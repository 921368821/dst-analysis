/**
 * L4 · 增量快照（Delta）：把「每拍整棵树」降成「变化量」
 *
 * ★★ 这一层只做一件事：**从「上一份发出去的世界」到「这一刻的世界」的差**
 *
 *   批152 的广播是每一拍（或每 N 拍）把整棵树序列化一遍。世界一大，带宽就与世界
 *   大小成正比 —— 而每拍真正变的往往只是几个角色的 `x` / `y`。增量快照把「发什么」
 *   从「世界的全部」换成「变了的那部分」。实测见 `tests/extensions/net-delta.test.ts`
 *   与 `net-session.test.ts` 里那条带宽判据（数字一律取实测，不估）。
 *
 * ★★ 「哪些字段算变化量」的口径（这一节是这一层**唯一**的规格）
 *
 *   ① **比较的是序列化后的记录**，不是运行时对象。
 *      运行时对象里有很多「序列化时会被丢掉或抹平」的东西：`undefined` 字段、
 *      定点累加的浮点噪声（`0.30000000000000004` 这种）、没声明进 schema 的临时量。
 *      拿它们比对，增量会**永远非空**（白费全部带宽），而「正确地非空」与
 *      「错误地非空」在日志里长得一模一样。所以两边都先过 `normalizeSnapshot`
 *      （与 `sceneToJson` 同一套 1e-9 量化），再比。
 *
 *   ② **节点身份 = `id`，组件身份 = `type`，粒度 = 顶层 10 个字段各自独立 +
 *      组件整体。**
 *      · 顶层字段（`NODE_FIELDS`）变哪个发哪个：移动只发 `x` / `y`，改名只发 `name`。
 *      · 组件按 `data` 深比，变了就**整块重发**那一个组件。不拆到字段级：组件数据
 *        通常只有几十字节，而字段级要多表达一种「删掉一个键」的编码
 *        （JSON 里缺键与键值为 `null` 是两件事），复杂度全花在不省带宽的地方。
 *
 *   ③ **删除必须显式列**（`removed`）。不能靠「没出现在增量里」推断 —— 增量本来就
 *      稀疏，那样推断出来的删除会是场上所有没动的东西。
 *
 *   ④ **`parent` 变化只算这个节点的变化**，不算整棵子树：客户端是整场重装
 *      （`loadScene` 三遍装配），父变了它自然按新父挂回去。
 *
 *   ⑤ **空增量照发**，不合并到下一拍。`seq` 与 `tick` 是「你的世界停在第几拍」的唯一
 *      证据；省掉一份空增量，下次缺口诊断就会把它算成丢包。
 *
 *   ⑥ **两次快照之间「加了又删」的节点不会出现**，改了又改回去的字段也不会出现 ——
 *      这是对的：增量描述的是**状态差**，不是事件流。
 *
 * ★★ 一条边界：**增量只在数据层合成，世界层仍然是整场替换**
 *
 *   客户端拿到增量之后不是去改场景，而是 `applyDelta` 合成一份完整快照，再
 *   `loadScene`（整场替换）。这条边界是批152 立的（只有主机改世界），破了它就会出现
 *   「两套增量修改逻辑各差一个字段」的漂移，而症状是客户端某个字段永远停在旧值。
 *   代价诚实地说：**客户端每收一份快照的 CPU 代价仍然是 O(节点数)**，省下的是带宽，
 *   不是装载时间。
 *
 * ★ 与 `scene-io.ts` 的分工：那边负责「一棵树怎么变成确定的字节」，这边负责
 *   「两棵树之间差了什么」以及「差怎么合回去」。量化函数**只有一份**
 *   （`quantizeSave`，从 scene-io 借），两边各写一份的那天，增量会开始报假变化。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { Scene } from "../../core/scene/scene.ts";
import {
  quantizeSave,
  saveScene,
  type ComponentRecord,
  type NodeRecord,
  type SceneSnapshot,
} from "../../core/scene/scene-io.ts";

/** 增量的格式版本。形状一变就 +1（它与 `SCENE_FORMAT_VERSION` 是两件事）。 */
export const DELTA_FORMAT_VERSION = 1;

/**
 * 顶层字段表。`id` **不在里面**：它就是节点的身份，不是它的内容。
 *
 * ★ 顺序即编码顺序。加一个字段时只改这一处 —— 分成「比对用一份、合并用一份」的那天，
 *   一定会有一份被漏掉，症状是「某个字段在客户端永远不更新，而其余字段都对」。
 */
export const NODE_FIELDS = [
  "name",
  "parent",
  "x",
  "y",
  "rot",
  "sx",
  "sy",
  "zIndex",
  "active",
  "layer",
] as const;

export type NodeField = (typeof NODE_FIELDS)[number];

