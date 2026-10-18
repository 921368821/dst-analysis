# 《Don't Starve Together》核心架构 —— 最小可运行参考实现（Lua）

一套**可直接运行**的教学级参考实现，用来仿写《饥荒联机版》的核心架构：
类系统、tick 调度器、实体/组件/事件、生存数值条、修饰器袋、预制体与生成、
世界主循环、AI 状态机、存档。

所有代码都带中文注释，重点解释「**为什么这样设计**」，而不只是「做了什么」。

---

## 一、如何运行

### 方式 A：已安装 Lua 解释器（推荐）

代码兼容 **Lua 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / LuaJIT 2.1**（六个版本均已实测通过）。

```bash
cd 03-参考架构

lua main.lua              # 完整演示：先跑各模块自测，再跑整合演示
lua main.lua --quick      # 跳过自测，只看整合演示
lua main.lua --selftest   # 只跑各模块自测
lua main.lua --ticks 3000 # 指定世界一天的长度（默认 3000 tick = 100 秒）
```

每个模块也都能**单独运行**，跑完自己的测试：

```bash
lua 01_class.lua
lua 02_scheduler.lua
lua 03_entity.lua
...
lua 09_savegame.lua
```

### 方式 B：没有 Lua 解释器（本仓库的默认验证方式）

本机原本没有独立的 `lua` 可执行文件，因此附带了一个基于
**lupa**（把真实 Lua 解释器嵌入 Python）的运行器：

```bash
pip install lupa

python _run_lua.py 5.1   main.lua    # 用 Lua 5.1 跑
python _run_lua.py 5.4   main.lua    # 用 Lua 5.4 跑
python _run_lua.py all   main.lua    # 在 5.1 / 5.3 / 5.4 / LuaJIT2.1 上各跑一遍
python _run_lua.py 5.2   main.lua    # 也可单独指定 5.2 / 5.5
python _run_lua.py 5.1   02_scheduler.lua   # 单模块
```

`_run_lua.py` 会设置 `package.path`、模拟 `arg[0]`，因此模块内的
「是否主 chunk」判断与 `lua xxx.lua` 完全一致。

> **注意**：lupa 嵌入的是**真实的 Lua 虚拟机**（ lupa 2.8 内含
> lua51/lua52/lua53/lua54/lua55/luajit20/luajit21 七个运行时），
> 不是模拟器也不是解释器重写。本仓库的全部结论都基于真实运行时得出。

---

## 二、验证结果（**实测，非推断**）

在 **Lua 5.1、5.2、5.3、5.4、5.5、LuaJIT 2.1** 六个真实运行时上，
`main.lua` 完整跑通，退出码 0：

```
汇总:
  5.1      PASS
  5.2      PASS
  5.3      PASS
  5.4      PASS
  5.5      PASS
  jit2.1   PASS
```

每个模块单独运行也都通过（9/9）。

合计 **58 组检查点**全部通过（每组内含多个 `check` 断言），覆盖：

