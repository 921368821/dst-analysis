# 恢复状态（RESUME）

> 任何会话/任何模型读到这个文件，都能无损接续。
> 最后更新：2026-10-15 21:06（实读）—— 新增核对三件套总入口、安全编辑工具、8 类文档规则

## ⚠️ 运行命令（2026-10-18 迁移后：**运行时与路径不再手抄**）

工作区搬过一次家（用户 `35916` → `admin`，工程 `E:/DST-Analysis` → `E:/xnb/DST-Analysis`），
旧命令里那串 `C:/Users/35916/...` 全部失效。现在**只有一个来源**：`<工程根>/tools/env.sh`。

```bash
cd "<工程根>/06-引擎复刻"          # 本机是 E:/xnb/DST-Analysis/06-引擎复刻
. ../tools/env.sh                  # 解析 PY / NODE / ENGINE / RUNNER / DST_SRC（幂等）
"$PY" "$RUNNER" 5.1 "$ENGINE/world.lua"
```

- `env.sh` 里的 `PY` **必须能 `import lupa`**（找不到就报错，不静默降级）
- 若报 `No module named 'lupa'`：`"$PY" -m pip install lupa`（venv 在
  `<用户>/.workbuddy/binaries/python/envs/default`）
- ⚠️ **Lua 5.1 的 `io.open` 在 Windows 上走 ANSI 代码页，打不开 UTF-8 中文目录** ——
  所以工程根下有一个 **`dstsrc` Junction**（指向 `02-注释源码`），`host/00_paths.lua` 优先走它。
  换机器/重装后若报「找不到 DST 源码根目录」，先看这个联接在不在：
  `New-Item -ItemType Junction -Path <根>/dstsrc -Target <根>/02-注释源码`

## ★★ 本地能做什么 / 不能做什么（三层，别混）

| 层 | 能不能 | 怎么用 | 证据 |
|---|---|---|---|
| **① 引擎（无头）** | ✅ **能跑** | `python _run_lua.py 5.1 <入口>.lua`，14 个入口 | 真在跑**原版 DST 的 Lua**（不改一行） |
| **② 本地「看」** | ✅ **能看** | 双击 `_out/world_player.html`（10.2 MB **完全自包含**，0 个外部引用） | 播放预烘焙轨迹；可暂停/调速/缩放/网格/标签/跟随实体 |
| **③ 本地「玩」** | ❌ **不能** | —— | 播放器只有**查看器控件**；唯一的键盘处理是 `Space → 播放/暂停`；**没有「输入→模拟→画面」闭环** |

**② 的播放器不是游戏**：它消费的是**已经烘焙好的帧**（`_out/*.json`），
唯一的键盘绑定是空格 = 播放/暂停，没有任何控制角色的输入。

**③ 为什么不做**：`P2-2 实时模式（把 Lua 编译到 JS）` 在报告里被**明确列为不做**
（「成本远高于边际价值」）。要做「能玩」需要两步，都不是小工程：
1. 让 Lua 引擎在浏览器里真跑（Fengari/WASM，或做成原生宿主）；
2. 加输入层（键盘 → 玩家 ACTIONS → 组件）+ **每帧回传新帧**（而不是播放烘焙帧）。

**另注**：本工程是**契约复刻引擎**，不是 DST 本体；原版 DST 客户端本来就能玩（与本工程目标不同）。

## ★★ 能不能「用这个引擎开发游戏」—— 分两种「开发」

**A. 在 DST 生态内做内容开发（写 prefab / 组件 / 大脑 / 状态机）—— ✅ 可以（已实测，不是声称）**

**复跑命令**（看它自己给自己打分）：
```bash
"$PY" "$RUNNER" 5.1 "$ENGINE/_demo_newcontent.lua"   # 先 . ../tools/env.sh
```
`_demo_newcontent.lua` **真的做了一遍**：定义全新组件 → `Core.RegisterComponent` 注册
→ 用**原版 `Prefab()` 语法**定义新预制体 → 与原版组件（health / lootdropper）共存
→ spawn → 跑 60 tick 观察。**实测 10 通过 / 0 失败**，例如：

