/**
 * L4 · 连续碰撞（扫掠）：「这一拍会不会穿过去」，而不是「现在是不是重叠」
 *
 * ★★ 缺的是什么（库里的 AABB + 空间哈希解决的是另一件事）：
 *   `SpatialHashWorld.resolve()` 是**位置解算** —— 它按当前坐标找重叠对，然后把它们推开。
 *   它回答「现在是不是叠在一起」。对**离散采样**漏掉的东西，它一个字都说不了：
 *   一个 6 单位/秒的单位在 16ms 的一拍里走 0.1 单位，没问题；
 *   被击退到 40 单位/秒时同一拍走 0.64 单位 —— 一堵 0.5 单位厚的墙就整个跨过去了。
 *   跨过去之后**永远**不会被推回来（下一拍它已经在墙的另一侧、不重叠了），
 *   症状是「这只怪偶尔会穿过箱子」，而重放同一个种子也复现不了（取决于它在哪一拍贴边）。
 *
 *   所以需要的是**时刻**：沿这一步的位移，最早在哪个 `t ∈ [0,1]` 上碰到了东西。
 *   拿到 `t` 之后"停在那儿"就完事了，不需要子步进（substep）、不需要把 dt 切碎。
 *
 * ★★ 为什么是精确解，而不是「把盒子放大 r 再做线段与盒求交」：
 *   放大盒（Minkowski 和的正方形近似）在**角**上多出一块 —— 从 45° 打角时它给
 *   `t = 0.146`，而真实接触在 `t = 0.45`。三倍的提前量，症状是「明明还有半个身位就停住了」，
 *   在斜着穿过门框/箱子缝时天天见。
 *   精确解 = 放大盒的**四条边**（接触点落在原盒边的范围之内）∪ **四个角圆**（半径 r）。
 *   判据里 45° 打角那条直接把这个差钉住：把角圆去掉，它立刻红。
 *
 * ★ 本文件**只做直线扫掠**：圆（半径 r）沿一个向量平移，碰到静态 AABB。
 *   不做旋转、不做圆柱/球（这是 2.5D 的 XZ 平面）、不做多段反弹 ——
 *   「撞上之后沿切向继续走」的那一步在 `moveSwept()` 里，是**明确的循环**，
 *   不是某段数学的一部分。
 */

/** 静态障碍：中心 + 半宽半高（XZ 平面）。`nodeId` 只用于回报"撞到了谁"。 */
export interface SweepBox {
  readonly cx: number;
  readonly cz: number;
  readonly hx: number;
  readonly hz: number;
  readonly nodeId?: number;
}

/** 一次扫掠的命中。 */
export interface SweepHit {
  /** 接触时刻，`0..1`（沿这一步的位移归一化）。 */
  readonly t: number;
  /**
   * 接触法线（单位向量），方向是**把移动体推离障碍的那一侧**。
   * 于是"还在靠近"的判据是 `n·d < 0`，滑动就是把 `d` 的法向分量减掉。
   */
  readonly nx: number;
  readonly nz: number;
  /** 撞到的对象的 `nodeId`（没有标注时为 -1）。 */
  readonly nodeId: number;
}

const NO_NODE = -1;

function finite(name: string, v: number): void {
  if (!Number.isFinite(v)) throw new TypeError(`sweepCircleVsBox 的 ${name} 必须是有限数（收到 ${String(v)}）`);
}

/** 点到盒的最近点（盒内时返回点自身）。 */
function closestOnBox(px: number, pz: number, box: SweepBox): { x: number; z: number; inside: boolean } {
  const x = px < box.cx - box.hx ? box.cx - box.hx : px > box.cx + box.hx ? box.cx + box.hx : px;
  const z = pz < box.cz - box.hz ? box.cz - box.hz : pz > box.cz + box.hz ? box.cz + box.hz : pz;
  return { x, z, inside: x === px && z === pz };
}

/**
 * 起点已经重叠时的法线：沿**穿透最浅**的那个轴推出去。
 *
 * ★ 不能沿"位移的反方向"推：贴着左墙往里挤的时候位移是 +x，反方向也对；
 *   但 T 形拐角里位移可能是斜的，沿它推会把实体推**更深**地嵌进另一个轴。
 *   最小穿透轴是唯一与"往哪走"无关的选择。
 */
