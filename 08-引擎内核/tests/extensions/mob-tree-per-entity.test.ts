/**
 * L4 · 「用哪棵树」按实体：树引用进场景、进模板、缺了要能看见
 *
 * 批154 的树是**整根大脑一份**。这一批把它变成**每只生物一个值**，落在实体上
 * （`mobs.ai` 组件的 `tree` 字段）—— 于是它跟着存档走、在属性面板里能改。
 *
 * 五条地基：
 *
 *  · **同一份事实、两只怪、两种决定**：这是「按实体选树」唯一的分辨手段。
 *    只断言 `treeIdOf()` 读到了字符串是不够的 —— 那只证明"字段存进去了"。
 *  · **存档往返之后引用还在**：`FieldType.Asset` 就是字符串，但"进 schema"这件事
 *    要靠这条判据钉住（不进 schema 的字段在存档里静默消失，而世界看起来正常）。
 *  · **缺 id 不抛、但要能看见**：回落内置树 + `treeMissing()` + 面板 `missing`。
 *    只验"没崩"的判据会放过「配了树却没生效」这个最难查的状态。
 *  · **热重载要立刻生效**：`put` 之后下一拍行为就变（`revision` 让缓存作废）。
 *    没有这条，编辑器里改树要重启进程才生效，而人会以为是"改错了"。
 *  · **模板配了树但组件没注册 ⇒ 硬失败**：静默用默认树等于"配了不生效"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { bt } from "../../src/extensions/ai/behavior.ts";
import type { MobGrid } from "../../src/extensions/mobs/mob-facts.ts";
import { createMobBrain } from "../../src/extensions/mobs/mob-brain.ts";
import { DEFAULT_TREE_ASSET, TreeLibrary } from "../../src/extensions/mobs/tree-library.ts";
import { AI_CONFIG_TYPE, AIConfig, registerAiConfig, treeIdOf } from "../../src/extensions/mobs/ai-config.ts";
import { validateTemplate } from "../../src/extensions/mobs/mob-template.ts";
import { spawnMob } from "../../src/extensions/mobs/spawn-mob.ts";
import { inspectText, nonAscii } from "../../src/extensions/mobs/mob-inspector.ts";
import { createMobWorldModule } from "../../src/extensions/mobs/mob-world.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";

const CALM = "asset:calm";

/** 只漫游的树：看得见人也不追（见文件「五条地基」第 1 条）。 */
function pacifist() {
  return bt.sequence("p.root", bt.check("p.c", "mob.canDecide"), bt.do("p.d", "mob.wander"));
}

/** 只追最近的：看不见就什么都不做。 */
function blindHunter() {
  return bt.sequence("h.root", bt.check("h.c", "mob.seesFoe"), bt.do("h.d", "mob.huntNearest"));
}

function rectGrid(w = 60, h = 60): MobGrid {
  return {
    cellAt: (x, z) => {
      const cx = Math.floor(x);
      const cz = Math.floor(z);
      if (cx < 0 || cx >= w || cz < 0 || cz >= h) return -1;
      return cz * w + cx;
    },
    cellX: (i) => i % w,
    cellZ: (i) => (i - (i % w)) / w,
    isWalkable: (cx, cz) => cx > 0 && cx < w - 1 && cz > 0 && cz < h - 1,
  };
}

