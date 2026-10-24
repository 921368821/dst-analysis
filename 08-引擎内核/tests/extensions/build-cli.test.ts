/**
 * 构建发布 CLI（`tools/build.ts`）的判据 —— 用**子进程真跑**，不 mock
 *
 * ★ 为什么必须真跑：这两条出口判据说的都是"产物目录里的字节"。
 *   在进程内调 `buildPublish` 只能证明"函数返回的对象一样"，
 *   证明不了"落盘的文件一样"（写盘顺序、覆盖、增量跳过都在这条缝里）。
 *
 * ★ 语料是**临时目录里的小资产**，不是仓库里的 `web/assets`：
 *   判据要验证"删掉未被引用的资产"，这必须能删文件。
 *   删仓库文件的判据是危险的（跑一半失败就留下残缺的工作区）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const TOOL = join(ROOT, "tools", "build.ts");
const ASSETS = join(ROOT, "web", "assets");

interface Built {
  readonly code: number;
  readonly stdout: string;
  readonly stderr: string;
  readonly manifestHash: string | undefined;
}

function runBuild(cwd: string, extra: string[] = []): Built {
  const r = spawnSync(process.execPath, ["--experimental-transform-types", TOOL, "--config", join(cwd, "config.json"), ...extra], {
    cwd,
    encoding: "utf8",
    // 关掉 Node 的实验特性警告，免得它混进 assert 的 stderr 匹配里
    env: { ...process.env, NODE_NO_WARNINGS: "1" },
  });
  const stdout = r.stdout ?? "";
  const m = /^manifest (\w+)$/m.exec(stdout);
  return {
    code: r.status ?? -1,
    stdout,
    stderr: r.stderr ?? "",
    manifestHash: m === null ? undefined : m[1]!,
  };
}

/**
 * 造一个最小工程：图集（入口）依赖两张贴图，另有一张**没人引用**的贴图。
 * 依赖边只有图集能给（`textures` 数组），所以语料里必须有它 ——
 * 只有平铺的 png 时"闭包"和"目录全收"是同一件事，判据会验不出东西。
 */
function makeFixture(): { dir: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "engine-build-"));
  const assets = join(dir, "assets");
  mkdirSync(assets, { recursive: true });
  copyFileSync(join(ASSETS, "berry.png"), join(assets, "a.png"));
  copyFileSync(join(ASSETS, "player.png"), join(assets, "b.png"));
  copyFileSync(join(ASSETS, "rock.png"), join(assets, "unused.png"));
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
    JSON.stringify({
      assetRoot: "/assets",
      outDir: "/out",
      // 512B 的包上限：小资产也能被打成多个包，"只重打一个包"才有东西可验
      maxBundleBytes: 512,
      entries: ["/assets/main.atlas.json"],
    }),
    "utf8",
  );
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function bundleNames(outDir: string): string[] {
  return readdirSync(join(outDir, "bundles")).sort();
}

test("[构建] 产物只含**入口闭包**：没人引用的资产进不来", () => {
  const f = makeFixture();
  try {
    const r = runBuild(f.dir);
    assert.equal(r.code, 0, `构建失败：${r.stderr}`);
    const manifest = readFileSync(join(f.dir, "out", "manifest.txt"), "utf8");
    // 三个资产：图集 + 两张贴图。unused.png 不该出现。
    const assetLines = manifest.split("\n").filter((l) => l.startsWith("asset "));
    assert.equal(assetLines.length, 3, `产物里有 ${String(assetLines.length)} 个资产：\n${manifest}`);
    assert.doesNotMatch(manifest, /unused\.png/, "没人引用的资产被发布了 —— 闭包没生效");
    // 导入缓存不该进产物
    assert.doesNotMatch(manifest, /library\/imported/, "导入缓存被当成资产发布了");
  } finally {
    f.cleanup();
  }
});

