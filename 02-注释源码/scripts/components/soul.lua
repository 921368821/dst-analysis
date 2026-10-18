--============================================================
-- 文件：components/soul.lua
-- 模块：组件 / soul
-- 职责：组件「soul」的实现。组件是挂在实体上的行为单元，通过 inst.components.soul 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--For generating component actions

local Soul = Class(function(self, inst)
    self.inst = inst

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("soul")
end)

return Soul
