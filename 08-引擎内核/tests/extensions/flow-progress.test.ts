/**
 * L4 · 关卡流程：**场景状态与游戏存档**的判据（批93）
 *
 * 这一组盯的是两件事，它们各自都有一类"看起来对、其实错"的做法：
 *
 *  ① **离开的场景不重置**。旧行为是每次跳转都从作者文档重建 —— 于是砍倒的树、
 *     杀掉的怪、丢在地上的东西在离开后全部复原，而画面上完全看不出发生过什么
 *     （世界本来就是新的）。判据不能只比"节点数一样"，必须比**那一处具体的变化还在不在**。
 *
 *  ② **存档要能读回来**。这里最容易犯的错是"只存场景名"（读档时回工程取文档）
 *     —— 那时读回来的是**作者的设计**，不是**这一局的进度**，而且它永远不会报错。
 *     所以判据里必须让"存档里的 b"与"source 里的 b"**长得不一样**，否则两种实现都能过。
 *
 * ★ 三条判据纪律（这一批特别容易踩）：
 *   - 「读档后 world 还对」不能靠"跳一下再看"来验：跳转本身会装 `visited`，
 *     那是**另一个动作**做了这件事（批91 的 M421 就是这么假绿的）。
 *     所以每个断言都只走一条路：要验 `loadGame`，就只调 `loadGame` 然后直接读世界。
 *   - 拿"文档里没有这个节点"当证据是**恒真**的（文档是夹具写的，当然没有）。
 *     证据必须是"我亲手加进去的那个节点，跳回来还在"。
 *   - 入口归位要**先挪走再走**：留在原地时"归位"与"不归位"结果一样。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { PlayerSpawn, registerPlayerComponents } from "../../src/extensions/worldgen/spawn.ts";
import {
  Inventory,
  ItemStack,
  registerInventoryComponents,
} from "../../src/extensions/inventory/inventory.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { Hunger, registerHungerComponent } from "../../src/extensions/survival/hunger.ts";
import { registerPortalComponent } from "../../src/extensions/flow/portal.ts";
import {
  FLOW_BAD_TARGET,
  FLOW_SAVE_NO_SPAWN,
  FLOW_SAVE_BAD_SCENE,
  SceneFlow,
  findPlayerId,
} from "../../src/extensions/flow/scene-flow.ts";
import {
  FLOW_BAD_SAVE,
  GAME_SAVE_FORMAT,
  decodeGameSave,
  encodeGameSave,
} from "../../src/extensions/flow/game-save.ts";

function makeRegistry(): ComponentRegistry {
  const r = new ComponentRegistry();
  registerPlayerComponents(r);
  registerInventoryComponents(r);
  registerHealthComponent(r);
  registerHungerComponent(r);
  registerPortalComponent(r);
  return r;
}

interface DocOpts {
  readonly px: number;
  readonly pz: number;
  readonly items?: readonly { readonly kind: string; readonly count: number }[];
  readonly withPlayer?: boolean;
  /** 额外造一个节点（"这一份世界长什么样"的特征）。 */
  readonly extra?: string;
}

/** 用独立临时场景造一份文档（主场景是"被测世界"，不能拿来当草稿纸）。 */
function makeDoc(reg: ComponentRegistry, o: DocOpts): string {
  const sc = new Scene("main", reg);
  if (o.extra !== undefined) {
    sc.spawnImmediate(o.extra, sc.rootId);
    sc.flush();
  }
  if (o.withPlayer !== false) {
    const n = sc.spawnImmediate("player", sc.rootId);
    sc.flush();
    n.setLocalPosition(o.px, o.pz);
    sc.attach(n.id, () => new PlayerSpawn());
    const h = new Health();
    h.hp = 7;
    h.maxHp = 10;
    sc.attach(n.id, () => h);
    const g = new Hunger();
    g.value = 42;
    sc.attach(n.id, () => g);
    const inv = new Inventory();
    inv.maxStacks = 8;
    inv.maxStack = 40;
    sc.attach(n.id, () => inv);
    for (const it of o.items ?? []) {
      const sub = sc.spawn(`item/${it.kind}`, n.id);
      sc.flush();
      assert.ok(sub.ok, sub.ok ? "" : sub.error.message);
      sc.attach(sub.value.id, () => {
        const s = new ItemStack();
        s.kind = it.kind;
        s.count = it.count;
        return s;
      });
      sc.flush();
    }
    // ★ 这一次 flush 必须在**循环外**：没有物品时循环一次都不跑，
    //   而上面四个 `attach` 还是队列里的操作 —— 不 flush 就 `saveScene`，
    //   导出的文档里一个组件都没有（夹具的错，表现出来像"引擎丢了玩家"）。
    sc.flush();
  }
  return sceneToJson(saveScene(sc));
}

