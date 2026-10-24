/**
 * L4 · 世界生成（阶段 3 的第三条出口判据）
 *
 * 目标不是"生成一张能看的地图"，而是满足三条**可机器验证**的承诺：
 *   ① **同种子 ⇒ 同指纹**（跨进程、跨机器、跨次运行）；
 *   ② **连通性可校验**（校验器能真的报出"有陆地到不了"）；
 *   ③ 群系是**成片**的，不是逐格独立随机的噪点 —— 否则连通性校验毫无意义
 *      （每个格子独立掷骰子，连不连通全凭运气，测了也说明不了实现对不对）。
 *
 * ★ 为什么坐标必须是定点整数：
 *   世界指纹要对"同一份数据"给出同一个串。浮点一旦进指纹，
 *   格式化差异就会变成幽灵漂移（见 `canonical.ts` 文件头）。
 *   所以这里把 1 格切成 `FIXED_UNITS = 256` 份，位姿全部是整数，
 *   需要世界单位时再除 —— **除法发生在使用侧，不发生在存储侧**。
 *
 * ★ 为什么噪声用整数运算写：
 *   双线性插值的每一项都能表达成"整数 × 整数"，除以 `G*G` 用 `Math.floor` 取整。
 *   全程 `Math.imul` + 整数加乘 ⇒ 没有任何一步依赖浮点舍入，
 *   于是"同种子同世界"这条承诺在**位级别**成立，而不只是"大概一样"。
 *
 * ★ 为什么不用全局 `Math.random()`：见 `foundation/random.ts`。这里更进一步 ——
 *   每个格子的投放用**从 (seed, 格子下标) 派生的独立 RNG**，而不是一条连续流。
 *   好处：往地图上加一个格子，不会把后面所有格子的投放全部错位
 *   （判据里有一条专门验这个"局部性"）。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import { XorShift128 } from "../../foundation/random.ts";
import { fingerprintOf } from "../../foundation/canonical.ts";

/** 1 个格子在定点表示里切成多少份。256 是 2 的幂：乘除都能写成移位，且不丢精度。 */
export const FIXED_UNITS = 256;

/** 指纹格式版本。★ 格式变了就要升这个数，否则新旧指纹"看起来能比"其实不能。 */
export const WORLD_PLAN_SCHEMA = 1;

export type BiomeKind = "ocean" | "beach" | "grass" | "forest" | "rocky" | "cliff" | "savanna" | "marsh";

export type SiteKind = "tree" | "berry" | "rock" | "flint" | "grass_tuft" | "reed";

/**
 * `SiteKind` 的运行时清单（类型在编译期管不到的地方用它：存档读出的字符串、
 * 背包里跨版本带过来的种类）。**新增种类要同步这里** —— 漏了的症状是
 * "世界那一侧永远放不下这种东西"，而类型检查一声不吭。
 */
export const SITE_KINDS: readonly SiteKind[] = ["tree", "berry", "rock", "flint", "grass_tuft", "reed"];

/** 字符串 → `SiteKind` 的校验（不是断言：未知值必须能被拒绝，不能蒙混过关）。 */
export function isSiteKind(k: string): k is SiteKind {
  return (SITE_KINDS as readonly string[]).includes(k);
}

interface BiomeDef {
  readonly passable: boolean;
  /** 该群系上可能投放的资源种类（空数组 = 不投放，但可能仍可通行） */
  readonly sites: readonly SiteKind[];
}

/**
 * 群系表。`passable` 只有两处是 false：
 *   · `ocean` —— 海是边界，不是可走地形；
 *   · `cliff` —— 内陆高地，**故意**做成不可通行，好让"陆地被切成几块"真实发生；
 *     否则连通性校验永远绿，等于没有校验。
 */
const BIOMES: Readonly<Record<BiomeKind, BiomeDef>> = {
  ocean: { passable: false, sites: [] },
  cliff: { passable: false, sites: [] },
  beach: { passable: true, sites: ["flint", "grass_tuft"] },
  grass: { passable: true, sites: ["tree", "berry", "grass_tuft"] },
  forest: { passable: true, sites: ["tree", "tree", "berry"] },
  savanna: { passable: true, sites: ["grass_tuft", "rock"] },
  marsh: { passable: true, sites: ["reed", "berry"] },
  rocky: { passable: true, sites: ["rock", "flint"] },
};

/** 群系是否可通行（唯一的判定入口 —— 不允许调用方自己写 `kind !== "ocean"`）。 */
export function isPassable(kind: BiomeKind): boolean {
  return BIOMES[kind].passable;
}

