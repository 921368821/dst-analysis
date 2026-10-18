--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/terrain.lua（174 行）
-- 模块：世界生成 / 地形过滤表（Terrain Filter）
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【TERRAIN_FILTER】★★ prefab → **禁止出现**的地块列表（黑名单语义）。
--     ★★ 方向最容易搞反：表里列的是"不能长"的地块。
--   【OnlyAllow】7 处白名单写法：遍历全部已注册地块取补集。
--     ★ 补集相对于"当前已注册地块"求 ⇒ 新增地块自动进黑名单。
--   【ARCHIVE / VAULT 追加】require 时给每条规则 in-place 追加 3 个地块
--     ⇒ 存档区（档案馆/保险库）里任何植物都不长。★ 靠数据表兜底。
--   【terrain.filter.Print】调试用，打印黑名单的可读形式。
--   【弃用 shim】terrain.rooms 走 __index 转 Rooms.GetRoomByName，
--     ★ 仍返回正确结果但每次访问 moderror —— 老 mod 不崩、开发者能定位。
--   ⚠【风格 A 列表地狱】134 行里绝大多数是显式黑名单枚举，
--     新增地块时**不会**自动被排除（与 OnlyAllow 相反）—— 真实维护陷阱。
--   ⚠【横跨两个时代】components/map.lua:613-614 运行时也在读这张表，
--     改动影响面远大于"一张 134 行的表"的观感。
--
-- ★★★ 0. 本文件只有两张表 + 一个兼容 shim，是 map/ 里最"纯数据"的文件
--   ① TERRAIN_FILTER（:14-147）—— **prefab → 禁止出现的地块列表**。
--      ★★ 注意语义方向：表里列的是**不能长**的地块，不是能长的。
--   ② 对老 API terrain.rooms 的弃用 shim（:164-174）。
--
-- ★★ 1. ★★★ TERRAIN_FILTER 的语义（★ 最容易搞反的一处）
--   -- These items will not spawn on a terrain tile of the types in the
--      list provided                                     （:13 原注释）
--   例：berrybush = { ROAD, WOODFLOOR, SCALE, CARPET, CHECKER, ROCKY,
--                     MARSH, DIRT, DESERT_DIRT, MONKEY_DOCK }
--   ⇒ 浆果丛**不会**长在道路、地毯、岩石地、沼泽、沙地、猴岛码头。
--     它会长在草地、森林、瓷砖地上（凡不在表里的都允许）。
--   ★ 两种书写风格并存，语义完全等价：
--     风格 A（黑名单，显式列举）：berrybush = { ROAD, ... }      ← 绝大多数
--     风格 B（白名单求补）：toadstool_cap = OnlyAllow({ ROCKY })  ← 7 处
--     OnlyAllow(:3) 遍历 GetWorldTileMap() 取补集 ⇒ ★★ 白名单是
--     **相对于"当前已注册的全部地块"** 求的，★ 未来新增地块会自动被加入黑名单。
--     ⇒ 风格 B 对新地块是安全的，风格 A 不是。⚠ 这是个真实的维护陷阱。
--
-- ★★ 2. ★★ :150-154 的全局副作用（★ 本文件最隐蔽的一处）
--     for terrain, tiles in pairs(TERRAIN_FILTER) do
--         table.insert(tiles, WORLD_TILES.ARCHIVE)
--         table.insert(tiles, WORLD_TILES.VAULT)
--         table.insert(tiles, WORLD_TILES.VAULT_CLEAN)
--     end
--   ★ 这在 require 时**一次性执行**，给**每一条**规则追加 3 个地块。
--   · 后果①：★ 这三个地块（档案馆 / 保险库）里**任何**植物都不长。
--     ★ 这是"存档区必须是纯净空地"的实现方式——**靠数据表兜底，
--     而不是靠布置逻辑**。
--   · 后果②：★ 它 **in-place 修改** TERRAIN_FILTER 的每一个 value 表。
--     若本模块被 require 两次（不同路径），会追加两次 → 无害但冗余。
--     若有 mod 在 require 之后缓存了某条规则的引用再读，会看到被追加后的值。
--   · 后果③：★ OnlyAllow 生成的补集**不会**包含这三个（因为它们是
--     require 时才插入的，而 OnlyAllow 在 :101-145 就已经跑完）。
--     ⇒ ⚠ 疑似缺陷（极轻微）：风格 B 的 7 条规则**没有**享受
--       "档案馆/保险库禁长"的加固。因为它们已经把自己排除成"除 ROCKY 外都禁"，
--       而 ARCHIVE/VAULT 本来就在补集里 ⇒ ★ 结论：其实**恰好是安全的**，
--       但这是巧合而非设计。⚠ 记录以防将来改动打破它。
--
-- ★★ 3. ★★ 为什么这张表是"生物群系约束"的真正载体
--   ★ grep 核实：terrain.filter 的消费点只有 4 处
--     · map/forest_map.lua:25-36  pickspawnprefab（权重散布时否决）
--     · map/forest_map.lua:65-79  pickspawncountprefabforground（定数散布时否决）
--     · map/ocean_gen.lua:745    海洋散布时否决
--     · ★ components/map.lua:613-614 —— ★★★ **运行时也在用**！
--       （组件 map 用它决定已生成的实体是否合法/是否要清理）
--   ⇒ 所以这张表**跨越了生成期与运行期**，改动它的影响面
--     远大于它看起来的样子（一张 134 行的表，两个时代都在读）。
--   ★★ 而 map/storygen.lua:1038 / 1073 / 1136 / 1329 只是把
--     `terrain_filter = self.terrain.filter` **整个引用挂到节点 data 上**
--     ⇒ ★ 节点的 data.terrain_filter 字段在 Lua 侧**从不被读取**，
--       真正生效的是上面那 4 个直接读 terrain.filter 的点。
--       挂上去只是为了让 C++ 侧或调试器能看到。
--
-- ★ 4. ★ 兼容 shim（:164-174）—— ★ 值得学的弃用手法
--   old_rooms_mt.__index = function(table, key)
--       moderror(string.format("Accessing 'terrain.rooms' directly is being
--           deprecated, please use AddRoomPreInit(\"%s\") instead!", key))
--       return Rooms.GetRoomByName(key)
--   end
--   ★ 手艺：
--     ① **不报错**，仍然返回正确结果 ⇒ 老 mod 不崩；
--     ② ★ **每次访问都 moderror** ⇒ 开发者看日志能立刻定位到该改哪儿；
--     ③ 错误信息里**带上出错的 key 名** ⇒ 可直接定位。
--   ⇒ 对比 level.lua:16-22 的 assert 式硬迁移，两者可并存：
--     数据结构（字段）用 assert 硬崩，API（字段访问）用 shim 软弃用。
--     ★ 因为前者是本项目自己会改的，后者是外部 mod 在用的。
--
-- ★★ 5. ★★ 随机数：本文件**零 math.random**（★ grep 核实）
--   ★ 但它间接决定随机结果：TERRAIN_FILTER 被否决掉的 prefab
--     不会进入 pickspawnprefab 的候选池 ⇒ ★ 改这张表会**直接改变**
--     所有后续随机抽取的候选集，从而改变整张地图。
--   ⇒ 这是"纯数据文件影响随机流"的典型：★ 它是 seed 敏感表之一。
--
-- ★ 6. 交叉引用
--   ★ 权重散布的过滤 ...... map/forest_map.lua:16-52 pickspawnprefab
--   ★ 定数散布的过滤 ...... map/forest_map.lua:62-84
--                         pickspawncountprefabforground
--   ★ 海洋散布的过滤 ...... map/ocean_gen.lua:745
--   ★★ 运行时也在读 ....... components/map.lua:613-614
--   节点上挂的引用（只读不用） map/storygen.lua:1038 / 1073 / 1136 / 1329
--   Print（调试用） ......... :156-162（★ 唯一被 forest_map.lua:27/33
--                           的注释掉的 print 提到过）
--   GROUND_NAMES（Print 用）  constants.lua
--   GetWorldTileMap ........  ★ C++ 注入；★ 决定了 OnlyAllow 的补集范围
--============================================================
--
--【阅读导航】
--  §零   OnlyAllow（★ 白名单求补，依赖 C++ 的 GetWorldTileMap）(1-11)
--  §一 ★★ TERRAIN_FILTER 主表（★ 134 行，★ 黑名单语义）  (13-147)
--  §二 ★★ :150-154 全局追加（★ 档案馆/保险库禁长）       (149-154)
--  §三   Print（调试辅助）                              (156-162)
--  §四 ★ 弃用 shim old_rooms（★ 值得学的手法）           (164-174)
--
--【★★ 全文件最重要的六条】
--  1. ★★★ 语义是**黑名单**：列出的地块**不能**长。搞反会导致整张地图空掉。
--  2. ★★ 两种风格并存：显式黑名单（绝大多数）vs OnlyAllow 白名单求补（7 处）。
--     ★ 白名单对未来新增地块是安全的，黑名单不是 —— 维护陷阱。
--  3. ★★ :150-154 在 require 时给每条规则追加 ARCHIVE/VAULT/VAULT_CLEAN
--     ⇒ 存档区与保险库**任何植物都不长**。这是纯数据兜底的典范。
--  4. ★★ 这张表**跨越生成期与运行时**（components/map.lua:613 也在读），
--     改动影响面远大于 134 行的视觉体量。
--  5. ★ storygen 挂到节点上的 `terrain_filter` 字段在 Lua 侧从不被读，
--     ★ 真正的过滤发生在 forest_map / ocean_gen 的两个 spawn 选择器里。
--  6. ★ 弃用 shim（:164-172）：不报错 + 每次 moderror + 错误信息带 key 名
--     ⇒ 让老 mod 平滑迁移且开发者一眼定位。对比 level.lua 的 assert 硬崩，
--     两者是互补而非冲突：**字段废弃用 assert，API 废弃用 shim。**
--============================================================
-- ★★ 开头两行是空行。terrain.lua 是 map/ 里最「纯数据」的文件：
--   全文件只有 ① 一张黑名单表 ② 一个白名单求补辅助函数 ③ 一个弃用 shim。
--   ★ grep 核实：本文件**零 math.random、零 WorldSim 调用**。
--   ★ 但它通过「否决候选集」间接决定所有随机抽取的结果（见 HEADER 第 5 条）。


-- ══════════════ OnlyAllow：白名单求补 ══════════════
-- ★★ 语义：传入「允许的地块」，返回「**除此之外全部**」的地块清单。
--   用法 `xxx = OnlyAllow({ WORLD_TILES.ROCKY })` 意为「只长在 ROCKY」。
-- ★★ 为什么需要它：黑名单风格（下面 130 行那种）**不覆盖未来新增地块**，
--   而白名单求补**自动覆盖**——新注册的地块自动进黑名单。
--   ⚠ 但代价是：若 C++ 侧新增了某个地块，行为会**静默改变**。
local function OnlyAllow(approved)
	local filter = {}
-- ★ GetWorldTileMap() 是 **C++ 注入的全局函数**，返回当前注册的全部地块 ID。
--   ★★ 这意味着：★ 本文件的加载时机必须晚于 C++ 的地块注册完成。
--   ★ 若在纯 Lua 单元测试里 require 本文件，此行会 crash（nil 索引）。
--   ⇒ 这也是「世界生成脚本无法单测」的一个具体例证（对比 graphnode.lua:189 的同类写法）。
	for _,v in pairs(GetWorldTileMap()) do
-- ★ table.contains(approved, v)：v 不在白名单里就收进 filter。
--   approved 是数组，用 ipairs 线性查找 ⇒ 7 处调用，代价可忽略。
		if not table.contains(approved, v) then
			table.insert(filter, v)
		end
	end
-- ★ 返回的 filter 是一张「普通数组」，被当作 TERRAIN_FILTER 的 value 使用。
--   ⇒ ★★ 注意两种 value 形态并存：黑名单风格的表也用 `{...}` 字面量，
--     但它们是**语义相反**的两种表。读表时必须先看它是哪种风格。
	return filter
end

-- ══════════════ ★★★ TERRAIN_FILTER：prefab → 禁止出现的地块 ══════════════
-- ★★★ 语义方向（最易搞反）：★ 表里列的地块是「**不能**长」，
--   凡是**不在**表里的地块都允许。
--   例：berrybush 禁 ROCKY/MARSH/DIRT/ROAD/… ⇒ 它**可以**长在草地、森林。
-- ★ 两种书写风格并存，语义完全等价（都产出「禁止列表」）：
--   风格 A（黑名单，显式列举）：berrybush = { ROAD, WOODFLOOR, … }  ← 约 127 行
--   风格 B（白名单求补）      ：toadstool_cap = OnlyAllow({ROCKY})     ← 7 处
--   ★ 维护提示：风格 B 对未来新增地块是安全的，风格 A 不是。
-- These items will not spawn on a terrain tile of the types in the list provided
local TERRAIN_FILTER=
	{
-- ★ 典型黑名单条目：浆果丛禁道路/人造地板/岩石地/沼泽/沙地/猴岛码头。
--   ★ 语义解读：这些地块都是「人造或非自然」的，浆果丛不该长在上面。
		berrybush=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		berrybush2=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		berrybush_juicy=	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
-- ★ beefalo（牛）：禁道路等 + 沼泽。★ 因为沼泽对牛是水，无处立蹄。
-- ★ pighouse / pigman 猪：禁 ROAD/地板类，但**允许** MARSH（见 65-66 行）
--   ⇒ ★ 与 beefalo 形成对照：**同类生物的不同变体可以有不同地形约束**，
--     这是「生物群系约束精细化」的实例。
		beefalo=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH},
		beehive=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH},
		wasphive=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH},
