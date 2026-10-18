--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/builder.lua
-- 模块：组件系统 / 建造（Builder）
-- 职责：配方解锁管理（科技树 EvaluateTechTrees）、材料检查与扣除
--       （HasIngredients / RemoveIngredients）、物品制造与放置（DoBuild）、
--       工作台与原型站（prototyper / craftingstation）权限判定、
--       缓冲建造（客户端预测）、连续建造的饥饿节流、配方存档与同步。
-- 关键符号：Builder, DoBuild, KnowsRecipe, HasIngredients, GetIngredients,
--           RemoveIngredients, EvaluateTechTrees, UnlockRecipe,
--           UnlockRecipesForTech, MakeRecipe, MakeRecipeAtPoint, BufferBuild,
--           SetBuildBuffered, GetTechBonuses, GetTempTechBonuses
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：recipe.lua（配方静态定义）, components/hunger.lua（饥饿代价）,
--           components/inventory.lua（材料来源容器）,
--           components/prototyper.lua（原型站权限）,
--           components/craftingstation.lua（工作台配方表）,
--           components/petleash.lua（孤儿类配方宠物栏位）,
--           components/ridermount.lua（骑乘限制）,
--           skillsystem.lua（builder_skill 校验）,
--           class.lua（属性 setter 元表机制）
--============================================================
local TechTree = require("techtree")
--[[
-- builder.lua —— 建造组件（Builder）
--
-- 职责：配方解锁管理（科技树）、材料检查与扣除、物品制造与放置。
-- 与 combat.lua 的对照：Combat 决定「打谁打多少」，Builder 决定「造什么花多少」，
-- 两者共享同一种设计风格——把校验、副作用、事件通知严格分成三段。
--
-- 【最重要的三段结构，全文件反复出现】
--   1) 前置校验（能不能造）—— freebuildmode / tech tree / builder_tag / station
--   2) 副作用   （真的做）—— RemoveIngredients / SpawnPrefab
--   3) 事件通知 （通知外部）—— PushEvent("builditem")
-- 顺序很重要：校验必须在副作用之前，事件必须在副作用之后。
-- 下方 DoBuild 有一个反例（先PushEvent 再检查材料），值得单独留意。
--
-- 【移植要点】配方解锁用「科技树（tech tree）+ tag」双轨：
--   tech tree 管「造物科技」等级，tag 管「角色专属」限制。两者正交，不要混用。
--]]

local function oningredientmod(self, ingredientmod)
    assert(INGREDIENT_MOD[ingredientmod] ~= nil, "Ingredient mods restricted to certain values, see constants.lua INGREDIENT_MOD")
    self.inst.replica.builder:SetIngredientMod(ingredientmod)
end

local function onfreebuildmode(self, freebuildmode)
    self.inst.replica.builder:SetIsFreeBuildMode(freebuildmode)
end

local function on_current_prototyper(self, current_prototyper)
	self.inst.replica.builder:SetCurrentPrototyper(current_prototyper)
end

local function metafn()
-- 组件元表：class.lua 用它做属性 setter 绑定。
-- on_xxx 形式的键会在 self.xxx 被赋值时自动触发同名回调，
-- 这样「属性变更」这件事不需要在每个赋值点手写if。
	local t =	{
		ingredientmod = oningredientmod,
		freebuildmode = onfreebuildmode,
		current_prototyper = on_current_prototyper,
	}
    for i, v in ipairs(TechTree.BONUS_TECH) do
        t[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] = function(self, bonus) self.inst.replica.builder:SetTechBonus(string.lower(v), bonus) end
        t[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"] = function(self, bonus) self.inst.replica.builder:SetTempTechBonus(string.lower(v), (bonus or 0)) end
    end
	return t
end

local Builder = Class(function(self, inst)
    self.inst = inst

    self.recipes = {}
    self.station_recipes = {}
    self.accessible_tech_trees = TechTree.Create()
    self.accessible_tech_trees_no_temp = TechTree.Create()
	self.old_accessible_tech_trees = {}
    self.inst:StartUpdatingComponent(self)
    self.current_prototyper = nil
    self.buffered_builds = {}

    for i, v in ipairs(TechTree.BONUS_TECH) do
        self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] = 0
    end
    self.ingredientmod = 1
    --self.last_hungry_build = nil
    --self.last_hungry_build_pt = nil

    self.freebuildmode = false

    self.inst.replica.builder:SetTechTrees(self.accessible_tech_trees)
    for k, v in pairs(AllRecipes) do
        if IsRecipeValid(v.name) then
            self.inst.replica.builder:SetIsBuildBuffered(v.name, false)
        end
    end

    self.exclude_tags = { "INLIMBO", "fire" }
    for k, v in pairs(CUSTOM_RECIPETABS) do
        if v.owner_tag ~= nil and not inst:HasTag(v.owner_tag) then
            table.insert(self.exclude_tags, v.owner_tag)
        end
    end
end,
nil,
metafn()
)

function Builder:ActivateCurrentResearchMachine(recipe)
    if self.current_prototyper ~= nil and
        self.current_prototyper.components.prototyper ~= nil and
        self.current_prototyper:IsValid() then
        self.current_prototyper.components.prototyper:Activate(self.inst, recipe)
    end
end

local function CheckHungryDistance(inst, last_hungry_build_pt)
    return inst:GetDistanceSqToPoint(last_hungry_build_pt) > TUNING.HUNGRY_BUILDER_RESET_DISTANCE_SQ
end

function Builder:OnSave()
-- OnSave：只存「解锁状态」，不存 tech tree 本身。
-- 理由：tech tree 是全局静态数据（recipe.lua 里定义），存档只需记录玩家点亮了哪些。
-- 这是重要的存档设计原则——静态配置不入档，动态状态才入档。
    local hungrytime = self.last_hungry_build ~= nil and math.ceil(GetTime() - self.last_hungry_build) or math.huge
    hungrytime = hungrytime < TUNING.HUNGRY_BUILDER_RESET_TIME and hungrytime or nil
    local hungrypt = self.last_hungry_build_pt and not CheckHungryDistance(self.inst, self.last_hungry_build_pt) and {x=self.last_hungry_build_pt.x, y=self.last_hungry_build_pt.y, z=self.last_hungry_build_pt.z} or nil

    local tempbonuses = self:GetTempTechBonuses()

    return
    {
        buffered_builds = self.buffered_builds,
        recipes = self.recipes,
        hungrytime = hungrytime,
        hungrypt = hungrypt,
        tempbonuses = tempbonuses,
        temptechbonus_count = self.temptechbonus_count,
    }
end

function Builder:OnLoad(data)
    if data.buffered_builds ~= nil then
        for k, v in pairs(AllRecipes) do
            if data.buffered_builds[k] ~= nil and IsRecipeValid(v.name) then
                self:SetBuildBuffered(v.name, true)
            end
        end
    end

    if data.recipes ~= nil then
        for i, v in ipairs(data.recipes) do
            if IsRecipeValid(v) then
                self:AddRecipe(v)
            end
        end
    end

    if data.hungrytime ~= nil then
        self.last_hungry_build = GetTime() - data.hungrytime
    end
    if data.hungrypt then
        self.last_hungry_build_pt = Point(data.hungrypt.x, data.hungrypt.y, data.hungrypt.z)
    end

    if data.tempbonuses then
        self:GiveTempTechBonus(data.tempbonuses)
        self.temptechbonus_count = data.temptechbonus_count
    end
