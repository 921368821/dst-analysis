/**
 * L4 · 输入映射表（动作名 → 按键）
 *
 * ★ 为什么"键位写在代码里"不够：
 *   ① 键位是**玩法配置**，不是实现。要求手柄、要求改键、要求不同平台不同默认值，
 *      这些都是迟早的事，而那时每改一次都要动代码、重新构建、重新测 —— 于是没人改；
 *   ② 代码里读的是物理键码（`KeyG`），于是"手柄的 X 键"和"键盘的 G"会在**两个地方**
 *      分别处理，第二个入口总有一天会漏（本工程的 `browser-entry` 就有一份 `keydown`
 *      监听在直接判 `ev.code`，绕过输入设备 —— 那条路永远不会知道手柄的存在）；
 *   ③ 拼错动作名时，`keysPressed.has("havesrt")` 只会**永远是 false**。
 *      表现是"按了没反应"，而所有判据都是绿的。这是最容易浪费半天的一种错。
 *
 * ★★ 三条设计决定，都有代价：
 *   ① **冲突检测按"互斥组"做**，不是"一个键只能属于一个动作"。
 *      因为"W 同时属于 move 和 sprint"是合理的；而"W 同时属于前进和后退"是错。
 *      两者的区别只有作者知道 ⇒ 所以答案是把意图写进数据里（`group`）。
 *      代价：默认所有动作同组 ⇒ 跨动作共用一个键会被判**错**，需要显式分组才能放行。
 *      宁可让"故意共用"多写一行，也不让"手滑共用"静默通过。
 *   ② **动作名拼错要抛错**，不是返回 false。上面第 ③ 条就是这么来的。
 *   ③ 数据形状（`InputMapData`）就是**资产格式**：能直接 JSON 化、能进存档、能由编辑器
 *      生成。演示用代码里的默认表，理由是不给浏览器启动再加一条"文件读不到"的失败路径
 *      （那条路径只有在真做改键界面时才值得存在）。
 */

import type { InputSnapshot } from "../../platform/input/device.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

export const INPUT_MAP_VERSION = 1;

/** 一个动作的绑定。 */
export interface InputActionSpec {
  /** 逻辑键码；为空数组 = 这个动作暂时没绑键（改键界面允许的中间态）。 */
  readonly keys: readonly string[];
  /**
   * 互斥组：**同组内的动作不允许共用键**。
   * 缺省 = `"default"` —— 也就是说"没声明分组"的动作之间默认互斥。
   */
  readonly group?: string;
}

/** 映射表数据（= 资产格式 = 存档形状）。 */
export interface InputMapData {
  readonly version: number;
  readonly actions: Readonly<Record<string, InputActionSpec>>;
}

export interface InputMap {
  /** 动作名（升序，便于日志与判据比对）。 */
  readonly names: readonly string[];
  keysOf(action: string): readonly string[];
  /** 这一 tick 该动作是否按住。**动作名不存在会抛错**（见文件头 ③）。 */
  isDown(snap: InputSnapshot, action: string): boolean;
  /** 这一 tick 是否**刚按下**（走 keysPressed 的边缘，一帧只该被消费一次）。 */
  justPressed(snap: InputSnapshot, action: string): boolean;
  /** `pos − neg`，钳到 −1..1；两边都按住 = 0（不是 1）。 */
  axis(snap: InputSnapshot, neg: string | null, pos: string | null): number;
  /** 数据快照（存档/序列化用；与输入时给的形状相同）。 */
  toData(): InputMapData;
}

const DEFAULT_GROUP = "default";

function badMap(message: string, detail?: Record<string, unknown>): EngineError {
  return detail === undefined ? engineError("INPUT.BAD_MAP", message) : engineError("INPUT.BAD_MAP", message, detail);
}

/**
 * 解析并校验映射表。
 *
 * ★ 入参是 `unknown` 而不是 `InputMapData`：它来自 JSON / 编辑器 / 存档，
 *   类型断言在运行时是空操作。**校验必须在入口做一次**，之后整条链都可以当它是可信的。
 */
