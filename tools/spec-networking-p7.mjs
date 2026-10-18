// spec-networking-p7.mjs —— networking.lua 第 7 段：跨文件交叉引用补强
// 在已有锚点行追加「参见」行，使本文件的跨文件引用密度与其他三个文件一致。

export const BEFORE = {};

export const AFTER = {
  // ── 追加到 p1 已有锚点之后（拼接，不覆盖原注释）──
  29: [
    "--★★ 参见 networkclientrpc.lua:1675 HandleRPC（RPC 管线的接收端入口），",
    "--   ★★ 参见 networkclientrpc.lua:1398 USERID_RPCS（同一时序问题的显式标记解法）。",
  ],
  137: [
    "--★★ 参见 usercommands.lua（命令注册/权限/投票的实现）；",
    "--   ★★ 参见 networkclientrpc.lua:1258 WobyCommand（另一条命令下发通道）。",
  ],
  68: [
    "--★★ 参见 components/talker.lua（气泡渲染）、chathistory.lua（聊天历史）；",
    "--   ★★ 参见 networkclientrpc.lua:1233（DoubleTapAction 用同样的过滤上下文机制）。",
  ],
  246: [
    "--★★ 参见 prefabs/world.lua:222-228（classified 实体族 —— 私有数据的载体）；",
    "--   ★★ 参见 prefabs/world.lua:583 playerspawner（出生流程的下游组件）；",
    "--   ★★ 参见 networkclientrpc.lua:937（「数字 ID + 反查」的白名单模式）。",
  ],
  294: [
    "--★★ 参见 prefabs/world.lua:601（cluster 场景需另行同步 worldgen 数据的自承注记）。",
  ],
  154: [
    "--★★ 参见 prefabs/world.lua:606（TheWorld 作为全局事件总线的同款桥接）。",
  ],
  183: [
    "--★★ 参见 prefabs/world.lua:431（CLASSIFIED 标签的语义来源）。",
  ],
  171: [
    "--★★ 参见 shardnetworking.lua:151（跨分片会话 id 的同款「推事件」模式）。",
  ],

  // ── p2 已有锚点 ──
  320: [
    "--★★ 参见 entityscript.lua（GetSaveRecord 与各组件 OnSave 的汇总路径）；",
    "--   ★★ 参见 locomotor.lua（提供存档字段的组件实例之一）；",
    "--   ★★ 参见 01-报告/04-联机同步-模组系统-UI.md 的存档持久化章节。",
  ],
  330: [
    "--★★ 参见 :862 onsaved（本文件唯一使用异步回调的存档路径）。",
  ],
  489: [
    "--★★ 参见 shardnetworking.lua:74-88（同源的「沙箱 + 严格结构校验」解码手法）；",
    "--   ★★ 参见 networkclientrpc.lua:1848 ⚠ 缺陷 B（模组扩展点的另一处问题）。",
  ],
  669: [
    "--★★ 参见 prefabs/world.lua:422（TheWorld 全局单例赋值 —— 迁移必须重启的根因）；",
    "--   ★★ 参见 prefabs/world.lua:417（重复世界检查，本文件重启策略的对照面）；",
    "--   ★★ 参见 prefabs/world.lua:543（focalpoint 的创建/销毁对称断言）。",
  ],

  // ── p3 已有锚点 ──
  746: [
    "--★★ 参见 prefabs/world_network.lua:52-61（autosaver / clock / seasons 等 7 个组件的注册处 ——",
    "--   ★★ ★ 注意它们挂在 TheWorld.net 上，不在 TheWorld 本体，见 prefabs/world.lua 文件头注记）。",
  ],
  815: [
    "--★★ 参见 prefabs/world.lua:600-602（同款调用的单世界版本）；",
    "--   ★★ 参见 shardnetworking.lua:119-120（分片增删后重新上报的触发点）。",
  ],
  882: [
    "--★★ 参见 prefabs/world.lua:553（IsDedicated 的另两个模式判定）；",
    "--   ★★ 参见 prefabs/world.lua:564-566（客户端提前 return 的性能命门）。",
  ],
  847: [
    "--★★ 参见 prefabs/world.lua:426-427（ismastersim / ismastershard 的权威赋值处）。",
  ],
  916: [
    "--★★ 参见 prefabs/world.lua:430（世界实体的标签体系）与 networking.lua:748（标签生成）。",
  ],
  955: [
    "--★★ 参见 prefabs/world.lua:606 与 shardnetworking.lua:151（ms_ 事件命名约定的两处源头）。",
  ],

  // ── p4 已有锚点 ──
  943: [
    "--★★ 参见 prefabs/world.lua:431-432（CLASSIFIED 标签 —— 主机对象与之无关，仅作对照）。",
  ],
  1003: [
    "--★★ 参见 prefabs/world.lua:543-545（focalpoint 创建/销毁对称的另一处范例）；",
    "--   ★★ 参见 prefabs/world.lua:360-366（OnRemoveEntity 的完整清理时序）。",
  ],
};