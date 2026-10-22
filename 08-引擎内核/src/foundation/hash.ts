/**
 * L0 · 内容哈希（FNV-1a 双通道）
 *
 * ★ **不是密码学哈希**，不做任何安全假设，只回答一个问题：
 *   "这份字节和上次是不是同一份？"
 *
 * ★ 为什么放在 L0 而不是各层自己写：
 *   这件事已经出过一次事了。资产层（L4）和 gfx-null 后端（L5）**各写了一份**
 *   双 FNV，B 通道的 offset basis 一个取 `0x9e3779b9`、一个取 `0x84222325`。
 *   两边的注释都写着"FNV-1a 双拼"，单看谁都没错，但它们算出的摘要**互不相等** ——
 *   于是"资产层解出的像素"和"GPU 实际收到的像素"没法比对，
 *   `解码 → 上传` 这条链的最后一环只能靠"我相信它接通了"。
 *   凡是"两边都要算同一个东西"的原语，都必须只有一个实现。
 *
 * ★ 为什么不用 SHA-256：
 *   增量导入的每个文件每次运行都要算一次；FNV-1a 是逐字节乘加，比密码学哈希快一个量级，
 *   且不需要 `crypto` 模块（浏览器/Node 同一份代码，同步、零依赖）。
 *   代价是抗碰撞性差 —— 对"手滑改错"足够，对"有人恶意构造碰撞"不够。
 *   若将来要校验下载内容，应换成 SHA-256；那时改的只有这个文件。
 *
 * ★ 为什么用**两个** FNV-1a（不同 offset basis）拼 16 hex：
 *   单个 32 位在几千个资产的工程里生日碰撞概率已不可忽略（~5000 个文件约 0.3%）。
 *   两个独立 basis 得到 64 位，成本只是两遍循环（同一份字节，不是更强的哈希族，只是加宽输出）。
 *
 * ★ 已知弱点（明确写出来，别指望它没弱点）：
 *   · 只对"内容变化"敏感，对文件**移动**不敏感（这正好是资产层要的：移动不改 id）；
 *   · 64 位下仍可能碰撞（可接受）；
 *   · 流式接口的 `hex()` 只看已 `update` 的字节，忘记 update 会得到"空流摘要"而不是报错 ——
 *     所以调用方必须同时比 `bytesHashed`，本文件的 `hashEquals` 就是干这个的。
 */

/** FNV-1a 32 位质数。 */
export const FNV_PRIME = 0x01000193;

/** 标准 basis（RFC 里的 32 位初值）。 */
export const FNV_BASIS_A = 0x811c9dc5;

/**
 * 第二通道 basis（黄金比例常量）。
 * ★ 这个值一旦改动，所有已落盘的 `sourceHash` 都会失效（触发全量重导）。
 *   历史：gfx-null 曾经用过 `0x84222325`，已统一到这里，别再各取各的。
 */
export const FNV_BASIS_B = 0x9e3779b9;

/**
 * 流式哈希状态（可变对象，`update` 原地修改 —— 每帧上传纹理时不该产生垃圾）。
 * 用普通 interface 而不是 class：它会进 `TexRec` 这类记录，保持"纯数据可观察"。
 */
export interface HashState {
  h1: number;
  h2: number;
  /** 已喂进摘要的字节数。为 0 时 `hashStateHex` 返回的是"空流摘要"。 */
  bytes: number;
}

export function hashStateCreate(): HashState {
  return { h1: FNV_BASIS_A, h2: FNV_BASIS_B, bytes: 0 };
}

/** 把一段字节喂进两条通道。分多次 update 与一次喂完整字节**结果相同**。 */
export function hashStateUpdate(s: HashState, bytes: Uint8Array): void {
  let h1 = s.h1;
  let h2 = s.h2;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i]!;
    h1 = Math.imul(h1 ^ b, FNV_PRIME) >>> 0;
    h2 = Math.imul(h2 ^ b, FNV_PRIME) >>> 0;
  }
  s.h1 = h1;
  s.h2 = h2;
  s.bytes += bytes.length;
}

function hex8(n: number): string {
  return (n >>> 0).toString(16).padStart(8, "0");
}

/** 16 个小写 hex 字符（两个 32 位 FNV-1a 拼接）。 */
export function hashStateHex(s: HashState): string {
  return hex8(s.h1) + hex8(s.h2);
}

/** 一次性哈希（等于"建状态 → update 一次 → 取 hex"）。 */
export function hashBytes(bytes: Uint8Array): string {
  const s = hashStateCreate();
  hashStateUpdate(s, bytes);
  return hashStateHex(s);
}

/** 文本按 UTF-8 编码后哈希（与写进文件时的字节一致，不按 UTF-16 编码）。 */
export function hashText(s: string): string {
  return hashBytes(new TextEncoder().encode(s));
}

/**
 * 两个哈希状态是否"同内容"。
 * ★ 必须同时比字节数：只比 hex 的话，"忘了 update 的两边"会双双等于空流摘要而**假相等**。
 */
export function hashEquals(a: HashState, b: HashState): boolean {
  return a.bytes === b.bytes && a.h1 === b.h1 && a.h2 === b.h2;
}