export function createInputMap(data: unknown): Result<InputMap, EngineError> {
  if (typeof data !== "object" || data === null) return err(badMap(`映射表必须是对象，收到 ${typeof data}`));
  const d = data as Partial<InputMapData>;
  if (d.version !== INPUT_MAP_VERSION) {
    return err(
      badMap(`映射表版本必须是 ${INPUT_MAP_VERSION}，收到 ${JSON.stringify(d.version)}（不做"猜格式"的兼容）`, {
        version: d.version,
      }),
    );
  }
  if (typeof d.actions !== "object" || d.actions === null || Array.isArray(d.actions)) {
    return err(badMap("actions 必须是「动作名 → 绑定」的对象"));
  }

  const actions = new Map<string, { keys: string[]; group: string }>();
  for (const [name, rawSpec] of Object.entries(d.actions)) {
    if (name.trim() === "") return err(badMap("动作名不能为空字符串"));
    if (typeof rawSpec !== "object" || rawSpec === null) {
      return err(badMap(`动作 "${name}" 的绑定必须是对象`, { action: name }));
    }
    const spec = rawSpec as Partial<InputActionSpec>;
    if (!Array.isArray(spec.keys)) {
      return err(badMap(`动作 "${name}" 的 keys 必须是字符串数组`, { action: name }));
    }
    if (spec.group !== undefined && (typeof spec.group !== "string" || spec.group.trim() === "")) {
      return err(badMap(`动作 "${name}" 的 group 必须是非空字符串`, { action: name }));
    }
    const seen = new Set<string>();
    const keys: string[] = [];
    for (const k of spec.keys) {
      if (typeof k !== "string" || k.trim() === "") {
        return err(badMap(`动作 "${name}" 里有非字符串或空的键码：${JSON.stringify(k)}`, { action: name }));
      }
      if (seen.has(k)) {
        // 同一个动作里重复绑同一个键 = 数据写重了。它不会导致"多走一步"（isDown 是集合），
        // 但会让改键界面显示两个一样的格子，而"删掉一个"之后行为不变 ⇒ 作者会以为删错了。
        return err(
          engineError("INPUT.DUPLICATE_KEY", `动作 "${name}" 里键码 "${k}" 出现了两次`, { action: name, key: k }),
        );
      }
      seen.add(k);
      keys.push(k);
    }
    actions.set(name, { keys, group: spec.group ?? DEFAULT_GROUP });
  }

  // ---- 冲突检测：同一互斥组内，一个键只能属于一个动作
  const owner = new Map<string, { group: string; action: string }>();
  for (const [name, spec] of actions) {
    for (const k of spec.keys) {
      const prev = owner.get(k);
      if (prev === undefined) {
        owner.set(k, { group: spec.group, action: name });
        continue;
      }
      if (prev.group !== spec.group) continue; // 不同组：允许（"W 同时是 move 和 sprint"）
      return err(
        engineError(
          "INPUT.KEY_CONFLICT",
          `键 "${k}" 同时绑在 "${prev.action}" 与 "${name}" 上（两者都在互斥组 "${prev.group}" 里）` +
            ` —— 要么删掉一个，要么把它们声明显式分到不同组`,
          { key: k, a: prev.action, b: name, group: prev.group },
        ),
      );
    }
  }

  const names = [...actions.keys()].sort();

  const require = (action: string, who: string): { keys: readonly string[]; group: string } => {
    const a = actions.get(action);
    if (a === undefined) {
      // ★ 抛错而不是返回空：拼错动作名的症状是"按了没反应"，是这类缺陷里最贵的一种。
      throw new Error(
        `${who}：映射表里没有动作 "${action}"（现有：${names.join(", ")}）—— 拼错了？`,
      );
    }
    return a;
  };

  const anyDown = (snap: InputSnapshot, action: string): boolean => {
    for (const k of require(action, "isDown").keys) if (snap.keysDown.has(k)) return true;
    return false;
  };

  return ok({
    names,
    keysOf(action: string): readonly string[] {
      return require(action, "keysOf").keys;
    },
    isDown(snap: InputSnapshot, action: string): boolean {
      return anyDown(snap, action);
    },
    justPressed(snap: InputSnapshot, action: string): boolean {
      for (const k of require(action, "justPressed").keys) if (snap.keysPressed.has(k)) return true;
      return false;
    },
    axis(snap: InputSnapshot, neg: string | null, pos: string | null): number {
      // 两侧都查表（哪怕有一侧为 0 也要校验名字）：否则"后退键拼错"会在往前按时才暴露
      const lo = neg === null ? 0 : anyDown(snap, neg) ? 1 : 0;
      const hi = pos === null ? 0 : anyDown(snap, pos) ? 1 : 0;
      return hi - lo;
    },
    toData(): InputMapData {
      const out: Record<string, InputActionSpec> = {};
      for (const [name, spec] of actions) out[name] = { keys: [...spec.keys], group: spec.group };
      return { version: INPUT_MAP_VERSION, actions: out };
    },
  });
}