end

function Builder:IsBuildBuffered(recname)
    return self.buffered_builds[recname]
end

function Builder:OnUpdate()
    self:EvaluateTechTrees()
end

function Builder:GiveAllRecipes()
    self.freebuildmode = not self.freebuildmode
    self.inst:PushEvent("unlockrecipe")
end

local function propertech(recipetree, buildertree)
-- 递归判断某个 tech 是否已解锁：自己是 true，或任一前置 tech 已解锁。
-- 典型的「或依赖」图遍历。注意 propertech 自身也是候选，形成递归。
    for k, v in pairs(recipetree) do
        if buildertree[tostring(k)] ~= nil and
            recipetree[tostring(k)] ~= nil and
            recipetree[tostring(k)] > buildertree[tostring(k)] then
            return false
        end
    end
    return true
end

function Builder:UnlockRecipesForTech(tech)
    for k, v in pairs(AllRecipes) do
        if IsRecipeValid(v.name) and propertech(v.level, tech) then
            self:UnlockRecipe(v.name)
        end
    end
end

function Builder:GetTechBonuses()
-- GetTechBonuses：把已解锁的科技奖励聚合成一个表。
-- 奖励分两类：永久（techbonuses）与临时（temptechbonuses，见 178 行）。
	local bonus = {}
    for i, v in ipairs(TechTree.BONUS_TECH) do
        bonus[v] = self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] or nil
        
        local tempbonus = self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"]
        if tempbonus ~= nil then
            if bonus[v] ~= nil then
                bonus[v] = bonus[v] + tempbonus
            else
                bonus[v] = tempbonus
            end
        end
    end

	return bonus
end

function Builder:GetTempTechBonuses()
-- ★ 临时科技加成：与永久加成分离，可被 ConsumeTempTechBonuses 消耗。
-- 典型用途是「一次性道具给的临时科技」，用完即清。
-- 分离的好处：永久加成不会因为临时道具过期而被误清。
    local bonus = {}
    for i, v in ipairs(TechTree.BONUS_TECH) do
        
        local tempbonus = self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"]
        if tempbonus ~= nil then
            bonus[v] = tempbonus
        end
    end

	return bonus
end

function Builder:GiveTempTechBonus(tech)
    for k, v in pairs(tech) do
        self[TechTree.AVAILABLE_TECH_TEMPBONUS[k] or string.lower(k).."_tempbonus"] = v
    end

    if self.temptechbonus_count ~= nil then
        self.temptechbonus_count = self.temptechbonus_count + 1
    else
        self.temptechbonus_count = 1
    end
end

function Builder:ConsumeTempTechBonuses()
	if self.temptechbonus_count == nil then
		--we should NOT reach here normally; only assert in dev branch though!
		assert(BRANCH ~= "dev")
        return
    end

    self.temptechbonus_count = self.temptechbonus_count - 1
    if self.temptechbonus_count < 1 then
        for i, v in ipairs(TechTree.BONUS_TECH) do
            if self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"] ~= nil then
                self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"] = nil
            end
        end

        self.temptechbonus_count = nil
    end
end

local function CopyTechTrees(src, dest)
-- 深拷贝科技树。必须拷贝而非取引用，否则多个玩家会共享同一张表，
-- 一个玩家解锁就会污染全体——这是联机游戏里非常典型的共享可变表陷阱。
	for i, v in ipairs(TechTree.AVAILABLE_TECH) do
		dest[v] = src[v] or 0
	end
end

local function SortByRecName(a, b)
-- 按配方名字母序排序。
-- ⚠️ 注意：排序保证确定性，这在联机同步时很重要——
--   若遍历顺序依赖 pairs 的哈希布局，两端可能得到不同的解锁顺序。
--   同类问题见 bug-patterns B5 / N15。
    if a.recname == b.recname then
        return a.amount < b.amount
    end
    return a.recname < b.recname -- NOTES(JBK): This is not important to be the same on client and server but stable for server for netvar ordering.
