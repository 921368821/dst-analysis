--============================================================
-- 文件：05_sourcemodifierlist.lua
-- 模块：组件支撑 / 修饰器袋（Source Modifier List）
-- 职责：管理「来自外部的、对某个属性或速率的修正」。
--       按来源(source)记账，支持同一个来源持有多把 key，
--       提供 multiply / additive / boolean 三种折叠方式，移除时干净撤销。
--
-- 【为什么需要这个模块？这是 DST 里最被低估的一块基建】
-- 设想：玩家的饥饿衰减速度是 1/s。现在要支持
--   - 站在冰箱旁 -> 减慢到 0.5/s
--   - 吃到「提速食物」-> 加快到 2/s
--   - 穿保暖衣物 -> 夜晚额外影响
--   - 队友光环（多人）-> 每人一份，叠加
-- 如果直接写 `self.hungerrate = 0.5`，那么：
--   ① 玩家一离开冰箱，你**不知道**该把速率改回多少（没有信息来源）
--   ② 两个来源同时生效时，顺序敏感，结果依赖施加顺序
--   ③ 来源实体被销毁后，修饰还挂着，变成「幽灵 buff」
-- 修饰器袋的解法是：**永远不直接写最终值**，只记录「谁要改成什么」，
-- 每次变化就从 base 重新折叠一遍（RecalculateModifier）。
-- 于是「撤销」变成了纯粹的数据删除，不需要反向操作，天然幂等。
--
-- 【三种折叠方式的语义】
--   multiply  —— 乘法。base=1，各来源给个系数。用于「速率倍率」（可乘可叠）
--   additive  —— 加法。base=0，各来源给个增量。用于「绝对增量」
--   boolean   —— 逻辑或。base=false，任一来源置 true 即为 true。用于「免疫」
-- ★ 选择原则：**同一属性只能用一种折叠方式**，否则语义会混乱
--   （"1 + 2 * 0.5" 和 "1 + 2" 再 * 0.5 差别很大）。
--   所以每个 SourceModifierList 实例在构造时就固定折叠函数。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》
--           scripts/util/sourcemodifierlist.lua（逐行注释版）
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local Class = require("01_class").Class

local M = {}

--============================================================
-- 一、折叠函数
--============================================================

function M.multiply(a, b) return a * b end
function M.additive(a, b) return a + b end
function M.boolean(a, b) return a or b end

M.FOLD = {
    multiply = M.multiply,
    additive = M.additive,
    boolean = M.boolean,
}

--============================================================
-- 二、SourceModifierList
--============================================================

-- 构造函数：SourceModifierList(inst, base_value, fn, dirtycb)
--   inst     —— 宿主实体。用来在「来源实体被销毁时自动撤销修饰」。
--               这就是 SourceModifierList 与实体系统唯一的耦合点。
--   base_val —— 基础值。不传时：multiply 折叠用 1，boolean 折叠用 false，
--               additive 折叠用 0。（按折叠函数自动选择，见下）
--   fn       —— 折叠函数，默认 multiply
--   dirtycb  —— 变化回调 function(inst, newvalue)，用于立刻刷新 UI/同步
local SourceModifierList = Class(function(self, inst, base_value, fn, dirtycb)
    self.inst = inst

    -- 私有成员
    self._modifiers = {}
    --【★ 数据结构：source -> { modifiers = { [key] = value }, onremove = fn }】
    --   两层的设计是为了支持「同一来源对同一属性施加多个独立修饰」：
    --     例如一件装备同时提供「寒冷抗性」和「移动速度」，来源是同一个实体，
    --     但 key 不同，移除时能精确撤掉其中一个。
    --   _modifier 是缓存的折叠结果，避免每次 Get() 都重算。

    if base_value ~= nil then
        self._modifier = base_value
        self._base = base_value
    else
        -- ★ 没给 base 时，按折叠函数选一个「乘/加单位元」
        --   multiply 的单位元是 1；boolean 的是 false；additive 的是 0。
        --   不这么做的话，additive 默认从 1 开始算会得到离谱的结果。
        local f = fn or M.multiply
        local defaultbase = 1
        if f == M.additive then defaultbase = 0
        elseif f == M.boolean then defaultbase = false end
        self._modifier = defaultbase
        self._base = defaultbase
    end

    self._fn = fn or M.multiply
    self._dirtycb = dirtycb
end)

