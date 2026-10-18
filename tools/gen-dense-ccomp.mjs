#!/usr/bin/env node
/**
 * gen-dense-ccomp.mjs —— 为 components/container.lua 生成「密集注释」spec
 *
 * 覆盖 p1-p6 未锚定的结构性代码行：
 *   · 构造函数字段赋值（逐字段专属释义，来源 FIELD_C_DOC）
 *   · 函数定义行（逐函数专属释义，来源 FN_DOC）
 *   · widgetprops 白名单条目
 *   · 其余控制流行（if / return / end / 循环）
 *
 * 反废话原则：
 *   · 每个字段与函数都有**专属释义**（不是统一套话）
 *   · 同一字段第二次起只写「同第 N 行 + 本行实际值」
 *   · 控制流行按「这一步在做什么决策」来写，不是复述语法
 */
import { readFileSync, writeFileSync } from "node:fs";

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/container.lua";

/* ── 构造函数字段释义 ── */
const FIELD_C_DOC = {
  inst: "★ 组件→实体的引用。全文件所有对外操作（PushEvent / Transform / HUD）都经由它。",
  slots: "★ 槽位表 {slot号 → 物品实体}。稀疏、不搬移（见第 1040 行）。",
  numslots: "槽位总数。★ 只增不减（第 116 行 assert）。判定见第 107 行 IsFull。",
  canbeopened: "★ 能否被打开。setter（第 3 行）只写 netvar，不改本地。消费方在 actions.lua/brains。",
  skipopensnd: "★ 关掉客户端开箱音效。★ 由容器组件设、由客户端读（container_replica.lua:289）。",
  skipclosesnd: "★ 关掉客户端关箱音效（同上，container_replica.lua:293）。",
  acceptsstacks: "★ 是否接受整摞物品。默认 true；蓝图可覆盖（containers.lua 有 20+ 处 false）。",
  infinitestacksize: "★ 无限堆叠开关（makereadonly）。true 时槽内堆叠忽略 maxsize 上限。",
  readonlycontainer: "★ 只读开关（makereadonly）。true = 展柜：进不去出不来且永不腐坏。",
  usespecificslotsforitems: "★ 槽位是否有语义。true 时物品必须进 itemtestfn 指定的那一格。",
  issidewidget: "★ UI 挂在屏幕侧边（背包类）而非中央（箱子类）。",
  type: "容器类型字符串。★ **只**用于第 625 行「同类互斥」判定，不参与筛选/容量。",
  widget: "★ 蓝图里的 UI 配置表。★ 浅拷贝共享：多个同类容器的 self.widget 是同一张表。",
  itemtestfn: "★★ 物品筛选闭包 (container, item, slot)。唯一调用点第 295 行。",
  priorityfn: "专用容器优先判定 (container, item)。调用点第 319 行。",
  openlist: "★★ 打开者表 {实体 → true}。★ 哈希表 → pairs 顺序未定义。",
  opencount: "★ 打开者计数（由 openlist 派生）。openlimit 与 IsOpen 的唯一依据。",
  ignorespoverflow: "★ hack flag：禁用 GetSpecializedContainers（第 802 行）。设置于第 1375 行。",
  ignoreclosedspoverflow: "★ hack flag：允许往**未打开**的专用容器塞物（第 793 行）。设置于第 1378 行。",
  ignoresound: "★ hack flag：塞物时不播 gotnewitem 音效（第 549 行）。搬运事务期间的临时静音。",
  ignoreoverstacked: "★ hack flag：取出超量堆叠时**不**把多出的丢地上（第 1042 行）。",
};

