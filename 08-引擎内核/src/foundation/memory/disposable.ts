/**
 * L0 · 内存工具
 *
 * 只放两样在热路径上真正救命的：
 *  ① `ObjectPool` —— 每帧创建/销毁的短命对象（渲染批次项、事件载荷、命令）
 *  ② `DisposableBag` —— **逆序释放**的资源集合
 *
 * `DisposableBag` 单独存在的理由：引擎里资源有依赖顺序（纹理依赖设备、管线依赖
 * 着色器、模块依赖服务）。正序释放会释放"还在被用的东西"，症状是随机的空指针。
 * 逆序释放 + 集中管理是唯一可维护的写法。上一代引擎靠"每处自己记得释放"，
 * 结果是 12 处 dispose 里 4 处顺序错误 —— 而错误只在热重载时显形。
 */

export interface Disposable {
  dispose(): void;
}

export class ObjectPool<T> {
  private readonly free: T[] = [];
  private created = 0;

  constructor(
    private readonly factory: () => T,
    private readonly reset: (obj: T) => void = () => {},
    prewarm = 0,
  ) {
    for (let i = 0; i < prewarm; i++) {
      this.free.push(factory());
      this.created++;
    }
  }

  acquire(): T {
    const obj = this.free.pop();
    if (obj !== undefined) return obj;
    this.created++;
    return this.factory();
  }

  release(obj: T): void {
    this.reset(obj);
    this.free.push(obj);
  }

  /** 观测用：判据可以断言"池没有无限增长"。 */
  get stats(): { created: number; free: number } {
    return { created: this.created, free: this.free.length };
  }

  clear(): void {
    this.free.length = 0;
  }
}

export class DisposableBag implements Disposable {
  private readonly items: Array<{ label: string; d: Disposable | (() => void) }> = [];
  private disposed = false;

  add(label: string, d: Disposable | (() => void)): void {
    if (this.disposed) {
      // 已经释放过还往里加，说明生命周期代码写错了 —— 立刻释放并报错（不静默）
      releaseOne(d);
      throw new Error(`DisposableBag 已释放，不允许再 add（${label}）`);
    }
    this.items.push({ label, d });
  }

  /** 逆序释放。单个失败**不中断**其余释放，但把失败收集起来抛一个聚合错误。 */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    const failures: string[] = [];
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i]!;
      try {
        releaseOne(it.d);
      } catch (e) {
        failures.push(`${it.label}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    this.items.length = 0;
    if (failures.length > 0) {
      throw new Error(`释放时有 ${failures.length} 项失败：\n  ${failures.join("\n  ")}`);
    }
  }

  get size(): number {
    return this.items.length;
  }

  get isDisposed(): boolean {
    return this.disposed;
  }
}

function releaseOne(d: Disposable | (() => void)): void {
  if (typeof d === "function") d();
  else d.dispose();
}
