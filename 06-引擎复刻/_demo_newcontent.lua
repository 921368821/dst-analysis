--[[==========================================================================
 _demo_newcontent.lua —— 「能不能用这个引擎开发内容」的**可执行验证**

 目的
   不是断言「可以」，而是**真的做一遍**：
     ① 定义一个**全新组件**（原版里不存在）→ 用 `Core.RegisterComponent` 注册
     ② 定义一个**全新预制体** → 用原版的 `Prefab()` 语法
     ③ 让它同时用上**新组件**与**原版组件**（health / lootdropper）
     ④ spawn 出来、跑 tick、观察可观测的行为
   如果这四步能跑通并给出正确输出，那「可以用它做内容开发（逻辑层）」就是**实测结论**，
   而不是一句声称。

 怎么跑
   python <工程根>/03-参考架构/_run_lua.py 5.1 <工程根>/06-引擎复刻/_demo_newcontent.lua
============================================================================]]
-- ★ require 顺序有讲究：Loader 负责把 `class` 等基础模块装进 require 路径，
--   必须在 Sim 之前。第一版我漏了 Loader ⇒ `require("host.02_sim")` 直接崩。
local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

Bootstrap.Setup()
WorldMap.Generate({ seed = 20261015 })

local pass, fail = 0, 0
local function report(ok, name, info)
    if ok then
        pass = pass + 1
        print(string.format("  ✔ %-44s %s", name, info))
    else
        fail = fail + 1
        print(string.format("  ✘ %-44s %s", name, info))
    end
end

print("")
print(string.rep("═", 72))
print("  用引擎开发「新内容」的最小闭环：新组件 + 新预制体 + 跑 tick")
print(string.rep("═", 72))

--=============================================================================
-- ① 全新组件：原版 components/ 里没有 `democounter`
--=============================================================================
--   ★ 关键事实：`AddComponent("democounter")` 会先查 `Core.ComponentRegistry`，
--     再回退到「从原版 scripts 树里加载 components/democounter.lua」——
--     两条都找不到就会 `NoteGap` 并返回 nil。
--     ⇒ 所以新组件必须**显式注册**（或用 RegisterComponent 间接做）。
--     这正是「能不能加新内容」的分水岭，本 demo 走的是**显式注册**这条路。
local DemoCounter = Class(function(self, inst)
    self.inst = inst
    self.n      = 0
    self.marks  = {}
end)

function DemoCounter:OnUpdate(dt)
    self.n = self.n + 1
    -- 每 10 tick 记一次「我当时的世界时刻」——用来证明它**跟着世界时间走**
    if self.n % 10 == 0 then
        self.marks[#self.marks + 1] = Sim.TheSim.time
    end
end

function DemoCounter:GetMarkCount() return #self.marks end
function DemoCounter:GetTicks()     return self.n end

Core.RegisterComponent("democounter", DemoCounter)

report(Core.ComponentRegistry["democounter"] ~= nil,
       "新组件已注册进 ComponentRegistry",
       "又回退链的第 1 条命中（不必往原版树里塞文件）")

--=============================================================================
-- ② + ③ 全新预制体：用**原版的 Prefab() 语法**，混用新组件与原版组件
--=============================================================================
local function demo_thing_fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()      -- 原版引擎侧接口（宿主的代理）
    inst:AddTag("demo")

    inst:AddComponent("democounter")   -- ← 我们的**新**组件
    inst:AddComponent("health")        -- ← **原版**组件（走 LoadRealComponent）
    inst:AddComponent("lootdropper")   -- ← **原版**组件
    inst.components.health:SetMaxHealth(37)

    inst:AddComponent("inspectable")   -- 原版：可被检视

    -- ★★ 关键一步（我第一版漏了，导致 OnUpdate 一次都没跑）：
    --   原版 `EntityScript:AddComponent` **不会**自动把带 OnUpdate 的组件
    --   加进更新泵 —— 必须**显式** `StartUpdatingComponent`。
    --   （已核对原版 entityscript.lua：AddComponent 体内没有 StartUpdating/OnUpdate）
    inst:StartUpdatingComponent(inst.components.democounter)
    return inst
end

Core.Prefab("demo_thing", demo_thing_fn)

report(Core.Prefabs["demo_thing"] ~= nil,
       "新预制体已登记（原版 Prefab() 语法）",
       "Prefabs[\"demo_thing\"] 存在")

--=============================================================================
-- ④ spawn + 跑 tick + 观察
--=============================================================================
local inst = Core.SpawnPrefab("demo_thing")
report(inst ~= nil, "SpawnPrefab(\"demo_thing\") 返回实体", inst and "非 nil" or "nil")

if inst then
    report(inst.components.democounter ~= nil, "新组件挂上了", "components.democounter 非 nil")
    report(inst.components.health ~= nil,      "原版 health 组件也挂上了",
           inst.components.health and ("max=" .. tostring(inst.components.health.maxhealth)) or "nil")
    report(inst.components.lootdropper ~= nil, "原版 lootdropper 也挂上了", "")

    local t0 = inst.components.health and inst.components.health.currenthealth or -1
    inst.components.health:DoDelta(-12)
    local t1 = inst.components.health.currenthealth
    report(t1 == t0 - 12, "原版组件的**行为**真的生效",
           string.format("health %s → %s", tostring(t0), tostring(t1)))

    local before = inst.components.democounter:GetTicks()
    local want = 60
    for _ = 1, want do Sim.Step() end
    local after = inst.components.democounter:GetTicks()
    report(after - before == want, "新组件的 OnUpdate 被**更新泵**每 tick 调到",
           string.format("tick %d → %d（跑了 %d 次）", before, after, want))

    report(inst.components.democounter:GetMarkCount() == want / 10,
           "新组件读到的是**真实世界时间**",
           string.format("每 10 tick 记一次 ⇒ %d 个标记，时刻=%s",
                         inst.components.democounter:GetMarkCount(),
                         table.concat(inst.components.democounter.marks, ",")))
end

--=============================================================================
-- ⑤ 反向：**未注册**的新组件应被**明确记缺口**，而不是静默 nil
--=============================================================================
local probe = Core.SpawnPrefab("pigman")   -- 用原版实体来试
if probe then
    local r = probe:AddComponent("this_component_does_not_exist")
    report(r == nil, "未注册的组件返回 nil（不是假成功）", "返回 nil")
end

print("")
print(string.rep("─", 72))
print(string.format("  结果：%d 通过 / %d 失败", pass, fail))
print(string.rep("─", 72))
