/**
 * 缺口清单对账：**一条「缺口」点名了某个 `tools/` 路径，而那个工具已经在 CI 里跑。**
 *
 * ★ 为什么需要这条判据（2026-10-27 批96 实测）：
 *
 *   `PROGRESS §六` 里有一行「headless ↔ 浏览器逐字节存档」，从批57 起一直写着
 *   "浏览器侧只断言到 Lua 算得对 + 跨界日志可见"。而批57 就把
 *   `tools/cross-host-save.mjs` 接进 CI 了 —— 这件事**早就做完了**。
 *   批94 清查阻塞项时我照抄了那一行，于是它进了 `BLOCKERS` 的 C12，
 *   一条"已完成"被记成"待办"，还配了一句自己编的现状。
 *
 *   教训不是"记得回头看"，而是：**对账的对象是磁盘，不是上一版清单**。
 *   所以把它变成判据 —— 缺口行里点名的工具如果已经在 CI 里跑，
 *   那这条缺口要么已经做完（改清单），要么它缺的根本不是这个工具（改措辞）。
 *
 * ★ 这条判据只可能给出**两种**结论，所以它不猜：
 *
 *   · 报出来 ⇒ 让人看那一行：是"做完了没划掉"，还是"点名点错了工具"；
 *   · 不报   ⇒ 这一行没有"已经有工具在跑"的证据，不能凭它判断做没做。
 *   **"文件存在"不等于"这件事做完了"** —— 所以条件里必须带上"在 CI 里跑"，
 *   否则每个规划中的路径都会立刻变成红（假红比不报更坏：人会去关掉判据）。
 *
 * ★ 判据本身的三道防空转（这类"扫文档"的判据最容易变成摆设）：
 *   ① 作用域钉死在 `## 六、已知缺口` 一节，避免被 §二 的评分表喂饱；
 *   ② 首格里带 ✅ / ~~ 视为已消除 —— 但**只看首格**：正文里划掉一句话不算
 *      （那正是 C12 的样子：正文划掉了旧等待条件，缺口名还在）；
 *   ③ `docs-check` 里有一条**反向自检**：合成一条过期行，必须被抓到；
 *      抓不到就 exit 2，不许"绿着但没在扫"。
 */

/** §六 的标题。改标题会让判据立刻报问题，而不是静默扫 0 行。 */
export const GAP_HEADING = "## 六、已知缺口";

/** `tools/` 下带扩展名的路径（`tools/a.mjs`、`tools/x/y.ts`）。 */
const TOOL_PATH = /tools\/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+/g;

/**
 * 取 §六 的正文行（到下一个二级标题为止），带**原文行号**。
 *
 * ★ 行号必须从原文推，不能从片段推：给作者看的 `PROGRESS.md:1510`
 *   一旦是片段内的相对行号，就去错了地方，人去那条看会以为判据在瞎报。
 */
export function gapSectionLines(docText) {
  const lines = docText.replace(/\r\n/g, "\n").split("\n");
  const start = lines.findIndex((l) => l.startsWith(GAP_HEADING));
  if (start < 0) return null;
  const out = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) break;
    out.push({ no: i + 1, text: lines[i] });
  }
  return out;
}

/** Markdown 表格行切格（容忍首尾竖线两侧的空格）。 */
function cells(line) {
  const t = line.trim();
  if (!t.startsWith("|")) return null;
  return t.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
}

/** 表格的分隔行（`|---|---|`）。 */
function isSeparator(row) {
  return row.every((c) => /^:?-{3,}:?$/.test(c));
}

/**
 * §六 里的**数据行**（去掉表头与分隔行）。
 *
 * ★ 收成一处的理由：`findStaleGapRows` 与 `gapRowCount` 都要"哪些行算缺口行"这一件事。
 *   两处各写一遍的话，变异只能打到其中一个 —— 另一个的错就永远没人咬（批96 的
 *   「一条帧驱动路径配一条判据」是同一个道理：同一件事两条实现，只有一条被验）。
 */
function dataRows(section) {
  const out = [];
  for (const line of section) {
    const row = cells(line.text);
    if (row === null || isSeparator(row)) continue;
    out.push({ no: line.no, row, text: line.text });
  }
  return out;
}

/**
 * 扫出「首格没标已消除、却点名了已在 CI 里跑的工具」的缺口行。
 *
 * @param {object} p
 * @param {string} p.docText   整篇文档
 * @param {(rel: string) => boolean} p.exists  相对仓库根判断存在性（注入，便于测试）
 * @param {string} p.ciText    `tools/ci.mjs` 的源码文本
 * @returns {{no: number, head: string, hits: string[]}[]}  空数组 = 没有过期行
 */
export function findStaleGapRows({ docText, exists, ciText }) {
  const section = gapSectionLines(docText);
  if (section === null) return [];
  const issues = [];
  for (const { no, row, text } of dataRows(section)) {
    const head = row[0] ?? "";
    // ② 只看首格：正文里划掉一句话不能顶替"这条缺口已经消除了"
    if (head.includes("✅") || head.includes("~~")) continue;
    const paths = text.match(TOOL_PATH) ?? [];
    // ★ 去重：同一行里同一个路径写两遍不该报两遍
    const hits = [...new Set(paths)].filter((p) => exists(p) && ciText.includes(p));
    if (hits.length > 0) issues.push({ no, head, hits });
  }
  return issues;
}

/** §六 里的缺口行数（给 `docs-check` 打印用：0 行 = 判据没在扫）。 */
export function gapRowCount(docText) {
  const section = gapSectionLines(docText);
  if (section === null) return 0;
  return dataRows(section).length;
}
