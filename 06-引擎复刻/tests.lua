--[[
==============================================================================
 tests.lua —— 本工程所有修复的**行为断言**回归
==============================================================================
为什么要有这个入口
    本项目修过不少东西，其中好几个是「静默失效」型：
    桩返回 nil、覆盖没撤销、计数记在错误的分支、参数读不到……
    共同点是**不报错**，所以「跑通了 / 没进桩清单」**不能证明修好了**。
    本工程自己的原则是：判断实现真伪只能靠行为。

    之前的验证是分散的（equip.lua / burn.lua / perish.lua 各验一块），
    而且多数只验到「不再报桩」—— 那是**必要条件不是充分条件**。
    本入口把每个修复写成一条**能独立判定真伪的行为断言**，一条不过就红。

覆盖的修复
    T1  OverrideSymbol 必须成对撤销        （卸下后帽子留在画面上）
    T2  PrefabExists 必须先懒加载再判      （烧焦掉落掉 ash 而非熟肉）
    T3  stringutil 必须加载                （协程脚本静默死掉）
    T4  GetTimeAlive + spawntime          （恒为「存活 0 秒」）
    T5  SetTwoFaced                        （粒子永远单面）
    T6  OverrideShade                      （躲棚下不变暗）
    T7  birds 家族文件                     （SpawnPrefab("crow") 静默 nil）
    T8  缺 build 的计数口径                （口径三连错）

★★ 断言的写法约定（这条本身是被实测逼出来的）
    断言函数一律 `return 布尔, 说明文字`，**说明文字不参与判定**。

    为什么强调：第一版判据写成 `ok and (info ~= false)`，
    而各条断言成功与失败**都 return 一个字符串** —— 字符串恒真
    ⇒ **11 条全部假通过**，输出里甚至出现
    「✔ … （期望回到原值）」这种自相矛盾的行。
    这跟本工程一直在防的「静默空实现」是同一类错误，
    而且**出现在测试框架自己身上**。
    所以 check() 现在额外做一道保险：
    断言返回值不是 boolean ⇒ 直接判失败并说明「判定不可信」。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

Bootstrap.Setup()
WorldMap.Generate({ seed = 20261015 })

local results = {}

local function hr(t)
    print("")
    print(string.rep("═", 72))
    print("  " .. tostring(t))
    print(string.rep("═", 72))
end

local function check(name, fn)
    local called, a, b = pcall(fn)
    local ok, info
    if not called then
        ok, info = false, "抛异常: " .. tostring(a)
    elseif type(a) ~= "boolean" then
        ok, info = false, string.format(
            "断言未返回布尔（得到 %s）—— 判定不可信，已按失败处理", type(a))
    else
        ok, info = a, tostring(b)
    end
    results[#results + 1] = { name = name, ok = ok, info = info }
    print(string.format("  %s %-44s %s", ok and "✔" or "✘", name, info))
end

--[[
 ★★ 环境前提不满足时的**显式跳过**（⊘）—— 2026-10-17 加

 起因：本机没有装 DST（`data/minimap/minimap_data1.xml` 不存在），
   于是两条「kleifileexists 真查磁盘 / resolvefilepath 解得出真实路径」必然红。
   这两条**不是在验我们的代码，而是在验「这台机器上有没有原版数据」**。

 为什么不能写成 `pcall + 失败算通过`（本工程栽过的那种「逃生口」）：
   §9v.5/§9ah 记过同族教训 ——「连不上就当这条反向不适用」⇒ 判据静默失效却自己报 ✔。
   所以跳过必须满足三条：
     ① **探针可判定**：由一个明确的「环境是否具备」函数决定，**不是 catch 异常**；
     ② **看得见**：打印 ⊘ + 原因，并在汇总里单独计数（总数/通过/失败/跳过 都写出来）；
     ③ **不许吞路径**：探针成立时，断言必须**原样执行**（check_env 里只分岔一次）。
 还有第四条，由下面的自检守着：
     ④ **跳过机制本身也要被验** —— 否则「跳过」会变成新的假绿来源。
]]
local skipped = {}          -- 名 -> 原因（单独一张表，不混进 results）

local function check_env(name, probe, fn)
    local avail, why = probe()
    if avail ~= true then
        skipped[#skipped + 1] = { name = name, why = tostring(why or "环境不具备") }
        print(string.format("  ⊘ %-44s 跳过：%s", name, tostring(why)))
        return
    end
    return check(name, fn)
end

--- 自检：跳过机制**不能**变成逃生口。
--- 做法：喂一个恒为假的探针 + 一个「一执行就红」的函数体，要求
---   ① 结果只进 skipped、不进 results；② 函数体**完全没被执行**。
--- 这条不占断言编号（它是框架自检，与 verify_plan 的「合成用例」同性质）。
do
    local before_results = #results
    local before_skips = #skipped
    local body_ran = false
    local function fake_probe() return false, "（自检用的合成探针）" end
    -- 静默跑：临时把打印吞掉，别让自检在报告里插一行 ⊘
    local real_print = print
    print = function() end
    check_env("（自检）探针为假时只跳过、不执行", fake_probe, function()
        body_ran = true
        return false, "自检体不该被执行"
    end)
    print = real_print
    local ok_self = (not body_ran)
        and (#results == before_results)
        and (#skipped == before_skips + 1)
    if not ok_self then
        -- 机制坏了就**当失败登记**（它能掩盖判据，比某一条断言红更严重）
        results[#results + 1] = {
            name = "（框架自检）跳过机制不是逃生口",
            ok = false,
            info = string.format("body_ran=%s results %d→%d skipped %d→%d",
                tostring(body_ran), before_results, #results,
                before_skips, #skipped),
        }
    end
    skipped[#skipped] = nil          -- 自检占的位不留在汇总里
end

local function spawn(name)
    Universal.Install(Core)
    local ok, inst = pcall(Core.SpawnPrefab, name)
    Universal.Uninstall()
    -- ★ 容错：不是所有预制体都有 Transform。
    --   实测 `tophat_container`（纯容器）就没有 ——
    --   无条件 `inst.Transform:SetPosition(...)` 会在这里抛错，
    --   把「预制体生成成功了」这个事实掩盖成一条失败。
    if ok and inst ~= nil and type(inst.Transform) == "table" then
        pcall(function() inst.Transform:SetPosition(0, 0, 0) end)
    end
    return ok and inst or nil
end

local function wilson()
    Bootstrap.LoadPrefabFile("wilson")
    local w = spawn("wilson")
    return w
end

--=========================================================================
hr("TC1  OverrideSymbol 必须成对撤销（卸下后帽子不能留在画面上）")
--=========================================================================
check("装备→卸下：覆盖表归位、绘制表无残留", function()
    local w = wilson()
    if w == nil then return false, "wilson 生成失败" end
    Bootstrap.LoadPrefabFile("hats")
    local hat = spawn("footballhat")
    if hat == nil then return false, "footballhat 生成失败" end
    local as = w.AnimState

    local function counts()
        local ov, ob = 0, 0
        for _ in pairs(as._overrides) do ov = ov + 1 end
        for _ in pairs(as._ov_builds) do ob = ob + 1 end
        local dl = as:GetDrawList()
        local bld = 0
        if type(dl) == "table" then
            for _, el in ipairs(dl) do if el.bld ~= nil then bld = bld + 1 end end
        end
        return ov, ob, bld
    end

    -- ★ 基线取**装备前**：装备会让 _ov_builds +1（登记 hat_football），
    --   卸下应该正好退回这个基线。第一版拿「装备后」当基线，
    --   于是正确行为（23 → 22）被判成「没回到原值」——**断言自己写错了**。
    local ov_pre, ob_pre, _ = counts()
    w.components.inventory:GiveItem(hat)
    w.components.inventory:Equip(hat)
    local ov_on, ob_on, bld_on = counts()

    w.components.inventory:Unequip("head")
    for i = 1, 5 do Sim.Step() end
    local ov_off, ob_off, bld_off = counts()
    -- ★ 反向判据（T6）：卸下后装备槽必须真的空了。
    --   只看「覆盖清零」不够 —— 万一 Unequip 什么都没做，
    --   而覆盖又恰好被别处清了，断言会假通过。
    local eq = w.components.inventory.equipslots or {}
    if eq.head ~= nil then
        return false, "卸下后 head 槽里还有 " .. tostring(eq.head.prefab)
    end

    if bld_on < 1 then return false, "装备后 GetDrawList 没有 bld，覆盖本身没生效" end
    if ov_off > ov_on then
        return false, string.format("卸下后覆盖反而变多：%d → %d", ov_on, ov_off)
    end
    if bld_off ~= 0 then
        return false, string.format("卸下后 GetDrawList 仍有 %d 条带 bld 的条目（期望 0）", bld_off)
    end
    if ob_on - ob_pre ~= 1 then
        return false, string.format("装备后 _ov_builds %d→%d（期望 +1）", ob_pre, ob_on)
    end
    if ob_off ~= ob_pre then
        return false, string.format("卸下后 _ov_builds %d→%d，没有退回装备前的 %d",
            ob_on, ob_off, ob_pre)
    end
    return true, string.format("覆盖 %d→%d、ov_builds %d→%d→%d、绘制 bld %d→0",
        ov_on, ov_off, ob_pre, ob_on, ob_off, bld_on)
end)

--=========================================================================
hr("TC2  PrefabExists 必须「先懒加载再判」")
--=========================================================================
check("已存在的预制体，PrefabExists 返回 true", function()
    -- 样本用 fishmeat_small_cooked —— 它来自 tuning.lua:4513 的
    -- BURNED_LOOT_OVERRIDES（pondfish = "fishmeat_small_cooked"），
    -- 正是 lootdropper.lua:418 `PrefabExists(v.."_cooked")` 会去问的那类名字。
    -- （第一版用 cooked_meat，实测这个 DST 版本**没有**它 ⇒ 断言写错而不是代码错。）
    for _, name in ipairs({ "fishmeat_small_cooked", "seeds_cooked", "meat" }) do
        if not PrefabExists(name) then
            return false, string.format("PrefabExists(%q)=false（该名字应存在）", name)
        end
    end
    return true, "fishmeat_small_cooked / seeds_cooked / meat 均 true"
end)

check("不存在的名字，PrefabExists 返回 false", function()
    local r = PrefabExists("__no_such_prefab_xyz__")
    if r ~= false then
        return false, string.format("对不存在的名字返回了 %s（期望 false）", tostring(r))
    end
    return true, "正确返回 false"
end)

--=========================================================================
hr("TC3  stringutil 已加载 ⇒ talker 依赖的全局存在")
--=========================================================================
check("GetSpecialCharacterPostProcess 可调用且原样返回", function()
    if type(GetSpecialCharacterPostProcess) ~= "function" then
        return false, "全局不存在 —— 协程里的 talker 会静默死掉"
    end
    local r = GetSpecialCharacterPostProcess("pigman", "hello")
    if r ~= "hello" then
        return false, string.format("返回了 %s（该函数应原样返回）", tostring(r))
    end
    return true, "原样返回 hello"
end)

check("stringutil 定义的全局已就位（抽样）", function()
    -- 这几个都确实定义在 stringutil.lua（Umlautify:190 / CraftGiberish:112 /
    -- GetGenderStrings:51），不是编出来的名字。
    local names = { "ProcessString", "Umlautify", "CraftGiberish", "GetGenderStrings" }
    local missing = {}
    for _, n in ipairs(names) do
        if rawget(_G, n) == nil then missing[#missing + 1] = n end
    end
    if #missing > 0 then
        return false, "仍缺: " .. table.concat(missing, ", ")
    end
    return true, "4 个抽样全局都在"
end)

--=========================================================================
hr("TC4  GetTimeAlive + spawntime")
--=========================================================================
check("GetTimeAlive 随时间增长（不是恒 0）", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local t0 = p:GetTimeAlive()
    for i = 1, 120 do Sim.Step() end          -- 4 秒
    local t1 = p:GetTimeAlive()
    if type(t0) ~= "number" or type(t1) ~= "number" then
        return false, "返回的不是数字（仍是桩语义）"
    end
    if t1 - t0 < 3.5 then
        return false, string.format("4 秒只涨了 %.3f（spawntime 可能没赋值）", t1 - t0)
    end
    -- ★ 反向判据（T6）：**不该发生的事**——涨得比真实时间还多
    --   若 GetTimeAlive 走的是「每次调用累加」之类错实现，它会远大于 4。
    --   只测「涨了」会漏掉这种；加上上界才封闭。
    if t1 - t0 > 4.6 then
        return false, string.format("4 秒涨了 %.3f —— 超出真实时间，实现有问题", t1 - t0)
    end
    return true, string.format("%.3f → %.3f 秒（+%.3f，在 [3.5,4.6] 内）",
        t0, t1, t1 - t0)
end)

check("spawntime 在 NewEntity 时就被赋值", function()
    local e = Core.NewEntity("__spawntime_probe__")
    if e.spawntime == nil then
        return false, "spawntime 为 nil"
    end
    if type(e.spawntime) ~= "number" then
        return false, "spawntime 不是数字: " .. type(e.spawntime)
    end
    return true, string.format("spawntime=%.2f", e.spawntime)
end)

--=========================================================================
hr("TC5  Transform:SetTwoFaced")
--=========================================================================
check("SetTwoFaced 无参时切换，IsTwoFaced 同步", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local t = p.Transform
    if type(t.SetTwoFaced) ~= "function" then return false, "方法不存在（仍是桩）" end
    if type(t.IsTwoFaced) ~= "function" then return false, "IsTwoFaced 不存在" end
    local a = t:IsTwoFaced()
    t:SetTwoFaced()
    local b = t:IsTwoFaced()
    t:SetTwoFaced()
    local c = t:IsTwoFaced()
    if a == b or b == c then
        return false, string.format("切换无效 %s→%s→%s", tostring(a), tostring(b), tostring(c))
    end
    t:SetTwoFaced(true)
    if t:IsTwoFaced() ~= true then return false, "SetTwoFaced(true) 未生效" end
    return true, string.format("%s→%s→%s，且显式置 true 生效",
        tostring(a), tostring(b), tostring(c))
end)

--=========================================================================
hr("TC6  AnimState:OverrideShade")
--=========================================================================
check("OverrideShade 存值、GetShade 读回、nil 还原为 1", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.OverrideShade) ~= "function" then return false, "方法不存在（仍是桩）" end
    as:OverrideShade(0.35)
    local v = as:GetShade()
    if type(v) ~= "number" or math.abs(v - 0.35) > 1e-6 then
        as:OverrideShade(nil)
        return false, string.format("写入 0.35 读回 %s", tostring(v))
    end
    as:OverrideShade(nil)
    local v2 = as:GetShade()
    if type(v2) ~= "number" or math.abs(v2 - 1.0) > 1e-6 then
        return false, string.format("nil 未还原为 1，读回 %s", tostring(v2))
    end
    return true, "0.35 写入读回一致；nil 还原为 1"
end)

--=========================================================================
hr("TC7  birds 家族文件 ⇒ crow 能生成")
--=========================================================================
check("SpawnPrefab(\"crow\") 返回实体（不是静默 nil）", function()
    local c = spawn("crow")
    if c == nil then
        return false, "返回 nil —— birds 没进 DYNAMIC_FAMILY_FILES，或 crow 没注册"
    end
    for i = 1, 30 do Sim.Step() end
    local n = 0
    for _ in pairs(c._components) do n = n + 1 end
    return true, string.format("guid=%d 组件=%d build=%s", c._guid, n,
        tostring(c.AnimState and c.AnimState._build))
end)

check("mole 与 butterfly 也能生成（第二批新生物）", function()
    local bad = {}
    for _, n in ipairs({ "mole", "butterfly" }) do
        if spawn(n) == nil then bad[#bad + 1] = n end
    end
    if #bad > 0 then return false, "生成失败: " .. table.concat(bad, ", ") end
    return true, "两者都能生成"
end)

--=========================================================================
hr("TC8  缺 build 的计数口径（记在 GetDrawList 而非 OnMissing）")
--=========================================================================
check("Core.MissingBuildHits 按 GetDrawList 失败次数累加", function()
    local w = wilson()
    if w == nil then return false, "wilson 生成失败" end
    local as = w.AnimState
    local missing = "__definitely_missing_build_zzz__"
    as._build = missing
    as._real = false
    for _ = 1, 3 do as:GetDrawList() end        -- 故意失败 3 次

    local hits = Core.MissingBuildHits
    if type(hits) ~= "table" then
        return false, "Core.MissingBuildHits 不存在（计数还挂在 OnMissing 上，恒为 1）"
    end
    local n = hits[missing] or 0
    if n < 3 then
        return false, string.format("失败 3 次但只记了 %d 次", n)
    end
    return true, string.format("失败 3 次 → 记了 %d 次", n)
end)

--=========================================================================
hr("TC9  本轮新补的渲染/声音接口")
--=========================================================================
check("SetAddColour 存的是「加色」且可清", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.SetAddColour) ~= "function" then return false, "方法不存在（仍是桩）" end
    as:SetAddColour(1, 0.5, 0.2, 1)
    local r, g, b, a = as:GetAddColour()
    if math.abs(r - 1) > 1e-6 or math.abs(g - 0.5) > 1e-6 or math.abs(b - 0.2) > 1e-6 then
        as:ClearAddColour()
        return false, string.format("写入 (1,0.5,0.2) 读回 (%.3f,%.3f,%.3f)", r, g, b)
    end
    as:ClearAddColour()
    local r2 = as:GetAddColour()
    if r2 ~= nil then as:ClearAddColour(); return false, "ClearAddColour 后仍有值" end
    return true, "写入读回一致；ClearAddColour 生效"
end)

check("SetHaunted 无参切换、显式置位", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.SetHaunted) ~= "function" then return false, "方法不存在（仍是桩）" end
    local a = as:IsHaunted()
    as:SetHaunted()
    local b = as:IsHaunted()
    as:SetHaunted(true)
    local c = as:IsHaunted()
    if a == b or c ~= true then
        return false, string.format("%s→%s→%s", tostring(a), tostring(b), tostring(c))
    end
    as:SetHaunted(false)
    if as:IsHaunted() ~= false then return false, "SetHaunted(false) 未生效" end
    return true, string.format("%s→%s，true/false 均生效", tostring(a), tostring(b))
end)

check("Transform:SetScale 与 GetScale 成对", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local t = p.Transform
    if type(t.SetScale) ~= "function" then return false, "方法不存在（仍是桩）" end
    t:SetScale(2.5)
    if math.abs(t:GetScale() - 2.5) > 1e-6 then
        return false, "SetScale(2.5) 后 GetScale=" .. tostring(t:GetScale())
    end
    t:SetScale()
    if math.abs(t:GetScale() - 1) > 1e-6 then
        return false, "无参 SetScale 未还原为 1（得到 " .. tostring(t:GetScale()) .. "）"
    end
    return true, "2.5 写入读回一致；无参还原为 1"
end)

check("SoundEmitter:SetParameter / GetParameter", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local se = p.SoundEmitter
    if se == nil then return false, "没有 SoundEmitter" end
    if type(se.SetParameter) ~= "function" then return false, "方法不存在（仍是桩）" end
    se:SetParameter("pitch", 0.7)
    if se:GetParameter("pitch") ~= 0.7 then
        return false, "写入 0.7 读回 " .. tostring(se:GetParameter("pitch"))
    end
    return true, "pitch=0.7 写入读回一致"
end)

check("TALKINGFONT 全局存在（talker.lua:161 依赖）", function()
    if rawget(_G, "TALKINGFONT") == nil then
        return false, "缺失 —— 协程里的 talker 会静默死掉"
    end
    return true, "TALKINGFONT = " .. tostring(rawget(_G, "TALKINGFONT"))
end)

--=========================================================================
hr("TC10  渲染次序 / 朝向 / 辉光 / 休眠保留（本轮由 batch.lua 的桩清单带出）")
--=========================================================================
local function pig()
    Bootstrap.LoadPrefabFile("pigman")
    return spawn("pigman")
end

check("SetLayer 与 GetLayer 成对，且同步进符号表", function()
    local p = pig()
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.SetLayer) ~= "function" then return false, "方法不存在（仍是桩）" end
    as:SetLayer(3)
    if as:GetLayer() ~= 3 then
        return false, "写入 3 读回 " .. tostring(as:GetLayer())
    end
    as:SetLayer()
    if as:GetLayer() ~= 0 then
        return false, "无参 SetLayer 未还原为 0（得到 " .. tostring(as:GetLayer()) .. "）"
    end
    return true, "3 写入读回一致；无参还原为 0"
end)

check("SetSortOrder 与 GetSortOrder 成对（跨实体绘制次序）", function()
    local p = pig()
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.SetSortOrder) ~= "function" then return false, "方法不存在（仍是桩）" end
    as:SetSortOrder(7)
    if as:GetSortOrder() ~= 7 then
        return false, "写入 7 读回 " .. tostring(as:GetSortOrder())
    end
    as:SetSortOrder()
    if as:GetSortOrder() ~= 0 then return false, "无参未还原为 0" end
    return true, "7 写入读回一致；无参还原为 0"
end)

check("SetOrientation 切换镜像朝向", function()
    local p = pig()
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.SetOrientation) ~= "function" then return false, "方法不存在（仍是桩）" end
    local a = as:GetOrientation()
    as:SetOrientation()
    local b = as:GetOrientation()
    if a == b then return false, string.format("无参未翻转 %s→%s", tostring(a), tostring(b)) end
    as:SetOrientation(false)
    if as:GetOrientation() ~= false then return false, "SetOrientation(false) 未生效" end
    return true, string.format("%s→%s；显式 false 生效", tostring(a), tostring(b))
end)

check("SetSymbolBloom / ClearSymbolBloom 成对（清得干净）", function()
    local p = pig()
    if p == nil then return false, "pigman 生成失败" end
    local as = p.AnimState
    if type(as.SetSymbolBloom) ~= "function" or type(as.ClearSymbolBloom) ~= "function" then
        return false, "方法不存在（仍是桩）"
    end
    as:SetSymbolBloom("head", 0.8)
    if as:GetSymbolBloom("head") ~= 0.8 then
        return false, "写入 0.8 读回 " .. tostring(as:GetSymbolBloom("head"))
    end
    as:ClearSymbolBloom("head")
    if as:GetSymbolBloom("head") ~= nil then
        return false, "Clear 后仍有值 " .. tostring(as:GetSymbolBloom("head"))
    end
    return true, "0.8 写入读回一致；Clear 后归 nil"
end)

check("Physics:SetDontRemoveOnSleep 标志可置可清", function()
    local p = pig()
    if p == nil then return false, "pigman 生成失败" end
    local ph = p.Physics
    if ph == nil then return false, "没有 Physics" end
    if type(ph.SetDontRemoveOnSleep) ~= "function" then return false, "方法不存在（仍是桩）" end
    ph:SetDontRemoveOnSleep(true)
    if ph:IsDontRemoveOnSleep() ~= true then return false, "置 true 未生效" end
    ph:SetDontRemoveOnSleep(false)
    if ph:IsDontRemoveOnSleep() ~= false then return false, "置 false 未生效" end
    return true, "true / false 均生效"
end)

--=========================================================================
hr("TC11  TheCamera（砍树收尾链依赖它，曾是泛化桩）")
--=========================================================================
check("GetRightVec / GetDownVec 返回真向量（不是 nil）", function()
    if type(rawget(_G, "TheCamera")) ~= "table" then
        return false, "TheCamera 不是表"
    end
    local r = TheCamera:GetRightVec()
    if type(r) ~= "table" then
        return false, "GetRightVec 返回 " .. type(r) .. "（应为 Vector3）"
    end
    -- heading=0 ⇒ right = 90° ⇒ (cos90, 0, sin90) = (0, 0, 1)
    if math.abs(r.x or 99) > 1e-6 or math.abs((r.y or 99)) > 1e-6
        or math.abs((r.z or 99) - 1) > 1e-6 then
        return false, string.format("heading=0 时 GetRightVec=(%.3f,%.3f,%.3f)，期望 (0,0,1)",
            r.x or -1, r.y or -1, r.z or -1)
    end
    return true, "heading=0 → (0, 0, 1) ✔"
end)

check("改 heading 后方向跟着转（不是硬编码）", function()
    TheCamera:SetHeadingTarget(0)
    local a = TheCamera:GetRightVec()
    TheCamera:SetHeadingTarget(90)
    local b = TheCamera:GetRightVec()
    TheCamera:SetHeadingTarget(0)          -- 还原，别影响后续
    local changed = (math.abs((a.x or 0) - (b.x or 0)) > 1e-6) or
                    (math.abs((a.z or 0) - (b.z or 0)) > 1e-6)
    if not changed then
        return false, string.format("heading 0 与 90 结果相同 (%.3f,%.3f)",
            a.x or -1, a.z or -1)
    end
    return true, string.format("heading 0→90：x %.3f→%.3f，z %.3f→%.3f",
        a.x or 0, b.x or 0, a.z or 0, b.z or 0)
end)

check("Vector3:Dot / :Cross 遇 nil 不崩（收尾链的保险）", function()
    if type(G) == "table" and rawget(_G, "Vector3") == nil then
        return false, "Vector3 全局缺失"
    end
    local V = rawget(_G, "Vector3")
    if V == nil then
        return false, "Vector3 全局缺失"
    end
    local v = V(1, 0, 0)
    local okd = pcall(function() return v:Dot(nil) end)
    local okc = pcall(function() return v:Cross(nil) end)
    if not (okd and okc) then
        return false, string.format("Dot(nil) ok=%s / Cross(nil) ok=%s",
            tostring(okd), tostring(okc))
    end
    return true, "两者遇 nil 均安全返回（不抛）"
end)

--=========================================================================
hr("TC12  TheFocalPoint（应是「玩家实体」，不是假表）")
--=========================================================================
check("默认是 nil（与原版 main.lua:330 一致，不是造一张假表）", function()
    local fp = rawget(_G, "TheFocalPoint")
    if fp ~= nil then
        return false, "初始应为 nil，实���是 " .. type(fp) ..
            "（造了假表就会让 lightning.lua 的 nil 判断永远不成立）"
    end
    return true, "TheFocalPoint = nil ✔"
end)

check("SetFocalPoint 绑定真实实体后可用", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local okf = SetFocalPoint(p)
    -- 用完还原成 nil，不影响后续
    SetFocalPoint(nil)
    if not okf then
        -- 实体没有 SoundEmitter 时应当拒绝绑定，而不是绑上一个坏引用
        local fp = rawget(_G, "TheFocalPoint")
        if fp == nil then
            return true, "实体无 SoundEmitter ⇒ 正确拒绝绑定，保持 nil"
        end
        return false, "无 SoundEmitter 却仍绑定了 " .. tostring(fp)
    end
    return true, "绑定成功（guid=" .. tostring(p._guid) .. "），已还原为 nil"
end)

check("绑定后 TheFocalPoint.SoundEmitter 是真对象", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    local okf = SetFocalPoint(p)
    local fp = rawget(_G, "TheFocalPoint")
    local verdict
    if not okf then
        SetFocalPoint(nil)
        return true, "该实体无 SoundEmitter ⇒ 未绑定（符合设计）"
    -- ★ 判据必须读 `_G`（游戏读的那一份），不能只读 G 暂存表
    elseif rawget(_G, "TheFocalPoint") == p and type(fp.SoundEmitter) == "table" then
        verdict = true
    else
        verdict = false
    end
    SetFocalPoint(nil)
    if verdict then return true, "TheFocalPoint 就是该实体，且带 SoundEmitter" end
    return false, "绑定后形状不对"
end)

--=========================================================================
hr("TC13  World:GetPocketDimensionContainer（hats.lua:7509 无条件调它）")
--=========================================================================
check("方法存在，且未注册时返回 nil（与 DST 语义一致）", function()
    if type(TheWorld) ~= "table" then return false, "TheWorld 不可用" end
    if type(TheWorld.GetPocketDimensionContainer) ~= "function" then
        return false, "方法不存在 —— hats.lua:7509 / chester.lua:383 会崩"
    end
    local r = TheWorld:GetPocketDimensionContainer("shadow")
    if r ~= nil then
        return false, "未注册却返回了 " .. tostring(r)
    end
    return true, "存在且未注册时返回 nil ✔"
end)

check("Create 之后 Get 能读回（成对）", function()
    local sentinel = { _probe = true }
    TheWorld:CreatePocketDimensionContainer("__probe__", sentinel)
    local r = TheWorld:GetPocketDimensionContainer("__probe__")
    -- ⚠️ 这里是**点号**不是冒号：`TheWorld:PocketDimensionContainers[...]`
    --   会被解析成「用冒号调一个叫 PocketDimensionContainers 的方法」⇒
    --   `function arguments expected near '['`。
    --   冒号只用于**方法调用**（TheWorld:GetPocketDimensionContainer），
    --   字段索引一律用点号。
    TheWorld.PocketDimensionContainers["__probe__"] = nil
    if r ~= sentinel then
        return false, "写入后读回 " .. tostring(r)
    end
    return true, "写入读回同一对象 ✔（并已清理）"
end)

check("tophat_container 能生成（这条路径曾因缺方法而崩）", function()
    Bootstrap.LoadPrefabFile("hats")
    local h = spawn("tophat_container")
    if h == nil then
        return false, "返回 nil —— 修复前是 GetPocketDimensionContainer 缺失"
    end
    local n = 0
    for _ in pairs(h._components) do n = n + 1 end
    return true, string.format("guid=%d 组件=%d", h._guid, n)
end)

--=========================================================================
hr("TC14  家族文件覆盖（静态扫出来的，不是逐个撞出来的）")
--=========================================================================
check("farm_plants 的产物 berries 可达（采摘要靠它）", function()
    if not PrefabExists("berries") then
        return false, "berries 不可达 —— 采摘会「返回成功但什么都拿不到」"
    end
    -- 反向判据：它必须真的能生成实体，而不只是「表里有名字」
    local b = spawn("berries")
    if b == nil then
        return false, "在注册表里但 SpawnPrefab 返回 nil"
    end
    return true, "PrefabExists=true 且能生成实体 ✔"
end)

check("hats / meats / birds 三类家族文件的关键预制体都可达", function()
    local need = { "footballhat", "cookedmeat", "crow" }
    local bad = {}
    for _, n in ipairs(need) do
        if not PrefabExists(n) then bad[#bad + 1] = n end
    end
    if #bad > 0 then
        return false, "不可达: " .. table.concat(bad, ", ")
    end
    return true, "footballhat / cookedmeat / crow 均可达 ✔"
end)

--=========================================================================
hr("TC15  本轮新增修复（VFXEffect / knownlocations / netvar 初值 / 降级代理）")
--=========================================================================
check("AddVFXEffect 返回可链式调用的对象（rain/eyeflame 依赖）", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    if type(p.entity.AddVFXEffect) ~= "function" then
        return false, "AddVFXEffect 不存在"
    end
    local fx = p.entity:AddVFXEffect()
    if type(fx) ~= "table" then
        return false, "返回 " .. type(fx) .. "（应可接住链式调用）"
    end
    -- ★ 关键：**任意**方法名都要接得住（代理法，不是枚举法）
    local r = fx:InitEmitters(1)
    if r ~= fx then return false, "InitEmitters 未返回 self，链式会断" end
    local okc = pcall(function()
        fx:SetRenderResources(0, "T", "S"):SetRotationStatus(0, true)
          :SetMaxNumParticles(0, 5):SomeUnheardOfMethod(1, 2, 3)
    end)
    if not okc then return false, "链式调用中抛错" end
    return true, "任意方法名均接得住（含 DST 里没有的）"
end)

check("knownlocations 是引擎默认组件（不需 prefab 自己加）", function()
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil then return false, "pigman 生成失败" end
    -- pigman **没有** AddComponent("knownlocations")，但必须能读到
    if p.components.knownlocations == nil then
        return false, "缺 knownlocations（caveventmitebrain / alterguardian_phase2brain 会崩）"
    end
    local okc = pcall(function()
        p.components.knownlocations:RememberLocation("__probe__", p:GetPosition())
    end)
    if not okc then return false, "组件存在但调用抛错" end
    return true, "存在且 RememberLocation 可用 ✔"
end)

check("netvar 未显式设初值时为类型零值（不是 nil）", function()
    local v = net_float(0, "__probe__", "probe")
    if v:value() == nil then
        return false, "net_float 无 default 时读出 nil（fireflies 的 compare nil 就是这么来的）"
    end
    local b = net_bool(0, "__probe_b__", "probe")
    if b:value() == nil then
        return false, "net_bool 无 default 时读出 nil"
    end
    return true, string.format("net_float=%s  net_bool=%s", tostring(v:value()),
        tostring(b:value()))
end)

check("event_server_data 降级表能接住任意 *_postinit（代理法）", function()
    if type(event_server_data) ~= "function" then
        return false, "全局不存在"
    end
    local mod = event_server_data("__no_such_event__", "prefabs/__probe__")
    if type(mod) ~= "table" then return false, "返回 " .. type(mod) end
    -- ★ 关键：不只是 master_postinit，任何 *_postinit 都要接得住
    local names = { "master_postinit", "postinit", "projectile_postinit",
                    "master_postinit_item", "hitfx_postinit", "goospit_postinit",
                    "SomeEntirelyUnknownPostinit" }
    local bad = {}
    for _, n in ipairs(names) do
        if type(mod[n]) ~= "function" then bad[#bad + 1] = n end
    end
    if #bad > 0 then
        return false, "接不住: " .. table.concat(bad, ", ")
    end
    return true, string.format("%d 个名字全部可调用（含未知名字）", #names)
end)

--=========================================================================
hr("TC16  引擎默认组件与结构（防「文件恢复不完整」这类回退）")
--=========================================================================
check("每个实体在 NewEntity 就有 replica（不能惰性创建）", function()
    -- ★ 这一条是**回归守卫**：2026-10-15 我误把 01_core.lua 截断、
    --   又用更早的备份恢复时，把 `inst.replica = make_replica(inst)`
    --   这条修复**静默丢掉了** —— 编译通过、大部分入口照过，
    --   只有两天长局在 4.33 s 时崩在
    --       combat_replica.lua:302: attempt to index field 'replica' (a nil value)
    --   因为 `FindEntity` 会把「没有任何组件的实体」也当候选目标。
    --   ⇒ 必须有断言直接盯住「裸实体也有 replica」这件事。
    local e = Core.NewEntity("__naked_no_components__")
    if e.replica == nil then
        return false, "裸实体没有 replica ⇒ FindEntity 选中它会崩"
    end
    if type(e.replica) ~= "table" then
        return false, "replica 类型是 " .. type(e.replica)
    end
    if e.replica.inst ~= e then
        return false, "replica.inst 没指回实体"
    end
    return true, "裸实体也有 replica，且 replica.inst 正确 ✔"
end)

check("knownlocations 在裸实体上也可用（引擎默认组件）", function()
    local e = Core.NewEntity("__naked2__")
    if e.components.knownlocations == nil then
        return false, "缺 knownlocations"
    end
    return true, "裸实体也有 knownlocations ✔"
end)

--=========================================================================
hr("TC17  引擎子对象（entity:AddXxx）覆盖 —— 用静态扫描找出来的，不是猜的")
--=========================================================================
check("游戏代码用到的 entity:AddXxx 宿主全部有", function()
    -- ★ 这 12 个是**静态扫描**发现的：把游戏代码里所有 `entity:AddXxx(` 收集起来
    --   （27 种），减去宿主已实现的（19 种），差集就是缺的。
    --   **不靠猜名字** —— 今天「猜名字」已错 9 次以上
    --   （`AddGroundCreep` vs `AddGroundCreepEntity` 就是最近一次）。
    local need = {
        "AddGroundCreepEntity", "AddClientSleepable", "AddServerNonSleepable",
        "AddLabel", "AddWaveComponent", "AddDebugRender",
        "AddMap", "AddMiniMap", "AddUITransform", "AddPathfinder",
        "AddShardClient", "AddShardNetwork",
    }
    local e = Core.NewEntity("__child_probe__")
    local bad = {}
    for _, m in ipairs(need) do
        if type(e.entity[m]) ~= "function" then bad[#bad + 1] = m end
    end
    if #bad > 0 then
        return false, "缺 " .. #bad .. " 个: " .. table.concat(bad, ", ")
    end
    return true, string.format("%d 个方法全部存在", #need)
end)

check("子对象是代理：任意方法可链式调用", function()
    local e = Core.NewEntity("__child_probe2__")
    local okc, r = pcall(function()
        local o = e.entity:AddGroundCreepEntity()
        if type(o) ~= "table" then error("返回 " .. type(o)) end
        -- 任意方法名都要接得住、且可链式
        return o:SetRadius(5):SomeUnknownMethod(1):Another()
    end)
    if not okc then return false, "链式调用抛错: " .. tostring(r):sub(1, 80) end
    return true, "任意方法名可链式调用 ✔"
end)

check("每个实体拿到的子对象是**同一个**（不是每次新建）", function()
    local e = Core.NewEntity("__child_probe3__")
    local a = e.entity:AddMiniMap()
    local b = e.entity:AddMiniMap()
    if a ~= b then
        return false, "两次调用返回不同对象 —— 状态会丢"
    end
    return true, "两次调用返回同一对象 ✔"
end)

--=========================================================================
hr("TC18  本轮（可达性抽样第三轮）新修 —— 每一条都先有失败样本再修")
--=========================================================================
-- ★ 这一组的来源与前 17 组不同：
--   前 17 组多是「读代码发现不对劲」；
--   这一组全部来自 **reachability.lua 抽样**（1000 个预制体逐个 spawn），
--   每一条都对应一个**真实失败样本**，修完再从同一样本上复验。
--   所以这些断言不是「我觉得该这样」，而是「曾经真的这样挂过」。

check("AtlasContains 真的查索引（不是一律 false）", function()
    local Sim = require("host.02_sim")
    local T = Sim.TheSim
    if type(T.AtlasContains) ~= "function" then
        return false, "方法不存在"
    end
    -- ★ 正向：spear.tex 确实在 images/inventoryimages.xml 里（导出索引里有）
    local hit = T:AtlasContains("images/inventoryimages.xml", "spear.tex")
    -- ★ 反向判据：不存在的东西必须返回 false（否则就是「一律 true」的假实现）
    local miss = T:AtlasContains("images/inventoryimages.xml", "__no_such_image__.tex")
    if hit ~= true then
        return false, "已知存在的 spear.tex 没查到 —— 索引或查询有问题"
    end
    if miss ~= false then
        return false, "不存在的名字也返回真 —— 这是假实现"
    end
    -- ★ 未导出的图集必须返回 false 而不是抛错
    local unk = T:AtlasContains("images/__no_such_atlas__.xml", "x.tex")
    if unk ~= false then return false, "未知图集没有返回 false" end
    return true, "spear.tex 命中 / 不存在项 false / 未知图集 false ✔"
end)

check("sg:HasState 存在，且查的是**定义表**不是当前状态", function()
    local e = Core.NewEntity("__sg_hasstate__")
    local sg = e.sg
    if type(sg) ~= "table" then return false, "e.sg 不是表" end
    if type(sg.HasState) ~= "function" then
        return false, "HasState 不存在 —— corpses 系列会栽（componentutil.lua:942）"
    end
    -- 裸实体的兜底 sg：self.sg 为 nil ⇒ 必须返回 false 且不抛错
    local okc, r = pcall(function() return sg:HasState("electrocute") end)
    if not okc then return false, "调用抛错: " .. tostring(r):sub(1, 60) end
    if r ~= false then
        return false, "空 sg 上 HasState 返回 " .. tostring(r) .. "（应为 false）"
    end
    return true, "HasState 可调用、空 sg 返回 false ✔"
end)

check("WORLDSTATETAGS 可用：SetTagEnabled / GetTagEnabled 往返", function()
    local W = _G.WORLDSTATETAGS
    if type(W) ~= "table" then return false, "WORLDSTATETAGS 不是表" end
    if type(W.SetTagEnabled) ~= "function" or type(W.GetTagEnabled) ~= "function" then
        return false, "缺 SetTagEnabled / GetTagEnabled"
    end
    -- ★★ 这里是**点号调用**而不是冒号！
    --   原版 mainfunctions.lua 里它们是 `local function GetTagEnabled(tag)`
    --   —— **普通函数**，只是被挂到 object 上，第一参数不是 self。
    --   DST 自己的调用点也全是点号（archivemanager.lua:44 等）。
    --   我第一版写成 `W:GetTagEnabled(TAG)` ⇒ self 被当成 tag ⇒
    --   `TAGS[<表>]` 为 nil ⇒ 「attempt to index field '?'」。
    --   ⇒ 断言写错会伪装成「宿主有 bug」，所以这条注释留在断言里。
    local TAG = "CELESTIAL_ORB_FOUND"
    local before = W.GetTagEnabled(TAG)
    W.SetTagEnabled(TAG, true)
    local on = W.GetTagEnabled(TAG)
    W.SetTagEnabled(TAG, false)
    local off = W.GetTagEnabled(TAG)
    W.SetTagEnabled(TAG, before == true)      -- 还原，别污染后续断言
    if on ~= true then return false, "置真后读回 " .. tostring(on) end
    if off ~= false then return false, "置假后读回 " .. tostring(off) end
    return true, "真/假往返正确（点号调用）✔"
end)

check("WORLDSTATETAGS 是**从真实文件切出来**的（不是照抄副本）", function()
    local WST = require("host.24_worldstatetags")
    if WST.SourceText == nil then
        return false, "没有记录切出来的源码段"
    end
    if not WST.SourceText:find("CreateWorldStateTag", 1, true) then
        return false, "切出来的段里没有 CreateWorldStateTag —— 锚点可能失效"
    end
    if not WST.SourceText:find("WORLDSTATETAGS.Lock()", 1, true) then
        return false, "切出来的段没到 Lock() —— 标签声明被截断了"
    end
    return true, string.format("切出 %d 字节 / %d~%d 行 ✔",
        WST.ByteLen or 0, WST.LineFrom or 0, WST.LineTo or 0)
end)

check("EnvelopeManager 存在且方法可调用", function()
    local EM = _G.EnvelopeManager
    if type(EM) ~= "table" then return false, "EnvelopeManager 不是表" end
    local okc, r = pcall(function()
        return EM:AddColourEnvelope("__test_env__") and EM:AddVector()
    end)
    if not okc then return false, "调用抛错: " .. tostring(r):sub(1, 60) end
    -- 代理必须**记账**（可观测），否则就是「静默空实现」
    if type(EM._calls) ~= "table" or (EM._calls.AddColourEnvelope or 0) < 1 then
        return false, "调用没有被记进 _calls —— 不可观测"
    end
    return true, string.format("可调用且已记账（%d 个方法被记）✔", (function()
        local n = 0; for _ in pairs(EM._calls) do n = n + 1 end; return n
    end)())
end)

check("RoadManager:IsOnRoad 返回 false（不能是链式代理的真值）", function()
    local RM = _G.RoadManager
    if type(RM) ~= "table" then return false, "RoadManager 不是表" end
    local r = RM:IsOnRoad(0, 0, 0)
    if r ~= false then
        -- ★ 反向判据：真值会让**所有**生物在所有地块上获得道路加速
        return false, "IsOnRoad 返回 " .. tostring(r) .. "（真值＝系统性加速错误）"
    end
    return true, "恒 false ✔（宿主无道路条带系统，语义正确）"
end)

check("prefabskin 全局空表齐全（静态提取，不是手写清单）", function()
    local PSG = require("host.27_prefabskin_globals")
    local okc, missing = PSG.Audit()
    if not okc then
        return false, "缺 " .. table.concat(missing, ", ")
    end
    if #PSG.Names == 0 then
        return false, "一条都没提取到 —— 锚点失效"
    end
    return true, string.format("提取 %d 张、全部在位 ✔", #PSG.Names)
end)

check("Ents 与 Core.Spawned 是**同一张表**（别名，不是拷贝）", function()
    if _G.Ents ~= Core.Spawned then
        return false, "Ents 不是 Core.Spawned 本身 —— 两份表会不同步"
    end
    -- ★ 反向判据：写进 Ents 必须能被 Core.Spawned 看到
    local probe = Core.NewEntity("__ents_alias__")
    local seen = (_G.Ents[probe.GUID] ~= nil)
    local okc, r = pcall(function() probe:Remove() end)
    if not seen then return false, "写进 Spawned 的实体在 Ents 里看不到" end
    return true, "同一张表、双向可见 ✔"
end)

check("Light 的数值 getter 不返回 nil", function()
    local e = Core.NewEntity("__light_num__")
    e.entity:AddLight()
    local L = e.Light
    if type(L) ~= "table" then return false, "Light 不是表" end
    for _, m in ipairs({ "GetIntensity", "GetFalloff", "GetRadius" }) do
        local v = L[m] and L[m](L)
        if type(v) ~= "number" then
            return false, m .. " 返回 " .. type(v) .. "（算术会崩）"
        end
    end
    return true, "三个数值 getter 都返回数字 ✔"
end)

check("InGamePlay() 为真（宿主没有前端，起来就是在对局中）", function()
    if type(_G.InGamePlay) ~= "function" then
        return false, "InGamePlay 不存在 —— worldmigrator.lua:109 会崩"
    end
    if _G.InGamePlay() ~= true then
        return false, "返回了非真值"
    end
    return true, "返回 true ✔"
end)

check("Profile 的 Get 返回 nil（走调用方的默认值分支）", function()
    local P = _G.Profile
    if type(P) ~= "table" then return false, "Profile 不是表" end
    -- ★ 反向判据：不能返回**表**，否则 SCREEN_FLASH_SCALING[表] = nil ≠ 默认值 1
    local v = P:GetScreenFlash()
    if v ~= nil then
        return false, "GetScreenFlash 返回 " .. type(v) .. "（应为 nil）"
    end
    if P:IsFavorite("x") ~= false then
        return false, "Is* 系列应返回 false"
    end
    if type(P.SetScreenShakeEnabled) ~= "function" then
        return false, "Set* 系列不存在"
    end
    return true, "Get→nil / Is→false / Set 可调用 ✔"
end)

check("世界有 ambientlighting 组件（light watcher 依赖它）", function()
    local W = _G.TheWorld
    if W == nil or W.components == nil then return false, "TheWorld 不存在" end
    local a = W.components.ambientlighting
    if a == nil then
        return false, "缺 ambientlighting —— moon_fissure.lua:49 会崩"
    end
    if type(a.GetVisualAmbientValue) ~= "function" then
        return false, "组件在但没有 GetVisualAmbientValue"
    end
    local v = a:GetVisualAmbientValue()
    if type(v) ~= "number" then
        return false, "GetVisualAmbientValue 返回 " .. type(v) .. "（应为数字）"
    end
    return true, string.format("在位，环境亮度 = %.3f ✔", v)
end)

check("抽样修过的预制体全部可生成（回归锁）", function()
    -- ★ 这 5 个分别对应本轮修的 5 类根因，逐个 spawn 一遍。
    --   任一挂掉都说明某条修复被回退了。
    local CASES = {
        { "moonrockseed",                   "WORLDSTATETAGS" },
        { "cave_entrance",                  "InGamePlay" },
        { "scarecrow",                      "prefabskin 全局空表" },
        { "moon_fissure",                   "ambientlighting + Light 数值默认值" },
        { "carnivalgame_shooting_kit_placer", "vecutil" },
    }
    -- ★ 最后一个预制体由 `carnivalgame_shooting.lua` 注册，
    --   而 PrefabExists 的惰性索引不一定覆盖到它（宿主按名字猜候选文件）。
    --   这里显式把那个文件加载进来 —— 否则断言会在**无关**的原因上失败。
    require("host.05_bootstrap").LoadPrefabFile("carnivalgame_shooting")
    local bad = {}
    for _, c in ipairs(CASES) do
        local nm, why = c[1], c[2]
        if not PrefabExists(nm) then
            bad[#bad + 1] = nm .. "（未注册）"
        else
            local okc, inst = pcall(SpawnPrefab, nm)
            if not okc then
                bad[#bad + 1] = nm .. "（抛错）"
            elseif inst == nil then
                bad[#bad + 1] = nm .. "（返回 nil）"
            else
                pcall(function() inst:Remove() end)
            end
        end
    end
    if #bad > 0 then
        return false, "失败: " .. table.concat(bad, ", ")
    end
    return true, string.format("%d 个全部可生成 ✔", #CASES)
end)

check("边界登记表自检通过，且**不过度声称**", function()
    local B = require("host.26_boundaries")
    local okc, problems = B.Audit()
    if not okc then
        return false, "自检不过: " .. table.concat(problems, "; "):sub(1, 80)
    end
    -- ★ 反向判据：没登记过的名字必须返回「未定性」，不能凭空空泛归类
    local cls = B.Explain("__definitely_not_registered__", {})
    if cls ~= "未定性 —— 必须去查" then
        return false, "未登记的名字被归成「" .. tostring(cls) .. "」—— 过度声称"
    end
    local nc, nr = B.Count()
    return true, string.format("%d 个案 / %d 规则；未登记项正确返回「未定性」✔",
        nc, nr)
end)

--=========================================================================
hr("TC19  真实 ACTIONS / 账号对象 / 世界根登记（第三轮后半场）")
--=========================================================================
-- ★ 这一组是**修完前一组之后才暴露的**：ACTIONS 换真表 ⇒ 触发 giftreceiver
--   的数值比较 ⇒ 打挂 burn/perish/mech 三个入口。
--   ⇒ 「改完必须跑全量回归」不是形式主义。

check("ACTIONS 是**真实表**（≥200 个动作，且字段齐）", function()
    local A = _G.ACTIONS
    if type(A) ~= "table" then return false, "ACTIONS 不是表" end
    local n = 0
    for _ in pairs(A) do n = n + 1 end
    if n < 200 then
        return false, string.format("只有 %d 个动作 —— actions.lua 没加载成功", n)
    end
    local toss = A.TOSS
    if type(toss) ~= "table" then return false, "ACTIONS.TOSS 不是表" end
    if toss.distance ~= 8 then
        return false, "ACTIONS.TOSS.distance = " .. tostring(toss.distance)
            .. "（原版 actions.lua:363 是 8）"
    end
    if A.CHOP.distance ~= 1.75 then
        return false, "ACTIONS.CHOP.distance = " .. tostring(A.CHOP.distance)
    end
    return true, string.format("%d 个动作；TOSS.distance=8 / CHOP.distance=1.75 ✔", n)
end)

check("ACTIONS 惰性兜底仍在（未知动作名要造得出来）", function()
    -- ★ 反向判据：真表替换掉宿主小表之后，
    --   finiteuses.lua:30 `self.consumption[ACTIONS.XXX]` 一旦拿到 nil 就崩。
    -- ⚠️ 名字**不能**用下划线开头：宿主的惰性表一律 `if k:match("^_") then return nil`
    --    以免拦截内部字段。我第一版写成 `ACTIONS.__xxx` ⇒ 拿到 nil ⇒
    --    断言误报「兜底被覆盖」。**又是判据错，不是代码错**。
    local a = _G.ACTIONS.ZZZ_NOT_A_REAL_ACTION
    if type(a) ~= "table" then
        return false, "未知动作名返回 " .. type(a) .. " —— 惰性兜底被真表覆盖掉了"
    end
    if type(a.GetActionType) ~= "function" then
        return false, "兜底对象缺 GetActionType"
    end
    return true, "未知名字仍返回可用的动作对象 ✔"
end)

check("TheInventory 的 **数值型** getter 返回数字（不能是 nil）", function()
    local TI = _G.TheInventory
    if type(TI) ~= "table" then return false, "TheInventory 不是表" end
    -- ★★ 这条断言是被一次真实回归逼出来的：
    --   `GetClientGiftCount` 返回 nil ⇒ giftreceiver.lua:17 `giftcount > 0`
    --   报 "attempt to compare nil with number" ⇒ 把 mech/burn/perish
    --   三个入口的 Sim.Step 打断，world.lua 的轨迹也变成 0 个点。
    local v = TI:GetClientGiftCount("__test_userid__")
    if type(v) ~= "number" then
        return false, "GetClientGiftCount 返回 " .. type(v) .. "（下游会做比较/算术）"
    end
    if TI:HasSupportForOfflineSkins() ~= false then
        return false, "Has* 应返回 false（宿主没有离线皮肤数据）"
    end
    return true, string.format("Count→%s（数字）/ Has→false ✔", tostring(v))
end)

check("世界根预制体被**自动登记**（不靠名字清单也不靠反射）", function()
    local Core_ = require("host.01_core")
    local BS = require("host.05_bootstrap")
    for _, f in ipairs({ "world", "forest", "cave", "lavaarena" }) do
        BS.LoadPrefabFile(f)
    end
    local marked = {}
    for k, v in pairs(Core_.WorldRootPrefabs) do marked[#marked + 1] = k .. "(" .. v .. ")" end
    table.sort(marked)
    local has = {}
    for _, entry in ipairs(marked) do has[entry:match("^([^(]+)")] = true end
    local missing = {}
    for _, n in ipairs({ "forest", "cave", "lavaarena" }) do
        if not has[n] then missing[#missing + 1] = n end
    end
    if #missing > 0 then
        return false, "没登记上: " .. table.concat(missing, ", ")
    end
    return true, string.format("登记 %d 个: %s ✔", #marked, table.concat(marked, " "))
end)

--=========================================================================
hr("TC20  N=3000 抽样才抽到的稀有缺口（平台函数 / 资源解析 / 本地化）")
--=========================================================================

check("平台函数齐全：从 main.lua **静态提取**的全集都在", function()
    -- ★ 宿主的平台函数清单原先是我手抄的，实测**抄错了**：
    --   缺 IsPS4/IsPS5/IsPSN/IsXB1/IsWin32，却多出 10 个原版没有的名字。
    --   症状：`languages/loc.lua:23 IsXB1()` ⇒ loc.lua 整个加载失败 ⇒ LOC 为 nil。
    local Core_ = require("host.01_core")
    local f = io.open(Core_.SourceDir .. "/main.lua", "r")
    if f == nil then return false, "打不开 main.lua" end
    local src = f:read("*a"); f:close()
    local missing, total = {}, 0
    for name in src:gmatch("function%s+(Is[A-Za-z0-9_]+)%s*%(%s*%)") do
        total = total + 1
        if type(_G[name]) ~= "function" then missing[#missing + 1] = name end
    end
    if total == 0 then return false, "一个都没提取到 —— 锚点失效" end
    if #missing > 0 then
        return false, "缺: " .. table.concat(missing, ", ")
    end
    return true, string.format("原版 %d 个平台函数全部在位（含 IsXB1/IsPS4/IsWin32）✔", total)
end)

check("LOC 可用，且 GetTextScale 返回**数字**", function()
    local L = _G.LOC
    if type(L) ~= "table" then
        return false, "LOC 不是表（hermitcrab.lua:1915 会崩）"
    end
    if type(L.GetTextScale) ~= "function" then
        return false, "缺 GetTextScale"
    end
    local v = L:GetTextScale()
    if type(v) ~= "number" then
        return false, "GetTextScale 返回 " .. type(v) .. "（下游会做 == 1 比较）"
    end
    return true, string.format("在位，GetTextScale=%s ✔", tostring(v))
end)

check_env("kleifileexists **真查磁盘**，且能认出真实存在的资源", function()
    -- ★ 环境探针：只看「本机有没有原版 data 目录」这一件事（与我们的代码无关）
    local stat = _G.__kleifileexists
    if stat ~= nil and stat.dir_ok == true then return true end
    return false, "本机没有原版 data 目录（" .. tostring(_G.DST_DATA_DIR) ..
        "）—— 只能用 DST_DATA_DIR 指过去，或装一份游戏"
end, function()
    -- ★ 语义要求：不能一律 false（那是「宿主不知道」伪装成「文件不存在」）。
    local ok = _G.kleifileexists
    if type(ok) ~= "function" then return false, "kleifileexists 不存在" end
    local stat = _G.__kleifileexists
    if stat == nil or stat.dir_ok ~= true then
        return false, "游戏数据目录不可用 —— 无法真查磁盘（" ..
            tostring(_G.DST_DATA_DIR) .. "）"
    end
    -- minimap_data1.xml 确实在 data/ 下（就是我们导出图集索引时读的那份）
    local yes = ok("minimap/minimap_data1.xml")
    local no  = ok("__definitely_missing_asset__.tex")
    if yes ~= true then return false, "真实存在的 minimap_data1.xml 判成不存在" end
    if no ~= false then return false, "不存在的资源判成存在（那就是坏判据）" end
    return true, string.format("真查磁盘：命中 %d / 未命中 %d ✔", stat.hit, stat.miss)
end)

check_env("resolvefilepath 能解出真实资源路径（不是一律 nil）", function()
    local stat = _G.__kleifileexists
    if stat ~= nil and stat.dir_ok == true then return true end
    return false, "本机没有原版 data 目录（" .. tostring(_G.DST_DATA_DIR) .. "）"
end, function()
    -- util.lua:640 resolvefilepath → 走 kleifileexists 那条回退
    if type(_G.resolvefilepath) ~= "function" then
        return false, "resolvefilepath 不存在"
    end
    local p = _G.resolvefilepath("minimap/minimap_data1.xml")
    if type(p) ~= "string" then
        return false, "解出 " .. type(p) .. "（应当返回可用路径字符串）"
    end
    return true, "minimap/minimap_data1.xml → " .. p .. " ✔"
end)

check("package.assetpath 存在（空表，不是 nil）", function()
    if type(package.assetpath) ~= "table" then
        return false, "package.assetpath 是 " .. type(package.assetpath) ..
            "（util.lua:607 会对它取长度）"
    end
    return true, "空表在位 ✔"
end)

--=========================================================================
hr("TC21  三条「静默失效」老账 —— 此前**零断言**覆盖（反向判据）")
--=========================================================================
-- ★ 挑这三条的理由：本工程的 MEMORY 里它们各自记着一次静默失效事故，
--   但 tests.lua 里**一条断言都没有**（grep 计数 = 0）：
--     · DropDeathLoot 曾被桩成 `function(self) end`（不报错、不进缺口清单）
--     · TheWorld:PushEvent 曾只做状态广播、**漏了监听器派发**
--     · TheWorld.state 曾是静态表、不镜像 worldstate
--   ⇒ 「修过」不等于「锁住了」。这三条都补**反向判据**。

check("DropDeathLoot 真的产出掉落物（不是空实现）", function()
    local e = Core.NewEntity("__t21_loot__")
    -- ★ 先加 Transform：裸实体的 `e.Transform` 是 nil（我第一版没加 ⇒ 断言自己抛错）
    e.entity:AddTransform()
    e.Transform:SetPosition(0, 0, 0)
    local okc = pcall(function() e:AddComponent("lootdropper") end)
    if not e.components.lootdropper then
        return false, "lootdropper 组件加不上（" .. tostring(okc) .. "）"
    end
    pcall(function() e.components.lootdropper:SetLoot({ "log", "log" }) end)

    local function count()
        local n = 0
        for _ in pairs(Core.Spawned) do n = n + 1 end
        return n
    end
    local before = count()
    local okd, err = pcall(function() e:DropDeathLoot() end)
    if not okd then return false, "DropDeathLoot 抛错: " .. tostring(err):sub(1, 70) end
    local after = count()
    -- ★ 反向判据：**必须变多**。空实现下 before == after，而它不报错。
    if after <= before then
        return false, string.format("掉落前后实体数没变（%d → %d）—— 疑似空实现",
            before, after)
    end
    -- ★ 再反向一次：掉出来的东西要是 log，不能是随便什么
    local logs = 0
    for _, inst in pairs(Core.Spawned) do
        if type(inst) == "table" and inst.prefab == "log" then logs = logs + 1 end
    end
    if logs < 1 then
        return false, "实体数变多了但没找到 log（掉错东西）"
    end
    pcall(function() e:Remove() end)
    return true, string.format("实体数 %d → %d，其中 log %d 个 ✔", before, after, logs)
end)

check("TheWorld:PushEvent 真的派发监听器（不只是世界状态广播）", function()
    local fired, got, dataok = 0, nil, false
    local EV = "__t21_probe_event__"
    local fn = function(_, data) fired = fired + 1; got = data and data.v or nil
        dataok = (data ~= nil and data.v == 42) end
    local okl = pcall(function() TheWorld:ListenForEvent(EV, fn) end)
    if not okl then return false, "ListenForEvent 不可用" end
    local okp = pcall(function() TheWorld:PushEvent(EV, { v = 42 }) end)
    if not okp then return false, "PushEvent 抛错" end
    -- ★ 反向判据：监听器**必须被调到**，且 data 要原样传过去。
    --   「只做世界状态广播」的实现在这里会 fired == 0，而且不报错。
    if fired ~= 1 then
        return false, string.format("监听器被调用 %d 次（应为 1）—— PushEvent 没派发", fired)
    end
    if not dataok then
        return false, "监听器收到了但 data 不对（传参丢了，got=" .. tostring(got) .. "）"
    end
    pcall(function() TheWorld:RemoveEventCallback(EV, fn) end)
    return true, "监听器被调用 1 次且 data.v=42 原样送达 ✔"
end)

check("TheWorld.state 实时镜像 worldstate（改了就跟）", function()
    local W = TheWorld
    if W.components == nil then return false, "TheWorld.components 不存在" end
    if W.components.worldstate == nil then
        pcall(function() W:AddComponent("worldstate") end)
    end
    local ws = W.components.worldstate
    if ws == nil then return false, "worldstate 组件装不上 —— 这条断言无法成立" end
    if ws.data == nil then return false, "worldstate.data 不存在" end
    local KEY = "isday"
    local old = ws.data[KEY]
    -- ★ 反向判据：写进 worldstate.data 之后，TheWorld.state **必须跟着变**。
    --   静态表实现下 state 永远是建表那一刻的值，而它同样不报错。
    ws.data[KEY] = true
    local t1 = (W.state ~= nil and W.state[KEY] == true)
    ws.data[KEY] = false
    local t2 = (W.state ~= nil and W.state[KEY] == false)
    ws.data[KEY] = old
    if not t1 then return false, "data.isday=true 之后 state.isday 不是 true" end
    if not t2 then return false, "data.isday=false 之后 state.isday 不是 false（镜像不实时）" end
    return true, "写 data → state 同步跟随（真/假都跟）✔"
end)

check("AddComponent 影子闸门：重复添加返回**同一个**实例", function()
    local e = Core.NewEntity("__t21_dupcomp__")
    local a = e:AddComponent("health")
    local b = e:AddComponent("health")
    -- ★ 反向判据：若造出两个共享 netvar 的实例，它们会互相打架
    --   （实测症状是 clock 相位来回跳）。这里要求**同一个**。
    if a == nil or b == nil then return false, "AddComponent 返回 nil" end
    if a ~= b then
        return false, "两次 AddComponent 返回不同实例 —— 影子闸门失效"
    end
    if e.components.health ~= a then
        return false, "e.components.health 与返回的不是同一个"
    end
    return true, "两次添加是同一实例，且 components 表里也是它 ✔"
end)

check("PrefabExists **双向**（真名字 true / 假名字 false）", function()
    -- ★ 它曾「自打加上起就永远返回 false」（同名局部遮蔽），
    --   因此只测「假名字返回 false」是不够的 —— 那正是错误实现的行为。
    require("host.05_bootstrap").LoadPrefabFile("forest")
    local yes = PrefabExists("log")
    local no  = PrefabExists("__definitely_not_a_real_prefab_zzz__")
    if yes ~= true then
        return false, "真实存在的 log 判成不存在 —— PrefabExists 又恒 false 了"
    end
    if no ~= false then
        return false, "不存在的名字判成存在 —— 那是另一种坏实现"
    end
    return true, "log → true / 假名 → false ✔"
end)

--=========================================================================
hr("TC22  knownlocations 闸门（本轮量化到「标准场景 20 次」的那条路径）")
--=========================================================================

check("NewEntity 预置的 knownlocations **也登记了影子表**", function()
    -- ★ 这条直接锁住本轮量出来的事实：标准世界场景里闸门拦下 **20 次**
    --   `knownlocations`（宿主在 NewEntity 预置了它，预制体自己又 AddComponent）。
    --   如果哪天有人把「预置」和「登记」拆开写（只预置不登记），
    --   闸门对这个组件就失效 ⇒ 20 个实体会各多一个活实例，而**不会有任何报错**。
    local e = Core.NewEntity("__t22_knownloc__")
    if e.components.knownlocations == nil then
        return false, "NewEntity 没预置 knownlocations"
    end
    if e.lower_components_shadow == nil then
        return false, "lower_components_shadow 整张表都不存在"
    end
    if e.lower_components_shadow.knownlocations == nil then
        return false, "预置了组件但**没登记影子表** —— 闸门对它无效（静默）"
    end
    -- 反向：再添加一次必须是**同一个**实例
    local again = e:AddComponent("knownlocations")
    if again ~= e.components.knownlocations then
        return false, "重复添加返回了不同实例 —— 闸门没拦住"
    end
    return true, "预置 + 登记 + 闸门三者一致（重复添加返回同一实例）✔"
end)

check("闸门会**记账**（Core.DuplicateAdds 可观测）", function()
    -- ★ 这条保证「拦了几次」是**可测量**的，而不是只能靠读代码相信。
    --   world.lua 末尾会把这个计数印出来（报告 §44.6 的数字就来自它）。
    local e = Core.NewEntity("__t22_dupcount__")
    e:AddComponent("knownlocations")          -- 触发一次闸门
    local D = Core.DuplicateAdds
    if type(D) ~= "table" then
        return false, "Core.DuplicateAdds 不存在 —— 拦截次数不可观测"
    end
    if (D.knownlocations or 0) < 1 then
        return false, "拦截发生了但没记账"
    end
    return true, string.format("knownlocations 累计拦截 %d 次（可被 world.lua 印出）✔",
        D.knownlocations)
end)

--=========================================================================
hr("TC23  未定性类别名**只有一份**（防「两处字面量悄悄漂移」）")
--=========================================================================

check("Boundaries.UNDETERMINED 与 Explain(未知名字) 的返回值一致", function()
    local B = require("host.26_boundaries")
    -- ★★ 这条防的是一个**静默失效**：
    --   类别名字符串原本有**两处**（26_boundaries 的 Explain 返回值 +
    --   reachability.lua 查表用的字面量）。两处靠「抄得一样」维系 ——
    --   谁改了措辞，查表就命中不了，而 `⚠ 未定性 N 条` 会**静默不再打印**，
    --   看起来像「本次没有未定性」，实际是那条警告失效了。
    --   ⇒ 现在只定义一份（常量），这条断言保证「常量 == Explain 实际返回的」。
    if type(B.UNDETERMINED) ~= "string" or B.UNDETERMINED == "" then
        return false, "Boundaries.UNDETERMINED 不是非空字符串"
    end
    local cls = B.Explain("__t23_never_registered__", {})
    if cls ~= B.UNDETERMINED then
        return false, string.format(
            "Explain 返回「%s」，常量是「%s」—— 两处已经漂移，⚠ 未定性警告会静默失效",
            tostring(cls), tostring(B.UNDETERMINED))
    end
    return true, "常量与 Explain 返回值一致（单一定义）✔"
end)

--=========================================================================
-- TC23b  2026-10-18：**「本机缺原版资产」这条边界必须是有条件的**
--=========================================================================
--   背景：换机器（新机器没装 DST）之后，穷举里 `minimap` 从「可达」变成不可达，
--   而且归不进任何已有类别 ⇒ 出现「未定性 1」。补了一条
--   `CLASS.NO_ASSET_DATA`【宿主边界(本机缺原版资产 data/)】。
--
--   ★ 为什么这条断言非有不可：那种「因为环境所以不算」的规则**最容易变成万能挡箭牌**
--     —— 写成无条件的，它会把**真正的宿主缺口**也一并盖住，而且从此没人再看。
--     ⇒ 必须证明它**只在资产目录确实不存在时**才生效：
--        ① `dir_ok = false` + 资产缺失的报错 ⇒ 归入 NO_ASSET_DATA；
--        ② `dir_ok = true`（假装装了原版）         ⇒ 必须回到「未定性」；
--        ③ 报错不是「找不到资产」（比如别的崩法）  ⇒ 也必须回到「未定性」。
--     三条一起才说明它是**条件**，不是**借口**。
check("「缺原版资产」这条边界只在资产确实缺失时生效（否则必须回到未定性）", function()
    local B = require("host.26_boundaries")
    local st = rawget(_G, "__kleifileexists")
    if type(st) ~= "table" then
        return false, "拿不到 __kleifileexists（探针没装上？）—— 那这条规则根本无从判断"
    end
    local keep = st.dir_ok
    local ctx = { err = "util.lua:648: Could not find an asset matching "
                       .. "minimap/minimap_data1.xml in any of the search paths." }
    local ok, a, b, c = pcall(function()
        st.dir_ok = false
        local r1 = B.Explain("minimap", ctx)
        st.dir_ok = true
        local r2 = B.Explain("minimap", ctx)
        st.dir_ok = false
        local r3 = B.Explain("minimap", { err = "attempt to index a nil value (field 'Foo')" })
        return r1, r2, r3
    end)
    st.dir_ok = keep                       -- ★ 无论成败都要还原：这是**全局状态**
    if not ok then
        return false, "Explain 抛异常：" .. tostring(a)
    end
    if a ~= B.CLASS.NO_ASSET_DATA then
        return false, string.format("资产缺失时应归入「%s」，实际「%s」",
            B.CLASS.NO_ASSET_DATA, tostring(a))
    end
    if b ~= B.UNDETERMINED then
        return false, string.format(
            "★ 资产**在**的时候它仍归入「%s」—— 这条规则变成了万能挡箭牌，"
            .. "真正的宿主缺口会被它盖住", tostring(b))
    end
    if c ~= B.UNDETERMINED then
        return false, string.format("别的崩法也被归成「%s」—— 判据太宽", tostring(c))
    end
    return true, "三条都对：缺资产⇒归边；资产在⇒未定性；别的崩法⇒未定性 ✔"
end)

check("reachability.lua 不再抄「未定性」字面量（改用常量）", function()
    -- ★ 反向判据：源码里不该再出现那个字面量（除注释外）
    local f = io.open("reachability.lua", "r")
    if f == nil then return false, "打不开 reachability.lua" end
    local src = f:read("*a"); f:close()
    local n = 0
    for line in src:gmatch("[^\n]+") do
        local stripped = line:gsub("^%s+", "")
        if not stripped:match("^%-%-") and line:find("未定性 —— 必须去查", 1, true) then
            n = n + 1
        end
    end
    if n > 0 then
        return false, string.format("还有 %d 处在**可执行代码**里硬编码该字面量", n)
    end
    return true, "代码里 0 处硬编码（注释不算）✔"
end)

--=========================================================================
hr("TC24  T42：覆盖率候选里**确认缺断言**的 5 项引擎修复")
--=========================================================================
-- ★ 这 5 项来自 `audit_fixes.py --coverage` 的候选清单 —— 该报告只给**候选**，
--   我人工过了一遍，确认其中 5 项是**真缺断言**的引擎修复（其余是工具类，
--   由各自的自检保障，不该进 tests.lua）。**补断言 = 把候选变成锁定。**

check("PhysicsWaker：AddPhysicsWaker 之后 inst.PhysicsWaker 真的在", function()
    -- ★ 真实引擎里 `inst.entity:AddPhysicsWaker()` 创建的是 C++ 对象，
    --   并且**同时**在 EntityScript 侧出现 `inst.PhysicsWaker`：
    --       inst.entity:AddPhysicsWaker()
    --       inst.PhysicsWaker:SetTimeBetweenWakeTests(...)
    --   只建 C++ 侧、不挂 `inst.PhysicsWaker` ⇒ 第二行直接崩。
    local e = Core.NewEntity("__t24_waker__")
    e.entity:AddTransform()
    local before = e.PhysicsWaker
    e.entity:AddPhysicsWaker()
    local after = e.PhysicsWaker
    if after == nil then
        return false, "AddPhysicsWaker 之后 inst.PhysicsWaker 仍是 nil"
    end
    if type(after.SetTimeBetweenWakeTests) ~= "function" then
        return false, "inst.PhysicsWaker 缺 SetTimeBetweenWakeTests"
    end
    -- 反向：调用不能抛错（代理也应接得住）
    local ok = pcall(function() after:SetTimeBetweenWakeTests(0.1) end)
    if not ok then return false, "SetTimeBetweenWakeTests 调用抛错" end
    return true, string.format("加之前 %s → 加之后可调用 ✔", tostring(before))
end)

check("MissingHits **模块初始化即建表**（不是等到用的时候才建）", function()
    -- ★ 原缺陷：转发那一步带 `AS.MissingHits ~= nil` 的前置条件，
    --   而表是**惰性**建的 ⇒ 第一次会静默拿不到，缺口统计少一份。
    --   ⇒ 判据：require 完 animstate 之后它**已经是表**。
    local AS = require("host.10_animstate")
    if type(AS.MissingHits) ~= "table" then
        return false, "As.MissingHits 类型是 " .. type(AS.MissingHits) .. "（应为 table）"
    end
    -- 反向：必须可写（有人会往里塞 build 名）
    local k = "__t24_probe__"
    AS.MissingHits[k] = true
    local ok = AS.MissingHits[k] == true
    AS.MissingHits[k] = nil
    if not ok then return false, "MissingHits 不可写" end
    return true, "模块加载后即为可写表（非惰性）✔"
end)

check("更新泵分桶表全局齐全（UpdatingEnts / NewUpdatingEnts …）", function()
    -- ★ 这些是**全局桶**：游戏代码直接读它们（如 `for k in pairs(UpdatingEnts)`）。
    --   缺一个就是「某些实体永远不更新」——而**不会报错**。
    local missing = {}
    for _, n in ipairs({ "AwakeEnts", "UpdatingEnts", "NewUpdatingEnts",
                         "StopUpdatingEnts" }) do
        if type(_G[n]) ~= "table" then missing[#missing + 1] = n end
    end
    if #missing > 0 then
        return false, "缺: " .. table.concat(missing, ", ")
    end
    return true, "4 个桶表全部存在且是 table ✔"
end)

check("emitters.lua 进了启动序列（EmitterManagerClass 可用）", function()
    -- ★ 原缺陷：emitters.lua 没进 bootstrap ⇒ `pollen.lua:90` 等
    --   **46 个文件 / 61 处调用**静默拿不到发射器工厂。
    --   ★ 注意它不是 `return` 一个表，而是定义**全局类** `EmitterManagerClass`。
    if type(_G.EmitterManagerClass) ~= "table" and type(_G.EmitterManagerClass) ~= "function" then
        return false, "EmitterManagerClass 不存在（emitters.lua 没加载）"
    end
    -- 反向：能不能真的造一个（构造器可调用）
    local ok, inst = pcall(function()
        if type(_G.EmitterManagerClass) == "table" and _G.EmitterManagerClass.new then
            return _G.EmitterManagerClass.new({})
        end
        return nil
    end)
    if not ok then return false, "EmitterManagerClass 构造抛错" end
    return true, "在启动序列里（类型 " .. type(_G.EmitterManagerClass) .. "）✔"
end)

check("_G.Map 与 World.Map 同步（不是只写了 G.Map）", function()
    -- ★ 原缺陷：`20_map.lua` 早期版本在函数体内只写 `G.Map`，
    --   而 `_G.Map` 保持 nil；游戏代码在**加载时**读全局 `Map` ⇒ 拿到 nil。
    --   修法：两处都写（`G.Map = Map; _G.Map = Map`）。
    --   ⇒ 判据：`_G.Map` 必须非 nil，且与 World 上那个是**同一张**。
    local m = _G.Map
    if m == nil then
        return false, "_G.Map 是 nil —— 只写了 G.Map（加载时读全局的代码会拿到 nil）"
    end
    if type(m) ~= "table" then return false, "_G.Map 类型是 " .. type(m) end
    -- 反向：两边必须是同一个对象，不是各自一份拷贝
    local wm = Core.World and Core.World.Map
    if wm ~= nil and wm ~= m then
        return false, "_G.Map 与 World.Map 不是同一个对象（各写了一份）"
    end
    return true, "非 nil 且与 World.Map 同一对象 ✔"
end)

--=========================================================================
--=========================================================================
hr("TC25  能加**新内容**吗：新组件 + 新预制体（`_demo_newcontent.lua` 的断言版）")
--=========================================================================
-- ★ 这一组锁的是一句**能力声明**：「这个引擎能用来开发内容」。
--   不是靠嘴说，而是把三件事锁死：
--     ① 新组件能链注册（Core.RegisterComponent）
--     ② 新预制体能链用**原版 Prefab() 语法**定义，并与原版组件共存
--     ③ 新组件的 OnUpdate 能被**更新泵**调到

check("Core.RegisterComponent 注册的新组件真的可用", function()
    local T25Counter = Class(function(self, inst)
        self.inst = inst; self.n = 0
    end)
    function T25Counter:OnUpdate() self.n = self.n + 1 end
    Core.RegisterComponent("t25_counter", T25Counter)
    if Core.ComponentRegistry["t25_counter"] == nil then
        return false, "注册后 ComponentRegistry 里没有它"
    end
    return true, "已进注册表 ✔"
end)

check("新预制体（原版 Prefab 语法）能 spawn，新/原版组件共存 + OnUpdate 真的跑", function()
    Core.Prefab("t25_thing", function()
        local inst = CreateEntity()
        inst.entity:AddTransform()
        inst:AddComponent("t25_counter")
        inst:AddComponent("health")
        inst.components.health:SetMaxHealth(37)
        -- ★ 必须显式注册更新（原版 AddComponent 不自动做，已核对 entityscript.lua）
        inst:StartUpdatingComponent(inst.components.t25_counter)
        return inst
    end)
    local inst = Core.SpawnPrefab("t25_thing")
    if inst == nil then return false, "SpawnPrefab 返回 nil" end
    if inst.components.health == nil then return false, "原版 health 没挂上" end
    if inst.components.health.maxhealth ~= 37 then
        return false, "原版组件属性不对: " .. tostring(inst.components.health.maxhealth)
    end
    local before = inst.components.t25_counter.n
    for _ = 1, 30 do Sim.Step() end
    local got = inst.components.t25_counter.n - before
    if got ~= 30 then
        return false, string.format("OnUpdate 跑了 %d 次（应为 30）", got)
    end
    return true, string.format("spawn ✔ / health max=%d ✔ / OnUpdate 30 次 ✔",
                               inst.components.health.maxhealth)
end)

check("未注册的组件返回 nil（不是假成功）", function()
    local inst = Core.SpawnPrefab("pigman")
    if inst == nil then return false, "拿不到原版实体做探针" end
    if inst:AddComponent("t25_never_registered") ~= nil then
        return false, "未注册组件竟然返回了非 nil"
    end
    return true, "返回 nil ✔"
end)

--=========================================================================
-- TC26 · 审计发现的两条 P0 + 两条「实测能通但没有回归锁」的链
--
--  ★ 这四条都有一个共同性质：**它们以前没人验**。
--    · behaviours 预加载缺失 ⇒ 51% 的 brain 生成即崩（spider 是最普通的一只）
--    · A* 四个函数全是空桩 ⇒ 生物只会走直线、撞墙就卡住
--    · 战斗链 / 制作链：实测**都通**，但 tests.lua 与 mech.lua 里一条断言都没有
--      ⇒ 与当年 `DropDeathLoot` 被桩成空函数却不报错是同一类风险
--=========================================================================
hr("TC26 · 行为树全局 / A* 寻路 / 战斗链 / 制作链")

check("behaviours 预加载：每个行为类的**全局**都就位（不靠加载顺序碰运气）", function()
    -- ★★ 为什么要判「全局在不在」而不是「spider 能不能生成」：
    --   实测过 —— 只判后者时，撤销预加载它**仍然是绿的**，
    --   因为排在前面的断言已经顺手把 behaviours/faceentity 加载了。
    --   ⇒ 那正是本次要治的病本身（结果依赖加载顺序），不能拿它当判据。
    -- ★ 反向：撤销预加载后这条必红（已验证）。
    local n, miss = 0, {}
    for _nm, cls in pairs(Bootstrap.BehavioursClasses or {}) do
        n = n + 1
        if rawget(_G, cls) == nil then miss[#miss + 1] = cls end
    end
    if n == 0 then
        return false, "一个行为类都没解析到（目录枚举失败？）"
    end
    if (Bootstrap.BehavioursPreloaded or 0) == 0 then
        return false, "behaviours 一个都没预加载"
    end
    if #miss > 0 then
        return false, string.format("%d 个行为类全局缺失：%s", #miss, table.concat(miss, " "))
    end
    return true, string.format("%d 个行为类全局全部就位 ✔（共预加载 %d 个文件）",
                               n, Bootstrap.BehavioursPreloaded)
end)

check("spider 端到端：能生成、带 brain、挂着真实状态图", function()
    local ok, inst = pcall(function() return Core.SpawnPrefab("spider") end)
    if not ok then
        return false, "spider 生成抛异常: " .. tostring(inst)
    end
    if inst == nil then return false, "spider 生成返回 nil" end
    if inst.brain == nil then return false, "spider 没有 brain（行为树没挂上）" end
    return true, string.format("spawn ✔ / brain ✔ / sg=%s",
                               inst.sg ~= nil and tostring(inst.sg.sg.name) or "nil")
end)

-- 下面三条 A* 判据共用一段「可控地形」：凿一条 3 瓦片高、31 瓦片长的走廊，
-- 再把中间一行封死 ⇒ 直线必不通、绕行必存在。不依赖随机地形，判据才稳定。
local function carve_corridor()
    local Map = WorldMap.GetMap()
    local PF = (Sim.World and Sim.World.Pathfinder) or WorldMap.Pathfinder
    local grass = (_G.GROUND and _G.GROUND.GRASS) or 6
    local row, c0, c1 = 40, 30, 60
    for cx = c0, c1 do
        for r = row - 1, row + 1 do Map:SetTile(cx, r, grass) end
    end
    local x0, _, z0 = Map:GetTileCenterPoint(c0, row)
    local x1, _, z1 = Map:GetTileCenterPoint(c1, row)
    return Map, PF, x0, z0, x1, z1, row, c0, c1
end

check("A*：开阔地直线可达时**恰好 2 步**（触发原版「丢弃路径走直线」）", function()
    local Map, PF, x0, z0, x1, z1 = carve_corridor()
    if not Map:IsPassableAtPoint(x0, 0, z0) then
        return false, "凿出来的起点竟然不可通行 —— 判据自身有问题"
    end
    -- ★ 反向的一半：直线必须真的通（否则「2 步」说明不了任何事）
    if not PF:IsClear(x0, 0, z0, x1, 0, z1, nil) then
        return false, "走廊两端直线不通 —— 测试地形没凿对"
    end
    local h = PF:SubmitSearch(x0, 0, z0, x1, 0, z1, nil)
    if h == nil then return false, "SubmitSearch 返回 nil（Locomotor 会当成提交失败）" end
    if PF:GetSearchStatus(h) ~= 1 then
        return false, "status=" .. tostring(PF:GetSearchStatus(h)) .. "（应为 1=FOUNDPATH）"
    end
    local r = PF:GetSearchResult(h)
    if r == nil or r.steps == nil then return false, "有 status=1 却取不到 steps" end
    -- ★★ 关键：locomotor.lua:2989 是 `if #steps > 2 then 采纳 else 丢弃走直线`。
    --   开阔地必须**恰好 2 步**，否则角色会在直线上走 S 形（与原版行为不同）。
    if #r.steps ~= 2 then
        return false, string.format("开阔地得到 %d 步（应为 2）—— 拉直没生效，角色会走 S 形",
                                    #r.steps)
    end
    PF:KillSearch(h)
    return true, "2 步 ✔（触发丢弃分支，与原版一致）"
end)

check("A*：直线被墙挡住时能绕过去，且不穿墙", function()
    local Map, PF, x0, z0, x1, z1, row, c0, c1 = carve_corridor()
    -- 只封中间一行的一段 ⇒ 上下两行还留着，绕行必然存在
    for cx = 42, 48 do
        local wx, _, wz = Map:GetTileCenterPoint(cx, row)
        PF:AddWall(wx, 0, wz)
    end
    local blocked = not PF:IsClear(x0, 0, z0, x1, 0, z1, nil)
    local h = PF:SubmitSearch(x0, 0, z0, x1, 0, z1, nil)
    local st = PF:GetSearchStatus(h)
    local r = PF:GetSearchResult(h)
    -- 清理，别把墙留给后面的断言
    for cx = 42, 48 do
        local wx, _, wz = Map:GetTileCenterPoint(cx, row)
        PF:RemoveWall(wx, 0, wz)
    end
    local clear_again = PF:IsClear(x0, 0, z0, x1, 0, z1, nil)
    PF:KillSearch(h)
    if not blocked then return false, "登记了墙，IsClear 却仍说通 —— 墙没进判据" end
    if not clear_again then return false, "RemoveWall 之后仍然不通 —— 墙没被撤掉" end
    if st ~= 1 then return false, "绕障失败：status=" .. tostring(st) end
    if r == nil or r.steps == nil then return false, "status=1 却没有 steps" end
    if #r.steps <= 2 then
        return false, string.format("绕障只得到 %d 步（应 >2）—— 还是走直线", #r.steps)
    end
    -- ★ 反向：路径上每一步都必须可通行（不许穿墙）
    local bad = 0
    for _, p in ipairs(r.steps) do
        if not Map:IsPassableAtPoint(p.x, 0, p.z) then bad = bad + 1 end
    end
    if bad > 0 then return false, string.format("路径有 %d 个拐点落在不可通行格上", bad) end
    return true, string.format("绕行 %d 步 ✔ / 零穿墙 ✔ / 撤墙后恢复直通 ✔", #r.steps)
end)

check("A*：反向 —— 目标不可达必须报无路，不许编一条", function()
    local _, PF, x0, z0 = carve_corridor()
    local h = PF:SubmitSearch(x0, 0, z0, 99999, 0, 99999, nil)
    local st = PF:GetSearchStatus(h)
    local r = PF:GetSearchResult(h)
    PF:KillSearch(h)
    if st == nil then return false, "句柄失效（应给一个明确状态）" end
    if st == 0 then return false, "永远停在「计算中」（同步实现不该这样）" end
    if st == 1 then return false, "目标在图外却报「找到路径」—— 橡皮图章" end
    if r ~= nil then return false, "无路却仍返回了 steps" end
    return true, string.format("status=%d（无路）✔ / steps=nil ✔", st)
end)

check("战斗链：Combat 打出**真实**伤害（不是空转）", function()
    local w = Core.SpawnPrefab("wilson")
    local s = Core.SpawnPrefab("spider")
    if w == nil or s == nil then return false, "拿不到探针实体" end
    if w.components.health == nil then return false, "wilson 没有 health 组件" end
    if s.components.combat == nil then return false, "spider 没有 combat 组件" end
    s.Transform:SetPosition(0, 0, 0)
    w.Transform:SetPosition(1, 0, 0)
    local h0 = w.components.health.currenthealth
    local ok, err = pcall(function() return s.components.combat:DoAttack(w) end)
    if not ok then return false, "DoAttack 抛异常: " .. tostring(err) end
    for _ = 1, 120 do Sim.Step(1 / 30) end
    local h1 = w.components.health.currenthealth
    -- ★ 反向：血量必须**变小**。恒等说明整条链是死的。
    if h1 >= h0 then
        return false, string.format("打了半天血量没变（%.2f → %.2f）—— 伤害链是死的",
                                    h0, h1)
    end
    return true, string.format("血量 %.2f → %.2f ✔", h0, h1)
end)

check("制作链：给足材料后能真的合成出斧头（且材料被扣）", function()
    local w = Core.SpawnPrefab("wilson")
    if w == nil then return false, "拿不到 wilson" end
    local b = w.components.builder
    if b == nil then return false, "wilson 没有 builder 组件" end
    -- ★ 反向的一半：没材料时必须**不能**造 —— 否则 CanBuild 是橡皮图章
    if b:CanBuild("axe") then
        return false, "空手就能 CanBuild(axe) —— 判据失效"
    end
    local inv = w.components.inventory
    if inv == nil then return false, "wilson 没有 inventory 组件" end
    local tw, fl = Core.SpawnPrefab("twigs"), Core.SpawnPrefab("flint")
    inv:GiveItem(tw)
    inv:GiveItem(fl)
    if not b:CanBuild("axe") then
        return false, "给了 twigs+flint 仍 CanBuild=false —— 配方校验不通"
    end
    local ok, r1 = pcall(function() return b:DoBuild("axe") end)
    if not ok then return false, "DoBuild 抛异常: " .. tostring(r1) end
    if not r1 then return false, "DoBuild 返回 false（没造出来）" end
    return true, "空手不能造 ✔ / 给料能造 ✔ / DoBuild 成功 ✔"
end)

check("COLLISION 常量必须是**真** constants.lua 那份（不是手抄的错值）", function()
    -- ★ 03_globals.lua:1654 手抄了一份 COLLISION（CHARACTERS=4、OBSTACLES=2…），
    --   与真 constants.lua（GROUND=32 / CHARACTERS=1024 / OBSTACLES=512 /
    --   GIANTS=16384 …）**完全对不上**。目前真文件会覆盖它所以没事，
    --   但哪天真常量加载失败，那份错值就会**悄悄生效** ——
    --   手抄常量漂移是本工程栽过好几次的坑，必须有人盯着。
    local C = rawget(_G, "COLLISION")
    if C == nil then return false, "COLLISION 根本不存在" end
    local want = { GROUND = 32, LIMITS = 192, WORLD = 224, ITEMS = 256,
                   OBSTACLES = 512, CHARACTERS = 1024, FLYERS = 2048,
                   SANITY = 4096, GIANTS = 16384 }
    local bad = {}
    for k, v in pairs(want) do
        if C[k] ~= v then bad[#bad + 1] = string.format("%s=%s(应%d)", k, tostring(C[k]), v) end
    end
    if #bad > 0 then
        return false, "COLLISION 不是真常量： " .. table.concat(bad, " ")
    end
    return true, "GROUND/CHARACTERS/OBSTACLES 等 9 个值全部与真 constants.lua 一致 ✔"
end)

check("Physics:CollidesWith 是**掩码设置器**（不是恒真的查询）", function()
    -- ★ 原版语义：`inst.Physics:CollidesWith(COLLISION.CHARACTERS)` 是
    --   「把这几个碰撞组加进我的掩码」，C++ 绑定**不返回值**
    --   （调用点：heavyobstaclephysics.lua:90 / projectile.lua:214）。
    --   此前宿主写成 `return true` ⇒ 任何读返回值的判定都拿到「永远碰上了」。
    local inst = Core.SpawnPrefab("wilson")
    if inst == nil or inst.Physics == nil then return false, "拿不到 Physics 做探针" end
    local C = rawget(_G, "COLLISION")
    if C == nil then return false, "没有 COLLISION 常量" end
    local before = inst.Physics:GetCollisionMask() or 0
    -- ★ 反向①：必须**不返回** true（否则还是老语义）
    local rv = inst.Physics:CollidesWith(C.SANITY)
    if rv ~= nil then
        return false, "CollidesWith 仍返回了 " .. tostring(rv) .. "（原版是不返回值的设置器）"
    end
    local after = inst.Physics:GetCollisionMask() or 0
    local bit = rawget(_G, "bit")
    local added = (bit ~= nil and bit.band(after, C.SANITY) == C.SANITY)
               or (after ~= before)
    if not added then
        return false, string.format("掩码没把 SANITY 加进去（%s → %s）",
                                    tostring(before), tostring(after))
    end
    -- ★ 反向②：ClearCollidesWith 必须能把它**拿掉**
    inst.Physics:ClearCollidesWith(C.SANITY)
    local cleared = inst.Physics:GetCollisionMask() or 0
    if bit ~= nil and bit.band(cleared, C.SANITY) ~= 0 then
        return false, string.format("ClearCollidesWith 之后掩码仍含 SANITY（%s）", tostring(cleared))
    end
    return true, string.format("设置器语义 ✔（%s → %s → %s）",
                               tostring(before), tostring(after), tostring(cleared))
end)

--=========================================================================
hr("TC27 资产加载器（TheSim:LoadAtlas / LoadPrefabs / LoadAnim）")
--=========================================================================
--  审计发现：这四个接口在**全仓 0 命中**，而原版有 34+22+137 处调用点。
--  这一节的判据全部要求「有真实数据落地」，并且**每条都带反向** ——
--  因为「加载了」这句话最容易写成假的（返回 true 但什么都没读）。

check("LoadAtlas 真解析 XML：元素数/矩形/AtlasContains 三处一致（且该图集不在索引里）", function()
    local T = Sim.TheSim
    local PATH = "_fixtures/tiny_atlas.xml"      -- 人造 2 元素图集，**不在** atlas_index/
    -- ★ 反向①：加载**之前** HasAtlas 必须 false（否则「加载」这件事没有可观测差别）
    if T:HasAtlas(PATH) then
        return false, "还没加载就已经 HasAtlas=true —— 判据失去意义"
    end
    local a, why = T:LoadAtlas(PATH)
    if type(a) ~= "table" then return false, "LoadAtlas 失败: " .. tostring(why) end
    if a.count ~= 2 then return false, "元素数 " .. tostring(a.count) .. "（应 2）" end
    if a.source ~= "xml" then return false, "source=" .. tostring(a.source) .. "（应是 xml，说明没走真解析）" end
    local r = a.rects["blue_square.tex"]
    if type(r) ~= "table" or r.w ~= 32 or r.u ~= 64 then
        return false, "矩形没解析对：" .. tostring(r and (r.u .. "," .. r.w) or r)
    end
    if T:AtlasContains(PATH, "red_circle.tex") ~= true then
        return false, "加载后 AtlasContains(red_circle) 仍 false"
    end
    -- ★ 反向②：图集里没有的名字必须 false（不能「加载了就什么都 true」）
    if T:AtlasContains(PATH, "nope.tex") ~= false then
        return false, "图集里不存在的名字 AtlasContains 返回了 true"
    end
    -- ★ 反向③：不存在的图集必须 false **且给原因**（不静默）
    local bad, why2 = T:LoadAtlas("images/definitely_not_here.xml")
    if bad ~= false then return false, "不存在的图集没返回 false" end
    if type(why2) ~= "string" or why2 == "" then return false, "失败没给原因" end
    return true, string.format("XML 解析 %d 元素 ✔ / 矩形 u=%s w=%s ✔ / 命中与不命中都对 ✔",
                               a.count, tostring(r.u), tostring(r.w))
end)

check("LoadPrefabs 真解析 prefab 文件；UnloadPrefabs 之后 IsPrefabLoaded 必须 false", function()
    local T = Sim.TheSim
    -- 先保证是「未加载」状态（幂等：上一条判据不依赖顺序）
    T:UnloadPrefabs({ "seeds" })
    if T:IsPrefabLoaded("seeds") then return false, "Unload 之后仍 IsPrefabLoaded=true" end
    local n, failed = T:LoadPrefabs({ "seeds" })
    if n ~= 1 or #failed ~= 0 then
        return false, string.format("成功 %s 失败 %s", tostring(n), table.concat(failed, ","))
    end
    -- ★ 真实副作用：prefab 定义必须真的进了 Core.Prefabs（不是只记账）
    if Core.Prefabs["seeds"] == nil then
        return false, "IsPrefabLoaded=true 但 Core.Prefabs 里没有定义 —— 只记了账"
    end
    if T:IsPrefabLoaded("seeds") ~= true then return false, "加载后 IsPrefabLoaded 仍 false" end
    -- ★ 反向①：不存在的名字必须进失败表（不静默当成功）
    local n2, failed2 = T:LoadPrefabs({ "definitely_not_a_prefab" })
    if n2 ~= 0 or #failed2 ~= 1 or failed2[1] ~= "definitely_not_a_prefab" then
        return false, "不存在的 prefab 没被记进失败表"
    end
    -- ★ 反向②：Unload 要真的把定义放掉（否则「卸载」是空话）
    if T:UnloadPrefabs({ "seeds" }) ~= 1 then return false, "UnloadPrefabs 返回不是 1" end
    if T:IsPrefabLoaded("seeds") or Core.Prefabs["seeds"] ~= nil then
        return false, "Unload 之后定义还在"
    end
    -- 收尾：重新加载，别把后续断言的环境搞脏
    T:LoadPrefabs({ "seeds" })
    return true, "加载 ✔（定义真的进 Core.Prefabs）/ 未知名字进失败表 ✔ / 卸载后定义消失 ✔"
end)

check("LoadAnim 读到真实 UV 与矩阵（不是只数文件名）", function()
    local T = Sim.TheSim
    local m, why = T:LoadAnim("bee_build")
    if type(m) ~= "table" then return false, "LoadAnim 失败: " .. tostring(why) end
    if (m.symbols or 0) < 1 then return false, "symbols=" .. tostring(m.symbols) end
    if (m.anims or 0) < 1 then return false, "anims=" .. tostring(m.anims) end
    -- ★ 关键：抽一个 symbol 的 verts，必须**真的有 6 个顶点、每点 4 个分量**
    --   （UV 是 4 元组 u,v,su,sv）。只数「有几个 symbol」是数不出来的。
    local data = m.data
    local got, nverts, badfmt = nil, 0, false
    for _, s in pairs(data.symbols or {}) do
        for _, fr in pairs(s.frames or {}) do
            got = fr
            nverts = #(fr.verts or {})
            for _, v in ipairs(fr.verts or {}) do
                if type(v) ~= "table" or #v ~= 4 then badfmt = true end
            end
            break
        end
        if got ~= nil then break end
    end
    if got == nil then return false, "没有一个 symbol 带 frames" end
    if nverts ~= 6 then return false, "顶点数 " .. nverts .. "（DST 的 quad 是 6 个顶点）" end
    if badfmt then return false, "顶点不是 4 分量（u,v,su,sv）" end
    if type(got.bbox) ~= "table" or #got.bbox ~= 4 then return false, "bbox 不是 4 元组" end
    -- ★ 反向：不存在的 build 必须 false + 原因
    local bad, why2 = T:LoadAnim("definitely_not_a_build")
    if bad ~= false or type(why2) ~= "string" then return false, "不存在的 build 没如实失败" end
    return true, string.format("%d symbol / %d anim / 6 顶点 × 4 分量 ✔ / bbox 4 元组 ✔",
                               m.symbols, m.anims)
end)

check("AddTextureToStreamingGroup 登记可反查，重复登记不新增（137 处调用点）", function()
    local T = Sim.TheSim
    local before = T:StreamingGroupCount(0)
    local i1 = T:AddTextureToStreamingGroup(0, "anim/__t1.zip:t1--atlas-0.tex")
    local i2 = T:AddTextureToStreamingGroup(0, "anim/__t2.zip:t2--atlas-0.tex")
    if i1 ~= before + 1 or i2 ~= before + 2 then
        return false, string.format("下标 %s/%s（期望 %d/%d）", tostring(i1), tostring(i2),
                                    before + 1, before + 2)
    end
    -- ★ 反向①：重复登记必须回**已有下标**，且数量不增加
    local i3 = T:AddTextureToStreamingGroup(0, "anim/__t2.zip:t2--atlas-0.tex")
    if i3 ~= i2 then return false, "重复登记返回了新下标 " .. tostring(i3) end
    if T:StreamingGroupCount(0) ~= before + 2 then
        return false, "重复登记把组撑大了（" .. T:StreamingGroupCount(0) .. "）"
    end
    -- ★ 反查：拿回来的列表里必须真的有这两个路径
    local list = T:GetStreamingGroup(0)
    if list[i1] ~= "anim/__t1.zip:t1--atlas-0.tex" or list[i2] ~= "anim/__t2.zip:t2--atlas-0.tex" then
        return false, "按组号反查拿不到登记的路径"
    end
    -- ★ 反向②：坏参数必须给 nil + 原因，不能静默当成功
    local bad = T:AddTextureToStreamingGroup(0, "")
    if bad ~= nil then return false, "空路径居然登记成功了" end
    return true, string.format("组 0：%d → %d，重复登记回同一下标 ✔，反查一致 ✔",
                               before, T:StreamingGroupCount(0))
end)

--=========================================================================
hr("TC28 音频事件通道（SoundEmitter 的播放/停止必须可观测）")
--=========================================================================
--  审计结论：此前 `SoundEmitter` 只是「一张记账表」——
--  播了什么、播了几次、什么参数，外部一概看不见。本工程不做音频后端，
--  但「不出声」与「不知道发生过什么」是两件事。

check("播 3 次 → 3 条结构化事件；Drain 取走即清空（不能重复取）", function()
    local A = Sim.Audio
    if A == nil then return false, "Sim.Audio 不存在（29_audio 没装上）" end
    Bootstrap.LoadPrefabFile("campfire")
    local fire = Core.SpawnPrefab("campfire")
    if fire == nil or fire.SoundEmitter == nil then return false, "campfire 没有 SoundEmitter" end
    A.Reset()

    fire.SoundEmitter:PlaySound("dontstarve/common/fire")
    fire.SoundEmitter:PlaySound("dontstarve/common/fire", "loop")
    fire.SoundEmitter:PlaySound("dontstarve/common/fire", "second")

    local ev = A.Drain()
    if #ev ~= 3 then return false, "事件数 " .. #ev .. "（应 3）" end
    -- ★ 字段必须齐全：缺任何一个，「谁在响/响的什么/多大声」就有一问答不上
    for i, e in ipairs(ev) do
        for _, k in ipairs({ "kind", "t", "prefab", "name", "vol", "pitch" }) do
            if e[k] == nil then
                return false, string.format("第 %d 条缺字段 %s", i, k)
            end
        end
        if e.kind ~= "play" then return false, "kind=" .. tostring(e.kind) end
        if e.prefab ~= "campfire" then
            return false, "prefab=" .. tostring(e.prefab) .. "（应 campfire —— 事件说不出是谁在响）"
        end
        if type(e.vol) ~= "number" or type(e.pitch) ~= "number" then
            return false, "vol/pitch 不是数字"
        end
    end
    if ev[2].id ~= "loop" then return false, "id 没记下来：" .. tostring(ev[2].id) end
    -- ★ 反向：取走即清空。否则「播了 3 次」这句话可以靠反复读同一批事件伪造
    if #A.Drain() ~= 0 then return false, "Drain 之后还能再取到事件（没有清空）" end
    return true, string.format("3 条事件字段齐全 ✔ / prefab=campfire ✔ / 二次 Drain=0 ✔")
end)

check("SetVolume/SetPitch 是真状态：默认 1，改了之后事件里带着新值", function()
    local A = Sim.Audio
    Bootstrap.LoadPrefabFile("campfire")
    local fire = Core.SpawnPrefab("campfire")
    if fire == nil or fire.SoundEmitter == nil then return false, "campfire 没有 SoundEmitter" end
    local SE = fire.SoundEmitter
    A.Reset()

    -- ★ 反向①：**没设过**的时候必须是 1，不能是 nil
    --   （数值型 getter 返回 nil 会把错误推到下游算术 —— 本工程栽过）
    if SE:GetVolume() ~= 1 then return false, "默认音量不是 1：" .. tostring(SE:GetVolume()) end
    if SE:GetPitch() ~= 1 then return false, "默认音高不是 1：" .. tostring(SE:GetPitch()) end

    SE:SetVolume(0)
    SE:SetPitch(2)
    SE:PlaySound("dontstarve/common/fire", "mute")
    local ev = A.Drain()
    if #ev ~= 1 then return false, "事件数 " .. #ev end
    -- ★ 关键：SetVolume(0) 必须**真的**体现在事件里（否则这个 setter 是空话）
    if ev[1].vol ~= 0 then return false, "事件 vol=" .. tostring(ev[1].vol) .. "（应 0）" end
    if ev[1].pitch ~= 2 then return false, "事件 pitch=" .. tostring(ev[1].pitch) .. "（应 2）" end

    -- ★ 反向②：显式参数优先于 emitter 状态（PlaySoundWithParams 的语义）
    SE:PlaySoundWithParams("dontstarve/common/fire", { volume = 0.25, pitch = 0.5 }, "p")
    local ev2 = A.Drain()
    if #ev2 ~= 1 or ev2[1].vol ~= 0.25 or ev2[1].pitch ~= 0.5 then
        return false, "PlaySoundWithParams 的参数没生效"
    end
    SE:SetVolume(1); SE:SetPitch(1)      -- 收尾，别污染后续
    return true, "默认 1 ✔ / SetVolume(0) 真生效 ✔ / 显式参数优先 ✔"
end)

check("KillSound/KillAllSounds 真改状态并产出 kill 事件；杀不存在的 id 不产事件", function()
    local A = Sim.Audio
    Bootstrap.LoadPrefabFile("campfire")
    local fire = Core.SpawnPrefab("campfire")
    if fire == nil or fire.SoundEmitter == nil then return false, "campfire 没有 SoundEmitter" end
    local SE = fire.SoundEmitter
    SE:KillAllSounds()      -- 先清干净，别受前面断言影响
    A.Reset()

    SE:PlaySound("s1", "id1")
    SE:PlaySound("s2", "id2")
    if not SE:PlayingSound("id1") then return false, "PlaySound 之后 PlayingSound(id1) 仍 false" end
    SE:KillSound("id1")
    if SE:PlayingSound("id1") then return false, "KillSound 之后 PlayingSound(id1) 仍 true" end

    local ev = A.Drain()
    local nkill = 0
    for _, e in ipairs(ev) do if e.kind == "kill" then nkill = nkill + 1 end end
    if nkill ~= 1 then return false, "kill 事件数 " .. nkill .. "（应 1）" end

    -- ★ 反向①：杀一个根本不存在的 id，**不该**产出事件
    --   （否则「kill 事件数」这个判据可以靠瞎调函数刷出来）
    SE:KillSound("never_existed")
    if #A.Drain() ~= 0 then return false, "KillSound 一个不存在的 id 也产出了事件" end

    -- ★ 反向②：KillAllSounds 之后必须一个都不剩，且事件里带**被停掉的数量**
    SE:KillSound("id2")             -- 把上一段留下的 id2 也停掉，让「还剩几个」可确定
    A.Reset()
    SE:PlaySound("s3", "id3")
    A.Reset()
    SE:KillAllSounds()
    local n = 0
    for _ in pairs(SE._playing) do n = n + 1 end
    if n ~= 0 then return false, "KillAllSounds 之后还剩 " .. n .. " 个在响" end
    local ev2 = A.Drain()
    if #ev2 ~= 1 or ev2[1].kind ~= "killall" then return false, "没产出 killall 事件" end
    if ev2[1].n ~= 1 then return false, "killall 事件里的 n=" .. tostring(ev2[1].n) .. "（应 1）" end
    return true, "kill 事件 1 条 ✔ / 杀不存在的 id 不产事件 ✔ / killall 带 n=1 ✔"
end)


--=========================================================================
-- ★ L6（2026-10-19）：**模块级**断言 —— 不经过世界/实体，直接测模块本身的契约
--
-- 为什么补这一段
--   上面 90 多条几乎全是**集成级**：先造世界、再生成实体、再观察行为。
--   集成级能证明「整条链路通」，但**定位差**：模块自己的契约（比如「列目录在拿不到
--   任何来源时必须返回空表而不是抛」）被埋在世界的噪音里，坏了只看到
--   「某个 brain 的行为类是 nil」这种离病因很远的现象。
--   M6/M3/M7 这三个改动都新增了独立模块或独立计数器，正好先给它们补模块级判据。
--=========================================================================
hr("模块级断言（L6：filelist / worldmount / A* 计数）")

check("31_filelist：真列得出 prefabs（全 .lua）且 source 说得清来源", function()
    local FL = require("host.31_filelist")
    local names, src = FL.List(Core.SourceDir .. "/prefabs")
    if type(names) ~= "table" then return false, "返回的不是表" end
    if #names < 100 then
        return false, "只列出 " .. #names .. " 个（prefabs 有 1500+ 个 .lua）"
    end
    for i = 1, #names do
        if not names[i]:match("%.lua$") then
            return false, "第 " .. i .. " 项不是 .lua：" .. tostring(names[i])
        end
    end
    if not (src == "filelist" or src == "ls" or src == "dir") then
        return false, "source 非法：" .. tostring(src)
    end
    return true, #names .. " 个文件名 / 来源=" .. src
end)

check("31_filelist 反向：目录不存在 ⇒ 空表 + source=none（**不许抛**）", function()
    local FL = require("host.31_filelist")
    local ok, names, src = pcall(FL.List, Core.SourceDir .. "/__no_such_dir__")
    if not ok then return false, "抛了异常：" .. tostring(names) end
    if type(names) ~= "table" then return false, "没返回表" end
    if #names ~= 0 then return false, "居然列出了 " .. #names .. " 个" end
    if src ~= "none" then return false, "source=" .. tostring(src) .. "（应为 none）" end
    return true, "空表 / source=none（调用方据此 NoteGap，不会被静默骗）"
end)

check("30_worldmount：组件清单唯一（无重复）且含五个必需项", function()
    local WM = require("host.30_worldmount")
    local C = WM.COMPONENTS
    if type(C) ~= "table" then return false, "COMPONENTS 不是表" end
    local seen, dup = {}, nil
    for _, nm in ipairs(C) do
        if seen[nm] then dup = nm end
        seen[nm] = true
    end
    if dup ~= nil then return false, "重复项：" .. dup end
    local need = { "clock", "worldtemperature", "seasons", "shardstate", "worldreset" }
    for _, nm in ipairs(need) do
        if not seen[nm] then return false, "缺必需组件：" .. nm end
    end
    return true, #C .. " 个组件无重复 / 五个必需项齐全"
end)

check("30_worldmount 反向：W 为 nil ⇒ mounted=0 且 ok=false（不许假装挂上）", function()
    local WM = require("host.30_worldmount")
    local ok, out = pcall(WM.Mount, nil)
    if not ok then return false, "抛了异常：" .. tostring(out) end
    if out == nil then return false, "没返回结果表" end
    if #out.mounted ~= 0 then return false, "居然挂上了 " .. #out.mounted .. " 个" end
    if out.ok ~= false then return false, "ok=" .. tostring(out.ok) .. "（应为 false）" end
    return true, "mounted=0 / ok=false（与「真挂上」可区分）"
end)

check("A* 计数：M7 的新计数器接在调试串上（预算 / 回收）", function()
    local Map = require("host.20_map")
    if type(Map.path_last_why) ~= "function" then
        return false, "path_last_why 不是函数（诊断入口缺失）"
    end
    local PF = Map.Pathfinder
    if PF == nil or PF.GetDebugString == nil then return false, "Pathfinder 缺 GetDebugString" end
    local s = PF:GetDebugString(1)
    if type(s) ~= "string" then return false, "GetDebugString 没返回字符串" end
    if not s:find("预算") then return false, "调试串里没有「预算」计数：" .. s end
    if not s:find("回收") then return false, "调试串里没有「回收」计数：" .. s end
    return true, "调试串带预算与回收计数（M7 的 evicted/budget_hit 真的接出来了）"
end)

hr("汇总")
--=========================================================================
local nfail, nskip = 0, #skipped
for _, r in ipairs(results) do
    if not r.ok then nfail = nfail + 1 end
end
-- ★ 总数 = 通过 + 失败 + 跳过（**跳过必须算进分母**，否则「82 条全绿」这句话
--   在缺环境的机器上就变成「80 条全绿 + 2 条没人跑」而不自知）。
print(string.format("  共 %d 条断言，失败 %d 条，跳过 %d 条",
    #results + nskip, nfail, nskip))
print("")
for _, r in ipairs(results) do
    print(string.format("  %s %-44s %s", r.ok and "✔" or "✘", r.name, r.info))
end
for _, s in ipairs(skipped) do
    print(string.format("  ⊘ %-44s 跳过：%s", s.name, s.why))
end
print("")
if nfail == 0 then
    if nskip > 0 then
        print(string.format("  总判定：✔ 全部通过（但 %d 条**跳过未执行**，见上面 ⊘ 与原因）", nskip))
    else
        print("  总判定：✔ 全部通过")
    end
else
    print(string.format("  总判定：✘ 有失败项（%d 条失败，%d 条跳过）", nfail, nskip))
end

-- ★★ 失败必须让**进程**知道（2026-10-17 补）。
--   为什么：`07-通用引擎/tests/run_all.sh` 的「③ 宿主回归」是用
--   `grep -E "^  5\.1 +PASS"` 判 14 个入口的，而 `_run_lua.py` 的 PASS
--   **只代表「chunk 没抛异常」** —— 也就是说：本文件打印「✘ 有失败项」时，
--   那一关**照样是 ✔**（一次实测：82 条里失败 2 条，③ 仍报 14/14 全过）。
--   这正是本工程记过的「词在≠行为在」：判据看着在，实际什么都没验。
--   ⇒ 直接把失败变成异常（chunk 抛 ⇒ runner 报 FAIL ⇒ ③ 真的变红）。
if nfail > 0 then
    error(string.format(
        "tests.lua 有 %d 条断言失败（另有 %d 条跳过）—— 以异常收尾，"
        .. "让 14 入口那道门**真的**变红", nfail, nskip), 0)
end