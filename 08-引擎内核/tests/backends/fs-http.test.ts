/**
 * `fs-http` 后端：只读契约 + HTTP 特有的失败形状。
 *
 * ★ 为什么用假 `fetch` 而不是起一个真服务器：
 *   判据要验的是"HTTP 状态 → 引擎错误码"的映射与"路径 → URL"的拼接，
 *   这两件事**不需要真实网络**。起服务器会让判据依赖端口、防火墙与 OS
 *   （本仓库的 CI 是 Windows + Linux 双矩阵，多一个 OS 依赖就多一种假红）。
 *   真服务器留给浏览器端自检（那里才需要真网络）。
 *
 * ★ 但假 fetch 有个天然陷阱：它太听话。所以下面专门有几条"坏服务器"用例 ——
 *   不支持 HEAD、不发 Content-Length、500、直接抛异常。真服务器会干的事，假服务器也得干。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { HttpFileSystem, httpFsBackend, type FetchLike } from "../../src/backends/fs-http/fs.ts";
import { FIXTURE_FILES, runReadContract } from "../contract/fs.contract.ts";

const BASE = "https://example.test/assets/";

interface Resp {
  readonly status: number;
  readonly headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
  body?: { cancel(): void } | null;
}

function resp(status: number, body: Uint8Array, headers: Record<string, string> = {}): Resp {
  const lower = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    status,
    headers: { get: (n) => lower.get(n.toLowerCase()) ?? null },
    arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) as ArrayBuffer,
  };
}

interface ServerOpts {
  /** false = 不支持 HEAD（返回 405），真服务器常见 */
  readonly supportHead?: boolean;
  /** true = 不发 Content-Length（分块传输） */
  readonly dropLength?: boolean;
  /** 指定路径返回 500 */
  readonly failPath?: string;
  /** 每次请求都抛（模拟断网/CORS） */
  readonly throwAll?: boolean;
}

function makeServer(opts: ServerOpts = {}) {
  const calls: Array<{ url: string; method: string }> = [];
  const routes = new Map<string, Uint8Array>();
  for (const f of FIXTURE_FILES) routes.set(new URL(f.path.slice(1), BASE).href, f.bytes);

  const fetch: FetchLike = async (url, init) => {
    const method = init?.method ?? "GET";
    calls.push({ url, method });
    if (opts.throwAll === true) throw new TypeError("Failed to fetch（模拟断网）");
    if (method === "HEAD" && opts.supportHead === false) return resp(405, new Uint8Array(0));
    if (opts.failPath !== undefined && url.endsWith(opts.failPath)) return resp(500, new Uint8Array(0));
    const body = routes.get(url);
    if (body === undefined) return resp(404, new Uint8Array(0));
    const headers: Record<string, string> = { "last-modified": "Wed, 22 Oct 2026 10:00:00 GMT" };
    if (opts.dropLength !== true) headers["content-length"] = String(body.byteLength);
    // HEAD 的响应没有 body，但 Content-Length 仍然是资源的长度（真服务器如此）
    return resp(200, method === "HEAD" ? new Uint8Array(0) : body, headers);
  };
  return { fetch, calls };
}

function httpFs(opts: ServerOpts = {}): { fs: HttpFileSystem; calls: Array<{ url: string; method: string }> } {
  const s = makeServer(opts);
  return { fs: new HttpFileSystem({ base: BASE, fetch: s.fetch }), calls: s.calls };
}

// 与 mem / node 同一套只读契约
runReadContract("http", () => httpFs().fs);

// ------------------------------------------------------------------ HTTP 特有

test("[http] 只读：类型上没有写方法（不是「写了就报错」，是**根本没有**）", () => {
  const { fs } = httpFs();
  for (const m of ["writeText", "writeBinary", "remove", "ensureDir"]) {
    assert.equal(m in fs, false, `只读后端不该有 ${m} —— 有它就能被传进需要写的 API`);
  }
  assert.equal(fs.canList, false, "HTTP 没有目录列举能力，必须显式声明");
  assert.equal(fs.scheme, "http");
});

test("[http] base 结尾没有斜杠时，拼出来仍是 base 之下（不是把最后一段吃掉）", async () => {
  const s = makeServer();
  // 注意 base 给的是 .../assets（无尾斜杠）
  const fs = new HttpFileSystem({ base: "https://example.test/assets", fetch: s.fetch });
  assert.equal((await fs.readBinary("/raw.bin")).ok, true);
  assert.deepEqual(s.calls.map((c) => c.url), [`${BASE}raw.bin`]);
});

