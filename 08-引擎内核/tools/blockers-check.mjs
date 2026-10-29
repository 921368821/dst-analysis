/**
 * 阻塞项对账：让「已消除」这句话必须由**磁盘上的一条判据**兜住。
 *
 * ★ 为什么需要它（2026-10-27 批102 实测，第三次踩同一个形状）：
 *
 *   `docs/BLOCKERS-*.md` 里的 C 项，至少有四条**早就做完了**却还挂着「没做」：
 *   C5「引擎根本没有脚本运行时」（`src/backends/script-lua/runtime.ts` 一直在）、
 *   C7「要先有导航网格」（`src/extensions/nav/nav-grid.ts` 批60 就交付了）、
 *   C10「缺 `PixelFormat` 扩展」（`PixelFormat.RGBA16` + `tests/core/render-rgba16-upload.test.ts` 都在）、
 *   C11「`unloadModule` 清不掉 `_G`」（`unloadFn` + `__engine_compat_unmodule` + 一条专门的判据）。
 *   再往前数，C12 是同一形状的第三次（批96 才核对掉）。
 *
 *   根因不是「某人忘了改」，而是**这句话没有任何东西在管**：
 *   一条 ✅ 只要有人写过一次就永久成立；代码后来变了、文件改名了、判据删了，
 *   没有任何一环会去问它一句。所以这条判据管的是**它能管的那一半**（见下）。
 *
 * ★ 只做能机器验的四条规则，不做「读起来像不像」：
 *
 *   ① **单行**：数据行必须以 `|` 结尾。多行单元格会让「状态」那一格读不出来，
 *      于是「这条到底是开着还是关着」只能靠人眼扫 —— 那正是这份清单失守的方式。
 *   ② **引用必须活着**：行里点名的每个路径都得存在。改名/删文件立刻红，不许留死引用。
 *   ③ **✅ 必须给证**：行内至少要有一段「…」逐字出现在它引用的某个文件里。
 *      不能是「我记得做完了」，也不能是「文件还在」。判据被删 ⇒ 这句引文找不到 ⇒ 红。
 *   ④ **状态是受控词表**：`✅` 已消除 / `⛔` 外部阻塞 / `🔜` 排队 / `❌` 决定不做。
 *      第四种是必须留的 —— 「决定不做」和「还没做」是两件事，混在一起就会被反复重提。
 *   ⑤ **自述与状态不许互相打脸**（批127 新增）：`项` 格里写着「全部交付 / 已交付 /
 *      已消除」，状态却不是 `✅` ⇒ 红。这条挡的是**做完之后忘了关单**：
 *      C18 的三项在批122/123/124 全部交付、批126 又补了演示生态，而状态格一直挂着
 *      `🔜 未排期` —— 前四条规则全绿，因为 `🔜` 本来就不要求证据。
 *      「开着的东西」与「已经做完的东西」在同一格里同时成立，清单就再也回答不了
 *      「还剩几件」；而"还剩几件"正是这份文件唯一的存在理由。
 *
 * ★ 它**验不到**什么（必须写出来，否则下一个人会以为绿了就都对）：
 *
 *   「claim 过期但文件都还在」。C10 那种情形（`PixelFormat` 早加了，几个文件一个没改名）
 *   在这四条规则下**永远是绿的**。这一半只能靠「每次清查都重跑一遍磁盘」，
 *   所以对账方法与本次结论要落进文档（`BLOCKERS` §四），而不是指望闸门。
 *   ⑤ 也一样：它只读**`项`那一格**。缺口若藏在别格的散文里，它照样看不见 ——
 *   C17 就是这么过的（整行 ✅，而「验证」格里写着「`?pack=` 那条真实加载路径
 *   还没有端到端判据」）。那一半只能靠"清查时逐格读一遍"，所以批127 给它编了号（C21）。
 */

/** 受控状态词表：顺序有意义（`✅` 是唯一需要给证据的那一类）。 */
export const BLOCKER_MARKERS = ["✅", "⛔", "🔜", "❌"];

/** 行里被点名的仓库内路径。允许 `vendor/`：上游素材也算证据。 */
const PATH_RE = /(?:src|tests|tools|docs|web|vendor)\/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+/g;

/** 行内的「…」引文（少于 4 个字的短词不算证据：`「状态」` 这种能匹配到任何文档）。 */
const QUOTE_RE = /「([^」]{4,})」/g;

/** 清单文件名形如 `BLOCKERS-2026-10-27.md`（带日期，所以按名字排序取最新）。 */
export function pickBlockersDoc(names) {
  const list = names.filter((n) => /^BLOCKERS-.*\.md$/.test(n)).sort();
  return list.length === 0 ? null : list[list.length - 1];
}