/**
 * 群系名是否属于当前 schema。
 *
 * ★ 存在的理由：`isPassable()` 遇到未知名字会**抛异常**（读 `undefined.passable`）。
 *   本文件产出的计划永远合法，但装配要能吃"别人给的计划"（存档、编辑器手改、
 *   上个版本留下的 JSON），那时"这个字符串根本不是一个群系"必须是一个**可返回的错误**，
 *   而不是一句 `TypeError` —— 后者在装配中途抛出会留下半个世界。
 *   ★ 用 `hasOwnProperty` 而不是 `in`：`in` 会把 `"toString"` 认成群系名。
 */
export function isBiomeKind(value: unknown): value is BiomeKind {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(BIOMES, value);
}

export interface BiomeCell {
  readonly x: number;
  readonly z: number;
  readonly kind: BiomeKind;
}

export interface WorldSite {
  /**
   * 投放点 id：`格子下标 * maxSitesPerCell + 序号`。
   * ★ 不用"全局自增计数器"：那样"在中间加一个格子"会让后面所有 id 平移，
   *   存档里引用的 id 全部指向别的东西。这个坑上一代引擎踩过（节点 id 全局自增）。
   */
  readonly id: number;
  readonly kind: SiteKind;
  /** 定点坐标（1 格 = 256）。 */
  readonly x: number;
  readonly z: number;
  /** 所属格子（便于校验与调试，不参与任何计算分支）。 */
  readonly cell: number;
}

/** 修复连通性时架的桥：从 `fromCell` 直线打一条可通行走廊到 `toCell`。 */
export interface WorldBridge {
  readonly fromCell: number;
  readonly toCell: number;
}

export interface WorldPlan {
  readonly seed: number;
  readonly width: number;
  readonly height: number;
  /** 行优先的群系序列（长度 = width * height）。 */
  readonly kinds: readonly BiomeKind[];
  readonly sites: readonly WorldSite[];
  readonly bridges: readonly WorldBridge[];
  /** 64 位 hex。等于 `planDigest(plan)`，生成时算好放进来，避免调用方各算一遍。 */
  readonly fingerprint: string;
}

export interface WorldGenParams {
  readonly seed: number;
  readonly width: number;
  readonly height: number;
  /**
   * 是否自动架桥修复连通性（默认 `true`）。
   * ★ 保留 `false` 不是为了"给用户选项"，而是**为了让校验器有东西可抓**：
   *   一条永远报绿的连通性校验和没有校验是一回事。判据里用 `repair:false`
   *   造出"有陆地到不了"的世界，校验器必须报出来。
   */
  readonly repair?: boolean;
  /** 每格最多投放几个资源点（默认 2）。 */
  readonly maxSitesPerCell?: number;
}

export const WORLD_BAD_PARAMS = "WORLD.BAD_PARAMS";

const NOISE_PERIOD = 8;

function mix32(a: number): number {
  let x = a | 0;
  x = Math.imul(x ^ (x >>> 16), 0x85ebca6b);
  x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35);
  return (x ^ (x >>> 16)) >>> 0;
}

/** 格点噪声值：0..1023 的整数。`channel` 让同一格子能取到互不相关的好几层噪声。 */
function latticeValue(seed: number, lx: number, lz: number, channel: number): number {
  const h = mix32(
    (seed | 0) ^ Math.imul(lx, 0x27d4eb2d) ^ Math.imul(lz, 0x165667b1) ^ Math.imul(channel, 0x9e3779b1),
  );
  return h % 1024;
}

/**
 * 双线性噪声（全整数）。
 * 返回值 0..1023，且**同一 (seed, x, z, channel) 在任何平台上逐位相同**。
 */
function noise2(seed: number, x: number, z: number, channel: number): number {
  const g = NOISE_PERIOD;
  const lx = Math.floor(x / g);
  const lz = Math.floor(z / g);
  const dx = x - lx * g;
  const dz = z - lz * g;

  const a = latticeValue(seed, lx, lz, channel);
  const b = latticeValue(seed, lx + 1, lz, channel);
  const c = latticeValue(seed, lx, lz + 1, channel);
  const d = latticeValue(seed, lx + 1, lz + 1, channel);

  const top = a * (g - dx) + b * dx;
  const bot = c * (g - dx) + d * dx;
  // 分母恒为 g*g，被除数恒为非负整数 ⇒ floor 是精确的整数除法
  return Math.floor((top * (g - dz) + bot * dz) / (g * g));
}

