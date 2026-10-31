/**
 * L4 · 决策树的编辑模型（批157）：增删拖拽算得对、坏树报得出、报的位置对得上
 *
 * 批155 树能存成文件，批156 宿主能把文件装进库。剩下的那一段是「人怎么改它」——
 * 这个文件验的就是改的时候会不会算错、错在哪一格。
 *
 * 六条地基：
 *
 *  · **移动要按修正后的下标定位**：先摘源节点、再按**原来的**目标下标插入，
 *    在「源在目标左边」时会静默落错位置（不是报错）。判据看**内容**：
 *    那个 selector 真的多了一个孩子、而第三个孩子真的还是原来那个 `do`。
 *    只断言"移动成功"或"节点数没变"的判据在这里全绿。
 *  · **结构操作永远不校验**（文件头 ①）：往叶子下面挂子节点是允许的中间态。
 *    这条要正面钉住 —— 否则下一个人"顺手加个校验"就把编辑器的自然动作堵死了。
 *  · **合法性只有一份**：坏样本必须同时被 `AiAgent.create` 拒绝（跨模块对照），
 *    否则 `treeIssue` 可能是在自己编错误、而真实装载路径照样放行。
 *  · **报的位置要对得上**：`message` 以 `pathText` 开头（两边同一份约定），
 *    且映射回来的下标路径指向**那个真的坏了的节点**（比对 id，不看下标）。
 *  · **只报第一条，修掉就报下一条**：两处错时先报第一处；把第一处修好之后
 *    第二处必须冒出来 —— 只验"有错"的话，报的是不是同一处永远说不清。
 *  · **改完的树存得下读得回**：序列化 → 解析 → 再序列化**逐字节相同**。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { AI_BAD_TREE, AI_UNKNOWN_OP, AiAgent, bt, type AiNode } from "../../src/extensions/ai/behavior.ts";
import {
  TREE_EDIT_BAD_PATH,
  TREE_EDIT_CYCLE,
  TREE_EDIT_ROOT,
  addChild,
  cloneNode,
  flattenTree,
  moveNode,
  nodeAt,
  patchNode,
  pathAfterRemoval,
  pathFromText,
  pathText,
  removeNode,
  treeAdvice,
  treeIssue,
  treeRows,
  treeStatusText,
  type TreePath,
} from "../../src/extensions/mobs/tree-edit.ts";
import { MOB_OPS } from "../../src/extensions/mobs/mob-tree.ts";
import { parseTreeAsset, serializeTreeAsset } from "../../src/extensions/mobs/tree-asset.ts";

/**
 * 夹具：
 * ```
 * r    sequence
 * ├ 0  check   c1 / mob.seesFoe
 * ├ 1  selector s
 * │   ├ 0 do   d1 / mob.huntNearest
 * │   └ 1 wait w1 / 3 tick
 * └ 2  do      z1 / mob.wander      ← 第三个孩子专门用来验"下标修正"
 * ```
 */
function fixture(): AiNode {
  return bt.sequence(
    "r",
    bt.check("c1", "mob.seesFoe"),
    bt.selector("s", bt.do("d1", "mob.huntNearest"), bt.wait("w1", 3)),
    bt.do("z1", "mob.wander"),
  );
}

function ids(root: AiNode): string[] {
  return flattenTree(root).map((r) => r.node.id);
}

function kidsIds(root: AiNode, path: TreePath): string[] {
  const n = nodeAt(root, path);
  assert.ok(n !== undefined, `路径 ${pathText(path)} 应当存在`);
  return (n.children ?? []).map((c) => c.id);
}

test("[编辑] flattenTree：顺序是父在子前，深度与序号都对", () => {
  const rows = flattenTree(fixture());
  assert.deepEqual(ids(fixture()), ["r", "c1", "s", "d1", "w1", "z1"]);
  assert.deepEqual(
    rows.map((r) => r.depth),
    [0, 1, 1, 2, 2, 1],
  );
  assert.deepEqual(
    rows.map((r) => r.index),
    [-1, 0, 1, 0, 1, 2],
  );
  assert.deepEqual(
    rows.map((r) => pathText(r.path)),
    ["root", "root.children[0]", "root.children[1]", "root.children[1].children[0]", "root.children[1].children[1]", "root.children[2]"],
  );
});

