/**
 * L4 · 方向帧素材与「朝向 → 帧名」这根线（批108）
 *
 * 这一批最容易假绿的地方有两个，判据一一对住：
 *
 *   ① **素材本身没有编码方向**。八张图都画出来了、文件名也对，但八张长得一样 ——
 *      `resolveDirFrame` 全绿、`syncDirFrames` 全绿，画面上怪物永远一个姿势。
 *      所以下面直接**解码 PNG 读像素**：朝前的五向必须有眼睛，朝后的三向必须没有、
 *      且眼睛质心要自东向西单调左移。方向映射写反（e/w 互换）当场红。
 *   ② **同步器改了帧名但读的是错的量**。比如写了 `sprite.frame` 却按 `dir4` 取
 *      （8 向图只用得上 4 张），或者同向每帧重写一次（`changed` 永远是 1，
 *      "没变就不写"这条优化等于没做）。所以每个用例都读**两个**观测量：
 *      帧名对不对 ∧ `changed` 计数对不对。
 *
 * ★ 判据不许依赖「上一 tick 留下的状态」：每个用例自己建场景、自己设角度。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { Node } from "../../src/core/scene/node.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { Facing, registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import {
  DIR_SPRITE_TYPE,
  DirSprite,
  registerDirSpriteComponent,
  syncDirFrames,
} from "../../src/extensions/render/dir-sprite.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { spawnMob } from "../../src/extensions/mobs/spawn-mob.ts";

const ASSETS = fileURLToPath(new URL("../../web/assets/", import.meta.url));
const ROOT = fileURLToPath(new URL("../../", import.meta.url));

/** 与 `dir-frames.ts` 的 `LETTERS8` 同序（`0` = 东，顺时针）。 */
const LETTERS = ["e", "se", "s", "sw", "w", "nw", "n", "ne"] as const;

/** 兔子方向帧的眼睛颜色（生成器里的 `EYE`，是契约的一部分）。 */
const EYE = [40, 40, 44] as const;
/** 猎狗的黄眼与深棕尾巴。 */
const HOUND_EYE = [240, 210, 90] as const;
const HOUND_TAIL = [70, 52, 38] as const;
/** 拾荒者的青眼与亮土黄尾巴（批167）。 */
const SCAV_EYE = [120, 226, 206] as const;
const SCAV_TAIL = [214, 186, 96] as const;

type Rgb = readonly [number, number, number];

/**
 * 三种生物的素材契约。**每只一份，判据对每一份都跑一遍。**
 *
 * ★★ 为什么不是只验兔子：批108 只验了兔子，猎狗的 8 张方向帧从来没有人读过像素。
 *   而"某一只的 e/w 画反"在画面上看起来完全正常（它朝东时显示朝西的姿势，
 *   只有盯着脚看才怪），唯一的守卫就是按眼睛质心对账。
 * ★ 瞳色必须互不相同：`scan` 是按**颜色**找眼睛的，撞色之后"这是谁的眼睛"无解，
 *   而症状是"某一只的眼睛数总是 0、或者多出来一份"。
 * ★ 尾巴色也一样（判据靠它判「背对」）。拾荒者的口袋是暗土黄、尾巴是亮土黄，
 *   刻意分开：同色的话，朝前那一帧的口袋会被当成尾巴 ⇒ 判据说方向画反了。
 */
const SPECIES: readonly { readonly key: string; readonly base: string; readonly eye: Rgb; readonly tail: Rgb }[] = [
  { key: "rabbit", base: "rabbit.png", eye: EYE, tail: [255, 255, 255] },
  { key: "hound", base: "hound.png", eye: HOUND_EYE, tail: HOUND_TAIL },
  { key: "scavenger", base: "scavenger.png", eye: SCAV_EYE, tail: SCAV_TAIL },
];

interface Scanned {
  readonly w: number;
  readonly h: number;
  readonly eyes: number;
  /** 眼睛像素的质心横坐标；没有眼睛时为 `null`。 */
  readonly eyeCx: number | null;
  readonly tail: number;
}

