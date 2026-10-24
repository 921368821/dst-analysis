/**
 * L4 · 受击反馈：「打中了」看得见，且**闪完之后回到原样**
 *
 * ★★ 这个文件的核心不是"闪了没有"，而是三处**只有用对了语料才分得出来**的实现：
 *
 *   ① 基色**不是白色**。到期把 `r/g/b` 写回 1,1,1（最省事的写法）在白色精灵上
 *      与"还原原色"逐字节相同 —— 判据必须用一个 **0.5/0.8/0.2** 这种非白基色的精灵，
 *      否则 M267（还原成白色）是抓不到的。
 *   ② 连挨三下之后颜色**精确**回到原值。每次 `flash` 都抓一次基色的话，
 *      第二次抓到的是闪色，颜色会一路漂向红 —— 而"闪了"和"还原了"每一轮都成立。
 *   ③ 重复触发**取最大剩余**而不是累加。累加会让"闪到什么时候"取决于挨了几下，
 *      回放/存档都对不上；判据用"先闪 3 tick，第 2 tick 再闪 5 tick"来分辨。
 *
 * ★ 还有一个"传了没用"的同族陷阱：`Sprite.r/g/b` 是**渲染真的读的字段**
 *   （`spriteToRenderItem` → `Batch.push` 顶点色 → GL），所以这里断言精灵颜色
 *   等价于断言画面颜色 —— 这与批66 的 `firstIndex`（存了但从未使用）不是一类。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { FieldType } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger } from "../../src/foundation/log/logger.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { Services } from "../../src/core/tokens.ts";
import { SPRITE_TYPE, Sprite, makeSprite } from "../../src/extensions/render/sprite.ts";
import {
  FEEDBACK_TYPE,
  FLASH_B,
  FLASH_G,
  FLASH_R,
  FX_BAD_TICKS,
  FX_NO_NODE,
  FX_NO_SPRITE,
  PUNCH_H,
  PUNCH_W,
  clearFeedback,
  createFeedbackModule,
  flash,
  punch,
  registerFeedbackComponent,
  restoreSize,
  restoreTint,
  type Feedback,
} from "../../src/extensions/render/feedback.ts";

/** 非白基色（见文件头 ①：白基色会让"还原"与"洗白"不可分辨）。 */
const BASE = { r: 0.5, g: 0.8, b: 0.2, a: 0.9 };
const BASE_SIZE = { w: 2, h: 3 };

function mk(): { scene: Scene; id: number } {
  const reg = new ComponentRegistry();
  // ★ 精灵也要注册：`attach` 对没注册的组件类型返回失败，而"失败"在
  //   `assert.ok(scene.attach(...).ok)` 之前就被吞掉的话，后面每条判据都会
  //   卡在"前提没造出来"上（这里踩过一次，14 条全红）。
  reg.register(new Sprite().schema, () => new Sprite());
  registerFeedbackComponent(reg);
  const scene = new Scene("fx", reg);
  const n = scene.spawnAt("mob", 5.5, 5.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const id = n.value.id;
  const sp = makeSprite("rabbit", BASE_SIZE.w, BASE_SIZE.h);
  sp.r = BASE.r;
  sp.g = BASE.g;
  sp.b = BASE.b;
  sp.a = BASE.a;
  assert.ok(scene.attach(id, () => sp).ok);
  scene.flush();
  return { scene, id };
}

function spriteOf(scene: Scene, id: number) {
  const sp = scene.find(id)?.get<ReturnType<typeof makeSprite>>(SPRITE_TYPE);
  if (sp === undefined) throw new Error("判据前提没造出来：节点上没有 sprite");
  return sp;
}

function fbOf(scene: Scene, id: number): Feedback {
  const fb = scene.find(id)?.get<Feedback>(FEEDBACK_TYPE);
  if (fb === undefined) throw new Error("判据前提没造出来：节点上没有 feedback");
  return fb;
}

function mkCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "feedback-test");
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: {} as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

function initMod(scene: Scene) {
  const mod = createFeedbackModule();
  const r = mod.init(mkCtx(scene));
  assert.ok(!(r instanceof Promise));
  if (r !== undefined) assert.ok(r.ok, r.ok ? "" : `init 失败：${r.error.code}`);
  return mod;
}

test("[反馈] flash：闪的时候颜色真的变了（且**不**是白色）", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const r = flash(scene, id, 10);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.value.remaining, 10);
  assert.equal(r.value.extended, false);
  assert.equal(sp.r, FLASH_R);
  assert.equal(sp.g, FLASH_G);
  assert.equal(sp.b, FLASH_B);
  assert.equal(sp.a, BASE.a, "闪色只该改 r/g/b，透明度不该被动");
  assert.notEqual(`${String(sp.r)},${String(sp.g)},${String(sp.b)}`, "1,1,1", "闪白在浅色精灵上等于没闪");
});

