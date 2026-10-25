/**
 * L4 · 编辑器：属性面板模型（schema → 控件 + 输入强转）
 *
 * 这一层解决的是「**人在输入框里打的东西**」与「**组件字段声明的类型**」之间的落差。
 * 三条决定：
 *
 * ① 字段顺序 = `schema.fields` 的声明顺序，**不排序**。
 *    schema 的注释写得很清楚：「顺序即序列化顺序（保证字节确定）」。
 *    面板按字母序出字段，会让人觉得「面板上的顺序和存档里的顺序是两回事」——
 *    而实际上它们是同一件事，一旦有人照着面板顺序改 schema，存档字节就变了。
 *
 * ② 强转**只接受无损输入**。`Int` 字段收到 `"3.5"` 要报错，不是取整：
 *    静默截断之后，人以为自己在设 3.5（并且会奇怪为什么属性没变），
 *    而实际值 3 已经写进去了。这与批61 里「小数伤害直接拒绝」是同一条理由。
 *
 * ③ 校验失败**一个字节都不写**。`setField` 先 `coerce`、后赋值，
 *    顺序反过来的话失败路径会留下半改的状态 —— 而属性面板是最容易
 *    「一边打一边写」的地方（每敲一个字符刷一次）。
 *
 * 另外：`NodeRef` 接受数字 id（编辑器从树上点一个节点拿到的就是数字），
 * 而 `Asset` 只接受字符串 —— 资产的 GUID 是字符串，把数字塞进去是纯粹的错。
 */

import {
  FieldType,
  zeroValue,
  type Component,
  type FieldTypeValue,
} from "../../core/scene/component.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { Scene } from "../../core/scene/scene.ts";
import type { NodeId } from "../../core/scene/node.ts";

/** 节点/组件/字段不存在。 */
export const EDIT_BAD_FIELD = "EDIT.BAD_FIELD";
/** 输入的值不能无损转成该字段声明类型。 */
export const EDIT_BAD_VALUE = "EDIT.BAD_VALUE";

export type FieldControl = "number" | "checkbox" | "text" | "vec2" | "color" | "asset" | "noderef" | "tags";

export interface EditableField {
  readonly key: string;
  readonly type: FieldTypeValue;
  readonly control: FieldControl;
  readonly value: unknown;
}

export function controlOf(t: FieldTypeValue): FieldControl {
  switch (t) {
    case FieldType.Int:
    case FieldType.Float:
    case FieldType.Double:
      return "number";
    case FieldType.Bool:
      return "checkbox";
    case FieldType.String:
      return "text";
    case FieldType.Vec2:
      return "vec2";
    case FieldType.Color:
      return "color";
    case FieldType.Asset:
      return "asset";
    case FieldType.NodeRef:
      return "noderef";
    case FieldType.StringArray:
      return "tags";
    default:
      return "text";
  }
}

/** 组件 → 可编辑字段（按 schema 声明顺序；实例上缺字段时用类型零值）。 */
export function fieldsOf(comp: Component): EditableField[] {
  const bag = comp as unknown as Record<string, unknown>;
  const out: EditableField[] = [];
  for (const [key, type] of Object.entries(comp.schema.fields)) {
    const v = bag[key];
    out.push({ key, type, control: controlOf(type), value: v === undefined ? zeroValue(type) : v });
  }
  return out;
}

