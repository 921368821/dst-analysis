/**
 * L4 · 编辑器：试玩会话（Play-In-Editor session）
 *
 * 「试玩」在编辑器里不是"把时钟打开"那么简单，它有一个**所有权问题**：
 * 试玩期间世界会自己改自己（控制器每 tick 写位置、脚本改组件字段），
 * 而这些改动**不属于文档**。没有会话这一层的话，试玩一次工程就永久变样了 ——
 * 人只会觉得"我点了一下播放，世界就乱了"。
 *
 * 所以这一层只做三件事，每件都对应一类"看起来对、其实很贵"的错：
 *
 * ① **进播放时拍一份快照**。拍在 `pie.play()` **之前** —— 拍在后面的话，
 *   第一帧已经跑过了，回滚回去的是"已经脏了"的状态。
 *
 * ② **停播放时先比文本，一样就不重建**。这条不是为了省时间，是为了保住**对象身份**：
 *   `loadScene` 会 `clear()` 整个场景再重建所有节点（新 `Node` 实例、组件回到出厂值、
 *   `onDetach` 跑一遍）。点一下播放又立刻停 —— 绝大多数时候世界一个字节都没变 ——
 *   却把整个工程换了一遍实例，任何持有 `Node` 引用的地方都会悬空，
 *   而画面上完全看不出来。判据因此必须能区分「没重建」和「重建了但值一样」。
 *
 * ③ **回滚不动撤销栈**。历史里记的是 `nodeId` 与字段的 before/after；
 *   回滚把值恢复到进入试玩那一刻，历史条目仍然是对得上的（同 id 的同一个字段）。
 *   清掉历史反而会让人连"进试玩之前那一步"都退不回去。
 *
 * ★ 这一层不碰 DOM、不认识 GameApp：只拿 `scene / registry`，所以整段逻辑
 *   能在 Node 里逐条钉住（`tests/extensions/editor-play-session.test.ts`）。
 *
 * ★★ **不做的两件事，写在这里免得后来者以为漏了**：
 *   ① 不检查"哪些字段被模拟托管"再拒绝编辑。查过 `ai.mover` / `game.controller`
 *      的 schema：它们的运行期状态明确**不进 schema**（见 `move.ts` 文件头 ⑤），
 *      面板能改到的字段（speed / frame / width…）全是配置，模拟一个都不写。
 *      照着一张空表写拒绝分支 = 永远进不去的分支。
 *   ② 不"逐字段 diff 再挑着回灌"。`loadScene` 是整体重建，逐字段回灌得自己维护
 *      一棵与存档格式并行的影子树 —— 两份字段表迟早给出两个答案。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { ComponentRegistry } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { loadScene, saveScene, sceneToJson, type SceneSnapshot } from "../../core/scene/scene-io.ts";

/** 回滚失败（场景已经被清掉、装不回去了）。这时候工作区不可信，必须说出来。 */
export const EDIT_PIE_ROLLBACK_FAILED = "EDIT.PIE_ROLLBACK_FAILED";

export interface PlaySession {
  /** 进播放那一刻的场景（快照，`loadScene` 直接能用）。 */
  readonly before: SceneSnapshot;
  /** 同一时刻的文档文本，用来判断"这一场试玩有没有改动"，见 ②。 */
  readonly text: string;
  /**
   * 试玩期间改了几个字段。
   *
   * ★ 可变字段是刻意的：它记的是"这一场试玩里发生过什么"，属于会话自己的账，
   *   不是场景的一部分。放进 `PlaySession` 而不是放回宿主，是因为
   *   "停播时报一句改了几个字段"和"回滚"是同一件事的两半，拆开就会有一半被忘掉。
   */
  edits: number;
}

export interface PlayStopReport {
  /** 世界真的被改过、并且已经回滚。`false` = 一个字节都没变，场景没被重建过。 */
  readonly rolledBack: boolean;
  /** 回滚重建出来的节点数（没回滚时是 0）。 */
  readonly made: number;
  /** 回滚时的逐条问题（未知组件等）。**不静默**。 */
  readonly skipped: readonly string[];
}

/** 拍一份会话（**必须在 `pie.play()` / `pie.step()` 之前调**）。 */
export function beginPlaySession(scene: Scene): PlaySession {
  const before = saveScene(scene);
  // 与 `before` 出自同一次读取：再调一次 `saveScene` 会多一遍组件 `save()`
  // （脚本组件的 `save()` 不是免费的），而且两份结果理论上可以不一样。
  return { before, text: sceneToJson(before), edits: 0 };
}

export interface StopDeps {
  readonly scene: Scene;
  readonly registry: ComponentRegistry;
}

/**
 * 结束一次试玩：世界变了就回滚，没变就什么都不做。
 *
 * 失败语义：回滚失败 ⇒ `EDIT.PIE_ROLLBACK_FAILED`，并且**把"场景现在不可信"写在消息里** ——
 * 这时候最糟的处理是静默返回成功，人会接着在半个世界里编辑。
 */
export function endPlaySession(deps: StopDeps, s: PlaySession): Result<PlayStopReport, EngineError> {
  let now: string;
  try {
    now = sceneToJson(saveScene(deps.scene));
  } catch (e) {
    // 导出不该抛（同 `exportDocument` 的注释）：真抛了就当"世界变了"，
    // 宁可多回滚一次，也不要把一个存不下来的场景留在那儿。
    return err(
      engineError(
        EDIT_PIE_ROLLBACK_FAILED,
        `停播时导出场景失败：${e instanceof Error ? e.message : String(e)} —— 工作区不可信`,
      ),
    );
  }
  // 见 ②：一个字节都没变 ⇒ 不重建，保住对象身份
  if (now === s.text) return ok({ rolledBack: false, made: 0, skipped: [] });

  const back = loadScene(deps.scene, s.before, deps.registry);
  if (!back.ok) {
    return err(
      engineError(
        EDIT_PIE_ROLLBACK_FAILED,
        `回滚失败：${back.error.message} —— 工作区现在不可信（先撤销或重新打开文档）`,
        { cause: back.error.code },
      ),
    );
  }
  return ok({ rolledBack: true, made: back.value.made, skipped: back.value.skipped });
}
