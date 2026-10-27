/**
 * L4 · 关卡流程：游戏存档（"我在哪一关 + 这一局走成什么样"）
 *
 * 这一层只做**格式**：把「当前场景名 + 若干份场景文档」编成一段文本、再解回来。
 * 它不碰 `Scene`、不认识注册表 —— 装载那一步在 `scene-flow.ts`，
 * 因为"读进世界"失败要回滚，而回滚需要世界本身。
 *
 * ★★ 为什么存档要自带**每一份场景文档**，而不是只记一个场景名：
 *   只记名字的话，读档时得回到工程槽位去取文档 —— 那是**作者写的原始场景**，
 *   不是"我这一局把它弄成的样子"（砍倒的树、杀掉的怪、丢在地上的东西全回来了）。
 *   存档记的是**进度**，工程记的是**设计**，两者的区别就是这一层存在的原因。
 *
 * ★ 为什么键序要固定、场景要按名字升序：存档的承诺与场景档一样是"逐字节可比"
 *   （`tests/backends/save-cross-host.test.ts` 那一套）。按 `Map` 插入序写的话，
 *   同一局"先去过 A 再去过 B"和"先去 B 再去 A"会产出两段不同的字节 ——
 *   而它们的语义完全相同，于是任何"两份档是不是同一局"的判断都会误报。
 *
 * ★ 校验分成两层，故意不合并：
 *   - 这里查**结构**（是不是 JSON / 版本 / 当前场景在不在 / 名字重不重）；
 *   - `scene-flow.ts` 查**内容**（每份文档能不能解析、当前场景有没有玩家）。
 *   结构错了连"该读哪一份"都不知道，只能整份拒绝；内容错了还能说出是哪一份。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 存档格式版本。加字段要升版本 + 写迁移（见 `core/serialization/schema.ts` 的口径）。 */
export const GAME_SAVE_FORMAT = 1;

/** 存档结构不合法（不是 JSON / 版本太新 / 当前场景不在 scenes 里 / 场景重名）。 */
export const FLOW_BAD_SAVE = "FLOW.BAD_SAVE";

export interface GameSaveScene {
  readonly name: string;
  readonly doc: string;
}

export interface GameSave {
  readonly format: number;
  readonly current: string;
  readonly scenes: readonly GameSaveScene[];
}

/** 名字比较：**不用 `localeCompare`** —— 它随宿主语言环境变，会让"同一局"在两个机器上字节不同。 */
function cmpName(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function bad(message: string): EngineError {
  return engineError(FLOW_BAD_SAVE, message);
}

/**
 * 把「当前场景 + 场景名→文档」编成一段文本。
 *
 * `docs` 里**必须**包含 `current`（否则读回来是个没世界的档）；缺了就在这里抛，
 * 不生成一份"看起来正常、读的时候才炸"的档 —— 写坏了应该在写的时候就知道。
 */
export function encodeGameSave(current: string, docs: ReadonlyMap<string, string>): string {
  if (!docs.has(current)) {
    throw new Error(`存档缺当前场景「${current}」的文档 —— 拒绝生成一份读不回来的档`);
  }
  const names = [...docs.keys()].sort(cmpName);
  const scenes: GameSaveScene[] = names.map((name) => ({ name, doc: docs.get(name) ?? "" }));
  // 对象字面量的键序就是输出顺序（三个键都不是数组下标形式，不会被引擎重排）
  return JSON.stringify({ format: GAME_SAVE_FORMAT, current, scenes });
}

/**
 * 解一段存档文本。**只查结构**，世界一个字节都不动。
 *
 * 所有失败都归到 `FLOW.BAD_SAVE` 一个码上，但 `message` 必须说清是哪一条 ——
 * 分成五个错误码看着更细，实际上调用方只会显示一句话，而"多写四个码"的代价是
 * 每一处 `switch` 都要跟着加分支。
 */
export function decodeGameSave(text: string): Result<GameSave, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text) as unknown;
  } catch (e) {
    return err(bad(`存档不是 JSON：${e instanceof Error ? e.message : String(e)}`));
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(bad("存档不是一个对象（顶层应该是 {format, current, scenes}）"));
  }
  const o = raw as Record<string, unknown>;

  const format = o["format"];
  if (typeof format !== "number" || !Number.isInteger(format) || format < 1) {
    return err(bad("存档缺少合法的 format（正整数）"));
  }
  if (format > GAME_SAVE_FORMAT) {
    return err(
      bad(`存档格式 v${String(format)} 高于引擎支持的 v${String(GAME_SAVE_FORMAT)}（用新版本存的档，旧版本读不了）`),
    );
  }

  const current = o["current"];
  if (typeof current !== "string" || current.length === 0) {
    return err(bad("存档没写「当前在哪个场景」（current 为空）"));
  }

  const rawScenes = o["scenes"];
  if (!Array.isArray(rawScenes) || rawScenes.length === 0) {
    return err(bad("存档里一份场景都没有（scenes 为空）"));
  }

  const scenes: GameSaveScene[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < rawScenes.length; i++) {
    const item = rawScenes[i] as unknown;
    if (typeof item !== "object" || item === null || Array.isArray(item)) {
      return err(bad(`第 ${String(i + 1)} 份场景不是一个对象`));
    }
    const rec = item as Record<string, unknown>;
    const name = rec["name"];
    const doc = rec["doc"];
    if (typeof name !== "string" || name.length === 0) {
      return err(bad(`第 ${String(i + 1)} 份场景没有名字`));
    }
    // ★ 重名必须拒，不能"后一份覆盖前一份"：两份都是这一局的世界，
    //   悄悄丢掉一份等于读档之后少了一整块进度，而看上去一切正常。
    if (seen.has(name)) {
      return err(bad(`存档里有重复的场景「${name}」—— 不知道哪一份才是这一局的`));
    }
    seen.add(name);
    if (typeof doc !== "string" || doc.length === 0) {
      return err(bad(`场景「${name}」的文档是空的`));
    }
    scenes.push({ name, doc });
  }

  if (!seen.has(current)) {
    return err(bad(`存档说当前在「${current}」，但 scenes 里没有这一份`));
  }

  return ok({ format: GAME_SAVE_FORMAT, current, scenes });
}
