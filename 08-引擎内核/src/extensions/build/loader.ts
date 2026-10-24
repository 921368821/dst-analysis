/**
 * L4 · 产物读取（阶段 5：**构建出来的包，运行时真的能读**）
 *
 * `publish.ts` 能产出"内容寻址的包 + manifest"，但在此之前没有任何东西读得回来 ——
 * 也就是说"产物能被消费"这件事**只有构建侧的判据在自说自话**：
 * 它证明的是"字节落盘了"，证明不了"运行时按 manifest 找得到、解得出、并且内容还对"。
 *
 * 本文件补这一段，并且把三件事**在运行时**验一遍（不是构建期）：
 *
 * ① **包名 = 内容 hash**。取回包之后先算 hash，与 manifest 里记的比。
 *    不验的话，CDN 返回一个截断/换成旧版本的文件时，解析可能"看起来成功"
 *    （比如两个资产的内容恰好都还能解），而错的东西已经进了内存。
 *
 * ② **资产 hash**。从包里解出资产后，再与 manifest 里该资产的 hash 比。
 *    这一条抓的是"包没被改，但 manifest 与包不配套"（比如部署时只上传了包、
 *    manifest 还是上一版）。只验包 hash 是抓不到这种的。
 *
 * ③ **manifest 自身的 hash**。manifest 里记着自己内容的 hash；
 *    读取时重算一遍。否则"改 manifest 让第 ② 条永远成立"是免费的 ——
 *    校验用的基准本身可写，那校验就只是仪式。
 *
 * ★ 包格式（framing）见 `publish.ts` 的 `frame()`：`[u32 idLen][id][u32 dataLen][data]`，小端。
 *   解析必须**严格**：截断、重复 id、尾随垃圾字节全部报错。
 *   宽松解析（"能读多少算多少"）的后果是两个不同资产集合能解出同一份内存，
 *   而这正是内容寻址要排除的事。
 */

import { canonicalize } from "../../foundation/canonical.ts";
import { hashBytes, hashText } from "../../foundation/hash.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { PUBLISH_SCHEMA, type PublishManifest } from "./publish.ts";

/** manifest 文本不是合法 JSON / 结构不对 / 自身 hash 不符。 */
export const LOAD_BAD_MANIFEST = "LOAD.BAD_MANIFEST";
/** 包的字节与 manifest 记的 hash 不符，或 framing 损坏。 */
export const LOAD_BAD_BUNDLE = "LOAD.BAD_BUNDLE";
/** manifest 里没有这个资产 id。 */
export const LOAD_ASSET_MISSING = "LOAD.ASSET_MISSING";
/** 取包的函数失败（网络 / 文件不存在）。 */
export const LOAD_BUNDLE_MISSING = "LOAD.BUNDLE_MISSING";
/** 内容与 hash 不符（包或资产）。 */
export const LOAD_HASH_MISMATCH = "LOAD.HASH_MISMATCH";

/** id 长度上限（防御性：损坏的 framing 可能读出一个几十亿的 idLen）。 */
const MAX_ID_BYTES = 4096;

export interface BundleReaderStats {
  /** 真正调用 `fetchBundle` 的次数（同一包只会取一次 —— 这是"缓存真的生效"的证据）。 */
  readonly fetches: number;
  /** 命中缓存（或已解析结果）的次数。 */
  readonly hits: number;
  /** `get()` 被调用的次数。 */
  readonly requests: number;
  /** 已解析的包数。 */
  readonly bundles: number;
}

export interface BundleReader {
  get(assetId: string): Promise<Result<Uint8Array, EngineError>>;
  stats(): BundleReaderStats;
}

/** 资产 id → 包 hash（从 manifest 反查，重复归属直接报错）。 */
function indexAssets(manifest: PublishManifest): Result<Map<string, string>, EngineError> {
  const known = new Set(manifest.assets.map((a) => a.id));
  const index = new Map<string, string>();
  for (const b of manifest.bundles) {
    for (const id of b.assets) {
      if (!known.has(id)) {
        return err(
          engineError(LOAD_BAD_MANIFEST, `包 ${b.hash.slice(0, 8)}… 里有一个 manifest 没登记的资产「${id}」`),
        );
      }
      const prev = index.get(id);
      if (prev !== undefined) {
        return err(
          engineError(LOAD_BAD_MANIFEST, `资产「${id}」同时出现在包 ${prev.slice(0, 8)}… 与 ${b.hash.slice(0, 8)}… 里`),
        );
      }
      index.set(id, b.hash);
    }
  }
  for (const a of manifest.assets) {
    if (!index.has(a.id)) {
      return err(engineError(LOAD_BAD_MANIFEST, `manifest 登记了资产「${a.id}」但没有任何包含它`));
    }
  }
  return ok(index);
}

