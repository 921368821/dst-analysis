#!/usr/bin/env node
/**
 * build-actions.mjs —— actions.lua / bufferedaction.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-behaviourtree.mjs / build-locomotor.mjs / build-stategraph.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-actions-p1..p10.mjs / spec-bufferedaction.mjs 中，
 *     以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *   · 规格里任何非 `--` 开头的行都会在构建期抛错（assertComment）。
 *
 * 用法：node build-actions.mjs [actions|bufferedaction|all]
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts";
const OUT_ROOT = "E:/DST-Analysis/02-注释源码/scripts";

/* ────────────────────────── 文件头 ────────────────────────── */

const HEADER_ACTIONS = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：actions.lua（7092 行，DST 最大的单一脚本文件）",
  "-- 模块：动作系统 / 动作注册表（Action Registry）",
  "-- 职责：回答「玩家能做什么」的唯一入口。包含五层内容：",
  "--   ① 范围与到达距离的校验函数族（1-291 行，共 14 个工具函数）",
  "--   ② Action 基类（294-351 行）—— 约 40 个字段，全部为「可选声明」",
  "--   ③ ACTIONS 表（357-741 行）—— 约 240 个动作的**原型声明**",
  "--   ④ 动作编号与网络映射（743-756 行）—— 把字符串 id 压成整数 code",
  "--   ⑤ 每个动作的 fn / strfn / stroverridefn / validfn / theme_music_fn 实现",
  "--      （768-7092 行）。★ 这 6300 行里 90% 是**同构模板**，只有少数动作",
  "--      有独特的判定链（详见下面 §三「同构模板谱系」）。",
  "--",
  "-- ★★ 全文件最重要的认知：Action 是**原型（prototype）**，不是执行实例。",
  "--   ACTIONS.CHOP 只是「斧头这一类动作的规格说明书」，真正的执行实例是",
  "--   BufferedAction（见 bufferedaction.lua），由 components/playercontroller.lua:4542",
  "--   在玩家按键时用 (doer, target, ACTIONS.CHOP, invobject, pos, ...) 现构造。",
  "--   一个 Action 对象在进程生命周期内**只创建一次**，被成千上万次引用。",
  "--   ⇒ 推论：Action 上任何「每次执行都要重置」的字段都是设计错误。",
  "--",
  "-- ★★ 关于 condition / act 分离 —— 本文件**没有**这两个字段，请勿照搬",
  "--   其他引擎的 Action 设计。DST 的对应机制是三件不同的东西：",
  "--     · fn         —— 执行体（服务端权威），见 307 行 `self.fn = function() return false end`",
  "--     · strfn      —— 「当前这个动作显示成什么字」（纯 UI 字符串）",
  "--     · validfn    —— 额外的**持续**有效性判据（bufferedaction.lua:46 只在",
  "--                    客户端 `not TheWorld.ismastersim` 时才调用）",
  "--   「能不能做」的判定**不在本文件**，而在 componentactions.lua 的",
  "--   COMPONENT_ACTIONS 表（3100+ 行）。那里才是 condition 的等价物。",
  "--   ★ 混淆这两个层次是读 actions.lua 最容易踩的坑。",
  "--",
  "-- 关键符号：",
  "--   Action（基类）, ACTIONS（动作原型表）, ACTION_IDS, ACTION_MOD_IDS,",
  "--   ACTIONS_BY_ACTION_CODE, MOD_ACTIONS_BY_ACTION_CODE, ACTIONS_MAP_REMAP,",
  "--   CLIENT_REQUESTED_ACTION, HIGH_ACTION_PRIORITY,",
  "--   SetClientRequestedAction / ClearClientRequestedAction,",
  "--   MakeRangeCheckFn / DefaultRangeCheck / PickRangeCheck / ExtraPickRange /",
  "--   PhysicsPaddedRangeCheck / CheckFishingOceanRange / CheckRowRange /",
  "--   CheckIsOnPlatform / CheckOceanFishingCastRange / CheckTileWithinRange /",
  "--   CheckInsideGolfGame / ShowPourWaterTilePlacer / ExtraPickupRange /",
  "--   ExtraDeployDist / ExtraDropDist / ExtraPourWaterDist / ExtraHealRange /",
  "--   ArriveAnywhere / ExtraWobyForagingDist / ExtraOpenCraftingRange /",
  "--   DoToolWork / ValidToolWork / CanOpenCharacterSpecificContainer /",
  "--   ShouldBlockGiving / IsFoodSafeToEat / ShouldLOOKATStopLocomotor /",
  "--   ShouldItemMimicBeRevealedFor / TryToSoulhop / COMPARE_WEIGHABLE_TEST",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 bufferedaction.lua —— 动作实例（执行体在这里，不在本文件）",
  "--   参见 componentactions.lua:3108 AddComponentAction —— 动作的第二个注册入口",
  "--   参见 componentactions.lua:3181 CollectActions —— condition 的等价物在这里",
  "--   参见 componentactions.lua:3063-3066 workable 的注册（CHOP/MINE/DIG 的标签判定）",
  "--   参见 componentactions.lua:3209 isvalid_list —— validfn 的第二个注册入口",
  "--   参见 entityscript.lua:1609 PushBufferedAction（客户端预测入口）",
  "--   参见 entityscript.lua:1650 PerformBufferedAction（提交执行 Do()）",
  "--   参见 entityscript.lua:1689 GetBufferedAction（当前动作的查询）",
  "--   参见 entityscript.lua:1563 ClearBufferedAction（打断 → Fail）",
  "--   参见 entityscript.lua:1794 CanDoAction（inherentactions / 标签 / 手持物）",
  "--   参见 entityscript.lua:93 actioncomponents（动作组件的网络同步载体）",
  "--   参见 components/playercontroller.lua:4542 DoAction（客户端按键入口）",
  "--   参见 components/playercontroller.lua:4585 「重复动作」判定（防连点）",
  "--   参见 components/playercontroller.lua:4623 lastheldaction（invalid_hold_action 的消费点）",
  "--   参见 components/playercontroller.lua:4634 DoActionAutoEquip（自动装备白名单）",
  "--   参见 components/playercontroller.lua:5272-5281 OnMapAction（地图动作的鉴权）",
  "--   参见 components/playercontroller.lua:2356 SendRPCToServer(ActionButton, actioncode)",
  "--   参见 components/locomotor.lua:882 PushAction（走路去做的分流）",
  "--   参见 components/locomotor.lua:1079 SetBufferedAction（覆盖旧动作 → Fail）",
  "--   参见 components/locomotor.lua:1452 每帧 IsValid → Clear（移动中的打断）",
  "--   参见 components/locomotor.lua:1466-1487 customarrivecheck 的调度与 invalid 处理",
  "--   参见 components/locomotor.lua:937-942 forced + rangecheckfn 的降级",
  "--   参见 stategraph.lua:405 PreviewAction（客户端预测动画）",
  "--   参见 stategraph.lua:430 StartAction（服务端权威动画）",
  "--   参见 modutil.lua:442 AddAction（模组注册动作）",
  "--   参见 modutil.lua:478 AddComponentAction（模组包装）",
  "--   参见 components/workable.lua:189 ShouldRecoil（反弹判定）",
  "--   参见 components/inventory.lua:1390 Inventory:RemoveItem（RemoveFromOwner 的返回语义）",
  "--   参见 components/inventoryitem.lua:468 RemoveFromOwner",
  "--   参见 components/talker.lua:266 Talker:Say（十参数签名的耦合点）",
  "--   参见 simutil.lua:547 CanEntitySeeTarget（静默失败的判据）",
  "--   参见 componentutil.lua:2087 ShouldItemMimicBeRevealedFor（反伪装守卫）",
  "--   参见 stringutil.lua:331 GetActionString / :434 GetActionFailString",
  "--   参见 prefabs/player_classified.lua:1590 actionmeter（长按进度环）",
  "--   参见 prefabs/wortox.lua:614 TryToPortalHop（BLINK 调用的 doer 方法）",
  "--   参见 behaviourtree.lua（AI 侧的缓冲动作用法：brains/beefalobrain.lua:171）",
  "--   参见 locomotor.lua（表现层与动作层的交接）",
  "--============================================================",
].join("\n");

