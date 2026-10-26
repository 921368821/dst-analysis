/**
 * L4 · 世界装配（把 `WorldPlan` 变成能真的跑的 `Scene`）
 *
 * `worldgen.ts` 产出的是**纯数据**（群系序列 + 投放点 + 架桥记录），
 * 它没有节点、没有组件、不能被 `scene.step` 驱动。这个文件补上"最后一公里"。
 *
 * ★ 为什么装配要单独一个文件，而不是在 `generateWorld` 里顺手建场景：
 *   生成要能在无渲染、无场景的环境里跑（编辑器预览、批量出图、指纹比对），
 *   `WorldPlan` 是它的**唯一**产物；装配是另一个关注点（谁装配、装配到哪个场景、
 *   装配后要不要存档）。混在一起会让"只想算指纹"的调用方被迫构造一个 Scene。
 *
 * ★★ 三条必须守住的承诺（都有对应判据）：
 *   ① **同计划 ⇒ 同场景**：节点树的形状、id、名字、定点位置、组件数据全部确定。
 *      所以这里不出现任何环境随机、不依赖对象属性枚举顺序、不读墙钟。
 *   ② **装配是可反查的**：`rasterizeTerrain()` 能从装配结果把群系栅格重建出来，
 *      与原 `kinds` 逐格相同 —— 否则"合并成矩形"这一步就是不可验证的自说自话。
 *   ③ **计划被改过要报错**：装配前重算指纹，与计划里存的指纹比对。
 *      少了这一步，一个被手改过（或来自旧 schema）的计划会被"忠实地"装配成错世界。
 *
 * ★ 为什么定点坐标除 `FIXED_UNITS` 能精确还原：
 *   `FIXED_UNITS = 256` 是 2 的幂 ⇒ `x / 256` 在二进制浮点里**无舍入**，
 *   于是 `node.localPosition.x * 256 === site.x` 是恒等式，不是"近似成立"。
 *   这是当初选 256 而不是 100 的真正理由（见 `FIXED_UNITS` 注释）。
 *   判据里用严格的 `===` 断言这一点 —— 若改成 `/1000`，这条会立刻红。
 *
 * ★ 为什么不用 `site.id` 当节点 id：
 *   ① `site.id` 从 0 起，而 root 固定是 1 ⇒ cell 0 的第 0 个投放点会撞 root；
 *   ② `Scene.allocateId(explicit)` 会把 id 水位推到 `explicit + 1`（见 scene.ts），
 *      于是装配完一个大地图后，**之后**新建的玩家节点 id 会跳到百万级。
 *   所以：**节点 id 是运行期身份**（按装配顺序确定地分配），
 *   **`siteId` 是内容身份**（`格子下标 * maxSites + 序号`，跨存档/跨地图稳定，记在组件里）。
 *   存档里要引用"那棵树"，引的是 `siteId`，不是节点 id。
 */

import type { ComponentRegistry, ComponentSchema } from "../../core/scene/component.ts";
import { Component, FieldType } from "../../core/scene/component.ts";
import type { Node } from "../../core/scene/node.ts";
import { Scene } from "../../core/scene/scene.ts";
import { fingerprintOf } from "../../foundation/canonical.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import {
  FIXED_UNITS,
  isBiomeKind,
  isPassable,
  planDigest,
  type BiomeKind,
  type SiteKind,
  type WorldPlan,
} from "./worldgen.ts";

/** 计划本身不可信（指纹不符 / 尺寸与内容不符 / 群系名未知）。 */
export const WORLD_BAD_PLAN = "WORLD.BAD_PLAN";
/** 目标场景不是空的 —— 装配**不**往已有世界里追加第二个世界。 */
export const WORLD_SCENE_NOT_EMPTY = "WORLD.SCENE_NOT_EMPTY";
/** 场景的组件注册表里没有世界组件（忘了 `registerWorldComponents`）。 */
export const WORLD_COMPONENTS_UNREGISTERED = "WORLD.COMPONENTS_UNREGISTERED";
/** 场景里的地形节点自相矛盾（越界 / 漏格 / 重叠），出现在反查与存档校验里。 */
export const WORLD_BAD_SCENE = "WORLD.BAD_SCENE";

export const TERRAIN_TYPE = "world.terrain";
export const SITE_TYPE = "world.site";