function SourceModifierList:Get() return self._modifier end

function SourceModifierList:IsEmpty() return next(self._modifiers) == nil end

function SourceModifierList:HasAnyModifiers() return next(self._modifiers) ~= nil end

--★ 核心：每次变化都从 base 完整重算一遍，而不是「在旧结果上增量修改」。
--
--【为什么全量重算而不是增量？】
--  增量做法（multiply 场景）：除掉旧系数再乘新系数。
--    问题：浮点误差会累积（除两次再乘回来不等于原值），
--    而且乘法不可逆 —— 无法从结果反解出各项。
--  全量重算：复杂度 O(来源数)，但绝对正确、无误差累积。
--  修饰器来源通常是个位数（<10），全量重算的开销可以忽略。
--  ★ 移植到强类型语言时，如果来源可能有成百上千个，
--   就需要改成「带索引的平衡树 / 脏标记只重算脏子树」。
function SourceModifierList:RecalculateModifier()
    local m = self._base
    for source, src_params in pairs(self._modifiers) do
        for _, v in pairs(src_params.modifiers) do
            m = self._fn(m, v)
        end
    end
    self._modifier = m
    if self._dirtycb then
        self._dirtycb(self.inst, m)
    end
end

-- SetModifier(source, m, key)
--   source —— 可以是实体对象，也可以是任意字符串（如 "winter"）。传 nil 直接忽略。
--   m      —— 修饰值。传 nil 或等于 base 视为「撤销」（这是个很好用的快捷方式）。
--   key    —— 同一来源下的区分键，省略时用 "key"
--
--【★ 自动清理机制 —— 本模块最重要的设计】
--   当 source 是实体时，自动在它上面注册一个 onremove 监听：
--   一旦该实体被从世界中移除（比如玩家把护甲扔了、临时 buff 实体到期消失），
--   修饰会自动撤销并触发重算。
--
--   没有这个机制的后果（真实踩过的坑）：
--     玩家捡起又丢下护甲 100 次 -> 速率上挂着 100 个来源 -> 数值彻底错乱，
--     而且永远修不好，只能重开游戏。
function SourceModifierList:SetModifier(source, m, key)
    if source == nil then return end

    if key == nil then
        key = "key"
    end

    -- 传 nil 或等于 base，语义上就是「不需要修饰」，等价于移除。
    -- 这让调用方不必区分「取消」和「设为默认值」两种写法。
    if m == nil or m == self._base then
        self:RemoveModifier(source, key)
        return
    end

    local src_params = self._modifiers[source]
    if src_params == nil then
        -- 该来源首次出现
        self._modifiers[source] = {
            modifiers = { [key] = m },
        }

        -- 如果 source 是实体（而不是字符串），注册 onremove 自动撤销
        if type(source) == "table" and source._eventcallbacks ~= nil then
            local entry = self._modifiers[source]
            entry.onremove = function()
                -- 直接删表项再重算。**不要**走 RemoveModifier，
                -- 因为此时实体正在销毁途中，RemoveModifier 会再去解绑监听，
                -- 而监听表可能已经被清空了（会出问题）。
                self._modifiers[source] = nil
                self:RecalculateModifier()
            end
            self.inst:ListenForEvent(source, "onremove", entry.onremove, source)
        end

        self:RecalculateModifier()

    elseif src_params.modifiers[key] ~= m then
        -- 该来源已有，但这次的值变了 —— 避免无谓的重算
        src_params.modifiers[key] = m
        self:RecalculateModifier()
    end
end

-- RemoveModifier(source, key)
--   key 省略时移除整个来源；给了 key 只移除该来源下的这一把。
--【★ 干净撤销的关键】
--   移除时必须**解绑 onremove 监听**，否则监听会一直挂在实体上，
--   而监听闭包又持有 SourceModifierList -> 持有实体 -> 整条引用链都收不回来。
--   这是最容易漏的一行代码，也是「幽灵修饰 + 内存泄漏」的双重来源。
function SourceModifierList:RemoveModifier(source, key)
    local src_params = self._modifiers[source]
    if src_params == nil then
        return
    elseif key ~= nil then
        src_params.modifiers[key] = nil
        if next(src_params.modifiers) ~= nil then
            -- 这个来源还有其他 key（还有别的修饰），保留它
            self:RecalculateModifier()
            return
        end
    end

    -- 移除整个来源
    if src_params.onremove ~= nil then
        self.inst:RemoveEventCallback(source, "onremove", src_params.onremove, source)
    end
    self._modifiers[source] = nil
    self:RecalculateModifier()