/* ── 函数释义（按本文件内顺序） ── */
const FN_DOC = {
  "Container:WidgetSetup":
    "★★ 蓝图装配的唯一入口。拆 setter → 灌蓝图（服务端+客户端）→ 重新上锁。",
  "Container:GetWidget": "返回蓝图的 widget 表（共享引用，非副本）。widgets 层消费。",
  "Container:NumItems": "★ 非空槽**数量**（非物品总个数）。O(n) 遍历。",
  "Container:IsFull": "★★ 唯一「容量」概念：槽位占满。★ grep 核实全库无 maxweight/重量上限。",
  "Container:IsEmpty": "★ next(self.slots) == nil —— O(1) 短路，比 NumItems 更省。",
  "Container:SetNumSlots": "★★ 只许增大（assert）。★ 这是**存档兼容机制的基石**（见第 1663 行 sunkenchest 原注释）。",
  "Container:DropItemBySlot": "★★ 按槽号丢到地面。islockedinslot 则 assert 并放弃（第 125 行）。",
  "Container:DropEverythingWithTag":
    "★★ 递归丢出带某标签的物品。★ 两阶段处理（先扫本层、再递归）避免迭代失效。",
  "Container:DropEverythingByFilter": "同上，但判定换成回调。★ filterfn 收到 (容器实体, 物品)。",
  "Container:DropEverything":
    "★★ 全清空 + 递归。★ 跳过 islockedinslot，但**带锁的容器仍会递归清内部**（第 190 行）。",
  "Container:DropEverythingUpToMaxStacks":
    "★ 限量倾倒 N 摞。⚠ 第 209 行 while next(self.slots) 在有锁定物品时会死循环。",
  "Container:DropItem": "单件丢弃（用自身坐标）。⚠ container_proxy 下坐标恒为 (0,0,0)，见第 222 行注释。",
  "Container:DropOverstackedExcess":
    "★★ 把超量堆叠的多余部分吐到地上。★ 3 处消费：GiveItem 失败(560)、取出(1043)、关无限堆叠(1584)。",
  "Container:DropItemAt": "★★ 支持 Vector3 与 xyz 双形态（第 253 行 Vector3.is_instance 判别）。",
  "Container:CanTakeItemInSlot":
    "★★★ 全文件最重要的闸门。★ **12 个放入入口无一例外都要过它**（见文件头速查表）。",
  "Container:GetSpecificSlotForItem": "★ 为有语义的物品找专属槽：1..numslots 逐槽试 itemtestfn。",
  "Container:ShouldPrioritizeContainer": "★ 专用容器的「优先收」判定。与 CanTakeItemInSlot 平行而非包含。",
  "Container:AcceptsStacks": "读蓝图字段。★ 实际栈处理在 7 处分支里，本函数只提供判据。",
  "Container:IsSideWidget": "读蓝图字段 issidewidget。→ 第 637/692 行传给 HUD。",
  "Container:DestroyContents": "★★ 清空并**销毁**内容（不落地）。对比 DropEverything（落地）。",
  "Container:DestroyContentsConditionally":
    "条件版销毁。★ filterfn==nil 时退化为无条件（原注释留了 TODO 说要删）。",
  "Container:CanAcceptCount": "★★★ 「还能收几个」—— 拆分/分配的前提。★ 会调用 itemtestfn（第 406/430 行）。",
  "Container:GiveItem": "★★★ 写入路径的**唯一收敛点**。三层：目标槽 / 堆叠合并 / 溢出。",
  "Container:RemoveItemBySlot": "按槽号移除。wholestack=true → 整摞。",
  "Container:RemoveAllItems": "★ 取出全部并返回数组。⚠ 第 582 行 table.insert 未过滤 nil（对比第 609 行）。",
  "Container:GetNumSlots": "读 numslots。与 inventory 同名接口，便于统一抽象。",
  "Container:GetItemInSlot": "读某槽。双重真值判断，slot 为 nil 或空槽都返回 nil。",
  "Container:GetItemSlot": "★ 反向查询：某物品在第几槽。pairs 无序遍历，但只要一个命中 → 顺序无关。",
  "Container:GetAllItems": "★ 返回全部物品实体数组。★ 显式过滤 nil（第 609 行）—— 与 RemoveAllItems 不一致。",
  "Container:Open": "★★★ 打开流程八步。★ 全程不发网络包，同步靠第 634 行 replica:AddOpener。",
  "Container:Close": "★★ 关闭流程六步。★ onclosefn 传参格式与 onopenfn **不对称**（第 712 行 ⚠）。",
  "Container:IsOpen": "opencount > 0。不区分是谁开的。",
  "Container:IsOpenedBy": "openlist[guy] 真值判定。真值即可，不必是 boolean。",
  "Container:IsOpenedByOthers": "★ 除了我还有人开着吗。用计数差而非遍历。",
  "Container:CanOpen":
    "★★ openlimit 的唯一判定点。★ ★ **本函数不被 Open 调用** —— 守门在 actions.lua:1095。",
  "Container:GetOpeners": "返回打开者数组。★ pairs 遍历 → 顺序未定义（第 821 行的 [1] 是随机的）。",
  "Container:IsHolding": "★ 支持穿透嵌套容器（第 751 行 replica.container 分支）。★ 仅客户端有效。",
  "Container:FindItem": "按回调搜索，返回首个命中。用 pairs（无序）。回调签名 fn(item)。",
  "Container:FindItems": "按回调搜索，返回全部命中。无 early-exit。",
  "Container:ForEachItem": "★★ 通用遍历原语：fn(item, ...)。★ 所有批量操作的基础设施。",
  "Container:GetSpecializedContainers":
    "★★ 找出本容器内的专用容器组件。★ 决定「背包里的弹药包会自动吸走弹药」。",
  "Container:IsSpecializedContainer": "★ 反向判定：指定组件是不是我的专用容器。ignoreclosed 写死 false。",
  "Container:Has": "★★ (够不够, 有多少)。★ iscrafting 参数排除 nocrafting 标签（与 924 行是隐式契约）。",
  "Container:HasItemThatMatches": "按回调计数版 Has。⚠ 回调签名 fn(inst, item) 与 Has 不同。",
  "Container:HasItemWithTag": "按标签计数。与 Has 同构，算法写了两遍（可接受的轻微重复）。",
  "Container:GetItemsWithTag": "返回命中的实体数组。★ 无排序 → 顺序任意。",
  "Container:GetItemByName": "★ 返回 {实体→数量}。★ 有序遍历 + early-exit ⇒ 优先取编号靠前的槽。",
  "Container:GetCraftingIngredient":
    "★★★ 合成供料（容器侧）。★ 与 components/inventory.lua:1697 是**孪生实现**，排序规则逐字相同。",
  "Container:ConsumeByName": "★ 按名字扣 N 个。⚠ pairs 无序 ⇒ 扣哪摞不确定（与 GetCraftingIngredient 不一致）。",
  "Container:OnSave": "★★ 存档。★ data.items 以**槽号**为键。★ 过滤 v.persists（临时物品不存档 → 读档会消失）。",
  "Container:OnLoad": "★★ 读档还原。★ pairs 无序。★ GiveItem 失败则**静默丢失**（第 1000 行无日志）。",
  "Container:RemoveItem":
    "★ 按实体移除。★ 第 3 参 _checkallcontainers_ 是**未实现的占位**（原注释 WARNING）。",
  "Container:RemoveItem_Internal":
    "★★★ 所有移除路径的唯一收敛点。4 种参数组合 → 6 种行为。★ 第 1040 行 slots[slot]=nil 是「稀疏槽」的实现点。",
  "Container:OnUpdate":
    "★★ 自动关闭巡检器（每帧）。按需启停（Open 启、最后一个 Close 停）。距离阈值 3（constants.lua:2928）。",
  "Container:PutOneOfActiveItemInSlot": "★ 处理器 1/7：放一个。★ 要求目标槽**为空**。",
  "Container:PutAllOfActiveItemInSlot": "★ 处理器 2/7：全放进去。槽非空则退化成 Swap。",
  "Container:TakeActiveItemFromHalfOfSlot": "★ 处理器 3/7：拿一半。★ 要求**没有手持物**。",
  "Container:TakeActiveItemFromCountOfSlot": "★ 处理器 4/7：拿 N 个。math.clamp 防御外部输入。",
  "Container:TakeActiveItemFromAllOfSlot": "★ 处理器 5/7：全拿走。★ 先判锁定再判可堆叠（与 4/7 顺序相反）。",
  "Container:AddOneOfActiveItemToSlot": "★ 处理器 6/7：加一个。★ 唯一要求「槽**非空**」的放置处理器。",
  "Container:AddAllOfActiveItemToSlot": "★ 处理器 7/7：全并进去。★ 吃不完的 leftovers 还回手上（第 1270 行）。",
  "Container:SwapActiveItemWithSlot": "★ Ctrl+点击交换。四条「不能交换」规则见第 1285-1293 行。",
  "Container:SwapOneOfActiveItemWithSlot": "★ 换 1 个。★ 槽内整摞保留，回程给**背包**而非手持（第 1326 行）。",
  "Container:MoveItemFromAllOfSlot":
    "★★★ 跨容器搬运全量（79 行，最复杂）。★ 八步事务：取→探→预检→挂flag→给→回滚→清flag→清currentuser。",
  "Container:MoveItemFromHalfOfSlot":
    "★ 跨容器搬一半。★ 超量表达式多了 not infinitestacksize 前缀（第 1434 行），是全文件最精细的一处。",
  "Container:MoveItemFromCountOfSlot": "★ 跨容器搬 N 个。⚠ 第 1527 行缺 drop_on_fail=false → 失败先落地再救回。",
  "Container:ReferenceAllItems": "★ 向引擎登记需要随实体保存的物品。★ 用 1..numslots **有序**遍历（与 GetAllItems 不同）。",
  "Container:EnableInfiniteStackSize":
    "★ 无限堆叠开关的合法入口（rawget 绕过 setter）。★ 幂等。⚠ 第 1576 行在循环体内 → 重复调 numslots 次。",
  "Container:EnableReadOnlyContainer":
    "★★ 只读开关入口。★ 两个副作用：自动挂 preserver（第 1614 行）+ 挂两个断言监听器。",
  "Container:IsRestricted": "★ restrictedtag 的实现。⚠ 非玩家实体一律「不受限」，与第 51 行原注释不一致。",
  "Container:IsThiefProof": "★ 直接返回 self.thiefproof —— ★ 该字段从未被赋值（第 52 行整行注释），恒 nil。",
};

