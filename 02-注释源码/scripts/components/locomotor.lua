--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/locomotor.lua
-- 模块：组件系统 / 移动（Locomotor）
-- 职责：全游戏每个可移动实体的移动控制器。承担目的地抽象（Dest）、
--       移动指令下达（GoToEntity / GoToPoint / WalkInDirection）、
--       速度倍率合成（装备/鞍/地面/临时修正）、寻路结果跟随、
--       路径跟随的转向决策、平台跳跃（hopping）扫描与预约、
--       斜向测距转向（strafing）、移动计时器、客户端预测，
--       以及与寻路器（TheWorld.Pathfinder，C++ 侧）的协作等职责。
--       它只负责「怎么走过去」，不负责「该往哪走」——
--       寻路求解与决策由 brain / stategraph / pathfinder 负责。
-- 关键符号：LocoMotor, Dest, WalkForward, RunForward, WalkInDirection,
--           GoToEntity, GoToPoint, PushAction, PreviewAction, Stop,
--           OnUpdate, FindPath, GetRunSpeed, GetWalkSpeed, GetSpeedMultiplier,
--           ScanForPlatform, StartHopping, SetExternalSpeedMultiplier,
--           UpdateGroundSpeedMultiplier, SetAllowPlatformHopping,
--           OverrideMoveTimer, PopOverrideTimeMoving, FinishHopping
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：util/sourcemodifierlist.lua（预测倍率容器）,
--           components/walkableplatform.lua（可站平台与容量）,
--           components/walkableplatformmanager.lua（平台注册表）,
--           components/drownable.lua（落水判定）,
--           components/amphibiouscreature.lua（两栖过渡）、
--           components/embarker.lua（玩家登船）、
--           components/health.lua（死亡中断移动）、
--           components/playercontroller.lua（客户端预测与远端输入）、
--           class.lua（属性 setter 机制）、physics.lua（碰撞回调）
--           TheWorld.Pathfinder 是 C++ 侧寻路器，无 Lua 源码
--============================================================
--
--【阅读导航】
--  §零   被注释掉的历史常量（3-16）      —— 寻路策略的演进史
--  §一   Dest 目的地抽象（18-65）        —— 三种目标统一成一个对象
--  §二   双端函数分派（67-264）          —— ★ server/client 各一套同构实现
--  §三   类构造与 setter（266-349）       —— 把分派决策收敛到一处
--  §四   更新生命周期（351-401）         —— 休眠协作（isupdating 标记）
--  §五   移动计时器（403-476）           —— 0.3 秒迟滞 + 客户端预测上报
--  §六   外部速度倍率（478-565）         —— 带来源的倍率表与预测容器
--  §七   地面速度（567-636）             —— ★ 每帧热路径，靠 lastpos 缓存节流
--  §八   临时地面修正（638-679）         —— TTL=0.034 秒的瞬时效果
--  §九   斜向移动（681-739）             —— 朝向与移动方向解耦
--  §十   动作路由（741-980）             —— ★ PreviewAction 与 PushAction 平行实现
--  §十一 GoToEntity / GoToPoint（982-1076）—— arrive_dist 三分支 + 立即到达检查
--  §十二 停止与清理（1078-1160）        —— locomote 事件握手契约
--  §十三 跳跃扫描原语（1162-1343）      —— 边缘检测、平台准入、延迟计时
--  §十四 扫描参数与预约（1345-1414）    —— 步长钳制与平台预约
--  §十五 ★★ OnUpdate（1416-1758）        —— locomotor 的心脏，七段结构
--  §十六 寻路能力 pathcaps（1760-1791） —— 四个查询函数的默认值不一致
--  §十七 FindPath（1793-1863）          —— ★ 只执行不决策，与 C++ 寻路器协作
--
--【本文件最重要的八条】
--  1. 双端分派（272-293）：所有 server/client 差异收敛到 8 个方法指针，
--     公共代码完全端无关。代价：这些方法不能被子类统一 override。
--  2. 速度倍率只在合成点计算（204 行），每帧只有 3-4 次 GetSpeedMultiplier。
--  3. 地面速度靠 lastpos 地块缓存（1438 行）节流，频率降低约 60 倍。
--  4. should_locomote（1638 行）用 `not a ~= not b` 表达状态异或，只在需要时派发事件。
--  5. 到达判定只比 x/z 不比 y（1469 行）—— 否则跨平台移动永远判不到达。
--  6. 接近减速（1747 行）用 sqrt 而非距离平方，下限 1/3 保证不会卡死。
--  7. 跳跃期间 locomotor 完全让权（1425 行），位置由 C++ 物理与状态图负责。
--  8. FindPath 只做两件事：视线通畅就直走，否则提交 A*（1836-1849 行）。
--
--【★ 移植时最需要重写的三处】
--  · DoDelta 同级的 1602-1608「后退转身」是纯经验 hack，斜向与击退场景不准确；
--  · 178-236 行的速度合成逻辑两端必须逐字符一致，否则端间跳变；
--  · 782 与 882 行的 PreviewAction / PushAction 是两份平行实现，
--    加新动作类型时必须同改，否则联机表现与本地不一致。
--★ 本文件唯一的 require：SourceModifierList（util/sourcemodifierlist.lua:8）。
--   它只用在 548-565 行的「客户端预测用外部倍率」上——
--   也就是说这个容器**只存在于客户端**，服务端不创建。
local SourceModifierList = require("util/sourcemodifierlist")

--⚠【被注释掉的 DOZE_OFF_TIME】原意是「连续移动多久后允许休眠（doze）」。
--   现在改由实体自身的 dormancy 机制控制（见 update.lua 的休眠判定），
--   locomotor 不再参与。保留注释是历史记录。
--local DOZE_OFF_TIME = 2

--⚠【被注释掉的 PATHFIND_PERIOD / PATHFIND_MAX_RANGE】
--   ★ 这两条揭示了寻路策略的演进史：
--     · PATHFIND_MAX_RANGE —— 曾限制「只对 40 格内的目标寻路」，
--       现在无限制（1815 行的对应检查也被注释掉了）。
--       放开的原因是玩家会要求「走到地图另一边」，硬限制会导致走不到。
--     · PATHFIND_PERIOD —— 曾用于「每 1 秒才重新寻路一次」以省 CPU，
--       现在改为「每帧都可能重新提交搜索」+「同目标地块去重」（1832 行 lastdesttile）。
--       用空间去重代替时间节流，既不浪费 CPU 也不牺牲正确性。
--   ★★ 这个演进是本文件性能设计的关键：见 1824 行的 lastdesttile 去重。
--local PATHFIND_PERIOD = 1
--local PATHFIND_MAX_RANGE = 40

--★★★【寻路状态机的三个状态】0=计算中、1=找到路径、2=没找到。
--   ★ 关键设计：STATUS_NOPATH(2) 被注释掉了，
--     而 1552 行对 `pathstatus == nil` 做了单独处理（视为「搜索句柄丢失」）。
--   ★★ 也就是说本文件只区分「还在算」与「算完了」两种状态；
--     「算完了但没路」与「算丢了」都走 1551 的 else 分支，只打调试日志。
--     这是刻意的降级：无路可走时最合理的做法是「直冲过去让物理挡住」，
--     而不是停下。参见 1838 行 IsClear 为真时的 ResetPath。
local STATUS_CALCULATING = 0
local STATUS_FOUNDPATH = 1
--local STATUS_NOPATH = 2

--★★ ARRIVE_STEP = 0.15 —— 「到达」判定的基准半径（0.15 格）。
--   数值极小，说明到达判定主要靠各处的 arrive_dist（通常 2~4 格），
--   ARRIVE_STEP 只是「两实体半径之和都拿不到」时的兜底值。
--★ 参见 constants.lua:769 GROUND_ROADWAYS ——
--   由 tilemanager.lua:175 填充（道路类地块的静态集合）。
--   参见 main.lua:453 `RoadManager = TheGlobalInstance.entity:AddRoadManager()` ——
--   RoadManager 是 C++ 侧对象，可能为 nil（非道路世界）。
local ARRIVE_STEP = .15

--★ MOVE_TIMER_STOP_THRESHOLD = 0.3 秒 —— 「移动计时器」的迟滞阈值。
--   短于 0.3 秒的停顿**不重置**移动计时器，理由见 403-412 行。
local MOVE_TIMER_STOP_THRESHOLD = 0.3 --seconds

--★★ INVALID_PLATFORM_ID = "INVALID PLATFORM" —— 一个刻意不可能与实体相等的哨兵值。
--   ★ 用途：last_platform_visited 的初始值。因为 Lua 表可以用任意值作 key，
--     用字符串哨兵比用 nil 更安全（nil 无法作为「已访问过」的有效区分）。
--   ★ 为什么不用实体？因为哨兵必须保证「不等于任何平台实体」，
--     字符串常量天然满足。参见 1084 与 1203 行的初始化。
local INVALID_PLATFORM_ID = "INVALID PLATFORM"

--★★★【Dest 类：把「三种目的地」统一成一个对象】
--   支持三种目标：
--     ① 实体（inst）      —— 「走到这个东西旁边」
--     ② 点（pt）          —— 「走到这个坐标」
--     ③ 缓冲动作（buffered_action）—— 「走到这个动作的执行点」
--   ★★ 设计动机：让 locomotor 的所有后续代码（OnUpdate、GetPlatform、
--     到达判定）只需处理一种类型，不必到处写「如果是实体就取位置，
--     否则如果是点就……」。这是最典型的「多态消除分支」手法。
--   ⚠ 注意它是全局变量（没有 local），这是刻意的——
--     因为模组与 stategraph 需要构造 Dest（search prefabs 见 `Dest(` 的外部用法）。
--   ⚠ 但全局命名有污染风险，DST 里 Dest 是保留名。
Dest = Class(function(self, inst, pt, buffered_action)
    self.inst = inst
--★ pt 为 nil 时不赋值 —— 保持 nil 语义，便于 GetPoint 的 else if 链。
    if pt ~= nil then
        self.pt = pt
    end
--★ 三选一构造：不同调用方（GoToEntity / GoToPoint）填不同的组合。
    self.buffered_action = buffered_action
end)

--★★【IsValid：实体会被销毁，所以每帧都要重验】
--   `self.inst == nil or self.inst:IsValid()` ——
--   注意是「inst 为 nil 也算有效」（那意味着目标是个坐标点，永远有效）。
--   ★ 这是「跟踪移动目标」的根本需求：目标被吃掉/摧毁后必须停止跟随。
--   ★ OnUpdate:1452 每帧调它；GoToEntity 走的 path 会指向一个已消失的实体。
function Dest:IsValid()
    return self.inst == nil or self.inst:IsValid()
end

--★ __tostring 只服务调试输出（GetDebugString:1159 打印它）。
--   ★ 优先级顺序：实体 > 点 > 动作点 > 无，恰好是构造的常见度顺序。
function Dest:__tostring()
    return (self.inst ~= nil and ("Going to Entity: "..tostring(self.inst)))
        or (self.pt ~= nil and ("Going to Point: "..tostring(self.pt)))
        or (self.buffered_action ~= nil and ("Going to buffered action point: "..tostring(self.buffered_action.pos)))
        or "No Dest"
end

--★★★【GetPoint：目的地的世界坐标】
--   四条路径：有效实体 → 点的当前值 → 动作点 → 兜底 (0,0,0)。
--   ⚠⚠ 兜底 (0,0,0) 是危险默认值：若三个字段都为 nil，
--     实体会朝**世界原点**走去。应视为「构造错误」而非正常分支。
--     强类型移植时应该返回 Optional 或抛异常。
--   ★ 注意实体分支要求 IsValid()：无效实体走不到这里（会落到 elseif pt）。
function Dest:GetPoint()
    if self.inst ~= nil and self.inst:IsValid() then
--★ 取实体的世界位置。移动目标每帧都在动，所以不能缓存。
        return self.inst.Transform:GetWorldPosition()
    elseif self.pt then
        return self.pt:Get()
    elseif self.buffered_action ~= nil then
--★ 动作点的解析：GetActionPoint 返回 Point 对象，:Get() 才拿到 x,y,z。
        local act_pos = self.buffered_action:GetActionPoint()
        if act_pos ~= nil then
            return act_pos:Get()
        end
    end
    return 0, 0, 0
end

--★★★【GetPlatform：目的地的「平台」归属 —— 跳跃逻辑的关键输入】
--   为什么要知道目的地的平台？因为跳跃必须判断「目标是否在另一块平台上」。
--   1719-1730 的 hopping 分支全靠这个判定。
--   ⚠ 第一条分支的判定链很关键：目标实体在别人背包里（inventoryitem.owner 非 nil）
--     → 返回**持有者**的平台。
--     ★★ 这解决了「捡起一个放在船上的物品，走过去」的场景：
--     物品随船移动，所以目标平台是船而不是地面。
--★ 参见 entityscript.lua:927 AddPlatformFollower / :911 RemovePlatformFollower
--   —— 「平台跟随者」机制在 EntityScript 层实现，
--    locomotor 只消费 GetCurrentPlatform 的结果。
--   ★ 参见 components/walkableplatformplayer.lua:90 的 AddPlatformFollower 调用。
function Dest:GetPlatform()
--★ 三重 nil 守卫：实体存在 + 有 inventoryitem 组件 + 物品在背包里。
--★★【★ 平台跟随（platformfollowers）的实际实现不在本文件】
--   机制全貌：
--     ① 实体站在可站平台上 → walkableplatform.lua:146 AddPlatformFollower(ent)
--     ② 平台每帧移动 → 平台把自己的 Transform 位移**同步给**所有 follower
--     ③ follower 因此被动地跟着移动 —— locomotor 完全不参与
--   ★★ 所以「站在移动平台上被带着走」不需要 locomotor 做任何事：
--     平台的移动被直接施加到实体上，locomotor 只是不再设 motor 速度
--     （1740 行的 CheckDrownable / 1657 行的 cur_speed > 0 判定都会跳过）。
--   参见 entityscript.lua:911-930 的双向解绑实现，
--   以及 walkableplatformplayer.lua:261-277 的玩家特殊处理（掉出平台时移除）。
    if self.inst ~= nil and self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then
        return self.inst.components.inventoryitem.owner:GetCurrentPlatform()
    elseif self.inst ~= nil then
        return self.inst:GetCurrentPlatform()
    elseif self.pt then
--★ 目标是坐标点时，用地图查询该点的平台。
        return TheWorld.Map:GetPlatformAtPoint(self.pt:Get())
    elseif self.buffered_action ~= nil then
        local act_pos = self.buffered_action:GetActionPoint()
        if act_pos ~= nil then
            return TheWorld.Map:GetPlatformAtPoint(act_pos:Get())
        end
    end
    return nil
end

--★★★【双端 setter：把 netvar 写入包在 nil 守卫里】
--   `if self.inst.player_classified ~= nil` ——
--   ★ player_classified 只在**玩家**上存在，而且是 C++ 侧分类对象。
--     非玩家实体（怪物、物品）走这里会静默跳过——因为它们的速度不需要给客户端看
--     （客户端只能看到自己控制的玩家和被网络同步的生物的粗略位置）。
--   ★ 这是「同端同构、异端分派」模式的一个小切片：见 266 行构造函数的整体设计。
local function onrunspeed(self, runspeed)
    if self.inst.player_classified ~= nil then
        self.inst.player_classified.runspeed:set(runspeed)
    end
end

local function onexternalspeedmultiplier(self, externalspeedmultiplier)
    if self.inst.player_classified ~= nil then
        self.inst.player_classified.externalspeedmultiplier:set(externalspeedmultiplier)
    end
end

local function onexternalvelocityvectorx(self, externalvelocityvectorx)
    if self.inst.player_classified ~= nil then
        self.inst.player_classified.externalvelocityvectorx:set(externalvelocityvectorx)
    end
end

local function onexternalvelocityvectorz(self, externalvelocityvectorz)
    if self.inst.player_classified ~= nil then
        self.inst.player_classified.externalvelocityvectorz:set(externalvelocityvectorz)
    end
end

--★★★【ServerRunSpeed：骑乘时用坐骑的速度】
--   实体本身的 runspeed 在骑乘时被完全忽略，改用 mount.components.locomotor.runspeed。
--   ★ 语义：骑马时你的速度是马的速度，不是你的速度。
--   ★ 严格要求 mount 非 nil 才取——挂载物（boat）也有 locomotor 组件，所以统一取法。
--   ★ 走的是服务端路径：骑乘关系（rider 组件）只有服务端权威。
local function ServerRunSpeed(self)
    if self.inst.components.rider ~= nil then
        local mount = self.inst.components.rider:IsRiding() and self.inst.components.rider:GetMount() or nil
        if mount ~= nil then
            return mount.components.locomotor.runspeed
        end
    end
--★ 兜底：没骑乘就是自己的 runspeed。
    return self.runspeed
end

--★★★【ClientRunSpeed：客户端版本的三层取法】
--   ① 骑乘 → 走**复制组件** replica.rider:IsRiding()，
--      再调 rider:GetMountRunSpeed()（不是 mount.components.locomotor.runspeed！
--      因为客户端上 mount 的 components 是 nil，必须通过 rider 副本转发）。
--   ② 有 player_classified → 读 netvar 的 runspeed;value()。
--   ③ 都没有（普通生物）→ 退回 self.runspeed（本地值）。
--   ★★ 关键：客户端不能读 mount.components.locomotor，必须走副本链。
--      这就是「同一逻辑在两端需要不同取法」的具体体现。
--   ★ predicspeed（第 ③ 层前提）：
--     `if self.predictrunspeed ~= nil and self.inst:HasTag("autopredict")` ——
--     ★★★ 「autopredict」tag 是**客户端预测的授权开关**。
--       它只由 stategraph 在「玩家自己」的场景下加，
--       意味着：只有自己的玩家实体才允许客户端本地预测速度，
--       避免预测被用于作弊（移动其他实体）。
local function ClientRunSpeed(self)
    local rider = self.inst.replica.rider
    local mount = rider ~= nil and rider:IsRiding() and rider:GetMount() or nil
    if mount ~= nil then
--★ GetMountRunSpeed 是 rider 副本组件的方法 —— 它内部才知道挂载物怎么同步速度。
        return rider:GetMountRunSpeed()
    end
    if self.inst.player_classified ~= nil then
        if self.predictrunspeed ~= nil and self.inst:HasTag("autopredict") then
            return self.predictrunspeed
        end
--★ 读 netvar：value() 取当前值。这是「网络变量 = 客户端只读的服务端真值」。
        return self.inst.player_classified.runspeed:value()
    end
    return self.runspeed
end

--★ ServerFasterOnRoad 与 ServerRunSpeed 完全同构：道路加速同理走坐骑。
local function ServerFasterOnRoad(self)
    if self.inst.components.rider ~= nil then
        local mount = self.inst.components.rider:IsRiding() and self.inst.components.rider:GetMount() or nil
        if mount ~= nil then
            return mount.components.locomotor.fasteronroad
        end
    end
    return self.fasteronroad
end

--★ ClientFasterOnRoad：不检查 player_classified —— 道路加速任何实体都可能触发。
local function ClientFasterOnRoad(self)
    local rider = self.inst.replica.rider
    local mount = rider ~= nil and rider:IsRiding() and rider:GetMount() or nil
    if mount ~= nil then
        return rider:GetMountFasterOnRoad()
    end
    return self.fasteronroad
end

--★★★【ServerFasterOnCreep：骑乘时**直接返回 false**】
--   ★★ 这不是 bug，是规则：骑乘时在地面 creep（地上的腐蚀/蕨地）上不会加速。
--     原因是骑乘状态下移动由坐骑物理决定，creep 加速对玩家无效。
--   ★ 服务端与客户端（145 行）严格对称 —— 这是本文件双端分派的一条铁律：
--     任何影响速度的函数，两端实现必须给出相同结果，否则会「橡皮筋」抖动。
local function ServerFasterOnCreep(self)
    if self.inst.components.rider ~= nil then
        local mount = self.inst.components.rider:IsRiding() and self.inst.components.rider:GetMount() or nil
        if mount ~= nil then
--★ 注意这里不是 return self.fasteroncreep —— 语义完全不同。
            return false
        end
    end
    return self.fasteroncreep
end

local function ClientFasterOnCreep(self)
    local rider = self.inst.replica.rider
    local mount = rider ~= nil and rider:IsRiding() and rider:GetMount() or nil
    if mount ~= nil then
        return false
    end
    return self.fasteroncreep
end

--★ ServerExternalSpeedMutliplier（注意原拼写少了个 l，外部 API 不能改）：
--   直接返回本端维护的 externalspeedmultiplier 值（由 SetExternalSpeedMultiplier 维护）。
local function ServerExternalSpeedMutliplier(self)
    return self.externalspeedmultiplier
end

--★★★【ClientExternalSpeedMultiplier：客户端 = netvar × 本地预测】
--   `(player_classified.netvar 或 本地值) * self:GetPredictExternalSpeedMultipler()`
--   ★★★ 这是「双端速度系统」最精妙的一处：
--     · netvar 部分是**服务端权威**的外部倍率（来自装备/状态等）
--     · 预测部分是**纯客户端**的（见 548 行 SetPredictExternalSpeedMultiplier）
--     两者相乘得到最终值。
--   ★★ 为什么要拆成两半？因为「外部倍率」的施加方分两类：
--     · 服务端能算的（穿装备）→ 走 netvar，慢但权威
--     · 客户端瞬时算的（预判「我马上要吃加速药」）→ 走预测容器，快但会丢
--     服务端不认可预测时（如被减速），netvar 部分自然覆盖回来。
--   ★ 预测失配的恢复：See 188-190 行 ServerGetSpeedMultiplier 末尾的 throttle。
--★★ 参见 components/health.lua:158 不适用；本行的 netvar 读取路径是
--   `inst.player_classified.externalspeedmultiplier:value()`，
--   该 netvar 在 netvars.lua 中声明。
--   ★ 双端速度系统的另一半在 272-278 行的方法分派表。
local function ClientExternalSpeedMultiplier(self)
	return (self.inst.player_classified and self.inst.player_classified.externalspeedmultiplier:value() or self.externalspeedmultiplier) * self:GetPredictExternalSpeedMultipler()
end

--★ 外部速度向量（横/纵两轴）—— 用于「风/推力/传送残留」等非标准速度源。
local function ServerExternalVelocityVectorX(self)
    return self.externalvelocityvectorx
end

local function ServerExternalVelocityVectorZ(self)
    return self.externalvelocityvectorz
end

--★ 客户端读 netvar；externalvelocityvectorx 同样在 player_classified 上。
local function ClientExternalVelocityVectorX(self)
    return self.inst.player_classified and self.inst.player_classified.externalvelocityvectorx:value() or self.externalvelocityvectorx
end

local function ClientExternalVelocityVectorZ(self)
    return self.inst.player_classified and self.inst.player_classified.externalvelocityvectorz:value() or self.externalvelocityvectorz
end

--★★★【ServerGetSpeedMultiplier：速度倍率的合成中心】
--   最终速度 = GetRunSpeed() × GetSpeedMultiplier()，
--   而 GetSpeedMultiplier = 外部倍率 × 物品倍率 × 地面倍率 × 节流。
--   四个来源的合成规则：
--     ① ExternalSpeedMultiplier()  —— netvar/预测的外部倍率
--     ② 装备或鞍的倍率            —— 骑乘时看鞍，否则看身上装备
--     ③ TempGroundSpeedMultiplier() 或 groundspeedmultiplier —— 地面
--     ④ throttle                  —— 见 898 行，移动指令时重置为 1
--   ★★ 关键设计：② 骑乘与装备是**互斥**的（if rider then 鞍 else 装备）。
--     骑马时不能还享受「穿靴子 +10% 速度」的效果。
local function ServerGetSpeedMultiplier(self)
    local mult = self:ExternalSpeedMultiplier()
    if self.inst.components.inventory ~= nil then
--★★ 骑乘时看**鞍**的加成（saddle），不看角色的装备。
        if self.inst.components.rider ~= nil and self.inst.components.rider:IsRiding() then
            local saddle = self.inst.components.rider:GetSaddle()
--★ 鞍需要 saddler 组件才有加成（不是所有鞍都有）。
--   ★ 两层判空：saddle 实体存在 + 有 saddler 组件。
            if saddle ~= nil and saddle.components.saddler ~= nil then
                mult = mult * saddle.components.saddler:GetBonusSpeedMult()
            end
--★★★【库存必须打开才计算装备减速】英文原注释解释得很清楚：
--   "Check if inventory is open because client GetEquips returns nothing
--   if inventory is closed. Don't check visibility though."
--   ★★★ 这是**双端一致性**的精妙修补：
--     客户端的 GetEquips 在背包关闭时返回空（为了省网络），
--     若服务端仍按「装备齐全」算速度而客户端算「无装备」，
--     玩家会感到「一关背包就走不动路」。
--   ★★ 解法是让两端都用「背包是否打开」当条件，从而得到相同结果。
--     这是一个很值得学的「在错误的地方对齐错误」的经典案例。
--   ★ 「不检查 visibility」：打开背包但角色在屏幕外时也应该算，
--     因为「关背包减速」是游戏规则，与是否被看见无关。
        elseif self.inst.components.inventory.isopen then
            --NOTE: Check if inventory is open because client GetEquips returns
            --      nothing if inventory is closed.
            --      Don't check visibility though.
--★★【mightiness：韦爵「威猛」形态的减速免疫】
--   `is_mighty and item_speed_mult < 1 → 视作 1` ——
--   ★ 设计意图：威猛形态下免疫一切「装备减速」效果（但仍享受加速）。
--     只挡 < 1 的减速，不挡 > 1 的加速 —— 所以雪人/ freezing 等减速无效，
--     但仍能吃加血装备的速度加成。
--   ⚠ is_mighty 判定本身在两端也不同（见 220 行的客户端版），也是一致性修补。
			local is_mighty = self.inst.components.mightiness ~= nil and self.inst.components.mightiness:GetState() == "mighty"
--★ 遍历 equipslots（物品栏槽位表），只累加有 equippable 组件的物品。
            for k, v in pairs(self.inst.components.inventory.equipslots) do
                if v.components.equippable ~= nil then
					local item_speed_mult = v.components.equippable:GetWalkSpeedMult()
                    if is_mighty and item_speed_mult < 1 then
						item_speed_mult = 1
					end

                    mult = mult * item_speed_mult
                end
            end
        end
    end

--★★★【最终合成：三个倍率相乘 × 节流】
--   `mult * (TempGroundSpeedMultiplier() or groundspeedmultiplier) * self.throttle`
--   ★★ `or` 优先取临时地面倍率（655 行），它是「短时修正」，
--     优先级高于常态地面倍率（泥地减速、道路加速）。
--   ★ throttle 是「节流阀」：RunInDirection:1144 传 throttle 参数（0~1），
--     用于「慢慢走」类效果（如喝汤时的减速）。见 898 行 PushAction 重置为 1。
--   ★★★ 临时值优先级高于常态值 —— 这个设计让「临时加速」能覆盖「泥地减速」，
--     是常见的临时效果优先级约定。
    return mult * (self:TempGroundSpeedMultiplier() or self.groundspeedmultiplier) * self.throttle
end

