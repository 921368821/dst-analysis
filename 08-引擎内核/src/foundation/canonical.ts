/**
 * L0 · 规范化序列化与内容指纹
 *
 * 用途只有一个：给"同一份数据"算出**唯一**的字符串表示，进而算出一个可比对的指纹。
 * 现有两处用它：世界指纹（`extensions/worldgen`）、发布产物 manifest 的 hash（`extensions/build`）。
 *
 * ★ 为什么不能直接 `JSON.stringify` 了事：
 *   指纹的承诺是「同一份数据 ⇒ 同一个指纹，且**可跨进程/跨机器/跨次运行比对**」。
 *   而 `JSON.stringify` 会留下三种表示自由度，每一种都能让同一份数据算出两个指纹：
 *
 *   ① **键顺序**：`{a:1,b:2}` 与 `{b:2,a:1}` 语义相同，`stringify` 给的串不同。
 *      这不是理论风险 —— 只要有人把对象从 `Map` 里重建一遍，顺序就变了。
 *   ② **浮点格式**：`0.1+0.2` 与 `0.3` 在某些写法下最后一位不同；一旦数据里出现浮点，
 *      指纹就变成"看格式化心情"。
 *   ③ **静默降级**：`undefined` 在对象里被直接丢掉、在数组里变成 `null`；
 *      `NaN`/`Infinity` 变成 `null`。于是"字段缺失"和"字段是 null"、
 *      "数值算爆了"和"数值是 null"全都长一样，**不报错**。
 *
 * ★ 对策（三条都是"宁可报错也不猜"）：
 *   ① 键**排序后**再拼；
 *   ② **只允许整数**，且必须在 `Number.MAX_SAFE_INTEGER` 以内。
 *      需要小数的场合请用定点整数表示（世界坐标就是 1 格 = 256 单位）。
 *      出现非整数就报错，**不四舍五入** —— 四舍五入会把"我引入了浮点"这件事藏起来。
 *   ③ `undefined` / `null` / `NaN` / `±Infinity` / 类实例 / 函数 / 符号 一律报错。
 *      缺字段的正确表达是"不写这个键"，不是"写个 null"。
 *
 * ★ `-0`：`String(-0)` 是 `"0"`，与 `0` 同串。这是**想要的**：`-0` 和 `0` 在数据里
 *   没有区别，让它们分叉只会制造幽灵漂移。
 */

import type { EngineError, Result } from "./result.ts";
import { err, ok } from "./result.ts";
import { hashText } from "./hash.ts";

export const CANON_NOT_INTEGER = "CANON.NOT_INTEGER";
export const CANON_NOT_FINITE = "CANON.NOT_FINITE";
export const CANON_TOO_LARGE = "CANON.TOO_LARGE";
export const CANON_NULL = "CANON.NULL";
export const CANON_UNSUPPORTED = "CANON.UNSUPPORTED";

function bad(code: string, path: string, extra: string): Result<string, EngineError> {
  return err({
    code,
    message: `${path} ${extra} —— 内容指纹要求"同值同串"，这类值没法保证`,
    detail: { path },
  });
}

/**
 * 把任意值变成**唯一**的字符串表示。
 *
 * 同一份数据在任何机器、任何键书写顺序下都得到同一个串；
 * 不能唯一表示的值一律返回错误，不做任何"聪明"的转换。
 */
export function canonicalize(value: unknown): Result<string, EngineError> {
  return canon(value, "$");
}

function canon(value: unknown, path: string): Result<string, EngineError> {
  if (value === null) {
    // 对象/数组里的 null 与"字段不存在"必须区分开，否则就没法要求调用方表达清楚意图
    return bad(CANON_NULL, path, "是 null（缺字段就别写这个键，不要写 null）");
  }
  if (value === undefined) {
    return bad(CANON_UNSUPPORTED, path, "是 undefined（JSON 会把它静默丢掉，数组里还会变 null）");
  }

  switch (typeof value) {
    case "string":
      return ok(JSON.stringify(value));
    case "boolean":
      return ok(value ? "true" : "false");
    case "number": {
      if (!Number.isFinite(value)) {
        return bad(CANON_NOT_FINITE, path, `是 ${String(value)}`);
      }
      if (!Number.isInteger(value)) {
        return bad(CANON_NOT_INTEGER, path, `是小数 ${String(value)}（需要小数请改用定点整数）`);
      }
      if (Math.abs(value) > Number.MAX_SAFE_INTEGER) {
        return bad(CANON_TOO_LARGE, path, `是 ${String(value)}，超出安全整数范围（整数已不精确）`);
      }
      // String(-0) === "0"：这是想要的，见文件头
      return ok(String(value));
    }
    case "bigint":
    case "function":
    case "symbol":
      return bad(CANON_UNSUPPORTED, path, `是 ${typeof value}`);
    default:
      break;
  }

  if (Array.isArray(value)) {
    const parts: string[] = [];
    for (let i = 0; i < value.length; i++) {
      const r = canon(value[i], `${path}[${String(i)}]`);
      if (!r.ok) return r;
      parts.push(r.value);
    }
    return ok(`[${parts.join(",")}]`);
  }

  // 只接受**纯数据对象**。类实例（含 Map/Set/Date）一律拒绝：
  // 它们有自己的 toJSON / 内部顺序，规范化规则管不到。
  const proto = Object.getPrototypeOf(value) as unknown;
  if (proto !== Object.prototype && proto !== null) {
    const name = (proto as { constructor?: { name?: string } } | null)?.constructor?.name;
    return bad(CANON_UNSUPPORTED, path, `不是纯对象（原型 ${String(name)}）`);
  }

  const rec = value as Record<string, unknown>;
  const keys = Object.keys(rec).sort();
  const parts: string[] = [];
  for (const k of keys) {
    const r = canon(rec[k], `${path}.${k}`);
    if (!r.ok) return r;
    parts.push(`${JSON.stringify(k)}:${r.value}`);
  }
  return ok(`{${parts.join(",")}}`);
}

/**
 * 内容指纹：规范化串的 64 位哈希（16 个小写 hex）。
 *
 * ★ 为什么是哈希而不是把整个规范化串存下来：
 *   指纹要写进存档、日志、产物清单，几百 KB 的串没法用。但**比对仍然靠串**——
 *   判据里要先比规范化串、再比指纹，这样一旦不一致能立刻看出是"值不同"还是"哈希撞了"。
 */
export function fingerprintOf(value: unknown): Result<string, EngineError> {
  const c = canonicalize(value);
  if (!c.ok) return c;
  return ok(hashText(c.value));
}
