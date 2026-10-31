/**
 * L6 · 宿主装载树资产（批156）：`.tree.json` 真的进了库，真的换了怪的行为
 *
 * 上一批（155）证明了「组件能按 id 选树」，但库里只有测试 `put` 进去的树 ——
 * 也就是说，**没有一个真实文件被读进过库**。这个文件补的就是最后一段，
 * 它验的不是"装载函数能跑"，而是下面四句**同时**成立：
 *
 *  · **清单里的每个文件真的在盘上、能解析、是规范形式**；
 *  · **组件里写的那个 id 就是那个文件的路径推出来的 id**（改文件名忘了改常量 ⇒ 红）；
 *  · **装上之后猎狗用的就是资产树**（`treeSource === "asset"`，`treeFallbacks === 0`）；
 *  · **换一个文件，行为真的变了**（同一份世界、同一批位置，只有树不同）。
 *
 * ★ 为什么最后一条必须是**世界级**的：前三条都能在纯函数里造假绿 ——
 *   库里有树、组件有 id、`explain` 也说 `asset`，但 `spawn` 时组件没挂上、
 *   或者大脑没拿到库，行为还是内置树的那一套。只有"同一局跑两棵树、看到两种决定"
 *   能分辨「配置生效」与「配置看起来生效」。
 *
 * ★ 这份判据读的是**仓库里的真实文件**（`readFileSync`），不是内联的语料：
 *   内联的话，文件被删/改名/改成 LF/被编辑器重排，判据全都绿，
 *   而浏览器里是一场静默的 404 + 全员内置树。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Scene } from "../../src/core/scene/scene.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { Services } from "../../src/core/tokens.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { registerAiConfig } from "../../src/extensions/mobs/ai-config.ts";
import { createMobWorldModule, type MobWorldHandle } from "../../src/extensions/mobs/mob-world.ts";
import { createMobTree, MOB_TREE } from "../../src/extensions/mobs/mob-tree.ts";
import type { MobFacts } from "../../src/extensions/mobs/mob-facts.ts";
import { parseTreeAsset, serializeTreeAsset, treeAssetIdFromPath } from "../../src/extensions/mobs/tree-asset.ts";
import { TreeLibrary } from "../../src/extensions/mobs/tree-library.ts";
import { loadTreeFiles, type TreeLoadReport } from "../../src/extensions/mobs/tree-loader.ts";
import { DEMO_HOUND_TREE, DEMO_MOB_TEMPLATES, DEMO_TREE_FILES } from "../../src/host/demo-mobs.ts";
import { engineError, err, ok } from "../../src/foundation/result.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");
const ASSETS = join(ROOT, "web", "assets");

/** 读盘：与宿主 `fs.readText` 同一个口径（出错给 `Result`，不抛）。 */
async function readAsset(path: string) {
  const abs = join(ASSETS, path);
  if (!existsSync(abs)) return err(engineError("FS.NOT_FOUND", `读不到 ${abs}`));
  return ok(readFileSync(abs, "utf8"));
}

// ------------------------------------------------------------------ ① 文件本身

test("[资产] ★ 清单里的每个树文件：在盘上、能解析、id 与路径一致、是规范形式", () => {
  assert.ok(DEMO_TREE_FILES.length >= 2, "清单少于两份 —— 「换一棵树」就没有第二种可选");
  for (const path of DEMO_TREE_FILES) {
    const abs = join(ASSETS, path);
    assert.equal(existsSync(abs), true, `${path} 不在 web/assets 下 —— 运行时 readText 会 404，而世界只是"怪变笨了"`);
    const text = readFileSync(abs, "utf8");
    const parsed = parseTreeAsset(text);
    assert.equal(parsed.ok, true, `${path} 解析不了：${parsed.ok ? "" : `${parsed.error.code} ${parsed.error.message}`}`);
    if (!parsed.ok) continue;
    // ★ 仓库里的文件必须是**导出器产出**：否则每次有人导出都会 diff 一整片
    assert.equal(serializeTreeAsset(parsed.value), text, `${path} 不是规范形式（键序/缩进/末尾换行）`);
    // ★ 文件进版本库：CRLF 会让"同一棵树"在两台机器上是两份字节
    assert.equal(text.includes("\r"), false, `${path} 里有 CR —— 资产文件统一 LF`);
    const id = treeAssetIdFromPath(path);
    assert.equal(id.ok, true, `${path} 推不出 id`);
  }
});