interface Rig {
  readonly flow: SceneFlow;
  readonly scene: Scene;
  readonly docs: Map<string, string>;
  text(): string;
}

function rig(startName: string, startDoc: string, others: Record<string, string>): Rig {
  const reg = makeRegistry();
  const scene = new Scene("main", reg);
  const docs = new Map<string, string>();
  docs.set(startName, startDoc);
  for (const [k, v] of Object.entries(others)) docs.set(k, v);

  const parsed = sceneFromJson(startDoc);
  assert.ok(parsed.ok, parsed.ok ? "" : parsed.error.message);
  const loaded = loadScene(scene, parsed.value, reg);
  assert.ok(loaded.ok, loaded.ok ? "" : loaded.error.message);

  const flow = new SceneFlow(
    { scene, registry: reg, source: (name) => docs.get(name) ?? null },
    startName,
  );
  return { flow, scene, docs, text: () => sceneToJson(saveScene(scene)) };
}

function nodeNames(scene: Scene): string[] {
  const out: string[] = [];
  scene.root.walk((n) => {
    if (n.id !== scene.rootId) out.push(n.name);
  });
  out.sort();
  return out;
}

function playerLocal(scene: Scene): { x: number; y: number } {
  const id = findPlayerId(scene);
  assert.notEqual(id, null, "夹具：场景里应该有玩家");
  const n = scene.find(id!);
  assert.ok(n !== undefined, "夹具：玩家节点取不到");
  return { x: n.localPosition.x, y: n.localPosition.y };
}

function itemTotal(scene: Scene): number {
  let n = 0;
  for (const s of scene.componentsOf<ItemStack>("game.item")) n += s.count;
  return n;
}

/** 存档文本 → 结构化视图（判据要能**逐个场景**看，而不是只看到一串字符）。 */
function saveView(text: string): { current: string; names: string[] } {
  const o = JSON.parse(text) as { current?: unknown; scenes?: unknown };
  const scenes = Array.isArray(o.scenes) ? (o.scenes as { name?: unknown }[]) : [];
  return {
    current: typeof o.current === "string" ? o.current : "",
    names: scenes.map((s) => (typeof s.name === "string" ? s.name : "")),
  };
}

// ---------------------------------------------------------------- ① 离开的场景不重置

test("进度：跳走再回来，我亲手加的那个节点还在（场景不会被文档重置）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { b: makeDoc(reg, { px: 5, pz: 5 }) });

  // "在 a 里砍倒了一棵树"：加一个节点代表世界被改过
  r.scene.spawnImmediate("砍倒的树", r.scene.rootId);
  r.scene.flush();
  assert.ok(nodeNames(r.scene).includes("砍倒的树"), "夹具：这个节点应该先存在");

  const away = r.flow.jump("b");
  assert.ok(away.ok, away.ok ? "" : away.error.message);
  const back = r.flow.jump("a");
  assert.ok(back.ok, back.ok ? "" : back.error.message);

  assert.ok(
    nodeNames(r.scene).includes("砍倒的树"),
    `跳回来之后节点没了 ⇒ 又按文档重建了；实际节点：${nodeNames(r.scene).join("、")}`,
  );
  assert.equal(back.ok ? back.value.reused : false, true, "回来这一跳应该用手里那份快照");
});