/**
 * 默认映射表（键盘 + 手柄 + 方向键）。
 *
 * ★ 手柄的键码用的是**逻辑名**（`Gamepad0.A` / `Gamepad0.LStickLeft`），由 DOM 后端
 *   在 `poll()` 里合成 —— 映射表这一层不该知道 `navigator.getGamepads()` 长什么样。
 *   这样"手柄能不能玩"就退化成"后端有没有吐出那几个键码"，可以在 headless 里判。
 */
export const DEFAULT_INPUT_MAP_DATA: InputMapData = {
  version: INPUT_MAP_VERSION,
  actions: {
    move_left: { keys: ["KeyA", "ArrowLeft", "Gamepad0.LStickLeft", "Gamepad0.DPadLeft"], group: "move" },
    move_right: { keys: ["KeyD", "ArrowRight", "Gamepad0.LStickRight", "Gamepad0.DPadRight"], group: "move" },
    move_forward: { keys: ["KeyW", "ArrowUp", "Gamepad0.LStickUp", "Gamepad0.DPadUp"], group: "move" },
    move_back: { keys: ["KeyS", "ArrowDown", "Gamepad0.LStickDown", "Gamepad0.DPadDown"], group: "move" },
    // 下面这些动作同属一个组：它们的键**互相不能共用**，否则"按一下砍树也存了档"
    harvest: { keys: ["KeyG", "Gamepad0.A"], group: "action" },
    chop: { keys: ["KeyH", "Gamepad0.B"], group: "action" },
    /**
     * 打一下（批66）。`Space` 在这个组里是空的；手柄用 RT ——
     * `Gamepad0.RT` 由输入后端合成（映射表不知道 getGamepads 长什么样）。
     */
    attack: { keys: ["Space", "Gamepad0.RT"], group: "action" },
    /**
     * 吃一口（批67）。**自动挑最有营养的那一种** —— 不为"吃哪个"再开一个面板：
     * 背包里能吃的东西通常只有一两样，而"先选再吃"会把一次按键变成三步操作。
     */
    eat: { keys: ["KeyE", "Gamepad0.LT"], group: "action" },
    /**
     * 做一件（批68）。做**表里第一条现在就能做的** —— 不弹面板，理由见
     * `craftSomething`：能否做完全由背包决定，一次按键 + 一句提示就够。
     */
    craft: { keys: ["KeyC", "Gamepad0.RB"], group: "action" },
    // 背包面板开关（饥荒同款键位）与丢弃选中堆。Tab 由宿主 preventDefault
    // （否则焦点会跳到浏览器 UI 上，"打开背包"变成"跳出页面"）
    bag: { keys: ["Tab", "Gamepad0.Y"], group: "action" },
    drop: { keys: ["KeyQ", "Gamepad0.X"], group: "action" },
    save: { keys: ["F5", "Gamepad0.Start"], group: "system" },
    load: { keys: ["F9", "Gamepad0.Select"], group: "system" },
    restart: { keys: ["KeyR"], group: "system" },
  },
};

/** 默认映射表（已校验）。模块级常量：坏数据应该**在加载时就炸**，而不是等到第一次按键。 */
export const DEFAULT_INPUT_MAP: InputMap = (() => {
  const r = createInputMap(DEFAULT_INPUT_MAP_DATA);
  if (!r.ok) throw new Error(`默认映射表本身不合法：${r.error.message}`);
  return r.value;
})();
