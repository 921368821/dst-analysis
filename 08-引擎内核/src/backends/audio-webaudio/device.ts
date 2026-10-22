/**
 * L5 · WebAudio 后端
 *
 * 用最小结构接口（`AudioContextLike`），理由同 `input-dom`：
 * Node 里可注入 fake 验证调用序列，浏览器路径不变。
 *
 * ★ 三条必须做对的：
 *
 * ① **`resume()` 是独立且幂等的**。浏览器要求用户手势后才能出声，
 *    第一次 `resume()` 很可能失败（`state === 'suspended'`）。
 *    调用方必须能"处理这件事"，所以它是可失败的返回值，而不是 init 里顺手做掉。
 *    上一代引擎是"尝试播，失败就静默" —— 玩家在无提示情况下没有音效。
 *
 * ② **声部上限 + 拒绝要可见**。超过上限时返回 `AUDIO.NO_FREE_VOICE`，
 *    而不是静默丢弃 —— "某些音效偶尔不响"是极难查的 bug。
 *
 * ③ **播放结束要回收 voice**。用 `onended` 回调；不回收的话
 *    `activeVoices` 会单调增长，几十秒后所有音效都播不出来。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type {
  AudioBus,
  AudioCaps,
  ClipHandle,
  IAudioDevice,
  PlayOptions,
  VoiceHandle,
  VoiceState,
} from "../../platform/audio/device.ts";

/** 只要求我们真正用到的 WebAudio 能力。 */
export interface AudioContextLike {
  readonly currentTime: number;
  readonly state: string;
  readonly sampleRate: number;
  readonly destination: unknown;
  resume(): Promise<void>;
  createBufferSource(): AudioBufferSourceLike;
  createGain(): GainNodeLike;
  decodeAudioData(data: ArrayBuffer): Promise<AudioBufferLike>;
}

export interface AudioBufferLike {
  readonly duration: number;
}

export interface AudioBufferSourceLike {
  buffer: AudioBufferLike | null;
  loop: boolean;
  playbackRate: { value: number };
  onended: (() => void) | null;
  connect(node: unknown): void;
  disconnect(): void;
  start(when?: number): void;
  stop(when?: number): void;
}

export interface GainNodeLike {
  gain: { value: number };
  connect(node: unknown): void;
  disconnect(): void;
}

interface ClipRec {
  readonly name: string;
  readonly buffer: AudioBufferLike;
}

interface VoiceRec {
  readonly src: AudioBufferSourceLike;
  readonly gain: GainNodeLike;
  readonly clip: ClipHandle;
  bus: string;
  volume: number;
  rate: number;
  loop: boolean;
  readonly endsAt: number;
  readonly position: { x: number; z: number } | null;
}

export class WebAudioDevice implements IAudioDevice {
  readonly caps: AudioCaps = {
    backend: "webaudio",
    maxVoices: 32,
    requiresGesture: true,
    spatial: false,
  };

  private ctx: AudioContextLike;
  private next = 1;
  private readonly clips = new Map<number, ClipRec>();
  private readonly voices = new Map<number, VoiceRec>();
  private readonly buses = new Map<string, AudioBus>([
    ["master", { name: "master", volume: 1, muted: false }],
  ]);
  private readonly busGains = new Map<string, GainNodeLike>();
  /** 因声部上限被拒的播放次数（可见，不静默）。 */
  voicesRejected = 0;

  constructor(ctx: AudioContextLike) {
    this.ctx = ctx;
  }

  async init(): Promise<Result<void, EngineError>> {
    try {
      const g = this.ctx.createGain();
      g.gain.value = 1;
      g.connect(this.ctx.destination);
      this.busGains.set("master", g);
      return ok(undefined);
    } catch (e) {
      return err(engineError("AUDIO.INIT_FAILED", e instanceof Error ? e.message : String(e)));
    }
  }

  async resume(): Promise<Result<void, EngineError>> {
    try {
      await this.ctx.resume();
    } catch (e) {
      return err(engineError("AUDIO.RESUME_FAILED", e instanceof Error ? e.message : String(e)));
    }
    if (this.ctx.state !== "running") {
      // 有些浏览器 resume() 不抛但状态仍是 suspended（还没有手势）
      return err(
        engineError("AUDIO.NEEDS_GESTURE", `音频上下文仍处于 '${this.ctx.state}'，需要用户手势后才能出声`),
      );
    }
    return ok(undefined);
  }

  async loadClip(name: string, data: ArrayBuffer): Promise<Result<ClipHandle, EngineError>> {
    if (data.byteLength === 0) {
      return err(engineError("AUDIO.BAD_CLIP", "音频数据为空：" + name));
    }
    try {
      const buf = await this.ctx.decodeAudioData(data);
      const h = this.next++;
      this.clips.set(h, { name, buffer: buf });
      return ok(h as unknown as ClipHandle);
    } catch (e) {
      // 解码失败必须报出来：静默的话就是"这个音效永远不响，没人知道为什么"
      return err(
        engineError("AUDIO.DECODE_FAILED", `解码失败：${name}（${e instanceof Error ? e.message : String(e)}）`, {
          clip: name,
        }),
      );
    }
  }

  releaseClip(clip: ClipHandle): void {
    this.clips.delete(clip as unknown as number);
    for (const [h, v] of [...this.voices]) {
      if (v.clip === clip) this.stop(h as unknown as VoiceHandle);
    }
  }

