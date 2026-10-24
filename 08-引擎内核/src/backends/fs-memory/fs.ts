/**
 * L5 · 内存文件系统
 *
 * 用途（每一个都是真实需求，不是"为了测试"）：
 *  · 判据：不需要落盘、不污染工作区、可逐字节比对
 *  · 编辑器 PIE：预览世界用内存盘，退出即丢弃，绝不覆盖真实工程文件
 *  · 存档 before/after：先在内存里算好再原子落盘
 *
 * ★ 路径规范化只做**必要**的事：统一 `/`、去掉 `.`、拒绝 `..`。
 *   拒绝 `..` 而不是解析它 —— 上一代引擎的"场景名白名单"教训：
 *   越界的名字必须**被拒绝**，而不是被"聪明地"处理成别的地方。
 *   解析成绝对路径看起来更友好，实际上让"我能写到哪"变得难以推理。
 */

import { ok, err, engineError, type EngineError, type Result } from "../../foundation/result.ts";
import type { FileEntry, FileStat, IFileSystem } from "../../platform/fs/fs.ts";

function norm(path: string): Result<string, EngineError> {
  let p = path.replace(/\\/g, "/");
  if (p.startsWith("mem:")) p = p.slice(4);
  if (!p.startsWith("/")) p = "/" + p;
  const parts: string[] = [];
  for (const seg of p.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      return err(
        engineError("FS.PATH_ESCAPE", `路径里出现 ".."：${path}（拒绝，不做'聪明'的解析）`),
      );
    }
    parts.push(seg);
  }
  return ok("/" + parts.join("/"));
}

export class MemoryFileSystem implements IFileSystem {
  readonly scheme = "mem";
  /** 内存盘/真实盘都能列目录。 */
  readonly canList = true;
  private readonly files = new Map<string, { data: Uint8Array; mtimeMs: number }>();
  private readonly dirs = new Set<string>(["/"]);
  private nowCounter = 1;
  /** 写入次数：判据可以断言"没有多余的落盘"。 */
  writeCount = 0;

  /** 前缀，用于同一进程里隔离多个内存盘（`mem:/a` vs `mem:/b`）。 */
  constructor(private readonly prefix = "") {}

  private key(p: string): Result<string, EngineError> {
    const n = norm(this.prefix + p);
    return n;
  }

  async readText(path: string): Promise<Result<string, EngineError>> {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `不是合法 UTF-8：${path}（${e instanceof Error ? e.message : ""}）`));
    }
  }

  async readBinary(path: string): Promise<Result<Uint8Array, EngineError>> {
    const k = this.key(path);
    if (!k.ok) return k;
    const f = this.files.get(k.value);
    if (f === undefined) {
      // ★ 指向目录时说"它是目录"，而不是"不存在"：这两件事对调用方是**不同的决策**
      //   （一个是"路径拼错了"，一个是"我该换个接口"）。契约要求两个后端一致。
      if (this.dirs.has(k.value)) {
        return err(engineError("FS.IS_DIR", `${k.value} 是目录（这个接口只读文件）`));
      }
      return err(
        engineError("FS.NOT_FOUND", `文件不存在：${k.value}`, {
          known: Array.from(this.files.keys()).sort().slice(0, 20),
        }),
      );
    }
    return ok(f.data.slice());
  }

  async writeText(path: string, text: string): Promise<Result<void, EngineError>> {
    return this.writeBinary(path, new TextEncoder().encode(text));
  }

  async writeBinary(path: string, data: Uint8Array): Promise<Result<void, EngineError>> {
    const k = this.key(path);
    if (!k.ok) return k;
    this.files.set(k.value, { data: data.slice(), mtimeMs: this.nowCounter++ });
    this.writeCount++;
    // 自动登记父目录，让 list 能工作
    const segs = k.value.split("/").filter(Boolean);
    for (let i = 1; i <= segs.length - 1; i++) {
      this.dirs.add("/" + segs.slice(0, i).join("/"));
    }
    return ok(undefined);
  }

  async remove(path: string): Promise<Result<void, EngineError>> {
    const k = this.key(path);
    if (!k.ok) return k;
    if (!this.files.delete(k.value)) {
      // 与 fs-node 对齐：目录不是"不存在"，而是"这个接口不删目录"
      if (this.dirs.has(k.value)) {
        return err(engineError("FS.IS_DIR", `${k.value} 是目录（这个接口只删文件）`));
      }
      return err(engineError("FS.NOT_FOUND", `要删除的路径不存在：${k.value}`));
    }
    return ok(undefined);
  }

  async exists(path: string): Promise<boolean> {
    const k = this.key(path);
    if (!k.ok) return false;
    return this.files.has(k.value) || this.dirs.has(k.value);
  }

  async list(dir: string): Promise<Result<readonly FileEntry[], EngineError>> {
    const k = this.key(dir);
    if (!k.ok) return k;
    // "空目录"和"目录不存在"必须区分：前者返回 []，后者报错。
    // 混成一件事的后果是调用方永远发现不了路径拼错（契约要求两个后端一致）
    if (this.files.has(k.value)) {
      return err(engineError("FS.NOT_A_DIR", `${k.value} 是文件，不是目录`));
    }
    if (!this.dirs.has(k.value)) {
      return err(engineError("FS.NOT_FOUND", `目录不存在：${k.value}`));
    }
    const base = k.value === "/" ? "/" : k.value + "/";
    const out: FileEntry[] = [];
    for (const [p, f] of this.files) {
      if (!p.startsWith(base)) continue;
      const rest = p.slice(base.length);
      if (rest === "" || rest.includes("/")) continue; // 只列直接子项
      out.push({ name: rest, path: p, isDirectory: false, size: f.data.byteLength });
    }
    for (const d of this.dirs) {
      if (d === k.value || !d.startsWith(base)) continue;
      const rest = d.slice(base.length);
      if (rest === "" || rest.includes("/")) continue;
      out.push({ name: rest, path: d, isDirectory: true, size: 0 });
    }
    out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return ok(out);
  }

  async stat(path: string): Promise<Result<FileStat, EngineError>> {
    const k = this.key(path);
    if (!k.ok) return k;
    const f = this.files.get(k.value);
    if (f !== undefined) {
      return ok({ size: f.data.byteLength, mtimeMs: f.mtimeMs, isDirectory: false });
    }
    if (this.dirs.has(k.value)) return ok({ size: 0, mtimeMs: 0, isDirectory: true });
    return err(engineError("FS.NOT_FOUND", `路径不存在：${k.value}`));
  }

  async ensureDir(dir: string): Promise<Result<void, EngineError>> {
    const k = this.key(dir);
    if (!k.ok) return k;
    this.dirs.add(k.value);
    return ok(undefined);
  }

  // ---- 判据/编辑器便利（不在 IFileSystem 接口里，避免所有实现都要有）
  snapshotFiles(): ReadonlyMap<string, Uint8Array> {
    const m = new Map<string, Uint8Array>();
    for (const [k, v] of this.files) m.set(k, v.data.slice());
    return m;
  }

  reset(): void {
    this.files.clear();
    this.dirs.clear();
    this.dirs.add("/");
    this.writeCount = 0;
  }
}

export const memFsBackend = {
  id: "mem",
  scheme: "mem",
  priority: 50,
  probe(_options?: unknown): boolean {
    return true;
  },
  create(options?: unknown): Result<IFileSystem, EngineError> {
    const o = (options ?? {}) as { prefix?: string };
    return ok(new MemoryFileSystem(o.prefix ?? ""));
  },
};
