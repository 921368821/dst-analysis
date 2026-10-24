/**
 * L2 · 确定性序列化
 *
 * "确定性"在这里有三条具体要求（都来自"存档/回放要逐字节相同"这个承诺）：
 *  ① **键顺序固定**：按字段声明的顺序（schema 顺序），不按对象插入顺序。
 *  ② **浮点量化**：写到固定小数位，而不是 `0.30000000000000004`。
 *     跨平台 `Math.round` 行为一致，`toFixed` 在极端值上有实现差异，所以自己算。
 *  ③ **不输出"未定义"**：`undefined` 与"字段不存在"必须区分开 ——
 *     混在一起会让"旧档缺字段"和"字段就是 empty"无法分辨。
 *
 * ★ 版本迁移：`Migration` 是一条 `from → from+1` 的函数链。
 *   迁移必须**只增不减**（`v1→v2→v3` 依次跑），不做"直达 v3"的捷径 ——
 *   捷径会让"从 v1 来的"和"从 v2 来的"走上不同的代码路径，而那条路径
 *   通常只有作者记得测一次。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import { quantize } from "../../foundation/math/scalar.ts";

export interface Migration {
  /** 从哪个版本迁移到 `from + 1`。必须是连续整数。 */
  readonly from: number;
  migrate(data: Record<string, unknown>): Record<string, unknown>;
}

export interface SchemaOptions {
  readonly version: number;
  /** 字段顺序 = 输出顺序。 */
  readonly fields: readonly string[];
  readonly migrations?: readonly Migration[];
  /** 浮点保留位数（默认 3）。 */
  readonly decimals?: number;
  /**
   * 版本字段名（默认 `"__v"`）。
   *
   * ★ 为什么需要这个：版本号写在哪个键上，是**格式的一部分**，而不同格式各写各的键 ——
   *   场景存档用的是 `format`。如果 `Schema` 写死读 `__v`，那么"接上迁移链"就是句空话：
   *   它对 `{"format":0,...}` 读不到版本，会按 v1 静默放行，比"不接"更糟
   *   （不接至少一眼能看出没人用；接了但读错键，看起来一切正常）。
   */
  readonly versionKey?: string;
}

export class Schema {
  readonly version: number;
  readonly fields: readonly string[];
  readonly versionKey: string;
  private readonly migrations: readonly Migration[];
  private readonly decimals: number;

  constructor(opts: SchemaOptions) {
    this.version = opts.version;
    this.fields = opts.fields;
    this.versionKey = opts.versionKey ?? "__v";
    this.migrations = opts.migrations ?? [];
    this.decimals = opts.decimals ?? 3;

    // 迁移链必须连续，否则"中间某一版来的档"无法迁移 —— 启动时就查出来
    const froms = this.migrations.map((m) => m.from).sort((a, b) => a - b);
    for (let i = 0; i < froms.length; i++) {
      if (froms[i] !== i + 1) {
        throw new Error(
          `迁移链必须从 v1 连续覆盖到 v${this.version}，实际缺 v${i + 1}` +
            `（已有：${froms.join(",") || "无"}）`,
        );
      }
    }
    // ★ 上面那个循环在"一条迁移都没有"时一次都不跑，于是
    //   `new Schema({ version: 2, fields: [...] })`（打算升到 v2 但忘了写迁移）
    //   会**构造成功**，然后运行时对每个 v1 档报 NO_MIGRATION —— 把"架构错误"
    //   降级成"用户遇到的运行时错误"。所以还要查条数。
    const need = this.version - 1;
    if (froms.length !== need) {
      throw new Error(
        `v${this.version} 需要 ${need} 条迁移（v1→v2 … v${need}→v${this.version}），` +
          `实际 ${froms.length} 条（已有：${froms.join(",") || "无"}）`,
      );
    }
  }