end
local PROTOTYPER_TAGS = { "prototyper" }
-- 建造者专属标签。配方可声明 builder_tag / no_builder_tag 来限制谁能造。
-- 用 tag 而非硬编码角色名，新增角色时零改动。
function Builder:EvaluateTechTrees()
-- ★★★ EvaluateTechTrees —— 配方解锁的总判定，KnowsRecipe 的数据来源。
--
-- 【为什么需要「缓存 + 失效」】
-- 判定一个配方是否解锁，需要递归遍历整棵科技树（深度可达十余层）。
-- 若每次 UI 刷新、每次鼠标悬停都重算，会成为帧率杀手。
-- 因此把结果缓存在 station_recipes / self.recipes，
-- 并在 UnlockRecipesForTech 时整体失效重建——
-- 这就是「读多写少」场景的标准缓存策略。
--
-- 【可复用的经验】
--  · 递归判定 + 缓存，是DST 处理「依赖图」的统一套路
--  · 缓存失效点必须与写入点严格对应，漏一个就会出现「解锁了但还是灰色」
--  · 缓存本身要参与存档（OnSave 存它），否则读档后科技全丢
	local enabled = self.inst.player_classified == nil or self.inst.player_classified.iscraftingenabled:value()
    local pos = self.inst:GetPosition()

    local ents
	if self.override_current_prototyper then
		if enabled
			and self.override_current_prototyper:IsValid()
			and self.override_current_prototyper:HasTags(PROTOTYPER_TAGS) 
			and not self.override_current_prototyper:HasOneOfTags(self.exclude_tags)
			and (self.override_current_prototyper.components.prototyper.restrictedtag == nil or self.inst:HasTag(self.override_current_prototyper.components.prototyper.restrictedtag))
			and self.override_current_prototyper.components.prototyper:CanUsePrototyper(self.inst)
			then

			ents = {self.override_current_prototyper}
		else
			self.override_current_prototyper = nil
		end
	end
	
	if enabled and ents == nil then
		ents = TheSim:FindEntities(pos.x, pos.y, pos.z, TUNING.RESEARCH_MACHINE_DIST, PROTOTYPER_TAGS, self.exclude_tags)
	end

	CopyTechTrees(self.accessible_tech_trees, self.old_accessible_tech_trees)
    local old_station_recipes = self.station_recipes
    local old_prototyper = self.current_prototyper
    self.current_prototyper = nil
    self.station_recipes = {}

    local prototyper_active = false
	if ents then
		for i, v in ipairs(ents) do
			if v.components.prototyper and (v.components.prototyper.restrictedtag == nil or self.inst:HasTag(v.components.prototyper.restrictedtag)) then
				if not prototyper_active then
					--activate the first machine in the list. This will be the one you're closest to.
					v.components.prototyper:TurnOn(self.inst)

					--prototyper:GetTrees() returns a deepcopy, which we no longer want
					CopyTechTrees(v.components.prototyper.trees, self.accessible_tech_trees)

					if v.components.craftingstation then
						local recs = v.components.craftingstation:GetRecipes(self.inst)
						for _, recname in ipairs(recs) do
							local recipe = GetValidRecipe(recname)
							if recipe and recipe.nounlock then
								--only nounlock recipes can be unlocked via crafting station
                                local has_unlocked_skin = false
                                if recipe.unlocks_from_skin and (recipe.unlocks_from_skin == SKINUNLOCKS.CRAFTINGSTATION) and self.inst.isplayer then
                                    local prefabskins = PREFAB_SKINS[recipe.product]
                                    if prefabskins ~= nil then
                                        for _, skin in ipairs(prefabskins) do
                                            if TheInventory:CheckClientOwnership(self.inst.userid, skin) then
                                                has_unlocked_skin = true
                                                break
                                            end
                                        end
                                    end
                                else
                                    has_unlocked_skin = true
                                end
                                self.station_recipes[recname] = v.components.craftingstation:GetRecipeCraftingLimit(recipe.name) or has_unlocked_skin or nil
							end
						end
					end

					prototyper_active = true
					self.current_prototyper = v
				else
					--you've already activated a machine. Turn all the other machines off.
					v.components.prototyper:TurnOff(self.inst)
				end
            end
        end
    end

    --V2C: Hacking giftreceiver logic in here so we do
    --     not have to duplicate the same search logic
    if self.inst.components.giftreceiver ~= nil then
        self.inst.components.giftreceiver:SetGiftMachine(
            self.current_prototyper ~= nil and
            self.current_prototyper:HasTag("giftmachine") and
            CanEntitySeeTarget(self.inst, self.current_prototyper) and
            self.inst.components.inventory.isopen and --ignores .isvisible, as long as it's .isopen
            self.current_prototyper or
            nil)
    end

    --add any character specific bonuses to your current tech levels.
	CopyTechTrees(self.accessible_tech_trees, self.accessible_tech_trees_no_temp)
    if not prototyper_active then
        for i, v in ipairs(TechTree.AVAILABLE_TECH) do
            self.accessible_tech_trees_no_temp[v] = (self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] or 0)
            self.accessible_tech_trees[v] = (self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"] or 0) + (self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] or 0)
        end
    else
		for i, v in ipairs(TechTree.BONUS_TECH) do
            self.accessible_tech_trees_no_temp[v] = self.accessible_tech_trees_no_temp[v] + (self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] or 0)
			self.accessible_tech_trees[v] = self.accessible_tech_trees[v] + 
                                            (self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"] or 0) + 
                                            (self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] or 0)
		end
	end

    if old_prototyper ~= nil and
        old_prototyper ~= self.current_prototyper and
        old_prototyper.components.prototyper ~= nil and
        old_prototyper.entity:IsValid() then
        old_prototyper.components.prototyper:TurnOff(self.inst)
    end

    local trees_changed = false

    local craftinglimitdata
    local lostcraftinglimitdata
    for recname, amount in pairs(self.station_recipes) do
        if old_station_recipes[recname] then
            if old_station_recipes[recname] ~= amount then
                trees_changed = true
            end
            old_station_recipes[recname] = nil
        else
            self.inst.replica.builder:AddRecipe(recname)
            trees_changed = true
        end
        if amount ~= true then -- We have a max number allowed, add it.
            if craftinglimitdata == nil then
                craftinglimitdata = {}
            end
            table.insert(craftinglimitdata, {recname = recname, amount = amount,})
        end
    end

    if next(old_station_recipes) ~= nil then
        for recname, amount in pairs(old_station_recipes) do
            self.inst.replica.builder:RemoveRecipe(recname)
            if amount ~= true then
                lostcraftinglimitdata = true
            end
        end
		trees_changed = true
    end

    if craftinglimitdata then
        table.sort(craftinglimitdata, SortByRecName)
        for i = 1, CRAFTINGSTATION_LIMITED_RECIPES_COUNT do
            local data = craftinglimitdata[i]
            if data then
                self.inst.replica.builder:SetRecipeCraftingLimit(i, data.recname, data.amount)
            else
                self.inst.replica.builder:SetRecipeCraftingLimit(i, nil, nil)
            end
        end
    elseif lostcraftinglimitdata then
        for i = 1, CRAFTINGSTATION_LIMITED_RECIPES_COUNT do
            self.inst.replica.builder:SetRecipeCraftingLimit(i, nil, nil)
        end
    end

    if not trees_changed then
        for k, v in pairs(self.old_accessible_tech_trees) do
            if v ~= self.accessible_tech_trees[k] then
                trees_changed = true
                break
            end
        end
		--V2C: not required anymore; both trees should have the same keys now
        --[[if not trees_changed then
            for k, v in pairs(self.accessible_tech_trees) do
                if v ~= self.old_accessible_tech_trees[k] then
                    trees_changed = true
                    break
                end
            end
        end]]
    end

    if trees_changed then
        self.inst:PushEvent("techtreechange", { level = self.accessible_tech_trees })
        self.inst.replica.builder:SetTechTrees(self.accessible_tech_trees)
    end

	if self.override_current_prototyper ~= nil then
		if self.override_current_prototyper ~= self.current_prototyper then
			self.override_current_prototyper = nil
		elseif self.override_current_prototyper ~= old_prototyper then
            if not self.override_current_prototyper.components.prototyper or not self.override_current_prototyper.components.prototyper.dontopencraftingmenuonevaulatetechtrees then
			    self.inst.replica.builder:OpenCraftingMenu()
            end
		end
	end
end

function Builder:UsePrototyper(prototyper, dontopencraftingmenu)
	if self.inst.player_classified and not self.inst.player_classified.iscraftingenabled:value() then
		return false
	elseif prototyper then
		if not prototyper:HasTags(PROTOTYPER_TAGS) 
			or prototyper:HasOneOfTags(self.exclude_tags)
			or (prototyper.components.prototyper ~= nil and prototyper.components.prototyper.restrictedtag ~= nil and not self.inst:HasTag(prototyper.components.prototyper.restrictedtag))
			then

			local fail_str = prototyper.components.prototyper and prototyper.components.prototyper.restrictedtag or nil
			return false, fail_str ~= nil and string.upper(fail_str) or nil
		end
	end

	self.override_current_prototyper = prototyper
	if prototyper ~= nil and prototyper == self.current_prototyper then
        if not dontopencraftingmenu then
		    self.inst.replica.builder:OpenCraftingMenu()
        end
	end
	return true
end

function Builder:AddRecipe(recname)
    if not table.contains(self.recipes, recname) then
        table.insert(self.recipes, recname)
    end
    self.inst.replica.builder:AddRecipe(recname)
end

function Builder:RemoveRecipe(recname)
	table.removearrayvalue(self.recipes, recname)
	self.inst.replica.builder:RemoveRecipe(recname)
end

function Builder:UnlockRecipe(recname, nosanity)
    local recipe = GetValidRecipe(recname)
    if recipe ~= nil and not recipe.nounlock then
    --print("Unlocking: ", recname)
        if self.inst.components.sanity ~= nil and not nosanity then
            self.inst.components.sanity:DoDelta(TUNING.SANITY_MED)
        end
        self:AddRecipe(recname)
        self.inst:PushEvent("unlockrecipe", { recipe = recname })
    end
end

function Builder:GetIngredientWetness(ingredients)
-- GetIngredientWetness：材料潮湿度。
-- ⚠️ 这个值会被继承给产物（第 731 行 InheritMoisture）——
--   也就是说「用湿草造出的干草」仍然是湿的。
--   属于有意的设定（材料性质传递），但移植时容易漏掉。
    local wetness = {}
    for item, ents in pairs(ingredients) do
        for k, v in pairs(ents) do
            table.insert(wetness,
            {
				wetness =
					(k.components.inventoryitem ~= nil and k.components.inventoryitem:GetMoisture()) or
					(k.components.rainimmunity == nil and TheWorld.state.wetness) or
					0,
                num = v,
            })
        end
    end

    local totalWetness = 0
    local totalItems = 0
    for k,v in pairs(wetness) do
        totalWetness = totalWetness + (v.wetness * v.num)
        totalItems = totalItems + v.num
    end

    return totalItems > 0 and totalWetness or 0
