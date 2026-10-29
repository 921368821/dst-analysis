/**
 * 缺口清单对账的判据
 *
 * 为什么值得单测：这条判据的输出永远是**空数组**（今天 §六 里没有过期行），
 * 一个"什么都不报"的函数与一个"根本没在扫"的函数，在 `docs-check` 的输出上
 * 完全一样。所以每一条规则都要用**合成语料**正向打一发：删掉被测规则，必须有一条红。
 *
 * ★ 语料里的每一行都是"某次真实出错的样子"，不是编出来凑数的：
 *   · 「只在正文里划掉旧条件」就是 C12 的形态（正文划掉了旧等待条件，缺口名还在，
 *     于是被抄进了阻塞清单）；
 *   · 「文件存在但没进 CI」是假红的来源（存在 ≠ 这件事做完了）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  findForgottenClosures,
  findStaleGapRows,
  findUnresolvedClaims,
  gapRowCount,
  gapSectionLines,
  GAP_HEADING,
} from "../../tools/gap-check.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** 造一篇最小文档：§六 里放给定的行（`after` 放在 §六 的 ### 小节之后，仍在 §六 内）。 */
function doc(gapLines: string[], opts: { before?: string[]; after?: string[] } = {}): string {
  return [
    "# 进度",
    "",
    ...(opts.before ?? []),
    GAP_HEADING,
    "",
    "| 缺口 | 现状 | 在等什么 |",
    "|---|---|---|",
    ...gapLines,
    "",
    "### 六·一 三级标题不该截断本节（只有二级标题才截）",
    "",
    ...(opts.after ?? []),
    "",
    "## 七、下一阶段",
    "",
    "| 说明 | 这张表在 §七 |",
    "|---|---|",
    "| 评分表里也点名了 `tools/ci.mjs` | 但它不在 §六 |",
    "",
  ].join("\n");
}

const HAS =
  (...paths: string[]) =>
  (rel: string): boolean =>
    paths.includes(rel);
const CI = (src: string): string => src;

test("缺口行点名了已在 CI 里跑的工具 ⇒ 报出来（并给原文行号）", () => {
  const text = doc(["| 某个缺口 | 现状 | `tools/cross-host-save.mjs` 早就在跑 |"]);
  const got = findStaleGapRows({
    docText: text,
    exists: HAS("tools/cross-host-save.mjs"),
    ciText: CI('node("跨宿主存档比对", "tools/cross-host-save.mjs")'),
  });
  assert.equal(got.length, 1);
  assert.deepEqual(got[0]?.hits, ["tools/cross-host-save.mjs"]);
  // 行号必须是**原文**里的行号：给人指路的东西指错了，比不指更坏
  const lineNo = text.split("\n").findIndex((l) => l.includes("某个缺口")) + 1;
  assert.equal(got[0]?.no, lineNo);
});

test("首格标了 ✅ / 划掉了 ⇒ 不报（已消除就是已消除）", () => {
  const text = doc([
    "| ~~旧缺口~~ | ✅ 已消除（批57）：`tools/cross-host-save.mjs` | 已完成 |",
    "| ✅ 另一种写法 | `tools/cross-host-save.mjs` | 已完成 |",
  ]);
  const got = findStaleGapRows({
    docText: text,
    exists: HAS("tools/cross-host-save.mjs"),
    ciText: CI("tools/cross-host-save.mjs"),
  });
  assert.deepEqual(got, []);
});

test("★ 只在正文里划掉旧等待条件，不算已消除（C12 就是这么被抄进清单的）", () => {
  const text = doc([
    "| **逐字节存档** | 浏览器侧只断言到日志可见 | ~~本机无浏览器自动化能力~~ 这个条件早没了，`tools/cross-host-save.mjs` 在跑 |",
  ]);
  const got = findStaleGapRows({
    docText: text,
    exists: HAS("tools/cross-host-save.mjs"),
    ciText: CI("tools/cross-host-save.mjs"),
  });
  assert.equal(got.length, 1, "首格没标已消除 ⇒ 必须报（正文划掉一句话不能免责）");
  assert.deepEqual(got[0]?.hits, ["tools/cross-host-save.mjs"]);
});

