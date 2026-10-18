--============================================================
-- 文件：components/pollinator.lua
-- 模块：组件 / pollinator
-- 职责：组件「pollinator」的实现。组件是挂在实体上的行为单元，通过 inst.components.pollinator 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Pollinator = Class(function(self, inst)
    self.inst = inst
    self.flowers = {}
    self.distance = 5
    self.maxdensity = 4
    self.collectcount = 5
    self.target = nil

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("pollinator")
end)

function Pollinator:OnRemoveFromEntity()
    self.inst:RemoveTag("pollinator")
end

function Pollinator:Pollinate(flower)
    if self:CanPollinate(flower) then
        table.insert(self.flowers, flower)
        self.target = nil
    end
end

function Pollinator:CanPollinate(flower)
    return flower ~= nil and flower:HasTag("flower") and not table.contains(self.flowers, flower)
end

function Pollinator:HasCollectedEnough()
    return #self.flowers > self.collectcount
end

function Pollinator:CreateFlower()
    if self:HasCollectedEnough() and self.inst:IsOnValidGround() then
        local parentFlower = GetRandomItem(self.flowers)
        local flower = SpawnPrefab(parentFlower.prefab)
        flower.planted = true
        flower.Transform:SetPosition(self.inst.Transform:GetWorldPosition())
        self.flowers = {}
    end
end

local FLOWERDENSITY_ONEOF_TAGS = {"FX", "NOBLOCK", "INLIMBO", "DECOR"}
function Pollinator:CheckFlowerDensity()
    local x,y,z = self.inst.Transform:GetWorldPosition()
    local nearbyentities = TheSim:FindEntities(x,y,z, self.distance, nil, FLOWERDENSITY_ONEOF_TAGS)
    return #nearbyentities < self.maxdensity
end

function Pollinator:GetDebugString()
    return string.format("flowers: %d, cancreate: %s", #self.flowers, tostring(self:HasCollectedEnough()))
end

return Pollinator
