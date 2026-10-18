// spec-behaviourtree.mjs —— behaviourtree.lua 注释规格汇总入口
// 逐段合并 spec-behaviourtree-p1..p5.mjs 的 BEFORE / AFTER 映射。
// 同一行号可被多段规格命中：此时把注释**拼接**（后一段接在前一段之后），
// 因为注入的全部是 `--` 注释行，拼接不影响任何语义，也不会覆盖丢失。

const parts = await Promise.all([
  import("./spec-behaviourtree-p1.mjs"),
  import("./spec-behaviourtree-p2.mjs"),
  import("./spec-behaviourtree-p3.mjs"),
  import("./spec-behaviourtree-p4.mjs"),
  import("./spec-behaviourtree-p5.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   依赖与四状态常量（1-8）     —— 状态是字符串枚举，且是全局 API",
  "--  §一   BT 外壳（12-47）            —— ★★ 「一次思考 = 三段式事务」",
  "--  §二 ★ BehaviourNode 基类（52-191）—— 生命周期五钩子 + 休眠协议",
  "--  §三   装饰器基类与条件类（195-253）—— 判定 / 等判定 / 两段式判定",
  "--  §四   动作与等待（259-299）        —— ★ WaitNode 的符号笔误",
  "--  §五   Sequence（304-336）          —— 「RUNNING 是唯一记忆」",
  "--  §六   Selector（340-375）          —— 与 Sequence 严格镜像",
  "--  §七   三个装饰器（378-423）        —— Not / FailIfRunning / FailIfSuccess",
  "--  §八   Loop（427-480）/ Random（484-530）—— 循环与随机选址",
  "--  §九 ★★ Priority（533-638）        —— ★★ 决策层的心脏 + ★ H1 缺陷现场",
  "--  §十   Parallel（644-695）          —— ★ 中断的唯一载体",
  "--  §十一 ★★ EventNode（702-765）     —— ★★ 事件驱动 + ★ 第二处破坏性 Reset",
  "--  §十二 语法糖（771-798）            —— While / If / IfThenDoWhile 的语义谱系",
  "--  §十三 LatchNode（801-826）         —— 唯一的限流节点（对照 ConditionWait）",
  "--",
  "--【★★ 全文件最重要的九条】",
  "--  1. 三段式：Visit（决策）→ SaveStatus（快照）→ Step（复位）。三者顺序不可换。",
  "--     理解这一点是读懂全文件的前提。参见 20-24 行。",
  "--  2. ★「RUNNING 是唯一的记忆」。跨思考周期存活的只有 RUNNING 状态，",
  "--     其余状态一律被 Step 复位。于是「优先级」与「粘性」都由它派生。参见 161-169 行。",
  "--  3. ★ 休眠协议：Sleep() 声明 + GetSleepTime() 查询，返回值三态",
  "--     （0 = 马上 / 正数 = 睡多久 / nil = Hibernate，只有事件能唤醒）。参见 37-43 行。",
  "--  4. ★★ PriorityNode 的 lasttime 是节流的唯一旋钮：period 控制频率，",
  "--     lasttime = nil 表示「立即重排」。两个触发源（632 行行为完成、734 行事件）",
  "--     共用这一个信号。参见 582-636 行。",
  "--  5. ★★ 抢占与中断都靠「破坏性 Reset」实现 —— 全文件**不存在** Interrupt /",
  "--     Suspend / Resume / timeout 中的任何一个。",
  "--     ★ 所以「停止」在本框架里等同于「遗忘」，节点不知情、也无法保留进度。",
  "--     ★★ 这是本文件最根本的结构性缺陷。参见 609 行、724 行、767 行三处现场。",
  "--  6. ★★ 【H1 缺陷定位】bug-patterns.md H1 的根因在 609-611 行：",
  "--     抢占时 `self.children[self.idx]:Reset()` 把正在跑的旧赢家直接清空；",
  "--     而 618 行的 `child:Reset()` 又与 603 行自相矛盾（603 刻意排除 RUNNING，",
  "--     618 却不排除），导致「正在正常执行的行为被无端重置」。",
  "--     ★★ 后果：行为树状态与实体状态（locomotor / bufferedaction）分裂，",
  "--       表现为 AI 原地停下、抽搐、打转，或走到一半重新规划。",
  "--     ★★ 第二处现场在 724-726 行：EventNode 事件重复触发时无条件 Reset 自己的",
  "--       子节点，且未把自身 status 归位，与 751 行的 READY 判断产生矛盾。",
  "--     ★★ 核实过的触发前提：同一 PriorityNode 内有多个 EventNode、",
  "--       且旧赢家也是 EventNode。单一 EventNode 的树（如 rabbitbrain）安全。",
  "--  7. ★ priority 是全文件唯一的优先级数字，且只在 600 行生效。",
  "--     ★★ 默认值 0 + 判据用 `<=` ⇒ 同优先级的事件节点互相可抢占，",
  "--       而遍历按位置顺序 ⇒ **靠后的会压制靠前的**（与「位置即优先级」相反）。",
  "--       一旦树里有多个 EventNode，必须显式指定 priority。参见 600/706 行。",
  "--  8. ★ WaitNode:295 的 `Sleep(current_time - self.wake_time)` 符号写反（应为负值变正值），",
  "--     导致所有 WaitNode 的休眠优化完全失效（睡多久都退化成 0）。",
  "--     ★ 功能正确（靠 wake_time 比较），只是节流白做。参见 295 行的完整分析。",
  "--  9. ★ PriorityNode 根的脑**永远不会 Hibernate**：READY 时 GetSleepTime 返回 0，",
  "--     而 Step 每轮把它复位成 READY ⇒ 每帧被调度、靠树内 O(1) 空转节流。",
  "--     参见 541-562 行。这是「Priority 比 Selector 耗 CPU」的根因。",
  "--",
  "--【⚠ 疑似缺陷清单（共 8 处，均只记录不修改）】",
  "--  L1 ★★ behaviourtree.lua:609-611  抢占时破坏性 Reset 旧赢家（H1 根因）",
  "--  L2 ★★ behaviourtree.lua:618       else 分支无条件 Reset，含 RUNNING，与 603 矛盾",
  "--  L3 ★★ behaviourtree.lua:724-726  EventNode 重复触发时 Reset 自己的子节点",
  "--  L4 ★  behaviourtree.lua:295      WaitNode 的 Sleep 传了负数 → 休眠优化失效",
  "--  L5 ※  behaviourtree.lua:428      LoopNode 的 name 误写为 \"Sequence\"，调试无法区分",
  "--  L6 ※  behaviourtree.lua:59       nextupdatetick 是从未被读取的死字段",
  "--  L7 ※  behaviourtree.lua:586      oldidx 是从未被读取的局部变量（H1 的化石记录）",
  "--  L8 ※  behaviourtree.lua:361/452/497  三处未使用的 local done",
  "--     另有 544/585 行的 `not self.period` 死条件（period 被 535 行兜底为 1）",
  "--",
  "--【★ 事件驱动的完整链路（跨三个文件）】",
  "--  ① 事件源：inst:PushEvent(\"gohome\")  —— entityscript.lua 的事件总线",
  "--  ② 触发：EventNode:OnEvent(721) 被调用",
  "--     · 724-726  若正在 RUNNING 则 Reset 自己的子节点（★ L3 缺陷现场）",
  "--     · 727      triggered = true（★ 只活一帧，741 行清除 —— 存在丢失窗口）",
  "--     · 728      data = 事件负载（全仓库无人读取，是预留扩展点）",
  "--     · 730-732  brain:ForceUpdate() → brain.lua:170-176",
  "--                → BrainManager:Wake(inst) 把实体移回 updaters",
  "--     · 734      DoToParents 清掉所有 PriorityNode 祖先的 lasttime",
  "--                → 下一次 bt:Update 的 585 行 do_eval 必为真 → 全量重排",
  "--  ③ 执行：EventNode:Visit(749) 被遍历到 → 读到 triggered → 转 RUNNING → 跑子节点",
  "--  ★★ 三步缺一不可：只有 triggered 会被休眠挡住；只有 ForceUpdate 会被 period 挡住。",
  "--",
  "--【★ 三种「等待」的语义谱系（选错会造成永久卡树）】",
  "--  ┌────────────────────┬───────────┬──────────┬───────────┬────────────┐",
  "--  │ 节点               │ 容器      │ 等待对象 │ 有终点    │ 期间的表现 │",
  "--  ├────────────────────┼───────────┼──────────┼───────────┼────────────┤",
  "--  │ WaitNode(273)      │ ——       │ 固定时长 │ ✓ 有     │ RUNNING     │",
  "--  │ ConditionWait(242) │ ——       │ 条件成立 │ ✗ 无     │ RUNNING ※   │",
  "--  │ LatchNode(801)     │ ——       │ 冷却结束 │ ✓ 有     │ FAILED ✓    │",
  "--  │ WhileNode(771)     │ Parallel  │ 条件成立 │ ✗ 无     │ 可被中断    │",
  "--  │ IfNode(783)        │ Sequence  │ 判一次   │ ——       │ 不可中断    │",
  "--  │ IfThenDoWhile(792) │ Parallel  │ 一+持续  │ ✗ 无     │ 可被中断    │",
  "--  └────────────────────┴───────────┴──────────┴───────────┴────────────┘",
  "--  ★★ 最危险的是 ConditionWaitNode：条件不成立就永远 RUNNING，整棵树永久停住，",
  "--     且没有任何框架级报错或超时保护。实践中须用外部超时兜底。",
  "--",
  "--【★ behaviours/ 目录（29 个行为片段）—— 本框架的复用机制】",
  "--  behaviours/ 下的每个文件都是 BehaviourNode 的子类或组合，",
  "--  由具体 brain 组合成树。核实到的代表：",
  "--    · panic.lua          Panic       —— 每 0.25~0.5 秒换一个逃跑方向（Sleep 用法范例）",
  "--    · leash.lua          Leash       —— 回家距离约束（自建 Visit + 多个 DBString）",
  "--    · minperiod.lua      MinPeriod   —— 限流（LatchNode 的行为侧同类）",
  "--    · wander.lua / follow.lua / runaway.lua —— 移动类行为",
  "--    · doaction.lua       DoAction    —— 最核心的执行节点（BufferAction 的封装）",
  "--  ★★ 复用靠「回调 + 闭包」：节点不认识实体类型，只接受函数与参数。",
  "--     这正是 54 行基类设计成「只有 fn/action/event」的回报。",
  "--  ★★ 全文件检索确认：LoopNode / RandomNode / ParallelNodeAny / LatchNode",
  "--     在 behaviours/ 中没有对应片段，但被多个 brain 直接使用",
  "--     （braincommon.lua:141/435、oceanfishbrain.lua:184/210 等）。",
  "--",
  "--【★ 与 stategraph.lua 的分工（表现层 vs 决策层）】",
  "--  · Brain + BehaviourTree（本文件）→ 决定「我要去哪、要不要攻击」",
  "--  · StateGraph                 → 决定「我现在播哪个动画」",
  "--  ★ 两者并存而非从属：brain 做出决策后通过 stategraph:GoToState 切换表现状态，",
  "--    stategraph 执行期间（如走路动画）脑仍在独立运行。",
  "--  ★★ 常见的「AI 卡住」是两层的交接问题：brain 认为做完了 → StopBrain，",
  "--    但 stategraph 的动作 handler 因 condition 为假而返回 nil（见 stategraph.lua:430），",
  "--    locomotor 已经走到位却没人接手 → 怪物站住不动。",
  "--    ★ 这是 bug-patterns.md H1「排查方法（相邻问题）」所说的现象。",
  "--",
  "--【★ 性能速查】",
  "--  · 每帧成本集中在「节流路径」（625-636 行），只 Visit 赢家一个 —— O(1)",
  "--  · period 到期才走全量路径（598 行），频率 = 1/period 每秒",
  "--  · RandomNode 的选址是 O(N) 且会「试探执行」（505 行）—— 不可放在脑根",
  "--  · GetTreeString（79 行）是 O(树大小) 且大量字符串分配 —— 只在调试时用",
  "--  · EventNode 的监听在构造期注册（709 行），Stop 才摘除 —— 长期驻留",
  "--  · ※ 全局 NODE_COUNT（52 行）只增不减，但只是数字，无内存泄漏",
];

function merge(field) {
  const out = {};
  let merged = 0;
  for (const p of parts) {
    for (const [k, v] of Object.entries(p[field] ?? {})) {
      if (out[k] !== undefined) {
        out[k] = [...out[k], ...v];
        merged++;
      } else {
        out[k] = v;
      }
    }
  }
  if (merged) console.log(`[info] ${field} 有 ${merged} 处行号被多段规格命中，已拼接`);
  return out;
}

export const BEFORE = merge("BEFORE");
export const AFTER = merge("AFTER");

const srcLineCount = 826;

// 覆盖率自检：确保没有大段连续区域完全没有注释
const commented = new Set([
  ...Object.keys(BEFORE).map(Number),
  ...Object.keys(AFTER).map(Number),
]);
let gaps = [];
let run = 0;
for (let i = 1; i <= srcLineCount; i++) {
  if (commented.has(i)) {
    if (run > 0) gaps.push(`${i - run}-${i - 1}`);
    run = 0;
  } else {
    run++;
  }
}
if (run > 0) gaps.push(`${srcLineCount - run + 1}-${srcLineCount}`);

const bigGaps = gaps.filter((g) => {
  const [a, b] = g.split("-").map(Number);
  return b - a + 1 >= 25;
});
if (bigGaps.length) {
  console.log(`[warn] 以下区段（≥25 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}