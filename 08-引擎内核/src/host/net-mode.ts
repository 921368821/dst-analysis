/**
 * L6 · 联机模式的**决策**（纯函数）
 *
 * ★★ 为什么把「URL 参数 → 行为」抽成一组纯函数，而不是写在 `browser-entry` 里
 *
 *   写在接线里的话，它唯一的验证方式就是「打开浏览器看一眼」：

 *   · 参数写错（`?net=cleint`）时，页面**看起来照常能玩**（退回单机），
 *     而两端的日志都说"一切正常"；
 *   · 「本机玩家是谁」错成"第一个找到的"时，拥有两个角色的人会控制错那个，
 *     而单机下永远只有一个角色 ⇒ 测不出来。
 *
 *   这两类问题的共同点是**症状不指向原因**，所以判断必须落在能被 Node 判据打的地方。
 *   接线（`browser-entry` / `demo-game`）只负责把 `NetMode` 变成对象与回调。
 *
 * ★ 这一层不认识 `Transport` / `Session`：它只回答「该不该联网、我是谁、
 *   本地玩家是哪个实体、谁负责驱动他」。把对象创建也塞进来，判据就得造一堆假对象。
 */

import type { Scene } from "../core/scene/scene.ts";
import type { NodeId } from "../core/scene/node.ts";
import { ownedBy, type PlayerId } from "../extensions/net/identity.ts";

/** 三种模式。`off` 是今天的单机行为，也是任何异常输入的回退。 */
export type NetRole = "off" | "host" | "client";

/**
 * 谁负责驱动本地玩家。
 *
 * ★ `off` 与联机的分界不是"要不要联网"，而是**「位置由谁改」**：
 *   · `controller`：`createControllerModule` 每拍直接写 `localPosition`（今天的行为）；
 *   · `session`：模块只 poll 输入，位置由会话走 `admit → dirStep → 预测` 那一条。
 *   两者同时生效就是**每拍走两步** —— 而单机下永远只有一个驱动者，测不出来。
 */
export type LocalDrive = "controller" | "session";

/** 同源多标签页的默认通道名。两个标签页要填同一个才连得上。 */
export const DEFAULT_ROOM = "engine08";

/** 通道名允许的字符集：`BroadcastChannel` 接受任意字符串，但跨机器/记账时会进日志与 URL。 */
const ROOM_RE = /^[A-Za-z0-9._-]{1,64}$/;

export interface NetMode {
  readonly role: NetRole;
  /** 端点号：主机 = 0、客户端 = 1；`off` 时为 `null`（没有端点，也不该有身份）。 */
  readonly self: number | null;
  /**
   * 本端**声称**的座位号（`PlayerId`）。
   *
   * ★★ 这是这一层唯一一处「简化」，必须写明白：
   *   正式的座位号由**握手分配**（`net/join.ts` 的 `assignOwner`，重连不变），
   *   而 demo-game 还没有接握手。所以这里退化成「端点号 = 座位号」，
   *   并用 `?seat=` 允许宿主覆盖 —— 双窗口联调时两个窗口都填 0，
   *   就是「两个人同控主机世界里的同一个角色」。
   *
   * ★ 为什么不做成 `self`：批159 立的规矩是「座位号 ≠ 端点号」。
   *   合并之后，「重连拿到同一个端口」与「重连拿到同一个座位」会同时成立，
   *   而那句判据（座位号不由端点数决定）就再也测不出区别。
   *   分成两个字段之后，退化发生在**调用方**，而不是在类型里。
   */
  readonly assumedSeat: number | null;
  /** 通道名；`off` 时是空串（没有通道）。 */
  readonly room: string;
  /**
   * 落到这个模式的理由。**失败也要有理由**：`?net=cleint` 退回单机时，
   * `why` 里写着「不认识的值 cleint」—— 这句话会进 HUD 与日志。
   * 静默回退的症状是「我明明加了参数，怎么还是单机」。
   */
  readonly why: string;
}

/**
 * 解析宿主的联网参数。
 *
 * ★ 接受 `null` 与空串都算"没指定"：`?net=` 与不带参数是同一件事
 *   （`URLSearchParams.get` 对 `?net=` 返回 `""`，不是 `null`）。
 */
export function parseNetMode(
  param: string | null | undefined,
  roomParam?: string | null,
  seatParam?: string | null,
): NetMode {
  const raw = (param ?? "").trim().toLowerCase();
  const role: NetRole = raw === "host" ? "host" : raw === "client" ? "client" : "off";
  const why =
    role !== "off"
      ? `?net=${role}`
      : raw === "" || raw === "off" || raw === "0"
        ? "未指定（单机）"
        : `不认识的值「${raw}」，退回单机`;

  if (role === "off") return { role, self: null, assumedSeat: null, room: "", why };

  const self = role === "host" ? 0 : 1;

  const want = (roomParam ?? "").trim();
  // ★ 空串不是"换成一个空房间"，是"没指定" —— 与 `?tree=` 同一条归一规则。
  const room = want === "" ? DEFAULT_ROOM : ROOM_RE.test(want) ? want : DEFAULT_ROOM;
  let roomWhy = want !== "" && room !== want ? `（房间名「${want}」不合法，用了 ${DEFAULT_ROOM}）` : "";

  // 座位号：缺省 = 端点号（见 `assumedSeat` 的注释）。给了就校验，不合法就退回并说明。
  const seatWant = (seatParam ?? "").trim();
  let assumedSeat = self;
  if (seatWant !== "") {
    // ★ 只认 0..31：`Number("")` 是 0、`Number("1e3")` 是 1000，两者都会让人以为"填对了"。
    const n = /^\d{1,2}$/.test(seatWant) ? Number(seatWant) : Number.NaN;
    if (Number.isInteger(n) && n >= 0 && n <= 31) assumedSeat = n;
    else roomWhy += `（座位号「${seatWant}」不合法，用了 ${String(self)}）`;
  }

  return { role, self, assumedSeat, room, why: why + roomWhy };
}