test("[编辑] nodeAt：根、深层、越界各一条", () => {
  const t = fixture();
  assert.equal(nodeAt(t, [])?.id, "r");
  assert.equal(nodeAt(t, [1, 1])?.id, "w1");
  assert.equal(nodeAt(t, [3]), undefined);
  assert.equal(nodeAt(t, [0, 0]), undefined, "叶子下面没有孩子，不该返回一个零值节点");
});

test("[编辑] ★ addChild 是纯的：新树多一个、原树一个字节没变", () => {
  const t = fixture();
  const before = serializeTreeAsset(t);
  const r = addChild(t, [1], bt.wait("w2", 1));
  assert.ok(r.ok);
  assert.deepEqual(kidsIds(r.value, [1]), ["d1", "w1", "w2"]);
  assert.equal(serializeTreeAsset(t), before, "原树被改了 —— 撤销栈的快照从此不可信");
  assert.equal(serializeTreeAsset(r.value).includes('"w2"'), true);
});

test("[编辑] addChild 可以插在中间（at）", () => {
  const r = addChild(fixture(), [1], bt.do("d0", "mob.wander"), 0);
  assert.ok(r.ok);
  assert.deepEqual(kidsIds(r.value, [1]), ["d0", "d1", "w1"]);
});

test("[编辑] addChild 的父不存在 ⇒ TREE_EDIT.BAD_PATH", () => {
  const r = addChild(fixture(), [2, 0], bt.wait("x", 1));
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, TREE_EDIT_BAD_PATH);
});

test("[编辑] ★ 往叶子下面挂子节点是允许的中间态（编辑器不拦，面板标红）", () => {
  const r = addChild(fixture(), [0], bt.wait("extra", 1));
  assert.ok(r.ok, "结构层拦住了 —— 「先搭架子后填内容」的编辑节奏就断了");
  assert.equal(kidsIds(r.value, [0]).length, 1);
  // 而这棵树现在真的装不上：判据在下一层（treeIssue），不在这里
  assert.notEqual(treeIssue(r.value), null);
});

test("[编辑] removeNode 删中间节点：子树一起走", () => {
  const r = removeNode(fixture(), [1, 0]);
  assert.ok(r.ok);
  assert.deepEqual(kidsIds(r.value, [1]), ["w1"]);
  assert.equal(ids(r.value).includes("d1"), false);
});

test("[编辑] ★ removeNode 删根被拒，且原树没被改动", () => {
  const t = fixture();
  const before = serializeTreeAsset(t);
  const r = removeNode(t, []);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, TREE_EDIT_ROOT);
  assert.equal(serializeTreeAsset(t), before);
});

test("[编辑] ★ moveNode 同父换序：按内容看顺序真的变了", () => {
  const r = moveNode(fixture(), [1, 0], [1], 2);
  assert.ok(r.ok);
  assert.deepEqual(kidsIds(r.value, [1]), ["w1", "d1"]);
});

test("[编辑] ★★ moveNode 跨父且目标在源右边：下标要修正，否则静默落错地方", () => {
  // 把 root 的第 1 个孩子（c1）挪到 selector（原第 2 个孩子）里。
  // 摘掉 c1 之后 selector 变成第 1 个孩子 —— 用旧下标 [1] 去找会落到 z1 那个分支上。
  const r = moveNode(fixture(), [0], [1], 1);
  assert.ok(r.ok);
  assert.deepEqual(kidsIds(r.value, [0]), ["d1", "c1", "w1"], "没挪进 selector");
  assert.deepEqual(kidsIds(r.value, [1]), [], "挪进了错误的分支（下标没修正）");
});

test("[编辑] ★ moveNode 拖进自己（或自己的子孙）⇒ TREE_EDIT.CYCLE", () => {
  for (const to of [[1], [1, 0]] as TreePath[]) {
    const r = moveNode(fixture(), [1], to, 0);
    assert.equal(r.ok, false, `${pathText(to)} 应当被拒`);
    if (!r.ok) assert.equal(r.error.code, TREE_EDIT_CYCLE);
  }
});

