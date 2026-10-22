/**
 * L4 · 资产导入 · 导入器契约
 *
 * ★ 为什么要一个注册表，而不是 `switch (ext)`：
 *   扩展点必须在**配置期**可枚举（一条线加格式不动核心），
 *   同时"同扩展名两个导入器"必须是**配置错误**（启动即崩），
 *   而不是运行时"谁先注册谁赢" —— 后者会让行为依赖加载顺序。
 *
 * ★ 为什么 `version` 是导入器自己的字段而不是全局版本号：
 *   改了 PNG 头解析只该让 `.png` 重导，不该让整个工程的音频/文本全重导。
 *   增量判定用"产物里的版本 vs 当前导入器版本"（见 pipeline）。
 *
 * ★ 为什么 `ImportedArtifact.dependencies` 是数组而不是 Set：
 *   **顺序决定依赖加载顺序**。图集里先声明哪张图，加载就先加载哪张；
 *   用 Set 会把"声明顺序"这个确定性来源丢掉。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import type { ChannelLogger } from "../../foundation/log/logger.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";
import type { AssetId } from "../../core/asset/asset.ts";

export interface ImportContext {
  readonly fs: IFileSystem;
  readonly root: string;
  readonly log: ChannelLogger;
  /**
   * 相对**当前源文件**解析兄弟路径（支持 `../`）。
   * 返回的是工程内的逻辑路径（可能带 scheme），可直接交给 `fs`；
   * `..` 在**这里**按词法消解，因为某些 fs 实现（如内存盘）会拒绝 `..`
   * 而不是"聪明地"夹到根 —— 那是刻意的安全边界，导入器不该绕过它。
   */
  resolveSibling(relPath: string): string;
  /**
   * 已扫描到的兄弟文件的 id（第一遍收集的 id 表）。
   * 入参与 `resolveSibling` 一致：相对**当前源文件**的路径。
   * 返回 undefined 表示"这个依赖不在本轮扫描结果里" —— 由调用方决定
   * 报 `IMPORT.MISSING_DEPENDENCY`，而不是在这里吞掉。
   */
  lookupId(relPath: string): AssetId | undefined;
}

export interface ImportedArtifact {
  readonly type: string;
  /** 有序：声明顺序就是加载顺序。 */
  readonly dependencies: readonly AssetId[];
  readonly byteLength: number;
  readonly sourceHash: string;
  readonly importerVersion: number;
  readonly data: Readonly<Record<string, unknown>>;
}

export interface SourceImporter {
  /** 同时作为资产的 `type`（`.meta` 里写的就是它）。 */
  readonly id: string;
  /** ★ 改导入逻辑必须 +1，否则已有产物不会重导。 */
  readonly version: number;
  /** 负责的扩展名（小写，带前导点）：`[".png"]` / `[".atlas.json"]`。 */
  readonly extensions: readonly string[];
  import(
    sourcePath: string,
    source: Uint8Array,
    settings: Readonly<Record<string, unknown>>,
    ctx: ImportContext,
  ): Promise<Result<ImportedArtifact, EngineError>>;
}

function normalizeExtension(ext: string): string {
  const e = ext.toLowerCase();
  if (!e.startsWith(".") || e.length < 2) {
    throw new Error(`导入器扩展名必须形如 ".png"（带前导点），实际收到 "${ext}"`);
  }
  return e;
}

export class ImporterRegistry {
  private readonly byExtension = new Map<string, SourceImporter>();

  /**
   * 注册。同扩展名重复注册 → **throw**。
   * 这是配置错误（两条线各自加了一个 `.json` 导入器），不是运行时状况；
   * 用 Result 返回只会让它被忽略，然后在运行时表现为"某类文件用了错的导入器"。
   */
  register(i: SourceImporter): void {
    for (const raw of i.extensions) {
      const ext = normalizeExtension(raw);
      const prev = this.byExtension.get(ext);
      if (prev !== undefined) {
        throw new Error(
          `扩展名 "${ext}" 已由导入器 ${prev.id} 注册，不能再给 ${i.id}（配置错误：同一扩展名只能有一个导入器）`,
        );
      }
      this.byExtension.set(ext, i);
    }
  }

  /**
   * 找导入器：大小写不敏感，**最长后缀优先**。
   * `.atlas.json` 必须赢过 `.json` —— 否则图集会先被当作文本导进去，
   * 依赖永远解析不出来。
   */
  find(sourcePath: string): SourceImporter | undefined {
    const p = sourcePath.toLowerCase();
    let best: SourceImporter | undefined;
    let bestLen = -1;
    for (const [ext, imp] of this.byExtension) {
      if (p.endsWith(ext) && ext.length > bestLen) {
        best = imp;
        bestLen = ext.length;
      }
    }
    return best;
  }

  /** 诊断用：已注册的扩展名（排序后），报 `IMPORT.NO_IMPORTER` 时带上。 */
  extensions(): readonly string[] {
    return Array.from(this.byExtension.keys()).sort();
  }
}
