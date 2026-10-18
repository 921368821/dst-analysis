--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/map.lua
-- 模块：地图服务层 / Map 类的全局扩展（⚠️ 不是组件）
-- 职责：把「生成数据」翻译成「可否通行 / 可否建造」的空间查询服务。
--       ① 地块谓词（IsXxxAtPoint 系列，40-187 行）；
--       ② 建造合法性判定与间距计算（189-745 行，本文件算法核心）；
--       ③ 空间采样：方形螺旋找水、随机点、视觉节点归属（747-1116 行）；
--       ④ 竞技场出生点的增量扫描与四级降级搜索（1122-1449 行）；
--       ⑤ DLC 区域（WagPunk 竞技场 / Vault 金库）转发查询（1453-1569 行）。
-- 【重要纠偏】本文件【没有】世界生成落地、季节视觉刷新、洞穴地表切换、
--       资源散布、OnSave/OnLoad。全文件无 Class( ) 包装、无 AddComponentPostInit、
--       无任何 net_* 声明。地图生成见 map/storygen.lua，季节见 components/seasons.lua。
-- 【文件形态】猴补丁扩展：require "map/terrain" 引入全局 Map 类后，
--       用 function Map:Xxx(...) 直接挂方法（第 1 行 + 3-8 行是唯一的改写）。
--       唯一被改写语义的是 Map:SetTile —— 补发全局事件 "onterraform"。
-- 关键符号：SetTile, IsPassableAtPointWithPlatformRadiusBias, IsDeployPointClear,
--           IsDeployPointClear2, IsNearOther, IsNearOther2, CanDeployAtPoint,
--           CanDeployWallAtPoint, CanDeployDockAtPoint, CanDeployBridgeAtPointWithFilter,
--           IsSurroundedByWater/Land/LandNoDocks, GetNearbyOceanPointFromXZ,
--           GetNearestPlatformInDirection, FindVisualNodeAtPoint, IsInLunacyArea,
--           GetLunacyAreaModifier, StartFindingGoodArenaPoints,
--           FindBestSpawningPointForArena, IsPointInAnyVault
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：map/terrain.lua（Map 类本体 + terrain.filter 生成表）,
--           tilegroups.lua（TileGroupManager，tile 分组判定）,
--           components/placer.lua（放置流程，本文件提供判定）,
--           components/season.lua（季节；本文件不含季节逻辑）,
--           components/moonstorms.lua（经 world.net 读月爆区域）,
--           world net components wagpunk_floor_helper / vault_floor_helper（DLC 区域）
--============================================================
require "map/terrain"
--[[
-- components/map.lua —— 【重要纠偏】这不是一个「组件」
--
-- 任务书里描述它「世界生成数据落地 / 摆放地形资源 / 季节视觉刷新 / 洞穴地表切换 /
-- 资源点散布 / OnSave 序列化」—— 我逐行读完1570 行后确认：
-- 这些内容【一件都不在这份文件里】。全文件 grep不到 OnSave / OnLoad /
-- AddComponentPostInit / Class(function(self, inst)) / 任何 net_* 声明。
--
-- 【它到底是什么】
-- 这是一份「猴补丁扩展脚本」：第 1 行 require "map/terrain" 把全局 Map 类
-- 引入本地，随后用 function Map:Xxx(...) 的写法【直接往全局 Map 类上挂方法】。
-- Map 类本体在 map/terrain.lua（文件末尾 return terrain={rooms=..., filter=...}），
-- 所以本文件是「往已有类上打补丁」，不是「定义一个新类」。
-- 副作用：这些方法全局可见、无命名空间、无实例状态，谁都能 Map:CanDeployAtPoint。
--
-- 【真实职责，按代码量排序】
--   1) 地块查询谓词（第 40-187 行）—— 一组 IsXxxAtPoint(x,y,z)，
--      全部是「取tile → 问TileGroupManager」的一行包装，本身无逻辑。
--   2) 建造合法性判定（第 189-745 行）—— ★全文件真正的算法核心：
--      能不能在这里放东西。间距计算、船只/平台避让、桥/码头/墙/植物的差异规则。
--   3) 空间采样工具（第 747-1116 行）—— 螺旋找水、随机点、
--      视觉节点（visual node）查询、癫狂区判定。
--   4) 竞技场出生点搜索（第 1122-1449 行）—— ★第二核心：
--      增量式全图扫描 + 分级降级的出生点评分，Linux/海洋两套几乎逐行对称。
--   5) DLC 区域查询（第 1453-1569 行）—— WagPunk竞技场 / Vault 金库，
--      全部转发给 world.net.components.*_helper（即客户端 replica 侧）。
--
-- 【移植要点】想看懂「DST 怎么判断能不能建造」，读本文件；
-- 想看懂「地图怎么生成出来、季节怎么变」，去 map/storygen.lua 与 components/seasons.lua。
--]]

local _SetTile = Map.SetTile
-- ★ 这是全文件唯一的「行为修改」（其余都是纯新增方法）：
-- 把原 Map.SetTile 存到 _SetTile，然后重定义同名方法。
-- 为什么要这样做：原版 SetTile 只改数据，不通知任何人；这里在改完后补发
-- 全局事件 "onterraform"，让地表材质/声音/成就等订阅方能响应。
--
-- 【Lua 闭包陷阱，抄这个模式必须懂】
-- _SetTile 是「旧的 Map.SetTile 函数值」的引用，不是方法调用。
-- 调用 _SetTile(self, x, y, tile, ...) 时self 被当作第一个参数显式传入——
-- 因为 Lua 的「方法」只是「以 . 调用的函数」，没有真正的绑定语义。
-- 若写成 _SetTile(x, y, tile, ...) 会丢掉 self，直接崩。
function Map:SetTile(x, y, tile, ...)
    local original_tile = self:GetTile(x, y)
    _SetTile(self, x, y, tile, ...)
	TheWorld:PushEvent("onterraform", {x = x, y = y, original_tile = original_tile, tile = tile})
-- ⚠️ 用的是 TheWorld 而非 self（此处 self 是 Map，不是 world）。
-- 隐含前提：全局只存在一个世界。单机/专服成立；
-- 任何多世界并存的场景（如编辑器预览）这行都会指向错误的世界。
end

--NOTE: Call Map:IsVisualGroundAtPoint(x, y, z) if you want to include the overhang

--NOTE: this is the max of all entities that have custom deploy_extra_spacing
--      see EntityScript:SetDeployExtraSpacing(spacing)
local DEPLOY_EXTRA_SPACING = 0
-- 【模块级可变状态 —— 典型的「注册表最大值」模式】
-- 实体在加载时调用 RegisterDeployExtraSpacing 上报自己的额外间距，
-- 这里只保留全局最大值，判定时一次比较即可覆盖所有实体。
-- 好处：避免每次判定都遍历实体表。
-- ⚠️ 代价：只能取max、无法「注销」——实体卸载后这个值不会回落。
--   模组反复载入卸载时该值只增不减，是隐性泄漏。
-- 好在它是「安全方向」（更严格），不会导致可建造区被错误放开。
function Map:RegisterDeployExtraSpacing(spacing)
    DEPLOY_EXTRA_SPACING = math.max(spacing, DEPLOY_EXTRA_SPACING)
end

--NOTE: this merge the max of this into DEPLOY_EXTRA_SPACING
--		see EntityScript:SetDeploySmartRadius(radius)
function Map:RegisterDeploySmartRadius(radius)
-- 注意这里做了「合并」而非直接 max：
-- deploy_smart_radius 语义是「实体自身的额外外扩量」，
-- 而 DEPLOY_EXTRA_SPACING 语义是「最终间距的一半」，两者量纲不同。
-- 所以要补上 DEPLOYSPACING.LARGE / 2 换算到同一量纲后再取 max。
-- 仿写提醒：把两种不同语义的量直接混进同一个 max 是很容易埋雷的。
	DEPLOY_EXTRA_SPACING = math.max(radius + DEPLOYSPACING_RADIUS[DEPLOYSPACING.LARGE] / 2, DEPLOY_EXTRA_SPACING)
end

--NOTE: this is the max of all entities that have custom terraform_extra_spacing
--      see EntityScript:SetTerraformExtraSpacing(spacing)
local TERRAFORM_EXTRA_SPACING = 0
function Map:RegisterTerraformExtraSpacing(spacing)
    TERRAFORM_EXTRA_SPACING = math.max(spacing, TERRAFORM_EXTRA_SPACING)
end

local MAX_GROUND_TARGET_BLOCKER_RADIUS = 0
function Map:RegisterGroundTargetBlocker(radius)
    MAX_GROUND_TARGET_BLOCKER_RADIUS = math.max(radius, MAX_GROUND_TARGET_BLOCKER_RADIUS)
end

local REGISTERED_WALKABLE_PLATFORM_TAGS = TheSim:RegisterFindTags({ "walkableplatform" })
-- TheSim:RegisterFindTags 返回一个「注册句柄」，后续FindEntities_Registered
-- 传这个句柄可以跳过按字符串匹配的过滤，走引擎侧的空间索引 + 标签缓存。
-- ⚠️ 这是性能关键：GetPlatformAtPoint / 各CanDeployBoat* 都在热路径上反复调用，
--   用字符串标签表做逐实体匹配会明显拖慢建造预览的每帧判定。
local MAST_TAGS = {"mast"}

function Map:IsPassableAtPoint(x, y, z, allow_water, exclude_boats)
    return self:IsPassableAtPointWithPlatformRadiusBias(x, y, z, allow_water, exclude_boats, 0)
end

function Map:IsPassableAtPointWithPlatformRadiusBias(x, y, z, allow_water, exclude_boats, platform_radius_bias, ignore_land_overhang)
-- ★★★ IsPassableAtPointWithPlatformRadiusBias —— 全文件最重要的判定。
-- 所有「能不能在这里建造/ 站人 / 放船」的根判定都汇到这一个函数。
--
-- 【返回两个值，第二个是「为什么通过」的元信息】
--   valid_tile —— 能不能站
--   is_overhang —— 通过的原因是「站在悬崖悬空层(overhang)」而不是「站在地块上」
--
-- 【is_overhang 的用途：反作弊式地放大间距】
-- 悬空层只有约 1 格宽，若按正常间距判定，会出现「两块墙视觉上紧贴却都放下了」。
-- 因此调用方（如 CanDeployWallAtPoint 第 342 行）把它当 check_player 传下去，
-- 表示「悬空处要忽略玩家再做间距检查」——这是借metadata 传参的巧用法。
--
-- 【四层判定的短路顺序（顺序有意义）】
--  1) IsAboveGroundAtPoint：真地块（陆地，或 allow_water 时的海洋）
--  2) IsVisualGroundAtPoint：悬空层（仅当未显式要求忽略）
--  3) 若两者都不成立且不允许水 → 找可走平台（boat 等）
--  4) 都失败 → false
--
-- ⚠️ platform_radius_bias 只加在第 55 行的 FindEntities 搜索半径上，
--   不参与第 61 行的实际距离比较。也就是说 bias 只「扩大搜索范围」，
--   不「放大判定半径」——真正生效的仍是 platform_radius 本身。
    local valid_tile = self:IsAboveGroundAtPoint(x, y, z, allow_water)
    local is_overhang = false
    if not valid_tile then
        valid_tile = ((not ignore_land_overhang) and self:IsVisualGroundAtPoint(x,y,z) or false)
-- ⚠️ 陷阱：(not ignore_land_overhang) and ... or false
-- 这是 Lua 的 and/or 惯用法。此处因为末尾补了 false 做兜底，
-- 所以当 ignore_land_overhang 为 true 时表达式求值为 false（正确）；
-- 若去掉末尾的 or false，当左边为 false 时整个表达式会变成 nil，
-- 而 valid_tile = nil 在第 53 行 if not valid_tile 下虽然还能走对，
-- 但第 66 行 return valid_tile, is_overhang 的第一个返回值类型就不确定了。
-- 惯用法的通用规则：a and b or c 只有在「b 为真值且不为 false/nil」时才等价于三元。
        if valid_tile then
            is_overhang = true
        end
    end
    if not allow_water and not valid_tile then
        if not exclude_boats then
            local entities = TheSim:FindEntities_Registered(x, 0, z, TUNING.MAX_WALKABLE_PLATFORM_RADIUS + platform_radius_bias, REGISTERED_WALKABLE_PLATFORM_TAGS)
-- ⚠️ 已核实的疑似缺陷（第 55-62 行）：
-- 循环体内第 61 行是【无条件 return】，只判断了 entities 列表里的【第一个】平台。
-- 若该点附近有多个 walkableplatform（船 + 玩家脚下的船 + 别的船），
-- 只要第一个不重叠就直接 return false，不会继续检查后面的。
-- 对比第 824 行GetPlatformAtPoint 的写法：那里是 if 判断成立才 return v，
-- 会继续遍历。因此本处与GetPlatformAtPoint 语义不一致，
-- 在多平台重叠场景下可能误报「不可通行」。
-- 我已逐行核对：第 56 行 for 循环、第 61 行 return 均在循环体内，无缩进错位。
-- 之所以没炸：FindEntities_Registered 的返回顺序通常让最近的那个排在前面，
-- 但这依赖空间索引实现顺序，不是语言保证。标为「疑似」而非「确定」。
            for i, v in ipairs(entities) do
                local walkable_platform = v.components.walkableplatform
                local platform_x, platform_y, platform_z = v.Transform:GetWorldPosition()
                local distance_sq = VecUtil_LengthSq(x - platform_x, z - platform_z)
                local r = walkable_platform.platform_radius
                return distance_sq <= r * r
            end
        end
		return false
    end
	return valid_tile, is_overhang
end

function Map:IsAboveGroundAtPoint(x, y, z, allow_water)
-- 注意 allow_water == true 用的是「严格等于 true」而不是真值判断。
-- 传 1 / "yes" 都不会生效。对比第 53 行的 not allow_water（真值判断），
-- 两处语义不一致——属于「同一文件内风格不统一」，移植时容易踩。
    local tile = self:GetTileAtPoint(x, y, z)
    local valid_water_tile = (allow_water == true) and TileGroupManager:IsOceanTile(tile)
    return valid_water_tile or TileGroupManager:IsLandTile(tile)
end

function Map:IsLandTileAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return TileGroupManager:IsLandTile(tile)
end

function Map:IsLandTileNoDocksAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return TileGroupManager:IsLandTile(tile) and tile ~= WORLD_TILES.MONKEY_DOCK
end

function Map:IsOceanTileAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return TileGroupManager:IsOceanTile(tile)
end

function Map:IsInvalidTileAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return TileGroupManager:IsInvalidTile(tile)
end

function Map:IsImpassableTileAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return TileGroupManager:IsImpassableTile(tile)
end

function Map:IsTemporaryTileAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return TileGroupManager:IsTemporaryTile(tile)
end

function Map:IsOceanAtPoint(x, y, z, allow_boats)
-- IsOceanAtPoint = 海洋 tile AND 非悬空层 AND（允许船 或 该处无船）。
-- ★ 三个条件是 AND 且顺序经过设计：前两条是静态的（便宜），
--   第三条要查实体（贵），放最后可短路掉大量不合格的查询。
-- 第 107 行的 IsVisualGroundAtPoint 是必要条件：
--   悬空层下方即使是海洋 tile，人站的地方仍是「陆地」，不算在水里。
-- ⚠️ 第 108 行 GetPlatformAtPoint(x, z) 只传两个参数，靠的是该函数
--   第 825 行的实参错位兼容（见该处注释）。
    return self:IsOceanTileAtPoint(x, y, z)                             -- Location is in the ocean tile range
        and not self:IsVisualGroundAtPoint(x, y, z)                     -- Location is NOT in the world overhang space
        and (allow_boats or self:GetPlatformAtPoint(x, z) == nil)		-- The location either accepts boats, or is not the location of a boat
end

function Map:IsValidTileAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return not TileGroupManager:IsInvalidTile(tile)
end

-- Terraform tests
local TERRAFORMBLOCKER_TAGS = { "terraformblocker" }
local TERRAFORMBLOCKER_IGNORE_TAGS = { "INLIMBO" }
function Map:CanTerraformAtPoint(x, y, z)
-- 【两级过滤】先查静态免疫表 TERRAFORM_IMMUNE + 必须是陆地 tile，
-- 再查动态的 terraformblocker 实体。
-- 静态表查得快且不依赖实体系统，动态查询放后面 —— 同样是成本排序。
    local tile = self:GetTileAtPoint(x, y, z)
    if TERRAFORM_IMMUNE[tile] or not TileGroupManager:IsLandTile(tile) then
        return false
    elseif TERRAFORM_EXTRA_SPACING > 0 then
        for i, v in ipairs(TheSim:FindEntities(x, 0, z, TERRAFORM_EXTRA_SPACING, TERRAFORMBLOCKER_TAGS, TERRAFORMBLOCKER_IGNORE_TAGS)) do
