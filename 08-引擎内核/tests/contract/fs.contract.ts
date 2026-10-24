/**
 * 文件系统后端契约测试
 *
 * ★ 为什么要契约：`IFileSystem` 有 10 个方法，每个方法都有**没说清楚**的语义缝隙：
 *   "写入要不要先建父目录"、"删一个目录算什么"、"符号链接跟不跟"、
 *   "list 的 path 是 OS 路径还是虚拟路径"。这些缝隙在只有一个实现时永远发现不了，
 *   接上第二个实现（mem / node）时全部暴露 —— 而那时通常已经有存档写在盘上了。
 *
 * ★ 每条用例都跑在两个后端上。任何一条只在一个后端通过，说明**接口没定义清楚**，
 *   不等于"那个后端有 bug"。
 *
 * ★ 有一条用例是"真原子性"：一边写一边读，读到的必须是**某一次的完整内容**，
 *   不允许"半截文件"或"两次写入混在一起"。这条用例只有在写入走
 *   "临时文件 → rename" 时才成立；直接 `open(w)+write` 会红。
 *   它同时也是"存档在崩溃时不会只写一半"的证据。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { IFileSystem, IReadableFileSystem } from "../../src/platform/fs/fs.ts";

export interface FsCase {
  readonly name: string;
  run(fs: IFileSystem): Promise<void>;
}

/** 只读用例：跑在所有后端上（含不可写的 fs-http）。 */
export interface ReadCase {
  readonly name: string;
  run(fs: IReadableFileSystem): Promise<void>;
}

const ALL_BYTES = Array.from({ length: 256 }, (_, i) => i);

// ------------------------------------------------------------------ 共用夹具
//
// ★ 只读契约不能靠"用例自己先写文件"来准备数据 —— 只读后端写不了。
//   所以夹具在这里**声明一次**，两个世界各自铺：
//   · 可写后端：`seedFixtures(fs)` 真写进去；
//   · http 后端：判据用同一份声明造一个假 `fetch`。
//   期望值因此也是同一份 —— 否则"三个后端都对"只是三套各自的期望。

export interface FixtureFile {
  readonly path: string;
  readonly bytes: Uint8Array;
}

export const FIXTURE_TEXT = "第一行\nsecond line\n";
export const FIXTURE_FILES: readonly FixtureFile[] = [
  { path: "/saves/a.txt", bytes: new TextEncoder().encode(FIXTURE_TEXT) },
  { path: "/raw.bin", bytes: new Uint8Array(ALL_BYTES) },
  { path: "/empty.bin", bytes: new Uint8Array(0) },
  { path: "/bad.txt", bytes: new Uint8Array([0xff, 0xfe, 0x41]) },
  { path: "/d/z.txt", bytes: new TextEncoder().encode("zz") },
  { path: "/d/a.txt", bytes: new TextEncoder().encode("a") },
  { path: "/d/sub/inner.txt", bytes: new TextEncoder().encode("inner") },
];

export const FIXTURE_DIRS: readonly string[] = ["/adir", "/d", "/d/sub"];

/** 把夹具写进可写后端（只读后端用假 fetch 铺，不调这个）。 */
export async function seedFixtures(fs: IFileSystem): Promise<void> {
  for (const d of FIXTURE_DIRS) expectOk(await fs.ensureDir(d));
  for (const f of FIXTURE_FILES) expectOk(await fs.writeBinary(f.path, f.bytes));
}

function expectCode<T>(r: Result<T, EngineError>, code: string): void {
  assert.equal(r.ok, false, `期望失败（${code}），实际成功了`);
  if (!r.ok) assert.equal(r.error.code, code, `错误码不对：期望 ${code}，实际 ${r.error.code}（${r.error.message}）`);
}