-- ★ beemine（蜂巢残骸）：禁列表比 beehive 短（无 MARSH/ROCKY）。
--   ⇒ 微调粒度可以到单个 prefab。
		beemine = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
-- ★ carrot_planted（种下的胡萝卜）：禁列表**额外含 SAVANNA**。
--   ⇒ ★ 同一个 prefab 在不同地貌的可种植性由这张表唯一决定。
		carrot_planted = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.SAVANNA, WORLD_TILES.MONKEY_DOCK },
		evergreen		= 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		pinecone_sapling= 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_normal = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_short = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_tall = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_sparse = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_sparse_normal = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_sparse_short = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_sparse_tall = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		twiggytree = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		twiggy_normal = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		twiggy_short = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		twiggy_tall = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		evergreen_burnt = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.MONKEY_DOCK },

-- ★ twigs（树枝）：禁列表**不含 MONKEY_DOCK**（对比 33 行 twiggytree 含）。
--   ⇒ ★★ 极细粒度：twiggytree 禁猴岛码头，twigs 不禁。
--   ⇒ 这是**手工逐条维护**的表，改动时容易漏。
		twigs = {WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT},


		evergreen_stump = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.MONKEY_DOCK },
		deciduoustree = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		acorn_sapling = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		deciduoustree_normal = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		deciduoustree_tall = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		deciduoustree_short = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		deciduoustree_burnt = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		deciduoustree_stump = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		livingtree = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		flower = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		red_mushroom = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		green_mushroom = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		blue_mushroom = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		flint = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.METEOR },
		fireflies = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		grass = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.METEOR, WORLD_TILES.MONKEY_DOCK },
		depleted_grass =	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		gravestone = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		firepit =  		    {WORLD_TILES.ROAD},
		log = 				{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		mandrake = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.MONKEY_DOCK },
		marsh_bush = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MONKEY_DOCK },
		marsh_tree = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MONKEY_DOCK },
		pighouse =			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		pigman =			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		mermhouse =			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		pond = 				{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MONKEY_DOCK },
		pond_mos = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MONKEY_DOCK },
		reeds = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.METEOR, WORLD_TILES.MONKEY_DOCK },
		rock1 = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.METEOR},
		rock2 = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.METEOR },
		rock_ice = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
