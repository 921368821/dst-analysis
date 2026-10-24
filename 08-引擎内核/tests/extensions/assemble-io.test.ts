/**
 * L4 · 世界装配的存档往返
 *
 * 「同种子 ⇒ 同世界」这条承诺在**存档**这一步还有一道关：
 * 装配出来的场景必须能存盘、读回、再存出**逐字节相同**的内容，且位置**精确不变**。
 *
 * ★★ 这个文件是被一条真实的精度断裂催生的：
 *   装配把定点坐标写成 `x / 256`（8 位二进制小数，如 `7.26953125`），
 *   而 `scene-io` 的量化函数 `q()` 是 `Math.round(v * 1000) / 1000` —— **十进制 3 位**。
 *   于是 `7.26953125 → 7.27`，反推 `7.27 * 256 = 1861.12`（原本是 1861）。
 *   表现：
 *     · `sceneDigest()` 直接报 `CANON.NOT_INTEGER`（它是第一个发现的，因为它要求整数）；
 *     · 若没有 digest，这个错误会变成"读档后资源点挪了 1/2000 格"—— 肉眼看不出、
 *       玩起来看不出、**只有拿两个世界逐字节比才看得出**。
 *   根因是"两处各自选精度"：一处用二进制分母（1/256），一处用十进制（1/1000）。
 *   修法是让量化也按 2 的幂（见 `scene-io.ts` 的 `q`）。
 *
 * ★ 判据的顺序是有讲究的：先钉「往返后 digest 相同」，再钉「每个坐标精确」，
 *   最后钉「存档损坏能被反查抓出来」。第一条是总闸门，后两条告诉人**哪儿**坏了。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import {
  loadScene,
  saveScene,
  sceneFromJson,
  sceneToJson,
  type SceneSnapshot,
} from "../../src/core/scene/scene-io.ts";
import { FIXED_UNITS, generateWorld, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import {
  SITE_TYPE,
  TERRAIN_TYPE,
  SiteMarker,
  TerrainArea,
  assembleWorld,
  rasterizeTerrain,
  registerWorldComponents,
  sceneDigest,
} from "../../src/extensions/worldgen/assemble.ts";

function makeScene(): Scene {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  return new Scene("world", reg);
}

function gen(seed = 7, width = 32, height = 24): WorldPlan {
  const r = generateWorld({ seed, width, height });
  assert.ok(r.ok, r.ok ? "" : `生成失败：${r.error.code}`);
  return r.value;
}

function assembled(plan: WorldPlan): Scene {
  const scene = makeScene();
  const r = assembleWorld(plan, scene);
  assert.ok(r.ok, r.ok ? "" : `装配失败：${r.error.code} ${r.error.message}`);
  return scene;
}

/** 存 → 序列化 → 解析 → 读档，返回新场景与中间产物。 */
function roundTrip(scene: Scene): { scene2: Scene; json: string; snap: SceneSnapshot } {
  const snap = saveScene(scene);
  const json = sceneToJson(snap);
  const parsed = sceneFromJson(json);
  assert.ok(parsed.ok, parsed.ok ? "" : `解析失败：${parsed.error.code} ${parsed.error.message}`);
  const scene2 = makeScene();
  const loaded = loadScene(scene2, parsed.value, scene2.components);
  assert.ok(loaded.ok, loaded.ok ? "" : `读档失败：${loaded.error.code}`);
  assert.deepEqual(loaded.value.skipped, [], "读档跳过了东西 —— 那不是「往返」，是「少了点」");
  assert.deepEqual(loaded.value.missingFields, [], "组件有字段没读到（旧档问题不该出现在自己写的档上）");
  return { scene2, json, snap };
}

// ── ① 总闸门：往返后内容指纹相同 ──────────────────────────────

