/**
 * L4 · 朝向（`motion.facing`）
 *
 * 「怪物追人时面朝目标」拆开是两半：**数据**（它朝哪）与**表现**（画哪一帧）。
 * 这一层只交付数据，因为它有两个消费者，而两者必须读同一个值：
 *   · `ai/perception` 的视野锥 —— 「前方」没有定义就不能做扇区感知；
 *   · 渲染层按方向选帧（`render/dir-frames.ts`）。
 *
 * ★★ 归属：**生物层（运动学），不是渲染层**。理由不是「哪个更合理」，
 *    而是三条可检验的事实：
 *    ① AI 在渲染之前跑，headless 世界根本没有渲染模块 —— 数据放渲染层，
 *       服务器与判据里就永远拿不到朝向，视野锥只能退化成全向；
 *    ② 朝向要进存档（「读档后面朝哪」是玩家看得见的状态），而渲染层的
 *       运行期状态是不存的；
 *    ③ 渲染层可以整块不装，朝向不该跟着消失。
 *
 * ★★ 只存**弧度**，`deg`/`dir8`/`dir4` 全是派生 getter。
 *    同时存「角度 + 方向枚举」是最常见的写法，也是最常见的一类 bug：
 *    写角度时忘了改枚举，于是精灵朝东、视野锥朝北 —— 而两边各自的判据都是绿的
 *    （各验各的那一半）。派生 getter 让「同一时刻只有一处真相」变成结构事实，
 *    不靠纪律。
 *
 * ★★ 归一化在**写入时**做，不在读取时做。
 *    读取时归一化看起来更省事，但 `angle += turn` 会一路累加到 1e6 弧度：
 *    f64 当然还够用，可是有人把 schema 里的 `Double` 改成 `Float` 就掉精度，
 *    而症状是「跑了半小时以后怪物朝错方向」。更现实的是 `-π` 与 `π`
 *    是同一个方向却 `!==`，存档比对与判据都会假红。
 *    `normRad` 把值域钉在 `[0, 2π)`，于是「相等」与「同向」是同一件事。
 *
 * ★ 转向速率（`turnRate`，度/秒）是**玩法参数**，不是表现参数：
 *    视野锥跟着朝向走时，「瞬时对准」等价于「全向感知」——
 *    追人的怪会永远看得见侧后方。所以限速必须可配，且限了之后要能被判据
 *    观察到（`turnTowards` 返回**实际**转过的量）。
 *    `0` = 不限速：没有朝向驱动的旧内容行为不变（每 tick 直接对准）。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";

/** 组件类型名。模块注册表、判据、宿主共用一处。 */
export const FACING_TYPE = "motion.facing";

const TAU = Math.PI * 2;
const DEG = Math.PI / 180;

/**
 * 归一化到 `[0, 2π)`。
 *
 * ★ 非有限值一律当 `0`：朝向要乘进旋转矩阵，一个 NaN 会让**整个节点的矩形**
 *   变成 NaN，而症状是「这个实体不见了」—— 离「朝向算错了」隔着三层。
 *   宁可朝错，不要消失：朝错有人看得见，消失只能猜。
 *
 * ★ `-0` 也要变成 `+0`：`Object.is(-0, 0)` 是 `false`，
 *   而存档比对与深层相等用的正是这一套语义 —— 差别在数值上为零，
 *   却足以让「同一个方向」被判成两份不同的存档。
 */
export function normRad(rad: number): number {
  if (!Number.isFinite(rad)) return 0;
  const m = rad % TAU;
  return m < 0 ? m + TAU : m + 0;
}

/**
 * 由位移增量求朝向。**零向量返回 `null`**（没有方向 ≠ 朝东）。
 *
 * ★ `atan2(0, 0)` 在 V8 里是 `0`（不是 NaN），所以直接用它会让
 *   「站着不动的怪物」被悄悄掰向东边。症状只在它停下来之后出现，
 *   看起来像美术帧选错了。
 */
export function angleOf(dx: number, dz: number): number | null {
  if (!Number.isFinite(dx) || !Number.isFinite(dz)) return null;
  if (dx === 0 && dz === 0) return null;
  return normRad(Math.atan2(dz, dx));
}

/**
 * 按「这一拍真的挪了多少」改朝向。**没挪就不动**，返回是否改过。
 *
 * ★★ 为什么单独抽出来：这段「读上一次位置 → 求差 → 写朝向」原来只写在
 *   `browser-entry.ts` 的 `onStep` 里，于是它只可能被**页面级**判据看见。
 *   而世界很脏（生物会推、物理会顶），像素级的朝向观测在浏览器里稳不住 ——
 *   三次里有一次红。抽成纯函数之后，四种方向 + 零位移都在 Node 里定死。
 *
 * ★ 用「实际位移」而不是「控制器想往哪走」是有意的：贴着墙时二者不同，
 *   读意图会让角色一直面朝墙外 —— 看起来像穿模的前兆。
 * ★ 零位移时**保持**原朝向（不是掰向东）：`angleOf` 返回 `null` 就是为这个。
 */
export function faceFromMotion(face: Facing, fromX: number, fromY: number, toX: number, toY: number): boolean {
  const a = angleOf(toX - fromX, toY - fromY);
  if (a === null) return false;
  face.setAngle(a);
  return true;
}

