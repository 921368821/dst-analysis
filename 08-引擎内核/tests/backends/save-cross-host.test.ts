/**
 * 跨宿主存档：同一份存档经过**三个不同的持久化后端**之后，字节必须完全一样。
 *
 * ★ 这个判据补的是什么：
 *   单个后端的契约证明"它自己能存能取"，但证明不了**换宿主之后还是同一份存档**。
 *   而"在浏览器存的档能不能在桌面端打开"正是玩家会做的事（也是我们自己调试时最常做的）。
 *   三个后端里每一个都可能悄悄改字节：
 *     · `mem` 忘了拷贝（交出内部引用，被后续写入污染）；
 *     · `node` 的编码/换行（Windows 上 `\r\n` 是经典事故）；
 *     · `storage` 的 base64（手写编码，高位掩码写错一位就会让中文全变 —— M72 就是这个）。
 *
 * ★ 为什么用 sha256 而不是 JSON 深比较：
 *   深比较能告诉你"哪里不一样"，但它会**规范化**掉"字节层的差异"（键序、空白、换行）。
 *   存档的承诺是"逐字节相同"，那就必须按字节比。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Component, ComponentRegistry, FieldType } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { NodeFileSystem } from "../../src/backends/fs-node/fs.ts";
import { StorageFileSystem, type StorageLike } from "../../src/backends/fs-storage/fs.ts";
import type { IFileSystem } from "../../src/platform/fs/fs.ts";

class Barrel extends Component {
  hp = 7.5;
  readonly schema = { type: "test.barrel", fields: { hp: FieldType.Float } };
}

/** 带**中文名**、浮点、父子关系、组件数据的场景：能同时压住编码、量化与装配顺序。 */
function buildScene(): Scene {
  const reg = new ComponentRegistry();
  reg.register({ type: "test.barrel", fields: { hp: FieldType.Float } }, () => new Barrel());
  const scene = new Scene("跨宿主存档", reg);
  const hero = scene.spawnImmediate("主角");
  hero.setLocalPosition(1.25, -2.5);
  hero.setLocalRotation(0.5);
  const child = scene.spawnImmediate("队友（带括号）", hero.id);
  child.setLocalScale(2, 3);
  child.zIndex = 4;
  child.layer = 2;
  scene.attach(hero.id, () => new Barrel());
  scene.attach(child.id, () => new Barrel());
  scene.flush();
  return scene;
}

class MemoryStorage implements StorageLike {
  private readonly map = new Map<string, string>();
  get length(): number {
    return this.map.size;
  }
  key(i: number): string | null {
    const keys = [...this.map.keys()];
    return i >= 0 && i < keys.length ? keys[i]! : null;
  }
  getItem(k: string): string | null {
    return this.map.get(k) ?? null;
  }
  setItem(k: string, v: string): void {
    this.map.set(k, v);
  }
  removeItem(k: string): void {
    this.map.delete(k);
  }
}

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

interface Host {
  readonly name: string;
  readonly fs: IFileSystem;
  readonly path: string;
  cleanup(): void;
}

function hosts(): readonly Host[] {
  // ★ 每个宿主**各自**一个临时根：共用一个是第一次写这个判据时的 bug ——
  //   `finally` 里删掉共享根之后，`node` 宿主的根就没了（realpath 失败 ⇒ PATH_ESCAPE）。
  const memRoot = mkdtempSync(join(tmpdir(), "cross-mem-"));
  const nodeRoot = mkdtempSync(join(tmpdir(), "cross-node-"));
  return [
    {
      name: "mem",
      fs: new MemoryFileSystem(),
      path: "/saves/slot1.json",
      cleanup: () => rmSync(memRoot, { recursive: true, force: true }),
    },
    {
      name: "node",
      fs: new NodeFileSystem(nodeRoot),
      path: "/saves/slot1.json",
      cleanup: () => rmSync(nodeRoot, { recursive: true, force: true }),
    },
    {
      name: "storage",
      fs: new StorageFileSystem({ storage: new MemoryStorage(), prefix: "t." }),
      path: "/saves/slot1.json",
      cleanup: () => {},
    },
  ];
}

test("[跨宿主] 同一份存档经三个后端之后，字节与 sha256 完全一致", async () => {
  const json = sceneToJson(saveScene(buildScene()));
  const wantSha = sha256(new TextEncoder().encode(json));
  const seen: string[] = [];
  for (const h of hosts()) {
    try {
      const w = await h.fs.writeText(h.path, json);
      assert.equal(w.ok, true, `${h.name} 写失败：${w.ok ? "" : w.error.code}`);
      const r = await h.fs.readText(h.path);
      assert.equal(r.ok, true, `${h.name} 读失败：${r.ok ? "" : r.error.code}`);
      if (!r.ok) continue;
      assert.equal(r.value, json, `${h.name} 读回来的文本被改过了`);
      assert.equal(sha256(new TextEncoder().encode(r.value)), wantSha, `${h.name} 的字节与源不同`);
      // 读回来还能过版本闸门（否则"字节一样"只说明存了个文本）
      const snap = sceneFromJson(r.value);
      assert.equal(snap.ok, true, `${h.name} 的存档过不了版本闸门：${snap.ok ? "" : snap.error.code}`);
      seen.push(`${h.name}:${wantSha.slice(0, 8)}`);
    } finally {
      h.cleanup();
    }
  }
  assert.equal(seen.length, 3, `应该有三个后端都通过：${seen.join(" ")}`);
  // 全部同一个 sha —— 这条断言在"某个后端改了字节"时会先被上面的逐字节比较抓住，
  // 但保留它：它直接表达了这个判据的承诺
  assert.equal(new Set(seen.map((s) => s.split(":")[1])).size, 1, `三个后端的 sha 不一致：${seen.join(" ")}`);
});

test("[跨宿主] 同一场景连存两次：sha 不变（确定性序列化，与宿主无关）", async () => {
  const scene = buildScene();
  const a = sceneToJson(saveScene(scene));
  const b = sceneToJson(saveScene(scene));
  assert.equal(sha256(new TextEncoder().encode(a)), sha256(new TextEncoder().encode(b)));
  // 存到 storage 再读回来，再存一次 —— 仍然一样（base64 往返不引入差异）
  const fs = new StorageFileSystem({ storage: new MemoryStorage() });
  await fs.writeText("/s.json", a);
  const back = await fs.readText("/s.json");
  assert.equal(back.ok, true);
  if (!back.ok) return;
  const snap = sceneFromJson(back.value);
  assert.equal(snap.ok, true);
  if (!snap.ok) return;
  assert.equal(sceneToJson(snap.value), a);
});
