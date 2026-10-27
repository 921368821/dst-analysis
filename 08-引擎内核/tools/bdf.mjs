/**
 * BDF（X11 Bitmap Distribution Format）解析器 —— 只做"位图字库 → 字形表"
 *
 * 为什么自己写而不是引包：
 *   ① 我们只需要 BDF 的一个子集（`ENCODING` / `DWIDTH` / `BBX` / `BITMAP`），
 *      而现成的包大多会顺手做字体族回退、Unicode 变体选择、渲染尺寸缩放 —— 那些
 *      都是"同一份输入在不同包版本下产出不同字节"的来源，而这张图集要逐字节可复现；
 *   ② 解析规则一共几十行，读得完；引一个包则要在 CI 里解释"为什么它今天产出不一样"。
 *
 * ★★ 这个文件里最要紧的不是"能解析"，而是**坏数据必须报错**：
 *   BDF 是逐行的状态机（`STARTCHAR` → `BBX` → `BITMAP` → 十六进制行 → `ENDCHAR`），
 *   少一行 `BITMAP` 或行数比 `BBX` 的 `h` 少一行，得到的是**一个少了几行的字** ——
 *   排版照旧推进、宽度全对、画面上那个字缺一块。那类错误只能在这里挡住。
 *
 * ★ 行尾：上游 BDF 是 LF。这里按 `\r?\n` 切，避免 Windows 上 checkout 之后
 *   每行末尾多一个 `\r`，让十六进制串多一位而 decode 出垃圾。
 */

const ERR = "BDF";

function fail(code, message) {
  throw new Error(`${ERR}.${code}：${message}`);
}

/**
 * 十六进制行 → 位。
 * BDF 规定每行按**字节**对齐：w ≤ 8 时每行 2 个十六进制字符，w ≤ 16 时 4 个……
 * ★ 用"字节数"而不是"字符数"做校验：多一位或少一位都是坏数据，
 *   而 `parseInt` 对多余的位**不报错**（它只是把值算大），于是会静默错位。
 */
function hexRowToBits(hex, w, code, row) {
  const bytes = Math.ceil(w / 8);
  if (hex.length !== bytes * 2) {
    fail("BAD_ROW", `U+${code.toString(16)} 第 ${row} 行应为 ${bytes * 2} 个十六进制字符，实际 ${hex.length}：${hex}`);
  }
  if (!/^[0-9A-Fa-f]+$/.test(hex)) fail("BAD_HEX", `U+${code.toString(16)} 第 ${row} 行不是十六进制：${hex}`);
  const bits = [];
  for (let x = 0; x < w; x++) {
    const byte = Number.parseInt(hex.slice((x >> 3) * 2, (x >> 3) * 2 + 2), 16);
    // 高位在左：BDF 与几乎所有位图格式一致
    bits.push((byte >> (7 - (x & 7))) & 1);
  }
  return bits;
}

/**
 * 解析 BDF 文本。
 *
 * `only`：只保留这些码点（子集化）。给了它就**不保留**其它字形 ——
 *   整字库 5.7 万字形的位图留在内存里没有意义，而"先全解析再过滤"会让
 *   内存峰值是必要值的十倍。
 *
 * @param {string} text
 * @param {ReadonlySet<number>} [only]
 */
