/**
 * L0 · 显式结果类型
 *
 * ★ 为什么整个引擎不用异常做控制流：
 *   引擎里绝大多数"失败"都是**预期内**的（资源不存在、后端不支持某个特性、
 *   着色器编译失败、网络断开）。用异常表达它们有三个后果：
 *     ① 调用者靠 `catch` 兜底，很容易**吞掉**真正的 bug（上一代代码里
 *        `pcall(cmp.OnUpdate)` 吞掉组件异常就是活例子，最后不得不加一个
 *        错误计数器才看得见）；
 *     ② 性能：V8 里 `try/catch` 便宜，但**抛**异常很贵，热路径上不可用；
 *     ③ 类型系统帮不上忙 —— `throws` 不是 TypeScript 的一部分。
 *
 *   所以：**可预期失败 → Result；程序错误（不变量被破坏）→ throw**。
 *   两者边界写在这里，全引擎遵守。
 */

export type Ok<T> = { readonly ok: true; readonly value: T };
export type Err<E> = { readonly ok: false; readonly error: E };

export type Result<T, E = string> = Ok<T> | Err<E>;

export function ok<T>(value: T): Ok<T> {
  return { ok: true, value };
}

export function err<E>(error: E): Err<E> {
  return { ok: false, error };
}

export function isOk<T, E>(r: Result<T, E>): r is Ok<T> {
  return r.ok;
}

export function isErr<T, E>(r: Result<T, E>): r is Err<E> {
  return !r.ok;
}

/** 取值，失败时抛。**只允许在**"已经确认成功"或"失败即 bug"的地方用。 */
export function unwrap<T, E>(r: Result<T, E>): T {
  if (r.ok) return r.value;
  throw new Error(`unwrap 了一个失败的结果：${String(r.error)}`);
}

/** 取值，失败时给默认值。 */
export function unwrapOr<T, E>(r: Result<T, E>, fallback: T): T {
  return r.ok ? r.value : fallback;
}

/** 映射成功值；失败原样透传（错误类型不变）。 */
export function mapOk<T, U, E>(r: Result<T, E>, f: (v: T) => U): Result<U, E> {
  return r.ok ? ok(f(r.value)) : r;
}

/** 链式串联；`f` 返回新的 Result。 */
export function andThen<T, U, E, F>(
  r: Result<T, E>,
  f: (v: T) => Result<U, F>,
): Result<U, E | F> {
  return r.ok ? f(r.value) : r;
}

/**
 * 把可能抛的同步函数包成 Result。
 * ★ 只用于**边界**（插件代码、脚本运行时、第三方解码器）——
 *   自己写的代码应该直接返回 Result，不要靠这个转换。
 */
export function trap<T>(fn: () => T, onError?: (e: unknown) => string): Result<T, string> {
  try {
    return ok(fn());
  } catch (e) {
    return err(onError ? onError(e) : e instanceof Error ? e.message : String(e));
  }
}

/** 结构化的错误：带一个稳定的 code，便于判据断言与日志归类。 */
export interface EngineError {
  /** 稳定机器码，例如 `GFX.SHADER_COMPILE`。判据可以断言它，而不是断言文案。 */
  readonly code: string;
  /** 人类可读的说明，可以改。 */
  readonly message: string;
  /** 附加上下文（后端名、资源 id、行号……）。 */
  readonly detail?: Readonly<Record<string, unknown>>;
}

export function engineError(
  code: string,
  message: string,
  detail?: Record<string, unknown>,
): EngineError {
  return detail === undefined ? { code, message } : { code, message, detail };
}
