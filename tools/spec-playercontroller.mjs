// spec-playercontroller.mjs —— components/playercontroller.lua 注释规格汇总入口
// 逐段合并 spec-playercontroller-p1..p10.mjs 的 BEFORE / AFTER 映射。
// 同一行号可被多段规格命中：此时把注释**拼接**（后一段接在前一段之后），
// 因为注入的全部是 `--` 注释行，拼接不影响任何语义，也不会覆盖丢失。

const parts = await Promise.all([
  import("./spec-playercontroller-p1.mjs"),
  import("./spec-playercontroller-p2.mjs"),
  import("./spec-playercontroller-p3.mjs"),
  import("./spec-playercontroller-p4.mjs"),
  import("./spec-playercontroller-p5.mjs"),
  import("./spec-playercontroller-p6.mjs"),
  import("./spec-playercontroller-p7.mjs"),
  import("./spec-playercontroller-p8.mjs"),
  import("./spec-playercontroller-p9.mjs"),
  import("./spec-playercontroller-p10.mjs"),
]);

export const HEADER_EXTRA = parts[0].HEADER_EXTRA;

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

const srcLineCount = 5941;

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
  return b - a + 1 >= 30;
});
if (bigGaps.length) {
  console.log(`[warn] 以下区段（≥30 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}