```
✔ 原版组件的**行为**真的生效        health 37 → 25
✔ 新组件的 OnUpdate 被**更新泵**每 tick 调到 tick 0 → 60（跑了 60 次）
✔ 新组件读到的是**真实世界时间**  每 10 tick 记一次 ⇒ 6 个标记，时刻=0.333,0.667,1,…
✔ 未注册的组件返回 nil（不是假成功）
```
（时刻 `0.333…` = 10 tick ÷ 30 tick/s，连 tick 率都对上了。）

**这条路的能力边界（实测得出，不是猜）**：
- 新组件走 `Core.RegisterComponent(name, ctor)` —— **不必**往原版 scripts 树里塞文件；
  否则回退链会去 `components/<name>.lua` 找（那里搜不到就记缺口并返回 nil）；
- 带 `OnUpdate` 的组件**必须显式** `inst:StartUpdatingComponent(cmp)` ——
  **原版 `AddComponent` 本来就不自动做**（已核对 `entityscript.lua`），这点与原版一致。
- 这三条已**锁进 `tests.lua` 的 TC25**（82 条断言），防回归。

**它仍是的强项（相对原版）**：写完能**无头、秒级、可断言地**验证逻辑。

- 你写的 Lua 走的是**原版同一套系统**（prefab / component / brain / stategraph），
  写完能**无头跑起来验证**（14 个入口 + `tests.lua` 的 79 条断言就是这个用法）；
- **保真度高**：同一份脚本**不改一行**也能进真实 DST ⇒ 可以「先在这里验证逻辑，再进游戏看表现」；
- **局限**：验证是**脚本化 tick 驱动**的 —— 没有玩家操作、没有实时画面。

**B. 拿它当引擎做独立游戏（有玩家操作、实时画面、能发布）—— ❌ 现在不能**

我逐项查过宿主，**四件核心东西都缺**：

| 缺什么 | 现状（证据） |
|---|---|
| **输入** | `TheInput = {}` 是个**空表**（只为「不 nil」而登记）；`OnKeyDown` 等 **0 处实现** |
| **实时循环** | 入口用 `for i = 1, spec.n` 跑**固定 tick 数**；没有「输入 → 每帧步进 → 回传」的闭环 |
| **存档** | `SaveIndex` **0 处**；`OnSave`/`OnLoad` 只是组件**名字表**里的条目 |
| **网络 / RPC** | `GetRPC` **0 处**；`SendRPCToServer` 只出现在**一句注释**里 |
| **实时渲染** | `render.lua` 是**离线出 PNG**；浏览器端是**回放预烘焙帧** |
| **新资产管线** | 图集/动画来自**原版资产**（`build_world_player.py` 消费原版 atlas） |

**要变成「能开发游戏」需要补的（按性价比排序）**：
1. **输入层 + 实时循环**（中）：键盘 → 玩家 `ACTIONS`/组件；「每帧 step + 回传新帧」。
   渲染可先用现有帧路做 15~30 fps 的粗略实时。
2. **存档**（小~中）：实现 `SaveIndex` / 序列化，让世界能存读。
3. **新资产管线**（大）：让 build/anim 能来自自定义资源，而不只是原版图集。
4. **网络**（大）：真实 RPC / 客户端-服务器（若要做多人）。

**★ 一句实话**：这个工程的**设计目标不是当通用引擎**，而是
「**验证原版脚本能否不改一行跑起来**」。它的最大价值是**保真度**
（14 入口 + 79 断言 + 0 真缺口 + 0 桩调用），**不是「能发布的游戏」**。
⇒ 若目标是做游戏，**用它做「逻辑验证层」、用别的做「表现/交互层」**，是更划算的分工。

## ★★ 旁边还有一个工程：`07-通用引擎`（把本引擎变成「能实时玩、能发布」的）

如果你要做的**不是**「验证原版脚本能不能不改一行跑起来」，而是**实时 / 可发布**，去那边：

```bash
cd "<工程根>/07-通用引擎"          # 本机是 E:/xnb/DST-Analysis/07-通用引擎
bash deploy/start.sh 8765 30     # 起实时服务端（自带端口守卫 + 健康检查）
bash tests/run_all.sh            # 13 组 + 宿主 14 入口（项数由 tools/verify_plan.py 机械核对）
cat README.md                    # 30 秒上手 + 已验证到什么程度 + 已知限制
```