export const TERRAIN_SCHEMA: ComponentSchema = {
  type: TERRAIN_TYPE,
  fields: {
    kind: FieldType.String,
    /** 矩形左上角格子坐标与尺寸 —— 存的是**格子**，不是世界单位（不引入浮点）。 */
    cx: FieldType.Int,
    cz: FieldType.Int,
    w: FieldType.Int,
    h: FieldType.Int,
    /** 冗余但必要：`passable` 是"能不能走"的**运行时事实**，不只由 kind 推。 */
    passable: FieldType.Bool,
  },
};

export const SITE_SCHEMA: ComponentSchema = {
  type: SITE_TYPE,
  fields: {
    siteId: FieldType.Int,
    kind: FieldType.String,
    cell: FieldType.Int,
  },
};

/**
 * 一块矩形地形。
 *
 * ★ 为什么地形不是"每格一个节点"：
 *   64×64 的地图就是 4096 个节点，每个节点一套变换缓存 + 一次组件虚调用；
 *   而群系是成片的，合并后通常只剩几十~几百块。
 *   合并算法是**确定性的贪心**（规则写死在 `mergeTerrain` 里），
 *   所以"合并"不会破坏可复现性。
 */
export class TerrainArea extends Component {
  readonly schema: ComponentSchema = TERRAIN_SCHEMA;
  kind: BiomeKind = "ocean";
  cx = 0;
  cz = 0;
  w = 0;
  h = 0;
  passable = false;
}

/** 一个资源投放点。`siteId` 是内容身份（见文件头），`cell` 便于校验与调试。 */
export class SiteMarker extends Component {
  readonly schema: ComponentSchema = SITE_SCHEMA;
  siteId = 0;
  kind: SiteKind = "tree";
  cell = 0;
}

/**
 * 注册两个世界组件。
 * ★ 不自动注册（不在 import 时分产生副作用）：组件的注册顺序会进入序列化顺序，
 *   隐式注册会让"谁先 import 谁先注册"变成存档字节差异的来源。
 */
export function registerWorldComponents(registry: ComponentRegistry): void {
  if (!registry.has(TERRAIN_TYPE)) registry.register(TERRAIN_SCHEMA, () => new TerrainArea());
  if (!registry.has(SITE_TYPE)) registry.register(SITE_SCHEMA, () => new SiteMarker());
}

export interface TerrainRect {
  /** 左上角格子坐标（含）。 */
  readonly cx: number;
  readonly cz: number;
  readonly w: number;
  readonly h: number;
  readonly kind: BiomeKind;
}

/**
 * 贪心矩形合并（行优先扫描 + 先向右再向下扩）。
 *
 * ★ 确定性来自三件事，缺一条"同计划同场景"就不成立：
 *   ① 扫描序固定：`z` 外层、`x` 内层（行优先）；
 *   ② 向右扩到"下一个格子已访问或群系不同"为止；
 *   ③ 向下扩时**只检查这 w 列**，不重新求最大宽度 ——
 *      重新求宽度会让结果依赖"从哪一行开始扩"，也让"矩形宽度"随扫描顺序变化。
 *      不做这件事的结果是矩形偏窄，但覆盖仍然完全（判据里的 gap/overlap 都是 0）。
 *
 * ★ `visited` 必须在**扩展之前**用于判断、在**产出之后**统一写入：
 *   边扩边写会让"向右扩"读到刚写下的自己，扩到 1 格就停。
 */
export function mergeTerrain(
  width: number,
  height: number,
  kinds: readonly BiomeKind[],
): TerrainRect[] {
  const visited = new Uint8Array(width * height);
  const rects: TerrainRect[] = [];

  for (let cz = 0; cz < height; cz++) {
    for (let cx = 0; cx < width; cx++) {
      const start = cz * width + cx;
      if (visited[start] === 1) continue;
      const kind = kinds[start]!;

      let w = 1;
      while (cx + w < width) {
        const i = start + w;
        if (visited[i] === 1 || kinds[i] !== kind) break;
        w++;
      }

      let h = 1;
      while (cz + h < height) {
        let sameRow = true;
        for (let dx = 0; dx < w; dx++) {
          const i = (cz + h) * width + cx + dx;
          if (visited[i] === 1 || kinds[i] !== kind) {
            sameRow = false;
            break;
          }
        }
        if (!sameRow) break;
        h++;
      }

      for (let dz = 0; dz < h; dz++) {
        for (let dx = 0; dx < w; dx++) visited[(cz + dz) * width + cx + dx] = 1;
      }
      rects.push({ cx, cz, w, h, kind });
    }
  }
  return rects;
}