| 模块 | 验证要点 |
|---|---|
| 01_class | 继承、方法覆写、is_a/is_class/is_instance、setter 拦截收到 (self,new,old)、只读保护（赋同值放行/赋新值报错）、addsetter/removesetter、无 props 类的快路径 |
| 02_scheduler | DoTaskInTime 精确在目标 tick 触发、**周期任务 20 次触发间隔恒为 15 tick（无漂移）**、id 自动继承、KillThreadsWithID 清理睡眠/冬眠/运行三态、Hibernate/Wake |
| 03_entity | 标签增删查+副本保护、组件 Add/Get/Remove、事件推送/解绑、**死监听者自动清理**、生命周期钩子、存档契约、**销毁全流程（清组件/清协程/清双向订阅）**、标签+半径空间查询 |
| 04_meter | **1000 tick 数值下降 150→116.6667（误差 1.9e-12）**、**大 dt 与多次小 dt 等价**、归零触发死亡+clamp+死因传递、修饰器生效/撤销/叠加、饥饿归零连锁扣血、**理智 30%/35% 双阈值滞回**、Pause/Resume 保留原速率 |
| 05_sourcemodifierlist | **3 来源 ×2×3×4=24，移除中间一个后精确回到 8**、multiply/additive/boolean 三种折叠、同来源多 key 精确撤销、**来源实体销毁自动撤销**、脏值回调去重、序列化只存永久来源 |
| 06_prefab_spawn | 预制体注册/查表/未知名报错、生成+组件挂载+GUID 唯一、**服务端/客户端分界（私有数据不下发、客户端操作被拒绝）**、SpawnPostInit 扩展点、工厂崩溃回收实体 |
| 07_world | 累加器模式（20/60/144Hz 跑 1 秒都得到约 30 逻辑步）、**maxsteps 死亡螺旋防护**、时间推进与跨天、昼夜分段与黄昏渐变、实体延迟删除、tick 桶、**10000 tick 无异常** |
| 08_statemachine | 状态定义/查询/错名报错、条件转换+OnEnter/OnExit、**共享状态库且实例隔离**、**hound 五状态完整流转**、世界主循环中运行+销毁时协程自动回收 |
| 09_savegame | **float64 无损往返**、**NaN/Inf 拦截（含深层嵌套与非严格降级）**、序列化确定性、**v1→v2→v3 链式迁移（字段改名+语义转换+字段删除）**、缺失钩子报错、版本过高保护、存档→读档状态一致 |

**诚实标注**：本实现**没有**在原版 Klei 的 C++ 引擎里跑过，也没有做网络同步与渲染。
它验证的是「架构语义是否正确」，而不是「与原版逐字节一致」。
原版 Lua 侧无法脱离引擎运行，所以任何声称「已与原版对拍」的结论都不可信。

---

## 三、模块清单与学什么

| 文件 | 行数 | 职责 | 从这个模块能学到什么 |
|---|---|---|---|
| `01_class.lua` | 421 | 单继承 + 属性 setter + 只读属性 | **「带透明副作用的属性」**：一句 `self.current = 50` 就同时完成赋值、网络同步、HUD 刷新。业务代码无法写错。另含原版最反直觉的语义：**构造函数不会自动串联**，必须手工调 `Base._ctor(self, inst)` |
| `02_scheduler.lua` | 851 | tick 协程调度器 | **绝对 tick 桶**（而非相对延迟）为什么能消除周期漂移；**id 自动继承**如何做到「实体销毁时一次清空所有协程」；`-0.0001` 的浮点边界处理；周期任务禁止 yield 的原因 |
| `03_entity.lua` | 750 | 实体 + 组件 + 事件 | 为什么实体用**组合**而非继承；**实体粒度的事件总线**如何天然解决清理问题；销毁流程的 7 步顺序；泄漏防护里 `onremove` 必须特殊处理的隐蔽坑 |
| `04_meter.lua` | 722 | 速率×dt 积分数值条 | 为什么「每秒扣 1 点」是错的（卡帧丢时间、无法平滑、依赖步长）；**滞回带**（30%/35% 双阈值）如何消除状态抖动；clamp 到 `[0,max]` 的铁律 |
| `05_sourcemodifierlist.lua` | 540 | 按来源记账的修饰器袋 | **永远不写最终值，只记「谁要改成什么」**，每次从 base 完整重算 —— 于是「撤销」变成纯数据删除，天然幂等，彻底消灭「幽灵 buff」 |
| `06_prefab_spawn.lua` | 515 | 预制体工厂 + 生成 | 预制体**就是具名工厂函数**（不是资源模板），因此能在生成时决策、支持 Mod、零序列化格式；SpawnPostInit 的扩展点机制；SetPristine 的语义分界 |
| `07_world.lua` | 548 | 固定步长主循环 + 世界 | **累加器模式**让逻辑与帧率解耦；**maxsteps 防死亡螺旋**（切后台回来不能一帧补 3 万步）；遍历中删除的标准解法（标记+清扫）；跨天计算的浮点防护 |
| `08_statemachine.lua` | 811 | StateGraph + 共享状态库 | 状态与转换都是**数据**，于是可复用、可动态生成、可序列化、可视化；**状态震荡预算**（两个状态互相转移会让协程永不 yield → 游戏卡死）；`Class(State, fn)` vs `Class(fn)` 的致命差别 |
| `09_savegame.lua` | 638 | 序列化 + 版本 + 迁移 | 存档三件套（序列化/版本/迁移）缺一不可；**链式迁移**可跳过任意多个历史版本；**NaN 会静默污染整个状态**，必须在序列化入口拦截；`%.17g` 才能保证 float64 无损往返；长度前缀格式避免分隔符歧义 |
| `main.lua` | 452 | 整合演示 | 把上面 9 块拼成一个可读、可玩文本演示的完整样例 |
| `_run_lua.py` | 123 | 跨版本 Lua 运行器 | 用 lupa 在 5.1/5.2/5.3/5.4/5.5/LuaJIT 上验证同一份代码 |

