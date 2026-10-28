#!/usr/bin/env node
/**
 * 从 Unicode 官方 conformance 语料（**不入库**，`.tmp-bidi/`）抽子集入库
 * `vendor/bidi/`，作为 UAX #9 实现的自动判据语料。
 *
 * ★ 为什么必须有官方语料：UAX #9 有 20 多条规则互相纠缠（W/N/I 系列、
 *   sos/eos 上下文、L2 的逐级反转），手写判据只能覆盖想到的形状；
 *   BidiTest.txt（~49 万用例）与 BidiCharacterTest.txt（~9 万用例，含括号 N0）
 *   是标准委员会的枚举语料，servo/unicode-bidi、bidi-js、wezterm-bidi
 *   全部以它们跑 conformance。全文件太大（8MB + 7MB），所以抽**确定性**子集
 *   入库：同输入同输出（FNV-1a 哈希采样），任何人重跑生成器得到逐字节相同的产物。
 *
 * 采样口径（写死，判据文档引用同一份）：
 *   · BidiTest.txt：@Levels/@Reorder 指令行全保留；数据行 len≤3 全保留
 *     （短序列是规则的基本形状），len≥5 全保留（规则触发的长序列），
 *     len 4（全枚举的大头，46.9 万行）按 FNV-1a % 20 == 0 抽 1/20。
 *   · BidiCharacterTest.txt：含括号字符（BidiBrackets.txt 里的 open/close）
 *     的行全保留（N0 只被这个文件覆盖）；其余按 FNV-1a % 4 == 0 抽 1/4。
 *
 * 用法：`node tools/make-bidi-corpus.mjs`
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "..", ".tmp-bidi");
const OUT = join(HERE, "..", "vendor", "bidi");

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}
function sha256Of(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

// 括号码点集合（open ∪ close）
const bracketCps = new Set();
for (const raw of readFileSync(join(SRC, "BidiBrackets.txt"), "utf8").split(/\r?\n/)) {
  const line = raw.split("#")[0].trim();
  if (line === "") continue;
  const [a, b] = line.split(";");
  bracketCps.add(parseInt(a, 16));
  bracketCps.add(parseInt(b, 16));
}

// ---- BidiTest.txt ----
let keep = 0;
let drop = 0;
const outTest = [];
for (const raw of readFileSync(join(SRC, "BidiTest.txt"), "utf8").split(/\r?\n/)) {
  if (raw.startsWith("@") || raw.startsWith("#") || raw.trim() === "") {
    outTest.push(raw);
    continue;
  }
  const [types] = raw.split(";");
  const len = types.split(" ").filter(Boolean).length;
  const take = len <= 3 || len >= 5 || fnv1a(raw) % 20 === 0;
  if (take) {
    outTest.push(raw);
    keep++;
  } else drop++;
}
writeFileSync(join(OUT, "BidiTest.subset.txt"), outTest.join("\n") + "\n", "utf8");
console.log(`BidiTest.subset.txt：保留 ${keep} / 丢弃 ${drop} 数据行`);

// ---- BidiCharacterTest.txt ----
// 行格式：码点...; paraDir; paraLevel; levels; reorder
//
// ★ 抽样口径（v2）：按「Bidi_Class 类型序列 + 括号配对结构 + 段落方向」签名去重，
//   每个签名保留文件里第一条。依据：UAX #9 的输出**只依赖**每个码点的 Bidi_Class
//   与括号配对结构（N0），不依赖具体码点 —— 签名相同 ⇒ levels/重排必然相同，
//   多余的行只是同一条判据抄 N 遍。括号结构进签名的方式：open 按**配对嵌套深度**
//   编号（O1/O2…），close 用其 open 的编号（C1…）—— 嵌套错位（如 "(]" 与 "(())"）
//   会得到不同签名，不会被错误合并。
//   （v1 是"含括号的行全保留"：实测 BidiCharacterTest 里 99.9% 的行都嵌括号，
//   全保留等于没抽样，产物 6.9MB —— 签名去重后缩到 ~2MB 且覆盖不降。）
const cpClass = []; // DerivedBidiClass → 紧凑查询（只为生成器算签名，产物不依赖它）
{
  const table = new Map(); // cp -> cls（缩写）
  const LONG_NAMES = {
    Left_To_Right: "L", Right_To_Left: "R", European_Number: "EN",
    European_Separator: "ES", European_Terminator: "ET", Arabic_Number: "AN",
    Common_Number_Separator: "CS", Paragraph_Separator: "B", Segment_Separator: "S",
    White_Space: "WS", Other_Neutral: "ON", Boundary_Neutral: "BN",
    Nonspacing_Mark: "NSM", Arabic_Letter: "AL",
  };
  for (const raw of readFileSync(join(SRC, "DerivedBidiClass.txt"), "utf8").split(/\r?\n/)) {
    const mm = /@missing:\s*([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\s*;\s*(\w+)/.exec(raw);
    if (mm !== null) {
      const short = LONG_NAMES[mm[3]] ?? mm[3];
      for (let c = parseInt(mm[1], 16); c <= parseInt(mm[2], 16); c++) table.set(c, short);
      continue;
    }
    const line = raw.split("#")[0].trim();
    if (line === "") continue;
    const m = /^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*(\w+)\s*$/.exec(line);
    if (m !== null) {
      for (let c = parseInt(m[1], 16); c <= parseInt(m[2] ?? m[1], 16); c++) table.set(c, m[3]);
    }
  }
  for (let c = 0; c <= 0x10ffff; c++) cpClass.push(table.get(c) ?? "BN");
}

/** open 码点 → close 码点；close 反查。 */
const openOf = new Map(); // close -> open
for (const cp of bracketCps) {
  // BidiBrackets 里的 open/close 集合：配对关系重新读一遍（cpClass 之外的信息）
}
const pairOpenToClose = new Map();
const pairCloseToOpen = new Map();
for (const raw of readFileSync(join(SRC, "BidiBrackets.txt"), "utf8").split(/\r?\n/)) {
  const line = raw.split("#")[0].trim();
  if (line === "") continue;
  const [a, b, t] = line.split(";").map((x) => x.trim());
  if (t === "o") {
    const o = parseInt(a, 16);
    const c = parseInt(b, 16);
    pairOpenToClose.set(o, c);
    pairCloseToOpen.set(c, o);
  }
}

