/**
 * UAX #9 双向算法（Unicode Bidirectional Algorithm）—— 纯函数核心。
 *
 * ★★ 为什么单独一个文件、为什么"照抄"规范阶段而不是"反着遍历一遍"：
 *   RTL 不是「从右往左画」：数字与英文在阿拉伯/希伯来文里仍然从左往右排，
 *   标点归属哪一侧由上下文的强类型决定，括号还有自己的配对规则（N0）。
 *   这些互相纠缠的规则只有按 TR9 的阶段完整跑一遍才正确 —— 本实现的阶段
 *   划分与 servo/unicode-bidi 一致（P2/P3 → X1–X10 → W1–W7 → N0–N2 → I1–I2
 *   → L1–L2），API 形状参考 bidi-js（getEmbeddingLevels / getReorderSegments），
 *   正确性由 **Unicode 官方 conformance 语料**（BidiTest.txt / BidiCharacterTest.txt
 *   的确定性子集，见 vendor/bidi/）钉住 —— 那也是 servo/bidi-js/wezterm-bidi
 *   的验收方式，不是本项目自创的。
 *
 * ---- 参考来源（先看业界怎么做，再定本实现的结构）----
 *   · **Unicode UAX #9（tr9-49）**：规则的唯一依据。阶段编号（P2/P3、X1–X10、
 *     W1–W7、N0–N2、I1/I2、L1/L2、M1）直接沿用规范，注释引的是规范原文措辞。
 *   · **FriBidi**（C，GNU）：把规则摊成"一个函数一条规则"（`resolve_explicit`、
 *     `resolve_weak`、`resolve_neutral`、`resolve_implicit`、`resolve_levels`）。
 *     本实现的**函数边界照它划** —— 一条规则一个作用域，红了立刻知道是哪条。
 *   · **servo/unicode-bidi**（Rust）：阶段划分最干净（`explicit::compute` →
 *     `prepare` 里造 isolating run sequences → `implicit` → `reorder`）。
 *     **数据流照它**：先按 BD13 备好序列，再在序列内部跑 W/N/I。
 *   · **bidi-js**（JS，MIT）：API 形状最贴合（`getEmbeddingLevels` /
 *     `getReorderSegments` / `getMirroredCharactersMap`），内部结构与上面两家一致。
 *     本实现的 `embeddingLevels` / `reorderLine` 与它同形，调试时拿它当"第二意见"
 *     （只用 `npm install --no-save` 离线对照过，**项目不依赖这个包**）。
 *   · **Blink / ICU 的管道位置**：段落级 bidi → 按 run 整形 → 断行 → 行级重排。
 *     排版层（text-layout.ts）照这个顺序接，所以是"段落先算、行后重排"。
 *   · 验收方式也照抄业界：**Unicode 官方 conformance 语料**（vendor/bidi/，见那边
 *     README 的来源与 sha256），不是本项目自己想的用例。
 *
 * ---- 实现要点（每条都是 conformance 红过之后才钉住的，别顺手"优化"掉）----
 *   ① X 栈项存**内容级**（新 level），不是"进入前的级"：PDF/PDI 弹出后取弹后栈顶，
 *      initiator/PDI 自身取栈顶（= 外层）。存错一层的症状是每层嵌入差 1，
 *      只在"嵌了又弹"的用例里出现。
 *   ② isolate initiator 与 PDI 落在 LRO/RLO 覆盖下时，**自身的类型**也要改写成
 *      L/R（X5a 步骤 2 / X6a 末步 "in all cases"）。不改写它们会被当普通中性字符
 *      走 N1、再被 I 阶段抬一级 —— 症状是"RLO 里的 LRI 高了一级"。
 *   ③ 溢出分两种计数（X2–X5 的 overflow embedding、X5a 的 overflow isolate）：
 *      embedding 溢出只在 **isolate 溢出为 0 时**才累计（X2 步骤 3 原文），
 *      否则末尾的 PDF 会多弹或少弹一层，末字符级别差 1。
 *   ④ BD13 的序列并接是**跳接**：initiator 的序列接着"以匹配 PDI 开头的那个 run"，
 *      中间隔着的 run 自成一序（不是"把相邻 run 接上"）。而且并接判定要用
 *      **建 run 时固化的 PDI 标志** —— N1 会把 PDI 改写成 L/R，事后看类型认不出来，
 *      同一个 run 会被两个序列各处理一遍（AN/EN 被 I 阶段连加两次：want 2 got 4）。
 *   ⑤ N0 的括号对按 **open 的逻辑顺序**处理，且上下文扫描读的是**已被前面括号对
 *      改写过的** types（顺序有语义：先处理外层对会让内层对的前文强类型变掉）；
 *      BD16 栈满（63）是**停止本序列后续配对**，不是"跳过这个 open 继续"。
 *   ⑥ sos/eos 一律读 **I 阶段改写前的级别快照**（TR9 X10 注 "before any changes"）；
 *      序列末是悬空 isolate initiator 时 eos 直接与段落级比、不往后扫。
 *   ⑦ L1 的"行尾链"不只是 WS/BN：WS + **隔离格式字符**（LRI/RLI/FSI/PDI）+ BN 类
 *      控制符都算（裸 `LRE LRI` 的期望 `x 0` 就来自这里）；判定要用**原始类**，
 *      因为 N1 会把 S/WS 改写成 L/R。
 *   ⑧ L2 必须从最高级**逐级降到最低奇级（含中间没出现过的级别）**，只对
 *      "出现过的级别"循环会漏掉嵌套反转。
 *
 * 三层 API（每层都可以单独判据）：
 *   ① bidiClassOf / mirroredOf / bracketPairOf —— 数据表查询（bidi-tables.ts）；
 *   ② paragraphLevelFromTypes / levelsFromTypes / reorderLine —— **类型序列**进出，
 *      与码点无关（conformance 语料就是类型序列）；
 *   ③ embeddingLevels / reorder —— **码点数组**进出（排版层的消费口）。
 *
 * ★「移除字符」的约定（X9）：LRE/RLE/LRO/RLO/PDF/BN 这 7 类在算法的其余部分
 *   "当作不存在"；本实现不物理删除它们 —— levels 数组与输入一一对应，它们的
 *   槽位在 reorderLine 的输出里是 -1（没有视觉位置）。isolate 控制符（LRI/RLI/
 *   FSI/PDI）**不**被移除（X9 原文明确），它们有 level、参与 N1，只是宽度为零。
 */

