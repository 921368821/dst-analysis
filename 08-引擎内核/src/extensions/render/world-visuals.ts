/**
 * L4 · 世界的可见化（把 `world.terrain` / `world.site` / `world.resource` 变成 `render.sprite`）
 *
 * 装配与任务模块造出来的是**逻辑**节点：它们有位置、有组件、能被查询，但渲染模块
 * 只认 `render.sprite`。这个文件是两者之间唯一的桥。
 *
 * ★ 为什么放在 render 而不是 worldgen：方向是"渲染认识世界数据"，不是"世界认识渲染"。
 *   反过来放会让世界生成依赖一套图形术语，而生成要能在无渲染的环境里跑（指纹、批量出图）。
 *
 * ★★ 为什么帧名检查必须在**动场景之前**做，且缺失时**报错**：
 *   渲染模块遇到不存在的帧名是 `warn` + 跳过（那是对的，它不该因为一个坏资产就停掉整帧）。
 *   但在这里，"某种资源没有对应帧"是一个**配置错误**：画面上少了一类东西，
 *   日志里只有一行 warn，玩家只会觉得"这游戏好像少了点什么"。
 *   所以这个入口把"缺帧"升级成错误，并列出缺的是哪几个 —— 换真图集时它就是闸门。
 *
 * ★★ 地形（`world.terrain`）怎么画：灰度基色 + 群系着色，锚点取 (0,0)。
 *   地形节点是**矩形**（w×h 格），位置是矩形左上角的格子坐标。因此：
 *     · `pivotX = 0, pivotY = 0` —— 左边界与底边都贴住节点位置，矩形恰好覆盖
 *       `[cx, cx+w) × [cz, cz+h)`。这正是 `Sprite.pivotX` 存在的理由；
 *     · 帧用中性灰的 `terrain`，颜色由 `BIOME_TINT` 乘上去 —— 一张灰度图 × 8 个色
 *       表示 8 种群系。底色若是草绿，海会变成"绿 × 蓝 = 墨绿"，而那种错法看起来
 *       还挺"自然"，没人会想到是基色错了。
 *
 * ★★ T288：地形走**瓦片页**（`terrain.tile`），按格平铺。
 *   原来一块矩形是一个精灵、64×64 的噪点被拉伸到整块上，大块地形的颗粒明显变粗。
 *   现在 `tileX/tileY = 矩形格数`，每格铺一张噪点 —— 颗粒与块大小无关。
 *   ⚠ 平铺必须落在 `wrap: repeat` 的**独立页**上（见 `buildTilePages`）：
 *   在主图集上平铺会把邻居帧采进来，画面是"每隔几格出现一块树"。
 */

import { SPRITE_TYPE, Sprite } from "./sprite.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { BiomeKind, SiteKind } from "../worldgen/worldgen.ts";
import { SITE_TYPE, TERRAIN_TYPE, SiteMarker, TerrainArea } from "../worldgen/assemble.ts";
import { RESOURCE_TYPE, ResourceMarker } from "../worldgen/task-module.ts";

/** 缺帧：需要的帧名不在可用图集里。 */
export const VISUAL_MISSING_FRAME = "VISUAL.MISSING_FRAME";
/** 组件注册表里没有 `render.sprite`（渲染模块没启动 / 没注册）。 */
export const VISUAL_NO_SPRITE_COMPONENT = "VISUAL.NO_SPRITE_COMPONENT";
/** 报错时用来指代"这个种类没有帧映射"（而不是把 `undefined` 打进日志）。 */
const UNMAPPED_LABEL = "（未映射的种类）";

/**
 * 资源种类 → 图集帧名。
 *
 * ★ 这是一张**临时的**映射：程序化图集里只有 `tree / rock / berry / player / ground / terrain`
 *   六帧，没有 `flint / grass_tuft / reed`。所以三类暂时复用别的帧。
 *   映射集中在这一处，换成真资产时**只改这张表**（判据会自动跟着走：
 *   它不写死帧名，而是断言"每个种类映射到的帧都在可用图集里"）。
 */
export const SITE_FRAMES: Readonly<Record<SiteKind, string>> = {
  tree: "tree",
  rock: "rock",
  berry: "berry",
  flint: "rock",
  grass_tuft: "berry",
  reed: "berry",
};

