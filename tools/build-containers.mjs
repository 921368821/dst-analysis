#!/usr/bin/env node
/**
 * build-containers.mjs —— 容器系统深度中文注释生成器（锚点注入法）
 *
 * 与 build-inventory.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-containers-p*.mjs / spec-ccomponent-p*.mjs 中，
 *     以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *   · 规格里任何非 `--` 开头的行都会在构建期抛错（assertComment）。
 *   · 规格里出现越界行号（超出源文件行数）同样在构建期抛错。
 *
 * 用法：node build-containers.mjs [params|component|all]
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT = pristineRoot();
const OUT_ROOT = ANN_SCRIPTS;

/* ────────────────────── 文件头：containers.lua ────────────────────── */

const HEADER_PARAMS = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：containers.lua（2504 行）",
  "-- 模块：容器系统 / 全局容器「配置表」（Container Params Registry）",
  "--",
  "-- ★★★ 本文件的身份：一本**静态数据字典**，不是逻辑实现。",
  "--   它导出 `containers` 一张表，里面两样东西：",
  "--     ① containers.params —— 以 prefab 名为键的**容器蓝图**（约 90 条）；",
  "--     ② containers.widgetsetup(container, prefab, data) —— 把蓝图",
  "--        灌进组件的**唯一入口**。",
  "--   全文件 2504 行里**没有一行是「运行时的容器逻辑」**，全部是",
  "--   `params.<名字> = { widget = {...}, type = \"...\", ... }` 与",
  "--   `function params.<名字>.itemtestfn(...)` 的声明。",
  "--   ⇒ 真正的逻辑全在 components/container.lua（服务端组件）与",
  "--     components/container_replica.lua（客户端镜像）。",
  "--",
  "-- ★★ 全文件最重要的认知一：**容器没有「类」，只有「类型字符串」**。",
  "--   任务描述里提到的 `CONST.GRID` / `STACKABLE` / `FRIDGE` / `CHEST`",
  "--   这些「容器类型常量」——★ grep 核实：本文件**从未出现 `CONST.`**",
  "--   （零命中），也不存在名为 Container 的类。同名的三个常量都别处：",
  "--     · constants.lua:1440  GRID = 3  →  属于 LAYOUT 表，",
  "--       是**世界生成布局**（3 = 网格），与容器毫无关系；",
  "--     · constants.lua:669  ITEMTAG.STACKABLE = \"stackable\"  →  物品标签；",
  "--     · constants.lua:1972 UPGRADETYPES.CHEST = \"chest\"  →  箱子升级动画类型。",
  "--   容器真正的「类型」就是本文件里的裸字符串，对应 containers.lua 第 18 行",
  "--   `self.type`。全文件 type 取值统计（grep 核实）：",
  "--     \"chest\"×24  \"cooker\"×21  \"pack\"×6  \"hand_inv\"×6",
  "--     \"side_inv_behind\"×3  \"backpack\"×2  \"inv\"×1  \"top_rack\"×1",
  "--     另有动态类型：第 2282 行 typefn 返回的 \"chest_addon\"。",
  "--   ★ 这些字符串的唯一用途有且只有三处（见下），不是标签系统。",
  "--",
  "-- ★★ 全文件最重要的认知二：type 字符串只被当作「**UI 挂载点选择器**」用。",
  "--   grep 核实全部消费点只有 4 个文件：",
  "--     · components/container.lua:625 —— Open 时关掉「同 prefab 或同 type」",
  "--       的其他已开容器（同一时间只允许开一个同类）；",
  "--     · screens/playerhud.lua:395-400 —— 决定 ContainerWidget 挂到 HUD 的",
  "--       哪个 root（容器出现在屏幕的哪个方位）；",
  "--     · components/inventory.lua:2120 —— CloseAllChestContainers 只关",
  "--       type == \"chest\" 的；",
  "--     · prefabs/storage_robot_common.lua:78 / prefabs/wobycommon.lua:552",
  "--       —— 白名单只有 { \"chest\", \"pack\" }。",
  "--   ⇒ **type 不参与物品筛选，也不参与容量计算**。",
  "--     「冰箱」之所以只能装食物，靠的是 itemtestfn（第 1019 行），",
  "--     **不是**因为它的 type 叫 \"chest\"。",
  "--",
  "-- ★★ 全文件最重要的认知三：物品筛选规则**只有两个**入口，",
  "--   而第二个在本文件中**完全不存在**（★ grep 核实全库零命中）：",
  "--     ① itemtestfn(container, item, slot) —— 本文件 40+ 处声明，",
  "--       被 components/container.lua:295 的 CanTakeItemInSlot 调用；",
  "--     ② globaltestfn —— **不存在**。全库 grep `globaltestfn` 零命中。",
  "--   同样地，任务描述提到的 ★ rangecheck / maxweight 在容器系统里",
  "--   **都不存在**：",
  "--     · rangecheck —— grep 全库只在 actions.lua 里以 rangecheckfn 形式存在",
  "--       （如 actions.lua:370 DefaultRangeCheck），是**动作距离**判定，",
  "--       容器不引用它；",
  "--     · maxweight —— grep 全库只在 loadingtipsdata.lua:63 出现（加载提示权重），",
  "--       容器**没有重量上限**这一概念。",
  "--     容器真正的「限制」是 slots 数量（numslots）与 acceptsstacks，",
  "--     见 components/container.lua:107 IsFull / 322 AcceptsStacks。",
  "--   ⇒ 那些能塞进**无限多物品**的容器（冰箱/箱子）不是靠 maxweight，",
  "--     而是因为 numslots 固定、而每摞的 stacksize 由 stackable.maxsize 决定。",
  "--",
  "-- ★★ 全文件最重要的认知四：itemtestfn 的统一表达范式。",
  "--   本文件 40 多个 itemtestfn 虽然内容各异，但**骨架完全一致**：",
  "--     function params.X.itemtestfn(container, item, slot)  -- 三参约定",
  "--         return <标签判定> and <额外约束>  -- 单行布尔表达式",
  "--     end",
  "--   签名固定为 (container, item, slot)——注意**第一个参数是 container 自己**：",
  "--   因为 components/container.lua:295 写成 `self:itemtestfn(item, slot)`，",
  "--   冒号调用把 self 补到第一个形参。所以本文件里写 `container.inst:HasTag(...)`",
  "--   时，`container` 就是那个组件。",
  "--   ★ 冰箱（第 1019 行）是**四层漏斗**：",
  "--     白名单标签 icebox_valid/inventoryitemtemperature → 直接放行；",
  "--     再要求有保鲜状态 fresh/stale/spoiled → 否则拒；",
  "--     再排除 smallcreature → 最后遍历 FOODTYPE 找 edible_<TYPE>。",
  "--   这就是「冰箱只放食物」在通用语言里的表达：**没有冰箱这个类型，",
  "--   只有一条标签组合判定**。新增一个「肥料箱」只需再写一条同形状的闭包。",
  "--   ★ 而 priorityfn（第 1632 行等）是 itemtestfn 的**同函数别名**，",
  "--     但语义相反：itemtestfn 决定「能不能放」，priorityfn 决定",
  "--     「在专用容器（弹药包这类）里优先往哪放」，见 components/container.lua:319。",
  "--",
  "-- ★★ 全文件最重要的认知五：开合（Open/Close）**不在本文件**。",
  "--   本文件只提供一个与开合相关的配置项：openlimit（见下）。",
  "--   · openlimit —— 「最多允许多人同时打开」，grep 核实 9 处声明；",
  "--     判定在 components/container.lua:735 Container:CanOpen()，",
  "--     而 CanOpen 只被 actions.lua:1095/2484/2506 与 components/slingshotmods.lua:148",
  "--     调用——**Open 自身并不检查 CanOpen**，靠动作层守门。",
  "--   · canbeopened —— 声明在 components/container.lua:31，由 setter 转成",
  "--     **反向 netvar** container._cannotbeopened（container_replica.lua:6/277），",
  "--     即「服务端存的是不能开，客户端读出来取反」。",
  "--   · ⚠ 任务描述提到的 `Toggle` 方法：★ grep 核实 containers.lua 与",
  "--     components/container.lua 中**均不存在** Toggle，全库容器相关文件零命中。",
  "--     开合是 Open/Close 两个独立动作，切换逻辑在 actions.lua 的",
  "--     OPEN/OPENCONTAINER 动作里。",
  "--   · ⚠ 任务描述提到的 `IsVisible`：★ grep 核实容器三文件中**不存在**",
  "--     IsVisible。对应的查询是 components/container.lua:723 IsOpen、",
  "--     727 IsOpenedBy、731 IsOpenedByOthers。",
  "--",
  "-- 关键符号：containers.params（蓝图字典）, containers.widgetsetup（灌入入口）,",
  "--   containers.MAXITEMSLOTS（全局最大槽位数）, params.X.widget.slotpos,",
  "--   params.X.widget.slotbg, animbank/animbuild/animloop, side_align_tip,",
  "--   params.X.itemtestfn, params.X.priorityfn, widget.buttoninfo.fn/validfn,",
  "--   widget.slotposfn/slotscalefn/animfn/posfn, type, typefn, openlimit,",
  "--   acceptsstacks, usespecificslotsforitems, issidewidget, excludefromcrafting,",
  "--   lowpriorityselection, opensound/closesound, animbank_upgraded",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 components/container.lua:86 Container:WidgetSetup —— 唯一调用点",
  "--   ★★ 参见 components/container.lua:9-17 —— 本文件 widgetsetup 的服务端侧",
  "--   ★★ 参见 components/container.lua:269 CanTakeItemInSlot —— itemtestfn 调用点",
  "--   ★★ 参见 components/container.lua:735 CanOpen —— openlimit 的唯一判定",
  "--   参见 components/container_replica.lua:232 WidgetSetup —— 客户端侧同构入口",
  "--   参见 components/container_replica.lua:6-8 —— 三条反向 netvar 的定义",
  "--   参见 prefabs/container_classified.lua:1057 —— MAXITEMSLOTS 的消费点",
  "--   参见 constants.lua:650 MAXITEMSLOTS = 15 —— 物品栏的槽位上限（对照）",
  "--   参见 constants.lua:2928 CONTAINER_AUTOCLOSE_DISTANCE = 3 —— 自动关闭距离",
  "--   参见 constants.lua:2022 FOODTYPE —— 冰箱 edible_ 判定的枚举来源",
  "--   参见 constants.lua:2049 FOODGROUP.OMNI —— 胡子袋 edible_ 判定的枚举来源",
  "--   参见 screens/playerhud.lua:395-400 —— type 字符串的 UI 挂载点",
  "--   参见 components/inventory.lua:2120 CloseAllChestContainers —— type==\"chest\"",
  "--   参见 prefabs/storage_robot_common.lua:78 ALLOWED_CONTAINER_TYPES",
  "--   参见 components/inventory.lua —— 容器的「近亲」，GetOverflowContainer 一侧",
  "--============================================================",
].join("\n");

