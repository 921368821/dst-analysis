--============================================================
-- 文件：components/recipescanner.lua
-- 模块：组件 / recipescanner
-- 职责：组件「recipescanner」的实现。组件是挂在实体上的行为单元，通过 inst.components.recipescanner 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local RecipeScanner = Class(function(self, inst)
	self.inst = inst
	self.onscanned = nil

	--V2C: Recommended to explicitly add tag to prefab pristine state
	inst:AddTag("recipescanner")
end)

function RecipeScanner:OnRemoveFromEntity()
	self.inst:RemoveTag("recipescanner")
end

function RecipeScanner:SetOnScannedFn(fn)
	self.onscanned = fn
end

function RecipeScanner:Scan(target, doer)
	if doer.components.builder == nil or target:HasTag("NOCLICK") then
		return false
	end
	local recipe
	if target.SCANNABLE_RECIPENAME then
		recipe = GetValidRecipe(target.SCANNABLE_RECIPENAME)
	else
		recipe = AllRecipes[target.prefab]
		if recipe and recipe.source_recipename then --in case of deconstruction recipe for a deployed item
			recipe = GetValidRecipe(recipe.source_recipename)
		end
	end
	if recipe == nil then
		return false, "CANTLEARN"
	elseif doer.components.builder:KnowsRecipe(recipe, true) then
		return false, "KNOWN"
	elseif recipe.nounlock or FunctionOrValue(recipe.no_deconstruction, target) then
		return false, "CANTLEARN"
	elseif not doer.components.builder:CanLearn(recipe.name) then
		return false, "CANTLEARN"
	end
	doer.components.builder:UnlockRecipe(recipe.name)
	target:PushEvent("onrecipescanned", { scanner = self.inst, doer = doer, recipe = recipe.name })
	if self.onscanned then
		self.onscanned(self.inst, target, doer, recipe.name)
	end
	return true
end

return RecipeScanner
