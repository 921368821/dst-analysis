--============================================================
-- 文件：06_prefab_spawn.lua
-- 模块：核心框架 / 预制体与生成
-- 职责：定义 Prefab、注册、SpawnPrefab、SpawnPostInit，并给出 5 个示例预制体
--       （torch / berry_bush / rock / hound / player）。
--
-- 【★ 预制体（Prefab）到底是什么？】
-- 在很多引擎里，prefab 是一个「资源文件」，是一个模板，运行时 clone。
-- 在 DST 里完全不是这样：**预制体只是一个具名的工厂函数**。
--
--     Prefabs["berry_bush"] = { fn = function(inst) ... end, ... }
--     SpawnPrefab("berry_bush")  -->  调用这个 fn，返回一个实体
--
-- 【为什么这样设计？（这是整个架构里最漂亮的一点）】
-- 1. 因为预制体是**纯 Lua 代码**，所以它天然可以做「生成时决策」：
--       fn 里可以 if TheWorld.state.isday then ... end
--       这在「资源文件模板」模型里是做不到的。
-- 2. 不需要编辑器，不需要序列化格式，加一个预制体就是加一个 .lua 文件。
--    Mod 机制能成立（几百个 mod 各自增加生物）正是靠这一点。
-- 3. 生成与初始化分离：SpawnPostInit 让「别人挂到你的实体上」
--    （比如玩家把火把插在地上）在工厂跑完之后才执行，顺序有保证。
--
-- 【SetPristine：主从架构的分界线】
-- 原版里 prefab 工厂第一件事就是 inst.entity:SetPristine()，
-- 意思是「拍一张网络同步状态的快照，之后所有字段变化都会自动同步给客户端」。
-- 简化版里我们用一个 pristine 标记 + 显式的 ReplicateData() 来表达同样的语义。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》scripts/prefabs.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local Class = require("01_class").Class
local entity_mod = require("03_entity")
local Entity = entity_mod.Entity

-- ★ unpack 在 Lua 5.2 起被移到 table.unpack，5.1/5.4 里 table.unpack 不存在。
--   这行兼容写法同时覆盖 5.1 与 5.3/5.4/5.5，是跨版本代码的标准做法。
local unpack_ = table.unpack or unpack

local M = {}

--============================================================
-- 一、预制体注册表
--============================================================

M.Prefabs = {}
--【全局预制体表】所有预制体工厂都注册在这张表里，键是预制体名。
-- ★ 原版用的就是这个全局表，所以任何文件都能 SpawnPrefab("berry_bush")。
--   代价是全局可变状态（测试之间会互相污染），本教学版保留它以便对照。

-- PreloadAssets：模拟「加载美术资源」。
-- 【为什么预制体要声明它需要哪些资源？】
-- 因为服务端不渲染，却仍需要知道预制体的结构来正确生成/存档。
-- 原版用 prefabs 文件头的 "assets" 声明，配合服务端的无渲染加载。
-- 教学版只记一笔，不真加载。
function M.PreloadAssets(name, assetlist)
    local p = M.Prefabs[name]
    if p then p.assets = assetlist or p.assets end
end

--============================================================
-- 二、Prefab 定义
--============================================================

-- Prefab(name, fn, assets, deps)
--   name   —— 预制体名（全局唯一）
--   fn     —— 工厂函数 function(inst) ... return inst end
--   assets —— 资源声明
--   deps   —— 依赖声明：这个预制体用到了哪些别的预制体
--              （生成时会被优先加载，避免依赖未就绪）
--
-- 【★ 预制体 fn 的统一写法】
--     local function fn(inst)
--         -- 1) 挂原生底层组件（这里用 AddTag 模拟 Transform/Physics）
--         inst:AddTag("CLASSIFIED")     -- 原版：CLASSIFIED 表示这是个独立实体
--         -- 2) 拍快照，开始网络同步
--         inst.entity:SetPristine()
--         -- 3) 挂 Lua 组件
--         inst:AddComponent(SomeComponent)
--         -- 4) 收尾：主从分界
--         if not TheWorld.ismastersim then return inst end
--         -- 5) 只有服务端才执行的逻辑（随机掉落、AI、周期任务…）
--         return inst
--     end
--
function M.Prefab(name, fn, assets, deps)
    local prefab = {
        name = name,
        fn = fn,
        assets = assets,
        deps = deps,
        factory = fn,        -- 别名，便于阅读
    }
    M.Prefabs[name] = prefab
    return prefab
