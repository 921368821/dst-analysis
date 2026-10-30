/**
 * L6 · 真机清单的「等级」必须数得出来
 *
 * ★ 为什么要给**文档**写判据：批141 的 `WX-VERIFY-WITHOUT-DEVICE.md` 逐行标了 22 条的等级，
 *   文末合计写「A/A- 14 · B 5 · C 3 = 22」，而逐行数出来是 **16 · 3 · 3 = 22** ——
 *   总数对了、分裂错了，所以任何"总数自洽"的检查都抓不到它。这正是 A1 那一格的旧病：
 *   条数没人真数过，就会一直错下去（那一格曾把 12 条写成 10 条、把 14 写成 10）。
 *
 * 三件判据：
 *  ① 两份文档的同一编号必须同一等级（一处改了另一处必须跟着改）；
 *  ② 文末合计必须等于**逐行数出**的数（分等级数，不是只数总数）；
 *  ③ 反向自检：合成的错行/错合计必须被抓到 —— 否则这两条只是"读了一遍文件"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (rel: string): string => readFileSync(join(ROOT, rel), "utf8");

const CHECKLIST = "docs/WX-DEVICE-CHECKLIST.md";
const VERIFY = "docs/WX-VERIFY-WITHOUT-DEVICE.md";

/** 等级单元格：整格恰好是 `**A**` / `**A-**` / `**B**` / `**C**`。 */
const GRADE_CELL = /^\*\*(A-|A|B|C)\*\*$/;

/**
 * 「编号 → 等级」。
 *
 * ★ 不按列号取：两份文档的列序不同（清单有「期望」「谁能判」，验证文档只有「依据」），
 *   按列号写会让其中一份永远扫 0 行，而"0 行"与"全对"在输出上一模一样（本仓库的旧病）。
 *   改成「找那个恰好是等级的单元格」—— 两份文档同一套规则。
 */
function parseGrades(text: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t.startsWith("|")) continue;
    const cells = t.split("|").map((c) => c.trim());
    const id = cells.find((c) => /^\d\.\d$/.test(c));
    if (id === undefined) continue;
    const grade = cells.find((c) => GRADE_CELL.test(c));
    if (grade === undefined) continue;
    const g = GRADE_CELL.exec(grade)?.[1];
    if (g === undefined) continue;
    out.set(id, g);
  }
  return out;
}

/** A/A-/B/C 三档计数（A 与 A- 同归「已断言」）。 */
function tally(m: Map<string, string>): { a: number; b: number; c: number; total: number } {
  let a = 0;
  let b = 0;
  let c = 0;
  for (const g of m.values()) {
    if (g === "A" || g === "A-") a++;
    else if (g === "B") b++;
    else c++;
  }
  return { a, b, c, total: m.size };
}

interface Stated {
  readonly a: number;
  readonly b: number;
  readonly c: number;
  readonly total: number;
}

/** 清单文末的 `**16 · 3 · 3 = 22**`。 */
function statedInChecklist(text: string): Stated | null {
  const m = /\*\*(\d+) · (\d+) · (\d+) = (\d+)\*\*/.exec(text);
  if (m === null) return null;
  return { a: Number(m[1]), b: Number(m[2]), c: Number(m[3]), total: Number(m[4]) };
}

/** 验证文档的 `合计：A/A- 16 · B 3 · C 3 = 22`。 */
function statedInVerify(text: string): Stated | null {
  const m = /合计：A\/A- (\d+) · B (\d+) · C (\d+) = (\d+)/.exec(text);
  if (m === null) return null;
  return { a: Number(m[1]), b: Number(m[2]), c: Number(m[3]), total: Number(m[4]) };
}

/** 合计与逐行计数不符时的差异描述（空数组 = 一致）。 */
function totalProblems(rows: Map<string, string>, stated: Stated | null): string[] {
  if (stated === null) return ["没找到合计行（写死期望值的地方都没有，等于没对账）"];
  const t = tally(rows);
  const bad: string[] = [];
  if (t.a !== stated.a) bad.push(`A/A-：行 ${String(t.a)} ≠ 合计 ${String(stated.a)}`);
  if (t.b !== stated.b) bad.push(`B：行 ${String(t.b)} ≠ 合计 ${String(stated.b)}`);
  if (t.c !== stated.c) bad.push(`C：行 ${String(t.c)} ≠ 合计 ${String(stated.c)}`);
  if (t.total !== stated.total) bad.push(`总数：行 ${String(t.total)} ≠ 合计 ${String(stated.total)}`);
  return bad;
}

