/**
 * L6 · 小游戏（wx）宿主适配层判据
 *
 * ★ 这一组判据的**唯一可能性**是"用一个假的 wx 驱动"：真机验证要微信开发者工具，
 *   与 B1（微信上传）是同一条外部依赖。所以假 wx 必须**故意做成最低配**：
 *   只有结构上的那几个方法，任何一处用到别的能力都会当场 `TypeError`。
 *   这不是"模拟得像"，而是"多要一样就崩"——它比模拟更严格。
 *
 * ★ 最后一组是**自指闸门**：扫 `src/host/wx/*.ts` 的源码，断言 `FORBIDDEN_IN_MINIGAME`
 *   零命中。注释里点名那些 API 是必须的（这层存在的理由就是它们），所以扫描前先剥注释 ——
 *   剥注释这件事本身也有一条判据（合成样本：注释里有、代码里没有 ⇒ 0 命中）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  WX_ERR,
  acquireCanvas,
  probeWebgl2,
  readViewport,
  type WxCanvasLike,
  type WxLike,
  type WxTouchEventLike,
  type WxTouchHandler,
} from "../../src/host/wx/env.ts";
import { pickRaf, WxTickSource } from "../../src/host/wx/tick.ts";
import { WX_USER_DATA_PATH, createWxFileSystem, WxFileSystem, type WxFsManagerLike } from "../../src/host/wx/fs.ts";
import {
  createWxInput,
  hitTestPad,
  makeDefaultPad,
  toCanvasPoint,
  type VirtualPad,
} from "../../src/host/wx/input.ts";
import { createWxHost } from "../../src/host/wx/index.ts";
import { FORBIDDEN_IN_MINIGAME, scanMiniGameSource } from "../../src/publish/pack-plan.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const WX_DIR = join(HERE, "..", "..", "src", "host", "wx");
/** 仓库根（`src/` 的上一层）。自指闸门（批128）按**相对路径**点名文件时用它。 */
const ROOT = join(HERE, "..", "..");

// ---------------------------------------------------------------- 假的 wx

interface FakeCanvas {
  readonly canvas: WxCanvasLike;
  /**
   * 手动跑掉当前排队的帧回调（顺序执行，不重排）。
   *
   * ★ 故意**给回调塞一个假时间戳**：小游戏的 rAF 不保证传参数，而浏览器一定传。
   *   实现里只要读了那个参数，dt 就会变成天文数字 —— 这是唯一能在 headless 里
   *   抓到"读了不该读的东西"的办法（不塞参数就永远抓不到，两种实现都对着）。
   */
  pump(ts?: number): void;
  pending(): number;
}

function makeCanvas(width = 1000, height = 1000, raf = true): FakeCanvas {
  const queue: { id: number; cb: () => void }[] = [];
  let next = 1;
  const ctx: Record<string, unknown> = { "webgl2": { tag: "gl2" }, "2d": { tag: "2d" } };
  const base: WxCanvasLike = {
    width,
    height,
    getContext: (kind: string) => ctx[kind] ?? null,
  };
  const canvas: WxCanvasLike = raf
    ? {
        ...base,
        requestAnimationFrame: (cb: () => void) => {
          const id = next++;
          queue.push({ id, cb });
          return id;
        },
        cancelAnimationFrame: (id: number) => {
          const at = queue.findIndex((q) => q.id === id);
          if (at >= 0) queue.splice(at, 1);
        },
      }
    : base;
  return {
    canvas,
    pump: (ts?: number) => {
      const now = queue.splice(0);
      for (const f of now) (f.cb as (t: number) => void)(ts ?? 0);
    },
    pending: () => queue.length,
  };
}

interface FakeMgr extends WxFsManagerLike {
  readonly files: Map<string, Uint8Array>;
  readonly dirs: Set<string>;
  readonly calls: { stat: number; mkdir: number; unlink: number; rmdir: number; rename: number };
  /** 记下每次 rename 的 (源, 目标)：用来验"源是临时文件、且两次写不撞名"。 */
  readonly renames: { from: string; to: string }[];
  /**
   * 让下一次 `writeFileSync` **先落下半截内容再抛异常**。
   *
   * ★ 必须真的留下半截：真实的 `writeFileSync` 失败时临时文件通常**已经存在**
   *   （写到一半满了 / 被杀了），"失败就没建文件"是个不存在的世界。
   *   第一版夹具就是那样，于是「失败要删临时文件」那条判据永远绿（M827 假绿）。
   */
  failWriteOnce(errMsg: string): void;
  /** 让下一次 `renameSync` 抛异常（写成功了、挪不过去）。 */
  failRenameOnce(errMsg: string): void;
  /** 模拟"该实现不覆盖已存在的目标"（rename 报 already exists）。 */
  setRenameRejectsExisting(v: boolean): void;
  /** 模拟老基础库：根本没有 renameSync。 */
  dropRename(): void;
  /** 让 `accessSync` 对"不存在"改为抛异常（部分实现是这样）。 */
  setAccessThrows(v: boolean): void;
  /** 下一次调用抛一个指定 errMsg 的异常（用来验错误分类）。 */
  failNext(errMsg: string): void;
}

