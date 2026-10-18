// spec-locomotor.mjs —— locomotor.lua 注释规格汇总入口
// 逐段合并 spec-locomotor-p1..p7.mjs 的 BEFORE / AFTER 映射。
// 同一行号可被多段规格命中：此时把注释**拼接**（后一段接在前一段之后），
// 因为注入的全部是 `--` 注释行，拼接不影响任何语义，也不会覆盖丢失。

const parts = await Promise.all([
  import("./spec-locomotor-p1.mjs"),
  import("./spec-locomotor-p2.mjs"),
  import("./spec-locomotor-p3.mjs"),
  import("./spec-locomotor-p4.mjs"),
  import("./spec-locomotor-p5.mjs"),
  import("./spec-locomotor-p6.mjs"),
  import("./spec-locomotor-p7.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   被注释掉的历史常量（3-16）      —— 寻路策略的演进史",
  "--  §一   Dest 目的地抽象（18-65）        —— 三种目标统一成一个对象",
  "--  §二   双端函数分派（67-264）          —— ★ server/client 各一套同构实现",
  "--  §三   类构造与 setter（266-349）       —— 把分派决策收敛到一处",
  "--  §四   更新生命周期（351-401）         —— 休眠协作（isupdating 标记）",
  "--  §五   移动计时器（403-476）           —— 0.3 秒迟滞 + 客户端预测上报",
  "--  §六   外部速度倍率（478-565）         —— 带来源的倍率表与预测容器",
  "--  §七   地面速度（567-636）             —— ★ 每帧热路径，靠 lastpos 缓存节流",
  "--  §八   临时地面修正（638-679）         —— TTL=0.034 秒的瞬时效果",
  "--  §九   斜向移动（681-739）             —— 朝向与移动方向解耦",
  "--  §十   动作路由（741-980）             —— ★ PreviewAction 与 PushAction 平行实现",
  "--  §十一 GoToEntity / GoToPoint（982-1076）—— arrive_dist 三分支 + 立即到达检查",
  "--  §十二 停止与清理（1078-1160）        —— locomote 事件握手契约",
  "--  §十三 跳跃扫描原语（1162-1343）      —— 边缘检测、平台准入、延迟计时",
  "--  §十四 扫描参数与预约（1345-1414）    —— 步长钳制与平台预约",
  "--  §十五 ★★ OnUpdate（1416-1758）        —— locomotor 的心脏，七段结构",
  "--  §十六 寻路能力 pathcaps（1760-1791） —— 四个查询函数的默认值不一致",
  "--  §十七 FindPath（1793-1863）          —— ★ 只执行不决策，与 C++ 寻路器协作",
  "--",
  "--【本文件最重要的八条】",
  "--  1. 双端分派（272-293）：所有 server/client 差异收敛到 8 个方法指针，",
  "--     公共代码完全端无关。代价：这些方法不能被子类统一 override。",
  "--  2. 速度倍率只在合成点计算（204 行），每帧只有 3-4 次 GetSpeedMultiplier。",
  "--  3. 地面速度靠 lastpos 地块缓存（1438 行）节流，频率降低约 60 倍。",
  "--  4. should_locomote（1638 行）用 `not a ~= not b` 表达状态异或，只在需要时派发事件。",
  "--  5. 到达判定只比 x/z 不比 y（1469 行）—— 否则跨平台移动永远判不到达。",
  "--  6. 接近减速（1747 行）用 sqrt 而非距离平方，下限 1/3 保证不会卡死。",
  "--  7. 跳跃期间 locomotor 完全让权（1425 行），位置由 C++ 物理与状态图负责。",
  "--  8. FindPath 只做两件事：视线通畅就直走，否则提交 A*（1836-1849 行）。",
  "--",
  "--【★ 移植时最需要重写的三处】",
  "--  · DoDelta 同级的 1602-1608「后退转身」是纯经验 hack，斜向与击退场景不准确；",
  "--  · 178-236 行的速度合成逻辑两端必须逐字符一致，否则端间跳变；",
  "--  · 782 与 882 行的 PreviewAction / PushAction 是两份平行实现，",
  "--    加新动作类型时必须同改，否则联机表现与本地不一致。",
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

const srcLineCount = 1865;

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
