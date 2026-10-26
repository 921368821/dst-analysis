/**
 * L4 · 编辑器：工程的落盘（序列化 + 存取）
 *
 * 批90 把"一个工程里多个场景"做出来了，但它只活在内存里 —— 关掉页面工程就没了。
 * 这一层补的就是这件事，只做两件：**把工程变成一段文本**、**把一段文本变回工程**。
 * 不碰 DOM、不认识 localStorage（存储通过 `ProjectStore` 注进来），所以整段能在 Node 里钉住。
 *
 * 三条容易做错、做错了却不报错的事：
 *
 * ① **解析失败必须彻底失败，不许"尽量恢复"**。少一个场景、`current` 指空、名字重复，
 *    都直接拒。半份工程比没有工程糟得多：人看到列表里少了东西，会以为是自己删的。
 *
 * ② **坏存档不许顺手清掉**。读失败时保持原样（`loadProject` 只读不写），
 *    人还能从 localStorage 里把它抠出来修；清掉的后果是"我上次做的三个场景凭空消失了"，
 *    而且没有任何痕迹。
 *
 * ③ **每个失败原因一个错误码**。同一个码挂在两个出口上，就必有一条变异被遮住
 *    （批90 的 M414 就是被自己的防御分支遮成假绿）。所以这里 JSON / FORMAT / VERSION /
 *    SHAPE / CURRENT / DUP / STORE 七个码各管一件事，判据对每个码都点名断言。
 *
 * ★ 不写时间戳：产物要**逐字节可复现**（同一个工程序列化两次必须一字不差），
 *   否则"存了两次内容却不一样"会让判据和人都没法判断到底变没变。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { Project, SceneSlot } from "./project.ts";

/** 产物里的身份标记，用来一眼认出"这是不是编辑器的工程文件"。 */
export const PROJECT_FORMAT = "dst.editor.project";
/** 产物格式版本。**只在结构不兼容地变了时才加**，加了就必须写迁移。 */
export const PROJECT_VERSION = 1;
/**
 * 浏览器 localStorage 的键名。
 *
 * 带 `.v1` 而不是复用 `PROJECT_VERSION`：键名是"存在哪"，版本是"存的是什么"。
 * 混成一个的话，以后升到 v2 就得在两个地方同时改，改漏一个 = 存档静默读不到。
 */
export const PROJECT_STORAGE_KEY = "dst.editor.project.v1";

/** 不是 JSON。 */
export const EDIT_PROJECT_JSON = "EDIT.PROJECT_JSON";
/** 是 JSON，但不是编辑器的工程文件（顶层不是对象 / `format` 不符）。 */
export const EDIT_PROJECT_FORMAT = "EDIT.PROJECT_FORMAT";
/** 是工程文件，但版本这一版不认识。 */
export const EDIT_PROJECT_VERSION = "EDIT.PROJECT_VERSION";
/** 结构不对：`scenes` 不是数组、为空、或某一项缺字段。 */
export const EDIT_PROJECT_SHAPE = "EDIT.PROJECT_SHAPE";
/** `current` 不指向列表里的任何场景。 */
export const EDIT_PROJECT_CURRENT = "EDIT.PROJECT_CURRENT";
/** 两个场景同名。 */
export const EDIT_PROJECT_DUP = "EDIT.PROJECT_DUP";
/** 存储本身坏了（配额满 / 被浏览器禁掉）。 */
export const EDIT_PROJECT_STORE = "EDIT.PROJECT_STORE";

/**
 * 存档介质的最低要求。
 *
 * ★ 故意**不给默认实现**：一个默默把写入失败吞掉的内存实现会让"存上了"这件事
 *   永远看起来成立。写不进去就抛，由 `saveProject` 转成 `EDIT.PROJECT_STORE`。
 */
export interface ProjectStore {
  /** 没存过 ⇒ `null`（不是空串 —— 空串会走解析，然后报"不是 JSON"）。 */
  read(): string | null;
  write(text: string): void;
}

function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * 工程 → 文本。
 *
 * 只抄 `name / text / current` 三个字段，**不抄任何运行时状态**（节点实例、历史、
 * 选中集）。抄了的话存档就成了一份"上一次会话的截图"，而恢复时那些东西一个都用不上。
 */
export function serializeProject(p: Project): string {
  return JSON.stringify({
    format: PROJECT_FORMAT,
    version: PROJECT_VERSION,
    current: p.current,
    scenes: p.scenes.map((s) => ({ name: s.name, text: s.text })),
  });
}