-- 双层半径过滤，移植时容易漏掉第二层：
--  外层 TheSim:FindEntities 的半径用【全局最大值】TERRAFORM_EXTRA_SPACING，
--  内层第 126 行用【每个实体自己的】terraform_extra_spacing 做精确判断。
-- 为什么不能两层用同一个值：外层小了会漏掉远处那个间距很大的实体，
-- 导致该挡的地方没挡（漏判）；外层必须取全局最大来保证不漏。
-- 正确写法是「外层用最大值保证不漏、内层用各自值保证不过」。
-- 第 125 行 v.entity:IsVisible() 排除隐藏实体——隐身的东西不该挡路。
            if v.entity:IsVisible() and
                v:GetDistanceSqToPoint(x, 0, z) < v.terraform_extra_spacing * v.terraform_extra_spacing then
                return false
            end
        end
    end
    return true
end

function Map:IsTerraformingBlockedByAnObject(tile_x, tile_y)
    if TERRAFORM_EXTRA_SPACING <= 0 then return false end

    local cx, _, cz = self:GetTileCenterPoint(tile_x, tile_y)
    for _, blocker in ipairs(TheSim:FindEntities(cx, 0, cz, TERRAFORM_EXTRA_SPACING, TERRAFORMBLOCKER_TAGS, TERRAFORMBLOCKER_IGNORE_TAGS)) do
        if blocker.entity:IsVisible() and
                blocker:GetDistanceSqToPoint(cx, 0, cz) < blocker.terraform_extra_spacing * blocker.terraform_extra_spacing then
            return true
        end
    end

    return false
end

function Map:CanPlowAtPoint(x, y, z)
    if not self:CanPlantAtPoint(x, y, z) then
        return false
    elseif TERRAFORM_EXTRA_SPACING > 0 then
        for _, v in ipairs(TheSim:FindEntities(x, 0, z, TERRAFORM_EXTRA_SPACING, TERRAFORMBLOCKER_TAGS, TERRAFORMBLOCKER_IGNORE_TAGS)) do
            if v.entity:IsVisible() and
                v:GetDistanceSqToPoint(x, 0, z) < v.terraform_extra_spacing * v.terraform_extra_spacing then
                return false
            end
        end
    end
    return true
end

function Map:CanPlaceTurfAtPoint(x, y, z)
    return self:GetTileAtPoint(x, y, z) == WORLD_TILES.DIRT
end

--
function Map:CanPlantAtPoint(x, y, z)
-- GROUND_HARD 是「硬地」表：能长草但不能种庄稼的地形（石头、砖等）。
-- 判定分两级：先要陆地 tile，再要非硬地。
-- 名字里的 plant 与 farm 是两个概念，这里管的是「能不能长东西」。
    local tile = self:GetTileAtPoint(x, y, z)

    if not TileGroupManager:IsLandTile(tile) then
        return false
    end

    return not GROUND_HARD[tile]
end

local FIND_SOIL_MUST_TAGS = { "soil" }
function Map:CollapseSoilAtPoint(x, y, z)
-- ★ 巧妙的双事件分发：同一个「附近土壤」列表，按距离分成两种命运——
--   距离 < till_spacing/2 → collapsesoil（被工具翻开，等价于耕作）
--   否则                 → breaksoil（只是被破坏）
-- 一个 FindEntities + 一次遍历完成两种处理，省掉第二次空间查询。
-- 条件表达式写在 PushEvent 的参数位，读起来略绕但避免了 if 分支重复代码。
	local till_spacing = GetFarmTillSpacing()
    for i, v in ipairs(TheSim:FindEntities(x, y, z, till_spacing, FIND_SOIL_MUST_TAGS)) do
        v:PushEvent(v:GetDistanceSqToPoint(x, y, z) < till_spacing * 0.5 and "collapsesoil" or "breaksoil")
    end
end

function Map:IsFarmableSoilAtPoint(x, y, z)
    return self:GetTileAtPoint(x, y, z) == WORLD_TILES.FARMING_SOIL
end

local DEPLOY_IGNORE_TAGS = { "NOBLOCK", "player", "FX", "INLIMBO", "DECOR", "walkableplatform", "walkableperipheral", "isdead"}
-- ★ DEPLOY_IGNORE_TAGS 是全文件的语义基石：建造间距检查的【白名单式排除】。
-- 语义是「带这些标签的实体一律不参与阻挡」，而非「只有带某标签才阻挡」。
-- 每一项的含义：
--   NOBLOCK——  显式声明不阻挡（UI/逻辑占位）
--   player           —— 玩家自己不挡自己的建造
--   FX               —— 特效实体
--   INLIMBO          —— 正在加载/卸载，状态不稳定
--   DECOR            —— 装饰物（草丛等）
--   walkableplatform —— 船/平台走另外的判定通道（见第 55 行）
--   walkableperipheral—— 船的边缘可走区
--   isdead           —— 尸体
-- 下面 191-204 行都是它的浅拷贝变体：shallowcopy 后增删标签。
-- ⚠️ 这样做的原因：table.removearrayvalue / table.insert 若直接作用于原表会污染全局。
--   shallowcopy 是浅拷贝，对字符串元素数组完全够用。

local DEPLOY_IGNORE_TAGS_NOPLAYER = shallowcopy(DEPLOY_IGNORE_TAGS)
-- DEPLOY_IGNORE_TAGS_NOPLAYER：把 "player" 摘掉，剩下标签照旧。
-- 用途（第 270 行 check_player 分支）：当调用方要求「玩家也不参与阻挡」
-- （例如悬空层上的间距检查）时使用——即「保留排除项，但不再排除玩家」。
-- ⚠️ 名字容易读反：NOPLAYER 指的是「不再忽略 player」，不是「只查 player」。
table.removearrayvalue(DEPLOY_IGNORE_TAGS_NOPLAYER, "player")

local TILLSOIL_IGNORE_TAGS = shallowcopy(DEPLOY_IGNORE_TAGS)
table.insert(TILLSOIL_IGNORE_TAGS, "soil")
table.insert(TILLSOIL_IGNORE_TAGS, "merm")

local WALKABLEPERIPHERAL_DEPLOY_IGNORE_TAGS = shallowcopy(DEPLOY_IGNORE_TAGS)
table.removearrayvalue(WALKABLEPERIPHERAL_DEPLOY_IGNORE_TAGS, "walkableperipheral")

local CAST_DEPLOY_IGNORE_TAGS = shallowcopy(DEPLOY_IGNORE_TAGS)
-- CAST_DEPLOY_IGNORE_TAGS：额外排除 locomotor / _inventoryitem / allow_casting。
-- 排除 locomotor 与 _inventoryitem 的原因：法术施放时施法者自己带着物品，
-- 若参与间距判定会把自己挡住，导致「站在自己身上放不了技能」。
-- allow_casting 则是给「可被施法的靶子」开个后门。
table.insert(CAST_DEPLOY_IGNORE_TAGS, "locomotor")
table.insert(CAST_DEPLOY_IGNORE_TAGS, "_inventoryitem")
table.insert(CAST_DEPLOY_IGNORE_TAGS, "allow_casting")

local HOLE_TAGS = { "groundhole" }
local BLOCKED_ONEOF_TAGS = { "groundtargetblocker", "groundhole" }

function Map:CanTillSoilAtPoint(x, y, z, ignore_tile_type)
	return (ignore_tile_type and self:CanPlantAtPoint(x, y, z) or self:IsFarmableSoilAtPoint(x, y, z))
			and self:IsDeployPointClear(Vector3(x, y, z), nil, GetFarmTillSpacing(), nil, nil, nil, TILLSOIL_IGNORE_TAGS)
end

function Map:IsPointNearHole(pt, range)
-- 【洞的三段式判定，语义比看上去复杂】
--  1) 外径：_groundhole_outerradius（缺省用物理半径）+ rangeoverride
--  2) 内径：_groundhole_innerradius —— 洞【中心】是可以站/放东西的
--  3) 所以判据是「在外径内 且 不在内径内」才返回 true。
-- 这让「站在洞里」与「站在洞旁边」得到不同答案，是 DSt 里很典型的建模手法。
-- ⚠️ 第 217 行 hole._groundhole_rangeoverride 的拼写：
--   这里是 rangeoverride，而下一行 230 行 blocker 上也是 rangeoverride，一致。
--   但整个文件其他地方大量使用 deploy_extra_spacing 这类「无下划线分隔」风格，
--   命名不统一容易看错，读的时候以实际拼写为准。
    range = range or .5
    for _, hole in ipairs(TheSim:FindEntities(pt.x, 0, pt.z, DEPLOY_EXTRA_SPACING + range, HOLE_TAGS)) do
        local radius = (hole._groundhole_outerradius or hole:GetPhysicsRadius(0)) + (hole._groundhole_rangeoverride or range)
        local distsq = hole:GetDistanceSqToPoint(pt)
        if distsq < radius * radius then
            local hole_innerradius = hole._groundhole_innerradius
            return (hole_innerradius == nil) or (distsq >= (hole_innerradius * hole_innerradius))
        end
    end
    return false
end

function Map:IsGroundTargetBlocked(pt, range)
-- 与 IsPointNearHole 几乎同构，差别有三处：
--  1) 搜索半径取 math.max(DEPLOY_EXTRA_SPACING, MAX_GROUND_TARGET_BLOCKER_RADIUS)，
--     即两个「全局最大间距注册表」取大者——因为这里要同时容纳建造与法术阻挡。
--  2) 标签用 BLOCKED_ONEOF_TAGS（命中任一即算），而不是单一 HOLE_TAGS（必须命中）。
--  3) 距离比较强制 y=0（第 231 行），地面目标只看平面距离。
-- ⚠️ 第 230 行的 fallback 链顺序：ground_target_blocker_radius →
--   _groundhole_outerradius → GetPhysicsRadius(0)。
--   注意 GetPhysicsRadius 的参数是0（取哪个碰撞层？）而非 0.5，与第 257/290 行
--   用 GetPhysicsRadius(0.5) 形成对比——这暗示该实体的 0.5 层才是「本体」。
    range = range or .5
    for _, blocker in ipairs(TheSim:FindEntities(pt.x, 0, pt.z, math.max(DEPLOY_EXTRA_SPACING, MAX_GROUND_TARGET_BLOCKER_RADIUS) + range, nil, nil, BLOCKED_ONEOF_TAGS)) do
        local radius = (blocker.ground_target_blocker_radius or blocker._groundhole_outerradius or blocker:GetPhysicsRadius(0)) + (blocker._groundhole_rangeoverride or range)
        local distsq = blocker:GetDistanceSqToPoint(pt.x, 0, pt.z)
        if distsq < radius * radius then
            local blocker_innerradius = blocker._groundhole_innerradius
            return (blocker_innerradius == nil) or (distsq >= (blocker_innerradius * blocker_innerradius))
        end
    end
    return false
end

--V2C: keep backward compatible
--     -original: IsNearOther(other, pt, min_spacing_sq)
--     -new: -added support for deploy_smart_radius
--           -supports missing min_spacing param
local function IsNearOther(other, pt, min_spacing_sq, min_spacing)
-- ★★★ IsNearOther —— 建造间距的单体判定，全文件最需要逐字读的函数。
-- 它是一个「四级 if/elseif 优先级链」，后三者互斥（ elseif ），
-- 只有第一级（structure 特例）可以与后续逻辑共存。
--
-- 【四级优先级，从上到下】
--  1) min_spacing_sq <= 0 且对方是 structure → 用对方的 deploy_extra_spacing。
--     ★ 存在 min_spacing_sq == nil 时会崩：nil <= 0 报错。
--       实际安全的原因是第 268/277 行的契约保证min_spacing_sq 一定非 nil
--       （除非调用方显式传了 min_spacing_sq_fn，参见第 276 行）。
--  2) deploy_smart_radius → 双方半径各出一半（两个实体的间距由双方分摊）。
--  3) deploy_extra_spacing → 与原间距【取大】（max），是保守方向。
--  4) 有 inventoryitem → 用物理半径分摊，但与原间距【取小】（min）。
--
-- ★★ 第 3 级 max 与第 4 级 min 的方向相反，这是本函数最容易读错的地方：
--   3 级（自带 extra_spacing）取 max = 更严格，宁可少放；
--   4 级（普通物品）取 min = 更宽松，用物品自身半径替代默认间距。
-- 理解成「实体可以声明自己需要更大的间距（max），也可以声明自己只需要
-- 自己的物理半径就够（min）」就顺了。
--
-- 【为什么第 2 级要先加 DEPLOYSPACING_RADIUS[LARGE]/2 再取 max】
-- 见第 21-22 行 RegisterDeploySmartRadius：smart_radius 也要补上默认间距的一半，
-- 这样「默认间距」与「smart_radius」被统一折算成「单边需要让出的距离」。
    --FindEntities range check is <=, but we want <
	if min_spacing_sq <= 0 and other:HasTag("structure") then
		--special case (e.g. minisigns use DEPLOYSPACING.NONE)
		if other.deploy_extra_spacing then
			min_spacing_sq = other.deploy_extra_spacing * other.deploy_extra_spacing
		end
	elseif other.deploy_smart_radius then
		min_spacing = other.deploy_smart_radius + (min_spacing or math.sqrt(min_spacing_sq)) / 2
-- ★ math.sqrt(min_spacing_sq) 这行的 (min_spacing or ...) 兜底：
-- 新版调用方（第 277 行）只在「本次没被 fn 改过」时才传 min_spacing，
-- 否则传 nil。此时必须能从 min_spacing_sq 反推出 sqrt。
-- 去掉这个兜底 → min_spacing_sq 非 nil 但 min_spacing 为 nil 时直接崩。
-- 抄这类代码时注意：平方距离和线性距离两个参数是「成对的」，
-- 谁先谁后、能不能互相换算，都要在函数入口处想清楚。
		min_spacing_sq = min_spacing * min_spacing
	elseif other.deploy_extra_spacing then
		min_spacing_sq = math.max(other.deploy_extra_spacing * other.deploy_extra_spacing, min_spacing_sq)
	elseif other.replica.inventoryitem then
		min_spacing = other:GetPhysicsRadius(0.5) + (min_spacing or math.sqrt(min_spacing_sq)) / 2
		min_spacing_sq = math.min(min_spacing * min_spacing, min_spacing_sq)
	end
	return other:GetDistanceSqToPoint(pt) < min_spacing_sq
-- 用严格小于（<）而注释里说明 FindEntities 用的是 <=：
-- 即「刚好贴在一起」算不算冲突，官方选择【不算冲突】（贴边可以放）。
-- 这个边界语义在第 286、347 行重复出现，是本文件统一的约定。
end

function Map:IsDeployPointClear(pt, inst, min_spacing, min_spacing_sq_fn, near_other_fn, check_player, custom_ignore_tags)
-- ★★★ IsDeployPointClear —— 建造/施法间距的总入口。
--
-- 【执行顺序，每一步都有存在理由】
--  0) 第 264 行：WagPunk 竞技场结界内的绝对禁建区（先于一切，快速拒绝）
--  1) 平方化：第 268 行把 min_spacing 预先算成平方，避免循环内反复乘
--  2) 第 269 行：near_other_fn 可注入 → 【策略模式】，
--     不同建造类型替换「怎么算两个实体冲突」（墙/植物/陷阱/码头各不同）
--  3) 第 270 行：math.max(DEPLOY_EXTRA_SPACING, min_spacing) 作为搜索半径，
--     取 max 保证不漏（与CanTerraformAtPoint 同一思路）
--  4) 第 271-275 行：四重过滤，只保留「真的会挡路」的实体
--  5) 第 276-277 行：交给注入的 near_other_fn 判定具体冲突
--
-- 【第 271-274 行四重过滤，逐条都有坑】
--  v ~= inst                —— 不和自己冲突（重放建造预览时必须排除）
--  v.entity:IsVisible()     —— 隐藏的不挡
--  v.components.placer==nil—— ★ 正在拖动的「幽灵预览实体」不挡。
--    这是建造手感的关键：预览时自己脚下那个半透明模型若参与判定，
--    会造成「越拖越红」的自锁死循环。
--  GetParent()==nil or childdeployblocker
--    —— 被挂载的实体（角色身上装备）不挡，
--       但带 childdeployblocker 标签的除外（如某些必须挡路的挂件）。
--⚠️ 第 270 行的标签选择用了嵌套 and/or 三元：
--   custom_ignore_tags 优先 > check_player 时用 NOPLAYER 版 > 默认版。
--   写这么长的一行可读性很差，拆成 if/elseif 会更清楚（但行为相同）。
    if self:IsXZWithThicknessInWagPunkArenaAndBarrierIsUp(pt.x, pt.z, TUNING.WAGPUNK_ARENA_COLLISION_NOBUILD_THICKNESS) then
        return false
    end

    local min_spacing_sq = min_spacing ~= nil and min_spacing * min_spacing or nil
    near_other_fn = near_other_fn or IsNearOther
    for _, v in ipairs(TheSim:FindEntities(pt.x, 0, pt.z, math.max(DEPLOY_EXTRA_SPACING, min_spacing), nil, (custom_ignore_tags ~= nil and custom_ignore_tags) or (check_player and DEPLOY_IGNORE_TAGS_NOPLAYER) or DEPLOY_IGNORE_TAGS)) do
        if v ~= inst and
            v.entity:IsVisible() and
            v.components.placer == nil and
			(v.entity:GetParent() == nil or v:HasTag("childdeployblocker"))
		then
			local v_min_spacing_sq = min_spacing_sq_fn and min_spacing_sq_fn(v) or min_spacing_sq
			if near_other_fn(v, pt, v_min_spacing_sq, (v_min_spacing_sq == min_spacing_sq and min_spacing) or nil) then