test("工具存在但不在 CI 里 ⇒ 不报（存在 ≠ 这件事做完了）", () => {
  const text = doc(["| 某个缺口 | 现状 | 计划给 `tools/future-thing.mjs` 加个开关 |"]);
  const got = findStaleGapRows({
    docText: text,
    exists: HAS("tools/future-thing.mjs"),
    ciText: CI('node("别的", "tools/other.mjs")'),
  });
  assert.deepEqual(got, [], "没进 CI 的工具不能当成缺口已消除的证据");
});

test("文件根本不存在 ⇒ 不报（规划中的路径不该立刻变红）", () => {
  const text = doc(["| 某个缺口 | 现状 | 以后会有 `tools/future-thing.mjs` |"]);
  const got = findStaleGapRows({ docText: text, exists: () => false, ciText: CI("tools/future-thing.mjs") });
  assert.deepEqual(got, []);
});

test("§六 之外的行不报（否则评分表会把判据喂饱）", () => {
  const text = doc([], {
    before: ["| 二、表格 | `tools/ci.mjs` 在评分表里被点名 | 这一行在 §六 之前 |"],
  });
  const got = findStaleGapRows({ docText: text, exists: HAS("tools/ci.mjs"), ciText: CI("tools/ci.mjs") });
  assert.deepEqual(got, [], "§六 之前 / §七 之后的表格都不属于缺口清单");
});

test("三级标题（###）不截断本节 —— 它下面的缺口行照样要扫", () => {
  const text = doc([], { after: ["| 小节里的缺口 | `tools/ci.mjs` 在跑 | — |"] });
  const got = findStaleGapRows({
    docText: text,
    exists: HAS("tools/ci.mjs"),
    ciText: CI("tools/ci.mjs"),
  });
  assert.equal(got.length, 1, "把 ### 也当成分节符的话，这种行会被漏掉");
});

test("表头分隔行不算缺口行（`|---|---|` 里没有缺口名）", () => {
  const text = doc(["|---|---|---|", "| 正常一行 | 没有任何工具路径 | — |"]);
  assert.equal(gapRowCount(text), 2, "分隔行被当成数据行的话，缺口行数会多算");
  const got = findStaleGapRows({ docText: text, exists: () => true, ciText: CI("") });
  assert.deepEqual(got, []);
});

test("同一行点名两个在跑的工具 ⇒ 两个都列出来，且不重复", () => {
  const text = doc(["| 某个缺口 | `tools/a.mjs` 与 `tools/b.mjs` 都在跑，`tools/a.mjs` 还写了两遍 | — |"]);
  const got = findStaleGapRows({
    docText: text,
    exists: HAS("tools/a.mjs", "tools/b.mjs"),
    ciText: CI("tools/a.mjs tools/b.mjs"),
  });
  assert.equal(got.length, 1);
  assert.deepEqual(got[0]?.hits, ["tools/a.mjs", "tools/b.mjs"]);
});

test("标题不见了 ⇒ 返回 null（判据不静默扫 0 行）", () => {
  const text = "# 进度\n\n## 六七、乱写的标题\n\n| a | b |\n|---|---|\n| x | `tools/ci.mjs` |\n";
  assert.equal(gapSectionLines(text), null);
  assert.deepEqual(findStaleGapRows({ docText: text, exists: () => true, ciText: CI("tools/ci.mjs") }), []);
});

test("真实 PROGRESS.md：0 条过期行，且确实扫到了缺口行（防「扫 0 行也绿」）", () => {
  const docText = readFileSync(join(ROOT, "docs", "PROGRESS.md"), "utf8");
  const ciText = readFileSync(join(ROOT, "tools", "ci.mjs"), "utf8");
  const exists = (rel: string): boolean => {
    try {
      readFileSync(join(ROOT, rel));
      return true;
    } catch {
      return false;
    }
  };
  const rows = gapRowCount(docText);
  assert.ok(rows >= 10, `§六 只扫到 ${String(rows)} 行 —— 标题或表格形式变了，判据其实没在扫`);
  const got = findStaleGapRows({ docText, exists, ciText });
  assert.deepEqual(
    got.map((g) => `PROGRESS.md:${String(g.no)} ${g.hits.join(",")}`),
    [],
    "缺口清单里点名了已在 CI 里跑的工具：要么这条缺口已经做完（把首格标 ✅），要么它缺的不是这个工具",
  );
});