/** 只含变了的那些字段。合并时直接展开（`{...old, ...fields}`），所以「变慢 null」也表达得出来。 */
export type PatchFields = Partial<Pick<NodeRecord, NodeField>>;

export interface NodePatch {
  readonly id: number;
  readonly fields: PatchFields;
  /** 新增或内容变了的组件（按 `type`，整体替换）。没变时省略。 */
  readonly components?: readonly ComponentRecord[];
  /** 从节点上摘掉的组件类型（`type` 升序）。没删时省略。 */
  readonly dropComponents?: readonly string[];
}

export interface SnapshotDelta {
  readonly format: number;
  /** 基线里没有的节点（完整记录）。 */
  readonly added: readonly NodeRecord[];
  /** 已存在节点的部分更新（`id` 升序）。 */
  readonly patched: readonly NodePatch[];
  /** 基线里有、现在没了的节点 id（升序）。 */
  readonly removed: readonly number[];
}

// ---------------------------------------------------------------- 规范化

/**
 * 把任意 JSON 值收成「序列化之后的形态」：数字过 `quantizeSave`、丢掉 `undefined` 键、
 * 键按升序（与 `sceneToJson` 的 `stringifySorted` 同规）。
 *
 * ★ 键序也归一并**不只是为了好看**：判定相等用的是结构比对，键序不影响；但把两边都
 *   归一之后，`sameJson` 里那条「键数不同就一定不等」才站得住 —— 而它正是删掉一个
 *   组件字段时唯一的证据。
 */
export function normalizeValue(v: unknown): unknown {
  if (typeof v === "number") return quantizeSave(v);
  if (Array.isArray(v)) return v.map(normalizeValue);
  if (v !== null && typeof v === "object") {
    const src = v as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(src).sort()) {
      const val = src[k];
      if (val === undefined) continue;
      out[k] = normalizeValue(val);
    }
    return out;
  }
  return v;
}

function normalizeRecord(n: NodeRecord): NodeRecord {
  const components: ComponentRecord[] = n.components
    .map((c) => ({ type: c.type, data: normalizeValue(c.data) as Record<string, unknown> }))
    .sort((a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1 : 0));
  return {
    id: n.id,
    name: n.name,
    parent: n.parent,
    x: quantizeSave(n.x),
    y: quantizeSave(n.y),
    rot: quantizeSave(n.rot),
    sx: quantizeSave(n.sx),
    sy: quantizeSave(n.sy),
    zIndex: n.zIndex,
    active: n.active,
    layer: n.layer,
    components,
  };
}

/**
 * 规范形态：数值已量化、节点按 `id` 升序、组件按 `type` 升序。
 *
 * ★ 这一段**必须在比较前做**（文件头 ①）。`saveScene` 出来的 `x` 是累加出来的
 *   double（`7.269531249999999`），量化后是 `7.26953125` —— 两个世界逐字节相同，
 *   未量化的比对却会报「变了」，于是每拍都发全量，而带宽数字看起来只是「优化没效果」。
 */
export function normalizeSnapshot(snap: SceneSnapshot): SceneSnapshot {
  const nodes = snap.nodes.map(normalizeRecord).sort((a, b) => a.id - b.id);
  return { format: snap.format, name: snap.name, nodes };
}

/**
 * 场景 → 规范快照（**网络快照用回滚语义**，见 `session.ts` 文件头）。
 *
 * ★ 主机侧只该用这一个入口取「此刻的世界」：全量时它是发出去的内容，增量时它是
 *   diff 的目标与下一份的基线。两处各拍一次的话，同一拍里世界被改过（比如 `onJoin`
 *   刚给了归属）就会出现「发出去的全量与基线不一致」，而症状是客户端下一次增量
 *   对不上、被当成乱序丢掉。
 */
export function snapshotOfScene(scene: Scene): SceneSnapshot {
  return normalizeSnapshot(saveScene(scene, { mode: "rollback" }));
}

// ---------------------------------------------------------------- 比较

/** 结构相等（只用于「已经归一过」的 JSON 值）。 */
function sameJson(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!sameJson(a[i], b[i])) return false;
    return true;
  }
  if (a !== null && b !== null && typeof a === "object" && typeof b === "object") {
    const ra = a as Record<string, unknown>;
    const rb = b as Record<string, unknown>;
    const ka = Object.keys(ra);
    if (ka.length !== Object.keys(rb).length) return false;
    for (const k of ka) {
      if (!Object.prototype.hasOwnProperty.call(rb, k)) return false;
      if (!sameJson(ra[k], rb[k])) return false;
    }
    return true;
  }
  return false;
}