const HEADER_BUFFEREDACTION = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：bufferedaction.lua（110 行）",
  "-- 模块：动作系统 / 动作实例与打断（Buffered Action）",
  "-- 职责：定义 BufferedAction —— 一次**具体**动作执行的完整上下文。",
  "--   它把「谁（doer）对谁（target）做什么（action）用什么（invobject）",
  "--   在哪里（pos）做」打包成不可变快照，并在真正执行的那一帧调用",
  "--   action.fn(self)。本文件是 actions.lua 与 locomotor / stategraph 之间的",
  "--   **协议层**：actions.lua 只定义「动作是什么」，本文件定义「这一次执行」。",
  "--",
  "-- ★★ 为什么必须有这一层（不能直接把参数塞给 fn）？",
  "--   因为动作要「缓冲」。玩家按键的那一刻目标还在范围内，走到跟前可能",
  "--   已经跑远了。BufferedAction 在**按键瞬间**就把 target / invobject / pos",
  "--   冻结下来，并记下 initialtargetowner（见 5 行），使得：",
  "--     · 途中目标被别人捡走 → 动作作废（IsValid 的第 3 个条件）",
  "--     · 途中物品被别人抢走 → 动作作废（第 4 个条件）",
  "--   ★★ 这就是「打断」的全部机制：没有 timeout，没有取消队列，",
  "--     只有一个每次执行前重新求值的 IsValid()。",
  "--",
  "-- 关键符号：BufferedAction（类）, BufferedAction.TestForStart（= IsValid 别名）",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 actions.lua:294 Action —— 本文件持有的是它的**引用**",
  "--   参见 actions.lua:307 `self.fn = function() return false end`（默认失败的 fn）",
  "--   参见 actions.lua:349 invalid_hold_action（长按禁止重发）",
  "--   参见 entityscript.lua:1624 TestForStart 调用点（PushBufferedAction）",
  "--   参见 entityscript.lua:1640 instant 动作的立即 Do() 路径",
  "--   参见 entityscript.lua:1672 PerformBufferedAction → bufferedaction:Do()",
  "--   参见 entityscript.lua:1563 ClearBufferedAction → 本文件 104 行 Fail()",
  "--   参见 components/locomotor.lua:899 PushAction 开头的 TestForStart",
  "--   参见 components/locomotor.lua:1079 SetBufferedAction → 本文件 104 行 Fail()",
  "--   参见 components/locomotor.lua:1452 每帧 `not bufferedaction:IsValid()` → Clear()",
  "--   参见 components/playercontroller.lua:4542 DoAction（构造本类实例）",
  "--   参见 components/playercontroller.lua:4585 「重复动作」判定（防连点）",
  "--   参见 components/playercontroller.lua:4636 autoequipped 的唯一赋值点",
  "--   参见 prefabs/wortox.lua:614 TryToPortalHop（BLINK 动作会调用的 doer 方法）",
  "--   参见 behaviourtree.lua（对照：AI 侧用「破坏性 Reset」中断，",
  "--     与本文件「反复求值 IsValid」是两种完全不同的中断范式）",
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
  const which = process.argv[2] || "all";
  if (which === "all" || which === "actions") {
    await build(
      "actions.lua",
      join(OUT_ROOT, "actions.lua"),
      HEADER_ACTIONS,
      join(__dirname, "spec-actions.mjs")
    );
  }
  if (which === "all" || which === "bufferedaction") {
    await build(
      "bufferedaction.lua",
      join(OUT_ROOT, "bufferedaction.lua"),
      HEADER_BUFFEREDACTION,
      join(__dirname, "spec-bufferedaction.mjs")
    );
  }
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});
