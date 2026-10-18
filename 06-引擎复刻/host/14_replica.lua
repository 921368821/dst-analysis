--[[
==============================================================================
 14_replica.lua —— replica（副本组件）分发层

 它补的是什么
   DST 的组件分两种落点：
     inst.components.<name>  —— 权威组件（服务端逻辑）
     inst.replica.<name>     —— 副本组件（客户端只读视图 / 服务端也能读的结果）
   真实分发机制写在 scripts/entityreplica.lua（369 行纯 Lua），核心是：
     · 19 个组件的白名单 REPLICATABLE_COMPONENTS
     · 用**实体标签**表达同步策略：`_combat` = 要同步，`__combat` = 显式不同步
     · ReplicateComponent(name) → AddTag("_"..name) + require(name.."_replica") + 实例化
     · inst.replica 的 __index 走 ValidateReplicaComponent 做惰性校验

 宿主此前的做法与它的问题
   宿主把 inst.replica 做成一个「问什么给什么」的哑桩：
       __index = function() return function() end
   这在「只加载、不联网」阶段能骗过大多数代码，但只要真实逻辑去**读**副本值就断链。
   实测暴露点（这就是加本文件的原因）：
     · components/combat.lua:578   Combat:IsValidTarget
           return self.inst.replica.combat:IsValidTarget(target)
       哑桩返回 nil → `Combat:SetTarget(player)` 的 `IsValidTarget and ShouldAggro`
       判定恒假 → **生物一个都追不起来**（world.lua 的「追逐」演示卡在这里）。
     · components/combat.lua:845   Combat:CanTarget 同款。

 本文件的做法
   1) 照抄 entityreplica.lua:35 的 19 项白名单；
   2) 照抄它的标签协议与 ReplicateComponent 三段结构；
   3) replica 组件**真的加载真实文件**（components/<name>_replica.lua）并实例化 ——
      不重写、不仿写。它依赖的 net_* 由 host/12_netvars.lua 提供；
   4) 只在白名单内的名字上「严格」；白名单外的名字保留宿主的宽容桩
      （真实引擎那里会返回 nil，宿主为了不把既有入口全打崩而放宽 —— 这是**宿主放宽**，
        已在 GAPS 里标注，不是「原版行为」）。

 运行位置：由 host/05_bootstrap.lua 的 Setup() 在加载组件之前调用 Install()。
==============================================================================
]]

local Core = require("host.01_core")

local M = {}

--=========================================================================
-- 1) 白名单 —— 逐字照抄 scripts/entityreplica.lua:35-55
--=========================================================================
-- 表里的 key 是「去掉 _replica 后缀的组件基名」，
-- 它同时是权限白名单与「基名 → 文件名」的映射（原版就是这样二合一的）。
local REPLICATABLE_COMPONENTS = {
    builder = true,
    combat = true,
    container = true,
    constructionsite = true,
    equippable = true,
    fishingrod = true,
    follower = true,
    health = true,
    hunger = true,
    inventory = true,
    inventoryitem = true,
    moisture = true,
    named = true,
    oceanfishingrod = true,
    rider = true,
    sanity = true,
    sheltered = true,
    stackable = true,
    writeable = true,
}

M.REPLICATABLE_COMPONENTS = REPLICATABLE_COMPONENTS

--=========================================================================
-- 2) 兼容桩：白名单外仍给「宽容表」
--=========================================================================
-- ★ 这不是原版行为，是**宿主的放宽**。
--   原版里 inst.replica.foo 对不可同步组件返回 nil，调用方自己判空；
--   宿主的历史入口（run/batch/player/play/full/render）大量直接索引 replica 成员，
--   若一律返回 nil 会一次性打崩。所以白名单外维持旧的宽容桩，
--   白名单内（= 真逻辑会读结果的那 19 个）走真实的「有则给、无则 nil」。
local function tolerant_stub()
    return setmetatable({}, {
        __index = function(_, m)
            if m == "classified" then return nil end
            return function() end
        end,
    })
end

M.TolerantStub = tolerant_stub

--=========================================================================
-- 3) 真实 replica 类的加载与缓存
--=========================================================================
-- entityreplica.lua:194-207：文件名约定 <name>_replica.lua，加载一次即缓存。
local ReplicaClasses = {}