import {
  BIDI_CLASS_NAMES,
  TYPE_RANGES_B64,
  MIRROR_PAIRS_B64,
  BRACKET_PAIRS_B64,
} from "./bidi-tables.ts";

/** Bidi_Class 的字节值（= BIDI_CLASS_NAMES 的下标）。 */
export const BC = Object.fromEntries(BIDI_CLASS_NAMES.map((n, i) => [n, i])) as Readonly<
  Record<(typeof BIDI_CLASS_NAMES)[number], number>
>;

// ---- 表加载（base64 → Uint32Array） ----

function u32FromB64(b64: string): Uint32Array {
  const bin = atob(b64);
  const out = new Uint32Array(bin.length >> 2);
  for (let i = 0; i < out.length; i++) {
    const a = bin.charCodeAt(i * 4)!;
    const b = bin.charCodeAt(i * 4 + 1)!;
    const c = bin.charCodeAt(i * 4 + 2)!;
    const d = bin.charCodeAt(i * 4 + 3)!;
    out[i] = ((a | (b << 8) | (c << 16) | (d << 24)) >>> 0);
  }
  return out;
}

const TYPE_RANGES = u32FromB64(TYPE_RANGES_B64); // [start, end, cls] × N
const MIRROR_PAIRS = u32FromB64(MIRROR_PAIRS_B64); // [src, dst] × N（src 升序）
const BRACKET_PAIRS = u32FromB64(BRACKET_PAIRS_B64); // [open, close] × N

/** 一个码点的 Bidi_Class（二分查范围表；表无缝覆盖全 Unicode，必有命中）。 */
export function bidiClassOf(code: number): number {
  let lo = 0;
  let hi = TYPE_RANGES.length / 3 - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const start = TYPE_RANGES[mid * 3]!;
    const end = TYPE_RANGES[mid * 3 + 1]!;
    if (code < start) hi = mid - 1;
    else if (code > end) lo = mid + 1;
    else return TYPE_RANGES[mid * 3 + 2]!;
  }
  return BC.BN; // 不可达（生成器保证无缝覆盖）；BN 是最安全的回落
}

/** M1/L4 的镜像映射：返回镜像码点；没有镜像关系的字符返回 undefined。 */
export function mirroredOf(code: number): number | undefined {
  let lo = 0;
  let hi = MIRROR_PAIRS.length / 2 - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const src = MIRROR_PAIRS[mid * 2]!;
    if (code < src) hi = mid - 1;
    else if (code > src) lo = mid + 1;
    else return MIRROR_PAIRS[mid * 2 + 1]!;
  }
  return undefined;
}

/** N0 的括号信息：open 括号给 close，close 括号给 open，其余 undefined。 */
export function bracketPairOf(code: number): number | undefined {
  // 表只有 65 对，线性够了；挂在 module 顶层缓存二分也行，但先量后优
  for (let i = 0; i < BRACKET_PAIRS.length; i += 2) {
    if (BRACKET_PAIRS[i] === code) return BRACKET_PAIRS[i + 1]!;
    if (BRACKET_PAIRS[i + 1] === code) return BRACKET_PAIRS[i]!;
  }
  return undefined;
}

// ---- ② 类型序列 API（conformance 语料的进出形状） ----

export type ParaDir = "auto" | "ltr" | "rtl";

/** 被 X9 移除的类（重排时没有视觉位置）。isolate 控制符不在其中。 */
function isRemoved(t: number): boolean {
  return (
    t === BC.LRE || t === BC.RLE || t === BC.LRO || t === BC.RLO || t === BC.PDF || t === BC.BN
  );
}
function isIsolate(t: number): boolean {
  return t === BC.LRI || t === BC.RLI || t === BC.FSI;
}

/**
 * P2/P3：段落级别。base 为 "auto" 时按首个强类型判定（跳过 isolate 内容），
 * 找不到强类型落 LTR（P3 的兜底）；显式 ltr/rtl 直接给 0/1。
 */
export function paragraphLevelFromTypes(types: readonly number[], base: ParaDir): 0 | 1 {
  if (base === "ltr") return 0;
  if (base === "rtl") return 1;
  // P2：从段首找第一个强类型；isolate 的内容不算（depth 计数）
  let depth = 0;
  for (let i = 0; i < types.length; i++) {
    const t = types[i]!;
    if (isIsolate(t)) {
      depth++;
      continue;
    }
    if (t === BC.PDI) {
      // 未配对的 PDI（不属于任何 isolate）：它本身不是强类型，跳过继续找
      if (depth === 0) continue;
      depth--;
      continue;
    }
    if (depth > 0) continue; // isolate 内容里的强类型不作数
    if (t === BC.L) return 0;
    if (t === BC.R || t === BC.AL) return 1;
  }
  return 0;
}

