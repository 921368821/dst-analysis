# 调试方法与工具链

> 这是一份**流程手册**，不是技巧清单。每一节都回答同一个问题：拿到一个异常现象，按什么顺序做什么动作。
> 所有代码示例可照抄；所有阈值来自对 DST 的实测或源码核实。

---

## 目录

1. [第 0 步：先把调试环境准备好](#第-0-步先把调试环境准备好)
2. [性能问题定位流程](#1-性能问题定位流程)
3. [帧耗时异常的排查决策树](#2-帧耗时异常的排查决策树)
4. [协程与任务泄漏的检测](#3-协程与任务泄漏的检测)
5. [网络不同步的排查顺序](#4-网络不同步的排查顺序)
6. [存档问题的排查](#5-存档问题的排查)
7. [崩溃与断言的分析方法](#6-崩溃与断言的分析方法)
8. [世界生成的排查](#7-世界生成的排查)
9. [模组的排查](#8-模组的排查)
10. [常用调试技巧](#9-常用调试技巧)
11. [环境矩阵与工具落地检查表](#10-环境矩阵与工具落地检查表)

---

## 第 0 步：先把调试环境准备好

**在开始查任何 bug 之前，先确认这四件事。跳过这一步的排查会浪费一半时间。**

### 0.1 三种构建必须存在

| 构建 | 用途 | 关键差异 |
|---|---|---|
| **dev** | 定位问题根因 | 断言全开、NaN 遇 `error()`、`printinvalid` 触发 `assert`、存档用可读文本格式 |
| **release** | 验证真实表现 | 断言关闭、错误降级为日志、存档压缩 |
| **profiler** | 性能测量 | 打点常开、额外计数、无 IO 阻塞 |

**为什么必须在 dev 下先复现**：`mainfunctions.lua:1201` 的 NaN 扫描在 dev 与 release 下用的是**不同的模式串**——dev 扫 `"=nan"`，release 扫 `"1.#QNAN"`（MSVC 的浮点打印格式）。**你在 release 下搜 `=nan` 永远搜不到。** `printinvalid`（`networkclientrpc.lua:18-29`）也是 dev 下直接 assert、生产只留日志。

### 0.2 三个不可关闭的断言

放在开发构建的固定位置，让它们常驻：

```lua
-- ① AddNetwork 必须在 SetPristine 之前
--    放进引擎侧的 AddNetwork 绑定里，或在 SetPristine 里反查
function EntityScript:SetPristine()
    assert(self._network_added, "AddNetwork() 必须在 SetPristine() 之前调用")
    ...
end

-- ② 模拟更新入口：服务器暂停时不能跑模拟
--    （照抄 update.lua:229 的 assert(not IsServerPaused()) 惯例）
function Update()
    assert(not IsServerPaused(), "服务器暂停时不应进入模拟更新")
    ...
end

-- ③ RPC 分配不超上限（照抄 networkclientrpc.lua:1386 的注释）
--    -- NOTES(JBK): RPC limit is at 128, with 1-127 usable.
local function alloc_rpc_code()
    assert(next_code < 128, "内建 RPC 槽位已耗尽（上限 127），请改用模组 RPC 命名空间")
    return next_code + 1
end
```

### 0.3 把「刻意放松的校验」标注出来

**规则：任何"看起来像 bug 的校验"必须在注释里写清楚为什么这样写。** 否则后来者会"修好"它。

DST 里的范例（`networkclientrpc.lua` 的 `checkuint`）：
```lua
--NOTE: checkuint since non-integer inventory slots are not handled gracefully
--      checknumber is generally enough for other cases
```
这里故意用了宽松的 `checknumber` 而不是更严格的 `checkuint`，**用最弱的校验换取兼容性**。没有这条注释，后人会"改成正确的"，然后物品栏里塞进小数槽位时整个客户端崩掉。

**做法：** 在代码里留 `#FIX` / `#HACK` / `#V2C` 标记（照抄 `update.lua` 的惯例）+ 原因。这些标记可以用 grep 一次性捞出来做 review 清单。

### 0.4 埋好四个量级哨兵

这四个数字覆盖了性能类问题的绝大部分场景（第 1、3 节会反复用）：

```lua
-- 挂到 TheWorld 上，每 30 刻打一次
local function Sentinel()
    local n_task, n_co = 0, 0
    for _ in pairs(scheduler.attime) do
        for _ in pairs(scheduler.attime[_]) do n_task = n_task + 1 end
    end
    for _ in pairs(scheduler.running) do n_co = n_co + 1 end
    local n_updating = 0
    for _ in pairs(UpdatingEnts) do n_updating = n_updating + 1 end

    Log.Info("[sentinel] ents=%d awake=%d updating=%d tasks=%d coroutines=%d",
        table.getn(Ents), table.getn(AwakeEnts), n_updating, n_task, n_co)

    -- 超阈值时打印一次调用栈，用来定位是谁在制造压力
    if n_co > 800 or n_task > 2000 then
        Log.Warn("[sentinel] 超阈值，调用栈:\n%s", debugstack())
    end
end
```

**阈值表（判断标准，不是建议）：**

| 指标 | 正常 | 需要优化 | 一定有问题 |
|---|---|---|---|
| 活跃定时器总数 | < 500 | 500–2000 | **> 2000** |
| 活跃协程数 | < 200 | 200–800 | **> 800** |
| 单实体定时器数 | 1–3 | 4–10 | **> 10** |
| 单实体事件监听数 | 5–20 | 20–50 | **> 50** |
| 单帧事件广播次数 | < 500 | 500–5000 | **> 5000** |
| 单帧空间查询返回实体数 | < 500 | 500–2000 | **> 2000** |
| 存活实体数 | ~3000 | — | — |
| **活跃实体数** | **100–200** | 200–500 | **> 500**（休眠失效） |

---

## 1. 性能问题定位流程

### 1.1 铁律：先测量，再猜

**性能问题的猜测命中率极低。** 下面这张表是"常见猜测 vs 实际占比"的典型分布——**AI 规模问题里 90% 是"不该跑的还在跑"，而不是"节点太多"。**

| 开发者的第一反应 | 实际占比 | 通常真正的原因 |
|---|---|---|
| "AI 太复杂了" | < 10% | 休眠机制失效 / 思考相位未散布 / `onupdate` 空转 |
| "寻路太慢" | < 10% | 每帧重复寻路（单阈值判定导致边界抖动） |
| "GC 压力大" | ~20% | 每帧隐式分配（`FindEntities` 每次返回新数组） |
| "事件广播太多" | ~30% | 全局事件 + 监听者数量膨胀 + 无降频 |
| "休眠机制坏了" | ~30% | 实体判定范围太窄 / limbo 状态没恢复 |

### 1.2 六步定位流程

```
第 1 步  分类：主线程帧时间高 / 世界生成慢 / 某个模组占满 CPU
   │      ↓ 主线程（继续第 2 步）
   │      ↓ 世界生成 → 跳到 §1.6
   │      ↓ 单个模组 → 跳到 §8.2
   │
第 2 步  打点：把帧时间分解到子系统，看谁占比最高
   │      （不能跳过这步。凭直觉优化的正确率低于 20%）
   │      ↓
第 3 步  在最高占比的子系统里再分解一层
   │      ↓
第 4 步  数一数：那一层里有几个对象？每个对象做几次？
   │      ↓ 「有 300 个实体 → 问：这 300 个都该跑吗？」
   │
第 5 步  判定：规模问题还是算法问题
   │      ├── 规模问题（本该只有 100 个在跑，实际 300 个）→ 修休眠机制
   │      └── 算法问题（数量合理但单次太贵）→ 降频/缩半径/加索引
   │
第 6 步  改一处，量一次。不要一次改三个地方然后说"快了"。
```

### 1.3 第 2 步：怎么打点

DST 的帧循环（`update.lua`）用 `TheSim:ProfilerPush/Pop` 逐段包裹，`stategraph.lua:148` 的 `UpdateEvents` 里也是这么做的：

```lua
function StateGraphWrangler:UpdateEvents()
    local evs = self.haveEvents
    self.haveEvents = {}
    TheSim:ProfilerPush("events")           -- ← 开始计时
    for k, v in pairs(evs) do k:HandleEvents() end
    TheSim:ProfilerPop()                    -- ← 结束计时
end
```

`TheSim:ProfilerPush(k.inst.prefab)` 甚至做到**逐预制体**打点——**这说明官方自己也需要 profile 才能定位性能问题**。你应该做同样的事。

推荐的顶层打点顺序（照 `update.lua` 的结构）：

```lua
function Update()
    local t0 = os.clock()
    TheSim:ProfilerPush("scheduler"); scheduler:OnTick(); TheSim:ProfilerPop()

    local t1 = os.clock()
    TheSim:ProfilerPush("components")        -- 组件 OnUpdate
    for k in pairs(UpdatingEnts) do k:OnUpdate() end
    TheSim:ProfilerPop()

    local t2 = os.clock()
    TheSim:ProfilerPush("brains");          -- SGManager:Update / BrainManager:Update
    TheSim:ProfilerPop()

    local t3 = os.clock()
    TheSim:ProfilerPush("events");          -- UpdateEvents（刻末批处理）
    TheSim:ProfilerPop()

    if dev then
        Log.Debug("[frame] sched=%.2f comp=%.2f brain=%.2f evt=%.2f",
            (t1-t0)*1000, (t2-t1)*1000, (t3-t2)*1000, (os.clock()-t3)*1000)
    end
end
```

### 1.4 第 4 步：把「数量」问清楚

**这一步是性能排查里最有价值、也最常被跳过的一步。** 对每个"看起来很重"的子系统，回答四个问题：

| 问题 | 怎么答 | 判定标准 |
|---|---|---|
| 有多少个对象在跑？ | 遍历更新列表计数 | 活跃实体数应 ≈ 100–200，不是 3000 |
| 每个对象做几次？ | 在函数入口计数 | 一次即可，绝不能是"每帧多次" |
| 单次多贵？ | `os.clock()` 差值 | 微秒级是正常；毫秒级就是异常 |
| 这些对象**都该跑**吗？ | 打印它们的 GUID + 距离玩家 | 远处的不该跑 → 休眠问题 |

**典型发现：** 300 个活跃实体 × 每个 30 个节点 × 30 Hz = **27 万次节点访问/秒**（`GetTreeSleepTime` 是递归的，`pigbrain` 那种 8 层嵌套 × 5 子节点的结构单次要访问 30–40 个节点）。这时候真正的解法不是优化节点，而是让其中 200 个猪进入休眠。

### 1.5 常见瓶颈的排序（按修复收益/成本比）

| 排名 | 瓶颈 | 典型症状 | 修复成本 | 收益 |
|---|---|---|---|---|
| 1 | **休眠机制没生效** | 玩久了越来越卡；远处实体也在耗 CPU | 低（调判定范围 / 修 limbo 恢复） | 极高（90% 开销） |
| 2 | **`onupdate` 空转导致状态图无法休眠** | 加了个 UI 后掉一个数量级 | 极低（删掉空 `onupdate`） | 极高 |
| 3 | **每帧重复的空间查询** | 与实体数平方成正比 | 中（降频 + 缩半径） | 高 |
| 4 | **事件广播无降频** | 联机才卡，单机正常 | 中（脏聚合 / 降频） | 高 |
| 5 | **每帧隐式分配** | GC 抖动、周期性卡顿 | 中（对象池 / 迭代器接口） | 中 |
| 6 | **单实体定时器过多** | 某类实体特别吃 CPU | 低（合并到统一 tick） | 中 |
| 7 | **模组在每帧做全局扫描** | 只有装了某模组才卡 | 低（找到并改） | 高（但不是你的问题） |
| 8 | **Lloyd 迭代 O(P×S)** | 世界生成慢 | 中（网格空间哈希） | 高（8 秒 → 1 秒） |

### 1.6 世界生成慢的专项定位

对照 §1.6 的阶段耗时预算表，先判断超时在哪一段：

| 阶段 | 目标 | 典型超标原因 |
|---|---|---|
| 任务解析 + 图构建 | < 50 ms | 房间深拷贝次数过多（131 任务 × 8 房间 ≈ 1000 次） |
| **Voronoi + Lloyd ×100** | **2–8 s** | **没用空间哈希 → O(P × S)** |
| 地块烘焙 | 0.5–2 s | 地块 id 查找用了线性扫描 |
| 连通性修复 + 洪水填充 | 0.3–1 s | 洪水填充没做边界检查 |
| 散布 | 1–3 s | 按面积散布而不是按胞元点数散布 |
| 校验 | < 100 ms | 校验里又跑了一遍完整扫描 |

**Lloyd 优化的判定标准**：暴力版是 O(P × S)。用**网格空间哈希**（32×32 的桶，每桶预存其覆盖范围内的候选站点列表）把最近站点查询降到 O(1) 附近，整体降到 O(P + S)。**100 次迭代从 8 秒降到 1 秒以内。**

### 1.7 重试让问题被放大 5 倍

排查生成失败时，先把 `maxtries` 临时改成 1，把单次耗时看清楚：

```lua
local try = 1
local maxtries = 1        -- 调试期改成 1，避免 5 次重试掩盖真实耗时
```

**单次 10 秒 × 5 次 = 50 秒才报一个错，而且错误信息极差**（玩家只看到"生成失败"，开发者要靠 `print` 里的 `PANIC: missing required prefab [X]! Expected N, got M` 反查）。详见 `bug-patterns.md` E3。

---

## 2. 帧耗时异常的排查决策树

### 2.1 决策树

```
帧耗时异常
│
├── 主线程帧时间高（模拟循环）
│   │
│   ├── ① 协程 / 定时器数量异常
│   │   ├── 哨兵显示 coroutines > 800 或 tasks > 2000
│   │   │   → 跑 §3 的泄漏检测
│   │   ├── 单个实体定时器数 > 10
│   │   │   → grep 该预制体文件里的 DoPeriodicTask / DoTaskInTime
│   │   │   → 合并到统一 tick，或改成事件驱动
│   │   └── 全局定时器在每刻触发
│   │       → 归属到具体实体，或提高周期 / 加脏聚合
│   │
│   ├── ② 事件广播量过大
│   │   ├── 单帧广播 > 5000
│   │   │   → 按事件名分类统计，找出贡献最大的 3 个
│   │   │   → 对这 3 个加脏聚合或降频
│   │   ├── 某事件有几百个监听者
│   │   │   → 换成"脏聚合 + 单点消费"：监听者只置标志，消费者每刻读一次
│   │   └── 监听者是永不过期的（已销毁实体仍在监听表里）
│   │       → 跑 §3 的检测（这是 bug 不是设计问题）
│   │
│   ├── ③ 实体数过多且都在 tick
│   │   ├── 活跃实体数 > 500
│   │   │   → 休眠机制失效。检查三件事：
│   │   │      a) 休眠的判定半径是否太窄？
│   │   │      b) limbo 状态下的实体有没有被永久排除？
│   │   │      c) 玩家移动时有没有"反复唤醒/休眠"的抖动？
│   │   └── 活跃实体数正常但 update 仍重
│   │       → 某个状态图返回 0.0（onupdate 空转），见 §2.3
│   │
│   ├── ④ 空间查询过密
│   │   ├── 每帧 FindEntities 调用次数 > 100
│   │   │   → grep 所有 OnUpdate 里的 FindEntities
│   │   │   → 三个改动：缩小半径（优先）、降频到每 10 刻、加空间网格
│   │   └── 每次调用返回 > 2000 个实体
│   │       → 半径过大，必须缩
│   │
│   ├── ⑤ 脑的计算成本
│   │   ├── 单个 GetTreeSleepTime 访问 30–40 个节点
│   │   │   → 决策树的嵌套层数太深（8 层 × 5 子节点）
│   │   │   → 用 CommonStates 生成器而不是手写深层嵌套
│   │   └── 多个脑的思考相位相同
│   │       → 收集 wake_time 看分布，改为 GUID 派生的确定性相位
│   │
│   └── ⑥ GC 抖动
│       ├── 每帧有大量短命 table
│       │   → 最常见来源：FindEntities 每次返回新数组
│       │   → 改迭代器接口，或用对象池复用
│       └── 热路径上的 string 拼接
│           → Log 输出要分级，默认关闭
│
├── 世界生成阶段慢 → §1.6
│
└── 单个模组占满 CPU → §8.2（死循环 / 每帧全局扫描）
```

### 2.2 「每帧 X 次」的计数方法

这是性能排查里最常用的一招——**任何可疑函数都在入口加计数，帧末打印**：

```lua
-- 通用探针工厂
local function make_counter(name)
    local c = { n = 0, stack = nil }
    setmetatable(c, { __call = function(self, ...)
        self.n = self.n + 1
        if self.stack == nil then self.stack = debugstack(2, 1, 0) end
        return true                      -- 返回 true 让调用方保持原行为
    end })
    _G.Counters = _G.Counters or {}
    _G.Counters[name] = c
    return c
end

local CountFindEntities = make_counter("FindEntities")

-- 帧末
function ReportCounters()
    for name, c in pairs(_G.Counters) do
        if c.n > THRESHOLD[name] then
            Log.Warn("[count] %s = %d (阈值 %d)\n首次调用栈:\n%s",
                name, c.n, THRESHOLD[name], c.stack)
        end
        c.n = 0
    end
end
```

**`debugstack` 只在第一次调用时抓**（`self.stack == nil` 时），因为抓栈本身很贵，而且第一次的调用点通常就是问题源头。

### 2.3 「onupdate 空转」的具体定位

这是收益最高的单项检查——**一个空的 `onupdate = function(inst, dt) end` 就能让整个状态图永不休眠。**

判定逻辑（`stategraph.lua:109`）：

```lua
if self.currentstate.onupdate then
    return 0.0                    -- ← 每帧
elseif time_to_sleep then
    return time_to_sleep
else
    return None                    -- ← 冬眠
end
```

**定位方法**：

```lua
-- 在 StateGraphWrangler:Update 里统计
local n_always = 0, n_tick = 0, n_hibernate = 0
for k in pairs(self.updaters) do
    local r = k:Update(current_tick)
    if r == 0.0 then n_always = n_always + 1
    elseif r == nil then n_hibernate = n_hibernate + 1
    else n_tick = n_tick + 1 end
end
if n_always > n_hibernate then
    Log.Warn("[sg] 永不休眠的状态图 %d 个 > 冬眠的 %d 个（应该相反）", n_always, n_hibernate)
    -- 打印出问题的状态名
    for k in pairs(self.updaters) do
        if k:Update(current_tick) == 0.0 and k._currentstate.onupdate then
            Log.Warn("[sg] %s 状态 %s 有 onupdate", k.inst.prefab, k._currentstate.name)
        end
    end
end
```

**修复**：把 `onupdate` 里"每帧检查某个时间点到了没"的逻辑改成 `timeline` / `ontimeout`。

```
❌ onupdate = function(inst, dt) if self.t > 2 then GoToState("next") end end
✅ timeline = { {time=2/FRAMES, fn=function(inst) inst.sg:GoToState("next") end} }
```

### 2.4 「遍历期间修改集合」导致的诡异性能问题

遍历快照/更新列表时，集合可能在遍历期间被改变（一个脑杀死另一个脑、一个状态图移除自己）。这会导致**某些元素永远不被更新**（漏掉）或**某些元素被更新两次**。

**症状**：特定情况下某类实体的行为"时灵时不灵"；或者更新列表里残留已销毁的实体。

DST 的两处做法：

```lua
-- ① 快照（brain.lua:106，注释明确说了原因）
-- NOTES(JBK): We need to make a copy of the keys to safely iterate over the table
-- because brains will remove and add onto the self.updaters table during iteration.
for k in self.updaters:
    if k.inst.entity:IsValid() and not k.inst:IsAsleep():
        count = count + 1
        self._safe_updaters[count] = k

-- ② 换表法（stategraph.lua:109，更彻底）
local updaters = self.updaters
self.updaters = {}          -- ← 直接换表，而不是边遍历边删
```

**规范：任何更新列表的遍历都必须用"快照 + 迭代数组"或"换表法"。**

---

## 3. 协程与任务泄漏的检测

### 3.1 在线监控代码（开发构建必备）

这段代码可以直接抄进调试菜单或控制台命令：

```lua
GLOBAL.DUMPLEAK = function(threshold)
    threshold = threshold or 0
    -- 活跃定时器
    local n_task, per_ent = 0, {}
    for tick, bucket in pairs(scheduler.attime) do
        for periodic in pairs(bucket) do
            n_task = n_task + 1
            local id = periodic.arg and periodic.arg[1]
            local guid = id and (id.GUID or id)
            if guid then per_ent[guid] = (per_ent[guid] or 0) + 1 end
        end
    end
    -- 活跃协程
    local n_co = 0
    for _ in pairs(scheduler.running) do n_co = n_co + 1 end

    print(("=== [LEAK] t=%d tasks=%d coroutines=%d entities=%d awake=%d ==="):format(
        TheSim:GetTick(), n_task, n_co, table.getn(Ents), table.getn(AwakeEnts)))

    -- 超阈值时，按实体聚类，找出"定时器最多的实体"
    local worst = {}
    for guid, n in pairs(per_ent) do
        if n > 3 then worst[#worst+1] = { guid = guid, n = n, inst = Ents[guid] } end
    end
    table.sort(worst, function(a, b) return a.n > b.n end)
    for i = 1, math.min(#worst, 10) do
        local e = worst[i]
        print(("  %s: %d 个定时器  prefab=%s  valid=%s"):format(
            tostring(e.guid), e.n,
            e.inst and tostring(e.inst.prefab) or "<已销毁>",
            e.inst and tostring(e.inst.entity:IsValid()) or "n/a"))
    end
    return n_task, n_co
end
```

**这个脚本一次就能回答三个问题：** 总量是否超标、哪个实体在制造任务、这些实体是不是已销毁的（后者直接指向 `bug-patterns.md` A5/A7）。

### 3.2 离线检测：基线往返法

**这是判定"是否泄漏"的唯一可靠方法**——没有基线就无法判断趋势。

```lua
local function RoundTrip(n, rounds)
    local base_tasks, base_co
    -- 第 0 轮：先稳定到一个基线
    for i = 1, n do SpawnPrefab("grass") end
    for i = 1, n do Ents[#Ents]:Remove() end
    Sleep(60)
    base_tasks, base_co = DUMPLEAK()
    print(("baseline: tasks=%d co=%d"):format(base_tasks, base_co))

    for r = 1, (rounds or 3) do
        for i = 1, n do SpawnPrefab("grass") end
        for i = 1, n do Ents[#Ents]:Remove() end
        Sleep(60)                      -- 等一个休眠周期让 GC 有机会跑
        local t, c = DUMPLEAK()
        print(("round %d: tasks=%d (+%d)  co=%d (+%d)"):format(
            r, t, t - base_tasks, c, c - base_co))
    end
end
```

**判定标准：**

| 结果 | 结论 |
|---|---|
| 三轮的增量完全一致（比如都是 +2） | 有个固定的定时器漏了，查那 2 个 |
| 增量逐轮放大（+2 / +5 / +9） | 有协程在被反复创建且从未结束（最危险） |
| 增量逐轮缩小 | 有延迟清理，只是还没跑完 |
| 增量恒为 0 | 没有泄漏 |

**关键：`Sleep(60)` 之后再看。** 很多"泄漏"其实是"还没到清理时间"。DST 的实体销毁链路里有一串延迟清理（`KillThreadsWithID` → `CancelAllPendingTasks` → `RemoveAllEventCallbacks`），60 刻（2 秒）足够让它们跑完。

### 3.3 定位"谁创建的"

计数器的增强版——**在协程创建点抓栈，按栈聚合**：

```lua
-- 在 StartThread / DoPeriodicTask 的创建路径上
local origins = {}
local function record_origin(kind)
    local st = debugstack(3, 1, 0)      -- 3 层：跳过 record_origin 与包装
    local k = kind .. "\n" .. st
    origins[k] = (origins[k] or 0) + 1
end

-- 泄漏检测时输出 top 3
local sorted = {}
for k, n in pairs(origins) do sorted[#sorted+1] = {k=k, n=n} end
table.sort(sorted, function(a,b) return a.n > b.n end)
for i = 1, math.min(#sorted, 3) do
    print(("[origin] x%d\n%s"):format(sorted[i].n, sorted[i].k))
end
```

**这个栈直接告诉你哪个文件、哪一行的 `DoPeriodicTask` 在泄漏。**

### 3.4 「正在 yield 中被 Cancel」的专门检测

这是 `bug-patterns.md` A2 里那类泄漏。它们**不会**出现在 `scheduler.running` 里（因为已经 Cancel 掉了），所以常规计数抓不到。要在 `Cancel()` 里加断言：

```lua
function Periodic:Cancel()
    -- 开发构建：被取消时协程应该已经 dead，或者处于"本刻刚挂起"
    if dev and self.co ~= nil and coroutine.status(self.co) == "suspended" then
        -- 允许：Sleep 到当前刻或更早（下一 tick 就会恢复）
        -- 危险：Sleep 到未来刻且已被摘除 → 永远不会 resume
        if self.nexttick > TheSim:GetTick() + 1 then
            Log.Warn("[scheduler] 取消了一个挂起到未来刻的任务（tick=%d>now=%d），"+
                     "存在协程泄漏风险。创建栈:\n%s", self.nexttick, TheSim:GetTick(), self.origin_stack)
        end
    end
    ...
end
```

**判定逻辑：** 挂起到**未来刻**再被 Cancel = 协程永远不会被 resume 也永远不会 dead = 泄漏。挂起到当前刻 = 下一 tick 就恢复了 = 安全。

---

## 4. 网络不同步的排查顺序

### 4.1 排查顺序（严格按这个顺序，不要跳）

```
客户端与服务端表现不一致
│
── 第 1 步：确认是"状态不同"还是"表现不同"
│
│   ├── 打印两端的权威值（不是 UI 显示值）
│   │   服务端：print(inst.components.health.currenthealth)
│   │   客户端：print(inst.replica.health:GetPercent())
│   │
│   ├── 两端权威值相同，但 UI 显示不同 → 问题在 UI 层，跳到 §4.4
│   └── 两端权威值不同 → 继续第 2 步
│
── 第 2 步：确认是"组件问题"还是"逻辑问题"
│
│   ├── 客户端 inst.components.xxx == nil 而服务端非 nil
│   │   → 组件没加可复制白名单（B3）
│   ├── 客户端 inst.replica.xxx == nil
│   │   → netvar 声明位置在 ismastersim 分支之后（B1）
│   └── 两端都有组件但值不同 → 继续第 3 步
│
── 第 3 步：确认写入路径是否合法
│
│   ├── 有没有绕过属性 setter 的裸赋值？
│   │   → grep 左侧是组件字段的赋值点（C6 / D3）
│   ├── 有没有在服务端写 replica？
│   │   → grep `replica.\w+ =`（B4）
│   ├── 有没有用 set_local？
│   │   → grep set_local（B2）
│   └── 以上都没有 → 继续第 4 步
│
── 第 4 步：确认逻辑本身是否确定性
│
│   ├── 有没有 pairs 遍历 + 事件/顺序依赖？
│   │   → 改成有序遍历 + 确定性 tiebreaker（B5）
│   ├── 有没有 table.sort 不稳定？
│   │   → 补 tiebreaker（B5）
│   └── 都是确定性的 → 继续第 5 步
│
└── 第 5 步：怀疑权威边界写错
    │
    ├── grep `if not TheWorld.ismastersim then return inst end` 的位置
    │   看有没有逻辑跑在了这个闸门之前
    └── 逻辑在闸门之后，但调用的某个函数内部有客户端分支
        → 检查被调用方（最隐蔽的一类）
```

### 4.2 第 1 步的具体做法：状态快照对比

不要靠肉眼比对 UI。在两端都挂一个快照命令，输出结构化文本再 diff：

```lua
-- 服务端与客户端都挂这个（挂在 Admin 权限后面）
GLOBAL.SNAPSHOT = function(guid)
    local inst = Ents[guid]
    if inst == nil then print("no such entity"); return end
    local out = {}
    out[#out+1] = ("prefab=%s"):format(inst.prefab)
    out[#out+1] = ("valid=%s asleep=%s"):format(
        tostring(inst.entity:IsValid()), tostring(inst:IsAsleep()))
    for _, name in ipairs(REPLICATABLE_COMPONENTS) do
        local auth = inst.components[name]
        local repl = inst.replica[name]
        if auth ~= nil then
            out[#out+1] = ("  comp[%s] 服务端存在"):format(name)
            -- 逐字段比较
            if name == "health" then
                out[#out+1] = ("    cur=%s max=%s"):format(
                    auth.currenthealth, auth.maxhealth)
            end
        elseif repl ~= nil then
            out[#out+1] = ("  comp[%s] 仅客户端存在（异常）"):format(name)
        else
            out[#out+1] = ("  comp[%s] 双端都没有"):format(name)
        end
    end
    print(table.concat(out, "\n"))
end
```

**两边各跑一次，diff 输出。** 差异行就是排查起点。

### 4.3 「客户端显示不对」的另一个方向

如果**权威值两端一致**，但玩家报告 UI 不对，按这个顺序查：

| 检查 | 怎么看 |
|---|---|
| 脏事件是否在逻辑更新**之前**触发 | `netvars.lua:36` 明确了顺序要求；对调就测一次 |
| 脏事件监听器是否在 0 刻注册 | 初始快照里的脏事件风暴会和注册打架（用 `DoStaticTaskInTime(0, RegisterNetListeners)`） |
| 是否有 UI 在轮询（每帧）而不是订阅 | grep `OnUpdate` 里的 UI 刷新 |
| 分类通道是否用对 | 私密状态走 `player_classified`（`SetClassifiedTarget`），而不是广播给所有人 |
| 兴趣管理是否把实体剔掉了 | 超出半径的实体客户端根本没有 → 表现为"UI 卡在旧值" |

### 4.4 带宽异常的定位

**症状**：抓包显示流量高，但代码里看不到高频操作。

**做法**：在 netvar 的发送路径上按字段计数：

```lua
-- 开发构建
netvar_tx_stats[fieldname] = (netvar_tx_stats[fieldname] or 0) + 1
netvar_byte_stats[fieldname] = (netvar_byte_stats[fieldname] or 0) + bits

-- 每 30 刻输出 top 10
local sorted = {}
for f, n in pairs(netvar_tx_stats) do sorted[#sorted+1] = {f=f, n=n, b=netvar_byte_stats[f]} end
table.sort(sorted, function(a,b) return a.b > b.b end)
for i = 1, math.min(#sorted, 10) do
    print(("[bw] %-28s sends=%-6d bytes=%d"):format(sorted[i].f, sorted[i].n, sorted[i].b))
end
```

**Bandwidth 选型参考**（用来判断某个字段的位宽是不是选小了）：

| 数据形态 | 选型 | 每字段开销 |
|---|---|---|
| 2 状态 | `net_bool` | 1 bit |
| 3–7 取值 | `net_tinybyte` | 3 bit |
| 8–63 取值 | `net_smallbyte` | 6 bit |
| 0–255 | `net_byte` | 8 bit |
| 通用整数 | `net_int` | 32 bit |
| 字符串标识 | `net_hash` | 32 bit |
| 数组 | `net_bytearray` | **"expensive"，上限 31** |

### 4.5 「偶发不同步」的专项

**偶发 = 有非确定性源。** 按这个顺序排除：

| 序号 | 非确定性源 | 怎么测 |
|---|---|---|
| 1 | `pairs` 遍历顺序 | 同一份数据跑 100 次，比对输出 |
| 2 | 不稳定的 `table.sort` | 同上（相同 priority 的元素顺序） |
| 3 | 定时器同刻到期的执行顺序 | `Periodic` 以 table 为键存在 `attime[tick]` 里 → 顺序随机 |
| 4 | 浮动累加顺序不同 | 同一组数字用不同顺序求和，比对结果 |
| 5 | 时钟回拨 | 打印刻号序列，查是否有回退 |

**第 3 项的修法**：有依赖关系的定时器（"先扣血再检查死亡"）必须用不同的时间或显式串行化。

> ⚠ **注意：如果你把调度器改成数组/向量，"意外地"变成确定性的插队顺序，这会掩盖 bug。** 等你修好依赖问题再享受确定性。

### 4.6 RPC 相关的排查

| 症状 | 首查 |
|---|---|
| 客户端的操作完全没反应 | 参数校验是不是把请求丢掉了？看 `printinvalid` 日志 |
| 偶发丢包 | 同帧分片 RPC 重入会被**静默丢弃**（`networkclientrpc.lua:1786`）——改成"排队到下一帧"并上报丢弃计数 |
| 服务器过载但无攻击者特征 | 模组抬高了全局限流（B6） |
| 玩家"瞬移" | 同一发送者的多条移动 RPC 在同一刻全执行了——检查同刻重入保护（`RPC_Timeline`）是否生效 |

**校验原语库**（`networkclientrpc.lua:3-14`，模组也能用，排查时直接拿来验证参数）：

```lua
checkbool(v)     -- v == nil or type(v) == "boolean"
checknumber(v)  -- type(v) == "number"
checkuint(v)    -- type(v) == "number" and tostring(v):find("%D") == nil
checkstring(v)  -- type(v) == "string"
checkentity(v)  -- type(v) == "table"     ← 必要但不充分
-- opt* 版本：额外允许 nil
```

**联合断言的形态**（照抄 `LeftClick`，`networkclientrpc.lua:61-76`）：要么全 nil（取消操作），要么全部合法。

```lua
if not ( (action == nil and x == nil and ...)
      or (checknumber(action) and checknumber(x) and checknumber(z)
          and optentity(target) and optbool(isreleased) and ...) )
then
    printinvalid("LeftClick", player)    -- 推 invalidrpc 事件 + dev 下 assert
    return
end
if IsPointInRange(player, x, z) then    -- 4096 = 64²，挡住"点击地图极远处"
    playercontroller:OnRemoteLeftClick(...)
end
```

---

## 5. 存档问题的排查

### 5.1 排查流程

```
存档损坏 / 读不回来
│
── 第 1 步：能不能读？
│   ├── 完全读不了（文件解析就失败）
│   │   → 跳到 §5.2 文本损坏排查
│   └── 能读但内容不对 → 继续第 2 步
│
── 第 2 步：是不是 NaN / Inf？
│   ├── grep 存档文本：=nan / -nan / =inf / =1.#QNAN / =-1.#IND
│   │   ★ 开发构建用前一组，生产用后一组（MSVC 浮点打印差异）
│   │   ★ 搜不到不代表没有——见下一步
│   ├── 搜不到 → 在序列化器里插类型钩子（见 C2 的 scan 函数）
│   │   它能精确定位到"哪个实体的哪个组件的哪个字段"
│   └── 找到 → 跳到第 3 步
│
── 第 3 步：哪些实体没生成出来？
│   → 在 SpawnSaveRecord 循环里统计 spawn 失败的记录（见 C4 的代码）
│   → 失败原因基本只有两类：预制体找不到（改名没迁移）/ 组件数据非法
│
── 第 4 步：哪些引用丢了？
│   → 统计 Missing reference 数量（见 C5）
│
── 第 5 步：哪些字段没恢复？
│   → 在关键组件的 OnLoad 末尾加断言，比对"值"与"副作用"
│       -- 例：perishable
│       assert(inst:HasTag("spoiled") == (inst.components.perishable:GetPercent() < 0.2))
│
└── 第 6 步：是不是跨版本问题？
    ├── 存档版本号 vs 现在的版本
    ├── 字段重命名 → 迁移映射表里有吗？
    └── 组件被删了 → OnSave 里加了 add_component_if_missing 吗？
```

### 5.2 文本损坏排查（存档是 Lua 源码格式）

**DST 的存档文件本质是可读的 Lua 文本**（`DataDumper` 把 table 序列化成 Lua 源码）。这是**值得抄的取舍**——最大好处是**模组可以理解并修改存档格式**，对长生命周期的游戏非常关键。代价是体积大、加载慢（二进制格式能小 3–5 倍）。

**排查步骤**：

```bash
# 1. 先看能不能被 loadstring 解析（这能精确定位语法错误的位置）
lua -e 'local f=loadfile("save/all/1/save/session/2/DST_GAME_1/server_save.stash"); print(f and "OK" or "PARSE FAIL")'

# 2. 如果解析失败，看最后 200 行（截断或乱序通常在文件尾）
tail -200 save/all/1/save/session/2/DST_GAME_1/server_save.stash

# 3. 搜数值异常
grep -n '=nan\|=inf\|1\.#QNAN\|1\.#IND' save/all/1/save/session/2/DST_GAME_1/server_save.stash | head

# 4. 对比上一个存档，看差异（文本格式的最大优势）
diff <(sed 's/, /,\n/g' old.stash) <(sed 's/, /,\n/g' new.stash) | head -100
```

**手工修存档的可行操作**（这正是选文本格式的价值）：

| 想做的事 | 怎么做 |
|---|---|
| 删掉一个坏实体 | 找到该实体块（按 `["prefab_name"] = {` 定位），整块删掉包括末尾逗号 |
| 修一个数值 | 直接改数字字面量 |
| 补一个缺失字段 | 在对应表里加一行 |
| 批量删掉某类物品 | grep 该 prefab 名，人工确认后删 |

### 5.3 迁移测试怎么做

**这是最容易被跳过、也最容易出问题的一环。** 建议做法：

| 测试项 | 做法 | 通过标准 |
|---|---|---|
| **逐版本升级** | 保留每个历史版本的存档样本，每个都升级到最新版 | 全部能读回，且关键状态正确 |
| **缺失模组** | 存一个"装了某模组"的存档，然后卸掉模组再读 | 实体消失但不崩；或被 `replace` 表映射 |
| **新增模组** | 读一个没有该模组的存档 | 模组的 `OnLoad` 能处理"组件不存在" |
| **部分字段缺失** | 手工删掉存档里的某个字段再读 | `OnLoad` 用默认值补齐，不崩 |
| **极端值** | 手工把某个数值改成 0 / 负数 / 极大值 | 被钳制或被识别为非法，不产生 NaN |
| **跨大版本** | 从最早可用版本直升最新版 | 通过（这是最难的一条，通常要写多级迁移链） |

**迁移链的设计**（照抄 DST 的 `upgrades[]` 按 `saveversion` 顺序执行）：

```lua
local upgrades = {
    { version = 2, fn = function(data)        -- v1 → v2：字段重命名
        for _, ent in pairs(data.ents or {}) do
            for _, rec in ipairs(ent) do
                rec.data.myoldfield = rec.data.mynewfield
                rec.data.mynewfield = nil
            end
        end
    end },
    { version = 3, fn = function(data)        -- v2 → v3：字段类型变化
        -- ...
    end },
}
```

**规范：字段重命名/删除必须同时做三件事——① 改代码；② 在迁移表加映射；③ 保留旧预制体名作为兼容壳。** 只做①是绝大多数存档 bug 的原因。

---

## 6. 崩溃与断言的分析方法

### 6.1 崩溃分类与首查方向

| 崩溃类型 | 典型报错 | 首查方向 | 对应条目 |
|---|---|---|---|
| **nil 索引** | `attempt to index a nil value` | 见 §6.2 的五个来源 | — |
| **已销毁对象被访问** | 在 nil / 已回收对象上执行逻辑 | 协程或事件在 `Remove` 后仍在跑 | A7 |
| **遍历中修改** | 行为不确定、有时崩有时不崩 | `pairs` 遍历时回调里 Remove | A6 |
| **数值异常** | 除以零 / sqrt 负数 | 速率计算缺守卫 | D3 |
| **断言失败** | `assert` 主动触发 | 见 §6.3 | — |
| **C++ 层异常穿透** | 后续所有调用都错位 | 绑定函数 throw 了 | 见 §6.5 |
| **段错误 / 访问违例** | 进程直接死 | 悬垂指针 / 句柄 ABA | 见 §6.6 |

### 6.2 nil 索引的五个来源

| # | 来源 | 怎么确认 |
|---|---|---|
| 1 | `TheWorld` 在世界实体创建前被访问 | 在 `PopulateWorld` 之前打点，看有没有提前访问 `TheWorld` |
| 2 | 组件在服务端专属分支里被客户端访问 | 打印 `ismastersim` + 访问点 |
| 3 | 模组拦截器返回值可能是 nil | 打印拦截器的返回值 |
| 4 | `LoadPostPass` 里的引用解析失败 | `newents[data.target]` 取不到（见 C5） |
| 5 | props 初始化顺序 | 见 §6.4 |

### 6.3 断言的分析方法

**断言的价值在于它把"这个条件不该成立"变成硬失败。** 但断言失败时，先分清是"真 bug"还是"断言写得太严"：

```
断言失败
│
├── 断言条件是"设计上的不变量"
│   ├── e.g. AddNetwork 在 SetPristine 之前
│   ├── e.g. Remove 后无事件监听残留
│   └── → 这是真 bug。断言帮你把它从"偶发的诡异现象"变成"确定的失败"
│
├── 断言条件是"性能/契约的前置检查"
│   ├── e.g. RPC 槽位 < 128
│   └── → 检查是不是触到了设计上限（见 A/B 类问题）
│
└── 断言条件是"刻意放松的校验"
    ├── e.g. 非整数槽位用 checknumber 而非 checkuint
    └── → ★ 这个断言如果没加"为什么"的注释，后人会当成 bug 修掉
        → 见 §0.3
```

**断言的三段式处理**（照抄 `printinvalid`，`networkclientrpc.lua:18-29`）：

```lua
local function printinvalid(rpcname, player)
    Log.Warn("Invalid %s RPC from (%s) %s", rpcname, player.userid or "", player.name or "")
    TheWorld:PushEvent("invalidrpc", { player = player, rpcname = rpcname })  -- 给反作弊模组的正式接口
    if BRANCH == "dev" then
        assert(false, ("Invalid %s RPC from (%s) %s"):format(rpcname, player.userid or "", player.name or ""))
    end
end
```

**这是成熟的做法：生产环境不崩，但留下完整证据链（日志 + 事件）；dev 环境立刻崩，便于内测时发现客户端 bug。**

### 6.4 「构造期顺序耦合」的定位

这是一个很难查的 bug 家族——**代码顺序对了就一直对，改一行就坏**。

**根因**（`class.lua` 的 props 机制）：props 表在构造时被 `pairs` 遍历初始化（**顺序不确定**），`obj._[k] = {nil, v}` 全部先设为 nil，之后构造器才跑。如果构造器里 `self.a = 1` 而 `a` 的 setter 依赖 `b` 已存在，就会读到 nil。

**DST 的 `health` 构造器里**：
```lua
self.maxhealth = 100          -- ← 必须在下一行之前
self.currenthealth = self.maxhealth
```
**依赖关系必须由代码顺序保证，不能指望 props 顺序。**

**排查方法**：把构造器里所有赋值语句的顺序打出来，看 setter 触发时读到的字段是不是 nil：

```lua
-- 在 props 的 __newindex 里挂探针
function Class.__newindex(obj, k, v)
    if dev and not obj._initializing then
        Log.Warn("[props] 构造完成后写入 %s，检查 setter 是否依赖未初始化字段", k)
    end
    rawset(obj, k, v)
end
```

**预防**：
1. **构造器里先设完所有字段，再写任何依赖它们的字段。**
2. setter 内部对依赖字段做 `or 默认值` 兜底，不要假设它已经存在。
3. 需要"所有字段就绪后统一刷新"时，提供显式的 `Recalculate()` 方法，在构造器末尾和每次相关字段变化后调用（这也是 C6 的修复方式）。

### 6.5 C++ 异常穿透脚本边界

**症状**：C++ 抛出的异常穿过 Lua 的 C 调用栈 → Lua 状态不一致（栈上残留半压入的值）→ **后续所有调用都错位**。一次异常毁掉整个会话。

**DST 的策略很清楚：绑定函数不抛 C++ 异常穿越边界。** 错误处理只有两种方式——返回 0/nil + 日志，或调 Lua 的 `error()`。

**正确做法**：
- 每一个可能被用户代码污染的入口（自定义命令、热重载的脚本、模组）都用 `xpcall(fn, debug.traceback)` 包住（照抄 `mainfunctions.lua:1602-1616`）：
  ```lua
  local fn = loadstring(str)
  known_assert(fn ~= nil, "CUSTOM_COMMANDS_ERROR")
  xpcall(fn, debug.traceback)   -- 兜住用户代码
  ```
- C++ 侧统一约定：**绑定函数返回错误码，绝不 throw。**

### 6.6 悬垂指针与 ABA 问题

**症状**：进程直接崩溃（段错误），或者——更糟——**不崩但行为完全错误**（旧句柄指向了新对象）。

**DST 的解法**：每次调用都验证有效性，而不是依赖 GC 时机。原文有 `ComponentValid` 守卫 + `"Stale Component Reference: GUID %d"` 日志。

**关键：只校验"非空"是不够的**——槽位复用会让旧句柄指向新对象（ABA 问题）。必须带世代号：

```cpp
struct HandleTable {
    std::vector<void*>   slots;
    std::vector<uint32_t> generations;   // slot 复用时 +1
    std::vector<bool>    alive;
    uint32_t freeListHead = UINT32_MAX;
};

void* Resolve(uint32_t handle) {
    uint32_t slot = handle >> 8, gen = handle & 0xFF;
    if (slot >= slots.size()) return nullptr;
    if (!alive[slot] || generations[slot] != gen) return nullptr;   // ★ 世代号校验
    return slots[slot];
}
```

**排查方法**：把所有解引用点过一遍，确认每个都有有效性校验，并且校验里包含世代号。

---

## 7. 世界生成的排查

### 7.1 「这张地图有 bug」类工单的排查

**这是最难的一类工单，因为世界是随机的，同一个 bug 可能是不同的种子触发的。** 固定流程：

```
1. 拿到种子与玩家路径
2. 重放那个种子（保证确定性，见 E4）
3. 用可查询的统计表，而不是 print
4. 走完 §7.2 的五道校验
5. 结构化输出失败原因
```

### 7.2 五道硬校验的逐条验证

`map/forest_map.lua` 的 `Generate()` 里有五道校验，全部会导致整个生成失败重来。**排查时逐条单独验证**，不要靠"生成失败了"这句话：

| # | 检查什么 | 怎么单独验证 | 失败的真实含义 |
|---|---|---|---|
| 1 | `WorldSim:WorldGen_Commit()` 返回 false | 提交前打印站点数与地块数 | 内部不一致，是引擎层问题 |
| 2 | 任何非 `LOOP_BLANK_SUB` 站点的 `GetSiteArea(id) < 8` | 打印所有站点的面积分布 | 有站点几乎为空 |
| 3 | `DetectDisconnect()` 的孤立地块数 > 全图 5% | 打印孤立地块数与总面积 | 有大量虚空地块 |
| 4 | 必需预制体数量不足（三重来源求和） | **打印求和明细表**（见下） | 资源不够，玩家会遇到"地图上没有 XX" |
| 5 | 没有任何出生点 | 打印四类出生点候选的数量 | 全空 |

**第 4 项的求和明细要这样打**（这是最有用的调试输出）：

```lua
local double_check = {}
for prefab in level.required_prefabs or {} do double_check[prefab] = (double_check[prefab] or 0) + 1 end
for prefab, count in topology_save.root:GetRequiredPrefabs() do double_check[prefab] = (double_check[prefab] or 0) + count end
for ocean_room in storygen.ocean_population do
    for prefab in ocean_room.data.required_prefabs or {} do
        double_check[prefab] = (double_check[prefab] or 0) + 1
    end
end
for prefab, count in double_check do
    local actual = #entities[prefab] or 0
    if actual < count then
        Log.Warn("[gen] 必需资源不足 %s: 需要 %d 实际 %d（来源 %s）",
            prefab, count, actual, actual == 0 and "完全没生成" or "生成不足")
    end
end
```

**注意 `translated_prefabs` 豁免**：用户主动关掉的资源不检查。别把这个豁免当成 bug。

### 7.3 静默失败的清单

排查"地图少了东西"时，**先查这三处静默失败**（它们只打 `print`，不计入校验）：

| 位置 | 行为 | 症状 |
|---|---|---|
| `graphnode.lua:330` `Node:PopulateVoronoi` | `if #points_x < pos_needed then return end` | **整个节点的内容物全丢** |
| `forest_map.lua` `object_layout.ReserveAndPlaceLayout` | `if rcx == nil then return end` | 场景件丢失 |
| `InsertAdditionalSetPieces` | `if choice == nil then print("Warning!...") break end` | 场景件没地方放 |

**做法：把 `print` 换成统计表**（见 `bug-patterns.md` E2 的修复代码），然后生成 20 张地图，把 `silent_drops` 累加起来看：

```lua
-- 生成 20 次后
for id, n in pairs(stats.silent_drops) do
    if n > 0 then Log.Warn("[gen] 节点 %s 在 20 次生成中被静默丢弃 %d 次", id, n) end
end
```

### 7.4 生成耗时的定位

见 §1.6。关键是：**先把 `maxtries` 改成 1**，看单次耗时；再对照阶段预算表判断超时段。

### 7.5 确定性的验证

**做法：生成两次，比对哈希。**

```lua
local function hash_world(w)
    local h = 5381
    local function mix(s) h = (h * 33 + string.byte(s)) % 2^32 end
    local ents = {}
    for _, e in ipairs(w.entities) do ents[#ents+1] = e end
    table.sort(ents, function(a, b)
        if a.prefab ~= b.prefab then return a.prefab < b.prefab end
        return a.id < b.id
    end)
    for _, e in ipairs(ents) do
        mix(e.prefab)
        mix(tostring(math.floor(e.x * 100)))
        mix(tostring(math.floor(e.z * 100)))
    end
    return h
end
```

两次不同 → 有非确定性源。按 §4.5 的顺序排查：`pairs` 顺序 / 不稳定排序 / RNG 未重置 / 浮点累加顺序。

### 7.6 玩家报告"地图有问题"时的提问清单

玩家能提供的信息比你想的多。**先问清楚这三件事再动手：**

1. **种子是多少？** → 能重放。
2. **具体坐标是多少？** → 能直接定位到是哪个节点。
3. **他做了什么？**（走了多远 / 有没有用某个道具 / 有没有进洞穴）→ 能判断是不是"设计如此"。

第 3 项最容易被忽略：**很多"bug"是设计如此**。比如"锁—钥匙图主要用来排序难度，不是真的做可达性验证"——原版在没有任何任务可挂时会**强行随机挂一个**（`storygen.lua:596-599`），代价是可能出现**逻辑上不可达**的任务。**这是已知的、被接受的行为。** 如果你的实现要保证严格可达性，就得在验收里加一道 BFS 可解性检查。

---

## 8. 模组的排查

### 8.1 模组崩溃的定位

**DST 的错误隔离机制值得照抄**（`mods.lua:192-206` 的 `runmodfn`）：每个模组钩子被独立包装，一个模组抛错不影响其他模组。

```lua
local runmodfn = function(fn, mod, modtype)
    return function(...)
        if fn then
            local status, r = xpcall(function() return fn(unpack(arg)) end, debug.traceback)
            if not status then
                Log.Error("error calling %s in mod %s:\n%s", modtype, ModInfoname(mod.modname), r or "")
                ModManager:RemoveBadMod(mod.modname, r)
                ModManager:DisplayBadMods()      -- 弹带三个按钮的错误对话框
            else
                return r
            end
        end
    end
end
```

**排查步骤：**
1. 找到 `error calling <hook类型> in mod <名字>` 这行日志 → 直接知道是哪个模组的哪个钩子。
2. `debug.traceback` 会给出完整调用栈。
3. 单模组隔离测试：只开这一个模组复现。

### 8.2 单模组占满 CPU

**两种原因，区分方法：**

| 原因 | 症状 | 区分方法 |
|---|---|---|
| **死循环** | CPU 100% 无响应，重启后正常 | 挂到调试器上看栈顶；或给模组入口配指令配额 |
| **每帧全局扫描** | CPU 高但有响应，且随实体数增长 | 看模组有没有自己的 `OnUpdate` / `DoPeriodicTask` |

**DST 的缺口**：`util.lua:817` 的 `RunInSandboxSafeCatchInfiniteLoops` 需要 `debug.sethook`，而它**和调试器冲突**（注释明写），且默认路径根本没用它——`InitializeModMain` 走的是普通 `RunInEnvironment`。

**所以一个模组写 `while true do end` 就能挂起整个服务器。** 你的实现里必须做指令配额：

```lua
local co = coroutine.create(function() return untrusted_code() end)
local count = 0
debug.sethook(function()
    count = count + 1000        -- 每次 hook 间隔 1000 条指令
    if count > maxops then error("mod exceeded CPU quota", 0) end
end, "", 1000)
local ok, err = coroutine.resume(co)
debug.sethook()
```

### 8.3 两个模组互相打架

**症状**：装了两个模组后行为异常；单独装都正常。

**三个最可能的原因：**

| 原因 | 怎么确认 | 怎么修 |
|---|---|---|
| **钩子执行顺序** | 打印两个模组的 `priority` 与加载顺序 | 明确声明「priority 高 = 后执行 = 覆盖别人」的规则 |
| **RPC 命名空间劫持** | 打印 `MOD_RPC` 的全部键 | 加所有权校验：`if MOD_RPC[ns][name] then error(...) end` |
| **资源路径覆盖顺序** | 检查 `package.assetpath` 的搜索顺序 | 显式声明覆盖优先级（DST 的倒序搜索是隐式的） |

**关于钩子顺序**：`GetPostInitFns` 遍历 `self.enabledmods`，而 `enabledmods` 是按 priority 排好序后依次插入的 → **高 priority 模组的钩子先执行，后加载的覆盖先加载的**。但**这个覆盖顺序没对外声明过**，模组作者会写出无法诊断的 bug。

排序函数有三个必须照抄的细节：

```lua
local function sanitizepriority(priority)
    local t = type(priority)
    if t == "string" then return tonumber(priority) or 0   -- 容忍字符串形式的数字
    elseif t == "number" then return priority end
    return 0
end
local function modPrioritySort(a, b)
    if a.modinfo and b.modinfo then
        local ap, bp = sanitizepriority(a.modinfo.priority), sanitizepriority(b.modinfo.priority)
        if ap == bp then
            local an = a.modinfo.name; if type(an) ~= "string" then an = a.modname end
            local bn = b.modinfo.name; if type(bn) ~= "string" then bn = b.modname end
            return stringidsorter(an, bn)      -- ★ 稳定的二级排序键
        end
        return ap > bp                        -- 降序
    end
    return stringidsorter(a.modname, b.modname)
end
```

1. **`sanitizepriority` 做类型防御**——模组作者会写 `priority = "10"`，不该崩溃。
2. **`stringidsorter` 替代 `<`**——注释说明了原因（macOS 改了 locale 排序行为）。**同 priority 时必须有确定性顺序**，否则不同机器上加载顺序不同 → 行为不一致。这在有全局状态（钩子顺序）的系统里是致命的。

### 8.4 模组相关的其他已知问题

| 症状 | 根因 | 位置 |
|---|---|---|
| 服务器被压垮但无攻击者 | 模组无限抬高全局 RPC 限流 | `networkclientrpc.lua:1848` |
| 模组 A 意外改坏了本体状态，堆栈看不出是谁 | 沙箱的 `GLOBAL = _G` 逃生舱 | `mods.lua:328` |
| 长时间运行后内存缓慢增长；换皮肤后用到旧路径 | `memoizedFilePaths` 无上限 | `util.lua:622` |
| 超长列表滚动时内存峰值过高、GC 抖动 | 每控件一实体 = 每控件一份 Transform | `widgets/widget.lua:1` |
| 跨分片物品偶发不同步，日志只有一行 print | 同帧分片 RPC 重入被静默丢弃 | `networkclientrpc.lua:1786` |

---

## 9. 常用调试技巧

### 9.1 断言的三种粒度

| 粒度 | 何时做 | 例子 |
|---|---|---|
| **每次调用都做** | 句柄有效性（否则就是崩溃） | `ComponentValid` 守卫 |
| **dev 构建做** | 参数类型/数量检查 | `luaL_checkstring` / `luaL_optnumber`（只在出错时才抛，编译进 release 后开销很小） |
| **注册期一次做完** | 业务逻辑校验（"这个 prefab 存不存在"） | `mainfunctions.lua:121-122` 的 `assert(resolvedpath, "Could not find "..asset.file)` |

**常见错误：把第三类放进热路径。** DST 的 `ComponentValid` 在每个绑定函数开头都跑，但它必须极简（一次句柄查表）。**它不是"防御性编程"，是"正确性前提"**（因为句柄可能悬垂）。两者不能混——把业务校验放进热路径会让帧耗时翻倍。

### 9.2 日志分级

| 级别 | 什么时候输出 | 用在哪 |
|---|---|---|
| `ERROR` | 总是 | 失败路径的证据 |
| `WARN` | 总是 | 静默失败、超阈值告警 |
| `INFO` | 总是（但要控制频率） | 哨兵计数、状态转移 |
| `DEBUG` | 仅 dev 构建 | 逐帧的耗时分解 |
| `TRACE` | 仅 dev + 显式开启 | 事件流、RPC 流 |

**关键点：日志本身有成本。** `INFO` 级别在热路径上输出会显著影响帧时间——Lua 的字符串拼接 + 控制台 IO 在 30 Hz 下每帧打一行就是可测量的开销。**做法：把拼接放在 `if dev then` 里，release 构建里连参数求值都别发生。**

```lua
-- ❌ release 下每次都做字符串拼接
Log.Info("[hit] %s took %.2fms", tostring(k), t*1000)

-- ✅
if dev then
    Log.Info("[hit] %s took %.2fms", tostring(k), t*1000)
end
```

### 9.3 快照对比（Snapdiff）

**这是排查"什么时候开始不对"的最有效手段。** 做法：

```lua
-- 定期（比如每 5 秒）对关键状态做一次序列化快照
local function TakeSnapshot(tag)
    local s = {}
    for guid, inst in pairs(Ents) do
        if inst.prefab and inst.entity:IsValid() then
            local h = inst.components.health
            if h then s[#s+1] = ("%s|%s|%.2f|%.2f"):format(guid, inst.prefab, h.currenthealth, h.maxhealth) end
        end
    end
    table.sort(s)                     -- ★ 必须排序，否则顺序差异会淹没真实差异
    _G.Snaps = _G.Snaps or {}
    _G.Snaps[tag] = table.concat(s, "\n")
    Log.Info("[snap] %s: %d 条", tag, #s)
end

-- 对比两个快照
GLOBAL.SNAPDIFF = function(tagA, tagB)
    local a = {} for line in (_G.Snaps[tagA] or ""):gmatch("[^\n]+") do a[line] = (a[line] or 0) + 1 end
    local b = {} for line in (_G.Snaps[tagB] or ""):gmatch("[^\n]+") do b[line] = (b[line] or 0) + 1 end
    for line, n in pairs(a) do
        if b[line] == nil then print("- "..line)          -- 只在 A 里 = 消失了
        elseif b[line] ~= n then print("~ "..line..": "..n.." -> "..b[line]) end
    end
    for line, n in pairs(b) do
        if a[line] == nil then print("+ "..line)          -- 只在 B 里 = 新出现了
    end
end
```

**用法**：在玩家报告"卡住了"的时候，用命令立刻打一次快照，和 30 秒前的自动快照对比——**差异行就是问题现场**。

### 9.4 热重载

**DST 的热重载基础设施**：`main.lua:134-158` 往 `package.loaders[2]` 装一个自定义模块加载器，把 `require` 路由到原生的 `kleiloadlua`（支持模组感知），并**把每个文件记进 `RequiredFilesForReload`**；`class.lua` 的 `ClassRegistry` 保存继承成员快照、`ReloadedClass` 注销。

**能热重载什么：**

| 类型 | 能否热重载 | 原因 |
|---|---|---|
| 纯函数、常量表、字符串 | 能 | 无状态 |
| 组件类的方法体 | 部分能 | 已有实例上的方法需要重新绑定 |
| `Class` 的继承结构 | 不能 | `ClassRegistry` 只能保证不崩，但结构变化需要重启 |
| 预制体工厂 | 不能 | 已经生成的实体不会重建 |
| 世界状态 | 不能 | `TheWorld` 的组件替换需要重新初始化 |

**推荐的开发循环：**

| 改什么 | 怎么做 |
|---|---|
| 数值常量（`tuning`） | 直接改 + 触发一次"重算所有派生值"的命令 |
| 组件逻辑 | 热重载 + **重启世界**（不要在活着的世界里换类） |
| 新增组件/预制体 | 必须重启 |
| 纯工具函数 | 热重载，立即生效 |

**热重载的禁忌：不要在有活体实体（玩家、背包物品）的世界里重载类。** 已有实例的原型链会处于半新半旧的状态，症状是"某种怪物的新逻辑生效了，另一种没有"——极难查。

### 9.5 用「第一次」当锚点

**排查偶发 bug 时，"第一次出问题"是最宝贵的信息。** 做法：

```lua
-- 在可疑的失败路径上记录第一次的完整上下文
local function FirstTimeOnly(key, fn, ...)
    _G.FirstSeen = _G.FirstSeen or {}
    if not _G.FirstSeen[key] then
        _G.FirstSeen[key] = true
        Log.Warn("[FIRST] %s 首次发生:\n%s\n参数: %s", key, debugstack(), serialize({...}))
    end
    return fn(...)
end
```

对以下场景特别有效：
- 某类实体的 AI 卡住
- 某种 RPC 被判 invalid
- 某个预制体 spawn 失败
- 存档里出现 Missing reference

### 9.6 反向二分

**当你不确定是哪次改动引入的 bug 时：**

```
1. 把代码 checkout 到"最后一个确认正常的提交"
2. 二分：应用一半的改动，跑测试
3. 缩小到具体的代码块
4. 在那块代码里找与 bug-patterns.md 的对应条目
```

**加速手段**：与其二分提交，不如二分**功能开关**。给可疑模块加一个运行时可切换的开关：
```lua
if _G.DisableNewAuraSystem then return end
```
这样一次运行就能排除一整块代码，比二分快得多。

### 9.7 断言「不该成立」的事，而不是断言「应该成立」

**这是一个反直觉但很有效的技巧。**

- ❌ 断言"每个实体都有 health 组件" —— 这需要遍历所有实体，很贵，而且只在新内容出错时有用。
- ✅ 断言"给任何实体加 health 组件时，它已经在可复制白名单里" —— 这只在加组件时跑一次，成本极低，而且**在错误发生的那一刻就抓住了**。

**通用原则：把不变量检查放在"状态变更的那一刻"，而不是"检查全局状态"。**

---

## 10. 环境矩阵与工具落地检查表

### 10.1 环境矩阵

**「我这里是好的」是最常见的调试陷阱。** 确保这几个环境的行为差异是已知的：

| 环境维度 | 差异点 | 怎么测 |
|---|---|---|
| **单机 vs 联机** | `ismastersim` 的值不同；客户端走完全不同的分支 | 单机测过的代码在联机下必须有对应测试 |
| **dev vs release** | 断言、NaN 模式串、`printinvalid` 行为 | 两个构建都跑一遍冒烟测试 |
| **主机 vs 专用服务器** | 资源加载不同（`ShouldIgnoreResolve` 会过滤 SOUND/OGV/FEV/FSB）；`ThePlayer` 在专用服务器上为 nil | 在专用服务器上跑一遍启动 |
| **有无模组** | 模组会加钩子、改 priority、覆盖资源路径 | 每加一个模组都跑一遍冒烟 |
| **存档版本** | 迁移链 | 逐版本升级测试（见 §5.3） |

**`ShouldIgnoreResolve` 的具体差异**（`mainfunctions.lua:69-98`）：

```lua
function ShouldIgnoreResolve(filename, assettype)
    if assettype == "INV_IMAGE" then return true end
    if assettype == "MINIMAP_IMAGE" then return true end
    if filename:find(".dyn") and assettype == "PKGREF" then return true end
    if TheNet:IsDedicated() then                       -- ★ 仅专用服务器
        if assettype == "SOUNDPACKAGE" then return true end
        if assettype == "SOUND" then return true end
        if filename:find(".ogv") then return true end
        if filename:find(".fev") and assettype == "PKGREF" then return true end
        if filename:find("fsb") then return true end
    end
    return false
end
```

**这就是"开发时在客户端测通了，上服务器发现某个组件不存在"的机制来源。**

### 10.2 工具落地检查表

按这个顺序建设，每一项都有明确的"什么时候会用到它"：

**第 1 批（必须有，否则每次排查都要从零搭环境）**

- [ ] 三种构建（dev / release / profiler）一键切换
- [ ] 断言基础设施：`assert(dev and cond, msg)` 的统一封装，生产自动降级为日志
- [ ] 四个量级哨兵（§0.4）
- [ ] 协程泄漏脚本 `DUMPLEAK`（§3.1）
- [ ] 网络快照命令 `SNAPSHOT`（§4.2）
- [ ] `debugstack` 可在任意处调用（DEBUGGER_ENABLED 时）

**第 2 批（性能排查）**

- [ ] `ProfilerPush/Pop` 逐子系统打点（§1.3）
- [ ] 计数器探针工厂（§2.2）
- [ ] 状态图 `Update` 返回值分布统计（§2.3）
- [ ] netvar 带宽统计（§4.4）
- [ ] 每帧 `FindEntities` 调用计数

**第 3 批（偶发问题）**

- [ ] 定期快照 + `SNAPDIFF`（§9.3）
- [ ] 「第一次」锚点记录（§9.5）
- [ ] 事件流追踪（记录 `PushEvent` 的时间戳与来源，用于排查 H3 的时序问题）
- [ ] 存档迁移测试框架（§5.3）

**第 4 批（模组生态）**

- [ ] 每模组 CPU 指令配额（§8.2）
- [ ] 模组错误隔离 + 错误对话框（§8.1）
- [ ] RPC 命名空间所有权校验
- [ ] 依赖环检测并**记录路径**（不是静默截断）
- [ ] 单模组隔离测试脚本（一次只开一个模组跑冒烟）

### 10.3 三个「不要」

| 不要 | 后果 |
|---|---|
| **不要在没有基线的情况下判断"有没有泄漏"** | 必须有"生成→销毁前后"的对比数字，否则"500 个协程"到底是多是少无从判断 |
| **不要一次改多个地方然后说"快了"** | 性能优化的归因必须是一对一。改一处量一次，是唯一能积累认知的方式 |
| **不要把「看起来像 bug 的刻意放松」当 bug 修掉** | 那些地方要么有注释说明原因，要么正在被依赖。修之前先 grep 一下有没有 `#FIX`/`#HACK` 标记 |

---

## 附：一页纸速查

```
性能问题          → §1.2 六步流程 → §1.3 打点 → §1.4 问"数量" → §1.5 排序修
帧耗时异常        → §2.1 决策树
协程泄漏          → §3.2 基线往返法（三轮往返看增量趋势）
偶发不同步        → §4.5 五个非确定性源逐个排除
存档坏了          → §5.1 六步流程 → §5.2 grep + diff（文本格式能手工修）
崩溃了            → §6.1 分类 → §6.2 nil 的五个来源 → §6.3 断言的三种含义
地图有问题        → §7.2 五道校验逐条验证 → §7.3 三处静默失败
模组出问题        → §8.1 runmodfn 日志 → §8.3 两个模组打架的三种原因
"我这里好的"      → §10.1 环境矩阵
```