--★★★【ClientGetSpeedMultiplier：客户端版，与服务端严格对称】
--   ★★ 逐行对照服务端版（178 行），差异只有「数据来源」：
--     装备 → replica.inventory:GetEquips()（与服务端 isopen 条件配对）
--     鞍   → saddle.replica.inventoryitem:GetWalkSpeedMult()（经副本链）
--   ★ 公式部分**逐字符相同** —— 这是本文件「双端同构」的铁律：
--     合成公式必须一致，否则速度会在端间跳变（玩家感到「顿一下」）。
local function ClientGetSpeedMultiplier(self)
    local mult = self:ExternalSpeedMultiplier()
    local inventory = self.inst.replica.inventory
    if inventory ~= nil then
--★ 客户端的骑乘判定也走副本（replica.rider）。
        local rider = self.inst.replica.rider
        if rider ~= nil and rider:IsRiding() then
            local saddle = rider:GetSaddle()
            local inventoryitem = saddle ~= nil and saddle.replica.inventoryitem or nil
            if inventoryitem ~= nil then
--★ 注意：客户端鞍的倍率来自 inventoryitem 副本（GetWalkSpeedMult），
--   而服务端来自 saddle.components.saddler:GetBonusSpeedMult()。
--   ★ 两条不同路径但语义相同 —— saddler 组件的倍率最终写进 inventoryitem 副本。
                mult = mult * inventoryitem:GetWalkSpeedMult()
            end
        else
--★ 再次强调 GetEquips 在背包关闭时为空 —— 注释重复一次因为这是极易踩的坑。
            --NOTE: GetEquips returns empty if inventory is closed! (Hidden still returns items.)
--★★ 客户端版 is_mighty 用**tag**（mightiness_mighty）判定，
--   而服务端用 components.mightiness:GetState() == "mighty"（190 行）。
--   ★★ 同一业务规则，两种表达方式：客户端读不到服务端组件，只能读 tag。
--     所以 tag 既是「状态广播」也是「客户端可判定的状态快照」。
			local is_mighty = self.inst:HasTag("mightiness_mighty")
--★ pairs 遍历（不是 ipairs）—— equips 是字典表，key 是槽位类型。
            for k, v in pairs(inventory:GetEquips()) do
                local inventoryitem = v.replica.inventoryitem
                if inventoryitem ~= nil then
					local item_speed_mult = inventoryitem:GetWalkSpeedMult()
                    if is_mighty and item_speed_mult < 1 then
						item_speed_mult = 1
					end

                    mult = mult * item_speed_mult
                end
            end
        end
    end

    return mult * (self:TempGroundSpeedMultiplier() or self.groundspeedmultiplier) * self.throttle
end

--★★★【ServerIsFasterOnGroundTile：地面加速的第二套判定（turf 系统）】
--   ★★ 与 FasterOnRoad（116 行）不同，这条查的是 faster_on_tiles 表 ——
--     即「特定地块类型上加速」（如绿蕈地/桦树皮地），
--     常用于「跑鞋」类效果。
--   ★ 第一层守卫：幽灵形态（isghostmode）下永不加速 —— 鬼不能跑步。
--   ★ 骑乘时查挂载物自己的 faster_on_tiles —— 与 FasterOnRoad 同构。
--   ★ `self.faster_on_tiles[ground_tile] == true` 用 `== true` 严格比较，
--     防止传入非布尔时被真值化（Lua 里 0 也是 true）。
function ServerIsFasterOnGroundTile(self, ground_tile)
	if self.inst.player_classified == nil or not self.inst.player_classified.isghostmode:value() then
		local rider = self.inst.components.rider
		local mount = rider ~= nil and rider:IsRiding() and rider:GetMount() or nil
		if mount ~= nil then
--★ 挂载物也检查 `~= nil`（防御：有些实体有 locomotor 但没设 faster_on_tiles）。
			return mount.components.locomotor ~= nil and mount.components.locomotor.faster_on_tiles[ground_tile]
        else
		    return self.faster_on_tiles[ground_tile] == true
        end
	end

	return false
end

--★★★【ClientIsFasterOnGroundTile：客户端用 tag 而非表】
--   `self.inst:HasTag("turfrunner_"..tostring(ground_tile))`
--   ★★ 原因：客户端拿不到服务端组件里的 faster_on_tiles 表。
--     所以服务端在 SetFasterOnGroundTile:600 里同时挂了 tag，
--     客户端读 tag —— 这就是「tag 作为跨端状态载体」的第二例。
--   ★ 拼 tag 名时用 tostring 包裹 —— 因为 ground_tile 是数字（tile id），
--     而 HasTag 要求字符串参数（引擎侧接口）。
function ClientIsFasterOnGroundTile(self, ground_tile)
	if self.inst.player_classified == nil or not self.inst.player_classified.isghostmode:value() then
		local rider = self.inst.replica.rider
		local mount = rider ~= nil and rider:IsRiding() and rider:GetMount() or nil
		if mount ~= nil then
			return mount:HasTag("turfrunner_"..tostring(ground_tile))
        else
		    return self.inst:HasTag("turfrunner_"..tostring(ground_tile))
        end
	end

	return false
end

--★★★★★【LocoMotor 构造：全文件最重要的 80 行】
--   它做三件大事：
--     ① 【双端分派】根据 ismastersim 把 8 个方法指向 server 或 client 实现
--     ② 【状态初始化】把所有速度、目标、跳跃相关字段初始化
--     ③ 【setter 绑定】把 4 个需同步到客户端的字段挂上 netvar 写入回调
--   ★★★ 整个 DST 组件系统的「双端」设计在此一览无余：
--     同一份 OnUpdate/OnUpdate 逻辑在两端各跑一遍，
--     差异全部收敛到「哪些取数据的函数用哪个实现」这一个决策上。
--★★ 参见 class.lua:82 Class(base, _ctor, props) —— 本行是第二个实参（构造器）。
--   class.lua:75 removesetter 是 289-292 行客户端降级所依赖的函数。
--   class.lua:64 addsetter 是运行期追加 setter 的接口（本文件未用）。
--   ★ 对比 health.lua:62 同样使用 props 表，两者是同一范式。
local LocoMotor = Class(function(self, inst)
    self.inst = inst
--★★ ismastersim 是全局常量（服务器为 true）。整个文件里到处判它。
--   ★ 注意 ismastersim 指的是「本进程是权威模拟端」，
--     对「非玩家实体」来说主机和客户端都会创建 locomotor 组件。
    self.ismastersim = TheWorld.ismastersim

--★ 服务端分支：给实例打 locomotor tag（客户端不用，因为客户端的实体不参与逻辑判定）。
    if self.ismastersim then
        inst:AddTag("locomotor")
--★★★【双端分派的实现：把方法名指向不同的函数】
--   `self.RunSpeed = ServerRunSpeed` —— 不是覆盖方法，而是「实例级的方法指针」。
--   ★★★ 设计收益：OnUpdate 等公共代码里可以直接写 `self:RunSpeed()`，
--     完全不需要写 `if self.ismastersim then ... else ... end`。
--     分派只在这一处发生，公共代码保持端无关。
--   ⚠ 副作用：这些方法不是类方法而是实例字段，
--     无法通过 LocoMotor.RunSpeed 静态访问，也无法被子类统一 override；
--     模组要改行为必须用 AddComponentPostInit 猴补。
--★★ 参见 class.lua 的方法查找机制（class.lua:82 `c.__index = __index`）——
--   因为 props 非 nil，方法查找走 __index 函数；
--   而 self.RunSpeed 是**实例字段**（rawset 到实例上），
--   它在实例表里，会**优先于**元表的 __index 命中。
--   ★ 这就是「把方法指向函数」能生效的底层原因。
        self.RunSpeed = ServerRunSpeed
        self.FasterOnRoad = ServerFasterOnRoad
        self.FasterOnCreep = ServerFasterOnCreep
        self.ExternalSpeedMultiplier = ServerExternalSpeedMutliplier
        self.ExternalVelocityVectorX = ServerExternalVelocityVectorX
        self.ExternalVelocityVectorZ = ServerExternalVelocityVectorZ
        self.GetSpeedMultiplier = ServerGetSpeedMultiplier
		self.IsFasterOnGroundTile = ServerIsFasterOnGroundTile
--★ 客户端分支同理。
    else
        self.RunSpeed = ClientRunSpeed
        self.FasterOnRoad = ClientFasterOnRoad
        self.FasterOnCreep = ClientFasterOnCreep
        self.ExternalSpeedMultiplier = ClientExternalSpeedMultiplier
        self.ExternalVelocityVectorX = ClientExternalVelocityVectorX
        self.ExternalVelocityVectorZ = ClientExternalVelocityVectorZ
        self.GetSpeedMultiplier = ClientGetSpeedMultiplier
		self.IsFasterOnGroundTile = ClientIsFasterOnGroundTile
--★★★【客户端 removesetter：客户端摘掉 netvar 写入回调】
--   `removesetter(self, "runspeed")` —— 参见 class.lua:75。
--   ★★ 关键设计：客户端不需要（也不应该）写 netvar。
--     netvar 是单向的（服务端→客户端），客户端赋值会报错或无意义。
--     所以客户端把字段恢复成「普通字段」，赋值只改本地值。
--   ★★ 这是双端组件的一个通用套路：
--     「共享的字段在客户端要降级为纯本地字段」。
--   ★ 对比 67 行 onrunspeed 里 `if player_classified ~= nil` 的 nil 守卫：
--     两者共同保证「客户端赋值 runspeed 不会同步，也不会崩」。
--★★ 参见 class.lua:75 removesetter(t, k) ——
--   它做 `rawset(t, k, _[k][1])`（恢复原值）再 `_[k] = nil`（摘除 setter）。
--   ★ 顺序不可反：先取回原值再删元数据。
        removesetter(self, "runspeed")
        removesetter(self, "externalspeedmultiplier")
        removesetter(self, "externalvelocityvectorx")
        removesetter(self, "externalvelocityvectorz")
    end

--★ dest（目标）与 atdestfn（到达回调）—— locomotor 的两大状态。
    self.dest = nil
    self.atdestfn = nil
    self.bufferedaction = nil
--★ arrive_step_dist 是「路径拐点的到达半径」（= ARRIVE_STEP = 0.15）。
--   ★ 与 arrive_dist（目的地的到达半径，通常 2~4）区分：
--     arrive_step_dist 用于路径中间点（细），arrive_dist 用于终点（粗）。
--   ★★ 为什么要分开？因为拐点要「精确经过」才转向，终点要「足够近就算到」。
    self.arrive_step_dist = ARRIVE_STEP
--★ arrive_dist 初值同样是 ARRIVE_STEP —— 无目标时的兜底。
    self.arrive_dist = ARRIVE_STEP
--★ WILSON_WALK_SPEED = 4 —— 基准走路速度。角色 prefab 在自己构造里改这个值。
--★ 参见 tuning.lua 的 WILSON_WALK_SPEED / WILSON_RUN_SPEED ——
--   角色 prefab（prefabs/wilson.lua 等）在构造时覆盖这两个值。
    self.walkspeed = TUNING.WILSON_WALK_SPEED -- 4
--★ WILSON_RUN_SPEED = 6 —— 基准跑步速度。原注释 "-- 6" 标明了默认值。
    self.runspeed = TUNING.WILSON_RUN_SPEED -- 6
--★★ throttle = 1（节流）。PushAction/PushStart 时重置为 1（898 行），
--   RunInDirection 可传 0~1 的部分速度。「缓慢移动」效果的基础。
    self.throttle = 1
--★★★【lastpos = {}：地面速度优化的缓存槽】
--   ★★★ 性能关键：UpdateGroundSpeedMultiplier 每帧都调代价很高
--     （要查 GroundCreep:OnCreep + 查地块 + 查道路）。
--     优化：只有当所在**地块坐标**变化时才重算（见 1438-1444）。
--   ★ lastpos 初始为空表，所以第一次 OnUpdate 必然触发一次重算。
    self.lastpos = {}
--★ slowmultiplier = 0.6 —— 在 creep（腐蚀地）上行走时速度 × 0.6。
    self.slowmultiplier = 0.6
--★ fastmultiplier = 1.3 —— 在快地面（道路/turf）上行走时速度 × 1.3。
    self.fastmultiplier = 1.3
--★ movestarttime = -1 —— 移动开始时刻，GetTimeMoving 用它算已移动时长。
    self.movestarttime = -1
--★ movestoptime = -1 —— 移动停止时刻。-1 是哨兵值（不是 nil），
--   因为 nil 在 Lua 里表示「无值」，而 -1 表示「有效但很久以前」。
--   ★★ 这个区别很关键：见 407 行 `self.movestoptime ~= nil and ...`，
--     用 -1 哨兵可以让条件简化为「减出来的时间差是否超阈值」，
--     而不需要额外的「是否曾停止过」标志。
    self.movestoptime = -1
--⚠【被注释的字段】movetimeoverride / predictmovestarttime / no_predict_fastforward
--   实际在 435/438/441/890 行有对应逻辑，只是构造时不需要初始化（nil 是有效初值）。
--   ★ 与 89 行 health.lua 一样：注释保留作为「这些字段存在」的记录。
	--self.movetimeoverride = nil
    --self.predictmovestarttime = nil
--★ no_predict_fastforward —— 见 PlayerController:RepeatHeldAction()，
--   用来标记「这个动作不应该被客户端预测快进」。
	--self.no_predict_fastforward = nil --see PlayerController:RepeatHeldAction()

--★ groundspeedmultiplier = 1.0 —— 常态地面倍率（泥地/道路之外的默认）。
    self.groundspeedmultiplier = 1.0
--★ enablegroundspeedmultiplier —— 总开关。关闭时所有地面效果失效（583 行清空状态）。
    self.enablegroundspeedmultiplier = true
    --self.tempgroundspeedmultiplier = nil
    --self.tempgroundspeedmulttime = nil
    --self.tempgroundtile = nil
    --self.modifytempgroundspeedmultiplier = nil
--★ isrunning：当前是否处于「跑」姿态。由 WalkForward/RunForward 设定。
    self.isrunning = false

--★★ _externalspeedmultipliers 是「来源→倍率」的表（详见 480 行）。
--   与 externalspeedmultiplier（计算结果）分离 —— 表是输入，字段是输出。
    self._externalspeedmultipliers = {}
--★ externalspeedmultiplier = 1 —— 计算结果初值（无来源时为 1 = 不减速也不加速）。
    self.externalspeedmultiplier = 1

--★ _externalvelocityvectors 同构 —— 外部速度向量的来源表。
    self._externalvelocityvectors = {}
    self.externalvelocityvectorx = 0
    self.externalvelocityvectorz = 0

--★ wasoncreep：上一帧是否在 creep 上（用于边沿事件，610/624 行）。
    self.wasoncreep = false
--★ triggerscreep：是否响应 creep。关闭后实体能在 creep 上正常走（如幽灵）。
    self.triggerscreep = true
--★ is_prediction_enabled —— 客户端预测开关（当前仅记录，未在本文件内读取）。
    self.is_prediction_enabled = false
--★ hop_distance = TUNING.DEFAULT_LOCOMOTOR_HOP_DISTANCE = 6.0
--   —— 跳跃探测的最大距离。太小跳不上船，太大会跳过头。
--★ 参见 tuning.lua:4359 DEFAULT_LOCOMOTOR_HOP_DISTANCE = 6.0。
--   参见 tuning.lua:3637 PLATFORM_HOP_DELAY_TICKS = 8 与
--   tuning.lua:3638 PLATFORM_FLOATING_HOP_DELAY_TICKS = 4。
    self.hop_distance = TUNING.DEFAULT_LOCOMOTOR_HOP_DISTANCE
	--self.hop_distance_fn = nil
--★ hopping：跳跃中标志。OnUpdate:1425 见到它就早退（跳跃期间不做移动决策）。
    self.hopping = false
--★ time_before_next_hop_is_allowed：跳跃冷却，防止连跳（见 1413 行）。
    self.time_before_next_hop_is_allowed = 0
	--self.hop_delay = nil

--★ faster_on_tiles = {}：turf 加速表（绿蕈地等）。客户端读它对应的 tag。
    self.faster_on_tiles = {}

--⚠【被注释的字段】isupdating / predictrunspeed / pusheventwithdirection
--   分别在 366/108/341 行有对应逻辑。pusheventwithdirection 主要是给玩家用的
--   ——让「locomote」事件携带方向信息，供状态图处理「初始朝向」。
    --self.isupdating = nil
    --self.predictrunspeed = nil
	--self.predictexternalspeedmultiplier = nil
--★★ pusheventwithdirection 的设计动机（英文原注释）：
--   "mainly for players, to handle initial move dir, and not have to add
--   'canrotate' to all interruptible states"
--   ★★★ 翻译：玩家按下方向键时，locomotor 不知道该朝哪转，
--     于是把方向塞进事件数据，让状态图自己决定怎么转。
--   ★★ 这样就不必给「所有可打断的状态」都加 canrotate 标签，
--     减少了状态图标签的维护成本。
	--self.pusheventwithdirection = false --mainly for players, to handle initial move dir, and not have to add "canrotate" to all interruptible states
end,
nil,
--★★ setter 表：4 个字段需同步到客户端。参见 class.lua:82 的 props 机制。
--   与 health.lua 同构。注意这里没有 maxhealth 之类的纯服务端字段。
--★ 参见 class.lua:82 —— props 表让这 4 个字段的赋值触发 netvar 写入。
{
    runspeed = onrunspeed,
    externalspeedmultiplier = onexternalspeedmultiplier,
    externalvelocityvectorx = onexternalvelocityvectorx,
    externalvelocityvectorz = onexternalvelocityvectorz,
})

--★★【EnableHopDelay：跳跃延迟的懒初始化】
--   hop_delay 是一张记录跳跃延迟状态的小表（记录从哪个平台到哪个平台、
--   起始 tick 等），见 1276-1319 行的使用。
--   ★★ 它是可选功能：只有调用过 EnableHopDelay(true) 的实体才有延迟。
--     延迟机制的目的是「防止玩家狂点方向键连续跳船」（见 1411 行注释）。
--   ★ 传 false 会把它置 nil（关闭延迟）——**双向开关**。
function LocoMotor:EnableHopDelay(enable)
	if enable == false then
		self.hop_delay = nil
	elseif self.hop_delay == nil then
--★ 四个字段：toplatform/fromplatform（延迟跨平台的具体范围）、
--   starttick/lasttick（延迟计时的起止）。starttick=-1 表示「未开始计时」。
		self.hop_delay =
		{
			toplatform = nil,
			fromplatform = nil,
			starttick = -1,
			lasttick = -1,
		}
	end
end

--★★★【StartUpdatingInternal：把「我要每帧更新」的请求落地】
--   ★★ 关键：`if not self.inst:IsAsleep()` —— 休眠实体不加入更新队列。
--     但 isupdating 仍被置 true！
--   ★★★ 这是「休眠协作」的核心：
--     · isupdating = true 记住「唤醒后应该继续更新」
--     · OnEntityWake:381 读它并真正 StartUpdatingComponent
--   ★ 若不加 IsAsleep 检查，休眠实体会被每帧遍历（性能浪费），
--     且它的 OnUpdate 会在无渲染的情况下跑（可能引发副作用）。
function LocoMotor:StartUpdatingInternal()
    self.isupdating = true
    if not self.inst:IsAsleep() then
        self.inst:StartUpdatingComponent(self)
    end
end

--★ StopUpdatingInternal 是对称的：清 isupdating 标志 + 移出更新队列。
function LocoMotor:StopUpdatingInternal()
    self.isupdating = nil
    self.inst:StopUpdatingComponent(self)
end

--★★★【OnEntitySleep：休眠即停止移动】
--   ★★ 设计决策：实体进入休眠（离屏太远）时，直接 Stop() ——
--     不仅停止物理移动，还要清掉目标、路径、缓冲动作。
--   ★ 理由：休眠意味着「没有玩家在看它」，任何自动移动都是浪费 CPU；
--     而且唤醒后实体位置必须与服务器一致，让它继续走会穿墙。
function LocoMotor:OnEntitySleep()
    self:Stop()
end

--★ OnEntityWake 恢复更新 —— 与 365 行的 isupdating 标记严格配对。
function LocoMotor:OnEntityWake()
    if self.isupdating then
        self.inst:StartUpdatingComponent(self)
    end
end

--★★【OnRemoveFromEntity：组件卸载清理】
--   ★ 三件事：① 摘 locomotor tag（服务端）；② 摘 turf 加速 tag；
--     ③ 摘所有外部倍率来源的 onremove 监听；④ 重置预测倍率。
--   ⚠★ 缺失的清理：没有 KillPathSearch()。
--     若实体在寻路搜索挂起时被移除，搜索句柄会悬空。
--     这属于「引擎层负责回收」还是「缺陷」取决于 C++ 侧的实现，
--     但从 Lua 侧看这是个清理漏洞。
function LocoMotor:OnRemoveFromEntity()
    if self.ismastersim then
        self.inst:RemoveTag("locomotor")

--★ 摘 turf 加速 tag —— 与 600 行的 AddOrRemoveTag 配对。
--   ⚠ 遍历时用 `for ground_tile in pairs(...)` 而非 ipairs（是字典表）。
		for ground_tile in pairs(self.faster_on_tiles) do
			self.inst:RemoveTag("turfrunner_"..tostring(ground_tile))
		end
    end
--★ 摘除所有外部倍率来源的 onremove 监听 —— 防止闭包持有已死实体。
--   ★★★ 这正是 bug-patterns.md A7（事件监听未注销）的正确处理方式。
	for source, src_params in pairs(self._externalspeedmultipliers) do
		self.inst:RemoveEventCallback("onremove", src_params.onremove, source)
	end
--★ 预测倍率容器重置 —— 客户端专用（服务端不创建该容器，见 549 行）。
	if self.predictexternalspeedmultiplier then
		self.predictexternalspeedmultiplier:Reset()
	end
end

--★★★【GetTimeMoving：已移动时长，供状态图/战斗判断「持续移动了多久」】
--   三级判定：
--     ① predictmovestarttime 存在 → 用**客户端预测**的时刻（客户端优化）
--     ② movestoptime 存在且距停止 ≥ 0.3 秒 → 返回 0（已停稳）
--     ③ 否则 → now - movestarttime
--   ★★ 为什么要 0.3 秒阈值（而不是立即返回 0）？
--     因为移动中的实体会**周期性停下**（撞墙、被推开、路径拐点减速），
--     若一停下就归零，会导致「我明明在走却被判定为静止」。
--     0.3 秒的迟滞窗口过滤掉了这些微小停顿。
--   ★★ 这是「迟滞（hysteresis）」设计的又一处应用（另见 health.lua 的 FIRE_TIMEOUT）。
function LocoMotor:GetTimeMoving()
    local t = GetTime()
--★ 客户端预测路径：predictmovestarttime 由 RestartPredictMoveTimer 设置，
--   客户端用它做「提前判定」，减少输入延迟感知。
    if self.predictmovestarttime ~= nil then
        return t - self.predictmovestarttime
    elseif self.movestoptime ~= nil and t - self.movestoptime >= MOVE_TIMER_STOP_THRESHOLD then
        --stopped longer than threshold
        return 0
    end
--★ 兜底路径：从未停过 → now - movestarttime。
    return t - self.movestarttime
end

--★★★【StartMoveTimerInternal："开始移动"的迟滞重置】
--   ★ 逻辑：只有当「上次停止距今 ≥ 0.3 秒」才算真正的重新开始，
--     此时才重置 movestarttime（并撤销 movetimeoverride）。
--   ★ 否则（刚刚才停下）只清 movestoptime，不动 movestarttime ——
--     这样「短暂的停-走-停」不会让计时器反复重置。
function LocoMotor:StartMoveTimerInternal()
    if self.movestoptime ~= nil then
        local t = GetTime()
        if t - self.movestoptime >= MOVE_TIMER_STOP_THRESHOLD then
--★ movetimeoverride 撤销：这是客户端预测的定时清理（见 438 行）。
			if self.movetimeoverride then
				self.movetimeoverride:Cancel()
				self.movetimeoverride = nil
			end
--★★ 关键：movestarttime = t（而非 t - 0.3），因为 0.3 秒只是「判定阈值」，
--   不是「应该补偿回的时间」。
            self.movestarttime = t
        end
        self.movestoptime = nil
    end
end

--★ StopMoveTimerInternal 极简：只在第一次停止时记时刻（不动 movestarttime）。
--   ★★ 幂等设计：重复调用不会覆盖第一次停止的时刻，
--     所以「什么时候停的」是稳定的，不会被后续的重复 Stop 滑动。
function LocoMotor:StopMoveTimerInternal()
    if self.movestoptime == nil then
        self.movestoptime = GetTime()
    end
end

--★ ClearOverrideMoveTimer：延迟 2 帧后自动清除预测覆盖值。
--   ★★ 为什么要延迟 2 帧？因为 OverrideMoveTimer 的目的是「本帧内让预测生效」，
--     下一帧的服务器数据到达后就该失效了。
--     用 DoTaskInTime(2 * FRAMES) 而不是逐帧检查，是「一次性清理」的标准写法。
local function ClearOverrideMoveTimer(inst, self)
	self.movetimeoverride = nil
end

--★★★【OverrideMoveTimer：强制设置「已移动时长」】
--   `self.movestarttime = t - movetime` —— 把起点往回挪，等价于「已经移动了 movetime 秒」。
--   ★★ 用途【客户端→服务器的移动时间预测同步】：
--     玩家按住方向键走路，客户端本地能精确知道「我走了 3 秒」，
--     但服务器只知道「玩家在动」。当玩家在移动中发起攻击时，
--     攻击的距离/时机判定（combat.lua 的 GetTimeMoving）需要准确的移动时长。
--     所以客户端通过 PopOverrideTimeMoving 把这个值随攻击包发给服务器。
--   ★ 这是「客户端预测 + 服务端采纳」的一个小而精的例子。
--   ⚠ 只在客户端创建清理任务（`if not self.ismastersim`）——
--     服务端不需要预测清理，因为服务端的 movestarttime 就是权威值。
--★★ 参见 components/playercontroller.lua 的攻击输入处理 ——
--   PopOverrideTimeMoving 的结果会随网络包上报，
--   服务端用 OverrideMoveTimer 采纳这个预测值。
--   ★ 参见 components/combat.lua 里 GetTimeMoving 的使用方（移动攻击的距离判定）。
function LocoMotor:OverrideMoveTimer(movetime)
	local t = GetTime()
	self.movestoptime = nil
	self.movestarttime = t - movetime
	if not self.ismastersim then
		if self.movetimeoverride then
			self.movetimeoverride:Cancel()
		end
--★ 2 * FRAMES = 2 帧（FRAMES 常量为一帧的 tick 数，通常 1/30 秒）。
--   ★ 用 2 而非 1：留一帧余量，确保下一网络批次的权威数据已覆盖。
		self.movetimeoverride = self.inst:DoTaskInTime(2 * FRAMES, ClearOverrideMoveTimer, self)
--★ 把 movetime 挂在 Periodic 对象上（_movetime）—— Lua 没有闭包字段的替代方案。
--   ★ 这是「用对象当结构体」的常见技巧，Periodic 对象本身是安全可挂载的。
		self.movetimeoverride._movetime = movetime
	end
end

--★★ 英文原注释 "only used by clients for sending to server"。
--   ★ 明确了这个方法的唯一用途：客户端上报预测的移动时长。
--only used by clients for sending to server
function LocoMotor:PopOverrideTimeMoving()
	if self.movetimeoverride then
		local movetime = self.movetimeoverride._movetime
		self.movetimeoverride:Cancel()
		self.movetimeoverride = nil
		return movetime
	end
end