/* ────────────────────── 文件头：components/container.lua ────────────────────── */

const HEADER_COMPONENT = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/container.lua（1651 行）",
  "-- 模块：容器系统 / 容器组件（Container，服务端权威）",
  "--",
  "-- ★★★ 本文件是容器系统的**全部运行时逻辑**。它与 containers.lua 的关系",
  "--   是「蓝图 → 实现」：",
  "--     containers.lua              components/container.lua（本文件）",
  "--     ─────────────────          ──────────────────────────────────────",
  "--     params.<prefab> 蓝图  ──→   WidgetSetup 读蓝图、灌进 self",
  "--     itemtestfn 定义   ──→   CanTakeItemInSlot 第 295 行调用它",
  "--     openlimit        ──→   CanOpen 第 736 行判定它",
  "--     type             ──→   Open 第 625 行读它做「同类互斥」",
  "--     MAXITEMSLOTS     ──→   （不参与；只有 container_classified 用）",
  "--   ⇒ **蓝图里的每一个字段都必须在本文件里找到消费点**，",
  "--     否则它就是死配置。本文件顶部第 73-84 行 widgetprops 列表",
  "--     正是「本文件承认的蓝图字段白名单」。",
  "--",
  "-- ★★ 两层职责边界（本任务最需要回答的问题），结论四条：",
  "--   ① **状态所有权**：本文件（服务端组件）是唯一权威。self.slots 是",
  "--      稀疏表（稀疏、不可信，见下）。客户端永远不写 self.slots。",
  "--   ② **UI 与显示**：本文件只在两处碰 UI —— components/container.lua:637",
  "--      `doer.HUD:OpenContainer(...)` 与 :692 `doer.HUD:CloseContainer(...)`，",
  "--      以及 :653 RegisterContainer / :704 UnregisterContainer。",
  "--      **绘制、动画、鼠标捕获全在 containers 之外的 widgets/containerwidget.lua**。",
  "--   ③ **联机同步**：本文件**不发任何网络包**，它只 PushEvent(\"itemget\")",
  "--      与 PushEvent(\"itemlose\")（第 538/547/1047 行）。真正的转写发生在",
  "--      components/container_replica.lua:30-47：它 ListenForEvent 这两个事件，",
  "--      转成 container_classified 的 netvar（SetSlotItem）。",
  "--      ★ 这与 components/inventory.lua 的模式完全一致——",
  "--        「服务端组件只产生事件，replica 只负责网络，classified 负责存储」。",
  "--   ④ **物品筛选**：规则写在 containers.lua，判定在本文件第 269-296 行",
  "--      CanTakeItemInSlot，**每个入口（拖拽/点击/程序化 GiveItem）都必过它**。",
  "--",
  "-- ★★ 全文件最重要的认知一：★ 槽位是**稀疏表**，下标不可信。",
  "--   · self.slots 是 `{ [k] = Entity }`，RemoveItem_Internal 第 1040 行只做",
  "--     `self.slots[slot] = nil`，**不做元素搬移**；",
  "--   · 遍历一律用 pairs()（无序），只有「找空位」才用 1..numslots 的 for；",
  "--   · 为什么不搬移？因为槽位编号对玩家是有视觉记忆的——玩家记得",
  "--     「斧头在第 4 格」，搬移会让画面无故跳动。",
  "--     ★ 代价：槽号会越来越稀疏，UI 必须按 1..numslots 逐个问",
  "--     GetItemInSlot（container_replica.lua:434）。",
  "--",
  "-- ★★ 全文件最重要的认知二：**入容器出容器一律经过 CanTakeItemInSlot**。",
  "--   第 450 行 GiveItem 的第一道门就是它；第 1106/1129/1238/1262/1285/1316/1354",
  "--   七个点击/拖拽处理器的第一道门也都是它。",
  "--   ⇒ ★ 这就是「itemtestfn 的调用时机」的全部答案：",
  "--     · **拖拽时实时判定**（鼠标悬停即算，componentactions.lua:680/2551 侧）；",
  "--     · **点击时再判定一次**（本文件七个 Put/Take/Add/Swap/Move 处理器）；",
  "--     · **程序化放入时判定**（GiveItem 第 450 行）；",
  "--     · **查询时判定**（CanAcceptCount 第 406/430 行、",
  "--       GetSpecificSlotForItem 第 301 行）。",
  "--   ⇒ 判定被放在客户端（container_replica.lua:340 有一份同构实现）",
  "--     是为了 UI 立即反馈；服务端再判一次是为了防作弊。两份实现必须同步修改。",
  "--",
  "-- ★★ 全文件最重要的认知三：堆叠语义由 `acceptsstacks` 与 stackable 组件",
  "--   **共同**决定，本文件只做「协调」，不自己算数量：",
  "--   · acceptsstacks = false（蓝图里 20+ 处）→ GiveItem 第 534 行会把超量堆叠",
  "--     `Get()` 成单个，并**返回 false**（明明放进去了却报告失败，这是刻意的，",
  "--     见第 533 行原注释「this should probably have been handled earlier」）；",
  "--   · infinitestacksize（本文件独有的 makereadonly 只读开关，第 36 行）→",
  "--     第 543 行 SetIgnoreMaxSize(true)，让 stackable 忽略 maxsize 上限；",
  "--   · ★ 超量堆叠（overstacked）的处理散落在第 1160/1181/1216/1356/1434/1499 行，",
  "--     规则统一是「取 originalmaxsize 而非当前 stacksize」。",
  "--     DropOverstackedExcess（第 228 行）负责把多出来的部分**丢到地上**。",
  "--",
  "-- ★★ 全文件最重要的认知四：开合是**引用计数**（opencount），不是布尔。",
  "--   · openlist[doer] = true 是「谁开着」，opencount 是派生计数（第 633/684 行）；",
  "--   · 第 619 行 `if not self.skipautoclose then StartUpdatingComponent` ——",
  "--     skipautoclose 字段在第 34 行**被注释掉了**，也就是说该字段永远为 nil，",
  "--     自动关闭的 onupdate **永远开启**。⚠ 见第 34 行注释处的说明；",
  "--   · 第 625 行开一个容器前先把「同 prefab 或同 type」的旧容器关掉，",
  "--     实现「同类容器互斥」（背包只能开一个）；",
  "--   · 第 1059-1084 OnUpdate 是自动关闭的唯一实现：距离 >3（CONTAINER_AUTOCLOSE_DISTANCE）",
  "--     或视线被挡 → Close。",
  "--",
  "-- ★★ 全文件最重要的认知五：三个 makereadonly 开关是**只读属性系统**。",
  "--   第 36/37 行 `makereadonly(self, \"infinitestacksize\")` 与 readonlycontainer，",
  "--   配合 WidgetSetup 第 86-97 行的 removesetter/makereadonly 循环，",
  "--   使这些字段**只能通过 EnableInfiniteStackSize/EnableReadOnlyContainer 修改**。",
  "--   ★ 原因见 class.lua 的 property setter 实现：它们要同时改本地状态、",
  "--     改 netvar、再批量刷新槽内物品——不能被外部随手赋值打断。",
  "--",
  "-- 关键符号：Container（类）, slots, numslots, openlist, opencount, openlimit,",
  "--   canbeopened, acceptsstacks, usespecificslotsforitems, issidewidget,",
  "--   itemtestfn, priorityfn, type, widget, infinitestacksize, readonlycontainer,",
  "--   WidgetSetup, NumItems, IsFull, IsEmpty, SetNumSlots, CanTakeItemInSlot,",
  "--   GetSpecificSlotForItem, ShouldPrioritizeContainer, CanAcceptCount,",
  "--   GiveItem, RemoveItem, RemoveItemBySlot, RemoveItem_Internal, RemoveAllItems,",
  "--   GetItemInSlot, GetItemSlot, GetAllItems, Open, Close, IsOpen, IsOpenedBy,",
  "--   IsOpenedByOthers, CanOpen, GetOpeners, IsHolding, FindItem, FindItems,",
  "--   ForEachItem, GetSpecializedContainers, IsSpecializedContainer, Has,",
  "--   HasItemThatMatches, HasItemWithTag, GetItemsWithTag, GetItemByName,",
  "--   GetCraftingIngredient, ConsumeByName, OnSave, OnLoad, OnUpdate,",
  "--   PutOneOfActiveItemInSlot, PutAllOfActiveItemInSlot, SwapActiveItemWithSlot,",
  "--   MoveItemFromAllOfSlot, ReferenceAllItems, EnableInfiniteStackSize,",
  "--   EnableReadOnlyContainer, IsRestricted, IsThiefProof, DropEverything,",
  "--   DestroyContents, ItemTestFn 调用链",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 containers.lua:9 containers.widgetsetup —— 本文件唯一读取的外部数据源",
  "--   ★★ 参见 containers.lua:1019 冰箱 itemtestfn —— 筛选规则的四层漏斗范例",
  "--   ★★ 参见 components/container_replica.lua:30-47 —— itemget/itemlose → netvar",
  "--   ★★ 参见 prefabs/container_classified.lua —— 真正的网络数据载体",
  "--   ★★ 参见 prefabs/container_opener.lua —— 「谁开着」的第二个 classified 实体",
  "--   ★★ 参见 components/inventory.lua —— 同构的近亲（容器是物品栏的溢出目标）",
  "--   参见 components/inventory.lua:813 GetOverflowContainer —— 本文件第 1372 行调用它",
  "--   参见 components/inventory.lua:1697 GetCraftingIngredient —— 本文件 920 行的孪生",
  "--   参见 components/stackable.lua:109 Get —— 本文件所有拆堆动作的落点",
  "--   参见 components/stackable.lua:36 SetIgnoreMaxSize —— infinitestacksize 的实现",
  "--   参见 components/stackable.lua:68 IsOverStacked —— overstacked 判定",
  "--   参见 components/inventoryitem.lua —— OnPutInInventory/OnDropped/OnRemoved 回调",
  "--   参见 components/preserver.lua —— readonlycontainer 附带的防腐组件",
  "--   参见 screens/playerhud.lua:385 OpenContainerWidget —— type 决定挂载点",
  "--   参见 components/builder.lua:500 GetIngredients —— 合成取料的上游",
  "--   参见 actions.lua:1095 —— CanOpen 的调用点（开合门禁在动作层）",
  "--   参见 prefabs/container_closed_receiveitem_classified.lua —— 闭容器收物动画",
  "--   参见 constants.lua:2928 CONTAINER_AUTOCLOSE_DISTANCE = 3",
  "--   参见 prefabskin.lua:18 SKIN_SOUND_FX —— 皮肤音效覆盖（642 行）",
  "--   参见 class.lua —— makereadonly / property setter 的实现",
  "--============================================================",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function build(srcFile, outFile, header, specFiles) {
  const BEFORE = {};
  const AFTER = {};
  const headerExtra = [];

  for (const sf of specFiles) {
    const specUrl = pathToFileURL(sf).href;
    const mod = await import(specUrl);
    for (const raw of [mod.HEADER_EXTRA ?? []].flat(Infinity)) {
      for (const h of String(raw).split("\n")) {
        if (h.trim() === "") continue; // 忽略 join 产生的空串
        headerExtra.push(h);
        assertComment(h, `HEADER_EXTRA(${sf})`);
      }
    }
    for (const [name, target] of [
      ["BEFORE", BEFORE],
      ["AFTER", AFTER],
    ]) {
      for (const [k, v] of Object.entries(mod[name] ?? {})) {
        if (target[k] !== undefined) target[k] = [...target[k], ...v];
        else target[k] = v;
      }
    }
  }

  const raw = readFileSync(join(SRC_ROOT, srcFile), "utf8");
  const srcLines = raw.split("\n");

  const out = [header.replace(/\n$/, "")];
  for (const h of headerExtra) out.push(h);

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
  if (which === "all" || which === "params") {
    await build("containers.lua", join(OUT_ROOT, "containers.lua"), HEADER_PARAMS, [
      join(__dirname, "spec-containers-p1.mjs"),
      join(__dirname, "spec-containers-p2.mjs"),
      join(__dirname, "spec-containers-p3.mjs"),
      join(__dirname, "spec-containers-p4.mjs"),
      join(__dirname, "spec-containers-p5.mjs"),
      join(__dirname, "spec-containers-p6.mjs"),
      join(__dirname, "spec-containers-dense.mjs"),
    ]);
  }
  if (which === "all" || which === "component") {
    await build(
      "components/container.lua",
      join(OUT_ROOT, "components/container.lua"),
      HEADER_COMPONENT,
      [
        join(__dirname, "spec-ccomponent-p1.mjs"),
        join(__dirname, "spec-ccomponent-p2.mjs"),
        join(__dirname, "spec-ccomponent-p3.mjs"),
        join(__dirname, "spec-ccomponent-p4.mjs"),
        join(__dirname, "spec-ccomponent-p5.mjs"),
        join(__dirname, "spec-ccomponent-p6.mjs"),
        join(__dirname, "spec-ccomponent-dense.mjs"),
      ]
    );
  }
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});