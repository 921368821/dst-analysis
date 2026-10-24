/**
 * L4 · 产物读取：manifest 自身 hash、包 hash、资产 hash 三道都要真的生效
 *
 * ★ 这份判据存在的理由：`build-cli.test.ts` 验的是"字节落盘"，它证明不了
 *   "运行时按 manifest 找得到、解得出、内容还对"。两边都绿才算这一环通了。
 *
 * ★ 三条 hash 各写一条反向用例（改一个字节就要红）：
 *   ① 改 manifest 的某个字段 ⇒ 自身 hash 不符；
 *   ② 取回的包被改一个字节 ⇒ 包 hash 不符；
 *   ③ 包没改、manifest 与包不配套（资产 hash 记的是别的版本）⇒ 资产 hash 不符。
 *   只验 ② 的话，"部署时 manifest 落后一版"这种最常见的故障是抓不到的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { hashBytes, hashText } from "../../src/foundation/hash.ts";
import { canonicalize } from "../../src/foundation/canonical.ts";
import { buildPublish, type PublishInput, type PublishManifest } from "../../src/extensions/build/publish.ts";
import {
  LOAD_ASSET_MISSING,
  LOAD_BAD_BUNDLE,
  LOAD_BAD_MANIFEST,
  LOAD_BUNDLE_MISSING,
  LOAD_HASH_MISMATCH,
  createBundleReader,
  parseBundle,
  parseManifest,
} from "../../src/extensions/build/loader.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const TOOL = join(ROOT, "tools", "build.ts");
const ASSETS = join(ROOT, "web", "assets");

function enc(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

/**
 * 三份小资产，p1 → p2 有依赖边。
 *
 * ★ `maxBundleBytes: 64` 是**判据的一部分**，不是随手填的数字：p1 + p2 的 framing
 *   合计 49 字节，64 才装得下同一个包。原先是 40，于是 p1/p2 被拆成两个包，
 *   "同一个包只取一次"那条判据就恒为 `fetches === 2` —— 看着红，其实测的根本不是缓存。
 */
function build(): { manifest: PublishManifest; bundles: ReadonlyMap<string, Uint8Array>; bytes: Map<string, Uint8Array> } {
  const bytes = new Map<string, Uint8Array>([
    ["p1", enc("hello world")],
    ["p2", enc("second asset bytes")],
    ["p3", enc("third")],
  ]);
  const input: PublishInput = {
    entries: ["p1", "p2"],
    assets: [...bytes].map(([id, b]) => ({ id, path: `/${id}.bin`, bytes: b })),
    dependencies: new Map([["p1", ["p2"]]]),
  };
  const r = buildPublish(input, { maxBundleBytes: 64 });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  return { manifest: r.value.manifest, bundles: r.value.bundles, bytes };
}

test("[产物读取] 包往返：解出的字节与原始逐字节相同", () => {
  const { manifest, bundles, bytes } = build();
  for (const b of manifest.bundles) {
    const parsed = parseBundle(bundles.get(b.hash)!, b.hash);
    assert.equal(parsed.ok, true, parsed.ok ? "" : parsed.error.code);
    if (!parsed.ok) throw new Error("unreachable");
    assert.deepEqual([...parsed.value.keys()].sort(), [...b.assets].sort());
    for (const id of b.assets) {
      assert.deepEqual([...parsed.value.get(id)!], [...bytes.get(id)!], `资产 ${id} 的内容不一致`);
    }
  }
});

test("[产物读取] framing 严格：截断 / 重复 id / 尾随垃圾都报 BAD_BUNDLE", () => {
  const { manifest, bundles } = build();
  const good = bundles.get(manifest.bundles[0]!.hash)!;

  const cut = parseBundle(good.subarray(0, good.length - 3));
  assert.equal(cut.ok, false);
  if (cut.ok) throw new Error("unreachable");
  assert.equal(cut.error.code, LOAD_BAD_BUNDLE, "截断必须报错，不能『能读多少算多少』");

  // 把同一个包再拼一遍 ⇒ 同一个 id 出现两次
  const dup = new Uint8Array(good.length * 2);
  dup.set(good, 0);
  dup.set(good, good.length);
  const dupR = parseBundle(dup);
  assert.equal(dupR.ok, false);
  if (dupR.ok) throw new Error("unreachable");
  assert.equal(dupR.error.code, LOAD_BAD_BUNDLE);

  // 尾随 4 个 0 字节：idLen = 0，不合法
  const tail = new Uint8Array(good.length + 4);
  tail.set(good, 0);
  const tailR = parseBundle(tail);
  assert.equal(tailR.ok, false);
  if (tailR.ok) throw new Error("unreachable");
  assert.equal(tailR.error.code, LOAD_BAD_BUNDLE);
});

