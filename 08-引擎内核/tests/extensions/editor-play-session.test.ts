/**
 * L4 · 编辑器：试玩会话（PIE session）的判据
 *
 * 这一组验的不是"能不能回滚"，而是**三条容易做反的边界**：
 *
 * ① **没变就别重建**。回滚有两条路：比文本、或一律重建。一律重建看起来更安全，
 *    实际代价是"点一下播放立刻停止"会把整个工程换一遍节点实例（`loadScene` 先
 *    `clear()` 再重建），而画面上完全看不出来。所以判据必须能区分
 *    「没重建」和「重建了但值一样」—— 靠 `scene.find(id)` 的**恒等**。
 *
 * ② **世界变了必须回滚到进入那一刻**，包括"模拟写进去的位置"和"人改的字段"
 *    这两种来源。只测其中一种的话，另一条的漏法一模一样。
 *
 * ③ **回滚不动撤销栈**。历史记的是文档；试玩没改文档（试玩期的改动不进历史，
 *    见 `editor-entry` 的 `commitField`）。回滚把值恢复之后，历史条目仍然指同一批
 *    id 与字段，所以它必须还在 —— 清掉反而让人连"进试玩之前那一步"都退不回去。
 *    ★ 这一条是**宿主**的决定（模型层压根不接 history），所以判据在
 *      编辑器页自检里（`# 停止试玩……撤销栈条数不变`），本文件证不到它。
 *       写在这里只是免得后来者以为漏了。
 *
 * 判别法还是那一句：**把被测逻辑删掉，这条还会绿吗**。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { beginPlaySession, endPlaySession, EDIT_PIE_ROLLBACK_FAILED, type StopDeps } from "../../src/extensions/editor/play-session.ts";

/** 一个"每 tick 自己往前走"的组件 —— 试玩期间世界会自己改自己，这就是最小模型。 */
const CRAWLER_TYPE = "test.crawler";
const CRAWLER_SCHEMA: ComponentSchema = {
  type: CRAWLER_TYPE,
  fields: { speed: FieldType.Float },
};

class Crawler extends Component {
  readonly schema: ComponentSchema = CRAWLER_SCHEMA;
  speed = 1;
  override onUpdate(_tick: number, dt: number): void {
    const n = this.node;
    if (n === null) return;
    n.setLocalPosition(n.localPosition.x + this.speed * dt, n.localPosition.y);
  }
}

function setup(): StopDeps & { ids: { still: number; crawling: number }; text: () => string } {
  const reg = new ComponentRegistry();
  reg.register(CRAWLER_SCHEMA, () => new Crawler());
  const scene = new Scene("pie", reg);
  const still = scene.spawnImmediate("still", scene.rootId);
  const crawling = scene.spawnImmediate("crawling", still.id);
  scene.attach(crawling.id, () => new Crawler());
  scene.flush();
  return {
    scene,
    registry: reg,
    ids: { still: still.id, crawling: crawling.id },
    text: () => sceneToJson(saveScene(scene)),
  };
}

test("★ 世界一个字节都没变：不重建场景（节点实例还是同一个）", () => {
  const deps = setup();
  const before = deps.scene.find(deps.ids.crawling);
  assert.ok(before !== undefined);

  const s = beginPlaySession(deps.scene);
  const r = endPlaySession(deps, s);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  assert.equal(r.value.rolledBack, false, "什么都没动却报了回滚");
  assert.equal(r.value.made, 0);
  // ★ 这条才是重点：值一样不等于没重建。恒等比较能分开两者。
  assert.equal(
    deps.scene.find(deps.ids.crawling),
    before,
    "场景被重建了 —— 世界一个字节都没变，不该换掉全部节点实例",
  );
});

