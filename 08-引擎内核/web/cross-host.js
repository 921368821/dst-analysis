// src/core/scene/component.ts
var FieldType = {
  Int: "i32",
  Float: "f32",
  Double: "f64",
  Bool: "bool",
  String: "string",
  Vec2: "vec2",
  Color: "color",
  /** 资产引用：存 AssetId（GUID），不存路径 —— 路径会变，GUID 不会。 */
  Asset: "asset",
  /** 场景内节点引用：存节点 id。 */
  NodeRef: "noderef",
  /** 字符串数组（标签、配方列表）。 */
  StringArray: "string[]"
};
function zeroValue(t) {
  switch (t) {
    case FieldType.Int:
    case FieldType.Float:
    case FieldType.Double:
      return 0;
    case FieldType.Bool:
      return false;
    case FieldType.String:
      return "";
    case FieldType.Vec2:
      return { x: 0, y: 0 };
    case FieldType.Color:
      return { r: 1, g: 1, b: 1, a: 1 };
    case FieldType.Asset:
    case FieldType.NodeRef:
      return "";
    case FieldType.StringArray:
      return [];
    default:
      return null;
  }
}
var Component = class {
  /** 所属节点。`null` 只在 attach 之前/ detach 之后。 */
  node = null;
  enabled = true;
  /** 场景内部用：记录 enabled 状态，避免重复触发 onEnable。 */
  lastActive = false;
  /** 便捷：组件类型（来自 schema，避免两处写）。 */
  get type() {
    return this.schema.type;
  }
  onAttach() {
  }
  onDetach() {
  }
  onEnable() {
  }
  onDisable() {
  }
  onUpdate(_tick, _dt) {
  }
  /** 通用保存：按 schema 逐字段取。**顺序由 schema 决定**（字节确定）。 */
  save() {
    const out = { type: this.schema.type };
    for (const k of Object.keys(this.schema.fields)) {
      const v = this[k];
      out[k] = v === void 0 ? zeroValue(this.schema.fields[k]) : v;
    }
    return out;
  }
  /**
   * 通用读取。**缺字段时保留实例上的值**（类初始化器就是这个字段的出生默认值），
   * 同时把缺失的字段名报告给调用方（AssetDatabase / 存档）判断"是不是旧版本"。
   *
   * ★★ 为什么不是"缺字段填类型零值"（这是被一条真判据逼出来的改动）：
   *   schema 演化时唯一可能正确的默认值写在**类的初始化器**里
   *   （`pivotX = 0.5`）。压成零值的话，旧存档读回来 `pivotX = 0` ——
   *   所有已有精灵右移半格，而**新存档完全正常**，所以新写的判据一个都不会红。
   *   这类错误只在"用户打开旧档"时出现，也就是永远不会在开发机上出现。
   *   实测：`Sprite.pivotX` 加进来的当天，这一条就抓到了（world-visuals 的旧档判据）。
   *
   * 顺序：实例已有值 → `schema.defaults`（显式声明的默认值） → 类型零值（字段压根没声明）。
   */
  load(data) {
    const missing = [];
    const self = this;
    for (const [k, t] of Object.entries(this.schema.fields)) {
      if (data[k] === void 0) {
        missing.push(k);
        if (self[k] !== void 0) continue;
        self[k] = this.schema.defaults?.[k] ?? zeroValue(t);
        continue;
      }
      self[k] = data[k];
    }
    return { missing };
  }
  /** 场景内部：由 Scene 调用，管理 onEnable/onDisable 的边沿。 */
  _setActive(active) {
    if (active === this.lastActive) return;
    this.lastActive = active;
    if (active) this.onEnable();
    else this.onDisable();
  }
  get isActive() {
    return this.lastActive;
  }
};
function isFastForwardable(c) {
  return typeof c.onFastForward === "function";
}
var ComponentRegistry = class {
  factories = /* @__PURE__ */ new Map();
  schemas = /* @__PURE__ */ new Map();
  register(schema, factory) {
    if (this.factories.has(schema.type)) {
      throw new Error(`\u7EC4\u4EF6\u7C7B\u578B ${schema.type} \u5DF2\u6CE8\u518C\uFF08\u540C\u7C7B\u578B\u4E0D\u5141\u8BB8\u91CD\u590D\u6CE8\u518C\uFF09`);
    }
    this.factories.set(schema.type, factory);
    this.schemas.set(schema.type, schema);
  }
  create(type) {
    return this.factories.get(type)?.();
  }
  schemaOf(type) {
    return this.schemas.get(type);
  }
  has(type) {
    return this.factories.has(type);
  }
  types() {
    return Array.from(this.factories.keys()).sort();
  }
};

// src/foundation/math/vec.ts
var Vec2 = class _Vec2 {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
  static zero = new _Vec2(0, 0);
  static one = new _Vec2(1, 1);
  static up = new _Vec2(0, 1);
  static right = new _Vec2(1, 0);
  add(v) {
    return new _Vec2(this.x + v.x, this.y + v.y);
  }
  sub(v) {
    return new _Vec2(this.x - v.x, this.y - v.y);
  }
  scale(s) {
    return new _Vec2(this.x * s, this.y * s);
  }
  dot(v) {
    return this.x * v.x + this.y * v.y;
  }
  /** 二维叉积（标量），用于判定左右与三角形朝向。 */
  cross(v) {
    return this.x * v.y - this.y * v.x;
  }
  get lengthSq() {
    return this.x * this.x + this.y * this.y;
  }
  get length() {
    return Math.sqrt(this.lengthSq);
  }
  /** 零向量归一化返回零向量，不产生 NaN。 */
  normalized() {
    const l = this.length;
    return l > 0 ? new _Vec2(this.x / l, this.y / l) : _Vec2.zero;
  }
  equals(v, eps = 0) {
    return Math.abs(this.x - v.x) <= eps && Math.abs(this.y - v.y) <= eps;
  }
  toString() {
    return `(${this.x}, ${this.y})`;
  }
};
var Vec3 = class _Vec3 {
  constructor(x, y, z) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
  static zero = new _Vec3(0, 0, 0);
  static one = new _Vec3(1, 1, 1);
  add(v) {
    return new _Vec3(this.x + v.x, this.y + v.y, this.z + v.z);
  }
  sub(v) {
    return new _Vec3(this.x - v.x, this.y - v.y, this.z - v.z);
  }
  scale(s) {
    return new _Vec3(this.x * s, this.y * s, this.z * s);
  }
  dot(v) {
    return this.x * v.x + this.y * v.y + this.z * v.z;
  }
  cross(v) {
    return new _Vec3(
      this.y * v.z - this.z * v.y,
      this.z * v.x - this.x * v.z,
      this.x * v.y - this.y * v.x
    );
  }
  get lengthSq() {
    return this.x * this.x + this.y * this.y + this.z * this.z;
  }
  get length() {
    return Math.sqrt(this.lengthSq);
  }
  normalized() {
    const l = this.length;
    return l > 0 ? new _Vec3(this.x / l, this.y / l, this.z / l) : _Vec3.zero;
  }
  /** 取 XZ 平面（2.5D 里"地面"就是 XZ）。 */
  toXZ() {
    return new Vec2(this.x, this.z);
  }
  toString() {
    return `(${this.x}, ${this.y}, ${this.z})`;
  }
};

// src/foundation/math/geometry.ts
var Rect = class _Rect {
  constructor(x, y, width, height) {
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }
  static zero = new _Rect(0, 0, 0, 0);
  get xMin() {
    return this.x;
  }
  get yMin() {
    return this.y;
  }
  get xMax() {
    return this.x + this.width;
  }
  get yMax() {
    return this.y + this.height;
  }
  get center() {
    return new Vec2(this.x + this.width / 2, this.y + this.height / 2);
  }
  contains(p) {
    return p.x >= this.xMin && p.x <= this.xMax && p.y >= this.yMin && p.y <= this.yMax;
  }
  /** 相交判定用 `<` 而非 `<=`：贴边不算重叠（与 SAT 的严格内部分离一致）。 */
  intersects(o) {
    return this.xMin < o.xMax && this.xMax > o.xMin && this.yMin < o.yMax && this.yMax > o.yMin;
  }
  intersect(o) {
    const x0 = Math.max(this.xMin, o.xMin);
    const y0 = Math.max(this.yMin, o.yMin);
    const x1 = Math.min(this.xMax, o.xMax);
    const y1 = Math.min(this.yMax, o.yMax);
    return new _Rect(x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0));
  }
  expand(by) {
    return new _Rect(this.x - by, this.y - by, this.width + by * 2, this.height + by * 2);
  }
};
var Color = class _Color {
  constructor(r, g, b, a = 1) {
    this.r = r;
    this.g = g;
    this.b = b;
    this.a = a;
  }
  static white = new _Color(1, 1, 1, 1);
  static black = new _Color(0, 0, 0, 1);
  static transparent = new _Color(0, 0, 0, 0);
  /** `0xRRGGBBAA` → Color。资产文件里用得多。 */
  static fromRgba8(rgba) {
    return new _Color(
      (rgba >>> 24 & 255) / 255,
      (rgba >>> 16 & 255) / 255,
      (rgba >>> 8 & 255) / 255,
      (rgba & 255) / 255
    );
  }
  toArray() {
    return [this.r, this.g, this.b, this.a];
  }
};
var Affine2 = class _Affine2 {
  constructor(m00, m01, m02, m10, m11, m12) {
    this.m00 = m00;
    this.m01 = m01;
    this.m02 = m02;
    this.m10 = m10;
    this.m11 = m11;
    this.m12 = m12;
  }
  static identity = new _Affine2(1, 0, 0, 0, 1, 0);
  static fromTrs(pos, rotationRad, scale) {
    const c = Math.cos(rotationRad);
    const s = Math.sin(rotationRad);
    return new _Affine2(c * scale.x, -s * scale.y, pos.x, s * scale.x, c * scale.y, pos.y);
  }
  /** this ∘ o（先应用 o，再应用 this）—— 与父子变换的语义一致。 */
  multiply(o) {
    return new _Affine2(
      this.m00 * o.m00 + this.m01 * o.m10,
      this.m00 * o.m01 + this.m01 * o.m11,
      this.m00 * o.m02 + this.m01 * o.m12 + this.m02,
      this.m10 * o.m00 + this.m11 * o.m10,
      this.m10 * o.m01 + this.m11 * o.m11,
      this.m10 * o.m02 + this.m11 * o.m12 + this.m12
    );
  }
  transformPoint(p) {
    return new Vec2(
      this.m00 * p.x + this.m01 * p.y + this.m02,
      this.m10 * p.x + this.m11 * p.y + this.m12
    );
  }
  /** 展开成 WebGL 需要的 9 元素列主序数组。 */
  toMat3Array(out) {
    const m = out ?? new Float32Array(9);
    m[0] = this.m00;
    m[1] = this.m10;
    m[2] = 0;
    m[3] = this.m01;
    m[4] = this.m11;
    m[5] = 0;
    m[6] = this.m02;
    m[7] = this.m12;
    m[8] = 1;
    return m;
  }
  equals(o, eps = 1e-9) {
    return Math.abs(this.m00 - o.m00) <= eps && Math.abs(this.m01 - o.m01) <= eps && Math.abs(this.m02 - o.m02) <= eps && Math.abs(this.m10 - o.m10) <= eps && Math.abs(this.m11 - o.m11) <= eps && Math.abs(this.m12 - o.m12) <= eps;
  }
};

// src/foundation/math/scalar.ts
var TAU = Math.PI * 2;
function quantize(v, decimals = 3) {
  const f = Math.pow(10, decimals);
  return Math.sign(v) * Math.round(Math.abs(v) * f + 1e-9) / f;
}

// src/foundation/result.ts
function ok(value) {
  return { ok: true, value };
}
function err(error) {
  return { ok: false, error };
}
function engineError(code, message, detail) {
  return detail === void 0 ? { code, message } : { code, message, detail };
}