---

## 四、整合演示做了什么

`lua main.lua` 会按顺序执行：

1. **各模块自测**（58 组检查点，全部打印 `[OK]`）
2. **阶段 1 生成世界**：玩家（4 条数值条）、火把、浆果丛、石块、猎犬（状态机）
3. **阶段 2 生存循环**：饥饿度按 -1.0/s 下降 → 采集浆果 → 吃浆果恢复（+25，clamp 到上限）
   → 演示修饰器袋：站在浆果丛旁衰减减半（0.5/s）
4. **阶段 3 昼夜与理智**：时间推进 → 光照从 1.00 降到 0.12 → 黑暗对理智衰减施加 12 倍放大
   → 理智跌破 30% 触发幻觉；并验证 30%~35% 滞回带内抖动 50 次**状态翻转 0 次**
5. **阶段 4 存档/读档**：存档 → NaN 拦截演示 → v1 老存档链式迁移演示 →
   **销毁全部 5 个实体（存活协程归零，零泄漏）** → 重建世界 → 逐字段一致性校验

实际输出节选：

```
跑 20 秒后：饥饿度    150.0 ->    130.0（下降    20.00，速率 -1.0/s）
浆果丛旁 10 秒:    150.0 ->    145.0（衰减速度  0.500/s，原始是 1.0/s）
理智崩溃: tick 2922（理智 59.8 / 200.0 = 30%，已触发幻觉 1 次）
滞回带验证: 在 32.5%（介于 30%/35% 之间）抖动 50 次，状态翻转 0 次（应为 0）
NaN 拦截: 尝试保存 NaN -> 已被正确拒绝
迁移演示: 读入 v1 存档，执行迁移 1->2 -> v3
    字段改名: player.food(75) -> player.hunger(0.5)，并从绝对值折算为百分比
销毁 5 个实体，当前实体数 0，存活协程数 0
泄漏检查: 存活协程 0 个 ✓（实体销毁后自动清理干净）
状态一致性校验:
    warmth         存档   19.887219670   读档   19.887219670   一致 ✓
    berries        存档    2.000000000   读档    2.000000000   一致 ✓
  ★ 存档 -> 读档 状态完全一致，演示通过
```

---

## 五、移植到 Unity / Godot 的对应关系