**边界（别搞混）**：
- `06-引擎复刻`（本目录）= **保真度**度量：14 入口 / 82 断言 / 0 真缺口。**不要为实时需求去改它。**
- `07-通用引擎` = **实时与发布**：权威 Lua 服务端 + 浏览器客户端 + 二进制帧 + 存档 + 资产打包 + 部署包。
  它**复用** `06-引擎复刻/host/*`，**不改**原版脚本。

## ★★★ 开工前先跑一遍：`bash tools/check_all.sh`

**一条命令跑齐三个核对工具**（以前要分别跑，很容易只跑一个就以为「都绿了」——
这种漏跑今天发生过多次）：

| 工具 | 查什么 |
|---|---|
| `tools/audit_fixes.py` | 修复清单是否都在（**特征串质量 / 自满足 / 歧义锚点 / 豁免**一并报） |
| `tools/audit_doc_numbers.py` | **全部 md** 的数字、时间戳、类别名表格一致性（8 类规则 + 配置自检） |
| `tools/verify_report.py` | 报告关键数字 vs 实跑（较慢，约 2 分钟） |

```bash
bash tools/check_all.sh          # 全部（约 3 分钟）
bash tools/check_all.sh --fast   # 跳过 verify_report（约 10 秒）
```
**退出码 0 = 三项全绿**；任一项红 ⇒ 非 0，并会打出是哪一项。

## ★★ 改文件前先用 `tools/safe_edit.py` 验锚点

**为什么**：今天**三次**把文件插坏，根因都是
`s.replace("def main():", 新函数 + "def main():", 1)`
命中的**不是定义**，而是**别处注释/字符串里引用的同一个串**（`replace(...,1)` 只认第一次出现，
**不问这段文本是什么身份**）。

```bash
python tools/safe_edit.py --file tools/xx.py --anchor "def main():"     # 只体检
```
它会列出锚点在**每一处**的身份（代码 / 字符串 / 注释 / 行首），并**拒绝**危险情形：
- 只在字符串/注释里 ⇒ 拒绝（会改到「文本」）
- 在代码里出现多次 ⇒ 拒绝（换更长的锚点，别赌「第一次」）
- 通过时**只按代码身份那一处**替换（不用 `replace(...,1)`）

实测那个插坏过三次的锚点：`def main():` 在注释里出现 **4 次**、真正的定义在**行首 1 次**——
`replace(...,1)` 会打到注释，而这个工具只打定义。

## 本轮新增（2026-10-14 下午/傍晚）