// src/core/scene/node.ts
var NEXT_NODE_ID = 1;
var Node = class {
  id;
  name;
  parent = null;
  children = [];
  components = [];
  /** 局部变换成分。改它们要调 `markTransformDirty()`（或用 setter）。 */
  localPosition = Vec2.zero;
  localRotation = 0;
  localScale = Vec2.one;
  /** 层级顺序微调（同一父下 `zIndex` 大的后画）。 */
  zIndex = 0;
  /** 整棵子树的开关：`false` 时组件不更新、不渲染。 */
  active = true;
  /** 渲染层（编辑器可以按层隐藏）。 */
  layer = 0;
  /** 变换版本：任何影响世界变换的改动都 +1。 */
  version = 0;
  cacheVersion = -1;
  cachedWorld = Affine2.identity;
  destroyed = false;
  constructor(name = "Node", id) {
    this.id = id ?? NEXT_NODE_ID++;
    if (id !== void 0) NEXT_NODE_ID = Math.max(NEXT_NODE_ID, id + 1);
    this.name = name;
  }
  get isDestroyed() {
    return this.destroyed;
  }
  addChild(child) {
    if (child.parent === this) return this;
    child.parent?.removeChild(child);
    child.parent = this;
    this.children.push(child);
    child.markTransformDirty();
    return this;
  }
  removeChild(child) {
    const i = this.children.indexOf(child);
    if (i < 0) return false;
    this.children.splice(i, 1);
    child.parent = null;
    child.markTransformDirty();
    return true;
  }
  attach(c) {
    if (c.node === this) return;
    c.node?.detach(c);
    c.node = this;
    this.components.push(c);
    c.onAttach();
  }
  detach(c) {
    const i = this.components.indexOf(c);
    if (i < 0) return false;
    if (c.isActive) c._setActive(false);
    this.components.splice(i, 1);
    c.node = null;
    c.onDetach();
    return true;
  }
  get(type) {
    for (const c of this.components) if (c.type === type) return c;
    return void 0;
  }
  /** 世界变换（惰性 + 版本缓存）。 */
  get worldTransform() {
    if (this.cacheVersion === this.version) return this.cachedWorld;
    const local = Affine2.fromTrs(this.localPosition, this.localRotation, this.localScale);
    const w = this.parent === null ? local : this.parent.worldTransform.multiply(local);
    this.cachedWorld = w;
    this.cacheVersion = this.version;
    return w;
  }
  get worldPosition() {
    return this.worldTransform.transformPoint(Vec2.zero);
  }
  setLocalPosition(x, y) {
    this.localPosition = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }
  /** ★ 一律用 setter：直接赋 `localScale` 字段**不会**推进版本号 ⇒ 世界变换用旧缓存。 */
  setLocalScale(x, y) {
    this.localScale = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }
  setLocalRotation(rad) {
    this.localRotation = rad;
    this.markTransformDirty();
    return this;
  }
  /** 标脏：自己 + 整棵子树（子节点的世界变换都依赖我）。 */
  markTransformDirty() {
    this.version++;
    for (const c of this.children) c.markTransformDirty();
  }
  /** 是否在整条祖先链上都 active。 */
  get activeInHierarchy() {
    let n = this;
    while (n !== null) {
      if (!n.active) return false;
      n = n.parent;
    }
    return true;
  }
  /** 深度优先遍历（顺序**确定**：子节点按添加顺序）。 */
  walk(fn) {
    fn(this);
    for (const c of this.children) c.walk(fn);
  }
  /** 从根到自己的路径（诊断/日志用）。 */
  path() {
    const parts = [];
    let n = this;
    while (n !== null) {
      parts.unshift(n.name);
      n = n.parent;
    }
    return "/" + parts.join("/");
  }
  /** 内部：销毁时标记，避免使用已销毁节点。 */
  _markDestroyed() {
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
};

// src/core/scene/scene.ts
var Scene = class {
  name;
  root;
  byId = /* @__PURE__ */ new Map();
  /** 类型 → 组件集合。用数组而非 Set：遍历要顺序稳定且可索引。 */
  byType = /* @__PURE__ */ new Map();
  /** 类型更新顺序：按首次注册的稳定序（不是节点顺序）。 */
  typeOrder = [];
  pending = [];
  _steps = 0;
  _updates = 0;
  _fastForwarded = 0;
  /**
   * 本世界的节点 id 分配器（root 固定 1，新节点从 2 起）。
   *
   * ★★ 为什么**不能**用模块级全局自增（阶段 2 改的）：
   *   `Node` 原本有个进程级 `NEXT_NODE_ID`，于是第二个 `Scene` 的第一个节点是 3。
   *   后果比"id 不好看"严重得多：
   *     · **存档不可比** —— 同种子同操作的两个世界，存档只差 id，逐字节比对永远失败
   *       （脚本层出口判据就是这么抓到的）；
   *     · **PIE 两个世界**（编辑器 + 预览）的 id 交错，粘贴一个 prefab 过去会撞 id；
   *     · 回放时 id 依赖"这台机器之前跑过什么"。
   *   每个世界自己的 id 空间反而是**更强**的性质：存档可以跨世界互换。
   *   `Node` 的全局分配器保留给"游离节点"（判据、编辑器里还没入场景的对象）。
   */
  nextId = 2;
  allocateId(explicit) {
    if (explicit !== void 0) {
      if (explicit >= this.nextId) this.nextId = explicit + 1;
      return explicit;
    }
    return this.nextId++;
  }
  /** 组件注册表：编辑器"可挂哪些组件"、读档"遇到未知类型找谁"都读它。 */
  components;
  constructor(name, components) {
    this.components = components;
    this.name = name;
    this.root = new Node("__root__", 1);
    this.byId.set(this.root.id, this.root);
  }
  // ---------------------------------------------------------------- 查询
  get rootId() {
    return this.root.id;
  }
  find(id) {
    return this.byId.get(id);
  }
  /** 按类型取全部组件（返回内部数组，**只读用**；要改请走命令）。 */
  componentsOf(type) {
    return this.byType.get(type) ?? [];
  }
  countOf(type) {
    return this.byType.get(type)?.length ?? 0;
  }
  // ---------------------------------------------------------------- 结构性修改（排队）
  spawn(name, parent = this.root.id, id) {
    const nid = this.allocateId(id);
    if (this.byId.has(nid)) {
      return err({ code: "SCENE.DUPLICATE_ID", message: `\u8282\u70B9 id ${nid} \u5DF2\u5B58\u5728` });
    }
    const node = new Node(name, nid);
    this.pending.push({ kind: "spawn", node, parent });
    return ok(node);
  }
  /** 立即建好（加载/编辑器用）。**游戏逻辑里请用 spawn（走队列）**。 */
  spawnImmediate(name, parent = this.root.id, id) {
    const node = new Node(name, this.allocateId(id));
    this.attachNodeTo(node, parent);
    return node;
  }
  destroy(id) {
    this.pending.push({ kind: "destroy", node: id });
  }
  attach(nodeId, make) {
    const c = make();
    if (!this.components.has(c.type)) {
      return err({
        code: "SCENE.UNKNOWN_COMPONENT",
        message: `\u7EC4\u4EF6\u7C7B\u578B ${c.type} \u672A\u6CE8\u518C\uFF08\u5148 components.register\uFF09`
      });
    }
    this.pending.push({ kind: "attach", node: nodeId, component: c });
    return ok(c);
  }
  detach(nodeId, type) {
    this.pending.push({ kind: "detach", node: nodeId, type });
  }
  reparent(nodeId, newParent) {
    this.pending.push({ kind: "reparent", node: nodeId, parent: newParent });
  }
  /** 排队一个任意回调（在同一处 flush 执行 ⇒ 顺序确定）。 */
  enqueue(fn, label = "custom") {
    this.pending.push({ kind: "run", fn, label });
  }
  get pendingCount() {
    return this.pending.length;
  }
  /**
   * 执行排队命令。
   * ★ 用**队列置换**而不是边遍历边 shift：命令里可能再 spawn（入新队列），
   *   那样本帧不会无限膨胀，且顺序严格按投递序。
   */
  flush() {
    if (this.pending.length === 0) return 0;
    const run2 = this.pending;
    this.pending = [];
    let n = 0;
    for (const cmd of run2) {
      switch (cmd.kind) {
        case "spawn":
          if (!cmd.node.isDestroyed) this.attachNodeTo(cmd.node, cmd.parent);
          break;
        case "destroy": {
          const node = this.byId.get(cmd.node);
          if (node !== void 0 && node.parent !== null) this.detachNode(node, true);
          break;
        }
        case "attach": {
          const node = this.byId.get(cmd.node);
          if (node !== void 0) this.attachTo(node, cmd.component);
          break;
        }
        case "detach": {
          const node = this.byId.get(cmd.node);
          const c = node?.get(cmd.type);
          if (node !== void 0 && c !== void 0) this.detachFrom(node, c);
          break;
        }
        case "reparent": {
          const node = this.byId.get(cmd.node);
          const parent = cmd.parent === null ? this.root : this.byId.get(cmd.parent);
          if (node !== void 0 && parent !== void 0) {
            parent.addChild(node);
            node.markTransformDirty();
          }
          break;
        }
        case "run":
          cmd.fn();
          break;
      }
      n++;
    }
    return n;
  }
  // ---------------------------------------------------------------- 步进
  /**
   * 推进一个固定步。
   * 顺序：flush（结构命令）→ 逐类型更新组件 → 再 flush（更新期投递的命令）
   * 两次 flush 是必须的：更新里投递的"销毁自己"不该延迟到下一帧。
   */
  step(tick, dt) {
    this.flush();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === void 0 || list.length === 0) continue;
      const n = list.length;
      for (let i = 0; i < n; i++) {
        const c = list[i];
        if (c === void 0 || c.node === null) continue;
        const active = c.enabled && c.node.activeInHierarchy;
        c._setActive(active);
        if (active) {
          c.onUpdate(tick, dt);
          this._updates++;
        }
      }
    }
    this.flush();
    this._steps++;
  }
  /**
   * 跳时间结算（`LongUpdate` 语义）。
   *
   * 场景：存档 → 离线 8 小时 → 读档。不能真的跑 864000 个 tick，
   * 所以让**实现了 `IFastForwardable` 的组件**按解析式结算 elapsed 秒。
   *
   * ★ 关键设计：**报告跳过了多少**。没实现该接口的组件（例如 AI、
   *   状态机）在跳过的时段里"什么都没发生" —— 这必须是一个**可见的事实**，
   *   而不是"看起来读档成功了"。调用方据此决定"要不要改成循环 step"。
   */
  fastForward(elapsedSec) {
    if (!(elapsedSec >= 0)) {
      throw new RangeError(`fastForward \u4E0D\u63A5\u53D7\u8D1F\u7684 elapsed\uFF1A${elapsedSec}`);
    }
    let handled = 0;
    let skipped = 0;
    const skippedByType = /* @__PURE__ */ new Map();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === void 0) continue;
      for (const c of list) {
        if (c.node === null) continue;
        if (isFastForwardable(c)) {
          c.onFastForward(elapsedSec);
          handled++;
        } else {
          skipped++;
          skippedByType.set(type, (skippedByType.get(type) ?? 0) + 1);
        }
      }
    }
    this._fastForwarded += elapsedSec;
    return { elapsed: elapsedSec, handled, skipped, skippedByType };
  }
  /** 累计跳过的秒数（诊断：用来判断"这个存档是不是被跳过太多次"）。 */
  get totalFastForwarded() {
    return this._fastForwarded;
  }
  // ---------------------------------------------------------------- 内部
  attachNodeTo(node, parentId) {
    const parent = parentId === null ? this.root : this.byId.get(parentId);
    if (parent === void 0) {
      throw new Error(`spawn \u7684\u7236\u8282\u70B9 ${parentId} \u4E0D\u5B58\u5728\uFF08\u547D\u4EE4\u5DF2\u5165\u961F\uFF0C\u7236\u8282\u70B9\u53EF\u80FD\u5DF2\u88AB\u9500\u6BC1\uFF09`);
    }
    parent.addChild(node);
    node.walk((n) => {
      this.byId.set(n.id, n);
      for (const c of n.components) this.indexComponent(c);
    });
  }
  attachTo(node, c) {
    node.attach(c);
    this.indexComponent(c);
  }
  detachFrom(node, c) {
    this.unindexComponent(c);
    node.detach(c);
  }
  detachNode(node, recursive) {
    node.parent?.removeChild(node);
    node.walk((n) => {
      for (const c of [...n.components]) this.unindexComponent(c);
      this.byId.delete(n.id);
    });
    if (recursive) node._markDestroyed();
  }
  indexComponent(c) {
    let list = this.byType.get(c.type);
    if (list === void 0) {
      list = [];
      this.byType.set(c.type, list);
      this.typeOrder.push(c.type);
    }
    list.push(c);
  }
  unindexComponent(c) {
    const list = this.byType.get(c.type);
    if (list === void 0) return;
    const i = list.indexOf(c);
    if (i >= 0) list.splice(i, 1);
  }
  stats() {
    let comps = 0;
    for (const l of this.byType.values()) comps += l.length;
    return {
      nodes: this.byId.size,
      components: comps,
      pendingCommands: this.pending.length,
      stepsRun: this._steps,
      componentUpdates: this._updates
    };
  }
  /** 清空（切场景/读档前）。不走命令 —— 它的语义就是"立刻什么都没了"。 */
  clear() {
    for (const child of [...this.root.children]) {
      this.detachNode(child, true);
    }
    this.pending = [];
  }
  /** 新建一个带标准变换的节点（便捷）。 */
  spawnAt(name, x, z, parent = this.root.id) {
    const r = this.spawn(name, parent);
    if (r.ok) r.value.setLocalPosition(x, z);
    return r;
  }
  /** 世界坐标（便利方法，供 2.5D 用）。 */
  worldPositionOf(id) {
    return this.byId.get(id)?.worldPosition;
  }
};

// src/core/serialization/schema.ts
var Schema = class {
  version;
  fields;
  versionKey;
  migrations;
  decimals;
  constructor(opts) {
    this.version = opts.version;
    this.fields = opts.fields;
    this.versionKey = opts.versionKey ?? "__v";
    this.migrations = opts.migrations ?? [];
    this.decimals = opts.decimals ?? 3;
    const froms = this.migrations.map((m) => m.from).sort((a, b) => a - b);
    for (let i = 0; i < froms.length; i++) {
      if (froms[i] !== i + 1) {
        throw new Error(
          `\u8FC1\u79FB\u94FE\u5FC5\u987B\u4ECE v1 \u8FDE\u7EED\u8986\u76D6\u5230 v${this.version}\uFF0C\u5B9E\u9645\u7F3A v${i + 1}\uFF08\u5DF2\u6709\uFF1A${froms.join(",") || "\u65E0"}\uFF09`
        );
      }
    }
    const need = this.version - 1;
    if (froms.length !== need) {
      throw new Error(
        `v${this.version} \u9700\u8981 ${need} \u6761\u8FC1\u79FB\uFF08v1\u2192v2 \u2026 v${need}\u2192v${this.version}\uFF09\uFF0C\u5B9E\u9645 ${froms.length} \u6761\uFF08\u5DF2\u6709\uFF1A${froms.join(",") || "\u65E0"}\uFF09`
      );
    }
  }
  /** 把任意旧版本的记录迁到当前版本。 */
  migrate(data) {
    let cur = { ...data };
    const raw = cur[this.versionKey];
    const declared = Object.prototype.hasOwnProperty.call(cur, this.versionKey);
    let v = 1;
    if (declared) {
      if (typeof raw !== "number") {
        return err({
          code: "SER.BAD_VERSION",
          message: `\u7248\u672C\u5B57\u6BB5 ${this.versionKey}=${JSON.stringify(raw)} \u4E0D\u662F\u6570\u5B57\uFF08\u5B58\u6863\u5934\u635F\u574F\uFF09`
        });
      }
      v = raw;
    }
    if (!Number.isInteger(v) || v < 1) {
      return err({
        code: "SER.BAD_VERSION",
        message: `\u7248\u672C\u5B57\u6BB5 ${this.versionKey}=${JSON.stringify(raw)} \u4E0D\u662F \u22651 \u7684\u6574\u6570\uFF08\u5B58\u6863\u5934\u635F\u574F\uFF09`
      });
    }
    if (v > this.version) {
      return err({
        code: "SER.VERSION_TOO_NEW",
        message: `\u8BB0\u5F55\u7248\u672C v${v} \u9AD8\u4E8E\u5F15\u64CE\u652F\u6301\u7684 v${this.version}\uFF08\u7528\u65B0\u5F15\u64CE\u5199\u7684\u6863\uFF0C\u65E7\u5F15\u64CE\u4E0D\u80FD\u8BFB\uFF09`
      });
    }
    while (v < this.version) {
      const m = this.migrations.find((x) => x.from === v);
      if (m === void 0) {
        return err({
          code: "SER.NO_MIGRATION",
          message: `\u7F3A\u5C11 v${v} \u2192 v${v + 1} \u7684\u8FC1\u79FB\u51FD\u6570`
        });
      }
      cur = m.migrate(cur);
      v++;
      cur[this.versionKey] = v;
    }
    return ok(cur);
  }
  /**
   * 确定性序列化：`{ "__v": 2, "name": "abc", "hp": 12.346 }`
   * - 字段顺序 = schema 顺序（**不是**对象键顺序）
   * - 数字量化到 decimals
   * - schema 里没有的键**丢弃并报告**（不静默保留：保留会让"字段名拼错"变成永久脏数据）
   */
  encode(data) {
    const dropped = Object.keys(data).filter((k) => k !== this.versionKey && !this.fields.includes(k));
    const parts = [`${JSON.stringify(this.versionKey)}:${this.version}`];
    for (const k of this.fields) {
      const v = data[k];
      if (v === void 0) continue;
      parts.push(`${JSON.stringify(k)}:${encodeValue(v, this.decimals)}`);
    }
    return { text: `{${parts.join(",")}}`, dropped };
  }
  decode(text) {
    let raw;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      return err({
        code: "SER.BAD_JSON",
        message: `\u4E0D\u662F\u5408\u6CD5 JSON\uFF1A${e instanceof Error ? e.message : String(e)}`
      });
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      return err({ code: "SER.NOT_OBJECT", message: "\u9876\u5C42\u5FC5\u987B\u662F\u5BF9\u8C61" });
    }
    return this.migrate(raw);
  }
};
function encodeValue(v, decimals) {
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      return JSON.stringify(`__num__:${String(v)}`);
    }
    return String(quantize(v, decimals));
  }
  if (typeof v === "string" || typeof v === "boolean") return JSON.stringify(v);
  if (v === null) return "null";
  if (Array.isArray(v)) return "[" + v.map((x) => encodeValue(x, decimals)).join(",") + "]";
  if (typeof v === "object") {
    const o = v;
    const keys = Object.keys(o).sort();
    const body = [];
    for (const k of keys) {
      if (o[k] === void 0) continue;
      body.push(`${JSON.stringify(k)}:${encodeValue(o[k], decimals)}`);
    }
    return "{" + body.join(",") + "}";
  }
  return JSON.stringify(String(v));
}

