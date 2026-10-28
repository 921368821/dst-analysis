/**
 * 环形扫格（由近到远，环内按 cell 升序）
 *
 * ★ 为什么单独一个文件：`findFreeCells`（丢弃时找空地）与 `findCorpseCell`
 *   （尸体找落点）要的是**完全同一种顺序** —— 同一世界同一位置必须落在同一格，
 *   否则回放不成立。写成两份的话，改一处忘了另一处时，两次搜索会
 *   "看起来都对、却选不同的格"，而两个功能的判据各自都能过。
 *
 * ★ 只负责**边界**，不负责可通行/占用：那是调用方各自的谓词
 *   （丢弃要避开资源占格，尸体只要避开"已经有尸体"）。把谓词也塞进来的话，
 *   这个函数就得认识 `WorldTaskModuleHandle`，于是又绑回世界生成那一层。
 */

/**
 * 把"半径为 `r` 的那一圈"塞进 `out`（**不清空**，由调用方决定复用还是新建）。
 *
 * · `r = 0` 只放中心格；
 * · `r > 0` 只放**环上**的格子（内圈在更小的 `r` 上已经扫过）；
 * · 越界的直接跳过，不报错（世界边缘的搜索天然会遇到）。
 *
 * 顺序：`dz` 升序 → `dx` 升序。行主序下 `cell = z * width + x`，所以这个顺序
 * 同时就是 **cell 升序** —— "同距离取小格"这条规则不需要额外比较。
 */
export function cellsInRing(
  width: number,
  height: number,
  cx: number,
  cz: number,
  r: number,
  out: number[],
): void {
  if (!Number.isInteger(r) || r < 0) return;
  if (r === 0) {
    if (cx >= 0 && cx < width && cz >= 0 && cz < height) out.push(cz * width + cx);
    return;
  }
  for (let dz = -r; dz <= r; dz++) {
    for (let dx = -r; dx <= r; dx++) {
      if (Math.abs(dx) !== r && Math.abs(dz) !== r) continue;
      const gx = cx + dx;
      const gz = cz + dz;
      if (gx < 0 || gx >= width || gz < 0 || gz >= height) continue;
      out.push(gz * width + gx);
    }
  }
}
