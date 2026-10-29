/**
 * 阻塞清单对账的判据
 *
 * 为什么值得单测：这条判据今天的输出是**空数组**（清单对干净了），
 * 而「扫了没发现问题」与「根本没在扫」在输出上完全一样。
 * 所以每条规则都要用**合成语料**正向打一发：删掉被测规则，必须有一条红。
 *
 * ★ 语料不是编的，每一条都是真实出错过的样子：
 *   · 「✅ 但一个文件都没点名」= C10/C11 的形态（「我记得做完了」）；
 *   · 「引文在文件里找不到」= 判据被删/改名之后，清单还挂着旧名；
 *   · 「多行单元格」= C3 原来那样，状态那格读不出来，只能靠人眼；
 *   · 「⛔ 没有证据」**不该报** = 外部凭据本来就没证据，误报会让人关掉判据。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  BLOCKER_MARKERS,
  blockerRowCount,
  findBlockerIssues,
  pickBlockersDoc,
} from "../../tools/blockers-check.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** 造一篇最小清单：表头 + 给定的数据行。 */
function doc(rows: string[]): string {
  return ["# 阻塞项", "", "| # | 项 | 现状 | 验证 | 状态 |", "|---|---|---|---|---|", ...rows, ""].join("\n");
}

/** 一个假的文件系统：`files` 里的路径算存在，内容就是它的字符串。 */
function fs(files: Record<string, string>) {
  return {
    exists: (rel: string) => Object.hasOwn(files, rel),
    readText: (rel: string) => files[rel] ?? "",
  };
}

const SRC = "src/a.ts";
const TST = "tests/a.test.ts";
const OK_FS = fs({
  [SRC]: "export const x = 1;",
  [TST]: 'test("★★ 甲：这条判据真的在守一件事", () => {});',
});

test("真实清单：0 条问题，且确实扫到了数据行（防「扫 0 行也绿」）", () => {
  const name = pickBlockersDoc(readdirSync(join(ROOT, "docs")));
  assert.ok(name !== null, "docs/ 下找不到 BLOCKERS-*.md");
  const docText = readFileSync(join(ROOT, "docs", name), "utf8");
  const exists = (rel: string) => {
    try {
      readFileSync(join(ROOT, rel));
      return true;
    } catch {
      return false;
    }
  };
  const readText = (rel: string) => {
    try {
      return readFileSync(join(ROOT, rel), "utf8");
    } catch {
      return "";
    }
  };
  const got = findBlockerIssues({ docText, exists, readText });
  assert.deepEqual(
    got.map((g) => `${name}:${String(g.no)} ${g.id} ${g.code} ${g.detail}`),
    [],
    "阻塞清单里有对不上的行（死引用 / 没证据的 ✅ / 状态不合词表 / 跨行单元格）",
  );
  // ★ 下限而不是上限：以后加条目不该改这里，但"扫到 0 行"必须红。
  assert.ok(blockerRowCount(docText) >= 15, `只扫到 ${String(blockerRowCount(docText))} 行，判据没在扫`);
});

test("✅ 但一个文件都没点名 ⇒ NO_EVIDENCE（「我记得做完了」不算证据）", () => {
  const got = findBlockerIssues({ docText: doc(["| C1 | 甲 | 早就做完了 | —— | ✅ 已消除 |"]), ...OK_FS });
  assert.deepEqual(got.map((g) => g.code), ["NO_EVIDENCE"]);
});