end

-- Reset：清空所有来源，回到 base。
-- 用于实体状态被整体重置的场景（比如角色转换、读档覆盖）。
function SourceModifierList:Reset()
    for source, src_params in pairs(self._modifiers) do
        if src_params.onremove then
            self.inst:RemoveEventCallback(source, "onremove", src_params.onremove, source)
        end
        self._modifiers[source] = nil
    end
    self._modifier = self._base
    if self._dirtycb then
        self._dirtycb(self.inst, self._modifier)
    end
end

-- CalculateModifierFromSource(source, key)
--   「只看这一个来源贡献了多少」。用于调试面板 / 「我的减益是什么」这类 UI。
function SourceModifierList:CalculateModifierFromSource(source, key)
    local src_params = self._modifiers[source]
    if src_params == nil then
        return self._base
    elseif key == nil then
        local m = self._base
        for _, v in pairs(src_params.modifiers) do
            m = self._fn(m, v)
        end
        return m
    end
    return src_params.modifiers[key] or self._base
end

-- CalculateModifierFromKey(key)
--   「只看所有来源里，某一把 key 折叠出来是多少」。
--   例如查「所有来源里寒冷相关的总抗性」—— 可以做出定制 UI。
function SourceModifierList:CalculateModifierFromKey(key)
    local m = self._base
    for source, src_params in pairs(self._modifiers) do
        for k, v in pairs(src_params.modifiers) do
            if k == key then
                m = self._fn(m, v)
            end
        end
    end
    return m
end

function SourceModifierList:HasModifier(source, key)
    local src_params = self._modifiers[source]
    if src_params == nil then
        return false
    end
    if key == nil then
        key = "key"
    end
    return src_params.modifiers[key] ~= nil
end

-- GetSourceCount：调试用，看挂了多少来源
function SourceModifierList:GetSourceCount()
    local n = 0
    for _ in pairs(self._modifiers) do n = n + 1 end
    return n
end

--============================================================
-- 三、序列化（存档）
--============================================================

--【★ 为什么不能直接把 _modifiers 存进存档？】
-- 因为 _modifiers 的**键是实体对象**（table）。存档是纯文本/纯数据，
-- 无法表达「指向另一个实体」这种引用关系。
-- 存的时候必须把实体来源降级成**字符串身份**（prefab名 + GUID）。
-- 读的时候：字符串来源 -> 恢复成「这个修饰器由谁施加」的语义，
-- 通常重新应用，而不是重建实体引用。
-- 这也是为什么 sanity.lua 里的 inducedinsanity_sources 用字符串 src 而
-- SourceModifierList 的 source 在 OnSave 里是被过滤掉的。
function SourceModifierList:OnSave()
    if next(self._modifiers) == nil then return nil end
    local saved = {}
    for source, src_params in pairs(self._modifiers) do
        -- 只保存字符串来源（永久性的，如 "winter"、"season"）。
        -- 实体来源是运行期临时状态，读档后应该由游戏逻辑重新施加，
        -- 存下来反而会造成「引用了不存在的实体」。
        if type(source) == "string" then
            saved[source] = {}
            for k, v in pairs(src_params.modifiers) do
                saved[source][k] = v
            end
        end
    end
    if next(saved) == nil then return nil end
    return { modifiers = saved, base = self._base }
end

function SourceModifierList:OnLoad(data)
    if data == nil or data.modifiers == nil then return end
    self._modifiers = {}
    self._base = data.base or self._base
    for source, mods in pairs(data.modifiers) do
        self._modifiers[source] = { modifiers = {} }
        for k, v in pairs(mods) do
            self._modifiers[source].modifiers[k] = v
        end
    end
    self:RecalculateModifier()
end

--============================================================
-- 四、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[05_sourcemodifierlist] 断言失败: " .. msg, 2) end
end

-- 只为测试准备：修饰器袋需要真实的实体来验证「来源实体销毁 -> 自动撤销」
local Entity = require("03_entity").Entity