test("接线：docs-check 真的在扫（`--gap-only` 的输出里必须有「清单对账」）", () => {
  // ★ 纯函数的判据证明不了"有人在调用它"。把 docs-check 里那段整块删掉，上面十条全绿 ——
  //   这类"没人接线"的缺口 Node 侧看不见，只能看真实输出。
  //   `--gap-only` 只走这段代码、不数判据（否则要等缓存/全量测试），见 docs-check 里的注释。
  const r = spawnSync(process.execPath, ["tools/docs-check.mjs", "--gap-only"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 120_000,
  });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  assert.match(
    out,
    /清单对账：§六 缺口行 \d+ 行，过期 \d+ 条/,
    `docs-check 没有打印清单对账结果：\n${out.slice(0, 800)}`,
  );
  assert.match(
    out,
    /做完却没关单 \d+ 条/,
    "「做完却没关单」那一行没打出来 —— 新判据可能没接进去（接线不是纯函数判据能证明的）",
  );
  assert.ok(r.status === 0 || r.status === 1, `退出码应当是 0 或 1（0 干净 / 1 有过期行），实际 ${String(r.status)}`);
});

// ---------------------------------------------------------------------------
// 「仍缺」必须挂阻断编号（批113）
//
// ★ 这一组存在的原因：`§六` 里当时有 5 处**早就做完**却仍写着「仍缺」的句子
//   （剧情解锁 / 拖拽换位 / 输入框 / 避头尾 / 脚本热更）。旧规则只抓「点名了已在 CI
//   里跑的工具」，这些句子一个工具都没点名 ⇒ 永远绿。加规则的同时必须给每条规则
//   一发合成语料，否则它就是「绿着但没在扫」。
// ---------------------------------------------------------------------------

const BLOCKERS = [
  "| # | 项 | 状态 |",
  "|---|---|---|",
  "| C2 | 剧情解锁 | ✅ 批103 |",
  "| C9 | 富文本 | 🔜 批106 起 |",
  "| B1 | 微信上传 | ⛔ 阻塞在凭据 |",
].join("\n");

test("[仍缺] 没挂编号 ⇒ 报（否则没人会回去核对它到底做完没有）", () => {
  const text = doc(["| 某个缺口 | **仍缺**：按任务/进度开门 | 等下一个玩家 |"]);
  const got = findUnresolvedClaims(text, BLOCKERS);
  assert.equal(got?.length, 1);
  assert.equal(got?.[0]?.kind, "uncited");
  const lineNo = text.split("\n").findIndex((l) => l.includes("某个缺口")) + 1;
  assert.equal(got?.[0]?.no, lineNo);
});

test("[仍缺] 挂的编号在清单里是 ✅ ⇒ 报（句子过期了，C12 就是这么来的）", () => {
  const text = doc(["| 另一个缺口 | **仍缺**：剧情解锁（C2） | —— |"]);
  const got = findUnresolvedClaims(text, BLOCKERS);
  assert.equal(got?.length, 1);
  assert.equal(got?.[0]?.kind, "stale");
  assert.deepEqual(got?.[0]?.ids, ["C2"]);
});

test("[仍缺] 编号是 🔜 / ⛔ ⇒ 不报（还在排队 / 等凭据，这就是现状）", () => {
  const text = doc([
    "| 甲 | **仍缺**：富文本（C9） | 等排版层重构 |",
    "| 乙 | **仍缺**：微信上传（要 appid，B1） | 等凭据 |",
  ]);
  assert.deepEqual(findUnresolvedClaims(text, BLOCKERS), []);
});