test("✅ 点名了文件，但行内没有「…」引文 ⇒ UNVERIFIED（文件还在 ≠ 这件事做完了）", () => {
  const got = findBlockerIssues({
    docText: doc(["| C1 | 甲 | 早就做完了 | `src/a.ts` | ✅ 已消除 |"]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), ["UNVERIFIED"]);
});

test("✅ 引文在引用的文件里逐字存在 ⇒ 通过（证明这条规则不是恒红）", () => {
  const got = findBlockerIssues({
    docText: doc([`| C1 | 甲 | 早就做完了 | \`${TST}\` 的「★★ 甲：这条判据真的在守一件事」 | ✅ 已消除 |`]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), []);
});

test("✅ 的引文改一个字就红 ⇒ UNVERIFIED（引文是逐字核对的，不是相似度）", () => {
  const got = findBlockerIssues({
    docText: doc([`| C1 | 甲 | 早就做完了 | \`${TST}\` 的「★★ 甲：这条判据在守一件事」 | ✅ 已消除 |`]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), ["UNVERIFIED"]);
});

test("点名的路径不存在 ⇒ DEAD_PATH（改名/删除之后不许留死引用）", () => {
  // ★ 同时会报 NO_EVIDENCE：这一行唯一的引用是死的 ⇒ 活着可核的证据为零。
  //   两条都报是有意的 —— 一条说"引用没了"，一条说"于是证据也空了"，
  //   合成一条会让人以为「补个路径就行」，而实际上判据本身可能已经被删了。
  const got = findBlockerIssues({
    docText: doc([`| C1 | 甲 | 做完了 | \`tests/gone.test.ts\` 的「任意一句」 | ✅ 已消除 |`]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), ["DEAD_PATH", "NO_EVIDENCE"]);
});

test("单元格跨行（行尾没有 |）⇒ ROW_MULTILINE（状态那格读不出来）", () => {
  const got = findBlockerIssues({
    docText: doc(["| C1 | 甲 | 第一行", "第二行接着写 | ✅ 已消除 |"]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), ["ROW_MULTILINE"]);
});

test("状态不在受控词表里 ⇒ BAD_STATUS（「做了一半」这种状态必须落到四种之一）", () => {
  const got = findBlockerIssues({ docText: doc(["| C1 | 甲 | 现状 | —— | 半做完 |"]), ...OK_FS });
  assert.deepEqual(got.map((g) => g.code), ["BAD_STATUS"]);
});

test("⛔ / 🔜 / ❌ 不要求证据（外部凭据与「决定不做」本来就没有判据）", () => {
  for (const m of ["⛔", "🔜", "❌"]) {
    const got = findBlockerIssues({ docText: doc([`| B1 | 甲 | 卡在凭据 | —— | ${m} 说明 |`]), ...OK_FS });
    assert.deepEqual(got.map((g) => g.code), [], `${m} 行不该被要求给证据`);
  }
  assert.deepEqual(BLOCKER_MARKERS, ["✅", "⛔", "🔜", "❌"]);
});

test("同一个编号出现两次 ⇒ DUP_ID（复制粘贴留下的一半）", () => {
  const got = findBlockerIssues({
    docText: doc([`| C1 | 甲 | 卡在凭据 | —— | 🔜 排队 |`, `| C1 | 乙 | 卡在凭据 | —— | 🔜 排队 |`]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), ["DUP_ID"]);
});

test("「项」格写着「全部交付」却还挂着 🔜 ⇒ STATUS_CONTRADICTS_ITEM（做完忘了关单）", () => {
  // ★ 这是 C18 的真实样子：地面堆叠 / 尸体 / 动态障碍在批122–124 全部交付、
  //   演示生态批126 补上，而状态格一直挂 `🔜 未排期`。前四条规则全绿
  //   —— `🔜` 本来就不要求证据，于是「做完了」与「还开着」在同一行同时成立，
  //   清单再也回答不了「还剩几件」。
  const got = findBlockerIssues({
    docText: doc([
      `| C18 | 玩法层三缺（**三项全部交付**：批122 / 批123 / 批124） | 现状 | —— | 🔜 未排期 |`,
    ]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), ["STATUS_CONTRADICTS_ITEM"]);
});

test("别格里的「已交付」不算自述 ⇒ 不许报（C3 的形状：能力已交付、项目决定不做）", () => {
  // ★ 假红比漏报更贵：被误报吓过一次的人会把整条闸门关掉。
  //   C3 的现状格里写着「开关已交付（批95）」，但那是**前置件**；
  //   这条阻塞项本身的状态是「决定不做」。只看「项」格就不会误伤。
  const got = findBlockerIssues({
    docText: doc([
      `| C3 | 门的方向性 | 开关已交付（批95）；剩下的确实是玩法决定 | —— | ❌ 决定不做 |`,
    ]),
    ...OK_FS,
  });
  assert.deepEqual(got.map((g) => g.code), []);
});


test("清单文件名带日期 ⇒ 取最新那份（拿旧清单对账等于没对账）", () => {
  assert.equal(pickBlockersDoc(["BLOCKERS-2026-10-27.md", "BLOCKERS-2026-03-01.md", "README.md"]), "BLOCKERS-2026-10-27.md");
  assert.equal(pickBlockersDoc(["README.md"]), null);
});

test("接线：docs-check 真的在扫（`--blockers-only` 的输出里必须有「阻塞项对账」）", () => {
  // ★ 纯函数判据证明不了"有人在调用它"：把 docs-check 里那段整块删掉，上面十条全绿。
  //   `--blockers-only` 只走这段代码、不数判据（否则要等缓存/全量测试）。
  const r = spawnSync(process.execPath, ["tools/docs-check.mjs", "--blockers-only"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 120_000,
  });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  assert.match(out, /阻塞项对账：\d+ 行，问题 \d+ 条/, `docs-check 没有打印阻塞项对账结果：\n${out.slice(0, 800)}`);
  assert.ok(r.status === 0 || r.status === 1, `退出码应当是 0 或 1（0 干净 / 1 有问题），实际 ${String(r.status)}`);
});