end

function Builder:GetIngredients(recname)
    local recipe = AllRecipes[recname]
    if recipe then
        local ingredients = {}
		local discounted = false
        for k,v in pairs(recipe.ingredients) do
			if v.amount > 0 then
				local amt = math.max(1, RoundBiasedUp(v.amount * self.ingredientmod))
				local items = self.inst.components.inventory:GetCraftingIngredient(v.type, amt)
				ingredients[v.type] = items
				if amt < v.amount then
					discounted = true
				end
			end
        end
        return ingredients, discounted
    end
end

function Builder:CheckIngredientsForMimic(ingredients)
    for _, ents in pairs(ingredients) do
        for item in pairs(ents) do
            if item.components.itemmimic then
                -- Do not check ShouldItemMimicBeRevealedFor here, ingredients must be earned.
                item.components.itemmimic:TurnEvil(self.inst)
                return true
            end
        end
    end

    return false
end

-- TODO If we ever add more discount equippables, make this a LOT better!
function Builder:CheckDiscountEquipsForMimic()
    if self.inst.components.inventory then
        for slot, item in pairs(self.inst.components.inventory.equipslots) do
            if item and item.prefab == "greenamulet" and item.components.itemmimic then
                -- Do not check ShouldItemMimicBeRevealedFor here, ingredients must be earned.
                item.components.itemmimic:TurnEvil(self.inst)
                return true
            end
        end
    end
end

function Builder:RemoveIngredients(ingredients, recname, discounted)
-- ★ RemoveIngredients：扣除材料。本组件里最需要小心的函数。
--
-- 【为什么难】
-- 材料可能来自三类容器：背包、工作台、临时存放。
-- 扣除时必须「先检查够不够，再真的扣」，否则会出现扣了一半的中间态。
-- 尤其在联机环境下，客户端预测与服务端校验之间存在时间差，
-- 中间态会被玩家看到「东西消失了一半」。
--
-- 【移植要点】
--  · 扣除前先HasIngredients 做一遍完整校验
--  · 容器为空要过滤（对应 bug-patterns CTR4：同类函数有的过滤了有的没过滤）
--  · 找不到目标物品时不要静默返回原物品（对应 bug-patterns CTR7）
	if self.freebuildmode then
		return
	end

    for item, ents in pairs(ingredients) do
        for k,v in pairs(ents) do
            for i = 1, v do
                local item = self.inst.components.inventory:RemoveItem(k, false, true)

                -- If the item we're crafting with is a container,
                -- drop the contained items onto the ground.
                if item.components.container ~= nil then
                    item.components.container:DropEverything(self.inst:GetPosition())
                end

                item:Remove()
            end
        end
    end

    local recipe = AllRecipes[recname]
    if recipe then
        for k,v in pairs(recipe.character_ingredients) do
            if v.type == CHARACTER_INGREDIENT.HEALTH then
                self.inst:PushEvent("consumehealthcost")
                self.inst.components.health:DoDelta(-v.amount, false, "builder", true, nil, true)
            elseif v.type == CHARACTER_INGREDIENT.MAX_HEALTH then
                self.inst:PushEvent("consumehealthcost")
                self.inst.components.health:DeltaPenalty(v.amount)
            elseif v.type == CHARACTER_INGREDIENT.SANITY then
                self.inst.components.sanity:DoDelta(-v.amount)
            elseif v.type == CHARACTER_INGREDIENT.MAX_SANITY then
                --[[
                    Because we don't have any maxsanity restoring items we want to be more careful
                    with how we remove max sanity. Because of that, this is not handled here.
                    Removal of sanity is actually managed by the entity that is created.
                    See maxwell's pet leash on spawn and pet on death functions for examples.

					Note: Make sure you handle self.freebuildmode in this case
                --]]
            end
        end
    end
    self.inst:PushEvent("consumeingredients", { discounted = discounted })
end

function Builder:HasCharacterIngredient(ingredient)
-- HasCharacterIngredient：材料是否在角色身上。
-- 分「随身容器」与「外部容器」两类来源，判定顺序会影响优先级。
    if ingredient.type == CHARACTER_INGREDIENT.HEALTH then
        if self.inst.components.health ~= nil then
            --round up health to match UI display
			local amount_required = self.inst:HasTag("health_as_oldage") and math.ceil(ingredient.amount * TUNING.OLDAGE_HEALTH_SCALE) or ingredient.amount
            local current = math.ceil(self.inst.components.health.currenthealth)
            return current > amount_required, current --Don't die from crafting!
        end
    elseif ingredient.type == CHARACTER_INGREDIENT.MAX_HEALTH then
        if self.inst.components.health ~= nil then
            local penalty = self.inst.components.health:GetPenaltyPercent()
            return penalty + ingredient.amount <= TUNING.MAXIMUM_HEALTH_PENALTY, 1 - penalty
        end
    elseif ingredient.type == CHARACTER_INGREDIENT.SANITY then
        if self.inst.components.sanity ~= nil then
            --round up sanity to match UI display
            local current = math.ceil(self.inst.components.sanity.current)
            return current >= ingredient.amount, current
        end
    elseif ingredient.type == CHARACTER_INGREDIENT.MAX_SANITY then
        if self.inst.components.sanity ~= nil then
            local penalty = self.inst.components.sanity:GetPenaltyPercent()
            return penalty + ingredient.amount <= TUNING.MAXIMUM_SANITY_PENALTY, 1 - penalty
        end
    end
    return false, 0
end

function Builder:HasTechIngredient(ingredient)
    if IsTechIngredient(ingredient.type) and ingredient.type:sub(-9) == "_material" then
        local level = self.accessible_tech_trees[ingredient.type:sub(1, -10):upper()] or 0
        return level >= ingredient.amount, level
    end
    return false, 0
end

function Builder:MakeRecipe(recipe, pt, rot, skin, onsuccess)
-- MakeRecipe：制造但不指定放置点（走 UI 流程）。
-- 与 MakeRecipeAtPoint 的区别：后者直接决定产物落点。
	if recipe and not self.inst.sg:HasAnyStateTag("drowning", "falling", "floating", "nointerrupt", "nopredict", "pausepredict") then -- TODO(JBK): This should be refactored to not do the state checks here.
        self.inst:PushEvent("makerecipe", { recipe = recipe })
        if self:IsBuildBuffered(recipe.name) or self:HasIngredients(recipe) then
            self.inst.components.locomotor:Stop()
            local buffaction = BufferedAction(self.inst, nil, ACTIONS.BUILD, nil, pt or self.inst:GetPosition(), recipe.name, recipe.build_distance, nil, rot)
            buffaction.skin = skin
            if onsuccess ~= nil then
                buffaction:AddSuccessAction(onsuccess)
            end
            self.inst.components.locomotor:PushAction(buffaction, true)
            return true
        end
    end
    return false
end

local function GiveOrDropItem(self, recipe, item, pt)
-- GiveOrDropItem：优先给背包，背包满则掉落在地上。
-- 这是「产出兜底」的标准写法——保证产物永不凭空消失。
	if recipe.dropitem then
		local angle = (self.inst.Transform:GetRotation() + GetRandomMinMax(-65, 65)) * DEGREES
		local r = item:GetPhysicsRadius(0.5) + self.inst:GetPhysicsRadius(0.5) + 0.1
		item.Transform:SetPosition(pt.x + r * math.cos(angle), pt.y, pt.z - r * math.sin(angle))
		item.components.inventoryitem:OnDropped()
	else
	    self.inst.components.inventory:GiveItem(item, nil, pt)
	end