function scan(name: string, eye: Rgb, tail: Rgb): Scanned {
  const r = decodePng(new Uint8Array(readFileSync(ASSETS + name)));
  if (!r.ok) throw new Error(`解码 ${name} 失败：${r.error.code} ${r.error.message}`);
  const { width: w, height: h, pixels } = r.value;
  let eyes = 0;
  let sumX = 0;
  let tailPx = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      if (pixels[i + 3]! < 40) continue;
      const rgb = [pixels[i]!, pixels[i + 1]!, pixels[i + 2]!] as const;
      if (rgb[0] === eye[0] && rgb[1] === eye[1] && rgb[2] === eye[2]) {
        eyes++;
        sumX += x;
      }
      // 尾巴只在**下半身**算，免得把身体轮廓也算进去
      if (rgb[0] === tail[0] && rgb[1] === tail[1] && rgb[2] === tail[2] && y > h * 0.7) tailPx++;
    }
  }
  return { w, h, eyes, eyeCx: eyes === 0 ? null : sumX / eyes, tail: tailPx };
}

function dirFrame(prefix: string, letter: string): string {
  return `${prefix}_${letter}.png`;
}

// ------------------------------------------------------------------ 素材

test("[素材] 三只生物各有一套八向帧，尺寸与自己的单帧一致（图集切片按同格才拼得上）", () => {
  for (const sp of SPECIES) {
    const base = scan(sp.base, sp.eye, sp.tail);
    assert.ok(base.w > 0 && base.h > 0, `${sp.base} 尺寸必须非零`);
    for (const l of LETTERS) {
      const s = scan(dirFrame(sp.key, l), sp.eye, sp.tail);
      assert.equal(s.w, base.w, `${sp.key}/${l} 帧宽度必须与自己的单帧相同`);
      assert.equal(s.h, base.h, `${sp.key}/${l} 帧高度必须与自己的单帧相同`);
    }
  }
});

test("[素材] 朝后的三向没有眼睛、有尾巴；朝前的五向有眼睛、没尾巴", () => {
  for (const sp of SPECIES) {
    // dz < 0 的三向：nw / n / ne
    for (const l of ["nw", "n", "ne"] as const) {
      const s = scan(dirFrame(sp.key, l), sp.eye, sp.tail);
      assert.equal(s.eyes, 0, `${sp.key}/${l} 是背对镜头，不该有眼睛像素（有 ⇒ 方向画反了）`);
      assert.ok(s.tail > 0, `${sp.key}/${l} 背对时必须看得到尾巴 —— 那是「背对」唯一可靠的视觉线索`);
    }
    for (const l of ["e", "se", "s", "sw", "w"] as const) {
      const s = scan(dirFrame(sp.key, l), sp.eye, sp.tail);
      assert.ok(s.eyes > 0, `${sp.key}/${l} 面朝镜头方向，必须有眼睛像素`);
      assert.equal(s.tail, 0, `${sp.key}/${l} 朝前时不该出现尾巴（出现 ⇒ 那帧里藏着一块尾巴色）`);
    }
  }
});

test("[素材] 眼睛质心自东向西单调左移（e/w 写反或顺序错位都会红）", () => {
  for (const sp of SPECIES) {
    const order = ["e", "se", "s", "sw", "w"] as const;
    const xs = order.map((l) => {
      const s = scan(dirFrame(sp.key, l), sp.eye, sp.tail);
      assert.notEqual(s.eyeCx, null, `${sp.key}/${l} 没有眼睛，质心无法比较`);
      return s.eyeCx!;
    });
    for (let i = 1; i < xs.length; i++) {
      assert.ok(
        xs[i]! < xs[i - 1]!,
        `${sp.key}：${order[i - 1]} → ${order[i]} 眼睛质心应当左移，实际 ${xs[i - 1]!.toFixed(2)} → ${xs[i]!.toFixed(2)}`,
      );
    }
    const half = scan(sp.base, sp.eye, sp.tail).w / 2;
    assert.ok(xs[0]! > half, `${sp.key}：最东向的眼睛质心要在右半（实际 ${xs[0]!.toFixed(2)}，中线 ${half}）`);
    assert.ok(xs[4]! < half, `${sp.key}：最西向的眼睛质心要在左半（实际 ${xs[4]!.toFixed(2)}，中线 ${half}）`);
  }
});