// src/core/scene/scene-io.ts
var SCENE_FORMAT_VERSION = 1;
function collectNodes(scene) {
  const out = [];
  scene.root.walk((n) => {
    if (n.id !== scene.rootId) out.push(n);
  });
  out.sort((a, b) => a.id - b.id);
  return out;
}
function saveScene(scene) {
  const nodes = [];
  for (const n of collectNodes(scene)) {
    const comps = [];
    for (const c of [...n.components].sort((a, b) => a.type < b.type ? -1 : a.type > b.type ? 1 : 0)) {
      const saved = c.save();
      const { type: _t, ...rest } = saved;
      comps.push({ type: c.type, data: rest });
    }
    nodes.push({
      id: n.id,
      name: n.name,
      parent: n.parent === null || n.parent.id === scene.rootId ? null : n.parent.id,
      x: n.localPosition.x,
      y: n.localPosition.y,
      rot: n.localRotation,
      sx: n.localScale.x,
      sy: n.localScale.y,
      zIndex: n.zIndex,
      active: n.active,
      layer: n.layer,
      components: comps
    });
  }
  return { format: SCENE_FORMAT_VERSION, name: scene.name, nodes };
}
function sceneToJson(snap) {
  const lines = [];
  lines.push(`{"format":${snap.format},"name":${JSON.stringify(snap.name)},"nodes":[`);
  snap.nodes.forEach((n, i) => {
    const comps = n.components.map((c) => `{"type":${JSON.stringify(c.type)},"data":${stringifySorted(c.data)}}`).join(",");
    const rec = `{"id":${n.id},"name":${JSON.stringify(n.name)},"parent":${n.parent === null ? "null" : n.parent},"x":${q(n.x)},"y":${q(n.y)},"rot":${q(n.rot)},"sx":${q(n.sx)},"sy":${q(n.sy)},"zIndex":${n.zIndex},"active":${n.active},"layer":${n.layer},"components":[${comps}]}`;
    lines.push(rec + (i === snap.nodes.length - 1 ? "" : ","));
  });
  lines.push("]}");
  return lines.join("");
}
var SAVE_SCALE = 1e9;
var SAVE_SCALE_LIMIT = 1e6;
function q(v) {
  if (!Number.isFinite(v)) return v;
  if (!(Math.abs(v) < SAVE_SCALE_LIMIT)) return v;
  return Math.round(v * SAVE_SCALE) / SAVE_SCALE;
}
function stringifySorted(o) {
  if (o === null || typeof o !== "object") {
    return typeof o === "number" ? String(q(o)) : JSON.stringify(o);
  }
  if (Array.isArray(o)) return "[" + o.map(stringifySorted).join(",") + "]";
  const rec = o;
  const keys = Object.keys(rec).sort();
  const parts = [];
  for (const k of keys) {
    if (rec[k] === void 0) continue;
    parts.push(`${JSON.stringify(k)}:${stringifySorted(rec[k])}`);
  }
  return "{" + parts.join(",") + "}";
}
var SCENE_SCHEMA = new Schema({
  version: SCENE_FORMAT_VERSION,
  fields: ["name", "nodes"],
  versionKey: "format"
});

// src/core/module/services.ts
function defineService(key) {
  return { key };
}
var ServiceRegistry = class {
  map = /* @__PURE__ */ new Map();
  owner = /* @__PURE__ */ new Map();
  /**
   * 注册服务。`ownerId` 只用于诊断（"这个服务是谁提供的"）。
   * 重复注册直接抛：静默覆盖会让"到底注入的是哪个"变成运气。
   */
  provide(token, impl, ownerId = "unknown") {
    if (this.map.has(token)) {
      throw new Error(
        `\u670D\u52A1 ${token.key} \u5DF2\u88AB ${this.owner.get(token)} \u63D0\u4F9B\uFF0C${ownerId} \u4E0D\u80FD\u91CD\u590D\u63D0\u4F9B\uFF08\u8981\u66FF\u6362\u8BF7\u5148 revoke\uFF0C\u5BBF\u4E3B\u7EC4\u88C5\u9636\u6BB5\u624D\u5141\u8BB8\u66FF\u6362\uFF09`
      );
    }
    this.map.set(token, impl);
    this.owner.set(token, ownerId);
  }
  /** 供宿主在测试/热替换时显式撤销。 */
  revoke(token) {
    this.map.delete(token);
    this.owner.delete(token);
  }
  /** 可选取：没有就 undefined（软依赖用它）。 */
  get(token) {
    return this.map.get(token);
  }
  /** 必需取：没有就抛，并在错误里列出当前已提供的服务（便于一眼看出拼错）。 */
  require(token) {
    const v = this.map.get(token);
    if (v === void 0) {
      throw new Error(
        `\u7F3A\u5C11\u5FC5\u9700\u670D\u52A1 ${token.key}\u3002\u5DF2\u63D0\u4F9B\uFF1A${Array.from(this.map.keys()).map((t) => t.key).sort().join(", ") || "(\u7A7A)"}`
      );
    }
    return v;
  }
  has(token) {
    return this.map.has(token);
  }
  describe() {
    return Array.from(this.map.keys()).map((t) => ({ key: t.key, owner: this.owner.get(t) ?? "?" })).sort((a, b) => a.key.localeCompare(b.key));
  }
  dispose() {
    this.map.clear();
    this.owner.clear();
  }
};

// src/foundation/event/event-bus.ts
var EventBus = class {
  listeners = /* @__PURE__ */ new Map();
  emitted = 0;
  listenerErrors = 0;
  lastError = null;
  /** 错误回调：默认什么都不做，由宿主接到 logger 上（L0 不依赖具体 logger 实例，避免全局单例）。 */
  onListenerError = null;
  on(topic, fn) {
    let set = this.listeners.get(topic);
    if (set === void 0) {
      set = /* @__PURE__ */ new Set();
      this.listeners.set(topic, set);
    }
    set.add(fn);
    return () => {
      set.delete(fn);
    };
  }
  once(topic, fn) {
    const off = this.on(topic, (p) => {
      off();
      fn(p);
    });
    return off;
  }
  emit(topic, payload) {
    this.emitted++;
    const set = this.listeners.get(topic);
    if (set === void 0 || set.size === 0) return;
    const snapshot = Array.from(set);
    for (const fn of snapshot) {
      try {
        fn(payload);
      } catch (e) {
        this.listenerErrors++;
        this.lastError = e instanceof Error ? e.message : String(e);
        this.onListenerError?.(topic, e);
      }
    }
  }
  listenerCount(topic) {
    return this.listeners.get(topic)?.size ?? 0;
  }
  /** 清空所有订阅。宿主 dispose 时调用，避免模块卸载后仍被事件引用。 */
  clear() {
    this.listeners.clear();
  }
  stats() {
    return {
      emitted: this.emitted,
      listenerErrors: this.listenerErrors,
      lastError: this.lastError
    };
  }
};

// src/foundation/log/logger.ts
var LogLevel = {
  Trace: 10,
  Debug: 20,
  Info: 30,
  Warn: 40,
  Error: 50,
  Off: 100
};
var DEFAULT_LIMIT = { maxPerWindow: 5, windowMs: 1e3 };
var Logger = class {
  constructor(now = () => Date.now()) {
    this.now = now;
  }
  sinks = [];
  channelLevel = /* @__PURE__ */ new Map();
  limiters = /* @__PURE__ */ new Map();
  defaultLevel = LogLevel.Info;
  addSink(sink) {
    this.sinks.push(sink);
  }
  setLevel(level, channel) {
    if (channel === void 0) this.defaultLevel = level;
    else this.channelLevel.set(channel, level);
  }
  levelOf(channel) {
    return this.channelLevel.get(channel) ?? this.defaultLevel;
  }
  /**
   * 取一个通道的 logger。
   * ★ 通道名用 `点分层`（`gfx.webgl2` / `asset.registry`），这样"给 gfx 全开 debug"
   *   可以用前缀匹配（见 `setLevelPrefix`），不需要一处一处改。
   */
  channel(name) {
    return new ChannelLogger(this, name);
  }
  setLevelPrefix(prefix, level) {
    this.channelLevel.set(prefix.endsWith("*") ? prefix : prefix + "*", level);
  }
  log(level, channel, message, fields, limit) {
    const lv = this.levelOf(channel);
    if (level < lv || lv >= LogLevel.Off) return;
    let suppressed = 0;
    if (limit) {
      const key = channel + "\0" + message;
      const t = this.now();
      const st = this.limiters.get(key);
      if (st === void 0 || t - st.windowStart >= limit.windowMs) {
        suppressed = st ? st.folded : 0;
        this.limiters.set(key, { windowStart: t, count: 1, folded: 0 });
      } else {
        st.count++;
        if (st.count > limit.maxPerWindow) {
          st.folded++;
          return;
        }
      }
    }
    const rec = {
      t: this.now(),
      level,
      channel,
      message,
      ...fields === void 0 ? {} : { fields },
      suppressed
    };
    for (const s of this.sinks) s.write(rec);
  }
  flush() {
    for (const s of this.sinks) s.flush?.();
  }
};
var ChannelLogger = class {
  constructor(root, name) {
    this.root = root;
    this.name = name;
  }
  trace(msg, fields) {
    this.root.log(LogLevel.Trace, this.name, msg, fields);
  }
  debug(msg, fields) {
    this.root.log(LogLevel.Debug, this.name, msg, fields);
  }
  info(msg, fields) {
    this.root.log(LogLevel.Info, this.name, msg, fields);
  }
  warn(msg, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Warn, this.name, msg, fields, limit);
  }
  error(msg, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Error, this.name, msg, fields, limit);
  }
};

// src/foundation/random.ts
var XorShift128 = class {
  s0;
  s1;
  constructor(seed) {
    let x = seed | 0 || 2654435769;
    const next = () => {
      x = x + 2654435769 | 0;
      let z = x;
      z = Math.imul(z ^ z >>> 16, 2246822507);
      z = Math.imul(z ^ z >>> 13, 3266489909);
      return (z ^ z >>> 16) >>> 0;
    };
    this.s0 = next() || 1;
    this.s1 = next() || 2;
  }
  /** 32 位 xorshift128，返回 [0, 2^32) */
  nextU32() {
    let x = this.s0;
    const y = this.s1;
    this.s0 = y;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.s1 = x >>> 0;
    return this.s1;
  }
  next() {
    const hi = this.nextU32() >>> 5;
    const lo = this.nextU32() >>> 6;
    return (hi * 67108864 + lo) / 9007199254740992;
  }
  int(lo, hi) {
    if (hi <= lo) return lo;
    return lo + Math.floor(this.next() * (hi - lo));
  }
  range(lo, hi) {
    return lo + this.next() * (hi - lo);
  }
  chance(p) {
    return this.next() < p;
  }
  shuffle(arr) {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = this.int(0, i + 1);
      const t = arr[i];
      arr[i] = arr[j];
      arr[j] = t;
    }
    return arr;
  }
  pick(arr) {
    if (arr.length === 0) return void 0;
    return arr[this.int(0, arr.length)];
  }
  getState() {
    return { s0: this.s0, s1: this.s1 };
  }
  setState(s) {
    if (s.s0 === 0 && s.s1 === 0) throw new RangeError("\u968F\u673A\u72B6\u6001\u4E0D\u80FD\u662F\u5168\u96F6");
    this.s0 = s.s0 >>> 0;
    this.s1 = s.s1 >>> 0;
  }
};

