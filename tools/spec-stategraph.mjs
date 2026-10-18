// spec-stategraph.mjs —— stategraph.lua 注释规格汇总入口
// 逐段合并 spec-stategraph-p1..p3.mjs 的 BEFORE / AFTER 映射。
// 同一行号可被多段规格命中：此时把注释**拼接**（后一段接在前一段之后），
// 因为注入的全部是 `--` 注释行，拼接不影响任何语义，也不会覆盖丢失。

const parts = await Promise.all([
  import("./spec-stategraph-p1.mjs"),
  import("./spec-stategraph-p2.mjs"),
  import("./spec-stategraph-p3.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   模块头与调度表（1-11）        —— ★★ 四张集合表 + 一个二级索引",
  "--  §一   SendToList 集合路由（13-25）  —— ★ 反查表维护的唯一入口",
  "--  §二   四种状态迁移入口（27-73）     —— 唤醒/休眠/定时睡的三态协议",
  "--  §三   注销与清理（76-107）          —— ★★ 作者自认的维护债",
  "--  §四   主循环 Update/UpdateEvents    —— ★★ 换表法与刻末批处理",
  "--         （109-157）",
  "--  §五   三个值对象（159-211）         —— ActionHandler/EventHandler/TimeEvent",
  "--  §六   State 类（213-262）           —— ★★ 状态是数据不是类层次",
  "--  §七   两级事件派发（264-272）       —— ★★ 事件归属校验",
  "--  §八   StateGraph 组装（274-325）    —— 四个 mod 注入点",
  "--  §九   StateGraphInstance（332-403）—— ★★ 三层记忆与三处不对称",
  "--  §十   动作路由（405-461）           —— ★★ Preview/Start 平行且不对称",
  "--  §十一 事件缓冲（463-494）           —— ★★ 换表式清空",
  "--  §十二 状态标签白名单（500-527）     —— ★★ tag → 实体 tag 全量同步",
  "--  §十三 ★★ GoToState（529-600）       —— 本文件最重要的一步，12 步顺序",
  "--  §十四 标签运行时操作（602-639）",
  "--  §十五 SetTimeout 与 UpdateState     —— ★★ 重入检测（startstate 快照）",
  "--         （641-690）",
  "--  §十六 limbo 生命周期 Start/Stop     —— 状态图停摆协议",
  "--         （692-716）",
  "--  §十七 ★★ Update 休眠裁决（718-744） —— 三态返回值的定义处",
  "--  §十八 客户端预测三件套（746-759）   —— FastForward / ServerStateMatches",
  "--",
  "--【★★ 本文件最重要的八条】",
  "--  1. 三层记忆（statemem / mem / 实例字段）的生命周期截然不同：",
  "--     statemem 每次 GoToState 清空（550 行），mem 永不清。",
  "--  2. GoToState 的 12 步顺序是刻意设计的，两条不变量必须记牢：",
  "--     onexit 能读到即将丢弃的 statemem；onenter 只能靠 params 拿数据。",
  "--  3. 换表法（118-119 / 490 / 149-150）出现三次，",
  "--     解决同一个问题：遍历期间增删表是未定义行为。",
  "--  4. 事件刻末批处理（145 行 UpdateEvents）—— 代价是延迟一帧，",
  "--     收益是事件处理永不重入正在跑的 Update。",
  "--  5. Update 返回三态（0 / 正数 / nil）决定实例的生死（718-744 行）。",
  "--     写了 onupdate → 永远返回 0 → 永不休眠（bug-patterns.md F3）。",
  "--  6. 事件归属校验（265 行 data.state == self.name）：",
  "--     延迟处理的事件必须由「入队时所在状态」的处理器消费。",
  "--  7. SGTagsToEntTags 白名单做「全量同步」而非「只加不减」（559-565 行）：",
  "--     漏删会导致实体标签永不消失，症状是「AI 看起来坏了」。",
  "--  8. 四个 mod 注入点（289 / 301 / 313 / 321）都发生在构造期，",
  "--     且 mod 后注入 → 同名覆盖原版。这是模组生态的技术基础。",
  "--",
  "--【★★★ 本文件收录的疑似缺陷（均为代码阅读推断，未在运行时验证）】",
  "--  ⚠ 1. 第 100 行 `self.tickwaiters[inst] = nil` 是空操作：",
  "--       tickwaiters 是二级表，第一层键是 tick 号，从未有以实例为键的条目。",
  "--       正确写法见 brain.lua:93-95（遍历所有桶）。",
  "--       被 85-88 行的 old_list 摘除掩盖，实际影响是「桶可能滞留」。",
  "--  ⚠ 2. 第 438-439 行 is_going_to_action_state 在 GoToState **之前**设置，",
  "--       而 550 行会清空 statemem → 新状态 onenter 读到的一定是 nil。",
  "--       表现为「执行动作时物品栏被误关」（SGwilson.lua:631 恒为假）。",
  "--  ⚠ 3. 第 442 行读 self.statemem.no_predict_fastforward 恒为 nil：",
  "--       该字段从未被写进 statemem（242/570 行都在别的命名空间）。",
  "--       「按状态禁止预测快进」是死代码，修复应改读 self.no_predict_fastforward。",
  "--  ⚠ 4. 第 682 行 self:Update(extra_time) 的 extra_time 参数被丢弃：",
  "--       Update（718 行）不接收参数，内部用真实时间差重算 dt。",
  "--       掉帧补偿的意图未达成，实际只是多跑一次 Update。",
  "--  ⚠ 5. 第 737 行 self.currentstate.onupdate 无判空：",
  "--       若状态图的 defaultstate 拼错，GoToState（532 行）软失败后",
  "--       currentstate 仍为 nil，实例却已注册 → 下帧 Update 在此崩溃。",
  "--  ⚠ 6. 第 261 行 table.sort + 第 209-210 行比较器不稳定：",
  "--       同一时刻的多个 TimeEvent 触发顺序未定义",
  "--       （与 bug-patterns.md A6 同族）。",
  "--  ⚠ 7. 第 596 行 lasttags 置 nil 与 551 行赋值构成的 API 一致性不足：",
  "--       SGbearger.lua:2235 直接索引、sharkboi.lua:85 加了判空，",
  "--       说明「只在 onenter 期间有效」这条约定未被强制、未被文档化。",
  "--",
  "--【★ 与其他文件的对照（同构孪生 / 同一思想的三次应用）】",
  "--  · brain.lua:2   BrainWrangler —— 与 StateGraphWrangler 同构孪生，",
  "--                  字段名完全一致，但实现细节已各自演化（见 14 行对照）。",
  "--  · brain.lua:136 _safe_updaters —— 换表法的变体（写进数组而非换表）。",
  "--  · entityscript.lua:61 StopUpdatingComponents —— 同一思想的第四次应用。",
  "--  · behaviours/ behaviourtree.lua:533 PriorityNode —— 决策层的对应物，",
  "--    同样有 period 散布（lasttime 随机初始化）防「上百只怪同刻动作」。",
  "--  · stategraphs/commonstates.lua CommonHandlers —— 事件处理器的复用库，",
  "--    是 300 个状态图文件不必各自重写「被打断怎么办」的原因。",
  "--",
  "--【★ 移植时最需要注意的四处不对称】",
  "--  ① PreviewAction 与 StartAction 是两份平行实现（405 / 430），",
  "--     且行为不一致（statemem 标志、预测快进、无 handler 兜底），",
  "--     改动作路由时必须同改，否则联机表现与本地不一致。",
  "--  ② StartAction 在 handler.condition 为假时隐式落出返回 nil，",
  "--     调用方（locomotor）已走到目标位置却等不到状态切换 →",
  "--     「走到某东西面前站着不做任何事」（bug-patterns.md H1 条目）。",
  "--  ③ stategraph 与 brain 的 Sleep 差一个 +1（64 行 vs brain.lua:72），",
  "--     亚帧睡眠的处理方式不同，照抄会产生抖动。",
  "--  ④ stategraph 的 stategraph.lua:113 唤醒时只写 updaters 不写",
  "--     instances 反查表，而 brain.lua:127-128 两处都写。移植应采用后者。",
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

const srcLineCount = 759;

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
  return b - a + 1 >= 20;
});
if (bigGaps.length) {
  console.log(`[warn] 以下区段（≥20 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}
