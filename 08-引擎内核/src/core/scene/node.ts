/**
 * L2 · 节点（变换层级）
 *
 * 一个节点 = 一个**变换**（局部位置/旋转/缩放）+ 一组组件 + 一串子节点。
 * 与 Unity 的 GameObject、Cocos 的 Node 同构。
 *
 * ★ 世界变换用**惰性求值 + 版本号缓存**，而不是每帧全树遍历。
 *   理由：2.5D 一张地图上 90% 的静态物件（树、石头）永远不动，
 *   每帧重算它们的 world matrix 是纯浪费；而"移动一个节点"才需要重算它和它的子树。
 *   实现：每个节点有 `version`，父节点变更时把自己和子树的 version 都 +1；
 *   `worldTransform` 读到 `cacheVersion !== version` 才重算。
 *
 *   ⚠️ 上一层（上一代引擎）在这里出过一个真错：为了"省一次排序"直接把绘制顺序
 *      交给实体创建顺序，结果"远的挡住近的"。**省下来的那点开销，远小于隐式契约的代价。**
 *      所以这里宁可多维护一个 version 字段，也要让"世界变换"是**明确可读**的。
 */

import { Affine2, Vec2 } from "../../foundation/math/index.ts";
import type { Component } from "./component.ts";

export type NodeId = number;

let NEXT_NODE_ID = 1;

/** 仅供判据/回放重置 id 分配器（生产代码不该调）。 */
export function __resetNodeIdsForTest(next = 1): void {
  NEXT_NODE_ID = next;
}

export class Node {
  readonly id: NodeId;
  name: string;
  parent: Node | null = null;
  readonly children: Node[] = [];
  readonly components: Component[] = [];

  /** 局部变换成分。改它们要调 `markTransformDirty()`（或用 setter）。 */
  localPosition: Vec2 = Vec2.zero;
  localRotation = 0;
  localScale: Vec2 = Vec2.one;
  /** 层级顺序微调（同一父下 `zIndex` 大的后画）。 */
  zIndex = 0;
  /** 整棵子树的开关：`false` 时组件不更新、不渲染。 */
  active = true;
  /** 渲染层（编辑器可以按层隐藏）。 */
  layer = 0;

  /** 变换版本：任何影响世界变换的改动都 +1。 */
  version = 0;
  private cacheVersion = -1;
  private cachedWorld: Affine2 = Affine2.identity;
  private destroyed = false;

  constructor(name = "Node", id?: NodeId) {
    this.id = id ?? NEXT_NODE_ID++;
    if (id !== undefined) NEXT_NODE_ID = Math.max(NEXT_NODE_ID, id + 1);
    this.name = name;
  }

  get isDestroyed(): boolean {
    return this.destroyed;
  }

  addChild(child: Node): this {
    if (child.parent === this) return this;
    child.parent?.removeChild(child);
    child.parent = this;
    this.children.push(child);
    child.markTransformDirty();
    return this;
  }

  removeChild(child: Node): boolean {
    const i = this.children.indexOf(child);
    if (i < 0) return false;
    this.children.splice(i, 1);
    child.parent = null;
    child.markTransformDirty();
    return true;
  }

  attach(c: Component): void {
    if (c.node === this) return;
    c.node?.detach(c);
    c.node = this;
    this.components.push(c);
    c.onAttach();
  }

  detach(c: Component): boolean {
    const i = this.components.indexOf(c);
    if (i < 0) return false;
    if (c.isActive) c._setActive(false);
    this.components.splice(i, 1);
    c.node = null;
    c.onDetach();
    return true;
  }

  get<T extends Component>(type: string): T | undefined {
    for (const c of this.components) if (c.type === type) return c as T;
    return undefined;
  }

  /** 世界变换（惰性 + 版本缓存）。 */
  get worldTransform(): Affine2 {
    if (this.cacheVersion === this.version) return this.cachedWorld;
    const local = Affine2.fromTrs(this.localPosition, this.localRotation, this.localScale);
    const w = this.parent === null ? local : this.parent.worldTransform.multiply(local);
    this.cachedWorld = w;
    this.cacheVersion = this.version;
    return w;
  }

  get worldPosition(): Vec2 {
    return this.worldTransform.transformPoint(Vec2.zero);
  }

  setLocalPosition(x: number, y: number): this {
    this.localPosition = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }

  /** 标脏：自己 + 整棵子树（子节点的世界变换都依赖我）。 */
  markTransformDirty(): void {
    this.version++;
    for (const c of this.children) c.markTransformDirty();
  }

  /** 是否在整条祖先链上都 active。 */
  get activeInHierarchy(): boolean {
    let n: Node | null = this;
    while (n !== null) {
      if (!n.active) return false;
      n = n.parent;
    }
    return true;
  }

  /** 深度优先遍历（顺序**确定**：子节点按添加顺序）。 */
  walk(fn: (n: Node) => void): void {
    fn(this);
    for (const c of this.children) c.walk(fn);
  }

  /** 从根到自己的路径（诊断/日志用）。 */
  path(): string {
    const parts: string[] = [];
    let n: Node | null = this;
    while (n !== null) {
      parts.unshift(n.name);
      n = n.parent;
    }
    return "/" + parts.join("/");
  }

  /** 内部：销毁时标记，避免使用已销毁节点。 */
  _markDestroyed(): void {
    this.destroyed = true;
    for (const c of this.components) {
      if (c.isActive) c._setActive(false);
      c.node = null;
      c.onDetach();
    }
    this.components.length = 0;
    for (const c of this.children) c._markDestroyed();
    this.children.length = 0;
    this.parent = null;
  }
}
