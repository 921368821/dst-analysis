--============================================================
-- 文件：09_savegame.lua
-- 模块：基础设施 / 存档
-- 职责：带版本号的序列化、反序列化、字段重命名/删除的迁移钩子、
--       以及 NaN / Inf 的拦截。
--
-- 【★ 存档三件套：序列化 + 版本号 + 迁移】
-- 只做序列化是不够的。假设 v1 存的是 { food = 50 }，
-- v2 改名成 { hunger = 50 }，那所有 v1 存档一读就全崩（food 是 nil），
-- 而且是「玩家玩了 100 小时之后才发现存档废了」这种灾难。
--
-- 所以存档必须回答三个问题：
--   1. 怎么把数据变成文本？（序列化）
--   2. 这份文本是哪个版本写的？（version 字段）
--   3. 老版本读出来之后怎么变成新结构？（migrations 表）
--
-- 【★ 为什么迁移必须是「逐版本」的链式迁移，而不是一个大 if？】
--   链式：v1 -> v2 -> v3，每一步只关心「上一版长什么样」。
--   好处：跳过多版本直接读 v1 存档也能正常工作（内部自动连跑 v1→v2→v3）。
--   如果写成一个大 if(v < 3) then ... elseif(v < 5) then ... end，
--   改到 v7 时所有历史分支都得动，迟早漏掉一条。
--
-- 【★★★ NaN / Inf —— 这是原版真实踩过的坑】
-- Lua 里 `0/0` 得到 NaN，`math.huge` 得到 Inf。这两个东西一旦进了存档：
--   - 序列化时可能写成 "nan" / "inf"，读回来时解析失败或变成垃圾
--   - 更糟：NaN 参与任何算术运算，结果还是 NaN，会**静默污染整个状态**
--     （表现为「这玩家的饥饿度永远是 NaN，所有 UI 显示乱码」）
-- 所以这里在**序列化入口**统一拦截，而不是等到读档时才报错。
--
-- 【为什么不用 JSON？】
-- Lua 没有内置 JSON，本可以用第三方库。但这里手写一个极简序列化器有两个好处：
--   1. 零依赖：教学项目 clone 下来就能跑。
--   2. 可以精确控制「哪些类型允许进存档」——这正是拦截 NaN/Inf 的切入点。
-- 真实项目里用 JSON 的话，NaN 检查要挂在 json.encode 之前，效果一样。
--
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local M = {}

--============================================================
-- 一、类型标记与序列化
--============================================================

-- 用「单字符类型标记 + 值」的结构，而不是纯 JSON。
-- 为什么要标记？因为 JSON 分不清 [] 和 {}、也存不了 nil / 布尔 / 函数。
-- 存档必须能**无损**还原，否则「读档后行为与读档前不一致」会成为噩梦。
local function is_array(t)
    -- 【判定规则】所有键都是连续正整数 -> 数组；否则是哈希表。
    -- 必须遍历确认，不能只看「有几个键」。
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false, 0 end
        if k < 1 or k % 1 ~= 0 then return false, 0 end
        n = n + 1
    end
    if n == 0 then return true, 0 end
    -- 连续性检查：最大键应等于键数
    local maxk = 0
    for k in pairs(t) do if k > maxk then maxk = k end end
    return (maxk == n), n
end

-- IsFinite：★ NaN / Inf 拦截的核心
local function is_finite(n)
    -- n == n 对 NaN 恒为 false（NaN 是唯一「不等于自己」的值）
    -- 这一行就同时挡住了 NaN 和 ±Inf
    return n == n and n ~= math.huge and n ~= -math.huge
end

M.IsFinite = is_finite

