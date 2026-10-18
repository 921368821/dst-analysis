#!/usr/bin/env node
/**
 * build-playercontroller.mjs —— components/playercontroller.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-actions.mjs / build-locomotor.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-playercontroller.mjs / spec-playercontroller-p1..p10.mjs 中，
 *     以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *   · 规格里任何非 `--` 开头的行都会在构建期抛错（assertComment）。
 *
 * 用法：node build-playercontroller.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts";
const OUT_ROOT = "E:/DST-Analysis/02-注释源码/scripts";
const SRC_REL = "components/playercontroller.lua";

/* ────────────────────────── 文件头 ────────────────────────── */

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/playercontroller.lua（5940 行，DST 玩家操控的唯一中枢）",
  "-- 模块：组件 / playercontroller（玩家控制器）",
  "-- 职责：把「玩家的物理输入」翻译成「引擎可执行的状态变更」，并在这条链路上",
  "--       插入一层**客户端预测 + 服务端权威**的双端协议。文件内部可以粗暴地分成",
  "--       六大块，每一块都围绕一个「意图 → 执行体」的映射：",
  "--   ① 输入分发（21-718）    键鼠/手柄事件 → DoXxxButton",
  "--   ② 动作选择（1737-2472）鼠标指向 → 「这一刻能做什么」→ BufferedAction",
  "--   ③ 手柄目标锁定（3178-3690）方向键 → 打分排序 → controller_target/_attack_target",
  "--   ④ 移动链路（3693-4432）★核心★ 意图编码 → RPC → locomotor 驱动 → 橡皮筋纠正",
  "--   ⑤ 地图动作（5122-5319） 屏幕坐标 → 世界坐标 → 仅在地图上可做的动作",
  "--   ⑥ 库存格子与法术书（5562-5748）手柄 UI 直连动作",
  "--",
  "-- ★★★ 全文件第一认知：这不是「玩家逻辑」，而是「网络协议适配层」。",
  "--   PlayerController 在双端都存在同一个类，但**角色完全不同**：",
  "--     · 客户端（handler ~= nil，即本机玩家）：它是**输入源 + 预测器**。",
  "--       按键立刻本地生效（locomotor:PreviewAction / PreviewWalking），",
  "--       同时把「我打算做什么」压缩成整数 actioncode 用 RPC 发给服务器。",
  "--     · 服务端（handler == nil，即远端玩家）：它是**验证器 + 执行器**。",
  "--       OnRemoteXxx 收到 RPC 后**重新跑一遍同样的 GetXxxAction**，",
  "--       只有当重算出的 action.code 与客户端上报的 code 完全一致时才执行。",
  "--   ⇒ 推论 1：客户端上报的不是「结果」而是「意图编号」，服务端永远可以否决。",
  "--   ⇒ 推论 2：任何在 GetXxxAction 里读 TheInput 的代码，在服务端都读不到",
  "--             ——所以服务端路径必须靠 SetClientRequestedAction（995/2329 行）",
  "--             把客户端的 actioncode 临时注入 playeractionpicker 的分支条件里。",
  "--   ⇒ 推论 3：所以「双击两次」「按住不放」这类纯客户端交互，在服务端会退化成",
  "--             一次单次请求。客户端必须用 --V2C: 注释标记的补充协议来补齐。",
  "--",
  "-- ★★★ 全文件第二认知：三个远端玩家**没有输入设备**，必须靠 remote_* 镜像。",
  "--   这个镜像由四个字段族构成，是本文件最难读的部分：",
  "--   ① remote_vector（Vector3）—— 移动意图，见 3694 行顶部注释",
  "--      ★★ y 分量一字段三语义（本项目重点，参见 bug-patterns.md B8）：",
  "--        0 = 停止 / 无意图",
  "--        1 = 直接行走（x/z 是**方向向量**，不是坐标）",
  "--        2 = 拖拽行走（x/z 是**世界坐标**）",
  "--        3 = 预测行走·直接（x/z 是目标坐标）",
  "--        4 = 预测行走·拖拽（x/z 是目标坐标）",
  "--        5 = 预测行走但正在执行动作（目标坐标被冻结，见 5801 行）",
  "--        6 = 跳跃（hopping，见 3884 行）",
  "--      ⇒ y>=3 时 GetRemotePredictPosition 会把 y 当作**真实高度**返回（3743 行），",
  "--        此时 y 只是恰好等于 3/4/5/6 而已，绝不是海拔。这是 B8 缺陷的根源。",
  "--      ⇒ 客户端只发 x/z 两��（3905 行 DirectWalking 注释明确说明），",
  "--        y 完全由服务端按 isdirectwalking/isstop 推导，压缩了带宽。",
  "--   ② remote_controls（table）—— 按键按下态。键 → 剩余冷却秒数。",
  "--      ★ 双重身份：①本地查询（IsControlPressed 515 行）②RPC 幂等去重",
  "--      （BUTTON_REPEAT_COOLDOWN/.5 阻止连点刷动作）。",
  "--   ③ remote_predict_dir / _stop_tick / _stop_notified —— 预测停止的三段握手。",
  "--   ④ recent_bufferedaction —— 「刚放下方向键时不要取消刚缓冲的动作」的护栏。",
  "--",
  "-- ★★★ 全文件第三认知：**V2C = V2C**，即 「Vehicle-to-Client」不，是引擎内部的",
  "--   客户端预测补丁标记（Client Prediction）。全文件 42 处 V2C 注释、8 处",
  "--   FIXME/FIXED(JBK) 标记，说明这套预测链路是**长期打补丁**演化出来的。",
  "--   阅读时凡遇 V2C/FIXME，一律把它当成「这里曾经出过 bug」的墓碑：",
  "--     · 4 处 FIXME(JBK): Boat handling.（4041/4086/4099/5794）—— 船只场景至今未修。",
  "--     · 4084 行 --V2C: don't override rubberband —— 详见下面橡皮筋一节。",
  "--     · 4768 行注释明说「为了不破坏 legacy 行为，只给有双击动作的玩家开这个修复」。",
  "--",
  "-- ── 本文件**不包含**的内容（grep 核实，勿在本文件里找） ──",
  "--   × sprint / 奔跑：grep -niE sprint components/playercontroller.lua → 0 命中。",
  "--     奔跑消耗与速度加成在 locomotor（GetRunSpeed:593）+ 角色 prefab 里。",
  "--   × 饥饿度 / 理智值驱动减速：grep -niE 'hunger|sanity' → 0 命中。",
  "--     减速走 locomotor:SetExternalSpeedMultiplier（567 行），调用方是",
  "--     carefulwalker/grogginess/rooted/miasmawatcher 等组件，饥饿在 hunger.lua。",
  "--   × 跳跃高度 / 空中控制 / 落地伤害：grep -niE 'jump|fall|dropdamage' → 0 命中。",
  "--     本文件只有**平台跳跃（hopping）** 的协议部分（3835-3901），",
  "--     物理部分在 locomotor:StartHopping:1396。",
  "--   × Respawn 流程 / 重生点选择：grep -niE respawnpoint → 0 命中。",
  "--     本文件只有 ACTIONS.REMOTERESURRECT（2426 行，遥控台复活）与",
  "--     ACTIONS.REVIVE_CORPSE（2061 行，复活尸体）。",
  "--   × 控制台命令 / cheat：grep -c AddConsoleCommand → 0 命中。",
  "--     但 94 行 IsConsole() 会让主机玩家拿到 remote_authority 权限（见下）。",
  "--",
  "-- ★★ remote_authority（本文件最容易被误读的权限位，94-98 行）：",
  "--   self.remote_authority = IsConsole() or client.admin or client.moderator or client.friend",
  "--   它**不是**「客户端预测是否开启」的开关，而是「服务器是否相信客户端意图」",
  "--   的信任位。开启后，4039 行的「过冲瞬移」和 5782 行的「动作前对齐」",
  "--   都会**无条件**执行（直接 Transform:SetPosition 硬瞬移、不做距离校验）。",
  "--   ⚠ 这意味着主机/房主/管理者的客户端可以直接把自己的位置拉过去。",
  "--     这是有意为之（房主不该被自己的网络延迟拖累），但它同时是一条真实的",
  "--     作弊面：房主客户端被改内存即可任意瞬移，且**不会**被橡皮筋拉回。",
  "--     参见 4039-4043、5778-5785、3789 三处依赖点。",
  "--",
  "-- 关键符号：",
  "--   PlayerController（类本体）, GetWorldControllerVector（模拟摇杆→世界方向）,",
  "--   OnControl（★ 输入总入口，601 行）, IsEnabled（双返回值：enabled + hudblocking）,",
  "--   CanLocomote / IsBusy（预测准入判据）, DoAction（★ 所有按钮的共同汇合点，4542 行）,",
  "--   DoActionAutoEquip（自动装备白名单）, ClearActionHold / RepeatHeldAction（长按重复）,",
  "--   GetAttackTarget / ValidateAttackTarget / TargetIsHostile（战斗瞄准与过滤）,",
  "--   GetActionButtonAction / GetPickupAction（空间键的 17 级动作优先级链）,",
  "--   GetSceneItemControllerAction / GetGroundUseAction / GetGroundUseSpecialAction /",
  "--   GetItemUseAction / GetItemSelfAction（手柄与鼠标共用的动作查询族）,",
  "--   UpdateControllerAttackTarget / UpdateControllerInteractionTarget /",
  "--   UpdateControllerConflictingTargets（★ 手柄目标打分三件套）,",
  "--   remote_vector / GetRemoteDirectVector / GetRemoteDragPosition /",
  "--   GetRemotePredictPosition / GetRemotePredictStopXZ（★ 移动意图解码）,",
  "--   RemoteDirectWalking / RemoteDragWalking / RemotePredictWalking /",
  "--   RemoteStopWalking / OnRemoteXxxWalking（移动 RPC 的收发两端）,",
  "--   DoPredictWalking（★ 预测的驱动与纠正核心，4003 行）,",
  "--   DoDirectWalking / DoDragWalking / DoDoubleTapDir（三种移动手势）,",
  "--   DoBoatSteering（船上驾驶，与玩家行走互斥）, DoClientBusyOverrideLocomote,",
  "--   OnRemoteStartHop（跳跃的服务器校验，含橡皮筋距离计算）,",
  "--   GetMapActions / RemapMapAction / OnMapAction（地图动作）,",
  "--   EncodeControlMods / DecodeControlMods / MOD_CONTROLS（修饰键位掩码）,",
  "--   RegisterFindTags（TheSim 查询索引，两处注册）, GetMapTarget / PullUpMap,",
  "--   HasAOETargeting / TryAOETargeting / TryAOECharging（AOE 施法与蓄力）,",
  "--   OnLocomotorBufferedAction（动作意图广播给 AI）, RemoteInteractionTarget",
  "--   OnRemoteToggleMovementPrediction（★ 客户端预测的总开关，由外部 UI 控制）",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 networkclientrpc.lua —— 本文件所有 Remote* 的对端",
  "--     networkclientrpc.lua:387 DirectWalking（★ 校验 x*x+z*z<1.01，即方向归一化）",
  "--     networkclientrpc.lua:403 DragWalking（★ 先 IsPointInRange 再转换平台坐标）",
  "--     networkclientrpc.lua:425 PredictWalking（★ 双重 or 校验：全nil 或 全合法）",
  "--     networkclientrpc.lua:43  IsPointInRange —— 半径 64（distsq<=4096）的反外挂闸",
  "--     networkclientrpc.lua:48  ConvertPlatformRelativePositionToAbsolutePosition",
  "--     networkclientrpc.lua:30  printinvalidplatform（第 33 行把 Platform 拼成 Playform ⚠）",
  "--     networkclientrpc.lua:491 StartHop / :508 SteerBoat / :520 StopWalking",
  "--     networkclientrpc.lua:61 LeftClick / :113 RightClick / :163 ActionButton",
  "--     networkclientrpc.lua:179 AttackButton / :205 ResurrectButton / :223 ControllerActionButton",
  "--     networkclientrpc.lua:356 ControllerAttackButton / :369 StopControl / :380 StopAllControls",
  "--     networkclientrpc.lua:1100 RepeatHeldAction / :1107 ClearActionHold / :1129 DoActionOnMap",
  "--   ★★ 参见 components/locomotor.lua —— 本文件只发意图，locomotor 才产生位移",
  "--     locomotor.lua:782 PreviewAction（★ 客户端预测的动画+位移入口）",
  "--     locomotor.lua:882 PushAction（服务端权威执行入口）",
  "--     locomotor.lua:1091 Stop / :755 Clear（★ Clear 会额外清 bufferedaction）",
  "--     locomotor.lua:1141 RunInDirection / :705 SetMoveDir / :741 WalkForward",
  "--     locomotor.lua:1078 SetBufferedAction / :403 GetTimeMoving / :452 PopOverrideTimeMoving",
  "--     locomotor.lua:461 RestartPredictMoveTimer / :465 CancelPredictMoveTimer /",
  "--     locomotor.lua:469 OverridePredictTimer（★ 预测移动的「超时自杀」三件套）",
  "--     locomotor.lua:1396 StartHopping / :1222 GetHopDistance / :1200 SetAllowPlatformHopping",
  "--     locomotor.lua:593 GetRunSpeed / :982 与 :1040 GoToEntity/GoToPoint",
  "--     locomotor.lua:1087 反向调用本文件 OnLocomotorBufferedAction",
  "--     locomotor.lua:930 反向调用本文件 GetRemotePredictPositionExternal",
  "--   ★★ 参见 components/playeractionpicker.lua —— 「这一刻能做什么」的真正实现",
  "--     playeractionpicker.lua:301 GetLeftClickActions / :388 GetRightClickActions",
  "--     playeractionpicker.lua:207 GetPointActions / :225 GetPointSpecialActions",
  "--     playeractionpicker.lua:240 GetDoubleClickActions / :257 GetInventoryActions",
  "--     playeractionpicker.lua:142 GetUseItemActions / :109 GetSceneActions",
  "--     playeractionpicker.lua:498 DoGetMouseActions（★ LMB+RMB 一次算完）",
  "--   ★★ 参见 actions.lua / bufferedaction.lua —— 动作原型与执行实例",
  "--     actions.lua:357 ACTIONS 表（ACTIONS[k] 与 TOOLACTIONS 的键名对应）",
  "--     bufferedaction.lua:1 BufferedAction（★ 冻结 doer/target/invobject/pos）",
  "--     bufferedaction.lua:14 self.options（★ DoAction/RepeatHeldAction 往里塞临时标志）",
  "--     componentactions.lua:3181 CollectActions（condition 的等价物在这里）",
  "--     componentactions.lua:463 HasAOETargeting 的一个消费点",
  "--   ★★ 参见 entityscript.lua —— bufferedaction 的宿主",
  "--     entityscript.lua:1609 PushBufferedAction / :1654 PerformBufferedAction",
  "--     entityscript.lua:1689 GetBufferedAction / :1563 ClearBufferedAction",
  "--     entityscript.lua:1794 CanDoAction（最终鉴权）",
  "--   ★★ 参见 stategraphs/SGwilson.lua / SGwilson_client.lua —— 动画与 busy 判定",
  "--     SGwilson.lua:1319 sg.mem.localchainattack（★ 3110 行读的就是这个）",
  "--     SGwilson.lua:4326 HUNGRY_THRESH（饥饿的动画阈值，与减速无关）",
  "--   ★★ 参见 prefabs/player_classified.lua —— 服务端→客户端的同步载体",
  "--     player_classified.lua:1602 busyremoteoverridelocomote（--WASD）",
  "--     player_classified.lua:1603 busyremoteoverridelocomoteclick（--L.click）",
  "--     player_classified.lua:1467 ismapcontrolsvisible",
  "--   ★★ 参见 components/combat.lua / combat_replica.lua —— 攻击合法性",
  "--     combat.lua:348 IsRecentTarget / :471 SetTarget / :747 CanTarget / :1321 IsAlly",
  "--     combat_replica.lua:82 GetAttackRangeWithWeapon / :311 CanTarget",
  "--   ★★ 参见 screens/mapscreen.lua —— 地图动作的另一侧",
  "--     mapscreen.lua:1361-1362 反向设置 playercontroller._hack_ignore_held_controls",
  "--     mapscreen.lua:1313 mapscreen 自己也有一份 _hack_ignore_ups_for",
  "--   参见 simutil.lua:31 FindEntity（空间查询的通用封装，本文件用了 12 次）",
  "--   参见 util.lua:553 distsq / mathutil.lua:81 DiffAngle / :90 DiffAngleRad",
  "--   参见 constants.lua:2183 TOOLACTIONS（8 个工具动作的标签约定）",
  "--   参见 constants.lua:2306 DOUBLE_CLICK_TIMEOUT=.5 / :2307 DOUBLE_CLICK_POS_THRESHOLD=3",
  "--   参见 bug-patterns.md B8（★ remote_vector.y 一字段三语义，本文件的重灾区）",
  "--   参见 04-联机同步-模组系统-UI.md「移动预测链路」章节",
  "--============================================================",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function build(srcFile, outFile, header, specFile) {
  const specUrl = pathToFileURL(specFile).href;
  const mod = await import(specUrl);
  const HEADER_EXTRA = mod.HEADER_EXTRA ?? [];
  const BEFORE = mod.BEFORE ?? {};
  const AFTER = mod.AFTER ?? {};

  const raw = readFileSync(join(SRC_ROOT, srcFile), "utf8");
  const srcLines = raw.split("\n");

  const out = [header.replace(/\n$/, "")];
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
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  const cross = (text.match(/参见 /g) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ 已生成: ${outFile}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`);
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
  console.log(`  交叉引用参见    : ${cross}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }`
  );
}

async function main() {
  await build(
    SRC_REL,
    join(OUT_ROOT, SRC_REL),
    HEADER,
    join(__dirname, "spec-playercontroller.mjs")
  );
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});