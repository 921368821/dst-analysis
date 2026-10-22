--[[==========================================================================
 rt_boot.lua —— 实时引擎的**常驻入口**（P1 建 / P2 扩充）

 与 06-引擎复刻 里那 14 个入口的区别
   · 那些入口是「跑一段、打印、退出」；
   · 本文件**跑完启动就返回一个函数表**，之后由 Python 服务端
     反复调用 `step(dt)` / `set_input(k,v)` / `snapshot()` —— 世界**一直活着**。

 它复用的是同一套宿主（`06-引擎复刻/host/*`），不改任何原版脚本。

 由 server.py 这样使用：
     boot = LuaRuntime(...).eval(loadstring(code)())   -- 返回本文件的表
     boot.step(dt)  / boot.set_input("right", True)  / boot.snapshot()

 P2-2 起新增
   · 真实的 `TheInput`（见 rt_input.lua）：IsKeyDown / IsControlPressed(CONTROL_*) /
     鼠标 / 手柄明确「没有」。**原地给宿主那张表补方法，不换表对象**，
     这样早先 `local TheInput = G.TheInput` 抓到的也是同一张。
   · 移动改走**原版** `locomotor:WalkInDirection`（而不是裸 SetMotorVel）：
     这样速度倍率、朝向、地形都快慢都按原版逻辑算。
     Physics 只在 locomotor 缺失时兜底。

 P9 起新增（**补一个保真度缺口**）
   · `TheWorld` 挂 5 个真实**世界组件**：clock / worldtemperature / seasons /
     shardstate / worldreset（清单照抄 06 的 world.lua，源头是原版 world_network.lua）。
     修复前一个都没挂 ⇒ 世界里**永远是大白天**、温度恒 35（`state.phase` 是死值）。
   · 快照新增 `world`（相位/季节/三态布尔/温度）⇒ 客户端画得出昼夜明暗。
     二进制协议因此升到 **v3**（帧尾追加「世界环境块」，见 protocol.md §3）。
   · 反向开关 `RT_NO_WORLD_COMPONENTS=1`：**故意不挂**（给反向测试用，
     证明「昼夜会走」那条检查指向真行为而不是自满足）。别在日常运行里打开。
============================================================================]]
local SEED     = tonumber(os.getenv("RT_SEED")    or "") or 20261015
local TICK_HZ  = tonumber(os.getenv("RT_TICK_HZ") or "") or 30
local MAX_ENTS = tonumber(os.getenv("RT_MAX_ENTS") or "") or 400

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

--=============================================================================
-- 启动：与 14 入口同一套序列（顺序不能改，Loader 必须在 Sim 之前）
--=============================================================================
Bootstrap.Setup()
WorldMap.Generate({ seed = SEED })

