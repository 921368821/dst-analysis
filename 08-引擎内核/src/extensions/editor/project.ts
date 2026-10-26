/**
 * L4 · 编辑器：工程（一个工程里多个场景）
 *
 * 这一层只做一件事：**把"场景"变成可以互相切换的文档**。但切换这件事有三条容易做错、
 * 而且做错了看不出来的规则：
 *
 * ① **切走之前必须先把当前场景存下来**（`savedFrom`）。动作顺序是「导出源 → 装载目标」，
 *    不能反 —— 反过来导出到的是**目标**场景的内容，源场景最后那次编辑被静默覆盖。
 *    界面上完全看不出来：切换成功、目标也对，只有切回来时才发现"我刚加的节点没了"，
 *    而人会以为是引擎把东西弄丢了。
 *
 * ② **切到同一份场景，一个字节都不动**（`kind: "noop"`）。`loadScene` 的第一件事是
 *    `scene.clear()`，它会把整棵树的 `Node` **实例**换掉：撤销栈、选中集、组件上的
 *    运行时状态、渲染模块里按实例缓存的东西全部作废。所以"点回当前那一行"必须是
 *    零副作用路径 —— 不导出、不装载、不清历史。
 *
 *    ★ 必须说清楚的一件事：**切到"另一个"场景再切回来，实例一定会换。**
 *      `loadScene` 的语义就是"清空 + 重建"（打开一份存档 = 换一份世界），
 *      这是它存在的理由，不是缺陷。所以"不重建节点实例"这条保证只覆盖 noop 路径；
 *      跨场景往返能保证的是**内容逐字节一致** —— 又因为节点 id 写在文档里，
 *      所以 `heroId`、外部记下的 id 在往返之后仍然指向同一个节点。
 *      想连实例都保住，得让每个场景拥有自己的 `Scene` 对象，而 `GameApp.scene` 是
 *      `readonly` 且在构造时注册进了 `Services.Scene` —— 那是"换场景所有权"，
 *      不在这一层的能力范围里，也不该假装做到了。
 *
 * ③ **成功的切换清历史与选中**（复用 `session.ts` 的 `adopt`）：历史条目记的是
 *    `nodeId`，而同一个 id 在另一份文档里指向**另一个节点**；选中集同理。
 *
 * ★ 删除当前场景**不保存**它：保存一个马上就要被丢掉的东西，除了让"已保存"这句话
 *   变得不可信之外没有别的作用。要删它的人已经表达了"不要这份"。
 *
 * ★ 这一层不碰 DOM、不认识 GameApp：只拿 `scene / registry / history / selection`
 *   四个纯对象，所以整段能在 Node 里逐条钉住（`tests/extensions/editor-project.test.ts`）。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import {
  exportDocument,
  newDocument,
  openDocument,
  type OpenReport,
  type SessionDeps,
} from "./session.ts";

/** 工程里没有这个名字的场景（切换/删除时给的具体名字不存在）。 */
export const EDIT_NO_SUCH_SCENE = "EDIT.NO_SUCH_SCENE";
/** 新建时名字撞了已有的场景。 */
export const EDIT_SCENE_EXISTS = "EDIT.SCENE_EXISTS";
/** 只剩一个场景时还要删 —— 工程至少要有一份文档。 */
export const EDIT_LAST_SCENE = "EDIT.LAST_SCENE";
/** 切走前保存源场景失败（导出抛了）。此时**不许动场景**。 */
export const EDIT_SAVE_FAILED = "EDIT.SAVE_FAILED";

/**
 * 工程里的一个场景槽位。
 *
 * `text` 永远是**一份完整文档**（`sceneToJson` 的产物），不留 `null`：
 * "还没保存过"这种状态会让每个读它的地方多一条分支，而新建场景完全可以在
 * 建它的那一刻就导出一次（那时场景已经清空了，导出必然成功）。
 */
export interface SceneSlot {
  name: string;
  text: string;
}

export interface Project {
  scenes: SceneSlot[];
  /** 当前装载在场景里的是哪一份。**一定是 `scenes` 里的某个名字**。 */
  current: string;
}

export interface SwitchReport {
  /** `noop` = 目标就是当前场景，一个字节都没动（节点实例也还是原来那些）。 */
  readonly kind: "noop" | "switched";
  readonly from: string;
  readonly to: string;
  /** 切走前源场景的内容有没有变（`false` = 槽位里已经是最新的，或本来就是 noop）。 */
  readonly savedFrom: boolean;
  readonly made: number;
  readonly skipped: readonly string[];
  readonly droppedHistory: number;
  readonly droppedSelection: number;
}

