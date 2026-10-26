/**
 * L4 · 编辑器：文档会话（保存 / 打开 / 新建）
 *
 * 这三个动作看起来只是"调一下 `scene-io`"，但真正容易做错的是**它们对另外两样东西的影响**：
 * 撤销栈和选中集。批77 把这条规则写在注释里（"读档后必须 `history.clear()`"），
 * 却一直**没有调用点** —— 因为编辑器当时还没接读档。这一批把调用点补上，并把三条不变量
 * 变成可执行的东西：
 *
 * ① **打开之前先解析**。`loadScene` 的第一件事是 `scene.clear()`：拿一个坏档直接 load，
 *    会把正在编辑的工程整个吃掉，然后才报"格式错"。所以顺序必须是
 *    解析（`sceneFromJson`）→ 成功才动场景。
 *
 * ② **装载失败要把场景恢复回去**。解析通过但装载中途失败（比如某个组件工厂返回 undefined）
 *    时，场景已经半新半旧了。这时用**打开前拍的快照**回灌 —— 宁可回到旧文档，
 *    也不要把工作区留在"一半是新档、一半是旧档"的状态（那种状态比打不开更糟：
 *    人看不出来，接着编辑就是往混合体上改）。
 *
 * ③ **成功后清空撤销栈与选中集**。历史条目里记的是 `nodeId`，而同一个 id 在新文档里
 *    指向**另一个节点** —— 不清的话，一次"撤销"会悄悄改到别人的节点上，
 *    而且看起来完全正常（值真的变了，只是变错了对象）。
 *
 * ★ 这一层不碰 DOM，也不认识 GameApp：它只拿 `scene / registry / history / selection`
 *   四个纯对象，所以整段逻辑能在 Node 里逐条钉住（`tests/extensions/editor-session.test.ts`）。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { ComponentRegistry } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson, type SceneSnapshot } from "../../core/scene/scene-io.ts";
import type { UndoStack } from "./undo-stack.ts";
import type { Selection } from "./selection.ts";

/** 文档内容本身不成立（不是合法存档 / 版本过新 / 结构错）。 */
export const EDIT_BAD_DOC = "EDIT.BAD_DOC";
/** 文档解析通过了，但装载进场景时失败（组件工厂、id 冲突等）。 */
export const EDIT_LOAD_FAILED = "EDIT.LOAD_FAILED";

export interface SessionDeps {
  readonly scene: Scene;
  readonly registry: ComponentRegistry;
  readonly history: UndoStack;
  readonly selection: Selection;
}

export interface OpenReport {
  /** 装载进去的节点数（含根）。 */
  readonly made: number;
  /** 装载时的逐条问题（未知组件、坏父子关系……）。**不静默**。 */
  readonly skipped: readonly string[];
  /** 被清掉的历史条数（`` = 本来就没有）。 */
  readonly droppedHistory: number;
  /** 被清掉的选中项个数。 */
  readonly droppedSelection: number;
}

/** 当前场景 → 文本（确定性：同一棵树的两次导出逐字节相同）。 */
export function exportDocument(deps: SessionDeps): Result<string, EngineError> {
  try {
    return ok(sceneToJson(saveScene(deps.scene)));
  } catch (e) {
    // 导出不该抛：它被挂在按钮和定时保存上，抛出去就是"按钮点了没反应"。
    return err(engineError(EDIT_BAD_DOC, `导出当前场景失败：${e instanceof Error ? e.message : String(e)}`));
  }
}

/** 接管一份文档：清历史、清选中，并把"清了多少"报出来。 */
function adopt(deps: SessionDeps, made: number, skipped: readonly string[]): OpenReport {
  const droppedHistory = deps.history.history().undo.length;
  // ★ 顺序不重要（两者互不依赖），但**都必须在装载成功之后**：
  //   失败的打开不该把历史清掉 —— 那样人连"刚才那步改错了"都退不回去。
  deps.history.clear();
  const droppedSelection = deps.selection.size;
  deps.selection.clear();
  return { made, skipped, droppedHistory, droppedSelection };
}

/**
 * 把**已解析**的快照装进场景（真正动场景的那一半）。
 *
 * ★ 单独暴露，不并进 `openDocument`：这两件事的失败面完全不同 ——
 *   解析失败时场景一个字节都没动（只要不动就行）；装载失败时场景**已经被 `clear()` 过了**
 *   （必须回灌）。混在一个函数里，第二种情况就没法单独判（判据只能喂文本，
 *   而 `sceneFromJson` 会把 `format` 归一成当前版本 ⇒ `loadScene` 的版本闸门永不触发，
 *   回灌分支变成没人走得到的死代码）。
 *
 * ★ 不假设调用方都过了 `sceneFromJson` 的闸门：宿主完全可能把快照对象直接存在
 *   `localStorage` 里读回来调这里 —— 与 `loadScene` 自己那道版本检查同口径，再查一次。
 */