function makeMgr(root = WX_USER_DATA_PATH): FakeMgr {
  const files = new Map<string, Uint8Array>();
  const dirs = new Set<string>([root]);
  const calls = { stat: 0, mkdir: 0, unlink: 0, rmdir: 0, rename: 0 };
  const renames: { from: string; to: string }[] = [];
  let accessThrows = false;
  let nextFail: string | null = null;
  let nextWriteFail: string | null = null;
  let nextRenameFail: string | null = null;
  let renameRejectsExisting = false;
  let hasRename = true;
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const parentOf = (p: string): string => {
    const at = p.lastIndexOf("/");
    return at <= 0 ? "" : p.slice(0, at);
  };
  const notFound = (p: string): never => {
    throw { errMsg: `no such file or directory: ${p}` };
  };
  const mgr: FakeMgr = {
    files,
    dirs,
    calls,
    renames,
    failWriteOnce: (m) => {
      nextWriteFail = m;
    },
    failRenameOnce: (m) => {
      nextRenameFail = m;
    },
    setRenameRejectsExisting: (v) => {
      renameRejectsExisting = v;
    },
    dropRename: () => {
      hasRename = false;
    },
    setAccessThrows: (v) => {
      accessThrows = v;
    },
    failNext: (m) => {
      nextFail = m;
    },
    readFileSync: (p: string, encoding?: string): string | ArrayBuffer => {
      if (nextFail !== null) {
        const m = nextFail;
        nextFail = null;
        throw { errMsg: m };
      }
      const v = files.get(p);
      if (v === undefined) return notFound(p);
      if (encoding !== undefined) return dec.decode(v);
      const out = new ArrayBuffer(v.length);
      new Uint8Array(out).set(v);
      return out;
    },
    writeFileSync: (p: string, data: string | ArrayBuffer, encoding?: string): void => {
      if (nextWriteFail !== null) {
        const m = nextWriteFail;
        nextWriteFail = null;
        // ★ 真实失败是"写到一半"：文件已经在了、内容是断的。留下这半截，
        //   「失败要把临时文件删掉」才是一条有分辨力的判据。
        const body = typeof data === "string" ? enc.encode(data) : new Uint8Array(data, 0, data.byteLength);
        files.set(p, body.slice(0, Math.max(1, body.length >> 1)));
        throw { errMsg: m };
      }
      const parent = parentOf(p);
      if (parent.length > 0 && !dirs.has(parent)) {
        // ★ 真实行为：不会自动建目录。
        throw { errMsg: `writeFileSync:fail no such file or directory ${parent}` };
      }
      if (typeof data === "string") {
        if (encoding !== "utf8") throw { errMsg: "writeFileSync:fail bad encoding" };
        files.set(p, enc.encode(data));
      } else {
        // ★ 存**视图**而不是拷贝：真实的 wx 会持有调用方给的 buffer，
        //   调用方随后复用同一块内存就会改到已写入的内容。这里照着实现，
        //   否则「写之前要复制」那条判据永远绿（等价变异）。
        files.set(p, new Uint8Array(data, 0, data.byteLength));
      }
    },
    readdirSync: (p: string): string[] => {
      if (!dirs.has(p)) return notFound(p);
      const pref = p.endsWith("/") ? p : `${p}/`;
      const out: string[] = [];
      for (const f of files.keys()) {
        if (!f.startsWith(pref)) continue;
        const rest = f.slice(pref.length);
        if (!rest.includes("/")) out.push(rest);
      }
      for (const d of dirs) {
        if (d === p || !d.startsWith(pref)) continue;
        const rest = d.slice(pref.length);
        if (!rest.includes("/")) out.push(rest);
      }
      // 故意**倒序**：判据要证明 `list` 自己排了序（不指望文件系统的顺序）。
      return out.reverse();
    },
    statSync: (p: string) => {
      calls.stat++;
      const f = files.get(p);
      if (f !== undefined) {
        return { size: f.length, lastModifiedTime: 1234, isFile: () => true, isDirectory: () => false };
      }
      if (dirs.has(p)) return { size: 0, isDirectory: () => true, isFile: () => false };
      return notFound(p);
    },
    mkdirSync: (p: string, recursive?: boolean): void => {
      calls.mkdir++;
      if (dirs.has(p)) throw { errMsg: `mkdirSync:fail file already exists: ${p}` };
      const parent = parentOf(p);
      if (recursive === true) {
        // `wxfile://usr/deep/nest` → 逐级建；scheme 前缀（`wxfile://`）原样保留。
        const m = /^([a-z]+:\/\/)(.*)$/i.exec(p);
        const prefix = m === null ? "" : m[1]!;
        const rest = m === null ? p : m[2]!;
        let cur = prefix;
        for (const seg of rest.split("/")) {
          if (seg.length === 0) continue;
          cur = cur === prefix ? `${prefix}${seg}` : `${cur}/${seg}`;
          dirs.add(cur);
        }
        return;
      }
      if (parent.length > 0 && !dirs.has(parent)) throw { errMsg: `mkdirSync:fail no such file or directory` };
      dirs.add(p);
    },
    unlinkSync: (p: string): void => {
      calls.unlink++;
      if (!files.has(p)) notFound(p);
      files.delete(p);
    },
    rmdirSync: (p: string, recursive?: boolean): void => {
      calls.rmdir++;
      if (!dirs.has(p)) notFound(p);
      if (recursive !== true) {
        const any = [...files.keys(), ...dirs].some((x) => x !== p && x.startsWith(`${p}/`));
        if (any) throw { errMsg: "rmdirSync:fail directory not empty" };
      }
      for (const f of [...files.keys()]) if (f.startsWith(`${p}/`)) files.delete(f);
      for (const d of [...dirs]) if (d === p || d.startsWith(`${p}/`)) dirs.delete(d);
    },
    accessSync: (p: string): boolean => {
      const okv = files.has(p) || dirs.has(p);
      if (!okv && accessThrows) throw { errMsg: `accessSync:fail no such file or directory ${p}` };
      return okv;
    },
  };
  // ★ 用 getter 挂 renameSync，`dropRename()` 才能真的把它从对象上**摘掉**
  //   （写成普通字段的话 `delete` 之后原型上还在，判据里那条"老基础库"永远假绿）。
  Object.defineProperty(mgr, "renameSync", {
    configurable: true,
    get: () => {
      if (!hasRename) return undefined;
      return (from: string, to: string): void => {
        calls.rename++;
        renames.push({ from, to });
        if (nextRenameFail !== null) {
          const m = nextRenameFail;
          nextRenameFail = null;
          throw { errMsg: m };
        }
        if (!files.has(from)) notFound(from);
        if (files.has(to)) {
          if (renameRejectsExisting) throw { errMsg: `renameSync:fail file already exists: ${to}` };
          files.delete(to);
        }
        files.set(to, files.get(from)!);
        files.delete(from);
      };
    },
  });
  return mgr;
}

interface FakeWx {
  readonly wx: WxLike;
  readonly canvas: FakeCanvas;
  readonly mgr: FakeMgr;
  /** 派发一个触摸事件给所有订阅者。 */
  touch(kind: "start" | "move" | "end" | "cancel", ev: WxTouchEventLike): void;
  readonly counts: { wxRaf: number; subs: number; offs: number };
}

interface FakeWxOptions {
  readonly canvas?: boolean;
  readonly info?: boolean;
  readonly wxRaf?: boolean;
  readonly touch?: boolean;
  readonly fs?: boolean;
  readonly off?: boolean;
  readonly width?: number;
  readonly height?: number;
  readonly windowWidth?: number;
  readonly windowHeight?: number;
  readonly pixelRatio?: number;
}

