/**
 * L4 · 世界可见化测试（`world.site` / `world.resource` → `render.sprite`）
 *
 * `assemble.test.ts` 验「场景里的逻辑数据对不对」，本文件验**画面上有没有**。
 * 这两件事分开验的理由与前几批同源，但这里多一条更尖锐的：
 *   渲染模块遇到不存在的帧名是 `warn` + 跳过。所以「帧名写错 / 图集里没这帧」
 *   在整条链路上**没有任何判据会红** —— 画面只是少了一类东西，
 *   而日志里那行 warn 没人看。本文件就是那条缺失的判据。
 *
 * ★★ 本文件的重点不是「挂上了」，而是**三个静默失效**：
 *   ① 缺帧 → 资源不显示，但整个过程返回成功；
 *   ② 不幂等 → 同一个节点两个 Sprite，半透明贴图颜色深一倍，而组件数只是静默翻倍；
 *   ③ 幂等写成「只要有 Sprite 就全跳过」→ 存档里已有一半可视化的场景，另一半永远不挂。
 *   第 ③ 条最容易写错：`countOf(SPRITE_TYPE) > 0` 读起来完全像是在检查「挂过没有」。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger } from "../../src/foundation/log/logger.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { generateWorld, type BiomeKind, type SiteKind, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import {
  SITE_TYPE,
  TERRAIN_TYPE,
  SiteMarker,
  TerrainArea,
  assembleWorld,
  registerWorldComponents,
} from "../../src/extensions/worldgen/assemble.ts";
import { saveScene, loadScene } from "../../src/core/scene/scene-io.ts";
import { WORLD_TASK_SCHEMA, type WorldTaskTable } from "../../src/extensions/worldgen/tasks.ts";
import {
  RESOURCE_TYPE,
  ResourceMarker,
  createWorldTaskModule,
  registerResourceComponent,
} from "../../src/extensions/worldgen/task-module.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { registerCorpseComponent, spawnCorpse } from "../../src/extensions/combat/corpse.ts";
import { buildProceduralAtlas } from "../../src/extensions/render/atlas.ts";
import { spriteToRenderItem } from "../../src/extensions/render/render-module.ts";
import {
  BIOME_TINT,
  SITE_FRAMES,
  TERRAIN_FRAME,
  VISUAL_MISSING_FRAME,
  VISUAL_NO_SPRITE_COMPONENT,
  attachWorldVisuals,
} from "../../src/extensions/render/world-visuals.ts";

const FD = 1 / 30;
const ALL_KINDS: readonly SiteKind[] = ["tree", "berry", "rock", "flint", "grass_tuft", "reed"];

/**
 * ★ `maxSitesPerCell` 的两个用途：
 *   - 2（默认）：铺满投放点 —— 验「计划里的投放点也能被可视化」；
 *   - 0：图上没有任何投放点 —— 验「再生资源也能被可视化」（否则会被投放点淹没）。
 */
function makeWorld(seed = 7, width = 32, height = 24, maxSitesPerCell = 2): { scene: Scene; plan: WorldPlan } {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed, width, height, maxSitesPerCell });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok, a.ok ? "" : `装配失败：${a.error.code} ${a.error.message}`);
  return { scene, plan: g.value };
}

/** 注册表里**故意**没有 `render.sprite`：模拟「渲染模块没启动就来挂可视化」。 */
function sceneWithoutSprite(): Scene {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 16, height: 12, maxSitesPerCell: 2 });
  assert.ok(g.ok);
  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok);
  return scene;
}

/** 程序化图集现在能提供的帧（**真**图集的帧表，不是这里手写一份帧名列表）。 */
function atlasFrames(): string[] {
  return [...buildProceduralAtlas().frames.keys()];
}

/** 最小模块上下文：只用到 `log`，其余给占位（真平台会把 gfx 拖进判据，与主题无关）。 */
function makeCtx(): ModuleContext {
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services: new ServiceRegistry(),
    platform: {} as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

function tableOf(picksPerRun: number, biomes: readonly BiomeKind[]): WorldTaskTable {
  return {
    schema: WORLD_TASK_SCHEMA,
    tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun, biomes }],
  };
}

/**
 * 在无投放点的世界里刷一批再生资源，返回场景（用于「再生资源也被可视化」的三条判据）。
 * ★ `IModule.init` 的返回类型是 `void | Result | Promise<...>`（允许「不会失败」的模块直接不返回），
 *   所以要先把 Promise 与 void 两种分支摘掉，才能读 `.ok`。
 */
