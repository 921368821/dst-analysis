/**
 * L4 · 树资产装载（`.tree.json` → `TreeLibrary`）—— 批156
 *
 * 批155 让树能存成文件、能被组件按 id 引用、缺 id 时会被数出来。但**没有人把文件送进库**：
 * `TreeLibrary.put` 一直是测试在直接调。于是 demo 里"配一棵树"的终点仍然是
 * 「在源码里 `library.put(...)`」，而策划改不了任何东西。
 *
 * 这个文件就是那一段：**一批路径 → 一批已校验的树**，并如实报告哪几个没装上。
 *
 * ★★ 五个决定：
 *
 * ① **一个坏文件不阻断整批**。设计方案里第一版是"任何失败就整体失败"，
 *    理由听着很正当（配置错误要当场炸）。但真实形状是：策划改了五棵树里的第三棵，
 *    存了个半成品。整体失败 ⇒ 五棵树全没装上 ⇒ 世界里**所有**生物退回内置树 ——
 *    症状是"怪突然都变笨了"，而真正的原因只是某个文件少了个括号。
 *    所以：能装的装，装不上的进 `failed` 并被计数。
 *    ★ 与此配套的是**必须有人说出来**：`failed` 不是日志，它是返回值
 *      （宿主把它接到面板与 `ai n/m` 上，判据钉住非空）。
 *
 * ② **失败必须带路径**，不只是一个错误码。`AI_TREE.BAD_ASSET` 单独出现时
 *    人不知道去改哪个文件 —— 而"哪个文件"正是这条报告的全部用处。
 *
 * ③ **同一批里 id 撞车 ⇒ 后者失败，先到的保留**（`AI_TREE.DUPLICATE_ID`）。
 *    路径推 id 之后两只文件撞 id 只能来自大小写或根前缀算错，而**静默覆盖**的
 *    唯一症状是"我改的那棵没生效"（因为生效的是另一只文件）。
 *    ★ 跨批次重复**不是**错误：那是热重载（`put` 覆盖 + revision++），
 *      也就是编辑器"保存后立刻重载"要走的路。所以"重复"只在**这一批内部**判定。
 *
 * ④ **按路径升序处理**，报告里的 `ids` 也升序。装载顺序决定"撞车时谁先到"，
 *    而不确定的顺序会让同一个 bug 时有时无。
 *
 * ⑤ **不碰 IO**：`read` 由调用方注入（`fs.readText`）。于是判据不需要真文件系统，
 *    浏览器走 `HttpFileSystem`、小游戏走自己的盘、编辑器走内存盘 —— 同一段代码。
 *    ★ 反过来（在库里 `fetch`）会让"装载"变成不可测的一步，而它恰恰是最该有判据的一步。
 */

import { engineError, type EngineError, type Result } from "../../foundation/result.ts";
import type { AssetId } from "../../core/asset/asset.ts";
import { treeAssetIdFromPath } from "./tree-asset.ts";
import type { TreeLibrary } from "./tree-library.ts";

/** 同一批里两份文件推出同一个 id（见文件头 ③）。 */
export const AI_TREE_DUPLICATE_ID = "AI_TREE.DUPLICATE_ID";

/** 一份没装上的树（见文件头 ②：路径是这条报告的**主要**内容）。 */
export interface TreeLoadFailure {
  readonly path: string;
  /** `AI_TREE.*` / `AI.UNKNOWN_OP` / `FS.NOT_FOUND` …… 原样透出，不在这里重编号。 */
  readonly code: string;
  readonly message: string;
}

export interface TreeLoadReport {
  /** 这一批真的装上了几棵（= `ids.length`）。 */
  readonly loaded: number;
  /** 装上的树 id（升序）。 */
  readonly ids: readonly AssetId[];
  /** 没装上的（按路径升序）。空数组 = 全部成功。 */
  readonly failed: readonly TreeLoadFailure[];
}

/** 一份"已经读到手的"树资产（路径 + 文本）。 */
export interface TreeTextEntry {
  readonly path: string;
  readonly text: string;
}

