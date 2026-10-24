/**
 * L5 · Node 文件系统后端（真实盘）
 *
 * 存在理由（不是"补一个 TODO"）：存档要能**活过进程重启**。
 * 内存盘能证明"序列化 → 反序列化"正确，但证明不了"字节真的落到了盘上、
 * 下次启动能原样读回来" —— 那两件事只有真实文件系统能证明（见 E1/E2）。
 *
 * ★ 三条设计决定，每条都有代价，代价写在旁边：
 *
 *  ① **root 沙箱**：构造时给一个根目录，所有路径都被解释成"根内的相对路径"，
 *     `..` 直接**拒绝**（与 `fs-memory` 同一策略，契约测试要求两者一致）。
 *     解析成绝对路径看起来更友好，但会让"我到底能写到哪"变得难以推理 ——
 *     上一代引擎的"场景名白名单"就是被"聪明解析"绕过去的。
 *     代价：不能直接操作根外的路径（要操作就再开一个实例）。
 *
 *  ② **符号链接不跟随**：真实路径（realpath）必须落在 root 内，否则 `FS.PATH_ESCAPE`。
 *     只比较字符串前缀是不够的 —— `root/link -> /etc` 之后 `root/link/passwd`
 *     在字符串上完全合法，在语义上已经在盘外。
 *     代价：每次读写多一次 realpath 系统调用。
 *     仍未消除的：检查与写入之间仍有 TOCTOU 窗口（同一进程内的并发写不受影响，
 *     恶意进程在我们脚下换链接则可能）。这是本地进程内的文件系统，不设防外部攻击者，
 *     但**越界必须报错**这条不能靠运气。
 *
 *  ③ **原子写**：写临时文件 → `fsync` → `rename`。存档最怕的是"写到一半断电/崩溃，
 *     留下半个文件"，而 rename 在同一卷上是原子的。
 *     代价：多一次 open/rename；Windows 上无法 fsync 目录项，
 *     所以"rename 本身是否已持久化"在 Windows 上只能靠文件系统日志 —— 如实记在这里。
 *
 * ★ 返回值里的 `path` 一律是**虚拟路径**（`/a/b`，不含 root）。
 *   否则调用方会把 OS 路径写进存档或日志，换个机器读档就崩 —— 这一类 bug 极难排查。
 */