test("[构建] 删掉一个**未被引用**的资产：产物逐字节不变（出口判据 ①）", () => {
  const f = makeFixture();
  try {
    const first = runBuild(f.dir);
    assert.equal(first.code, 0, first.stderr);
    const before = readFileSync(join(f.dir, "out", "manifest.txt"));

    rmSync(join(f.dir, "assets", "unused.png"));
    const second = runBuild(f.dir);
    assert.equal(second.code, 0, second.stderr);
    const after = readFileSync(join(f.dir, "out", "manifest.txt"));

    assert.deepEqual([...after], [...before], "删掉未引用的资产后产物变了 —— 说明产物不是入口闭包");
    assert.equal(second.manifestHash, first.manifestHash);
    // 第二次应当**一个字节都不写**（内容寻址 + 先比字节）
    assert.match(second.stdout, /^written 0 skipped \d+$/m, `第二次重建还在写盘：${second.stdout}`);
  } finally {
    f.cleanup();
  }
});

test("[构建] 改一个资产：只重打**一个**包（出口判据 ②）", () => {
  const f = makeFixture();
  try {
    assert.equal(runBuild(f.dir).code, 0);
    const before = bundleNames(join(f.dir, "out"));

    // 改 a.png：往尾部追加一个字节（贴图导入器只看头，不会因此失败）
    const p = join(f.dir, "assets", "a.png");
    writeFileSync(p, Buffer.concat([readFileSync(p), Buffer.from([0x00])]));

    const r = runBuild(f.dir);
    assert.equal(r.code, 0, r.stderr);
    const after = bundleNames(join(f.dir, "out"));

    const added = after.filter((n) => !before.includes(n));
    const removed = before.filter((n) => !after.includes(n));
    assert.equal(added.length, 1, `新增了 ${String(added.length)} 个包（应该只有 1 个）：${added.join(",")}`);
    assert.equal(removed.length, 1, `失效了 ${String(removed.length)} 个包（应该只有 1 个）：${removed.join(",")}`);
    // 其余包名必须原样还在（CDN 缓存才不会整片失效）
    const kept = before.filter((n) => after.includes(n));
    assert.equal(kept.length, before.length - 1);
  } finally {
    f.cleanup();
  }
});

test("[构建] 删掉一个包文件后重建：只把它补回来（不会全量重写）", () => {
  const f = makeFixture();
  try {
    assert.equal(runBuild(f.dir).code, 0);
    const names = bundleNames(join(f.dir, "out"));
    assert.ok(names.length >= 2, "语料至少该打出两个包");
    rmSync(join(f.dir, "out", "bundles", names[0]!));

    const r = runBuild(f.dir);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /^written 1 skipped \d+$/m, `重建应只补 1 个文件：${r.stdout}`);
    assert.deepEqual(bundleNames(join(f.dir, "out")), names, "补回来的包名应该与原来一样（内容寻址）");
  } finally {
    f.cleanup();
  }
});

test("[构建] 入口写错：退出码 1 并点名（不产出缺件的包）", () => {
  const f = makeFixture();
  try {
    writeFileSync(
      join(f.dir, "config.json"),
      JSON.stringify({ assetRoot: "/assets", outDir: "/out", entries: ["/assets/nope.png"] }),
      "utf8",
    );
    const r = runBuild(f.dir);
    assert.equal(r.code, 1, `应该失败：${r.stdout}${r.stderr}`);
    assert.match(r.stderr, /nope\.png/);
    assert.equal(existsSync(join(f.dir, "out", "manifest.txt")), false, "失败时不该留下 manifest");
  } finally {
    f.cleanup();
  }
});

test("[构建] 空入口 / 资产根不存在：退出码 2（配置问题不是构建问题）", () => {
  const f = makeFixture();
  try {
    writeFileSync(join(f.dir, "config.json"), JSON.stringify({ assetRoot: "/assets", outDir: "/out", entries: [] }), "utf8");
    assert.equal(runBuild(f.dir).code, 2);

    writeFileSync(
      join(f.dir, "config.json"),
      JSON.stringify({ assetRoot: "/missing", outDir: "/out", entries: ["/assets/a.png"] }),
      "utf8",
    );
    const r = runBuild(f.dir);
    assert.equal(r.code, 2, `资产根不存在应该报配置错误：${r.stderr}`);
    assert.match(r.stderr, /资产根不存在/);
  } finally {
    f.cleanup();
  }
});