-- ⚠️ 已核实的易错点（第 276-277 行）：
-- v_min_spacing_sq 被第 276 行的 fn 改写后，第 277 行用
-- (v_min_spacing_sq == min_spacing_sq and min_spacing) or nil 判断
-- 「这次有没有被改过」来决定是否传 min_spacing。
-- ★ 这是用【数值相等】当【脏标记（dirty flag）】用。
--   若 fn 恰好算出与原值相同的平方距离，min_spacing 会被误传为 nil，
--   下游 IsNearOther 第 252 行的 or 兜底会救回来，所以不会崩；
--   但如果 fn 改的是别的语义，这里就传错了。移植时建议改成显式返回值。
-- ⚠️ 另：min_spacing_sq_fn 若返回 nil，第 277 行 near_other_fn 拿到 nil，
--   会在 IsNearOther 第 246 行 nil <= 0 处报错。属调用方契约，源码未防御。
				return false
			end
        end
    end
    return true
end

local function IsNearOther2(other, pt, object_size)
-- ★★ IsNearOther2 —— IsDeployPointClear 的「新数学」，第 296 行注释自称改进版。
--【与IsNearOther 的本质差异】
--  IsNearOther  ：先取【对方】的间距（other.deploy_extra_spacing 等），
--                  min_spacing 只当默认/分摊基数 → 间距是「对方说了算」。
--  IsNearOther2  ：先取【自己】的 object_size，再【加上】对方的增量：
--  object_size + (other.deploy_smart_radius or other.deploy_extra_spacing
--                  or (有物品 and 物理半径) or 0)
--→ 间距变成「双方半径之和」，物理上更合理（大物体+小物体要分得更开）。
-- ⚠️ 注意 or 链的短路性质：第一个为真的分支生效，后面的【不再求值】。
--   所以同时设了 smart_radius 和 extra_spacing 的实体只用 smart_radius。
--   这是「优先级」而非「累加」——想累加必须写加号，不能堆 or。
    --FindEntities range check is <=, but we want <
	object_size = object_size + (
		other.deploy_smart_radius or
		other.deploy_extra_spacing or
		(other.replica.inventoryitem and other:GetPhysicsRadius(0.5)) or
		0
	)
    return other:GetDistanceSqToPoint(pt.x, 0, pt.z) < object_size * object_size
-- ★ 与 IsNearOther 第 260 行一样用严格 <，贴边不算冲突，保持一致。
-- 另外这里用 VecUtil 的三参数重载写法：distance_sq(pt.x, 0, pt.z)，
-- 显式把 y 归零 → 只算水平距离（与第 817 行 GetPlatformAtPoint 一致）。
end

--this is very similiar to IsDeployPointClear, but does the math a bit better, and DEPLOY_EXTRA_SPACING now works a lot better.
function Map:IsDeployPointClear2(pt, inst, object_size, object_size_fn, near_other_fn, check_player, custom_ignore_tags)
-- IsDeployPointClear2：结构与 IsDeployPointClear 相同，三处不同：
--  1) 第 302 行半径直接 object_size + DEPLOY_EXTRA_SPACING（不加 max）
--     —— 因为 object_size 已是「自己这一侧」的完整半径，语义不同
--  2) 默认判定函数是 IsNearOther2（半径分摊模型）
--  3) 第 309 行 near_other_fn 的调用塞在 if 链里，与前 4 条过滤合并成一条
--
-- 【第 1 点的取舍】不加 math.max 意味着「自己很小」时搜索半径会偏小，
-- 可能漏掉远处的大物体。源码注释第 296 行承认DEPLOY_EXTRA_SPACING
-- 「now works a lot better」，但半径合成方式仍与 v1 不同，是需要注意的差异。
    if self:IsXZWithThicknessInWagPunkArenaAndBarrierIsUp(pt.x, pt.z, TUNING.WAGPUNK_ARENA_COLLISION_NOBUILD_THICKNESS) then
        return false
    end

    local entities_radius = object_size + DEPLOY_EXTRA_SPACING
    near_other_fn = near_other_fn or IsNearOther2
    for i, v in ipairs(TheSim:FindEntities(pt.x, 0, pt.z, entities_radius, nil, (custom_ignore_tags ~= nil and custom_ignore_tags) or (check_player and DEPLOY_IGNORE_TAGS_NOPLAYER) or DEPLOY_IGNORE_TAGS)) do
        if v ~= inst and
            v.entity:IsVisible() and
            v.components.placer == nil and
            (v.entity:GetParent() == nil or v:HasTag("childdeployblocker")) and
            near_other_fn(v, pt, object_size_fn and object_size_fn(v) or object_size) then
            return false
        end
    end
    return true
end

function Map:CanDeployAtPoint(pt, inst, mouseover)
-- 【通用建造判定的三段式】
--  1) mouseover 过滤：鼠标下必须是玩家/平台/船边缘，
--     否则点在 UI 或装饰上时也应显示可建——这里反而是「只有这几类才行」。
--     注意用的是 HasAnyTag（任一命中）而非 HasTag。
--  2) 可通行 + 忽略悬空层（ignore_land_overhang=true，末尾的 true）
--     → 通用建造不接受站在悬崖边，墙等特殊建造才接受。
--  3) 间距：优先取物品自己声明的 DeploySpacingRadius，
--     没有物品（世界生成器）则用 DEPLOYSPACING.DEFAULT。
-- ★ 第 320 行的 inst.replica.inventoryitem ~= nil and ... or ... 兜底：
--   没挂 inventoryitem 组件的实体走默认间距。
--   注意这里读replica（客户端数据），见第 256 行同类写法的说明。
    local x,y,z = pt:Get()
    return (mouseover == nil or mouseover:HasAnyTag("player", "walkableplatform", "walkableperipheral"))
        and self:IsPassableAtPointWithPlatformRadiusBias(x,y,z, false, false, TUNING.BOAT.NO_BUILD_BORDER_RADIUS, true)
        and self:IsDeployPointClear(pt, inst, inst.replica.inventoryitem ~= nil and inst.replica.inventoryitem:DeploySpacingRadius() or DEPLOYSPACING_RADIUS[DEPLOYSPACING.DEFAULT])
end

function Map:CanDeployPlantAtPoint(pt, inst)
    return self:CanPlantAtPoint(pt:Get())
        and self:IsDeployPointClear(pt, inst, inst.replica.inventoryitem ~= nil and inst.replica.inventoryitem:DeploySpacingRadius() or DEPLOYSPACING_RADIUS[DEPLOYSPACING.DEFAULT])
end

local function IsNearOtherWallOrPlayer(other, pt, min_spacing_sq, min_spacing)
    if other:HasAnyTag("wall", "player") then
        local x, y, z = other.Transform:GetWorldPosition()
        return math.floor(x) == math.floor(pt.x) and math.floor(z) == math.floor(pt.z)
    end
	return IsNearOther(other, pt, min_spacing_sq, min_spacing)
end

function Map:CanDeployWallAtPoint(pt, inst)
-- ★ 墙的判定的特别之处：先【把坐标吸附到格子中心】（第 338 行）。
-- 注释明说 wall 使用 placer.snap_to_meters，所以这里手工模拟同样的吸附，
-- 否则鼠标位置与实际落点差半格，会出现「判定通过但放下去穿模」。
-- 【第 341 行 vs 第 319 行的三处差异，逐一对照很有价值】
--   platform_radius_bias 都传 BOAT.NO_BUILD_BORDER_RADIUS
--   ignore_land_overhang：墙传 false（允许悬空），通用建造传 true
--   第 342 行把 is_overhang 当 check_player 传下去（见第 44 行函数的说明）
-- min_spacing 固定 1（墙贴墙刚好合法），且用IsNearOtherWallOrPlayer。
    -- We assume that walls use placer.snap_to_meters, so let's emulate the snap here.
    pt = Vector3(math.floor(pt.x) + 0.5, pt.y, math.floor(pt.z) + 0.5)

    local x,y,z = pt:Get()
    local ispassable, is_overhang = self:IsPassableAtPointWithPlatformRadiusBias(x,y,z, false, false, TUNING.BOAT.NO_BUILD_BORDER_RADIUS, false)
    return ispassable and self:IsDeployPointClear(pt, inst, 1, nil, IsNearOtherWallOrPlayer, is_overhang)
end

local TrapFumaroleUtil = require("prefabs/trap_fumarole_util")
local function IsFumaroleTrapNearOther(other, pt, min_spacing_sq, min_spacing)
    --FindEntities range check is <=, but we want <
	if min_spacing_sq <= 0 and other:HasTag("structure") then
		--special case (e.g. minisigns use DEPLOYSPACING.NONE)
		if other.deploy_extra_spacing then
			min_spacing_sq = other.deploy_extra_spacing * other.deploy_extra_spacing
		end
	elseif other.deploy_smart_radius then
		min_spacing = other.deploy_smart_radius + (min_spacing or math.sqrt(min_spacing_sq)) / 2
		min_spacing_sq = min_spacing * min_spacing
	elseif other.deploy_extra_spacing then
		min_spacing_sq = math.max(other.deploy_extra_spacing * other.deploy_extra_spacing, min_spacing_sq)
    elseif other.replica.inventoryitem or other:HasTag("heatstar") then
		return false
	end
	return other:GetDistanceSqToPoint(pt) < min_spacing_sq
end

function Map:CanDeployFumaroleTrapAtPoint(pt, inst)
    -- We assume that fumarole traps use placer.snap_to_half_tile, so let's emulate the snap here.
    local tx, ty = TrapFumaroleUtil.GetTrapCoordsAtPoint(pt.x, pt.y, pt.z)
    if TrapFumaroleUtil.HasTrap(TrapFumaroleUtil.TileCoordsToId(tx, ty)) then
        return false
    end
    pt = Vector3(TrapFumaroleUtil.GetTrapCenterPoint(tx, ty))

    local x,y,z = pt:Get()
    local ispassable, is_overhang = self:IsPassableAtPointWithPlatformRadiusBias(x,y,z, false, true, TUNING.BOAT.NO_BUILD_BORDER_RADIUS, true)
    return ispassable and self:IsDeployPointClear(pt, inst, TrapFumaroleUtil.TILE_SCALE, nil, IsFumaroleTrapNearOther, is_overhang)
end

function Map:CanDeployAtPointInWater(pt, inst, mouseover, data)
    local tile = self:GetTileAtPoint(pt.x, pt.y, pt.z)
    if TileGroupManager:IsInvalidTile(tile) then
        return false
    end

    -- check if there's a boat in the way
    local min_distance_from_boat = (data and data.boat) or 0
    local radius = (data and data.radius) or 0

    local entities = TheSim:FindEntities_Registered(pt.x, 0, pt.z, TUNING.MAX_WALKABLE_PLATFORM_RADIUS + radius + min_distance_from_boat, REGISTERED_WALKABLE_PLATFORM_TAGS)
    for i, v in ipairs(entities) do
        local r = v.components.walkableplatform.platform_radius + radius + min_distance_from_boat
        if v:GetDistanceSqToPoint(pt.x, 0, pt.z) <= r * r then
            return false
        end
    end

    local min_distance_from_land = (data and data.land) or 0

    return (mouseover == nil or mouseover:HasTag("player"))
        and self:IsDeployPointClear(pt, nil, min_distance_from_boat + radius)
        and self:IsSurroundedByWater(pt.x, pt.y, pt.z, min_distance_from_land + radius)
end

function Map:CanDeployMastAtPoint(pt, inst, mouseover)
    local tile = self:GetTileAtPoint(pt.x, pt.y, pt.z)
    if TileGroupManager:IsInvalidTile(tile) then
        return false
    end

    -- check if there's a mast in the way
    local mast_min_distance = 1.5
-- ⚠️ 已核实的小瑕疵（第 410-413 行）：
-- 循环体里无条件 return false，等价于「只要找到任何桅杆就失败」。
-- 写法上等价于 #entities > 0，但这里 for 一次就返回，
-- 语义正确、只是写法冗余。不影响正确性，仅作风格记录。
-- ★ 真正值得注意：这段只检查了 mast 标签，
--   没有像 CanDeployDockAtPoint 那样检查 walkableplatform（船）。
--   桅杆可以贴着船放，这是设计取舍还是遗漏，源码未说明。
    local entities = TheSim:FindEntities(pt.x, 0, pt.z, mast_min_distance, MAST_TAGS)
    for i, v in ipairs(entities) do
        return false
    end

    return (mouseover == nil or mouseover:HasTag("player") or mouseover:HasTag("walkableplatform") or mouseover:HasTag("walkableperipheral"))
        and self:IsPassableAtPointWithPlatformRadiusBias(pt.x,pt.y,pt.z, false, false, TUNING.BOAT.NO_BUILD_BORDER_RADIUS, true)
        and self:IsDeployPointClear(pt, nil, inst.replica.inventoryitem:DeploySpacingRadius())
end

local function IsNearOtherWalkablePeripheral(other, pt, min_spacing_sq, min_spacing)
	return other:HasTag("walkableperipheral") and IsNearOther(other, pt, min_spacing_sq, min_spacing)
end

function Map:CanDeployWalkablePeripheralAtPoint(pt, inst)
	return self:IsDeployPointClear(pt, nil, inst.replica.inventoryitem:DeploySpacingRadius(), nil, IsNearOtherWalkablePeripheral, nil, WALKABLEPERIPHERAL_DEPLOY_IGNORE_TAGS)
end

local function IsDockNearOtherOnOcean(other, pt, min_spacing_sq, min_spacing)
-- IsDockNearOtherOnOcean：在通用间距判定之上，额外排除「不在海里的东西」。
-- 第 430 行用 IsVisualGroundAtPoint 排除站在悬崖/陆地上的实体——
-- 因为码头只该考虑海里的障碍，陆地上的建筑不算。
-- ★ 这是「策略注入」的一个好例子：把领域知识（码头看海洋）
--   编码进判定函数，而不是塞进通用函数加 if。移植时值得照抄这个分层。
	return IsNearOther(other, pt, min_spacing_sq, min_spacing)
		and not TheWorld.Map:IsVisualGroundAtPoint(other.Transform:GetWorldPosition())  -- Throw out any tests for anything that's not in the ocean.
end

function Map:HasAdjacentLandTile(tx, ty) -- Tile coordinates only.
    for x_off = -1, 1, 1 do
        for y_off = -1, 1, 1 do
            if x_off ~= 0 or y_off ~= 0 then
                local tileid = TheWorld.Map:GetTile(tx + x_off, ty + y_off)
                if IsLandTile(tileid) then
                    return true
                end
            end
        end
    end
    return false
end

function Map:HasAdjacentTileFiltered(tx, ty, filterfn) -- Tile coordinates only.
    for x_off = -1, 1, 1 do
        for y_off = -1, 1, 1 do
            if x_off ~= 0 or y_off ~= 0 then
                local tileid = self:GetTile(tx + x_off, ty + y_off)
                if filterfn(tileid) then
                    return true
                end
            end
        end
    end
    return false
end

function Map:IsAreaTilesFiltered(tx, ty, width, height, filterfn) -- Tile coordinates only.
    for x_off = 0, width - 1 do
        for y_off = 0, height - 1 do
            local tileid = self:GetTile(tx + x_off, ty + y_off)
            if not filterfn(tileid) then
                return false
            end
        end
    end
    return true
end

