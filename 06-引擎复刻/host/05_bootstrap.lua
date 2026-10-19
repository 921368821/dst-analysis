--[[
==============================================================================
 05_bootstrap.lua —— 统一启动序列

 把「装全局 → 加载 class → 加载 tuning → 加载标准组件 → 装 require 钩子」
 这套固定顺序固化成一个函数，run.lua / batch.lua / 以后的任何入口都调它。

 ★ 为什么单独抽出来
   启动顺序踩过三次坑：
     1) require 钩子必须早于 scheduler.lua 加载（它内部 require("class")）
     2) class.lua 要先于任何组件（组件用 Class(...)）
     3) tuning.lua 会执行 `TUNING = {}` **重建全局表**，
        所以必须先装好钩子再加载 tuning，且加载后要重新挂元表兜底
==============================================================================
]]

local Core = require("host.01_core")
local Loader = require("host.04_loader")
local Sim = require("host.02_sim")
local G = require("host.03_globals")
-- ★ M6：列目录的唯一实现（$DST_FILELIST 清单 → ls -1 → dir /b 三级降级）
--   本文件原先直接 `io.popen('dir /b ... 2>nul')`，在 Linux/macOS 上恒空，
--   表现为「behaviours 只加载 0 个文件」——静默降级而不是报错。
local FileList = require("host.31_filelist")

local Bootstrap = {}

--- 装引擎全局到 _G
function Bootstrap.InstallGlobals()
    for k, v in pairs(G) do
        if k ~= "TheSim" then _G[k] = v end
    end
    _G.TheSim = Sim.TheSim
    _G.TheWorld = Sim.World
    _G.TheNet = G.TheNet
    -- ★ 这三个是引擎注册的全局函数，pighouse.lua 结尾直接调 Prefab(...)
    _G.Prefab = Core.Prefab
    _G.CreateEntity = Core.CreateEntity
    _G.SpawnPrefab = Core.SpawnPrefab
    -- ★ `Prefabs` 注册表：main.lua:288 `Prefabs = {}` 是引擎的预制体登记表。
    --   periodicspawner.lua:33 直接用它做断言：
    --     `assert(type(prefab) == "function" or Prefabs[prefab] ~= nil)`
    --   不别名的话 beefalo 等多组件生物实例化时会在这里断掉（实测）。
    _G.Prefabs = Core.Prefabs
end