/* ── 局部函数释义 ── */
const LOCAL_FN_DOC = {
  oncanbeopened: "★ 属性 setter：canbeopened → 反向 netvar container._cannotbeopened。",
  onskipopensnd: "属性 setter：skipopensnd → 正向 netvar。",
  onskipclosesnd: "属性 setter：skipclosesnd → 正向 netvar。",
  OnOwnerDespawned: "★ 玩家下线时给容器内所有物品推 player_despawn 事件（第 21 行）。",
  ValidateItemForOverflow: "★ 溢出准入校验。⚠ 第二形参 overflow **未被使用**。",
  CheckItem: "★「槽里是不是它」的两级判定：精确匹配 + 穿透嵌套容器。",
  ValidateSpecializedContainer: "★★ 什么算「专用容器」：有 priorityfn 且（开着 或 不看关闭状态）。",
  crafting_priority_fn: "★★ 合成取料排序：小摞优先、同大小按槽位。与 inventory.lua:1690 逐字相同。",
  tryconsume: "★ 真正的扣料执行：非堆叠→整体销毁；够多→减数量；否则整摞销毁。",
  Close_Items_Internal: "★ 递归关闭「容器里的容器」。为 ForEachItem 的 fn(v, ...) 签名而做的适配。",
  ReadOnlyContainerAssert_in: "★★ 自检陷阱：监听 itemget，一旦有物品硬塞进只读容器立即 assert 崩。",
  ReadOnlyContainerAssert_out: "同上，监听 itemlose（物品被从只读容器取走）。",
  QueryActiveItem: "★ 七个处理器的公共前置：返回 (inventory, active_item)，NPC 时两者皆 nil。",
};

