/**
 * L2 · 服务注册表
 *
 * 按 **token** 取服务，而不是 `import` 具体实现。这是"模块解耦"最实用的一条：
 * 上层写 `services.require(RenderQueueToken)`，它不知道也不关心背后是
 * WebGL2 还是 Null 后端；换实现只改宿主的一行组装代码。
 *
 * ★ 与"全局单例"的区别（这不是文字游戏）：
 *   - 单例是 **拉**：任何模块在任何时刻 `import` 就能拿到，依赖关系不出现在
 *     任何签名里 ⇒ 依赖图不可见、不可验证、测试无法替换。
 *   - 这里是 **推**：宿主在 bootstrap 时显式 provide，模块在构造参数里显式声明要什么。
 *     依赖关系是**数据**，可以被检查、被替换、被并行隔离。
 *
 * ★ token 用对象而不是字符串：两个模块各写 `'renderer'` 会撞车，而
 *   `defineService<T>('render.queue')` 返回的 token 是同一个引用，
 *   类型还能跟着走。字符串只用于诊断显示。
 */

import type { Disposable } from "../../foundation/memory/disposable.ts";

declare const serviceBrand: unique symbol;

export interface ServiceToken<T> {
  readonly key: string;
  /** 只用于类型推导，运行时不存在。 */
  readonly [serviceBrand]?: T;
}

export function defineService<T>(key: string): ServiceToken<T> {
  return { key };
}

export class ServiceRegistry implements Disposable {
  private readonly map = new Map<ServiceToken<unknown>, unknown>();
  private readonly owner = new Map<ServiceToken<unknown>, string>();

  /**
   * 注册服务。`ownerId` 只用于诊断（"这个服务是谁提供的"）。
   * 重复注册直接抛：静默覆盖会让"到底注入的是哪个"变成运气。
   */
  provide<T>(token: ServiceToken<T>, impl: T, ownerId = "unknown"): void {
    if (this.map.has(token)) {
      throw new Error(
        `服务 ${token.key} 已被 ${this.owner.get(token)} 提供，${ownerId} 不能重复提供` +
          `（要替换请先 revoke，宿主组装阶段才允许替换）`,
      );
    }
    this.map.set(token, impl);
    this.owner.set(token, ownerId);
  }

  /** 供宿主在测试/热替换时显式撤销。 */
  revoke<T>(token: ServiceToken<T>): void {
    this.map.delete(token);
    this.owner.delete(token);
  }

  /** 可选取：没有就 undefined（软依赖用它）。 */
  get<T>(token: ServiceToken<T>): T | undefined {
    return this.map.get(token) as T | undefined;
  }

  /** 必需取：没有就抛，并在错误里列出当前已提供的服务（便于一眼看出拼错）。 */
  require<T>(token: ServiceToken<T>): T {
    const v = this.map.get(token);
    if (v === undefined) {
      throw new Error(
        `缺少必需服务 ${token.key}。已提供：${Array.from(this.map.keys())
          .map((t) => t.key)
          .sort()
          .join(", ") || "(空)"}`,
      );
    }
    return v as T;
  }

  has<T>(token: ServiceToken<T>): boolean {
    return this.map.has(token);
  }

  describe(): ReadonlyArray<{ key: string; owner: string }> {
    return Array.from(this.map.keys())
      .map((t) => ({ key: t.key, owner: this.owner.get(t) ?? "?" }))
      .sort((a, b) => a.key.localeCompare(b.key));
  }

  dispose(): void {
    this.map.clear();
    this.owner.clear();
  }
}
