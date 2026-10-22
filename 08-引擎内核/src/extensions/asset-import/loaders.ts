/**
 * L4 · 导入产物的加载器（导入 → 运行时 的闭环）
 *
 * ★★ 为什么这一步必须存在：
 *   `AssetImportPipeline` 只做"源文件 → 产物 + 注册元数据"。如果没人**消费**产物，
 *   `AssetDatabase.load(id)` 永远返回 `ASSET.NO_LOADER` —— 导入管线看起来全绿，
 *   实际上资产进不了世界。这是"中间层做完了、两头没接上"的典型假完成。
 *
 * ★ 为什么加载器持有 `root` 而不是从 `AssetMeta.path` 反推：
 *   产物路径规则是**导入器的实现细节**（`<root>/library/imported/<id>.json`），
 *   让加载器去猜目录结构，等于把两处代码用一个隐式约定绑在一起 ——
 *   改一次布局要同时改两边，且失败方式是"读不到文件"。
 *   这里把规则收在构造参数里，路径只有一个来源。
 *
 * ★ 边界（诚实标注）：texture 加载器交付**元数据 + 原始字节**，不解码像素。
 *   PNG 的 zlib inflate 在浏览器（`createImageBitmap`）与 Node（`zlib`）各有原生实现，
 *   在 L4 手写一份是重复劳动且更慢。像素上传属于 `gfx` 后端的职责。
 */
import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { AssetId, AssetLoadContext, AssetMeta, IAsset, IAssetLoader } from "../../core/asset/asset.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";

export const ImportLoadErrorCode = {
  /** 元数据在库里，但产物文件不在 —— 说明没跑过导入，或 library 被清空。 */
  NoArtifact: "ASSET.NO_ARTIFACT",
  /** 产物存在但内容不合约定（被手改过 / 旧版本格式）。 */
  BadArtifact: "ASSET.BAD_ARTIFACT",
} as const;

interface StoredArtifact {
  readonly type: string;
  readonly importerVersion: number;
  readonly sourceHash: string;
  readonly byteLength: number;
  readonly dependencies: readonly AssetId[];
  readonly data: Record<string, unknown>;
}

// ------------------------------------------------------------------ 资产

/** 贴图资产：只带元数据与原始字节，像素解码交给 gfx 后端。 */
export class ImportedTexture implements IAsset {
  readonly width: number;
  readonly height: number;
  readonly bytes: Uint8Array;
  readonly sourcePath: string;
  readonly bitDepth: number;
  readonly colorType: number;

  constructor(
    readonly id: AssetId,
    readonly type: string,
    meta: { width: number; height: number; bitDepth: number; colorType: number },
    bytes: Uint8Array,
    sourcePath: string,
  ) {
    this.width = meta.width;
    this.height = meta.height;
    this.bitDepth = meta.bitDepth;
    this.colorType = meta.colorType;
    this.bytes = bytes;
    this.sourcePath = sourcePath;
  }

  dispose(): void {
    // 没有 GPU 资源可放（字节由 GC 回收）。若将来这里持有上传后的纹理句柄，
    // 释放必须幂等 —— 契约测试会连调两次。
  }

  get byteLength(): number {
    return this.bytes.byteLength;
  }
}

/** 图集资产：帧表 + 依赖的贴图 id（贴图本体由 `AssetDatabase` 的依赖计数管理）。 */
export class ImportedAtlas implements IAsset {
  constructor(
    readonly id: AssetId,
    readonly type: string,
    readonly frameCount: number,
    readonly textureIds: readonly AssetId[],
  ) {}

  dispose(): void {}
}

/** 文本资产（`.txt/.json/.lua/.md`）：运行时读脚本/配置都走它。 */
export class ImportedText implements IAsset {
  constructor(
    readonly id: AssetId,
    readonly type: string,
    readonly text: string,
    readonly lines: number,
    readonly sourcePath: string,
  ) {}

  dispose(): void {}
}

// ------------------------------------------------------------------ 加载器

function numField(data: Record<string, unknown>, key: string, where: string): Result<number, EngineError> {
  const v = data[key];
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0) {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `${where}: 产物字段 ${key} 不是非负有限数`));
  }
  return ok(v);
}