/** 回灌到 `before`，返回一句给用户看的尾巴（说清楚到底救回来没有）。 */
function restore(deps: SessionDeps, before: SceneSnapshot): string {
  const back = loadScene(deps.scene, before, deps.registry);
  return back.ok ? "已恢复到打开前的场景" : `恢复也失败了（${back.error.code}），工作区不可信`;
}

export function loadDocument(deps: SessionDeps, snap: SceneSnapshot): Result<OpenReport, EngineError> {
  // ★ 快照必须在 `loadScene` 之前拍 —— 它内部第一件事是 `scene.clear()`。
  //   顺序写反（先 load 再拍）时，回灌装回来的是**空场景**：报错看着一样，工作区没了。
  //
  // ★ 这条顺序不是"理论上更好"：`loadScene` 在 `clear()` **之后**还会抛 ——
  //   `scene.flush()` 会跑第三遍装上的组件的 `onAttach`，那里抛出去就穿过整个
  //   `loadScene`（它只把"建节点/设父子"的异常收进 `skipped`）。而版本过新那种
  //   `err` 反而是在 `clear()` **之前**返回的 —— 所以真正需要回灌的，只有这条抛的路径。
  const before = saveScene(deps.scene);
  let loaded: ReturnType<typeof loadScene>;
  try {
    loaded = loadScene(deps.scene, snap, deps.registry);
  } catch (e) {
    // 读档是**不可抛**的边界（与 `scene-io` 里 catch `addChild` 同一口径）：
    // 这个函数被保存/打开按钮直接调用，抛出去就是"点了没反应"，而场景已经半新半旧。
    const why = e instanceof Error ? e.message : String(e);
    return err(engineError(EDIT_LOAD_FAILED, `装载中途抛异常：${why} —— ${restore(deps, before)}`));
  }
  if (!loaded.ok) {
    const tail = restore(deps, before);
    return err(
      engineError(EDIT_LOAD_FAILED, `装载失败：${loaded.error.message} —— ${tail}`, { cause: loaded.error.code }),
    );
  }
  return ok(adopt(deps, loaded.value.made, loaded.value.skipped));
}

/**
 * 打开一份文档文本。
 *
 * 失败时的保证：**场景与它打开之前一模一样**（解析失败时连动都没动；
 * 装载失败时用快照回灌）。历史与选中也不动 —— 打开失败不该产生任何副作用。
 */
export function openDocument(deps: SessionDeps, text: string): Result<OpenReport, EngineError> {
  const parsed = sceneFromJson(text);
  if (!parsed.ok) {
    // 解析就失败：场景一个字节都没动，直接透传更具体的错误码（FORMAT_TOO_NEW 等）
    return err(engineError(EDIT_BAD_DOC, `这份文档打不开：${parsed.error.message}`, { cause: parsed.error.code }));
  }
  return loadDocument(deps, parsed.value);
}

/**
 * 新建一份空文档（只留场景根）。
 *
 * ★ 不做"先问一句要不要保存"：那是 UI 的事，这一层只保证**清干净**。
 *   真正要防的是"新建之后还能撤销回上一份文档" —— 那等于把两份文档混在一条历史里。
 */
export function newDocument(deps: SessionDeps): Result<OpenReport, EngineError> {
  // ★ 名字是 `Scene` 的只读字段（它属于"这个场景是什么"，不属于"编辑器现在开着什么"），
  //   所以这里不改名 —— 想改名是宿主的事，不是"新建文档"的副作用。
  const before = saveScene(deps.scene);
  try {
    deps.scene.clear();
  } catch (e) {
    const back = loadScene(deps.scene, before, deps.registry);
    const tail = back.ok ? "已恢复原场景" : `恢复也失败了（${back.error.code}）`;
    return err(engineError(EDIT_LOAD_FAILED, `新建失败：${e instanceof Error ? e.message : String(e)} —— ${tail}`));
  }
  // `made: 0` 而不是 1：根节点**不在存档记录里**（`collectNodes` 明确排除它），
  // 所以"新建"实际装进去的记录是 0 条 —— 报 1 会让人以为凭空多了一个节点。
  return ok(adopt(deps, 0, []));
}

/**
 * 把一份文档"另存后重新打开"—— 往返一次，用来验证导出的东西自己读得回来。
 *
 * 单独写出来不是为了省两行：往返是**唯一**能证明"导出格式与导入格式是同一个口径"的判据，
 * 而这两个方向在两个函数里，很容易一边加字段另一边没跟上。
 */
export function roundTrip(deps: SessionDeps): Result<OpenReport, EngineError> {
  const text = exportDocument(deps);
  if (!text.ok) return err(text.error);
  return openDocument(deps, text.value);
}