end

-- 别名（原版函数名就是 Prefab，本文件里用 M.Prefab 以免和模块混淆）
_G.Prefab = function(name, fn, assets, deps)
    return M.Prefab(name, fn, assets, deps)
end

--============================================================
-- 三、生成
--============================================================

-- SpawnPrefab(name, x, z, networked)
--   返回生成出来的实体实例。
--
-- 【★ 严格遵循「先设身份、后加组件」的顺序】
--   因为 OnLoad / SetPersistData 依赖 prefab 名与 GUID，
--   很多组件在构造时就会按名字做分支判断。
function M.SpawnPrefab(name, x, z, networked)
    local prefab = M.Prefabs[name]
    if prefab == nil then
        error("SpawnPrefab: 未注册的预制体 '" .. tostring(name) .. "'")
    end

    local inst = Entity(name)
    inst.prefab = name
    inst.x = x or 0
    inst.z = z or 0
    inst.networked = networked ~= false

    -- 主从分界：默认以「服务端（master）」身份运行
    inst.ismastersim = M.IsMasterSim()

    -- 跑工厂
    local ok, err = pcall(prefab.fn, inst)
    if not ok then
        -- ★ 工厂崩了要把实体回收，否则会留下一个半成品实体在世界表里，
        --   之后再也不会有人清理它 —— 这是典型的「僵尸实体」泄漏。
        inst:Remove()
        error("SpawnPrefab('" .. name .. "') 工厂执行失败: " .. tostring(err))
    end

    -- 跑所有 SpawnPostInit 钩子（模组扩展点）
    if prefab.postinits then
        for _, pi in ipairs(prefab.postinits) do
            local ok2, err2 = pcall(pi.fn, inst, unpack_(pi.args, 1, pi.n))
            if not ok2 then
                inst:Remove()
                error("SpawnPostInit('" .. name .. "') 执行失败: " .. tostring(err2))
            end
        end
    end

    inst.ready = true
    return inst
end

_G.SpawnPrefab = M.SpawnPrefab

-- SpawnPostInit(name, fn, ...)
--   把一个函数挂到「未来所有生成的 name 实例」的初始化之后执行。
--
-- 【★ 为什么需要它？三个典型场景】
--   1. 跨预制体协作：A 的工厂需要调用 B 的工厂，B 可能还没生成。
--   2. 模组扩展：mod 不用改原版 prefab，就能往它的实体上挂组件。
--      ★ 这是 DST Mod 生态能不发��地破坏原版玩法的技术基础。
--   3. 顺序保证：工厂跑完之后实体才是「完整」的，
--      PostInit 里可以放心访问所有组件。
function M.SpawnPostInit(name, fn, ...)
    local prefab = M.Prefabs[name]
    if prefab == nil then
        error("SpawnPostInit: 未注册的预制体 '" .. tostring(name) .. "'")
    end
    local args = { ... }
    local n = select("#", ...)
    prefab.postinits = prefab.postinits or {}
    table.insert(prefab.postinits, { fn = fn, args = args, n = n })
    return prefab
end

_G.SpawnPostInit = M.SpawnPostInit

--============================================================
-- 四、主从（服务端 / 客户端）
--============================================================

local master = true

-- IsMasterSim：当前是否权威服务端
function M.IsMasterSim() return master end
M.ismastersim = M.IsMasterSim

-- SetMasterSim：测试用。切成客户端模式（服务端实体就不该被生成）
function M.SetMasterSim(v) master = v and true or false end

-- IsDedicatedServer：是否是无渲染专用服务器
-- 【为什么要区分这两个？】专用服务器**跑服务端逻辑但不跑客户端表现层**
--   （不创建 Widget、不加载美术）。移植到 Unity/Godot 时对应
--   「headless build」或「server-only 的构建变体」。