test("[编辑] moveNode 的根不能动；摘掉之后目标不存在 ⇒ BAD_PATH（不是静默建造）", () => {
  const r1 = moveNode(fixture(), [], [1], 0);
  assert.equal(r1.ok, false);
  if (!r1.ok) assert.equal(r1.error.code, TREE_EDIT_ROOT);
  const r2 = moveNode(fixture(), [2], [5], 0);
  assert.equal(r2.ok, false);
  if (!r2.ok) assert.equal(r2.error.code, TREE_EDIT_BAD_PATH);
});

test("[编辑] pathAfterRemoval：只有「同父且排在源之后」减一", () => {
  assert.deepEqual(pathAfterRemoval([0], [1]), [0], "同父、源在目标左边 ⇒ 目标前移一格");
  assert.deepEqual(pathAfterRemoval([0], [2]), [1]);
  assert.deepEqual(pathAfterRemoval([2], [0]), [0], "源在目标右边 ⇒ 不动");
  assert.deepEqual(pathAfterRemoval([1, 0], [1]), [1], "目标是源的祖先 ⇒ 不动");
  assert.deepEqual(pathAfterRemoval([1], [1, 0]), [1, 0], "目标是源的子孙（会被 CYCLE 拦住，这里只验不改）");
  assert.deepEqual(pathAfterRemoval([0], [0, 1]), [0, 1], "另一条分支的深层路径不动");
  assert.deepEqual(pathAfterRemoval([0, 1], [0, 5]), [0, 4], "同父深层也要减");
});

test("[编辑] patchNode 改 id / op / ticks，其余字段保留", () => {
  const a = patchNode(fixture(), [0], { op: "mob.hasGrudge" });
  assert.ok(a.ok);
  assert.equal(nodeAt(a.value, [0])?.op, "mob.hasGrudge");
  const b = patchNode(fixture(), [1, 1], { ticks: 7 });
  assert.ok(b.ok);
  assert.equal(nodeAt(b.value, [1, 1])?.ticks, 7);
  const c = patchNode(fixture(), [2], { id: "z9" });
  assert.ok(c.ok);
  assert.equal(nodeAt(c.value, [2])?.id, "z9");
  assert.equal(nodeAt(c.value, [2])?.op, "mob.wander", "改 id 不该把 op 弄丢");
});

test("[编辑] patchNode 能换 kind（叶子 ↔ 容器），子节点原样留着让校验去报", () => {
  const t = bt.sequence("r", bt.wait("w", 1));
  const toSeq = patchNode(t, [0], { kind: "sequence" });
  assert.ok(toSeq.ok);
  assert.equal(nodeAt(toSeq.value, [0])?.kind, "sequence");
  assert.equal(nodeAt(toSeq.value, [0])?.ticks, 1, "换 kind 不该把 ticks 抹掉");
  assert.notEqual(treeIssue(toSeq.value), null, "空 sequence 现在装不上 —— 这正是面板要报的");
  // 反过来：把带孩子的容器换成叶子 ⇒ 非法，但**允许存在**（中间态）
  const t2 = bt.sequence("r", bt.selector("s", bt.wait("a", 1), bt.wait("b", 1)));
  const toDo = patchNode(t2, [0], { kind: "do", op: "mob.wander" });
  assert.ok(toDo.ok);
  assert.equal(nodeAt(toDo.value, [0, 1])?.id, "b", "换 kind 不该丢掉子树");
  assert.equal(treeIssue(toDo.value)?.pathText, "root.children[0]");
});

test("[编辑] ★ treeIssue：空容器报得出来，位置指向那个容器", () => {
  const broken = bt.sequence("r", bt.check("c1", "mob.seesFoe"), bt.sequence("empty"));
  const issue = treeIssue(broken);
  assert.notEqual(issue, null);
  assert.equal(issue?.code, AI_BAD_TREE);
  assert.equal(issue?.pathText, "root.children[1]");
  assert.deepEqual(issue?.path, [1]);
  assert.equal(nodeAt(broken, issue?.path ?? [])?.id, "empty", "标红的那一行必须真的是空容器");
  assert.equal(issue?.message.startsWith("root.children[1]"), true, "校验器的路径写法与 pathText 必须一致");
});