test("[仍缺] 被 ~~ 划掉的不算（历史留痕，不是现状）", () => {
  const text = doc([
    "| 甲 | ~~**仍缺**：输入框~~ ✅ 批110 | —— |",
    "- ~~世界仍缺：**关卡流程**~~ ✅ 已消除（批92）",
  ]);
  assert.deepEqual(findUnresolvedClaims(text, BLOCKERS), []);
});

test("[仍缺] 一行里既有划掉又有仍缺：只有 ~~ 开关注分得清（indexOf 两边都错）", () => {
  const live = doc(["| 甲 | ~~平台分包~~ ✅、~~Steam 上传~~ ✅。**仍缺**：微信上传（B1） | —— |"]);
  assert.equal(findUnresolvedClaims(live, BLOCKERS)?.length, 0, "挂了 B1 且在等凭据 ⇒ 不报");
  const uncited = doc(["| 甲 | ~~平台分包~~ ✅。**仍缺**：微信上传 | —— |"]);
  assert.equal(findUnresolvedClaims(uncited, BLOCKERS)?.length, 1, "没挂编号 ⇒ 报");
});

test("[仍缺] 编号写了但清单里没有 ⇒ 不报（不拿猜出来的状态判红）", () => {
  const text = doc(["| 甲 | **仍缺**：某件事（C99） | —— |"]);
  assert.deepEqual(findUnresolvedClaims(text, BLOCKERS), []);
});

test("[仍缺] 找不到 §六 标题 ⇒ null（不许静默扫 0 行）", () => {
  assert.equal(findUnresolvedClaims("# 没有六\n\n| 甲 | **仍缺**：x | —— |", BLOCKERS), null);
});

test("[仍缺] 真实 PROGRESS.md：0 条，且确实扫到了「仍缺」（防「扫 0 行也绿」）", () => {
  const text = readFileSync(join(ROOT, "docs", "PROGRESS.md"), "utf8");
  const blockersText = readFileSync(join(ROOT, "docs", "BLOCKERS-2026-10-27.md"), "utf8");
  const got = findUnresolvedClaims(text, blockersText);
  assert.notEqual(got, null, "§六 标题没了？");
  assert.deepEqual(got, [], `真实文档里有 ${String(got?.length)} 条「仍缺」没挂编号或已过期`);
  // ★ 上一条只证明「没报」，不证明「扫过」：正文里必须真有『仍缺』，也真有一条挂了编号
  const section = gapSectionLines(text) ?? [];
  assert.ok(section.some((l) => l.text.includes("仍缺")), "§六 里一条「仍缺」都找不到 —— 判据可能扫错了范围");
  assert.ok(
    section.some((l) => /（[^）]*[A-Z]\d+[^）]*）/.test(l.text)),
    "没有一条挂了编号 —— 上面的空数组可能来自「没扫」",
  );
});

// ---------------------------------------------------------------------------
// 「做完了却没关单」（批131）
//
// ★ 这一组存在的原因：`BLOCKERS` 那边批127 就有了规则 ⑤（C18 三项全交付、状态格还挂 🔜），
//   但 `PROGRESS §六` 的缺口表**一条判据都没有**。2026-10-27 批131 实测，
//   `| 补间：混合 / 自定义曲线 |` 这一行三格写满「已交付 / ✅ 批117 / ✅ 批118 / ✅ 批119」，
//   首格却一直没划 —— 19 行缺口行（`gapRowCount` 的口径，含 4 个表头）里
//   有 1 行是**早就做完却还在数**。
//   缺口表的唯一用处就是回答「还剩几件」，一行错就整张表不可信。
// ---------------------------------------------------------------------------

test("[没关单] 首格没划掉、行里却自称做完了 ⇒ 报（连行号与首格原文一起给）", () => {
  const text = doc(["| 补间：混合 / 曲线 | **多关键帧已交付**（批99） | ~~混合~~ ✅ 批117 |"]);
  const got = findForgottenClosures(text);
  assert.equal(got?.length, 1);
  assert.equal(got?.[0]?.head, "补间：混合 / 曲线");
  assert.equal(got?.[0]?.kind, "forgot-close");
  const lineNo = text.split("\n").findIndex((l) => l.includes("补间：混合 / 曲线")) + 1;
  assert.equal(got?.[0]?.no, lineNo, "行号必须指回原文那一行");
});