function makeWx(o: FakeWxOptions = {}): FakeWx {
  const fc = makeCanvas(o.width ?? 1000, o.height ?? 1000, true);
  const mgr = makeMgr();
  const counts = { wxRaf: 0, subs: 0, offs: 0 };
  const handlers = new Map<string, Set<WxTouchHandler>>();
  const wantTouch = o.touch !== false;
  const wantOff = o.off !== false;

  const wx: Record<string, unknown> = {
    ...(o.canvas === false ? {} : { createCanvas: () => fc.canvas }),
    ...(o.info === false
      ? {}
      : {
          getSystemInfoSync: () => ({
            windowWidth: o.windowWidth ?? 500,
            windowHeight: o.windowHeight ?? 500,
            pixelRatio: o.pixelRatio ?? 2,
          }),
        }),
    ...(o.wxRaf === true
      ? {
          requestAnimationFrame: (_cb: () => void) => {
            counts.wxRaf++;
            return 0;
          },
          cancelAnimationFrame: () => {},
        }
      : {}),
    ...(o.fs === false ? {} : { getFileSystemManager: () => mgr }),
  };
  for (const kind of ["Start", "Move", "End", "Cancel"]) {
    if (!wantTouch) continue;
    const key = `onTouch${kind}`;
    wx[key] = (cb: WxTouchHandler) => {
      counts.subs++;
      const set = handlers.get(kind) ?? new Set<WxTouchHandler>();
      set.add(cb);
      handlers.set(kind, set);
    };
    if (!wantOff) continue;
    wx[`offTouch${kind}`] = (cb: WxTouchHandler) => {
      counts.offs++;
      handlers.get(kind)?.delete(cb);
    };
  }

  return {
    wx: wx as unknown as WxLike,
    canvas: fc,
    mgr,
    counts,
    touch: (kind, ev) => {
      const name = kind[0]!.toUpperCase() + kind.slice(1);
      for (const cb of [...(handlers.get(name) ?? [])]) cb(ev);
    },
  };
}

/** 一个测试用的固定键位（画布像素）。 */
const PAD: VirtualPad = {
  dpad: { x: 0, y: 0, w: 400, h: 400 },
  deadZone: 0.2,
  buttons: [{ key: "Space", rect: { x: 600, y: 0, w: 100, h: 100 } }],
};

const TOUCH_AT = (identifier: number, x: number, y: number) => ({ identifier, clientX: x, clientY: y });

// ---------------------------------------------------------------- env

test("★ acquireCanvas：返回的正是 createCanvas 那一个（不复制、不自造）", () => {
  const f = makeWx();
  const r = acquireCanvas(f.wx);
  assert.equal(r.ok, true);
  assert.equal(r.ok && r.value, f.canvas.canvas);
});

test("★ acquireCanvas：没有 createCanvas / 返回 null，两种都报 WX.NO_CANVAS", () => {
  const a = acquireCanvas(makeWx({ canvas: false }).wx);
  assert.equal(a.ok, false);
  assert.equal(!a.ok && a.error.code, WX_ERR.NO_CANVAS);
  const b = acquireCanvas({ createCanvas: () => null });
  assert.equal(b.ok, false);
  assert.equal(!b.ok && b.error.code, WX_ERR.NO_CANVAS);
});

test("★ probeWebgl2：取不到 webgl2 报 WX.NO_WEBGL2，而 canvas 本身仍然可用", () => {
  const fc = makeCanvas();
  const picky: WxCanvasLike = { width: 1, height: 1, getContext: (k: string) => (k === "webgl2" ? null : { tag: "2d" }) };
  const r = probeWebgl2(picky);
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.error.code, WX_ERR.NO_WEBGL2);
  // ★ 同一个 canvas 的 2d 还能取 —— 「canvas 拿到」与「能不能上 GPU」是两件事。
  assert.deepEqual(picky.getContext("2d"), { tag: "2d" });
  assert.equal(probeWebgl2(fc.canvas).ok, true);
});

test("★ readViewport：没有 getSystemInfoSync 时用画布尺寸且 pixelRatio 记 1（不是猜 2）", () => {
  const a = readViewport(makeWx({ info: false }).wx, makeCanvas(640, 480).canvas);
  assert.equal(a.ok, true);
  assert.deepEqual(a.ok && a.value, { width: 640, height: 480, pixelRatio: 1 });
  const b = readViewport(makeWx({ pixelRatio: 0 }).wx, makeCanvas().canvas);
  assert.equal(b.ok && b.value.pixelRatio, 1);
  const c = readViewport(makeWx({ width: 0, height: 0, info: false }).wx, makeCanvas(0, 0).canvas);
  assert.equal(c.ok, false);
  assert.equal(!c.ok && c.error.code, WX_ERR.BAD_VIEWPORT);
});

test("★★ 安全区：`safeArea` 的边是**位置**不是 inset，右边与下边要减（写反 = 右边多出一整块）", () => {
  // ★ wx 给的是可用矩形：`{ left: 0, right: 400, top: 40, bottom: 760 }` 意味着
  //   "上边躲 40、下边躲 40、左右不留"。把 `right: 400` 直接当 inset 用，
  //   UI 会以为右边要躲 400 像素（半个屏幕）—— 而它**不会报错**，只会缩在左半边。
  const wx = {
    getSystemInfoSync: () => ({
      windowWidth: 400,
      windowHeight: 800,
      pixelRatio: 2,
      safeArea: { left: 0, right: 400, top: 40, bottom: 760 },
    }),
  } as unknown as WxLike;
  const r = readViewport(wx, makeCanvas(800, 1600).canvas);
  assert.equal(r.ok, true);
  assert.deepEqual(r.ok && r.value.safeArea, { top: 40, right: 0, bottom: 40, left: 0 });
  // ★ 顺带钉住"没被误当成像素比"：safeArea 是 CSS 像素，不乘 dpr。
  assert.equal(r.ok && r.value.pixelRatio, 2);
});

test("★★ 安全区缺失或含 NaN 时**不给**（不给 ≠ 给一组 0）", () => {
  const noInfo = readViewport(makeWx({ info: false }).wx, makeCanvas(640, 480).canvas);
  assert.equal(noInfo.ok && noInfo.value.safeArea, undefined, "没有 getSystemInfoSync 就不知道");

  // 老基础库：有 getSystemInfoSync 但没有 safeArea
  const old = readViewport(
    { getSystemInfoSync: () => ({ windowWidth: 400, windowHeight: 800 }) } as unknown as WxLike,
    makeCanvas(800, 1600).canvas,
  );
  assert.equal(old.ok && old.value.safeArea, undefined, "缺字段不能补成 0：补了就等于「验过了」");

  // 报了但有一个数是 NaN：不拿剩下的三个去凑
  const broken = readViewport(
    {
      getSystemInfoSync: () => ({
        windowWidth: 400,
        windowHeight: 800,
        safeArea: { left: 0, right: Number.NaN, top: 40, bottom: 760 },
      }),
    } as unknown as WxLike,
    makeCanvas(800, 1600).canvas,
  );
  assert.equal(broken.ok && broken.value.safeArea, undefined);
});

