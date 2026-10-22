/**
 * L0 · 日志
 *
 * 三条设计要求（都来自上一代引擎踩过的坑）：
 *
 * ① **通道（channel）而不是全局开关**。上一代是 `print("[rt_boot] ...")` 满天飞，
 *    想只看网络日志只能靠 `grep`。这里每个子系统一个通道，运行时按通道调级别。
 * ② **限流（rate limit）**。热路径上的日志（每帧警告一次"实体没有 Transform"）
 *    会在一分钟内刷出十万行，把真正的问题埋掉。同一个 key 默认每秒最多 N 条，
 *    超出只累计计数，在下次放行时补一句"（另有 N 条同类被折叠）"。
 *    这一次折叠**必须报告**：静默丢弃日志等于制造一个看不见的故障。
 * ③ **sink 可换**。浏览器控制台 / Node stdout / 内存环形缓冲（给 headless 判据读）。
 *    判据要能**断言日志内容**，所以内存 sink 是一等公民，不是调试附属品。
 */

import { clamp } from "../math/scalar.ts";

export const LogLevel = {
  Trace: 10,
  Debug: 20,
  Info: 30,
  Warn: 40,
  Error: 50,
  Off: 100,
} as const;
export type LogLevelValue = (typeof LogLevel)[keyof typeof LogLevel];

export interface LogRecord {
  readonly t: number;
  readonly level: LogLevelValue;
  readonly channel: string;
  readonly message: string;
  /** 结构化字段：判据可以按值断言，而不是对字符串做正则。 */
  readonly fields?: Readonly<Record<string, unknown>>;
  /** 被折叠掉的同类条数（0 表示没有被折叠）。 */
  readonly suppressed: number;
}

export interface LogSink {
  write(rec: LogRecord): void;
  flush?(): void;
}

export interface RateLimitPolicy {
  /** 同一个 key 在一个窗口内最多几条。 */
  readonly maxPerWindow: number;
  readonly windowMs: number;
}

const DEFAULT_LIMIT: RateLimitPolicy = { maxPerWindow: 5, windowMs: 1000 };

/** 内存 sink：保留最近 N 条，供判据查看。 */
export class MemorySink implements LogSink {
  private readonly buf: LogRecord[] = [];
  private dropped = 0;

  constructor(private readonly capacity = 2000) {}

  write(rec: LogRecord): void {
    if (this.buf.length >= this.capacity) {
      this.buf.shift();
      this.dropped++;
    }
    this.buf.push(rec);
  }

  records(): readonly LogRecord[] {
    return this.buf;
  }

  /** 按通道/级别过滤，判据里最常用的两个查询。 */
  byChannel(channel: string): readonly LogRecord[] {
    return this.buf.filter((r) => r.channel === channel);
  }

  has(level: LogLevelValue, substr: string): boolean {
    return this.buf.some((r) => r.level >= level && r.message.includes(substr));
  }

  clear(): void {
    this.buf.length = 0;
    this.dropped = 0;
  }

  get droppedCount(): number {
    return this.dropped;
  }
}

export class Logger {
  private readonly sinks: LogSink[] = [];
  private readonly channelLevel = new Map<string, LogLevelValue>();
  private readonly limiters = new Map<string, { windowStart: number; count: number; folded: number }>();
  private defaultLevel: LogLevelValue = LogLevel.Info;

  constructor(private readonly now: () => number = () => Date.now()) {}

  addSink(sink: LogSink): void {
    this.sinks.push(sink);
  }

  setLevel(level: LogLevelValue, channel?: string): void {
    if (channel === undefined) this.defaultLevel = level;
    else this.channelLevel.set(channel, level);
  }

  levelOf(channel: string): LogLevelValue {
    return this.channelLevel.get(channel) ?? this.defaultLevel;
  }

  /**
   * 取一个通道的 logger。
   * ★ 通道名用 `点分层`（`gfx.webgl2` / `asset.registry`），这样"给 gfx 全开 debug"
   *   可以用前缀匹配（见 `setLevelPrefix`），不需要一处一处改。
   */
  channel(name: string): ChannelLogger {
    return new ChannelLogger(this, name);
  }

  setLevelPrefix(prefix: string, level: LogLevelValue): void {
    this.channelLevel.set(prefix.endsWith("*") ? prefix : prefix + "*", level);
  }

  log(
    level: LogLevelValue,
    channel: string,
    message: string,
    fields?: Record<string, unknown>,
    limit?: RateLimitPolicy | null,
  ): void {
    const lv = this.levelOf(channel);
    if (level < lv || lv >= LogLevel.Off) return;

    let suppressed = 0;
    if (limit) {
      const key = channel + "\u0000" + message;
      const t = this.now();
      const st = this.limiters.get(key);
      if (st === undefined || t - st.windowStart >= limit.windowMs) {
        suppressed = st ? st.folded : 0;
        this.limiters.set(key, { windowStart: t, count: 1, folded: 0 });
      } else {
        st.count++;
        if (st.count > limit.maxPerWindow) {
          st.folded++;
          return; // 本窗口内已超限：只记账，不输出
        }
      }
    }

    const rec: LogRecord = {
      t: this.now(),
      level,
      channel,
      message,
      ...(fields === undefined ? {} : { fields }),
      suppressed,
    };
    for (const s of this.sinks) s.write(rec);
  }

  flush(): void {
    for (const s of this.sinks) s.flush?.();
  }
}

export class ChannelLogger {
  constructor(
    private readonly root: Logger,
    private readonly name: string,
  ) {}

  trace(msg: string, fields?: Record<string, unknown>): void {
    this.root.log(LogLevel.Trace, this.name, msg, fields);
  }
  debug(msg: string, fields?: Record<string, unknown>): void {
    this.root.log(LogLevel.Debug, this.name, msg, fields);
  }
  info(msg: string, fields?: Record<string, unknown>): void {
    this.root.log(LogLevel.Info, this.name, msg, fields);
  }
  warn(msg: string, fields?: Record<string, unknown>, limit: RateLimitPolicy | null = DEFAULT_LIMIT): void {
    this.root.log(LogLevel.Warn, this.name, msg, fields, limit);
  }
  error(msg: string, fields?: Record<string, unknown>, limit: RateLimitPolicy | null = DEFAULT_LIMIT): void {
    this.root.log(LogLevel.Error, this.name, msg, fields, limit);
  }
}

/** 控制台 sink：浏览器与 Node 都能用。`clamp` 只是为了避免把对象打爆。 */
export class ConsoleSink implements LogSink {
  constructor(
    private readonly minLevel: LogLevelValue = LogLevel.Info,
    private readonly echo: (line: string) => void = (l) => console.log(l),
  ) {}

  write(rec: LogRecord): void {
    if (rec.level < this.minLevel) return;
    const tag = rec.level >= LogLevel.Error ? "E" : rec.level >= LogLevel.Warn ? "W" : "I";
    const fold = rec.suppressed > 0 ? ` (+${rec.suppressed} 同类被折叠)` : "";
    const f = rec.fields ? " " + JSON.stringify(rec.fields) : "";
    this.echo(`[${tag}][${rec.channel}] ${rec.message}${f}${fold}`);
  }
}

/** 在日志里安全打印浮点：避免 0.30000000000000004 这种噪声。 */
export function fmt(v: number, decimals = 3): string {
  return clamp(v, -1e12, 1e12).toFixed(decimals);
}
