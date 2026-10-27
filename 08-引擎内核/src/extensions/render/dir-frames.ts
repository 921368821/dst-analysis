/**
 * L4 · 按朝向选帧（**帧名契约**，不是动画系统）
 *
 * `Sprite.frame` 是一个字符串，方向帧的存在方式只有一种：**图集里多几张图**，
 * 名字带方向后缀（`walk_e` / `walk_ne`…）。这一层只做一件事：
 * 把「朝向（`motion.facing` 的 `dir8`）」翻译成「该读哪个帧名」，
 * 顺便定死「美术还没画那一向」时的回落顺序。
 *
 * ★ 为什么不用数字后缀（`walk_0`…`walk_7`）：
 *   数字把「扇区怎么排」这个实现细节钉进了资产名，改 8 向顺序就要重命名一批图；
 *   字母（`e/se/s/sw/w/nw/n/ne`）是资产自己的属性，与引擎里的下标顺序无关 ——
 *   顺序只在这一处定义，改顺序不改图。
 *
 * ★ 为什么回落到「单帧前缀」而不是报错/不画：
 *   一张图都没有方向帧是最常见的中间状态（先有兔子，再谈它朝哪）。
 *   这时候**必须照样画出来**：看不见的实体比朝向错的实体难查得多
 *   （前者像「怪物没刷出来」，后者一眼能看出方向不对）。
 *   回落顺序写死在这里：`walk_<dir>` → `walk` → `null`。
 *
 * ★ 为什么没有「4 向回落到 8 向」这类智能回退：
 *   那会让「8 向里只画了 4 个」这种**残缺状态**看起来正常，
 *   而人眼在画面上分不出「这一向是拿邻向凑的」。宁可回落单帧 ——
 *   让残缺是**可见的**。
 */

/** 8 向字母表：下标与 `dirIndex(angle, 8)` 一致（`0` = 东，顺时针）。 */
const LETTERS8 = ["e", "se", "s", "sw", "w", "nw", "n", "ne"] as const;

/** 4 向字母表：`0` = 东，顺时针（跳过对角）。 */
const LETTERS4 = ["e", "s", "w", "n"] as const;

export type DirCount = 4 | 8;

/**
 * 扇区下标 → 方向字母。
 *
 * ★ 越界/负数按**环**取（`-1` ⇒ `ne`，`9` ⇒ `se`），不抛错：
 *   帧名算不出来的时候游戏还得继续跑，而抛在这里的错会变成
 *   「某只怪经过某个角度就崩」—— 症状离原因非常远。
 */
export function dirLetter(dir: number, dirs: DirCount = 8): string {
  const table: readonly string[] = dirs === 4 ? LETTERS4 : LETTERS8;
  const n = table.length;
  const i = ((Math.trunc(dir) % n) + n) % n;
  return table[i]!;
}

/** 方向帧名：`walk` + `0`（东） ⇒ `walk_e`。 */
export function dirFrameName(prefix: string, dir: number, dirs: DirCount = 8): string {
  return `${prefix}_${dirLetter(dir, dirs)}`;
}

/**
 * 在图集里解析出该画哪一帧。返回 `null` = 连回落的单帧都没有（调用方自己决定）。
 *
 * `has` 用函数而不是 `Set`：调用方手里可能是一张「帧名 → 索引」的 Map，
 * 或者一个惰性构造的集合，引擎不该逼他们先摊平成 `Set`。
 */
export function resolveDirFrame(
  has: (frame: string) => boolean,
  prefix: string,
  dir: number,
  dirs: DirCount = 8,
): string | null {
  const directed = dirFrameName(prefix, dir, dirs);
  if (has(directed)) return directed;
  if (has(prefix)) return prefix;
  return null;
}
