--============================================================
-- 文件：components/groundcreep.lua
-- 模块：组件 / groundcreep
-- 职责：组件「groundcreep」的实现。组件是挂在实体上的行为单元，通过 inst.components.groundcreep 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ GroundCreep class definition ]]
--[[
    This exists solely to make serializing the ground creep from the map sane,
    as opposed to insane special case code that lives god knows where
--]]
--------------------------------------------------------------------------

return Class(function(self, inst)

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--------------------------------------------------------------------------
--[[ Private event handlers ]]
--------------------------------------------------------------------------

local function OnPlayerActivated()
    inst.GroundCreep:FastForward()
end

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

inst:ListenForEvent("playeractivated", OnPlayerActivated)

--------------------------------------------------------------------------
--[[ Save/Load ]]
--------------------------------------------------------------------------

if inst.ismastersim then function self:OnSave()
    return inst.GroundCreep:GetAsString()
end end

if inst.ismastersim then function self:OnLoad(data)
    inst.GroundCreep:SetFromString(data)
end end

--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)