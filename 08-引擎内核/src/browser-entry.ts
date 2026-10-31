/**
 * 浏览器宿主入口（L6 · 组合根 · **薄壳**）
 *
 * 这个文件现在只做一件事：**把 DOM 世界翻译成 `DemoHostEnv`**，然后交给
 * `host/demo-game.ts` 的 `buildDemoGame`。装配本身（世界、模块、玩法）不在这里 ——
 * 它必须能在没有 `document` 的宿主里跑（小游戏），一条 `document.` 都不该出现在那边。
 *
 * ★ 为什么这个拆分值得做（而不是"看着更整齐"）：
 *   在这之前整段装配长在这个文件里、与 DOM 缠在一起（20 处 `document.`/`window.`
 *   /`localStorage`/隐藏 `<input>`）。于是"多一个宿主"不是接线问题而是重写问题，
 *   小游戏那条路（`src/host/wx/` 的 canvas / 视口 / 帧源 / 触摸 / 文件系统四件套
 *   早就齐了、37 条判据全绿）卡在"没有入口"，而它看起来像"卡在真机"。
 *
 * ★ 这里允许知道一切（具体后端、具体 DOM API）—— 它是**组合根**。
 *   同样的 import 出现在 `core/**` 里就是架构崩了（arch 规则 4 会红），
 *   出现在 `host/demo-game.ts` 里也是（那条规则只放行 root 与 GameApp）。
 */

import { MemoryFileSystem } from "./backends/fs-memory/fs.ts";
import { HttpFileSystem } from "./backends/fs-http/fs.ts";
import { StorageFileSystem } from "./backends/fs-storage/fs.ts";
import { registerNullBackends } from "./backends/index.ts";
import { webgl2Backend } from "./backends/gfx-webgl2/device.ts";
import { domInputBackend } from "./backends/input-dom/device.ts";
import { webAudioBackend } from "./backends/audio-webaudio/device.ts";
import { createLuaScriptBackend } from "./backends/script-lua/runtime.ts";
import { BackendRegistry } from "./platform/registry.ts";
import { backingStoreSize } from "./host/backing-store.ts";
import { RafTickSource } from "./runtime/tick-source.ts";
import { resolveAssetSource } from "./extensions/build/bundle-source.ts";
import { BundleFileSystem } from "./extensions/build/fs-bundle.ts";
import {
  ASSET_ROOT,
  buildDemoGame,
  type DamageNumberElement,
  type DemoAssets,
  type DemoHostEnv,
  type DemoSurface,
} from "./host/demo-game.ts";
import { parseNetMode } from "./host/net-mode.ts";
import type { ChannelLike } from "./extensions/net/broadcast-transport.ts";

/**
 * 打开联机通道（批163）。返回 `null` = 这一端不联网。
 *
 * ★★ 为什么用 `BroadcastChannel` 而不是 WebSocket：这一批要回答的是「两个标签页
 *   能不能一起玩」，不是「运营服怎么搭」。`BroadcastChannel` 是浏览器原生的同源广播，
 *   两个标签页各开一个同名 channel 就行 —— 不用起进程、不用端口、不用证书。
 *   代价写在脸上：**只在同一台机器、同一个浏览器进程内**成立。跨机器仍然要
 *   Steamworks 或 WebSocket，而那一天的改动只发生在 `net/broadcast-transport.ts`。
 *
 * ★ 名字用 `parseNetMode` 归一之后的 `room`，不在这里自己拼：两处各算一次的话，
 *   页面 A 用了缺省名、页面 B 用了原值（含空格），两个标签页就永远连不上，
 *   而两边的日志都写着"通道名是 xxx"。
 */