test("[反馈] ★ 到期还原成**受击前的颜色**，不是白色", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 3).ok);
  mod.update(1);
  mod.update(1);
  assert.equal(sp.g, FLASH_G, "还差 1 tick，仍该是闪色");
  mod.update(1);
  assert.equal(sp.g, BASE.g, "到期必须还原成 0.8（还原成 1 会把精灵洗白）");
  assert.equal(sp.r, BASE.r);
  assert.equal(sp.b, BASE.b);
  assert.equal(sp.a, BASE.a);
});

test("[反馈] ★★ 在**还闪着的时候**再挨两下：颜色不漂移", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 5).ok);
  mod.update(1);
  mod.update(1); // 仍剩 3 tick —— 精灵此刻是**闪色**
  assert.equal(sp.g, FLASH_G, "前提：它现在就是闪色（不然下面测不到「重抓基色」）");
  assert.ok(flash(scene, id, 5).ok); // 闪着的时候再打一下（漂移就发生在这一刻）
  mod.update(1);
  assert.ok(flash(scene, id, 5).ok);
  // 一直跑到不闪为止
  let guard = 0;
  while (fbOf(scene, id).flashTicks > 0 && guard < 50) {
    mod.update(1);
    guard++;
  }
  assert.equal(guard < 50, true, "闪烁应该自己结束（最多 5 tick），不该一直闪下去");
  assert.equal(sp.r, BASE.r, "必须精确回 0.5：漂了就说明每下都抓了一次基色（抓到的是闪色）");
  assert.equal(sp.g, BASE.g);
  assert.equal(sp.b, BASE.b);
  assert.equal(sp.a, BASE.a);
});

test("[反馈] ★ 重复触发取最大剩余（不是累加）", () => {
  const { scene, id } = mk();
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 3).ok);
  mod.update(1); // 剩 2
  const second = flash(scene, id, 5);
  assert.equal(second.ok, true);
  if (!second.ok) return;
  assert.equal(second.value.extended, true, "第二次应报告「本来就在闪」");
  assert.equal(second.value.remaining, 5, "取最大值 ⇒ 5；累加的实现在这里会是 7");
  // 3 + 5 = 8 的累加实现要 8 tick 才灭；正确的是 5
  for (let t = 0; t < 4; t++) mod.update(1);
  assert.equal(fbOf(scene, id).flashTicks, 1, "第 5 tick 时只剩 1（累加实现会剩 3）");
  mod.update(1);
  assert.equal(fbOf(scene, id).flashTicks, 0);
});