// ---------------------------------------------------------------- tick

test("★★ 帧源：canvas 上有 rAF 就用它，wx 上的那个一次都不碰", () => {
  const f = makeWx({ wxRaf: true });
  const raf = pickRaf(f.wx, f.canvas.canvas);
  assert.equal(raf.ok && raf.value.from, "canvas");
  const ticks: number[] = [];
  const src = new WxTickSource(raf.ok ? raf.value : { from: "?", requestAnimationFrame: () => 0 }, () => 0);
  src.start((dt) => ticks.push(dt));
  f.canvas.pump();
  assert.equal(ticks.length, 1);
  assert.equal(f.counts.wxRaf, 0);
  assert.equal(src.id, "wx-raf:canvas");
  src.stop();
});

test("★★ 帧源：canvas 上没有 rAF 就退到 wx 上的（两条出口都要认）", () => {
  const fc = makeCanvas(100, 100, false);
  const f = makeWx({ wxRaf: true });
  const raf = pickRaf(f.wx, fc.canvas);
  assert.equal(raf.ok && raf.value.from, "wx");
  assert.equal(raf.ok && raf.value.requestAnimationFrame != null, true);
});

test("★ 帧源：两处都没有 rAF ⇒ WX.NO_SCHEDULER（不是悄悄用一个 60Hz 定时器顶上）", () => {
  const fc = makeCanvas(100, 100, false);
  const r = pickRaf(makeWx().wx, fc.canvas);
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.error.code, WX_ERR.NO_SCHEDULER);
});

test("★★ dt 由注入的时钟算，绝不读 rAF 回调参数（真机上那个参数可能是 undefined）", () => {
  const f = makeWx();
  let clock = 5000;
  const raf = pickRaf(f.wx, f.canvas.canvas);
  const src = new WxTickSource(raf.ok ? raf.value : { from: "?", requestAnimationFrame: () => 0 }, () => clock);
  const dts: number[] = [];
  src.start((dt) => dts.push(dt));
  clock += 16;
  // ★ 回调参数是**假的**（far future）：读了它的实现会算出天文数字的 dt。
  f.canvas.pump(999_999);
  assert.equal(dts.length, 1);
  assert.ok(Math.abs(dts[0]! - 0.016) < 1e-9, `dt 应为 0.016，实际 ${String(dts[0])}`);
  src.stop();
});

test("★ stop 之后 fn 不再被调用；在 fn 里 stop 也不再排下一帧", () => {
  const f = makeWx();
  const raf = pickRaf(f.wx, f.canvas.canvas);
  let n = 0;
  const src = new WxTickSource(raf.ok ? raf.value : { from: "?", requestAnimationFrame: () => 0 }, () => 0);
  src.start(() => {
    n++;
  });
  f.canvas.pump();
  assert.equal(n, 1);
  assert.equal(f.canvas.pending(), 1);
  src.stop();
  assert.equal(f.canvas.pending(), 0);
  f.canvas.pump();
  assert.equal(n, 1);

  // ★ 在回调里停：不能排下一帧（否则 stop 只是"少跑一次"）。
  const g = makeWx();
  const raf2 = pickRaf(g.wx, g.canvas.canvas);
  const src2 = new WxTickSource(raf2.ok ? raf2.value : { from: "?", requestAnimationFrame: () => 0 }, () => 0);
  let m = 0;
  src2.start(() => {
    m++;
    src2.stop();
  });
  g.canvas.pump();
  assert.equal(m, 1);
  assert.equal(g.canvas.pending(), 0);
});

// ---------------------------------------------------------------- fs

test("★★ 写→读回环：文本与二进制都逐字节回来（二进制写入前要复制，调用方复用缓冲不污染）", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  const t = await fs.writeText("save/a.json", "{\"轮\":1}");
  assert.equal(t.ok, true, t.ok ? "" : t.error.code);
  const rt = await fs.readText("/save/a.json");
  assert.equal(rt.ok && rt.value, "{\"轮\":1}");

  const buf = new Uint8Array([1, 2, 3, 255]);
  const w = await fs.writeBinary("save/a.bin", buf);
  assert.equal(w.ok, true);
  buf[0] = 99; // 调用方复用这块内存（存档缓冲池的常态）
  const rb = await fs.readBinary("save/a.bin");
  assert.equal(rb.ok, true);
  assert.deepEqual([...(rb.ok ? rb.value : [])], [1, 2, 3, 255], "写入后改原 buffer 不该改到已存的内容");
});

// ---------------------------------------------------------------- 原子写（批132）

/**
 * ★★ 为什么这一组必须存在：`fs-node` 从第一天就是「临时文件 → rename」，
 *   而 wx 后端一直是直接 `writeFileSync` 到目标路径 —— 于是同一个"存档"契约，
 *   在一个宿主上是原子的、在另一个上不是。这类差异**不会**在桌面端报错，
 *   只在"手机没电 / 用户上滑杀进程"那一刻变成半份存档。
 *
 * ★ 判据读两个观测量：**目标文件的最终内容**（旧 vs 新 vs 半个）与
 *   **临时文件有没有留下**。只断言"写成功"的话，直接写也会全绿。
 */

test("★★ 写存档走临时文件 + rename：目标是新内容，且留下的临时文件为 0", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  const w = await fs.writeText("save.json", "v2");
  assert.equal(w.ok, true, w.ok ? "" : w.error.code);
  assert.equal(mgr.calls.rename, 1, "写一次应当 rename 一次");
  assert.equal(mgr.renames[0]?.to, `${WX_USER_DATA_PATH}/save.json`);
  assert.ok(
    (mgr.renames[0]?.from ?? "").includes(".tmp-"),
    `rename 的源必须是临时文件，实际：${mgr.renames[0]?.from ?? ""}`,
  );
  const rt = await fs.readText("save.json");
  assert.equal(rt.ok && rt.value, "v2");
  const leftovers = [...mgr.files.keys()].filter((k) => k.includes(".tmp-"));
  assert.deepEqual(leftovers, [], "成功后不该留下临时文件");
});

