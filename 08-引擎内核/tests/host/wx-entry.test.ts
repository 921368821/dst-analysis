/**
 * 小游戏入口：假 wx 装出**真的一局**
 *
 * 这一批要回答的问题不是"wx 适配层的函数对不对"（`wx.test.ts` 的 37 条已经在管），
 * 而是：**把那个适配层接到装配上之后，游戏真的跑起来了吗**。两者的区别很具体：
 *
 *   · 适配层绿 + 入口没接 ⇒ 触摸能翻译成 `KeyW`，而平台里跑的是 `input-null`；
 *   · 入口绿 + 装配还在读 DOM ⇒ 在 Node 里跑得通，在真机上白屏。
 *
 * 所以下面每条都读**平台与世界的观测量**（`platform.backends` / 玩家坐标 / 存档文件），
 * 不读"我调过哪个函数"。
 *
 * ★ 假 wx 刻意不复用 `wx.test.ts` 里那一个：那个是"验 wx 层单件"的最小夹具
 *   （画布不带 GL、文件系统全在内存）。这里的盘要能**透传真资产**（否则装配一开机
 *   就降级到程序化图集，UI 建不起来），目标不同、形状也就不同。
 *   两处共用同一份夹具的结果会是"为了一个目标加参数，另一个目标跟着抖"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync as readdirNode } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { startWxGame } from "../../src/wx-entry.ts";
import type { WxCanvasLike, WxLike, WxTouchEventLike, WxTouchHandler } from "../../src/host/wx/env.ts";
import type { VirtualPad } from "../../src/host/wx/input.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const ASSETS = join(ROOT, "web", "assets");

/** 判据用的键位：摇杆在左上 200×200，动作键在 (300,300) 起 100×100。坐标都是 canvas 像素。 */
const PAD: VirtualPad = {
  dpad: { x: 0, y: 0, w: 200, h: 200 },
  deadZone: 0.2,
  buttons: [{ key: "Space", rect: { x: 300, y: 300, w: 100, h: 100 } }],
};

interface FakeFsOptions {
  /** false = 读不到 `ui-*`（验"HUD 没有兜底"那条降级语义）。 */
  readonly allowUi?: boolean;
  /** false = 读不到任何资产（验启动失败要能说清原因）。 */
  readonly allowAssets?: boolean;
}

function toArrayBuffer(u8: Uint8Array): ArrayBuffer {
  return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
}

