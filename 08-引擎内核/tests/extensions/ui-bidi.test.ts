/**
 * L4 · UAX #9 双向算法判据
 *
 * 判据分三层（与 bidi.ts 的三层 API 对应）：
 *   ① 手算锚点：TR9 的经典例子，每一步都能在纸上核；
 *   ② **Unicode 官方 conformance 语料**（vendor/bidi/ 里的确定性子集）——
 *      这是本批最硬的判据：servo/unicode-bidi、bidi-js、wezterm-bidi 都用
 *      同一份官方语料验收（BidiTest.txt ≈49 万用例 + BidiCharacterTest.txt
 *      ≈9 万用例），抽样口径见 tools/make-bidi-corpus.mjs 文件头；
 *   ③ 与排版层的接缝在 ui-text.test.ts（RTL 行的 quads 顺序）。
 *
 * 官方语料的意义：UAX #9 的规则互相纠缠（W 系列改写类型、N 系列看上下文、
 * I 系列看 parity、L2 还要"包含不存在的中间级别"），手写判据只能覆盖想到的
 * 形状 —— "数字在 RTL 里保持 LTR"这类用例想得到，"sos 在 isolate 边界的
 * level 较高侧"这类就想不全了。语料是标准委员会枚举的，不靠想象。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BC,
  applyL1,
  bidiClassOf,
  bracketPairOf,
  embeddingLevels,
  levelsFromTypes,
  mirroredOf,
  paragraphLevelFromTypes,
  reorderLine,
  type ParaDir,
} from "../../src/extensions/ui/bidi.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, "..", "..", "vendor", "bidi");

// =====================================================================
// ① 手算锚点（TR9 §3.3.1 的标准例子）
// =====================================================================

const HEBREW = "א".codePointAt(0)!; // U+05D0，R
const ARABIC = "ع".codePointAt(0)!; // U+0639，AL
const A = "A".codePointAt(0)!;
const ONE = "1".codePointAt(0)!;

test("手算锚点：纯 LTR 全 0 级、重排恒等", () => {
  const codes = [A, ONE, A];
  const { levels } = embeddingLevels(codes, "auto");
  assert.deepEqual([...levels], [0, 0, 0]);
  const map = reorderLine([BC.L, BC.EN, BC.L], [0, 0, 0], 0, 3, 0);
  assert.deepEqual([...map], [0, 1, 2]);
});

test("手算锚点：LTR 段里的希伯来文整体反转（TR9 例：car means אוטו）", () => {
  // "car אוטו" → L L L R R R R？אוטו 是 4 个 R。期望 levels：0 0 0 1 1 1 1
  const codes = [A, A, A, 0x05d0, 0x05d5, 0x05d8, 0x05d5];
  const { levels, paraLevel } = embeddingLevels(codes, "auto");
  assert.equal(paraLevel, 0);
  assert.deepEqual([...levels], [0, 0, 0, 1, 1, 1, 1]);
  // 视觉序：car 是 level 0（不反转），希伯来文反转 → [0,1,2,6,5,4,3]
  const types = codes.map((c) => bidiClassOf(c));
  const map = reorderLine(types, levels, 0, 7, 0);
  assert.deepEqual([...map], [0, 1, 2, 6, 5, 4, 3]);
});

test("手算锚点：RTL 段里的数字保持 LTR（levels 奇级不变）", () => {
  // "عربي 123" → AL AL AL WS EN EN EN；段落级 1
  // AL→R（W3）；EN 在奇级 +1（I2）→ level 2 的 LTR 岛
  const codes = [ARABIC, 0x0631, 0x0628, 0x064a, 0x20, ONE, ONE, ONE];
  const { levels, paraLevel } = embeddingLevels(codes, "auto");
  assert.equal(paraLevel, 1, "首强类型是 AL");
  assert.deepEqual([...levels], [1, 1, 1, 1, 1, 2, 2, 2]);
  // L2 两轮反转：lvl2 反转数字、lvl1 反转全部 ⇒ 数字恢复正序、整段 RTL
  // 视觉序：数字在左保持 LTR，阿拉伯词反转在右 → [5,6,7,4,3,2,1,0]
  const types = codes.map((c) => bidiClassOf(c));
  const map = reorderLine(types, levels, 0, 8, 1);
  assert.deepEqual([...map], [5, 6, 7, 4, 3, 2, 1, 0]);
});

test("手算锚点：X9 移除的控制在重排里没有视觉位置（-1 槽）", () => {
  const codes = [A, 0x202b /* RLE */, HEBREW];
  const { levels } = embeddingLevels(codes, "ltr");
  assert.equal(levels[0], 0);
  assert.equal(levels[2], 1);
  const types = codes.map((c) => bidiClassOf(c));
  const map = reorderLine(types, levels, 0, 3, 0);
  assert.equal(map[1], -1, "RLE 被 X9 移除");
  // level 1 的只有 א 一个字符：单字符 run 反转后不变，A（level 0）仍在左
  assert.deepEqual([...map].filter((v) => v >= 0), [0, 2]);
});

