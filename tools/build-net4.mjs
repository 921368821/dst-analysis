#!/usr/bin/env node
/**
 * build-net4.mjs —— 四个网络/世界核心文件的深度中文注释生成器（锚点注入法）
 *
 * 与 build-locomotor.mjs 完全同构，只是把「单文件」泛化成「文件表」：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-<key>-p*.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * ★ 输出路径严格镜像输入的相对路径结构（prefabs/world.lua 不会被拍平）。
 *   verify-annotated.mjs 是按 relative(srcRoot, src) 查找注释版的，
 *   一旦拍平就找不到文件，校验会报「注释版缺失该文件」。
 *
 * 用法：node build-net4.mjs [key ...]      不带参数则构建全部四个
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT = pristineRoot();
const DST_ROOT = ANN_SCRIPTS;

/**
 * 四个目标文件的登记表。
 * header 里的第 2 行固定是保护标记，务必原样保留：
 *   -- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
 */
const TARGETS = {
  world: {
    rel: "prefabs/world.lua",
    header: [
      "--============================================================",
      "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
      "-- 文件：prefabs/world.lua",
      "-- 模块：世界预制体（World Prefab）/ 全局事件总线 / 实体注册表",
      "-- 职责：定义「世界」这个预制体本身。承担世界资源与预制体清单的声明、",
      "--       地图渲染层（render layer）与碰撞集的建立、23 个管理器组件的装配、",
      "--       全局单例 TheWorld / TheFocalPoint 的建立与销毁、",
      "--       以及 TheWorld 作为「全局事件总线」的那一半职责。",
      "-- 关键符号：MakeWorld, PostInit, OnRemoveEntity, CreateTilePhysics,",
      "--           OnPlayerSpawn, DoGameDataChanged, OnGameDataChanged,",
      "--           SetPocketDimensionContainer, CanFlyingCrossBarriers",
      "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
      "-- 交叉引用：main.lua:289（Ents 全局表）、entityscript.lua（事件机制）,",
      "--           prefabs/world_network.lua:57-59（clock / seasons 等时钟类组件）,",
      "--           networking.lua:498 JoinServer / :849 StartDedicatedServer,",
      "--           shardnetworking.lua（分片网络）、update.lua:42（WallUpdate 驱动）",
      "--           TheNet / TheShard / TheSim 均为 C++ 侧对象，无 Lua 源码",
      "--============================================================",
    ],
  },

  networkclientrpc: {
    rel: "networkclientrpc.lua",
    header: [
      "--============================================================",
      "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
      "-- 文件：networkclientrpc.lua",
      "-- 模块：联机同步 / RPC（Remote Procedure Call）核心管线",
      "-- 职责：DST 全部 Lua 侧远程过程调用的中枢。承担参数校验谓词（check*/opt*）、",
      "--       三张内置 RPC 处理表（RPC / CLIENT_RPC / SHARD_RPC）的声明与编号分配、",
      "--       限流队列的三条入队路径与逐帧排空、同刻重入保护（RPC_Timeline）、",
      "--       模组 RPC 的注册与派发（namespace + id 二级索引）、",
      "--       以及世界重置时一键关闭发送的熔断开关。",
      "-- 关键符号：checkbool, checknumber, checkuint, checkstring, checkentity,",
      "--           optbool, optnumber, optuint, optstring, optentity,",
      "--           printinvalid, IsPointInRange, ConvertPlatformRelativePositionToAbsolutePosition,",
      "--           RPC_HANDLERS, CLIENT_RPC_HANDLERS, SHARD_RPC_HANDLERS,",
      "--           HandleRPC, HandleClientRPC, HandleShardRPC, HandleRPCQueue, TickRPCQueue,",
      "--           AddModRPCHandler, HandleModRPC, MarkUserIDRPC, DisableRPCSending",
      "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
      "-- 交叉引用：update.lua:42（WallUpdate 排空队列）、networking.lua（连接生命周期）、",
      "--           shardnetworking.lua（分片侧 RPC 封装）、",
      "--           components/playercontroller.lua（OnRemote* 的实际实现）",
      "-- ★ 实体复制 / 兴趣管理 / 心跳超时在本文件中没有实现：",
      "--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现。",
      "--   参见 01-报告/04-联机同步-模组系统-UI.md 与 01-报告/05-原生C++引擎层.md。",
      "--============================================================",
    ],
  },

  networking: {
    rel: "networking.lua",
    header: [
      "--============================================================",
      "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
      "-- 文件：networking.lua",
      "-- 模块：联机同步 / 玩家连接全生命周期与存档持久化入口",
      "-- 职责：承担网络层派发给 Lua 的全部回调。包含聊天与公告的收发、",
      "--       斜杠命令的服务端执行、玩家角色/皮肤的合法性校验（反作弊第一道闸）、",
      "--       出生与无缝换角色的落地、玩家持久化存档的序列化（SerializeUserSession）、",
      "--       模组列表对齐与下载、开服/加入/迁移三个流程的编排、",
      "--       以及服务器标签与世界生成元数据字符串的生成。",
      "-- 关键符号：Networking_SlashCmd, Networking_Say, ValidateSpawnPrefabRequest,",
      "--           SerializeUserSession, DeleteUserSession, JoinServer, MigrateToServer,",
      "--           StartDedicatedServer, DownloadMods, UpdateServerTagsString,",
      "--           UpdateServerWorldGenDataString, GetDefaultServerData, LookupPlayerInstByUserID",
      "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
      "-- 交叉引用：networkclientrpc.lua（RPC 管线本体）、prefabs/world.lua:401 MakeWorld,",
      "--           shardnetworking.lua（分片集群的 worldgen 数据合并）、",
      "--           usercommands.lua（斜杠命令与投票）、chathistory.lua（聊天历史）",
      "-- ★ 兴趣管理（兴趣中心点）在本文件中没有实现：",
      "--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现；",
      "--   Lua 唯一提供的是 prefabs/world.lua:544 的 TheFocalPoint 兴趣中心点实体。",
      "--   参见 01-报告/04-联机同步-模组系统-UI.md:1318 与 05-原生C++引擎层.md:660。",
      "--============================================================",
    ],
  },

  shardnetworking: {
    rel: "shardnetworking.lua",
    header: [
      "--============================================================",
      "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
      "-- 文件：shardnetworking.lua",
      "-- 模块：联机同步 / 分片（Shard）集群网络",
      "-- 职责：DST「一个存档 = 多个模拟分片」架构下的分片互联层。承担分片连接状态表",
      "--       的维护、传送门与分片的双向绑定、世界设置在分片间的同步、",
      "--       跨分片投票与存档请求的转发、以及月王/首领战利品状态的跨分片广播。",
      "-- 关键符号：ShardPortals, ShardList, ShardConnected, Shard_IsMaster,",
      "--           Shard_IsWorldAvailable, Shard_SyncWorldSettings, Shard_OnShardConnected,",
      "--           Shard_UpdateWorldState, Shard_UpdatePortalState, Shard_GetConnectedShards,",
      "--           Shard_UpdateMasterSessionId, Shard_WorldSave, Shard_StartVote,",
      "--           Shard_OnDiceRollRequest, Shard_SyncBossDefeated, Shard_SyncMermKingExists",
      "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
      "-- 交叉引用：networkclientrpc.lua:1539 SHARD_RPC_HANDLERS（分片通道本体）、",
      "--           prefabs/world.lua:427 ismastershard（分片主控标记）、",
      "--           components/shardtransactionsteps.lua（跨分片事务）",
      "--           TheShard / SendRPCToShard 为 C++ 侧对象，无 Lua 源码",
      "--============================================================",
    ],
  },
};

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function buildOne(key) {
  const t = TARGETS[key];
  if (!t) {
    throw new Error(`未知目标 key: ${key}（可选：${Object.keys(TARGETS).join(", ")}）`);
  }

  const specUrl = pathToFileURL(join(__dirname, `spec-${key}.mjs`)).href;
  const { HEADER_EXTRA, BEFORE, AFTER } = await import(specUrl);

  const src = join(SRC_ROOT, t.rel);
  const out = join(DST_ROOT, t.rel); // ← 镜像相对路径，绝不平铺

  const srcLines = readFileSync(src, "utf8").split("\n");

  const outLines = [t.header.join("\n")];
  if (HEADER_EXTRA && HEADER_EXTRA.length) {
    for (const h of HEADER_EXTRA) {
      assertComment(h, "HEADER_EXTRA");
      outLines.push(h);
    }
  }

  let injected = 0;
  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;

    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        outLines.push(c);
        injected++;
      }
    }

    outLines.push(srcLines[i]); // ← 代码行永远原样取自源文件

    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
        outLines.push(c);
        injected++;
      }
    }
  }

  // 报告规格里是否有「行号不存在」的锚点
  const missing = [];
  for (const key2 of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
    const n = Number(key2);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key2);
  }
  if (missing.length) {
    throw new Error(`[${key}] 规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = outLines.join("\n");
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, text, "utf8");

  const count = (re) => (text.match(re) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ [${key}] ${t.rel}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${outLines.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(
    `  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`
  );
  console.log(`  机制标注【】   : ${count(/【/g)}`);
  console.log(`  重点标注★      : ${count(/★/g)}`);
  console.log(`  疑似缺陷⚠      : ${count(/⚠/g)}`);
  console.log(`  交叉引用参见    : ${count(/参见 /g)}`);
  console.log(
    `  保护标记在前10行: ${
      outLines.slice(0, 10).some((l) => l.includes("【深度注释版】"))
        ? "是"
        : "否"
    }`
  );
}

async function main() {
  const keys = process.argv.slice(2);
  const list = keys.length ? keys : Object.keys(TARGETS);
  for (const k of list) await buildOne(k);
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});