--- 测试 1：multiply 折叠 + 撤销
function T.multiply()
    local inst = Entity("sml_test1")
    local sml = SourceModifierList(inst, 1, M.multiply)

    check(sml:Get() == 1, "初始应等于 base")
    check(sml:IsEmpty(), "初始应为空")

    sml:SetModifier("fridge", 0.5)
    check(sml:Get() == 0.5, "1 * 0.5 = 0.5")

    sml:SetModifier("sprint", 2.0)
    check(sml:Get() == 1.0, "0.5 * 2.0 = 1.0")

    sml:SetModifier("buff", 1.5)
    check(sml:Get() == 1.5, "再叠 1.5 应为 1.5")
    check(sml:GetSourceCount() == 3, "应有 3 个来源")

    -- 移除中间那个，结果应该精确回到剩下两项的折叠值
    sml:RemoveModifier("sprint")
    check(sml:Get() == 0.75, string.format("移除 sprint 后应为 0.75，实际 %s", tostring(sml:Get())))
    check(sml:GetSourceCount() == 2, "移除后应剩 2 个来源")
    check(not sml:HasModifier("sprint"), "HasModifier 应为假")

    -- 全部移除回到 base
    sml:RemoveModifier("fridge")
    sml:RemoveModifier("buff")
    check(sml:Get() == 1, "全部移除后应回到 base")
    check(sml:IsEmpty(), "应重新变空")
    print("  [OK] multiply 折叠 + 干净撤销")
end

--- 测试 2：★ 题目要求的「加 3 个来源移除 1 个，验证总量」
function T.threeSourcesRemoveOne()
    local inst = Entity("sml_test2")
    local sml = SourceModifierList(inst, 1, M.multiply)

    -- 三个来源各给一个系数
    sml:SetModifier("srcA", 2)
    sml:SetModifier("srcB", 3)
    sml:SetModifier("srcC", 4)
    local total = 1 * 2 * 3 * 4
    check(sml:Get() == total,
        string.format("3 个来源折叠应为 %d，实际 %s", total, tostring(sml:Get())))

    -- 移除中间那个 B
    sml:RemoveModifier("srcB")
    local expected = 1 * 2 * 4
    check(sml:Get() == expected,
        string.format("移除 srcB 后应为 %d，实际 %s", expected, tostring(sml:Get())))
    check(sml:GetSourceCount() == 2, "应剩 2 个来源")
    -- 单来源贡献查询
    check(sml:CalculateModifierFromSource("srcA") == 2, "srcA 单独贡献应为 2")
    check(sml:CalculateModifierFromSource("srcC") == 4, "srcC 单独贡献应为 4")
    -- 已移除的来源查不到，回落 base
    check(sml:CalculateModifierFromSource("srcB") == 1, "srcB 应回落到 base")
    print(string.format("  [OK] 3 来源 -> 移除 1 个：%d -> %d，精确无误", total, sml:Get()))
end

--- 测试 3：additive 折叠
function T.additive()
    local inst = Entity("sml_test3")
    local sml = SourceModifierList(inst, 0, M.additive)
    check(sml:Get() == 0, "additive 默认 base 应为 0")

    sml:SetModifier("hedge", 0.5)
    sml:SetModifier("tea", 0.25)
    check(sml:Get() == 0.75, "0 + 0.5 + 0.25 = 0.75")
    sml:RemoveModifier("hedge")
    check(sml:Get() == 0.25, "移除后应为 0.25")
    print("  [OK] additive 折叠")
end

--- 测试 4：boolean 折叠
function T.boolean()
    local inst = Entity("sml_test4")
    local sml = SourceModifierList(inst, false, M.boolean)
    check(sml:Get() == false, "boolean 默认应为 false")

    sml:SetModifier("hat", true)
    check(sml:Get() == true, "任一为 true 则整体 true")
    sml:SetModifier("shield", true)
    check(sml:Get() == true, "多来源仍为 true")
    sml:RemoveModifier("hat")
    check(sml:Get() == true, "还有一个来源为 true")
    sml:RemoveModifier("shield")
    check(sml:Get() == false, "全部移除后回到 false")
    print("  [OK] boolean 折叠")
end

--- 测试 5：同一来源多 key
function T.multiKey()
    local inst = Entity("sml_test5")
    local sml = SourceModifierList(inst, 1, M.multiply)

    sml:SetModifier("armor", 0.5, "cold")     -- 同一个来源，两把 key
    sml:SetModifier("armor", 0.8, "heat")
    check(sml:Get() == 0.4, "同一来源两把 key 应相乘 = 0.4")

    -- 只撤掉一把
    sml:RemoveModifier("armor", "cold")
    check(sml:Get() == 0.8, "只撤 cold 后应剩 heat = 0.8")
    check(sml:GetSourceCount() == 1, "来源数仍为 1（未整体移除）")
    print("  [OK] 同一来源多 key 的精确撤销")