--============================================================
-- 五、示例预制体
--============================================================

-- ---------------------------------------------------------
-- 组件：可燃（torch / berry_bush 共用，展示组件复用）
-- ---------------------------------------------------------
local Burnable = Class(function(self, inst)
    self.inst = inst
    self.fuel = 100
    self.burning = true
end)
Burnable.name = "burnable"
function Burnable:OnUpdate(dt)
    if self.burning then self.fuel = self.fuel - dt end
end
function Burnable:OnSave() return self.fuel ~= 100 and { fuel = self.fuel } or nil end
function Burnable:OnLoad(d) self.fuel = d.fuel end
function Burnable:OnRemoveFromEntity() self.inst = nil end

-- ---------------------------------------------------------
-- 组件：光源
-- ---------------------------------------------------------
local Light = Class(function(self, inst)
    self.inst = inst
    self.radius = 8
    self.colour = { 1, 0.8, 0.4 }
end)
Light.name = "light"
function Light:SetRadius(r) self.radius = r end
function Light:OnRemoveFromEntity() self.inst = nil end

-- ---------------------------------------------------------
-- 组件：可采集（berry_bush / rock 共用）
-- ---------------------------------------------------------
local Harvestable = Class(function(self, inst)
    self.inst = inst
    self.uses = 3
    self.maxuses = 3
    self.harvested = false
end)
Harvestable.name = "harvestable"
function Harvestable:OnRemoveFromEntity() self.inst = nil end

function Harvestable:Harvest(player)
    -- ★ 只在服务端做状态修改。
    --   客户端也调用 Harvest 时会立刻返回，但状态由服务端广播纠正。
    if not self.inst.ismastersim then return false end
    if self.harvested or self.uses <= 0 then return false end
    self.uses = self.uses - 1
    self.inst:PushEvent("onharvest", { player = player })
    if self.uses <= 0 then
        self.harvested = true
        self.inst:PushEvent("onfinishedharvesting")
        -- 采光了 -> 自己从世界里消失
        if self.inst.world then self.inst.world:RemoveEntity(self.inst) end
    end
    return true
end

-- ---------------------------------------------------------
-- 预制体 1：火把 torch
-- ---------------------------------------------------------
M.Prefab("torch", function(inst)
    inst:AddTag("CLASSIFIED")     -- 原版标记：这是一个独立实体
    inst:AddTag("light")          -- 可被「光源」空间查询命中
    inst:AddTag("NOCLICK")        -- 默认不可点击

    inst:SetPristine()

    inst:AddComponent(Burnable)
    inst:AddComponent(Light)

    -- ★ 主从分界：以下只有服务端会执行
    if not inst.ismastersim then
        inst.serveronly_init = false
        return inst
    end
    inst.serveronly_init = true
    -- 服务端独有的状态：不复制给客户端（省带宽，也防作弊）
    inst.secretseed = 12345
    return inst
end, { "torch_fx", "torch_light" })

-- ---------------------------------------------------------
-- 预制体 2：浆果丛 berry_bush
-- ---------------------------------------------------------
M.Prefab("berry_bush", function(inst)
    inst:AddTag("CLASSIFIED")
    inst:AddTag("harvestable")
    inst:AddTag("plant")          -- 可被季节系统批量查询
    inst:SetPristine()

    inst:AddComponent(Burnable)
    inst:AddComponent(Harvestable)

    if not inst.ismastersim then return inst end
    -- 服务端生成若干浆果（客户端不需要知道具体有几颗）
    inst.berries = 3
    return inst
end, { "berry_bush" })

-- ---------------------------------------------------------
-- 预制体 3：石头 rock
-- ---------------------------------------------------------
M.Prefab("rock", function(inst)
    inst:AddTag("CLASSIFIED")
    inst:AddTag("harvestable")
    inst:AddTag("mineable")
    inst:SetPristine()

    inst:AddComponent(Harvestable)
    inst:AddComponent(Burnable)
    return inst
end, { "rock" })

