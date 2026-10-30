/**
 * L4 · 决策树库 —— `AssetId` → 树 的**同步**解析
 *
 * 为什么需要这一层：资产的装载是异步的（`AssetDatabase.load` 返回 Promise），
 * 而生物每拍都要问「我这只用的哪棵树」。在 `decide` 里 `await` 一次是做不到的
 * （决策是同步纯函数，且一帧要问几十次）。
 *
 * 所以边界划在这里：
 *   · **资产系统**负责 IO / 依赖 / 引用计数（`core/asset/asset.ts`）；
 *   · **本库**只管「id → 已校验的树」，同步、无 IO、可被决策路径直接调用。
 * 谁来把内容送进来？导入器 / 编辑器 / 宿主启动时 —— 都有一个明确的时刻，
 * 而「每拍去磁盘找一下」不该是决策路径的一部分。
 *
 * ★★ 三个决定：
 *
 * ① **`put` 就是校验点**：坏树进不来。于是「世界里跑着一棵坏树」在类型与流程上都不可能，
 *    而不是靠"希望调用方先校验"。返回 `Result` 而不是抛：装载一份配置是**可失败的正常操作**
 *    （策划刚存了个半成品），而 `createMobTree` 的抛是**程序错误**（树已经校验过还跑不起来）。
 *
 * ② **`revision` 是缓存失效的唯一信号**。`MobBrain` 缓存 `id → MobTree` 实例（省掉每拍
 *    重新编译树），而热重载改了树之后必须让缓存作废。用 `revision` 而不是比内容：
 *    比内容要么慢（序列化），要么漏（只比根节点）。
 *    ★ 反过来的坑也在这里：`revision` 只在**成功** `put` / `remove` 时变，
 *      失败的那次不改库、也不改 revision —— 否则一次坏配置会把所有怪的无谓重编译一遍。
 *
 * ③ **缺 id 不抛、但要能被数出来**（`resolve` 返回 `source: "missing"`）。
 *    一只怪的树被删了不该让整局崩，但也绝不能"看起来正常"：调用方会把它记进统计，
 *    面板上标 `missing`，判据钉住「用了默认树」这件事本身。
 *    这是本仓库的「半条链」纪律：降级路径必须有面板 + 计数 + 判据三件套。
 */

import type { AiNode, AiOps } from "../ai/behavior.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { AssetId } from "../../core/asset/asset.ts";
import { AI_TREE_BAD_ASSET, checkTree, parseTreeAsset, serializeTreeAsset } from "./tree-asset.ts";
import { MOB_OPS, MOB_TREE } from "./mob-tree.ts";

/**
 * 内置树的 id。
 *
 * ★ 不用空串当键：空串在组件里表示「没配」（沿用 `FieldType.Asset` 的零值），
 *   两件事必须能分开 —— 「默认树」是一个真实存在的树，「没配」是一个引用状态。
 *   合成一个的话，面板上分不清「这只用的是内置树」还是「这只的树丢了」。
 */
export const DEFAULT_TREE_ASSET: AssetId = "builtin:mob";

export type TreeSource = "asset" | "default" | "missing";

export interface TreeLookup {
  /** 实体要的 id（`""` = 没配）。 */
  readonly wanted: AssetId;
  /** 实际用的树的 id（缺 id 时就是内置树）。 */
  readonly id: AssetId;
  readonly tree: AiNode;
  /**
   * `asset` = 命中资产；`default` = 没配（正常）；`missing` = 配了但库里没有（**要报警**）。
   */
  readonly source: TreeSource;
}

export interface TreeLibraryStats {
  readonly trees: number;
  readonly revision: number;
}

/** FNV-1a 32 位（与 `stableIdFromPath` 同族；这里只要稳定，不要密码学）。 */
function fnv(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(36).padStart(7, "0");
}

export class TreeLibrary {
  private readonly trees = new Map<AssetId, AiNode>();
  private readonly ops: AiOps;
  private revisionCount = 0;

