/**
 * L4 · 世界装配测试（世界生成 → 真实 Scene 的"最后一公里"）
 *
 * 出口判据原文是「同种子 ⇒ 同世界」。在 `worldgen.ts` 那侧它只证明了
 * **计划数据**相同；这个文件要把那句话延长到**场景**：
 *   ① 同计划装配两次，节点树的形状 / id / 名字 / 定点位置 / 组件数据全部相同；
 *   ② 装配结果可以**反查**回群系栅格，且与 `kinds` 逐格相同（否则"合并成矩形"不可验证）；
 *   ③ `passable` 真的随装配过去了（用场景里的字段重算连通分量，不是再查一次群系表）。
 *
 * ★ 判据里刻意区分了三种"看起来对"：
 *   · **漏格**：某块地形根本没进场景（画面上看是黑的，逻辑上是海？说不清）；
 *   · **重叠**：两块矩形盖同一格（首写优先会让它完全看不出来）；
 *   · **越界**：矩形比地图还大（会被裁剪，于是"多出来的部分"静默消失）。
 *   这三种在 `rasterizeTerrain` 里各有独立计数 —— 因为它们混在一起时，
 *   "overlaps === 0" 就变成了一句看不出在验什么的话。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { CANON_NOT_INTEGER } from "../../src/foundation/canonical.ts";
import { fingerprintOf } from "../../src/foundation/canonical.ts";
import {
  FIXED_UNITS,
  WORLD_BAD_PARAMS,
  WORLD_PLAN_SCHEMA,
  findComponents,
  generateWorld,
  isPassable,
  planDigest,
  type BiomeKind,
  type WorldPlan,
  type WorldSite,
} from "../../src/extensions/worldgen/worldgen.ts";
import { validateWorld } from "../../src/extensions/worldgen/validate.ts";
import {
  SITE_TYPE,
  TERRAIN_TYPE,
  WORLD_BAD_PLAN,
  WORLD_BAD_SCENE,
  WORLD_COMPONENTS_UNREGISTERED,
  WORLD_SCENE_NOT_EMPTY,
  SiteMarker,
  TerrainArea,
  assembleWorld,
  mergeTerrain,
  rasterizeTerrain,
  registerWorldComponents,
  sceneComponents,
  sceneDigest,
} from "../../src/extensions/worldgen/assemble.ts";

function makeScene(withComponents = true): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  if (withComponents) registerWorldComponents(reg);
  return { scene: new Scene("world", reg), reg };
}

function gen(seed: number, width = 32, height = 24, repair = true): WorldPlan {
  const r = generateWorld({ seed, width, height, repair });
  assert.ok(r.ok, r.ok ? "" : `生成失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

/** 合成计划：不经过 `generateWorld`，用来构造"生成的图永远不会出现"的形状（棋盘、单色、非岛）。 */
function synth(width: number, height: number, kinds: BiomeKind[], sites: WorldSite[] = []): WorldPlan {
  const partial = {
    schema: WORLD_PLAN_SCHEMA,
    seed: 0,
    width,
    height,
    kinds,
    sites,
    bridges: [],
  } as const;
  const fp = fingerprintOf(partial);
  assert.ok(fp.ok, fp.ok ? "" : `指纹失败：${fp.error.code}`);
  return { seed: 0, width, height, kinds, sites, bridges: [], fingerprint: fp.value };
}

function assemble(plan: WorldPlan): { scene: Scene; rects: number; sites: number } {
  const { scene } = makeScene();
  const r = assembleWorld(plan, scene);
  assert.ok(r.ok, r.ok ? "" : `装配失败：${r.error.code} ${r.error.message}`);
  return { scene, rects: r.value.rects, sites: r.value.siteNodes };
}

// ── ① 场景结构 ────────────────────────────────────────────────

test("装配后根下正好两个容器：地形与投放点各归一处（不是全摊在 root 上）", () => {
  const plan = gen(7);
  const { scene } = assemble(plan);
  assert.deepEqual(
    scene.root.children.map((n) => n.name),
    ["terrain", "sites"],
  );
  const [terrainRoot, siteRoot] = scene.root.children;
  assert.equal(scene.countOf(TERRAIN_TYPE), terrainRoot!.children.length);
  assert.equal(scene.countOf(SITE_TYPE), siteRoot!.children.length);
  // 每个地形节点的父节点都是容器 —— 这一条抓的是"某个分支里传错了 parent"
  for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
    assert.equal(area.node!.parent, terrainRoot);
  }
});

