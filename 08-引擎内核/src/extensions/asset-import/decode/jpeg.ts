/**
 * L4 · 资产导入 · 解码 · JPEG → RGBA8
 *
 * ★ 这个文件现在只是**转发壳**：实现已按职责拆到 `jpeg/` 下
 *   （types / tables / bits / frame / parse / scan-huffman / reconstruct）。
 *   保留它是因为调用方（`image.ts`、导入器、判据）按这个路径引用，
 *   而"因为内部重构就让所有调用方改 import"是没必要的破坏。
 */

export * from "./jpeg/index.ts";