/** FSI 的 X5c：对"FSI 与匹配 PDI 之间"的内容按 P2/P3 判定（如同独立段落）。 */
function fsiLevelOf(types: Uint8Array | readonly number[], fsiIdx: number): 0 | 1 {
  let depth = 0;
  for (let i = fsiIdx + 1; i < types.length; i++) {
    const t = types[i]!;
    if (isIsolate(t)) {
      depth++;
      continue;
    }
    if (t === BC.PDI) {
      if (depth === 0) break; // 这就是与 FSI 匹配的 PDI
      depth--;
      continue;
    }
    if (depth > 0) continue;
    if (t === BC.L) return 0;
    if (t === BC.R || t === BC.AL) return 1;
  }
  return 0;
}

/** 最低的 greater-even/odd level（X2/X3/X5a/X5b 的「least odd/even greater」）。 */
function leastGreater(level: number, wantEven: boolean): number {
  return wantEven ? (level & 1) === 0 ? level + 2 : level + 1 : (level & 1) === 1 ? level + 2 : level + 1;
}

const MAX_DEPTH = 125; // BD12：isolate/embedding 的有效上限

/** N0 输入：每个位置的可选括号配对（codes 路径由 bracketPairOf 生成）。 */
export type BracketInfo = readonly (number | undefined)[];

/**
 * X1–I2：给每个码点定 embedding level（在 types 上就地解析 W/N/I —— 所以收副本）。
 *
 * brackets 传了才跑 N0（BidiTest 语料没有码点 → 没有括号信息 → 正确地跳过 N0；
 * BidiCharacterTest / 排版层传真实配对表）。
 * 返回 levels；同时把「N 阶段后的类型」写进 outTypes（重排/镜像要用最终方向）。
 */