test("★ 装配 → 存档 → 读档：内容指纹完全相同（节点 id / 位置 / 组件数据）", () => {
  const plan = gen();
  const scene = assembled(plan);
  const before = sceneDigest(scene);
  assert.ok(before.ok, before.ok ? "" : `装配后就已经不合法：${before.error.code} ${before.error.message}`);

  const { scene2 } = roundTrip(scene);
  const after = sceneDigest(scene2);
  assert.ok(
    after.ok,
    after.ok ? "" : `读档后的坐标不再是定点整数：${after.error.code} ${after.error.message} —— 量化精度与 FIXED_UNITS 不兼容`,
  );
  assert.equal(after.value, before.value, "存读一趟，世界变了");
});

test("★ 定点坐标逐点精确：读回后 pos × 256 仍精确等于计划里的整数（1/256 不能只剩 3 位小数）", () => {
  const plan = gen(11);
  const scene = assembled(plan);
  const { scene2 } = roundTrip(scene);

  const byId = new Map(plan.sites.map((s) => [s.id, s] as const));
  const markers = scene2.componentsOf<SiteMarker>(SITE_TYPE);
  assert.equal(markers.length, plan.sites.length);
  for (const m of markers) {
    const site = byId.get(m.siteId);
    assert.ok(site !== undefined, `读回来的 siteId ${m.siteId} 在计划里找不到`);
    const pos = m.node!.localPosition;
    assert.equal(pos.x * FIXED_UNITS, site.x, `site ${m.siteId} 的 x 存档后偏了`);
    assert.equal(pos.y * FIXED_UNITS, site.z, `site ${m.siteId} 的 z 存档后偏了`);
  }
});

test("地形矩形的格子坐标与 passable 全部保留（组件字段不能「存了但读回来是默认值」）", () => {
  const plan = gen(7);
  const scene = assembled(plan);
  const { scene2 } = roundTrip(scene);

  const pick = (s: Scene): string[] =>
    s
      .componentsOf<TerrainArea>(TERRAIN_TYPE)
      .map((a) => `${a.kind}:${a.cx},${a.cz},${a.w},${a.h}:${a.passable}`)
      .sort();
  assert.deepEqual(pick(scene2), pick(scene));
  assert.ok(pick(scene).length > 0);
});

test("存档字节回环：存 → 读 → 再存，两次的 JSON 完全相同", () => {
  const scene = assembled(gen(7));
  const { scene2, json } = roundTrip(scene);
  const again = sceneToJson(saveScene(scene2));
  assert.equal(again, json, "读档再存出来的字节不一样 —— 存档不是幂等的");
});

test("读档后的场景能被正常 step，且地形反查仍然完全覆盖", () => {
  const plan = gen(7);
  const scene = assembled(plan);
  const { scene2 } = roundTrip(scene);
  scene2.step(1, 1 / 30);
  const r = rasterizeTerrain(scene2, plan.width, plan.height);
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  assert.equal(r.value.gaps, 0);
  assert.equal(r.value.overlaps, 0);
  assert.deepEqual(r.value.kinds, plan.kinds);
});

test("读档后的节点 id 与装配时一致（id 是存档可以跨世界互换的前提）", () => {
  const scene = assembled(gen(7));
  const { scene2 } = roundTrip(scene);
  const ids = (s: Scene): number[] => {
    const out: number[] = [];
    s.root.walk((n) => out.push(n.id));
    return out.sort((a, b) => a - b);
  };
  assert.deepEqual(ids(scene2), ids(scene));
});

// ── ② 存档损坏要被反查抓出来 ──────────────────────────────────

test("存档里的地形被改坏（某块漏掉一行）⇒ 反查报出漏格，而不是「加载成功」", () => {
  const plan = gen(7);
  const scene = assembled(plan);
  const snap = saveScene(scene);

  // 找到第一块高度 > 1 的地形，把它的 h 减 1 —— 这是最"合理"的损坏形式（有人手动改过数值）
  const victim = snap.nodes
    .flatMap((n) => n.components)
    .find((c) => c.type === TERRAIN_TYPE && Number(c.data.h) > 1);
  assert.ok(victim !== undefined, "没有高度 >1 的地形块，换一张图再测");
  const before = Number(victim!.data.h);
  Object.assign(victim!.data as Record<string, unknown>, { h: before - 1 });

  const scene2 = makeScene();
  const loaded = loadScene(scene2, snap, scene2.components);
  assert.ok(loaded.ok, "读档本身不该失败 —— 它只该「照单全收」");
  const raster = rasterizeTerrain(scene2, plan.width, plan.height);
  assert.ok(raster.ok);
  assert.ok(raster.value.gaps > 0, "存档被改坏了一行，反查却说覆盖完全 —— 反查工具没有牙齿");
});