--- 加载 components/<name>_replica.lua 的类。
--- 走 Core.LoadRealComponent 的同一套路径（它只负责「读文件 + 执行 + 返回类」）。
local function load_replica_class(name)
    local key = name .. "_replica"
    if ReplicaClasses[key] ~= nil then return ReplicaClasses[key] end

    local cls = Core.LoadRealComponent(key)
    ReplicaClasses[key] = cls or false
    return ReplicaClasses[key]
end

M.LoadReplicaClass = load_replica_class

--=========================================================================
-- 3b) 按需加载 <name>_classified 预制体
--=========================================================================
-- 真实引擎里**服务端**的每个 replica 组件会在构造期 SpawnPrefab("<name>_classified")，
-- 把一份「只放 netvar 的镜像实体」挂成子实体，用于把 net 数据推给客户端。例：
--     components/inventoryitem_replica.lua:20-21
--         self.classified = SpawnPrefab("inventoryitem_classified")
--         self.classified.entity:SetParent(inst.entity)
-- 宿主按需加载 prefab 文件，这些 classified 实体不在任何 prefab 的依赖列表里，
-- 于是 SpawnPrefab 返回 nil → 「索引 nil」→ 整只 replica 实例化失败。
--
-- ★ 这里选择**按需加载**而不是启动期一次性预加载：
--   预加载会让 full.lua 的「注册了预制体的文件」口径偏移
--   （实测 1525 → 1520，「加载成功但无预制体」69 → 74；
--     而注册表预制体总数恒为 6081、加载失败恒为 0 —— 纯记账影响）。
--   按需加载只在真的用到时多付一次，且不影响任何既有入口的统计。
--   Loader 由 host/05_bootstrap.lua 注入（本文件不反向依赖 Bootstrap）。
M.PrefabLoader = nil

local function ensure_classified(name)
    if type(M.PrefabLoader) ~= "function" then return end
    local cname = name .. "_classified"
    if Core.Prefabs[cname] ~= nil then return end
    -- ★ 失败原因要留下来。原先 `pcall(M.PrefabLoader, cname)` 把返回值整个丢掉，
    --   于是调用方只看到「回退到了 tolerant_stub」，看不到**为什么**。
    --   （同类教训：静默丢弃 = 把根因藏起来。）
    local ok, err = pcall(M.PrefabLoader, cname)
    if not ok then
        M.ClassifiedLoadErrors = M.ClassifiedLoadErrors or {}
        if M.ClassifiedLoadErrors[cname] == nil then
            M.ClassifiedLoadErrors[cname] = tostring(err):sub(1, 160)
        end
    end
end