/**
 * 开一个工程：**必须给一份现成的文档**。
 *
 * 不提供"空工程"：编辑器启动时世界里已经有内容（worldgen 装的），
 * 第一个槽位就应该是那份内容的导出，而不是一个凭空的空文档 ——
 * 后者会让"启动时看到的世界"和"工程里记的场景"从第一秒起就不是同一份。
 */
export function createProject(name: string, text: string): Project {
  return { scenes: [{ name, text }], current: name };
}

/** 场景名（顺序即列表顺序）。 */
export function sceneNames(p: Project): string[] {
  return p.scenes.map((s) => s.name);
}

/** 当前场景**已保存**的那份文档（不是场景里的活内容 —— 那要看 `exportDocument`）。 */
export function currentSceneText(p: Project): string {
  return slotOf(p, p.current)?.text ?? "";
}

function slotOf(p: Project, name: string): SceneSlot | undefined {
  return p.scenes.find((s) => s.name === name);
}

/**
 * 取一个没被占用的名字。
 *
 * ★ 不能写成 `` `场景 ${p.scenes.length + 1}` ``：删掉 [场景1, 场景2, 场景3] 里的
 *   场景 2 之后 `length` 是 2 ⇒ 新名字又是「场景 3」，撞上现存的那个。
 *   撞名之后 `slotOf` 只会返回**第一个**，于是"新建"变成了"切到已有场景"——
 *   而界面上看起来一切正常（列表多了一行、当前项也换了）。
 *   所以按编号**从 1 开始扫描第一个空位**。
 */
export function freeSceneName(p: Project, want?: string): string {
  const trimmed = (want ?? "").trim();
  if (trimmed.length > 0) return trimmed;
  for (let i = 1; i < 10000; i++) {
    const candidate = `场景 ${String(i)}`;
    if (slotOf(p, candidate) === undefined) return candidate;
  }
  return `场景 ${String(p.scenes.length + 1)}`;
}

/** 把当前场景的**活内容**写回它的槽位。 */
export function saveCurrent(deps: SessionDeps, p: Project): Result<{ text: string; changed: boolean }, EngineError> {
  const r = exportDocument(deps);
  if (!r.ok) return err(r.error);
  const slot = slotOf(p, p.current);
  if (slot === undefined) {
    // 结构坏了（`current` 不在列表里）。不静默补一个槽位：那会把"工程记错了"
    // 变成一个看起来正常的工程，之后每次导出都写进一个凭空冒出来的名字里。
    return err(engineError(EDIT_NO_SUCH_SCENE, `工程的当前项「${p.current}」不在场景列表里`));
  }
  const changed = slot.text !== r.value;
  if (changed) slot.text = r.value;
  return ok({ text: r.value, changed });
}

function report(
  kind: SwitchReport["kind"],
  from: string,
  to: string,
  savedFrom: boolean,
  r: OpenReport | null,
): SwitchReport {
  return {
    kind,
    from,
    to,
    savedFrom,
    made: r === null ? 0 : r.made,
    skipped: r === null ? [] : r.skipped,
    droppedHistory: r === null ? 0 : r.droppedHistory,
    droppedSelection: r === null ? 0 : r.droppedSelection,
  };
}

/**
 * 切到 `name`。
 *
 * 顺序是**定死的**，四步各有各的理由：
 *   1. 目标不存在 ⇒ 先拒（不然会在"保存完才发现名字打错"之后留下一次无谓的导出）；
 *   2. 目标就是当前 ⇒ `noop`，一个字节都不动（见文件头 ②）；
 *   3. 保存源场景；失败 ⇒ 立刻返回，**场景一个字节都没动**（半存半切最糟）；
 *   4. 装载目标（`openDocument` 自己保证"先解析后动场景、装载失败用快照回灌"）。
 *      失败时 `current` 不动 —— 场景已经被回灌成源场景，说"当前是目标"就是撒谎。
 */
