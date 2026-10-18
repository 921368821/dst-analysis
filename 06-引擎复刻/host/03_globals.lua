--[[
==============================================================================
 03_globals.lua —— 引擎单例与全局常量桩

 原版 prefab 脚本开头就会碰这些全局：
   TheNet / TheWorld / TheSim / TheInput / TheFrontEnd / TUNING / ACTIONS ...
 每个都按「Lua 层能观察到的契约」实现，未实现的接口记入 GAPS。
==============================================================================
]]

local Core = require("host.01_core")
local bitlib = require("host.21_bit")
local Sim = require("host.02_sim")

local G = {}
_G.__ENGINE_GLOBALS = G

--=========================================================================
-- TheNet：联机层。宿主无网络，但契约必须回答「是不是专用服务器」
--=========================================================================
local TheNet = {}
G.TheNet = TheNet

function TheNet:IsDedicated() return false end       -- 宿主当作客户端/单机
function TheNet:IsServer() return true end
function TheNet:IsClient() return false end
function TheNet:GetIsClient() return false end
function TheNet:GetIsServer() return true end
-- ★ floater.lua:4 等组件构造期调用：宿主只有一个进程，恒为权威
function TheNet:GetIsMasterSimulation() return true end
function TheNet:IsMasterSimulation() return true end
function TheNet:GetServerIsClientHosted() return true end
function TheNet:GetPlayerCount() return 1 end
function TheNet:GetMaxPlayers() return 6 end
function TheNet:Announce(msg) end
function TheNet:SystemMessage(msg) end
function TheNet:Say(msg, whisper) end
function TheNet:GetLocalUserName() return "HostPlayer" end
function TheNet:GetUserID() return "USER_HOST" end
function TheNet:GetClientTable() return {} end
function TheNet:GetServerGameMode() return "survival" end
function TheNet:GetDefaultClothingID() return "" end
function TheNet:GetDefaultSkinID() return "" end
function TheNet:IsNetOwner() return true end
function TheNet:Vote() end
function TheNet:GetPing() return 0 end
function TheNet:GetIsWorldGen() return false end

-- 有明确宿主语义的补充（其余靠下面的自动桩兜住）
--=========================================================================
-- ★ PrefabExists(name) —— 预制体是否已注册（mainfunctions.lua:399）
--=========================================================================
--      function PrefabExists(name)
--          return Prefabs[name] ~= nil
--      end
--
-- 它也在 mainfunctions.lua（2589 行，拖了一串 UI 屏幕），所以照抄实现。
--
-- ★★ 但**不能**直接写 `return G.Prefabs[name] ~= nil` —— 宿主是**懒加载**的：
--    `Prefabs[name]` 为 nil 可能只是「还没加载」，而不是「不存在」。
--    调用点正好会因此走错分支 —— components/lootdropper.lua:416-420 的
--    烧焦掉落改写：
--        if TUNING.BURNED_LOOT_OVERRIDES[v] ~= nil then ...
--        elseif PrefabExists(v.."_cooked") then   prefabs[k] = v.."_cooked"
--        elseif PrefabExists("cooked"..v) then    prefabs[k] = "cooked"..v
--        elseif ... then prefabs[k] = "ash"
--    若 `meat_cooked` 因为没加载而被判「不存在」，掉出来的就成了 **ash**，
--    而不是熟肉 —— 静默走错分支，画面看着还挺合理（确实掉了东西）。
--    所以这里**先尝试懒加载，再判**。
--
--    （实测起点：burn.lua 砍烧焦的树时报
--      `lootdropper.lua:418: attempt to call global 'PrefabExists' (a nil value)`。
--      charcoal 仍然掉了，是因为 `SpawnLootPrefab("charcoal")` 在 DropLoot() **之前**，
--      报错发生在链尾 —— 所以只看「有没有掉东西」是发现不了的。）
-- ★★★ 这里原来写的是 `G.Prefabs`，而 `G` 是本文件第 15 行的 `local G = {}`
--   —— 一个**用来往 _G 里灌全局的暂存表**，它自己**没有 Prefabs 字段**
--   （`_G.Prefabs = Core.Prefabs` 才是全局那一份，见 05_bootstrap.lua:40）。
--   ⇒ `G.Prefabs ~= nil` 恒 false ⇒ **本函数自打加上起就永远返回 false**，
--     一次都没真正判过。burn.lua 当初照样通过，是因为树的掉落路径
--     压根不调它（charcoal 是直接 SpawnLootPrefab 的）。
--   ⇒ 这就是「静默空实现」的教科书案例：**没有报错、没有进桩清单、
--     甚至被一个通过的测试盖住**，只是行为全是默认值。
--     它是靠 tests.lua 的 T2 直接针对本函数断言才暴露的。
function G.PrefabExists(name)
    if type(name) ~= "string" then return false end
    if Core.Prefabs ~= nil and Core.Prefabs[name] ~= nil then return true end
    -- 懒加载：宿主按需加载，先试着把它拉进来再判。
    --
    -- ★★★ 这里踩过一个**很贵的坑**：原实现写的是
    --       local loader = rawget(_G, "Core")
    --   而 `Core` 在本文件第 11 行是 `local Core = require("host.01_core")`
    --   —— **模块局部，不是全局** ⇒ `rawget(_G, "Core")` 恒为 nil
    --   ⇒ 整段懒加载被静默跳过 ⇒ 本函数退化成
    --       return Prefabs[name] ~= nil
    --   也就是「修复」根本没生效。而 burn.lua 当时照样通过 ——
    --   因为树的掉落路径**压根不走 PrefabExists**（charcoal 是直接 spawn 的）。
    --   ⇒ 「测试通过」在这里**完全不能证明修复有效**，必须有一条
    --     直接针对本函数行为的断言（tests.lua 的 T2 就是那条）。
    --
    --   第二环：即便加载了，还得**找得到**。`meats.lua` 里
    --   `fishmeat_small_cooked` 这类名字是用 common(...) 批量注册的，
    --   文件里没有字面量 Prefab("xxx")，文本索引扫不到
    --   ⇒ 必须把 meats 放进 DYNAMIC_FAMILY_FILES（见 05_bootstrap）。
    --   **两环都补上才算真修好。**
    if type(Core._prefab_loader) == "function" then
        pcall(Core._prefab_loader, name)
    end
    return Core.Prefabs ~= nil and Core.Prefabs[name] ~= nil
end

--=========================================================================
-- ★ Print(msg_verbosity, ...) —— 分级日志（mainfunctions.lua:48）
--=========================================================================
--      function Print( msg_verbosity, ... )
--          if msg_verbosity <= VERBOSITY_LEVEL then print( ... ) end
--      end
--
-- 它住在 mainfunctions.lua（2589 行）里，而那个文件 require 了
-- `screens/redux/popupdialog` / `screens/worldgenscreen` / `screens/healthwarningpopup`
-- / `stats` —— 一整串 UI 屏幕，不值得为 4 行函数拖进来。所以照抄实现。
--
-- ⚠️ 代表性调用点 components/locomotor.lua:1431：
--       if not self.inst:IsValid() then
--           Print(VERBOSITY.DEBUG, "OnUpdate INVALID", self.inst.prefab)
--   缺了 Print 会让**整个 OnUpdate 中断**（不只是少打一行日志）。
--   VERBOSITY_LEVEL 按 main.lua:271 的默认取 ERROR(0) ⇒ DEBUG(3) 级别的
--   这条不会打印，与正式版行为一致。
if G.VERBOSITY_LEVEL == nil then
    G.VERBOSITY_LEVEL = (G.VERBOSITY ~= nil and G.VERBOSITY.ERROR) or 0
end

-- ★★★ event_server_data(eventname, path)
--
--   原版（entityscript.lua:77-87）：
--       local fullpath = eventname.."_event_server/"..path
--       EventServerFiles[fullpath] = requireeventfile(fullpath)
--       if path starts with "components/" then 加 WatchWorldState/StopWatchingWorldState
--       return EventServerFiles[fullpath]
--   用法：lavaarena_beetletaur.lua:258
--       event_server_data("lavaarena", "prefabs/lavaarena_beetletaur").master_postinit(inst, fn)
--
--   ★★ 为什么在宿主里它**降级而不是照抄**：
--   本宿主的 `scripts/` 是**部分提取**（1447 个 prefabs + 常用组件/大脑），
--   **没有** `lavaarena_event_server/` / `quagmire_event_server/` 这些目录。
--   所以 `requireeventfile` 找不到东西 —— 这是**数据边界**，不是代码缺口。
--   ⇒ 正确做法是**优雅降级**：返回一个带空 `master_postinit` 的表，
--     让那些 DLC 活动预制体**至少能生成**，而不是在 postinit 里崩掉。
--     缺的是「活动专属逻辑」，这一点在报告里如实标注为边界。
--
--   实测：300 抽样里有 ~15 个 lavaarena/quagmire/yotd 预制体栽在这条上。
G.EventServerFiles = {}
function G.event_server_data(eventname, path)
    local fullpath = tostring(eventname) .. "_event_server/" .. tostring(path)

    -- ★★ 降级计数（可观测性）——必须在**每一次**拿到降级模块时都记，
    --   而不是只在「首次降级」时记。
    --
    --   为什么：`G.EventServerFiles` 会**缓存**降级结果，所以第二次调用
    --   走的是上面那个提前 return 的分支。第一版我只在 `mod == nil`
    --   （首次）那一段计数 ⇒ 同一个进程里只有**第一个** event_server 预制体
    --   能被计数到，后面的全是 0。
    --   后果不是少记几个数，而是**判据失效**：
    --       `lavaarenastage_attack` / `_delay` / `_endofmatch` / `_resetgame`
    --       （同一家族的 4 个）在抽样里被归成「未定性 —— 必须去查」，
    --       而它们和已经正确定性的 `lavaarenastage_dialog` 是**同一条**路径。
    --   ⇒ 判据依赖的那个计数，必须与实际「被用到」的次数对齐。
    local function bump(full)
        Core.EventServerDegraded = Core.EventServerDegraded or { count = 0, paths = {} }
        Core.EventServerDegraded.count = Core.EventServerDegraded.count + 1
        Core.EventServerDegraded.paths[full] =
            (Core.EventServerDegraded.paths[full] or 0) + 1
    end

    local cached = G.EventServerFiles[fullpath]
    if cached ~= nil then
        if type(cached) == "table" and cached._degraded then bump(fullpath) end
        return cached
    end

    local dir = (rawget(_G, "SourceDir") or "") .. "/" .. eventname .. "_event_server"
    local fs = io.open(dir .. "/" .. tostring(path), "r")
    local mod = nil
    if fs ~= nil then
        fs:close()
        local chunk = loadfile(dir .. "/" .. tostring(path))
        if chunk ~= nil then
            local okc, r = pcall(chunk, "@" .. dir .. "/" .. tostring(path))
            if okc and type(r) == "table" then mod = r end
        end
    end

    if mod == nil then
        -- ★★ 让降级**可观测**：降级本身是数据边界，但「有没有被触发、
        --   触发了多少次、走的是哪几条路径」必须能数出来 ——
        --   否则 `lavaarenastage_dialog` 那种「工厂返回 nil」看起来像代码缺陷。
        --   reachability.lua 用这个计数器把「数据边界」和「真缺口」分开。
        Core.EventServerDegraded = Core.EventServerDegraded or { count = 0, paths = {} }
        Core.EventServerDegraded.count = Core.EventServerDegraded.count + 1
        Core.EventServerDegraded.paths[fullpath] =
            (Core.EventServerDegraded.paths[fullpath] or 0) + 1
        -- ★★★ 降级：用**代理**给「任何 *_postinit / 任何方法」一个空实现。
        --   第一版我只枚举了 `master_postinit` + `postinit` 两个名字，
        --   结果 5 个预制体继续挂：
        --       `projectile_postinit`（blowdart_lava / lavaarena_peghook）
        --       `master_postinit_item`（quagmire_oven / quagmire_pot_hanger）
        --       `hitfx_postinit`、`goospit_postinit` …
        --   —— 又是「枚举法漏名字」，**与 AddVFXEffect 那次是同一个教训**。
        --   ⇒ 代理法从根上避免：任何键都返回可调用的空实现。
        --     调过的名字记进 `_calls`，需要时能看清单。
        local rec = { _degraded = true, _calls = {} }
        mod = setmetatable(rec, {
            __index = function(t, k)
                if type(k) ~= "string" then return nil end
                local f = rawget(t, k)
                if f ~= nil then return f end
                local m = function(...) return nil end
                rawset(t, k, m)
                return m
            end,
        })
    end
    if type(path) == "string" and string.sub(path, 1, 11) == "components/" then
        mod.WatchWorldState = mod.WatchWorldState or function() end
        mod.StopWatchingWorldState = mod.StopWatchingWorldState or function() end
    end
    G.EventServerFiles[fullpath] = mod
    return mod
