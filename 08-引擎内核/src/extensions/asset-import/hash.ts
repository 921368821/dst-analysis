/**
 * L4 · 资产导入 · 变更检测哈希
 *
 * ★ **不是密码学哈希**，不做任何安全假设，只回答一个问题：
 *   "这份字节和上次导入时是不是同一份？"
 *
 * ★ 为什么不用 SHA-256：
 *   增量导入的每个文件每次运行都要算一次；FNV-1a 是逐字节乘加，比
 *   密码学哈希快一个量级，而且不需要 crypto 模块（浏览器/Node 同一份代码）。
 *   代价是抗碰撞性差 —— 对"手滑改错"足够，对"有人恶意构造碰撞"不够。
 *   若将来要校验下载内容，应换成 SHA-256；那时改的只有这个文件。
 *
 * ★ 为什么用**两个** FNV-1a（不同 offset basis）拼 16 hex：
 *   单个 32 位哈希在几千个资产的工程里生日碰撞概率已经不可忽略
 *   （~5000 个文件约 0.3%）。两个独立 basis 得到 64 位，成本只是两遍循环。
 *   注意：两次遍历的是同一份字节，所以这不是"更强的哈希族"，只是加宽输出。
 *
 * ★ 已知弱点（明确写出来，别指望它没弱点）：
 *   · 只对"内容变化"敏感，对文件**移动**不敏感（这正好是我们要的：移动不改 id）；
 *   · 长度 + 字节顺序不同的两份内容仍可能碰撞（64 位，可接受）。
 */

/** FNV-1a 32 位质数。 */
const FNV_PRIME = 0x01000193;

/** 标准 basis 与黄金比例常量（两个不同起点，避免单点碰撞）。 */
const BASIS_A = 0x811c9dc5;
const BASIS_B = 0x9e3779b9;

function fnv1a(bytes: Uint8Array, basis: number): number {
  let h = basis >>> 0;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i]!;
    h = Math.imul(h, FNV_PRIME) >>> 0;
  }
  return h >>> 0;
}

function hex8(n: number): string {
  return n.toString(16).padStart(8, "0");
}

/** 16 个小写 hex 字符（两个 32 位 FNV-1a 拼接）。 */
export function contentHash(bytes: Uint8Array): string {
  return hex8(fnv1a(bytes, BASIS_A)) + hex8(fnv1a(bytes, BASIS_B));
}

/** 文本按 UTF-8 编码后哈希（与写进文件时的字节一致，不按 UTF-16 编码）。 */
export function hashText(s: string): string {
  return contentHash(new TextEncoder().encode(s));
}
