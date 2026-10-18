--[[
==============================================================================
 run.lua —— 入口：让 DST 原版 pighouse.lua 在契约宿主上跑起来

 用法：
   cd <工程根>/06-引擎复刻
   python ../03-参考架构/_run_lua.py 5.1 run.lua

 流程：
   1. Bootstrap.Setup() 装引擎全局 + 加载真实 class.lua / tuning.lua / 标准组件
   2. 执行真实 prefabs/pighouse.lua（未改一行）
   3. SpawnPrefab("pighouse") 实例化
   4. 检查标签/组件/动画/光照状态
   5. 跑 600 tick
   6. 输出契约缺口清单
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core = require("host.01_core")
local Loader = require("host.04_loader")
local Sim = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")

--=========================================================================
-- 1. 启动
--=========================================================================
print("════ 引擎启动 ════")
Bootstrap.Setup()
print(string.format("  ✔ class.lua        %s",
    type(_G.Class) == "function" and "已加载（真实版）" or "降级"))
print(string.format("  ✔ tuning.lua       %s",
    Bootstrap.TuningLoaded and "已加载（真实版）" or "未加载"))
if Bootstrap.TuningLoaded then
    local n = 0
    for _ in pairs(_G.TUNING) do n = n + 1 end
    print(string.format("     TUNING 键数: %d", n))
    local dk = {}
    for k in pairs(Bootstrap.TuningDiscovered or {}) do dk[#dk + 1] = k end
    table.sort(dk)
    if #dk > 0 then
        print(string.format("     自动补 0 的全局: %s", table.concat(dk, ", ")))
    end
end
for _, m in ipairs({ "easing", "standardcomponents", "prefabutil",
                     "worldsettingsutil" }) do
    local f = Loader.Failures[m]
    print(string.format("  %s %-20s %s",
        f and "✘" or "✔", m, f and f.reason or ""))
end

--=========================================================================
-- 2. 执行真实 prefabs/pighouse.lua
--=========================================================================
print("")
print("════ 执行真实 prefabs/pighouse.lua（453 行，未改一行）════")
local ok_pf, pfres = Bootstrap.LoadPrefabFile("pighouse")
if not ok_pf then
    print("  ✘ 失败: " .. tostring(pfres))
    Core.DumpGaps()
    os.exit(1)
end
print("  ✔ 执行成功")

local nreg = 0
for _ in pairs(Core.Prefabs) do nreg = nreg + 1 end
print(string.format("  注册表预制体数: %d", nreg))

--=========================================================================
-- 3. 实例化
--=========================================================================
print("")
print('════ SpawnPrefab("pighouse") ════')
local inst, err = Core.SpawnPrefab("pighouse")
if not inst then
    print("  ✘ 失败: " .. tostring(err))
    Core.DumpGaps()
    os.exit(1)
end

print("  ✔ 实例化成功")
print(string.format("    prefab      : %s", tostring(inst.prefab)))
print(string.format("    标签数      : %d", inst:NumTags()))
local ncomp = 0
for _ in pairs(inst._components) do ncomp = ncomp + 1 end
print(string.format("    组件数      : %d", ncomp))

local tags = {}
for t in pairs(inst._tags) do tags[#tags + 1] = t end
table.sort(tags)
print("    标签: " .. table.concat(tags, " · "))

local comps = {}
for c in pairs(inst._components) do comps[#comps + 1] = c end
table.sort(comps)
print("    组件: " .. table.concat(comps, " · "))

print("")
print("  AnimState（对照原版第 382-384 行的设置）:")
print(string.format("    bank=%s  build=%s  anim=%s  looping=%s",
    tostring(inst.AnimState._bank), tostring(inst.AnimState._build),
    tostring(inst.AnimState._anim), tostring(inst.AnimState._looping)))
print("  Light（对照原版第 376-379 行）:")
print(string.format("    enabled=%s  intensity=%s  falloff=%s  radius=%s",
    tostring(inst.Light._enabled), tostring(inst.Light._intensity),
    tostring(inst.Light._falloff), tostring(inst.Light._radius)))
print("  MiniMapEntity:")
print(string.format("    icon=%s", tostring(inst.MiniMapEntity._icon)))
print("  SoundEmitter（原版 LightsOn 时才会播放）:")
print(string.format("    正在播放: %d 个", (function()
    local n = 0
    for _ in pairs(inst.SoundEmitter._playing) do n = n + 1 end
    return n
end)()))

print("  spawner（对照原版第 416 行 Configure）:")
print(string.format("    childname=%s  child=%s  occupied=%s",
    tostring(inst.components.spawner.childname),
    tostring(inst.components.spawner.child),
    tostring(inst.components.spawner.occupied)))
print("  workable（对照原版第 409-411 行）:")
print(string.format("    workleft=%s  action=%s",
    tostring(inst.components.workable.workleft),
    tostring(inst.components.workable.action)))

--=========================================================================
-- 4. tick
--=========================================================================
print("")
print("════ 跑 600 tick（20 秒仿真）════")
local t0 = os.clock()
local okrun, runerr = pcall(function() Sim.Run(600) end)
local dt = (os.clock() - t0) * 1000
print(string.format("  %s 用时 %.1f ms",
    okrun and "✔ 完成" or ("✘ 中断: " .. tostring(runerr)), dt))
print(string.format("    世界时间 %.2f s / tick %d", Sim.World.time, Sim.World.tick))
print(string.format("    实体仍有效: %s", tostring(inst:IsValid())))
print(string.format("    事件派发: %d 次", inst._eventcount))
print(string.format("    spawner.child: %s",
    tostring(inst.components.spawner.child)))

--=========================================================================
-- 5. 缺口清单
--=========================================================================
Core.DumpGaps()

print("")
print("════ 结论 ════")
-- ★ 结论必须反映实际结果，不能无条件报「跑通」
local spawned = inst.components.spawner and inst.components.spawner.child
local nreal = 0
for _, c in pairs(Core.RealComponents) do
    if c then nreal = nreal + 1 end
end

if not inst:IsValid() then
    print("✘ 实例在仿真中被移除")
elseif not okrun then
    print(string.format("△ pighouse 实例化成功，但 %d tick 时中断：%s",
        Sim.World.tick, tostring(runerr)))
    print(string.format("  已完成的 tick：%d（世界时间 %.2f s）",
        Sim.World.tick, Sim.World.time))
    print("  → 见上方缺口清单定位下一步")
else
    print(string.format("✔ 原版 pighouse.lua（453 行）完整跑通：实例化 + %d tick 无错",
        Sim.World.tick))
end

print(string.format("  组件数 %d（其中 %d 个为真实 DST 组件文件）",
    (function()
        local n = 0
        for _ in pairs(inst._components) do n = n + 1 end
        return n
    end)(), nreal))
print(string.format("  spawner.child: %s",
    spawned and ("已生成 → " .. tostring(spawned.prefab)) or "nil"))