end

-- ★★ PhysicsWaker 全局（main.lua:476 `PhysicsWaker.SetMaxPhysicsRadius(...)`）
--   真实引擎里它既是 C++ 类、也是全局可见的静态入口。
--   宿主补一份最小实现：实例侧的 AddPhysicsWaker 在 01_core，
--   这里补**静态**侧，两边共用同一个上限值。
G.PhysicsWaker = {
    _max_radius = nil,
    _instances = {},
}
function G.PhysicsWaker.SetMaxPhysicsRadius(r)
    G.PhysicsWaker._max_radius = r
    for _, w in pairs(G.PhysicsWaker._instances) do w:SetMaxPhysicsRadius(r) end
    return r
end
function G.PhysicsWaker.GetMaxPhysicsRadius()
    return G.PhysicsWaker._max_radius
end
function G.PhysicsWaker.Register(w)
    if w ~= nil then
        G.PhysicsWaker._instances[w] = true
        if G.PhysicsWaker._max_radius ~= nil then
            w:SetMaxPhysicsRadius(G.PhysicsWaker._max_radius)
        end
    end
end

-- ★ TALKINGFONT（scripts/fonts.lua:12）= "talkingfont"
--   宿主根目录**没有 fonts.lua**（它只在 scripts/ 里），而 talker.lua:161
--   会引用 `self.font or TALKINGFONT` ⇒ 缺失时报
--   「attempt to call global / nil value」（协程里 ⇒ 静默死掉）。
G.TALKINGFONT = "talkingfont"
function G.Print(msg_verbosity, ...)
    if (tonumber(msg_verbosity) or 0) <= G.VERBOSITY_LEVEL then
        print(...)
    end
end

--=========================================================================
-- ★ TheShard —— 分片对象（C++ 全局）
--=========================================================================
-- 原版用法（`TheShard:<方法>` 的完整清单，从全库扫出来）：
--   GetShardId()                       —— constants.lua:2481 `SHARDID = { INVALID="0", MASTER="1" }`
--   IsMaster() / IsSecondary()         —— 分片角色判断
--   IsMigrating()                      —— 是否正在迁移玩家
--   StartMigration / SetSecondaryLoading / GetSecondaryShardPlayerCounts
--
-- 宿主是**单一主分片**（没有洞穴分片、没有迁移），所以：
--   角色类方法返回真值，迁移类方法的语义就是「永远不迁移」。
-- 代表性调用点：player_common_extensions.lua:234
--   `inst.last_death_shardid = TheShard:GetShardId()`
--   —— 缺了它整条死亡处理链直接「索引 nil」。
local TheShard = {}
G.TheShard = TheShard
TheShard.GetShardId = function() return "1" end          -- SHARDID.MASTER
TheShard.IsMaster = function() return true end
TheShard.IsSecondary = function() return false end
TheShard.IsMigrating = function() return false end
-- 迁移类：宿主不分片，如实返回「没这回事」，而不是假装成功
TheShard.StartMigration = function() return false end
TheShard.SetSecondaryLoading = function() end
TheShard.GetSecondaryShardPlayerCounts = function() return nil end

