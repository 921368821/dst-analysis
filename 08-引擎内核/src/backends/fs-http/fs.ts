/**
 * L5 后端 · `fs-http`：把静态资源当成只读文件系统。
 *
 * 存在理由：浏览器宿主里"读资产"一直是**内联 `fetch`**，绕过了 `IFileSystem`：
 *   - 路径解析各自一份（`new URL('assets/'+file, location)` 抄在宿主里）；
 *   - 错误各自一套（404 被 `res.ok` 判断成"降级路径"）；
 *   - 于是"资产读不到"在宿主里是一种样子，在 Node 里是另一种样子，
 *     而导入管线只认识后者（`FS.NOT_FOUND`）。
 * 收到 `IFileSystem` 之下以后，**两个宿主的失败形状一致**，判据也能覆盖。
 *
 * ★ 只读：本后端**不实现** `IFileSystem`，只实现 `IReadableFileSystem`。
 *   这不是"写方法返回错误"的另一种写法 —— 类型上就传不进需要写的 API。
 *   静态资源服务器确实没有"写"这个操作，装出来只会骗过编译器。
 *
 * ★ `canList = false`：HTTP 没有"列出目录"这个操作。
 *   `list` 必须报 `FS.NOT_SUPPORTED`，**不能返回空数组** ——
 *   空数组的含义是"目录是空的"，会让资产导入以为一个资产都没有（然后安静地什么都不做）。
 *
 * ★ 路径必须**先归一、再拼 URL、最后再核一次前缀**：
 *   三道都要，因为 `encodeURIComponent` 之后 `%2e%2e` 这类写法会被某些服务器解码回 `..`。
 *   只靠"我拒绝过 `..`"是不够的（那三道里任何一道单独失效都会破防）。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { FileEntry, FileStat, IReadableFileSystem } from "../../platform/fs/fs.ts";
import { normalizeVirtualPath } from "../../platform/fs/virtual-path.ts";

/** `fetch` 的最小结构（便于判据注入，不必伪造整个 `Response`）。 */
export interface FetchLike {
  (url: string, init?: { method?: string; headers?: Record<string, string>; signal?: AbortSignal }): Promise<{
    readonly status: number;
    readonly headers: { get(name: string): string | null };
    arrayBuffer(): Promise<ArrayBuffer>;
    body?: { cancel(): void } | null;
  }>;
}

export interface HttpFsOptions {
  /** 资源根（必须以 `/` 结尾，或者是个目录 URL）。`/a.png` 会拼到它后面。 */
  readonly base: string | URL;
  /** 默认用全局 `fetch`；判据注入假的。 */
  readonly fetch?: FetchLike;
  /** 单次请求上限（毫秒）。默认 15s。 */
  readonly timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 15_000;

export class HttpFileSystem implements IReadableFileSystem {
  readonly scheme = "http";
  readonly canList = false;

  private readonly base: URL;
  private readonly doFetch: FetchLike;
  private readonly timeoutMs: number;