function openNetChannel(mode: ReturnType<typeof parseNetMode>): ChannelLike | null {
  if (mode.role === "off") return null;
  // 小游戏 / 老浏览器没有这个全局：**显式不启用**，而不是假装开着（假装开着之后
  // `send` 永远返回 false，表现就是"主机在广播、客户端一动不动"）。
  if (typeof BroadcastChannel === "undefined") return null;
  let bc: BroadcastChannel;
  try {
    bc = new BroadcastChannel(mode.room);
  } catch {
    return null;
  }
  // ★ 适配而不是「直接塞进去」：`BroadcastChannel.onmessage` 的类型是
  //   `(this: BroadcastChannel, ev: MessageEvent) => any`，与 `ChannelLike` 的
  //   `(ev: {data: unknown}) => void` 在参数上是**逆变**的 —— 直接赋值过不了 tsc，
  //   而 `as unknown as ChannelLike` 会把"将来 BC 的签名变了"这件事变成运行时才发现。
  //   一层 12 行的适配器把风险关在一个地方。
  let handler: ((ev: { readonly data: unknown }) => void) | null = null;
  bc.onmessage = (ev: MessageEvent): void => {
    handler?.(ev);
  };
  return {
    name: bc.name,
    postMessage: (data: unknown): void => {
      bc.postMessage(data);
    },
    close: (): void => {
      bc.close();
    },
    get onmessage(): ((ev: { readonly data: unknown }) => void) | null {
      return handler;
    },
    set onmessage(h: ((ev: { readonly data: unknown }) => void) | null) {
      handler = h;
    },
  };
}

/** 浮字容器的样式。★ 必须 `fixed`：`getBoundingClientRect()` 给的是**视口**坐标。 */
const FX_LAYER_STYLE =
  "position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;overflow:hidden;z-index:20;";

/** 单个浮字的样式（颜色按"是否击杀"分两档）。 */
const dmgStyle = (dead: boolean): string =>
  "position:absolute;left:0;top:0;font:700 14px/1 ui-monospace,monospace;" +
  `color:${dead ? "#ffd54a" : "#ff6b5a"};text-shadow:0 1px 2px rgba(0,0,0,.55);` +
  "pointer-events:none;will-change:transform,opacity;";

/**
 * 启动失败时把错误**显示在页面上**（而不是只留一条控制台日志）。
 *
 * ★ 转义不是洁癖：错误信息里含用户可控内容（资产路径、场景节点名、
 *   Lua 报错的源码片段）。直接拼进 `innerHTML` 会让一个畸形节点名变成一段 HTML。
 */