function withRegenerated(plan: WorldPlan, scene: Scene, picksPerRun: number): Scene {
  const mod = createWorldTaskModule({ tasks: tableOf(picksPerRun, ["grass"]), plan, scene });
  const r = mod.init(makeCtx());
  assert.ok(!(r instanceof Promise), "世界任务模块的 init 不该是异步的");
  if (r !== undefined) assert.ok(r.ok, r.ok ? "" : `init 失败：${r.error.code} ${r.error.message}`);
  mod.start?.();
  mod.update(10, FD);
  return scene;
}

function resources(scene: Scene): ResourceMarker[] {
  return [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
}

function terrains(scene: Scene): TerrainArea[] {
  return [...scene.componentsOf<TerrainArea>(TERRAIN_TYPE)];
}

// ── ① 真接线 ──────────────────────────────────────────────────

test("★ 真接线：装配出来的投放点全都有 render.sprite，帧名 = SITE_FRAMES[kind]", () => {
  const { scene } = makeWorld();
  const markers = [...scene.componentsOf<SiteMarker>(SITE_TYPE)];
  assert.ok(markers.length > 100, `这张图只有 ${markers.length} 个投放点，判据分辨力不足`);

  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.sites, markers.length);
  assert.equal(r.value.resources, 0);
  // ★ 组件总数要把地形块算进去：这一批之后"场景里所有 Sprite"不再等于"所有投放点"
  assert.equal(r.value.terrain, terrains(scene).length);
  assert.equal(scene.countOf(SPRITE_TYPE), markers.length + terrains(scene).length);

  for (const m of markers) {
    const sp = m.node!.get<Sprite>(SPRITE_TYPE);
    assert.ok(sp !== undefined, `格子 ${m.cell} 的 ${m.kind} 没挂上 Sprite —— 画面上看不到`);
    assert.equal(sp.frame, SITE_FRAMES[m.kind], `格子 ${m.cell} 的 ${m.kind} 挂错了帧`);
  }
});

test("再生资源同样会被可视化（不只是计划里带的投放点）", () => {
  const { scene, plan } = makeWorld(7, 32, 24, 0);
  assert.equal(scene.countOf(SITE_TYPE), 0, "这张图本来就该没有投放点");
  withRegenerated(plan, scene, 4);
  assert.equal(resources(scene).length, 4);

  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.sites, 0);
  assert.equal(r.value.resources, 4);
  for (const res of resources(scene)) {
    const sp = res.node!.get<Sprite>(SPRITE_TYPE);
    assert.ok(sp !== undefined, `再生出来的 ${res.kind} 没挂上 Sprite`);
    assert.equal(sp.frame, SITE_FRAMES[res.kind]);
  }
});

test("frames 只列**实际用到的**帧（不是把 availableFrames 原样回传）", () => {
  const { scene, plan } = makeWorld(7, 32, 24, 0);
  withRegenerated(plan, scene, 3);
  // 全 grass 图上只刷浆果 ⇒ 只有 berry 与地形帧被用到，尽管图集里还有 tree / rock / player / ground
  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(r.ok);
  assert.deepEqual([...r.value.frames], [TERRAIN_FRAME, "berry"].sort());
});

// ── ② 缺帧：从「一行 warn」升级成错误 ──────────────────────────

test("★ 缺帧报 VISUAL.MISSING_FRAME，消息里说清缺哪帧、被哪些种类用到", () => {
  const { scene } = makeWorld();
  // 只给 tree：这张图上还有 berry / rock / …
  const r = attachWorldVisuals(scene, ["tree"]);
  assert.ok(!r.ok);
  if (r.ok) return;
  assert.equal(r.error.code, VISUAL_MISSING_FRAME);
  assert.match(r.error.message, /berry|rock/, "没说缺哪个帧");
  assert.match(r.error.message, /site:/, "没说这个帧被哪些种类用到 —— 换图集时没法定位");
});

test("★★ 缺帧时一个组件都不挂（不留「挂了一半」的场景）", () => {
  const { scene } = makeWorld();
  const nodesBefore = scene.stats().nodes;
  const r = attachWorldVisuals(scene, ["tree"]);
  assert.ok(!r.ok);
  assert.equal(scene.countOf(SPRITE_TYPE), 0, "报错之后场景里已经有 Sprite 了 —— 调用方拿到的是半成品");
  assert.equal(scene.stats().nodes, nodesBefore, "节点数变了");
});