export interface AssembleReport {
  readonly terrainNodes: number;
  readonly siteNodes: number;
  /** 装配后场景里的节点总数（含 root 与两个容器）。 */
  readonly sceneNodes: number;
  readonly cells: number;
  readonly rects: number;
  readonly fingerprint: string;
}

/**
 * 把计划装配进一个**空场景**。
 *
 * ★ 为什么要求空场景：往非空场景里追加，会让"这个场景属于哪个世界"变得说不清
 *   （两个世界的投放点 id 空间会重叠，而 `siteId` 只在单个世界内唯一）。
 *   要换世界请先 `scene.clear()` —— 这个错误必须在装配时报，不能等到查询时才发现。
 *
 * ★ 为什么组件挂载走命令队列（`scene.attach` + `flush`）而不是 `node.attach()`：
 *   `Scene` 的 `byType` 索引只在 `flush`（`attachTo`）里建立。
 *   直接 `node.attach(c)` 会得到一个"节点上有组件，但 `scene.componentsOf()` 查不到"的场景 ——
 *   而这个错误**只在查询时**暴露，装配本身看起来完全成功。
 */
export function assembleWorld(plan: WorldPlan, scene: Scene): Result<AssembleReport, EngineError> {
  const { width, height, kinds } = plan;

  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
    return err({ code: WORLD_BAD_PLAN, message: `尺寸不合法：${String(width)}x${String(height)}` });
  }
  if (kinds.length !== width * height) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `kinds 长度 ${kinds.length} 与尺寸 ${width}x${height}（${width * height}）不符`,
    });
  }
  for (let i = 0; i < kinds.length; i++) {
    if (!isBiomeKind(kinds[i])) {
      return err({
        code: WORLD_BAD_PLAN,
        message: `第 ${i} 格的群系名未知：${String(kinds[i])}（可能是旧 schema 或手改的计划）`,
      });
    }
  }

  const digest = planDigest(plan);
  if (!digest.ok) return digest;
  if (digest.value !== plan.fingerprint) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `计划指纹与内容不符（计划里存 ${plan.fingerprint}，重算得 ${digest.value}）—— 内容被改过或来自旧 schema`,
    });
  }

  if (scene.stats().nodes !== 1) {
    return err({
      code: WORLD_SCENE_NOT_EMPTY,
      message: `目标场景已有 ${scene.stats().nodes - 1} 个节点（装配要求空场景，先 scene.clear()）`,
    });
  }

  // ★ 注册表检查放在**动场景之前**：否则第一块地形在 `scene.attach` 处失败时，
  //   两个容器节点已经建好了 —— 调用方拿到的是一句错误 + 一个被污染的场景。
  //   "失败要么没发生，要么留下可用的半成品"这条规则在这里选了前者。
  const missing = [TERRAIN_TYPE, SITE_TYPE].filter((t) => !scene.components.has(t));
  if (missing.length > 0) {
    return err({
      code: WORLD_COMPONENTS_UNREGISTERED,
      message: `组件类型未注册：${missing.join(", ")} —— 先 registerWorldComponents(scene.components)`,
    });
  }

  const rects = mergeTerrain(width, height, kinds);
  const terrainRoot = scene.spawnImmediate("terrain");
  const siteRoot = scene.spawnImmediate("sites");

  for (const r of rects) {
    const node = scene.spawnImmediate(`terrain/${r.kind}`, terrainRoot.id);
    node.setLocalPosition(r.cx, r.cz);
    const made = scene.attach(node.id, () => new TerrainArea());
    if (!made.ok) return made;
    made.value.kind = r.kind;
    made.value.cx = r.cx;
    made.value.cz = r.cz;
    made.value.w = r.w;
    made.value.h = r.h;
    made.value.passable = isPassable(r.kind);
  }

  for (const s of plan.sites) {
    const node = scene.spawnImmediate(`site/${s.kind}`, siteRoot.id);
    // 定点 → 世界单位：256 是 2 的幂，这一步没有舍入（见文件头）
    node.setLocalPosition(s.x / FIXED_UNITS, s.z / FIXED_UNITS);
    const made = scene.attach(node.id, () => new SiteMarker());
    if (!made.ok) return made;
    made.value.siteId = s.id;
    made.value.kind = s.kind;
    made.value.cell = s.cell;
  }

  scene.flush();

  return ok({
    terrainNodes: rects.length,
    siteNodes: plan.sites.length,
    sceneNodes: scene.stats().nodes,
    cells: width * height,
    rects: rects.length,
    fingerprint: plan.fingerprint,
  });
}