  /** 把任意旧版本的记录迁到当前版本。 */
  migrate(data: Record<string, unknown>): Result<Record<string, unknown>, EngineError> {
    let cur = { ...data };
    const raw = cur[this.versionKey];
    // ★ 「字段不存在」与「字段存在但值不对」必须分开：
    //   前者是"最早的存档没写版本号"（按 v1 处理，这条兼容规则要留着），
    //   后者是"存档头坏了"（`"1"`、`null`、`1.5`）—— 静默当 v1 会把它读成另一份数据。
    const declared = Object.prototype.hasOwnProperty.call(cur, this.versionKey);
    let v = 1;
    if (declared) {
      if (typeof raw !== "number") {
        return err({
          code: "SER.BAD_VERSION",
          message: `版本字段 ${this.versionKey}=${JSON.stringify(raw)} 不是数字（存档头损坏）`,
        });
      }
      v = raw;
    }
    // ★ 版本号是整数这件事**不能靠"看起来像"**：`format: 1.5` 会通过 `v > this.version` 与
    //   `v < this.version` 两道判断（两个都不成立），然后原样返回 —— 一份"1.5 版"的档
    //   就这样被当成当前版本读进引擎。
    if (!Number.isInteger(v) || v < 1) {
      return err({
        code: "SER.BAD_VERSION",
        message: `版本字段 ${this.versionKey}=${JSON.stringify(raw)} 不是 ≥1 的整数（存档头损坏）`,
      });
    }
    if (v > this.version) {
      return err({
        code: "SER.VERSION_TOO_NEW",
        message: `记录版本 v${v} 高于引擎支持的 v${this.version}（用新引擎写的档，旧引擎不能读）`,
      });
    }
    while (v < this.version) {
      const m = this.migrations.find((x) => x.from === v);
      if (m === undefined) {
        return err({
          code: "SER.NO_MIGRATION",
          message: `缺少 v${v} → v${v + 1} 的迁移函数`,
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
  encode(data: Readonly<Record<string, unknown>>): { text: string; dropped: string[] } {
    const dropped = Object.keys(data).filter((k) => k !== this.versionKey && !this.fields.includes(k));
    const parts: string[] = [`${JSON.stringify(this.versionKey)}:${this.version}`];
    for (const k of this.fields) {
      const v = data[k];
      if (v === undefined) continue; // 未定义 = 不出现在输出里（与"存在但为 null"区分）
      parts.push(`${JSON.stringify(k)}:${encodeValue(v, this.decimals)}`);
    }
    return { text: `{${parts.join(",")}}`, dropped };
  }

  decode(text: string): Result<Record<string, unknown>, EngineError> {
    let raw: unknown;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      return err({
        code: "SER.BAD_JSON",
        message: `不是合法 JSON：${e instanceof Error ? e.message : String(e)}`,
      });
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      return err({ code: "SER.NOT_OBJECT", message: "顶层必须是对象" });
    }
    return this.migrate(raw as Record<string, unknown>);
  }
}

function encodeValue(v: unknown, decimals: number): string {
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      // NaN/Infinity 在 JSON 里没有表示。写成字符串而不是 null ——
      // null 会被读成"空值"，而这是"非法数值"，两者必须能区分
      return JSON.stringify(`__num__:${String(v)}`);
    }
    return String(quantize(v, decimals));
  }
  if (typeof v === "string" || typeof v === "boolean") return JSON.stringify(v);
  if (v === null) return "null";
  if (Array.isArray(v)) return "[" + v.map((x) => encodeValue(x, decimals)).join(",") + "]";
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    // 嵌套对象也按键名排序：嵌套层的插入顺序不应该影响字节
    const keys = Object.keys(o).sort();
    const body: string[] = [];
    for (const k of keys) {
      if (o[k] === undefined) continue;
      body.push(`${JSON.stringify(k)}:${encodeValue(o[k], decimals)}`);
    }
    return "{" + body.join(",") + "}";
  }
  return JSON.stringify(String(v));
}

/**
 * 稳定 hash（FNV-1a 32 位，十六进制）。
 * 用于"源文件变了没有"与"两份数据是否逐字节相同"的快速判定。
 * ★ 不做加密用途 —— 这里只需要"碰撞概率足够低且便宜"。
 */
export function stableHash(text: string | Uint8Array): string {
  let h = 0x811c9dc5;
  if (typeof text === "string") {
    for (let i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i) & 0xff;
      h = Math.imul(h, 0x01000193) >>> 0;
      h ^= (text.charCodeAt(i) >>> 8) & 0xff;
      h = Math.imul(h, 0x01000193) >>> 0;
    }
  } else {
    for (let i = 0; i < text.length; i++) {
      h ^= text[i]!;
      h = Math.imul(h, 0x01000193) >>> 0;
    }
  }
  return h.toString(16).padStart(8, "0");
}