test("手算锚点：镜像表（M1）—— 括号与数学符号", () => {
  assert.equal(mirroredOf(0x28 /* ( */), 0x29);
  assert.equal(mirroredOf(0x29 /* ) */), 0x28);
  assert.equal(mirroredOf(0x3c /* < */), 0x3e);
  assert.equal(mirroredOf(A), undefined);
});

test("手算锚点：N0 括号对 —— 希伯来文里的括号跟文字走", () => {
  // 配对表本身来自 BidiBrackets.txt（65 对 o 行），先钉一条
  assert.equal(bracketPairOf(0x28 /* ( */), 0x29, "BidiBrackets 表：'(' ↔ ')'");
  // "א(ב)ג"：R ON R ON R。括号包围的是 R，嵌入方向 L 相反，
  // open 之前无强类型 → sos = L ≠ R ⇒ 括号取前文强类型方向 R（N0c）
  const codes = [HEBREW, 0x28, HEBREW, 0x29, HEBREW];
  const { types } = embeddingLevels(codes, "ltr");
  assert.equal(types[1], BC.R, "open 括号解析为 R");
  assert.equal(types[3], BC.R, "close 括号解析为 R");
});

test("手算锚点：isolate —— LRI 里的希伯来文不外溢到外侧中性字符", () => {
  // ① 级别布局（X5a / X6a）：initiator 自身拿**外层**级；内容 = 外层 +2（even）；
  //    PDI 拿**匹配 initiator 的级**（TR9 注："the initiator and its matching
  //    PDI always have the same level"）。希伯来文 R 在 even 2 → I1 抬到 3。
  const base = embeddingLevels([A, 0x2066 /* LRI */, HEBREW, 0x2069 /* PDI */, A], "ltr");
  assert.deepEqual([...base.levels], [0, 0, 3, 0, 0]);

  // ② 隔离的实际效果：同一个 '!'（ON）在**没有** isolate 时被两侧的希伯来文
  //    带成 R（1 级）；有 isolate 时内层 א 被围起来，外侧只剩 L 上下文 → 0 级。
  //    这条是「隔离」二字唯一能观察到的语义，光看级别布局证不出来。
  const BANG = 0x21;
  const plain = embeddingLevels([A, HEBREW, BANG, HEBREW, A], "ltr");
  assert.deepEqual([...plain.levels], [0, 1, 1, 1, 0], "无隔离：'!' 随两侧 R");
  const iso = embeddingLevels([A, 0x2066, HEBREW, 0x2069, BANG, HEBREW, A], "ltr");
  assert.deepEqual([...iso.levels], [0, 0, 3, 0, 0, 1, 0], "有隔离：'!' 只看外侧 L");
});

// =====================================================================
// ② conformance：BidiTest.subset.txt（类型序列）
// =====================================================================

const TYPE_NAME_TO_ID = new Map(
  (Object.entries(BC) as Array<[string, number]>).map(([k, v]) => [k, v]),
);

/** 位集展开：bit1=auto-LTR、bit2=显式 LTR(0)、bit4=显式 RTL(1)。 */
function paraLevelsForBitset(bit: number): Array<"auto" | 0 | 1> {
  const out: Array<"auto" | 0 | 1> = [];
  if (bit & 1) out.push("auto");
  if (bit & 2) out.push(0);
  if (bit & 4) out.push(1);
  return out;
}