test("存档里带着本版本不认识的种类 ⇒ 报「未映射的种类」，不是把 undefined 打进日志", () => {
  const { scene } = makeWorld(7, 16, 12, 2);
  const m = [...scene.componentsOf<SiteMarker>(SITE_TYPE)][0]!;
  // 模拟版本漂移：旧存档里有一个新版本已经删掉的种类
  (m as unknown as { kind: string }).kind = "ancient_tree";
  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(!r.ok);
  if (r.ok) return;
  assert.equal(r.error.code, VISUAL_MISSING_FRAME);
  assert.match(r.error.message, /未映射/, "缺的是**映射**，不是帧 —— 报错该这么说");
  assert.match(r.error.message, /ancient_tree/, "没说出是哪个种类");
  assert.ok(!/undefined/.test(r.error.message), "把 undefined 打进了日志");
});

test("注册表里没有 render.sprite ⇒ VISUAL_NO_SPRITE_COMPONENT", () => {
  const scene = sceneWithoutSprite();
  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(!r.ok);
  if (r.ok) return;
  assert.equal(r.error.code, VISUAL_NO_SPRITE_COMPONENT);
  assert.match(r.error.message, /render\.sprite/);
});

// ── ③ 幂等 ────────────────────────────────────────────────────

test("★ 幂等：跑两次不重复挂，第二次全部进 skipped", () => {
  const { scene } = makeWorld();
  const first = attachWorldVisuals(scene, atlasFrames());
  assert.ok(first.ok);
  const countAfterFirst = scene.countOf(SPRITE_TYPE);
  assert.ok(countAfterFirst > 100);

  const second = attachWorldVisuals(scene, atlasFrames());
  assert.ok(second.ok);
  assert.equal(second.value.sites, 0);
  assert.equal(second.value.resources, 0);
  assert.equal(second.value.skipped, countAfterFirst, "第二次没有把已有的都跳过");
  assert.equal(scene.countOf(SPRITE_TYPE), countAfterFirst, "组件数翻倍了 —— 半透明资源会深一倍");
  assert.deepEqual([...second.value.frames], [], "没挂东西却报告用到了帧");
});

test("★★ 幂等是按节点判断的：只有一部分已有 Sprite 时，其余照挂", () => {
  const { scene } = makeWorld();
  const markers = [...scene.componentsOf<SiteMarker>(SITE_TYPE)];
  assert.ok(markers.length >= 3);

  // 手工给头两个节点挂上（模拟「存档里已有一半做过可视化」）
  const handmade = markers.slice(0, 2);
  for (const m of handmade) {
    scene.attach(m.node!.id, () => {
      const sp = new Sprite();
      sp.frame = "player"; // 故意用一个不该被覆盖的帧名
      return sp;
    });
  }
  scene.flush();

  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(r.ok);
  assert.equal(r.value.skipped, 2, "skipped 该等于「已有 Sprite 的节点数」，不是「有没有 Sprite」");
  assert.equal(
    r.value.sites,
    markers.length - 2,
    "把已经有 Sprite 的节点当成「全都挂过了」—— 剩下的永远不显示",
  );
  assert.equal(scene.countOf(SPRITE_TYPE), markers.length + terrains(scene).length);

  for (const m of handmade) {
    assert.equal(m.node!.get<Sprite>(SPRITE_TYPE)!.frame, "player", "覆盖了已有的 Sprite");
  }
});

// ── ④ Sprite 字段 ─────────────────────────────────────────────

test("Sprite 的字段：1×1、pivotY=0（脚踩地面）、可见", () => {
  const { scene } = makeWorld();
  assert.ok(attachWorldVisuals(scene, atlasFrames()).ok);
  const sprites = [...scene.componentsOf<SiteMarker>(SITE_TYPE)].map((m) => m.node!.get<Sprite>(SPRITE_TYPE));
  assert.ok(sprites.length > 0);
  for (const sp of sprites) {
    assert.ok(sp !== undefined);
    assert.equal(sp.width, 1);
    assert.equal(sp.height, 1);
    assert.equal(sp.pivotY, 0, "pivotY 不是 0 —— 精灵会以格子中心为锚，浮在半空");
    assert.equal(sp.visible, true);
  }
});

