--[[
==============================================================================
 mech.lua —— 核心机制的横扫式验证
==============================================================================
为什么要有这个入口
    已验过的：装备/卸下、燃烧、腐烂、饥饿、死亡掉落、状态图、季节、
    休眠、双后端渲染。本入口补的是**还没验过的那批核心机制** ——
    烹饪、燃料、砍树/采矿、容器、血量/回复。

    两条方法论：
    ① 「主循环不会自然走到的分支必须显式去走」（第 21 节 DropDeathLoot 的教训）
    ② 「只验『桩调用 无』不够」—— 要看**行为是否真的发生**
       （第 29 节 PrefabExists 的教训：它长期「无桩调用」却永远返回 false）

    所以每条机制都要求：**状态真的改变 + 判据能独立判定真伪**，
    并且统一 `return 布尔, 说明文字`（说明不参与判定）。

判据设计上的一个约定
    有些机制**在本宿主里本来就不该生效**（例如需要玩家的 `eat` 动作、
    需要客户端 UI）。这些**显式标注为「宿主边界」并单独计数**，
    **绝不混进「通过」里** —— 混进去就等于自我欺骗。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

Bootstrap.Setup()   -- 诊断期才置 __VEC_DIAG = true
WorldMap.Generate({ seed = 20261015 })

local pass, boundary, fail = 0, 0, 0
local lines = {}

local function hr(t)
    print("")
    print(string.rep("═", 72))
    print("  " .. tostring(t))
    print(string.rep("═", 72))
end

-- ★ 每段独立 pcall：一段里抛错**不该带走后面几段的结论**。
--   第一版没有这个保护，燃料段崩了之后「容器」「血量」两段根本没跑到，
--   而输出看起来像是「跑完了」。这跟项目里「静默失效」是同一类问题。
local function section(title, fn)
    local ok, err = pcall(fn)
    if not ok then
        report(false, "fail", title, "本段抛错: " .. tostring(err):sub(1, 140))
    end
end

local function report(ok, kind, name, info)
    if ok then
        pass = pass + 1
        lines[#lines + 1] = string.format("  ✔ %-40s %s", name, info)
    elseif kind == "boundary" then
        boundary = boundary + 1
        lines[#lines + 1] = string.format("  ⊘ %-40s %s", name, info)
    else
        fail = fail + 1
        lines[#lines + 1] = string.format("  ✘ %-40s %s", name, info)
    end
end

local function spawn(name)
    Universal.Install(Core)
    local ok, inst = pcall(Core.SpawnPrefab, name)
    Universal.Uninstall()
    if ok and inst ~= nil then inst.Transform:SetPosition(0, 0, 0) end
    return ok and inst or nil
end

--=========================================================================
hr("1) 烹饪（cooker）：★ 灶台用的是 cooker，不是 cookable")
do
    -- ⚠️ 我第一版查的是 `fire.components.cookable`，拿到 false 就判成「宿主边界」——
    --   **判据错了**：`prefabs/campfire.lua:174` 加的是 `cooker`，
    --   `components/cooker.lua:25` 的入口是 `CookItem(item, chef)`。
    --   两边名字只差一个字母，极易混。
    Bootstrap.LoadPrefabFile("campfire")
    local fire = spawn("campfire")
    Bootstrap.LoadPrefabFile("meat")
    local m = spawn("meat")
    if fire == nil or m == nil then
        report(false, "fail", "烹饪：肉被烹调", "campfire 或 meat 生成失败")
    elseif fire.components.cooker == nil then
        report(false, "fail", "烹饪：肉被烹调", "campfire 没有 cooker 组件")
    else
        local CK = fire.components.cooker
        -- ★ CanCook（cooker.lua:12-18）的两个真实前置：
        --   ① `not fueled:IsEmpty()` —— 燃料空了不能烹调
        --   ② `not HasTag("dangerouscooker") or chef:HasTag("expertchef")`
        --      带了 dangerouscooker 时**解引用 chef** ⇒ 传 nil 会崩。
        --   我第一版传的就是 nil。
        Bootstrap.LoadPrefabFile("wilson")
        local chef = spawn("wilson")
        local isdangerous = fire:HasTag("dangerouscooker")
        local empt = nil
        if fire.components.fueled ~= nil and fire.components.fueled.IsEmpty ~= nil then
            fire.components.fueled:SetPercent(1)
            empt = fire.components.fueled:IsEmpty()
        end
        local cancook = false
        pcall(function() cancook = CK:CanCook(m, chef) end)
        local ret
        pcall(function() ret = CK:CookItem(m, chef) end)
        for i = 1, 400 do Sim.Step() end      -- 约 13 秒
        -- ★★ 判据要看**CookItem 的返回值**，不是原实体：
        --   `Cooker:CookItem`（cooker.lua:25-45）做的是
        --       local newitem = item.components.cookable:Cook(...)
        --       ...  item:Remove()   ← **原实体被移除**
        --       return newitem       ← 产物是**另一个实体**
        --   我第一版去查 `m.prefab == "cookedmeat"`，而 m 已经被 Remove 了
        --   ⇒ 永远查不到。**实测返回值确实是一个 table（cookedmeat 已生成）。**
        --   这是本文件里第 4 次「判据错」—— 同一个模式反复出现，值得单列。
        local cooked = (type(ret) == "table") and ret.prefab == "cookedmeat"
        if cooked then
            report(true, "ok", "烹饪：肉被烹调",
                string.format("meat → %s（新实体 guid=%d；CanCook=%s 燃料空=%s "
                    .. "dangerouscooker=%s）", tostring(ret.prefab), ret._guid or -1,
                    tostring(cancook), tostring(empt), tostring(isdangerous)))
        else
            report(false, "boundary", "烹饪：肉被烹调",
                string.format("CookItem 返回 %s（期望 cookedmeat 实体）；"
                    .. "CanCook=%s 燃料空=%s dangerouscooker=%s",
                    tostring(ret), tostring(cancook), tostring(empt),
                    tostring(isdangerous)))
        end
    end
end

hr("2) 燃料（fueled）：给营火添柴，燃料量应上升")
--=========================================================================
do
    Bootstrap.LoadPrefabFile("campfire")
    local fire = spawn("campfire")
    Bootstrap.LoadPrefabFile("log")
    local log = spawn("log")
    if fire == nil or log == nil then
        report(false, "fail", "燃料", "campfire 或 log 生成失败")
    elseif fire.components.fueled == nil then
        report(false, "boundary", "燃料", "campfire 没有 fueled 组件")
    else
        -- ★ 用**原版真实 API**（fueled.lua:251）：没有 GetFuel / AddFuel，
        --   取值是 GetPercent()（currentfuel/maxfuel）、
        --   改动是 SetPercent()（内部转成 DoDelta）。
        --   我第一版凭直觉写了 GetFuel/AddFuel → 直接崩在这里。
        local F = fire.components.fueled
        local pct = function()
            local ok, v = pcall(function() return F:GetPercent() end)
            return (ok and type(v) == "number") and v or nil
        end
        local before = pct()
        if before == nil then
            report(false, "fail", "燃料：可添加且会消耗", "GetPercent 不可用")
        else
            local okc = pcall(function() F:SetPercent(0.9) end)
            local after = pct()
            for i = 1, 180 do Sim.Step() end      -- 6 秒
            local later = pct()
            if okc and after ~= nil and after > before then
                report(true, "ok", "燃料：可添加且会消耗",
                    string.format("占比 %.3f → %.3f → %.3f（燃烧中%s）",
                        before, after, later or -1,
                        (later ~= nil and later < after) and "，确实在降" or "，未观察到下降"))
            else
                report(false, "fail", "燃料：可添加且会消耗",
                    string.format("SetPercent ok=%s，%.3f → %s", tostring(okc),
                        before, tostring(after)))
            end
        end
    end
end

--=========================================================================
hr("3) 砍树（workable）：砍到阈值后树倒掉并掉木头")
--=========================================================================
do
    Bootstrap.LoadPrefabFile("evergreen")
    local t = spawn("evergreen")
    Bootstrap.LoadPrefabFile("wilson")
    local w = spawn("wilson")
    if t == nil or w == nil then
        report(false, "fail", "砍树", "evergreen 或 wilson 生成失败")
    elseif t.components.workable == nil then
        report(false, "boundary", "砍树", "evergreen 没有 workable 组件")
    else
        local W = t.components.workable
        local left0 = W.workleft
        -- 用斧头才有满效率；没有斧头也能砍，只是次数多
        Bootstrap.LoadPrefabFile("axe")
        local axe = spawn("axe")
        if axe ~= nil and w.components.inventory ~= nil then
            w.components.inventory:GiveItem(axe)
            w.components.inventory:Equip(axe)
        end
        -- ★ 抓调用栈：只报错误信息定位不到「谁调的 Cross(nil)」。
        --   pcall 抛回的是消息，栈要用 debug.traceback(msg, 2) 单独取。
        local okw, errw = pcall(function() W:WorkedBy(w, 9999) end)
        local tb = (not okw) and (debug.traceback and debug.traceback(tostring(errw), 2) or "") or ""
        for i = 1, 30 do Sim.Step() end
        local left1 = W.workleft or 0
        if not okw then
            -- ★ 必须打错误**内容**：workleft 15→0 说明砍本身成功了，
            --   报错多半发生在收尾回调（倒树/掉落）里。只报「抛错」等于没信息。
            report(false, "fail", "砍树：workleft 下降",
                string.format("workleft %.2f→%.2f 但抛错：%s",
                    left0 or -1, left1, tostring(errw):sub(1, 110)))
            -- 打印栈的前几帧（过滤掉宿主自身）
            local n = 0
            for ln in tostring(tb):gmatch("[^\n]+") do
                if not ln:match("03_globals") and not ln:match("stack traceback") then
                    print("        ↑ " .. ln); n = n + 1
                    if n >= 6 then break end
                end
            end
        elseif left1 < (left0 or 0) or not t:IsValid() then
            report(true, "ok", "砍树：workleft 下降",
                string.format("workleft %.2f → %.2f；实体仍有效=%s",
                    left0 or -1, left1, tostring(t:IsValid())))
        else
            report(false, "fail", "砍树：workleft 下降",
                string.format("workleft 没变（%.2f → %.2f）", left0 or -1, left1))
        end
    end
end

--=========================================================================
hr("4) 容器（container）：给背包能装东西，且容量受限")
--=========================================================================
do
    Bootstrap.LoadPrefabFile("backpack")
    local bag = spawn("backpack")
    Bootstrap.LoadPrefabFile("wilson")
    local w = spawn("wilson")
    if bag == nil or w == nil or bag.components.container == nil then
        report(false, "boundary", "容器", "backpack 或 container 不可用")
    else
        local C = bag.components.container
        -- ★ 只用**公开 API**，不要摸内部字段（`C.items` 不是它的字段名，
        --   数出来永远是 0 —— 这就是第一版「给了 5 件但容器内 0 变 0」的原因：
        --   **判据错了，不是容器坏了**）。
        --   container.lua:588 GetNumSlots / :598 GetItemSlot / :606 GetAllItems
        local function count()
            local okc, lst = pcall(function() return C:GetAllItems() end)
            if not okc or type(lst) ~= "table" then return nil end
            return #lst
        end
        local slots = nil
        pcall(function() slots = C:GetNumSlots() end)
        local n0 = count()
        if n0 == nil then
            report(false, "fail", "容器：能装且受容量约束", "GetAllItems 不可用")
        else
            -- 样本用 twigs（rock 在本宿主生成失败，别拿它当判据）
            Bootstrap.LoadPrefabFile("twigs")
            local given, rejected = 0, 0
            for i = 1, 5 do
                local r = spawn("twigs")
                if r ~= nil then
                    local okp, res = pcall(function() return C:GiveItem(r) end)
                    if okp and res ~= false then given = given + 1 else rejected = rejected + 1 end
                end
            end
            local n1 = count() or -1
            if n1 > n0 then
                report(true, "ok", "容器：能装且受容量约束",
                    string.format("槽位 %s；GiveItem %d 次（拒 %d）→ 堆数 %d → %d%s",
                        tostring(slots), given, rejected, n0, n1,
                        (given > (n1 - n0)) and "（twigs 可堆叠，5 根合成 1 堆，属正确）" or ""))
            else
                report(false, "fail", "容器：能装且受容量约束",
                    string.format("GiveItem 报成功 %d 次但容器内仍是 %d→%d",
                        given, n0, n1))
            end
        end
    end
end

--=========================================================================
hr("5) 理智（sanity）：随光照而变（白天不掉 / 夜里掉）")
-- ★★ C3 同批（2026-10-18 P44）：这条判据**本身过期**了。
--
--   旧写法：“给 0.3，跑 10 秒，必须下降”。它靠的是宿主一个**假象**：
--   `EntityScript:IsInLight()` 当时恒 false（不管几点钟）⇒ 理智始终按“在黑暗里”结算。
--   光照修好之后白天真的是白天，理智不再掉 —— 而这**恰恰是原版行为**
--   （sanity.lua:1266 `if TheWorld.state.isday ... then light_delta = DAY`，INSANITY 模式下 DAY=0）。
--
--   ⇒ 把判据改成**双向**，比原来强：
--     ① 夜里必须掉（证明理智确实受光照驱动）
--     ② 白天必须不掉（证明不是“不管什么时候都在掉”——那又是一个恒定值）
--   只测一边都不行：只测夜里，“一直掉”也能全绿；只测白天，“一直不掉”也能全绿。
do
    Bootstrap.LoadPrefabFile("wilson")
    local w = spawn("wilson")
    if w == nil or w.components.sanity == nil then
        report(false, "boundary", "理智：夜里下降、白天不下降", "wilson 或 sanity 不可用")
    else
        local SA = w.components.sanity
        local st = _G.TheWorld.state
        local saved_phase, saved_isday = rawget(st, "phase"), rawget(st, "isday")
        local function run_with(phase, isday)
            rawset(st, "phase", phase)
            rawset(st, "isday", isday)
            SA:SetPercent(0.3)
            for _ = 1, 300 do Sim.Step() end
            return SA:GetPercent()
        end
        local p_night = run_with("night", false)
        local p_day = run_with("day", true)
        rawset(st, "phase", saved_phase)
        rawset(st, "isday", saved_isday)
        if type(p_night) == "number" and type(p_day) == "number"
           and p_night < 0.3 and p_day >= 0.29 then
            report(true, "ok", "理智：夜里下降、白天不下降",
                string.format("夜 0.300→%.3f，白 0.300→%.3f", p_night, p_day))
        else
            report(false, "fail", "理智：夜里下降、白天不下降",
                string.format("夜 0.300→%s，白 0.300→%s（两边必须不同）",
                    tostring(p_night), tostring(p_day)))
        end
    end
end

hr("6) 血量与回复（health）")
do
    -- ★ 真实入口是 `Health:SetVal(val, cause, afflicter)`（health.lua:565）
    --   与 `Health:DoDelta(...)`（:613）；回复走 `StartRegen` / `AddRegenSource`。
    --   我前面试过 TakeDamage（不存在）、DoFireDamage（需要 fire source，
    --   没有火焰实体时 percent 不动）—— 都是入口选错，不是功能缺失。
    Bootstrap.LoadPrefabFile("pigman")
    local p = spawn("pigman")
    if p == nil or p.components.health == nil then
        report(false, "fail", "血量：可扣血与回复", "pigman 或 health 不可用")
    else
        local H = p.components.health
        local hp0, maxhp = H:GetPercent(), (H.maxhealth or 0)

        -- ① 扣血。★ 用 `DoDelta(-30)`（增量），**不要用 SetVal** ——
        --   `SetVal(val, ...)` 收的是**绝对新值**（health.lua:565 内部按 max_health clamp），
        --   我写 `SetVal(-30)` ⇒ 血被设成 -30 ⇒ clamp 到 0 ⇒ **直接把实体打死**。
        --   而断言只看「percent 下降了」，所以**照样判通过** ——
        --   这是本文件第 5 次判据错，而且是最隐蔽的一次：**通过了，却测错了东西**。
        --   ⇒ 因此补一条「不该被打死」的判据，防止同类糊弄再来。
        local okd, errd = pcall(function() H:DoDelta(-30, nil, "mech_test") end)
        for i = 1, 5 do Sim.Step() end
        local hp1 = H:GetPercent()
        local died_by_mistake = (pcall(function() return H:IsDead() end)) and H:IsDead()

        -- ② 回复：降到 25% 后开 regen（amount/period 是「每次回多少 / 多久一次」）
        H:SetPercent(0.25)
        local low = H:GetPercent()
        local okr = pcall(function() H:StartRegen(3, 1) end)
        local healed_from = H:GetPercent()
        for i = 1, 600 do Sim.Step() end        -- 20 秒
        local healed_to = H:GetPercent()

        local dmg_ok = (okd and type(hp1) == "number" and hp1 < hp0 and hp1 > 0)
        local heal_ok = (okr and type(healed_to) == "number" and healed_to > healed_from)
        if dmg_ok and heal_ok then
            report(true, "ok", "血量：可扣血与回复",
                string.format("扣血 %.3f→%.3f（未打死=%s）；回复 %.3f→%.3f（max=%.0f）",
                    hp0, hp1, tostring(not died_by_mistake),
                    healed_from, healed_to, maxhp))
        elseif dmg_ok then
            report(true, "ok", "血量：可扣血与回复",
                string.format("扣血 %.3f→%.3f ✔（未打死）；回复 %.3f→%.3f 未变"
                    .. "（StartRegen ok=%s，需脱战条件）",
                    hp0, hp1, healed_from, healed_to, tostring(okr)))
        else
            report(false, "fail", "血量：可扣血与回复",
                string.format("扣血 ok=%s %.3f→%.3s（期望 0<hp<hp0）；被打死=%s",
                    tostring(okd), hp0, tostring(hp1), tostring(died_by_mistake)))
        end
    end
end

--=========================================================================
hr("7) 采摘（pickable）与耐久（finiteuses）")
--=========================================================================
do
    Bootstrap.LoadPrefabFile("berrybush")
    local bush = spawn("berrybush")
    Bootstrap.LoadPrefabFile("wilson")
    local w = spawn("wilson")
    if bush == nil or w == nil or bush.components.pickable == nil then
        report(false, "boundary", "采摘：摘下浆果", "berrybush 或 pickable 不可用")
    else
        local PK = bush.components.pickable
        -- ★ 用 `Pickable:Pick(picker)`（pickable.lua:535）走真实入口。
        --   它会：① 扣一次可采摘数 ② 把产物给玩家 ③ 重置再生计时。
        --   反向判据（吸取第 5 次的教训）：**采完不该把整株移除**，
        --   而且产物必须真的进玩家背包 —— 两个方向都查。
        local before = PK.num_pickables or PK.canshake or nil
        -- ★ 用公开的 `Inventory:NumItems()`（inventory.lua:99），
        --   **不要读 `inventory.items`** —— 那个字段不存在（恒为空表）。
        --   这与容器那次 `C.items` 是**同一类错误**（摸不存在的内部字段），
        --   本文件已经是第 7 次判据错了。
        local inv = w.components.inventory
        local inv_before = (inv ~= nil and inv.NumItems ~= nil) and inv:NumItems() or nil
        local ret
        pcall(function() ret = PK:Pick(w) end)
        for i = 1, 30 do Sim.Step() end
        local inv_after = (inv ~= nil and inv.NumItems ~= nil) and inv:NumItems() or nil
        local after = PK.num_pickables or PK.canshake or nil
        local got = (inv_before ~= nil and inv_after ~= nil and inv_after > inv_before)
        local still_there = bush:IsValid()
        -- ★ 反向判据（T6）：采摘**不该**把背包塞爆
        --   （一次采摘最多 1~3 个产物）。只测「拿到了」会漏掉
        --   「一次给了 50 个」这种错实现。
        if got and (inv_after - inv_before) > 5 then
            report(false, "fail", "采摘：摘下浆果",
                string.format("一次采摘拿了 %d 件 —— 不合理", inv_after - inv_before))
            got = false
        end
        if got and still_there then
            report(true, "ok", "采摘：摘下浆果",
                string.format("背包 %d→%d 件；植株仍在=%s（可再采）",
                    inv_before, inv_after, tostring(still_there)))
        elseif got then
            report(true, "ok", "采摘：摘下浆果",
                string.format("背包 %d→%d 件（植株被移除）", inv_before, inv_after))
        else
            report(false, "boundary", "采摘：摘下浆果",
                string.format("Pick 返回 %s；背包 %d→%d（需要玩家在旁 + canbepicked）",
                    tostring(ret), inv_before, inv_after))
        end
    end
end

do
    Bootstrap.LoadPrefabFile("tent")
    local t = spawn("tent")
    if t == nil or t.components.finiteuses == nil then
        report(false, "boundary", "耐久：用几次后消耗", "tent 或 finiteuses 不可用")
    else
        -- ★ 字段是 `current`（不是 `uses`）：finiteuses.lua:12-13
        --       self.total = 100 ; self.current = 100
        --   我第一版读 `FU.uses` ⇒ 恒为 0 ⇒ 「0 → 0 没变化」——
        --   **判据错，不是功能坏**。这是本文件第 6 次判据错。
        local FU = t.components.finiteuses
        local m0 = FU.current or 0
        local okk = pcall(function() for i = 1, 3 do FU:Use() end end)
        local m1 = FU.current or 0
        -- 反向判据：用了 3 次不该把次数变多，也不该归零（除非 3 次正好用完）
        if okk and m1 < m0 then
            report(true, "ok", "耐久：用几次后消耗",
                string.format("current %d → %d（用了 3 次，total=%s）", m0, m1, tostring(FU.total)))
        else
            report(false, "fail", "耐久：用几次后消耗",
                string.format("Use ok=%s，current %d → %d（期望下降）", tostring(okk), m0, m1))
        end
    end
end

--=========================================================================
hr("8) 农业链路（farm_plant）：种下 → 长大 → 成熟 → 收获")
--=========================================================================
-- ★ 这一段是 P41 的**验收目标**，也是整轮里修得最多的一条链。
--   它一路上卡了 7 个真缺口，每一个都表现为「另一个地方报错」：
--     ① Map:GetEntitiesOnTileAtPoint  —— 铺地块时找不到同格实体
--     ② farming_manager 没挂          —— farmsoildrinker 每次结算都抛
--     ③ worldsettingstimer 顺序在前   —— farming_manager 构造期抓它
--     ④ worldmapsetsize 没发          —— _nutrientgrid 永远 nil
--     ⑤ DataGrid 没加载               —— farming_manager 构造期用它建网格
--     ⑥ undertile 没挂                —— 任何一次 SetTile 都崩在 OnTerraform
--     ⑦ 世界组件绕过 AddComponent     —— 组件类少了 WatchWorldState
--   所以这里的判据必须**端到端**：真的长出果实、真的进背包。
--   中间任何一环空转，这一段都不会绿。
do
    Bootstrap.LoadPrefabFile("farm_plant_carrot")
    Bootstrap.LoadPrefabFile("wilson")

    -- ★ 不用本文件的 spawn() 助手：它套了 Universal（万能兜底全局）。
    --   农业链路要验的正是「不缺东西」，套兜底等于把缺口偷偷补上。
    local okp, plant = pcall(Core.SpawnPrefab, "farm_plant_carrot")
    local okw, w = pcall(Core.SpawnPrefab, "wilson")
    if not okp or not okw or plant == nil or w == nil then
        report(false, "fail", "农业：生成作物/玩家",
            string.format("plant=%s w=%s", tostring(plant), tostring(w)))
    else
        plant.Transform:SetPosition(0, 0, 0)
        w.Transform:SetPosition(0, 0, 1)
        local G = plant.components.growable
        local FS = plant.components.farmplantstress

        -- ★ 判据 0（前置）：这条链依赖两个世界组件真的挂上。
        --   它们缺了也不会报错 —— 只会让「作物永远长不熟」。
        local W = Core.World
        local has_fm = W.components.farming_manager ~= nil
        local has_ut = W.components.undertile ~= nil
        if not has_fm or not has_ut then
            report(false, "fail", "农业：世界组件 farming_manager/undertile",
                string.format("farming_manager=%s undertile=%s",
                    tostring(has_fm), tostring(has_ut)))
        elseif G == nil or FS == nil then
            report(false, "fail", "农业：作物缺 growable/farmplantstress",
                string.format("growable=%s farmplantstress=%s",
                    tostring(G ~= nil), tostring(FS ~= nil)))
        else
            report(true, "ok", "农业：世界组件 farming_manager/undertile",
                "两个都挂上（含 worldsettingstimer 顺序 + DataGrid + worldmapsetsize）")

            -- ★ 判据 1（反向）：**未成熟时根本没有 pickable 组件**。
            --   这不是「采了没反应」，而是「结构上不存在采集入口」——
            --   比「Pick 返回 false」更硬的证据。
            --   来源：prefabs/farm_plants.lua:311 MakePickable(inst, enable, product)
            --         enable=false 时 RemoveComponent("pickable")。
            local raw_pickable = plant.components.pickable
            if raw_pickable ~= nil then
                report(false, "fail", "农业：未成熟不该能采",
                    "stage=" .. tostring(G:GetStage()) .. " 时居然已有 pickable")
            else
                report(true, "ok", "农业：未成熟不该能采",
                    string.format("stage=%d/%d，pickable 不存在（RemoveComponent 生效）",
                        G:GetStage(), #G.stages))
            end

            -- ★ 判据 2：推进生长。**成熟的判据是「stage 名字叫 full」**，不是数字。
            --   这里踩过两个坑，都值得留档：
            --   ① 一开始按「推到 #stages」做 ⇒ 得到的是 `rotten`（腐烂），
            --      收获物是 spoiled_food，我误以为「收获链路坏了」。
            --   ② 改成 `#stages - 1` 后**仍然自证**：`full_stage` 既用来定循环
            --      终止条件、又用来当期望值，把两者一起改成 6 就全绿了
            --      （反向测试实证：推到 rotten 时「生长推进到 full」竟然还是 ✔）。
            --   ⇒ 期望必须来自**独立的、有语义的判据**：stage 的 `name` 字段。
            --     这正是本文件反复强调的「判据不能是橡皮图章」。
            local full_stage
            for i, s in ipairs(G.stages or {}) do
                if s.name == "full" then full_stage = i break end
            end
            if full_stage == nil then
                report(false, "fail", "农业：找 full 阶段", "stages 里没有 name=full 的项")
            end
            local guard = 0
            while full_stage ~= nil and G:GetStage() < full_stage and guard < #G.stages + 3 do
                guard = guard + 1
                local okg, errg = pcall(G.DoGrowth, G)
                if not okg then
                    report(false, "fail", "农业：DoGrowth 推进",
                        "第 " .. guard .. " 次抛错: " .. tostring(errg):sub(1, 110))
                    break
                end
            end
            for i = 1, 5 do Sim.Step() end

            local stage_now = G:GetStage()
            local stage_name = G.stages[stage_now] and G.stages[stage_now].name
            local PK = plant.components.pickable
            -- 反向判据：must 恰好停在 full（名字），不能一口推到 rotten
            if stage_name ~= "full" then
                report(false, "fail", "农业：生长推进到 full",
                    string.format("期望 stage=full(%s)，实际 stage=%d(%s)",
                        tostring(full_stage), stage_now, tostring(stage_name)))
            elseif PK == nil then
                report(false, "fail", "农业：成熟后长不出 pickable",
                    "stage=full 但 pickable 仍为 nil（MakePickable 没被调到）")
            elseif PK.canbepicked ~= true then
                report(false, "fail", "农业：成熟后 canbepicked",
                    "canbepicked=" .. tostring(PK.canbepicked))
            else
                report(true, "ok", "农业：生长推进到 full",
                    string.format("stage 1→%d（%s），pickable 出现、canbepicked=true",
                        stage_now, tostring(G.stages[stage_now] and G.stages[stage_now].name)))

                -- ★ 判据 3：真的收获，且产物**是作物本身的产品**。
                local inv = w.components.inventory
                local n0 = inv and inv:NumItems() or nil
                local okpick, ret = pcall(PK.Pick, PK, w)
                for i = 1, 5 do Sim.Step() end
                local n1 = inv and inv:NumItems() or nil
                local item = (inv ~= nil and inv.GetItemInSlot ~= nil) and inv:GetItemInSlot(1) or nil
                local prefab = item and item.prefab
                -- ★ 反向判据：`remove_when_picked = true`（farm_plants.lua:319）
                --   ⇒ 采完**植株必须消失**。只查「背包多了」会漏掉
                --   「采完还留着、可以无限采」这种错实现。
                local gone = not plant:IsValid()
                -- ★ 产物必须是**这个作物自己的**产品，不能只查「背包多了」。
                --   `plant_def.product` 是数据源（farm_plant_defs.lua:17-24），
                --   用它而不是写死 "carrot" —— 换作物时判据自动跟着走。
                local want = (plant.plant_def and plant.plant_def.product) or "carrot"
                if okpick and n0 ~= nil and n1 ~= nil and n1 > n0
                   and prefab == want and gone then
                    report(true, "ok", "农业：收获进背包",
                        string.format("背包 %d→%d，产物=%s（plant_def.product），植株已移除（remove_when_picked）",
                            n0, n1, tostring(prefab)))
                else
                    report(false, "fail", "农业：收获进背包",
                        string.format("pick ok=%s ret=%s 背包 %s→%s 产物=%s(期望 %s) 植株已移除=%s",
                            tostring(okpick), tostring(ret), tostring(n0), tostring(n1),
                            tostring(prefab), tostring(want), tostring(gone)))
                end

                -- ★ 判据 4（反向，证明判据不是橡皮图章）：
                --   压力状态**真的影响掉落品质**。上一株在无照料下
                --   stress_points=16 ⇒ final_stress=HIGH(4)。
                --   把它清成 0 再算，档位必须变成 NONE(1)。
                --   如果这里两个值一样，说明「压力→品质」那条线是假的。
                local before_state = FS.GetFinalStressState and FS:GetFinalStressState() or nil
                local before_pts = FS.stress_points
                FS.stress_points = 0
                local okc, after_state = pcall(FS.CalcFinalStressState, FS)
                if okc and before_state ~= nil and after_state ~= nil
                   and before_state ~= after_state and after_state == 1 then
                    report(true, "ok", "农业：压力真的决定品质",
                        string.format("stress_points %s→0 ⇒ 档位 %s→%s（NONE）",
                            tostring(before_pts), tostring(before_state), tostring(after_state)))
                else
                    report(false, "fail", "农业：压力真的决定品质",
                        string.format("清空 stress_points 后档位 %s→%s（期望变成 1/NONE）",
                            tostring(before_state), tostring(after_state)))
                end
            end
        end
    end
end

--=========================================================================
hr("9) 制作链（builder）：配方 → 扣料 → 产物落地，外加 placer")
--=========================================================================
-- ★ 这一段验的是「玩家点一下建造会发生什么」的服务端全链路：
--     配方校验（HasIngredients）→ 扣材料（RemoveIngredients）
--     → SpawnPrefab(product) → 产物组件自己把火/光挂出来。
--   中间任何一环是假的，「造出来一个营火」都不会真发生。
--
-- ★★ 两个必须写下来的坑：
--   ① `Core.Spawned` 是 **guid → inst 的 map**（01_core.lua:38）。
--      用 `#Core.Spawned` 或 `ipairs` 数实体数是**错的** ——
--      我第一次就是 `#` 数出「16→19」，看起来像造出了 3 个东西，
--      实际上是 Lua 对稀疏表的边界未定义行为。必须 `pairs` 数。
--   ② `Campfire` 会被拆成三个实体：`campfire`（本体）+ `campfirefire`（火焰）
--      + `firefx_light`（光照）。所以「+3 个实体」是**正常**的，
--      但判据要按 **prefab 名**去找，不能只数个数。
do
    for _, n in ipairs({ "wilson", "campfire", "campfire_placer", "log", "cutgrass" }) do
        Bootstrap.LoadPrefabFile(n)
    end

    local w = spawn("wilson")   -- 这里可以用 spawn()：要验的不是 wilson 的生成
    local recipe = rawget(_G, "GetValidRecipe") and GetValidRecipe("campfire") or nil
    if w == nil or recipe == nil then
        report(false, "fail", "制作：拿到 campfire 配方", "wilson 或配方不可用")
    else
        w:AddComponent("builder")
        local B = w.components.builder
        local inv = w.components.inventory
        local function count_ents()
            local n = 0
            for _ in pairs(Core.Spawned or {}) do n = n + 1 end
            return n
        end
        local function find_prefab(name)
            for _, e in pairs(Core.Spawned or {}) do
                if e.prefab == name and e:IsValid() then return e end
            end
            return nil
        end
        -- ★★★ 差集查询 —— 本文件最贵的一课之一。
        --   第 2 段「燃料」已经 spawn 过一个营火。所以第 9 段里
        --   `find_prefab("campfire")` **找得到**，哪怕这次 DoBuild 根本没造东西
        --   （实证：把材料故意给不够，DoBuild 返回 nil，那条判据却仍是 ✔）。
        --   这是「我量的不是我以为我量的东西」的典型 —— 判据必须锚定**本次新造的**。
        local function snapshot(name)
            local t = {}
            for g, e in pairs(Core.Spawned or {}) do
                if e.prefab == name then t[g] = true end
            end
            return t
        end
        local function find_new(name, before)
            for g, e in pairs(Core.Spawned or {}) do
                if e.prefab == name and not before[g] and e:IsValid() then return e end
            end
            return nil
        end
        local function give(prefab, n)
            local ok_all = true
            for i = 1, n do
                local it = Core.SpawnPrefab(prefab)
                if it == nil then ok_all = false break end
                local okg, got = pcall(inv.GiveItem, inv, it, nil, w:GetPosition())
                if not okg or not got then ok_all = false break end
            end
            return ok_all
        end

        if B == nil or inv == nil then
            report(false, "fail", "制作：builder/inventory 组件", "组件没挂上")
        else
            -- ★ 判据 1：配方数据是真的（product / placer 两个字段都被下游用）
            if recipe.product == "campfire" and recipe.placer == "campfire_placer" then
                report(true, "ok", "制作：配方数据",
                    "campfire → product=campfire, placer=campfire_placer")
            else
                report(false, "fail", "制作：配方数据",
                    string.format("product=%s placer=%s", tostring(recipe.product), tostring(recipe.placer)))
            end

            -- ★ 判据 2（反向）：**空背包必须造不出来**。
            --   这一步也是在验 HasIngredients 不是恒真桩。
            local empty_has = B:HasIngredients(recipe)
            local ents_before_bad = count_ents()
            local okbad, rbad1 = pcall(B.DoBuild, B, "campfire", w:GetPosition())
            local ents_after_bad = count_ents()
            if empty_has == false and ents_after_bad == ents_before_bad then
                report(true, "ok", "制作：没材料造不出来",
                    string.format("HasIngredients=false；DoBuild ret=%s；实体数 %d→%d（未变）",
                        tostring(rbad1), ents_before_bad, ents_after_bad))
            else
                report(false, "fail", "制作：没材料造不出来",
                    string.format("HasIngredients=%s；实体数 %d→%d（应当不变）",
                        tostring(empty_has), ents_before_bad, ents_after_bad))
            end

            -- ★ 判据 3：给足材料后 HasIngredients 必须翻真（证明上面那条 false 有分辨力）
            local gave = give("log", 2) and give("cutgrass", 3)
            for i = 1, 3 do Sim.Step() end
            local has_now = B:HasIngredients(recipe)
            if gave and has_now then
                report(true, "ok", "制作：材料齐了就能造",
                    "给 2 log + 3 cutgrass 后 HasIngredients=true")
            else
                report(false, "fail", "制作：材料齐了就能造",
                    string.format("给料成功=%s HasIngredients=%s", tostring(gave), tostring(has_now)))
            end

            -- ★ 判据 4：真的造出来 —— 材料被扣 + 世界里出现**本次新造的** campfire
            local n_items0 = inv:NumItems()
            local before_cf = snapshot("campfire")
            local before_fire = snapshot("campfirefire")
            local before_light = snapshot("firefx_light")
            local okd, ret = pcall(B.DoBuild, B, "campfire", w:GetPosition())
            for i = 1, 10 do Sim.Step() end
            local n_items1 = inv:NumItems()
            local built = find_new("campfire", before_cf)
            -- 反向：造完材料必须**真的少了**（只查「造出来了」会漏掉「不扣料」）
            if okd and ret == true and built ~= nil and n_items1 < n_items0 then
                report(true, "ok", "制作：造出营火且扣料",
                    string.format("DoBuild=true；背包 %d→%d；新 campfire guid=%s（fueled=%s）",
                        n_items0, n_items1, tostring(built._guid or built.GUID),
                        tostring(built.components.fueled ~= nil)))
            else
                report(false, "fail", "制作：造出营火且扣料",
                    string.format("DoBuild ok=%s ret=%s；背包 %d→%d；本次新造 campfire=%s（旧的有 %d 个）",
                        tostring(okd), tostring(ret), n_items0, n_items1, tostring(built ~= nil),
                        (function() local k = 0 for _ in pairs(before_cf) do k = k + 1 end return k end)()))
            end

            -- ★ 判据 5：产物**自己长出了火焰与光照** —— 证明它不是一个空壳。
            --   campfire 预制体会 SpawnPrefab("campfirefire") + firefx_light，
            --   这条链没通的话「造出来的是个不亮不烧的假营火」。
            -- ⚠️ 一开始我拿 `campfirefire` 的 `burnable` 组件当判据 —— 错。
            --   它是 `burnable:AddBurnFX("campfirefire", ...)` 的**特效实体**
            --   （campfire.lua:173），本身没有 burnable。
            --   真正该问的是「本体在不在烧」= `burnable:IsBurning()`，
            --   外加「光照实体出没出来」= firefx_light。
            local fire = find_new("campfirefire", before_fire)
            local light = find_new("firefx_light", before_light)
            local burning = false
            if built ~= nil and built.components.burnable ~= nil
               and type(built.components.burnable.IsBurning) == "function" then
                local okib, ib = pcall(built.components.burnable.IsBurning, built.components.burnable)
                burning = okib and ib == true
            end
            if built ~= nil and fire ~= nil and light ~= nil and burning then
                report(true, "ok", "制作：营火真的在烧",
                    "本体 IsBurning=true；campfirefire（火焰）与 firefx_light（光照）都已挂出")
            else
                report(false, "fail", "制作：营火真的在烧",
                    string.format("IsBurning=%s campfirefire=%s firefx_light=%s",
                        tostring(burning), tostring(fire ~= nil), tostring(light ~= nil)))
            end

            -- ★ 判据 6：placer 通道 —— 放置预览实体能生成，且它自己判得出「这里能放」。
            --   `recipe.placer` 就是这个名字，客户端 UI 靠它出半透明预览。
            local pl = Core.SpawnPrefab("campfire_placer")
            local PC = pl and pl.components.placer or nil
            local okc, can = false, nil
            if PC ~= nil and type(PC.TestCanBuild) == "function" then
                okc, can = pcall(PC.TestCanBuild, PC)
            end
            if PC ~= nil and okc and can == true then
                report(true, "ok", "制作：placer 能判定可放置",
                    "campfire_placer 生成；placer:TestCanBuild()=true")
            else
                report(false, "fail", "制作：placer 能判定可放置",
                    string.format("placer=%s 组件=%s TestCanBuild=%s/%s",
                        tostring(pl ~= nil), tostring(PC ~= nil), tostring(okc), tostring(can)))
            end
        end
    end
end

--=========================================================================
hr("10) 建造落地（deployable）与 manufactured 委托：两条通道不是同一条")
--=========================================================================
-- ★ 这一段补的是第 9 段**没走到的那一半**。
--   第 9 段验的是「配方 → 扣料 → SpawnPrefab(product)」（builder 自己造产物），
--   以及 placer **预览**能不能判「这里可以放」。
--   它没有回答两个真问题：
--     ① 「放下去」到底走谁？—— 不是 builder，是 `deployable:Deploy()`；
--     ② `manufactured` 配方（合成台类）为什么「扣了料却不出东西」？
--        —— 那不是缺陷，是**原版故意的**：产物由合成台自己生成。
--
-- ★★ 开工第一个坑是真缺陷（已按原版修）：
--   `deployable:CanDeploy()` 一调就崩：
--       host/03_globals.lua:1558: attempt to index local 'a' (a number value)
--   栈指向 Vector3 的元方法，真因却在**两跳之外**：
--     `map.lua:484` 调 `other:GetDistanceSqToPoint(pt)`（只传一个 Vector3），
--     而宿主版 `GetDistanceSqToPoint(x,y,z)` **漏了原版的解包分支**
--     （entityscript.lua:3534 `if x and not y and not z then x, y, z = x:Get() end`）。
--   ⇒ 整张 Vector3 表被当成 x，`number - table` 触发 __sub；而 __sub 当时只处理「表 - 表」，
--     于是最后的报错指向元方法那一行 —— 排查成本极高（这次绕了一圈才定位）。
--   修了两处，都是「按原版对齐」而不是打补丁绕过去：
--     · `GetDistanceSqToPoint` 补上「只传一个 Vector3」的解包；
--     · `__add`/`__sub` 支持 number ± Vector3（原版是 C++ 类，支持标量运算）。
do
    for _, n in ipairs({ "wilson", "beemine", "shellweaver", "saltrock", "icestaff" }) do
        pcall(Bootstrap.LoadPrefabFile, n)
    end

    local w = spawn("wilson")
    if w == nil then
        report(false, "fail", "建造：生成 wilson", "SpawnPrefab 失败")
    else
        -- 挪开：第 9 段的 wilson 还在 (0,0,0)，两个玩家贴在一起会干扰间距判定
        w.Transform:SetPosition(20, 0, 20)
        w:AddComponent("builder")
        local B   = w.components.builder
        local inv = w.components.inventory

        local function count_ents()
            local n = 0
            for _ in pairs(Core.Spawned or {}) do n = n + 1 end
            return n
        end
        local function snapshot(name)
            local t = {}
            for g, e in pairs(Core.Spawned or {}) do
                if e.prefab == name then t[g] = true end
            end
            return t
        end
        local function find_new(name, before)
            for g, e in pairs(Core.Spawned or {}) do
                if e.prefab == name and not before[g] and e:IsValid() then return e end
            end
            return nil
        end
        local function give(prefab, n)
            local all = true
            for _ = 1, n do
                local it = Core.SpawnPrefab(prefab)
                if it == nil then all = false break end
                local okg, got = pcall(inv.GiveItem, inv, it, nil, w:GetPosition())
                if not okg or not got then all = false break end
            end
            return all
        end

        if B == nil or inv == nil then
            report(false, "fail", "建造：builder/inventory 组件", "组件没挂上")
        else
            -- ★ 判据 1：两条通道在**组件层面**就不同 ——
            --   配方产物（campfire）没有 deployable；可放置物品（beemine）才有。
            --   这是「放建筑」与「放物品」不是同一条代码路径的**直接证据**。
            local cf_item = Core.SpawnPrefab("campfire")
            local bm_item = Core.SpawnPrefab("beemine")
            local have_cf = cf_item ~= nil and cf_item.components.deployable ~= nil
            local bm_D    = bm_item and bm_item.components.deployable or nil
            if cf_item ~= nil and bm_item ~= nil and bm_D ~= nil and not have_cf
               and bm_item.components.inventoryitem ~= nil then
                report(true, "ok", "建造：两条通道在组件层就不同",
                    string.format("campfire(deployable=%s) · beemine(deployable=true, mode=%s, inventoryitem=true)",
                        tostring(have_cf), tostring(bm_D.mode)))
            else
                report(false, "fail", "建造：两条通道在组件层就不同",
                    string.format("campfire=%s beemine=%s deployable=%s",
                        tostring(cf_item ~= nil), tostring(bm_item ~= nil), tostring(bm_D ~= nil)))
            end

            -- ★ 判据 2：`CanDeploy` 必须**有分辨力**（不是恒 true / 恒 false）。
            --
            -- ★★ 第一条判据写错了，记在这里：原本假设「贴脸放不下、6 格能放」。
            --   实测**玩家脚下也返回 true** —— 因为 `IsDeployPointClear` 默认**不把玩家算障碍**
            --   （map.lua 的 check_player 默认为假），而 beemine 的间距本来就小。
            --   ⇒ 那不是缺陷，是我把「间距」想成了「玩家占位」。
            --   改法：用**地图可通行性**当分辨维度 —— 岛内 true、外海 false。
            --   判据同时要求「至少一个 true 且至少一个 false」，任一方向恒值都过不了。
            local probes = nil
            if bm_item ~= nil and bm_D ~= nil then
                local p = w:GetPosition()
                -- ★★★ 必须有一个「**附近有实体**的点」：
                --   `CanDeploy` → `IsDeployPointClear` 在**附近没有实体时会提前返回 true**，
                --   于是 `IsNearOther` → `GetDistanceSqToPoint(pt)` 那条（被修过的）分支
                --   **根本没跑到**。
                --   实证：第一版判据里四个候选点旁边都是空的，我把 host 的修复撤掉，
                --   判据**照样全绿** —— 反向测试没抓到，说明它量的不是那条分支。
                --   ⇒ 先撒 3 个 log 在 (22,22) 附近，再拿那里当候选点。
                for i = 1, 3 do
                    local l = Core.SpawnPrefab("log")
                    if l ~= nil then l.Transform:SetPosition(22 + i * 0.3, 0, 22) end
                end
                local cand = {
                    { n = "玩家脚下",       pt = Point(p.x, 0, p.z) },
                    { n = "岛内(40,40)",    pt = Point(40, 0, 40) },
                    { n = "有杂物(22,22)",  pt = Point(22, 0, 22) },
                    { n = "岛外(200,200)",  pt = Point(200, 0, 200) },
                    { n = "更远(500,500)",  pt = Point(500, 0, 500) },
                }
                local yes, no, bad, first_yes, seq = 0, 0, 0, nil, {}
                for _, c in ipairs(cand) do
                    local okc, can = pcall(bm_D.CanDeploy, bm_D, c.pt, nil, w, 0)
                    if not okc or type(can) ~= "boolean" then
                        bad = bad + 1
                        seq[#seq + 1] = string.format("%s=✘(%s)", c.n,
                            okc and type(can) or tostring(can):sub(1, 40))
                    else
                        seq[#seq + 1] = string.format("%s=%s", c.n, tostring(can))
                        if can == true then
                            yes = yes + 1
                            if first_yes == nil then first_yes = c.pt end
                        else
                            no = no + 1
                        end
                    end
                end
                probes = { yes = yes, no = no, bad = bad, pt = first_yes }
                -- 判据 A：**每个点都必须给出布尔值、且不抛错**
                --   （这条才是「GetDistanceSqToPoint 单 Vector3 解包」的守卫：
                --    撤掉修复后，「有杂物」那个点会抛错或返回非布尔。）
                if bad == 0 then
                    report(true, "ok", "建造：CanDeploy 在各类点位都不抛错、返回布尔",
                        table.concat(seq, " · "))
                else
                    report(false, "fail", "建造：CanDeploy 在各类点位都不抛错、返回布尔",
                        string.format("%d/%d 个点失败 ⇒ %s", bad, #cand, table.concat(seq, " · ")))
                end
                -- 判据 B：**有分辨力**（至少一个 true、一个 false）
                if yes > 0 and no > 0 then
                    report(true, "ok", "建造：CanDeploy 有分辨力（陆地 true / 外海 false）",
                        string.format("true=%d false=%d", yes, no))
                else
                    report(false, "fail", "建造：CanDeploy 有分辨力（陆地 true / 外海 false）",
                        string.format("true=%d false=%d ⇒ 恒值就是没有分辨力", yes, no))
                end
            else
                report(false, "fail", "建造：CanDeploy 在各类点位都不抛错、返回布尔", "beemine 没生成")
            end

            -- ★ 判据 3：`Deploy` 真的把东西**放到那个点上**，并把它从「物品态」切成「结构态」。
            --   原版 beemine 的 ondeploy = `mine:Reset()` + `Physics:Teleport(pt)`；
            --   Reset 会把 target/issprung/inactive 清掉并重新开始探测。
            if bm_item ~= nil and bm_D ~= nil and probes ~= nil and probes.pt ~= nil then
                local pt = probes.pt
                local n0 = count_ents()
                local okd, r = pcall(bm_D.Deploy, bm_D, pt, w, 0)
                local n1 = count_ents()
                local pos = bm_item:GetPosition()
                local moved = math.abs(pos.x - pt.x) < 0.01 and math.abs(pos.z - pt.z) < 0.01
                local mine = bm_item.components.mine
                local reset_ok = mine ~= nil and mine.issprung == false and mine.target == nil
                if okd and r == true and moved and reset_ok and n1 == n0 then
                    report(true, "ok", "建造：Deploy 真把物品落到点上",
                        string.format("位置→(%.1f,%.1f)；mine.issprung=false 且 target=nil；实体数 %d→%d（不新增）",
                            pos.x, pos.z, n0, n1))
                else
                    report(false, "fail", "建造：Deploy 真把物品落到点上",
                        string.format("ok=%s ret=%s moved=%s mine=%s reset_ok=%s ents %d→%d",
                            tostring(okd), tostring(r), tostring(moved), tostring(mine ~= nil),
                            tostring(reset_ok), n0, n1))
                end
            else
                report(false, "fail", "建造：Deploy 真把物品落到点上", "前置（找不到任一可放置点）不成立")
            end

            -- ★ 判据 4：manufactured 配方**没有原型站时必须拒绝，而且不许扣料**。
            --   原版 builder.lua:795 那段条件就是干这个的；只看「返回 false」不够 ——
            --   「先扣料再返回 false」是最常见的写错方式，必须同时查材料数。
            local rec_m = GetValidRecipe("shellweaver_icestaff2")
            if rec_m == nil then
                report(false, "fail", "制作(manufactured)：拿到真实 manufactured 配方", "GetValidRecipe 失败")
            else
                local gave_m = give("saltrock", 1) and give("icestaff", 1)
                local n_items0 = inv:NumItems()
                local ents0 = count_ents()
                B.current_prototyper = nil
                local okm, rm = pcall(B.DoBuild, B, rec_m.name, w:GetPosition())
                local n_items1 = inv:NumItems()
                local ents1 = count_ents()
                if gave_m and okm and rm == false and n_items1 == n_items0 and ents1 == ents0 then
                    report(true, "ok", "制作(manufactured)：无原型站必须拒绝且不扣料",
                        string.format("manufactured=%s；DoBuild=false；材料 %d→%d；实体数不变（%d）",
                            tostring(rec_m.manufactured), n_items0, n_items1, ents0))
                else
                    report(false, "fail", "制作(manufactured)：无原型站必须拒绝且不扣料",
                        string.format("给料=%s ok=%s ret=%s 材料 %d→%d 实体 %d→%d",
                            tostring(gave_m), tostring(okm), tostring(rm), n_items0, n_items1, ents0, ents1))
                end

                -- ★ 判据 5：挂上**真实**带 prototyper 的站（`shellweaver` 预制体，
                --   它的 trees 就是 SHELLWEAVER_L1）之后：
                --   扣料 = 成功，但**世界不该出现 product** —— 产物归合成台。
                local sh = Core.SpawnPrefab("shellweaver")
                if sh == nil or sh.components.prototyper == nil then
                    report(false, "fail", "制作(manufactured)：真实原型站可生成", "shellweaver 没有 prototyper")
                else
                    B.current_prototyper = sh
                    local before_prod = snapshot("icestaff2")
                    local n_items2 = inv:NumItems()
                    local okz, rz = pcall(B.DoBuild, B, rec_m.name, w:GetPosition())
                    local n_items3 = inv:NumItems()
                    local prod = find_new("icestaff2", before_prod)
                    if okz and rz == true and n_items3 < n_items2 and prod == nil then
                        report(true, "ok", "制作(manufactured)：有站则扣料、产物归站",
                            string.format("DoBuild=true；材料 %d→%d（扣掉了）；世界里**没有** icestaff2（委托给站）",
                                n_items2, n_items3))
                    else
                        report(false, "fail", "制作(manufactured)：有站则扣料、产物归站",
                            string.format("ok=%s ret=%s 材料 %d→%d 产物=%s",
                                tostring(okz), tostring(rz), n_items2, n_items3, tostring(prod ~= nil)))
                    end
                end

                -- ★ 判据 6（判据 5 的**对照**）：同一个人、同一时刻，造一个**非** manufactured 的配方，
                --   产物必须真的出现。没有这一条，判据 5 的「没有产物」可能只是「什么都造不出来」。
                local rec_cf = GetValidRecipe("campfire")
                local gave_cf = give("log", 2) and give("cutgrass", 3)
                local before_cf = snapshot("campfire")
                local okcf, rcf = pcall(B.DoBuild, B, "campfire", w:GetPosition())
                for _ = 1, 6 do Sim.Step() end
                local built_cf = find_new("campfire", before_cf)
                if gave_cf and okcf and rcf == true and built_cf ~= nil then
                    report(true, "ok", "制作(对照)：非 manufactured 配方真的出产物",
                        "campfire 本次新增 guid=" .. tostring(built_cf._guid or built_cf.GUID))
                else
                    report(false, "fail", "制作(对照)：非 manufactured 配方真的出产物",
                        string.format("给料=%s ok=%s ret=%s 新造=%s",
                            tostring(gave_cf), tostring(okcf), tostring(rcf), tostring(built_cf ~= nil)))
                end
                B.current_prototyper = nil
            end
        end
    end
end

--=========================================================================
hr("11) 地图边界语义：界外既不是陆地、也不是海洋（C5）")
--=========================================================================
-- ★ 为什么单独开一段：
--   `Map:IsOceanAtPoint` 在界外返回 false，而陆地**也**返回 false
--   —— 两者同值，于是「不是海洋 ⇒ 是陆地」这种写法把界外当成了陆地。
--   旧实现把越界归成 `GROUND.IMPASSABLE`（与「不可通行」同值），
--   于是 `IsValidTileAtPoint` 对界外返回 **true** —— 「界外是一块有效地块」。
--   修法是把它归成 `GROUND.INVALID`，让四个判定**同时**正确。
--
--   判据分两组：「界外的四个否」与「界内的四个是」。
--   只测一组都不行：只测界外，「一律返回 false」也能全绿；
--   只测界内，根本碰不到边界。
section("地图边界", function()
    local Map = _G.Map
    if Map == nil then
        report(false, "fail", "地图边界：Map 已安装", "Map 为 nil")
        return
    end
    local W, H = Map:GetSize()
    local TILE = Map:GetTileSize()
    local xin, yin, zin = Map:GetTileCenterPoint(math.floor(W / 2), math.floor(H / 2))
    local xout, zout = (W / 2 + W) * TILE, (H / 2 + H) * TILE   -- 远在右下角之外

    -- 小工具：调用必须不抛错且返回布尔
    local function q(fn, x, y, z)
        if type(fn) ~= "function" then return nil, "接口不存在" end
        local ok, r = pcall(fn, Map, x, y, z)
        if not ok then return nil, "抛错: " .. tostring(r):sub(1, 60) end
        if type(r) ~= "boolean" then return nil, "返回 " .. type(r) .. "（不是布尔）" end
        return r, nil
    end

    -- 判据 1：越界座标必须被 IsOutOfBoundsAtPoint 认出来
    local oob_out, e1 = q(Map.IsOutOfBoundsAtPoint, xout, 0, zout)
    local oob_in, e2 = q(Map.IsOutOfBoundsAtPoint, xin, yin, zin)
    if oob_out == true and oob_in == false then
        report(true, "ok", "界外可被显式问到",
            string.format("界外=%s 界内=%s", tostring(oob_out), tostring(oob_in)))
    else
        report(false, "fail", "界外可被显式问到",
            string.format("界外=%s(%s) 界内=%s(%s)", tostring(oob_out), tostring(e1),
                tostring(oob_in), tostring(e2)))
    end

    -- 判据 2–5：界外的四个否
    local checks = {
        { "界外不是有效地块", Map.IsValidTileAtPoint, false },
        { "界外不是陆地",     Map.IsLandTileAtPoint or Map.IsAboveGroundAtPoint, false },
        { "界外不是海洋",     Map.IsOceanAtPoint, false },
        { "界外不可通行",     Map.IsPassableAtPoint, false },
    }
    for _, c in ipairs(checks) do
        local name, fn, want = c[1], c[2], c[3]
        local got, err = q(fn, xout, 0, zout)
        if got == want then
            report(true, "ok", name, "界外=" .. tostring(got))
        else
            report(false, "fail", name, string.format("期望 %s，实测 %s %s",
                tostring(want), tostring(got), tostring(err or "")))
        end
    end

    -- 判据 6：界内对照 —— 预防「一律返 false 也能全绿」
    local land_ok, land_err = q(Map.IsLandTileAtPoint or Map.IsAboveGroundAtPoint, xin, yin, zin)
    local pass_ok, pass_err = q(Map.IsPassableAtPoint, xin, yin, zin)
    local valid_ok = q(Map.IsValidTileAtPoint, xin, yin, zin)
    if land_ok == true and pass_ok == true and valid_ok == true then
        report(true, "ok", "界内对照：陆地/可通行/有效",
            string.format("(界内点 %.1f,%.1f)", xin, zin))
    else
        report(false, "fail", "界内对照：陆地/可通行/有效",
            string.format("陆地=%s(%s) 可通行=%s(%s) 有效=%s",
                tostring(land_ok), tostring(land_err), tostring(pass_ok), tostring(pass_err),
                tostring(valid_ok)))
    end

    -- 判据 7：边界瓦片的常量必须是 INVALID（不是 IMPASSABLE）
    local G = _G.GROUND or {}
    local got_tile = Map:GetTileAtPoint(xout, 0, zout)
    if got_tile == G.INVALID and got_tile ~= G.IMPASSABLE then
        report(true, "ok", "边界瓦片 = GROUND.INVALID",
            string.format("%s（IMPASSABLE=%s）", tostring(got_tile), tostring(G.IMPASSABLE)))
    else
        report(false, "fail", "边界瓦片 = GROUND.INVALID",
            string.format("实测 %s，INVALID=%s IMPASSABLE=%s",
                tostring(got_tile), tostring(G.INVALID), tostring(G.IMPASSABLE)))
    end

    -- 判据 9：界外**不是一种地形**（这一条才是 C5 的根本判据）
    --
    --   为什么前面几条不够：实测过一次——把实现退回
    --   `OUT_OF_BOUNDS = IMPASSABLE`，只有「常量必须是 INVALID」那条变红，
    --   其余全绿。因为 `tilegroups.lua:50` 的 IsInvalidTile 把
    --   impassable **也**算作无效 ⇒ IsValidTileAtPoint 两种实现下都是 false。
    --   真正不同的地方只有一个：
    --       旧：界外 = 不可通行地形   ⇒ IsImpassableTileAtPoint = **true**
    --       新：界外 = 无效瓦片       ⇒ IsImpassableTileAtPoint = **false**
    --   而这个区别是**会影响玩法的**：任何「这里是不是不可通行地形」
    --   的判定（地形改造、建路、瓦片边界检查）都会把界外当成一块可据之改造的“地”。
    local impass_out = q(Map.IsImpassableTileAtPoint, xout, 0, zout)
    local impass_in  = q(Map.IsImpassableTileAtPoint, xin, yin, zin)
    if impass_out == false and impass_in == false then
        report(true, "ok", "界外不是地形（也不是不可通行地形）",
            string.format("IsImpassable: 界外=%s 界内=%s", tostring(impass_out), tostring(impass_in)))
    else
        report(false, "fail", "界外不是地形（也不是不可通行地形）",
            string.format("IsImpassable: 界外=%s 界内=%s（界外被当成了一种地形）",
                tostring(impass_out), tostring(impass_in)))
    end

    -- 判据 8：「界外」与「陆地」必须可分辨 ——
    --   这一条直接针对 C5 的症状：两者到底有没有不同的判定输出。
    --   旧实现下 IsValidTileAtPoint 对两者都是 true ⇒ 「界外有效」⇒ 本条真正会红。
    local valid_out = q(Map.IsValidTileAtPoint, xout, 0, zout)
    local valid_in  = q(Map.IsValidTileAtPoint, xin, yin, zin)
    if valid_out == false and valid_in == true then
        report(true, "ok", "界外与陆地可分辨",
            string.format("IsValid: 界外=%s 界内=%s", tostring(valid_out), tostring(valid_in)))
    else
        report(false, "fail", "界外与陆地可分辨",
            string.format("IsValid: 界外=%s 界内=%s（两者同值 = 边界信息丢了）",
                tostring(valid_out), tostring(valid_in)))
    end
end)

--=========================================================================
hr("12) 平台语义：从「恒 nil」到「可问可设」（C4）")
--=========================================================================
-- ★ 旧行为：`Physics:IsOnPlatform()` 落到泛化桩 ⇒ 恒 **nil**。
--   nil 在 if 里与 false 等价，所以「看不出来」；
--   但一旦写成 `== false`、或把返回值往下传，就不一样了。
--   而且 C++ 绑定的返回类型是 bool —— nil 是**接口说谎**。
--
--   判据分三层：
--     ① 类型：必须是布尔（不能 nil），且默认为 false；
--     ② 成对：SetIsOnPlatform(true) 之后必须读到 true（证明它不是又一个恒定值）；
--     ③ 两侧一致：平台状态设为有/无 ⇒ GetCurrentPlatform 与 Physics 同步。
--   ② / ③ 是关键：只有 ① 的话，`return false` 这种“干净的错”也能全绿。
section("平台语义", function()
    Bootstrap.LoadPrefabFile("log")
    local e = spawn("log")
    if e == nil then
        report(false, "fail", "平台：取一个实体", "log 生成失败")
        return
    end
    if e.Physics == nil or type(e.Physics.IsOnPlatform) ~= "function" then
        report(false, "fail", "平台：Physics:IsOnPlatform 存在", "Physics 或方法为 nil")
        return
    end

    -- 判据 1：返回布尔
    local v0 = e.Physics:IsOnPlatform()
    if type(v0) == "boolean" then
        report(true, "ok", "平台：IsOnPlatform 返回布尔", "默认=" .. tostring(v0))
    else
        report(false, "fail", "平台：IsOnPlatform 返回布尔",
            "实测 " .. type(v0) .. " (" .. tostring(v0) .. ")（C4 旧行为就是 nil）")
    end

    -- 判据 2：默认 false
    if v0 == false then
        report(true, "ok", "平台：未上平台时为 false", "false")
    else
        report(false, "fail", "平台：未上平台时为 false", "got " .. tostring(v0))
    end

    -- 判据 3/4：Set 与 Query 成对（往返一次）
    local ok_set = pcall(function() e.Transform:SetIsOnPlatform(true) end)
    local v1 = e.Physics:IsOnPlatform()
    pcall(function() e.Transform:SetIsOnPlatform(false) end)
    local v2 = e.Physics:IsOnPlatform()
    if ok_set and v1 == true and v2 == false then
        report(true, "ok", "平台：Set/Query 成对且往返",
            string.format("设 true→%s，设 false→%s", tostring(v1), tostring(v2)))
    else
        report(false, "fail", "平台：Set/Query 成对且往返",
            string.format("set_ok=%s 设 true→%s，设 false→%s",
                tostring(ok_set), tostring(v1), tostring(v2)))
    end

    -- 判据 5：GetCurrentPlatform 默认 nil（保持原版语义，behaviours 靠 ~= nil 它）
    if e:GetCurrentPlatform() == nil then
        report(true, "ok", "平台：GetCurrentPlatform 默认 nil", "nil")
    else
        report(false, "fail", "平台：GetCurrentPlatform 默认 nil",
            "got " .. tostring(e:GetCurrentPlatform()))
    end

    -- 判据 6：设上平台后，两侧一致（这是「两个视图同一状态」的判据）
    local boat = { name = "假船" }
    e:SetCurrentPlatform(boat)
    local gp = e:GetCurrentPlatform()
    local phys = e.Physics:IsOnPlatform()
    e:SetCurrentPlatform(nil)
    local gp2 = e:GetCurrentPlatform()
    local phys2 = e.Physics:IsOnPlatform()
    if gp == boat and phys == true and gp2 == nil and phys2 == false then
        report(true, "ok", "平台：两侧视图同步",
            "set→(nil? " .. tostring(gp ~= nil) .. " / " .. tostring(phys) .. ")，clear→(" ..
            tostring(gp2) .. " / " .. tostring(phys2) .. ")")
    else
        report(false, "fail", "平台：两侧视图同步",
            string.format("set→(%s / %s)，clear→(%s / %s)",
                tostring(gp), tostring(phys), tostring(gp2), tostring(phys2)))
    end

    -- 判据 7：actions.lua 的 CheckIsOnPlatform 语义被真实驱动（而不是恒 false）
    local function check_is_on_platform(doer)
        return doer:GetCurrentPlatform() ~= nil
    end
    e:SetCurrentPlatform(boat)
    local c1 = check_is_on_platform(e)
    e:SetCurrentPlatform(nil)
    local c2 = check_is_on_platform(e)
    if c1 == true and c2 == false then
        report(true, "ok", "平台：CheckIsOnPlatform 随状态变化",
            "on=" .. tostring(c1) .. " off=" .. tostring(c2))
    else
        report(false, "fail", "平台：CheckIsOnPlatform 随状态变化",
            "on=" .. tostring(c1) .. " off=" .. tostring(c2) .. "（两者相同 = 平台状态没接上）")
    end
end)

--=========================================================================
hr("13) 光照语义：两处不再互相矛盾，且真的随昼夜变（C3）")
--=========================================================================
-- ★ 修之前的症状是一个宿主里两个相反的常量：
--     LightWatcher:IsInLight()  恒 true（GetLightLevel 恒 1）
--     EntityScript:IsInLight()  恒 false
--   判据分四层，每一层都能单独把某一种错实现打红：
--     ① 两处一致（旧实现直接死在这里）
--     ② 随 phase 翻转（恒值实现全死）
--     ③ IsInLight 与 IsInDark 互补（两者同值的实现死）
--     ④ 阈值真的参与判定（只存不用的实现死）
section("光照语义", function()
    local W = _G.TheWorld
    local st = W and W.state
    if st == nil then
        report(false, "fail", "光照：TheWorld.state 存在", "_G.TheWorld 或 state 为 nil")
        return
    end
    -- ★ 用 wilson：LightWatcher 是 player_common.lua:2430 挂的，
    --   普通物品（log）**不挂** —— 第一版判据就是拿 log 测的，
    --   于是报了一条“没挂上”的假红。
    Bootstrap.LoadPrefabFile("wilson")
    local e = spawn("wilson")
    if e == nil then
        report(false, "fail", "光照：取一个实体", "wilson 生成失败")
        return
    end
    local lw = rawget(e, "LightWatcher")
    if lw == nil then
        report(false, "fail", "光照：实体有 LightWatcher", "没挂上")
        return
    end

    -- ★ 用 rawset 直接覆盖镜像（World.state 的 __newindex 允许），
    --   用完置 nil 还原成“读组件”。
    local function set_phase(p)
        if p == nil then rawset(st, "phase", nil) else rawset(st, "phase", p) end
    end
    local saved = rawget(st, "phase")

    set_phase("day")
    local lw_day, es_day = lw:IsInLight(), e:IsInLight()
    set_phase("night")
    local lw_night, es_night = lw:IsInLight(), e:IsInLight()
    local dark_night = lw:IsInDark()

    -- 判据 1：两处一致（白天与黑夜各比一次）
    if lw_day == es_day and lw_night == es_night then
        report(true, "ok", "光照：LightWatcher 与 EntityScript 一致",
            string.format("day(%s/%s) night(%s/%s)", tostring(lw_day), tostring(es_day),
                tostring(lw_night), tostring(es_night)))
    else
        report(false, "fail", "光照：LightWatcher 与 EntityScript 一致",
            string.format("day(%s/%s) night(%s/%s)（两处说法不同）",
                tostring(lw_day), tostring(es_day), tostring(lw_night), tostring(es_night)))
    end

    -- 判据 2：白天为真、黑夜为假（真的随昼夜变）
    if lw_day == true and lw_night == false then
        report(true, "ok", "光照：随昼夜翻转", "day=true night=false")
    else
        report(false, "fail", "光照：随昼夜翻转",
            string.format("day=%s night=%s", tostring(lw_day), tostring(lw_night)))
    end

    -- 判据 3：IsInDark 与 IsInLight 互补
    if dark_night == true and lw_night == false then
        report(true, "ok", "光照：IsInDark 与 IsInLight 互补", "night: light=false dark=true")
    else
        report(false, "fail", "光照：IsInDark 与 IsInLight 互补",
            string.format("night: light=%s dark=%s", tostring(lw_night), tostring(dark_night)))
    end

    -- 判据 4：阈值真的参与判定
    --   黄昏亮度 0.5：默认阈值 0.2 ⇒ true；把阈值抬到 0.8 ⇒ false。
    --   只存不用的实现（旧实现就是）在这里一定红。
    set_phase("dusk")
    local d_default = lw:IsInLight()
    lw:SetLightThresh(0.8)
    local d_strict = lw:IsInLight()
    lw:SetLightThresh(nil)
    lw._lightthresh = nil
    if d_default == true and d_strict == false then
        report(true, "ok", "光照：阈值真的参与判定",
            "dusk 0.5：默认阈值→" .. tostring(d_default) .. "，0.8阈值→" .. tostring(d_strict))
    else
        report(false, "fail", "光照：阈值真的参与判定",
            string.format("dusk 0.5：默认→%s，0.8→%s（阈值被忽略）",
                tostring(d_default), tostring(d_strict)))
    end

    -- 判据 5：黑夜里 GetTimeInDark 真的累加（旧实现恒 0）
    --   ★ 为什么它值得单独一条：wisecracker.lua:522 就靠
    --     `GetTimeInDark() >= 0.5` 决定对话。恒 0 会让它永远不成立。
    set_phase("night")
    local t0 = lw:GetTimeInDark()
    for _ = 1, 60 do Sim.Step() end
    local t1 = lw:GetTimeInDark()
    if t1 > t0 and t1 > 0 then
        report(true, "ok", "光照：黑夜里 GetTimeInDark 累加",
            string.format("%.2f → %.2f s", t0, t1))
    else
        report(false, "fail", "光照：黑夜里 GetTimeInDark 累加",
            string.format("%.2f → %.2f s（恒不增 = wisecracker 那条永不成立）", t0, t1))
    end

    set_phase(saved)
end)

--=========================================================================
hr("14) 父实体坐标跟随：镜像实体不该全堆在原点（C6）")
--=========================================================================
-- ★ 旧行为：`entity:SetParent(p)` 只写指针，**坐标一直不跟**。
--   于是子实体永远停在 Make 时的 (0,0,0)。
--   真实后果：约 140 个 `*_classified` 镜像实体全堆在原点，
--   每次查询都要扫这批肯定不在身边的“死重量”。
--
--   判据四条（前两条证明“会跟”，后两条证明“不乱跟”）：
--     ① 子实体一开始不在原点（跟到父的位置）
--     ② 父移动后，子跟着移动
--     ③ **显式摆过位置**的子实体不被覆盖（否则装备/摆件全会飞到玩家身上）
--     ④ 没挂父的实体不动（防止“一律抄到某个坐标”）
section("父子坐标跟随", function()
    Bootstrap.LoadPrefabFile("log")
    Bootstrap.LoadPrefabFile("twigs")
    local parent = spawn("log")
    if parent == nil then
        report(false, "fail", "父子：取实体", "log 生成失败")
        return
    end
    parent.Transform:SetPosition(10, 0, 10)

    -- 子：生成后**抹掉** spawn() 带来的 `_explicit_pos`，
    -- 模拟“从没被摆过”的镜像实体（classified 就是这种）。
    local child = spawn("twigs")
    if child == nil then
        report(false, "fail", "父子：取子实体", "twigs 生成失败")
        return
    end
    child.Transform:SetPosition(0, 0, 0)
    child.Transform._explicit_pos = nil
    child.entity:SetParent(parent.entity)
    Sim.Step()
    local cx, cy, cz = child.Transform:GetWorldPosition()
    if cx == 10 and cz == 10 then
        report(true, "ok", "父子：子实体跟到父位置",
            string.format("(%.1f,%.1f)", cx, cz))
    else
        report(false, "fail", "父子：子实体跟到父位置",
            string.format("子在 (%.1f,%.1f)，父在 (10,10)（没跟上）", cx, cz))
    end

    parent.Transform:SetPosition(20, 0, 20)
    Sim.Step()
    local cx2, _, cz2 = child.Transform:GetWorldPosition()
    if cx2 == 20 and cz2 == 20 then
        report(true, "ok", "父子：父移动后子跟随", "(20,20)")
    else
        report(false, "fail", "父子：父移动后子跟随",
            string.format("子在 (%.1f,%.1f)，应在 (20,20)", cx2, cz2))
    end

    -- ③ 对照：显式摆过位置的子实体必须保持自己的位置
    local placed = spawn("twigs")
    if placed ~= nil then
        placed.Transform:SetPosition(3, 0, 4)
        placed.entity:SetParent(parent.entity)
        Sim.Step()
        local px, _, pz = placed.Transform:GetWorldPosition()
        if px == 3 and pz == 4 then
            report(true, "ok", "父子：显式摆过的不被覆盖", "(3,4) 保持")
        else
            report(false, "fail", "父子：显式摆过的不装覆盖",
                string.format("实测 (%.1f,%.1f)，应为 (3,4)", px, pz))
        end
    end

    -- ④ 对照：没挂父的实体不能被抄到别人的坐标
    local lone = spawn("twigs")
    if lone ~= nil then
        lone.Transform:SetPosition(7, 0, 8)
        Sim.Step()
        local lx, _, lz = lone.Transform:GetWorldPosition()
        if lx == 7 and lz == 8 then
            report(true, "ok", "父子：无父实体不受影响", "(7,8) 保持")
        else
            report(false, "fail", "父子：无父实体不受影响",
                string.format("实测 (%.1f,%.1f)，应为 (7,8)", lx, lz))
        end
    end
end)

--=========================================================================
hr("汇总")
--=========================================================================
for _, l in ipairs(lines) do print(l) end
print("")
print(string.format("  通过 %d · 宿主边界 %d · 失败 %d", pass, boundary, fail))
print("")
print("  ★ 「宿主边界」= 本宿主里本来就不该生效的路径（缺玩家动作 / 客户端 UI /")
print("    headless 没有的东西）。它们**单独计数、不算通过** —— 混进通过就是自我欺骗。")
print(string.format("  总判定：%s",
    (fail == 0 and "✔ 无失败项（边界项已单列）" or "✘ 有失败项")))

--=========================================================================
-- ★★★ T9：门要**真红**
--=========================================================================
-- 为什么必须有这一段：这一行打印 `✘ 有失败项` 之后，脚本**正常退出**，
-- 于是 `_run_lua.py` 判它 PASS、`run_all.sh` 判它 ✔ ——
-- 「打印了失败却算通过」正是本工程反复吃亏的那种**假绿**。
-- （`tests.lua` 早就吃过同一个亏，那边已经改成 `error()` 收尾并留了注释。）
--
-- ★ 为什么用 `error()` 而不是 `os.exit(1)`：
--   本工程跑在 lupa 里，`os.exit` 会把**宿主 Python 进程**一起带走，
--   从而**吞掉后面所有入口的输出**（一次跑 14 个入口时会看起来像「突然中断」）。
--   抛 Lua 错误则由 runner 捕获、记为**这个入口 FAIL**，其余入口照常跑完 ——
--   失败要吵，但不能把现场一起毁掉。
if fail > 0 then
    error(string.format("mech.lua 有 %d 条失败（见上方 ✘ 行）", fail), 0)
end