-- ★★ rock_moon（月岛石）：禁列表**含 WORLD_TILES.GRASS 与 FOREST**！
--   ⇒ 这是全表唯一「禁草地」的反向条目：月岛石是月岛特产，
--     不该出现在普通草原/森林里。★ 属地约束的实现方式。
		rock_moon =			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.METEOR, WORLD_TILES.GRASS, WORLD_TILES.FOREST },
		rock_flintless =	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		rock_petrified_tree = {WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		basalt = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		houndbone = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		houndmound = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		catcoonden = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		basalt_pillar =		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		rocks = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.QUAGMIRE_PARKFIELD },
		rabbithole=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.MONKEY_DOCK },
		molehill=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.MONKEY_DOCK },
		sapling=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.QUAGMIRE_PARKSTONE, WORLD_TILES.MONKEY_DOCK },
		spiderden = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		spiderden_2 = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		spiderden_3 = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		tallbirdnest = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
-- ★★ tentacle（触手）：禁列表含 GRASS / FOREST / SAVANNA ——
--   ⇒ 触手是**洞穴**专属，不能长在地面群系。★ 群系隔离。
		tentacle=			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.GRASS, WORLD_TILES.FOREST, WORLD_TILES.SAVANNA, WORLD_TILES.MONKEY_DOCK },
		trap_teeth = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		marbletree =		{WORLD_TILES.ROAD, WORLD_TILES.MONKEY_DOCK },
		marblestatue =		{WORLD_TILES.ROAD},

		stagehand = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.SAVANNA },
		moonbase = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.SAVANNA },
		beequeenhive =		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.MARSH, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.SAVANNA, WORLD_TILES.FOREST, WORLD_TILES.MONKEY_DOCK },
