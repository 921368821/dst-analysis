--[[
==============================================================================
 burn.lua —— 燃烧链路验证（点燃 → 烧完 → 掉落物被换掉）
==============================================================================
为什么单独验
    按「后续任务清单」P1-1，也按第 21 节 DropDeathLoot 的教训：
    **主循环不会自然走到的分支必须显式去走**，否则静默空实现会一直藏着。
    燃烧是典型的「慢速推进 + 终点换物」型链路，80 s 演示里根本烧不完。

两个「我先想错、被实测纠正」的地方（记下来，避免下次再绕）
    ① **`burnt` 标签不是 burnable 加的。**
       `components/burnable.lua` 全文**只推 `onburnt` 事件**，从不 `AddTag("burnt")`。
       标签是**静态物预制体自己**在 onburnt 回调里加的。
       ⇒ 判据不能写死成「有 burnt 标签」，得用**每个对象自己的**终态标志。
    ② **生物烧不着。**
       `burnable.lua` 顶部原注释：
         「NOTE ON DAMAGE: Burning damage is done in the propagator component
           going to Health:GetFireDamageScale(), not the burnable component.」
       而 `pigman.lua` **没有 propagator** ⇒ 点燃一只猪人只会播火焰特效，
       既不掉血也不会死。**这是原版设定，不是宿主缺口。**
       ⇒ 所以燃烧试验的对象必须选**带 burnable 的静态物**（树）。

验的是什么
    evergreen（常青树）的 burnable:Ignite() → 推进 → 树烧成焦木
      → lootdropper 掉落 charcoal（`evergreens.lua:159` 直接
        `SpawnLootPrefab("charcoal")`）

判据
    ① Ignite 后 IsBurning() 为真、有 burntime
    ② 推进足够 tick 后：不再 burning（已烧完）
    ③ 场上出现 charcoal —— 硬证据：真的走完了整条链
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
WorldMap.Generate({ seed = 20261013 })

local function hr(t)
    print("")
    print(string.rep("═", 70))
    print("  " .. tostring(t))
    print(string.rep("═", 70))
end

local function spawn(name)
    Universal.Install(Core)
    local ok, inst = pcall(Core.SpawnPrefab, name)
    Universal.Uninstall()
    if ok and inst ~= nil then inst.Transform:SetPosition(0, 0, 0) end
    return ok and inst or nil
end

local function count_live()
    local n, names = 0, {}
    for _, v in pairs(Core.Spawned) do
        n = n + 1
        local k = v.prefab or "?"
        names[k] = (names[k] or 0) + 1
    end
    return n, names
end

--=========================================================================
hr("1) 前置核对：生物到底受不受火焰伤害")
do
    Bootstrap.LoadPrefabFile("pigman")
    local pig = spawn("pigman")
    if pig ~= nil then
        print(string.format("  pigman:  burnable=%s  propagator=%s",
            tostring(pig.components.burnable ~= nil),
            tostring(pig.components.propagator ~= nil)))
        print("  ★ 没有 propagator ⇒ 点燃它只会播特效，不掉血也不死（原版设定）")
    end
end

--=========================================================================
hr("2) 生成一棵常青树（带 burnable + lootdropper）")
Bootstrap.LoadPrefabFile("evergreen")
local t = spawn("evergreen")
if t == nil then print("  ✘ 树生成失败"); return end
local B  = t.components.burnable
local LD = t.components.lootdropper
print(string.format("  burnable = %s   lootdropper = %s   health = %s",
    tostring(B), tostring(LD), tostring(t.components.health)))
if B == nil then print("  ✘ 树没有 burnable，无法继续"); return end
print(string.format("  点燃前：prefab=%s  HasTag('burnt')=%s",
    tostring(t.prefab), tostring(t:HasTag("burnt"))))

--=========================================================================
hr("3) 点燃")
local ok_i, err_i = pcall(B.Ignite, B)
print(string.format("  Ignite() → ok=%s %s", tostring(ok_i), tostring(err_i):sub(1, 120)))
print(string.format("  IsBurning()=%s  burning=%s  burntime=%s  task=%s",
    tostring(B:IsBurning()), tostring(B.burning), tostring(B.burntime),
    tostring(B.task)))

--=========================================================================
hr("4) 推进到烧完")
local ticks_needed = math.ceil((B.burntime or 10) * 30 * 2) + 120
local finished_at = nil
for i = 1, ticks_needed do
    Sim.Step()
    if not t:IsValid() then finished_at = finished_at or i; break end
    if finished_at == nil and not B:IsBurning() then finished_at = i end
end
print(string.format("  跑 %d tick（burntime=%s s ≈ %d tick）",
    ticks_needed, tostring(B.burntime), math.ceil((B.burntime or 0) * 30)))
print(string.format("  实体仍有效=%s   停止燃烧于第 %s tick   现在 IsBurning=%s",
    tostring(t:IsValid()), tostring(finished_at),
    tostring(t:IsValid() and B:IsBurning())))

--=========================================================================
hr("5) 烧完后的状态与掉落")
local n_before, names_before = count_live()
print(string.format("  烧完时场上 %d 个实体", n_before))
if t:IsValid() then
    print(string.format("  prefab 变成 %s   还有 burnable=%s   HasTag('burnt')=%s",
        tostring(t.prefab), tostring(t.components.burnable ~= nil),
        tostring(t:HasTag("burnt"))))
end
-- ★★ charcoal 不是「烧完就掉」，而是「**砍烧焦的树**才掉」。
--   依据：`evergreens.lua:152 chop_down_burnt_tree` 里才
--   `SpawnLootPrefab("charcoal")` + `DropLoot()`；
--   而 `OnBurnt`（同文件 172 行）反而把 loot 清空成 `SetLoot({})`。
--   所以要走完最后一环，必须**模拟砍**：
--     workable:WorkedBy(worker, 足够大的工作量) → workleft<=1 → onfinish
--   而 `OnBurnt` 里挂的正是 `SetOnFinishCallback(chop_down_burnt_tree)`。
local ok_d = false
if t:IsValid() then
    local W = t.components.workable
    print(string.format("  烧焦后的 workable = %s   workleft = %s",
        tostring(W), tostring(W and W.workleft)))
    if W ~= nil and type(W.WorkedBy) == "function" then
        -- 造一个能当 worker 的实体（WorkedBy 会查 worker.components.inventory）
        Bootstrap.LoadPrefabFile("wilson")
        local w = spawn("wilson")
        local err_d
        ok_d, err_d = pcall(function() W:WorkedBy(w, 9999) end)
        print(string.format("  模拟砍树 WorkedBy(worker, 9999) → ok=%s", tostring(ok_d)))
        if not ok_d then
            -- 报错也要看清内容：链路走完 ≠ 没错误（可能报在链尾）
            print("    ⚠️ 错误内容：" .. tostring(err_d):sub(1, 220))
        end
    else
        print("  ⚠️ 烧焦后没有 workable —— 砍不掉，charcoal 自然不会有")
    end
end
for i = 1, 5 do Sim.Step() end
for i = 1, 5 do Sim.Step() end
local n_after, names_after = count_live()
print(string.format("  触发掉落 ok=%s   场上 %d → %d", tostring(ok_d), n_before, n_after))
print("  新增/变化的预制体：")
local any = false
for k, v in pairs(names_after) do
    local d = v - (names_before[k] or 0)
    if d ~= 0 then
        print(string.format("    %-16s %+d", k, d)); any = true
    end
end
if not any then print("    （无）") end

--=========================================================================
hr("6) 判定")
local pass = true
local function chk(c, n)
    print(string.format("  %s %s", c and "✔" or "✘", n))
    if not c then pass = false end
end
chk(ok_i, "Ignite() 调用成功")
chk(B.burntime ~= nil and B.burntime > 0, "burnable 有有效 burntime")
chk(finished_at ~= nil, "燃烧在推进中真的结束了（不是永远烧下去）")
local got_charcoal = (names_after["charcoal"] or 0) > (names_before["charcoal"] or 0)
chk(got_charcoal, "砍烧焦的树后场上出现 charcoal（整条链走完的硬证据）")
print("")
print(string.format("  总判定：%s", pass and "✔ 通过" or "✘ 有失败项"))

Core.DumpGaps()
