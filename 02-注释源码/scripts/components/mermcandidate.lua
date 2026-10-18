--============================================================
-- 文件：components/mermcandidate.lua
-- 模块：组件 / mermcandidate
-- 职责：组件「mermcandidate」的实现。组件是挂在实体上的行为单元，通过 inst.components.mermcandidate 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MermCandidate = Class(function(self, inst)
    self.inst = inst
    self.calories = 0
    self.transformation_calories = 50
end)

function MermCandidate:AddCalories(food)
    if food.components.edible then
        local calories_consumed = food.components.edible:GetHunger(self.inst)
        self.calories = self.calories + calories_consumed
    end
end

function MermCandidate:ResetCalories()
    self.calories = 0
end

function MermCandidate:ShouldTransform()
    return self.calories >= self.transformation_calories
end

function MermCandidate:OnSave()
    return {
        calories = self.calories,
        transformation_calories = self.transformation_calories
    }
end

function MermCandidate:OnLoad(data)
    if data.calories then
        self.calories = data.calories
    end

    if data.transformation_calories then
        self.transformation_calories = data.transformation_calories
    end
end

return MermCandidate