test("★★ 写到一半失败 ⇒ 目标文件保持**旧内容**（不是半份），临时文件被清掉", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.writeText("save.json", "v1");
  mgr.failWriteOnce("writeFileSync:fail disk full");
  const w = await fs.writeText("save.json", "v2-写到一半");
  assert.equal(w.ok, false, "写失败必须如实返回错误");
  // ★ 两个观测量一起读：目标没变（旧），且没留下垃圾。
  const rt = await fs.readText("save.json");
  assert.equal(rt.ok && rt.value, "v1", "失败的写不许动到旧存档（直接写会留下半份 v2）");
  const leftovers = [...mgr.files.keys()].filter((k) => k.includes(".tmp-"));
  assert.deepEqual(leftovers, [], "失败后不许留下临时文件（list 会把它当普通文件列出来）");
});

test("★★ rename 失败（写成功了、挪不过去）⇒ 旧存档不动，临时文件清掉", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.writeText("save.json", "v1");
  mgr.failRenameOnce("renameSync:fail permission denied");
  const w = await fs.writeText("save.json", "v2");
  assert.equal(w.ok, false, "挪不过去必须如实失败");
  const rt = await fs.readText("save.json");
  assert.equal(rt.ok && rt.value, "v1", "旧存档不许丢（这是 atomicWrite 的全部意义）");
  const leftovers = [...mgr.files.keys()].filter((k) => k.includes(".tmp-"));
  assert.deepEqual(leftovers, [], "rename 失败也必须清掉临时文件");
});

test("★★ 没有 renameSync 的老基础库 ⇒ 明确报错，且**不回退**直接写", async () => {
  const mgr = makeMgr();
  mgr.dropRename();
  const fs = new WxFileSystem(mgr);
  const w = await fs.writeText("save.json", "v1");
  assert.equal(w.ok, false, "不能静默退化成非原子写");
  const msg = w.ok ? "" : w.error.message;
  assert.ok(msg.includes("renameSync"), `报错要点名缺的是什么，实际：${msg}`);
  assert.ok(msg.includes("原子"), `报错要说清后果，实际：${msg}`);
  // ★ 关键的反向断言：**一个字节都不许落盘**（落了一半正是这条要防的）。
  assert.equal(mgr.files.has(`${WX_USER_DATA_PATH}/save.json`), false, "拒绝之后不许写出东西");
});

test("★ rename 不覆盖已存在目标（某些实现）⇒ 走 unlink + rename，仍是新内容", async () => {
  const mgr = makeMgr();
  mgr.setRenameRejectsExisting(true);
  const fs = new WxFileSystem(mgr);
  const first = await fs.writeText("save.json", "v1");
  assert.equal(first.ok, true, first.ok ? "" : first.error.message);
  const second = await fs.writeText("save.json", "v2");
  assert.equal(second.ok, true, second.ok ? "" : second.error.message);
  const rt = await fs.readText("save.json");
  assert.equal(rt.ok && rt.value, "v2", "第二次必须覆盖成功（否则读档会永远读到 v1）");
});

test("★ 同一个目标写两次，临时文件名不撞（async 之间别的代码能插进来）", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  // ★ 必须写**同一个目标**才验得到序号：写两个不同目标时，临时名本身就因为
  //   目标名不同而不同 —— 那样这条判据删掉 `tmpSeq` 也照样绿（等价变异）。
  await fs.writeText("save.json", "1");
  await fs.writeText("save.json", "2");
  const froms = mgr.renames.map((r) => r.from);
  assert.equal(froms.length, 2, `应当 rename 两次，实际：${froms.join(" / ")}`);
  assert.notEqual(froms[0], froms[1], `同一个目标的两次写必须用不同临时名，实际：${froms.join(" / ")}`);
});

test("★★ list：readdirSync 只给名字 ⇒ 每个子项必须 stat 一次（类型不是猜出来的）", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.ensureDir("assets");
  await fs.writeText("assets/b.png", "B");
  await fs.writeText("assets/a.png", "A");
  await fs.writeText("assets/c.txt", "C");
  mgr.calls.stat = 0;
  const r = await fs.list("assets");
  assert.equal(r.ok, true);
  const names = r.ok ? r.value.map((e) => e.name) : [];
  // fake 的 readdirSync 故意倒序：能过说明排序是自己做的。
  assert.deepEqual(names, ["a.png", "b.png", "c.txt"]);
  assert.equal(mgr.calls.stat, 3, "三个子项 ⇒ 三次 stat（少一次就是拿名字猜类型）");
  assert.deepEqual(
    r.ok ? r.value.map((e) => e.isDirectory) : [],
    [false, false, false],
  );
});

test("★ list：目录排在文件前（不靠文件系统顺序）", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.writeText("a.txt", "x");
  await fs.ensureDir("zzz");
  const r = await fs.list("/");
  assert.deepEqual(r.ok ? r.value.map((e) => e.name) : [], ["zzz", "a.txt"]);
  assert.equal(r.ok ? r.value[0]?.isDirectory : false, true);
});

test("★ 不存在 ⇒ FS.NOT_FOUND（不返回空串、不当成空文件）", async () => {
  const fs = new WxFileSystem(makeMgr());
  const a = await fs.readText("nope.json");
  assert.equal(a.ok, false);
  assert.equal(!a.ok && a.error.code, "FS.NOT_FOUND");
  const b = await fs.readBinary("nope.bin");
  assert.equal(!b.ok && b.error.code, "FS.NOT_FOUND");
  assert.equal(await fs.exists("nope.json"), false);
});

test("★ 错误分类：权限错误不会被读成「不存在」（先判 not-exist 会让它变空文件）", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.writeText("a.json", "{}");
  mgr.failNext("readFileSync:fail permission denied, open wxfile://usr/a.json");
  const r = await fs.readText("a.json");
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.error.code, "FS.PERMISSION");
});

test("★ exists：accessSync 抛异常的实现也要当 false（两种实现都见过）", async () => {
  const mgr = makeMgr();
  mgr.setAccessThrows(true);
  const fs = new WxFileSystem(mgr);
  await fs.writeText("a.json", "{}");
  assert.equal(await fs.exists("a.json"), true);
  assert.equal(await fs.exists("b.json"), false);
});

test("★ 写文件前先建父目录（否则「第一次存档失败、第二次能成」）", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  mgr.calls.mkdir = 0;
  const w = await fs.writeText("deep/nest/s.json", "1");
  assert.equal(w.ok, true, w.ok ? "" : w.error.code);
  assert.ok(mgr.calls.mkdir > 0, "必须调过 mkdirSync");
  assert.equal(mgr.dirs.has(`${WX_USER_DATA_PATH}/deep/nest`), true);
});