-- 序列化：把 Lua 值写成带类型标记的文本
--   opts.strict     —— 为 true 时遇到非法值直接报错（默认）
--   opts.onbadvalue —— 为 false 时把非法值替换成 nil 并记录警告
-- 【存档文本格式】全部用「显式长度/个数前缀」，**不使用分隔符推断长度】
--
--   z;                     nil
--   b0; / b1;              布尔
--   n<number>;             数值
--   s<len>:<len个字节>     字符串（长度前缀）
--   a<count>:<count个值>   数组
--   h<count>:<count组(键 值)>  哈希表
--
-- ★ 为什么要长度前缀而不是「用分号/逗号分隔到下一个分隔符为止」？
--   因为字符串里**可以包含任意字符**。用分隔符的格式遇到
--   玩家名里带分号（"a;b"）或物品名带逗号时就会解析错乱，
--   而且这种 bug 只在特定玩家名/物品名时触发，极难复现。
--   长度前缀让「读多少字节」完全由前面的数字决定，不依赖内容。
local function serialize(v, out, path, opts)
    out = out or {}
    local t = type(v)

    if v == nil then
        out[#out + 1] = "z;"
    elseif t == "boolean" then
        out[#out + 1] = "b" .. (v and "1;" or "0;")
    elseif t == "number" then
        -- ★★★ NaN / Inf 拦截点 ★★★
        if not is_finite(v) then
            local msg = string.format("存档序列化拒绝非法数值 %s（路径: %s）", tostring(v), path or "?")
            if opts.strict ~= false then
                error(msg)
            end
            out[#out + 1] = "z;"
            out.warnings = out.warnings or {}
            out.warnings[#out.warnings + 1] = msg
        else
            -- ★ 用 "%.17g" 而不是 tostring()：
            --   tostring(0.1) 在不同 Lua 版本/平台上可能给 "0.1" 或
            --   "0.10000000000000001"；而 17 位有效数字能保证 float64
            --   **无损往返**。存 6 位有效数字的存档会出现「血量慢慢漂移」的怪 bug。
            out[#out + 1] = "n" .. string.format("%.17g", v) .. ";"
        end
    elseif t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "table" then
        local isarr, n = is_array(v)
        if isarr then
            out[#out + 1] = "a" .. n .. ":"
            for i = 1, n do
                serialize(v[i], out, (path or "") .. "[" .. i .. "]", opts)
            end
        else
            -- 键排序：保证同一份数据每次序列化结果**完全一致**。
            -- ★ 这很重要：存档文件若每次保存字节都不同，就无法做二进制 diff、
            --   无法校验、无法增量同步。Lua 的 pairs 顺序不确定，必须显式排序。
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" and type(k) ~= "number" then
                    local msg = string.format("存档遇到不支持的键类型 %s（路径: %s）", type(k), path or "?")
                    if opts.strict ~= false then error(msg) end
                else
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            out[#out + 1] = "h" .. #keys .. ":"
            for _, k in ipairs(keys) do
                serialize(tostring(k), out, (path or "") .. ".key", opts)
                serialize(v[k], out, (path or "") .. "." .. tostring(k), opts)
            end
        end
    elseif t == "function" or t == "userdata" or t == "thread" then
        -- 函数/协程/用户数据不可能存。明确报错而不是静默跳过 ——
        -- 静默跳过会导致「存档里少了一块状态，读档后行为诡异」，
        -- 这种 bug 排查起来比直接崩溃痛苦得多。
        local msg = string.format("存档不支持的类型 %s（路径: %s）", t, path or "?")
        if opts.strict ~= false then error(msg) end
        out[#out + 1] = "z;"
    else
        local msg = string.format("存档未知类型 %s（路径: %s）", t, path or "?")
        if opts.strict ~= false then error(msg) end
        out[#out + 1] = "z;"
    end
    return out
end

M.Serialize = serialize

-- 反序列化：手写递归下降解析器。
-- 全部靠「长度前缀」定位，因此绝不会被内容里的特殊字符干扰。
local function deserialize(s)
    local pos = 1
    local n = #s

    local function readch()
        local c = string.sub(s, pos, pos)
        pos = pos + 1
        return c
    end
    local function readuntil(ch)
        local start = pos
        while pos <= n and string.sub(s, pos, pos) ~= ch do pos = pos + 1 end
        if pos > n then
            error(string.format("存档解析失败：在位置 %d 处找不到分隔符 '%s'", start, ch))
        end
        local r = string.sub(s, start, pos - 1)
        pos = pos + 1          -- 吃掉分隔符
        return r
    end
    local function readnum()
        return tonumber(readuntil(";"))
    end

    local parse

    parse = function()
        local t = readch()
        if t == "z" then
            -- 注意：必须把结尾的 ';' 吃掉，否则它会被下一次 parse
            -- 当成类型标记读走。这正是序列化格式里「每个值都要消费同样长度」的要求。
            readuntil(";")
            return nil
        elseif t == "b" then
            local c = readch()
            readuntil(";")
            return c == "1"
        elseif t == "n" then
            local num = readuntil(";")
            local v = tonumber(num)
            -- ★ 读回时必须严格校验，两道关：
            --   ① tonumber 失败 -> 说明文本不是合法数字。
            --      特别注意：Lua 的 tonumber("nan") 返回 **nil**（而不是 NaN），
            --      所以如果只检查 is_finite(v)，NaN 会被当成 nil 静默放过。
            --      上面几行 01~04 的逻辑里 `v ~= nil and not is_finite(v)`
            --      因此永远不成立 —— 这个坑非常隐蔽。
            --   ② v 非有限 -> 文件里被塞进了 NaN / Inf。
            if v == nil then
                error(string.format("存档解析失败：非法数值字面量 '%s'（位置 %d）", num, pos))
            end
            if not is_finite(v) then
                error("存档文件中含有非法数值（NaN/Inf），已拒绝读取")
            end
            return v
        elseif t == "s" then
            local len = tonumber(readuntil(":"))
            local str = string.sub(s, pos, pos + len - 1)
            pos = pos + len
            return str
        elseif t == "a" then
            local count = tonumber(readuntil(":"))
            local arr = {}
            for i = 1, count do arr[i] = parse() end
            return arr
        elseif t == "h" then
            local count = tonumber(readuntil(":"))
            local map = {}
            for _ = 1, count do
                local k = parse()
                local v = parse()
                -- 键在序列化时被 tostring 过，读回来可能是数字或字符串
                map[k] = v
            end
            return map
        end
        error(string.format("存档解析失败：未知类型标记 '%s'（位置 %d）", tostring(t), pos - 1))
    end

    return parse()
end

M.Deserialize = deserialize

--============================================================
-- 二、版本号与迁移
--============================================================

-- 存档系统本体
local SaveGame = {}
SaveGame.__index = SaveGame

M.VERSION = 3          -- ★ 当前存档格式版本

-- migrations：{ [旧版本号] = function(data) ... end }
--   每个函数负责把「版本 N 的数据」升级成「版本 N+1 的数据」。
--   ★ key 是「迁移前」的版本号，这是最容易写错的地方。
M.migrations = {
    -- v1 -> v2：hunger 字段改名，且含义从「剩余饥饿」变为「饥饿百分比」
    [1] = function(data)
        if data.player ~= nil then
            if data.player.food ~= nil then
                data.player.hunger = data.player.food
                data.player.food = nil
            end
            -- 语义变了：原来存绝对值，现在存百分比（0..1）
            if data.player.hunger ~= nil and data.player.hunger > 1 then
                data.player.hunger = data.player.hunger / 150
            end
        end
        data.version = 2
        return data
    end,
    -- v2 -> v3：删除了 sanity.hallucinations 字段（改成运行时计算）
    --        同时把 entities 数组里的 name 字段改名为 prefab
    [2] = function(data)
        if data.player ~= nil and data.player.sanity ~= nil then
            data.player.sanity.hallucinations = nil
        end
        if data.entities ~= nil then
            for i = 1, #data.entities do
                local e = data.entities[i]
                if e.name ~= nil then
                    e.prefab = e.name
                    e.name = nil
                end
            end
        end
        data.version = 3
        return data
    end,
}

-- 注册自定义迁移钩子（模组/版本升级时用）
function M.RegisterMigration(fromversion, fn)
    M.migrations[fromversion] = fn
end

-- Migrate：把任意历史版本的数据升级到当前版本
function M.Migrate(data)
    if type(data) ~= "table" then
        error("存档迁移失败：根节点必须是表")
    end
    data.version = data.version or 1

    local applied = {}
    -- ★ 链式迁移：即使存档来自 v1，也能一路连跑到当前版本
    local guard = 0
    while data.version < M.VERSION do
        guard = guard + 1
        if guard > 100 then
            error("存档迁移陷入死循环（version=" .. tostring(data.version) .. "）")
        end
        local from = data.version
        local fn = M.migrations[from]
        if fn == nil then
            error(string.format(
                "缺少 v%d -> v%d 的迁移钩子！旧存档无法读取。", from, from + 1))
        end
        data = fn(data) or data
        if data.version == from then
            error(string.format("v%d -> v%d 的迁移钩子没有更新 version 字段", from, from + 1))
        end
        applied[#applied + 1] = from
    end

    if data.version > M.VERSION then
        -- ★ 降版本保护：存档来自比当前程序更新的版本（比如玩家在装了 mod 的
        --   存档上读了一个没装 mod 的客户端）。这时不能读，读了必然出错。
        error(string.format(
            "存档版本 v%d 高于当前程序支持的 v%d —— 存档来自更新版本或带 mod 的版本",
            data.version, M.VERSION))
    end
    return data, applied
end

--============================================================
-- 三、保存 / 载入
--============================================================

-- Save：把一份纯数据存档成字符串
--   format = "compressed" | "plain"（教学版两者等价，保留接口说明原版的真实行为）
function M.Save(data, opts)
    opts = opts or {}
    -- 先校验能否安全序列化（NaN/Inf/函数会在这一步报错）
    local buf = {}
    serialize(data, buf, "$", opts)
    local text = table.concat(buf)
    return text
end

-- Load：读档。自动执行迁移。
function M.Load(text, opts)
    opts = opts or {}
    local data = deserialize(text)
    if type(data) ~= "table" then
        error("存档反序列化失败：根节点不是表")
    end
    local migrated, applied = M.Migrate(data)
    return migrated, applied
end

-- SaveToFile / LoadFromFile：教学版不写磁盘（保持纯逻辑、便于测试），
--   但保留接口说明真实项目该怎么做。
function M.SaveToFile(path, data)
    error("教学版不实现文件 IO —— 请在宿主层（Unity/Godot/Node）里调用 M.Save 后自行落盘")
end
function M.LoadFromFile(path)
    error("教学版不实现文件 IO —— 请在宿主层读取文本后调用 M.Load")
end

--============================================================
-- 四、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[09_savegame] 断言失败: " .. msg, 2) end
end
local function near(a, b, eps, msg)
    check(math.abs(a - b) < (eps or 1e-9),
        (msg or "数值不符") .. string.format("  期望 %.10f 实际 %.10f", b, a))
end

--- 测试 1：基本往返
function T.roundTrip()
    local data = {
        version = M.VERSION,
        player = { name = "Willow", hunger = 0.75, sanity = 0.5, health = 100 },
        inventory = { "berries", "torch", "stone" },
        position = { x = 12.5, y = -3.25, z = 0.125 },
        alive = true,
        nothing = nil,
    }
    local text = M.Save(data)
    check(#text > 0, "应产出文本")

    local back, _ = M.Load(text)
    check(back.version == M.VERSION, "版本号应一致")
    check(back.player.name == "Willow", "字符串应还原")
    near(back.player.hunger, 0.75, 1e-12, "浮点数应无损还原")
    near(back.position.y, -3.25, 1e-12, "负数应还原")
    check(#back.inventory == 3 and back.inventory[1] == "berries", "数组应还原")
    check(back.alive == true, "布尔应还原")
    check(back.nothing == nil, "nil 应还原")

    -- ★ 无损往返验证：用极难精确表示的浮点数
    local tricky = { a = 0.1, b = 1 / 3, c = 1e-300, d = 123456789.123456789, e = -0.000001 }
    local back2 = M.Load(M.Save(tricky))
    near(back2.a, tricky.a, 1e-15, "0.1 应精确往返")
    near(back2.b, tricky.b, 1e-15, "1/3 应精确往返")
    near(back2.c, tricky.c, 1e-300, "极小数应精确往返")
    near(back2.d, tricky.d, 1e-9, "大数应精确往返")
    print("  [OK] 序列化往返（含 float64 无损 + 类型无损）")
end

--- 测试 2：★ NaN / Inf 拦截
function T.nanInfGuard()
    -- NaN
    local ok = pcall(M.Save, { version = M.VERSION, x = 0 / 0 })
    check(not ok, "★ NaN 必须被拒绝（严格模式）")

    -- Inf
    local ok2 = pcall(M.Save, { version = M.VERSION, x = math.huge })
    check(not ok2, "★ Inf 必须被拒绝")

    -- 负 Inf
    local ok3 = pcall(M.Save, { version = M.VERSION, x = -math.huge })
    check(not ok3, "★ -Inf 必须被拒绝")

    -- 嵌套里的 NaN 也要拦（很多 bug 就藏在深层嵌套里）
    local ok4 = pcall(M.Save, { version = M.VERSION, a = { b = { c = { d = 0/0 } } } })
    check(not ok4, "深层嵌套的 NaN 也必须被拒绝")

    -- 非严格模式：降级成 nil，并给出警告
    local text = M.Save({ version = M.VERSION, good = 1, bad = 0 / 0 }, { strict = false })
    local back = M.Load(text)
    check(back.good == 1, "合法字段应保留")
    check(back.bad == nil, "NaN 应被降级为 nil")

    -- ★ 反序列化侧也要拦：存档文件可能被外部改坏/被 mod 塞进非法数值。
    --   按本模块的格式，手工造一条含 NaN 的文本（nnan;），必须被拒绝读取。
    --   这是防御性校验：序列化时已经拦过一次，这里防的是「文件被篡改」。
    local tampered = "h1:s1:xn1:n" .. string.format("%.17g", 0 / 0) .. ";"
    check(tampered ~= nil, "构造被篡改的存档文本")
    local ok5, err5 = pcall(M.Deserialize, tampered)
    check(not ok5, "★ 读档时遇到 NaN 必须拒绝")
    check(tostring(err5):find("非法数值") ~= nil,
        "错误信息应说明是非法数值，实际: " .. tostring(err5))

    -- 格式本身损坏时也要报错，而不是返回垃圾数据
    local ok6 = pcall(M.Deserialize, "h1:s1:xx")   -- 数量与内容不符
    check(not ok6, "格式损坏的存档必须报错")
    -- 直接写 Inf 字面量也应被拒
    local ok7 = pcall(M.Deserialize, "n" .. tostring(math.huge) .. ";")
    check(not ok7, "★ 读档时遇到 Inf 必须拒绝")
    print("  [OK] NaN / Inf 拦截（严格拒绝 + 非严格降级 + 深层嵌套 + 读档侧防篡改）")
end

--- 测试 3：确定性（同样的数据必须产出同样的字节）
function T.deterministic()
    local data = { version = M.VERSION, b = 2, a = 1, c = 3, d = { z = 1, y = 2 } }
    local t1 = M.Save(data)
    local t2 = M.Save(data)
    check(t1 == t2, "★ 同样的数据必须产出完全相同的存档文本（否则无法做 diff/校验）")
    print("  [OK] 序列化确定性（键排序）")
end

--- 测试 4：★ 迁移钩子
function T.migration()
    -- 模拟一份 v1 存档（老版本：字段叫 food，存绝对值；实体字段叫 name）
    local v1 = {
        version = 1,
        player = { food = 75 },           -- 75 / 150 = 0.5
        entities = {
            { name = "berry_bush", x = 10 },
            { name = "rock", x = 20 },
        },
        sanity_old_field = 0.5,
    }
    local text = M.Save(v1)

    local data, applied = M.Load(text)
    -- 应连跑 v1->v2->v3
    check(#applied == 2, string.format("应执行 2 步迁移，实际 %d 步", #applied))
    check(applied[1] == 1 and applied[2] == 2, "应按 1,2 顺序迁移")
    check(data.version == M.VERSION, string.format("迁移后应为 v%d", M.VERSION))

    -- v1->v2：food 改名 hunger，并从绝对值转成百分比
    check(data.player.food == nil, "旧字段 food 应被删除")
    check(data.player.hunger ~= nil, "新字段 hunger 应存在")
    near(data.player.hunger, 0.5, 1e-9, "绝对值 75 应转成百分比 0.5")

    -- v2->v3：实体的 name 改名 prefab
    check(data.entities[1].name == nil, "旧字段 name 应被删除")
    check(data.entities[1].prefab == "berry_bush", "应迁移为 prefab 字段")
    check(data.entities[2].prefab == "rock", "所有实体都应迁移")

    print("  [OK] 链式迁移 v1→v2→v3（字段重命名 + 语义转换 + 字段删除）")
end

--- 测试 5：缺失迁移钩子必须明确报错
function T.missingMigration()
    local v1 = { version = 1, player = { food = 75 } }
    -- 临时移除 v1->v2 的钩子
    local saved = M.migrations[1]
    M.migrations[1] = nil
    local ok = pcall(M.Load, M.Save(v1))
    M.migrations[1] = saved
    check(not ok, "缺少迁移钩子必须报错（而不是静默丢数据）")
    print("  [OK] 缺失迁移钩子明确报错")
end

--- 测试 6：版本过高保护
function T.futureVersion()
    local v99 = { version = 99, player = {} }
    local ok = pcall(M.Load, M.Save(v99))
    check(not ok, "★ 高于当前版本的存档必须拒绝读取（否则会读出乱数据）")
    print("  [OK] 版本过高保护")
end

--- 测试 7：★ 存档 -> 读档 -> 状态一致（与实体系统集成）
function T.entityRoundTrip()
    local Entity = require("03_entity").Entity
    local Meters = require("04_meter")
    local spawn = require("06_prefab_spawn")
    spawn.SetMasterSim(true)

    -- 造一个玩家并消耗一些资源
    local player = spawn.SpawnPrefab("player", 12.5, -7.25)
    player.components.hunger:Eat(-60)      -- 扣 60 点
    player.components.health:DoDamage(25, "hound")
    player.components.sanity:SetPercent(0.6)

    -- 收集世界状态
    local worlddata = {
        version = M.VERSION,
        player = {
            hunger = player.components.hunger.current,
            health = player.components.health.current,
            sanity = player.components.sanity.current,
            x = player.x, z = player.z,
        },
        entities = { { name = player.prefab, x = player.x, z = player.z } },
    }

    -- 存档 -> 文本
    local text = M.Save(worlddata)

    -- ★ 关键一步：销毁原实体，重新生成一个（同预制体），
    --   然后用存档恢复 —— 模拟真实的「退出游戏再进」流程。
    player:Remove()
    local player2 = spawn.SpawnPrefab("player", 0, 0)
    check(player2.components.hunger.current ~= worlddata.player.hunger,
        "新生成的玩家应处于默认状态（与存档不同）")

    -- 读档 -> 恢复到新实体
    local loaded = M.Load(text)
    player2.components.hunger.current = loaded.player.hunger
    player2.components.health.current = loaded.player.health
    player2.components.sanity.current = loaded.player.sanity
    player2.x, player2.z = loaded.player.x, loaded.player.z

    near(player2.components.hunger.current, worlddata.player.hunger, 1e-12, "饥饿度应一致")
    near(player2.components.health.current, worlddata.player.health, 1e-12, "血量应一致")
    near(player2.components.sanity.current, worlddata.player.sanity, 1e-12, "理智度应一致")
    near(player2.x, worlddata.player.x, 1e-12, "坐标应一致")
    check(player2.GUID ~= player.GUID, "重生成后 GUID 应不同（GUID 是实例身份，不是存档身份）")

    print(string.format("  [OK] 存档->读档->状态一致：hunger=%.4f health=%.4f sanity=%.4f",
        player2.components.hunger.current,
        player2.components.health.current,
        player2.components.sanity.current))
end

--- 测试 8：实体 OnSave / OnLoad 契约
function T.entityContract()
    local Entity = require("03_entity").Entity
    local Meters = require("04_meter")
    local e = Entity("contract_ent")
    e:AddComponent(Meters.Health)

    -- 默认状态不存档（省体积）
    check(e:OnSave() == nil, "默认状态不应产生存档数据")

    e.components.health:DoDamage(40)
    local d = e:OnSave()
    check(d ~= nil, "有状态时应产生存档数据")
    -- ★ 注意数值条存的是 `{ [自己的 eventname] = current }`，
    --   所以这里是 components.health.health 而不是 components.health.current。
    --   这个约定与原版 DST 的 hunger.lua / sanity.lua 一致，
    --   好处是每个组件的存档数据自带字段名，读日志/调存档时一眼能看懂。
    check(d.components.health ~= nil, "应含 health 组件数据")
    check(d.components.health.health == 60, "应存下正确数值")

    -- 重建 + 恢复
    local e2 = Entity("contract_ent2")
    e2:AddComponent(Meters.Health)
    e2:OnLoad(d)
    near(e2.components.health.current, 60, 1e-12, "OnLoad 应恢复状态")
    print("  [OK] 实体 OnSave/OnLoad 契约（默认状态省略 + 精确恢复）")
end

function T.run()
    print("=== 09_savegame.lua 自测 ===")
    T.roundTrip()
    T.nanInfGuard()
    T.deterministic()
    T.migration()
    T.missingMigration()
    T.futureVersion()
    T.entityRoundTrip()
    T.entityContract()
    print("09_savegame 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 五、导出
--============================================================

-- 【独立运行检测】不能用 `... == nil`：Lua 5.2+ 用 load 编译的 chunk 非 vararg，
--   顶层 `...` 是语法错误。详见 01_class.lua 末尾的说明。
local function IS_MAIN_CHUNK()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) ~= "@" then return false end
    local fname = src:sub(2):gsub("\\", "/"):match("([^/]+)$") or ""
    if fname == "" then return false end
    return arg ~= nil and arg[0] ~= nil
        and (arg[0]:gsub("\\", "/"):match("([^/]+)$")) == fname
end

if IS_MAIN_CHUNK() then
    T.run()
end

return M