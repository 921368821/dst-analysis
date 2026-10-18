--============================================================
-- 文件：components/hudindicatable.lua
-- 模块：组件 / hudindicatable
-- 职责：组件「hudindicatable」的实现。组件是挂在实体上的行为单元，通过 inst.components.hudindicatable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Hudindicatable = Class(function(self, inst)
    self.inst = inst
    self.shouldtrackfn = function() return true end
    self.inst:DoTaskInTime(0,function() self:RegisterWithWorldComponent() end)
    self.inst:ListenForEvent("onremove", self.UnRegisterWithWorldComponent)
end,
nil,
{})

function Hudindicatable:SetShouldTrackFunction(fn)
    self.shouldtrackfn = fn
end

function Hudindicatable:ShouldTrack(viewer)
    return self.shouldtrackfn(self.inst, viewer)
end

function Hudindicatable:UnRegisterWithWorldComponent()
     if TheWorld.components.hudindicatablemanager then
        TheWorld.components.hudindicatablemanager:UnRegisterItem(self.inst)
        TheWorld:PushEvent("unregister_hudindicatable",self.inst)
    end
end

function Hudindicatable:RegisterWithWorldComponent()
    if TheWorld.components.hudindicatablemanager then
        TheWorld.components.hudindicatablemanager:RegisterItem(self.inst)
    end
end

function Hudindicatable:OnRemoveFromEntity()
    self:UnRegisterWithWorldComponent()
end

return Hudindicatable