test("★ 路径归一化只有一处：带不带前导斜杠是同一个文件", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.writeText("/save.json", "v1");
  const r = await fs.readText("save.json");
  assert.equal(r.ok && r.value, "v1");
  assert.equal(await fs.exists("/save.json"), true);
  const bad = await fs.readText("");
  assert.equal(!bad.ok && bad.error.code, "FS.BAD_PATH");
});

test("★ remove / ensureDir：目录走 rmdir（递归），文件走 unlink", async () => {
  const mgr = makeMgr();
  const fs = new WxFileSystem(mgr);
  await fs.writeText("d/x.json", "1");
  assert.equal((await fs.remove("d")).ok, true);
  assert.equal(mgr.calls.rmdir, 1);
  assert.equal(mgr.calls.unlink, 0);
  await fs.writeText("y.json", "1");
  assert.equal((await fs.remove("y.json")).ok, true);
  assert.equal(mgr.calls.unlink, 1);
  // ensureDir 对已存在的目录是成功（不是 EEXIST 失败）
  assert.equal((await fs.ensureDir("d")).ok, true);
  assert.equal((await fs.ensureDir("d")).ok, true);
});

test("★ 工厂：没有 getFileSystemManager ⇒ WX.NO_FS", () => {
  const r = createWxFileSystem(makeWx({ fs: false }).wx);
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.error.code, WX_ERR.NO_FS);
});

// ---------------------------------------------------------------- input

test("★★ 触摸点先换算到画布像素：少乘一个像素比 ⇒ 按哪里都不中", () => {
  const p = toCanvasPoint(
    { clientX: 325, clientY: 25 },
    { windowWidth: 500, windowHeight: 500, canvasWidth: 1000, canvasHeight: 1000 },
  );
  assert.deepEqual(p, { x: 650, y: 50 });

  const f = makeWx({ windowWidth: 500, windowHeight: 500, width: 1000, height: 1000 });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 500, windowHeight: 500, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  assert.equal(dev.ok, true);
  f.touch("start", { touches: [TOUCH_AT(1, 325, 25)] });
  const snap = dev.ok ? dev.value.poll() : null;
  assert.equal(snap?.keysDown.has("Space"), true, "按在 (650,50) 该命中右下那个按钮");
  assert.equal(snap?.pointer.x, 650);
});

test("★★ 死区：只有配到大于扇区阈值时才真的挡得住（0.2 被 tan22.5° 覆盖了）", () => {
  // ★ 这条判据的形状值得记：0.2 的死区**天然被方向阈值覆盖** —— 半径 0.2 以内
  //   的任何一个点，两个轴的分量都不超过 0.2 < 0.414，本来就出不来方向键。
  //   所以"中心没键"这个断言对"死区有没有实现"**没有分辨力**（第一版就是这里假绿）。
  //   能分辨的是「配一个大死区：同一个点，0.2 时有键、0.5 时没键」。
  const p = { x: 200, y: 290 }; // ny = 0.45：过得了 tan22.5°，但只有 0.45 半径
  assert.deepEqual(hitTestPad(PAD, p.x, p.y), ["KeyS"], "默认死区 0.2 挡不住它");
  assert.deepEqual(hitTestPad({ ...PAD, deadZone: 0.5 }, p.x, p.y), [], "死区 0.5 必须挡住");
  assert.deepEqual(hitTestPad(PAD, 360, 200), ["KeyD"], "往外推要出方向键");
});

test("★★ 斜向同时发两个键（否则斜走要「先按上再按右」凑）", () => {
  // nx = ny = 0.6：仍在圆内（0.85 < 1），且两个轴都过了 tan(22.5°) 的门槛。
  const keys = hitTestPad(PAD, 320, 320);
  assert.deepEqual([...keys].sort(), ["KeyD", "KeyS"]);
});

test("★★ 摇杆是圆不是方：矩形角落不算命中（方框的角离中心最远、按下去没反应）", () => {
  const corner = hitTestPad(PAD, 398, 398);
  assert.deepEqual(corner, [], "角落应当在圆外");
  // 同一距离的轴向点上必须命中 —— 证明拒绝的是「角」而不是「远」。
  assert.deepEqual(hitTestPad(PAD, 200, 398), ["KeyS"]);
});

test("★★ 按钮重叠时只听第一个（同时触发两个动作 = 按一下砍树也存了档）", () => {
  const pad: VirtualPad = {
    dpad: { x: 0, y: 0, w: 0, h: 0 },
    deadZone: 0.2,
    buttons: [
      { key: "KeyG", rect: { x: 0, y: 0, w: 100, h: 100 } },
      { key: "KeyH", rect: { x: 50, y: 50, w: 100, h: 100 } },
    ],
  };
  assert.deepEqual(hitTestPad(pad, 60, 60), ["KeyG"]);
});

test("★★ 多指：左手摇杆 + 右手按钮取并集；抬起一根另一根还在", () => {
  const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  assert.equal(dev.ok, true);
  const d = dev.ok ? dev.value : null;
  f.touch("start", { touches: [TOUCH_AT(1, 100, 100), TOUCH_AT(2, 650, 50)] });
  const s1 = d?.poll();
  assert.deepEqual([...(s1?.keysDown ?? [])].sort(), ["KeyA", "KeyW", "Space"]);
  assert.equal(s1?.pointer.down, true);
  assert.equal(s1?.pointer.pressed, true);

  // 抬起按钮那根：按钮键消失，摇杆键还在
  f.touch("end", { touches: [TOUCH_AT(1, 100, 100)], changedTouches: [TOUCH_AT(2, 650, 50)] });
  const s2 = d?.poll();
  assert.deepEqual([...(s2?.keysDown ?? [])].sort(), ["KeyA", "KeyW"]);
  assert.deepEqual([...(s2?.keysReleased ?? [])], ["Space"]);
  assert.equal(s2?.pointer.pressed, false, "指针没重新按下");

  // 全部抬起
  f.touch("end", { touches: [], changedTouches: [TOUCH_AT(1, 100, 100)] });
  const s3 = d?.poll();
  assert.equal(s3?.keysDown.size, 0);
  assert.equal(s3?.pointer.down, false);
  assert.equal(s3?.pointer.released, true);
  assert.deepEqual([...(s3?.keysReleased ?? [])].sort(), ["KeyA", "KeyW"]);
});

test("★★ 边缘语义：pressed/released 只在一次 poll 里可见（与 input-null / input-dom 一致）", () => {
  const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  const d = dev.ok ? dev.value : null;
  f.touch("start", { touches: [TOUCH_AT(1, 360, 200)] });
  assert.equal(d?.poll().keysPressed.has("KeyD"), true);
  assert.equal(d?.poll().keysPressed.has("KeyD"), false, "第二次 poll 不该再报按下");
  f.touch("end", { touches: [], changedTouches: [TOUCH_AT(1, 360, 200)] });
  assert.equal(d?.poll().keysReleased.has("KeyD"), true);
  assert.equal(d?.poll().keysReleased.has("KeyD"), false);
});

