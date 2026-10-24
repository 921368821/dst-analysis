/**
 * `fs-storage` 后端：与 mem/node 同一套契约 + localStorage 特有的坑。
 *
 * ★ 为什么必须在 Node 里用内存 storage 跑契约：
 *   真 `localStorage` 只在浏览器里，而"浏览器存档"恰恰是最难调试的地方
 *   （没有文件可看、没有错误码、刷新一次就没了）。把后端拉到 Node 里跑，
 *   它才有和 mem/node 一样的判据；浏览器那边只剩"Storage 接口通不通"这一件事，
 *   而那件事由浏览器端自检的"存档 → 读档往返"覆盖。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  StorageFileSystem,
  fromBase64,
  storageFsBackend,
  toBase64,
  type StorageLike,
} from "../../src/backends/fs-storage/fs.ts";
import { runFsContract, runReadContract, seedFixtures } from "../contract/fs.contract.ts";

/** 内存版 localStorage（键序按插入序，与浏览器一致：`length` + `key(i)` 遍历）。 */
class MemoryStorage implements StorageLike {
  private readonly map = new Map<string, string>();
  /** 设成 true 后所有写入都抛（模拟配额满）。 */
  failWrites = false;

  get length(): number {
    return this.map.size;
  }
  key(index: number): string | null {
    const keys = [...this.map.keys()];
    return index >= 0 && index < keys.length ? keys[index]! : null;
  }
  getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    if (this.failWrites) throw new Error("QuotaExceededError（模拟 storage 满）");
    this.map.set(key, value);
  }
  removeItem(key: string): void {
    this.map.delete(key);
  }
}

const fresh = (): StorageFileSystem => new StorageFileSystem({ storage: new MemoryStorage() });

runFsContract("storage", () => fresh());
runReadContract("storage", async () => {
  const fs = fresh();
  await seedFixtures(fs);
  return fs;
});

// ------------------------------------------------------------------ localStorage 特有

test("[storage] base64 往返：0..255 全字节保真（两套实现都对）", () => {
  // 自己实现的 base64 是最容易"看起来对"的地方：padding、末尾 1/2 字节都要覆盖
  for (let len = 0; len <= 256; len++) {
    const bytes = Uint8Array.from({ length: len }, (_, i) => i % 256);
    const back = fromBase64(toBase64(bytes));
    assert.equal(back.byteLength, len, `长度 ${len} 往返后字节数变了`);
    assert.deepEqual([...back], [...bytes], `长度 ${len} 往返后内容变了`);
  }
  // 对照标准实现（Node 有 Buffer）：只用来验我们的编码，不是运行时依赖
  const sample = Uint8Array.from([0, 1, 254, 255, 42]);
  assert.equal(toBase64(sample), Buffer.from(sample).toString("base64"));
});

test("[storage] 前缀隔离：两份工程共用一个 storage 互不干扰", async () => {
  const storage = new MemoryStorage();
  const a = new StorageFileSystem({ storage, prefix: "gameA." });
  const b = new StorageFileSystem({ storage, prefix: "gameB." });
  await a.writeText("/slot.json", "A 的存档");
  await b.writeText("/slot.json", "B 的存档");
  const ra = await a.readText("/slot.json");
  const rb = await b.readText("/slot.json");
  assert.equal(ra.ok && ra.value, "A 的存档");
  assert.equal(rb.ok && rb.value, "B 的存档");
  // 键名真的带前缀（否则"隔离"只是两个对象各存一份内存引用）
  const keys = Array.from({ length: storage.length }, (_, i) => storage.key(i));
  assert.ok(keys.some((k) => k !== null && k.startsWith("gameA.f:")), `键名没带前缀：${keys.join(",")}`);
});

test("[storage] storage 满：报 FS.NO_SPACE（不是把异常冒泡给调用方）", async () => {
  const storage = new MemoryStorage();
  const fs = new StorageFileSystem({ storage });
  await fs.writeText("/a.txt", "1"); // 先确认正常情况下可写
  storage.failWrites = true;
  const r = await fs.writeText("/b.txt", "2");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "FS.NO_SPACE");
});

test("[storage] 记录损坏：报 FS.IO（不抛、也不当成空文件）", async () => {
  const storage = new MemoryStorage();
  const fs = new StorageFileSystem({ storage });
  await fs.writeText("/a.txt", "hi");
  storage.setItem("f:/a.txt", "{这不是合法记录");
  const r = await fs.readBinary("/a.txt");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "FS.IO");
  // stat 也要报同一个错，而不是给个 size 0
  const st = await fs.stat("/a.txt");
  assert.equal(st.ok, false);
});

test("[storage] 目录索引损坏：自愈（从文件路径重建），不把用户卡死", async () => {
  const storage = new MemoryStorage();
  const fs = new StorageFileSystem({ storage });
  await fs.writeText("/deep/a/b.txt", "x");
  // 索引被写坏（模拟别处误写/旧版本迁移）
  storage.setItem("d", "不是 JSON");
  const ents = await fs.list("/deep/a");
  assert.equal(ents.ok, true, ents.ok ? "" : `索引坏了就列不出目录：${ents.error.code}`);
  if (!ents.ok) return;
  assert.deepEqual(ents.value.map((e) => e.name), ["b.txt"], "重建后应该看得见文件");
});

test("[storage] 先建目录再往同名路径写文件：FS.IS_DIR（不许两者同名）", async () => {
  const fs = fresh();
  assert.equal((await fs.ensureDir("/x")).ok, true);
  const r = await fs.writeText("/x", "1");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "FS.IS_DIR");
});

test("[storage] 工厂：缺 storage 报 BAD_OPTIONS；有 storage 时能建", () => {
  const bad = storageFsBackend.create({});
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.error.code, "FS.BAD_OPTIONS");
  const made = storageFsBackend.create({ storage: new MemoryStorage() });
  assert.equal(made.ok, true);
  if (made.ok) assert.equal(made.value.scheme, "storage");
});