--★★ RestartPredictMoveTimer：客户端预测计时的开始（玩家开始移动时调）。
--   ★ 由 playercontroller 在处理玩家输入时调用。
function LocoMotor:RestartPredictMoveTimer()
    self.predictmovestarttime = GetTime()
end

--★ CancelPredictMoveTimer：取消预测。GoToEntity/GoToPoint 都会调（986/1044 行），
--   注释说「能走到这里说明客户端没在预测」—— 即服务端路径会取消客户端的预测。
function LocoMotor:CancelPredictMoveTimer()
    self.predictmovestarttime = nil
end

--★ OverridePredictTimer：直接设定预测起始时刻（网络同步来的时间戳用）。
function LocoMotor:OverridePredictTimer(t)
	self.predictmovestarttime = t
end

--★★★【StopMoving：物理层立即停】
--   `self.inst.Physics:Stop()` —— 停止 C++ 侧的物理马达。
--   ★ 与 Stop()（1091 行）区分：Stop() 是「完整停止移动意图」，
--     StopMoving() 是「只停物理，不清目标」。
--   ★ 为什么物理速度会被重置？Physics:Stop 把速度与马达速度都清零，
--     这也是「实体不会滑行」的原因。
function LocoMotor:StopMoving()
    self.isrunning = false
    self.inst.Physics:Stop()
end

--★★★【V2C 注释揭示了 Recalculate 的设计契约】
--   "we always call this to recalculate even if only one value changes,
--   so we can always do custom math here"
--   ★★★ 翻译：即使只有一个倍率变了，也总是**全量重算**所有倍率，
--     这样「合成算法」可以随时被模组改写成任意数学规则，
--     而不必关心「哪个值变了」。
--   ★ 这是「无增量、无缓存」的刻意选择：牺牲性能换可扩展性。
--     性能上完全可接受（倍率来源通常个位数，每帧调用几次）。
--   ★ 模组改写方式：猴补本函数即可改变所有外部倍率的合成规则。
--V2C: we always call this to recalculate even if only one value
--     changes, so we can always do custom math here
--★★ RecalculateExternalSpeedMultiplier：所有来源的倍率**连乘**。
--   语义：1.2（加速 20%）和 0.8（减速 20%）相乘 = 0.96（净减速 4%），
--   而不是加法 1.0。这是倍率类效果的常规合成方式。
function LocoMotor:RecalculateExternalSpeedMultiplier(sources)
    local m = 1
    for source, src_params in pairs(sources) do
        for k, v in pairs(src_params.multipliers) do
            m = m * v
        end
    end
    return m
end

--★★★【SetExternalSpeedMultiplier：带来源与 key 的倍率设置】
--   三层防护：
--     · key 为 nil → 直接返回（防呆：必须指定 key）
--     · m 为 nil 或 1 → 转为「移除」（1 是无效果的恒等值）
--     · 首次注册该来源 → 建表 + 注册 onremove 自摘除
--   ★ 把 m=1 当作「移除」是刻意的：调用方不需要自己判断「要不要撤」。
--   ★ onremove 自摘除（501-506）：来源实体消失时自动清掉其倍率。
function LocoMotor:SetExternalSpeedMultiplier(source, key, m)
    if key == nil then
        return
    elseif m == nil or m == 1 then
        self:RemoveExternalSpeedMultiplier(source, key)
        return
    end
    local src_params = self._externalspeedmultipliers[source]
    if src_params == nil then
        self._externalspeedmultipliers[source] = {
            multipliers = { [key] = m },
            onremove = function(source)
                self._externalspeedmultipliers[source] = nil
                self.externalspeedmultiplier = self:RecalculateExternalSpeedMultiplier(self._externalspeedmultipliers)
            end,
        }
--★ ListenForEvent 注册自摘除 —— 参见 util/sourcemodifierlist.lua 的同款实现。
        self.inst:ListenForEvent("onremove", self._externalspeedmultipliers[source].onremove, source)
        self.externalspeedmultiplier = self:RecalculateExternalSpeedMultiplier(self._externalspeedmultipliers)
--★ 已有该来源且该 key 的值变了 → 更新并全量重算。
    elseif src_params.multipliers[key] ~= m then
        src_params.multipliers[key] = m
        self.externalspeedmultiplier = self:RecalculateExternalSpeedMultiplier(self._externalspeedmultipliers)
    end
end

--key is optional if you want to remove the entire source
--★★【RemoveExternalSpeedMultiplier：与 Set 完全对称的两段式移除】
--   传 key → 只删这一路；删完发现该来源没路了 → 整体拆掉 + 反注册 onremove。
--   ★ 与 health.lua 的 RemoveRegenSource（407 行）是同一套模式。
function LocoMotor:RemoveExternalSpeedMultiplier(source, key)
    local src_params = self._externalspeedmultipliers[source]
    if src_params == nil then
        return
    elseif key ~= nil then
--★ 删 key 后判断来源是否还有其它 key（决定是否整体拆）。
        src_params.multipliers[key] = nil
        if next(src_params.multipliers) ~= nil then
            --this source still has other keys
            self.externalspeedmultiplier = self:RecalculateExternalSpeedMultiplier(self._externalspeedmultipliers)
            return
        end
    end
    --remove the entire source
    self.inst:RemoveEventCallback("onremove", src_params.onremove, source)
    self._externalspeedmultipliers[source] = nil
    self.externalspeedmultiplier = self:RecalculateExternalSpeedMultiplier(self._externalspeedmultipliers)
end

--key is optional if you want to calculate the entire source
--★★ GetExternalSpeedMultiplier：查询接口，key 可选。
--   不传 key → 返回该来源所有 key 的乘积；传 key → 返回该 key 的值（或 1）。
--   ★ 统一用 `or 1` 兜底 —— 「无效果」的标准表示法。
function LocoMotor:GetExternalSpeedMultiplier(source, key)
    local src_params = self._externalspeedmultipliers[source]
    if src_params == nil then
        return 1
    elseif key == nil then
        local m = 1
        for k, v in pairs(src_params.multipliers) do
            m = m * v
        end
        return m
    end
    return src_params.multipliers[key] or 1
end

--★★★【SetPredictExternalSpeedMultiplier：客户端专用预测倍率】
--   ★★★ 与 SetExternalSpeedMultiplier 的关键区别：
--     · 不分双端，**只在客户端被调用**（548 行无 ismastersim 判断，
--       但因为只在客户端场景使用，语义上等价）
--     · 用 SourceModifierList 而不是手写表（复用现成的自摘除机制）
--     · 结果在 159 行与 netvar 相乘，不直接替换
--   ★★ 设计意图：让「马上要吃加速/减速药」这类瞬时效果
--     在**本地立即生效**，而不等服务端下一网络帧。
--     服务端不认可时，netvar 部分会自然覆盖回来。
--★★ 参见 util/sourcemodifierlist.lua:8 SourceModifierList 构造签名
--   `Class(function(self, inst, base_value, fn, dirtycb)` —— 本行**不传** base_value，
--   所以用默认的 1 与 multiply 语义（见 sourcemodifierlist.lua:28）。
--   util/sourcemodifierlist.lua:60 SetModifier 内部会自动注册 onremove 清理。
--   ★ 与 health.lua:92-93 的差别：那里显式传 base_value=0 与 additive，
--     因为吸收率是「加法累计」，而这里是「倍率连乘」。
function LocoMotor:SetPredictExternalSpeedMultiplier(source, key, m)
	if not self.predictexternalspeedmultiplier then
		self.predictexternalspeedmultiplier = SourceModifierList(self.inst)
	end
	self.predictexternalspeedmultiplier:SetModifier(source, m, key)
end

--key is optional if you want to remove the entire source
function LocoMotor:RemovePredictExternalSpeedMultiplier(source, key)
	if self.predictexternalspeedmultiplier then
		self.predictexternalspeedmultiplier:RemoveModifier(source, key)
	end
end

--key is optional if you want to calculate the entire source
--★ 注意函数名拼写是 GetPredictExternalSpeedMultipler（少一个 i，Multipler）。
--   ★★★ 这是一个**接口命名瑕疵**：内部调用（159 行）也跟着拼错。
--     因为它是公开 API，改名会炸模组，所以只能将错就错。
--     强类型移植时这是一个必须保留的历史拼写（或加 deprecated 别名）。
function LocoMotor:GetPredictExternalSpeedMultipler(source, key)
--★ 三元式 `A and A:Get() or 1` —— 容器不存在时返回 1（无效果）。
	return self.predictexternalspeedmultiplier and self.predictexternalspeedmultiplier:Get() or 1
end

--★ SetSlowMultiplier：creep 上的减速倍率（默认 0.6，可被 prefab 改）。
function LocoMotor:SetSlowMultiplier(m)
    self.slowmultiplier = m
end

--★ SetTriggersCreep：是否响应 creep 边沿事件（某些实体如幽灵不触发）。
function LocoMotor:SetTriggersCreep(triggers)
    self.triggerscreep = triggers
end

--★ SetFasterOnCreep：是否在 creep 上加速（反向于减速）。
function LocoMotor:SetFasterOnCreep(faster)
    self.fasteroncreep = faster
end

--★★【EnableGroundSpeedMultiplier：地面速度的总开关】
--   关闭时**同时清空所有临时状态**（tempgroundspeedmultiplier 等），
--   而不只是置 enable=false。
--   ★ 为什么必须清？因为 TempGroundSpeedMultiplier（655 行）
--     不检查 enable 标志，只看时间戳。若只置 enable=false，
--     临时倍率仍会生效 —— 这就是「开关必须清理关联状态」的典型。
function LocoMotor:EnableGroundSpeedMultiplier(enable)
    self.enablegroundspeedmultiplier = enable
    if not enable then
        self.groundspeedmultiplier = 1
        self.tempgroundspeedmultiplier = nil
        self.tempgroundspeedmulttime = nil
        self.tempgroundtile = nil
    end
end

--★★★【GetWalkSpeed / GetRunSpeed：最终速度的两个入口】
--   两者结构完全相同：`基准速度 × GetSpeedMultiplier()`。
--   ★ 区别只在基准：walkspeed（4）与 RunSpeed()（6 或坐骑速度）。
--   ★★ RunSpeed 走函数（可能是坐骑速度），walkspeed 是裸字段 ——
--     所以骑马时走路速度**不会**用马的速度。这个不对称是有意的：
--     坐骑的「走」由坐骑自己控制（DST 坐骑没有走/跑之分）。
function LocoMotor:GetWalkSpeed()
    return self.walkspeed * self:GetSpeedMultiplier()
end

function LocoMotor:GetRunSpeed()
    return self:RunSpeed() * self:GetSpeedMultiplier()
end

--★★【SetFasterOnGroundTile：turf 加速的 setter，必须双写（表 + tag）】
--   `self.faster_on_tiles[tile] = is_faster`（服务端数据）
--   `self.inst:AddOrRemoveTag("turfrunner_"..tile, is_faster)`（客户端可见）
--   ★★★ 这就是「tag 作为跨端状态载体」的写入点，
--     与 252-263 行 ClientIsFasterOnGroundTile 的 tag 读取严格配对。
--   ★ 为什么 turf 用 tag 而 runspeed 用 netvar？因为 turf 是
--     「世界数据」（由世界扫描写入），不是「玩家数据」，
--     netvar 是每实体一个浮点数，太多 turf 实体会浪费带宽；
--     而 tag 是位打包的，扩展性好。
function LocoMotor:SetFasterOnGroundTile(ground_tile, is_faster)
	if self.ismastersim then
		self.faster_on_tiles[ground_tile] = is_faster
        self.inst:AddOrRemoveTag("turfrunner_"..tostring(ground_tile), is_faster)
	end
end

--★★★【UpdateGroundSpeedMultiplier：每帧可能被调用的性能敏感函数】
--   这是本文件最热的函数之一（每帧、每移动实体都跑）。
--   它做两件互斥的事：
--     在 creep 上 → 设 slowmultiplier（减速）
--     不在 creep 上 → 按「快地面条件」设 fastmultiplier 或 1（加速/正常）
--   ★★★ 性能：内部有三次世界查询——
--     ① TheWorld.GroundCreep:OnCreep(x,y,z)（查 creep 网格）
--     ② TheWorld.Map:GetTileAtPoint（查地块）
--     ③ RoadManager:IsOnRoad（查道路）
--     ★★ 优化全靠调用方（1438-1444 行）：只在「地块坐标变化」时才调本函数。
--       所以实际调用频率 ≈ 「每秒跨过的地块数」而非 30 次/秒。
function LocoMotor:UpdateGroundSpeedMultiplier()
--★ 取世界坐标 —— 之后所有查询都基于它。
    local x, y, z = self.inst.Transform:GetWorldPosition()
--★ GroundCreep:OnCreep 查地面腐蚀（西边的蕨地/触手等）。C++ 侧网格查询。
    local oncreep = TheWorld.GroundCreep:OnCreep(x, y, z)

--★ oncreep 且允许触发 —— 才走减速分支。
    if oncreep and self.triggerscreep then
--★★★【英文原注释是一条设计自省】
--   "if this ever needs to happen when self.enablegroundspeedmultiplier is
--   set, need to move the check for self.enablegroundspeedmultiplier above"
--   ★★★ 翻译：这段 creep 减速逻辑**绕过了** enablegroundspeedmultiplier 开关
--     （它只检查 triggerscreep）。作者知道这是不一致的，并写下了修复方案：
--     「若将来需要在开关打开时才生效，把开关检查提到前面」。
--   ★ 这是一段难得的「把已知技术债写进注释」的范例 ——
--     强类型重写时应该直接执行这个修复。
--   ⚠ 具体表现：调用 EnableGroundSpeedMultiplier(false) 之后，
--     实体在 creep 上**依然会减速**。这是可观察的行为差异。
        -- if this ever needs to happen when self.enablegroundspeedmultiplier is set, need to move the check for self.enablegroundspeedmultiplier above
--★★ `if not self.wasoncreep` —— 边沿检测：只有「刚踏上 creep」才派发事件。
--   ★ 这保证「站在 creep 上不动」不会每帧重复派发 walkoncreep。
        if not self.wasoncreep then
--★ GetTriggeredCreepSpawners：查出该位置会触发哪些 creep 生成器（伏笔需求）。
            local spawners = TheWorld.GroundCreep:GetTriggeredCreepSpawners(x, y, z)
            local eventdata = { target = self.inst, spawners = spawners, }
            for _, v in ipairs(spawners) do
                v:PushEvent("creepactivate", eventdata)
            end
--★ walkoncreep 事件：供 prefab 播放「踩到腐蚀」特效等。
            self.inst:PushEvent("walkoncreep", eventdata)
            self.wasoncreep = true
        end

--★★ vigorbuff 标签：韦爵的「活力」buff 让他免疫 creep 减速。
--   ★ 注意这个检查在 triggerscreep 之后、enable 之外 ——
--     属于「个体免疫」层，与全局开关层正交。
        if not self.inst:HasTag("vigorbuff") then
            self.groundspeedmultiplier = self.slowmultiplier
        end
    else
--★ 离开 creep 的边沿事件 walkoffcreep —— 与 616 配对。
        if self.wasoncreep and self.triggerscreep then
            self.inst:PushEvent("walkoffcreep")
        end
        self.wasoncreep = false

--★★【退出 creep 后：查三类「快地面」条件】
--   三者任一成立就用 fastmultiplier，否则 1：
--     ① IsFasterOnGroundTile(当前地块) —— turf（绿蕈地等）
--     ② FasterOnRoad() 且（在道路上 或 地块本身是道路）—— 人工道路
--     ③ oncreep 且 FasterOnCreep() —— 可配置在 creep 上加速的实体
--   ★★ 为什么 ② 要查两个条件（RoadManager:IsOnRoad 或 GROUND_ROADWAYS[tile]）？
--     RoadManager 是道路系统的运行时查询（瓦片级数据），
--     GROUND_ROADWAYS 是静态表（tilemanager.lua:175 填充的道路地块）。
--     两者覆盖不同来源的道路，且 RoadManager 本身可能是 nil（非道路世界）。
        local current_ground_tile = TheWorld.Map:GetTileAtPoint(x, 0, z)
--★★ 三条件用 or 串联在同一个 and 表达式里 —— 整个表达式为真才加速。
--   ★ 严格用 `== true` 的是 245 行；这里 IsFasterOnGroundTile 已返回布尔。
        self.groundspeedmultiplier = (self:IsFasterOnGroundTile(current_ground_tile) or
--★★【`RoadManager ~= nil and RoadManager:IsOnRoad(...) or GROUND_ROADWAYS[tile]`】
--   ⚠⚠ 这里的 and/or 链式三元有个**经典陷阱**：
--     若 RoadManager 存在但 IsOnRoad 返回 **false**，
--     表达式会继续评估 `GROUND_ROADWAYS[tile]` —— 这恰好是想要的（fallback）。
--     但若 RoadManager 存在、IsOnRoad 返回 false、且 GROUND_ROADWAYS[tile] 为 nil，
--     整个子表达式为 nil（falsy）—— 结果正确。
--   ★ 所以这里恰好是安全的，因为 fallback 是「或」关系。
--     但它**不是**「RoadManager 缺失时用静态表」这么简单：
--     两者是逻辑或，不是有优先级的 fallback。
                                     (self:FasterOnRoad() and ((RoadManager ~= nil and RoadManager:IsOnRoad(x, 0, z)) or GROUND_ROADWAYS[current_ground_tile])) or
                                     (oncreep and self:FasterOnCreep()))
--★ 加速倍率（1.3），否则 1。整行是一个 and-or 表达式。
									 and self.fastmultiplier
									 or 1
    end
end

--★★★【PushTempGroundSpeedMultiplier：临时地面加速】
--   用于「踩到某物短暂加速」类效果。三个特征：
--     ① 只取**最小**的 mult（647 行 `mult <= self.tempgroundspeedmultiplier`），
--        即多个来源同时推时，**减速优先**（取更保守的值）
--     ② 有 modifierfn 钩子（640 行），供模组改写
--     ③ 有效期只有 0.034 秒（见 657 行）
--   ★★ 语义：这个函数是「每帧被调用」的（由具体 prefab 在 OnUpdate 里调），
--     所以效果靠「持续推」维持；一旦停止推，0.034 秒后自动失效。
--   ★ 这就是「无状态计时」的技巧：不存到期时刻，只存「最后一次推的时间」，
--     读取时比较 now - lasttime < 窗口。不需要定时器就能实现 TTL。
function LocoMotor:PushTempGroundSpeedMultiplier(mult, tile)
    if self.enablegroundspeedmultiplier then
        if self.modifytempgroundspeedmultiplier ~= nil then
            mult = self.modifytempgroundspeedmultiplier(self.inst, mult)
        end

        local t = GetTime()
--★★★【取最小值的规则 —— 整段最反直觉的一行】
--   `if tempgroundspeedmultiplier == nil or t > tempgroundspeedmulttime
--    or mult <= self.tempgroundspeedmultiplier then`
--   三个条件任一成立就接受新值：
--     · 还没有临时值（首次）
--     · 上次的值已过期（t > 旧时间戳）
--     · 新值比旧值**更小**（mult <= 旧值）——即减速覆盖加速
--   ★★ 设计意图：多个来源同时生效时，取最不利（最低）的那个。
--     举例：踩到加速带（1.3）同时中了减速 debuff（0.5）→ 结果 0.5 而非 0.65。
--   ★ 为什么是 min 而不是 max？因为「临时修正」多用于**惩罚性**效果
--     （沼泽、火山灰），取 min 保证惩罚不被加速抵消。
--   ⚠ 但这意味着「多个加速来源不叠加」——设计取舍，不是 bug。
        if self.tempgroundspeedmultiplier == nil or
            t > self.tempgroundspeedmulttime or
            mult <= self.tempgroundspeedmultiplier then
            self.tempgroundspeedmultiplier = mult
            self.tempgroundtile = tile
        end
--★ 刷新时间戳 —— 每次推都刷新，TTL 因此是「最后一次推后 0.034 秒」。
        self.tempgroundspeedmulttime = t
    end
end

--★★★【TempGroundSpeedMultiplier：读取即判定过期（并顺手清理）】
--   `if self.tempgroundspeedmulttime + 0.034 > GetTime() then return 值`
--   ★★ 0.034 秒 ≈ 一帧（1/30 = 0.0333）。多出的 0.0007 是浮点余量。
--   ★ 设计：过期时**顺手把三个字段都置 nil**（惰性清理）。
--     不需要额外的清理任务，也不会有「残留的临时值突然复活」。
--   ★★★ 这是一个很干净的 TTL 实现范式，值得复用。
--   ⚠ 副作用：第一次读取若已过期，会把状态清掉，
--     所以「读一次就没了」—— 若某个 prefab 只推一次就读多次，
--     必须在同帧内读，否则效果丢失。
function LocoMotor:TempGroundSpeedMultiplier()
    if self.tempgroundspeedmultiplier ~= nil then
        if self.tempgroundspeedmulttime + 0.034 > GetTime() then
            return self.tempgroundspeedmultiplier
        end
--★ 惰性清理：三个字段一起清，与 649 行的写入严格对称。
        self.tempgroundspeedmultiplier = nil
        self.tempgroundspeedmulttime = nil
        self.tempgroundtile = nil
    end
end

--★★【TempGroundTile：与 TempGroundSpeedMultiplier 同构】
--   ⚠⚠ 疑似缺陷【重复清理代码】：
--     666-675 行的函数体与 655-664 几乎完全相同，唯一区别是返回值。
--     更要紧的是：TempGroundTile 里清理的字段**也是** tempgroundspeedmultiplier ——
--     这本身是对的（两者同生命周期），但两份重复的清理逻辑意味着
--     若将来要加第四个字段（如来源标记），很容易只改一处。
--     这不是功能性 bug，是可维护性隐患。
--   ★ 顺带说明 tempgroundtile 的用途：由 prefab 记录「临时加速来自哪块地」，
--     用于播放对应的特效/音效。
function LocoMotor:TempGroundTile()
    if self.tempgroundtile ~= nil then
        if self.tempgroundspeedmulttime + 0.034 > GetTime() then
            return self.tempgroundtile
        end
        self.tempgroundspeedmultiplier = nil
        self.tempgroundspeedmulttime = nil
        self.tempgroundtile = nil
    end
end

--★★ 英文原注释强调：「Call for both client and server, make sure results are synced」
--   ★ 这条约束很重要：modifierfn 若只在服务端调用，客户端算出的速度就不同，
--     产生「本地看着正常，一到联机就卡顿」。
--   ★★★ 这是本文件「双端同构」原则的又一体现：
--     凡影响最终速度的逻辑，两端必须同时以相同输入执行。
function LocoMotor:SetTempGroundSpeedMultiplierModifier(modifierfn) -- Call for both client and server, make sure results are synced
    self.modifytempgroundspeedmultiplier = modifierfn
end

--★★【StartStrafing：进入斜向模式】
--   ★★ 斜向移动的语义：「身体朝向 strafedir，但移动方向自由」。
--     典型场景是端着盾走路时仍能自由转向。
--   ⚠⚠ 疑似缺陷【直接解引用 player_classified】：
--     `self.inst.player_classified.isstrafing:value()` 没有 nil 守卫。
--     虽然 ismastersim 判了，但**服务端上的怪物也有 locomotor 组件**，
--     而怪物没有 player_classified。
--     推理依据：对比 67 行 onrunspeed 里严谨的
--     `if self.inst.player_classified ~= nil` 守卫，
--     以及 238 行 ServerIsFasterOnGroundTile 的 `== nil or` 写法，
--     本函数与 StopStrafing（689 行）都缺了这个守卫。
--     实际未崩的原因是：只有玩家会调用 StartStrafing/StopStrafing
--     （由 playercontroller 调用），而玩家必有 player_classified。
--     ★ 所以这是「靠调用方约束存活」而非「靠自身守卫存活」的隐式契约 ——
--       强类型移植或模组误调用时会立刻暴露为崩溃。
function LocoMotor:StartStrafing()
--★ 双重守卫：服务端 且 当前未在斜向（避免重复派发事件）。
	if self.ismastersim and not self.inst.player_classified.isstrafing:value() then
		self:SetStrafing(true)
		self.inst.player_classified.isstrafing:set(true)
--★ startstrafing 事件供状态图切到「持盾行走」等对应状态。
		self.inst:PushEvent("startstrafing")
	end
end

function LocoMotor:StopStrafing()
	if self.ismastersim and self.inst.player_classified.isstrafing:value() then
		self:SetStrafing(false)
		self.inst.player_classified.isstrafing:set(false)
		self.inst:PushEvent("stopstrafing")
	end
end

--★★★【SetStrafing：斜向模式的开关与初始化】
--   ★ 关键：进入斜向时记录「当前朝向」为 strafedir，
--     之后身体朝向就不再被移动方向改写。
--   退出时置 nil —— 回到「朝向 = 移动方向」的普通模式。
function LocoMotor:SetStrafing(strafing)
	if not strafing then
		self.strafedir = nil
	elseif self.strafedir == nil then
--★ strafedir 初始化为当前旋转角（Transform:GetRotation 返回弧度制角度）。
		self.strafedir = self.inst.Transform:GetRotation()
	end
end

--★★【SetMoveDir：移动方向设置 —— 斜向模式的核心分叉】
--   斜向中 → 改的是 strafedir（朝向），**不动实际移动方向**
--   非斜向 → 改 Transform 旋转（身体朝向 = 移动方向）
--   ★★★ 关键理解：斜向模式下，移动方向由 Physics 的 motor velocity 决定，
--     身体朝向由 strafedir 决定，两者解耦。
--   ★ 这就是斜向的完整实现：SetMotorSpeed（726 行）负责解耦移动，
--     SetMoveDir 负责解耦朝向。
function LocoMotor:SetMoveDir(dir)
	if self.strafedir then
		self.strafedir = dir
	else
		self.inst.Transform:SetRotation(dir)
	end
end

--★★【FaceMovePoint：转向到某点 —— 斜向下的特殊处理】
--   斜向中 → 不动 Transform，只改 strafedir
--   非斜向 → 调 inst:FacePoint（引擎侧转向）
--   ★★ 「busy」状态标签检查：正在做动作（如攻击）时不转向，
--     避免「攻击时身体乱转」。
--   ⚠ 注意 716 行的条件是 `not (sg and sg:HasStateTag("busy"))`，
--     而 1610 行的同类检查用的是 `not (sg and HasStateTag("busy"))` + canrotate。
--     两处的 busy 语义一致，但 canrotate 检查位置不同（这里没有 canrotate）。
function LocoMotor:FaceMovePoint(x, y, z)
	if self.strafedir == nil then
		self.inst:FacePoint(x, y, z)
	elseif not (self.inst.sg and self.inst.sg:HasStateTag("busy")) then
		self.strafedir = self.inst:GetAngleToPoint(x, y, z)
	end
end

