/**
 * L4 · 构建产物 · 「资产从哪来」的**决策**（可直接判据）
 *
 * 浏览器入口需要回答一个问题：这次是从 `web/assets` 直读，还是从构建产物（内容寻址的包）读？
 * 答案写在 URL 上（`?pack=<manifest 地址>`），但**决策本身**不该长在 `browser-entry.ts` 里 ——
 * 那个文件的每一条分支都只能靠"起一个无头浏览器跑一遍"来验，而这条决策完全可以抽成纯函数：
 * 给它参数、给它假的 fetch、看它返回什么后端、有没有留痕。
 *
 * ★ 为什么默认必须是不变的直读：
 *   现有 demo、浏览器自检、跨宿主存档全跑在直读上。把默认换成包，会让"没构建产物就打不开游戏"
 *   —— 而构建产物是发布期才有的东西。所以开关是**显式**的：URL 上有 `pack` 参数才走包。
 *
 * ★ 为什么失败要退回直读、而不是直接报错：
 *   与 `bakeAtlasFromAssets` 的降级纪律一致 —— 资产读不到时游戏还能用程序化图集跑。
 *   但**必须留痕**（`warn` 回调）：静默退回会让「以为在测包，其实在测直读」变成长期假象，
 *   而那正是这一整轮要消灭的盲区。判据里专门有一条验 warn 被调用。
 */

import type { IReadableFileSystem } from "../../platform/fs/fs.ts";
import { BundleFileSystem } from "./fs-bundle.ts";
import { parseManifest } from "./loader.ts";

/** fetch 的最小结构子集（`Response` 天然满足；判据注入假的）。 */
export interface FetchResponseLike {
  readonly ok: boolean;
  readonly status: number;
  text(): Promise<string>;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export type FetchTextLike = (url: string) => Promise<FetchResponseLike>;

export interface AssetSourceOptions {
  /** URL 上的 `pack` 参数；`null` 或空串表示走直读。 */
  readonly packParam: string | null;
  /** 当前页面地址（用来解析相对 URL）。 */
  readonly pageHref: string;
  /** manifest 里 `path` 的挂载前缀（与构建配置的 `assetRoot` 一致）。 */
  readonly root?: string;
  readonly fallback: () => IReadableFileSystem;
  readonly fetchLike?: FetchTextLike;
  readonly warn?: (message: string) => void;
}

/**
 * 决定这一次的资产来源。
 *
 * ★ 三条出口都必须可判：
 *   ① 没有 `pack` ⇒ 直接给 `fallback`（**不调 fetch**，也不能 warn）；
 *   ② `pack` 有效 ⇒ `BundleFileSystem`；
 *   ③ `pack` 无效（取不到 / 解析失败 / 包结构不对）⇒ `fallback` + 一条 warn。
 */
export async function resolveAssetSource(opts: AssetSourceOptions): Promise<IReadableFileSystem> {
  const param = opts.packParam;
  if (param === null || param === "") return opts.fallback();

  const doFetch = opts.fetchLike ?? ((url: string) => globalThis.fetch(url));
  const warn = opts.warn ?? (() => {});
  try {
    const manifestUrl = new URL(param, opts.pageHref);
    const res = await doFetch(manifestUrl.href);
    if (!res.ok) throw new Error(`manifest 取不到：HTTP ${String(res.status)}`);
    const parsed = parseManifest(await res.text());
    if (!parsed.ok) throw new Error(`${parsed.error.code}：${parsed.error.message}`);
    const dir = new URL(".", manifestUrl);
    return new BundleFileSystem({
      manifest: parsed.value,
      root: opts.root,
      fetchBundle: async (hash) => {
        const r = await doFetch(new URL(`bundles/${hash}.bin`, dir).href);
        if (!r.ok) throw new Error(`包取不到：HTTP ${String(r.status)}`);
        return new Uint8Array(await r.arrayBuffer());
      },
    });
  } catch (e) {
    // 退回直读并留痕（见文件头）。
    warn(`[asset] 从包加载失败，退回直读：${e instanceof Error ? e.message : String(e)}`);
    return opts.fallback();
  }
}