end

function Builder:DoBuild(recname, pt, rotation, skin)
-- ★★★ DoBuild —— 建造/制造的唯一入口，全文件最该精读的函数。
--
-- 【参数】recname=配方名, pt=放置点, rotation=朝向, skin=皮肤
--
-- 【返回值语义】第一个是成功与否；第二个是失败原因字符串（如 "MOUNTED"/"HASPET"）
--   失败原因会回给客户端做提示，所以这些字符串是对外契约，不要随意改。
--
-- 【校验链（659-688 行），顺序即优先级】
--  1) 配方有效 + 有材料或已缓冲 + 皮肤合法
--  2) 不能骑乘状态下建造（recipe.placer ~= nil 时）
--  3) 孤儿类配方需要宠物栏位
--  4) 制造类配方必须有有效的原型站（prototyper）
--  5) 皮肤解锁类配方必须指定 skin
--  6) recipe.canbuild 自定义钩子（模组扩展点）
--
-- 【⚠️ 一个真实的顺序缺陷】
--  第 710 行的 PushEvent("refreshcrafting") 与第 713 行的
--  CheckIngredientsForMimic 之间，隔着一个已经执行过的 hungrybuilder 扣饥饿逻辑。
--  更关键的是：第 713 行的检查失败会return false，
--  但第 700-702 行已经扣了饥饿值、推了 hungrybuild 事件。
--  也就是说「材料伪装（mimic）检查失败」这条路径上，
--  玩家会被扣饥饿但不消耗材料、也拿不到产物——代价与收益不匹配。
--  这与 bug-patterns ACT3（先移除道具再 return false）是同一类错误：
--  副作用必须排在最终校验之后。
--  仿写时务必把「所有可能失败的检查」前置。
    local recipe = GetValidRecipe(recname)
    if recipe ~= nil and (self:IsBuildBuffered(recname) or self:HasIngredients(recipe)) and not PREFAB_SKINS_SHOULD_NOT_SELECT[skin] then
-- 三重条件：配方有效、且（已缓冲建造 或 材料充足）、且皮肤不在禁用表里。
-- ⚠️ 注意是「或」：IsBuildBuffered 为真时，即使没材料也放行——
--   缓冲建造（客户端预测已先行扣料）需要这条通路。
        if recipe.placer ~= nil and
-- 骑乘状态下不能执行「放置类」配方。
-- 原因：放置需要精确的世界坐标，而坐骑上坐标由坐骑驱动，语义不对。
            self.inst.components.rider ~= nil and
            self.inst.components.rider:IsRiding() then
            return false, "MOUNTED"
        elseif recipe.level.ORPHANAGE > 0 and (
                self.inst.components.petleash == nil or
                self.inst.components.petleash:IsFull() or
                self.inst.components.petleash:HasPetWithTag("critter")
            ) then
            return false, "HASPET"
        elseif recipe.manufactured and (
-- 制造类配方（manufactured）必须依赖一个有效的原型站。
-- ⚠️ 第 674 行的条件是一个四段的 or 链，包含 craftingstation 的独立配方表——
--   也就是说「原型站能做」与「工作台能做」是两条并行的放行路径，
--   不是同一套权限。移植时容易只抄前半段，导致工作台配方全部失效。
                self.current_prototyper == nil or
                not self.current_prototyper:IsValid() or
                self.current_prototyper.components.prototyper == nil or
                ( not CanPrototypeRecipe(recipe.level, self.current_prototyper.components.prototyper.trees) and not (self.current_prototyper.components.craftingstation and self.current_prototyper.components.craftingstation:KnowsRecipe(recipe.name)))
            ) then
            -- manufacturing stations requires the current active protyper in order to work
            return false
        end

        if recipe.unlocks_from_skin and not skin then
            return false
        end
        if recipe.canbuild ~= nil then
-- recipe.canbuild：配方自定义的前置校验钩子。
-- 这是模组扩展配方行为的正规入口，返回 (success, msg)。
-- ★ 仿写建议：把这类钩子设计成「返回失败原因」而不是「直接报错」，
--   这样上层能把原因透传到 UI 提示，联机体验一致。
			local success, msg = recipe.canbuild(recipe, self.inst, pt, rotation, self.current_prototyper, skin)
			if not success then
				return false, msg
			end
		end

		local is_buffered_build = self.buffered_builds[recname] ~= nil
-- 缓冲建造在这里被消费掉（置false），保证一次缓冲只生效一次。
        if is_buffered_build then
            self:SetBuildBuffered(recname, false)
        end

        if self.inst:HasTag("hungrybuilder") and not self.inst.sg:HasStateTag("slowaction") and not self.inst.sg:HasStateTag("giving") then
-- ★ hungrybuilder：连续快速建造会累积饥饿代价。
-- 【节流设计】第 697-698 行有两个条件同时满足才扣：
--   hasTimeExpired  —— 距上次建造超过 HUNGRY_BUILDER_RESET_TIME
--   hasPlayerMoved  —— 玩家已离开上次建造点一定距离
-- 换句话说：原地连点是安全的，走开再回来才会重新计价。
-- 这是防误触的经典设计，值得抄。
            local t = GetTime()
            local hasTimeExpired = self.last_hungry_build == nil or t > self.last_hungry_build + TUNING.HUNGRY_BUILDER_RESET_TIME
            local hasPlayerMoved = self.last_hungry_build_pt == nil or CheckHungryDistance(self.inst, self.last_hungry_build_pt)
            if hasTimeExpired and hasPlayerMoved then
                self.inst.sg.mem.dohungryfastbuildtalk = true
                self.inst.components.hunger:DoDelta(TUNING.HUNGRY_BUILDER_DELTA)
                self.inst:PushEvent("hungrybuild")
            else
                self.inst.sg.mem.dohungryfastbuildtalk = nil
            end
            self.last_hungry_build = t
            self.last_hungry_build_pt = self.inst:GetPosition()
        end

        self.inst:PushEvent("refreshcrafting")
-- ⚠️ 注意位置：这里已经推了 refreshcrafting 事件，
-- 但下面的材料伪装检查（713 行）仍可能让整个建造失败。
-- 详见函数头关于「顺序缺陷」的说明。

        local materials, discounted = self:GetIngredients(recname)
-- 先取出材料清单，再做伪装检查，最后才真正扣除。
-- 顺序正确：GetIngredients 只读不写，RemoveIngredients 才是副作用。
        if self:CheckIngredientsForMimic(materials) or (discounted and self:CheckDiscountEquipsForMimic()) then
            return false, "ITEMMIMIC"
        end

		if recipe.manufactured then
-- 制造类配方：只扣材料，产物由原型站自己在 onactivate 里生成。
-- ⚠️ 这里 return true 表示「成功」，但产物还没出现——
--   若原型站随后生成失败，玩家会白扣材料。
--   这是「委托生成」模式的固有风险，需要原型站侧保证幂等。
			self:RemoveIngredients(materials, recname, discounted)
			   -- its up to the prototyper to implement onactivate and handle spawning the prefab
		   return true
		end

        local prod = SpawnPrefab(recipe.product, recipe.chooseskin or skin, nil, self.inst.userid) or nil