test("[资产] ★★ 组件里写的 id 就是猎狗那份文件的路径推出来的 id（防漂移）", () => {
  const id = treeAssetIdFromPath("ai/hound.tree.json");
  assert.equal(id.ok, true);
  if (!id.ok) return;
  assert.equal(
    DEMO_HOUND_TREE,
    id.value,
    "常量与文件路径对不上 ⇒ 每只猎狗都在引用一棵不存在的树（面板 `miss`、`treeFallbacks` 涨，行为退回内置）",
  );
  // 反向：清单里确实有它（不是"常量对、文件却不在清单里"）
  assert.equal(
    (DEMO_TREE_FILES as readonly string[]).includes("ai/hound.tree.json"),
    true,
    "猎狗用的那份文件不在装载清单里 ⇒ 库是空的，常量再对也解析不到",
  );
});

// ------------------------------------------------------------------ ② 装库 → 世界

function registry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerLootComponent(reg);
  registerAiConfig(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

function demoFactions() {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

interface World {
  readonly mod: MobWorldHandle;
  readonly scene: Scene;
  readonly report: TreeLoadReport;
}

/** 起一个只有两只生物的世界：猎狗用 `houndTree`，兔子用内置树。 */
async function boot(houndTree: string, every = 1): Promise<World | null> {
  const g = generateWorld({ seed: 21, width: 20, height: 14, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) return null;
  const nav = NavGrid.fromPlan(g.value);
  assert.equal(nav.ok, true);
  if (!nav.ok) return null;
  const grid = nav.value;

  const cells: number[] = [];
  for (let cz = 1; cz < 13 && cells.length < 2; cz++) {
    for (let cx = 1; cx < 19 && cells.length < 2; cx++) {
      if (grid.isWalkable(cx, cz)) cells.push(grid.cellAt(cx + 0.5, cz + 0.5));
    }
  }
  assert.equal(cells.length, 2);

  const hound = DEMO_MOB_TEMPLATES.find((t) => t.kind === "hound");
  const rabbit = DEMO_MOB_TEMPLATES.find((t) => t.kind === "rabbit");
  assert.ok(hound !== undefined && rabbit !== undefined);

  const scene = new Scene("demo-trees", registry());
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

  // ★ 用**真实文件**装库（与宿主同一条路：`loadTreeFiles` + `fs.readText`）
  const library = new TreeLibrary();
  const report = await loadTreeFiles(library, DEMO_TREE_FILES, (p) => readAsset(p));

  const mod = createMobWorldModule({
    grid,
    factions: demoFactions(),
    templates: [{ ...hound, tree: houndTree }, rabbit],
    spots: [
      { template: 0, cell: cells[0]! },
      { template: 1, cell: cells[1]! },
    ],
    range: 12,
    seed: 3,
    wanderEvery: every,
    library,
  });
  const r = mod.init(ctx) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "生物模块初始化失败");

  // ★ 先读报告：装载本身没成功的话，后面每条断言都会在验一个"没装上的世界"
  assert.deepEqual(report.failed, [], `树资产装载失败：${JSON.stringify(report.failed)}`);
  assert.equal(report.loaded, DEMO_TREE_FILES.length);
  return { mod, scene, report };
}

test("[世界] ★★ 装库之后猎狗用的是资产树：`treeSource=asset`、零回落、名单为空", async () => {
  const w = await boot(DEMO_HOUND_TREE);
  if (w === null) return;
  w.mod.update(1, 1 / 30);
  const houndId = w.mod.nodeIds.find((id) => w.mod.templateOf(id) === "hound");
  assert.ok(houndId !== undefined);
  const e = w.mod.explain(houndId!);
  assert.ok(e !== null, "explain 为 null ⇒ 面板没有可显示的东西");
  assert.equal(e?.treeSource, "asset", "还是 default/missing ⇒ 组件没挂上、或者库没透传给大脑");
  assert.equal(e?.treeId, DEMO_HOUND_TREE);
  assert.equal(e?.wanted, DEMO_HOUND_TREE);
  assert.equal(w.mod.stats.treeFallbacks, 0);
  assert.deepEqual(w.mod.missingTrees, []);
  // 兔子没配树 ⇒ 内置（`default` 是正常态，不是缺）
  const rabbitId = w.mod.nodeIds.find((id) => w.mod.templateOf(id) === "rabbit");
  assert.equal(w.mod.explain(rabbitId!)?.treeSource, "default");
});

test("[世界] ★ 组件写错 id（策划打错字）：世界照跑，但三处都要能看见", async () => {
  const w = await boot("ai/houndd");
  if (w === null) return;
  w.mod.update(1, 1 / 30);
  const houndId = w.mod.nodeIds.find((id) => w.mod.templateOf(id) === "hound");
  const e = w.mod.explain(houndId!);
  assert.equal(e?.treeSource, "missing");
  assert.equal(e?.wanted, "ai/houndd");
  assert.equal(w.mod.stats.treeFallbacks, 1);
  assert.deepEqual(w.mod.missingTrees, ["ai/houndd"]);
  // 行为仍按内置树跑（怪不能因此变傻）
  assert.equal(w.mod.explain(houndId!)?.decision?.kind, "hunt", "回落之后必须还能追（这条同时证明「降级不是瘫痪」）");
});

test("[世界] ★★ 换一棵树，行为真的变了：`ai/hound` 追看见的，`ai/hound_grudge` 不追", async () => {
  const before = await boot(DEMO_HOUND_TREE);
  const after = await boot("ai/hound_grudge");
  if (before === null || after === null) return;
  before.mod.update(1, 1 / 30);
  after.mod.update(1, 1 / 30);
  const h1 = before.mod.nodeIds.find((id) => before.mod.templateOf(id) === "hound");
  const h2 = after.mod.nodeIds.find((id) => after.mod.templateOf(id) === "hound");

  assert.equal(before.mod.explain(h1!)?.decision?.kind, "hunt", "内置那套脾气：看得见就追");
  const d2 = after.mod.explain(h2!)?.decision;
  assert.notEqual(d2?.kind, "hunt", "换了「只追有仇的」那棵树却还在追 ⇒ 文件里的树没生效（换了个寂寞）");
  // ★ 同时钉住"树真的换了"这件事实本身（否则上面那条也可能是"两棵树都坏了"）
  assert.equal(before.mod.explain(h1!)?.treeId, "ai/hound");
  assert.equal(after.mod.explain(h2!)?.treeId, "ai/hound_grudge");
});

// ------------------------------------------------------------------ ③ 资产树 ≡ 内置树

test("[资产] ★★ `ai/hound.tree.json` 与内置树逐条同构（导出一次不该改变脾气）", () => {
  const text = readFileSync(join(ASSETS, "ai/hound.tree.json"), "utf8");
  const parsed = parseTreeAsset(text);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;
  const asset = createMobTree({ tree: parsed.value });
  const builtin = createMobTree({ tree: MOB_TREE });

  const facts: MobFacts[] = [
    { agentId: 1, tick: 1, selfCell: -1, aggressive: true, grudge: null, visible: [], wanderCell: 5 },
    { agentId: 1, tick: 1, selfCell: 7, aggressive: true, grudge: null, visible: [], wanderCell: 5 },
    { agentId: 1, tick: 1, selfCell: 7, aggressive: true, grudge: null, visible: [], wanderCell: -1 },
    {
      agentId: 1,
      tick: 1,
      selfCell: 7,
      aggressive: true,
      grudge: null,
      visible: [{ nodeId: 9, cell: 8, dist2: 1 }],
      wanderCell: 5,
    },
    {
      agentId: 1,
      tick: 1,
      selfCell: 7,
      aggressive: true,
      grudge: { nodeId: 11, cell: 12 },
      visible: [{ nodeId: 9, cell: 8, dist2: 1 }],
      wanderCell: 5,
    },
    {
      agentId: 1,
      tick: 1,
      selfCell: 7,
      aggressive: false,
      grudge: { nodeId: 11, cell: 12 },
      visible: [{ nodeId: 9, cell: 8, dist2: 1 }],
      wanderCell: 5,
    },
  ];
  for (const f of facts) {
    assert.deepEqual(asset.decide(f), builtin.decide(f), `同一份事实下两棵树给了不同决定（facts=${JSON.stringify(f)}）`);
  }
  // ★ 反向对照：换掉「看见」那条分支之后，**同一份事实**必须给出不同决定 ——
  //   否则上面那六条可能只是"两边都没在判断"（等价变异）。
  const grudge = parseTreeAsset(readFileSync(join(ASSETS, "ai/hound_grudge.tree.json"), "utf8"));
  assert.equal(grudge.ok, true);
  if (!grudge.ok) return;
  const other = createMobTree({ tree: grudge.value });
  const sees = facts[3]!;
  assert.equal(builtin.decide(sees)?.kind, "hunt");
  assert.notEqual(other.decide(sees)?.kind, "hunt", "两棵树在同一份事实上给了同一个结论 ⇒ 这份语料对「换树」没有分辨力");
});
