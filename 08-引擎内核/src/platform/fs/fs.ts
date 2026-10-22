/**
 * L1 · 文件系统与网络接口
 *
 * ★ 文件系统接口是**异步**的（返回 Promise），即使内存实现是同步的。
 *   理由：浏览器里读文件必然异步，如果接口是同步的，将来接 IndexedDB / HTTP
 *   就得改签名 ⇒ 违反"新增功能不改核心结构"。异步签名从一开始就定死。
 *
 * ★ 路径用统一的 `scheme:path` 形式（`mem:/scenes/a.json`、`node:./assets/x.png`）。
 *   一个引擎同时有"内存虚拟盘（存档/测试）"和"真实盘"是常态，
 *   带 scheme 才能在**同一个接口**下混用，而不需要调用方自己判断来源。
 */

import type { EngineError, Result } from "../../foundation/result.ts";

export interface FileStat {
  readonly size: number;
  /** 毫秒时间戳（修改时间）。0 表示实现不提供。 */
  readonly mtimeMs: number;
  readonly isDirectory: boolean;
}

export interface FileEntry {
  readonly name: string;
  readonly path: string;
  readonly isDirectory: boolean;
  readonly size: number;
}

export interface IFileSystem {
  /** 这个实例负责的 scheme（`mem` / `node` / `http`）。 */
  readonly scheme: string;
  readText(path: string): Promise<Result<string, EngineError>>;
  readBinary(path: string): Promise<Result<Uint8Array, EngineError>>;
  writeText(path: string, text: string): Promise<Result<void, EngineError>>;
  writeBinary(path: string, data: Uint8Array): Promise<Result<void, EngineError>>;
  remove(path: string): Promise<Result<void, EngineError>>;
  exists(path: string): Promise<boolean>;
  list(dir: string): Promise<Result<readonly FileEntry[], EngineError>>;
  stat(path: string): Promise<Result<FileStat, EngineError>>;
  /** 创建目录（递归）。已存在视为成功。 */
  ensureDir(dir: string): Promise<Result<void, EngineError>>;
}

export interface FsBackendFactory {
  readonly id: string;
  readonly scheme: string;
  probe(options?: unknown): boolean;
  create(options?: unknown): Result<IFileSystem, EngineError>;
}

// ------------------------------------------------------------------ 网络

export type TransportState = "closed" | "connecting" | "open" | "closing";

export interface TransportMessage {
  readonly channel: string;
  readonly data: ArrayBuffer | string;
  readonly receivedAtMs: number;
}

export interface ITransport {
  readonly state: TransportState;
  connect(url: string, opts?: { timeoutMs?: number }): Promise<Result<void, EngineError>>;
  send(
    channel: string,
    data: ArrayBuffer | string,
    opts?: { reliable?: boolean },
  ): Result<void, EngineError>;
  onMessage(fn: (m: TransportMessage) => void): () => void;
  onClose(fn: (reason: string) => void): () => void;
  close(code?: number, reason?: string): void;
  /** 往返时延估计（毫秒）。未知返回 -1，**不要用 0 冒充"很快"**。 */
  readonly rttMs: number;
}

export interface NetBackendFactory {
  readonly id: string;
  probe(options?: unknown): boolean;
  create(options?: unknown): Result<ITransport, EngineError>;
}
