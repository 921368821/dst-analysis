#!/usr/bin/env node
/**
 * JPEG 解码器的"未覆盖行必须与白名单一致"闸门。
 *
 * ★ 为什么不是"行覆盖率 ≥ 98%"：
 *   百分比是个能被平凡代码堆出来的数。真正要守的性质是
 *   **"还有哪些行没被执行过"这份清单不能变多，也不能凭空变少**：
 *     - 变多 ⇒ 新代码没有任何判据走过它（哪怕它在正常输入下永远走到也不算，因为
 *       "正常输入下能走到"这句话本身就是靠判据证明的）；
 *     - 变少 ⇒ 白名单过期了。要么是有人补了判据（好事，把该行从清单里删掉），
 *       要么是行号漂移（危险：白名单会掩盖真正的未覆盖行）。
 *
 * ★ 用法：
 *   node tools/coverage-gate.mjs            # 校验
 *   node tools/coverage-gate.mjs --verbose  # 连一致的也打印
 *
 * 需要 node ≥ 22.6（`--experimental-test-coverage`）。退出码非 0 表示闸门不通过。
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const verbose = process.argv.includes("--verbose");

/**
 * 每份文件的"已知未覆盖行"及其原因。改这份表必须同时改 ADR-0009 ⑥-d。
 *
 * ★ 为什么用"代码签名"锚定，而不是直接写行号：
 *   第一版写的是行号集合（`"178-180"`）。它确实抓到过一次"新增未覆盖行"，
 *   但代价是**在同一个文件里加几行注释就整张表失效** —— 报出来的既有
 *   "白名单过期"，也有"新增未覆盖行"，而两者其实是同一批代码整体下移了 19 行。
 *   这种"红得没依据"的闸门很快就会被当成噪音，然后被 --force 掉。
 *
 *   现在每个区间用**代码签名**锚定：`at` 是若干**连续行**的原文（比较时去首尾空白），
 *   从匹配到的第 `nth` 处起算，跳过 `skip` 行、覆盖 `len` 行。
 *   于是：加注释/挪位置 → 仍然绿（行号自动算）；
 *        被豁免的那几行**代码本身**改了 → 立刻红（签名找不到 = 白名单过期）。
 *   这才是这个闸门该守的性质：**豁免的是哪一段代码**，不是哪几个数字。
 */