function Map:CanDeployDockAtPoint(pt, inst, mouseover)
-- 【码头判定的四层，成本递增】
--  1) tile 必须是海洋且非 INVALID（第 474-477 行）
--  2) 船只避让（第 483-489 行）：min_distance_from_entities = TILE_SCALE/2 + 1.2
--     ★ 注释第 479 行说明来源：TILE_SCALE 是格子边长，1.0 约等于悬空层宽度，
--     「宁可高估」——安全方向的偏差。两个魔数都是这里的由来。
--  3) dockjammer（第 491-495 行）：逐个检查本格子上的实体标签。
--     ★ 注意这里用 GetEntitiesOnTileAtPoint（按格子取），与按半径取的
--     FindEntities 是两套不同的空间查询，别混淆。
--  4) 通用间距（第 498 行），注入 IsDockNearOtherOnOcean。
-- ⚠️ 第 497 行 mouseover 只允许 "player"，比通用建造（还允许平台）更严——
--   因为船边缘不能放码头。
    local tile = self:GetTileAtPoint(pt.x, pt.y, pt.z)
    if TileGroupManager:IsInvalidTile(tile) or not TileGroupManager:IsOceanTile(tile) then
        return false
    end

    -- TILE_SCALE is the dimension of a tile; 1.0 is the approximate overhang, but we overestimate for safety.
    local min_distance_from_entities = (TILE_SCALE/2) + 1.2
    local min_distance_from_boat = min_distance_from_entities + TUNING.MAX_WALKABLE_PLATFORM_RADIUS

    local boat_entities = TheSim:FindEntities_Registered(pt.x, 0, pt.z, min_distance_from_boat, REGISTERED_WALKABLE_PLATFORM_TAGS)
    for _, v in ipairs(boat_entities) do
        local r = v.components.walkableplatform.platform_radius + min_distance_from_entities
        if v:GetDistanceSqToPoint(pt.x, 0, pt.z) <= r * r then
            return false
        end
    end

    for _, entity_on_tile in ipairs(TheWorld.Map:GetEntitiesOnTileAtPoint(pt.x, 0, pt.z)) do
        if entity_on_tile:HasTag("dockjammer") then
            return false
        end
    end

    return (mouseover == nil or mouseover:HasTag("player"))
        and self:IsDeployPointClear(pt, nil, min_distance_from_entities, nil, IsDockNearOtherOnOcean)
end

function Map:CanDeployBridgeAtPointWithFilter(pt, inst, mouseover, tilefilterfn)
-- ★★ 桥的判定：CanDeployBridgeAtPointWithFilter 是所有桥的公共骨架。
-- 【五个检查点，按「静态→动态」排列】
--  1) tilefilterfn：不同桥对地块要求不同（绳桥只要虚空，藤桥要海+虚空）
--  2) 第 509-516 行：按【拓扑 ID 字符串】排除特殊房间。
--⚠️ 第 513 行是一段纯字符串匹配：id:find("Archive") and not id:find("MoonMush")
--     and not id:find("ArchiveMazeEntrance")
--   这是典型的脆弱耦合：地图房间改名会让这行逻辑静默失效。
--   注释第 510-511 行解释了ArchiveMazeEntrance「不是真档案室，是连接用的洞窟」。
--   更好的做法是用房间标签（tags）而非名字子串。
--  3) 第 518 行：Vault 金库内禁建
--  4) 船只避让（与码头同样的两个魔数，第 523 行）
--  5) dockjammer 逐格检查（第 533 行）
-- ★ 整体是「模板方法」结构：差异全靠 tilefilterfn 注入。
    if tilefilterfn then
        local tile = self:GetTileAtPoint(pt.x, pt.y, pt.z)
        if not tilefilterfn(self, tile) then
            return false
        end
    end

    local id, index = self:GetTopologyIDAtPoint(pt.x, pt.y, pt.z)
    -- MoonMush check is here for Retrofitted Archives (Entire Grotto + Archives retrofit is marked with AncientArchivesRetrofit for task name)
    -- ArchiveMazeEntrance is not actually the archive, its a grotto room that acts as a connection.
    if id and (
        (id:find("Archive") and not id:find("MoonMush") and not id:find("ArchiveMazeEntrance")) or
        id:find("Atrium")) then
        return false
    end

    if self:IsPointInOrAdjacentToAnyVault(pt.x, pt.y, pt.z) then
        return false
    end

    -- TILE_SCALE is the dimension of a tile; 1.0 is the approximate overhang, but we overestimate for safety.
    local min_distance_from_entities = (TILE_SCALE/2) + 1.2
    local min_distance_from_boat = min_distance_from_entities + TUNING.MAX_WALKABLE_PLATFORM_RADIUS
    local boat_entities = TheSim:FindEntities_Registered(pt.x, 0, pt.z, min_distance_from_boat, REGISTERED_WALKABLE_PLATFORM_TAGS)
    for _, v in ipairs(boat_entities) do
        local r = v.components.walkableplatform.platform_radius + min_distance_from_entities
        if v:GetDistanceSqToPoint(pt.x, 0, pt.z) <= r * r then
            return false
        end
    end

    for _, entity_on_tile in ipairs(TheWorld.Map:GetEntitiesOnTileAtPoint(pt.x, 0, pt.z)) do
        if entity_on_tile:HasTag("dockjammer") then
            return false
        end
    end

    return (mouseover == nil or mouseover:HasTag("player"))
        and self:IsDeployPointClear(pt, nil, min_distance_from_entities)
end

function Map:BridgeFilter_OceanAndVoid(tile)
    return TileGroupManager:IsOceanTile(tile) or TileGroupManager:IsInvalidTile(tile)
end
function Map:BridgeFilter_Void(tile)
    return TileGroupManager:IsInvalidTile(tile)
end

function Map:CanDeployRopeBridgeAtPoint(pt, inst, mouseover)
-- ★ 第 551 行TheWorld:HasTag("cave") —— 全文件唯一的「洞穴/地表」开关。
-- 注释明确说「比CanDeploy 检查更快」：绳桥只存在于洞穴世界，
-- 所以先用世界标签做一次 O(1) 短路，避免进入昂贵的 tile + 实体查询。
-- ⚠️ 这可能就是任务书里提到的「洞穴/地表切换」的唯一落点：
--   它不是「切换状态」，而是用世界级标签区分两套规则。
--   真正的地表/洞穴切换在 world gen 与 seasons 组件里。
-- 对比：藤桥（第 556 行）没有这个前置检查——藤桥地表也要能用。
    if not TheWorld:HasTag("cave") then -- Faster check than the CanDeploy check.
        return false
    end
    return self:CanDeployBridgeAtPointWithFilter(pt, inst, mouseover, self.BridgeFilter_Void)
end
function Map:CanDeployVineBridgeAtPoint(pt, inst, mouseover)
    return self:CanDeployBridgeAtPointWithFilter(pt, inst, mouseover, self.BridgeFilter_OceanAndVoid)
end

function Map:IsValidTileForRopeBridgeAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return self:BridgeFilter_Void(tile)
end

function Map:IsValidTileForVineBridgeAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return self:BridgeFilter_OceanAndVoid(tile)
end

function Map:IsDockAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return tile == WORLD_TILES.MONKEY_DOCK
end

function Map:IsOceanIceAtPoint(x, y, z)
    local tile = self:GetTileAtPoint(x, y, z)
    return tile == WORLD_TILES.OCEAN_ICE
end

local BOAT_IGNORE_TAGS = shallowcopy(DEPLOY_IGNORE_TAGS)
table.insert(BOAT_IGNORE_TAGS, "_inventoryitem")

function Map:CanDeployBoatAtPointInWater(pt, inst, mouseover, data)
    local tile = self:GetTileAtPoint(pt.x, pt.y, pt.z)
    if TileGroupManager:IsInvalidTile(tile) then
        return false
    end

    local boat_radius = data.boat_radius
    local boat_extra_spacing = data.boat_extra_spacing
    local min_distance_from_land = data.min_distance_from_land

    local entities = TheSim:FindEntities_Registered(pt.x, 0, pt.z, TUNING.MAX_WALKABLE_PLATFORM_RADIUS + boat_radius + boat_extra_spacing, REGISTERED_WALKABLE_PLATFORM_TAGS)
    for i, v in ipairs(entities) do
        local v_walkableplatform = v.components.walkableplatform
        local test_distance = v_walkableplatform.platform_radius + boat_radius + boat_extra_spacing
        if v:GetDistanceSqToPoint(pt.x, 0, pt.z) <= test_distance * test_distance then
            return false
        end
    end

    return (mouseover == nil or mouseover:HasTag("player"))
        and self:IsDeployPointClear2(pt, nil, boat_radius + boat_extra_spacing, nil, nil, nil, BOAT_IGNORE_TAGS)
        and self:IsSurroundedByWater(pt.x, pt.y, pt.z, boat_radius + min_distance_from_land)
end

function Map:CanPlacePrefabFilteredAtPoint(x, y, z, prefab)
    local tile = self:GetTileAtPoint(x, y, z)
    if TileGroupManager:IsInvalidTile(tile) then
        return false
    end

    if terrain.filter[prefab] ~= nil then
        for i, v in ipairs(terrain.filter[prefab]) do
            if tile == v then
                -- can't grow on this terrain
                return false
            end
        end
    end
    return true
end

function Map:CanDeployRecipeAtPoint(pt, recipe, rot, builder)
    local is_valid_ground = false;
    if BUILDMODE.WATER == recipe.build_mode then
        local pt_x, pt_y, pt_z = pt:Get()
        is_valid_ground = not self:IsPassableAtPoint(pt_x, pt_y, pt_z)
        if is_valid_ground then
            is_valid_ground = self:IsSurroundedByWater(pt_x, pt_y, pt_z, 5)
        end
    else
        local pt_x, pt_y, pt_z = pt:Get()
        is_valid_ground = self:IsPassableAtPointWithPlatformRadiusBias(pt_x, pt_y, pt_z, false, false, TUNING.BOAT.NO_BUILD_BORDER_RADIUS, true)
    end

    return is_valid_ground
        and (recipe.testfn == nil or recipe.testfn(pt, rot, builder))
        and (
            (recipe.overridecandeployrecipeatpointfn ~= nil and recipe.overridecandeployrecipeatpointfn(pt, recipe, rot, builder)) or
            (recipe.overridecandeployrecipeatpointfn == nil and self:IsDeployPointClear(pt, nil, recipe.min_spacing or 3.2))
        )
end

function Map:IsSurroundedByWater(x, y, z, radius)
-- ★★★ IsSurroundedByWater —— 三层网格采样判定的代表，
--   同构版本还有IsSurroundedByLand（679）、IsSurroundedByLandNoDocks（713）。
--
-- 【为什么 radius 要 +1（第 646 行）】
-- 注释明说：为了覆盖地图悬空层(overhang)，而「这样比逐点IsVisualGround 测试便宜得多」。
-- ★ 这是典型的【用保守的廉价近似换掉昂贵的精确判定】：
--   精确做法要每点都查悬空层；这里把搜索半径整体放大 1，
--   保证「宁可多判一点为水」。代价是边界处可能过于宽松。
--
-- 【为什么先测四角（第 650-653 行）】
-- 最短拒绝路径优先。四角任一不满足就立刻 false，
-- 而四角是「四角包围盒」里最容易被证伪的点。
--
-- 【采样密度（第 647 行）】num_edge_points = ceil(radius*2/4) - 1
--  即每 4 个格子采一个点。radius < 1 时（+1 后 < 2）num_edge_points = 0，
-- 此时只剩四角检测，第 656 行提前 return true。
-- ⚠️ 这是【离散采样】不是【精确判定】：菱形的斜边和圆形边界会漏检。
--   对「船需要一圈水」这种要求宽松的场景够用；
--   若移植到需要精确边界的玩法，必须换成逐点或精确几何判定。
    radius = radius + 1 --add 1 to radius for map overhang, way cheaper than doing an IsVisualGround test
    local num_edge_points = math.ceil((radius*2) / 4) - 1

    --test the corners first
    if not self:IsOceanTileAtPoint(x + radius, y, z + radius) then return false end
    if not self:IsOceanTileAtPoint(x - radius, y, z + radius) then return false end
    if not self:IsOceanTileAtPoint(x + radius, y, z - radius) then return false end
    if not self:IsOceanTileAtPoint(x - radius, y, z - radius) then return false end

    --if the radius is less than 1(2 after the +1), it won't have any edges to test and we can end the testing here.
    if num_edge_points == 0 then return true end

    local dist = (radius*2) / (num_edge_points + 1)
-- dist = (radius*2)/(num_edge_points+1) —— 分母 +1 的原因：
-- 采样点在区间【内部】均分，含两端则需 n+1 段才能容纳 n 个内部点。
-- 即 idist 从 dist 递增到 num_edge_points*dist < radius*2，两端不取。
-- 少写这个 +1 会导致最后一个采样点正好落在 radius 上（边界点），
-- 使采样退化。
    --test the edges next
    for i = 1, num_edge_points do
        local idist = dist * i
        if not self:IsOceanTileAtPoint(x - radius + idist, y, z + radius) then return false end
        if not self:IsOceanTileAtPoint(x - radius + idist, y, z - radius) then return false end
        if not self:IsOceanTileAtPoint(x - radius, y, z - radius + idist) then return false end
-- 四条边的坐标表达式各不相同（各有 ±radius 与固定另一轴），
-- 靠 x - radius + idist / z - radius + idist 的旋转对称实现四条边。
-- ⚠️ 这种「用四条不同表达式枚举四条边」的写法极易看错，
--   自己写循环时更推荐用一个方向向量表来避免手误。
--   我逐条核对过：四条边覆盖上/下/左/右且不重复（端点由四角测试负责）。
        if not self:IsOceanTileAtPoint(x + radius, y, z - radius + idist) then return false end
    end

    --test interior points last
    for i = 1, num_edge_points do
        local idist = dist * i
        for j = 1, num_edge_points do
            local jdist = dist * j
            if not self:IsOceanTileAtPoint(x - radius + idist, y, z - radius + jdist) then return false end
        end
    end
    return true
end

function Map:IsSurroundedByLand(x, y, z, radius)
    radius = radius + 1 --add 1 to radius for map overhang, way cheaper than doing an IsVisualGround test
    local num_edge_points = math.ceil((radius*2) / 4) - 1

    --test the corners first
    if not self:IsLandTileAtPoint(x + radius, y, z + radius) then return false end
    if not self:IsLandTileAtPoint(x - radius, y, z + radius) then return false end
    if not self:IsLandTileAtPoint(x + radius, y, z - radius) then return false end
    if not self:IsLandTileAtPoint(x - radius, y, z - radius) then return false end

    --if the radius is less than 1(2 after the +1), it won't have any edges to test and we can end the testing here.
    if num_edge_points == 0 then return true end

    local dist = (radius*2) / (num_edge_points + 1)
    --test the edges next
    for i = 1, num_edge_points do
        local idist = dist * i
        if not self:IsLandTileAtPoint(x - radius + idist, y, z + radius) then return false end
        if not self:IsLandTileAtPoint(x - radius + idist, y, z - radius) then return false end
        if not self:IsLandTileAtPoint(x - radius, y, z - radius + idist) then return false end
        if not self:IsLandTileAtPoint(x + radius, y, z - radius + idist) then return false end
    end

    --test interior points last
    for i = 1, num_edge_points do
        local idist = dist * i
        for j = 1, num_edge_points do
            local jdist = dist * j
            if not self:IsLandTileAtPoint(x - radius + idist, y, z - radius + jdist) then return false end
        end
    end
    return true
end

function Map:IsSurroundedByLandNoDocks(x, y, z, radius)
    radius = radius + 1 --add 1 to radius for map overhang, way cheaper than doing an IsVisualGround test
    local num_edge_points = math.ceil((radius*2) / 4) - 1

    --test the corners first
    if not self:IsLandTileNoDocksAtPoint(x + radius, y, z + radius) then return false end
    if not self:IsLandTileNoDocksAtPoint(x - radius, y, z + radius) then return false end
    if not self:IsLandTileNoDocksAtPoint(x + radius, y, z - radius) then return false end
    if not self:IsLandTileNoDocksAtPoint(x - radius, y, z - radius) then return false end

    --if the radius is less than 1(2 after the +1), it won't have any edges to test and we can end the testing here.
    if num_edge_points == 0 then return true end

    local dist = (radius*2) / (num_edge_points + 1)
    --test the edges next
    for i = 1, num_edge_points do
        local idist = dist * i
        if not self:IsLandTileNoDocksAtPoint(x - radius + idist, y, z + radius) then return false end
        if not self:IsLandTileNoDocksAtPoint(x - radius + idist, y, z - radius) then return false end
        if not self:IsLandTileNoDocksAtPoint(x - radius, y, z - radius + idist) then return false end
        if not self:IsLandTileNoDocksAtPoint(x + radius, y, z - radius + idist) then return false end
    end

    --test interior points last
    for i = 1, num_edge_points do
        local idist = dist * i
        for j = 1, num_edge_points do
            local jdist = dist * j
            if not self:IsLandTileNoDocksAtPoint(x - radius + idist, y, z - radius + jdist) then return false end
        end
    end
    return true
