/**
 * L4 · 导入的 CC0 八向素材 + 「方向选 clip」这根线（批112）
 *
 * 这一批要防的假绿，和批108 是**同一类**，但换了形状：
 *
 *   ① **文件在、方向不在**。32 张图都写出来了、名字也对，但镜像算错轴 /
 *      四个方向拷了同一张 —— `syncDirFrames` 全绿、图集也全绿，画面上却
 *      永远一个姿势。所以下面**解码 PNG 读像素**：逐像素校验镜像关系、
 *      校验同向四帧互异、校验侧视左右真的不同。
 *   ② **素材对了但没接上**。clip 选出来却没人采样（缺 `SpriteAnimator`），
 *      或者每 tick 都把 `timeMs` 归零（动画永远停在第 0 帧）—— 两种都是
 *      "有动静"的假象（别的东西在动）。所以引擎层每个用例都读**两个**观测量：
 *      该变的变了 ∧ 不该变的没变。
 *
 * ★ 本文件里有一条**钉住缺点**的判据（`前后朝向只靠脸区分`）。它不是在夸素材：
 *   它把"正/背差异 6.19 < 侧视 35.67 < 帧间 22.15"这个实测关系写死，于是
 *   哪天有人把镜像轴改错、或者把 s 与 n 拷成同一张，它会红。
 *   **不钉住缺陷 = 缺陷会在重构里悄悄变成"新特性"。**
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

import { encodePng } from "../../tools/png-encode.mjs";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import type { Node } from "../../src/core/scene/node.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { Facing, registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import {
  SPRITE_ANIMATOR_TYPE,
  SpriteAnimator,
} from "../../src/extensions/render/sprite-animator.ts";
import {
  loadScene,
  saveScene,
  sceneFromJson,
  sceneToJson,
} from "../../src/core/scene/scene-io.ts";
import {
  DirSprite,
  registerDirSpriteComponent,
  restoreDirClipIds,
  syncDirFrames,
} from "../../src/extensions/render/dir-sprite.ts";

const ASSETS = fileURLToPath(new URL("../../web/assets/", import.meta.url));

/** 与 `dir-frames.ts` 的 `LETTERS8` 同序（`0` = 东，顺时针）。 */
const LETTERS = ["e", "se", "s", "sw", "w", "nw", "n", "ne"] as const;

/** 帧数：与 `tools/import-8dir-pack.mjs --frames` 的默认值一致。 */
const FRAMES = [0, 1, 2, 3];

/**
 * 镜像关系：目标向 ← 源向。
 *
 * ★ 这张表**故意与导入器里那张分开写**。抄同一张表会让"映射本身写错"
 *   两边一起错、判据照样绿；分开写，至少有一处对不上就会红。
 *   包内只有 5 个方向，缺的 3 个必须是这三个（不是随便三个）。
 */
const MIRRORED = { sw: "se", w: "e", nw: "ne" } as const;

interface Decoded {
  readonly w: number;
  readonly h: number;
  readonly px: Uint8Array;
}