function patchOf(old: NodeRecord, now: NodeRecord): NodePatch | null {
  const fields: PatchFields = {};
  let touched = false;
  for (const k of NODE_FIELDS) {
    if (!sameJson(old[k], now[k])) {
      (fields as Record<string, unknown>)[k] = now[k];
      touched = true;
    }
  }

  const before = new Map<string, Readonly<Record<string, unknown>>>();
  for (const c of old.components) before.set(c.type, c.data);
  const components: ComponentRecord[] = [];
  for (const c of now.components) {
    const prev = before.get(c.type);
    if (prev === undefined || !sameJson(prev, c.data)) components.push(c);
    before.delete(c.type);
  }
  // 走完上面之后 `before` 里剩下的就是「旧有新无」的类型。用这个差集而不是再建一张表：
  // 两份表各自维护时，删组件的那一侧永远先忘掉一处。
  const dropComponents = [...before.keys()].sort();

  if (!touched && components.length === 0 && dropComponents.length === 0) return null;
  const out: NodePatch = { id: now.id, fields };
  const withComponents = components.length === 0 ? out : { ...out, components };
  return dropComponents.length === 0 ? withComponents : { ...withComponents, dropComponents };
}

/**
 * 两份**规范快照**之差。
 *
 * ★ 输入必须是 `normalizeSnapshot` 的产物（主机侧就是 `snapshotOfScene`）。
 *   传原始 `saveScene` 的输出不会崩，但会让量化噪声变成假变化 —— 见文件头 ①。
 */
export function diffSnapshot(prev: SceneSnapshot, next: SceneSnapshot): SnapshotDelta {
  const old = new Map<number, NodeRecord>();
  for (const n of prev.nodes) old.set(n.id, n);

  const added: NodeRecord[] = [];
  const patched: NodePatch[] = [];
  for (const n of next.nodes) {
    const before = old.get(n.id);
    if (before === undefined) {
      added.push(n);
      continue;
    }
    old.delete(n.id);
    const p = patchOf(before, n);
    if (p !== null) patched.push(p);
  }
  // 同 `patchOf` 里那条：走到这里 `old` 里剩下的就是被删掉的节点。
  const removed = [...old.keys()].sort((a, b) => a - b);
  return { format: DELTA_FORMAT_VERSION, added, patched, removed };
}

export function deltaIsEmpty(d: SnapshotDelta): boolean {
  return d.added.length === 0 && d.patched.length === 0 && d.removed.length === 0;
}

// ---------------------------------------------------------------- 合成

export interface DeltaApply {
  readonly snap: SceneSnapshot;
  /**
   * 对不上基线的条数：补丁指向基线里没有的节点、删除基线里没有的节点、
   * 新增基线里已有的节点。
   *
   * ★ 大于 0 就是「这份增量不是给这个基线的」，**不许**当没事发生直接合 ——
   *   合出来的世界看起来完整（节点一个不少），但某个字段会是旧的，而游戏里
   *   那只表现为「这个箱子打不开」。调用方应当重同步，见 `session.ts`。
   */
  readonly orphans: number;
}

function mergeNode(old: NodeRecord, p: NodePatch): NodeRecord {
  const drop = new Set(p.dropComponents ?? []);
  const byType = new Map<string, ComponentRecord>();
  for (const c of old.components) if (!drop.has(c.type)) byType.set(c.type, c);
  for (const c of p.components ?? []) byType.set(c.type, c);
  const components = [...byType.values()].sort((a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1 : 0));
  return { ...old, ...p.fields, components };
}

/**
 * 基线 + 增量 → 新快照。**纯函数**（不改 `base`，也不看世界）。
 *
 * ★ 结果按 `id` 排序、组件按 `type` 排序：`loadScene` 会自己排，但
 *   `sceneToJson` **不会**（它按 `nodes` 给的顺序写）。顺序不同 ⇒ 同一份世界写出
 *   不同字节 ⇒ 「客户端与主机逐字节一致」那条判据会红在一个与增量无关的地方。
 */
export function applyDelta(base: SceneSnapshot, d: SnapshotDelta): DeltaApply {
  const byId = new Map<number, NodeRecord>();
  for (const n of base.nodes) byId.set(n.id, n);

  let orphans = 0;
  for (const id of d.removed) if (!byId.delete(id)) orphans++;
  for (const n of d.added) {
    if (byId.has(n.id)) orphans++;
    byId.set(n.id, n);
  }
  for (const p of d.patched) {
    const old = byId.get(p.id);
    if (old === undefined) {
      orphans++;
      continue;
    }
    byId.set(p.id, mergeNode(old, p));
  }

  const nodes = [...byId.values()].sort((a, b) => a.id - b.id);
  return { snap: { format: base.format, name: base.name, nodes }, orphans };
}

// ---------------------------------------------------------------- 编解码

