--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/graphnode.lua（610 行）
-- 模块：世界生成 / 图节点 = 一个房间 = 一个 Voronoi 胞元
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【Node 类】房间节点的实现。★ 一个 Node ⇒ 一个 Voronoi 站点 ⇒ 一块地形。
--   【node.data】房间的"元数据袋"：房间名 / biome / 尺寸 / 锁 / 钥匙 /
--     story_depth / tags / terrain_filter 等，几乎所有生成决策都挂在这里。
--   【AddNode / AddEdge】图的写入接口（storygen 通过它建整棵树）。
--   【PopulateVoronoi】★★ 撒资源的主循环：逐胞元按 biome 与 density 落地 prefab。
--   【SetTilesViaFunction】把房间布局 / 静态布局写进 tilemap。
--   【GetRoomLocation / FindEntityInRoom...】运行时按房间反查实体（跨生成期/运行期）。
--   【deepcopy 房间定义】从 map/rooms/*.lua 模板深拷贝出一个实例。
--   【room_functions】房间的地表装饰逻辑（草、石头、洞穴形态）。
--   ⚠【terrain_filter 只是挂载】node.data.terrain_filter 在 Lua 侧从不被读，
--     真正生效的是 forest_map / ocean_gen / components/map 那 4 个直读点。
--
-- ★★★ 0. Node 是什么
--   一个 Node 对应 map/rooms/ 里的一个**房间模板实例**（deepcopy 出来的）。
--   它带着这些数据参与世界生成：
--     .data.value         → 这个胞元压什么地面地块（WORLD_TILES.*）
--     .data.terrain_contents.countprefabs        → 定数摆放（如 flint=1）
--     .data.terrain_contents.distributeprefabs   → 权重散布（如 grass=0.5）
--     .data.terrain_contents.distributepercent   → 散布概率（0~1）
--     .data.terrain_contents.countstaticlayouts  → 静态场景件数量
--     .data.terrain_contents_extra               → 标签展开出来的东西
--     .data.type / .internal_type / .tags        → 拓扑与生成约束
--     .data.entrance / blocker_blank             → 门 / 封口
--   Voronoi 阶段后，C++ 给它算出一个胞元（polygon）与一批采样点
--   （points_x/points_y/points_type），★ 散布只遍历**采样点**，
--   不遍历格子（详见 PopulateVoronoi 的注释）。
--
-- ★★ 1. ★★★ 全文件只有 4 个"真正干活"的方法
--   ① ConvertGround(:247)     静态场景件（countstaticlayouts）落位
--   ② PopulateVoronoi(:330)   ★ 主散布：定数 prefab + 权重 prefab
--   ③ PopulateChildren(:498)  背景房间（task 级 background_room）散布
--   ④ PopulateExtra(:567)     世界生成设置的"加量"（>default 的项）
--   其余 20 多个方法都是 SaveEncode / 属性存取 / 钩子转发。
--
-- ★★ 2. ★ 随机数与可复现性
--   · ★ 本文件**零 randomseed**。
--   · 消耗随机的点：:321 GetRandomItem（swappable prefabs 解析）、
--     :458 math.random() < distributepercent、:582 math.random() < 0.25
--     （成簇 clumpcount 判定）、:593 pickspawnprefab（内含一次
--     math.random()*total）、:196-198 PopulateWorld_AddEntity 的 ±1 随机偏移。
--   · ★★ :196-199 的 `if rand_offset == nil or rand_offset == true` 意味着
--     **★ 省略参数与传 true 行为一致**（都加随机偏移），传 false 才固定。
--     而 forest_map.lua:613 的 add_fn 与 network.lua:856 都显式传了
--     rand_offset=false ⇒ 这两条路径的实体位置是**格子中心**，完全确定。
--     但 graphnode.lua:257 的 add_fn 也是 rand_offset=false。
--     ⇒ 真正带随机偏移的是 PopulateWorld_AddEntity 被
--       PopulateExtra(:598) 调用时 —— ★ 但它也没传（第 8 个参数后就没了），
--       实际上 data.idx_left 路径调用时 rand_offset 传入的是 nil ⇒ **会加偏移**。
--     ⇒ 结论：**散落实体的位置本身就不是纯随机的格子中心**，
--       这增加了"同种子同图"的验证难度（还受 float 精度影响）。
--
-- ★ 3. 交叉引用
--   Graph:AddNode → Node 构造 ................. map/network.lua:461 / 474
--   Edge 类 .................................. map/graphedge.lua
--   房间模板来源 .............................. map/rooms/*.lua
--   权重抽取 spawnFN.pickspawnprefab ......... map/forest_map.lua:16
--   按地块过滤 pickspawncountprefabforground . map/forest_map.lua:62
--   ★ 缺陷背景 ................................ E2（静默失败，bug-patterns.md）
--   prefab 改名映射 ........................... prefabswaps.lua
--   SaveEncode 的调用方 ........................ map/network.lua:120
--============================================================
--
--【阅读导航】
--  §零   依赖 / DENSITY_PRECISION / 两个 prefab 权重工具  (1-44)
--  §一 ★ recurseTable（★ 递归参数漏传的疑似缺陷）       (46-80)
--  §二   filterPrefabsForGlobalSwaps              (82-104)
--  §三 ★ Node 类构造（custom_tiles/objects 提前转钩子）(107-140)
--  §四 ★ SaveEncode（★ 坐标居中与取整精度）            (142-166)
--  §五 ★ PopulateWorld_AddEntity（★ 坐标换算的核心）   (188-235)
--  §六 ★ AddEntity（★ 非陆地直接丢弃）                (238-245)
--  §七 ★ ConvertGround（静态场景件 + scratchpad）      (247-279)
--  §八   自定义钩子 SetPopulate/Tiles + ViaFunction   (281-314)
--  §九 ★★ PopulateVoronoi（★ 主散布，E2 缺陷现场）    (330-495)
--  §十 ★★ PopulateChildren（★ perTerrain 混合地块）   (498-565)
--  §十一 ★★ PopulateExtra（世界生成设置的加量）        (567-610)
--
--【★★ 全文件最重要的十条】
--  1. ★★ 散布的单位是 **Voronoi 采样点**，不是格子。
--     :348 GetPointsForSite 返回 points_x/y/type，#points_x 就是这个
--     胞元"能用多少个位置"。Lloyd 松弛的迭代次数（forest_map.lua:499）
--     直接决定这个数 ⇒ ★ 群系大小不均 → distributepercent 的实际密度剧烈波动。
--  2. ★★ E2 缺陷现场：:369-372 `if #points_x < floor(pos_needed) then return end`
--     ⇒ **整个节点的所有 prefab 一个都不放**，只 print 一行。
--     :421-424 同理（中途放弃）。:392/:441 再加两处。
--     这是"玩家说地图上没东西、开发者复现不了"的根因。
--  3. ★★ :374-405 countprefabs_uses_filters 分支会
--     **table.remove 三条并行数组**（:389-391），把已用的点从池子里删掉。
--     ⚠ 疑似缺陷：循环条件是 `while next(generate_these) ~= nil`，
--       但内部 `cur_pt = cur_pt - 1` 与 `table.remove` 会让
--       cur_pt 与 #points_x 不同步 —— remove 之后 cur_pt 指向的元素已经左移，
--       实际是"从尾部往前扫并原地删"，逻辑上碰巧自洽但极易读错。
--       若 pickspawncountprefabforground 返回 nil（全部被地块过滤掉），
--       :397 仍然 cur_pt-1 ⇒ 会白扫一遍但不死循环（cur_pt 到 0 break）。
--  4. ★ :460 `if prefab == nil then table.insert(idx_left, ...)` ——
--     ★ idx_left 是"这个点没能放东西"的集合，随后交给 PopulateExtra。
--     所以 idx_left 的语义是"空位"，不是"失败位"。
--  5. ★★ :544 `prefab_data.data = room.contents.prefabdata and
--     backgroundRoom.contents.prefabdata[prefab] or nil`
--     ⚠ 疑似缺陷：当 perTerrain 为真（:536）时 room 是按地块选出来的，
--     这里却用 **backgroundRoom**（整体的、可能是 {地块→房间} 的表）
--     去索引 prefabdata ⇒ table 索引 table 会拿到 nil，
--     结果 prefab_data 恒为 nil。推理依据：:531 `local room = backgroundRoom`
--     在 perTerrain 时被 :537 改写，但 :544 用的仍是外层 backgroundRoom。
--  6. ★ :482 `prefabDensities[self.id] = {}` 位于 countprefabs 分支之后，
--     且 :491 的 removed 合并写在其后。★ 注意 :558 在 PopulateChildren 里
--     **又赋一次值**，会覆盖掉 PopulateVoronoi 在同一 site 上算的密度
--     （两者用同一个 self.id 作 key）⇒ 背景房间的密度会覆盖房间密度。
--     ⚠ 疑似缺陷（密度统计只用于前端/调试，影响面小）。
--  7. ★ getFilteredSpawnWeight(:10) 的 for 循环变量名叫 weightList，
--     但 :14-15 在 table 分支里读 `weightList.weight` —— ★★ 这个字段
--     在本文件里从不存在（resolveswappableprefabs:316 产出的表里
--     value 是数字不是 {weight=} 表）⇒ table 分支是**死分支**。
--  8. ★ recurseTable(:46) ⚠ 疑似缺陷：:52 `v = recurseTable(v, fn)`
--     ★ **漏传了 removed 参数**（应为 recurseTable(v, removed, fn)），
--     且返回值只接了第一个 ⇒ 递归层级里被删掉的 prefab 不会累计进 removed。
--     后果：嵌套层的 prefab 改名/停用会丢。⚠ 推理依据：:79 返回两个值，
--     :52 只接 1 个且第二个参数位置错位（fn 传给了 removed）。
--  9. ★ :54 `local add, delete = fn(k, fn)` —— ★ 把 **fn 自己**当第二个
--     参数传给了回调。回调签名是 fn(testData)（见 :86 / :91），只用第一个
--     参数 ⇒ 第二参无人读 ⇒ 无害但明显是复制粘贴残留。⚠ 疑似缺陷（无害）。
--  10. ★ :189 `if _G.WorldSim ~= nil then WorldSim:ReserveTile(...)` ——
--     WorldSim 是 C++ 注入的全局。★ 它的存在意味着这份脚本
--     **只能跑在离线 worldgen VM 里**，无法单元测试。
--============================================================
-- ★★★ Node = 一个房间 = 一个 Voronoi 胞元。本文件是散布的实现层。
require "class"
-- ★ terrain：地形过滤表。★ 本文件通过 terrain_contents_extra 与
--   传入的 spawnFn（forest_map.lua 的三个选择器）间接使用它。
require "map/terrain"
-- ★ mathutil：向量/几何工具。★ 用途有限（DistXYSq 在 storygen 用）。
require "mathutil"

-- ★ PrefabSwaps：prefab 改名/停用映射。★ 用于 §一/§二 的过滤。
local PrefabSwaps = require("prefabswaps")

-- Save characters in the save file
-- ★★ DENSITY_PRECISION = 1/10000 ——★ 密度记录的精度（万分之一）。
-- ★★ 用途：SaveEncode 之外，密度会写进 save.map.generated.densities
--   （forest_map.lua:873），供前端/调试查看「这个胞元多密」。
-- ★★ 精度选择：★ 万分之一足以看出「这格长了 37 根草」vs「0 根」，
--   ★★ 又不至于把存档撑大（每个 prefab 每个胞元一个数字）。
-- ★★ ⚠ 不一致点：:486 的 PopulateVoronoi **没有**用这个常量，
--   ★★ 而是直接 `v/#points_x`（全精度）。
--   ⇒ ★★ 只有 PopulateChildren(:560) 做了 RoundToNearest。
--     ★★ 两处精度不同 ⇒ 同一张地图里的密度记录精度不一致。⚠ 疑似缺陷（极轻微）。
local DENSITY_PRECISION = 1/10000

-- ══════════════ ★ getFilteredSpawnWeight：权重归一化 ══════════════
-- ★★ 用途：把「被 prefab 改名机制移除的 prefab」的权重，
--   ★★ **按比例分摊**回剩下的 prefab 上（见 :474-477 的调用）。
-- ★★ 场景：玩家禁用了「草」，草的权重不能凭空消失，
--   ★★ 而要按比例加到其他 prefab 上，否则总密度会下降。
local function getFilteredSpawnWeight(list,weight,prefab)
	local total = 0

-- ★★ for i,weightList in pairs(list) ——★★ pairs（顺序不定）。
--   ★★ 但本函数只求**总和**，与顺序无关。★ 这里是**安全**的。
--   ★★ ⇒ ★★ 值得与 storygen.lua 那些「按遍历顺序取第 k 个」的地方对照：
--     ★★ 只求和 ⇒ 无序无害；依赖顺序取元素 ⇒ 无序致命。
	for i,weightList in pairs(list)do
-- ★★★ ⚠ 疑似缺陷（死分支）：`if type(weightList) == "table" then`
--   ★★★ 这个分支读 `weightList.weight`。
--   ★★★ 但**唯一调用方**（:476）传入的 self.data.terrain_contents
--     .distributeprefabs 是由 resolveswappableprefabs(:316) 产出的，
--     ★★★ 而那个函数的 :322 `tbl[choice] = v.weight` 产出的是**数字**，
--       ★★★ 不是 {weight=…} 表。⇒ ★★ 这个 table 分支永不进入。
--   ⚠ 推理依据：:316-328 全文无 {weight=} 的构造。
		if type(weightList) == "table" then
-- ★★ total = total + weightList.weight ——★ 死分支里的累加。
			total = total + weightList.weight
		else
-- ★★ else 分支：普通数字权重。
			local add = true

-- ★★ for cat,catdata in pairs(PrefabSwaps.GetBasePrefabSwaps())
--   ★★ 遍历「基础 prefab 替换表」（★ 外部模块，随 DLC/季节变化）。
-- ★★★ ⚠ 性能：★ 这个**双重嵌套循环在权重列表的每个元素上都跑一遍**。
--   ★★★ 复杂度 = O(列表长度 × 替换表大小)。
--     ★★ 而 :476 在**每个 Voronoi 胞元**里对**每个被移除的 prefab** 调用本函数。
--       ★★★ ⇒ 总复杂度 = O(胞元数 × 移除数 × 列表长 × 替换表大)。
--     ★★ 实际量级：几十胞元 × 几个移除 × 几十 prefab × 几十替换 = 万级。
--       ★★ 仍在毫秒级，★ 但这是本文件最「重」的一段代码。
--     ★★★ 若世界规模变大（更多胞元），这里会先成为瓶颈。★ 记录以备移植时优化。
			for cat,catdata in pairs(PrefabSwaps.GetBasePrefabSwaps())do
				for swap,swapData in ipairs(catdata)do
-- ★★ if swapData.primary and prefab == i then add = false
--   ★★ 语义：★ 若 i 是某个替换组的「主 prefab」，它不该在基础表里出现
--     ★★ （会在后面被更具体的版本替代）。
					if swapData.primary and prefab == i then
						add = false -- remove it if the prefab is a primary, will be added in later
					end
-- ★ if add then ——★ 注意这个 if 包住了内层的 prefab2 循环。
--   ★★★ ⚠ 疑似缺陷（逻辑漏洞）：★ `if add` 一旦为 false，
--     ★★ 整个内层循环被跳过 ⇒ 提前 exit ⇒ 后面 catdata 里的
--       ★★★ **同名 alt prefab 检查不再执行**。
--     ★★★ 后果：若 prefab i 先在某组被判为 primary（add=false），
--       ★★★ 则它在后续组里的 alt 身份不会被发现 ⇒ ★★ 判定结果依赖
--         ★★★ **pairs 的遍历顺序** ⇒ 不可复现。
--   ⚠ 推理依据：:22 把 add 设为 false 后，:24 的 if 会跳过 :25-29 整段。
					if add then
						for p,prefab2 in ipairs(swapData.prefabs)do
-- ★★ if not swapData.primary and i == prefab2 then add = false
--   ★★ 语义：★ 若 i 是某个替换组的「替身」，也从基础表剔除。
--   ★★ ⇒ ★★ 最终只保留 primary（主 prefab）。原注释说得更清楚：
--     ★★ "remove all alternate prefabs, only keep the primaries."
							if not swapData.primary and i == prefab2 then
								add = false -- remove all alternate prefabs, only keep the primaries.
							end
						end
					end
				end
			end
			if add then
				--print(total ,"+",weightList,"=", total + weightList,i)
				total = total + weightList
			end
		end
	end

-- ★★ total = total + weight ——★ 把当前 prefab 自己的权重加进去。
--   ★★ 原注释：-- add the prefabs weight to the total at the end.
--   ★★ 注意它在**循环外**：★ 所以本函数是「给它一个权重，
--     ★★ 返回它在（自己 + 所有未被移除项）里的占比」。
	total = total + weight -- add the prefabs weight to the total at the end.

	--print("final weight",weight / total)
-- ★★ return weight / total ——★ 归一化后的权重。
--   ★★★ ⚠ 若 total 为 0 ⇒ **除零**！
--     ★★ 推理依据：若列表里所有 prefab 都被判为 add=false，
--       ★★★ 且 weight 本身也是 0 ⇒ total=0 ⇒ Lua 中 0/0 = nan
--         ★★★ ⇒ 返回 nan ⇒ 下游 `threshold - nan` 恒为 nan，
--           ★★★ `nan <= 0` 恒 false ⇒ ★★ weighted_random_choice
--             ★★★ 会走完整个循环返回 last_choice（兜底）。
--     ★★ 所以不崩，但结果是「随便挑一个」。★ 静默降级。
	return  weight / total --getPercentFromWeigth(list,weight)
end

-- ══════════════ ★★ recurseTable：递归改写 prefab 权重表 ══════════════
-- ★★ 作用：★ 深度遍历一张 {prefab → 权重} 表，对每个叶子键执行 fn，
--   ★★ fn 返回 (新名字, 是否删除)。
-- ★★ 消费：:99-100 的两次调用（先删未启用项，再改名）。
local function recurseTable(dataTable, removed, fn)
-- ★ deleteList：★ 要删掉的键（延后删，避免遍历中改表）。
	local deleteList = {}
-- ★ addList：★ 要新增的项 {prefab=新名, weight=原权重}。
	local addList = {}

-- ★★ for k,v in pairs(dataTable) ——★★ pairs 遍历 + :68-71 延后删除。
--   ★★★ 正确做法：★ 遍历时**不删**，先收集到 deleteList 再删。
--     ★★ 对比 network.lua:951/:966 的「遍历中直接 entities[x]=nil」，
--       ★★★ 那是**错误**的（未定义行为）。★ 这里做对了。
--       ★★ 同一个仓库里两种写法并存，★ 本文件是正面示范。
	for k,v in pairs(dataTable)do
-- ★ if type(v) == "table" then ——★ 递归分支（子表）。
		if type(v) == "table" then
-- ★★★★ 真实缺陷（⚠ 疑似缺陷，需修）：
--   v = recurseTable(v, fn)
-- ★★ 三个问题：
--   ① ★★ **漏传 removed 参数**：★ 签名是 recurseTable(dataTable, removed, fn)，
--      ★★ 这里只传了 2 个 ⇒ `removed` 收到的是 **fn**（函数对象），
--        ★★ 而 `fn` 收到的是 nil！
--   ② ★★ 于是递归调用里 :54 的 `fn(k, fn)` 变成 `nil(k, fn)` ⇒ **崩溃**。
--      ★★★ ⇒ ★★ 只要 distributeprefabs 里存在**嵌套表**，本函数必崩。
--   ③ ★★ 返回值只接了第一个 ⇒ 子层的 removed 收集全部丢失。
-- ★★★ 实际情况：★ 实践中 distributeprefabs 是**扁平表**（prefab → 数字），
--   ★★★ 所以 :51 的递归分支永不进入 ⇒ 缺陷不触发。
--   ★★★ 但这是一颗地雷：★ 一旦某个房间模板写了嵌套表（resolveswappableprefabs
--     ★★★ 确实会产生 {weight=…} 形态，见 :322 的 v.weight 读取），
--       ★★★ 就会崩。★ 正确写法应为 recurseTable(v, removed, fn)。
-- ⚠ 推理依据：:46 的签名有 3 个形参，:52 只传了 2 个。
			v = recurseTable(v, fn)
		else
-- ★★★ ⚠ 疑似缺陷（无害但是残留）：`local add, delete = fn(k, fn)`
--   ★★ 把 **fn 自己**当成第二个参数传给了回调。
--   ★★ 而两个回调（:86 / :91）的签名都是 `function(testData)`，
--     ★★ 只用第一个参数 ⇒ 第二参无人读 ⇒ **无害**。
--   ★★★ 这是典型的复制粘贴残留：★ 本意大概是 `fn(k, v)`（把值传出去）。
--   ⚠ 记录以便将来若回调要用第二个参数时不会踩坑。
			local add, delete = fn(k, fn)
-- ★ if add then ——★ 回调要改名（或新增）。
			if add then
-- ★★ table.insert(addList, {prefab=add, weight=v}) ——★ 记录改名请求。
--   ★★ 注意：**权重沿用 v** ⇒ 改名不改权重。★ 正确。
				table.insert(addList,{prefab=add,weight=v})
			end
-- ★ if delete then ——★ 回调要删除。
			if delete then
				table.insert(deleteList,k)
			end

			if not add and delete then
-- ★★ if not add and delete then removed[k] = v end
--   ★★★ 语义：★「删掉但保留权重」的项，★ 权重记进 removed。
--   ★★★ 这是**部分删除**的处理：★ 该 prefab 整体消失，
--     ★★★ 但它的权重要**分摊**给别的 prefab（:476 的 getFilteredSpawnWeight）。
--     ★★★ ⇒ ★★ 这就是「禁用一个 prefab 后地图不该变稀」的机制。
--   ★★ 设计精巧，值得学。
				removed[k] = v
			end
		end
	end

-- ★★ 延后删除 ——★ 避免「遍历中改表」的未定义行为（同 :50 的说明）。
	for k,v in ipairs(deleteList)do
		--print("REMOVING PREFAB",v)
		dataTable[v] = nil
	end

-- ★★★ 原注释解释了 addList 的真实用途：
--   -- this isn't really adding a prefab, it's replacing one that may
--      have just been removed with it's actual name. eg: ground_sticks
-- ★★ 翻译：★ 这不是「新增 prefab」，而是「把刚被移除的 prefab
--   ★★ 换回它的实际名字」。举例 ground_sticks。
-- ★★★ 即：★ 有些 prefab 名是**代理名**（如 seasonal 变体），
--   ★★★ 被移除后要换回本体名字 ⇒ 权重保留。
	-- this isn't really adding a prefab, it's replacing one that may have just been removed with it's actual name. eg: ground_sticks
	for k,v in ipairs(addList)do
		--print("ADDING PREFAB",v.prefab)
-- ★★ dataTable[v.prefab] = v.weight ——★ 写入实际名字。
		dataTable[v.prefab] = v.weight
	end

-- ★★ return dataTable, removed ——★ 两个返回值都要用（:99-100 链式接收）。
--   ★★★ 链式写法：`params, removed = recurseTable(params, removed, removeUnused)`
--     ★★ 然后 `params, removed = recurseTable(params, removed, swapToActual)`
--     ★★★ ⇒ 第二次调用**接收第一次的 removed**并继续累加。★ 正确。
	return dataTable,removed
end

-- ══════════════ ★ filterPrefabsForGlobalSwaps ══════════════
-- ★★ 两步：先删「未启用」的 prefab，再把代理名换成实际名。
-- ★★ 消费：:455（每个胞元的 PopulateVoronoi 都调）。
local function filterPrefabsForGlobalSwaps(params, removed)

	--REMOVE PREFABS NOT USED IN THIS WORLD
-- ★★ removeUnusedPrefabs(testData, fn)：★ 第二个形参 fn 无人使用（见 :54）。
	local function removeUnusedPrefabs(testData, fn)
-- ★★ return false, PrefabSwaps.IsPrefabInactive(testData)
--   ★★★ 语义：★ 不改名（add=false），★ 但「删不删」由 IsPrefabInactive 决定。
--   ★★★ 「未启用」的来源：★ 玩家在世界里没选某个 prefab，
--     ★★ 或某个 prefab 被 PrefabSwaps 标记为 inactive（★ 与季节/DLC 相关）。
--   ★★★ ⇒ ★★ 也就是说：★ 同一个房间模板，**冬天和夏天生成的地图不同**，
--     ★★★ 因为 IsPrefabInactive 的结果随 PrefabSwaps 的状态变。
--     ★★★ 这就是 DST 「季节影响世界生成」的一条隐蔽路径。
        return false, PrefabSwaps.IsPrefabInactive(testData)
	end

	--CHANGE MARKED UP PREFABS TO THEIR ACTUAL PREFAB NAME
-- ★★ swapToActualPrefabs(testData, fn)：★ 同上，第二形参未用。
	local function swapToActualPrefabs(testData, fn)
-- ★★ PrefabSwaps.ResolvePrefabProxy(testData) ——★ 代理名 → 实际名。
        local prefab = PrefabSwaps.ResolvePrefabProxy(testData)
-- ★★ if prefab ~= testData then ——★ 只有「能改名」才返回 add。
        if prefab ~= testData then
            return prefab, true
        end
        return false, false
	end

-- ★★ if type(params) == "table" then ——★ 非表直接跳过（防御）。
	if type(params) == "table" then
		params,removed = recurseTable(params, removed, removeUnusedPrefabs)
		params,removed = recurseTable(params, removed, swapToActualPrefabs)
	end

	return params, removed
end


-- ══════════════ ★★★ Node 类构造 ══════════════
-- ★★★ 本类的 data 是一大块「房间数据」，构造时不做校验、不做默认，
--   ★★★ 全部由 storygen.lua:1317-1336 组装好后传入。
-- ★★★ 关键字段速查（★ 全部来自 storygen.lua:next_room_data）：
--   type            → NODE_TYPE.*（Room/Background/Blank/Blocker…）
--   task            → 所属 task id（★ FindMainlandNodesForNewRegion 用）
--   name            → 房间名（★ GetNodesByName 按它查）
--   value           → 地面地块 ID（★ 群系地形）
--   internal_type   → 内部连接类型
--   tags            → ArrayUnion(标签展开的, task.room_tags)
--   custom_tiles / custom_objects → ★ 转成函数钩子后被清空（:131/:135）
--   terrain_contents → 房间内容物（countprefabs/distributeprefabs/…）
--   terrain_contents_extra → 标签展开出来的东西
--   terrain_filter  → ★ 整个 terrain.filter 表（★ 但 Lua 侧从不读！）
--   entrance        → 是否是入口房（★★★ 决定一切，见 :433 说明）
--   required_prefabs / SafeFromDisconnect / 随机权重
Node = Class(function(self, id, data)
-- ★ self.id：房间节点 id（如 "ForestTask:0:Forest"）。
	self.id = id
	self.graph = nil
	self.delta_graph = nil

    -- Graph properties
-- ★★★ self.edges{}：★★ **数组**（不是字典）！
--   ★★★ 这是本文件里唯一用数组存边的结构（★ 对比 Graph 的字典）。
--     ★★ 后果：★ graphedge.lua 的构造函数用 table.insert 注册边，
--       ★★ 而 network.lua:617 的 `if #node.edges == 1` 依赖它是数组。
--       ★★★ 若改成字典，MakeLoop 会静默失效。★ 隐式契约。
--     ★★ 也因为是数组，★ 遍历 node.edges 顺序稳定（插入序）。✔
    self.edges = {}

    -- Data
-- ★ self.data = data ——★★ **直接引用，不 deepcopy**。
--   ★★ ⚠ 与 Graph:AddNode（network.lua:474）同理：★ 不拷贝。
--     ★★ 而 GetRoom（storygen.lua:108）已经 deepcopy 过房间模板，
--       ★★ 所以「不拷贝」在这里其实是**安全的**。★ 靠上游兜底。
    self.data = data

    -- Search
    self.visited = false

-- ★ colour：★ 调试可视化色，缺省**半透明黄**（a=55）。
--   ★★★ 注意 a=55/255 ≈ 21% 透明度 ⇒ ★ 多个节点叠在一起也能看清边界。
--     ★★ 这是纯调试信息，但会在小地图/调试视图里显示。
    self.colour = data.colour or {r=255,g=255,b=0,a=55}


-- ★★ ents：★ 本节点要生成的实体列表。
--   ★★ ⚠ 疑似缺陷：★ 整个本文件里 self.ents **从未被使用**
--     ★★ （★ grep 核实）—— 实体实际写进的是外部传入的 entitiesOut。
--   ⚠ 残留字段。
    self.ents = nil
-- ★ populateFn / tileFn：★★ 同样是**从未被使用**的字段
--   ★★ （真正用的是 :281 SetPopulateFunction / :287 SetTilesFunction
--   ★★ 设的 custom_objects_data / custom_tiles_data）。
--   ⚠★★ 残留字段 ×2。★ 说明这里经历过一次重构且没清理干净。
    self.populateFn = nil
    self.tileFn = nil
-- ★★ populated / children_populated：★★ 两个幂等标记。
--   ★★ 防重复散布的机制：★ 同一节点被 PopulateVoronoi 调两次时跳过。
--   ★★★ 必要吗？★ network.lua:730 的 GetNodes(false) + :742 的递归
--     ★★★ 已经保证每个节点只处理一次。⇒ 这是**第二道保险**。
--     ★★ 对比 :331 的 `if self.populated == true then return end`：
--       ★★ 注意 :313 SetTilesViaFunction 也设 populated=true ⇒
--         ★★★ **跑过自定义地块的节点，其 PopulateVoronoi 会被跳过**！
--         ★★★ 这可能是有意的（自定义房间不该被通用散布污染），
--           ★★★ 但两处用同一个标记，★ 语义混淆。⚠ 疑似缺陷（设计瑕疵）。
    self.populated = false
    self.children_populated = false


-- ★★ if self.data.custom_tiles ~= nil then ——★ 房间自带「自定义地块」钩子。
--   ★★ custom_tiles = {GeneratorFunction=fn, data={…}} 形态。
--   ★★ 消费：:304 SetTilesViaFunction（forest_map.lua:563 逐节点调用）。
--   ★★★ ⇒ ★★ 机制：`custom_tiles` 会被**清空**（:133），
--       ★★★ 换成 self.custom_tiles_data。
--       ★★★ 意义：★ 把「数据字段」转成「可调用钩子」，
--         ★★★ 之后 data.custom_tiles 不再携带信息（避免被误读两次）。
    if self.data.custom_tiles ~= nil then
 		self:SetTilesFunction(self.data.custom_tiles)
    	self.data.custom_tiles = nil
    end
-- ★★ custom_objects 同理：★ 转成 populate 钩子。
--   ★★ 消费：:292 PopulateViaFunction。
--   ★★★ ⚠ 但 grep 核实：**PopulateViaFunction 从未被调用**！
--     ★★★ ⇒ ★★★ custom_objects 这条路径事实上**从未执行**。
--       ★★ 推论：★ 想让房间「自定义生成实体」的房间模板（★ 若存在）
--         ★★★ 实际上不生效。★ 死路径。
--   ⚠ 这与 network.lua:688 Populate 的三处断链是同一类问题：
--     ★★ 「上一代架构的遗留物没清理干净」。
    if self.data.custom_objects ~= nil then
 		self:SetPopulateFunction(self.data.custom_objects)
    	self.data.custom_objects = nil
    end

end)

-- ══════════════ ★★ SaveEncode：★ 房间几何序列化 ══════════════
-- ★★ 消费：network.lua:152/:173（★ 每个节点都调）。
-- ★★★ 输出的 poly（多边形）是本文件对存档体积的最大贡献。
function Node:SaveEncode(map)

-- ★★ local pos_x, pos_y = WorldSim:GetSite(self.id) ——★ 站点坐标。
--   ★★★ 这是**唯一**从 C++ 拿坐标的地方。
--     ★★★ ⇒ ★★ Voronoi 阶段（forest_map.lua:499）算出胞元后，
--       ★★★ 坐标就存在 C++ 侧，★ 本文件只是回读。
--       ★★★ ⇒ ★★ Lua 侧完全不知道 Voronoi 是怎么算的。★ 分层清晰。
	local pos_x, pos_y = WorldSim:GetSite(self.id)
-- ★★ c_x, c_y = WorldSim:GetSiteCentroid(self.id) ——★ 胞元**形心**。
--   ★★ 与 pos 的区别：★ pos 是 Voronoi 站点（= Voronoi 点的位置），
--     ★★ centroid 是胞元内采样点的算术平均。
--   ★★★ 两者可能差很多：★ 形状不规则时形心会偏移。
--     ★★★ 存档里两个都存（x/y 与 cent）⇒ 运行时各有用途：
--       ★★★ · x/y → ★ 生成位置（小地图、区域中心）
--       ★★★★ · cent → ★★ **物品摆放的参考点**（★ 关键！）
--         ★★★ · ★★ poly → ★★ 判定「某坐标是否属于本房间」
	local c_x, c_y = WorldSim:GetSiteCentroid(self.id)
-- ★★ 坐标换算：`(c - map.width/2) * TILE_SCALE`，★ 保留 2 位小数。
--   ★★★ 全项目统一的坐标约定（三处精度：
--     ★★★ · graphnode.lua:146-147 → ×100/100（2 位）
--     ★★★ · graphnode.lua:201-202 → ×100/100（2 位）
--     ★★★ · network.lua:978-979   → ×10/10（1 位）
--     ★★ · forest_map.lua:618-619 → ×100/100（2 位）
--   ★★★ ⇒ 2 位小数是主流；network.lua 的虫洞是 1 位（因为是粗略位置）。
	c_x = math.floor((c_x-map.width/2.0)*TILE_SCALE*100)/100.0
	c_y = math.floor((c_y-map.height/2.0)*TILE_SCALE*100)/100.0

-- ★★ poly_x, poly_y = WorldSim:GetSitePolygon(self.id) ——★ 胞元边界顶点。
--   ★★★★ 这是存档里**最占空间**的数据：
--     ★★ 一个 Voronoi 胞元平均 6 个顶点，每顶点 2 个坐标 ⇒ 12 个数字/节点。
--     ★★★ 2000 个节点 ⇒ 24000 个数字。★ 相当可观。
--     ★★★ 但必须存：★ 因为 100 次 Lloyd 松弛后胞元**不是规则多边形**，
--       ★★★ 无法用「中心 + 半径」还原。★ 只能存顶点。
	local poly_x, poly_y = WorldSim:GetSitePolygon(self.id)
	local poly_def = {}
	for current_pos_idx = 1, #poly_x  do
-- ★★ 每个顶点也做 ×TILE_SCALE 并 floor（★ **直接取整，无小数**）。
--   ★★★ 精度策略与坐标不同：★ 顶点只取整数。
--     ★★★ 理由：★ 顶点只用于「点在多边形内」的判定，
--       ★★★ 小数精度无意义 ⇒ 省存档空间。★ 合理的取舍。
		poly_def[current_pos_idx] = {math.floor((poly_x[current_pos_idx]-map.width/2.0)*TILE_SCALE), math.floor((poly_y[current_pos_idx]-map.height/2.0)*TILE_SCALE)}
-- ★★ ⚠ 疑似缺陷（无害）：`current_pos_idx = current_pos_idx + 1` 在循环体内。
--   ★★ for 循环自己会递增 current_pos_idx ⇒ **每轮加了两次**。
--   ★★★ 后果：★ poly_def 的**下标是 1, 3, 5, …**（奇数），
--     ★★★ 偶数下标为 nil！
--   ★★★★ ⚠ 后果很严重：★ 若运行时遍历 poly 用 ipairs，
--       ★★★ ipairs 在遇到 nil 时**提前停止** ⇒ ★★ 只会读到第 1 个顶点！
--   ⚠ 推理依据：:151 的 for 隐式递增 + :153 显式递增。
--   ★★★ 这是一个真实存在的缺陷，★ 但它可能在下游被规避
--     ★★★ （例如运行时用 for k,v in pairs(poly) 或直接用 ipairs 从 1 步进 2）。
--   ★★★ 无论如何：**存档里每个胞元的 poly 长度是实际顶点数的一半（向上取整）**。
--     ★★ 即 6 个顶点的胞元只有 {1:[x1,y1], 3:[x2,y2], 5:[x3,y3]} 三个有效项。
--   ⚠★ 这是本次审阅发现的**最隐蔽的一处缺陷**：★ 它不报错、
--     ★★ 只是让存档里的多边形「少了一半顶点」。
		current_pos_idx = current_pos_idx + 1
	end
-- ★★ 返回结构：★ 8 个字段。逐个说明：
--   x, y   → 站点坐标（整数）
--   cent   → 形心（2 位小数）
--   poly   → ★ 多边形顶点（★ 见 :153 的 ⚠ 缺一半）
--   type   → NODE_TYPE（★ 运行时据此决定渲染/碰撞）
--   c      → 颜色（★ 会被 network.lua:101 EncodeColour 换成下标）
--   area   → WorldSim:GetSiteArea（★ 胞元面积（格数））
--   tags   → ★ 标签数组（★ 运行时读它决定区块行为）
--   ★★★ 「area」是森林_map.lua:599 的面积校验（≥8 格）的数据源。
--     ★★ 而它在 SaveEncode 时就被算好了 ⇒ 校验是 O(1)。★ 设计合理。
	return {
				x = math.floor((pos_x-map.width/2.0)*TILE_SCALE),
				y = math.floor((pos_y-map.height/2.0)*TILE_SCALE),
				cent = {c_x, c_y},
				poly = poly_def,
				type = self.data.type,
				c = self.colour,
-- ★★ area = WorldSim:GetSiteArea(self.id) ——★ 胞元面积（格数）。
--   ★★★ 用途（★ 两处）：
--     ★★ ① forest_map.lua:598-599 的校验「area < 8 ⇒ 失败重试」
--     ★★ ② graphnode.lua:254/:264 的 countstaticlayouts 动态计数：
--       ★★★ `if type(count) == "function" then count = count(area, k, scratchpad)`
--       ★★★★ ⇒ ★★ 场景件数量可以**按胞元面积缩放**！
--         ★★ 大房间多放几个宝箱，小房间少放。★ 这就是 scratchpad 的用途。
				area = WorldSim:GetSiteArea(self.id),
-- ★ tags = self.data.tags ——★ 标签原样存进存档。
--   ★★★ 运行时读它做什么？（★ 可查证的行为）：
--     ★★ · components/map.lua 用它做区域的特殊处理
--     ★★ · 迷宫/竞技场（MAZE_TYPE）靠它找到节点
--     ★★★ · ★★ 运行时还可以用 TheWorld:topology 给它打标记
--       ★★★   （debugcommands.lua:1189 / caves_retrofit_land.lua:40 就是）
                tags = self.data.tags,
            }

end

-- ══════════════ 位置存取（SetPosition/GetPosition）══════════════
-- ★★★ ⚠ 疑似缺陷：★ 这两个读写 self.data.position，
--   ★★★ 但 ★★ 本文件**从不调用**，且 data.position 从未被初始化
--     ★★★ （storygen.lua:1317-1336 的 next_room_data 里没有 position）。
--   ★★ ⇒ 返回 nil。★ 纯死代码。
function Node:SetPosition(position)
	self.data.position = position
end

function Node:GetPosition()
	return self.data.position
end

-- ★★★ IsConnectedTo(node)：★ 判断本节点是否与某节点有边。
--   ★★ 消费：network.lua:601 CrosslinkRandom 判「两节点是否已相连」。
--   ★★★ 它遍历的是 **self.edges**（含 exit 边，因为 graphedge 构造时
--     ★★★ 会把 exit 边也注册到两端节点上）。
--     ★★★ ⇒ ★★ 所以它能看到跨图连接。★ 正确。
--     ★★ 对比 Graph:IsConnectedTo（network.lua:293）只看 self.edges（不含 exit）
--       ★★★ ⇒ ★★★ 两者语义不同但名字相同。⚠ 又一处同名异义。
function Node:IsConnectedTo(node)
	assert(node)

-- ★★ for k,edge in pairs(self.edges) ——★ 遍历（数组，顺序其实稳定）。
--   ★★★ 注意 self.edges 是**数组**（见 :113 的说明），
--     ★★★ 用 pairs 遍历数组是**不必要的**（ipairs 更好），
--       ★★★ 但由于数组的 pairs 顺序 = 索引序，★ 这里无碍。
	for k,edge in pairs(self.edges) do
		if edge.node1 == node or edge.node2 == node then
			return true
		end
	end

	return false
end

-- ══════════════ ★★★ PopulateWorld_AddEntity：★ 坐标换算核心 ══════════════
-- ★★ 全局函数（非方法）——★ 因为 forest_map.lua:613 的 add_fn 也要用同样的逻辑。
-- ★★★ 参数共 11 个，是本文件最复杂的签名。逐个：
--   prefab        → 要生成的 prefab 名
--   tile_x/tile_y → 格子坐标（★ 整数，来自 WorldSim:GetPointsForSite）
--   tile_value    → 该格的地块（★ 本函数**不使用**，★ 只是为兼容签名）
--   entitiesOut   → 输出实体表（★ 按 prefab 名分桶）
--   width/height  → 地图尺寸（★ 用于居中换算）
--   prefab_list   → 计数表（★ 供 :482 算密度）
--   prefab_data   → 附加数据 {data=, id=, scenario=, skinname=}
--   rand_offset   → ★ 是否加 ±0.5 格的随机偏移
function PopulateWorld_AddEntity(prefab, tile_x, tile_y, tile_value, entitiesOut, width, height, prefab_list, prefab_data, rand_offset)
-- ★★ if _G.WorldSim ~= nil then ——★★ 防御性检查。
--   ★★★ 这行暴露了一个重要事实：★ WorldSim 是 C++ 注入的全局，
--     ★★★ 而本文件**假设它存在**（:190/:239 都直接用）。
--     ★★★ ⇒ ★ 这套脚本**只能在世界生成的离线 VM 里跑**，
--       ★★★ **无法单元测试**。★ 这是可测试性的根本障碍。
--     ★★ :189 的防御只覆盖这一处，其他地方（:239/:254/…）都没有防御。
--   ★★★ ⇒ ★★ 防御是不完整的：要么全不防御，要么全防御。
--     ★★ 这里属于「半防御」状态。⚠ 疑似缺陷（一致性）。
	if _G.WorldSim ~= nil then
-- ★★ WorldSim:ReserveTile(tile_x, tile_y) ——★ 占住这格。
--   ★★★★ 这是散布的**核心副作用**：★ 占了就不能再放别的东西。
--     ★★★ ⇒ ★★ 多个 prefab 的散布是**互相排斥**的，
--       ★★★ 这保证了「一格只有一个实体」。
--     ★★★ 但注意：★ ReserveTile 只占**格子**，
--       ★★★ 而实体的**实际尺寸可能大于 1 格**（比如牛、巨石）。
--       ★★★ ⇒ ★★★ 体型大的 prefab 之间可能重叠。
--         ★★ 解决办法在别处（★ obj_layout 的空间预留，:868）。
		WorldSim:ReserveTile(tile_x, tile_y)
	end

-- ★★ local x = (tile_x - width/2.0)*TILE_SCALE ——★ 格 → 世界坐标。
--   ★★★ 这是全项目**唯一**的坐标换算公式（乘 TILE_SCALE）。
--     ★★★ TILE_SCALE = 1/FOOT（★ 常量），把「格」变成「世界单位」。
--     ★★★ · 格坐标 (0..W) → 世界坐标 (-W/2..+W/2) × TILE_SCALE
--     ★★★ 「减半」是为了让地图**以原点为中心**。
--       ★★ 这就是「出生点在地图中心」的几何基础。
	local x = (tile_x - width/2.0)*TILE_SCALE
	local y = (tile_y - height/2.0)*TILE_SCALE

-- ★★★ if rand_offset == nil or rand_offset == true then
--   ★★★ 「省略 == 传 true」——★ 一个容易踩的默认值约定。
--     ★★★ ⇒ ★ 调用方若不传第 11 个参数，会**得到随机偏移**。
--     ★★★ 而明确传 false 的调用点（forest_map.lua:613、network.lua:856、
--       ★★★ graphnode.lua:257）都拿到了**格子中心**的确定位置。
--     ★★★ ⇒ ★★ 推论：**只有 PopulateExtra(:598) 那条路径会加偏移**，
--       ★★★ 因为它没显式传 rand_offset。
--       ★★★ 这就解释了为什么本文件的注释说「散落实体的位置本身带随机性」。
	if rand_offset == nil or rand_offset == true then
-- ★★ x = x + math.random()*2-1 ——★ ±1 格的偏移。
--   ★★★ 注意是**±1 个世界单位**，不是 ±0.5 格。
--     ★★★ 因为 x 已经是世界单位（TILE_SCALE 缩放过），
--       ★★★ 所以偏移量在格尺度上看起来更小。
--     ★★★ ⇒ 效果：实体不会精确落在格子中心，而是在中心附近浮动。
--     ★★ 目的：★ 避免所有实体排成整齐的格点。★ 视觉必需。
		x = x + math.random()*2-1
		y = y + math.random()*2-1
	end

-- ★★ x = math.floor(x*100)/100.0 ——★★ 保留 2 位小数。
--   ★★★★ 为什么要取整到 2 位？★ 因为存档里存的是**字符串化的浮点**，
--     ★★★ 精度位数直接决定存档体积。
--     ★★★ 精度过高（如 15 位）会让存档膨胀几倍。
--     ★★★ ⇒ ★★ 「×100 后 floor 再 /100」是标准的「保留 N 位」技巧。
--     ★★★ 全项目一致使用（:146/:201/forest_map:618）。★ 好实践。
--   ★★★ ⚠ 副作用：★ 极小坐标会被压成 0。地图边缘附近可能出现「堆叠」。
	x = math.floor(x*100)/100.0
	y = math.floor(y*100)/100.0

-- ★★ if entitiesOut[prefab] == nil then entitiesOut[prefab] = {} end
--   ★★★ 注意：**没有 deepcopy** ⇒ 每个实体是一张独立的小表。
--     ★★★ 而 entitiesOut 的 key 是 prefab 名 ⇒ ★★ 「按 prefab 分桶」。
--       ★★★ 这个结构一路传到 save.ents（forest_map.lua:976）。
--       ★★★ 运行时读存档时也是这个结构 ⇒ 一致的 schema。
	if entitiesOut[prefab] == nil then
		entitiesOut[prefab] = {}
	end

-- ★★ local save_data = {x=x, z=y} ——★★ 注意是 **z** 不是 y！
--   ★★★ 坐标系约定：★ Lua 侧用 (x, y)，
--     ★★★ 而存档/实体侧用 **(x, z)**（3D 引擎的 xz 平面）。
--     ★★★ 这是全项目统一的约定，★ 移植时最容易踩的坑。
--     ★★★ （对照：storygen.lua 的 story_depth 数组、forest_map 的 y 变量名，
--       ★★★ 都遵循「Lua 的 y = 引擎的 z」。）
	local save_data = {x=x, z=y}
-- ★ if prefab_data then ——★ 附加数据（★ 可选）。
	if prefab_data then

-- ★★ if prefab_data.data then ——★ 实体初始化数据。
		if prefab_data.data then
-- ★★★ if type(prefab_data.data) == "function" then save_data["data"] = prefab_data.data()
--   ★★★ 「data 可以是函数」——★ 这是**惰性求值**机制：
--     ★★★ 数据只在**真的要生成这个实体时**才计算。
--     ★★★★ ⇒ ★★ 对「季节性/随机性数据」极其有用：
--       ★★ 同一个房间模板，在不同胞元里的数据可以不同（因为位置不同）。
--       ★★★ 而且 ★★ 只在用到的那些实体上求值 ⇒ 省 CPU。
--     ★★★ 这是一个很值得学的「声明式 + 惰性」组合。
			if type(prefab_data.data) == "function" then
				save_data["data"] = prefab_data.data()
			else
				save_data["data"] = prefab_data.data
			end
		end
		if prefab_data.id then
			save_data["id"] = prefab_data.id
		end
		if prefab_data.scenario then
			save_data["scenario"] = prefab_data.scenario
		end
-- ★ if prefab_data.skinname then ——★ 皮肤名（★ 「换皮」功能的载体）。
--   ★★★ 与 network.lua:936 ResolveCustomizationPrefabs 呼应：
--     ★★★ 生成期用代理 prefab + skinname，★ 最后统一换成真 prefab。
        if prefab_data.skinname then
            save_data["skinname"] = prefab_data.skinname
        end
	end
-- ★★ table.insert(entitiesOut[prefab], save_data) ——★ 入桶。
	table.insert(entitiesOut[prefab], save_data)

-- ★★ prefab_list[prefab] 计数 ——★ 供 :482/:558 算密度用。
--   ★★★ prefab_list 是**本函数第 9 个参数**，由调用方创建并持有。
--     ★★★ ⇒ ★ 它是「per-site 计数」，:482 拿它算「这格放了多少 X」。
	if prefab_list[prefab] == nil then
		prefab_list[prefab] = 0
	end
	prefab_list[prefab] = prefab_list[prefab] + 1

end


-- ══════════════ ★★ AddEntity：Node 方法版（带陆地检查）══════════════
-- ★★ 与 :188 的区别只有一处：★ 先检查该格是否陆地。
-- ★★ 所有 Node 内的散布都走这个函数（★ 而不直接调 PopulateWorld_AddEntity）。
function Node:AddEntity(prefab, points_x, points_y, current_pos_idx, entitiesOut, width, height, prefab_list, prefab_data, rand_offset)
	local tile = WorldSim:GetTile(points_x[current_pos_idx], points_y[current_pos_idx])
-- ★★★ if not TileGroupManager:IsLandTile(tile) then return end
--   ★★★★ 「非陆地不放东西」——★ 本文件**最重要的一条散布约束**。
--     ★★★ ⇒ ★★ 水面/道路/人造地板上**不生成任何野外物件**。
--     ★★★ 但注意 ★★ 这只挡住了「这一格」，
--       ★★★ 没挡住「这个东西的体型是否超过可用空间」。
--     ★★★★ ⇒ ★★ 大型 prefab（牛、巨石、帐篷）的**重叠问题未被解决**。
--       ★★★ 唯一的缓解是 :190 的 ReserveTile（但它也只占 1 格）。
--       ★★★ ⇒ ★★ 玩家偶尔会看到「两棵树重叠」——★ 这就是根因。
--     ★★★ ⚠ 记录：这需要「N×N 占位」机制才能真正解决。
	if not TileGroupManager:IsLandTile(tile) then
		return
	end

	PopulateWorld_AddEntity(prefab, points_x[current_pos_idx], points_y[current_pos_idx], tile, entitiesOut, width, height, prefab_list, prefab_data, rand_offset)
end

-- ══════════════ ★★ ConvertGround：★ 静态场景件落位 ══════════════
-- ★★ 消费：network.lua:681 → forest_map.lua:843。
-- ★★ 时机：★ 在 PopulateVoronoi **之前**调用（★ 见该行注释）。
-- ★★ 差异：★ 只处理 countstaticlayouts 与 extra.static_layouts，
--   ★★ **不处理 prefab 散布**。两类内容物在这里是分开的。
function Node:ConvertGround(spawnFn, entitiesOut, width, height, world_gen_choices)
-- ★★ if not self.data.terrain_contents then return end ——★ 无内容物的房间跳过。
	if not self.data.terrain_contents then
		return
	end
	local obj_layout = require("map/object_layout")
	local prefab_list = {}

-- ★★ local area = WorldSim:GetSiteArea(self.id) ——★ 胞元面积。
--   ★★★ 用途：★ 作为 count 函数的第一参数（:264）。
	local area = WorldSim:GetSiteArea(self.id)

	-- Get the list of special items for this node
	local add_fn = {fn=function(...) self:AddEntity(...) end,args={entitiesOut=entitiesOut, width=width, height=height, rand_offset = false, debug_prefab_list=prefab_list}}

-- ★★★★ scratchpad：★★ 「countstaticlayouts 各条目之间共享的数据」。
--   ★★★ 这是一个很精巧的设计：
--     ★★★ 静态场景件的数量可以是函数 `fn(area, name, scratchpad)`，
--     ★★★ 而 scratchpad 让**后面的条目能看到前面的计算结果**。
--     ★★★★ ⇒ ★★ 例如：「先放 N 个箱子，N 由面积决定；
--       ★★★     再放 M 个陷阱，M = N × 2」——这种依赖可以实现。
--     ★★★ 而且 scratchpad 是**每次调用新建**（:259），
--       ★★★ 所以它只在**单个胞元内**共享，跨胞元不共享。
--       ★★★ ⇒ 防止「一个房间的决策影响另一个房间」。★ 正确的隔离。
--   ★★★ 对比 :359 的另一个 scratchpad（countprefabs 用）——
--     ★★★ ★★ 原注释明确说「**这个不与 countstaticlayouts 共享**」，
--       ★★★ 说明作者**有意识地**做了两次独立分配。
--       ★★★ ⇒ 这是刻意设计，不是重复代码。★ 值得肯定。
	local scratchpad = {} -- shared data between all entries in countstaticlayouts. This is not shared with countprefabs.
-- ★★★ if self.data.terrain_contents.countstaticlayouts ~= nil then
--   ★★★ 这是房间的「静态场景件计数表」：{房间模板名 → 数量}。
--     ★★★ 两个来源：
--       ★★★ ① 房间模板自己声明（map/rooms/*.lua 的 contents.countstaticlayouts）
--       ★★★ ② storygen.lua:260/293 的 InsertAdditionalSetPieces 写入
--         ★★★ （= 关卡级与任务级的 set_pieces 分配结果）
--       ★★★★ ⇒ ★★ 所以「关卡配置的宝箱」最终会走到这里落位。
--   ★★★ 数量可以是 function（★ 见 :263-264）。
	if self.data.terrain_contents.countstaticlayouts ~= nil then
		for k,count in pairs(self.data.terrain_contents.countstaticlayouts) do
            --print("STATIC LAYOUTS: adding a "..k.." to "..self.id)
-- ★★ if type(count) == "function" then count = count(area, k, scratchpad)
--   ★★★ 「数量可以是函数」——★ 世界生成的**惰性/条件化数量**机制。
--     ★★★ 用途：
--       ★★★ · 按面积缩放（大房间多放）
--       ★★★ · 按 scratchpad 依赖其他条目
--       ★★★ · 按世界状态（如「玩家关了多少东西」）
--     ★★★ 对比：★ countprefabs 的函数签名是 (area, prefab, scratchpad)，
--       ★★★ 参数名不同但**第一个是 area、第三个是 scratchpad** ⇒ 结构一致。
			if type(count) == "function" then
				count = count(area, k, scratchpad)
			end

-- ★★ for i=1, count do obj_layout.Convert(self.id, k, add_fn) end
--   ★★ obj_layout.Convert：★ 把静态布局转成实体并放置。
--     ★★★★ 它是**场景件落位的唯一实现**。
--       ★★★ · :268 循环 count 次 ⇒ 同一模板可放多次
--       ★★★ · 它内部会 ReserveAndPlaceLayout ⇒ ★★ 先占格再放
--       ★★★ ★★ 这就是「宝箱不会被草压住」的机制。
--       ★★★ ⚠ 但 bug-patterns.md E2 指出：★ 这里有
--         ★★★ `if rcx == nil then return end` 的静默失败（★ 场景件丢失）。
			for i=1, count do
				obj_layout.Convert(self.id, k, add_fn)
			end
		end
	end

-- ★★★★ if self.data.terrain_contents_extra and .static_layouts then
--   ★★★ 标签展开出来的场景件（★「STATIC」类型的 maptag，见 :1180）。
--     ★★★ 与 countstaticlayouts 的区别：
--       ★★★ · countstaticlayouts：**可计数**（可放 N 个）
--       ★★★ · extra.static_layouts：**一次性列表**（每个条目放 1 个）
--     ★★★ 两者都在这里落位，但走的是不同的循环结构。
	if self.data.terrain_contents_extra and self.data.terrain_contents_extra.static_layouts then
		for i,layout in pairs(self.data.terrain_contents_extra.static_layouts) do
			obj_layout.Convert(self.id, layout, add_fn)
		end
	end

end

-- ══════════════ 自定义钩子：四个函数 ══════════════
-- ★★ SetPopulateFunction(custom_objects_data) ——★ 注册「自定义实体生成」。
--   ★★ 构造期 :136 调用。★ ⚠ 但 PopulateViaFunction 从未被调用（见 :135）。
function Node:SetPopulateFunction(custom_objects_data)
	self.custom_objects_data = custom_objects_data
	self.populated = false
	-- Set tag to run here
end

-- ★★ SetTilesFunction(custom_tiles_data) ——★ 注册「自定义地块生成」。
--   ★★★ 这条路径**是活的**：forest_map.lua:563 的逐节点循环会调
--     ★★★ :304 SetTilesViaFunction。
--   ★★★ 所以「房间自带地形绘制」是**真正可用**的特性
--     ★★★ （竞技场迷宫、月亮遗迹的房间用它画特殊地形）。
function Node:SetTilesFunction(custom_tiles_data)
	self.custom_tiles_data = custom_tiles_data
	-- Set tag to run here
end

-- ★★★ PopulateViaFunction() ——★ 执行自定义实体生成。
--   ★★★★ ⚠★★ 死代码：★ **全项目无调用点**（★ grep 核实）。
--     ★★★ ⇒ custom_objects 这条路径**从未生效**。
--       ★★★ 对比 custom_tiles（活的）⇒ ★ 两个孪生特性只有一个能用。
--   ⚠ 与 network.lua:688 Populate 的三处断链同源：★ 架构迁移残留。
function Node:PopulateViaFunction()
	if self.custom_objects_data == nil then
		return
	end

	--print(self.id.." SetTilesViaFunction() Populate function running...")
-- ★★ data.node = self ——★★ 把节点自己挂进 data 传给用户函数。
--   ★★★★ 这是**给 mod 作者的钩子**：★ 用户的 GeneratorFunction
--     ★★★ 可以通过 data.node 拿到节点的一切（id、data、edges…）。
--     ★★★ ⇒ ★ 设计意图是「让房间能完全接管自己的生成」。
--   ★★★ ⚠ 但 :298 用的是 `data`（**全局变量**！）而不是 self.custom_objects_data.data
--     ★★★ 疑似缺陷：★ `data` 是 Lua 的全局数据加载函数名！
--       ★★★ 虽然本文件没有 require("data")，所以 data 是 nil，
--         ★★★ 会给全局 data 赋值一个房间对象 ——★ 污染全局命名空间！
--         ★★★ 而 :309 就写对了：`self.custom_objects_data.data.node = self`。
--       ★★★ ⇒ ★★ :298 少了 `self.custom_objects_data.` 前缀，
--         ★★★ 是明确的笔误（对照 :309 一看就知道）。
--         ★★★ 后果：① 污染全局 data ② 用户函数从 data 参数拿不到 node。
	data.node = self
	self.custom_objects_data.GeneratorFunction(self.id, self.custom_objects_data.data)

	self.populated = true
end

-- ★★ SetTilesViaFunction(entities, width, height) ——★★ 活路径。
--   ★★ 消费：forest_map.lua:563（在 ApplyPoisonTag 之后、编码之前）。
--   ★★★ 时机很重要：★ 此时地块已烘焙（WorldGen_Commit 已完成），
--     ★★★ 所以自定义函数可以**直接改已生成的像素**。
function Node:SetTilesViaFunction(entities, width, height)
	if self.custom_tiles_data == nil then
		return
	end

-- ★★★ self.custom_objects_data.data.node = self ——★ 写对了（对照 :298）。
--   ★★★ 注意这里用的是 custom_objects_data 而函数名是 SetTilesViaFunction
--     ★★★ 且参数是 custom_tiles_data ——★★ 等等，
--       ★★★ 这里访问的是 **custom_objects_data**，不是 custom_tiles_data！
--     ★★★★ ⚠⚠ 疑似缺陷（真实）：★ :309-312 三行全部用了
--       ★★★ `self.custom_objects_data`，而本函数应当用 `self.custom_tiles_data`。
--       ★★★ ⇒ ★★ 结果：SetTilesViaFunction 会**把 custom_tiles 的数据写进
--         ★★★ custom_objects_data**，然后从 custom_objects_data 读出来执行。
--       ★★★★ ⇒ ★★ 若一个房间**只设了 custom_tiles 没设 custom_objects**，
--         ★★★ 则 custom_objects_data 为 nil ⇒ :309 **崩溃**。
--         ★★★ 若两个都设了 ⇒ custom_tiles 永远不会被执行。
--   ⚠ 推理依据：:287 SetTilesFunction 存的是 self.custom_tiles_data，
--     ★★ 而 :309/:310/:311 读的是 self.custom_objects_data。★ 字段名不一致。
--   ★★★ 这是一个**确凿的字段名错误**，两处（:298 与 :309-311）都错，
--     ★★ 但 :309-311 三处一致地错 ⇒ 可能是复制粘贴自 SetPopulateFunction。
--   ⚠ 若竞技场/月亮房间真的用了 custom_tiles，★ 生成会崩或失效。
	self.custom_tiles_data.data.node = self
-- ★★ data.width / data.height ——★ 同样写到了错误的字段（见 :309）。
	self.custom_tiles_data.data.width = width
	self.custom_tiles_data.data.height = height
-- ★★ self.custom_objects_data.GeneratorFunction(self.id, entities, …)
--   ★★ 注意 **entities 是第 2 个参数**（用户函数可以往里写实体），
--   ★★ 且 ★ 它是**第三个参数**的位置（self.custom_objects_data, entities, data）。
--   ★★★ 对比 :299 PopulateViaFunction：
--     ★★★ `self.custom_objects_data.GeneratorFunction(self.id, self.custom_objects_data.data)`
--     ★★★ **只传了 2 个参数，没有 entities**！
--     ★★ ⇒ ★★ 两个孪生函数的**签名不一致**：
--       ★★ · tiles 版：(id, entities, data) ——★ 能生成实体
--       ★★★ · objects 版：(id, data) —— ★★ 不能生成实体，只能改 data
--   ⚠★★★ 疑似缺陷：★ 「objects」（生成实体）的版本**反而不给 entities**。
--     ★★★ 看起来是本末倒置。★ 因为这条路径是死代码（:135）所以没人发现。
	self.custom_tiles_data.GeneratorFunction(self.id, entities, self.custom_tiles_data.data)
	self.populated = true
end

-- ══════════════ ★ resolveswappableprefabs：代理名 → 真名 ══════════════
-- ★★ 作用：★ 把 {代理名 → {prefabs={…}, weight=w}} 展平成 {真名 → w}。
-- ★★ 消费：:453（在 PopulateVoronoi 的 distributeprefabs 分支里）。
local function resolveswappableprefabs(table)
	local tbl = {}

	for k,v in pairs(table) do
		if type(v) == "table" then
-- ★★ local choice = GetRandomItem(v.prefabs) ——★ 从候选里**随机挑一个**。
--   ★★★★ 这是一个**在循环里摇随机数**的地方，★ 每次调用消耗 1 次 math.random。
--     ★★★ ⇒ ★★ 它对「同种子同世界」有直接影响：
--       ★★★ 每个胞元的每个可 swap prefab 都会消耗一次。
--     ★★ 而 distributeprefabs 通常有 10~30 个可 swap 项 ⇒
--       ★★★ 单个胞元消耗 10~30 次随机数，2000 个胞元 ⇒ ★ 2~6 万次。
--     ★★★ 也就是说：★ **代理 prefab 的选择顺序本身就是不可复现的源头之一**。
--       ★★ 加之 pairs 遍历顺序不定（:319），★ 两重不可控。
			local choice = GetRandomItem(v.prefabs)
-- ★★ tbl[choice] = v.weight ——★★ 注意存的是**权重**（数字）。
--   ★★★ ⇒ ★★ 这印证了 getFilteredSpawnWeight(:14) 里那个 table 分支是死代码：
--     ★★★ 「{prefabs={…}, weight=w}」形态在展平后已消失。
			tbl[choice] = v.weight
		else
			tbl[k] = v
		end
-- ★ else 分支：不是 swap 表，直接拷贝。
	end
	return tbl
end

-- ══════════════ ★★★★ PopulateVoronoi：★ 全文件最重要的一段 ══════════════
-- ★★ 消费：network.lua:733（★ 每个节点调一次）。
-- ★★★ 「Voronoi」之名指：★ 它在**烘焙好的胞元**里按采样点散布，
--   ★★★ 采样点由 C++ 的 Voronoi/Lloyd 过程决定。
--     ★★★ ⇒ ★★ 所以「这个房间长多少草」取决于「这个胞元有多少采样点」。
--       ★★★★ 而采样点数被 **Lloyd 松弛迭代次数**（forest_map.lua:499 的 100 次）
--         ★★★★ **直接控制** ⇒ ★★ 群系大小不均 ⇒ 密度剧烈波动。
--         ★★★ 这是 E-1 报告「坑 5」的核心机制。
-- ★★★ 内部四段：
--   ① :331-357 早退与采样点获取
--   ② :360-427 countprefabs ——★ 定数摆放
--   ③ :430-445 terrain_contents_extra.prefabs ——★ 标签带来的额外实体
--   ④ :449-480 distributeprefabs + distributepercent ——★ 权重散布
--   ⑤ :482-493 密度统计
function Node:PopulateVoronoi(spawnFn, entitiesOut, width, height, world_gen_choices, prefabDensities)
-- ★★ if self.populated == true then return end ——★ 幂等保护。
--   ★★★ ⚠ 语义混淆（见 :127）：★ :313 的 SetTilesViaFunction 也设这个标记。
--     ★★★ ⇒ ★★ 跑过 custom_tiles 的节点，其 PopulateVoronoi **被跳过**。
--       ★★★ 这可能是有意的（自定义房间不该被通用散布污染），
--         ★★★ 但用同一个 boolean 表达两件事，★ 极难排查。
--   ⚠ 疑似缺陷（设计瑕疵）。
	if self.populated == true then
		--table.insert(entitiesOut[prefab], save_data)
		return
	end

-- ★★ if TileGroupManager:IsImpassableTile(self.data.value) then return end
--   ★★★ 「不可通行地块的房间不散布」。
--     ★★★ 这是**大面积丢弃**的一道：
--       ★★ · blank 房间（LOOP_BLANK_SUB、blocker_blank）—— IMPASSABLE
--       ★★ · Region Link 节点（storygen.lua:780 type=Background, value=OCEAN_COASTAL）
--       ★★★ ⇒ ★★ 这解释了为什么「地图上有些空白大块」——★ 它们本来就是空房间。
--   ★★★ 注意判据是 data.value（房间的**地块**），不是 data.type。
--     ★★★ 对比 storygen.lua:237 的 isnt_blank 用的是 type ~= "blank"。
--       ★★★ 两处判据不同 ⇒ 边界情况可能不一致。★ 轻微。
	if TileGroupManager:IsImpassableTile(self.data.value) then
		return
	end

-- ★★ if not terrain_contents or (countprefabs==nil and distributeprefabs==nil)
--   ★★★ 没有内容物的房间跳过（空白房、LINK 房）。
	if not self.data.terrain_contents or (self.data.terrain_contents.countprefabs == nil and self.data.terrain_contents.distributeprefabs == nil) then
		return
	end

-- ★★ prefab_list{}：★ 本次散布的计数表（供 :482 算密度）。
	local prefab_list = {}
-- ★★★ generate_these{}：★「还要放多少个」的清单（prefab → 剩余数量）。
--   ★★★ 它与 prefab_list 的区别：
--     ★★★ · generate_these = ★ 计划（多少个还没放）
--     ★★★ · prefab_list     = ★ 实际（放了多少个）
--     ★★★ ⇒ ★★ 两者之差就是「没放成的」，★ :403-405 会报警告。
	local generate_these = {}
-- ★★ pos_needed = 0：★ 总共需要多少个位置。
	local pos_needed = 0

-- ★★★★ points_x, points_y, points_type = WorldSim:GetPointsForSite(self.id)
--   ★★★★ 全文件最关键的一行。
--     ★★★ 三个返回值的含义：
--       ★★ points_x / points_y → 这个胞元里**可用的采样点格子坐标**
--       ★★★ points_type        → ★ 每个点所在的**地块类型**
--         ★★★ 它是 biome 约束的载体：★ :378/:459 用它选 prefab，
--           ★★★ ★★ 同一个 prefab 只会长在该 prefab「允许」的地块上
--             ★★★ （通过 terrain.filter，见 forest_map.lua:25/65）。
--     ★★★★ 「散布的单位是采样点而不是格子」——★ 这是本文件的性能基石。
--       ★★★ 一个 100 格的胞元可能只有 20 个采样点 ⇒
--         ★★★ 散布循环跑 20 次而不是 100 次。
--       ★★★ 而采样点密度由 Lloyd 松弛控制 ⇒ 生成期与散布期耦合。
	local points_x, points_y, points_type = WorldSim:GetPointsForSite(self.id)
-- ★★ if #points_x == 0 then ——★ 胞元里一个采样点都没有。
--   ★★★ print + return ——★ E2 缺陷的形态之一：**静默放弃整个节点**。
--     ★★★ 推理：这个胞元可能是被后续处理（如 ForceConnectivity 挖掉）
--       ★★★ 弄成空地的。★ 此时什么都不放是合理的。
--       ★★ 但只有一行 print，★ 无统计、无告警等级。
	if #points_x == 0 then
-- ★★ print(self.id.." Cant process points") ——★ 仅日志。
		print(self.id.." Cant process points")
		return
	end
-- ★★ current_pos_idx = 1：★ 顺序放置的游标（从数组头往后取点）。
	local current_pos_idx = 1

	--print("Number of points returned: " .. tostring(#points_x) .. " for site " .. self.id)

-- ★★★★ local area = #points_x ——★★ 注意这里的「面积」是**采样点数**，
--   ★★★ 而不是真正的格子面积（那个是 :162 的 WorldSim:GetSiteArea）。
--     ★★★ 两处同名不同义，★ 极易混淆：
--       ★★ · :162 area（graphnode.lua）= WorldSim:GetSiteArea = **真实格数**
--       ★★★ · :357 area（graphnode.lua）= #points_x = **采样点数**
--     ★★ 而 :264（ConvertGround）传给 count 的是 :254 的真实面积，
--       ★★★ :363（PopulateVoronoi）传给 count 的是 :357 的采样点数。
--       ★★★ ⇒ ★★ 「静态场景件按真实面积缩放，散布 prefab 按采样点缩放」
--         ★★★ ——★ 两套不同的量纲。★ 设计如此，但极易读错。
	local area = #points_x

-- ★★ scratchpad{}：★ countprefabs 专用（★ 与 :259 的不共享）。
--   ★★★ 原注释明确："shared data between all entries in countprefabs.
--     This is not shared with countstaticlayouts." ★ 刻意隔离。
	local scratchpad = {} -- shared data between all entries in countprefabs. This is not shared with countstaticlayouts.
-- ★★★★ if self.data.terrain_contents.countprefabs ~= nil then
--   ★★★ 「定数摆放」：★ 明确指定「这个房间恰好有 N 个 X」。
--     ★★★ 典型内容（★ storygen.lua:954-962 的 START 节点）：
--       ★★ spawnpoint=1（出生点）, sapling=1, twiggytree=1, flint=1,
--       ★★ berrybush=1, berrybush_juicy=0.5, grass=function() return 2+math.random(2) end
--     ★★★★ 注意 ★★ 数量可以是**小数**（0.5）★！
--       ★★★ ⇒ :367 `pos_needed = pos_needed + count` 允许小数，
--         ★★★ 而 :369 `math.floor(pos_needed)` 会在检查时向下取整。
--       ★★★ 后果：★ 「0.5 个浆果丛」= 「50% 概率放 1 个」，
--         ★★★★ 但**它不是这么实现的**——★ :408 `for id = 1, count do`
--           ★★★★ 对 count=0.5 会执行 **0 次**（1 > 0.5 为假）！
--         ★★★ ⇒ ★★ **小数数量 ⇒ 永远放 0 个**。★ 这是一个真实的行为差异。
--         ★★★ ⚠ START 节点的 berrybush_juicy=0.5 因此**永远不生成**！
--       ★★ 这是「设计意图（概率）」与「实现（整数循环）」的语义错配。
--   ⚠⚠ 疑似缺陷（真实，且影响玩家可见内容）。
	if self.data.terrain_contents.countprefabs ~= nil then
		for prefab, count in pairs(self.data.terrain_contents.countprefabs) do
-- ★★ if type(count) == "function" then count = count(area, prefab, scratchpad) end
--   ★★★ 与 :263 的 countstaticlayouts 版本同构。
--     ★★★ 注意第一个参数是 **:357 的采样点数**（不是真实面积，见 :357 注释）。
			if type(count) == "function" then
				count = count(area, prefab, scratchpad)
			end
-- ★★ generate_these[prefab] = count ——★ 登记计划量。
			generate_these[prefab] = count
-- ★★ pos_needed = pos_needed + count ——★ 累加总需求。
--   ★★★ 注意 count 可能是**小数**（见 :360 的注释）⇒ pos_needed 可能是小数。
			pos_needed = pos_needed + count
		end

-- ★★★★ 【E2 缺陷现场之一】`if #points_x < math.floor(pos_needed) then
--   ★★★ 「点位不够 ⇒ **整个节点的所有 prefab 一个都不放**」+ 一行 print。
--     ★★★★ 这是 bug-patterns.md **E2** 的确切现场，行号：**graphnode.lua:369-372**。
--     ★★★ 后果：★ 一个本该有 20 只蜘蛛巢的蛛巢区，可能**一只都没有**。
--     ★★★★ 而唯一的痕迹是一行 print，★ 不进任何统计表。
--     ★★★ ⇒ ★★ 玩家投诉「地图上没有 XX」、开发者复现不了 ——★ 就是这里。
--     ★★★ 修复方向：★ 至少放得下的部分（部分投放），
--       ★★ 并把丢弃量记进统计（E2 建议的 stats.silent_drops）。
--   ★★ 注意 math.floor：★ 小数 pos_needed 会被向下取整，
--     ★★ 所以 2.5 个需求只需 2 个点位就算够。★ 略微宽松。
		if #points_x < math.floor(pos_needed) then
-- ★★ print(self.id.." Didnt get enough points for all prefabs, got "…)
			print(self.id.." Didnt get enough points for all prefabs, got "..#points_x .." need ".. pos_needed)
			return
		end

-- ★★★★ countprefabs_uses_filters 分支：★ 按地块过滤地投放。
--   ★★★ 这是一个**可选优化**：★ 只有声明了这个标志的房间才走
--     ★★★ 「挑一个适合当前地块的 prefab」的逻辑。
--     ★★★ 未声明的房间走 :407 的「顺序投放」（不管地块合不合适）。
--     ★★★ ⇒ ★★ 这是「要不要遵守地形约束」的开关。
--     ★★★ ⚠ 但即使不开这个标志，AddEntity(:240) 仍会做 IsLandTile 检查。
--       ★★★ ⇒ ★★ 不开标志的后果不是「放错地方」，而是「**放不下**」（:240 return）。
--       ★★★★ 即：★ 顺序投放时遇到非陆地格 ⇒ 该 prefab 被丢弃 ⇒
--         ★★★ 后面所有 prefab 的点位都错位（因为 current_pos_idx 照常前进）。
--         ★★★ 这是一个隐蔽但真实的行为差异。
		if self.data.terrain_contents.countprefabs_uses_filters then
-- ★★ local cur_pt = #points_x ——★ 从**尾部**开始扫（★ 不是从头部）。
--   ★★★★ 从尾部扫的设计意图：★ 让散布从胞元边缘往内填，
--     ★★ **留出中心的空地**。★ 视觉上有意义。
--   ★★★ 但与 :407 的顺序投放（从 current_pos_idx=1 正向）**方向相反**！
--     ★★★ ⇒ ★★ 同一个房间里，两类 prefab 会从**相反的方向**抢点位。
--       ★★★ 这会产生「一边稀一边密」的不对称。★ 疑似设计瑕疵。
			local cur_pt = #points_x

-- ★★ while next(generate_these) ~= nil do ——★ 直到所有 prefab 都放够。
--   ★★★ ⚠ 疑似缺陷（控制流脆弱）：★ 循环退出只靠两个条件：
--     ★★ ① generate_these 空了
--     ★★★ ② :398-400 的 `cur_pt <= 0 then break`
--     ★★★★ 若某次 pickspawncountprefabforground 返回 nil（全部候选都被地块过滤），
--       ★★★ :397 的 cur_pt 仍会 -1 ⇒ 最终 cur_pt 变 0 ⇒ break。✔ 不死循环。
--       ★★★ 但 :403-405 会打印一大堆 "could not be placed" 警告。
			while next(generate_these) ~= nil do
-- ★★ prefab = spawnFn.pickspawncountprefabforground(generate_these, points_type[cur_pt])
--   ★★★ ★★ 核心一行：**按当前点的地块类型，从待放清单里挑一个合适的**。
--     ★★★ spawnFn 来自 forest_map.lua:62-84：
--       ★★ · 把 terrain.filter[prefab] 里含当前地块的候选**剔除**
--       ★★ · 再从剩下的里**随机挑一个**
--     ★★★★ ⇒ ★★ 这是「生物群系约束」在生成期的**唯一执行点**。
--       ★★★ 而 terrain.filter（map/terrain.lua:14）就是那张 134 行的表。
--       ★★★★ 「群系」在 DST 里 = 「地块类型」×「TERRAIN_FILTER 规则」。
--         ★★★ 改那张表 ⇒ 直接改变所有群系的植被分布。
				local prefab = spawnFn.pickspawncountprefabforground(generate_these, points_type[cur_pt])
-- ★★ if prefab ~= nil then ——★ 挑到了合法 prefab。
				if prefab ~= nil then
-- ★★ prefab_data = {} ——★ 该 prefab 的附加数据容器。
					local prefab_data = {}
-- ★★ prefab_data.data = terrain_contents.prefabdata[prefab] or nil
--   ★★ 房间可以给特定 prefab 预设初始化数据（★ 如随机属性）。
--   ★★★ 数据来源是**房间模板**的 contents.prefabdata 表。
					prefab_data.data = self.data.terrain_contents.prefabdata and self.data.terrain_contents.prefabdata[prefab] or nil
-- ★★ self:AddEntity(prefab, points_x, points_y, cur_pt, …)
--   ★★ 注意传的是 cur_pt（★ 而非常量索引）⇒ 每次都取不同的点。
					self:AddEntity(prefab, points_x, points_y, cur_pt, entitiesOut, width, height, prefab_list, prefab_data)

-- ★★ generate_these[prefab] = generate_these[prefab] - 1 ——★ 减库存。
					generate_these[prefab] = generate_these[prefab] - 1
-- ★★ if generate_these[prefab] == 0 then generate_these[prefab] = nil end
--   ★★★ 用 nil 而非 0 来移除 ——★ 这样 next(generate_these) 才会认为该键没了。
--     ★★★ 若留 0，循环会**死转**（0 永远不为 nil）。★ 正确。
					if generate_these[prefab] == 0 then
						generate_these[prefab] = nil
					end

-- ★★★★ table.remove(points_x, cur_pt) 等三行 ——★★ 原地删点。
--   ★★★★ 这是「已用的点从池子里移除」，★ 保证不会重复使用同一格。
--     ★★★ ⚠ 疑似缺陷（同步问题，逻辑上自洽但极难读）：
--       ★★★ table.remove 把 cur_pt 之后的元素左移，
--       ★★★ 但 :397 的 cur_pt = cur_pt - 1 也在递减 ⇒
--       ★★★★ ⇒ 效果是「**从尾部往前逐个扫并原地删**」，
--         ★★★ 逻辑上正确（每次删的都是当前末尾区），
--         ★★★ 但 ★★ 「cur_pt 与 #points_x 不同步」这件事
--           ★★★★ 任何人改动这段都会立刻踩坑。
--       ★★★ ⇒ 代码正确但可读性极差。★ 属于「能跑但脆弱」。
--     ★★★ 三条数组（x/y/type）必须**同步删除**——★ :389-391 三行缺一不可。
					table.remove(points_x, cur_pt)
					table.remove(points_y, cur_pt)
					table.remove(points_type, cur_pt)
-- ★★ if #points_x == 0 then ——★ 点用光了。
--   ★★★★ 【E2 缺陷之二】`print(self.id.." countprefabs used all--   ★★★ the points")` + return ——★ **整个节点放弃**。
--     ★★★ 相比 :369 的检查，这里是「投放中途点用光」。
--     ★★★ ⇒ ★★ 已放的东西已经进了 entitiesOut（无法回滚），
--       ★★★ 而**没放的全部丢弃**。★ 部分成功 + 静默。
					if #points_x == 0 then
						print(self.id.." countprefabs used all the points")
						return
					end
				end
-- ★★ cur_pt = cur_pt - 1 ——★ 向胞元内侧推进。
				cur_pt = cur_pt - 1
-- ★★ if cur_pt <= 0 then break end ——★ 扫完了。
				if cur_pt <= 0 then
					break
				end
			end

-- ★★ for p, c in pairs(generate_these) do ——★ 剩下的都是没放成的。
--   ★★★★ 这是本文件**最诚实的一处日志**：
--     ★★★ 「哪些 prefab、缺多少个、在哪个胞元」全部打印出来。
--     ★★★ ★★ 这正是 E2 建议保留的「结构化痕迹」的雏形，
--       ★★★ 但它只是 print，★ 不进统计表、★ 不影响返回码、
--         ★★★ ★★ 也不会导致世界生成失败。
--       ★★★ ⇒ ★★ 「有告警但没人看」= 等于没有。
--     ★★★ 若把它改成写进 save.map.generated.warnings，
--       ★★★ 前端就能告诉玩家「这个房间放不下 N 只蜘蛛」。
			for p, c in pairs(generate_these) do
				print ("Warning: CountPrefabs could not be placed : " .. c .. " " .. p .. " in site " .. self.id)
			end
-- ★★ else 分支：★ **顺序投放**（不按地块过滤）。
--   ★★★ 语义：按 countprefabs 的 pairs 顺序，★ 从 cur_pt=1 正向填。
--     ★★★ ⚠ 与 :374 的过滤分支**方向相反**（那边从尾往头）。
--       ★★★ ⇒ ★★ 同房间内两类 prefab 从相反方向占位（见 :375 注释）。
		else
			for prefab, count in pairs(generate_these) do
				for id = 1, count do
-- ★★ if current_pos_idx > #points_x then break end ——★ 点用完就停。
					if current_pos_idx > #points_x then
						break
					end

					local prefab_data = {}
					prefab_data.data = self.data.terrain_contents.prefabdata and self.data.terrain_contents.prefabdata[prefab] or nil
					self:AddEntity(prefab, points_x, points_y, current_pos_idx, entitiesOut, width, height, prefab_list, prefab_data)

					--print("Creating count:", current_pos_idx, self.id, prefab)

-- ★★ current_pos_idx = current_pos_idx + 1 ——★ 正向推进。
					current_pos_idx = current_pos_idx + 1
				end
-- ★★★★ 【E2 缺陷之三】`if current_pos_idx > #points_x then print(...) return end`
--   ★★★★ 「投放中途点不够 ⇒ 放弃剩余 prefab」。
--     ★★★★ 与 :392 同型，但**发生在非过滤分支**。
--     ★★★★ 注意 :421 的检查在**每个 prefab 循环之后**，
--       ★★★ 所以是「放完 A 的全部，再看还有没有点放 B」。
--     ★★★ ⇒ ★★ 若 B 没点，B 及其后的所有 prefab 全部丢失。
--   ⚠ 三处（:369 / :392 / :421）+ graphnode.lua:441 共四处静默放弃。
				if current_pos_idx > #points_x then
					print(self.id.." Didnt get enough points for all counted prefabs, bailed at "..current_pos_idx )
					return
				end
			end
		end
	end

-- ★★★ terrain_contents_extra.prefabs ——★ 「标签带来的额外实体」。
--   ★★★ 来源：storygen.lua:1190 的 `"ITEM"` 类型 maptag 展开。
--     ★★★ 与 countprefabs 的区别：★ 这些是**无条件、无数量**的，
--       ★★★ 每个条目放 1 个（:431 的 ipairs）。
	-- Loop through the tags and add any items they generate
	if self.data.terrain_contents_extra and self.data.terrain_contents_extra.prefabs and #self.data.terrain_contents_extra.prefabs > 0 then
		for i, prefab in ipairs(self.data.terrain_contents_extra.prefabs) do
			local prefabname, data = prefab, nil
-- ★★ if type(prefab) == "table" then ——★ 允许 {名字, 数据} 的二元组。
			if type(prefab) == "table" then
-- ★★ assert(#prefab == 2, "Data prefabs must have a name and data.")
--   ★★★ 好的断言：★ **精确**说明期望的数据形态。
				assert(#prefab == 2, "Data prefabs must have a name and data.")
				prefabname = prefab[1]
				data = prefab[2]
			end
			self:AddEntity(prefabname, points_x, points_y, current_pos_idx, entitiesOut, width, height, prefab_list, data)
			current_pos_idx = current_pos_idx + 1
			if current_pos_idx > #points_x then
				print(self.id.." Didnt get enough points for all extra contents, bailed at "..current_pos_idx )
				return
			end
		end
	end

-- ★★ local removed = {} ——★ 被 prefab 改名机制移除的 prefab 权重。
--   ★★★ 用途：:474-477 把它们的权重**按比例**加回剩余 prefab。
	local removed = {}

-- ★★★★ distributeprefabs + distributepercent：★ 权重散布分支。
--   ★★★★ 这是「地图看起来自然」的**主要来源**：
--     ★★★ · distributepercent（0~1）= ★ 每个点有多大概率被填上东西
--     ★★★ · distributeprefabs     = ★ 填什么（按权重）
--     ★★★★ 两级随机：★ 先判「填不填」（:458），
--       ★★★★★ 再判「填什么」（:459 的 pickspawnprefab 内部再摇一次）。
--     ★★★ 这是「稀疏但自然」的分布模型，比定数摆放更像野外。
	if self.data.terrain_contents.distributepercent and self.data.terrain_contents.distributeprefabs then

-- ★★ idx_left{}：★ 「没能放东西的点」的集合。
--   ★★★★ 语义澄清（极易误解）：★ 它是「**空位**」不是「失败位」。
--     ★★★ 这些点会在 :479 传给 PopulateExtra，
--       ★★★ 由 PopulateExtra(:590) 拿它们放「世界生成设置的加量 prefab」。
--     ★★★★ ⇒ ★★ idx_left 是「留给加量的点」，不是「被丢弃的点」。
--       ★★ 理解错了会以为「这些点废了」。
		local idx_left = {}

-- ★★ distributeprefabs = resolveswappableprefabs(...) ——★ 展平代理名。
--   ★★★ 注意 ★★ 这里重新赋值了一个**局部变量**，
--     ★★ 而 self.data.terrain_contents.distributeprefabs **不变**。
--     ★★ ⇒ ★★ 原始表保持「未展平」形态，供 :476 的 getFilteredSpawnWeight 用。
--       ★★★ 这个「两个版本并存」是刻意且必要的。
		local distributeprefabs = resolveswappableprefabs(self.data.terrain_contents.distributeprefabs)

-- ★★ distributeprefabs, removed = filterPrefabsForGlobalSwaps(...)
--   ★★★ 删掉未启用的 prefab + 代理名换真名（:82）。
--     ★★★ 这就是「玩家关掉了某资源 ⇒ 它真的不生成」的落地点。
		distributeprefabs, removed = filterPrefabsForGlobalSwaps(distributeprefabs, removed)

-- ★★ for current_pos_idx = current_pos_idx, #points_x do ——★ 继续从游标往后扫。
--   ★★★★ 注意 ★★ **重用了外层的 current_pos_idx 作为循环起点**。
--     ★★★ ⇒ ★★ countprefabs 用过的点**不会被重复使用**。★ 正确。
--     ★★★ ⚠ 但这意味着：★ 若 countprefabs 用得太多，
--       ★★★ 权重散布可用的点就少 ⇒ ★★ 「定数摆放」会**挤压散布**。
--       ★★★ 这是两条路径之间**没有配额隔离**的后果。
--     ★★★ 推论：★ 同一个房间模板，若 countprefabs 数字写大了，
--       ★★★ 地图会明显变空（distributepercent 打折）。★ 隐蔽的耦合。
		for current_pos_idx = current_pos_idx, #points_x  do
-- ★★ if math.random() < self.data.terrain_contents.distributepercent then
--   ★★★ 第一级随机：★ 「这个点填不填东西」。
--     ★★★★ 每次循环消耗 1 次 math.random()。
--       ★★★ 2000 个胞元 × 每个 50 个点 ⇒ 10 万次。
--       ★★★ ⇒ 这是全生成过程中**最大的随机消耗源**（在 Lua 侧）。
--     ★★★ ⇒ ★★★ 「同种子 = 同世界」的前提再次成立在 pairs 顺序上。
			if math.random() < self.data.terrain_contents.distributepercent then
-- ★★★ prefab = spawnFn.pickspawnprefab(distributeprefabs, points_type[idx])
--   ★★★ 第二级随机 + 地块过滤：
--     ★★★ · forest_map.lua:16-52 的实现：
--       ★★ ① 按 terrain.filter 把不合适的候选剔除（:23-37）
--       ★★ ② 求权重总和（:39-42）
--       ★★ ③ `math.random()*total` 一次抽样（:44）
--       ★★★ ④ 遍历累减命中（:45-50）
--     ★★★★ 注意 ③ 只消耗 **1 次**随机数，
--       ★★★ 而 ④ 的遍历用 pairs ⇒ ★★ 又一个顺序依赖点。
--       ★★★ ★★ 也就是说：**一次 pickspawnprefab 消耗 1 个随机数**，
--         ★★★ 但结果依赖 pairs 遍历顺序 ⇒ ★★ 双重的不可控。
--     ★★★ 若 total 为 0（全部候选被地块过滤掉）⇒ :43 不进 ⇒ 返回 nil
--       ★★★ ⇒ :464 的 else 分支把它记入 idx_left。★ 优雅降级。
				local prefab = spawnFn.pickspawnprefab(distributeprefabs, points_type[current_pos_idx])
				if prefab ~= nil then
					local prefab_data = {}
					prefab_data.data = self.data.terrain_contents.prefabdata and self.data.terrain_contents.prefabdata[prefab] or nil
					self:AddEntity(prefab, points_x, points_y, current_pos_idx, entitiesOut, width, height, prefab_list, prefab_data)
-- ★★ else ——★ prefab 为 nil ⇒ 这个点「空着」。
--   ★★★ table.insert(idx_left, current_pos_idx) ——★ 留给加量用。
				else
					table.insert(idx_left, current_pos_idx)
					--print(self.id.." prefab nil for "..current_pos_idx.. " type "..points_type[current_pos_idx])
				end
			else
			--print(self.id.."-",current_pos_idx.. " type "..points_type[current_pos_idx])
-- ★★ else ——★ 没通过 distributepercent 判定 ⇒ 也是空点。
--   ★★★ 两种「空」的原因不同（:464 地块不允许 vs :470 概率没过），
--     ★★★ 但都进 idx_left ⇒ **后续处理不区分原因**。
--     ★★★ 这是「信息在流程中被抹平」的典型例子。
				table.insert(idx_left, current_pos_idx)
			end
		end
-- ★★★ -- converts the removed prefabs to a percent of the distrubute percents
--   ★★★ 原注释有个拼写错误（distrubute），★ 但含义清晰。
--     ★★★ 语义：★ 被移除的 prefab 的权重，
--       ★★★ 要**按比例**加到剩余 prefab 上（保持总密度不变）。
		-- converts the removed prefabs to a percent of the distrubute percents
-- ★★ for prefab,v in pairs(removed) do ——★ pairs 遍历。
--   ★★★ 与 :491 同款循环，但这里改 removed 自身（:476）。
--     ★★★ ⚠ 疑似缺陷（遍历中改表）：★ :476 `removed[prefab] = …`
--       ★★★ 是在遍历 pairs(removed) 时**写同一个表**。
--       ★★★ 虽然只改已存在的键（不增删），★ 但严格说仍是未定义行为。
--       ★★★ 对比 :68-71（recurseTable 里）的正确做法（先收集后删）。
--         ★★★ ⇒ ★★ 同一个仓库两种写法，★ 本处是不严谨的那个。
--         ⚠ 实际影响：改已有键的值通常安全，★ 但不保证。
		for prefab,v in pairs(removed)do
		--	print(self.id,prefab,"percent of weight:",getFilteredSpawnWeight(self.data.terrain_contents.distributeprefabs,v,prefab),"distribute percent:", self.data.terrain_contents.distributepercent)
-- ★★ removed[prefab] = getFilteredSpawnWeight(distributeprefabs, v, prefab)
--   ★★   * self.data.terrain_contents.distributepercent
--   ★★★★ 权重分摊的算式：
--     ★★ · getFilteredSpawnWeight 返回「v 在（自己 + 剩余项）里的占比」
--     ★★ · 乘 distributepercent ⇒ 转成「实际投放概率的增量」
--     ★★★★ 于是结果在 :491-492 写进 prefabDensities，
--       ★★★★ 最终**仅用于密度统计/调试**，★ 不参与实际放置。
--     ★★★ ⚠ 换言之：★ 这段计算的目的**不是**让被移除的 prefab 复活，
--       ★★★★ 而是「在密度报告里如实记录：这些被让出来的密度归谁了」。
--       ★★★ 一个纯粹的「统计修正」，不影响生成结果。
			removed[prefab] = getFilteredSpawnWeight(self.data.terrain_contents.distributeprefabs,v,prefab) *  self.data.terrain_contents.distributepercent
		end

-- ★★★★ self:PopulateExtra(world_gen_choices, spawnFn, {...})
--   ★★★★ 把「空点」交给加量处理（★ 见 :590）。
--     ★★★ 传入的是一个**大表**（context 对象）：
--       ★★★ points_type/points_x/points_y/idx_left/entitiesOut/
--       ★★★ width/height/prefab_list
--     ★★★ 用表打包而不是 7 个位置参数 ——★ 可读性好。
--       ★★★ ⚠ 但表是**共享的**：★ PopulateExtra 内部会改 entitiesOut/prefab_list，
--         ★★★ 副作用直接可见。★ 这里是有意的（要累加计数）。
		self:PopulateExtra(world_gen_choices, spawnFn, {points_type=points_type, points_x=points_x, points_y=points_y, idx_left=idx_left, entitiesOut=entitiesOut, width=width, height=height, prefab_list=prefab_list})
	end

-- ★★ prefabDensities[self.id] = {} ——★ 本胞元的密度表。
--   ★★★★ ⚠ 疑似缺陷（覆盖）：★ :558 的 PopulateChildren **又赋值一次**
--     ★★★ 同一个键（也用 self.id）⇒ ★★ 房间密度被背景房间密度**覆盖**。
--     ★★★★ ⇒ ★★ 最终 save.map.generated.densities[self.id] 里
--       ★★★ 装的是**背景房间**的密度，不是房间自己的。
--     ★★★ 影响面：★ 只用于前端/调试展示，★ 不影响生成。
--     ★★★ ⇒ 属「调试数据不可信」类缺陷。★ 值得记录。
 	prefabDensities[self.id] ={}
-- ★★★ if self.data.terrain_contents.distributepercent then ——★ 只在有散布时统计。
 	if self.data.terrain_contents.distributepercent then
		for prefab,v in pairs(prefab_list) do
			-- convererts from actual numbers to a percentage of the distribute percent
-- ★★★ prefabDensities[self.id][prefab] = v/#points_x
--   ★★★★ 密度 = 「这个 prefab 放了多少个」/「总采样点数」。
--     ★★★ ★★ ⚠ 与 :560 的 PopulateChildren 不同：
--       ★★★ · 本行**没有** RoundToNearest(…, DENSITY_PRECISION)
--       ★★★ · :560 有
--     ★★★★ ⇒ ★★ 同一张地图里两种精度。⚠（见 :8 的注释）。
--     ★★★ 而且 ★★ 若 #points_x 为 0 ⇒ **除零**！
--       ★★★★ 推理：:349 已保证 #points_x ~= 0（否则 :350 return），
--         ★★★ 所以本行安全。★（:370/:392/:421 的 return 也保证了。）
			prefabDensities[self.id][prefab] = v/#points_x

		end
	end
-- ★★ -- merges the items removed due to prefab swaps back into the list
--   ★★★ 原注释：★ 把因 prefab 替换而移除的项合并回列表。
	-- merges the items removed due to prefab swaps back into the list
-- ★★ for prefab,v in pairs(removed) do ——★ 同 :474（又是遍历中写自己）。
	for prefab,v in pairs(removed)do
-- ★★★ prefabDensities[self.id][prefab] = v ——★ 直接写入 :476 算好的值。
--   ★★★ 位于 :482 的赋值之后 ⇒ **会覆盖**同 prefab 的真实密度。
--     ★★★ ⚠ 但如果该 prefab 已被 removed，它就不会在 :486 里出现 ⇒ 无冲突。✔
--     ★★★ ⇒ 逻辑上没问题。
		prefabDensities[self.id][prefab] = v
	end

end


-- ══════════════ ★★ PopulateChildren：★ 背景房间散布 ══════════════
-- ★★ 消费：network.lua:739（★ ⚠ 见 network.lua 注释里关于参数个数的缺陷）。
-- ★★★ 它做的事与 PopulateVoronoi 平行，★ 但对象是「本节点的子站点」。
--   ★★★★ 子站点从哪来：★ WorldSim:GetChildrenForSite(self.id)
--     ★★★★ 也就是说：★ 背景不是「胞元外剩余的空白」，
--       ★★★★ 而是**WorldSim 在 Voronoi 阶段给这个站点分配的子 Voronoi 胞元**。
--         ★★★ ⇒ ★★★ 背景也有自己独立的胞元、自己的采样点、自己的散布。
--       ★★★ 这解释了「背景房间的内容物也是 Voronoi 散布的」，
--         ★★★ 而 density 的覆盖 bug（:558 vs :482）就是在这个语境下发生的。
function Node:PopulateChildren(spawnFn, entitiesOut, width, height, backgroundRoom, perTerrain, world_gen_choices, prefabDensities)
	-- Fill in any background sites that we have generated

-- ★★ if self.children_populated == true then return end ——★ 幂等。
	if self.children_populated == true then
		return
	end
-- ★★ self.children_populated = true ——★ 标记（★ 在实际工作**之前**置位）。
	self.children_populated = true

-- ★★ local children = WorldSim:GetChildrenForSite(self.id) ——★ 子站点列表。
--   ★★★★ 这是一个**从 C++ 查询**的操作，★ 不是 Lua 侧的图结构。
--     ★★★ ⇒ ★★ 所以「背景节点」在两套体系里各有一个身份：
--       ★★★ · Lua 侧：storygen.lua:1024 AddBGNodes 加的**真实 Node**
--       ★★★ · C++ 侧：Voronoi 阶段分配的**子站点**
--       ★★★ ⇒ ★★★ ★★ 两者是否一一对应？★ 本文件不校验。
--         ★★★ 若某个背景节点因条件没被创建（C++ 侧没有对应子站点），
--           ★★★★ 那它的内容物就**永远不会散布** —— ★★ 静默丢失。
--         ★★★ ⚠ 这是「两套模型不同步」的典型风险。
	local children = WorldSim:GetChildrenForSite(self.id)

	--if not perTerrain then
		--print("Background room:", backgroundRoom)
		--dumptable(backgroundRoom, 1)
		--print("\tContents")
		--dumptable(backgroundRoom.contents,2)
	--else
		--print("Background rooms:", backgroundRoom)
		--dumptable(backgroundRoom, 1)
	--end

-- ★★★ if children ~= nil then ——★ 没有子站点就什么都不做。
	if children ~= nil then

-- ★★ for i,id in ipairs(children) do ——★★ ipairs ⇒ 顺序稳定 ✔。
--   ★★★ 这是本文件**少见的**有序遍历（对比 :319/:344/:538 的 pairs）。
		for i,id in ipairs(children) do

-- ★★ local prefab_list = {} ——★★ 每个子站点一个独立的计数表。
--   ★★★ 注意它与 PopulateVoronoi 的 prefab_list（:344）**不共享**。
--     ★★★ ⇒ ★★ 房间的计数与背景的计数是分开的。✔ 设计正确。
            local prefab_list = {}

-- ★★ points_x, points_y, points_type = WorldSim:GetPointsForSite(id)
--   ★★★ 与 :348 同款，但参数是**子站点 id**。
			local points_x, points_y, points_type = WorldSim:GetPointsForSite(id) -- minus the sites that have been taken
-- ★★ if points_x == nil then ——★★ 注意这里判 **nil** 而非 :349 的 `#points_x == 0`！
--   ★★★★ 两种判据不一致：
--     ★★ · :349（PopulateVoronoi）判 `#points_x == 0`
--     ★★ · :525（PopulateChildren）判 `points_x == nil`
--     ★★★ ⇒ ★★ 若子站点返回**空表**而非 nil，:525 不会拦，
--       ★★★ 后面 :535 的 `for 1, #points_x` 就是 0 次循环 ⇒ 无害；
--       ★★★ 但 :560 的 `v / #points_x` ⇒ **除零**！
--     ★★★★ ⇒ ★★ 这是一个真实的除零风险（虽然 loops 为 0 时 prefab_list 也空，
--       ★★★★ ⇒ :559 的 pairs 空表不执行 ⇒ 实际不崩）。
--       ★★★ 结论：**碰巧不崩**，但两处判据本该统一。⚠ 疑似缺陷（潜伏）。
			if points_x == nil then
				print(self.id.." Cant process points")
				return
			end

-- ★★ -- need to stash this incase we are on a multi-terrain ground
--   ★★★ 「多地块地面」的正式支持机制的注释。
			-- need to stash this incase we are on a multi-terrain ground
-- ★★ local room = backgroundRoom ——★★ 循环外的默认房间。
--   ★★★ perTerrain 时（:537）会被改写。★ 非 perTerrain 时一直保持整体房间。
			local room = backgroundRoom

-- ★★ local idx_left = {} ——★ 同样收集「空点」。
--   ★★★ ⇒ 与 :451 同构，★ :556 也传给 PopulateExtra。★ 结构对称。
			local idx_left = {}

-- ★★ for current_pos_idx = 1, #points_x do ——★★ 从**头部**正向扫！
--   ★★★★ 与 :457（PopulateVoronoi 的 distributeprefabs 从 current_pos_idx 起）
--     ★★★ 不同的是这里**总是从头扫**，而 :375 的过滤分支是**从尾扫**。
--     ★★★ ⇒ ★★ 同一套散布引擎有**三种扫描方向**（头/尾/游标续）。
--       ★★★ 视觉后果：★ 不同的散布路径会在胞元的不同侧留下密集区。
--         ★★★ 这是「散布不够均匀」的一个隐藏来源。★ 值得记录。
			for current_pos_idx = 1, #points_x do
-- ★★★★ perTerrain 分支：★★★ 这是「生物群系」概念的真正落地点。
--   ★★★★ 「biome with mixed tile types (caves mostly)」——★ 原注释。
--     ★★★ 语义：★ 当 background 是 {地块 → 房间名} 表时，
--       ★★★ 背景内容物要**按每个点所在的地块**分别选房间。
--     ★★★★ ⇒ ★★ 这是洞穴群系能同时有「泥地、瓷砖、蘑菇」三种背景的根本原因。
--       ★★★ 若没有 perTerrain，★ 洞穴背景只能统一用一种房间，
--         ★★★ 洞穴就会显得单调。★ 这就是「多地块群系」的全部机制。
--     ★★★ 开关在 network.lua:734-737：
--       ★★ `if type(self.data.background) == type({}) then perTerrain = true end`
--       ★★★ 即：**background 是表 ⇒ perTerrain**。★ 纯类型判定。
				if perTerrain then -- For use in biomes with mixed tile types (caves mostly)
-- ★★ room = backgroundRoom[points_type[current_pos_idx]]
--   ★★★ ★★ 按当前点的地块类型选房间。
--     ★★★★ ⚠ 疑似缺陷：★ 若该地块没有对应房间 ⇒ room = nil，
--       ★★★ 下一步 :540 `room.contents.distributepercent` ⇒ **崩溃**。
--       ★★★ 且这个崩溃点在 network.lua:738 已经预警过
--         ★★★ （GetBackgroundRoom 对不存在的房间名返回 nil）。
--       ★★★ ⇒ ★★ 「background 表里写错一个房间名 ⇒ 世界生成崩溃」。
--     ★★★ 对比 network.lua:1030 的 ForceConnected 处理：
--       ★★★ 那里有**兜底注释**（是否加 `or nil`），这里没有。
--       ★★★ ⇒ ★★ 表格式 background 的**鲁棒性比字符串格式差**。
					room = backgroundRoom[points_type[current_pos_idx]]
				end

-- ★★★ if room.contents.distributepercent and math.random() < … then
--   ★★★ 同样是「第一级随机」⇒ 每次循环消耗 1 次 math.random。
--   ★★★★ ⚠ 但 ★★ **没有 nil 检查 room**（见 :537）。
				if room.contents.distributepercent and math.random() < room.contents.distributepercent then
-- ★★★ prefab = spawnFn.pickspawnprefab(room.contents.distributeprefabs,
--   points_type[current_pos_idx])
--   ★★ 与 :459 同款（同样消耗 1 次随机数 + 依赖 pairs 顺序）。
					local prefab = spawnFn.pickspawnprefab(room.contents.distributeprefabs, points_type[current_pos_idx])
					if prefab ~= nil then
-- ★★ prefab_data = {} ——★ 同 :380。
						local prefab_data = {}
-- ★★★★ ⚠⚠ ★★ 疑似缺陷（真实，字段错误）：
--   prefab_data.data = room.contents.prefabdata and
--                      backgroundRoom.contents.prefabdata[prefab] or nil
--   ★★★★ 两个问题：
--   ① ★★ 用了 **backgroundRoom** 而不是 **room**！
--     ★★★ perTerrain 为真时 room 是 backgroundRoom[...] 的**子表**（:537），
--       ★★★ 而这里却去索引**整体的** backgroundRoom ⇒
--         ★★★ `backgroundRoom.contents` ——★ backgroundRoom 是
--           ★★★★ {地块 → 房间} 的表，**它没有 .contents 字段**！
--         ★★★★ ⇒ ★★ backgroundRoom.contents 为 nil ⇒ 整个表达式取 or nil
--           ★★★ ⇒ **prefab_data.data 恒为 nil**。
--         ★★★★ ⇒ ★★★ 背景房间的 prefabdata **完全失效**。
--     ★★★ 即使 perTerrain 为假（room == backgroundRoom），
--       ★★★ 这个写法也只是「碰巧正确」，★ 但显然是想写 room.contents。
--       ★★★ 对照 :381 与 :462 的正确写法：
--         ★★★ `prefab_data.data = self.data.terrain_contents.prefabdata and
--                self.data.terrain_contents.prefabdata[prefab] or nil`
--         ★★★ 那里用的是 self.data.terrain_contents（正确的所属）。
--   ② ★★ 还有个隐藏问题：★ `backgroundRoom.contents.prefabdata[prefab]`
--     ★★★ 若 backgroundRoom 是 {地块→房间} 表，索引 .contents 得 nil，
--       ★★★ 再索引 .prefabdata ⇒ **对 nil 索引** ⇒ 崩溃？
--       ★★★ 不崩溃，因为 `a and b` 短路：backgroundRoom.contents 为 nil
--         ★★★ ⇒ 整个 and 表达式得 nil ⇒ or nil ⇒ nil。✔ 安全但无效。
--   ⚠ 推理依据：:531 `local room = backgroundRoom`，:537 在 perTerrain 时改写 room。
						prefab_data.data = room.contents.prefabdata and backgroundRoom.contents.prefabdata[prefab] or nil
						self:AddEntity(prefab, points_x, points_y, current_pos_idx, entitiesOut, width, height, prefab_list, prefab_data)
					else
						--print(self.id.." prefab nil for "..current_pos_idx.. " type "..points_type[current_pos_idx])
						table.insert(idx_left, current_pos_idx)
					end
				else
					--print(self.id.."-",current_pos_idx.. " type "..points_type[current_pos_idx])
					table.insert(idx_left, current_pos_idx)
				end
			end

-- ★★ self:PopulateExtra(world_gen_choices, spawnFn, {…}) ——★ 同 :479。
--   ★★★ context 表的字段与 :479 一致。★ 两处同构。
			self:PopulateExtra(world_gen_choices, spawnFn, {points_type=points_type, points_x=points_x, points_y=points_y, idx_left=idx_left, entitiesOut=entitiesOut, width=width, height=height, prefab_list=prefab_list})

-- ★★★★ prefabDensities[self.id] = {} ——★★ 覆盖 :482 的同键赋值！
--   ★★★★ ⚠ 真实缺陷：★ 见 :482 的详细说明。
--     ★★★ ⇒ ★★ 保存到存档的 densities 是**背景房间**的，不是房间的。
            prefabDensities[self.id] ={}
-- ★★ for k,v in pairs(prefab_list) do ——★ 统计实际放了多少。
            for k,v in pairs(prefab_list) do
-- ★★★ prefabDensities[self.id][k] = RoundToNearest(v / #points_x, DENSITY_PRECISION)
--   ★★ 与 :486 的区别：★ 做了精度归整（见 :8 的说明）。
--   ★★★ 这里用对了常量 ⇒ ★★ 说明作者**知道**该用，只是 :486 漏了。
--     ★★★★ ⚠ 另一个隐患：★ 若 #points_x 为 0（见 :525 的 ⚠）⇒ 除零。
--       ★★★ 但 :559 的 pairs(prefab_list) 在 0 次循环后为空表 ⇒ 不执行。✔
--       ★★★ ⇒ 又是「碰巧不崩」。
                prefabDensities[self.id][k] = RoundToNearest(v / #points_x, DENSITY_PRECISION)
            end
		end
	end

end

-- ══════════════ ★★★ PopulateExtra：★ 世界生成设置的加量 ══════════════
-- ★★ 这是**玩家设置直接改变世界**的最后一道：
--   ★★ world_gen_choices（forest_map.lua:873 的 translated_prefabs）
--   ★★ 把 UI 上的「浆果丛：often」翻译成 MULTIPLY 倍数（forest_map.lua:86-104）。
-- ★★★ 于是同一种世界预设，★ 玩家的密度设置会真实改变地图。
-- ★★ 消费点：:479（房间）与 :556（背景）。
function Node:PopulateExtra(world_gen_choices, spawnFn, data)
	-- We have a bunch of unused positions that we can use.
	-- loop through anything > 'default' (ie 1)
	-- add in % more
	--print("world_gen_choices...", world_gen_choices, #idx_left)
-- ★★★★ if world_gen_choices ~= nil and #data.idx_left > 0 then
--   ★★★ 两个前提：★ 有设置（不是 default-only），★ 且有空点可填。
--     ★★★ 注意：★ **只有在 distributepercent 分支被走到时才有空点**。
--       ★★★ ⇒ ★★ 若房间没有 distributeprefabs（:449 为假），
--         ★★★★ idx_left 根本不会被创建 ⇒ **加量机制完全不生效**。
--         ★★★ ⇒ ★★ 也就是说：★ 「世界生成设置」只对**有散布配置的房间**有效。
--           ★★★★ 这是个**很隐蔽的限制**，★ 玩家调密度对某些房间完全无效。
	if world_gen_choices ~= nil and #data.idx_left >0 then

-- ★★ local amount_to_generate = {} ——★ 本次要加的数量表。
--   ★★ 语义：★「额外要放多少个」（不是总数）。
		local amount_to_generate = {}
-- ★★ for prefab,amt in pairs(world_gen_choices) ——★ pairs 遍历设置表。
		for prefab,amt in pairs(world_gen_choices) do
-- ★★ if not PrefabSwaps.IsPrefabInactive(prefab) then ——★ 二次过滤。
--   ★★★ 与 :86 的 IsPrefabInactive 是同一个判据。
--     ★★★ ⇒ ★★ 「未启用的 prefab」被挡两次（filterPrefabs + 这里）。
--       ★★★ 冗余但无害的防御。★（★ 实际上 filterPrefabs 只处理了
--         ★★★ distributeprefabs，而 world_gen_choices 是**另一张表**，
--         ★★★ 所以这里**不是**冗余，是必要的！）
			if not PrefabSwaps.IsPrefabInactive(prefab) then
-- ★★★ if type(amt) == "number" then ——★ 普通倍数（MULTIPLY 表的结果）。
--   ★★★ amt 的形态来自 forest_map.lua:267-319 TranslateWorldGenChoices：
--     ★★★ ① number = MULTIPLY[tweak] ⇒ 「1.5 倍」等
--     ★★★ ② table  = {clumpcount=N, clumpsize={a,b}} ⇒ 「成簇」形态
				if type(amt) == "number" then
-- ★★ if data.prefab_list[prefab] then ——★★ 必须已经放过至少一个。
--   ★★★★ 这是「倍数」逻辑的正确实现：
--     ★★★ · prefab_list[prefab] = 已放的数量
--     ★★ · math.floor(已放 × 倍数) - 已放 = **额外**要放的数量
--     ★★★ 例：已放 10 个，倍数 1.5 ⇒ floor(15) - 10 = 5 ⇒ 再放 5 个。
--   ★★★★ ★★ 因此「倍数 < 1」的**减少**在这里**做不到**！
--     ★★★ 因为 if data.prefab_list[prefab] 为假（一个都没放）时整个分支跳过。
--     ★★★ ⇒ ★★ 「rare（0.5 倍）」的实现不在这里，
--       ★★★ 而在 forest_map.lua:904-918 的**事后裁剪**。
--         ★★★ 两处机制必须一起看才完整：
--           ★★★ · 这里：只负责**增加**
--           ★★★ · forest_map:904：负责**减少**（shuffleArray + table.remove）
					if data.prefab_list[prefab] then
						amount_to_generate[prefab] = math.floor(data.prefab_list[prefab]*amt) - data.prefab_list[prefab]
					end
				else
-- ★★★★ else 分支（成簇形态）：★ `if amt.clumpcount > 0 and 0.25 > math.random()`
--   ★★★ 「簇」的逻辑：
--     ★★ · CLUMP 表（forest_map.lua:106-116）定义每档的簇大小上限
--     ★★ · clumpsize（:118-128）定义每簇的颗数区间
--     ★★★ 判定：★ **25% 概率**决定「这一档要成簇」，
--       ★★★★ 并且**消耗一次随机数**（且消耗在条件的后半段）。
--     ★★★ ⚠ 疑似缺陷（★★★ 真实的状态泄漏）：
--       ★★★★ `amt.clumpcount = amt.clumpcount - 1` ——★ **就地修改了入参**！
--         ★★★★ amt 是 world_gen_choices 里的**共享表**（同一张表传给所有胞元）
--         ★★★★ ⇒ ★★ 第一次调用后，所有后续胞元的 clumpcount 都少了 1！
--         ★★★★ ⇒ ★★ 簇只会在**前几个**胞元出现，之后就没了。
--       ★★★ ⚠★ 推理依据：network.lua:733 把同一个 world_gen_choices 传给每个节点，
--         ★★★ 而 forest_map.lua:873 传的是同一张 translated_prefabs。
--       ★★★ 这是一个**确凿的共享状态污染 bug**。
					if amt.clumpcount > 0 and 0.25 > math.random() then
						amt.clumpcount = amt.clumpcount - 1
-- ★★ amount_to_generate[prefab] = math.random(amt.clumpsize[1], amt.clumpsize[2])
--   ★★ 本簇的颗数（CLUMPSIZE 表，forest_map.lua:118-128）。
--   ★★★ 注意：这是**直接赋值**不是累加，★ 而 :600 的减 1 假设它是库存。
--     ★★★ ⇒ ★★ 每处理一个 prefab 都会**覆盖**上一次的值。
--       ★★★ 于是「同档多次成簇」只会保留最后一次的数量。★ 轻微。
						amount_to_generate[prefab] = math.random(amt.clumpsize[1], amt.clumpsize[2])
					end
				end
			end
		end

-- ★★ for idx = 1, #data.idx_left do ——★ 遍历所有空点。
--   ★★★ 注意：★ 与 :535 的正向扫描一致，★ 都是从头。
		for idx = 1, #data.idx_left do

			-- Choose random prefab
-- ★★★ prefab = spawnFn.pickspawnprefab(amount_to_generate, data.points_type[...])
--   ★★★ ★★ 与 :459 同款：消耗 1 次随机数 + 依赖 pairs 顺序。
--     ★★★★ ⇒ ★★ 加量路径**也**受地形过滤（因为 amount_to_generate 的键会
--       ★★★★ 被 pickspawnprefab 内部按 terrain.filter 剔除）。
--     ★★★★ 所以「世界生成设置里勾了某资源，但那个地块上放不下」是可能的。
			local prefab = spawnFn.pickspawnprefab(amount_to_generate, data.points_type[data.idx_left[idx]])

			if prefab ~= nil then
				local prefab_data = {}
-- ★★ prefab_data.data = (self.data.terrain_contents and .prefabdata and
--   .prefabdata[prefab]) or nil ——★★ 这里写对了！
--   ★★★ 三重 and 保护（防止 terrain_contents 或 prefabdata 为 nil）。
--     ★★★ 与 :381/:462 同款，但更防御。★ 正确写法。
--     ★★★ 对照 :544 的错误写法，★ 差距一目了然。
				prefab_data.data = (self.data.terrain_contents and self.data.terrain_contents.prefabdata and self.data.terrain_contents.prefabdata[prefab]) or nil
-- ★★ self:AddEntity(prefab, data.points_x, data.points_y, data.idx_left[idx], …)
--   ★★★ 注意 ★★ **没有传 rand_offset**（第 11 个参数缺省）。
--     ★★★ ⇒ ★★ 依据 :196 的约定（nil == true），★ 这里**会加随机偏移**。
--     ★★★★ ⇒ ★★ 加量放置的实体是**唯一带 ±1 随机偏移**的一类。
--       ★★★ 也就是「玩家设置加的那批东西位置会飘」。
--       ★★★ 这与「房间自己的 prefab 位置固定在格心」形成对比。
				self:AddEntity(prefab, data.points_x, data.points_y, data.idx_left[idx], data.entitiesOut, data.width, data.height, data.prefab_list, prefab_data)

-- ★★ amount_to_generate[prefab] = amount_to_generate[prefab] - 1 ——★ 减库存。
				amount_to_generate[prefab] = amount_to_generate[prefab] - 1

				-- Remove any complete items from the list
-- ★★ if amount_to_generate[prefab] <= 0 then amount_to_generate[prefab] = nil end
--   ★★★ 与 :385 同款：用 nil 移除，★ 让 :593 的 pickspawnprefab 选不到它。
--   ★★★ 注意这里是 `<= 0` 而 :385 是 `== 0`：★ 更稳健。
--     ★★ 小的正确性改进。
				if amount_to_generate[prefab] <= 0 then
					--print("Generated enough",prefab)
					amount_to_generate[prefab] = nil
				end
			end
		end
	end
-- ★★★ 全文件结束（611 行含末尾空行）。
-- ★★ 本文件的四类缺陷总结（供移植时逐条检查）：
--   ⚠ :52  recurseTable 漏传参数（嵌套表必崩，当前不触发）
--   ⚠ :54  fn(k, fn) 把函数当数据传（无害但是笔误）
--   ⚠ :14  getFilteredSpawnWeight 的 table 分支是死代码
--   ⚠ :24  if add 包裹内层循环 ⇒ 判定依赖 pairs 顺序
--   ⚠ :43  total 为 0 时除零（结果 nan，静默降级）
--   ⚠ :124/:125/:168/:172 四个从未被使用的字段（残留）
--   ⚠ :153 ★★ poly 下标奇偶错位 ⇒ 存档里的多边形少一半顶点
--   ⚠ :189 防御不完整（WorldSim 一半有检查一半没有）
--   ⚠ :292 PopulateViaFunction 无调用点 ⇒ custom_objects 路径失效
--   ⚠ :298 ★★ 用全局 data 而非 self.custom_objects_data.data（污染全局）
--   ⚠ :309-312 ★★ SetTilesViaFunction 用了 custom_objects_data（字段名错）
--   ⚠ :312/:299 孪生函数签名不一致（objects 版不给 entities）
--   ⚠ :360 ★★ countprefabs 的小数数量（0.5）永远放 0 个
--   ⚠ :369/:392/:421 ★★ 三处静默放弃（E2 缺陷现场）
--   ⚠ :375/:457/:535 三种不同的点扫描方向
--   ⚠ :474/:491 遍历中改表（写已有键，风险低）
--   ⚠ :482/:558 ★★ prefabDensities 同键覆盖 ⇒ 调试数据不可信
--   ⚠ :525/:560 子站点空表时除零（碰巧不崩）
--   ⚠ :537 ★★ perTerrain 下 backgroundRoom 无 .contents ⇒ prefabdata 失效
--   ⚠ :540 room 为 nil 时崩溃（表格式 background 写错房间名即崩）
--   ⚠ :582 ★★ 就地修改入参 clumpcount ⇒ 共享状态污染，簇只在前几格出现
--   ⚠ :584 clumpcount 覆盖而非累加（轻微）
end