  constructor(opts: { readonly ops?: AiOps; readonly defaultTree?: AiNode } = {}) {
    this.ops = opts.ops ?? MOB_OPS;
    // 内置树也要过一遍校验：它是代码常量，但自定义 ops 下它可能引用不存在的 op
    const builtin = opts.defaultTree ?? MOB_TREE;
    const checked = checkTree(builtin, this.ops);
    if (!checked.ok) {
      throw new RangeError(`${AI_TREE_BAD_ASSET}: 内置树不合法 —— ${checked.error.code}：${checked.error.message}`);
    }
    this.trees.set(DEFAULT_TREE_ASSET, builtin);
  }

  /** 库变过几次（见文件头 ②）。只增不减。 */
  get revision(): number {
    return this.revisionCount;
  }

  /** 装/换一棵树。**校验在这里**（见文件头 ①）。 */
  put(id: AssetId, tree: AiNode): Result<void, EngineError> {
    if (typeof id !== "string" || id.length === 0) {
      // 见 `DEFAULT_TREE_ASSET` 的 ★：空串是「没配」，不能当键
      return err(engineError(AI_TREE_BAD_ASSET, "树的资产 id 不能是空串（空串表示「没配」，见 DEFAULT_TREE_ASSET）"));
    }
    if (id.trim().length === 0) {
      return err(engineError(AI_TREE_BAD_ASSET, "树的资产 id 不能是纯空白 —— 那是一个看不见的 id"));
    }
    const checked = checkTree(tree, this.ops);
    if (!checked.ok) return err(checked.error);
    this.trees.set(id, tree);
    this.revisionCount++;
    return ok(undefined);
  }

  /** 从资产文本装载（解析 + 校验 + 存）。 */
  putText(id: AssetId, text: string): Result<void, EngineError> {
    const parsed = parseTreeAsset(text, this.ops);
    if (!parsed.ok) return err(parsed.error);
    return this.put(id, parsed.value);
  }

  /** 删一棵树（资产被删）。内置树删不掉 —— 它是「没配」的落点。 */
  remove(id: AssetId): boolean {
    if (id === DEFAULT_TREE_ASSET) return false;
    const had = this.trees.delete(id);
    if (had) this.revisionCount++;
    return had;
  }

  has(id: AssetId): boolean {
    return this.trees.has(id);
  }

  get(id: AssetId): AiNode | undefined {
    return this.trees.get(id);
  }

  /** 库里全部 id（升序；含内置树）。 */
  ids(): readonly AssetId[] {
    return [...this.trees.keys()].sort();
  }

  /**
   * 解析一个引用（**纯的**：不改库、不改 revision）。
   *
   * 缺 id 不抛（见文件头 ③）：返回内置树 + `source: "missing"`，由调用方决定怎么报警。
   */
  resolve(id: AssetId): TreeLookup {
    if (id === "") {
      return { wanted: "", id: DEFAULT_TREE_ASSET, tree: this.trees.get(DEFAULT_TREE_ASSET)!, source: "default" };
    }
    const tree = this.trees.get(id);
    if (tree !== undefined) return { wanted: id, id, tree, source: "asset" };
    return { wanted: id, id: DEFAULT_TREE_ASSET, tree: this.trees.get(DEFAULT_TREE_ASSET)!, source: "missing" };
  }

  /**
   * 内容指纹（升序 id + 规范序列化）。
   *
   * 用途：证「换了一棵树」与「换回来」是可判定的两件事；也能进世界指纹
   * （同一场景 + 同一批树 = 同一局，否则回放会在 AI 上分叉）。
   */
  fingerprint(): string {
    const parts: string[] = [];
    for (const id of this.ids()) parts.push(`${id}=${serializeTreeAsset(this.trees.get(id)!)}`);
    return fnv(parts.join("\u0000"));
  }

  stats(): TreeLibraryStats {
    return { trees: this.trees.size, revision: this.revisionCount };
  }
}
