/**
 * L5 · Null 音频设备
 *
 * 记录每一次播放请求（clip / 音量 / 总线），并维护一个**可推进的音频时钟**。
 * 这样"音频与模拟同步"这类判据可以完全在 headless 跑：
 *   - `advance(ms)` 推进时钟并让到期的 voice 自动结束；
 *   - `playLog` 让判据断言"该响的时候响了、不该响的时候没响"。
 *
 * ★ 一个刻意的行为：`resume()` 在 `requiresGesture = true` 时**首次失败**，
 *   第二次成功。这不是"模拟浏览器"，而是**把自动播放策略变成可测的契约**：
 *   调用方必须处理"第一次播不出声"，否则上线就是没声音。
 *   上一代引擎在无提示情况下静音，正是因为没有这条契约。
 */

import { ok, err, engineError, type EngineError, type Result } from "../../foundation/result.ts";
import type {
  AudioBus,
  AudioCaps,
  ClipHandle,
  IAudioDevice,
  PlayOptions,
  VoiceHandle,
  VoiceState,
} from "../../platform/audio/device.ts";

export interface PlayRecord {
  readonly clip: ClipHandle;
  readonly name: string;
  readonly bus: string;
  readonly volume: number;
  readonly loop: boolean;
  readonly atMs: number;
  readonly position: { x: number; z: number } | null;
}

interface VoiceRec {
  readonly handle: VoiceHandle;
  readonly clip: ClipHandle;
  readonly name: string;
  bus: string;
  volume: number;
  rate: number;
  loop: boolean;
  /** 结束时间（毫秒，音频时钟）。loop 时为 Infinity。 */
  endsAtMs: number;
  readonly position: { x: number; z: number } | null;
}

export class NullAudioDevice implements IAudioDevice {
  readonly caps: AudioCaps = {
    backend: "null",
    maxVoices: 32,
    requiresGesture: true,
    spatial: true,
  };

  private nextHandle = 1;
  private readonly clips = new Map<number, { name: string; durationMs: number }>();
  private readonly voices = new Map<number, VoiceRec>();
  private readonly buses = new Map<string, AudioBus>([["master", { name: "master", volume: 1, muted: false }]]);
  private clock = 0;
  private resumed = false;
  private resumeCalls = 0;

  readonly playLog: PlayRecord[] = [];
  /** 因为超过 maxVoices 被拒绝的播放次数（"声音被吞掉"必须可见）。 */
  voicesRejected = 0;

  async init(): Promise<Result<void, EngineError>> {
    return ok(undefined);
  }

  async resume(): Promise<Result<void, EngineError>> {
    this.resumeCalls++;
    if (!this.caps.requiresGesture) {
      this.resumed = true;
      return ok(undefined);
    }
    // 第一次失败：调用方必须处理"用户还没手势"这件事
    if (!this.resumed) {
      this.resumed = true;
      return err(
        engineError("AUDIO.NEEDS_GESTURE", "音频需要用户手势才能解锁（第一次 resume 必然失败，这是契约）"),
      );
    }
    return ok(undefined);
  }

  /** 判据用：模拟"用户点了"（跳过手势检查）。 */
  forceUnlock(): void {
    this.resumed = true;
    this.capsUnlockPatch();
  }

  private capsUnlockPatch(): void {
    // caps 是 readonly 语义，但实现需要能改"是否需要手势"来模拟已解锁环境
    (this.caps as { requiresGesture: boolean }).requiresGesture = false;
  }

  async loadClip(name: string, data: ArrayBuffer): Promise<Result<ClipHandle, EngineError>> {
    if (data.byteLength === 0) {
      return err(engineError("AUDIO.BAD_CLIP", "音频数据为空：" + name));
    }
    // 用字节长度估时长：判据不依赖真实解码，只依赖"有确定时长"
    const durationMs = Math.max(50, Math.round((data.byteLength / 8000) * 1000));
    const h = this.nextHandle++;
    this.clips.set(h, { name, durationMs });
    return ok(h as unknown as ClipHandle);
  }

