#!/usr/bin/env node
/**
 * build-mainfunctions.mjs —— mainfunctions.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-actions.mjs / build-behaviourtree.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-mainfunctions-p1..p6.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *   · 规格里任何非 `--` 开头的行都会在构建期抛错（assertComment）。
 *
 * 用法：node build-mainfunctions.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts";
const OUT_ROOT = "E:/DST-Analysis/02-注释源码/scripts";

const SRC_LINE_COUNT = 2589;

/* ────────────────────────── 文件头 ────────────────────────── */

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：mainfunctions.lua（2589 行）",
  "-- 模块：全局函数总表 + 存档系统入口（SaveGame / 会话序列化）",
  "--",
  "-- ★★★ 本文件的核心认知：它是 Lua **全局命名空间的手写扩展**，不是模块。",
  "--   文件里 200 多个 `function Xxx()` 全部没有 local（除了少数几个带 local 的",
  "--   内部辅助函数），也就是说它们在 load 时就**注入到全局环境 _G**。",
  "--   ⇒ 推论 1：别的文件可以在任何地方直接调用本文件的函数，不需要 require。",
  "--             这就是为什么 mainfunctions.lua 必须在引擎启动**最早**期被加载。",
  "--   ⇒ 推论 2：本文件不能被安全地重复 require（会重复定义并重新初始化状态）。",
  "--   ⇒ 推论 3：想找某个全局函数在哪被用，直接 Grep 全 scripts 目录即可。",
  "--",
  "-- ★★ 关于存档：本文件只负责「写」（SaveGame），**不负责「读」**。",
  "--   本文件没有 LoadGame 函数——读档路径全部在 gamelogic.lua：",
  "--     gamelogic.lua:1044  DoLoadWorldFile / :1056 DoLoadWorld",
  "--     gamelogic.lua:368   PopulateWorld（真正把 savedata 灌回世界）",
  "--     gamelogic.lua:1031  UpgradeSaveFile（跨版本迁移入口，见本文件 1018 行）",
  "--   本文件的 SaveGame（1068 行）与 gamelogic.lua 的 PopulateWorld（368 行）",
  "--   是**同一份数据结构的两个方向**：写出去的字段名，读回来时逐字对应。",
  "--   ⇒ 排查「某字段没存上/没读到」时，必须把这两边一起看。",
  "--",
  "-- 分区索引表（★ 重点区域已标星，按行号直接跳转）：",
  "--",
  "--  #  行号区间      分区                          职责一句话",
  "--  ────────────────────────────────────────────────────────────",
  "--  01    1   -  16   模块头                        requires / DEBUG_MODE / 三个全局开关",
  "--  02   18   -  46   持久化字符串 ★               SavePersistentString / ErasePersistentString",
  "--  03   48   -  65   小工具                       Print / SecondsToTimeString",
  "--  04   67   - 137   Prefab 注册 ★                ShouldIgnoreResolve / RegisterPrefabsImpl",
  "--  05  139   - 247   Prefab 文件加载与模组资源      LoadPrefabFile / Mod*Assets",
  "--  06  249   - 343   成就与平台服务                RegisterAchievements / AwardPlayerAchievement",
  "--  07  347   - 411   实体生成                     SpawnPrefabFromSim / SpawnPrefab / PrefabExists",
  "--  08  413   - 436   ★ 存档坐标解析                ResolveSaveRecordPosition（平台局部坐标）",
  "--  09  438   - 484   ★ 存档实体还原                SpawnSaveRecord（newents 表的构建点）",
  "--  10  486   - 556   实体生命周期                 CreateEntity / OnRemoveEntity / RemoveEntity",
  "--  11  558   - 587   时间函数                     GetTime / GetTick / GetStaticTime",
  "--  12  589   - 668   脚本加载与调试               LoadScript / GetDebugString / SetDebugEntity",
  "--  13  670   - 761   休眠与唤醒 ★                 OnEntitySleep / OnEntityWake / PhysicsWake",
  "--  14  763   - 812   服务器暂停状态机 ★           OnServerPauseDirty（三种 pause）",
  "--  15  814   - 835   复制与加载保护               ReplicateEntity / DisableLoadingProtection",
  "--  16  837   - 851   NIS 播放                     PlayNIS",
  "--  17  853   - 950   本地暂停体系 ★               IsPaused / SetPause / 自动暂停 DoAutopause",
  "--  18  952   - 1064  外部设置 + 世界生成覆盖 ★★   UpdateWorldGenOverride（含跨版本迁移）",
  "--  19 1066   - 1274  ★★★ SaveGame 存档主流程      本文件最重要区域，见下方专项说明",
  "--  20 1276   - 1300  JSON 消息处理                ProcessJsonMessage",
  "--  21 1302   - 1321  字体                         LoadFonts / UnloadFonts",
  "--  22 1323   - 1408  手柄检测弹窗                 CheckControllers（Steam Deck 特判）",
  "--  23 1410   - 1440  启动入口 ★                   Start（配置目录权限自检）",
  "--  24 1444   - 1541  实例重置 ★                   GlobalInit / SimReset（换档/重开的中枢）",
  "--  25 1543   - 1679  退出与错误展示               RequestShutdown / DisplayError",
  "--  26 1681   - 1757  重启 ★                       savefn / DoRestart（保存后重启）",
  "--  27 1759   - 1929  断线处理                     OnPlayerLeave / OnNetworkDisconnect",
  "--  28 1931   - 1993  账号事件 / 焦点              OnAccountEvent / OnFocusLost",
  "--  29 1995   - 2132  ★ 玩家会话（存档的用户侧）    SerializeUserSession 的对面",
  "--  30 2134   - 2198  控制台执行 / 加载状态        ExecuteConsoleCommand / NotifyLoadingState",
  "--  31 2200   - 2423  ★★ 世界状态标签（位域编码）   CreateWorldStateTag（假 base64）",
  "--  32 2425   - 2457  存档退出 + 音量降噪           SaveAndShutdown / CreateRepeatedSound...",
  "--  33 2459   - 2487  防沉迷通知 / shell 命令       DisplayAntiAddictionNotification",
  "--  34 2489   - 2520  文件哈希告警 UI              ShowBadHashUI",
  "--  35 2522   - 2589  登录流同步 + 完整性校验 ★    DataBundleFileHashes（哈希比对）",
  "--",
  "-- ★★★ SaveGame（1066-1274 行）阶段划分 —— 全项目最重要的数据流程：",
  "--   阶段 A  1068-1077  守卫：客户端直接拒绝；TheNet:StartWorldSave() 打开写入窗口",
  "--   阶段 B  1079-1107  遍历 Ents，逐个 GetSaveRecord()，收集 GUID 交叉引用",
  "--   阶段 C  1109-1166  地图与网络层：tiles / nav / persistdata / world_network",
  "--   阶段 D  1168-1187  玩家快照列表 + 逐个 SerializeUserSession + 回填 id",
  "--   阶段 E  1189-1199  模组清单 + 6 条结构断言（fail-fast）",
  "--   阶段 F  ★★1201-1238  序列化 + NaN/Inf 拦截（本文件最高价值区域）",
  "--   阶段 G  1241-1273  落盘回调：快照轮转 → ShardGameIndex → EndWorldSave",
  "--   ⚠ 注意阶段 F 的错误处理是 `error()` 硬抛，不是软降级——见 1219 行注释。",
  "--",
  "-- ★★ NaN/Inf 拦截的精确位置（bug-patterns.md C 类「NaN 永久损坏存档」）：",
  "--   判据构造  1203-1208   patterns 表，按 BRANCH 分叉",
  "--     · BRANCH==\"dev\"   → {\"=nan\", \"=-nan\", \"=inf\", \"=-inf\"}",
  "--     · 正式版          → {\"=-1.#IND\", \"=1.#QNAN\", \"=1.#INF\", \"=-1.#INF\"}",
  "--   扫描位置    1214-1221  对普通字段（save 的每个 key）做 string.find",
  "--   扫描位置    1230-1237  对 data.ents（按 prefab 分组的实体表）做同样的扫描",
  "--   判据本质    ★ 对**序列化后的文本**做纯文本子串匹配，而不是数值比较。",
  "--   为什么这样设计 → 见 1214 行与 1230 行的长注释（含 tonumber(\"nan\")==nil 陷阱）。",
  "--",
  "-- 关键符号：",
  "--   SaveGame / ResolveSaveRecordPosition / SpawnSaveRecord / SpawnPrefab /",
  "--   CreateEntity / RemoveEntity / OnRemoveEntity / ReplicateEntity /",
  "--   SavePersistentString / ErasePersistentString / UpdateWorldGenOverride /",
  "--   RegisterPrefabsImpl / LoadPrefabFile / ShouldIgnoreResolve /",
  "--   CreateWorldStateTag / WORLDSTATETAGS / BuildTagsStringCommon /",
  "--   GetTime / GetStaticTime / SetPause / DoAutopause / DoRestart / Shutdown /",
  "--   ParseUserSessionData / ResumeExistingUserSession / RestoreSnapshotUserSession",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 gamelogic.lua:368 PopulateWorld —— SaveGame 的**逆过程**（读档）",
  "--   ★★ 参见 gamelogic.lua:1031 UpgradeSaveFile —— 跨版本迁移的实际执行者",
  "--   ★★ 参见 gamelogic.lua:168 LoadAssets / :777 WriteServerSaveTempFile",
  "--   ★★ 参见 savefileupgrades.lua:31 utilities —— 迁移函数登记表（本文件 1019 行调用）",
  "--   ★★ 参见 savefileupgrades.lua:367 UpgradeWorldgenoverrideFromV1toV2（本文件 1019 行）",
  "--   参见 shardindex.lua / shardsaveindex.lua —— ShardGameIndex 的 Save/WriteTimeFile",
  "--   参见 saveindex.lua —— 存档索引与非分片存档",
  "--   参见 dumper.lua DataDumper —— 阶段 F 的序列化器（把 table 转成 Lua 源码文本）",
  "--   参见 entityscript.lua:GetSaveRecord —— 阶段 B 的 record 生产者",
  "--   参见 entityscript.lua:SetPersistData —— 阶段 G 之后的反序列化消费者",
  "--   参见 components/worldstate.lua —— clock / seasons 的持有者（本文件 1268 行取值）",
  "--   参见 components/playerspawner.lua —— ms_playerdespawn 的监听者（1774 行注释提及）",
  "--   参见 walkableplatformmanager.lua:GetPlatformWithUID（428 行坐标还原）",
  "--   参见 modindex.lua / modutil.lua / mods.lua —— ModManager:GetModRecords（1189 行）",
  "--   参见 prefabs/global.lua —— SPECIAL_EVENT_GLOBAL_PREFABS 等常量",
  "--   参见 scheduler.lua —— scheduler:ExecuteInTime（1367 行等处大量使用）",
  "--   参见 frontend.lua FrontEnd() —— 1416 行创建的屏幕管理器",
  "--   参见 networkclientrpc.lua / networking.lua —— StartWorldSave / EndWorldSave 的实现在 C++",
  "--   参见 profile.lua Profile —— DoAutopause 读的用户偏好（916 行）",
  "--   参见 constants.lua —— BGCOLOURS / LoadingStates / BRANCH / VERBOSITY_LEVEL",
  "--   参见 util.lua —— shallowcopy / deepcopy / known_assert / TrackedAssert / RunInSandboxSafe",
  "--   参见 wordfilter.lua / knownerrors.lua —— ERRORS 表（1638 行已知错误提示）",
  "--   参见 03-参考架构/09_savegame.lua —— 本项目自建的存档模块参考实现（含 NaN 测试用例）",
  "--============================================================",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function build() {
  const specFile = join(__dirname, "spec-mainfunctions.mjs");
  const mod = await import(pathToFileURL(specFile).href);
  const HEADER_EXTRA = mod.HEADER_EXTRA ?? [];
  const BEFORE = mod.BEFORE ?? {};
  const AFTER = mod.AFTER ?? {};

  const raw = readFileSync(join(SRC_ROOT, "mainfunctions.lua"), "utf8");
  const srcLines = raw.split("\n");
  // 去掉文件末尾因换行产生的空元素，保证行号与 wc -l 一致
  if (srcLines.length > 1 && srcLines[srcLines.length - 1] === "") srcLines.pop();

  if (srcLines.length !== SRC_LINE_COUNT) {
    throw new Error(
      `源文件行数与规格预期不符: 实际 ${srcLines.length}, 预期 ${SRC_LINE_COUNT}`
    );
  }

  const out = [HEADER];
  for (const h of HEADER_EXTRA) {
    assertComment(h, "HEADER_EXTRA");
    out.push(h);
  }

  let injected = 0;

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
    }

    out.push(srcLines[i]); // ← 代码行永远原样取自源文件

    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
        out.push(c);
        injected++;
      }
    }
  }

  // 报告规格里是否有「行号不存在」的锚点
  const missing = [];
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  mkdirSync(dirname(join(OUT_ROOT, "mainfunctions.lua")), { recursive: true });
  writeFileSync(join(OUT_ROOT, "mainfunctions.lua"), text, "utf8");

  // ★ 实际落盘行数（out.length 是数组元素数，不等于行数——HEADER 是一个多行字符串）
  const outLineCount = text.split("\n").length;
  const headerLineCount = HEADER.split("\n").length;

  const count = (re) => (text.match(re) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ 已生成: ${join(OUT_ROOT, "mainfunctions.lua")}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  文件头行数     : ${headerLineCount}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  实际落盘行数   : ${outLineCount}  (文件头 ${headerLineCount} + 注释 ${injected} + 代码 ${srcLines.length})`);
  console.log(`  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`);
  console.log(`  机制标注【】   : ${count(/【/g)}`);
  console.log(`  重点标注★      : ${count(/★/g)}`);
  console.log(`  疑似缺陷⚠      : ${count(/⚠/g)}`);
  console.log(`  交叉引用参见    : ${count(/参见 /g)}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }`
  );
}

build().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});