function overlapNormal(px: number, pz: number, box: SweepBox): { nx: number; nz: number } {
  const dxL = px - (box.cx - box.hx);
  const dxR = box.cx + box.hx - px;
  const dzL = pz - (box.cz - box.hz);
  const dzR = box.cz + box.hz - pz;
  const m = Math.min(dxL, dxR, dzL, dzR);
  if (m === dxL) return { nx: -1, nz: 0 };
  if (m === dxR) return { nx: 1, nz: 0 };
  if (m === dzL) return { nx: 0, nz: -1 };
  return { nx: 0, nz: 1 };
}

/**
 * 圆 vs 静态 AABB 的扫掠。
 *
 * `(px,pz)` 起点，`(dx,dz)` 这一步的位移（不是方向向量 —— 长度就是这一步走多远），
 * `r` 半径。返回最早接触，或 `null`（这一步不会碰到）。
 *
 * 三种边界，都各有一条判据盯着：
 *   ① **起点已重叠** ⇒ `t = 0`（不是"忽略"，也不是"滑过去"）：不然后面所有计算
 *      都在一个已经非法的状态上做，而"从墙里穿出去"正是这么来的；
 *   ② **零位移** ⇒ 不重叠就是 `null`（不要算出 `0/0 = NaN` 再污染整条链）；
 *   ③ **擦过**（最近距离恰好 > r）⇒ `null`（`>=` 与 `>` 的取法决定了"贴面滑行时会不会粘住"）。
 */
export function sweepCircleVsBox(
  px: number,
  pz: number,
  dx: number,
  dz: number,
  r: number,
  box: SweepBox,
): SweepHit | null {
  finite("px", px);
  finite("pz", pz);
  finite("dx", dx);
  finite("dz", dz);
  finite("r", r);
  if (!(r > 0)) throw new RangeError(`sweepCircleVsBox 的半径必须 > 0（收到 ${String(r)}）`);
  const nodeId = box.nodeId ?? NO_NODE;

  // ① 起点已重叠
  const cp = closestOnBox(px, pz, box);
  if (cp.inside) {
    const n = overlapNormal(px, pz, box);
    return { t: 0, nx: n.nx, nz: n.nz, nodeId };
  }
  const ddx = px - cp.x;
  const ddz = pz - cp.z;
  const d2 = ddx * ddx + ddz * ddz;
  if (d2 < r * r) {
    const len = Math.sqrt(d2);
    // 恰好落在角点上（len=0）不可能发生：`inside` 已经接走了盒内的情况。
    return { t: 0, nx: ddx / len, nz: ddz / len, nodeId };
  }
  // ② 零位移
  if (dx === 0 && dz === 0) return null;

  let best = Number.POSITIVE_INFINITY;
  let bestNx = 0;
  let bestNz = 0;

  // ---- 四条边（接触点必须落在**原盒**这条边的范围之内，否则属于角区域）
  const faces = [
    { axis: 0, plane: box.cx - box.hx - r, lo: box.cz - box.hz, hi: box.cz + box.hz, nx: -1, nz: 0 },
    { axis: 0, plane: box.cx + box.hx + r, lo: box.cz - box.hz, hi: box.cz + box.hz, nx: 1, nz: 0 },
    { axis: 1, plane: box.cz - box.hz - r, lo: box.cx - box.hx, hi: box.cx + box.hx, nx: 0, nz: -1 },
    { axis: 1, plane: box.cz + box.hz + r, lo: box.cx - box.hx, hi: box.cx + box.hx, nx: 0, nz: 1 },
  ] as const;
  for (const f of faces) {
    const p = f.axis === 0 ? px : pz;
    const d = f.axis === 0 ? dx : dz;
    if (d === 0) continue;
    const t = (f.plane - p) / d;
    if (!(t >= 0 && t <= 1)) continue;
    const other = f.axis === 0 ? pz + dz * t : px + dx * t;
    if (other < f.lo || other > f.hi) continue; // 角区域，交给下面
    // ★ 这里**没有**"是不是正在离开这一面"的判定，而且不需要：
    //   同轴的两个平面里，先到的那个必然 `t` 更小，而"已经穿过去"的那个 `t` 是负的
    //   （被 `t >= 0` 挡掉）。曾经写过一条 `d * nComp > 0 ⇒ continue`，被变异测试
    //   证明**任何输入下都不改变结果** —— 死分支比没写更糟（它会让人以为那里有保护）。
    if (t < best) {
      best = t;
      bestNx = f.nx;
      bestNz = f.nz;
    }
  }

  // ---- 四个角圆
  const corners = [
    { cx: box.cx - box.hx, cz: box.cz - box.hz },
    { cx: box.cx + box.hx, cz: box.cz - box.hz },
    { cx: box.cx - box.hx, cz: box.cz + box.hz },
    { cx: box.cx + box.hx, cz: box.cz + box.hz },
  ] as const;
  for (const c of corners) {
    const hit = rayVsCircle(px - c.cx, pz - c.cz, dx, dz, r);
    if (hit === null) continue;
    if (hit > best) continue;
    const hx0 = px + dx * hit - c.cx;
    const hz0 = pz + dz * hit - c.cz;
    // 接触点必须在这个角的**外侧象限**（否则那个方向本来就被边覆盖，会重复计）
    const outwardX = px < c.cx ? hx0 <= 0 : hx0 >= 0;
    const outwardZ = pz < c.cz ? hz0 <= 0 : hz0 >= 0;
    if (!outwardX || !outwardZ) continue;
    const len = Math.sqrt(hx0 * hx0 + hz0 * hz0);
    if (len === 0) continue;
    best = hit;
    bestNx = hx0 / len;
    bestNz = hz0 / len;
  }

  if (!Number.isFinite(best)) return null;
  return { t: best, nx: bestNx, nz: bestNz, nodeId };
}

