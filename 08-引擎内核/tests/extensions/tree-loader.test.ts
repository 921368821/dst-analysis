/**
 * L4 · 树资产的装载（批156）：路径 → id、一批文件 → 一批树、坏文件不带走好文件
 *
 * 批155 之后树能存成 `.tree.json`、能被组件按 id 引用，但**没有人把文件送进库**。
 * 这个文件验的就是那一段：一批路径进来，一批已校验的树进库，坏的进报告。
 *
 * 五条地基：
 *
 *  · **id 来自路径**：`ai/hound.tree.json` 就是 `ai/hound`。判据不仅验"能推出来"，
 *    还验**四种拒绝**（不是树文件 / 根下直放 / 根外 / `..`）—— 它们各自对应一种
 *    "人以为配上了、其实永远解析不到"的形状。
 *  · **一个坏文件不阻断整批**：三份里坏一份 ⇒ 好的那两份**真的在库里**。
 *    只断言 `failed.length === 1` 的判据会在"整批都没装上"时照样绿。
 *  · **撞 id ⇒ 后者失败、先到的保留**：必须验**内容**（先到的那棵在库里），
 *    验 `has(id)` 分不出谁赢。
 *  · **跨批次重复不算错**：那是热重载，`put` 覆盖 + `revision` 增加。
 *    这条钉住"重复判定只在批内"的边界，否则编辑器保存一次就报一次假错。
 *  · **顺序确定**：同一批打乱两次，报告逐字节相同 —— 撞车时"谁先到"不能靠运气。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { bt } from "../../src/extensions/ai/behavior.ts";
import { AI_TREE_BAD_PATH, parseTreeAsset, serializeTreeAsset, treeAssetIdFromPath } from "../../src/extensions/mobs/tree-asset.ts";
import { DEFAULT_TREE_ASSET, TreeLibrary } from "../../src/extensions/mobs/tree-library.ts";
import {
  AI_TREE_DUPLICATE_ID,
  loadTreeFiles,
  loadTreeTexts,
  treeLoadShort,
  treesLoadedClean,
  type TreeTextEntry,
} from "../../src/extensions/mobs/tree-loader.ts";
import { engineError, err, ok } from "../../src/foundation/result.ts";

/** 一棵带「看见就追」的树（内容可辨认：根 id 叫 `a`）。 */
function treeA() {
  return bt.sequence("a.root", bt.check("a.c", "mob.seesFoe"), bt.do("a.d", "mob.huntNearest"));
}

/** 另一棵（根 id 叫 `b`）—— 用来分辨"库里到底是哪一份"。 */
function treeB() {
  return bt.sequence("b.root", bt.check("b.c", "mob.canDecide"), bt.do("b.d", "mob.wander"));
}

function text(tree: ReturnType<typeof treeA>): string {
  return serializeTreeAsset(tree);
}

// ------------------------------------------------------------------ ① 路径 → id

test("[id] ★ 路径推 id：反斜杠 / 大小写 / 根前缀都归一", () => {
  const cases: [string, string, string][] = [
    ["ai/hound.tree.json", "", "ai/hound"],
    ["./ai/hound.tree.json", "", "ai/hound"],
    ["AI/Hound.TREE.JSON", "", "ai/hound"],
    ["web\\assets\\ai\\hound.tree.json", "web/assets", "ai/hound"],
    ["/assets//ai//boss/golem.tree.json", "assets", "ai/boss/golem"],
  ];
  for (const [path, root, want] of cases) {
    const r = treeAssetIdFromPath(path, root);
    assert.equal(r.ok, true, `${path}（根 ${root}）应当能推出 id：${r.ok ? "" : r.error.message}`);
    if (r.ok) assert.equal(r.value, want, `${path}（根 ${root}）`);
  }
});

test("[id] ★ 四种拒绝：不是树文件 / 根下直放 / 根外 / 带 ..", () => {
  const bad: [string, string, RegExp][] = [
    ["ai/hound.json", "", /不是决策树资产/],
    [".tree.json", "", /空 id/],
    ["ai/hound.tree.json", "assets", /不在资产根/],
    ["assets", "assets", /资产根本身/],
    ["../outside.tree.json", "assets", /不在资产根/],
    ["a/../../b.tree.json", "", /\.\./],
  ];
  for (const [path, root, why] of bad) {
    const r = treeAssetIdFromPath(path, root);
    assert.equal(r.ok, false, `「${path}」不该被接受`);
    if (!r.ok) {
      assert.equal(r.error.code, AI_TREE_BAD_PATH);
      assert.match(r.error.message, why, `「${path}」的拒绝理由要对得上`);
    }
  }
});