  play(clip: ClipHandle, opts: PlayOptions = {}): Result<VoiceHandle, EngineError> {
    const c = this.clips.get(clip as unknown as number);
    if (c === undefined) return err(engineError("AUDIO.INVALID_CLIP", `clip ${clip} 不存在或已释放`));
    if (this.voices.size >= this.caps.maxVoices) {
      this.voicesRejected++;
      return err(
        engineError("AUDIO.NO_FREE_VOICE", `已达 ${this.caps.maxVoices} 个声部上限`, { clip: c.name }),
      );
    }
    const busName = opts.bus ?? "master";
    const bus = this.bus(busName);
    if (bus.muted) {
      return err(engineError("AUDIO.BUS_MUTED", `总线 ${busName} 已静音`, { clip: c.name }));
    }

    const src = this.ctx.createBufferSource();
    src.buffer = c.buffer;
    src.loop = opts.loop === true;
    src.playbackRate.value = opts.rate ?? 1;
    const gain = this.ctx.createGain();
    gain.gain.value = (opts.volume ?? 1) * bus.volume;
    src.connect(gain);
    gain.connect(this.busGain(busName));

    const h = this.next++ as unknown as VoiceHandle;
    const rate = opts.rate ?? 1;
    const rec: VoiceRec = {
      src,
      gain,
      clip,
      bus: busName,
      volume: (opts.volume ?? 1) * bus.volume,
      rate,
      loop: opts.loop === true,
      endsAt: this.ctx.currentTime + (opts.loop === true ? Number.POSITIVE_INFINITY : c.buffer.duration / rate),
      position: opts.position === undefined ? null : { x: opts.position.x, z: opts.position.z },
    };
    // ★ 必须回收：不回收的话 activeVoices 单调增长，几十秒后所有音效都播不出来
    src.onended = () => {
      const v = this.voices.get(h as unknown as number);
      if (v !== undefined && v.src === src) this.voices.delete(h as unknown as number);
    };
    try {
      src.start();
    } catch (e) {
      this.voices.delete(h as unknown as number);
      return err(
        engineError("AUDIO.START_FAILED", `播放失败（音频上下文可能未解锁）：${e instanceof Error ? e.message : String(e)}`, {
          clip: c.name,
        }),
      );
    }
    this.voices.set(h as unknown as number, rec);
    return ok(h);
  }

  stop(voice: VoiceHandle): void {
    const v = this.voices.get(voice as unknown as number);
    if (v === undefined) return;
    this.voices.delete(voice as unknown as number);
    try {
      v.src.onended = null;
      v.src.stop();
      v.src.disconnect();
      v.gain.disconnect();
    } catch {
      // 已停止的 source 再 stop 会抛，忽略
    }
  }

  setVoice(voice: VoiceHandle, patch: { volume?: number; rate?: number; loop?: boolean }): void {
    const v = this.voices.get(voice as unknown as number);
    if (v === undefined) return;
    if (patch.volume !== undefined) {
      v.volume = patch.volume;
      v.gain.gain.value = patch.volume * this.bus(v.bus).volume;
    }
    if (patch.rate !== undefined) {
      v.rate = patch.rate;
      v.src.playbackRate.value = patch.rate;
    }
    if (patch.loop !== undefined) {
      v.loop = patch.loop;
      v.src.loop = patch.loop;
    }
  }

  getVoice(voice: VoiceHandle): VoiceState | undefined {
    const v = this.voices.get(voice as unknown as number);
    if (v === undefined) return undefined;
    return { handle: voice, playing: true, clip: v.clip, bus: v.bus, volume: v.volume, rate: v.rate, loop: v.loop };
  }

  bus(name: string): AudioBus {
    let b = this.buses.get(name);
    if (b === undefined) {
      b = { name, volume: 1, muted: false };
      this.buses.set(name, b);
    }
    return b;
  }

  private busGain(name: string): unknown {
    let g = this.busGains.get(name);
    if (g === undefined) {
      g = this.ctx.createGain();
      g.gain.value = this.bus(name).volume;
      // 非 master 总线串到 master 上（总线音量才会叠加生效）
      const master = this.busGains.get("master");
      g.connect(master ?? this.ctx.destination);
      this.busGains.set(name, g);
    }
    return g;
  }

  setListener(_pos: { x: number; y: number; z: number }): void {
    // 未做空间化（caps.spatial = false，调用方据此降级）
  }

  get timeMs(): number {
    return this.ctx.currentTime * 1000;
  }

  get activeVoices(): number {
    return this.voices.size;
  }

  destroy(): void {
    for (const v of [...this.voices.keys()]) this.stop(v as unknown as VoiceHandle);
    this.voices.clear();
    this.clips.clear();
    for (const g of this.busGains.values()) {
      try {
        g.disconnect();
      } catch {
        // 已断开
      }
    }
    this.busGains.clear();
  }
}

export const webAudioBackend = {
  id: "webaudio",
  priority: 100,
  probe(options?: unknown): boolean {
    if (typeof (globalThis as { AudioContext?: unknown }).AudioContext === "function") return true;
    const o = (options ?? {}) as { context?: AudioContextLike };
    return typeof o.context?.createGain === "function";
  },
  create(options?: unknown): Result<IAudioDevice, EngineError> {
    const o = (options ?? {}) as { context?: AudioContextLike };
    let ctx: AudioContextLike | undefined = o.context;
    if (ctx === undefined) {
      const Ctor = (globalThis as { AudioContext?: new () => AudioContextLike }).AudioContext;
      if (Ctor === undefined) {
        return err(engineError("AUDIO.NO_CONTEXT", "当前环境没有 AudioContext"));
      }
      try {
        ctx = new Ctor();
      } catch (e) {
        return err(engineError("AUDIO.NO_CONTEXT", e instanceof Error ? e.message : String(e)));
      }
    }
    try {
      return ok(new WebAudioDevice(ctx));
    } catch (e) {
      return err(engineError("AUDIO.INIT_FAILED", e instanceof Error ? e.message : String(e)));
    }
  },
};
