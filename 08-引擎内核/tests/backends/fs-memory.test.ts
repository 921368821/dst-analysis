/**
 * `fs-memory` 后端：通用语义由 `runFsContract` 守（与 fs-node 同一套条目），
 * 这里只补**内存盘独有**的东西（前缀隔离、写入计数、快照与重置）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { MemoryFileSystem, memFsBackend } from "../../src/backends/fs-memory/fs.ts";
import { runFsContract, runReadContract, seedFixtures } from "../contract/fs.contract.ts";

runFsContract("mem", () => new MemoryFileSystem());

// 只读契约（与 fs-http 同一套）：夹具写入后才交出去
runReadContract("mem", async () => {
  const fs = new MemoryFileSystem();
  await seedFixtures(fs);
  return fs;
});

test("[mem] 同一进程里两个前缀互不干扰（编辑器 PIE 与真实工程并存的基础）", async () => {
  const a = new MemoryFileSystem("/pie");
  const b = new MemoryFileSystem("/game");
  await a.writeText("/x.txt", "A");
  await b.writeText("/x.txt", "B");
  const ra = await a.readText("/x.txt");
  const rb = await b.readText("/x.txt");
  assert.equal(ra.ok && ra.value, "A");
  assert.equal(rb.ok && rb.value, "B");
  // 而且跨盘看不到对方的文件
  assert.equal(await a.exists("/only-in-b.txt"), false);
  await b.writeText("/only-in-b.txt", "1");
  assert.equal(await a.exists("/only-in-b.txt"), false);
});

test("[mem] writeCount 只数写入（读多少次都不涨）", async () => {
  const fs = new MemoryFileSystem();
  assert.equal(fs.writeCount, 0);
  await fs.writeText("/a.txt", "1");
  await fs.readText("/a.txt");
  await fs.readBinary("/a.txt");
  await fs.exists("/a.txt");
  await fs.list("/");
  assert.equal(fs.writeCount, 1, "读操作被算成写入了");
  await fs.writeText("/a.txt", "2");
  assert.equal(fs.writeCount, 2);
});

test("[mem] snapshotFiles 是拷贝：改快照不影响盘（存档 before/after 的前提）", async () => {
  const fs = new MemoryFileSystem();
  await fs.writeBinary("/a.bin", new Uint8Array([1, 2, 3]));
  const snap = fs.snapshotFiles();
  const copy = snap.get("/a.bin");
  assert.ok(copy);
  copy[0] = 99;
  const r = await fs.readBinary("/a.bin");
  assert.deepEqual([...(r.ok ? r.value : [])], [1, 2, 3], "快照与盘共享了内存");
});

test("[mem] 写入时拿到的是拷贝：调用方之后改自己的 buffer 不污染盘", async () => {
  const fs = new MemoryFileSystem();
  const buf = new Uint8Array([1, 2, 3]);
  await fs.writeBinary("/b.bin", buf);
  buf[0] = 42;
  const r = await fs.readBinary("/b.bin");
  assert.equal(r.ok && r.value[0], 1);
});

test("[mem] 后端工厂：方案名固定 mem，probe 永远可用（浏览器/Node 都能跑）", async () => {
  assert.equal(memFsBackend.scheme, "mem");
  assert.equal(memFsBackend.probe(), true);
  const made = memFsBackend.create({ prefix: "p" });
  assert.equal(made.ok, true);
  if (!made.ok) return;
  assert.equal(made.value.scheme, "mem");
  await made.value.writeText("/z.txt", "z");
  // 前缀对调用方是**透明**的：读写的路径还是那个路径
  const back = await made.value.readText("/z.txt");
  assert.equal(back.ok && back.value, "z");
  // 但 list 的 path 会带上前缀 —— 前缀是"内部虚拟盘名"，如实记在这里，
  // 免得将来有人以为 list 的 path 可以直接拿去喂另一个实例
  const ents = await made.value.list("/");
  assert.deepEqual(
    ents.ok ? ents.value.map((e) => e.path) : [],
    ["/p/z.txt"],
  );
});