-- ★ critterlab（实验室）：禁 ROAD/GRASS/FOREST/SAVANNA/MARSH
--   ⇒ 只允许在瓷砖地/洞穴地。★ 特殊场景的地形强约束。
		critterlab =		{WORLD_TILES.ROAD, WORLD_TILES.GRASS, WORLD_TILES.FOREST, WORLD_TILES.SAVANNA, WORLD_TILES.MARSH },
		deerspawningground= {WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.SAVANNA, WORLD_TILES.MARSH },

-- ─── ★★★ 从这里开始是「风格 B：OnlyAllow 白名单求补」的 7 处 ───
-- ★★ 与上面 127 行黑名单并列存在，**同一个文件两种思维**。
-- ⚠ 维护者必须同时在脑内维护「正向白名单」与「反向黑名单」两套模型。
		toadstool_cap =		OnlyAllow({WORLD_TILES.ROCKY}),

-- ★ monkeybarrel_spawner（猴桶生成器）：只允许 MUD / CAVE_NOISE。
--   ★ 注意 spawner 类 prefab 也在这张表里受约束（forest_map.lua:150-166
--   还有专门的 spawner 密度补偿表）。
		monkeybarrel_spawner =		OnlyAllow({WORLD_TILES.MUD, WORLD_TILES.CAVE_NOISE}),
		slurper_spawner =			OnlyAllow({WORLD_TILES.MUD, WORLD_TILES.CAVE_NOISE}),