test("[没关单] 首格划掉 / 带 ✅ ⇒ 不报（已经关过的单不该再报一次）", () => {
  const text = doc([
    "| ~~补间：自定义曲线~~ ✅ 批118 | 已交付 | —— |",
    "| ✅ 另一种写法 | 已交付 | —— |",
  ]);
  assert.deepEqual(findForgottenClosures(text), []);
});

test("★ [没关单] 行里写明「仍缺 X」⇒ 不报（半路的话要能写得出来，否则判据会逼人撒谎）", () => {
  const text = doc([
    "| 甲 | 已交付一半，**仍缺**：B | —— |",
    "| 乙 | 已完成 A，没做 B | —— |",
    "| 丙 | 已交付 A，待补 B | —— |",
  ]);
  assert.deepEqual(findForgottenClosures(text), [], "只要还写着还差什么，这条缺口就还是开着的");
});

test("[没关单] 自称做完的话被 ~~ 划掉 ⇒ 不算（划掉的部分是历史留痕）", () => {
  const text = doc(["| 甲 | ~~已交付（批99）~~ 后来重新打开了 | —— |"]);
  assert.deepEqual(findForgottenClosures(text), [], "不剥 ~~…~~ 的话，这行会被误报成没关单");
});

test("[没关单] 什么都没说的行 ⇒ 不报（没有结论就没有矛盾）", () => {
  const text = doc(["| 甲 | 现状一句话 | 为什么先不做 |"]);
  assert.deepEqual(findForgottenClosures(text), []);
});

test("[没关单] §七 的表不扫（作用域只在 §六，否则评分表会把判据喂饱）", () => {
  const text = [
    "# 进度",
    "",
    GAP_HEADING,
    "",
    "| 缺口 | 现状 | 在等什么 |",
    "|---|---|---|",
    "| 甲 | 还没做 | —— |",
    "",
    "## 七、下一阶段",
    "",
    "| 已交付的东西 | 说明 |",
    "|---|---|",
    "| 引擎 | 阶段一已交付 |",
    "",
  ].join("\n");
  assert.deepEqual(findForgottenClosures(text), []);
});

test("[没关单] 找不到 §六 标题 ⇒ null（不许静默扫 0 行）", () => {
  assert.equal(findForgottenClosures("# 没有六\n\n| 甲 | 已交付 | —— |"), null);
});

test("[没关单] 真实 PROGRESS.md：0 条，且确实扫过「已划掉的行」", () => {
  const text = readFileSync(join(ROOT, "docs", "PROGRESS.md"), "utf8");
  const found = findForgottenClosures(text);
  assert.notEqual(found, null, "§六 标题没了？");
  // ★ `?? []` 只为收窄类型：上面那条断言已经把 `null` 挡掉了，
  //   换成 `?? []` 反而会让"标题消失"变成"0 条"（正是要防空的那种绿）。
  const got = found ?? [];
  assert.deepEqual(
    got.map((g) => `PROGRESS.md:${String(g.no)} ${g.head}`),
    [],
    "这些缺口行自称做完了、首格却没划掉 —— 缺口表要能回答「还剩几件」",
  );
  // ★ 空数组也可能来自「没扫到任何行」：真实文档里必须真有被划掉的行（否则这条判据
  //   只是把"全都开着"误读成"全都关着"）。
  const section = gapSectionLines(text) ?? [];
  assert.ok(
    section.some((l) => /\|\s*~~/.test(l.text)),
    "§六 里一条划掉的行都没有 —— 上面的空数组可能来自「没扫」",
  );
  assert.ok(
    section.some((l) => !/\|\s*~~/.test(l.text) && l.text.includes("|")),
    "§六 里一条没划掉的行都没有 —— 那这条判据永远绿，等于没写",
  );
});
