/**
 * L2 · 构建包文件系统（`bundle:`）的判据
 *
 * 这一组守的是「内容寻址的包，运行时真的被当成一个文件系统用过」。
 * 此前 `createBundleReader` 只有判据在消费（`grep` 只命中测试），
 * 真人跑的游戏一直从 `web/assets` 直读 —— 「包能被消费」这句话在宿主侧没有落点（C17）。
 *
 * 五类判据：
 *   ① **字节一致**：从包读出的字节与源文件逐字节相同（不是"能解出点什么"）；
 *   ② **清单即目录**：`canList = true` 是这里与 `fs-http` 的**语义差异**，必须钉住 ——
 *      静态服务器返回 `FS.NOT_SUPPORTED`，而这里能确定回答「这个目录下有什么」；
 *   ③ **同一个包只取一次**：读同包三个资产，`fetches` 必须是 1（首屏流量乘以十几的唯一原因）；
 *   ④ **路径归一化只有一处**：`assets/a.png` 与 `/assets/a.png` 在 exists/stat/read 三处口径一致；
 *   ⑤ **失败不伪装**：路径不存在报 NOT_FOUND（不返回空字节）、重复 path 在构造期报、
 *      hash 不符透传 `LOAD.HASH_MISMATCH`（根因在构建产物，不该在这里被翻译成 FS 错误）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { buildPublish, type PublishInput } from "../../src/extensions/build/publish.ts";
import { LOAD_HASH_MISMATCH } from "../../src/extensions/build/loader.ts";
import { BundleFileSystem, bundleFsBackend, FSBUNDLE_ERR } from "../../src/extensions/build/fs-bundle.ts";
import { resolveAssetSource, type FetchResponseLike } from "../../src/extensions/build/bundle-source.ts";
import { httpFsBackend } from "../../src/backends/fs-http/fs.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const ASSETS = join(ROOT, "web", "assets");

const BERRY = new Uint8Array(readFileSync(join(ASSETS, "berry.png")));
const PLAYER = new Uint8Array(readFileSync(join(ASSETS, "player.png")));
const LABEL = new TextEncoder().encode("中文标签/abc");

const INPUT: PublishInput = {
  // a3 也当入口：未被闭包引用的资产不进产物（`buildPublish` 的第 3 步）
  entries: ["a1", "a3"],
  assets: [
    { id: "a1", path: "/assets/berry.png", bytes: BERRY },
    { id: "a2", path: "/assets/player.png", bytes: PLAYER },
    { id: "a3", path: "/assets/ui/label.txt", bytes: LABEL },
  ],
  dependencies: new Map([["a1", ["a2"]]]),
};

function build(cfg = {}) {
  const r = buildPublish(INPUT, { maxBundleBytes: 1 << 20, ...cfg });
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  return r.value;
}

function fsOf(over: { manifest?: ReturnType<typeof build>["manifest"]; root?: string } = {}) {
  const out = build();
  const manifest = over.manifest ?? out.manifest;
  return new BundleFileSystem({ manifest, root: over.root, fetchBundle: async (h) => out.bundles.get(h)! });
}

// ---------------------------------------------------------------- ① 字节一致

test("★★ 从包读出的字节与源文件逐字节相同（三个资产、含中文文本）", async () => {
  const fs = fsOf();
  const pairs: [string, Uint8Array][] = [
    ["/assets/berry.png", BERRY],
    ["/assets/player.png", PLAYER],
    ["/assets/ui/label.txt", LABEL],
  ];
  for (const [path, want] of pairs) {
    const r = await fs.readBinary(path);
    assert.ok(r.ok, `${path}: ${r.ok ? "" : r.error.code}`);
    assert.deepEqual([...r.value], [...want], `${path} 字节不一致`);
  }
});

test("readText：中文按 UTF-8 解回原文", async () => {
  const fs = fsOf();
  const r = await fs.readText("/assets/ui/label.txt");
  assert.ok(r.ok);
  assert.equal(r.value, "中文标签/abc");
});

// ---------------------------------------------------------------- ② 清单即目录

test("★★ 能列目录（`canList = true`）：这是与 HTTP 后端的语义差异，不是宽松化", async () => {
  const fs = fsOf();
  assert.equal(fs.canList, true);
  // 与 fs-http 对比：那边没有"列目录"这个操作
  assert.equal(httpFsBackend.scheme, "http");
  const http = httpFsBackend.create({ base: "https://example.com/assets/", fetch: async () => new Response("") });
  assert.ok(http.ok);
  const listed = await http.value.list("/");
  assert.equal(listed.ok, false, "静态服务器不能列目录 —— 返回空数组会被误读成「目录是空的」");
  if (!listed.ok) assert.equal(listed.error.code, "FS.NOT_SUPPORTED");
});

test("★ 列直接子项：目录在前、同级名字升序、不递归", async () => {
  const fs = fsOf();
  const root = await fs.list("/");
  assert.ok(root.ok);
  assert.deepEqual(
    root.value.map((e) => `${e.name}${e.isDirectory ? "/" : ""}`),
    ["assets/"],
    "根下只有 assets 目录",
  );

  const assets = await fs.list("/assets");
  assert.ok(assets.ok);
  assert.deepEqual(
    assets.value.map((e) => `${e.name}${e.isDirectory ? "/" : ""}`),
    ["ui/", "berry.png", "player.png"],
    "目录在前、文件按名字升序",
  );
  assert.equal(assets.value[0]!.path, "/assets/ui");

  const ui = await fs.list("/assets/ui");
  assert.ok(ui.ok);
  assert.deepEqual(ui.value.map((e) => e.name), ["label.txt"]);
  assert.equal(ui.value[0]!.size, LABEL.length);
});

// ---------------------------------------------------------------- ③ 只取一次

test("★★ 读同包三个资产，包只取一次（首屏流量不该乘以资产数）", async () => {
  const fs = fsOf();
  await fs.readBinary("/assets/berry.png");
  await fs.readBinary("/assets/player.png");
  await fs.readBinary("/assets/ui/label.txt");
  const s = fs.stats();
  assert.equal(s.requests, 3);
  assert.equal(s.fetches, 1, "三个资产同一个包，只该取一次");
  assert.equal(s.hits, 2, "后两次命中缓存");
});

// ---------------------------------------------------------------- ④ 路径归一化

test("★ 相对路径与前导斜杠是同一处归一化（exists/stat/read 三处口径一致）", async () => {
  const fs = fsOf();
  for (const p of ["/assets/berry.png", "assets/berry.png", "assets//berry.png", "/assets/berry.png/"]) {
    assert.equal(await fs.exists(p), true, `exists(${p})`);
    const st = await fs.stat(p);
    assert.ok(st.ok, `stat(${p})`);
    assert.equal(st.value.size, BERRY.length);
    const b = await fs.readBinary(p);
    assert.ok(b.ok, `readBinary(${p})`);
  }
  // 根目录的归一化：`/` 与空尾部
  assert.equal(await fs.exists("/"), true);
});

test("★ root 挂载点：相对路径挂到它下面，绝对路径不受影响（四个入口同口径）", async () => {
  const fs = fsOf({ root: "/assets" });
  // 宿主调用点给的是相对名（`berry.png`）—— 与 fs-http 的 base URL 承担同一件事
  assert.equal(await fs.exists("berry.png"), true);
  const b = await fs.readBinary("berry.png");
  assert.ok(b.ok);
  assert.deepEqual([...b.value], [...BERRY]);
  const st = await fs.stat("berry.png");
  assert.ok(st.ok);
  assert.equal(st.value.size, BERRY.length);
  // 子目录相对路径
  assert.equal(await fs.exists("ui/label.txt"), true);
  const ui = await fs.list("ui");
  assert.ok(ui.ok);
  assert.deepEqual(ui.value.map((e) => e.name), ["label.txt"]);
  // 绝对路径仍按 manifest 的 path
  assert.equal(await fs.exists("/assets/berry.png"), true);
  // 挂载点之外仍是"不存在"（不许借 root 逃出清单）
  assert.equal(await fs.exists("nope.png"), false);
  const miss = await fs.readBinary("nope.png");
  assert.equal(miss.ok, false);
  if (!miss.ok) assert.equal(miss.error.code, FSBUNDLE_ERR.NOT_FOUND);
});

test("stat：文件大小取自 manifest，目录 isDirectory 且 size 0", async () => {
  const fs = fsOf();
  const f = await fs.stat("/assets/player.png");
  assert.ok(f.ok);
  assert.equal(f.value.isDirectory, false);
  assert.equal(f.value.size, PLAYER.length);
  assert.equal(f.value.mtimeMs, 0, "manifest 没有时间戳：0 表示实现不提供");

  const d = await fs.stat("/assets/ui");
  assert.ok(d.ok);
  assert.equal(d.value.isDirectory, true);
  assert.equal(d.value.size, 0);
});

// ---------------------------------------------------------------- ⑤ 失败不伪装

test("★ 路径不存在报 NOT_FOUND（不是返回空字节，也不是空目录）", async () => {
  const fs = fsOf();
  const r = await fs.readBinary("/assets/nope.png");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FSBUNDLE_ERR.NOT_FOUND);
  assert.equal(await fs.exists("/assets/nope.png"), false);
  const st = await fs.stat("/assets/nope.png");
  assert.equal(st.ok, false);
  const ls = await fs.list("/nope");
  assert.equal(ls.ok, false);
  if (!ls.ok) assert.equal(ls.error.code, FSBUNDLE_ERR.NOT_FOUND);
});

test("★ manifest 里两个资产同 path：构造期就报（path 不参与 hash，查起来有歧义）", () => {
  const out = build();
  const dup = {
    ...out.manifest,
    assets: [
      ...out.manifest.assets,
      { ...out.manifest.assets[0]!, id: "ghost" },
    ],
  };
  assert.throws(
    () => new BundleFileSystem({ manifest: dup, fetchBundle: async () => new Uint8Array() }),
    new RegExp(FSBUNDLE_ERR.DUPLICATE_PATH.replace(".", "\\.")),
  );
});

test("★ 资产 hash 不符时透传 LOAD.HASH_MISMATCH（根因在构建产物，不在文件系统）", async () => {
  const out = build();
  const tampered = {
    ...out.manifest,
    assets: out.manifest.assets.map((a, i) => (i === 0 ? { ...a, hash: "0".repeat(a.hash.length) } : a)),
  };
  const fs = new BundleFileSystem({ manifest: tampered, fetchBundle: async (h) => out.bundles.get(h)! });
  const target = tampered.assets[0]!;
  const r = await fs.readBinary(target.path);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, LOAD_HASH_MISMATCH);
});

test("后端工厂：没有 manifest 时 create 明确报错、probe 为 false", () => {
  assert.equal(bundleFsBackend.probe(undefined), false);
  const r = bundleFsBackend.create(undefined);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "FS.BAD_OPTIONS");

  const out = build();
  assert.equal(bundleFsBackend.probe({ manifest: out.manifest, fetchBundle: async () => new Uint8Array() }), true);
});

// ---------------------------------------------------------------- ⑥ 来源决策（接线）

function textRes(text: string): FetchResponseLike {
  return { ok: true, status: 200, text: async () => text, arrayBuffer: async () => new ArrayBuffer(0) };
}

function binRes(bytes: Uint8Array): FetchResponseLike {
  const copy = new Uint8Array(bytes);
  return { ok: true, status: 200, text: async () => "", arrayBuffer: async () => copy.buffer };
}

test("★★ 来源决策：没有 pack 参数 ⇒ 走直读，且**不调 fetch、不 warn**", async () => {
  const fallback = fsOf();
  let fetched = 0;
  const warned: string[] = [];
  const fs = await resolveAssetSource({
    packParam: null,
    pageHref: "https://h/game/index.html",
    fallback: () => fallback,
    fetchLike: async () => {
      fetched++;
      return textRes("");
    },
    warn: (m) => warned.push(m),
  });
  assert.equal(fs, fallback, "默认路径必须原样返回直读后端");
  assert.equal(fetched, 0, "没有 pack 参数时一次网络都不该发");
  assert.deepEqual(warned, []);
});

test("★★ 来源决策：pack 有效 ⇒ 返回包后端，能读出真实字节（URL 解析到 manifest 同目录的 bundles/）", async () => {
  const out = build();
  const urls: string[] = [];
  const warned: string[] = [];
  const fs = await resolveAssetSource({
    packParam: "out/manifest.json",
    pageHref: "https://h/game/index.html",
    root: "/assets",
    fallback: () => fsOf(),
    warn: (m) => warned.push(m),
    fetchLike: async (url) => {
      urls.push(url);
      if (url.endsWith("manifest.json")) return textRes(JSON.stringify(out.manifest));
      const m = /bundles\/([0-9a-f]+)\.bin$/.exec(url);
      const b = m === null ? undefined : out.bundles.get(m[1]!);
      if (b === undefined) return { ok: false, status: 404, text: async () => "", arrayBuffer: async () => new ArrayBuffer(0) };
      return binRes(b);
    },
  });
  assert.deepEqual(warned, [], "有效 manifest 不该触发退回");
  assert.ok(fs instanceof BundleFileSystem);
  assert.equal(urls[0], "https://h/game/out/manifest.json");
  const r = await fs.readBinary("berry.png");
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.deepEqual([...r.value], [...BERRY]);
});

test("★★ 来源决策：pack 取不到 ⇒ 退回直读**并留痕**（静默退回等于长期假象）", async () => {
  const fallback = fsOf();
  const warned: string[] = [];
  const fs = await resolveAssetSource({
    packParam: "out/manifest.json",
    pageHref: "https://h/game/index.html",
    fallback: () => fallback,
    fetchLike: async () => ({ ok: false, status: 404, text: async () => "", arrayBuffer: async () => new ArrayBuffer(0) }),
    warn: (m) => warned.push(m),
  });
  assert.equal(fs, fallback);
  assert.equal(warned.length, 1);
  assert.ok(warned[0]!.includes("退回直读"), warned[0]);
});

test("★★ 来源决策：manifest 内容坏了（schema 不认）也退回直读，且 warn 里带错误码", async () => {
  const out = build();
  const bad = { ...out.manifest, schema: 99 };
  const fallback = fsOf();
  const warned: string[] = [];
  const fs = await resolveAssetSource({
    packParam: "out/manifest.json",
    pageHref: "https://h/game/index.html",
    fallback: () => fallback,
    fetchLike: async () => textRes(JSON.stringify(bad)),
    warn: (m) => warned.push(m),
  });
  assert.equal(fs, fallback, "schema 不认的产物必须退回去，而不是带着一知半解的结构继续跑");
  assert.equal(warned.length, 1);
  assert.ok(warned[0]!.includes("LOAD.BAD_MANIFEST"), warned[0]);
});