| 主题 | 结果 |
|---|---|
| **符号覆盖到画面** | wilson 戴橄榄球帽，像素级验证 133 像素 / 单连通块；`tools/verify_override.py` 可一键复跑 |
| **昼夜循环** | 真实 `clock.lua`，0/240/420/480 s 相位与 seasons 的 8/6/2 段分毫不差 |
| **世界组件 5/5** | clock / worldtemperature / seasons / shardstate / worldreset 全部挂上 |
| **季节与温度** | 温度按 DST 模型起伏（白天 24.5→27.0，夜晚 16.8）；`WORLD_SEASON=winter` 可切冬季（-24.3°C） |
| **生物作息** | 夜里 `rabbit:sleeping` 19% / `beefalo:sleeping` 18%（全由原版 brains 读世界状态得出） |
| **KTEX 格式** | 全库 3242 样本证明**没有格式字段**，格式由 pitch 隐含；DXT5 用 alpha 干净度确证 |
| **扩大场景压测** | 10 种生物，又挖出 8 个真缺口全部修掉 ⇒ 缺口清单与标准场景一致 |
| **静态景物** | +70 个（树×20 草×26 树苗×16 浆果丛×8）；石头**诚实放弃**（无可解码动画） |
| **★ 实体休眠** | 补上「远离玩家就睡着」：帧率 552 → **1212** tick/s，入睡 57/89 |
| **★★★ 卸下装备 bug** | `OverrideSymbol` 单边登记 ⇒ 卸下后帽子留在画面上。已修（账本成对撤销）。新入口 `equip.lua` |
| **★★ 燃烧链路** | 新入口 `burn.lua`：点燃→1350 tick 烧完→砍→掉 charcoal。修掉 2 个缺失全局（`stringutil` / `PrefabExists`） |
| **★★★ 行为断言回归** | 新入口 `tests.lua`（当时值 17 条断言，现 **70** 条）抓出 `PrefabExists` **从未生效过**（同名局部遮蔽）|
| **★★ 生物 10 → 14 种** | 27 只实体；全局状态名 25 → **36 种** |
| **★ 默认后端换 WebGL** | 逐字节一致 + 快 3.8x 已验证；`?renderer=2d` 保留为降级与 A/B 对照 |
| **★★ 指标口径纠正** | 「状态图状态种类」实为**每实体求和**（会随生物数增长）；全局去重仅 25 种。现在两个口径都报 |
| **★ 完整四季循环** | 新入口 `seasons.lua`：顺序 / 昼夜分段 / 温度区间三项全对 |
| **★ 休眠补全** | 状态图也进 `hibernaters` 桶（`sg.Start` 传 `IsAsleep()`） |
| **★★ 数字可信度分级** | 方差与「离纯几何多远」成正比：撞墙 1.06x ＜ 状态种类 1.20x ＜ 战斗 1.45x ＜ 帧率 3.1x |
| **★★ 测量纠正** | 帧率是**双峰分布**（10 次采样 333~1020，中位数 374）；此前报的「1000+」全是快尾幸运样本 |
| **★ 限制显式化** | `world.lua` 结尾输出 7 条「已知宿主限制」，每条附会导致什么现象 |
| **★★ 死亡掉落修复** | `DropDeathLoot` 曾被桩成**空函数**（不报错、不进缺口清单）—— 已按原版实现，猪人死了真的掉肉 |
| **指标** | 真缺口 **1**（DST 里不存在的 choptree）· 桩调用 **无** · 七入口全 PASS |

详细过程见 `世界可跑可看报告.md` 第 12~16 节。

## 任务

**验证「DST 原版 Lua 脚本能否在契约复刻版引擎上不改一行运行」**
→ **已达成。且已从「逻辑活着」跨到「看得见的游戏」：**
**玩家 + 9 只生物在真实地形上真的走动/追逐/战斗，全过程逐 tick 导出，
用浏览器 canvas + 真实图集**按真实时间轴回放**（预烘焙轨迹，**非交互**）（`_out/world_player.html`，10.2 MB 自包含）。**

## 当前成果

| 入口 | 结果 |
|---|---|
| `run.lua` | pighouse 453 行未改 → 实例化 + 600 tick 无错，pigman 真实生成 |
| `batch.lua` | **✔ 300 tick 完成**（此前在此中断）· 0 失败 · 38 重新实例化 |
| `compdiag.lua` | 38 组件加载诊断（34 成功） |
| `player.lua` | **wilson 88 组件** · AllPlayers 非空 · playerprox 走真实分支 · 真实状态机端到端跑通 |
| `full.lua` | 全量 prefab 文件 → **1525 注册成功 / 0 失败 / 注册表 6081 个预制体** |
| `play.lua` | **无头游戏运行**：4 种生物带真实大脑 → 3000 tick 无错 |
| `render.lua` | 四种生物导出绘制列表 → 外部光栅化 → PNG 出图 |
| `world.lua` | **★ 正式入口**：真实地图 128×128 + 真实物理 + 真实大脑 + 真实战斗，2400 tick，~2800 tick/s，轨迹导出 `_out/world.json` |

本阶段补的三层能力（详见 `世界可跑可看报告.md`）：

- **net 变量层**（`host/12_netvars.lua`）—— 补 C++ 的 netvar 三件套契约
- **replica 分发层**（`host/14_replica.lua`）—— 逐字照抄 19 项白名单 +
  `*_classified` 按需加载（启动期预加载会让 full.lua 口径掉到 1520）
- **AddComponent 顺序修复** —— 必须**先** ReplicateComponent **再**构造组件
  （`entityscript.lua:626-633`），否则 `combat.lua:5` 三级因果链炸