/** 地形用的帧（中性灰，颜色来自 `BIOME_TINT`）。 */
export const TERRAIN_FRAME = "terrain";

/**
 * 地形平铺用的**页名**（T288）。
 *
 * ★ 为什么是一个常量而不是字面量：`world-visuals` 写页名、渲染模块建页名、
 *   判据读页名 —— 三处各写一遍 `"terrain.tile"` 就是三次打错的机会。
 */
export const TERRAIN_TILE_PAGE = "terrain.tile";

/**
 * 群系 → 顶点色（与灰度底相乘）。
 *
 * ★ 写在这里而不是 worldgen：这是**呈现**决定，不是世界的事实。
 *   换一套美术风格时该整张替换，而世界生成不该跟着动。
 */
export const BIOME_TINT: Readonly<Record<BiomeKind, readonly [number, number, number]>> = {
  ocean: [0.16, 0.32, 0.55],
  beach: [0.85, 0.78, 0.55],
  grass: [0.42, 0.62, 0.30],
  forest: [0.24, 0.46, 0.26],
  rocky: [0.52, 0.50, 0.48],
  cliff: [0.38, 0.36, 0.40],
  savanna: [0.72, 0.66, 0.36],
  marsh: [0.36, 0.44, 0.38],
};

export interface WorldVisualReport {
  readonly terrain: number;
  readonly sites: number;
  readonly resources: number;
  /** 实际用到的帧名（去重、升序）。换图集时拿它与图集帧表对一下就知道有没有漏。 */
  readonly frames: readonly string[];
  /** 已经有了 Sprite、这次跳过的节点数（幂等性的证据）。 */
  readonly skipped: number;
}

interface VisualPlan {
  readonly nodeId: number;
  /** `null` = 这个种类没有帧映射（存档里带着本版本不认识的种类）。 */
  readonly frame: string | null;
  /** 图集页（空 = 主图集）。地形用瓦片页（T288）。 */
  readonly atlasId: string;
  /** 诊断用：`terrain:ocean` / `site:tree` / `resource:berry`。 */
  readonly kind: string;
  readonly width: number;
  readonly height: number;
  /** 绘制层：地形 = 0（背景），投放点/资源 = 1（实体）。见 `Sprite.layer`。 */
  readonly layer: number;
  /** 沿宽重复贴图次数（默认 1）。 */
  readonly tileX: number;
  /** 沿高重复贴图次数（默认 1）。 */
  readonly tileY: number;
  readonly pivotX: number;
  readonly pivotY: number;
  readonly r: number;
  readonly g: number;
  readonly b: number;
}

function hasSprite(s: Scene, nodeId: number): boolean {
  // 直接看节点上的组件：`countOf` 只能给总数，判断不了"这一个有没有"
  const node = s.find(nodeId);
  return node?.get(SPRITE_TYPE) !== undefined;
}

/**
 * 给场景里所有地形块、投放点与再生资源挂上 Sprite。
 *
 * ★ 幂等：已经有 Sprite 的节点跳过并计数。
 *   不加这个判断的后果不是"画两次"那么简单 —— 两个 Sprite 各画一遍会让半透明资源的
 *   颜色变深一倍，看起来像"这个资源的贴图颜色不对"，而组件数只是静默翻倍。
 */
