/**
 * spec-containers-p4.mjs —— containers.lua 第 1452-2000 行
 * slingshot / slingshotmodscontainer / tackle / sunkenchest / sacred_chest / seedpouch / candybag / alterguardianhat / pocketwatch / ocean_trawler / bookstation / beargerfur_sack / houndstooth / battlesong / wortox_souljar
 */

export const BEFORE = {
  1456: ["-- ── slingshot（弹弓）区块 ──"],
  1463: [
    "-- 弹弓：1 格，放「弹弓弹药」。★ type = \"hand_inv\"（UI 在手持区）。",
    "--   ★ 与第 1318 行海洋钓竿同型——手持武器类容器的标准形态。",
  ],
  1479: ["-- hand_inv + excludefromcrafting：弹药不参与合成（同第 1279 行沙尘蜂帽的取舍）。"],
  1483: [
    "-- deepcopy + 换美术：三个弹弓变体（普通/骨/宝石）共用同一套逻辑，只换外观。",
    "--   ★ 这就是第 105 行 widgetsetup 浅拷贝的**正面价值**：",
    "--     蓝图里嵌套的 Vector3 是 UI 布局，与逻辑无关，换图不影响判定。",
  ],
  1491: [
    "-- 【★ slingshot2：双格弹弓，且槽序被刻意反转】",
    "--   第 1497 行原注释保留：「--reversed so bottom is slot 1」",
    "--   ★ 这是**槽位语义与视觉顺序解耦**的唯一一处：视觉上 slot 2 在上、slot 1 在下，",
    "--     而 slotpos 数组里 slot 1 写在前面。",
    "--   ⇒ 推论：槽位编号由 slotpos 数组顺序决定，而 UI 绘制位置也由 slotpos 决定，",
    "--     两者本应一致；这里通过「先写上面的坐标却表示下面的槽」人为反转，",
    "--     说明确有下游逻辑依赖「slot 1 = 底部」。仅记录这个反直觉约定。",
  ],
  1514: [
    "-- 宝石弹弓：deepcopy + 换美术 + ★ 单独调整第 2 槽 y 坐标（第 1517 行）。",
    "--   这展示了「派生后微调单个槽位」的粒度 —— 因为 slotpos 是 Vector3 数组，可以索引。",
  ],
  1519: [
    "-- 【★ itemtestfn 范例 R：带前置条件的标签判定】三层：",
    "--   ① 若物品有 REQUIRED_SKILL 字段，先查打开者的技能树是否解锁（第 1528 行）；",
    "--   ② 未解锁 → return false；",
    "--   ③ 解锁（或不需要技能）→ 最终只认 slingshotammo 标签。",
    "--   ★ 这是「弹弓弹药按角色技能树分化」的实现 —— 沃托克斯/ Wortox 相关机制。",
  ],
  1520: [
    "-- ★ 用「物品自带字段」REQUIRED_SKILL 作为门禁，容器系统本身不知道技能树的存在。",
    "--   ⇒ 设计要点：**物品可以携带自己的准入条件**，容器只需读取。",
    "--     这样新增一个「需要某技能的弹药」不需要改任何容器蓝图。",
  ],
  1522: [
    "-- 与第 819 行 sisturn 同型的双端分支（服务端 GetOpeners / 客户端 ThePlayer）。",
  ],
  1527: [
    "-- ★ 原注释保留：「NOTE: can have no owner when loading, or when replacing",
    "--   slingshots when swapping frames」。",
    "--   ⇒ 比第 826 行的 sisturn 多了一个例外：**换弹弓框（换弹药池）时也没有 owner**。",
    "--     推理：换框过程会重建容器实例，此刻无人「打开」它。",
    "--   第 1528 行的 `if owner and ...` 用 owner 非空做了守卫，所以加载期会**跳过**技能检查、",
    "--     直接落到第 1532 行接受弹药 —— 这是有意的「宽松兜底」。",
  ],
  1535: [
    "-- ★ 四个变体共享同一个 itemtestfn 函数指针。",
    "--   ⚠ 但注意顺序：slingshotex（第 1483 行 deepcopy）与 slingshot2（第 1491 行独立定义）",
    "--     都在这里被赋值。slingshotex 是 deepcopy 来的，本来就没有 itemtestfn，",
    "--     这里补上；slingshot2 已有，这里覆盖成同一个 —— 结果一致。",
  ],
  1540: ["-- ── slingshotmodscontainer（弹弓改装台）区块 ──"],
  1544: [
    "-- 【★ 改装台：三槽位语义（弹带/弹弓框/握把）+ 1.6 倍放大显示】",
    "--   ★ slotscale = 1.6 / slothighlightscale = 1.75：零件比普通格子大，",
    "--     因为弹弓零件在物品栏里会被缩小显示（弹弓是手持物，格子小）。",
    "--   ⇒ 这是一个纯 UI 参数，与逻辑完全无关，但缺了它零件就看不清。",
  ],
  1550: [
    "-- ★ 原注释保留的行内注释：「--band」「--frame」「--handle」——",
    "--   直接标出 slot1/2/3 分别是弹带/弓框/握把。",
    "--   ★ 这三行行内注释比外部块注释更有价值：它们让 slotpos 数组**自解释**。",
  ],
  1573: ["-- usespecificslotsforitems + acceptsstacks=false + type=cooker + openlimit=1 —— 四项全开。"],
  1579: [
    "-- 【★ itemtestfn 范例 S：三分支 + 显式 return false 兜底】",
    "--   与第 425/935 行同型，但**末尾有 return false**（第 1602 行），",
    "--   这才是完整写法 —— slot 超出 1..3 时（不可能，但防御性）返回 false。",
    "--   ★ 对照第 1383 行 beard_sack_1 没有 return：同一个团队里两种风格。",
  ],
  1593: [
    "-- ★ 三个 slot 分支用 if/elseif 链，最后 else nil 分支。",
    "--   ⚠ 与第 425 行 portablespicer 的「or 表达式」写法不同，这里是命令式分支。",
    "--     两种写法都能用，但命令式更容易加日志/调试分支。",
  ],
  1605: ["-- ── tacklecontainer（钓具箱）区块 ──"],
  1609: ["-- 钓具箱：3x2 = 6 格，放浮标与诱饵。"],
  1622: [
    "-- ★ y 从 1 到 0（只有 2 行），y 坐标偏移 +120 —— 整体上移，",
    "--   因为 UI 底板下方还要留位置放提示条。",
  ],
  1628: [
    "-- 【双标签白名单】oceanfishing_bobber / oceanfishing_lure，任意一个都行。",
  ],
  1632: [
    "-- 【★★ priorityfn 的定义方式】`priorityfn = itemtestfn`。",
    "--   ★ 关键：两者签名不同！itemtestfn 是 (container, item, slot)，",
    "--     priorityfn 是 (container, item) —— 调用点见 components/container.lua:319",
    "--     `self:priorityfn(item)`，Lua 会自动传 self 作第一参、item 作第二参，slot 为 nil。",
    "--   ⇒ 因为本例的 itemtestfn 不依赖 slot（第 1629 行没用 slot 参数），",
    "--     直接复用是安全的。★ 但若 itemtestfn 依赖 slot，这么赋值就会**永远传 nil**。",
    "--   ⚠ 这是本文件一个**易被误用的复用技巧**：第 1735 行 seedpouch、第 1764 行 candybag、",
    "--     第 1985 行 battlesong、第 2046 行 elixir、第 2130 行 slingshotammo_container、",
    "--     第 1658 行 supertacklecontainer 都用了同一手法 —— 全部安全（都不依赖 slot）。",
  ],
  1634: ["-- ── supertacklecontainer（超级钓具箱）区块 ──"],
  1638: ["-- 超级钓具箱：3x5 = 15 格（for y = 1 到 -3）。"],
  1651: [
    "-- ★ y 坐标公式 `80 * y - 45`（不是 -80*2+80）—— 因为是 5 行，",
    "--   需要从中心 45 像素处起算。这是一个**按行数反推偏移**的写法。",
  ],
  1657: [
    "-- itemtestfn 与 priorityfn 一起共享给超级版（两行成对出现，说明作者知道必须成对设）。",
  ],
  1660: ["-- ── sunkenchest（沉箱）区块 ──"],
  1663: [
    "-- ★★★ 原注释保留（本文件最有价值的一段工程说明）：",
    "--   「Sunken Chest is an actual container though it can not be opened it often reaches",
    "--    capacity from it's old container data (3x3) we have moved to 3x5 now",
    "--    We can deepcopy supertacklecontainer and set itemtestfn but I am making a entirely",
    "--    new definition to ensure it is not potentially messed with」",
    "--   ★ 逐句翻译与解读：",
    "--     ① 沉箱**是一个真正的容器**（有 slots 数组），但玩家**打不开它**；",
    "--     ② 它经常从小容量（3x3）旧存档数据**满载**进来 —— 即旧档有 9 个物品，",
    "--        新版 numslots 变 15，但加载时物品仍占着原来的槽位；",
    "--     ③ 作者明确考虑了「直接 deepcopy supertacklecontainer 再设 itemtestfn」的捷径，",
    "--        但**故意不用**，理由是「确保它不会被（共享表）意外搞坏」。",
    "--   ⇒ 这段注释是**共享可变表技术债的官方自证**：作者在别的容器上用了",
    "--     第 950 行那种 deepcopy 派生，但在这里拒绝派生，转而手写一份完整定义。",
    "--     这正好印证了本文件第 43/137/168 行那些引用赋值的风险是真实存在的。",
  ],
  1666: [
    "-- 手写完整定义（3x5），与 supertacklecontainer 布局相同但**不共享**。",
    "--   ★ 注意它**故意不设 itemtestfn** —— 于是沉箱什么都能装。",
    "--     为什么？因为它打不开，也就没人能往里放东西，规则无意义。",
  ],
  1679: ["-- 3x5 槽位生成，与第 1651 行逐字相同 —— 复制粘贴而非共享。"],
  1685: ["-- ── sacred_chest（圣柜）区块 ──"],
  1689: [
    "-- 圣柜：3x2 = 6 格。★ 同样**没有 itemtestfn** —— 万能箱。",
  ],
  1708: ["-- ── seedpouch（种子袋）区块 ──"],
  1712: ["-- 种子袋：2x8 布局（14 格），与 krampus_sack 同规格。"],
  1731: [
    "-- 【★ itemtestfn 范例 T：prefab 精确 + 字符串匹配 + 标签三合一】",
    "--   第 1732 行的三重 or 是本文件**最复杂的一条单行规则**：",
    "--     ① prefab 精确等于 \"seeds\"；",
    "--     ② ★ string.match(prefab, \"_seeds\") —— 用 Lua 模式匹配找**任意位置**的 \"_seeds\"；",
    "--        这条覆盖了所有 `xxx_seeds` 变体（前置/后缀变体），",
    "--        string.match 的第一个返回值是匹配到的子串，真值即通过；",
    "--     ③ HasTag(\"treeseed\") —— 兜底的标签通路。",
    "--   ⇒ 推论：一个种子物品只要满足三者之一就能进袋子，不必逐个注册。",
    "--   ⚠ 但 string.match 无锚点，若某物品名含 \"_seeds\"（如 \"seeds_dust\"）会被误纳。",
  ],
  1735: [
    "-- priorityfn = itemtestfn（同第 1632 行）。此处安全：第 1732 行不依赖 slot。",
  ],
  1737: ["-- ── candybag（糖果袋）区块 ──"],
  1741: ["-- 糖果袋：同样是 2x8 = 14 格，与种子袋布局完全一致（复用 krampus 美术）。"],
  1760: [
    "-- 【itemtestfn 范例 U：标签 + 前缀匹配】",
    "--   第 1761 行：`HasAnyTag(\"halloweencandy\", \"halloween_ornament\")` 或",
    "--     `string.sub(item.prefab, 1, 8) == \"trinket_\"`。",
    "--   ★ string.sub 取前 8 字符与 \"trinket_\" 比较 —— 这是**前缀匹配的正确写法**",
    "--     （对比第 1732 行 string.match 无锚点的写法，这里更严谨）。",
    "--   ⇒ 万圣节小丑饰品（trinket_xxx）能进糖果袋。",
  ],
  1766: ["-- ── alterguardianhatshard（ alters 监护者帽子碎片）区块 ──"],
  1770: ["-- 帽子碎片：1 格，放孢子（spore）。type = \"chest\"（世界里的实体容器）。"],
  1789: [
    "-- 单标签白名单：spore。与第 1790 行的 alterguardianhat 用 HasAnyTag(spore, lunarseed) 不同。",
    "--   ⇒ 同一个物品（spore）在两个容器里都能放，且判定规则不同。",
  ],
  1793: ["-- ── alterguardianhat 区块 ──"],
  1797: [
    "-- 监护者帽子：5 格竖排，放孢子与月之种。type = \"hand_inv\"。",
  ],
  1812: [
    "-- ★★ 坐标常量提成局部变量：AGHAT_SLOTSTART = 72*5-22 = 338。",
    "--   ★ 公式的来历：5 格 × 72 间距 = 360，再减 22 让整组略微上移居中。",
    "--   这比第 1013 行那种「循环 + 行内算式」更易读：",
    "--     常量把「为什么是这个数」显式化，而不是埋在算式里。",
    "--   ⚠ 但注意这**不是** immutable：第 1816 行的 sp 用它计算，不修改它。",
  ],
  1814: [
    "-- 第三张 slotbg 常量（spore_slot.tex），5 格共用。",
  ],
  1821: [
    "-- ★ 把物品清单提为常量表 ALTERGUARDIANHAT_ITEMS，供 HasAnyTag 展开。",
    "--   ⇒ 若要支持 lunarseed 的同时保留 spore 的语义，只需改这一张表。",
  ],
  1822: [
    "-- itemtestfn = HasAnyTag(常量表)。★ 最短最清晰的 itemtestfn 之一。",
  ],
  1826: ["-- ── pocketwatch（怀表）区块 ──"],
  1830: [
    "-- 怀表：3x2 = 6 格，放怀表零件。",
    "--   ★ pos = Vector3(-850, 100, 0) —— x 偏移 **-850 像素**，",
    "--     极负值 = UI 出现在屏幕**最左侧**（远离中央）。",
    "--   推论：怀表打开时物品栏会被推到右边，是为特殊道具设计的极端布局。",
  ],
  1854: ["-- ── ocean_trawler（海洋拖网渔船）区块 ──"],
  1858: ["-- 拖网渔船：4 竖格，acceptsstacks = false（每格一条鱼）。"],
  1878: [
    "-- 【双标签白名单】cookable 或 oceanfish。",
    "--   ★ 注意这里允许「可烹饪」但不带 burnt 守卫（对比第 374 行 cookpot 有）。",
    "--     ⇒ 烧焦的船（burnt 标签）仍能放鱼 —— 小差异，通常无害。",
  ],
  1882: ["-- ── bookstation（书站）区块 ──"],
  1886: [
    "-- 书站：4x5 = 20 格。★ 与第 1239 行的古代船并列，",
    "--   是**全文件槽位最多的静态蓝图**（20 格）。",
    "--   ⇒ 直接决定 containers.MAXITEMSLOTS = 20（第 2499 行），",
    "--     进而决定 container_classified 要为每个容器分配多少条 net_entity 变量。",
  ],
  1899: [
    "-- ★ 坐标公式 `-77 * y + 37 - (y * 2)`：行距 77 且**逐行再下移 2 像素**。",
    "--   推理：行距不是常数偏移，而是带累积项 —— 因为行高 77 小于格高，两行之间会挤。",
    "--   `- (y * 2)` 随 y 递增，等于每行比均匀分布再低 2 像素，补偿格子重叠。",
    "--   ⇒ 这解释了为什么只有这 4 个槽用 -114/-163/-238/-313 四个不同 x 值：",
    "--     4 列不等距（间距 75），因为右侧要避开翻页按钮。",
  ],
  1906: [
    "-- 单标签白名单：bookcabinet_item。",
  ],
  1910: ["-- ── beargerfur_sack（熊皮袋）区块 ──"],
  1914: ["-- 熊皮袋：2x3 = 6 格，放熟食。美术复用 ui_icepack_2x3（与香料包同图）。"],
  1928: [
    "-- ★ for y = 0,2 / for x = 0,1 → 6 格，但注意 x 方向是**向右**递增（-163 + 75*x），",
    "--   与其他容器的「从 -160 到 -85」写法相反。坐标原点在右下而非左上。",
  ],
  1935: [
    "-- 【itemtestfn 范例 V：标签 + 逃生口】",
    "--   HasAnyTag(\"beargerfur_sack_valid\", \"preparedfood\")。",
    "--   ★ 与冰箱第 1020 行的 icebox_valid 同型：给模组留一个「指定合法物」的标签口。",
    "--     官方自己用它装「冬oki 节的皮」，模组可用它塞任意自定义物品。",
    "--   ⚠ 风险：任何模组给物品打上 beargerfur_sack_valid 就能塞进去 —— 这是**刻意的开放**。",
  ],
  1940: ["-- ── houndstooth_blowpipe（獠牙吹管）区块 ──"],
  1944: [
    "-- deepcopy(params.slingshot) —— 吹管完全复用弹弓的 1 格手持布局，只换贴图与判定。",
    "--   ★ 跨「道具语义」复用 UI 布局（弹弓→吹管），说明布局参数确实已高度抽象。",
  ],
  1946: [
    "-- 整体替换 slotbg 为吹管专用贴图（1 格）。",
  ],
  1948: [
    "-- 单标签白名单：blowpipeammo。★ 与弹弓的 slingshotammo 同型，只是标签不同。",
  ],
  1952: ["-- ── battlesong_container（战歌容器）区块 ──"],
  1956: ["-- 战歌容器：2x4 = 8 格，放战歌。与背包同布局同美术。"],
  1970: [
    "-- ★ 第四处 slotbg 常量。累计本文件已有 4~5 处 slotbg 游标（第 190/228/278/745/1814 行），",
    "--   全是「声明 local → 用 → 置 nil」的相同模式。",
  ],
  1980: [
    "-- 单标签白名单：battlesong。",
  ],
  1985: [
    "-- priorityfn = itemtestfn（第 1632 行模式的第五次复用）。此处不依赖 slot，安全。",
  ],
  1987: ["-- ── wortox_souljar（沃尔托克斯魂罐）区块 ──"],
  1991: ["-- 魂罐：1 格，放灵魂。"],
  2005: [
    "-- ★ 自定义开合音效：开盖是「pop」，关盖是「close_pop」——",
    "--   两个不同音效而非同一音效的正放/倒放，体现了音效系统的灵活性。",
  ],
};

export const AFTER = {};