/** 联机时位置由会话管；单机时由控制器模块管。 */
export function localDriveOf(role: NetRole): LocalDrive {
  return role === "off" ? "controller" : "session";
}

/**
 * 本机玩家操控的**那个**实体。
 *
 * ★ 取 `id` 最小的，不是"第一个找到的"。
 *   `ownedBy` 的实现是遍历组件表（`Map` 的插入序），而插入序取决于
 *   "谁先被 spawn / 谁先从快照里载入" —— 那是两条会分叉的路径。
 *   取最小值是一个**与遍历顺序无关**的定义，两端算出来必然相同。
 *
 * ★★ 为什么这里只写 `ids[0]`、不再自己扫一遍最小值（2026-10-30 实测后改的）：
 *   第一版在这里写 `if (best === null || id < best) best = id`，而 `ownedBy`
 *   已经 `sort((a,b) => a-b)` 过 —— 于是那段扫描是**第二份实现**：
 *   把它删掉判据照样全绿（等价变异），而变异真正该打的是 `ownedBy` 的排序。
 *   同一段逻辑写两处，变异只会打到第一处。所以最小值这件事**只有一处**：
 *   `ownedBy` 的升序契约（`tests/extensions/net-identity.test.ts` 钉住它）。
 *   这里接着往下写 `[0]` 就是把那个契约用起来。
 *
 * ★ 一个玩家拥有多个实体的情形现在很少（分屏、交接间隙），但"很少"不是
 *   "不会"：交接期间两个实体短暂同属一人是**设计上允许**的（见 `identity.ts`）。
 *   到那时的正确行为是"操控哪一个"由上层决定，而这一层只保证**同一个问题同一个答案**。
 */
export function pickLocalEntity(scene: Scene, player: PlayerId | null): NodeId | null {
  if (player === null) return null;
  return ownedBy(scene, player)[0] ?? null;
}

/**
 * 装配要用的一整套决策。
 *
 * ★ 为什么把它也抽出来：`demo-game.ts` 是 3000 多行的组合根，里面任何一行判断
 *   都只能靠"打开浏览器看一眼"来验证。而"开不开预测""端点算几号座位""控制器
 *   要不要自己改位置"这三件事**每一个错了都表现为画面正常**：
 *   · 座位号错了 ⇒ 客户端的输入被拒，角色纹丝不动（看起来像网络断了）；
 *   · 控制器仍然自己改位置 ⇒ 每拍走两步（看起来像"跑得特别快"，但那也可能是敏捷属性）；
 *   · 预测没开 ⇒ 客户端画面一顿一顿（看起来像帧率问题）。
 *   抽到这里之后，这三件事都是纯函数的返回值，各有判据。
 */
export interface NetWiring {
  readonly mode: NetMode;
  /** 控制器模块要不要自己改位置（见 `LocalDrive`）。 */
  readonly driveController: boolean;
  /** 这一端认为自己是几号座位；`off` 时为 `null`。 */
  readonly seat: number | null;
  /**
   * 端点 → 座位的映射，交给 `SessionOptions.playerOf`；`off` 时为 `null`。
   *
   * ★★ 这里有一处**必须说清的简化**：demo 的世界里只有一个玩家实体（owner 0），
   *   所以联机模式下**任何端点都被当成同一个座位** —— 于是两个窗口可以同控那个角色。
   *   这正是「预测真的跑在游戏里」需要的最小形态（客户端得有个实体可以预测）。
   *
   *   正式的多玩家（每人一个实体、座位由握手分配、重连不变）不在这里：
   *   那要 `net/join.ts` 的座位表，且需要世界生成能造出第二个玩家 —— 见
   *   `docs/ONLINE-READINESS-PLAN.md` 的缺口表。把这条捷径写成"默认"是最糟的做法。
   */
  readonly playerOf: ((peer: number) => number) | null;
}

export function planNetWiring(mode: NetMode): NetWiring {
  if (mode.role === "off" || mode.assumedSeat === null) {
    return { mode, driveController: true, seat: null, playerOf: null };
  }
  const seat = mode.assumedSeat;
  return {
    mode,
    driveController: localDriveOf(mode.role) === "controller",
    seat,
    playerOf: () => seat,
  };
}