/**
 * 两个角之间的**最短**有向差，值域 `(-π, π]`。
 *
 * ★ 不取最短的后果是「从 350° 转到 10° 要走 340°」：怪物在目标前面
 *   原地绕一大圈才转过去，画面上是一段莫名的圆弧。
 * ★ 正好差 π 时统一取 `+π`（不是随便定的：不定死的话，
 *   同一个输入在两台机器上可能反向转，回放就不认字节了）。
 */
export function shortestDelta(from: number, to: number): number {
  const d = normRad(to) - normRad(from);
  if (d > Math.PI) return d - TAU;
  if (d <= -Math.PI) return d + TAU;
  return d;
}

/**
 * 方向扇区下标：`0` = 屏幕右（+x，东），**顺时针**增加（屏幕 y 向下）。
 *
 * 8 向时顺序是 `e, se, s, sw, w, nw, n, ne`；4 向时是 `e, s, w, n`。
 * 扇区**闭合于右端**（`Math.round`）：正好 22.5° 算 1 号扇形，
 * 所以边界只有一个答案，不会随浮点误差在两格之间跳。
 */
export function dirIndex(rad: number, dirs: number): number {
  const n = Number.isFinite(dirs) ? Math.max(1, Math.floor(dirs)) : 8;
  return Math.round(normRad(rad) / (TAU / n)) % n;
}

export class Facing extends Component {
  /**
   * 朝向（弧度，`[0, 2π)`）。`0` = +x（屏幕右），顺时针为正。
   *
   * ★ 直接写这个字段**不会**被归一化 —— 想安全赋值用 `setAngle()`。
   *   留着公开字段是因为序列化与编辑器面板按名字读写它（`Component.save/load`
   *   走的就是字段表），setter 会把 `load()` 挡住。
   *   写入方（`setAngle` / `turnTowards` / `faceTo`）都在写后归一化，
   *   越界值只可能来自手写存档。
   */
  angle = 0;

  /**
   * 最大转向角速度（度/秒）。`0` = 不限速（瞬时对准）。
   *
   * ★ 负值不表示「反向转」，而是「永远转不过去」—— 表现为怪物贴着目标
   *   原地发抖。判据钉住 `<= 0` 一律当不限速，比让负值参与运算便宜。
   */
  turnRate = 0;

  readonly schema: ComponentSchema = {
    type: FACING_TYPE,
    fields: {
      angle: FieldType.Double,
      turnRate: FieldType.Double,
    },
    defaults: { angle: 0, turnRate: 0 },
  };

  /** 朝向（度，`[0, 360)`）。给人看与给编辑器用；内部一律弧度。 */
  get deg(): number {
    return normRad(this.angle) / DEG;
  }

  /** 8 向扇区（`0` = 东，顺时针）。渲染选帧读它。 */
  get dir8(): number {
    return dirIndex(this.angle, 8);
  }

  /** 4 向扇区（`0` = 东，顺时针）。素材只有四张时用它。 */
  get dir4(): number {
    return dirIndex(this.angle, 4);
  }

  /** 直接设定（归一化后写入）。 */
  setAngle(rad: number): void {
    this.angle = normRad(rad);
  }

  /**
   * 朝 `(dx, dz)` 转，最多 `maxRad` 弧度。返回**实际**转过的有向弧度。
   *
   * ★ 零向量**什么都不做**并返回 0（见 `angleOf` 的注释）。
   * ★ `maxRad` 为 `Infinity` 或不有限值 = 不限速；`< 0` 当 0（不转）。
   */
  faceTo(dx: number, dz: number, maxRad = Number.POSITIVE_INFINITY): number {
    const a = angleOf(dx, dz);
    if (a === null) return 0;
    return this.turnTowards(a, maxRad);
  }

  /** 朝绝对角 `target` 转，最多 `maxRad` 弧度。返回实际转过的有向弧度。 */
  turnTowards(target: number, maxRad = Number.POSITIVE_INFINITY): number {
    const delta = shortestDelta(this.angle, target);
    let step = delta;
    if (Number.isFinite(maxRad)) {
      const lim = maxRad > 0 ? maxRad : 0;
      if (Math.abs(delta) > lim) step = delta > 0 ? lim : -lim;
    }
    // ★ `step === 0` 时**不写**：写回会把一个越界的手写存档值顺手抹成 0
    if (step !== 0) this.angle = normRad(this.angle + step);
    return step;
  }

  /**
   * 这一 `dt` 秒最多能转多少弧度（由 `turnRate` 决定）。
   *
   * ★ 收成一处的理由：`turnRate` 是度、`angle` 是弧度、`dt` 是秒 ——
   *   三处单位换算写在每个调用点上，必然有一处漏掉 `DEG`，
   *   而漏掉的症状是「转得特别慢」，看着像配置问题。
   */
  maxTurn(dt: number): number {
    if (!(this.turnRate > 0) || !Number.isFinite(this.turnRate)) return Number.POSITIVE_INFINITY;
    return this.turnRate * DEG * Math.max(0, dt);
  }
}

/** 注册到场景的组件表（与其它扩展同一形状：注册一次，不改 Scene）。 */
export function registerFacingComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(FACING_TYPE)) registry.register(new Facing().schema, () => new Facing());
}
