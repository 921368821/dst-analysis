/**
 * L5 后端 · `fs-storage`：把 `localStorage` 当成文件系统。
 *
 * 存在理由与 `fs-http` 同源：浏览器宿主的存档一直直接 `localStorage.setItem(SAVE_KEY, json)`，
 * 于是"存档"这件事在浏览器里是一条**旁路**：
 *   · 没有版本闸门（直到 `sceneFromJson` 才查，而 save 侧什么都不查）；
 *   · 没有路径概念（一个硬编码 key，多存档位就得自己拼字符串）；
 *   · 没有错误通道（`setItem` 抛配额异常时，调用方只看见一个冒泡的 `Error`）。
 * 收到 `IFileSystem` 之后，浏览器与 Node 用同一套存档代码、同一套错误码。
 *
 * ★ 三件必须说清楚的事（都来自 "localStorage 不是一个文件系统"）：
 *  ① **它只存字符串**。二进制一律 base64（膨胀 4/3）。存档是 JSON，实际影响很小，
 *     但**不能假装没这回事** —— 大小上限（通常 5MB）是按 base64 之后的字符数算的。
 *  ② **它没有目录**。目录用一个索引键维护（`<prefix>d`），`list`/`stat` 从索引推出来。
 *     索引坏了要能自愈（读时重建，而不是直接报错让用户去删 storage）。
 *  ③ **它没有修改时间**。`mtimeMs` 由我们自己写进记录里；这也意味着
 *     "别的标签页改了同一个 key" 时我们看不到 —— 已知限制，单标签假设。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";
import type { FileEntry, FileStat } from "../../platform/fs/fs.ts";
import { normalizeVirtualPath, virtualPathOf } from "../../platform/fs/virtual-path.ts";

/** `localStorage` 的最小结构（便于判据注入内存实现）。 */
export interface StorageLike {
  readonly length: number;
  key(index: number): string | null;
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export interface StorageFsOptions {
  readonly storage: StorageLike;
  /** 键前缀：同一个 storage 里多份工程/多个版本互不干扰。 */
  readonly prefix?: string;
}

interface FileRecord {
  /** 写入时间（毫秒）。 */
  readonly t: number;
  /** 字节数（base64 长度反推会差 padding，所以直接记）。 */
  readonly n: number;
  /** base64 内容。 */
  readonly b: string;
}

export class StorageFileSystem implements IFileSystem {
  readonly scheme = "storage";
  readonly canList = true;

  private readonly storage: StorageLike;
  private readonly prefix: string;
  private clock = 1;

  constructor(opts: StorageFsOptions) {
    this.storage = opts.storage;
    this.prefix = opts.prefix ?? "";
  }

  // ---------------------------------------------------------------- 写

  async writeText(path: string, text: string): Promise<Result<void, EngineError>> {
    return this.writeBinary(path, new TextEncoder().encode(text));
  }

  async writeBinary(path: string, data: Uint8Array): Promise<Result<void, EngineError>> {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    if (segs.value.length === 0) {
      return err(engineError("FS.IS_DIR", "不能往根路径写文件"));
    }
    const vpath = virtualPathOf(segs.value);
    const dirs = this.dirs();
    // 自动建父目录（与 mem/node 一致：写入不需要先 ensureDir）
    for (let i = 1; i < segs.value.length; i++) {
      dirs.add(virtualPathOf(segs.value.slice(0, i)));
    }
    // 覆盖写一个目录 → 拒绝（否则 list 会同时看到"目录"和同名文件）
    if (dirs.has(vpath)) {
      return err(engineError("FS.IS_DIR", `目标是一个目录：${vpath}`));
    }
    const rec: FileRecord = { t: this.now(), n: data.byteLength, b: toBase64(data) };
    const w = this.set(this.keyOf(vpath), JSON.stringify(rec));
    if (!w.ok) return w;
    return this.writeDirs(dirs);
  }

  async remove(path: string): Promise<Result<void, EngineError>> {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const vpath = virtualPathOf(segs.value);
    const dirs = this.dirs();
    if (dirs.has(vpath)) {
      // ★ 与 mem/node 同一立场：删目录不静默删子树
      return err(engineError("FS.IS_DIR", `这是一个目录，不能当文件删：${vpath}`));
    }
    if (this.storage.getItem(this.keyOf(vpath)) === null) {
      return err(engineError("FS.NOT_FOUND", `要删除的路径不存在：${vpath}`));
    }
    this.storage.removeItem(this.keyOf(vpath));
    return ok(undefined);
  }