--=========================================================================
-- ★ 联机交互类：Talker / AnnounceDeath / SendRPCToClient
--=========================================================================
-- 宿主无网络栈，但这些都是**有内容的动作**，不该静默丢掉 ——
-- 记下来（可从 TheNet 上读回），需要时能断言、能展示。
--
--   TheNet:Talker(guid, message, ...)      components/talker.lua:193
--                                          —— 实体说话（聊天/台词）
--   TheNet:AnnounceDeath(str, entity)      player_common_extensions.lua:259/693/780
--                                          —— 死亡公告（「XXX 被 YYY 杀死了」）
--   TheNet:SendRPCToClient(code, userid,…) cookbookupdater.lua:25 等
--                                          —— 给**指定客户端**发 RPC
--                                          宿主无网络 ⇒ 委托给 networkclientrpc.lua
--                                          提供的全局（它在非 mastersim 时本来就是 no-op）
TheNet._talklog = {}
TheNet._deathlog = {}
function TheNet:Talker(guid, message, ...)
    self._talklog[#self._talklog + 1] = { guid = guid, message = message }
end
function TheNet:GetTalkLog() return self._talklog end
function TheNet:AnnounceDeath(str, entity)
    self._deathlog[#self._deathlog + 1] = { text = str }
end
function TheNet:GetDeathLog() return self._deathlog end
function TheNet:SendRPCToClient(code, userid, ...)
    local f = rawget(_G, "SendRPCToClient")
    if type(f) == "function" then
        local args = { ... }
        return pcall(f, code, userid, unpack(args, 1, select("#", ...)))
    end
    return true
end

-- ★ 世界重置标志（components/worldreset.lua:117/176/242 在写）
--   宿主不重置世界，但这是**真实状态位**：写进去、能读回来。
--   原版 Lua 侧只有 setter（读的一方在 C++ 网络层），所以补一个 getter 供宿主自检。
function TheNet:SetIsWorldResetting(v) TheNet._isworldresetting = v and true or false end
function TheNet:IsWorldResetting() return TheNet._isworldresetting == true end

function TheNet:IsOnlineMode() return false end        -- 单机
function TheNet:GetPVPEnabled() return false end       -- 单机无 PVP
function TheNet:IsServerPaused() return false end
function TheNet:GetServerMaxPlayers() return 6 end
function TheNet:GetServerName() return "HostWorld" end
function TheNet:GetIsHosting() return false end
function TheNet:GetSessionIdentifier() return "host-local" end
function TheNet:IsNetIDPlatformValid() return true end
function TheNet:GetClientTableForUser() return nil end

-- ★★ TheNet 是**纯 C++ 联机层**：宿主没有网络栈，它的 200+ 个方法
--    （StartClient / TruncateSnapshots / SendWorldRollbackRequestToServer ...）
--    一个都不可能在宿主里实现，也不该实现。
--    但如果某个方法不存在，调用点会直接抛「attempt to call method 'X' (a nil value)」
--    把整个仿真打断 —— 实测 talker.lua:193 的 `TheNet:Talker(...)` 就是这样，
--    在 tick 253（生物第一次开口说话）把 world.lua 的仿真掐断了。
--
--    做法与全局兜底（07_universal.lua）同源，但**作用域严格限定在 TheNet**：
--    未声明的方法自动降级为「no-op，返回 nil」，并计入 GAPS 的桩调用清单。
--    返回 nil 而不是万能对象 —— 联机层查询（IsDedicated / GetPVPEnabled …）
--    的「没有」语义本来就是 nil/false，这与单机宿主的真实状态一致。
--
--    ⚠️ 顺序：方法必须先全部定义好，再装元表；__index 只在原始查找失败时才触发。
local DECLARED = {}
for k, v in pairs(TheNet) do DECLARED[k] = true end
setmetatable(TheNet, {
    __index = function(t, k)
        if type(k) ~= "string" or k:match("^_") then return nil end
        -- 把未声明方法补成 no-op 并记录（只记第一个来源，避免刷屏）
        local fn = function() return nil end
        rawset(t, k, fn)
        Core.NoteStub("TheNet:" .. k, "net-layer")
        return fn
    end,
})
TheNet.__declared = DECLARED

--=========================================================================
-- TheWorld：世界实体。宿主侧投影在 02_sim 里，这里补齐契约方法
--=========================================================================
local TheWorld = Sim.World
G.TheWorld = TheWorld

TheWorld.ismastersim = true
TheWorld.ismastershard = true
TheWorld.net = nil            -- 原版有 TheWorld.net（shard 网络组件）

function TheWorld:GetState() return self.state end
function TheWorld:HasTag(t) return false end
function TheWorld:IsCave() return self.state.iscave end
function TheWorld:IsRuins() return false end
function TheWorld:IsSurvival() return true end
function TheWorld:IsCaveWorld() return self.state.iscave end
function TheWorld:CanStartNightmare() return false end

-- ★ CanFlyingCrossBarriers —— 真实实现在 prefabs/world.lua:1061（**是 Lua，不是 C++**）：
--     local function CanFlyingCrossBarriers(world)
--         return world.has_ocean or world.cancrossbarriers_flying
--     end
--   它由世界预制体挂到世界实体上，宿主不生成真实 world 预制体，于是缺失。
--   调用点很散：standardcomponents.lua 的 MakeFlyingCharacterPhysics、
--   ocean_util.lua:168/179、prefabs/abigail.lua:117… —— batch.lua 的 300 tick 阶段
--   就断在这里（attempt to call method 'CanFlyingCrossBarriers'）。
--   语义：返回真 ⇒ 飞行单位用 COLLISION.GROUND 掩码（可以越过世界边界屏障）。
--   host 生成的地图确实含海洋瓦片，故 has_ocean = true（与原版生存世界一致）。
TheWorld.has_ocean = true                 -- 原版注释标注它是「向后兼容」字段
TheWorld.cancrossbarriers_flying = false  -- 新字段：显式开关（这里保持关闭）
function TheWorld:CanFlyingCrossBarriers()
    -- 逐字对齐 prefabs/world.lua:1072 的 `or` 语义（**不是** and ——
    -- 用 and 会让老存档行为改变）
    return (self.has_ocean or self.cancrossbarriers_flying) and true or false
end

--=========================================================================
-- TheSim / TheInput / TheFrontEnd / 其余单例
--=========================================================================
G.TheSim = Sim.TheSim

local TheInput = {}
G.TheInput = TheInput
function TheInput:IsMouseDown() return false end
function TheInput:IsKeyDown() return false end
function TheInput:GetWorldPosition() return 0, 0, 0 end
function TheInput:GetScreenPosition() return 0, 0 end
function TheInput:GetAnalogControlVector() return 0, 0 end
function TheInput:EnableMouseFilter() end
function TheInput:DisableMouseFilter() end
function TheInput:AddMoveHandler() end
function TheInput:AddKeyHandler() end
function TheInput:AddMouseButtonHandler() end
function TheInput:AddTextInputHandler() end
function TheInput:OnControlMapped() end
function TheInput:IsControllerActive() return false end
function TheInput:GetInputDevices() return {} end

local TheFrontEnd = {}
G.TheFrontEnd = TheFrontEnd
function TheFrontEnd:GetActiveScreen() return nil end
function TheFrontEnd:PushScreen() end
function TheFrontEnd:PopScreen() end
function TheFrontEnd:SetFadeLevel() end

-- ★ TheInventory：giftreceiver.lua:58 等组件直接用。
--   宿主单玩家，给一个「取当前玩家库存」的代理。
G.TheInventory = {
    GetInventory = function() return nil end,
    Collect = function() return {} end,
    CollectAll = function() return {} end,
    Has = function() return false end,
    FindItem = function() return nil end,
    Open = function() return false end,
    GetClientGiftCount = function() return 0 end,
    GetGiftCount = function() return 0 end,
}
-- ★ POPUPS：弹出式 UI 的类型常量表（真实定义在 popupmanager.lua:45）。
--   宿主没有 UI 层，但**代码会读它的键**：
--     prefabs/player_common_extensions.lua:1120
--         inst:ShowPopUp(POPUPS.PLAYERINFO, false)
--   POPUPS 为 nil 就直接「索引 nil」抛错。
--   做成惰表：任何键都返回「键名本身」，于是 ShowPopUp 拿到一个稳定标识，
--   而宿主侧 ShowPopUp 是桩（no-op），不会有副作用。
--   不加载 popupmanager.lua 的原因：它是纯 UI 文件，会拖进 Screen/Widget 依赖链。
if rawget(G, "POPUPS") == nil then
    local popups = {}
    setmetatable(popups, {
        __index = function(t, k)
            if type(k) ~= "string" or k:match("^_") then return nil end
            rawset(t, k, k)
            return k
        end,
    })
    G.POPUPS = popups
end

-- ★ 性能剖析全局：hunger.lua:119 等多处调用。宿主不做剖析，全部 no-op。
--   注意必须是**函数**（不能是 0），否则会 "attempt to call a number value"。
for _, fn in ipairs({
    "ProfileStatsSet", "ProfileStatsAdd", "ProfileStatsAddItemChunk",
    "ProfileStatsAddToField", "ProfileStatsAppendToField", "ProfileStatsGet",
    "ProfileStats" .. "Push", "ProfileStats" .. "Pop",
}) do
    if G[fn] == nil then G[fn] = function() return 0 end end
end
-- =========================================================================
-- ★ UI 层启动所需的几个全局（补齐后 screens/ 与 widgets/ 就能加载了）
-- =========================================================================

-- ValidateLineNumber：main.lua:54 定义，只是转发给 TheSim。
-- 缺了它会让 4 个 UI 模块（widget / imagebutton / barterscreen /
-- popupdialog）在顶层调用时直接崩。宿主不做行号校验，no-op 即可。
function G.ValidateLineNumber(num) end

-- ★ CreatePrefabSkin：prefabskin.lua:3938 定义（在**真实的 Prefab 类**体系里）。
--=========================================================================
-- ★★★ global(...) —— 声明全局名（strict.lua:27）
--=========================================================================
--   它是 `actions.lua:273` 的第一句就用到的：
--       global("CLIENT_REQUESTED_ACTION")
--       CLIENT_REQUESTED_ACTION = nil
--   宿主缺它 ⇒ **整个 actions.lua 加载失败**（`attempt to call global 'global'`）
--   ⇒ 宿主只能用自己手写的那张 34 项的 ACTIONS 小表。
--
--   ★★ 后果是**静默的**：ACTIONS 存在、动作名字都在、`GetActionType()` 也能调，
--      于是没人发现每个动作都缺字段。直到 `prefabs/bootleg.lua:124`：
--          inst.map_remap_min_dist = ACTIONS.TOSS.distance + TUNING...
--      报 `attempt to perform arithmetic on field 'distance' (a nil value)`
--      —— 而原版 `actions.lua:294` 的构造器**明明**有 `self.distance = data.distance`。
--
--   ★ 为什么不直接加载 strict.lua 拿这个函数：
--     strict.lua 会给 `_G` 装**严格模式元表** —— 未声明的全局**读写都直接 error**。
--     宿主刻意跑非严格模式（大量全局按需补、还有万能兜底），
--     装上它只会造出成片假报错。⇒ 只实现 `global` 这一个函数，语义取「声明登记」。
--
--   在本宿主里它是**no-op**：非严格模式下赋值本来就不需要预先声明，
--   所以「登记一下」与「什么都不做」行为等价。
function G.global(...) end

-- ★★★ TheInventory —— 客户端账号/皮肤仓库对象（C++ 单例）
--=========================================================================
--   实测症状（可达性抽样，`prefabs/livingtree.lua:190`）：
--       if TheInventory:HasSupportForOfflineSkins() or TheNet:IsOnlineMode() then
--       ✘ attempt to index global 'TheInventory' (a nil value)
--     ⇒ livingtree（活木树，核心资源树）生成不出来。
--
--   使用面（全库计数）：`skins_defs_data.lua` 里 **9713 次**（皮肤数据集登记）、
--   `skinsutils.lua` 31 次，其余散在 UI 屏幕。宿主不加载皮肤数据集与 UI，
--   真正会被走到的是**能力查询**。
--
--   ★ 语义选择：宿主没有账号系统 ⇒
--        HasSupportForOfflineSkins() → **false**（没有离线皮肤数据）
--        Get* → nil；Add*/Set*/Clear* （皮肤登记）→ no-op 并记账
--     等价于「离线/未登录客户端」，是诚实取值，不是假装有皮肤仓库。
--     ⚠️ 刻意**不**用万能链式代理：那样 Has* 会返回真值，
--        调用方会走进「有离线皮肤」的分支 —— 那是**行为谎言**。
do
    local rec = { _calls = {} }
    G.TheInventory = setmetatable(rec, {
        __index = function(t, k)
            if type(k) ~= "string" then return nil end
            local f = rawget(t, k)
            if f ~= nil then return f end
            local fn
            if k:match("^Has") or k:match("^Is") or k:match("^Should") then
                fn = function(self, ...)
                    self._calls[k] = (self._calls[k] or 0) + 1
                    return false
                end
            elseif k:match("Count$") then
                -- ★★ 名字以 Count 结尾的 getter **必须返回数字**。
                --   第一版把这些也归到 `Get* → nil`，结果：
                --     components/giftreceiver.lua:58
                --         local giftcount = TheInventory:GetClientGiftCount(userid)   -- nil
                --     → :61 self.giftcount = giftcount（触发 Class 属性 setter）
                --     → :17  self.inst.player_classified.hasgift:set(giftcount > 0)
                --        ✘ attempt to compare nil with number
                --   一崩就把 mech.lua / burn.lua / perish.lua 三个入口的
                --   `Sim.Step()` 打断（world.lua 的轨迹也因此变成 0 个点）。
                --   ⇒ 与本轮 Light 的 `_intensity/_falloff` 是同一条教训：
                --     **数值型 getter 绝不能返回 nil**（下游多半是算术/比较）。
                fn = function(self, ...)
                    self._calls[k] = (self._calls[k] or 0) + 1
                    return 0
                end
            elseif k:match("^Get") then
                fn = function(self, ...)
                    self._calls[k] = (self._calls[k] or 0) + 1
                    return nil
                end
            else
                fn = function(self, ...)
                    self._calls[k] = (self._calls[k] or 0) + 1
                    return nil
                end
            end
            rawset(t, k, fn)
            return fn
        end,
    })
end

-- ★ CreatePrefabSkin：prefabskin.lua:3938 定义（在**真实的 Prefab 类**体系里）。
--   skinprefabs.lua:5 顶层调用它来累积皮肤定义，然后整体 return。
--   宿主不实现皮肤系统，但需要一个能接受调用、返回可用对象的桩 ——
--   否则整个 skinprefabs.lua 加载失败（它是个「数据汇」，不该因缺皮肤系统而丢）。
--   ⚠️ 不能靠加载 prefabskin.lua 来拿这个函数：它会 require("prefabs")，
--      把宿主的 Prefab 注册函数换成真实类，实测导致 38 个 prefab 连锁失败。
function G.CreatePrefabSkin(name, info)
    local skin = {}
    if type(info) == "table" then
        for k, v in pairs(info) do skin[k] = v end
    end
    skin.name = name
    skin.skin_name = name
    return skin
end

-- ★★★ prefabskin.lua 顶部的全局空表（BASE_TORSO_TUCK / ONE_PIECE_SKIRT / …）
--
--   components/skinner.lua **直接索引**它们且没有 nil 守卫：
--       :64  local tuck_torso     = BASE_TORSO_TUCK[base_skin] or "skirt"
--       :67  local legs_cuff_size = BASE_LEGS_SIZE[base_skin] or 1
--       :344 ... ONE_PIECE_SKIRT[base_skin] ...
--   实测症状：wx78_backupbody / scarecrow / player_hosted 三个预制体挂掉，
--   skinner 又是**所有可换肤实体**的必经之路 ⇒ 影响面远大于 3。
--
--   ⚠️ 第一版我**手工**列了 5 个（BASE_* 系列），补完立刻露出第二层
--      `ONE_PIECE_SKIRT` —— 又是「凭印象列清单」。
--      ⇒ 改成 host/27_prefabskin_globals.lua：启动时从真实 prefabskin.lua
--        **静态提取**零缩进的 `NAME = {}` 声明并逐个建表，清单永不再漂。
--   ⚠️ 不要为了这几个空表去加载 prefabskin.lua：
--      实测负收益（失败 4→38、注册表 6075→5190），见 05_bootstrap.lua。
do
    local ok, mod = pcall(require, "host.27_prefabskin_globals")
    if ok and mod ~= nil then mod.Install() end
end

--=========================================================================
-- ★ main.lua:288-302 的实体表全局（**Ents 是 GUID → 实体**）
--=========================================================================
--   实测症状：brains/hostedbrain.lua:113 `Ents[...]` ⇒
--       ✘ attempt to index global 'Ents' (a nil value)（player_hosted 挂掉）
--
--   `Ents` 的语义（main.lua:289 `Ents = {}`）就是宿主已有的
--   `Core.Spawned`（guid → inst）—— 直接**别名**过去，不另建一份。
--   别名而不是拷贝：两份表会在实体增删时不一致。
--
--   其余几个是**引擎更新泵的分桶表**（entityscript.lua:446/453/511 往里写，
--   1744-1752 往外删）。宿主用自己的 13_update 泵，不用它们，
--   但 entityscript 的写操作必须有个落点 —— nil 会直接崩。
--   ⚠️ 已知语义差异（如实标注）：宿主不维护它们的成员关系，
--      读取 `UpdatingEnts[guid]` 一律得到 nil。真实读取点在
--      mainfunctions.lua:519-528（卸载实体时清理桶，写操作），
--      以及 main.lua 的更新循环（宿主已替换）⇒ 不影响逻辑量。
if _G.Ents == nil and G.Ents == nil then
    G.Ents = Core.Spawned
end
for _, nm in ipairs({
    "AwakeEnts", "UpdatingEnts", "NewUpdatingEnts", "StopUpdatingEnts",
    "StaticUpdatingEnts", "NewStaticUpdatingEnts",
    "WallUpdatingEnts", "NewWallUpdatingEnts",
    "StopUpdatingComponents",
}) do
    if G[nm] == nil and _G[nm] == nil then G[nm] = {} end
end
if G.NumEnts == nil then G.NumEnts = 0 end
if G.num_updating_ents == nil then G.num_updating_ents = 0 end

-- ★ InGamePlay：mainfunctions.lua:1690 `function InGamePlay() return inGamePlay end`
--   变量 `inGamePlay` 在 main.lua:380 初始化为 false，
--   由 gamelogic.lua:1020 置 true（进入对局）。
--   宿主**没有前端/登陆流程** —— 进程一起来就是「在对局中」，
--   所以忠实等价物是常量 true（不是 false，也不是 nil）。
--   实测症状：worldmigrator.lua:109 `if InGamePlay() and not ...` ⇒
--     ✘ attempt to call global 'InGamePlay' (a nil value)（cave_entrance 挂掉）
function G.InGamePlay() return true end

-- ★ IsMigrating：mainfunctions.lua:1693，需要 TheFrontEnd（宿主没有）。
--   宿主不做分片迁移 ⇒ false。补它是因为它和 InGamePlay 成对出现。
function G.IsMigrating() return false end

--=========================================================================
-- ★★★ Profile —— 玩家本地设置对象（C++，全库 **723 处** `Profile:XXX`）
--=========================================================================
--   它不是函数，是一个**对象**（用户本地配置：画面抖动强度、控制方案、
--   上次用过的皮肤、世界自定义预设……）。
--
--   实测症状：components/ambientlighting.lua:88
--       local _flash_str_setting = SCREEN_FLASH_SCALING[Profile:GetScreenFlash() or 1]
--       ✘ attempt to index global 'Profile' (a nil value)
--     ⇒ ambientlighting **组件构造直接失败** ⇒ 世界没有环境光照组件
--     ⇒ prefabs/moon_fissure.lua:49 崩（而且所有 light watcher 都读它）。
--
--   ★ 语义选择：宿主**没有本地配置**，所以忠实等价物是
--     「所有设置都在默认值上」：
--        Get* / GetValue*  → nil   ⇒ 调用方的 `or 默认值` / `== "Classic"` 自然走默认分支
--        Is* / Has* / Saw* / Showed* → false
--        其余（Set* / Save / Load / …）→ no-op
--     这与原版「新装好的客户端、什么都没配过」一致。
--     ⚠️ 不要一律返回 self（链式代理那种做法）：
--        `SCREEN_FLASH_SCALING[<表>]` 会得到 nil ≠ 默认值 1，
--        把一个「没设过」伪装成「设了个不存在的值」。
--
--   ★ 723 处调用点里绝大多数在 UI 屏幕里（宿主不加载那些文件）；
--     真正被走到的是设置读取。调过的名字记进 `_calls`，可审计。
do
    local rec = { _calls = {} }
    local function bump(k)
        rec._calls[k] = (rec._calls[k] or 0) + 1
    end
    G.Profile = setmetatable(rec, {
        __index = function(t, k)
            if type(k) ~= "string" then return nil end
            local f = rawget(t, k)
            if f ~= nil then return f end
            local fn
            if k:match("^Get") then
                fn = function(self, ...) bump(k); return nil end
            elseif k:match("^Is") or k:match("^Has")
                or k:match("^Saw") or k:match("^Showed") then
                fn = function(self, ...) bump(k); return false end
            else
                fn = function(self, ...) bump(k); return nil end
            end
            rawset(t, k, fn)
            return fn
        end,
    })
end

-- hash：C++ 引擎函数（Lua 侧无定义），用于把字符串转成哈希表键。
--
-- ★ 2026-10-14：算法从「自造多项式」升级为**实证的 sdbm**。
--   此前这里写的是 `h = (h*31 + byte) % 2^32`，并注释「不追求与引擎一致」。
--   那个注释是**错的** —— 引擎哈希值确实会被跨文件比较：
--     clothing.lua:11765   CLOTHING_SFX = { [0x7BB765F7] = { -- feet_horseshoe ... } }
--     player_common_extensions.lua:1277
--         local skin_sfx = CLOTHING_SFX[... GetSymbolOverride("foot")]
--   这两处要能对上，hash("feet_horseshoe") 就必须**精确等于** 0x7BB765F7。
--
--   实证过程（_probe_hash.py / _probe_hash2.py，一次性探针，已删）：
--     · 拿 anim_data/*.json 里 67 组「符号名 → 哈希」当已知样本
--       （这些哈希是 build.bin 里真实存的，不是猜的）
--     · 试 fnv1a / fnv1 / djb2 / djb2x / sdbm / joaat / crc32 / murmur3 / jenkins
--     · **只有 sdbm 全中**：67/67
--       （唯一看着不命中的 SWAP_ICON，是导出侧把显示名写成了大写，
--         sdbm("swap_icon") 才等于真实哈希 0xF6AADF05 —— 反而印证了算法）
--     · sdbm("feet_horseshoe") == 0x7BB765F7，与 CLOTHING_SFX 的键分毫不差
--
--   sdbm 的经典写法用移位：
--       h = (c + (h<<6) + (h<<16) - h) & 0xFFFFFFFF
--   而 (h<<6)+(h<<16)-h == h*65599，所以可以纯算术表达 ——
--   ⚠️ Lua 5.1 没有位运算符（`~`/`&`/`|` 是 5.3+），移位写法会直接语法错误，
--      这正是当初退化成多项式哈希的原因。现在用等价乘法式，两种写法
--      已在 Python 侧交叉验证结果一致。
--   数值安全性：h < 2^32 时 h*65599 < 2^48，远小于 Lua 双精度的 2^53 精确上限。
function G.hash(s)
    if type(s) ~= "string" then return 0 end
    local h = 0
    for i = 1, #s do
        h = (s:byte(i) + h * 65599) % 4294967296
    end
    return h
end

-- smallhash：同样是 C++ 全局（usercommands.lua 用它给命令编号）。
-- 宿主用**完整的 sdbm 哈希**而不是截断到 16 位：
--   · 它的全部用法都是「进程内表键」—— usercommands.lua:524 写入、
--     :120-126 读取，两边都过 smallhash，自洽即可；
--   · 截断会让不同命令因低 16 位相同而**静默合并**（`getcommandfromhash`
--     会返回错的命令），用完整哈希则无损。
-- ⚠️ 真实引擎里它还参与网络投票（TheNet:StartVote），宿主不联网，
--    所以「值与引擎不一致」不影响任何可观察行为。
function G.smallhash(s)
    return G.hash(s)
end

-- TheInput:PlatformUsesVirtualKeyboard()：chatinputscreen.lua:15 在**顶层**
-- 就调用它（`local use_virtual_keyboard = TheInput:PlatformUsesVirtualKeyboard()`），
-- 所以 TheInput 必须已经有这个方法，不能等惰性兜底。
do
    local TI = rawget(G, "TheInput") or _G.TheInput
    if type(TI) == "table" then
        TI.PlatformUsesVirtualKeyboard = function() return false end
    end
end

G.ThePlayer = nil             -- 宿主暂无玩家实体
-- ★★ TheFocalPoint 的语义要跟原版一致：**它是「玩家实体」，不是一张假表。**
--
--   原版 main.lua:330 `TheFocalPoint = nil`，玩家进来后才指向玩家实体
--   （所以 lightning.lua:9 会显式判 `TheFocalPoint == nil`）。
--   而 caveweather.lua:211/214 与 actions.lua:6339 是**无条件**调
--       TheFocalPoint.SoundEmitter:KillSound/PlaySound(...)
--   ⇒ 服务端一旦进入洞穴天气 / 玩家点错东西，TheFocalPoint 必须是**真实实体**。
--
--   宿主先前造了张 `{ SoundEmitter = 桩 }` 的假表：
--   好处是永不 nil（不会崩），代价是**声音永远是桩、且语义与原版不符**。
--   改成忠实语义：初始 nil（与 main.lua 一致），场景里创建了玩家就绑上去。
--   在没有玩家的入口（full/batch 等）它保持 nil —— 这才是原版行为。
G.TheFocalPoint = nil
-- 提供一个显式绑定入口，避免场景直接写全局（写全局也行，但要走这个函数
-- 才能顺手校验「这确实是带 SoundEmitter 的实体」）。
-- ★★★ 这里**必须同时写 `_G`** —— 否则绑定「看起来成功、实际无效」。
--
--   成因（本项目已经在这个坑上栽了两次）：
--     05_bootstrap.lua:26-27 是 **一次性拷贝**
--         for k, v in pairs(G) do _G[k] = v end
--     所以 bootstrap 之后 **`G.X` 与 `_G.X` 是两个互不相干的绑定**：
--     之后写 `G.TheFocalPoint = x` 并**不会**更新 `_G.TheFocalPoint`；
--     而游戏代码（caveweather.lua / actions.lua / lightning.lua）读的是
--     `TheFocalPoint`，也就是 `_G.TheFocalPoint` ⇒ 永远是旧值。
--
--     第一次是 PrefabExists：我写 `G.Prefabs` 而它恒 nil
--       （PrefabExists 因此自打加上起就永远返回 false）。
--     第二次就是这里：SetFocalPoint 写 G.*、游戏读 _G.*。
--
--   ⇒ 凡是**运行时会被改写**的全局，都必须写 `_G`（或两处都写）。
--     只有「启动期一次性定义」的全局才可以用 G.* 了事。
function G.SetFocalPoint(inst)
    local v = nil
    if inst ~= nil and inst.SoundEmitter ~= nil then
        v = inst
    end
    -- 两处都写：G.* 保持文件内自洽，_G.* 才是游戏真正读的那一份
    G.TheFocalPoint = v
    _G.TheFocalPoint = v
    if v == nil then
        if inst ~= nil then
            return false, "实体无 SoundEmitter，不能作为 TheFocalPoint"
        end
        return false
    end
    return true
end
G.TheItems = {}
-- ★★ TheCamera 不能是泛化桩（was `Core.MakeStub("TheCamera")`）。
--
--   症状：砍树 workleft 15→0（**砍本身成功了**），但收尾回调里炸在
--       evergreens.lua:518  attempt to call method 'GetRightVec' (a nil value)
--   真正的错误其实更早：evergreens.lua:514
--       inst.components.lootdropper:DropLoot(pt - TheCamera:GetRightVec())
--   泛化桩对未知方法**返回 nil** ⇒ `pt - nil` ⇒ 整条收尾链断掉。
--
--   为什么该有真实现：跟随相机（cameras/followcamera.lua）在
--   **服务端也存在**，而且 prefabs 里至少 4 个文件（ancienttrees / boat /
--   boat_cannon / carnivalgame_golfball）无条件引用它。
--   按 followcamera.lua:104-112 的原实现给全：
--       GetRightVec: heading + 90° → (cos, 0, sin)
--       GetDownVec : heading      → (cos, 0, sin)
--   headless 没有真实相机，heading 取 0（默认值）⇒
--   GetRightVec() = (cos90°, 0, sin90°) = (0, 0, 1)
--   —— 即掉落物沿 Z 轴偏一格，正是原版「掉落物落在树的一侧」的效果。
G.TheCamera = {
    _headingtarget = 0,          -- 度；无真实相机时保持 0
    _pos = { x = 0, y = 0, z = 0 },
}
G.TheCamera.GetHeadingTarget = function(self) return self._headingtarget end
-- ★★ GetHeading —— 与 GetHeadingTarget 是**两个不同的东西**，别合并。
--   原版 followcamera.lua:328 `function FollowCamera:GetHeading() return self.heading end`
--   而 :332 `GetHeadingTarget()` 返回 `self.headingtarget`（目标值）。
--   宿主原先只补了 Target 那一个 ⇒ `GetHeading()` 落到泛化桩上返回 nil。
--
--   实测症状（可达性抽样，`prefabs/miasma_cloud_fx.lua:120`）：
--       local heading = TheCamera:GetHeading()      -- nil
--       _OldHeading_cos = math.cos(_OldHeading * DEGREES)   -- 在 OnInit 里先算过一次
--       local ox, oz = _OldHeading_cos * MIASMA_PARTICLE_RADIUS, ...
--       ✘ attempt to perform arithmetic on local 'cur_intensity' 类错误（乘法拿到 nil）
--     ⇒ 有毒雾云特效的预制体生成不出来。
--   ★ 单位是**度**（原版 normalize 到 [0,360)），调用方自己乘 DEGREES 转弧度 ——
--     `miasma_cloud_fx.lua:117 math.cos(_OldHeading * DEGREES)` 可证。
--     宿主没有真实相机，朝向恒为初始值 0 度。
G.TheCamera.GetHeading = function(self) return self._headingtarget end
G.TheCamera.SetHeadingTarget = function(self, v) self._headingtarget = v or 0 end
G.TheCamera.GetRightVec = function(self)
    local right = math.rad(self._headingtarget + 90)
    return G.Vector3(math.cos(right), 0, math.sin(right))
end
G.TheCamera.GetDownVec = function(self)
    local h = math.rad(self._headingtarget)
    return G.Vector3(math.cos(h), 0, math.sin(h))
end
G.TheCamera.GetUpVec = function(self) return G.Vector3(0, 1, 0) end
G.TheCamera.GetWorldPoint = function(self) return self._pos end
G.TheCamera.GetFocusPoint = function(self) return self._pos end
G.TheCamera.SetWorldPoint = function(self, x, y, z) self._pos = { x = x or 0, y = y or 0, z = z or 0 } end
G.TheCamera.SetFocusPoint = G.TheCamera.SetWorldPoint
-- 其余未实现的方法仍走泛化桩（不静默：MakeStub 会记桩调用）
do
    local gen = Core.MakeStub("TheCamera")
    setmetatable(G.TheCamera, {
        __index = function(t, k)
            local v = rawget(t, k)
            if v ~= nil then return v end
            return gen[k]      -- 缺的方法仍返回桩（并记桩调用），不静默吞掉
        end,
    })
end

--=========================================================================
-- TUNING：数值表。宿主只放「原版脚本确实会读到的键」，
-- 缺的键由 metatable 兜底并记缺口。
--=========================================================================
local TUNING_DEFAULTS = {
    -- 通用
    TOTAL_DAY_TIME = 480,
    SEG_TIME = 30,
    TINY_FUEL = 15,
    MED_FUEL = 30,
    LARGE_FUEL = 60,
    -- pighouse 相关
    PIGHOUSE_SPAWN_TIME = 60,
    PIGHOUSE_ENABLED = true,
    -- 通用结构物
    MEDIUM_BURNABLE_HIBERNATE = 5,
    MEDIUM_PROPAGATOR_RANGE = 6,
    LARGE_PROPAGATOR_RANGE = 9,
    HAUNT_INSTANT_REZ = 0,
    HAUNT_COOLDOWN_TINY = 20,
    HAUNT_COOLDOWN_SMALL = 30,
    HAUNT_COOLDOWN_MEDIUM = 60,
    HAUNT_COOLDOWN_LARGE = 90,
    HAUNT_CHANCE_ALWAYS = 1,
    HAUNT_CHANCE_OFTEN = 0.75,
    HAUNT_CHANCE_SOMETIMES = 0.5,
    HAUNT_CHANCE_RARE = 0.25,
    HAUNT_CHANCE_VERYRARE = 0.1,
    HAUNT_CHANCE_ALMOSTNEVER = 0.02,
    HAUNT_MIN_PERCENT = 0.25,
    HAUNT_MAX_PERCENT = 0.75,
    LUNARHAIL_BUILDUP_LARGE = 2,
    -- 生存数值（三个量表，已深度注释）
    HUNGER_RATE = 1,
    SANITY_RATE = 1,
    STARTING_TEMP = 20,
    FREEZING_TEMP = 0,
    OVERHEAT_TEMP = 70,
    -- 时间
    CAVE_DAY_TIME = 480,
    NIGHT_TIME = 60,
    DUSK_TIME = 30,
    -- 世界
    SNOW_THRESHOLD = 0.05,
    MOONPHASE_LENGTH = 2,
}

G.TUNING = setmetatable({}, {
    __index = function(t, k)
        if TUNING_DEFAULTS[k] ~= nil then return TUNING_DEFAULTS[k] end
        -- 原版 tuning.lua 有 9581 行、41 个分区；宿主只带最常用键。
        -- 缺键返回 0 而非 nil：DST 的 TUNING 值绝大多数是数值，
        -- 返回 nil 会让 math.min/max 之类的运算直接崩（实测踩到），
        -- 返回 0 能让流程继续走完，同时缺口已记录、事后可精确补齐。
        Core.NoteGap("TUNING." .. tostring(k), "index")
        return 0
    end,
})

--=========================================================================
-- ACTIONS：动作注册表。宿主提供最常用的几个。
--=========================================================================
local ACTIONS = {}
G.ACTIONS = ACTIONS

local function make_action(name)
    local a = { id = name, str = name, code = name }
    function a:GetActionType() return self.id end
    return a
end

for _, name in ipairs({
    "HAMMER", "CHOP", "MINE", "REMOVELUNARBUILDUP", "DIG", "TERRAFORM",
    "TERRAFORM_REMOVE", "PICKUP", "PICK",
    "ATTACK", "EAT", "COOK", "GIVE", "TALK", "WALKTO",
    "BUILD", "DEPLOY", "PLANT", "HARVEST", "FERTILIZE",
    "ACTIVATE", "BLANK", "READ", "SLEEPIN",
    "EXTINGUISH", "SHAVE", "REPAIR", "NET", "CATCH",
    "FISH", "POLLINATE", "CASTAOE", "RUMMAGE", "CHECKTRAP",
}) do
    ACTIONS[name] = make_action(name)
end

-- ★ ACTIONS 惰性自建：DST 有 100+ 个动作，宿主只列了常用的。
--   finiteuses.lua:30 `self.consumption[ACTIONS.REMOVELUNARBUILDUP]` 这类写法
--   一旦键缺失就会 `table index is nil` 直接崩。惰性表让任意键都返回
--   一个合法动作对象，语义上等价于「该动作存在但宿主不实现其行为」。
setmetatable(ACTIONS, {
    __index = function(t, k)
        if type(k) ~= "string" or k:match("^_") then return nil end
        local a = make_action(k)
        rawset(t, k, a)
        return a
    end,
})

--=========================================================================
-- 平台判断全局（constants.lua:186 等大量引用）
-- 宿主是 Windows 桌面，全部返回 false，让原版走「非主机/非主机平台」分支。
-- ⚠️ 这些必须是**函数**：原版写法是 `IsConsole() and 70 or -1`，
--    若返回 0 这种不可调用值，直接 "attempt to call global (a number value)"。
--=========================================================================
local PLATFORM_FNS = {
    -- ★★★ 这份清单原先是我**手抄**的，实测**抄错了**：
    --   缺了原版真有的 `IsPS4 / IsPS5 / IsPSN / IsXB1 / IsWin32`，
    --   却多出 `IsSteamDeckGame / IsPlayStation / IsXbox / IsSwitch /
    --   IsNintendo / IsOSX / IsBBB / IsTestBuild / IsDevBuild / IsCTV`
    --   这些**原版根本没有**的名字（凭空捏的）。
    --
    --   实测症状：`languages/loc.lua:23` 第一句就是 `IsXB1()` ⇒
    --     ✘ attempt to call global 'IsXB1' (a nil value)
    --     ⇒ 整个 `loc.lua` 加载失败 ⇒ `LOC` 为 nil ⇒
    --       `prefabs/hermitcrab.lua:1915 LOC.GetTextScale()` 崩。
    --
    --   ⇒ 下面这 5 个补齐，并且**再加一道自动提取兜底**（见后面那段）：
    --     从真实 main.lua 里扫 `function IsXxx()` 全集，缺哪个补哪个。
    --     这是本工程第 N 次用「源码提取」替代「凭印象列清单」——
    --     sg 方法表、prefabskin 全局表、渲染管理器、到这次的平台函数。
    "IsConsole", "IsNotConsole", "IsPS4", "IsPS5", "IsPSN", "IsXB1",
    "IsSteam", "IsLinux", "IsRail", "IsSteamDeck", "IsWin32",
    -- 下面这些原版没有，但宿主别处可能已引用；一并保留（返回 false 无害）
    "IsSteamDeckGame", "IsPlayStation",
    "IsXbox", "IsSwitch", "IsNintendo", "IsOSX", "IsWindows",
    "IsAndroid", "IsIOS", "IsMobile", "IsBBB", "IsTestBuild",
    "IsDevBuild", "IsCTV",
}
for _, fn in ipairs(PLATFORM_FNS) do
    G[fn] = function() return false end
end
G.IsWindows = function() return true end
G.IsWin32 = function() return true end     -- 宿主跑在 Windows 上

-- ★★ 平台函数**自动补齐**（从真实 main.lua 静态提取）
--   为什么还要这道：上面那份清单再怎么补也只是「这一刻抄对了」。
--   直接扫原版 `function IsXxx()` 全集，缺的补成 false，
--   并记进缺口清单（不静默）——这样以后换版本也自动跟上。
do
    local path = Core.SourceDir .. "/main.lua"
    local f = io.open(path, "r")
    if f ~= nil then
        local src = f:read("*a")
        f:close()
        local found, added = 0, {}
        for name in src:gmatch("function%s+(Is[A-Za-z0-9_]+)%s*%(%s*%)") do
            found = found + 1
            if rawget(G, name) == nil then
                G[name] = function() return false end
                added[#added + 1] = name
            end
        end
        G.__PLATFORM_FNS_FOUND = found
        G.__PLATFORM_FNS_ADDED = added
        if #added > 0 then
            -- ★ 提取到的名字里若有**没预料到**的，记进缺口清单供报告引用
            Core.NoteGap("平台函数自动补齐: " .. table.concat(added, ","),
                         "main.lua 静态提取")
        end
    else
        Core.NoteGap("平台函数自动提取: 打不开 main.lua", "platform-fns")
    end
end

--=========================================================================
-- ★ PLATFORM：**字符串**全局（不是函数！），真实引擎里是平台名
--=========================================================================
-- 用途（全是直接比较，不调用）：
--   cookbookdata.lua:8 / craftingmenuprofile.lua:8
--       local USE_SETTINGS_FILE = PLATFORM ~= "PS4" and PLATFORM ~= "NACL"
--   config.lua:74   if platform_overrides[PLATFORM] then ...
--
-- ★ 为什么必须给字符串：万能兜底返回的是**万能对象**，
--   而它的 __eq 是 rawequal → `PLATFORM ~= "PS4"` 恒真（碰巧对了），
--   但 `platform_overrides[PLATFORM]` 会拿对象当表键 → 永远取不到。
--   给出真值后行为与原版一致：
--   config.lua 的 platform_overrides 只有 NACL / ANDROID / IOS 三个键，
--   没有 WIN → `platform_overrides["WIN"]` 为 nil → 不调 SetOptions（正确）。
G.PLATFORM = "WIN"

--=========================================================================
-- ★ package.assetpath —— 引擎登记的**资源搜索路径列表**
--=========================================================================
--   实测症状（可达性抽样 N=3000 才抽到）：`prefabs/minimap.lua:42`
--       inst.MiniMap:AddAtlas(resolvefilepath("minimap/minimap_data1.xml"))
--     → util.lua:640 resolvefilepath
--     → util.lua:623 resolvefilepath_internal
--     → util.lua:607 `for i, pathdata in ipairs_reverse(searchpaths)`  ← searchpaths = nil
--     → util.lua:219 `return reverse_next, t, #t`   ✘ 取 nil 的长度
--
--   `package.assetpath` 是**引擎**塞进 `package` 表的（`util.lua:606` 直接读它），
--   宿主从没提供。给空表 = 「没有任何额外资源路径」，
--   `resolvefilepath` 随后的两条回退（`kleifileexists(filepath)` → `return nil`）
--   会正常走完 ⇒ 返回 nil，而 `MiniMap:AddAtlas(nil)` 是代理接得住的。
--
--   ★ 语义边界（如实标注）：宿主**实现了资源解析的文件系统**吗？没有。
--     `kleifileexists` 是桩 ⇒ 这里恒返回 nil。所以 minimap 的图集
--     「解析不出路径」，但**不会崩**。真实图集数据由浏览器播放器那条链路
--     （直接用本项目导出的 atlas_index / anim_data）负责。
if type(package) == "table" and package.assetpath == nil then
    package.assetpath = {}
end

--=========================================================================
-- ★★ kleifileexists(filepath[, manifest, original]) —— 引擎的「资源文件存在吗」
--=========================================================================
--   它是 `util.lua` 资源解析链的**最后一道实际判据**：
--       util.lua:601/609/615  kleifileexists(...)
--   宿主从没提供 ⇒ `resolvefilepath` 一路走到 util.lua:615 直接
--       ✘ attempt to call global 'kleifileexists' (a nil value)
--   （可达性抽样 N=3000 才抽到，`prefabs/minimap.lua:42`）
--
--   ★ 这里**不做桩**：宿主手上就有游戏数据目录，检查文件是否真的存在是
--     完全可做且**应当真做**的事。返回假值会让 `resolvefilepath` 静默失配，
--     而那是「宿主不知道」伪装成「文件不存在」—— 本工程明确禁止这种伪装。
--
--   语义对齐：
--     · 引擎的 filepath 是**相对 data/ 的虚拟路径**（如 minimap/minimap_data1.xml）
--     · 目录可用环境变量 `DST_DATA_DIR` 覆盖（换安装位置/换机器时用）
--     · 第二个参数 manifest 是「包内清单」语义，宿主不做打包，
--       所以只它能回答的那部分（**已落到磁盘的路径**）——如实标注
--     · 结果**带缓存**（`resolvefilepath` 每次都会调，不缓存会很慢）
--
--   ⚠️ 诚实边界：目录不存在 ⇒ 一律返回 false，并**计数**（可观测），
--      不是静默 false。计数到 0 说明路径配对了。
G.DST_DATA_DIR = os.getenv("DST_DATA_DIR")
    or "D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/data"
G.__kleifileexists = { hit = 0, miss = 0, queries = 0, dir_ok = nil }

do
    -- ★ 探测文件要选**确定存在**的：`data/scripts/scripts/util.lua` **不存在**
    --   （脚本在 databundles/scripts.zip 里）—— 我第一版就拿它当探针，
    --   于是 dir_ok 恒为 false，断言误报「数据目录不可用」。
    --   ⇒ 换用本项目导出图集索引时已经读过的那份散件。
    local probe = io.open(G.DST_DATA_DIR .. "/minimap/minimap_data1.xml", "rb")
    if probe ~= nil then probe:close() end
    G.__kleifileexists.dir_ok = (probe ~= nil)
end

local _kfe_cache = {}
function G.kleifileexists(filepath, manifest, originalpath)
    G.__kleifileexists.queries = G.__kleifileexists.queries + 1
    if type(filepath) ~= "string" then
        G.__kleifileexists.miss = G.__kleifileexists.miss + 1
        return false
    end
    local c = _kfe_cache[filepath]
    if c ~= nil then
        if c then G.__kleifileexists.hit = G.__kleifileexists.hit + 1
        else G.__kleifileexists.miss = G.__kleifileexists.miss + 1 end
        return c
    end
    local p = filepath:gsub("\\", "/")
    if p:sub(1, 1) == "/" then p = p:sub(2) end
    local f = io.open(G.DST_DATA_DIR .. "/" .. p, "rb")
    local ok = false
    if f ~= nil then f:close(); ok = true end
    if not ok then
        -- 退化：也接受「调用方给的就是可直接打开的真实路径」
        local f2 = io.open(filepath, "rb")
        if f2 ~= nil then f2:close(); ok = true end
    end
    _kfe_cache[filepath] = ok
    if ok then G.__kleifileexists.hit = G.__kleifileexists.hit + 1
    else G.__kleifileexists.miss = G.__kleifileexists.miss + 1 end
    return ok
end

--=========================================================================
-- ★ CHEATS_ENABLED：**布尔**全局 —— 这条原先是个真 bug
--=========================================================================
-- 万能兜底返回的是万能**对象**，在 Lua 里是 **truthy**：
--   debugtools.lua:255   if not (CHEATS_ENABLED and CHEATS_ENABLE_DPRINT) then
--     → 桩下 `CHEATS_ENABLED` 为真 → `not (true and ...)` 整个调试门被关掉
--   health.lua:166       if CHEATS_ENABLED then  -- 客户端可视化 godmode tag
--     → 桩下会走进「给客户端加 invincible 标签」的分支
-- 正式版里它是 false。这里给 false，让这两处回到原版语义。
G.CHEATS_ENABLED = false
-- 作弊相关的配套开关（debugtools.lua:255 用到）
G.CHEATS_ENABLE_DPRINT = false
G.CHEATS_ENABLE_PROFILER = false

--=========================================================================
-- ★ ClientSideInventoryImageFlags —— 客户端背包图集换图的全局开关表
--=========================================================================
-- entityscript.lua:5042 的 SetClientSideInventoryImageOverride 往里写、
-- :2072 的 SetClientSideInventoryImageOverrideFlag 往里读。
-- 宿主无客户端 UI，给一张空表让「注册映射」与「查映射」两条路都能走通
-- （语义与原版一致：flag 没开 → 查询返 nil）。
G.ClientSideInventoryImageFlags = {}

--=========================================================================
-- ★ SerializeInherentActions —— 同步「固有动作」表给客户端（C++ 全局）
--=========================================================================
-- entityscript.lua:1061 AddInherentAction 末尾调用。
-- 宿主无网络层，登记一次调用便于诊断即可（不静默吞）。
--
-- ⚠️ 计数必须写进 **_G** 而不是模块表 G：
--   05_bootstrap.lua:26 是 `for k, v in pairs(G) do _G[k] = v end` ——
--   **按值拷贝**，不是共享绑定。写在 G 上会停在初始值，
--   而外部（含 DST 原版代码）从 _G 读，永远看不到变化。
G.__SerializeInherentActionsCalls = 0
function G.SerializeInherentActions(inst)
    _G.__SerializeInherentActionsCalls = (_G.__SerializeInherentActionsCalls or 0) + 1
    local n = 0
    if inst and type(inst.inherentactions) == "table" then
        for _ in pairs(inst.inherentactions) do n = n + 1 end
    end
    return n
end

--=========================================================================
-- 数学/通用常量（真实引擎在 constants.lua 与 util.lua 里定义）
-- 这几个是 tuning.lua 实测引用到的（用契约发现模式扫出来）
--=========================================================================
G.RADIANS = math.pi / 180
G.DEGREES = 180 / math.pi
G.PI = math.pi
G.TWOPI = math.pi * 2
G.HALFPI = math.pi / 2
G.EPSILON = 1e-6
G.FRAME_TIME = 1 / 30
G.TINY = 1e-6
G.ENTITY_POPOUT_RADIUS = 0.5
G.PLAYER_CAMERA_SEE_DISTANCE = 30

--- DiffAngle：两角之差（处理 ±360° 环绕）—— combat.lua 的扇形判定要用
function G.DiffAngle(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end

--- anglediff：另一个常用形式
function G.anglediff(a, b)
    return G.DiffAngle(a, b)
end

--- math 扩展（原版 util.lua 往 math 表上加的）
function math.sign(x)
    return x > 0 and 1 or (x < 0 and -1 or 0)
end
function math.clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
end
function math.lerp(a, b, t)
    return a + (b - a) * t
end
function math.round(x)
    return math.floor(x + 0.5)
end
function math.RemapNumber(v, inMin, inMax, outMin, outMax)
    return outMin + (v - inMin) * (outMax - outMin) / (inMax - inMin)
end
function math.Remap(v, inMin, inMax, outMin, outMax)
    return math.RemapNumber(v, inMin, inMax, outMin, outMax)
end
function math.RemapNumberClamped(v, inMin, inMax, outMin, outMax)
    local t = math.clamp((v - inMin) / (inMax - inMin), 0, 1)
    return outMin + t * (outMax - outMin)
end

--=========================================================================
-- 高频全局常量/表（batch 测试实测缺失，按频次补）
--=========================================================================

-- 部署间距（deployer / placer 用）
G.DEPLOYSPACING = {
    DEFAULT = 1.2,
    NONE = 0,
    MEDIUM = 1.5,
    LARGE = 2.0,
    HUGE = 3.0,
    PLACER_DEFAULT = 0.5,
}

-- 占居者类型（birdcage 等容器用）
G.OCCUPANTTYPE = {
    BIRDS = "birds",
    RABBITS = "rabbits",
    MOLE = "mole",
    SPIDERS = "spiders",
}

-- 季节枚举
G.SEASONS = {
    AUTUMN = "autumn",
    WINTER = "winter",
    SPRING = "spring",
    SUMMER = "summer",
    CAVES = "caves",
    LUSH = "lush",
}

-- 动画朝向枚举
G.ANIM_ORIENTATION = {
    Default = 0,
    BillBoard = 1,
    BillBoard_Y = 2,
    TwoFaced = 3,
    FourFaced = 4,
    SixFaced = 5,
    EightFaced = 6,
    Ground = 7,
    Inverted = 8,
}

-- 本地化表：真实引擎由 strings.lua + 各语言包填充（18,822 行）。
-- 宿主做成「任意键返回键名本身」的惰性表 —— 语义正确
-- （取不到译文时退回键名），且不会因缺失而崩。
local STRINGS_MT = {
    __index = function(t, k)
        if type(k) ~= "string" then return nil end
        local v = tostring(k)
        rawset(t, k, v)
        return v
    end,
}
G.STRINGS = setmetatable({
    CHARACTERS = setmetatable({}, STRINGS_MT),
    NAMES = setmetatable({}, STRINGS_MT),
    ACTIONS = setmetatable({}, STRINGS_MT),
    UI = setmetatable({}, STRINGS_MT),
}, STRINGS_MT)

-- 其他高频全局
G.INVERTED_SIGNS = { -1, 1 }
G.LEVEL_CATEGORY = { OCEAN = 1, CAVE = 2, RUINS = 3, ADVENTURE = 4 }
-- WORLD_TILES：真实 constants.lua 只有 INVALID=65535，
-- 其余（RIFT_MOON / LUNAR_MARSH / OCEAN_ICE / SHADOW_MARSH…）由地图生成时写入。
-- player_common.lua:2676 直接用 `WORLD_TILES.RIFT_MOON` 当表键
-- （areaaware.lua:115 `{ [tile_id] = false }`），键为 nil 会 "table index is nil"。
-- 所以改成惰性自增：任意键都能拿到一个稳定的数字。
do
    local nextid = 100
    G.WORLD_TILES = setmetatable({ INVALID = 65535 }, {
        __index = function(t, k)
            if type(k) ~= "string" or k:match("^_") then return nil end
            local id = nextid
            nextid = nextid + 1
            rawset(t, k, id)
            return id
        end,
    })
end
G.GROUND = setmetatable({}, { __index = function() return 0 end })
G.EMPTY_TABLE = {}

--=========================================================================
-- 组件构造期引用的全局表（compdiag 实测）
--=========================================================================

-- moisture.lua:61 / 各处速率缩放
G.RATE_SCALE = {
    NEUTRAL = 1,
    SLOW = 0.5,
    FAST = 2,
}

-- fueled.lua:63 —— 燃料类型
G.FUELTYPE = {
    BURNABLE = "burstable",
    CAVE = "cave",
    CHEMICAL = "chemical",
    ELEC = "electric",
    MAGIC = "magic",
    MECHANICAL = "mechanical",
    NONE = "none",
    ONEMANBAND = "onemanband",
    ORGANIC = "organic",
    PLANT = "plant",
    PUMPKIN = "pumpkin",
    PUREDARKNESS = "puredarkness",
    SPORE = "spore",
    TAR = "tar",
    WORMLIGHT = "wormlight",
    USAGE = "usage",
}

-- equippable.lua:29 —— 装备槽位
G.EQUIPSLOTS = {
    HANDS = "hands",
    HEAD = "head",
    BODY = "body",
    BEARD = "beard",
    AMULET = "amulet",
    BACK = "back",
    NECK = "neck",
    WAIST = "waist",
    TALISMAN = "talisman",
}

-- inventory.lua:47 —— 最大槽位数
function G.GetMaxItemSlots()
    -- 原版按角色/模式不同；默认 15（DST 玩家背包上限）
    return 15
end

-- 特殊事件查询（goldnugget 等）
function G.IsSpecialEventActive(evt)
    return false
end

--=========================================================================
-- ★ netvar 族 —— DST 网络变量系统（884 处调用）
--   net_bool(320) net_tinybyte(195) net_float(99) net_event(85)
--   net_smallbyte(82) net_byte(59) net_string(52) net_ushortint(34)
--   net_hash(30) net_uint(7) net_shortint(7) net_int(1)
--
-- 用法：net_bool(inst.GUID, "floater._is_landed", "landeddirty")
--   返回一个 netvar 对象，支持 :value() 读、:set(v)/:set_local(v) 写。
--
-- 宿主实现要点：
--   · **声明顺序即 wire format**（bug-patterns B1）—— 所以必须按声明顺序
--     分配索引，且索引要在 GUID 上保持稳定
--   · :set_local() 的代价是「服务端下次 set 必定重发」（bug-patterns B2），
--     这是 DST 利用脏值检测做纠偏的机制，不是缺陷
--   · 宿主无网络，退化为「本地变量 + 脏标记」，但契约形状保持一致
--=========================================================================
local NetVarRegistry = {}   -- guid -> { index -> netvar }
G.NetVarRegistry = NetVarRegistry

local function make_netvar(guid, name, event, default)
    local reg = NetVarRegistry[guid]
    if not reg then
        reg = { order = {}, byname = {} }
        NetVarRegistry[guid] = reg
    end
    -- 同一个 name 重复声明要返回同一个对象（原版如此）
    if reg.byname[name] then return reg.byname[name] end

    local idx = #reg.order + 1
    local nv = {
        _guid = guid, _name = name, _event = event,
        _index = idx, _value = default, _dirty = false,
        _local = false,
    }
    function nv:value() return self._value end
    function nv:set(v)
        self._value = v
        self._dirty = true
        if self._event then
            local ent = Core.Spawned[guid]
            if ent then ent:PushEvent(self._event, v) end
        end
    end
    function nv:set_local(v)
        self._value = v
        self._local = true
        self._dirty = true
    end
    function nv:is_local() return self._local end
    function nv:GetIndex() return self._index end

    reg.order[idx] = nv
    reg.byname[name] = nv
    return nv
end

local NETVAR_DEFAULTS = {
    net_bool = false, net_tinybyte = 0, net_smallbyte = 0, net_byte = 0,
    net_ushortint = 0, net_shortint = 0, net_int = 0, net_uint = 0,
    net_float = 0, net_string = "", net_hash = 0,
}

for fname, default in pairs(NETVAR_DEFAULTS) do
    G[fname] = function(guid, name, event)
        Core.NoteStub(fname, "netvar")
        return make_netvar(guid, name, event, default)
    end
end

-- net_event 形状不同：它本身就是事件通道，不承载值
G.net_event = function(guid, name, event)
    Core.NoteStub("net_event", "netvar")
    return make_netvar(guid, name, event, nil)
end

--=========================================================================
-- ★ GetTemperatureAtXZ：temperature.lua:331 用它算环境温度，
--   返回值直接参与后续算术（367 行）。缺了会让 ambient_temperature 变 nil。
function G.GetTemperatureAtXZ(x, z)
    local Sim = require("host.02_sim")
    local base = Sim.World.state.temperature or 20
    -- 简易季节偏移：纬度越高越冷。宿主无季节模型，只给一个确定的函数
    return base - math.floor((z or 0) / 10) * 0.5
end

-- ★ simutil.lua:67 的 FindClosestPlayerInRange 会调 IsEntityDeadOrGhost。
--   玩家实体接上后这条路径才第一次被真实执行到。
function G.IsEntityDeadOrGhost(inst)
    if not inst then return false end
    -- ⚠️ 真实的 health 组件没有 IsGhost() 方法（只有 IsDead），
    --   所以这里只探测确定存在的方法，避免 "attempt to call method" 打断整条链。
    local h = inst.components and inst.components.health
    if h and type(h.IsDead) == "function" and h:IsDead() then return true end
    if inst._dead == true or inst._ghost == true then return true end
    return false
end

-- ★ GetLocalTemperature：frostybreather.lua:85 等生存组件直接比较它的返回值。
--   万能兜底会返回 nil → "attempt to compare number with nil"。
function G.GetLocalTemperature(inst)
    local Sim = require("host.02_sim")
    if inst and inst.Transform then
        local _, _, z = inst.Transform:GetWorldPosition()
        return G.GetTemperatureAtXZ(inst.Transform:GetWorldPosition(), z)
    end
    return Sim.World.state.temperature or 20
end
function G.GetTempAtPoint(x, y, z)
    local Sim = require("host.02_sim")
    return Sim.World.state.temperature or 20
end
function G.GetSeasonTemperature() return 20 end

-- 其他组件构造期引用的全局
--=========================================================================
function G.NotifyPlayerProgress() end
function G.NotifyPlayerPresence() end
function G.ErodeAway(inst, delay)
    if inst then inst:Remove() end
end
function G.GetRandomItem() return nil end

-- sanity.lua:78 —— 理智模式（constants.lua:1234）
G.SANITY_MODE_INSANITY = 0
G.SANITY_MODE_LUNACY = 1

--=========================================================================
-- =========================================================================
-- ModManager：真实引擎的模组管理器（modindex.lua 1305 行 / modutil.lua 1015 行）
-- 宿主不实现模组系统，但 stategraph.lua:289 等会调它，所以给最小桩。
-- 8 个方法全部返回「空集合」语义 —— 没有模组就是没有模组，语义正确。
-- =========================================================================
G.ModManager = {
    GetPostInitData = function() return {} end,
    GetPostInitFns = function() return {} end,
    GetPostInitTables = function() return {} end,
    GetEnabledModNames = function() return {} end,
    GetEnabledServerModNames = function() return {} end,
    GetMod = function() return nil end,
    GetModRecords = function() return {} end,
    GetLinkForMod = function() return nil end,
    FrontendLoadMod = function() return true end,
    FrontendUnloadMod = function() return true end,
    DisableAllServerMods = function() end,
    DisplayBadMods = function() end,
    GetPersistentMods = function() return {} end,
}

-- 空间查询/传送判定（simutil.lua 与大量 spawner 逻辑引用）
-- 宿主无真实地图，判定一律「允许」，让生成流程走通。
-- ==========================================================================
function G.IsTeleportingPermittedFromPointToPoint(x1, y1, z1, x2, y2, z2)
    return true
end
function G.IsTeleportingPermitted(x, y, z) return true end
function G.IsEntityInWater(entity) return false end
function G.IsShore(entity) return false end
function G.IsSwimmable(x, z) return true end
function G.IsInWater(x, z) return false end
function G.GetWaterDepth(x, z) return 0 end
function G.FindNearestTile(x, y, z) return 0 end
function G.IsOceanShallowAt(x, z) return false end
function G.IsCaveAt(x, y, z) return false end
function G.GetClosestUsableTile(x, y, z) return 0 end
function G.NoiseGetter() return 0 end
function G.IsTurfBlocked(x, y, z) return false end
function G.IsTileOccluded() return false end
function G.PointInAnyCollisionWithWorld() return false end
function G.ErodeAway(inst, delay)
    if inst then inst:Remove() end
end

-- age.lua:16 / autosaver.lua:54 —— 分片存档索引（宿主无分片，给最小桩）
G.ShardGameIndex = {
    GetGameMode = function() return "survival" end,
    GetSlot = function() return 1 end,
    SaveCurrent = function() return true end,
    GetCurrentSaveName = function() return "" end,
}

--=========================================================================
-- Vector3 / Quaternion —— 真实引擎的数学类型（1666 处 Vector3( 调用）
--=========================================================================
local Vector3Meta = {}
Vector3Meta.__index = Vector3Meta
Vector3Meta.__add = function(a, b)
    -- ★ P43：number ± Vector3 也要成立。原来只处理「两侧都是表」，
    --   一旦真出了 `1 - v` 这种调用，报的是 `attempt to index local 'a' (a number value)`，
    --   栈里指向的是**元方法**而不是调用点 —— 排查成本极高（这次就绕了一圈）。
    --   原版 Vector3 是 C++ 类，标量加减是支持的；这里对齐，并让错误信息说人话。
    if type(a) == "number" then return G.Vector3(a + b.x, a + b.y, a + b.z) end
    if type(b) == "number" then return G.Vector3(a.x + b, a.y + b, a.z + b) end
    return G.Vector3(a.x + b.x, a.y + b.y, a.z + b.z)
end
Vector3Meta.__sub = function(a, b)
    if type(a) == "number" then return G.Vector3(a - b.x, a - b.y, a - b.z) end
    if type(b) == "number" then return G.Vector3(a.x - b, a.y - b, a.z - b) end
    return G.Vector3(a.x - b.x, a.y - b.y, a.z - b.z)
end
Vector3Meta.__mul = function(a, b)
    if type(a) == "number" then
        return G.Vector3(a * b.x, a * b.y, a * b.z)
    end
    return G.Vector3(a.x * b, a.y * b, a.z * b)
end
Vector3Meta.__eq = function(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end
Vector3Meta.__tostring = function(v)
    return string.format("Vector3(%.3f, %.3f, %.3f)", v.x, v.y, v.z)
end

function G.Vector3(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vector3Meta)
end

-- ★ Vector3:Get() —— periodicspawner.lua:178 `spawnpos:Get()` 等大量处调用。
--   返回三值。这是宿主之前漏掉的，导致生物跑到 74 秒时崩。
function Vector3Meta:Get()
    return self.x, self.y, self.z
end
function Vector3Meta:GetX() return self.x end
function Vector3Meta:GetY() return self.y end
function Vector3Meta:GetZ() return self.z end
function Vector3Meta:Set(x, y, z)
    self.x, self.y, self.z = x or 0, y or 0, z or 0
end
function Vector3Meta:SetX(v) self.x = v end
function Vector3Meta:SetY(v) self.y = v end
function Vector3Meta:SetZ(v) self.z = v end
function Vector3Meta:Length()
    return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
end
function Vector3Meta:LengthSq()
    return self.x * self.x + self.y * self.y + self.z * self.z
end
function Vector3Meta:Normalize()
    local l = self:Length()
    if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end
    return self
end
function Vector3Meta:GetNormalized()
    local v = G.Vector3(self.x, self.y, self.z)
    return v:Normalize()
end
function Vector3Meta:Dot(other)
    -- ★ other 为 nil 时返回 0，而不是崩在这里。
    --   起因：砍树的收尾回调里 evergreens.lua:514 算了 `pt - TheCamera:GetRightVec()`，
    --   而 TheCamera 原先是泛化桩 ⇒ 返回 nil ⇒ `pt - nil` 崩。
    --   TheCamera 已补真实现（见上），但这里的守卫仍要留 ——
    --   **一条收尾链不该因为可选向量缺失而整条断掉**。
    --   （要追调用方时把 __VEC_DIAG 置 true，会打印 traceback）
    if other == nil then
        if __VEC_DIAG then
            print("    [VEC] Dot(nil) 栈：" .. tostring(debug.traceback("", 2):gsub("\n", " | ")))
        end
        return 0
    end
    return self.x * other.x + self.y * other.y + self.z * other.z
end
function Vector3Meta:Cross(other)
    -- other 为 nil 时返回 nil 而不是崩（理由同 Dot）。
    if other == nil then
        if __VEC_DIAG then
            print("    [VEC] Cross(nil) 栈：" .. tostring(debug.traceback("", 2):gsub("\n", " | ")))
        end
        return nil
    end
    return G.Vector3(
        self.y * other.z - self.z * other.y,
        self.z * other.x - self.x * other.z,
        self.x * other.y - self.y * other.x)
end
function Vector3Meta:Dist(other)
    local dx, dy, dz = self.x - other.x, self.y - other.y, self.z - other.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
function Vector3Meta:DistSq(other)
    local dx, dy, dz = self.x - other.x, self.y - other.y, self.z - other.z
    return dx * dx + dy * dy + dz * dz
end

local QuaternionMeta = {}
QuaternionMeta.__index = QuaternionMeta
function G.Quaternion(x, y, z, w)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0, w = w or 1 },
        QuaternionMeta)
end

--=========================================================================
-- COLLISION：碰撞组位掩码（真实引擎定义在 constants.lua）
-- Bullet 的碰撞系统按「组 × 掩码」判定，二者都是位掩码。
--=========================================================================
G.COLLISION = {
    WORLD = 1,
    OBSTACLES = 2,
    CHARACTERS = 4,
    ITEMS = 8,
    GIANTS = 16,
    SANDBAG = 32,
    FLYERS = 64,
    LIMBO = 128,
    BORDER = 256,
}

--=========================================================================
-- 常量
--=========================================================================
G.FRAMES = 1 / 30
G.CONTROL_ACTION = 1000
G.PLAYERSTUNLOCK = {}
G.SKINUNLOCKS = { ALWAYS = 1, NEVER = 2, SOMETIMES = 3 }
G.INLIMBO = 1

-- Asset() —— 真实引擎用它登记资源依赖；宿主只记录
function G.Asset(kind, path)
    return { type = kind, file = path }
end

-- MakeInventoryPhysics 等物理辅助
function G.MakeInventoryPhysics(inst) end
function G.MakeObstaclePhysics(inst, radius) end
function G.MakeCharacterPhysics(inst, mass, radius) end
function G.MakeProjectilePhysics(inst) end
function G.MakeSmallBurnable(inst) end
function G.MakeMediumBurnable(inst) end
function G.MakeLargeBurnable(inst) end
function G.MakeSmallPropagator(inst) end
function G.MakeMediumPropagator(inst) end
function G.MakeLargePropagator(inst) end
function G.MakeSnowCovered(inst) end
function G.MakeSnowCoveredPristine(inst) end
function G.MakeHauntable(inst) end
function G.MakeHauntableWork(inst) end
function G.MakeHauntableLaunch(inst) end
function G.MakeHauntableChangeGlow(inst) end
function G.MakePlacer(name, bank, build, anim) end
function G.MakeTileCold(inst) end
function G.SetLunarHailBuildupAmountSmall(inst) end
function G.SetLunarHailBuildupAmountMed(inst) end
function G.SetLunarHailBuildupAmountLarge(inst) end
function G.RemovePolarSnowCoverage(inst) end
function G.MakePlatformTemperatureBlocker(inst) end

-- 原版常用工具函数
function G.GetTime() return Sim.TheSim.time end
function G.GetTick() return Sim.TheSim.tick end
function G.GetTickTime() return Sim.TheSim.TICK_TIME end

-- ★ GetStaticTick / GetStaticTime —— scheduler.lua:21/30 的「静态时钟」
--
-- 真实引擎里这对时钟与 GetTick/GetTime 的差别是：
--   GetStaticTick() **不受暂停与加速影响**（是未被缩放的 tick 计数），
--   所以 staticScheduler 排的任务（DoStaticTaskInTime / 客户端 UI 刷新等）
--   在游戏暂停时仍会推进。
--   scheduler.lua:281 的 GetListForTimeFromNow 直接调它 —— 之前宿主没定义，
--   于是任何走 staticScheduler 的代码都炸：
--     "scheduler.lua:7: attempt to call global 'GetStaticTick' (a nil value)"
--
-- ★ 宿主里两者**重合**：Sim.TheSim.tick 每 tick 固定 +1，既没有暂停也没有
--   时间缩放（没有 DoGameFrozenTick / SetTimeScale 的真实推进路径）。
--   所以按定义直接返回同一个计数即可 —— 这是语义正确的，不是省事。
function G.GetStaticTick() return Sim.TheSim.tick end
function G.GetStaticTime() return Sim.TheSim.time end

-- ★★ toarrayornil(...) —— 变长参数「打包成数组，无参则返 nil」
--=========================================================================
-- 两处真实调用：
--   scheduler.lua:95   self.arg = toarrayornil(...)   （任务回调参数打包）
--   widget.lua:1839    self.focus_flow_args[dir] = toarrayornil(...)
--
-- ★★ 为什么要专门有这个函数：Lua 的经典陷阱。
--   widget.lua:1833-1836 的注释说得很清楚 —— 若直接写 {...}，
--   **无参时得到空表 {}，而在 Lua 里 {} 是 truthy**，
--   于是 `if self.focus_flow_args[dir] then` 会被空表骗过，
--   走进 unpack({}) 分支。语义上「没有参数」必须是 nil 而不是空表。
--
-- 之前宿主没定义它，于是任何走 staticScheduler 的代码都在
--   "scheduler.lua:53: attempt to call global 'toarrayornil' (a nil value)"
-- 直接崩 —— 而 staticScheduler 是 DoStaticTaskInTime / DoPeriodic 的底座。
G.toarrayornil = function(...)
    local n = select("#", ...)
    if n == 0 then return nil end
    local t = {}
    for i = 1, n do t[i] = (select(i, ...)) end
    return t
end
function G.GetSchedulerTime() return Sim.TheSim.time end
function G.GetSchedulerTick() return Sim.TheSim.tick end
function G.GetGameModeProperty(k) return nil end
function G.GetModConfigData(k) return nil end
function G.IsTableEmpty(t) return next(t) == nil end
function G.GetTableSize(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
function G.FunctionOrValue(v, ...)
    if type(v) == "function" then return v(...) end
    return v
end
function G.KillThread() end

-- ★ AllPlayers：simutil.lua:65 `ipairs(AllPlayers)` 等大量处直接遍历。
--   宿主暂无玩家实体，给空表让「找最近玩家」类逻辑走 nil 分支。
G.AllPlayers = {}

-- 世界实体引用（不少 prefab 直接读 WorldEnts / AllPlayers）
G.WorldEnts = setmetatable({}, { __index = function() return nil end })

--- playerprox.lua:47 等位置需要：在范围内找最近的玩家
--- 宿主暂无玩家实体，返回 nil —— 语义正确（没有玩家就该返回 nil），
--- 调用方据此走「玩家不在附近」分支，正好可以验证 playerprox 的判定逻辑。
function G.FindClosestPlayerInRange(x, y, z, range, isalive)
    Core.NoteGap("FindClosestPlayerInRange", "global")
    return nil
end
function G.FindClosestPlayerToInst(inst, range)
    Core.NoteGap("FindClosestPlayerToInst", "global")
    return nil
end
function G.GetClosestInstWithTagForComparison(tag, x, y, z, range)
    Core.NoteGap("GetClosestInstWithTagForComparison", "global")
    return nil
end
function G.TheWorldHasTag(t) return false end
function G.IsWeatherRain() return false end
function G.IsUnderRain(inst) return false end
function G.GetSeasonManager() return nil end
function G.IsWorldGen() return false end
function G.IsServer() return true end
function G.IsClient() return false end
function G.IsDLCEnabled(flag) return false end
function G.PlatformIsConsole() return false end
function G.PlatformIsSteamDeck() return false end
function G.PlatformIsLinux() return false end
function G.PlatformIsOSX() return false end
function G.PlatformIsWindows() return true end
function G.PlatformIsPlayStation() return false end
function G.PlatformIsXbox() return false end
function G.PlatformIsSwitch() return false end

-- 字符串/数值工具（原版在 util.lua，宿主直接内联常用几个）
function G.trimstring(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
function G.Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function G.Lerp(a, b, t) return a + (b - a) * t end

--=========================================================================
-- ★ 一批「到处在用、但宿主一直没定义」的全局（本次调试一次补齐）
--
-- 这些缺失以前**看不出来**：宿主从没跑过 brain/behaviour 的代码路径，
-- 一开启就立刻批量报 nil。定义全部按原版逐字对齐，方便日后核对。
--=========================================================================
-- scripts/vector3.lua:7 `Point = Vector3` —— Point 只是 Vector3 的别名
G.Point = G.Vector3
-- scripts/vector3.lua:90/104
function G.ToVector3(obj, y, z)
    if obj == nil then return nil end
    if obj.IsVector3 then return obj end
    if type(obj) == "table" then
        return G.Vector3(tonumber(obj[1]), tonumber(obj[2]), tonumber(obj[3]))
    end
    return G.Vector3(tonumber(obj), tonumber(y), tonumber(z))
end
function G.Vector3FromTheta(theta, radius)
    radius = radius or 1
    return G.Vector3(radius * math.cos(theta), 0, -radius * math.sin(theta))
end

-- scripts/util.lua:553
function G.distsq(v1, v2, v3, v4)
    if v3 ~= nil then
        -- 特例：两个二维向量以数字传入
        local dx, dy = v1 - v3, v2 - v4
        return dx * dx + dy * dy
    end
    local dx = (v1.x or v1[1]) - (v2.x or v2[1])
    local dy = (v1.y or v1[2]) - (v2.y or v2[2])
    local dz = (v1.z or v1[3]) - (v2.z or v2[3])
    return dx * dx + dy * dy + dz * dz
end

-- scripts/vecutil.lua:3-30
function G.VecUtil_Add(a, b, c, d) return a + c, b + d end
function G.VecUtil_Sub(a, b, c, d) return a - c, b - d end
function G.VecUtil_Scale(a, b, s) return a * s, b * s end
function G.VecUtil_LengthSq(x, z) return x * x + z * z end
function G.VecUtil_Length(x, z) return math.sqrt(x * x + z * z) end
function G.VecUtil_DistSq(ax, az, bx, bz)
    return (ax - bx) * (ax - bx) + (az - bz) * (az - bz)
end
function G.VecUtil_Dist(ax, az, bx, bz)
    return math.sqrt((ax - bx) * (ax - bx) + (az - bz) * (az - bz))
end

-- scripts/util.lua:550
function G.GetRandomMinMax(min, max) return min + math.random() * (max - min) end

-- 成对/范围工具（原版 util.lua / 各文件里散落，行为树里高频）
function G.IsAnyOf(t, ...)
    if t == nil then return false end
    for i = 1, select("#", ...) do
        if t == (select(i, ...)) then return true end
    end
    return false
end

--=========================================================================
-- bit：DST 注入的位运算库（LuaBitOp）
--
-- ★ 为什么必须有：DST 的 Lua 侧有 **120 个调用点**用 bit.band/bor/bxor/bnot/
--   lshift/rshift，且 components/health.lua:648 的注释明写
--   「bit.bor 是 DST 注入的位运算库提供的」。
--   而宿主此前从未提供这个全局 —— 探针实测 `rawget(_G, "bit") == nil`，
--   任何走到这些行的代码都会 "attempt to index global 'bit' (a nil value)"。
--   ⚠️ 以前没暴露，是因为这些调用多在条件分支深处（月光灼烧标志归约、
--      农场养分打包、谜题编码…），pcall 又把它们吞成了「加载失败」。
--
--   实现见 host/21_bit.lua：Lua 5.1 没有位运算符，用逐位算术实现，
--   语义对齐 LuaBitOp（32 位归一 + 有符号返回 + 逻辑移位 + 变参折叠）。
--   已用 33 例与 Python 真位运算逐条对照（见 _probe_bit.lua）。
--=========================================================================
G.bit = bitlib

--=========================================================================
-- ★ perlin(x, y, z) —— 三维 Perlin 噪声（C++ 全局的 Lua 等价物）
--=========================================================================
-- 原版 6 处直接调它，缺了会让**组件构造直接抛**：
--   worldtemperature.lua:115  温度扰动 → 构造失败 ⇒ 世界温度组件挂不上
--   weather.lua:402 / caveweather.lua:319  降雨强度
--   fumarolelocaltemperature.lua:101 / map/ocean_gen.lua:178 /
--   prefabs/floatinglantern.lua:126
-- 实现与诚实边界见 host/22_perlin.lua 的文件头。
G.perlin = require("host.22_perlin").perlin

--=========================================================================
-- ★ TheSim:AtlasContains —— 真实图集索引查询（缺了会让预制体工厂直接崩）
--=========================================================================
-- 实测症状：`preparedfoods.lua:57` → `simutil.lua:675`
--   ✘ attempt to call method 'AtlasContains' (a nil value)
--   ⇒ 12 个 `*_spice_*` 预制体 spawn 全灭（reachability.lua 抽样实证）。
-- 索引由 tools/export_atlas_index.py 从 databundles/images.zip 导出。
-- 实现与诚实边界见 host/23_atlas.lua 的文件头。
require("host.23_atlas")

--=========================================================================
-- ★ 资产加载器 —— TheSim:LoadAtlas / LoadPrefabs / LoadAnim 一族
--=========================================================================
-- 审计发现：四个接口在**全仓 0 命中**，而原版脚本有 34+22+137 处调用点。
-- 必须在 23_atlas **之后** require：它要把「已加载图集」接到 AtlasContains 前面
-- （加载过的优先，否则退回索引查询）—— 那条接线就是 LoadAtlas 有真实副作用的证据。
-- 实现与数据源见 host/28_assets.lua 的文件头。
require("host.28_assets")

--=========================================================================
-- ★ 音频事件通道 —— 让 SoundEmitter 的播放/停止有**可观测副作用**
--=========================================================================
-- 此前 SoundEmitter 只是「一张记账表」：播了什么、播了几次、什么参数，
-- 外部一概看不见（`SetVolume` 连字段都没有）。本工程**不做音频后端**，
-- 但「不出声」与「不知道发生过什么」是两件事 —— 后者会让音效回归无从下手。
-- 挂在 03_globals 尾部：此时 00_stubs 已装好（它每次调用现查 `_G.__AUDIO_SINK`）。
-- 实现与诚实边界见 host/29_audio.lua 的文件头。
require("host.29_audio")

--=========================================================================
-- ★ TheWorld.meta —— 世界元数据（真实引擎由世界生成器写出）
--=========================================================================
-- shardstate.lua:44 `_mastersessionid:set(_world.meta.session_identifier)`
-- 读 `.meta.session_identifier`；宿主没有 meta 就直接「索引 nil」。
-- 只补真实被读到的字段，不臆造更多。
if G.TheWorld ~= nil and G.TheWorld.meta == nil then
    G.TheWorld.meta = {
        session_identifier = "host-local-session",
        -- 其余字段（worldgen 参数等）宿主没有生成器，故意留空，
        -- 让读到它们的代码自然走「字段为 nil」的分支。
    }
end

--=========================================================================
-- ★ c_sel() —— 控制台「当前选中的实体」
--=========================================================================
-- 实证来源（P41 农业链路）：
--   `components/farmplantstress.lua:258`
--       if c_sel() == self.inst then
--           print("FarmPlantStress: ", self.inst)
--           ...
--       end
--   这是**被正常游戏流程**调用到的（每次作物压力结算都会跑），
--   不是只有敲控制台才走 —— 缺了它 `Growable:DoGrowth()` 每次都抛
--       attempt to call global 'c_sel' (a nil value)
--   ⇒ 作物永远长不熟，收获链路整条走不到。
--
-- ★ 为什么返回 nil 是**事实等价**而不是敷衍：
--   c_sel() 的语义是「玩家 UI 里当前选中的那个实体」。宿主没有客户端 UI、
--   也没有控制台选中态 ⇒ 正确答案就是「没有选中任何实体」= nil。
--   返回 nil 会让上面那个门控自然走 false 分支（不打调试日志），
--   与「真实引擎里没选中作物时」的行为**完全一致**。
--   ⚠️ 反面做法：返回 self.inst 或一个万能对象 —— 那会每秒刷屏，
--      而且是在**伪造**一个不存在的选中态。
--
-- ★ 其余 c_* 系列（c_give / c_spawn / c_select / c_announce …共 20+ 个）
--   **故意不补**：它们只在「有人在控制台敲命令」时执行，
--   不在任何正常游戏流程的路径上。补了等于**假装有一个控制台**，
--   真被调到时会静默什么都不做 —— 那比崩溃更难查。
--   若将来某个 c_* 出现在正常流程里（像 c_sel 这样），按实证单独补，并注明触发点。
G.c_sel = function() return nil end

return G
