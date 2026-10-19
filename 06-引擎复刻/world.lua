--[[
==============================================================================
 world.lua —— 正式入口：真实地形 + 真实物理 + 真实大脑 + 轨迹导出

 这是「世界可跑可看」阶段的**最终入口**（替代临时的 _diag_brain.lua）。

 它把此前各层各自验证过的能力串成一条完整链路：

     真实地图瓦片（host/20_map.lua，判定逻辑来自真实 tilegroups.lua
                  + 真实 components/map.lua 猴补丁）
        ↓
     Pathfinder:IsClear / Map:IsPassableAtPoint（真实的「能不能走过去」）
        ↓
     locomotor:GoToPoint → Physics:SetMotorVel（真实的移动意图）
        ↓
     Physics 位移积分 + 滑墙（host/11_physics.lua，补 C++ 那一侧）
        ↓
     真实状态图（stategraphs/，PlayAnimation 真的翻页）
        ↓
     真实大脑（brains/*，BehaviourTree 真的做决策）
        ↓
     ★ 每 tick 位置 / 朝向 / 动画 / 帧号 → JSON → 浏览器 canvas 播放

 为什么值得做这一步
   此前宿主能把 1594 个原版文件加载起来、单个 prefab 能实例化，
   但「世界」是静止的：生物不走、不追、不决策。
   现在第一次能回答一个具体问题：**生物在真实地形上真的会走动/追逐吗？**
   而且答案可以**用眼睛看**（导出的轨迹 + 图集在浏览器里播）。

 用法
   cd <工程根>/06-引擎复刻
   python ../03-参考架构/_run_lua.py 5.1 ../06-引擎复刻/world.lua
   可选环境参数（用脚本顶部常量改）：
     TICKS          仿真总 tick（默认 2400）
     SAMPLE_EVERY   每几 tick 存一帧（默认 2）
     OUT_JSON       轨迹输出路径（默认 _out/world.json）

 设计取舍
   · 生物 = pigman / rabbit / spider / beefalo 四类，因为它们都有**已导出的
     anim_data**（tools/export_anim.py 产物），能在浏览器里真的动起来。
   · 玩家 = 真实 prefabs/wilson.lua（→ player_common.lua 2986 行）。
     它没有导出 anim_data，所以可视化里画成标记点，但**逻辑上是真玩家**：
     'player' 标签、locomotor、真实状态图，蜘蛛的 ChaseAndAttack 靠它生效。
   · 玩家被脚本驱动绕圈走 —— 这是为了让「追逐」有目标，
     而且**玩家的每一段位移仍然走 真实 Pathfinder + 真实物理**，不是传送。
   · 全程不修改任何原版文件；宿主只补 C++ 那一侧。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")

--=========================================================================
-- 参数
--=========================================================================
-- ★ 可用环境变量覆盖：WORLD_TICKS（时长）/ WORLD_OUT（输出路径）/ WORLD_SEED
--   默认 2400 tick = 80 s，是回归基线用的口径（位移/tick、撞墙数都按它记录）。
--   想看完整昼夜循环（1 天 = 480 s = 14400 tick）就把 WORLD_TICKS 调到 14500。
local TICKS        = tonumber(os.getenv("WORLD_TICKS")) or 2400
local SAMPLE_EVERY = 2
local OUT_JSON     = os.getenv("WORLD_OUT") or "_out/world.json"
local SEED         = tonumber(os.getenv("WORLD_SEED")) or 20261013
local PLAYER_RADIUS = 26      -- 玩家绕圈半径（世界单位）
local RETARGET_EVERY = 12     -- 玩家每几 tick 重设目标点

local function hr(title)
    print("")
    print(string.rep("═", 74))
    print(" " .. title)
    print(string.rep("═", 74))
end

--=========================================================================
-- 0) 启动
--=========================================================================
hr("0) 引擎启动")
Bootstrap.Setup()
print(string.format("  class.lua            %s",
    type(_G.Class) == "function" and "真实版" or "降级"))
print(string.format("  tuning.lua           %s（%d 键）",
    Bootstrap.TuningLoaded and "真实版" or "未加载",
    (function() local n = 0 for _ in pairs(_G.TUNING or {}) do n = n + 1 end return n end)()))
print(string.format("  AnimState 真实化     %s", tostring(Bootstrap.AnimStateReal)))
print(string.format("  Physics  真实化      %s", tostring(Bootstrap.PhysicsReal)))
print(string.format("  真实地图猴补丁       %s", tostring(Bootstrap.MapRealLua)))
print(string.format("  TileGroupManager     %s", tostring(Bootstrap.TileGroupManagerReady)))
print(string.format("  行为树 behaviourtree %s", Bootstrap.BehaviourTreeMissing and ("缺: " .. Bootstrap.BehaviourTreeMissing) or "已加载"))
print(string.format("  大脑   brain.lua     %s", Bootstrap.BrainMissing and ("缺: " .. Bootstrap.BrainMissing) or "已加载（BrainManager 就位）"))

--=========================================================================
-- 1) 生成真实地形
--=========================================================================
hr("1) 生成真实地形（瓦片编号 = GROUND 真实常量）")
WorldMap.Generate({ seed = SEED })

--=========================================================================
-- 1b) 昼夜循环：加载真实的 components/clock
--=========================================================================
-- 全链都是原版代码：
--   components/clock.lua（539 行）→ 每 tick OnUpdate 推进 _remainingtimeinphase
--     → 到点后推 `phasechanged` / `cycleschanged` / `clocktick`
--   components/worldstate.lua 监听这些事件 → SetVariable → 写自己的 self.data
--   TheWorld.state 通过 __index 实时镜像 worldstate.data（见 02_sim.lua 的注释）
--
-- 实测节奏（与 TUNING 的 10/4/2 段 ×30 s 分毫不差）：
--   0 s day → 300 s dusk → 420 s night → 480 s 第 1 天 → 780 s dusk → …
--
-- ⚠️ 关键前提是修好的两处宿主 bug（详见报告第 13 节）：
--   ① TheWorld:PushEvent 原先只做世界状态广播、**漏了监听器派发**
--   ② TheWorld.state 原先是静态表，**不镜像 worldstate**
-- ★★ 世界级组件的**清单与挂法**见 `host/30_worldmount.lua`（顺序 = 原版权威列表
--   `world_network.lua:52-61`）。
--   宿主此前一个都没挂，于是 TheWorld.state 只能靠硬编码值。
--   实测每个都真的能挂上（前提是补了 perlin / TheWorld.meta，见 03_globals.lua）。
-- ★★ M3：单源化。此前这里与 `07-通用引擎/rt/rt_boot.lua` 各存一份 WORLD_COMPONENTS
--   （07 的注释自陈「照抄」），原版新增世界组件时必然只改一处，
--   症状是「06 有季节、07 没有」这种极难定位的差异。
local WorldMount = require("host.30_worldmount")
-- ★ 实体休眠的活动中心钩子在这里**先声明成 nil 占位**，真正的实现在
--   「玩家生成之后」再赋值 —— 详见那段注释里的作用域说明。
local sleep_stats = { slept = 0, woke = 0 }

local phase_log = {}      -- 相位变化点 {秒, 相位名}
local season_log = {}     -- 季节变化点 {秒, 季节名}
local world_samples = {}  -- 逐采样点的世界级量 {tick, 温度}
local CLOCK_OK = false
do
    local W = _G.TheWorld
    if W ~= nil then
        local WM = WorldMount.Mount(W)
        print(string.format("  世界组件  %d/%d 挂载成功：%s",
            #WM.mounted, WM.total, table.concat(WM.mounted, ", ")))
        -- ⚠️ 这里**不能**再 AddComponent("clock") —— 上面循环里已经加过了。
        --   重复添加在真实引擎里会被影子表挡住并返回旧实例，
        --   而宿主原先没有那道闸门，于是会造出两个共享同一组 netvar 的 clock，
        --   实测表现为 `phasechanged` 在同一秒里来回跳
        --   （240s→dusk、240s→day、300s→dusk…）。
        --   闸门已在 host/01_core.lua 的 AddComponent 里按 entityscript.lua:610-624 补上。
        CLOCK_OK = (W.components ~= nil and W.components.clock ~= nil)
        -- 只记**变化点**：相邻同相位不重复记（t=0 的初始事件与下面的兜底会撞车）
        local function log_phase(t, p)
            local last = phase_log[#phase_log]
            if last == nil or last[2] ~= tostring(p) then
                phase_log[#phase_log + 1] = { t, tostring(p) }
            end
        end
        W:ListenForEvent("phasechanged", function(_, p)
            log_phase(Sim.TheSim.time, p)
        end)
        -- ★ 可选：指定起始季节（WORLD_SEASON=winter）。走原版机制
        --   `ms_setseason`（seasons.lua:469 监听），不是宿主自己改状态。
        --   用途：一个季节 20 游戏日 = 9600 s，演示跑不了那么久，
        --   但要能看到「冬天白天短、温度低」就得能切过去。
        local want = os.getenv("WORLD_SEASON")
        if want ~= nil and want ~= "" then
            W:PushEvent("ms_setseason", want)
            print(string.format("  季节切换  按 WORLD_SEASON=%s 推送 ms_setseason → 现在 %s",
                want, tostring(W.state.season)))
        end
        -- 初始相位兜底（即使没有 t=0 的相位事件，播放器从第 0 秒也有相位可查）
        log_phase(Sim.TheSim.time, W.state.phase or "day")

        local function log_season(t, sv)
            local last = season_log[#season_log]
            if last == nil or last[2] ~= tostring(sv) then
                season_log[#season_log + 1] = { t, tostring(sv) }
            end
        end
        W:ListenForEvent("seasontick", function()
            log_season(Sim.TheSim.time, W.state.season or "?")
        end)
        log_season(Sim.TheSim.time, W.state.season or "autumn")
    end
end
-- ★ 分段以**时钟实际生效的值**为准，不用 TUNING 默认值 ——
--   因为在 DST 里 **seasons 组件会按季节改写分段**
--   （clock.lua 第 355 行原注释：「It is the seasons component that handles
--     adjusting the number of day/dusk/night segments」）。
--   seasons.lua:37-40 的表：
--       autumn = { day=8,  dusk=6, night=2 }   ← 宿主默认季节
--       winter = { day=5,  dusk=5, night=6 }
--       spring = { day=5,  dusk=8, night=3 }
--       summer = { day=11, dusk=1, night=4 }
--   所以秋天的一天是 8/6/2 段 = 240/180/60 s，而 TUNING 的默认是 10/4/2。
-- 读实际分段用**原版事件** `clocksegschanged`（clock.lua:386 推的 data 就是
-- { day=n, dusk=n, night=n }）。没有公开的 GetSegs 方法 —— 分段存在 clock 的
-- netvar 里，事件是唯一的对外通道。
local LIVE_SEGS = nil
if _G.TheWorld ~= nil then
    _G.TheWorld:ListenForEvent("clocksegschanged", function(_, data)
        if type(data) == "table" then LIVE_SEGS = data end
    end)
end
local function clock_segs()
    local SEG = TUNING.SEG_TIME
    local d, k, n = TUNING.DAY_SEGS_DEFAULT, TUNING.DUSK_SEGS_DEFAULT,
                    TUNING.NIGHT_SEGS_DEFAULT
    if LIVE_SEGS ~= nil then
        d = LIVE_SEGS.day or d
        k = LIVE_SEGS.dusk or k
        n = LIVE_SEGS.night or n
    end
    return d, k, n, SEG
end
print(string.format("  昼夜循环  clock 组件=%s  初始相位=%s  季节=%s（分段由 seasons 按季节改写，"
    .. "实测值在结尾汇总里）",
    tostring(CLOCK_OK),
    tostring(_G.TheWorld and _G.TheWorld.state.phase or "?"),
    tostring(_G.TheWorld and _G.TheWorld.state.season or "?")))

print(string.format("  地图尺寸  %d × %d 瓦片（1 瓦片 = %d 世界单位）",
    WorldMap.WIDTH, WorldMap.HEIGHT, WorldMap.TILE))
print(string.format("  世界范围  x ∈ [%.0f, %.0f]   z ∈ [%.0f, %.0f]",
    -WorldMap.WIDTH / 2 * WorldMap.TILE, WorldMap.WIDTH / 2 * WorldMap.TILE,
    -WorldMap.HEIGHT / 2 * WorldMap.TILE, WorldMap.HEIGHT / 2 * WorldMap.TILE))
print(string.format("  噪声种子  %d", SEED))
print("")
print("  地形分布：")
for _, row in ipairs(WorldMap.TileStats()) do
    local pct = row.count / (WorldMap.WIDTH * WorldMap.HEIGHT) * 100
    print(string.format("    %-16s #%-4d  %6d 块  %5.1f%%",
        row.name, row.id, row.count, pct))
end
print("")
print("  ASCII 地形图（. 草  T 森林  , 稀树草原  ~ 沼泽  ^ 岩  # 不可通行  o/O 海洋）：")
local ascii = WorldMap.ASCIIMap(70)
for line in ascii:gmatch("[^\n]+") do print("    " .. line) end

--=========================================================================
-- 2) 加载真实 brains / prefabs
--=========================================================================
hr("2) 加载真实 prefabs 与 brains")
local BRAINS = {
    "brain", "brains/braincommon",
    "behaviours/wander", "behaviours/follow", "behaviours/faceentity",
    "behaviours/chaseandattack", "behaviours/runaway", "behaviours/doaction",
    "behaviours/leash", "behaviours/panic", "behaviours/findlight",
    "behaviours/avoidlight", "behaviours/chattynode",
    "behaviours/attackwall", "behaviours/useshield",
    "brains/pigbrain", "brains/spiderbrain", "brains/rabbitbrain",
    "brains/beefalobrain",
    -- 本轮新增生物的脑
    "brains/houndbrain", "brains/frogbrain", "brains/beebrain",
    "brains/catcoonbrain", "brains/koalefantbrain",
    -- P3-2 新增：crow / dustmoth / eyeplant
    --   · crow      没有独立 brain（prefabs/crow.lua 不调 SetBrain），
    --                它靠自己的状态图 + `thief` 组件
    --   · dustmoth  用 brains/dustmothbrain
    --   · eyeplant  **没有 brain**（它是植物，原版靠 eyeplant.lua 里的
    --                距离判定 + 状态图，不进 BrainManager）
    "brains/dustmothbrain",
    --   · mole       用 brains/molebrain（会钻地、探头）
    --   · butterfly  用 brains/butterflybrain（在花间飞）
    "brains/molebrain", "brains/butterflybrain",
}
local nb_ok = 0
for _, b in ipairs(BRAINS) do
    if Loader.Load(b) then nb_ok = nb_ok + 1 end
end
print(string.format("  brains 模块 %d/%d 加载成功", nb_ok, #BRAINS))

--=========================================================================
-- 3) 生成世界实体
--=========================================================================
hr("3) 生成世界实体")

-- ---- 3.1 玩家（真实 wilson，best-effort）----
local Universal = require("host.07_universal")
Bootstrap.LoadPrefabFile("wilson")
local player = nil
if Core.Prefabs["wilson"] then
    Universal.Install(Core)
    local ok, p = pcall(Core.SpawnPrefab, "wilson")
    Universal.Uninstall()
    if ok and p then player = p end
end
if player then
    player.Transform:SetPosition(0, 0, 0)
    print(string.format("  ✔ 玩家 wilson  guid=%d  组件=%d  标签=%d  locomotor=%s",
        player._guid,
        (function() local n = 0 for _ in pairs(player._components) do n = n + 1 end return n end)(),
        player:NumTags(),
        tostring(player.components.locomotor ~= nil)))

    -- ★★ 给 wilson 戴一顶橄榄球帽 —— **走真实的装备路径**，不做手工 OverrideSymbol
    --
    -- 链路（全部是原版代码，宿主一行没改）：
    --   inventory:Equip(hat)
    --     → equippable:OnEquip → MakeHat 的 _onequip（prefabs/hats.lua:41-46）
    --       owner.AnimState:OverrideSymbol("swap_hat", "hat_football", "swap_hat")
    --       owner.AnimState:ClearOverrideSymbol("headbase_hat")
    --
    -- 为什么这个帽子能验证整条链路：
    --   · wilson 的**动画里真实引用** `swap_hat`（哈希 1690368943）这个槽位，
    --     但 wilson build 里没有它的几何 —— 正是靠覆盖来提供。
    --   · `hat_football` build 里恰好只有一个符号，就是 `swap_hat`，
    --     且哈希与 wilson 动画里引用的**完全一致**。
    --   （hats.lua 83 个帽子全部有 `hat_<name>.zip` 贴图包，可随时换。）
    --
    -- ⇒ 装备之前，DrawList 里 swap_hat 元素解析不出来（静默缺件）；
    --    装备之后，它被解析成 hat_football 的几何 ⇒ 播放er's sig 表出现条目。
    -- ★ 83 个帽子都由 prefabs/hats.lua 一个文件注册（MakeHat 的 prefabname = name.."hat"），
    --   没有单独的 footballhat.lua，所以要加载 hats。
    Bootstrap.LoadPrefabFile("hats")
    local hat = Core.SpawnPrefab("footballhat")
    local inv = player.components and player.components.inventory
    if hat ~= nil and inv ~= nil then
        inv:GiveItem(hat)
        inv:Equip(hat)
        local eq = rawget(inv, "equipslots") or {}
        print(string.format("  ✔ 装备橄榄球帽：帽子实体=%s 装备槽 head=%s 覆盖数=%d",
            tostring(hat.prefab),
            tostring(eq.head ~= nil and eq.head.prefab or "（空）"),
            (function()
                local n = 0
                for _ in pairs(player.AnimState._overrides or {}) do n = n + 1 end
                return n
            end)()))
    else
        print("  ✘ 装备失败：hat=" .. tostring(hat) .. "  inventory=" .. tostring(inv))
    end
else
    print("  △ wilson 未成功实例化，改用一个带 'player' 标签的替身")
    player = Core.NewEntity("player_standin")
    player:AddTag("player")
    player._is_standin = true
    print("    （替身没有 locomotor，将用直接位移驱动；追逐逻辑仍然成立）")
end

-- ---- 3.1a 把 TheFocalPoint 绑到真实玩家实体 ----
-- ★ 原版语义：main.lua:330 是 `TheFocalPoint = nil`，玩家进来后才指向玩家实体
--   （lightning.lua:9 因此显式判 `TheFocalPoint == nil`）；
--   而 caveweather.lua:211/214 与 actions.lua:6339 是**无条件**调
--       TheFocalPoint.SoundEmitter:KillSound / PlaySound(...)
--   ⇒ 服务端一旦进洞穴天气 / 玩家点错东西，它必须是真实实体。
--
--   宿主先前造了张假表 `{SoundEmitter = 桩}`：永不 nil 但声音永远是桩，
--   且语义与原版不符。已改成「初始 nil + 显式绑定」。
--   没有玩家的入口（full / batch）保持 nil —— 那才是原版行为。
do
    local okf, errf = SetFocalPoint(player)
    if okf then
        print(string.format("  ✔ TheFocalPoint 已绑定到玩家实体 guid=%d",
            player._guid or -1))
    else
        print("  △ TheFocalPoint 未绑定：" .. tostring(errf or "玩家没有 SoundEmitter")
            .. "（与原版一致：没有玩家时它就是 nil）")
    end
end

-- ---- 3.1b 演示豁免：玩家无敌（★ 这不是引擎行为，是我们的演示开关）----
-- 事实依据（都是实测得到的，不是为了绕开 bug）：
--   真实玩法里玩家会被生物打死 —— 实测 t≈300 血量 150→49.95（被蜘蛛咬），
--   t≈500 health:IsDead() 变 true。
--   而 components/locomotor.lua:1457 一旦发现 IsDead 就 self:Clear()：
--       if self.inst.components.health and self.inst.components.health:IsDead() then
--           self:Clear(); return
--       end
--   Clear() 会立刻清掉 dest，于是 GoToPoint 每 12 tick 被调一次、又立刻被清掉，
--   玩家退化成「原地抖一下」。这是**真实的原版语义**，不是宿主缺陷。
--   但本演示（world.lua）要演的是「生物在真实地形上追逐真实玩家」这条链路，
--   需要玩家活满 2400 tick 当猎物。所以这里显式开无敌，并在第 8 节结论里如实标注。
--   若要看「玩家被打死」的真实行为，把下面这段注释掉重跑即可（玩家会在 t≈500 停住）。
if player.components and player.components.health then
    local okI = pcall(player.components.health.SetInvincible, player.components.health, true)
    print(string.format("  ★ 演示开关：health:SetInvincible(true) = %s（非引擎行为，仅为让追逐演示跑满全程）",
        tostring(okI)))
else
    print("  △ 玩家无 health 组件，跳过演示豁免")
end

-- ---- 3.2 生物 ----
-- ★ 每类生物固定用「已导出 anim_data 的那一套 build」。
--   原因：pigman 预制体在生成时随机挑皮肤（实测拿到过 pigspotted_build），
--   而工具只导出了 pig/rabbit/spider/beefalo 四套图集 —— 不固定的话
--   会有生物在可视化里**画不出来**。固定 build 只影响贴图选择，
--   不影响状态机（同一套动画名）。
-- ★ 生物清单。build 一律**显式固定**（原因见上面那段注释），
--   并且每个 build 都必须有导出的动画数据，否则播放器画不出来。
--   新增的 5 种（hound/frog/bee/catcoon/koalefant）由
--   `tools/auto_export.py` 导出 —— 它会自动为 build 找最佳动画包
--   （名字完全不可信：`pig_build` 配的既不是 `pig_basic` 也不是 `ds_pig_basic`）。
local CREATURES = {
    { name = "pigman",   build = "pig_build",             n = 2, provoke = 2 },
    { name = "rabbit",   build = "rabbit_build",          n = 2 },
    { name = "spider",   build = "spider_build",          n = 3, provoke = 3 },
    { name = "beefalo",  build = "beefalo_build",         n = 2 },
    -- ↓ 本轮新增：行为差异明显，能把世界「活起来」
    { name = "hound",    build = "hound",                 n = 2, provoke = 2 },
    { name = "frog",     build = "frog",                  n = 2 },
    { name = "bee",      build = "bee_build",             n = 2 },
    { name = "catcoon",  build = "catcoon_build",         n = 2 },
    { name = "koalefant_winter", build = "koalefant_summer_build", n = 1 },
    -- ↓ P3-2 新增：挑的是**行为差异明显**的三种，不是凑数
    --   · crow      偷玩家身上的东西 + 一路跟随（world.lua 里没有任何生物做这个）
    --   · dustmoth  飞行（其余全是地面/树上移动）+ 被光吸引
    --   · eyeplant  **不动**的敌对植物（站着不动、近身才攻击）——
    --               现有 10 种全在移动，缺一种「地形威胁」
    { name = "crow",      build = "crow_build", n = 2 },
    { name = "dustmoth",  build = "dustmoth",   n = 2 },
    { name = "eyeplant",  build = "eyeplant",   n = 1 },
    -- ↓ P3-2 第二批
    --   · mole       钻地/探头（会周期性消失又出现 —— 场上唯一的「会隐身」生物）
    --   · butterfly  在花间飞舞（prefabs/butterfly.lua:55 会
    --                SpawnPrefab("planted_flower")，给场上带来一种新植物）
    { name = "mole",      build = "mole_build", n = 2 },
    { name = "butterfly", build = "butterfly",   n = 2 },
}
-- ★ provoke = 该物种里「被激怒」的个体数。见下面 3.3 的解释。
Bootstrap.LoadPrefabFile("beefaloherd")
local rng = function() return math.random() end
math.randomseed(SEED)
local ents = {}
for _, spec in ipairs(CREATURES) do
    Bootstrap.LoadPrefabFile(spec.name)
    for i = 1, spec.n do
        local ok, inst = pcall(Core.SpawnPrefab, spec.name)
        if ok and inst then
            local x, z = WorldMap.RandomWalkablePoint(40, rng)
            inst.Transform:SetPosition(x, 0, z)
            if inst.Physics and inst.Physics.SetRadius then inst.Physics:SetRadius(0.5) end
            if inst.AnimState and inst.AnimState.SetBuild then
                pcall(inst.AnimState.SetBuild, inst.AnimState, spec.build)
            end
            inst._provoked = spec.provoke ~= nil and i <= spec.provoke
            ents[#ents + 1] = inst
        else
            -- ★ 不再静默跳过：生成失败必须看见原因，
            --   否则「少了几只生物」会被误当成「本来就是这么多」。
            print(string.format("    ✘ %s 生成失败: %s", spec.name,
                tostring(inst):sub(1, 160)))
        end
    end
end
print(string.format("  生物 %d 个：", #ents))
for _, inst in ipairs(ents) do
    local x, _, z = inst.Transform:GetWorldPosition()
    print(string.format("    %-9s guid=%-4d  pos=(%7.1f,%7.1f)  组件=%-2d  brain=%s  build=%-14s %s",
        inst.prefab, inst._guid, x, z,
        (function() local n = 0 for _ in pairs(inst._components) do n = n + 1 end return n end)(),
        tostring(inst.brain ~= nil),
        tostring(inst.AnimState and inst.AnimState._build or "?"),
        inst._provoked and "★已激怒" or ""))
end

-- ---- 3.2b 静态景物：树 / 草 / 树苗 / 浆果丛 / 石头 ----
-- 为什么加：此前世界上**只有生物**，看上去像一块空场地。
--   DST 的「世界」一半是植被与石头，加上之后才像那个游戏。
--
-- 全部走原版预制体（`evergreen` / `grass` / `sapling` / `berrybush` /
-- `rock1` / `rock2`），宿主不写任何自造逻辑；build 显式固定（理由同生物）。
--
-- ★ 它们**不参与 AI**（不加进 `ents`），但**要加进 `watched`** ——
--   否则不会进轨迹、播放器里就看不见。
local PROPS = {
    { name = "evergreen", build = "evergreen_new", n = 20 },
    { name = "grass",     build = "grass1",        n = 26 },
    { name = "sapling",   build = "sapling",       n = 16 },
    { name = "berrybush", build = "berrybush",     n = 8 },
    -- ★ 石头**没加**：`rock.zip` / `rock2.zip` 里的 anim.bin 解析出 **0 个动画**
    --   （哪怕它们各自带 build.bin），全库扫描也没有任何一个包提供
    --   「命中 rock 符号的 idle」—— 见报告第 17 节。
    --   不放进来是**诚实取舍**：放进去就是一块看不见的占位，
    --   而不是「少画了一块」这种一眼能看出的问题。
}
local props = {}
local prop_fail = {}
for _, spec in ipairs(PROPS) do
    Bootstrap.LoadPrefabFile(spec.name)
    for i = 1, spec.n do
        local ok, inst = pcall(Core.SpawnPrefab, spec.name)
        if ok and inst then
            local x, z = WorldMap.RandomWalkablePoint(56, rng)
            inst.Transform:SetPosition(x, 0, z)
            if inst.AnimState and inst.AnimState.SetBuild then
                pcall(inst.AnimState.SetBuild, inst.AnimState, spec.build)
            end
            -- 静态景物停在 idle：不播它就没有 as._curName，播放器画不出来
            if inst.AnimState and inst.AnimState.PlayAnimation then
                pcall(inst.AnimState.PlayAnimation, inst.AnimState, "idle")
            end
            props[#props + 1] = inst
        else
            prop_fail[spec.name] = (prop_fail[spec.name] or 0) + 1
        end
    end
end
print(string.format("  静态景物 %d 个（%s）",
    #props, (function()
        local c = {}
        for _, sp in ipairs(PROPS) do c[#c + 1] = sp.name .. "×" .. sp.n end
        return table.concat(c, " ")
    end)()))
if next(prop_fail) ~= nil then
    for k, v in pairs(prop_fail) do
        print(string.format("    ✘ %s 生成失败 %d 次", k, v))
    end
end

-- ---- 3.3 演示：激怒部分生物，让「追逐/攻击」真的发生 ----
-- 为什么需要这一步：
--   pigman / rabbit / spider / beefalo 在 DST 里都是**中立**生物 ——
--   翻遍 brains/spiderbrain.lua、brains/pigbrain.lua 也找不到「看见玩家就锁定」的节点。
--   所以只把它们和玩家放在同一张地图上，得到的只会是「路过」，不是「追杀」。
-- 这一步做了什么（以及为什么不是伪造）：
--   对部分生物调用 components/combat.lua 的 Combat:SetTarget(player)。
--   而 **玩家在游戏里砍它一刀时，Combat:OnAttacked 内部做的正是同一件事**：
--   把攻击者设为 combat.target。所以我们等于在演示里「替玩家招惹了」这几只生物。
--   之后的一切 —— 追不追、追多久、够不够得着、咬几口、追丢了怎么办 ——
--   全部交给真实 brain（behaviours/chaseandattack）+ 真实 combat 判定，
--   宿主一行都不插手。
if player and player._guid then
    local n_provoked = 0
    for _, inst in ipairs(ents) do
        if inst._provoked and inst.components and inst.components.combat then
            local ok, err = pcall(inst.components.combat.SetTarget, inst.components.combat, player)
            if not ok then
                print(string.format("    [诊断] %s SetTarget 抛错: %s", inst.prefab, tostring(err)))
            elseif inst.components.combat.target ~= player then
                local c = inst.components.combat
                local iok, iv = pcall(c.IsValidTarget, c, player)
                local sok, sv = pcall(c.ShouldAggro, c, player)
                print(string.format("    [诊断] %s SetTarget 返回但 target 未设上: IsValidTarget=%s(%s) ShouldAggro=%s(%s) replica.combat=%s",
                    inst.prefab, tostring(iok), tostring(iv), tostring(sok), tostring(sv),
                    tostring(inst.replica and inst.replica.combat ~= nil)))
            else
                n_provoked = n_provoked + 1
            end
        end
    end
    print(string.format("  ★ 演示：已把 %d 只生物设为「主动攻击玩家」（等价于玩家在游戏里招惹了它们）",
        n_provoked))
end

--=========================================================================
-- 4) 采样基础设施
--=========================================================================
-- 要记录的东西（每帧）：tick / 位置 / 朝向 / 当前动画名 / 帧号 / 状态名
local function build_of(inst)
    local b = inst.AnimState and inst.AnimState._build
    if type(b) == "string" then return b end
    return nil
end

local watched = { player }
for _, inst in ipairs(ents) do watched[#watched + 1] = inst end
-- ★ 静态景物也要进轨迹 —— 它们不参与 AI，但**必须被画出来**。
--   不注册的话播放器里世界还是空的（实测漏过这一步的后果就是「加了树却看不见」）。
for _, inst in ipairs(props) do watched[#watched + 1] = inst end

local tracks = {}      -- inst -> { label=..., build=..., frames={...}, states={...} }
for _, inst in ipairs(watched) do
    tracks[inst] = {
        label  = inst.prefab or inst._name,
        build  = build_of(inst),
        frames = {},        -- { {t,x,z,r,anim,fr,sg,sig}, ... }
        states = {},        -- { {t, name}, ... }
        is_player = (inst == player),
    }
end

--=========================================================================
-- ★ 符号覆盖：把 GetDrawList 已解析好的「元素 → (符号名, 图集, build)」导出
--=========================================================================
-- 背景：宿主 host/10_animstate.lua 的 GetDrawList 会应用整套符号覆盖
--   （OverrideSymbol / AddOverrideBuild / BuildHasSymbol 回落），
--   并在每个元素上给出 `symbol` / `atlas` / `bld` —— 三个字段都是
--   **相对「提供该符号的那个 build」** 而言的。
-- 而轨迹帧只存 (tick,x,z,rot,anim,fr,sg)，不含绘制列表；
-- 播放器于是只能用实体自己的 build 去查符号 → **覆盖层看不见**。
--
-- 为什么用「去重表」而不是每帧存一份：装备很少变，一段轨迹里
-- 不同的解析结果通常只有个位数，逐帧存会白白撑大 JSON。
--
-- 只在「与实体 build 不同」时记条目 —— 全都用实体 build 的情况返回 nil，
-- 播放器的零开销快路径完全不受影响。
local SIG_TABLE, SIG_INDEX = {}, {}

local function draw_sig(tr, inst)
    local as = rawget(inst, "AnimState")
    if type(as) ~= "table" or type(as.GetDrawList) ~= "function" then return nil end
    local ok, dl = pcall(as.GetDrawList, as)
    if not ok or type(dl) ~= "table" then return nil end

    local entries, key_parts = {}, {}
    for i, el in ipairs(dl) do
        -- bld 为 nil ⇒ 这个符号来自实体自己的 build，用播放器的默认路径即可
        if el.bld ~= nil then
            -- ★ 用哈希而不是名字：播放器的 build JSON 按哈希建键
            entries[i] = { el.symh or 0, el.atlas or 0, el.bld }
            key_parts[#key_parts + 1] = i .. ":" .. tostring(el.symh) .. ":"
                .. tostring(el.atlas or 0) .. ":" .. el.bld
        end
    end
    if #entries == 0 then return nil end

    local key = table.concat(key_parts, "|")
    local idx = SIG_INDEX[key]
    if idx == nil then
        idx = #SIG_TABLE + 1
        SIG_TABLE[idx] = entries
        SIG_INDEX[key] = idx
    end
    tr._sigused = true
    return idx
end

-- 状态迁移监听（新状态名 + 发生的 tick）
for _, inst in ipairs(watched) do
    local tr = tracks[inst]
    inst:ListenForEvent("newstate", function(_, data)
        local nm = data and data.statename or nil
        if nm == nil then
            local sg = rawget(inst, "sg")
            nm = sg and sg.currentstate and sg.currentstate.name
        end
        if nm ~= nil then
            local seq = tr.states
            if #seq == 0 or seq[#seq].name ~= nm then
                seq[#seq + 1] = { t = Sim.TheSim:GetTick(), name = nm }
            end
        end
    end)
end

--=========================================================================
-- 5) 跑仿真 + 采样
--=========================================================================
hr(string.format("5) 跑 %d tick（%.0f 秒世界时间），每 %d tick 采一帧",
    TICKS, TICKS / 30, SAMPLE_EVERY))

local function sample(inst, tick)
    local tr = tracks[inst]
    local t = rawget(inst, "Transform")
    if t == nil then return end
    local x, y, z = t:GetWorldPosition()
    local rot = t:GetRotation() or 0
    local as = rawget(inst, "AnimState")
    local anim, fr
    if type(as) == "table" then
        anim = as._curName
        fr = as._frame
    end
    local sg = rawget(inst, "sg")
    local sgn = sg and sg.currentstate and sg.currentstate.name
    tr.frames[#tr.frames + 1] = {
        t = tick,
        x = math.floor((x or 0) * 10 + 0.5) / 10,
        z = math.floor((z or 0) * 10 + 0.5) / 10,
        r = math.floor(rot * 10 + 0.5) / 10,
        anim = anim,
        fr = fr,
        sg = sgn,
        sig = draw_sig(tr, inst),
    }
end

-- ★★ 实体休眠的活动中心 = 玩家位置。
--   真实引擎由 C++ 按玩家距离决定实体睡不睡；宿主用这个钩子把「玩家在哪」告诉
--   更新泵（见 host/02_sim.lua 的休眠段）。半径 40 格内保持清醒，之外入睡；
--   32 格内唤醒（迟滞带，避免实体在边界上反复睡/醒抖动）。
--
--   ⚠️ 为什么必须放在这里：Lua 的闭包捕获的是**变量**，而 `local player`
--      是在很后面才声明的。若在这个位置之前定义闭包，函数体里的 `player`
--      会解析成**全局** `player`（恒为 nil）—— 症状是
--      `Sim.SleepCenter()` 每次都返回 nil，休眠一次都不发生，
--      而「SleepCenter 非 nil」的诊断却显示正常（因为闭包本身确实存在）。
--      这种「钩子在、内容错」的静默失效，只能靠计数器逐个条件排查才发现。
Sim.SleepCenter = function()
    if player == nil or not player:IsValid() then return nil end
    local x, _, z = player.Transform:GetWorldPosition()
    return x, z, 40
end

-- ★★ 玩家驱动：沿圆周「逐点行走」。
--   每一段位移都经过 真实 Pathfinder（loco:FindPath → TheWorld.Pathfinder）
--   与 真实物理（Physics:SetMotorVel），不是传送。
--
--   ★ 本次修正（实测驱动）：把「按固定 tick 重设目标」改成「**到达才推进路点**」。
--     为什么必须改 —— 这是一个可算出来的量纲问题：
--       · 若目标点按 2π/2400 rad/tick 绕圆周走，圆周线速度只有
--         2π·26/2400 ≈ 0.068 单位/tick；
--       · 而玩家真实跑速 = TUNING.WILSON_RUN_SPEED = 6 单位/秒 = 0.2 单位/tick。
--     目标比玩家**慢 3 倍**，于是每 12 tick 重设目标时玩家总是「提前到达」
--     （GoToPoint 无 bufferedaction 时 arrive_dist = ARRIVE_STEP = 0.15）：
--     走 4 tick → run_stop → 空等 8 tick → 再 run_start。
--     实测正是如此：状态序列退化成 run_start/run_stop 每 12 tick 抖一次，
--     位移 0.076 单位/tick（只有跑速的 38%）。
--   ★ 改法：路点夹角 WP_STEP=0.62 rad（弦长 ≈ 16 世界单位 ≈ 80 tick 的连续跑动），
--     并且只在 locomotor 的 dest 被清空（= 到达/停止，见 locomotor.lua 到达分支
--     的 Stop()+Clear()）时才设下一个。这样玩家会**跑完整段**再换点 ——
--     正是真实玩家「点一下、走一段」的行为，run_stop 只出现在换点那一瞬。
--   ★ MIN_RETARGET：给「路点不可达导致 GoToPoint 立即失败」兜一个下限，
--     防止 wp_index 在一帧内失控空转。
local WP_STEP = 0.62
local MIN_RETARGET = 4
-- ★ PLAYER_RUN 传给真实的 LocoMotor:GoToPoint 第三参（wantstorun）。
--   ⚠️ 诚实说明：对 **wilson 无效** —— SGwilson.lua 里只有 run_start/run/run_stop
--   三个移动状态（grep 全文件没有 walk_start/walk/walk_stop），所以不管传什么，
--   wilson 都以 TUNING.WILSON_RUN_SPEED = 6 单位/秒跑。
--   保留这个参数是因为它对「有走/跑两套状态的替身/生物」是真实的。
--   本演示里玩家跑得比蜘蛛快是事实，靠下面的「持续激怒」来保住追逐戏。
local PLAYER_RUN = true
local PROVOKE_EVERY = 60      -- 持续激怒的周期（tick）
local provoked_peak = 0       -- 同一时刻最多有几只成功锁定玩家（用于结论汇报）
local wp_index = 0
local last_retarget = -1000

--- 持续激怒（★ 演示机制，非引擎行为 —— 见 3.3 的说明）
--- 只对 _provoked 的、还活着的生物重新 SetTarget。
local function keep_provoking(i)
    if i % PROVOKE_EVERY ~= 0 then return end
    local n = 0
    for _, inst in ipairs(ents) do
        if inst._provoked and inst:IsValid()
           and inst.components and inst.components.combat
           and not (inst.components.health and inst.components.health:IsDead()) then
            if pcall(inst.components.combat.SetTarget, inst.components.combat, player)
               and inst.components.combat.target == player then
                n = n + 1
            end
        end
    end
    provoked_count = n
    if n > provoked_peak then provoked_peak = n end
end

local function drive_player(i)
    if player._is_standin then
        if i % RETARGET_EVERY == 0 then
            wp_index = wp_index + 1
            local a = wp_index * WP_STEP
            player.Transform:SetPosition(math.cos(a) * PLAYER_RADIUS, 0, math.sin(a) * PLAYER_RADIUS)
            player.Transform:SetRotation(math.deg(math.atan(-math.sin(a), math.cos(a))))
        end
        return
    end
    local loco = player.components and player.components.locomotor
    if loco == nil or Point == nil then return end
    -- dest == nil 表示「没有目的地」= 上一段已到达（或被清），此时才发新目标
    if loco.dest == nil and (i - last_retarget) >= MIN_RETARGET then
        last_retarget = i
        wp_index = wp_index + 1
        local a = wp_index * WP_STEP
        pcall(loco.GoToPoint, loco,
              Point(math.cos(a) * PLAYER_RADIUS, 0, math.sin(a) * PLAYER_RADIUS),
              nil,          -- 无 bufferedaction：纯移动
              PLAYER_RUN)   -- run = true 跑 / false 走
    end
end

local t0 = os.clock()
local errors = {}
local provoked_count = 0
local ok_run, run_err = xpcall(function()
    for i = 1, TICKS do
        drive_player(i)
        keep_provoking(i)
        Sim.Step()
        if i % SAMPLE_EVERY == 0 then
            sample(player, i)
            for _, inst in ipairs(ents) do
                if inst:IsValid() then sample(inst, i) end
            end
            -- ★ 静态景物**只在第 1 帧采一次**。
            --   它们是静止的（不移动、不换动画），逐帧采没有信息量，
            --   但每个采样点都要跑一次 draw_sig → AnimState:GetDrawList()，
            --   90 个景物 × 1200 个采样点 = 10.8 万次白跑。
            --   实测正是这里把帧率从 1285 tick/s 拖到 530。
            --   播放器侧：frameAt() 取「≤ t 的最近一帧」，单帧会被一直沿用，
            --   所以画面完全一致。
            if i <= SAMPLE_EVERY then
                for _, inst in ipairs(props) do
                    if inst:IsValid() then sample(inst, i) end
                end
            end
            -- ★ 世界级量：温度（数值连续，逐采样点存；一天跨度 14 度，值得画出来）
            local ws = _G.TheWorld.state
            world_samples[#world_samples + 1] = {
                i,
                math.floor((tonumber(ws.temperature) or 0) * 10 + 0.5) / 10,
            }
        end
    end
end, debug.traceback)
local elapsed = (os.clock() - t0) * 1000

print(string.format("  %s  世界时间 %.2f s  用时 %.0f ms（%.0f tick/s）",
    ok_run and "✔ 完成" or ("✘ 中断: " .. tostring(run_err)),
    Sim.World.time, elapsed, TICKS / math.max(elapsed, 1) * 1000))
if not ok_run then
    print("  Lua traceback（前 30 行）:")
    for line in tostring(run_err):gmatch("[^\n]+") do
        print("    " .. line)
    end
end

--=========================================================================
-- 5b) 撞墙探针 —— 直接证明「地形碰撞真的生效」
--=========================================================================
-- 主仿真里的生物都在内陆闲逛，撞不到墙（撞墙数会是 0，无法区分
-- 「碰撞被正确实现」和「碰撞从未被触发」）。所以单独做一次**定向**验证。
--
-- ★ 刻意绕开大脑与状态图：直接给 Physics 一个恒定 motor velocity 往墙里推。
--   否则大脑的 Wander 会不断覆盖 locomotor 目标，测出来的就不是物理层了。
--   （第一版正是用 locomotor:GoToPoint，探针只前进 9.8 单位就被大脑拽走，
--     撞墙数仍是 0 —— 假阴性。）
hr("5b) 撞墙探针（地形碰撞是否真的生效）")

local Map = WorldMap.GetMap()
local tiles, TW, TH = WorldMap.GetTiles()

--- 找「可通行瓦片**紧邻**不可通行瓦片」的边界（正 +x 方向隔一列）
local function find_wall_boundary()
    for cy = 30, TH - 30 do
        for cx = 30, TW - 30 do
            local x0, _, z0 = Map:GetTileCenterPoint(cx, cy)
            if Map.IsPassableAtPoint and Map.IsPassableAtPoint(Map, x0, 0, z0) then
                local x1, _, z1 = Map:GetTileCenterPoint(cx + 1, cy)
                if not Map.IsPassableAtPoint(Map, x1, 0, z1) then
                    return cx, cy, x0, z0, x1, z1
                end
            end
        end
    end
end

local pcx, pcy, px0, pz0, px1, pz1 = find_wall_boundary()
if pcx ~= nil then
    -- 瓦片分界线的世界 x 坐标：瓦片 cx 覆盖 [(cx-OX)*4, (cx-OX+1)*4)
    local wall_line = (pcx + 1 - WorldMap.WIDTH / 2) * WorldMap.TILE
    print(string.format("  边界：可通行瓦片(%d,%d) 中心 x=%.1f ｜ 墙瓦片(%d,%d) 中心 x=%.1f",
        pcx, pcy, px0, pcx + 1, pcy, px1))
    print(string.format("        瓦片分界线（理论上过不去）x = %.1f", wall_line))
    Bootstrap.LoadPrefabFile("pigman")
    local probe = Core.SpawnPrefab("pigman")
    if probe then
        probe.Transform:SetPosition(px0, 0, pz0)
        probe.Transform:SetRotation(0)                 -- 朝向 0 ⇒ 前方向量 = (+1, 0)
        pcall(probe.StopBrain, probe, "probe")         -- 停掉大脑，避免它抢走 locomotor
        local sx = px0
        local SPEED = 4
        local okp, ep = pcall(function()
            for _ = 1, 150 do
                probe.Physics:SetMotorVel(SPEED, 0, 0) -- 恒定朝 +x 推
                Sim.Step()
            end
        end)
        local fx, _, fz = probe.Transform:GetWorldPosition()
        local blocked = probe.Physics:GetBlockedCount()
        local moved = probe.Physics:GetMovedTotal()
        local final_passable = Map:IsPassableAtPoint(fx, 0, fz)
        local not_crossed = fx < wall_line + 0.001
        print(string.format("  探针 %s：以 %.0f 单位/秒沿 +x 直推 150 tick",
            okp and "✔" or ("✘ " .. tostring(ep):sub(1, 80)), SPEED))
        print(string.format("    起点 x=%.2f → 终点 x=%.2f（共前进 %.2f 世界单位）", sx, fx, moved))
        print(string.format("    物理层判定「撞墙并刹停」：%d 次", blocked))
        print(string.format("    没有越过瓦片分界线：%s（终点 %.2f  <  分界线 %.2f）",
            tostring(not_crossed), fx, wall_line))
        print(string.format("    终点仍在可通行区域：%s  ← 没穿墙", tostring(final_passable)))
        print(string.format("    对照：墙瓦片中心 x=%.1f 可通行性 = %s",
            px1, tostring(Map:IsPassableAtPoint(px1, 0, pz0))))
        probe:Remove()
    else
        print("  ✘ 探针生成失败")
    end
else
    print("  △ 未找到「可通行紧贴不可通行」的边界（换种子即可）")
end

--=========================================================================
-- 6) 轨迹摘要
--=========================================================================
hr("6) 轨迹摘要（这就是「生物真的走动了吗」的答案）")

local function dist(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

print(string.format("%-10s %-8s %-9s %-9s %-7s %-7s %s",
    "实体", "帧数", "总位移", "位移/tick", "撞墙", "状态数", "走过的状态（前 12）"))
print(string.rep("-", 74))

local summary = {}
local tnames = {}
for _, row in ipairs(WorldMap.TileStats()) do tnames[row.id] = row.name end

for _, inst in ipairs(watched) do
    local tr = tracks[inst]
    local f = tr.frames
    local total = 0
    for i = 2, #f do total = total + dist(f[i], f[i - 1]) end
    local blocked = (inst.Physics and inst.Physics.GetBlockedCount
        and inst.Physics:GetBlockedCount()) or 0
    local kinds = {}
    for _, s in ipairs(tr.states) do kinds[s.name] = true end
    local nk = 0
    for _ in pairs(kinds) do nk = nk + 1 end
    local shown = {}
    for i = 1, math.min(12, #tr.states) do shown[i] = tr.states[i].name end

    -- ★ 走过的地形种类：用**真实地图**按采样点反查，
    --   证明生物确实是在「真实瓦片」上活动，而不是在虚空里。
    local biomes = {}
    for _, fr in ipairs(f) do
        local id = Map and Map:GetTileAtPoint(fr.x, 0, fr.z)
        if id ~= nil then biomes[id] = true end
    end
    local bnames = {}
    for id in pairs(biomes) do bnames[#bnames + 1] = tnames[id] or ("#" .. tostring(id)) end
    table.sort(bnames)

    -- ★ 本实体见过的状态名清单（供「全局去重」口径用）。
    --   只报「每实体状态数求和」会误导 —— 那个数随生物数量机械增长，
    --   加 5 种生物自然就涨，但它不测「状态多样性」。
    -- ⚠️ 变量名是 `kinds`（上面 866 行算 nk 用的就是它）。
    --   第一版我写了 `pairs(seen)` —— 那个名字在这作用域不存在，
    --   `pairs(nil)` 直接报错，而**症状是「输出在表头后整段消失」**：
    --   轨迹摘要后面的统计全不打印，但前面的照常。
    --   这类「后半段静默消失」比直接崩更难注意到。
    local seen_names = {}
    for nm in pairs(kinds) do seen_names[#seen_names + 1] = nm end
    table.sort(seen_names)

    local info = {
        label = tr.label, build = tr.build, is_player = tr.is_player,
        frames = #f, moved = math.floor(total * 10 + 0.5) / 10,
        blocked = blocked, nstates = nk,
        states_seen = seen_names,
        biomes = table.concat(bnames, "/"),
        first = f[1], last = f[#f],
    }
    -- ★ 与玩家的最近距离：用来判断「追逐」到底有没有真的发生。
    --   蜘蛛/猎犬的 ChaseAndAttack 一旦锁定玩家就会持续缩短这个值。
    if not tr.is_player then
        local pf = tracks[player].frames
        local best, besti = math.huge, nil
        for i, fr in ipairs(f) do
            local pr = pf[i]
            if pr ~= nil then
                local d = dist(fr, pr)
                if d < best then best, besti = d, fr.t end
            end
        end
        info.min_player_dist = math.floor(best * 10 + 0.5) / 10
        info.min_player_at = besti
    end
    summary[#summary + 1] = info

    print(string.format("%-10s %-8d %-9.1f %-9.3f %-7d %-7d %s",
        tr.label, #f, total, total / math.max(1, #f - 1), blocked, nk,
        #shown > 0 and table.concat(shown, " → ") or "（无迁移）"))
end

print("")
print("  走过/停留过的**真实地形种类**（按采样点反查真实瓦片编号）：")
for _, s in ipairs(summary) do
    print(string.format("    %-10s %s", s.label, s.biomes ~= "" and s.biomes or "（无采样）"))
end

print("")
print("  与玩家的最近距离（判断「追逐」是否真的发生）：")
for _, s in ipairs(summary) do
    if s.is_player then
        print(string.format("    %-10s ——（它是被追的目标）", s.label))
    elseif s.min_player_dist == nil then
        print(string.format("    %-10s 无数据", s.label))
    else
        print(string.format("    %-10s 最近 %.1f 世界单位（第 %s tick）",
            s.label, s.min_player_dist, tostring(s.min_player_at)))
    end
end

print("")
print("  起点 / 终点：")
for _, s in ipairs(summary) do
    if s.first and s.last then
        print(string.format("    %-10s (%.1f,%.1f) → (%.1f,%.1f)%s",
            s.label, s.first.x, s.first.z, s.last.x, s.last.z,
            s.is_player and "   ← 玩家（脚本绕圈）" or ""))
    end
end

--=========================================================================
-- 7) 导出 JSON（供浏览器 canvas 播放）
--=========================================================================
hr("7) 导出轨迹 JSON")

-- ---- 极简 JSON 编码器（只处理本文件用到的类型）----
local esc = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jstr(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        return esc[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end
local function jnum(v)
    if v == nil then return "null" end
    if type(v) ~= "number" then return jstr(v) end
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then
        return string.format("%d", v)
    end
    return string.format("%.3f", v)
end
local function jval(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then return jnum(v) end
    if t == "string" then return jstr(v) end
    if t ~= "table" then return jstr(tostring(v)) end
    -- 数组还是对象？
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == 0 then return "[]" end
    if #v == n then
        local parts = {}
        for i = 1, n do parts[i] = jval(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = jstr(k) .. ":" .. jval(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ---- 地图：瓦片扁平数组（按行主序 cy*W+cx）----
local rawtiles, MW, MH = WorldMap.GetTiles()
local tilearr = {}
for i = 1, MW * MH do tilearr[i] = rawtiles[i] or 0 end

-- ---- 地形调色板（与 GROUND 常量对齐）----
local G = _G.GROUND or {}
local palette = {
    { id = G.GRASS or 6,          name = "草地",     color = "#5a8f3c" },
    { id = G.FOREST or 7,         name = "森林",     color = "#3f7a33" },
    { id = G.SAVANNA or 5,        name = "稀树草原", color = "#8a9a3f" },
    { id = G.MARSH or 8,          name = "沼泽",     color = "#4a6b4a" },
    { id = G.ROCKY or 3,          name = "岩石",     color = "#7d7a72" },
    { id = G.DIRT or 4,           name = "泥地",     color = "#8a6f4a" },
    { id = G.IMPASSABLE or 1,     name = "不可通行", color = "#2b2f36" },
    { id = G.OCEAN_COASTAL or 201, name = "近海",    color = "#2f6f9e" },
    { id = G.OCEAN_SWELL or 203,  name = "远海",     color = "#1d4f7a" },
}

local ents_out = {}
for _, inst in ipairs(watched) do
    local tr = tracks[inst]
    local fr = {}
    for i, f in ipairs(tr.frames) do
        -- ★ 第 8 项是符号覆盖的去重表下标（无覆盖时为 nil，
        --   播放器的默认快路径直接跳过）。见上面 draw_sig 的说明。
        fr[i] = { f.t, f.x, f.z, f.r, f.anim, f.fr, f.sg, f.sig }
    end
    local st = {}
    for i, s in ipairs(tr.states) do st[i] = { s.t, s.name } end
    ents_out[#ents_out + 1] = {
        label = tr.label,
        build = tr.build,
        is_player = tr.is_player,
        frames = fr,
        states = st,
    }
end

local payload = {
    meta = {
        generated_by = "06-引擎复刻/world.lua",
        ticks = TICKS,
        sample_every = SAMPLE_EVERY,
        tick_time = Sim.TheSim.TICK_TIME,
        seed = SEED,
        world_range = WorldMap.WIDTH * WorldMap.TILE,
        entities = #ents_out,
    },
    -- ★ 符号覆盖去重表：sigs[i] = { [元素下标] = {符号名, 图集下标, build名} }
    --   播放器的 drawEnt 按帧里的 sig 下标查它，逐元素选 build 与图集。
    sigs = SIG_TABLE,
    -- ★ 昼夜：相位变化点 + 分段长度。
    --   播放器按 `tick * tick_time` 与 phases 里相邻两项的时间区间判断当前相位，
    --   据此给画面加暮色/夜色叠色，并在 HUD 上显示「第 N 天 · 白天/黄昏/夜晚」。
    --   只存**变化点**而不是逐帧相位：1 天只有 3 次变化，逐帧存会白撑 JSON。
    daylight = {
        seg_time   = TUNING.SEG_TIME,
        day_segs   = TUNING.DAY_SEGS_DEFAULT,
        dusk_segs  = TUNING.DUSK_SEGS_DEFAULT,
        night_segs = TUNING.NIGHT_SEGS_DEFAULT,
        day_length = (TUNING.DAY_SEGS_DEFAULT + TUNING.DUSK_SEGS_DEFAULT
                      + TUNING.NIGHT_SEGS_DEFAULT) * TUNING.SEG_TIME,
        clock      = CLOCK_OK,
        -- phases = { {时间秒, 相位名}, ... }（含 t=0 的初始相位）
        phases     = phase_log,
        -- seasons = { {时间秒, 季节名}, ... }（一次运行里通常只有 1 条：
        --   一个季节 20 游戏日 = 20×480 s，远超本演示的时长）
        seasons    = season_log,
        -- samples = { {tick, 温度}, ... }，逐采样点
        samples    = world_samples,
        temp_min   = (function()
            local mn = 1e9
            for _, v in ipairs(world_samples) do if v[2] < mn then mn = v[2] end end
            return mn == 1e9 and 0 or mn end)(),
        temp_max   = (function()
            local mx = -1e9
            for _, v in ipairs(world_samples) do if v[2] > mx then mx = v[2] end end
            return mx == -1e9 and 0 or mx end)(),
    },
    map = {
        w = MW, h = MH, tile = WorldMap.TILE,
        ox = math.floor(MW / 2), oy = math.floor(MH / 2),
        out_of_bounds = WorldMap.Map.OUT_OF_BOUNDS or 1,
        palette = palette,
        tiles = tilearr,
    },
    entities = ents_out,
}

local json = jval(payload)
local fh = io.open(OUT_JSON, "w")
if fh then
    fh:write(json)
    fh:close()
    print(string.format("  ✔ 已写出 %s（%.0f KB）",
        OUT_JSON, #json / 1024))
    if #phase_log > 0 then
        local segs = {}
        for _, e in ipairs(phase_log) do
            segs[#segs + 1] = string.format("%.0fs→%s", e[1], e[2])
        end
        print(string.format("    昼夜相位变化：%s", table.concat(segs, "  ")))
    end
    local sig_desc = "（无实体使用装备/覆盖）"
    if #SIG_TABLE > 0 then
        local rows = {}
        for i, e in pairs(SIG_TABLE[1]) do
            rows[#rows + 1] = string.format("元素%d→%s@%s", i, e[1], e[3])
        end
        table.sort(rows)
        sig_desc = string.format("（首条：%s）", table.concat(rows, "  "))
    end
    print(string.format("    符号覆盖去重表：%d 条%s", #SIG_TABLE, sig_desc))
    print(string.format("    地图 %d×%d 瓦片 %d 个 · 实体 %d 个 · 轨道点 %d 个",
        MW, MH, #tilearr, #ents_out,
        (function() local n = 0 for _, e in ipairs(ents_out) do n = n + #e.frames end return n end)()))
else
    print("  ✘ 写文件失败: " .. OUT_JSON)
end

--=========================================================================
-- 8) 结论
--=========================================================================
hr("8) 结论")
local moved_any = false
for _, s in ipairs(summary) do
    if not s.is_player and s.moved > 1 then moved_any = true end
end

print(string.format("  · 地图瓦片：%d×%d（真实 GROUND 编号 + 真实可通行判定）", MW, MH))
print(string.format("  · 参与仿真的实体：%d 个（%d 生物 + 1 玩家）", #watched, #ents))
print(string.format("  · 生物在真实地形上发生位移：%s", moved_any and "是" or "否"))
print(string.format("  · 物理撞墙（滑墙）次数合计：%d",
    (function() local n = 0 for _, s in ipairs(summary) do n = n + s.blocked end return n end)()))
-- ★★ 两个口径必须分开报，否则名字会骗人。
--   原先只报「每实体状态数求和」，标签写「状态图状态种类合计」——
--   读起来像「有多少种不同状态」，实际是「所有实体的状态数之和」。
--   后者会**随生物数量机械增长**：加 5 种生物自然就涨，
--   它根本没在测「状态多样性」（实测 89 实体求和 119，全局去重只有 25）。
--   所以两个都报，并且标签写清楚。
local nstates_sum, nstates_uniq = 0, {}
for _, s in ipairs(summary) do
    nstates_sum = nstates_sum + s.nstates
    for _, nm in ipairs(s.states_seen or {}) do nstates_uniq[nm] = true end
end
local uniq_n = 0
for _ in pairs(nstates_uniq) do uniq_n = uniq_n + 1 end
print(string.format("  · 状态图：全局不同状态名 %d 种；每实体状态数求和 %d（后者随生物数量增长，"
    .. "不代表多样性）", uniq_n, nstates_sum))
-- ★ 休眠统计：入睡/唤醒次数 + 当前休眠实体数。
do
    local Upd = require("host.13_update")
    local na, ns = 0, 0
    for _, inst in ipairs(watched) do
        na = na + 1
        if inst:IsAsleep() then ns = ns + 1 end
    end
    print(string.format("  · 实体休眠：%d/%d 个实体已入睡（入睡半径 40 格，以玩家为中心）",
        ns, na))
    print(string.format("    本 tick 因休眠被跳过的组件更新：%d 个",
        Upd.LastSkipped or 0))
    -- 状态图休眠桶：原版 SGManager 的 hibernaters（只跑 updaters，不跑它）
    local SGM = _G.SGManager
    if SGM ~= nil then
        local nup, nhi = 0, 0
        if SGM.updaters then for _ in pairs(SGM.updaters) do nup = nup + 1 end end
        if SGM.hibernaters then for _ in pairs(SGM.hibernaters) do nhi = nhi + 1 end end
        print(string.format("    状态图调度桶：updaters=%d  hibernaters=%d（后者不跑 Update）",
            nup, nhi))
    end
end

-- ★ 昼夜：用**实际生效**的分段（seasons 会按季节改写，不是 TUNING 的默认值）
do
    local SD, SK, SN, SEGT = clock_segs()
    print(string.format("  · 昼夜分段（由 seasons 按季节改写）：白天 %d / 黄昏 %d / 夜晚 %d 段"
        .. " = %d / %d / %d s，1 天 %d s",
        SD, SK, SN, SD * SEGT, SK * SEGT, SN * SEGT, (SD + SK + SN) * SEGT))
    print(string.format("  · 世界状态：季节=%s  温度区间 [%.1f, %.1f]°C",
        tostring(_G.TheWorld.state.season),
        (function()
            local mn = 1e9
            for _, v in ipairs(world_samples) do if v[2] < mn then mn = v[2] end end
            return mn == 1e9 and 0 or mn end)(),
        (function()
            local mx = -1e9
            for _, v in ipairs(world_samples) do if v[2] > mx then mx = v[2] end end
            return mx == -1e9 and 0 or mx end)()))
end

-- ★ ★ 昼夜对行为的影响 —— 只有跑跨多个相位的时长（WORLD_TICKS>9000）才有意义。
--   判据：**不同相位下同一种生物的状态分布应当不同**。
--   这是「世界状态是否真的接进了 AI」的可证伪判据 ——
--   全部由原版 brains 读 `TheWorld.state.isday/isnight` 得出，宿主没写一行 AI。
--   实测（两天，30000 tick）：
--     白天  spider:sleeping 31.1%
--     夜晚  rabbit:sleeping 21.3% / beefalo:sleeping 21.0%   ← 兔子与牛在睡
if #phase_log > 1 then
    -- 复用 sample() 已经记录的每帧状态：按「该帧所处相位」分桶
    local hist = {}
    for _, e in ipairs(ents_out) do
        local label, fr = e.label, e.frames
        for _, f in ipairs(fr) do
            local sec = f[1] * Sim.TheSim.TICK_TIME
            local ph = phase_log[1][2]
            for _, pe in ipairs(phase_log) do
                if pe[1] <= sec then ph = pe[2] else break end
            end
            hist[ph] = hist[ph] or {}
            local key = label .. ":" .. tostring(f[7])
            hist[ph][key] = (hist[ph][key] or 0) + 1
        end
    end
    print("")
    print("  ── 昼夜对行为的影响（各相位下 Top3 状态）──")
    for _, ph in ipairs({ "day", "dusk", "night" }) do
        local t = hist[ph]
        if t ~= nil then
            local rows = {}
            for k, v in pairs(t) do rows[#rows + 1] = { k, v } end
            table.sort(rows, function(a, b) return a[2] > b[2] end)
            local tot = 0
            for _, r in ipairs(rows) do tot = tot + r[2] end
            local top = {}
            for i = 1, math.min(3, #rows) do
                top[#top + 1] = string.format("%s %.0f%%", rows[i][1], rows[i][2] * 100 / tot)
            end
            print(string.format("     %-6s %s", ph, table.concat(top, "  |  ")))
        end
    end
end

-- ★ 战斗事件统计：追逐/攻击是否真的发生了。
--   从「状态迁移记录」里数战斗相关状态的出现次数（不是采样帧数）。
local COMBAT = { attack = true, hit = true, hit_stunlock = true,
                 death = true, corpse = true, corpse_hit = true }
local ncombat = 0
local combat_detail = {}
for _, inst in ipairs(watched) do
    local tr = tracks[inst]
    local n = 0
    for _, st in ipairs(tr.states) do
        if COMBAT[st.name] then n = n + 1 end
    end
    if n > 0 then
        ncombat = ncombat + n
        combat_detail[#combat_detail + 1] = string.format("%s×%d", tr.label, n)
    end
end
print(string.format("  · 战斗事件（attack/hit/death 状态迁移）：%d 次  %s",
    ncombat, #combat_detail > 0 and ("（" .. table.concat(combat_detail, " ") .. "）") or "（无）"))
print(string.format("  · 演示豁免与激怒（★ 非引擎行为）：玩家无敌 = %s；持续激怒 = %s",
    tostring(player.components and player.components.health
             and player.components.health.invincible or false),
    tostring(provoked_peak > 0 and (provoked_peak .. " 只（峰值）") or "无")))
print(string.format("  · 轨迹已导出：%s", OUT_JSON))

-- ★★ 已知宿主限制（★ 非引擎行为，必须显式列出）
--   工程约定：演示豁免/非引擎行为必须显式标注，缺口必须给数字和原因。
--   这些不是 bug，但没有它们就无法正确解读上面的数字 ——
--   例如「避光行为一次都没出现」不是因为 AI 写错，而是宿主没有光照系统。
print("")
print("  ── ★ 已知宿主限制（不是 bug，但没有它们就无法解读上面的数字）──")
print("    1. 无光照系统（原版走 LightWatcher + C++ 光照贴图）")
print("       ⇒ behaviours/avoidlight 与 findlight **永不触发**")
print("    2. 无海洋系统 ⇒ IsOnOcean 恒 false，海洋分支不走")
print("    3. 无湿度系统 ⇒ GetIsWet 恒 false，潮湿/干燥相关不走")
print("    4. 无平台系统 ⇒ GetCurrentPlatform 恒 nil，骑乘不走")
print("    5. perlin 统计性质对齐，**不可能逐位复刻 C++**")
print("       ⇒ 依赖「某具体坐标上的噪声值」的逻辑会与真引擎不同")
print("    6. 玩家无敌（演示豁免）+ 部分生物持续激怒")
print("       ⇒ 主循环里生物打不死玩家；死亡/掉落走下面那段显式验证")
print("    7. 石头未加入：rock.zip/rock2.zip 的 anim 解析出 0 个动画")
print("       ⇒ 放进去就是看不见的占位，故不加（见报告 17.3）")

-- ---- 5d) 死亡与掉落验证 ----
-- 为什么单独验：主循环里**没有任何生物进入 death 状态** —— 因为猎犬主攻
--   「无敌的玩家」（演示豁免，见上面的 ★ 标注），打不动；生物互殴的伤害
--   也不足以在 80 s 内打死 150 血的猎犬。链路本身是好的（单独探针验证过：
--   DoDelta(-60) → IsDead → 进 death 89 tick → 实体被移除），
--   但「主循环从没走到这条路」不等于「这条路是通的」。
--   所以这里**显式打死一只**，把 death / lootdropper / SpawnPrefab 一并压到。
do
    local victim = nil
    for _, inst in ipairs(ents) do
        if inst:IsValid() and inst.components and inst.components.health
            and not inst.components.health:IsDead() then
            victim = inst; break
        end
    end
    if victim == nil then
        print("  · 死亡验证：找不到可用的活体（跳过）")
    else
        local vname = victim.prefab or "?"
        local H = victim.components.health
        local before = H.currenthealth
        -- 掉落物：先记下场上已有实体数，死后新增的就是掉落
        local function count_ents()
            local n = 0
            for _ in pairs(Core.Spawned) do n = n + 1 end
            return n
        end
        local n_before = count_ents()
        local saw_death, removed = false, false
        H:DoDelta(-(H.currenthealth + 10))
        for i = 1, 240 do
            Sim.Step()
            if victim.sg and victim.sg.currentstate then
                local sn = victim.sg.currentstate.name
                if sn == "death" or sn == "die" then saw_death = true end
            end
            if not victim:IsValid() then removed = true; break end
        end
        local n_after = count_ents()
        print(string.format("  · 死亡验证：%s 血量 %d → %d，IsDead=%s",
            vname, before, H.currenthealth, tostring(H:IsDead())))
        print(string.format("    进过 death 状态=%s  实体被移除=%s  场上实体 %d → %d（+%d，掉落物）",
            tostring(saw_death), tostring(removed), n_before, n_after, n_after - n_before))
        if victim.components.lootdropper then
            print("    该预制体带 lootdropper（死亡时会 GenerateLoot）")
        else
            print("    该预制体没有 lootdropper —— 不掉落是原版设定，不是缺口")
        end
    end
end

-- ★ 组件 OnUpdate 里被 pcall 吞掉的异常：不报出来就会以「桩调用」的形式
--   淹没在缺口清单里（实测 10217 次 component.OnUpdate 桩调用全是同一个异常）。
local Pump = Bootstrap.Pump
if Pump ~= nil and next(Pump.ComponentErrors or {}) ~= nil then
    print("")
    print("  ⚠️ 组件 OnUpdate 异常（被 pcall 隔离，未中断仿真）：")
    local list = {}
    for k, v in pairs(Pump.ComponentErrors) do list[#list + 1] = { k = k, v = v } end
    table.sort(list, function(a, b) return a.v > b.v end)
    for i, e in ipairs(list) do
        if i > 6 then break end
        print(string.format("     x%-7d %s", e.v, e.k))
    end
end

if not ok_run then
    print("")
    print("  ⚠️ 仿真中途中断，上面的统计是「中断前已采集」的部分。")
end

Core.DumpGaps()

--=========================================================================
-- ★ 机制健康度：**影子闸门**实际拦下了多少次重复 AddComponent
--=========================================================================
--   为什么把这个数印出来：它本来是我用一次性探针（`/tmp/_dup.lua`）量出来的
--   —— 那就犯了本工程最明确的错误之一：**数字不可复现**
--   （报告第 41.1 节记着：上一轮正是因为这个才把抽样做成入口）。
--   ⇒ 让它可以由文档里的命令复现：
--        WORLD_TICKS=2400 … world.lua     （看「影子闸门」那一行）
--
--   ★ 这个数的正确读法（报告 §44.6）：
--     它 = 「当前场景里**真的发生了**多少次重复添加」。
--     0 不代表闸门没用 —— 闸门防的是「以后任何一处（预制体/组件/场景代码）
--     重复添加」那一类 bug，而那类 bug 的症状离原因很远（clock 那条表现为
--     「相位在同一秒里来回跳」），极难从表象定位。
--   ⇒ 只说「0 次」会让人以为不用修；只说「修好了」会夸大影响面。两句都要说。
do
    -- ★★ T33：把它从「一个数」变成「**被检查过的期望**」。
    --   基线 20 已由 5 个种子复核（`WORLD_SEED`=20261013/20261015/7/4242/999983），
    --   **方差 0** —— 因为它由场景构成（98 实体的构造期）决定，与随机行为无关。
    --   ⇒ 若某天这个数变了，两种可能，都必须去看：
    --       (a) 场景真的改了（加/减了带 knownlocations 的实体）→ 更新基线即可；
    --       (b) **引入了新的重复添加** → 那就是闸门正在接住一个真问题。
    --   ⚠️ 刻意**不**做成硬断言：场景会合理地演进，硬断言会变成噪音；
    --      但**不能什么都不说** —— 悄悄变成别的数就等于这个指标失效了。
    local GATE_BASELINE = 20
    local D = Core.DuplicateAdds
    if D == nil then
        print(string.format("  · 影子闸门（重复 AddComponent）：0 次（基线 %d）"
            .. "%s", GATE_BASELINE,
            GATE_BASELINE == 0 and "" or "  ⚠ 与基线不符 —— 去看是场景变了还是引入了重复添加"))
    else
        local ks, total = {}, 0
        for k, v in pairs(D) do ks[#ks + 1] = { k, v }; total = total + v end
        table.sort(ks, function(a, b) return a[2] > b[2] end)
        local top = {}
        for i = 1, math.min(6, #ks) do
            top[#top + 1] = string.format("%s×%d", ks[i][1], ks[i][2])
        end
        print(string.format("  · 影子闸门（重复 AddComponent）：%d 个组件名 / **%d 次**  %s",
            #ks, total, table.concat(top, " ")))
        if total ~= GATE_BASELINE then
            print(string.format("      ⚠ 与基线 %d 不符 —— 两种可能都要看：" ..
                "① 场景改了（带 knownlocations 的实体数变了）；" ..
                "② **引入了新的重复添加**（那正是闸门该接住的问题）",
                GATE_BASELINE))
        end
    end
end
