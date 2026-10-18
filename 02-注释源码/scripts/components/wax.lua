--============================================================
-- 文件：components/wax.lua
-- 模块：组件 / wax
-- 职责：组件「wax」的实现。组件是挂在实体上的行为单元，通过 inst.components.wax 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnIsSprayFn(self, is_spray)
    if is_spray then
        self.inst:AddTag("waxspray")
    else
        self.inst:RemoveTag("waxspray")
    end
end

local Wax = Class(function(self, inst)
    self.inst = inst

    self.is_spray = false
end,
nil,
{
    is_spray = OnIsSprayFn,
})

function Wax:SetIsSpray()
    self.is_spray = true
end

function Wax:GetIsSpray()
    return self.is_spray
end

return Wax