test("[编辑] ★ 坏样本必须同时被 AiAgent.create 拒绝（合法性只有一份）", () => {
  const samples: readonly [string, AiNode][] = [
    ["空 sequence", bt.sequence("r", bt.sequence("e"))],
    ["未知 op", bt.sequence("r", bt.do("d", "mob.nope"))],
    ["叶子带子节点", bt.sequence("r", { id: "d", kind: "do", op: "mob.wander", children: [bt.wait("w", 1)] })],
    ["wait 的 ticks 非法", bt.sequence("r", bt.wait("w", -1))],
    ["id 重复", bt.sequence("r", bt.do("same", "mob.wander"), bt.wait("same", 1))],
    ["inverter 两个孩子", bt.sequence("r", { id: "i", kind: "inverter", children: [bt.wait("a", 1), bt.wait("b", 1)] })],
  ];
  for (const [name, tree] of samples) {
    assert.equal(AiAgent.create(tree, MOB_OPS).ok, false, `${name} 居然被装载路径放行了`);
    const issue = treeIssue(tree);
    assert.notEqual(issue, null, `${name} 面板上没报出来`);
    // ★ 每条校验错误都必须带位置：否则面板只知道"这棵树坏了"，不知道标哪一行。
    //   实测漏过一次 —— 重复 id 那条原本只有 `detail.id`，于是树里最隐蔽的一类错
    //   （两个节点共用记忆）在面板上是"没有任何一行变红"。这条判据就是那次补回来的。
    assert.notEqual(issue?.path, null, `${name} 的错误里没有位置（detail.path 缺了）`);
    assert.equal(issue?.message.startsWith(issue?.pathText ?? "\u0000"), true, `${name} 的消息与位置串对不上`);
  }
});

test("[编辑] ★★ 只报第一条；修掉它之后报下一条（不是一直报同一处）", () => {
  const two = bt.sequence("r", bt.sequence("empty"), bt.do("d", "mob.nope"));
  const first = treeIssue(two);
  assert.equal(first?.pathText, "root.children[0]");
  // 把第一个修掉（塞一个合法叶子），第二条必须冒出来，而且指向另一个节点
  const fixed1 = addChild(two, [0], bt.wait("w", 1));
  assert.ok(fixed1.ok);
  const second = treeIssue(fixed1.value);
  assert.notEqual(second, null);
  assert.equal(second?.code, AI_UNKNOWN_OP);
  assert.equal(second?.pathText, "root.children[1]");
  assert.equal(nodeAt(fixed1.value, second?.path ?? [])?.id, "d");
});

test("[编辑] treeAdvice：单子容器与 wait 0 各一条，干净树零条", () => {
  // ★ 根必须有两个孩子：只有一个的话根自己也算「单子容器」，那就分不清
  //   少的这一条是"没报"还是"多报了根"（第一种假绿）。
  const t = bt.sequence("r", bt.selector("s", bt.wait("w", 0)), bt.wait("z", 1));
  const a = treeAdvice(t);
  assert.equal(a.length, 2, JSON.stringify(a));
  assert.deepEqual(a.map((x) => pathText(x.path)), ["root.children[0]", "root.children[0].children[0]"]);
  assert.equal(treeAdvice(fixture()).length, 0, "干净树不该有提醒");
  assert.equal(treeIssue(t), null, "这两条是建议，不是规则 —— 树是合法的");
});