| 本实现（Lua） | Unity (C#) | Godot (GDScript/C#) | 移植时的坑 |
|---|---|---|---|
| `01_class.lua` 属性 setter | `class Meter { float current { get; set; } }` 手工 setter | `set(value)` / `@export` + `_set()` | **C# 的属性天然支持写入拦截，比 Lua 更容易做**。要警惕的是别把 setter 当成「校验」，它还承担副作用 |
| `01_class.lua` 手工串构造 | `base(...)`（隐式自动串联） | `super._init()` | ⚠️ **Lua 版的构造函数不会自动串联，C# 会**。移植时若照抄 C# 习惯会得到不同的初始化顺序 |
| `02_scheduler.lua` 协程 | 原生 `IEnumerator` + 协程；或 UniTask | `await ToSignal(get_tree(),"process_frame")` / `await get_tree().process_frame` | ⚠️ C#/Godot **没有 Lua 的「yield 一个值让调度器识别」**，Sleep 要改写成显式 `await`。同时要保留「绝对 tick 桶」而非 `WaitForSeconds`（后者受 Time.timeScale 影响） |
| `02_scheduler.lua` id 继承 | 传 `CancellationTokenSource`，子任务沿用父 token | 传 `owner_id`，或用 Godot 4 的 `Node` 树做天然层级清理 | Unity 协程**无法按归属批量取消**，这是最容易出协程泄漏的地方。建议自己维护 `Dictionary<int, List<Coroutine>>` |
| `02_scheduler.lua` Hibernate | `coroutine.enabled = false`（自己实现） | `process_mode = PROCESS_MODE_DISABLED` | Godot 的 `set_process(false)` 是最接近的；Unity 没有等价物，得自己加标志位 |
| `03_entity.lua` 组件 | `GetComponent<T>()` + `[RequireComponent]` | `get_node()` / 自写组件表 | ⚠️ Unity 的 `GetComponent` 是**类型查找**而非字符串键，移植时要维护一张 `string -> Type` 的注册表才能复刻 `inst.components.health` 这种按名字访问 |
| `03_entity.lua` 事件总线 | C# `event` + `UnityEvent` | Godot `signal` | ⚠️ **C# 的 event 是「订阅者消失即解绑」，Lua 是「必须手工 UnregisterEvent」**。移植时若依赖自动解绑，实体生命周期管理会全线改变 |
| `03_entity.lua` SetPristine | `NetworkVariable<T>` 初始值设置 | `MultiplayerSynchronizer` 初始状态 | 这是主从架构的分界线，**必须在构造期完成**，否则客户端会看到中间态 |
| `03_entity.lua` 空间查询 | `Physics.OverlapSphere(pos, r, layerMask)` | `PhysicsServer3D` 球形查询 + `collision_mask` | 标签过滤对应 Unity 的 **LayerMask**（位掩码，比字符串标签快得多）。⚠️ 注意 Unity 的 OverlapSphere **包含触发器要显式指定** |
| `04_meter.lua` `rate×dt` | `Update()` 里 `current += rate * Time.deltaTime` | `_process()` 里同理 | ⚠️ `Time.deltaTime` 在卡顿后会变得很大。数值条天然对大 dt 免疫，但**物理/动画不能**放这里 |
| `04_meter.lua` 滞回带 | 直接两个 `const float` 比较 | 同 | 无需移植，照抄阈值即可 |
| `05_sourcemodifierlist` | `Dictionary<object, Dictionary<string,float>>` + 脏标记重算 | 同 | ⚠️ 来源数量上千时要改用**带索引的平衡树/脏子树**，否则全量重算的 O(n) 会成为热点 |
| `06_prefab_spawn.lua` 预制体 | `ScriptableObject` + `Instantiate`；或纯 C# 工厂 `Func<GameObject>` | `.tscn` 场景；或 GDScript 工厂函数 | ⚠️ Unity 的 prefab 是**资源**不是函数，会丢掉「生成时决策」的能力。若要保留原版语义，必须自己写工厂 + 注册表 |
| `07_world.lua` 累加器 | MonoBehaviour `Update` 里自己累加；或 `FixedUpdate` | `_process()` 累加；或 `_physics_process()` | ⚠️ Unity 的 `FixedUpdate` 是**全局固定步长**，与逻辑步长未必一致。要复刻原版语义就得在 `Update` 里自己跑累加器 |
| `07_world.lua` 死亡螺旋防护 | 同样要限制单帧补步数 | 同 | ⚠️ 这一条**极易遗漏**，遗漏后表现为「切后台回来卡死几秒」 |
| `08_statemachine.lua` | 纯 C# 类，或导入 `NodeStateMachine` / `XNode` | Godot 4 无内置，可用 `Air` 状态机插件或手写 | 共享状态库在 C# 里更简单：`class WalkState : State`，用 `new` 而不是单例即可天然隔离 |
| `08_statemachine.lua` 状态震荡预算 | 每次 `Update` 限制转移次数 | 同 | ⚠️ **C# 同样会死循环**（转移不 yield，每帧转移次数不限）。移植时务必保留这个计数器 |
| `09_savegame.lua` 迁移钩子 | `[Serializable]` + `ISerializationCallbackReceiver`，或自写 `Migrate(vN)` | Godot 的 `Resource` 无版本迁移，需自写 | ⚠️ Unity 的 `JsonUtility` **不保存嵌套对象数组，且会把缺失字段填成默认值**，读旧存档时会静默得到错误数据（而不是报错）。这是最隐蔽的一类存档 bug |

---

## 六、开发过程中真实踩到的坑（都在代码注释里留了记录）

这些都是**实际跑起来才暴露**的问题，静态检查发现不了：

1. **`Class()` 多传参数被静默丢弃** — `Class(Base, ctor, nil, props)` 写了 4 个参数，
   而 `Class(base, _ctor, props)` 只有 3 个形参。props 被静默丢弃，属性 setter 完全失效，
   **不报任何错**。已在 `01_class.lua` 加入实参个数守卫。
2. **`Class(function...)` 不继承任何东西** — 第一个参数是函数时被当成「根类构造函数」，
   派生类拿不到父类方法。症状是「方法明明在父类上却调不到」。
3. **顶层 `...` 在 Lua 5.2+ 是语法错误** — 用 `if ... == nil then` 判断主 chunk，
   在 5.1 能编译，5.2+ 直接编译失败。已改为比对源文件名与 `arg[0]`。
4. **`unpack` 在 5.2 被移除** — 必须写 `table.unpack or unpack`。
5. **`math.rad` 在 5.3 被移除** — 改用显式 `x * math.pi / 180`。
6. **`tonumber("nan")` 返回 nil 而不是 NaN** — 导致「NaN 拦截」的判据
   `v ~= nil and not is_finite(v)` 永远不成立，NaN 被当成 nil 静默放过。
7. **状态机震荡导致协程永不 yield** — 玩家站在猎犬身上时 attack↔chase 每帧互切，
   `Think` 永远返回「本帧不要 Sleep」，整个游戏卡死。已加转移次数预算。
8. **`#` 作用在哈希表上返回 0** — `scheduler.tasks` 是以协程为键的哈希表，
   用 `#` 统计协程数会永远得到 0，看起来像「协程全没了」。
9. **事件总线把 `onremove` 也过滤掉了** — 导致修饰器袋的自动撤销机制完全失效
   （症状：buff 实体消失了但效果还在）。
10. **浮点累加导致「整整一天」不算过** — 3000 次累加 1/30 后理论是 100.0，
    实际可能是 99.99999，`floor` 后日期永远不翻页。

---

## 七、目录

```
03-参考架构/
├── README.md               本文件
├── _run_lua.py             跨版本 Lua 运行器（基于 lupa）
├── 01_class.lua            类系统
├── 02_scheduler.lua        tick 协程调度器
├── 03_entity.lua           实体 / 组件 / 事件
├── 04_meter.lua            生存数值条
├── 05_sourcemodifierlist.lua  修饰器袋
├── 06_prefab_spawn.lua     预制体与生成
├── 07_world.lua            世界与主循环
├── 08_statemachine.lua     AI 状态机
├── 09_savegame.lua         存档
└── main.lua                整合演示
```

依赖顺序：`01 → 02 → 03 → 05 → 04 → 06 → 07 → 08 → 09`。
`04`（数值条）依赖 `05`（修饰器袋），这是刻意的 —— 修饰器袋是数值条的基础设施。