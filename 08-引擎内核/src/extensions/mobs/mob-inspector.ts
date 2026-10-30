/**
 * L4 · 生物调试面板的**文案模型**（面板画什么字）
 *
 * 为什么文案要抽成一个纯函数，不直接写在宿主里拼：与 `host/hud-model.ts` 同一条理由，
 * 但这里多一条更硬的 —— **面板要显示的是"这一拍的决定"，而那是一个随时间消失的东西**。
 * 拼字符串的代码一旦散在渲染循环里，"显示的是哪一拍"就没人说得清；
 * 抽成纯函数之后，判据可以直接拿一份 `MobExplain` 断言"显示的正是它"。
 *
 * ★★ 三个决定：
 *
 * ① **`wanted` 与 `treeId` 都显示**（对应 `MobExplain` 的那两个字段）。
 *    只显示实际用的树时，「配了 `asset:hound_v2` 但库里没有 ⇒ 正在跑内置树」
 *    在面板上与「配了内置树」一模一样 —— 而那正是最需要看见的一刻。
 *
 * ② **决定为 `null` 时显示 `-`，绝不显示"上一次的决定"**。
 *    面板的语义是「这一拍」，不是「最近一次」。留着旧值会让人以为它还在追，
 *    而实际上它已经什么都不做了（找不到自己 / 没有可走的格）。
 *
 * ③ **文案只许 ASCII**。引擎的位图字体只有 5×7 的 ASCII 字形（见 `tools/make-ui-assets.mjs`），
 *    中文字符不会报错、不会崩 —— 它会**静默变成空白**，还占着宽度。
 *    所以文案里一个中文都不放，判据里有一条逐字检查（与 HUD 同一条闸门）。
 */

import type { MobExplain } from "./mob-brain.ts";

/** 一行面板：`label` 是固定的英文键（人扫左边），`value` 是这一拍的值。 */
export interface InspectRow {
  readonly label: string;
  readonly value: string;
}

/** 值的三种"空"：找不到自己 / 这一拍没有决定 / 没配树。**三件事不能合成一个 `-`**。 */
const NO_CELL = "-";
const NO_DECISION = "-";

function treeValue(e: MobExplain): string {
  // 见文件头 ①
  const base = e.treeId === "" ? "builtin" : e.treeId;
  if (e.treeSource === "missing") return `${base} (miss ${e.wanted})`;
  if (e.treeSource === "default") return `${base} (default)`;
  return base;
}

/** 目标：`hunt #12@345` / `roam 345` / `-`（见文件头 ②）。 */
function goalValue(e: MobExplain): string {
  const d = e.decision;
  if (d === null) return NO_DECISION;
  if (d.kind === "hunt") return `hunt #${String(d.targetNodeId)}@${String(d.cell)}`;
  return `roam ${String(d.cell)}`;
}

/**
 * 面板的行（顺序固定：**身份 → 它用的树 → 它的判断 → 它的依据**）。
 *
 * ★ 顺序不是随手排的：人看面板的第一问是「这是哪只」，第二问是「它为什么这样」。
 *   把 `board` 那十几个键放前面的话，前两问都要在数字里找。
 */
export function inspectRows(e: MobExplain): readonly InspectRow[] {
  const f = e.facts;
  return [
    { label: "tick", value: String(e.tick) },
    { label: "node", value: `#${String(e.nodeId)}` },
    { label: "cell", value: f.selfCell < 0 ? NO_CELL : String(f.selfCell) },
    { label: "tree", value: treeValue(e) },
    { label: "why", value: e.decision === null ? NO_DECISION : e.decision.reason },
    { label: "goal", value: goalValue(e) },
    { label: "sees", value: String(f.visible.length) },
    { label: "aggro", value: f.aggressive ? "yes" : "no" },
  ];
}

/** 单行文本（日志 / 断言用）：`tick=42 | node=#7 | ...`。 */
export function inspectText(e: MobExplain): string {
  return inspectRows(e)
    .map((r) => `${r.label}=${r.value}`)
    .join(" | ");
}

/**
 * 非 ASCII 字符的位置（空数组 = 全部可渲染）。
 *
 * 与 `hud-model.ts` 的闸门分开写一个：那边的检查针对 `TextRun`，这里的输入是字符串；
 * 共用一份实现要先把字符串包成 run，多出来的转换只会让两边都变难读。
 */
export function nonAscii(text: string): readonly string[] {
  const out: string[] = [];
  for (const ch of text) {
    const cp = ch.codePointAt(0) ?? 0;
    if (cp > 0x7e || cp < 0x20) out.push(ch);
  }
  return out;
}