  async ensureDir(dir: string): Promise<Result<void, EngineError>> {
    const segs = normalizeVirtualPath(dir);
    if (!segs.ok) return segs;
    const dirs = this.dirs();
    for (let i = 0; i <= segs.value.length; i++) {
      dirs.add(virtualPathOf(segs.value.slice(0, i)));
    }
    return this.writeDirs(dirs);
  }

  // ---------------------------------------------------------------- 读

  async readText(path: string): Promise<Result<string, EngineError>> {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `不是合法 UTF-8：${path}（${msg(e)}）`));
    }
  }

  async readBinary(path: string): Promise<Result<Uint8Array, EngineError>> {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const vpath = virtualPathOf(segs.value);
    if (this.dirs().has(vpath)) {
      return err(engineError("FS.IS_DIR", `路径是一个目录：${vpath}`));
    }
    const rec = this.record(vpath);
    if (!rec.ok) return rec;
    try {
      return ok(fromBase64(rec.value.b));
    } catch (e) {
      return err(engineError("FS.IO", `存档记录损坏（base64 解不开）：${vpath}（${msg(e)}）`));
    }
  }

  async exists(path: string): Promise<boolean> {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return false;
    const vpath = virtualPathOf(segs.value);
    return this.dirs().has(vpath) || this.storage.getItem(this.keyOf(vpath)) !== null;
  }

  async stat(path: string): Promise<Result<FileStat, EngineError>> {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const vpath = virtualPathOf(segs.value);
    if (this.dirs().has(vpath)) return ok({ size: 0, mtimeMs: 0, isDirectory: true });
    const rec = this.record(vpath);
    if (!rec.ok) return rec;
    return ok({ size: rec.value.n, mtimeMs: rec.value.t, isDirectory: false });
  }

  async list(dir: string): Promise<Result<readonly FileEntry[], EngineError>> {
    const segs = normalizeVirtualPath(dir);
    if (!segs.ok) return segs;
    const base = virtualPathOf(segs.value);
    const dirs = this.dirs();
    // ★ 不存在的目录必须报错，不是返回 []（与 mem/node 一致）：
    //   [] 的含义是"这个目录是空的"，会让调用方以为"目录存在但没有资产"。
    if (!dirs.has(base)) {
      return err(engineError("FS.NOT_FOUND", `目录不存在：${base}`));
    }
    const prefix = base === "/" ? "/" : base + "/";
    const seen = new Map<string, FileEntry>();

    for (const d of dirs) {
      if (!d.startsWith(prefix) || d === base) continue;
      const rest = d.slice(prefix.length);
      if (rest === "" || rest.includes("/")) continue;
      seen.set(rest, { name: rest, path: prefix + rest, isDirectory: true, size: 0 });
    }
    for (const k of this.filePaths()) {
      if (!k.startsWith(prefix)) continue;
      const rest = k.slice(prefix.length);
      if (rest === "" || rest.includes("/")) continue;
      if (seen.has(rest)) continue; // 目录优先（同名文件不该出现，写了会被拒）
      const rec = this.recordRaw(k);
      seen.set(rest, {
        name: rest,
        path: prefix + rest,
        isDirectory: false,
        size: rec === null ? 0 : rec.n,
      });
    }
    const out = [...seen.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return ok(out);
  }

  // ---------------------------------------------------------------- 内部

  private now(): number {
    // 单调递增：同一毫秒内连写两次也要能区分先后（判据会断言 mtime 非 0）
    this.clock = Math.max(Date.now(), this.clock + 1);
    return this.clock;
  }

  private keyOf(vpath: string): string {
    return `${this.prefix}f:${vpath}`;
  }

  private dirsKey(): string {
    return `${this.prefix}d`;
  }

  private set(key: string, value: string): Result<void, EngineError> {
    try {
      this.storage.setItem(key, value);
      return ok(undefined);
    } catch (e) {
      // localStorage 写满时抛 QuotaExceededError —— 这是**存储满了**，不是别的
      return err(engineError("FS.NO_SPACE", `写入失败（storage 满或不可写）：${msg(e)}`));
    }
  }

  /** 目录索引。读坏了就当空集（自愈），不把用户卡在"删 storage 才能用"。 */
  private dirs(): Set<string> {
    const out = new Set<string>(["/"]);
    const raw = this.storage.getItem(this.dirsKey());
    if (raw === null) return out;
    try {
      const arr = JSON.parse(raw) as unknown;
      if (Array.isArray(arr)) for (const p of arr) if (typeof p === "string") out.add(p);
    } catch {
      // 索引损坏：从文件路径**重建**（文件才是真数据，索引只是派生）
      const rebuilt = new Set<string>(["/"]);
      for (const p of this.filePaths()) {
        const segs = p.split("/").filter((s) => s !== "");
        for (let i = 0; i < segs.length; i++) rebuilt.add("/" + segs.slice(0, i).join("/"));
      }
      return rebuilt;
    }
    return out;
  }

  private writeDirs(dirs: Set<string>): Result<void, EngineError> {
    return this.set(this.dirsKey(), JSON.stringify([...dirs].sort()));
  }

  /** 所有以 `prefix + "f:"` 开头的键 → 虚拟路径。 */
  private filePaths(): string[] {
    const out: string[] = [];
    const head = `${this.prefix}f:`;
    for (let i = 0; i < this.storage.length; i++) {
      const k = this.storage.key(i);
      if (k === null || !k.startsWith(head)) continue;
      out.push(k.slice(head.length));
    }
    return out;
  }

  private recordRaw(vpath: string): FileRecord | null {
    const raw = this.storage.getItem(this.keyOf(vpath));
    if (raw === null) return null;
    try {
      const o = JSON.parse(raw) as Partial<FileRecord>;
      if (typeof o.b !== "string" || typeof o.n !== "number" || typeof o.t !== "number") return null;
      return { t: o.t, n: o.n, b: o.b };
    } catch {
      return null;
    }
  }

  private record(vpath: string): Result<FileRecord, EngineError> {
    const raw = this.storage.getItem(this.keyOf(vpath));
    if (raw === null) return err(engineError("FS.NOT_FOUND", `文件不存在：${vpath}`));
    const rec = this.recordRaw(vpath);
    if (rec === null) return err(engineError("FS.IO", `存档记录损坏（不是合法记录）：${vpath}`));
    return ok(rec);
  }
}

