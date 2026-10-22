/**
 * L1 · 音频设备接口
 *
 * 只做"游戏需要的那些事"，不做 DAW：
 *   clip（解码后的可播放资源） → voice（一次播放实例） → bus（音量总线）
 *
 * ★ 两条硬约束：
 * ① **自动播放策略必须由接口表达**。浏览器要求"用户手势后才能出声"，
 *    所以 `resume()` 是独立的、可能失败的、幂等的方法，而不是 init 里顺手做掉。
 *    调用方（runtime 的输入模块）负责在第一次真实输入时调它。
 *    上一代引擎是"尝试播，失败就静默" —— 结果是玩家在无提示情况下没有音效。
 * ② **播放是 fire-and-forget，但"没播成"必须可见**。
 *    `play()` 返回 voice 句柄；拿不到句柄就是没播成，调用方可以降级（字幕/震动）。
 */

import type { EngineError, Result } from "../../foundation/result.ts";

declare const audioBrand: unique symbol;
type Branded<T extends string> = number & { readonly [audioBrand]: T };

export type ClipHandle = Branded<"Clip">;
export type VoiceHandle = Branded<"Voice">;

export interface AudioCaps {
  readonly backend: string;
  readonly maxVoices: number;
  /** 需要用户手势才能出声（浏览器为 true）。 */
  readonly requiresGesture: boolean;
  /** 支持空间化（2.5D 里做左右声道 / 衰减）。 */
  readonly spatial: boolean;
}

export interface AudioBus {
  readonly name: string;
  volume: number;
  muted: boolean;
}

export interface PlayOptions {
  readonly bus?: string;
  readonly volume?: number;
  readonly rate?: number;
  readonly loop?: boolean;
  /** 2.5D 世界坐标；`spatial` 为 false 时被忽略。 */
  readonly position?: { readonly x: number; readonly z: number };
  readonly priority?: number;
}

export interface VoiceState {
  readonly handle: VoiceHandle;
  readonly playing: boolean;
  readonly clip: ClipHandle;
  readonly bus: string;
  volume: number;
  rate: number;
  loop: boolean;
}

export interface IAudioDevice {
  readonly caps: AudioCaps;
  /** 创建（或挂载到已有上下文）。不要求手势。 */
  init(): Promise<Result<void, EngineError>>;
  /** 解锁音频（浏览器需要手势）。幂等；重复调用返回同样的结果。 */
  resume(): Promise<Result<void, EngineError>>;
  /** 解码。`data` 是原始字节（mp3/ogg/wav），解码由后端负责。 */
  loadClip(name: string, data: ArrayBuffer): Promise<Result<ClipHandle, EngineError>>;
  releaseClip(clip: ClipHandle): void;
  play(clip: ClipHandle, opts?: PlayOptions): Result<VoiceHandle, EngineError>;
  stop(voice: VoiceHandle): void;
  setVoice(voice: VoiceHandle, patch: { volume?: number; rate?: number; loop?: boolean }): void;
  getVoice(voice: VoiceHandle): VoiceState | undefined;
  bus(name: string): AudioBus;
  /** 监听者位置（2.5D 用 x/z）。 */
  setListener(pos: { x: number; y: number; z: number }): void;
  /** 音频时钟（毫秒）。用于"音画同步"判据。 */
  readonly timeMs: number;
  /** 正在播放的 voice 数（判据断言"没有泄漏的 voice"）。 */
  readonly activeVoices: number;
  destroy(): void;
}

export interface AudioBackendFactory {
  readonly id: string;
  probe(options?: unknown): boolean;
  /**
   * ★ 同步构造。**所有后端工厂的 create 都是同步的**，理由：
   *   "创建对象"和"初始化设备"是两件事。音频的 init() 需要等 DOM/上下文，
   *   但那不该让工厂变成 async —— 否则注册表要处理 Promise，
   *   而注册表是同步的纯配置设施（它不该有 IO 语义）。
   *   同一约定让 createPlatform 保持同步 ⇒ 宿主在构造期不需要 await。
   */
  create(options?: unknown): Result<IAudioDevice, EngineError>;
}