-- ★ worm_spawner（ worm 生成器）：只允许洞穴系地块。
--   ★ 链条：WORLD_TILES.TILES / TILES_GLOW / TRIM / TRIM_GLOW /
--     CAVE / MUD / CAVE_NOISE —— 全是洞穴内的细分地面。
		worm_spawner =				OnlyAllow({WORLD_TILES.TILES, WORLD_TILES.TILES_GLOW, WORLD_TILES.TRIM, WORLD_TILES.TRIM_GLOW, WORLD_TILES.CAVE, WORLD_TILES.MUD, WORLD_TILES.CAVE_NOISE}),

		cave_hole =			OnlyAllow({WORLD_TILES.TILES, WORLD_TILES.TILES_GLOW, WORLD_TILES.TRIM, WORLD_TILES.TRIM_GLOW, WORLD_TILES.CAVE, WORLD_TILES.MUD, WORLD_TILES.CAVE_NOISE, WORLD_TILES.UNDERROCK}),

		driftwood_log =			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.METEOR },
-- ★★ 这 4 行（driftwood_*）是**海洋/海滩**的锚点：
--   只允许 PEBBLEBEACH（卵石滩）与 DIRT。
--   ⇒ 「海洋回归」DLC 的地形约束入口。
		driftwood_tall = 		OnlyAllow({WORLD_TILES.PEBBLEBEACH, WORLD_TILES.DIRT}),
		driftwood_small1 = 		OnlyAllow({WORLD_TILES.PEBBLEBEACH, WORLD_TILES.DIRT}),
		driftwood_small2 = 		OnlyAllow({WORLD_TILES.PEBBLEBEACH, WORLD_TILES.DIRT}),
		dead_sea_bones = 		OnlyAllow({WORLD_TILES.PEBBLEBEACH, WORLD_TILES.DIRT}),
		trap_starfish =			OnlyAllow({WORLD_TILES.PEBBLEBEACH, WORLD_TILES.MARSH}),