/**
 * 由 (高程, 湿度) 定群系。
 * 分档数字**故意硬编码**：它们是可复现性的一部分，改动等于换了一张地图，
 * 所以改这里必须同时升 `WORLD_PLAN_SCHEMA`。
 */
function pickBiome(elevation: number, moisture: number): BiomeKind {
  if (elevation < 280) return "ocean";
  if (elevation < 340) return "beach";
  if (elevation >= 900) return "cliff";
  if (elevation >= 780) return "rocky";
  if (moisture < 300) return "savanna";
  if (moisture < 700) return "grass";
  if (moisture < 850) return "forest";
  return "marsh";
}

function cellSeed(seed: number, cellIndex: number): number {
  return mix32((seed | 0) ^ Math.imul(cellIndex + 1, 0x9e3779b1));
}

/** 4 邻域（不带对角线：对角穿墙在 2.5D 里是不该允许的，否则"贴着墙斜走"能穿过去）。 */
const NEIGHBORS: readonly (readonly [number, number])[] = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1],
];

interface Components {
  readonly regionOf: Int32Array;
  /** 每个分量包含的格子下标（升序），按"最小格子下标"排序后的顺序。 */
  readonly groups: readonly (readonly number[])[];
}

/** 求可通行格的四连通分量。不可通行格 region = -1。 */
export function findComponents(width: number, height: number, kinds: readonly BiomeKind[]): Components {
  const total = width * height;
  const regionOf = new Int32Array(total).fill(-1);
  const groups: number[][] = [];
  const queue: number[] = [];

  for (let start = 0; start < total; start++) {
    if (regionOf[start] !== -1) continue;
    if (!isPassable(kinds[start]!)) continue;

    const id = groups.length;
    const group: number[] = [];
    regionOf[start] = id;
    queue.length = 0;
    queue.push(start);

    for (let head = 0; head < queue.length; head++) {
      const cur = queue[head]!;
      group.push(cur);
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [ox, oz] of NEIGHBORS) {
        const nx = cx + ox;
        const nz = cz + oz;
        if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
        const ni = nz * width + nx;
        if (regionOf[ni] !== -1) continue;
        if (!isPassable(kinds[ni]!)) continue;
        regionOf[ni] = id;
        queue.push(ni);
      }
    }
    group.sort((p, q) => p - q);
    groups.push(group);
  }
  return { regionOf, groups };
}

/** 在两点之间画直线（Bresenham），返回路径上的格子下标（含两端）。 */
function lineCells(width: number, x0: number, z0: number, x1: number, z1: number): number[] {
  const out: number[] = [];
  const dx = Math.abs(x1 - x0);
  const dz = Math.abs(z1 - z0);
  const sx = x0 < x1 ? 1 : -1;
  const sz = z0 < z1 ? 1 : -1;
  let e = dx - dz;
  let x = x0;
  let z = z0;
  for (;;) {
    out.push(z * width + x);
    if (x === x1 && z === z1) break;
    const e2 = 2 * e;
    if (e2 > -dz) {
      e -= dz;
      x += sx;
    }
    if (e2 < dx) {
      e += dx;
      z += sz;
    }
  }
  return out;
}

/**
 * 架桥修复：把每个"非最大分量"用一条直线走廊连到最大分量上。
 *
 * ★ 目标格选"曼哈顿距离最近的**最大分量**格子"，平局取下标小的 ——
 *   平局规则必须写死，否则同一份输入会因遍历顺序不同产生不同的桥，
 *   "同种子同指纹"当场失效。
 *
 * ★ 为什么要循环多轮：一条走廊可能顺手穿过第三个分量，把它也并进来；
 *   但也可能只并进来一部分（走廊是直线，分量是块状）。多算几轮能收敛，
 *   而"本轮一格都没挖开"就是收敛的判据 —— 不按轮数硬判，避免空转。
 */