test("进度：第二次进同一个场景**不读文档**（把文档弄坏也进得去）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { b: makeDoc(reg, { px: 5, pz: 5 }) });

  const first = r.flow.jump("b");
  assert.ok(first.ok, first.ok ? "" : first.error.message);
  assert.equal(first.value.reused, false, "第一次进 b 必须读文档（否则 reused 恒真，这条判据就白写了");
  r.flow.jump("a");

  // ★ 把 b 的文档换成坏文本：只要还走文档，这一跳必然 BAD_TARGET
  r.docs.set("b", "{ 这不是 json");
  const again = r.flow.jump("b");
  assert.ok(again.ok, again.ok ? "" : `${again.error.code}：${again.error.message}`);
  assert.equal(again.ok ? again.value.reused : false, true, "第二次进 b 应该用手里的快照");
});

test("进度：回访落在**入口**，不是上次离开时站的地方", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { b: makeDoc(reg, { px: 5, pz: 5 }) });

  // 先走开（否则归位与不归位结果一样 —— 这条判据会恒绿）
  const pid = findPlayerId(r.scene);
  assert.notEqual(pid, null);
  const n = r.scene.find(pid!);
  assert.ok(n !== undefined);
  n.setLocalPosition(9, 9);
  r.scene.flush();
  assert.deepEqual(playerLocal(r.scene), { x: 9, y: 9 }, "夹具：先确实把玩家挪走了");

  r.flow.jump("b");
  r.flow.jump("a");
  assert.deepEqual(playerLocal(r.scene), { x: 2, y: 3 }, "回访应该出现在 a 的入口 (2,3)");
});

test("进度：跨场景携带仍然生效（去的时候带过去，回来的时候带回来）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3, items: [{ kind: "twig", count: 12 }] }), {
    b: makeDoc(reg, { px: 5, pz: 5 }),
  });
  assert.equal(itemTotal(r.scene), 12, "夹具");

  const away = r.flow.jump("b");
  assert.ok(away.ok, away.ok ? "" : away.error.message);
  assert.equal(itemTotal(r.scene), 12, "跳到 b 之后背包应该跟着人");

  const back = r.flow.jump("a");
  assert.ok(back.ok, back.ok ? "" : back.error.message);
  // a 的快照里也有 12 根，携带会把 b 的 12 根**覆盖**上去 —— 关键是别变成 24 或 0
  assert.equal(itemTotal(r.scene), 12, "回访时背包不该翻倍，也不该丢");
});

test("进度：失败的一跳不许入册（回滚之后账本还是干净的）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { bad: "{ 不是 json" });
  const before = r.flow.visitedCount;

  const res = r.flow.jump("bad");
  assert.equal(res.ok, false);
  assert.equal(res.ok ? "" : res.error.code, FLOW_BAD_TARGET);
  assert.equal(r.flow.visitedCount, before, "跳失败不该让「去过几个场景」变多");
  assert.equal(r.flow.sceneName, "a");
});

// ---------------------------------------------------------------- ② 存档格式

test("存档：同一局两次编码字节相同，且场景按名字升序（与插入顺序无关）", () => {
  const a = encodeGameSave("b", new Map([["b", "doc-b"], ["a", "doc-a"], ["c", "doc-c"]]));
  const b = encodeGameSave("b", new Map([["c", "doc-c"], ["a", "doc-a"], ["b", "doc-b"]]));
  assert.equal(a, b, "两份语义相同的档必须逐字节相同");
  assert.deepEqual(saveView(a).names, ["a", "b", "c"], "场景要按名字升序");
  assert.deepEqual(saveView(a).current, "b");
});

test("存档：缺当前场景的文档 ⇒ 编码时直接抛（不生成一份读不回来的档）", () => {
  assert.throws(
    () => encodeGameSave("x", new Map([["a", "doc-a"]])),
    /缺当前场景/,
    "写的时候就该知道写坏了，而不是读的时候",
  );
});

