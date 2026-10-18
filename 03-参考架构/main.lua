--============================================================
-- 文件：main.lua
-- 模块：整合演示
-- 职责：把 01~09 全部模块串起来，跑一个可读的文本生存演示。
--
-- 【演示内容】
--   阶段 1  世界生成：生成玩家、火把、浆果丛、石块
--   阶段 2  采集浆果 -> 饥饿度下降 -> 吃浆果 -> 恢复
--   阶段 3  夜晚降临 -> 理智度下降 -> 出现幻觉
--   阶段 4  存档并读档，验证状态一致
--
-- 运行方式：
--     lua main.lua                      # 完整演示
--     lua main.lua --quick              # 跳过各模块自测，直接看演示
--     lua main.lua --selftest           # 只跑各模块自测
--     lua main.lua --ticks 6000         # 指定天数长度（默认 3000 tick = 100 秒）
--
-- ★ 本文件是「怎么把上面 9 个模块拼成一个游戏」的最小完整样例，
--   也是整个参考实现的验收用例。
--============================================================

-- ★ 独立运行检测：不能用 `... == nil`（Lua 5.2+ 用 load 编译的 chunk 非 vararg，
--   顶层 `...` 是语法错误）。详见 01_class.lua 末尾说明。
local function IS_MAIN_CHUNK()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) ~= "@" then return false end
    local fname = src:sub(2):gsub("\\", "/"):match("([^/]+)$") or ""
    if fname == "" then return false end
    return arg ~= nil and arg[0] ~= nil
        and (arg[0]:gsub("\\", "/"):match("([^/]+)$")) == fname
end

--============================================================
-- 依赖
--============================================================
local classmod = require("01_class")
local sched    = require("02_scheduler")
local entity   = require("03_entity")
local meters   = require("04_meter")
local sml      = require("05_sourcemodifierlist")
local spawn    = require("06_prefab_spawn")
local worldmod = require("07_world")
local sgmod    = require("08_statemachine")
local save     = require("09_savegame")

--============================================================
-- 输出工具
--============================================================

local function banner(title)
    print("")
    print(string.rep("=", 72))
    print("  " .. title)
    print(string.rep("=", 72))
end