function repairConnectivity(
  width: number,
  height: number,
  kinds: BiomeKind[],
  bridges: WorldBridge[],
): { carved: number; rounds: number } {
  let carved = 0;
  let rounds = 0;

  for (let round = 0; round < 4; round++) {
    const { groups } = findComponents(width, height, kinds);
    if (groups.length <= 1) break;
    rounds++;

    // 最大分量：格数最多；平局取最小格子下标（`groups` 已按"最小格子下标"排序）
    let mainIdx = 0;
    for (let i = 1; i < groups.length; i++) {
      if (groups[i]!.length > groups[mainIdx]!.length) mainIdx = i;
    }
    const main = groups[mainIdx]!;

    let carvedThisRound = 0;
    for (let gi = 0; gi < groups.length; gi++) {
      if (gi === mainIdx) continue;
      const group = groups[gi]!;
      const source = group[0]!;
      const sx = source % width;
      const sz = (source - sx) / width;

      let best = -1;
      let bestD = Number.POSITIVE_INFINITY;
      for (const target of main) {
        const tx = target % width;
        const tz = (target - tx) / width;
        const d = Math.abs(tx - sx) + Math.abs(tz - sz);
        if (d < bestD) {
          bestD = d;
          best = target;
        }
      }
      if (best < 0) continue;
      const tx = best % width;
      const tz = (best - tx) / width;

      let carvedHere = 0;
      for (const cell of lineCells(width, sx, sz, tx, tz)) {
        if (isPassable(kinds[cell]!)) continue;
        kinds[cell] = "beach";
        carvedHere++;
      }
      if (carvedHere > 0) {
        bridges.push({ fromCell: source, toCell: best });
        carvedThisRound += carvedHere;
      }
    }

    carved += carvedThisRound;
    if (carvedThisRound === 0) break;
  }

  return { carved, rounds };
}

/** 生成世界。参数不合法时返回错误，**不做任何"合理默认"兜底**。 */
export function generateWorld(params: WorldGenParams): Result<WorldPlan, EngineError> {
  const { seed, width, height } = params;
  if (!Number.isInteger(seed)) {
    return err({ code: WORLD_BAD_PARAMS, message: `seed 必须是整数，得到 ${String(seed)}` });
  }
  if (!Number.isInteger(width) || width < 8 || width > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `width 必须是 8..128 的整数，得到 ${String(width)}` });
  }
  if (!Number.isInteger(height) || height < 8 || height > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `height 必须是 8..128 的整数，得到 ${String(height)}` });
  }
  const maxSites = params.maxSitesPerCell ?? 2;
  if (!Number.isInteger(maxSites) || maxSites < 0 || maxSites > 8) {
    return err({ code: WORLD_BAD_PARAMS, message: `maxSitesPerCell 必须是 0..8 的整数，得到 ${String(maxSites)}` });
  }

  const total = width * height;
  const kinds: BiomeKind[] = new Array<BiomeKind>(total);

  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      // 边界一圈强制海：把地图做成一座岛，连通性问题才有意义
      const isBorder = x === 0 || z === 0 || x === width - 1 || z === height - 1;
      if (isBorder) {
        kinds[z * width + x] = "ocean";
        continue;
      }
      const elevation = noise2(seed, x, z, 1);
      const moisture = noise2(seed, x, z, 2);
      kinds[z * width + x] = pickBiome(elevation, moisture);
    }
  }

  const bridges: WorldBridge[] = [];
  if (params.repair !== false) {
    repairConnectivity(width, height, kinds, bridges);
  }

  const sites: WorldSite[] = [];
  for (let cell = 0; cell < total; cell++) {
    const kind = kinds[cell]!;
    const def = BIOMES[kind];
    if (!def.passable || def.sites.length === 0 || maxSites === 0) continue;
    const rng = new XorShift128(cellSeed(seed, cell));
    const n = rng.int(1, maxSites + 1);
    const cx = cell % width;
    const cz = (cell - cx) / width;
    for (let k = 0; k < n; k++) {
      const siteKind = rng.pick(def.sites);
      if (siteKind === undefined) continue;
      sites.push({
        id: cell * maxSites + k,
        kind: siteKind,
        x: cx * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        z: cz * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        cell,
      });
    }
  }

  const partial = {
    schema: WORLD_PLAN_SCHEMA,
    seed,
    width,
    height,
    kinds,
    sites,
    bridges,
  } as const;
  const fp = fingerprintOf(partial);
  if (!fp.ok) return fp;

  return ok({
    seed,
    width,
    height,
    kinds,
    sites,
    bridges,
    fingerprint: fp.value,
  });
}

/**
 * 独立计算计划指纹（不含 `fingerprint` 字段本身 —— 自指会把指纹变成不动点问题）。
 * 判据里用它验证"生成时算的指纹"与"重新算的指纹"一致。
 */
export function planDigest(plan: WorldPlan): Result<string, EngineError> {
  return fingerprintOf({
    schema: WORLD_PLAN_SCHEMA,
    seed: plan.seed,
    width: plan.width,
    height: plan.height,
    kinds: plan.kinds,
    sites: plan.sites,
    bridges: plan.bridges,
  });
}