--- 完整启动序列
-- @param opts.use_real_tuning 是否加载真实 tuning.lua（默认 true）
function Bootstrap.Setup(opts)
    opts = opts or {}
    if opts.use_real_tuning == nil then opts.use_real_tuning = true end

    Bootstrap.InstallGlobals()

    -- ★ WORLDSTATETAGS —— 运行时从真实 mainfunctions.lua 里**切出**并执行
    --   （不是照抄一段：照抄会随版本漂移）。
    --   实测症状：moonrockseed.lua:276 `WORLDSTATETAGS.SetTagEnabled(...)`
    --   ✘ attempt to index global 'WORLDSTATETAGS' (a nil value)
    --   必须在 InstallGlobals 之后 —— 段里要用 `bit` 等已注入的全局。
    do
        local ok, mod = pcall(require, "host.24_worldstatetags")
        Bootstrap.WorldStateTags = ok and mod or false
        if ok and mod ~= nil then
            if not mod.Install() then
                print("  [bootstrap] WORLDSTATETAGS 安装失败: " .. tostring(mod.Error))
            end
        end
    end

    -- ★ main.lua:441-456 的四个渲染层管理器全局
    --   （ShadowManager / RoadManager / EnvelopeManager / PostProcessor）
    --   实测症状：3 个预制体栽在 `EnvelopeManager` 为 nil 上，其中 `pollen`
    --   是**服务端** weather.lua:400 主动 spawn 的。详见 host/25_render_managers.lua。
    do
        local ok, mod = pcall(require, "host.25_render_managers")
        Bootstrap.RenderManagers = ok and mod or false
        if ok and mod ~= nil then mod.Install() end
    end

    -- ★ 安装网络变量层（net_bool / net_float / net_entity / net_event ...）。
    --   真实 DST 里这些是 C++ 注册的全局函数，scripts/netvars.lua 一行实现都没有。
    --   宿主的哑桩版本「读出来是 nil」，会让真实组件在**读** netvar 时炸掉：
    --     combat_replica.lua:724  `target:GetPosition().y <= self._attackrange:value()`
    --   必须早于任何组件构造（所以放在 Setup 最前面）。
    do
        local ok, mod = pcall(require, "host.12_netvars")
        Bootstrap.NetVars = ok and mod or false
        if ok and mod ~= nil then
            pcall(mod.Install)
        else
            print("  [bootstrap] netvars 安装失败: " .. tostring(mod))
        end
    end

    -- ★ 安装 replica 分发层（对齐 scripts/entityreplica.lua）。
    --   它给 EntityScript 补上 ValidateReplicaComponent / ReplicateComponent /
    --   UnreplicateComponent / PrereplicateComponent，
    --   并把 inst.replica.<name> 接到**真实**的 components/<name>_replica.lua 上。
    --   必须在任何 AddComponent 之前装好 —— 因为 AddComponent 会自动调
    --   ReplicateComponent（对齐 entityscript.lua:631）。
    do
        local ok, mod = pcall(require, "host.14_replica")
        Bootstrap.Replica = ok and mod or false
        if ok and mod ~= nil then
            local okI = pcall(mod.Install, Core)
            Bootstrap.ReplicaInstalled = okI or false
        else
            print("  [bootstrap] replica 安装失败: " .. tostring(mod))
        end
    end

    -- ★ 注册 AnimState 装饰器：把「纯桩」升级成「真实帧数据驱动」。
    --   ZipAnim 解出来后（tools/export_anim.py 导出 anim_data/<build>.lua），
    --   AnimState 就能真的给出逐帧绘制指令，而不是永远返回桩。
    --   找不到对应数据时装饰器**自动退回桩行为**，所以不会破坏既有入口。
    do
        local ok, err = pcall(function()
            local Stubs = require("host.00_stubs")
            local AS = require("host.10_animstate")
            AS.OnMissing = function(build, path)
                -- ★★ 这里记的是「**动画数据没导出**」，不是「方法缺语义」。
                --
                -- 两者混在一起会污染指标：`hats.lua` 一加载就会给 wilson 登记
                -- 二十多个 player_* 动作 build（player_actions_farming / player_oar /
                -- player_boat_* …），本场景一个都用不到，于是凭空多出 22 条
                -- 「桩调用」，把真正需要补语义的项淹掉。
                --
                -- 所以另立一个计数器 Core.MissingBuilds，报告时单列一段：
                --   · 桩调用   = 契约内接口有桩、缺真实语义  → **要补实现**
                --   · 缺 build = 这个 build 我们没有导出数据  → **要补导出（或本就用不到）**
                if Core == nil then return end
                local name = tostring(build)
                if Core.MissingBuilds == nil then
                    Core.MissingBuilds = {}
                    Core.MissingBuildCount = {}
                end
                if not Core.MissingBuilds[name] then
                    Core.MissingBuilds[name] = true
                    Core.MissingBuildCount[name] = 1
                else
                    Core.MissingBuildCount[name] = Core.MissingBuildCount[name] + 1
                end
                -- ★ 转发「真实请求次数」。OnMissing 每个 build 只触发一次，
                --   所以 MissingBuildCount 恒为 1（它其实是「缺了」这个布尔），
                --   报告按它排序等于没排。真正的次数在 10_animstate.M.MissingHits，
                --   那边在每次 ensure 失败时都会累加。
                if Core ~= nil and AS ~= nil and AS.MissingHits ~= nil then
                    Core.MissingBuildHits = AS.MissingHits
                end
            end
            Stubs.OnDecoratorError = function(name, e)
                if Core and Core.NoteGap then
                    Core.NoteGap("decorator:" .. name .. " → " ..
                        tostring(e):sub(1, 120), "decorator")
                end
            end
            Stubs.AddDecorator("AnimState", function(obj, inst)
                AS.Decorate(obj, inst)
            end)
            Bootstrap.AnimStateReal = true
        end)
        if not ok then
            Bootstrap.AnimStateReal = false
        end
    end

    -- ★ 注册 Physics 装饰器：给「纯桩」补上真实位移语义。
    --   桩只会把 SetMotorVel 的参数记下来，位置永远不动 ——
    --   而 DST 的移动是「C++ 物理把 motor velocity 积分成位移」，
    --   没有这一步 locomotor 的全部距离判断都停在原地。
    --   见 host/11_physics.lua（含「motor velocity 是局部坐标」的推导）。
    do
        local ok = pcall(function()
            require("host.11_physics")
            Bootstrap.PhysicsReal = true
        end)
        if not ok then Bootstrap.PhysicsReal = false end
    end

    -- ★★★ world 实体的组件装配（world_postinit）。
    --
    --   照 `prefabs/world.lua` 的 world_postinit 那一批。必须在**这里**做，
    --   不能放在 02_sim 的模块加载期 —— 那时 `Core.SourceDir` 与 Loader
    --   都还没就绪，`LoadRealComponent` 会一律返回 nil（实测报「类加载不了」）。
    --
    --   为什么要装：`components/walkableplatform.lua:66/70/74` 直接
    --       TheWorld.components.walkableplatformmanager:RegisterPlatform(self.inst)
    --   而 `prefabs/boat.lua:412` 会 `inst:AddComponent("walkableplatform")`
    --   —— 后者构造期就要用到前者。缺了它：
    --       walkableplatform 构造失败 ⇒ boat_ancient / boat_otterden 等
    --       预制体**生成不出来**（300 抽样里 3 个因此失败）。
    --
    --   装配失败**不阻断启动**，记进缺口清单让报告能看见。
    --
    -- ★★ 为什么做成「可重跑的两趟」而不是一趟：
    --   本块在 Setup 的**早期**执行，那时 constants.lua / 启动文件清单
    --   都还没加载完。`ambientlighting` 的类体在**模块顶层**就求值
    --   `SCREEN_FLASH_SCALING[Profile:GetScreenFlash() or 1]`（:88），
    --   依赖 constants 提供的全局表 —— 早期加载会失败。
    --   实测：只跑早期这一趟时 ambientlighting 挂不上（缺口清单里
    --   记的是「类加载不了」），而**同一份代码在 Setup 结束后**能加载成功。
    --   ⇒ 拆成 mount 函数，早一趟 + 晚一趟（Setup 末尾）各跑一次。
    --     重跑安全：只补 `components[cname] == nil` 的那些。
    local WORLD_ASSEMBLY_COMPONENTS = {
        "walkableplatformmanager",
        "walkableplatformplayer",
        "nutrients_visual_manager",
        -- ★★★ ambientlighting —— 来源与上面三个**不同**：
        --   它在 **世界类型**预制体里挂，不在 world_network
        --   的列表里。`prefabs/forest.lua:626-638`：
        --       inst:AddComponent("ambientlighting")
        --       --Dedicated server does not require these components
        --       --NOTE: ambient lighting is required by light watchers
        --       if not TheNet:IsDedicated() then ... end
        --   ★ 这一行在 `not IsDedicated` 块**之外** —— 注释明说
        --     「light watchers 需要它」，所以服务端也有。
        --   宿主不走 MakeWorld 路径 ⇒ 得自己补。
        --   实测症状（reachability.lua 抽样）：
        --       prefabs/moon_fissure.lua:49
        --       TheWorld.components.ambientlighting:GetVisualAmbientValue()
        --       ✘ attempt to index field 'ambientlighting' (a nil value)
        --   影响面 > 1：所有 light watcher（灯笼/营火/月光连枷）
        --   都靠 GetVisualAmbientValue 判断环境亮度。
        "ambientlighting",
        -- ★★★ farming_manager —— P41 农业链路实测出来的缺口：        --   `components/farmsoildrinker.lua:40` 直接读
        --       TheWorld.components.farming_manager:...
        --   缺了它就 **每次土壤湿度结算都抛错** ⇒ 作物 `Growable:DoGrowth()`
        --   每次都断在压力测试里 ⇒ **作物永远长不熟**（收获链路整条走不到）。
        --   原版由 `prefabs/world.lua` 的 world_postinit 挂，宿主不走那条路径 ⇒ 自己补。
        -- ★ worldsettingstimer 必须排在 farming_manager **之前**：
        --   farming_manager 在**构造期**就把 `TheWorld.components.worldsettingstimer`
        --   抓进局部变量（farming_manager.lua:56），缺了直接崩在 :85：
        --       attempt to index local '_worldsettingstimer' (a nil value)
        --   这正是「顺序即依赖」的一个实例 —— 列表顺序不是随便排的。
        -- ★★ 这两个**只能晚装**（阶段标记）：它们都在**构造期**抓外部引用 ——
        --   farming_manager 抓 `_world.Map`（:56）与 `worldsettingstimer`（:57），
        --   而 `world.Map` 是 `20_map.lua` 的 Install 里才赋值的。
        --   早装 ⇒ 抓到 nil ⇒ 铺瓦片时 `_nutrientgrid` 永远是 nil ⇒ 世界生成直接崩。
        --   （实测：`farming_manager.lua:155 attempt to index upvalue '_nutrientgrid'`）
        { name = "worldsettingstimer", phase = "late" },
        { name = "farming_manager",     phase = "late" },
        -- ★★★ undertile —— P41 农业链路实测出来的**第二个**缺口，
        --   位置在 farming_manager 的 `OnTerraform` 回调里（farming_manager.lua:163/180）：
        --       TheWorld.components.undertile:SetTileUnderneath(x, y, ...)
        --       TheWorld.components.undertile:ClearTileUnderneath(x, y)
        --   只要地图上发生**任何一次** `SetTile`（哪怕是世界生成时抹平出生点），
        --   `OnTerraform` 就会去索引这个字段 ⇒ 缺了直接崩在
        --       farming_manager.lua:181 attempt to index field 'undertile' (a nil value)
        --   而且崩的是**世界生成**（`20_map.lua Generate` → `Map:SetTile` 那条栈），
        --   不是作物逻辑 —— 症状离病因很远，值得单列注释。
        --   「地表下面原本是什么地砖」由它是唯一权威：造田/挖地/回填都靠它还原。
        -- ★ 同样**只能晚装**：构造期抓 `_world.Map`（undertile.lua:33），
        --   而 `world.Map` 是 `20_map.lua` 的 Install 里才赋值的。
        -- ★ 它的 `_underneath_tiles`（DataGrid）由 `worldmapsetsize` 事件建立
        --   （undertile.lua:40-43）—— 那个广播在 `mount_world_components` 末尾发，
        --   所以必须排在本函数内、且 `Loader.Load("datagrid")` 已完成（见 §8 datagrid）。
        { name = "undertile",           phase = "late" },
    }

    local function mount_world_components(phase)
        local World = rawget(_G, "TheWorld") or (Core.World)
        if World == nil then return end
        World.components = World.components or {}
        for _, entry in ipairs(WORLD_ASSEMBLY_COMPONENTS) do
            -- 条目可以是字符串（两趟都试），也可以是 {name=, phase=}（只在指定趟装）
            local cname, want = entry, nil
            if type(entry) == "table" then cname, want = entry.name, entry.phase end
            if cname ~= nil and (want == nil or want == phase)
               and World.components[cname] == nil then
                local cls = Core.LoadRealComponent(cname)
                if cls ~= nil then
                    local okc, inst = pcall(cls, World)
                    if okc and inst ~= nil then
                        World.components[cname] = inst
                    elseif phase == "late" then
                        Core.NoteGap("world-component:" .. cname .. " (构造失败)",
                                     "world_postinit")
                    end
                elseif phase == "late" then
                    Core.NoteGap("world-component:" .. cname .. " (类加载不了)",
                                 "world_postinit")
                end
            end
        end
        -- ★★ 晚装之后补发 `worldmapsetsize`：`farming_manager` 靠这个事件才去建
        --   `_nutrientgrid` / `_moisturegrid`（farming_manager.lua:149 InitializeDataGrids）。
        --   为什么必须**晚装之后再发**：这两个世界组件在构造期抓 `world.Map`，
        --   而 Map 是 Install 里才挂到 world 上的 —— 早装抓到 nil，
        --   发事件时 `_map:GetSize()` 就会崩。
        --
        -- ★★★ 事件**必须带 {width, height}** —— P41 实测踩过：
        --   一开始发的是 `PushEvent("worldmapsetsize")`（无参数），
        --   `farming_manager` 侥幸没事（它自己调 `_map:GetSize()`，忽略 payload），
        --   但 `undertile` 是**从 payload 取**的（undertile.lua:40-43）：
        --       local function InitializeDataGrid(src, data)
        --           _underneath_tiles = DataGrid(data.width, data.height)
        --       end
        --   无参数 ⇒ data 为 nil ⇒ pcall 记一条 Gap 就过 ⇒ `_underneath_tiles`
        --   永远是 nil ⇒ 下一次 `SetTile` 崩在
        --       undertile.lua:57 attempt to index upvalue '_underneath_tiles' (a nil value)
        --   教训：**同一个事件被多个订阅方用不同方式消费时，payload 不能省**。
        if phase == "late" and type(World.PushEvent) == "function" then
            local payload = nil
            local M = World.Map
            if M ~= nil and type(M.GetSize) == "function" then
                local w, h = M:GetSize()
                if type(w) == "number" and type(h) == "number" then
                    payload = { width = w, height = h }
                end
            end
            local okEv, errEv = pcall(function()
                World:PushEvent("worldmapsetsize", payload)
            end)
            if not okEv then
                Core.NoteGap("worldmapsetsize 广播失败: " .. tostring(errEv):sub(1, 90),
                             "world_postinit")
            elseif payload == nil then
                Core.NoteGap("worldmapsetsize 广播缺少尺寸（world.Map 不可用）",
                             "world_postinit")
            end
        end
    end
    Bootstrap.MountWorldComponents = mount_world_components
    mount_world_components("early")

    -- ★ 可选：安装万能兜底全局。
    --   玩家预制体（player_common 2986 行）会引用几十个未定义全局，
    --   逐个补会被连锁拖死。开启后未知全局返回一个「什么都能做」的对象，
    --   且**每次访问都记入桩调用清单**（Core.NoteStub），不静默掩盖。
    if opts.universal_globals then
        require("host.07_universal").Install(require("host.01_core"))
        Bootstrap.UniversalEnabled = true
    end

    -- 1) class.lua —— 零引擎依赖，定义全局 Class
    Loader.LoadFile(Core.SourceDir .. "/class.lua")
    if type(_G.Class) ~= "function" then
        _G.Class = function(base, ctor) return ctor or function() end end
    end

    -- 2) 真实 tuning.lua —— 5163 个真实数值键
    --    用契约发现模式跑，缺的全局自动补 0 并报告
    if opts.use_real_tuning then
        local ok, err, disc = Loader.DiscoverGlobals(function()
            Loader.LoadFile(Core.SourceDir .. "/tuning.lua")
        end)
        Bootstrap.TuningLoaded = ok
        Bootstrap.TuningDiscovered = disc or {}
        if not ok then
            print("  [bootstrap] tuning.lua 加载失败: " .. tostring(err))
        end
    end

    -- ★ EntityScript 全局类：真实引擎由 entityscript.lua 定义并注册为全局。
    --   宿主不加载 5377 行的 entityscript.lua（它耦合太深），
    --   但很多文件直接 `EntityScript.IsEntity(inst)` 这类调用
    --   （sourcemodifierlist.lua:85 实测），所以给一个指向宿主 EntityMeta 的替身。
    if _G.EntityScript == nil then
        _G.EntityScript = setmetatable({}, {
            __index = function(_, k)
                return function(inst, ...)
                    if inst and inst.components and inst.components[k] then
                        local c = inst.components[k]
                        if type(c) == "function" then return c(inst, ...) end
                    end
                    return nil
                end
            end,
        })
    end
    G.EntityScript = _G.EntityScript

    -- 3) tuning.lua 执行了 `TUNING = {}` 重建全局表，
    --    元表兜底被冲掉 → 重新挂上，让仍缺的键返回 0 而不是 nil
    if getmetatable(_G.TUNING) == nil then
        setmetatable(_G.TUNING, {
            __index = function(t, k)
                if rawget(t, k) ~= nil then return rawget(t, k) end
                Core.NoteGap("TUNING." .. tostring(k), "post-tuning-index")
                return 0
            end,
        })
    end

    -- ★ stategraph.lua（759 行，已深度注释）—— 大量组件会读 `inst.sg`：
    --   sleeper.lua:83 `inst.sg and inst.sg:HasStateTag("busy")`
    --   locomotor / burnt / freezable 等几十处。直接加载真实版而非写桩。
    do
        local ok, err = pcall(function()
            Loader.LoadFile(Core.SourceDir .. "/stategraph.lua")
        end)
        Bootstrap.StateGraphLoaded = ok
        if not ok then
            print("  [bootstrap] stategraph.lua 加载失败: " .. tostring(err))
        end
        -- ★ 给真实的 StateGraphInstance **类**补方法。
        --   实例靠类表 __index 找方法，只在实例上 rawset 不够 ——
        --   真实代码（playercontroller 等）也会创建实例。
        --   我们没让真实 SG 跑起来（SGwilson 有 28601 行，
        --   过不了 stategraph.lua:188 的校验），所以这些方法一律返回
        --   「空集 / 不在播放」语义。
        --
        -- ★★★ 方法清单现在**只在 Core.SG_METHODS 维护一份**。
        --   原先这里手写一份 17 个方法的表，与 01_core 的 DefaultSG、
        --   06_entityscript 的降级分支**三份互相独立**，且三份**都漏了
        --   `HasState`**（真实 stategraph.lua:1976 有它）。
        --   实测代价：4 个 `*corpse` 预制体 spawn 崩在
        --   `componentutil.lua:942 ent.sg:HasState("electrocute")`。
        if ok and type(_G.StateGraphInstance) == "table" then
            Core.ApplySGMethods(_G.StateGraphInstance, { only_missing = true })
            Bootstrap.SGMethodsApplied = true
        end
    end

    -- ★★ 加载真实的 strings.lua（18822 行 / 840 KB）
    --   宿主原先用「任意键返回键名本身」的惰性表冒充 STRINGS ——
    --   但那样**中间层也返回字符串**：STRINGS.BALATRO 得到字符串 "BALATRO"，
    --   再往下索引 .JIMBO_REWARD_TYPES 就是 nil →
    --   balatro_machine.lua:6 的 `pairs(...)` 直接报 "table expected, got nil"；
    --   STRINGS.CHARACTERS.GENERIC.DESCRIBE 同理让 corpses.lua:602 崩。
    --   真表一加载，这两类问题同时消失，而且**文案是真的**（不再退回键名）。
    do
        local ok, err = Loader.Load("strings")
        Bootstrap.StringsLoaded = ok
        if not ok then
            print("  [bootstrap] strings.lua 加载失败: " .. tostring(err):sub(1, 120))
        end
    end

    -- 4) 标准组件与工具
    for _, m in ipairs({
        "easing", "standardcomponents", "prefabutil", "worldsettingsutil",
        -- ★ commonstates 定义全局 CommonHandlers（combat.lua:102 等大量组件要用）
        "stategraphs/commonstates",
        -- ★ sourcemodifierlist 定义全局 SourceModifierList。
        --   inventory.lua:62 / sanity.lua:79 / health.lua / burnable.lua 都要用
        "util/sourcemodifierlist",
        -- ★ simutil 定义 FindWalkableOffset / FindSwimmableOffset 等地图查询。
        --   childspawner.lua:548 等生成逻辑要用。
        "simutil",
        -- ★ worldtiledefs 定义全局 PlayFootstep（worldtiledefs.lua:89）。
        --   SGpig.lua:322 的 TimeEvent(0, PlayFootstep) 需要它，
        --   否则 stategraph.lua:188 的 assert 会失败 → 整个 SG 加载不了。
        --   同时它还提供 GROUND / WORLD_TILES 的真实定义。
        "worldtiledefs",

        -- ★★ recipe / recipes / gamemodes —— 配方系统（原版 1151+1765+329 行）
        --
        --   起因：components/builder.lua:93-94 `for k, v in pairs(AllRecipes) do
        --   if IsRecipeValid(v.name) then` 这类调用此前拿到的是**万能兜底对象**：
        --       · AllRecipes   → 遍历 0 次（Lua 5.1 的 pairs 不看 __index）
        --       · IsRecipeValid → 返 nil（假值）→ builder 永远不认任何配方
        --   修法不是打桩，而是**加载真实文件** —— recipe.lua:361 自己就有
        --   `AllRecipes = {}`，:1046 有 `IsRecipeValid`（= `GetValidRecipe(rec) ~= nil`）。
        --
        --   依赖链（实测全部可满足）：
        --       recipe.lua     require class / util          → 已有
        --       recipes.lua    调 AddRecipePostInit ×1122     → 宿主补（C++ 全局）
        --       gamemodes.lua  无 require                    → 独立
        --       GetValidRecipe → TheNet ~= nil               → 宿主给 TheNet:GetServerGameMode()
        --   顺序：gamemodes 先（IsRecipeValidInGameMode 靠它）→ recipe → recipes。
        "gamemodes",
        "recipe",
        "recipes",

        -- ★★ networkclientrpc —— RPC 常量表与发送函数（原版 2004 行）
        --
        --   起因：跑满一整天（14800 tick）时崩在
        --       skilltreeupdater.lua:177: attempt to index global 'CLIENT_RPC' (a nil value)
        --   链路：experiencecollector.lua:22 UpdateXp → skilltreeupdater:AddSkillXP
        --         → `SendRPCToClient(CLIENT_RPC.AddSkillXP, ...)`
        --
        --   这一个文件同时定义了：
        --     · `CLIENT_RPC = {}`（:1521，15 条客户端 RPC 常量）
        --     · `RPC = {}`        （:1388，服务端 RPC 常量）
        --     · `SendRPCToServer` （:1636；:1998 有「非 mastersim 时为 no-op」的兜底）
        --   宿主无网络栈，这些函数自然退化成空操作 —— 但**常量表必须是真的**，
        --   否则 `CLIENT_RPC.AddSkillXP` 这种索引就直接崩。
        "networkclientrpc",

        -- ★★ bufferedaction —— BufferedAction 类的真实现（原版 110 行）
        --
        --   起因：扩大生物种类后崩在
        --       brains/catcoonbrain.lua:54: attempt to call global 'BufferedAction'
        --   全库到处用 `BufferedAction(doer, target, action, invobject, pos, ...)`
        --   构造「一次具体动作执行」，宿主一直没加载这个文件。
        --   它**自包含**（无 require），且定义了我们此前在 06_entityscript.lua 里
        --   用 pcall 兜底调用的那几个方法：Do / Fail / Succeed / TestForStart / IsValid。
        --   ⇒ 加载它之后，宿主那套 BufferedAction 体系换成**真对象**，
        --     不再依赖 pcall 兜底。
        "bufferedaction",

        -- ★★ physics —— CollisionMaskBatcher 与碰撞回调桥（原版 222 行）
        --
        --   起因：扩大生物种类后 SGManager **每帧报桩**，错误被 pcall 吞掉
        --   （补了 Core.SGErrors 记录后才看见）：
        --       ocean_util.lua:160: attempt to call global 'CollisionMaskBatcher'
        --   它定义在 physics.lua:23 —— 一个「批量改碰撞掩码」的辅助类
        --   （链式 ClearCollidesWith / CollidesWith / CommitTo）。
        --   飞行生物落地/起飞（LandFlyingCreature / RaiseFlyingCreature）
        --   必经此处，缺了它整条状态图更新直接中断。
        --   该文件还定义 `OnPhysicsCollision`（引擎回调进 Lua 的入口）
        --   与 `PhysicsCollisionCallbacks` 表。
        "physics",

        -- ★★ stringutil —— 字符串工具（原版 622 行，**无 require**）
        --
        --   起因：burn.lua 验证里协程脚本崩在
        --       components/talker.lua:180: attempt to call global
        --           'GetSpecialCharacterPostProcess' (a nil value)
        --   它是 stringutil.lua:240 定义的（一个已弃用的兼容桩，原样返回字符串），
        --   宿主一直没加载这个文件。
        --   ⚠️ 症状有迷惑性：报错来自**协程脚本**（talker 的 sayfn），
        --   不是主线程，所以它不会中断 Sim.Step，只是那条脚本静默死掉。
        --   代价是「实体不会说话了」，而且 burnt 标签推进也被连累（见 burn.lua）。
        "stringutil",

        -- ★★ emitters —— 粒子发射器工厂（原版 225 行，纯 Lua，只 require("class")）
        --
        --   它定义 8 个全局发射器构造器：
        --       UnitRand / CreateDiscEmitter / CreateCircleEmitter / CreateRingEmitter /
        --       CreateSphereEmitter / CreateBoxEmitter / CreateAreaEmitter / Create2DTriEmitter
        --     以及 `EmitterManager`（休眠/唤醒式更新管理器）。
        --
        --   影响面（全库计数）：**46 个文件 / 61 处调用**
        --       CreateSphereEmitter x53   CreateBoxEmitter x8
        --   全是 fx 预制体（rain / pollen / eyeflame / lighterfire_* / nightsword_*_fx /
        --   lunar_goop_cloud_fx / miasma_cloud_fx / confetti_fx …）。
        --
        --   实测症状（reachability.lua）：
        --       prefabs/pollen.lua:90              CreateBoxEmitter(...)
        --       prefabs/nightsword_sharp_fx.lua:229 CreateSphereEmitter(...)
        --       prefabs/lunar_goop_cloud_fx.lua:100 CreateSphereEmitter(...)
        --       ✘ attempt to call global 'CreateSphereEmitter' (a nil value)
        --   ★ 这是「先补 EnvelopeManager，报错点往后移一格」露出来的下一个缺口
        --     —— 修好一个缺口后**必须重跑**，否则只会看到最外层那一个。
        "emitters",

        -- ★★ vecutil —— 二维向量工具（原版 108 行，纯 Lua，只本地化 math.sqrt）
        --
        --   定义 17 个全局 `VecUtil_*`：Add/Sub/Scale/Dot/Length/Normalize/
        --   Rotate/GetAngle/AngleBetween/Project/... 。
        --   实测症状（reachability.lua 抽样）：
        --       prefabs/carnivalgame_shooting.lua:194
        --       ✘ attempt to call global 'VecUtil_RotateDir' (a nil value)
        --     ⇒ `carnivalgame_shooting_kit_placer` 生成不出来。
        --   载入顺序无关紧要（无依赖），但必须在 prefab 工厂执行前。
        "vecutil",
    }) do
        Loader.Load(m)
    end

    -- ★ constants.lua 一次提供 MATERIALS / TOOLACTIONS / UPGRADETYPES /
    --   EQUIPSLOTS / SANITY_MODE_* / COLLISION / WORLD_TILES 等大批全局常量表。
    --   它在第 186 行引用 IsConsole 等平台判断全局，用契约发现模式跑完，
    --   否则后半段的 MATERIALS/TOOLACTIONS 根本不会被执行到。
    do
        local ok, err, disc = Loader.DiscoverGlobals(function()
            local r, e = Loader.LoadFile(Core.SourceDir .. "/constants.lua")
            if r == nil and e then
                -- LoadFile 用 pcall 吞错，这里把真实错误抛出来让 DiscoverGlobals 收到
                error(e, 0)
            end
            return r
        end)
        Bootstrap.ConstantsLoaded = ok
        Bootstrap.ConstantsDiscovered = disc or {}
        if not ok then
            print("  [bootstrap] constants.lua 加载失败: " .. tostring(err))
        end
    end

    -- ★ GROUND：constants.lua:753 定义的真实地形枚举（OCEAN_SWELL=203 等）。
    --   ⚠️ 宿主原先用 `setmetatable({}, {__index=function() return 0 end})` 造假表，
    --      任何键都返回 0 —— 结果 `SCHOOL_WEIGHTS[SEASONS.AUTUMN][GROUND.OCEAN_SWELL]`
    --      取到的是 nil（真表用的是 203），oceanfishdef 在 1079 行直接崩，
    --      再连带把 cooking 也拖挂（cooking 顶层就 require 它）。
    --   改为：用 constants 里的真表，只给缺失的键补惰性值。
    do
        local g = _G.GROUND
        if type(g) ~= "table" then g = {}; _G.GROUND = g end
        local nextid = 1
        for _, v in pairs(g) do
            if type(v) == "number" and v >= nextid then nextid = v + 1 end
        end
        setmetatable(g, {
            __index = function(t, k)
                if type(k) ~= "string" or k:match("^_") then return nil end
                local id = nextid
                nextid = nextid + 1
                rawset(t, k, id)
                return id
            end,
        })
        G.GROUND = g
    end

    -- ★★ WORLD_TILES 必须与 GROUND **共用同一套编号**。
    --   真引擎里 `WORLD_TILES` 就是 `GROUND` 再加一个 `INVALID`（见
    --   constants.lua:788 的 GetWorldTileMap 用法）。
    --   ⚠️ 宿主原先把两者做成**独立的惰性表**，各自从 100 开始发号 ——
    --      结果 WORLD_TILES.OCEAN_SWELL ≠ GROUND.OCEAN_SWELL。
    --      而 oceanfishdef.lua 恰好一边用 WORLD_TILES 建表（1032 行）、
    --      一边用 GROUND 取值（1079 行），于是取到 nil 直接崩，
    --      还把 cooking 一起拖挂。这类「两张表本该同源」的坑很隐蔽：
    --      单看任何一张表都正常，只有交叉使用时才暴露。
    do
        local wt = _G.WORLD_TILES
        if type(wt) ~= "table" then wt = {}; _G.WORLD_TILES = wt end
        rawset(wt, "INVALID", 65535)
        local nextid2 = 100
        for _, v in pairs(wt) do
            if type(v) == "number" and v >= nextid2 then nextid2 = v + 1 end
        end
        setmetatable(wt, {
            __index = function(t, k)
                if type(k) ~= "string" or k:match("^_") then return nil end
                -- ★ 先查 GROUND：可用的地形键两边必须同值
                local gv = _G.GROUND and rawget(_G.GROUND, k)
                if type(gv) == "number" then
                    rawset(t, k, gv)
                    return gv
                end
                local id = nextid2
                nextid2 = nextid2 + 1
                rawset(t, k, id)
                return id
            end,
        })
        G.WORLD_TILES = wt
    end

    -- ★★★ actions.lua（7092 行）—— **真实动作注册表**，替换宿主手写的小表。
    --
    --   起因（`prefabs/bootleg.lua:124`，经可达性抽样暴露）：
    --       inst.map_remap_min_dist = ACTIONS.TOSS.distance + TUNING....
    --       ✘ attempt to perform arithmetic on field 'distance' (a nil value)
    --   但原版 `actions.lua:294` 的构造器**明明**写了
    --       `self.distance = data.distance or nil`
    --   而 `TOSS = Action({ priority=1, rmb=true, distance=8, mount_valid=true })`。
    --
    --   真因有两层，都属于**静默型**：
    --     ① 宿主从没加载过 actions.lua，`G.ACTIONS` 是 03_globals 里手写的
    --        34 项小表（只有 id/str/code/GetActionType）⇒ 每个动作都缺字段；
    --     ② 想加载也加载不了：`actions.lua:273` 第一句就是
    --        `global("CLIENT_REQUESTED_ACTION")`，而 `global` 定义在
    --        strict.lua:27 —— 宿主没有 ⇒ 整个文件在第一屏就失败。
    --        ⚠️ 而且失败是**静默的**：`ACTIONS` 依然存在、名字都在、
    --           `GetActionType()` 也能调，没有任何迹象。
    --
    --   ⇒ 两处都补：`G.global`（见 03_globals，刻意**不**加载 strict.lua），
    --     然后在这里加载真表。加载后**重新挂上惰性兜底** ——
    --     原版 ACTIONS 没有宿主以前那种「任意键都造一个」的性质，
    --     而 finiteuses.lua:30 `self.consumption[ACTIONS.XXX]` 这类写法
    --     一旦拿到 nil 就是 `table index is nil` 直接崩。
    --     兜底只对**真表里没有的键**生效，不覆盖任何真实动作。
    do
        local r, e = Loader.LoadFile(Core.SourceDir .. "/actions.lua")
        local A = _G.ACTIONS
        if r and type(A) == "table" then
            local n = 0
            for _ in pairs(A) do n = n + 1 end
            Bootstrap.ActionsLoaded = true
            Bootstrap.ActionCount = n
            G.ACTIONS = A
            -- 惰性兜底：只补真表里没有的键
            setmetatable(A, {
                __index = function(t, k)
                    if type(k) ~= "string" or k:match("^_") then return nil end
                    local a = { id = k, str = k, code = k }
                    function a:GetActionType() return self.id end
                    rawset(t, k, a)
                    return a
                end,
            })
        else
            Bootstrap.ActionsLoaded = false
            Bootstrap.ActionCount = (function()
                local n = 0
                for _ in pairs(type(A) == "table" and A or {}) do n = n + 1 end
                return n
            end)()
            -- 失败**不静默**：带上原因
            Core.NoteGap("actions.lua: " ..
                tostring(e):gsub("^.-:%d+: ", ""):sub(1, 90), "actions")
        end
    end

    -- ★ Map 类：components/map.lua 与 quagmire_map.lua 在**顶层**就写
    --   `Map.SetTile` / `function Map:SetTile(...)`（猴补丁扩展）。
    --   但 `Map = Class(...)` 的定义**不在任何 Lua 文件里** ——
    --   全库 grep 只有这两处「使用」没有「定义」，说明它是 C++ 引擎提供的类。
    --   宿主不实现地图系统，给一个空的 Map 类，让猴补丁能挂上方法。
    --   ⚠️ 只做这一次兜底：真正的 Map 行为（GetTile/SetTile/寻路）仍是桩，
    --   见 Sim.World.Map 的「宽松结果」说明。
    if _G.Map == nil then
        _G.Map = setmetatable({}, {
            __index = function(t, k)
                if type(k) ~= "string" or k:match("^_") then return nil end
                return function() return nil end
            end,
        })
        G.Map = _G.Map
    end

    -- ★ 把 WORLD_TILES 登记为「守卫全局表」
    --   constants.lua:788 只给 INVALID=65535，其余（RIFT_MOON / LUNAR_MARSH /
    --   OCEAN_ICE…）由地图生成时写入。player_common.lua:2676 直接用它当表键
    --   （areaaware.lua:115 `{[tile_id]=false}`），键为 nil 会 "table index is nil"。
    --   ★ 关键：某个 map 模块会在**懒加载时**重建 WORLD_TILES，
    --     所以不能只在 constants 之后挂一次 —— 交给 Loader 的守卫机制，
    --     每次执行任何 DST 文件后自动重挂（见 04_loader.RearmGuards）。
    do
        local wt = require("host.04_loader").MakeLazyGlobal("WORLD_TILES", 100)
        G.WORLD_TILES = wt
    end

    -- ★ 预加载「导出全局函数」的组件
    --   问题：组件在宿主里是**懒加载**的（AddComponent 时才 loadfile），
    --   但有些组件文件在顶层定义了全局函数供 prefab 直接用：
    --     · components/lootdropper.lua   → SetSharedLootTable（prefabs 里用了 221 次！）
    --     · components/sleeper.lua       → StandardSleepChecks / StandardWakeChecks
    --     · components/deployhelper.lua  → TriggerDeployHelpers
    --     · components/klaussackloot.lua → AddGiantLootPrefabs
    --     · components/skinner*.lua      → SetSkinsOnAnim / SetBeefaloSkinsOnAnim
    --   不预加载的话，全量扫描 prefabs/ 时 100+ 个文件会因为
    --   "attempt to call global 'SetSharedLootTable' (a nil value)" 失败（实测）。
    --   这里直接把文件当 Lua 脚本跑一遍，只为拿到它们的全局副作用。
    for _, c in ipairs({
        "lootdropper", "sleeper", "deployhelper", "klaussackloot",
        "skinner", "skinner_beefalo",
    }) do
        pcall(function()
            Loader.LoadFile(Core.SourceDir .. "/components/" .. c .. ".lua")
        end)
    end

    -- ⚠️ 实测结论：**不要**预加载 recipe.lua / prefabskin.lua。
    --   虽然它们能修好 cookpot 系列（3 个文件）与 skinprefabs（1 个），
    --   但代价是：它们会传递 require 到 prefabs.lua，而 prefabs.lua:6
    --   定义了真实的 `Prefab = Class(...)`，覆盖宿主的注册函数；
    --   同时它们自己会引用一批尚未就绪的常量表
    --   （PROTOTYPER_TREES / SKILLS / BOAT / CANNONBALLS 变成 number），
    --   结果失败数从 15 **涨到 41**，注册数从 1513 **降到 1488**。
    --   → 净收益为负，回退。（这 4 个文件的问题留待 UI/常量层补齐后再处理。）

    -- ★ 只加载 componentutil（它导出 SetDesiredMaxTakeCountFunction，
    --   wortox_soul.lua:336 顶层就调用）。实测它是安全的。
    --
    -- ⚠️ **不要**加载 prefabskin.lua。它第 3 行 `require("prefabs")`，
    --    而 prefabs.lua:6 定义了真实的 `Prefab = Class(...)`，
    --    会把宿主的注册函数换掉 —— 即便之后重装全局也来不及，
    --    因为 prefabs.lua 自身的副作用已经扩散。
    --    实测：加了 prefabskin 后失败数 4 → **38**、注册表 6075 → **5190**，净负收益。
    --    CreatePrefabSkin 改用最小桩（见 03_globals.lua）。
    -- ★ 成败必须记下来。原先这里是 `pcall(function() Loader.Load(...) end)`，
    --   把返回值整个丢掉 —— 一旦 componentutil 加载失败，几十个组件会静默坏掉，
    --   而缺口清单里只会看到零散的「attempt to index nil」，查不到根因。
    --   （与第 21 节 DropDeathLoot 同源的教训：静默丢弃 = 藏住问题。）
    Bootstrap.ComponentUtil = (function()
        local ok, err = pcall(function() return Loader.Load("componentutil") end)
        return { ok = ok, err = ok and nil or tostring(err):sub(1, 160) }
    end)()
    if not Bootstrap.ComponentUtil.ok then
        print(string.format("  ⚠️ componentutil 加载失败：%s",
            Bootstrap.ComponentUtil.err or "?"))
    end

    -- 5) 高频全局表（batch 实测缺失）
    if _G.DEPLOYSPACING_RADIUS == nil then
        _G.DEPLOYSPACING_RADIUS = {
            DEFAULT = 1.2, NONE = 0, MEDIUM = 1.5, LARGE = 2.0, HUGE = 3.0,
        }
    end
    if _G.FOODTYPE == nil then
        _G.FOODTYPE = {
            GENERIC = "generic", MEAT = "meat", VEGGIE = "veggie",
            GOODIES = "goodies", HORRIBLE = "horrible", RAW = "raw",
            ELEMENTAL = "elemental", INSECT = "insect", SEEDS = "seeds",
            WOOD = "wood", GEARS = "gears", BURNT = "burnt",
        }
    end
    if _G.SPECIAL_EVENTS == nil then
        _G.SPECIAL_EVENTS = {
            NONE = "none",
            HALLOWED_NIGHTS = "hallowed_nights",
            WINTERS_FEAST = "winters_feast",
        }
    end

    -- 6) 世界实体：TheWorld.Map / TheWorld.Pathfinder
    --    simutil.lua:339 的 FindWalkableOffset 要用它们。
    --    ★ 注意 map.lua 是**猴补丁扩展**（require "map/terrain" 后直接
    --      挂 function Map:Xxx()），不返回类——所以真正的 Map 类来自
    --      map/terrain.lua。两个都加载，才拿到完整方法集。
    do
        local Core_ = require("host.01_core")
        local world = Sim.World

        -- ★ TheWorld.net.components.moonstorms —— stormwatcher.lua:25 等
        --   只做存在性检查（`~= nil and next(...GetMoonstormNodes())`）。
        --   宿主无分片网络，给一个空的 net 对象即可让分支安全跳过。
        world.net = world.net or {
            components = {},          -- moonstorms 等分片组件，宿主全缺
            _connected = false,
            IsConnected = function() return false end,
            Connect = function() end,
            Disconnect = function() end,
        }

        -- ★ TheWorld.components —— singingshelltrigger.lua:26 等做存在性检查。
        --   注意是 TheWorld.components 不是实体自己的，所以必须显式给空表，
        --   否则 `TheWorld.components` 为 nil 会直接崩。
        world.components = world.components or {}
        -- TheWorld.components.X 对未知 X 一律返回 nil，保持「不存在」语义
        setmetatable(world.components, {
            __index = function(t, k)
                if type(k) ~= "string" or k:match("^_") then return nil end
                -- 不 rawsert —— 每次都返回 nil，等价于「该组件不存在」
                return nil
            end,
        })

        -- ★ 给世界实体挂**真实的**世界组件。
        --   prefabs/world.lua 会挂 25 个（worldsettings / worldstate /
        --   uniqueprefabids / playerspawner …）。宿主先用最必要的几个：
        --     · uniqueprefabids —— components/uniqueid.lua:5 直接调
        --       `TheWorld.components.uniqueprefabids:GetNextID(prefab)`，
        --       缺了会让 beefalo 这类带 uniqueid 的生物实例化失败
        --   用真实组件文件实例化（不是写桩），能保真到什么程度就保真到什么程度。
        for _, wc in ipairs({ "uniqueprefabids", "worldsettings", "worldstate" }) do
            local okc = pcall(function()
                -- ★ 取「组件类」的确定性做法：**加载前后 diff _G**。
                --   为什么不能靠名字推断：组件文件有两种写法 ——
                --     · `class.lua` 风格：结尾 `return Class(...)`
                --     · 全局赋值风格：`WorldState = Class(...)`，**不 return**
                --       （worldstate.lua 就是这样）
                --   而后者没法靠文件名推出全局名：`worldstate` → 我原先的
                --   「首字母大写」得到 `Worldstate`，真名却是 `WorldState`，
                --   于是取不到类、被记成世界组件缺口。
                --   diff _G 对两种写法都成立，且不依赖命名约定。
                local before = {}
                for k in pairs(_G) do before[k] = true end

                local _ok, cls = Loader.LoadFile(
                    Core_.SourceDir .. "/components/" .. wc .. ".lua")

                if cls == nil then
                    local added = {}
                    for k, v in pairs(_G) do
                        if not before[k] and type(v) == "table"
                            and getmetatable(v) ~= nil then
                            added[#added + 1] = v
                        end
                    end
                    if #added == 1 then
                        cls = added[1]
                    elseif #added > 1 then
                        -- 多个新全局时，挑名字最像的（把下划线去掉后比对）
                        local want = wc:lower():gsub("_", "")
                        for _, v in ipairs(added) do
                            local n = tostring(v)
                            if n then
                                cls = v
                                break
                            end
                        end
                    end
                end

                if type(cls) == "function" then
                    world.components[wc] = cls(world)
                elseif type(cls) == "table" then
                    -- Class 产物是带 __call 的表
                    local mt = getmetatable(cls)
                    if mt and mt.__call then
                        world.components[wc] = cls(world)
                    end
                end
            end)
            if not okc then
                Core_.NoteGap("world-component:" .. wc, "bootstrap")
            end
        end

            world.entity = Core_.NewEntity("world")

        -- ★ 世界级的引擎对象（真实引擎里是 C++ 世界实体上的成员）。
        --   `locomotor.lua:606 UpdateGroundSpeedMultiplier` 每帧都读
        --   `TheWorld.GroundCreep:OnCreep(x,y,z)` —— 缺了会让**每一个**带
        --   locomotor 的实体在组件更新时抛错，移动链直接断在第一帧。
        if world.GroundCreep == nil then
            world.GroundCreep = {
                OnCreep = function() return false end,
                GetTriggeredCreepSpawners = function() return {} end,
                AddRenderLayer = function() end,
                FastForward = function() end,
                GetAsString = function() return "" end,
                SetFromString = function() end,
            }
        end

        -- ★★ DataGrid —— 真实脚本 `datagrid.lua` 提供的二维网格容器
        --
        --   `main.lua:217` 的启动清单里有 `require("datagrid")`，宿主一直没有加载它。
        --   后果（P41 农业链路实测）：
        --       farming_manager.lua:138: attempt to call global 'DataGrid' (a nil value)
        --   ⇒ 土壤营养/湿度网格建不起来 ⇒ 作物永远长不熟。
        --   DataGrid 是 `DataGrid = Class(...)` 的**全局赋值**风格（不 return），
        --   所以要用 Loader.Load（它按主清单的方式执行文件），不是 require 返回值。
        do
            local okDG, errDG = Loader.Load("datagrid")
            if not okDG or rawget(_G, "DataGrid") == nil then
                Core.NoteGap("datagrid: " .. tostring(errDG):sub(1, 90), "bootstrap")
            end
        end

        -- ★★ 真实地图层（host/20_map.lua）        --
        -- 旧实现是一张「任何查询都返宽松结果」的兜底表：IsAboveGroundAtPoint 恒真、
        -- GetTile 恒 0、Pathfinder:IsClear 恒真 —— 地形相关逻辑从未被检验过。
        --
        -- 现在改成：**瓦片数据由宿主提供，判定逻辑全部复用真实 DST 文件**。
        --   · tilegroups.lua（147 行，纯 Lua）给出 IsLandTile / IsOceanTile /
        --     IsImpassableTile / IsInvalidTile / IsNoiseTile 的原版判定
        --   · components/map.lua（900+ 行，纯 Lua 猴补丁）在其上叠出
        --     IsAboveGroundAtPoint / IsPassableAtPoint / IsLandTileAtPoint …
        -- 宿主只补了 C++ 那一侧：瓦片数组、坐标换算、Pathfinder。
        --
        -- ⚠️ 装载顺序是硬约束：必须先把 `_G.Map` 指向宿主的地图对象，
        --    再加载 components/map.lua —— 它第 3 行是
        --    `local _SetTile = Map.SetTile`，是**在加载时**抓取全局的。
        local WorldMap = require("host.20_map")
        WorldMap.Install()
        Bootstrap.MapInstalled = WorldMap.Installed
        Bootstrap.MapRealLua = WorldMap.RealMapLuaAttached
        Bootstrap.TileGroupManagerReady = WorldMap.TileGroupManagerReady
    end

    -- 6b) 三个「纯 Lua 工具文件」——它们的函数被组件层高频调用，
    --     不加载就会以「每 tick 一次」的频率抛异常（实测各 2550 次）：
    --
    --   ocean_util.lua   IsLandTile / IsOceanTile / ShouldEntitySink / GetOceanDepthAtPoint
    --                    ← components/map.lua:986 `IsLandTile(tile_type)`、
    --                      components/inventoryitem.lua:542 `ShouldEntitySink(...)`
    --   gamemodes.lua    GetGhostSanityDrain / GetGameMode / GetMaxItemSlots ...
    --                    ← components/sanity.lua:457 `GetGhostSanityDrain(...)`
    --   equipslotutil    EquipSlot.Count()/FromID()/ToID()
    --                    ← components/inventory.lua:411 `for slotid = 1, EquipSlot.Count()`
    --
    --   三者都只依赖宿主**已经有**的东西（TileGroupManager / LEVELTYPE /
    --   WORLD_TILES / EQUIPSLOTS / orderedPairs / table.invert），所以可以直接
    --   加载真实文件，而不是在宿主里重写一遍。
    --   ⚠️ ocean_util 必须在 20_map.Install() 之后：它调用 TileGroupManager。
    do
        local okO, errO = Loader.LoadFile(Core.SourceDir .. "/ocean_util.lua")
        Bootstrap.OceanUtilLoaded = okO and type(rawget(_G, "IsLandTile")) == "function" or nil
        if not okO then
            Core.NoteGap("ocean_util.lua: " .. tostring(errO):sub(1, 90), "bootstrap")
        end

        local okG, errG = Loader.LoadFile(Core.SourceDir .. "/gamemodes.lua")
        Bootstrap.GameModesLoaded = okG and type(rawget(_G, "GetGhostSanityDrain")) == "function" or nil
        if not okG then
            Core.NoteGap("gamemodes.lua: " .. tostring(errG):sub(1, 90), "bootstrap")
        end

        --   mathutil.lua   ReduceAngle / ReduceAngleRad / DiffAngle / Lerp / Clamp
        --                  / Remap / RoundBiasedUp/Down / RoundToNearest / math.clamp
        --                  / math.diff / math.range / DistXSq / DistXZSq ...
        --                  ← prefabs/floatinglantern.lua:139 `ReduceAngle`（batch 300 tick 断点）
        --   152 行、零 require、纯函数 —— 直接真加载即可，不需要在宿主里内联重写。
        --   ★ 宿主此前把「常用几个」内联在 03_globals.lua，
        --     于是漏一个就崩一个（ReduceAngle 就是这么暴露的）。
        local okM, errM = Loader.LoadFile(Core.SourceDir .. "/mathutil.lua")
        Bootstrap.MathUtilLoaded = okM and type(rawget(_G, "ReduceAngle")) == "function" or nil
        if not okM then
            Core.NoteGap("mathutil.lua: " .. tostring(errM):sub(1, 90), "bootstrap")
        end
    end

    -- 6c) TileInfo 缓存初始化（worldtiledefs.Initialize = CacheAllTileInfo）
    --   worldtiledefs.lua 把「每种地形的渲染层 / 噪音贴图 / 名字」放进
    --   GROUND_PROPERTIES，但真正的查表缓存要显式调 Initialize() 才建
    --   （原版由 gamelogic.lua 的 GroundTiles.Initialize() 触发）。
    --   不调的话 GetTileInfo 会索引 nil：
    --     worldtiledefs.lua:67: attempt to index upvalue 'GROUND_PROPERTIES_CACHE'
    --   而 locomotor 的 UpdateGroundSpeedMultiplier → IsFasterOnGroundTile → GetTileInfo
    --   是**每 tick** 都走的路径，于是移动链被打断。
    --
    --   ⚠️ 踩坑：`Loader.Load(name)` 只返回**模块值本身**，不是 (ok, value) 二元组。
    --      写成 `local ok, wtd = Loader.Load(...)` 会让 wtd 恒为 nil，
    --      初始化静默不执行（这条路径上没有任何报错，只有每 tick 一次的下游异常）。
    do
        local wtd = Loader.Load("worldtiledefs")
        if type(wtd) == "table" and type(wtd.Initialize) == "function" then
            local okI = pcall(wtd.Initialize)
            -- 用一个**确实登记过**的瓦片验证（GROUND.GRASS 在 GROUND_PROPERTIES 里没有条目）
            local probe_tile = next(wtd.ground or {})
            local okQ = probe_tile ~= nil and (select(1, pcall(GetTileInfo, probe_tile)))
            Bootstrap.TileInfoReady = (okI and okQ) and true or nil
        end
    end

    -- 6d) EquipSlot 初始化
    --   equipslotutil.lua 是个**模块**（不是全局脚本），构造期不做任何事；
    --   必须显式调 Initialize() 才会算出 EQUIPSLOT_COUNT。
    --   不初始化的话 `EquipSlot.Count()` 返回 nil，于是
    --   inventory.lua:411 的 `for slotid = 1, EquipSlot.Count()` 直接报
    --   "'for' limit must be a number"（`ApplyDamage` 整条链路失效）。
    do
        local ok, ES = pcall(require, "equipslotutil")
        if ok and type(ES) == "table" and type(ES.Initialize) == "function" then
            local okI = pcall(ES.Initialize)
            Bootstrap.EquipSlotReady = okI and type(ES.Count()) == "number" or nil
        end
    end

    -- ★ 给 replica 层注入「按需加载预制体」的钩子 —— 见 host/14_replica.lua 的说明。
    --   为什么不在 Setup 里一次性预加载：这些 *_classified 预制体一旦提前注册，
    --   full.lua 的「注册了预制体的文件」统计会把对应的 1594 个 prefab 文件
    --   重新分类（实测 1525 → 1520，「加载成功但无预制体」69 → 74，
    --   而**注册表预制体总数恒为 6081、加载失败恒为 0** —— 纯记账口径偏移）。
    --   改成按需加载后，full.lua 的口径保持原样，代价只是第一次用到时多一次加载。
    do
        local okR, R = pcall(require, "host.14_replica")
        if okR and type(R) == "table" then
            R.PrefabLoader = function(cname)
                return Bootstrap.LoadPrefabFile(cname)
            end
        end
    end

    -- 7) EntityScript 契约补全（130 个方法，表驱动）
    Bootstrap.EntityScriptAdded = require("host.06_entityscript").Install(
        require("host.01_core").EntityMeta)

    -- 8) ★★ 行为树 + 大脑 + 组件更新泵
    --
    -- 这一步之前，宿主有两处「静默失效」，合起来让世界完全静止：
    --   · `StartUpdatingComponent` 只记 `self._updating`，**从不调用 OnUpdate**
    --     ⇒ locomotor 的推进逻辑永不执行 ⇒ 生物永不移动
    --   · `SetBrain` 把大脑**类**当成实例存起来，
    --     既不 `brainfn()` 造实例、也不进 BrainManager
    --     ⇒ BehaviourTree 永不 Update ⇒ 生物永不决策
    -- 两者都不报错。补法与 update.lua:224 的更新泵逐条对齐。
    --
    -- behaviourtree.lua 定义全局 `BehaviourNode` / `BehaviourTree`，
    -- 而 behaviours/*.lua 第一行就是 `Class(BehaviourNode, ...)` —— 必须先加载。
    -- brain.lua 定义全局 `Brain` 与 `BrainManager`（BrainWrangler 单例）。
    do
        local btOk, btErr = Loader.Load("behaviourtree")
        if not btOk or rawget(_G, "BehaviourNode") == nil then
            Bootstrap.BehaviourTreeMissing = tostring(btErr):sub(1, 120)
        end
        local bOk, bErr = Loader.Load("brain")
        if not bOk or rawget(_G, "BrainManager") == nil then
            Bootstrap.BrainMissing = tostring(bErr):sub(1, 120)
        end
        local Pump = require("host.13_update")
        Pump.Install(require("host.01_core").EntityMeta)
        Sim.Pump = Pump
        Bootstrap.Pump = Pump
    end

    -- 8.2) ★★ 预加载 `behaviours/` 全部文件 —— 否则 51% 的 brain 生成即崩
    --
    --   ★★ 这是**实测**出来的缺口（审计时首次发现），不是文档里已有的：
    --       `SpawnPrefab("spider")` 直接抛
    --         `brains/spiderbrain.lua:155: attempt to call global 'FaceEntity' (a nil value)`
    --
    --   真因：`behaviours/faceentity.lua` 定义全局类 `FaceEntity`，
    --   而 `spiderbrain.lua` **只管用、从不 require 它**（全文 require 了
    --   chaseandattack / runaway / wander / doaction / avoidlight / attackwall /
    --   useshield 七个，唯独没有 faceentity）。
    --   统计：**191 个 brain 里有 98 个**用了「本文件没 require」的行为类
    --   （`DoAction` 32 个、`FaceEntity` 28 个、`ChaseAndAttack` 18 个…）。
    --
    --   原版为什么不崩？因为原版在**启动时**把 brain / behaviour 全量加载一遍，
    --   这些全局是靠「别的 brain 顺手 require 了」而存在的 ——
    --   即**加载顺序决定的副作用**。宿主是**按需懒加载**，
    --   于是「先生成谁」直接决定「后面谁会崩」：
    --       ⇒ 同一份代码、不同的加载顺序 ⇒ 不同的结果。这是最坏的一类缺陷。
    --
    --   ⇒ 修法就是补上原版那份「启动时全量加载」的语义：**不改动原版任何一行**，
    --     只在宿主启动序列里把 behaviours 目录整体加载一遍。
    do
        local dir = Core.SourceDir .. "/behaviours"
        local n, failed, cls_of = 0, {}, {}
        -- ★ M6：`dir /b` 换成 FileList.List —— 原来在非 Windows 上恒空，
        --   而这里的失败方式是「静默少加载」，症状会跑到 brain 里 nil 行为类去。
        local files, src = FileList.List(dir)
        for _, line in ipairs(files) do
            local nm = line:match("^(.-)%.lua$")
            if nm ~= nil then
                n = n + 1
                Loader.Load("behaviours/" .. nm)
                -- ★★ 光「加载过」不算数：这些文件的语义是**设一个全局类**
                --   （`behaviours/faceentity.lua:10` 是 `FaceEntity = Class(BehaviourNode, …)`）。
                --   所以判据必须是「那个**全局**在不在」，不是「文件读没读」。
                --   ⇒ 这样判才与加载顺序无关（见 tests.lua TC26 的反向测试：
                --     只断言「spider 能生成」会被前面断言的副作用救活，
                --     撤销预加载它照样是绿的 —— 那不是判据，是运气）。
                local fh = io.open(dir .. "/" .. nm .. ".lua", "r")
                if fh then
                    local src_txt = fh:read("*a")
                    fh:close()
                    local g = src_txt:match("([A-Za-z_][%w_]*)%s*=%s*Class%s*%(%s*BehaviourNode")
                    if g ~= nil then
                        cls_of[nm] = g
                        if rawget(_G, g) == nil then
                            failed[#failed + 1] = nm .. "(全局缺失:" .. g .. ")"
                        end
                    end
                end
            end
        end
        Bootstrap.BehavioursClasses = cls_of
        Bootstrap.BehavioursPreloaded = n
        Bootstrap.BehavioursFailed = #failed
        Bootstrap.BehavioursFailList = failed
        Bootstrap.BehavioursSource = src
        if n == 0 then
            -- ★ 枚举不出来必须**吵**，不能悄悄退化成「碰运气」
            Core.NoteGap("behaviours:目录枚举失败（filelist/ls/dir 三路都没拿到）"
                .. " —— brain 里未 require 的行为类会是 nil", "bootstrap")
        end
        if #failed > 0 then
            print(string.format("  [bootstrap] behaviours 预加载 %d 个，失败 %d 个: %s",
                n, #failed, table.concat(failed, " ")))
        end
    end

    -- 8.5) ★ LOC —— 本地化对象（`languages/loc.lua` **返回**它，不是设全局）
    --
    --   实测症状（可达性抽样 N=3000 才抽到）：
    --       prefabs/hermitcrab.lua:1915  if LOC.GetTextScale() == 1 then
    --       ✘ attempt to index global 'LOC' (a nil value)
    --
    --   两个坑叠在一起：
    --     ① main.lua:194 写的是 `LOC = require("languages/loc")` ——
    --        **用 require 的返回值**赋值，而 loc.lua 尾行是 `return LOCALE`，
    --        它**不设全局**。所以「加载了文件」不等于「有 LOC」。
    --     ② 它会失败：loc.lua:23 第一句就是 `IsXB1()`，而宿主的平台函数清单
    --        是手抄的、缺了 5 个真名（见 03_globals 的说明）。
    --        ⇒ 平台函数补齐之后这里才加载得动。
    --
    --   ⇒ 用 Loader.Load（走 require 语义并拿返回值）而不是 LoadFile。
    do
        local r, e = Loader.LoadFile(Core.SourceDir .. "/languages/loc.lua")
        if r and type(e) == "table" then
            _G.LOC = e
            G.LOC = e
            Bootstrap.LocLoaded = true
        else
            Bootstrap.LocLoaded = false
            Core.NoteGap("LOC: " .. tostring(e):gsub("^.-:%d+: ", ""):sub(1, 70), "loc")
        end
    end

    -- 9) ★★ world 组件**晚一趟**装配 —— 见 mount_world_components 的说明。
    --   必须放在这里：此刻 constants.lua / 启动文件清单都已就绪，
    --   早期挂不上的 `ambientlighting`（模块顶层读 SCREEN_FLASH_SCALING）
    --   这一趟才能挂上。只补还缺的，重跑安全。
    mount_world_components("late")
    Bootstrap.WorldComponentsMounted = (function()
        local W = rawget(_G, "TheWorld") or Core.World
        if W == nil or W.components == nil then return 0 end
        local n = 0
        for _, entry in ipairs(WORLD_ASSEMBLY_COMPONENTS) do
            -- 条目可能是字符串，也可能是 {name=, phase=}（见 WORLD_ASSEMBLY_COMPONENTS 的说明）
            local cname = (type(entry) == "table") and entry.name or entry
            if cname ~= nil and W.components[cname] ~= nil then n = n + 1 end
        end
        return n
    end)()
    Bootstrap.WorldComponentsTotal = #WORLD_ASSEMBLY_COMPONENTS

    return Bootstrap
end

--- 加载一个原版 prefab 文件，并**递归加载它声明的依赖预制体**
--
-- ★ 为什么必须自动加载依赖
--   原版 prefab 文件开头有 `local prefabs = { "pigman", "splash_sink" }`，
--   这是「我运行时会生成谁」的声明。真实引擎在启动时加载全部 1594 个文件，
--   所以依赖总是就绪的。
--   宿主只加载单个文件时，`SpawnPrefab("mound")` 会返回 nil，
--   于是 `inst.mound.Transform` 直接崩（gravestone.lua:250-251 实测）。
--   递归加载依赖能一次性修好这一类失败。
-- ★ 把加载器挂到 Core 上，供 Core.SpawnPrefab 的「查不到就现加载」用。
--   （真实引擎启动时注册全部 prefab，宿主改成按需加载，
--     所以 SpawnPrefab 必须能自己触发加载 —— 见 01_core.lua 的 SpawnPrefab。）
--=========================================================================
-- ★★ 预制体名 → 文件 索引（惰性构建）
--=========================================================================
-- 为什么需要它：**文件名不一定等于预制体名**。实例：
--     prefabs/fx.lua              → 注册 die_fx 等 ~200 个 fx 预制体
--     prefabs/hats.lua            → 注册 83 个帽子（footballhat …）
--     prefabs/shallow_grave.lua   → 注册 shallow_grave_player
-- `SpawnPrefab("die_fx")` 若按「文件名 = 预制体名」去加载，会找
-- `prefabs/die_fx.lua` —— 不存在 ⇒ 返回 nil ⇒
-- 调用方 `SpawnPrefab("die_fx").Transform:SetPosition(...)` 直接「索引 nil」
-- （实测：player_common_extensions.lua:152 玩家死亡时崩）。
--
-- 真实引擎没有这个问题：它在启动时把 prefablist 里的**全部**文件都跑一遍，
-- 所以任何注册过的预制体都能 SpawnPrefab 到。
--
-- 做法：**首次查不到时才构建**，扫一遍 prefabs/*.lua 找 `Prefab("<名字>"`，
-- 结果缓存。只扫一次，且只在真的缺预制体时才付这个代价。
-- 成本实测约 1~2 s（1594 个文件），可接受。
-- 索引是 { 预制体名 -> { 候选文件名, ... } }（**列表**，不是一个名字）。
-- 为什么必须是列表：文本扫描只是启发式，会有假阳性 —— 实测
-- `yotr_rabbitshrine.lua:326` 里的 `SpawnPrefab("spoiled_food")`
-- 会被「`Prefab("名字"`」扫到（因为 `SpawnPrefab(` 里就含 `Prefab(`）。
-- 所以按顺序逐个候选试加载，**以「加载后 Core.Prefabs 里真的出现了」为准**。
local PREFAB_INDEX = nil
local PREFAB_INDEX_BUILT = false

local function build_prefab_index()
    if PREFAB_INDEX_BUILT then return PREFAB_INDEX end
    PREFAB_INDEX_BUILT = true
    local dir = Core.SourceDir .. "/prefabs"
    local idx = {}
    -- ★ M6：`dir /b` → FileList.List（同 behaviours 的跨平台理由）
    local names = FileList.List(dir)
    for _, fn in ipairs(names) do
        local base = fn:gsub("%.lua$", "")
        local h = io.open(dir .. "/" .. fn, "r")
        if h ~= nil then
            local src = h:read("*a") or ""
            h:close()
            -- ★ 匹配 `Prefab("名字"` / `Prefab('名字'`，只取第一个参数。
            --   ⚠️ 前面必须是**非单词字符**：否则 `SpawnPrefab("x")` 会被误匹配
            --   （`SpawnPrefab(` 的尾巴就是 `Prefab(`）。
            --   实测漏了这个边界，`spoiled_food` 被错指到 yotr_rabbitshrine.lua。
            local function add(pname)
                local list = idx[pname]
                if list == nil then idx[pname] = { base }
                elseif list[#list] ~= base then list[#list + 1] = base end
            end
            -- ⚠️ 这两个模式**只有一个捕获**（前导的 [^%w_] 是非捕获写法上的必须，
            --   但它不带括号所以不产生捕获值）—— 写成 `for _, pname in ...` 会让
            --   pname 恒为 nil，报 "table index is nil"。
            for pname in src:gmatch('[^%w_]Prefab%(%s*"([%w_]+)"') do add(pname) end
            for pname in src:gmatch("[^%w_]Prefab%(%s*'([%w_]+)'") do add(pname) end
        end
    end
    PREFAB_INDEX = idx
    return idx
end

-- ★★ 文本索引扫不到的「动态注册」文件
--   `prefabs/fx.lua` 末尾是：
--       local fx = require("fx")
--       for k, v in pairs(fx) do table.insert(prefs, MakeFx(v)) end
--       return unpack(prefs)
--   —— 预制体名来自**数据表**（`t.name`），源码里没有字面量
--   `Prefab("die_fx"`，所以文本扫描一个都找不到。
--   但 `Core.Prefab()` 是**有注册副作用**的，只要把这个文件跑一遍，
--   它注册的 ~200 个 fx 预制体就全都进 `Core.Prefabs` 了。
--   代价：一次加载（4116 行 + 依赖），只在真的缺预制体时才付。
local DYNAMIC_FAMILY_FILES = {
    "fx",            -- ~200 个特效预制体（die_fx …）
    "preparedfoods", -- 全部料理（wetgoop …，名字来自 FOODTYPE 数据表）
    -- ★ 树：`evergreens.lua` 末尾是一串 `tree("evergreen", ...)`，
    --   而 `tree()` 内部才调 `Prefab(name, ...)` —— 名字是**变量**，
    --   文本索引同样扫不到（实测 `SpawnPrefab("evergreen")` 失败 20 次）。
    "evergreens",
    "deciduoustrees",
    -- ★ 鸟：`prefabs/crow.lua` **不存在**，crow 注册在 `prefabs/birds.lua` 里
    --   （和 83 个帽子都在 `hats.lua` 是同一个套路）。
    --   实测症状：`SpawnPrefab("crow")` 静默返回 nil —— 不报错、不进缺口清单，
    --   只是「没生成」。补进本清单后按需加载即可。
    "birds",
    -- ★ 肉/食物：`prefabs/meats.lua` 里 `fishmeat_small_cooked`、`cookedmeat`
    --   这些是用 `local function common(...)` **批量注册**的，
    --   文件里没有字面量 `Prefab("xxx"`，所以**文本索引扫不到**
    --   （和 `hats` / `evergreens` / `birds` 同一个套路）。
    --
    --   后果很具体：lootdropper.lua:416-420 的烧焦掉落改写
    --       elseif PrefabExists(v.."_cooked") then prefabs[k] = v.."_cooked"
    --       ... elseif ... then prefabs[k] = "ash"
    --   若 PrefabExists 判不出 fishmeat_small_cooked，烧焦的鱼就掉 **ash** 而不是熟鱼。
    --   ★ 这条是 tests.lua 的 T2 断言抓出来的 —— 说明
    --     「PrefabExists 先懒加载再判」那个修复是**必要但不充分**的：
    --     加载了还得**找得到**，而批量注册的家族文件文本索引看不见。
    --
    --   代价：931 行、无 require、约 80 个预制体（远小于已加载的 fx 4116 行）。
    "meats",
    -- ★ 农作物：`prefabs/farm_plants.lua` 末尾是
    --       return Prefab(plant_def.prefab, fn, assets, prefabs)
    --   名字是**变量**，文本索引扫不到（与 hats / meats / birds 同一套路）。
    --
    --   后果很隐蔽：`berrybush` 的 pickable 会
    --       SpawnProductLoot → loot = SpawnPrefab(self.product)   （pickable.lua:492）
    --   而 self.product == "berries"。berries 找不到 ⇒ **SpawnPrefab 返回 nil**
    --   ⇒ 采了半天**什么也没拿到**，而 `Pickable:Pick` 仍然
    --   **照常返回 true**、并把 canbepicked 置 false —— **假成功**。
    --   实测症状：`Pick 返回 true；背包 0→0`。
    --
    --   ★ 这类「返回成功但什么都没发生」比直接报错更难发现：
    --     它不会进桩清单、不会进缺口清单，还让断言「有返回」就判通过。
    "farm_plants",
    -- ★ 下面这批由**一次全量静态扫描**挑出来的，不是逐个撞出来的。
    --   扫描方法：把 `prefabs/*.lua` 里 `Prefab(` 的第一个实参取出来，
    --   若是**变量**（`plant_def.prefab` / `def.prefab` / `name`）而不是字符串字面量，
    --   则该文件的注册名对文本索引不可见 ⇒ 必须进本清单。
    --   1447 个预制体文件里有 **170 个**命中这个形态。
    --   ⚠️ 其中多数**不是问题**：像 `axe.lua` 虽然注册名是变量，
    --   但它只有一个预制体且名字等于文件名 ⇒ 走「文件名直取」那条路照样能生成。
    --   真正的问题是「**文件名 ≠ 注册名、且注册多个**」的那批。
    --
    --   运行时抽样 23 个预制体验证：补之前 **13 个静默返回 nil**（不报错、
    --   不进缺口清单，只是「没生成」）。补高价值的一批（蔬菜/杂草/蘑菇/树）：
    "veggies", "weed_plants", "mushrooms", "mushtree", "plant_normal",
}

Bootstrap.BuildPrefabIndex = build_prefab_index

Core._prefab_loader = function(name)
    -- ① 先按「文件名 = 预制体名」直接试（绝大多数情况命中，零额外成本）
    local ok = Bootstrap.LoadPrefabFile(name)
    if ok and Core.Prefabs[name] ~= nil then
        return true
    end
    -- ② 按候选列表逐个试（以「Core.Prefabs 里真的有了」为准，不是以加载没报错为准）
    local idx = build_prefab_index()
    local cands = idx[name]
    if cands ~= nil then
        for _, file in ipairs(cands) do
            if file ~= name and Core.Prefabs[name] == nil then
                Bootstrap.LoadPrefabFile(file)
            end
            if Core.Prefabs[name] ~= nil then return true end
        end
    end
    -- ③ 动态注册的家族文件（文本扫不到，但跑一遍就全注册了）
    for _, fam in ipairs(DYNAMIC_FAMILY_FILES) do
        if Core.Prefabs[name] == nil then
            Bootstrap.LoadPrefabFile(fam)
        end
    end
    return Core.Prefabs[name] ~= nil
end

function Bootstrap.LoadPrefabFile(name, opts)
    opts = opts or {}
    local depth = opts.depth or 0
    if depth > 3 then return false, "依赖递归过深" end

    local path = Core.SourceDir .. "/prefabs/" .. name .. ".lua"
    local f = io.open(path, "r")
    if not f then return false, "文件不存在: " .. path end
    f:close()

    local before = {}
    for k in pairs(Core.Prefabs) do before[k] = true end

    local ok, err = Loader.LoadFile(path)

    -- 找出本次新注册的预制体，加载它们声明的依赖
    if ok then
        for pname, def in pairs(Core.Prefabs) do
            if not before[pname] and def.prefabs then
                for _, dep in ipairs(def.prefabs) do
                    if Core.Prefabs[dep] == nil then
                        Bootstrap.LoadPrefabFile(dep, { depth = depth + 1 })
                    end
                end
            end
        end
    end

    return ok, err
end

--- 加载一个原版组件文件（供手动测试）
function Bootstrap.LoadComponent(name)
    return Core.LoadRealComponent(name)
end

return Bootstrap