// ── ④b 地形（矩形 → 一个精灵，锚点 (0,0)） ─────────────────────

test("★ 每个地形块都有 Sprite：尺寸 = w×h、锚点 = (0,0)（矩形恰好覆盖格子）", () => {
  const { scene } = makeWorld(7, 32, 24, 2);
  const blocks = terrains(scene);
  assert.ok(blocks.length > 0);

  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.terrain, blocks.length);

  for (const area of blocks) {
    const sp = area.node!.get<Sprite>(SPRITE_TYPE);
    assert.ok(sp !== undefined, `地形块 (${area.cx},${area.cz}) 没挂 Sprite —— 那一片地表是空的`);
    assert.equal(sp.frame, TERRAIN_FRAME);
    assert.equal(sp.width, area.w, `宽度不是 w：块会盖不住右边界`);
    assert.equal(sp.height, area.h, `高度不是 h：块会盖不住下边界`);
    assert.equal(sp.pivotX, 0, "pivotX 不是 0 —— 整块地形会右移半块，相邻块之间裂开");
    assert.equal(sp.pivotY, 0, "pivotY 不是 0 —— 整块地形会浮起半块");
  }
});

test("地形是**块**不是格：块数远小于格子数（合并生效，否则 4096 个节点）", () => {
  const { scene, plan } = makeWorld(7, 32, 24, 2);
  const blocks = terrains(scene);
  assert.ok(blocks.length < plan.width * plan.height / 2, `${blocks.length} 块 vs ${plan.width * plan.height} 格，没有合并`);
  // 每块覆盖的格子数加起来必须恰好等于全图（不重不漏）
  let covered = 0;
  for (const b of blocks) covered += b.w * b.h;
  assert.equal(covered, plan.width * plan.height);
});

test("★ 群系着色：颜色 = BIOME_TINT[kind]，同群系同色、不同群系不同色", () => {
  const { scene } = makeWorld(7, 32, 24, 2);
  assert.ok(attachWorldVisuals(scene, atlasFrames()).ok);

  const seen = new Map<string, string>();
  for (const area of terrains(scene)) {
    const sp = area.node!.get<Sprite>(SPRITE_TYPE)!;
    const tint = BIOME_TINT[area.kind];
    assert.equal(sp.r, tint[0]);
    assert.equal(sp.g, tint[1]);
    assert.equal(sp.b, tint[2]);
    for (const c of [sp.r, sp.g, sp.b]) assert.ok(c >= 0 && c <= 1, `颜色分量越界：${c}`);
    const key = `${sp.r},${sp.g},${sp.b}`;
    const prev = seen.get(area.kind);
    if (prev !== undefined) assert.equal(prev, key, `${area.kind} 出现了两种颜色`);
    seen.set(area.kind, key);
  }
  assert.ok(new Set(seen.values()).size >= 4, "至少要有 4 种群系颜色不同，否则地图上没有可分的地貌");
  assert.notEqual(
    `${BIOME_TINT.ocean.join()}`,
    `${BIOME_TINT.grass.join()}`,
    "海与草地同色 —— 玩家分不出哪里能走",
  );
});

test("地形也幂等：第二次跑不重复挂", () => {
  const { scene } = makeWorld(7, 32, 24, 2);
  const first = attachWorldVisuals(scene, atlasFrames());
  assert.ok(first.ok);
  const total = scene.countOf(SPRITE_TYPE);
  const second = attachWorldVisuals(scene, atlasFrames());
  assert.ok(second.ok);
  assert.equal(second.value.terrain, 0);
  assert.equal(second.value.skipped, total);
  assert.equal(scene.countOf(SPRITE_TYPE), total);
});

test("★ 地形帧缺失同样报错（换图集时忘了 terrain 帧，整片地表会静默消失）", () => {
  const { scene } = makeWorld(7, 32, 24, 2);
  const frames = atlasFrames().filter((f) => f !== TERRAIN_FRAME);
  const r = attachWorldVisuals(scene, frames);
  assert.ok(!r.ok);
  if (r.ok) return;
  assert.equal(r.error.code, VISUAL_MISSING_FRAME);
  assert.match(r.error.message, new RegExp(TERRAIN_FRAME), "没说缺的是地形帧");
  assert.match(r.error.message, /terrain:/, "没说哪些群系受影响");
  assert.equal(scene.countOf(SPRITE_TYPE), 0, "报错时挂了一半");
});