/** 两份文档逐编号比较（空数组 = 一致）。 */
function gradeProblems(left: Map<string, string>, right: Map<string, string>): string[] {
  const bad: string[] = [];
  for (const [id, g] of left) {
    const o = right.get(id);
    if (o === undefined) bad.push(`${id}：左边有、右边没有`);
    else if (o !== g) bad.push(`${id}：左边 ${g} ≠ 右边 ${o}`);
  }
  for (const id of right.keys()) if (!left.has(id)) bad.push(`${id}：右边有、左边没有`);
  return bad;
}

// ---------------------------------------------------------------- 反向自检（先证明工具有牙）

const SAMPLE = [
  "| # | 条目 | 等级 | 依据 |",
  "|---|---|---|---|",
  "| 1.1 | 甲 | **A** | x |",
  "| 1.2 | 乙 | **B** | x |",
  "| 1.3 | 丙 | **C** | x |",
].join("\n");

test("★ 解析器本身：三行三种等级都读得出来（扫不到 ≠ 全对）", () => {
  const m = parseGrades(SAMPLE);
  assert.equal(m.size, 3);
  assert.equal(m.get("1.1"), "A");
  assert.equal(m.get("1.2"), "B");
  assert.equal(m.get("1.3"), "C");
});

test("★ 反向自检：合计写错必须报出来（合成 2A/1B 却写 3·0·0）", () => {
  const rows = parseGrades(
    ["| 1.1 | 甲 | **A** |", "| 1.2 | 乙 | **A** |", "| 1.3 | 丙 | **B** |"].join("\n"),
  );
  const bad = totalProblems(rows, { a: 3, b: 0, c: 0, total: 3 });
  assert.equal(bad.length >= 2, true, `应当同时报 A 与 B 两处：${bad.join("；")}`);
  // 同一份行，合计写对时必须一条都不报 —— 否则"永远在报"与"真有问题"分不开
  assert.deepEqual(totalProblems(rows, { a: 2, b: 1, c: 0, total: 3 }), []);
});

test("★ 反向自检：同编号不同级必须报出来（合成 1.2 = B vs 1.2 = A）", () => {
  const left = parseGrades("| 1.2 | 甲 | **B** |");
  const right = parseGrades("| 1.2 | 甲 | **A** |");
  assert.equal(gradeProblems(left, right).length, 1);
  assert.deepEqual(gradeProblems(left, parseGrades("| 1.2 | 甲 | **B** |")), []);
  // 缺行也算差异（少一条比"改了一条"更隐蔽）
  assert.equal(gradeProblems(left, parseGrades("| 1.3 | 甲 | **B** |")).length, 2);
});

// ---------------------------------------------------------------- 真文档

test("★★ 两份真机文档：22 条同编号同级（一处改了另一处必须跟着改）", () => {
  const a = parseGrades(read(CHECKLIST));
  const b = parseGrades(read(VERIFY));
  assert.equal(a.size, 22, `清单应逐行标 22 条，实际 ${String(a.size)}`);
  assert.equal(b.size, 22, `验证文档应逐行标 22 条，实际 ${String(b.size)}`);
  assert.deepEqual(gradeProblems(a, b), [], "等级表两处不一致");
});

test("★★ 两份真机文档：合计等于**逐行数出**的数（不是只数总数）", () => {
  // ★ 这一条就是本批要抓的缺陷：批141 合计写 14/5/3，逐行是 16/3/3，总数都是 22。
  const listText = read(CHECKLIST);
  const verifyText = read(VERIFY);
  assert.deepEqual(totalProblems(parseGrades(listText), statedInChecklist(listText)), []);
  assert.deepEqual(totalProblems(parseGrades(verifyText), statedInVerify(verifyText)), []);
  // 前提：两份都真的找到了合计行（否则上面两条是"两个 null 相等"式的假绿）
  assert.notEqual(statedInChecklist(listText), null);
  assert.notEqual(statedInVerify(verifyText), null);
});
