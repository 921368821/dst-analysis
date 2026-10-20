// spec-entityscript-p10.mjs —— 注释规格 第10部分：交叉引用补充层
// 目的：按要求补足「参见 xxx.lua:行号」格式的交叉引用，覆盖重点讲解区域的上下游。

export const BEFORE = {
  // ── 与 scheduler.lua 的交叉引用 ──
  "EntityScript:KillTasks#1": [
    "--★★ 参见 scheduler.lua:442 KillTasksWithID 是本行的下游实现；",
    "--   scheduler.lua:607 KillThreadsWithID 是对外的全局入口。",
    "--   参见 scheduler.lua:556 StartThread 的 id 继承机制。",
  ],
  "EntityScript:StartThread#1": [
    "--★★ 参见 scheduler.lua:556 StartThread(fn, id, param)",
    "--   ★ 参见 scheduler.lua:563 的 id 继承说明——本函数显式传 GUID，",
    "--     因此不会走「继承当前协程 id」的分支。",
  ],
  "EntityScript:DoStaticPeriodicTask#1": [
    "--★★ 参见 scheduler.lua:424 ExecutePeriodic（周期任务本体）",
    "--   参见 scheduler.lua:330 里「回调内 yield 会导致周期漂移」的警告。",
  ],
  "EntityScript:DoStaticTaskInTime#1": [
    "--★★ 参见 scheduler.lua:395 ExecuteInTime —— 实现是 limit=1 的周期任务。",
  ],
  "EntityScript:DoPeriodicTask#1": [
    "--★★ 参见 scheduler.lua:431 的返回值使用说明",
    "--   （调用方应保存 Periodic 对象以便 Cancel）。",
  ],
  "EntityScript:TimeRemainingInTask#1+2": [
    "--★★ 参见 scheduler.lua:110 onfinish 的调用方式",
    "--   —— 本函数的 TimeRemainingInTask 与之配套，供状态图算进度。",
  ],

  // ── 与 update.lua 的交叉引用 ──
  "EntityScript:StartUpdatingComponent#1": [
    "--★★ 参见 update.lua:256 是主循环的组件更新遍历；",
    "--   update.lua:270 是 NewUpdatingEnts 的并表位置；",
    "--   update.lua:277 是 StopUpdatingComponents 的帧末清理位置；",
    "--   update.lua:54 是 WallUpdatingEnts 的遍历。",
  ],
  "EntityScript:StopUpdatingComponent#1": [
    "--★★ 参见 update.lua:261 的 `not StopUpdatingComponents[cmp]` 判断",
    "--   正是本函数「延迟删除」能保持语义正确的原因；",
    "--   update.lua:279 调用本函数的 Deferred 版本。",
  ],
  "EntityScript:StartWallUpdatingComponent#1": [
    "--★★ 参见 update.lua:54 `for cmp in pairs(v.wallupdatecomponents)`",
    "--   —— 该遍历没有 StopUpdatingComponents 缓冲，故本表是立即生效的。",
  ],
  "EntityScript:LongUpdate#1": [
    "--★★ 参见 update.lua:301 LongUpdate —— 本函数由它遍历 Ents 逐个调用；",
    "--   update.lua:315-341 是 ignore_player 分支的过滤逻辑。",
  ],

  // ── 与 entityreplica.lua 的交叉引用 ──
  "Entity:AddNetwork#1+34": [
    "--★★ 参见 entityreplica.lua:30 ValidateReplicaComponent",
    "--   —— 它的 return self:HasTag('_'..name) and cmp or nil 正是本 __index 的核心。",
    "--   entityreplica.lua:34 ReplicateComponent 是唯一填充 _ 表的入口。",
  ],
  "EntityScript:HasOneOfTags#1+10": [
    "--★★ 参见 entityreplica.lua 的 ReplicateComponent:34",
    "--   由本文件的 AddComponent:631 调用。",
  ],
  "EntityScript:AddComponent#1+21": [
    "--★★ 参见 entityreplica.lua:41 AddTag('_'..name) 与 :46 rawset",
    "--   —— 说明副本组件在主组件构造前就已创建。",
  ],
  "EntityScript:RemoveComponent#1+12": [
    "--★★ 参见 entityreplica.lua 的 UnreplicateComponent",
    "--   —— 撤销副本与 '_' 标签，使 self.replica.xxx 立即返回 nil。",
  ],
  "EntityScript:Remove#1+24": [
    "--★★ 参见 entityreplica.lua:46 rawset(self.replica._, name, ...)",
    "--   —— 本行的 rawget 正是读同一张表，必须绕过 __index 钩子。",
  ],

  // ── 与 stategraph.lua / brain.lua 的交叉引用 ──
  "EntityScript:SetStateGraph#1": [
    "--★★ 参见 stategraph.lua:82 SGManager:RemoveInstance（清理实例）；",
    "--   stategraph.lua:60 SendToList（按 asleep 决定入哪个调度表）。",
  ],
  "EntityScript:SetStateGraph#1+8": [
    "--★★ 参见 stategraph.lua:62-70 —— 休眠态下实例进入 tickwaiters 桶，",
    "--   直到唤醒 tick 才会被调度。",
  ],
  "EntityScript:SetStateGraph#1+10": [
    "--★★ 参见 stategraph.lua 的 SGManager:OnPushEvent",
    "--   —— 返回 false 时 PushEvent_Internal:1307 会跳过状态图。",
  ],
  "EntityScript:PushEvent_Internal#1+18": [
    "--★★ 参见 stategraph.lua 的 HandleEvent / PushEvent / IsListeningForEvent",
    "--   —— 本行的两个分支分别对应它们。",
  ],
  "EntityScript:PushEvent_Internal#1+21": [
    "--★★ 参见 stategraph.lua 的 SGManager:OnPushEvent；",
    "--   以及 stategraph.lua:715 RemoveInstance 中的 ClearBufferedEvents。",
  ],
  "EntityScript:SetBrain#1": [
    "--★★ 参见 brain.lua:257 / brain.lua:273 BrainManager:RemoveInstance",
    "--   —— brain 对象销毁时从调度表摘除。",
  ],
  "EntityScript:_DisableBrain_Internal#1+8": [
    "--★★ 参见 brain.lua:89 BrainWrangler:RemoveInstance —— 停止大脑的核心。",
  ],

  // ── 与 class.lua 的交叉引用 ──
  "__index#1+5": [
    "--★★ 参见 class.lua:150 Class() —— 本实体类的构造入口；",
    "--   class.lua:257 / class.lua:276 是实例创建的 __call 实现。",
  ],
  1: [
    "--★★ 参见 class.lua 是本文件唯一的硬依赖，见 class.lua:150。",
  ],
  "__index#1+34": [
    "--★★ 参见 entityscriptproxy.lua:88 把 replica._ 再次包一层代理；",
    "--   entityscriptproxy.lua:62 components_proxy_mt 描述其查找规则。",
  ],
  "EntityScript:GetDeathLoot#1+8": [
    "--★★ 参见 entityscriptproxy.lua:81 EntityScriptProxy = ProxyClass(...)",
    "--   —— 本行 require 的目的就是执行这行副作用。",
  ],

  // ── 与 componentactions.lua 的交叉引用 ──
  "EntityScript:HasOneOfTags#1+18": [
    "--★★ 参见 componentactions.lua 的 RegisterComponentActions",
    "--   —— 由本文件 AddComponent:643 调用、RemoveComponent:661 撤销。",
  ],
  "EntityScript:AddComponent#1+33": [
    "--★★ 参见 componentactions.lua:RegisterComponentActions(name)",
    "--   必须在组件构造与模组钩子之后调用，否则读不到完整状态。",
  ],

  // ── 与 components/map.lua 的交叉引用 ──
  "EntityScript:SetDeployExtraSpacing#1+5": [
    "--★★ 参见 components/map.lua RegisterDeployExtraSpacing",
    "--   —— 本行注释已指明「see components/map.lua」。",
  ],
  "EntityScript:SetDeploySmartRadius#1+7": [
    "--★★ 参见 components/map.lua RegisterDeploySmartRadius",
  ],
  "EntityScript:SetTerraformExtraSpacing#1+6": [
    "--★★ 参见 components/map.lua RegisterTerraformExtraSpacing",
  ],
  "EntityScript:SetGroundTargetBlockerRadius#1+6": [
    "--★★ 参见 components/map.lua RegisterGroundTargetBlocker",
  ],

  // ── 与 components/*.lua 的交叉引用（生命周期回调的转发方）──
  "EntityScript:_DisableBrain_Internal#1": [
    "--★★ 参见 components/amphibiouscreature.lua:29 OnEntitySleep",
    "--   components/boatphysics.lua:684 OnEntitySleep",
    "--   —— 组件层的 sleep 回调与本函数在同一条休眠链路上。",
  ],
  "EntityScript:_EnableBrain_Internal#1": [
    "--★★ 参见 components/amphibiouscreature.lua:33 OnEntityWake",
    "--   components/boatdrifter.lua:85 OnEntityWake",
    "--   —— 与 1120 行严格配对。",
  ],
  "EntityScript:RemoveFromScene#1": [
    "--★★ 参见 components/inventoryitem.lua:349（入包即移出场景）、",
    "--   components/hideout.lua:177、",
    "--   components/hermitcrab_relocation_manager.lua:240 —— 均为调用方。",
  ],
  "EntityScript:IsValid#1": [
    "--★★ 参见 stategraph.lua:77 SGManager:OnRemoveEntity",
    "--   brain.lua:11 BrainManager:OnRemoveEntity",
    "--   —— 二者都靠本文件的 Remove:1714 触发。",
  ],
};

export const AFTER = {};