// src/foundation/hash.ts
var FNV_PRIME = 16777619;
var FNV_BASIS_A = 2166136261;
var FNV_BASIS_B = 2654435769;
function hashStateCreate() {
  return { h1: FNV_BASIS_A, h2: FNV_BASIS_B, bytes: 0 };
}
function hashStateUpdate(s, bytes) {
  let h1 = s.h1;
  let h2 = s.h2;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    h1 = Math.imul(h1 ^ b, FNV_PRIME) >>> 0;
    h2 = Math.imul(h2 ^ b, FNV_PRIME) >>> 0;
  }
  s.h1 = h1;
  s.h2 = h2;
  s.bytes += bytes.length;
}
function hex8(n) {
  return (n >>> 0).toString(16).padStart(8, "0");
}
function hashStateHex(s) {
  return hex8(s.h1) + hex8(s.h2);
}
function hashBytes(bytes) {
  const s = hashStateCreate();
  hashStateUpdate(s, bytes);
  return hashStateHex(s);
}
function hashText(s) {
  return hashBytes(new TextEncoder().encode(s));
}

// src/foundation/canonical.ts
var CANON_NOT_INTEGER = "CANON.NOT_INTEGER";
var CANON_NOT_FINITE = "CANON.NOT_FINITE";
var CANON_TOO_LARGE = "CANON.TOO_LARGE";
var CANON_NULL = "CANON.NULL";
var CANON_UNSUPPORTED = "CANON.UNSUPPORTED";
function bad(code, path, extra) {
  return err({
    code,
    message: `${path} ${extra} \u2014\u2014 \u5185\u5BB9\u6307\u7EB9\u8981\u6C42"\u540C\u503C\u540C\u4E32"\uFF0C\u8FD9\u7C7B\u503C\u6CA1\u6CD5\u4FDD\u8BC1`,
    detail: { path }
  });
}
function canonicalize(value) {
  return canon(value, "$");
}
function canon(value, path) {
  if (value === null) {
    return bad(CANON_NULL, path, "\u662F null\uFF08\u7F3A\u5B57\u6BB5\u5C31\u522B\u5199\u8FD9\u4E2A\u952E\uFF0C\u4E0D\u8981\u5199 null\uFF09");
  }
  if (value === void 0) {
    return bad(CANON_UNSUPPORTED, path, "\u662F undefined\uFF08JSON \u4F1A\u628A\u5B83\u9759\u9ED8\u4E22\u6389\uFF0C\u6570\u7EC4\u91CC\u8FD8\u4F1A\u53D8 null\uFF09");
  }
  switch (typeof value) {
    case "string":
      return ok(JSON.stringify(value));
    case "boolean":
      return ok(value ? "true" : "false");
    case "number": {
      if (!Number.isFinite(value)) {
        return bad(CANON_NOT_FINITE, path, `\u662F ${String(value)}`);
      }
      if (!Number.isInteger(value)) {
        return bad(CANON_NOT_INTEGER, path, `\u662F\u5C0F\u6570 ${String(value)}\uFF08\u9700\u8981\u5C0F\u6570\u8BF7\u6539\u7528\u5B9A\u70B9\u6574\u6570\uFF09`);
      }
      if (Math.abs(value) > Number.MAX_SAFE_INTEGER) {
        return bad(CANON_TOO_LARGE, path, `\u662F ${String(value)}\uFF0C\u8D85\u51FA\u5B89\u5168\u6574\u6570\u8303\u56F4\uFF08\u6574\u6570\u5DF2\u4E0D\u7CBE\u786E\uFF09`);
      }
      return ok(String(value));
    }
    case "bigint":
    case "function":
    case "symbol":
      return bad(CANON_UNSUPPORTED, path, `\u662F ${typeof value}`);
    default:
      break;
  }
  if (Array.isArray(value)) {
    const parts2 = [];
    for (let i = 0; i < value.length; i++) {
      const r = canon(value[i], `${path}[${String(i)}]`);
      if (!r.ok) return r;
      parts2.push(r.value);
    }
    return ok(`[${parts2.join(",")}]`);
  }
  const proto = Object.getPrototypeOf(value);
  if (proto !== Object.prototype && proto !== null) {
    const name = proto?.constructor?.name;
    return bad(CANON_UNSUPPORTED, path, `\u4E0D\u662F\u7EAF\u5BF9\u8C61\uFF08\u539F\u578B ${String(name)}\uFF09`);
  }
  const rec = value;
  const keys = Object.keys(rec).sort();
  const parts = [];
  for (const k of keys) {
    const r = canon(rec[k], `${path}.${k}`);
    if (!r.ok) return r;
    parts.push(`${JSON.stringify(k)}:${r.value}`);
  }
  return ok(`{${parts.join(",")}}`);
}
function fingerprintOf(value) {
  const c = canonicalize(value);
  if (!c.ok) return c;
  return ok(hashText(c.value));
}

// src/extensions/worldgen/worldgen.ts
var FIXED_UNITS = 256;
var WORLD_PLAN_SCHEMA = 1;
var BIOMES = {
  ocean: { passable: false, sites: [] },
  cliff: { passable: false, sites: [] },
  beach: { passable: true, sites: ["flint", "grass_tuft"] },
  grass: { passable: true, sites: ["tree", "berry", "grass_tuft"] },
  forest: { passable: true, sites: ["tree", "tree", "berry"] },
  savanna: { passable: true, sites: ["grass_tuft", "rock"] },
  marsh: { passable: true, sites: ["reed", "berry"] },
  rocky: { passable: true, sites: ["rock", "flint"] }
};
function isPassable(kind) {
  return BIOMES[kind].passable;
}
function isBiomeKind(value) {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(BIOMES, value);
}
var WORLD_BAD_PARAMS = "WORLD.BAD_PARAMS";
var NOISE_PERIOD = 8;
function mix32(a) {
  let x = a | 0;
  x = Math.imul(x ^ x >>> 16, 2246822507);
  x = Math.imul(x ^ x >>> 13, 3266489909);
  return (x ^ x >>> 16) >>> 0;
}
function latticeValue(seed, lx, lz, channel) {
  const h = mix32(
    (seed | 0) ^ Math.imul(lx, 668265261) ^ Math.imul(lz, 374761393) ^ Math.imul(channel, 2654435761)
  );
  return h % 1024;
}
function noise2(seed, x, z, channel) {
  const g = NOISE_PERIOD;
  const lx = Math.floor(x / g);
  const lz = Math.floor(z / g);
  const dx = x - lx * g;
  const dz = z - lz * g;
  const a = latticeValue(seed, lx, lz, channel);
  const b = latticeValue(seed, lx + 1, lz, channel);
  const c = latticeValue(seed, lx, lz + 1, channel);
  const d = latticeValue(seed, lx + 1, lz + 1, channel);
  const top = a * (g - dx) + b * dx;
  const bot = c * (g - dx) + d * dx;
  return Math.floor((top * (g - dz) + bot * dz) / (g * g));
}
function pickBiome(elevation, moisture) {
  if (elevation < 280) return "ocean";
  if (elevation < 340) return "beach";
  if (elevation >= 900) return "cliff";
  if (elevation >= 780) return "rocky";
  if (moisture < 300) return "savanna";
  if (moisture < 700) return "grass";
  if (moisture < 850) return "forest";
  return "marsh";
}
function cellSeed(seed, cellIndex) {
  return mix32((seed | 0) ^ Math.imul(cellIndex + 1, 2654435761));
}
var NEIGHBORS = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1]
];
function findComponents(width, height, kinds) {
  const total = width * height;
  const regionOf = new Int32Array(total).fill(-1);
  const groups = [];
  const queue = [];
  for (let start = 0; start < total; start++) {
    if (regionOf[start] !== -1) continue;
    if (!isPassable(kinds[start])) continue;
    const id = groups.length;
    const group = [];
    regionOf[start] = id;
    queue.length = 0;
    queue.push(start);
    for (let head = 0; head < queue.length; head++) {
      const cur = queue[head];
      group.push(cur);
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [ox, oz] of NEIGHBORS) {
        const nx = cx + ox;
        const nz = cz + oz;
        if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
        const ni = nz * width + nx;
        if (regionOf[ni] !== -1) continue;
        if (!isPassable(kinds[ni])) continue;
        regionOf[ni] = id;
        queue.push(ni);
      }
    }
    group.sort((p, q2) => p - q2);
    groups.push(group);
  }
  return { regionOf, groups };
}
function lineCells(width, x0, z0, x1, z1) {
  const out = [];
  const dx = Math.abs(x1 - x0);
  const dz = Math.abs(z1 - z0);
  const sx = x0 < x1 ? 1 : -1;
  const sz = z0 < z1 ? 1 : -1;
  let e = dx - dz;
  let x = x0;
  let z = z0;
  for (; ; ) {
    out.push(z * width + x);
    if (x === x1 && z === z1) break;
    const e2 = 2 * e;
    if (e2 > -dz) {
      e -= dz;
      x += sx;
    }
    if (e2 < dx) {
      e += dx;
      z += sz;
    }
  }
  return out;
}
function repairConnectivity(width, height, kinds, bridges) {
  let carved = 0;
  let rounds = 0;
  for (let round = 0; round < 4; round++) {
    const { groups } = findComponents(width, height, kinds);
    if (groups.length <= 1) break;
    rounds++;
    let mainIdx = 0;
    for (let i = 1; i < groups.length; i++) {
      if (groups[i].length > groups[mainIdx].length) mainIdx = i;
    }
    const main = groups[mainIdx];
    let carvedThisRound = 0;
    for (let gi = 0; gi < groups.length; gi++) {
      if (gi === mainIdx) continue;
      const group = groups[gi];
      const source = group[0];
      const sx = source % width;
      const sz = (source - sx) / width;
      let best = -1;
      let bestD = Number.POSITIVE_INFINITY;
      for (const target of main) {
        const tx2 = target % width;
        const tz2 = (target - tx2) / width;
        const d = Math.abs(tx2 - sx) + Math.abs(tz2 - sz);
        if (d < bestD) {
          bestD = d;
          best = target;
        }
      }
      if (best < 0) continue;
      const tx = best % width;
      const tz = (best - tx) / width;
      let carvedHere = 0;
      for (const cell of lineCells(width, sx, sz, tx, tz)) {
        if (isPassable(kinds[cell])) continue;
        kinds[cell] = "beach";
        carvedHere++;
      }
      if (carvedHere > 0) {
        bridges.push({ fromCell: source, toCell: best });
        carvedThisRound += carvedHere;
      }
    }
    carved += carvedThisRound;
    if (carvedThisRound === 0) break;
  }
  return { carved, rounds };
}
function generateWorld(params) {
  const { seed, width, height } = params;
  if (!Number.isInteger(seed)) {
    return err({ code: WORLD_BAD_PARAMS, message: `seed \u5FC5\u987B\u662F\u6574\u6570\uFF0C\u5F97\u5230 ${String(seed)}` });
  }
  if (!Number.isInteger(width) || width < 8 || width > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `width \u5FC5\u987B\u662F 8..128 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(width)}` });
  }
  if (!Number.isInteger(height) || height < 8 || height > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `height \u5FC5\u987B\u662F 8..128 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(height)}` });
  }
  const maxSites = params.maxSitesPerCell ?? 2;
  if (!Number.isInteger(maxSites) || maxSites < 0 || maxSites > 8) {
    return err({ code: WORLD_BAD_PARAMS, message: `maxSitesPerCell \u5FC5\u987B\u662F 0..8 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(maxSites)}` });
  }
  const total = width * height;
  const kinds = new Array(total);
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      const isBorder = x === 0 || z === 0 || x === width - 1 || z === height - 1;
      if (isBorder) {
        kinds[z * width + x] = "ocean";
        continue;
      }
      const elevation = noise2(seed, x, z, 1);
      const moisture = noise2(seed, x, z, 2);
      kinds[z * width + x] = pickBiome(elevation, moisture);
    }
  }
  const bridges = [];
  if (params.repair !== false) {
    repairConnectivity(width, height, kinds, bridges);
  }
  const sites = [];
  for (let cell = 0; cell < total; cell++) {
    const kind = kinds[cell];
    const def = BIOMES[kind];
    if (!def.passable || def.sites.length === 0 || maxSites === 0) continue;
    const rng = new XorShift128(cellSeed(seed, cell));
    const n = rng.int(1, maxSites + 1);
    const cx = cell % width;
    const cz = (cell - cx) / width;
    for (let k = 0; k < n; k++) {
      const siteKind = rng.pick(def.sites);
      if (siteKind === void 0) continue;
      sites.push({
        id: cell * maxSites + k,
        kind: siteKind,
        x: cx * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        z: cz * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        cell
      });
    }
  }
  const partial = {
    schema: WORLD_PLAN_SCHEMA,
    seed,
    width,
    height,
    kinds,
    sites,
    bridges
  };
  const fp = fingerprintOf(partial);
  if (!fp.ok) return fp;
  return ok({
    seed,
    width,
    height,
    kinds,
    sites,
    bridges,
    fingerprint: fp.value
  });
}
function planDigest(plan) {
  return fingerprintOf({
    schema: WORLD_PLAN_SCHEMA,
    seed: plan.seed,
    width: plan.width,
    height: plan.height,
    kinds: plan.kinds,
    sites: plan.sites,
    bridges: plan.bridges
  });
}
var WORLD_NO_SPAWN = "WORLD.NO_SPAWN";
function pickSpawn(plan) {
  const { width, height, kinds } = plan;
  const total = width * height;
  const { regionOf, groups } = findComponents(width, height, kinds);
  let mainIdx = -1;
  let largest = 0;
  for (let i = 0; i < groups.length; i++) {
    const n = groups[i].length;
    if (n > largest) {
      largest = n;
      mainIdx = i;
    }
  }
  if (mainIdx < 0) {
    return err({ code: WORLD_NO_SPAWN, message: "\u6574\u5F20\u56FE\u6CA1\u6709\u53EF\u901A\u884C\u7684\u9646\u5730\uFF08\u5168\u662F\u6D77/\u60AC\u5D16\uFF09\uFF0C\u65E0\u6CD5\u9009\u51FA\u751F\u70B9" });
  }
  const dist = new Int32Array(total).fill(-1);
  const queue = [];
  for (let i = 0; i < total; i++) {
    if (!isPassable(kinds[i])) {
      dist[i] = 0;
      queue.push(i);
    }
  }
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      if (x !== 0 && z !== 0 && x !== width - 1 && z !== height - 1) continue;
      const i = z * width + x;
      if (dist[i] !== -1) continue;
      dist[i] = 1;
      queue.push(i);
    }
  }
  for (let head = 0; head < queue.length; head++) {
    const cur = queue[head];
    const cx = cur % width;
    const cz = (cur - cx) / width;
    const d = dist[cur];
    for (const [ox, oz] of NEIGHBORS) {
      const nx = cx + ox;
      const nz = cz + oz;
      if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
      const ni = nz * width + nx;
      if (dist[ni] !== -1) continue;
      dist[ni] = d + 1;
      queue.push(ni);
    }
  }
  let best = -1;
  let bestDist = -1;
  for (let i = 0; i < total; i++) {
    if (regionOf[i] !== mainIdx) continue;
    const d = dist[i];
    if (d > bestDist) {
      bestDist = d;
      best = i;
    }
  }
  if (best < 0) {
    return err({ code: WORLD_NO_SPAWN, message: `\u4E3B\u5206\u91CF\uFF08${largest} \u683C\uFF09\u91CC\u6CA1\u6709\u53EF\u901A\u884C\u683C` });
  }
  const bx = best % width;
  const bz = (best - bx) / width;
  return ok({
    cell: best,
    x: bx * FIXED_UNITS + FIXED_UNITS / 2,
    z: bz * FIXED_UNITS + FIXED_UNITS / 2,
    clearance: bestDist
  });
}

