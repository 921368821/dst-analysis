#!/usr/bin/env node
/**
 * build-inventory.mjs —— 物品栏与合成系统深度中文注释生成器（锚点注入法）
 *
 * 与 build-actions.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-inventory-p*.mjs / spec-recipe.mjs /
 *     spec-equippable.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *   · 规格里任何非 `--` 开头的行都会在构建期抛错（assertComment）。
 *   · 规格里出现越界行号（超出源文件行数）同样在构建期抛错。
 *
 * 用法：node build-inventory.mjs [inventory|recipe|equippable|all]
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT = pristineRoot();
const OUT_ROOT = ANN_SCRIPTS;

/* ────────────────────────── 文件头 ────────────────────────── */

const HEADER_INVENTORY = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/inventory.lua（2755 行，DST 物品栏的唯一权威实现）",
  "-- 模块：物品栏系统 / 服务端权威库存（Inventory）",
  "-- 职责：回答「这个实体身上现在有什么东西、放得下吗、装得下吗」。",
  "--   它同时承担四个通常被拆开的职责：",
  "--   ① 槽位模型 —— itemslots（普通槽）/ equipslots（装备槽）/ activeitem（手持）",
  "--      三张表 + 一个「溢出容器」（背包）指针，构成完整的物品视图；",
  "--   ② 增删改查 —— GiveItem / RemoveItem / Equip / Unequip 四条主干，",
  "--      每一条都带「往哪放、放不下怎么办、要不要通知客户端」三层决策；",
  "--   ③ 联机同步的事件源 —— 本文件**只 PushEvent**，不发网络数据；",
  "--      真正的网络同步在 inventory_replica.lua:22-26 监听这五个事件",
  "--      并写进 inventory_classified 的 netvar（见下）；",
  "--   ④ 合成供料 —— Has / GetCraftingIngredient / ConsumeByName 三件套，",
  "--      为 components/builder.lua 的扣除逻辑提供「取哪几个、按什么顺序」。",
  "--",
  "-- ★★ 全文件最重要的认知一：**Inventory 不持有物品数据，只持有实体引用**。",
  "--   itemslots[3] 存的是一个 Entity，不是 {name=..., count=...} 这样的结构体。",
  "--   物品的一切属性（可堆叠 / 会腐烂 / 可燃 / 是武器）都挂在实体自己的",
  "--   组件上（inst.components.stackable / perishable / fuel / weapon）。",
  "--   ⇒ 推论：本文件里所有 `item.components.X ~= nil` 判定，都是",
  "--   「按标签能力查询」而不是「按类型分派」。新增一种物品能力，",
  "--   只需加一个组件 + 一个 if，不需要改 Inventory 的任何分派表。",
  "--   ★ 这正是 DST 相对多数引擎「物品大枚举表」的设计优势。",
  "--",
  "-- ★★ 全文件最重要的认知二：**槽位下标是稀疏的、不可信的**。",
  "--   · itemslots 是以 1..maxslots 为下标的数组，但可能只有 [1] 和 [7] 有值；",
  "--   · 大量查询用 pairs() 遍历（无序），只有涉及「找空位/排序」时才用",
  "--     1..maxslots 的 for 循环（有序）；",
  "--   · 为什么存稀疏？因为 RemoveItem 时只是 self.itemslots[k] = nil（1407 行），",
  "--     不做元素搬移。搬移会让「物品在客户端的显示位置」无故跳变，",
  "--     而背包是有视觉记忆的——玩家会记住「斧头在第 4 格」。",
  "--   ★ 代价：槽位编号会越来越乱，UI 必须容忍空洞（inventory 的贴图绘制",
  "--     是按 1..maxslots 逐个问 GetItemInSlot 的，见 777 行）。",
  "--",
  "-- ★★ 全文件最重要的认知三：**客户端从不查询服务端的状态，它读 netvar**。",
  "--   本文件 1085 行附近大量 `self.inst:PushEvent(\"itemget\", {...})`，这些事件",
  "--   在**服务端**被 inventory_replica.lua:22-26 的匿名函数接住，转写成",
  "--   inventory_classified 的 netvar（self.classified:SetSlotItem 等）。",
  "--   客户端 inventory_replica.lua:332 GetItems() 读的是 classified 而非本组件。",
  "--   ⚠ grep 核实：本文件**不存在** Reclientify / RepackInventory / GetSlots /",
  "--     GetItems 四个方法（全库 grep 零命中）。任务描述里提到的这三个",
  "--     「联机同步机制」函数在 DST 中并不存在，请勿按图索骥：",
  "--     · 取代 Reclientify 的是 classified 的 netvar 自动同步（见上）；",
  "--     · 取代 RepackInventory 的是 GetNextAvailableSlot（813 行）的选位算法；",
  "--     · 取代 GetSlots/GetItems 的是 inventory_replica.lua:332 GetItems()",
  "--       与 GetEquips()（340 行）——它们是**只读快照**，不是活表。",
  "--",
  "-- 关键符号：Inventory（类）, itemslots, equipslots, activeitem, maxslots,",
  "--   GiveItem, RemoveItem, RemoveItemBySlot, Equip, Unequip, SetActiveItem,",
  "--   GiveActiveItem, DropItem, DropEverything, GetNextAvailableSlot,",
  "--   CanTakeItemInSlot, CanAcceptCount, GetOverflowContainer,",
  "--   GetSpecializedContainers, GetCraftingIngredient, ConsumeByName,",
  "--   ApplyDamage, GetWaterproofness, GetEquippedMoistureRate,",
  "--   OnSave, OnLoad, TransferInventory, SwapEquipment",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 components/inventory_replica.lua —— 事件 → netvar 的转写层",
  "--   ★★ 参见 prefabs/inventory_classified.lua —— 真正的网络数据载体",
  "--   参见 components/inventoryitem.lua:315 GetSlotNum（prevslot 的来源）",
  "--   参见 components/inventoryitem.lua:344 OnPutInInventory（湿气继承点）",
  "--   参见 components/inventoryitem.lua:468 RemoveFromOwner（拆卸的统一入口）",
  "--   参见 components/equippable.lua —— 装备槽与属性加成的另一半",
  "--   参见 components/stackable.lua —— Put/Get/SetStackSize 的堆叠语义",
  "--   参见 components/container.lua:Container —— 溢出容器与专用容器",
  "--   参见 components/builder.lua:500 GetIngredients —— 合成取料入口",
  "--   参见 components/builder.lua:546 RemoveIngredients —— 合成扣料执行",
  "--   参见 components/builder.lua:592 HasCharacterIngredient —— 角色代价判定",
  "--   参见 recipe.lua —— 配方数据结构（本文件的产出目标）",
  "--   参见 equipslotutil.lua:31 EquipSlotToID（槽位名 ↔ 网络整数）",
  "--   参见 constants.lua:652 EQUIPSLOTS（仅 4 槽：hands/head/body/beard）",
  "--   参见 prefabs/player_classified.lua —— heavylifting / floaterheld 的消费点",
  "--============================================================",
].join("\n");