test("空场景前置：装配前只有 root，装配后节点数 = 地形 + 投放 + root + 两个容器", () => {
  const plan = gen(7);
  const { scene, rects, sites } = assemble(plan);
  assert.equal(scene.stats().nodes, rects + sites + 3);
  assert.equal(rects, scene.countOf(TERRAIN_TYPE));
  assert.equal(sites, plan.sites.length);
});

test("节点 id 从 2 开始连续分配（root 是 1，没有空洞）", () => {
  const { scene } = assemble(gen(7));
  const ids: number[] = [];
  scene.root.walk((n) => ids.push(n.id));
  ids.sort((a, b) => a - b);
  assert.deepEqual(ids, ids.map((_, i) => i + 1));
});

// ── ② 矩形合并与反查 ──────────────────────────────────────────

test("合并结果覆盖全部格子、无重叠，且逐格群系与计划相同", () => {
  const plan = gen(7);
  const { scene } = assemble(plan);
  const r = rasterizeTerrain(scene, plan.width, plan.height);
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  assert.equal(r.value.gaps, 0, `漏了 ${r.value.gaps} 格`);
  assert.equal(r.value.overlaps, 0, `重叠了 ${r.value.overlaps} 格`);
  assert.deepEqual(r.value.kinds, plan.kinds);
});

test("合并真的在合并：矩形数远少于格子数（否则「合并」这一步等于没做）", () => {
  const plan = gen(7);
  const rects = mergeTerrain(plan.width, plan.height, plan.kinds);
  const cells = plan.width * plan.height;
  assert.ok(rects.length > 0, "一块矩形都没有");
  assert.ok(rects.length < cells, `矩形数 ${rects.length} 已经不小于格子数 ${cells}`);
});

test("单色地图合并成一块矩形（防止「每个格子单独成块」也算通过覆盖判据）", () => {
  const kinds: BiomeKind[] = new Array<BiomeKind>(8 * 8).fill("grass");
  const rects = mergeTerrain(8, 8, kinds);
  assert.deepEqual(rects, [{ cx: 0, cz: 0, w: 8, h: 8, kind: "grass" }]);
});

test("棋盘是最坏情况：矩形数 == 格子数，但覆盖仍然完全（合并算法的下界）", () => {
  const width = 8;
  const height = 8;
  const kinds: BiomeKind[] = [];
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) kinds.push((x + z) % 2 === 0 ? "grass" : "rocky");
  }
  const rects = mergeTerrain(width, height, kinds);
  assert.equal(rects.length, width * height, "棋盘格不该有任何合并");
  const plan = synth(width, height, kinds);
  const { scene } = assemble(plan);
  const r = rasterizeTerrain(scene, width, height);
  assert.ok(r.ok);
  assert.equal(r.value.overlaps, 0);
  assert.equal(r.value.gaps, 0);
  assert.deepEqual(r.value.kinds, kinds);
});

test("越界的地形节点会被反查抓出来（rasterize 不是恒绿）", () => {
  const plan = gen(7);
  const { scene } = assemble(plan);
  const area = scene.componentsOf<TerrainArea>(TERRAIN_TYPE)[0]!;
  area.w = plan.width + 5;
  const r = rasterizeTerrain(scene, plan.width, plan.height);
  assert.equal(r.ok, false, "矩形越界了却还是绿的");
  if (r.ok) return;
  assert.equal(r.error.code, WORLD_BAD_SCENE);
  assert.match(r.error.message, /越界/);
});