function numberOf(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string") {
    const t = v.trim();
    if (t === "") return null;
    const n = Number(t);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function bad(t: FieldTypeValue, raw: unknown, want: string): Result<never, EngineError> {
  return err(
    engineError(EDIT_BAD_VALUE, `字段类型 ${t} 要的是${want}，收到 ${describe(raw)}`),
  );
}

function describe(v: unknown): string {
  if (typeof v === "string") return `「${v}」`;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (v === null) return "null";
  if (Array.isArray(v)) return `数组(${String(v.length)})`;
  return typeof v;
}

/** 输入 → 该字段类型的值。**无损**：转不过去就报错，绝不静默取整/截断。 */
export function coerce(type: FieldTypeValue, raw: unknown): Result<unknown, EngineError> {
  switch (type) {
    case FieldType.Int: {
      const n = numberOf(raw);
      if (n === null || !Number.isInteger(n)) return bad(type, raw, "整数（3.5 不会变成 3）");
      return ok(n);
    }
    case FieldType.Float:
    case FieldType.Double: {
      const n = numberOf(raw);
      if (n === null) return bad(type, raw, "有限数字（NaN / Infinity 不收）");
      return ok(n);
    }
    case FieldType.Bool: {
      if (typeof raw === "boolean") return ok(raw);
      if (typeof raw === "string") {
        const t = raw.trim();
        if (t === "true") return ok(true);
        if (t === "false") return ok(false);
      }
      return bad(type, raw, "true / false");
    }
    case FieldType.String: {
      if (typeof raw === "string") return ok(raw);
      return bad(type, raw, "字符串");
    }
    case FieldType.Vec2: {
      if (typeof raw === "string") {
        const parts = raw.split(",").map((s) => s.trim());
        if (parts.length !== 2) return bad(type, raw, "「x, z」两段");
        const x = numberOf(parts[0]!);
        const y = numberOf(parts[1]!);
        if (x === null || y === null) return bad(type, raw, "两个有限数字");
        return ok({ x, y });
      }
      if (typeof raw === "object" && raw !== null) {
        const o = raw as { x?: unknown; y?: unknown };
        const x = numberOf(o.x);
        const y = numberOf(o.y);
        if (x === null || y === null) return bad(type, raw, "{x, y} 两个有限数字");
        return ok({ x, y });
      }
      return bad(type, raw, "「x, z」或 {x, y}");
    }
    case FieldType.Color: {
      if (typeof raw === "string") {
        const m = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(raw.trim());
        if (m !== null) {
          let h = m[1]!;
          if (h.length === 3) h = [...h].map((c) => c + c).join("");
          const a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
          return ok({
            r: parseInt(h.slice(0, 2), 16) / 255,
            g: parseInt(h.slice(2, 4), 16) / 255,
            b: parseInt(h.slice(4, 6), 16) / 255,
            a,
          });
        }
        return bad(type, raw, "#rgb / #rrggbb / #rrggbbaa");
      }
      if (typeof raw === "object" && raw !== null) {
        const o = raw as { r?: unknown; g?: unknown; b?: unknown; a?: unknown };
        const r = numberOf(o.r);
        const g = numberOf(o.g);
        const b = numberOf(o.b);
        const a = o.a === undefined ? 1 : numberOf(o.a);
        if (r === null || g === null || b === null || a === null) return bad(type, raw, "{r,g,b,a} 数字");
        return ok({ r, g, b, a });
      }
      return bad(type, raw, "#rrggbb 或 {r,g,b,a}");
    }
    case FieldType.Asset: {
      if (typeof raw === "string") return ok(raw);
      return bad(type, raw, "资产 id 字符串（GUID，不是数字）");
    }
    case FieldType.NodeRef: {
      if (typeof raw === "string") return ok(raw);
      // 编辑器从树上点来的就是数字 id：这里按下标转成字符串，与 `zeroValue` 的口径一致
      if (typeof raw === "number" && Number.isInteger(raw)) return ok(String(raw));
      return bad(type, raw, "节点 id（字符串或整数）");
    }
    case FieldType.StringArray: {
      if (Array.isArray(raw)) {
        const out: string[] = [];
        for (const v of raw) {
          if (typeof v !== "string") return bad(type, raw, "字符串数组");
          out.push(v);
        }
        return ok(out);
      }
      if (typeof raw === "string") {
        return ok(
          raw
            .split(",")
            .map((s) => s.trim())
            .filter((s) => s.length > 0),
        );
      }
      return bad(type, raw, "字符串数组或逗号分隔的串");
    }
    default:
      return bad(type, raw, "已知的字段类型");
  }
}

export interface FieldChange {
  readonly before: unknown;
  readonly after: unknown;
  /**
   * 值是否**真的**变了。
   *
   * ★ 为什么要这一位：面板用 `change` 事件提交，人可能把 12 改成 120 又改回 12，
   *   或者直接聚了个焦又失焦。这些提交在数值上没变，但 `Vec2` / `Color` 是**对象**——
   *   重新 coerce 一次拿到的是新对象，`before !== after` 恒成立。
   *   撤销栈要是照着 `!==` 压，历史会被一堆「改了什么都没改」的条目填满，
   *   人按五次撤销都看不见场景变化，会以为撤销坏了。
   */
  readonly changed: boolean;
}

/**
 * 按字段类型的口径比较两个值（标量、字符串数组、`{x,y}`、`{r,g,b,a}`）。
 *
 * ★ 不用 `JSON.stringify` 比较：键序不同的两个同值对象（`{x,y}` 与 `{y,x}`）
 *   会判成不同，于是「没变」被判成「变了」。而键序在 coerce 之后是稳定的，
 *   一旦有人换个顺序构造对象，撤销栈就会凭空多出历史 —— 这类 bug 只在
 *   用户抱怨「撤销要点两下」时才暴露。
 */
export function valuesEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!valuesEqual(a[i], b[i])) return false;
    return true;
  }
  if (typeof a === "object" && a !== null && typeof b === "object" && b !== null) {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
      if (!valuesEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k])) return false;
    }
    return true;
  }
  return false;
}

/**
 * 改一个字段。先校验、后写 —— 失败时**组件一个字节都没动**。
 * 返回值里带 `before`，供撤销栈直接压一条命令（不必再读一遍旧值）。
 */
export function setField(
  scene: Scene,
  nodeId: NodeId,
  type: string,
  key: string,
  raw: unknown,
): Result<FieldChange, EngineError> {
  const node = scene.find(nodeId);
  if (node === undefined) return err(engineError(EDIT_BAD_FIELD, `节点 ${String(nodeId)} 不在场景里`));
  const comp = node.components.find((c) => c.type === type);
  if (comp === undefined) {
    return err(engineError(EDIT_BAD_FIELD, `节点 ${String(nodeId)}（${node.name}）上没有组件「${type}」`));
  }
  const declared = comp.schema.fields[key];
  if (declared === undefined) {
    return err(engineError(EDIT_BAD_FIELD, `组件「${type}」没有字段「${key}」`));
  }
  const c = coerce(declared, raw);
  if (!c.ok) return c;
  const bag = comp as unknown as Record<string, unknown>;
  const before = bag[key];
  bag[key] = c.value;
  return ok({ before, after: c.value, changed: !valuesEqual(before, c.value) });
}