export function levelsFromTypes(
  inputTypes: readonly number[],
  paraLevel: 0 | 1,
  brackets?: BracketInfo,
  codes?: readonly number[],
): { levels: Uint8Array; types: Uint8Array; rawTypes: Uint8Array } {
  const n = inputTypes.length;
  const types = Uint8Array.from(inputTypes); // X6 override 会改写；originalTypes 另存
  const originalTypes = Uint8Array.from(inputTypes); // N0d 要"W1 之前的 NSM"；L1 要原始 S/WS/BN 类
  const levels = new Uint8Array(n);

  // ---- X1–X8：方向状态栈 ----
  // ★ 栈项存的是**该项作用域的内容级**（新 level），不是「进入前的 level」——
  //   这与 bidi-js / 官方 conformance 一致：PDF/PDI 弹出后恢复到的是"弹后栈顶
  //   的内容级"，initiator/PDI 自身的 level 也是"栈顶的内容级"。
  //   用「进入前 level」做栈项的话，PDF 之后的 level 会比正确值低一层
  //   （实测官方语料 `RLE a LRE b PDF LRI c PDI` 期望 LRI=1、PDI=1、c=2）。
  const stackLev: number[] = [];
  const stackOvr: number[] = []; // 0 中性 / 1 L / 2 R
  const stackIso: boolean[] = [];
  const matchIso = new Int32Array(n).fill(-1); // PDI → 它匹配的 isolate initiator 下标
  stackLev.push(paraLevel); // X1：隐式底项（paraLevel）
  stackOvr.push(0);
  stackIso.push(false);
  let level: number = paraLevel; // 恒等于栈顶的内容级
  let ovr = 0;
  let overflowIso = 0;
  let overflowEmbed = 0;
  const openIsolates: number[] = []; // 未配对的 isolate initiator 下标（用于 matchIso）

  for (let i = 0; i < n; i++) {
    const t = types[i]!;
    switch (t) {
      case BC.LRE:
      case BC.RLE: {
        levels[i] = level;
        const next = leastGreater(level, t === BC.LRE);
        if (next <= MAX_DEPTH && overflowIso === 0 && overflowEmbed === 0) {
          stackLev.push(next);
          stackOvr.push(0); // X2/X3：新栈项 override 重置为中性
          stackIso.push(false);
          level = next;
          ovr = 0;
        } else if (overflowIso === 0) overflowEmbed++; // X2 步骤 3：isolate 溢出期间不累计
        break;
      }
      case BC.LRO:
      case BC.RLO: {
        levels[i] = level;
        const next = leastGreater(level, t === BC.LRO);
        if (next <= MAX_DEPTH && overflowIso === 0 && overflowEmbed === 0) {
          stackLev.push(next);
          stackOvr.push(t === BC.LRO ? 1 : 2);
          stackIso.push(false);
          level = next;
          ovr = t === BC.LRO ? 1 : 2;
        } else if (overflowIso === 0) overflowEmbed++; // X4 步骤 3：同上
        break;
      }
      case BC.PDF: {
        // X7：弹出最近一个 embedding（isolate 项挡住不许穿过）；
        // level 恢复为弹后栈顶的内容级
        if (overflowIso === 0) {
          if (overflowEmbed > 0) overflowEmbed--;
          else if (!stackIso[stackIso.length - 1]! && stackLev.length > 1) {
            stackLev.pop();
            stackOvr.pop();
            stackIso.pop();
            level = stackLev[stackLev.length - 1]!;
            ovr = stackOvr[stackOvr.length - 1]!;
          }
        }
        levels[i] = level;
        break;
      }
      case BC.LRI:
      case BC.RLI:
      case BC.FSI: {
        const wantEven =
          t === BC.LRI || (t === BC.FSI && fsiLevelOf(types, i) === 0);
        levels[i] = level; // initiator 本身 = 外层内容级（X5a/X5b/X5c 步骤 1）
        // X5a 步骤 2：外层 override 非中性时，**isolate initiator 自身的类型**
        // 也要被重置为 L/R（TR9 原文："reset the current character type from
        // RLI to L/R"）—— 重写后它不再是 NI，N1 不再解析它、I 阶段不再 +1。
        // （实测官方语料 `LRO א RLE ב PDF RLI ג PDI …`：RLI 在 LRO 覆盖下被改写成 L。）
        if (ovr === 1) types[i] = BC.L;
        else if (ovr === 2) types[i] = BC.R;
        const next = leastGreater(level, wantEven);
        if (next <= MAX_DEPTH && overflowIso === 0 && overflowEmbed === 0) {
          stackLev.push(next);
          stackOvr.push(0);
          stackIso.push(true);
          level = next;
          ovr = 0;
          openIsolates.push(i);
        } else overflowIso++;
        break;
      }
      case BC.PDI: {
        // X6a：先按规则弹出（overflow 递减 / 一直弹到 isolate 项被弹掉），
        // 然后 PDI 的 level = **弹后栈顶的内容级**（= 它匹配的 initiator 的 level）
        if (overflowIso > 0) {
          overflowIso--;
        } else if (openIsolates.length > 0) {
          const open = openIsolates.pop()!;
          matchIso[i] = open;
          overflowEmbed = 0; // X6a 步骤 3：配对成功时把 embedding 溢出计数清零
          while (stackLev.length > 1) {
            const iso = stackIso.pop()!;
            stackOvr.pop();
            stackLev.pop();
            if (iso) break;
          }
        }
        level = stackLev[stackLev.length - 1]!;
        ovr = stackOvr[stackOvr.length - 1]!;
        levels[i] = level;
        // X6a 末步（"In all cases"）：弹栈后的栈顶 override 非中性时，PDI 自身
        // 的类型同样被重置为 L/R —— 与其匹配 initiator 的改写规则对称。
        if (ovr === 1) types[i] = BC.L;
        else if (ovr === 2) types[i] = BC.R;
        break;
      }
      case BC.B: {
        // X8：段落分隔符 = 段落级，并且"终止一切"（本实现按段切好进来，
        // 语料里的 B 按此处理：重置状态机 —— 与 bidiref 的行为一致）。
        levels[i] = paraLevel;
        stackLev.length = 0;
        stackOvr.length = 0;
        stackIso.length = 0;
        openIsolates.length = 0;
        overflowIso = 0;
        overflowEmbed = 0;
        stackLev.push(paraLevel);
        stackOvr.push(0);
        stackIso.push(false);
        level = paraLevel;
        ovr = 0;
        break;
      }
      default: {
        levels[i] = level; // X6 / X8(S)
        // X6：override 改写类型，**但 BN 除外** —— BN 是 X9 移除类，改写成 L/R
        // 会让 reorder 的 isRemoved 判定失效（bidi-js 同款注记：为过测试）
        if (t !== BC.BN) {
          if (ovr === 1) types[i] = BC.L;
          else if (ovr === 2) types[i] = BC.R;
        }
      }
    }
  }

  // ---- X10：isolating run sequences（BD13）+ sos/eos ----
  // 成员 = 非 X9 移除字符（isolate 控制符算成员）。level 相同的连续成员是同一段 run；
  // PDI 把它所在的 run 接到匹配 initiator 所在的 sequence 尾上。
  // ★ levels0 = I1/I2 改写**前**的级别快照：TR9 X10 注明 sos/eos "must use the
  //   embedding levels assigned by the rules above, before any changes are made
  //   to them in the steps below"。sos/eos 在各 sequence 解析时才计算，而排在
  //   前面的 sequence 的 I 阶段已经就地改过 levels（实测 line161
  //   `א LRE ב PDF ␣1 ␣2`：ב 被 I1 提到 3，后面 WS 序列的 sos 若读现值会算成
  //   R，官方期望 L）—— 一律读快照。
  const levels0 = Uint8Array.from(levels);
  {
    // ---- BD13：先切 level run，再跳接 ----
    // ★ 并接是「run 末字符是 isolate initiator 时，**跳到以它匹配的 PDI 开头的
    //   那个 run**」，中间隔着的 run **不并入**（它们自成 sequence）——
    //   BD13 原文 "whose matching PDI is the first character of the next level
    //   run **in the sequence**"（是"序列里的下一个 run"，不是"文本里的下一个
    //   run"）。实测 `RLI ES PDI EN`（ltr）：正确序列是 [RLI,PDI,EN] + [ES]，
    //   若按相邻并接会把 ES 卷进 RLI 的序列，ES 的 N1 就错了（官方 ES=1）。
    //   已被跳接消费的「以匹配 PDI 开头的 run」不再作为新序列起点（bidi-js
    //   同款：`run._startsWithPDI && isolationPairs.has(run._start)` 则跳过）。
    const runs: number[][] = [];
    const runStartsWithPdi: boolean[] = []; // ★ 建仓时固化（N1 会把 PDI 重写成 L/R）
    {
      let cur: number[] = [];
      let curLv = -1;
      for (let i = 0; i < n; i++) {
        if (isRemoved(types[i]!)) continue;
        if (cur.length > 0 && levels0[i]! !== curLv) {
          runs.push(cur);
          runStartsWithPdi.push(types[cur[0]!] === BC.PDI);
          cur = [];
        }
        if (cur.length === 0) curLv = levels0[i]!;
        cur.push(i);
      }
      if (cur.length > 0) {
        runs.push(cur);
        runStartsWithPdi.push(types[cur[0]!] === BC.PDI);
      }
    }
    // initiator → 匹配 PDI（matchIso 是 PDI → initiator，反转一份）
    const isoPdi = new Map<number, number>();
    for (let i = 0; i < n; i++) if (matchIso[i]! >= 0) isoPdi.set(matchIso[i]!, i);
    // run 首字符下标 → run 序号（跳接寻址用）
    const runByStart = new Map<number, number>();
    runs.forEach((r, ri) => runByStart.set(r[0]!, ri));
    for (let ri = 0; ri < runs.length; ri++) {
      const run = runs[ri]!;
      // 以匹配 PDI 开头的 run 已被其 initiator 的序列跳接消费掉
      //（★ 判定用建仓时固化的标志：resolveSequence 的 N1 会把 PDI 重写成
      //  L/R，事后看 types[head] 就认不出它是 PDI，同一 run 会被第二个序列
      //  再处理一遍 —— AN/EN 被 I 阶段连加两次（实测 want 2 got 4）。）
      if (runStartsWithPdi[ri] && matchIso[run[0]!]! >= 0) continue;
      const seq: number[] = [...run];
      for (;;) {
        const lastChar = seq[seq.length - 1]!;
        if (!isIsolate(types[lastChar]!)) break;
        const pdi = isoPdi.get(lastChar);
        if (pdi === undefined) break; // 悬空 initiator：序列到此为止（eos=段落级）
        const target = runByStart.get(pdi);
        if (target === undefined) break; // 空 isolate（PDI 与 initiator 同 run）：已在一起
        seq.push(...runs[target]!);
      }
      resolveSequence(seq, levels0[seq[0]!]!);
    }
  }

  /** 对一个 isolating run sequence 跑 W1–W7、N0–N2、I1–I2。 */
  function resolveSequence(seq: readonly number[], _runLevel: number): void {
    if (seq.length === 0) return;
    // sos/eos：与序列外邻接字符（跳过移除字符）的 level 取较高者，奇 → R。
    // ★ 读 levels0（I 改写前快照），见上。
    const dirOfLevel = (lv: number): number => ((lv & 1) === 1 ? BC.R : BC.L);
    const first = seq[0]!;
    const last = seq[seq.length - 1]!;
    let prevLv: number = paraLevel;
    for (let i = first - 1; i >= 0; i--) {
      if (isRemoved(types[i]!)) continue;
      prevLv = levels0[i]!;
      break;
    }
    const sos = dirOfLevel(Math.max(levels0[first]!, prevLv));
    // eos：与后一个非移除字符比。★ 序列末是 isolate initiator 时不往后扫，
    // 直接与**段落级**比（TR9 X10："or the last character of the sequence is
    // an isolate initiator, with the paragraph embedding level"；BD13 极大性
    // 保证「序列末是 initiator」⇔ 它悬空无匹配 PDI —— 有匹配 PDI 的话那个
    // PDI 的 run 已并进本序列，末字符就不是 initiator 了。bidi-js 同款：
    // `if (!(charTypes[lastIndex] & ISOLATE_INIT_TYPES))` 才往后扫）。
    let nextLv: number = paraLevel;
    if (!isIsolate(types[last]!)) {
      for (let i = last + 1; i < n; i++) {
        if (isRemoved(types[i]!)) continue;
        nextLv = levels0[i]!;
        break;
      }
    }
    const eos = dirOfLevel(Math.max(levels0[last]!, nextLv));

    // ---- W1–W7（弱类型）----
    // W1：NSM 跟前一字符；前面是 isolate initiator / PDI → ON；序列首 → sos
    {
      let prevT = sos;
      let prevIsIso = false;
      for (const i of seq) {
        const t = types[i]!;
        if (t === BC.NSM) types[i] = prevIsIso ? BC.ON : prevT;
        prevIsIso = isIsolate(t) || t === BC.PDI;
        prevT = types[i]!;
      }
    }
    // W2：EN → AN，如果序列里它之前最近的强类型是 AL（从 sos 起）
    {
      let strong = sos; // sos ∈ {L, R}，不是 AL
      for (const i of seq) {
        const t = types[i]!;
        if (t === BC.EN && strong === BC.AL) types[i] = BC.AN;
        if (t === BC.L || t === BC.R || t === BC.AL) strong = t;
      }
    }
    // W3：AL → R
    for (const i of seq) if (types[i] === BC.AL) types[i] = BC.R;
    // W4：ES 夹在 EN…EN → EN；CS 夹在 EN…EN → EN；CS 夹在 AN…AN → AN
    for (let k = 1; k < seq.length - 1; k++) {
      const i = seq[k]!;
      const t = types[i]!;
      if (t !== BC.ES && t !== BC.CS) continue;
      const a = types[seq[k - 1]!]!;
      const b = types[seq[k + 1]!]!;
      if (t === BC.ES && a === BC.EN && b === BC.EN) types[i] = BC.EN;
      else if (t === BC.CS && a === BC.EN && b === BC.EN) types[i] = BC.EN;
      else if (t === BC.CS && a === BC.AN && b === BC.AN) types[i] = BC.AN;
    }
    // W5：ET 序列贴着 EN（一侧即可）→ 整串 ET 变 EN
    {
      let runStart = -1;
      for (let k = 0; k <= seq.length; k++) {
        const i = seq[k];
        const isEt = i !== undefined && types[i] === BC.ET;
        if (isEt && runStart < 0) runStart = k;
        if (!isEt && runStart >= 0) {
          const before = seq[runStart - 1];
          const after = i;
          const adjEn =
            (before !== undefined && types[before] === BC.EN) ||
            (after !== undefined && types[after] === BC.EN);
          if (adjEn) for (let j = runStart; j < k; j++) types[seq[j]!] = BC.EN;
          runStart = -1;
        }
      }
    }
    // W6：剩下的 ES/ET/CS → ON
    for (const i of seq) {
      const t = types[i]!;
      if (t === BC.ES || t === BC.ET || t === BC.CS) types[i] = BC.ON;
    }
    // W7：EN → L，如果它之前最近的强类型是 L（从 sos 起）
    {
      let strong = sos;
      for (const i of seq) {
        const t = types[i]!;
        if (t === BC.EN && strong === BC.L) types[i] = BC.L;
        if (t === BC.L || t === BC.R) strong = t;
      }
    }

    // ---- N0（括号对）----
    if (brackets !== undefined) resolveBrackets(seq, sos);

    // ---- N1 / N2（中性类型）----
    {
      const isNi = (t: number): boolean =>
        t === BC.ON || t === BC.WS || t === BC.S || t === BC.B || isIsolate(t) || t === BC.PDI;
      const strongAsR = (t: number): number =>
        t === BC.R || t === BC.EN || t === BC.AN ? BC.R : t === BC.L ? BC.L : BC.ON;
      let k = 0;
      while (k < seq.length) {
        if (!isNi(types[seq[k]!]!)) {
          k++;
          continue;
        }
        let e = k;
        while (e < seq.length && isNi(types[seq[e]!]!)) e++;
        // 段前强类型：k-1 往回，跨到 sos（段前没找到就是 sos）
        let pre = BC.ON;
        for (let j = k - 1; j >= 0; j--) {
          const t = strongAsR(types[seq[j]!]!);
          if (t !== BC.ON) {
            pre = t;
            break;
          }
        }
        if (pre === BC.ON) pre = sos; // sos ∈ {L, R}
        // 段后强类型：e 往后，跨到 eos（后面没找到就是 eos）
        let post = BC.ON;
        for (let j = e; j < seq.length; j++) {
          const t = strongAsR(types[seq[j]!]!);
          if (t !== BC.ON) {
            post = t;
            break;
          }
        }
        if (post === BC.ON) post = eos;
        // N2：两侧方向不一致时取**嵌入方向**（序列首字符级别的奇偶），不是 eos
        // （TR9 N2 原文 "Any remaining NIs take the embedding direction"；
        //   bidi-js 同款 `prevType === nextType ? prevType : embedDirection`）。
        const embedDir = dirOfLevel(levels0[first]!);
        const resolved = pre === post && pre !== BC.ON ? pre : embedDir;
        for (let j = k; j < e; j++) types[seq[j]!] = resolved;
        k = e;
      }
    }

    // ---- I1 / I2（隐式级别）----
    // ★ isolate 控制符与 PDI **参与** I1/I2：X 阶段它们拿外层级（X5a/X6a），
    //   之后作为「隐形中性字符」走完整流程（TR9 BD9 注）—— N1 把它们解析成
    //   两侧方向，I1/I2 再按类型调 level。实测官方语料："א LRI LRE PDI ב"（ltr）
    //   期望 LRI/PDI = 1 = 外层 0 + I1 的 +1，与 bidi-js 一致。
    for (const i of seq) {
      const lv = levels[i]!;
      const t = types[i]!;
      if ((lv & 1) === 0) {
        // I1（偶）：R +1；AN/EN +2；L 不变
        if (t === BC.R) levels[i] = lv + 1;
        else if (t === BC.AN || t === BC.EN) levels[i] = lv + 2;
      } else {
        // I2（奇）：L/AN/EN +1；R 不变
        if (t === BC.L || t === BC.AN || t === BC.EN) levels[i] = lv + 1;
      }
    }
  }

  /** N0 / BD16：括号配对与方向（只在实际有码点信息的路径上被调用）。 */
  function resolveBrackets(seq: readonly number[], sos: number): void {
    if (brackets === undefined || codes === undefined) return;
    // BD16：栈式配对。open 压栈；close 从栈顶往下找配对（open 的 pair == 该 close
    // 的**码点**），找到即成对、比它晚入栈的一起作废；找不到则该 close 忽略。
    // ★ 括号参与资格按 **X6 之后的 current type**（TR9 注明）：
    //   被 override 改写成 L/R 的括号不再算 NI，不参与配对。
    const pairs: Array<[number, number]> = []; // [openPos(seq 内下标), closePos]
    const stack: number[] = []; // seq 内下标
    for (let k = 0; k < seq.length; k++) {
      const i = seq[k]!;
      const t = types[i]!;
      if (t === BC.L || t === BC.R) continue; // 被 override 的括号出局
      if (brackets[i] === undefined) continue;
      if (bracketIsOpen(codes[i]!)) {
        // BD16：栈满（63）→ **停止本序列后续全部配对**（TR9 原文 "stop
        // processing BD16 for the remainder of the isolating run sequence"；
        // bidi-js 同样 `else break`）—— 不是"忽略这次 open 继续"。
        if (stack.length >= 63) break;
        stack.push(k);
      } else {
        let found = -1;
        const wantClose = codes[i]!;
        for (let s = stack.length - 1; s >= 0; s--) {
          const oi = seq[stack[s]!]!;
          // 配对判定用**规范等价**后的码点（BD16 注：U+2329/U+3008、U+232A/U+3009）
          if (canonBracket(brackets[oi]!) === canonBracket(wantClose)) {
            found = s;
            break;
          }
        }
        if (found >= 0) {
          const oi = stack[found]!;
          stack.length = found;
          pairs.push([oi, k]);
        }
      }
    }
    // 处理顺序：按 open 的**逻辑顺序**（TR9 N0 首句 "sequentially in the logical
    // order of the text positions of the opening paired brackets"）。
    // ★ 这一步不能省：N0 的上下文扫描读的是**已被前面括号对改写过的** types，
    //   先处理哪个对会改变后一个对的结论（line 185：`)` 对先被外层对改成 R，
    //   内层对的前文强类型就变成 R 而不是更前面的 L）。push 顺序是 close 序。
    pairs.sort((a, b) => a[0] - b[0]);
    for (const [ko, kc] of pairs) {
      const io = seq[ko]!;
      const ic = seq[kc]!;
      // 上下文强类型（EN/AN 计 R，TR9 N0 明确）
      const strongDir = (t: number): number =>
        t === BC.L ? BC.L : t === BC.R || t === BC.EN || t === BC.AN ? BC.R : BC.ON;
      const embedDir = (levels[io]! & 1) === 1 ? BC.R : BC.L;
      // ① 括号内的强类型：★ TR9 N0 步骤 2 的条件是「**存在**与嵌入方向一致的
      //   强类型」就取嵌入方向（N0b）—— 不是"第一个强类型一致"：
      //   "א(ג…ef)…" 里 ג(R) 在前、e(L) 在后，嵌入方向 L 时括号仍取 L。
      //   只有"存在强类型且全部与嵌入方向相反"才走 N0c。
      let matching = false; // 有与嵌入方向一致的强类型
      let opposite = false; // 有相反的强类型
      for (let k = ko + 1; k < kc; k++) {
        const d = strongDir(types[seq[k]!]!);
        if (d === BC.ON) continue;
        if (d === embedDir) {
          matching = true;
          break;
        }
        opposite = true;
      }
      if (matching) {
        // N0b：括号取嵌入方向
        types[io] = embedDir;
        types[ic] = embedDir;
      } else if (opposite) {
        // N0c：括号内强类型全部与嵌入方向相反 → 看 open 之前最近强类型
        //   （到 sos 为止，EN/AN 计 R）。
        //   步骤 3.1：前文强类型「也与嵌入方向相反」→ 括号取前文方向；
        //   步骤 3.2：否则取嵌入方向。
        let pre = BC.ON;
        for (let k = ko - 1; k >= 0; k--) {
          const d = strongDir(types[seq[k]!]!);
          if (d !== BC.ON) {
            pre = d;
            break;
          }
        }
        if (pre === BC.ON) pre = sos; // sos ∈ {L, R}
        // pre 只可能 ∈ {L, R}：pre 与嵌入方向相反（= 步骤 3.1 的"也相反"）→ 取 pre；
        // pre 与嵌入方向一致 → 取嵌入方向（步骤 3.2）
        types[io] = pre === embedDir ? embedDir : pre;
        types[ic] = types[io]!;
      }
      // ④ 括号内无强类型 → 不设置（保持 ON）
      // N0d：紧跟括号（且 W1 之前就是 NSM）的字符跟着括号走。
      //   「紧跟」要**跳过 X9 移除字符**（BN 类如 ZWJ 夹在中间时 NSM 仍算紧跟）
      for (const j0 of [io + 1, ic + 1]) {
        for (let j = j0; j < n; j++) {
          if (isRemoved(types[j]!)) continue; // BN/控制符不是 NSM，越过它继续找
          if (originalTypes[j] !== BC.NSM) break;
          types[j] = types[io]!;
        }
      }
    }
  }

  return { levels, types, rawTypes: originalTypes };
}