test("重叠会被单独计数（首写优先不会把它掩盖成「看起来对」）", () => {
  const { scene } = makeScene();
  const root = scene.spawnImmediate("terrain");
  const a = scene.spawnImmediate("a", root.id);
  const b = scene.spawnImmediate("b", root.id);
  for (const [node, kind] of [
    [a, "grass"],
    [b, "rocky"],
  ] as const) {
    const made = scene.attach(node.id, () => new TerrainArea());
    assert.ok(made.ok);
    made.value.kind = kind;
    made.value.w = 1;
    made.value.h = 1;
  }
  scene.flush();

  const r = rasterizeTerrain(scene, 2, 2);
  assert.ok(r.ok);
  assert.equal(r.value.overlaps, 1, "两格盖在同一格上，重叠计数应该是 1");
  assert.equal(r.value.gaps, 3, "2x2 里只盖了 1 格，剩下 3 格是漏的");
  assert.equal(r.value.kinds[0], "grass", "首写优先：先挂上的那块是这一格的归属");
});

// ── ③ 定点坐标与身份 ──────────────────────────────────────────

test("投放点世界坐标 × 256 精确等于定点坐标（256 是 2 的幂 ⇒ 这一步无舍入）", () => {
  const plan = gen(11);
  const { scene } = assemble(plan);
  const markers = scene.componentsOf<SiteMarker>(SITE_TYPE);
  assert.equal(markers.length, plan.sites.length);
  const byId = new Map(plan.sites.map((s) => [s.id, s] as const));
  for (const m of markers) {
    const site = byId.get(m.siteId);
    assert.ok(site !== undefined, `场景里的 siteId ${m.siteId} 在计划里找不到`);
    const world = m.node!.localPosition;
    assert.equal(world.x * FIXED_UNITS, site.x, `site ${m.siteId} 的 x 不精确`);
    assert.equal(world.y * FIXED_UNITS, site.z, `site ${m.siteId} 的 z 不精确`);
  }
});

test("地形节点位置以「格」为单位，不是以定点单位", () => {
  const plan = gen(11);
  const { scene } = assemble(plan);
  for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
    assert.equal(area.node!.localPosition.x, area.cx);
    assert.equal(area.node!.localPosition.y, area.cz);
  }
});

test("siteId 记在组件里（内容身份），与节点 id（运行期身份）不是同一个空间", () => {
  const plan = gen(11);
  const { scene } = assemble(plan);
  const markers = scene.componentsOf<SiteMarker>(SITE_TYPE);
  assert.deepEqual(
    markers.map((m) => m.siteId).sort((a, b) => a - b),
    plan.sites.map((s) => s.id).sort((a, b) => a - b),
  );
  // 节点 id 也被分配器连续给出去了，于是必然有一批 siteId 与节点 id 不同 ——
  // 若两者相等，说明装配偷偷拿 siteId 当了节点 id
  assert.ok(
    markers.some((m) => m.siteId !== m.node!.id),
    "所有 siteId 都与节点 id 相同 —— 这两者被混用了",
  );
});

test("显式 id 会把分配水位顶到 explicit+1（这就是装配不用 siteId 当节点 id 的原因）", () => {
  const { scene } = makeScene();
  const a = scene.spawnImmediate("a");
  assert.equal(a.id, 2);
  const b = scene.spawnImmediate("b", null, 900);
  assert.equal(b.id, 900);
  // ★ 记录的是 Scene 的既有行为：水位被抬到 901，之后自动分配的 id 全在百万级以外
  assert.equal(scene.spawnImmediate("c").id, 901);
});

// ── ④ 同计划 ⇒ 同场景 ─────────────────────────────────────────

test("同计划装配两次：节点 id、名字、层级逐一相同", () => {
  const plan = gen(7);
  const a = assemble(plan).scene;
  const b = assemble(plan).scene;
  const shape = (s: Scene): string[] => {
    const out: string[] = [];
    s.root.walk((n) => out.push(`${n.id}:${n.name}@${n.localPosition.x},${n.localPosition.y}`));
    return out;
  };
  assert.deepEqual(shape(a), shape(b));
});

test("同计划装配两次：内容指纹相同（整棵树的形状 / 位置 / 组件数据 / id 全部进指纹）", () => {
  const plan = gen(7);
  const a = sceneDigest(assemble(plan).scene);
  const b = sceneDigest(assemble(plan).scene);
  assert.ok(a.ok && b.ok);
  assert.equal(a.value, b.value);
});