// src/extensions/worldgen/assemble.ts
var WORLD_BAD_PLAN = "WORLD.BAD_PLAN";
var WORLD_SCENE_NOT_EMPTY = "WORLD.SCENE_NOT_EMPTY";
var WORLD_COMPONENTS_UNREGISTERED = "WORLD.COMPONENTS_UNREGISTERED";
var TERRAIN_TYPE = "world.terrain";
var SITE_TYPE = "world.site";
var TERRAIN_SCHEMA = {
  type: TERRAIN_TYPE,
  fields: {
    kind: FieldType.String,
    /** 矩形左上角格子坐标与尺寸 —— 存的是**格子**，不是世界单位（不引入浮点）。 */
    cx: FieldType.Int,
    cz: FieldType.Int,
    w: FieldType.Int,
    h: FieldType.Int,
    /** 冗余但必要：`passable` 是"能不能走"的**运行时事实**，不只由 kind 推。 */
    passable: FieldType.Bool
  }
};
var SITE_SCHEMA = {
  type: SITE_TYPE,
  fields: {
    siteId: FieldType.Int,
    kind: FieldType.String,
    cell: FieldType.Int
  }
};
var TerrainArea = class extends Component {
  schema = TERRAIN_SCHEMA;
  kind = "ocean";
  cx = 0;
  cz = 0;
  w = 0;
  h = 0;
  passable = false;
};
var SiteMarker = class extends Component {
  schema = SITE_SCHEMA;
  siteId = 0;
  kind = "tree";
  cell = 0;
};
function registerWorldComponents(registry) {
  if (!registry.has(TERRAIN_TYPE)) registry.register(TERRAIN_SCHEMA, () => new TerrainArea());
  if (!registry.has(SITE_TYPE)) registry.register(SITE_SCHEMA, () => new SiteMarker());
}
function mergeTerrain(width, height, kinds) {
  const visited = new Uint8Array(width * height);
  const rects = [];
  for (let cz = 0; cz < height; cz++) {
    for (let cx = 0; cx < width; cx++) {
      const start = cz * width + cx;
      if (visited[start] === 1) continue;
      const kind = kinds[start];
      let w = 1;
      while (cx + w < width) {
        const i = start + w;
        if (visited[i] === 1 || kinds[i] !== kind) break;
        w++;
      }
      let h = 1;
      while (cz + h < height) {
        let sameRow = true;
        for (let dx = 0; dx < w; dx++) {
          const i = (cz + h) * width + cx + dx;
          if (visited[i] === 1 || kinds[i] !== kind) {
            sameRow = false;
            break;
          }
        }
        if (!sameRow) break;
        h++;
      }
      for (let dz = 0; dz < h; dz++) {
        for (let dx = 0; dx < w; dx++) visited[(cz + dz) * width + cx + dx] = 1;
      }
      rects.push({ cx, cz, w, h, kind });
    }
  }
  return rects;
}
function assembleWorld(plan, scene) {
  const { width, height, kinds } = plan;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
    return err({ code: WORLD_BAD_PLAN, message: `\u5C3A\u5BF8\u4E0D\u5408\u6CD5\uFF1A${String(width)}x${String(height)}` });
  }
  if (kinds.length !== width * height) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `kinds \u957F\u5EA6 ${kinds.length} \u4E0E\u5C3A\u5BF8 ${width}x${height}\uFF08${width * height}\uFF09\u4E0D\u7B26`
    });
  }
  for (let i = 0; i < kinds.length; i++) {
    if (!isBiomeKind(kinds[i])) {
      return err({
        code: WORLD_BAD_PLAN,
        message: `\u7B2C ${i} \u683C\u7684\u7FA4\u7CFB\u540D\u672A\u77E5\uFF1A${String(kinds[i])}\uFF08\u53EF\u80FD\u662F\u65E7 schema \u6216\u624B\u6539\u7684\u8BA1\u5212\uFF09`
      });
    }
  }
  const digest = planDigest(plan);
  if (!digest.ok) return digest;
  if (digest.value !== plan.fingerprint) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `\u8BA1\u5212\u6307\u7EB9\u4E0E\u5185\u5BB9\u4E0D\u7B26\uFF08\u8BA1\u5212\u91CC\u5B58 ${plan.fingerprint}\uFF0C\u91CD\u7B97\u5F97 ${digest.value}\uFF09\u2014\u2014 \u5185\u5BB9\u88AB\u6539\u8FC7\u6216\u6765\u81EA\u65E7 schema`
    });
  }
  if (scene.stats().nodes !== 1) {
    return err({
      code: WORLD_SCENE_NOT_EMPTY,
      message: `\u76EE\u6807\u573A\u666F\u5DF2\u6709 ${scene.stats().nodes - 1} \u4E2A\u8282\u70B9\uFF08\u88C5\u914D\u8981\u6C42\u7A7A\u573A\u666F\uFF0C\u5148 scene.clear()\uFF09`
    });
  }
  const missing = [TERRAIN_TYPE, SITE_TYPE].filter((t) => !scene.components.has(t));
  if (missing.length > 0) {
    return err({
      code: WORLD_COMPONENTS_UNREGISTERED,
      message: `\u7EC4\u4EF6\u7C7B\u578B\u672A\u6CE8\u518C\uFF1A${missing.join(", ")} \u2014\u2014 \u5148 registerWorldComponents(scene.components)`
    });
  }
  const rects = mergeTerrain(width, height, kinds);
  const terrainRoot = scene.spawnImmediate("terrain");
  const siteRoot = scene.spawnImmediate("sites");
  for (const r of rects) {
    const node = scene.spawnImmediate(`terrain/${r.kind}`, terrainRoot.id);
    node.setLocalPosition(r.cx, r.cz);
    const made = scene.attach(node.id, () => new TerrainArea());
    if (!made.ok) return made;
    made.value.kind = r.kind;
    made.value.cx = r.cx;
    made.value.cz = r.cz;
    made.value.w = r.w;
    made.value.h = r.h;
    made.value.passable = isPassable(r.kind);
  }
  for (const s of plan.sites) {
    const node = scene.spawnImmediate(`site/${s.kind}`, siteRoot.id);
    node.setLocalPosition(s.x / FIXED_UNITS, s.z / FIXED_UNITS);
    const made = scene.attach(node.id, () => new SiteMarker());
    if (!made.ok) return made;
    made.value.siteId = s.id;
    made.value.kind = s.kind;
    made.value.cell = s.cell;
  }
  scene.flush();
  return ok({
    terrainNodes: rects.length,
    siteNodes: plan.sites.length,
    sceneNodes: scene.stats().nodes,
    cells: width * height,
    rects: rects.length,
    fingerprint: plan.fingerprint
  });
}