/**
 * 增量 → 文本。
 *
 * ★ 空字段/空组件故意**省略键**而不是写 `{}` / `[]`：一份「只有一个角色挪了」
 *   的增量是 40 来字节，写成带空数组的形状就是 90 来字节，而这条路径每拍都走。
 */
export function deltaToJson(d: SnapshotDelta): string {
  const patched = d.patched.map((p) => {
    const o: Record<string, unknown> = { id: p.id, fields: p.fields };
    if (p.components !== undefined) o.components = p.components;
    if (p.dropComponents !== undefined) o.dropComponents = p.dropComponents;
    return o;
  });
  return JSON.stringify({ format: d.format, added: d.added, patched, removed: d.removed });
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function isInt(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v);
}

/** 一条完整节点记录的形状（网络数据可以是任何形状，这里不放行）。 */
function validRecord(v: unknown): v is NodeRecord {
  if (!isRecord(v)) return false;
  if (!isInt(v.id) || typeof v.name !== "string") return false;
  if (!(v.parent === null || isInt(v.parent))) return false;
  for (const k of ["x", "y", "rot", "sx", "sy"] as const) {
    if (typeof v[k] !== "number" || !Number.isFinite(v[k])) return false;
  }
  if (!isInt(v.zIndex) || typeof v.active !== "boolean" || !isInt(v.layer)) return false;
  const comps = v.components;
  if (!Array.isArray(comps)) return false;
  for (const c of comps) {
    if (!isRecord(c) || typeof c.type !== "string" || !isRecord(c.data)) return false;
  }
  return true;
}

function validPatch(v: unknown): v is NodePatch {
  if (!isRecord(v) || !isInt(v.id) || !isRecord(v.fields)) return false;
  const fields = v.fields as Record<string, unknown>;
  for (const k of Object.keys(fields)) {
    if (!(NODE_FIELDS as readonly string[]).includes(k)) return false;
  }
  const comps = v.components;
  if (comps !== undefined) {
    if (!Array.isArray(comps)) return false;
    for (const c of comps) {
      if (!isRecord(c) || typeof c.type !== "string" || !isRecord(c.data)) return false;
    }
  }
  const drop = v.dropComponents;
  if (drop !== undefined) {
    if (!Array.isArray(drop)) return false;
    for (const t of drop) if (typeof t !== "string") return false;
  }
  return true;
}

/**
 * 文本 → 增量。坏数据返回 `Result`（会话拿它计数并**重同步**，不抛）。
 *
 * ★ 版本比本端新时给专门的错误码：形状不同的一坨数据若是被「尽量理解」地读进来，
 *   症状是客户端某几个字段永远不更新 —— 那比直接拒绝难查一个量级。
 */
export function deltaFromJson(text: string): Result<SnapshotDelta, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return err(engineError("NET.DELTA_BAD", `增量快照不是合法 JSON：${e instanceof Error ? e.message : String(e)}`));
  }
  if (!isRecord(raw)) return err(engineError("NET.DELTA_BAD", "增量快照不是对象"));
  if (!isInt(raw.format)) return err(engineError("NET.DELTA_BAD", "增量快照缺少 format"));
  if (raw.format > DELTA_FORMAT_VERSION) {
    return err(
      engineError("NET.DELTA_TOO_NEW", `增量格式 v${String(raw.format)} 高于本端支持的 v${String(DELTA_FORMAT_VERSION)}`),
    );
  }
  if (raw.format !== DELTA_FORMAT_VERSION) {
    return err(engineError("NET.DELTA_BAD", `增量格式 v${String(raw.format)} 不认识（只支持 v${String(DELTA_FORMAT_VERSION)}）`));
  }
  const added = raw.added;
  const patched = raw.patched;
  const removed = raw.removed;
  if (!Array.isArray(added) || !Array.isArray(patched) || !Array.isArray(removed)) {
    return err(engineError("NET.DELTA_BAD", "增量快照缺少 added / patched / removed"));
  }
  const addOut: NodeRecord[] = [];
  for (const n of added) {
    if (!validRecord(n)) return err(engineError("NET.DELTA_BAD", "added 里有一条不是节点记录"));
    addOut.push(n);
  }
  const patchOut: NodePatch[] = [];
  for (const p of patched) {
    if (!validPatch(p)) return err(engineError("NET.DELTA_BAD", "patched 里有一条形状不对"));
    patchOut.push(p);
  }
  const removedOut: number[] = [];
  for (const id of removed) {
    if (!isInt(id)) return err(engineError("NET.DELTA_BAD", "removed 里有一个不是整数 id"));
    removedOut.push(id);
  }
  return ok({ format: DELTA_FORMAT_VERSION, added: addOut, patched: patchOut, removed: removedOut });
}
