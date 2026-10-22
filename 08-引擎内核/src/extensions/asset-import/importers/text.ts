/**
 * L4 · 资产导入 · 文本类源文件
 *
 * ★ 为什么 `.json` / `.lua` / `.md` 都走同一个导入器：
 *   对**导入**而言它们只关心"是不是合法 UTF-8、有多少行/字符"；
 *   语义校验（JSON 结构、Lua 语法）属于各自的使用方（图集导入器、脚本运行时），
 *   在这里做会让一个通用文本导入器变成"半个解析器"。
 *
 * ★ 非法 UTF-8 必须**报错**而不是替换成 U+FFFD：
 *   `new TextDecoder("utf-8")` 默认把坏字节静默变成 "�"，
 *   于是"乱码文件"会一路导入成功，等到渲染/脚本执行时才莫名其妙。
 *   `fatal: true` 把问题挡在导入阶段，message 里带文件路径。
 */

import { contentHash } from "../hash.ts";
import type { ImportedArtifact, SourceImporter } from "../importer.ts";
import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import { AssetType } from "../../../core/asset/asset.ts";

const VERSION = 1;

/** `\n` / `\r\n` / `\r` 都算换行；末尾换行不额外算一行（与编辑器显示一致）。 */
function countLines(text: string): number {
  if (text.length === 0) return 0;
  const parts = text.split(/\r\n|\r|\n/);
  if (parts.length > 1 && parts[parts.length - 1] === "") parts.pop();
  return parts.length;
}

/**
 * 码点数（不是 UTF-16 码元数）：中文一个字算 1，emoji 也算 1。
 * 用手写循环而不是 `[...text]`：后者会为整个文件分配一个字符数组，
 * 大 JSON 上白白多一份内存。
 */
function countCodePoints(text: string): number {
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    n++;
    const c = text.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) i++;
    }
  }
  return n;
}

export const textImporter: SourceImporter = {
  id: AssetType.Text,
  version: VERSION,
  extensions: [".txt", ".json", ".lua", ".md"],

  async import(sourcePath, source): Promise<Result<ImportedArtifact, EngineError>> {
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(source);
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      return err(
        engineError("IMPORT.BAD_SOURCE", `${sourcePath}: 不是合法 UTF-8（${why}）`, {
          path: sourcePath,
          importer: "text",
        }),
      );
    }

    return ok({
      type: AssetType.Text,
      dependencies: [],
      byteLength: source.byteLength,
      // ★ 对**磁盘字节**哈希（与管线增量判定的口径完全一致）。
      //   用字符串重新编码再哈希会多一次"解码→编码"的往返，虽然对合法 UTF-8
      //   结果是同一份字节，但依赖这个等价性没有必要。
      sourceHash: contentHash(source),
      importerVersion: VERSION,
      data: {
        lines: countLines(text),
        // 用码点数而不是 UTF-16 长度：中文/emoji 的"字符数"才符合直觉。
        chars: countCodePoints(text),
        encoding: "utf-8",
      },
    });
  },
};
