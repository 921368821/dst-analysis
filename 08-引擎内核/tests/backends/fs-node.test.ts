/**
 * `fs-node` 后端：通用语义由 `runFsContract` 守（与 fs-memory 同一套条目），
 * 这里补**真实盘独有**的东西：
 *   · 字节真的落在盘上（用 `node:fs` 直接读回来比对，不经过我们的实现）
 *   · **进程重启后**还能读回同一份存档（子进程读档并再存，比 sha256）
 *   · 沙箱：符号链接把路径引到 root 之外时必须报 FS.PATH_ESCAPE
 *   · 原子写不留临时文件
 *   · root 带中文/空格也能用（Windows 上真实项目路径常常如此）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { NodeFileSystem, nodeFsBackend } from "../../src/backends/fs-node/fs.ts";
import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { sceneToJson, saveScene } from "../../src/core/scene/scene-io.ts";
import { runFsContract, runReadContract, seedFixtures } from "../contract/fs.contract.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHILD = join(HERE, "..", "tools", "save-readback-child.mjs");
const SCENE_IO_URL = pathToFileURL(join(HERE, "..", "..", "src", "core", "scene", "scene-io.ts")).href;

function tempRoot(tag: string): string {
  return mkdtempSync(join(tmpdir(), `fsnode-${tag}-`));
}

runFsContract(
  "node",
  () => new NodeFileSystem(tempRoot("case")),
  async (fs) => {
    rmSync((fs as NodeFileSystem).root, { recursive: true, force: true });
  },
);

// 只读契约（与 fs-http 同一套）：夹具真写真盘
runReadContract(
  "node",
  async () => {
    const fs = new NodeFileSystem(tempRoot("read"));
    await seedFixtures(fs);
    return fs;
  },
  async (fs) => {
    rmSync((fs as NodeFileSystem).root, { recursive: true, force: true });
  },
);

test("[node] 字节真的落在盘上：绕过我们的实现，用 node:fs 直接读回", async () => {
  const root = tempRoot("disk");
  try {
    const fs = new NodeFileSystem(root);
    const data = new Uint8Array([0, 1, 2, 250, 251, 255]);
    const w = await fs.writeBinary("/saves/slot1.bin", data);
    assert.equal(w.ok, true, w.ok ? "" : w.error.message);
    // 关键：这里不经过 IFileSystem，直接看盘
    const onDisk = readFileSync(join(root, "saves", "slot1.bin"));
    assert.deepEqual([...onDisk], [...data]);
    assert.equal(await fs.exists("/saves/slot1.bin"), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("[node] 虚拟路径不含 root（否则 OS 路径迟早被写进存档）", async () => {
  const root = tempRoot("vpath");
  try {
    const fs = new NodeFileSystem(root);
    await fs.writeText("/a/b.txt", "x");
    const st = await fs.stat("/a/b.txt");
    assert.equal(st.ok, true);
    const ents = await fs.list("/a");
    assert.equal(ents.ok, true);
    if (!ents.ok) return;
    assert.deepEqual(ents.value.map((e) => e.path), ["/a/b.txt"]);
    assert.equal(JSON.stringify(ents.value).includes(root.replace(/\\/g, "\\\\")), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("[node] root 带中文与空格也能用（Windows 真实项目路径常常如此）", async () => {
  const base = tempRoot("cn");
  const root = join(base, "存档 目录");
  try {
    const fs = new NodeFileSystem(root);
    const w = await fs.writeText("/slot 1.json", '{"a":1}');
    assert.equal(w.ok, true, w.ok ? "" : w.error.message);
    const r = await fs.readText("/slot 1.json");
    assert.equal(r.ok && r.value, '{"a":1}');
    assert.deepEqual(readdirSync(root), ["slot 1.json"]);
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});

test("[node] 原子写不留临时文件（写完目录里只有一个文件）", async () => {
  const root = tempRoot("tmp");
  try {
    const fs = new NodeFileSystem(root);
    for (let i = 0; i < 5; i++) await fs.writeBinary("/save.bin", new Uint8Array([i]));
    assert.deepEqual(readdirSync(root), ["save.bin"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("[node] 符号链接把路径引到 root 之外 → FS.PATH_ESCAPE", async (t) => {
  const root = tempRoot("link");
  const outside = tempRoot("outside");
  try {
    const fs = new NodeFileSystem(root);
    // Windows 上建目录符号链接需要管理员权限，junction 不需要
    const type = process.platform === "win32" ? "junction" : "dir";
    try {
      symlinkSync(outside, join(root, "link"), type);
    } catch (e) {
      t.diagnostic(`跳过：当前环境不能创建符号链接（${e instanceof Error ? e.message : ""}）`);
      return;
    }
    const w = await fs.writeBinary("/link/escaped.txt", new Uint8Array([1]));
    assert.equal(w.ok, false, "通过符号链接写到了 root 之外");
    if (!w.ok) assert.equal(w.error.code, "FS.PATH_ESCAPE", `错误码不对：${w.error.message}`);
    assert.deepEqual(readdirSync(outside), [], "盘外目录被写入了内容");
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test("[node] 后端工厂：没给 root 就拒绝（不拿当前工作目录当根）", () => {
  assert.equal(nodeFsBackend.scheme, "node");
  assert.equal(nodeFsBackend.probe(), true, "在 Node 里 probe 必须是 true");
  const noRoot = nodeFsBackend.create({});
  assert.equal(noRoot.ok, false);
  if (!noRoot.ok) assert.equal(noRoot.error.code, "FS.BAD_OPTIONS");

  const missing = nodeFsBackend.create({ root: join(tempRoot("noexist"), "nope"), createRoot: false });
  assert.equal(missing.ok, false);
  if (!missing.ok) assert.equal(missing.error.code, "FS.BAD_ROOT");

  const made = nodeFsBackend.create({ root: tempRoot("factory") });
  assert.equal(made.ok, true);
  if (made.ok) {
    assert.equal(made.value.scheme, "node");
    rmSync((made.value as NodeFileSystem).root, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------------ 存档 × 跨宿主 × 重启

class Ttl extends Component {
  ttl = 7.5;
  readonly schema: ComponentSchema = { type: "test.ttl", fields: { ttl: FieldType.Float } };
}

function buildScene(): Scene {
  const reg = new ComponentRegistry();
  reg.register({ type: "test.ttl", fields: { ttl: FieldType.Float } }, () => new Ttl());
  const scene = new Scene("save-test", reg);
  const a = scene.spawnImmediate("hero");
  a.setLocalPosition(1.25, -2.5);
  const b = scene.spawnImmediate("child", a.id);
  b.setLocalScale(2, 3);
  b.zIndex = 4;
  scene.attach(a.id, () => new Ttl());
  scene.flush();
  return scene;
}

test("[node] 存 → 落盘 → **新进程**读回 → 再存：sha256 相同", async () => {
  const root = tempRoot("save");
  try {
    const fs = new NodeFileSystem(root);
    const snap = saveScene(buildScene());
    const text = sceneToJson(snap);
    const w = await fs.writeText("/slot1.json", text);
    assert.equal(w.ok, true, w.ok ? "" : w.error.message);

    // 子进程：全新进程，只拿盘上的文件与序列化入口
    const r = spawnSync(
      process.execPath,
      ["--experimental-transform-types", CHILD, join(root, "slot1.json"), SCENE_IO_URL],
      { encoding: "utf8", timeout: 60_000 },
    );
    assert.equal(r.status, 0, `子进程退出码 ${r.status}：${r.stderr}`);
    const line = (r.stdout ?? "").trim().split("\n").pop() ?? "";
    const out = JSON.parse(line) as {
      ok: boolean;
      error?: string;
      pid?: number;
      nodes?: number;
      sameBytes?: boolean;
      shaOnDisk?: string;
      shaAgain?: string;
    };
    assert.equal(out.ok, true, `子进程解析存档失败：${out.error ?? ""}`);
    assert.notEqual(out.pid, process.pid, "子进程竟然和父进程同 pid");
    assert.equal(out.sameBytes, true, "新进程 读→再存 的字节与原文件不同");
    assert.equal(out.shaAgain, out.shaOnDisk);
    assert.equal(out.shaOnDisk, createHash("sha256").update(text).digest("hex"), "盘上文件被改过");
    assert.equal(out.nodes, snap.nodes.length, "新进程读到的节点数和存的时候不一样");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("[node] 同一份存档：内存盘与真实盘写出的字节完全相同（跨宿主不用迁就）", async () => {
  const root = tempRoot("equal");
  try {
    const mem = new MemoryFileSystem();
    const node = new NodeFileSystem(root);
    const text = sceneToJson(saveScene(buildScene()));
    await mem.writeText("/slot1.json", text);
    await node.writeText("/slot1.json", text);
    const a = await mem.readBinary("/slot1.json");
    const b = await node.readBinary("/slot1.json");
    assert.equal(a.ok && b.ok, true);
    if (!a.ok || !b.ok) return;
    assert.deepEqual([...a.value], [...b.value]);
    assert.equal(createHash("sha256").update(a.value).digest("hex"), createHash("sha256").update(b.value).digest("hex"));
    assert.equal(new TextDecoder().decode(b.value), text, "真实盘上的内容被改写过");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
