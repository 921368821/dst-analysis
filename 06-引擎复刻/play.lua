--[[
==============================================================================
 play.lua —— 无头游戏运行：真实生物 AI 的涌现行为

 目的
   前四个入口验证的是「单个实体能否跑起来」。这个入口验证的是
   **多个真实生物 + 各自真实大脑 + 真实状态机 并发运行**时会发生什么
   —— 也就是「游戏是否真的在跑」。

 为什么不做渲染
   · 本机没有 LÖVE2D，且 DST 用自家的 ZipAnim 格式
     （data/anim/*.zip 里是 anim.bin + build.bin + 图集），
     要看到画面得先实现 Klei 的二进制动画解析器 —— 那是独立的一大块工程。
   · 更划算的是先证明**逻辑层**活着：生物会自己做决策、
     在状态机里迁移、对世界事件有反应。这些用文本轨迹就能看清。

 做法
   加载真实 prefabs/ 与 brains/ → 生成若干生物 → 跑 N tick →
   记录每个生物的「状态迁移序列」与「大脑决策」，最后给行为摘要。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core = require("host.01_core")
local Loader = require("host.04_loader")
local Sim = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")

Bootstrap.Setup()

--=========================================================================
-- 加载真实 prefabs 与 brains
--=========================================================================
-- ★ brains 必须在 prefab 之前加载：prefab 文件里 `local brain = require("brains/pigbrain")`
--   发生在顶层（pigman.lua:1），此时 brain 模块内部又 require 一批 behaviours。
print("════ 加载真实 brains ════")
-- ★ 这份清单是**从 DST 源码自动推导**的，不是我手写的：
--   grep 出 pigbrain/spiderbrain/rabbitbrain/beefalobrain 四个大脑
--   + behaviours/ 下被它们引用的模块，取并集。
--   （早前我凭印象写了 behaviours/idle 与 behaviours/talker —— 这两个文件
--     在 DST 里根本不存在，缺口清单如实报了 file-missing。
--     教训：路径一律先 ls 核实，别凭印象。）
local BRAINS = {
    "brain",                        -- Brain 基类（顶层 scripts/brain.lua）
    "brains/braincommon",           -- 全局 BrainCommon
    "behaviours/wander",
    "behaviours/follow",
    "behaviours/faceentity",
    "behaviours/chaseandattack",
    "behaviours/runaway",
    "behaviours/doaction",
    "behaviours/leash",
    "behaviours/panic",
    "behaviours/findlight",
    "behaviours/avoidlight",
    "behaviours/chattynode",
   
    "behaviours/attackwall",
    "behaviours/useshield",
    "brains/pigbrain",
    "brains/spiderbrain",
    "brains/rabbitbrain",
    "brains/beefalobrain",
}
local ok_brains, fail_brains = 0, {}
for _, b in ipairs(BRAINS) do
    local ok, err = Loader.Load(b)
    if ok then ok_brains = ok_brains + 1
    else fail_brains[#fail_brains + 1] = b .. " → " .. tostring(err):sub(1, 100) end
end
print(string.format("  %d/%d 个 brain 模块加载成功", ok_brains, #BRAINS))
for _, f in ipairs(fail_brains) do print("    ✘ " .. f) end

-- 生成生物需要的 prefab
-- beefalo 的大脑会 SpawnPrefab("beefaloherd")，所以要把它的依赖也加载上
Bootstrap.LoadPrefabFile("beefaloherd")
local CREATURES = { "pigman", "spider", "rabbit", "beefalo" }
print("")
print("════ 生成生物 ════")
local spawned = {}
for _, name in ipairs(CREATURES) do
    Bootstrap.LoadPrefabFile(name)
    local ok, inst = pcall(Core.SpawnPrefab, name)
    if ok and inst then
        spawned[#spawned + 1] = inst
        -- 错开位置，避免叠在一起
        local i = #spawned
        inst.Transform:SetPosition(i * 8, 0, i * 5)
        print(string.format("  ✔ %-10s guid=%d  组件=%d  标签=%d  brain=%s",
            name, inst._guid,
            (function() local n = 0 for _ in pairs(inst._components) do n = n + 1 end return n end)(),
            inst:NumTags(),
            tostring(inst.brain ~= nil)))
    else
        print(string.format("  ✘ %-10s → %s", name, tostring(inst):sub(1, 110)))
    end
end

--=========================================================================
-- 记录状态迁移
--=========================================================================
print("")
print("════ 挂状态迁移监听 ════")
local traces = {}
for _, inst in ipairs(spawned) do
    local t = { name = inst.prefab, seq = {}, decisions = 0 }
    traces[inst] = t
    inst:ListenForEvent("newstate", function(entity, data)
        t.seq[#t.seq + 1] = data and data.statename or "?"
    end)
end
print(string.format("  已挂 %d 个监听器", #spawned))

--=========================================================================
-- 跑仿真
--=========================================================================
local TICKS = 3000
print("")
print(string.format("════ 跑 %d tick（约 %.0f 秒世界时间）════", TICKS, TICKS / 30))
local t0 = os.clock()
local ok_run, run_err = pcall(function() Sim.Run(TICKS) end)
local dt = (os.clock() - t0) * 1000
print(string.format("  %s  世界时间 %.2f s  用时 %.0f ms",
    ok_run and "✔ 完成" or ("✘ 中断: " .. tostring(run_err)),
    Sim.World.time, dt))
print("")

--=========================================================================
-- 行为摘要
--=========================================================================
print("════ 行为摘要 ════")
print(string.format("%-12s %-8s %-8s %s", "生物", "迁移数", "状态种类", "状态序列（前 10）"))
print(string.rep("-", 78))
for _, inst in ipairs(spawned) do
    local t = traces[inst]
    local kinds = {}
    for _, s in ipairs(t.seq) do kinds[s] = true end
    local nk = 0
    for _ in pairs(kinds) do nk = nk + 1 end
    local shown = {}
    for i = 1, math.min(10, #t.seq) do shown[i] = t.seq[i] end
    print(string.format("%-12s %-8d %-8d %s",
        t.name, #t.seq, nk,
        #shown > 0 and table.concat(shown, " → ") or "（无迁移）"))
end

print("")
print("════ 存活与状态 ════")
for _, inst in ipairs(spawned) do
    local sg = rawget(inst, "sg")
    print(string.format("  %-10s 有效=%-5s 当前状态=%-14s 缓冲事件=%d",
        inst.prefab, tostring(inst:IsValid()),
        tostring(sg and sg.currentstate and sg.currentstate.name),
        sg and #sg.bufferedevents or 0))
end

print("")
local ninst, nactive = 0, 0
-- ⚠️ SGManager.instances 是 **map**（key = 实例），不是数组 ——
--    用 ipairs 会永远得到 0（实测踩到）。必须 pairs。
for _, v in pairs(_G.SGManager.instances) do
    ninst = ninst + 1
    if not v.stopped then nactive = nactive + 1 end
end
print(string.format("SGManager: 登记 %d 个状态图实例，其中 %d 个活跃", ninst, nactive))

Core.DumpGaps()