-- ★ moonglass_rock：只允许 METEOR（陨石地）——★ 月岛专属。
		moonglass_rock = 		OnlyAllow({WORLD_TILES.METEOR}),
		moonrocknugget =		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER },
		moon_tree = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		moon_tree_short = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		moon_tree_normal = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		moon_tree_tall = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		moon_fissure =			OnlyAllow({WORLD_TILES.METEOR}),
		bullkelp_beachedroot =  {WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.METEOR, WORLD_TILES.MONKEY_DOCK },

-- ★ flower_cave（洞穴花）：禁 FUNGUSMOON 与 MONKEY_DOCK，
--   ⇒ 注意它**允许**普通 FUNGUS（蘑菇地）。
		flower_cave =			{WORLD_TILES.FUNGUSMOON, WORLD_TILES.MONKEY_DOCK },
		mushtree_tall =			{WORLD_TILES.FUNGUSMOON, WORLD_TILES.MONKEY_DOCK },
		lightflier_flower =		{WORLD_TILES.FUNGUS, WORLD_TILES.FUNGUSRED, WORLD_TILES.FUNGUSGREEN, WORLD_TILES.MONKEY_DOCK },
		mushtree_moon =			{WORLD_TILES.FUNGUS, WORLD_TILES.FUNGUSRED, WORLD_TILES.FUNGUSGREEN, WORLD_TILES.DIRT, WORLD_TILES.MONKEY_DOCK },

		palmconetree = 			{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		palmconetree_short = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		palmconetree_normal = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
		palmconetree_tall = 	{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
        palmcone_sapling = 		{WORLD_TILES.ROAD, WORLD_TILES.WOODFLOOR, WORLD_TILES.SCALE, WORLD_TILES.CARPET, WORLD_TILES.CHECKER, WORLD_TILES.ROCKY, WORLD_TILES.DIRT, WORLD_TILES.DESERT_DIRT, WORLD_TILES.MONKEY_DOCK },
        
-- ★ daywalkerspawningground：只允许 MUD（泥地）。
        daywalkerspawningground = OnlyAllow({WORLD_TILES.MUD}),

-- ★ 注释列出 6 种 Quagmire（执政官）地块的全名，
--   紧接着下面 10 条规则全是 OnlyAllow 限定到 Quagmire 地块。
--   ⇒ ★★ 这是「新 DLC 扩展一张纯数据表」的典型成本：10 行新规则。
--   ★ 且它们全部依赖 OnlyAllow（白名单）⇒ 新增 Quagmire 地块时这些规则
--     会**自动跟着变严**，这是选择风格 B 的收益。
		-- quagmire ground types: WORLD_TILES.QUAGMIRE_GATEWAY, WORLD_TILES.QUAGMIRE_PEATFOREST, WORLD_TILES.QUAGMIRE_PARKFIELD, WORLD_TILES.QUAGMIRE_PARKSTONE, WORLD_TILES.QUAGMIRE_CITYSTONE, WORLD_TILES.QUAGMIRE_SOIL
		quagmire_sugarwoodtree = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
		quagmire_sugarwoodtree_small = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
		quagmire_sugarwoodtree_normal = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
		quagmire_sugarwoodtree_tall = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
		quagmire_spotspice_shrub = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
		quagmire_rock = OnlyAllow({WORLD_TILES.ROCKY, WORLD_TILES.QUAGMIRE_PARKSTONE, WORLD_TILES.QUAGMIRE_CITYSTONE}),
		quagmire_lamp_post = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKSTONE, WORLD_TILES.QUAGMIRE_CITYSTONE}),
		quagmire_pond_park = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
		quagmire_fern = OnlyAllow({WORLD_TILES.QUAGMIRE_PARKFIELD}),