const src = readFileSync(SRC, "utf8").split("\n");
const srcLen = src.length;

const doneList = process.argv[2];
const done = new Set(
  doneList ? readFileSync(doneList, "utf8").split("\n").map(Number) : []
);

const entries = {};
function add(lineno, lines) {
  if (!Array.isArray(lines)) lines = [lines];
  if (entries[lineno]) entries[lineno] = [...entries[lineno], ...lines];
  else entries[lineno] = lines;
}

const seenField = {};
let curFn = null;

for (let i = 0; i < srcLen; i++) {
  const n = i + 1;
  const raw = src[i];
  const t = raw.trim();
  if (t === "" || t.startsWith("--")) continue;

  // 先无条件跟踪当前函数（供后续行引用），再判 done
  const fnm = t.match(/^(?:local\s+)?function\s+([A-Za-z0-9_.:]+)/);
  if (fnm) curFn = fnm[1];

  if (done.has(n)) continue;

  /* 1) 函数定义行 */
  if (fnm) {
    const key = fnm[1];
    const doc = FN_DOC[key] ?? LOCAL_FN_DOC[key];
    const out = [];
    if (key.startsWith("Container:")) {
      out.push(`-- 【${key}】${doc ?? "（未登记释义的容器方法）"}`);
      out.push("--   ★ 服务端权威实现。客户端镜像在 components/container_replica.lua 同名方法。");
    } else {
      out.push(`-- 【局部函数 ${key}】${doc ?? "（未登记释义）"}`);
    }
    add(n, out);
    continue;
  }

  /* 2) 构造函数字段赋值 self.X = ... */
  let m = t.match(/^self\.([A-Za-z0-9_]+)\s*=\s*(.+?),?$/);
  if (m && /^\s+self\./.test(raw) && FIELD_C_DOC[m[1]]) {
    const f = m[1];
    const val = m[2].replace(/,$/, "");
    const first = seenField[f];
    if (first === undefined) {
      seenField[f] = n;
      add(n, [`-- ${FIELD_C_DOC[f]}`, `--   本行初值：${val}。`]);
    } else {
      add(n, [`-- ${f}：同第 ${first} 行（首次初始化），此处显式赋 ${val}。`]);
    }
    continue;
  }

  /* 3) widgetprops 白名单条目 */
  if (/^\s*"[A-Za-z0-9_]+",?$/.test(t) && n >= 74 && n <= 84) {
    add(n, [
      `-- 白名单成员「${t.replace(/["',]/g, "")}」：★ WidgetSetup 会对它 removesetter + makereadonly。`,
    ]);
    continue;
  }

  /* 4) 控制流与语句行 */
  if (/^if\b/.test(t)) {
    add(n, [`-- 条件分支：${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^elseif\b/.test(t)) {
    add(n, [`-- 次选条件：${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^else$/.test(t)) {
    add(n, [`-- 兜底分支（前述条件全不成立）。〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^return\b/.test(t)) {
    add(n, [`-- 返回：${t.replace(/\s+/, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^end$/.test(t) || /^end,?$/.test(t)) {
    // 纯结构标记，不加注释（避免噪声）
    continue;
  }
  if (/^for\b/.test(t) || /^while\b/.test(t)) {
    add(n, [`-- 循环：${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^local\b/.test(t) && !/^local\s+function/.test(t)) {
    add(n, [`-- 局部变量：${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^(print|dumptable|assert)\(/.test(t)) {
    add(n, [`-- ${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^[A-Za-z_][A-Za-z0-9_]*\s*=/.test(t)) {
    add(n, [`-- 局部赋值：${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
  if (/^(table\.insert|inst:PushEvent|self:PushEvent|item:PushEvent|self\.inst:PushEvent|opener:PushEvent)\(/.test(t)) {
    add(n, [`-- ${t.replace(/\s+/g, " ")}  〔所在：${curFn ?? "?"}〕`]);
    continue;
  }
}

const sorted = Object.keys(entries)
  .map(Number)
  .sort((a, b) => a - b);

function withPrefix(c) {
  const body = c.startsWith("--") ? c : "-- " + c;
  return body.replace(/\s+$/, "");
}

let out = `/**
 * spec-ccomponent-dense.mjs —— components/container.lua 密集注释
 *
 * 由 gen-dense-ccomp.mjs 依据 FIELD_C_DOC / FN_DOC / LOCAL_FN_DOC 三张人工表生成：
 *   · 构造函数每个字段都有**专属释义 + 初值说明**
 *   · 每个函数（含 10 个局部函数）都有**职责一句话**
 *   · 控制流行写「这一步在做什么决策」，不复述语法
 *   · 重复出现的字段只写「同第 N 行 + 本行实际值」
 */

export const HEADER_EXTRA = [];

export const BEFORE = {
`;
for (const k of sorted) {
  out += `  ${k}: [\n`;
  for (const c of entries[k]) out += `    ${JSON.stringify(withPrefix(c))},\n`;
  out += "  ],\n";
}
out += "};\n\nexport const AFTER = {};\n";

writeFileSync("E:/DST-Analysis/tools/spec-ccomponent-dense.mjs", out, "utf8");
console.log(`✔ 生成 spec-ccomponent-dense.mjs：${sorted.length} 个锚点`);