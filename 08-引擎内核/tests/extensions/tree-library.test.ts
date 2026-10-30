/**
 * L4 · 树库：`AssetId → 树` 的同步解析（决策路径每拍都要用）
 *
 * 四条地基：
 *
 *  · **`put` 是唯一的校验点**：坏树进不来 ⇒ 「世界里跑着一棵坏树」在流程上不可能。
 *  · **失败不改 `revision`**：一次坏配置不该让所有怪白白重编译一遍树。
 *    这条最容易写错（先 `set` 再校验），而症状只是"卡一帧"，没人会去查。
 *  · **缺 id 不抛、但要能分辨**：`source: "missing"` 与 `"default"` 分开，
 *    否则「配了树但没生效」与「没配」在面板上一模一样。
 *  · **指纹可变可复原**：换一棵树指纹要变，换回来要变回原值 ——
 *    只验"变了"的话，一个恒定的随机数也满足。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { bt } from "../../src/extensions/ai/behavior.ts";
import { MOB_TREE } from "../../src/extensions/mobs/mob-tree.ts";
import {
  DEFAULT_TREE_ASSET,
  TreeLibrary,
} from "../../src/extensions/mobs/tree-library.ts";
import { AI_TREE_BAD_ASSET, serializeTreeAsset } from "../../src/extensions/mobs/tree-asset.ts";

/** 只漫游的树（与内置树的区别：看得见人也不追）。 */
function pacifist() {
  return bt.sequence("p.root", bt.check("p.c", "mob.canDecide"), bt.do("p.d", "mob.wander"));
}

/** 只追最近的（看不见就什么都不做）。 */
function blindHunter() {
  return bt.sequence("h.root", bt.check("h.c", "mob.seesFoe"), bt.do("h.d", "mob.huntNearest"));
}

test("[树库] 内置树总在库里：`resolve(\"\")` 命中它，且来源是 default", () => {
  const lib = new TreeLibrary();
  assert.deepEqual(lib.ids(), [DEFAULT_TREE_ASSET], "新建的库只该有内置树");
  const r = lib.resolve("");
  assert.equal(r.source, "default");
  assert.equal(r.id, DEFAULT_TREE_ASSET);
  assert.equal(r.wanted, "", "wanted 必须原样保留 —— 面板要显示「没配」而不是「配了内置树」");
  assert.deepEqual(r.tree, MOB_TREE);
});

test("[树库] 装一棵就能解析到它（且 id 原样是资产 id）", () => {
  const lib = new TreeLibrary();
  const put = lib.put("asset:calm", pacifist());
  assert.equal(put.ok, true);
  const r = lib.resolve("asset:calm");
  assert.equal(r.source, "asset");
  assert.equal(r.id, "asset:calm");
  assert.equal(lib.has("asset:calm"), true);
});

test("[树库] ★ 坏树被拒绝，且库与 revision 都没变", () => {
  const lib = new TreeLibrary();
  const before = lib.revision;
  const bad = lib.put("asset:bad", { id: "x", kind: "do", op: "mob.notAnOp" } as never);
  assert.equal(bad.ok, false, "未知 op 的树竟然装进来了 —— 运行期会在第 N 拍炸");
  if (!bad.ok) assert.equal(bad.error.code, "AI.UNKNOWN_OP");
  assert.equal(lib.has("asset:bad"), false);
  assert.equal(lib.revision, before, "失败的 put 不许改 revision（否则一次坏配置让所有怪重编译一遍树）");
});

test("[树库] 空串 / 纯空白 id 都拒绝（空串表示「没配」，不是一个 id）", () => {
  const lib = new TreeLibrary();
  assert.equal(lib.put("", pacifist()).ok, false);
  assert.equal(lib.put("   ", pacifist()).ok, false);
});

test("[树库] 每次成功 put 都推进 revision（热重载靠它让缓存作废）", () => {
  const lib = new TreeLibrary();
  const r0 = lib.revision;
  assert.equal(lib.put("a", pacifist()).ok, true);
  assert.equal(lib.revision, r0 + 1);
  // 换同一棵树也算一次（"内容没变"由调用方判断，库不替它猜）
  assert.equal(lib.put("a", pacifist()).ok, true);
  assert.equal(lib.revision, r0 + 2);
});

test("[树库] ★ 缺 id 不抛：回落到内置树，但来源是 missing（面板要能指名道姓）", () => {
  const lib = new TreeLibrary();
  const r = lib.resolve("asset:deleted");
  assert.equal(r.source, "missing");
  assert.equal(r.wanted, "asset:deleted", "必须留着被请求的 id —— 否则「哪棵树不见了」无从查起");
  assert.equal(r.id, DEFAULT_TREE_ASSET);
  assert.deepEqual(r.tree, MOB_TREE, "回落用的必须是内置树（不是上一棵）");
});

test("[树库] 删树：内置树删不掉，普通树删掉之后变成 missing", () => {
  const lib = new TreeLibrary();
  assert.equal(lib.remove(DEFAULT_TREE_ASSET), false, "内置树是「没配」的落点，删了世界就无处可落");
  assert.equal(lib.put("asset:x", pacifist()).ok, true);
  assert.equal(lib.remove("asset:x"), true);
  assert.equal(lib.resolve("asset:x").source, "missing");
  assert.equal(lib.remove("asset:x"), false, "删第二次不该再推进 revision（幂等）");
});

test("[树库] 指纹：换树会变，换回来要变回原值（否则「变了」可能只是随机数）", () => {
  const lib = new TreeLibrary();
  assert.equal(lib.put("asset:a", pacifist()).ok, true);
  const fp1 = lib.fingerprint();

  assert.equal(lib.put("asset:a", blindHunter()).ok, true);
  const fp2 = lib.fingerprint();
  assert.notEqual(fp2, fp1, "换了一棵树指纹不变 ⇒ 它没在算内容");

  assert.equal(lib.put("asset:a", pacifist()).ok, true);
  assert.equal(lib.fingerprint(), fp1, "换回同一棵必须得到同一个指纹 —— 回放与「同种子同世界」都靠这条");
});

test("[树库] 从资产文本装载（`.tree.json` 那一份内容）", () => {
  const lib = new TreeLibrary();
  const text = serializeTreeAsset(pacifist());
  const r = lib.putText("asset:fromFile", text);
  assert.equal(r.ok, true);
  assert.deepEqual(lib.get("asset:fromFile"), pacifist());

  const broken = lib.putText("asset:broken", "{ not json");
  assert.equal(broken.ok, false);
  if (!broken.ok) assert.equal(broken.error.code, AI_TREE_BAD_ASSET);
});