function registry(opts: { readonly ai?: boolean } = {}): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerLootComponent(reg);
  if (opts.ai !== false) registerAiConfig(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

function factions() {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

interface UnitOpts {
  readonly armed?: boolean;
  readonly tree?: string;
}

/** 造一只单位；`tree` 给了就挂 `mobs.ai`（与 `spawnMob` 同一条规矩）。 */
function unit(scene: Scene, name: string, x: number, z: number, team: string, opts: UnitOpts = {}): number {
  const n = scene.spawnAt(name, x, z);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const id = n.value.id;
  const h = new Health();
  h.hp = 5;
  h.maxHp = 5;
  scene.attach(id, () => h);
  const f = new FactionMember();
  f.team = team;
  scene.attach(id, () => f);
  if (opts.armed !== false) {
    const a = new Attacker();
    a.damage = 1;
    a.range = 1.6;
    a.cooldownTicks = 10;
    scene.attach(id, () => a);
  }
  if (opts.tree !== undefined) {
    const c = new AIConfig();
    c.tree = opts.tree;
    scene.attach(id, () => c);
  }
  scene.flush();
  return id;
}

test("[按实体] ★ 同一份事实，两只怪走不同的树 ⇒ 一个追、一个不动", () => {
  const reg = registry();
  const scene = new Scene("per-entity", reg);
  const lib = new TreeLibrary();
  assert.equal(lib.put(CALM, pacifist()).ok, true);

  const prey = unit(scene, "prey", 11.5, 10.5, "prey", { armed: false });
  const calm = unit(scene, "calm", 10.5, 10.5, "hunter", { tree: CALM });
  const hound = unit(scene, "hound", 10.5, 11.5, "hunter");

  const brain = createMobBrain({ factions: factions(), range: 10, library: lib, seed: 1 });
  const grid = rectGrid();

  const dCalm = brain.decide(scene, calm, 1, grid);
  const dHound = brain.decide(scene, hound, 1, grid);

  assert.equal(dCalm, null, "配了「只漫游」的树却在追人 ⇒ 按实体选树没生效（还在用整根脑子那棵）");
  assert.equal(dHound?.kind, "hunt", "没配树的那只必须走内置树（追）");
  assert.equal(dHound?.targetNodeId, prey);
  assert.equal(brain.treeForAgent(scene, calm).source, "asset");
  assert.equal(brain.treeForAgent(scene, hound).source, "default", "没配组件 = default，不是 missing");
  assert.equal(brain.treeMissing(), 0);
});

test("[按实体] 树引用进场景：存档往返之后还在（Asset 字段必须进 schema）", () => {
  const reg = registry();
  const scene = new Scene("persist", reg);
  const id = unit(scene, "calm", 5.5, 5.5, "hunter", { tree: CALM });

  const json = sceneToJson(saveScene(scene));
  const parsed = sceneFromJson(json);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;
  const back = new Scene("读档", reg);
  assert.equal(loadScene(back, parsed.value, reg).ok, true);

  assert.equal(treeIdOf(back, id), CALM, "读档后树引用丢了 ⇒ 那只怪悄悄换回内置树（而世界看起来正常）");
  const c = back.find(id)?.get<AIConfig>(AI_CONFIG_TYPE);
  assert.equal(c?.tree, CALM);
  // 反向：普通存档里这个字段是真实存在的（不是零值碰巧相等）
  assert.notEqual(CALM, "");
});

test("[按实体] ★ 配了不存在的树：不抛、用内置树、但三处都要能看见", () => {
  const reg = registry();
  const scene = new Scene("missing", reg);
  const lib = new TreeLibrary();
  const prey = unit(scene, "prey", 11.5, 10.5, "prey", { armed: false });
  const hound = unit(scene, "hound", 10.5, 10.5, "hunter", { tree: "asset:deleted" });

  const brain = createMobBrain({ factions: factions(), range: 10, library: lib, seed: 1 });
  const grid = rectGrid();
  const d = brain.decide(scene, hound, 1, grid);

  assert.equal(d?.kind, "hunt", "回落之后仍然按内置树跑（怪不能因此变傻）");
  assert.equal(d?.targetNodeId, prey);
  // 三件套：计数 / 名单 / 面板
  assert.equal(brain.treeMissing(), 1, "没有计数 ⇒ 「配了树但没生效」永远没人知道");
  assert.deepEqual(brain.missingTreeIds(), ["asset:deleted"], "面板要点名是哪棵树不见了");
  const e = brain.explain(scene, hound, 1, grid);
  assert.ok(e !== null);
  assert.equal(e?.treeSource, "missing");
  assert.equal(e?.wanted, "asset:deleted");
  assert.equal(e?.treeId, DEFAULT_TREE_ASSET);
  assert.match(inspectText(e!), /miss asset:deleted/, "面板文本必须标出来（否则它与「配了内置树」一模一样）");
});

test("[按实体] ★ 热重载：put 一棵新树之后，下一拍行为就变（revision 让缓存作废）", () => {
  const reg = registry();
  const scene = new Scene("hot", reg);
  const lib = new TreeLibrary();
  assert.equal(lib.put(CALM, pacifist()).ok, true);
  unit(scene, "prey", 11.5, 10.5, "prey", { armed: false });
  const calm = unit(scene, "calm", 10.5, 10.5, "hunter", { tree: CALM });

  const brain = createMobBrain({ factions: factions(), range: 10, library: lib, seed: 1 });
  const grid = rectGrid();
  assert.equal(brain.decide(scene, calm, 1, grid), null, "改之前是「只漫游」");

  // 换掉同一个 id 的树（编辑器保存 = 这一条）
  assert.equal(lib.put(CALM, blindHunter()).ok, true);
  const after = brain.decide(scene, calm, 2, grid);
  assert.equal(after?.kind, "hunt", "改了树但行为没变 ⇒ 缓存没按 revision 作废（要重启才生效）");
  assert.equal(after?.reason, "sight");
});

test("[面板] explain 的这一拍：决定、原因、树来源与 deciding 一致；没有决定时显示 `-`", () => {
  const reg = registry();
  const scene = new Scene("panel", reg);
  const lib = new TreeLibrary();
  assert.equal(lib.put(CALM, pacifist()).ok, true);
  const prey = unit(scene, "prey", 11.5, 10.5, "prey", { armed: false });
  const calm = unit(scene, "calm", 10.5, 10.5, "hunter", { tree: CALM });
  const hound = unit(scene, "hound", 10.5, 11.5, "hunter");

  const brain = createMobBrain({ factions: factions(), range: 10, library: lib, seed: 1 });
  const grid = rectGrid();

  const eHound = brain.explain(scene, hound, 3, grid);
  assert.ok(eHound !== null);
  assert.equal(eHound?.decision?.kind, "hunt");
  assert.match(inspectText(eHound!), /why=sight/, "面板的 why 必须是这一拍的 reason（不是 kind）");
  assert.match(inspectText(eHound!), new RegExp(`goal=hunt #${String(prey)}@`));
  assert.match(inspectText(eHound!), /tree=builtin:mob \(default\)/);

  const eCalm = brain.explain(scene, calm, 3, grid);
  assert.ok(eCalm !== null);
  assert.equal(eCalm?.decision, null);
  assert.match(inspectText(eCalm!), /why=-/, "没有决定时必须显示 `-`，不能留着上一次的「在追」");
  assert.match(inspectText(eCalm!), /goal=-/);

  // 面板文案必须是纯 ASCII（位图字体只有 5×7 的 ASCII 字形，中文会静默变空白）
  assert.deepEqual(nonAscii(inspectText(eHound!)), [], "面板文案里有非 ASCII 字符 ⇒ 在位图字体上会静默变成空白");
  // 正向对照：这条检查必须真的能发现东西，否则上面的「空数组」可能是它根本没在扫
  assert.deepEqual(nonAscii("tree=猎狗"), ["猎", "狗"]);
});

test("[模板] 写了 tree 就挂组件、没写就不挂；纯空白要拒绝", () => {
  const base = {
    kind: "hound",
    frame: "hound",
    width: 1,
    height: 1,
    radius: 0.35,
    maxHp: 6,
    damage: 1,
    range: 1.6,
    cooldownTicks: 5,
    speed: 3,
    team: "hunter",
    loot: [],
  };

  const plain = validateTemplate(base);
  assert.equal(plain.ok, true);
  if (plain.ok) assert.equal(plain.value.tree, "", "没写 tree ⇒ 空串（= 内置树）");

  const withTree = validateTemplate({ ...base, tree: CALM });
  assert.equal(withTree.ok, true);
  if (withTree.ok) assert.equal(withTree.value.tree, CALM);

  const blank = validateTemplate({ ...base, tree: "   " });
  assert.equal(blank.ok, false, "纯空白 id 必须拒绝 —— 它与空串在库里是两个值，而人眼分不出");
  if (!blank.ok) assert.equal(blank.error.code, "MOB.BAD_TEMPLATE");

  const notString = validateTemplate({ ...base, tree: 7 });
  assert.equal(notString.ok, false);
});

test("[模板] spawnMob：模板带 tree ⇒ 生物身上真有那棵树；组件没注册 ⇒ 硬失败", () => {
  const scene = new Scene("spawn", registry());
  const hound = {
    kind: "hound",
    frame: "hound",
    width: 1,
    height: 1,
    radius: 0.35,
    maxHp: 6,
    damage: 1,
    range: 1.6,
    cooldownTicks: 5,
    speed: 3,
    team: "hunter",
    tree: CALM,
    loot: [],
  };
  const r = spawnMob(scene, hound, 5.5, 5.5, { name: "hound#0" });
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(treeIdOf(scene, r.value.nodeId), CALM);
  assert.equal(r.value.aiConfig?.tree, CALM);
  assert.notEqual(scene.find(r.value.nodeId)?.get(AI_CONFIG_TYPE), undefined, "模板配了树 ⇒ 组件必须真的挂在节点上");

  // 不带 tree 的模板：不挂组件（"没配"就是没配，不该在存档里留一条空记录）
  const plain = spawnMob(scene, { ...hound, tree: "" }, 9.5, 9.5, { name: "hound#1" });
  assert.equal(plain.ok, true);
  if (!plain.ok) return;
  assert.equal(treeIdOf(scene, plain.value.nodeId), "");
  assert.equal(plain.value.aiConfig, null);
  // ★ 这一条才是「没配就不挂」的可观察形式：`treeIdOf` 对"没组件"与"空值组件"都返回空串，
  //   只断言它的话「恒挂一个空值组件」照样绿（M935 就是这个形状）。
  assert.equal(
    scene.find(plain.value.nodeId)?.get(AI_CONFIG_TYPE),
    undefined,
    "没配树却挂了 `mobs.ai` ⇒ 存档里每只怪都多一条空记录（信息量为零）",
  );

  // 见文件「五条地基」最后一条
  const noAi = new Scene("spawn-no-ai", registry({ ai: false }));
  const bad = spawnMob(noAi, hound, 5.5, 5.5, { name: "hound#2" });
  assert.equal(bad.ok, false, "配了树但组件没注册，竟然静默成功 ⇒ 那只怪会一直用默认树，而配置看起来是生效的");
  if (!bad.ok) {
    assert.equal(bad.error.code, "MOB.SPAWN_FAILED");
    assert.match(bad.error.message, new RegExp(AI_CONFIG_TYPE.replace(".", "\\.")));
  }
});

test("[模块] ★ 模块级接线：`world.explain` 用的是同一个大脑，`stats.treeFallbacks` 能看见坏引用", () => {
  // ★ 为什么还要一条"模块级"的：上面所有判据都直接 new 一个 `MobBrain`。
  //   而真正跑在游戏里的是 `createMobWorldModule` —— 它要自己记住 `lastTick`、
  //   自己拿 `options.grid`、自己把库透传给大脑。这三件事任何一件接错，
  //   裸 `MobBrain` 的判据都看不见，而症状是「面板永远是空的」。
  const g = generateWorld({ seed: 21, width: 20, height: 14, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) return;
  const nav = NavGrid.fromPlan(g.value);
  assert.equal(nav.ok, true);
  if (!nav.ok) return;
  const grid = nav.value;

  const cells: number[] = [];
  for (let cz = 1; cz < 13 && cells.length < 2; cz++) {
    for (let cx = 1; cx < 19 && cells.length < 2; cx++) {
      if (grid.isWalkable(cx, cz)) cells.push(grid.cellAt(cx + 0.5, cz + 0.5));
    }
  }
  assert.equal(cells.length, 2, "找不到两个可走格（世界生成的种子变了？）");

  const hound = {
    kind: "hound",
    frame: "hound",
    width: 1,
    height: 1,
    radius: 0.35,
    maxHp: 6,
    damage: 1,
    range: 1.6,
    cooldownTicks: 5,
    speed: 3,
    team: "hunter",
    tree: CALM,
    loot: [],
  };
  const rabbit = {
    kind: "rabbit",
    frame: "rabbit",
    width: 0.8,
    height: 0.8,
    radius: 0.3,
    maxHp: 2,
    damage: 0,
    range: 1.4,
    cooldownTicks: 20,
    speed: 0.6,
    team: "prey",
    tree: "",
    loot: [],
  };

  function boot(treeId: string): { mod: ReturnType<typeof createMobWorldModule>; scene: Scene } {
    const scene = new Scene("module", registry());
    const services = new ServiceRegistry();
    services.provide(Services.Scene, scene, "test");
    const ctx = {
      log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) },
      events: { emit: () => undefined, on: () => () => undefined },
      services,
      platform: {},
      random: { next: () => 0 },
      module: () => undefined,
    } as unknown as ModuleContext;
    const lib = new TreeLibrary();
    assert.equal(lib.put(CALM, pacifist()).ok, true);
    const mod = createMobWorldModule({
      grid,
      factions: factions(),
      templates: [{ ...hound, tree: treeId }, rabbit],
      spots: [
        { template: 0, cell: cells[0]! },
        { template: 1, cell: cells[1]! },
      ],
      range: 12,
      seed: 3,
      library: lib,
    });
    const r = mod.init(ctx) as { ok: boolean } | undefined;
    assert.equal(r?.ok, true, "模块初始化必须成功");
    return { mod, scene };
  }

  const { mod } = boot(CALM);
  mod.update(1, 1 / 30);
  const houndId = mod.nodeIds.find((id) => mod.templateOf(id) === "hound");
  assert.ok(houndId !== undefined);
  const e = mod.explain(houndId!);
  assert.ok(e !== null, "explain 返回 null ⇒ 模块没把 tick / grid / 大脑接起来（面板永远是空的）");
  assert.equal(e?.treeSource, "asset");
  assert.equal(e?.treeId, CALM);
  assert.equal(e?.tick, 1, "面板显示的必须是刚算过的那一拍");
  assert.equal(mod.stats.treeFallbacks, 0);
  assert.deepEqual(mod.missingTrees, []);
  // 兔子没配树 ⇒ 走内置树
  const rabbitId = mod.nodeIds.find((id) => mod.templateOf(id) === "rabbit");
  assert.equal(mod.explain(rabbitId!)?.treeSource, "default");

  // 坏引用：世界照跑，但计数与名单都要有
  const broken = boot("asset:nope");
  broken.mod.update(1, 1 / 30);
  assert.equal(broken.mod.stats.treeFallbacks, 1, "没有计数 ⇒ 「配了树但没生效」永远没人知道");
  assert.deepEqual(broken.mod.missingTrees, ["asset:nope"]);
});
