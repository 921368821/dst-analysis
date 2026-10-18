--============================================================
-- 文件：components/walkingplankuser.lua
-- 模块：组件 / walkingplankuser
-- 职责：组件「walkingplankuser」的实现。组件是挂在实体上的行为单元，通过 inst.components.walkingplankuser 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local WalkingPlankUser = Class(function(self, inst)
    self.inst = inst

    --self.current_plank = nil
    --self._plank_remove_event = nil
end)

function WalkingPlankUser:SetCurrentPlank(plank)
    if self._plank_remove_event ~= nil then
        self._plank_remove_event:Cancel()
        self._plank_remove_event = nil
    end

    if plank ~= nil then
        self._plank_remove_event = self.inst:ListenForEvent("onremove", function(i) self.current_plank = nil end, plank)
    end

    self.current_plank = plank
end

function WalkingPlankUser:Dismount()
    if self.current_plank ~= nil then
        self.current_plank.components.walkingplank:StopMounting()
        self.current_plank = nil
    end

    if self._plank_remove_event ~= nil then
        self._plank_remove_event:Cancel()
        self._plank_remove_event = nil
    end
end

return WalkingPlankUser