// src/extensions/worldgen/tasks.ts
var WORLD_TASK_SCHEMA = 1;
var TASK_BAD_TABLE = "TASK.BAD_TABLE";
var TASK_BAD_TICK = "TASK.BAD_TICK";
function hashString(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
function dueRange(period, phase, from, to) {
  if (to <= from) return { first: -1, count: 0 };
  const rem = ((phase - from % period) % period + period) % period;
  const first = from + (rem === 0 ? period : rem);
  if (first > to) return { first: -1, count: 0 };
  return { first, count: Math.floor((to - first) / period) + 1 };
}
function validateTaskTable(table) {
  if (table.schema !== WORLD_TASK_SCHEMA) {
    return err({
      code: TASK_BAD_TABLE,
      message: `\u8868\u7ED3\u6784\u7248\u672C ${String(table.schema)} \u4E0D\u662F ${WORLD_TASK_SCHEMA}\uFF08\u65E7\u8868\u5FC5\u987B\u88AB\u62D2\u7EDD\uFF0C\u800C\u4E0D\u662F\u52C9\u5F3A\u80FD\u7528\uFF09`
    });
  }
  const seen = /* @__PURE__ */ new Set();
  const out = [];
  for (let i = 0; i < table.tasks.length; i++) {
    const t = table.tasks[i];
    if (typeof t.id !== "string" || t.id.length === 0) {
      return err({ code: TASK_BAD_TABLE, message: `\u7B2C ${i} \u6761\u4EFB\u52A1\u6CA1\u6709 id` });
    }
    if (seen.has(t.id)) {
      return err({ code: TASK_BAD_TABLE, message: `\u4EFB\u52A1 id \u91CD\u590D\uFF1A${t.id}` });
    }
    seen.add(t.id);
    if (!Number.isInteger(t.periodTicks) || t.periodTicks < 1) {
      return err({
        code: TASK_BAD_TABLE,
        message: `\u4EFB\u52A1 ${t.id} \u7684 periodTicks \u5FC5\u987B\u662F \u22651 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(t.periodTicks)}`
      });
    }
    const phase = t.phase ?? 0;
    if (!Number.isInteger(phase) || phase < 0 || phase >= t.periodTicks) {
      return err({
        code: TASK_BAD_TABLE,
        message: `\u4EFB\u52A1 ${t.id} \u7684 phase \u5FC5\u987B\u843D\u5728 [0, ${t.periodTicks})\uFF0C\u5F97\u5230 ${String(phase)} \u2014\u2014 \u8D8A\u754C\u4F1A\u8BA9\u5B83\u6C38\u4E0D\u89E6\u53D1`
      });
    }
    const picks = t.picksPerRun ?? 0;
    if (!Number.isInteger(picks) || picks < 0 || picks > 64) {
      return err({
        code: TASK_BAD_TABLE,
        message: `\u4EFB\u52A1 ${t.id} \u7684 picksPerRun \u5FC5\u987B\u662F 0..64 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(picks)}`
      });
    }
    if (t.biomes !== void 0) {
      for (const b of t.biomes) {
        if (!isBiomeKind(b)) {
          return err({ code: TASK_BAD_TABLE, message: `\u4EFB\u52A1 ${t.id} \u7684\u7FA4\u7CFB\u540D\u672A\u77E5\uFF1A${String(b)}` });
        }
      }
    }
    out.push(t);
  }
  return ok(out);
}
var WorldTasks = class _WorldTasks {
  states;
  plan;
  _lastTick = 0;
  _runs = 0;
  _missed = 0;
  constructor(states, plan) {
    this.states = states;
    this.plan = plan;
  }
  static create(table, plan) {
    const valid = validateTaskTable(table);
    if (!valid.ok) return valid;
    const needsPlan = valid.value.some((t) => (t.picksPerRun ?? 0) > 0 && (t.biomes?.length ?? 0) > 0);
    if (needsPlan && plan === void 0) {
      return err({
        code: TASK_BAD_TABLE,
        message: "\u8868\u91CC\u6709\u4EFB\u52A1\u8981\u6309\u7FA4\u7CFB\u9009\u683C\uFF0C\u4F46\u6CA1\u6709\u7ED9 WorldPlan \u2014\u2014 \u9759\u9ED8\u8FD4\u56DE\u7A7A\u6570\u7EC4\u4F1A\u8BA9\u300C\u6CA1\u5237\u51FA\u6765\u300D\u770B\u8D77\u6765\u50CF\u300C\u6CA1\u8DD1\u5230\u300D"
      });
    }
    return ok(
      new _WorldTasks(
        valid.value.map((task) => ({ task, runs: 0, missed: 0 })),
        plan
      )
    );
  }
  get lastTick() {
    return this._lastTick;
  }
  /**
   * 推进到 `tick`（含），返回本次推进触发的执行。
   *
   * ★ 只能前进：倒退会让同一个 tick 被执行两次（读档回档时的经典坑），必须报错。
   * ★ 顺序：先按 `tick` 升序（区间内各任务的首次命中），再按表内声明顺序 ——
   *   "按 tick 再按声明序"是确定的；只按声明序会让同一 tick 内多任务的先后
   *   依赖表里谁写在前，而这个顺序会进 seed 之外的副作用（日志、事件）。
   */
  advanceTo(tick) {
    if (!Number.isInteger(tick)) {
      return err({ code: TASK_BAD_TICK, message: `tick \u5FC5\u987B\u662F\u6574\u6570\uFF0C\u5F97\u5230 ${String(tick)}` });
    }
    if (tick < this._lastTick) {
      return err({
        code: TASK_BAD_TICK,
        message: `\u65F6\u95F4\u4E0D\u80FD\u5012\u9000\uFF1A\u4E0A\u6B21 ${this._lastTick}\uFF0C\u8FD9\u6B21 ${tick}\uFF08\u56DE\u6863\u8BF7\u91CD\u5EFA\u4EFB\u52A1\u8868\uFF09`
      });
    }
    const due = [];
    for (let i = 0; i < this.states.length; i++) {
      const st = this.states[i];
      const period = st.task.periodTicks;
      const phase = st.task.phase ?? 0;
      const { first, count } = dueRange(period, phase, this._lastTick, tick);
      if (first < 0) continue;
      st.runs += 1;
      st.missed += count - 1;
      this._runs += 1;
      this._missed += count - 1;
      due.push({
        order: i,
        fire: {
          taskId: st.task.id,
          tick: first,
          run: st.runs,
          missed: count - 1,
          cells: this.pickCells(st.task, first, st.runs)
        }
      });
    }
    this._lastTick = tick;
    due.sort((a, b) => a.fire.tick !== b.fire.tick ? a.fire.tick - b.fire.tick : a.order - b.order);
    return ok(due.map((d) => d.fire));
  }
  /**
   * 按群系确定性选格：候选 = 计划里"群系属于 biomes 且可通行"的格子（升序）。
   *
   * ★★ seed 只由 **(任务 id, 首次到期 tick)** 决定，**不含 `run`**。
   *   第一版把 `run` 也混了进去，写变异时才发现两个问题：
   *   ① 它让"同一 tick 的产出"依赖**执行历史** —— 读档后重建实例、推进到同一个 tick，
   *      会得到另一批格子（`run` 从 1 重新数），可重放性当场失效；
   *   ② `firstTick` 严格单调递增，`run` 在它之外不带来任何新信息 ——
   *      删掉 `run` 也无法被任何判据抓住。**一条抓不住对应变异的判据等于没写**，
   *      反过来说：一个无法被区分的设计元素也不该留在关键路径上。
   *   所以 `run` 降级为纯诊断字段（`runCounts()` 用）。
   */
  pickCells(task, firstTick, _run) {
    const want = task.picksPerRun ?? 0;
    const biomes = task.biomes ?? [];
    if (want === 0 || biomes.length === 0 || this.plan === void 0) return [];
    const allow = new Set(biomes);
    const candidates = [];
    for (let i = 0; i < this.plan.kinds.length; i++) {
      const k = this.plan.kinds[i];
      if (!allow.has(k)) continue;
      if (!isPassable(k)) continue;
      candidates.push(i);
    }
    if (candidates.length === 0) return [];
    const seed = hashString(task.id) ^ Math.imul(firstTick, 2654435761) | 0;
    const rng = new XorShift128(seed);
    rng.shuffle(candidates);
    return candidates.slice(0, Math.min(want, candidates.length)).sort((a, b) => a - b);
  }
  stats() {
    return {
      tasks: this.states.length,
      runs: this._runs,
      missed: this._missed,
      lastTick: this._lastTick
    };
  }
  /** 每条任务跑了多少次（诊断/编辑器面板用）。 */
  runCounts() {
    const out = /* @__PURE__ */ new Map();
    for (const st of this.states) out.set(st.task.id, st.runs);
    return out;
  }
};

// src/core/tokens.ts
var Services = {
  /**
   * 帧宿主：提供 `onRender(fn)`。
   * ★ 为什么渲染不能靠"事件"：事件是"发生了什么，谁关心谁订阅"，
   *   而渲染是**每个宿主都必须执行的一个阶段**（哪怕没人订阅）。
   *   用事件的话，"没有任何渲染器订阅"与"渲染器都注销了"无法区分，
   *   画面会静默变黑。
   */
  Frame: defineService("core.frame"),
  Scene: defineService("core.scene"),
  Assets: defineService("core.assets"),
  Scheduler: defineService("core.scheduler"),
  /**
   * 脚本运行时（可空）。
   * ★ 为什么作为服务而不是"模块私有字段"：UI/AI/关卡这些上层模块都要调脚本，
   *   如果各自 new 一个运行时，就会出现"两个 VM 两份全局状态"——
   *   脚本里的全局变量会莫名其妙地不共享。
   */
  Script: defineService("core.script")
};

// src/extensions/worldgen/task-module.ts
var RESOURCE_TYPE = "world.resource";
var TASK_NO_SCENE = "TASK.NO_SCENE";
var TASK_BAD_CELL = "TASK.BAD_CELL";
var TASK_BAD_TERRAIN = "TASK.BAD_TERRAIN";
var TASK_CELL_TAKEN = "TASK.CELL_TAKEN";
var TASK_CAP = "TASK.CAP";
var RESOURCE_SCHEMA = {
  type: RESOURCE_TYPE,
  fields: {
    cell: FieldType.Int,
    kind: FieldType.String,
    /** 哪一次触发刷出来的（= `TaskFire.tick`）。诊断用，也用来验"重复触发没被合并"。 */
    bornTick: FieldType.Int
  }
};
var ResourceMarker = class extends Component {
  schema = RESOURCE_SCHEMA;
  cell = 0;
  kind = "tree";
  bornTick = 0;
};
function registerResourceComponent(registry) {
  if (!registry.has(RESOURCE_TYPE)) registry.register(RESOURCE_SCHEMA, () => new ResourceMarker());
}
var DEFAULT_MAX_RESOURCES = 4096;
function createWorldTaskModule(opts) {
  const maxResources = opts.maxResources ?? DEFAULT_MAX_RESOURCES;
  let scene = opts.scene ?? null;
  let ctxRef = null;
  let started = false;
  const tasks = (() => {
    const r = WorldTasks.create(opts.tasks, opts.plan);
    if (!r.ok) {
      throw new Error(`\u4E16\u754C\u4EFB\u52A1\u8868\u4E0D\u5408\u6CD5\uFF1A${r.error.code} ${r.error.message}`);
    }
    return r.value;
  })();
  let occupied = null;
  let fires = 0;
  let spawned = 0;
  let alive = 0;
  let released = 0;
  let skippedExisting = 0;
  let skippedCap = 0;
  let lastFires = [];
  function ensureIndex(s) {
    if (occupied !== null) return occupied;
    const set = /* @__PURE__ */ new Set();
    for (const marker of s.componentsOf(SITE_TYPE)) set.add(marker.cell);
    for (const res of s.componentsOf(RESOURCE_TYPE)) set.add(res.cell);
    occupied = set;
    return set;
  }
  const mod = {
    id: "world.tasks",
    deps: [],
    tasks,
    init(ctx) {
      ctxRef = ctx;
      if (scene === null) {
        const got = ctx.services.get(Services.Scene);
        if (got === void 0) {
          return err(
            engineError(
              TASK_NO_SCENE,
              "\u4E16\u754C\u4EFB\u52A1\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF1A\u8981\u4E48\u5728 options \u91CC\u4F20\uFF0C\u8981\u4E48\u5148\u7531\u5BBF\u4E3B\u6CE8\u518C Services.Scene"
            )
          );
        }
        scene = got;
      }
      if (!scene.components.has(RESOURCE_TYPE)) {
        return err(
          engineError(
            TASK_NO_SCENE,
            `\u573A\u666F\u7684\u7EC4\u4EF6\u6CE8\u518C\u8868\u91CC\u6CA1\u6709 ${RESOURCE_TYPE} \u2014\u2014 \u5148 registerResourceComponent(scene.components)`
          )
        );
      }
      return ok(void 0);
    },
    start() {
      started = true;
    },
    stop() {
      started = false;
    },
    update(tick, dt) {
      const s = scene;
      if (s === null || !started) return;
      const advanced = tasks.advanceTo(tick);
      if (!advanced.ok) {
        ctxRef?.log.channel("world").warn(`\u4E16\u754C\u4EFB\u52A1\u63A8\u8FDB\u5931\u8D25\uFF1A${advanced.error.code} ${advanced.error.message}`);
        lastFires = [];
        return;
      }
      lastFires = advanced.value;
      if (advanced.value.length === 0) return;
      const taken = ensureIndex(s);
      let touched = false;
      for (const fire of advanced.value) {
        fires++;
        for (const cell of fire.cells) {
          if (taken.has(cell)) {
            skippedExisting++;
            continue;
          }
          if (alive >= maxResources) {
            skippedCap++;
            continue;
          }
          const width = opts.plan.width;
          const cx = cell % width;
          const cz = (cell - cx) / width;
          const node = s.spawn(`resource/${kindOf(fire, opts.plan, cell)}`, null);
          if (!node.ok) {
            ctxRef?.log.channel("world").warn(`\u8D44\u6E90\u8282\u70B9\u521B\u5EFA\u5931\u8D25\uFF1A${node.error.code}`);
            continue;
          }
          node.value.setLocalPosition(cx + 0.5, cz + 0.5);
          const made = s.attach(node.value.id, () => new ResourceMarker());
          if (!made.ok) continue;
          made.value.cell = cell;
          made.value.kind = kindOf(fire, opts.plan, cell);
          made.value.bornTick = fire.tick;
          taken.add(cell);
          spawned++;
          alive++;
          touched = true;
        }
      }
      if (touched) s.flush();
    },
    stats() {
      return {
        fires,
        spawned,
        alive,
        released,
        skippedExisting,
        skippedCap,
        occupied: occupied === null ? 0 : occupied.size,
        lastTick: tasks.lastTick
      };
    },
    releaseCell(cell) {
      const s = scene;
      if (s === null) return false;
      const taken = ensureIndex(s);
      if (!taken.delete(cell)) return false;
      if (alive > 0) alive--;
      released++;
      return true;
    },
    isOccupied(cell) {
      const s = scene;
      if (s === null) return false;
      return ensureIndex(s).has(cell);
    },
    placeResource(cell, kind, bornTick) {
      const s = scene;
      if (s === null) {
        return err(engineError(TASK_NO_SCENE, "\u4E16\u754C\u4EFB\u52A1\u6A21\u5757\u6CA1\u6709\u573A\u666F\uFF0C\u653E\u4E0D\u4E86\u8D44\u6E90"));
      }
      const width = opts.plan.width;
      const size = width * opts.plan.height;
      if (!Number.isInteger(cell) || cell < 0 || cell >= size) {
        return err(engineError(TASK_BAD_CELL, `\u683C\u5B50 ${String(cell)} \u8D8A\u754C\uFF08\u4E16\u754C\u662F ${String(width)}\xD7${String(opts.plan.height)}\uFF09`));
      }
      if (!isPassable(opts.plan.kinds[cell])) {
        return err(engineError(TASK_BAD_TERRAIN, `\u683C\u5B50 ${String(cell)} \u662F\u4E0D\u53EF\u901A\u884C\u5730\u5F62\uFF0C\u4E0D\u80FD\u653E\u8D44\u6E90`));
      }
      const taken = ensureIndex(s);
      if (taken.has(cell)) {
        return err(engineError(TASK_CELL_TAKEN, `\u683C\u5B50 ${String(cell)} \u4E0A\u5DF2\u7ECF\u6709\u8D44\u6E90\u4E86`));
      }
      if (alive >= maxResources) {
        return err(engineError(TASK_CAP, `\u4E16\u754C\u8D44\u6E90\u5DF2\u5230\u5168\u5C40\u4E0A\u9650\uFF08${String(maxResources)}\uFF09\uFF0C\u653E\u4E0D\u4E0B\u66F4\u591A`));
      }
      const cx = cell % width;
      const cz = (cell - cx) / width;
      const node = s.spawn(`resource/${kind}`, null);
      if (!node.ok) return node;
      node.value.setLocalPosition(cx + 0.5, cz + 0.5);
      const made = s.attach(node.value.id, () => new ResourceMarker());
      if (!made.ok) {
        s.destroy(node.value.id);
        s.flush();
        return made;
      }
      made.value.cell = cell;
      made.value.kind = kind;
      made.value.bornTick = bornTick;
      taken.add(cell);
      spawned++;
      alive++;
      s.flush();
      return ok(node.value.id);
    },
    lastFires() {
      return lastFires;
    },
    describe() {
      return `world.tasks\uFF1A${String(tasks.stats().tasks)} \u6761\u4EFB\u52A1 / \u5DF2\u5237 ${String(spawned)} / \u8DF3\u8FC7\u53BB\u91CD ${String(skippedExisting)} / \u4E0A\u9650 ${String(skippedCap)}`;
    }
  };
  return mod;
}
function kindOf(fire, plan, cell) {
  const kind = plan.kinds[cell];
  if (!isPassable(kind)) return "grass_tuft";
  switch (kind) {
    case "forest":
      return "tree";
    case "grass":
      return "berry";
    case "beach":
      return "flint";
    case "rocky":
      return "rock";
    case "savanna":
      return "grass_tuft";
    case "marsh":
      return "reed";
    default:
      return "grass_tuft";
  }
}

// src/extensions/render/sprite.ts
var SPRITE_TYPE = "render.sprite";
var Sprite = class extends Component {
  /** 图集资产 id（空 = 用默认图集）。 */
  atlasId = "";
  /** 图集内帧名。 */
  frame = "";
  /** 世界尺寸（宽/高）。 */
  width = 1;
  height = 1;
  /** 顶点色（与纹理相乘）。 */
  r = 1;
  g = 1;
  b = 1;
  a = 1;
  /** 同 z 时的次序（小的先画）。 */
  order = 0;
  /**
   * 绘制层：0 = 背景（地面），1 = 实体（默认）。层在 z **之前**比较。
   *
   * ★ 默认 1 而不是 0：旧内容/旧存档没有这个字段，它们该保持"实体"行为。
   *   缺字段拿到 0 会让所有旧精灵掉到地形背后 —— 一帧都不显示，且没有任何报错。
   *
   * ★ 用整数而不是枚举：层数由宿主定（背景/实体/UI/ overlay…），引擎不替宿主
   *   决定有哪些层，只保证"小的先画"。
   */
  layer = 1;
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;
  /**
   * 水平锚点：0 = 左边界，0.5 = 中心。
   *
   * ★ 为什么需要它（这是"地形一直画不出来"的根因）：
   *   地形节点是**矩形**，位置是矩形左上角的格子坐标。只有 `pivotY` 时，
   *   精灵永远以节点位置为水平中心 —— 一块 8×5 的地形要么整体右移半块，
   *   要么就得把节点位置改成矩形中心（那会破坏「地形节点位置 = 格子坐标」，
   *   连带破坏反查与存档往返）。加一个对称的 `pivotX` 是唯一不动代价的解法。
   *
   * ★ 默认 0.5 = 与"只有 pivotY"时的行为完全一致：旧内容/旧代码的显示不变。
   *   也正因为如此，旧存档里没有这个字段时**必须**拿到 0.5（不是 0）——
   *   见 scene-io 的 `missingFields`：缺字段会走类里的默认值，不会被写成 0。
   */
  pivotX = 0.5;
  /**
   * 沿精灵宽度重复贴图多少次（T288）。
   *
   * ★ 为什么它是"次数"而不是"UV 缩放量"：调用方想的是"这一块 8 格宽的地形，
   *   每格铺一张 64×64 的噪点"—— 8 次，一个整数。乘出来的 UV 是 8×帧宽，
   *   那是实现细节。写成"缩放量"会让每个宿主都得自己算 `宽 / 贴图像素宽`，
   *   而那正是 T288 想消灭的"每处各算一遍"。
   *
   * ★ 只能用在 `wrap: repeat` 的**瓦片页**上（见 `buildTilePages`）。
   *   在 clamp 页上平铺，GPU 会把边缘像素抻出去 —— 画面是一条脏边，
   *   而精灵的所有数字都对。渲染模块对这种组合**告警**（不静默跳过）。
   *
   * ★ 默认 1 = 与旧行为逐字节一致：旧存档没有这个字段时也必须拿到 1
   *   （`scene-io` 的缺字段走类默认值，不会被写成 0 —— 0 会让精灵整块消失）。
   */
  tileX = 1;
  /** 沿精灵高度重复贴图多少次。语义同 `tileX`。 */
  tileY = 1;
  schema = {
    type: SPRITE_TYPE,
    fields: {
      atlasId: FieldType.String,
      frame: FieldType.String,
      width: FieldType.Float,
      height: FieldType.Float,
      r: FieldType.Float,
      g: FieldType.Float,
      b: FieldType.Float,
      a: FieldType.Float,
      order: FieldType.Int,
      layer: FieldType.Int,
      visible: FieldType.Bool,
      pivotY: FieldType.Float,
      pivotX: FieldType.Float,
      tileX: FieldType.Float,
      tileY: FieldType.Float
    }
  };
};

// src/extensions/worldgen/spawn.ts
var PLAYER_TYPE = "world.player";
var PLAYER_FRAME = "player";
var SPAWN_NO_SPRITE_COMPONENT = "SPAWN.NO_SPRITE_COMPONENT";
var SPAWN_ALREADY_SPAWNED = "SPAWN.ALREADY_SPAWNED";
var PLAYER_SCHEMA = {
  type: PLAYER_TYPE,
  fields: {
    /** 出生格（升序下标）。玩家走开之后这个字段仍然是"他是从哪开始的"。 */
    cell: FieldType.Int
  }
};
var PlayerSpawn = class extends Component {
  schema = PLAYER_SCHEMA;
  cell = 0;
};
function registerPlayerComponent(registry) {
  if (!registry.has(PLAYER_TYPE)) registry.register(PLAYER_SCHEMA, () => new PlayerSpawn());
}
function spawnPlayer(scene, plan) {
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        SPAWN_NO_SPRITE_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B render.sprite \u672A\u6CE8\u518C \u2014\u2014 \u73A9\u5BB6\u4F1A\u6CA1\u6709\u8EAB\u4F53\uFF08\u6E32\u67D3\u6A21\u5757\u542F\u52A8\u65F6\u4F1A\u6CE8\u518C\uFF09"
      )
    );
  }
  if (!scene.components.has(PLAYER_TYPE)) {
    return err(
      engineError(SPAWN_NO_SPRITE_COMPONENT, "\u7EC4\u4EF6\u7C7B\u578B world.player \u672A\u6CE8\u518C \u2014\u2014 \u5148 registerPlayerComponent(...)")
    );
  }
  const existing = [...scene.componentsOf(PLAYER_TYPE)];
  if (existing.length > 0) {
    return err(
      engineError(SPAWN_ALREADY_SPAWNED, "\u573A\u666F\u91CC\u5DF2\u7ECF\u6709\u73A9\u5BB6\u4E86 \u2014\u2014 \u91CD\u590D\u51FA\u751F\u4F1A\u8BA9\u4E24\u4E2A\u63A7\u5236\u5668\u62A2\u540C\u4E00\u4E2A\u4F4D\u7F6E")
    );
  }
  const pick = pickSpawn(plan);
  if (!pick.ok) return pick;
  const sp = pick.value;
  const made = scene.spawnAt("player", sp.x / FIXED_UNITS, sp.z / FIXED_UNITS);
  if (!made.ok) return made;
  const nodeId = made.value.id;
  scene.attach(nodeId, () => {
    const s = new Sprite();
    s.frame = PLAYER_FRAME;
    s.width = 1;
    s.height = 1;
    s.pivotY = 0;
    return s;
  });
  scene.attach(nodeId, () => {
    const marker = new PlayerSpawn();
    marker.cell = sp.cell;
    return marker;
  });
  scene.flush();
  return ok({ nodeId, cell: sp.cell, x: sp.x, z: sp.z });
}