export function switchScene(deps: SessionDeps, p: Project, name: string): Result<SwitchReport, EngineError> {
  if (name === p.current) return ok(report("noop", p.current, name, false, null));
  const target = slotOf(p, name);
  if (target === undefined) {
    return err(engineError(EDIT_NO_SUCH_SCENE, `工程里没有叫「${name}」的场景`));
  }
  const from = p.current;
  const saved = saveCurrent(deps, p);
  if (!saved.ok) {
    return err(
      engineError(EDIT_SAVE_FAILED, `切走前保存「${from}」失败：${saved.error.message}`, {
        cause: saved.error.code,
      }),
    );
  }
  const opened = openDocument(deps, target.text);
  if (!opened.ok) {
    // 场景被 `session.ts` 回灌成了 `from` 的内容 —— 但槽位里现在存的是**最新的**
    // `from`（第 3 步刚写的），所以"工程 + 场景"仍然是一致的：只是没切成。
    return err(opened.error);
  }
  p.current = name;
  // ★ 目标文本就是刚装载的那份 ⇒ 槽位与场景此刻逐字节一致，不需要再写一次。
  return ok(report("switched", from, name, saved.value.changed, opened.value));
}

/**
 * 新建一个空场景并切过去。
 *
 * ★ 先保存源场景、**成功之后**才把新槽位塞进列表：反过来（先加槽位再保存）的话，
 *   保存失败就得把槽位再删掉 —— 而"删掉刚加的那一项"和"用户按了删除"在列表上
 *   长得一模一样，一旦哪天删错了索引，坏的是别人的场景。
 */
export function createScene(deps: SessionDeps, p: Project, want?: string): Result<SwitchReport, EngineError> {
  const name = freeSceneName(p, want);
  if (slotOf(p, name) !== undefined) {
    return err(engineError(EDIT_SCENE_EXISTS, `已经有一个叫「${name}」的场景了`));
  }
  const from = p.current;
  const saved = saveCurrent(deps, p);
  if (!saved.ok) {
    return err(
      engineError(EDIT_SAVE_FAILED, `新建前保存「${from}」失败：${saved.error.message}`, {
        cause: saved.error.code,
      }),
    );
  }
  const fresh = newDocument(deps);
  if (!fresh.ok) return err(fresh.error);
  // 刚清空的场景导出必然成功（没有节点就没有组件要序列化）。真失败了也不能
  // 把槽位塞进列表 —— 那会让一个空壳场景顶着一个不存在的文档留在这里。
  const text = exportDocument(deps);
  if (!text.ok) {
    return err(engineError(EDIT_SAVE_FAILED, `新场景导出失败：${text.error.message}`, { cause: text.error.code }));
  }
  p.scenes.push({ name, text: text.value });
  p.current = name;
  return ok(report("switched", from, name, saved.value.changed, fresh.value));
}

/**
 * 删掉一个场景（缺省 = 当前场景）。
 *
 * 删**当前**场景时必须先切到邻居：`current` 不能指向一个不存在的名字。
 * 邻居的选择是定死的 —— **后一个，没有就前一个**（列表上"删完这一行、
 * 下一行顶上来"）。写成"随便挑一个"的话，判据只能验"不是空"，验不到选得对不对。
 */
export function deleteScene(deps: SessionDeps, p: Project, name?: string): Result<SwitchReport, EngineError> {
  const target = name ?? p.current;
  const idx = p.scenes.findIndex((s) => s.name === target);
  if (idx < 0) return err(engineError(EDIT_NO_SUCH_SCENE, `工程里没有叫「${target}」的场景`));
  if (p.scenes.length <= 1) {
    return err(engineError(EDIT_LAST_SCENE, "工程里只剩这一个场景了，删掉就没有文档可编辑"));
  }
  if (target !== p.current) {
    // 删的不是当前项：场景不用动，`current` 也不变 —— 这是一条纯列表操作。
    p.scenes.splice(idx, 1);
    return ok(report("noop", p.current, p.current, false, null));
  }
  const from = p.current;
  // ★ 这里不调 `saveCurrent`：要删的就是它。
  //
  // ★★ 邻居用 `!` 而不是再写一条 `=== undefined` 的防御分支 —— 这条注释是判据换来的：
  //   长度已保证 ≥ 2、`idx` 也合法，所以邻居**一定**存在。写上那条分支的后果不是"更安全"，
  //   而是给"删到只剩一个"造出**第二个**返回 `EDIT_LAST_SCENE` 的出口 ⇒
  //   `length <= 1` 那个真守卫坏掉时，变异照样"被抓住"（假绿），
  //   因为防御分支顶了它的位置。这是 M414 第一版的实测结果。
  //   真出现不变量被破坏，这里会在 `next.text` 上**响亮地抛**，而不是静默返回一个错误码。
  const next = (p.scenes[idx + 1] ?? p.scenes[idx - 1])!;
  const opened = openDocument(deps, next.text);
  if (!opened.ok) return err(opened.error);
  p.scenes.splice(idx, 1);
  p.current = next.name;
  return ok(report("switched", from, next.name, false, opened.value));
}