★ **AnimState 动画队列修复**（`host/10_animstate.lua`）—— 本阶段最重要的
引擎语义修复：`PushAnimation` 晚于 `animover` 一帧入队（因为 SG 是刻末批处理），
旧代码 `if self._fired then return end` 会把队列永久短路 →
蜘蛛走 40 世界单位动画却冻结在 `walk_pre` 第 6 帧。修复后状态序列变成干净的
`walk_pre → walk_loop → walk_pst`，pigman 追逐真的用跑的动画。

复用真实 DST 文件：class / tuning(5163 键) / constants / scheduler / stategraph /
simutil / sourcemodifierlist / commonstates / standardcomponents / prefabutil /
worldsettingsutil / clothing / bufferedaction + player_common(2986 行)
+ 87 个真实组件 + mathutil.lua

## 下一步（按价值排序）

1. **接渲染到 GPU**（LÖVE2D/WebGL）—— 现在 GetDrawList + 播放器数据全通
2. **让播放器消费符号覆盖**（`bld` 字段）—— 宿主已能解析覆盖并回传 build 名，
   但 `build_world_player.py` 还只用实体自己的 build；等有实机装备时可显示出来
3. **`worldstate` 的环境变量（季节/温度）** —— `worldstate.lua` 现在能加载了，
   但宿主没有时间/季节推进
4. **剩余真缺口只有 1 个**：`require:behaviours/choptree`（DST 里真不存在）

> ✅ 已完成：装备/换装路径、worldstate/worldsettings（实测已能加载）、
> render_frame.py 光栅化、hash 算法实证、配方系统（1122 个）、静态调度器、
> GetParent 语义。

## ★ 系统性设计（移植时直接复用）

1. **全局表守卫**（`04_loader.RearmGuards`）—— DST 里 `TUNING={}`、
   `WORLD_TILES={}` 会被反复重建、冲掉元表。登记后每次执行文件自动重挂
2. **契约发现模式**（`Loader.DiscoverGlobals`）—— 给 `_G` 装元表，
   未知全局自动返 0 并记录；加载 tuning/constants 的必备手段
3. **表驱动桩生成器**（`00_stubs.lua`）+ **装饰器机制**（`Stubs.AddDecorator`）
   —— 桩建好后由宿主模块接管升级为真实实现（AnimState/Physics 都这么接的）
4. **按名分派的地图兜底**（`05_bootstrap.lua`）—— 坐标类查询返 nil、
   判定类返 0。一刀切返 0 会让 `spawnpos:Get()` 崩（实测）
5. **netvar 三件套契约** —— `value()` 读 / `set(v)` 权威写（仅真变化才派发）/
   `set_local(v)` 本地写不派发
6. **replica 结构逐字对齐** —— `self.replica = { _ = {}, inst = self }` +
   `setmetatable`；`_` 必须 rawget/rawset（否则 `__index` 无限递归）

## 运行命令

```bash
cd "<工程根>/06-引擎复刻"
. ../tools/env.sh                  # PY / RUNNER / ENGINE 都由它解析（别再手抄路径）
# 14 个入口（world.lua 是正式入口；全部跑一遍见 tools/check_all.sh）
"$PY" "$RUNNER" 5.1 "$ENGINE/world.lua"

# 重建播放器
"$PY" tools/build_world_player.py
```

## 踩过的坑（都是实际的，别重犯）

### 引擎/加载类
1. **`class.lua` 不 return** —— 定义全局 `Class`
2. **`tuning.lua:3` 执行 `TUNING = {}`** —— 重建全局表，冲掉元表
3. **`constants.lua` 同样重建 `WORLD_TILES`**，且某 map 模块**懒加载时再重建一次**
4. **`DiscoverGlobals` 结尾 `setmetatable(_G, nil)`** 会擦掉万能兜底 → 必须保存并恢复
5. **`inst:GetPosition()` 必须返回 Point 对象**（entityscript.lua:1356），
   返回 x,y,z 三值会让 `knownlocations.lua:64` 崩
