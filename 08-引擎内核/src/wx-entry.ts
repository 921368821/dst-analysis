/**
 * 小游戏（wx）宿主入口（L6 · 组合根 · 薄壳）
 *
 * 与 `browser-entry.ts` 同构：**把 wx 世界翻译成 `DemoHostEnv`**，装配本身在
 * `host/demo-game.ts`。两者唯一的区别是"四件套从哪来"：
 *
 *   | | 浏览器 | 小游戏 |
 *   |---|---|---|
 *   | 画布 | `document.getElementById("cv")` | `wx.createCanvas()` |
 *   | 视口 | `clientWidth × devicePixelRatio`（上限 2） | `wx.getSystemInfoSync()` |
 *   | 帧源 | 全局 `requestAnimationFrame` | `canvas.requestAnimationFrame`（老版本在 `wx` 上） |
 *   | 输入 | DOM 键盘/指针 | 触摸 → 逻辑键（`host/wx/input.ts`） |
 *   | 存档 | `localStorage` 后端 | `wx.getFileSystemManager()` |
 *   | 资产 | `?pack=` 或直读 `web/assets` | 包内相对路径（根为空串） |
 *   | HUD 兜底 | `#hud` 一行 DOM 文本 | **没有** —— 只能靠引擎 UI 树 |
 *
 * ★★ 最后一行是这一批最重要的一条决定，也是"卡在架构"的具体形状：
 *   HUD 的降级链本来有三级（UI 树 → DOM 一行 → 无），小游戏把中间那级抽掉了。
 *   所以**资产读不到时它必须起不来**（`DEMO.NO_VISIBLE_HUD`），而不是"起来了但什么都看不见"。
 *   这条不是保守，是"不留半个宿主"的直接推论：一个能跑但看不见的游戏，
 *   排查要从渲染、UI、资产三条线各查一遍，而失败信息在启动那一刻本来是拿得到的。
 *
 * ★ 这里允许 import 具体后端（组合根）。`src/host/wx/*.ts` 不允许 —— 那边有自指闸门扫。
 */

import { ok } from "./foundation/result.ts";
import { MemoryFileSystem } from "./backends/fs-memory/fs.ts";
import { registerNullBackends } from "./backends/index.ts";
import { webgl2Backend } from "./backends/gfx-webgl2/device.ts";
import { INJECTED_INPUT_ID, injectedInputBackend } from "./backends/input-injected/device.ts";
import { BackendRegistry } from "./platform/registry.ts";
import { createWxFileSystem } from "./host/wx/fs.ts";
import { createWxHost } from "./host/wx/index.ts";
import type { VirtualPad } from "./host/wx/input.ts";
import type { WxLike } from "./host/wx/env.ts";
import { WX_ERR } from "./host/wx/env.ts";
import {
  buildDemoGame,
  type DemoAssets,
  type DemoHandle,
  type DemoHostEnv,
  type DemoSurface,
} from "./host/demo-game.ts";

