// spec-shardnetworking.mjs —— shardnetworking.lua 注释规格汇总入口
// 逐段合并 spec-shardnetworking-p1..p2.mjs。

const parts = await Promise.all([
  import("./spec-shardnetworking-p1.mjs"),
  import("./spec-shardnetworking-p2.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   依赖与全局状态（1-10）",
  "--  §一 ★★★ 分片身份判定（12-22）",
  "--  §二 ★★★ 世界设置的跨分片同步（24-41）",
  "--  §三 ★★ 连接建立时的握手（43-62）",
  "--  §四 ★★★★ Shard_UpdateWorldState（68-121）—— 本文件的心脏",
  "--  §五   传送门与分片的双向绑定（125-143）",
  "--  §六   调试与存档/投票转发（145-188）",
  "--  §七 ★★★ 骰子冷却（192-218）",
  "--  §八 ★★ 月王与首领状态的跨分片广播（222-291）",
  "--  §九   跨分片事务的包装（293-305）",
  "--",
  "--【★★★ 本文件最重要的八条】",
  "--  1. ★★★「分片」（shard）是什么 —— 必须先讲清，否则整个文件读不懂：",
  "--     ★★★ 一个「存档」可以由**多个独立的模拟进程**共同构成。这些进程叫分片。",
  "--     · 主分片（master shard）= ★ 承载「主分片状态」的进程（通常是表层世界）；",
  "--     · 次分片（secondary shard）= ★ 附属进程（通常是洞穴世界）。",
  "--     ★★ 两个关键事实：",
  "--       (a) 每个分片都是**完整的模拟**（有自己的 TheWorld、自己的实体表），",
  "--           所以各自都能跑 TheNet:StartServer —— 「一个进程一个世界」。",
  "--       (b) 分片之间**不共享内存**，只能通过 SHARD_RPC（networkclientrpc.lua:1539）",
  "--           互相发消息。★ 这就是本文件存在的全部理由。",
  "--     ★★★ 与 prefabs/world.lua 的关系：",
  "--     · TheWorld.ismastersim（第 426 行）→ 「我是权威模拟吗」（每个分片都是 true）；",
  "--     · ★ TheWorld.ismastershard（第 427 行）→ 「我是主分片吗」（只有主分片 true）；",
  "--     ★ 换句话说：ismastersim 区分「客户端 vs 服务端」，",
  "--     ★★ ismastershard 区分「主分片 vs 次分片」—— ★ 两个正交维度。",
  "--     参见 prefabs/world.lua:426-427 与 shardnetworking.lua:13。",
  "--  2. ★★★ 三张全局表（:7-10）承担不同的角色，不可混用：",
  "--     · ShardPortals  = 所有 worldmigrator 传送门实体（跨分片传送门）",
  "--     · ShardList     = ★ 「有哪些分片存在」的布尔集合（world_id → true）",
  "--     · ★★ ShardConnected = 「有哪些分片已连接」及其元数据",
  "--       （world_id → {ready, tags, world, shard_name}）—— ★ 完整信息在后者。",
  "--     ★ 三者都是**全局无 local**（第 7/9 行），供全项目访问。",
  "--     ★★ ShardConnected 是 local（第 10 行）—— 只有本文件与外部通过函数访问。",
  "--  3. ★★ Shard_IsMaster 的判定式（第 13 行）看似怪异，实则周全：",
  "--     return TheShard:IsMaster() or TheNet:GetIsMasterSimulation() and not TheShard:IsSecondary()",
  "--     ★★ 两个分支覆盖不同场景：",
  "--       · 分支A：TheShard:IsMaster() —— ★ 主分片直接返回 true；",
  "--       · 分支B：(权威模拟) and (非次分片) —— ★★ 兼容「分片系统未启用」的情况：",
  "--         ★ 在普通（非分片）服务器上，TheShard 可能未正确报告，",
  "--         ★★ 于是用「我是权威且不是次分片」来推断「我是主」。",
  "--     ★★ 这是一种「多路径推断同一语义」的写法，为兼容各种部署形态。",
  "--  4. ★★★ Shard_UpdateWorldState（第 68 行）是本文件的心脏：",
  "--     ★ 它由 ShardManager 在「分片连接或断开」时调用，负责：",
  "--       ① 解码新连接分片的 world_data（第 73-91 行，双层沙箱 + 结构校验）；",
  "--       ② 更新 ShardConnected / ShardList（第 92-93 行）；",
  "--       ③ 握手：同步世界设置（第 95 行）；",
  "--       ④ ★★★ 重新绑定所有传送门（第 101-117 行）—— 分片变化会让传送门失效；",
  "--       ⑤ 刷新服务器标签与世界数据（第 119-120 行）。",
  "--     ★★ 关键理解：★ **分片的连接状态一变，所有传送门都要重新评估**",
  "--       （因为传送门可能指向刚连上/刚断开的分片）。",
  "--  5. ★★★ world_data 的「双层沙箱解码」（第 74/84 行）值得细读 ——",
  "--     这是本文件安全设计的精华，详见 §四 的拆解。",
  "--  6. ★★ 传送门绑定的三分支（第 102-116 行）—— 「连上」「断开」「不匹配」：",
  "--     · ready 且目标分片空闲/自动 → 绑定到新分片；",
  "--     · ★★ ready 但 portal.linkedWorld == world_id → 已绑定到这个分片，"
    ,
  "--       只需刷新（ValidateAndPushEvents）；",
  "--     · ★★ ready 但 portal.linkedWorld == 别的分片 → 「不匹配的永久世界」，禁用。",
  "--     ★★★ 第三种情况揭示了一个重要概念：★「永久世界」（permanent world）——",
  "--       一个传送门可以「固定指向某个特定分片」，而非动态绑定。",
  "--  7. ★★★ 投票/存档/会话 id 的转发（第 151-188 行）全部「无条件推给主分片」：",
  "--     · 条件统一是 `if TheWorld ~= nil and TheWorld.ismastershard then`；",
  "--     ★★ 语义：★ 次分片收到这些请求 → 转成事件推给主分片 → 主分片处理。",
  "--     ★ 「投票」「存档」都是**全局状态**，只能由主分片裁定。",
  "--     ★ 第 152 行的注释解释了 TheWorld 可能为 nil（连接发生在世界生成期间）。",
  "--  8. ★★ 骰子冷却（第 194-218 行）是本文件唯一的「限流/防刷」机制：",
  "--     · RecentDiceRolls = { user_id → 冷却结束时刻 }；",
  "--     · 每次请求先清理过期项，再检查是否在冷却，最后写入新冷却；",
  "--     ★★★ TUNING.DICE_ROLL_COOLDOWN 是冷却时长（★ 可调平衡参数）。",
  "--     ★★ 这是「按玩家限频」的简单范式（与 networkclientrpc 的限流同源思想）。",
  "--",
  "--【★ 关于「实体复制 / 兴趣管理 / 心跳超时」】",
  "--  ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现。",
  "--  ★ 分片之间**不复制实体** —— 它们是两个独立的模拟进程。",
  "--    分片间同步的是「稀疏的状态」（世界设置、会话 id、投票、boss 状态、"
    ,
  "--    月王部件），★ 走 SHARD_RPC 显式传输，而不是实体复制。",
  "--    ★★ 这是「分片」与「复制」的分工：",
  "--      · 复制（引擎层）= 同一模拟内，客户端之间的实体同步；",
  "--      · ★ 分片 RPC（本文件）= 不同模拟之间，少量状态的显式同步。",
  "--    参见 01-报告/04-联机同步-模组系统-UI.md 与 05-原生C++引擎层.md。",
  "--  ★ 跨分片的数据一致性由 shardtransactionsteps 组件保证（:58-61 引用），",
  "--    参见 components/shardtransactionsteps.lua。",
];

function merge(field) {
  const out = {};
  let merged = 0;
  for (const p of parts) {
    for (const [k, v] of Object.entries(p[field] ?? {})) {
      if (out[k] !== undefined) {
        out[k] = [...out[k], ...v];
        merged++;
      } else {
        out[k] = v;
      }
    }
  }
  if (merged) console.log(`[info] shardnetworking.mjs ${field} 有 ${merged} 处行号被多段命中，已拼接`);
  return out;
}

export const BEFORE = merge("BEFORE");
export const AFTER = merge("AFTER");

const srcLineCount = 308;

const commented = new Set([
  ...Object.keys(BEFORE).map(Number),
  ...Object.keys(AFTER).map(Number),
]);
let run = 0;
const gaps = [];
for (let i = 1; i <= srcLineCount; i++) {
  if (commented.has(i)) {
    if (run > 0) gaps.push(`${i - run}-${i - 1}`);
    run = 0;
  } else {
    run++;
  }
}
if (run > 0) gaps.push(`${srcLineCount - run + 1}-${srcLineCount}`);

const bigGaps = gaps.filter((g) => {
  const [a, b] = g.split("-").map(Number);
  return b - a + 1 >= 25;
});
if (bigGaps.length) {
  console.log(`[warn] shardnetworking.mjs 以下区段（≥25 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}