export function attachWorldVisuals(scene: Scene, availableFrames: readonly string[]): Result<WorldVisualReport, EngineError> {
  const plans: VisualPlan[] = [];

  for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
    if (area.node === null) continue;
    const tint = BIOME_TINT[area.kind];
    plans.push({
      nodeId: area.node.id,
      frame: TERRAIN_FRAME,
      atlasId: TERRAIN_TILE_PAGE,
      kind: `terrain:${area.kind}`,
      width: area.w,
      height: area.h,
      // ★ 背景层：地面永远先画、永远被实体盖住。地形的 z 是矩形左上角的格子坐标，
      //   与实体（格子中心）必然交错 —— 不分层会被一块地形盖住站在它上面的角色，
      //   而且 draw 会被 z 序打散成几十段（T288 之后实测 29 段）。
      layer: 0,
      // ★ T288：按格平铺 —— 一块 w×h 的地形铺 w×h 张噪点，颗粒不随块变大。
      //   必须是整数：0.5 次平铺在 GPU 上就是"半张被裁掉的贴图"，
      //   而矩形格数天生是整数（`TerrainArea` 的 w/h 是格子数）。
      tileX: Math.max(1, Math.floor(area.w)),
      tileY: Math.max(1, Math.floor(area.h)),
      // ★ (0,0)：矩形左上角 = 节点位置。用 0.5 会让整块地形右移半块、上移半块 ——
      //   相邻块之间于是出现缝隙，而"缝隙"在 2.5D 斜视角下看起来像地表裂开了。
      pivotX: 0,
      pivotY: 0,
      r: tint[0],
      g: tint[1],
      b: tint[2],
    });
  }

  for (const m of scene.componentsOf<SiteMarker>(SITE_TYPE)) {
    if (m.node === null) continue;
    plans.push({
      nodeId: m.node.id,
      frame: SITE_FRAMES[m.kind] ?? null,
      atlasId: "",
      kind: `site:${m.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      // 脚踩地面：2.5D 里精灵的底边贴住它所在的格
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1,
    });
  }
  for (const res of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    if (res.node === null) continue;
    plans.push({
      nodeId: res.node.id,
      frame: SITE_FRAMES[res.kind] ?? null,
      atlasId: "",
      kind: `resource:${res.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1,
    });
  }

  // ★ 先整体检查帧，再动场景：报错时不该留下"挂了一半"的场景
  const available = new Set(availableFrames);
  const missing = new Map<string, Set<string>>();
  for (const p of plans) {
    if (p.frame !== null && available.has(p.frame)) continue;
    const key = p.frame ?? UNMAPPED_LABEL;
    const set = missing.get(key) ?? new Set<string>();
    set.add(p.kind);
    missing.set(key, set);
  }
  if (missing.size > 0) {
    const detail = [...missing.entries()]
      .sort((a, b) => (a[0] < b[0] ? -1 : 1))
      .map(([frame, kinds]) => `${frame}（被 ${[...kinds].sort().join(", ")} 用到）`)
      .join("；");
    return err(
      engineError(
        VISUAL_MISSING_FRAME,
        `图集里没有这些帧：${detail} —— 缺帧的资源会**静默不显示**（渲染模块只 warn 一次），所以在这里报错`,
      ),
    );
  }

  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        VISUAL_NO_SPRITE_COMPONENT,
        "组件类型 render.sprite 未注册 —— 先 components.register(...)（渲染模块启动时会注册）",
      ),
    );
  }

  let terrain = 0;
  let sites = 0;
  let resources = 0;
  let skipped = 0;
  const used = new Set<string>();

  for (const p of plans) {
    if (hasSprite(scene, p.nodeId)) {
      skipped++;
      continue;
    }
    const frame = p.frame;
    // 不可达：上面只要有 null 就已经 `return err`。写成 `throw` 而不是 `continue`，
    // 是为了万一有人改坏了上面的检查时**当场炸**，而不是静默少挂一个（画面上只是少一样东西）。
    if (frame === null) throw new Error(`world-visuals 内部错误：${p.kind} 的帧映射在检查之后变成了 null`);
    const made = scene.attach(p.nodeId, () => {
      const sp = new Sprite();
      sp.frame = frame;
      sp.atlasId = p.atlasId;
      sp.tileX = p.tileX;
      sp.tileY = p.tileY;
      sp.layer = p.layer;
      sp.width = p.width;
      sp.height = p.height;
      sp.pivotX = p.pivotX;
      sp.pivotY = p.pivotY;
      sp.r = p.r;
      sp.g = p.g;
      sp.b = p.b;
      return sp;
    });
    if (!made.ok) return made;
    used.add(frame);
    if (p.kind.startsWith("terrain:")) terrain++;
    else if (p.kind.startsWith("site:")) sites++;
    else resources++;
  }
  scene.flush();

  return ok({
    terrain,
    sites,
    resources,
    frames: [...used].sort(),
    skipped,
  });
}