import { mkdirSync, realpathSync } from "node:fs";
import * as fsp from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";
import { err, engineError, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { FileEntry, FileStat, IFileSystem } from "../../platform/fs/fs.ts";

/** 与 `fs-memory` **完全相同**的规范化：统一 `/`、去 `.`、拒绝 `..`。 */
function norm(path: string): Result<readonly string[], EngineError> {
  let p = path.replace(/\\/g, "/");
  if (p.startsWith("node:")) p = p.slice(5);
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
  return ok(parts);
}

/** 把 Node 的 errno 翻成稳定错误码：判据断言 code，不断言文案。 */
function mapFsError(e: unknown, path: string): EngineError {
  const code = (e as NodeJS.ErrnoException | undefined)?.code ?? "";
  const detail = { errno: code, path };
  switch (code) {
    case "ENOENT":
      return engineError("FS.NOT_FOUND", `文件不存在：${path}`, detail);
    case "EACCES":
    case "EPERM":
      return engineError("FS.PERMISSION", `没有权限：${path}`, detail);
    case "EISDIR":
      return engineError("FS.IS_DIR", `${path} 是目录（这个接口只删文件）`, detail);
    case "ENOTDIR":
      return engineError("FS.NOT_A_DIR", `${path} 的某一段不是目录`, detail);
    case "ENOTEMPTY":
      return engineError("FS.NOT_EMPTY", `目录非空：${path}`, detail);
    case "ENOSPC":
      return engineError("FS.NO_SPACE", `磁盘空间不足：${path}`, detail);
    case "EEXIST":
      return engineError("FS.EXISTS", `已存在：${path}`, detail);
    case "ENAMETOOLONG":
      return engineError("FS.NAME_TOO_LONG", `路径太长：${path}`, detail);
    default:
      return engineError(
        "FS.IO",
        `${path} 操作失败${code === "" ? "" : `（${code}）`}：${e instanceof Error ? e.message : String(e)}`,
        detail,
      );
  }
}

export class NodeFileSystem implements IFileSystem {
  readonly scheme = "node";
  /** 内存盘/真实盘都能列目录。 */
  readonly canList = true;
  /** 绝对且已 resolve 的根目录。构造后不再变。 */
  readonly root: string;
  /** 根的 realpath（解掉符号链接），越界判定用这个做前缀。 */
  private readonly realRoot: string;
  private tmpSeq = 0;
  /** 写入次数（判据可以断言"没有多余的落盘"）。 */
  writeCount = 0;

  constructor(root: string, opts: { createRoot?: boolean } = {}) {
    this.root = resolve(root);
    if (opts.createRoot !== false) mkdirSync(this.root, { recursive: true });
    try {
      this.realRoot = realpathSync(this.root);
    } catch (e) {
      // 根目录不存在且 createRoot=false 是**调用方的配置错误**，不是可预期失败
      throw new Error(`NodeFileSystem 的 root 不可用：${this.root}（${mapFsError(e, root).message}）`);
    }
  }

  private abs(segs: readonly string[]): string {
    return segs.length === 0 ? this.root : join(this.root, ...segs);
  }

  private virtual(osPath: string): string {
    const rel = osPath.slice(this.root.length).split(sep).filter(Boolean);
    return "/" + rel.join("/");
  }

  /**
   * 越界判定：从目标往上找**第一个存在的祖先**，看它的 realpath 是否在 root 内。
   * 只比较字符串前缀会漏掉"root 内的符号链接指向盘外"这一类；
   * 从存在的祖先开始比较，才能在目标还不存在（第一次写入）时也做出判断。
   */
  private async contained(target: string, given: string): Promise<Result<void, EngineError>> {
    let probe = target;
    for (;;) {
      try {
        const real = await fsp.realpath(probe);
        const inside = real === this.realRoot || real.startsWith(this.realRoot + sep);
        if (inside) return ok(undefined);
        return err(
          engineError("FS.PATH_ESCAPE", `真实路径落在根目录之外：${given}（命中 ${real}）`, {
            root: this.root,
            real,
          }),
        );
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "ENOENT") return err(mapFsError(e, given));
        const parent = dirname(probe);
        if (parent === probe) {
          return err(engineError("FS.PATH_ESCAPE", `无法定位根内的祖先目录：${given}`));
        }
        probe = parent;
      }
    }
  }

  /**
   * Windows 上 `rename` 到一个**正被打开**的目标会返回 EPERM/EBUSY，
   * 而 POSIX 允许覆盖 —— 同一段代码在两个平台上语义不同，这是实测出来的：
   * 契约里"边写边读"的那条用例在 Linux/mac 上直接过，在 Windows 上第一次就 EPERM。
   *
   * 处理方式不是"Windows 上别管原子性"，而是**重试**：读存档的进程随时可能开着文件，
   * 而写存档的等待成本只有几毫秒 —— 60 次 × 2ms 的退避。
   * 其他 errno（ENOENT / ENOSPC / EXDEV …）一律立刻上抛，不掩盖真实故障。
   */
  private async renameWithRetry(from: string, to: string): Promise<void> {
    let lastErr: unknown;
    for (let i = 0; i < 60; i++) {
      try {
        await fsp.rename(from, to);
        return;
      } catch (e) {
        lastErr = e;
        const code = (e as NodeJS.ErrnoException).code;
        if (code !== "EPERM" && code !== "EBUSY" && code !== "EACCES") throw e;
        await new Promise((r) => setTimeout(r, 2));
      }
    }
    throw lastErr;
  }

  async readText(path: string): Promise<Result<string, EngineError>> {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(
        engineError("FS.NOT_UTF8", `不是合法 UTF-8：${path}（${e instanceof Error ? e.message : ""}）`),
      );
    }
  }

  async readBinary(path: string): Promise<Result<Uint8Array, EngineError>> {
    const segs = norm(path);
    if (!segs.ok) return segs;
    const target = this.abs(segs.value);
    const g = await this.contained(target, path);
    if (!g.ok) return g;
    try {
      // 先判目录：各平台对"readFile 一个目录"的 errno 并不一致（Linux EISDIR、
      // Windows 有时是 EACCES），契约要的是**稳定错误码**，所以不靠 errno 猜
      const st = await fsp.lstat(target);
      if (st.isDirectory()) {
        return err(engineError("FS.IS_DIR", `${path} 是目录（这个接口只读文件）`));
      }
      const buf = await fsp.readFile(target);
      // 拷一份独立内存：不要把 Buffer 直接交出去（它可能来自共享池，且带 Buffer 的私有方法）
      return ok(new Uint8Array(buf));
    } catch (e) {
      return err(mapFsError(e, path));
    }
  }

  async writeText(path: string, text: string): Promise<Result<void, EngineError>> {
    return this.writeBinary(path, new TextEncoder().encode(text));
  }

  async writeBinary(path: string, data: Uint8Array): Promise<Result<void, EngineError>> {
    const segs = norm(path);
    if (!segs.ok) return segs;
    const target = this.abs(segs.value);
    const before = await this.contained(target, path);
    if (!before.ok) return before;
    let tmp = "";
    try {
      // 与 fs-memory 对齐：写入自动建父目录（契约要求两个后端语义一致）
      await fsp.mkdir(dirname(target), { recursive: true });
      // 建完再查一次：父目录可能刚被建在符号链接后面
      const after = await this.contained(target, path);
      if (!after.ok) return after;
      tmp = `${target}.tmp-${process.pid}-${++this.tmpSeq}`;
      let handle: fsp.FileHandle | undefined;
      try {
        handle = await fsp.open(tmp, "w");
        await handle.writeFile(data);
        await handle.sync(); // 先落到稳定介质，再让 rename 生效
      } finally {
        await handle?.close();
      }
      await this.renameWithRetry(tmp, target);
      this.writeCount++;
      return ok(undefined);
    } catch (e) {
      if (tmp !== "") await fsp.rm(tmp, { force: true }).catch(() => undefined);
      return err(mapFsError(e, path));
    }
  }

  async remove(path: string): Promise<Result<void, EngineError>> {
    const segs = norm(path);
    if (!segs.ok) return segs;
    const target = this.abs(segs.value);
    const g = await this.contained(target, path);
    if (!g.ok) return g;
    try {
      const st = await fsp.lstat(target);
      if (st.isDirectory()) {
        // 接口只删文件：删目录会把"整棵子树消失"变成一个静默副作用
        return err(engineError("FS.IS_DIR", `${path} 是目录（这个接口只删文件）`));
      }
      await fsp.unlink(target);
      return ok(undefined);
    } catch (e) {
      return err(mapFsError(e, path));
    }
  }

  async exists(path: string): Promise<boolean> {
    const segs = norm(path);
    if (!segs.ok) return false; // 越界路径按"不存在"回答，不抛
    const target = this.abs(segs.value);
    const g = await this.contained(target, path);
    if (!g.ok) return false;
    try {
      await fsp.lstat(target);
      return true;
    } catch {
      return false;
    }
  }

  async list(dir: string): Promise<Result<readonly FileEntry[], EngineError>> {
    const segs = norm(dir);
    if (!segs.ok) return segs;
    const target = this.abs(segs.value);
    const g = await this.contained(target, dir);
    if (!g.ok) return g;
    try {
      const ents = await fsp.readdir(target, { withFileTypes: true });
      const out: FileEntry[] = [];
      for (const ent of ents) {
        const child = join(target, ent.name);
        const vpath = this.virtual(child);
        if (ent.isDirectory()) {
          out.push({ name: ent.name, path: vpath, isDirectory: true, size: 0 });
          continue;
        }
        // 符号链接**不跟随**：它的目标可能在 root 外，跟随等于绕过沙箱。
        // 报 lstat 的大小（链接自身字节数），而不是目标文件的大小 —— 后者会误导调用方。
        const st = await fsp.lstat(child);
        out.push({ name: ent.name, path: vpath, isDirectory: false, size: st.size });
      }
      out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      return ok(out);
    } catch (e) {
      return err(mapFsError(e, dir));
    }
  }

  async stat(path: string): Promise<Result<FileStat, EngineError>> {
    const segs = norm(path);
    if (!segs.ok) return segs;
    const target = this.abs(segs.value);
    const g = await this.contained(target, path);
    if (!g.ok) return g;
    try {
      const st = await fsp.lstat(target);
      return ok({
        size: st.isDirectory() ? 0 : st.size,
        mtimeMs: Math.floor(st.mtimeMs),
        isDirectory: st.isDirectory(),
      });
    } catch (e) {
      return err(mapFsError(e, path));
    }
  }

  async ensureDir(dir: string): Promise<Result<void, EngineError>> {
    const segs = norm(dir);
    if (!segs.ok) return segs;
    const target = this.abs(segs.value);
    const g = await this.contained(target, dir);
    if (!g.ok) return g;
    try {
      await fsp.mkdir(target, { recursive: true });
      return ok(undefined);
    } catch (e) {
      return err(mapFsError(e, dir));
    }
  }
}

export const nodeFsBackend = {
  id: "node",
  scheme: "node",
  /** 优先级高于 `mem`（50）：Node 宿主有真盘就用真盘，浏览器里 probe 直接 false。 */
  priority: 80,
  probe(_options?: unknown): boolean {
    const v = (globalThis as { process?: { versions?: { node?: string } } }).process?.versions?.node;
    return typeof v === "string" && v.length > 0;
  },
  create(options?: unknown): Result<IFileSystem, EngineError> {
    const o = (options ?? {}) as { root?: unknown; createRoot?: unknown };
    if (typeof o.root !== "string" || o.root === "") {
      return err(
        engineError(
          "FS.BAD_OPTIONS",
          "NodeFileSystem 必须给 root（根目录）—— 不给就把当前工作目录当成根太危险，拒绝",
        ),
      );
    }
    try {
      return ok(
        new NodeFileSystem(o.root, { createRoot: o.createRoot !== false }),
      );
    } catch (e) {
      return err(engineError("FS.BAD_ROOT", e instanceof Error ? e.message : String(e)));
    }
  },
};
