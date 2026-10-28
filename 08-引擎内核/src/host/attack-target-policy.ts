/**
 * 演示世界"这一下能打谁"的策略（批123 从 `browser-entry.ts` 抽出来）。
 *
 * ★ 为什么单独一个文件：这是**玩法判断**（谁算候选目标），玩法判断必须能被单测
 *   钉住。写在 `browser-entry.ts` 里就是"只有浏览器能验它" —— 而浏览器判据的
 *   分辨力依赖于**演示世界里恰好存在的东西**，那是本项目明令禁止的依赖
 *   （「判据不许依赖世界的自发活动」）。抽成纯函数之后，四条拒绝理由各自
 *   有毫秒级的 Node 判据，不再赌场景里有没有一具站着的尸体。
 *
 * ★★ 抽出来的直接原因（如实记）：批123 给玩家击杀补了"当场撤掉死掉的节点"
 *   （`attackNearest` 里 `scene.destroy` + 尸体落地），于是演示里不再有
 *   "站着的尸体"——`if (isDead(h)) continue;` 那一行在浏览器里**再也等不到
 *   它的语料**。变异 M314（删掉这一行）因此从"咬得住"退化成了等价变异，
 *   CI 报「判据假绿」。那不是判据写窄了，是**这一行没了可观察的出口**：
 *   要继续咬住它，只能给它一条不依赖世界的判据 —— 也就是这个文件。
 *
 * ★★★ 四条理由分开返回（而不是一个 `boolean`），是这一批栽过的同一个坑的
 *   另一面：把四个条件与在一起，**任何一个不成立都是同一个现象**
 *   （"打不到"），诊断只能靠猜。批123 的浏览器判据就是被那个 `&&` 坑掉的。
 *   返回理由码，判据才能一条一条钉，宿主也能把理由说出来。
 */

/** 不能当攻击候选的理由码。`null` = 可以打。 */
export type AttackReject =
  /** 拿自己当目标。 */
  | "self"
  /** 节点（或它的祖先）没激活 —— 逻辑上还在，画面上没有。 */
  | "inactive"
  /** 血量已经见底。★ 见文件头 ★★：批123 之后这条在演示里不常出现，
   *  但它是**选择侧**的规矩（`health.ts` 的文案自己说"打尸体通常是目标
   *  选择出错"），别的宿主/别的路径照样会把死节点留在场景里。 */
  | "dead"
  /** 同队（`MOB_FACTIONS` 的关系表算出来的）。 */
  | "ally";

/** 判断一个候选需要的全部信息 —— 都是宿主**已经算好**的原语，本函数不读场景。 */
export interface AttackCandidateInfo {
  /** 攻击者自己的 nodeId（用来排除"打自己"）。 */
  selfId: number;
  /** 这个候选的 nodeId。 */
  id: number;
  /** `activeInHierarchy`。 */
  active: boolean;
  /** 血量是否已经见底。 */
  dead: boolean;
  /** 关系表判定的"同队"（调用方用 `stanceOf(myTeam, itsTeam) === "ally"` 算）。 */
  isAlly: boolean;
}

/**
 * 这一下能不能打它：能打返回 `null`，不能打返回理由码。
 *
 * 判定顺序（先便宜的、先确定的）：自己 → 未激活 → 死 → 盟友。
 * ★ 顺序写死在这里而不是散在循环里：散着写的时候，"盟友也死了"到底报哪个理由
 *   取决于代码行的先后，判据与日志会各说一套。
 */
export function whyNotAttackable(info: AttackCandidateInfo): AttackReject | null {
  if (info.id === info.selfId) return "self";
  if (!info.active) return "inactive";
  if (info.dead) return "dead";
  if (info.isAlly) return "ally";
  return null;
}
