/**
 * L4 · 构建发布：内容寻址的资产包（阶段 5 的第一条）
 *
 * 出口判据（ARCHITECTURE §12 原文）：
 *   ① 删掉一个**未被引用**的资产后，构建产物**逐字节不变**；
 *   ② 改动一个资产只重打**一个**包。
 *
 * 这两条判据直接定义了设计，不是"参考了一下"：
 *
 *  · 要满足 ①，产物只能包含**入口闭包**，绝不能是"目录里所有文件"。
 *    反过来这条判据也保护了一件事：**往目录里丢一个草稿资产不会让线上包变**。
 *  · 要满足 ②，必须按内容分片且**包名 = 内容 hash**。改一个资产只让包含它的那个包换名，
 *    其余包名不变 ⇒ CDN 缓存不失效、增量上传只需传一个包。
 *    若打成一个大包，改一个字节整包就失效 —— 那样"增量"只是一种说法。
 *
 * ★ 为什么 manifest 里没有时间戳/构建号：
 *   有了它们，"同样的输入产出同样的字节"就永久不成立，而**可复现构建**是
 *   "这条产物确实是这份源码打出来的"的唯一证据。要追溯就打 git commit，不要打时间。
 *
 * ★ 为什么缺依赖要报错而不是跳过：
 *   静默跳过会产出一个"少了东西但能上线"的包，错误推迟到玩家手里才暴露。
 *
 * ★ 为什么包内每条资产要带长度前缀（framing）而不是直接拼接：
 *   直接拼接有歧义 —— `["ab","c"]` 与 `["a","bc"]` 拼出来是同一串字节，
 *   于是两个**不同**的资产集合会得到**相同**的包 hash，内容寻址当场失去意义。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import { hashBytes, hashText } from "../../foundation/hash.ts";
import { canonicalize } from "../../foundation/canonical.ts";

/** manifest 格式版本。字段语义变了就要升，否则新旧产物没法比。 */
export const PUBLISH_SCHEMA = 1;

export const BUILD_BAD_CONFIG = "BUILD.BAD_CONFIG";
export const BUILD_DUPLICATE_ASSET = "BUILD.DUPLICATE_ASSET";
export const BUILD_ENTRY_MISSING = "BUILD.ENTRY_MISSING";
export const BUILD_DEP_MISSING = "BUILD.DEP_MISSING";

export interface PublishAsset {
  /** 资产身份（与 `AssetMeta.id` 同义）。 */
  readonly id: string;
  /**
   * 运行时取资产的键（**不参与**任何 hash）。
   *
   * ★ 批127 改口：原来写的是「逻辑路径，只用于排查」，而 `BundleFileSystem`
   *   `readBinary(path)` 就是拿它当键查的 —— 文档说"只用于排查"、代码当主键用，
   *   于是构建侧按源文件位置生成、运行时按自己的挂载根去取，两边永远对不上。
   *   现在这份路径由 `CollectOptions.mount` 决定（见那里的注释）。
   */
  readonly path: string;
  readonly bytes: Uint8Array;
}

export interface PublishInput {
  /** 入口资产 id（从哪个开始要）。顺序不影响结果。 */
  readonly entries: readonly string[];
  /** 已知的全部资产。★ 未被闭包引用的**不会**进产物。 */
  readonly assets: readonly PublishAsset[];
  /** 依赖边，与 `AssetMeta.dependencies` 同义（`from → [to...]`）。 */
  readonly dependencies: ReadonlyMap<string, readonly string[]>;
}

export interface PublishConfig {
  /** 单个包的最大字节数（默认 64 KiB）。单条资产比它还大时自成一件。 */
  readonly maxBundleBytes?: number;
}

export interface PublishManifestAsset {
  readonly id: string;
  readonly path: string;
  readonly hash: string;
  readonly size: number;
}

export interface PublishManifestBundle {
  readonly hash: string;
  readonly size: number;
  /** 包内资产 id，按 id 升序。 */
  readonly assets: readonly string[];
}

export interface PublishManifest {
  readonly schema: number;
  readonly entries: readonly string[];
  readonly assets: readonly PublishManifestAsset[];
  readonly bundles: readonly PublishManifestBundle[];
  /** manifest 自身的内容 hash（不含本字段）。 */
  readonly hash: string;
}

export interface PublishOutput {
  readonly manifest: PublishManifest;
  readonly bundles: ReadonlyMap<string, Uint8Array>;
}

/** 包内单条记录的 framing：[u32 idLen][id][u32 dataLen][data]，全部小端。 */
function frame(id: string, bytes: Uint8Array): Uint8Array {
  const idBytes = new TextEncoder().encode(id);
  const out = new Uint8Array(4 + idBytes.length + 4 + bytes.length);
  const dv = new DataView(out.buffer, out.byteOffset, out.byteLength);
  dv.setUint32(0, idBytes.length, true);
  out.set(idBytes, 4);
  dv.setUint32(4 + idBytes.length, bytes.length, true);
  out.set(bytes, 4 + idBytes.length + 4);
  return out;
}

