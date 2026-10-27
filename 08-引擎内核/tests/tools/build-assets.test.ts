/**
 * 构建 CLI 的"落盘层"判据
 *
 * `publish.test.ts` 验的是纯函数的输出；这里验的是**写到磁盘之后**还对不对。
 * 两者必须分开：本轮之前 §11.6 记的缺口正是"判据比的是内存里的字节，
 * 『写到磁盘上逐字节相同』还没验过"。
 *
 * 两条出口判据在这里以**文件名和文件字节**的形式重验一遍：
 *   ① 删掉未被引用的资产 ⇒ 目录里的文件名集合与每个文件的字节都不变；
 *   ② 改一个资产 ⇒ **只有一个** `.pack` 换名。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

interface CliResult {
  readonly status: number;
  readonly stdout: string;
  readonly stderr: string;
}

function cli(args: readonly string[]): CliResult {
  const r = spawnSync(process.execPath, ["--experimental-transform-types", "tools/build-assets.mjs", ...args], {
    cwd: ROOT,
    encoding: "utf8",
  });
  return { status: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function tmp(tag: string): string {
  return mkdtempSync(join(tmpdir(), `wb-build-${tag}-`));
}

function put(dir: string, files: Record<string, string>): void {
  for (const [name, text] of Object.entries(files)) {
    const p = join(dir, name);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
  }
}

/** 目录快照：相对路径 → 内容 sha256。**文件名也是产物的一部分**（包名 = 内容 hash）。 */
function snapshot(dir: string, base = dir, acc: Record<string, string> = {}): Record<string, string> {
  for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const p = join(dir, e.name);
    if (e.isDirectory()) snapshot(p, base, acc);
    else acc[relative(base, p).split("\\").join("/")] = createHash("sha256").update(readFileSync(p)).digest("hex");
  }
  return acc;
}

function packs(dir: string): string[] {
  return readdirSync(dir).filter((f) => f.endsWith(".pack")).sort();
}

function buildJson(res: CliResult): { manifest: string; assets: number; bundles: number; out: string } {
  const line = res.stdout.trim().split("\n").filter((l) => l.startsWith("{")).pop();
  assert.ok(line !== undefined, `stdout 里没有 JSON 摘要：${res.stdout}${res.stderr}`);
  return JSON.parse(line) as { manifest: string; assets: number; bundles: number; out: string };
}

