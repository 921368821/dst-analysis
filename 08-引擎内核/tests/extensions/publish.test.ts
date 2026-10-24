/**
 * L5 · 构建发布测试（阶段 5 出口判据）
 *
 * 这个文件的两条主判据就是 ARCHITECTURE §12 写的出口判据，一字不差地翻译成断言：
 *   ① 删掉一个**未被引用**的资产后，产物**逐字节不变**；
 *   ② 改动一个资产只重打**一个**包。
 *
 * ★ 为什么第 ② 条要断言"**只有一个**包换名"而不是"包变了"：
 *   "包变了"在打成一个大包的实现里也成立 —— 而那种实现下改一个字节整包失效，
 *   CDN 缓存全废，"增量"只剩说法。判据必须能区分这两种实现。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BUILD_BAD_CONFIG,
  BUILD_DEP_MISSING,
  BUILD_DUPLICATE_ASSET,
  BUILD_ENTRY_MISSING,
  PUBLISH_SCHEMA,
  buildPublish,
  renderManifest,
  type PublishAsset,
  type PublishInput,
  type PublishOutput,
} from "../../src/extensions/build/publish.ts";
import { canonicalize } from "../../src/foundation/canonical.ts";
import { hashText } from "../../src/foundation/hash.ts";

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);

function asset(id: string, text: string): PublishAsset {
  return { id, path: `mem:/a/${id}.bin`, bytes: enc(text) };
}

function withDeps(pairs: ReadonlyArray<readonly [string, readonly string[]]>): ReadonlyMap<string, readonly string[]> {
  return new Map(pairs.map(([k, v]) => [k, v] as const));
}

function run(input: PublishInput, maxBundleBytes?: number): PublishOutput {
  const r = maxBundleBytes === undefined ? buildPublish(input) : buildPublish(input, { maxBundleBytes });
  assert.ok(r.ok, r.ok ? "" : `构建失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function errOf(input: PublishInput, maxBundleBytes?: number): { code: string; message: string } {
  const r = maxBundleBytes === undefined ? buildPublish(input) : buildPublish(input, { maxBundleBytes });
  assert.equal(r.ok, false, "本该报错却成功了");
  if (r.ok) throw new Error("unreachable");
  return r.error;
}

/** 把产物压成一个可逐字节比对的东西：manifest 文本 + 每个包的字节。 */
function dump(out: PublishOutput): string {
  const parts = [renderManifest(out.manifest)];
  for (const h of [...out.bundles.keys()].sort()) {
    parts.push(h, Buffer.from(out.bundles.get(h)!).toString("base64"));
  }
  return parts.join("\n");
}

const filler = (n: number, tag: string): string => tag.repeat(Math.ceil(n / tag.length)).slice(0, n);

/** a → b → c 三个资产，每条约 40 字节：配 64 字节上限时会各自成包。 */
function chainInput(): PublishInput {
  return {
    entries: ["a"],
    assets: [asset("a", filler(40, "a")), asset("b", filler(40, "b")), asset("c", filler(40, "c"))],
    dependencies: withDeps([
      ["a", ["b"]],
      ["b", ["c"]],
      ["c", []],
    ]),
  };
}

// ── 出口判据 ① ───────────────────────────────────────────────

test("★ 出口判据①：删掉未被引用的资产，产物逐字节不变", () => {
  const base = chainInput();
  const withJunk: PublishInput = {
    ...base,
    // 目录里多放一个草稿资产 —— 它不在任何入口闭包里
    assets: [...base.assets, asset("junk", "这个资产没人引用，不该进产物")],
    dependencies: new Map([...base.dependencies, ["junk", []] as const]),
  };
  const a = run(withJunk);
  const b = run(base);
  assert.equal(dump(a), dump(b), "未被引用的资产影响了产物");
  assert.equal(a.manifest.assets.length, 3);
  assert.equal(a.manifest.assets.some((x) => x.id === "junk"), false);
});