end

function Map:GetNearbyOceanPointFromXZ(x, z, maxradius, radiusscale)
-- ★ GetNearbyOceanPointFromXZ：以方形螺旋向外找最近的水。
-- 【四条边的遍历范围是精心设计的】
--  for dx = -r, r     —— 顶边含两端（因为是首次到达这一层）
--  for dz = r-1, -r, -1 —— 右边跳过已测过的角点（-r 起算）
--  for dx = r-1, -r, -1 —— 底边同理
--  for dz = -r+1, r-1   —— 左边同理，最后一个到 r-1（不回到角点）
-- ★ 每条边都「跳过一个已测过的角点」，因此不重复测试，总测试数恰为 (2r+1)²-1。
--   若改成每条边都取全范围，会在角点上重复 4 次（轻微浪费，但结果不变）。
-- 螺旋顺序保证「先找到的一定是曼哈顿距离最小的」，符合「最近」的语义。
-- ⚠️ radiusscale 默认 TILE_SCALE，即【按格子步进】而非连续采样。
--   所以返回的坐标必然落在格子中心附近，精度受限于格子大小。
    if not radiusscale then
        radiusscale = TILE_SCALE
    end
    local testx, testz
    for r = 1, maxradius do -- Go around in a square spiral to try to find an ocean tile.
        local maxradiusoffset = r * radiusscale
        for dx = -r, r do -- Top left to top right.
            testx, testz = x + dx * radiusscale, z + maxradiusoffset
            if self:IsOceanAtPoint(testx, 0, testz, false) then
                return testx, testz
            end
        end
        for dz = r - 1, -r, -1 do -- Top right to bottom right.
            testx, testz = x + maxradiusoffset, z + dz * radiusscale
            if self:IsOceanAtPoint(testx, 0, testz, false) then
                return testx, testz
            end
        end
        for dx = r - 1, -r, -1 do -- Bottom right to bottom left.
            testx, testz = x + dx * radiusscale, z - maxradiusoffset
            if self:IsOceanAtPoint(testx, 0, testz, false) then
                return testx, testz
            end
        end
        for dz = -r + 1, r - 1 do -- Bottom left to top left.
            testx, testz = x - maxradiusoffset, z + dz * radiusscale
            if self:IsOceanAtPoint(testx, 0, testz, false) then
                return testx, testz
            end
        end
    end
    return nil, nil
end

function Map:GetNearestPointOnWater(x, z, radius, iterations) -- NOTES(JBK): Deprecated use GetNearbyOceanPointFromXZ this is kept around for mods.
-- ★★ GetNearestPointOnWater 已被官方标记 Deprecated（第 782 行行尾注释）：
--   "Deprecated use GetNearbyOceanPointFromXZ this is kept around for mods."
--   即【仅为向后兼容保留】。抄这个文件时不要学它的算法。
-- 差异：旧版只沿四个正交方向线性推进（旧版 test_increment = radius/iterations），
--   只做十字形采样，找不到就放弃；新版是完整的方形螺旋。
-- ⚠️ 返回值语义也不同：旧版第一个返回值是 true（布尔），
--   与函数名承诺的「返回坐标」不符——调用方必须按 (bool, x, z) 解包。
    local test_increment = radius / iterations

    for i=1,iterations do
        local test_x, test_z = 0,0

        test_x, test_z = x + test_increment * i, z + 0
        if self:InternalIsPointOnWater(test_x, test_z) then
            return true, test_x, test_z
        end

        test_x, test_z = x +0, z + test_increment * i
        if self:InternalIsPointOnWater(test_x, test_z) then
            return true, test_x, test_z
        end

        test_x, test_z = x + -test_increment * i, z + 0
        if self:InternalIsPointOnWater(test_x, test_z) then
            return true, test_x, test_z
        end

        test_x, test_z = x + 0, z + -test_increment * i
        if self:InternalIsPointOnWater(test_x, test_z) then
            return true, test_x, test_z
        end
    end

    return false, 0, 0
end

function Map:InternalIsPointOnWater(test_x, test_y, test_z)
-- ★★ 第 813-816 行：实参错位兼容。
-- 支持 InternalIsPointOnWater(x, z) 与 (x, y, z) 两种调用：
-- 若第三参为 nil，则把第二参当成 z、y 置 0。
-- 这是 mod 生态的产物（老代码少传一个参数），不是优雅设计。
-- ⚠️ 危险：若真的想传 y=nil 的 (x, nil, z)，会被误判为两参调用。
-- 第 824 行 GetPlatformAtPoint 有完全相同的兼容代码，可视为一种约定。
	if test_z == nil then -- to support passing in (x, z) instead of (x, y, x)
		test_z = test_y
		test_y = 0
	end
    if self:IsVisualGroundAtPoint(test_x, test_y, test_z) or self:GetPlatformAtPoint(test_x, test_y, test_z) ~= nil then
        return false
    else
        return true
    end
end

function Map:GetPlatformAtPoint(pos_x, pos_y, pos_z, extra_radius)
-- ★ 与第 812 行同款实参错位兼容，第 825-828 行。
-- 第 829 行 extra_radius 只加在【搜索半径】上，与第 44 行的 bias 同理：
--   扩大搜索范围，不放大判定半径。判定仍用 platform_radius 本身（第 832 行）。
-- ⚠️ 第 832 行 GetDistanceSqToPoint(pos_x, 0, pos_z) 强制 y=0，
--   所以「平台判定只看平面距离」。多层平台（船叠船）在此会互相命中。
	if pos_z == nil then -- to support passing in (x, z) instead of (x, y, x)
		pos_z = pos_y
		pos_y = 0
	end
    local entities = TheSim:FindEntities_Registered(pos_x, pos_y, pos_z, TUNING.MAX_WALKABLE_PLATFORM_RADIUS + (extra_radius or 0), REGISTERED_WALKABLE_PLATFORM_TAGS)
    for i, v in ipairs(entities) do
		local r = v.components.walkableplatform.platform_radius
		if v:GetDistanceSqToPoint(pos_x, 0, pos_z) <= r * r then
            return v
        end
    end
    return nil
end

--(forward_x, forward_z) is normalized direction vector
function Map:GetNearestPlatformInDirection(x, z, forward_x, forward_z, dist)
-- ★★★ GetNearestPlatformInDirection —— 前方最近可跳上的平台及其落脚点。
-- 【数学部分：这是全文件几何计算最密的一段，逐行拆解】
--  输入 (forward_x, forward_z) 是【已归一化】的方向向量（第 839 行注释强调）。
--  dot = forward·dA           —— dA 在前方向量上的投影，即「沿前方走了多远」
--  dot > 0                   —— 只考虑前方的平台（半平面裁剪）
--  Bsq = Asq - dot²          —— ★ 用勾股定理解「中心到前方射线的垂距平方」
--                              Bsq 恒为正（因为已由 dot>0 保证可分解）
--
--  【第 847-860 行：用两段几何分别求交点】
--   分支A（dot <= dist1）：射线上距原点 dist1 处在圆内 →
--        用点积判「中心到射线的垂距 <= r」（第 850 行 |叉积| <= r）
--        这是无限长直线与圆的相交判定，此时交点仍在 max_hop_distance 内。
--   分支B（dot > dist1）： 射线上距原点 dist1 处【已在圆外】，
--        只能落在圆靠近原点的那一侧 → 改判「第 856 行：dist1 端点到圆心 <= r」。
--   ★ 两个分支的差别正是「交点在前还是在后」，少任何一个都会算错落脚点。
--
--  【第 867 行：真正求落脚距离】
--   dist1 = dot - sqrt(r² - Bsq)
--   直觉：沿射线从圆心投影点往回退「半个弦长」即入圆点。
--   ⚠️ 只有 Bsq <= r² 时根号内非负；
--     两个 intersects 分支正是靠第 850/856 行保证了这一点。
--     这是「先验证相交、再开根号」的正确顺序，不能颠倒。
--
--  【第 847 行 max_hop_distance】限制跳板的最远距离（传送带/船的跳跃上限）。
--  ★ dist1 被【覆写】了：第 847 行先算过一遍，第 867 行再算一遍。
--    第 847 行的值只在第 849 行做分支判断时使用，复用同一个变量名容易误读。
-- ⚠️ 循环末尾没有 return nil，显式缺省即返回 nil——
--   整个函数在没找到平台时返回 nil（不是 false），调用方需按 nil 判断。
	for i, v in ipairs(TheSim:FindEntities_Registered(x, 0, z, dist + TUNING.MAX_WALKABLE_PLATFORM_RADIUS, REGISTERED_WALKABLE_PLATFORM_TAGS)) do
		local xA, _, zA = v.Transform:GetWorldPosition()
		local dxA, dzA = xA - x, zA - z
		local dot = forward_x * dxA + forward_z * dzA
		if dot > 0 then --target is in front
			local r = v.components.walkableplatform.platform_radius
			local dist1 = math.min(dist, v.components.walkableplatform.max_hop_distance or dist)
			local intersects
			if dot <= dist1 then
				if math.abs(forward_z * dxA - forward_x * dzA) <= r then
					--distance to forward vector is within platform radius
					intersects = true
				end
			else
				local x1, z1 = x + forward_x * dist1, z + forward_z * dist1
				if distsq(x1, z1, xA, zA) <= r * r then
					--distance to end point(x1, z1) is within platform radius
					intersects = true
				end
			end
			if intersects then
				--A: distance from me to center of circle
				--B: distance from center of circle to forward vector
				--dot: A projected onto forward vector
				local Asq = dxA * dxA + dzA * dzA
				local Bsq = Asq - dot * dot
				dist1 = dot - math.sqrt(r * r - Bsq)
				return v, x + forward_x * dist1, z + forward_z * dist1
			end
		end
	end
end

function Map:FindRandomPointWithFilter(max_tries, filterfn)
-- 【用拒绝采样（rejection sampling）找满足条件的点】
-- 坐标在 [-w, w] × [-h, h] 上均匀随机，失败就重试，最多 max_tries 次。
-- ★ 权衡：有最大重试次数保证【不会死循环】，但失败时返回 nil。
--   在「符合条件的区域很稀疏」时（如找一小块海），失败率会很高。
--   更稳的做法是预筛可行区域（如 arena points 那套缓存扫描）。
-- ⚠️ 边界：2*math.random()-1 给出 [-1, 1]，math.random() 返回 [0,1)。
--   故 x ∈ [-w, w)，右侧开区间。不影响均匀性，但注意不是闭区间。
    local w, h = self:GetSize()
    w = w/2 * TILE_SCALE
    h = h/2 * TILE_SCALE
    -- NOTES(JBK): w and h are now half width and half height sample from -w and +w
    while (max_tries > 0) do
        max_tries = max_tries - 1
        local x, z = (2 * math.random() - 1) * w, (2 * math.random() - 1) * h
        if filterfn == nil or filterfn(self, x, 0, z) then
            return Vector3(x, 0, z)
        end
    end
    return nil
end

function Map:FindRandomPointInOcean(max_tries)
-- ★ 这两行是「筛选器注入」的最小示范：把 self.IsOceanAtPoint 当函数值传下去。
-- ⚠️ 直接传方法名（不加 self.）会得到 nil，因为 IsOceanAtPoint 需要 self。
--   写成 self.IsOceanAtPoint 是必须的——第 882 行会用 self 调它。
--   注意 FindRandomPointWithFilter 的 filterfn 签名是 (self, x, y, z)，
--   所以传入的必须是【接收 self 作为第一参】的方法，这正是能这样传的原因。
    return self:FindRandomPointWithFilter(max_tries, self.IsOceanAtPoint)
end

function Map:FindRandomPointOnLand(max_tries)
    return self:FindRandomPointWithFilter(max_tries, self.IsLandTileAtPoint)
end

function Map:GetTopologyIDAtPoint(x, y, z)
-- 【拓扑（topology）是storygen 产出的「区域划分」：
--   TheWorld.topology.nodes[i] —— 第 i 个区域的节点（含 tags 多边形等）
--   TheWorld.topology.ids[i]    —— 第 i 个区域的【字符串 ID】
-- 房间级规则（酸雨/地震/月爆）都靠区域的 tags 来决定。
-- GetNodeIdAtPoint 返回的是索引，GetTileNodeId（第 915 行）则是按格子取。
	local node_index = self:GetNodeIdAtPoint(x, y, z)
    return TheWorld.topology.ids[node_index], node_index
end

function Map:FindNodeAtPoint(x, y, z)
-- ★★ FindNodeAtPoint vs FindVisualNodeAtPoint（第 1003 行）—— 必须分清：
--   本函数：按【脚下地块】找区域。点在悬空层边界时返回的是「下方地块」的区域。
--   FindVisualNodeAtPoint：按【眼睛看到的】那一层找区域（考虑 render_layer）。
-- 源码第 903 行注释直说：If you care about the tile overlap then use FindVisualNodeAtPoint。
-- ⚠️ 选错的症状：站在悬空层上做区域判定（酸雨/地震/月爆）会判到下面的海域，
--   导致「明明在陆地上却中了地震」。这类 bug 极难定位。
	-- Note: If you care about the tile overlap then use FindVisualNodeAtPoint
	local node_index = self:GetNodeIdAtPoint(x, y, z)
	return TheWorld.topology.nodes[node_index], node_index
end

function Map:NodeAtPointHasTag(x, y, z, tag)
-- 三重防御：node 非 nil、node.tags 非 nil、table.contains。
-- ★ 任何来自 TheWorld.topology 的数据都不能假设 tags 一定存在——
--   区域数据来自 mod 提供的 rooms（map/rooms），第三方数据不可信。
--   第 915 行 NodeAtTileHasTag 有完全相同的三重防御，说明这是刻意的。
	-- Note: If you care about the tile overlap then use FindVisualNodeAtPoint
	local node_index = self:GetNodeIdAtPoint(x, y, z)
	local node = TheWorld.topology.nodes[node_index]
	return node ~= nil and node.tags ~= nil and table.contains(node.tags, tag)
end

function Map:NodeAtTileHasTag(x, y, tag)
    local node_index = self:GetTileNodeId(x, y)
    local node = TheWorld.topology.nodes[node_index]
    return node ~= nil and node.tags ~= nil and table.contains(node.tags, tag)
end

function Map:CanAreaTagsHaveAcidRain(tags)
-- CanAreaTagsHaveAcidRain：酸雨的区域级开关。
-- lunacyarea —— 癫狂区域内不下酸雨（那里已经有月爆，叠加会超标）
-- nocavein    —— 世界生成的标记，表示该区域「不透洞穴」，同样排除
-- ★ 设计意图：把「哪些区域不下酸雨」变成【数据（房间标签）】而非硬编码坐标，
--   模组新增房间只要打标签即可。这是 mod 友好设计的典范。
    return not table.contains(tags, "lunacyarea") and not table.contains(tags, "nocavein")
end

function Map:CanPointHaveAcidRain(x, y, z)
-- 点级版：三层过滤，任一不满足即不可下酸雨。
--  1) 不可通行 tile（深渊/虚空）—— 没有地面承接
--  2) Vault 金库内（第 930 行）—— 金库是密封的
--  3) 区域的 tags 判定（第 941 行）
-- 第 934 行注释再次提醒：关心悬空层请用 FindVisualNodeAtPoint。
-- ⚠️ 第 941 行的行尾注释 "-- worldgen" 含义不明，疑似遗留标记，未见解释。
    if self:IsImpassableTileAtPoint(x, y, z) then
        return false
    end

    if self:IsPointInAnyVault(x, y, z) then
        return false
    end

    -- Note: If you care about the tile overlap then use FindVisualNodeAtPoint
    local node_index = self:GetNodeIdAtPoint(x, y, z)
    local node = TheWorld.topology.nodes[node_index]
    if node == nil or node.tags == nil then
        return false
    end

    return self:CanAreaTagsHaveAcidRain(node.tags)
end

function Map:CanAreaTagsHaveQuaker(tags)
    return not table.contains(tags, "noquaker")
end

function Map:CanPointHaveQuaker(x, y, z)
    if self:IsPointInAnyVault(x, y, z) then
        return false
    end

    -- Note: If you care about the tile overlap then use FindVisualNodeAtPoint
    local node_index = self:GetNodeIdAtPoint(x, y, z)
    local node = TheWorld.topology.nodes[node_index]
    if node == nil or node.tags == nil then
        return false
    end

    return self:CanAreaTagsHaveQuaker(node.tags) -- worldgen
end