6. **桩的 `_x/_y/_z` 必须初始化** —— 元表不拦下划线键，未初始化就是 nil
7. **组件基类方法要注入类表**（构造体内就调用，注入实例太晚）
8. **`CommonHandlers` 来自 stategraphs/commonstates**
9. **`TheNet:GetIsMasterSimulation` 不是 EntityScript 方法**（是 TheNet 的）
10. **TUNING 缺键返 0 而非 nil**（否则 `math.min(x, nil)` 崩）
11. **桩的 `__index` 不能拦下划线键**（否则 `_bank` 等状态字段全变函数）
12. **`pairs` 遍历中删表** → "invalid key to 'next'"，要先取快照
13. **万能兜底只在实例化阶段启用** —— 全程开启会让 simutil 加载失败
14. **`FindClosestPlayerInRange` 第 4 参是 range**（内部自己平方），
    第 5 参 isalive 传 nil 才对（传 false 变成「只要死掉的」）
15. **真实玩家预制体自己注册进 AllPlayers** —— 别手工 insert（会重复）
16. **prefab 声明的依赖必须递归加载**（`Bootstrap.LoadPrefabFile`）
17. **平台判断全局（IsConsole 等）必须是函数**，返 0 会 "call a number value"
18. **`playerprox:ForceUpdate()` 只在 `self.task ~= nil` 时执行**，
    task 由 `Schedule()` 创建；回调字段是 `onnear`/`onfar`，有正规 Setter
19. **`components/mound.lua`、`deployer.lua` 在 DST 里真不存在** ——
    缺口报告说它们缺失是准确的，不是 bug

### 本阶段新增
20. **netvar 层是 C++ 的，Lua 侧零实现** —— `scripts/netvars.lua` 279 行只有注释
21. **AddComponent 必须**先** ReplicateComponent 再构造组件** ——
    服务端组件 setter 会把值推进 replica（`combat.lua:4-6`）
22. **`*_classified` 要按需加载** —— 启动期预加载会让 full.lua 口径偏移
23. **`replica._` 必须 rawget/rawset** —— 走 `__index` 会无限递归
24. **★ PushAnimation 晚一帧入队** —— SG 是刻末批处理，动画队列消费绝不能
    放在 `if self._fired then return end` 之后（否则蜘蛛动画永久冻结）
25. **玩家驱动要「到达才推进路点」** —— 固定间隔重设目标会因「目标比玩家慢」
    退化成走 4 tick 停 8 tick（量纲问题，可算出来）
26. **wilson 无 walk_* 状态** —— SGwilson 只有 run_start/run/run_stop，
    所以 `GoToPoint` 的 wantstorun 对 wilson 无效（这是真实的）
27. **中立生物不会主动攻击** —— 必须 `Combat:SetTarget`（等价玩家招惹）才有追逐戏
28. **wilson 动画要放宽命中率阈值** —— build 只有 15 个符号（装备槽另算），
    默认 0.85 会全部被丢；用 `ANIM_HIT_THRESHOLD=0.30`
29. **★ 引擎字符串哈希是 sdbm**（67/67 实证）—— 不是 fnv/djb2/crc32。
    `sdbm("feet_horseshoe") == 0x7BB765F7` 与 clothing.lua 的 CLOTHING_SFX 键吻合。
    Lua 5.1 无位运算，用等价乘法式 `(c + h*65599) % 2^32`
30. **`GetSymbolOverride` 返回哈希不是名字**（CLOTHING_SFX 用数字键 +
    balloon_held_child 塞 netvar 回退写 0），但 `OverrideSymbol` 收名字 —— 两边都要兼容
31. **`AddOverrideBuild` 是给「base build 没有的符号」用的** ——
    wilson 动画引用 12 个 build 外符号哈希（全是装备槽），漏了会静默丢元素
32. **`SetBuild` 不清符号覆盖**（反证：ClearOverrideBuild/ClearAllOverrideSymbols
    作为独立方法存在就说明它冗余）
33. **泛化桩的 setter 存 `_"..方法名小写`，getter 读的却是语义键** ——
    `SetMass(5)` 落进 `_setmass`，`GetMass` 读 `_mass`，永远返回初值
34. **render_frame.py 的顶点池是三角形列表** —— 旧代码只画前 2 个三角形，
    nv 越大丢越多（hair nv=114 只画 2/38 → 条纹噪点）；且 `tex = texs[0]`
    恒用第一张图集，多图集 build 直接采错纹理