function expectOk<T>(r: Result<T, EngineError>): T {
  assert.equal(r.ok, true, r.ok ? "" : `期望成功，实际失败：${r.error.code} ${r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

export const FS_CASES: readonly FsCase[] = [
  {
    name: "文本往返：UTF-8 多字节原样读回",
    async run(fs) {
      expectOk(await fs.writeText("/saves/a.txt", "第一行\nsecond line\n"));
      assert.equal(expectOk(await fs.readText("/saves/a.txt")), "第一行\nsecond line\n");
    },
  },
  {
    name: "二进制保真：0..255 全字节表往返",
    async run(fs) {
      expectOk(await fs.writeBinary("/raw.bin", new Uint8Array(ALL_BYTES)));
      assert.deepEqual([...expectOk(await fs.readBinary("/raw.bin"))], ALL_BYTES);
    },
  },
  {
    name: "越界路径被拒绝（而不是被'聪明地'解析到盘外）",
    async run(fs) {
      expectCode(await fs.writeBinary("/../escape.bin", new Uint8Array([1])), "FS.PATH_ESCAPE");
      expectCode(await fs.readBinary("/a/../../etc/passwd"), "FS.PATH_ESCAPE");
      // 而且盘上什么都没发生
      assert.equal(await fs.exists("/escape.bin"), false);
    },
  },
  {
    name: "不存在的路径：读/stat/list 都是 FS.NOT_FOUND（不是静默空值）",
    async run(fs) {
      expectCode(await fs.readBinary("/nope.bin"), "FS.NOT_FOUND");
      expectCode(await fs.stat("/nope.bin"), "FS.NOT_FOUND");
      expectCode(await fs.list("/nope"), "FS.NOT_FOUND");
    },
  },
  {
    name: "指向目录的读写：FS.IS_DIR（不是读成空、也不是 FS.NOT_FOUND）",
    async run(fs) {
      expectOk(await fs.ensureDir("/adir"));
      expectCode(await fs.readBinary("/adir"), "FS.IS_DIR");
      expectCode(await fs.readText("/adir"), "FS.IS_DIR");
    },
  },
  {
    name: "覆盖写：更短的内容不留尾巴",
    async run(fs) {
      expectOk(await fs.writeText("/o.txt", "0123456789"));
      expectOk(await fs.writeText("/o.txt", "abc"));
      assert.equal(expectOk(await fs.readText("/o.txt")), "abc");
      assert.equal(expectOk(await fs.stat("/o.txt")).size, 3);
    },
  },
  {
    name: "0 字节文件存在且能读回空",
    async run(fs) {
      expectOk(await fs.writeBinary("/empty.bin", new Uint8Array(0)));
      assert.equal(expectOk(await fs.readBinary("/empty.bin")).byteLength, 0);
      assert.equal(await fs.exists("/empty.bin"), true);
      assert.equal(expectOk(await fs.stat("/empty.bin")).size, 0);
    },
  },
  {
    name: "没 ensureDir 也能写（自动建父目录），list 能看见",
    async run(fs) {
      expectOk(await fs.writeText("/deep/a/b/c.txt", "x"));
      assert.equal(await fs.exists("/deep/a/b/c.txt"), true);
      assert.deepEqual(expectOk(await fs.list("/deep/a/b")).map((e) => e.name), ["c.txt"]);
    },
  },
  {
    name: "list：只列直接子项、按名字升序、目录 size=0、path 是虚拟路径",
    async run(fs) {
      expectOk(await fs.writeText("/d/z.txt", "zz"));
      expectOk(await fs.writeText("/d/a.txt", "a"));
      expectOk(await fs.ensureDir("/d/sub"));
      expectOk(await fs.writeText("/d/sub/inner.txt", "inner"));
      const ents = expectOk(await fs.list("/d"));
      assert.deepEqual(ents.map((e) => e.name), ["a.txt", "sub", "z.txt"]);
      const sub = ents.find((e) => e.name === "sub");
      const a = ents.find((e) => e.name === "a.txt");
      assert.equal(sub?.isDirectory, true);
      assert.equal(sub?.size, 0);
      assert.equal(a?.isDirectory, false);
      assert.equal(a?.size, 1);
      // ★ path 必须是虚拟路径：把 OS 路径交给调用方，迟早会被写进存档
      for (const e of ents) {
        assert.equal(e.path.startsWith("/"), true, `path 不是虚拟路径：${e.path}`);
        assert.equal(e.path.includes(".."), false);
        assert.equal(e.path.includes("\\"), false);
      }
    },
  },
  {
    name: "stat：文件给字节数、目录 isDirectory=true 且 size=0",
    async run(fs) {
      expectOk(await fs.writeText("/s.txt", "12345"));
      const st = expectOk(await fs.stat("/s.txt"));
      assert.equal(st.size, 5);
      assert.equal(st.isDirectory, false);
      assert.ok(st.mtimeMs >= 0, `mtimeMs 不能是负的：${st.mtimeMs}`);
      expectOk(await fs.ensureDir("/sd"));
      const sd = expectOk(await fs.stat("/sd"));
      assert.equal(sd.isDirectory, true);
      assert.equal(sd.size, 0);
    },
  },
  {
    name: "exists：文件/目录 true，不存在与越界路径 false（不抛）",
    async run(fs) {
      assert.equal(await fs.exists("/nope.txt"), false);
      assert.equal(await fs.exists("/../x"), false);
      expectOk(await fs.ensureDir("/dd"));
      assert.equal(await fs.exists("/dd"), true);
      expectOk(await fs.writeText("/dd/f", "1"));
      assert.equal(await fs.exists("/dd/f"), true);
    },
  },
  {
    name: "ensureDir：递归建 + 幂等",
    async run(fs) {
      expectOk(await fs.ensureDir("/x/y/z"));
      expectOk(await fs.ensureDir("/x/y/z"));
      expectOk(await fs.ensureDir("/x"));
      assert.equal(await fs.exists("/x/y/z"), true);
    },
  },
  {
    name: "remove：删文件后不存在；删目录是 FS.IS_DIR（不静默删子树）",
    async run(fs) {
      expectOk(await fs.writeText("/r.txt", "1"));
      expectOk(await fs.remove("/r.txt"));
      assert.equal(await fs.exists("/r.txt"), false);
      expectCode(await fs.remove("/r.txt"), "FS.NOT_FOUND");
      expectOk(await fs.ensureDir("/rdir"));
      expectCode(await fs.remove("/rdir"), "FS.IS_DIR");
      assert.equal(await fs.exists("/rdir"), true, "报错就不能真的删掉");
    },
  },
  {
    name: "非 UTF-8 字节 readText → FS.NOT_UTF8（不返回替换字符）",
    async run(fs) {
      expectOk(await fs.writeBinary("/bad.txt", new Uint8Array([0xff, 0xfe, 0x41])));
      expectCode(await fs.readText("/bad.txt"), "FS.NOT_UTF8");
    },
  },
  {
    name: "原子写：边写边读，只能读到某一次的完整内容",
    async run(fs) {
      const SIZE = 16 * 1024;
      const payload = (fill: number): Uint8Array => new Uint8Array(SIZE).fill(fill);
      let writing = true;
      const problems: string[] = [];
      let reads = 0;
      const reader = (async () => {
        // 上限是"防止用例自己变成死循环"：写侧一旦抛错，writing 可能停在 true
        while (writing && reads < 200_000) {
          const r = await fs.readBinary("/atomic.bin");
          reads++;
          if (!r.ok) {
            if (r.error.code !== "FS.NOT_FOUND") problems.push(`意外错误 ${r.error.code}`);
            continue;
          }
          const v = r.value;
          if (v.byteLength !== SIZE) {
            problems.push(`读到半截文件：${v.byteLength} / ${SIZE} 字节`);
            continue;
          }
          const first = v[0];
          if (!v.every((b) => b === first)) problems.push("读到两次写入混在一起的内容");
        }
      })();
      try {
        for (let i = 0; i < 40; i++) expectOk(await fs.writeBinary("/atomic.bin", payload(i)));
      } finally {
        // ★ 必须在 finally 里停读者：写侧断言失败时若不停，读者会一直转，
        //   测试进程在"报完错之后"继续挂 90 秒 —— 报错被淹没在超时里。
        writing = false;
        await reader;
      }
      assert.equal(problems.length, 0, `原子性被破坏：${problems.slice(0, 3).join(" / ")}`);
      // 反向自检：读者必须真的读到过东西，否则这条用例是空转
      assert.ok(reads > 0, "读者一次都没读过 —— 用例没生效");
      assert.equal(expectOk(await fs.readBinary("/atomic.bin")).byteLength, SIZE);
    },
  },
];

/** 用同一个后端跑完全部契约用例（每个用例独立实例，避免互相污染）。 */
export function runFsContract(
  backendName: string,
  make: () => IFileSystem,
  dispose?: (fs: IFileSystem) => Promise<void>,
): void {
  for (const c of FS_CASES) {
    test(`[${backendName}] 契约 · ${c.name}`, async () => {
      const fs = make();
      try {
        await c.run(fs);
      } finally {
        await dispose?.(fs);
      }
    });
  }
}


// ------------------------------------------------------------------ 只读契约
//
// ★ 为什么单独一套：`fs-http` 只实现 `IReadableFileSystem`（类型上就写不了）。
//   如果只读能力靠"跑完整契约、跳过写用例"来验，那么"只读"这件事本身就没有判据 ——
//   而它恰恰是最容易悄悄退化成"能写"的地方（谁只要给后端补两个方法，编译照样过）。

export const READ_CASES: readonly ReadCase[] = [
  {
    name: "读文本：UTF-8 多字节原样",
    async run(fs) {
      assert.equal(expectOk(await fs.readText("/saves/a.txt")), FIXTURE_TEXT);
    },
  },
  {
    name: "读二进制：0..255 全字节保真",
    async run(fs) {
      assert.deepEqual([...expectOk(await fs.readBinary("/raw.bin"))], ALL_BYTES);
    },
  },
  {
    name: "0 字节文件：读回空、exists 为真、stat.size 为 0",
    async run(fs) {
      assert.equal(expectOk(await fs.readBinary("/empty.bin")).byteLength, 0);
      assert.equal(await fs.exists("/empty.bin"), true);
      assert.equal(expectOk(await fs.stat("/empty.bin")).size, 0);
    },
  },
  {
    name: "不存在：读与 stat 都是 FS.NOT_FOUND",
    async run(fs) {
      expectCode(await fs.readBinary("/nope.bin"), "FS.NOT_FOUND");
      expectCode(await fs.readText("/nope.bin"), "FS.NOT_FOUND");
      expectCode(await fs.stat("/nope.bin"), "FS.NOT_FOUND");
    },
  },
  {
    name: "exists：有则真、无则假、越界也假（不抛）",
    async run(fs) {
      assert.equal(await fs.exists("/raw.bin"), true);
      assert.equal(await fs.exists("/nope.bin"), false);
      assert.equal(await fs.exists("/../etc/passwd"), false, "越界路径必须 false，不许抛");
    },
  },
  {
    name: "越界：`..` 一律 PATH_ESCAPE（连看起来无害的 /a/../b 也拒绝）",
    async run(fs) {
      expectCode(await fs.readBinary("/../x"), "FS.PATH_ESCAPE");
      expectCode(await fs.readBinary("/a/../../etc/passwd"), "FS.PATH_ESCAPE");
      // ★ `/a/../b` 归一化后是合法的 `/b`，但"归一化"意味着任何拼接错误都会变成
      //   一次合法的越界读。宁可报错。
      expectCode(await fs.readBinary("/a/../b"), "FS.PATH_ESCAPE");
    },
  },
  {
    name: "非 UTF-8：readText 报 NOT_UTF8（不返回替换字符）",
    async run(fs) {
      expectCode(await fs.readText("/bad.txt"), "FS.NOT_UTF8");
    },
  },
  {
    name: "stat：文件 size 正确、isDirectory=false、mtime 非负",
    async run(fs) {
      const st = expectOk(await fs.stat("/saves/a.txt"));
      assert.equal(st.size, FIXTURE_FILES[0]!.bytes.byteLength);
      assert.equal(st.isDirectory, false);
      assert.equal(st.mtimeMs >= 0, true, `mtimeMs 不能是负的：${st.mtimeMs}`);
    },
  },
  {
    name: "list：能列的后端内容正确；不能列的必须 NOT_SUPPORTED（不许返回空数组）",
    async run(fs) {
      const r = await fs.list("/d");
      if (!fs.canList) {
        // ★ 空数组的含义是"目录是空的"。这里必须说"我不会列目录"。
        expectCode(r, "FS.NOT_SUPPORTED");
        return;
      }
      const names = expectOk(r).map((e) => e.name);
      assert.deepEqual(names, ["a.txt", "sub", "z.txt"]);
    },
  },
  {
    name: "指向目录的读：能列目录的后端报 IS_DIR；不能列的报 NOT_FOUND",
    async run(fs) {
      if (fs.canList) {
        expectCode(await fs.readBinary("/adir"), "FS.IS_DIR");
        expectCode(await fs.readText("/adir"), "FS.IS_DIR");
      } else {
        // 没有目录概念的后端里 /adir 只是个不存在的资源
        expectCode(await fs.readBinary("/adir"), "FS.NOT_FOUND");
      }
    },
  },
  {
    name: "重复读同一路径 50 次：内容逐字节一致（没有会变的缓存）",
    async run(fs) {
      const first = expectOk(await fs.readBinary("/raw.bin"));
      for (let i = 0; i < 50; i++) {
        const again = expectOk(await fs.readBinary("/raw.bin"));
        assert.equal(again.byteLength, first.byteLength, `第 ${i + 1} 次读长度变了`);
        if (i % 10 === 0) assert.deepEqual([...again], [...first], `第 ${i + 1} 次读内容变了`);
      }
    },
  },
];

/** 跑只读契约。`make` 负责把夹具铺好再交出来（可写后端写真文件，http 造假 fetch）。 */
export function runReadContract(
  backendName: string,
  make: () => Promise<IReadableFileSystem> | IReadableFileSystem,
  dispose?: (fs: IReadableFileSystem) => Promise<void>,
): void {
  for (const c of READ_CASES) {
    test(`[${backendName}] 只读契约 · ${c.name}`, async () => {
      const fs = await make();
      try {
        await c.run(fs);
      } finally {
        await dispose?.(fs);
      }
    });
  }
}