-- SpawnPrefab 生成产物。
-- ⚠️ or nil：预制体不存在时不报错，而是让 prod 为 nil 走后续分支，
--   避免一个坏配方导致整个建造流程崩溃。
--   这是「数据驱动系统」应有的健壮性：数据可能来自模组，不保证有效。
        if prod ~= nil then
            pt = pt or self.inst:GetPosition()

            if prod.components.inventoryitem ~= nil then
-- 只有具备 inventoryitem 的产物才有「物品语义」，才需要走背包流程。
-- 像篝火这类「放置即完成」的预制体没有 inventoryitem，跳过整个背包逻辑。
                if self.inst.components.inventory ~= nil then
					local wetlevel = self:GetIngredientWetness(materials)
					if wetlevel > 0 and prod.components.inventoryitem ~= nil then
						prod.components.inventoryitem:InheritMoisture(wetlevel, self.inst:GetIsWet())
					end

					if prod.onPreBuilt ~= nil then
-- onPreBuilt：产物生成后、扣材料前的钩子。
-- ⚠️ 这里存在一个失败窗口：若 onPreBuilt 内部抛错，
--   第 738 行的 RemoveIngredients 不会执行，材料不会被扣——
--   反而是「材料没扣但产物已生成」，玩家可利用此刷物品。
--   移植时应把钩子的异常处理纳入考虑。
						prod:onPreBuilt(self.inst, materials, recipe)
					end

					self:RemoveIngredients(materials, recname, discounted)

                    --self.inst.components.inventory:GiveItem(prod)
                    self.inst:PushEvent("builditem", { item = prod, recipe = recipe, skin = skin, prototyper = self.current_prototyper })
-- ★ 事件广播：builditem 携带完整上下文（物品/配方/皮肤/原型站）。
-- 这是整个建造系统的对外契约点——UI 刷新、音效、成就、数据统计都挂在这里。
-- ★ 经验：事件参数用命名 table 而非位置参数，便于后续新增字段而不破坏调用方。
                    if self.current_prototyper ~= nil and self.current_prototyper:IsValid() then
                        self.current_prototyper:PushEvent("builditem", { item = prod, recipe = recipe, skin = skin }) -- added this back for the gorge.
                    end
                    ProfileStatsAdd("build_"..prod.prefab)

					local numtogive = recipe.override_numtogive_fn and recipe.override_numtogive_fn(recipe, self.inst) or recipe.numtogive

                    if prod.components.equippable ~= nil
						and not recipe.dropitem
                        and self.inst.components.inventory:GetEquippedItem(prod.components.equippable.equipslot) == nil
                        and not prod.components.equippable:IsRestricted(self.inst) then
                        if numtogive <= 1 then
                            --The item is equippable. Equip it.
                            self.inst.components.inventory:Equip(prod)
                        elseif prod.components.stackable ~= nil then
                            --The item is stackable. Just increase the stack size of the original item.
                            prod.components.stackable:SetStackSize(numtogive)
                            self.inst.components.inventory:Equip(prod)
                        else
                            --We still need to equip the original product that was spawned, so do that.
                            self.inst.components.inventory:Equip(prod)
                            --Now spawn in the rest of the items and give them to the player.
                            for i = 2, numtogive do
                                local addt_prod = SpawnPrefab(recipe.product)
                                self.inst.components.inventory:GiveItem(addt_prod, nil, pt)
                            end
                        end
                    elseif numtogive <= 1 then
                        --Only the original item is being received.
						GiveOrDropItem(self, recipe, prod, pt)
                    elseif prod.components.stackable ~= nil then
                        --The item is stackable. Just increase the stack size of the original item.
                        prod.components.stackable:SetStackSize(numtogive)
						GiveOrDropItem(self, recipe, prod, pt)
                    else
                        --We still need to give the player the original product that was spawned, so do that.
						GiveOrDropItem(self, recipe, prod, pt)
                        --Now spawn in the rest of the items and give them to the player.
                        for i = 2, numtogive do
                            local addt_prod = SpawnPrefab(recipe.product)
							GiveOrDropItem(self, recipe, addt_prod, pt)
                        end
                    end

                    NotifyPlayerProgress("TotalItemsCrafted", 1, self.inst)

                    if self.onBuild ~= nil then
                        self.onBuild(self.inst, prod)
                    end
                    prod:OnBuilt(self.inst) -- This is an EntityScript function, custom logic should be defined in prod.OnBuiltFn.

                    return true
				else
					prod:Remove()
					prod = nil
                end
            else
				if not is_buffered_build then -- items that have intermediate build items (like statues)
					self:RemoveIngredients(materials, recname, discounted)
				end

                local spawn_pos = pt

                -- If a non-inventoryitem recipe specifies dropitem, position the created object
                -- away from the builder so that they don't overlap.
                if recipe.dropitem then
                    local angle = (self.inst.Transform:GetRotation() + GetRandomMinMax(-65, 65)) * DEGREES
                    local r = prod:GetPhysicsRadius(0.5) + self.inst:GetPhysicsRadius(0.5) + 0.1
                    spawn_pos = Vector3(
                        spawn_pos.x + r * math.cos(angle),
                        spawn_pos.y,
                        spawn_pos.z - r * math.sin(angle)
                    )
                end

                prod.Transform:SetPosition(spawn_pos:Get())
                --V2C: or 0 check added for backward compatibility with mods that
                --     have not been updated to support placement rotation yet
                prod.Transform:SetRotation(rotation or 0)
                self.inst:PushEvent("buildstructure", { item = prod, recipe = recipe, skin = skin })
                if self.current_prototyper ~= nil and self.current_prototyper:IsValid() then
                    self.current_prototyper:PushEvent("buildstructure", { item = prod, recipe = recipe, skin = skin })
                end
                prod:PushEvent("onbuilt", { builder = self.inst, pos = pt })
                ProfileStatsAdd("build_"..prod.prefab)
                NotifyPlayerProgress("TotalItemsCrafted", 1, self.inst)

                if self.onBuild ~= nil then
                    self.onBuild(self.inst, prod)
                end

                prod:OnBuilt(self.inst) -- This is an EntityScript function, custom logic should be defined in prod.OnBuiltFn.

                return true
            end
        end
    end
end

function Builder:KnowsRecipe(recipe, ignore_tempbonus, cached_tech_trees)
-- ★★★ KnowsRecipe —— 「这个配方能不能造」的判定，被 UI 高频调用。
--
-- 【判定的五个层次，短路顺序即优先级】
--  1) 配方不存在 → false
--  2) 创造模式（freebuildmode）→ true（除皮肤禁用）
--  3) 皮肤解锁类配方 → 查客户端所有权（TheInventory）
--  4) builder_tag / no_builder_tag → 角色限制
--  5) builder_skill / no_builder_skill → 技能树限制
--  6) 已解锁表命中 → true
--  7) 回落到科技树递归判定
--
-- 【⚠️ 第 870-880 行的注释说明了原因】
--   "the following builder_tag/skill checks are require due to character swapping"
--   因为玩家可以中途换角色，已解锁列表会变，所以必须在每次查询时重新校验标签，
--   不能只看缓存的解锁表。这是「缓存之外仍需动态校验」的正确范例。
--
-- 【性能】函数第三参cached_tech_trees 允许外部传入缓存，
--   避免同一帧内多次重复遍历科技树。调用方（UI 批量刷新）应传入。
    if type(recipe) == "string" then
		recipe = GetValidRecipe(recipe)
	end
    if recipe == nil then
        return false
	elseif self.freebuildmode and not PREFAB_SKINS_SHOULD_NOT_SELECT[recipe.product] then
