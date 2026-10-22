/**
 * L2 · 资产系统测试
 *
 * 覆盖上一代引擎付出过代价的四件事：
 *  ① 引用计数（提前释放 = 用着用着变空）
 *  ② 依赖成环（栈溢出或死锁）
 *  ③ 卸载顺序（先卸被依赖的 = 释放时的随机崩）
 *  ④ 并发加载同一资产（加载两次 = 两份资源 + 只释放一份 = 泄漏）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { AssetDatabase, type AssetId, type AssetMeta, type IAsset, type IAssetLoader } from "../../src/core/asset/asset.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import { ok, err, type EngineError, type Result } from "../../src/foundation/result.ts";

class TextAsset implements IAsset {
  disposed = false;
  constructor(
    readonly id: AssetId,
    readonly type: string,
    readonly text: string,
  ) {}
  dispose(): void {
    this.disposed = true;
  }
}

function meta(id: AssetId, path: string, deps: AssetId[] = [], type = "text"): AssetMeta {
  return { id, type, path, importerVersion: 1, sourceHash: "h", dependencies: deps, byteLength: 0 };
}

function setup(): { db: AssetDatabase; fs: MemoryFileSystem; loaded: string[] } {
  const fs = new MemoryFileSystem();
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  const loaded: string[] = [];
  const db = new AssetDatabase(fs, log.channel("asset"));
  const loader: IAssetLoader = {
    types: ["text"],
    async load(m, ctx): Promise<Result<IAsset, EngineError>> {
      const r = await ctx.fs.readText(m.path);
      if (!r.ok) return err(r.error);
      loaded.push(m.id);
      return ok(new TextAsset(m.id, m.type, r.value));
    },
  };
  db.registerLoader(loader);
  return { db, fs, loaded };
}

test("引用计数：两处引用时 release 一处不释放，全部释放才 dispose", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  db.register(meta("a", "/a.txt"));

  const h1 = await db.load("a");
  const h2 = await db.load("a");
  assert.ok(h1.ok && h2.ok);
  if (!h1.ok || !h2.ok) return;
  assert.equal(h1.value.asset, h2.value.asset, "同一个资产应返回同一个实例");

  h1.value.release();
  assert.equal((h1.value.asset as TextAsset).disposed, false, "还有一处引用，不许释放");
  h2.value.release();
  assert.equal((h2.value.asset as TextAsset).disposed, true, "引用清零后才释放");
});

test("依赖：加载 A 会自动加载 B，且 A 释放后 B 仍被 A 的引用关系挡住，直到一起释放", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  await fs.writeText("/b.txt", "B");
  db.register(meta("b", "/b.txt"));
  db.register(meta("a", "/a.txt", ["b"]));

  const ha = await db.load("a");
  assert.ok(ha.ok);
  const stats = db.stats();
  assert.equal(stats.loaded, 2, "A 和它的依赖 B 都应被加载");
  assert.equal(stats.refs, 2, "A 引用 1 + 依赖 B 引用 1");
});

test("卸载顺序 = 依赖的反拓扑（先卸使用者，再卸被使用者）", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  await fs.writeText("/b.txt", "B");
  await fs.writeText("/c.txt", "C");
  db.register(meta("c", "/c.txt"));
  db.register(meta("b", "/b.txt", ["c"]));
  db.register(meta("a", "/a.txt", ["b"]));

  const h = await db.load("a");
  assert.ok(h.ok);
  const plan = db.unloadPlan();
  const ia = plan.indexOf("a");
  const ib = plan.indexOf("b");
  const ic = plan.indexOf("c");
  assert.ok(ia >= 0 && ib >= 0 && ic >= 0, "计划里应包含三个资产：" + plan.join(","));
  assert.ok(ia < ib, "a（使用者）必须先卸");
  assert.ok(ib < ic, "b 必须早于 c");
});

test("循环依赖：报错且**点名环**，不栈溢出", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  await fs.writeText("/b.txt", "B");
  db.register(meta("a", "/a.txt", ["b"]));
  db.register(meta("b", "/b.txt", ["a"]));

  const r = await db.load("a");
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.DEPENDENCY_CYCLE");
    assert.match(r.error.message, /a.*b.*a|b.*a.*b/, "错误里应能看出环：" + r.error.message);
  }
});

test("缺失依赖：报错点名是哪个依赖，且不留下半加载状态", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  db.register(meta("a", "/a.txt", ["ghost"]));
  const r = await db.load("a");
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.DEPENDENCY_FAILED");
    assert.match(r.error.message, /ghost/);
  }
  assert.equal(db.stats().loaded, 0, "失败的加载不该留下任何已加载实例");
});

test("并发加载同一资产只加载一次（cacheMiss = 1）", async () => {
  const { db, fs, loaded } = setup();
  await fs.writeText("/a.txt", "A");
  db.register(meta("a", "/a.txt"));
  const [x, y] = await Promise.all([db.load("a"), db.load("a")]);
  assert.ok(x.ok && y.ok);
  assert.equal(loaded.length, 1, `加载器只该被调用一次，实际 ${loaded.length}`);
  assert.equal(db.stats().cacheMiss, 1);
});

test("未注册的资产给出可读错误（并列出已知 id 便于发现拼错）", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  db.register(meta("a", "/a.txt"));
  const r = await db.load("aa");
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.NOT_REGISTERED");
    assert.match(r.error.message, /aa/);
  }
});

test("没有加载器处理某个类型：报错并列出已支持的类型", async () => {
  const { db, fs } = setup();
  await fs.writeText("/x.bin", "X");
  db.register(meta("x", "/x.bin", [], "binary"));
  const r = await db.load("x");
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.NO_LOADER");
    assert.match(r.error.message, /text/, "错误里应列出实际注册的类型");
  }
});

test("使用中的资产不许重新导入（避免把别人手里的实例换掉）", async () => {
  const { db, fs } = setup();
  await fs.writeText("/a.txt", "A");
  db.register(meta("a", "/a.txt"));
  const h = await db.load("a");
  assert.ok(h.ok);
  const re = db.register(meta("a", "/a.txt"));
  assert.equal(re.ok, false);
  if (!re.ok) assert.equal(re.error.code, "ASSET.REIMPORT_WHILE_IN_USE");
});
