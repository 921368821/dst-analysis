/**
 * L4 · 联机身份（NetIdentity）：这个实体归谁
 *
 * ★★ 为什么这个字段必须住在**场景里**，而不是会话对象里
 *
 *   归属是**世界状态**，不是连接状态：它要跟着快照一起走过去（客户端得知道"哪个
 *   角色我能推"）、要跟着存档一起留下（单人档读回来还是我的角色）、要在交接时
 *   改一次就全场生效。放进会话对象的 `Map<PeerId, NodeId>` 里，这三件都要另写一份，
 *   而"另写一份"的那份一定会在某次改字段时被漏掉。
 *
 * ★ 两个刻意的选择：
 *
 * ① **`AUTHORITY`（-1）是一个真实的取值，不是"没有归属"**
 *    NPC、场景物件、被主机接管的角色都归它。于是"这个实体能不能被网络意图驱动"
 *    只有一个判断（`owner === from`），不需要再区分"没挂组件"与"挂了但没人拥有"。
 *    没挂 `net.identity` 的实体**不参与联机**（它连归属都没有，谈不上校验），
 *    这和"归主机"是两件事：前者是单机物件，后者是联机里由权威驱动的物件。
 *
 * ② **`assignOwner` 不会顺手挂组件**
 *    对没有 `net.identity` 的节点赋值一律返回 `false`。自动补挂留着的症状是
 *    "某个从没打算联机的物件悄悄进了快照"，而这件事在单机上完全看不出来。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import type { PeerId } from "./transport.ts";

/** 组件类型。 */
export const NET_IDENTITY_TYPE = "net.identity";

/**
 * 「由权威驱动」的对端 id。
 *
 * ★ 用 -1 而不是 0：环回里 0 号是**主机这个对端**（它的本地玩家归它，玩家输入
 *   与远程客户端走同一道校验）。NPC 归的是"权威"这个角色，不是"0 号对端" ——
 *   专用服里没有 0 号对端的玩家，混用会让这段代码在换宿主形态时全部失效。
 */
export const AUTHORITY: PeerId = -1;

export class NetIdentity extends Component {
  /** 拥有者。`AUTHORITY` = 由权威侧驱动（AI / 脚本 / 主机本地）。 */
  owner: PeerId = AUTHORITY;

  readonly schema: ComponentSchema = {
    type: NET_IDENTITY_TYPE,
    fields: { owner: FieldType.Int },
    defaults: { owner: AUTHORITY },
  };
}

/** 注册用的静态 schema（`registry.create` 需要不依赖实例的形态）。 */
const SCHEMA: ComponentSchema = {
  type: NET_IDENTITY_TYPE,
  fields: { owner: FieldType.Int },
  defaults: { owner: AUTHORITY },
};

export function registerNetIdentity(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(NET_IDENTITY_TYPE)) registry.register(SCHEMA, () => new NetIdentity());
}

/** 读归属。`null` = 节点不存在或没挂 `net.identity`（不参与联机）。 */
export function ownerOf(scene: Scene, nodeId: NodeId): PeerId | null {
  const id = scene.find(nodeId)?.get<NetIdentity>(NET_IDENTITY_TYPE);
  return id === undefined ? null : id.owner;
}

/**
 * 写归属（**唯一**的写入点）。
 *
 * 只该由主机调用 —— 但这条不在这里守：本函数是"改一个数字"的纯操作，
 * 角色守卫在 `session.assign`（那里知道谁是主机）。把它写在这里会让
 * "客户端偷偷改"变成一个需要猜测的问题，而不是一个可计数的拒绝。
 */
export function assignOwner(scene: Scene, nodeId: NodeId, owner: PeerId): boolean {
  const id = scene.find(nodeId)?.get<NetIdentity>(NET_IDENTITY_TYPE);
  if (id === undefined) return false;
  id.owner = owner;
  return true;
}

/** 这个对端能驱动哪些实体（客户端用它决定"给谁发意图"）。按 id 升序，确定性。 */
export function ownedBy(scene: Scene, peer: PeerId): NodeId[] {
  const out: NodeId[] = [];
  for (const c of scene.componentsOf<NetIdentity>(NET_IDENTITY_TYPE)) {
    if (c.owner !== peer) continue;
    const node = c.node;
    if (node === null) continue;
    out.push(node.id);
  }
  out.sort((a, b) => a - b);
  return out;
}