// ── ④c 存档往返：pivotX 是新字段 ───────────────────────────────

test("★ pivotX 进存档往返：地形读回来锚点仍是 0、投放点仍是 0.5", () => {
  const { scene } = makeWorld(7, 16, 12, 2);
  assert.ok(attachWorldVisuals(scene, atlasFrames()).ok);

  const snap = saveScene(scene);
  const scene2 = new Scene("world", scene.components);
  const loaded = loadScene(scene2, snap, scene2.components);
  assert.ok(loaded.ok);
  assert.deepEqual(loaded.value.missingFields, [], "新格式的存档不该有缺字段");

  for (const area of [...scene2.componentsOf<TerrainArea>(TERRAIN_TYPE)]) {
    const sp = area.node!.get<Sprite>(SPRITE_TYPE);
    assert.ok(sp !== undefined);
    assert.equal(sp.pivotX, 0, "地形锚点在存档往返里丢了 —— 读回来会整体右移半块");
  }
  for (const m of scene2.componentsOf<SiteMarker>(SITE_TYPE)) {
    assert.equal(m.node!.get<Sprite>(SPRITE_TYPE)!.pivotX, 0.5, "投放点的水平锚点丢了");
  }
});

test("★★ 旧存档（没有 pivotX 字段）读出来是 0.5，不是 0 —— 并且缺字段要被报出来", () => {
  const { scene } = makeWorld(7, 16, 12, 2);
  assert.ok(attachWorldVisuals(scene, atlasFrames()).ok);
  const snap = saveScene(scene);

  // 模拟"这一批之前存下来的档"：把 pivotX 从每个 render.sprite 里删掉
  let removed = 0;
  for (const n of snap.nodes) {
    for (const c of n.components) {
      if (c.type !== SPRITE_TYPE) continue;
      const data = c.data as Record<string, unknown>;
      if (data.pivotX !== undefined) {
        delete data.pivotX;
        removed++;
      }
    }
  }
  assert.ok(removed > 0, "存档里没有 pivotX —— 上一条判据可能没真的把它存进去");

  const scene2 = new Scene("world", scene.components);
  const loaded = loadScene(scene2, snap, scene2.components);
  assert.ok(loaded.ok);
  assert.ok(
    loaded.value.missingFields.some((f) => f.endsWith(".pivotX")),
    `缺字段没被报出来：${loaded.value.missingFields.join(", ")}`,
  );
  for (const m of scene2.componentsOf<SiteMarker>(SITE_TYPE)) {
    const sp = m.node!.get<Sprite>(SPRITE_TYPE)!;
    // ★ 0.5 是类里的默认值。如果哪天有人把默认值改成 0（"反正新内容都会显式赋值"），
    //   所有旧存档里的精灵都会右移半格 —— 而新存档完全正常，看判据永远发现不了。
    assert.equal(sp.pivotX, 0.5, "旧存档的 pivotX 落到了 0 而不是默认值 0.5");
  }
});

// ── ④d 搬运：组件 → 渲染项（中间那一行） ───────────────────────

test("★★ 搬运不丢字段：地形 Sprite 的 pivotX/尺寸/颜色真的到了 RenderItem", () => {
  const { scene } = makeWorld(7, 16, 12, 2);
  assert.ok(attachWorldVisuals(scene, atlasFrames()).ok);

  const atlas = buildProceduralAtlas();
  const frame = atlas.frames.get(TERRAIN_FRAME)!;
  const area = terrains(scene).find((a) => a.w > 1 && a.h > 1);
  assert.ok(area !== undefined, "没有大于 1×1 的地形块，判据分辨力不足");
  const sp = area!.node!.get<Sprite>(SPRITE_TYPE)!;

  const item = spriteToRenderItem(sp, frame, 7, 3, 5, 0);
  assert.equal(item.pivotX, 0, "pivotX 在搬运时丢了 —— 地形右移半块，而组件上看起来是对的");
  assert.equal(item.pivotY, 0);
  assert.equal(item.w, area!.w);
  assert.equal(item.h, area!.h);
  assert.equal(item.r, sp.r);
  assert.equal(item.g, sp.g);
  assert.equal(item.b, sp.b);
  assert.equal(item.u0, frame.u0);
  assert.equal(item.x, 3);
  assert.equal(item.z, 5);
});