--=========================================================================
-- 4) 安装到 EntityMeta
--=========================================================================
function M.Install(Core_)
    local meta = (Core_ or Core).EntityMeta

    -- ---- ValidateReplicaComponent ----
    -- entityreplica.lua:102 原文就是一行：
    --     return self:HasTag("_"..name) and cmp or nil
    -- ★ 校验依据是**标签**，不是「组件是否已挂载」——
    --   服务端「打算同步」与「已经同步」是两件事，由标签独立表达。
    function meta:ValidateReplicaComponent(name, cmp)
        if REPLICATABLE_COMPONENTS[name] then
            -- 白名单内：严格按标签授权。没打 _name 标签就是 nil（原版行为）。
            return self:HasTag("_" .. name) and cmp or nil
        end
        -- 白名单外：宿主放宽（见本文件第 2 节说明）。
        if cmp ~= nil and cmp ~= false then return cmp end
        return tolerant_stub()
    end

    -- ---- ReplicateComponent ----
    -- 照抄 entityreplica.lua:130-231 的三段结构。
    function meta:ReplicateComponent(name)
        -- 闸门一：白名单。
        -- ★ 这里**不是缺口**：原版 entityreplica.lua:138-144 对白名单外的名字
        --   就是静默返回（821 个组件里只有 19 个可同步）。宿主只做个计数，
        --   不往缺口清单里写 —— 否则每个实体的 propagator / burnable / inspectable
        --   都会各记一笔，把真正的缺口淹掉（实测过一次：清单里冒出 60+ 条噪声）。
        if not REPLICATABLE_COMPONENTS[name] then
            M.Skipped = (M.Skipped or 0) + 1
            return
        end

        -- 闸门二：只有服务端能改变同步策略（entityreplica.lua:146）。
        -- 原因见原注释：标签会被同步到客户端，若客户端也能加标签就是越权提权。
        if TheWorld ~= nil and TheWorld.ismastersim then
            self:AddTag("_" .. name)
            if self:HasTag("__" .. name) then
                -- 存在「否定标签」= 该组件被显式关掉过 → 撤销正标签并返回。
                self:RemoveTag("__" .. name)
                return
            end
        end

        -- 已存在则提示（原版此处是 print + debugstack，不中断）。
        if rawget(self.replica, "_")[name] ~= nil then
            return
        end

        -- 闸门三：加载真实 replica 类并实例化（entityreplica.lua:194-215）。
        --
        -- ★★ 宿主策略：**能真则真，不能真就退回宽容桩**（并记缺口）。
        --   原版的 fail-fast 只在「开发者写死了 19 项白名单」的前提下成立；
        --   宿主还要面对「原版 replica 会去 SpawnPrefab("<name>_classified")」这类
        --   依赖 network 侧预制体的行为 —— 宿主没有网络层，这些 classified
        --   实体未被预加载，于是 new 到一半就抛错。实测例：
        --     components/inventoryitem_replica.lua:13-14
        --         self.classified = SpawnPrefab("inventoryitem_classified")  -- → nil
        --         self.classified.entity:SetParent(inst.entity)             -- → 索引 nil
        --   若照原版崩掉，rabbit/spider/beefalo 会全部生成失败（实测如此）。
        --   所以退回宽容桩：保证「组件能装上」，同时把失败原因写进缺口清单 ——
        --   既不静默掩盖，也不让一个未实现的网络侧把整个世界打瘫。
        --   （这与 host/10_animstate.lua 对「没有动画数据的 build」的处理是同一策略。）
        local cmp = nil
        local cls = load_replica_class(name)
        if cls == nil then
            Core.NoteGap("replica:" .. name .. "_replica (无对应文件)", "ReplicateComponent")
        else
            ensure_classified(name)
            local ok, inst = pcall(cls, self)
            if ok then
                cmp = inst
                M.Created = (M.Created or 0) + 1
                M.CreatedNames = M.CreatedNames or {}
                M.CreatedNames[name] = (M.CreatedNames[name] or 0) + 1
            else
                local why = tostring(inst):gsub("^.-:%d+: ", ""):sub(1, 100)
                Core.NoteGap("replica:" .. name .. "_replica (实例化失败: " .. why .. ")",
                    "ReplicateComponent")
            end
        end

        if cmp == nil then
            cmp = tolerant_stub()
            M.FellBack = M.FellBack or {}
            M.FellBack[name] = true
        end
        rawset(self.replica._, name, cmp)
    end

    -- ---- UnreplicateComponent ----
    -- entityreplica.lua:233：先撤正标签、再打否定标签。
    function meta:UnreplicateComponent(name)
        if rawget(self.replica, "_")[name] ~= nil and TheWorld ~= nil and TheWorld.ismastersim then
            self:RemoveTag("_" .. name)
            self:AddTag("__" .. name)
            return true
        end
        return false
    end

    -- ---- PrereplicateComponent ----
    -- entityreplica.lua:69：先打负标签 → 再 ReplicateComponent。
    -- ★ 顺序不能反：ReplicateComponent 看到 __ 就会撤销正标签，于是「先建后关」成立。
    function meta:PrereplicateComponent(name)
        if REPLICATABLE_COMPONENTS[name] then
            self:AddTag("__" .. name)
            self:ReplicateComponent(name)
        end
    end

    -- ---- ReplicateEntity ----
    function meta:ReplicateEntity()
        for name in pairs(REPLICATABLE_COMPONENTS) do
            if self.components[name] ~= nil or self:HasTag("_" .. name) then
                self:ReplicateComponent(name)
            end
        end
    end

    return true
end

return M