// src/extensions/worldgen/harvest.ts
var HARVEST_NOTHING = "HARVEST.NOTHING";
var HARVEST_BAD_CELL = "HARVEST.BAD_CELL";
function isCellIndex(v) {
  return Number.isInteger(v) && v >= 0;
}
function harvestAt(scene, cell, opts = {}) {
  if (!isCellIndex(cell)) {
    return err(engineError(HARVEST_BAD_CELL, `\u683C\u5B50\u4E0B\u6807\u5FC5\u987B\u662F \u2265 0 \u7684\u6574\u6570\uFF0C\u6536\u5230 ${String(cell)}`));
  }
  for (const r of scene.componentsOf(RESOURCE_TYPE)) {
    if (r.cell !== cell || r.node === null) continue;
    const nodeId = r.node.id;
    const kind = r.kind;
    scene.destroy(nodeId);
    scene.flush();
    opts.onRelease?.(cell);
    return ok({ cell, kind, nodeId, source: "resource" });
  }
  for (const m of scene.componentsOf(SITE_TYPE)) {
    if (m.cell !== cell || m.node === null) continue;
    const nodeId = m.node.id;
    const kind = m.kind;
    scene.destroy(nodeId);
    scene.flush();
    opts.onRelease?.(cell);
    return ok({ cell, kind, nodeId, source: "site" });
  }
  return err(
    engineError(
      HARVEST_NOTHING,
      `\u683C\u5B50 ${String(cell)} \u4E0A\u6CA1\u6709\u8D44\u6E90\uFF08\u518D\u751F ${String(scene.countOf(RESOURCE_TYPE))} \u4E2A / \u6295\u653E\u70B9 ${String(scene.countOf(SITE_TYPE))} \u4E2A\uFF09`
    )
  );
}