  releaseClip(clip: ClipHandle): void {
    this.clips.delete(clip as unknown as number);
    for (const [h, v] of this.voices) if (v.clip === clip) this.voices.delete(h);
  }

  play(clip: ClipHandle, opts: PlayOptions = {}): Result<VoiceHandle, EngineError> {
    const c = this.clips.get(clip as unknown as number);
    if (c === undefined) return err(engineError("AUDIO.INVALID_CLIP", `clip ${clip} 不存在`));
    if (this.voices.size >= this.caps.maxVoices) {
      this.voicesRejected++;
      return err(
        engineError("AUDIO.NO_FREE_VOICE", `已达 ${this.caps.maxVoices} 个声部上限`, { clip: c.name }),
      );
    }
    const busName = opts.bus ?? "master";
    const bus = this.buses.get(busName) ?? { name: busName, volume: 1, muted: false };
    this.buses.set(busName, bus);
    if (bus.muted) {
      // 静音总线上播放：不占声部，但**记录**（否则"播了但没声"无法解释）
      this.playLog.push({
        clip,
        name: c.name,
        bus: busName,
        volume: 0,
        loop: opts.loop === true,
        atMs: this.clock,
        position: opts.position === undefined ? null : { x: opts.position.x, z: opts.position.z },
      });
      return err(engineError("AUDIO.BUS_MUTED", `总线 ${busName} 已静音`, { clip: c.name }));
    }

    const rate = opts.rate ?? 1;
    const volume = (opts.volume ?? 1) * bus.volume;
    const loop = opts.loop === true;
    const h = this.nextHandle++ as unknown as VoiceHandle;
    this.voices.set(h as unknown as number, {
      handle: h,
      clip,
      name: c.name,
      bus: busName,
      volume,
      rate,
      loop,
      endsAtMs: loop ? Number.POSITIVE_INFINITY : this.clock + Math.round(c.durationMs / rate),
      position: opts.position === undefined ? null : { x: opts.position.x, z: opts.position.z },
    });
    this.playLog.push({
      clip,
      name: c.name,
      bus: busName,
      volume,
      loop,
      atMs: this.clock,
      position: opts.position === undefined ? null : { x: opts.position.x, z: opts.position.z },
    });
    return ok(h);
  }

  stop(voice: VoiceHandle): void {
    this.voices.delete(voice as unknown as number);
  }

  setVoice(voice: VoiceHandle, patch: { volume?: number; rate?: number; loop?: boolean }): void {
    const v = this.voices.get(voice as unknown as number);
    if (v === undefined) return;
    if (patch.volume !== undefined) v.volume = patch.volume;
    if (patch.rate !== undefined) v.rate = patch.rate;
    if (patch.loop !== undefined) v.loop = patch.loop;
  }

  getVoice(voice: VoiceHandle): VoiceState | undefined {
    const v = this.voices.get(voice as unknown as number);
    if (v === undefined) return undefined;
    return {
      handle: v.handle,
      playing: true,
      clip: v.clip,
      bus: v.bus,
      volume: v.volume,
      rate: v.rate,
      loop: v.loop,
    };
  }

  bus(name: string): AudioBus {
    let b = this.buses.get(name);
    if (b === undefined) {
      b = { name, volume: 1, muted: false };
      this.buses.set(name, b);
    }
    return b;
  }

  setListener(_pos: { x: number; y: number; z: number }): void {}

  get timeMs(): number {
    return this.clock;
  }

  get activeVoices(): number {
    return this.voices.size;
  }

  /** 判据用：推进音频时钟并结束到期 voice。 */
  advance(ms: number): void {
    this.clock += ms;
    for (const [h, v] of [...this.voices]) {
      if (!v.loop && this.clock >= v.endsAtMs) this.voices.delete(h);
    }
  }

  destroy(): void {
    this.voices.clear();
    this.clips.clear();
  }
}

export const nullAudioBackend = {
  id: "null",
  priority: 0,
  probe(_options?: unknown): boolean {
    return true;
  },
  create(_options?: unknown): Result<IAudioDevice, EngineError> {
    return ok(new NullAudioDevice());
  },
};