interface BidiTestCase {
  types: number[];
  base: "auto" | 0 | 1;
  wantLevels: Array<number | "x">;
  wantReorder: Array<number | "x">;
  line: number;
}

function loadBidiTest(): BidiTestCase[] {
  const raw = readFileSync(join(CORPUS, "BidiTest.subset.txt"), "utf8").split(/\r?\n/);
  const cases: BidiTestCase[] = [];
  let levels: Array<number | "x"> = [];
  let reorder: Array<number | "x"> = [];
  let lineNo = 0;
  for (const rawLine of raw) {
    lineNo++;
    if (rawLine.startsWith("@Levels:")) {
      levels = rawLine
        .slice(8)
        .trim()
        .split(/\s+/)
        .filter(Boolean)
        .map((x) => (x === "x" ? "x" : parseInt(x, 10)));
      continue;
    }
    if (rawLine.startsWith("@Reorder:")) {
      reorder = rawLine
        .slice(9)
        .trim()
        .split(/\s+/)
        .filter(Boolean)
        .map((x) => (x === "x" ? "x" : parseInt(x, 10)));
      continue;
    }
    if (rawLine.startsWith("#") || rawLine.startsWith("@") || rawLine.trim() === "") continue;
    const barIdx = rawLine.indexOf(";");
    if (barIdx < 0) continue;
    const typesField = rawLine.slice(0, barIdx);
    const bitField = rawLine.slice(barIdx + 1);
    const types = typesField
      .trim()
      .split(" ")
      .filter(Boolean)
      .map((name) => {
        const id = TYPE_NAME_TO_ID.get(name);
        if (id === undefined) throw new Error(`未知类型名 ${name}`);
        return id;
      });
    const bitset = parseInt(bitField.trim(), 16);
    for (const base of paraLevelsForBitset(bitset)) {
      cases.push({ types, base, wantLevels: levels, wantReorder: reorder, line: lineNo });
    }
  }
  return cases;
}

test("★★★ conformance：BidiTest 子集 —— levels 与视觉重排全部一致", () => {
  const cases = loadBidiTest();
  assert.ok(cases.length > 30000, `语料行数异常：${cases.length}`);
  const failures: string[] = [];
  for (const c of cases) {
    const paraLevel: 0 | 1 =
      c.base === "auto" ? paragraphLevelFromTypes(c.types, "auto") : c.base;
    const { levels: lvRaw, rawTypes } = levelsFromTypes(c.types, paraLevel);
    // 官方期望含 L1（BidiTest 单行 = 整段）：S/B/行尾 WS/BN 已重置为段落级
    // ★ L1 按**原始类**判定（rawTypes）—— N1 会把 S/WS 解析成 L/R
    const levels = Uint8Array.from(lvRaw);
    applyL1(rawTypes, levels, c.types.map((_, i) => i), paraLevel);
    // 期望里 x = X9 移除位：剔除后比对
    const got: string[] = [];
    const want: string[] = [];
    for (let i = 0; i < c.types.length; i++) {
      const w = c.wantLevels[i];
      if (w === "x") continue;
      want.push(String(w));
      got.push(String(levels[i]));
    }
    if (got.join(",") !== want.join(",")) {
      if (failures.length < 5) {
        failures.push(
          `L${c.line} base=${c.base} types=[${c.types.map((t) => BIDI_NAME(t)).join(" ")}]\n` +
            `  want [${want.join(" ")}] got [${got.join(" ")}]`,
        );
      }
      continue;
    }
    // reorder：用（可能被 L1 重置过的）levels —— 官方期望含 L1，reorderLine 同
    const map = reorderLine(c.types, levels, 0, c.types.length, paraLevel, rawTypes);
    const gotOrder = [...map].filter((v) => v >= 0).join(",");
    // ★ @Reorder 期望**本身就是**视觉→逻辑映射（如 "2 1 0 5 4 3"），
    //   不是"非 x 位置的下标"—— x 位（被 X9 移除的字符）在期望里占位，
    //   比对时压缩掉即可
    const wantSeq = c.wantReorder.filter((v) => v !== "x");
    if (gotOrder !== wantSeq.join(",")) {
      if (failures.length < 5) {
        failures.push(
          `L${c.line} reorder base=${c.base} types=[${c.types.map((t) => BIDI_NAME(t)).join(" ")}]\n` +
            `  want [${wantSeq.join(" ")}] got [${[...map].filter((v) => v >= 0).join(" ")}]`,
        );
      }
    }
  }
  assert.equal(failures.length, 0, `conformance 失败 ${failures.length} 例：\n${failures.join("\n")}`);
});