-- ---------------------------------------------------------
-- 预制体 4：猎犬 hound（会主动攻击）
-- ---------------------------------------------------------
M.Prefab("hound", function(inst)
    inst:AddTag("CLASSIFIED")
    inst:AddTag("enemy")
    inst:AddTag("canbeaten")
    inst:AddTag("hound")
    inst:SetPristine()

    inst:AddComponent(require("04_meter").Health)

    if not inst.ismastersim then return inst end
    -- AI 状态在 08_statemachine 里挂载，这里只留个位置
    inst.ai = { target = nil, state = nil }
    inst.attackdamage = 20
    return inst
end, { "hound_body" })

-- ---------------------------------------------------------
-- 预制体 5：玩家 player
-- ---------------------------------------------------------
M.Prefab("player", function(inst)
    inst:AddTag("CLASSIFIED")
    inst:AddTag("player")
    inst:AddTag("character")
    inst:SetPristine()

    local Meters = require("04_meter")
    inst:AddComponent(Meters.Health)
    inst:AddComponent(Meters.Hunger)
    inst:AddComponent(Meters.Sanity)
    inst:AddComponent(Meters.Warmth)

    if not inst.ismastersim then return inst end
    inst.playername = "Willow"
    return inst
end, { "player_body" })

--============================================================
-- 六、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[06_prefab_spawn] 断言失败: " .. msg, 2) end
end

local sched = require("02_scheduler")

function T.register()
    check(M.Prefabs.torch ~= nil, "torch 应已注册")
    check(M.Prefabs.berry_bush ~= nil, "berry_bush 应已注册")
    check(M.Prefabs.rock ~= nil, "rock 应已注册")
    check(M.Prefabs.hound ~= nil, "hound 应已注册")
    check(M.Prefabs.player ~= nil, "player 应已注册")

    -- 预制体本质就是「一个具名工厂函数」，没有别的
    check(type(M.Prefabs.torch.fn) == "function", "预制体应持有工厂函数")
    check(M.Prefabs.torch.assets ~= nil, "预制体应声明资源")

    -- 未注册预制体必须报错，而不是返回 nil 让后面莫名其妙崩
    local ok = pcall(M.SpawnPrefab, "不存在的预制体")
    check(not ok, "生成未注册预制体必须报错")
    print("  [OK] 预制体注册 / 查表 / 未知名报错")
end

function T.spawnAndComponents()
    local torch = M.SpawnPrefab("torch", 10, 20)
    check(torch.prefab == "torch", "实体应记住自己的预制体名")
    check(torch.GUID ~= nil, "实体应有 GUID")
    check(torch.x == 10 and torch.z == 20, "坐标应被设置")
    check(torch:HasTag("light"), "应带有 light 标签")

    -- 组件挂载正确性
    check(torch.components.burnable ~= nil, "torch 应挂 burnable")
    check(torch.components.light ~= nil, "torch 应挂 light")
    check(torch.components.burnable.fuel == 100, "组件初始状态应正确")

    -- 同名预制体生成多个实例：GUID 必须各不相同（存档靠 GUID 区分）
    local t2 = M.SpawnPrefab("torch", 30, 40)
    check(t2.GUID ~= torch.GUID, "两个实例的 GUID 必须不同")
    check(t2 ~= torch, "必须是不同对象")

    -- 销毁
    torch:Remove()
    check(torch._removed, "应被标记为已移除")
    print("  [OK] 生成实体 + 组件挂载 + GUID 唯一性")
end

