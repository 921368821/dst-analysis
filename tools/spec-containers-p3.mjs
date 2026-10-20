/**
 * spec-containers-p3.mjs —— containers.lua 第 906-1450 行
 * merm 工具棚/军械库 / 万圣节树 / icebox 冰箱 ★ / saltbox / krampus_sack / piggyback / teleportato / balatro / 宝箱 / antlionhat / fish_box / 钓竿 / 胡子袋
 */

export const BEFORE = {
  "params.offering_pot.itemtestfn#1+41": ["-- ── merm_toolshed（鱼人工具棚）区块 ──"],
  "params.offering_pot.itemtestfn#1+45": [
    "-- 工具棚：2 格，每格固定物品（slot1 = 树枝，slot2 = 石头），slotbg 直接画对应图标。",
    "--   ★ 这是「双格语义容器」的代表：不用标签，靠 slot 参数硬绑定。",
  ],
  "params.offering_pot.itemtestfn#1+63": [
    "-- ★ 自定义开合音效（meta4 前缀 = 鱼人 Wurtster? DLC 的资源前缀）。",
    "--   参见第 508-513 行那段关于「世界音效 vs HUD 音效」的注释。",
  ],
  "params.offering_pot.itemtestfn#1+66": [
    "-- usespecificslotsforitems = true：slot 1/2 不可互换。",
  ],
  "params.merm_toolshed.itemtestfn#1": [
    "-- 【★ itemtestfn 范例 K：slot 参数的三分支，与第 425 行 portablespicer 同型】",
    "--   唯一区别是这里用 prefab 精确匹配（twigs/rocks），那里用标签（preparedfood/spice）。",
    "--   ★ 又一次印证：**规则的具体程度由语义确定程度决定**，框架完全通用。",
  ],
  "params.merm_toolshed.itemtestfn#1+5": [
    "-- slot == nil 的兜底：两种都接受 → 拖拽时不高亮任何特定格也能放下。",
  ],
  "params.merm_toolshed.itemtestfn#1+9": [
    "-- deepcopy 派生二代：只有槽位布局不变，判定靠第 950 行覆盖。",
  ],
  "params.merm_toolshed.itemtestfn#1+11": ["-- ── merm_armory（鱼人军械库）区块 ──"],
  "params.merm_toolshed.itemtestfn#1+15": [
    "-- ★ 完整 deepcopy（第 944 行用的是 deepcopy，这里也是——风格一致）。",
    "--   注意第 43/137/168/389/782 行的引用赋值是**少数派**，本文件主流是 deepcopy。",
  ],
  "params.merm_toolshed.itemtestfn#1+17": [
    "-- 整体替换 slotbg：木头 + 草。★ 用「整体替换」而非「逐项覆盖」表达「这一组全换」。",
  ],
  "params.merm_armory.itemtestfn#1": [
    "-- 军械库的 itemtestfn 覆盖：log / cutgrass。同样是 prefab 精确匹配。",
  ],
  "params.merm_armory.itemtestfn#1+11": ["-- ── livingtree_halloween（万圣节树）区块 ──"],
  "params.merm_armory.itemtestfn#1+15": ["-- 万圣节树：3 横格，放万圣节装饰（南瓜灯等）。"],
  "params.livingtree_halloween.itemtestfn#1": [
    "-- 单标签 + burnt 守卫。与第 993 行同型的最短写法。",
    "--   ★ 三个槽用同一张 Vector3 公式 `-(64+12)/0/+(64+12)`：间距 76，比标准 75 多 1。",
    "--     偏移 12 是为了给「物品图标比格子略大」的美术留边距。",
  ],
  "params.livingtree_halloween.itemtestfn#1+4": ["-- ── icebox（冰箱）区块 ★★★ 本文件最重要的区块 ──"],
  "params.livingtree_halloween.itemtestfn#1+8": [
    "-- 【★★★ 冰箱：type = \"chest\"，但它才是「物品筛选」的教科书】",
    "--   ★★ 关键认知：**冰箱并没有「冰箱类型」**。它的 type 和普通木箱一模一样，",
    "--     它的特殊性 100% 来自下面第 1019 行的 itemtestfn。",
    "--     把这个 itemtestfn 删掉，冰箱就会变成能装一切的 9 格箱子。",
    "--     ⇒ 这就是「DST 不用类型枚举做物品筛选」的实证。",
  ],
  "params.icebox.itemtestfn#1": [
    "-- 【★★ 四层漏斗：全库最值得读的 itemtestfn】逐层拆解：",
    "--   第 1 层（1020 行）：**显式白名单标签** —— icebox_valid / inventoryitemtemperature；",
    "--   第 2 层（1025 行）：**状态门** —— 必须有 fresh/stale/spoiled 之一，否则拒；",
    "--   第 3 层（1029 行）：**生物排除** —— smallcreature 一律拒（活的东西不能进冰箱）；",
    "--   第 4 层（1034 行）：**类型枚举遍历** —— 遍历 FOODTYPE 找 edible_<TYPE>。",
    "--   ★ 为什么第 4 层要遍历？因为 edible 标签有 20 多种（constants.lua:2022 FOODTYPE），",
    "--     写死 20 个 or 条件不可维护，遍历枚举只需 5 行。",
    "--   ⚠ 但遍历也带来代价：**新加一种 FOODTYPE 不会自动让旧物品变成可放入**，",
    "--     它只是让「已经打好 edible_XXX 标签的物品」通过。若新食物没打标签就进不去冰箱。",
  ],
  "params.icebox.itemtestfn#1+1": [
    "-- 第 1 层：两条快速通道。icebox_valid 是「模组/官方指定的合法物」逃生口；",
    "--   inventoryitemtemperature 指「有温度属性」的物品（如温度计、水银温度计类道具）。",
    "--   ★ 这两条是为了**兼容性与特殊道具**而开的口子——规则永远需要后门。",
  ],
  "params.icebox.itemtestfn#1+5": [
    "-- ★ 原注释保留：「--Perishable」。这一个词就概括了第 2 层的意图。",
    "--   perishable（易腐品）组件会自动打上 fresh/stale/spoiled 三个标签之一，",
    "--   所以「有这三个标签」≡「这东西会腐烂」≡「放冰箱有意义」。",
  ],
  "params.icebox.itemtestfn#1+6": [
    "-- 第 2 层：不是易腐品 → 直接拒。这排除了木头、石头、工具等一切非食物。",
  ],
  "params.icebox.itemtestfn#1+10": [
    "-- 第 3 层：★ 易腐品里的例外——小生物不许进。",
    "--   为什么？活物（如小蜘蛛、蜜蜂）进了冰箱会「冻住」或数据异常。",
    "--   ⚠ 这里只排除了 smallcreature 标签；若某种生物没有这个标签仍会漏进来。",
    "--     说明这是一个**标签驱动的补丁**，不是根本解法。",
  ],
  "params.icebox.itemtestfn#1+14": [
    "-- 第 4 层：遍历 FOODTYPE 全枚举，检查对应 edible_ 标签。",
    "--   ★ 与第 1378 行胡子袋用 FOODGROUP.OMNI.types 的差别：",
    "--     FOODTYPE 是**全集**（20+ 种），FOODGROUP.OMNI 是**子集**（6 种）。",
    "--     冰箱要什么都能放（全集），胡子袋只要玩家能吃的（OMNI 集）。",
  ],
  "params.icebox.itemtestfn#1+24": ["-- ── saltbox（盐罐）区块 ──"],
  "params.icebox.itemtestfn#1+28": [
    "-- ★ deepcopy(icebox) 后**整体覆盖 itemtestfn** —— 派生式配置的标准三步。",
    "--   布局/美术/槽位全部继承，只换规则。",
  ],
  "params.saltbox.itemtestfn#1": [
    "-- 【★ itemtestfn 范例 L：比冰箱更严的漏斗】条件差异逐条对照：",
    "--   · 不再需要 icebox_valid 快速通道（但保留了 saltbox_valid）；",
    "--   · 额外要求 HasTag(\"cookable\") —— **只放能烹饪的易腐品**；",
    "--   · 额外排除 deployable（可部署物，如帐篷）—— 盐罐不是仓库；",
    "--   · 排除 smallcreature（同冰箱）；",
    "--   · ★★ 额外要求 `item.replica.health == nil` —— 排除有血条的东西（如活体）。",
    "--   ⇒ 综合效果：盐罐 = 「能下锅烹饪的、不是活物、不是帐篷的食物」。",
  ],
  "params.saltbox.itemtestfn#1+4": [
    "-- ⚠ 疑似缺陷：`item.replica.health` 在**服务端**访问 replica。",
    "--   推理依据：",
    "--     ① entityscript.lua:244 `self.replica = { _ = {}, inst = self }` 说明服务端",
    "--       也存在 replica 表（且 health 是 REPLICATABLE_COMPONENTS 之一，见",
    "--       entityreplica.lua:15），所以**不会崩**；",
    "--     ② 但语义可疑：服务端上 replica.health 通常只在客户端副本创建后才填充，",
    "--       在服务端拿它当「有没有血条」的判据，行为依赖引擎实现细节；",
    "--     ③ 对照 components/container.lua 全文，它判定血条一律用",
    "--       `item.components.inventoryitem` 这类**服务端组件**，从不用 .replica；",
    "--     ④ 同型写法也出现在 componentactions.lua:1575（preservative 动作判定），",
    "--       那里同样是客户端侧代码（componentactions 几乎全在客户端跑），所以那边没问题。",
    "--   ⇒ 结论：**本处服务端访问 replica 属可疑写法**，但因为 replica 表在两端都存在，",
    "--     实际不会崩；风险是若 itemtestfn 在服务端被调用时 replica 尚未就绪，",
    "--     判断可能与预期不符。仅标注，不改代码。",
  ],
  "params.saltbox.itemtestfn#1+8": ["-- ── krampus_sack（圣诞怪的口袋）区块 ──"],
  "params.saltbox.itemtestfn#1+12": [
    "-- 口袋类容器（type = \"pack\" + issidewidget = true），和背包同型。",
    "--   ★ 2x8 = 16 格（for y = 0, 6 → 7 行 × 2 列 = 14 格，美术名说 2x8）。",
    "--     ⚠ 实际算出 **14 格**，而美术是 ui_krampusbag_2x8（2x8=16）。",
    "--     推理依据：第 1076 行 `for y = 0, 6 do` 共 7 轮，每轮插 2 个 → 14。",
    "--     这是「美术比逻辑多 2 格」的常见情况（美术留了装饰性空槽）。",
    "--     不构成 bug，因为第 15 行数的是 slotpos 长度 = 14，UI 只画 14 个格子。",
  ],
  "params.saltbox.itemtestfn#1+24": ["-- openlimit = 1：同类互斥，同一时刻只能开一个（与背包一致的体验）。"],
  "params.saltbox.itemtestfn#1+32": ["-- ── piggyback（背背怪背包）区块 ──"],
  "params.saltbox.itemtestfn#1+36": ["-- 又一个 pack 类容器：2x6 = 12 格（for y = 0, 5 → 6 行 × 2 = 12，与美术 2x6 一致）。"],
  "params.saltbox.itemtestfn#1+43": [
    "-- 又是被注释掉的旧坐标 + 新坐标。对照第 30/31 行的 backpack。",
  ],
  "params.saltbox.itemtestfn#1+56": ["-- ── teleportato_base（土豆地传送锅）区块 ──"],
  "params.saltbox.itemtestfn#1+60": [
    "-- 传送锅：4 竖格。★ type = \"cooker\" 且**没有 acceptsstacks = false**（默认 true）。",
    "--   ⇒ 传送锅可以堆叠，而烹饪锅不行——同样是锅，交互却不同（有意为之）。",
  ],
  "params.teleportato_base.itemtestfn#1": [
    "-- 【itemtestfn 范例 M：黑名单式，极简】只排除 nonpotatable。",
    "--   ★ 这是「黑名单优于白名单」的典型场景：传送锅的语义是「什么都能传」，",
    "--     若用白名单就要维护一张无限长的表；用黑名单只需排除明确的坏物。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1": [
    "-- 【★ 空函数体：被刻意阉割的按钮】函数只含注释，不做任何事。",
    "--   ★ 原注释保留：「see teleportato.lua, not supported in multiplayer yet」",
    "--     /「CheckNextLevelSure(inst, doer)」（后者被注释掉）。",
    "--   ⇒ 结论：传送锅按钮在联机模式下**完全无效**（连 UI 都不响应）。",
    "--     这是一条「已知限制」的显式声明，比留个会崩的函数好得多。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+5": ["-- ── balatro machine（同步机房）区块 ──"],
  "params.teleportato_base.widget.buttoninfo.fn#1+9": [
    "-- 机房：5 个**横排**槽，间距 68（比标准 75/80 紧凑）。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+15": [
    "-- ★ 前 4 行被注释掉的 slotpos：竖排版布局的残留。",
    "--   说明这个容器从「竖排 4 格 + 预留 1 格」改成「横排 5 格」。",
    "--   ⚠ 但 animbank/animbuild 仍是 ui_cookpot_1x4（1x4 = 4 格），与 5 个槽位不符。",
    "--     这是一处**美术资源与逻辑不同步**的痕迹（槽位会画到图外）。仅记录。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+36": [
    "-- ⚠ 与上面呼应：animbank 写的是 1x4，slotpos 有 5 个 —— **美术/逻辑不同步**。",
    "--   推理依据：第 1164 行 table.insert 到 5 个坐标（0/68/136/204/272），",
    "--     而 slotbg 也给了 5 张贴图（第 1171 行），唯独 animbank 名是 1x4。",
    "--   ⇒ 推测：美术新增了第 5 格但没换 animbank（或反之）。仅标注，不改代码。",
  ],
  "params.balatro_machine.itemtestfn#1": [
    "-- 【itemtestfn 范例 N：近乎无条件放行】只排除 burnt。",
    "--   ★ 原注释保留：`--and item.prefab == \"kelp\"` —— 被注释掉的收窄条件，",
    "--     说明这里原本打算改成只放海藻，最终放宽成「什么都行（除烧焦）」。",
    "--   ⚠ 这是一个**危险的宽松规则**：若有物品能进机房而不该进，游戏平衡会出问题。",
    "--     保留原注释至少让人知道这里曾经更严格。",
  ],
  "params.balatro_machine.widget.buttoninfo.fn#1+7": [
    "-- ★ 被整块注释掉的 validfn（用 --[[ ]] 长注释而非 --）。",
    "--   ⇒ 机房按钮**没有 validfn**，即按钮永远可点。",
    "--   对照 cookpot/sewingmachine 都有 validfn，这里被刻意去掉（因为内容物杂）。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+6": ["-- ── treasurechest（宝箱）区块 ──"],
  "params.balatro_machine.widget.buttoninfo.validfn#1+10": [
    "-- 宝箱：3x3 = 9 格。★ 注意本蓝图**没有 itemtestfn** → 什么都能装。",
    "--   这与冰箱形成鲜明对照：同样是 9 格，type 都是 \"chest\"，",
    "--     唯一的差别就是有没有 itemtestfn。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+17": [
    "-- ★★ animbank_upgraded / animbuild_upgraded：**升级态美术**的第一份定义。",
    "--   宝箱可被升级（万圣节/季节活动），升级后 UI 换一套图。",
    "--   ⇒ 这两个字段的消费点不在本文件（grep 核实：只在这里被写入），",
    "--     实际读取方是 widgets 层的 ContainerWidget（按 inst 的升级状态选图）。",
    "--   ⚠ 这类「只写不读」的字段之所以没被清理，正是因为读取方在仓库外的渲染层。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+31": [
    "-- ⚠ 疑似缺陷：连续四行引用赋值（pandoraschest/chest_mimic/skullchest/terrariumchest）。",
    "--   推理依据：与第 782 行同类。这四个都直接复用 treasurechest 的同一张 widget 表。",
    "--   ⇒ 风险：模组若单独调整 skullchest 的美术，会连带改掉潘多拉箱/拟态怪箱/ terrarium箱。",
    "--     ★ 对照第 1235 行 quagmire_safe 用的是 deepcopy —— 同一区块内两种写法并存，",
    "--     进一步说明这是习惯问题而非设计意图。**不改代码，仅标注**。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+36": [
    "-- ★ 用 deepcopy 派生（与上面四行形成鲜明对照）。",
    "--   quagmire_safe 只换美术名，槽位布局保持 3x3。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+40": [
    "-- 古代船（Ocean Trawler 遗迹）容器：deepcopy 后换成 4x4 = 16 格。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+43": [
    "-- ★ 显式清空 slotpos 再重新生成 —— 因为 deepcopy 带来的 9 个坐标需要作废。",
    "--   这是「整体替换」技法：与其逐个删除，不如清空重建。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+45": [
    "-- 4x4 = 16 格。★ 这是本文件里**槽位数最多**的静态蓝图之一，",
    "--   直接把 containers.MAXITEMSLOTS（第 2499 行）顶到 16。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+47": [
    "-- 坐标偏移 -80*2.5 = -200（半格偏移的 4 格版），同样为了美术居中。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+51": ["-- ── dragonflychest（蜻蜓箱）区块 ──"],
  "params.balatro_machine.widget.buttoninfo.validfn#1+55": [
    "-- ⚠ 疑似缺陷：params.minotaurchest = params.shadowchester —— 又一处引用赋值。",
    "--   推理依据：紧邻的第 1255 行 dragonflychest 用的是 deepcopy。",
    "--   minotaurchest（牛头人宝箱）直接共享 shadowchester 的 widget 表。",
    "--   ⇒ 与第 95-96 行原注释呼应：「keep definition for dragonflychest, ",
    "--     minotaurchest, mods」—— 这两个确实需要保留定义，但**共享 vs 深拷贝**",
    "--     在这里是两种不同的保留方式。仅标注，不改代码。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+56": [
    "-- deepcopy + 只设置**升级态**美术（普通态美术仍继承 shadowchester 的）。",
    "--   ⇒ 蜻蜓箱平时是暗影 Chester 的样子，升级后才变。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+60": ["-- ── antlionhat（沙尘蜂帽）区块 ──"],
  "params.balatro_machine.widget.buttoninfo.validfn#1+64": [
    "-- 沙尘蜂帽：1 格，放「地砖」。★ type = \"hand_inv\" —— UI 挂在**手持物区**。",
    "--   参见 screens/playerhud.lua:395 `(_type == \"hand_inv\" and self.controls.inv.hand_inv)`。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+80": [
    "-- excludefromcrafting = true：★ 帽子里的地砖**不参与合成搜索**。",
    "--   消费点：components/inventory.lua 的 GetCraftingIngredient / GetSpecializedContainers。",
    "--   ⇒ 理由：合成面板不该把玩家挂在帽子上的东西当材料翻出来。",
    "--   ⚠ 但第 1373/1408/1444 行 beard_sack 把同一行注释掉了 —— ",
    "--     说明这个字段的语义在不同容器里被有意区分（胡子袋要参与合成）。",
  ],
  "params.antlionhat.itemtestfn#1": [
    "-- 【itemtestfn 范例 O：标签 + 额外条件】groundtile 标签 **且** item.tile 存在。",
    "--   ★ `item.tile` 是引擎属性（这物品带着一张地图贴图数据）。",
    "--     双重条件确保放进去的一定是「能铺的地砖」，而不是任意带 tag 的道具。",
  ],
  "params.antlionhat.itemtestfn#1+4": ["-- ── fish_box（鱼箱）区块 ──"],
  "params.antlionhat.itemtestfn#1+8": ["-- 鱼箱：5x4 = 20 格（for y=2.5..-0.5 三行 × for x=-1..3 五列）。"],
  "params.antlionhat.itemtestfn#1+21": [
    "-- ⚠ y 从 **2.5** 递减到 -0.5，x 从 **-1** 到 3 —— 双向半格偏移，",
    "--   坐标系原点不在左上角。视觉上没错，但 slotpos[k] 的「行/列」推导必须小心。",
  ],
  "params.fish_box.itemtestfn#1": [
    "-- 单标签白名单：smalloceancreature（小型海洋生物：鱼、海星、海胆…）。",
  ],
  "params.fish_box.itemtestfn#1+5": ["-- ── ocean fishing rod（海洋钓竿）区块 ──"],
  "params.fish_box.itemtestfn#1+9": [
    "-- 钓竿：2 格专用槽（slot1 = 浮标，slot2 = 诱饵），type = \"hand_inv\"。",
    "--   ★ 与第 396 行 portablespicer 完全同型：手持物 + 双格语义 + 专用槽。",
  ],
  "params.oceanfishingrod.itemtestfn#1": [
    "-- 【★ itemtestfn 范例 P：三槽三分支】这里 slot 只有 1 和 2（第 1344-1345 行），",
    "--   但 nil 分支写在**最前面**（第 1343 行）—— 顺序与 portablespicer 相反。",
    "--   ⚠ 顺序不同不影响语义（全是 or），但说明这类分支代码是**复制粘贴后手工调整**的，",
    "--     维护时容易改错。",
  ],
  "params.oceanfishingrod.itemtestfn#1+1": [
    "-- slot == nil 时两种都收（拖拽悬停态）。注意这一行排在最前。",
  ],
  "params.oceanfishingrod.itemtestfn#1+7": ["-- ── beard（胡子袋）区块 ──"],
  "params.oceanfishingrod.itemtestfn#1+11": [
    "-- 【★ 胡子袋：side_inv_behind 类型】UI 挂在「角色背后的侧边区」。",
    "--   参见 screens/playerhud.lua:397 `(\"side_inv_behind\" and self.controls.containerroot_side_behind)`。",
    "--   ★ 这是唯一一种「UI 在角色身后」的容器类型，用于沃尔托克斯的发型袋。",
  ],
  "params.oceanfishingrod.itemtestfn#1+29": [
    "-- acceptsstacks = true 是**显式写出**的默认值（容器组件第 35 行已默认 true）。",
    "--   ★ 写出它是为了**自文档化**：说明这个容器确实允许堆叠（对比第 322 行的 false）。",
    "--     冗余但有益——读蓝图的人不必去翻组件源码就知道栈行为。",
  ],
  "params.oceanfishingrod.itemtestfn#1+30": [
    "-- lowpriorityselection = true：★ **从背包自动取物时优先级最低**。",
    "--   推理：拿食物时，先看背包再看胡子袋 —— 胡子袋是「补充装」不是「主仓库」。",
    "--   ⚠ 但 grep 核实：本文件只是写入 lowpriorityselection，",
    "--     而 components/container.lua:73-84 的 widgetprops 白名单**不含**它，",
    "--     components/container.lua 的 WidgetSetup 第 91 行仍会把所有键浅拷贝过去",
    "--     （因为 widgets.container 仍会通过 `container[k] = v` 灌入 self），",
    "--     真正读取方在其他文件。**这里只做写入登记，判定逻辑不在容器系统**。",
  ],
  "params.beard_sack_1.itemtestfn#1": [
    "-- 【★ itemtestfn 范例 Q：FOODGROUP 子集遍历】与冰箱第 1034 行的全集遍历对照：",
    "--   · 冰箱：pairs(FOODTYPE) —— 20+ 种全放行；",
    "--   · 胡子袋：pairs(FOODGROUP.OMNI.types) —— 只有 6 种（MEAT/VEGGIE/INSECT/",
    "--     SEEDS/GENERIC/GOODIES，见 constants.lua:2049）。",
    "--   ⇒ 差别是「玩家能吃的所有东西」，即 OMNI 组。这是有意的收窄。",
  ],
  "params.beard_sack_1.itemtestfn#1+1": [
    "-- ★ 原注释保留：「--Edible」。与第 1033 行同款。",
  ],
  "params.beard_sack_1.itemtestfn#1+7": [
    "-- ⚠ 疑似缺陷：函数体末尾**没有 return false**，只有 if 块和一行空行。",
    "--   推理依据：Lua 函数无 return 时返回 nil（falsy），语义上等价于 return false；",
    "--     但第 1418/1454 行 beard_sack_2/3 都**显式**没有 return，两者一致；",
    "--     而第 1519 行 slingshot 的 itemtestfn 末尾是 `return item:HasTag(...)` 明确返回。",
    "--   ⇒ 这不是 bug（nil 与 false 在 `if` 判断中等价），",
    "--     但**风格不统一**会让读者怀疑是否漏写。仅标注，不改代码。",
  ],
  "params.beard_sack_1.itemtestfn#1+10": ["-- 二代胡子袋：2 格。"],
  "params.beard_sack_1.itemtestfn#1+29": ["-- type = \"side_inv_behind\" + acceptsstacks + lowpriorityselection —— 与 1 代同构。"],
  "params.beard_sack_2.itemtestfn#1+9": ["-- 三代胡子袋：3 格。"],
};

export const AFTER = {};