/**
 * L2 · 场景存档（确定性序列化）
 *
 * 目标是"存一次、读一次、再存一次，得到**逐字节相同**的文件"。
 *
 * ★ 三条必须做对的：
 *
 * ① **节点按 id 升序、组件按 type 升序**输出。
 *    不排序的话，输出顺序取决于 `Map` 的插入序 —— 而插入序取决于加载顺序，
 *    加载顺序将来可能并行化。那时"同样的世界存出两份不同文件"会变成幽灵 bug。
 *
 * ② **先建全部节点，再设父子，最后挂组件**（三遍）。
 *    一遍做不到：子节点可能比父节点先出现在记录里；
 *    组件可能引用"还没建出来的节点"。
 *
 * ③ **坏记录不静默跳过**：未知组件类型、缺失父节点都要**收集并报出来**，
 *    返回 `{ made, skipped }`。静默跳过 = 存档悄悄丢内容，而玩家只会觉得"少了个箱子"。
 *
 * ★ 与 `Schema` 的分工：
 *   `Schema` 负责**单个对象**的字段级确定性（字段序、浮点量化、NaN 标记）；
 *   本文件负责**整棵树**的结构序与装配顺序。两层各管一件事，不重复实现。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { ComponentRegistry } from "./component.ts";
import { isFastForwardable } from "./component.ts";
import type { Scene } from "./scene.ts";
import { Schema } from "../serialization/schema.ts";

export const SCENE_FORMAT_VERSION = 1;

export interface ComponentRecord {
  readonly type: string;
  readonly data: Readonly<Record<string, unknown>>;
}

export interface NodeRecord {
  readonly id: number;
  readonly name: string;
  /** `null` 表示直接挂在场景根下。 */
  readonly parent: number | null;
  readonly x: number;
  readonly y: number;
  readonly rot: number;
  readonly sx: number;
  readonly sy: number;
  readonly zIndex: number;
  readonly active: boolean;
  readonly layer: number;
  readonly components: readonly ComponentRecord[];
}

export interface SceneSnapshot {
  readonly format: number;
  readonly name: string;
  readonly nodes: readonly NodeRecord[];
}

/** 取全场景节点（不含 root 本身）。顺序：id 升序（确定性）。 */
export function collectNodes(scene: Scene): Array<import("./node.ts").Node> {
  const out: Array<import("./node.ts").Node> = [];
  scene.root.walk((n) => {
    if (n.id !== scene.rootId) out.push(n);
  });
  out.sort((a, b) => a.id - b.id);
  return out;
}

export function saveScene(scene: Scene): SceneSnapshot {
  const nodes: NodeRecord[] = [];
  for (const n of collectNodes(scene)) {
    const comps: ComponentRecord[] = [];
    for (const c of [...n.components].sort((a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1 : 0))) {
      const saved = c.save();
      // save() 里带着 type（便于人读），记录里 type 已单独存，data 去掉它避免重复
      const { type: _t, ...rest } = saved as { type?: unknown } & Record<string, unknown>;
      void _t;
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
      components: comps,
    });
  }
  return { format: SCENE_FORMAT_VERSION, name: scene.name, nodes };
}

export interface LoadReport {
  readonly made: number;
  readonly skipped: readonly string[];
  /** 组件 `load` 报出的缺失字段（旧版本存档会缺字段）。 */
  readonly missingFields: readonly string[];
}

/**
 * 从快照重建世界。**会先清空**（与"打开一个关卡"的语义一致）。
 *
 * 三遍装配：建节点 → 设父子 → 挂组件。
 */
