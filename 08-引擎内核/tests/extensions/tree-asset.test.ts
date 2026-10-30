/**
 * L4 · 决策树资产：**树能被存成文件、且存的正是那一棵**
 *
 * 这一层是「配 AI 不用改代码」的最后一段。三条地基：
 *
 *  · **规范序列化**：同一棵树，无论对象字面量里字段怎么写，导出的字节必须相同。
 *    不同的话，git 里「树没改」看不出来，资产导入的 `sourceHash` 每次都变（等于每次重导入）。
 *  · **往返等价**：`parse(serialize(t))` 与 `t` 深度相等，且再导一次逐字节相同。
 *    只验「能 parse」是不够的：丢一个 `ticks` 字段的树照样 parse 成功，只是行为变了。
 *  · **坏资产在装载时就红**：未知 op / 重复 id / 版本太新，各自一个错误码。
 *    这些如果留到运行时，症状是「第 500 拍某只怪走到那条分支才炸」。
 *
 * ★ 为什么用真树（`MOB_TREE`）也跑一遍：玩具树（两三个节点）验不出 `children` 的
 *   嵌套顺序问题，而真实树的深度正好是「人手写 JSON 会写错」的那一档。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { AiAgent, bt, type AiNode } from "../../src/extensions/ai/behavior.ts";
import { MOB_OPS, MOB_TREE } from "../../src/extensions/mobs/mob-tree.ts";
import {
  AI_TREE_BAD_ASSET,
  AI_TREE_BAD_VERSION,
  TREE_FILE_SUFFIX,
  TREE_FORMAT_VERSION,
  isTreeAssetPath,
  parseTreeAsset,
  serializeTreeAsset,
} from "../../src/extensions/mobs/tree-asset.ts";

/** 两节点的玩具树（用于形状类断言）。 */
function toy(): AiNode {
  return bt.sequence("t.root", bt.check("t.c", "mob.canDecide"), bt.do("t.d", "mob.wander"));
}

test("[树资产] 规范序列化：字段书写顺序不同，导出的字节相同", () => {
  // 同一棵树，两个对象字面量的**键序不同**（JS 保留插入顺序，所以这是真实差异）
  const a: AiNode = {
    id: "r",
    kind: "sequence",
    children: [{ id: "c", kind: "do", op: "mob.canDecide" }],
  };
  const b = {
    children: [{ op: "mob.canDecide", kind: "do", id: "c" }],
    kind: "sequence",
    id: "r",
  } as unknown as AiNode;

  assert.equal(
    serializeTreeAsset(a),
    serializeTreeAsset(b),
    "键序跟着对象字面量走 ⇒ 同内容的树在两个文件里 diff 出一堆无关改动（且 sourceHash 每次都变）",
  );
});

test("[树资产] 往返：深度相等，且再导一次逐字节相同", () => {
  const t = toy();
  const once = serializeTreeAsset(t);
  const parsed = parseTreeAsset(once);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;

  assert.deepEqual(parsed.value, t, "往返丢了字段（`ticks` 之类的可选字段最容易丢）");
  assert.equal(serializeTreeAsset(parsed.value), once, "再导一次变了 ⇒ 序列化不是幂等的，文件会永远在改");
});

test("[树资产] 真实的内置树能往返（深度三段以上，玩具树验不出嵌套顺序）", () => {
  const text = serializeTreeAsset(MOB_TREE);
  const parsed = parseTreeAsset(text);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;
  assert.deepEqual(parsed.value, MOB_TREE);
  assert.equal(serializeTreeAsset(parsed.value), text);
  // 顺便证一下「解析出来的树真能跑」——只比结构的话，op 名写错也看不出来
  const created = AiAgent.create(parsed.value, MOB_OPS);
  assert.equal(created.ok, true);
});

test("[树资产] 版本比本代码新 ⇒ 拒绝打开（不按旧格式猜着读）", () => {
  const text = JSON.stringify({ format: "aitree", version: TREE_FORMAT_VERSION + 1, root: toy() });
  const r = parseTreeAsset(text);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, AI_TREE_BAD_VERSION, "新版本必须有自己的错误码 —— 处置办法不同（升级代码，不是改资产）");
});

test("[树资产] 四类坏资产各自报错，且都能在装载时抓到", () => {
  const cases: ReadonlyArray<{ readonly why: string; readonly text: string; readonly code: string }> = [
    { why: "根本不是 JSON", text: "{ nope", code: AI_TREE_BAD_ASSET },
    { why: "format 不是 aitree", text: JSON.stringify({ format: "scene", version: 1, root: toy() }), code: AI_TREE_BAD_ASSET },
    { why: "缺 root", text: JSON.stringify({ format: "aitree", version: 1 }), code: AI_TREE_BAD_ASSET },
    {
      why: "引用了不存在的 op",
      text: JSON.stringify({
        format: "aitree",
        version: 1,
        root: { id: "r", kind: "do", op: "mob.doesNotExist" },
      }),
      code: "AI.UNKNOWN_OP",
    },
    {
      why: "两个节点同一个 id",
      text: JSON.stringify({
        format: "aitree",
        version: 1,
        root: { id: "dup", kind: "sequence", children: [{ id: "dup", kind: "do", op: "mob.wander" }] },
      }),
      code: "AI.DUPLICATE_ID",
    },
  ];
  for (const c of cases) {
    const r = parseTreeAsset(c.text);
    assert.equal(r.ok, false, `${c.why} —— 竟然被接受了（运行期才会炸）`);
    if (r.ok) continue;
    assert.equal(r.error.code, c.code, `${c.why} —— 错误码不对`);
  }
});

test("[树资产] 后缀识别（编辑器据此决定用哪个查看器）", () => {
  assert.equal(isTreeAssetPath("assets/hound.tree.json"), true);
  assert.equal(isTreeAssetPath("assets/HOUND.TREE.JSON"), true, "大小写不敏感 —— 与 asset-list 的最长后缀规则一致");
  assert.equal(isTreeAssetPath("assets/hound.json"), false);
  assert.equal(TREE_FILE_SUFFIX, ".tree.json");
});