test("[产物读取] 包 hash 不符：改一个字节就报 HASH_MISMATCH", () => {
  const { manifest, bundles } = build();
  const h = manifest.bundles[0]!.hash;
  const tampered = bundles.get(h)!.slice();
  const last = tampered.length - 1;
  tampered[last] = (tampered[last] ?? 0) ^ 0xff;
  const r = parseBundle(tampered, h);
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, LOAD_HASH_MISMATCH);
});

test("[产物读取] manifest：结构、schema、自身 hash 三道", () => {
  const { manifest } = build();
  const text = JSON.stringify(manifest);

  const good = parseManifest(text);
  assert.equal(good.ok, true, good.ok ? "" : good.error.code);

  const badJson = parseManifest("{ not json");
  assert.equal(badJson.ok, false);
  if (badJson.ok) throw new Error("unreachable");
  assert.equal(badJson.error.code, LOAD_BAD_MANIFEST);

  const badSchema = parseManifest(JSON.stringify({ ...manifest, schema: 99 }));
  assert.equal(badSchema.ok, false);
  if (badSchema.ok) throw new Error("unreachable");
  assert.equal(badSchema.error.code, LOAD_BAD_MANIFEST);

  // 改资产的大小但不改 hash ⇒ 自身 hash 不符（否则"改 manifest 绕过资产校验"是免费的）
  const tampered = {
    ...manifest,
    assets: manifest.assets.map((a, i) => (i === 0 ? { ...a, size: a.size + 1 } : a)),
  };
  const r = parseManifest(JSON.stringify(tampered));
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, LOAD_HASH_MISMATCH);
});

test("[产物读取] manifest 自洽但资产不在任何包里：报 BAD_MANIFEST", () => {
  const { manifest } = build();
  // 手工造一个"内部 hash 正确、但把一个资产从所有包里删掉"的 manifest
  const bundles = manifest.bundles.map((b, i) =>
    i === 0 ? { ...b, assets: b.assets.slice(1) } : b,
  );
  const body = { schema: manifest.schema, entries: manifest.entries, assets: manifest.assets, bundles };
  const canon = canonicalize(body);
  assert.equal(canon.ok, true);
  if (!canon.ok) throw new Error("unreachable");
  const hash = hashText(canon.value);
  const r = parseManifest(JSON.stringify({ ...body, hash }));
  assert.equal(r.ok, false, "资产没被打进任何包时，读取必然永远 ASSET_MISSING —— 要在加载期就说清楚");
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, LOAD_BAD_MANIFEST);
});

test("[产物读取] reader：字节正确、同一个包只取一次、未登记资产报 ASSET_MISSING", async () => {
  const { manifest, bundles, bytes } = build();
  // ★ 前置条件先行断言：否则"包上限填错 ⇒ p1/p2 分属两包"会让这条判据红了却不指向缓存
  const bundleIndex = (id: string): number => manifest.bundles.findIndex((x) => x.assets.includes(id));
  assert.equal(
    bundleIndex("p1"),
    bundleIndex("p2"),
    "前置条件：p1 与 p2 必须落在同一个包里，否则『只取一次』测的不是缓存",
  );
  assert.ok(bundleIndex("p1") >= 0, "前置条件：p1 必须被打进某个包");

  let fetches = 0;
  const reader = createBundleReader({
    manifest,
    fetchBundle: async (h) => {
      fetches++;
      const b = bundles.get(h);
      if (b === undefined) throw new Error(`no bundle ${h}`);
      return b;
    },
  });

  // p1 与 p2 在同一个包里（p1 依 p2，且包上限 64），连取两次只该 fetch 一次
  const a = await reader.get("p1");
  const b = await reader.get("p2");
  assert.equal(a.ok && b.ok, true);
  if (!a.ok || !b.ok) throw new Error("unreachable");
  assert.deepEqual([...a.value], [...bytes.get("p1")!]);
  assert.deepEqual([...b.value], [...bytes.get("p2")!]);
  assert.equal(fetches, 1, `同一个包被取了 ${String(fetches)} 次 —— 首屏流量会乘以资产数`);
  assert.equal(reader.stats().fetches, 1);
  assert.ok(reader.stats().hits >= 1, "第二次应命中缓存");

  const missing = await reader.get("nope");
  assert.equal(missing.ok, false);
  if (missing.ok) throw new Error("unreachable");
  assert.equal(missing.error.code, LOAD_ASSET_MISSING);
});

