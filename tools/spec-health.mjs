// spec-health.mjs —— health.lua 注释规格汇总入口
// 逐段合并 spec-health-p1..p3.mjs 的 BEFORE / AFTER 映射。
// 同一行号可被多段规格命中：此时把注释**拼接**（后一段接在前一段之后），
// 因为注入的全部是 `--` 注释行，拼接不影响任何语义，也不会覆盖丢失。

const parts = await Promise.all([
  import("./spec-health-p1.mjs"),
  import("./spec-health-p2.mjs"),
  import("./spec-health-p3.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §一  属性 setter 回调层（3-60）      —— health 字段变化如何驱动副本同步与战斗阈值",
  "--  §二  构造与存档（62-186）            —— 全部状态字段的初始化清单、只存三样的 OnSave",
  "--  §三  火焰伤害（188-253）             —— 状态机、点燃前摇、每秒 120 点上限",
  "--  §四  月光灼烧（255-316）             —— 位标志归约、来源自摘除",
  "--  §五  回复体系（318-438）             —— 单例 StartRegen vs 多源 AddRegenSource",
  "--  §六  上限与惩罚（440-526）           —— GetMaxWithPenalty 现算、三代减伤机制",
  "--  §七  死亡流程（528-611）             —— SetVal、事件顺序契约、尸体化、淡出",
  "--  §八  DoDelta 全解（613-649）         —— ★ 全游戏所有生存压力的最终汇聚点",
  "--  §九  组件迁移（651-663）             —— TransferComponent 的迁移清单",
  "--",
  "--【全文件最重要的五条】",
  "--  1. DoDelta:613 是七级流水线，顺序不可交换；返回实际生效的 amount。",
  "--  2. DoDelta:629 的 externalreduction 因 `afflicter ~= nil` 短路而对环境伤害无效。",
  "--  3. DoDelta:628 的一代 absorb 若为 nil 会崩（bug-patterns.md 收录的 nil 陷阱）。",
  "--  4. SetVal:585-590 世界事件必须先于实体事件，否则死亡时自删的 prefab 会让世界拿到死实体。",
  "--  5. ForceUpdateHUD:150 用 DoDelta(0, ...) 兼作「HUD 刷新」的通用手段。",
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

const srcLineCount = 665;

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
