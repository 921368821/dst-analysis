// spec-networking.mjs —— networking.lua 注释规格汇总入口
// 逐段合并 spec-networking-p1..p3.mjs。

const parts = await Promise.all([
  import("./spec-networking-p1.mjs"),
  import("./spec-networking-p2.mjs"),
  import("./spec-networking-p3.mjs"),
  import("./spec-networking-p4.mjs"),
  import("./spec-networking-p5.mjs"),
  import("./spec-networking-p6.mjs"),
  import("./spec-networking-p7.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   依赖与首个实例启动（1-20）  —— os.execute 拉起第二个游戏进程",
  "--  §一 ★ 聊天与公告（23-137）        —— 网络层派发给 Lua 的消息落地点",
  "--  §二   说话/Twitch/皮肤校验（139-192）",
  "--  §三 ★★★ 角色与皮肤合法性校验（194-246）—— 反作弊第一道闸门",
  "--  §四 ★ 出生与无缝换角色（248-299）—— 跨 networking/world 两文件的链路",
  "--  §五 ★★★ SerializeUserSession（301-330）—— 玩家持久化存档的序列化",
  "--  §六   模组列表对齐与下载（332-489）—— 联机前的模组协商",
  "--  §七 ★★★ JoinServer（491-644）     —— 加入流程的 UI 与协议编排",
  "--  §八 ★★★ MigrateToServer（646-669）—— 跨服务器迁移：为什么必须重开进程",
  "--  §九   颜色分配与重置/回滚（671-746）",
  "--  §十 ★★ 标签与世界生成元数据（748-815）",
  "--  §十一 GetDefaultServerData（817-847）—— 开服参数快照",
  "--  §十二 ★★ StartDedicatedServer（849-882）—— 专服启动时序",
  "--  §十三 快速加入评分（884-916）    —— 纯客户端侧的启发式排序",
  "--  §十四 玩家查询与连接事件（918-955）",
  "--  §十五 好友管理器（957-1003）     —— 唯一的 UI 状态持有者",
  "--",
  "--【★★★ 本文件最重要的九条】",
  "--  1. ★★★「回调集合」而非「类」：本文件的函数全是**无 local 的全局函数**，",
  "--     因为它们由 **C++ 网络层在特定时刻调用**（消息到达、存档时机、UI 事件）。",
  "--     网络层只知道函数名，不持有实例 —— 所以必须是全局可查的名字。",
  "--     ★ 对比 networkclientrpc.lua 的 HandleRPC（本文件的「对偶」：那边是接收端入口，",
  "--       这边是被调用的具体实现）。",
  "--  2. ★★★ 三种联机模式的识别（★ 最重要的判定）：",
  "--     · TheNet:IsDedicated()          —— 「本进程有没有界面」（专服为真）",
  "--     · TheNet:GetIsMasterSimulation() —— 「我是否持有模拟权威」（房主/专服为真）",
  "--     · TheWorld.ismastersim           —— ★ 上述判定的**缓存字段**（见 prefabs/world.lua:426）",
  "--     · TheWorld.ismastershard         —— 「我是否是主分片」（多分片集群用）",
  "--     ★★ 组合起来区分四种身份：房主 / 专服 / 次分片 / 纯客户端。",
  "--     ★ 注意：GetIsServer() 是第三个谓词，本文件第 14 行与 :304 用它，",
  "--       语义上接近 ismastersim 但不完全等同（后者才与分片无关的纯权威概念）。",
  "--     ★ 权威定义在 prefabs/world.lua:426-427，本文件处处引用那两个字段。",
  "--  3. ★★★ SerializeUserSession（:303）是玩家存档的唯一出口：",
  "--     双重归属校验（第 304 行）→ GetSaveRecord() 取全部组件存档 →",
  "--     DataDumper 序列化 → TheNet:SerializeUserSession 交给存档层。",
  "--     ★★ 两个判断值得记：",
  "--       · 归属校验：player == ThePlayer（本地玩家）**或** GetIsServer()（服务端）",
  "--         → ★ 含义：客户端只允许存自己的存档；服务端可以存任何人的。",
  "--       · `userid:len() > 0` —— ★ 排除「还没有 userid 的实体」（如刚生成的 NPC）。",
  "--  4. ★★★ 「一进程一世界」决定了 MigrateToServer 必须重启进程（:646）：",
  "--     本文件第 418 行的 SpawnSecondInstance 已经示范了「开第二个进程」的做法；",
  "--     MigrateToServer 用 StartNextInstance 走同一条路。",
  "--     ★★ 原因：TheWorld 是全局单例（prefabs/world.lua:422），换服务器意味着换世界，",
  "--       ★ 无法在同一个 Lua 状态里安全地「换掉」它 —— 只能重启。",
  "--  5. ★★ ValidateSpawnPrefabRequest（:194）是反作弊第一道闸门：",
  "--     白名单（DST_CHARACTERLIST / MODCHARACTERLIST）+ 归属校验（CheckClientOwnership）",
  "--     + 降级策略（非法角色 → 回退到第一个合法角色而非踢人）。",
  "--     ★ 第 201 行的 NOTES 记录了一个「行政级」入侵记录（[WERR] 日志）。",
  "--  6. ★★ DownloadMods（:347）是联机模组协商的实现，约 140 行、四层嵌套：",
  "--     临时关闭多余模组 → 检查必需模组 → 缺失则下载 → 下载后校验版本。",
  "--     ★ 版本不符会明确报错（:462-463），而非静默降级。",
  "--  7. ★★ JoinServer（:498）是纯 UI 编排，但藏着两个条件判断（:558/:628）：",
  "--     「服务端开了模组」与「客户端模组被禁」的警告弹窗，",
  "--     且都带 `not IsMigrating()` —— ★ 迁移过程中不弹窗（因为马上要重启）。",
  "--  8. ★★ UpdateServerTagsString（:748）有源码自嘲：",
  "--     \"ughh... well at least try to keep this in sync with",
  "--      servercreationscreen.lua BuildTagsStringHosting()\"",
  "--     ★★ 这是**已知的重复实现**，移植时必须两处同改（★ 双维护点）。",
  "--  9. ★★ 存档写入分两级（★ 理解本文件的关键）：",
  "--     · 玩家级：SerializeUserSession(:303) —— 每个玩家一份",
  "--     · 世界级：SerializeWorldSession(:328) —— 整个存档一份（带回调）",
  "--     ★★ 世界级会**回调**（onsaved，见 :862-866），因为它是异步落盘；",
  "--       玩家级无回调（存档层内部处理）。",
  "--",
  "--【★ 已知缺陷与脆弱点（详见各锚点处的 ⚠ 注记）】",
  "--  · :438-448 的二次校验循环里 `known_mods_good` 逻辑正确但版本比较依赖",
  "--    modinfo_name（第 462 行）在 mod 缺失时会崩（潜在缺陷）。",
  "--  · :336 的 pcall 结果 `status` 被丢弃，JSON 解析失败时仍会读 result_data。",
  "--  · :15 的 `os.execute(\"start \"..exepath)` 用字符串拼接启动进程 —— Windows 特有。",
  "--  · :748 的标签字符串与 servercreationscreen.lua 重复实现（源码自承）。",
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
  if (merged) console.log(`[info] networking.mjs ${field} 有 ${merged} 处行号被多段命中，已拼接`);
  return out;
}

export const BEFORE = merge("BEFORE");
export const AFTER = merge("AFTER");

const srcLineCount = 1004;

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
  console.log(`[warn] networking.mjs 以下区段（≥25 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}