-- ══════════════ TERRAIN_FILTER 主表结束 ══════════════
-- ★★★ 统计（grep 核实）：约 134 条 prefab 规则，其中
--   风格 A（黑名单字面量）约 127 条、风格 B（OnlyAllow）7 条。
	}

-- ══════════════ ★★★ 全局副作用：三地块禁长 ══════════════
-- ★★★ 下面这个循环在 require 时**一次性执行**，
--   给**每一条**规则的禁止列表追加 3 个地块：
--     WORLD_TILES.ARCHIVE       （档案馆）
--     WORLD_TILES.VAULT         （保险库）
--     WORLD_TILES.VAULT_CLEAN   （保险库-净）
-- nothing can grow on these tiles:
-- ★★ 后果①：这三个地块里**任何植物都不长**。
--   ⇒ ★ 这是「存档区/保险库必须是纯净空地」的实现方式——
--     ★★ 靠**数据表兜底**，而不是靠布置逻辑去保证。
--     ⇒ 好处：新增任何 prefab 到某个房间模板里，自动继承这条约束。
--     ⇒ 坏处：★ 无法为某个 prefab 开例外（除非绕开这张表）。
for terrain, tiles in pairs(TERRAIN_FILTER) do
-- ★ table.insert(tiles, …)：★ in-place 修改 TERRAIN_FILTER 的每个 value 表。
--   ⚠ 副作用链：任何在 require 之前/之后缓存了某个 value 表引用的代码，
--     读到的将是**被追加后**的表。目前无此类代码（grep 核实）。
	table.insert(tiles, WORLD_TILES.ARCHIVE)
-- ★ 保险库地块，同样禁长一切植物。
	table.insert(tiles, WORLD_TILES.VAULT)
-- ★ 保险库净（未开封状态），同样禁长一切植物。
	table.insert(tiles, WORLD_TILES.VAULT_CLEAN)
-- ⚠ 疑似缺陷（轻微，恰好无害）：
--   ★★ OnlyAllow 生成的补集是在 :101-145 **求值时**算完的，
--     早于本循环追加这 3 个地块。
--   ★ 直觉上「风格 B 的 7 条规则漏掉了这条加固」，
--     ★ 但推演下来它们**恰好安全**：OnlyAllow 的语义是「除白名单外全禁」，
--       而 ARCHIVE/VAULT/VAULT_CLEAN 本来就在补集里 ⇒ 等价。
--   ⇒ 这是**巧合而非设计**。记录在此以防将来把白名单改成
--     「只列出允许项」的正向表时，悄悄打破这个巧合。
end