const HEADER_RECIPE = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：recipe.lua（243 行）",
  "-- 模块：合成系统 / 配方数据结构（Recipe Schema）",
  "-- 职责：定义 Ingredient（一份材料）与 Recipe（一条配方）两个类，",
  "--   并维护全局配方表 AllRecipes。它是**纯数据层**，不执行合成。",
  "--",
  "-- ★★ 全文件最重要的认知一：本文件**不判定材料够不够**。",
  "--   grep 核实：`CanCraft` / `IsCookingPermitted` 在本文件**不存在**",
  "--   （全库 grep 只在 widgets/widgetutil.lua:30 命中一个同名的",
  "--   局部函数 CanCraftIngredient，那是 UI 侧的灰显判定）。",
  "--   真正的三段式流程分散在三个文件：",
  "--     ① 配方定义   —— 本文件（Recipe 类）+ recipes.lua / preparedfoods.lua",
  "--     ② 取料       —— components/builder.lua:500 GetIngredients",
  "--                    → components/inventory.lua:1697 GetCraftingIngredient",
  "--     ③ 扣料       —— components/builder.lua:546 RemoveIngredients",
  "--   ⇒ 读本文件时不要指望找到「匹配算法」，它在上游的 builder 里。",
  "--",
  "-- ★★ 全文件最重要的认知二：Recipe 是**全局唯一表**，不是原型注册表。",
  "--   179 行 `AllRecipes[name] = self` 直接写入全局表，name 冲突即覆盖。",
  "--   对比 actions.lua：Action 有 ACTIONS_BY_ACTION_CODE 的编号层，",
  "--   而 Recipe 只有 name 一个键——所以模组改配方名 = 改存档兼容。",
  "--",
  "-- ★★ 全文件最重要的认知三：`ingredients` 在构造时被拆成**三张表**。",
  "--   89-96 行按 Ingredient.type 把材料分到：",
  "--     · self.ingredients          —— 普通物品材料（草、木头、石头…）",
  "--     · self.character_ingredients —— 角色代价（扣血、扣理智）",
  "--     · self.tech_ingredients     —— 科技材料（目前只有雕刻材料）",
  "--   ★ 为什么拆？因为三者的扣除路径完全不同：",
  "--     普通材料 → inventory:RemoveItem（实体销毁）；",
  "--     角色代价 → health:DoDelta / sanity:DoDelta（改数值，不掉实体）。",
  "--   判定谓词见 44 行的 IsCharacterIngredient 与 55 行的 IsTechIngredient，",
  "--   它们都是**惰性建表**（第一次调用时才建，反射常量表并取 value 反查）。",
  "--",
  "-- 关键符号：Ingredient（类）, Recipe（类）, Recipe2, DeconstructRecipe,",
  "--   AllRecipes, AllBuilderTaggedRecipes, IsCharacterIngredient,",
  "--   IsTechIngredient, GetValidRecipe, IsRecipeValid, RemoveAllRecipes,",
  "--   mod_protect_Recipe",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 components/builder.lua:500 GetIngredients（取料入口）",
  "--   ★★ 参见 components/builder.lua:546 RemoveIngredients（扣料执行）",
  "--   ★★ 参见 components/inventory.lua:1690 crafting_priority_fn（取料排序）",
  "--   ★★ 参见 components/inventory.lua:1697 GetCraftingIngredient（选哪几个）",
  "--   参见 techtree.lua:76 Create —— level 字段被补齐成 40 轴全 0 的表",
  "--   参见 constants.lua:2123 CHARACTER_INGREDIENT（角色代价类型枚举）",
  "--   参见 constants.lua:2134 CHARACTER_INGREDIENT_SEG = 5（代价粒度）",
  "--   参见 constants.lua:2136 TECH_INGREDIENT（科技材料枚举）",
  "--   参见 constants.lua:3012 SKINUNLOCKS（unlocks_from_skin 的枚举）",
  "--   参见 constants.lua:2224 BUILDMODE（建造落点模式）",
  "--   参见 simutil.lua:930 DeclareLimitedCraftingRecipe（限量配方登记）",
  "--   参见 gamemodes.lua:302 IsRecipeValidInGameMode（模式过滤）",
  "--   参见 modutil.lua:613 AddRecipePostInit（模组配方后置钩子）",
  "--   参见 preparedfoods.lua:352 wetgoop 兜底烹饪条目（priority = -10）",
  "--   参见 spicedfoods.lua:32 香料版本的 wetgoop（test 改为检查香料）",
  "--   参见 widgets/widgetutil.lua:30 CanCraftIngredient（UI 侧灰显判定）",
  "--   参见 widgets/crafttabs.lua:260 CHARACTER_INGREDIENT_SEG 的 UI 用法",
  "--============================================================",
].join("\n");