35. **PreviewBufferedAction 的去重比的是对象同一性** ——
    真实 DST 里 action 是 ACTIONS 单例，测试必须复用同一张表才能触发去重
36. **★ 这个工程的 A/B 必须多次采样** —— world.lua 有 1-in-5 长尾
    （`pairs()` 顺序 → 生物行为不同），单次/3 次采样会把人带歪。
    我曾据此错误地回退过 4 处正确实现
37. **★★ `entity:GetParent()` 返回父 EntityScript，不是实体句柄** ——
    铁证是原版 classified 预制体里成片的
    `inst._parent = inst.entity:GetParent()`（container_classified.lua:69 等 4 处），
    而 `_parent` 随后被当 EntityScript 用（`.components` / `.replica`）。
    返回句柄会让 `_parent.components` 变成**函数**（命中句柄兜底 `__index`）
38. **★ 真实 scheduler.lua 有两个驱动入口**（scheduler.lua:582 / :596）：
    `RunScheduler`（update.lua:247）与 `RunStaticScheduler`（update.lua:185）。
    只接前者 → `staticScheduler` 永远不动，`DoStaticTaskInTime` 全部失效
39. **`toarrayornil` 存在是为了绕开 Lua 陷阱** —— 无参时 `{...}` 是 `{}`，
    而 `{}` 是 **truthy**，`if args then` 会被骗过。必须「无参返 nil」
40. **`05_bootstrap.lua:26` 是按值拷贝 `G` 到 `_G`** —— 写 `G.__x` 外部读不到，
    诊断计数要写 `_G.__x`
41. **★ 报错行号要对齐真正加载的那份文件** —— 宿主加载
    `.qwenworkcn/.../scripts/`，而 `02-注释源码/scripts/` 是**另一份**（有注释、
    行号不同）。查错文件会浪费很多时间
42. **兜底全局对象是 truthy** —— `CHEATS_ENABLED` 这种正式版为 `false` 的布尔量，
    拿到兜底对象会走错分支
43. **★ `SpawnPrefab` 必须能「查不到就现加载」** —— 真实 DST 启动时注册全部
    prefablist；宿主改成按需加载后，数据驱动的生成（如
    `herdmember.lua:60 SpawnPrefab(self.herdprefab)`）就找不到定义。
    修法与 `ensure_classified` 同套路

## 文件清单

| 文件 | 作用 |
|---|---|
| `host/00_stubs.lua` | C++ 组件桩生成器（表驱动）+ 装饰器机制 |
| `host/01_core.lua` | 实体/组件/标签/事件/任务/预制体（含 replica 结构） |
| `host/02_sim.lua` | TheSim + 世界 + 主循环 + 状态图调度 |
| `host/03_globals.lua` | 引擎单例 + TUNING/ACTIONS/netvar/Vector3 |
| `host/04_loader.lua` | require 钩子 + 契约发现 + 全局表守卫 |
| `host/05_bootstrap.lua` | 统一启动序列（含 netvars/replica/装饰器安装） |
| `host/06_entityscript.lua` | EntityScript 130 方法契约补全 |
| `host/07_universal.lua` | 万能兜底全局（临时启用） |
| `host/12_netvars.lua` | **net 变量层**（C++ 侧契约） |
| `host/13_update.lua` | 组件更新泵（locomotor/health 等的 OnUpdate） |
| `host/14_replica.lua` | **replica 分发层**（19 项白名单 + classified） |
| `host/20_map.lua` | **真实地图**（瓦片编号 + 可通行判定） |
| `host/10_animstate.lua` | **AnimState 真实实现**（帧推进/动画队列/GetDrawList）+ **符号覆盖体系** |
| `host/11_physics.lua` | **Physics 真实位移** + 碰撞体/材质属性（含半径进碰撞） |
| `host/06_entityscript.lua` | EntityScript 契约补全 + **BufferedAction 体系** |
| `world.lua` | **正式入口**：真实地形 + 物理 + 大脑 + 轨迹导出 |
| `tools/build_world_player.py` | 世界轨迹 + 真实图集 → 自包含 HTML 播放器 |
| `run/batch/player/play/full/render.lua` | 七个验证入口 |