function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export async function main(): Promise<void> {
  /**
   * 页面参数（一次取出来）。
   *
   * ★ `URLSearchParams` 每次 `new URL(location.href)` 都要解析一遍 URL 字符串 ——
   *   这里原来有两处各解析一次，加了联机参数之后会变成五处。**一处解析、多处读**
   *   才能保证"同一个参数在不同地方读到的是同一个值"。
   */
  const params = new URL(location.href).searchParams;
  /** 联机模式（归一在这里做一次，`env` 里传原值给装配再算一次 —— 纯函数，两次相同）。 */
  const netModeForEntry = parseNetMode(params.get("net"), params.get("room"), params.get("seat"));

  const canvas = document.getElementById("cv") as HTMLCanvasElement | null;
  const hud = document.getElementById("hud");
  const toastEl = document.getElementById("toast");
  if (canvas === null || hud === null || toastEl === null) {
    throw new Error("页面结构不完整：需要 #cv / #hud / #toast");
  }
  const helpEl = document.getElementById("help");

  // ---- 画布尺寸：逻辑尺寸 × 像素比。上限 2 与 floor 的理由见 `host/backing-store.ts`。
  //   ★ 公式只有一份：`editor-entry.ts` 的两处（启动 + ResizeObserver 的 `syncViewport`）
  //   走的是同一个函数 —— 三处各写一遍时，改了上限的人只改启动那两行，
  //   而 `syncViewport` 会用旧上限把画布改回去（批145 合并）。
  const store = backingStoreSize(
    canvas.clientWidth || 960,
    canvas.clientHeight || 600,
    window.devicePixelRatio || 1,
  );
  const dpr = store.dpr;
  canvas.width = store.width;
  canvas.height = store.height;

  // ---- 后端注册（**只有组合根能做**）
  const registry = new BackendRegistry();
  registerNullBackends(registry); // 兜底：真实后端 probe 失败时自动降级
  registry.registerGfx(webgl2Backend, 100);
  registry.registerInput(domInputBackend, 100);
  registry.registerAudio(webAudioBackend, 100);
  // 脚本后端：wasm 从**本目录**取（`web/glue.wasm`），不依赖 unpkg ——
  // 否则"离线能不能跑"就变成了对 CDN 的依赖。
  const scriptWasm = new URL("glue.wasm", location.href).href;
  registry.registerScript(createLuaScriptBackend({ wasmPath: scriptWasm }), 100);

  // ---- 浮字层（伤害数字的家）
  const fxLayer = document.createElement("div");
  fxLayer.id = "fx";
  fxLayer.style.cssText = FX_LAYER_STYLE;
  document.body.appendChild(fxLayer);

  /** 这一次资产实际走了哪条来源（`direct` / `bundle`；判据读它）。 */
  let assetKindLabel = "direct";
  const assets: DemoAssets = {
    async open() {
      const source = await resolveAssetSource({
        packParam: new URL(location.href).searchParams.get("pack"),
        pageHref: location.href,
        root: ASSET_ROOT,
        fallback: () => new HttpFileSystem({ base: new URL("./assets/", location.href) }),
        fetchLike: (url) => fetch(url),
        warn: (message) => console.warn(message),
      });
      assetKindLabel = source instanceof BundleFileSystem ? "bundle" : "direct";
      return source;
    },
    kind: () => assetKindLabel,
    scratch: () => new MemoryFileSystem(),
  };

  const surface: DemoSurface = {
    hudLine: (text) => {
      hud.textContent = text;
    },
    // UI 树接管后必须藏掉：否则屏幕上两份 HUD，而两边数字可能不同步
    hideFallbackHud: () => {
      hud.hidden = true;
    },
    toast: (msg) => {
      if (msg === null) {
        toastEl.style.opacity = "0";
        return;
      }
      toastEl.textContent = msg;
      toastEl.style.opacity = "1";
    },
    help: (text) => {
      if (helpEl !== null) helpEl.textContent = text;
    },
    fatal: (text) => {
      document.body.innerHTML =
        `<pre style="color:#f66;padding:16px;font:13px ui-monospace;white-space:pre-wrap">` +
        `${escapeHtml(text)}</pre>`;
    },
    canvasRect: () => {
      const r = canvas.getBoundingClientRect();
      return { left: r.left, top: r.top, width: r.width, height: r.height };
    },
    damageNumber: (text, dead, by) => {
      const el = document.createElement("div");
      el.className = "dmg";
      // ★ `data-dmg` 是"屏幕上显示的是几"的证据：判据要读值，不只是数元素个数。
      el.dataset.dmg = text;
      // ★ `data-dmg-by`：生物打斗也在冒数字，不区分来源的话"数字会消失"永远等不到空数组。
      el.dataset.dmgBy = String(by);
      el.textContent = text;
      el.style.cssText = dmgStyle(dead);
      fxLayer.appendChild(el);
      const node: DamageNumberElement = {
        place(px, py, opacity) {
          el.style.transform = `translate(${px.toFixed(1)}px, ${py.toFixed(1)}px)`;
          el.style.opacity = opacity.toFixed(2);
        },
        remove() {
          el.remove();
        },
      };
      return node;
    },
    damageNumberCount: (by) =>
      by === undefined
        ? fxLayer.querySelectorAll(".dmg").length
        : fxLayer.querySelectorAll(`.dmg[data-dmg-by="${String(by)}"]`).length,
    keyboard: (handlers) => {
      // ★ 装配不知道 `preventDefault`：它只说"这个键我消费了"，拦不拦默认行为是宿主的事。
      window.addEventListener("keydown", (ev) => {
        if (handlers.keydown(ev)) ev.preventDefault();
      });
      window.addEventListener("keyup", (ev) => {
        handlers.keyup(ev);
      });
      // 焦点离开页面时 Shift 可能卡在"按下"（keyup 没送到）—— 失焦一律清零
      window.addEventListener("blur", () => {
        handlers.blur();
      });
      // 首次真实手势时解锁音频（浏览器要求）
      window.addEventListener("pointerdown", () => handlers.pointerdown(), { once: true });
    },
    ime: (hooks) => {
      const el = document.createElement("input");
      el.type = "text";
      el.autocomplete = "off";
      el.spellcheck = false;
      // 放到屏幕外但**不能** `display:none`（后者会让它拿不到焦点，输入法就不工作）
      el.style.cssText =
        "position:fixed;left:-1000px;top:0;width:1px;height:1px;opacity:0;border:0;padding:0;";
      document.body.appendChild(el);
      el.addEventListener("compositionstart", () => hooks.begin());
      el.addEventListener("compositionupdate", (e) => hooks.update(e.data ?? ""));
      el.addEventListener("compositionend", (e) => {
        hooks.commit(e.data ?? "");
        // `value` 不参与逻辑（真正的值在装配的 `cmd` 里），不清会越攒越多
        el.value = "";
      });
      // ★ 不能直接把 `el` 交出去：装配只该知道"聚焦/失焦"两件事，
      //   而 `isFocused` 要拿同一个元素对号 —— 用闭包里的 `element` 对上。
      return {
        focus: () => el.focus(),
        blur: () => el.blur(),
        element: el,
      };
    },
    isFocused: (h) => (h as { element?: unknown } | null)?.element === document.activeElement,
    blur: (h) => (h as { blur?: () => void } | null)?.blur?.(),
  };

  const env: DemoHostEnv = {
    registry,
    canvas,
    viewport: { width: canvas.width, height: canvas.height, devicePixelRatio: dpr },
    assets,
    // 存档走 `StorageFileSystem`（不是直接 `localStorage.setItem`）：
    // 于是"配额满/读不出"有错误码，与 Node 侧同一套。
    saves: new StorageFileSystem({ storage: window.localStorage, prefix: "engine08.fs." }),
    // ★ 浏览器这里**不给** `input`：由注册表挑 `input-dom`（它自带键盘/指针接线）。
    //   小游戏才用注入通道（那边没有 DOM，probe 必然不过）。
    tick: new RafTickSource(() => performance.now()),
    now: () => performance.now(),
    setTimer: (fn, ms) => window.setTimeout(fn, ms),
    clearTimer: (id) => window.clearTimeout(id),
    reload: () => location.reload(),
    scriptWasm,
    // 批156：`?tree=ai/hound_grudge` —— 全体生物换一棵决策树（不改代码、不用重建）。
    // ★ 空串/缺省都交给装配去归一（空串不是"换成一棵空树"，是"没指定"）。
    aiTree: params.get("tree"),
    // 批163：`?net=host` / `?net=client`，可选 `&room=`（通道名）与 `&seat=`（座位号）。
    // ★ 归一在 `host/net-mode.ts`（有判据）；这里只把原值与通道交给装配。
    net: params.get("net"),
    netRoom: params.get("room"),
    netSeat: params.get("seat"),
    netChannel: openNetChannel(netModeForEntry),
    surface,
    platformId: "web",
    platform: {
      backendOptions: {
        gfx: { canvas },
        input: { keyboard: window, pointer: canvas },
        audio: {},
      },
    },
  };

  const handle = await buildDemoGame(env);

  // 供浏览器端到端判据读取（自动化时用；不影响正常游玩）
  (globalThis as { __engine?: unknown }).__engine = handle;
}

void main();