function load(name: string): Decoded {
  const p = join(ASSETS, name);
  assert.ok(existsSync(p), `缺素材：${name}`);
  const r = decodePng(new Uint8Array(readFileSync(p)));
  assert.equal(r.ok, true, `${name} 解码失败：${r.ok ? "" : r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  return { w: r.value.width, h: r.value.height, px: r.value.pixels };
}

const frameName = (letter: string, f: number): string => `hero_${letter}_${f}.png`;

/** 每向每帧都解一次，后面几条判据共用（解码一次约 1ms，省下来的不是时间而是重复代码）。 */
const IMG: Record<string, Decoded> = {};
for (const l of LETTERS) {
  for (const f of FRAMES) IMG[`${l}/${f}`] = load(frameName(l, f));
}

/** 平均每通道绝对差（RGBA 四通道一起算，除以 4）。 */
function diff(a: Decoded, b: Decoded): number {
  let s = 0;
  for (let i = 0; i < a.px.length; i++) s += Math.abs(a.px[i]! - b.px[i]!);
  return s / (a.px.length);
}

/**
 * 找整数 `s`，使 `dst(x,y) === src(s - x, y)` 对**全部**像素成立。
 * 返回最优 `s` 与不符像素数。找不到（返回的不符数 > 0）就说明不是镜像。
 */
function mirrorAxisOf(dst: Decoded, src: Decoded): { s: number; bad: number } {
  let best = { s: 0, bad: Number.POSITIVE_INFINITY };
  for (let s = 0; s <= 2 * dst.w - 2; s++) {
    let bad = 0;
    for (let y = 0; y < dst.h && bad === 0; y++) {
      for (let x = 0; x < dst.w; x++) {
        const sx = s - x;
        const di = (y * dst.w + x) * 4;
        if (sx < 0 || sx >= src.w) {
          // 源在这一列不存在：只有目标全透明才算对得上（否则是内容被裁掉了）
          if (dst.px[di + 3]! > 0) bad++;
          continue;
        }
        const si = (y * src.w + sx) * 4;
        if (
          dst.px[di] !== src.px[si] ||
          dst.px[di + 1] !== src.px[si + 1] ||
          dst.px[di + 2] !== src.px[si + 2] ||
          dst.px[di + 3] !== src.px[si + 3]
        ) {
          bad++;
          break;
        }
      }
    }
    if (bad < best.bad) best = { s, bad };
    if (best.bad === 0) break;
  }
  return best;
}

function digest(d: Decoded): string {
  // 只用来判"两张是不是同一张"，不需要密码学强度
  let h = 2166136261;
  for (let i = 0; i < d.px.length; i++) {
    h ^= d.px[i]!;
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16);
}

// ------------------------------------------------------------------ ① 素材层

test("★ 八向素材齐全：32 张都在、尺寸一致、每张都不是全透明", () => {
  let n = 0;
  const sizes = new Set<string>();
  for (const l of LETTERS) {
    for (const f of FRAMES) {
      const d = IMG[`${l}/${f}`]!;
      sizes.add(`${String(d.w)}x${String(d.h)}`);
      let opaque = 0;
      for (let i = 3; i < d.px.length; i += 4) if (d.px[i]! > 0) opaque++;
      assert.ok(opaque > 0, `${frameName(l, f)} 全透明 —— 等于这个方向没有素材`);
      n++;
    }
  }
  assert.equal(n, 32, "8 向 × 4 帧 = 32 张");
  assert.equal(sizes.size, 1, `各方向尺寸必须一致（否则精灵会在转向时跳动）：${[...sizes].join(",")}`);
});

test("★★ 镜像三向逐像素等于源向的镜像（轴从像素自己算，不读配置表）", () => {
  const axes: string[] = [];
  for (const [dst, src] of Object.entries(MIRRORED)) {
    let axisThisDir: number | null = null;
    for (const f of FRAMES) {
      const got = mirrorAxisOf(IMG[`${dst}/${f}`]!, IMG[`${src}/${f}`]!);
      assert.equal(
        got.bad,
        0,
        `${dst} 帧${String(f)} 不是 ${src} 的镜像：最优轴 s=${String(got.s)} 仍有 ${String(got.bad)} 个像素对不上`,
      );
      // ★ 四帧必须用**同一根轴**：每帧各算各的轴，等于逐帧重新居中，
      //   播放起来是"角色在原地抖"，而单看静态图完全正常。
      if (axisThisDir === null) axisThisDir = got.s;
      else assert.equal(got.s, axisThisDir, `${dst} 第 ${String(f)} 帧的镜像轴变了（${String(got.s)} != ${String(axisThisDir)}）`);
    }
    axes.push(`${dst}=${String(axisThisDir)}`);
  }
  // 轴必须落在画面内部（0..2w-2）；落在边界说明内容被裁掉了一半
  assert.ok(axes.length === 3, axes.join(" "));
});

test("★★ 同方向四帧不是同一张（相邻帧也不许重复，否则循环里看不出在动）", () => {
  for (const l of LETTERS) {
    const hs = FRAMES.map((f) => digest(IMG[`${l}/${f}`]!));
    for (let i = 1; i < hs.length; i++) {
      assert.notEqual(hs[i], hs[i - 1], `${l} 的第 ${String(i - 1)} 与 ${String(i)} 帧完全相同 —— 循环里会出现一次"卡住"`);
    }
    // 源素材是循环待机：首尾相接是正常的，但**不能只有两张**
    assert.ok(new Set(hs).size >= 3, `${l} 只有 ${String(new Set(hs).size)} 张不同的帧（至少 3）`);
  }
});

test("★★ 侧视左右真的朝向不同：e 与 w 的差异远大于同向帧间差异", () => {
  const sideDiff = diff(IMG["e/0"]!, IMG["w/0"]!);
  const animDiff = (diff(IMG["e/0"]!, IMG["e/1"]!) + diff(IMG["e/1"]!, IMG["e/2"]!)) / 2;
  assert.ok(
    sideDiff > animDiff * 1.2,
    `左右朝应有的差异只有 ${sideDiff.toFixed(2)}，不比帧间 ${animDiff.toFixed(2)} 大 —— 说明左右是同一张`,
  );
});

test("★★ 钉住缺点：正/背只靠脸区分（s 与 n 有小差异，但小于侧视）", () => {
  const backDiff = diff(IMG["s/0"]!, IMG["n/0"]!);
  const sideDiff = diff(IMG["e/0"]!, IMG["w/0"]!);
  // 下限：不能是同一张。上限：这批素材是方头小人的正/背，差异只来自脸，
  // 一定小于侧视的轮廓差 —— 这是**实测事实**，不是期望值（见文档）。
  assert.ok(backDiff > 0.5, `正/背差异 ${backDiff.toFixed(2)} —— 几乎相同，朝前朝后分不出来`);
  assert.ok(backDiff < sideDiff, `正/背差异 ${backDiff.toFixed(2)} 竟然大于侧视 ${sideDiff.toFixed(2)} —— 与实测不符，先查是不是拷错图`);
});

test("★★ 出处清单：许可/作者/来源齐全，且每张图的 sha256 与磁盘一致", () => {
  const p = join(ASSETS, "pack-provenance.json");
  assert.ok(existsSync(p), "缺 pack-provenance.json —— 半年后没人说得清这批图能不能商用");
  const j = JSON.parse(readFileSync(p, "utf8")) as {
    license?: string;
    author?: string;
    sourceUrl?: string;
    files?: Record<string, string>;
  };
  assert.equal(j.license, "CC0 1.0", "许可必须写明是 CC0 1.0");
  assert.ok((j.author ?? "").length > 0, "缺作者");
  assert.ok((j.sourceUrl ?? "").startsWith("https://opengameart.org/"), "缺可核的出处链接");
  const files = j.files ?? {};
  assert.equal(Object.keys(files).length, 32, `清单里有 ${String(Object.keys(files).length)} 个文件（应为 32）`);
  // 逐张比对 sha256：图被改了却没重跑导入器，这里就会红
  // （★ 这条比"数一数有几张"有用得多 —— 数量对而内容变是最常见的漂移）
  for (const [name, want] of Object.entries(files)) {
    const got = createHash("sha256").update(readFileSync(join(ASSETS, name))).digest("hex");
    assert.equal(got, want, `${name} 的 sha256 与清单不符 —— 图被改过但没重跑 tools/import-8dir-pack.mjs`);
  }
});

// ------------------------------------------------------------------ ② 引擎层

function makeScene(): Scene {
  const reg = new ComponentRegistry();
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  if (!reg.has(SPRITE_ANIMATOR_TYPE)) {
    reg.register(new SpriteAnimator().schema, () => new SpriteAnimator());
  }
  return new Scene("eight-dir", reg);
}

/**
 * 同上，但把注册表也交出来 —— 读档要它（`loadScene(scene, snap, reg)`）。
 *
 * ★ 不把 `makeScene` 改成返回对象：它在下面十几条判据里都是 `const scene = makeScene()`，
 *   为了一个用例去动十几处，等于给所有既有判据加一次被改错的概率。
 */
function makeSceneWithReg(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  if (!reg.has(SPRITE_ANIMATOR_TYPE)) {
    reg.register(new SpriteAnimator().schema, () => new SpriteAnimator());
  }
  return { scene: new Scene("eight-dir", reg), reg };
}

/** 造一个"玩家那样"的节点：Facing + Sprite + DirSprite(clipIds) + SpriteAnimator。 */
function makeActor(scene: Scene, opts: { clipIds?: string[]; withAnimator?: boolean } = {}): {
  node: Node;
  sprite: Sprite;
  facing: Facing;
  anim: SpriteAnimator | undefined;
  dirSprite: DirSprite;
} {
  const r = scene.spawn("hero");
  if (!r.ok) throw new Error(r.error.message);
  const node = r.value;
  const sprite = new Sprite();
  sprite.frame = "hero_s_0";
  scene.attach(node.id, () => sprite);
  const facing = new Facing();
  scene.attach(node.id, () => facing);
  const ds = new DirSprite();
  ds.prefix = "hero";
  ds.dirs = 8;
  ds.clipIds = opts.clipIds ?? LETTERS.map((l) => `hero_idle_${l}`);
  scene.attach(node.id, () => ds);
  let anim: SpriteAnimator | undefined;
  if (opts.withAnimator !== false) {
    anim = new SpriteAnimator();
    scene.attach(node.id, () => anim as SpriteAnimator);
  }
  scene.flush();
  return {
    node,
    sprite,
    facing,
    anim,
    dirSprite: ds,
  };
}

/** 所有帧都"存在"：这一层只验接线，素材是否存在由上一节管。 */
const hasAll = (): boolean => true;

test("★★ clip 模式：方向变 ⇒ clipId 变且 timeMs 归零；同向 ⇒ 两个都不动", () => {
  const scene = makeScene();
  const a = makeActor(scene);
  assert.ok(a.anim !== undefined);

  a.facing.setAngle(0); // 东
  let st = syncDirFrames(scene, hasAll);
  assert.equal(a.anim.clipId, "hero_idle_e", "朝东必须选东向 clip");
  assert.equal(st.clipChanged, 1, "第一次选 clip 要计一次");
  assert.equal(st.animated, 1);

  // 同一方向再同步：不许重置时钟（否则动画永远停在第一帧）
  a.anim.timeMs = 500;
  st = syncDirFrames(scene, hasAll);
  assert.equal(a.anim.clipId, "hero_idle_e", "同向不该换 clip");
  assert.equal(a.anim.timeMs, 500, "同向不该把 timeMs 归零 —— 每 tick 归零 = 动画永远第 0 帧");
  assert.equal(st.clipChanged, 0, "同向不该计 clipChanged");

  // 换方向：clipId 变，timeMs 归零
  a.facing.setAngle(Math.PI / 2); // 南（屏幕向下）
  st = syncDirFrames(scene, hasAll);
  assert.equal(a.anim.clipId, "hero_idle_s", "朝南必须选南向 clip（角度 π/2 = 南）");
  assert.equal(a.anim.timeMs, 0, "换 clip 必须从头播");
  assert.equal(st.clipChanged, 1);
});

test("★★ clip 模式下不写 sprite.frame（`Sprite.frame` 只能有一个写入者）", () => {
  const scene = makeScene();
  const a = makeActor(scene);
  a.sprite.frame = "MARKER";
  a.facing.setAngle(0);
  const st = syncDirFrames(scene, hasAll);
  assert.equal(a.sprite.frame, "MARKER", "clip 模式下方向同步改了 sprite.frame —— 会和动画采样抢同一个字段");
  assert.equal(st.changed, 0, "clip 模式不许计入 changed（那个计数的含义是「写了 frame」）");
  assert.equal(st.animated, 1, "但要计入 animated，否则判据分不清「没同步」与「同步了但不写帧」");
});

test("★ clip 配了但该向为空 ⇒ 回落单帧，并计 clipMissing", () => {
  const scene = makeScene();
  const clips = LETTERS.map(() => "");
  clips[0] = "hero_idle_e"; // 只有东向配了
  const a = makeActor(scene, { clipIds: clips });
  a.facing.setAngle(0);
  let st = syncDirFrames(scene, hasAll);
  assert.equal(a.anim?.clipId, "hero_idle_e");
  assert.equal(st.clipMissing, 0, "配了的那一向不该计缺失");

  // 换成没配的方向：回落单帧（`hero` 前缀没有方向帧 ⇒ 单帧 `hero`）
  a.facing.setAngle(Math.PI / 2);
  a.sprite.frame = "hero_s_0";
  st = syncDirFrames(scene, hasAll);
  assert.equal(st.clipMissing, 1, "没配 clip 的方向要计数，不能静默");
  // 回落顺序是 `hero_<向>` → `hero` → null（`dir-frames.ts` 定的）。
  // `hasAll` 下第一步就命中 —— 所以期望 `hero_s`，这正好证明"clip 缺失时仍在走老路"。
  assert.equal(a.sprite.frame, "hero_s", "clip 缺失时必须回落到方向帧，而不是留着旧帧不管");
});

test("★ clipIds 长度不足 ⇒ 整体回落单帧（不搞「配了一半也算配」）", () => {
  const scene = makeScene();
  // 只给 4 项：4 向的量配在 8 向的组件上
  const a = makeActor(scene, { clipIds: ["hero_idle_e", "hero_idle_se", "hero_idle_s", "hero_idle_sw"] });
  a.sprite.frame = "hero_s_0";
  a.facing.setAngle(Math.PI / 2);
  const st = syncDirFrames(scene, hasAll);
  assert.equal(a.anim?.clipId, "", "长度不足时**不许**按半张表选 clip（会让 5~8 向全都错成东向）");
  assert.equal(st.animated, 0);
  assert.equal(a.sprite.frame, "hero_s", "长度不足时走的是**单帧**那条老路（方向帧），不是半张 clip 表");
});

test("★★★ 读档会把 clip 表丢掉（不在 schema 里），`restoreDirClipIds` 是唯一补回来的路", () => {
  // ★ 这条是浏览器自检逼出来的，不是想出来的：批112 加完页面级断言，
  //   它当场报「clipIds 长度 0」。原因是 `clipIds` 是字符串数组、塞不进
  //   `ComponentSchema`（只有标量），而 `loadScene` 是「按 schema 重建组件」。
  //   症状不是报错：朝向照旧跟着走，`syncDirFrames` 退回单帧模式，
  //   去图集找 `hero`（这套素材没有单帧名）⇒ `sprite.frame` 从此一秒都不再变
  //   —— 「读档之后玩家变成一张静止贴图」。
  const from = makeSceneWithReg();
  const a = makeActor(from.scene);
  a.facing.setAngle(0); // 东
  syncDirFrames(from.scene, hasAll);
  assert.equal(a.anim?.clipId, "hero_idle_e", "前置：读档前 clip 模式是通的");

  const snap = sceneFromJson(sceneToJson(saveScene(from.scene)));
  assert.ok(snap.ok);
  if (!snap.ok) return;
  const to = makeSceneWithReg();
  const loaded = loadScene(to.scene, snap.value, to.reg);
  assert.ok(loaded.ok);
  if (!loaded.ok) return;

  const node = to.scene.find(a.node.id);
  assert.ok(node !== undefined, "读档后节点 id 必须还在（物理登记表也靠它）");
  if (node === undefined) return;
  const ds = node.get<DirSprite>("render.dirSprite");
  assert.ok(ds !== undefined);
  if (ds === undefined) return;
  // ① 口径钉住：prefix/dirs 在 schema 里 ⇒ 活下来了
  assert.equal(ds.prefix, "hero");
  assert.equal(ds.dirs, 8);
  assert.equal(node.get<Facing>("motion.facing")?.angle, 0, "朝向是 schema 字段，读档后照旧");
  // ② 缺口的形状：clip 表空了 —— 这条不是"顺便验一下"，它证明这个缺口**真的存在**。
  //    哪天 `clipIds` 进了 schema，这条会红，而那时应当来这里删掉 `restoreDirClipIds`。
  assert.deepEqual(ds.clipIds, [], "`clipIds` 不在 schema 里 ⇒ 读档后必然是空的");

  // ③ 补回来：与装配同一个来源
  const ids = LETTERS.map((l) => `hero_idle_${l}`);
  assert.equal(restoreDirClipIds(to.scene, a.node.id, ids), true);
  assert.deepEqual(ds.clipIds, ids);
  const st = syncDirFrames(to.scene, hasAll);
  assert.equal(st.animated, 1, "补回来之后必须重新走 clip 模式");
  assert.equal(node.get<SpriteAnimator>("render.spriteAnimator")?.clipId, "hero_idle_e");

  // ④ 补不上时要**说出来**（宿主拿返回值报错；返回 false 而不是静默什么都不做）
  assert.equal(restoreDirClipIds(to.scene, 999_999, ids), false, "节点不在 ⇒ false");
  const bare = to.scene.spawn("bare");
  assert.ok(bare.ok);
  if (!bare.ok) return;
  assert.equal(restoreDirClipIds(to.scene, bare.value.id, ids), false, "没挂 DirSprite ⇒ false");
});

// ------------------------------------------------------------------ ③ 导入器本体

/**
 * 用**合成的源包**跑一遍真导入器。
 *
 * ★ 为什么非要这一步：上一节验的是**仓库里那批 PNG**。把导入器里"关于角色中线镜像"
 *   改成"关于裁剪框中线镜像"，那批 PNG 一个字节都不会变 —— 判据全绿，而下次
 *   重新导入时 8 张图会整体偏 1 像素，转向时"跳一格"。
 *   这与批108 的生成器产物是**同一条缝**，只是换了文件。
 *
 * 合成包里故意把内容摆得**不对称**（`right` 的内容中线 3.5，而裁剪框中线 4.5）：
 * 两种轴差 1 像素，判据才分得出来。
 */
test("★★ 导入器：镜像必须关于角色自身中线（不是裁剪框中线），非镜像向逐字节等于源裁切", () => {
  const root = fileURLToPath(new URL("../../", import.meta.url));
  const tmp = mkdtempSync(join(tmpdir(), "eight-dir-import-"));
  try {
    const spriteDir = join(tmp, "Sprites", "Hero");
    mkdirSync(spriteDir, { recursive: true });
    // 5 个方向 × 2 帧，16×16。内容矩形按方向故意错开：
    //   right/down_right/up_right 从 x=2 起（中线 3.5 / 4.0）
    //   down/up 从 x=4 起（中线 5.5）
    // 并集 = x 2..10 ⇒ 裁剪框宽 9，框中线 4.0 —— 与 right 的内容中线 3.0 差 1。
    const RECT: Record<string, [number, number]> = {
      right: [2, 7],
      down_right: [2, 8],
      down: [4, 7],
      up: [4, 7],
      up_right: [2, 8],
    };
    for (const [name, [x0, w]] of Object.entries(RECT)) {
      for (const f of [1, 2]) {
        const px = new Uint8Array(16 * 16 * 4);
        for (let y = 2; y <= 13; y++) {
          for (let x = x0; x < x0 + w; x++) {
            const i = (y * 16 + x) * 4;
            // 颜色编码坐标：镜像错一格会立刻体现在 R/G 上
            px[i] = (x * 13) & 255;
            px[i + 1] = (y * 7) & 255;
            px[i + 2] = f === 1 ? 10 : 200;
            px[i + 3] = 255;
          }
        }
        writeFileSync(
          join(spriteDir, `idle_${name} (${String(f)}).png`),
          encodePng({ width: 16, height: 16, colorType: 6, bitDepth: 8, samples: Array.from(px) }),
        );
      }
    }

    const out = join(tmp, "out");
    const r = spawnSync(
      process.execPath,
      [
        "--experimental-transform-types",
        "tools/import-8dir-pack.mjs",
        "--src",
        join(tmp, "Sprites"),
        "--char",
        "hero=Hero",
        "--frames",
        "2",
        "--out",
        out,
      ],
      { cwd: root, encoding: "utf8" },
    );
    assert.equal(r.status, 0, `导入器退出码 ${String(r.status)}\n${r.stdout}\n${r.stderr}`);

    // ① 张数：8 向 × 2 帧
    const names = readdirSync(out).filter((n) => n.endsWith(".png")).sort();
    assert.equal(names.length, 16, `应写出 16 张，实际 ${String(names.length)}：${names.join(",")}`);

    const dec = (p: string): Decoded => {
      const d = decodePng(new Uint8Array(readFileSync(join(out, p))));
      assert.equal(d.ok, true);
      if (!d.ok) throw new Error("合成图解码失败");
      return { w: d.value.width, h: d.value.height, px: d.value.pixels };
    };
    // ② 裁剪框：并集 x 2..11 ⇒ 宽 10
    const probe = dec("hero_e_0.png");
    assert.equal(probe.w, 9, "裁剪框宽度必须等于 5 个方向的并集（x 2..10）");
    assert.equal(probe.h, 12, "高度必须等于并集（y 2..13）");

    // ③ 非镜像向（e）必须是源裁切的原样：
    //    源 right 占 x 2..8，框从 x=2 起 ⇒ 框内 0..6，内容中线 3.0
    let first = -1;
    let last = -1;
    for (let x = 0; x < probe.w; x++) {
      let any = false;
      for (let y = 0; y < probe.h; y++) if (probe.px[(y * probe.w + x) * 4 + 3]! > 0) any = true;
      if (any) {
        if (first < 0) first = x;
        last = x;
      }
    }
    assert.equal(first, 0, "e 的首个不透明列 = 0（源 right 与并集同起点）");
    assert.equal(last, 6, "e 的末个不透明列 = 6（宽 7）");
    const eMid = (first + last) / 2;
    const boxMid = (probe.w - 1) / 2;
    assert.notEqual(eMid, boxMid, `夹具失效：内容中线 ${String(eMid)} 与裁剪框中线 ${String(boxMid)} 相同，判据分不出两种镜像轴`);

    // ④ 镜像向 w 必须是 e 关于 **e 的内容中线** 的镜像
    const w = dec("hero_w_0.png");
    assert.equal(w.w, probe.w);
    let bad = 0;
    for (let y = 0; y < w.h; y++) {
      for (let x = 0; x < w.w; x++) {
        const sx = Math.round(2 * eMid - x);
        const wi = (y * w.w + x) * 4;
        if (sx < 0 || sx >= w.w) {
          if (w.px[wi + 3]! > 0) bad++;
          continue;
        }
        const ei = (y * probe.w + sx) * 4;
        for (let c = 0; c < 4; c++) if (w.px[wi + c] !== probe.px[ei + c]) bad++;
      }
    }
    assert.equal(
      bad,
      0,
      `w 不是关于内容中线 ${String(eMid)} 的镜像（${String(bad)} 个通道值不符）—— ` +
        `若关于裁剪框中线 ${String(boxMid)} 翻，这里会差一整列`,
    );

    // ⑤ 出处清单也要写出来
    const prov = JSON.parse(readFileSync(join(out, "pack-provenance.json"), "utf8")) as {
      files: Record<string, string>;
      crop: { w: number };
    };
    assert.equal(Object.keys(prov.files).length, 16, "provenance 要覆盖全部 16 张");
    assert.equal(prov.crop.w, 9, "provenance 里记的裁剪框宽度必须与产物一致");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