/**
 * 「项」格里自称做完了的说法（规则 ⑤ 用）。
 *
 * ★ 只认**这一格**、只认这几种词：`项` 是这条阻塞项的名字，"它做完了没有"是它
 *   唯一该回答的问题。别格里的「已交付」经常是在讲**前置件**（C3「开关已交付（批95）」
 *   指的是能力在、只是决定不读朝向），拿它判红就是假红 —— 假红会让人关掉闸门。
 */
const DONE_CLAIM_RE = /全部交付|已交付|已消除/;

function splitCells(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => c.trim());
}

/**
 * 清单里的**数据行**：首格是 `A1`/`B2`/`C11` 这种编号。
 *
 * ★ 表头（`| # | 项 |`）与分隔行（`|---|`）靠这条自动跳过，不需要单独认。
 *   `closed` 记「这一行是否以 `|` 结尾」—— 它就是「单元格有没有跨行」的判据。
 */
export function blockerRows(docText) {
  const lines = docText.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (!t.startsWith("|")) continue;
    const cells = splitCells(t);
    if (!/^[ABC]\d+$/.test(cells[0] ?? "")) continue;
    out.push({ no: i + 1, id: cells[0], cells, text: t, singleLine: t.endsWith("|") });
  }
  return out;
}

/** 清单里的数据行数（给 `docs-check` 打印：0 行 = 判据没在扫）。 */
export function blockerRowCount(docText) {
  return blockerRows(docText).length;
}

/**
 * 扫出清单里的问题。
 *
 * @param {object} p
 * @param {string} p.docText    整篇清单
 * @param {(rel: string) => boolean} p.exists    相对仓库根判断存在性（注入，便于测试）
 * @param {(rel: string) => string} p.readText   读文本（不存在时返回空串即可）
 * @returns {{no: number, id: string, code: string, detail: string}[]}  空数组 = 没有发现问题
 */
export function findBlockerIssues({ docText, exists, readText }) {
  const issues = [];
  const seen = new Set();
  for (const row of blockerRows(docText)) {
    const push = (code, detail) => issues.push({ no: row.no, id: row.id, code, detail });
    if (!row.singleLine) {
      push("ROW_MULTILINE", "这一行没有以 | 结尾 ⇒ 单元格跨行了，「状态」那一格读不出来");
      continue;
    }
    if (seen.has(row.id)) push("DUP_ID", "同一个编号出现两次（复制粘贴留下的一半）");
    seen.add(row.id);

    const status = row.cells[row.cells.length - 1] ?? "";
    const marker = BLOCKER_MARKERS.find((m) => status.startsWith(m));
    if (marker === undefined) {
      push("BAD_STATUS", `状态格必须以 ${BLOCKER_MARKERS.join(" / ")} 之一开头，实际是「${status.slice(0, 12)}」`);
      continue;
    }

    const paths = [...new Set(row.text.match(PATH_RE) ?? [])];
    const dead = paths.filter((p) => !exists(p));
    if (dead.length > 0) push("DEAD_PATH", `行里点名的路径不存在：${dead.join(", ")}`);

    // ★ 规则 ⑤：`项` 格自称做完，状态却不是 ✅ ⇒ 做完之后忘了关单（C18 的形状）。
    //   只在非 ✅ 时检查：✅ 行里出现「已交付」是正常叙述（"批122 已交付"）。
    if (marker !== "✅") {
      const item = row.cells[1] ?? "";
      const claim = DONE_CLAIM_RE.exec(item);
      if (claim !== null) {
        push(
          "STATUS_CONTRADICTS_ITEM",
          `「项」格里写着「${claim[0]}」，状态却是 ${marker} —— 要么补证据改成 ✅，要么把自述改掉（两者都成立时，清单就不再回答「还剩几件」）`,
        );
      }
    }

    // ★ 只有 ✅ 要证据：⛔ 是外部凭据、🔜 是排队、❌ 是决定不做 —— 它们「没有证据」是正常的。
    if (marker !== "✅") continue;
    const live = paths.filter((p) => exists(p));
    if (live.length === 0) {
      push("NO_EVIDENCE", "标了已消除，却一个文件都没点名");
      continue;
    }
    const quotes = [...row.text.matchAll(QUOTE_RE)].map((m) => m[1]);
    const hit = quotes.some((q) => live.some((p) => readText(p).includes(q)));
    if (!hit) {
      push(
        "UNVERIFIED",
        `引用的 ${String(live.length)} 个文件里找不到行内任何一句「…」原话` +
          "（证据要能被逐字核对：贴一条判据名或一句代码注释）",
      );
    }
  }
  return issues;
}