test("存档里的地形被改坏（某块宽度越界）⇒ 反查报 WORLD.BAD_SCENE", () => {
  const plan = gen(7);
  const snap = saveScene(assembled(plan));
  const victim = snap.nodes.flatMap((n) => n.components).find((c) => c.type === TERRAIN_TYPE);
  assert.ok(victim !== undefined);
  Object.assign(victim!.data as Record<string, unknown>, { w: plan.width + 4 });

  const scene2 = makeScene();
  const loaded = loadScene(scene2, snap, scene2.components);
  assert.ok(loaded.ok);
  const raster = rasterizeTerrain(scene2, plan.width, plan.height);
  assert.equal(raster.ok, false);
  if (raster.ok) return;
  assert.match(raster.error.message, /越界/);
});

// ── ③ 量化精度本身的性质 ──────────────────────────────────────

test("量化必须能精确表示 1/256 的整数倍（这是「定点坐标不该被存档改掉」的最小条件）", () => {
  // 直接验算术：把 0..255 个定点单位写成世界坐标再存读一趟
  const scene = makeScene();
  const root = scene.spawnImmediate("probe");
  const probes: number[] = [];
  for (let i = 0; i < 256; i++) {
    const n = scene.spawnImmediate(`p${i}`, root.id);
    const v = i / FIXED_UNITS;
    n.setLocalPosition(v, v);
    probes.push(v);
  }
  scene.flush();
  const { scene2 } = roundTrip(scene);
  const xs: number[] = [];
  for (let i = 0; i < 256; i++) xs.push(scene2.root.children[0]!.children[i]!.localPosition.x);
  for (let i = 0; i < 256; i++) {
    // ★ 这里必须用 === 而不是容差：定点与量化都该是精确的（2 的幂）
    assert.equal(xs[i], probes[i], `定点 ${i}/256 存读后被改成了 ${String(xs[i])}`);
    assert.equal(xs[i]! * FIXED_UNITS, i, `定点 ${i}/256 反推不是整数`);
  }
});

test("量化的分母是 2 的幂（若是十进制 1000，「精确往返」就不可能对所有定点值成立）", () => {
  // 用一个只有 8 位二进制小数的值：0.00390625 = 1/256
  const scene = makeScene();
  const n = scene.spawnImmediate("p");
  n.setLocalPosition(1 / 256, 0);
  scene.flush();
  const json = sceneToJson(saveScene(scene));
  assert.match(json, /"x":0\.00390625/, `存档里写的不是精确值：${json.slice(0, 160)}`);
});

test("★ 守卫：FIXED_UNITS ≤ 512（存档量化是 1e-9，再细的定点它就装不下了）", () => {
  // ★ 跨层约束，只能靠判据表达：L2 的 scene-io 不许依赖 L4 的 worldgen，
  //   所以"1e-9 能表示多少分之一的定点"这件事没法写成类型。
  //   谁把 FIXED_UNITS 改大，就先红这条 —— 提示去把 scene-io 的量化换成 2 的幂。
  assert.ok(
    FIXED_UNITS <= 512,
    `FIXED_UNITS=${FIXED_UNITS} 超出存档量化（1e-9 = 9 位小数）能精确表示的范围：1/1024 = 0.0009765625 是 10 位。改大定点单位要同时把 scene-io 的 q() 换成 2 的幂量化`,
  );
  // 顺手验证结论本身：上限值（1/512）刚好还能精确
  const step = 1 / 512;
  assert.equal(Math.round(step * 1e9) / 1e9, step, "1/512 已经不是 9 位小数 —— 守卫的界算错了");
});