const HEADER_EQUIPPABLE = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/equippable.lua（218 行）",
  "-- 模块：物品栏系统 / 装备能力（Equippable）",
  "-- 职责：定义 Equippable 组件——「这个实体可以被穿在身上」。",
  "--   它只回答装备相关的四个问题：",
  "--   ① 能穿到哪个槽位（equipslot，默认 HANDS）；",
  "--   ② 穿上/脱下时要回调什么（onequipfn / onunequipfn / onpocketfn）；",
  "--   ③ 穿了之后有什么属性加成（walkspeedmult / dapperness / insulated）；",
  "--   ④ 谁能穿（restrictedtag）与 能不能脱（preventunequipping）。",
  "--",
  "-- ★★ 全文件最重要的认知一：Equippable **不做任何属性结算**。",
  "--   它只持有「属性值」与「属性值怎么算」的函数指针，真正的**汇总**",
  "--   发生在别人身上：",
  "--     · 护甲减伤汇总 → components/inventory.lua:408 Inventory:ApplyDamage",
  "--     · 防水汇总     → components/inventory.lua:2714 GetWaterproofness",
  "--     · 湿度汇总     → components/inventory.lua:2692 GetEquippedMoistureRate",
  "--     · 绝缘汇总     → components/inventory.lua:759 Inventory:IsInsulated",
  "--     · 移速汇总     → locomotor.lua 的 GetWalkSpeed（见 126 行注释）",
  "--   ⇒ 也就是说：**装备槽是「数据源」，不是「效果器」**。",
  "--     这让「同时穿 3 件绝缘装备」这类叠加逻辑只需要写一份（在 Inventory 里）。",
  "--",
  "-- ★★ 全文件最重要的认知二：本组件是**双端分裂**的，且客户端数据来自",
  "--   inventoryitem 而非本组件。第 5 行的原注释已经点明：",
  "--     \"Update inventoryitem_replica constructor if any more properties are added\"",
  "--   ⇒ 新增装备属性时，必须同时在 inventoryitem_replica 上加一个同步通道，",
  "--     否则客户端永远看不到（这正是 1-23 行四个 on* setter 的用途）。",
  "--   ⚠ 注意 9-10 行的原注释：这套 hack 与 saddler 组件**共用**，",
  "--     所以「一个 prefab 不能同时挂 equippable 和 saddler」。",
  "--",
  "-- ★★ 关于「耐久」：★ grep 核实——**本文件不含任何耐久逻辑**。",
  "--   耐久由 armordurability / fuel / perishable 等独立组件负责，",
  "--   本文件只在 Equip/Unequip 时透传事件。装备槽本身不存耐久。",
  "--   用户常说的「装备耐久」在本游戏里其实是「护甲吸收量」的两套系统：",
  "--     · components/armor.lua —— 护甲吸收率（决定减伤百分比）；",
  "--     · components/armordurability.lua —— 耐久消耗（决定还能挡几下）。",
  "--   两者在 inventory.lua:408 ApplyDamage 里被同时驱动。",
  "--",
  "-- 关键符号：Equippable（类）, Equip, Unequip, ToPocket, IsEquipped,",
  "--   GetWalkSpeedMult, IsRestricted, IsRestricted_FromLoad,",
  "--   ShouldPreventUnequipping, SetPreventUnequipping, GetDapperness,",
  "--   GetEquippedMoisture, IsInsulated, SetOnEquip, SetOnUnequip, SetOnPocket,",
  "--   SetOnEquipToModel, SetDappernessFn, OnRemoveFromEntity",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 components/inventory.lua:1266 Inventory:Equip —— 装备的主流程",
  "--   ★★ 参见 components/inventory.lua:1219 Inventory:Unequip —— 卸装的主流程",
  "--   ★★ 参见 components/inventory.lua:408 Inventory:ApplyDamage —— 护甲减伤汇总",
  "--   ★★ 参见 components/inventory.lua:7714 GetWaterproofness（防水汇总入口）",
  "--   参见 components/inventoryitem_replica.lua:GetWalkSpeedMult（客户端镜像）",
  "--   参见 components/inventoryitem_replica.lua —— 装备属性的网络载体",
  "--   参见 components/stackable.lua —— equipstack 时整摞一起装备",
  "--   参见 components/setbonus.lua:UpdateSetBonus —— 套装效果开关",
  "--   参见 components/spdamageutil.lua:GetSpDefenseForType —— 特殊伤害防御",
  "--   参见 components/linkeditem.lua:IsEquippableRestrictedToOwner —— 专属装备",
  "--   参见 components/burdenedbackpack.lua / saddler —— 与 walkspeedmult 共享的 hack",
  "--   参见 constants.lua:652 EQUIPSLOTS（hands / head / body / beard 共 4 槽）",
  "--   参见 equipslotutil.lua —— 槽位名与网络整数 id 的互转",
  "--   参见 TUNING.WET_ITEM_DAPPERNESS —— 淋湿装备的理智惩罚常量",
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
      // 允许规格里写成多行字符串（.join("\n")），此处拆开后逐行校验
      for (const h of String(raw).split("\n")) {
        if (h.trim() === "") continue; // 忽略 join 产生的空串
        headerExtra.push(h);
        assertComment(h, `HEADER_EXTRA(${sf})`);
      }
    }
    for (const field of [
      ["BEFORE", BEFORE],
      ["AFTER", AFTER],
    ]) {
      const [name, target] = field;
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
  if (which === "all" || which === "inventory") {
    await build(
      "components/inventory.lua",
      join(OUT_ROOT, "components/inventory.lua"),
      HEADER_INVENTORY,
      [
        join(__dirname, "spec-inventory-p1.mjs"),
        join(__dirname, "spec-inventory-p2.mjs"),
        join(__dirname, "spec-inventory-p3.mjs"),
        join(__dirname, "spec-inventory-p4.mjs"),
        join(__dirname, "spec-inventory-p5.mjs"),
        join(__dirname, "spec-inventory-p6.mjs"),
        join(__dirname, "spec-inventory-p7.mjs"),
        join(__dirname, "spec-inventory-p8.mjs"),
        join(__dirname, "spec-inventory-p9.mjs"),
      ]
    );
  }
  if (which === "all" || which === "recipe") {
    await build(
      "recipe.lua",
      join(OUT_ROOT, "recipe.lua"),
      HEADER_RECIPE,
      [
        join(__dirname, "spec-recipe.mjs"),
        join(__dirname, "spec-recipe2.mjs"),
      ]
    );
  }
  if (which === "all" || which === "equippable") {
    await build(
      "components/equippable.lua",
      join(OUT_ROOT, "components/equippable.lua"),
      HEADER_EQUIPPABLE,
      [
        join(__dirname, "spec-equippable.mjs"),
        join(__dirname, "spec-equippable2.mjs"),
      ]
    );
  }
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});