test("★★ 模拟挪动过：回滚到进入那一刻（位置与文本都回去）", () => {
  const deps = setup();
  const node = deps.scene.find(deps.ids.crawling);
  assert.ok(node !== undefined);
  const x0 = node.localPosition.x;
  const t0 = deps.text();

  const s = beginPlaySession(deps.scene);
  // 让世界自己跑 10 个 tick（每 tick 0.1 秒 × speed 1 ⇒ 大约 +1）
  for (let i = 1; i <= 10; i++) deps.scene.step(i, 0.1);
  const moved = deps.scene.find(deps.ids.crawling);
  assert.ok(moved !== undefined);
  assert.ok(moved.localPosition.x > x0, `世界没动（x 还是 ${String(moved.localPosition.x)}），这条判据会假绿`);

  const r = endPlaySession(deps, s);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  assert.equal(r.value.rolledBack, true, "世界变了却没回滚");
  const back = deps.scene.find(deps.ids.crawling);
  assert.ok(back !== undefined);
  assert.equal(back.localPosition.x, x0, "位置没回到进入试玩那一刻");
  assert.equal(deps.text(), t0, "回滚后文档文本与进入前不一致");
});

test("★ 人改的字段也要回滚（不只是模拟写的位置）", () => {
  const deps = setup();
  const t0 = deps.text();
  const s = beginPlaySession(deps.scene);
  const c = [...deps.scene.componentsOf<Crawler>(CRAWLER_TYPE)][0];
  assert.ok(c !== undefined);
  c.speed = 9;
  assert.notEqual(deps.text(), t0, "改了字段却没进存档 —— 这条判据会假绿");

  const r = endPlaySession(deps, s);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  assert.equal(r.value.rolledBack, true);
  const after = [...deps.scene.componentsOf<Crawler>(CRAWLER_TYPE)][0];
  assert.ok(after !== undefined);
  assert.equal(after.speed, 1, "字段没回滚到进入试玩时的值");
});

test("★ 回滚保住节点 id：选中集与历史里记的 id 仍然指得到", () => {
  const deps = setup();
  const s = beginPlaySession(deps.scene);
  deps.scene.step(1, 1);
  const r = endPlaySession(deps, s);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  assert.ok(deps.scene.find(deps.ids.still) !== undefined, `回滚后 #${String(deps.ids.still)} 找不到了`);
  assert.ok(deps.scene.find(deps.ids.crawling) !== undefined, `回滚后 #${String(deps.ids.crawling)} 找不到了`);
  // 父关系也得回来：回滚是重建，"crawling 挂在 still 下"这条不能丢
  const n = deps.scene.find(deps.ids.crawling);
  assert.ok(n !== undefined);
  assert.equal(n.parent?.id, deps.ids.still, "回滚把父子关系弄丢了");
});

test("★ 回滚之后再新建节点，id 不与现存的撞", () => {
  const deps = setup();
  const s = beginPlaySession(deps.scene);
  deps.scene.step(1, 1);
  const r = endPlaySession(deps, s);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);

  // ★ `clear()` 不清 `nextId`，但重建时每个节点都显式要了 id（`allocateId(explicit)`
  //   会把计数器推到 id+1）。这条判据盯的就是那个"推"：漏掉的话新建出来的节点
  //   会撞上一个刚回滚回来的 id，症状是 `SCENE.DUPLICATE_ID` 或悄悄覆盖别人。
  const fresh = deps.scene.spawnImmediate("fresh", deps.scene.rootId);
  deps.scene.flush();
  const ids = new Set<number>();
  deps.scene.root.walk((n) => ids.add(n.id));
  assert.equal(ids.size, 4, `回滚后新建的节点 id 撞了（现有 id ${[...ids].join(",")}，期望 4 个不同）`);
  assert.ok(fresh.id > deps.ids.crawling, "新节点的 id 没往前走");
});

test("★ 回滚失败要报出来，而不是假装成功", () => {
  const deps = setup();
  const s = beginPlaySession(deps.scene);
  deps.scene.step(1, 1); // 让世界变脏 —— 不脏的话根本不会走到回滚那条路
  // 篡改快照版本：唯一能让 `loadScene` 明确拒绝的入口（见 `session.ts` 对这条的注释）
  const bad = { ...s.before, format: 999 };
  const r = endPlaySession(deps, { before: bad, text: s.text, edits: 0 });
  assert.equal(r.ok, false, "回滚失败却返回成功 —— 人会在半个世界里继续编辑");
  if (r.ok) return;
  assert.equal(r.error.code, EDIT_PIE_ROLLBACK_FAILED);
  assert.match(r.error.message, /不可信/, `消息里没说清后果：${r.error.message}`);
});