/** 这个码点是不是表里的 open 括号（BRACKET_PAIRS 只存 [open, close]）。 */
function bracketIsOpen(code: number): boolean {
  for (let b = 0; b < BRACKET_PAIRS.length; b += 2) if (BRACKET_PAIRS[b] === code) return true;
  return false;
}

/**
 * BD16 的括号配对要用**规范等价**：U+2329/U+232A（角括号）与 U+3008/U+3009
 * 在 Unicode 里互为规范等价，`⟨` 可以被 `〉` 配平。BidiBrackets.txt 的配对表
 * 只按码点给，所以这里把角括号规范到 CJK 一侧再比。
 */
function canonBracket(code: number): number {
  if (code === 0x2329) return 0x3008;
  if (code === 0x232a) return 0x3009;
  return code;
}

// ---- L1 + L2：一行的视觉重排 ----

/**
 * L1（就地修改 levels）：把**行内**的下列字符重置为段落级 ——
 *   ① 段分隔符（S）② 行分隔符（B）
 *   ③④ S/B 前面或行尾的「WS + isolate 格式字符（LRI/RLI/FSI/PDI）」连续链。
 *
 * ★ TR9 L1 规则 3/4 的重置链**不只是 WS/BN** —— 「any sequence of whitespace
 *   characters **or isolate formatting characters**」也包含在内（bidi-js 的
 *   TRAILING_TYPES = S|WS|B|LRI/RLI/FSI|PDI|BN+嵌入控制符）。裸 `LRE LRI`
 *   期望 `x 0` 的 0 就是这里给的：LRI 在行尾，被重置回段落级。
 *   （BN 与 LRE/RLE/LRO/RLO/PDF 是 X9 移除类，不在 members 里，官方期望标 x，
 *   bidi-js 会一并重置 —— 不可见的级别，这里跳过不影响比对与视觉序。）
 * ★ 官方 conformance 期望的 levels 是**含 L1 的**（BidiTest 期望 `LRE S` 给
 *   `x 0`：S 在 L1 里回到段落级，哪怕它在 LRE 嵌入的 level 2 里）——
 *   所以「整段 = 一行」的 conformance 比对也要过这一步，而不是只比 I2 的产物。
 * members 是行内非 X9 移除字符的下标（S/B/WS/LRI/RLI/FSI/PDI 都不是移除类，
 * 都在里面）。
 */