/**
 * 文本 → 工程。失败时**一个字段都不返回**（不是"返回能解析的那部分"）。
 */
export function parseProject(text: string): Result<Project, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return err(engineError(EDIT_PROJECT_JSON, `工程文件不是合法 JSON：${errText(e)}`));
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(engineError(EDIT_PROJECT_FORMAT, "工程文件的最外层必须是一个对象"));
  }
  const o = raw as Record<string, unknown>;
  if (o.format !== PROJECT_FORMAT) {
    return err(
      engineError(EDIT_PROJECT_FORMAT, `这不是编辑器的工程文件（format=${JSON.stringify(o.format)}）`),
    );
  }
  if (o.version !== PROJECT_VERSION) {
    return err(
      engineError(
        EDIT_PROJECT_VERSION,
        `工程文件版本 ${JSON.stringify(o.version)} 这一版不认识（只认 ${String(PROJECT_VERSION)}）`,
      ),
    );
  }
  if (!Array.isArray(o.scenes)) {
    return err(engineError(EDIT_PROJECT_SHAPE, "工程文件的 scenes 必须是数组"));
  }
  if (o.scenes.length === 0) {
    return err(engineError(EDIT_PROJECT_SHAPE, "工程里一个场景都没有 —— 没有文档可编辑"));
  }
  const scenes: SceneSlot[] = [];
  const seen = new Set<string>();
  for (const [i, it] of o.scenes.entries()) {
    if (typeof it !== "object" || it === null) {
      return err(engineError(EDIT_PROJECT_SHAPE, `第 ${String(i + 1)} 个场景不是对象`));
    }
    const { name, text } = it as { name?: unknown; text?: unknown };
    if (typeof name !== "string" || name.length === 0) {
      return err(engineError(EDIT_PROJECT_SHAPE, `第 ${String(i + 1)} 个场景没有名字`));
    }
    if (typeof text !== "string") {
      return err(engineError(EDIT_PROJECT_SHAPE, `场景「${name}」没有文档文本（text 必须是字符串）`));
    }
    if (seen.has(name)) {
      // ★ 重名不是"小瑕疵"：`slotOf` 只返回第一个同名的 ⇒ 切到第二个永远失败，
      //   而列表上明明有两行 —— 与批90「新建名字撞车」是同一个坑的另一头。
      return err(engineError(EDIT_PROJECT_DUP, `场景名「${name}」出现了两次 —— 重名之后切换只会命中第一份`));
    }
    seen.add(name);
    scenes.push({ name, text });
  }
  const current = o.current;
  if (typeof current !== "string" || !seen.has(current)) {
    return err(
      engineError(EDIT_PROJECT_CURRENT, `工程的当前项 ${JSON.stringify(current)} 不在场景列表里`),
    );
  }
  return ok({ scenes, current });
}

/** 把工程写进介质。写不进去 ⇒ `EDIT.PROJECT_STORE`（绝不"报成功"）。 */
export function saveProject(store: ProjectStore, p: Project): Result<{ bytes: number; scenes: number }, EngineError> {
  const text = serializeProject(p);
  try {
    store.write(text);
  } catch (e) {
    return err(engineError(EDIT_PROJECT_STORE, `工程写不进去：${errText(e)}`));
  }
  return ok({ bytes: new TextEncoder().encode(text).length, scenes: p.scenes.length });
}

/**
 * 从介质读工程。`null` = **没存过**（不是错误）。
 *
 * ★ 读失败（介质抛 / 文本坏了）时**不写回、不清档**：只把错误往上递。
 */
export function loadProject(store: ProjectStore): Result<{ project: Project; bytes: number } | null, EngineError> {
  let text: string | null;
  try {
    text = store.read();
  } catch (e) {
    return err(engineError(EDIT_PROJECT_STORE, `工程读不出来：${errText(e)}`));
  }
  if (text === null) return ok(null);
  const parsed = parseProject(text);
  if (!parsed.ok) return err(parsed.error);
  return ok({ project: parsed.value, bytes: new TextEncoder().encode(text).length });
}

/** 内存介质。判据用；编辑器**不用**它（见 `ProjectStore` 上那段注释）。 */
export function memoryStore(init?: string): ProjectStore & { peek(): string | null } {
  let cur: string | null = init ?? null;
  return {
    read: () => cur,
    write: (t: string) => {
      cur = t;
    },
    peek: () => cur,
  };
}