const EXPECTED = {
  "decode/jpeg/bits.ts": {
    why: "DHT 查表越界：构造器不变量保证 at 必在界内（保留只为类型收窄）",
    anchors: [{ at: ['fail("ASSET.BAD_JPEG", `DHT 查表越界：len=${len} code=${code} at=${at}`);'], len: 2 }],
  },
  "decode/jpeg/qm.ts": {
    why: "算术熵数据里出现真标记：splitEntropy 已在切分时排除（该分支不可达）",
    anchors: [{ at: ["} else {", "this.stalled = true;", "return 0;", "}"], skip: 1, len: 3 }],
  },
  "decode/jpeg/scan-huffman.ts": {
    why: "交错扫描里的渐进 AC 首扫：AC 扫描被强制单分量，交错时不可能出现",
    anchors: [
      {
        at: [
          "if (progressive) {",
          "if (ss === 0) decodeProgressiveDc(c, bo);",
          "else if (ah === 0) decodeProgressiveAcFirst(c, bo);",
        ],
        skip: 2,
        len: 1,
        nth: 0, // 这段代码在文件里出现两次（交错/非交错），只豁免第一处
      },
    ],
  },
  "decode/jpeg/scan-arith.ts": {
    why: "统计区缺失：beginInterval 已按扫描参数建好，属内部一致性兜底",
    anchors: [
      { at: ['fail("ASSET.BAD_JPEG", `分量 ${c.id} 需要算术 DC 表 ${c.td}，但统计区没有建立（扫描参数自相矛盾）`);', "}"], len: 2 },
      { at: ['fail("ASSET.BAD_JPEG", `分量 ${c.id} 需要算术 AC 表 ${c.ta}，但统计区没有建立（扫描参数自相矛盾）`);', "}"], len: 2 },
    ],
  },
  "decode/jpeg/hierarchy.ts": {
    why: "两条「内部错误」兜底（配对被 checkPairing 蕴含；平面顺序由调用序保证）",
    anchors: [
      { at: ['fail("ASSET.BAD_JPEG", `分层 JPEG 的差分帧找不到分量 ${c.id} 的参考分量`);', "}"], len: 2 },
      { at: ['fail("ASSET.BAD_JPEG", `分量 ${c.id} 的平面还没解出来（内部错误：分层合成的顺序错了）`);', "}"], len: 2 },
    ],
  },
  "decode/jpeg/reconstruct.ts": {
    why: "采样比例名兜底（4:1:1/4:1:0/4:4:0 之外的比例 Pillow 不产）+ 平面未解码兜底",
    anchors: [
      { at: ["return `${maxH}x${maxV}`;"], len: 3 },
      { at: ['fail("ASSET.BAD_JPEG", `分量 ${c.id} 的平面还没有解码出来（内部错误：重建顺序错了）`);', "}"], len: 2 },
    ],
  },
  "decode/jpeg/index.ts": {
    why: "兜底 catch：fuzz 用例断言永远走不到（走不到才是对的）",
    anchors: [
      {
        at: [
          "return err(",
          'engineError("ASSET.BAD_JPEG", `JPEG 解码内部错误：${e instanceof Error ? e.message : String(e)}`),',
        ],
        len: 1,
      },
    ],
  },
};

/** 把签名解析成行号区间（"197-199"）。签名找不到/不唯一 → 抛错，由调用方记成 problem。 */
function resolveRanges(rel, spec) {
  const file = join(ROOT, "src/extensions/asset-import", rel);
  const lines = readFileSync(file, "utf8").split(/\r?\n/).map((s) => s.trim());
  const ranges = [];
  for (const a of spec.anchors) {
    const need = a.at.map((s) => s.trim());
    const hits = [];
    for (let i = 0; i + need.length <= lines.length; i++) {
      let ok = true;
      for (let k = 0; k < need.length; k++) {
        if (lines[i + k] !== need[k]) {
          ok = false;
          break;
        }
      }
      if (ok) hits.push(i + 1); // 1-based
    }
    const nth = a.nth ?? 0;
    if (hits.length <= nth) {
      throw new Error(
        `签名找不到（期望第 ${nth + 1} 处）：${need[0]} —— 被豁免的代码改过了，请重看这段为什么够不到`,
      );
    }
    if (hits.length > 1 && a.nth === undefined) {
      throw new Error(`签名不唯一（${hits.length} 处）：${need[0]} —— 请给 at 补更多上下文或指定 nth`);
    }
    const start = hits[nth] + (a.skip ?? 0);
    const len = a.len ?? need.length;
    ranges.push(len === 1 ? `${start}` : `${start}-${start + len - 1}`);
  }
  return ranges;
}

const TESTS = ["tests/extensions/jpeg-modes.test.ts", "tests/extensions/jpeg.test.ts"];