test("[http] 状态码映射：404 → NOT_FOUND，500 → FS.IO，断网 → FS.IO（不抛）", async () => {
  const notFound = httpFs();
  const r404 = await notFound.fs.readBinary("/nope.bin");
  assert.equal(r404.ok, false);
  if (!r404.ok) assert.equal(r404.error.code, "FS.NOT_FOUND");

  const bad = httpFs({ failPath: "/raw.bin" });
  const r500 = await bad.fs.readBinary("/raw.bin");
  assert.equal(r500.ok, false);
  if (!r500.ok) assert.equal(r500.error.code, "FS.IO");

  const offline = httpFs({ throwAll: true });
  const rOff = await offline.fs.readBinary("/raw.bin");
  assert.equal(rOff.ok, false);
  if (!rOff.ok) assert.equal(rOff.error.code, "FS.IO");
  // exists 在断网时必须 false（签名没有错误通道，只能保守）
  assert.equal(await offline.fs.exists("/raw.bin"), false);
  // stat 也一样：报错而不是抛出
  assert.equal((await offline.fs.stat("/raw.bin")).ok, false);
});

test("[http] 服务器不支持 HEAD：stat 用 Range 退一步，exists 仍为真", async () => {
  const s = makeServer({ supportHead: false });
  const fs = new HttpFileSystem({ base: BASE, fetch: s.fetch });
  assert.equal(await fs.exists("/raw.bin"), true);
  const st = await fs.stat("/raw.bin");
  assert.equal(st.ok, true);
  if (!st.ok) return;
  assert.equal(st.value.size, 256, "退一步时必须仍然拿到正确长度");
  assert.ok(
    s.calls.some((c) => c.method === "GET"),
    "HEAD 被 405 之后没有改用 GET —— 那就永远读不到大小",
  );
});

test("[http] 没有 Content-Length：size 给 0（未知不是'非零'，也不是 NaN）", async () => {
  const { fs } = httpFs({ dropLength: true });
  const st = await fs.stat("/raw.bin");
  assert.equal(st.ok, true);
  if (!st.ok) return;
  assert.equal(Number.isNaN(st.value.size), false, "size 不能是 NaN");
  assert.equal(st.value.size, 0);
  // mtime 从 Last-Modified 解析得到（非 0），说明"缺长度"不影响其他字段
  assert.ok(st.value.mtimeMs > 0, `mtimeMs 应能从 Last-Modified 解析：${st.value.mtimeMs}`);
});

test("[http] 路径编码：空格与中文被编码，且请求 URL 始终以 base 开头", async () => {
  const s = makeServer();
  const fs = new HttpFileSystem({ base: BASE, fetch: s.fetch });
  await fs.readBinary("/图 集/a.png");
  const url = s.calls[0]!.url;
  assert.equal(url, `${BASE}${encodeURIComponent("图 集")}/${encodeURIComponent("a.png")}`);
  assert.ok(url.startsWith(BASE));
});

test("[http] 反斜杠与空路径：报 BAD_PATH（不许拼出一个「差不多」的 URL）", async () => {
  const { fs } = httpFs();
  for (const bad of ["", "a\\b.png", "/a\\..\\b"]) {
    const r = await fs.readBinary(bad);
    assert.equal(r.ok, false, `${JSON.stringify(bad)} 必须被拒绝`);
    if (!r.ok) assert.equal(r.error.code, "FS.BAD_PATH", bad);
  }
});

test("[http] 端口/协议非法时构造就失败（不给「运行时才发现」留口子）", () => {
  assert.throws(() => new HttpFileSystem({ base: "file:///c:/assets/", fetch: makeServer().fetch }), /http\/https/);
});

test("[http] 工厂：缺 base 报 BAD_OPTIONS；probe 在无 fetch 的环境返回 false", () => {
  const noBase = httpFsBackend.create({});
  assert.equal(noBase.ok, false);
  if (!noBase.ok) assert.equal(noBase.error.code, "FS.BAD_OPTIONS");

  const made = httpFsBackend.create({ base: BASE, fetch: makeServer().fetch });
  assert.equal(made.ok, true);
  if (made.ok) assert.equal(made.value.scheme, "http");

  // probe 依赖全局 fetch 是否存在：这条判据只钉"有 fetch 时给 true"，
  // 不去 mock 全局（删全局 fetch 会影响同进程其他判据）
  assert.equal(typeof globalThis.fetch, "function");
  assert.equal(httpFsBackend.probe({ base: BASE }), true);
});