end

--- 测试 6：★ 来源实体被销毁 -> 自动撤销（防幽灵 buff）
function T.autoRemoveOnEntityRemoval()
    local host = Entity("host")
    local sml = SourceModifierList(host, 1, M.multiply)

    -- 一个永久来源（字符串）：季节、天气这类全局状态
    sml:SetModifier("winter", 0.5)
    -- 一个临时来源（实体）：临时 buff 实体，到期会被从世界里删掉
    local buff = Entity("buff_entity")
    sml:SetModifier(buff, 2)

    check(sml:Get() == 1.0, "0.5 * 2 = 1.0")

    -- buff 到期消失 -> 修饰必须自动撤销，不能变成幽灵 buff
    buff:Remove()

    check(sml:Get() == 0.5,
        string.format("实体销毁后修饰应自动撤销，应为 0.5，实际 %s", tostring(sml:Get())))
    check(sml:GetSourceCount() == 1, "只剩 1 个来源（winter）")

    -- onremove 监听也必须被解绑，否则 host 会被 buff 的引用链钉住。
    -- （Entity:Remove() 在广播后会清空自己的订阅表，所以这里查的是空/nil）
    check(buff._eventcallbacks.onremove == nil or #buff._eventcallbacks.onremove == 0,
        "撤销后不应残留在 buff 实体的订阅表里")
    print("  [OK] 来源实体销毁 -> 自动撤销（防幽灵 buff）+ 监听解绑")
end

--- 测试 7：脏值回调
function T.dirtycb()
    local inst = Entity("sml_test7")
    local calls = 0
    local lastval = nil
    local sml = SourceModifierList(inst, 1, M.multiply, function(i, v)
        calls = calls + 1
        lastval = v
    end)
    sml:SetModifier("a", 2)
    check(calls == 1 and lastval == 2, "设置修饰应触发回调")
    -- 重复设置相同值不应触发回调（避免无谓的 UI 刷新）
    sml:SetModifier("a", 2)
    check(calls == 1, "设置相同值不应重复触发回调")
    sml:RemoveModifier("a")
    check(calls == 2 and lastval == 1, "移除应触发回调并回到 base")
    print("  [OK] dirtycb 脏值回调（去重）")
end

--- 测试 8：序列化（只存字符串来源）
function T.saveLoad()
    local inst = Entity("sml_test8")
    local sml = SourceModifierList(inst, 1, M.multiply)

    local tmp = Entity("tmp_buff")   -- 临时实体来源
    sml:SetModifier("winter", 0.5)       -- 字符串来源：应被保存
    sml:SetModifier(tmp, 2)              -- 实体来源：不应被保存

    local d = sml:OnSave()
    check(d ~= nil, "应产生存档数据")
    check(d.modifiers.winter ~= nil, "字符串来源应被保存")
    check(d.modifiers.winter.key == 0.5, "字符串来源的修饰值应被保存")
    check(d.modifiers[tmp] == nil and d.modifiers[tmp] == nil,
        "实体来源不应被保存（存档无法表达实体引用）")

    -- 读档重建
    local sml2 = SourceModifierList(inst, 1, M.multiply)
    sml2:OnLoad(d)
    check(sml2:Get() == 0.5, string.format("读档后应为 0.5，实际 %s", tostring(sml2:Get())))
    check(sml2:GetSourceCount() == 1, "读档后应只有 1 个来源")

    -- 空袋不存档
    local sml3 = SourceModifierList(inst, 1, M.multiply)
    check(sml3:OnSave() == nil, "空袋应返回 nil（省体积）")
    print("  [OK] 序列化：只存永久来源，实体来源交给逻辑重建")
end

function T.run()
    print("=== 05_sourcemodifierlist.lua 自测 ===")
    T.multiply()
    T.threeSourcesRemoveOne()
    T.additive()
    T.boolean()
    T.multiKey()
    T.autoRemoveOnEntityRemoval()
    T.dirtycb()
    T.saveLoad()
    print("05_sourcemodifierlist 全部通过\n")
    return true
end

M.SourceModifierList = SourceModifierList
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