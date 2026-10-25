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

/**
 * 单个节点 → 记录。
 *
 * ★ 抽出来是为了让**编辑器撤销**能只拍一棵子树的快照，而不用为了一个节点
 *   把整个场景序列化一遍（`saveScene` 在 500 节点的场景里是 O(n) 加全部组件
 *   `save()`）。两处共用同一份字段表，加字段不必改两个地方 —— 否则一定会有一处
 *   被漏掉，症状是「撤销删除之后 `layer` 回到了默认值」这种很难查的偏差。
 */
export function recordOf(scene: Scene, n: import("./node.ts").Node): NodeRecord {
  const comps: ComponentRecord[] = [];
  for (const c of [...n.components].sort((a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1 : 0))) {
    const saved = c.save();
    // save() 里带着 type（便于人读），记录里 type 已单独存，data 去掉它避免重复
    const { type: _t, ...rest } = saved as { type?: unknown } & Record<string, unknown>;
    void _t;
    comps.push({ type: c.type, data: rest });
  }
  return {
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
  };
}

export function saveScene(scene: Scene): SceneSnapshot {
  const nodes: NodeRecord[] = [];
  for (const n of collectNodes(scene)) nodes.push(recordOf(scene, n));
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
    try {
      parent.addChild(child);
    } catch (e) {
      // ★ 存档里如果有环（手改过、或某版引擎写坏了），核心层的环检查会抛。
      //   读档是**不可抛**的边界（它返回 Result）：一次读档不该把宿主进程炸掉，
      //   而且"只跳过坏的那条父子关系"比"整档读失败"更接近用户想要的结果。
      skipped.push(`节点 #${r.id} 的父子关系不成立：${e instanceof Error ? e.message : String(e)}`);
    }
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

/**
 * 读存档：**先过 Schema 的版本闸门**，再做结构校验。
 *
 * ★ 修掉的两个静默缺陷（都是"看着接上了、其实没接"）：
 *  ① 以前这里只 `JSON.parse` + 手查 `format`/`nodes`，**从不看版本上下限** ——
 *     一份 `format: 0` 的旧档会被当成当前版本读进来（然后组件按今天的字段解释旧数据，
 *     错得很安静）。版本闸门只写在 `loadScene` 里，而调用方完全可能只解析不加载。
 *  ② `SCENE_SCHEMA` 早就声明了迁移链入口，但没人调用它；而且 `Schema` 读的是 `__v`，
 *     场景写的却是 `format`。于是"迁移入口"既没被调用、调用了也读不到版本。
 * 现在两件事合成一件：`SCENE_SCHEMA.decode` 既解析又迁移，`format` 通过 `versionKey` 声明。
 *
 * 错误码仍按场景域返回（调用方按 `SCENE.*` 分支，不需要知道 `Schema` 的存在）。
 */
export function sceneFromJson(text: string): Result<SceneSnapshot, EngineError> {
  const dec = SCENE_SCHEMA.decode(text);
  if (!dec.ok) {
    switch (dec.error.code) {
      case "SER.VERSION_TOO_NEW":
        return err(engineError("SCENE.FORMAT_TOO_NEW", dec.error.message));
      case "SER.NO_MIGRATION":
        return err(engineError("SCENE.FORMAT_NO_MIGRATION", dec.error.message));
      case "SER.BAD_VERSION":
        return err(engineError("SCENE.FORMAT_BAD", dec.error.message));
      default:
        return err(engineError("SCENE.BAD_JSON", dec.error.message));
    }
  }
  const o = dec.value as { format?: unknown; name?: unknown; nodes?: unknown };
  if (typeof o.format !== "number" || !Array.isArray(o.nodes)) {
    return err(engineError("SCENE.BAD_JSON", "缺少 format 或 nodes"));
  }
  return ok({
    // 迁移过的记录已经是当前版本；写 v1 档读回来也是 v1，所以这里恒等于 SCENE_FORMAT_VERSION
    format: SCENE_FORMAT_VERSION,
    name: typeof o.name === "string" ? o.name : "scene",
    nodes: o.nodes as NodeRecord[],
  });
}

/**
 * 存档里的数值量化：**1e-9**（9 位小数）。
 *
 * ★★ 这里原本是 `Math.round(v * 1000) / 1000`（3 位）。2026-10-23 抓到真 bug：
 *   世界坐标的定点单位是 `FIXED_UNITS = 256`，即 `1/256 = 0.00390625` —— **8 位十进制小数**。
 *   3 位装不下它：装配出来的 `7.26953125` 存成 `7.27`，反推 `7.27 * 256 = 1861.12`（原本 1861）。
 *   症状隐蔽到极点：挪了 1/2000 格，肉眼看不出、玩起来看不出，
 *   只有 `sceneDigest()`（它要求整数）或两个世界的逐字节比对才看得见。
 *
 * 为什么是 9 位：
 *   ① 必须能**精确**表示 `1/256`（8 位）⇒ 至少 8 位，取 9 位留一位余量；
 *   ② 必须粗于 double 在游戏坐标量级的 ulp（2^-52），否则等于没量化 —— 1e-9 远粗于它，
 *      于是"累加出来的 9.999999999999984"会被收成 `10`、"5 秒后剩的 7.7e-15"会被收成 `0`。
 *      存档是**快照**，不是累加过程的日志：把 ulp 级噪声写进存档只会让逐字节比对变脆；
 *   ③ 十进制量化不会给十进制写出来的值留尾巴（`1.387` 还是 `1.387`）——
 *      若改成"2 的幂量化"，`1.387` 会变成 `1.3870086669921875`，存档立刻不可读。
 *
 * ★★ 这条量化有一个**跨层约束**：它只对 `FIXED_UNITS ≤ 512` 的定点精确
 *   （`1/512 = 0.001953125` 仍是 9 位；`1/1024` 就是 10 位了）。
 *   分层规则不许 L2 依赖 L4，所以这条约束**没法用类型表达** ——
 *   它由 `tests/extensions/assemble-io.test.ts` 里的一条守卫判据钉住：
 *   谁把 `FIXED_UNITS` 改大，那条会先红，提示改成 2 的幂量化。
 *   （这类"只能靠判据表达的跨层约束"在本项目里不止一处，见 `§11.3`。）
 */
const SAVE_SCALE = 1e9;
/** |v| 超过这个值时 v * 1e9 会越过安全整数，此时不量化（宁可原样写，也不要算错）。 */
const SAVE_SCALE_LIMIT = 1e6;

function q(v: number): number {
  if (!Number.isFinite(v)) return v;
  if (!(Math.abs(v) < SAVE_SCALE_LIMIT)) return v;
  return Math.round(v * SAVE_SCALE) / SAVE_SCALE;
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
 * 整棵树的版本闸门（**真的在用**，不是"入口留好"）。
 *
 * 目前只有 v1，所以迁移链是空的 —— 但空链不等于空转：
 *   · `version < 当前` 的档会走迁移；没有对应函数时报 `SCENE.FORMAT_NO_MIGRATION`
 *     （以前是静默当当前版本读）；
 *   · 将来把 `SCENE_FORMAT_VERSION` 改成 2 而忘了写迁移，`Schema` 构造时就会抛
 *     （而不是等用户拿旧档来读时才炸）。
 *
 * ★ `fields` 里**不含** `format`：版本键由 `versionKey` 负责，写进 fields 会让
 *   `encode` 输出两个 `"format"` 键（后者覆盖前者，看起来还对，json 解析也接受）。
 */
export const SCENE_SCHEMA = new Schema({
  version: SCENE_FORMAT_VERSION,
  fields: ["name", "nodes"],
  versionKey: "format",
});

export type { Scene };
export { isFastForwardable };