--=============================================================================
-- 世界级组件：昼夜 / 温度 / 季节 / 分片 / 重置
--=============================================================================
-- ★ 为什么必须挂：不挂的话 `TheWorld.state.phase/season/temperature` 全是**死值**
--   ⇒ 世界里永远是大白天。实测（修复前）：起始 day|autumn|35|true，
--   跑满 300 s 世界时间后仍是 day|autumn|35|true —— phase 一点没动。
--
-- 清单与挂法**照抄** 06-引擎复刻/world.lua:119-152（原版权威列表见
-- world_network.lua:52-61），只去掉那里的打印与相位日志，
-- 改成对服务端可读的查询接口（M.world_state）。
--
-- ⚠️ 前提（宿主侧与 06 同一份代码，已具备）：
--   · `perlin` 全局 + `TheWorld.meta.session_identifier`（host/03_globals.lua）
--   · AddComponent 影子闸门（host/01_core.lua）—— 重复添加返回旧实例而非再造一个
-- ★★★ M3：清单与挂法**单源**在 `host/30_worldmount.lua`。
--   这里原来自己存了一份 WORLD_COMPONENTS（注释自陈「照抄 06/world.lua」）——
--   两份清单各自维护，原版加一个世界组件（或改名）时必然只改一处，
--   症状是「06 昼夜正常、07 少了季节」，而且没人会想到去看另一份清单。
local WorldMount = require("host.30_worldmount")
local WORLD_MOUNT = { mounted = {}, missing = {}, ok = false }
do
    local W = rawget(_G, "TheWorld") or (G and G.TheWorld)
    if W == nil then
        error("rt_boot: TheWorld 不存在，无法挂世界组件（Bootstrap.Setup 未先跑？）")
    end
    -- ★ 反向开关：不挂世界组件（= 修复前的旧行为）。**只为测试与「故意演示失真」**，
    --   用在「证明 A14 那条检查确实指向行为」——摘掉之后世界必须退回永恒大白天。
    --   ⚠️ 这不是可选功能，别在日常运行里打开。
    local skip = os.getenv("RT_NO_WORLD_COMPONENTS")
    local want_skip = (skip ~= nil and skip ~= "" and skip ~= "0")
    WORLD_MOUNT = WorldMount.Mount(W, { skip = want_skip })
    -- ★ 失败要吵：缺组件是个**静默失真**（世界永远大白天），不能在日志里悄无声息
    if not WORLD_MOUNT.ok then
        print(string.format("[rt_boot] ⚠ 世界组件缺 %d 个：%s —— 昼夜/季节/温度会是死值",
            #WORLD_MOUNT.missing, table.concat(WORLD_MOUNT.missing, ",")))
    end
    -- ★ 可选：指定起始季节（RT_SEASON=winter）。走**原版** `ms_setseason` 机制
    --   （seasons.lua:469 监听），而不是宿主自己去改 state。
    local want = os.getenv("RT_SEASON")
    if want ~= nil and want ~= "" then
        W:PushEvent("ms_setseason", want)
    end
end

--- 读世界环境（昼夜/季节/温度）。**只读 TheWorld.state**，那是 worldstate 对
--- clock/seasons/worldtemperature 的 netvar 的实时镜像 —— 不是宿主硬编码。
--- 返回值可能是 nil（TheWorld 还没就绪），调用方必须能接受。
local function world_env()
    local W = rawget(_G, "TheWorld") or (G and G.TheWorld)
    if W == nil or W.state == nil then return nil end
    local st = W.state
    return {
        phase       = st.phase,
        season      = st.season,
        isday       = st.isday,
        isdusk      = st.isdusk,
        isnight     = st.isnight,
        temperature = st.temperature,
    }
end

--=============================================================================
-- 输入层：把宿主的空壳 TheInput 换成真实实现（rt_input.lua）
--=============================================================================
local RTInput = rawget(_G, "__rt_mod_rt_input")
if RTInput == nil and G then RTInput = G.__rt_mod_rt_input end
if RTInput == nil then error("rt_boot: 拿不到 rt_input 模块（server.py 应先加载它）") end
local Input = RTInput.Install(_G.TheInput or G.TheInput)

--=============================================================================
-- 玩家实体（玩家契约由原版 prefabs/wilson.lua 定义）
--=============================================================================
Bootstrap.LoadPrefabFile("wilson")

-- ★ 只在实例化期间开万能兜底（player_common.lua 会引用几十个宿主未定义的全局），
--   装完立刻撤掉 —— 与 player.lua 的做法一致。
Universal.Install(Core)
local okp, player = pcall(Core.SpawnPrefab, "wilson")
Universal.Uninstall()

local M = {}
-- ★★ `steps_done` 必须**在输入日志之前**声明：Lua 的 `local` 只对它**之后**的代码可见，
--   而输入日志（下面）要用它当时间戳。第一版把声明留在「主步进」段里，
--   于是日志函数看到的是**全局** `steps_done`（nil）⇒ 每条事件的 tick 都是 nil，
--   而症状是**回放时整体错一位**（不是报错），最难发现的那一类。
local steps_done = 0

-- ★★ 前向声明（Lua 的 `local` 只对它**之后**的代码可见）。
--   这里踩过**两次**同款坑：先是 `steps_done`（放到「主步进」段里 ⇒ 输入日志读到 nil），
--   后是 `log_input`（放到「输入接口」段里 ⇒ 上面「玩家槽位」段调它就报
--   "attempt to call a nil value"，因为那时候 `log_input` 还是个**全局**名）。
--   ⇒ 规矩：**跨段落调用的 local 一律在文件前部前向声明**。
local log_input
-- ★★ 这两个也必须前向声明：它们定义在**快照段**（文件靠后），而前面几段要用它们。
--   不声明的话，前面那段看到的是**全局** `pos_of`（nil）⇒
--   `attempt to call global 'pos_of' (a nil value)`，而且**只在真的调用时才炸**
--   （交互那条路径就是这么被抓到的）。本工程在 Lua 的局部作用域上已经踩了 4 次：
--     steps_done（输入日志）· log_input（槽位输入）· pos_of/ent_table（交互）
--   ⇒ 规矩：**跨段调用的 local 一律在文件前部前向声明**。
local pos_of
local ent_table
M.dt        = 1 / TICK_HZ
M.tick_hz   = TICK_HZ
M.seed      = SEED
M.player    = player
M.player_ok = okp and player ~= nil
M.boot_ms   = 0
M.input     = Input

--=============================================================================
-- 玩家槽位（P20：**每个客户端一个角色**）
--=============================================================================
-- ★★ 为什么需要：在此之前所有客户端**共用同一个 wilson** —— 四个浏览器连上来，
--   按方向键动的是同一个人。那不是多人，那是「四个遥控器对着同一台电视」。
--
-- ★ 设计上刻意**向后兼容**（工作量大头在这里，不在于功能本身）：
--     · 槽位 0 = **开机时创建的那个玩家**（`M.player`）—— 存档/读档、预测、
--       以及全部既有测试都指着它，所以它必须还在、还叫这个名字；
--     · 槽位 0 的输入**仍然走真实的 `TheInput`**（P2-2 的结论：TheInput 是真表），
--       槽位 ≥1 才走各自的输入表 —— 这样 A7「真实 TheInput」那条判据依然有意义；
--     · 槽位 ≥1 的角色在**运行时**生成，位置绕原点散开（免得叠在一起）。
-- ★★★ `PLAYERS` 只存**槽位 ≥1**（运行时加进来的）。槽位 0 **一律现读 `M.player`** ——
--   这一条是踩出来的：我第一版写 `PLAYERS = { [0] = player }`，
--   而 `save_apply` 会把 `M.player` 换成**读档后的新实体**（那个函数上面的注释
--   早就专门写过这件事）⇒ `PLAYERS[0]` 仍指着**已被清掉的旧实体** ⇒
--   读档后「按右不动」（A11/B13 当场变红）。
--   ⇒ 教训：**同一个东西只能存一处**。多存一处 = 多一处会忘记同步。
local PLAYERS = {}                     -- slot(>=1) -> entity
local INPUT_SLOTS = {}                 -- slot(>=1) -> { key -> true }
-- ★★ P36：**会话身份的持久化**（2026-10-16 加）。
--   以前 `slot → key` 只活在服务端的内存里 ⇒ 重启之后每个客户端都会拿到**新**角色，
--   而旧角色（带着它走过的路）只能当「没人认领」删掉 —— 这是 P21 明确登记过的缺口。
--   ⇒ 现在把这张表**写进存档**，并在读档后恢复；服务端启动时读它来认领槽位。
local SLOT_KEYS = {}                   -- slot -> 会话 key
function M.set_slot_keys(map)
    SLOT_KEYS = {}
    for k, v in pairs(map or {}) do
        local slot = tonumber(k)
        if slot ~= nil and v ~= nil then SLOT_KEYS[slot] = tostring(v) end
    end
    return true
end
-- ★★★ 键一律用**字符串**（`tostring(slot)`）—— 这不是风格问题，是**必须**：
--   Lua 的数组从 **1** 开始，而槽位从 **0** 开始。一个 `{[0]=a,[1]=b}` 的表
--   在 `lua_to_py()` 眼里是「长度 1 的数组」⇒ **槽位 0 会被静默丢掉**
--   （实测：存档里 `players` 输出成 `[21]`，槽位 0 的 guid 直接消失）。
--   用字符串键 ⇒ 转换器认出这是**字典** ⇒ 一个都不丢。
--   读档那边本来就是 `tonumber(slot_s)`，两边对得上。
function M.slot_keys()
    local out = {}
    for k, v in pairs(SLOT_KEYS) do out[tostring(k)] = v end
    return out
end
function M.player_slots_bound()
    local out = {}
    for slot, inst in pairs(PLAYERS) do
        if inst ~= nil and inst:IsValid() then out[tostring(slot)] = inst._guid end
    end
    if M.player_ok and M.player ~= nil then out[tostring(0)] = M.player._guid end
    return out
end
local PLAYER_SPAWN_R = 6               -- 散开半径（世界单位）

--- 取槽位对应的实体（**唯一入口**：槽位 0 现读 `M.player`）
local function slot_entity(slot)
    if slot == 0 then return M.player end
    return PLAYERS[slot]
end

function M.player_slots()
    local t = { 0 }
    for slot in pairs(PLAYERS) do t[#t + 1] = slot end
    table.sort(t)
    return t
end

--- 槽位对应的实体 guid（服务端要拿它告诉客户端「你是哪一个」）
function M.player_guid(slot)
    local p = slot_entity(tonumber(slot) or 0)
    return p ~= nil and p._guid or nil
end

--- 生成一个 wilson 并按「第 n 个」摆到圆环上（add_player 的两条分支共用）。
--- ★ 抽出来是为了**只有一份生成逻辑** —— 否则「槽位 0 重建」与「槽位 ≥1 新建」
---   很容易慢慢长歪（一边做了位置、另一边忘了）。
local function spawn_wilson_at(nth)
    Universal.Install(Core)
    local ok, pl = pcall(Core.SpawnPrefab, "wilson")
    Universal.Uninstall()
    if not ok or pl == nil then return nil end
    local ang = (nth - 1) * (2 * math.pi / 6)
    if pl.Transform ~= nil and pl.Transform.SetPosition ~= nil then
        pl.Transform:SetPosition(math.cos(ang) * PLAYER_SPAWN_R, 0,
                                 math.sin(ang) * PLAYER_SPAWN_R)
    end
    return pl
end

--- 加一个玩家（服务端在客户端连上时调）。返回 (ok, guid 或 错误原因)
function M.add_player(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "slot 必须是数字" end
    if slot == 0 then
        -- ★ P21：槽位 0 也**可能被回收过**（带会话 key 的客户端认领它、断开后过期被清）。
        --   所以要能手建：建好后同步 M.player / M.player_ok（`step_one_player(0)` 与
        --   存档都读这两个字段）。
        if M.player_ok and M.player ~= nil then
            return true, M.player._guid                                   -- 幂等
        end
        -- ⚠️ 必须把参数传进去：`pcall(spawn_wilson_at)` 漏了参数 ⇒ 里面 `nth - 1`
        --    对 nil 做算术 ⇒ pcall 吞掉错误 ⇒ 返回 false ⇒ 症状是「宽限期后重连没拿到角色」。
        local oks, pl = pcall(spawn_wilson_at, 1)
        if not oks or pl == nil then
            return false, "重建默认玩家失败: " .. tostring(pl)
        end
        M.player = pl
        M.player_ok = true
        return true, pl._guid
    end
    if PLAYERS[slot] ~= nil then return true, PLAYERS[slot]._guid end   -- 幂等
    -- ★★ 必须在**模拟线程**里调（服务端用命令队列保证），原因见 server.py 的 cmd 队列注释：
    --   Sim 只有一个 LuaRuntime，从 HTTP/WS 处理线程直接碰 Lua 会和模拟线程抢状态。
    local pl = spawn_wilson_at(M.player_count())      -- 含槽位 0，绕圈散开
    if pl == nil then
        return false, "SpawnPrefab 失败"
    end
    PLAYERS[slot] = pl
    INPUT_SLOTS[slot] = {}
    return true, pl._guid
end

--- 调试用：把某个槽位玩家的血扣光。
--- ★ **只有在服务端 `--allow-debug` 时才会被调用**（入口见 server.py 的 `/debug/kill`）。
---   为什么要有它：**跨进程**验「死亡 ⇒ 自动复活 ⇒ 客户端认回自己」这条链需要一个
---   **从外部触发死亡**的手段；否则这条链只能进程内验（§9aa.5 登记过这个缺口）。
--- ★ 走组件的正式接口（`health:DoDelta`），不戳内部字段 —— 本工程一直守这条。
function M.force_kill(slot)
    slot = tonumber(slot) or 0
    local p = slot_entity(slot)
    if p == nil then return false, "没有玩家（槽位 " .. tostring(slot) .. "）" end
    local h = p.components and p.components.health
    if h == nil then return false, "玩家没有 health 组件" end
    if h:IsDead() then return false, "玩家已经死了" end
    h:DoDelta(-((h.currenthealth or 0) + 1))     -- 保证一定归零（别留 0.5 之类的残血）
    return true, "已扣光血量"
end

--- 去掉一个玩家（客户端断开）。**槽位 0 永不删除**（它是默认玩家）
function M.remove_player(slot)
    slot = tonumber(slot)
    if slot == nil then return false, "slot 必须是数字" end
    if slot == 0 then
        -- ★ P21：**允许**删槽位 0。它是「默认玩家」，但它也可能被带 key 的客户端认领过；
        --   那种情况下它必须和普通角色一样有生命周期（否则每刷新一次就漏一个空壳）。
        --   删掉后 `M.player_ok = false`（`step_one_player(0)` 会跳过），
        --   下次有人要槽位 0 时由 `add_player(0)` 重建。
        local p = M.player
        M.player_ok = false
        if p ~= nil and p.Remove ~= nil then pcall(p.Remove, p) end
        return true, "已移除默认角色（下次有人用时重建）"
    end
    local pl = PLAYERS[slot]
    if pl == nil then return false, "槽位不存在: " .. tostring(slot) end
    PLAYERS[slot] = nil
    INPUT_SLOTS[slot] = nil
    if pl.Remove ~= nil then pcall(pl.Remove, pl) end
    return true, "已移除"
end

--- 给某个槽位喂输入。slot 0 = 默认玩家（走真实 TheInput）；其余走自己的表。
function M.set_input_for(slot, key, down)
    slot = tonumber(slot) or 0
    if slot == 0 then return M.set_input(key, down) end
    if INPUT_SLOTS[slot] == nil then return false, "槽位不存在: " .. tostring(slot) end
    log_input(tostring(key), down and 1 or 0, slot)
    INPUT_SLOTS[slot][tostring(key)] = down and true or false
    return true
end

function M.player_count()
    local n = 1                       -- 槽位 0（默认玩家）恒在
    for _ in pairs(PLAYERS) do n = n + 1 end
    return n
end

--=============================================================================
-- 输入接口（供服务端调用）
--=============================================================================
-- ★★ 输入日志（M7「回放」的一半）：每次**输入变化**记一条 (tick, 键, 值)。
--   为什么只记变化：重复按同一键（客户端每个 keydown 只发一次，但服务端可能重复推）
--   在语义上是幂等的 —— 记下来只会让日志膨胀，回放时也没有任何差别。
--   tick 的语义：`steps_done` = 「这条输入是在**推进第 steps_done+1 个 tick 之前**生效的」。
--   回放端必须按同一语义喂，否则会整体差一 tick（这种错很难看出来：前几十帧还像对的）。
-- ★★ 日志里**必须带槽位**（P20 加）：多人之后「谁按的」和「按了什么」一样重要。
--   不带槽位的话，四个客户端连上来录下来的日志只有本地玩家那一份 ——
--   而且**回放仍然会「一致」**（因为回放也只喂本地玩家那一份）⇒ 一个**看不出来的缺口**。
local INPUT_LOG = {}
function log_input(k, v, slot)      -- 前向声明在上面（见那里的注释）
    slot = tonumber(slot) or 0
    local last = INPUT_LOG[#INPUT_LOG]
    if last ~= nil and last.tick == steps_done and last.k == k and last.v == v
       and (tonumber(last.slot) or 0) == slot then
        return
    end
    INPUT_LOG[#INPUT_LOG + 1] = { tick = steps_done, k = k, v = v, slot = slot }
end

function M.set_input(key, down)
    log_input(tostring(key), down and 1 or 0, 0)
    return Input.set(key, down)
end
function M.clear_input()
    -- ★ 清空记成一条 "*" 事件：回放时同样语义（否则「清空」这个动作会丢，回放会跑偏）
    log_input("*", 0, 0)
    Input.clear()
end
function M.input_log() return INPUT_LOG end
function M.clear_input_log() INPUT_LOG = {} end
function M.set_mouse(x, z)
    Input.set_mouse(x, z)
end
function M.input_state()
    local st = {}
    for k, v in pairs(Input.state()) do st[#st + 1] = k .. "=" .. tostring(v) end
    table.sort(st)
    return st
end
--- ★ 未知接口调用记录：让人看见「还有谁在读我没实现的输入面」
function M.input_unknown()
    return Input.unknown_calls()
end

--- 从输入算方向（走 rt_input 的控制名映射，而不是自己认键）
--- ★ 返回**世界方向单位向量** (dx, dz)。
local function dir_from_input()
    local x, z = 0, 0
    if Input.TI:IsControlPressed("CONTROL_MOVE_RIGHT") then x = x + 1 end
    if Input.TI:IsControlPressed("CONTROL_MOVE_LEFT")  then x = x - 1 end
    if Input.TI:IsControlPressed("CONTROL_MOVE_UP")    then z = z + 1 end
    if Input.TI:IsControlPressed("CONTROL_MOVE_DOWN")  then z = z - 1 end
    if x ~= 0 and z ~= 0 then
        local inv = 1 / math.sqrt(2)
        x, z = x * inv, z * inv
    end
    return x, z
end

--- 世界方向 (dx, dz) → 原版朝向角（**度**）。
---
--- ★★★ 这里曾经有一个真缺陷，而且是**假绿**（2026-10-16 发现并修）：
---   `LocoMotor:WalkInDirection(direction, should_run)` 的第一个参数**不是向量，
---   是「朝向角」**。它会一路传到
---       `SetMoveDir(dir) → Transform:SetRotation(dir)`
---   而 `SetRotation` 收的是**数字角度**。本工程第一版传的是 `Vector3(x, 0, z)`（表），
---   宿主把非数字收敛成 0（那是为另一个崩溃加的兜底）⇒ **朝向恒为 0** ⇒
---   物理积分只能沿 0 度走 ⇒ **玩家永远朝 +x 走，四个方向键没有区别**。
---   ⚠️ 而当时 A3「按右 ⇒ x 变大」**照样是绿的** —— 因为 +x 恰好就是它要的方向。
---   这正是本工程反复出现的「**判据通过但什么都没证明**」：只测一个方向，
---   就分不清「按右生效」和「不管按什么都往 +x」。
---   ⇒ 现在 A3 改成**四个方向 + 两个斜向**各自断言（并把另外三个方向当反向判据）。
---
--- ★ 单位是**度**，不是弧度 —— 取证（三处互相印证）：
---   ① 原版 `EntityScript:GetAngleToPoint`（entityscript.lua:3407）：
---        `math.atan2(z1 - z, x - x1) * RADIANS`，而 `constants.lua:117`
---        `RADIANS = 180/PI` ⇒ **返回度**。
---   ② 原版 `EntityScript:FacePoint`（同文件 3484）：把这个返回值**直接**
---        交给 `Transform:SetRotation` ⇒ **SetRotation 收度**。
---   ③ 宿主 `host/11_physics.lua:176`：`rot = GetRotation() * DEG`，把存下来的值
---        当**度**换算成弧度再积分 ⇒ 与 ①② 一致（宿主 `GetAngleToPoint` 也返回度）。
---   ⚠️ 反例记录：原版 `behaviours/wander.lua:447` 写的是 `WalkInDirection(angle/DEGREES)`
---      （把度换成弧度），与另外三个调用点（avoidlight / follow / runaway 都传度）
---      不一致 —— 按上面三处取证，**wander 那处是原版的单位笔误**。
---      本工程**不修原版**，只按权威语义传度。
---
--- ★ 角度公式与朝向的对应（来自 host/11_physics.lua 的推导，不是猜的）：
---   `θ = atan2(-dz, dx)`（度）⇒ 前方向量 = (cosθ, -sinθ)。
---   核对：右 (1,0) → θ=0 → 前方 (1,0) ✔；上 (0,1) → θ=-90° → 前方 (0,1) ✔。
local function dir_to_angle(x, z)
    if x == 0 and z == 0 then return nil end
    return math.atan2(-z, x) * 180 / math.pi
end

--=============================================================================
-- 动画：**默认交给原版状态图**，这里只在没有状态图时兜底
--=============================================================================
-- ★★★ 这里曾经有一个真缺陷（2026-10-16 发现）：**所有实体动画帧都不动**。
--   原来每个 tick 都调 `anim:PlayAnimation(run and "run" or "walk")`。
--   三个害处，逐一实测确认过：
--     ① **每 tick 重播**：`applyAnim` 会把 `_time` 清零 ⇒ 帧号永远停在 1~2
--        ⇒ 精灵是**死的**（客户端每帧都拿到同一个 fr）；
--     ② **名字不对**：导出的 wilson build 里**根本没有** `walk`/`run`/`attack`/`hit`
--        （实测动画表只有：corpse, corpse_hit, idle, idle_hot_loop, idle_hot_pre,
--          idle_hot_pst, idle_inaction, idle_inaction_sanity, idle_loop,
--          idle_loop_nofaced, idle_sanity_loop, idle_sanity_pre, run_loop, run_pre, run_pst）
--        ⇒ `applyAnim` 落到**合成兜底**（15 帧、无绘制数据）⇒ 客户端连精灵都画不出来；
--     ③ **覆盖状态图**：玩家身上挂着**真的** `sg`（wilson 状态图），它自己会按
--        `locomote` 事件切 `idle_loop` / `run_pre` / `run_loop`。
--        我每 tick 覆盖它，等于让状态图的 `run_start` 永远等不到 `animover`
--        ⇒ 状态机**卡在 `run_start` 不再前进**（实测 sg 状态停在 run_start、时间不再走）。
--
--   ⇒ 正确做法：**一行都不碰**，让状态图驱动（这也是原版的架构）。
--      只有当实体**没有状态图**时（罕见）才手工兜底，而且：
--        · 用**真实存在的**动画名（`idle_loop` / `run_loop`）；
--        · **只在动画名变化时切一次**（绝不每 tick 重播）。
--- 兜底次数（供观测/测试：玩家有状态图 ⇒ **恒为 0**，即「一行都没碰」）
local anim_fallback_used = 0
function M.anim_fallback_used() return anim_fallback_used end

local function anim_fallback_for(p, want)
    local anim = p and p.AnimState
    if anim == nil or anim.PlayAnimation == nil then return end
    if anim.IsCurrentAnimation ~= nil and anim:IsCurrentAnimation(want) then
        return                      -- ★ 已经在播它了 ⇒ 什么都别做（关键：不重置 _time）
    end
    anim_fallback_used = anim_fallback_used + 1
    pcall(anim.PlayAnimation, anim, want, true)
end

--=============================================================================
-- 交互（P22）：对着附近的东西**做动作**（砍树 / 挖 / 捡）
--=============================================================================
-- ★★ 为什么目标由**服务端**挑，而不是客户端点哪儿算哪儿：
--   一个东西「能不能砍」取决于它挂了哪些组件（workable / pickable / harvestable）
--   以及 workable 的 action 是什么 —— 这套规则**只在引擎里**。
--   让客户端去猜，等于把规则复制一份到前端，两边迟早对不上
--   （本工程已经在「动画名」「地形名」上各栽过一次：**名字/规则对不上的时候，程序不报错、
--     只会悄悄降级**）。⇒ 服务端给**可作用目标列表**（带动作名），客户端只负责显示和选最近的那个。
local ACT_REACH = 20            -- 世界单位：超出这个距离直接拒绝（并且**说得出**拒绝原因）
local act_ok_n, act_refused_n = 0, 0
local act_arrive_n = 0          -- ★ 因「到达距离缺失」被 07 补过参数的次数（**不静默**，见 push_action）
local act_invobject_n = 0       -- ★ B3：带上了手持物品的动作次数（0 = 装备对动作完全没影响）
local last_act_refusal = nil
function M.act_stats() return act_ok_n, act_refused_n, last_act_refusal end
function M.act_arrive_patched() return act_arrive_n end
function M.act_invobject_count() return act_invobject_n end

--- 这个东西支持什么动作？返回动作名（如 "CHOP"）或 nil。
local function action_for(inst)
    local c = inst.components
    if c == nil then return nil end
    local w = c.workable
    if w ~= nil and w.action ~= nil and w.action.id ~= nil then
        -- ★ 用 workable **自己声明的** action（原版就是这么定的），不猜名字
        return tostring(w.action.id)
    end
    -- ★★ P61：**能打的**（战斗闭环的第一半：玩家 → 生物）。
    --   判据是「有 combat + 有 health + 没死 + 不是玩家」，四条缺一不可：
    --   ① 只有 combat 没有 health —— 打不死，列出来是骗人；
    --   ② 已经死了 —— 尸体不该出现在目标列表里；
    --   ③ **其他玩家**也有 combat + health，不排除掉就会变成「互相砍」，
    --      而本引擎没有 PVP 开关（原版要 `pvp` 标记 + 双方同意），
    --      默认允许互砍是一种**没人要求过的行为选择**。排除，等有了开关再说。
    --   位置放在 workable 之后：生物一般没有 workable，但万一有（比如能砍的怪），
    --   原版规则是 workable 优先 —— 这里跟着原版走。
    local cb, hp = c.combat, c.health
    if cb ~= nil and hp ~= nil and not hp:IsDead() and not inst:HasTag("player") then
        return "ATTACK"
    end
    if c.pickable ~= nil and c.pickable.canbepicked ~= false then return "PICKUP" end
    if c.harvestable ~= nil then return "HARVEST" end
    -- ★★ 地上的**物品**（2026-10-16 加）：树会掉 log / pinecone，所以「捡起来」是闭环的一半。
    --   旧文档写的是「拾取不可用（宿主 inventory 是桩）」—— 那是**错诊断**：
    --   ① 原版 `Inventory` 根本没有 `GetItems`（真接口是 `GetItemInSlot`/`FindItem`/`Has`/
    --      `GetNumSlots`/`GiveItem`），而且这些在宿主里**都能用**；
    --   ② `ACTIONS.PICKUP.fn` 直接调用**能成**（实测 log/twigs 都进了背包）。
    --   真正缺的只是：地上的物品**没被算成「目标」**（原来只认 workable/pickable/harvestable）。
    local ii = c.inventoryitem
    if ii ~= nil and ii.canbepickedup then return "PICKUP" end
    return nil
end

--- 附近**可作用**的东西（按距离升序）。服务端算，客户端只显示。
---
--- ★★★ P41 / T6：这里从「全表线性扫」换成了**空间索引**。
---
--- 为什么要换：`act_targets` 是每个客户端**每 250 ms** 拉一次的热路径，
--- 而它是 `pairs(ent_table())` 全表遍历 —— 645 个实体 × 4 个客户端，
--- 光这一项每拍就要扫 2580 次、每次还要 `action_for` + `pos_of`（都是元表调用）。
--- 压测里这一项就是 12.0 ms 预算的主要消耗者。
---
--- 索引的设计（三条都对着计划里的验收标准）：
--- ① **4 个世界单位一格**（`ACT_CELL`）。`ACT_REACH` 是 20 ⇒ 查询只扫
---    半径 ±20 的包围盒 = 最多 11×11 = 121 格，而不是 645 个实体。
--- ② **每 8 拍全量重建**（`ACT_REBUILD_EVERY`）。重建是 O(n)，但摊到 8 拍上
---    就只剩 1/8；而且「位置会变」这件事也只能靠定期重建兜住。
--- ③ **排序/截断规则一个字都没动**，只是抽成了 `act_sort_and_cut` 与线性版共用。
---
--- ⚠️ 已知代价（写在这里，不藏）：索引**最多陈旧 8 拍**。
---   引擎里新 spawn 的实体要等下一次重建才进索引；同理「走出格子的实体」
---   也可能在 8 拍内被漏掉。`M.act_index_invalidate()` 就是给这种
---   「我确知世界变了」的调用方留的（世界生成、`debug_spawn` 之后调它）。
---   这条代价是计划里「每 8 拍重建」这个设计**本身**带来的，不是实现缺陷。
---
--- ★ 另一处**行为改进**（不是重构的副作用，是刻意加的）：
---   距离相等时按 guid 升序兜底。原来 `table.sort` 对相等距离的顺序是
---   **不稳定的**，而索引版与线性版的**输入顺序不同**（格子遍历 vs 表遍历）⇒
---   不兜底就永远对不上，「逐项一致」这条判据根本无从成立。
---   兜底之后结果是**确定**的，两条路才真的可比。

--- 距离排序 + 截断 12 条 —— 线性版与索引版**共用这一段**。
--- 共用是为了让「两条路结果逐项一致」成为**结构上的保证**，而不是靠调参凑出来。
local ACT_LIMIT = 12
local function act_sort_and_cut(out, px, pz)
    table.sort(out, function(u, v)
        local du = (u.x - px) ^ 2 + (u.z - pz) ^ 2
        local dv = (v.x - px) ^ 2 + (v.z - pz) ^ 2
        if du ~= dv then return du < dv end
        return u.id < v.id          -- ★ 距离相等按 guid，让结果确定（见上面那段）
    end)
    if #out > ACT_LIMIT then
        -- 只给最近 12 个：列表是**每 250 ms 拉一次**的，别把带宽花在看不见的东西上
        local cut = {}
        for i = 1, ACT_LIMIT do cut[i] = out[i] end
        out = cut
    end
    return out
end

--- 把一个实体变成「候选记录」（或 nil）。线性版与索引版都走它。
local function act_make_entry(inst, guid, p, px, pz, radius)
    if inst == nil or inst == p then return nil end
    local a = action_for(inst)
    if a == nil then return nil end
    local x, z = pos_of(inst)
    if x == nil then return nil end
    local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
    if d > radius then return nil end
    return { id = guid, p = tostring(inst.prefab or ""), x = x, z = z, a = a }
end

--- **线性实现**（原版行为，一字不改）。
--- 保留它的两个用途：① 索引版的比对基准（验收判据靠它）；② 索引出问题时的降级路径。
function M.act_targets_linear(slot, radius)
    radius = tonumber(radius) or ACT_REACH
    local p = slot_entity(tonumber(slot) or 0)
    if p == nil then return {} end
    local px, pz = pos_of(p)
    if px == nil then return {} end
    local out = {}
    for guid, inst in pairs(ent_table()) do
        local e = act_make_entry(inst, guid, p, px, pz, radius)
        if e ~= nil then out[#out + 1] = e end
    end
    return act_sort_and_cut(out, px, pz)
end

-- ── 空间索引本体 ──────────────────────────────────────────────────────────
local ACT_CELL          = 4     -- 每格边长（世界单位）
local ACT_REBUILD_EVERY = 8     -- 每 N 拍全量重建

local act_index, act_index_stamp = nil, nil
local act_builds, act_lookups, act_scan_ents = 0, 0, 0

local function cell_coord(v) return math.floor(v / ACT_CELL) end
local function cell_key(cx, cz) return cx * 65536 + cz end

--- 全量重建：遍历一次实体表，按所在格子分桶。
local function act_index_build(now)
    local g, n = {}, 0
    for guid, inst in pairs(ent_table()) do
        local x, z = pos_of(inst)
        if x ~= nil then
            local k = cell_key(cell_coord(x), cell_coord(z))
            local b = g[k]
            if b == nil then b = {}; g[k] = b end
            b[#b + 1] = guid
            n = n + 1
        end
    end
    act_index, act_index_stamp = g, now
    act_builds = act_builds + 1
    return n
end

--- 取「半径内可能命中」的候选 guid 列表（只扫包围盒内的格子）。
local function act_candidates(px, pz, radius)
    local now = steps_done or 0
    if act_index == nil or act_index_stamp == nil
       or (now - act_index_stamp) >= ACT_REBUILD_EVERY then
        act_index_build(now)
    end
    act_lookups = act_lookups + 1
    local out = {}
    local cx0, cx1 = cell_coord(px - radius), cell_coord(px + radius)
    local cz0, cz1 = cell_coord(pz - radius), cell_coord(pz + radius)
    for cx = cx0, cx1 do
        for cz = cz0, cz1 do
            local b = act_index[cell_key(cx, cz)]
            if b ~= nil then
                for i = 1, #b do
                    out[#out + 1] = b[i]
                end
            end
        end
    end
    act_scan_ents = act_scan_ents + #out
    return out
end

--- ★ 给「我确知世界变了」的调用方用（世界生成 / debug_spawn / 读档之后）。
--- 不调也不会错，只是要等最多 8 拍。
function M.act_index_invalidate() act_index, act_index_stamp = nil, nil end

--- 索引的体检数据：重建次数 / 查询次数 / 累计扫描实体数。
--- 「累计扫描实体数 / 查询次数」就是**平均每次查询扫了几个实体** ——
--- 这是索引有没有真的省下工作的直接证据（线性版这个数恒等于实体总数）。
function M.act_index_stats() return act_builds, act_lookups, act_scan_ents end

function M.act_targets(slot, radius)
    radius = tonumber(radius) or ACT_REACH
    local p = slot_entity(tonumber(slot) or 0)
    if p == nil then return {} end
    local px, pz = pos_of(p)
    if px == nil then return {} end
    local ents = ent_table()
    local cands = act_candidates(px, pz, radius)
    local out = {}
    for i = 1, #cands do
        local guid = cands[i]
        local e = act_make_entry(ents[guid], guid, p, px, pz, radius)
        if e ~= nil then out[#out + 1] = e end
    end
    return act_sort_and_cut(out, px, pz)
end

--- 真正把动作压进 locomotor（成败都说得出原因）
-- ★ 前向声明：`ACT_HIT` 在下面「待做动作」那段才赋值，但 `push_action` 也要用它。
--   Lua 的 `local` **只对它之后的代码可见** —— 不声明的话，这里引用到的是一个
--   **全局** `ACT_HIT`（= nil），而且**不报错**（本工程在别的变量上已经栽过 4 次）。
local ACT_HIT, ACT_REPEAT
local function push_action(p, target, action_name)
    local ACT = ACTIONS and ACTIONS[action_name]
    if ACT == nil then return false, "引擎里没有动作 " .. tostring(action_name) end
    local loco = p.components and p.components.locomotor
    if loco == nil or loco.PushAction == nil then return false, "玩家没有 locomotor" end
    -- ★★★ B3（2026-10-22）：**必须把「手持物品」传进 BufferedAction**。
    --   原版 `playercontroller` 构造动作时第 4 个参数就是 invobject（手持物）。
    --   我们之前一直没传 ⇒ `act.invobject == nil` ⇒ 砍树时
    --       numworks = (invobject.tool:GetEffectiveness(...) or worker:... or 1)
    --   永远走最后的兜底 1 ⇒ **装了斧头也不会变快**，而且**不会报错**。
    --   这不是「装备没做」，是「做了也不会生效」—— 与 P61「ATTACK 记账只接一处」同族。
    --   ⚠️ 只在拿得到时传：`GetActiveItem` 取不到就保持 nil（沉默），不要编一个假物品。
    local inv = p.components and p.components.inventory or nil
    local invobject = nil
    if inv ~= nil then
        -- ★★ 手持物 = **装备在 HANDS 槽的东西**，不是 `GetActiveItem()`。
        --   实测（B3 第一次）：先用 `GetActiveItem` 时，斧头明明已经
        --   `equip` 成功（hands_prefab = "axe"），`act_invobject_n` 却还是 0 ——
        --   因为 `GetActiveItem` 指的是"当前选中/使用中的物品"，与"手上装备的"是两个概念。
        --   两个都试，优先 hands：这就是原版 `numworks` 那条 or 链要的东西。
        if inv.GetEquippedItem ~= nil then
            local okH, h = pcall(inv.GetEquippedItem, inv, EQUIPSLOTS.HANDS)
            if okH and h ~= nil then invobject = h end
        end
        -- ⚠️ **不做 `GetActiveItem` 兜底**（B3 实测后撤回）：
        --   `GetActiveItem` 是「鼠标选中的物品」，可以是任何东西（一块木头、一坨粪）。
        --   而 `tool:GetEffectiveness(action)` 对不认识的动作返回 **0**（不是 1），
        --   numworks = 0 ⇒ **手持一块木头反而砍不动树**。
        --   原版 `numworks` 那条 or 链的兜底 1 只在 `invobject == nil` 时才生效 ——
        --   所以「传一个不是工具的东西」比「什么都不传」更糟。只认 HANDS 槽。
    end
    local okA, ba = pcall(BufferedAction, p, target, ACT, invobject)
    if not okA or ba == nil then return false, "动作构造失败: " .. tostring(ba) end
    -- ★★ 记账必须挂在**构造出来的动作**上，不能挂在"我打算传"的那个变量上。
    --   实测（B3 变异 F）：把 `BufferedAction` 的第四个参数去掉、但保留
    --   `if invobject ~= nil then 计数+1`，判据照样全绿 ——
    --   因为计数记的是"意图"，不是"事实"。这类记账在本工程出现过不止一次
    --   （P61 的 atk_hit 恒 0 也是同一个形状：以为记了，其实记的是另一个东西）。
    if ba.invobject ~= nil then act_invobject_n = act_invobject_n + 1 end
    -- ★★★ 唯一一处「替原版补一个参数」，而且**只在它确实缺的时候**补，并**记账**（不静默）。
    --   为什么必须补：`locomotor:PushAction` 对「带 target 的动作」走
    --   `GoToEntity`，而动作是在**判定为「到达」之后**才执行的。到达距离的算法是
    --       arrive_dist = ARRIVE_STEP + rad(owner) + rad(self)
    --       然后 math.max(arrive_dist, bufferedaction.distance)
    --   `ACTIONS.CHOP.distance = 1.75` ⇒ 站 1.2 格外也算到达（实测能砍）；
    --   而 `ACTIONS.PICKUP` **没有 distance**（它用的是 extra_arrive_dist）⇒ 走不到那个
    --   math.max ⇒ 实测**只有站在物品正上方（0.0 格）才算到达**（0.2 格就捡不到，
    --   而玩家被物理挡住时与物品的距离不会那么小）⇒ 「捡起来」永远不发生、
    --   表现却是**静默无效**（push 成功、什么都不发生）—— 本工程最讨厌的那种形态。
    --   ⇒ 用原版**自己留的钩子** `bufferedaction.arrivedist`（GoToEntity 的第一个分支）
    --     显式给它一个够得着的距离。不是改原版文件，只是把调用方该给的参数给上。
    --   ⚠️ 只在 `distance` 与 `arrivedist` **都缺**时才动，别覆盖原版已经算好的值。
    if ba.distance == nil and ba.arrivedist == nil then
        ba.arrivedist = ACT_HIT
        act_arrive_n = act_arrive_n + 1
    end
    local okP, err = pcall(loco.PushAction, loco, ba, true)
    if not okP then return false, "PushAction 失败: " .. tostring(err) end
    return true, action_name
end

-- ★★ P22：「待做动作」。为什么要它：原版动作有**作用范围**（实测 1.5 格能砍、2.0 格砍不动），
--   超出范围时 PushAction **不报错、也不做事** —— 属于典型的「静默无效」。
--   原版 playercontroller 的做法是「记住要做什么、朝它走过去、到了再做」，
--   这里照做（走用 WalkInDirection —— 那条路我们已经验证过是通的）。
--
-- ★★★ 2026-10-16：这里**差点被我改坏**，把量出来的事实记下来，免得下次再想当然。
--   我一度以为「原版动作链自己会循环，所以一次 push 就够、重发反而把循环打断」，
--   于是删掉了下面的重发。实测**直接否掉了这个想法**（树放 1.0 格外、只 push 一次）：
--     · 只 push 一次  ⇒ workleft 15 → 14，然后**永远停在 14**（一次 push = **一次**敲击）；
--     · 每秒重发一次  ⇒ 15 → 14 → … → 1 → 倒下（CHOP→DIG）+ **掉 3 个 log**。
--   ⇒ 结论与我的猜测**正好相反**：`push_action` 就是「敲一下」，
--     「连砍」**本来就是靠这个定时重发撑起来的**，它是承重结构，不能拆。
--   ★ 另一个同样是量出来的事实：玩家「走过去」时会被物理**挡在约 1.2 格**，
--     而动作真正生效的距离比那更近（1.0 格能砍、1.2 格那一下打空）。
--     所以「到了就敲、打空就等下一拍再敲」这个**容忍性**也是靠重发提供的 ——
--     只敲一次的话，恰好在 1.2 停下的那种情况会「一次都没打中」，表现就是
--     workleft 一点都不降（实测过；这也是我那次改动让 E1/E2 一起变红的直接原因）。
local PENDING = {}              -- slot -> { guid, next_t, until_t }
ACT_HIT = 1.2                   -- 认为「够得着」的距离（实测 1.5 可行，取小一点更稳）
ACT_REPEAT = 30                 -- 到范围后每隔这么多 tick 再做一次（= 按住不放的节奏）

--=============================================================================
-- P61：攻击（战斗闭环：玩家 → 生物）
--=============================================================================
-- ★★★ 这里记一段**我判断错、被自己的变异实验抓住**的经过：
--   我最初认定「ATTACK **不能**走 `push_action`」，理由是「原版 `ACTIONS.ATTACK.fn`
--   是空的，真正的结算发生在 stategraph 的动画帧事件里，而宿主的兜底动画不产生事件」
--   （`代理语义总览.md` 第 9 行确实记着这条）。于是写了一个直接调
--   `combat:DoAttack` 的独立分支。
--
--   变异实验（把 ATTACK 退回 `push_action`，看 E13 会不会红）给出的结果是：
--   **目标照样被打死了**，只有我自己加的计数 `atk_hit` 是 0。
--   回头读 `dstsrc/scripts/actions.lua:4902` 才发现 —— `ACTIONS.ATTACK.fn`
--   **有实现**，内容就是 `act.doer.components.combat:DoAttack(act.target)`。
--   ⇒ 「fn 是空的」是**事实错误**。而错误的前提会让实现绕开原版，
--     丢掉 `propattack` / `thrusting` / `helmsplitting` 三个分支
--     和 `BufferedAction` 的到达判定。
--
-- ★ 最终实现：**动作仍交给原版**（`push_action` → `ACTIONS.ATTACK.fn` → `DoAttack`），
--   07 只做三件原版不做的事：
--     ① 把生物列进目标列表（`action_for` 的 ATTACK 分支，见上面）；
--     ② 冷却期**不 push**（`CanAttack` 先说不行，就别去占用 locomotor 队列）；
--     ③ **记账**：这一下到底有没有扣血 —— `DoAttack` 没有返回值，
--        唯一不依赖实现细节的事实来源是**目标血量前后差**。
--   伤害公式、护甲、电击倍率、反伤、范围攻击全部仍由原版 `CalcDamage` /
--   `GetAttacked` 算，这里一行都没重写。
--
-- ★ 冷却不是错误。`CanAttack` 在冷却期返回 false —— 那是「这一拍不出手」，
--   和「太远」「目标非法」不是一回事。混在一起会让客户端一直显示失败，
--   而用户看到的是「按了没反应」。
-- ★★ 记账为什么**不能**在 push 之后当场读血量（这条是实测撞出来的）：
--   `push_action` 只把 `BufferedAction` 交给 locomotor，**执行发生在之后的某拍**
--   （走到位才执行 fn）。所以「push 前后 `hp_of()` 相等」是正常现象，
--   不是「没打中」——第一版就是这么写的，判据报的却是
--   「目标死了但 atk_hit=0」，看起来像攻击没生效，实际是**采样时机错了**。
--   ⇒ 改成**逐拍采样**（step 里对每个 PENDING 目标比上一拍的血量），
--     统计口径也跟着改成「观测到几次掉血 + 一共掉多少血」。
--     其中 `atk_dmg` 是最硬的事实：**打完一只 100 血的蜘蛛，它必须正好等于 100**。
local atk_ok_n, atk_land_n, atk_dmg_n, atk_cd_n = 0, 0, 0, 0
local last_atk_why = nil
function M.attack_stats() return atk_ok_n, atk_land_n, atk_dmg_n, atk_cd_n, last_atk_why end

--- 目标当前血量；拿不到就是 nil（**不是 0** —— 缺字段和「血空了」是两件事）
local function hp_of(inst)
    local c = inst ~= nil and inst.components or nil
    local h = c ~= nil and c.health or nil
    if h == nil then return nil end
    local ok, v = pcall(function() return h.currenthealth end)
    if not ok or type(v) ~= "number" then return nil end
    return v
end

--- 出手一次：**走原版动作链**，外面只套一层「冷却判断 + 记账」。
--- 返回 (受理, 说明, 是否真的出手)。
---   · 冷却中   → (true, "冷却中", false)：调用方**照常排下一拍**，不要报失败
---   · 太远/非法 → (false, 原因)：调用方应当拒绝并说明
local function do_attack(p, target)
    local pc = p.components and p.components.combat
    if pc == nil then
        last_atk_why = "玩家没有 combat 组件"
        return false, last_atk_why
    end
    -- ★ 距离先判：`CanAttack` 返回 false 时**分不清**是「冷却」还是「够不着」，
    --   而这两者的用户可见后果完全相反（等一等就会打 / 得走过去）。
    --   先自己判一次距离，剩下的 false 才敢说是冷却。
    local px, pz = pos_of(p)
    local tx, tz = pos_of(target)
    if px == nil or tx == nil then
        last_atk_why = "取不到位置"
        return false, last_atk_why
    end
    local d = math.sqrt((tx - px) ^ 2 + (tz - pz) ^ 2)
    if d > ACT_HIT then
        last_atk_why = string.format("够不着（%.2f > %.2f）", d, ACT_HIT)
        return false, last_atk_why
    end
    local okC, can, invalid = pcall(pc.CanAttack, pc, target)
    if not okC then
        last_atk_why = "CanAttack 抛错: " .. tostring(can)
        return false, last_atk_why
    end
    if not can then
        if invalid then
            last_atk_why = "目标不可攻击（原版判定为非法目标）"
            return false, last_atk_why
        end
        atk_cd_n = atk_cd_n + 1
        last_atk_why = "冷却中（这一拍不出手）"
        return true, last_atk_why, false
    end
    -- ★★ 真正出手：交给原版 `ACTIONS.ATTACK.fn`（它内部就是 `combat:DoAttack`）。
    --   注意 `ACTIONS.ATTACK` 自己**没有** `distance` 字段 ⇒ `push_action` 会替它补
    --   `arrivedist = ACT_HIT` 并记一次 `arrive_patched`（这条路径对 CHOP/PICKUP
    --   已经跑了半年，是同一个机制，不是为攻击新开的特例）。
    --   ⚠️ 这里**不**读血量差：push 只是排队，执行在之后的拍（见上面那段）。
    local okP, whyP = push_action(p, target, "ATTACK")
    if not okP then
        last_atk_why = whyP
        return false, last_atk_why
    end
    atk_ok_n = atk_ok_n + 1
    last_atk_why = "出手（这一击的结果由下一拍的血量差核）"
    return true, last_atk_why, true
end

--- **执行动作的唯一入口**：`M.act` 与 step 里的重发都必须走这里。
--  为什么抽出来：「走到够得着 → 每 30 拍重发一次」这套逻辑在两个地方
--  （首次调用 / step 重发）各有一份。ATTACK 需要额外的「冷却判断 + 血量记账」，
--  分支若只接一处，另一处的攻击就会**记账缺失**（目标死了但 atk_hit = 0）——
--  变异实验 P61-A 红的就是这个形状。P24 的「连砍」也差点因为只改一处而失效。
local function perform(p, target, a)
    if a == "ATTACK" then
        return do_attack(p, target)
    end
    local ok, why = push_action(p, target, a)
    return ok, why, ok
end


--- 对着某个 guid 做它支持的动作（会**先走过去**）。返回 (ok, 说明 或 拒绝原因)
function M.act(slot, guid)
    slot = tonumber(slot) or 0
    guid = tonumber(guid)
    local p = slot_entity(slot)
    if p == nil then
        act_refused_n = act_refused_n + 1
        last_act_refusal = "没有玩家（槽位 " .. tostring(slot) .. "）"
        return false, last_act_refusal
    end
    if guid == nil then
        act_refused_n = act_refused_n + 1
        last_act_refusal = "没给目标 guid"
        return false, last_act_refusal
    end
    local target = ent_table()[guid]
    local function refuse(why)
        act_refused_n = act_refused_n + 1
        last_act_refusal = why
        return false, why
    end
    if target == nil then return refuse("目标不存在（guid " .. guid .. "）") end
    local a = action_for(target)
    if a == nil then
        return refuse("这东西没有可做的动作（" .. tostring(target.prefab) .. "）")
    end
    -- ★ 距离由**服务端**判（不信客户端）：太远就说「太远」，而不是静默不做
    local px, pz = pos_of(p)
    local tx, tz = pos_of(target)
    if px == nil or tx == nil then return refuse("取不到位置") end
    local d = math.sqrt((tx - px) ^ 2 + (tz - pz) ^ 2)
    if d > ACT_REACH then
        return refuse(string.format("太远（%.1f > %d）", d, ACT_REACH))
    end
    -- ★ 记下「待做」：由 step 负责走过去 / 到范围后重复做（松开时由 unact 取消）
    PENDING[slot] = { guid = guid, next_t = 0, until_t = steps_done + 900,
                      -- ★ P61：逐拍采样用的「上一拍血量」。对没有 health 的目标
                      --   它是 nil（植物），采样分支会跳过 —— 不需要为动作类型分支。
                      hp_watch = hp_of(target) }
    if d > ACT_HIT then
        -- 太远：**不是失败**，而是「正在走过去」——状态要说清楚（否则客户端没法显示）
        last_act_refusal = nil
        return true, "走下去（" .. a .. "，还差 " .. string.format("%.1f", d - ACT_HIT) .. "）"
    end
    local okD, why, performed = perform(p, target, a)
    if not okD then return refuse(why) end
    -- ★ 定下一拍的时刻（**不是**「做完这一下就算了」—— 一次 push 只敲一下，
    --   连砍靠的就是这个节拍；见 PENDING 上方的实测记录）。
    PENDING[slot].next_t = steps_done + ACT_REPEAT
    -- ★ P61：「受理了」和「真的出手了」不是一回事（攻击冷却期属于前者）。
    --   `act_ok` 统计的是**真的做了**的次数 —— 否则冷却期也会 +1，
    --   判据就会看到「出手 30 次、掉血 0」这种自相矛盾的数字。
    if performed ~= false then act_ok_n = act_ok_n + 1 end
    last_act_refusal = nil
    return true, why or a
end

--- 取消「待做动作」（松开按键时调）
function M.unact(slot)
    PENDING[tonumber(slot) or 0] = nil
    return true
end

--- 有没人正在走过去做什么（供观测/测试）
function M.pending_act(slot)
    local pd = PENDING[tonumber(slot) or 0]
    return pd ~= nil, pd and pd.guid or nil
end

--=============================================================================
-- 主步进（M1）
--=============================================================================
-- ★ steps_done 已在上面声明（输入日志要用，必须是先声明的 local）
local moved_total = 0
local used_locomotor = 0     -- 走原版 locomotor 的 tick 数（供观测）
local used_physics = 0       -- 走 Physics 兜底的 tick 数
local walk_errors = 0        -- WalkInDirection 抛错次数（**不静默**：会在 stats 里报）
local last_walk_error = nil
function M.walk_errors() return walk_errors, last_walk_error end

--- 某个槽位这一帧的**方向**（世界单位向量）
local function dir_for_slot(slot)
    if slot == 0 then return dir_from_input() end          -- 槽位 0：真实 TheInput
    local st = INPUT_SLOTS[slot]
    if st == nil then return 0, 0 end
    local x, z = 0, 0
    if st.right then x = x + 1 end
    if st.left  then x = x - 1 end
    if st.up    then z = z + 1 end
    if st.down  then z = z - 1 end
    if x ~= 0 and z ~= 0 then
        local inv = 1 / math.sqrt(2)
        x, z = x * inv, z * inv
    end
    return x, z
end

--- 某个槽位这一帧**是否在跑**
local function run_for_slot(slot)
    if slot == 0 then return Input.TI:IsControlPressed("CONTROL_ATTACK") end  -- F = 跑
    local st = INPUT_SLOTS[slot]
    return st ~= nil and st.run == true
end

--- 驱动一个玩家的这一帧（本地玩家与网络玩家**共用同一份逻辑**）
local function step_one_player(slot)
    local p = slot_entity(slot)
    if p == nil then return end
    if slot == 0 and not M.player_ok then return end

    local x, z = dir_for_slot(slot)
    local run = run_for_slot(slot)

    -- ★★ P22：没有输入、但有「待做动作」⇒ **朝目标走过去**，到了就做（原地版 playercontroller）。
    --   有输入则**取消**待做 —— 玩家自己动就是改变主意了，尊重人的操作。
    if x ~= 0 or z ~= 0 then
        PENDING[slot] = nil
    else
        local pend = PENDING[slot]
        if pend ~= nil then
            local t = ent_table()[pend.guid]
            if t == nil or steps_done > pend.until_t then
                PENDING[slot] = nil
            else
                -- ★★ P61：**逐拍采样血量**，捕捉上一次 push 出去的那一击的结果。
                --   为什么不在 push 之后当场读：push 只是排队，执行在之后的拍
                --   （见 do_attack 上方那段实测）。
                --   为什么每拍都采：一次攻击可能分段掉血，逐拍采样能一次不漏；
                --   代价是「1 个 PENDING 目标 1 次属性读」，可忽略。
                if pend.hp_watch ~= nil then
                    local cur = hp_of(t)
                    if cur ~= nil then
                        if cur < pend.hp_watch then
                            atk_land_n = atk_land_n + 1
                            atk_dmg_n = atk_dmg_n + (pend.hp_watch - cur)
                            last_atk_why = string.format("命中 -%.2f（剩 %.1f）",
                                                         pend.hp_watch - cur, cur)
                        end
                        pend.hp_watch = cur
                    end
                end
                local px, pz = pos_of(p)
                local tx, tz = pos_of(t)
                if px ~= nil and tx ~= nil then
                    local dx, dz = tx - px, tz - pz
                    local d = math.sqrt(dx * dx + dz * dz)
                    if d > ACT_HIT then
                        local inv = 1 / math.max(d, 1e-6)
                        x, z = dx * inv, dz * inv          -- 朝它走
                    elseif steps_done >= pend.next_t then
                        local a = action_for(t)
                        if a ~= nil then
                            -- ★ P61：**必须**走 perform 而不是 push_action ——
                            --   否则 ATTACK 在「按住不放」这条路上会退回静默无效
                            --   （首次点击走了 do_attack，后续重发走了 push_action）。
                            local okA, whyA, performed = perform(p, t, a)
                            if okA and performed ~= false then
                                act_ok_n = act_ok_n + 1
                                last_act_refusal = nil
                            end
                            if not okA then last_act_refusal = whyA end
                        end
                        -- ★ 无论这一下**打中没打中**都要排下一拍：够得着的距离是 1.2，
                        --   而动作真正生效的距离更近，所以「打空」是正常现象，
                        --   靠下一拍补上（实测：就是靠这个容忍性才砍得倒）。
                        pend.next_t = steps_done + ACT_REPEAT
                    end
                end
            end
        end
    end

    local loco = p.components and p.components.locomotor
    local ang = dir_to_angle(x, z)

    if ang ~= nil then
        if loco and loco.WalkInDirection then
            -- ★ 原版接口：走速度倍率 / 朝向 / 地形。
            --   ⚠️ 第一参数是**朝向角（度）**（见 dir_to_angle 上方的取证），不是向量！
            local okW, errW = pcall(loco.WalkInDirection, loco, ang, run)
            if not okW then
                -- 反向保护：原版接口一旦抛错（例如签名又变了），必须**记账**而不是静默
                walk_errors = walk_errors + 1
                last_walk_error = tostring(errW)
            end
            used_locomotor = used_locomotor + 1
        elseif p.Physics and p.Physics.SetMotorVel then
            -- ★ 兜底路径：Physics 的 motor velocity 是**实体局部坐标**
            --   （见 host/11_physics.lua 文件头的取证），所以必须**先设朝向**
            --   再给「朝前」的速度 —— 否则又是一条「速度设了却往 +x 走」的同款坑。
            if p.Transform and p.Transform.SetRotation then
                p.Transform:SetRotation(ang)
            end
            p.Physics:SetMotorVel(4, 0, 0)
            used_physics = used_physics + 1
        end
        if p.sg == nil then anim_fallback_for(p, "run_loop") end
    else
        -- ★★ 必须用原版的 `Stop()`，**不是** `StopMoving()` —— 两个方法长得很像，
        --   但契约完全不同（原版 `components/locomotor.lua`）：
        --     · `Stop()`（2068 行）：清移动意图 + `ResetPath` + **`PushEvent("locomote")`**
        --       ⇒ 状态图据此**离开 walk/run 状态**。这是「移动意图 ↔ 移动状态」的握手。
        --     · `StopMoving()`（950 行）：只 `isrunning=false` + `Physics:Stop()`，
        --       **一个事件都不发**。
        --   用错的后果（实测）：位置立刻停住（看起来对），但状态图仍留在 `run`，
        --   **动画继续播约 4 秒**才因为别的原因（夜里被黑暗咬了一下）跳到 idle。
        --   ⇒ 症状是「人不走了，但腿还在跑」—— 只看坐标的判据永远发现不了。
        if loco and loco.Stop then
            pcall(loco.Stop, loco)
        elseif loco and loco.StopMoving then
            pcall(loco.StopMoving, loco)
        elseif p.Physics and p.Physics.Stop then
            p.Physics:Stop()
        end
        if p.sg == nil then anim_fallback_for(p, "idle_loop") end
    end
end

--=============================================================================
-- 死亡与复活（2026-10-16 加）
--=============================================================================
-- ★★★ 为什么需要它（实测出来的失败形态，见 §9y.7 / README 的已知限制）：
--   玩家死后状态机停在 `death`，之后 **`act` 仍然返回成功但什么都推不动**
--   （拿一棵树试：workleft 一动不动）⇒ 表现是「世界安静地不动了」。
--   而 `SGwilson` 的 death 状态是**出不去**的：
--   实测 `sg:GoToState("idle")` 直接报
--     `stategraphs/SGwilson.lua:3839: Left death state.`
--   ⇒ 只能**换一具身体**。原版这里走的也是换实体（人变成 ghost），
--     本宿主没有 `SGghost`，于是用「移除 + 重新生成」来等价地表达「重生」。
--   ⚠️ 这是**07 侧的行为选择**，不是原版语义：原版要跑回肉块/复活台才算复活。
--     ⇒ 如实写在注释与文档里（§9z / README），并且**记账**（`respawns` 进 stats）。
local RESPAWN_DELAY = 90        -- 拍：死后多久自动复活（3 s）
local DEATH_SINCE = {}          -- slot -> steps_done（第一次观察到该槽位已死的那一拍）
local respawn_n = 0
function M.respawn_stats() return respawn_n end

-- ★★ N4（2026-10-22）：死亡代价 —— 背包**掉一半**。
--   为什么原来一点代价都没有：`M.respawn` 里直接 `p:Remove()` 把尸体连同背包一起删了，
--   所以「死亡」在玩法上等于「免费回城」——没有紧张感，也就没有生存压力。
--   DST 原版是「全掉（或按设置不掉）」，这里取**一半**是 07 侧的设计选择：
--   全掉太惩罚（一次失误清空半小时积累），不掉又没压力。
--   ⚠️ 确定性而不是随机：隔一个掉一个。随机的话同一个存档重放两次掉的不是同一批，
--      E19 会变成一条"大多数时候能过"的判据 —— 那种判据比没有更糟。
local death_drop_total = 0
local DEATH_DROPPED = {}          -- slot -> 本次死了掉了几个（可观测）
function M.death_drops() return death_drop_total end
function M.death_dropped_of(slot) return DEATH_DROPPED[tonumber(slot) or 0] or 0 end

--- 死亡瞬间把一半背包丢到地上。返回丢了几件。
local function drop_half_on_death(slot, p)
    local inv = p.components and p.components.inventory or nil
    if inv == nil or inv.GetNumSlots == nil then return 0 end
    local okn, n = pcall(inv.GetNumSlots, inv)
    if not okn or type(n) ~= "number" or n <= 0 then return 0 end
    local okp, pos = pcall(function() return p:GetPosition() end)
    if not okp then pos = nil end
    local dropped = 0
    -- 从后往前：先掉高位槽位，避免"边删边遍历"导致的索引漂移
    for i = n - 1, 0, -1 do
        if i % 2 == 0 then
            local oki, item = pcall(inv.GetItemInSlot, inv, i)
            if oki and item ~= nil then
                pcall(function() inv:DropItem(item, false, nil, pos) end)
                -- ★★ 记账必须**回读**：`DropItem` 失败时也只是 return（不抛），
                --   所以 pcall 成功 ≠ 真的掉出来了。判据靠这个数判断"掉了一半"，
                --   数错就等于没验（本工程已在 invobject 记账上踩过一模一样的坑）。
                local oks, left = pcall(inv.GetItemSlot, inv, item)
                if oks and left == nil then dropped = dropped + 1 end
            end
        end
    end
    -- ★★ 掉完一半，**必须把另一半明确销毁**。
    --   实测（E19 首跑）：`M.respawn` 里 `p:Remove()` 会把背上剩下的物品**也丢到地上**，
    --   于是"掉一半"实际变成了"全掉"（复活后世界表里 4 件全在）。
    --   ⇒ 不写这一步，"一半"就只是注释里的一句话，而世界上发生的是"全掉"。
    for i = n - 1, 0, -1 do
        if i % 2 ~= 0 then
            local oki, item = pcall(inv.GetItemInSlot, inv, i)
            if oki and item ~= nil then
                pcall(function() item:Remove() end)
            end
        end
    end
    death_drop_total = death_drop_total + dropped
    DEATH_DROPPED[slot] = dropped
    return dropped
end

--- 复活一个已经死掉的玩家。返回 (ok, 新 guid 或 拒绝原因)
--- ★ 拒绝也要说得出原因（「没死就不该复活」是一条正常拒绝，不是错误）
function M.respawn(slot)
    slot = tonumber(slot) or 0
    local p = slot_entity(slot)
    if p == nil then return false, "没有玩家（槽位 " .. tostring(slot) .. "）" end
    local h = p.components and p.components.health
    if h == nil then return false, "玩家没有 health 组件" end
    if not h:IsDead() then return false, "玩家没死，不需要复活" end
    PENDING[slot] = nil                 -- 死前那个「待做动作」不作数了
    DEATH_SINCE[slot] = nil
    pcall(function() p:Remove() end)     -- 移除这具尸体（death 状态出不去，只能换身体）
    if slot == 0 then
        M.player = nil
        M.player_ok = false
        local ok, g = M.add_player(0)
        if not ok then return false, "重建默认玩家失败：" .. tostring(g) end
        respawn_n = respawn_n + 1
        return true, g
    end
    PLAYERS[slot] = nil
    local ok, g = M.add_player(slot)
    if not ok then return false, "重建角色失败：" .. tostring(g) end
    respawn_n = respawn_n + 1
    return true, g
end

-- 每拍检查一次：死了就计时，到点自动复活（否则世界会**永久停摆**）
local function auto_respawn()
    for _, slot in ipairs(M.player_slots()) do
        local p = slot_entity(slot)
        local h = p ~= nil and p.components and p.components.health or nil
        if h ~= nil and h:IsDead() then
            if DEATH_SINCE[slot] == nil then
                DEATH_SINCE[slot] = steps_done
                -- ★ 死的那一拍就掉，而不是等 3 秒后复活时才掉：
                --   复活时 `p:Remove()` 会把背包一起删掉，那时再想"掉一半"已经没东西可掉了。
                drop_half_on_death(slot, p)
            elseif steps_done - DEATH_SINCE[slot] >= RESPAWN_DELAY then
                M.respawn(slot)          -- 失败就下一拍再试（不静默：stats 里的 respawns 不涨）
            end
        elseif DEATH_SINCE[slot] ~= nil then
            DEATH_SINCE[slot] = nil
        end
    end
end

--=============================================================================
-- 07 侧的**语义补丁**：让 grue（黑暗里的查理）跟着**昼夜相位**走
--=============================================================================
-- ★★★ 为什么必须补（2026-10-16 查实）——06 宿主里两处桩**互相矛盾**：
--   · `host/01_core.lua:186`      LightWatcher:IsInLight = **true**
--       理由写的是「宿主世界恒为白天（isday 永远 true，没有昼夜/光照求解器）」——
--       ⚠️ **这条理由已经过期**：自从 `rt_boot/3` 挂上 5 个世界组件之后，宿主**有昼夜**了
--       （实测 state.phase 会 day→dusk→night 地变，温度也在变）。
--   · `host/06_entityscript.lua:189` EntityScript:IsInLight = **false**（理由：「无光照系统」）
--   ⇒ 两者**对同一件事给出相反答案**，而 `components/grue.lua:120` 的
--     `CheckForStart()` 读的正是 `inst:IsInLight()` ⇒ **恒 false**
--     ⇒ grue 永远认为「玩家在黑暗里」⇒ 世界开始 5~10 s
--       （`nextHitTime = 5 + math.random()*5`）就来一发
--       `combat:GetAttacked(nil, TUNING.GRUEDAMAGE, nil, "darkness")`
--     ⇒ **玩家 12 秒必死**。实测逐秒：`health 150 → 49.95（6 s）→ 0（12 s）`，
--       抓到的事件是 `attacked{damage=100.05, stimuli=darkness}`，
--       而 `TUNING.GRUEDAMAGE` 正是 **100.05** —— 指纹完全对上。
-- ★ 原版里这件事由 LightWatcher 的 `enterlight` / `enterdark` 事件驱动
--   （`grue.lua:8-14` 的 OnEnterLight/OnEnterDark 就是干这个的）。宿主没有光照场，
--   所以用**世界昼夜相位**当「光」的代理 —— 这是宿主里唯一可得的「光」信息。
-- ⚠️ 这是**代理，不是等价**：原版「站在营火旁边就不挨打」这类行为做不到
--   （宿主没有逐点光照）。所以：① 记账（`grue_sync` 进 stats，**不静默**）；
--   ② **不改 06**（那是保真基线），缺陷在 07 侧登记（见 开发计划 §9z）。
--=============================================================================
-- 光照代理（二）：**离点着的营火足够近 = 在光里**（2026-10-16 加）
--=============================================================================
-- 为什么需要：只按昼夜相位的话，夜里**必死**（§9z 把这条登记成了限制）。
--   原版的语义是「站在光里就不挨打」，而宿主没有逐点光照 ⇒
--   用「离**点着的**营火足够近」当代理。
-- 实测（探针，5 分钟世界时间）：营火**不会点燃**旁边的树（树的 burning 一直 false、
--   workleft 不变）⇒ 放火**是安全的**；但它**自己会烧完**（约 140 s 后实体被移除）
--   ⇒ 所以黄昏时要补一堆新的。
-- ⚠️ 这是**代理不是等价**：原版的光源还有火把/矿灯/发光生物，我们只有营火；
--   而且「火在哪儿点」是**本世界（07）的配置**，不是引擎规则 —— 如实登记在 §9ae。
local LIGHT_R = 7                    -- 世界单位：离点着的火这么近就算「在光里」
local FIRE_GUIDS = {}                -- 我们点过的火（只遍历这些，不扫全世界）
local fires_lit_n = 0
local LIGHT_STATE = {}               -- slot -> { applied = bool, entity = 实体 }
local grue_sync_n = 0

--- 「哪些实体算光源」。**这是 07 侧的世界配置**：默认只有黄昏时点的那堆营火。
--- ★ 为什么做成公开入口：① 以后加火把/矿灯只要登记一下；② 判据要能**造场景**
---   （不然它只能靠「等 430 秒让黄昏去点火」来测，那太慢也太脆）。
function M.add_light_source(guid)
    guid = tonumber(guid)
    if guid == nil then return false, "guid 必须是数字" end
    for _, g in ipairs(FIRE_GUIDS) do
        if g == guid then return true, "已在册" end
    end
    FIRE_GUIDS[#FIRE_GUIDS + 1] = guid
    return true, "已登记"
end
function M.light_sources() return #alive_lit_fires(), fires_lit_n end

--- 「这个光源还亮着吗」：有 `burnable` 就看 `IsBurning()`（营火就是这么报自己的），
--- 没有 `burnable` 的（将来可能有的发光物）按**一直亮**算。已经消失的从名册里剔掉。
local function is_lit(inst)
    if inst == nil or not inst:IsValid() then return false end
    local b = inst.components and inst.components.burnable or nil
    if b ~= nil then return b:IsBurning() end
    return true
end

--- 还**点着**的火（顺便把已经烧完/消失的清出名册）
local function alive_lit_fires()
    local out = {}
    local et = ent_table()
    for i = #FIRE_GUIDS, 1, -1 do
        local f = et[FIRE_GUIDS[i]]
        if is_lit(f) then
            out[#out + 1] = f
        else
            table.remove(FIRE_GUIDS, i)
        end
    end
    return out
end

--- 世界坐标 (x,z) 在不在「光」里。
--- ★ `isnight` 由**调用方**给 ⇒ 这个函数是**纯的**（不读世界状态、不碰 grue）
---   ⇒ 判据可以直接喂 `isnight=true` 去验「火的光照」，不用等 430 秒的世界时间。
function M.in_light_at(x, z, isnight)
    if not isnight then return true end          -- 白天/黄昏：世界自带的环境光
    for _, f in ipairs(alive_lit_fires()) do
        local fx, fz = pos_of(f)
        if fx ~= nil then
            local d = math.sqrt((fx - x) ^ 2 + (fz - z) ^ 2)
            if d <= LIGHT_R then return true end
        end
    end
    return false
end

--- 黄昏/夜里如果没有点着的火，就在玩家附近点一堆。
--- ⚠️ 这是**本世界的配置**（让玩家夜里有个地方可待），不是引擎规则：原版要玩家自己造火。
local function light_fire_near_player()
    if #alive_lit_fires() > 0 then return false end
    local p = M.player
    if p == nil then return false end
    local px, pz = pos_of(p)
    if px == nil then return false end
    local ok, f = pcall(Core.SpawnPrefab, "campfire")
    if not ok or f == nil then return false end
    local ang = (steps_done % 628) / 100      -- 每次换个方位，免得总是同一个点
    if f.Transform ~= nil and f.Transform.SetPosition ~= nil then
        f.Transform:SetPosition(px + math.cos(ang) * 2.5, 0, pz + math.sin(ang) * 2.5)
    end
    if f._guid ~= nil then
        FIRE_GUIDS[#FIRE_GUIDS + 1] = f._guid
        fires_lit_n = fires_lit_n + 1
    end
    return true
end
function M.fires_stats() return #alive_lit_fires(), fires_lit_n end

--- 「离火多近算在光里」的**可调**入口（默认 7）。判据用它做反向验证：
--- 把半径设成 0 ⇒ 站在火边也**不算**在光里 ⇒ 夜间那套保护就应当失效。
function M.set_light_radius(r)
    LIGHT_R = tonumber(r) or LIGHT_R
    return LIGHT_R
end
function M.light_radius() return LIGHT_R end

--==============================================================================
-- ★★★ P38：「随身光源」（补 §9ae 登记的那条代理缺口：火把/矿灯不算光源）
--==============================================================================
-- 缺口是什么：上面的光照代理只认「**世界里某个固定坐标**的点着的营火」⇒
--   玩家夜里举着火把走，一旦离开火堆就重新算「不在光里」⇒ 照样被黑暗打死。
--   原版里这是靠「手上装备的火把带 Light 组件」实现的。
--
-- ★ 探针先说清楚**为什么不能直接照搬原版**（实测，2026-10-16）：
--     `Core.SpawnPrefab("torch")` 能出来，但组件是
--     `[burnable, equippable, fueled, lighter, inventoryitem, weapon …]` ——
--     **没有 `light`**；`lantern` 同样没有。⇒ 宿主里「火把发光」**没有组件支撑**，
--     只能继续用**代理**：把「这个槽位的玩家随身带着一个光源」直接登记出来。
--
-- ★★ 为什么挂在**槽位**上、而不是登记实体 guid（这是这一节的关键）：
--     玩家**死亡会自动换一具身体**（`M.respawn`：移除旧实体 + `add_player`），
--     guid 会变。若按 guid 登记，复活一次随身光源就**悄悄失效**了。
--     槽位是稳定的 ⇒ 按槽位登记，复活后仍然有效。（判据 E9 专门测这一条。）
--
-- ⚠️ 仍然是**代理不是等价**：它不模拟「燃料烧完」「火把会被雨浇灭」这些真实规则。
--   如实登记在 §9ak；默认**不开**（保持 P30 的行为：黄昏自动在玩家附近点火）。
local PLAYER_LIGHT = {}              -- slot -> 半径（nil/<=0 = 没有随身光源）

--- 给某个槽位的玩家开/关「随身光源」。`r <= 0` 或省略即关掉。
--- ★ 返回值与 `add_light_source` 同风格：`(true, 说明)`。
function M.set_player_light(slot, r)
    slot = tonumber(slot)
    if slot == nil then return false, "slot 必须是数字" end
    r = tonumber(r)
    if r == nil or r <= 0 then
        PLAYER_LIGHT[slot] = nil
        return true, "已关掉槽位 " .. tostring(slot) .. " 的随身光源"
    end
    PLAYER_LIGHT[slot] = r
    return true, string.format("槽位 %d 的随身光源半径 = %.2f", slot, r)
end

--- 查某个槽位的随身光源半径（没开则 nil）。
function M.player_light(slot) return PLAYER_LIGHT[tonumber(slot) or -1] end

--- 全部随身光源（键是**字符串**槽位，理由同 `slot_keys`：Lua 数组从 1 起、槽位从 0 起）。
function M.player_lights()
    local out, n = {}, 0
    for k, v in pairs(PLAYER_LIGHT) do out[tostring(k)] = v; n = n + 1 end
    return out, n
end

--- 某个槽位的玩家在不在光里（**把他自己的随身光源也算进去**）。
--- ★ 随身光源就在他身上 ⇒ 只要开着（r > 0）就一定照得到**他自己** ⇒ 直接算在光里。
---   （半径 `r` 的意义是「将来可以照亮**别人**」，但本代理只关心「他自己在不在光里」。）
--- ★ 与 `in_light_at` 一样是**纯的**：`isnight` 由调用方给 ⇒ 判据不用等黄昏。
function M.in_light_for_slot(slot, x, z, isnight)
    if not isnight then return true end
    local r = PLAYER_LIGHT[tonumber(slot) or -1]
    if r ~= nil and r > 0 then return true end
    return M.in_light_at(x, z, isnight)
end

--- 每个槽位的「在不在光里」→ grue 免疫。
--- ★★ 「光」现在是**位置相关**的（离火远近）⇒ 不能只在相位翻转时算一次，
---   也不能只缓存「相位」：缓存键必须包含**实体与光照状态**（换身体、走进走出火光都要重算）。
local function sync_grue_light()
    local st = TheWorld ~= nil and TheWorld.state or nil
    local isnight = st ~= nil and st.isnight == true
    -- 黄昏（或夜里火灭了）⇒ 补一堆火（见上）
    if st ~= nil and (st.phase == "dusk" or isnight) then light_fire_near_player() end
    for _, slot in ipairs(M.player_slots()) do
        local p = slot_entity(slot)
        local g = (p ~= nil and p.components) and p.components.grue or nil
        if g ~= nil then
            local px, pz = pos_of(p)
            local lit = true
            -- ★ P38：走 in_light_for_slot（= 营火代理 **+ 这个槽位的随身光源**）
            if px ~= nil then lit = M.in_light_for_slot(slot, px, pz, isnight) end
            local cur = LIGHT_STATE[slot]
            if cur == nil then cur = {}; LIGHT_STATE[slot] = cur end
            -- ★ 两个触发条件缺一不可：① 光照状态变了；② **玩家实体换了**
            --   （复活会换一具身体，新实体的 immunity 表是空的）——
            --   只判①是原来那版，探针立刻抓到：复活后新的那具身体白天又开始挨打。
            if cur.applied ~= lit or cur.entity ~= p then
                cur.applied, cur.entity = lit, p
                if lit then
                    g:AddImmunity("light")        -- 在光里：等价于原版的 enterlight
                else
                    g:RemoveImmunity("light")     -- 黑暗里：等价于原版的 enterdark
                end
                grue_sync_n = grue_sync_n + 1
            end
        end
    end
end
function M.grue_sync_stats()
    local cur = LIGHT_STATE[0]
    return grue_sync_n, (cur == nil and nil or cur.applied)
end

-- ★★★ N1（2026-10-22）：**碰撞解算** —— 人不能穿过树。
--
-- 为什么原来会穿：移动走的是 `locomotor`（`E1/A8` 验过是原版路径），而原版的碰撞
-- 依赖引擎侧的物理积分 + `CanPathTo`；本宿主**没有物理引擎**（`stats.used_physics` 恒 0），
-- 于是 `locomotor` 只负责"沿方向改变坐标"，不负责"别撞上东西"。
-- 实测：spawn 一棵树在 (3,0)，按住「右」6 秒，玩家 x 从 0 一路走到 **35.6** —— 直接穿过去。
--
-- 做法：每拍**移动之后**做一次圆形重叠分离（玩家圆 + 障碍圆 ⇒ 推到刚好相切）。
--   · 只对"有位置、不是玩家、不是背包物品"的实体做 —— 地上的 log 不该挡人；
--   · 完全重合时沿 +x 推开一点点，**不做随机方向**（随机会让同一份录像重放不出同一世界，
--     而 B18 的逐 tick 指纹判据会立刻变红）；
--   · 每次推开记账（`collide_n`），让"到底有没有在挡"变成可观测的数，
--     而不是靠"看起来没穿过去"。
local collide_n = 0
function M.collide_pushes() return collide_n end

local function _radius_of(inst, fallback)
    if inst == nil then return fallback end
    if inst.GetPhysicsRadius ~= nil then
        local ok, r = pcall(inst.GetPhysicsRadius, inst, fallback)
        if ok and type(r) == "number" and r > 0 then return r end
    end
    return fallback
end

-- ★★★ 修正（同一天，第一次实现是错的）：不能用「当前重叠就推开」。
--   实测：collide 记账涨到 159，玩家还是走过去了 —— 因为一拍 locomotor 推 0.65 格，
--   而玩家一旦**越过树心**，"远离树心"的方向就变成了**继续前进**的方向 ⇒ 推开 = 帮他穿模。
--   正确做法是**连续碰撞检测**：拿上一拍位置与本拍位置连成线段，与障碍圆求交，
--   把玩家挡在**入射侧**。
--   （这是本工程第三次遇到同一形状：局部修正看着在工作、实际在放大问题。
--     前两次是 atk_hit 记在 push 之前、invobject 记在"打算传"的变量上。）
local prev_pos = {}          -- slot -> {x, z}

local function _seg_hits_circle(x0, z0, x1, z1, cx, cz, r)
    local dx, dz = x1 - x0, z1 - z0
    local a = dx * dx + dz * dz
    if a < 1e-9 then return nil end
    local fx, fz = x0 - cx, z0 - cz
    local b = 2 * (fx * dx + fz * dz)
    local c = fx * fx + fz * fz - r * r
    -- ★★ 起点已经在圆内/圆上 ⇒ **完全挡住**，返回一个极小的 t。
    --   不这么写的话：起点在圆上时 c≈0，两个根是 0 和 t2（穿出点），
    --   而 t>0 过滤掉 0 ⇒ 返回 t2 ⇒ 玩家被"放行到圆另一侧"。
    --   实测就是这么蹭过去的：x 从 0 → 0.65 → 2.35 → 4.85，看着每次都被挡，
    --   实际上每拍都在往对面挪一点。**"被挡住"和"没穿过去"是两件事。**
    if c <= 0 then return 1e-4 end
    local disc = b * b - 4 * a * c
    if disc < 0 then return nil end
    local sq = math.sqrt(disc)
    local t1 = (-b - sq) / (2 * a)
    local t2 = (-b + sq) / (2 * a)
    local best = nil
    for _, t in ipairs({ t1, t2 }) do
        if t > 0 and t <= 1 and (best == nil or t < best) then best = t end
    end
    return best
end

local function block_movement(slot, p)
    local x, z = pos_of(p)
    if x == nil then return 0 end
    local pv = prev_pos[slot]
    prev_pos[slot] = { x = x, z = z }
    if pv == nil then return 0 end
    if (x - pv.x) * (x - pv.x) + (z - pv.z) * (z - pv.z) < 1e-8 then return 0 end

    local okF, list = pcall(function() return TheSim:FindEntities(pv.x, 0, pv.z, 6.0) end)
    if not okF or list == nil then return 0 end
    local rp = _radius_of(p, 0.35)
    local best_t = nil
    for i = 1, #list do
        local e = list[i]
        if e ~= p and e.Transform ~= nil
           -- ★★ 排除**附属实体**：`player_classified` / `inventory_classified` 这些
           --   "网络镜像实体"跟着玩家走、也有 Transform，但不该参与碰撞。
           --   不排除的话，玩家会被**自己的背包**挡住 —— 实测表现是"从第一拍就完全走不动"，
           --   而 collide 记账一直在涨（看着像碰撞在工作）。
           and not (e.HasTag ~= nil and (e:HasTag("player") or e:HasTag("INLIMBO")
                                          or e:HasTag("CLASSIFIED")))
           and not (e.components ~= nil and e.components.inventoryitem ~= nil)
        then
            local ex, ez = pos_of(e)
            if ex ~= nil then
                local t = _seg_hits_circle(pv.x, pv.z, x, z, ex, ez,
                                           rp + _radius_of(e, 0.3))
                if t ~= nil and (best_t == nil or t < best_t) then best_t = t end
            end
        end
    end
    if best_t == nil then return 0 end
    -- 退到交点前一点点（0.95），避免下一拍从圆内开始、判定退化成"已经嵌进去了"
    local nx = pv.x + (x - pv.x) * best_t * 0.95
    local nz = pv.z + (z - pv.z) * best_t * 0.95
    pcall(function() p.Transform:SetPosition(nx, 0, nz) end)
    prev_pos[slot] = { x = nx, z = nz }
    collide_n = collide_n + 1
    return 1
end

function M.step(dt)
    dt = tonumber(dt) or M.dt
    if dt <= 0 then
        -- ★ 反向保护：dt<=0 必须报错，而不是静默推进
        error("rt_boot.step: dt must be > 0, got " .. tostring(dt))
    end

    -- ★ 光照代理（见上方说明）：白天给光免疫、入夜撤掉。只在相位翻转那一步动手。
    sync_grue_light()

    -- ★ 死了就计时，到点自动复活（否则世界会永久停摆 —— 见 M.respawn 上方的说明）
    auto_respawn()

    -- ★ P20：逐个槽位驱动。槽位 0 走真实 TheInput，其余走各自的输入表。
    --   抽取成同一个函数的意义：**每个玩家的驱动逻辑只有一份** ——
    --   否则「本地玩家能走、网络玩家不能走」这类差异会以「某个方向不动」的形式出现，
    --   而那是本工程已经踩过两次的坑（方向/停止各一次）。
    for _, slot in ipairs(M.player_slots()) do
        step_one_player(slot)
        -- ★ 移动之后做连续碰撞检测：放在驱动之后，才不会把这一拍的输入抵消掉
        local pp = slot_entity(slot)
        if pp ~= nil then block_movement(slot, pp) end
    end

    Sim.Step(dt)
    steps_done = steps_done + 1

    if M.player and M.player_ok and M.player.Physics
       and M.player.Physics.GetMovedTotal then
        local mt = M.player.Physics:GetMovedTotal()
        if type(mt) == "number" then moved_total = mt end
    end
    return steps_done
end

--=============================================================================
-- 快照（M3 的源数据）
--=============================================================================
function ent_table()
    return _G.Ents or (G and G.Ents) or {}
end

function pos_of(inst)
    local T = inst.Transform
    if T == nil then return nil end
    local x, y, z
    if T.GetWorldPosition then x, y, z = T:GetWorldPosition() end
    if x == nil then return nil end
    return x, z
end

function M.snapshot()
    local ents, ents_out = ent_table(), {}
    -- ★★★ H5：原来这里是 `if n >= MAX_ENTS then break end` 直接跳循环 —— 代价是**丢了多少根本不知道**：
    --   实测 456 个实体只送 400，返回里却一个标记都没有，读日志的人会以为世界就这么大。
    --   现在改为「全表扫描一次，超额的只计数不构造」，于是可以如实报 total / dropped / truncated。
    --   为什么不怕变慢：这个循环本来就要遍历实体表做过滤（见下面「只送画得出来的」），
    --   早退省下的只是「超额那一小段的构造开销」，而世界规模上限本来就只有几百。
    local n_total, n_out = 0, 0
    for guid, inst in pairs(ents) do
        local x, z = pos_of(inst)
        -- ★★★ 只送**画得出来**的实体（有 build 的）。
        --   实测（默认世界 + 40 个生成，共 67 个实体）：有 build 的 41 个 = 全部生物；
        --   没 build 的 26 个 = **全部是 `*_classified`**（`player_classified` /
        --   `inventory_classified` / `inventoryitem_classified` / `writeable_classified`）。
        --
        --   为什么要过滤（三个理由，都实测过）：
        --     ① `*_classified` 是**客户端侧的镜像实体** —— 真实架构里它们由客户端
        --        根据本体自己生成，**不该由服务端当独立实体送出去**。送出去等于多一份。
        --     ② 它们**没有 build ⇒ 画不出来**，客户端只能画**回退灰点**。
        --        而它们的坐标全都停在 (0,0)（宿主没做父子跟随）⇒ 症状是
        --        **原点堆了一坨灰点**，而且玩家一出生就压在中间。
        --     ③ 顺带也排掉了宿主内部登记实体（`TheWorld` 本体、`knownlocations`）——
        --        它们同样没有 prefab、没有 build。
        --
        --   ★ 判据不是「名字里带 _classified」（那是**猜名字**），而是
        --     「**有没有 build**」——这是客户端**画得出来**的充要条件，
        --     换成别的内部实体同样成立，不需要再维护一张名单。
        local as0 = inst.AnimState
        if x ~= nil and inst.prefab ~= nil and as0 ~= nil and as0._build ~= nil then
            n_total = n_total + 1                 -- 画得出来的总数（含超出上限、不送的那些）
            if n_out < MAX_ENTS then
                n_out = n_out + 1
                local e = { id = guid, x = x, z = z }
                e.p = inst.prefab
                e.f = inst.AnimState and inst.AnimState._rotation or nil
                e.a = inst.AnimState and inst.AnimState._anim or nil
                -- ★ P4：出**真图集精灵**需要的三个字段
                --   bld = build 名（对应 _out/json/<bld>.json 与 anim_data/<bld>__atlas-N.png）
                --   fr  = 当前帧号（anims[anim].frames[fr]）
                --   ov  = 覆盖 build（换装后会变，决定用哪套图）
                local as = inst.AnimState
                if as ~= nil then
                    e.bld = as._build
                    e.fr  = as._frame
                    -- ★ 故意**不送** `_ov_builds`：宿主那张表只增不减（工程报告里记着的已知问题，
                    --   实测 22→23→23），送出去只会误导「换了什么装」还白费带宽。
                    --   要判断换装，看 bld 本身就够了（OverrideSymbol 会改 _build）。
                end
                ents_out[#ents_out + 1] = e
            end
        end
    end

    -- ★★ 按 id **排序**：`pairs` 的顺序是**未定义**的，而客户端是**按帧序绘制**的
    --   ⇒ 顺序一变，精灵的前后关系就变（实体增删时尤其明显）⇒ 画面**闪**。
    --   排序是稳定的、零成本的（一帧几十~几百个元素），换来「画出来的前后关系每次都一样」。
    table.sort(ents_out, function(a, b) return a.id < b.id end)

    local px, pz
    if M.player and M.player_ok then px, pz = pos_of(M.player) end

    return {
        t      = Sim.TheSim.time,
        tick   = steps_done,
        -- ★ `n` 保持旧语义 = **实际送出去的个数**（客户端 `实体=N` 读它，避免一改就显示 456 却只画 400）；
        --   真实总量另给 `total`，超出部分给 `dropped`，并置 `truncated`。
        --   三者一起看才是「世界有多大 / 你看见了多少 / 少了多少」，缺一个就会误判。
        n      = n_out,
        total  = n_total,
        dropped = n_total - n_out,
        truncated = (n_total > n_out),
        ents   = ents_out,
        player = (px ~= nil) and { id = M.player._guid, x = px, z = pz } or nil,
        input_seq = Input.seq(),
        -- ★ 世界环境（昼夜/季节/温度）：客户端拿它做明暗与色调。
        --   送出去的是**每秒变化量很小**的几个值，一帧多带 ~10 字节，
        --   换来的是「画面里能看见天黑」——不送的话夜里和大白天长得一模一样。
        world  = world_env(),
    }
end

-- ★ 把 [0, 2^32) 的整数拆成 hi/lo 两段（各 < 65536）。
--   为什么要拆，见 M.fingerprint 里「%d 是 C int」那段注释 —— 不是风格问题：
--   不拆的话指纹里有两个字段**恒为常数**，等于没进指纹。
local function u32_parts(v)
    v = v % 4294967296
    return math.floor(v / 65536), v % 65536
end

function M.fingerprint()
    local px, pz = 0, 0
    if M.player and M.player_ok then px, pz = pos_of(M.player) end

    -- ★★★ M1：把**世界**也压进指纹。
    --   改之前只有 `px/pz/moved` 三个玩家量 ⇒ 指纹相同只说明「玩家没走歪」：
    --   NPC 走岔了、植被被清了、实体增删了，指纹**一模一样**。
    --   而回放是本工程唯一能自动发现「行为悄悄变了」的手段，弱指纹等于没有。
    --
    --   两个硬要求：
    --     ① 覆盖所有 **有 prefab** 的实体（NPC / 植被 / 内部登记实体都算）；
    --     ② **与 pairs 顺序无关** —— `pairs` 的遍历顺序未定义，用「按顺序滚动」必然假红。
    --        这里用 sum(h) 与 sum(h²) 两个可交换的滚动量，任何交换都不改变结果；
    --        再配 count，三者一起基本排除了「换了位置但和不变」的巧合。
    --   量化 0.1：世界坐标本来就在 0.25 网格上，0.1 吃掉浮点尾差，
    --   又远小于「走一步」（0.25 ⇒ 至少 2~3 个量化单位），不会把真变化抹平。
    local cnt, hsum, hsq = 0, 0, 0
    for _, inst in pairs(ent_table()) do
        local p = inst.prefab
        if p ~= nil then
            local x, z = pos_of(inst)
            if x ~= nil then
                cnt = cnt + 1
                local key = string.format("%s|%d|%d", p,
                    math.floor(x * 10 + 0.5), math.floor((z or 0) * 10 + 0.5))
                local h = 2166136261                      -- FNV-1a 32 位
                -- ★ 这里也必须拆：Lua 5.1 的数字是 double（53 位尾数），
                --   `h * 16777619` 会上到 2^56 量级 ⇒ **低 3 位直接被舍掉**，
                --   所谓「32 位哈希」实际只剩 ~28 位有效。拆成 hi/lo 之后
                --   每一步乘积都 < 2^41，逐位精确。
                for i = 1, #key do
                    local lo = h % 65536
                    local hi = (h - lo) / 65536
                    h = ((hi * 16777619 % 65536) * 65536
                         + lo * 16777619 + string.byte(key, i)) % 4294967296
                end
                hsum = (hsum + h) % 4294967296
                -- h² mod 2^32：直接 `h * h` 会到 2^64，double 存不下。
                --   展开 (hi·2^16 + lo)² = lo² + 2·hi·lo·2^16 + hi²·2^32，
                --   末项 ≡ 0 (mod 2^32)，剩下的最大 ~2^49 ⇒ 精确。
                local hl = h % 65536
                local hh = (h - hl) / 65536
                hsq  = (hsq + hl * hl + 2 * hh * hl * 65536) % 4294967296
            end
        end
    end

    -- ★★★ `%d` 在 Lua 5.1 里是 **C int（32 位有符号）**，不是「随便一个整数」：
    --   hsum/hsq 都落在 [0, 2^32)，一旦 ≥ 2^31 就被压成 `-2147483648`。
    --   实测（B21 回放抓到）：`esum=-2147483648 esq=-2147483648` **恒为常数**
    --   ⇒ M1 好不容易加进来的「实体滚动和」一个 bit 都没进指纹，只剩 ecnt 有用，
    --   而「实体没增删、只是走岔了 / 被挪走了」这种最该抓的漂移**完全看不见**。
    --   拆成 `hi.lo` 两段（各 < 65536）后 %d 永远安全，且**信息一位不丢**。
    local sum_hi, sum_lo = u32_parts(hsum)
    local sq_hi,  sq_lo  = u32_parts(hsq)
    local s = string.format(
        "seed=%d tick=%d t=%.4f px=%.4f pz=%.4f moved=%.3f esum=%d.%d esq=%d.%d ecnt=%d",
        SEED, steps_done, Sim.TheSim.time, px or 0, pz or 0, moved_total,
        sum_hi, sum_lo, sq_hi, sq_lo, cnt)
    local h = 0
    for i = 1, #s do
        h = (string.byte(s, i) + h * 65599) % 4294967296
    end
    return s, h
end

--=============================================================================
-- P39：**玩家自身状态**（HUD 用）—— 血量 / 饥饿 / 理智 / 背包
--=============================================================================
--[[ 为什么需要这个入口（缺口是什么）

  到 P38 为止，玩家身上**已经**有 health / hunger / sanity / inventory 四个组件
  （实测：wilson 共 88 个组件，四个都在），但它们对**用户**完全不可见：
    · HUD 只有 tick / 相位 / 温度 / 目标 / 预测误差；
    · 捡起一根木头之后，屏幕上**一个字都没有**（东西确实进了背包，`itemslots` 里有）；
    · 「饿」这件事根本没有出口 —— 饿到 0 会掉血，而用户只会看到「莫名在掉血」。
  ⇒ 本轮把这些读出来给客户端（**只读，不改任何语义**）。

  ★ 一个字段名的坑，值得写下来：
    我第一版探针读的是 `hunger.hunger` / `health.currenthealth`，结果显示
    「hunger 读不到（ERROR）」—— 差点据此得出「hunger 是桩」的错误结论。
    实际是：原版 `components/hunger.lua` 的字段叫 **`current` / `max`**
    （`self.current = self.max`，见该文件 :109），`hunger` 只是名字里那个词。
    而我的探针写的是 `ok and v or "ERR"` —— **v 为 nil 时也会落到 "ERR"**。
    ⇒ 又一条「我量的不是我以为我量的东西」：**探针自己把 nil 显示成了错误**。

  ★ 为什么按**槽位**取（与 P38 的随身光源同一个理由）：死亡会自动换一具身体，
    按 guid 存状态会在复活时悄悄失效。
]]
function M.player_state(slot)
    slot = tonumber(slot) or 0
    local p = slot_entity(slot)
    if p == nil then
        -- ★ 明确回「没有这个玩家」，**不回一串 0**：
        --   0 血 / 0 饿 在客户端看起来像「快死了」，而事实是「这个人不存在」。
        return { ok = false, slot = slot, why = "槽位 " .. tostring(slot) .. " 没有玩家" }
    end
    local c = p.components or {}
    local hp, hu, sa, inv = c.health, c.hunger, c.sanity, c.inventory

    -- 背包：**按 prefab 聚合**（原版没有 `GetItems`，只能自己扫 itemslots 逐槽读 ——
    -- 原版真接口见 `inventory.lua`：`GetItemInSlot` / `FindItem` / `Has` / `GetNumSlots`）
    local items, by_prefab, used, total_n = {}, {}, 0, 0
    if inv ~= nil and inv.itemslots ~= nil then
        for _, it in pairs(inv.itemslots) do
            if it ~= nil then
                used = used + 1
                local n = 1
                local st = it.components and it.components.stackable
                if st ~= nil and st.stacksize ~= nil then n = st.stacksize end
                total_n = total_n + n
                local key = tostring(it.prefab)
                local row = by_prefab[key]
                if row == nil then
                    row = { p = key, n = 0 }
                    by_prefab[key] = row
                    items[#items + 1] = row
                end
                row.n = row.n + n
            end
        end
    end
    -- 数量多的排前面（同数量按名字，保证**顺序稳定**：客户端 HUD 每 0.5 s 刷一次，
    -- 顺序乱跳会看起来像「东西在闪」）
    table.sort(items, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.p < b.p
    end)

    return {
        ok      = true,
        slot    = slot,
        guid    = p._guid,
        alive   = hp ~= nil and ((hp.currenthealth or 0) > 0) or false,
        health    = hp and hp.currenthealth or nil,
        maxhealth = hp and hp.maxhealth or nil,
        -- ★ 字段名是 current/max（不是 hunger/hungermax）
        hunger    = hu and hu.current or nil,
        maxhunger = hu and hu.max or nil,
        sanity    = sa and sa.current or nil,
        maxsanity = sa and sa.max or nil,
        items   = items,
        used    = used,                                  -- 占了几格
        total   = total_n,                               -- 一共几件（含堆叠）
        slots   = inv and inv.GetNumSlots and inv:GetNumSlots() or nil,
    }
end

function M.stats()
    local c = 0
    -- ★ 顺便数一下「威尔逊实体」的个数（2026-10-16 加）。
    --   为什么值得单列：判据 D2 要证明「宽限期过了旧角色真的被回收」，
    --   它原来用的是 `n_ents <= 20` 这种**跟世界大小绑死的魔法数** ——
    --   而这一天默认世界刚被塞进 14 个植物，那个数立刻就不成立了
    --   （报「实体数 25，空壳没被回收」，其实空壳早清了）。
    --   ⇒ 判据该问的是**它真正关心的东西**：世界里到底有几个玩家实体。
    local n_player_ents = 0
    for _, inst in pairs(ent_table()) do
        c = c + 1
        if inst.prefab == "wilson" then n_player_ents = n_player_ents + 1 end
    end
    -- ★★ **每个槽位**的存活与血量（2026-10-16 加）。
    --   为什么必须按槽位：`player_alive`/`player_health` 说的是**槽位 0**，
    --   而多客户端时客户端可能拿到槽位 1/2… ⇒ 只看那两项会得出
    --   「杀了客户端，却报「玩家还活着」」这种**看起来像 bug 的误判**。
    --   （跨进程判据 E8 就是这么被卡住的：日志里明明杀了槽位 1、也复活了，
    --     而 `/healthz` 的 `player_alive` 一直 true —— 因为它说的是槽位 0。）
    local players = {}
    for _, slot in ipairs(M.player_slots()) do
        local q = slot_entity(slot)
        local qh = (q ~= nil and q.components) and q.components.health or nil
        players[tostring(slot)] = {
            alive  = qh == nil and "?" or ((qh.currenthealth or 0) > 0),
            health = qh ~= nil and qh.currenthealth or nil,
            guid   = q ~= nil and q._guid or nil,
            -- ★ P38：这个槽位**现在**在不在光里（见 sync_grue_light / in_light_for_slot）。
            --   放进来是为了「运行时看得见」：夜里被判「不在光里」正是挨打的原因，
            --   而它以前只在 LIGHT_STATE 这个**局部表**里，外面看不到。
            in_light = LIGHT_STATE[slot] == nil and "?" or (LIGHT_STATE[slot].applied == true),
            light_r  = PLAYER_LIGHT[slot],          -- 随身光源半径（nil = 没开）
            -- ★ P39：饥饿 / 理智也上运维面 —— 玩家会**饿死**，而在此之前
            --   `/healthz` 只看得到血：血量一直掉却说不出为什么（饿的、冻的、还是被咬的）。
            hunger   = (q ~= nil and q.components and q.components.hunger)
                       and q.components.hunger.current or nil,
            sanity   = (q ~= nil and q.components and q.components.sanity)
                       and q.components.sanity.current or nil,
        }
    end
    local n_player_light = 0
    for _ in pairs(PLAYER_LIGHT) do n_player_light = n_player_light + 1 end
    -- ★★ 玩家生死（2026-10-16 加）。
    --   查「树为什么砍不倒」时抓到的真因：世界开始后玩家 health **持续掉**
    --   （实测 150 → 49.95（6 s）→ 0（12 s）），随后状态机停在 `sg=death`，
    --   **此后 `act` 再也推不动任何动作 —— 但 push 依旧返回成功**。
    --   表现就是「世界安静地不动了」，日志里一个字都没有。
    --   这与「失败要吵」是同一条纪律：**死必须看得见**（所以它出现在 /healthz 与 /status 上）。
    local ph = M.player ~= nil and M.player.components and M.player.components.health or nil
    return {
        tick      = steps_done,
        time      = Sim.TheSim.time,
        tick_hz   = TICK_HZ,
        n_ents    = c,
        -- ★ 世界里「威尔逊实体」的个数：正常应等于**玩家槽位数**。
        --   比 n_ents 更适合当「有没有空壳角色漏掉」的判据（见上面那段说明）。
        player_ents = n_player_ents,
        player_ok = M.player_ok,
        player_alive  = ph == nil and "?" or ((ph.currenthealth or 0) > 0),
        player_health = ph ~= nil and ph.currenthealth or nil,
        -- ★ 按槽位的存活/血量/guid（见上面的说明）：`player_alive` 只代表**槽位 0**
        players = players,
        -- ★ 光照代理的状态（见 sync_grue_light）：在光里 ⇒ 免疫为 true。
        --   放进 stats 是为了「运行时能看见」，而不是只在文档里写着。
        grue_immune   = LIGHT_STATE[0] == nil and "?" or (LIGHT_STATE[0].applied == true),
        grue_sync     = grue_sync_n,
        -- ★ 火：还点着几堆 / 一共点过几堆（见 light_fire_near_player）
        fires         = #alive_lit_fires(),
        fires_lit     = fires_lit_n,
        -- ★ P38：开着「随身光源」的槽位数（见 M.set_player_light）
        player_light  = n_player_light,
        -- ★ 自动复活的次数（见 M.respawn）。放进 stats 是为了「运行时看得见」：
        --   原版没有「N 秒自动复活」，这是 07 侧的行为选择，必须能被观测到。
        respawns      = respawn_n,
        input_seq = Input.seq(),
        moved     = moved_total,
        used_locomotor = used_locomotor,
        used_physics   = used_physics,
        walk_errors    = walk_errors,
        act_ok         = act_ok_n,
        act_refused    = act_refused_n,
        last_refusal   = last_act_refusal,
        -- ★★ P61：攻击的四个数必须分开报，因为它们回答的是不同问题：
        --   atk_ok   —— push 出去几次（**不等于命中**：动作是异步执行的）
        --   atk_land —— 逐拍采样到几次「血量下降」（真实落点）
        --   atk_dmg  —— 累计扣血总量（**最硬的事实**：打完一只 100 血的蜘蛛必须正好 100）
        --   atk_cd   —— 因冷却被吞掉的拍数（**不是**错误，别当失败读）
        --   只报一个 `atk_ok` 的话，「出手 30 次、掉血 0」看起来和「打得很好」没区别。
        atk_ok         = atk_ok_n,
        atk_land       = atk_land_n,
        atk_dmg        = atk_dmg_n,
        atk_cd         = atk_cd_n,
        last_atk_why   = last_atk_why,
        -- ★ 因「到达距离缺失」被 07 补过参数的次数（见 push_action 的说明）。
        --   放进 stats 是为了**不静默**：这类「替原版补一个参数」如果悄悄做，
        --   下一个人就不知道有这回事（所以它必须出现在 /healthz 上，也有判据守着）。
        arrive_patched = act_arrive_n,
        -- ★ 世界组件必须 5/5；缺了就是「大白天永远不变」这类静默失真
        world_ok       = WORLD_MOUNT.ok,
        world_missing  = WORLD_MOUNT.missing,
    }
end

--- 世界环境状态（供服务端 / 探针读）：昼夜 / 季节 / 温度 / 天数
--- ★ 这五个量**全部**来自 TheWorld.state，而 state 是 worldstate 组件对
---   clock/seasons/worldtemperature 那些 netvar 的实时镜像 —— 不是宿主硬编码。
---   所以「读到的值随时间变化」本身就是「世界组件真的在跑」的证据。
function M.world_state()
    local w = world_env()
    if w == nil then return nil end
    local W = rawget(_G, "TheWorld") or (G and G.TheWorld)
    w.cycles = W.state.cycles
    w.time   = Sim.TheSim.time
    return w
end

--- 世界组件的挂载情况（5/5 才算齐）
function M.world_components()
    return {
        mounted = WORLD_MOUNT.mounted,
        missing = WORLD_MOUNT.missing,
        ok      = WORLD_MOUNT.ok,
    }
end

-- ★★ 模型版本。**每次改变「客户端/服务端能看到的行为面」就 +1**（不一定是帧格式）：
--   /4 → /5 之间加的是 P20 真多人（you 握手 + 槽位）、P21 会话身份（宽限期重连）、
--   P22 交互（targets / act / unact 三条控制消息）、P23 触屏（纯客户端，服务端无变化）。
--   帧格式（二进制 v3）**没变**，所以协议版本不动 —— 但**行为面变了**，
--   于是这份「模型版本」必须动：否则发布记录里那一版和跑着的这一版对不上，
--   而人对不上时只会得出一个结论：「应该一样吧」。
--   ⚠️ 此前这个函数**没有任何调用者**（`grep version()` 只有定义那一行）——
--     声明在、消费不在，等于没有。现在它出现在 `/healthz` 与 `/status` 上（见 server.py 的 stats），
--     并由 `tests/test_rt.py` 的 B6 与**本文件里的字面量交叉核对**（防止有人只改一处）。
-- ★ 版本号规则：**引擎行为改了就要进位**，因为它会通过 `/healthz` 的 `stats.boot`
--   报给外面，判据 B6 会拿它跟这里的字面量逐字核对（改一处漏另一处当场红）。
--   /5 → /6 的原因：P41/T6 把 `act_targets` 从"全表线性扫"换成"4 单位一格 + 每 8 拍重建"
--   的空间索引（见 `M.act_targets` / `M.act_targets_linear` 与 `/debug/act` 的 impl 开关）。
--   ⚠️ 这次是**补正**：`deploy/发布检查单.md` 的 2026-10-18 那条发布记录早就写着
--   `rt_boot/6`，而这里的字面量一直是 `/5` —— 记录与代码对不上，谁对谁错没人核。
--   B6 只核「两处是否一致」，**核不出「两处一起停留在旧值」** ⇒ 这类偏差只能靠人。
--   /7 → /8 的原因（P45，2026-10-19）：
--     ① `M.fingerprint()` 的 **esum/esq 从「恒为常数」变成真有信息** —— 修的是
--        Lua 5.1 的 `%d` 是 C int（≥2^31 被压成 -2147483648），连带把 FNV 步进与 h² 也
--        改成逐位精确；指纹串格式随之变成 `esum=hi.lo`。**录像会因此不兼容老版本**
--        （旧录像的 hashes 与新实现算不出来同一个值），这是行为面变化，必须进位。
--     ② 录像格式 v2 → v3（新增 `joins`，回放按「上线时刻」重建玩家）。
--     ③ `rt/server.py` 拆成 7 个模块（M4）——**这一条本身不改行为**，但它改了
--        `tools/boot_version_guard.py` 的指纹输入面，而「把拆分当成免升版的理由」
--        正是 C8 那类事故的温床：宁可多进一版，也不要让「记录里的 /7」对应两份实现。
function M.version() return "rt_boot/11" end

if not M.player_ok then
    error("rt_boot: 玩家实体创建失败（SpawnPrefab('wilson') 失败）")
end

M.map = { w = WorldMap.WIDTH, h = WorldMap.HEIGHT }

--=============================================================================
-- 地形图层（P10）：**整张瓦片表一次性**给客户端，之后本地缓存
--=============================================================================
-- 为什么需要：在这之前客户端只画「网格 + 圆/精灵」—— 世界的地形是**看不见的**，
--   玩家只能靠网格判断自己在动。而引擎里地形是**真的**（host/20_map.lua 的瓦片，
--   判定逻辑来自原版 tilegroups.lua），把它送出去才算「实时画面渲染」。
--
-- 为什么一次性而不是每帧：地形**不变**（原版里只有世界生成/地形改造才动）。
--   128×128 = 16384 个瓦片 ≈ 40 KB，开局拉一次就够，每帧重发是纯浪费。
--   （这一点与「增量帧没做」的取舍一致：**先看数据变不变，再决定怎么发**。）
function M.terrain()
    local tiles, w, h = WorldMap.GetTiles()
    local out = {}
    for i = 1, w * h do out[i] = tiles[i] or 0 end
    -- 瓦片 id → 名字（供客户端上色与图例）。GROUND 里有别名指向同一个 id，
    -- **先到先得**，保证两边对同一个 id 总给出同一个名字。
    local names = {}
    for name, id in pairs(_G.GROUND or {}) do
        if type(id) == "number" and names[id] == nil then names[id] = name end
    end
    return {
        w     = w,
        h     = h,
        tile  = WorldMap.TILE,      -- 1 瓦片 = 4 世界单位
        tiles = out,                -- 扁平数组，索引 = cy * w + cx + 1
        names = names,
    }
end

--=============================================================================
-- 压力测试：可选生成 N 个原版生物（P7）
--=============================================================================
-- 为什么要它：现有世界里只有 6 个实体，**从没在规模下测过**。
--   帧大小、tick 耗时、带宽都是随实体数变的，不测就不知道拐点在哪。
--   生成的都是**原版** prefab（pigman / rabbit / beefalo …），走的是真实工厂 + 真实大脑，
--   所以这既是压力测试，也是一次保真度抽查。
local SPAWN_N = tonumber(os.getenv("RT_SPAWN") or "") or 0
-- ★ P22 起加了**植物**：它们有 workable（evergreen=CHOP、sapling/berrybush=DIG），
--   于是「交互」这条链路在**跨进程**的测试里也有真目标可打。
--   顺带也让压力世界更像真实世界（只有动物、没有可采集物，是不像的）。
local SPAWN_KINDS = { "pigman", "rabbit", "beefalo", "spider", "frog", "butterfly",
                      "bee", "crow", "tallbird", "penguin",
                      "evergreen", "sapling", "berrybush" }
function M.spawn_kinds() return SPAWN_KINDS end

--=============================================================================
-- 调试通道（P41）：`/debug/spawn` / `/debug/give`
--=============================================================================
-- ★ 为什么需要它：审计时发现「运行时没有一条能**主动改变世界**的调试通道」——
--   只能靠 `RT_SPAWN` 环境变量在启动时撒固定的 13 种生物，想验「某一个特定
--   prefab 能不能生成、生成后行为对不对」就必须重启进程换参数。
--   原版有 `c_spawn` / `c_give`（consolecommands.lua），宿主一条都没有。
--
-- ★ 安全性：这两个函数**只能**被 `/debug/*` 路由调到，而那些路由
--   默认 404（需要 `--allow-debug`）。函数本身不做权限判断 ——
--   权限在 HTTP 层（单点），不重复实现两遍。
--
-- ★ 纪律：它们**必须在模拟线程里跑**（服务端通过 `hub.cmds` 排队），
--   因为它们调 Core.SpawnPrefab / inventory，都直接碰 Lua。

local DEBUG_SPAWN_N = 0

--- 在 (x,z) 生成一个预制体；缺省撒在玩家旁边的黄金角螺线上。
--  返回 true, {prefab,guid,x,z} | false, 原因（原因会原样回给调用方）
function M.debug_spawn(prefab, x, z)
    if type(prefab) ~= "string" or prefab == "" then
        return false, "prefab 必须是非空字符串（收到 " .. type(prefab) .. "）"
    end

    local px, pz = 0, 0
    if M.player ~= nil then
        local okp, ax, az = pcall(pos_of, M.player)
        if okp and ax ~= nil then px, pz = ax, az end
    end

    -- 连续 spawn 时用黄金角螺旋错开，避免叠在一个点上（叠在一起会互相挤开，测不准）
    DEBUG_SPAWN_N = DEBUG_SPAWN_N + 1
    local ang = DEBUG_SPAWN_N * 2.3999632297286533
    local rad = 3 + 0.6 * (DEBUG_SPAWN_N % 5)
    local tx = tonumber(x) or (px + math.cos(ang) * rad)
    local tz = tonumber(z) or (pz + math.sin(ang) * rad)

    local ok, inst = pcall(Core.SpawnPrefab, prefab)
    if not ok then
        return false, "生成抛错：" .. tostring(inst)
    end
    if inst == nil then
        return false, "引擎里没有这个预制体（SpawnPrefab 返回 nil）"
    end
    if inst.Transform ~= nil then inst.Transform:SetPosition(tx, 0, tz) end
    -- ★ T6：世界刚多了个实体 ⇒ 交互目标索引立刻作废。
    --   不调也不会错（最多 8 拍后自然重建），但调试通道的意义就是「所见即所得」：
    --   刚 spawn 的东西必须马上能被 /act/targets 看到，否则测试自己会骗自己。
    M.act_index_invalidate()
    return true, {
        prefab = tostring(inst.prefab or prefab),
        guid   = inst._guid or -1,
        x      = tx,
        z      = tz,
    }
end

--- 合成 / 建造（B1，2026-10-22）—— 走原版 `Builder:DoBuild`，不自己实现扣料与落点。
---
--- ★ 为什么必须走原版：`DoBuild`（`components/builder.lua:752`）是原版**唯一**的建造入口，
---   它内部已经按顺序处理了：配方有效性 → 材料或缓冲建造 → 骑乘/宠物/原型站/皮肤校验 →
---   `recipe.canbuild` 模组钩子 → 扣材料 → 放置类配方算落点 → 产物进位背包或落地。
---   自己写一份"查材料、扣材料、生成产物"等于把配方规则复制第二遍 ——
---   而本工程的母题就是「同一件事两处实现 ⇒ 改一处、另一处悄悄过期」。
---
--- ★ 为什么不塞进 `action_for`/`act`：`act` 的语义是「对着**某个目标**做动作」，
---   需要走过去、需要 PENDING 逐拍重发、需要目标 guid。合成不依赖目标，也不需要靠近，
---   硬塞进去会让 ACT 那张三态返回表多一个语义完全不同的分支（P61 的教训：
---   只接一处分支就会有一处记账缺失）。
---
--- ★ 已知风险（写在这里，不藏）：`DoBuild` 会走到 `prod:OnBuilt()`、
---   `NotifyPlayerProgress`、`ProfileStatsAdd`、`Transform:SetPosition(v:Get())` 这些
---   宿主只做了桩的东西。所以整段用 pcall 包住，**失败要能说出是哪一句崩的**，
---   而不是让模拟线程静默停摆。
local craft_ok_n, craft_refused_n, last_craft_why = 0, 0, nil
function M.craft_stats() return craft_ok_n, craft_refused_n, last_craft_why end

--- 取一个 Vector3。宿主的 `Vector3` 在 `03_globals.lua` 里，不保证在 `_G` 上，
--- 所以先探再调；造不出来返回 nil（调用方要当作"没有位置"处理，不能当 0）。
local function mk_vec3(x, y, z)
    local V = rawget(_G, "Vector3")
    if type(V) ~= "function" then return nil end
    local ok, v = pcall(V, x, y, z)
    if ok then return v end
    return nil
end

--- 造一个配方。返回 (成功, 说明或拒绝原因, 详情表|nil)。
---   · 成功 → (true, "ok", {recipe=..., prefab=..., x=, z=, ents_before=, ents_after=})
---   · 失败 → (false, 原因, nil)  —— 原因必须能直接显示给玩家
---   ⚠️ **失败也必须补第三个 nil**：lupa 把多返回值变成 tuple，返回 2 个会让
---      Python 侧 `ok, info, detail = ...` 直接 ValueError —— 实测首跑就踩到，
---      而它冒出来的地方是「材料不足」这条**最常见的路径**上。
function M.craft(slot, recname, x, z)
    slot = tonumber(slot) or 0
    if type(recname) ~= "string" or recname == "" then
        craft_refused_n = craft_refused_n + 1
        last_craft_why = "配方名必须是非空字符串（收到 " .. type(recname) .. "）"
        return false, last_craft_why, nil
    end
    local p = slot_entity(slot)
    if p == nil then
        craft_refused_n = craft_refused_n + 1
        last_craft_why = "槽位 " .. tostring(slot) .. " 没有玩家"
        return false, last_craft_why, nil
    end
    local b = p.components and p.components.builder or nil
    if b == nil then
        craft_refused_n = craft_refused_n + 1
        last_craft_why = "玩家没有 builder 组件（配方系统没加载？）"
        return false, last_craft_why, nil
    end

    -- 落点：默认玩家脚边（沿朝向 1.2 格）—— 放置类配方（营火/墙）必须有合法点，
    -- 传 nil 会让原版走到「造在自己身上」的分支，那是**看起来成功但位置错**的形态。
    local px, pz = pos_of(p)
    if px == nil then
        craft_refused_n = craft_refused_n + 1
        last_craft_why = "取不到玩家位置"
        return false, last_craft_why, nil
    end
    local tx, tz = tonumber(x), tonumber(z)
    if tx == nil or tz == nil then
        local ang = 0
        local okr, rot = pcall(function() return p.Transform:GetRotation() end)
        if okr and type(rot) == "number" then ang = rot end
        tx = px + math.cos(math.rad(ang)) * 1.2
        tz = pz - math.sin(math.rad(ang)) * 1.2
    end
    local pt = mk_vec3(tx, 0, tz)
    if pt == nil then
        craft_refused_n = craft_refused_n + 1
        last_craft_why = "宿主没有可用的 Vector3，无法给出建造落点"
        return false, last_craft_why, nil
    end

    local ents_before = 0
    for _ in pairs(ent_table()) do ents_before = ents_before + 1 end

    local okC, r1, r2 = pcall(b.DoBuild, b, recname, pt, 0, nil)
    if not okC then
        craft_refused_n = craft_refused_n + 1
        last_craft_why = "DoBuild 抛错：" .. tostring(r1)
        return false, last_craft_why, nil
    end
    if not r1 then
        craft_refused_n = craft_refused_n + 1
        -- 原版把失败原因作为**对外契约**返回（"MOUNTED"/"HASPET"/"ITEMMIMIC"/nil）。
        -- ★ 原版对「配方不存在」和「材料不足」都返回 `false, nil` —— 这两件事对玩家
        --   的处理动作**完全不同**（一个改输入、一个去采集），所以不能都译成一句
        --   "失败了"。这里补一次**只读的解释**：判定仍然是 DoBuild 的，这里只解释它。
        --   ⚠️ 解释不能反过来影响判定 —— 一旦这里"自己决定成功与否"，就会出现
        --      两套判定规则（本项目母题），所以这段只在失败之后跑。
        if type(r2) == "string" and r2 ~= "" then
            last_craft_why = r2
        else
            local okR, recipe = pcall(GetValidRecipe, recname)
            if not okR then
                last_craft_why = "原版未给原因（GetValidRecipe 抛错：" .. tostring(recipe) .. "）"
            elseif recipe == nil then
                last_craft_why = "配方不存在：" .. recname
            else
                -- 需求清单直接读 `recipe.ingredients`（权威数据），不自己推算材料表
                local need = {}
                for _, v in ipairs(recipe.ingredients or {}) do
                    if (v.amount or 0) > 0 then
                        need[#need + 1] = tostring(v.type) .. "×" .. tostring(v.amount)
                    end
                end
                last_craft_why = "材料不足（该配方需要 " .. table.concat(need, "、") .. "）"
            end
        end
        return false, last_craft_why, nil
    end

    craft_ok_n = craft_ok_n + 1
    last_craft_why = nil
    M.act_index_invalidate()      -- 世界多了实体，交互索引立刻作废（与 debug_spawn 同一条纪律）
    local ents_after = 0
    for _ in pairs(ent_table()) do ents_after = ents_after + 1 end
    return true, "ok", {
        recipe = recname, x = tx, z = tz,
        ents_before = ents_before, ents_after = ents_after,
    }
end

--- 列出配方（B2）。返回 (全表数, 可造数, 有效数, 跳过数, 紧凑文本, 错误)。
---
--- ★ 关于"跳过数"：有一类配方 `ingredients` 是**空的**（`carnivalgame_*` 活动装饰、
---   建造模式专用件）。空材料的配方 `HasIngredients` 天然为真 ⇒ 面板上会出现
---   一屏"能造"的垃圾，而且它们跟生存玩法毫无关系。
---   实测（B2 第二跑）：只过 `GetValidRecipe` 时，空背包仍有 **30 条可造**，
---   全是 `carnivalgame_golf_shape_*` —— 因为宿主里 `IsSpecialEventActive` 把活动当开启。
---   所以再补一条**结构过滤**：一个 `amount > 0` 的材料都没有的配方不进列表。
---   这不是"我替原版决定规则"，而是"这个引擎只做生存玩法，不做活动装饰" ——
---   跳过的条数**单独返回**，让它可被观测，而不是悄悄消失。
---
--- 文本格式：每行 `name\tproduct\t材料\t可造`，材料形如 `log:2,cutgrass:3`。
---
--- ★ 为什么用**一个字符串**而不是 table：lupa 逐条迭代 Lua table 是几千次跨语言调用
---   （P41 的教训：`act_targets` 曾因为逐条转换把一次 250 ms 的轮询压到 12 ms 预算边缘）。
---   原版配方有 **1122 个**，逐个转 dict 会把一次请求变成秒级。
---
--- ★ 为什么先排"可造的"再排"不可造的"：`limit` 截断时，玩家最需要看到的是
---   **现在就能做的东西**。不这样的话，40 条限额会被一堆做不了的配方占满，
---   面板看起来"全是灰的"。
---
--- ★ `HasIngredients` 每个配方要查一次背包（内含若干次 `inventory:Has`），
---   1122 个配方 ≈ 2 万次槽位比较。**所以这个接口只允许"打开面板时拉一次"，
---   绝不能挂进每帧/每 250 ms 的帧循环**（实测耗时见下方注释，由 E16 锁住上限）。
function M.recipes(slot, limit)
    slot = tonumber(slot) or 0
    limit = math.floor(tonumber(limit) or 40)
    if limit < 1 then limit = 1 elseif limit > 200 then limit = 200 end

    local p = slot_entity(slot)
    if p == nil then return 0, 0, 0, 0, "", "槽位 " .. tostring(slot) .. " 没有玩家" end
    local all = rawget(_G, "AllRecipes")
    if type(all) ~= "table" then
        return 0, 0, 0, 0, "", "配方表 AllRecipes 不存在（recipes.lua 没加载？）"
    end
    local b = p.components and p.components.builder or nil

    local yes, no = {}, {}
    local total, craftable, valid_n, skipped = 0, 0, 0, 0
    for name, r in pairs(all) do
        total = total + 1
        -- ★★ 必须过 `GetValidRecipe` 这一关，不能直接信 `AllRecipes`。
        --   实测（B2 首跑）：不过滤时**空背包也有 30 条"可造"**，而且全是
        --   `carnivalgame_golf_shape_*` 这种活动装饰 —— 它们的 `ingredients` 是空的，
        --   于是 `HasIngredients` 天然为真。面板上会出现一屏"能造"的垃圾。
        --   `GetValidRecipe`（recipe.lua:1018）做的就是四重过滤：游戏模式 /
        --   不是拆除配方 / 特殊活动是否开启 / 查表存在。原版合成菜单走的是同一条路，
        --   所以这里跟着原版走，**不自己写过滤规则**。
        local okV, vr = pcall(GetValidRecipe, name)
        if okV and vr ~= nil then
            local n_ing = 0
            if type(r) == "table" and type(r.ingredients) == "table" then
                for _, v in ipairs(r.ingredients) do
                    if type(v) == "table" and (v.amount or 0) > 0 then n_ing = n_ing + 1 end
                end
            end
            if n_ing == 0 then
                skipped = skipped + 1        -- 空材料配方：活动装饰 / 建造模式专用，不进生存面板
            elseif type(r) == "table" and type(r.ingredients) == "table" then
                valid_n = valid_n + 1
                local can = false
                if b ~= nil then
                    local okH, h = pcall(b.HasIngredients, b, r)
                    can = (okH and h == true)
                end
                if can then craftable = craftable + 1 end
                local ing = {}
                for _, v in ipairs(r.ingredients) do
                    if type(v) == "table" and (v.amount or 0) > 0 then
                        ing[#ing + 1] = tostring(v.type) .. ":" .. tostring(v.amount)
                    end
                end
                local line = tostring(name) .. "\t" .. tostring(r.product or name) ..
                             "\t" .. table.concat(ing, ",") .. "\t" .. (can and "1" or "0")
                if can then yes[#yes + 1] = line else no[#no + 1] = line end
            end
        end
    end
    -- 排序：`pairs` 的顺序是不确定的，不排的话同一个背包两次请求的列表顺序会变，
    -- 客户端列表就会「自己跳」。这条和 act_targets 的 guid 兜底是同一个理由。
    table.sort(yes); table.sort(no)
    local out = {}
    for _, l in ipairs(yes) do if #out >= limit then break end; out[#out + 1] = l end
    for _, l in ipairs(no) do if #out >= limit then break end; out[#out + 1] = l end
    return total, craftable, valid_n, skipped, table.concat(out, "\n"), nil
end

--- 装备一件物品（B3）。走原版 `ACTIONS.EQUIP.fn` —— 它内部就是 `inventory:Equip(invobject)`。
---
--- ★ 为什么物品必须放在 **invobject** 而不是 target：
---   `actions.lua:2888` 的 `ACTIONS.EQUIP.fn` 读的是 `act.invobject`，**不是 target**。
---   构造 `BufferedAction(p, item, ACTIONS.EQUIP)` 会把物品塞进 target ⇒ fn 拿到
---   `invobject = nil` ⇒ `Equip(nil)` ⇒ **静默什么都不做**（返回 nil，不报错）。
---   这是「参数放错槽位」的典型形态：调用成功、没有异常、状态没变。
---
--- ★ 为什么直接调 `fn` 而不 PushAction：EQUIP 是 `instant = true`（actions.lua:1355），
---   原版对即时动作就是当场执行；走 PushAction 反而会去等一个「到达」条件，
---   而装备这件事没有目标位置可到达。
---
--- ★ 为什么结尾要**回读**：`inventory:Equip` 在「物品不在背包里」「已被别的槽占用」
---   等情况下会自己 bail out，返回值也不表达成功与否。不回读的话，
---   「装上了」就只是一个说法，而不是一个事实。
function M.equip(slot, guid)
    slot = tonumber(slot) or 0
    guid = tonumber(guid)
    local p = slot_entity(slot)
    if p == nil then return false, "槽位 " .. tostring(slot) .. " 没有玩家", nil end
    if guid == nil then return false, "没给物品 guid", nil end
    local item = ent_table()[guid]
    if item == nil then return false, "目标不存在（guid " .. tostring(guid) .. "）", nil end
    local inv = p.components and p.components.inventory or nil
    if inv == nil then return false, "玩家没有 inventory 组件", nil end

    -- ★★ 幂等：已经在那个槽里就直接算成功。
    --   为什么必须有：`Builder:DoBuild` 对「产物是可装备物品且槽位空」的情况
    --   **会自动装备**（builder.lua 的 `if prod.components.equippable ~= nil and
    --   not recipe.dropitem and GetEquippedItem(eslot) == nil then inventory:Equip(prod)`）。
    --   所以 `craft("axe")` 之后斧头**已经在手上、不在背包**。
    --   没有这条幂等，`equip` 会报「背包槽=nil」—— 而真实状态是"已经装好了"，
    --   把一个正确状态报成失败，比不做事更糟（调用方会去"修"一个没坏的东西）。
    local eqc = item.components and item.components.equippable or nil
    if eqc ~= nil and inv.GetEquippedItem ~= nil then
        local okS, cur = pcall(inv.GetEquippedItem, inv, eqc.equipslot)
        if okS and cur == item then
            return true, "已经是装备状态（幂等）", {
                guid = guid, prefab = tostring(item.prefab or ""),
                equipped = true, hands_prefab = tostring(item.prefab or ""),
            }
        end
    end

    local ACT = ACTIONS and ACTIONS.EQUIP
    if ACT == nil or ACT.fn == nil then return false, "引擎里没有 EQUIP 动作", nil end

    -- 前置条件回读：装备失败时**要能说出是哪一条不满足**。
    -- 否则只会得到「没生效」，而「没生效」有三个完全不同的原因：
    -- 物品不在背包 / 物品没有 equippable / equipslot 不是 hands。
    local idx = nil
    if inv.GetItemSlot ~= nil then
        local okS, v = pcall(inv.GetItemSlot, inv, item)
        if okS then idx = v end
    end
    local eq = item.components and item.components.equippable or nil
    local eqslot = nil
    if eq ~= nil then
        local okQ, q = pcall(function() return eq.equipslot end)
        if okQ then eqslot = q end
    end

    -- ★★ 直接调 `inventory:Equip(item)`，**不绕 `ACTIONS.EQUIP.fn`**。
    --   理由（B3 实测）：`ACTIONS.EQUIP.fn` 的函数体就是
    --       `return act.doer.components.inventory:Equip(act.invobject)`
    --   （actions.lua:2888-2892），一行。而 `BufferedAction(p, nil, ACT, item)` 构造出来的
    --   动作拿不到 `invobject`（实测 ba.invobject 为空），于是 fn 走到 `Equip(nil)` 直接 return，
    --   表现是「装备成功、手上还是空的」。绕这一层的唯一收益是走动作链，
    --   而装备是 `instant` 动作，没有到达判定、没有动画依赖 —— 绕过去只会多一个失效点。
    --   ⚠️ 这不是"自己实现规则"：规则仍然在 `Inventory:Equip` 里（准入检查、旧物品归还、
    --      replica 推送都在那儿）。我们只是省掉了一次注定传不进参数的转发。
    local okF, r = pcall(inv.Equip, inv, item)
    if not okF then return false, "Equip 抛错：" .. tostring(r), nil end

    -- 回读：手上真的是它吗？（不回读就等于自述结论）
    local hands = nil
    local okE, e = pcall(function() return inv:GetEquippedItem(EQUIPSLOTS.HANDS) end)
    if okE then hands = e end
    local okD, detail = true, {
        guid = guid,
        prefab = tostring(item.prefab or ""),
        equipped = (hands ~= nil and hands == item),
        hands_prefab = (hands ~= nil) and tostring(hands.prefab or "") or "",
    }
    if not okD then detail = nil end
    if hands ~= item then
        -- 把背包里到底有什么也打出来：只说"不在背包里"没法定位
        -- 是「产物没进背包」还是「进的是另一个实例」。
        local dump = {}
        local okN, n = pcall(inv.GetNumSlots, inv)
        if okN and type(n) == "number" then
            for i = 0, n - 1 do
                local okI, it = pcall(inv.GetItemInSlot, inv, i)
                if okI then dump[#dump + 1] = i .. ":" .. tostring(it and it.prefab) end
            end
        end
        return false, string.format(
            "装备没生效（背包槽=%s / equippable=%s / equipslot=%s / 手上=%s / 背包=[%s]）",
            tostring(idx), tostring(eq ~= nil), tostring(eqslot),
            tostring(detail.hands_prefab), table.concat(dump, ",")), detail
    end
    return true, "ok", detail
end

--- 给某个槽位的玩家发 n 个某物品（走真实 `inventory:GiveItem`）。
--  返回 true, {given, items_before, items_after} | false, 原因
function M.debug_give(slot, prefab, n)
    slot = tonumber(slot) or 0
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 elseif n > 20 then n = 20 end    -- 上限 20：别一次把背包塞爆
    if type(prefab) ~= "string" or prefab == "" then
        return false, "prefab 必须是非空字符串（收到 " .. type(prefab) .. "）"
    end

    local p = slot_entity(slot)
    if p == nil then return false, "槽位 " .. tostring(slot) .. " 没有玩家" end
    local inv = p.components and p.components.inventory or nil
    if inv == nil then return false, "槽位 " .. tostring(slot) .. " 的玩家没有 inventory 组件" end

    local before = (inv.NumItems ~= nil) and inv:NumItems() or nil
    local given = 0
    for _ = 1, n do
        local ok, inst = pcall(Core.SpawnPrefab, prefab)
        if not ok then return false, "生成抛错：" .. tostring(inst) end
        if inst == nil then
            return false, "引擎里没有这个预制体（SpawnPrefab 返回 nil）"
        end
        local okg, res = pcall(function() return inv:GiveItem(inst) end)
        if not okg or res == false then
            if inst.Remove ~= nil then pcall(function() inst:Remove() end) end
            return false, string.format("背包放不下（已放入 %d 个，GiveItem 拒绝第 %d 个）",
                                        given, given + 1)
        end
        given = given + 1
    end
    local after = (inv.NumItems ~= nil) and inv:NumItems() or nil
    return true, { given = given, items_before = before, items_after = after }
end

--- 按 guid 查一个实体（`/debug/entity`）。**这是判据能落地的关键**：
--  `spawn` 回一个 guid 只能说明「工厂返回了东西」，
--   而「它真的在世界表里、位置就是我给的那个」必须**再查一次**才能证明。
--  （实体数 n_ents 不可靠：世界本身会因为鸟/生成器/复活在变，±1 判不出来。）
function M.debug_entity(guid)
    guid = tonumber(guid)
    if guid == nil then return false, "guid 必须是数字" end
    local inst = ent_table()[guid]
    if inst == nil then
        return false, "guid " .. tostring(guid) .. " 不在世界表里"
    end
    if inst.IsValid ~= nil and not inst:IsValid() then
        return false, "guid " .. tostring(guid) .. " 已失效"
    end
    local x, z = pos_of(inst)
    -- ★ P61：加上血量与当前可做的动作。
    --   为什么必须加：战斗闭环上线后，「这个生物还剩多少血」是判断
    --   「攻击到底有没有生效」的唯一事实来源（DoAttack 没有返回值）。
    --   以前这个通道只回位置，运维时只能看到「它在动」，看不到「它快死了」。
    --   ⚠️ hp 拿不到时回 nil，**不回 0** —— 缺字段 ≠ 血空了。
    local hc = inst.components and inst.components.health or nil
    local dead = nil
    if hc ~= nil then
        local okD, v = pcall(hc.IsDead, hc)
        if okD then dead = v end
    end
    -- ★★ B3（2026-10-22）：workleft / 手持物品 / 工具效率，三样一起加。
    --   为什么非加不可：「拿斧头砍树更快」这件事**唯一的可观测证据**就是 workleft 的
    --   下降步长。在此之前探针只能看到「树倒了 / 没倒」，看不到「敲一下扣了几点」——
    --   而「敲 3 下倒」与「敲 6 下倒」在只看结果时**完全一样**，都是"倒了"。
    --   这正是本项目最怕的假绿灯形态：结论对，但判据测不到差别。
    local wc = inst.components and inst.components.workable or nil
    local workleft, maxwork, wtough, waction = nil, nil, nil, nil
    if wc ~= nil then
        local okW, w = pcall(function() return wc.workleft end)
        if okW then workleft = w end
        local okM, m = pcall(function() return wc.maxwork end)
        if okM then maxwork = m end
        local okT, t = pcall(function() return wc.tough end)
        if okT then wtough = t end
        local okQ, q = pcall(function() return wc.action and wc.action.id end)
        if okQ then waction = q end
    end
    local hands = nil
    local pcomp = M.player and M.player.components or nil
    local pinv = pcomp and pcomp.inventory or nil
    if pinv ~= nil and pinv.GetEquippedItem ~= nil then
        local okH, h = pcall(function() return pinv:GetEquippedItem(EQUIPSLOTS.HANDS) end)
        if okH and h ~= nil then hands = tostring(h.prefab or "") end
    end
    return true, {
        guid = guid,
        prefab = tostring(inst.prefab or "?"),
        x = x or 0,
        z = z or 0,
        hp = hp_of(inst),
        maxhp = (hc ~= nil) and hc.maxhealth or nil,
        dead = dead,
        action = action_for(inst),
        workleft = workleft,
        maxwork = maxwork,
        wtough = wtough,
        waction = (waction ~= nil) and tostring(waction) or nil,
        hands = hands,
    }
end

-- ★★ P62：编辑器通道（`/editor/*`）—— 让世界**可被看、被选、被改**。
--   为什么另开一组而不是复用 `/debug/*`：
--     `/debug/*` 是**运维**通道，默认关、要 `--allow-debug`，发布检查单里明写「公网别开」；
--     编辑器是**本机开发工具**，诉求是「打开就能用」。两个诉求冲突，不能共用一个开关。
--   所以判据换成**看来源地址**：`/editor/*` 只在请求来自回环（127.0.0.1 / ::1）时可用。
--     这比 `--allow-debug` 更硬 —— 即使有人绑了 0.0.0.0，外网也调不动编辑器；
--     而本机开发者不用改任何启动参数。
--
--   ★ 返回格式沿用 `debug_act` 的先例：**压成字符串**，不返回 Lua 表。
--     理由：lupa 里 Lua table → Python 要逐条迭代取字段，1000 个实体就是几千次
--     跨语言调用；这里一次取回一大串，解析放在 Python 侧。
--     字段用 \t 分隔、行用 \n 分隔 —— prefab 名是 ASCII 标识符，不会含这两种字符。

--- 列出世界里的全部实体。`limit` 是**返回条数上限**（默认 500 / 最多 5000），
--- `count` 是真实总数 —— 两者必须分开报，否则「只看到 500 个」会被误读成「世界只有 500 个」。
function M.debug_entities(limit)
    limit = math.floor(tonumber(limit) or 500)
    if limit < 1 then limit = 1 elseif limit > 5000 then limit = 5000 end
    local rows, total = {}, 0
    for guid, inst in pairs(ent_table()) do
        if inst ~= nil and (inst.IsValid == nil or inst:IsValid()) then
            total = total + 1
            local x, z = pos_of(inst)
            local hp = hp_of(inst)
            rows[#rows + 1] = string.format("%d\t%s\t%s\t%s\t%s",
                guid, tostring(inst.prefab or "?"),
                (x ~= nil) and string.format("%.2f", x) or "",
                (z ~= nil) and string.format("%.2f", z) or "",
                (hp ~= nil) and string.format("%.2f", hp) or "")
        end
    end
    -- ★ 按 guid 升序：pairs 的顺序是哈希序，每次调用都可能不同。
    --   不排序的话，编辑器列表会**自己跳来跳去**，点一下选中就跑了。
    table.sort(rows, function(a, b)
        return (tonumber(a:match("^%d+")) or 0) < (tonumber(b:match("^%d+")) or 0)
    end)
    local out = {}
    for i = 1, math.min(#rows, limit) do out[i] = rows[i] end
    return true, { count = total, listed = #out, rows = table.concat(out, "\n") }
end

--- 删掉一个实体。**玩家实体拒绝删除** —— 删了会破坏会话身份（key→角色 指向空壳）。
function M.debug_remove(guid)
    guid = tonumber(guid)
    if guid == nil then return false, "guid 必须是数字" end
    local inst = ent_table()[guid]
    if inst == nil then return false, "guid " .. tostring(guid) .. " 不在世界表里" end
    if inst.IsValid ~= nil and not inst:IsValid() then
        return false, "guid " .. tostring(guid) .. " 已失效"
    end
    if inst.HasTag ~= nil and inst:HasTag("player") then
        return false, "拒绝删除玩家实体：会破坏会话身份（key→角色）"
    end
    if inst.Remove == nil then return false, "实体没有 Remove 方法" end
    local prefab = tostring(inst.prefab or "?")
    local ok, err = pcall(function() inst:Remove() end)
    if not ok then return false, "Remove 抛错：" .. tostring(err) end
    return true, { guid = guid, prefab = prefab, removed = true }
end

--- 把一个实体挪到 (x, z)。保留原 y —— 只关心水平坐标，生物本来就站在地上。
function M.debug_move(guid, x, z)
    guid, x, z = tonumber(guid), tonumber(x), tonumber(z)
    if guid == nil then return false, "guid 必须是数字" end
    if x == nil or z == nil then return false, "需要 x 和 z（都必须是数字）" end
    local inst = ent_table()[guid]
    if inst == nil then return false, "guid " .. tostring(guid) .. " 不在世界表里" end
    if inst.Transform == nil or inst.Transform.SetPosition == nil then
        return false, "实体没有 Transform:SetPosition"
    end
    local y = 0
    if inst.Transform.GetWorldPosition ~= nil then
        local okp, _, py = pcall(inst.Transform.GetWorldPosition, inst.Transform)
        if okp and py ~= nil then y = py end
    end
    local ok, err = pcall(function() inst.Transform:SetPosition(x, y, z) end)
    if not ok then return false, "SetPosition 抛错：" .. tostring(err) end
    -- ★ 回读：SetPosition 不返回值，**挪没挪动只能看位置**。
    local nx, nz = pos_of(inst)
    return true, { guid = guid, x = nx or x, z = nz or z }
end

function M.debug_spawn_count() return DEBUG_SPAWN_N end

--- ★ T6 验收入口：把「索引版 vs 线性版」的比对与计时搬到可被 HTTP 驱动的地方。
--
--  为什么不在 07 里另起一套 Lua 单测跑：07 的验证栈是「服务端 + WebSocket」，
--  实体是**运行时**生出来的（默认世界 6 个 + `RT_SPAWN` 撒的一批）。脱离这个
--  环境单独造 645 个实体来测，测的是另一个世界 —— 那正是本工程最反感的
--  「我量的不是我以为我量的东西」。⇒ 就地挂在调试通道上，用**真实世界**比对。
--
--  @param impl  "index"（默认）| "linear"
--  @param n     重复次数（测耗时用；结果取最后一次）
--  返回 true, { impl, n, ms, count, ids }
--    · `ids` 用**逗号分隔字符串**而不是嵌套表：Lua 表过 lupa 边界会变成
--      `_LuaTable`，`json.dumps` 不认（P39 踩过）。字符串是最省事的确定性表示。
function M.debug_act(slot, radius, impl, n)
    slot = tonumber(slot) or 0
    radius = tonumber(radius) or ACT_REACH
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 elseif n > 200 then n = 200 end
    impl = tostring(impl or "index")
    local fn = (impl == "linear") and M.act_targets_linear or M.act_targets

    local res
    -- ★ 先跑一次「预热」：第一次调用要建索引（O(实体数)），
    --   把它算进平均耗时会**虚高**，测出来的不是「稳态成本」。
    local ok0, err0 = pcall(fn, slot, radius)
    if not ok0 then return false, "act_targets 抛错：" .. tostring(err0) end

    local t0 = os.clock()
    for _ = 1, n do
        local okr, r = pcall(fn, slot, radius)
        if not okr then return false, "act_targets 抛错：" .. tostring(r) end
        res = r
    end
    local ms = (os.clock() - t0) * 1000 / n

    local ids = {}
    for i = 1, #res do ids[i] = tostring(res[i].id) end
    return true, {
        impl = impl,
        n = n,
        ms = ms,
        count = #res,
        ids = table.concat(ids, ","),
        builds = act_builds,
        lookups = act_lookups,
        scanned = act_scan_ents,
    }
end

function M.spawn_extra(n)
    n = tonumber(n) or 0
    local made, failed = 0, {}
    for i = 1, n do
        local k = SPAWN_KINDS[(i - 1) % #SPAWN_KINDS + 1]
        -- 撒在一个圆环上，避免全挤在原点（那会因碰撞互相挡住，测出来不准）
        local ang = (i / n) * math.pi * 2
        local rad = 6 + (i % 17)
        local px, pz = math.cos(ang) * rad, math.sin(ang) * rad
        local ok, inst = pcall(Core.SpawnPrefab, k)
        if ok and inst ~= nil then
            if inst.Transform then inst.Transform:SetPosition(px, 0, pz) end
            made = made + 1
        else
            failed[#failed + 1] = k
        end
    end
    M.spawned_total = made
    return made, failed
end

if SPAWN_N > 0 then
    local made, failed = M.spawn_extra(SPAWN_N)
    print(string.format("[rt_boot] 压力生成：成功 %d 个（失败 %d：%s）",
        made, #failed, #failed > 0 and table.concat(failed, ",") or "无"))
end

--=============================================================================
-- 默认世界内容（2026-10-16 加）
--=============================================================================
-- ★★★ 为什么需要它：**发布演练**（`tests/test_deploy.py`）量出一个真相 ——
--   默认世界**只有玩家一个实体**（`act_targets(0, 200)` 也是空的）：
--   用户打开链接、能走能跳，但**周围什么都没有**，砍不了、捡不了。
--   「服务端没问题」≠「用户那条路能玩」—— 这正是演练要抓的那类差距。
--   ⇒ 默认在玩家周围放一小片可交互的东西（树/树苗/浆果丛），全部落在
--     `ACT_REACH`(20) 之内，一进游戏就能砍；`RT_WORLD_CONTENT=0` 可关（测试要空世界时用）。
--   ⚠️ 这是**07 侧的默认世界配置**，不是原版世界生成：宿主只有 128×128 的瓦片地形，
--     没有森林/草原这套生物群系规则。摆放用黄金角螺旋（散得开又不互相卡住）。
local WORLD_CONTENT = tonumber(os.getenv("RT_WORLD_CONTENT") or "") or 14
if WORLD_CONTENT < 0 then WORLD_CONTENT = 0 end
-- 种类：树为主（能砍倒 + 掉木头，判据 E2 守着的就是它），另有树苗/浆果丛（能 DIG/PICKUP）
local WORLD_KINDS = { "evergreen", "sapling", "evergreen", "berrybush",
                      "evergreen", "sapling", "evergreen" }

--- 在**玩家周围**撒一片可交互的世界内容。返回 (成功数, 失败表)
--- ★ 与 `spawn_extra` 的区别：那个是**压测用**（固定撒在原点周围 6~23 格、含猪人蜘蛛），
---   这个是**给玩家玩的内容**（围绕玩家、全是可交互的植物、都在 20 格内）。
function M.populate_world(n)
    n = tonumber(n) or 0
    local p = M.player
    if p == nil or not M.player_ok then return 0, { "没有玩家，无法围绕它摆放" } end
    local px, pz = pos_of(p)
    if px == nil then return 0, { "取不到玩家位置" } end
    local made, failed = 0, {}
    for i = 1, n do
        local k = WORLD_KINDS[(i - 1) % #WORLD_KINDS + 1]
        -- 黄金角螺旋：第 i 个点的半径 ~ 3.5 + 1.7*sqrt(i) ⇒
        --   n=14 时第一个约 5 格（**一进游戏走两步就能砍**）、最远 ≈ 9.9 格（一定在 ACT_REACH=20 之内）
        local ang = i * 2.3999632297286533
        local rad = 3.5 + 1.7 * math.sqrt(i)
        local ok, inst = pcall(Core.SpawnPrefab, k)
        if ok and inst ~= nil then
            if inst.Transform then
                inst.Transform:SetPosition(px + math.cos(ang) * rad, 0, pz + math.sin(ang) * rad)
            end
            made = made + 1
        else
            failed[#failed + 1] = k
        end
    end
    M.world_content = made
    return made, failed
end

if WORLD_CONTENT > 0 then
    local made, failed = M.populate_world(WORLD_CONTENT)
    print(string.format("[rt_boot] 世界内容：%d 个（失败 %d：%s）—— 都在 20 格内，进游戏就能砍/挖/捡",
        made, #failed, #failed > 0 and table.concat(failed, ",") or "无"))
end

-- ★ 调试导出（诊断用，也让测试能查注册表）：把宿主 Core 表暴露出来。
M._core = Core
M._sim = Sim

--=============================================================================
-- 存档 / 读档（P3 / M5）
--=============================================================================
local SaveMod = rawget(_G, "__rt_mod_rt_save")
if SaveMod == nil and G then SaveMod = G.__rt_mod_rt_save end
if SaveMod == nil then error("rt_boot: 拿不到 rt_save 模块") end

local meta = { seed = SEED, tick = 0,
               player_guid = (M.player_ok and M.player) and M.player._guid or 0 }

function M.save_collect()
    meta.tick = steps_done
    meta.player_guid = (M.player_ok and M.player) and M.player._guid or 0
    -- ★★ P36：把「谁是谁」也存进去（以前只存了槽位 0 那个）
    meta.players = M.player_slots_bound()      -- 键是字符串（见 player_slots_bound 的说明）
    local keys_out = {}
    for k, v in pairs(SLOT_KEYS) do keys_out[tostring(k)] = v end
    meta.keys = keys_out
    return SaveMod.collect(Core, Sim, meta)
end
function M.save_validate(t) return SaveMod.validate(t) end
function M.save_apply(t)
    local ok, msg = SaveMod.apply(Core, Sim, meta, t)
    -- ★★★ P50⑭：apply **失败就必须立刻返回**（2026-10-20 实测缺这一句的后果）。
    --   缺了它的表现：存档内容是一个**标量**（`42` / `null`，都是**合法 JSON**）时，
    --   `SaveMod.validate` 已经正确地拒了（「存档不是表（类型 number）」），
    --   但控制流照样往下走到 `pairs(t.players or {})` ⇒
    --     `attempt to index local 't' (a number value)` ⇒ **LuaError 冒出 Python**。
    --   后果两连：① `server.py` 的启动读档没有 try ⇒ 服务端起不来；
    --            ② `try_load` 的 except 只包住 `json.load` ⇒ 坏档**连隔离都做不到**，
    --              留在原地等着被下一次自动存档覆盖（就是 P50⑬ 刚堵掉的那个洞）。
    --   ⚠ 为什么只崩 2 种：字符串 `"abc"` 在 Lua 里索引是**合法**的（返回 nil），
    --     所以 11 种语义坏档里偏偏只有 number / nil 这两种炸 ——
    --     「大部分坏档都没事」正是这类缺口能活下来的原因。
    if not ok then return ok, msg end
    -- ★ T6：读档把世界**整个换了一遍**（实体全新 guid）⇒ 索引必须作废。
    --   忘了这一句的后果很隐蔽：读档后交互目标列表会指着**上一局**的 guid，
    --   客户端点了没反应，而服务端一切正常 —— 又一个「静默失效」。
    M.act_index_invalidate()
    -- ★★ 必须把结果**同步回 M**：step() 里读的是 M.player，
    --   而 Save.apply 写的是 meta.player —— 两张表！
    --   不同步的后果：读档后 M.player 仍指向**已被清掉的旧实体**，
    --   位置不动、输入也没反应，而新实体其实一切正常。
    M.player    = meta.player
    M.player_ok = meta.player_ok
    -- ★★★ P36：把「槽位 → 角色」重新绑回来。
    --   读档时实体是**新 guid**，所以要用 `apply` 交出来的「旧 guid → 新实体」来翻译：
    --     t.players[槽位] = 旧 guid  ⇒  restored[旧 guid] = 新实体
    --   以前这里**不管三七二十一全删**（见下面那段注释），于是客户端重连只能拿到新角色。
    local restored = meta.restored or {}
    local claimed = {}
    for k in pairs(PLAYERS) do PLAYERS[k] = nil end
    for slot_s, old_guid in pairs(t.players or {}) do
        local slot = tonumber(slot_s)
        local inst = (old_guid ~= nil) and restored[old_guid] or nil
        if slot ~= nil and inst ~= nil and inst:IsValid() then
            if slot == 0 then
                M.player, M.player_ok = inst, true     -- 槽位 0 就是「默认玩家」
            else
                PLAYERS[slot] = inst
                INPUT_SLOTS[slot] = {}
            end
            claimed[inst] = true
        end
    end
    -- 会话 key 一起恢复（服务端启动时会读它）
    SLOT_KEYS = {}
    for slot_s, k2 in pairs(t.keys or {}) do
        local slot = tonumber(slot_s)
        if slot ~= nil and k2 ~= nil then SLOT_KEYS[slot] = tostring(k2) end
    end
    -- ★★ P20：多人之后，存档里可能躺着**好几个** wilson（上次运行时 4 个客户端各一个）。
    --   而「哪个客户端对应哪个角色」**没有持久化** —— 客户端重连会拿到**新**槽位、
    --   生成**新**角色。于是旧的那些没人驱动，只会站在世界里，
    --   而且每重连一次就多一个（泄漏）。
    --   ⇒ 读档后**认领回来的**（谁的 key 存在存档里）全部保留并重新绑定；
    --     真正没人认领的才删掉并**打印**出来。
    --   ★ 这一条在 2026-10-16 从「取舍」升级成了「已做」：见上面 `t.players` 那段。
    local extra = {}
    for _, inst in pairs(ent_table()) do
        if inst.prefab == "wilson" and inst ~= M.player and not claimed[inst] then
            extra[#extra + 1] = inst
        end
    end
    for i = 1, #extra do
        if extra[i].Remove ~= nil then pcall(extra[i].Remove, extra[i]) end
    end
    if #extra > 0 then
        -- ★★ 这里原来写的是 `print("… %d …" % #extra)` —— **Lua 里 `%` 是取模，不是字符串格式化**，
        --   运行到这一支会直接抛 "attempt to perform arithmetic on a string value"。
        --   ⚠️ 它一直没被触发：**以前根本没有「读档后出现多余角色」的场景**
        --     （读档后不管三七二十一全删，而且只有单人的存档才会走到这里）。
        --   是 D4（会话身份挺过重启）第一次让这一支真的跑起来，才把它炸出来。
        print(string.format("[load] ⚠ 清掉 %d 个「没有客户端认领」的角色（它们的 key 不在存档里）",
              #extra))
    end
    return ok, msg
end

return M
