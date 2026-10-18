--============================================================
-- 文件：components/boatpatch.lua
-- 模块：组件 / boatpatch
-- 职责：组件「boatpatch」的实现。组件是挂在实体上的行为单元，通过 inst.components.boatpatch 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BoatPatch = Class(function(self, inst)
    self.inst = inst
    self.patch_type = nil

    inst:AddTag("boat_patch")
end)

function BoatPatch:OnRemoveFromEntity()
    self.inst:RemoveTag("boat_patch")
end

function BoatPatch:GetPatchType()
    return self.patch_type
end

return BoatPatch