export function buildPublish(input: PublishInput, cfg: PublishConfig = {}): Result<PublishOutput, EngineError> {
  const max = cfg.maxBundleBytes ?? 64 * 1024;
  if (!Number.isInteger(max) || max <= 0) {
    return err({
      code: BUILD_BAD_CONFIG,
      message: `maxBundleBytes 必须是正整数，得到 ${String(cfg.maxBundleBytes)}`,
    });
  }

  // 1) 建索引。重复 id 直接报错：否则"用的是哪一份字节"取决于数组顺序，产物不可复现。
  const byId = new Map<string, PublishAsset>();
  for (const a of input.assets) {
    if (byId.has(a.id)) {
      return err({ code: BUILD_DUPLICATE_ASSET, message: `资产 id「${a.id}」出现多次`, detail: { id: a.id } });
    }
    byId.set(a.id, a);
  }

  // 2) 入口去重 + 排序（顺序不影响产物，这是判据之一）
  const entries = [...new Set(input.entries)].sort();
  for (const e of entries) {
    if (!byId.has(e)) {
      return err({ code: BUILD_ENTRY_MISSING, message: `入口资产「${e}」不存在`, detail: { id: e } });
    }
  }

  // 3) 求闭包。依赖缺失报错，不静默跳过。
  const reachable = new Set<string>();
  const queue: string[] = [...entries];
  while (queue.length > 0) {
    const cur = queue.pop()!;
    if (reachable.has(cur)) continue;
    reachable.add(cur);
    const deps = input.dependencies.get(cur) ?? [];
    for (const d of deps) {
      if (!byId.has(d)) {
        return err({
          code: BUILD_DEP_MISSING,
          message: `「${cur}」依赖的「${d}」不存在 —— 构建不允许产出缺件的包`,
          detail: { from: cur, missing: d },
        });
      }
      if (!reachable.has(d)) queue.push(d);
    }
  }

  // 4) 按 id 升序（唯一顺序：与输入数组顺序、Map 插入顺序都无关）
  const closure = [...reachable].sort();

  const manifestAssets: PublishManifestAsset[] = [];
  const assetHash = new Map<string, string>();
  for (const id of closure) {
    const a = byId.get(id)!;
    const h = hashBytes(a.bytes);
    assetHash.set(id, h);
    manifestAssets.push({ id, path: a.path, hash: h, size: a.bytes.length });
  }

  // 5) 按 id 顺序贪心装包。包名 = 包字节的内容 hash。
  const bundles = new Map<string, Uint8Array>();
  const manifestBundles: PublishManifestBundle[] = [];
  let curSegs: Uint8Array[] = [];
  let curLen = 0;
  let curIds: string[] = [];

  const flush = (): void => {
    if (curSegs.length === 0) return;
    const bytes = new Uint8Array(curLen);
    let at = 0;
    for (const s of curSegs) {
      bytes.set(s, at);
      at += s.length;
    }
    const h = hashBytes(bytes);
    bundles.set(h, bytes);
    manifestBundles.push({ hash: h, size: bytes.length, assets: [...curIds] });
    curSegs = [];
    curLen = 0;
    curIds = [];
  };

  for (const id of closure) {
    const seg = frame(id, byId.get(id)!.bytes);
    // 单条资产比包上限还大时它也自成一件：不报错，但包会超限（调用方看 size 就知道）
    if (curSegs.length > 0 && curLen + seg.length > max) flush();
    curSegs.push(seg);
    curLen += seg.length;
    curIds.push(id);
  }
  flush();

  // 6) manifest 自身 hash：走规范化序列化，避免键序把同一个 manifest 算成两个值
  const body = {
    schema: PUBLISH_SCHEMA,
    entries,
    assets: manifestAssets,
    bundles: manifestBundles,
  };
  const canon = canonicalize(body);
  if (!canon.ok) return canon;
  const hash = hashText(canon.value);

  return ok({
    manifest: { ...body, hash },
    bundles,
  });
}

/**
 * 把 manifest 与包列表渲染成**稳定的**文本（写进产物目录，便于 diff 与排查）。
 * ★ 键序、缩进、行尾全部固定：这段文本一旦不稳定，"逐字节不变"这条判据就只能验 manifest 对象。
 */
export function renderManifest(manifest: PublishManifest): string {
  const lines: string[] = [];
  lines.push(`# 由 tools 构建生成，请勿手改（schema ${String(manifest.schema)}）`);
  lines.push(`manifest ${manifest.hash}`);
  lines.push(`entries ${manifest.entries.join(",")}`);
  for (const a of manifest.assets) {
    lines.push(`asset ${a.id} ${a.hash} ${String(a.size)} ${a.path}`);
  }
  for (const b of manifest.bundles) {
    lines.push(`bundle ${b.hash} ${String(b.size)} ${b.assets.join(",")}`);
  }
  return `${lines.join("\n")}\n`;
}