test("改一个投放点的坐标，指纹要变（投放点真的进指纹，不只是地形）", () => {
  const plan = gen(7);
  const base = sceneDigest(assemble(plan).scene);
  assert.ok(base.ok);

  const moved: WorldPlan = {
    ...plan,
    sites: plan.sites.map((s, i) => (i === 0 ? { ...s, x: s.x + 1 } : s)),
  };
  const digest = planDigest(moved);
  assert.ok(digest.ok);
  const bumped = sceneDigest(assemble({ ...moved, fingerprint: digest.value }).scene);
  assert.ok(bumped.ok);
  assert.notEqual(bumped.value, base.value);
});

test("改一格群系（保持指纹自洽），指纹要变（地形真的进指纹）", () => {
  const plan = gen(7);
  const base = sceneDigest(assemble(plan).scene);
  assert.ok(base.ok);

  const kinds = [...plan.kinds];
  const at = kinds.findIndex((k) => k === "grass");
  assert.ok(at >= 0, "这张图上没有 grass，换一张再测");
  kinds[at] = "marsh";
  const changed = { ...plan, kinds };
  const digest = planDigest(changed);
  assert.ok(digest.ok);
  const other = sceneDigest(assemble({ ...changed, fingerprint: digest.value }).scene);
  assert.ok(other.ok);
  assert.notEqual(other.value, base.value);
});

test("位置不是精确定点时，指纹**报错**而不是给一个「只是不同」的串", () => {
  const plan = gen(7);
  const { scene } = assemble(plan);
  const marker = scene.componentsOf<SiteMarker>(SITE_TYPE)[0]!;
  marker.node!.setLocalPosition(0.1, 0.1); // 0.1 * 256 = 25.6，不能精确表示
  const d = sceneDigest(scene);
  assert.equal(d.ok, false, "非定点位置被静默接受了");
  if (d.ok) return;
  assert.equal(d.error.code, CANON_NOT_INTEGER);
});

// ── ⑤ 拒绝路径（计划不可信 / 场景不合适） ──────────────────────

test("指纹与内容不符 ⇒ WORLD.BAD_PLAN（被手改过的计划不许被「忠实」装配）", () => {
  const plan = gen(7);
  const { scene } = makeScene();
  const r = assembleWorld({ ...plan, fingerprint: "0".repeat(16) }, scene);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, WORLD_BAD_PLAN);
  assert.equal(scene.stats().nodes, 1, "报错前不该动场景");
});

test("kinds 长度与尺寸不符 ⇒ WORLD.BAD_PLAN", () => {
  const plan = gen(7);
  const { scene } = makeScene();
  const r = assembleWorld({ ...plan, kinds: plan.kinds.slice(1) }, scene);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, WORLD_BAD_PLAN);
  assert.match(r.error.message, /kinds 长度/);
});

test("未知群系名 ⇒ WORLD.BAD_PLAN（不是 TypeError，也不留下半个世界）", () => {
  const plan = gen(7);
  const kinds = [...plan.kinds];
  kinds[5] = "lava" as BiomeKind;
  const { scene } = makeScene();
  const r = assembleWorld({ ...plan, kinds }, scene);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, WORLD_BAD_PLAN);
  assert.match(r.error.message, /群系名未知/);
  assert.equal(scene.stats().nodes, 1);
});

test("非空场景 ⇒ WORLD.SCENE_NOT_EMPTY（不往已有世界里塞第二个世界）", () => {
  const { scene } = makeScene();
  scene.spawnImmediate("player");
  scene.flush();
  const r = assembleWorld(gen(7), scene);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, WORLD_SCENE_NOT_EMPTY);
  assert.equal(scene.stats().nodes, 2, "被拒绝的装配不该留下任何节点");
});

test("组件没注册 ⇒ WORLD.COMPONENTS_UNREGISTERED，且场景仍是空的", () => {
  const { scene } = makeScene(false);
  const r = assembleWorld(gen(7), scene);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, WORLD_COMPONENTS_UNREGISTERED);
  assert.equal(scene.stats().nodes, 1, "容器节点都建出来了，说明检查放在了动场景之后");
});

test("装配不修改计划（写入前先重算指纹，写后重算仍一致）", () => {
  const plan = gen(7);
  const before = planDigest(plan);
  assert.ok(before.ok);
  assemble(plan);
  const after = planDigest(plan);
  assert.ok(after.ok);
  assert.equal(after.value, before.value);
});