export interface WxGameOptions {
  /** 存档根（默认 `wxfile://usr`，与 `createWxHost` 同口径）。 */
  readonly saveRoot?: string;
  /**
   * 资产根。默认 `""`（包根），于是 `/assets/tree.png` 落到包内的 `assets/tree.png`。
   *
   * ★ 单独一个（而不是复用存档那个 fs）：小游戏的**包内文件只读**、**用户目录可写**，
   *   两者根不同。用同一个实例读资产，症状是"真机上资产全读不到、模拟器上正常"。
   */
  readonly assetRoot?: string;
  /**
   * 图形后端。默认 `webgl2`；判据传 `null`（Node 里没有 GL 上下文）。
   *
   * ★ 这是**入口**的决定，不是适配层的：`host/wx/index.ts` 的注释早就写了
   *   「图形后端要不要用、用哪一个本来就是这次在哪跑的决定」。
   * ★ 传 `null` **不需要**动 `strict`：注册表的 `allowFallbackToNull: false`
   *   只管**回退兜底**那一轮（`registry.ts` 里 `continue` 掉 id 为 `null` 的候选），
   *   `prefer: "null"` 是"我点名要它"，走的是 prefer 分支，直接建。
   *   （第一版在这里写了 `options.gfx === "null" ? [...] : [...]`，被 M801 变异
   *   证明是**等价于没写**的死分支 —— 见 `docs/ARCHITECTURE.md` 的 strict 一节。）
   */
  readonly gfx?: "webgl2" | "null";
  /** 单调毫秒时钟（帧源的 dt 用它算）。判据传假时钟拨表；缺省 `Date.now`。 */
  readonly now?: () => number;
  /**
   * 虚拟键位。缺省按画布尺寸生成（真机就用这个）。
   *
   * ★ 给判据留口子的理由很具体：默认布局是"按屏幕比例算的"，而判据要知道
   *   **手指该按在哪**。让它去反推那套比例，等于把布局公式抄进判据 ——
   *   抄的那份一漂移，"触摸能走"这条就会在布局改动后变成假红/假绿。
   */
  readonly pad?: VirtualPad;
  /** 装好之后的回调（小游戏启动脚本用它把句柄挂到全局；判据用它拿断言目标）。 */
  readonly onReady?: (handle: DemoHandle) => void;
}

/**
 * 启动失败时**唯一**的播报点（弹窗 + 日志）。
 *
 * ★★ 为什么必须抽出来，而不是只放在 `surface.fatal` 里：
 *
 *   `surface` 是在 `createWxHost` **之后**才建好的（它要用 `wx` 才谈得上 `showToast`），
 *   而 `createWxHost` 自己就会失败 —— `WX.NO_TOUCH` / `WX.NO_FS` 恰恰是**真机上最常见**
 *   的那一类（触摸接口与文件系统在开发者工具与真机之间行为不一定一致）。
 *   于是顺序是：真机缺一个东西 ⇒ 抛在 surface 建好之前 ⇒ `main()` 的 promise 拒绝
 *   ⇒ 启动脚本里没人接 ⇒ **白屏，控制台一条红**。玩家看到的是"打开就黑"，开发者拿到的
 *   是一句没有上下文的堆栈，而这正好落在"只有真机才复现"的那一侧 —— 最贵的位置。
 *
 *   所以：**报错的路不能依赖"已经走到哪一步了"**。这一层只依赖 `wx` 本身。
 */
function reportFatal(wx: WxLike, text: string): void {
  // 日志是第一现场（真机调试与判据都读它），弹窗是给人看的。
  console.error(text);
  wx.showModal?.({ title: "启动失败", content: text.slice(0, 200), showCancel: false });
}