// ---------------------------------------------------------------- base64
//
// 不用 `Buffer`（浏览器里没有），也不用 `btoa`（Node 里对二进制字符串不友好、
// 且大数组一次性展开会让栈溢出）。自己写，两行循环，两端行为完全一致。

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function toBase64(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]!;
    const b = i + 1 < bytes.length ? bytes[i + 1]! : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2]! : 0;
    out += B64[a >> 2];
    out += B64[((a & 0x03) << 4) | (b >> 4)];
    out += i + 1 < bytes.length ? B64[((b & 0x0f) << 2) | (c >> 6)] : "=";
    out += i + 2 < bytes.length ? B64[c & 0x3f] : "=";
  }
  return out;
}

export function fromBase64(s: string): Uint8Array {
  const clean = s.replace(/=+$/, "");
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let o = 0;
  let acc = 0;
  let bits = 0;
  for (let i = 0; i < clean.length; i++) {
    const v = B64.indexOf(clean[i]!);
    if (v < 0) throw new Error(`非法 base64 字符 ${JSON.stringify(clean[i])}（位置 ${i}）`);
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (acc >> bits) & 0xff;
    }
  }
  return o === out.length ? out : out.subarray(0, o);
}

function msg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export const storageFsBackend = {
  id: "storage",
  scheme: "storage",
  probe(options?: unknown): boolean {
    const o = options as StorageFsOptions | undefined;
    return o !== undefined && o.storage !== undefined;
  },
  create(options?: unknown): Result<IFileSystem, EngineError> {
    const o = options as StorageFsOptions | undefined;
    if (o === undefined || o.storage === undefined) {
      return err(engineError("FS.BAD_OPTIONS", "StorageFileSystem 必须给 storage（localStorage 或等价物）"));
    }
    return ok(new StorageFileSystem(o));
  },
} as const;
