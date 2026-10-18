// spec-locomotor-p7.mjs —— locomotor.lua 深度注释规格 第 7 部分：交叉引用补充层
// 目的：按要求补足「参见 xxx.lua:行号」格式的交叉引用，覆盖上下游关键机制。

export const BEFORE = {
  // ── 与 class.lua 的关系：双端分派与 setter ──
  266: [
    "--★★ 参见 class.lua:82 Class(base, _ctor, props) —— 本行是第二个实参（构造器）。",
    "--   class.lua:75 removesetter 是 289-292 行客户端降级所依赖的函数。",
    "--   class.lua:64 addsetter 是运行期追加 setter 的接口（本文件未用）。",
    "--   ★ 对比 health.lua:62 同样使用 props 表，两者是同一范式。",
  ],
  272: [
    "--★★ 参见 class.lua 的方法查找机制（class.lua:82 `c.__index = __index`）——",
    "--   因为 props 非 nil，方法查找走 __index 函数；",
    "--   而 self.RunSpeed 是**实例字段**（rawset 到实例上），",
    "--   它在实例表里，会**优先于**元表的 __index 命中。",
    "--   ★ 这就是「把方法指向函数」能生效的底层原因。",
  ],
  289: [
    "--★★ 参见 class.lua:75 removesetter(t, k) ——",
    "--   它做 `rawset(t, k, _[k][1])`（恢复原值）再 `_[k] = nil`（摘除 setter）。",
    "--   ★ 顺序不可反：先取回原值再删元数据。",
  ],
  344: [
    "--★ 参见 class.lua:82 —— props 表让这 4 个字段的赋值触发 netvar 写入。",
  ],

  // ── 与 util/sourcemodifierlist.lua 的关系 ──
  548: [
    "--★★ 参见 util/sourcemodifierlist.lua:8 SourceModifierList 构造签名",
    "--   `Class(function(self, inst, base_value, fn, dirtycb)` —— 本行**不传** base_value，",
    "--   所以用默认的 1 与 multiply 语义（见 sourcemodifierlist.lua:28）。",
    "--   util/sourcemodifierlist.lua:60 SetModifier 内部会自动注册 onremove 清理。",
    "--   ★ 与 health.lua:92-93 的差别：那里显式传 base_value=0 与 additive，",
    "--     因为吸收率是「加法累计」，而这里是「倍率连乘」。",
  ],

  // ── 与 health.lua 的耦合 ──
  1457: [
    "--★★ 参见 components/health.lua:546 IsDead 与 health.lua:583 的死亡判定。",
    "--   这是 health 与 locomotor 之间**唯一**的直接耦合点。",
    "--   死亡事件在 health.lua:590 PushEvent(\"death\")，",
    "--   而这里用的是轮询式检查（每帧问一次），不是事件驱动。",
    "--   ★ 轮询的好处：不依赖事件顺序，不会漏；",
    "--     代价：每个有目标的移动实体每帧多一次组件查询。",
  ],

  // ── 与 walkableplatform 的关系 ──
  1207: [
    "--★★ 参见 components/walkableplatform.lua —— IsFull / player_only / no_mounts",
    "--   / max_hop_distance 都定义在该组件的构造里（walkableplatform.lua:1-15）。",
    "--   平台的注册与容量统计在 components/walkableplatformmanager.lua。",
  ],
  1226: [
    "--★★ 参见 components/walkableplatform.lua:44 的 RemovePlatformFollower 配对流程，",
    "--   以及 walkableplatformmanager.lua 的 RegisterPlatform / AddPlatform。",
    "--   ★ 1241 行的 \"walkableplatform_full\" tag 由 walkableplatform 组件写入，",
    "--     是「容量已满」这一状态的跨端快照。",
  ],
  1297: [
    "--★ 参见 components/boatringdata.lua（或 boat 相关组件）——",
    "--   boatringdata 是可复制组件，客户端可读，因此这条判定能双端一致。",
  ],

  // ── 与 drownable / amphibiouscreature / embarker 的关系 ──
  1416: [
    "--★★ 参见 components/drownable.lua:364 附近的 CheckDrownable ——",
    "--   落水后由该组件接管移动（浮力、游动、溺水计时）。",
    "--   drownable.lua:378 也有一处 health:DoDelta（溺水扣血，ignore_absorb=true）。",
  ],
  1717: [
    "--★★ 参见 components/amphibiouscreature.lua —— GetTransitionDistance / ShouldTransition。",
    "--   参见 components/amphibiouscreature.lua:29 OnEntitySleep 与 locomotor 的休眠链路相关。",
  ],
  1396: [
    "--★ 参见 components/embarker.lua —— 玩家登船/下船的状态记录与过场。",
    "--   ★ StartHopping 是它唯一的调用方之一。",
  ],

  // ── 与 playercontroller 的关系：客户端预测 ──
  930: [
    "--★★ 参见 components/playercontroller.lua —— GetRemotePredictPositionExternal",
    "--   是「客户端把预测目标位置上报给服务端」的通道。",
    "--   配套参见 playercontroller.lua:2212 附近的 revive 相关处理（与 health.lua 的联动）。",
  ],
  438: [
    "--★★ 参见 components/playercontroller.lua 的攻击输入处理 ——",
    "--   PopOverrideTimeMoving 的结果会随网络包上报，",
    "--   服务端用 OverrideMoveTimer 采纳这个预测值。",
    "--   ★ 参见 components/combat.lua 里 GetTimeMoving 的使用方（移动攻击的距离判定）。",
  ],
  158: [
    "--★★ 参见 components/health.lua:158 不适用；本行的 netvar 读取路径是",
    "--   `inst.player_classified.externalspeedmultiplier:value()`，",
    "--   该 netvar 在 netvars.lua 中声明。",
    "--   ★ 双端速度系统的另一半在 272-278 行的方法分派表。",
  ],

  // ── 与 stategraph 的关系：locomote 握手 ──
  1112: [
    "--★★★ 参见 stategraphs/commonstates.lua 的 walk / run 状态 ——",
    "--   它们监听 \"locomote\" 事件进入移动状态。",
    "--   参见 stategraphs/commonstates.lua:768 的 onhop 事件处理器（跳跃）。",
    "--   commonstates.lua:797 的 tags 里含 \"jumping\" 与 \"autopredict\"，",
    "--   后者正是 108 行 ClientRunSpeed 里检查的 tag。",
  ],
  1404: [
    "--★ 参见 stategraphs/commonstates.lua:771 ——",
    "--   onhop 处理器里同样有 `if not inst.sg:HasStateTag(\"jumping\")` 的守卫，",
    "--   与本行严格配对（避免状态图被重复触发进 jumping）。",
  ],
  1564: [
    "--★ 参见 stategraphs/commonstates.lua 的 walk 状态标签 ——",
    "--   \"canrotate\" / \"busy\" / \"moving\" / \"running\" 四个标签由状态图维护，",
    "--   locomotor 只读不写（除 PushEvent(\"locomote\") 间接驱动状态切换）。",
  ],
  1629: [
    "--★★ 参见 stategraph.lua 的 HasStateTag —— 本文件所有 sg:HasStateTag 调用的实现方。",
  ],

  // ── 与 physics / 引擎层的关系 ──
  721: [
    "--★ 参见 physics.lua —— PhysicsCollisionCallbacks / CollisionMaskBatcher",
    "--   是 Lua 侧能看到的全部物理设施。",
    "--   ★ Physics 组件本体（SetMotorVel / GetMotorVel / SetVel / Teleport）",
    "--   是 C++ 侧实现，Lua 无源码。这是「两层速度模型」的物理层。",
  ],
  1656: [
    "--★ 参见 physics.lua 的 Launch / Launch2 / LaunchAt ——",
    "--   它们直接用 Physics:SetVel 设置速度（绕过 motor），",
    "--   意味着「被弹射」的实体不受 locomotor 的 motor 速度控制。",
  ],

  // ── 与 constants / tuning 的关系 ──
  12: [
    "--★ 参见 constants.lua:769 GROUND_ROADWAYS ——",
    "--   由 tilemanager.lua:175 填充（道路类地块的静态集合）。",
    "--   参见 main.lua:453 `RoadManager = TheGlobalInstance.entity:AddRoadManager()` ——",
    "--   RoadManager 是 C++ 侧对象，可能为 nil（非道路世界）。",
  ],
  330: [
    "--★ 参见 tuning.lua:4359 DEFAULT_LOCOMOTOR_HOP_DISTANCE = 6.0。",
    "--   参见 tuning.lua:3637 PLATFORM_HOP_DELAY_TICKS = 8 与",
    "--   tuning.lua:3638 PLATFORM_FLOATING_HOP_DELAY_TICKS = 4。",
  ],
  300: [
    "--★ 参见 tuning.lua 的 WILSON_WALK_SPEED / WILSON_RUN_SPEED ——",
    "--   角色 prefab（prefabs/wilson.lua 等）在构造时覆盖这两个值。",
  ],

  // ── 与 update.lua 的关系 ──
  1424: [
    "--★ 参见 update.lua 的组件更新遍历 —— OnUpdate 由主循环每帧调用。",
    "--   参见 update.lua:256（遍历更新队列）、update.lua:270（NewUpdatingEnts 并表）、",
    "--   update.lua:277（StopUpdatingComponents 的帧末清理）。",
    "--   ★ 本文件 365/372 行的 StartUpdatingComponent / StopUpdatingComponent 正是",
    "--     通过 StopUpdatingComponents 缓冲实现「延迟删除」（见 entityscript.lua:439）。",
  ],

  // ── 与 entityscript.lua 的关系 ──
  51: [
    "--★ 参见 entityscript.lua:927 AddPlatformFollower / :911 RemovePlatformFollower",
    "--   —— 「平台跟随者」机制在 EntityScript 层实现，",
    "--    locomotor 只消费 GetCurrentPlatform 的结果。",
    "--   ★ 参见 components/walkableplatformplayer.lua:90 的 AddPlatformFollower 调用。",
  ],
  52: [
    "--★★【★ 平台跟随（platformfollowers）的实际实现不在本文件】",
    "--   机制全貌：",
    "--     ① 实体站在可站平台上 → walkableplatform.lua:146 AddPlatformFollower(ent)",
    "--     ② 平台每帧移动 → 平台把自己的 Transform 位移**同步给**所有 follower",
    "--     ③ follower 因此被动地跟着移动 —— locomotor 完全不参与",
    "--   ★★ 所以「站在移动平台上被带着走」不需要 locomotor 做任何事：",
    "--     平台的移动被直接施加到实体上，locomotor 只是不再设 motor 速度",
    "--     （1740 行的 CheckDrownable / 1657 行的 cur_speed > 0 判定都会跳过）。",
    "--   参见 entityscript.lua:911-930 的双向解绑实现，",
    "--   以及 walkableplatformplayer.lua:261-277 的玩家特殊处理（掉出平台时移除）。",
  ],

  // ── 与 combat.lua 的关系 ──
  1477: [
    "--★★ 参见 components/combat.lua 的 LocomotorCanAttack ——",
    "--   它返回「到达 / 失效 / 冷却中」三态，",
    "--   并使用 replica.combat（副本组件）以便客户端也能执行同一判定。",
    "--   ★ combat.lua:653 是 health:DoDelta 的主调用方（与本文件无直接关系但同属移动-战斗链路）。",
  ],

  // ── 与 componentactions / bufferedaction 的关系 ──
  982: [
    "--★ 参见 components/bufferedaction.lua 与 componentactions.lua ——",
    "--   bufferedaction.arrivedist / distance / action.mindistance /",
    "--   action.extra_arrive_dist / action.skip_locomotor_facing 等字段",
    "--   全部由动作定义侧提供。",
    "--   参见 componentactions.lua 的 RegisterComponentActions（组件动作注册）。",
  ],
  845: [
    "--★ 参见 components/bufferedaction.lua 的 options.instant ——",
    "--   该标志由 PreviewAction:826 与外部逻辑设置，会一路传到",
    "--   EntityScript:PushBufferedAction。",
  ],

  // ── 与 mainfunctions / util 的关系 ──
  1469: [
    "--★ 参见 util.lua:553 distsq(v1, v2, v3, v4) ——",
    "--   水平距离平方，**不比较 y**。这是本文件所有「到达判定」的基础。",
  ],
  1364: [
    "--★ 参见 math2d.lua / mathutil.lua 的 VecUtil_Length / VecUtil_Normalize。",
  ],
};

export const AFTER = {};