test("存档：结构不对的档逐条拒掉（各自的理由要说清）", () => {
  const cases: readonly { readonly text: string; readonly why: string }[] = [
    { text: "{ 不是 json", why: "不是 JSON" },
    { text: "[]", why: "顶层是数组" },
    {
      text: JSON.stringify({ format: GAME_SAVE_FORMAT + 1, current: "a", scenes: [{ name: "a", doc: "{}" }] }),
      why: "版本太新",
    },
    { text: JSON.stringify({ format: 1, current: "", scenes: [{ name: "a", doc: "{}" }] }), why: "没写当前场景" },
    { text: JSON.stringify({ format: 1, current: "a", scenes: [] }), why: "一份场景都没有" },
    {
      text: JSON.stringify({ format: 1, current: "a", scenes: [{ name: "a", doc: "{}" }, { name: "a", doc: "{}" }] }),
      why: "场景重名",
    },
    {
      text: JSON.stringify({ format: 1, current: "zzz", scenes: [{ name: "a", doc: "{}" }] }),
      why: "当前场景不在列表里",
    },
    { text: JSON.stringify({ format: 1, current: "a", scenes: [{ name: "a", doc: "" }] }), why: "文档是空的" },
  ];
  for (const c of cases) {
    const d = decodeGameSave(c.text);
    assert.equal(d.ok, false, `这条应该被拒：${c.why}`);
    assert.equal(d.ok ? "" : d.error.code, FLOW_BAD_SAVE, `错误码不对：${c.why}`);
    assert.ok((d.ok ? "" : d.error.message).length > 0, `理由不能是空的：${c.why}`);
  }
});

// ---------------------------------------------------------------- ③ 读档

test("存档：走过的场景都进档，没去过的不进（读档后仍能按文档进新场景）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {
    b: makeDoc(reg, { px: 5, pz: 5 }),
    c: makeDoc(reg, { px: 7, pz: 1 }),
  });
  r.flow.jump("b");
  const view = saveView(r.flow.saveGame());
  assert.equal(view.current, "b");
  assert.deepEqual(view.names, ["a", "b"], "只该有走过的两份（c 没去过）");
});

test("读档：当前场景与玩家状态（背包/血/饱食）都按存档恢复", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3, items: [{ kind: "reed", count: 9 }] }), {
    b: makeDoc(reg, { px: 5, pz: 5 }),
  });
  const saved = r.flow.saveGame();

  // 把这一局彻底毁掉：换到 b、再加一个垃圾节点、把血改成 1、把背包清空
  const away = r.flow.jump("b");
  assert.ok(away.ok, away.ok ? "" : away.error.message);
  r.scene.spawnImmediate("乱七八糟", r.scene.rootId);
  r.scene.flush();
  const hp = [...r.scene.componentsOf<Health>("combat.health")];
  for (const h of hp) h.hp = 1;
  for (const s of r.scene.componentsOf<ItemStack>("game.item")) {
    const id = s.node?.id;
    if (id !== undefined) r.scene.destroy(id);
  }
  r.scene.flush();
  assert.equal(itemTotal(r.scene), 0, "夹具：跳过去之后要把背包清空（否则读档前后数字一样，判据白写）");

  const back = r.flow.loadGame(saved);
  assert.ok(back.ok, back.ok ? "" : `${back.error.code}：${back.error.message}`);
  assert.equal(r.flow.sceneName, "a", "读档后应该回到 a");
  assert.ok(nodeNames(r.scene).includes("player"));
  assert.ok(!nodeNames(r.scene).includes("乱七八糟"), "读档要把当前世界换掉，不是合并");
  assert.equal(itemTotal(r.scene), 9, "背包是玩家节点上的组件，读档应该一起回来");
  const h = [...r.scene.componentsOf<Health>("combat.health")][0];
  assert.ok(h !== undefined);
  assert.equal(h.hp, 7, "存档里的血量");
});