function BIDI_NAME(id: number): string {
  for (const [k, v] of TYPE_NAME_TO_ID) if (v === id) return k;
  return "?";
}

// =====================================================================
// ② conformance：BidiCharacterTest.subset.txt（真实码点，含 N0 括号）
// =====================================================================

test("★★★ conformance：BidiCharacterTest 子集 —— 真实码点 + 括号 + 三种段落方向", () => {
  const raw = readFileSync(join(CORPUS, "BidiCharacterTest.subset.txt"), "utf8").split(/\r?\n/);
  let count = 0;
  const failures: string[] = [];
  for (const line of raw) {
    if (line.startsWith("#") || line.trim() === "") continue;
    const fields = line.split(";");
    const cpsField = fields[0] ?? "";
    const dirField = fields[1] ?? "2";
    const wantParaField = fields[2] ?? "0";
    const wantLevelsField = fields[3] ?? "";
    const wantReorderField = fields[4] ?? "";
    const codes = cpsField
      .trim()
      .split(" ")
      .filter(Boolean)
      .map((h) => parseInt(h, 16));
    const dir = parseInt(dirField.trim(), 10) as 0 | 1 | 2;
    const base: ParaDir = dir === 0 ? "ltr" : dir === 1 ? "rtl" : "auto";
    const wantPara = parseInt(wantParaField.trim(), 10);
    const r = embeddingLevels(codes, base);
    const paraLevel = r.paraLevel;
    const types = r.types;
    const levels = Uint8Array.from(r.levels);
    applyL1(r.rawTypes, levels, codes.map((_, i) => i), paraLevel);
    count++;
    if (paraLevel !== wantPara && failures.length < 5) {
      failures.push(`段落级 want ${wantPara} got ${paraLevel}（dir=${dir}，codes=${cpsField.trim().slice(0, 40)}）`);
      continue;
    }
    // levels：期望 x = X9 移除位
    const wantLv = wantLevelsField.trim().split(/\s+/);
    for (let i = 0; i < codes.length; i++) {
      if (wantLv[i] === "x") continue;
      if (levels[i] !== parseInt(wantLv[i]!, 10)) {
        if (failures.length < 5) {
          failures.push(
            `levels[${i}] want ${wantLv[i]} got ${levels[i]}（dir=${base}，codes=${cpsField.trim().slice(0, 40)}…）`,
          );
        }
        break;
      }
    }
    // reorder：期望是视觉序的**原下标序列**（不含 x 位）
    const map = reorderLine(types, levels, 0, codes.length, paraLevel, r.rawTypes);
    const gotSeq = [...map].filter((v) => v >= 0).join(",");
    // ★ 同 BidiTest：期望字段本身就是视觉→逻辑映射，压缩 x 位
    const reorder = wantReorderField.trim().split(/\s+/);
    const wantSeq = reorder.map((v) => (v === "x" ? null : parseInt(v, 10))).filter((v) => v !== null);
    if (gotSeq !== wantSeq.join(",") && failures.length < 5) {
      failures.push(
        `reorder want [${wantSeq.join(" ")}] got [${[...map].filter((v) => v >= 0).join(" ")}]` +
          `（dir=${base}，codes=${cpsField.trim().slice(0, 40)}…）`,
      );
    }
  }
  assert.ok(count > 20000, `有效用例数异常：${count}`);
  assert.equal(failures.length, 0, `conformance 失败（共 ${count} 例）：\n${failures.join("\n")}`);
});