test("[编辑] ★ treeRows：bad 落在坏的那一行，warn 落在建议那一行，两者冲突时 bad 优先", () => {
  const broken = bt.sequence("r", bt.selector("s", bt.wait("w", 0)), bt.do("d", "mob.nope"));
  const rows = treeRows(broken);
  const byId = new Map(rows.map((r) => [r.id, r]));
  // 「d 的 op 不认识」是错，「s 只有一个孩子」只是建议 —— 两种标记不能混
  assert.equal(byId.get("d")?.marker, "bad");
  assert.equal(byId.get("s")?.marker, "warn");
  assert.equal(byId.get("w")?.marker, "warn");
  assert.equal(byId.get("r")?.marker, "none");
  // 冲突：同一行既是第一条错、又是建议（id 撞车 + 只有一个孩子）
  const conflict = bt.sequence("s", bt.sequence("s", bt.wait("w", 1)), bt.wait("z", 1));
  const rows2 = treeRows(conflict);
  assert.equal(rows2.length, 4);
  assert.equal(rows2[1]?.marker, "bad", "同一行只许一个标记，且 bad 不能被降级成 warn");
  assert.equal(rows2[0]?.marker, "none", "根上没错，不该被连带标红");
  assert.equal(rows2[2]?.marker, "none");
  assert.equal(treeAdvice(conflict).length, 1, "夹具前提：那一行同时命中一条建议");
});

test("[编辑] treeStatusText 三种状态各一句，且空串不会出现", () => {
  const clean = fixture();
  assert.equal(treeStatusText(treeIssue(clean), treeAdvice(clean)), "装得上 · 没有提醒");
  const warned = bt.sequence("r", bt.selector("s", bt.wait("w", 0)), bt.wait("z", 1));
  assert.equal(treeStatusText(treeIssue(warned), treeAdvice(warned)), "装得上 · 2 条提醒");
  const broken = bt.sequence("r", bt.sequence("e"));
  const text = treeStatusText(treeIssue(broken), treeAdvice(broken));
  assert.equal(text.startsWith(AI_BAD_TREE), true);
  assert.equal(text.includes("："), true);
});

test("[编辑] pathFromText 与 pathText 互逆；解析不了的返回 null（不猜）", () => {
  const t = fixture();
  for (const row of flattenTree(t)) {
    assert.deepEqual(pathFromText(t, pathText(row.path)), row.path);
  }
  assert.equal(pathFromText(t, "root.children[9]"), null, "不存在的位置不该映射出下标");
  assert.equal(pathFromText(t, "root.kids[0]"), null);
  assert.equal(pathFromText(t, ""), null);
});

test("[编辑] ★ 一串编辑之后导出：解析回来逐字节相同，且树是合法的", () => {
  let t: AiNode = fixture();
  const steps: ((root: AiNode) => ReturnType<typeof addChild>)[] = [
    (r) => addChild(r, [1], bt.check("c2", "mob.hasGrudge"), 0),
    // ★ `moveNode` 的第三个参数是**目标父的路径**（不是「父 + 序号」）：
    //   写成 [1, 1] 的话 z1 会挂到 d1 下面 —— 而世界照样能跑（一棵合法但没有意义的树）。
    (r) => moveNode(r, [2], [1], 0),
    (r) => patchNode(r, [1, 0], { op: "mob.huntGrudge" }),
    (r) => removeNode(r, [0]),
  ];
  for (const step of steps) {
    const r = step(t);
    assert.ok(r.ok, `这一步失败了：${r.ok ? "" : r.error.message}`);
    t = r.value;
  }
  assert.equal(treeIssue(t), null, "这一串编辑之后树应当是合法的");
  const text = serializeTreeAsset(t);
  const back = parseTreeAsset(text);
  assert.ok(back.ok, back.ok ? "" : back.error.message);
  assert.equal(serializeTreeAsset(back.value), text, "存下去再读回来不是同一份 —— 资产每次都会重导入");
  assert.deepEqual(ids(back.value), ["r", "s", "z1", "c2", "d1", "w1"]);
  // cloneNode 与"原树共享子树"是撤销栈快照的前提：拷出来的树改不动原树
  const copy = cloneNode(t);
  const touched = patchNode(copy, [0], { id: "s9" });
  assert.ok(touched.ok);
  assert.equal(nodeAt(t, [0])?.id, "s", "cloneNode 不是深拷贝 —— 撤销栈会一起被改");
});