function isL1ChainType(t: number): boolean {
  return (
    t === BC.WS ||
    t === BC.BN ||
    t === BC.LRE ||
    t === BC.RLE ||
    t === BC.LRO ||
    t === BC.RLO ||
    t === BC.PDF ||
    t === BC.LRI ||
    t === BC.RLI ||
    t === BC.FSI ||
    t === BC.PDI
  );
}
export function applyL1(
  types: ArrayLike<number>,
  levels: Uint8Array,
  members: readonly number[],
  paraLevel: 0 | 1,
): void {
  let i = members.length - 1;
  // ④ 行尾连续 WS / isolate 格式字符
  while (i >= 0) {
    const t = types[members[i]!]!;
    if (isL1ChainType(t)) {
      levels[members[i]!] = paraLevel;
      i--;
    } else break;
  }
  // ①②③ S/B 与它们前面的 WS / isolate 格式字符链
  while (i >= 0) {
    const t = types[members[i]!]!;
    if (t === BC.S || t === BC.B) {
      levels[members[i]!] = paraLevel;
      i--;
      while (i >= 0) {
        const t2 = types[members[i]!]!;
        if (isL1ChainType(t2)) {
          levels[members[i]!] = paraLevel;
          i--;
        } else break;
      }
      continue;
    }
    i--;
  }
}