test("闭包按依赖求：只要求入口，依赖自动带上；兄弟草稿不带", () => {
  const out = run({
    entries: ["a"],
    assets: [asset("a", "A"), asset("b", "B"), asset("draft", "D")],
    dependencies: withDeps([
      ["a", ["b"]],
      ["b", []],
      ["draft", []],
    ]),
  });
  assert.deepEqual(out.manifest.assets.map((x) => x.id), ["a", "b"]);
});

// ── 出口判据 ② ───────────────────────────────────────────────

test("★ 出口判据②：改一个资产只让**一个**包换名，其余包 hash 与字节不变", () => {
  const before = run(chainInput(), 64);
  assert.ok(before.manifest.bundles.length >= 3, `只打了 ${String(before.manifest.bundles.length)} 个包，这条判据验不动`);

  const changed = chainInput();
  const out = run(
    { ...changed, assets: [asset("a", filler(40, "a")), asset("b", filler(40, "X")), asset("c", filler(40, "c"))] },
    64,
  );

  const hs1 = new Set(before.manifest.bundles.map((b) => b.hash));
  const hs2 = new Set(out.manifest.bundles.map((b) => b.hash));
  const common = [...hs1].filter((h) => hs2.has(h));
  assert.equal(common.length, hs1.size - 1, "改一个资产却牵动了多个包（或一个都没牵动）");
  // 没变的包，字节必须完全一致
  for (const h of common) {
    assert.deepEqual(out.bundles.get(h), before.bundles.get(h));
  }
});

test("改资产内容要同时改 manifest.hash（否则「变了却看不出来」）", () => {
  const a = run(chainInput(), 64);
  const b = run(
    { ...chainInput(), assets: [asset("a", filler(40, "Z")), asset("b", filler(40, "b")), asset("c", filler(40, "c"))] },
    64,
  );
  assert.notEqual(a.manifest.hash, b.manifest.hash);
});

// ── 确定性 ───────────────────────────────────────────────────

test("同输入两次构建，产物逐字节相同", () => {
  assert.equal(dump(run(chainInput(), 64)), dump(run(chainInput(), 64)));
});

test("entries 顺序不影响产物", () => {
  const mk = (entries: readonly string[]): PublishInput => ({ ...chainInput(), entries });
  assert.equal(dump(run(mk(["a", "b"]), 64)), dump(run(mk(["b", "a"]), 64)));
});

test("assets 数组顺序不影响产物", () => {
  const base = chainInput();
  const reversed: PublishInput = { ...base, assets: [...base.assets].reverse() };
  assert.equal(dump(run(base, 64)), dump(run(reversed, 64)));
});

// ── 包内 framing 的歧义 ──────────────────────────────────────

test("★ 包内每条资产带长度前缀：拼接不发生歧义", () => {
  // 直接拼接的话，{x:"ab", y:"c"} 与 {x:"a", y:"bc"} 的包字节都是 "abc"，
  // 于是两个**不同**的资产集合得到**相同**的包 hash —— 内容寻址失去意义
  const pack = (bx: string, by: string): PublishOutput =>
    run(
      {
        entries: ["x"],
        assets: [asset("x", bx), asset("y", by)],
        dependencies: withDeps([
          ["x", ["y"]],
          ["y", []],
        ]),
      },
      4096,
    );
  const p1 = pack("ab", "c");
  const p2 = pack("a", "bc");
  assert.equal(p1.manifest.bundles.length, 1);
  assert.equal(p2.manifest.bundles.length, 1);
  assert.notEqual(p1.manifest.bundles[0]!.hash, p2.manifest.bundles[0]!.hash);
  const b1 = p1.bundles.get(p1.manifest.bundles[0]!.hash)!;
  const b2 = p2.bundles.get(p2.manifest.bundles[0]!.hash)!;
  // frame = [u32 idLen][id][u32 dataLen][data]：x 的 id 是 1 字节
  assert.equal(b1.length, 4 + 1 + 4 + 2 + (4 + 1 + 4 + 1));
  assert.equal(b2.length, b1.length);
  assert.notDeepEqual([...b1], [...b2], "长度相同但字节必须不同");
});