test("★ 只给 changedTouches（不给 touches 全量）的老实现也能跑", () => {
  const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  const d = dev.ok ? dev.value : null;
  f.touch("start", { changedTouches: [TOUCH_AT(7, 360, 200)] });
  assert.equal(d?.poll().keysDown.has("KeyD"), true);
  f.touch("end", { changedTouches: [TOUCH_AT(7, 360, 200)] });
  assert.equal(d?.poll().keysDown.size, 0);
});

test("★★ touchcancel 与 touchend 同口径：拖出屏幕不许卡住输入（两条输入路径都验）", () => {
  // 真机上的形状：按住摇杆往屏幕外拖、在别的 App 里松手 —— 回来的不是 touchend 而是
  // touchcancel。`feed()` 把 cancel 与 end 同样对待（input.ts 的增量分支），但在这条判据
  // 之前**没有任何一条判据喂过 cancel**：把那半个条件删掉，43 条输入判据全绿。
  //
  // ★ 为什么非要在**增量路径**上验一次：全量 `touches` 那条路下 cancel 靠"列表空了"自然
  //   清掉，删掉 `phase === "cancel"` 它照样绿 —— 那条路对这件事**没有分辨力**。
  const mk = () => {
    const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
    const dev = createWxInput(f.wx, {
      space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
      pad: PAD,
    });
    return { f, d: dev.ok ? dev.value : null };
  };

  // ① 全量路径：cancel 时 touches 已经是空列表
  const a = mk();
  a.f.touch("start", { touches: [TOUCH_AT(1, 360, 200)] });
  assert.equal(a.d?.poll().keysDown.has("KeyD"), true, "前提：先真的按上了");
  a.f.touch("cancel", { touches: [] });
  const sa = a.d?.poll();
  assert.equal(sa?.keysDown.size, 0, "cancel 之后不许还按着");
  assert.deepEqual([...(sa?.keysReleased ?? [])], ["KeyD"], "松开要作为一次「抬起」报出去");

  // ② 增量路径：只给 changedTouches —— 只有这条能分辨 cancel 有没有被当成抬起
  const b = mk();
  b.f.touch("start", { changedTouches: [TOUCH_AT(9, 360, 200)] });
  assert.equal(b.d?.poll().keysDown.has("KeyD"), true, "前提：先真的按上了");
  b.f.touch("cancel", { changedTouches: [TOUCH_AT(9, 360, 200)] });
  const sb = b.d?.poll();
  assert.equal(sb?.keysDown.size, 0, "cancel 必须清点：否则手指早就松了、角色还在往右走");
  assert.deepEqual([...(sb?.keysReleased ?? [])], ["KeyD"]);
  assert.equal(sb?.pointer.down, false, "指针也得松开（否则拖拽状态永远结束不了）");
});

test("★ 没有 onTouch* ⇒ WX.NO_TOUCH（没有输入源就别装作能玩）", () => {
  const r = createWxInput(makeWx({ touch: false }).wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
  });
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.error.code, WX_ERR.NO_TOUCH);
});

test("★★ destroy 之后回调不再改状态；有 off* 时必须真的退订", () => {
  const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  const d = dev.ok ? dev.value : null;
  const subsBefore = f.counts.subs;
  assert.equal(subsBefore, 4, "四个触摸事件各订一次");
  d?.destroy();
  assert.equal(f.counts.offs, 4, "四个都要退订");
  f.touch("start", { touches: [TOUCH_AT(1, 360, 200)] });
  assert.equal(d?.poll().keysDown.size, 0);
  assert.equal(d?.subscribe(() => {}) instanceof Function, true);
});

test("★★ 实现没有 off* 时，destroy 只能靠 dead 标记挡住后续回调（不许默认「应该不会再来」）", () => {
  // ★ 这一条是被变异逼出来的：只有「退订成功」这一条路时，`dead = true` 删掉也没人红
  //   （四条 off* 已经把回调撤干净了 —— 等价变异）。真实的老版本 wx 可能没有 off*，
  //   那时回调还会来，唯一的防线就是 dead。
  const f = makeWx({
    windowWidth: 1000,
    windowHeight: 1000,
    width: 1000,
    height: 1000,
    pixelRatio: 1,
    off: false,
  });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  const d = dev.ok ? dev.value : null;
  assert.equal(f.counts.subs, 4);
  d?.destroy();
  assert.equal(f.counts.offs, 0, "本来就没有 off* 可调");
  f.touch("start", { touches: [TOUCH_AT(1, 360, 200)] });
  assert.equal(d?.poll().keysDown.size, 0, "回调照旧会来，但状态不能再变");
});

test("★ reset 清空所有按下状态（切后台回来「W 一直按着」是真实 bug）", () => {
  const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
  const dev = createWxInput(f.wx, {
    space: { windowWidth: 1000, windowHeight: 1000, canvasWidth: 1000, canvasHeight: 1000 },
    pad: PAD,
  });
  const d = dev.ok ? dev.value : null;
  f.touch("start", { touches: [TOUCH_AT(1, 360, 200)] });
  assert.equal(d?.poll().keysDown.size, 1);
  d?.reset();
  const s = d?.poll();
  assert.equal(s?.keysDown.size, 0);
  assert.equal(s?.pointer.down, false);
});

// ---------------------------------------------------------------- 组装

test("★★ createWxHost：假 wx 装出完整宿主，帧源真的驱动、存档真的读写、按键真的出来", async () => {
  const f = makeWx({ windowWidth: 1000, windowHeight: 1000, width: 1000, height: 1000, pixelRatio: 1 });
  let clock = 0;
  const host = createWxHost(f.wx, { now: () => clock, pad: PAD });
  assert.equal(host.ok, true, host.ok ? "" : `${host.error.code}：${host.error.message}`);
  if (!host.ok) return;
  assert.equal(host.value.viewport.width, 1000);

  let frames = 0;
  host.value.tick.start(() => {
    frames++;
  });
  clock = 16;
  f.canvas.pump();
  assert.equal(frames, 1);
  host.value.tick.stop();

  const w = await host.value.fs.writeText("save.json", "hp=3");
  assert.equal(w.ok, true);
  assert.equal((await host.value.fs.readText("save.json")).ok, true);

  f.touch("start", { touches: [TOUCH_AT(1, 100, 100)] });
  assert.equal(host.value.input.poll().keysDown.has("KeyW"), true);
  host.value.input.destroy();
});