/** 把 `WxLike` 装成一局可玩的游戏。失败一律 reject，并带 `WX.*` / `DEMO.*` 错误码。 */
export async function startWxGame(wx: WxLike, options: WxGameOptions = {}): Promise<DemoHandle> {
  // ---- 四件套（canvas / 视口 / 帧源 / 输入）+ 存档盘
  const hostR = createWxHost(wx, {
    ...(options.saveRoot === undefined ? {} : { root: options.saveRoot }),
    ...(options.now === undefined ? {} : { now: options.now }),
    ...(options.pad === undefined ? {} : { pad: options.pad }),
  });
  if (!hostR.ok) {
    // ★ 不 try/catch 成"能用的先用着"：让失败停在启动那一刻，并带上具体是哪一环。
    throw new Error(`${hostR.error.code}：${hostR.error.message}`);
  }
  const host = hostR.value;

  // ---- 后端注册（只有组合根能做）
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  registry.registerGfx(webgl2Backend, 100);
  // ★ 触摸设备**不会**被 probe 自动选中：`input-dom` 在小游戏里必然不过，
  //   而 `injected` 只在宿主交了设备时才可用（见 `backends/input-injected`）。
  registry.registerInput(injectedInputBackend, injectedInputBackend.priority);
  // 存档盘就是宿主那一个实例：再 `createWxFileSystem` 一次会得到**第二个**对象，
  // 两个缓存目录状态 ⇒ "刚写的文件读不到"（只在真机上偶发）。
  registry.registerFs(
    {
      id: "wx",
      scheme: "wx",
      probe: () => true,
      create: () => ok(host.fs),
    },
    100,
  );

  // ---- 资产（包内只读，根为空串）
  const assetFsR = createWxFileSystem(wx, { root: options.assetRoot ?? "" });
  if (!assetFsR.ok) throw new Error(`${assetFsR.error.code}：${assetFsR.error.message}`);
  const assetFs = assetFsR.value;

  const assets: DemoAssets = {
    open: async () => assetFs,
    // ★ 标签写 `wx`：浏览器那两条是 `direct` / `bundle`（判据靠它区分），
    //   小游戏只有一条，写死反而让"是不是走错了宿主"一眼可见。
    kind: () => "wx",
    // 导入管线的临时盘：与浏览器同一个实现（内容一起、生命周期一次）。
    scratch: () => new MemoryFileSystem(),
  };

  /**
   * 能看见的东西：**只有原生 toast 与弹窗**，没有 HUD 的 DOM 兜底。
   * 见文件头那张表 —— 这不是缺省，是小游戏的事实。
   */
  const surface: DemoSurface = {
    toast: (msg) => {
      if (msg === null) return;
      wx.showToast?.({ title: msg, icon: "none", duration: 2000 });
    },
    fatal: (text) => {
      reportFatal(wx, text);
    },
  };

  const env: DemoHostEnv = {
    registry,
    canvas: host.canvas,
    viewport: {
      width: host.viewport.width,
      height: host.viewport.height,
      // ★ 小游戏的 `pixelRatio` 来自 `getSystemInfoSync`；拿不到时 `readViewport` 记 1
      //   （"不知道"，不是"等于 1"）。这里原样传，不再夹上限 —— 上屏尺寸已由宿主定。
      devicePixelRatio: host.viewport.pixelRatio,
      // ★ 安全区（CSS 像素四边 inset）。老基础库没有 `safeArea` 时这里是 `undefined`，
      //   于是 UI 按 0 处理 —— 不替设备猜边距。
      ...(host.viewport.safeArea === undefined ? {} : { safeArea: host.viewport.safeArea }),
    },
    assets,
    saves: host.fs,
    tick: host.tick,
    now: options.now ?? (() => Date.now()),
    setTimer: (fn, ms) => globalThis.setTimeout(fn, ms) as unknown as number,
    clearTimer: (id) => globalThis.clearTimeout(id),
    // ★ 小游戏没有"刷新页面"。这里只提示一句就返回 —— **不要**抛错：
    //   这个函数是在 `onStep`（固定步长）里被调的，抛出去会打断帧循环，
    //   而"按了 R 之后游戏卡死"比"按了 R 没反应"更难排查。
    reload: () => surface.toast?.("小游戏里没有刷新页面，退出重进即可"),
    // 没有 wasm 路径 ⇒ 注册表里不会注册 lua，`script` 落到 null 后端（日志会说明）。
    scriptWasm: null,
    surface,
    platformId: "wx",
    platform: {
      prefer: { gfx: options.gfx ?? "webgl2", input: INJECTED_INPUT_ID, fs: "wx" },
      // ★★ `strict` 是"不留半个宿主"的机器可读形式：这三样退回 null 就等于
      //   "游戏起来了但按不动 / 存不了 / 画面全黑"，而三者都要翻五个方向才查得出来。
      // ★ gfx 也在这里，即使调用方要的是 `gfx: "null"` —— 那不是矛盾：
      //   `strict` 拦的是**回退**（prefer 的 webgl2 不可用 ⇒ 悄悄换成 null ⇒ 黑屏），
      //   而 `prefer: "null"` 是点名要 null，走 prefer 分支，不受 strict 影响。
      //   这条区别很重要，写错过一版（拿 `options.gfx === "null"` 当条件去删 gfx，
      //   被 M801 变异证明等价于没写），见 `tests/host/wx-entry.test.ts` 的 no-GL 那条。
      strict: ["gfx", "input", "fs"],
      backendOptions: {
        gfx: { canvas: host.canvas },
        input: { device: host.input },
      },
    },
  };

  const handle = await buildDemoGame(env);
  options.onReady?.(handle);
  return handle;
}