/** 找不到出生点（整张图没有可通行的陆地）。 */
export const WORLD_NO_SPAWN = "WORLD.NO_SPAWN";

/** 出生点。坐标是格子中心，且是**定点整数倍**（可直接换算成世界单位）。 */
export interface SpawnPoint {
  readonly cell: number;
  readonly x: number;
  readonly z: number;
  /**
   * 到最近**不可通行格或地图边缘**的四连通步数（"余量"）。
   * 1 表示贴着海/悬崖/边界；越大越宽敞。玩家出生在 1 上面等于一睁眼就卡在海边。
   */
  readonly clearance: number;
}

/**
 * 选出生点。
 *
 * ★ 规则（全部写死，因为"同种子同世界"要求它确定）：
 *   ① 只在**主分量**里选 —— 出生在走不到主大陆的小岛上，等于这局白开；
 *   ② 取"到最近不可通行格的四连通距离"**最大**的格子；
 *   ③ 平局取**格子下标最小**的那个。
 *
 * ★ 为什么把**地图边缘**也算源：全可通行的手改地图（编辑器里画一片草地）
 *   一个不可通行格都没有，只算"不可通行格"会让距离全是 `-1`，
 *   选出来的出生点会是"第一个格子"—— 那既不宽敞，也不是任何人想要的结果。
 *   把出界也算作一步之后，"离边缘多远"成为同一条规则的推论，没有特例分支。
 *
 * ★ 为什么用"离不可通行格的步数"而不是"离地图中心":
 *   中心可能正好是悬崖或海（岛形地图上很常见），而"宽敞"是玩家真正能感知的性质。
 *   BFS 距离变换是多源一次算完的，代价 O(格子数) —— 不值得为它引入噪声采样。
 *
 * ★ 为什么平局规则必须写死：并列最大值的格子在地图上往往是一整片
 *   （全草地时全部并列）。不指定平局规则，结果就会取决于遍历顺序或 Map 迭代序，
 *   "同种子同世界"当场失效，而这种失效**只在某些种子上出现**。
 */
export function pickSpawn(plan: WorldPlan): Result<SpawnPoint, EngineError> {
  const { width, height, kinds } = plan;
  const total = width * height;
  const { regionOf, groups } = findComponents(width, height, kinds);

  let mainIdx = -1;
  let largest = 0;
  for (let i = 0; i < groups.length; i++) {
    const n = groups[i]!.length;
    if (n > largest) {
      largest = n;
      mainIdx = i;
    }
  }
  if (mainIdx < 0) {
    return err({ code: WORLD_NO_SPAWN, message: "整张图没有可通行的陆地（全是海/悬崖），无法选出生点" });
  }

  // 多源 BFS：不可通行格为源（dist 0），可通行的边缘格 dist 1（它的邻居在图外）
  const dist = new Int32Array(total).fill(-1);
  const queue: number[] = [];
  for (let i = 0; i < total; i++) {
    if (!isPassable(kinds[i]!)) {
      dist[i] = 0;
      queue.push(i);
    }
  }
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      if (x !== 0 && z !== 0 && x !== width - 1 && z !== height - 1) continue;
      const i = z * width + x;
      if (dist[i] !== -1) continue;
      dist[i] = 1;
      queue.push(i);
    }
  }
  for (let head = 0; head < queue.length; head++) {
    const cur = queue[head]!;
    const cx = cur % width;
    const cz = (cur - cx) / width;
    const d = dist[cur]!;
    for (const [ox, oz] of NEIGHBORS) {
      const nx = cx + ox;
      const nz = cz + oz;
      if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
      const ni = nz * width + nx;
      if (dist[ni] !== -1) continue;
      dist[ni] = d + 1;
      queue.push(ni);
    }
  }

  // 主分量内取 dist 最大；平局取下标最小（严格 `<` 让先遇到的留下）
  let best = -1;
  let bestDist = -1;
  for (let i = 0; i < total; i++) {
    if (regionOf[i] !== mainIdx) continue;
    const d = dist[i]!;
    if (d > bestDist) {
      bestDist = d;
      best = i;
    }
  }
  if (best < 0) {
    return err({ code: WORLD_NO_SPAWN, message: `主分量（${largest} 格）里没有可通行格` });
  }

  const bx = best % width;
  const bz = (best - bx) / width;
  return ok({
    cell: best,
    x: bx * FIXED_UNITS + FIXED_UNITS / 2,
    z: bz * FIXED_UNITS + FIXED_UNITS / 2,
    clearance: bestDist,
  });
}