--★★★【SetMotorVelRelToStrafeDir：把「沿移动方向」转成「沿世界坐标」】
--   `angle = (strafedir - dir) * DEGREES`
--   `Physics:SetMotorVel(speed * cos(angle), 0, -speed * sin(angle))`
--   ★★ 数学：把速度向量在「朝向坐标系」下分解为 (cos, sin) 分量，
--     再转成世界 XZ 坐标。DST 的约定是 +X 为 0°、顺时针为正（因此有负号）。
--   ★★★ 关键洞察【两层速度模型的真相】：
--     · locomotor.lua 里**只有水平速度**（Y 分量恒为 0，见 723/730 行）
--     · 垂直方向（跳跃、下落、斜坡）完全由 **C++ 侧物理**处理
--       （Physics 组件的重力与碰撞），见 physics.lua
--     · 「两层速度模型」的分层是「Lua 水平层 + C++ 垂直层」，
--       不是 Lua 内部的两层
--   ★ 所以本文件没有 verticalVelocity 字段——这是刻意的架构划分，
--     不是遗漏。跳跃由 stategraph 的 jumping 状态触发（见 commonstates.lua:797），
--     物理由引擎接管。
--★ 参见 physics.lua —— PhysicsCollisionCallbacks / CollisionMaskBatcher
--   是 Lua 侧能看到的全部物理设施。
--   ★ Physics 组件本体（SetMotorVel / GetMotorVel / SetVel / Teleport）
--   是 C++ 侧实现，Lua 无源码。这是「两层速度模型」的物理层。
local function SetMotorVelRelToStrafeDir(inst, speed, dir, strafedir)
	local angle = (strafedir - dir) * DEGREES
	inst.Physics:SetMotorVel(speed * math.cos(angle), 0, -speed * math.sin(angle))
end

--★★【SetMotorSpeed：速度设置的双路径】
--   斜向 → SetMotorVelRelToStrafeDir（解耦）
--   非斜向 → 直接 SetMotorVel(speed, 0, 0)（motor 朝自身前方）
--   ★ 非斜向时只给 X 分量，物理引擎会按当前 Transform 旋转方向推进。
function LocoMotor:SetMotorSpeed(speed)
	if self.strafedir then
		SetMotorVelRelToStrafeDir(self.inst, speed, self.inst.Transform:GetRotation(), self.strafedir)
	else
		self.inst.Physics:SetMotorVel(speed, 0, 0)
	end
end

--★★【OnStrafeFacingChanged：斜向中朝向被外部改变时的补偿】
--   ★★ 场景：斜向模式里，状态图或其他代码改了实体旋转（如受击转向）。
--     若不补偿，motor velocity 就与新朝向脱节（会横着走）。
--   解法：用新的 dir 重算 motor velocity。
--   ★ 这是一个「外部状态变更 → 重算派生状态」的标准钩子。
function LocoMotor:OnStrafeFacingChanged(dir)
	if self.strafedir and dir ~= self.inst.Transform:GetRotation() then
		self.inst.Transform:SetRotation(dir)
		SetMotorVelRelToStrafeDir(self.inst, self.inst.Physics:GetMotorSpeed(), dir, self.strafedir)
	end
end

--★★【WalkForward / RunForward：最基础的移动原语】
--   结构完全相同，只差 isrunning 标志与速度来源。
--   ★★ 三个动作：设姿态 → 设 motor 速度 → 启动每帧更新。
--     第三个动作最容易被忘 —— 漏了它就不会转向、不会到达、不会跳跃。
--   ★ direct 参数："直接前进"模式。
--     设为 true 时记 wantstomoveforward，供 OnUpdate 决策是否继续 locomote。
function LocoMotor:WalkForward(direct)
    self.isrunning = false
    if direct then self.wantstomoveforward = true end
	self:SetMotorSpeed(self:GetWalkSpeed())
    self:StartUpdatingInternal()
end

--★ RunForward：唯一区别是 isrunning=true 与 GetRunSpeed()。
function LocoMotor:RunForward(direct)
    self.isrunning = true
    if direct then self.wantstomoveforward = true end
	self:SetMotorSpeed(self:GetRunSpeed())
    self:StartUpdatingInternal()
end

--★★★【Clear：只清「意图」，不动物理】
--   清理项：目标、到达回调、前进意图、跑意图、缓冲动作。
--   ★★ 注意它**不清** wantstomoveforward 之外的东西，也不调 Physics:Stop()
--     —— 因为 Clear 可能在「立即要设新目标」的场景被调用（792/905 行），
--     此刻停止物理会造成一帧的顿挫。真正的停止是 Stop()（1091 行）。
--   ★ 与 ResetPath 的区别：Clear 不碰路径，ResetPath 专门清路径。
--     782 行的 Clear 里注释掉的 `self:ResetPath()` 说明曾考虑过合并。
function LocoMotor:Clear()
    --Print(VERBOSITY.DEBUG, "LocoMotor:Clear", self.inst.prefab)
    self.dest = nil
    self.atdestfn = nil
    self.wantstomoveforward = nil
    self.wantstorun = nil
--★ SetBufferedAction(nil) 会**Fail 掉旧动作**（见 1079 行）——
--   换目标时旧动作必须被显式作废，否则会留下「悬挂的缓冲动作」。
	self:SetBufferedAction(nil)
    --self:ResetPath()
end

--★★【ResetPath：清路径 + 杀搜索】
--   顺序：先 KillPathSearch（杀掉挂起的 C++ 搜索），再清 path。
--   ★★ 顺序重要：先杀再清，才能保证不会残留一个「句柄已失效但 Lua 仍持有」的 path。
function LocoMotor:ResetPath()
    --Print(VERBOSITY.DEBUG, "LocoMotor:ResetPath", self.inst.prefab)
    self:KillPathSearch()
    self.path = nil
end

--★ KillPathSearch 用 WaitingForPathSearch() 做守卫（防重复杀）。
function LocoMotor:KillPathSearch()
    --Print(VERBOSITY.DEBUG, "LocoMotor:KillPathSearch", self.inst.prefab)
    if self:WaitingForPathSearch() then
        TheWorld.Pathfinder:KillSearch(self.path.handle)
    end
end

--★ SetReachDestinationCallback：设置「到达目的地时执行」的回调（atdestfn）。
--   ★ 与 bufferedaction 的区别：atdestfn 是**纯通知**，不携带动作。
function LocoMotor:SetReachDestinationCallback(fn)
    self.atdestfn = fn
end

--★★★【PreviewAction —— 客户端「预测」版的动作路由】
--   ★★★ 与 PushAction（882 行）是**同一套逻辑的两个平行实现**：
--     · PreviewAction 在客户端跑（本地预测，喂给 PreviewBufferedAction）
--     · PushAction 在服务端跑（权威，喂给 PushBufferedAction）
--   ★ 两者结构逐条对应，但**不是简单镜像**——有几处刻意的不对称（见下）。
--   ★★ 这种「双份路由表」是 DST 的固有代价：
--     客户端要立即给玩家视觉反馈，服务端要保证权威正确。
--     ⚠ 维护风险极高：加一种新动作类型时**必须同时改两个函数**，
--       漏改会导致「本地看起来会去，联机上却不走过去」。
--   ---- 决策顺序（两者一致）----
--   ① WALKTO（显式走过去的动作）
--   ② LOOKAT（注视/查看）
--   ③ forced（强制动作，如开门）
--   ④ instant / do_not_locomote（瞬时或不需要走过去）
--   ⑤ 有 target → GoToEntity
--   ⑥ 无 action_pos → 直接执行
--   ⑦ CASTAOE → 范围技能（AOE 施法）
--   ⑧ 无穷远距离 → 视为瞬时
--   ⑨ 兜底 → GoToPoint
function LocoMotor:PreviewAction(bufferedaction, run, try_instant)
    if bufferedaction == nil then
        return
    end

--★ pre_action_cb：动作的前置钩子（修改动作参数，如距离、方向）。
--   ★ 在 Clear 之前调用 —— 前置钩子失败时原移动意图还未被破坏。
    if bufferedaction.action.pre_action_cb ~= nil then
        bufferedaction.action.pre_action_cb(bufferedaction)
    end

--★★ throttle 重置为 1：每次发起新动作都恢复全速。
--   ★ 与 RunInDirection:1144 的部分节流相对。
    self.throttle = 1
    self:Clear()
    local action_pos = bufferedaction:GetActionPoint()

--★ WALKTO 动作：显式「走到某处」。分 target / action_pos 两种。
    if bufferedaction.action == ACTIONS.WALKTO then
        if bufferedaction.target ~= nil then
            self:GoToEntity(bufferedaction.target, bufferedaction, run)
        elseif action_pos ~= nil then
            self:GoToPoint(nil, bufferedaction, run)
        end
--★★★【LOOKAT 分支 —— 客户端版比服务端版多了三个条件】
--   条件：有 playercontroller 且**不是** directwalking（直走模式）。
--   ★ directwalking 是「玩家用 WASD 直走而非点击移动」的模式，
--     此时 LOOKAT 不该触发自动走过去。
--   ★★ 客户端独有的 overridelocomote 检查（805 行）：
--     若状态图有 overridelocomote 标签，说明「移动由状态图接管」，
--     此时只做预览，不发移动指令。
--   ⚠ 服务端版（915 行）**没有** overridelocomote 检查 —— 刻意的差异，
--     因为服务端不需要「预览」，且状态图已在服务端做出决策。
    elseif bufferedaction.action == ACTIONS.LOOKAT and
        self.inst.sg ~= nil and
        self.inst.components.playercontroller ~= nil and
        not self.inst.components.playercontroller.directwalking then
--★ overridelocomote 标签：状态图说「我自己管移动」。见 OnUpdate:1631 的对应处理。
		if self.inst.sg:HasStateTag("overridelocomote") then
			self.inst:PreviewBufferedAction(bufferedaction)
		else
			local closeinspect = false
			if bufferedaction.target then
--★ CanCloseInspect：能否「走近看」（如物品详情）。能则走过去看，不能就原地预览。
--   ★ 定义在 componentutil.lua:657 的 CLOSEINSPECTORUTIL。
				if CLOSEINSPECTORUTIL.CanCloseInspect(self.inst, bufferedaction.target) then
					closeinspect = true
					self:GoToEntity(bufferedaction.target, bufferedaction, run)
				end
			elseif action_pos then
				if CLOSEINSPECTORUTIL.CanCloseInspect(self.inst, action_pos) then
					closeinspect = true
					self:GoToPoint(nil, bufferedaction, run)
				end
			end
			if not closeinspect then
				self:Stop()

--★★★【V2C 注释解释了一个 workaround】
--   "since LOOKAT now has an action handler for closeinspect support, we can use
--   options.instant to bypass it during preview. see EntityScript:PreviewBufferedAction"
--   ★ 背景：LOOKAT 加了「走近查看」支持后，预览时会真的走过去；
--     所以预览路径必须用 options.instant 强制绕过。
--   ★★ 这是「特性新增后回补旧路径」的典型痕迹，也提示：
--     options.instant 是一个**递归传染的标志** —— 设了它，下游又会去改它。
				--V2C: since LOOKAT now has an action handler for closeinspect support,
				--     we can use options.instant to bypass it during preview.
				--     see EntityScript:PreviewBufferedAction
				bufferedaction.options.instant = true

				if bufferedaction.target ~= nil then
					self:FaceMovePoint(bufferedaction.target.Transform:GetWorldPosition())
				end
--★ 若不在 idle 状态则强制播 idle 动画 —— 避免「走着走着卡在走路动画」。
				if not self.inst.sg:HasStateTag("idle") then
--★ 幽灵（playerghost）用 idle 而非 idle_loop —— 幽灵没有循环待机动画。
					local idle_anim = self.inst:HasTag("playerghost") and "idle" or "idle_loop"
					if not self.inst.AnimState:IsCurrentAnimation(idle_anim) then
						self.inst.AnimState:PlayAnimation(idle_anim, true)
					end
				end
				self.inst:PreviewBufferedAction(bufferedaction)
--★ 强制进 idle 状态并加 noanim 参数（避免重复播动画）。
				self.inst.sg:GoToState("idle", "noanim")
			end
		end
--★ forced 分支：强制动作（如开门）—— 若有 action_pos 就走过去。
    elseif bufferedaction.forced then
        if action_pos ~= nil then
            self:GoToPoint(nil, bufferedaction, run)
        end
--★★★【instant / do_not_locomote / options.instant 三条件并联】
--   三者任一成立 → 直接执行，不移动。
--   ★ options.instant 由 826 行设置（预览路径强制置位）。
--   ★★ 注意这条分支在客户端版和**服务端版的位置相同**（946 行），
--     所以「预览时瞬时执行」与「真正执行时瞬时执行」保持一致。
--★ 参见 components/bufferedaction.lua 的 options.instant ——
--   该标志由 PreviewAction:826 与外部逻辑设置，会一路传到
--   EntityScript:PushBufferedAction。
	elseif bufferedaction.action.instant or bufferedaction.action.do_not_locomote or bufferedaction.options.instant then
        self.inst:PreviewBufferedAction(bufferedaction)
--★ 有目标 → 走过去执行。
    elseif bufferedaction.target ~= nil then
--★★★【客户端用 replica.inventoryitem 判断「物品是否被持有」】
--   `bufferedaction.target.replica.inventoryitem:IsHeld()`
--   ★ 服务端版（949 行）用 components.inventoryitem.owner —— 路径不同，语义相同。
		local inventoryitem = bufferedaction.target.replica.inventoryitem
		local owner = inventoryitem ~= nil and inventoryitem:IsHeld() and bufferedaction.target.entity:GetParent() or nil
--★★【pocketdimension_container 特殊处理：不能走到 (0,0,0)】
--   ★★★ 这是「手套」类道具的特殊情况：
--     它挂着一个 pocketdimension（次级维度容器），其坐标在次级空间里。
--     如果按常规走过去，目标坐标是次级空间的原点，实体真的会跑过去。
--     所以改为「只转向 + 直接执行」。
--   ★ 这类「坐标系不统一」的特例，是本文件里最「脏」也最必要的分支。
		if owner ~= nil and owner:HasTag("pocketdimension_container") then
			--don't try to walk to this container at (0, 0, 0)
			self:FaceMovePoint(bufferedaction.target.Transform:GetWorldPosition())
			self.inst:PushBufferedAction(bufferedaction)
--★ 距离为无穷大 → 视为瞬时（只转向不移动）。
		elseif bufferedaction.distance ~= nil and bufferedaction.distance >= math.huge then
            --essentially instant
			self:FaceMovePoint(bufferedaction.target.Transform:GetWorldPosition())
            self.inst:PreviewBufferedAction(bufferedaction)
        else
            self:GoToEntity(bufferedaction.target, bufferedaction, run)
        end
--★ 无 action_pos → 无处可去 → 直接执行。
    elseif action_pos == nil then
        self.inst:PreviewBufferedAction(bufferedaction)
--★★【CASTAOE：范围施法动作的距离判定】
--   `GetDistanceSqToPoint(action_pos) <= distance^2` ——
--   ★ 用**距离平方**比较，避免开方（性能 + 精度）。
--   在范围内 → 转向 + 立即执行；不在 → 走过去。
--   ★ 这是 AOE 技能的标准处理：站进范围就能放，不必精确走到点。
    elseif bufferedaction.action == ACTIONS.CASTAOE then
        if self.inst:GetDistanceSqToPoint(action_pos) <= bufferedaction.distance * bufferedaction.distance then
			self:FaceMovePoint(action_pos:Get())
            self.inst:PreviewBufferedAction(bufferedaction)
        else
            self:GoToPoint(nil, bufferedaction, run)
--★ bufferedcastaoe 事件：告诉上层「正在走向 AOE 施法点」。
--   ★★ 守卫 `if self.bufferedaction == bufferedaction` 是必要的：
--     GoToPoint 可能立即失败并换掉 bufferedaction，此时不该派发。
            if self.bufferedaction == bufferedaction then
                self.inst:PushEvent("bufferedcastaoe", bufferedaction)
            end
        end
    elseif bufferedaction.distance ~= nil and bufferedaction.distance >= math.huge then
        --essentially instant
		self:FaceMovePoint(action_pos:Get())
        self.inst:PreviewBufferedAction(bufferedaction)
    else
        self:GoToPoint(nil, bufferedaction, run)
    end
end

--★★★★★【PushAction —— 服务端权威版的动作路由】
--   ★ 结构与 PreviewAction 平行，但有四处**实质差异**：
--     ① 先调 TestForStart()，失败则派发 actionfailed 并返回（899 行）
--        —— 客户端预览不做这个检查（因为还没真正开始）
--     ② LOOKAT 分支条件不同（没有 directwalking 判断，改为用
--        GetRemotePredictPositionExternal 取远端预测位置）
--     ③ forced 分支多了 rangecheckfn 检查（938 行）
--     ④ 调 PushBufferedAction 而非 PreviewBufferedAction
--   ★★ 差异 ② 的意义：服务端处理的是**客户端上报的意图**，
--     所以要相信客户端给的「远程预测位置」作为目的地。
--   ⚠ 维护提示：加新动作类型时必须 PreviewAction + PushAction 同改。
function LocoMotor:PushAction(bufferedaction, run, try_instant)
    if bufferedaction == nil then
        return
--★ playercontroller:OnRemoteBufferedAction —— 告诉控制器「收到远端动作请求」。
	elseif self.inst.components.playercontroller ~= nil then
		self.inst.components.playercontroller:OnRemoteBufferedAction()
	end

--★★★【no_predict_fastforward 的传染标记】
--   `if self.no_predict_fastforward then bufferedaction.options.no_predict_fastforward = true`
--   ★★★ 把组件级标志复制到**动作的 options 表**上，
--     让下游（EntityScript:PerformBufferedAction）也能看到这个意图。
--   ★ 来源：PlayerController:RepeatHeldAction() —— 玩家按住右键重复动作时，
--     不允许客户端预测快进（否则会连发）。
	--V2C: see PlayerController:RepeatHeldAction()
	if self.no_predict_fastforward then
		bufferedaction.options.no_predict_fastforward = true
	end

    if bufferedaction.action.pre_action_cb ~= nil then
        bufferedaction.action.pre_action_cb(bufferedaction)
    end

    self.throttle = 1
--★★★【TestForStart：执行前的合法性检查】
--   ★★ 为什么要在这里检查而不在动作真正执行时？
--     因为「走过去」可能耗时很久，目标可能在此期间失效。
--     先检查一次可以提前失败，不必白走一趟。
--   ★ actionfailed 事件携带 reason，供 UI 提示玩家为什么没反应。
    local success, reason = bufferedaction:TestForStart()
    if not success then
--★ actionfailed 事件：UI 层（widgets/controls.lua）监听它显示失败提示。
        self.inst:PushEvent("actionfailed", { action = bufferedaction, reason = reason })
        return
    end

    self:Clear()
    local action_pos = bufferedaction:GetActionPoint()
    if bufferedaction.action == ACTIONS.WALKTO then
        if bufferedaction.target ~= nil then
            self:GoToEntity(bufferedaction.target, bufferedaction, run)
        elseif action_pos then
            self:GoToPoint(nil, bufferedaction, run)
        else
            return
        end
--★ LOOKAT 分支（服务端版）：条件更宽松（只要有 playercontroller）。
--   ★★ 关键差异：931 行用 `pos and not directwalking` ——
--     远端预测位置存在且非直走模式 → 走过去；否则直接执行。
    elseif bufferedaction.action == ACTIONS.LOOKAT and
        self.inst.components.playercontroller ~= nil then
		local closeinspect = false
		if bufferedaction.target then
			if CLOSEINSPECTORUTIL.CanCloseInspect(self.inst, bufferedaction.target) then
				closeinspect = true
				self:GoToEntity(bufferedaction.target, bufferedaction, run)
			end
		elseif action_pos then
			if CLOSEINSPECTORUTIL.CanCloseInspect(self.inst, action_pos) then
				closeinspect = true
				self:GoToPoint(nil, bufferedaction, run)
			end
		end
		if not closeinspect then
--★★★【GetRemotePredictPositionExternal：客户端上报的预测位置】
--   ★ 这是「客户端预测」的服务端消费点：
--     玩家点击地面 → 客户端本地立刻走过去（预测）→
--     同时把「我预计要去哪」发给服务器 →
--     服务端用这个位置作为 GoToPoint 的目标，
--     从而让服务端的移动与客户端视觉一致。
--   ★ 若这个值为 nil（客户端没上报或直走模式），则退化为「不移动」。
--   ⚠ 安全考量：这是客户端可控的数据。若直接信任，
--     恶意客户端可以声称「我要走到世界尽头」来让角色跑飞。
--     ★ 实际约束：GoToPoint 走的是正常寻路（1817 行 FindPath），
--     目标不可达时寻路器会失败，实体不会真的跑到非法位置。
--★★ 参见 components/playercontroller.lua —— GetRemotePredictPositionExternal
--   是「客户端把预测目标位置上报给服务端」的通道。
--   配套参见 playercontroller.lua:2212 附近的 revive 相关处理（与 health.lua 的联动）。
			local pos = self.inst.components.playercontroller:GetRemotePredictPositionExternal()
			if pos and not self.inst.components.playercontroller.directwalking then
				self:GoToPoint(pos, bufferedaction, run)
			else
				self.inst:PushBufferedAction(bufferedaction)
			end
		end
    elseif bufferedaction.forced then
--★★【rangecheckfn：强制动作的距离复核】
--   ★ forced 分支（开门、挖掘等）里，先复核目标是否还在合法范围。
--   不在范围内 → 丢弃 target 与 initialtargetowner（相当于放弃这次尝试）。
--   ★★ 为什么客户端版没有这个检查？因为客户端是预览，
--     真正执行前服务端还会重新检查一次。
        if bufferedaction.action.rangecheckfn ~= nil and
            not bufferedaction.action.rangecheckfn(bufferedaction.doer, bufferedaction.target) then
            bufferedaction.target = nil
            bufferedaction.initialtargetowner = nil
        end
        if action_pos ~= nil then
--★ overridedest：额外的目的地覆盖（供网络控制器支持，见 1039 行注释）。
            self:GoToPoint(nil, bufferedaction, run, bufferedaction.overridedest)
        end
	elseif bufferedaction.action.instant or bufferedaction.action.do_not_locomote or bufferedaction.options.instant then
        self.inst:PushBufferedAction(bufferedaction)
    elseif bufferedaction.target ~= nil then
--★ 服务端版用 components.inventoryitem 判断持有 —— 与 848 行客户端版对称。
		local owner = bufferedaction.target.components.inventoryitem ~= nil and bufferedaction.target.components.inventoryitem.owner or nil
		if owner ~= nil and owner:HasTag("pocketdimension_container") then
			--don't try to walk to this container at (0, 0, 0)
			self:FaceMovePoint(bufferedaction.target.Transform:GetWorldPosition())
			self.inst:PushBufferedAction(bufferedaction)
--★ 与 854 行完全对称的「无穷远即瞬时」分支。
		elseif bufferedaction.distance ~= nil and bufferedaction.distance >= math.huge then
--★ 客户端「无穷远即瞬时」用 Preview，服务端（954 行）用 Push ——
--   除执行端不同外，两分支的判定顺序与客户端版（841-879）完全一致。
            --essentially instant
			self:FaceMovePoint(bufferedaction.target.Transform:GetWorldPosition())
            self.inst:PushBufferedAction(bufferedaction)
        else
--★★ 最后一个「走过去执行」的分支 —— 服务端版的兜底 GoToEntity。
--   ★ 三个 GoToEntity 调用点：919（LOOKAT 走近看）、921、959（常规）。
            self:GoToEntity(bufferedaction.target, bufferedaction, run)
        end
--★ 无 action_pos 且无 target → 目标「不可达」，直接执行（等价于原地执行）。
--   ★ 与客户端版 861 行完全对称。
    elseif action_pos == nil then
        self.inst:PushBufferedAction(bufferedaction)
--★ CASTAOE 分支：与客户端版 863 行对称，但执行端为 Push。
    elseif bufferedaction.action == ACTIONS.CASTAOE then
--★★ 距离平方比较（AOE 范围判定）与客户端版逐字符相同 ——
--   再次印证「判定逻辑必须两端一致」这条铁律。
        if self.inst:GetDistanceSqToPoint(action_pos) <= bufferedaction.distance * bufferedaction.distance then
			self:FaceMovePoint(action_pos:Get())
            self.inst:PushBufferedAction(bufferedaction)
        else
--★ 服务端版同样在「走向 AOE 施法点」时派发 bufferedcastaoe 事件。
            self:GoToPoint(nil, bufferedaction, run)
            if self.bufferedaction == bufferedaction then
                self.inst:PushEvent("bufferedcastaoe", bufferedaction)
            end
        end
--★ 与 845/846 行的 instant 判定对称的「无穷远即瞬时」。
    elseif bufferedaction.distance ~= nil and bufferedaction.distance >= math.huge then
        --essentially instant
		self:FaceMovePoint(action_pos:Get())
        self.inst:PushBufferedAction(bufferedaction)
--★★ PushAction 的最终兜底：GoToPoint。
--   ★ 走到这里意味着：动作既不是瞬时、又没有实体目标、
--     但有 action_pos —— 只能走向那个坐标点。
    else
        self:GoToPoint(nil, bufferedaction, run)
    end
end

--★★★★★【GoToEntity：走向一个实体】
--   这是 locomotor 最重要的公开入口。调用方遍布：
--   brain（AI 决策）、stategraph（状态迁移）、
--   playercontroller（玩家点击）、componentactions（各种动作）。
--   ---- 完整流程 ----
--   ① 建 Dest、设 throttle、取消客户端预测计时
--   ② 设置缓冲动作与前进意图
--   ③ **计算 arrive_dist（三分支，见下）**
--   ④ directdrive ? 直推 : FindPath 寻路
--   ⑤ 启动每帧更新
--   ⑥ 若不在 moving 状态，立刻做一次到达检查（见 1034 行）
--★ 参见 components/bufferedaction.lua 与 componentactions.lua ——
--   bufferedaction.arrivedist / distance / action.mindistance /
--   action.extra_arrive_dist / action.skip_locomotor_facing 等字段
--   全部由动作定义侧提供。
--   参见 componentactions.lua 的 RegisterComponentActions（组件动作注册）。
function LocoMotor:GoToEntity(target, bufferedaction, run)
    self.dest = Dest(target)
    self.throttle = 1

--★ 取消客户端预测计时：走到这里说明是服务端路径（或客户端没在预测）。
    self:CancelPredictMoveTimer() --if we reach here, means client is not predicting

    self:SetBufferedAction(bufferedaction)
    self.wantstomoveforward = true

--★★★【arrive_dist 的三分支 —— 「走多近算到达」的决定性逻辑】
--   分支 1：bufferedaction.arrivedist 显式指定 → 直接用（最优先）
--   分支 2：有 bufferedaction.distance →
--     ARRIVE_STEP + 双方物理半径，再与 distance 取 max
--   分支 3：都没有 →
--     ARRIVE_STEP + 双方物理半径(0)，再叠加 action.extra_arrive_dist 与 mindistance
--   ★★★ 为什么半径之和是必需的？
--     因为「到达」的判定是**中心点距离**（1469 行的 distsq），
--     两实体各有半径 r1、r2 时，边缘刚好接触对应中心距 r1+r2。
--     不加半径就会「贴脸才算到达」，玩家会觉得「明明碰到了却还在走」。
--   ★ 分支 2 的 `math.max` 是防御：若 distance 比半径和小（近距离动作），
--     取半径和作为下限，保证「至少不撞上」。
    local arrive_dist

    if bufferedaction ~= nil and bufferedaction.arrivedist ~= nil then
        arrive_dist = bufferedaction.arrivedist

    elseif bufferedaction ~= nil and bufferedaction.distance ~= nil then
--★★★【英文原注释解释了一个历史包袱】
--   "use actual physics (ignoring physicsradiusoverride) as fallback
--    if bufferedaction.distance is too small"
--   ★ 物理半径有两种：实际的（Physics:GetRadius）与覆写的
--     （physicsradiusoverride，某些 prefab 为视觉放大而缩小碰撞体）。
--     这里**故意用实际的**，作为 distance 太小时的兜底。
--   ★ 这行注释的价值：说明「用哪个半径」是深思熟虑的结果，不是随手写的。
        --NOTE: use actual physics (ignoring physicsradiusoverride)
        --      as fallback if bufferedaction.distance is too small
		local owner = target.components.inventoryitem and target.components.inventoryitem:GetGrandOwner() or target
