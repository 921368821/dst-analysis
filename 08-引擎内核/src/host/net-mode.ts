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
 *
 * ★★ 批164：`?seat=` 与 `assumedSeat` **删掉了**
 *
 *   批163 里它们的存在理由是「demo 还没有握手，座位号只能从 URL 猜」，
 *   并且明写了那条捷径的用途：两个窗口都填 0 = 两个人同控一个角色。
 *   握手接上之后（`net/join.ts` 的 `Room` 分配座位 → `host/seat-table.ts` 造实体），
 *   **座位号不再是一个可以被申报的东西**：它由主机分配，客户端只能等回复。
 *   留着 `?seat=` 就留下了一条"我自称我是谁"的路径 —— 而那正是这次要拆的东西。
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

/**
 * 走哪条链路。
 *
 * ★ 两条链路的差别**不是"实现不同"**，而是「端点号与投递语义从哪来」：
 *   · `bc`（`BroadcastChannel`）：同源标签页广播。号由 URL 给（host = 0 / client = 1），
 *     因为同一台机器上有几个标签页是**页面自己知道的**。
 *   · `ws`（WebSocket + 网关）：跨机器。号由**网关**给（`hello`），因为一台机器
 *     不可能知道别处还有谁连着 —— 这正是"我自称我是谁"必须断掉的地方。
 */
export type NetWire = "bc" | "ws";

export interface NetMode {
  readonly role: NetRole;
  /**
   * 端点号。**只有 `bc` 有值**（主机 = 0、客户端 = 1）。
   *
   * ★ `ws` 下恒为 `null`：号由网关在连接建立时分配（`net/ws-transport.ts` 的 `hello`）。
   *   在这里给一个猜测值等于把刚拆掉的"自报座位号"从后门放回来 ——
   *   而它的症状是"客户端连上了但收不到自己的加入回复"（见 `join.ts` 里
   *   `JoinerOptions.self` 的注释）。
   */
  readonly self: number | null;
  /** 通道名；`off` 时是空串（没有通道）。 */
  readonly room: string;
  /** 走哪条链路；`off` 时为 `null`。 */
  readonly wire: NetWire | null;
  /** `wire === "ws"` 时的地址（已归一）；其余情况为 `null`。 */
  readonly url: string | null;
  /**
   * 落到这个模式的理由。**失败也要有理由**：`?net=cleint` 退回单机时，
   * `why` 里写着「不认识的值 cleint」—— 这句话会进 HUD 与日志。
   * 静默回退的症状是「我明明加了参数，怎么还是单机」。
   */
  readonly why: string;
}

/**
 * 归一一个 WebSocket 地址。**不合法返回 `null`**（调用方据此退回单机）。
 *
 * ★ 只认 `ws:` / `wss:`：把 `http://` 当成能连的地址，症状是浏览器控制台里
 *   "The URL's scheme must be either 'ws' or 'wss'" —— 而页面上只会显示"没连上"。
 * ★ 走 `new URL()` 而不是正则：端口、IPv6 字面量（`ws://[::1]:8787`）、百分号编码
 *   全部由它处理。自己写正则的那一天，就是"局域网能用、IPv6 不能用"的那一天。
 * ★ 返回 `toString()` 的归一形态（补上结尾的 `/`）：判据可以直接比字符串，
 *   而不用两处各自记得"有没有斜杠"。
 */
export function normalizeWsUrl(raw: string | null | undefined): string | null {
  const s = (raw ?? "").trim();
  if (s === "") return null;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  if (u.protocol !== "ws:" && u.protocol !== "wss:") return null;
  if (u.hostname === "") return null;
  return u.toString();
}

/**
 * 解析宿主的联网参数。
 *
 * ★ 接受 `null` 与空串都算"没指定"：`?net=` 与不带参数是同一件事
 *   （`URLSearchParams.get` 对 `?net=` 返回 `""`，不是 `null`）。
 *
 * ★★ `wire` 的缺省是 `bc`，**不是**"自动挑一个"
 *   自动挑的规则会需要"这台机器上有没有别人"这种运行期知识，而那在页面起来时
 *   根本没有答案。缺省 `bc` 保住了批163~166 的全部行为（两个标签页能玩），
 *   跨机器必须显式写 `wire=ws` —— 于是"我忘了加参数"的表现是"同机能玩、跨机不能"，
 *   而不是"两边都在等一个永远不会来的对手"。
 */
export function parseNetMode(
  param: string | null | undefined,
  roomParam?: string | null,
  wireParam?: string | null,
  urlParam?: string | null,
): NetMode {
  const raw = (param ?? "").trim().toLowerCase();
  const role: NetRole = raw === "host" ? "host" : raw === "client" ? "client" : "off";
  const why =
    role !== "off"
      ? `?net=${role}`
      : raw === "" || raw === "off" || raw === "0"
        ? "未指定（单机）"
        : `不认识的值「${raw}」，退回单机`;

  if (role === "off") return { role, self: null, room: "", wire: null, url: null, why };

  const want = (roomParam ?? "").trim();
  // ★ 空串不是"换成一个空房间"，是"没指定" —— 与 `?tree=` 同一条归一规则。
  const room = want === "" ? DEFAULT_ROOM : ROOM_RE.test(want) ? want : DEFAULT_ROOM;
  const roomWhy = want !== "" && room !== want ? `（房间名「${want}」不合法，用了 ${DEFAULT_ROOM}）` : "";

  const off = (why2: string): NetMode => ({
    role: "off",
    self: null,
    room: "",
    wire: null,
    url: null,
    why: why + why2,
  });

  const wRaw = (wireParam ?? "").trim().toLowerCase();
  if (wRaw !== "" && wRaw !== "bc" && wRaw !== "ws") {
    // ★ 不认识的链路**退回单机**，而不是退回 `bc`：后者会让"跨机器打不开"变成
    //   "同机能玩"，于是参数写错这件事再也看不出来。
    return off(`；不认识的 wire「${wRaw}」，退回单机`);
  }

  if (wRaw === "ws") {
    const url = normalizeWsUrl(urlParam);
    if (url === null) {
      const detail = (urlParam ?? "").trim() === "" ? "wire=ws 但没有 url" : `url「${(urlParam ?? "").trim()}」不是 ws:// 或 wss://`;
      return off(`；${detail}，退回单机`);
    }
    // ★ `self: null`：号由网关给（见 `NetMode.self` 的注释）。
    return { role, self: null, room, wire: "ws", url, why: `${why} + wire=ws` + roomWhy };
  }

  const self = role === "host" ? 0 : 1;
  return { role, self, room, wire: "bc", url: null, why: why + roomWhy };
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
}

/**
 * 装配要用的决策。
 *
 * ★ 批164 之后这里只剩一件事（"位置由谁改"）：座位号与端点映射不在这了 ——
 *   它们来自握手（主机侧 `room.playerOf`、客户端侧 `joiner.playerId()`），
 *   而握手是**运行期**才知道的，不是"URL 解析出来"的。硬塞进来的话，
 *   它会是一个"解析那一刻算出来的常量"，重连之后就与事实不符。
 */
export function planNetWiring(mode: NetMode): NetWiring {
  return { mode, driveController: localDriveOf(mode.role) === "controller" };
}