test("[素材] 每只的八帧互不相同（画了八张一样的图也是「齐全」）", () => {
  for (const sp of SPECIES) {
    const seen = new Map<string, string>();
    for (const l of LETTERS) {
      const bytes = readFileSync(ASSETS + dirFrame(sp.key, l));
      const sig = bytes.toString("base64");
      const dup = seen.get(sig);
      assert.equal(dup, undefined, `${sp.key}/${l} 与 ${String(dup)} 的图完全相同 —— 方向没有画出来`);
      seen.set(sig, l);
    }
  }
});

test("[素材] 生成器产物与已提交的图逐字节一致（改坏生成器也要红）", () => {
  // ★ 为什么必须有这一条：上面的三条判据读的是**仓库里那批 PNG**，它们不会跟着
  //   生成器一起变。生成器把「朝后不画眼睛」改成「照画」，那三条依旧全绿 ——
  //   直到有人重新生成。这里跑一遍到临时目录做逐字节比对，把那条缝堵上。
  const out = mkdtempSync(join(tmpdir(), "demo-assets-"));
  try {
    const r = spawnSync(process.execPath, ["tools/make-demo-assets.mjs"], {
      cwd: ROOT,
      env: { ...process.env, DEMO_ASSETS_OUT: out },
      encoding: "utf8",
    });
    assert.equal(r.status, 0, `生成器退出码 ${String(r.status)}：${r.stderr ?? ""}`);
    const names = readdirSync(out).filter((f) => f.endsWith(".png")).sort();
    // 5 张场景图 + 3 只生物的单帧 + 3×8 张方向帧 = 5 + 3 + 24 = 32
    assert.equal(names.length, 32, `生成器应当产出 32 张，实际 ${names.length} 张`);
    for (const n of names) {
      const a = readFileSync(ASSETS + n);
      const b = readFileSync(join(out, n));
      assert.ok(a.equals(b), `${n} 与生成器产物不一致（改了生成器但没重新生成？）`);
    }
    // 反向也要查：仓库里不许有「生成器不再产出」的孤儿方向帧
    for (const sp of SPECIES) {
      assert.ok(names.includes(sp.base), `生成器不再产出 ${sp.base}`);
      for (const l of LETTERS) {
        assert.ok(names.includes(dirFrame(sp.key, l)), `生成器不再产出 ${dirFrame(sp.key, l)}`);
      }
    }
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------------ 同步

function makeScene(): Scene {
  const reg = new ComponentRegistry();
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  return new Scene("dir-sprite", reg);
}

interface Fixture {
  readonly node: Node;
  readonly sprite: Sprite;
  readonly facing: Facing;
  readonly dirSprite: DirSprite;
}

function makeMob(
  scene: Scene,
  opts: { prefix?: string; dirs?: 4 | 8; withFacing?: boolean; withSprite?: boolean } = {},
): Fixture {
  const node = scene.spawnImmediate("mob");
  const sprite = new Sprite();
  if (opts.withSprite !== false) node.attach(sprite);
  const facing = new Facing();
  if (opts.withFacing !== false) node.attach(facing);
  const dirSprite = new DirSprite();
  dirSprite.prefix = opts.prefix ?? "rabbit";
  dirSprite.dirs = opts.dirs ?? 8;
  node.attach(dirSprite);
  return { node, sprite, facing, dirSprite };
}

/** 只认「单帧 + 全部 8 向」的最小帧表，等价于真图集里有什么。 */
function hasAll(frame: string): boolean {
  return frame === "rabbit" || LETTERS.some((l) => frame === `rabbit_${l}`);
}

test("[同步] 按 dir8 写入对应的方向帧", () => {
  const scene = makeScene();
  const f = makeMob(scene);
  // 朝东（angle = 0）⇒ rabbit_e
  f.facing.setAngle(0);
  const st = syncDirFrames(scene, hasAll);
  assert.equal(f.sprite.frame, "rabbit_e", "朝东必须是 _e");
  assert.equal(st.changed, 1, "第一次同步必须真的改写一次");
  assert.equal(st.visited, 1);
  assert.equal(st.missing, 0);

  // 朝南（+y 屏幕向下）⇒ dirIndex(π/2, 8) = 2 ⇒ rabbit_s
  f.facing.setAngle(Math.PI / 2);
  syncDirFrames(scene, hasAll);
  assert.equal(f.sprite.frame, "rabbit_s", "朝南必须是 _s");
});

test("[同步] 同一朝向不重复写（changed === 0 才是真的「没变就不写」）", () => {
  const scene = makeScene();
  const f = makeMob(scene);
  f.facing.setAngle(Math.PI); // 朝西
  syncDirFrames(scene, hasAll);
  assert.equal(f.sprite.frame, "rabbit_w");
  const second = syncDirFrames(scene, hasAll);
  assert.equal(second.changed, 0, "同向第二 tick 又写了一次 ⇒ 每帧都在给渲染模块标脏");
  assert.equal(second.visited, 1, "「没改」不等于「没看」—— visited 必须仍为 1");
  assert.equal(f.sprite.frame, "rabbit_w");
});

test("[同步] 4 向组件按 dir4 选帧（方向数它是组件字段，不是全局开关）", () => {
  const scene = makeScene();
  const f = makeMob(scene, { dirs: 4 });
  // ★ 取 30° 而不是 45°：45° 时 `dir8` 与 `dir4` 都等于 1，判据分辨不出
  //   「按 4 向取」与「误按 8 向取」—— 两者读到同一个下标。30° 时
  //   `dir8 = 1`（se）、`dir4 = 0`（e），一根筋指对。
  f.facing.setAngle(Math.PI / 6);
  syncDirFrames(scene, hasAll);
  assert.equal(f.sprite.frame, "rabbit_e", "30° 在 4 向里归到 e（8 向才会是 se）");
});

test("[同步] 缺方向帧回落单帧（美术只画了一张图时，实体不能消失）", () => {
  const scene = makeScene();
  const f = makeMob(scene);
  const onlyBase = (frame: string): boolean => frame === "rabbit";
  f.facing.setAngle(0);
  const st = syncDirFrames(scene, onlyBase);
  assert.equal(f.sprite.frame, "rabbit", "没有 rabbit_e 就该回落到单帧");
  assert.equal(st.missing, 0, "回落算成功，不算缺失");
});

test("[同步] 连单帧都没有：计入 missing，且不改写原有帧名", () => {
  const scene = makeScene();
  const f = makeMob(scene);
  f.sprite.frame = "keep-me";
  f.facing.setAngle(0);
  const st = syncDirFrames(scene, () => false);
  assert.equal(st.missing, 1, "资产全缺必须计入 missing");
  assert.equal(st.changed, 0);
  assert.equal(f.sprite.frame, "keep-me", "编一个名字出来只会把「资产缺失」伪装成「方向错了」");
});

test("[同步] prefix 为空 / 没有朝向 / 没有精灵 —— 三种都不参与", () => {
  const empty = makeScene();
  const a = makeMob(empty, { prefix: "" });
  a.facing.setAngle(0);
  assert.equal(syncDirFrames(empty, hasAll).visited, 0, "空前缀不该参与");

  const noFace = makeScene();
  const b = makeMob(noFace, { withFacing: false });
  b.sprite.frame = "rabbit";
  assert.equal(syncDirFrames(noFace, hasAll).visited, 0, "没有朝向就没有方向可同步");
  assert.equal(b.sprite.frame, "rabbit");

  const noSprite = makeScene();
  const c = makeMob(noSprite, { withSprite: false });
  c.facing.setAngle(0);
  assert.equal(syncDirFrames(noSprite, hasAll).visited, 0, "没有精灵就没有帧可写");
});

test("[同步] 换前缀后重新解析（缓存不能粘住旧前缀）", () => {
  const scene = makeScene();
  const f = makeMob(scene);
  const both = (frame: string): boolean => hasAll(frame) || frame.startsWith("hound");
  f.facing.setAngle(0);
  syncDirFrames(scene, both);
  assert.equal(f.sprite.frame, "rabbit_e");

  f.dirSprite.prefix = "hound";
  syncDirFrames(scene, both);
  assert.equal(f.sprite.frame, "hound_e", "前缀变了必须重解析，否则生物换皮之后永远读旧帧");
});

test("[同步] 改 dirs 之后自动重解析（缓存键必须含方向数，否则 4 向会拿到 8 向的表）", () => {
  const scene = makeScene();
  const f = makeMob(scene); // 先按 8 向
  f.facing.setAngle(Math.PI / 4); // 45° ⇒ 8 向是 se
  syncDirFrames(scene, hasAll);
  assert.equal(f.sprite.frame, "rabbit_se");
  // ★ 只改方向数、**不调 invalidate**：键里漏掉 dirs 的实现会继续用 8 向那张表，
  //   于是 4 向组件的 dir=1 读到的仍是 se（正确应是 s）。
  f.dirSprite.dirs = 4;
  syncDirFrames(scene, hasAll);
  assert.equal(f.sprite.frame, "rabbit_s", "4 向里 45° 归到 s，不该拿到 8 向的 se");
});

test("[同步] invalidate 之后即使前缀没变也会重查图集", () => {
  const scene = makeScene();
  const f = makeMob(scene);
  let atlasHasDir = false;
  const has = (frame: string): boolean => (atlasHasDir ? hasAll(frame) : frame === "rabbit");
  f.facing.setAngle(0);
  syncDirFrames(scene, has);
  assert.equal(f.sprite.frame, "rabbit", "一开始图集里没有方向帧 ⇒ 单帧");

  atlasHasDir = true;
  syncDirFrames(scene, has);
  assert.equal(f.sprite.frame, "rabbit", "缓存还在，不该因为图集变了就自己重查（自动重算会藏住「图集只读」这个前提）");

  f.dirSprite.invalidate();
  syncDirFrames(scene, has);
  assert.equal(f.sprite.frame, "rabbit_e", "invalidate 之后必须重新解析到 _e");
});

// ------------------------------------------------------------------ 装配

const RABBIT = {
  kind: "rabbit",
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 4,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 1.8,
  team: "prey",
  loot: [{ kind: "meat", count: 2 }],
};

function mobRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  // ★ 批123：spawnMob 会把模板的战利品表挂成组件（game.loot）
  registerLootComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

test("[装配] spawnMob 挂的方向帧前缀与模板帧名同源（两处各配一次 = 永远一个姿势）", () => {
  const scene = new Scene("mob-dir", mobRegistry());
  const r = spawnMob(scene, RABBIT, 0.5, 0.5);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  const back = scene.find(r.value.nodeId)?.get<DirSprite>(DIR_SPRITE_TYPE);
  assert.ok(back instanceof DirSprite, "生物身上没有 render.dirSprite —— 朝向与图集之间没有任何代码连接");
  assert.equal(back.prefix, RABBIT.frame, "前缀必须等于模板的 frame");
  assert.equal(r.value.dirSprite, back, "handle 上那个必须就是节点上那一个");
});

test("[装配] 方向帧组件没注册 ⇒ 装配硬失败（不留「画得出来但不会转身」的怪）", () => {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("mob-no-dir", reg);
  const r = spawnMob(scene, RABBIT, 0.5, 0.5);
  assert.equal(r.ok, false, "少了 render.dirSprite 还照样生成 = 装配静默退化");
  if (r.ok) return;
  assert.equal((r.error.detail as { type?: string }).type, DIR_SPRITE_TYPE, "要点名缺的是哪个组件");
});