--★ GetGrandOwner：物品在被背包里时要算「最外层主人」（如船上的箱子里的物品）。
		arrive_dist = ARRIVE_STEP + (owner.Physics and owner.Physics:GetRadius() or 0) + self.inst.Physics:GetRadius()
        arrive_dist = math.max(arrive_dist, bufferedaction.distance)

    else
		local owner = target.components.inventoryitem and target.components.inventoryitem:GetGrandOwner() or target
--★ GetPhysicsRadius(0) 带参数 0 —— 见 entityscript.lua 的实现，
--   参数用于指定「取哪个实体的半径」（0 = 自己）。
		arrive_dist = ARRIVE_STEP + owner:GetPhysicsRadius(0) + self.inst:GetPhysicsRadius(0)

--★★【extra_arrive_dist 钩子：让动作自定义「额外接近距离」】
--   典型用途：长柄武器需要更靠近（挥击范围），钩爪需要更远。
--   ★ 是函数调用形式，允许按参数动态计算。
        local extra_arrive_dist = (bufferedaction ~= nil and bufferedaction.action ~= nil and bufferedaction.action.extra_arrive_dist) or nil
        if extra_arrive_dist ~= nil then
            arrive_dist = arrive_dist + extra_arrive_dist(self.inst, self.dest, bufferedaction, arrive_dist)
        end

--★ mindistance：动作的「最小接近距离」下限，防止某些动作贴太近反而失败。
        if bufferedaction ~= nil and bufferedaction.action.mindistance ~= nil and bufferedaction.action.mindistance > arrive_dist then
            arrive_dist = bufferedaction.action.mindistance
        end
    end

    self.arrive_dist = arrive_dist

--★★【directdrive：绕过寻路的直推模式】
--   ★ 用于「直走」场景（如玩家 WASD 移动、脚本驱动的直线移动）。
--     直推不寻路，直接给 motor 速度，靠物理碰撞自然阻挡。
--   ★ 与 FindPath 的对比：直推简单但会被墙卡住，寻路能绕。
    if self.directdrive then
        if run then
            self:RunForward()
        else
            self:WalkForward()
        end
    else
        self:FindPath()
    end

--★ wantstorun 在寻路**之后**才设 —— 顺序微妙：FindPath 不关心跑/走。
    self.wantstorun = run
    --self.arrive_step_dist = ARRIVE_STEP
--★ StartUpdatingInternal：没有它就不会有转向、到达判定、跳跃。
    self:StartUpdatingInternal()

--★★★【★ 立即到达检查：解决「原地已到位却还在走」的经典问题】
--   `if not (self.inst.sg and self.inst.sg:HasStateTag("moving")) then self:OnUpdate(0, true)`
--   ★★ 问题场景：玩家在原地点击一个就在脚下的物品 ——
--     GoToEntity 启动更新后，要等**下一帧** OnUpdate 才会做到达判定，
--     期间实体已经开始移动 → 玩家看到「点了一下却先跑开再回来」。
--   ★ 解法：立刻调一次 OnUpdate(0, true)，用 dt=0 且 arrive_check_only=true
--     只做到达判定、不做移动决策。
--   ★★★ `arrive_check_only` 这个第二参数是本文件的一个小设计亮点：
--     让「检查到达」与「执行移动」可以在同一段代码里复用而不混淆副作用。
	--Try instant arrive check if we're not moving
	if not (self.inst.sg and self.inst.sg:HasStateTag("moving")) then
--★ OnUpdate(0, true)：dt=0 保证不做移动积分，arrive_check_only 保证不改状态。
		self:OnUpdate(0, true)
	end
end

--V2C: Added overridedest for additional network controller support
--★★★【GoToPoint：走向一个坐标点】
--   结构与 GoToEntity 平行，差异只有 arrive_dist 的计算（更简单）：
--     有 bufferedaction → arrivedist or distance or max(mindistance, ARRIVE_STEP)
--     无 bufferedaction → ARRIVE_STEP
--   ★★ 少了两步：不用算双方物理半径（点没有半径）、
--     不用 GetGrandOwner。
function LocoMotor:GoToPoint(pt, bufferedaction, run, overridedest)
--★ overridedest：允许「真正目的地是另一个实体，但立即触发点是坐标」。
--   ★ 用途：点击物品的某个部位时，pt 是点击点，overridedest 是那个实体。
    self.dest = Dest(overridedest, pt, bufferedaction)
    self.throttle = 1

    self:CancelPredictMoveTimer() --if we reach here, means client is not predicting

--★ arrive_dist 的 or 链：`arrivedist or distance or max(mindistance, ARRIVE_STEP)`
--   ★ 优先级：显式 arrivedist > 动作距离 > 动作最小距离 > 基准步长。
    self.arrive_dist =
        bufferedaction ~= nil
        and (bufferedaction.arrivedist or bufferedaction.distance or math.max(bufferedaction.action.mindistance or 0, ARRIVE_STEP))
        or ARRIVE_STEP

--★ extra_arrive_dist 同样适用（1053 行调用时只传 3 个参数，与 1009 行不同）。
--   ⚠ 注意签名差异：1009 行传 4 个参数（含 arrive_dist），1053 行传 3 个。
--     模组实现 extra_arrive_dist 时需容忍参数个数变化。
    local extra_arrive_dist = (bufferedaction ~= nil and bufferedaction.action ~= nil and bufferedaction.action.extra_arrive_dist) or nil
    if extra_arrive_dist ~= nil then
        self.arrive_dist = self.arrive_dist + extra_arrive_dist(self.inst, self.dest, bufferedaction)
    end

    --self.arrive_step_dist = ARRIVE_STEP
    self.wantstorun = run

--★ directdrive 分支与 GoToEntity 相同。
    if self.directdrive then
        if run then
            self:RunForward()
        else
            self:WalkForward()
        end
    else
        self:FindPath()
    end
--★ 注意这里 wantstomoveforward 设**在** FindPath 之后（与 GoToEntity 的 1029 行对称）。
    self.wantstomoveforward = true
    self:SetBufferedAction(bufferedaction)
    self:StartUpdatingInternal()

	--Try instant arrive check if we're not moving
--★ 同样的「立即到达检查」—— 1033 行的机制在此复用。
	if not (self.inst.sg and self.inst.sg:HasStateTag("moving")) then
		self:OnUpdate(0, true)
	end
end

--★★★【SetBufferedAction：换动作时必须 Fail 掉旧的】
--   ★★ 核心契约：**替换即作废**。
--     旧动作的 Fail 会通知上层「这个动作没做成」，
--     让 UI / 状态图能恢复（比如取消施法进度条、退出施法状态）。
--   ★ 若不 Fail 旧动作：玩家点了 A 又点 B，A 会永远「悬挂」在状态图里。
--   ★★ 1063 行的 1512 `self.bufferedaction = nil --so it doesn't get Failed at Clear()`
--     正是为了配合这个契约：到达目的地时先把动作取出（避免被 Fail），再执行。
function LocoMotor:SetBufferedAction(act)
--★ Fail 旧动作 —— 只有旧动作非 nil 才需要（1078 行已判空，这里不判也无害）。
    if self.bufferedaction ~= nil then
        self.bufferedaction:Fail()
    end
    self.bufferedaction = act
--★★ allow_platform_hopping 开启时，重置 last_platform_visited。
--   ★★★ 语义：「允许跨平台跳跃」的移动中，
--     **不允许跳回刚离开的那块平台**（1257 行的判定）。
--     每次接新动作就重置这个「记忆」，让新的一次移动可以跳任何平台。
--   ★ 否则连续做两个动作时，第二个动作会因「记得第一块平台」而拒绝跳跃。
    if self.allow_platform_hopping then
        self.last_platform_visited = INVALID_PLATFORM_ID
    end
--★ 通知 playercontroller 有新动作 —— 用于客户端预测/重复动作的协调。
	if act ~= nil and self.inst.components.playercontroller ~= nil then
		self.inst.components.playercontroller:OnLocomotorBufferedAction(act)
	end
end

--★★★【Stop：完整的移动终止】
--   ★★ 清理清单（比 Clear 更彻底）：
--     · isrunning = false
--     · dest = nil（清目标）
--     · ResetPath()（清路径 + 杀搜索）
--     · lastdesttile = nil（清寻路去重缓存）
--     · wantstomoveforward / wantstorun = false
--     · 物理停止（除非状态图接管）
--     · 派发 "locomote" 事件（通知状态图停下）
--     · StopUpdatingInternal（退出每帧更新）
--   ★★ 注意：**没有** SetBufferedAction(nil) —— 1100 行有注释掉的调用。
--     意味着 Stop 不会 Fail 缓冲动作。有些场景（如到达目的地后）
--     确实不该 Fail（动作已经执行了），有些场景需要外部显式清理。
--     ★ 这个「留白」是刻意的：Stop 负责「停止移动」，
--       不负责「取消动作」—— 两者是不同维度的事。
function LocoMotor:Stop(sgparams)
    --Print(VERBOSITY.DEBUG, "LocoMotor:Stop", self.inst.prefab)
    self.isrunning = false
    self.dest = nil
    self:ResetPath()
    self.lastdesttile = nil
    --self.arrive_step_dist = 0

    --self:SetBufferedAction(nil)
    self.wantstomoveforward = false
    self.wantstorun = false

--★★★【softstop 状态标签：把停止物理的权限交给状态图】
--   `if self.softstop and self.inst.sg and self.inst.sg:HasStateTag("softstop")`
--   ★★ softstop 状态（如玩家「转身」动画）需要**自己控制物理停止时机**，
--     以便播出减速/刹车的动画。若 locomotor 直接 Physics:Stop()，
--     状态图就失去了控制权。
--   ★ 所以这里只清逻辑，不动物理，注释明确写了「Let stategraph handle stopping physics」。
--   ⚠ 注意 1104 行在这个分支里重复设了 isrunning=false（外层 1093 已经设过）——
--     冗余但无害。
    if self.softstop and self.inst.sg ~= nil and self.inst.sg:HasStateTag("softstop") then
        self.isrunning = false
        --Let stategraph handle stopping physics
        --self.inst.Physics:Stop()
    else
--★ 非 softstop 分支：正常路径 —— 停计时器 + 停物理。
        self:StopMoveTimerInternal()
        self:StopMoving()
    end

--★★★【PushEvent("locomote") —— locomotor 与状态图之间的核心契约】
--   ★★ 状态图监听 "locomote" 来进入 walk / run 状态。
--     所以「移动意图」与「移动状态」是**双向握手**：
--       locomotor → PushEvent("locomote") → 状态图进入 moving
--       状态图 → HasStateTag("moving") → locomotor 决定是否继续 locomote（1643 行）
--   ★ sgparams 透传给状态图，供其区分停止原因。
--★★★ 参见 stategraphs/commonstates.lua 的 walk / run 状态 ——
--   它们监听 "locomote" 事件进入移动状态。
--   参见 stategraphs/commonstates.lua:768 的 onhop 事件处理器（跳跃）。
--   commonstates.lua:797 的 tags 里含 "jumping" 与 "autopredict"，
--   后者正是 108 行 ClientRunSpeed 里检查的 tag。
    self.inst:PushEvent("locomote", sgparams)
--★ 退出每帧更新 —— 若不退出，静止实体会被无谓遍历。
    self:StopUpdatingInternal()
end

--★★★【WalkInDirection：朝指定方向走（无目标点）】
--   ★ 与 GoToPoint 的关键区别：**没有目的地**。
--     所以不走寻路（除非 directdrive），只靠 motor 速度 + 物理碰撞。
--   ★ 典型调用方：玩家 WASD 输入、AI 的「朝某方向逃跑」、远程攻击的后摇走位。
--   ★★ 仍然要 ResetPath：清掉「上一个目标的路径」，
--     否则 OnUpdate 里的路径跟随代码会继续按旧路径转向。
function LocoMotor:WalkInDirection(direction, should_run)
    --Print(VERBOSITY.DEBUG, "LocoMotor:WalkInDirection ", self.inst.prefab)
    self:SetBufferedAction(nil)
	self.dest = nil
	self:ResetPath()
	self.lastdesttile = nil

--★★★【canrotate 标签：状态图可以禁止转向】
--   `if not self.inst.sg or self.inst.sg:HasStateTag("canrotate") then SetMoveDir`
--   ★★ 语义：状态图处于「正在做事」（如挖矿挥动）时不该转身，
--     因为转身会让动画与朝向脱节。
--   ★ 注意条件里有 `not self.inst.sg` —— 无状态图的实体（如物品、球体）总是可转向。
--   ⚠ 与 1610 行的同类检查对比：那里是 `canrotate and not HasStateTag("busy")`，
--     两处的 canrotate 语义有细微差异（busy 是 canrotate 的超集还是子集？
--     取决于各状态图的标签定义）。
    if not self.inst.sg or self.inst.sg:HasStateTag("canrotate") then
		self:SetMoveDir(direction)
    end

    self.wantstomoveforward = true
    self.wantstorun = should_run

    if self.directdrive then
		if should_run then
			self:RunForward()
		else
			self:WalkForward()
		end
    end
--★★ pusheventwithdirection 时把方向塞进事件数据（见 341 行注释的设计动机）。
	self.inst:PushEvent("locomote", self.pusheventwithdirection and { dir = direction } or nil)
    self:StartUpdatingInternal()
end

--★ RunInDirection = WalkInDirection + 节流。throttle 为 nil 时默认 1。
function LocoMotor:RunInDirection(direction, throttle)
    --Print(VERBOSITY.DEBUG, "LocoMotor:RunInDirection ", self.inst.prefab)

    self.throttle = throttle or 1
	self:WalkInDirection(direction, true)
end

--★★★【GetDebugString：调试模式下的移动诊断】
--   ★ 输出：跑/走状态、目标速度、目的地、缓冲动作、
--     地图地块坐标、寻路地块索引、arrive_step_dist。
--   ★★ 「地图地块坐标」与「寻路地块索引」是两套不同坐标系：
--     前者来自 TheWorld.Map:GetTileCoordsAtPoint（渲染/世界网格），
--     后者来自 TheWorld.Pathfinder:GetPathTileIndexFromPoint（A* 寻路网格）。
--     ★ 这两套网格的分辨率不同（寻路网格更粗），
--       正是 1832 行 lastdesttile 存在的原因 —— 寻路去重必须在寻路网格上做。
function LocoMotor:GetDebugString()
    local pathtile_x = -1
    local pathtile_y = -1
    local tile_x = -1
    local tile_y = -1
    local ground = TheWorld
    if ground then
        pathtile_x, pathtile_y = ground.Pathfinder:GetPathTileIndexFromPoint(self.inst.Transform:GetWorldPosition())
        tile_x, tile_y = ground.Map:GetTileCoordsAtPoint(self.inst.Transform:GetWorldPosition())
    end
    local state = self.wantstorun and "RUN" or "WALK"
    return string.format("%s, (%0.2f) [%s] [%s] (%u, %u):(%u, %u) +/-%2.2f", state, self.wantstorun and self:GetRunSpeed() or self:GetWalkSpeed(), tostring(self.dest), tostring(self.bufferedaction), tile_x, tile_y, pathtile_x, pathtile_y, self.arrive_step_dist or 0)
end

--★ HasDestination：外部查询「当前是否有目标」。空检查即可（Dest:IsValid 由 OnUpdate 负责）。
function LocoMotor:HasDestination()
    return self.dest ~= nil
end

--★ SetShouldRun：外部可改「跑还是走」（如体力不足时改为走）。
function LocoMotor:SetShouldRun(should_run)
    self.wantstorun = should_run
end

--★ WantsToRun / WantsToMoveForward：状态图与 AI 查询移动意图的接口。
function LocoMotor:WantsToRun()
    return self.wantstorun == true
end

function LocoMotor:WantsToMoveForward()
    return self.wantstomoveforward == true
end

--★★★【WaitingForPathSearch：返回搜索句柄本身（不是布尔）】
--   `return self.path and self.path.handle`
--   ★★ 三个返回值场景：
--     · 没有 path → nil（假）
--     · 有 path 但无 handle（搜索已结束或已取结果）→ nil（假）
--     · 有 path 且有 handle → 数字句柄（真）
--   ★ 返回句柄而非 true，是为了 774/1559 行能直接拿它去 KillSearch。
function LocoMotor:WaitingForPathSearch()
    return self.path and self.path.handle
end

--⚠【已废弃的 UpdateHopping（函数体全被注释）】
--   跳跃机制从「每帧更新跳跃状态」改为「事件驱动 + 状态图 jumping 状态」。
--   ★ 保留空壳是为了不炸调用它的模组。
function LocoMotor:UpdateHopping(dt) -- deprecated
    --self.inst.Physics:Stop()
end

--★★★【FinishHopping：跳跃结束，释放平台预约】
--   ★★ 平台预约（reservation）机制：
--     跳跃前 TryToReservePlatform 占用目标平台（1702 行），
--     防止两个实体同时跳向同一个平台导致「挤在平台边缘」。
--     跳跃结束后必须释放 —— 若忘了，多人同跳场景下会出现「平台永远被占满」。
--   ★ 1191 行的双重检查：只有「我当前所在平台 ≠ 我预约的平台」才需要释放
--     （说明我可能没跳成功）。
function LocoMotor:FinishHopping()
    self.hopping = false

    if self.reserved_platform then
        local my_platform = self.inst:GetCurrentPlatform()
        if my_platform ~= self.reserved_platform then
            if self.reserved_platform.TryToClearReservedPlatform then
				self.reserved_platform:TryToClearReservedPlatform(self.inst)
            end
        end
        self.reserved_platform = nil
    end
end

--★★【SetAllowPlatformHopping：是否允许跨平台跳跃】
--   开启时也重置 last_platform_visited（与 1083 行同款初始化）。
--   ★★ 这个开关会通过 FindPath:1796 间接影响寻路能力
--     （AdjustPathCaps("allowplatformhopping")），即「寻路时能否跨水面」。
function LocoMotor:SetAllowPlatformHopping(enabled)
    self.allow_platform_hopping = enabled
    if enabled then
        self.last_platform_visited = INVALID_PLATFORM_ID
    end
end

--★★★【CheckEdge：判断「前方是否已无落脚点」】
--   采样点 = 当前位置 + 方向 × radius（物理半径）。
--   `is_water = not map:IsVisualGroundAtPoint(pt_x, 0, pt_z)` ——
--   ★ 「视觉地面」判定：不是查地形层，而是查「有没有可站立的实体」。
--     这正是**平台系统**与**地形系统**的统一抽象层：
--     船、浮冰、吊桥、树桩都算「有地面」，而海水不算。
--   返回 true 的两种情况：
--     ① 采样点是水且没有平台 → 前方无路
--     ② 采样点的平台 ≠ 我当前平台 → 平台边界
--   ★★ 这是整个跳跃检测的基石：把「边缘」定义为「脚下地面类型改变」。
--★★ 参见 components/walkableplatform.lua —— IsFull / player_only / no_mounts
--   / max_hop_distance 都定义在该组件的构造里（walkableplatform.lua:1-15）。
--   平台的注册与容量统计在 components/walkableplatformmanager.lua。
function LocoMotor:CheckEdge(my_platform, map, my_x, my_z, dir_x, dir_z, radius)
    local pt_x, pt_z = my_x + dir_x * radius, my_z + dir_z * radius
    local platform = map:GetPlatformAtPoint(pt_x, pt_z)
    local is_water = not map:IsVisualGroundAtPoint(pt_x, 0, pt_z)
    return (is_water and platform == nil) or platform ~= my_platform
end

--★★★【IsAtEdge：三点采样防抖】
--   用 radius - 0.25 / radius / radius + 0.25 三个半径各采一次，任一为真即在边缘。
--   ★★★ 为什么要三点？
--     · 只用 radius：物理体已经压边了才触发，玩家会「悬空半步」
--     · 只用 radius+0.25：太早触发，站着不动也会被判为「在边缘」
--     · 三点：覆盖「刚压边 / 正压边 / 刚离开」三个阶段，任一命中即触发
--   ★ 这是一个「扩大判定范围」的经典技巧 ——
--     用多个偏移采样代替「加个 margin 参数」。
function LocoMotor:IsAtEdge(my_platform, map, my_x, my_z, dir_x, dir_z)
    local radius = self.inst.Physics:GetRadius()
--★ edge_range = 0.25 —— 采样偏移量。与跳跃距离 6.0 相比很小，
--   说明三点采样覆盖的区间只有 0.5 格，靠的是「时间上连续多帧」而非「空间上很大」。
    local edge_range = 0.25
    return self:CheckEdge(my_platform, map, my_x, my_z, dir_x, dir_z, radius) or
           self:CheckEdge(my_platform, map, my_x, my_z, dir_x, dir_z, radius - edge_range) or
           self:CheckEdge(my_platform, map, my_x, my_z, dir_x, dir_z, radius + edge_range)
end

--★ GetHopDistance：优先用 hop_distance_fn 钩子，否则用固定值。
--   ★★ 传 speed_mult 参数（1664 行调用）——
--     设计上允许「速度越快跳越远」，但当前实现不传也能工作。
function LocoMotor:GetHopDistance(speed_mult)
	return self.hop_distance_fn ~= nil and self.hop_distance_fn(self.inst, speed_mult or 1) or self.hop_distance
end

--★★★★★【IsValidDestinationPlatform：目标平台的四道准入检查】
--   ① 目标 == 当前平台 → 有效（不需要跳）
--   ② walkableplatform.player_only 且我不是玩家 → 无效
--      ★ 典型：玩家专属的移动平台（某些剧情平台）
--   ③ walkableplatform.no_mounts 且我骑着东西 → 无效
--      ★ 典型：只能步行的窄桥，骑马过去会掉下去
--   ④ 容量已满 → 无效（见下）
--   ★★ 关键：第 ③ 条用 `self.inst.replica.rider` 判定骑乘——
--     ★★ 这是一个**在服务端也用 replica 的地方**！
--       推理依据：master sim 上 inst.replica 通常为 nil，
--       所以 `rider and rider:IsRiding()` 恒为 false，
--       即服务端**永远不会**因「骑乘中」而拒绝跳跃。
--     ⚠ 若某个 prefab 在服务端也给 inst 赋了 replica.rider，
--       行为会与客户端不一致。这是「双端不对称」的潜在 bug 点，
--       修复方式是像 ServerRunSpeed 那样用 components.rider。
--   ★★ 第 ④ 条也是双端分派的：服务端用 IsFull()（真值），
--     客户端用 HasTag("walkableplatform_full")（网络可见的快照）。
--     参见 components/walkableplatform.lua 的 IsFull 与对应 tag 写入。
--   ⚠ 1241 行客户端版：`not dest_platform:HasTag(...)` ——
--     若 dest_platform 为 nil 会崩，但调用方（1680/1689）已判空。
--★★ 参见 components/walkableplatform.lua:44 的 RemovePlatformFollower 配对流程，
--   以及 walkableplatformmanager.lua 的 RegisterPlatform / AddPlatform。
--   ★ 1241 行的 "walkableplatform_full" tag 由 walkableplatform 组件写入，
--     是「容量已满」这一状态的跨端快照。
function LocoMotor:IsValidDestinationPlatform(my_platform, dest_platform)
	if dest_platform == my_platform then
		return true
--★ no_mounts 检查用 replica.rider —— 见上方分析，这是双端不对称点。
	elseif dest_platform.components.walkableplatform.player_only and not self.inst.isplayer then
		return false
--★ walkableplatform 组件保证存在（能拿到平台的实体都有这个组件）。
	elseif dest_platform.components.walkableplatform.no_mounts then
		local rider = self.inst.replica.rider
		if rider and rider:IsRiding() then
			return false
		end
	end

--★ 服务端：查真实容量（IsFull 由 walkableplatformmanager 维护）。
	if self.ismastersim then
		return not dest_platform.components.walkableplatform:IsFull()
	end
	return not dest_platform:HasTag("walkableplatform_full")
end

--★ WALL_TAGS —— 跳跃时需要避让的「墙类」实体标签。
--   ★ 只有 wall 标签：其他有物理的障碍（如栅栏 gate）不阻挡跳跃。
local WALL_TAGS = { "wall" }
--★★★【ScanForPlatformInDir_Internal 签名解释】
--   steps        —— 常规扫描步数
--   steps_to_land—— 从「悬浮位置」跳向陆地时的额外扫描步数（可大于 steps）
--   step_size    —— 每步的距离
--   nodelay      —— 跳过跳跃延迟机制
--   from_floating—— 是否处于「悬浮」（无平台）状态
--   ★★ steps_to_land 的存在是为了解决「站在船边跳到岸上比跳到船上远」
--     的不对称：跳向陆地时要多扫几步找可落脚的点。
--steps_to_land is optional: used when hopping from floating, to scan a bit further for land
--★ 本函数是跳跃检测的**唯一实现**，另外两个 ScanForPlatformInDir* 都是它的包装。
function LocoMotor:ScanForPlatformInDir_Internal(my_platform, map, my_x, my_z, dir_x, dir_z, steps, steps_to_land, step_size, nodelay, from_floating)
--★ is_first_hop_point：跳过第一个采样点的返回（见 1322 行）——
--   因为第一个采样点通常就是脚下的位置，返回它等于「不跳」。
    local is_first_hop_point = true
--★★★【`for i = 1, steps_to_land or steps` —— 扫描步数取决于出发点】
--   ★ 站在平台上 → 扫 steps 步
--   ★ 悬浮在空中 → 扫 steps_to_land 步（更多）
--   ★★ 注意：Lua 的 `for i = 1, steps_to_land` 中，
--     若 steps_to_land 是浮点数，循环会向上取整（实际是 i <= steps_to_land）。
--     1367 行的 step_count 就是浮点数（(dist+1)/0.5），所以这里有隐式取整。
	for i = 1, steps_to_land or steps do
        local pt_x, pt_z = my_x + dir_x * i * step_size, my_z + dir_z * i * step_size
        local platform = map:GetPlatformAtPoint(pt_x, pt_z)
--★ 平台无效则当不存在（置 nil）—— 后续判定会自然落到「有地面但没平台」。
		if platform and not self:IsValidDestinationPlatform(my_platform, platform) then
			platform = nil
		end

--★★★【英文原注释解释了一个手感问题】
--   "prevent jumping back onto the same platform because if you click an action
--    and land near the edge of a platform you would sometimes turn around
--    and jump right back"
--   ★★ 场景还原：玩家站在船边点击岸上的箱子 → 跳过去 →
--     落点离船边很近 → 检测到船也在范围内 → 判定为「可以跳回船」→
--     实体转身又跳回船上 → 玩家看到「莫名其妙的往返跳」。
--   ★ 解法：记住 last_platform_visited（1714 行设置），本次移动中不跳回它。
        -- prevent jumping back onto the same platform because if you click an action and land near the edge of a platform
        -- you would sometimes turn around and jump right back
--★ from_floating 时无条件放行（悬浮状态没有「来路平台」可记忆）。
		if from_floating or not (self.last_platform_visited == platform) then
--★ is_water：脚下无实体（无地面）判定，与 CheckEdge:1210 同款。
            local is_water = not map:IsVisualGroundAtPoint(pt_x, 0, pt_z)
            if not is_water then
