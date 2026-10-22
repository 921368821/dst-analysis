/**
 * L0 · 类型化事件总线
 *
 * 这是模块间**三种通信方式**之一（见 ARCHITECTURE §5）：
 *   ① 直接调用 —— 同层或向下，热路径
 *   ② 事件     —— 本文件，"发生了某事"，发布/订阅
 *   ③ 命令队列 —— 结构性修改，帧边界统一执行
 *
 * 设计约束（每条都有代价在里面）：
 *
 * ① **类型化 topic**：用一张 `EventMap` 声明"有哪些事件、载荷是什么"，
 *    订阅/发布都做静态检查。字符串 topic 的自由度换来的是"拼错 topic 永远收不到"，
 *    而且不会报错 —— 这类 bug 在上一代引擎里出现过（`onperish` vs `onperished`）。
 *
 * ② **载荷不可变**：事件里只放值快照或 ID，不放可变对象引用。
 *    否则订阅者拿到的是"发布那一刻的同一个对象"，改它就是偷偷改别人的状态。
 *
 * ③ **同步分发 + 快照遍历**：同步是为了确定性（事件顺序 = 发布顺序）。
 *    遍历前对订阅者列表取快照，所以**允许在回调里退订**（否则会跳过下一个）。
 *    但**禁止**在回调里改世界 —— 要改就投命令（见 ③ 命令队列）。
 *
 * ④ **异常隔离并记账**：一个订阅者抛错不能让整条事件链断掉，但**必须被记录**，
 *    否则就变成"事件没人处理"的静默故障。策略与组件更新泵一致：捕获 → 计数 → 报告。
 */

export type Listener<T> = (payload: T) => void;

export interface EventBusStats {
  readonly emitted: number;
  readonly listenerErrors: number;
  readonly lastError: string | null;
}

export class EventBus<TMap extends Record<string, unknown>> {
  private readonly listeners = new Map<keyof TMap, Set<Listener<never>>>();
  private emitted = 0;
  private listenerErrors = 0;
  private lastError: string | null = null;

  /** 错误回调：默认什么都不做，由宿主接到 logger 上（L0 不依赖具体 logger 实例，避免全局单例）。 */
  onListenerError: ((topic: keyof TMap, e: unknown) => void) | null = null;

  on<K extends keyof TMap>(topic: K, fn: Listener<TMap[K]>): () => void {
    let set = this.listeners.get(topic);
    if (set === undefined) {
      set = new Set();
      this.listeners.set(topic, set);
    }
    set.add(fn as Listener<never>);
    // 返回退订函数：调用方不需要记住 on/off 成对，避免漏 off 造成泄漏
    return () => {
      set!.delete(fn as Listener<never>);
    };
  }

  once<K extends keyof TMap>(topic: K, fn: Listener<TMap[K]>): () => void {
    const off = this.on(topic, (p) => {
      off();
      fn(p);
    });
    return off;
  }

  emit<K extends keyof TMap>(topic: K, payload: TMap[K]): void {
    this.emitted++;
    const set = this.listeners.get(topic);
    if (set === undefined || set.size === 0) return;
    // 快照：允许回调里退订/新增，不影响本次遍历
    const snapshot = Array.from(set);
    for (const fn of snapshot) {
      try {
        (fn as Listener<TMap[K]>)(payload);
      } catch (e) {
        this.listenerErrors++;
        this.lastError = e instanceof Error ? e.message : String(e);
        this.onListenerError?.(topic, e);
      }
    }
  }

  listenerCount<K extends keyof TMap>(topic: K): number {
    return this.listeners.get(topic)?.size ?? 0;
  }

  /** 清空所有订阅。宿主 dispose 时调用，避免模块卸载后仍被事件引用。 */
  clear(): void {
    this.listeners.clear();
  }

  stats(): EventBusStats {
    return {
      emitted: this.emitted,
      listenerErrors: this.listenerErrors,
      lastError: this.lastError,
    };
  }
}