test("[反馈] 大小写错：ticks 不是正整数一律拒绝，且不动任何状态", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  for (const bad of [0, -1, 2.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    const r = flash(scene, id, bad);
    assert.equal(r.ok, false, `${String(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, FX_BAD_TICKS);
  }
  assert.equal(sp.g, BASE.g, "被拒绝的调用不该改颜色");
  assert.equal(scene.find(id)?.get(FEEDBACK_TYPE), undefined, "被拒绝的调用不该挂组件");
});

test("[反馈] 节点不存在 / 没有精灵：报错而不是静默成功", () => {
  const { scene, id } = mk();
  const noNode = flash(scene, 999, 5);
  assert.equal(noNode.ok, false);
  if (!noNode.ok) assert.equal(noNode.error.code, FX_NO_NODE);

  // 只有节点、没有 sprite
  const bare = scene.spawnAt("invisible", 1.5, 1.5);
  assert.equal(bare.ok, true);
  if (!bare.ok) return;
  // ★ `spawnAt` 也走命令队列：不 flush 的话 `find()` 找不到它，
  //   于是这条判据会拿到 FX.NO_NODE 而不是 FX.NO_SPRITE（踩过一次）。
  scene.flush();
  assert.notEqual(scene.find(bare.value.id), undefined, "前提：节点真的进了场景");
  assert.equal(scene.find(bare.value.id)?.get(SPRITE_TYPE), undefined, "前提：它没有精灵");
  const noSprite = flash(scene, bare.value.id, 5);
  assert.equal(noSprite.ok, false);
  if (!noSprite.ok) assert.equal(noSprite.error.code, FX_NO_SPRITE);
  assert.ok(id > 0);
});

test("[反馈] punch：尺寸按倍率变化，到期还原成原尺寸", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const mod = initMod(scene);
  const r = punch(scene, id, 2);
  assert.equal(r.ok, true);
  assert.equal(sp.width, BASE_SIZE.w * PUNCH_W);
  assert.equal(sp.height, BASE_SIZE.h * PUNCH_H);
  mod.update(1);
  mod.update(1);
  assert.equal(sp.width, BASE_SIZE.w, "还原必须是 2（不是 1）");
  assert.equal(sp.height, BASE_SIZE.h);
});

test("[反馈] ★ 闪与挤互不干扰：颜色在闪、尺寸已还原", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 10).ok);
  assert.ok(punch(scene, id, 2).ok);
  for (let t = 0; t < 2; t++) mod.update(1);
  assert.equal(sp.width, BASE_SIZE.w, "挤压已到期");
  assert.equal(sp.g, FLASH_G, "闪烁还没到期");
  for (let t = 0; t < 8; t++) mod.update(1);
  assert.equal(sp.g, BASE.g);
});

test("[反馈] restoreTint 幂等：没闪的时候不动手，返回 false", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  assert.ok(flash(scene, id, 1).ok);
  assert.equal(restoreTint(scene, id), false, "还在闪，不该还原");
  const mod = initMod(scene);
  mod.update(1);
  const before = sp.g;
  assert.equal(restoreTint(scene, id), false, "已经还原过了，第二次必须是什么都不做");
  assert.equal(sp.g, before);
});

test("[反馈] ★ 还原之后再有人改颜色：不会被改回去（幂等的真正含义）", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 1).ok);
  mod.update(1); // 到期还原成 0.8
  sp.g = 0.1; // 宿主自己把它改暗（例如"进入夜晚"或"尸体变灰"）
  assert.equal(restoreTint(scene, id), false, "没有闪烁时不该覆盖宿主的改动");
  assert.equal(sp.g, 0.1);
});

test("[反馈] clearFeedback：两个通道立刻结束，状态归零", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  assert.ok(flash(scene, id, 100).ok);
  assert.ok(punch(scene, id, 100).ok);
  const done = clearFeedback(scene, id);
  assert.deepEqual(done, { tint: true, size: true });
  assert.equal(sp.g, BASE.g);
  assert.equal(sp.width, BASE_SIZE.w);
  assert.equal(fbOf(scene, id).flashTicks, 0);
  assert.equal(fbOf(scene, id).punchTicks, 0);
});

test("[反馈] 模块统计：闪几个、还原几次，且到点后不再算「在闪」", () => {
  const { scene, id } = mk();
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 3).ok);
  assert.ok(punch(scene, id, 1).ok);
  mod.update(1);
  assert.equal(mod.stats.flashing, 1, "还剩 2 tick，应算在闪");
  assert.equal(mod.stats.punching, 0, "挤压已到期");
  assert.equal(mod.stats.restored, 1, "挤压还原了一次");
  mod.update(1);
  mod.update(1);
  assert.equal(mod.stats.flashing, 0);
  assert.equal(mod.stats.restored, 2, "颜色也还原了 ⇒ 累计 2");
});

test("[反馈] ★ 精灵被摘掉后到期：记 orphaned，不炸、也不假装还原了", () => {
  const { scene, id } = mk();
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 2).ok);
  scene.detach(id, SPRITE_TYPE);
  scene.flush();
  assert.equal(scene.find(id)?.get(SPRITE_TYPE), undefined, "前提：精灵确实被摘掉了");
  mod.update(1);
  mod.update(1);
  assert.equal(mod.stats.orphaned, 1, "组件在、精灵没了 ⇒ 要人看");
  assert.equal(mod.stats.restored, 0, "没还原成任何东西，不该计入 restored");
});

test("[反馈] ★ 闪红时被宿主改成灰：到期**不覆盖**，记 overridden", () => {
  const { scene, id } = mk();
  const sp = spriteOf(scene, id);
  const mod = initMod(scene);
  assert.ok(flash(scene, id, 2).ok);
  sp.r = 0.3;
  sp.g = 0.3;
  sp.b = 0.3; // 这一下打死了它，宿主把它变灰
  mod.update(1);
  mod.update(1);
  assert.equal(sp.g, 0.3, "到期不该把灰改回 0.8（否则「死后变灰」会被闪色还原顶掉）");
  assert.equal(mod.stats.overridden, 1);
  assert.equal(mod.stats.restored, 0, "没写回任何颜色，不该计入 restored");
});

test("[反馈] 组件字段类型：基值是浮点、倒计时是整数（存错类型会截断）", () => {
  const { scene, id } = mk();
  assert.ok(flash(scene, id, 4).ok);
  assert.ok(punch(scene, id, 4).ok);
  const fb = fbOf(scene, id);
  assert.equal(fb.schema.type, FEEDBACK_TYPE);
  // 倒计时用整数（0.5 tick 没有意义）；基值必须是浮点（整数会把 0.9 截成 0 = 全透明）
  for (const f of ["flashTicks", "flashTotal", "punchTicks", "punchTotal"] as const) {
    assert.equal(fb.schema.fields[f], FieldType.Int, `${f} 必须是 Int`);
  }
  for (const f of ["baseR", "baseG", "baseB", "baseA", "baseW", "baseH"] as const) {
    assert.equal(fb.schema.fields[f], FieldType.Float, `${f} 必须是 Float（Int 会把 0.9 截成 0）`);
  }
  assert.equal(restoreSize(scene, id), false, "还在挤压时不该动尺寸");
});