--★★★【跳跃前的障碍物检查：扫「有物理的墙」】
--   `TheSim:FindEntities(整格坐标, 0, 整格坐标, 半径1, WALL_TAGS)`
--   ★★ FindEntities 用**整数格坐标**（math.floor）——
--     因为 TheSim 的空间索引是格哈希，浮点会落到错误的桶。
--   四个额外条件：
--     · v ~= self.inst —— 排除自己
--     · v.entity:IsVisible() —— 不可见的不阻挡（隐藏的墙不该挡路）
--     · v.components.placer == nil —— 「放置预览」状态的实体不阻挡
--       ★ 这是建造模式的关键：正在放置的墙不该阻止角色跳过去
--     · v.entity:GetParent() == nil —— 被拿在手里的不阻挡（子实体）
--     · v.Physics:IsActive() —— 物理未激活的不阻挡
--   ★ 找到任一则返回 (false, 0, 0, nil) —— 即「不跳」。
--   ⚠ 性能：每帧可能对多个采样点做 FindEntities。
--     优化靠 1438 行的 lastpos 缓存（只有跨格才进 OnUpdate 深处）。
                --search for nearby walls and fences with active physics.
--★ math.floor 是必须的：TheSim 的空间哈希只认整数格。
                for _, v in ipairs(TheSim:FindEntities(math.floor(pt_x), 0, math.floor(pt_z), 1, WALL_TAGS)) do
                    if v ~= self.inst and
                    v.entity:IsVisible() and
--★ placer 组件：正在被放置的实体（有预览幽灵时存在）。
                    v.components.placer == nil and
                    v.entity:GetParent() == nil and
                    v.Physics:IsActive() then
                        return false, 0, 0, nil
                    end
                end
            end
			--print(i, my_platform, platform, pt_x - my_x, pt_z - my_z, is_water, step_size)
--★★★【跳跃成立的两个必要条件（用 and 连接）】
--   `from_floating or (platform ~= my_platform and (i <= steps or platform == nil))`
--   ① 目标是不同的平台（platform ~= my_platform）
--   ② i <= steps（常规范围内）**或** 目标是 nil（没平台但有地面）
--   ★★ 条件 ② 的 `or platform == nil` 是「悬浮跳向陆地」的放宽：
--     即使扫超出了 steps 步，只要那点有地面（不是水）也算数。
--   ★ 括号位置很关键：`platform ~= my_platform and (i <= steps or ...)`
--     —— or 的优先级高于 and，必须显式加括号。
--   ⚠ 移植到强类型语言时，Lua 的运算符优先级差异是最容易出错的地方。
			if from_floating or platform ~= my_platform and
				(i <= steps or platform == nil) --extra distance when jumping to land from floating
			then
--★ `platform ~= nil or not is_water` —— 有平台，或有地面（陆地）。
                if platform ~= nil or not is_water then
--★★★【跳跃延迟机制：防止「贴着边缘狂点方向键连跳」】
--   条件：hop_delay 存在 + 没有目标（dest == nil，即纯方向移动） + 未 nodelay。
--   ★★ 为什么只在「无目标的方向移动」时延迟？
--     因为「点击某个东西走过去」是**明确的用户意图**，不该延迟；
--     而「按住方向键」是持续的输入，可能只是「站在船边想靠岸」——
--     若立刻跳船，玩家会觉得「误跳」。
--   ★ 延迟时长按情况分三档（见 1280-1287 行）。
					if self.hop_delay and self.dest == nil and not nodelay then
						--keep pushing toward the same direction during the delay before the hop is actually triggered
						local delay
--★★【延迟时长三档】
--   ① 目标是水（跳向船）→ TUNING.PLATFORM_FLOATING_HOP_DELAY_TICKS = 4
--   ② 目标是陆地 → 取「源平台与目标平台的 platformhopdelay 的较大者」，
--      若为 0 则用 TUNING.PLATFORM_HOP_DELAY_TICKS = 8
--   ③ forced_platformhopdelay（实体级强制值，可被剧情设置）
--   ★★ 跳向水比跳向陆地的延迟**更短**（4 < 8）：
--     因为「跳上船」是常见且期待的操作，延迟长了很烦人；
--     「跳离船去找岸」误触成本更高，所以延迟更长。
--   ★ 平台级可配（components/platformhopdelay.lua）——
--     某些平台（如需要「蓄力」的吊桥）可以要求更长延迟。
						if is_water then
							delay = self.inst.forced_platformhopdelay or TUNING.PLATFORM_FLOATING_HOP_DELAY_TICKS
						else
							local platform_delay = math.max(
--★ platformhopdelay 组件：平台级的跳跃延迟配置（可选组件）。
								platform and platform.components.platformhopdelay and platform.components.platformhopdelay:GetDelayTicks() or 0,
								my_platform and my_platform.components.platformhopdelay and my_platform.components.platformhopdelay:GetDelayTicks() or 0
							)
							delay = platform_delay > 0 and platform_delay or self.inst.forced_platformhopdelay or TUNING.PLATFORM_HOP_DELAY_TICKS
						end
--★ delay <= 0 时直接跳过延迟判断（该场景不延迟）。
						if delay > 0 then
							local skip_delay = false
--★★★【skip_delay：三种「不延迟」的情形】
--   ① my_platform.Physics == nil —— 固定平台（如 abysspillar 深海柱）
--      ★ 没有 Physics = 不可移动的平台，跳到它上面不会造成
--        「船突然启动把人甩下去」的意外，延迟就没意义。
--   ② 目标平台与自身平台都静止 —— 船对船的「静态桥」
--      ★ 场景：两艘停着的船刚好靠在一起，可以直接走过去。
--   ③ 例外：boatringdata:IsRotating() —— 旋转中的环形船阵不算静止
--      ★ 即使速度为 0，旋转中的船阵也在动，所以不能跳过延迟。
							if my_platform then
--★ abysspillar（深海柱）—— 固定不动的平台，是这个分支的主要受益者。
								if my_platform.Physics == nil then
									--detect if we are jumping off a fixed platform (e.g. abysspillar)
									skip_delay = true
								elseif platform and platform.Physics then
									--detect boat bridges (only from boat->boat)
									--boatringdata is available on clients!
--★★★【boatringdata 的关键注释】
--   "boatringdata is available on clients!"
--   ★★★ 这条注释解释了为什么这里可以安全地在客户端读这个组件：
--     boatringdata 是**可复制组件**（通过 AddReplicableComponent 注册），
--     所以客户端也有，能参与同样的 skip_delay 判定。
--   ★★ 双端同构的又一个例子：为了让两端跳跃延迟一致，
--     这个判定用到的组件必须是双端可读的。
--★ 参见 components/boatringdata.lua（或 boat 相关组件）——
--   boatringdata 是可复制组件，客户端可读，因此这条判定能双端一致。
									local vx, vy, vz = platform.Physics:GetVelocity()
--★ 三重条件：速度全 0 且不在旋转 → 才算「静止可直连」。
									if vx == 0 and vy == 0 and vz == 0 and not (platform.components.boatringdata and platform.components.boatringdata:IsRotating()) then
										vx, vy, vz = my_platform.Physics:GetVelocity()
										if vx == 0 and vy == 0 and vz == 0 and not (my_platform.components.boatringdata and my_platform.components.boatringdata:IsRotating()) then
											skip_delay = true
										end
									end
								end
							end

							if not skip_delay then
--★★★【延迟计时的核心：starttick 只在「目标或来源变化」或「中断一帧以上」时重置】
--   `if platform ~= toplatform or my_platform ~= fromplatform`
--     `or tick > lasttick + 1 then starttick = tick`
--   ★★★ 语义：玩家必须**持续按住方向键且目标不变**才会计时。
--     · 松开一下再按住（tick 跳 2）→ 重新计时
--     · 目标平台变了（比如船漂走了）→ 重新计时
--   ★ 这是「连续输入确认」的防抖实现 ——
--     防止「点一下方向键松手」被当成「按住」，也防止「连续快速点击」绕过延迟。
								local tick = GetTick()
								if platform ~= self.hop_delay.toplatform or my_platform ~= self.hop_delay.fromplatform or tick > self.hop_delay.lasttick + 1 then
									self.hop_delay.toplatform = platform
									self.hop_delay.fromplatform = my_platform
									self.hop_delay.starttick = tick
								end
								self.hop_delay.lasttick = tick
--★ 计时够了才返回 true（可以跳）。否则返回 false（继续等）。
								if tick - self.hop_delay.starttick < delay then
									return false, 0, 0, nil
								end
							end
						end
					end
                    --print("SUCCESS!")
--★★★【跳过第一个采样点】
--   `if is_first_hop_point then is_first_hop_point = false else return true, ... end`
--   ★★ 为什么？第一个采样点在「脚边 + 一小步」，通常还在当前平台上，
--     返回它等于「原地跳」。跳过它让扫描从「真正离开平台后的第一个点」开始。
                    if is_first_hop_point then
                        is_first_hop_point = false
                    else
                        return true, pt_x, pt_z, platform
                    end
                end
            end
        end
    end
--★ 扫完都没找到 → 不跳。这是正常路径（走到平台边缘但不跳）。
    return false, 0, 0, nil
end

--★★【ScanForPlatformInDir：先判边缘再扫】
--   ★ 短路：不在边缘就不扫（省掉 1246 行那个重循环）。
--   ★ 这是「前置快速筛 + 后置精细判」的标准优化结构。
function LocoMotor:ScanForPlatformInDir(my_platform, map, my_x, my_z, dir_x, dir_z, steps, step_size)
	if self:IsAtEdge(my_platform, map, my_x, my_z, dir_x, dir_z) then
		return self:ScanForPlatformInDir_Internal(my_platform, map, my_x, my_z, dir_x, dir_z, steps, nil, step_size, false, false)
	end
	return false, 0, 0, nil
end

--★ 从悬浮位置扫描：my_platform 传 nil，from_floating 传 true，步数用 steps_to_platform。
function LocoMotor:ScanForPlatformInDirFromFloating(map, my_x, my_z, dir_x, dir_z, steps_to_platform, steps_to_land, step_size, nodelay)
	return self:ScanForPlatformInDir_Internal(nil, map, my_x, my_z, dir_x, dir_z, steps_to_platform, steps_to_land, step_size, nodelay, true)
end

--★★ PLATFORM_SCAN_STEP_SIZE = 0.5 —— 扫描步长（格）。
--   ★ 取 0.5 而非 1.0：0.5 的精度足以捕捉平台边缘，
--     而步数只有 1.0 的一半 —— 精度与开销的折中点。
local PLATFORM_SCAN_STEP_SIZE = 0.5
--★ PLATFORM_SCAN_LANDING_RANGE = 1 —— 落点搜索时额外多扫 1 格。
--   ★ 用途：给「刚好在边缘」留一点余量，避免差几厘米跳不上去的挫败感。
local PLATFORM_SCAN_LANDING_RANGE = 1
--★ BLOCKER_TAGS = {"blocker"} —— TestForBlocked 查的标签。
--   ★ 与 1244 行的 WALL_TAGS 是两套：
--     · WALL_TAGS —— 「跳过去」的障碍（垂直墙）
--     · BLOCKER_TAGS —— 「跳不过去」的障碍（路径封锁）
local BLOCKER_TAGS = {"blocker"}
--★★★【TestForBlocked：路径上是否有阻挡物】
--   与 1260 行的 WALL 检查是**不同用途**：
--     · 1260 行：跳跃落点处有墙 → 不跳
--     · 本函数：跳跃路径上有 blocker → 不跳（1312 行那处调用）
--   ★ step_count 是浮点数：(test_length + 1) / 0.5。
--     for 循环会向上取整，所以实际扫描了 ⌈step_count⌉ 个点。
--   ★ 半径参数 `radius + PLATFORM_SCAN_STEP_SIZE` 让检测范围略宽于实体。
function LocoMotor:TestForBlocked(my_x, my_z, dir_x, dir_z, radius, test_length)
    local step_count = (test_length + PLATFORM_SCAN_LANDING_RANGE) / PLATFORM_SCAN_STEP_SIZE
    for i = 1, step_count do
        local step_amount = i * PLATFORM_SCAN_STEP_SIZE
        local pt_x, pt_z = my_x + dir_x * step_amount, my_z + dir_z * step_amount
--★ 用 FindEntities 查 blocker 标签，命中任一即 return true。
        if #TheSim:FindEntities(pt_x, 0, pt_z, radius + PLATFORM_SCAN_STEP_SIZE, BLOCKER_TAGS) > 0 then
            return true
        end
    end

    return false
end

--★★★【ScanForPlatform：把「向某点跳跃」分解为「定方向 + 定距离」】
--   步骤：
--     ① 算到目标的向量，归一化成方向
--     ② 算距离，钳制到 hop_distance（1367 行）
--     ③ 调 ScanForPlatformInDir 做实际扫描
--   ★★★ 1367 行的钳制是安全关键：
--     `math.min(dir_length + LANDING_RANGE, hop_distance) / STEP_SIZE`
--     若不钳制，远处目标的 step_count 会巨大（几千步）→
--     整个函数在单帧内跑几千次 FindEntities → 卡死。
--     ★ 钳制后步数上限 = (6+1)/0.5 = 14 步，可接受。
function LocoMotor:ScanForPlatform(my_platform, target_x, target_z, hop_distance)
    local my_x, my_y, my_z = self.inst.Transform:GetWorldPosition()
    local dir_x, dir_z = target_x - my_x, target_z - my_z
--★ VecUtil_Length：求向量长度。dir_length 为 0 时（原地跳）会除零得 NaN ——
--   ⚠ 实际不会发生，因为只有「有目标」才走到这里，且目标不会正好在脚下
--     （否则 1034 行的立即到达检查就处理了）。
--★ 参见 math2d.lua / mathutil.lua 的 VecUtil_Length / VecUtil_Normalize。
    local dir_length = VecUtil_Length(dir_x, dir_z)
    dir_x, dir_z = dir_x / dir_length, dir_z / dir_length

--★★★【★ 性能与正确性的双重关键行】双重钳制（见上方说明）。
    local step_count = math.min(dir_length + PLATFORM_SCAN_LANDING_RANGE, hop_distance) / PLATFORM_SCAN_STEP_SIZE

    local can_hop, px, pz, found_platform = self:ScanForPlatformInDir(my_platform, TheWorld.Map, my_x, my_z, dir_x, dir_z, step_count, PLATFORM_SCAN_STEP_SIZE)
--★ blocked 变量现在主要由调用方（1707 行）设置。
    local blocked = false
--⚠【被整块注释掉的「路径通畅性检查」】
--   ★ 这段死代码揭示了一个**被否决的设计**：
--     原本想在跳跃后额外验证「从起点到落点中心」的直线路径是否被 blocker 挡住，
--     挡住就放弃跳跃。
--   ★★ 为什么被注释掉？代码里的注释给出了理由：
--     "Awkwardly, when we hop to platforms, we hop towards the center, despite
--      getting a px/pz that does not reflect that."
--     翻译：跳跃时实际是**朝平台中心**跳的，但 ScanForPlatform 返回的 px/pz
--     是「探测到的落脚点」，两者不一致 —— 用 px/pz 做的阻挡检测
--     测的是一条「实际不会走的线」，结论不可靠。
--   ★ 教训：宁可用一个「可能不准但不误伤」的检查，
--     也不用一个「理论精确但坐标系错位」的检查。
--   ⚠ 遗留问题：blocked 变量（1370 行）现在**恒为 false**，
--     1691 行的 `if other_platform and not IsValidDestinationPlatform ...`
--     里仍会设 blocked = true，1707 行也会设 —— 所以 blocked 并非完全无用，
--     但 1722/1728 行的「if my_platform ~= nil then ScanForPlatform」分支里，
--     blocked 只能来自 ScanForPlatform 的返回值（恒 false）。
    --[[if can_hop then
        -- If we found a place to hop to, we need to check that our path is clear of obstacles.
        local path_x, path_z = px - my_x, pz - my_z

        local p_length = VecUtil_Length(path_x, path_z)

        -- Awkwardly, when we hop to platforms, we hop towards the center, despite getting a px/pz that does not reflect that.
        -- So, we need to quickly calculate the actual center-boat direction to test with.
        local platform_dir_x, platform_dir_z = nil, nil
        if found_platform and found_platform.Transform then
            local platform_x, _, platform_z = found_platform.Transform:GetWorldPosition()
            platform_dir_x, platform_dir_z = VecUtil_Normalize(platform_x - my_x, platform_z - my_z)
        else
            platform_dir_x, platform_dir_z = path_x / p_length, path_z / p_length
        end

        --if self:TestForBlocked(my_x, my_z, platform_dir_x, platform_dir_z, self.inst:GetPhysicsRadius(0), p_length) then
        --    can_hop = false
        --    blocked = true
        --end
    end]]--

--★ 返回 5 个值，blocked 在当前实现下几乎恒 false（见 1371 行的说明）。
    return can_hop, px, pz, found_platform, blocked
end

--★★★【StartHopping：宣告「我要跳了」】
--   ★ 三个作用：
--     ① 通知 embarker 组件（玩家登船/下船的位置记录）
--     ② 置 hopping = true（使 OnUpdate:1425 早退，把控制权交给状态图）
--     ③ 设 0.2 秒跳跃冷却
--★ 参见 components/embarker.lua —— 玩家登船/下船的状态记录与过场。
--   ★ StartHopping 是它唯一的调用方之一。
function LocoMotor:StartHopping(x,z,target_platform)
--★ embarker 组件：玩家专用，负责「从船上岸 / 上船」的过场与重生点。
    local embarker = self.inst.components.embarker
    if embarker ~= nil then
        if target_platform ~= nil then
--★ SetEmbarkable(目标平台) vs SetDisembarkPos(x, z)：
--   跳向平台 → 记平台；跳向陆地 → 记坐标点。
            embarker:SetEmbarkable(target_platform)
        else
            embarker:SetDisembarkPos(x, z)
        end
--★ 已在 jumping 状态则不重复推 onhop —— 防止状态图被重复触发。
--★ 参见 stategraphs/commonstates.lua:771 ——
--   onhop 处理器里同样有 `if not inst.sg:HasStateTag("jumping")` 的守卫，
--   与本行严格配对（避免状态图被重复触发进 jumping）。
        if not self.inst.sg:HasStateTag("jumping") then
            self.inst:PushEvent("onhop")
        end
    end

--★★ hopping = true 是「控制权移交信号」：
--   OnUpdate 开头见到它就直接 return，跳跃期间 locomotor 不做任何决策，
--   完全交给状态图的 jumping 状态 + C++ 物理。
    self.hopping = true

--★★★【英文原注释解释了 0.2 秒冷却的双重目的】
--   ① "to give the server a little bit of time to land it's hop before the
--      client starts hopping again" —— 网络同步延迟保护
--   ② "This also solves an issue where the player controller which polls for
--      hops has time to poll and realize that the first hop is done before the
--      second on starts" —— 轮询式跳跃检测的时序保护
--   ★★ 第 ② 点揭示了「跳跃是轮询驱动的」：
--     playercontroller 靠轮询询问 locomotor「能跳吗」，
--     若两次询问之间跳跃已结束，会误判为「可以连跳」。
--   ★ 0.2 秒 = 6 帧，是「够网络往返 + 够轮询间隔」的保守值。
    -- Don't allow the player to hop for another ~200ms. This is to give the server a little bit of time to land it's hop before the client starts hopping again.
    -- This also solves an issue where the player controller which polls for hops has time to poll and realize that the first hop is done before the second on starts.
    self.time_before_next_hop_is_allowed = 0.2
end

--★ CheckDrownable：落水检查的薄包装。返回 false 表示「不需要游」。
--★★ 参见 components/drownable.lua:364 附近的 CheckDrownable ——
--   落水后由该组件接管移动（浮力、游动、溺水计时）。
--   drownable.lua:378 也有一处 health:DoDelta（溺水扣血，ignore_absorb=true）。
function LocoMotor:CheckDrownable() -- Wrapper function for drownable check.
    local drownable = self.inst.components.drownable
    if drownable then
        return drownable:CheckDrownable()
    end
    return false
end

--★★★★★【OnUpdate —— locomotor 的心脏，每帧执行】
--   签名：OnUpdate(dt, arrive_check_only)
--     dt                —— 本帧时长（秒）。0 表示「只检查不推进」
--     arrive_check_only —— ★ 只做到达判定，不做任何移动决策（1035/1074 行的优化调用）
--   ---- 整体结构（七段）----
--   ① 早退：跳跃中 / 实体失效
--   ② 地面速度优化（仅在跨格时）
--   ③ 有目标时：有效性检查 → 到达判定 → 路径搜索轮询 → 转向
--   ④ arrive_check_only 早退
--   ⑤ should_locomote 决策（与状态图握手）
--   ⑥ 平台跳跃扫描（占本函数最大篇幅）
--   ⑦ 非跳跃路径：设置 motor 速度（含到达减速）
--   ★★ 最后一步：跳跃冷却倒计时（1757 行）
--★ 参见 update.lua 的组件更新遍历 —— OnUpdate 由主循环每帧调用。
--   参见 update.lua:256（遍历更新队列）、update.lua:270（NewUpdatingEnts 并表）、
--   update.lua:277（StopUpdatingComponents 的帧末清理）。
--   ★ 本文件 365/372 行的 StartUpdatingComponent / StopUpdatingComponent 正是
--     通过 StopUpdatingComponents 缓冲实现「延迟删除」（见 entityscript.lua:439）。
function LocoMotor:OnUpdate(dt, arrive_check_only)
--★★★【跳跃期间的完全让权】
--   `if self.hopping then return end` ——
--   ★★ 这是本文件最重要的架构约定：
--     「跳跃」期间，locomotor **不做任何移动决策**。
--     位置更新完全由 C++ 物理（初速度 + 重力 + 碰撞）与状态图负责。
--   ★ 这与「水平移动由 locomotor 驱动、垂直移动由物理驱动」的分工一致。
--   ★★ 状态由谁恢复？状态图的 jumping 状态结束时会调 FinishHopping（1186 行），
--     它把 hopping 置 false，OnUpdate 下一帧就恢复工作。
    if self.hopping then
        --self:UpdateHopping(dt)
        return
    end

--★★ 实体失效兜底：OnUpdate 是每帧调用的，实体可能在帧间被移除。
--   ★ Print 用 VERBOSITY.DEBUG 而非 print —— 调试日志有等级控制，避免刷屏。
    if not self.inst:IsValid() then
        Print(VERBOSITY.DEBUG, "OnUpdate INVALID", self.inst.prefab)
--★ 实体已失效：清路径、停更新、停计时器。必须全部做，否则会留下悬挂状态。
        self:ResetPath()
        self:StopUpdatingInternal()
        self:StopMoveTimerInternal()
        return
    end

--★★★【★★ 性能优化的核心：地面速度的「跨格才重算」】
--   条件：enablegroundspeedmultiplier 且不是 arrive_check_only
--   逻辑：取当前地块坐标 → 与 lastpos 比较 → 不同才 UpdateGroundSpeedMultiplier
--   ★★★ 收益量化：
--     UpdateGroundSpeedMultiplier 内有 3 次世界查询（creep 网格 + 地块 + 道路）
--     每帧 30 次/秒 × 数百个移动实体 = 上万次查询/秒
--     优化后：只在「跨过格边界」时触发，实体跑 1 格约需 0.5 秒 → 频率降 60 倍
--   ★ 这也解释了为什么 lastpos 存的是**地块坐标**而不是世界坐标：
--     地块坐标是整数，变化频率远低于浮点世界坐标。
--   ⚠ lastpos 初始为空表 → 第一次必然重算（正确行为）。
	if self.enablegroundspeedmultiplier and not arrive_check_only then
        local x, y, z = self.inst.Transform:GetWorldPosition()
        local tx, ty = TheWorld.Map:GetTileCoordsAtPoint(x, 0, z)
--★ 只用 tx/ty（地块的 x/y），忽略 z —— DST 地图是单层的。
        if tx ~= self.lastpos.x or ty ~= self.lastpos.y then
            self:UpdateGroundSpeedMultiplier()
--★★ 注意这里是整体替换而非逐字段赋值：`self.lastpos = { x = tx, y = ty }`。
--   ★ 每格一次的小表分配，比三个字段赋值稍慢但更简洁。
--   ⚠ 高性能要求下可考虑复用同一个表（self.lastpos.x = tx）。
            self.lastpos = { x = tx, y = ty }
        end
    end

--★ facedir：本次要转到的角度，1750/1649 行会用它（pusheventwithdirection 场景）。
	local facedir

    --Print(VERBOSITY.DEBUG, "OnUpdate", self.inst.prefab)
--★★★【有目标的主分支：整个 OnUpdate 的核心逻辑】
--   从 1450 到 1621 行，占本函数一半篇幅。子结构：
--     1452 有效性检查（目标/动作失效 → Clear）
--     1457 死亡检查
--     1462 取坐标
--     1466 到达判定（custom 或标准）
--     1489 到达后处理（派发事件、转向、推动作、Stop）
--     1522 未到达 → 路径搜索轮询 + 转向
    if self.dest then
        --Print(VERBOSITY.DEBUG, "    w dest")
--★★★【有效性检查：目标实体可能已死，动作可能已失效】
--   ★ 追踪移动目标时，目标可能随时被吃掉 —— 必须每帧验证。
--   ★ 缓冲动作失效（如目标物被烧毁）也要中止移动。
--   ★★ 关键：这里是 Clear() 而非 Stop() ——
--     因为「目标消失」不等于「正常停止」，不该派发 locomote 事件，
--     状态图需要自己通过其他方式恢复。
        if not self.dest:IsValid() or (self.bufferedaction and not self.bufferedaction:IsValid()) then
            self:Clear()
            return
        end

--★★★【死亡检查 —— health 与 locomotor 的耦合点】
--   `if self.inst.components.health and self.inst.components.health:IsDead()`
--   ★★ 死掉的实体不继续移动：否则玩家死亡后角色会「滑行」一段，
--     或者更糟 —— 若正在追玩家，会继续追着打。
--   ★ 注意判了 health 存在：不是所有 locomotor 实体都有 health。
--   ⚠ 但只 Clear 不 Stop：死亡时物理与状态由状态图/死亡流程接管。
--★★ 参见 components/health.lua:546 IsDead 与 health.lua:583 的死亡判定。
--   这是 health 与 locomotor 之间**唯一**的直接耦合点。
--   死亡事件在 health.lua:590 PushEvent("death")，
--   而这里用的是轮询式检查（每帧问一次），不是事件驱动。
--   ★ 轮询的好处：不依赖事件顺序，不会漏；
--     代价：每个有目标的移动实体每帧多一次组件查询。
        if self.inst.components.health and self.inst.components.health:IsDead() then
            self:Clear()
            return
        end

--★ 取目的地的当前坐标（Dest:GetPoint 每帧重取，因为目标在动）。
        local destpos_x, destpos_y, destpos_z = self.dest:GetPoint()
        local mypos_x, mypos_y, mypos_z = self.inst.Transform:GetWorldPosition()

--★ 三个结果变量一次性声明：到达 / 失效 / 攻击冷却中。
        local reached_dest, invalid, in_cooldown = nil, nil, false
--★★★【到达判定的两个实现】
--   ① customarrivecheck —— 动作自定义判定（完全接管）
--   ② 标准判定 —— 距离平方比较（见下）
--   ★★ 为什么要留这个钩子？因为有些动作的「到达」不是位置概念，
--     比如「追到能看见的位置」「追到攻击范围内但保持距离」
--     「召唤物追到主人身边」等等。
		if self.bufferedaction and self.bufferedaction.action.customarrivecheck then
			reached_dest, invalid = self.bufferedaction.action.customarrivecheck(self.inst, self.dest, self.bufferedaction)
		else