test("读档：去过的场景也一并恢复（存档里的 b ≠ 文档里的 b）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {
    // 文档版的 b 有特征节点；存档版的 b 里那个节点被我删掉了
    b: makeDoc(reg, { px: 5, pz: 5, extra: "文档版 b 的树" }),
  });

  const toB = r.flow.jump("b");
  assert.ok(toB.ok, toB.ok ? "" : `${toB.error.code}：${toB.error.message}`);
  // "在 b 里砍掉那棵树"
  const tree = [...r.scene.root.children].find((n) => n.name === "文档版 b 的树");
  assert.ok(tree !== undefined, `夹具：b 里应该有那棵树；实际节点：${nodeNames(r.scene).join("、")}`);
  r.scene.destroy(tree.id);
  r.scene.flush();
  assert.ok(!nodeNames(r.scene).includes("文档版 b 的树"), "夹具：树确实没了");
  // 回到 a 再存 —— 存档的"当前场景"就是 a，而 b 以"砍过树"的样子进册
  const backToA = r.flow.jump("a");
  assert.ok(backToA.ok, backToA.ok ? "" : backToA.error.message);
  const saved = r.flow.saveGame();

  const fresh = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {
    b: makeDoc(reg, { px: 5, pz: 5, extra: "文档版 b 的树" }),
  });
  const res = fresh.flow.loadGame(saved);
  assert.ok(res.ok, res.ok ? "" : `${res.error.code}：${res.error.message}`);
  assert.equal(fresh.flow.sceneName, "a");

  const go = fresh.flow.jump("b");
  assert.ok(go.ok, go.ok ? "" : go.error.message);
  assert.equal(go.ok ? go.value.reused : false, true, "存档里的 b 应该进册了");
  assert.ok(
    !nodeNames(fresh.scene).includes("文档版 b 的树"),
    `读档之后跳去 b 又按文档重建了；节点：${nodeNames(fresh.scene).join("、")}`,
  );
});

test("读档：当前场景的文档坏了 ⇒ 世界一个字节都不动（解析必须先于装载）", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {});
  const before = r.text();

  const broken = JSON.stringify({
    format: GAME_SAVE_FORMAT,
    current: "a",
    scenes: [{ name: "a", doc: "{ 这不是 json" }],
  });
  const res = r.flow.loadGame(broken);
  assert.equal(res.ok, false);
  assert.equal(res.ok ? "" : res.error.code, FLOW_SAVE_BAD_SCENE);
  assert.equal(r.text(), before, "世界不许被动过");
  assert.equal(r.flow.sceneName, "a");
});

test("读档：存档的当前场景里没有玩家 ⇒ 拒，世界不动", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), {});
  const before = r.text();
  const noPlayer = makeDoc(reg, { px: 0, pz: 0, withPlayer: false });
  const text = JSON.stringify({
    format: GAME_SAVE_FORMAT,
    current: "empty",
    scenes: [{ name: "empty", doc: noPlayer }],
  });
  const res = r.flow.loadGame(text);
  assert.equal(res.ok, false);
  assert.equal(res.ok ? "" : res.error.code, FLOW_SAVE_NO_SPAWN);
  assert.equal(r.text(), before);
});

test("存档：读档之后接着玩，再存一次与第一次**不相干的地方**保持稳定", () => {
  const reg = makeRegistry();
  const r = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { b: makeDoc(reg, { px: 5, pz: 5 }) });
  r.flow.jump("b");
  const first = r.flow.saveGame();
  const second = r.flow.saveGame();
  assert.equal(first, second, "同一刻连存两次必须字节相同（否则「是不是同一局」永远判不了）");

  const other = rig("a", makeDoc(reg, { px: 2, pz: 3 }), { b: makeDoc(reg, { px: 5, pz: 5 }) });
  const res = other.flow.loadGame(first);
  assert.ok(res.ok, res.ok ? "" : res.error.message);
  assert.equal(other.flow.saveGame(), first, "读档再立刻存档应该得到同一段字节");
});