function Map:GetRandomPointClustersForNodePrefix(prefixes, countpernode)
    local ret = {}

    local topology = TheWorld.topology
    for id, name in ipairs(topology.ids) do
        for _, prefix in ipairs(prefixes) do
            if name:sub(1, #prefix) == prefix then
                local area =  topology.nodes[id]
                table.insert(ret, {self:GetRandomPointsForSite(area.x, area.y, area.poly, countpernode)})
            end
        end
    end

    return ret
end

local function FindVisualNodeAtPoint_TestArea(map, pt_x, pt_z, on_land, r)
-- ★★ FindVisualNodeAtPoint_TestArea —— 「视觉层归属」的判定算法。
-- 【问题】悬空层（overhang）盖在地面 tile 之上，脚下 tile 与眼睛看到的 tile
--   可能不是同一个。要找「真正属于这一层」的 tile，就必须比较渲染层级。
-- 【算法】
--  1) 以 (pt_x, pt_z) 为中心，取 3×3 邻域（-1..1，各偏移 r）
--  2) 第 986 行：只接受与 on_land【同组】的 tile（都在陆地 或 都在海洋）
--     —— 跨组的不参与竞争，避免「脚在海、看到陆」这类错误归属
--  3) 第 988 行：取 _render_layer（渲染层级，层越高画得越靠上）
--  4) 第 989 行：严格大于才替换 → 在同层中【取最先遇到的】
--     初始 render_layer = -1 保证任何合法 tile 都能入选。
--  5) 第 999 行：全 INVALID 则返回 nil，否则返回累积的 best
-- ⚠️ 第 989 行的严格 > 而非 >=：同层时保留先遇到的（-x, -z 角先扫）。
--   所以在层级相同的多个候选中，结果依赖遍历顺序 —— 一个隐式的偏好规则。
	local best = {tile_type = WORLD_TILES.INVALID, render_layer = -1}
	for _z = -1, 1 do
		for _x = -1, 1 do
			local x, z = pt_x + _x*r, pt_z + _z*r

			local tile_type = map:GetTileAtPoint(x, 0, z)
			if on_land == IsLandTile(tile_type) then
				local tile_info = GetTileInfo(tile_type)
				local render_layer = tile_info ~= nil and tile_info._render_layer or 0
				if render_layer > best.render_layer then
					best.tile_type = tile_type
					best.render_layer = render_layer
					best.x = x
					best.z = z
				end
			end
		end
	end

	return best.tile_type ~= WORLD_TILES.INVALID and best or nil
end

-- !! NOTE: This function is fairly expensive!
function Map:FindVisualNodeAtPoint(x, y, z, has_tag)
-- ★★★ FindVisualNodeAtPoint —— 源码第 1002 行自己标注了
--   "!! NOTE: This function is fairly expensive!"（相当昂贵）。
--
-- 【为什么要试三个半径】第 1006-1008 行的 0.95 / 1.25 / 1.5 递增试探：
--   第 1007 行注释说明——玩家可能站得离水面很近（逻辑上在陆地但人在海上），
--   小半径找不到合适的 tile，就需要放大半径再试。
-- 这是「三级回退」的容错设计：宁可多花几次采样，也不要给错答案。
--
-- 【第 1010 行的短路技巧】
--  local node_index = (on_land and best ~= nil) and self:GetNodeIdAtPoint(...) or 0
--  不在陆地上 → 直接用 0（无效索引）→ 第 1012 行取到 nodes[0] = nil。
--  ★ 用「索引 0 作为无效哨兵」省掉一层 if/else，且下游全都做了 nil 检查。
-- ⚠️ 但这依赖 TheWorld.topology.nodes[0] 确实为 nil；若哪天有索引 0 的区域，
--   语义就崩了。属于「隐式契约」，移植时要显式化。
--
-- 【第 1015 行的返回不对称】
--  无 has_tag 时返回 (node, index)——node 可能是 nil；
--  有 has_tag 时标签不匹配返回 (nil, index) —— index 仍有效。
--  调用方若只取第一个返回值，语义是「标签匹配的区域，没有则 nil」。
	local on_land = self:IsVisualGroundAtPoint(x, 0, z)

	local best = FindVisualNodeAtPoint_TestArea(self, x, z, on_land, 0.95)
				or FindVisualNodeAtPoint_TestArea(self, x, z, on_land, 1.25) -- this is the handle some of the corner case when there the player is really standing quite far into the water tile, but logically on land
				or FindVisualNodeAtPoint_TestArea(self, x, z, on_land, 1.5)

	local node_index = (on_land and best ~= nil) and self:GetNodeIdAtPoint(best.x, 0, best.z) or 0
	if has_tag == nil then
		return TheWorld.topology.nodes[node_index], node_index
	else
		local node = TheWorld.topology.nodes[node_index]
		return ((node ~= nil and table.contains(node.tags, has_tag)) and node or nil), node_index
	end
end

local LUNACY_TILES =
-- LUNACY_TILES：直接按 tile 判定的癫狂地形（月亮裂隙、月亮沼泽）。
-- 少数几种「看脚下的格子就知道是否癫狂」的情况，省去拓扑查询。
{
    [WORLD_TILES.RIFT_MOON] = true,
    [WORLD_TILES.LUNAR_MARSH] = true,
}
local CHECK_LUNACY_FNS = {
-- ★★★ CHECK_LUNACY_FNS —— 【判定表（rule table）设计】的教科书案例。
-- 五个互不相关的癫狂成因，各写成一个「签名一致」的函数，签名刻意统一为
--  (self, x, y, z)，全部返回布尔。
-- ★ 为什么签名要强一致：第 1044 行才能用同一个 pairs 循环无差别遍历，
--   新增一种癫狂成因 = 往表里加一行，不动任何调用方代码。
--   这是「开闭原则」在游戏脚本里的轻量落地。
-- 【五种成因】
--   IS_ALTER_AWAKE   —— alter 醒了且是夜晚（TheWorld.state 直接读，不用 netvar）
--   IS_RIFT_FULL_MOON —— 裂隙 spawner 开启且满月（要查 components.riftspawner）
--   IS_IN_MOONSTORM  —— ★ 唯一必须走 net（TheWorld.net.components.moonstorms）
--   IS_ON_LUNACY_TILE—— 脚下就是癫狂地形
--   IS_IN_LUNACY_AREA—— 拓扑区域带 lunacyarea 标签（走 FindVisualNodeAtPoint）
-- ⚠️ 第 1029-1030 行：riftspawner 只做非 nil 检查，未检查 TheWorld.state.isfullmoon
--   是否为 nil；若为 nil 则返回 nil（falsy），行为上安全但语义不严谨。
    ["IS_ALTER_AWAKE"] = function(self, x, y, z)
        return TheWorld.state.isalterawake and TheWorld.state.isnight
    end,
    ["IS_RIFT_FULL_MOON"] = function(self, x, y, z)
        local riftspawner = TheWorld.components.riftspawner
        return riftspawner and riftspawner:GetLunarRiftsEnabled() and TheWorld.state.isfullmoon
    end,
    ["IS_IN_MOONSTORM"] = function(self, x, y, z)
        local moonstorms = TheWorld.net.components.moonstorms
        return moonstorms and moonstorms:IsXZInMoonstorm(x, z)
    end,
    ["IS_ON_LUNACY_TILE"] = function(self, x, y, z)
        return LUNACY_TILES[self:GetTileAtPoint(x, y, z)]
    end,
    ["IS_IN_LUNACY_AREA"] = function(self, x, y, z)
        return self:FindVisualNodeAtPoint(x, y, z, "lunacyarea") ~= nil
    end,
}
function Map:IsInLunacyArea(x, y, z)
    for _, lunacyfn in pairs(CHECK_LUNACY_FNS) do
        if lunacyfn(self, x, y, z) then
            return true
        end
    end

    return false
end

-- Like Map:IsInLunacyArea, but gives us a modifier for mutation spawn chances
local EXTRA_MODIFIER = 0.5
function Map:GetLunacyAreaModifier(x, y, z)
-- ★★ GetLunacyAreaModifier：与 IsInLunacyArea 共用同一张判定表，
--   但输出的是【强度】而非布尔。
--
-- 【第 1061 行有个值得注意的写法】modifier = math.max(1, modifier + EXTRA_MODIFIER)
--  注释说「每个额外的癫狂修正加 50%」。但 math.max(1, ...) 意味着：
--   第一次命中时 modifier = max(1, 0 + 0.5) = 1（不是 0.5）——
--   ★ 被这个 max「抬」到了基准 1。第二次 1.5、第三次 2.0。
--  所以实际语义是「命中 n 次 → max(1, 0.5n)」，即 n=1 时是 1 而非 0.5。
--  这大概是有意的（至少命中一次就要有满额基础修正），但与注释字面不符。
-- ⚠️ 我逐行核对过第 1056/1058/1061 行，确认 modifier 初值为 0、
--   EXTRA_MODIFIER 为 0.5（第 1054 行），上述推导成立。
--   标为「疑似」：无法确定是有意为之还是笔误，源码无更多线索。
    local modifier = 0

    for _, lunacyfn in pairs(CHECK_LUNACY_FNS) do
        if lunacyfn(self, x, y, z) then
            -- Each extra lunacy modifier adds a 50% additive increase
            modifier = math.max(1, modifier + EXTRA_MODIFIER)
        end
    end

    return modifier
end

function Map:CanCastAtPoint(pt, alwayspassable, allowwater, deployradius)
-- 【施法判定的短路结构值得学】
--  第 1069 行：alwayspassable 为真时【跳过全部地面检查】直接进第二层。
--    语义是「这个技能不挑地形」（如凭空召唤），用于表新机制的扩展点。
--  第 1070 行：deployradius 缺省或 <= 0 时【跳过间距检查】。
--    ★ 用「nil / <= 0」两种表达同一件事，是刻意的宽容：
--      调用方写 nil 和写 0 都不必特殊处理。
--  两层都过才true ——「不挑地形」与「不挑距离」是两个独立的放宽维度。
	if alwayspassable or (self:IsPassableAtPoint(pt.x, 0, pt.z, allowwater) and not self:IsGroundTargetBlocked(pt)) then
		return deployradius == nil or deployradius <= 0 or self:IsDeployPointClear(pt, nil, deployradius, nil, nil, nil, CAST_DEPLOY_IGNORE_TAGS)
	end
	return false
end

function Map:IsInMapBounds(x, y, z)
-- ★⚠️ 已核实的越界问题（第 1082 行）：
--   if tx > w or tz > h —— 用的是严格大于。
--   GetTileCoordsAtPoint 返回的索引若恰好等于 w（即边界外的第一格），
--   这里会被判为「在界内」。正确的边界判断应为 tx >= w or tz >= h。
--   依据：合法索引范围是 0 .. w-1（第 1077 行已用 tx < 0 排除了负数侧）。
--   后果：地图最外圈之外的「一格」会被误判为界内。
--   ⚠️ 实际影响可能有限（该格通常是 INVALID tile，多数调用方会先判 tile），
--     但作为「是否越界」的权威 API，返回 true 是错的。
--   标为「疑似」而非「确定」：需确认 GetTileCoordsAtPoint 是否已把点夹到 w-1，
--   我未读该函数（位于 map/terrain.lua）。结论基于索引范围的常规定义。
    local tx, tz = self:GetTileCoordsAtPoint(x, y, z)
    if tx < 0 or tz < 0 then
        return false
    end

    local w, h = self:GetSize()
    if tx > w or tz > h then
        return false
    end

    return true
end

function Map:IsTileLandNoDocks(tile)
-- 这两个是【给 filterfn 用的裸函数】而非点查询：
-- 接收 (self, tile) 而非 (x, y, z)，因此能直接塞进 IsAboveGroundInSquare（第 1097 行）。
-- ★ 这是「提高函数签名的一致性以支持注入」的具体做法。
-- 注意 IsTileLandNoDocks 与第 80 行 IsLandTileNoDocksAtPoint 的差别：
--   后者自己调 GetTileAtPoint（点→tile），前者直接收 tile。两者规则相同。
    return TileGroupManager:IsLandTile(tile) and tile ~= WORLD_TILES.MONKEY_DOCK
end

function Map:IsTileOcean(tile)
    return TileGroupManager:IsOceanTile(tile)
end

function Map:IsAboveGroundInSquare(x, y, z, r, filterfn)
-- ★ IsAboveGroundInSquare：检查 (2r+1)² 个采样点是否全部满足条件。
-- 【两个分支的历史包袱】
--  有 filterfn：新逻辑，【按 tile 判定】，可传IsTileLandNoDocks / IsTileOcean
--  无 filterfn：旧逻辑，【按点判定】且 allow_water=false（允许码头）。
-- 第 1108 行注释直言 "Old logic assumes point based filtering"，
--  说明 filterfn 是后加的扩展点，旧调用方仍走无参分支。
-- ⚠️ 第 1104 行 filterfn(self, tile) 与第 1089-1094 行的签名严格对应，
--   所以传进来的必须是那两个裸函数之一；传普通方法会因 self 语义不符而错。
-- 采样步长是 TILE_SCALE（第 1103 行），即【逐格】而非连续——
-- 所以 r=6 实际是 13×13=169 次tile 查询，第 1148 行调用它时就是这个开销。
    r = r or 1
    for dx = -r, r do
        for dz = -r, r do
            if filterfn then
                -- New logic allows for tile based filtering.
                local tile = self:GetTileAtPoint(x + dx * TILE_SCALE, y, z + dz * TILE_SCALE)
                if not filterfn(self, tile) then
                    return false
                end
            else
                -- Old logic assumes point based filtering with no ocean tiles but allows docks.
                if not self:IsAboveGroundAtPoint(x + dx * TILE_SCALE, y, z + dz * TILE_SCALE, false) then
                    return false
                end
            end
        end
    end
    return true
end





local GOOD_ARENA_SQUARE_SIZE = 6
-- 【竞技场出生点系统的三个魔数】
--  GOOD_ARENA_SQUARE_SIZE = 6    —— 判定「够大」的正方形边长（格）
--  IS_CLEAR_AREA_RADIUS = 6*TILE_SCALE —— 查障碍实体的半径
--  NO_PLAYER_RADIUS = 35         —— 排除玩家附近的点（单位是世界单位，非格）
-- ⚠️ 单位不一致值得注意：前两个是【格】的倍数，第三个 35 是世界单位。
--   TILE_SCALE 通常为 1，所以数值上接近，但概念上混用了两套单位。
-- 第 1129-1131 行的 ITERATIONS_PER_TICK=20 / TIME_PER_TICK=0.1 /
-- SIZE_INTERVAL=50 三者共同决定扫描速度（见 1214 行）。
local IS_CLEAR_AREA_RADIUS = TILE_SCALE * GOOD_ARENA_SQUARE_SIZE
local NO_PLAYER_RADIUS = 35
----------------------------------------------------------------------------------------
-- Land
local GOODARENAPOINTS_CACHE_SIZE_MIN = 50 -- 50 points are good enough for a good placement strategy.
local GOODARENAPOINTS_CACHE_SIZE_MAX = 100 -- Do not exceed hard limit for memory's sake.
local GOODARENAPOINTS_ITERATIONS_PER_TICK = 20
local GOODARENAPOINTS_TIME_PER_TICK = 0.1
local GOODARENAPOINTS_SIZE_INTERVAL = 50 -- Tiles to go by per interval.


local GoodArenaPoints = {}
local GoodArenaPoints_Count = 0
function Map:ClearGoodArenaPoints()
    GoodArenaPoints = {}
    GoodArenaPoints_Count = 0
end
function Map:GetGoodArenaPoints()
    return GoodArenaPoints, GoodArenaPoints_Count
end

local BADARENA_CANT_TAGS = {"tree", "boulder", "spiderden", "okayforarena"}
local BADARENA_ONEOF_TAGS = {"structure", "blocker", "plant", "antlion_sinkhole_blocker"}
function Map:CheckForBadThingsInArena(pt, badthingsatspawnpoints)
-- ★★★ CheckForBadThingsInArena —— 返回值语义【与直觉相反】，务必注意：
--   ★ 返回 true  = 「这里有坏东西 / 不合格」
--   ★ 返回 false = 「这里干净 / 合格」
--  这是【否定语义】（is_bad），所以调用方全在写 if not self:CheckForBad... 。
--  仿写陷阱：一旦有人误当「is_good」用，出生点逻辑会完全反过来。
--
-- 【两级过滤】
--  1) 第 1148 行：脚下 13×13 格必须全是陆地（排除码头），
--     且 NO_PLAYER_RADIUS 内无玩家（避免一开局刷怪在玩家脸上）。
--     短路顺序：地形先查（便宜）、玩家后查（要遍历实体）。
--  2) 第 1149-1155 行：查半径内的障碍实体并计数。
--
-- 【第 1152-1154 行的「反向计数」是本函数最精妙的一处】
--  找到障碍后，若它是 plant 且【不是 transplanted】（未被移植的普通植物），
--  就把计数【减 1】—— 也就是把普通植物从「障碍」里排除掉。
--  ★ 意图：草和花不算障碍（出生点长草很正常），但移植来的植物算。
--  ⚠️ 这里用「先加后减」而不是「查询时就不加」，是为了让 badthingsatspawnpoints
--    记录的计数能反映净障碍数（供第 1258 行做best 选择）。
    local x, y, z = pt.x, pt.y, pt.z
    if self:IsAboveGroundInSquare(x, y, z, GOOD_ARENA_SQUARE_SIZE, self.IsTileLandNoDocks) and not IsAnyPlayerInRange(x, y, z, NO_PLAYER_RADIUS) then
        local badthings = TheSim:FindEntities(x, y, z, IS_CLEAR_AREA_RADIUS, nil, BADARENA_CANT_TAGS, BADARENA_ONEOF_TAGS)
        local badthingscount = #badthings
        for _, v in ipairs(badthings) do
            if (v.components.pickable == nil or not v.components.pickable.transplanted) and v:HasTag("plant") then
                badthingscount = badthingscount - 1
            end
        end
        if badthingsatspawnpoints then
            badthingsatspawnpoints[pt] = badthingscount
        end
        if badthingscount == 0 then