// ------------------------------------------------------------------ ② 一批 → 一批

test("[装载] ★ 两份好文件 ⇒ 两份都进库，报告干净", () => {
  const lib = new TreeLibrary();
  const report = loadTreeTexts(lib, [
    { path: "ai/hound.tree.json", text: text(treeA()) },
    { path: "ai/calm.tree.json", text: text(treeB()) },
  ]);
  assert.equal(report.loaded, 2);
  assert.deepEqual(report.failed, []);
  assert.deepEqual(report.ids, ["ai/calm", "ai/hound"], "ids 必须升序（否则报告不稳）");
  assert.equal(lib.has("ai/hound"), true);
  // 装进去的是**标题那棵树**，不是"某个能解析的树"
  assert.equal(lib.get("ai/hound")?.id, "a.root");
  assert.equal(lib.get("ai/calm")?.id, "b.root");
  assert.equal(treesLoadedClean(report), true);
  assert.equal(treeLoadShort(report), "trees 2");
});

test("[装载] ★★ 三份里坏一份：好的两份**真的在库里**，坏的进报告并带路径", () => {
  const lib = new TreeLibrary();
  const report = loadTreeTexts(lib, [
    { path: "ai/a.tree.json", text: text(treeA()) },
    { path: "ai/broken.tree.json", text: '{ "format": "aitree", "version": 1, "root": ' },
    { path: "ai/c.tree.json", text: text(treeB()) },
  ]);
  assert.equal(report.loaded, 2, "坏一份就整批不装 ⇒ 世界里所有生物退回内置树，而原因只是少了个括号");
  assert.equal(report.failed.length, 1);
  assert.equal(report.failed[0]?.path, "ai/broken.tree.json", "报告里没有路径 ⇒ 人不知道该去改哪个文件");
  assert.equal(report.failed[0]?.code, "AI_TREE.BAD_ASSET");
  assert.equal(lib.has("ai/a"), true);
  assert.equal(lib.has("ai/c"), true);
  assert.equal(lib.has("ai/broken"), false);
  assert.equal(treesLoadedClean(report), false);
  assert.equal(treeLoadShort(report), "trees 2/1");
});

test("[装载] 未知 op 的树也装不进来（装载期就拒绝，不等到第 500 拍）", () => {
  const lib = new TreeLibrary();
  const text = serializeTreeAsset(bt.sequence("x.root", bt.do("x.d", "mob.doesNotExist")));
  const report = loadTreeTexts(lib, [{ path: "ai/x.tree.json", text }]);
  assert.equal(report.loaded, 0);
  assert.equal(report.failed[0]?.code, "AI.UNKNOWN_OP");
  assert.equal(lib.has("ai/x"), false);
});

test("[装载] ★★ 撞 id ⇒ 后者失败、先到的保留（要看内容，不能只看 has）", () => {
  const lib = new TreeLibrary();
  // ASCII 序里 "AI/..." < "ai/..." ⇒ 大写那份先到
  const report = loadTreeTexts(lib, [
    { path: "ai/hound.tree.json", text: text(treeB()) },
    { path: "AI/HOUND.tree.json", text: text(treeA()) },
  ]);
  assert.equal(report.loaded, 1);
  assert.equal(report.failed.length, 1);
  assert.equal(report.failed[0]?.code, AI_TREE_DUPLICATE_ID);
  assert.equal(report.failed[0]?.path, "ai/hound.tree.json", "后到的那份要进报告（它被丢掉了）");
  // ★ 分辨力：库里的必须是**先到的**那棵
  assert.equal(lib.get("ai/hound")?.id, "a.root", "静默覆盖 ⇒ 症状是「我改的那棵没生效」，而人改的是被丢掉的那份");
});