export function parseBdf(text, only) {
  const lines = text.split(/\r?\n/);
  let ascent = null;
  let descent = null;
  let bboxW = 0;
  let bboxH = 0;

  const glyphs = new Map();
  let scanned = 0;

  // 状态机的当前字形
  let code = null;
  let advance = null;
  let bbx = null;
  let bitmap = null;

  const reset = () => {
    code = null;
    advance = null;
    bbx = null;
    bitmap = null;
  };

  const flush = (at) => {
    if (code === null) fail("NO_ENCODING", `第 ${at} 行附近的字形没有 ENCODING`);
    if (advance === null) fail("NO_DWIDTH", `U+${code.toString(16)} 没有 DWIDTH（排版会退化成"零宽"）`);
    if (bbx === null) fail("NO_BBX", `U+${code.toString(16)} 没有 BBX`);
    if (bitmap === null) fail("NO_BITMAP", `U+${code.toString(16)} 没有 BITMAP 段`);
    if (bitmap.length !== bbx.h) {
      fail("BAD_ROW_COUNT", `U+${code.toString(16)} 的 BITMAP 有 ${bitmap.length} 行，BBX 说 ${bbx.h} 行`);
    }
    if (only === undefined || only.has(code)) {
      // 墨迹全空的字形按"宽度 0"处理（空格、以及 BDF 里那些画成空白的占位字）。
      // ★ 不能只判 `w === 0`：Unifont 的 U+0020 有 8×16 的 BBX，只是每行都是 00。
      let any = false;
      const cols = [];
      for (let x = 0; x < bbx.w; x++) cols.push(new Array(bbx.h).fill(0));
      for (let y = 0; y < bbx.h; y++) {
        const bits = hexRowToBits(bitmap[y], bbx.w, code, y);
        for (let x = 0; x < bbx.w; x++) {
          if (bits[x] === 1) {
            cols[x][y] = 1;
            any = true;
          }
        }
      }
      glyphs.set(code, {
        code,
        advance,
        w: any ? bbx.w : 0,
        h: any ? bbx.h : 0,
        xoff: bbx.x,
        yoff: bbx.y,
        cols: any ? cols : null,
      });
    }
    reset();
  };

  for (let i = 0; i < lines.length; i++) {
    const raw = (lines[i] ?? "").trim();
    if (raw === "") continue;
    const sp = raw.indexOf(" ");
    const key = sp < 0 ? raw : raw.slice(0, sp);
    const rest = sp < 0 ? "" : raw.slice(sp + 1).trim();

    switch (key) {
      case "FONT_ASCENT": {
        ascent = Number.parseInt(rest, 10);
        if (!Number.isFinite(ascent)) fail("BAD_ASCENT", `FONT_ASCENT 不是数字：${rest}`);
        break;
      }
      case "FONT_DESCENT": {
        descent = Number.parseInt(rest, 10);
        if (!Number.isFinite(descent)) fail("BAD_DESCENT", `FONT_DESCENT 不是数字：${rest}`);
        break;
      }
      case "FONTBOUNDINGBOX": {
        const p = rest.split(/\s+/).map((s) => Number.parseInt(s, 10));
        if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) fail("BAD_FBB", `FONTBOUNDINGBOX 非法：${rest}`);
        bboxW = p[0];
        bboxH = p[1];
        break;
      }
      case "STARTCHAR":
        if (code !== null) fail("NESTED", `第 ${i + 1} 行：上一个字形没 ENDCHAR 就开始了新的`);
        scanned++;
        break;
      case "ENCODING": {
        const v = Number.parseInt(rest, 10);
        if (!Number.isFinite(v) || v < 0) {
          // -1 = 未编码字形（只用于按名字引用）。跳过它，但不能让它污染状态机。
          code = -1;
          break;
        }
        code = v;
        break;
      }
      case "DWIDTH": {
        const v = Number.parseInt(rest.split(/\s+/)[0] ?? "", 10);
        if (!Number.isFinite(v)) fail("BAD_DWIDTH", `DWIDTH 非法：${rest}`);
        advance = v;
        break;
      }
      case "BBX": {
        const p = rest.split(/\s+/).map((s) => Number.parseInt(s, 10));
        if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) fail("BAD_BBX", `BBX 非法：${rest}`);
        bbx = { w: p[0], h: p[1], x: p[2], y: p[3] };
        break;
      }
      case "BITMAP":
        bitmap = [];
        break;
      case "ENDCHAR":
        if (code === -1) {
          reset();
          break;
        }
        flush(i + 1);
        break;
      default:
        // BITMAP 段里的十六进制行：没有前缀，全行都是 hex。
        // ★ 这里**不预先判 hex**：判了就等于"不是 hex 就悄悄跳过"，
        //   于是坏行只会表现为"行数少了"，报出来的是 BAD_ROW_COUNT 而不是 BAD_HEX ——
        //   错误码指错方向，比没报错更费时间。行内容交给 `hexRowToBits` 逐行验。
        if (bitmap !== null && code !== null && rest === "") {
          bitmap.push(key);
        }
        break;
    }
  }

  if (ascent === null || descent === null) fail("NO_METRIC", "缺 FONT_ASCENT / FONT_DESCENT（行高与基线都不可知）");
  return { ascent, descent, bboxW, bboxH, glyphs, scanned };
}