/** 内存盘 + 对 `assets/` 前缀透传到真资产目录（小游戏包里就是这些字节）。 */
function makeMgr(o: FakeFsOptions = {}) {
  const files = new Map<string, Uint8Array>();
  const dirs = new Set<string>(["wxfile://", "wxfile://usr"]);
  const calls = { read: 0, write: 0, missed: [] as string[] };
  const notFound = (p: string): never => {
    calls.missed.push(p);
    throw { errMsg: `readFileSync:fail no such file or directory ${p}` };
  };
  const parentOf = (p: string): string => {
    const at = p.lastIndexOf("/");
    return at <= 0 ? "" : p.slice(0, at);
  };
  /**
   * 包内资产 → 真文件。
   *
   * ★ 路径形状是**两段**：装配读资产时用的是裸文件名（`ui-font.fnt`，因为根是空串），
   *   而导入管线扫目录时用的是 `assets`。第一版只认 `assets/` 前缀，
   *   于是"能扫到目录、每个文件都 404" —— 而它表现出来的只是 HUD 起不来。
   */
  const assetName = (p: string): string | null => {
    if (o.allowAssets === false) return null;
    // 用户目录（存档位）不透明到包内：`wxfile://usr/x` 与包里的 `assets/x` 无关
    if (p.startsWith("wxfile://")) return null;
    const n = p.replace(/^\/?assets\//, "").replace(/^\/+/, "");
    if (n.length === 0 || n.includes("..")) return null;
    if (o.allowUi === false && n.startsWith("ui-")) return null;
    return n;
  };
  const readAsset = (p: string): Uint8Array | null => {
    const name = assetName(p);
    if (name === null) return null;
    const abs = join(ASSETS, name);
    return existsSync(abs) ? new Uint8Array(readFileSync(abs)) : null;
  };
  const assetDir = (p: string): string[] | null => {
    const n = p.replace(/^\/+/, "").replace(/\/+$/, "");
    if (n !== "" && n !== "assets") return null;
    if (o.allowAssets === false) return null;
    const all = readdirNode(ASSETS, { withFileTypes: true }).filter((e) => e.isFile()).map((e) => e.name);
    return o.allowUi === false ? all.filter((x) => !x.startsWith("ui-")) : all;
  };
  const mgr = {
    readFileSync(p: string, encoding?: string): string | ArrayBuffer {
      calls.read++;
      const hit = files.get(p) ?? readAsset(p);
      if (hit === null || hit === undefined) return notFound(p);
      return encoding === "utf8" ? Buffer.from(hit).toString("utf8") : toArrayBuffer(hit);
    },
    writeFileSync(p: string, data: string | ArrayBuffer): void {
      calls.write++;
      files.set(p, typeof data === "string" ? new Uint8Array(Buffer.from(data, "utf8")) : new Uint8Array(data));
      const par = parentOf(p);
      if (par.length > 0) dirs.add(par);
    },
    readdirSync(p: string): string[] {
      const prefix = p.endsWith("/") ? p : `${p}/`;
      const out = new Set<string>();
      for (const f of files.keys()) {
        if (f.startsWith(prefix)) {
          const rest = f.slice(prefix.length);
          out.add(rest.includes("/") ? (rest.split("/")[0] as string) : rest);
        }
      }
      for (const n of assetDir(p) ?? []) out.add(n);
      if (out.size === 0) notFound(p);
      return [...out];
    },
    statSync(p: string) {
      const f = files.get(p);
      if (f !== undefined) return { size: f.byteLength, isFile: () => true, isDirectory: () => false };
      if (dirs.has(p)) return { size: 0, isFile: () => false, isDirectory: () => true };
      // 资产目录（`assets`）与资产文件都要能 stat：导入管线会两者都问
      const kids = assetDir(p);
      if (kids !== null) return { size: kids.length, isFile: () => false, isDirectory: () => true };
      const a = readAsset(p);
      if (a !== null) return { size: a.byteLength, isFile: () => true, isDirectory: () => false };
      return notFound(p);
    },
    mkdirSync(p: string): void {
      dirs.add(p);
    },
    unlinkSync(p: string): void {
      files.delete(p);
    },
    rmdirSync(p: string): void {
      for (const f of [...files.keys()]) if (f.startsWith(`${p}/`)) files.delete(f);
      dirs.delete(p);
    },
    accessSync(p: string): boolean {
      return files.has(p) || dirs.has(p) || readAsset(p) !== null || assetDir(p) !== null;
    },
  };
  return { mgr, files, dirs, calls };
}

interface FakeWx {
  readonly wx: WxLike;
  readonly mgr: ReturnType<typeof makeMgr>;
  /** 把画布上排队的那一帧回调跑掉（帧源就是这么被驱动的）。 */
  frame(): void;
  touch(kind: "start" | "move" | "end", ev: WxTouchEventLike): void;
}

function makeWx(o: FakeFsOptions & { touch?: boolean; fs?: boolean } = {}): FakeWx {
  const queue: (() => void)[] = [];
  const canvas: WxCanvasLike = {
    width: 1000,
    height: 1000,
    // ★ 没有 GL：判据用 `gfx: "null"`。带一个假 GL 会让"图形后端到底有没有接上"
    //   变成"我造的假对象像不像 GL"，而那件事在浏览器自检里有真证据。
    getContext: (kind: string) => (kind === "webgl2" ? null : { tag: "2d" }),
    requestAnimationFrame: (cb: () => void) => {
      queue.push(cb);
      return queue.length;
    },
    cancelAnimationFrame: () => undefined,
  };
  const mgr = makeMgr(o);
  const handlers = new Map<string, Set<WxTouchHandler>>();
  const wx: Record<string, unknown> = {
    createCanvas: () => canvas,
    // 窗口与画布 1:1（pixelRatio 1），判据给的 pad 坐标就是触摸坐标
    getSystemInfoSync: () => ({ windowWidth: 1000, windowHeight: 1000, pixelRatio: 1 }),
    requestAnimationFrame: (cb: () => void) => {
      queue.push(cb);
      return queue.length;
    },
    cancelAnimationFrame: () => undefined,
    ...(o.fs === false ? {} : { getFileSystemManager: () => mgr.mgr }),
    showToast: () => undefined,
  };
  if (o.touch !== false) {
    for (const kind of ["Start", "Move", "End", "Cancel"]) {
      wx[`onTouch${kind}`] = (cb: WxTouchHandler) => {
        const set = handlers.get(kind) ?? new Set<WxTouchHandler>();
        set.add(cb);
        handlers.set(kind, set);
      };
    }
  }
  return {
    wx: wx as WxLike,
    mgr,
    frame: () => {
      const cbs = queue.splice(0, queue.length);
      for (const cb of cbs) cb();
    },
    touch: (kind, ev) => {
      const key = `${kind[0]!.toUpperCase()}${kind.slice(1)}`;
      for (const cb of handlers.get(key) ?? []) cb(ev);
    },
  };
}

/** 一个可以拨的时钟（帧源的 dt 用它算，不拨就永远是 0 ⇒ 一个 tick 都不跑）。 */
function makeClock(): { now(): number; advance(ms: number): void } {
  let t = 1_000;
  return {
    now: () => t,
    advance: (ms) => {
      t += ms;
    },
  };
}

test("★★★ 假 wx 装出一整局：平台是 wx、世界有东西、帧源真的在推进", async () => {
  const f = makeWx();
  const clock = makeClock();
  const handle = await startWxGame(f.wx, { gfx: "null", pad: PAD, now: clock.now });

  const snap = handle.app.snapshot();
  assert.equal(snap.platformId, "wx", "平台标识要是 wx（走错入口时一眼可见）");
  assert.equal(snap.tick, 0, "刚装好还没跑帧");
  assert.ok(handle.scene !== null, "场景要建起来");

  // 推两帧（每帧 1/30 秒）⇒ 固定步长调度器该跑出 tick
  for (let i = 0; i < 2; i++) {
    clock.advance(34);
    f.frame();
  }
  assert.ok(handle.app.snapshot().tick > 0, "帧源没接上：推了两帧 tick 还是 0");

  handle.app.stopRun();
});

test("★★★ 触摸真的接到了平台：不是「翻译成了 KeyW」而是「玩家真的动了」", async () => {
  const f = makeWx();
  const clock = makeClock();
  const handle = await startWxGame(f.wx, { gfx: "null", pad: PAD, now: clock.now });

  // ★ 先读平台自己认的后端。期望值是 `wx` 而**不是** `injected` —— 这一对名字
  //   正好是这条判据的要点：`backends.input` 报的是**设备自述的 `caps.backend`**，
  //   不是注册表里的通道 id。注入通道（`injected`）只是个搬运工，它把宿主那个
  //   触摸设备原样交出去，所以自述仍是 `wx`。
  //   ⇒ 这里断 `wx` 就在断"平台拿到的**是宿主造的那个设备**"；断成 `injected`
  //     是把通道名当设备名，会一直红；而只断"不等于 null"又太松（见下）。
  const inputId = handle.app.platform.backends.input;
  assert.notEqual(inputId, "null", "平台退回了 input-null —— 触摸一个字节都收不到");
  assert.equal(inputId, "wx", `平台选中的输入设备自述不是 wx 触摸设备（实际 ${inputId}）`);
  // ★ 两条一起看才排得掉"标志位对了、效果没发生"：上面验选中的是**触摸**设备，
  //   下面验这个设备自己声明支持触摸（`input-null` 会说 false）。
  assert.equal(handle.app.platform.input.caps.touch, true, "选中的设备没有声明 touch 能力（那是 key 设备）");

  const heroId = handle.heroId as number;
  assert.ok(heroId >= 0, "没有玩家节点");
  const scene = handle.scene as { find(id: number): { worldPosition: { x: number; y: number } } | undefined };
  const before = scene.find(heroId)?.worldPosition.y ?? 0;

  // 按住摇杆上半部分（中心 100,100 → 按到 100,20 ⇒ 向上）
  f.touch("start", { touches: [{ identifier: 1, clientX: 100, clientY: 20 }] });
  for (let i = 0; i < 12; i++) {
    clock.advance(34);
    f.frame();
  }
  f.touch("end", { touches: [], changedTouches: [{ identifier: 1, clientX: 100, clientY: 20 }] });

  const after = scene.find(heroId)?.worldPosition.y ?? 0;
  // ★ 断言"变了"而不是"变了多少"：距离由控制器加速度/碰撞决定，
  //   写死一个数会让这条判据在调手感时变红（那是另一件事）。
  assert.notEqual(after, before, `玩家没动（y ${String(before)} → ${String(after)}）—— 触摸没进平台`);
  handle.app.stopRun();
});

test("★★ 存档真的落到 wx 的文件系统（不是落在内存里的另一个实例）", async () => {
  const f = makeWx();
  const clock = makeClock();
  const handle = await startWxGame(f.wx, { gfx: "null", pad: PAD, now: clock.now });

  const r = (await handle.save()) as { ok: boolean };
  assert.equal(r.ok, true, "存档该成功");
  // ★ 读**假 manager 的文件表**，不读 `handle` 里的任何计数：
  //   "我调用过 write" 与 "文件真的在那里" 是两件事。
  const path = "wxfile://usr/saves/slot1.json";
  assert.equal(f.mgr.files.has(path), true, `没写出 ${path}（写到了哪？${[...f.mgr.files.keys()].join(", ") || "空"}`);
  const text = Buffer.from(f.mgr.files.get(path) ?? new Uint8Array()).toString("utf8");
  assert.ok(text.includes("\"nodes\""), "存档内容不像场景快照");
  handle.app.stopRun();
});

test("★★ HUD 降级语义：小游戏没有 DOM 兜底，UI 资产读不到就必须**起不来**", async () => {
  // ★ 这条钉的是文件头那张表的第三行。它与"能起得来"是**一对**：
  //   只验能起来 ⇒ 资产缺失时会静默变成"起来了但什么都看不见"；
  //   只验起不来 ⇒ 一个永远起不来的入口也满足。
  const f = makeWx({ allowUi: false });
  await assert.rejects(
    () => startWxGame(f.wx, { gfx: "null", pad: PAD, now: makeClock().now }),
    (e: unknown) => {
      const msg = e instanceof Error ? e.message : String(e);
      return msg.includes("DEMO.NO_VISIBLE_HUD");
    },
    "UI 读不到时该在启动那一刻失败，而不是起来之后一片空白",
  );
});

test("★★ 不留半个宿主：缺触摸 / 缺文件系统都是启动即失败，且点名是哪一环", async () => {
  const noTouch = makeWx({ touch: false });
  await assert.rejects(
    () => startWxGame(noTouch.wx, { gfx: "null", pad: PAD, now: makeClock().now }),
    (e: unknown) => (e instanceof Error ? e.message : "").includes("WX.NO_TOUCH"),
  );
  const noFs = makeWx({ fs: false });
  await assert.rejects(
    () => startWxGame(noFs.wx, { gfx: "null", pad: PAD, now: makeClock().now }),
    (e: unknown) => (e instanceof Error ? e.message : "").includes("WX.NO_FS"),
  );
});

test("★★ 默认 gfx=webgl2 在没有 GL 的环境里必须启动失败（strict 的 gfx 项真的拦住了降级）", async () => {
  // ★ 这条防的是"黑屏但一切计数正常"：`prefer.webgl2` 探测失败后，注册表默认
  //   会**继续往下挑**，而 `null` 图形后端永远可用 —— 于是游戏起得来、tick 在走、
  //   存档能写、日志全绿，屏幕上什么都没有。`strict` 里少写一项就是这个结局。
  // ★ 它与上面那几条**不重复**：那几条都传 `gfx: "null"`（明确要 null），
  //   走的是 prefer 分支；这条走的是"prefer 失败 ⇒ 想回退 ⇒ 被 strict 挡住"。
  const f = makeWx();
  await assert.rejects(
    () => startWxGame(f.wx, { pad: PAD, now: makeClock().now }),
    (e: unknown) => {
      const msg = e instanceof Error ? e.message : String(e);
      return msg.includes("BACKEND.UNAVAILABLE");
    },
    "没有 GL 时该启动即失败，而不是悄悄换成 null 图形后端（后者 = 黑屏）",
  );
});

test("★ 没有全局 wx 时 `main` 报 WX.NO_GLOBAL（不静默什么都不做）", async () => {
  const mod = await import("../../src/wx-entry.ts");
  const g = globalThis as { wx?: unknown };
  const had = "wx" in g;
  const old = g.wx;
  delete g.wx;
  try {
    await assert.rejects(
      () => mod.main(),
      (e: unknown) => (e instanceof Error ? e.message : "").includes("WX.NO_GLOBAL"),
    );
  } finally {
    if (had) g.wx = old;
  }
});