export interface TreeLoadOptions {
  /** 资产根（`assets` / `assets/ai`）。给了就从 id 里剥掉，见 `treeAssetIdFromPath` ③。 */
  readonly root?: string;
}

function fail(path: string, e: EngineError): TreeLoadFailure {
  return { path, code: e.code, message: e.message };
}

function sortedBy<T>(items: readonly T[], key: (t: T) => string): T[] {
  return [...items].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
}

/**
 * 一批**文本** → 库（同步、纯：不读盘、不读时钟）。
 *
 * 这是装载逻辑的唯一一份；`loadTreeFiles` 只是"先读一遍"再调它。
 *
 * ★ op 表**不从参数给**：它属于库（`new TreeLibrary({ops})` 定下），不属于这一批文件。
 *   两处都能给的话，"同一个库里两批树用不同词汇"就成了一种可表达的状态 ——
 *   而它没有任何合理解释，只会让"这棵树为什么装着的时候好好的、跑起来却抛"多一个来源。
 */
export function loadTreeTexts(
  library: TreeLibrary,
  entries: readonly TreeTextEntry[],
  opts: TreeLoadOptions = {},
): TreeLoadReport {
  const ids: AssetId[] = [];
  const failed: TreeLoadFailure[] = [];
  /** 这一批已经用掉的 id（见文件头 ③）。 */
  const taken = new Map<AssetId, string>();
  for (const entry of sortedBy(entries, (e) => e.path)) {
    const idR = treeAssetIdFromPath(entry.path, opts.root ?? "");
    if (!idR.ok) {
      failed.push(fail(entry.path, idR.error));
      continue;
    }
    const id = idR.value;
    const owner = taken.get(id);
    if (owner !== undefined) {
      failed.push(
        fail(
          entry.path,
          engineError(
            AI_TREE_DUPLICATE_ID,
            `「${entry.path}」与「${owner}」推出同一个树 id「${id}」—— 保留先到的那个`,
            { id, path: entry.path, first: owner },
          ),
        ),
      );
      continue;
    }
    const put = library.putText(id, entry.text);
    if (!put.ok) {
      failed.push(fail(entry.path, put.error));
      continue;
    }
    taken.set(id, entry.path);
    ids.push(id);
  }
  return { loaded: ids.length, ids: sortedBy(ids, (s) => s), failed };
}

/**
 * 一批**路径** → 库（异步：读一遍再交给 `loadTreeTexts`）。
 *
 * `read` 的失败形状与别处一致（`Result`，不是抛）：静态资源服务器上的 404
 * 是一个**正常的**结果，而"读不到"与"装不上"要进同一份 `failed` 报告 ——
 * 分成两处报的话，调用方总有一处会忘。
 */
export async function loadTreeFiles(
  library: TreeLibrary,
  paths: readonly string[],
  read: (path: string) => Promise<Result<string, EngineError>>,
  opts: TreeLoadOptions = {},
): Promise<TreeLoadReport> {
  const entries: TreeTextEntry[] = [];
  const failed: TreeLoadFailure[] = [];
  for (const path of sortedBy(paths, (p) => p)) {
    const r = await read(path);
    if (!r.ok) {
      failed.push(fail(path, r.error));
      continue;
    }
    entries.push({ path, text: r.value });
  }
  const fromText = loadTreeTexts(library, entries, opts);
  // 读失败的排在解析失败的**前面**：它们先发生，报告的顺序应当与发生的顺序一致
  return {
    loaded: fromText.loaded,
    ids: fromText.ids,
    failed: [...failed, ...fromText.failed],
  };
}

/** 报告是不是"全部装上了"（`failed.length === 0` 的**显式**说法，宿主用）。 */
export function treesLoadedClean(report: TreeLoadReport): boolean {
  return report.failed.length === 0;
}

/** 把报告压成一行面板文案（ASCII；见 `mob-inspector.ts` ③ 的同一条理由）。 */
export function treeLoadShort(report: TreeLoadReport): string {
  if (report.failed.length === 0) return `trees ${String(report.loaded)}`;
  return `trees ${String(report.loaded)}/${String(report.failed.length)}`;
}