/**
 * L1 + L2：把 [start, end) 这一行变成 visual → logical 映射。
 *
 * 返回长度 `end - start` 的 Int32Array：第 v 位是"视觉第 v 个字符"的逻辑下标；
 * 被 X9 移除的字符没有视觉位置，对应位是 -1（调用方跳过即可）。
 *
 * ★ rawTypes：**X/W/N 改写前**的原始 bidi 类（levelsFromTypes 的 rawTypes 返回值）。
 *   L1 的重置对象（S/B/WS/isolate 格式字符/BN）按原始类判定 —— N1 会把 S/WS
 *   解析成 L/R，若看解析后的 types 就认不出「这曾经是 S」（bidi-js 的 L1 用
 *   getBidiCharType(string[i])，即原始类；实测 line255 `١ tab ( ٢ )`：tab want 0）。
 *   缺省时退回 types（调用方保证没有 N1 改写过的 S/WS 时才可省）。
 *
 * ★ L2 必须**从最高 level 逐级降到最低奇 level（含没出现过的中间级别）**，
 *   每级反转所有 `level >= 当前级` 的连续段 —— 只对"出现过的 level"循环是错的
 *   （中间缺失的级别会漏反转，官方 bidiref 与 ICU 都按全范围循环）。
 */
export function reorderLine(
  types: ArrayLike<number>,
  levelsIn: ArrayLike<number>,
  start: number,
  end: number,
  paraLevel: 0 | 1,
  rawTypes?: ArrayLike<number>,
): Int32Array {
  const len = end - start;
  const map = new Int32Array(len).fill(-1);
  const l1Types = rawTypes ?? types;
  // L1 要把行尾 WS/S/BN 的 level 重置成段落级 —— 只作用于**本行**，不改调用方的数组
  const levels = Uint8Array.from(levelsIn);
  const members: number[] = []; // 非移除字符的（行内）下标
  for (let i = start; i < end; i++) {
    // ★ 移除判定读**原始类**：X6 的 override 不改写 BN（早已修过），但
    //   N 系列会把 S/WS 改写成 L/R —— 移除类本身不是中性字符，理论上不会被
    //   改写；用 rawTypes 是为了让"能不能看见"这件事只由输入决定。
    if (!isRemoved(l1Types[i]!)) members.push(i);
  }
  if (members.length === 0) return map;

  // ---- L1 ----
  applyL1(l1Types, levels, members, paraLevel);

  // ---- L2：逐级反转 ----
  let maxLevel = 0;
  for (const i of members) if (levels[i]! > maxLevel) maxLevel = levels[i]!;
  const minOdd = (paraLevel & 1) === 1 ? paraLevel : paraLevel + 1;
  // visual 初始 = 逻辑顺序
  for (let v = 0; v < members.length; v++) map[v] = members[v]!;
  for (let lvl = maxLevel; lvl >= minOdd; lvl--) {
    let k = 0;
    while (k < members.length) {
      if (levels[members[k]!]! >= lvl) {
        let e = k;
        while (e < members.length && levels[members[e]!]! >= lvl) e++;
        // 反转 map 里这段对应的视觉槽
        for (let a = k, b = e - 1; a < b; a++, b--) {
          const tmp = map[a]!;
          map[a] = map[b]!;
          map[b] = tmp;
        }
        k = e;
      } else k++;
    }
  }
  // 把 -1 槽位铺回去：被移除的字符不占视觉位置 —— map 前 members.length 位是重排结果，
  // 剩下的槽填 -1。为了让"视觉槽位"与数组下标一致（调用方按序遍历即可），
  // 这里把移除字符的 -1 放回它们的**逻辑原位**：移动成员映射到"压缩槽位"，
  // 再展开回全长数组（移除位 -1）。
  const compact = Int32Array.from(map.subarray(0, members.length));
  map.fill(-1);
  {
    let c = 0;
    for (let i = start; i < end; i++) {
      if (isRemoved(types[i]!)) continue;
      map[i - start] = compact[c++]!;
    }
  }
  return map;
}

// ---- ③ 码点数组 API（排版层的消费口） ----

/**
 * 给一串码点定 embedding levels。base 用 "auto" 时段落方向由 P2/P3 判定。
 * 返回 levels（与输入等长）；X9 移除字符的槽位也有 level，但重排时是 -1 槽。
 */
export function embeddingLevels(
  codes: readonly number[],
  base: ParaDir,
): { levels: Uint8Array; types: Uint8Array; rawTypes: Uint8Array; paraLevel: 0 | 1 } {
  const types = Array.from(codes, (c) => bidiClassOf(c));
  const paraLevel = paragraphLevelFromTypes(types, base);
  const brackets: number[] = codes.map((c) => bracketPairOf(c) ?? -1);
  const r = levelsFromTypes(
    types,
    paraLevel,
    brackets.map((b) => (b < 0 ? undefined : b)),
    codes,
  );
  return { levels: r.levels, types: r.types, rawTypes: r.rawTypes, paraLevel };
}