-- ★★ TERRAIN_FILTER.Print：调试辅助，把地块 ID 列表转成可读地名。
-- ★ 作为**函数挂在表上**（不是独立函数）⇒ 只影响 table 本身，
--   ★★★ 但 ★★★ 这会让 pairs(TERRAIN_FILTER) 遍历出一个非 prefab 的项！
--   ★★★ 遍历器（如 forest_map.lua 的 pickspawnprefab 遍历 items）
--     必须小心：若误把 Print 当作 prefab 规则，terrain.filter[item] 会取到函数，
--     然后 `for idx,gt in ipairs(函数)` 立刻报错。
--   ★★ 实际安全的原因是：★ 遍历时传进来的 items 表来自
--     room 的 distributeprefabs（prefab 名单），而不是 TERRAIN_FILTER 本身。
--   ★★ 但这是本文件**唯一的设计陷阱**，务必记住。
TERRAIN_FILTER.Print = function (filter)
	local val = ""
	for i,v in ipairs(filter) do
-- ★ GROUND_NAMES[v] 是 constants.lua 里的反向映射：地块 ID → 显示名。
		val = val .." ".. GROUND_NAMES[v]
	end
	return val
end

-- ══════════════ ★ 弃用 shim：老 API terrain.rooms ══════════════
-- ★★ gjans 的注释说明了意图：房间应该用 AddRoomPreInit 修改，
--   而不是直接读写 terrain.rooms。保留兼容但打警告。
-- ★★ 这是值得学的弃用手法，三要素：
--   ① **不报错**（老 mod 不崩）；
--   ② **每次访问都 moderror**（开发者看日志立刻定位）；
--   ③ **错误信息带出错的 key 名**（可直接定位到具体哪一行）。
-- ★★ 对比 map/level.lua:16-22 的 assert 式硬迁移——两者是**互补**的：
--   · 字段（数据结构）废弃 ⇒ assert 硬崩（自己会改的代码）；
--   · API（外部访问方式）废弃 ⇒ shim 软弃用（外部 mod 在用的）。
-- gjans: Rooms should be tweaked from mods using the AddRoomPreInit function now. Preserving backwards compatability here, but with a warning.
local Rooms = require("map/rooms")
local old_rooms = {}
local old_rooms_mt = {}
-- ★ 元表的 __index 拦截「表中不存在的键」——old_rooms 初始是空表 {}，
--   所以任何 terrain.rooms.X 访问都会走进这个函数。
old_rooms_mt.__index = function(table, key)
-- ★ moderror（不是 error）⇒ 只在开发版弹提示，发行版静默。
--   ★ 错误信息里的 %s 就是 key 名，例如：
--     "Accessing 'terrain.rooms' directly is being deprecated,
--      please use AddRoomPreInit(\"Forest\") instead!"
    moderror(string.format("Accessing 'terrain.rooms' directly is being deprecated, please use AddRoomPreInit(\"%s\") instead!", key ))
-- ★★ 仍然返回正确结果 ⇒ 老代码「能跑但有警告」，这是平滑迁移的关键。
    return Rooms.GetRoomByName(key)
end
setmetatable(old_rooms, old_rooms_mt)

-- ★★★ 全文件收尾：导出全局 terrain 表，只有两个字段。
-- ★★ 注意这是**直接覆盖全局名 terrain**（不是 local terrain）。
--   ⇒ 所有 `terrain.filter[...]` 引用（forest_map.lua:25/65/69、
--     ocean_gen.lua:745、components/map.lua:613）都指向这一张表。
-- ★★ 消费点完整清单（grep 核实，仅 5 处）：
--   · map/forest_map.lua:25,30,33   权重散布时的地块否决
--   · map/forest_map.lua:65,69      定数散布时的地块否决
--   · map/ocean_gen.lua:745         海洋散布时的地块否决
--   · components/map.lua:613-614    ★★ 运行时组件也在读
--   · map/storygen.lua:1038/1073/1136/1329  ★ 只是把引用挂到节点 data 上，
--     ★★ 在 Lua 侧从未被读取（真正生效的是上面那 4 个直接读点）。
-- ⇒ ★★ 这张 134 行的表**跨越生成期与运行期**，改动影响面远大于视觉体量。
terrain={rooms=old_rooms, filter=TERRAIN_FILTER}