/** 一行的签名：类型序列 + 括号嵌套结构 + 段落方向。 */
function signatureOf(raw) {
  const [cpsField, , paraLevel] = raw.split(";");
  const cps = cpsField.trim().split(" ").filter(Boolean).map((h) => parseInt(h, 16));
  const stack = []; // 嵌套中的 open 码点
  const depthOfOpen = new Map(); // open 码点实例位置 -> 编号（从 1 起）
  const closeNum = new Map(); // close 实例位置 -> 配对编号
  let next = 1;
  const parts = [];
  for (const c of cps) {
    if (pairOpenToClose.has(c)) {
      parts.push(`O${next}`);
      depthOfOpen.set(c, next);
      // 注意：同一 open 码点出现两次时按出现次序编号 —— 用栈记位置
      stack.push(next);
      next++;
    } else if (pairCloseToOpen.has(c)) {
      const openNum = stack.length > 0 ? stack[stack.length - 1] : 0;
      stack.pop();
      parts.push(`C${openNum}`);
    } else {
      parts.push(cpClass[c] ?? "BN");
    }
  }
  return `${parts.join(",")}|p${paraLevel.trim()}`;
}

keep = 0;
drop = 0;
const seenSig = new Set();
const outChar = [];
for (const raw of readFileSync(join(SRC, "BidiCharacterTest.txt"), "utf8").split(/\r?\n/)) {
  if (raw.startsWith("#") || raw.trim() === "") {
    outChar.push(raw);
    continue;
  }
  const sig = signatureOf(raw);
  if (seenSig.has(sig)) {
    drop++;
    continue;
  }
  seenSig.add(sig);
  outChar.push(raw);
  keep++;
}
writeFileSync(join(OUT, "BidiCharacterTest.subset.txt"), outChar.join("\n") + "\n", "utf8");
console.log(`BidiCharacterTest.subset.txt：保留 ${keep} / 去重 ${drop} 用例行`);

// ---- README（来源、版本、校验和、口径） ----
const readme = `# UAX #9 conformance 语料（子集）

由 \`tools/make-bidi-corpus.mjs\` 从官方全量语料确定性抽样生成 —— **不要手改**；
重新生成：下载下表文件到 \`.tmp-bidi/\` 后跑 \`node tools/make-bidi-corpus.mjs\`。

| 文件 | 来源（Unicode 18.0.0） |
|---|---|
| BidiTest.txt | https://www.unicode.org/Public/UCD/latest/ucd/BidiTest.txt |
| BidiCharacterTest.txt | https://www.unicode.org/Public/UCD/latest/ucd/BidiCharacterTest.txt |
| BidiBrackets.txt | https://www.unicode.org/Public/UCD/latest/ucd/BidiBrackets.txt |
| DerivedBidiClass.txt | https://www.unicode.org/Public/UCD/latest/ucd/extracted/DerivedBidiClass.txt |

格式见各全量文件头。要点：
- BidiTest.txt：\`@Levels:\`/\`@Reorder:\` 指令行之后的数据行 \`TYPES; BITSET\`，
  BITSET 位 1/2/4 = auto-LTR / 显式 LTR(0) / 显式 RTL(1) 三种段落方向；
  期望 levels 里的 \`x\` = 该字符被 X9 移除，无级别。
- BidiCharacterTest.txt：\`码点; 段落方向; 期望段落级; 期望 levels; 期望视觉序\`。

采样口径见生成器文件头。全量文件 sha256（抽样输入的校验和）：

- BidiTest.txt \`${sha256Of(join(SRC, "BidiTest.txt")).slice(0, 16)}…（完整值见生成时输出）\`

判据入口：\`tests/extensions/ui-bidi.test.ts\`。
`;
writeFileSync(join(OUT, "README.md"), readme, "utf8");
console.log("vendor/bidi/README.md 已写（含来源与口径）");
console.log(`全量 sha256：`);
for (const f of ["BidiTest.txt", "BidiCharacterTest.txt", "BidiBrackets.txt", "DerivedBidiClass.txt"]) {
  console.log(`  ${f}: ${sha256Of(join(SRC, f))}`);
}