test("[装载] ★ 跨批次重复不算错：那是热重载（覆盖 + revision 增加）", () => {
  const lib = new TreeLibrary();
  const first = loadTreeTexts(lib, [{ path: "ai/hound.tree.json", text: text(treeA()) }]);
  assert.equal(first.loaded, 1);
  const rev = lib.revision;
  const again = loadTreeTexts(lib, [{ path: "ai/hound.tree.json", text: text(treeB()) }]);
  assert.deepEqual(again.failed, [], "同一批里只出现一次 ⇒ 没有撞车；跨批次覆盖是正常的保存/重载");
  assert.equal(again.loaded, 1);
  assert.equal(lib.get("ai/hound")?.id, "b.root", "重载之后库里必须是新内容");
  assert.ok(lib.revision > rev, "revision 没变 ⇒ `MobBrain` 的树缓存不会作废，改了树要重启才生效");
});

// ------------------------------------------------------------------ ③ 读文件那一条路

test("[装载] ★ loadTreeFiles：读失败与解析失败进同一份报告，且读失败的排在前面", async () => {
  const lib = new TreeLibrary();
  const report = await loadTreeFiles(
    lib,
    ["ai/a.tree.json", "ai/gone.tree.json", "ai/bad.tree.json"],
    async (path) => {
      if (path === "ai/gone.tree.json") return err(engineError("FS.NOT_FOUND", "读不到"));
      if (path === "ai/bad.tree.json") return ok("{");
      return ok(text(treeA()));
    },
  );
  assert.equal(report.loaded, 1);
  assert.equal(report.ids.length, 1);
  assert.deepEqual(
    report.failed.map((f) => [f.path, f.code]),
    [
      ["ai/gone.tree.json", "FS.NOT_FOUND"],
      ["ai/bad.tree.json", "AI_TREE.BAD_ASSET"],
    ],
    "两类失败必须在同一份报告里（分开报的话总有一处会被忘掉）",
  );
});

test("[装载] ★ 报告的 ids 按 **id** 升序，而不是按路径顺序（大小写让两者不同）", () => {
  const lib = new TreeLibrary();
  const report = loadTreeTexts(lib, [
    // 路径序里 "Zeta" < "alpha"（ASCII 大写在前），而 id 序里 "alpha" < "zeta" ——
    // 两个顺序在这里**不同**，于是这条能分辨「顺手返回处理顺序」与「真的按 id 排序」。
    { path: "Zeta.tree.json", text: text(treeA()) },
    { path: "alpha.tree.json", text: text(treeB()) },
  ]);
  assert.equal(report.loaded, 2);
  assert.deepEqual(report.ids, ["alpha", "zeta"]);
  // 大小写归一只影响 id，不影响装进去的内容
  assert.equal(lib.get("zeta")?.id, "a.root");
  assert.equal(lib.get("alpha")?.id, "b.root");
});

test("[装载] ★ 空清单合法：0 棵、0 错、不抛（世界退回内置树）", () => {
  const lib = new TreeLibrary();
  const report = loadTreeTexts(lib, []);
  assert.deepEqual(report, { loaded: 0, ids: [], failed: [] });
  assert.equal(lib.has(DEFAULT_TREE_ASSET), true, "内置树永远在（它是「没配」的落点）");
});

test("[装载] ★ 顺序确定：同一批打乱两次，报告与库的内容都相同", () => {
  const entries: TreeTextEntry[] = [
    { path: "ai/a.tree.json", text: text(treeA()) },
    { path: "ai/z.tree.json", text: text(treeB()) },
    { path: "ai/m.tree.json", text: "{" },
  ];
  const one = new TreeLibrary();
  const r1 = loadTreeTexts(one, entries);
  const two = new TreeLibrary();
  const r2 = loadTreeTexts(two, [...entries].reverse());
  assert.deepEqual(r1, r2, "报告随输入顺序变 ⇒ 撞车时「谁先到」变成运气");
  assert.equal(one.fingerprint(), two.fingerprint(), "装载顺序不同却要得到同一份库");
});

// ------------------------------------------------------------------ ④ 与解析器的口径一致

test("[装载] 装进去的树与 `parseTreeAsset` 直接解析同一份文本得到的是同一棵", () => {
  const lib = new TreeLibrary();
  const src = text(treeA());
  assert.equal(lib.putText("ai/hound", src).ok, true);
  const parsed = parseTreeAsset(src);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;
  assert.deepEqual(lib.get("ai/hound"), parsed.value, "两条路（putText / 装载器）必须落到同一棵树上");
});