test("[产物读取] reader：取包失败报 BUNDLE_MISSING（不是抛出去）", async () => {
  const { manifest } = build();
  const reader = createBundleReader({
    manifest,
    fetchBundle: async () => {
      throw new Error("404");
    },
  });
  const r = await reader.get(manifest.assets[0]!.id);
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, LOAD_BUNDLE_MISSING);
  assert.match(r.error.message, /404/);
});

test("[产物读取] ★ 包没被改、manifest 与包不配套：资产 hash 要抓住", async () => {
  const { manifest, bundles } = build();
  // 取第一个包，把某个资产的 hash 改成别的值（不改包、不改包 hash、重算 manifest hash）
  const firstBundle = manifest.bundles[0]!;
  const victim = firstBundle.assets[0]!;
  const assets = manifest.assets.map((a) =>
    a.id === victim ? { ...a, hash: hashBytes(enc("a different version of this asset")) } : a,
  );
  const body = { schema: manifest.schema, entries: manifest.entries, assets, bundles: manifest.bundles };
  const canon = canonicalize(body);
  assert.equal(canon.ok, true);
  if (!canon.ok) throw new Error("unreachable");
  const fake: PublishManifest = { ...body, hash: hashText(canon.value) };

  const parsed = parseManifest(JSON.stringify(fake));
  assert.equal(parsed.ok, true, "这份 manifest 自身是自洽的（模拟『部署时 manifest 落后一版』）");
  if (!parsed.ok) throw new Error("unreachable");

  const reader = createBundleReader({
    manifest: parsed.value,
    fetchBundle: async (h) => bundles.get(h)!,
  });
  const r = await reader.get(victim);
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, LOAD_HASH_MISMATCH, "只验包 hash 是抓不到这种的");
});

test("[产物读取] ★ 接线：CLI 产出的 manifest.json 能被读回，资产逐字节等于源文件且能解码", async () => {
  const dir = mkdtempSync(join(tmpdir(), "engine-load-"));
  try {
    const assets = join(dir, "assets");
    mkdirSync(assets, { recursive: true });
    copyFileSync(join(ASSETS, "berry.png"), join(assets, "a.png"));
    copyFileSync(join(ASSETS, "player.png"), join(assets, "b.png"));
    writeFileSync(
      join(assets, "main.atlas.json"),
      JSON.stringify({
        textures: ["a.png", "b.png"],
        frames: { a: { x: 0, y: 0, w: 8, h: 8 }, b: { x: 8, y: 0, w: 8, h: 8 } },
      }),
      "utf8",
    );
    writeFileSync(
      join(dir, "config.json"),
      JSON.stringify({ assetRoot: "/assets", outDir: "/out", maxBundleBytes: 4096, entries: ["/assets/main.atlas.json"] }),
      "utf8",
    );

    const run = spawnSync(
      process.execPath,
      ["--experimental-transform-types", TOOL, "--config", join(dir, "config.json")],
      { cwd: dir, encoding: "utf8", env: { ...process.env, NODE_NO_WARNINGS: "1" } },
    );
    assert.equal(run.status, 0, `构建失败：${run.stdout}\n${run.stderr}`);

    const manifestR = parseManifest(readFileSync(join(dir, "out", "manifest.json"), "utf8"));
    assert.equal(manifestR.ok, true, manifestR.ok ? "" : manifestR.error.message);
    if (!manifestR.ok) throw new Error("unreachable");
    const manifest = manifestR.value;
    assert.equal(manifest.assets.length, 3, "图集 + 两张贴图");

    const reader = createBundleReader({
      manifest,
      fetchBundle: async (h) => new Uint8Array(readFileSync(join(dir, "out", "bundles", `${h}.bin`))),
    });

    for (const a of manifest.assets) {
      const r = await reader.get(a.id);
      assert.equal(r.ok, true, `${a.path}: ${r.ok ? "" : r.error.message}`);
      if (!r.ok) throw new Error("unreachable");
      // manifest 里的 path 是 scheme 路径（`/assets/a.png`），映射回临时目录
      const source = join(dir, a.path.replace(/^\//, ""));
      assert.deepEqual([...r.value], [...new Uint8Array(readFileSync(source))], `${a.path} 与源文件不一致`);
      if (a.path.endsWith(".png")) {
        const dec = decodePng(r.value);
        assert.equal(dec.ok, true, `从包里解出的 PNG 解不开：${dec.ok ? "" : dec.error.code}`);
        if (dec.ok) assert.ok(dec.value.width > 0 && dec.value.height > 0);
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
