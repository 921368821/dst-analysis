// spec-networkclientrpc.mjs —— networkclientrpc.lua 注释规格汇总入口
// 逐段合并 spec-networkclientrpc-p1..p8.mjs。
// 同一行号被多段命中时把注释**拼接**（全部是 `--` 注释行，拼接不改变语义）。

const parts = await Promise.all([
  import("./spec-networkclientrpc-p1.mjs"),
  import("./spec-networkclientrpc-p2.mjs"),
  import("./spec-networkclientrpc-p3.mjs"),
  import("./spec-networkclientrpc-p4.mjs"),
  import("./spec-networkclientrpc-p5.mjs"),
  import("./spec-networkclientrpc-p6.mjs"),
  import("./spec-networkclientrpc-p7.mjs"),
  import("./spec-networkclientrpc-p8.mjs"),
  import("./spec-networkclientrpc-p9.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   类型校验谓词（1-16）         —— ★★ check*/opt* 两族语义之别",
  "--  §一   非法 RPC 的三段式处理（18-35）—— 打印 / 推事件 / dev 断言",
  "--  §二   几何与范围原语（39-57）      —— ★ 4096 距离平方阈值与平台相对坐标",
  "--  §三 ★★ RPC_HANDLERS 客户端→服务端（59-1386）—— 不可信方向的 100+ 处理器",
  "--  §四 ★★ 三张表的编号机制（1388-1404）—— orderedPairs 决定终身编号",
  "--  §五 ★ CLIENT_RPC_HANDLERS 服务端→客户端（1406-1535）—— 可信方向，无需校验",
  "--  §六 ★ SHARD_RPC_HANDLERS 分片→分片（1537-1634）—— 第三条通道",
  "--  §七 ★★★ 三个发送函数（1636-1660）—— 唯一的对外出口",
  "--  §八 ★★★ 限流与三条队列（1662-1673）",
  "--  §九 ★★★ HandleRPC 入队（1675-1722）",
  "--  §十 ★★★ HandleRPCQueue 排空（1724-1796）—— 同刻重入保护 RPC_Timeline",
  "--  §十一 模组 RPC 的元表机制（1804-1832）—— 大小写不敏感",
  "--  §十二 ★★★ AddModRPCHandler（1834-1879）—— ⚠ 模组可无限抬高全局限流",
  "--  §十三 模组 RPC 的收发（1881-1954）",
  "--  §十四 注册表查询与 MarkUserIDRPC（1956-1993）",
  "--  §十五 DisableRPCSending 熔断（1995-2004）",
  "--",
  "--【★★★ 三张表的分工（本文件最需要先记住的一件事）】",
  "--  ┌──────────┬────────────────────┬──────────────────────┬────────────┐",
  "--  │ 表       │ 方向                │ 处理表                │ 信任级别   │",
  "--  ├──────────┼────────────────────┼──────────────────────┼────────────┤",
  "--  │ RPC      │ 客户端 → 服务端     │ RPC_HANDLERS          │ ★★ 不可信  │",
  "--  │          │ SendRPCToServer     │ :59-1386（约 90 个）  │ 必须逐个校验│",
  "--  │ CLIENT_  │ 服务端 → 客户端     │ CLIENT_RPC_HANDLERS   │ 可信       │",
  "--  │   RPC    │ SendRPCToClient     │ :1407-1519（16 个）   │ 无需校验   │",
  "--  │ SHARD_   │ 分片 → 分片         │ SHARD_RPC_HANDLERS    │ 可信       │",
  "--  │   RPC    │ SendRPCToShard      │ :1539-1618（13 个）   │ 无需校验   │",
  "--  └──────────┴────────────────────┴──────────────────────┴────────────┘",
  "--  ★★ 两条源码注释直接写明了信任前提，这是本文件的根本设计：",
  "--     :1406 \"these rpc's don't need special verification because",
  "--             server->client communication is already trusted.\"",
  "--     :1537 \"these rpc's don't need special verification because",
  "--             server<->server communication is already trusted.\"",
  "--  ★★ 结论：**只有「客户端→服务端」这一个方向需要防御**。",
  "--     其余两个方向的数据源在服务端（或可信分片）内部，",
  "--     不经过不可信信道，因此省掉了每一个 handler 的校验代码。",
  "--     这解释了整个文件 2004 行里，校验逻辑集中在前 1300 行的原因。",
  "--",
  "--【★★ 关于 C_ / V2C / C2V 命名约定】",
  "--  ★★ 这套约定在 DST 的**注释**里被大量使用，不是 Lua 语法，是开发者的速记：",
  "--    · V2C = **V**anilla **2** **C**lient —— 原版代码路径到客户端的桥接，",
  "--      即「这是引擎(C++)为了客户端显示而调用 Lua 的地方」。",
  "--      ★ 判定方法：注释里出现 V2C 且函数名以 Networking_ 开头（networking.lua），",
  "--        或该函数只在一个方向存在 —— 基本都是 V2C。",
  "--    · C2V = **C**lient **2** **V**anilla —— 客户端输入回到原版逻辑的桥接，",
  "--      即「这是客户端发往服务器、由服务器执行的入口」。",
  "--      ★ 判定方法：注释里有 C2V 且处理的是玩家输入（RPC_HANDLERS 里的全部）。",
  "--    · C_  前缀（如果你在模组代码里见到 C_MyFunc）：约定俗成表示",
  "--      「Client to Server」方向的自定义 RPC，即 C2V 的省略写法。",
  "--      ★ 本文件里没有以 C_ 开头的函数名，但**参数校验谓词**沿用了同一风格：",
  "--        checkbool / checknumber / checkuint / checkstring / checkentity",
  "--        与它们的 opt* 可选版本。",
  "--  ★★★ 这套命名的价值：在一个同时有 C++、Lua、原版、模组四层代码的项目里，",
  "--    方向标注让「这个函数谁调谁」不必读实现就能判断。",
  "--    跨层重构时它是最好的路标。",
  "--  ★ 本文件里的实例：",
  "--    · :428 world.lua 无关，此处 —— networkclientrpc.lua 全文没有 V2C/C2V 字样，",
  "--      因为**这个文件本身就是 C2V 的实现**（名字已经说明了方向，无须再注）。",
  "--    · 反向的例子：prefabs/world.lua:428 `--V2C: Masters is hard`、",
  "--      networking.lua:23 `--V2C: This is for server side processing of",
  "--      remote slash command requests`（★ 这句其实描述的是 C2V 语义，",
  "--      说明注释里的方向标注并非总是严谨 —— 读实现才是准的）。",
  "--    · networking.lua:749 `--V2C: ughh... well at least try to keep this",
  "--      in sync with servercreationscreen.lua BuildTagsStringHosting()`。",
  "--  参见 01-报告/00-注释规范与术语表.md。",
  "--",
  "--【本文件最重要的九条】",
  "--  1. ★★★「入队而非立即执行」（HandleRPC:1675 + HandleRPCQueue:1724）：",
  "--     收到 RPC 只做三件事——查表、校验发送者身份、限流、入队。",
  "--     真正的执行发生在每帧一次的排空阶段。理由见 §九 与 §十 的注记。",
  "--  2. ★★★ 限流额度是「入队」额度不是「执行」额度：",
  "--     HandleRPC 自增（:1688），HandleRPCQueue 排空时自减（:1731-1736），",
  "--     ★ 归零后必须清表（:1733-1734）—— 这是防内存泄漏的关键一行。",
  "--  3. ★★★ ⚠ 模组可无限抬高全局限流（AddModRPCHandler:1848）：",
  "--     每注册一个模组 RPC，RPC_QUEUE_RATE_LIMIT 就 +5，**没有上限**。",
  "--     详见 §十二 的完整推理。",
  "--  4. ★★★ 同刻重入保护（RPC_Timeline:1741-1750）：同一个 sender 在同一 tick",
  "--     只允许有一条 RPC 正在执行；后来的排队等下一刻。",
  "--     ★ 这不是为了限流（限流是 :1687 那件事），而是为了保证「同一玩家的多条输入",
  "--     不会在同一刻交错执行」，否则 inventory 这类状态机操作会自相矛盾。",
  "--  5. ★★ 处理器编号在加载期一次性分配（:1391-1395）：",
  "--     `for k,v in orderedPairs(RPC_HANDLERS) do RPC[k] = i; i = i + 1 end`",
  "--     ★★ 终身绑定：此后往 RPC_HANDLERS 加新键不会重新编号。",
  "--     → 新增 handler 必须在**表定义里**，不能运行时追加（否则客户端与服务端",
  "--       的 orderedPairs 顺序可能不同，导致 code 对不上）。",
  "--     ★ 这是本文件最容易踩的坑，也是 AddModRPCHandler 存在的理由：",
  "--       模组用 namespace+id 走独立通道，不占内置编号空间。",
  "--  6. ★★ 距离校验：IsPointInRange(:43) 用 distsq <= 4096，即 64 格半径。",
  "--     ★ 对**平台相对坐标**的 RPC 必须先转绝对坐标再校验（:102/:152/...），",
  "--       否则可以用平台坐标绕过距离检查。",
  "--  7. ★★ 平台相对坐标的二元约束（ConvertPlatformRelativePositionToAbsolutePosition:48）：",
  "--     platform_relative 为真时 platform 必须非 nil，否则返回 nil（无值），",
  "--     调用方统一用 `if x ~= nil then` 跳过 —— ★ 静默丢弃而非报错。",
  "--  8. ★ USERID_RPCS(:1398)：标记某些 handler 的第一个参数**不是实体而是 userid 字符串**。",
  "--     ★ 典型用途：玩家实体尚未生成时（选人阶段）就要处理 RPC。",
  "--     ★ MarkUserIDRPC:1980 提供注册入口。参见 :1121 的注释。",
  "--  9. ★★ DisableRPCSending(:1997)：世界重置时把六个发送函数整体替换为空函数，",
  "--     ★ 用「重绑定全局函数」而非「逐个改标志位」—— 关闭后的调用成本 = 函数调用开销。",
  "--     ★ 但注意它只关**发送**，接收侧（HandleRPCQueue）照旧。",
  "--",
  "--【★ 关于「实体复制 / 兴趣管理 / 心跳超时」】",
  "--  ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现。",
  "--  ★ 本文件只处理「显式的、带类型的 RPC 消息」，不负责实体的状态同步。",
  "--    · 实体复制（netvar 增量同步）：引擎侧 ReplicaManager 风格机制。",
  "--    · 兴趣管理：引擎侧依据 prefabs/world.lua:544 的 TheFocalPoint 计算复制范围。",
  "--    · 心跳/超时断线：引擎侧与 TheNet 相关，Lua 无对应逻辑。",
  "--  参见 01-报告/04-联机同步-模组系统-UI.md（1.4 兴趣管理 :1318；2.x RPC 全章）",
  "--       与 01-报告/05-原生C++引擎层.md:521（GUID 标识与复制同步）。",
  "--  ★★ 区分 RPC 与实体复用的口诀：",
  "--    「RPC 是玩家主动做的事（点击、移动、合成），复制是世界发生的变化」。",
  "--     前者必须校验与限流（本文件），后者由引擎按兴趣范围自动处理。",
  "--",
  "--【⚠ 本文件记录的疑似缺陷清单（共 5 处）】",
  "--  A. :43-46 IsPointInRange 的 4096 阈值是硬编码，且**位置校验不等于合法性校验**。",
  "--  B. :1848 模组可无限抬高全局限流（★ 用户核实的那个缺口，就在第 1848 行）。",
  "--  C. :715 SwapOneOfActiveItemWithSlot 的背包分支是空的（源码 TODO）。",
  "--  D. :1035 exitgym 全小写命名，且它是本文件里唯一绕过参数校验的 handler。",
  "--  E. :1646/:1656 注释里的 `users`/`shards` 参数在签名中并不存在（文档过时）。",
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
  if (merged) console.log(`[info] networkclientrpc.mjs ${field} 有 ${merged} 处行号被多段命中，已拼接`);
  return out;
}

export const BEFORE = merge("BEFORE");
export const AFTER = merge("AFTER");

const srcLineCount = 2005;

// 覆盖率自检
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
  console.log(`[warn] networkclientrpc.mjs 以下区段（≥25 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}