-- 只有【净计数恰好为 0】才算完美点。注意是 == 0 而非 <= 0，
-- 两者等价但 == 更能表达「一个不多一个不少」。
-- ⚠️ 反面情况：若第 1153 行的减法把计数减成负数（普通植物多于障碍），
--   == 0 不成立 → 该点被判为「有坏东西」→ 白白损失一个可用出生点。
--   理论上网格采样内 plant 数量不会压过障碍，但这是脆弱的不变式。
            return false -- No bad things are here.
        end
    end
    return true -- Bad things are here.
end

function Map:StartFindingGoodArenaPoints()
-- ★★★ StartFindingGoodArenaPoints —— 【增量式全图扫描】，本文件最精彩的调度设计。
--
-- 【为什么必须分帧】全图扫描 = (w/50) × (h/50) 个采样点，
--   每个点要查 169 个 tile + 一圈实体。一次性做完会造成明显卡顿。
--   解法：DoPeriodicTask 每 0.1 秒做 20 个点（第 1214 行），
--   把总耗时摊平到多帧 —— 典型的【时间分片（time slicing）】。
--
-- 【第 1167 行先 Stop 是幂等性保障】重复调用不会叠加多个扫描任务。
--
-- 【★ 第 1204-1205 行的随机偏移是本设计最值得学的一点】
--  每一轮完整网格扫描（check_pt.z 越界时）都重新随机一个【亚格子偏移】：
--      check_pt_offset.x = math.random() * check_iter_scale
--  效果：每轮采样点落在不同的亚格位置上，多轮扫描的【并集覆盖率显著提高】。
--  若偏移恒为 0，每轮都在同一批格子上重复检测，扫描一百轮也没有额外收益。
--  ★ 这是「用随机化对抗采样盲区」的低成本手法，移植时直接照抄。
--
-- 【双重停止条件，缺一不可】
--   第 1191 行：达到 CACHE_SIZE_MAX(100) → 立即停（内存上限，第 1128 行注明）
--   第 1206 行：完成【一整轮】扫描且已有 CACHE_SIZE_MIN(50) → 停
--  前者防内存爆掉，后者防「小地图反复扫也扫不满 100 个」时的空转。
--  ★ 后者的语义是「至少要扫完一轮」——部分轮次的结果不算数，
--    因为第 1204 行的随机偏移需要轮次累积才有意义。
    self:StopFindingGoodArenaPoints()

    local w, h = self:GetSize()
    w = w * TILE_SCALE / 2
    h = h * TILE_SCALE / 2
    local check_pt = Vector3(-w, 0, -h)
    local check_iter_scale = GOODARENAPOINTS_SIZE_INTERVAL * TILE_SCALE
    local check_pt_offset = Vector3(0, 0, 0)

    local function DoIteration()
-- DoIteration 是 DoPeriodicTask 的回调：
-- ⚠️ 它是【协程】—— 若内部 yield 会导致周期漂移（bug-patterns A1）。
--  好在 CheckForBadThingsInArena 是纯查询、无 yield，所以这里是安全的。
-- 每次 tick 固定处理 20 个点（GOODARENAPOINTS_ITERATIONS_PER_TICK），
--  即每秒 200 个采样点 → 覆盖整图约需 数秒，符合「后台慢慢填缓存」的预期。
        --print("DoIteration", GoodArenaPoints_Count, check_pt_offset.x, check_pt_offset.z, check_pt.x, check_pt.z)
        for i = 1, GOODARENAPOINTS_ITERATIONS_PER_TICK do
            -- Check.
            if not self:CheckForBadThingsInArena(check_pt) then
                GoodArenaPoints_Count = GoodArenaPoints_Count + 1
                GoodArenaPoints[GoodArenaPoints_Count] = Vector3(check_pt:Get()) -- Copy.
-- ★ Vector3(check_pt:Get()) —— 显式【拷贝】一个新向量。
--  若直接存 check_pt 引用，所有缓存点会指向同一个 Vector3 对象，
--  而第 1197/1199 行在原地修改 check_pt.x/z → 整个缓存全部塌缩成一个点。
-- ★ 这是「循环里复用临时对象」时最容易踩的别名(aliasing) 陷阱。
-- 第 1198 行 x > w 与第 1201 行 z > h 也有同类问题：
--   check_pt.x 每轮只会 +check_iter_scale 重置回 -w + offset.x，
--   因此这条「蛇形扫描」路径的每格步进量是 50 格 → 采样极稀疏。
--   （GOODARENAPOINTS_SIZE_INTERVAL=50，第 1131 行），
--   意味着第 1148 行的 13×13 判定基本覆盖不到格与格之间的间隙。
--   这是【有意的性能取舍】：宁可漏点也不能卡帧。
                --local id, index = self:GetTopologyIDAtPoint(check_pt:Get())
                --local r = (
                --    id:find("BigBatCave") or id:find("RockyLand") or id:find("SpillagmiteCaverns") or id:find("LichenLand") or
                --    id:find("BlueForest") or id:find("RedForest") or id:find("GreenForest")
                --) and true or false
                --if r then
                --    SpawnPrefab("bluemooneye").Transform:SetPosition(check_pt:Get())
                --end
                if GoodArenaPoints_Count >= GOODARENAPOINTS_CACHE_SIZE_MAX then
                    self:StopFindingGoodArenaPoints()
                end
            end

            -- Iterate.
            check_pt.x = check_pt.x + check_iter_scale
            if check_pt.x > w then
                check_pt.x = -w + check_pt_offset.x
                check_pt.z = check_pt.z + check_iter_scale
                if check_pt.z > h then
                    check_pt.z = -h + check_pt_offset.z
                    -- Restart whole grid scan happened here get a new offset.
                    check_pt_offset.x = math.random() * check_iter_scale
                    check_pt_offset.z = math.random() * check_iter_scale
                    if GoodArenaPoints_Count >= GOODARENAPOINTS_CACHE_SIZE_MIN then
                        -- We have at least the cache size from one scan stop finding more.
                        self:StopFindingGoodArenaPoints()
                    end
                end
            end
        end
    end
    TheWorld._GoodArenaPoints_Task = TheWorld:DoPeriodicTask(GOODARENAPOINTS_TIME_PER_TICK, DoIteration)
-- 任务句柄存在 TheWorld 上（第 1217-1219 行用它来Cancel）。
-- ★ 为什么存 TheWorld 而不是局部 upvalue：
--   因为 Map 的方法之间要能互相 Stop（见第 1167、1192、1208 行），
--   跨方法共享状态需要一个公共落脚点。用 TheWorld._<Name>_Task 是本文件的惯例。
-- ⚠️ 惯例风险：字段名以 _ 开头避免与业务字段冲突，
--   但这也意味着若两个 mod 都用同名会互相Cancel 对方的任务。
end
function Map:StopFindingGoodArenaPoints()
    if TheWorld._GoodArenaPoints_Task ~= nil then
        TheWorld._GoodArenaPoints_Task:Cancel()
        TheWorld._GoodArenaPoints_Task = nil
    end
end

function Map:FindBestSpawningPointForArena(CustomAllowTest, perfect_only, spawnpoints)
-- ★★★ FindBestSpawningPointForArena —— 【四级降级策略】，全文件最该精读的算法。
--
-- 【第 0 级：准备】
--  第 1228 行shuffleArray(GoodArenaPoints) —— ★ 直接打乱【模块级缓存本身】，
--    不是打乱副本。这样每次调用都是不同的起点，避免总选同一个点。
--    ⚠️ 但它就地修改了全局缓存（顺序变了，内容没变），是有意为之。
--  spawnpoints 参数存在时用外部传入的（此时不打乱）——
--    这就是「第 1248 行 spawnpoints == GoodArenaPoints 的身份比较」能成立的原因：
--    Lua 的 table 比较是【引用相等】，用它来判断「我没用外部点」。
--
-- 【第 1 级：完美点】第 1240-1245 行
--  遍历所有候选，要求 CustomAllowTest 通过【且】无障碍 → 立即返回。
--  ★短路顺序好：CustomAllowTest 先跑（通常最便宜），命中就直接返回，
--    不再调昂贵的 CheckForBadThingsInArena。
--  ★ 顺带把每个点的障碍数记进 badthingsatspawnpoints（第 1232 行建表），
--    为第 2 级准备 —— 用【一次遍历填两用】避免二次扫描。
--
-- 【第 1.5 级：只要完美就放弃】第 1247-1254 行
--  perfect_only 为真时找不到完美点，返回 nil 并【顺带补充缓存】
--  （Clear + Start 让后台继续扫）。
--  ★ 这是很务实的自愈设计：调用方拿不到点→ 触发更多扫描 → 下次可能就有了。
--
-- 【第 2 级：障碍最少的点】第 1257-1263 行
--  ⚠️⚠️ 已核实的真实缺陷（第 1258-1262 行）：
--  local best_count = 999999
--  for v, badthingscount in pairs(badthingsatspawnpoints) do
--      if badthingscount < best_count then
--          best_count = badthingscount
--          return v.x, v.y, v.z
--      end
--  end
--  ★ 第 1261 行的 return 【写在 if 块内部】。
--    于是循环【第一次迭代就return】，根本不会比较完所有点。
--    即「取 pairs 遍历的第一个点」，而非「取障碍最少的点」。
--    变量名 best_count 完全误导——赋值后立刻返回，从未被用于比较第二次。
--  我已逐行核对第 1257-1263 行的缩进与 end 配对，return 确实在 if 内。
--  同样的缺陷原样出现在第 1414-1420 行（海洋版），可见是复制粘贴。
--  正确写法应为：循环内只记录最优项，循环【外】再 return。
--  ⚠️ 实际影响被前面的降级掩盖：第 2 级只在「有障碍但非完美」时触发，
--    而 pairs 的遍历顺序不确定，所以最终出生点仍「看起来正常」，
--    只是没有真正做到「最少障碍」。这正是这类缺陷长期存活的原因。
--
-- 【第 3 级：找一块空地】第 1267-1281 行
--  随机挑一个点，然后以 5/10/15 三个递增半径调用 FindWalkableOffset 找偏移。
--  IsValidSpawningPoint_Bridge 回调只要求 13×13 格是陆地 ——
--  ★ 放宽了「无障碍」的要求，只要求「有地」，并放回 x/z（第 1277-1278 行）。
--  ★ 递增半径（5,10,15）配合随机起始角度，是「先小范围试，不行再扩大」的阶梯搜索，
--    比一次性用大范围更快找到近解，且结果更集中（更像正经出生点）。
    if not spawnpoints then
        -- If spawnpoints is nil use the cached good points as reference.
        spawnpoints = GoodArenaPoints
        -- Shuffle the points around randomly.
        shuffleArray(GoodArenaPoints)
    end


    local badthingsatspawnpoints = {}
    local x, y, z
    local spawnpointscount = #spawnpoints
    if spawnpointscount == 0 then
        return nil, nil, nil -- No point.
    end

    -- Perfect test for an ideal arena.
    for i, v in ipairs(spawnpoints) do
        x, y, z = v.x, v.y, v.z
        if CustomAllowTest(self, x, y, z) and not self:CheckForBadThingsInArena(v, badthingsatspawnpoints) then
            return x, y, z -- No bad things nearby and roomy for tiles very good point.
        end
    end

    if perfect_only then
        if spawnpoints == GoodArenaPoints then
            -- There are no good arena points for what called this so let us try to make more good ones for the cache.
            self:ClearGoodArenaPoints()
            self:StartFindingGoodArenaPoints()
        end
        return nil, nil, nil
    end

    -- Try a best case if structures are okay to get.
    local best_count = 999999
    for v, badthingscount in pairs(badthingsatspawnpoints) do
        if badthingscount < best_count then
            best_count = badthingscount
            return v.x, v.y, v.z
        end
    end


    -- Try to find something ground available.
    local pt = spawnpoints[math.random(spawnpointscount)]
    x, y, z = pt.x, pt.y, pt.z

    local function IsValidSpawningPoint_Bridge(pt)
        return self:IsAboveGroundInSquare(pt.x, pt.y, pt.z, GOOD_ARENA_SQUARE_SIZE, self.IsTileLandNoDocks)
    end
    
    for r = 5, 15, 5 do
-- for r = 5, 15, 5 —— Lua 的三参for：起点5、终点15、步长5 → r 取5/10/15。
-- FindWalkableOffset(点, 随机角度, 半径, 8, false, false, 判定函数)：
--  第 3 参 r 是搜索半径、第 4 参 8 是环上的采样数、最后是自定义合法性回调。
-- ★ 传入随机角度 math.random()*TWOPI 使每次尝试方向不同，避免每次都朝同一边找。
-- ⚠️ 只尝试 3 次（r=5/10/15），第 4 次就放弃并落回第 1268 行的原坐标。
--   此时 x/y/z 已非nil → 第 1283 行的 if not x 不成立 → 直接 return 原点。
        local offset = FindWalkableOffset(pt, math.random() * TWOPI, r, 8, false, false, IsValidSpawningPoint_Bridge)
        if offset ~= nil then
            x = x + offset.x
            z = z + offset.z
            return x, y, z -- Do not care for amount of structures but it is roomy for tiles.
        end
    end

    if not x then
-- ⚠️ 已核实的死代码（第 1283 行）：if not x then
--  第 1268 行已执行 x, y, z = pt.x, pt.y, pt.z —— x 必非 nil；
--  且第 1274-1281 行的循环要么 return 要么不改x。
--  所以这个 if 【永远为假】，其内部的「补充缓存」逻辑（第 1284-1288 行）
--  是【死代码】，永不执行。
--  对照第 1247-1254 行：那里在 return【之前】做了 Clear + Start，
--  是有效的。这处显然是复制第 1284 行的注释块时改错了位置。
--  ★ 真实后果：当第 3 级搜索失败时，本应触发的「缓存耗尽后补充扫描」没有发生，
--    缓存会一直停在旧数据上，直到下一次 perfect_only 调用（第 1250 行）才补。
--  同样的死代码出现在第 1440-1446 行（海洋版）。
        if spawnpoints == GoodArenaPoints then
            -- There are no good arena points for what called this so let us try to make more good ones for the cache.
            self:ClearGoodArenaPoints()
            self:StartFindingGoodArenaPoints()
        end
    end

    return x, y, z
end
-- Land
----------------------------------------------------------------------------------------
-- Ocean
local GOODOCEANARENAPOINTS_CACHE_SIZE_MIN = 50 -- 50 points are good enough for a good placement strategy.
-- ★ 海洋版的四个魔数与陆地版（第 1127-1131 行）几乎相同，唯一差异是
--   TIME_PER_TICK = 0.2（陆地 0.1）—— 海洋扫描慢一半，
--   因为海洋判定（IsSurroundedByWater / 找船）成本更高。
-- ★【整个第 1293-1449 行几乎逐行复制陆地版】只替换了三个谓词：
--   CheckForBadThingsInArena → CheckForBadThingsInOceanArena
--   IsTileLandNoDocks→ IsTileOcean
--   GoodArenaPoints → GoodOceanArenaPoints
-- 两次停止条件、一个死代码、一个 best_count 缺陷都原样继承。
-- 【移植建议】这正是应该抽成「参数化模板」的场景：
--   把差异收敛成 { 判定函数, 缓存名, 标签集, 时间参数 } 四个参数，
--   两套实现共用一个骨架。Klei 用复制粘贴，说明这是历史债务而非设计。
local GOODOCEANARENAPOINTS_CACHE_SIZE_MAX = 100 -- Do not exceed hard limit for memory's sake.
local GOODOCEANARENAPOINTS_ITERATIONS_PER_TICK = 10
local GOODOCEANARENAPOINTS_TIME_PER_TICK = 0.2
local GOODOCEANARENAPOINTS_SIZE_INTERVAL = 50 -- Tiles to go by per interval.


