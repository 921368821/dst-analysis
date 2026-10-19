#!/usr/bin/env node
/**
 * gen-builds.mjs —— 为 behaviours/ 目录批量生成「每个文件一个」的独立 build-<name>.mjs
 *
 * 说明：生成物与手工复制 build-combat.mjs 并改四处（SRC/SPEC/OUT/HEADER）完全等价，
 *      只是把机械部分自动化，避免手抄出错。生成物是独立的、可单独 node 运行的脚本，
 *      且都保留了末尾的 assertComment 断言。
 *
 * 用法：node gen-builds.mjs
 */
import { writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRCROOT = join(pristineRoot(), "behaviours");
const OUTROOT = join(ANN_SCRIPTS, "behaviours");

/**
 * 每项：
 *   name  —— 文件名（不含 .lua）
 *   mod   —— 模块归类
 *   duty  —— 职责（2~3 行）
 *   keys  —— 关键符号
 *   xref  —— 交叉引用
 */
const ITEMS = [
  {
    name: "follow",
    mod: "行为树节点库 / 跟随",
    duty:
      "把实体维持在目标周围的「三段距离带」内（max_dist 触发追 / target_dist 判定成功 /\n--       min_dist 触发后退），内含 APPROACH / BACKOFF 两态小状态机，\n--       并通过 Sleep(.25) 与大脑休眠机制协作。",
    keys:
      "Follow, Follow:Visit, Follow:GetTarget, Follow:EvaluateDistances,\n--           Follow:AreDifferentPlatforms, Follow:DBString",
    xref:
      "behaviourtree.lua（BehaviourNode 基类 / status 协议 / Sleep 休眠）,\n--           components/locomotor.lua（GoToPoint / RunInDirection / WalkInDirection）,\n--           components/combat.lua（跨平台能力 allow_platform_hopping）,\n--           approach.lua（同源的简化跟随节点）",
  },
  {
    name: "chaseandattack",
    mod: "行为树节点库 / 追击战斗",
    duty:
      "接管 combat.target 的所有权：READY 时校验/补索敌并战吼，RUNNING 时边压近边攻击，\n--       并用 max_chase_time / give_up_dist / max_attacks 三个阈值中任一触发即终止，\n--       另特判「目标站在无效地面（如海上）时只靠近到边缘」。",
    keys:
      "ChaseAndAttack, ChaseAndAttack:Visit, ChaseAndAttack:OnAttackOther,\n--           ChaseAndAttack:OnStop, ChaseAndAttack:__tostring",
    xref:
      "components/combat.lua（ValidateTarget / SetTarget / TryAttack / BattleCry / GiveUp / CalcAttackRangeSq）,\n--           components/locomotor.lua, stategraph（longattack / canrotate / running 状态标签）,\n--           standandattack.lua（同结构的站桩版）, chaseandram.lua, chaseandattackandavoid.lua",
  },
  {
    name: "approach",
    mod: "行为树节点库 / 接近",
    duty:
      "最简的「走到目标附近」节点：单一距离阈值 dist，走到即 SUCCESS。\n--       相比 follow 少了 min/max 双阈值与 BACKOFF 状态，适合「只需靠近、不需维持」的场合。",
    keys:
      "Approach, Approach:Visit, Approach:GetTarget, Approach:EvaluateDistances,\n--           Approach:AreDifferentPlatforms, Approach:DBString",
    xref:
      "follow.lua（本文件是它的简化子集，_distsq / AreDifferentPlatforms 为同源复制）,\n--           components/locomotor.lua, behaviourtree.lua（status 协议）",
  },
  {
    name: "findclosest",
    mod: "行为树节点库 / 查找",
    duty:
      "按标签在视野半径内挑选最近的一个实体并走到它身边，同时每 5 秒复查一次目标有效性。\n--       演示三种标签过滤语义的组合：必须全有(tags) / 必须全无(exclude_tags) / 至少一个(one_of_tags)。",
    keys:
      "FindClosest, FindClosest:Visit, FindClosest:PickTarget, FindClosest:DBString,\n--           CHECK_INTERVAL",
    xref:
      "TheSim:FindEntities（实际的空间查询）, components/locomotor.lua,\n--           entity:HasTag / IsValid, behaviourtree.lua",
  },
  {
    name: "leashandavoid",
    mod: "行为树节点库 / 拉拽回归",
    duty:
      "超出活动半径后回家，且回家途中绕开指定障碍物（含一段作者自嘲为\n--       「我这一生做过最大的 hack」的侧向绕行几何计算）。",
    keys:
      "LeashAndAvoid, LeashAndAvoid:Visit, LeashAndAvoid:GetHomePos,\n--           LeashAndAvoid:GetDistFromHomeSq, LeashAndAvoid:IsInsideLeash,\n--           LeashAndAvoid:IsOutsideReturnDist, LeashAndAvoid:GetMaxDistSq,\n--           LeashAndAvoid:GetReturnDistSq, LeashAndAvoid:DBString",
    xref:
      "leash.lua（同族无避障版本）, chaseandattackandavoid.lua（hack 的原始出处）,\n--       components/locomotor.lua, FunctionOrValue",
  },
  {
    name: "standandattack",
    mod: "行为树节点库 / 站桩战斗",
    duty:
      "原地站着持续攻击：不移动、不逃跑，只有「目标无效/超时/目标死亡」三种终止路径，\n--       超时计时器会被每次命中重置（starttime 置 nil）。",
    keys:
      "StandAndAttack, StandAndAttack:Visit, StandAndAttack:OnAttackOther,\n--           StandAndAttack:OnStop, StandAndAttack:__tostring",
    xref:
      "components/combat.lua（ValidateTarget / TryAttack / BattleCry）,\n--           stategraph（canrotate 状态标签）, chaseandattack.lua（同结构的移动版）",
  },
  {
    name: "wander",
    mod: "行为树节点库 / 漫游",
    duty:
      "在活动半径内随机选方向漫游，带「等待-行走-驻足」小状态机与回家的 IsFarFromHome 判定，\n--       是全目录里把「随机行为 + 时间节流」写得最完整的范本。",
    keys:
      "Wander, Wander:Visit, Wander:PickNewDirection, Wander:Wait,\n--           Wander:HoldPosition, Wander:GetHomePos, Wander:GetDistFromHomeSq,\n--           Wander:GetMaxDistSq, Wander:IsFarFromHome, Wander:DBString",
    xref:
      "components/locomotor.lua, behaviourtree.lua（status 协议）, leash.lua,\n--           findclosest.lua（同为 FindEntities 系节点）",
  },
  {
    name: "runaway",
    mod: "行为树节点库 / 逃跑",
    duty:
      "在给定时间内朝「远离威胁」的方向全速奔跑，支持贴墙滑行与无路可跑时的转向重试，\n--       是所有「逃跑类」AI 的几何参考实现。",
    keys:
      "RunAway, RunAway:Visit, RunAway:GetRunAngle, RunAway:__tostring",
    xref:
      "components/locomotor.lua（RunInDirection / ConstantMove / GetWalkablePoint）,\n--           panic.lua, panicandavoid.lua, avoids:avoidelectricfence.lua",
  },
  {
    name: "chaseandram",
    mod: "行为树节点库 / 冲撞",
    duty:
      "先冲过去把目标撞飞（ram），期间按 maxram_attacks 计数与 max_chase_time 限时，\n--       并含平台差异判定与「停止后短暂停顿」的节奏控制。",
    keys:
      "ChaseAndRam, ChaseAndRam:Visit, ChaseAndRam:OnAttackOther,\n--           ChaseAndRam:AreDifferentPlatforms, ChaseAndRam:OnStop,\n--           ChaseAndRam:__tostring",
    xref:
      "chaseandattack.lua（同族节点）, components/locomotor.lua,\n--           components/combat.lua, stategraph",
  },
  {
    name: "useshield",
    mod: "行为树节点库 / 防御",
    duty:
      "「举盾」状态机：ShouldShield 判定是否值得举盾 → Visit 驱动举盾/放下 → OnStop 收尾，\n--       附带 OnAttacked 事件回调与 TimeToEmerge（从地里钻出）计时。",
    keys:
      "UseShield, UseShield:Visit, UseShield:ShouldShield, UseShield:OnAttacked,\n--           UseShield:TimeToEmerge, UseShield:OnStop",
    xref:
      "components/combat.lua, components/shield.lua（举盾能力源）,\n--           stategraph, behaviourtree.lua（OnStop 与 Reset 的区别）",
  },
  {
    name: "chaseandattackandavoid",
    mod: "行为树节点库 / 追打避障",
    duty:
      "chaseandattack 的变体：在追击途中若发现「想躲的障碍物比目标更近」，\n--       就把目标点偏移到障碍物另一侧 —— leashandavoid 的绕行 hack 的原始出处。",
    keys:
      "ChaseAndAttackAndAvoid, ChaseAndAttackAndAvoid:Visit,\n--           ChaseAndAttackAndAvoid:OnAttackOther, ChaseAndAttackAndAvoid:OnStop,\n--           ChaseAndAttackAndAvoid:__tostring",
    xref:
      "chaseandattack.lua（基础版）, leashandavoid.lua（hack 的移植）,\n--           components/combat.lua, components/locomotor.lua",
  },
  {
    name: "runtodist",
    mod: "行为树节点库 / 位移",
    duty:
      "朝「离当前最远的若干候选点」跑过去（取距离最远的那个），常用于「往地图另一边跑」。\n--       GetRunPosition 封装了候选点的生成与打分。",
    keys:
      "RunToDist, RunToDist:Visit, RunToDist:GetRunPosition, RunToDist:__tostring",
    xref:
      "components/locomotor.lua, runaway.lua, behaviorutil.lua（GetFurthestPoint 等）",
  },
  {
    name: "controlminions",
    mod: "行为树节点库 / 单位控制",
    duty:
      "找出最近的一个从属单位并下达指令（由外部传入的控制函数），\n--       演示「节点作为指令调度器」而非「节点自己执行动作」的写法。",
    keys:
      "ControlMinions, ControlMinions:Visit, ControlMinions:GetClosestMinion",
    xref:
      "components/locomotor.lua, components/combat.lua, brain.lua（黑板 shared 变量）",
  },
  {
    name: "chattynode",
    mod: "行为树节点库 / 表演",
    duty:
      "让实体播放一段带时序的说话/表演动作（按 schedule 表推进），\n--       是不影响战斗的「纯表演节点」范例。",
    keys: "ChattyNode, ChattyNode:Visit",
    xref: "stategraph, animstate, behaviourtree.lua（Sleep 节流）",
  },
  {
    name: "leash",
    mod: "行为树节点库 / 拉拽回归",
    duty:
      "LeashAndAvoid 的无避障版本：超出 max_dist 就走回 home，\n--       进入 return_dist 内即 SUCCESS。两段阈值构成标准滞回。",
    keys:
      "Leash, Leash:Visit, Leash:GetHomePos, Leash:GetDistFromHomeSq,\n--           Leash:IsInsideLeash, Leash:IsOutsideReturnDist, Leash:GetMaxDistSq,\n--           Leash:GetReturnDistSq, Leash:DBString",
    xref: "leashandavoid.lua（同族带避障版本）, wander.lua, components/locomotor.lua",
  },
  {
    name: "avoidlight",
    mod: "行为树节点库 / 避让",
    duty:
      "躲避光源（火焰、余烬、探照灯）的节点：探测最近光源 → 计算侧向逃逸角 → 边走边等。",
    keys: "AvoidLight, AvoidLight:Visit, AvoidLight:PickNewAngle, AvoidLight:Wait",
    xref: "runaway.lua, avoidelectricfence.lua, components/locomotor.lua",
  },
  {
    name: "avoidelectricfence",
    mod: "行为树节点库 / 避让",
    duty:
      "躲避电栅栏（海象/巨鹿的电网）：检测到处于电栏范围时朝安全方向奔跑，\n--       含 GetRunAngle 的方向逃逸计算与 OnStop 清理。",
    keys:
      "AvoidElectricFence, AvoidElectricFence:Visit, AvoidElectricFence:GetRunAngle,\n--           AvoidElectricFence:OnStop, AvoidElectricFence:__tostring",
    xref: "runaway.lua, panicandavoid.lua, components/locomotor.lua",
  },
  {
    name: "panic",
    mod: "行为树节点库 / 逃跑",
    duty:
      "最简逃跑节点：一次性朝随机方向跑（PickNewDirection），无参数、无阈值，\n--       适合「受到惊吓时随便跑开一下」的场景。",
    keys: "Panic, Panic:Visit, Panic:PickNewDirection",
    xref: "panicandavoid.lua, runaway.lua, components/locomotor.lua",
  },
  {
    name: "panicandavoid",
    mod: "行为树节点库 / 逃跑",
    duty:
      "panic 的避障版本：ResolveDirection 在若干候选方向里挑一个既远离威胁又可落地的，\n--       演示「候选方向打分筛选」的通用套路。",
    keys:
      "PanicAndAvoid, PanicAndAvoid:Visit, PanicAndAvoid:ResolveDirection,\n--           PanicAndAvoid:PickNewDirection",
    xref: "panic.lua, runaway.lua, avoidelectricfence.lua",
  },
  {
    name: "beargeroffscreen",
    mod: "行为树节点库 / 复合 AI",
    duty:
      "全目录最长的节点（约 313 行）：把「离屏狂暴 AI」拆成 Roam / Rampage 两阶段，\n--       含沿途掉落（DropTrail）、沿路径处理实体（WorkEntitiesAlongLine）与边界内随机取点。",
    keys:
      "BeargerOffScreen, BeargerOffScreen:Visit, BeargerOffScreen:Roam,\n--           BeargerOffScreen:SetupRoaming, BeargerOffScreen:PickNewDirection,\n--           BeargerOffScreen:PickNewDirection_Rampage,\n--           BeargerOffScreen:GetRandomWanderDestWithinBoundary,\n--           BeargerOffScreen:DropTrail, BeargerOffScreen:DropTrailItem,\n--           BeargerOffScreen:DropGroundPoundTrail,\n--           BeargerOffScreen:WorkEntitiesAlongLine",
    xref:
      "behaviours/wander.lua（Roam 阶段大量复用）,\n--       components/locomotor.lua, TheWorld（阶段计时）,\n--       DropTrail 依赖 summoning 类实体的 spawn 机制",
  },
  {
    name: "findfarmplant",
    mod: "行为树节点库 / 查找",
    duty:
      "找最近的农作物（仿 follow/findclosest 家族的 PickTarget 写法），\n--       用于 NPC 农夫照料田地。",
    keys: "FindFarmPlant, FindFarmPlant:Visit, FindFarmPlant:PickTarget, FindFarmPlant:DBString",
    xref: "findclosest.lua（同族节点）, TheSim:FindEntities, components/locomotor.lua",
  },
  {
    name: "findflower",
    mod: "行为树节点库 / 查找",
    duty: "找最近的花（蜜蜂采蜜行为的一环），到达即 SUCCESS。",
    keys: "FindFlower, FindFlower:Visit, FindFlower:PickTarget, FindFlower:DBString",
    xref: "findclosest.lua, findfarmplant.lua, TheSim:FindEntities",
  },
  {
    name: "findlight",
    mod: "行为树节点库 / 查找",
    duty: "找最近的光源（与 avoidlight 的「躲光」互为镜像），用于扑火类生物。",
    keys: "FindLight, FindLight:Visit, FindLight:PickTarget, FindLight:DBString",
    xref: "avoidlight.lua（反向节点）, findclosest.lua, TheSim:FindEntities",
  },
  {
    name: "faceentity",
    mod: "行为树节点库 / 朝向",
    duty: "把实体转向某个目标实体（一次性动作，无参数化阈值），用于「说话时看着对方」。",
    keys: "FaceEntity, FaceEntity:Visit, FaceEntity:HasLocomotor",
    xref: "standandattack.lua（同样用 canrotate 状态标签）",
  },
  {
    name: "doaction",
    mod: "行为树节点库 / 动作",
    duty:
      "执行一次 bufferedaction（采集/交互），通过 OnSucceed / OnFail 两个事件回调\n--       把异步结果转成 SUCCESS / FAILED —— 是「回调 → 终态」桥接的范本。",
    keys: "DoAction, DoAction:Visit, DoAction:OnSucceed, DoAction:OnFail",
    xref:
      "bufferedaction.lua（动作队列）, behaviourtree.lua（status 终态被后续 Visit 消费）",
  },
  {
    name: "minperiod",
    mod: "行为树节点库 / 节流",
    duty:
      "装饰型节流节点：自身子节点/条件只有累计到指定周期才允许成功一次。\n--       是「用节点做限流」而非「在业务代码里写计时器」的示例。",
    keys: "MinPeriod, MinPeriod:Visit, MinPeriod:DBString",
    xref: "behaviourtree.lua（LatchNode 是同族但机制不同的实现）, brain.lua（period 语义）",
  },
  {
    name: "attackwall",
    mod: "行为树节点库 / 战斗",
    duty: "攻击最近的墙体/障碍物（如海象砸开冰墙），是 chaseandattack 的「无生命目标」简化版。",
    keys: "AttackWall, AttackWall:Visit, AttackWall:__tostring",
    xref: "chaseandattack.lua, components/combat.lua, components/locomotor.lua",
  },
  {
    name: "standstill",
    mod: "行为树节点库 / 待机",
    duty: "原地不动并保持一小段时间，是「等待」类行为的最小实现。",
    keys: "StandStill, StandStill:Visit",
    xref: "behaviourtree.lua（WaitNode 是它的框架内建版本）, components/locomotor.lua",
  },
  {
    name: "stalkerchaseandattack",
    mod: "行为树节点库 / 追打",
    duty:
      "本目录最短的节点（仅 10 行）：构造器里只存参数，全部逻辑靠 chattynode/参数化组合完成，\n--       是「用已有节点 + 参数拼装出行为」的极致例子。",
    keys: "StalkerChaseAndAttack",
    xref: "chaseandattack.lua（被包装的对象）, stalker 相关 brain",
  },
];

function header(it) {
  return [
    "--============================================================",
    "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
    `-- 文件：behaviours/${it.name}.lua`,
    `-- 模块：${it.mod}`,
    `-- 职责：${it.duty}`,
    `-- 关键符号：${it.keys}`,
    `-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本`,
    `-- 交叉引用：${it.xref}`,
    "--============================================================",
    "",
  ].join("\n");
}

let n = 0;
for (const it of ITEMS) {
  const src = `
#!/usr/bin/env node
/**
 * build-${it.name}.mjs —— ${it.name}.lua 深度中文注释生成器（锚点注入法）
 *
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-${it.name}.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置：在指定行号之后插入以 \`--\` 开头的注释行。
 *   · 任何插入内容都以 \`--\` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-${it.name}.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = "${SRCROOT}/${it.name}.lua";
const SPEC = join(__dirname, "spec-${it.name}.mjs");
const OUT = "${OUTROOT}/${it.name}.lua";

const HEADER = ${JSON.stringify(header(it))};

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (t !== "" && !t.startsWith("--")) {
    throw new Error(\`规格错误 @\${where}: 非注释行 -> \${JSON.stringify(line)}\`);
  }
  // 防编码损坏：U+FFFD 说明写入时字符被截断，必须修好再生成
  if (line.includes("\\uFFFD")) {
    throw new Error(\`规格错误 @\${where}: 含 U+FFFD 替换字符（编码损坏）-> \${line}\`);
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const mod = await import(specUrl);
  const AFTER = mod.default; // { 行号: [注释行...] }

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split(/\\r?\\n/);
  if (srcLines.length && srcLines[srcLines.length - 1] === "") srcLines.pop();

  const out = [HEADER.replace(/\\n$/, "")];

  let injected = 0;
  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    out.push(srcLines[i]); // ← 代码行永远原样取自源文件
    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, \`AFTER[\${lineno}]\`);
        out.push(c);
        injected++;
      }
    }
  }

  const missing = [];
  for (const key of Object.keys(AFTER)) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(\`规格中存在越界行号: \${missing.join(", ")}\`);
  }

  const text = out.join("\\n");
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  let cov = 0;
  for (const k of Object.keys(AFTER)) {
    const n = Number(k);
    if (n >= 1 && n <= srcLines.length) cov++;
  }

  console.log(\`✔ 已生成: \${OUT}\`);
  console.log(\`  源文件行数     : \${srcLines.length}\`);
  console.log(\`  输出文件行数   : \${out.length}\`);
  console.log(\`  注入注释行数   : \${injected}\`);
  console.log(
    \`  注释锚点行数   : \${cov} (覆盖率 \${((cov / srcLines.length) * 100).toFixed(1)}%)\`
  );
  console.log(\`  机制标注【】   : \${mech}\`);
  console.log(\`  重点标注★      : \${star}\`);
  console.log(\`  疑似缺陷⚠      : \${warn}\`);
  console.log(
    \`  保护标记在前10行: \${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }\`
  );
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});
`.trimStart();
  writeFileSync(join(__dirname, `build-${it.name}.mjs`), src, "utf8");
  n++;
}
console.log(`✔ 已生成 ${n} 个 build-*.mjs`);