test("★★ createWxHost：任何一环缺失就整体失败（不留半截宿主）", () => {
  const noCanvas = createWxHost(makeWx({ canvas: false }).wx);
  assert.equal(!noCanvas.ok && noCanvas.error.code, WX_ERR.NO_CANVAS);
  const noTouch = createWxHost(makeWx({ touch: false }).wx);
  assert.equal(!noTouch.ok && noTouch.error.code, WX_ERR.NO_TOUCH);
  const noFs = createWxHost(makeWx({ fs: false }).wx);
  assert.equal(!noFs.ok && noFs.error.code, WX_ERR.NO_FS);
  const noRaf = createWxHost(makeWx({ wxRaf: false, width: 100, height: 100 }).wx);
  // canvas 上还有 rAF ⇒ 这条应当成功；换成两端都没有才失败。
  assert.equal(noRaf.ok, true);
});

test("★ 默认键位与分辨率成比例：短边变了布局跟着变，且不互相重叠", () => {
  const small = makeDefaultPad(640, 360);
  const big = makeDefaultPad(1920, 1080);
  assert.ok(small.dpad.w < big.dpad.w);
  const ratio = big.dpad.w / big.buttons[0]!.rect.w;
  assert.ok(Math.abs(ratio - small.dpad.w / small.buttons[0]!.rect.w) < 1e-9, "比例必须一致");
  for (const b of big.buttons) {
    const overlapX = b.rect.x < big.dpad.x + big.dpad.w && b.rect.x + b.rect.w > big.dpad.x;
    const overlapY = b.rect.y < big.dpad.y + big.dpad.h && b.rect.y + b.rect.h > big.dpad.y;
    assert.equal(overlapX && overlapY, false, `按钮 ${b.key} 与摇杆重叠了`);
  }
});

// ---------------------------------------------------------------- 自指闸门

/** 剥掉注释（保留行号）：注释里点名那些 API 是必须的，判据只看代码。 */
function stripComments(src: string): string {
  let out = "";
  let i = 0;
  let mode: "code" | "line" | "block" = "code";
  while (i < src.length) {
    const c = src[i]!;
    const n = src[i + 1];
    if (mode === "code") {
      if (c === "/" && n === "/") {
        mode = "line";
        out += "  ";
        i += 2;
        continue;
      }
      if (c === "/" && n === "*") {
        mode = "block";
        out += "  ";
        i += 2;
        continue;
      }
      out += c;
      i++;
      continue;
    }
    if (mode === "line") {
      if (c === "\n") {
        mode = "code";
        out += "\n";
      } else out += " ";
      i++;
      continue;
    }
    if (c === "*" && n === "/") {
      mode = "code";
      out += "  ";
      i += 2;
      continue;
    }
    out += c === "\n" ? "\n" : " ";
    i++;
  }
  return out;
}

test("★ 剥注释器自检：注释里写了禁用的 API、代码里没有 ⇒ 0 命中（否则自指闸门是假的）", () => {
  const sample = [
    "// 这里说的是 document.createElement 与 window.setTimeout",
    "/* localStorage 与 eval( 也只是被点名 */",
    "const a = 1;",
  ].join("\n");
  const stripped = stripComments(sample);
  assert.equal(stripped.includes("document."), false);
  assert.equal(scanMiniGameSource(stripped).length, 0);
  // 反向：代码里真写了就必须被抓到（证明剥注释没有把代码一起吃掉）。
  assert.ok(scanMiniGameSource("const x = document.getElementById('a');").length > 0);
  assert.ok(scanMiniGameSource(stripComments("const x = window.foo;")).length > 0);
});

test("★★ 自指闸门：src/host/wx/*.ts 的**代码**里零 FORBIDDEN_IN_MINIGAME 命中", () => {
  const files = readdirSync(WX_DIR).filter((f) => f.endsWith(".ts"));
  assert.ok(files.length >= 5, `只扫到 ${files.length} 个文件 —— 目录或过滤坏了`);
  const hits: string[] = [];
  let lines = 0;
  for (const f of files) {
    const src = readFileSync(join(WX_DIR, f), "utf8");
    lines += src.split("\n").length;
    for (const h of scanMiniGameSource(stripComments(src))) hits.push(`${f}:${h.line} ${h.api}`);
  }
  assert.ok(lines > 300, `总行数只有 ${lines} —— 扫的东西不对`);
  assert.deepEqual(hits, [], `适配层自己用了小游戏里没有的 API：\n  ${hits.join("\n  ")}`);
  // ★ 反向：清单真的非空（否则上面那条恒绿）。
  assert.ok(FORBIDDEN_IN_MINIGAME.length >= 5);
});

test("★★ 自指闸门（批128）：装配与小游戏入口里也零命中 —— 搬出入口不等于搬出闸门", () => {
  // ★ 为什么必须单独一条：批128 把 3000 行装配从 `browser-entry.ts` 搬到了
  //   `host/demo-game.ts`，而上面那条只扫 `host/wx/*.ts`。
  //   于是「装配里出现一个 `document.`」会有整整一批判据看不见它：
  //   Node 判据全绿（wx 那条用假 wx，`document` 压根不会被访问），
  //   要到真机白屏才发现。闸门必须跟着**代码搬家**，不是跟着目录名走。
  const files = ["src/host/demo-game.ts", "src/wx-entry.ts", "src/wx-boot.ts"];
  const hits: string[] = [];
  let lines = 0;
  for (const rel of files) {
    const abs = join(ROOT, rel);
    assert.equal(existsSync(abs), true, `文件不见了：${rel}（路径漂移会让这条判据扫 0 行也绿）`);
    const src = readFileSync(abs, "utf8");
    lines += src.split("\n").length;
    // ★ 不再自己剥一遍注释：`scanMiniGameSource` 内部已经剥了（批128），
    //   而这里的 `stripComments` 不认字符串字面量 —— 二次剥会把 `"http://…"` 之后的内容吃掉，
    //   那会**少报**命中（假绿）。一处真相就够。
    for (const h of scanMiniGameSource(src)) hits.push(`${rel}:${h.line} ${h.api}`);
  }
  assert.ok(lines > 2500, `总行数只有 ${lines} —— 三个文件加起来不该这么少（装配约 3000 行）`);
  assert.deepEqual(hits, [], `宿主无关的代码里用了小游戏没有的 API：\n  ${hits.join("\n  ")}`);
});