// ── ⑤ 映射表自身 ──────────────────────────────────────────────

test("★ SITE_FRAMES 的每个值都在**真**的程序化图集里（换图集时这条就是闸门）", () => {
  const frames = new Set(atlasFrames());
  assert.ok(frames.size >= 5, `图集只有 ${frames.size} 帧，判据分辨力不足`);
  for (const kind of ALL_KINDS) {
    const frame: string | undefined = SITE_FRAMES[kind];
    assert.ok(frame !== undefined, `${kind} 没有帧映射 —— 它会静默不显示`);
    assert.ok(frames.has(frame), `${kind} 映射到 ${frame}，但图集里没有这一帧`);
  }
});

test("SITE_FRAMES 覆盖全部 SiteKind（键集合与种类全集相等）", () => {
  assert.deepEqual(Object.keys(SITE_FRAMES).sort(), [...ALL_KINDS].sort());
});

// ── ⑥ 边界 ────────────────────────────────────────────────────

test("空场景：ok、全 0、frames 为空（不是报错）", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("empty", reg);
  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.sites, 0);
  assert.equal(r.value.resources, 0);
  assert.equal(r.value.skipped, 0);
  assert.deepEqual([...r.value.frames], []);
});

test("★ 空场景 + 组件未注册 ⇒ 仍然报错（配置错误不因为「现在没东西可画」而静默）", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  const scene = new Scene("empty", reg);
  const r = attachWorldVisuals(scene, atlasFrames());
  assert.ok(!r.ok, "组件没注册却报成功 —— 等下次刷出资源时才炸，那时已经离现场很远了");
  if (r.ok) return;
  assert.equal(r.error.code, VISUAL_NO_SPRITE_COMPONENT);
});

test("★★ 尸体也会被挂上精灵（carcass 帧），且重复调用不叠", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerCorpseComponent(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("corpse-visual", reg);
  const g = generateWorld({ seed: 7, width: 16, height: 12, maxSitesPerCell: 0 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);
  const nav = NavGrid.fromPlan(g.value);
  assert.ok(nav.ok, nav.ok ? "" : `导航网格建不起来：${nav.error.code}`);
  let cell = -1;
  for (let i = 0; i < nav.value.total; i++) {
    if (nav.value.isWalkableIndex(i)) {
      cell = i;
      break;
    }
  }
  assert.ok(cell >= 0, "世界里一格可走的地方都没有 —— 判据前提不成立");
  const c = nav.value.centerOf(cell);
  const made = spawnCorpse(scene, [{ kind: "meat", count: 2 }], { ground: nav.value, x: c.x, z: c.z, nowTick: 0 });
  assert.ok(made.ok, made.ok ? "" : `生成尸体失败：${made.error.code}`);

  const frames = atlasFrames();
  // ★ 前置：帧真的在**真图集**里（不是这里手写一份帧名表）
  assert.ok(frames.includes("carcass"), `程序化图集里没有 carcass 帧：${frames.join(", ")}`);

  const r1 = attachWorldVisuals(scene, frames);
  assert.ok(r1.ok, r1.ok ? "" : `挂可视化失败：${r1.error.code}`);
  // ★ 只验「没报错」是不够的：尸体不在计划里，漏掉它时函数照样成功返回。
  assert.equal(r1.value.corpses, 1, "尸体没有挂精灵 —— 画面上就是不存在（而它明明在世界里）");
  const sp = scene.find(made.value.nodeId)?.get<Sprite>(SPRITE_TYPE);
  assert.ok(sp !== undefined, "尸体节点上没有 render.sprite");
  assert.equal(sp!.frame, "carcass", "尸体的帧名不对（换图集时这里会先红）");

  // 幂等：再挂一次不叠（尸体是运行期反复出现的，这条路径一定会被走第二遍）
  const sprites = scene.countOf(SPRITE_TYPE);
  const r2 = attachWorldVisuals(scene, frames);
  assert.ok(r2.ok);
  assert.equal(r2.value.corpses, 0, "第二次调用又给同一具尸体挂了一个精灵");
  assert.ok(r2.value.skipped >= 1, "跳过的计数没涨 —— 幂等是靠「有精灵就跳过」实现的");
  assert.equal(scene.countOf(SPRITE_TYPE), sprites, "精灵数变了：同一个尸体被挂了两次");
});