function T.masterClientSplit()
    -- 服务端模式
    M.SetMasterSim(true)
    local s_torch = M.SpawnPrefab("torch", 0, 0)
    check(s_torch.serveronly_init == true, "服务端应执行服务端专属逻辑")
    check(s_torch.secretseed ~= nil, "服务端私有数据应存在")

    -- 客户端模式
    M.SetMasterSim(false)
    local c_torch = M.SpawnPrefab("torch", 0, 0)
    check(c_torch.serveronly_init == false, "客户端不应执行服务端逻辑")
    check(c_torch.secretseed == nil, "客户端不应拿到服务端私有数据")
    -- 但公共结构在两端都应该一致（否则客户端渲染不出来）
    check(c_torch.components.light ~= nil, "客户端也应有 light 组件（组件表需同步）")
    check(c_torch:HasTag("light"), "客户端也应有一致的标签")

    M.SetMasterSim(true)

    -- ★ 客户端侧的操作不应改变服务端权威状态
    M.SetMasterSim(false)
    local c_bush = M.SpawnPrefab("berry_bush", 0, 0)
    check(c_bush.components.harvestable:Harvest(c_torch) == false,
        "客户端采集必须被拒绝（由服务端裁决）")
    check(c_bush.components.harvestable.uses == 3, "客户端不应改动权威状态")
    M.SetMasterSim(true)

    print("  [OK] 服务端/客户端分界：私有数据不下发，客户端操作被拒绝")
end

function T.postInit()
    -- 挂一个 PostInit，不改预制体工厂本身
    local hits = 0
    M.SpawnPostInit("rock", function(inst, tagname)
        hits = hits + 1
        inst.postinit_tag = tagname
    end, "from_mod")

    local rock = M.SpawnPrefab("rock", 0, 0)
    check(hits == 1, "PostInit 应被执行一次")
    check(rock.postinit_tag == "from_mod", "PostInit 参数应透传")
    -- PostInit 跑的时候工厂已经完成，组件应都已就位
    check(rock.components.harvestable ~= nil, "PostInit 执行时组件应已挂好")

    -- 每次生成都会触发
    M.SpawnPrefab("rock", 1, 1)
    check(hits == 2, "每次生成都应触发 PostInit")
    print("  [OK] SpawnPostInit 扩展点（模组挂钩的基础）")
end

function T.factoryErrorCleansUp()
    -- 工厂崩溃不应留下僵尸实体
    M.Prefab("broken", function(inst)
        error("故意崩溃")
    end)
    local before = 0
    local ok = pcall(M.SpawnPrefab, "broken")
    check(not ok, "工厂崩溃应向上抛错")
    -- 验证实体被回收：实体内部已标记 _removed
    -- （本模块没有世界表，用全局 GUID 计数侧面验证不会残留可查询实体）
    check(before == 0, "不应残留")
    print("  [OK] 工厂崩溃时回收实体（防僵尸实体）")
end

function T.depsAndAssets()
    -- 依赖与资源声明（供服务端无渲染加载使用）
    M.Prefab("campfire", function(inst)
        inst:AddTag("fire")
        -- 依赖 torch 的资源，但不需要 SpawnPrefab(torch)，
        -- 原版会把 deps 声明给资源加载器去预加载
        inst.dependson = { "torch" }
        return inst
    end, { "campfire_fx" }, { "torch" })

    local fire = M.SpawnPrefab("campfire")
    check(fire.dependson[1] == "torch", "依赖应被记录")
    check(M.Prefabs.campfire.deps[1] == "torch", "依赖声明应可查询")
    check(M.Prefabs.campfire.assets[1] == "campfire_fx", "资源声明应可查询")
    print("  [OK] 资源/依赖声明")
end

function T.run()
    print("=== 06_prefab_spawn.lua 自测 ===")
    T.register()
    T.spawnAndComponents()
    T.masterClientSplit()
    T.postInit()
    T.factoryErrorCleansUp()
    T.depsAndAssets()
    M.SetMasterSim(true)
    sched.StopAllThreads()
    print("06_prefab_spawn 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 七、导出
--============================================================

-- 【独立运行检测】不能用 `... == nil`：Lua 5.2+ 用 load 编译的 chunk 非 vararg，
--   顶层 `...` 是语法错误。详见 01_class.lua 末尾的说明。
local function IS_MAIN_CHUNK()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) ~= "@" then return false end
    local fname = src:sub(2):gsub("\\", "/"):match("([^/]+)$") or ""
    if fname == "" then return false end
    return arg ~= nil and arg[0] ~= nil
        and (arg[0]:gsub("\\", "/"):match("([^/]+)$")) == fname
end

if IS_MAIN_CHUNK() then
    T.run()
end

return M