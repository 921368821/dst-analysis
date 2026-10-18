--============================================================
-- 文件：components/furnituredecor.lua
-- 模块：组件 / furnituredecor
-- 职责：组件「furnituredecor」的实现。组件是挂在实体上的行为单元，通过 inst.components.furnituredecor 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onenabled(self, enabled)
	self.inst:AddOrRemoveTag("furnituredecor", enabled)
end

local FurnitureDecor = Class(function(self, inst)
    self.inst = inst

    self.enabled = true
    self.on_furniture = nil
    self.decor_animation = "idle"

    --self.onputonfurniture = nil

    -- NOTE: Recommended to add to pristine state, for optimization.
	--self.inst:AddTag("furnituredecor")
end,
nil,
{
    enabled = onenabled,
})

function FurnitureDecor:OnRemoveFromEntity()
    self.inst:RemoveTag("furnituredecor")
end

function FurnitureDecor:SetEnabled(enabled)
    if self.enabled ~= enabled then
        self.enabled = enabled
    end
end

function FurnitureDecor:IsOnFurniture()
	return self.on_furniture == true
end

function FurnitureDecor:PutOnFurniture(furniture)
    self.on_furniture = true
    if self.onputonfurniture then
        self.onputonfurniture(self.inst, furniture)
    end
end

function FurnitureDecor:TakeOffFurniture(furniture)
    self.on_furniture = nil
	if self.ontakeofffurniture then
		self.ontakeofffurniture(self.inst, furniture)
	end
end

return FurnitureDecor