/**
 * 线段（相对圆心）与半径 `r` 的圆的**最早**交点参数，没有则 `null`。
 *
 * 起点在圆内 ⇒ 返回 0（"已经碰到了"）。
 * ★ 判别式写成 `b*b - c` 而不是 `b² − 4ac`：`a = dx²+dz²` 已经除掉了，
 *   少两次乘法也少一次溢出机会（坐标是米级，dx 可能到几十，平方后 1e3 量级还安全，
 *   但把 `4a` 留着会让"高速体"这个用例更接近精度边界）。
 */
function rayVsCircle(px: number, pz: number, dx: number, dz: number, r: number): number | null {
  const c = px * px + pz * pz - r * r;
  if (c <= 0) return 0;
  const a = dx * dx + dz * dz;
  if (a === 0) return null;
  const b = px * dx + pz * dz;
  if (b >= 0) return null; // 正在远离圆心
  const disc = b * b - a * c;
  if (disc < 0) return null;
  return (-b - Math.sqrt(disc)) / a;
}

/** 圆 vs 圆（动态体互相之间也要来得及停住）。 */
export function sweepCircleVsCircle(
  px: number,
  pz: number,
  dx: number,
  dz: number,
  r: number,
  cx: number,
  cz: number,
  otherR: number,
  nodeId = NO_NODE,
): SweepHit | null {
  finite("cx", cx);
  finite("cz", cz);
  finite("otherR", otherR);
  const sum = r + otherR;
  const t = rayVsCircle(px - cx, pz - cz, dx, dz, sum);
  if (t === null || t > 1) return null;
  const hx = px + dx * t - cx;
  const hz = pz + dz * t - cz;
  const len = Math.hypot(hx, hz);
  if (len === 0) return { t, nx: 0, nz: 0, nodeId };
  return { t, nx: hx / len, nz: hz / len, nodeId };
}

/**
 * 从一组障碍里找**最早**的命中。
 * ★ 平手时取 `nodeId` 小的那个，不用"先来后到"：数组顺序取决于空间哈希的格遍历顺序，
 *   那在不同格宽下会变 ⇒ 同一个种子会出现两局结果不同。
 */
export function earliestHit(hits: Iterable<SweepHit | null>): SweepHit | null {
  let best: SweepHit | null = null;
  for (const h of hits) {
    if (h === null) continue;
    if (best === null || h.t < best.t || (h.t === best.t && h.nodeId < best.nodeId)) best = h;
  }
  return best;
}