test("path 不影响**包**的 hash（换目录不该让 CDN 缓存全失效）", () => {
  const a = run(chainInput(), 64);
  const base = chainInput();
  const moved: PublishInput = {
    ...base,
    assets: base.assets.map((x) => ({ ...x, path: `mem:/moved/${x.id}.bin` })),
  };
  const b = run(moved, 64);
  // ★ manifest.hash **会**变：清单里带着 path（它是排查用的展示字段）。
  //   这是可接受的 —— 清单本来就每次重新生成，真正要紧的是**包名**不变，
  //   因为包名就是 CDN 的缓存键。把这一点写清楚，比断言"两个 hash 相等"更诚实。
  assert.notEqual(a.manifest.hash, b.manifest.hash);
  assert.deepEqual(
    a.manifest.bundles.map((x) => x.hash).sort(),
    b.manifest.bundles.map((x) => x.hash).sort(),
    "改了 path 却让包换名了",
  );
  for (const h of a.bundles.keys()) assert.deepEqual(b.bundles.get(h), a.bundles.get(h));
  assert.deepEqual(
    a.manifest.assets.map((x) => x.path),
    base.assets.map((x) => `mem:/a/${x.id}.bin`),
  );
  assert.notDeepEqual(
    b.manifest.assets.map((x) => x.path),
    a.manifest.assets.map((x) => x.path),
    "path 应该只影响清单里的展示字段",
  );
});

// ── 分包 ─────────────────────────────────────────────────────

test("上限大时打成一个包；上限小时分成多个包，且每个资产恰好出现一次", () => {
  const one = run(chainInput(), 1 << 20);
  assert.equal(one.manifest.bundles.length, 1);
  assert.deepEqual(one.manifest.bundles[0]!.assets, ["a", "b", "c"]);

  const many = run(chainInput(), 64);
  assert.ok(many.manifest.bundles.length > 1);
  const seen = many.manifest.bundles.flatMap((b) => b.assets).sort();
  assert.deepEqual(seen, ["a", "b", "c"]);
});

test("单条资产比包上限还大：自成一件，不报错但 size 会超限", () => {
  const out = run({ entries: ["big"], assets: [asset("big", filler(200, "z"))], dependencies: withDeps([["big", []]]) }, 64);
  assert.equal(out.manifest.bundles.length, 1);
  assert.ok(out.manifest.bundles[0]!.size > 64);
  assert.equal(out.manifest.bundles[0]!.assets[0], "big");
});

test("包 size 与包字节长度一致，且等于包内各条 framing 之和", () => {
  const out = run(chainInput(), 1 << 20);
  const b = out.manifest.bundles[0]!;
  const bytes = out.bundles.get(b.hash)!;
  assert.equal(b.size, bytes.length);
  let expect = 0;
  for (const a of out.manifest.assets) expect += 4 + a.id.length + 4 + a.size;
  assert.equal(b.size, expect);
});

// ── manifest ─────────────────────────────────────────────────

test("manifest.hash 覆盖 assets/bundles/entries，且不含自身", () => {
  const out = run(chainInput(), 64);
  const body = {
    schema: PUBLISH_SCHEMA,
    entries: out.manifest.entries,
    assets: out.manifest.assets,
    bundles: out.manifest.bundles,
  };
  const canon = canonicalize(body);
  assert.ok(canon.ok);
  assert.equal(hashText(canon.value), out.manifest.hash);
});

