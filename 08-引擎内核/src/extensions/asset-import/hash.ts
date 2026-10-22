/**
 * L4 · 资产导入 · 变更检测哈希（**薄壳**，实现已上移到 L0）
 *
 * ★ 为什么这层现在是薄壳：
 *   这个双 FNV 原先在这里和 `gfx-null` 后端**各写了一份**，B 通道 basis 分别是
 *   `0x9e3779b9` 与 `0x84222325` —— 两边注释都写"FNV-1a 双拼"，单看都对，
 *   但算出的摘要**互不相等**，导致"资产层解出的像素"与"GPU 收到的像素"无法比对。
 *   现在只有 `foundation/hash.ts` 一份实现，这里只做语义命名（`contentHash`
 *   在资产语境下读起来比 `hashBytes` 清楚）。
 *
 * ★ 增量导入的语义要点（仍然由这里负责解释）：
 *   · 只对"内容变化"敏感，对文件**移动**不敏感 —— 这正是 `.meta` 身份层要的：
 *     移动/改名不改 id，只改 path 索引；
 *   · 64 位（两通道拼接）在几千资产的工程里碰撞概率可忽略；
 *   · 慢一档的密码学哈希（SHA-256）留给"校验下载内容"的场景，不在导入热路径上。
 */

import { hashBytes, hashText as hashTextUtf8 } from "../../foundation/hash.ts";

/** 16 个小写 hex 字符（两个 32 位 FNV-1a 拼接）。 */
export function contentHash(bytes: Uint8Array): string {
  return hashBytes(bytes);
}

/** 文本按 UTF-8 编码后哈希（与写进文件时的字节一致，不按 UTF-16 编码）。 */
export function hashText(s: string): string {
  return hashTextUtf8(s);
}