test("真跑一次：web/assets 打成包，写出 manifest.txt 与 .pack", () => {
  const out = tmp("real-out");
  try {
    const res = cli(["--src", "web/assets", "--out", out]);
    assert.equal(res.status, 0, res.stderr);
    const j = buildJson(res);
    assert.ok(j.assets >= 6, `只打进去 ${String(j.assets)} 个资产`);
    // ★ 包数**不再是 1**，而且不该写死：打包器按 64KB 一层切，而资产里现在有
    //   1MB 级的字体（`ui-font-cjk.fnt` 710KB / `.png` 344KB，批101 加的）——
    //   单个资产本身超过 64KB 时它自成一包。写死 1 会让"资产变大"变成一次假红，
    //   而这条判据真正要守的是"包的个数与产物文件个数对得上、manifest 指得到它们"。
    assert.ok(j.bundles >= 1, `一个包都没打出来`);
    assert.match(j.manifest, /^[0-9a-f]{16}$/);
    const files = readdirSync(out).sort();
    assert.ok(files.includes("manifest.txt"));
    assert.equal(packs(out).length, j.bundles, "磁盘上的 .pack 个数与 manifest 声明的不一致");
    assert.ok(readFileSync(join(out, "manifest.txt"), "utf8").includes(`manifest ${j.manifest}`));
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test("★ 可复现：同输入构建到两个空目录，文件名与字节完全相同", () => {
  const out1 = tmp("rep1");
  const out2 = tmp("rep2");
  try {
    assert.equal(cli(["--src", "web/assets", "--out", out1]).status, 0);
    assert.equal(cli(["--src", "web/assets", "--out", out2]).status, 0);
    assert.deepEqual(snapshot(out1), snapshot(out2));
  } finally {
    rmSync(out1, { recursive: true, force: true });
    rmSync(out2, { recursive: true, force: true });
  }
});

test("★ 出口判据①（磁盘层）：未被引用的资产删掉后，目录里一个字都不该变", () => {
  const src1 = tmp("d1");
  const src2 = tmp("d2");
  const o1 = tmp("o1");
  const o2 = tmp("o2");
  try {
    put(src1, { "a.png": "AAAA", "b.png": "BBBB", "junk.png": "没人引用我" });
    put(src2, { "a.png": "AAAA", "b.png": "BBBB" });
    assert.equal(cli(["--src", src1, "--out", o1, "--entry", "a.png", "--entry", "b.png"]).status, 0);
    assert.equal(cli(["--src", src2, "--out", o2]).status, 0);
    assert.deepEqual(snapshot(o1), snapshot(o2), "未被引用的资产影响了磁盘上的产物");
    // 反面对照：让它被引用，产物就必须变（否则上面那条无从证明）
    const o3 = tmp("o3");
    try {
      assert.equal(cli(["--src", src1, "--out", o3, "--entry", "a.png"]).status, 0);
      assert.notDeepEqual(snapshot(o3), snapshot(o1));
    } finally {
      rmSync(o3, { recursive: true, force: true });
    }
  } finally {
    for (const d of [src1, src2, o1, o2]) rmSync(d, { recursive: true, force: true });
  }
});

test("★ 出口判据②（磁盘层）：改一个资产只让一个 .pack 换名", () => {
  const src = tmp("c1");
  const out1 = tmp("c1o1");
  const out2 = tmp("c1o2");
  try {
    put(src, { "a.bin": "a".repeat(40), "b.bin": "b".repeat(40), "c.bin": "c".repeat(40) });
    assert.equal(cli(["--src", src, "--out", out1, "--max", "64"]).status, 0);
    const p1 = packs(out1);
    assert.ok(p1.length >= 3, `只打了 ${String(p1.length)} 个包，这条判据验不动`);

    put(src, { "b.bin": "B".repeat(40) });
    assert.equal(cli(["--src", src, "--out", out2, "--max", "64"]).status, 0);
    const p2 = packs(out2);

    const common = p1.filter((f) => p2.includes(f));
    assert.equal(common.length, p1.length - 1, "改一个资产却牵动了多个包（或一个都没牵动）");
    for (const f of common) {
      assert.deepEqual(readFileSync(join(out2, f)), readFileSync(join(out1, f)));
    }
  } finally {
    for (const d of [src, out1, out2]) rmSync(d, { recursive: true, force: true });
  }
});

test("重复构建到同一个目录不留旧包（清目录是产物正确性的一部分）", () => {
  const src = tmp("s1");
  const out = tmp("s1o");
  try {
    put(src, { "a.bin": "a".repeat(40), "b.bin": "b".repeat(40), "c.bin": "c".repeat(40) });
    assert.equal(cli(["--src", src, "--out", out, "--max", "64"]).status, 0);
    const first = snapshot(out);
    // 删掉一个资产后重建到同一目录
    rmSync(join(src, "c.bin"));
    assert.equal(cli(["--src", src, "--out", out, "--max", "64"]).status, 0);
    const second = snapshot(out);

    const fresh = tmp("s1f");
    try {
      assert.equal(cli(["--src", src, "--out", fresh, "--max", "64"]).status, 0);
      assert.deepEqual(second, snapshot(fresh), "旧包没被清掉：目录里残留了上次的产物");
      assert.notDeepEqual(first, second);
    } finally {
      rmSync(fresh, { recursive: true, force: true });
    }
  } finally {
    for (const d of [src, out]) rmSync(d, { recursive: true, force: true });
  }
});

test(".meta 不进产物（它是导入期输入，不是可发布内容）", () => {
  const src = tmp("m1");
  const out = tmp("m1o");
  try {
    put(src, { "a.png": "AAAA", "a.png.meta": JSON.stringify({ dependencies: [] }) });
    const res = cli(["--src", src, "--out", out]);
    assert.equal(res.status, 0, res.stderr);
    const j = buildJson(res);
    assert.equal(j.assets, 1, ".meta 被打进了产物");
    const manifest = readFileSync(join(out, "manifest.txt"), "utf8");
    assert.equal(manifest.includes(".meta"), false);
  } finally {
    for (const d of [src, out]) rmSync(d, { recursive: true, force: true });
  }
});

test(".meta 声明的依赖缺失 → 退出码 1 且报 BUILD.DEP_MISSING", () => {
  const src = tmp("m2");
  const out = tmp("m2o");
  try {
    put(src, { "a.png": "AAAA", "a.png.meta": JSON.stringify({ dependencies: ["ghost.png"] }) });
    const res = cli(["--src", src, "--out", out]);
    assert.equal(res.status, 1);
    assert.match(res.stderr, /BUILD\.DEP_MISSING/);
  } finally {
    for (const d of [src, out]) rmSync(d, { recursive: true, force: true });
  }
});

test(".meta 解析失败 → 退出码 1（不当成「没依赖」混过去）", () => {
  const src = tmp("m3");
  const out = tmp("m3o");
  try {
    put(src, { "a.png": "AAAA", "a.png.meta": "{ 这不是 JSON" });
    const res = cli(["--src", src, "--out", out]);
    assert.equal(res.status, 1);
    assert.match(res.stderr, /meta 解析失败/);
  } finally {
    for (const d of [src, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("参数缺失/非法 → 退出码 2（用法错误与构建失败分开）", () => {
  assert.equal(cli([]).status, 2);
  assert.equal(cli(["--src", "web/assets"]).status, 2);
  const out = tmp("u1");
  try {
    assert.equal(cli(["--src", "web/assets", "--out", out, "--max", "0"]).status, 2);
    assert.equal(cli(["--src", "web/assets", "--out", out, "--nope"]).status, 2);
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test("源目录为空 → 退出码 2（不产出空产物）", () => {
  const src = tmp("e1");
  const out = tmp("e1o");
  try {
    const res = cli(["--src", src, "--out", out]);
    assert.equal(res.status, 2);
    assert.match(res.stderr, /没有可发布的文件/);
  } finally {
    for (const d of [src, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("manifest.txt 的资产行数与 stdout 的 assets 一致（两个出口不能各说各话）", () => {
  const out = tmp("mx");
  try {
    const res = cli(["--src", "web/assets", "--out", out]);
    assert.equal(res.status, 0, res.stderr);
    const j = buildJson(res);
    const manifest = readFileSync(join(out, "manifest.txt"), "utf8");
    const assetLines = manifest.split("\n").filter((l) => l.startsWith("asset "));
    assert.equal(assetLines.length, j.assets);
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
