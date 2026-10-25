/**
 * L2 · 场景与组件测试
 *
 * 重点覆盖三条容易静默出错的语义：
 *  ① 结构性修改必须走命令队列（遍历期改结构不许崩、不许跳过元素）
 *  ② 组件生命周期边沿（onEnable/onDisable 每边沿一次，不是每帧一次）
 *  ③ 世界变换的惰性缓存（改了父要能看见，不改就不重算）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { Vec2 } from "../../src/foundation/math/index.ts";

class Health extends Component {
  hp = 100;
  updates = 0;
  enables = 0;
  disables = 0;
  attaches = 0;
  readonly schema: ComponentSchema = {
    type: "test.health",
    fields: { hp: FieldType.Int },
  };
  override onAttach(): void {
    this.attaches++;
  }
  override onEnable(): void {
    this.enables++;
  }
  override onDisable(): void {
    this.disables++;
  }
  override onUpdate(): void {
    this.updates++;
  }
}

function makeScene(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  reg.register({ type: "test.health", fields: { hp: FieldType.Int } }, () => new Health());
  return { scene: new Scene("test", reg), reg };
}

test("spawn 是排队的：flush 之前查不到，flush 之后才出现", () => {
  const { scene } = makeScene();
  const r = scene.spawn("a");
  assert.ok(r.ok);
  const id = r.value.id;
  assert.equal(scene.find(id), undefined, "排队期间不该能被查到（否则'先查后建'的代码会拿到半成品）");
  assert.equal(scene.pendingCount, 1);
  scene.flush();
  assert.ok(scene.find(id) !== undefined);
  assert.equal(scene.pendingCount, 0);
});

test("组件生命周期：attach → enable（一次）→ 每步 update；disable 只在边沿触发一次", () => {
  const { scene } = makeScene();
  const r = scene.spawn("n");
  assert.ok(r.ok);
  scene.flush();
  const node = r.value;

  scene.attach(node.id, () => new Health());
  scene.flush();
  const h = node.get<Health>("test.health");
  assert.ok(h !== undefined, "组件应已挂上");
  assert.equal(h.attaches, 1);

  scene.step(1, 1 / 30);
  assert.equal(h.updates, 1);
  assert.equal(h.enables, 1, "首次生效触发一次 onEnable");

  scene.step(2, 1 / 30);
  assert.equal(h.updates, 2);
  assert.equal(h.enables, 1, "不许每帧都触发 onEnable");

  h.enabled = false;
  scene.step(3, 1 / 30);
  assert.equal(h.updates, 2, "disabled 后不更新");
  assert.equal(h.disables, 1);

  scene.step(4, 1 / 30);
  assert.equal(h.disables, 1, "不许每帧都触发 onDisable");

  h.enabled = true;
  scene.step(5, 1 / 30);
  assert.equal(h.updates, 3);
  assert.equal(h.enables, 2);
});

test("在 onUpdate 里销毁自己：不崩，并且后续步不再更新它", () => {
  const { scene } = makeScene();
  const r = scene.spawn("suicide");
  assert.ok(r.ok);
  scene.flush();
  const node = r.value;

  class Suicide extends Component {
    updates = 0;
    readonly schema: ComponentSchema = { type: "test.suicide", fields: {} };
    override onUpdate(): void {
      this.updates++;
      this.node && scene.destroy(this.node.id);
    }
  }
  scene.components.register({ type: "test.suicide", fields: {} }, () => new Suicide());
  scene.attach(node.id, () => new Suicide());
  scene.flush();
  const c = node.get<Suicide>("test.suicide")!;

  assert.doesNotThrow(() => scene.step(1, 1 / 30));
  assert.equal(c.updates, 1);
  // 销毁命令在 step 末尾的 flush 里执行 ⇒ 下一步不该再更新
  scene.step(2, 1 / 30);
  assert.equal(c.updates, 1, "已销毁的组件不许继续更新");
  assert.equal(scene.find(node.id), undefined);
});

test("世界变换：父移动后子跟着走；不移动时复用缓存（版本号不变）", () => {
  const { scene } = makeScene();
  const parent = scene.spawnImmediate("p");
  const child = scene.spawnImmediate("c", parent.id);
  parent.setLocalPosition(10, 0);
  child.setLocalPosition(5, 0);
  assert.deepEqual(child.worldPosition, new Vec2(15, 0));

  const v0 = child.version;
  child.worldTransform;
  child.worldTransform;
  assert.equal(child.version, v0, "只读不写时版本号不该变（否则缓存形同虚设）");

  parent.setLocalPosition(20, 0);
  assert.ok(child.version > v0, "父移动必须让子的版本号也前进（否则子会用旧缓存）");
  assert.deepEqual(child.worldPosition, new Vec2(25, 0));
});

test("activeInHierarchy：父失活时子组件不更新（不只看自己的 enabled）", () => {
  const { scene } = makeScene();
  const parent = scene.spawnImmediate("p");
  const child = scene.spawnImmediate("c", parent.id);
  scene.attach(child.id, () => new Health());
  scene.flush();
  const h = child.get<Health>("test.health")!;

  scene.step(1, 1 / 30);
  assert.equal(h.updates, 1);

  parent.active = false;
  scene.step(2, 1 / 30);
  assert.equal(h.updates, 1, "父失活后子不该更新");
  assert.equal(h.disables, 1);

  parent.active = true;
  scene.step(3, 1 / 30);
  assert.equal(h.updates, 2);
});

test("节点 id 不复用（销毁后新实体拿新 id，避免旧引用指向新对象）", () => {
  const { scene } = makeScene();
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", scene.rootId);
  const idA = a.id;
  scene.destroy(b.id);
  scene.flush();
  const c = scene.spawnImmediate("c", scene.rootId);
  assert.ok(c.id > b.id, `新 id ${c.id} 应大于已销毁的 ${b.id}`);
  assert.notEqual(c.id, idA);
});

test("spawn 指定 id（读档恢复）与重复 id 拒绝", () => {
  const { scene } = makeScene();
  const a = scene.spawn("a", null, 777);
  assert.ok(a.ok);
  scene.flush();
  assert.equal(a.value.id, 777);
  const dup = scene.spawn("b", null, 777);
  assert.equal(dup.ok, false);
  if (!dup.ok) assert.equal(dup.error.code, "SCENE.DUPLICATE_ID");
});

test("未注册的组件类型被拒绝（不是静默成功）", () => {
  const { scene } = makeScene();
  const n = scene.spawnImmediate("n");
  const r = scene.attach(n.id, () => {
    const c = new Health();
    // 伪造一个未注册类型
    Object.defineProperty(c, "schema", { value: { type: "test.nope", fields: {} } });
    return c;
  });
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SCENE.UNKNOWN_COMPONENT");
});

// ---------------------------------------------------------------- 层级环（批81）

test("★★ 不能把节点挂进自己的子树（否则 walk 无限递归 ⇒ 栈溢出）", () => {
  const scene = new Scene("cycle", new ComponentRegistry());
  // ★ `spawn` 返回 NodeId（不是 Node），要拿对象得走 `find`
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", scene.rootId);
  const c = scene.spawnImmediate("c", scene.rootId);
  a.addChild(b);
  b.addChild(c);

  // ① 自己挂自己
  assert.throws(() => a.addChild(a), /子树/, "自己挂自己应该抛");
  // ② 把祖先挂到自己的后代下面
  assert.throws(() => c.addChild(a), /子树/, "把祖先挂到后代下面应该抛");
  // ③ 把根挂到后代下面也要拦（root 是所有节点的祖先）
  assert.throws(() => c.addChild(scene.root), /子树/);

  // ★ 关键：抛完之后层级必须**一点没变** —— 半途改坏再抛，比不抛更糟。
  //   这里真的走一遍 walk：如果环已经形成，这一行是栈溢出（RangeError），
  //   而不是断言失败 —— 判据本身就是那场事故的复现。
  const seen: NodeId[] = [];
  scene.root.walk((n) => seen.push(n.id));
  assert.deepEqual(seen, [scene.rootId, a.id, b.id, c.id], "抛异常时层级已经被改坏了");
  assert.equal(b.parent, a);
  assert.equal(c.parent, b);
});

test("★ 正常的换父仍然可以（新父不是自己的后代）", () => {
  const scene = new Scene("cycle", new ComponentRegistry());
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", scene.rootId);
  const c = scene.spawnImmediate("c", scene.rootId);
  a.addChild(c);
  b.addChild(c); // c 从 a 移到 b：合法
  assert.equal(c.parent, b, "换父不该被环检查误伤");
  assert.equal(a.children.includes(c), false, "旧父还留着它");
  assert.equal(b.children.filter((n) => n === c).length, 1, "新父里重复了");
});

test("★ 重复 addChild 同一个父是幂等的（不重复入 children，也不抛）", () => {
  const scene = new Scene("cycle", new ComponentRegistry());
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", scene.rootId);
  a.addChild(b);
  assert.doesNotThrow(() => a.addChild(b), "同一个父重复挂不该抛");
  assert.equal(a.children.filter((n) => n === b).length, 1);
});

test("★ isAncestorOf：只认严格祖先（自己不算自己的祖先）", () => {
  const scene = new Scene("cycle", new ComponentRegistry());
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", scene.rootId);
  const c = scene.spawnImmediate("c", scene.rootId);
  a.addChild(b);
  b.addChild(c);
  assert.equal(a.isAncestorOf(c), true);
  assert.equal(a.isAncestorOf(b), true);
  assert.equal(c.isAncestorOf(a), false, "方向反了");
  assert.equal(a.isAncestorOf(a), false, "自己不该算自己的祖先（否则 addChild 的幂等分支会被它抢走）");
});