  constructor(opts: HttpFsOptions) {
    const base = typeof opts.base === "string" ? new URL(opts.base) : new URL(opts.base.href);
    if (base.protocol !== "http:" && base.protocol !== "https:") {
      throw new Error(`fs-http：base 必须是 http/https，实际 ${base.protocol}`);
    }
    // 统一成"目录"形式：`https://h/a` 与 `https://h/a/` 拼出来是两回事
    if (!base.pathname.endsWith("/")) base.pathname += "/";
    this.base = base;

    // ★ 必须 `bind(globalThis)`：浏览器里的 `fetch` 要求 `this === window`，
    //   把裸引用存进字段再调用会抛 `TypeError: Illegal invocation`。
    //   这个坑**只能在真浏览器里复现** —— Node 的假 fetch 是普通函数，测试永远抓不到。
    const f =
      opts.fetch ??
      (typeof globalThis.fetch === "function" ? (globalThis.fetch.bind(globalThis) as FetchLike) : undefined);
    if (f === undefined) {
      throw new Error("fs-http：环境里没有 fetch（浏览器需要 polyfill，Node < 18 请显式传入）");
    }
    this.doFetch = f;
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  // ---------------------------------------------------------------- 读

  async readBinary(path: string): Promise<Result<Uint8Array, EngineError>> {
    const url = this.urlOf(path);
    if (!url.ok) return url;
    const res = await this.request(url.value, "GET", path);
    if (!res.ok) return res;
    try {
      const buf = await res.value.arrayBuffer();
      return ok(new Uint8Array(buf));
    } catch (e) {
      return err(engineError("FS.IO", `读响应体失败：${path}（${msg(e)}）`));
    }
  }

  async readText(path: string): Promise<Result<string, EngineError>> {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      // ★ fatal:true —— 非 UTF-8 必须报错，不能返回一堆替换字符（U+FFFD）。
      //   替换字符会让"资产编码错了"看起来像"文本内容就是这样的"。
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `不是合法 UTF-8：${path}（${msg(e)}）`));
    }
  }

  /**
   * 用 HEAD 探存在性；有的静态服务器不支持 HEAD（405/501），退回带 `Range` 的 GET。
   *
   * ★ 返回 boolean 而不是 Result：`exists` 的签名没有错误通道。
   *   所以这里对"说不清"的响应（500、超时）一律 false ——
   *   **保守**是关键：把不确定说成"存在"会让调用方去读一个读不到的东西。
   */
  async exists(path: string): Promise<boolean> {
    const url = this.urlOf(path);
    if (!url.ok) return false;
    let res = await this.raw(url.value, "HEAD");
    if (res !== null && (res.status === 405 || res.status === 501)) {
      res = await this.raw(url.value, "GET", { Range: "bytes=0-0" });
      res?.body?.cancel();
    }
    return res !== null && res.status >= 200 && res.status < 300;
  }

  async stat(path: string): Promise<Result<FileStat, EngineError>> {
    const url = this.urlOf(path);
    if (!url.ok) return url;
    let res = await this.request(url.value, "HEAD", path, { allowBodyless: true });
    // 服务器不支持 HEAD → 用 Range 退一步（只取 1 字节，不整份下载）
    if (!res.ok && res.error.code === "FS.NOT_SUPPORTED") {
      res = await this.request(url.value, "GET", path, { headers: { Range: "bytes=0-0" } });
    }
    if (!res.ok) return res;
    const lenText = res.value.headers.get("content-length");
    const len = lenText === null ? NaN : Number(lenText);
    const lm = res.value.headers.get("last-modified");
    return ok({
      // 没有 Content-Length（分块传输）时给 0：**未知 ≠ 非零**，0 是唯一不会撒谎的默认
      size: Number.isFinite(len) && len >= 0 ? len : 0,
      mtimeMs: lm === null ? 0 : parseHttpDate(lm),
      isDirectory: false,
    });
  }

  async list(dir: string): Promise<Result<readonly FileEntry[], EngineError>> {
    // ★ 不返回 `[]`。空数组 = "目录是空的"，而这里的真相是"这个后端不会列目录"。
    return err(
      engineError(
        "FS.NOT_SUPPORTED",
        `HTTP 后端没有目录列举能力（静态资源服务器不提供列目录）：${dir}`,
      ),
    );
  }

  // ---------------------------------------------------------------- 内部

  /** 虚拟路径 → URL。三道防线：归一、编码、前缀核对。 */
  private urlOf(path: string): Result<URL, EngineError> {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const rel = segs.value.map((s) => encodeURIComponent(s)).join("/");
    let url: URL;
    try {
      url = new URL(rel, this.base);
    } catch (e) {
      return err(engineError("FS.BAD_PATH", `路径无法拼成 URL：${path}（${msg(e)}）`));
    }
    // 前缀核对：编码后仍然必须落在 base 之下（防 `%2e%2e/` 这类绕过）
    if (!url.href.startsWith(this.base.href)) {
      return err(engineError("FS.PATH_ESCAPE", `路径逃出了资源根：${path}`));
    }
    return ok(url);
  }

  /** 发请求并做状态码映射（唯一一处把 HTTP 状态翻成引擎错误码）。 */
  private async request(
    url: URL,
    method: "GET" | "HEAD",
    path: string,
    opts: { headers?: Record<string, string>; allowBodyless?: boolean } = {},
  ): Promise<Result<{ status: number; headers: { get(n: string): string | null }; arrayBuffer(): Promise<ArrayBuffer> }, EngineError>> {
    let res: Awaited<ReturnType<FetchLike>> | null;
    try {
      res = await this.doFetch(url.href, {
        method,
        ...(opts.headers === undefined ? {} : { headers: opts.headers }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      // 网络层失败（DNS、CORS、超时、断连）统一成 FS.IO：对调用方来说都是"读不到"
      return err(engineError("FS.IO", `请求失败：${path}（${msg(e)}）`));
    }
    const st = res.status;
    if (st >= 200 && st < 300) return ok(res);
    if (st === 404 || st === 410) return err(engineError("FS.NOT_FOUND", `资源不存在：${path}（HTTP ${st}）`));
    if (st === 401 || st === 403) {
      return err(engineError("FS.PERMISSION", `没有权限读取：${path}（HTTP ${st}）`));
    }
    if (st === 405 || st === 501) {
      return err(engineError("FS.NOT_SUPPORTED", `服务器不支持 ${method}：${path}（HTTP ${st}）`));
    }
    return err(engineError("FS.IO", `HTTP ${st}：${path}`));
  }

  /** 只要状态码的场景（`exists`）。失败返回 null，不抛。 */
  private async raw(url: URL, method: "GET" | "HEAD", headers?: Record<string, string>) {
    try {
      return await this.doFetch(url.href, {
        method,
        ...(headers === undefined ? {} : { headers }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      return null;
    }
  }
}

function parseHttpDate(s: string): number {
  const t = Date.parse(s);
  return Number.isFinite(t) ? t : 0;
}

function msg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** 后端工厂（不进注册表，理由见文件头与 `createHttpFs` 的注释）。 */
export const httpFsBackend = {
  id: "http",
  scheme: "http",
  probe(options?: unknown): boolean {
    const o = options as HttpFsOptions | undefined;
    return o !== undefined && o.base !== undefined && typeof fetch === "function";
  },
  create(options?: unknown): Result<IReadableFileSystem, EngineError> {
    const o = options as HttpFsOptions | undefined;
    if (o === undefined || o.base === undefined) {
      return err(engineError("FS.BAD_OPTIONS", "HttpFileSystem 必须给 base（资源根 URL）"));
    }
    try {
      return ok(new HttpFileSystem(o));
    } catch (e) {
      return err(engineError("FS.BAD_OPTIONS", msg(e)));
    }
  },
} as const;