-- 创造模式绕过几乎所有限制——调试与创造模式专用。
-- ⚠️ 注意仍排除「皮肤禁用」项，说明自由模式也不能造不该有的皮肤外观。
		return true
	end

    local has_unlocked_skin = false
    if recipe.unlocks_from_skin and self.inst.isplayer then
        local prefabskins = PREFAB_SKINS[recipe.product]
        if prefabskins ~= nil then
            for _, skin in ipairs(prefabskins) do
                if TheInventory:CheckClientOwnership(self.inst.userid, skin) then
                    has_unlocked_skin = true
                    if recipe.unlocks_from_skin == SKINUNLOCKS.ALWAYS then
                        return true
                    end
                end
            end
        end
        if recipe.unlocks_from_skin == SKINUNLOCKS.ALWAYS then
            return false
        end
    end

	--the following builder_tag/skill checks are require due to character swapping
	if (recipe.builder_tag and not self.inst:HasTag(recipe.builder_tag)) or
-- ★ 角色标签双向限制：
--   builder_tag      —— 必须拥有该标签才能造
--   no_builder_tag   —— 若拥有该标签则不能造（反向排除）
-- 这两个字段是「正条件 + 反条件」的一对，比写多个 if 清晰得多。
		(recipe.no_builder_tag and self.inst:HasTag(recipe.no_builder_tag))
	then
		return false
	end
	local skilltreeupdater = self.inst.components.skilltreeupdater
-- 技能树限制同理。
-- ⚠️ 注意第 877 行的条件里带了 and skilltreeupdater 的额外判断，
--   因为组件可能不存在（不是所有实体都有技能树），nil 保护必须写全。
--   漏掉 nil 保护就是 bug-patterns CTR2（未定义的全局/空值，仅靠巧合未崩溃）。
	if (recipe.builder_skill and not (skilltreeupdater and skilltreeupdater:IsActivated(recipe.builder_skill))) or
		(recipe.no_builder_skill and skilltreeupdater and skilltreeupdater:IsActivated(recipe.no_builder_skill))
	then
		return false
	end
	--

	if self.station_recipes[recipe.name] or table.contains(self.recipes, recipe.name) then
-- 命中已解锁表（工作台配方或玩家已解锁）。
-- ⚠️ 皮肤类配方在此返回 has_unlocked_skin 而非 true：
--   「知道配方」与「拥有皮肤」是两件事，不能混为一谈。
        if recipe.unlocks_from_skin then
            return has_unlocked_skin
        end
        return true
	end

    if cached_tech_trees and cached_tech_trees[recipe.level] ~= nil then
        if recipe.unlocks_from_skin then
            return has_unlocked_skin and cached_tech_trees[recipe.level]
        end
        return cached_tech_trees[recipe.level]
    end
    for i, v in ipairs(TechTree.AVAILABLE_TECH) do
        local bonusvalue = (self[TechTree.AVAILABLE_TECH_BONUS[v] or string.lower(v).."_bonus"] or 0)
        if not ignore_tempbonus then
            bonusvalue = bonusvalue + (self[TechTree.AVAILABLE_TECH_TEMPBONUS[v] or string.lower(v).."_tempbonus"] or 0)
        end
        if recipe.level[v] > bonusvalue then
            if cached_tech_trees then
                cached_tech_trees[recipe.level] = false
            end
            return false
        end
    end

    if cached_tech_trees then
        cached_tech_trees[recipe.level] = true
    end
    if recipe.unlocks_from_skin then
        return has_unlocked_skin
    end
    return true
end

function Builder:HasIngredients(recipe)
    if type(recipe) == "string" then 
		recipe = GetValidRecipe(recipe)
	end
	if recipe ~= nil then
		if self.freebuildmode then
			return true
		end
        if recipe.getlimitedrecipecount and recipe:getlimitedrecipecount(self.inst) <= 0 then
            return false
        end
		for i, v in ipairs(recipe.ingredients) do
            if not self.inst.components.inventory:Has(v.type, math.max(1, RoundBiasedUp(v.amount * self.ingredientmod)), true) then
				return false
			end
		end
		for i, v in ipairs(recipe.character_ingredients) do
			if not self:HasCharacterIngredient(v) then
				return false
			end
		end
		for i, v in ipairs(recipe.tech_ingredients) do
			if not self:HasTechIngredient(v) then
				return false
			end
		end
		return true
	end

	return false
end

function Builder:CanBuild(recipe_name) -- deprecated, use HasIngredients instead
	return self:HasIngredients(GetValidRecipe(recipe_name))
end

function Builder:CanLearn(recname)
	local recipe = GetValidRecipe(recname)
	if recipe == nil then
		return false
	elseif (recipe.builder_tag and not self.inst:HasTag(recipe.builder_tag)) or
		(recipe.no_builder_tag and self.inst:HasTag(recipe.no_builder_tag))
	then
		return false
	end
	local skilltreeupdater = self.inst.components.skilltreeupdater
	if (recipe.builder_skill and not (skilltreeupdater and skilltreeupdater:IsActivated(recipe.builder_skill))) or
		(recipe.no_builder_skill and skilltreeupdater and skilltreeupdater:IsActivated(recipe.no_builder_skill))
	then
		return false
	end
	return true
end

function Builder:LongUpdate(dt)
    if self.last_hungry_build ~= nil then
        self.last_hungry_build = self.last_hungry_build - dt
    end
end

local function TryActivateCurrentResearchMachineOnFreeBuild(self, recipe)
    local craftingstation = self.current_prototyper and self.current_prototyper.components.prototyper and self.current_prototyper.components.craftingstation
    if not table.contains(self.recipes, recipe.name) and (CanPrototypeRecipe(recipe.level, self.accessible_tech_trees) or (craftingstation and craftingstation:KnowsRecipe(recipe.name))) then
        self:ActivateCurrentResearchMachine(recipe)
    end
end

--------------------------------------------------------------------------
--RPC handlers
--------------------------------------------------------------------------

local function _TryMakeIngredientRecipe(self, ing_recipe)
	--Need to determine this NOW before calling async MakeRecipe
	local knows_no_temp = self:KnowsRecipe(ing_recipe, true)
	local canproto_no_temp = CanPrototypeRecipe(ing_recipe.level, self.accessible_tech_trees_no_temp)
	local canlearn = self:CanLearn(ing_recipe.name)
	local usingtempbonus = not knows_no_temp and not canproto_no_temp
	local success, canaccess = false, false
	if self:KnowsRecipe(ing_recipe) then
		canaccess = true
		if self:HasIngredients(ing_recipe) then
			success = self:MakeRecipe(ing_recipe, nil, nil, ValidateRecipeSkinRequest(self.inst.userid, ing_recipe.product, nil),
				function()
					if usingtempbonus then
						self:ConsumeTempTechBonuses()
					end

					if self.freebuildmode then
						--V2C: free-build should still trigger prototyping
                        TryActivateCurrentResearchMachineOnFreeBuild(self, ing_recipe)
					elseif not knows_no_temp and canproto_no_temp and canlearn then
						--assert(not usingtempbonus) --sanity check
						--V2C: for recipes known through temp bonus buff,
						--     but can be prototyped without consuming it
						self:ActivateCurrentResearchMachine(ing_recipe)
						self:UnlockRecipe(ing_recipe.name)
					elseif not ing_recipe.nounlock then
						--V2C: for recipes known through tech bonus, still
						--     want to unlock in case we reroll characters
						self:AddRecipe(ing_recipe.name)
					else
						self:ActivateCurrentResearchMachine(ing_recipe)
					end
				end
			)
		end
	elseif canlearn and CanPrototypeRecipe(ing_recipe.level, self.accessible_tech_trees) then
		canaccess = true
		if self:HasIngredients(ing_recipe) then
			success = self:MakeRecipe(ing_recipe, nil, nil, ValidateRecipeSkinRequest(self.inst.userid, ing_recipe.product, nil),
				function()
					if usingtempbonus then
						self:ConsumeTempTechBonuses()
					end
					self:ActivateCurrentResearchMachine(ing_recipe)
					self:UnlockRecipe(ing_recipe.name)
				end
			)
		end
	end
	return success, canaccess
