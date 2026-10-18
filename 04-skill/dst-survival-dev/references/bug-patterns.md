# Bug 模式排查手册

> 收录 **108 条**从 DST 真实源码里核实出来的 Bug 模式。每条给出「症状 / 根因 / 排查方法 / 修复 / 预防」。
> 引用格式 `文件:行号` 均为源码核实位置；标注「推断」的条目是基于代码阅读的合理推断，未经运行时验证。

---

## 目录

| 分区 | 主题 | 条数 | 编号 |
|---|---|---|---|
| [A](#a-协程与生命周期) | 协程与生命周期 | 7 | A1–A7 |
| [B](#b-网络同步与联机) | 网络同步与联机 | 8 | B1–B8 |
| [C](#c-存档与数据) | 存档与数据 | 6 | C1–C6 |
| [D](#d-数值与状态同步) | 数值与状态同步 | 6 | D1–D6 |
| [E](#e-世界生成) | 世界生成 | 6 | E1–E6 |
| [F](#f-性能) | 性能 | 6 | F1–F6 |
| [G](#g-ui-与输入) | UI 与输入 | 4 | G1–G4 |
| [H](#h-ai-与状态机) | AI 与状态机 | 7 | H1–H7 |
| [附录一](#附录逐行深度注释阶段新发现的缺陷18-条) | 深度注释阶段新发现（混合） | 18 | N1–N18 |
| [附录二](#附录二动作系统与存档系统深度注释新增缺陷13-条) | 动作系统 / 存档 | 11 | ACT1–ACT8、S1–S3 |
| [附录三](#附录三玩家控制与物品系统深度注释新增缺陷12-条) | 玩家控制与物品 | 8 | P1–P8 |
| [附录四](#附录四容器系统与-ui-框架深度注释新增缺陷14-条) | 容器系统 / UI 框架 | 9+4 | CTR1–CTR9、GR1–GR4 |
| [附录五](#附录五世界生成与数值系统深度注释新增缺陷11-条) | 世界生成 / 数值 | 12 | W1–W6、M1–M6 |
| — | [症状速查表](#症状速查表) | — | **共 108 条** |

**编号规则：** 主文用单字母分区（A–H），**字母在整个文档内唯一**。
附录另有独立前缀：`N` 深度注释新发现、`ACT` 动作、`CTR` 容器、`GR` UI 根因、
`S` 存档编码、`P` 玩家控制、`W` 世界生成、`M` 数值常量。
报 bug 时直接用完整编号（如 `B3`、`ACT3`、`CTR4`），不要只写字母。

---

## A. 协程与生命周期

### 症状：A1 · 1 秒的周期任务实际跑了 1.2 秒，且越积越慢

> **同源**：附录 `N16` 记录了同一根因的另一面（同为周期任务回调内 yield 导致的漂移）。两者是**同一条缺陷**，编号不同只为区分侧重点。

`DoPeriodicTask(1, fn)` 的实际执行间隔随负载升高而变长。玩家反馈"每秒掉落的判定越来越慢"、"燃烧蔓延比预期慢"。严重时同一个周期任务的两次触发间隔能到 3 秒以上。

**根因**：`DoPeriodicTask` 底层是协程（`scheduler.lua:218` 的 `coroutine.resume`），所以回调里**可以 `yield`，而且不会有任何报错**。一旦回调里某个被调用的函数 yield 了，这个周期任务在下一次 tick 恢复之前不会再次运行——实际周期变成「至少 1 秒 + 被挂起那段逻辑的时长」。

**排查方法**：
1. 把回调体替换成纯计时（只累加一个计数器），观察计数器增长速度：
   ```lua
   inst:DoPeriodicTask(1, function() self._probe = (self._probe or 0) + 1 end)
   -- 挂 debugui：每 5 秒打印 TheSim:GetTick() 与 self._probe 的比值
   ```
2. 在可疑的子函数入口加探针，确认是哪一层 yield：
   ```lua
   local function traced(f) return function(...) print("enter", debugstack(2,1,0)); return f(...) end end
   ```
3. 统计周期：注册 10 个同类任务，观察是否同时出现漂移（是则查共享逻辑），只有个别漂移（则查该实体的特殊分支）。

**修复**：把长时序逻辑从周期任务里搬出去，用协程脚本表达。

```lua
-- ❌ 回调里调了一个会 yield 的函数
inst:DoPeriodicTask(1, function()
    if self.count % 10 == 0 then DoSomethingWithAnim() end  -- 内部 Sleep
end)

-- ✅ 周期回调只做"本刻能做完"的事；序列交给 StartThread
inst:DoPeriodicTask(1, function() self.count = self.count + 1 end)
inst:StartThread(function()
    while not self.inst:IsAsleep() do
        Sleep(10)
        DoSomethingWithAnim()
    end
end)
```

**预防**：在团队规范里写死"**定时器回调是不可挂起的**"。所有带 `Sleep` 的逻辑必须是 `StartThread` 的函数体，而不是被定时器回调调用的深层函数。加一条 lint 规则：定时器回调体内禁止出现已知的可挂起函数名白名单。

---

### 症状：A2 · Cancel 一个"正在 yield 中"的周期任务 → 协程永久泄漏

反复生成/销毁实体后，协程数只增不减。内存缓慢上涨；严重时调度器队列膨胀导致全局帧耗时上升。关掉游戏重开就恢复。

**根因**：`scheduler.lua:234` 有 `if coroutine.status(v.co) == "dead" then ... kill it!` 的回收逻辑——它只回收**已经跑完**的协程。如果协程正挂在 `SLEEP` 上、此时被 `Cancel()` 从列表里摘掉，它就永远不会 resume，也永远不会 dead，成为悬空协程。

**排查方法**：
1. 在开发构建里挂一个每 60 刻的监视器（代码见 `debugging.md` §4）：
   ```lua
   local n_co = 0
   for _ in pairs(scheduler.running) do n_co = n_co + 1 end
   if n_co > 800 then print(string.format("[LEAK?] t=%d coroutines=%d", TheSim:GetTick(), n_co)) end
   ```
2. 用「生成 1000 个实体 → 全部销毁」重复三轮，看协程数是否回到基线。
3. 定位挂在哪个函数上——在 `Task` 的 resume 点打印协程创建处的 `debugstack`，按创建位置聚类。

**修复**：周期任务回调内**禁止 yield**（这是唯一的根治手段）。若已经存在无法避免的挂起点，改为"回调只置一个待办标志，由独立的每帧驱动统一处理"：

```lua
inst:DoPeriodicTask(1, function()
    self._dirty = true          -- 只置标志，不挂起
end)
inst:StartUpdatingComponent(self)  -- 统一在 OnUpdate 里消费 _dirty
```

**预防**：`Cancel()` 的实现里加一条断言——被取消的任务若协程状态不是 `dead`/`suspended-on-same-tick`，就打警告并把创建栈记进环形缓冲区。这条断言在开发构建里能提前 100% 捕获这类泄漏。

---

### 症状：A3 · `Sleep(0)` 不是"立即继续"，而是"下一帧"

写了一个"本帧内串行做完"的小工具函数，里面用了 `Sleep(0)` 想让出控制权再立刻恢复。结果整条逻辑链被打散到多帧执行，中间出现可见的状态中间态（例如"食物先被取出、下一步才被吃掉"）。

**根因**（`scheduler.lua:356`）：

```lua
function Sleep(time)
    local desttick = math.ceil((GetSchedulerTime(schedule.isstatic) + time) / GetTickTime())
    if GetSchedulerTick(schedule.isstatic) < desttick then
        coroutine.yield(SLEEP, desttick)
    else
        coroutine.yield()          -- 空 yield → 下一帧继续，不是"这一帧末尾"
    end
end
```

`Sleep(0.001)` 因为不足一格，会落进 `coroutine.yield()` 分支——**下一帧才继续**。不存在"帧内继续"的语义。

**排查方法**：在协程里每步打印 `TheSim:GetTick()`，观察同一段逻辑的不同步骤是否落在同一个 tick 上。

**修复**：不需要跨帧就直接连续调用；需要跨帧就用 `Sleep(GetTickTime())` 或更大的显式时长，让语义可读。

```lua
-- ✅ 让"至少下一帧"这件事显式化
Sleep(GetTickTime())
```

**预防**：把 `Sleep` 的"最小有效时长"写进 API 文档；给 `Sleep(0)` 这类写法加断言 `assert(time > 0, "Sleep(0) 不会立即继续")`。

---

### 症状：A4 · 服务器校时后所有等待中的协程同时断言失败

断线重连或跨地域迁移后，服务端瞬间崩一片堆栈，全是 `scheduler.lua:166` 附近的断言失败。

**根因**（`scheduler.lua:166`）：`OnTick` 里对 `waitingfortick` 中所有等待中的协程做 `assert(k >= tick)`。任何 `Sleep` 到**过去的刻**（即目标 tick 小于当前 tick）都会立刻触发断言失败。网络校时回拨会造成系统时间与刻计数不一致，从而把 `Sleep` 的目标刻推到过去。

**排查方法**：在 `OnTick` 入口临时插桩，打印 `tick` 与 `min(waitingfortick keys)` 的差值。如果出现负数/大幅回退，就是时间源被改动。

**修复**：
1. **绝对不要用真实时间或网络时间驱动模拟刻**。模拟时钟必须单调递增。
2. 把断言改成软失败：目标刻已过时，按"立即唤醒"处理并记一条警告。

```lua
local d = k - tick
if d < 0 then
    Log.Warn("[scheduler] 过期的 Sleep 目标 tick=%d 当前=%d，按立即处理", k, tick)
    k = tick   -- 而不是 assert
end
```

**预防**：把"模拟时间"与"真实时间"分成两个独立的调度器（`scheduler.lua:324` 就是这么做的：`scheduler` 走模拟时间、`staticScheduler` 走真实时间）。UI 动画必须挂真实时间那条，暂停时仍要动。

---

### 症状：A5 · 实体销毁了，但它的定时器还在跑（回调名拼错）

实体已经 `Remove()`，日志里仍在打它的周期日志；实体越多日志越多，且这些实体占的 CPU 随时间线性上升。

**根因**：清理回调名写成了 `OnRemoveFromEntity`，而实体销毁时框架调的是 `OnRemoveEntity`（见 `architecture.md` §8 反模式 1 的回调名对照表）。前者只在"组件被单独移除"时触发。后者拼错 → 清理代码永远不执行。

**排查方法**：
```lua
-- 开发构建：在组件基类的末尾加一个"未被调用的回调名"告警
function MyComponent:OnRemoveFromEntity()   -- 故意拼错
    Log.Warn("[leak] %s 的清理回调从未被调用，任务是否泄漏？", self.inst)
end
```
再 grep 一遍 `OnRemoveFrom` 与 `OnRemove` 的所有出现，确认拼写。

**修复**：

```lua
-- ✅ 用框架真正的名字
function MyComponent:OnRemoveEntity()
    if self.updatetask then self.updatetask:Cancel() end
    self.inst:RemoveAllEventCallbacks()
end
```

**预防**：把回调名做成**基类里的虚方法**并给出默认实现，派生类只覆写，不允许自由起名。在框架层加一条断言：实体销毁后若 `pendingtasks` 非空则报错。

---

### 症状：A6 · 批量取消任务时漏掉一部分（onfinish 在遍历中改表）

`Remove()` 时 `for k in pairs(self.pendingtasks) do k:Cancel() end` 之后，偶发有 1–2 个任务没被取消。概率与任务数量正相关。

**根因**（`entityscript.lua:1470` 与 `:1476`）：`Cancel()` 会触发 `onfinish`，而 `task_finish` 里执行 `inst.pendingtasks[task] = nil`。Lua 的 `pairs` 对"当前 key 被置 nil"是安全的——**但如果 `onfinish` 在这期间往表里新增了 key**，遍历就会跳过新 key；而某些任务的 `onfinish` 链会重新挂新任务。

**排查方法**：在取消循环前后打印 `#` 计数的辅助统计：
```lua
local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
print("before", count(inst.pendingtasks))
for k in pairs(inst.pendingtasks) do k:Cancel() end
print("after", count(inst.pendingtasks))   -- 应当是 0
```

**修复**：先快照再取消。

```lua
local pending = {}
for k in pairs(self.pendingtasks) do pending[#pending+1] = k end
self.pendingtasks = {}
for _, task in ipairs(pending) do task:Cancel() end
```

**预防**：框架层统一提供 `CancelAllPendingTasks()`，禁止业务代码直接遍历 `pendingtasks`。任何"遍历一个会被回调修改的集合"的地方，统一走快照模式。

---

### 症状：A7 · 事件监听未注销 → 内存泄漏 + 已销毁实体被回调

长会话后内存线性增长；更隐蔽的是——某个已经被 `Remove()` 的实体，在世界状态变化时仍然被调用到回调里，报"在已销毁对象上执行逻辑"，或直接 nil 索引崩溃。

**根因**（`entityscript.lua:1232`）：`RemoveAllEventCallbacks` 做的是**双向解绑**——同时清 `self.event_listening`（我在听谁）和 `self.event_listeners`（谁在听我）。**Lua/C++ 的 GC 不会帮你做这件事**：table 是强引用，`TheWorld:PushEvent("entity_death", {inst = ...})` 的 data 会被监听者闭包捕获，实体逻辑上已死也被拖住不回收。

**排查方法**：
1. 统计每个实体的事件监听数（`architecture.md` §5.6 的阈值表）：单实体 > 50 就是异常。
2. 在 `Remove()` 末尾加断言：
   ```lua
   assert(self.event_listeners == nil and self.event_listening == nil,
          "Remove 后仍有事件监听残留")
   ```
3. 订阅时一律走 `ListenForEvent`（它内部做双向记账），不要直接往 `event_listeners` 上塞。

**修复**：

```lua
-- ✅ 订阅必须成对登记
inst:ListenForEvent("ms_playerjoined", OnPlayerJoined, TheWorld)

function MyComponent:OnRemoveEntity()
    self.inst:RemoveEventCallback(OnPlayerJoined, TheWorld)
    self.inst:RemoveEventCallback(OnPlayerLeft, TheWorld)
end
```

**特别提醒：** `SourceModifierList` 在 DST 里已经处理了这个场景——`SetModifier` 时若 `source` 是实体，会自动注册 `onremove` 监听把修饰器摘掉。**你的实现必须照抄这个机制**，否则"装备的帽子被烧掉后防御力永久 -20%"会成为常态。

**预防**：把"订阅一律走封装 API"写成硬规范；在 `Remove()` 的最后一行做无残留断言。

---

## B. 网络同步与联机

### 症状：B1 · 单边启用 netvar → 客户端实体反序列化错位（静默数据错乱）

给服务器装一个"服务器专属"模组后，所有客户端的实体属性错乱——**不是报错，是静默的值互换**。典型表现是 A 的血量条显示成 B 的体温、物品的"是否已装备"状态错乱。

**根因**（`netvars.lua:29-32` 的警告描述的正是这个约束）：netvar 的 **"声明顺序即 wire format"**。DST 靠"服务器与客户端跑同一套 Lua"来保证顺序一致，这在"模组只能服务器安装"的场景下必然崩——客户端少声明了一个字段，后面所有字段整体前移一位。

**排查方法**：
1. 在两端各打印一次声明序列并 diff：
   ```lua
   -- 放在所有 netvar 声明之后
   print("[netvar order]", MODNAME, table.concat(netvar_order, ","))
   ```
2. 检查是否有任何 netvar 声明被包在 `if TheWorld.ismastersim then` 里（这是最常见的写法事故）。
3. 检查模组是否用了条件加载（`modworldgenmain.lua` vs `modmain.lua`）。

**修复**：**用显式字段 ID 而非声明序号**做 wire format。

```lua
-- ❌ 依赖声明顺序
local inst_level = net_byte(inst.GUID, "level", "leveldirty")

-- ✅ 显式稳定 ID（hash 或注册表分配的序号）
local NETVAR_IDS = { level = 0x1A2B, phase = 0x1A2C }
local inst_level = net_byte(inst.GUID, "level", "leveldirty", NETVAR_IDS.level)
```

代价是每字段多 2–4 字节，收益是彻底摆脱顺序耦合，且支持"服务器有、客户端没有"的渐进式扩展。**这是本清单里最值得优先改动的一条。**

**预防**：加一条启动期断言——记录全局 netvar 声明总数与 ID 集合的校验和，两端不一致就在联机握手阶段直接报错，而不是让数据错位。

---

### 症状：B2 · 某个字段的带宽莫名变大，且日志里看不出原因

抓包显示单个实体的流量比预期高 3–5 倍，但没有任何异常日志，字段改动频率看起来正常。

**根因**（`netvars.lua:55-57` 明确警告）：客户端调用过 `set_local` 之后，服务器的下一次 `set` **每次都会变成脏**。`player_classified.lua:16-20` 的 `SetDirty` 工具函数说明这是被有意使用的模式（把状态变更变成事件），所以在原版里这个问题是"可控的"。但如果你自己给某个字段加了 `set_local` 而忘了它会被强制同步，**该字段带宽永久性退化为"每次 set 都发"**。

**排查方法**：
1. 在开发构建里统计每字段的实际发送次数：
   ```lua
   -- 在 netvar 的 set 路径上挂钩
   netvar_stats[fieldname] = (netvar_stats[fieldname] or 0) + (did_dirty and 1 or 0)
   ```
2. 全局 grep `set_local`，逐个确认是否需要。

**修复**：为每个 netvar 标注「是否允许 `set_local`」；开发构建里对不允许的字段断言拦截。

```lua
function NetVar:Set(v)
    if not self.allow_set_local and self._locally_set then
        Log.Warn("[netvar] %s 在被 set_local 后又被 set，带宽已永久抬高", self.name)
    end
    ...
end
```

**预防**：把 `set_local` 的语义写进 API 文档："**不保证下次 Set 的脏判定幂等**"。

---

### 症状：B3 · 新增组件后客户端永远显示满血

新写的组件带血条，服务端逻辑完全正确，但所有客户端 UI 上永远是满值。

**根因**（`entityreplica.lua:5`）：`REPLICATABLE_COMPONENTS` 是一个**独立的白名单**，决定是否创建客户端副本。它和 `is_a(Component)` 的类型继承判断**不联动**。忘了加白名单 → 服务端有 `<name>` 组件，客户端没有 → 副本的 `Max()` 走 fallback 分支返回默认值（通常是 100 或最大上限）。

**排查方法**：在客户端打印：
```lua
print("has component:", inst.components.mine, "replica:", inst.replica.mine)
```
如果客户端 `components.mine == nil` 而服务端非 nil，就是白名单问题。

**修复**：新增可复制组件时必须同步登记，或在创建时显式注册：
```lua
inst:AddReplicableComponent("mine")      -- 不依赖全局白名单，更不易漏
```

**预防**：把「可复制组件」改为**显式注册制**而不是全局白名单——全局白名单在组件数量破百之后必然漏。

---

### 症状：B4 · 服务端写了 replica → 同步静默失效

服务端改了某个值，客户端完全不响应；或者客户端改了之后服务端状态被污染。

**根因**：replica 是**只读镜像**。服务端写它不会通过网络下发（因为同步方向是服务端→客户端的权威组件→replica），等于往一个不参与同步的镜像上写。

**注意一个例外：** DST 自己在服务端读 replica，注释写得很明确（`combat.lua:330`）：

```lua
local iframeskeepaggro_combat = self.target.sg and self.target.sg:HasStateTag("iframeskeep_aggro")
    and self.target.replica.combat or nil  -- V2C: intentionally using replica on server
```

**读是合法的**（replica 在双端都存在，只是服务端这份通常由网络更新）；**写会破坏同步**。

**排查方法**：grep 所有 `replica.` 的赋值点（左侧不是 `local` 的），逐个确认角色。

**修复**：在框架层给 replica 加只读保护：
```lua
local replica_mt = { __newindex = function() error("禁止在服务端/客户端写 replica", 2) end }
```
服务端想改值就写 `inst.components.xxx`，setter 会自动推到 replica。

**预防**：把"replica 可读不可写"写成注释贴在每个 `*_replica.lua` 文件头；CI 里加静态检查拦截 `replica.* =` 的写入形式。

---

### 症状：B5 · 两端算出不同的结果（`pairs` 遍历顺序）

客户端预测"这次烹饪会做出 X"，服务端实际做出 Y。或：多人在同一场景触发的事件顺序因人而异（某人先被打断、某人先放技能），但换个时间进游戏又不一样。

**根因**：`pairs` 的遍历顺序依赖 Lua 表的哈希布局，同一份数据在不同插入顺序、不同 Lua 版本下顺序可以不同。两个真实例子：

1. **护甲打碎的顺序**（`inventory.lua:408`）：`for armor, amt in pairs(absorbers)` 里，`max`/`sum` 两行是**顺序无关**的所以安全，但紧接着的 `armor_damage[armor] = ...` 决定 `armorbroke` 事件顺序——玩家同时穿两件护甲且被一击打碎两件时，哪件先触发是不确定的。
2. **烹饪配方选择**（`cooking.lua` 的 `GetCandidateRecipes`）：`table.sort` **不稳定**，priority 相同的候选之间相对顺序取决于 `pairs` 的哈希顺序。原版规避了这个——`stewer:StartCooking` 只在服务端跑（`containers.lua:353` 的客户端分支是 `SendRPCToServer`），所以只有一份结果。

**排查方法**：把可疑的 `pairs` 遍历改成打印带序号的版本，跑多局看输出是否稳定：
```lua
local i = 0
for k, v in pairs(t) do i = i + 1; print(i, tostring(k)) end
```

**修复**：任何**要发事件、要改外部状态**的遍历都必须有序化。

```lua
-- ❌ 顺序不确定
for armor, amt in pairs(absorbers) do
    armor_damage[armor] = absorbed_damage * amt / total_absorption
    if armor_damage[armor] >= armor_durability then armor:OnBroken() end
end

-- ✅ 显式排序 + 确定性 tiebreaker
local ordered = {}
for armor, amt in pairs(absorbers) do
    if amt ~= nil then ordered[#ordered+1] = {armor=armor, amt=amt} end
end
table.sort(ordered, function(a, b)
    if a.armor.durability ~= b.armor.durability then
        return a.armor.durability < b.armor.durability   -- 耐久低的先破
    end
    return tostring(a.armor.prefab) < tostring(b.armor.prefab)  -- 确定性 tiebreaker
end)
for _, e in ipairs(ordered) do ... end
```

**规则**：纯聚合（max / sum / min）可以用 `pairs`（可交换）；**任何要发事件的遍历必须用 `ipairs` 或显式排序**。

**预防**：把这条写进 code review 清单。数值排序也必须带 tiebreaker——只按主键排序仍是不确定的。

---

### 症状：B6 · 模组可以无限抬高全局 RPC 限流

> **同源**：附录 `N5` 记录了同一根因的另一面（同为 `networkclientrpc.lua:1848` 的 RPC 限流无上界）。两者是**同一条缺陷**，编号不同只为区分侧重点。

服务器被压垮，但所有诊断都显示"没有攻击者"。查限流日志也看不到任何超限告警。

**根因**（`networkclientrpc.lua:1848`）：`AddModRPCHandler` 每注册一个 RPC 就执行 `RPC_QUEUE_RATE_LIMIT = RPC_QUEUE_RATE_LIMIT + RPC_QUEUE_RATE_LIMIT_PER_MOD`，**无上限**。一个模组注册上万个 RPC 处理器就能把全局限流抬到天上，让真正的攻击流量畅通无阻。

**排查方法**：启动时打印 `RPC_QUEUE_RATE_LIMIT` 的值，看它是否随模组数量线性增长。

**修复**：每模组独立配额 + 全局硬上限。

```lua
local GLOBAL_HARD_LIMIT = 200
function AddModRPCHandler(namespace, name, fn)
    if MOD_RPC[namespace][name] then
        error(("RPC %s/%s 已被注册（可能被其他模组劫持）"):format(namespace, name))
    end
    RPC_QUEUE_RATE_LIMIT_PER_MOD_TOTAL =
        math.min(RPC_QUEUE_RATE_LIMIT_PER_MOD_TOTAL + RPC_QUEUE_RATE_LIMIT_PER_MOD,
                 GLOBAL_HARD_LIMIT - RPC_QUEUE_RATE_LIMIT_BASE)
    ...
end
```

**预防**：限流额度必须在"每发送者每刻"维度上分账（见 `networkclientrpc.lua:1675-1703` 的 `RPC_Queue_Limiter`），且归零后**清表**（`:1724`），否则伪造 sender 能把限流表撑爆。

---

### 症状：B7 · 玩家操作"黏滞"，感觉延迟半拍

联机时点击/移动/攻击的响应明显慢于单机，RTT 高时不明显、低时也不明显，就是"总是慢一点"。

**根因**：缺少客户端预测。`prefabs/player_common.lua:877` 的 `EnableMovementPrediction` 只在客户端挂载预测 locomotor，服务器权威位置照常推进并回传，客户端在收到权威结果后纠正。**没有这一步，玩家输入就要等一个来回。**

**排查方法**：在客户端打时间戳：
```lua
-- 输入时
local t0 = Network.GetServerTime()
-- 收到纠正时
print(("predict latency=%dms, error=%d"):format(
      (Network:GetServerTime() - t0) * 1000, distsq_to_authoritative))
```

**修复**：完整链路（照抄 DST 的四步）：
1. 客户端挂预测 locomotor，`EnableMovementPrediction` 时机在**组件与状态图都就绪之后**。
2. 客户端预测目标用「预测位置」而非「当前模拟位置」。
3. 第一个 RPC 延迟一帧发送（引擎不允许生成帧发 RPC）。
4. **回滚带（rubber band）**：预测误差超过阈值时无条件放弃预测、让服务器位置胜出，优先级高于一切其他纠正。

**预防**：把预测/纠正链路当作独立模块写单元测试——注入人为延迟，验证客户端不会永久分叉。DST 的 `no_predict_fastforward` / `RemotePausePrediction` 整套机制在 `SGwilson_client.lua` 里实现，**单机游戏应完全关掉它**。

---

### 症状：B8 · 移动平台/船只上的位置错乱，难以复现

> **同源**：附录 `P4` 记录了同一根因的另一面（同为 `remote_vector.y` 一字段三语义）。两者是**同一条缺陷**，编号不同只为区分侧重点。

站在船上时位置错乱、跨平台跳跃时物体重叠。改了这里好那里坏，重现需要特定的操作顺序。

**根因**（`playercontroller.lua:3694`）：`remote_vector.y` **一个字段承担三种语义**——同时用作"移动意图标签"（0/1/2/3/4）和真实高度坐标。文件里至少两处 `FIXME(JBK): Boat handling.` 标记说明这条路径至今有已知问题。叠加因素：`platform` / `platform_relative` 这对参数是后期补上的（`FIXED(V2C)` 注释），代码里到处是补丁，`printinvalidplatform` 里那个 `Playform` 拼写错误说明这段是紧急加入的。

**排查方法**：把 `remote_vector` 的每个取值范围都打出来，看哪些值既不像标签也不像合理坐标。

**修复**：**从第一天就把位置消息设计成 `(平台句柄, 局部坐标)` 二元组**，或者明确声明不支持移动平台。字段拆分会多花 4 字节，换来可调试性。

```lua
-- ✅ 意图与坐标分离
local intent = net_tinybyte(inst.GUID, "move_intent", "move_intentdirty")  -- 枚举
local pos    = net_vec3(inst.GUID, "move_pos", "move_posdirty")            -- 坐标
```

**预防**：不要中途给位置协议加维度。这条路径的补丁史说明"后加参数"的代价远高于"一开始就设计对"。

---

## C. 存档与数据

### 症状：C1 · NaN / Inf 写进存档 → 存档永久损坏

> **同源**：附录 `S1` 记录了同一根因的另一面（同为 NaN 写坏存档；S1 补充了判据表的分支细节）。两者是**同一条缺陷**，编号不同只为区分侧重点。

存一次档之后，这个存档再也读不回来。报错位置在读档的某一层（`loadstring` 失败或数据字段全空），但**存档文件里搜不到任何明显的错误值**。

**根因**：NaN 一旦写进存档就是**永久**的（NaN 传播：NaN 参与任何运算结果都是 NaN）。DST 有两道防线：

1. 写入前猎捕（`entityscript.lua:1770`）：`if isbadnumber(x) or isbadnumber(y) or isbadnumber(z) then ... end`——开发环境直接 `error()`，发布环境降级为 0。
2. 序列化后扫描（`mainfunctions.lua:1201`）：
   ```lua
   local patterns
   if BRANCH == "dev" then patterns = {"=nan", "=-nan", "=inf", "=-inf"}
   else                      patterns = {"=-1.#IND", "=1.#QNAN", "=1.#INF", "=-1.#INF"} end
   for key, value in pairs(save) do
       data[key] = DataDumper(value, nil, not PRETTY_PRINT)
       for i, corrupt_pattern in ipairs(patterns) do
           if string.find(data[key], corrupt_pattern, 1, true) then
               error("Error saving game, corruption detected.")
           end
       end
   end
   ```

**排查方法**：
1. 直接搜存档文本：`=nan` / `1.#QNAN` / `=-1.#IND` / `=inf`。
2. 搜不到 → 说明 NaN 走了别的序列化路径（见 C2）。
3. 二分定位：把最后一次改动前后的存档各存一份，比对哪个字段先变 NaN。

**修复**：修掉产生 NaN 的源头。常见源头：除零、`math.sqrt` 负数、`0/0`、无限递归累加。**在速率计算的所有除法上加守卫**：
```lua
local denom = math.max(0.001, total_absorption)   -- 而不是直接除
local share = absorbed_damage * amt / denom
```
并在 `OnSave` 入口统一做一次 `isbadnumber` 扫描（比事后扫字符串可靠，见 C2）。

**预防**：存档写入前加一道类型钩子——序列化器遇到非有限数值直接抛错并带上"路径"（哪个实体、哪个组件、哪个字段）。

---

### 症状：C2 · NaN 检测只扫字符串，走了别的序列化路径就漏

存档损坏，但 `grep '=nan'` 什么都搜不到。反复查找不到源头。

**根因**（`mainfunctions.lua:1202-1236`）：扫描是对每个 `DataDumper` 产物做 `string.find(..., 1, true)` 的**纯文本匹配**。dev 与非 dev 分支用不同的模式串（`"=nan"` vs `"1.#QNAN"`，因为 Windows 的浮点打印格式不同）。数值已经被序列化成字符串了，所以扫字符串可行；**但如果某个表结构让 NaN 走了别的路径（比如以 key 的形式出现），就漏了。**

**排查方法**：在序列化器里插类型检查而非扫文本：
```lua
local function scan(v, path)
    local t = type(v)
    if t == "number" and (v ~= v or v == math.huge or v == -math.huge) then
        Log.Error("[NaN] %s = %s", path, tostring(v))
    elseif t == "table" then
        for k, x in pairs(v) do scan(x, path.."."..tostring(k)) end
    end
end
```

**修复**：把校验从"事后扫文本"上移到"序列化时的类型钩子"。

**预防**：同时保留两道防线——写入前的类型钩子（精确，带路径）+ 写出后的文本扫描（兜底，防序列化器本身的 bug）。两道都只在 dev 构建全量运行，发布构建保留轻量版。

---

### 症状：C3 · 组件名大小写改了 → 老存档读回丢数据

某次更新后，玩家发现装备/建造物的所有属性回到了默认值。

**根因**（`entityscript.lua:612-623`）：`AddComponent` 维护**两张表**——`lower_components_shadow` 用小写去重保证幂等，`self.components` 用**原样**存储，而 `self.components` 的 key **就是存档字段名**。所以 `AddComponent("Health")` 会让存档里出现 `"Health"` 字段；老存档里是 `"health"`，key 匹配不上 → 静默丢数据。

**排查方法**：打开存档文件，搜组件字段名的大小写：
```
["Health"] = { ... }      ← 混用大小写就是 bug
["health"] = { ... }
```

**修复**：组件名一律小写；如需对外显示名，另设 `displayname` 字段。

**预防**：在 `AddComponent` 里加断言：
```lua
assert(name:lower() == name, ("组件名 %s 含大写字母，会导致存档字段名不兼容"):format(name))
```

---

### 症状：C4 · 预制体重命名 / 合并 → 老存档里的实体静默消失

更新后，玩家世界里成片的建筑/物品不见了，没有任何报错。

**根因**：存档里记录的是 `record.prefab`（预制体名字符串）。读档时 `SpawnPrefab(record.prefab)` 找不到对应工厂就返回 nil，这条记录被静默跳过。`gamelogic.lua:352-366` 有一张 `replace` 表专门做映射：
```lua
local replace = {
    ["farmplot2"]   = "fast_farmplot",
    ["farmplot3"]   = "fast_farmplot",
    ["sinkhole"]    = "cave_entrance",
    ["cave_stairs"] = "cave_entrance",
}
```
**任何预制体改名/合并，都必须在这张表里留映射。**

**排查方法**：读档时统计"spawn 失败的记录数"，> 0 就打日志：
```lua
local failed = 0
for prefab, ents in pairs(savedata.ents) do
    for _, v in ipairs(ents) do
        if SpawnPrefab(v.prefab or prefab, v.skinname, v.skin_id) == nil then
            failed = failed + 1
            Log.Warn("[save] 预制体 %s 不存在，记录被跳过", v.prefab or prefab)
        end
    end
end
```

**修复**：改名时同步在 `replace` 表加映射；更好的是**永不删除旧预制体**，让它变成一个不可见的兼容壳（转发到新预制体）。

**预防**：把 `replace` 表的维护纳入发版检查清单。改名 PR 如果没改这张表，直接拒绝合并。

---

### 症状：C5 · 存档引用表与实体 ID 失配 → 引用解析为 nil

读档后跟随的宠物消失了 / 背包绑定丢失 / AI 的攻击目标为空。控制台有 `Missing reference:` 日志。

**根因**（`entityscript.lua:1803` 附近的引用表机制）：只有"被别人引用"或"自己引用了别人"的实体才会被写入 `record.id`：
```lua
for k, v in pairs(references) do
    if saved_ents[k] ~= nil then saved_ents[k].id = k
    else print("Missing reference:", v, "->", k) end
end
```
`Missing reference` 说明被引用的 GUID 在这次存档的实体集合里找不到——通常是"引用的实体已经死了/被移除了，但引用它的东西还在存档里"。

**排查方法**：统计每次存档的 `Missing reference` 数量，并与上上次对比——数量增长说明有组件在存无效引用。

**修复**：
1. **存引用前校验实体有效性**：
   ```lua
   function MyComponent:OnSave()
       if self.target ~= nil and self.target.entity:IsValid() then
           return { target = self.target.GUID }, { self.target.GUID }
       end
       return {}
   end
   ```
2. **读档时容错**：`LoadPostPass` 里 `local rec = newents[data.target]; self.target = rec and rec.entity or nil`，拿不到就重新找一个（按标签/位置重新绑定），不要留 nil。

**预防**：把所有跨实体引用收敛到一个 `references` 出口，方便统一做有效性过滤；并在读档后做一次"空引用审计"。

---

### 症状：C6 · 跨版本迁移缺失 / 标签在读档时不更新

读档后物品的状态标签不对——已经腐坏的食材仍带 `fresh` 标签，导致玩家吃到"新鲜食物"的额外收益。

**根因**（`perishable.lua:1` 的 `onpercent` 属性设置器回调）：

```lua
local function onpercent(self)
    if self.perishremainingtime ~= nil then       -- ★ 守卫
        local percent = self:GetPercent()
        if percent >= TUNING.PERISH_FRESH then
            if not self.inst:HasTag("fresh") then ... AddTag("fresh") ... end
        ...
```

`onpercent` 在 `self.percent = x` 赋值时触发，但有 `perishremainingtime ~= nil` 的守卫。**如果读档顺序是先设 `percent` 后设 `perishremainingtime`，第一次 `onpercent` 会因为守卫而什么都不做——标签不会更新。**（推断：DST 的 `OnLoad` 通常先恢复 `perishremainingtime`，所以实际没暴露；但这依赖调用顺序，是脆弱耦合。）

另一类跨版本问题：组件被删除后，存档里还有它的数据。DST 有个专门机制兜底（`SetPersistData`）：
```lua
if data and data.add_component_if_missing then
    for k, v in pairs(data) do
        if self.components[k] == nil and type(v) == "table" and v.add_component_if_missing then
            self:AddComponent(k)        -- 自动补回被删的组件
        end
    end
end
```
用法是组件的 `OnSave` 返回 `{ add_component_if_missing = true, ... }`。读档时若该组件已被删除，框架会自动补回，让它有机会执行 `OnLoad` 做数据迁移。

**排查方法**：读档后断言标签与数值一致：
```lua
-- perishable 读档后自检
assert(inst.components.perishable ~= nil)
assert(inst:HasTag("spoiled") == (inst.components.perishable:GetPercent() < 0.2))
```

**修复**：把标签更新从属性设置器里拿出来，改成显式方法，在初始化、读档、以及每次 percent 变化后**都调一次**：
```lua
function Perishable:UpdateSpoilageTags()
    local percent = self:GetPercent()
    self.inst:TagRemove("fresh"); self.inst:TagRemove("stale"); self.inst:TagRemove("spoiled")
    if self.perishremainingtime == nil then return end
    if percent >= TUNING.PERISH_FRESH then self.inst:AddTag("fresh")
    elseif percent >= TUNING.PERISH_STALE then self.inst:AddTag("stale")
    else self.inst:AddTag("spoiled") end
end
```

**预防**：
1. 需要在读档后生效的副作用，一律实现成显式方法并在 `OnLoad` 末尾调用，**不要只依赖属性 setter**。
2. 所有持久化字段加 `saveversion`；字段重命名必须在迁移映射表里留条目。
3. 需要被删除组件读档时迁移的数据，标记 `add_component_if_missing = true`。

---

## D. 数值与状态同步

### 症状：D1 · `and / or` 三元陷阱：返回 0 的函数被跳过

某件"风度为 0"的装备，其风度计算走了错误的分支——用了默认函数的返回值，而不是自定义钩子的 0。

**根因**（`sanity.lua:526`）：

```lua
local item_dapperness = self.get_equippable_dappernessfn ~= nil
    and self.get_equippable_dappernessfn(self.inst, equippable)
    or equippable:GetDapperness(self.inst, self.no_moisture_penalty)
```

Lua 里 `and` 优先级高于 `or`，整行读作 `(fn ~= nil and fn(...)) or default(...)`。**`dapperness == 0` 的装备（大量存在！）会走进 `or` 分支**——用了错误的函数。

**注意 `combat.lua:846` 的同类写法"恰好安全"**：
```lua
return weapon ~= nil and weapon.components.weapon.attackrange ~= nil
    and math.max(0, self.attackrange + weapon.components.weapon.attackrange)
    or self.attackrange
```
因为 `math.max(0, ...)` 结果 ≥ 0，而 **Lua 里 0 是 truthy**。**但这是运气好，不是设计好。**

**排查方法**：全局搜索 `and` 与 `or` 出现在同一表达式的行：
```
grep -n "and.*\n.*or " --include="*.lua" -Pz
```
逐条问："如果中间结果是 `nil` / `false` / `0`，会发生什么？"

**修复**：涉及数值计算一律写显式分支。
```lua
-- ✅
local item_dapperness = equippable:GetDapperness(self.inst, self.no_moisture_penalty)
if self.get_equippable_dappernessfn ~= nil then
    item_dapperness = self.get_equippable_dappernessfn(self.inst, equippable)
end
```

**预防**：把"Lua 的 `x and y or z` 只有在 y 保证非 nil/false 时才等价于三元运算符"写进团队速查卡。加 lint：禁止 `and` 与 `or` 混用于返回值表达式。

---

### 症状：D2 · 护甲吸收率是 nil（移植到强类型语言时崩溃或算错）

> **同源**：附录 `N2` 记录了同一根因的另一面（同为 `health.lua:628` 的 absorb 未做 nil 保护）。两者是**同一条缺陷**，编号不同只为区分侧重点。

从 Lua 移植到 C#/C++ 后，伤害计算结果完全错误——减伤率异常高，或者直接空引用崩溃。

**根因**（`inventory.lua:408`）：`GetAbsorption` 在 `CanResist` 返回 false 时返回 **nil**。
```lua
absorbers[v.components.armor] = v.components.armor:GetAbsorption(attacker, weapon)
-- absorbers[armor] 可能是 nil 值
for armor, amt in pairs(absorbers) do
    absorbed_percent = math.max(amt, absorbed_percent)
    total_absorption = total_absorption + amt
end
```

**在 Lua 里这是安全的**，但依赖了一个微妙的语义：`t[k] = nil` 等价于删除该键，所以 `pairs` 根本遍历不到那个 armor。

**在强类型语言里这是错的**：`Dictionary<Armor, float?>` 会把 null 算进 `max` 里。

**排查方法**：打印 `absorbers` 的实际键数量与 `min(durability)` 的护甲数量对比。

**修复**：移植时必须显式过滤 nil。
```cpp
float absorbed_percent = 0, total_absorption = 0;
for (auto& [armor, amt] : absorbers) {
    if (amt == nullptr) continue;          // ★ 移植时必须显式加这一行
    absorbed_percent = std::max(*amt, absorbed_percent);
    total_absorption += *amt;
}
```

**另一层问题：`resistance` 的短路遍历**（`inventory.lua` 的第一层循环）：遍历 `EquipSlot.FromID(1..N)`，第一个匹配的 `resistance` 就 `return 0, nil`（完全免疫）。**如果玩家同时戴了两件都提供 `resistance` 的装备，只有槽位 ID 最小的那个会触发 `ResistDamage`**，另一个的副作用（音效、扣耐久、CD）漏触发。

**预防**："用第一个匹配就返回"的短路改成"收集所有匹配的 resistance，累加效果"。强类型语言移植时，所有"可能为空的数值"都要显式声明可空并过滤。

---

### 症状：D3 · 环境惩罚速率没有上限 → 玩家瞬间冻死，保暖装备完全失去意义

冬天站在空地上，1 秒内掉光体温；穿了顶级毛皮大衣也一样。

**根因**：环境温度 −20 °C、当前体温 35 °C，差值 −55。若直接用它当速率就是 −55 °C/s → 0.6 秒冻死。DST 的做法是在算出差值后用**速率上限**钳制（`temperature` 的第 9 阶段）：
```lua
if ambient_temperature >= STARTING_TEMP then
    if self.delta > 0 then
        self.rate = math.min(self.delta, SEG_TIME / (SEG_TIME + summerInsulation))
    else
        self.rate = math.max(self.delta,
            self.current >= overheattemp and -THAW_DEGREES_PER_SEC or -WARM_DEGREES_PER_SEC)
    end
elseif self.delta < 0 then
    self.rate = math.max(self.delta, -SEG_TIME / (SEG_TIME + winterInsulation))
else
    self.rate = math.min(self.delta,
        self.current <= 0 and THAW_DEGREES_PER_SEC or WARM_DEGREES_PER_SEC)
end
```

**排查方法**：在积分前打印 `self.delta` 与 `self.rate`，看钳制是否生效。典型症状是 `rate` 的绝对值等于 `delta`（没被钳）。

**修复**：所有"环境差值 → 速率"的换算都必须有上限，且上限用**意图表达式**写（`SEG_TIME / (SEG_TIME + insulation)` 读作"保温把降温速率按比例削减"）。

**验证方法**（`gameplay-numbers.md` §4.4 的时间线表）：

| 配置 | 变冷速率 | 到 0 °C | 死亡 |
|---|---|---|---|
| 无保暖 | −1.0 °C/s（受速率上限限制，不是 55） | 35 秒 | **155 秒** |
| 一件 LARGE(240) | −30/(30+240) = −0.111 °C/s | 315 秒 | 435 秒 |
| 两件 LARGE(480) | −30/(30+480) = −0.059 °C/s | 595 秒 | 715 秒 |

**预防**：调任何"环境速率"前，先手算"裸速率"是多少。如果裸速率能在 10 秒内致死，说明缺钳制。

---

### 症状：D4 · 复合累加器不同步（温度与湿度的单向依赖被打破）

玩家在火边已经干了很久，湿度条却一直下不去；或者湿着烤火，但体温上升比预期慢。

**根因**：温度与湿度是两个独立累加器，通过一个单向依赖耦合——**湿度组件的干燥速率依赖温度组件累加出来的 `externalheaterpower`**（`temperature` 累加的第 8 阶段）。这意味着温度必须先于湿度完成累加。

如果：① 两个组件在同一个 `OnUpdate` 批次里的执行顺序不固定；② 或某个代码路径直接在温度累加之前读 `externalheaterpower`——湿度就会用上一帧的值，产生 1 帧的滞后，在快速切换时看起来像不同步。

**干燥速率量级（可用来判断是否合理）：**

| 状态 | 速率 | 从满湿到干 |
|---|---|---|
| 自然干燥 | 0.1/s | 1000+ 秒 |
| 火边 | ≈ 5/s | **20 秒** |

**排查方法**：在同一帧打印两个组件的累加顺序与 `externalheaterpower` 的值：
```lua
-- temperature.lua 累加末尾
print("[order] temp", self.inst.GUID, self.externalheaterpower, TheSim:GetTick())
-- moisture.lua 消费时
print("[order] moist", self.inst.GUID, self.current, TheSim:GetTick())
```
看 moist 的 tick 是否总是 ≥ temp 的 tick。

**修复**：给依赖链定一个**显式顺序**（例如在世界的更新顺序表里给组件排序号，或让湿度组件订阅 `temperaturedelta` 事件而不是在同批次里直接读）。

**预防**：把"温度 → 湿度"这条链写成单向依赖并在注释里标注：**修改温度累加时不要引入对湿度的反向读取，否则会产生振荡**。

---

### 症状：D5 · 减伤护符对火/冻/饿无效

> **同源**：附录 `N3` 记录了同一根因的另一面（同为环境类伤害不走 externalreduction 的短路）。两者是**同一条缺陷**，编号不同只为区分侧重点。

玩家反馈"我戴了减伤 30% 的护符，为什么站在火里掉血还是那么快"。

**根因**（`health.lua:613` 的 `DoDelta` 第 4 阶段）：

```lua
amount = afflicter ~= nil
     and math.min(0, amount + self.externalreductionmodifiers:Get())
     or amount
```

**守卫条件是 `afflicter ~= nil`。** 也就是说**环境伤害（`cold` / `hot` / `hunger` 这些 afflicter 为 nil 的调用）完全绕过 `externalreductionmodifiers`**。

（顺带：`math.min(0, ...)` 保证减伤永远不会把负向 delta 变成治疗——这是这个写法"恰好安全"的原因，因为 `math.min(0,...)` ≤ 0 且 0 是 truthy。但守卫条件是实质性的行为限制。）

**排查方法**：在 `DoDelta` 入口打印 `afflicter` 与 `externalreductionmodifiers:Get()`。

**修复**：这是**原版行为不是 bug**，但你的实现应该显式化。如果要允许减伤对环境伤害生效，把守卫改成一个显式的"减伤适用域"参数：
```lua
local function ApplyReduction(amount, afflicter, reduction, applies_to_env)
    if amount >= 0 then return amount end
    if afflicter ~= nil or applies_to_env then
        return math.min(0, amount + reduction)
    end
    return amount
end
```
并在 UI 上明确告知玩家适用范围——**这是设计决策，必须对玩家可见**。

**预防**：任何"有条件生效"的乘数，都要在 UI/描述里写明条件；否则玩家永远认为它是 bug。

---

### 症状：D6 · 32 位无符号整数传过去变成负数

预制体哈希、GUID、资产 ID 在客户端变成负数；或超过 2^31 的 ID 全部错位。

**根因**（`netvars.lua:8-11` 的类型表列了 `net_uint 32-bit unsigned integer [0..4294967295]`）：Lua 5.1 只有 double 一种数，靠 IEEE754 double 的 53 位尾数精确表示 32 位整数。但：

- **Lua 5.3+ 变成整数/浮点双类型**，`tonumber("4294967295")` 返回整数子类型，绑定代码若假设"所有数都是 double"行为就变。
- **Unity `MonoBehaviour` 的 `float` 只有 24 位尾数**，传大整数会掉精度。

**排查方法**：打印 `(v > 2147483647)` 的检查结果，以及绑定层的实际声明类型。

**修复**：绑定里显式声明宽度，`static uint32_t` / `static uint64_t`，不要图省事全用 `double` 或 `float`。跨语言边界处的序列化统一用定点而非浮点。

**预防**：所有网络 ID 类字段用字符串哈希（`net_hash`，32 位有符号哈希空间）而不是原始 uint32，能天然避开符号问题。

---

## E. 世界生成

### 症状：E1 · 地图存在不可达区域（锁的钥匙表被同名覆盖）

玩家被一堵打不开的门永久挡住；或者需要钥匙的钥匙不在该分支的任何前置任务里。

**根因**（`map/lockandkey.lua`）：`LOCKS.TREES` 在 `LOCKS_KEYS` 里**定义了两次**：
```lua
[LOCKS.TREES] = { KEYS.AXE, KEYS.FIRE },     -- 第 219 行
...
[LOCKS.TREES] = { KEYS.AXE, KEYS.PIGS },     -- 第 254 行 ← 后者生效
```
第一组定义被**静默覆盖**。源码自己在第 486 行留了注释承认校验有盲区：*"NOTE: This will **NOT** catch it if the typo is in the last key in the list. ... But it's better than nothing..."* 而且 498–510 行有一个 `SKIP_THESE_MISSING_KEYS_AND_LOCKS` 白名单，承认有若干 key/lock 被引用但从未声明（`SILK`、`ROCKS`、`TALLBIRDS`、`SWAMP` 等），只在 `BRANCH == "dev"` 时才会在元表 `__index` 里报错。

**规则本身只有一条**（`lockandkey.lua:171-172` 注释）：*"锁只要有**任意一把**对应的钥匙就解开；但一个任务要解锁，必须**所有**锁都解开。"*

**排查方法**：写一个独立校验脚本（不要依赖原版的）：
```lua
for lock, keys in pairs(LOCKS_KEYS) do
    for _, k in ipairs(keys) do
        assert(KEYS_ARRAY[k], ("锁 %s 引用了未声明的钥匙 %s"):format(lock, tostring(k)))
    end
end
```
再查反向：每个 `KEYS_ARRAY` 里的钥匙是否至少被一个任务 `keys_given` 发出。
**还要查正向重复**：`LOCKS_KEYS` 内部是否有同名键（这是本缺陷的直接成因，原版的断言查不到）。

**★ 重要修正（逐行双向grep 后核实）**：上述重复定义**在原版任务集下不会导致玩家不可达**。
- `AXE` 仍在生效的钥匙集中，且由首个任务发放（`forest.lua:9-10`，`locks=LOCKS.NONE`）
- 三个使用 `TREES` 的任务其 `keys_given` 都含 `PIGS`
- 但 **`KEYS.FIRE` 全仓从未被任何 task 发放** ——它成为一把「设计上发不出来的死钥匙」

所以本条缺陷的真实后果是：
1. `LOCKS_KEYS`侧**缺少重复检查**（结构性隐患）
2. `FIRE` 是死钥匙（配置冗余）
3. **若模组想用「FIRE 开路」才会立即退化为拓扑级不可达**

> **教训**：评估一条缺陷时，必须**双向验证**——
> 既要确认"代码确实有 bug"，也要确认"这个 bug 在当前配置下是否真的触发"。
> 只看代码结构就断言"玩家不可达"，会误报。

**排查方法（可达性）**：对生成的图做 BFS——从出生点出发，看每个锁节点能否在其所有锁都满足的条件下到达。

**修复**：改成**显式的声明式配置 + 启动期严格校验**（缺一个就崩溃），而不是容错跳过。原版的容错策略是历史包袱——注释明说是"怕改变世界生成结果、影响玩家体验"。

**预防**：**永远不要在同一张表里写重复键**。用数组 + 校验的方式声明，并在 CI 里跑"无重复键 + 未声明引用 双向检查"两个测试。

---

### 症状：E2 · 地图缺少必需资源（静默放弃，玩家找不到东西）

玩家报告"地图上没有 XX"；开发者复现不了，因为只打了一行 `print`。

**根因**：至少三处静默失败，全部只 `print` 不计入校验：

| 位置 | 行为 |
|---|---|
| `graphnode.lua:330` `Node:PopulateVoronoi` | `if #points_x < pos_needed then return end` → **整个节点的内容物丢失** |
| `forest_map.lua` 的 `object_layout.ReserveAndPlaceLayout` | `if rcx == nil then return end` → 场景件丢失 |
| `InsertAdditionalSetPieces` | `if choice == nil then print("Warning!...") break end` → 场景件没地方放 |

**排查方法**：给每处静默失败加计数，然后看统计表：
```lua
-- ❌ 只打 print
if #points_x < math.floor(pos_needed) then
    print(self.id.." Didnt get enough points for all prefabs, got "..#points_x.." need "..pos_needed)
    return
end
```

**修复**：留下可查询的痕迹，并在验收阶段作为警告输出。
```lua
-- ✅
if #points_x < math.floor(pos_needed) then
    local w = self.stats.silent_drops[self.id] or 0
    self.stats.silent_drops[self.id] = w + 1
    self.stats.dropped_prefabs = self.stats.dropped_prefabs + (pos_needed - #points_x)
    Log.Warn("[worldgen] %s 丢弃 %d 个 %s", self.id, pos_needed - #points_x, self.id)
    return false    -- ★ 返回 false，让上层校验感知到
end
```

再加上原版的**三重来源求和**校验（`forest_map.lua:926-959`），这是唯一在内容物层面做的验收：
```
来源 1：关卡级 level.required_prefabs
来源 2：任务/房间级（房间的会被任务级合并，任务级的会被图级递归合并）
来源 3：海洋房间 ocean_population
判定：实际生成数量 < 求和数量 → 失败重试
```

**预防**：静默失败必须结构化返回原因，前端据此给出可操作的提示（"你的世界设置禁用了必需资源 XX，请调整设置"），而不是只让玩家困惑。

---

### 症状：E3 · 世界生成耗时过长（50 秒才报一个错）

生成世界时进度条卡住几十秒，最后报错"生成失败"，且错误信息毫无指向性。

**根因**：两个成本相乘。

1. **单次生成慢**：Lloyd 松弛是 O(P × S)（每点找最近站点）。100 次迭代在 425×425 世界上要 2–8 秒。
2. **重试代价**（`worldgen_main.lua:379`）：
```lua
local try = 1
local maxtries = 5
while savedata == nil do
    savedata = forest_map.Generate(...)
    if savedata == nil then
        if try >= maxtries then return nil end
        try = try + 1
        collectgarbage("collect")
        WorldSim:ResetAll()
    end
end
```
`maxtries = 5`，每次失败都 `collectgarbage("collect")` + `WorldSim:ResetAll()`。**如果单次 10 秒，最坏情况 50 秒才给玩家一个错误。**

**阶段耗时预算（用于判断是否超标）：**

| 阶段 | 目标耗时 | 主要开销 |
|---|---|---|
| 任务解析 + 图构建 | < 50 ms | 纯表操作，约 1000 次深拷贝 |
| Voronoi + Lloyd ×100 | **2–8 s** | O(P × S)，**唯一的大头** |
| 地块烘焙 | 0.5–2 s | O(W × H)，425² ≈ 18 万格 |
| 连通性修复 + 洪水填充 | 0.3–1 s | O(W × H) |
| 散布 | 1–3 s | O(P) + 权重抽样 O(N) 预处理 |
| 校验 | < 100 ms | 几次数组扫描 |
| **合计** | **4–15 s** | |

**排查方法**：
1. **先把 `maxtries` 改成 1**，看单次生成的真实耗时——否则 5 次重试会把真实耗时掩盖掉 5 倍：
   ```lua
   local try, maxtries = 1, 1        -- 调试期改成 1
   ```
2. 对照阶段耗时预算表（见 `debugging.md` §1.6）判断超时在哪一段。**Lloyd 松弛是唯一的大头**（目标 2–8 秒，占了预算的绝大部分）。
3. 判断是算法问题还是重复问题：把 Lloyd 迭代次数从 100 改成 1，看耗时是否线性下降到 1/100。**线性下降 = 算法问题（O(P×S)）；不降 = 有别的固定开销（深拷贝、JSON 序列化等）。**
4. 打印单次生成的站点数 `S` 与格点数 `P`，用 `P × S` 对照耗时验证是否真的在 O(P×S)。

**修复**：把 Lloyd 的最近站点查询降到 O(1) 附近——用**网格空间哈希**（32×32 的桶，每桶预存覆盖范围内的候选站点），整体降到 O(P + S)，**100 次迭代从 8 秒降到 1 秒以内**。

**预防**：
1. 世界生成跑在**独立离线 VM**（`worldgen_main.lua`），不在游戏主循环里——失败重来的代价可控。
2. 失败原因**结构化返回**：`return nil, {reason="missing_required_prefab", prefab="X", expected=3, got=0}`。
3. 前端据此给出可操作提示，而不是"生成失败"。

---

### 症状：E4 · 世界生成无法复现（同种子结果不同）

同一个种子生成两次，地图不一样；或者同一个存档在不同机器上加载出不同结果。

**根因**：确定性的三大破坏者。

1. **`pairs()` 的遍历顺序**：`LinkNodesByKeys` 里 `for taskid, node in pairs(unusedTasks)` 的顺序依赖 Lua 表的哈希布局。同一份数据、同一个种子，不同 Lua 版本可能给出不同结果。
2. **`WorldSim:ResetAll()` 不完全重置 RNG**：每次重试 `math.random` 的状态已经前进了——"第 3 次尝试"和"第 1 次尝试"在同样逻辑下会得到不同的随机数。
3. **`GetRandomItem` 对表长度敏感**：`for k, v in pairs(t)` 数个数——如果表在遍历中被修改，计数会错。

**排查方法**：跑两次，比对生成结果的哈希：
```lua
local function hash_world(w)
    local h = 5381
    local function mix(s) h = (h * 33 + string.byte(s)) % 2^32 end
    for _, e in ipairs(ordered_entities) do mix(e.prefab); mix(tostring(math.floor(e.x*100))) end
    return h
end
```
两次不同 → 有非确定性源。

**修复**：用自己的 PRNG（不是 `math.random`），把种子显式传入**每一个**随机调用点；遍历用有序数组而不是哈希表。

```lua
local Rng = Class(nil, function(self, seed)
    self.state = seed
end)
function Rng:NextInt(n)                    -- xorshift32
    local x = self.state
    x = (x ~ (x << 13)) & 0xFFFFFFFF
    x = x ~ (x >> 17)
    x = (x ~ (x << 5)) & 0xFFFFFFFF
    self.state = x
    return x % n
end
```

**预防**：把"用同一个种子 + 同一个版本的代码 → 逐字节相同的地图"作为 CI 里的回归测试项。

---

### 症状：E5 · 临时连通地块没被清理 → 玩家走进虚空

玩家走进一块"设计上不存在"的区域，从虚空掉下去。

**根因**：`FAKE_GROUND` 这类"临时连通"靠事后清理。源码注释自己都在叹气：*"Sigh, so the `ForceDisconnected` tag does not actually keep something in the void disconnected from the mainland (e.g. Atrium)"*。这个临时地块靠 `DetectDisconnect` 事后清理——**如果你的清理逻辑漏了，玩家就能走进设计上是虚空的地方。**

**排查方法**：`forest_map.lua:853-867` 的 `DetectDisconnect()` 返回的孤立地块数 > 全图 5% 就重试。这个校验是生成后的**兜底**，不是清理保障。

**修复**：
1. 临时地块用**显式的清理步骤**（不是"靠后置检测顺便清理"），并把它列进生成 pipeline 的必做项。
2. 在 `DetectDisconnect` 之后加第二道：把残留的 `FAKE_GROUND` 地块强制转为不可通行。

**预防**：所有"临时/占位"状态都必须有显式的 finalizer，且在 pipeline 的阶段清单里列出。生成后验收要包含"占位状态残留数 == 0"。

---

### 症状：E6 · 新地块类型加进来，所有预制体默认都能长在上面

新加一种地块（比如"雪原"）后，蘑菇长在了不该长的地方、Boss 刷新在了不该刷的地方。

**根因**（`map/terrain.lua`）：`TERRAIN_FILTER` 是**逐预制体的排除列表（黑名单）**，不是规则系统。新加地块意味着**所有预制体默认可以在上面生长**，除非你显式把每个相关预制体加进黑名单。原版为此打了一个补丁（`terrain.lua:150-154`）把 `ARCHIVE` / `VAULT` / `VAULT_CLEAN` 加进**所有**条目。

还有一个相邻问题（`forest_map.lua:896`）：
```lua
local tiletype = WorldSim:GetVisualTileAtPosition(x, y)
-- Warning: This does not quite work as expected. It thinks the ground type id is in
-- rendering order, which it totally is not!
if TileGroupManager:IsImpassableTile(tiletype) then
```
**渲染顺序 ≠ 逻辑顺序。** 原版用一个"按渲染顺序编号的地块 id"去查按逻辑顺序分组的 `TileGroups`，这是靠巧合能工作。

**排查方法**：新加地块后，遍历 `TERRAIN_FILTER` 的每一条，检查是否需要追加新地块 id。写个脚本对比"哪些预制体的新地块黑名单是空的"。

**修复**：改成**白名单 + 默认拒绝**，或者引入地块属性位（可种植 / 可建造 / 可通行 / 水），让规则由地块自己声明而不是由预制体列举。

**预防**：地块 id 按功能段分配（LAND / NOISE / OCEAN / IMPASSABLE 各 ≥256 宽），并把 `*_NOISE` 段的解析函数挂在 `TileManager.AddTile` 一处。新增地块只需在那一处注册。

---

## F. 性能

### 症状：F1 · 事件广播量爆炸（单帧几万次）

玩家越多、实体越密集越卡；单机正常、4 人联机就掉帧。

**根因**：`TheWorld` 是事实上的全局总线。任何一个 `TheWorld:PushEvent(...)` 的监听者数量 = 当时活着的相关实体数。当实体数上千时，单次广播就是上千次回调。

**排查方法**：统计单帧的广播量：
```lua
-- 在 PushEvent_Internal 入口加计数
_G.__evt_count = (_G.__evt_count or 0) + 1
-- 每帧末尾打印
if tick % 30 == 0 then print("events this frame:", _G.__evt_count); _G.__evt_count = 0 end
```
并按事件名分类统计，找出贡献最大的几个。

**修复**：
1. **加"脏聚合"**：同一帧内对同一源实体的重复事件合并为一次处理。
2. **降频**：状态类事件（"光照变了"）改成每 N 刻或变化超过阈值才广播。
3. **缩小事件作用域**：能挂在局部实体上的事件不要挂 `TheWorld`。
4. **休眠兜底**：不在活动区的实体不订阅高频事件（DST 的休眠机制砍掉了 90% 的这类开销）。

**数量级参考：**

| 指标 | 正常 | 需要优化 | 一定有问题 |
|---|---|---|---|
| 单帧事件广播次数 | < 500 | 500–5000 | **> 5000** |
| 单帧空间查询返回实体数 | < 500 | 500–2000 | **> 2000** |
| 活跃定时器总数 | < 500 | 500–2000 | **> 2000** |
| 活跃协程数 | < 200 | 200–800 | **> 800** |
| 单实体定时器数 | 1–3 | 4–10 | **> 10** |
| 单实体事件监听数 | 5–20 | 20–50 | **> 50** |

**预防**：给"单帧广播次数"设一个开发构建的告警阈值，超了就打堆栈。

---

### 症状：F2 · 上百只怪在同一刻集体重评（脑的思考相位未散布）

生成 100 只同种怪后，每隔固定周期就出现一次明显的集体动作（集体转向、集体停顿），帧率周期性抖动。

**根因**：所有脑用 `period * (0.5 + random())` 做初始相位散布，但**如果所有脑都是同一种模板、且 PRNG 序列相同或相位计算放在 `Brain:OnStart` 里顺序执行**，相位可能高度相关。

**排查方法**：打印 100 只怪的 `wake_time` 分布：
```lua
print(brain:GetSleepTime(), inst.GUID)
```
如果它们聚集在某几个值上，就是相位相关。

**修复**：把相位散布改成**实体 GUID 派生的确定性哈希**，保证既分散又可复现：
```lua
local phase = (inst.GUID * 2654435761 % 1000) / 1000   -- 黄金分割散布
inst.brain = self.brainfn()
inst.brain.phase_offset = phase * period
```

**预防**：所有"周期性做某事"的系统（脑、状态机 tick、刷怪检查）都必须有相位散布，且相位来源要与实体 ID 绑定而不是与生成顺序绑定。

---

### 症状：F3 · 状态图永不休眠（`onupdate` 空转）

加了 UI/音效之后性能掉一个数量级；远处大量实体仍在消耗 CPU。

**根因**（`stategraph.lua:109` 的 `Update`）：

```lua
if self.currentstate.onupdate then
    return 0.0                    -- ← 每帧
elseif time_to_sleep then
    return time_to_sleep           -- ← 睡到下一个 timeline 点
else
    return None                    -- ← 冬眠
end
```

**一个 `idle` 状态如果写了空的 `onupdate = function(inst, dt) end`，性能立刻掉一个数量级**——状态图永远返回"每帧更新"，即使实体已经离玩家很远。

**排查方法**：统计有多少状态图返回 `0.0`：
```lua
-- StateGraphWrangler:Update 里
if self:Update(current_tick) == 0.0 then n_alwaysupdaters = n_alwaysupdaters + 1 end
```
把这个数与活跃实体数对比。

**修复**：把"持续判断"从 `onupdate` 改成时间点：
```
onenter   → 状态开始的瞬间（起冷却、播动画、设目标）
timeline  → 过程中的具体帧（音效、伤害帧、位移帧、重复触发帧）
ontimeout → 固定时长后（换状态）
onexit    → 离开的瞬间（清理、撤销未完成意图）
```

**判断标准：`onenter` / `onexit` / `ontimeout` 是"点"，`timeline` 是"帧"，`onupdate` 是"每帧"。能写成时间点的一律不要写成 `onupdate` 里的时间比较。**

**预防**：把这条写进状态图 review 清单。空 `onupdate` 一律删掉。

---

### 症状：F4 · 实体数量失控 / 休眠机制没有生效

世界玩久了越来越卡；存活实体数持续增长但没人删。

**根因**：没有休眠/清理机制，或休眠的判定范围太窄。

**数量级参照（DST）：** 425×425 世界约 **3000 个实体**，但同时活跃的通常只有 **100–200 个**。休眠机制砍掉了 **90% 以上**的 AI 开销。

休眠机制的两级语义（`entityscript.lua:1120` / `:1135`）：
```lua
function EntityScript:_DisableBrain_Internal()
    self._braindisabled = true
    self.brain:_Stop_Internal()
    self.brain = nil              -- ★ 脑对象被丢弃，内存回收
    -- SGManager:Hibernate(inst.sg)、EmitterManager:Hibernate(inst.emitter)
end
function EntityScript:_EnableBrain_Internal()
    self.brain = self.brainfn()   -- ★ 从工厂函数重新构造
end
```

**"销毁 + 工厂重建"而不是"停用 + 恢复"，是有意的**：一个正在追玩家的蜘蛛离开模拟范围时，它的脑里保存着 `combat.target`、各种 `idx`、事件监听。恢复这些状态的正确性远难于重建。重建还有额外收益——`Brain:_Start_Internal` 里 `self.modpostinitfns` 会在重建时重新应用，模组对脑的修改不会因为睡眠而丢失。

**排查方法**：
1. 打三线数据：**存活实体数 / 活跃实体数 / 休眠实体数**。健康的状态是 3000 / 150 / 2850。如果休眠数长期接近 0，休眠机制就是坏的。
2. 抽查活跃实体：打印它们的 GUID、prefab、与玩家的距离。**距离玩家 500 单位以外的实体出现在活跃列表里 = 休眠判定半径太窄。**
3. 检查 limbo 状态：被 `RemoveFromScene` 移出场景的实体**不一定会被恢复**。看 `OnEntityWake` 里有没有 `if not inst:IsInLimbo()` 这样的守卫，以及 limbed 的实体在回到场景时有没有走唤醒路径。
4. 检查"反复唤醒/休眠抖动"：把每个实体的休眠次数打点。如果一个实体每分钟睡眠 5 次以上，是判定边界在抖动（通常是"半衰期"边界没有迟滞）。
5. 检查 `tickwaiters` 分桶是否按 tick 而不是按实体——按实体扫列表会让唤醒退化成 O(N)。

**修复**：
1. 实现两级休眠：`tickwaiters[t]`（睡到第 t 刻再唤醒，**按目标 tick 分桶**，避免每次唤醒都 O(N) 扫列表）+ `hibernaters`（完全不访问，只有事件/唤醒能叫醒）。
2. 放宽休眠判定半径，并给半径加迟滞（避免边界抖动）。
3. 遍历更新列表时**必须先快照**——源码注释（`NOTES(JBK)`）说明了原因：*"We need to make a copy of the keys to safely iterate over the table because brains will remove and add onto the self.updaters table during iteration."* 遍历期间一个脑的攻击行为可能杀死另一个脑。

**预防**：定期打点"存活实体数 / 活跃实体数 / 休眠实体数"三线图。**AI 的规模问题从来不是"节点太多"，而是"不该跑的还在跑"。**

---

### 症状：F5 · 空间查询在每帧对每个实体调用（O(N×M)）

实体越多越卡，且卡顿程度与实体数的**平方**成正比。

**根因**：`TheSim:FindEntities(x, y, z, radius, ...)` 每帧在每个实体上调用就是 O(N×M)。而且它**每次调用都返回一个实体数组**——在 Lua 侧意味着每次调用都创建一个 table 数组并填充（`simutil.lua:35/48/229/235/241/482` 全是这个函数）。425×425 世界 3000 个实体，单次全图查询不可接受。

**排查方法**：统计每帧 `FindEntities` 的调用次数与总返回实体数。

**修复**：按优先级：
1. **缩小半径**（优先，最省事）
2. **降低频率**：每 10 刻查一次并缓存结果
3. **加空间网格 / 四叉树**（首选，从根上解决）

```lua
-- ❌
function MyComponent:OnUpdate(dt)
    for _, e in ipairs(TheSim:FindEntities(x, y, z, 1000, {"thorn"})) do ... end
end

-- ✅ 降低频率 + 缩小半径 + 缓存
function MyComponent:OnUpdate(dt)
    self.querytick = (self.querytick or 0) + 1
    if self.querytick % 10 == 0 then
        self.nearby = TheSim:FindEntities(x, y, z, 20, {"thorn"}, self.inst)
    end
    for _, e in ipairs(self.nearby or {}) do ... end
end
```

如果用的是 C++/C# 引擎，提供**迭代器式接口**而非返回数组，把遍历在原生侧完成：
```cpp
for (auto& e : Sim.EachEntityNear(x, y, z, r)) { ... }
```

**预防**：`FindEntities` 封装成一个带缓存的查询服务，调用方拿不到原始函数。

---

### 症状：F6 · `dryRun` 侧的副作用（"看一眼"改变了状态）

打开植物状态的 UI 之后，植物的养分/压力状态自己变了。

**根因**（`components/farmplantstress.lua:90` 的 `GetStressDescription`）：它会**再次调用所有压力测试函数**，这次传 `apply = false` → `not apply = true` → `dryRun = true`（`CycleNutrientsAtPoint` 的第三个布尔）。如果 `farming_manager` 的实现有任何缓存写入（在 dryRun 模式下也写缓存），那么"看一眼植物状态"就会改变内部状态。**而且这是每帧每个植物一次的调用频率**（如果有 UI 在轮询）。

**排查方法**：在 `dryRun == true` 的分支上加计数器，运行 1 分钟后看计数——如果增长远超预期，说明 UI 在每帧轮询。

**修复**：`dryRun` 必须是**纯函数**，不能有任何副作用（包括缓存）。

**预防**：这一点应该在函数签名和注释里写死——**因为后来者很容易"优化"出一个带缓存的版本**：
```lua
--- @param dryRun boolean true 时 MUST NOT 有任何副作用（包括写缓存）。
---                        UI 的描述查询会高频调用此路径。
function farming_manager:CycleNutrientsAtPoint(x, y, z, consumption, restoration, dryRun)
```

---

## G. UI 与输入

### 症状：G1 · 关闭弹窗再打开，焦点落到已销毁的控件上（所有按键无声失效）

打开一个模组的自定义面板 → 关闭 → 再打开，鼠标点击没反应、键盘/手柄导航完全无效。关掉整个游戏重开才恢复。

**根因**（`screens/screen.lua:35`）：焦点记忆字段 `self.last_focus` 存的是上一次获得焦点的控件对象。有 `self.last_focus.inst.entity:IsValid()` 检查——**说明这个坑被踩过**。但**模组自定义的 Screen 若忘了这个检查就会复现**。

**排查方法**：
```lua
-- 在 Screen:OnBecomeActive 开头
if self.last_focus ~= nil and not self.last_focus.inst.entity:IsValid() then
    print("[ui] last_focus 已失效:", tostring(self.last_focus.name))
    self.last_focus = self.default_focus
end
```

**修复**：把焦点记忆做成**框架能力**，在 `Screen` 基类的 `OnBecomeActive` 里统一处理并校验有效性，不要让每个屏幕自己写。

**预防**：焦点对象一律存"能重建的标识"（控件路径或 ID）而不是对象引用，取用时现查现校验。

---

### 症状：G2 · 为吃鼠标 hover 而创建的透明 Image 抢焦点

鼠标划过某些区域时，焦点会被一个看不见的元素抢走（键盘导航"跳"到奇怪的地方）；多一次 draw call；屏幕阅读器把它当成真实元素。

**根因**（`widgets/scrollablelist.lua:44`）：
```lua
self.bg = self:AddChild(Image("images/ui.xml", "blank.tex"))  -- so that we have focus whenever the mouse is over this thing
self.bg:ScaleToSize(self.width, self.height)
```
一个不可见的背景 Image 只是为了"吃焦点"——它必须被创建、被渲染（浪费一次 draw call），只为了拿到鼠标事件。

**排查方法**：遍历控件树，找出 `tex == "blank.tex"` 或完全透明但 `focus = true` 的节点。

**修复**：在框架层提供独立的**"命中区域"概念**（一个矩形描述符 + 命中回调），不要用假图元。

**预防**：把"需要鼠标命中但不需要视觉表现"作为一类明确需求记在 UI 框架的需求清单里，不要用实现细节去凑。

---

### 症状：G3 · 点 UI 界面会触发角色攻击

点击任何 UI 元素都会让角色朝那个方向攻击一次；连续点击 UI 会持续攻击（auto-repeat）。

**根因**（`frontend.lua:419` 的 `FrontEnd:OnControl`）：

```lua
elseif #self.screenstack > 0
    and not (self.textProcessorWidget ~= nil and ...)
    and self.screenstack[#self.screenstack]:OnControl(
            control == CONTROL_PRIMARY and CONTROL_ACCEPT or control, down)
then
    self.isprimary = false
    --@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see playercontroller.lua)
    --@V2C: #HACK fix auto repeat attack bug in playercontroller where clicking down on
    --      UI elements still triggers attacks
    local player = ThePlayer
    if player and player.sg and player.sg.statemem.retarget and ... then
```

注释 `#FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK` 与 `#HACK fix auto repeat attack bug in playercontroller where clicking down on UI elements still triggers attacks` 说明了一切：**按下与抬起是两帧事件，UI 在抬起时才消费，按下时已经漏过去了。**修复方式是在 UI 消费分支里显式取消 retarget 状态——这是补丁，不是设计。

**排查方法**：在 gameplay 层的输入处理入口打印 `control, down, input_swallowed` 三个值，看游戏层是否收到了 UI 已消费的输入。

**修复**：**把输入仲裁放在最前面，一次性决定"这次输入归谁"**。
```
✅ 正确做法
Input::OnControl(control, down):
    if UI.consume(control, down):         -- UI 消费并记录本次输入已被吞掉
        mark_input_swallowed(control)    -- 标记，游戏层查询这个标记
        return
    gameplay.handle(control, down)

❌ 错误做法：按下时游戏层也收到，抬起时 UI 消费 —— 两边都被触发
```

**预防**：输入系统设计时就要明确"一个输入事件只被一个消费者处理"，并且这个仲裁发生在分发之前，不是之后打补丁。

---

### 症状：G4 · UI 状态残留（屏幕栈上的界面互相污染）

关掉某个界面再打开，某些控件还保持着上次的展开/选中/滚动位置；或者关掉界面后它的协程还在跑。

**根因**：屏幕的 `OnBecomeActive` / `OnBecomeInactive` 没有严格成对。状态被保存在实例字段上，而实例被复用（进出场栈而不是销毁重建）。

**排查方法**：
```lua
-- 在 Screen 基类加
function Screen:OnBecomeInactive()
    assert(self._active_count == 1, "OnBecomeInactive 次数与 OnBecomeActive 不匹配")
    self._active_count = 0
end
```
不匹配就说明某一处路径漏了其中一个。

**修复**：成对实现，并显式决定"哪些状态跨进出保留、哪些必须重置"：
```lua
function MyScreen:OnBecomeInactive()
    -- 跨进出保留的（写在 OnSaveScreenState 里）
    self._saved_tab = self.current_tab
    -- 不保留的显式清空
    self:_clearTransientState()
end
```

**预防**：把 `OnBecomeActive` / `OnBecomeInactive` 的对称性做成断言；补间的完成回调要检查宿主是否已销毁（`components/uianim.lua` 的补间完成时 `if not self.inst:IsValid() then return end`）。

---

## H. AI 与状态机

### 症状：H1 · AI 莫名其妙停下（EventNode 抢占重置了正在跑的子节点）

怪物在战斗中突然停住不动，也不做任何动作；或者某种行为被无端打断，而不是被更高优先级行为抢占。

**根因（`behaviourtree.lua:609-611`，已逐行核实）**：

```lua
if should_test_anyway and self.idx ~= idx then
    self.children[self.idx]:Reset()       -- ← 把当前赢家重置了
end
```

如果一个高优先级的 `EventNode` 触发并抢占了位置，而它的子节点立刻返回 FAILED，那么**原本在跑的那个子节点已经被 Reset 了**，它的内部状态丢失。结果是行为被打断而不是抢占。

**★ 深度注释后的更完整根因（三层）**：

1. **前提条件**：旧赢家也必须是 `EventNode`（`behaviourtree.lua:591`），
   且新候选 `priority >=` 旧赢家（`:600`）——**只有事件能抢占事件**。
2. **最狠的一环在 `:618`**：`else child:Reset()` 会**无条件 Reset 落选分支**，
   而 `:603` 的判断 `if status == FAILED or SUCCESS` **刻意排除了 RUNNING**。
   两者自相矛盾——作者用 Sequence 的心智模型写了 Priority 的代码。
3. **第二处现场（`:724-726`，此前未被收录）**：事件**重复触发**时，
   在事件发生瞬间就清空自己的子节点，比 `:610` 更早、更隐蔽；
   且未把自身 status 归位，与 `:751` 的 `status == READY` 判断产生矛盾。

**★ 根本原因**：全文件经检索确认**不存在** `Interrupt` / `Suspend` / `Resume` / `timeout`
任何一个函数 —— **框架缺少「挂起」概念**，导致抢占与中断只能退化为
「破坏性遗忘」：节点不知情，也无法保留进度。
> 这不是某个节点的 bug，而是**框架级设计缺陷**。自研 AI 时务必先设计好中断语义。

**后果的传导**：`Reset` 只清行为树内部状态，**不通知 `locomotor` / `bufferedaction`**
→ 行为树认为在做事、实体物理上也在走，**状态分裂** → 表现为抽搐 / 打转而非静止。

**排查方法**：在 `PriorityNode` 的选择循环里打印本轮各子节点的状态与最终赢家：
```lua
print(("[brain] %s idx=%d winner=%s statuses=%s"):format(
    self.inst.prefab, self.idx, tostring(winner.name),
    table.concat(statuses, ",")))
```
对比"卡住时刻"与"正常时刻"的差别——如果卡住时上一轮的 idx 被 Reset 过，就确认了。

**修复**：抢占时**只在新的赢家真正成功后才 Reset 旧的**，或者引入"挂起/恢复"：
```lua
if new_winner ~= nil then
    local old = self.children[self.idx]
    if old ~= nil and old.status == RUNNING then old:Suspend() end  -- 保留状态
    self.idx = new_idx
end
```
落选分支尤其不要 Reset —— 让它自然 FAILED 即可。

**预防**：设计 AI 框架时，**必须明确定义三种状态之外的第四种：挂起**。
「运行 / 成功 / 失败」三态无法表达"被打断但要保留进度"，这是行为树实现最常见的结构性错误。

**排查方法（相邻问题）**：如果怪物"走到某个东西面前然后什么也不做地站一会儿"，看 `stategraph.lua:430` 的 `StartAction`：
```lua
if handler then
    if not handler.condition or handler.condition(self.inst) then
        ...
    end
    -- ← 如果 condition 为假，这里什么都不做，直接返回 nil
end
```
返回 nil 的含义是"这个动作没被接受"，但调用方（locomotor）已经走到了目标位置。**这是 AI 卡住的另一个常见原因。**

**预防**：行为树的两层（决策 / 执行）都要有显式的"放弃"语义，并且放弃时是否保留状态必须在节点类型上声明清楚。

---

### 症状：H2 · 跨状态传递的数据丢失（`statemem` 在 `GoToState` 时被清空）

状态图从 `attack` 转到 `chase` 后，之前记录的目标丢失，AI 忘记在追谁。

**根因**（`stategraph.lua:550`）：`self.statemem = {}`——**每次 `GoToState` 都会清空 `statemem`**。如果你的 timeline 事件在 20 帧后触发，而期间有任何其他 `GoToState` 调用（包括被打断、被事件驱动的跳转），`statemem` 里的数据就没了。

**排查方法**：在状态转移时打印 `statemem` 的键数量：
```lua
function MySG:onenter()
    print("[sg] enter", self._state.name, "statemem keys:", count_keys(self._state.statemem))
end
```

**修复**：需要跨状态保留的数据放 `sg.mem`（跨状态保留），不是 `sg.statemem`。

原版对攻击目标的处理是把它塞进 `statemem` 并在**同一个状态的 timeline 里用**——只在"从 attack 跳到别的状态"时才丢，所以安全。

**预防**：明确划分两类数据：`statemem` = "本状态的临时工作区"，`sg.mem` = "跨状态的持久数据"。写代码时先判断数据要活多久，再选容器。

---

### 症状：H3 · 跨状态/跨机制的事件时序混乱

**症状：难以复现的偶发 bug**——某个动作在"排队期间"被另一个事件取消，只在特定操作顺序下出现。

**根因**：三套事件机制的时序不同（`architecture.md` §4.6 有完整对照）：

| | 事件总线 | 状态图 `sg:PushEvent` | 脑 `brain:PushEvent` |
|---|---|---|---|
| 实现 | 直接调监听者 | 塞进 `bufferedevents` 队列 | 查表直接调 `self.events[event](data)` |
| 时机 | **同步立即** | 更新循环之后统一 `HandleEvents` | **同步立即** |
| 来源标记 | 有（source 实体） | 带上 `data.state = currentstate.name` | 无 |

**脑的事件立即改变状态，状态图的事件排队到刻末。** 一个动作在"排队期间"被另一个事件取消，就是极难查的问题。

**排查方法**：在两侧都打时间戳：
```lua
-- 事件总线侧
print(string.format("[evt:%d] bus %s", TheSim:GetTick(), eventname))
-- 状态图侧
function StateGraphWrangler:UpdateEvents()
    local evs = self.haveEvents
    self.haveEvents = {}
    print(string.format("[evt:%d] sg drain %d", TheSim:GetTick(), count_keys(evs)))
    for k, v in pairs(evs) do k:HandleEvents() end
end
```
对比两个时间戳的差值——如果差 1 刻以上，就是队列延迟导致的。

**修复**：需要"当前调用栈内完成状态转移"时用 `PushEventImmediate`（比如死亡时立刻进 corpse 态，`health.lua:559-562` 就是在推 `"forcecorpsereplace"` 的同时 `sg:GoToState("corpse")`）。不要靠加 `Sleep(0)` 试图对齐——见 A3。

**预防**：三套机制选哪一套，写在事件名的注释里。用前缀区分：`ms_`（仅主模拟）、`sg_`（状态图缓冲）、直接名（立即）。

---

### 症状：H4 · 光环/范围效果被地形挡住

站在悬崖下的生物得不到悬崖顶的光环效果，尽管水平距离只有 3 单位。

**根因**：所有"10 单位"的空间查询语义实际都是 **`max_distsq` 平方比较**。例如理智光环：
```lua
local SANITY_EFFECT_RANGE_SQ = TUNING.SANITY_EFFECT_RANGE * TUNING.SANITY_EFFECT_RANGE  -- 100
if distsq <= (self.max_distsq or SANITY_EFFECT_RANGE_SQ) then ...
```
而 `GetDistanceSqToInst` 是**三维平方距离，包含 y 差**。所以光环会被地形高度挡住。

同时原版**混用**了两套语义：`FindEntities` 是球形；`moisture` / `perishable` 里用的是 `GetTemperatureAtXZ(x, z)` 的水平语义。这种混用导致玩家感知不一致。

**排查方法**：打印判定的 `distsq` 与 `Vector3_FlatDistSq` 的对比，差值大就说明被 y 挡住了。

**修复**：**明确区分"水平半径"与"球形半径"，不要在一个系统里混用。**

```lua
-- ✅ 明确语义
function Health:GetAuraRangeSquared(radius)
    if AURA_RADIUS_IS_SPHERICAL then
        return self.inst:GetDistanceSqTo(other)
    else
        local ax, _, az = self.inst.Transform:GetWorldPosition()
        local bx, _, bz = other.Transform:GetWorldPosition()
        return Lume.Vector2(ax, az):dist2(Lume.Vector2(bx, bz))
    end
end
```

**预防**：给 `FindEntities` 的所有调用点标注半径语义；`radius` 参数改名成 `radius_spherical` / `radius_flat` 之类，让误用在编译期就被发现。

---

### 症状：H5 · AI 休眠优化完全失效（WaitNode 的睡眠时间算成了负数）
**根因**：`behaviourtree.lua:295` —— `Sleep(current_time - self.wake_time)`
**符号写反**，应为 `wake_time - current_time`。负值被 `:106-108` 的钳位容错吃掉，
结果**所有 WaitNode 的休眠优化完全无效**，树永远无法真正休眠。

**排查方法**：在 WaitNode 的唤醒处打印 `current_time - self.wake_time`，
看是否出现负值。同时观察 AI 是否"看起来闲着却仍在每帧被调度"。

**修复**：改正符号：`Sleep(self.wake_time - current_time)`。

**预防**：时间差运算写完后，用三个用例验证：未到期（正）、刚好到期（零）、已过期（负）。
**不要依赖下游的钳位容错掩盖符号错误** —— 那会让休眠静默失效，很难通过功能测试发现。

**同文件另一处相关缺陷**：`:724-726` 事件重复触发时会立刻 Reset 自己的子节点，
比 `:610` 更早、更隐蔽，且未把自身 status 归位，与 `:751` 的 READY 判断冲突。

---

### 症状：H6 · 同优先级的行为互相压制，且压制方向与直觉相反
**根因**：`behaviourtree.lua` 中 `priority` 默认值是 0，判据用 `<=`（`<=` 表示"可抢占"），
而遍历顺序是**按 children 的位置顺序**。

后果：**同一优先级的 EventNode 会互相可抢占，而遍历时靠后的会压制靠前的** ——
与「位置越靠前优先级越高」的直觉**完全相反**。

**排查方法**：树里只有一个 EventNode 时一切正常，加第二个同优先级 EventNode 后行为错乱。

**修复**：不要依赖默认优先级。树里有多个 EventNode 时**全部显式指定 priority**，
不要依赖位置顺序。

**预防**：把「位置」和「优先级」两个维度在设计期就分开。
任何「顺序即优先级」的设计都要在文档里写死，否则后来者必踩。

---

### 症状：H7 · Priority 树的根节点让大脑永远不休眠（CPU 持续占用）
**根因**：`PriorityNode` 在 READY 状态下 `GetSleepTime` 返回 0，
于是 `Step` 每轮都把status 复位成 READY，导致 `BT:GetSleepTime` 恒为 0，
大脑永不进入 Hibernate。

**排查方法**：观察一个"完全空闲"的生物的 CPU 占用，或打印其大脑的休眠状态。

**修复**：READY 状态下若无可运行子节点，应返回 `nil`（表示"无事可做，请休眠"），
而不是 0（表示"立刻再来看我"）。

**预防**：休眠信号要区分三种语义：
- `nil` = 没有任何事（可休眠）
- `0` = 立刻还要再来（不可休眠）
- 正数 = 这么多时间后再来

把 `0` 当成 `nil` 用，就会出现本症状。

---

## 症状速查表

**用法：** 拿到现象先在这张表里查"首查方向"，对上号再去对应条目看完整的排查/修复流程。

| 症状（玩家或开发者看到的） | 首查方向 | 条目 |
|---|---|---|
| 周期任务越跑越慢 / "每秒判定"不准 | 回调里有没有 yield | A1 |
| 协程数只增不减；反复生成销毁后内存涨 | `Cancel()` 一个正在 yield 的任务 | A2 |
| 本该同帧完成的事被拆到多帧 | `Sleep(0)` / `Sleep(0.001)` 的语义 | A3 |
| 校时/迁移后服务端瞬间崩一片堆栈 | `OnTick` 的 `assert(k >= tick)` | A4 |
| 实体已销毁但日志还在打 | 清理回调名拼错（`OnRemoveEntity` vs `OnRemoveFromEntity`） | A5 |
| 批量销毁时偶发漏掉 1–2 个任务 | `pendingtasks` 遍历中 `onfinish` 改表 | A6 |
| 内存线性增长；已死实体仍收到回调 | 事件监听未双向注销 | A7 |
| 客户端实体属性**静默互换**（A 的血量显示成 B 的体温） | netvar "声明顺序即 wire format" | B1 |
| 单字段带宽莫名变大 | 字段被 `set_local` 污染 | B2 |
| 新组件服务端正常但客户端 UI 永远满值 | 组件没加可复制白名单 | B3 |
| 服务端改了值客户端无反应 | 在服务端写了 replica | B4 |
| 两端算出不同结果 / 事件顺序因人/因时而异 | `pairs` 遍历顺序 + 不稳定排序 | B5 |
| 服务器被压垮但无攻击者特征 | 模组抬高全局 RPC 限流 | B6 |
| 操作"慢半拍" | 缺客户端预测链路 | B7 |
| 移动平台/船只上位置错乱 | `remote_vector.y` 一字段三语义 | B8 |
| 存档读不回来 / 存档永久损坏 | NaN / Inf 写入 | C1 |
| 存档坏了但 grep `=nan` 搜不到 | NaN 走了别的序列化路径 | C2 |
| 读档后属性全回默认值 | 组件名大小写改了 | C3 |
| 更新后成片的建筑/物品消失 | 预制体改名没写迁移映射 | C4 |
| 读档后跟随物消失 / `Missing reference` 日志 | 存档引用表与实体 ID 失配 | C5 |
| 读档后状态标签不对（已腐坏仍带 fresh） | setter 守卫被读档顺序绕过 / 缺版本迁移 | C6 |
| 风度 0 的装备走了错误分支 | `and/or` 三元：返回 0 被当 falsy | D1 |
| 减伤率算错 / 移植到 C++ 后减伤异常 | 护甲吸收率可能为 nil | D2 |
| 玩家 1 秒内冻死，保暖无效 | 环境差值没做速率上限钳制 | D3 |
| 温度与湿度"不同步" | 复合累加器的执行顺序/单向依赖 | D4 |
| 减伤护符对火/冻/饿无效 | 减伤守卫是 `afflicter ~= nil` | D5 |
> 说明：D5 是原版的**设计限制不是 bug**，但必须对玩家可见。 |
| 大整数 ID 变负数 | 32 位无符号跨越语言边界 | D6 |
| 玩家被一堵打不开的门永久挡住 | 锁—钥匙表同名覆盖 | E1 |
| "地图上没有 XX" | 散布点数不足的静默放弃 | E2 |
| 生成卡几十秒后报"生成失败" | Lloyd 迭代 O(P×S) × 重试 5 次 | E3 |
| 同种子生成两次地图不同 | `pairs` 顺序 / RNG 未完全重置 | E4 |
| 玩家走进虚空掉下去 | 临时连通地块没清理 | E5 |
| 新地块上长出了不该长的东西 | 地块规则是黑名单语义 | E6 |
| 实体越多越卡，联机尤其明显 | 事件广播规模爆炸 | F1 |
| 上百只怪同一刻集体动作 | 脑的思考相位未散布 | F2 |
| 加了 UI/音效后性能掉一个数量级 | 状态图 `onupdate` 空转，无法休眠 | F3 |
| 世界玩久了越来越卡 | 休眠机制没生效 / 实体数失控 | F4 |
| 卡顿与实体数**平方**成正比 | 每帧对每个实体做空间查询 | F5 |
| 打开植物状态 UI 后植物状态自己变了 | `dryRun` 路径有副作用 | F6 |
| 关弹窗再打开，所有按键无声失效 | 焦点记忆指向已销毁控件 | G1 |
| 鼠标滑过某处焦点被"看不见的元素"抢走 | 用透明 Image 吃焦点 | G2 |
| 点 UI 会触发角色攻击 / 持续攻击 | 按下与抬起两帧，仲裁太晚 | G3 |
| 关掉界面再打开，控件状态残留 | `OnBecomeActive/Inactive` 不成对 | G4 |
| 战斗中 AI 突然停住不动 | EventNode 抢占时 Reset 了正在跑的子节点 | H1 |
| 状态转移后 AI 忘了在追谁 | `statemem` 在 `GoToState` 时被清空 | H2 |
| 极难复现的偶发状态错乱 | 事件总线（立即）vs 状态图（刻末批处理）时序差 | H3 |
| 悬崖下的生物拿不到悬崖顶的光环 | 三维平方距离 vs 水平距离混用 | H4 |
| 走到某东西面前站着不做任何事 | `ActionHandler.condition` 为假时静默返回 nil | H1 |
| 挖掘/攻击被受击后仍继续跑完 | 可打断状态忘了 `ClearBufferedAction()` | H4 |
| 怪物在判定边界疯狂抽搐 | 单阈值判定，缺迟滞双带 | D3 / H4 |
| 新加的活动状态集触发顺序每次都不同 | 定时器以 table 为键，同刻到期顺序随机 | A6 |

**三条最高频根因（出现频次统计）：**

| 排名 | 根因 | 典型条目 | 为什么高频 |
|---|---|---|---|
| 1 | 清理不彻底（任务/监听/组件） | A5 A6 A7 | 每个组件都要写三遍清理代码，漏一处就泄漏 |
| 2 | `pairs` 遍历 + 不稳定排序 | B5 D2 E4 | 写法简洁、测试时小数据量下顺序恰好一致，等到线上多端才炸 |
| 3 | setter 依赖的字段顺序 | C6 D4 | Lua 里"恰好能跑"，加一行代码就破 |

---

## 附：三条不写代码的防线

**这三条的性价比高于任何一条修复。**

1. **开发构建的 `Remove()` 断言。**
   ```lua
   -- 实体销毁流程的最后一行
   assert(self.pendingtasks == nil or count(self.pendingtasks) == 0, "Remove 后仍有未取消的任务")
   assert(self.event_listeners == nil and self.event_listening == nil, "Remove 后仍有事件监听残留")
   ```
   这两条断言能在开发期捕获 A2/A5/A6/A7 全部四类泄漏。

2. **启动期的一致性校验。**
   netvar 声明序列的校验和、锁—钥匙表的重复键与未声明引用、必需预制体的三重来源求和、预制体改名映射表的完备性——这些都在启动时跑一次，比在运行时被发现便宜几个数量级。

3. **每帧一次的量级哨兵。**
   单帧广播次数、活跃协程数、活跃定时器数、活跃实体数——四个数字，超过阈值就 `print` + 打堆栈。这四个数字覆盖了 F1–F4 的绝大部分场景。

---

# 附录：逐行深度注释阶段新发现的缺陷（18 条）

> 以下条目来自对 11 个核心文件（25,515 行）的逐行深度注释核实，
> 每条都定位到具体行号并给出推理依据。均为**原版真实代码**中存在的问题，仿写时应主动规避。

## 一、数值系统类

### 症状：N1 · 护甲叠加直觉错误（减伤是相乘而非相加）
**根因**：`components/health.lua:628` 附近，两代减伤分别计算后**相乘**。
直觉上"护甲1 减 20% + 护甲2 减 20% = 减 40%"，实际是 `0.8 × 0.8 = 0.64`，减36%。

**排查方法**：读 `health.lua` 的减伤聚合段，确认各段是`=` 还是 `*`。
**修复**：设计上明确想要哪种。若想要叠加，必须写成 `reduction = r1 + r2 - r1*r2`（概率并集）。
**预防**：在数值表旁注明"减伤按乘法叠加"，调参时用对数刻度而非线性刻度。

### 症状：N2 · 一代`absorb` 为 nil 时崩溃
**根因**：`health.lua:628` 的 `absorb` 未做 nil 保护即参与运算。
**排查方法**：搜 `absorb` 的所有使用点，检查每条路径是否可能未赋值。
**修复**：所有数值字段统一 `(x or 0)`。
**预防**：迁移到强类型语言时用可空类型 + 默认值，杜绝此类问题。

### 症状：N3 · `externalreduction` 对环境伤害无效（业务规则写成了短路表达式）
**根因**：`health.lua:629` 前的 `afflicter ~= nil` 短路。环境类伤害
（温度、溺水、饥饿，见 `components/temperature.lua:519/521`、`components/hunger.lua:160`）
一律不传 afflicter，整个 and/or 表达式走or 分支，amount 原样返回。
> 注：真正让固定减免失效的是这个短路，**不是**其后`math.min(0, ...)` —— 后者语义正确（防止减伤变成治疗）。

**排查方法**：列出所有调用 `DoDelta` 的位置，标出哪些不传 afflicter。
**修复**：把"减免只针对可归因攻击"写成显式 `if` 而不是看不出意图的 and/or。
**预防**：这类业务规则必须写成独立函数并配注释，别塞进表达式。

### 症状：N4 · 数值阈值缺少迟滞导致每帧翻转
**根因**：`components/sanity.lua` 的崩溃/恢复阈值若取同一值，理智停在线上时
`sane` 标志每帧翻转，引发音效与滤镜闪烁。
**修复**：两个阈值必须留缓冲带（原版用 15% 崩溃 / 17.5% 恢复，5 个百分点）。
**预防**：任何布尔状态派生自连续数值时，都要用「进入阈值 ≠ 退出阈值」的模式。

## 二、联机与网络类

### 症状：N5 · 模组可无限抬高 RPC 限流阈值
**根因**：`networkclientrpc.lua:1848` —— 限流常量定义在 `:1663`，
且 `HandleModRPC`（`:1911`）与主队列共用 limiter 与队列。
**排查方法**：查限流常量的读写点，确认模组接口是否也能改。
**修复**：限流上界必须是 `local` 常量，模组接口不得触碰。
**预防**：任何限流/配额都必须由引擎侧强制，配置项只能收紧不能放宽。

### 症状：N6 · 位置校验不等于合法性校验
**根因**：`networkclientrpc.lua` 中部分 RPC 只校验调用者位置，
不校验目标是否合法。
**排查方法**：逐个 RPC 检查：是否验证了参数类型？范围？权限？
**修复**：RPC 入口做统一的参数 schema 校验。
**预防**：**永远不要信任客户端传来的任何值**，包括位置、ID、数量。

### 症状：N7 · `ismastersim` 与 `ismastershard` 是两个正交维度
**根因**：容易误以为"服务端 == master shard"。`shardnetworking.lua` 里两者独立。
**排查方法**：分片逻辑里同时检查这两个标志。
**修复**：需要区分时显式写两个判断，不要合并。
**预防**：多维度状态（服务端/主机/分片）应建枚举，不要用多个 bool。

## 三、状态与生命周期类

### 症状：N8 · 世界实体销毁时的实体泄漏
**根因**：`prefabs/world.lua:417` 附近，销毁流程未清理全部注册实体。
**排查方法**：销毁前后对比 `TheWorld.Ents` 数量。
**修复**：销毁时遍历并强制移除所有子实体。
**预防**：世界销毁应有"归零断言"——`assert(#Ents == 0)`。

### 症状：N9 · 布尔 or 合并导致"显式禁止"失效
**根因**：`prefabs/world.lua:396/452` —— `enabled or explicitly_disabled` 的写法，
一旦enabled 为真，禁用被吞掉。
**排查方法**：检查所有"允许/禁止"标志的组合逻辑。
**修复**：改用互斥的三态（未定义/允许/禁止）。
**预防**：权限与开关类逻辑禁止用or 合并两个标志。

### 症状：N10 · `ismastersim` 提前 return 的性能命门
**根因**：`prefabs/world.lua:564` —— 这个检查若放在循环内会显著拖慢帧率。
**排查方法**：看它是否在热路径上。
**修复**：提到函数入口，一次判断。
**预防**：服务端正统检查放函数首行，不要散落在循环体内。

## 四、移动与物理类

### 症状：N11 · 骑乘中跳窄桥的规则在服务端永不生效
**根因**：`components/locomotor.lua:1229` 的 `IsValidDestinationPlatform`
在服务端也读 `replica.rider`，而 master sim 上 replica 恒为 nil。
**排查方法**：检查服务端与客户端读的是不是同一份数据。
**修复**：服务端读权威数据，客户端才读 replica。
**预防**：**双端不对称是最难查的一类 bug**，凡涉及 replica 都要问"服务端拿什么"。

### 症状：N12 · 布尔异或写法移植易错
**根因**：`components/locomotor.lua:1638` 用 `not a ~= not b` 表示异或。
**排查方法**：移植时若误写成 `!a != b`，语义直接颠倒且难以察觉。
**修复**：改写为显式的 `(a and not b) or (b and not a)`。
**预防**：避免双重否定；异或用显式写法。

### 症状：N13 · 「后退转身」是经验 hack
**根因**：`components/locomotor.lua:1602` —— 斜向移动与击退场景下不准确。
**排查方法**：斜向后退 + 受击同时发生时观察朝向。
**修复**：改为按速度矢量的角度差计算朝向。
**预防**：任何"看起来能用"的角度魔法都要标注为技术债。

### 症状：N14 · 死代码里藏着重要信息
**根因**：`components/locomotor.lua:1371` 被整块注释的路径通畅性检查，
注释里写着"坐标系错位"这个否决理由。
**排查方法**：不要直接删注释掉的代码，先读明白当年为什么放弃。
**修复**：转为正式的 issue 文档，或在注释上标注 `【已废弃，原因：xxx】`。
**预防**：删除死代码前，先把"为什么废弃"搬进正式文档。

## 五、工程与性能类

### 症状：N15 · `pairs` 遍历顺序不稳定影响确定性
**根因**：Lua 的 `pairs` 不保证顺序，导致多端可能算出不同结果。
（典型场景：烹饪产物选择）
**排查方法**：在两个不同运行时上跑同一逻辑，比对输出。
**修复**：需要确定性时用 `ipairs`，或先 `table.sort`。
**预防**：任何影响游戏结果或网络同步的遍历，**必须**先排序。

### 症状：N16 · 周期任务回调内yield 导致漂移与泄漏
**根因**：见 `scheduler.lua` 的 `ExecutePeriodic` —— Periodic 已挂进下一桶，
回调里 yield 会让协程挂起，下次周期又调一次 fn。
**修复**：周期回调内禁止 yield，或改用自调度写法。
**预防**：代码规范里明确写死这条，Code Review 必查。

### 症状：N17 · 浮点误差导致任务晚一帧
**根因**：`scheduler.lua` 的 `GetListForTimeFromNow` 中
`math.ceil((time + dt) / GetTickTime() - 0.0001)` —— 不减 epsilon 时
整除场景会算出 900.0000001 → ceil 成 901。
**排查方法**：打印 `(time/dt)` 的浮点值。
**修复**：加 epsilon 补偿（原版用 0.0001）。
**预防**：所有「时间差 / 步长」换算都要考虑浮点边界。

### 症状：N18 · 组件名大小写不敏感处理不对称
**根因**：`entityscript.lua` 的 `AddComponent` 会规范化大小写，
但 `RemoveComponent` 不会 —— 导致 `RemoveComponent("Health")` 静默失败。
**排查方法**：尝试用错误大小写移除组件，观察是否生效。
**修复**：两个方法用同一套规范化逻辑。
**预防**：所有按名索引的API 必须共用一个规范化函数。

---

# 附录二：动作系统与存档系统深度注释新增缺陷（11 条）

> 来自 `actions.lua`（13379行注释版，36 处标记）与 `mainfunctions.lua`（4790 行，51 处标记）
> 的逐行核实。每条定位到具体行号。

## 一、运算符优先级类（DST Lua 代码的头号杀手）

### 症状：ACT1 · `not X and X:IsActivated()` 导致必然崩溃
**根因**：`actions.lua:3461`。`not` 优先级高于 `and`，表达式实际是
`(not X) and X:IsActivated(...)` —— 当 `X` 为 nil 时，第一段为 true，
于是执行 `nil:IsActivated()` → **崩溃**。

**★ 强证据**：同一文件 `:1025` 有正确写法 `X == nil or not X`，
说明作者知道正确写法，`:3461` 是**漏写**而非无知。

**排查方法**：grep 所有 `not ` 后面直接跟变量名的表达式，逐个核对。
**修复**：`X == nil or not X:IsActivated(...)`
**预防**：**永远不要把 `not X` 和 `X:method()` 写在同一个 and/or 链里**。
Lua 没有 `?.` 安全调用，必须显式判空。

### 症状：ACT2 · `act.target` 为 nil 时崩溃
**根因**：`actions.lua:2789`，and/or 优先级导致 nil 保护失效。
**排查方法**：打印该动作执行时 target 的值，模拟目标消失的时序。
**预防**：涉及引擎对象的方法调用前，必须在同一表达式内先判空。

## 二、资源损失类（最严重）

### 症状：ACT3 · 先移除道具再 return false，白白损失道具
**根因**：`actions.lua:5612` —— 逻辑顺序错误，先 `Remove` 了道具才返回失败。
**排查方法**：模拟该动作的失败路径，看道具是否还在。
**修复**：把失败检查移到 `Remove` **之前**。
**预防**：**任何"消耗资源"的操作必须放在成功路径的最后一步**。
写代码时把副作用（扣物品、扣血、消耗材料）一律后置。

### 症状：ACT4 · `RemoveItem(...):Remove()` 缺 nil 检查
**根因**：`actions.lua:4805`。同一文件有 12 处同类写法（说明主流写法正确），
此处是漏检。
**预防**：链式调用在强类型语言里安全，在 Lua 里必须逐段判空。
**移植提示**：这类链式写法搬到 C#/Unity 时不会崩，**反而容易掩盖问题** ——
Lua 侧的 nil 保护必须显式写出来。

## 三、逻辑失效类（不崩但行为错误，最难查）

### 症状：ACT5 · 「技能未激活」检查完全失效
**根因**：即 ACT1 的另一面。表达式语义错误导致该检查永远为真/永不为真。
**★ 这类缺陷没有任何崩溃迹象** —— 只是玩家反馈"技能好像没用"。
**排查方法**：在检查处打印实际求值结果，与预期对比。
**预防**：布尔逻辑改动后，**必须写单元测试覆盖真/假/边界三种输入**。

### 症状：ACT6 · `IsOpenedBy(doer)` 恒为假
**根因**：`actions.lua:3299` 与 `:3374`。
**排查方法**：在真实场景调用并打印返回值。
**预防**：涉及"某个实体是否能打开某容器"的判断，用真实场景验证而非单测。

### 症状：ACT7 · `CanEntitySeeTarget(doer, doer)` 恒为真
**根因**：`actions.lua:4335` —— **自己当然能看到自己**，这个判断没有任何意义。
**后果**：打包等机制的黑暗保护完全失效。
**排查方法**：检查参数是不是本该传目标却传了自己。
**预防**：调用前**逐个核对参数语义**，不要凭函数名想当然。

### 症状：ACT8 · 动作失败却报告"砍不动"的相反结果
**根因**：`actions.lua:1730` 的 `DoToolWork` 缺少 reason 传递。
**排查方法**：实际测试砍不动的对象，看 UI 提示与实际是否一致。
**预防**：失败路径的提示信息必须来自真实失败原因，不能是硬编码。

## 四、存档系统类

### 症状：S1 · NaN 写入损坏存档，且**守卫存在却无效**
**根因**：`mainfunctions.lua:1203-1208` 的判据表。这是最值得学的一条。

官方判据分两支（行号精确）：
```lua
-- dev 分支
{"=nan", "=-nan", "=inf", "=-inf"}
-- 正式分支（MSVC 浮点打印格式）
{"=-1.#IND", "=1.#QNAN", "=1.#INF", "=-1.#INF"}
```
扫描点在 `:1214-1221`（世界级字段）与 `:1230-1237`（`data.ents`，按 prefab 分组），
命中即 `error()` 硬中止。

**★ 为什么"守卫存在却无效"**：常见的守卫写法是「值转数字失败就放过」，
而 Lua 中 `tonumber("nan")` / `tonumber("inf")` **一律返回 nil**
—— NaN 恰好落进 nil 分支被静默放过。
**官方干脆不走数值通道，改在文本层用 `string.find(..., 1, true)` 纯文本匹配。**

> **这是本项目最重要的移植教训**：
> 在强类型语言里`double.NaN` 是可比较的，守卫容易写对；
> 但在 Lua/Python 这类弱类型语言里，**"转换失败"和"值是 NaN"是无法区分的**。
> 自研存档系统时，**必须走文本层匹配或用 `math.abs(x) ~= x` 判断 NaN**，
> 绝不能用 `if not tonumber(v)`。

**★ 另一个已实测复现的缺陷**：`:1237` 附近用 `string.sub` 切片打印诊断信息时，
负索引钳制导致输出**不包含命中串**，诊断信息指向错误位置 ——
出错时的报错信息本身就是错的，会浪费大量排查时间。

### 症状：S2 · 前导 `=` 不是装饰，是判别依据
**根因**：NaN 在 DataDumper 里的呈现形式是 ` = nan`（带空格和等号），
这样才能与字符串值 `"nan"` 区分开。
**预防**：设计序列化格式时，**数值与字符串必须有可区分的前缀/分隔**，
否则无法对存档做内容校验。

### 症状：S3 · 动作编码随字母序漂移
**根因**：`actions.lua` 中 `action.code` 由**字母序**决定。插入一个新动作名，
会让其后所有动作的 code 偏移。**原版对此没有任何注释说明。**

**排查方法**：新增动作后打印若干已知动作的 code，检查是否改变。
**修复**：**保存 code 与动作名的映射表**，不要依赖运行时计算。
**预防**：任何用于网络协议或存档的 ID，**必须显式分配，绝不能由容器顺序推导**。
这是本项目反复出现的模式（netvar 声明序即线格式也属同类）。

## 五、系统性观察

### 动作系统的三层分工（DST 与常见误解不同）
代理核实发现 **DST 中不存在 `condition` / `act` / `type` / `isshared` / `noaccess` /
`AddPlayerAction` 这些字段与函数**（全库检索为零）。真实分层是：

| 层 | 函数 | 归属 | 作用 |
|---|---|---|---|
| 执行 | `fn` | 服务端 | 真正做事 |
| UI | `strfn` + `stroverridefn` | 客户端 | 显示动作名称 |
| 持续有效性 | `validfn` | **仅服务端** | 动作中途是否仍合法 |

条件判断的等价物在 `componentactions.lua:3181CollectActions`，
注册入口是 `componentactions.lua:3108 AddComponentAction`。

> **这个"UI 在客户端、合法性只在服务端"的分工是联机设计的要点**：
> 客户端可以乐观显示，但能不能执行必须等服务端确认。

---

# 附录三：玩家控制与物品系统深度注释新增缺陷（8 条）

> 来自 `components/playercontroller.lua`（10041 行，286 处标记）、
> `components/inventory.lua`（9218 行，57 处）、`recipe.lua`（1151 行）、`components/equippable.lua`（1001 行）
> 的逐行核实。

## 一、参数类型错乱类（隐蔽且难查）

### 症状：P1 · 布尔参数被传成字符串，靠truthy"碰巧"工作
**根因**：`components/inventory.lua:2458` 与 `:2492`
```lua
self:Equip(active_item, true, active_item.components.equippable.equipslot)
--                 ^^^^no_animation  ^^^^^^^^^^^^^^^^^^^^ 槽名字符串
```
第三参应为布尔（是否播动画），实际传了槽名字符串。
**因为任何非 nil / false 的值都是 truthy**，结果"碰巧"表现为不播动画——行为正确纯属巧合。

**★ 强证据**：同文件其他调用点第三参传的是 `true`/`false`/`nil`，可对照确认这是复制粘贴漏改。

**排查方法**：把所有调用点列出来对比第三参的实际类型。
**修复**：改为 `self:Equip(active_item, true)`。
**预防**：**Lua 没有类型检查，布尔参数传错类型不会有任何报错**。
对布尔参数，考虑改用 `assert(type(x) == "boolean")` 或改传明确枚举。

### 症状：P2 · `string.format` 格式串无占位符，值被静默丢弃
**根因**：`components/inventory.lua:2012`
```lua
return count..": "..s..string.format(" waterproofness:", self:GetWaterproofness())
--                                    ^^^^^^^^^^^^^^^^^^^^ 没有 %s
```
防水属性被计算、被传入、然后**被完全丢弃**。无任何报错。

**排查方法**：搜所有 `string.format`，检查占位符数量与参数数量是否一致。
**修复**：改为 `string.format(" waterproofness:%s", self:GetWaterproofness())`。
**预防**：格式化字符串**必须做"占位符个数 == 参数个数"的静态检查**。
这类缺陷在日志里完全不可见。

### 症状：P3 · 装备槽与普通槽的取值函数用错
**根因**：`components/inventory.lua:2696` 与 `:2722` ——
`GetEquippedMoistureRate` / `GetWaterproofness` 在 slot 分支用了
`GetItemInSlot`（普通槽）而非 `GetEquippedItem`（装备槽）。

**排查方法**：在玩家戴帽子/穿外套时调用这两个函数，看返回值是否合理。
**预防**：物品栏API 命名相近，**在类定义处就把两套访问器的区别注释清楚**。

## 二、联机预测类

### 症状：P4 · `remote_vector.y` 一字段三语义（定时炸弹）
**根因**：`components/playercontroller.lua:3743`
```lua
Vector3(x, self.remote_vector.y, z)   -- 把"标签"当成"海拔"返回
```
`remote_vector.y` 实际是状态标签，取值 0/1/2/3/4/5/6 共七态。

**★ 当前状态**：已核实**所有调用点都只用 xz 坐标，不读 y**，所以目前自洽。
但只要有人写一行 `return pos.y` 就会立刻出错。

**预防**：一个字段承载多种语义是**定时炸弹**。
拆分字段，或至少在类型名/注释上明确"这不是坐标"。

### 症状：P5 · 传送与橡皮筋回滚的优先级被搞反过
**根因**：`components/playercontroller.lua:4084` 的注释 `V2C: don't override rubberband`
记录了这段历史。

注释掉的 `:4085-4088` 是旧实现——**不分 remote_authority 一律瞬移**，
会让**服务器传送被客户端预测踩掉**（玩家刚被传送，客户端预测又把他拉回原处）。

现实现改为 `Physics:Teleport(当前权威位置)`，即**传送赢、橡皮筋让步**。

**排查方法**：在联机中测试"队长传送队员"，看队员是否会被拉回。
**预防**：**"权威事件"必须优先于"客户端预测"**。
设计预测系统时，先把哪些事件能压过预测写清楚。

### 症状：P6 · 同类"瞬移"逻辑的三处严格程度不一致（残留漏洞）
**根因**：`playercontroller.lua` 中三处 remote_authority 无条件瞬移——
`:4039`（预测过冲）、`:5778`（动作前对齐）、`:5789`。
其中 `:5778` 有"距离限制 + 可通行"双重校验，`:4039` **完全没有**。

**排查方法**：对比三处的校验条件。
**预防**：同一个语义的操作**必须走同一个函数**。
三处各写一遍必然出现校验不一致。

## 三、权限校验类

### 症状：P7 · 移动预测开关无归属校验
**根因**：`networkclientrpc.lua:954` 的 `SetMovementPredictionEnabled`
**任何客户端都能开关自己的移动预测**。

**★ 对比**：同文件其他 RPC 都有归属校验或参数范围检查，
此处的校验强度明显低于邻居——这种"邻居都校验了就它没校验"最值得警惕。

**预防**：**审查 RPC 时，同文件横向对比**。
找那个"比别人都宽松"的，它就是遗漏。

## 四、数值与算法类

### 症状：P8 · 护甲的两套减伤策略并存
**根因**：`components/inventory.lua` 的 `ApplyDamage` ——减伤取 `max`
（取最强的那个），耐久损耗按 `sum` 分摊；元素伤害另用一套池化分摊循环（`:468-486`）。

**后果**：玩家理解与实际行为不符 —— 玩家以为护甲叠加，实际是"最强的生效"。

**排查方法**：穿两件减伤不同的护甲，测实际减伤值。
**预防**：**设计阶段就要决定用哪种策略**，并在 UI 上如实展示。

## 五、结构性观察

### 玩家控制的双端分布（重要参考）
`playercontroller.lua` 5941 行里，判定"是否本机玩家"的标志**只有一个**：`self.handler ~= nil`。
全文件呈清晰的三段式：

| 区域 | 客户端（handler≠nil） | 服务端（handler==nil） |
|---|---|---|
| **输入入口 :601-718** | 唯一持有输入总线，读 `TheInput` | **永不执行** |
| **动作选择** | 算 code → 上报意图编号 | 用同一函数**重算** + 双重比对才执行 |
| **移动链路** | `DoPredictWalking` 客户端分支生产目标并发 RPC | 服务端分支消费目标驱动 locomotor + 橡皮筋 |
| **相机 :4438** | OnWallUpdate（暂停时仍转） | 不跑 |

> **★ 可直接借鉴的设计**：动作 code 由**客户端算、服务端用同一函数重算**，
> 两边不一致就拒绝执行。既避免了传大量参数，又天然防作弊。

### 物品栏 UI 同步的真实链路
`Reclientify` / `RepackInventory` / `GetSlots` **在全库检索为零** —— 我原以为有这些API。
真实链路是：
```
Inventory PushEvent → inventory_replica.lua:22-26 → inventory_classified netvar → 客户端 UI
```

### 「湿泥巴」兜底配方在别处
不在 `recipe.lua`，而在 `recipes/preparedfoods.lua:352`。
其机制：`test` 函数恒返回 true + `priority = -10` + 三项数值全 0 ——
即"匹配任何东西"但优先级最低。`spicedfoods.lua:32` 对它有特判分叉。

---

# 附录四：容器系统与 UI 框架深度注释新增缺陷（9 条）

> 来自 `containers.lua`（4647 行，72 处标记）、`components/container.lua`（3501 行，138 处）、
> `frontend.lua`（4062 行，174 处）、`widgets/widget.lua`（2504 行，141 处）、`input.lua`（2371 行，104 处）
> 的逐行核实。

## 一、死循环与崩溃类（最高危）

### 症状：CTR1 · 遍历槽位时踢出被锁定的物品 → 死循环
**根因**：`components/container.lua:209`
```lua
while next(self.slots) do
    for k in pairs(self.slots) do
        self:DropItemBySlot(k, drop_pos, true)
```
若某个槽位里的物品带 `islockedinslot` 标记，`DropItemBySlot` **不会真的移除它**。
于是 `for` 结束、`while` 再检查 `next(self.slots)`——槽位还在，**无限循环**。

**排查方法**：给容器塞入带 `islockedinslot` 的物品，再调 `DropEverythingUpToMaxStacks`，
观察是否卡死。
**修复**：在 `for` 内统计实际移除数，`while` 条件加上「本轮有进展」判断。
**预防**：**「边遍历边删除」+「可能删除失败」= 死循环**。
所有这类循环必须有"本轮是否有进展"的兜底判断。

### 症状：CTR2 · 未定义的全局变量（仅靠巧合未崩溃）
**根因**：`input.lua:649` 使用了 `player`，但该函数作用域内**没有定义它**。
对比同文件 `:351` 有 `local player = ThePlayer`，此处是漏写。
Lua 中未定义的全局变量读取到 `nil`，`nil.HUD` 会崩。

**★ 精确可达性分析**：需要 `scheme == 3`（手柄模式）**且** controlId 属于 NAV 组
才会命中。现有 4 个调用方全传 ACTION 组，**因此从未触发**。
但模组若调`GetLocalizedControl(id, VIRTUAL_CONTROL_INV_UP)` 就会崩。

**排查方法**：静态搜索所有裸全局变量引用，与同文件其它函数对照找出漏写的 `local`。
**修复**：补`local player = ThePlayer`。
**预防**：**开启严格模式**（Lua 5.2+ 的 `strict`，或自建断言检查 `_G` 访问）。
弱类型语言不报错，正是这类缺陷隐蔽的原因。

### 症状：CTR3 · 行为判定依赖本地化字符串相等
**根因**：`input.lua:712-719`的 `GetControlIsMouseWheel` 靠**本地化文本比较**
判断是否为滚轮。且 `:717` 的设备索引 `[1]` 与 `:607` 的 `[device]` 不一致。

**后果**：换语言（玩家用英文/中文）该判断直接失效。
**预防**：**永远不要用用户可见的文本做逻辑判定**，应该用枚举或控制 ID。

## 二、遍历与副作用类

### 症状：CTR4 · `RemoveAllItems` 未过滤 nil，而同类函数过滤了
**根因**：`components/container.lua:578-582`。
同文件 `:606-611` 的 `GetAllItems` 却做了 nil 过滤 —— **同一个文件里两种写法**。

**排查方法**：在同一文件内搜索所有类似遍历，找出写法不一致的那处。
**预防**：**同一文件内同类操作必须统一**。
发现一处不一致，就说明存在历史遗留或复制粘贴错误。

### 症状：CTR5 · `for` 循环体内调用了应只执行一次的语句
**根因**：`components/container.lua:1576/1587` ——
`replica:EnableInfiniteStackSize` 被误写在 `for` 循环**内部**，
导致按numslots 重复调用同一 N 次。

**后果**：功能上通常幂等所以看不出问题，但白做功、且埋下隐患。
**预防**：缩进即契约。**审查时重点看"只应执行一次的语句是否被缩进进了循环"**。

## 三、API 契约类（隐蔽且难维护）

### 症状：CTR6 · 同一对回调的参数格式不对称
**根因**：`components/container.lua:711-712` ——
`onclosefn(inst, doer)` 传**裸值**，而 `onopenfn(inst, {doer=doer})` 传**表**。

**后果**：写回调时必须记住"开和关的参数格式不一样"，极容易写错。
**预防**：**成对的回调必须用同一签名**。发现不对称就统一。

### 症状：CTR7 · `RemoveItem` 找不到物品时返回物品本身
**根因**：`components/container.lua:1015`。找不到时**返回了传入的物品对象**，
而不是 `nil`。配合 `:950` 的 `RemoveItem(v):Remove()` 链式调用，
可致**物品凭空消失**（相当于对不存在的物品又调了一次 Remove）。

**排查方法**：对不存在的物品调 `RemoveItem`，检查返回值。
**预防**：**"找不到"必须返回 nil**。返回业务对象是危险设计——
调用方的 `if item then item:Remove() end` 会照常执行。

### 症状：CTR8 · `CanOpen` 不被 `Open` 调用（守门人失效）
**根因**：`components/container.lua:735` 的 `CanOpen` **不被 `Open` 调用**，
真正的守门在 `actions.lua:1095`。
**后果**：绕过动作系统直接调 `Open`，可开出超过 `openlimit` 个 UI。

**预防**：**校验函数与执行函数必须成对出现**。
若 `CanXxx` 与 `Xxx` 不在同一处调用，迟早有人会绕过。

### 症状：CTR9 · 两个函数构成「隐式契约」
**根因**：`components/container.lua:211-220` 的 `Has` 排除了 `nocrafting`，
而 `:924` 的 `GetCraftingIngredient` 又依赖这个约定。
**两个函数必须同步修改**，否则行为不一致，但代码上完全看不出关联。

**预防**：这类跨函数的隐式约定**必须写在注释里**，并用同一个常量或配置表达。

## 四、死字段类（读代码会以为它在起作用）

**`containers.lua` 中三个字段从不被赋值：**

| 字段 | 被读位置 | 状态 |
|---|---|---|
| `droponopen` | `:795` | 恒 nil |
| `thiefproof` | `:1647` | 恒 nil |
| `skipautoclose` | `:619` | 构造函数 `:34` 已被注释 ⇒ 恒 nil |

**危害**：开发者看到 `if params.thiefproof then` 会以为这个功能存在并可用。
**排查方法**：对每个可疑字段全局搜索「读取点」与「赋值点」，只有读取没有赋值即是死字段。
**预防**：定期清理死字段；至少注释标注「已废弃」。

## 五、共享可变表技术债

**`containers.lua` 中 8 处以上 `params.X = params.Y` 引用赋值**
（行号：43/ 137 / 168 / 389 / 782 / 1230 / 1254 / 2405）——
这些不是复制，是**引用同一张表**，改一个会连带改掉另一个。

**★ 作者自己已经证明了这个风险**：`containers.lua:1663-1666` 明确拒绝派生
`sunkenchest`，理由原文是「确保它不会被共享表意外搞坏」。

> **移植教训**：用模板表继承（引用赋值）做配置很省事，但**必须明确是共享还是拷贝**。
> 最稳妥的做法是配置生成时深拷贝，或干脆用不可变数据 + 显式 merge 函数。

## 六、UI 系统类（主文 G1-G4 的精确根因，编号 GR1-GR4）

### GR1 焦点指向已销毁控件 · 三层根因（主文 G1 的精确根因）
- `widgets/screen.lua:35` 有 `IsValid` 守卫 —— **官方基类已做对**
- **框架层根因**：`widgets/widget.lua:592-602` 的 `GetDeepestFocus` 逐层下钻时**不校验节点存活**
- **源头**：`widgets/widget.lua:325-334` 的 `Kill()` **不清焦点** —— 祖先链残留 `focus=true` 造成断口
- 触发点：`frontend.lua:1151` 的 `GetActiveScreen` 也无校验

> **修复顺序**：先在 `Kill()` 里清焦点（治源头），再在 `GetDeepestFocus` 加守卫（治表现）。

### GR2 透明 Image 吃焦点 · 机制层根因（主文 G2 的精确根因）
原始现场：`widgets/scrollablelist.lua:44`。
**机制层根因在 `input.lua:526-557`**：`CanMouseThrough` 只有「可穿透/不可穿透」
**二元类别，没有「纯装饰」这一类**。
加上 `widgets/widget.lua:759` 的 hover 探测器又造了第二个 `blank.tex` —— 于是多了一层。

> **设计教训**：焦点系统的分类维度不够用时，就会用「画一个透明图」这种 hack 绕过。
> 症状是"看不见的东西抢了焦点"，根因是**分类模型缺了一种状态**。

### GR3 下击/抬起两帧导致误攻击 · 三环（主文 G3 的精确根因）
- **环节一（技术根源）**：`input.lua:163-170` 的仲裁位置正确，
  但 `input.lua:481` 的 `IsControlPressed` 走`TheSim:GetDigitalControl`
  **轮询式查询，完全绕过仲裁** ← 这才是根源
- 环节二：`playercontroller.lua:4603/4804` 写入粘滞的 `sg.statemem.retarget`
- 补丁本体：`frontend.lua:439-448`；另一半在 `playercontroller.lua:3132`

> **★ 这条最值得学**：原版知道这是 bug 并打了补丁，但**根因没解决**——
> 仲裁路径（事件驱动）和查询路径（轮询）并存，补丁只堵了一边。
> **自研引擎时应该只有一条输入路径。**

### GR4 UI 状态残留 · 三处不对称（主文 G4 的精确根因）
| 位置 | 问题 |
|---|---|
| `frontend.lua:1105-1107` | 按对象弹出时 `if old_head == v` 使 `OnBecomeInactive` **仅在弹栈顶时执行** |
| `frontend.lua:959-965` | `InsertScreenUnderTop` 两个回调**都不调**（唯一调用方是 `screens/playerhud.lua:462`） |
| `frontend.lua:1002-1011` | `ClearScreens` 只调 `OnLoseFocus`，**从不调** `OnBecomeInactive` |

**最严重后果**：`widgets/screen.lua:34` 的 `TheSim:SetUIRoot` 未执行 →
该屏 UI 实体**物理上无法被鼠标命中**（`input.lua:516` 只在 UIRoot 子树内拾取）。

> **★ 教训**：同一组"成对的生命周期回调"（onBecomeActive/OnBecomeInactive、
> onGainFocus/onLoseFocus）**必须成对调用**。漏掉一个的代价往往不是"少做一件事"，
> 而是"整个界面失去响应"。

## 七、其他新发现

- **`widgets/widget.lua:219/229`** —— `uianim:ForceStartWallUpdating` 在
  `components/uianim.lua`（235 行）中**不存在**；调用路径因 `IsConsole()` 双重早退
  而不可达，**缺陷被掩盖**。
- **`widgets/widget.lua:247-260`** —— `GetParentScreen` 的 `while` 无终止保护，
  且缓存永不失效（`RemoveChild` 不清 `parent_screen`）；同文件 `:633-636` 却做了防御。
- **`input.lua:179-184`** —— 鼠标路径**完全没有输入仲裁**（返回值被丢弃），
  与 `OnControl` 路径不对称。

## 八、对既有条目的纠正

**G 类中一条原记述有误**：`bug-patterns.md` 曾把 `input.lua:164-165` 记为
「主机上主键绕过 UI 直达游戏层」。

逐字重读后确认：`A and not TheFrontEnd:OnControl(...)` 中当 A 为假时
**整个 if 短路** —— 主键是**被静默丢弃**，不是直通。
该分支实为**防御性死分支**（主机无鼠标，`CONTROL_PRIMARY` 永不触发）。
已在新版条目中纠正。
---

# 附录五：世界生成与数值系统深度注释新增缺陷（12 条）

> 来自 `map/` 下9 个文件（storygen/forest_map/network/graphnode/lockandkey/tasks/task/level/terrain，
> 共约 14,790 行注释版）、`tuning.lua`（11537 行）、`constants.lua`（4243 行）、
> `tuning_override.lua`（238 行）的逐行核实。

## 一、必崩的日志语句（最典型的一类）

### 症状：W1 · "只打日志"的错误分支里藏着一个必然崩溃
**根因**：`map/forest_map.lua:572`
```lua
print(self.id .. " Cant process points")
```
`Generate` 是 `local function`且**没有 `self` 参数**，全文件也没有 `self` 的定义。
走到这一行必然 `index a nil value`崩溃。

**★ 为什么从未暴露**：它在"仅打日志"的错误分支里，
正常流程永远走不到，只有出错时才崩 —— 而出错时开发者看到的是崩溃，
不会联想到"其实是这个 print 出了问题"。

**排查方法**：搜索所有 `self.` 引用，逐个确认所在函数是否有 `self` 参数或外层定义。
**修复**：改为打印实际存在的变量（如 `id`）。
**预防**：**在错误处理分支里写代码要格外小心** ——
这些分支平时不执行，最缺乏测试覆盖，却是排障时唯一能给你信息的地方。

## 二、随机数与可复现性类

### 症状：W2 · 默认种子熵被压到10⁶，碰撞周期仅11.57 天
**根因**：`map/worldgen_main.lua:8` 的默认种子经`reverse()` + `sub(1,6)` 处理后，
**熵被压缩到只有 10⁶**。这意味着 `t` 与 `t + 1000000` 会得到相同种子。

**后果**：新开的世界会在约 **11.57 天后**开始出现完全重复的地图。

**排查方法**：连续生成大量世界，统计种子碰撞。
**修复**：不要对种子做 `reverse()` 这类压缩处理，或压缩后补足位数。
**预防**：**种子的可用空间必须显式验证**。
"看起来是随机的"不等于"随机空间足够大"。

### 症状：W3 · 遍历 `SPECIAL_EVENTS` 用 `pairs` 破坏可复现性
**根因**：`map/forest_map.lua:456` —— 用 `pairs` 遍历特殊事件表。
Lua 的 `pairs` **不保证顺序**，多个事件同时开启时处理顺序不确定。

**后果**：同种子在不同运行/不同Lua 版本下**可能生成不同地图**。

**排查方法**：同种子生成两次，比对结果。
**修复**：改用 `ipairs`，或先对键排序。
**预防**：**任何影响生成结果的遍历都必须排序**。
Lua 的 `pairs` 顺序在字符串键上尤其不可靠。

## 三、性能类

### 症状：W4 · Lloyd 松弛的真实开销远高于表面
**根因**：`map/forest_map.lua:499` 的 `VoronoiPass(100)`（首次）
与 `:503` 的 `VoronoiPass(50)`（**每增加一个区域就调一次**）。

grep 核实**Lua 侧零 Lloyd 实现**，全部在 C++ WorldSim 里。

**最坏耗时** = 单次约 10 秒 × `worldgen_main.lua:419` 的 `maxtries = 5`
→ **最坏可达 50 秒**。

**排查方法**：在 `VoronoiPass` 前后打时间戳，统计调用次数与总耗时。
**修复**：改用增量式局部松弛，或降低重试次数。
**预防**：**地图生成的重算法必须单独计时**。
Lloyd 是典型的"看起来轻量、实际是O(P×S)"的算法。

### 症状：W5 · 跨文件的人工同步契约（无代码保障）
**根因**：`constants.lua` 的 `WIRE` 类命名 —— 跨 `export_accountitems.lua`（5 处）
与 `MiniMapRenderer.cpp`（1 处）依赖**同名常量**保持同步。
**只有注释约束，没有任何代码校验**。

**排查方法**：搜索这些常量名，确认所有出现处是否都在维护者视野内。
**预防**：跨语言/跨文件的契约**必须有自动检查**。
注释会过期，CI 不会。

## 四、数值系统类

### 症状：M1 · 三种时间分母混用，改时钟会让缩放比例漂移
**根因**：`tuning.lua` 中三种分母的使用分布（实测统计）：

| 分母 | 值 | 出现次数 | 典型场景 |
|---|---:|---:|---|
| `seg_time` | 30 | 201 | 极短时序（护盾燃料、营火燃料） |
| `day_time` | 300 | 105 | 中等时序（作物生长、堆肥） |
| `total_day_time` | 480 | 436 | 长周期（每日消耗/回复速率） |

比值 **1 : 10 : 16**，且 `day + dusk + night == total`（300+120+60=480）恒等。

**★ 实锤**：`:2196-2202` 的 `SANITYAURA_*` 用 `seg_time`，
紧邻的 `:2204-2210` 的 `DAPPERNESS_*` 用 `day_time`，
**两组行尾注释都写 "per day"**。经按 480 秒验算全部吻合，
确认 "per day" 一律指完整昼夜 480 秒 —— 但**改时钟时两组缩放比例会漂移**。

**★ 正面教材（同一文件里的正确写法）**：`:7270` 用 `100/(day_time*4.5)` 表达
"每天 35.5"—— 策划能直接看出意图，且改时钟会自动等比缩放。

**排查方法**：改动任何时间常量后，检查所有速率类常量的实际值是否仍符合预期。
**预防**：**时间分母必须只有一种，或每个用途有明确的独立命名**。
最好像 `:7270` 那样写成除法表达式而不是裸数字。

### 症状：M2 · 引用求值脱钩（配置失效但不报错）
**根因**：`tuning.lua` 中 `TWIN1_CHARGECD` 把引用求值成了裸数字 `7`，
与原定义脱钩。

**后果**：改原定义不会影响这个值，且**没有任何报错**。
**排查方法**：对比配置项与其引用来源，确认是否被求值。
**预防**：**配置表的引用要么保持惰性求值，要么明确注释"这是快照值"**。

### 症状：M3 · 两个不同语义的常量值撞车
**根因**：`tuning.lua` 中 `LAYER_WIP_BELOW_OCEAN` 与 `LAYER_BELOW_GROUND` **值同为 2**。

**排查方法**：检查所有按值比较的分支，判断是否会误命中。
**预防**：**同值的枚举项要在同一处集中定义**，或干脆用位标志。

### 症状：M4 · 枚举值重复，作者自承不确定
**根因**：`TEXT_FILTER_CTX_UNKNOWN` 与 `TEXT_FILTER_CTX_SERVERNAME` **枚举值重复**，
源码行尾注释作者自己写着「不确定如何处理」。

**预防**：枚举定义后应有一条**唯一性断言**。

### 症状：M5 · 同一概念两种命名（接口歧义）
**根因**：`perd` 与 `petrification` 指同一概念。
经去重检验**并非重复键**（Lua 中是两个不同的键），但接口层面歧义。

**后果**：使用者用错名字时**静默失败**，不报错。
**预防**：给概念起唯一名字；确需别名时集中定义`ALIAS = { ... }` 并加注释。

### 症状：M6 · 引用值被用于期望的枚举值（`constants.lua`）
**根因**：`constants.lua` 中 `TUNING` 的部分项把引用求值成了裸值。
（见 M2，同类问题）

## 五、文档与实现偏差

### 症状：W6 · 注释描述与实际行为不符
**根因**：`map/containers.lua:1636` 的 `IsRestricted` 实现只对**玩家**生效，
但构造函数 `:51` 的原注释写的是 "Only entities with this tag can interact."

**影响**：任何依赖该注释的非玩家实体都会得到错误预期。
**预防**：**注释描述的是意图，代码实现的是现实**。
两者不一致时，先信代码，再改注释。

## 六、三个必须记住的路径陷阱

| 我以为的路径 | 真实路径 | 说明 |
|---|---|---|
| `scripts/network.lua`（联机） | `map/network.lua` | **这是地图生成图**，与联机无关 |
| `scripts/inventory.lua` | `components/inventory.lua` | 物品栏组件 |
| `scripts/playercontroller.lua` | `components/playercontroller.lua` | 玩家控制器 |

> **★ 教训**：每次接手新文件前**先用 find 核实真实路径**。
> 本项目已多次因凭印象写路径而派错任务。

## 七、数值系统的正确组织方式（本附录最有价值的产出）

`tuning.lua` 9581 行几乎全是数据，但它的**组织方式**值得抄：

1. **按领域分区**：生存/战斗/温度/湿度/农业/驯化…共 41 个分区，
   每个分区变量名共享前缀（如 `DAPPERNESS_*`、`WET_HEAT_FACTOR_*`）
2. **命名即文档**：从变量名能直接看出用途与单位倾向
3. **优先写表达式而非裸数字**：`100/(day_time*4.5)` 优于 `0.034722`
4. **覆盖有独立入口**：`tuning_override.lua` 让模组改数值而不动原文件
   （不过它实际是 41 个事件名的白名单，唯一消费方是 `components/area_trigger.lua`）