/** 重算 manifest 自身的 hash（口径与 `buildPublish` 完全一致：只对 body 做规范化）。 */
function manifestHashOf(manifest: PublishManifest): Result<string, EngineError> {
  const body = {
    schema: manifest.schema,
    entries: manifest.entries,
    assets: manifest.assets,
    bundles: manifest.bundles,
  };
  const canon = canonicalize(body);
  if (!canon.ok) return canon;
  return ok(hashText(canon.value));
}

/**
 * 解析 `manifest.json` 文本。
 *
 * ★ 校验顺序：JSON → schema → 结构 → **自身 hash** → 包与资产的互相覆盖。
 *   最后一步（`indexAssets`）容易漏：manifest 可能"内部自洽"但某个资产不在任何包里，
 *   于是 `get()` 永远 `ASSET_MISSING`，而人会去怀疑部署。
 */
export function parseManifest(text: string): Result<PublishManifest, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return err(engineError(LOAD_BAD_MANIFEST, `manifest 不是合法 JSON：${e instanceof Error ? e.message : String(e)}`));
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(engineError(LOAD_BAD_MANIFEST, "manifest 顶层必须是对象"));
  }
  const m = raw as Partial<PublishManifest>;
  if (m.schema !== PUBLISH_SCHEMA) {
    return err(
      engineError(LOAD_BAD_MANIFEST, `manifest schema 是 ${String(m.schema)}，本运行时只认 ${String(PUBLISH_SCHEMA)}`),
    );
  }
  if (!Array.isArray(m.entries) || !Array.isArray(m.assets) || !Array.isArray(m.bundles) || typeof m.hash !== "string") {
    return err(engineError(LOAD_BAD_MANIFEST, "manifest 缺字段（entries / assets / bundles / hash 都要有）"));
  }
  for (const a of m.assets) {
    if (typeof a?.id !== "string" || typeof a.hash !== "string" || typeof a.size !== "number") {
      return err(engineError(LOAD_BAD_MANIFEST, "assets 里有一条缺 id/hash/size"));
    }
  }
  for (const b of m.bundles) {
    if (typeof b?.hash !== "string" || typeof b.size !== "number" || !Array.isArray(b.assets)) {
      return err(engineError(LOAD_BAD_MANIFEST, "bundles 里有一条缺 hash/size/assets"));
    }
  }

  const manifest = m as PublishManifest;
  const rehash = manifestHashOf(manifest);
  if (!rehash.ok) return rehash;
  if (rehash.value !== manifest.hash) {
    return err(
      engineError(
        LOAD_HASH_MISMATCH,
        `manifest 自身 hash 不符：记的是 ${manifest.hash.slice(0, 16)}…，重算得到 ${rehash.value.slice(0, 16)}…（manifest 被改过？）`,
      ),
    );
  }
  const indexed = indexAssets(manifest);
  if (!indexed.ok) return indexed;
  return ok(manifest);
}

/**
 * 解析一个包。
 *
 * `expectedHash` 给了就先校验**整包** hash（见文件头 ①）。
 * 返回值是 `id → 资产字节` 的副本（不与入参共享内存：调用方改了返回值不该影响缓存）。
 */
