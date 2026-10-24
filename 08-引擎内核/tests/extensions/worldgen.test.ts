/**
 * L4 · 世界生成测试（阶段 3 出口判据）
 *
 * 出口判据原文：「同种子两次生成指纹相同」。这句话要成立，得先拆成四件事分别验：
 *   ① 规范化序列化真的消除了表示自由度（键序 / 浮点 / 静默降级）；
 *   ② 生成过程本身没有隐藏状态（同参数两次调用逐字段相同，含架桥记录）；
 *   ③ 指纹覆盖了改动（改种子 / 改尺寸 / 改投放都要变）；
 *   ④ **校验器会报红** —— 这条最重要：一条永远绿的连通性校验等于没有校验。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { canonicalize, fingerprintOf, CANON_NOT_FINITE, CANON_NOT_INTEGER, CANON_NULL, CANON_UNSUPPORTED } from "../../src/foundation/canonical.ts";
import {
  FIXED_UNITS,
  WORLD_BAD_PARAMS,
  WORLD_NO_SPAWN,
  generateWorld,
  isPassable,
  pickSpawn,
  planDigest,
  type BiomeKind,
  type WorldPlan,
} from "../../src/extensions/worldgen/worldgen.ts";
import { validateWorld } from "../../src/extensions/worldgen/validate.ts";

function gen(seed: number, width = 32, height = 24, repair = true): WorldPlan {
  const r = generateWorld({ seed, width, height, repair });
  assert.ok(r.ok, r.ok ? "" : `生成失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function boom(v: unknown): { code: string; message: string } {
  const r = canonicalize(v);
  assert.equal(r.ok, false, "本该报错却成功了");
  if (r.ok) throw new Error("unreachable");
  return r.error;
}

// ── ① 规范化序列化 ────────────────────────────────────────────

test("键书写顺序不影响规范化结果", () => {
  const a = canonicalize({ b: 2, a: 1, c: { z: 9, y: 8 } });
  const b = canonicalize({ c: { y: 8, z: 9 }, a: 1, b: 2 });
  assert.ok(a.ok && b.ok);
  assert.equal(a.value, b.value);
  // 串本身也必须是"键已排序"的形状，否则上面那条只是碰巧相等
  assert.equal(a.value, '{"a":1,"b":2,"c":{"y":8,"z":9}}');
});

test("小数直接报错，不四舍五入（否则「引入了浮点」这件事会被藏起来）", () => {
  const e = boom({ x: 1.5 });
  assert.equal(e.code, CANON_NOT_INTEGER);
  assert.match(e.message, /\$\.x/);
});

test("NaN / Infinity 报错（JSON 会把它们静默变成 null）", () => {
  // 与"小数"分开报：非有限值不是"精度问题"，是"算爆了"，处置不同
  assert.equal(boom({ v: Number.NaN }).code, CANON_NOT_FINITE);
  assert.equal(boom({ v: Number.POSITIVE_INFINITY }).code, CANON_NOT_FINITE);
  assert.equal(boom({ v: Number.NEGATIVE_INFINITY }).code, CANON_NOT_FINITE);
});

test("null 与 undefined 报错，且错误码可区分", () => {
  assert.equal(boom({ a: null }).code, CANON_NULL);
  assert.equal(boom({ a: undefined }).code, CANON_UNSUPPORTED);
  // 数组里的 undefined 在 JSON 里会变 null —— 最隐蔽的一种
  assert.equal(boom([1, undefined]).code, CANON_UNSUPPORTED);
});

test("类实例（Date / Map / 自定义类）报错：它们的内部顺序规范化规则管不到", () => {
  assert.equal(boom({ d: new Date(0) }).code, CANON_UNSUPPORTED);
  assert.equal(boom({ m: new Map() }).code, CANON_UNSUPPORTED);
  class Foo {
    readonly a = 1;
  }
  assert.equal(boom({ f: new Foo() }).code, CANON_UNSUPPORTED);
});

test("超出安全整数报错（再往上整数已经不精确，两个相邻整数可能是同一个值）", () => {
  const r = canonicalize({ v: Number.MAX_SAFE_INTEGER + 2 });
  assert.equal(r.ok, false);
});

test("-0 与 0 同串（世界坐标里它们没有区别，分叉只会制造幽灵漂移）", () => {
  const a = canonicalize({ v: -0 });
  const b = canonicalize({ v: 0 });
  assert.ok(a.ok && b.ok);
  assert.equal(a.value, b.value);
});

test("字符串按 JSON 规则转义：引号/反斜杠/控制字符不会破坏结构", () => {
  // 手拼 `"${s}"` 是这里最容易犯的错：一个引号就能让规范化串变成两个键，
  // 而两份**不同**的数据因此可能撞成同一个串 —— 指纹当场失去意义。
  const r = canonicalize({ a: 'he said "hi"\n\\' });
  assert.ok(r.ok);
  assert.equal(r.value, '{"a":"he said \\"hi\\"\\n\\\\"}');
});

test("嵌套结构里的非法值要报出**具体路径**（不然红了不知道看哪儿）", () => {
  const e = boom({ list: [{ ok: 1 }, { ok: 2.25 }] });
  assert.match(e.message, /\$\.list\[1\]\.ok/);
});

test("指纹对同值不同键序给出同一个值，且是 16 位 hex", () => {
  const a = fingerprintOf({ a: 1, b: 2 });
  const b = fingerprintOf({ b: 2, a: 1 });
  assert.ok(a.ok && b.ok);
  assert.equal(a.value, b.value);
  assert.match(a.value, /^[0-9a-f]{16}$/);
});

// ── ② 生成过程的确定性 ────────────────────────────────────────

test("同参数两次生成，逐字段完全相同（含架桥记录）", () => {
  const a = gen(12345);
  const b = gen(12345);
  assert.equal(a.fingerprint, b.fingerprint);
  assert.deepEqual(a.kinds, b.kinds);
  assert.deepEqual(a.sites, b.sites);
  assert.deepEqual(a.bridges, b.bridges);
});

test("生成时算的指纹 == 事后独立重算的指纹（防止「存的指纹」和「内容」不同步）", () => {
  const p = gen(777);
  const d = planDigest(p);
  assert.ok(d.ok);
  assert.equal(d.value, p.fingerprint);
});

test("不同种子给出不同世界", () => {
  const fps = new Set([gen(1).fingerprint, gen(2).fingerprint, gen(3).fingerprint, gen(4).fingerprint]);
  assert.equal(fps.size, 4, "不同种子撞了同一个指纹");
});

test("改尺寸要改变指纹（尺寸在指纹覆盖范围内）", () => {
  const a = gen(9, 32, 24);
  const b = gen(9, 33, 24);
  assert.notEqual(a.fingerprint, b.fingerprint);
});

test("地图边界一圈恒为 ocean（岛形，连通性问题才有意义）", () => {
  const p = gen(5, 20, 16);
  for (let x = 0; x < p.width; x++) {
    assert.equal(p.kinds[x], "ocean", `上边界 x=${String(x)}`);
    assert.equal(p.kinds[(p.height - 1) * p.width + x], "ocean", `下边界 x=${String(x)}`);
  }
  for (let z = 0; z < p.height; z++) {
    assert.equal(p.kinds[z * p.width], "ocean", `左边界 z=${String(z)}`);
    assert.equal(p.kinds[z * p.width + p.width - 1], "ocean", `右边界 z=${String(z)}`);
  }
});

test("参数不合法返回 WORLD.BAD_PARAMS，不做任何「合理默认」兜底", () => {
  for (const bad of [
    { seed: 1, width: 7, height: 16 },
    { seed: 1, width: 16, height: 129 },
    { seed: 1.5, width: 16, height: 16 },
    { seed: 1, width: 16, height: 16, maxSitesPerCell: 9 },
  ]) {
    const r = generateWorld(bad);
    assert.equal(r.ok, false, `本该拒绝 ${JSON.stringify(bad)}`);
    if (!r.ok) assert.equal(r.error.code, WORLD_BAD_PARAMS);
  }
});

// ── ③ 投放点 ──────────────────────────────────────────────────

test("投放点 id 规则：id = 格子下标 * maxSites + 序号，且全图不重复", () => {
  const maxSites = 2;
  const p = gen(31, 24, 20);
  const seen = new Set<number>();
  for (const s of p.sites) {
    // id 必须落在"本格子专属的号段"里：中途加一个格子不会让别人的 id 平移
    assert.ok(s.id >= s.cell * maxSites, `id ${String(s.id)} 小于号段下界 ${String(s.cell * maxSites)}`);
    assert.ok(s.id < (s.cell + 1) * maxSites, `id ${String(s.id)} 越过号段上界`);
    assert.equal(seen.has(s.id), false, `id 重复：${String(s.id)}`);
    seen.add(s.id);
  }
  assert.ok(p.sites.length > 0, "一个投放点都没有，这条判据没验到东西");
});

test("所有投放点都落在可通行格上且不越界", () => {
  const p = gen(88, 32, 24);
  const v = validateWorld(p);
  assert.equal(v.sitesOnImpassable, 0);
  assert.equal(v.sitesOutOfBounds, 0);
});

test("maxSitesPerCell = 0 时不投任何点", () => {
  const r = generateWorld({ seed: 4, width: 16, height: 16, maxSitesPerCell: 0 });
  assert.ok(r.ok);
  assert.equal(r.value.sites.length, 0);
});

test("投放的「局部性」：末尾追加几行，已有格子的投放一个不变", () => {
  // 一条连续 RNG 流做不到这一点：中途插入一个格子会消耗掉若干随机数，
  // 后面的格子全部错位。这里验的是更强的性质 ——
  // 每个格子的投放只由 (seed, 自身格子下标) 决定。
  //
  // ★ 必须排除原图的**最后一行**：地形规则里"边界一圈强制海"依赖 height，
  //   加高之后原先的最后一行不再是边界，从海变成陆地 —— 这是边界规则的正确行为，
  //   不是确定性出了问题。把它算进比对范围，这条判据就变成在验错误的东西。
  const a = generateWorld({ seed: 202, width: 24, height: 16, repair: false });
  const b = generateWorld({ seed: 202, width: 24, height: 20, repair: false });
  assert.ok(a.ok && b.ok);
  const safeRows = 15;
  const limit = 24 * safeRows;
  const left = a.value.sites.filter((s) => s.cell < limit);
  const right = b.value.sites.filter((s) => s.cell < limit);
  assert.ok(left.length > 100, `比对区只有 ${String(left.length)} 个投放点，验不动`);
  assert.equal(left.length, right.length);
  assert.deepEqual(left, right);
  // 反面对照：确实存在"最后一行"被边界规则改掉的情况，否则排除它就没理由
  const lastRowA = a.value.kinds.slice(24 * 15, 24 * 16);
  const lastRowB = b.value.kinds.slice(24 * 15, 24 * 16);
  assert.notDeepEqual(lastRowA, lastRowB, "最后一行没有变化 —— 那排除它就纯属放水");
});

test("群系是成片的，不是棋盘噪点", () => {
  const p = gen(66, 48, 40);
  // 统计"可通行格中，4 邻域里没有一个同群系邻居"的比例
  let lonely = 0;
  let passable = 0;
  for (let z = 1; z < p.height - 1; z++) {
    for (let x = 1; x < p.width - 1; x++) {
      const i = z * p.width + x;
      const k = p.kinds[i]!;
      if (!isPassable(k)) continue;
      passable++;
      const neighbors = [p.kinds[i - 1]!, p.kinds[i + 1]!, p.kinds[i - p.width]!, p.kinds[i + p.width]!];
      if (!neighbors.includes(k)) lonely++;
    }
  }
  assert.ok(passable > 100, `可通行格只有 ${String(passable)} 个，地图太贫瘠`);
  assert.ok(lonely / passable < 0.05, `孤立格占 ${(lonely / passable).toFixed(3)}，群系没有成片`);
});

// ── ④ 校验器必须会报红（本文件最重要的一组）────────────────────

test("repair=true 时不存在到不了的陆地", () => {
  for (const seed of [1, 2, 3, 7, 11, 42, 99, 1234]) {
    const p = gen(seed, 40, 32, true);
    const v = validateWorld(p);
    assert.equal(v.unreachable, 0, `seed=${String(seed)} 仍有 ${String(v.unreachable)} 格不可达`);
    assert.equal(v.ok, true);
  }
});

test("repair=false 会造出「到不了的陆地」，而校验器真的报出来", () => {
  // 至少要有一个种子能证明这条路走得通。若一个都造不出来，
  // 说明"连通性"在这套地形参数下是必然的 ⇒ 上面那条判据是假绿。
  let found = 0;
  let sawIsland = false;
  for (const seed of [1, 2, 3, 7, 11, 42, 99, 1234, 5150, 8888]) {
    const p = gen(seed, 40, 32, false);
    const v = validateWorld(p);
    if (v.unreachable > 0) {
      found++;
      assert.equal(v.ok, false, "不可达却报 ok");
      assert.ok(v.components >= 2);
      assert.ok(v.unreachableSamples.length > 0, "报红却不给位置");
      // 样本必须真的是不可达格：它所在的分量不是最大分量
      for (const cell of v.unreachableSamples) {
        assert.notEqual(v.regionOf[cell], -1, "样本落在不可通行格上");
        assert.notEqual(v.regionOf[cell], v.mainRegion, "样本落在了主分量上");
      }
    } else {
      sawIsland = true;
    }
  }
  assert.ok(found > 0, "十个种子里一个都没造出不可达陆地 —— 连通性判据没有观测对象");
  assert.ok(sawIsland, "十个种子全都不可达 —— 地形参数把地图撕得太碎，正常");
});

test("架桥只增加可通行格，不会把陆地改成海", () => {
  const before = gen(42, 40, 32, false);
  const after = gen(42, 40, 32, true);
  let passableBefore = 0;
  let passableAfter = 0;
  for (let i = 0; i < before.kinds.length; i++) {
    if (isPassable(before.kinds[i]!)) passableBefore++;
    if (isPassable(after.kinds[i]!)) passableAfter++;
    // 原本可通行的格子不许被改（桥只挖不改）
    if (isPassable(before.kinds[i]!)) {
      assert.equal(isPassable(after.kinds[i]!), true, `格子 ${String(i)} 从可通行变成了不可通行`);
    }
  }
  assert.ok(passableAfter >= passableBefore);
  assert.equal(after.bridges.length, 0);
  assert.ok(before.bridges.length === 0, "repair=false 不该产生桥记录");
});

test("校验器是纯函数：不改输入，跑两次结果相同", () => {
  const p = gen(13, 32, 24, false);
  const snapshot = JSON.stringify({ k: p.kinds, s: p.sites, b: p.bridges });
  const v1 = validateWorld(p);
  const v2 = validateWorld(p);
  assert.equal(JSON.stringify({ k: p.kinds, s: p.sites, b: p.bridges }), snapshot);
  assert.deepEqual(v1, v2);
});

test("校验结果的 ok 与各项计数自洽", () => {
  for (const repair of [true, false]) {
    for (const seed of [3, 17, 250]) {
      const p = gen(seed, 36, 28, repair);
      const v = validateWorld(p);
      assert.equal(v.passable + v.impassable, p.width * p.height);
      assert.equal(v.passable - v.largest, v.unreachable);
      const expectOk = v.unreachable === 0 && v.sitesOnImpassable === 0 && v.sitesOutOfBounds === 0;
      assert.equal(v.ok, expectOk);
    }
  }
});

test("定点常量是 2 的幂（乘除可写成移位，且 1 格 > 1 单位才留得住亚格位置）", () => {
  assert.equal(FIXED_UNITS, 256);
  assert.equal(Math.log2(FIXED_UNITS) % 1, 0);
});

// ── 出生点（"能不能玩"的最后一环）────────────────────────────

test("出生点在主分量内且可通行（出生在走不到的小岛上等于这局白开）", () => {
  for (const seed of [3, 7, 11, 23]) {
    const plan = gen(seed, 32, 24, false); // 故意不架桥：保证真有多个分量
    const s = pickSpawn(plan);
    assert.ok(s.ok, s.ok ? "" : `${s.error.code} ${s.error.message}`);
    assert.equal(isPassable(plan.kinds[s.value.cell]!), true);
    const v = validateWorld(plan);
    assert.equal(v.regionOf[s.value.cell], v.mainRegion, `seed ${seed} 的出生点不在主分量里`);
  }
});

test("★ 主分量不是「最宽敞的那块」时，仍然选主分量（构造图：环 vs 方块岛）", () => {
  // ★ 这条判据是被 M127 逼出来的：在真实种子的地图上，"最宽敞的格"几乎总在主分量里，
  //   于是"出生点必须在主分量内"这条**根本抓不住**"不限主分量"的实现 —— 判据是假绿。
  //   要让它有分辨力，必须造出"非主分量更宽敞"的形状：
  //     · 环（厚 3 格，276 格）—— 每格都离海很近，余量最大 2，但它是**主分量**；
  //     · 方块岛（9×9，81 格）—— 中心余量 4，却是**非主分量**。
  //   不限主分量的实现会去方块岛中心（余量 4），正确答案是环上余量 2 的某格。
  const W = 40;
  const H = 40;
  const kinds: BiomeKind[] = new Array<BiomeKind>(W * H).fill("ocean");
  const put = (x: number, z: number): void => {
    kinds[z * W + x] = "grass";
  };
  // 环：外框 (2,2)-(27,27)，厚度 3
  for (let x = 2; x <= 27; x++) {
    for (let t = 0; t < 3; t++) {
      put(x, 2 + t);
      put(x, 27 - t);
    }
  }
  for (let z = 2; z <= 27; z++) {
    for (let t = 0; t < 3; t++) {
      put(2 + t, z);
      put(27 - t, z);
    }
  }
  // 方块岛 (31,2)-(39,10)：9×9，与环不连通
  for (let z = 2; z <= 10; z++) for (let x = 31; x <= 39; x++) put(x, z);

  const base = gen(1, W, H);
  const patched: WorldPlan = { ...base, width: W, height: H, kinds };
  const fp = planDigest(patched);
  assert.ok(fp.ok);
  const plan: WorldPlan = { ...patched, fingerprint: fp.value };

  const v = validateWorld(plan);
  assert.ok(v.components >= 2, `构造图只有 ${v.components} 个分量，判据没有分辨力`);

  const s = pickSpawn(plan);
  assert.ok(s.ok, s.ok ? "" : `${s.error.code} ${s.error.message}`);
  const sx = s.value.cell % W;
  const sz = (s.value.cell - sx) / W;
  assert.ok(sx <= 27 && sz <= 27, `出生点落在方块岛上了（${sx},${sz}）—— 那是走不到主大陆的孤岛`);
  assert.equal(v.regionOf[s.value.cell], v.mainRegion);
  assert.ok(
    s.value.clearance < 4,
    `余量 ${s.value.clearance} 说明选的是方块岛中心 —— 主分量里不可能有这么大的余量`,
  );
});

test("出生点的「余量」与四邻一致：clearance ≥ 2 时四邻全可通行，= 1 时至少一个邻居不可通行", () => {
  const plan = gen(7, 32, 24);
  const s = pickSpawn(plan);
  assert.ok(s.ok);
  const { width, kinds } = plan;
  const cell = s.value.cell;
  const x = cell % width;
  const z = (cell - x) / width;
  const neighbours: number[] = [];
  for (const [ox, oz] of [
    [1, 0],
    [-1, 0],
    [0, 1],
    [0, -1],
  ] as const) {
    const nx = x + ox;
    const nz = z + oz;
    if (nx < 0 || nz < 0 || nx >= width || nz >= plan.height) continue; // 出界不是"邻居"
    neighbours.push(nz * width + nx);
  }
  if (s.value.clearance >= 2) {
    for (const n of neighbours) assert.equal(isPassable(kinds[n]!), true, `clearance=${s.value.clearance} 却有不可通行的邻居 ${n}`);
  } else {
    assert.equal(s.value.clearance, 1);
    assert.ok(neighbours.some((n) => !isPassable(kinds[n]!)), "clearance=1 却没有不可通行的邻居");
  }
  assert.ok(s.value.clearance >= 1, "余量至少是 1（边界外的邻居算一步）");
});

test("全可通行的手改地图：按「离边缘多远」选，平局取下标最小", () => {
  // 8×8 全 grass：一层层剥下去，(3,3) 与 (4,4) 都是 4；(3,3) 的下标更小 ⇒ 必须选它
  const kinds: BiomeKind[] = new Array<BiomeKind>(64).fill("grass");
  const plan = gen(1, 8, 8); // 只为拿一个合法的 fingerprint 字段，kinds 会被覆盖
  const patched: WorldPlan = { ...plan, width: 8, height: 8, kinds };
  const fp = planDigest(patched);
  assert.ok(fp.ok);
  const s = pickSpawn({ ...patched, fingerprint: fp.value });
  assert.ok(s.ok, s.ok ? "" : `${s.error.code} ${s.error.message}`);
  assert.equal(s.value.cell, 3 * 8 + 3, "平局没取下标最小的格");
  assert.equal(s.value.clearance, 4);
});

test("全海图 ⇒ WORLD.NO_SPAWN（不是随便给个坐标）", () => {
  const base = gen(1, 8, 8);
  const kinds: BiomeKind[] = new Array<BiomeKind>(64).fill("ocean");
  const patched: WorldPlan = { ...base, width: 8, height: 8, kinds };
  const fp = planDigest(patched);
  assert.ok(fp.ok);
  const s = pickSpawn({ ...patched, fingerprint: fp.value });
  assert.equal(s.ok, false);
  if (s.ok) return;
  assert.equal(s.error.code, WORLD_NO_SPAWN);
});

test("出生点坐标是格子中心，且 × 256 是整数（能精确进世界坐标）", () => {
  const plan = gen(7, 32, 24);
  const s = pickSpawn(plan);
  assert.ok(s.ok);
  const x = s.value.cell % plan.width;
  const z = (s.value.cell - x) / plan.width;
  assert.equal(s.value.x, x * FIXED_UNITS + FIXED_UNITS / 2);
  assert.equal(s.value.z, z * FIXED_UNITS + FIXED_UNITS / 2);
  assert.equal(Number.isInteger(s.value.x), true);
});

test("同计划两次 pickSpawn 完全相同（不是「随机挑一个安全点」）", () => {
  const plan = gen(13, 40, 32);
  const a = pickSpawn(plan);
  const b = pickSpawn(plan);
  assert.ok(a.ok && b.ok);
  assert.deepEqual(a.value, b.value);
});

test("架桥只会让「余量」不减（桥只把不可通行格挖开，任何格的余量都不可能变小）", () => {
  // ★ 第一版这里断言的是"出生点必须变"—— 那是错的：桥在别的角落挖开时，
  //   最宽敞的那一格完全可能不变。**单调性**才是这条改动的必然推论。
  for (const seed of [3, 7, 11]) {
    const a = pickSpawn(gen(seed, 32, 24, false));
    const b = pickSpawn(gen(seed, 32, 24, true));
    assert.ok(a.ok && b.ok);
    assert.ok(
      b.value.clearance >= a.value.clearance,
      `seed ${seed}：架桥后余量从 ${a.value.clearance} 掉到 ${b.value.clearance} —— 桥挖错了地形`,
    );
  }
});