--★★【标准到达判定：距离平方】
--   `dsq = distsq(目标x, 目标z, 我x, 我z)` ——
--   ★ 只比较 x/z，**完全忽略 y**！
--   ★★★ 这是重要的设计决策：
--     站在船上的玩家点击岸上的物品，y 差很大但仍应判定为「到达」
--     —— 因为跳跃系统（平台 hopping）会负责把他送过去。
--     ★ 绝不能改成三维距离，否则跨平台移动永远判不到达。
--★ 参见 util.lua:553 distsq(v1, v2, v3, v4) ——
--   水平距离平方，**不比较 y**。这是本文件所有「到达判定」的基础。
			local dsq = distsq(destpos_x, destpos_z, mypos_x, mypos_z)
--★ arrive_dist 的平方 —— 避免每帧开方。
			local arrive_dsq = self.arrive_dist * self.arrive_dist
--★★★【★ 高帧率/大 dt 的容差放大 —— 一个反直觉但正确的优化】
--   `if dt > 0 then run_dist = GetRunSpeed() * dt * 0.5`
--      `arrive_dsq = math.max(arrive_dsq, run_dist * run_dist)`
--   ★★★ 语义：允许的到达距离**至少是「本帧最多能移动的距离的一半」**。
--   ★ 为什么需要？极端情况：arrive_dist 极小（比如 0.15）且实体正在高速冲向目标，
--     单帧位移可能大于 0.15 → 永远「跨过」到达圈 → 永远判定不到达 →
--     实体在目标周围来回穿梭（经典的「到达抖动」）。
--   ★ 用「半帧位移」作下限，保证至少「跨过时已进入范围内」。
--   ★★ 这是「连续运动离散化的容差补偿」的教科书案例。
--   ⚠ dt 极大时（如断线重连的时间跳跃）这个容差会很大，
--     可能导致「远处就判定到达」。dt=0 时不放大（1035 行的调用）。
			if dt > 0 then
--★ 系数 0.5 是「半帧」的经验值 —— 留一半余量避免误判。
				local run_dist = self:GetRunSpeed() * dt * .5
				arrive_dsq = math.max(arrive_dsq, run_dist * run_dist)
			end
--★ reached_dest = 距离平方 ≤ 到达距离平方。
			reached_dest = dsq <= arrive_dsq

--★★★【攻击的特殊处理：冷却中不算「到达」也不算「失效」】
--   ★★ 问题场景：玩家点击攻击一个正在冷却中的目标。
--     若按标准判定，距离到了就算 reached_dest → 立刻执行攻击 →
--     但此时还在冷却 → 动作失败 → 玩家白点了一下。
--   ★ 解法：交给 combat 组件的 LocomotorCanAttack 三态判定。
--   ★★★ 三态返回是本段最精彩的设计：
--     · reached_dest=true, in_cooldown=true → 「可以停下等冷却，但别执行」
--       → 1495 行 `if in_cooldown then return end` 保持移动但不执行
--     · invalid=true → 「目标没了/不可打」→ 完全中止
--     · reached_dest=true, in_cooldown=false → 正常执行
--   ★ 这是一个「移动系统向战斗系统请求三态裁决」的模式，
--     避免了「移动层不知道业务状态」的困境。
--★★ 参见 components/combat.lua 的 LocomotorCanAttack ——
--   它返回「到达 / 失效 / 冷却中」三态，
--   并使用 replica.combat（副本组件）以便客户端也能执行同一判定。
--   ★ combat.lua:653 是 health:DoDelta 的主调用方（与本文件无直接关系但同属移动-战斗链路）。
			--special case for attacks (in_cooldown can get set here)
			if self.bufferedaction and
				self.bufferedaction.action == ACTIONS.ATTACK and
				not (self.bufferedaction.forced and self.bufferedaction.target == nil)
			then
--★ combat 是**副本组件** —— 客户端也能访问，所以这段判定在两端都能跑。
--   ★★ 这是必须的：到达判定在客户端也要跑（预测）。
				local combat = self.inst.replica.combat
				if combat then
					reached_dest, invalid, in_cooldown = combat:LocomotorCanAttack(reached_dest, self.bufferedaction.target)
				end
			end
        end

--★★ 失效：完全中止（Stop + Clear）。Stop 会派发 locomote 让状态图停下。
        if invalid then
            self:Stop()
            self:Clear()
			return
--★★★【到达分支：整条移动指令的终点】
--   顺序（每一步都有讲究）：
--     ① 冷却中 → 只 return（保持状态，等下一帧）
--     ② 派发 onreachdestination（带目标与落点坐标）
--     ③ 执行 atdestfn 回调
--     ④ 转向到动作目标（除非 skip_locomotor_facing）
--     ⑤ 取出 bufferedaction 并推给实体（★ 先置 nil 防 Clear 里 Fail）
--     ⑥ Stop + Clear
        elseif reached_dest then
--★ 英文原注释 "I think this is fine?" —— 作者自己对代码的自审存疑。
--   ★ 这类注释在 Klei 代码里常见：标记出「我也不确定但先这样」的地方。
        	--I think this is fine? we might need to make OnUpdateFinish() function that we can run to finish up the OnUpdate so we don't duplicate code
--★★★【冷却中的早退 —— 必须 return 而不是继续】
--   ★ 若继续往下走，会执行动作（失败）或 Stop（丢失「等冷却后攻击」的意图）。
--   ★★ 保持 dest 与 bufferedaction 不变，下一帧重新判定，
--     冷却结束后自然就能执行了。这就是「等待」的实现。
            if in_cooldown then return end
            --Print(VERBOSITY.DEBUG, "REACH DEST")
--★ onreachdestination 事件：外部（特效/成就）得知「到达了」。
--   ★ 落点坐标用 destpos（目标坐标）而非实际位置 —— 供特效定位。
            self.inst:PushEvent("onreachdestination", { target = self.dest.inst, pos = Point(destpos_x, destpos_y, destpos_z) })
--★ atdestfn 是「到达即执行」的轻量回调（比 bufferedaction 更简单）。
            if self.atdestfn ~= nil then
                self.atdestfn(self.inst)
            end

--★★【`self.bufferedaction ~= self.inst.bufferedaction` 的判定】
--   防止「重复推同一个动作」：若 inst.bufferedaction 已经是它，说明之前推过了。
            if self.bufferedaction ~= nil and self.bufferedaction ~= self.inst.bufferedaction then
--★ skip_locomotor_facing 标记的动作不强制转向（如「开门」不该转身看门）。
                if self.bufferedaction.target ~= nil and self.bufferedaction.target.Transform ~= nil and not self.bufferedaction.action.skip_locomotor_facing then
					self:FaceMovePoint(self.bufferedaction.target.Transform:GetWorldPosition())
                elseif self.bufferedaction.invobject ~= nil and not self.bufferedaction.action.skip_locomotor_facing then
                    local act_pos = self.bufferedaction:GetActionPoint()
                    if act_pos ~= nil then
						self:FaceMovePoint(act_pos:Get())
                    end
                end
--★★ 先存局部变量、再置 nil —— 顺序不能反。
--   ★ 置 nil 的目的是「Clear 时不要 Fail 它」（见 1078 行的契约）。
				local bufferedaction = self.bufferedaction
				self.bufferedaction = nil --so it doesn't get Failed at Clear()
--★★★【双端分派：服务端 Push / 客户端 Preview】
--   ★ 这是本文件「双端同构」模式在动作执行处的体现 ——
--     与 PreviewAction/PushAction 的分派是同一个思路。
                if self.ismastersim then
					self.inst:PushBufferedAction(bufferedaction)
                else
					self.inst:PreviewBufferedAction(bufferedaction)
                end
            end
--★ Stop（派发 locomote 让状态图停）→ Clear（清所有意图）。
            self:Stop()
            self:Clear()
			return
--★★★【未到达分支：路径搜索轮询 + 转向】
--   ★ 这里的职责是「决定往哪转」，实际位移由物理马达完成。
--   ★★ 与寻路器的关系：本文件只**消费**寻路结果（GetSearchStatus /
--     GetSearchResult），求解本身在 C++ 侧。
		elseif not arrive_check_only then
            --Print(VERBOSITY.DEBUG, "LOCOMOTING")
--★ 等待搜索结果：path.handle 非 nil 说明有搜索在跑。
            if self:WaitingForPathSearch() then
--★ GetSearchStatus 返回 0/1/nil（见文件头的状态定义）。
                local pathstatus = TheWorld.Pathfinder:GetSearchStatus(self.path.handle)
                --Print(VERBOSITY.DEBUG, "HAS PATH SEARCH", pathstatus)
--★★ `pathstatus ~= STATUS_CALCULATING` —— 搜索结束（找到或没找到）。
--   ★ 每帧轮询一次直到结束 —— 这是异步搜索的 Lua 侧消费方式。
                if pathstatus ~= STATUS_CALCULATING then
                    --Print(VERBOSITY.DEBUG, "PATH CALCULATION complete", pathstatus)
                    if pathstatus == STATUS_FOUNDPATH then
                        --Print(VERBOSITY.DEBUG, "PATH FOUND")