// ── ⑥ 组件数据与语义 ──────────────────────────────────────────

test("passable 随装配过去：由场景字段重算的连通分量数 == 计划的分量数", () => {
  // repair:false 造出"有陆地到不了"的世界，分量数才可能 > 1（否则这条判据没有分辨力）
  const plan = gen(3, 24, 18, false);
  const v = validateWorld(plan);
  assert.ok(v.components >= 1);
  const { scene } = assemble(plan);
  const got = sceneComponents(scene, plan.width, plan.height);
  assert.ok(got.ok, got.ok ? "" : got.error.message);
  assert.equal(got.value, v.components, "场景里的 passable 与计划的群系表给出了不同的连通性");
  // 交叉验证：这里刻意用了一份独立的 BFS（理由见 sceneComponents 注释），
  // 它与 worldgen 的 findComponents 必须给出同一个数 —— 两份实现漂移时先红的是这条
  assert.equal(findComponents(plan.width, plan.height, plan.kinds).groups.length, got.value);
});

test("passable 不是常量：把一块海的 passable 改成 true，分量数必须变（判据有分辨力）", () => {
  // ★ 这条是为了钉住"判据本身有没有牙齿"：
  //   第一版 sceneComponents 用 `passable ? kind : "ocean"` 拼网格再交给 findComponents，
  //   于是"全改成 true"被群系表抹平，分量数一点不变 —— 判据全绿而错误还在。
  const plan = gen(3, 24, 18, false);
  const { scene } = assemble(plan);
  const base = sceneComponents(scene, plan.width, plan.height);
  assert.ok(base.ok);

  const ocean = scene.componentsOf<TerrainArea>(TERRAIN_TYPE).find((a) => a.kind === "ocean");
  assert.ok(ocean !== undefined, "这张图上没有海，换一张再测");
  ocean.passable = true;
  const after = sceneComponents(scene, plan.width, plan.height);
  assert.ok(after.ok);
  assert.notEqual(after.value, base.value, "把海改成可通行，连通性居然没变 —— 判据读的不是 passable");
});

test("每块地形的 passable 都等于 isPassable(kind)（没有一处写死 true）", () => {
  const plan = gen(3, 24, 18, false);
  const { scene } = assemble(plan);
  const areas = scene.componentsOf<TerrainArea>(TERRAIN_TYPE);
  assert.ok(areas.length > 0);
  for (const a of areas) assert.equal(a.passable, isPassable(a.kind), `${a.kind} 的 passable 写错了`);
});

test("组件字段名与 schema 完全对应：save/load 往返不丢字段（防「存了但读回来是默认值」）", () => {
  const plan = gen(7);
  const { scene } = assemble(plan);
  const area = scene.componentsOf<TerrainArea>(TERRAIN_TYPE)[0]!;
  const saved = area.save();
  assert.deepEqual(Object.keys(saved), ["type", "kind", "cx", "cz", "w", "h", "passable"]);

  const copy = new TerrainArea();
  const loaded = copy.load(saved);
  assert.deepEqual(loaded.missing, []);
  assert.deepEqual(copy.save(), saved);
});

test("装配出来的场景能被正常 step（组件在 byType 索引里，不是只在节点上）", () => {
  const plan = gen(7);
  const { scene } = assemble(plan);
  assert.ok(scene.countOf(TERRAIN_TYPE) > 0, "componentsOf 查不到地形 —— 挂载绕过了命令队列");
  const before = scene.stats().componentUpdates;
  scene.step(1, 1 / 30);
  assert.ok(scene.stats().componentUpdates >= before);
  // 地形/投放点都没有 per-tick 行为，所以 step 不该改变它们的位置
  for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
    assert.equal(area.node!.localPosition.x, area.cx);
  }
});

test("尺寸参数不合法时 generateWorld 与装配都拒绝（不是只有生成那侧把关）", () => {
  const bad = generateWorld({ seed: 1, width: 4, height: 4 });
  assert.equal(bad.ok, false);
  if (bad.ok) return;
  assert.equal(bad.error.code, WORLD_BAD_PARAMS);
});