export function parseBundle(bytes: Uint8Array, expectedHash?: string): Result<Map<string, Uint8Array>, EngineError> {
  if (expectedHash !== undefined) {
    const got = hashBytes(bytes);
    if (got !== expectedHash) {
      return err(
        engineError(
          LOAD_HASH_MISMATCH,
          `包 hash 不符：manifest 记 ${expectedHash.slice(0, 16)}…，实际 ${got.slice(0, 16)}…（${String(bytes.length)} 字节）`,
        ),
      );
    }
  }
  const out = new Map<string, Uint8Array>();
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const dec = new TextDecoder();
  let at = 0;
  while (at < bytes.length) {
    if (at + 4 > bytes.length) {
      return err(engineError(LOAD_BAD_BUNDLE, `包在第 ${String(at)} 字节处截断（读不完 idLen）`));
    }
    const idLen = dv.getUint32(at, true);
    at += 4;
    if (idLen === 0 || idLen > MAX_ID_BYTES) {
      return err(engineError(LOAD_BAD_BUNDLE, `第 ${String(at - 4)} 字节处的 idLen=${String(idLen)} 不合法`));
    }
    if (at + idLen + 4 > bytes.length) {
      return err(engineError(LOAD_BAD_BUNDLE, `包在第 ${String(at)} 字节处截断（读不完 id）`));
    }
    const id = dec.decode(bytes.subarray(at, at + idLen));
    at += idLen;
    const dataLen = dv.getUint32(at, true);
    at += 4;
    if (at + dataLen > bytes.length) {
      return err(
        engineError(LOAD_BAD_BUNDLE, `资产「${id}」声明 ${String(dataLen)} 字节，但包只剩 ${String(bytes.length - at)} 字节`),
      );
    }
    if (out.has(id)) {
      return err(engineError(LOAD_BAD_BUNDLE, `包里资产「${id}」出现两次（framing 有歧义）`));
    }
    out.set(id, bytes.slice(at, at + dataLen));
    at += dataLen;
  }
  if (out.size === 0) {
    return err(engineError(LOAD_BAD_BUNDLE, "包是空的（0 条资产）"));
  }
  return ok(out);
}

export interface ReaderOptions {
  readonly manifest: PublishManifest;
  /** 取一个包的字节（Node 读文件 / 浏览器 fetch）。失败请 `throw`，会被转成 `LOAD.BUNDLE_MISSING`。 */
  readonly fetchBundle: (hash: string) => Promise<Uint8Array>;
}

/**
 * 按 manifest 读资产。
 *
 * ★ 同一个包只取一次（`fetchBundle` 调用次数可查）：
 *   一个 pack 里通常有十几个资产，每个资产各取一次包会把首屏流量乘以十几 ——
 *   而画面上看不出区别，只有网络面板能看出来。
 */
export function createBundleReader(opts: ReaderOptions): BundleReader {
  const { manifest } = opts;
  let fetches = 0;
  let hits = 0;
  let requests = 0;
  const cache = new Map<string, Promise<Result<Map<string, Uint8Array>, EngineError>>>();
  const assetIndex = new Map<string, string>();
  for (const b of manifest.bundles) for (const id of b.assets) assetIndex.set(id, b.hash);
  const assetHash = new Map<string, string>();
  for (const a of manifest.assets) assetHash.set(a.id, a.hash);

  const loadBundle = (hash: string): Promise<Result<Map<string, Uint8Array>, EngineError>> => {
    const hit = cache.get(hash);
    if (hit !== undefined) {
      hits++;
      return hit;
    }
    fetches++;
    const p = (async (): Promise<Result<Map<string, Uint8Array>, EngineError>> => {
      let bytes: Uint8Array;
      try {
        bytes = await opts.fetchBundle(hash);
      } catch (e) {
        return err(
          engineError(LOAD_BUNDLE_MISSING, `取包 ${hash.slice(0, 8)}… 失败：${e instanceof Error ? e.message : String(e)}`),
        );
      }
      return parseBundle(bytes, hash);
    })();
    cache.set(hash, p);
    return p;
  };

  return {
    async get(assetId: string): Promise<Result<Uint8Array, EngineError>> {
      requests++;
      const bundleHash = assetIndex.get(assetId);
      if (bundleHash === undefined) {
        return err(
          engineError(
            LOAD_ASSET_MISSING,
            `资产「${assetId}」不在 manifest 里（已登记 ${String(manifest.assets.length)} 个）`,
          ),
        );
      }
      const bundle = await loadBundle(bundleHash);
      if (!bundle.ok) return bundle;
      const data = bundle.value.get(assetId);
      if (data === undefined) {
        return err(
          engineError(LOAD_BAD_BUNDLE, `包 ${bundleHash.slice(0, 8)}… 里没有资产「${assetId}」（manifest 与包不配套）`),
        );
      }
      // 见文件头 ②：包 hash 对不代表 manifest 与包配套
      const want = assetHash.get(assetId);
      if (want === undefined) {
        return err(engineError(LOAD_BAD_MANIFEST, `资产「${assetId}」没有登记 hash`));
      }
      const got = hashBytes(data);
      if (got !== want) {
        return err(
          engineError(
            LOAD_HASH_MISMATCH,
            `资产「${assetId}」hash 不符：manifest 记 ${want.slice(0, 16)}…，解出 ${got.slice(0, 16)}…（部署时 manifest 与包不是同一版？）`,
          ),
        );
      }
      return ok(data);
    },
    stats(): BundleReaderStats {
      return { fetches, hits, requests, bundles: cache.size };
    },
  };
}