export interface SweptMoveOptions {
  /** 最多滑动几次（撞一次墙算一次）。默认 3；超出就停住。 */
  readonly maxSlides?: number;
  /** 停下时与障碍保留的间隙（世界单位）。默认 1e-4。 */
  readonly skin?: number;
}

export interface SweptMoveResult {
  /** 终点。 */
  readonly x: number;
  readonly z: number;
  /** 这一步是否碰到过东西。 */
  readonly hit: boolean;
  /** 真的滑动了几次。 */
  readonly slides: number;
  /** 实际走过的路程（`<= |(dx,dz)|`，撞墙之后只会更短）。 */
  readonly traveled: number;
  /** 第一次撞到的 `nodeId`（没撞到为 -1）。 */
  readonly firstHit: number;
}

/**
 * 带滑动的扫掠移动：走到接触点，把位移的**法向分量**减掉，剩下的继续走。
 *
 * ★★ 为什么去掉法向分量就是"沿墙滑"：位移分解成 `d = (d·n)n + 切向`。
 *   去掉 `(d·n)n` 之后剩下的正好贴着墙面。不需要求切向量、不需要投影到墙面。
 * ★★ 为什么"走过的路程"必须 ≤ 原始长度（判据里有这一条）：
 *   如果滑动时**重新给一个满步长**，玩家会在墙角被弹射出去 —— 那是"凭空加能量"，
 *   而症状是"贴着墙走会比直线更快"，几乎没人会怀疑碰撞代码。
 * ★★ 起点已重叠时**这一拍不动**（`t = 0` ⇒ 立刻 break）：滑过去会让
 *   "卡在墙里"变成"从墙里穿出去"，而那正是这套代码要防的事。
 *   分开交给 `resolve()`（位置解算）做 —— 它才是负责"把重叠对推开"的那一层。
 */
export function moveSwept(
  x0: number,
  z0: number,
  dx: number,
  dz: number,
  r: number,
  boxes: readonly SweepBox[],
  opts: SweptMoveOptions = {},
): SweptMoveResult {
  finite("x0", x0);
  finite("z0", z0);
  finite("dx", dx);
  finite("dz", dz);
  finite("r", r);
  if (!(r > 0)) throw new RangeError(`moveSwept 的半径必须 > 0（收到 ${String(r)}）`);
  const maxSlides = Math.max(0, Math.floor(opts.maxSlides ?? 3));
  const skin = opts.skin ?? 1e-4;

  let x = x0;
  let z = z0;
  let remX = dx;
  let remZ = dz;
  let slides = 0;
  let traveled = 0;
  let hit = false;
  let firstHit = NO_NODE;

  for (let step = 0; step <= maxSlides; step++) {
    const h = earliestHit(boxes.map((b) => sweepCircleVsBox(x, z, remX, remZ, r, b)));
    if (h === null) {
      x += remX;
      z += remZ;
      traveled += Math.hypot(remX, remZ);
      break;
    }
    hit = true;
    if (firstHit === NO_NODE) firstHit = h.nodeId;
    // 起点已经重叠（`t === 0`）⇒ **这一拍不动**，交给 `resolve()` 去分开。
    // ★ 滑过去会让"卡在墙里"变成"从墙里穿出去"，而那正是这套代码要防的事。
    if (h.t <= 0) break;
    const len = Math.hypot(remX, remZ);
    // 走到接触点，再退 `skin`：不退的话下一轮起点恰好相切，
    // 而"相切"在浮点上是重叠/不重叠五五开 —— 那就是"有时会粘住"的来源。
    const back = Math.max(0, h.t - (len > 0 ? skin / len : 0));
    x += remX * back;
    z += remZ * back;
    traveled += len * back;
    const dot = remX * h.nx + remZ * h.nz;
    // 已经在离开（浮点噪声）⇒ 停，不要再滑（否则会在墙里来回抖）
    if (!(dot < 0)) break;
    remX -= h.nx * dot;
    remZ -= h.nz * dot;
    if (step === maxSlides) break; // 滑动次数用尽：停在接触点
    if (Math.hypot(remX, remZ) < skin) break;
    slides++;
  }

  return { x, z, hit, slides, traveled, firstHit };
}