test("空入口是合法的：没有资产、没有包，但 manifest 仍可算 hash", () => {
  const out = run({ entries: [], assets: [asset("a", "A")], dependencies: withDeps([["a", []]]) }, 64);
  assert.deepEqual(out.manifest.assets, []);
  assert.deepEqual(out.manifest.bundles, []);
  assert.equal(out.bundles.size, 0);
  assert.match(out.manifest.hash, /^[0-9a-f]{16}$/);
});

test("renderManifest 稳定：同一产物渲染两次逐字节相同，且以换行结尾", () => {
  const out = run(chainInput(), 64);
  const t1 = renderManifest(out.manifest);
  const t2 = renderManifest(out.manifest);
  assert.equal(t1, t2);
  assert.ok(t1.endsWith("\n"));
  assert.ok(t1.includes(`manifest ${out.manifest.hash}`));
  for (const b of out.manifest.bundles) assert.ok(t1.includes(`bundle ${b.hash} ${String(b.size)}`));
});

test("资产 hash 是内容 hash：同内容不同 id 得到同一个 hash 值", () => {
  const out = run(
    {
      entries: ["p"],
      assets: [asset("p", "same"), asset("q", "same")],
      dependencies: withDeps([
        ["p", ["q"]],
        ["q", []],
      ]),
    },
    1 << 20,
  );
  const byId = new Map(out.manifest.assets.map((a) => [a.id, a.hash]));
  assert.equal(byId.get("p"), byId.get("q"));
});

// ── 错误路径（静默跳过是最坏的处置） ────────────────────────

test("入口不存在 → BUILD_ENTRY_MISSING", () => {
  assert.equal(errOf({ entries: ["nope"], assets: [asset("a", "A")], dependencies: withDeps([["a", []]]) }).code, BUILD_ENTRY_MISSING);
});

test("依赖缺失 → BUILD_DEP_MISSING（不产出缺件的包）", () => {
  const e = errOf({
    entries: ["a"],
    assets: [asset("a", "A")],
    dependencies: withDeps([["a", ["ghost"]]]),
  });
  assert.equal(e.code, BUILD_DEP_MISSING);
  assert.match(e.message, /ghost/);
});

test("重复 id → BUILD_DUPLICATE_ASSET（否则「用哪份字节」取决于数组顺序）", () => {
  assert.equal(
    errOf({ entries: ["a"], assets: [asset("a", "A"), asset("a", "B")], dependencies: withDeps([["a", []]]) }).code,
    BUILD_DUPLICATE_ASSET,
  );
});

test("maxBundleBytes 非法 → BUILD_BAD_CONFIG", () => {
  assert.equal(errOf(chainInput(), 0).code, BUILD_BAD_CONFIG);
  assert.equal(errOf(chainInput(), 1.5).code, BUILD_BAD_CONFIG);
});

test("循环依赖能终止，且环上的资产都在闭包里", () => {
  const out = run({
    entries: ["a"],
    assets: [asset("a", "A"), asset("b", "B")],
    dependencies: withDeps([
      ["a", ["b"]],
      ["b", ["a"]],
    ]),
  });
  assert.deepEqual(out.manifest.assets.map((x) => x.id), ["a", "b"]);
});

test("重复的依赖边不产生重复资产", () => {
  const out = run({
    entries: ["a"],
    assets: [asset("a", "A"), asset("b", "B")],
    dependencies: withDeps([
      ["a", ["b", "b", "b"]],
      ["b", []],
    ]),
  });
  assert.equal(out.manifest.assets.filter((x) => x.id === "b").length, 1);
});

test("十六进制对齐：hash 都是 16 位小写 hex（拼文件名时不能有意外字符）", () => {
  const out = run(chainInput(), 64);
  for (const a of out.manifest.assets) assert.match(a.hash, /^[0-9a-f]{16}$/);
  for (const b of out.manifest.bundles) assert.match(b.hash, /^[0-9a-f]{16}$/);
  assert.match(out.manifest.hash, /^[0-9a-f]{16}$/);
});