async function readArtifact(
  fs: IFileSystem,
  root: string,
  id: AssetId,
): Promise<Result<StoredArtifact, EngineError>> {
  const path = `${root.replace(/\/+$/, "")}/library/imported/${id}.json`;
  const r = await fs.readText(path);
  if (!r.ok) {
    return err(
      engineError(
        ImportLoadErrorCode.NoArtifact,
        `资产 ${id} 的导入产物不在（${path}）—— 先跑 AssetImportPipeline.run()，或 library 被清空了`,
        { id, path },
      ),
    );
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(r.value);
  } catch (e) {
    return err(
      engineError(ImportLoadErrorCode.BadArtifact, `产物 ${path} 不是合法 JSON：${e instanceof Error ? e.message : String(e)}`),
    );
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `产物 ${path} 顶层不是对象`));
  }
  const o = parsed as Record<string, unknown>;
  const data = o["data"];
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `产物 ${path} 缺 data 对象`));
  }
  if (typeof o["type"] !== "string") {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `产物 ${path} 缺 type`));
  }
  return ok({
    type: o["type"],
    importerVersion: typeof o["importerVersion"] === "number" ? o["importerVersion"] : 0,
    sourceHash: typeof o["sourceHash"] === "string" ? o["sourceHash"] : "",
    byteLength: typeof o["byteLength"] === "number" ? o["byteLength"] : 0,
    dependencies: Array.isArray(o["dependencies"]) ? (o["dependencies"] as AssetId[]) : [],
    data: data as Record<string, unknown>,
  });
}

/**
 * 造三个加载器（texture / atlas / text）。
 * ★ 同一 `root` 必须与 `AssetImportPipeline` 构造时一致：产物路径由它决定。
 */
export function createImportLoaders(opts: { readonly root: string }): readonly IAssetLoader[] {
  const root = opts.root;

  const texture: IAssetLoader = {
    types: ["texture"],
    async load(meta: AssetMeta, ctx: AssetLoadContext): Promise<Result<IAsset, EngineError>> {
      const a = await readArtifact(ctx.fs, root, meta.id);
      if (!a.ok) return err(a.error);
      const w = numField(a.value.data, "width", `texture ${meta.id}`);
      if (!w.ok) return err(w.error);
      const h = numField(a.value.data, "height", `texture ${meta.id}`);
      if (!h.ok) return err(h.error);
      const bytes = await ctx.fs.readBinary(meta.path);
      if (!bytes.ok) return err(bytes.error);
      const bitDepth = typeof a.value.data["bitDepth"] === "number" ? a.value.data["bitDepth"] : 8;
      const colorType = typeof a.value.data["colorType"] === "number" ? a.value.data["colorType"] : 6;
      return ok(
        new ImportedTexture(meta.id, meta.type, { width: w.value, height: h.value, bitDepth, colorType }, bytes.value, meta.path),
      );
    },
  };

  const atlas: IAssetLoader = {
    types: ["atlas"],
    async load(meta: AssetMeta, ctx: AssetLoadContext): Promise<Result<IAsset, EngineError>> {
      const a = await readArtifact(ctx.fs, root, meta.id);
      if (!a.ok) return err(a.error);
      const frames = numField(a.value.data, "frames", `atlas ${meta.id}`);
      if (!frames.ok) return err(frames.error);
      // 依赖本体由 AssetDatabase 递归加载（meta.dependencies），这里只交付 id 清单：
      // 图集用到的贴图必须已经因为"依赖计数"而驻留，加载器再 load 一次会重复计数。
      void ctx;
      return ok(new ImportedAtlas(meta.id, meta.type, frames.value, a.value.dependencies));
    },
  };

  const text: IAssetLoader = {
    types: ["text"],
    async load(meta: AssetMeta, ctx: AssetLoadContext): Promise<Result<IAsset, EngineError>> {
      const a = await readArtifact(ctx.fs, root, meta.id);
      if (!a.ok) return err(a.error);
      const t = await ctx.fs.readText(meta.path);
      if (!t.ok) return err(t.error);
      // ★ 行数取**产物里的口径**，不在这里重算：末尾换行到底算不算一行，
      //   导入器与加载器各算一次必然会产生两种答案（这类分歧会在编辑器里显示成"对不上"）。
      const lines = numField(a.value.data, "lines", `text ${meta.id}`);
      if (!lines.ok) return err(lines.error);
      return ok(new ImportedText(meta.id, meta.type, t.value, lines.value, meta.path));
    },
  };

  return [texture, atlas, text];
}