export interface TerrainRaster {
  readonly width: number;
  readonly height: number;
  /** 逐格群系；`null` = 没有任何地形节点覆盖这一格（漏格）。 */
  readonly kinds: readonly (BiomeKind | null)[];
  /** 被多个地形节点覆盖的格子数。>0 说明合并算法产出了重叠矩形（会画两遍、也会掩盖漏格）。 */
  readonly overlaps: number;
  /** 没有被覆盖的格子数。 */
  readonly gaps: number;
}

/**
 * 从场景反查群系栅格。
 *
 * ★ 为什么需要它：装配的"正确"不能靠"我读过代码了"。
 *   合并算法出错有两种典型症状 —— **漏格**（某块地形根本没进场景）和
 *   **重叠**（两块矩形盖同一格，其中一块被画在下面看不出来）。
 *   两者都能让"看起来有地"和"实际有地"不一致，而它们只在把场景还原成栅格时暴露。
 *   所以 `overlaps` 单独计数：若首写优先、只比 `kinds`，重叠会被完全掩盖。
 */
export function rasterizeTerrain(
  scene: Scene,
  width: number,
  height: number,
): Result<TerrainRaster, EngineError> {
  const total = width * height;
  const kinds: (BiomeKind | null)[] = new Array<BiomeKind | null>(total).fill(null);
  let overlaps = 0;

  for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
    for (let dz = 0; dz < area.h; dz++) {
      for (let dx = 0; dx < area.w; dx++) {
        const x = area.cx + dx;
        const z = area.cz + dz;
        if (x < 0 || z < 0 || x >= width || z >= height) {
          return err({
            code: WORLD_BAD_SCENE,
            message: `地形节点越界：(${x}, ${z}) 超出 ${width}x${height}（组件 ${area.kind} ${area.w}x${area.h}@(${area.cx},${area.cz})）`,
          });
        }
        const i = z * width + x;
        if (kinds[i] !== null) {
          overlaps++;
          continue;
        }
        kinds[i] = area.kind;
      }
    }
  }

  let gaps = 0;
  for (let i = 0; i < total; i++) if (kinds[i] === null) gaps++;

  return ok({ width, height, kinds, overlaps, gaps });
}

/**
 * 由装配后的场景反推出"可通行分量数"，用于验证 `passable` 字段真的传过去了。
 *
 * ★★ 这里**刻意**不复用 `findComponents()`，尽管它就在隔壁。
 *   原因是 2026-10-23 抓到的一条假判据：第一版这样写 ——
 *     `walkable[i] = area.passable ? kinds[i] : "ocean"`
 *   然后交给 `findComponents`（它内部再查一次群系表）。于是"某块地形的 passable 写死成
 *   true"这个错误被**抹平**了：海格虽然被标成可通行，但 `findComponents` 又按群系表
 *   把 `ocean` 判成不可通行，分量数一点没变 —— 判据全绿。
 *   根因是输入混了两条来源（场景字段 + 群系表），**分不清是哪一条错了**。
 *   所以这里直接用布尔栅格做 BFS：输入只有场景字段，输出只有分量数，中间没有第三条路。
 *   （重复实现的风险由交叉验证兜住：判据里同时断言它与 `findComponents(plan.kinds)`
 *   给出同一个数 —— 两份实现一旦漂移，那条会先红。）
 */