/**
 * `main()` 的幂等状态。
 *
 * ★ 为什么要有（批141）：真机正常路径只调一次，但**热重载 / 双入口 / 假宿主连调两次**
 *   会建出**第二条 rAF 循环** —— 症状是"游戏跑两倍速"或"一帧推两次"，
 *   而两次调用都成功返回、日志里一句错都没有。这是"标志位对了、效果没发生"的反面：
 *   没有任何标志位，效果却发生了两次。
 * ★ 一旦尝试过就**不再重试**（即使上一次失败）：失败可能发生在帧循环已经起来之后
 *   （例如 `onReady` 里抛），那时再起一遍就是两条循环 —— 比"不能重试"贵得多。
 */
let bootState: "idle" | "attempted" = "idle";

/** 判据用：把幂等状态复位。**只给测试**，宿主不该调用它。 */
export function __resetWxMainForTest(): void {
  bootState = "idle";
}

/**
 * 小游戏启动脚本的入口（`src/wx-boot.ts` 调它）。
 *
 * ★★ 这里**必须**接住 `startWxGame` 的失败，而不是让它变成未处理的 promise 拒绝。
 *   真机上"未处理拒绝"最坏的结果是**什么都不发生**：帧循环没起来、屏幕上没有画面、
 *   也没有弹窗 —— 与"游戏正在加载"看起来一模一样。见 `reportFatal` 的注释。
 *
 * ★ 接住之后**不再重抛**：人已经看见弹窗、日志里也有全文；再抛一次只会变成
 *   一条未处理拒绝，而"报过了"这件事那时就有两个真相了（哪个才算数？）。
 *   判据要看失败原因，调的是 `startWxGame`（它仍然 reject），不是 `main`。
 *
 * ★ 例外是「重复调用」：它**先报再抛**。理由是两者的读者不同 —— `startWxGame`
 *   的失败是**运行时**故障（玩家要看见弹窗），重复调用是**接线**错误（开发者要看见
 *   堆栈）。只弹窗不抛，堆栈就丢了；只抛不弹，真机上又变成"什么都没发生"。
 */
export async function main(): Promise<void> {
  const g = globalThis as { wx?: WxLike };
  if (g.wx === undefined) {
    // 没有 `wx` 连弹窗都没有（这不是小游戏环境）—— 只能打日志，然后抛给调用方，
    // 否则"在浏览器里跑了小游戏入口"会变成一次静默的空转。
    // ★ 这一支**不消耗**幂等配额：它不是一次启动尝试。
    const text = "WX.NO_GLOBAL：全局没有 wx —— 这不是小游戏运行环境";
    console.error(text);
    throw new Error(text);
  }
  const wx = g.wx;
  if (bootState !== "idle") {
    const text = `${WX_ERR.ALREADY_STARTED}：main() 已经被调用过 —— 再调一次会建出第二条帧循环（表现是跑两倍速或一帧推两次）。重启小程序，不要重复调用。`;
    reportFatal(wx, text);
    throw new Error(text);
  }
  bootState = "attempted";
  try {
    await startWxGame(wx, {
      onReady: () => {
        // 小游戏里没有 `window`；调试时从控制台读 `globalThis.__engine` 即可。
        // （写在这里而不是 startWxGame 内部：那是"宿主要不要暴露调试面"的选择。）
      },
    });
  } catch (e) {
    // ★ 错误码前缀（`WX.NO_TOUCH：…`）必须原样到人眼前：真机排查时它是唯一的路标。
    reportFatal(wx, e instanceof Error ? e.message : String(e));
  }
}