--★ GetSearchResult 取结果（steps 是路径点列表）。
                        local foundpath = TheWorld.Pathfinder:GetSearchResult(self.path.handle)
                        if foundpath then
                            --Print(VERBOSITY.DEBUG, string.format("PATH %d steps ", #foundpath.steps))

--★★★【★ 「两步以内视为直线」的优化 —— 一个很实用的技巧】
--   `if #foundpath.steps > 2 then 采纳路径 else 丢弃，走直线 end`
--   ★★★ 为什么？A* 寻路器返回的结果里，起点与终点各占一个 step，
--     所以「steps 只有 2 个」意味着「起点直连终点，中间无需拐点」。
--   ★ 丢弃它的好处：走直线比逐点跟随更自然（不会在直线上画 S 形），
--     且省掉每帧的 step 计算。
--   ★ 这是「把复杂解法降级为简单解法」的典型优化 ——
--     物理马达本来就能处理碰撞，直线走不会比绕路差。
                            if #foundpath.steps > 2 then
                                self.path.steps = foundpath.steps
--★ currentstep = 2 —— 从第 3 个点开始（跳过起点附近的两个点，
--   它们通常在实体脚下或紧邻位置，无转向价值）。
                                self.path.currentstep = 2

                                -- for k,v in ipairs(foundpath.steps) do
                                --     Print(VERBOSITY.DEBUG, string.format("%d, %s", k, tostring(Point(v.x, v.y, v.z))))
                                -- end

--★ 丢弃直线路径：设 steps = nil，OnUpdate 的跟随分支就跳过。
                            else
                                --Print(VERBOSITY.DEBUG, "DISCARDING straight line path")
                                self.path.steps = nil
                                self.path.currentstep = nil
                            end
                        else
                            Print(VERBOSITY.DEBUG, "EMPTY PATH")
                        end
                    else
--★ pathstatus 为 nil = 搜索句柄失效（C++ 侧回收了）→ 视为失败。
--   ★ 这是一个「防御性分支」：正常情况下不会发生。
                        if pathstatus == nil then
                            Print(VERBOSITY.DEBUG, string.format("LOST PATH SEARCH %u. Maybe it timed out?", self.path.handle))
                        else
                            Print(VERBOSITY.DEBUG, "NO PATH")
                        end
                    end

--★★ 无论找到与否都要 KillSearch 并清 handle —— 句柄必须释放，否则泄漏。
--   ★ 注意：先 KillSearch 再 handle = nil，顺序与 771 行一致。
                    TheWorld.Pathfinder:KillSearch(self.path.handle)
                    self.path.handle = nil
                end
            end

--★★★【canrotate 状态标签 + pusheventwithdirection】
--   `if canrotate or self.pusheventwithdirection then`
--   ★★ 双重条件很有意思：
--     · canrotate —— 状态图允许转向 → 可以改实体朝向
--     · pusheventwithdirection —— 即使不能转向，
--       也要把方向放进 locomote 事件（见 341 行的设计动机）
--   ★ 所以对「玩家」而言，转向能力始终保留（因为玩家有 pusheventwithdirection）。
--★ 参见 stategraphs/commonstates.lua 的 walk 状态标签 ——
--   "canrotate" / "busy" / "moving" / "running" 四个标签由状态图维护，
--   locomotor 只读不写（除 PushEvent("locomote") 间接驱动状态切换）。
			local canrotate = self.inst.sg == nil or self.inst.sg:HasStateTag("canrotate")
			if canrotate or self.pusheventwithdirection then
                --Print(VERBOSITY.DEBUG, "CANROTATE")
                local facepos_x, facepos_y, facepos_z = destpos_x, destpos_y, destpos_z

--★★【路径跟随：确定「转向哪个点」】
--   有路径且未到最后一点 → 转向当前 step 点
--   否则 → 转向终点
--   ★ 这是「路径跟随」的经典结构：不是转向终点，而是转向下一个拐点。
                if self.path and self.path.steps and self.path.currentstep < #self.path.steps then
                    --Print(VERBOSITY.DEBUG, "FOLLOW PATH")
                    local step = self.path.steps[self.path.currentstep]
                    local steppos_x, steppos_y, steppos_z = step.x, step.y, step.z

                    --Print(VERBOSITY.DEBUG, string.format("CURRENT STEP %d/%d - %s", self.path.currentstep, #self.path.steps, tostring(steppos)))

--★ step_distsq：到当前拐点的距离平方。
                    local step_distsq = distsq(mypos_x, mypos_z, steppos_x, steppos_z)

                    local maxsteps = #self.path.steps
--★★★【非终点拐点的容差放大 —— 与 1471 行的到达容差同理】
--   `if currentstep < maxsteps then step_distsq = step_distsq - physdiameter^2`
--   ★★ 为什么要「减去直径平方」？
--     实体不是质点，**身体边缘碰到拐点就算「经过」了**，
--     此时中心距 = 物理直径。减去它让判定提前触发，避免「擦着拐点走」。
--   ★★★ 而终点不减 —— 因为终点用的是 arrive_dist（含半径），
--     判定标准本就不同。
--   ★ 这与 1471 行的「半帧位移容差」是同一族技巧：
--     都在补偿「离散帧 + 有限体积」带来的判定误差。
                    if self.path.currentstep < maxsteps then -- Add tolerance to step points that aren't the final destination.
                        local physdiameter = self.inst:GetPhysicsRadius(0)*2
                        step_distsq = step_distsq - physdiameter * physdiameter
                    end

--★ 到达拐点 → 前进到下一个。arrive_step_dist 通常只有 0.15，很严格。
                    if step_distsq <= (self.arrive_step_dist)*(self.arrive_step_dist) then
                        self.path.currentstep = self.path.currentstep + 1

--★ 还没到最后 → 预读下一个拐点（提前取，减少下一帧的延迟）。
                        if self.path.currentstep < maxsteps then
                            step = self.path.steps[self.path.currentstep]
                            steppos_x, steppos_y, steppos_z = step.x, step.y, step.z

                            --Print(VERBOSITY.DEBUG, string.format("NEXT STEP %d/%d - %s", self.path.currentstep, #self.path.steps, tostring(steppos)))
                        else
                            --Print(VERBOSITY.DEBUG, string.format("LAST STEP %s", tostring(destpos)))
--★ 到最后一点了 → 直接用终点坐标作为转向目标。
                            steppos_x, steppos_y, steppos_z = destpos_x, destpos_y, destpos_z
                        end
                    end
                    facepos_x, facepos_y, facepos_z = steppos_x, steppos_y, steppos_z
                end

--★ GetAngleToPoint：算「我指向那个点应该转多少度」。
				facedir = self.inst:GetAngleToPoint(facepos_x, facepos_y, facepos_z)

--★★★【★ 「后退时转身」的经典处理】
--   `local x,y,z = self.inst.Physics:GetMotorVel()`
--   `if x < 0 and self.strafedir == nil then facedir = facedir + 180`
--   ★★ 问题场景：实体在追踪目标时「跑过头」了 ——
--     目标在身后，但 motor velocity 仍是「向前」（+X 方向）。
--     若按 GetAngleToPoint 转，实体永远面向目标，
--     但物理马达还在往前推 → **倒着走向目标**（经典「太空步」）。
--   ★ 解法：检测 motor velocity 的 X 分量为负（说明在倒着走或被反弹），
--     就把目标角度 + 180°，让实体「转过来，用正面走向目标」。
--   ★★★ 这是一个纯经验性的 hack，但确实是解决倒行问题的最简方案。
--   ⚠⚠ 已知局限：
--     · 只看 x 分量，斜向移动（z 分量占主导）时判断不准
--     · `self.strafedir == nil` 排除斜向模式（斜向下不转身）
--     · 被外力推后（击退）时 motor velocity 为 0，不触发，
--       会短暂出现「被推着走还面向目标」
--   ★ 移植到新引擎时这是最需要重新设计的部分 ——
--     正确做法是让物理马达的方向与实体朝向解耦（像现代 3D 角色控制那样，
--     移动向量直接在世界空间计算，不依赖朝向）。
                local x,y,z = self.inst.Physics:GetMotorVel()
				if x < 0 and self.strafedir == nil then
					facedir = facedir + 180
					if canrotate then
						--V2C: matching legacy behaviour, where this ignores busy state
						--Print(VERBOSITY.DEBUG, "SET ROT", facedir)
						self:SetMoveDir(facedir)
					end
--★★ 另一分支：正常前进时转向，但避开 busy 状态（正在做动作不转身）。
--   ★ V2C 注释坦承了这个 busy 检查是「为了匹配旧行为」而保留的，
--     作者本人想删掉（"while I'd like to remove the busy check"）。
--     ★ 这类注释是「技术债的显式记录」的好范例。
				elseif canrotate and not (self.inst.sg and self.inst.sg:HasStateTag("busy")) then
					--V2C: while I'd like to remove the busy check,
					--     we'll keep it to match legacy behaviour:
					--     it used to call self.inst:FaceMovePoint(...)
					--Print(VERBOSITY.DEBUG, "FACE PT", Point(facepos_x, facepos_y, facepos_z))
					self:SetMoveDir(facedir)
                end
            end

--★★★【`wantstomoveforward = wantstomoveforward or not WaitingForPathSearch()`】
--   ★★ 语义：**寻路搜索完成后，即使之前没打算前进，也继续前进**。
--   ★★★ 原因：路径搜索是异步的，GoToEntity 发起时它还在算，
--     此刻还没法转向。搜索完成后才知道往哪走，
--     所以必须「无条件继续」直到到达。
--   ★ 若没有这行，实体会在等待搜索期间判定「无需前进」→ 停止更新 → 搜索结果永远不被消费。
            self.wantstomoveforward = self.wantstomoveforward or not self:WaitingForPathSearch()
        end
    end

--★ arrive_check_only 早退：跳过后面所有移动决策与状态修改。
	if arrive_check_only then
		return
	end

--★★★【should_locomote：locomotor 与状态图的核心握手逻辑】
--   目的：决定「本帧是否需要再推一次 locomote 事件（让状态图继续移动）」。
--   条件 1628：limbo 判定（被移出场景的实体不处理）
    local should_locomote = false
--★★★【limbo 判定 —— 一个微妙的双端逻辑】
--   `(self.ismastersim and not self.inst:IsInLimbo())`
--     `or not (self.ismastersim or self.inst:HasTag("INLIMBO"))`
--   ★★★ 拆开看：
--     · 服务端：需要「不在 limbo」
--     · 客户端：需要「没有 INLIMBO 标签」
--   ★★ 为什么客户端用 tag 而不是 IsInLimbo()？
--     因为 IsInLimbo 是服务端权威状态，客户端只能通过 tag 得知
--     （ limbo 实体的 netvar 会被跳过同步，见 entityscript.lua 的 limbo 机制）。
--   ⚠ 这又是一处「双端不对称但语义等价」的实现。
    if (self.ismastersim and not self.inst:IsInLimbo()) or not (self.ismastersim or self.inst:HasTag("INLIMBO")) then
--★ is_moving：状态图当前是否在「移动中」状态。
--★★ 参见 stategraph.lua 的 HasStateTag —— 本文件所有 sg:HasStateTag 调用的实现方。
        local is_moving = self.inst.sg ~= nil and self.inst.sg:HasStateTag("moving")
--★ is_running：状态图当前是否在「跑」状态。
        local is_running = self.inst.sg ~= nil and self.inst.sg:HasStateTag("running")
--★★★【overridelocomote 特殊分支：状态图接管移动时不做任何推动】
--   条件：不在 moving + 无目标 + 状态图有 overridelocomote 标签。
--   ★★ 语义：「移动由状态图自己驱动（如玩家直走、载具、动画位移），
--     locomotor 不要插手」。
--   ★ 与 805 行的 PreviewAction 里的同名检查配对。
		if not is_moving and self.dest == nil and self.inst.sg and self.inst.sg:HasStateTag("overridelocomote") then
			--Special case for "overridelocomote" states, and direct movement (no dest).
			--Generally we won't actually go to a "moving" state, even though "locomote"
			--should already be handled.
			should_locomote = false
--★★【★ 核心判定式：布尔异或的自表达写法】
--   `should_locomote = (not is_moving ~= not self.wantstomoveforward)`
--     `or (is_moving and (not is_running ~= not self.wantstorun))`
--   ★★★ 拆解：
--     · `a ~= b` 就是布尔「异或」——两个布尔值不同则为真
--     · 但这里写成 `not a ~= not b`（两边都取反）：
--       因为 not a、not b 在 Lua 里是**真值**（true/false），
--       而 `true ~= false` 得到 true/false。
--       ★ 写成 `not a ~= not b` 与 `a ~= b` 结果相同，
--         但前者更清晰地表达「两边状态不同」这一意图。
--   ★★★ 语义 = 「意图与现状不一致」：
--     第一项：想动但状态图没在动（或反之）→ 需要推 locomote
--     第二项：想跑但状态图没在跑（或反之）→ 需要推 locomote
--   ★★ 设计意义：只在「需要状态图切换状态时」才派发事件，
--     而不是每帧都推。这既省了事件分发，也避免了状态图反复重进 moving 状态。
--   ⚠⚠ 移植陷阱：这是「用真值异或表达状态差异」的 Lua 风格写法，
--     在强类型语言里必须显式写成 `a != b`。若有人误写成 `!a != b`（一边取反一边不取反），
--     语义会完全颠倒 —— 这是本文件最需要小心的一行。
		else
--★ 英文原注释 "'not' is being used below as a cast-to-boolean operator" ——
--   明确说明了「not 在这里用作布尔化操作符」。
			--'not' is being used below as a cast-to-boolean operator
			should_locomote =
				(not is_moving ~= not self.wantstomoveforward) or
				(is_moving and (not is_running ~= not self.wantstorun))
		end

--★ 正在移动/跑 → 刷新移动计时器（StartMoveTimerInternal 有 0.3 秒迟滞）。
        if is_moving or is_running then
            self:StartMoveTimerInternal()
        end
    end

--★ 状态不一致 → 推 locomote（带方向数据，若 pusheventwithdirection）。
    if should_locomote then
		self.inst:PushEvent("locomote", self.pusheventwithdirection and facedir and { dir = facedir } or nil)
--★★★【完全停止的判定与清理】
--   `not wantstomoveforward and not WaitingForPathSearch()`
--   ★★ 为什么还要检查「没在等搜索」？
--     因为寻路是异步的：用户松手时搜索可能还在跑。
--     若此时就停止更新，搜索结果永远不会被消费（句柄泄漏）。
--   ★★ 「三条件全部满足才停」是本函数最重要的资源回收逻辑：
--     意图没了 + 没在等 → 清路径、停更新、停计时器。
    elseif not self.wantstomoveforward and not self:WaitingForPathSearch() then
        self:ResetPath()
        self:StopUpdatingInternal()
        self:StopMoveTimerInternal()
    end

--★★ 物理马达速度：> 0 表示正在移动。这是整个跳跃分支的门槛。
--★ 参见 physics.lua 的 Launch / Launch2 / LaunchAt ——
--   它们直接用 Physics:SetVel 设置速度（绕过 motor），
--   意味着「被弹射」的实体不受 locomotor 的 motor 速度控制。
    local cur_speed = self.inst.Physics:GetMotorSpeed()
--★★ `cur_speed > 0` 才做跳跃检测 —— 站着不动不跳。
--   ★ 性能优化：绝大多数帧实体不移动（待命/攻击/死亡），
--     这个判断让整段跳跃逻辑（几百行）在这些帧完全跳过。
    if cur_speed > 0 then
--★★ 跳跃检测的四个前置条件：
--     · allow_platform_hopping 开启（默认 nil，即关闭！）
--     · bufferedaction 为空，或该动作不禁用跳跃
--   ★★ 注意默认 nil 是「关闭」——
--     所以「走到船边自动跳上船」不是全局行为，
--     必须由具体 prefab 显式调 SetAllowPlatformHopping(true)。
        if self.allow_platform_hopping and (self.bufferedaction == nil or not self.bufferedaction.action.disable_platform_hopping) then
            local mypos_x, mypos_y, mypos_z = self.inst.Transform:GetWorldPosition()

--★ 朝向转弧度：Transform:GetRotation 是弧度，乘 DEGREES 得角度。
            local rotation = self.inst.Transform:GetRotation() * DEGREES
--★ 世界空间的「正前方」向量：+X 为 0°，-Z 为 90°（DST 约定）。
            local forward_x, forward_z = math.cos(rotation), -math.sin(rotation)

--★ 传 GetSpeedMultiplier() 作参数 —— 预留「速度影响跳跃距离」的钩子。
			local hop_distance = self:GetHopDistance(self:GetSpeedMultiplier())

--★ GetCurrentPlatform：拿脚下平台（entityscript.lua 定义）。
            local my_platform = self.inst:GetCurrentPlatform()
--★★ 平台可自定义最大跳跃距离（更窄的平台不跳太远）。
			if my_platform and my_platform.components.walkableplatform.max_hop_distance then
--★ 取较小者：min(实体默认距离, 平台限制)。
				hop_distance = math.min(hop_distance, my_platform.components.walkableplatform.max_hop_distance)
			end

--★ other_platform：目标平台。初始为 nil（未知）。
            local other_platform = nil
            local destpos_x, destpos_y, destpos_z
--★★★【优先场景：目标就在同一平台上】
--   `if self.dest and self.dest:IsValid() and my_platform == self.dest:GetPlatform()`
--   ★★ 场景：玩家在船上点击船上的箱子。目标平台 = 船 = 脚下平台。
--     此时跳跃方向应指向**箱子**而不是正前方。
--   ★ 用 Dest:GetPlatform() 统一处理「目标是被拿在手里的物品」等情况。
			if self.dest and self.dest:IsValid() and my_platform == self.dest:GetPlatform() then
				destpos_x, destpos_y, destpos_z = self.dest:GetPoint()
				other_platform = my_platform
			end
--★ 没有明确目标平台 → 走「自动探测前方平台」的三分支。
			if other_platform == nil then
--★★★【自动探测的三个分支】
--   ① 玩家 或 有静态可跳平台 → 用地图的 GetNearestPlatformInDirection
--   ② 其他情况 → 向前 hop_distance 试探，查询该点平台
--   ③ 若目标平台无效 → 退化为「纯距离判断」（不要求有平台）
--   ★★ ① 的条件 `self.inst.isplayer or HasStaticHoppablePlatform`：
--     玩家永远用「找最近平台」（体验优先），
--     其他实体只在「有静态可跳平台」时才找（性能优先）。
--   ★ ② 的探测点 = 当前位置 + 前进方向 × 跳跃距离。
				if self.inst.isplayer or TheWorld.Pathfinder:HasStaticHoppablePlatform(mypos_x, 0, mypos_z) then
--★ GetNearestPlatformInDirection 由 TheWorld.Map 提供（C++ 侧）。
					other_platform, destpos_x, destpos_z = TheWorld.Map:GetNearestPlatformInDirection(mypos_x, mypos_z, forward_x, forward_z, hop_distance)
					if other_platform and self:IsValidDestinationPlatform(my_platform, other_platform) then
						destpos_y = 0
					else
--★ 目标平台无效 → 只用距离当作「跳跃点」，放弃平台校验。
						destpos_x, destpos_z = forward_x * hop_distance + mypos_x, forward_z * hop_distance + mypos_z
						other_platform = nil
					end
				else
					destpos_x, destpos_z = forward_x * hop_distance + mypos_x, forward_z * hop_distance + mypos_z
--★ 非玩家分支：直接查「跳跃落点处有什么平台」。
					other_platform = TheWorld.Map:GetPlatformAtPoint(destpos_x, destpos_z)
					if other_platform and not self:IsValidDestinationPlatform(my_platform, other_platform) then
						other_platform = nil
					end
				end
			end

--★ can_hop：能否跳跃。默认 false（每帧重算）。
            local can_hop = false
            local hop_x, hop_z, target_platform, blocked
--★★ too_early_top_hop：跳跃冷却未结束则不跳（1413 行设的 0.2 秒）。
            local too_early_top_hop = self.time_before_next_hop_is_allowed > 0
--★★★【跳跃的四个必要条件】
--   ① my_platform ~= other_platform（目标不是脚下这块）
--   ② 冷却已过（not too_early_top_hop）
--   ③ ScanForPlatform 找到落脚点（can_hop）
--   ④ 未被阻挡（not blocked）
            if my_platform ~= other_platform and not too_early_top_hop then
                can_hop, hop_x, hop_z, target_platform, blocked = self:ScanForPlatform(my_platform, destpos_x, destpos_z, hop_distance)
--★ 找到落脚点后，若目标平台需要预约则预约。
                if can_hop and not blocked and target_platform then
--★★【平台预约：防止两个实体同时跳向同一平台】
--   TryToReservePlatform 是 walkableplatform 组件的可选方法。
--   ★★ 解决的问题：船很小，两个人同时从两侧跳上去会「卡在边缘」。
--     预约机制让「先到先得」，后来的实体跳不过去。
--   ★ 与 1679 行的容量检查（IsValidDestinationPlatform:1239）是**两道独立的关卡**：
--     · IsFull() —— 硬容量（平台自带的 N 个坑位）
--     · TryToReserve() —— 软预约（时间窗口内的意图占用）
--   ★★ 软预约的好处：不占用硬容量，但能防止「同时挤」。
                    if target_platform.TryToReservePlatform then
						if target_platform:TryToReservePlatform(self.inst) then
                            self.reserved_platform = target_platform
--★ 预约失败 → 取消本次跳跃并标记 blocked（阻止后续的游动逻辑）。
                        else
                            can_hop = false
                            target_platform = nil
                            blocked = true
                        end
                    end
                end
            end
--★ 没有阻挡才继续处理跳跃/游动。
            if not blocked then
--★★ can_hop 分支：记录 last_platform_visited 后发起跳跃。
--   ★★ 记录时机很讲究（1714 行）：记录的是**当前平台**（my_platform），
--     因为「不能跳回」针对的是「我刚从这块跳走」。
                if can_hop then
                    self.last_platform_visited = my_platform

--★ StartHopping 移交控制权给状态图（详见 1396 行）。
                    self:StartHopping(hop_x, hop_z, target_platform)
--★★★【两栖生物的「游过去」分支 —— 不能跳跃时的替代方案】
--   条件：有 amphibiouscreature 组件 + other_platform 为 nil（没有可跳的平台）
--        + 不在 jumping 状态
--   ★ 场景：鸭子、蛙人这类生物从船边跳到水里——它们不「跳」，而是「游」。
--   ★★★ 关键：这里不走 StartHopping，而是直接 PushEvent("onhop")（1730 行），
--     由状态图的 onhop 处理器（commonstates.lua:768）决定是「游」还是「跳」。
--     同一个事件，两种行为 —— 状态图根据生物类型分流。
--   ★ 这是「用同一事件 + 状态图分流」而非「组件内分支」的架构选择。
--★★ 参见 components/amphibiouscreature.lua —— GetTransitionDistance / ShouldTransition。
--   参见 components/amphibiouscreature.lua:29 OnEntitySleep 与 locomotor 的休眠链路相关。
                elseif self.inst.components.amphibiouscreature ~= nil and other_platform == nil and not self.inst.sg:HasStateTag("jumping") then
--★ 过渡距离 = 自身半径 + amphibiouscreature 定义的过渡距离。
--   ★★ `GetTransitionDistance()` 是「从站着到开始游泳的距离」，
--     即岸边的缓冲带宽度。
                    local dist = self.inst:GetPhysicsRadius(0) + self.inst.components.amphibiouscreature:GetTransitionDistance()
                    local _x, _z = forward_x * dist + mypos_x, forward_z * dist + mypos_z
                    if my_platform ~= nil then
--★ 单纯的赋值占位 —— Lua 用来解构多返回值（只需要第二个）。
--   ★ 这是 Lua 特有的技巧：`local _` 声明一个不用的变量来吃掉第一个返回值。
--   ★★ 注意 1720 行同样用 `local _` 吃掉 ScanForPlatform 的 x/z。
--     强类型移植时这会变成显式的 discard/ignore 语法。
                        local _
--★ 只在「有平台时」才检测阻挡（无平台时不需要，下方 1728 行会另行检测）。
                        can_hop, _, _, _, blocked = self:ScanForPlatform(nil, _x, _z, hop_distance)
                    end

--★ ShouldTransition：两栖组件自己判断「这里该下水了吗」（如根据水深/速度）。
                    if not can_hop and self.inst.components.amphibiouscreature:ShouldTransition(_x, _z) then
--★★ 英文原注释解释了 blocked 复用的逻辑：
--   "If my_platform ~= nil, we already ran the 'is blocked' test as part of
--    ScanForPlatform. Otherwise, run one now."
--   ★ 即「有平台时 1722 行已检测过，无平台时现在补一次」—— 避免重复查询。
                        -- If my_platform ~= nil, we already ran the "is blocked" test as part of ScanForPlatform.
                        -- Otherwise, run one now.
                        if (my_platform ~= nil and not blocked) or
--★★★【`dist * 1.41421` —— 精确的 sqrt(2) 近似】
--   英文原注释："~sqrt(2); _x,_z are a dist right triangle so sqrt(dist^2 + dist^2)"
--   ★★★ 推理：检测点 (_x, _z) 在距离 dist 的方向上，
--     但 TestForBlocked 测的是「到那一点的直线距离」；
--     当且仅当方向为 45° 时直线距离 = dist * sqrt(2)。
--     沿对角线游动时路径最长，故按最坏情况检测。
--   ★ 1.41421 是 sqrt(2)=1.41421356 的截断，精度足够。
--   ★ 这种「按最坏方向取值」的处理方式在性能敏感代码里很常见。
                                not self:TestForBlocked(mypos_x, mypos_z, forward_x, forward_z, self.inst:GetPhysicsRadius(0), dist * 1.41421) then -- ~sqrt(2); _x,_z are a dist right triangle so sqrt(dist^2 + dist^2)
--★ 推 onhop 且带落点坐标 —— 状态图据此播放「下水」动画并设置物理初速度。
                            self.inst:PushEvent("onhop", {x = _x, z = _z})
                        end
                    end
                end
            end

--★★★【落水检查的触发条件】
--   `not can_hop and my_platform == nil and target_platform == nil`
--     and not HasStateTag("jumping")
--   ★★★ 三个条件合起来是「没在跳、脚下没平台、也没打算跳到某平台」
--     → 说明这个实体正在**离岸漂向虚空**，需要检查是否会溺亡。
--   ★ 若正在 jumping 则不检查（跳跃中有平台信息，状态图会处理落水）。
            if (not can_hop and my_platform == nil and target_platform == nil and not self.inst.sg:HasStateTag("jumping")) then
                self:CheckDrownable()
            end
--★ 跳跃检测的 else 分支：不允许跳跃（或未开启）→ 走「普通移动」路径。
        else
--★★★【CheckDrownable 为真时直接跳过电机设置】
--   ★★★ 这是「游泳接管移动」的机制：
--     落水后由 drownable 组件接管位置更新（浮力/游动），
--     locomotor 不能再设 motor 速度 —— 否则两者会打架（物体被拉回）。
--   ★ CheckDrownable 定义在 components/drownable.lua。
            if not self:CheckDrownable() then
--★ speed_mult = GetSpeedMultiplier() —— 装备/地面等倍率的合成值。
                local speed_mult = self:GetSpeedMultiplier()
--★★★【desired_speed：跑用 RunSpeed()，走用裸 walkspeed】
--   `self.isrunning and self:RunSpeed() or self.walkspeed`
--   ★★ 与 GetWalkSpeed() 的差异：后者是 `walkspeed * GetSpeedMultiplier()`，
--     而这里只取裸值（倍率在下一行统一乘）。
--   ★ 结果等价，但这里的写法是为 1748 行的「接近减速」做准备 ——
--     减速时改的是 speed_mult，不是 desired_speed。
                local desired_speed = self.isrunning and self:RunSpeed() or self.walkspeed
--★ 有目标时按距离平方判定「快到了」。
                if self.dest and self.dest:IsValid() then
                    local destpos_x, destpos_y, destpos_z = self.dest:GetPoint()
                    local mypos_x, mypos_y, mypos_z = self.inst.Transform:GetWorldPosition()
                    local dsq = distsq(destpos_x, destpos_z, mypos_x, mypos_z)
--★★★★★【★★ 接近减速（arrival easing）—— 手感的关键】
--   `if dsq <= .25 then speed_mult = math.max(.33, math.sqrt(dsq)) end`
--   ★★★ 这段代码是「走到目标时自然减速」的实现：
--     · 距离平方 ≤ 0.25（即距离 ≤ 0.5 格）→ 进入减速区
--     · 减速系数 = sqrt(距离)，下限 0.33
--   ★★ 为什么用**开方**（即 sqrt(距离平方) = 距离）而不是距离平方本身？
--     · 用距离线性减速：远处几乎全速，近处按比例减速 → 符合物理直觉
--     · 用距离平方减速：平方在远处大、近处骤降 → 减速曲线不自然
--     · 开方把平方还原成线性，正是为了得到「匀减速」的手感。
--   ★ 下限 0.33：永不降到 1/3 以下。
--     ★★ 这是关键的健壮性设计：下限保证了「即使距离为 0 也会继续走」，
--       从而不需要「精确到达 0 距离」这个不可能满足的条件。
--       配合 1475 行的到达判定，两者构成「减速靠近 → 判定到达」的完整节奏。
--   ★★ 没有这段减速，实体在接近目标时会「急刹」，看起来很僵硬。
--   ⚠ 这是一个「手感参数」：0.25 与 0.33 是调出来的，改动会明显影响观感。
                    if dsq <= .25 then
--★ math.max(.33, sqrt(dsq)) —— 见上方分析。0.33 是 1/3 速下限。
                        speed_mult = math.max(.33, math.sqrt(dsq))
                    end
                end

--★ SetMotorSpeed 处理斜向（见 726 行）。非斜向时直接设 motor 速度。
                self:SetMotorSpeed(desired_speed * speed_mult)
            end
        end
    end

--★ 跳跃冷却倒计时：每帧递减，最多减到 0。
--   ★★ 放在函数**最末尾**是刻意的：
--     它必须在「本帧是否跳了」的判定之后递减，
--     所以刚开始的那一帧 delay 仍是 0.2（保证至少冷却一整帧）。
--   ⚠ dt 极大时（断线重连）会一次减到 0，无副作用。
    self.time_before_next_hop_is_allowed = math.max(self.time_before_next_hop_is_allowed - dt, 0)
end

--★★★【四个寻路能力查询函数】
--   这四个函数是 locomotor 声明「自己能走什么地形」的入口。
--   ★★ 它们全部读同一个字段：self.pathcaps（寻路能力表）。
--   pathcaps 的键名（由调用方通过 AdjustPathCaps 传入的 capname 决定）
--   至少包括：allowocean（能走水面）、ignoreLand（忽略陆地）、
--   allowplatformhopping（能跨平台）。
--   ★ 键名是**字符串约定**而非枚举 —— 强类型移植时应收敛为枚举。
function LocoMotor:IsAquatic()
--★★ IsAquatic：完全水生。必须同时满足「能走水面」且「忽略陆地」。
--   ★★ 两个条件都要 —— 只有 allowocean 的话，
--     「陆地上也能走」的水生生物（如鸭子）不满足 IsAquatic。
	return self.pathcaps ~= nil and self.pathcaps.allowocean == true and self.pathcaps.ignoreLand == true
end

--★ CanPathfindOnWater：只要 allowocean 即可（鸭子也满足）。
function LocoMotor:CanPathfindOnWater()
    return self.pathcaps ~= nil and self.pathcaps.allowocean == true
end

--★★【IsTerrestrial：陆生。英文原注释解释了双重否定的原因】
--   "We use 'not' because the pathcaps may be unassigned or assigned false
--    (i.e. if they're changed at runtime)"
--   ★★★ 翻译：pathcaps 可能整体是 nil（从未设置），
--     也可能被运行时改成 false。所以必须用「取反」而不是「比较等于 false」
--     —— 后者在 nil 时会崩。
--   ★ 这是一条关于「可选配置」的重要防御模式。
function LocoMotor:IsTerrestrial()
    -- We use "not" because the pathcaps may be unassigned or assigned false (i.e. if they're changed at runtime)
    return self.pathcaps ~= nil and (not self.pathcaps.allowocean) and (not self.pathcaps.ignoreLand)
end

--★★ CanPathfindOnLand：默认 true（pathcaps 为 nil 时也返回 true）。
--   ★★ 注意这里与其他三个函数的默认值策略**相反**：
--     · IsAquatic / IsTerrestrial / CanPathfindOnWater —— pathcaps 为 nil 时返回 false
--     · CanPathfindOnLand —— pathcaps 为 nil 时返回 true
--   ★★ 原因是默认值：实体没配 pathcaps 时，应当「按陆地生物处理」
--     （最常见的情况），而不是「什么都不行」。
--   ★ 但这也造成了一个 API 不一致：四个查询里三个「默认无」，一个「默认有」。
--     使用方必须清楚这个区别，否则会出现「以为能在陆地走却不能」。
function LocoMotor:CanPathfindOnLand()
    return self.pathcaps == nil or (not self.pathcaps.ignoreLand)
end

--★★★【AdjustPathCaps：寻路能力开关】
--   启用 → pathcaps[capname] = true（懒建表）
--   禁用 → pathcaps[capname] = nil；若表空则整体置 nil
--   ★ 与 655 行 TempGroundSpeedMultiplier 的「懒建 + 空则置 nil」是同一套路。
--   ★★ 禁用时置 nil 而非 false —— 因为判读时用的是 `pathcaps.ignoreLand`
--     的真值性，nil 与 false 等价。用 nil 便于 `next()` 的空表检测。
function LocoMotor:AdjustPathCaps(enabled, capname)
    if enabled then
        if self.pathcaps == nil then
            self.pathcaps = {}
        end
        self.pathcaps[capname] = true
    else
        if self.pathcaps ~= nil then
            self.pathcaps[capname] = nil
--★ 空表则整体置 nil —— 保持「nil = 未设置」的语义（见 1768 行注释）。
            if next(self.pathcaps) == nil then
                self.pathcaps = nil
            end
        end
    end
end

--★★★★★【FindPath：向 C++ 寻路器提交一次搜索（或走直线）】
--   ★★★ 这是本文件与「寻路器」的唯一接口。分工非常清晰：
--     · locomotor：提交起点/终点/能力，等结果，**决定往哪转**
--     · TheWorld.Pathfinder（C++）：求解 A*，返回 steps 列表
--   locomotor **不做任何寻路决策**（不判断该不该寻路、不选备选路径），
--   它只做两件事：
--     ① 若两点之间视线通畅（IsClear）→ 放弃寻路，走直线
--     ② 否则提交搜索
--   ---- 完整流程 ----
--   1796 同步 allow_platform_hopping 到 pathcaps
--   1803 目标有效性检查
--   1807-1808 取起点终点
--   1821-1832 目标地块去重（★ 性能关键）
--   1836 视线通畅检查 → ResetPath（走直线）
--   1845 防抖 → SubmitSearch
function LocoMotor:FindPath()
--★★★【JBK 的注释坦承这是一个 hack —— 非常值得学习】
--   "This is a hack because of the handling of locomotor.pathcaps has no setter
--    and we do not want a metatable hook for all of every instance of locomotor
--    component. So we will watch the state of allow_platform_hopping which is
--    true or false if it was ever set or cleared later."
--   ★★★ 完整翻译：
--     问题：pathcaps 没有属性 setter（不走 class.lua 的 props 机制），
--          若要「pathcaps 变化时自动同步」，得给**每一个** locomotor 实例
--          挂一个元表钩子 —— 那会有明显的性能与内存开销（成百上千个实例）。
--     折中：不去监听 pathcaps 的变化，而是**在每次 FindPath 时**，
--          检查「allow_platform_hopping 是否曾经被显式设置过（可能为 nil/true/false）」，
--          然后手动同步到 pathcaps。
--   ★★ 这是一个「主动轮询替代被动监听」的经典权衡：
--     用「每次调用时多一次比较」换取「不给每个实例挂钩子」。
--   ★ 值得学习的是作者**把权衡的理由完整写了下来**——
--     后来者能理解为什么这里看起来很笨。
    -- NOTES(JBK): This is a hack because of the handling of locomotor.pathcaps has no setter and we do not want a metatable hook for all of every instance of locomotor component.
    -- So we will watch the state of allow_platform_hopping which is true or false if it was ever set or cleared later.
--★★ `if self.allow_platform_hopping ~= nil` —— 只在「被显式设置过」时才同步。
--   ★ 若从未设置（nil），AdjustPathCaps(nil, ...) 会走「禁用」分支，
--     把 allowplatformhopping 键置 nil —— 对从未配置过的东西是安全的。
--   ⚠ 但注意：若 allow_platform_hopping = false（显式禁用），
--     AdjustPathCaps(false, ...) 也会置 nil —— 结果正确（都是「不允许」）。
    if self.allow_platform_hopping ~= nil then
        self:AdjustPathCaps(self.allow_platform_hopping, "allowplatformhopping")
    end
    --Print(VERBOSITY.DEBUG, "LocoMotor:FindPath", self.inst.prefab)

    --if self.inst.prefab ~= "wilson" then return end

--★ 目标失效则不寻路（否则会向一个已销毁的实体提交搜索）。
    if not self.dest:IsValid() then
        return
    end

--★ Vector3 包装当前位置。Point 只存 3 个 float，Vector3 可能是 Lua 对象。
    local p0 = Vector3(self.inst.Transform:GetWorldPosition())
    local p1 = Vector3(self.dest:GetPoint())
    -- local dist = math.sqrt(distsq(p0, p1))
    --Print(VERBOSITY.DEBUG, string.format("    %s -> %s distance %2.2f", tostring(p0), tostring(p1), dist))

--⚠【被注释掉的距离上限检查】（见文件头 5-6 行的说明）
--   ★ 现在无距离限制 —— 玩家可以要求走到地图任何地方。
    -- if dist > PATHFIND_MAX_RANGE then
    --     Print(VERBOSITY.DEBUG, string.format("TOO FAR to pathfind %2.2f > %2.2f", dist, PATHFIND_MAX_RANGE))
    --     return
    -- end

    local ground = TheWorld
    if ground then
        --Print(VERBOSITY.DEBUG, "GROUND")

--★★★【目标地块去重 —— 本函数最重要的性能优化】
--   `GetPathTileIndexFromPoint` 把目标坐标映射到**寻路网格**的索引。
--   ★★ 语义：若「上次搜索的目标地块」与「本次相同」，直接 return —— 
--     因为寻路结果只取决于起点与终点所在格，
--     目标在同一格内移动不必重新求解。
--   ★★★ 这就是文件头 PATHFIND_PERIOD 被废弃后的替代方案：
--     用「空间去重」代替「时间节流」，既省 CPU 也不影响正确性。
--   ⚠ 精确性：目标在同格内移动时不再更新路径，
--     所以移动目标（逃跑的敌人）会有「路径滞后一格」的现象。
--     ★ 滞后距离 = 一格（寻路网格的分辨率，通常是 1~2 格），
--       加上 1619 行的「无条件继续前进」，实际表现是「追着上一格的路径走」，
--       而 1469 行的到达判定用的是**实时**目标坐标 —— 所以不会真的追丢。
        local desttile_x, desttile_y = ground.Pathfinder:GetPathTileIndexFromPoint(p1.x, p1.y, p1.z)
        --Print(VERBOSITY.DEBUG, string.format("    dest tile %d, %d", desttile_x, desttile_y))

--★ 双重守卫：本次有索引 且 上次也有记录（lastdesttile）。
        if desttile_x and desttile_y and self.lastdesttile then
            --Print(VERBOSITY.DEBUG, string.format("    last dest tile %d, %d", self.lastdesttile.x, self.lastdesttile.y))
--★★ 地块索引相同 → 直接返回（不重新寻路）。
--   ★★ 注意这里返回的是「不做事」，而不是「重置路径」——
--     已有路径继续被 OnUpdate 跟随。
            if desttile_x == self.lastdesttile.x and desttile_y == self.lastdesttile.y then
                --Print(VERBOSITY.DEBUG, "SAME PATH")
                return
            end
        end

--★ 记录本次目标地块，供下次去重比较。
        self.lastdesttile = {x = desttile_x, y = desttile_y}

        --Print(VERBOSITY.DEBUG, string.format("CHECK LOS for [%s] %s -> %s", self.inst.prefab, tostring(p0), tostring(p1)))

--★★★【视线通畅检查：寻路的第一道也是最重要的一道优化】
--   `Pathfinder:IsClear(p0, p1, self.pathcaps)` ——
--   ★★ 若起点到终点之间无阻挡，**根本不需要寻路**。
--     直接走直线（ResetPath 清掉旧路径，之后走电机 + 物理碰撞）。
--   ★★★ 这是本文件最重要的性能设计：
--     · 开阔地形（草原、海面）上 100% 命中 → 完全不触发 A*
--     · 只有需要绕障时才付出寻路代价
--   ★ 而且它同时是「正确性」保障：直线路径永远可走（物理会挡住），
--     不会因为寻路器找不到路（被围死）而卡住。
--   ★ 对比 1839 行的注释 "NO LOS - PATHFIND" ——
--     两分支互斥：一个「走直线」，一个「寻路」。
        if ground.Pathfinder:IsClear(p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, self.pathcaps) then
            --print("HAS LOS")
--★★ 视线通畅 → ResetPath（清掉旧路径，后续走直线）。
            self:ResetPath()
        else
            --print("NO LOS - PATHFIND")

--★★★【英文原注释解释了一个真实的性能问题】
--   "while chasing a moving target, the path may get reset frequently before any
--    search completes -- only start a new search if we're not already waiting for
--    the previous one to complete OR we already have a completed path we can
--    keep following until new search returns"
--   ★★★ 完整翻译：
--     问题：追移动目标时，FindPath 每帧被调用（若 lastdesttile 变了），
--           若无条件提交新搜索，会「杀死旧搜索、提交新搜索」无限循环，
--           一个搜索都完不成（CPU 100% 空转）。
--     解法：只在满足下列之一时才提交新搜索：
--       ① 已经有一条**完成的**路径（可以边走旧边等新）
--       ② 当前**没有**在等任何搜索（不会打断别人）
--   ★★ 这是「异步任务提交」的经典防抖：
--     「要么我有结果可用，要么我没在忙 —— 才发起新任务」。
            -- while chasing a moving target, the path may get reset frequently before any search completes
            -- only start a new search if we're not already waiting for the previous one to complete OR
            -- we already have a completed path we can keep following until new search returns
--★★ 防抖条件：`(self.path and self.path.steps) or not self:WaitingForPathSearch()`
--   ★ 注意 self.path.steps 存在即代表「有可跟随的已完成路径」。
--   ★★ 语义：即使「有搜索在跑」，只要「有完成的路径可走」，也提交新的 ——
--     因为旧路径还能用，新搜索只是为将来做准备。
            if (self.path and self.path.steps) or not self:WaitingForPathSearch() then

--★ KillPathSearch：先杀掉旧搜索再提交新的，避免句柄堆积。
                self:KillPathSearch()

--★★ SubmitSearch：真正的 A* 求解请求，返回句柄。
--   ★ pathcaps 作为最后参数传入 —— 寻路器据此决定「水能不能走」「陆地能不能走」。
--   ★★ 这是 pathcaps 的**唯一实际用途**：
--     locomotor 从不自己用 pathcaps 做移动决策（除了那四个查询函数），
--     它只是把这份「能力声明」转交给寻路器。
                local handle = ground.Pathfinder:SubmitSearch(p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, self.pathcaps)
--★ 句柄非 nil 表示提交成功。nil 通常意味着「寻路器满了/拒绝了请求」。
                if handle then
                    --Print(VERBOSITY.DEBUG, string.format("PATH handle %d ", handle))

--★★★【★ 「新旧路径共存」的设计 —— 极易被误解为 bug】
--   `self.path = self.path or {}` —— ★ 保留已有的 path 表（含 steps 与 currentstep）
--   `self.path.handle = handle` —— ★ 只替换句柄，不动 steps
--   ★★★ 这意味着：
--     · 新搜索在跑的同时，OnUpdate 继续跟随**旧的 steps**（1531 行那套逻辑）
--     · 新搜索完成后（1536 行）才替换 steps
--     ★★ 效果：角色永远在「走一条有效路径」，而路径在后台持续优化。
--     这就是「有旧路径可走就允许发起新搜索」（1845 行）的意义所在。
--   ⚠⚠ 潜在隐患：1537 行 `self.path.currentstep = 2` 在采纳新路径时重置，
--     但从 step 2 重新开始走一条新的（可能绕远的）路径，
--     可能让角色「突然改变方向往回走」。
--     ★ 实际不明显的理由：新旧路径的起点相同，
--       前几步通常方向一致，视觉上是平滑的。
                    --if we already had a path, just keep following it until we get our new one
                    self.path = self.path or {}
                    self.path.handle = handle

                else
--★ 提交失败只打调试日志，不做重试 —— 依赖下一帧的 FindPath 再次尝试。
                    Print(VERBOSITY.DEBUG, "SUBMIT PATH FAILED")
                end
            end
        end
    end
--★ 函数结束。注意末尾没有 return —— 无返回值，调用方不依赖返回值。
--   ★ FindPath 的结果通过 self.path 字段传递（副作用式 API），
--     而不是返回值。这是本文件的一贯风格。
end

--★★ 模块出口。LocoMotor 类通过 Class 系统全局可用（不需要模块导出机制）。
--   ★ 与 health.lua:665 的 `return Health` 形式一致。
return LocoMotor