local function step(title)
    print("")
    print("--- " .. title .. " " .. string.rep("-", math.max(0, 68 - #title)))
end

-- 用固定宽度打印数值，避免不同 Lua 版本 tostring 的浮点格式差异影响对齐
local function fmt(v, w, prec)
    return string.format("%" .. (w or 8) .. "." .. (prec or 1) .. "f", v)
end

--============================================================
-- 阶段 0：各模块自测
--============================================================

local function runAllModuleTests()
    banner("阶段 0：各模块自测")
    local modules = {
        { "01_class", classmod.test },
        { "02_scheduler", require("02_scheduler").test },
        { "03_entity", entity.test },
        { "04_meter", meters.test },
        { "05_sourcemodifierlist", sml.test },
        { "06_prefab_spawn", spawn.test },
        { "07_world", worldmod.test },
        { "08_statemachine", sgmod.test },
        { "09_savegame", save.test },
    }
    for _, m in ipairs(modules) do
        if m[2] then
            m[2].run()
        end
    end
end

-- 检查是否有协程泄漏（架构是否干净）
-- ★ 必须定义在 demo() 之前：Lua 的 local 是词法作用域，
--   先用后定义会把名字解析成全局 nil，运行到这里就报
--   "attempt to call a nil value"。本文件开发时就踩了这个坑。
local function check_no_leak()
    local n = sched.scheduler:GetTaskCount()
    if n == 0 then
        print("    泄漏检查: 存活协程 0 个 ✓（实体销毁后自动清理干净）")
    else
        print(string.format("    泄漏检查: ★ 仍有 %d 个协程存活（存在泄漏）", n))
    end
end

--============================================================
-- 阶段 1-4：整合演示
--============================================================

local function demo(dayticks)
    dayticks = dayticks or 3000       -- 3000 tick = 100 秒 = 一个白天+黄昏+夜晚周期

    banner("整合演示：一场完整的「采集 -> 挨饿 -> 进食 -> 入夜 -> 发疯 -> 存档读档」")

    -- 全新世界：清掉调度器，重置时钟与 GUID
    sched.StopAllThreads()
    sched.ResetTime()
    entity.ResetGUIDs()
    spawn.SetMasterSim(true)

    local world = worldmod.World("demo_world", dayticks * sched.TICK_TIME)

    -- ---------------------------------------------------------
    step("阶段 1：生成世界与实体")
    -- ---------------------------------------------------------
    local player = spawn.SpawnPrefab("player", 0, 0)
    world:AddEntity(player)

    local torch = spawn.SpawnPrefab("torch", 2, 0)
    local berry  = spawn.SpawnPrefab("berry_bush", 3, 1)
    local rock   = spawn.SpawnPrefab("rock", 5, 5)
    world:AddEntity(torch)
    world:AddEntity(berry)
    world:AddEntity(rock)

    -- 玩家数值条接入世界的更新循环
    -- ★ 注意是 inst:StartUpdatingComponent(comp)，不是 comp:StartUpdating()
    player:StartUpdatingComponent(player.components.hunger)
    player:StartUpdatingComponent(player.components.sanity)
    player:StartUpdatingComponent(player.components.warmth)
    torch:StartUpdatingComponent(torch.components.burnable)

    -- 挂一只 hound，让状态机也参与进来
    local hound = spawn.SpawnPrefab("hound", 20, 0)
    world:AddEntity(hound)
    hound.attackdamage = 15
    hound.angle = 0
    hound.state_ticks = 0
    hound.homex, hound.homez = 20, 0
    hound.target = nil
    hound.nearestplayer = player
    hound.sg = sgmod.BuildHoundGraph()
    hound.sg:StartThread(hound)

    -- 用事件把系统内部发生的事打印出来（事件总线的实际用法）
    player:ListenForEvent(player, "goinsane", function()
        print("  !! 理智崩溃 -> 出现幻觉")
    end)
    player:ListenForEvent(player, "death", function(source, data)
        print(string.format("  !! 玩家死亡，死因：%s", tostring(data.cause)))
    end)

    print(string.format("  世界: %s   实体数: %d", world.name, world.nument))
    print(string.format("  玩家: %s  血量 %.0f/%.0f  饥饿 %.0f/%.0f  理智 %.0f/%.0f  体温 %.0f/%.0f",
        player.prefab,
        player.components.health.current, player.components.health.max,
        player.components.hunger.current, player.components.hunger.max,
        player.components.sanity.current, player.components.sanity.max,
        player.components.warmth.current, player.components.warmth.max))
    print(string.format("  资源: torch(x=%d)  berry_bush(x=%d, 余量 %d)  rock(x=%d)",
        torch.x, berry.x, berry.components.harvestable.uses, rock.x))
    print("  组件: " .. (function()
        local names = {}
        for name in pairs(player.components) do names[#names + 1] = name end
        table.sort(names)
        return table.concat(names, ", ")
    end)())

    -- ---------------------------------------------------------
    step("阶段 2：采集浆果 -> 饥饿度下降 -> 进食恢复")
    -- ---------------------------------------------------------
    local hunger = player.components.hunger

    -- 先跑 20 秒：只看饥饿度怎么掉
    local h0 = hunger.current
    for _ = 1, 600 do world:Step() end
    local h1 = hunger.current
    print(string.format("  跑 20 秒后：饥饿度 %s -> %s（下降 %s，速率 -1.0/s）",
        fmt(h0, 8), fmt(h1, 8), fmt(h0 - h1, 8, 2)))

    -- 用「温度趋向环境」模型驱动体温：晚上会更冷
    player.components.warmth:Recalc(world.light > 0.3 and 22 or 8, 1)

    -- ★ 采集浆果（服务端裁决）
    local before = hunger.current
    local ok = berry.components.harvestable:Harvest(player)
    print(string.format("  采集浆果: %s（浆果余量 %d -> %d）",
        ok and "成功" or "失败",
        berry.components.harvestable.maxuses, berry.components.harvestable.uses))

    -- 吃浆果：一次补 25 点
    hunger:Eat(25)
    print(string.format("  吃浆果:   饥饿度 %s -> %s（+25，已 clamp 到上限）",
        fmt(before, 8), fmt(hunger.current, 8)))

    -- ★ 演示修饰器袋：站到冰箱（berry_bush）旁边，饥饿衰减减半
    hunger.ratemodifiers:SetModifier("berry_bush", 0.5)
    local hb = hunger.current
    for _ = 1, 300 do world:Step() end          -- 10 秒
    print(string.format("  浆果丛旁 10 秒: %s -> %s（衰减速度 %s/s，原始是 1.0/s）",
        fmt(hb, 8), fmt(hunger.current, 8),
        fmt((hb - hunger.current) / 10.0, 6, 3)))
    hunger.ratemodifiers:RemoveModifier("berry_bush")   -- 撤销

    -- ---------------------------------------------------------
    step("阶段 3：夜晚降临 -> 理智度下降 -> 幻觉")
    -- ---------------------------------------------------------
    local sanity = player.components.sanity
    local d2, n = nil, nil
    print("  时间推进中（每 10 秒打印一行）：")
    print(string.format("  %8s %6s %8s %8s %8s %6s",
        "tick", "时间", "段", "光照", "理智", "疯狂"))

    -- ★ 夜晚的「黑暗」通过修饰器袋放大理智衰减。
    --   这是 05_sourcemodifierlist 的典型用法：
    --   理智的基础衰减率是常量（白天 +0.3，夜晚 -0.5），
    --   但真正让人发疯的是「待在黑暗里」这件事，
    --   它是一个**外部施加的乘区**，所以必须走 SetModifier 而不是直接改 rate。
    --   ★ 而且这个乘区是可以撤销的：一旦天亮，立刻恢复原速，不需要记录原值。
    for i = 1, 9000 do
        world:Step()

        local isdark = world.light < 0.3
        -- 昼夜驱动理智与体温的基础速率
        sanity:Recalc(isdark)
        player.components.warmth:Recalc(isdark and 8 or 22, 1)

        -- 黑暗环境：对理智衰减施加 12 倍放大
        if isdark then
            sanity.ratemodifiers:SetModifier("darkness", 12)
        else
            sanity.ratemodifiers:RemoveModifier("darkness")
        end

        if i % 300 == 0 then
            print(string.format("  %8d %5.0fs %8s %8.2f %8s %6s",
                world.tick, world.time, world.segment, world.light,
                fmt(sanity.current, 8, 1), tostring(not sanity:IsSane())))
        end

        if d2 == nil and world.segment == "night" then d2 = world.tick end
        if n == nil and not sanity:IsSane() then n = world.tick end
        if d2 and n then break end
    end

    print("")
    if d2 then print(string.format("  夜晚开始: tick %d（第 %d 天，光照 %.2f）", d2, world.day, world.light)) end
    if n then  print(string.format("  理智崩溃: tick %d（理智 %.1f / %.1f = %.0f%%，已触发幻觉 %d 次）",
        n, sanity.current, sanity.max, sanity:GetPercent() * 100, sanity.hallucinations)) end
    if not n then print("  注意：本轮没有崩溃（理智速率或时长不足）") end

    -- ★ 滞回带演示：在阈值附近抖动不应反复切换
    local flips = 0
    local was = sanity:IsSane()
    for _ = 1, 50 do
        sanity:SetCurrent(sanity.max * 0.325)   -- 32.5%，正好在 30%~35% 滞回带内
        if sanity:IsSane() ~= was then flips = flips + 1 end
    end
    print(string.format("  滞回带验证: 在 32.5%%（介于 30%%/35%% 之间）抖动 50 次，状态翻转 %d 次（应为 0）", flips))

    -- ---------------------------------------------------------
    step("阶段 4：存档 -> 销毁世界 -> 读档重建")
    -- ---------------------------------------------------------

    -- 4.1 收集当前状态
    local snapshot = {
        version = save.VERSION,
        day = world.day,
        tick = world.tick,
        player = {
            health = player.components.health.current,
            hunger = hunger.current,
            sanity = sanity.current,
            warmth = player.components.warmth.current,
            x = player.x, z = player.z,
        },
        berries_left = berry.components.harvestable.uses,
    }

    local text = save.Save(snapshot)
    print(string.format("  存档完成: %d 字节", #text))
    print(string.format("    玩家状态: 血量 %s 饥饿 %s 理智 %s 体温 %s",
        fmt(snapshot.player.health, 7), fmt(snapshot.player.hunger, 7),
        fmt(snapshot.player.sanity, 7), fmt(snapshot.player.warmth, 7)))
    print("    存档文本片段: " .. string.sub(text, 1, 60) .. " ...")

    -- 4.2 演示 NaN 拦截：往存档里塞 NaN 必须被拒绝
    local nan_ok = pcall(save.Save, { version = save.VERSION, x = 0 / 0 })
    print(string.format("  NaN 拦截: 尝试保存 NaN -> %s", nan_ok and "★ 竟然成功了（有 bug）" or "已被正确拒绝"))

    -- 4.3 演示迁移：伪造一份 v1 老存档
    --   注意用一个「有代表性的」旧值（75 = 一半饱腹），
    --   这样才能看清迁移前后的语义差异；真实迁移里当然用玩家当时的值。
    local legacy = {
        version = 1,
        player = { food = 75 },                     -- 老字段叫 food，存的是绝对值
        entities = { { name = "berry_bush" }, { name = "player" } },
    }
    local legacy_text = save.Save(legacy)
    local migrated, applied = save.Load(legacy_text)
    print(string.format("  迁移演示: 读入 v1 存档，执行迁移 %s -> v%d",
        table.concat(applied, "->"), migrated.version))
    print(string.format("    字段改名: player.food(%s) -> player.hunger(%s)，并从绝对值折算为百分比",
        tostring(legacy.player.food), tostring(migrated.player.hunger)))
    print(string.format("    实体改名: entities[1].name -> entities[1].prefab = %s",
        tostring(migrated.entities[1].prefab)))

    -- 4.4 销毁整个世界
    print("")
    print("  模拟「退出游戏」：销毁世界与所有实体")
    local entcount = world.nument
    for _, e in ipairs({ player, torch, berry, rock, hound }) do
        world:RemoveEntity(e)
    end
    world:Step()     -- 触发延迟删除
    print(string.format("    销毁 %d 个实体，当前实体数 %d，存活协程数 %d",
        entcount, world.nument, sched.scheduler:GetTaskCount()))

    -- ★ 这一行是整个架构的价值所在：
    --   实体一销毁，AI 协程就被 KillThreadsWithID 自动清理，
    --   周期任务也被 Cancel —— 不需要任何一行手工清理代码。
    check_no_leak()

    -- 4.5 读档：重建世界与实体
    print("")
    print("  模拟「重新进入游戏」：读档并重建")
    sched.ResetTime()
    spawn.SetMasterSim(true)

    local world2 = worldmod.World("demo_world_2", dayticks * sched.TICK_TIME)
    local player2 = spawn.SpawnPrefab("player", 0, 0)
    world2:AddEntity(player2)

    local loaded = save.Load(text)
    player2.components.health.current = loaded.player.health
    player2.components.hunger.current = loaded.player.hunger
    player2.components.sanity.current = loaded.player.sanity
    player2.components.warmth.current = loaded.player.warmth
    player2.x, player2.z = loaded.player.x, loaded.player.z

    -- 世界资源也要恢复：重新生成一株浆果丛，并把剩余次数恢复
    local berry2 = spawn.SpawnPrefab("berry_bush", 3, 1)
    world2:AddEntity(berry2)
    berry2.components.harvestable.uses = loaded.berries_left
    local berry_left_after_save = berry2.components.harvestable.uses

    print(string.format("    世界: %s (第 %d 天, tick %d)", world2.name, loaded.day, loaded.tick))
    print(string.format("    玩家: 血量 %s 饥饿 %s 理智 %s 体温 %s",
        fmt(player2.components.health.current, 7), fmt(player2.components.hunger.current, 7),
        fmt(player2.components.sanity.current, 7), fmt(player2.components.warmth.current, 7)))

    -- 4.6 一致性校验
    -- ★ 必须拿 snapshot（存档那一刻的数值）与 player2 比，
    --   不能拿 player 比 —— 原实体此时已经被销毁了，
    --   读它的字段就是「访问已销毁对象」，是典型的悬空引用 bug。
    local function same(a, b, name)
        local diff = math.abs(a - b)
        local ok = diff < 1e-9
        print(string.format("    %-14s 存档 %14.9f   读档 %14.9f   %s",
            name, a, b, ok and "一致 ✓" or string.format("★不一致，差 %g", diff)))
        return ok
    end

    print("")
    print("  状态一致性校验：")
    local allsame = true
    allsame = same(snapshot.player.health, player2.components.health.current, "health") and allsame
    allsame = same(snapshot.player.hunger, player2.components.hunger.current, "hunger") and allsame
    allsame = same(snapshot.player.sanity, player2.components.sanity.current, "sanity") and allsame
    allsame = same(snapshot.player.warmth, player2.components.warmth.current, "warmth") and allsame
    allsame = same(snapshot.player.x,      player2.x,                          "x")       and allsame
    allsame = same(snapshot.player.z,      player2.z,                          "z")       and allsame
    allsame = same(snapshot.berries_left,  berry_left_after_save,              "berries") and allsame

    print("")
    if allsame then
        print("  ★ 存档 -> 读档 状态完全一致，演示通过")
    else
        print("  ★ 状态不一致，演示失败")
    end

    sched.StopAllThreads()
    return allsame
end

--============================================================
-- 入口
--============================================================

local function main()
    local args = arg or {}
    local mode = "full"
    local ticks = nil

    -- ★ 用 while 而不是 for 遍历命令行参数：
    --   Lua 的 for 循环变量是**只读**的，写 `i = i + 1` 会直接报
    --   "attempt to assign to const variable"。
    local idx = 1
    while idx <= #args do
        if args[idx] == "--quick" then
            mode = "quick"
        elseif args[idx] == "--selftest" then
            mode = "selftest"
        elseif args[idx] == "--ticks" then
            -- 下一个参数才是值，所以手动前进
            ticks = tonumber(args[idx + 1])
            idx = idx + 1
        end
        idx = idx + 1
    end

    print("============================================================")
    print("  《Don't Starve Together》核心架构 —— 最小可运行参考实现")
    print("  Lua 运行时版本: " .. _VERSION)
    print("============================================================")

    if mode == "selftest" then
        runAllModuleTests()
        return
    end

    if mode == "full" then
        runAllModuleTests()
    end

    local ok = demo(ticks)

    banner("演示结束")
    if ok then
        print("结果: 全部通过 ✓")
    else
        print("结果: 存在失败 ✗")
    end
    return ok
end

if IS_MAIN_CHUNK() then
    main()
end

return {
    main = main,
    demo = demo,
    runAllModuleTests = runAllModuleTests,
}