end

function Builder:MakeRecipeFromMenu(recipe, skin)
    if not self.inst.components.inventory:IsOpenedBy(self.inst) then
        return -- NOTES(JBK): The inventory was hidden by gameplay do not allow crafting.
    end
    if self:HasIngredients(recipe) then
		if recipe.placer == nil then
			--Need to determine this NOW before calling async MakeRecipe
			local knows_no_temp = self:KnowsRecipe(recipe, true)
			local canproto_no_temp = CanPrototypeRecipe(recipe.level, self.accessible_tech_trees_no_temp)
			local canlearn = self:CanLearn(recipe.name)
			local usingtempbonus = not knows_no_temp and not canproto_no_temp

			if self:KnowsRecipe(recipe) then
                self:MakeRecipe(recipe, nil, nil, ValidateRecipeSkinRequest(self.inst.userid, recipe.product, skin),
                    function()
						if usingtempbonus then
							self:ConsumeTempTechBonuses()
						end

                        if self.freebuildmode then
                            --V2C: free-build should still trigger prototyping
                            TryActivateCurrentResearchMachineOnFreeBuild(self, recipe)
						elseif not knows_no_temp and canproto_no_temp and canlearn then
							--assert(not usingtempbonus) --sanity check
							--V2C: for recipes known through temp bonus buff,
							--     but can be prototyped without consuming it
							self:ActivateCurrentResearchMachine(recipe)
							self:UnlockRecipe(recipe.name)
                        elseif not recipe.nounlock then
                            --V2C: for recipes known through tech bonus, still
                            --     want to unlock in case we reroll characters
                            self:AddRecipe(recipe.name)
						else
							self:ActivateCurrentResearchMachine(recipe)
                        end

                    end
                )
			elseif canlearn and CanPrototypeRecipe(recipe.level, self.accessible_tech_trees) then
				self:MakeRecipe(recipe, nil, nil, ValidateRecipeSkinRequest(self.inst.userid, recipe.product, skin),
					function()
						if usingtempbonus then
							self:ConsumeTempTechBonuses()
						end
						self:ActivateCurrentResearchMachine(recipe)
						self:UnlockRecipe(recipe.name)
					end
				)
			end
        end
	else
		for i, ing in ipairs(recipe.ingredients) do
			local ing_recipe = GetValidRecipe(ing.type)
			if ing_recipe and not self.inst.components.inventory:Has(ing.type, math.max(1, RoundBiasedUp(ing.amount * self.ingredientmod)), true) then
				local success, canaccess = _TryMakeIngredientRecipe(self, ing_recipe)
				if not canaccess and ing_recipe.forward_ingredients then
					--V2C: skill tree might've locked basic ingredient recipe. try the forwarded ingredient recipes.
					for i, v in ipairs(ing_recipe.forward_ingredients) do
						ing_recipe = GetValidRecipe(v)
						if ing_recipe then
							success, canaccess = _TryMakeIngredientRecipe(self, ing_recipe)
							if canaccess then
								break
							end
						end
					end
				end
			end
		end
    end
end

function Builder:MakeRecipeAtPoint(recipe, pt, rot, skin)
    if not self.inst.components.inventory:IsOpenedBy(self.inst) then
        return -- NOTES(JBK): The inventory was hidden by gameplay do not allow crafting.
    end

    if recipe.placer ~= nil and
		(recipe.always_allow_buffered_placer or self:KnowsRecipe(recipe)) and
        self:IsBuildBuffered(recipe.name) and
        TheWorld.Map:CanDeployRecipeAtPoint(pt, recipe, rot, self.inst) then
        self:MakeRecipe(recipe, pt, rot, skin)
    end
end

function Builder:SetBuildBuffered(recname, boolval)
-- SetBuildBuffered：客户端预测用。
-- 客户端先「假装造好」以获得即时反馈，服务器确认后再真正扣除材料。
-- 若服务器判定失败，需要回滚——这类「预测 + 纠正」逻辑的坑见 bug-patterns B7。
    self.buffered_builds[recname] = boolval or nil
    self.inst.replica.builder:SetIsBuildBuffered(recname, boolval or false)
end

function Builder:BufferBuild(recname)
-- BufferBuild：请求服务器建造。
-- 与 SetBuildBuffered 配对：前者发请求，后者设置本地预测状态。
    if not self.inst.components.inventory:IsOpenedBy(self.inst) then
        return -- NOTES(JBK): The inventory was hidden by gameplay do not allow crafting.
    end

    local recipe = GetValidRecipe(recname)
    if recipe ~= nil and recipe.placer ~= nil and not self:IsBuildBuffered(recname) and self:HasIngredients(recipe) then
		local knows_no_temp = self:KnowsRecipe(recipe, true)
		local canproto_no_temp = CanPrototypeRecipe(recipe.level, self.accessible_tech_trees_no_temp)
		local canlearn = self:CanLearn(recname)
		local usingtempbonus = not knows_no_temp and not canproto_no_temp

        local materials, discounted = self:GetIngredients(recname)
        if self:CheckIngredientsForMimic(materials) or (discounted and self:CheckDiscountEquipsForMimic()) then
            if self.inst.components.talker then
                self.inst.components.talker:Say(GetActionFailString(self.inst, "GENERIC", "ITEMMIMIC"))
            end
            return
        end

        if self:KnowsRecipe(recipe) then
			if usingtempbonus then
				self:ConsumeTempTechBonuses()
			end

            if self.freebuildmode then
                --V2C: free-build should still trigger prototyping
                TryActivateCurrentResearchMachineOnFreeBuild(self, recipe)
			elseif not knows_no_temp and canproto_no_temp and canlearn then
				--assert(not usingtempbonus) --sanity check
				--V2C: for recipes known through temp bonus buff,
				--     but can be prototyped without consuming it
				self:ActivateCurrentResearchMachine(recipe)
				self:UnlockRecipe(recname)
            elseif not recipe.nounlock then
                --V2C: for recipes known through tech bonus, still
                --     want to unlock in case we reroll characters
                self:AddRecipe(recname)
            end
		elseif canlearn and CanPrototypeRecipe(recipe.level, self.accessible_tech_trees) then
			if usingtempbonus then
				self:ConsumeTempTechBonuses()
			end
			self:ActivateCurrentResearchMachine(recipe)
			self:UnlockRecipe(recname)
		else
			return
		end

        self:RemoveIngredients(materials, recname, discounted)
        self:SetBuildBuffered(recname, true)
    end
end

return Builder