local GoodOceanArenaPoints = {}
local GoodOceanArenaPoints_Count = 0
function Map:ClearGoodOceanArenaPoints()
    GoodOceanArenaPoints = {}
    GoodOceanArenaPoints_Count = 0
end
function Map:GetGoodOceanArenaPoints()
    return GoodOceanArenaPoints, GoodOceanArenaPoints_Count
end

local BADOCEANARENA_CANT_TAGS = {"tree", "boulder", "spiderden", "okayforarena", "FX", "DECOR", "NOCLICK"}
-- 与陆地版（第 1144-1145 行）对比，海洋版标签集有两处增减：
--  CANT 增加 FX / DECOR / NOCLICK —— 海面上装饰与特效更多，需要排除
--  ONEOF 增加 ignorewalkableplatforms —— ★ 船本身不该算障碍
-- ⚠️ 但 CANT 里删掉了 "plant" 相关处理 → 海洋版没有陆地版第 1152-1154 行
--   那个「普通植物不算障碍」的减法。这是合理的（海里没草），
--   但也说明两版逻辑已产生实质差异，复制粘贴的维护成本是真实的。
local BADOCEANARENA_ONEOF_TAGS = {"structure", "blocker", "antlion_sinkhole_blocker", "ignorewalkableplatforms"}
function Map:CheckForBadThingsInOceanArena(pt, badthingsatspawnpoints)
    local x, y, z = pt.x, pt.y, pt.z
    if self:IsAboveGroundInSquare(x, y, z, GOOD_ARENA_SQUARE_SIZE, self.IsTileOcean) and not IsAnyPlayerInRange(x, y, z, NO_PLAYER_RADIUS) then
        local badthings = TheSim:FindEntities(x, y, z, IS_CLEAR_AREA_RADIUS, nil, BADOCEANARENA_CANT_TAGS, BADOCEANARENA_ONEOF_TAGS)
        local badthingscount = #badthings
        if badthingsatspawnpoints then
            badthingsatspawnpoints[pt] = badthingscount
        end
        if badthingscount == 0 then
            return false -- No bad things are here.
        end
    end
    return true -- Bad things are here.
end

function Map:StartFindingGoodOceanArenaPoints()
    self:StopFindingGoodOceanArenaPoints()

    local w, h = self:GetSize()
    w = w * TILE_SCALE / 2
    h = h * TILE_SCALE / 2
    local check_pt = Vector3(-w, 0, -h)
    local check_iter_scale = GOODOCEANARENAPOINTS_SIZE_INTERVAL * TILE_SCALE
    local check_pt_offset = Vector3(0, 0, 0)

    local function DoIteration()
        --print("DoIteration", GoodOceanArenaPoints_Count, check_pt_offset.x, check_pt_offset.z, check_pt.x, check_pt.z)
        for i = 1, GOODOCEANARENAPOINTS_ITERATIONS_PER_TICK do
            -- Check.
            if not self:CheckForBadThingsInOceanArena(check_pt) then
                GoodOceanArenaPoints_Count = GoodOceanArenaPoints_Count + 1
                GoodOceanArenaPoints[GoodOceanArenaPoints_Count] = Vector3(check_pt:Get()) -- Copy.
                --SpawnPrefab("sentryward").Transform:SetPosition(check_pt:Get())
                if GoodOceanArenaPoints_Count >= GOODOCEANARENAPOINTS_CACHE_SIZE_MAX then
                    self:StopFindingGoodOceanArenaPoints()
                end
            end

            -- Iterate.
            check_pt.x = check_pt.x + check_iter_scale
            if check_pt.x > w then
                check_pt.x = -w + check_pt_offset.x
                check_pt.z = check_pt.z + check_iter_scale
                if check_pt.z > h then
                    check_pt.z = -h + check_pt_offset.z
                    -- Restart whole grid scan happened here get a new offset.
                    check_pt_offset.x = math.random() * check_iter_scale
                    check_pt_offset.z = math.random() * check_iter_scale
                    if GoodOceanArenaPoints_Count >= GOODOCEANARENAPOINTS_CACHE_SIZE_MIN then
                        -- We have at least the cache size from one scan stop finding more.
                        self:StopFindingGoodOceanArenaPoints()
                    end
                end
            end
        end
    end
    TheWorld._GoodOceanArenaPoints_Task = TheWorld:DoPeriodicTask(GOODOCEANARENAPOINTS_TIME_PER_TICK, DoIteration)
end
function Map:StopFindingGoodOceanArenaPoints()
    if TheWorld._GoodOceanArenaPoints_Task ~= nil then
        TheWorld._GoodOceanArenaPoints_Task:Cancel()
        TheWorld._GoodOceanArenaPoints_Task = nil
    end
end

function Map:FindBestSpawningPointForOceanArena(CustomAllowTest, perfect_only, spawnpoints)
-- FindBestSpawningPointForOceanArena：与陆地版（第 1223 行）逐行对应，
-- 包括第 1415-1418 行同一个 best_count 缺陷（return 在 if 内、首次迭代即返回）。
-- 第 1385 行的 shuffleArray 同样就地打乱全局缓存 GoodOceanArenaPoints。
    if not spawnpoints then
        -- If spawnpoints is nil use the cached good points as reference.
        spawnpoints = GoodOceanArenaPoints
        -- Shuffle the points around randomly.
        shuffleArray(GoodOceanArenaPoints)
    end


    local badthingsatspawnpoints = {}
    local x, y, z
    local spawnpointscount = #spawnpoints
    if spawnpointscount == 0 then
        return nil, nil, nil -- No point.
    end

    -- Perfect test for an ideal arena.
    for i, v in ipairs(spawnpoints) do
        x, y, z = v.x, v.y, v.z
        if CustomAllowTest(self, x, y, z) and not self:CheckForBadThingsInOceanArena(v, badthingsatspawnpoints) then
            return x, y, z -- No bad things nearby and roomy for tiles very good point.
        end
    end

    if perfect_only then
        if spawnpoints == GoodOceanArenaPoints then
            -- There are no good arena points for what called this so let us try to make more good ones for the cache.
            self:ClearGoodOceanArenaPoints()
            self:StartFindingGoodOceanArenaPoints()
        end
        return nil, nil, nil
    end

    -- Try a best case if structures are okay to get.
    local best_count = 999999
    for v, badthingscount in pairs(badthingsatspawnpoints) do
        if badthingscount < best_count then
            best_count = badthingscount
            return v.x, v.y, v.z
        end
    end


    -- Try to find something ground available.
    local pt = spawnpoints[math.random(spawnpointscount)]
    x, y, z = pt.x, pt.y, pt.z

    local function IsValidSpawningPoint_Bridge(pt)
        return self:IsAboveGroundInSquare(pt.x, pt.y, pt.z, GOOD_ARENA_SQUARE_SIZE, self.IsTileOcean)
    end
    
    for r = 5, 15, 5 do
        local offset = FindWalkableOffset(pt, math.random() * TWOPI, r, 8, false, false, IsValidSpawningPoint_Bridge, true)
        if offset ~= nil then
            x = x + offset.x
            z = z + offset.z
            return x, y, z -- Do not care for amount of structures but it is roomy for tiles.
        end
    end

    if not x then
        if spawnpoints == GoodOceanArenaPoints then
            -- There are no good arena points for what called this so let us try to make more good ones for the cache.
            self:ClearGoodOceanArenaPoints()
            self:StartFindingGoodOceanArenaPoints()
        end
    end

    return x, y, z
end
-- Ocean
----------------------------------------------------------------------------------------

function Map:IsPointInSharkBoiArena(x, y, z)
-- ★★★ 接下来的 ~110 行是【统一转发模式】，与前面的算法代码风格截然不同。
-- 【七个别名函数（第 1453-1522 行）全部是 WagPunk 竞技场的转发】
--  SharkBoiArena         ——  Shark 控制的竞技场
--  WagPunkArena          ——  WagPunk 控制的竞技场
--   +BarrierIsUp           ——  额外要求结界升起（两个变体）
--  XZWithThickness        ——  带厚度的矩形判定（两个变体）
--  GetWagPunkArenaCenterXZ ——  取中心坐标
--  IsWagPunkArenaBarrierUp——  单独查结界状态
--
-- 【★ 三条硬性约定，抄这段必须遵守】
--  1) 全部走 world.net.components.*（第 1455、1464、1473、1486、1495、1508、1517 行）：
--     也就是说这些数据住在【客户端的 replica 侧】而非服务端。
--     ★ 理由很实际：竞技场的形状是客户端已知的静态数据，
--       放replica 才能让服务端在判定建造时同步读到，而不必每帧跨网查询。
--       第 264 行 IsDeployPointClear 每次建造判定都要调它，必须是本地读取。
--  2) 每个函数开头都是 world.net == nil 或 helper == nil 的双重 nil 检查。
--     ★ 原因：第 2 行就return false「没有这个 DLC 时一律当作不在区域内」，
--       这让所有调用方【无需自己判断 DLC 是否安装】——
--       没买DLC 的玩家不会崩，也不会被结界误伤。
--  3) 同样的检查重复了 7 遍而没有抽成helper：
--     ⚠️ 这本身是个可改进点。抽一个 local function GetWagPunkHelper()
--       能省掉 6 份重复。抄写时建议抽取。
--
-- 【★ 四个 WagPunk 转发函数里，只有「+BarrierIsUp」的两个才先查结界】
--  顺序：先 IsBarrierUp() 再 IsPointInArena()。
--  ⚠️ 这意味着 【没有结界的 WagPunk 竞技场是可以正常建造的】——
--    而第 264 行 IsDeployPointClear 用的是 AndBarrierIsUp 版本（第 264 行），
--    所以「结界没升时不禁建」正是设计意图，而非疏漏。
    local world = TheWorld
    if world.net == nil or world.net.components.sharkboimanagerhelper == nil then
        return false
    end

    return world.net.components.sharkboimanagerhelper:IsPointInArena(x, y, z)
end

function Map:IsPointInWagPunkArena(x, y, z)
    local world = TheWorld
    if world.net == nil or world.net.components.wagpunk_floor_helper == nil then
        return false
    end

    return world.net.components.wagpunk_floor_helper:IsPointInArena(x, y, z)
end

function Map:IsPointInWagPunkArenaAndBarrierIsUp(x, y, z)
-- 禁建判定的实际入口。第 264 行 IsDeployPointClear 与第 298 行
-- IsDeployPointClear2 都以它开头 —— 也就是【所有建造与施法都受它管】。
-- ★ 这是「把一条业务规则埋进最底层通用函数」的典型做法：
--   代价是通用函数不再通用（认识了一个具体 DLC 的概念）；
--   好处是新 DLC 不需要改任何建造代码，加helper 组件即可生效。
-- 对DST 这种重度mod化的游戏，收益明显大于代价。
    local world = TheWorld
    if world.net == nil or world.net.components.wagpunk_floor_helper == nil then
        return false
    end

    if not world.net.components.wagpunk_floor_helper:IsBarrierUp() then
        return false
    end

    return world.net.components.wagpunk_floor_helper:IsPointInArena(x, y, z)
end

function Map:IsXZWithThicknessInWagPunkArena(x, z, thickness)
    local world = TheWorld
    if world.net == nil or world.net.components.wagpunk_floor_helper == nil then
        return false
    end

    return world.net.components.wagpunk_floor_helper:IsXZWithThicknessInArena(x, z, thickness)
end

function Map:IsXZWithThicknessInWagPunkArenaAndBarrierIsUp(x, z, thickness)
    local world = TheWorld
    if world.net == nil or world.net.components.wagpunk_floor_helper == nil then
        return false
    end

    if not world.net.components.wagpunk_floor_helper:IsBarrierUp() then
        return false
    end

    return world.net.components.wagpunk_floor_helper:IsXZWithThicknessInArena(x, z, thickness)
end

function Map:GetWagPunkArenaCenterXZ()
    local world = TheWorld
    if world.net == nil or world.net.components.wagpunk_floor_helper == nil then
        return nil, nil
    end

    return world.net.components.wagpunk_floor_helper:GetArenaOrigin()
end

function Map:IsWagPunkArenaBarrierUp()
    local world = TheWorld
    if world.net == nil or world.net.components.wagpunk_floor_helper == nil then
        return false
    end

    return world.net.components.wagpunk_floor_helper:IsBarrierUp()
end

function Map:IsPointInVaultRoom(x, y, z)
-- ★★ Vault 相关三个函数的【两级结构】，注释本身就说清了优化意图：
-- 【为什么要有「大厅(lobby)」的廉价预判】
--  IsPointInVaultRoom 走网络组件查询（第 1532 行）；
--  但绝大多数点根本不在金库里，用它逐点判定太贵。
--  所以先用【格子标签】廉价筛：HasAdjacentTileFiltered(tx, ty, IsVaultTile)
--  —— 邻接格里有 VAULT tile 才值得进一步问。
-- 第 1525-1526 行注释解释：房间内的 tile 可能已不是 vault tile 了，
-- 所以才需要服务端把 vault 位置同步过来做精确判定。
-- ★ 这是「廉价过滤 + 精确确认」两段式，很标准的性能模式。
-- ⚠️ 注意 IsPointInVaultLobby（第 1537 行）比 IsPointInAnyVault（第 1548 行）
--   【多一次 IsVisualGroundAtPoint 判断】，用于排除「悬空层在大厅上方」。
--   最宽松的 IsPointInOrAdjacentToAnyVault（第 1560 行）连这个判断都没有。
--   三个函数是「越来越宽松」的阶梯，选错会误判（太严漏掉 / 太松误伤）。
    -- The vault's rooms can have the tiles no longer vault tiles so we will need to do one last check.
    -- The server will network over the position of the vault so the client can force include a square from the position.
    local world = TheWorld
    if world.net == nil or world.net.components.vault_floor_helper == nil then
        return false
    end

    return world.net.components.vault_floor_helper:IsPointInVaultRoom_Internal(x, y, z)
end
local function IsVaultTile(tileid)
    return tileid == WORLD_TILES.VAULT
end
function Map:IsPointInVaultLobby(x, y, z)
-- ★ 第 1538 行注释自陈了这个函数的脆弱假设：
--   "makes the assumption for vault tiles being always secluded from anything
--    and covers the entire vault floor"
-- 即「假设 vault tile 总与外界隔绝，且铺满整个金库地板」。
-- ⚠️ 一旦 mod 在金库里铺了非 vault 的地板，IsVisualGroundAtPoint 仍为真，
--   但 HasAdjacentTileFiltered 会失败 → 该点被判为「不在大厅」→
--   禁建失效。这是【基于世界生成不变量的优化】的典型代价。
-- 与 IsPointInAnyVault 的区别：后者会继续走网络查询兜底（第 1558 行），
-- 所以更可靠但更贵。安全相关的判定应选后者。
    -- NOTES(JBK): This is a very quick check and makes the assumption for vault tiles being always secluded from anything and covers the entire vault floor.
    local tx, ty = self:GetTileCoordsAtPoint(x, 0, z)
    if self:HasAdjacentTileFiltered(tx, ty, IsVaultTile) then
        if self:IsVisualGroundAtPoint(x, y, z) then
            return not self:IsPointInVaultRoom(x, y, z)
        end
    end

    return false
end
function Map:IsPointInAnyVault(x, y, z)
    -- Optimizations for not caring which vault section the point is in.
    -- Lobby
    local tx, ty = self:GetTileCoordsAtPoint(x, 0, z)
    if self:HasAdjacentTileFiltered(tx, ty, IsVaultTile) then
        if self:IsVisualGroundAtPoint(x, y, z) then
            return true
        end
    end
    -- Room
    return self:IsPointInVaultRoom(x, y, z)
end
function Map:IsPointInOrAdjacentToAnyVault(x, y, z)
-- 最宽松的版本：只要邻接 vault tile 就返回 true，连 IsVisualGround 都不查。
-- ★ 用途是【只做否定判定】——第 518 行 CanDeployBridgeAtPointWithFilter
--   用它做「禁建桥」检查。误判方向是「把非金库点当成金库」→ 少放一座桥，
--   比「在金库里放了桥」安全得多。
-- 【三个Vault 函数的选用原则：宁可误判为「是金库」也不要误判为「不是」】
--   因为它们几乎都用在「禁止建造」的语境里，false 才是危险方向。
--   移植时若新增用法（允许建造），务必重新评估这个方向性。
    -- Optimizations for not caring which vault section the point is in.
    -- Lobby
    local tx, ty = self:GetTileCoordsAtPoint(x, 0, z)
    if self:HasAdjacentTileFiltered(tx, ty, IsVaultTile) then
        return true
    end
    -- Room
    return self:IsPointInVaultRoom(x, y, z)
end