export function loadScene(
  scene: Scene,
  snap: SceneSnapshot,
  registry: ComponentRegistry,
): Result<LoadReport, EngineError> {
  if (snap.format > SCENE_FORMAT_VERSION) {
    return err(
      engineError(
        "SCENE.FORMAT_TOO_NEW",
        `存档格式 v${snap.format} 高于引擎支持的 v${SCENE_FORMAT_VERSION}（用新引擎写的档，旧引擎不能读）`,
      ),
    );
  }
  const skipped: string[] = [];
  const missingFields: string[] = [];

  scene.clear();

  // 第 1 遍：建节点（只挂着 root，父子关系下一遍设）
  const built = new Map<number, import("./node.ts").Node>();
  const records = [...snap.nodes].sort((a, b) => a.id - b.id);
  for (const r of records) {
    try {
      const n = scene.spawnImmediate(r.name, r.id === 0 ? null : scene.rootId, r.id);
      // ★ 一律走 setter：直接赋 `localPosition/localScale` 字段**不推进版本号**，
      //   于是世界变换会继续用旧缓存（症状：读档后实体的世界坐标还是存档前的）。
      n.setLocalPosition(r.x, r.y);
      n.setLocalRotation(r.rot);
      n.setLocalScale(r.sx, r.sy);
      n.zIndex = r.zIndex;
      n.active = r.active;
      n.layer = r.layer;
      n.markTransformDirty();
      built.set(r.id, n);
    } catch (e) {
      skipped.push(`节点 #${r.id}（${r.name}）：${e instanceof Error ? e.message : String(e)}`);
    }
  }

  // 第 2 遍：父子
  for (const r of records) {
    if (r.parent === null) continue;
    const child = built.get(r.id);
    const parent = built.get(r.parent);
    if (child === undefined) continue;
    if (parent === undefined) {
      skipped.push(`节点 #${r.id} 的父节点 #${r.parent} 不存在（该节点被挂到根下）`);
      continue;
    }
    parent.addChild(child);
  }

  // 第 3 遍：组件
  for (const r of records) {
    const n = built.get(r.id);
    if (n === undefined) continue;
    for (const cr of r.components) {
      if (!registry.has(cr.type)) {
        skipped.push(`节点 #${r.id} 的组件 ${cr.type} 未注册（跳过）`);
        continue;
      }
      const c = registry.create(cr.type);
      if (c === undefined) {
        skipped.push(`节点 #${r.id} 的组件 ${cr.type} 工厂返回 undefined（跳过）`);
        continue;
      }
      const res = c.load(cr.data);
      for (const f of res.missing) missingFields.push(`#${r.id}.${cr.type}.${f}`);
      scene.attach(n.id, () => c);
    }
  }
  scene.flush();

  return ok({ made: built.size, skipped, missingFields });
}

/**
 * 场景 → 文本（整棵树用一个 Schema 包起来，保证字段序与量化统一）。
 * ★ 用 `JSON.stringify` 而不是 `Schema.encode` 的字段表：
 *   节点是可变的列表，逐节点声明字段表只会让"加一个字段要改两处"。
 *   这里靠**构造顺序**（id 升序 + type 升序）保证确定性，并用 `stableHash` 自检。
 */
export function sceneToJson(snap: SceneSnapshot): string {
  const lines: string[] = [];
  lines.push(`{"format":${snap.format},"name":${JSON.stringify(snap.name)},"nodes":[`);
  snap.nodes.forEach((n, i) => {
    const comps = n.components
      .map((c) => `{"type":${JSON.stringify(c.type)},"data":${stringifySorted(c.data)}}`)
      .join(",");
    const rec =
      `{"id":${n.id},"name":${JSON.stringify(n.name)},"parent":${n.parent === null ? "null" : n.parent},` +
      `"x":${q(n.x)},"y":${q(n.y)},"rot":${q(n.rot)},"sx":${q(n.sx)},"sy":${q(n.sy)},` +
      `"zIndex":${n.zIndex},"active":${n.active},"layer":${n.layer},"components":[${comps}]}`;
    lines.push(rec + (i === snap.nodes.length - 1 ? "" : ","));
  });
  lines.push("]}");
  return lines.join("");
}

export function sceneFromJson(text: string): Result<SceneSnapshot, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return err(engineError("SCENE.BAD_JSON", `不是合法 JSON：${e instanceof Error ? e.message : String(e)}`));
  }
  if (raw === null || typeof raw !== "object") {
    return err(engineError("SCENE.BAD_JSON", "顶层不是对象"));
  }
  const o = raw as { format?: unknown; name?: unknown; nodes?: unknown };
  if (typeof o.format !== "number" || !Array.isArray(o.nodes)) {
    return err(engineError("SCENE.BAD_JSON", "缺少 format 或 nodes"));
  }
  return ok({
    format: o.format,
    name: typeof o.name === "string" ? o.name : "scene",
    nodes: o.nodes as NodeRecord[],
  });
}

function q(v: number): number {
  return Math.round(v * 1000) / 1000;
}

/** 键排序的对象序列化（嵌套也排）。 */
function stringifySorted(o: unknown): string {
  if (o === null || typeof o !== "object") {
    return typeof o === "number" ? String(q(o)) : JSON.stringify(o);
  }
  if (Array.isArray(o)) return "[" + o.map(stringifySorted).join(",") + "]";
  const rec = o as Record<string, unknown>;
  const keys = Object.keys(rec).sort();
  const parts: string[] = [];
  for (const k of keys) {
    if (rec[k] === undefined) continue;
    parts.push(`${JSON.stringify(k)}:${stringifySorted(rec[k])}`);
  }
  return "{" + parts.join(",") + "}";
}

/**
 * 把"整棵树"也纳入 Schema 的版本迁移链（将来加字段时用）。
 * 目前只有 v1，所以没有迁移函数 —— 但入口留好，避免"以后再说"变成"直接改格式"。
 */
export const SCENE_SCHEMA = new Schema({
  version: SCENE_FORMAT_VERSION,
  fields: ["format", "name", "nodes"],
});

export type { Scene };
export { isFastForwardable };