// src/extensions/inventory/inventory.ts
var ITEM_TYPE = "game.item";
var INVENTORY_TYPE = "game.inventory";
var INVENTORY_NO_OWNER = "INVENTORY.NO_OWNER";
var INVENTORY_FULL = "INVENTORY.FULL";
var INVENTORY_BAD_COUNT = "INVENTORY.BAD_COUNT";
var ItemStack = class extends Component {
  /** 物品种类（与 `SiteKind` 同名，但不强绑：背包不认识"世界"）。 */
  kind = "";
  count = 0;
  schema = {
    type: ITEM_TYPE,
    fields: { kind: FieldType.String, count: FieldType.Int }
  };
};
var Inventory = class extends Component {
  /** 最多几堆（不是"最多几个"）。到上限再加"新种类"就报 `INVENTORY.FULL`。 */
  maxStacks = 8;
  /**
   * 单堆上限（饥荒默认 40）。**不是**"最多几个"：到顶会自动开新堆（有名额时），
   * 没有名额才报 `INVENTORY.FULL`。
   *
   * ★ 为什么需要它：`maxStacks` 管的是**格子数**，单堆无上限时"1 堆 × 9999"与
   *   "250 堆 × 40"都合法 —— 前者让背包面板一行写不下，后者让 `maxStacks` 形同虚设。
   *   两者都管，才是"几格、每格多少"的完整形状。
   */
  maxStack = 40;
  schema = {
    type: INVENTORY_TYPE,
    fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int }
  };
};
function registerInventoryComponents(registry) {
  if (!registry.has(ITEM_TYPE)) registry.register(ITEM_SCHEMA, () => new ItemStack());
  if (!registry.has(INVENTORY_TYPE)) registry.register(INVENTORY_SCHEMA, () => new Inventory());
}
var ITEM_SCHEMA = { type: ITEM_TYPE, fields: { kind: FieldType.String, count: FieldType.Int } };
var INVENTORY_SCHEMA = {
  type: INVENTORY_TYPE,
  fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int }
};
function makeInventory(scene, ownerId, maxStacks = 8, maxStack = 40) {
  const owner = scene.find(ownerId);
  if (owner === void 0) return err(engineError(INVENTORY_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  const existing = owner.get(INVENTORY_TYPE);
  if (existing !== void 0) return ok(existing);
  const made = scene.attach(ownerId, () => {
    const inv2 = new Inventory();
    inv2.maxStacks = maxStacks;
    inv2.maxStack = maxStack;
    return inv2;
  });
  if (!made.ok) return made;
  scene.flush();
  const inv = owner.get(INVENTORY_TYPE);
  if (inv === void 0) return err(engineError(INVENTORY_NO_OWNER, "\u80CC\u5305\u7EC4\u4EF6\u6302\u4E0A\u4E4B\u540E\u53C8\u8BFB\u4E0D\u5230"));
  return ok(inv);
}
function stacksOf(scene, ownerId) {
  const owner = scene.find(ownerId);
  if (owner === void 0) return [];
  const out = [];
  owner.walk((n) => {
    if (n.id === ownerId) return;
    const it = n.get(ITEM_TYPE);
    if (it !== void 0) out.push(it);
  });
  out.sort((a, b) => (a.node?.id ?? 0) - (b.node?.id ?? 0));
  return out;
}
function countItem(scene, ownerId, kind) {
  let n = 0;
  for (const s of stacksOf(scene, ownerId)) if (s.kind === kind) n += s.count;
  return n;
}
function isPositiveInt(v) {
  return Number.isInteger(v) && v > 0;
}
function stackCapOf(inv) {
  const v = inv.maxStack;
  if (!Number.isInteger(v) || v < 1) return 1;
  return v;
}
function stacksNeeded(total, cap) {
  return Math.max(1, Math.ceil(total / cap));
}
function addItem(scene, ownerId, kind, n) {
  if (!isPositiveInt(n)) {
    return err(engineError(INVENTORY_BAD_COUNT, `\u6570\u91CF\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(n)}`));
  }
  const owner = scene.find(ownerId);
  if (owner === void 0) return err(engineError(INVENTORY_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  const inv = owner.get(INVENTORY_TYPE);
  if (inv === void 0) return err(engineError(INVENTORY_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u6CA1\u6709\u80CC\u5305\u7EC4\u4EF6`));
  const cap = stackCapOf(inv);
  const stacks = stacksOf(scene, ownerId);
  const free = Math.max(0, inv.maxStacks - stacks.length);
  const same = stacks.filter((s) => s.kind === kind);
  const total = n + same.reduce((a, s) => a + s.count, 0);
  const needNew = Math.max(0, stacksNeeded(total, cap) - same.length);
  if (needNew > free) {
    return err(
      engineError(
        INVENTORY_FULL,
        `\u80CC\u5305\u5DF2\u6EE1\uFF08${String(inv.maxStacks)} \u5806 \xD7 ${String(cap)}\uFF09\uFF0C${kind} \u6EA2\u51FA ${String(needNew - free)} \u5806\u653E\u4E0D\u4E0B`
      )
    );
  }
  let left = n;
  for (const s of same) {
    if (left === 0) break;
    const put = Math.min(cap - s.count, left);
    s.count += put;
    left -= put;
  }
  while (left > 0) {
    const put = Math.min(cap, left);
    const spawned = scene.spawn(`item/${kind}`, ownerId);
    if (!spawned.ok) return spawned;
    scene.flush();
    const nodeId = spawned.value.id;
    const made = scene.attach(nodeId, () => {
      const s = new ItemStack();
      s.kind = kind;
      s.count = put;
      return s;
    });
    if (!made.ok) {
      scene.destroy(nodeId);
      scene.flush();
      return made;
    }
    left -= put;
  }
  scene.flush();
  return ok(countItem(scene, ownerId, kind));
}

// src/extensions/render/atlas.ts
var Pen = class {
  constructor(px, W, H) {
    this.px = px;
    this.W = W;
    this.H = H;
  }
  /** 当前绘制原点：**每个帧块都必须先 `origin()` 到自己的矩形左上角**。 */
  ox = 0;
  oy = 0;
  /**
   * ★ 这个方法是 T330 顺带抓出来的第二个缺陷的解药：
   *   原来每个帧的绘制用的是**绝对坐标**，而 `layout` 里 rock/player/berry 分别在
   *   x=64/112/144 —— 于是那三帧的图形全被画进了 tree 的矩形（x 0..64），
   *   三帧本身**一个不透明像素都没有**。
   *   症状是"兜底图集里少三类东西"，而所有既有判据（帧在不在、UV 对不对、
   *   尺寸对不对）都是绿的：它们查的是地图，不是地图上有没有东西。
   */
  origin(x, y) {
    this.ox = x;
    this.oy = y;
  }
  put(x, y, r, g, b, a = 255) {
    const ax = this.ox + x;
    const ay = this.oy + y;
    if (ax < 0 || ay < 0 || ax >= this.W || ay >= this.H) return;
    const i = (ay * this.W + ax) * 4;
    const src = a / 255;
    const dstA = this.px[i + 3] / 255;
    const outA = src + dstA * (1 - src);
    if (outA <= 0) return;
    this.px[i] = Math.round((r * src + this.px[i] * dstA * (1 - src)) / outA);
    this.px[i + 1] = Math.round((g * src + this.px[i + 1] * dstA * (1 - src)) / outA);
    this.px[i + 2] = Math.round((b * src + this.px[i + 2] * dstA * (1 - src)) / outA);
    this.px[i + 3] = Math.round(outA * 255);
  }
  rect(x, y, w, h, c) {
    for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) this.put(i, j, c[0], c[1], c[2]);
  }
  /** 圆（用于石头/浆果）。 */
  disc(cx, cy, r, c) {
    for (let j = -r; j <= r; j++) {
      for (let i = -r; i <= r; i++) {
        if (i * i + j * j <= r * r) this.put(cx + i, cy + j, c[0], c[1], c[2]);
      }
    }
  }
  /** 三角（树冠）。 */
  triangle(x0, y0, x1, y1, x2, y2, c) {
    const minY = Math.min(y0, y1, y2);
    const maxY = Math.max(y0, y1, y2);
    for (let y = minY; y <= maxY; y++) {
      const xs = [];
      const edges = [
        [x0, y0, x1, y1],
        [x1, y1, x2, y2],
        [x2, y2, x0, y0]
      ];
      for (const [ax, ay, bx, by] of edges) {
        if (ay <= y && by >= y || by <= y && ay >= y) {
          if (Math.abs(by - ay) < 1e-9) {
            xs.push(ax, bx);
          } else {
            xs.push(ax + (y - ay) / (by - ay) * (bx - ax));
          }
        }
      }
      if (xs.length >= 2) {
        const lo = Math.round(Math.min(...xs));
        const hi = Math.round(Math.max(...xs));
        for (let x = lo; x <= hi; x++) this.put(x, y, c[0], c[1], c[2]);
      }
    }
  }
};
function buildProceduralAtlas() {
  const W = 256;
  const H = 256;
  const px = new Uint8Array(W * H * 4);
  const pen = new Pen(px, W, H);
  const layout = [
    { name: "tree", x: 0, y: 0, w: 64, h: 96 },
    { name: "rock", x: 64, y: 0, w: 48, h: 40 },
    { name: "player", x: 112, y: 0, w: 32, h: 48 },
    { name: "berry", x: 144, y: 0, w: 24, h: 24 },
    { name: "ground", x: 0, y: 96, w: 64, h: 64 },
    { name: "terrain", x: 64, y: 96, w: 64, h: 64 }
  ];
  const at = (n) => {
    const l = layout.find((e) => e.name === n);
    if (l === void 0) throw new Error(`\u5E03\u5C40\u91CC\u6CA1\u6709\u5E27 "${n}"\uFF08\u5185\u90E8\u4E00\u81F4\u6027\u9519\u8BEF\uFF09`);
    return { x: l.x, y: l.y };
  };
  pen.origin(at("tree").x, at("tree").y);
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);
  pen.origin(at("rock").x, at("rock").y);
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);
  pen.origin(at("player").x, at("player").y);
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);
  pen.origin(at("berry").x, at("berry").y);
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);
  let seed = 19088743;
  const rnd = () => {
    seed = seed * 1103515245 + 12345 & 2147483647;
    return seed / 2147483647;
  };
  pen.origin(at("ground").x, at("ground").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
    }
  }
  pen.origin(at("terrain").x, at("terrain").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 188 + Math.floor(rnd() * 31);
      pen.rect(x, y, 1, 1, [v, v, v]);
    }
  }
  const frames = /* @__PURE__ */ new Map();
  for (const l of layout) {
    frames.set(l.name, {
      u0: l.x / W,
      v0: l.y / H,
      u1: (l.x + l.w) / W,
      v1: (l.y + l.h) / H,
      w: l.w,
      h: l.h
    });
  }
  return { width: W, height: H, pixels: px, frames };
}

// src/extensions/render/world-visuals.ts
var VISUAL_MISSING_FRAME = "VISUAL.MISSING_FRAME";
var VISUAL_NO_SPRITE_COMPONENT = "VISUAL.NO_SPRITE_COMPONENT";
var UNMAPPED_LABEL = "\uFF08\u672A\u6620\u5C04\u7684\u79CD\u7C7B\uFF09";
var SITE_FRAMES = {
  tree: "tree",
  rock: "rock",
  berry: "berry",
  flint: "rock",
  grass_tuft: "berry",
  reed: "berry"
};
var TERRAIN_FRAME = "terrain";
var TERRAIN_TILE_PAGE = "terrain.tile";
var BIOME_TINT = {
  ocean: [0.16, 0.32, 0.55],
  beach: [0.85, 0.78, 0.55],
  grass: [0.42, 0.62, 0.3],
  forest: [0.24, 0.46, 0.26],
  rocky: [0.52, 0.5, 0.48],
  cliff: [0.38, 0.36, 0.4],
  savanna: [0.72, 0.66, 0.36],
  marsh: [0.36, 0.44, 0.38]
};
function hasSprite(s, nodeId) {
  const node = s.find(nodeId);
  return node?.get(SPRITE_TYPE) !== void 0;
}
function attachWorldVisuals(scene, availableFrames) {
  const plans = [];
  for (const area of scene.componentsOf(TERRAIN_TYPE)) {
    if (area.node === null) continue;
    const tint = BIOME_TINT[area.kind];
    plans.push({
      nodeId: area.node.id,
      frame: TERRAIN_FRAME,
      atlasId: TERRAIN_TILE_PAGE,
      kind: `terrain:${area.kind}`,
      width: area.w,
      height: area.h,
      // ★ 背景层：地面永远先画、永远被实体盖住。地形的 z 是矩形左上角的格子坐标，
      //   与实体（格子中心）必然交错 —— 不分层会被一块地形盖住站在它上面的角色，
      //   而且 draw 会被 z 序打散成几十段（T288 之后实测 29 段）。
      layer: 0,
      // ★ T288：按格平铺 —— 一块 w×h 的地形铺 w×h 张噪点，颗粒不随块变大。
      //   必须是整数：0.5 次平铺在 GPU 上就是"半张被裁掉的贴图"，
      //   而矩形格数天生是整数（`TerrainArea` 的 w/h 是格子数）。
      tileX: Math.max(1, Math.floor(area.w)),
      tileY: Math.max(1, Math.floor(area.h)),
      // ★ (0,0)：矩形左上角 = 节点位置。用 0.5 会让整块地形右移半块、上移半块 ——
      //   相邻块之间于是出现缝隙，而"缝隙"在 2.5D 斜视角下看起来像地表裂开了。
      pivotX: 0,
      pivotY: 0,
      r: tint[0],
      g: tint[1],
      b: tint[2]
    });
  }
  for (const m of scene.componentsOf(SITE_TYPE)) {
    if (m.node === null) continue;
    plans.push({
      nodeId: m.node.id,
      frame: SITE_FRAMES[m.kind] ?? null,
      atlasId: "",
      kind: `site:${m.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      // 脚踩地面：2.5D 里精灵的底边贴住它所在的格
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1
    });
  }
  for (const res of scene.componentsOf(RESOURCE_TYPE)) {
    if (res.node === null) continue;
    plans.push({
      nodeId: res.node.id,
      frame: SITE_FRAMES[res.kind] ?? null,
      atlasId: "",
      kind: `resource:${res.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1
    });
  }
  const available = new Set(availableFrames);
  const missing = /* @__PURE__ */ new Map();
  for (const p of plans) {
    if (p.frame !== null && available.has(p.frame)) continue;
    const key = p.frame ?? UNMAPPED_LABEL;
    const set = missing.get(key) ?? /* @__PURE__ */ new Set();
    set.add(p.kind);
    missing.set(key, set);
  }
  if (missing.size > 0) {
    const detail = [...missing.entries()].sort((a, b) => a[0] < b[0] ? -1 : 1).map(([frame, kinds]) => `${frame}\uFF08\u88AB ${[...kinds].sort().join(", ")} \u7528\u5230\uFF09`).join("\uFF1B");
    return err(
      engineError(
        VISUAL_MISSING_FRAME,
        `\u56FE\u96C6\u91CC\u6CA1\u6709\u8FD9\u4E9B\u5E27\uFF1A${detail} \u2014\u2014 \u7F3A\u5E27\u7684\u8D44\u6E90\u4F1A**\u9759\u9ED8\u4E0D\u663E\u793A**\uFF08\u6E32\u67D3\u6A21\u5757\u53EA warn \u4E00\u6B21\uFF09\uFF0C\u6240\u4EE5\u5728\u8FD9\u91CC\u62A5\u9519`
      )
    );
  }
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        VISUAL_NO_SPRITE_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B render.sprite \u672A\u6CE8\u518C \u2014\u2014 \u5148 components.register(...)\uFF08\u6E32\u67D3\u6A21\u5757\u542F\u52A8\u65F6\u4F1A\u6CE8\u518C\uFF09"
      )
    );
  }
  let terrain = 0;
  let sites = 0;
  let resources = 0;
  let skipped = 0;
  const used = /* @__PURE__ */ new Set();
  for (const p of plans) {
    if (hasSprite(scene, p.nodeId)) {
      skipped++;
      continue;
    }
    const frame = p.frame;
    if (frame === null) throw new Error(`world-visuals \u5185\u90E8\u9519\u8BEF\uFF1A${p.kind} \u7684\u5E27\u6620\u5C04\u5728\u68C0\u67E5\u4E4B\u540E\u53D8\u6210\u4E86 null`);
    const made = scene.attach(p.nodeId, () => {
      const sp = new Sprite();
      sp.frame = frame;
      sp.atlasId = p.atlasId;
      sp.tileX = p.tileX;
      sp.tileY = p.tileY;
      sp.layer = p.layer;
      sp.width = p.width;
      sp.height = p.height;
      sp.pivotX = p.pivotX;
      sp.pivotY = p.pivotY;
      sp.r = p.r;
      sp.g = p.g;
      sp.b = p.b;
      return sp;
    });
    if (!made.ok) return made;
    used.add(frame);
    if (p.kind.startsWith("terrain:")) terrain++;
    else if (p.kind.startsWith("site:")) sites++;
    else resources++;
  }
  scene.flush();
  return ok({
    terrain,
    sites,
    resources,
    frames: [...used].sort(),
    skipped
  });
}

// tests/fixtures/cross-host-save.ts
var CROSS_HOST_SEED = 20261024;
var FD = 1 / 30;
function makeRegistry() {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponent(reg);
  registerInventoryComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}
function makeCtx() {
  return {
    log: new Logger(() => 0),
    events: new EventBus(),
    services: new ServiceRegistry(),
    platform: {},
    random: new XorShift128(CROSS_HOST_SEED),
    module: () => void 0
  };
}
function buildCrossHostSave() {
  const scene = new Scene("\u8DE8\u5BBF\u4E3B\u5B58\u6863", makeRegistry());
  const g = generateWorld({ seed: CROSS_HOST_SEED, width: 28, height: 20, maxSitesPerCell: 1 });
  if (!g.ok) throw new Error(`\u751F\u6210\u5931\u8D25\uFF1A${g.error.code} ${g.error.message}`);
  const a = assembleWorld(g.value, scene);
  if (!a.ok) throw new Error(`\u88C5\u914D\u5931\u8D25\uFF1A${a.error.code} ${a.error.message}`);
  const mod = createWorldTaskModule({
    tasks: {
      schema: WORLD_TASK_SCHEMA,
      // 再生参数是**手调过的**：`maxSitesPerCell: 1` 时地图已铺满，再生会被"这格已经有了"全部跳过
      // （首次跑出来 `spawned: 0`），所以先采掉一片、再让它填回来 —— 见下面 harvest 那一段。
      tasks: [{ id: "regen", periodTicks: 5, phase: 3, picksPerRun: 20, biomes: ["grass", "forest"] }]
    },
    plan: g.value,
    scene
  });
  const init = mod.init(makeCtx());
  if (init instanceof Promise) throw new Error("\u4EFB\u52A1\u6A21\u5757 init \u8FD4\u56DE\u4E86 Promise \u2014\u2014 \u8DE8\u5BBF\u4E3B\u8BED\u6599\u53EA\u63A5\u53D7\u540C\u6B65\u521D\u59CB\u5316");
  if (init !== void 0 && init !== null) {
    const ir = init;
    if (!ir.ok) throw new Error(`\u4EFB\u52A1\u6A21\u5757 init \u5931\u8D25\uFF1A${ir.error?.code ?? "?"} ${ir.error?.message ?? ""}`);
  }
  mod.start?.();
  const vis = attachWorldVisuals(scene, [...buildProceduralAtlas().frames.keys()]);
  if (!vis.ok) throw new Error(`\u53EF\u89C1\u5316\u5931\u8D25\uFF1A${vis.error.code} ${vis.error.message}`);
  const spawn = spawnPlayer(scene, g.value);
  if (!spawn.ok) throw new Error(`\u51FA\u751F\u5931\u8D25\uFF1A${spawn.error.code} ${spawn.error.message}`);
  const heroId = spawn.value.nodeId;
  const siteCells = [...scene.componentsOf(SITE_TYPE)].map((s) => s.cell).sort((x, y) => x - y);
  if (siteCells.length < 40) throw new Error(`\u6295\u653E\u70B9\u592A\u5C11\uFF08${String(siteCells.length)} \u4E2A\uFF09\uFF0C\u8BED\u6599\u4E0D\u8FBE\u6807`);
  let released = 0;
  for (const cell of siteCells.slice(0, 40)) {
    const h = harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) });
    if (!h.ok) throw new Error(`\u91C7\u96C6\u7B2C ${String(cell)} \u683C\u5931\u8D25\uFF1A${h.error.code} ${h.error.message}`);
    released++;
  }
  for (let t = 5; t <= 25; t += 5) mod.update(t, FD);
  const inv = makeInventory(scene, heroId);
  if (!inv.ok) throw new Error(`\u6302\u80CC\u5305\u5931\u8D25\uFF1A${inv.error.code} ${inv.error.message}`);
  for (const [kind, n] of [["reed", 3], ["twig", 45]]) {
    const r = addItem(scene, heroId, kind, n);
    if (!r.ok) throw new Error(`\u88C5 ${kind}\xD7${String(n)} \u5931\u8D25\uFF1A${r.error.code} ${r.error.message}`);
  }
  const snap = saveScene(scene);
  const json = sceneToJson(snap);
  return {
    json,
    nodes: snap.nodes.length,
    resources: scene.countOf(RESOURCE_TYPE),
    stacks: stacksOf(scene, heroId).length,
    released
  };
}
function crossHostBytes(json) {
  return new TextEncoder().encode(json);
}
function bytesToBase64(bytes) {
  const TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += TABLE[b0 >> 2];
    out += TABLE[(b0 & 3) << 4 | b1 >> 4];
    out += i + 1 < bytes.length ? TABLE[(b1 & 15) << 2 | b2 >> 6] : "=";
    out += i + 2 < bytes.length ? TABLE[b2 & 63] : "=";
  }
  return out;
}

// tools/cross-host-entry.ts
function run() {
  try {
    const r = buildCrossHostSave();
    const bytes = crossHostBytes(r.json);
    return {
      ok: true,
      base64: bytesToBase64(bytes),
      bytes: bytes.length,
      nodes: r.nodes,
      resources: r.resources,
      stacks: r.stacks,
      released: r.released
    };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? `${e.name}: ${e.message}` : String(e) };
  }
}
globalThis.__crossHost = run();
