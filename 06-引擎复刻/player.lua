--[[
==============================================================================
 player.lua —— 接上真实玩家实体

 目的
   消除 `AllPlayers` 空表造成的语义空洞。此前 playerprox /
   FindClosestPlayerInRange / IsNearPlayer 等全部走 nil 分支，
   「有玩家在附近」这条逻辑分支从未被真实检验。

 做法
   加载**真实**的 prefabs/wilson.lua（→ prefabs/player_common.lua，2986 行），
   实例化后注册进 AllPlayers。这是最高保真的做法：玩家契约由原版代码定义，
   宿主只负责提供引擎底座。

==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core = require("host.01_core")
local Loader = require("host.04_loader")
local Sim = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")

-- ★ 不在 Setup 阶段启用万能兜底
--   实测：兜底会让 simutil.lua:684 这类原本能加载的文件开始报错
--   （它把本该是 nil 的判断变成了对象，改变了控制流）。
--   所以核心加载保持干净，只在实例化玩家时才临时启用。
Bootstrap.Setup()

--=========================================================================
-- 加载真实玩家预制体
--=========================================================================
print("════ 加载真实玩家预制体 ════")
local ok, err = Bootstrap.LoadPrefabFile("wilson")
print(string.format("  wilson.lua 加载: %s%s", ok and "✔" or "✘",
    ok and "" or (" → " .. tostring(err))))

if not Core.Prefabs["wilson"] then
    print("  ✘ wilson 预制体未注册，无法继续")
    Core.DumpGaps()
    os.exit(1)
end

--=========================================================================
-- 实例化
--=========================================================================
print("")
print("════ SpawnPrefab(\"wilson\") ════")

-- ★ 只在实例化阶段启用万能兜底：player_common.lua 2986 行会引用几十个
--   宿主未定义的全局（GetGhostEnabled / Hooks / ...），逐个补会被连锁拖死。
--   每次访问都会被 Core.NoteStub 记录，缺口清单可查，不静默掩盖。
local Universal = require("host.07_universal")
Universal.Install(Core)

local p, perr = pcall(Core.SpawnPrefab, "wilson")
local player = p and perr or nil

Universal.Uninstall()   -- 装完立刻撤掉，避免影响后续 pighouse 验证

if not player then
    print("  ✘ 实例化失败: " .. tostring(perr))
    Core.DumpGaps()
    os.exit(1)
end

print("  ✔ 实例化成功")
print(string.format("    guid       : %d", player._guid))
print(string.format("    标签数     : %d", player:NumTags()))
local ncomp = 0
local comps = {}
for c in pairs(player._components) do
    ncomp = ncomp + 1
    comps[#comps + 1] = c
end
table.sort(comps)
print(string.format("    组件数     : %d", ncomp))
print("    组件: " .. table.concat(comps, " · "))

local tags = {}
for t in pairs(player._tags) do tags[#tags + 1] = t end
table.sort(tags)
print("    标签: " .. table.concat(tags, " · "))

print(string.format("    AnimState: bank=%s build=%s anim=%s",
    tostring(player.AnimState and player.AnimState._bank),
    tostring(player.AnimState and player.AnimState._build),
    tostring(player.AnimState and player.AnimState._anim)))

--=========================================================================
-- 注册进 AllPlayers —— 这是消除语义空洞的关键一步
--=========================================================================
-- ★ 注意：真实玩家预制体**自己会注册进 AllPlayers**
--   （实测 SpawnPrefab("wilson") 后 AllPlayers 已含该实体）。
--   这里只在没注册时补一个，避免重复。
local already = false
for _, v in ipairs(_G.AllPlayers) do
    if v == player then already = true break end
end
if not already then
    table.insert(_G.AllPlayers, player)
    print("  （预制体未自行注册，已补登记）")
end
player.isplayer = true

print("")
print("════ 注册进 AllPlayers ════")
print(string.format("  AllPlayers 长度: %d", #_G.AllPlayers))
print(string.format("  FindClosestPlayerInRange 可用: %s",
    type(_G.FindClosestPlayerInRange) == "function" and "✔" or "✘"))

-- 直接验证：现在它应该能找到玩家了
-- ⚠️ simutil.lua 定义的是**真实**的 FindClosestPlayerInRange（覆盖了 03_globals
--   里的兜底）。两点注意：
--   · 第 4 参是 **range**（内部自己平方），不是 rangesq
--   · 第 5 参 isalive 传 nil = 「不论死活都算」；
--     传 false 反而变成「只要死掉的」，与意图相反
local okf, found = pcall(_G.FindClosestPlayerInRange, 0, 0, 0, 100, nil)
if not okf then
    print(string.format("  FindClosestPlayerInRange 调用失败: %s",
        tostring(found):sub(1, 160)))
else
    print(string.format("  FindClosestPlayerInRange(0,0,0,range=100) -> %s",
        found and ("✔ 找到玩家 guid=" .. tostring(found._guid)) or "nil"))
end

--=========================================================================
-- ★ 核心验证：playerprox 的近/远判定现在应该走真实分支
--=========================================================================
print("")
print("════ ★ playerprox 判定验证（此前永远走 nil 分支）════")

-- 造一个 pighouse，让它的 playerprox 观察玩家
Bootstrap.LoadPrefabFile("pighouse")
local house = Core.SpawnPrefab("pighouse")
if not house then
    print("  ✘ 无法创建 pighouse（对照组缺失）")
    os.exit(1)
end

local prox = house.components.playerprox
if not prox then
    print("  ✘ pighouse 没有 playerprox 组件")
    os.exit(1)
end

-- ★ 用正规接口（playerprox.lua:165 / :198），不要直接改字段
local fired = { near = 0, far = 0 }
prox:SetOnPlayerNear(function(inst, plr)
    fired.near = fired.near + 1
end)
prox:SetOnPlayerFar(function(inst, plr)
    fired.far = fired.far + 1
end)
print(string.format("  SetDist(10,13) 已设：near=%s far=%s",
    tostring(prox.near), tostring(prox.far)))

-- 把玩家放到 pighouse 附近
player.Transform:SetPosition(3, 0, 3)
house.Transform:SetPosition(0, 0, 0)

-- ★ playerprox 自己用 DoPeriodicTask 调度检查（playerprox.lua:190 Schedule）。
--   宿主的主循环目前只驱动实体的 DoPeriodicTask/DoTaskInTime，
--   组件的周期任务由组件自管，所以这里显式调 ForceUpdate 走真实判定逻辑。
--   距离 4.24 < near(10) → 应判为「玩家在附近」。
-- ★ playerprox:ForceUpdate() 只在 `self.task ~= nil` 时才真正执行
--   （playerprox.lua:198），而 task 由 Schedule() 创建。所以要先 Schedule。
--   ⚠️ 全程 pcall：slipperyfeet.lua:118 的状态图调用在某些路径仍会崩
--   （已知未完成项，见实现报告），不能让它把前面的成果一起带走。
local prox_ok, prox_err = pcall(function()
    prox:Schedule(1)
    for _ = 1, 5 do
        prox:ForceUpdate()
        Sim.Step()
    end
end)

print("  玩家 (3,0,3) · 猪屋 (0,0,0) · 距离 ≈ 4.24 · SetDist(near=10, far=13)")
if not prox_ok then
    print(string.format("  ✘ playerprox 判定中断: %s", tostring(prox_err):sub(1, 140)))
else
    print(string.format("  5 次 ForceUpdate 后：onnear 触发 %d 次，onfar 触发 %d 次",
        fired.near, fired.far))
    print(string.format("  IsPlayerClose() = %s", tostring(prox:IsPlayerClose())))
    if fired.near > 0 then
        print("  ✔ playerprox 走真实「玩家在附近」分支（此前永远 nil）")
    else
        print("  △ 未触发 —— playerprox 的调度或距离判定还没对上")
    end
end

--=========================================================================
-- ★ 状态机验证：真实 SGwilson 的转移链 + 动画驱动
--=========================================================================
print("")
print("════ ★ 状态机验证（479 个状态的真实 SGwilson）════")
-- ★★ 这两条判据必须**真的会红**（后置 error 收尾）。
--   本工程在 `mech.lua` 上已经栽过一模一样的坑（§9an.6）：打印 `✘` 却从不 `error`，
--   于是 14 个入口照样 PASS —— 那叫假绿。这里把判据结果提到 do 块外面，
--   文末 `error` 收尾，红了就是红了。
local SM_OK = false
local SM_WHY = "状态机验证块没有执行到"
do
    local sg = rawget(player, "sg")
    if not sg or sg.sg == nil then
        print("  ✘ 玩家没有状态图")
    else
        Sim.Run(30)
        local nstates = 0
        for _ in pairs(sg.sg.states) do nstates = nstates + 1 end
        print(string.format("  状态图: %s（%d 个状态，默认 %s）",
            tostring(sg.sg.name), nstates, tostring(sg.sg.defaultstate)))
        print(string.format("  当前: %s  动画: %s",
            tostring(sg.currentstate and sg.currentstate.name),
            tostring(player.AnimState._anim)))

        local chain = {}
        local function go(name)
            local prev_anim = player.AnimState._anim
            pcall(sg.GoToState, sg, name)
            -- ★★ 三个采样点，缺一个就分不清「没驱动」和「驱动了又切回去了」：
            --   `anim_after_go` = GoToState 返回那一刻（onenter 是否真的改了动画）
            --   `anim`          = 跑 10 tick 之后（有没有被 onupdate/事件切走）
            --   `tis_after_go`  = 转移刚发生时（应被 GoToState 重置为 0）
            --   这一条原来只采「10 tick 之后」，于是 `go("run")` 进 run 后
            --   状态机在 10 tick 内自己切回 idle ⇒ 采到 idle ⇒ 判「onenter 驱动动画 ✘」。
            --   那个 ✘ 是**判据的采样时刻错了**，不是引擎没驱动动画。
            local anim_after_go = player.AnimState._anim
            local tis_after_go = sg.timeinstate
            Sim.Run(10)
            chain[#chain + 1] = {
                state = sg.currentstate and sg.currentstate.name,
                anim = player.AnimState._anim,
                anim_after_go = anim_after_go,
                anim_changed = (anim_after_go ~= prev_anim),
                tis = sg.timeinstate,
                tis_after_go = tis_after_go,
            }
        end
        go("idle"); go("run"); go("idle")

        print("  转移链验证（每次转移后跑 10 tick）:")
        for i, s in ipairs(chain) do
            print(string.format("    %d. state=%-10s anim=%-14s (转移瞬间 %-12s) timeinstate=%5.2f",
                i, tostring(s.state), tostring(s.anim),
                tostring(s.anim_after_go), s.tis or 0))
        end
        -- ★ 判据改成看**转移瞬间**：onenter 驱动动画 = GoToState 返回时动画已经变了。
        --   原来比的是 10 tick 之后的 anim，跑一次就被状态机自己切回去，
        --   于是恒为 ✘ —— 「✘ 恒久」与「✔ 恒久」一样没用。
        local anim_ok = chain[2] and chain[2].anim_changed
        local tis_ok = chain[3] and chain[3].tis_after_go == 0 and chain[3].tis > 0
        print(string.format("  onenter 驱动动画: %s（转移瞬间 %s → %s）",
            anim_ok and "✔" or "✘",
            tostring(chain[1] and chain[1].anim_after_go),
            tostring(chain[2] and chain[2].anim_after_go)))
        print(string.format("  转移重置并继续推进 timeinstate: %s", tis_ok and "✔" or "✘"))
        print(string.format("  SGManager 登记实例: %d", (function()
            local n = 0
            for _ in pairs(_G.SGManager.instances) do n = n + 1 end
            return n
        end)()))
        SM_OK = (anim_ok == true) and (tis_ok == true)
        if not SM_OK then
            SM_WHY = string.format("onenter 驱动动画=%s / timeinstate 重置推进=%s",
                tostring(anim_ok), tostring(tis_ok))
        end
    end
end

--=========================================================================
-- 长 tick 稳定性
--=========================================================================
print("")
print("════ 玩家 + 猪屋 + 猪人 跑 600 tick ════")
local okrun, runerr = pcall(function() Sim.Run(600) end)
print(string.format("  %s  世界时间 %.2f s",
    okrun and "✔ 完成" or ("✘ 中断: " .. tostring(runerr)), Sim.World.time))
print(string.format("  玩家仍有效: %s", tostring(player:IsValid())))
print(string.format("  猪屋 spawner.child: %s",
    tostring(house.components.spawner and house.components.spawner.child)))
print(string.format("  playerprox near/far: %d / %d", fired.near, fired.far))

Core.DumpGaps()

print("")
print("════ 结论 ════")
if okrun and fired.near > 0 then
    print("✔ 真实玩家实体（wilson.lua → player_common.lua 2986 行）已接上，")
    print("  AllPlayers 不再是空表，playerprox 走真实分支，长 tick 无错。")
else
    print("△ 玩家已实例化，但部分验证未通过（见上）。")
end

-- ★ 文末统一收尾：状态机判据红了就 `error`，不让「打印 ✘ 但入口 PASS」再出现。
--   注意放在最后 —— 前面所有诊断都要先打出来，红了也要能看到现场。
if not SM_OK then
    error("状态机判据未通过：" .. SM_WHY, 0)
end