export function sceneComponents(
  scene: Scene,
  width: number,
  height: number,
): Result<number, EngineError> {
  const raster = rasterizeTerrain(scene, width, height);
  if (!raster.ok) return raster;
  const total = width * height;

  // 逐格 passable：唯一来源就是场景里的组件字段
  const passable = new Int8Array(total).fill(-1);
  for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
    for (let dz = 0; dz < area.h; dz++) {
      for (let dx = 0; dx < area.w; dx++) {
        passable[(area.cz + dz) * width + area.cx + dx] = area.passable ? 1 : 0;
      }
    }
  }

  const seen = new Uint8Array(total);
  let components = 0;
  const stack: number[] = [];
  for (let start = 0; start < total; start++) {
    // 漏格（-1）不假装成海：缺失 ≠ 不适用，直接报错
    if (passable[start] === -1) {
      return err({ code: WORLD_BAD_SCENE, message: `第 ${start} 格没有地形覆盖，无法求连通分量` });
    }
    if (passable[start] !== 1 || seen[start] === 1) continue;

    components++;
    seen[start] = 1;
    stack.length = 0;
    stack.push(start);
    while (stack.length > 0) {
      const cur = stack.pop()!;
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [ox, oz] of [
        [1, 0],
        [-1, 0],
        [0, 1],
        [0, -1],
      ] as const) {
        const nx = cx + ox;
        const nz = cz + oz;
        if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
        const ni = nz * width + nx;
        if (seen[ni] === 1 || passable[ni] !== 1) continue;
        seen[ni] = 1;
        stack.push(ni);
      }
    }
  }
  return ok(components);
}

/**
 * 装配结果的内容指纹：节点树的形状 / 名字 / 定点位置 / 组件数据 / 子节点顺序。
 *
 * ★ id 也进指纹。理由：id 是"两个世界能不能互换存档"的前提（见 Scene 文件头），
 *   而 id 由装配顺序决定 —— 顺序一变 id 就变，这正是要抓的东西。
 *
 * ★ 位置以**定点整数**进指纹：`canonicalize` 拒绝非整数，于是
 *   "位置被除以 1000 而不是 256"会在这里直接报 `CANON.NOT_INTEGER`，
 *   而不是变成"两个指纹碰巧不同"（后者看不出原因）。
 */
/**
 * 内容指纹**排除**的组件前缀。
 *
 * ★★ 为什么（全链路判据逼出来的）：`render.sprite` 里有 `r/g/b` 这种 0..1 的浮点
 *   （群系着色就有 `0.55`），而内容指纹要求"同值同串"，浮点进不去（`CANON.NOT_INTEGER`）。
 *   于是"装配好 + 挂上视觉"的场景**根本算不出指纹** —— 这在写全链路判据之前没人发现，
 *   因为两段各自都只验自己那一半。
 *
 * ★ 排除它不只是"绕过报错"，而是**语义上正确**：世界指纹回答的是"这一局的世界长什么样"，
 *   换个美术风格不该让所有内容 id 失效。呈现参数（帧名/颜色/锚点）属于资产与风格。
 *
 * ★★ 批88 又加了一条 `game.controller`，同一个原因：它的 `speed` 默认 **4.5**，
 *   也是浮点 ⇒ 场景一旦有玩家，指纹就算不出来（全链路两条判据当场红）。
 *   语义上同样站得住：这一层回答的是"世界长什么样"，而移动速度是**手感参数**
 *   （改一下不该让内容 id 全部失效），与呈现参数同类。
 *   代价说清楚：`game.controller.speed` 存档往返丢了不会被这条指纹判据抓住 ——
 *   但 `missingFields` 的断言与 `spawn.test.ts`（玩家身上必须有控制器）各自兜一层。
 */
const DIGEST_EXCLUDE_PREFIXES: readonly string[] = ["render.", "game.controller"];

export function sceneDigest(scene: Scene): Result<string, EngineError> {
  const canon = (n: Node): unknown => {
    const comps = [...n.components]
      .filter((c) => !DIGEST_EXCLUDE_PREFIXES.some((p) => c.type.startsWith(p)))
      .map((c) => c.save())
      .sort((a, b) => String(a.type).localeCompare(String(b.type)));
    return {
      id: n.id,
      name: n.name,
      // y 是 2.5D 的 z 轴（Vec2 只有 x/y 两个分量）
      x: n.localPosition.x * FIXED_UNITS,
      z: n.localPosition.y * FIXED_UNITS,
      components: comps,
      children: n.children.map(canon),
    };
  };
  return fingerprintOf(canon(scene.root));
}
