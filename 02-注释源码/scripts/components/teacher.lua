--============================================================
-- 文件：components/teacher.lua
-- 模块：组件 / teacher
-- 职责：组件「teacher」的实现。组件是挂在实体上的行为单元，通过 inst.components.teacher 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Teacher = Class(function(self, inst)
    self.inst = inst
    self.recipe = nil
end)

function Teacher:SetRecipe(recipe)
    self.recipe = recipe
end

function Teacher:Teach(target)
    if self.recipe == nil then
        self.inst:Remove()
        return false
    elseif target.components.builder == nil then
        return false
	elseif target.components.builder:KnowsRecipe(self.recipe, true) then
        return false, "KNOWN"
    elseif not target.components.builder:CanLearn(self.recipe) then
        return false, "CANTLEARN"
    else
        target.components.builder:UnlockRecipe(self.recipe)
        if self.onteach then
            self.onteach(self.inst, target)
        end
        self.inst:Remove()
        return true
	end
end

return Teacher