// ★ reporter 显式写死 TAP：这条闸门在输出里找 `#` 前缀的覆盖率表，
//   报错行也要归到"哪条判据红了"。默认 reporter 在 Node 22 是 TAP、Node 24 是 spec，
//   靠默认值会让同一条命令在两个解释器下给出不同的可解析性。
const run = spawnSync(
  process.execPath,
  ["--experimental-transform-types", "--test-reporter=tap", "--experimental-test-coverage", "--test", ...TESTS],
  { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);
if (run.error) {
  console.error(`跑覆盖率失败：${run.error.message}`);
  process.exit(2);
}
const out = `${run.stdout ?? ""}${run.stderr ?? ""}`;

// ---------------------------------------------------------------- 解析表格
/** 从报告里取出 { "decode/jpeg/bits.ts": ["117-118"] } */
function parseCoverage(text) {
  const start = text.indexOf("start of coverage report");
  const end = text.indexOf("end of coverage report");
  if (start < 0) throw new Error("覆盖率报告里没有 start of coverage report —— node 版本太旧？");
  const body = text.slice(start, end < 0 ? undefined : end);

  const rows = new Map();
  const stack = [];
  for (const raw of body.split(/\r?\n/)) {
    if (!raw.startsWith("#")) continue;
    const m = /^#(\s+)(\S+)(.*)$/.exec(raw);
    if (m === null) continue;
    const indent = m[1].length;
    const name = m[2];
    const rest = m[3];
    const cols = rest.split("|");
    const uncovered = cols.length >= 4 ? cols[cols.length - 1].trim() : "";

    while (stack.length > 0 && stack[stack.length - 1].indent >= indent) stack.pop();
    stack.push({ indent, name });

    if (cols.length < 4) continue; // 目录行（没有指标）
    const dirs = stack.slice(0, -1).map((s) => s.name);
    // 去掉最外层的 src 前缀，后续按 "decode/jpeg/xxx.ts" 对表
    const path = [...dirs.filter((d) => d !== "src"), name].join("/");
    rows.set(path, uncovered === "" ? [] : uncovered.split(/\s+/));
  }
  return rows;
}

let actual;
try {
  actual = parseCoverage(out);
} catch (e) {
  console.error(`解析失败：${e.message}`);
  process.exit(2);
}

// ---------------------------------------------------------------- 比对
const problems = [];
const notes = [];
let checked = 0;

for (const [rel, want] of Object.entries(EXPECTED)) {
  const key = [...actual.keys()].find((k) => k.endsWith(rel));
  if (key === undefined) {
    problems.push(`${rel}：报告里找不到这个文件（改名了？白名单要跟着改）`);
    continue;
  }
  checked++;
  let exp;
  try {
    exp = resolveRanges(rel, want);
  } catch (e) {
    problems.push(`${rel}：${e.message}`);
    continue;
  }
  const got = [...actual.get(key)].sort();
  const sortedExp = [...exp].sort();
  const added = got.filter((x) => !sortedExp.includes(x));
  const gone = sortedExp.filter((x) => !got.includes(x));
  if (added.length > 0) {
    problems.push(
      `${rel}：新增未覆盖行 ${added.join(" ")} —— 要么补一条判据走它，` +
        `要么在 EXPECTED 里写明为什么够不到（当前原因：${want.why}）`,
    );
  }
  if (gone.length > 0) {
    notes.push(`${rel}：白名单里的 ${gone.join(" ")} 已被覆盖 —— 请从 EXPECTED 里删掉（白名单过期会掩盖行号漂移）`);
  }
  if (verbose && added.length === 0 && gone.length === 0) {
    console.log(`  ${rel.padEnd(34)} ok（未覆盖 ${exp.join(" ") || "无"}）`);
  }
}

// 反向：白名单里没有的文件若出现未覆盖行，也要报（防止新模块悄悄没判据）
for (const [key, un] of actual) {
  if (!key.includes("decode/jpeg/")) continue;
  if (Object.keys(EXPECTED).some((rel) => key.endsWith(rel))) continue;
  if (un.length > 0) {
    problems.push(`${key}：不在白名单里却有未覆盖行 ${un.join(" ")} —— 新增模块要么补判据，要么登记原因`);
  }
}

console.log(`\n覆盖率闸门：检查 ${checked} 个模块，问题 ${problems.length} 条，提示 ${notes.length} 条`);
for (const n of notes) console.log(`  ⚠ ${n}`);
for (const p of problems) console.log(`  ✘ ${p}`);
if (problems.length === 0) console.log("  ✔ 未覆盖行与白名单一致");
process.exit(problems.length === 0 ? 0 : 1);
