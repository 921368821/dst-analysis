--============================================================
-- 文件：components/wintertreegiftable.lua
-- 模块：组件 / wintertreegiftable
-- 职责：组件「wintertreegiftable」的实现。组件是挂在实体上的行为单元，通过 inst.components.wintertreegiftable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================



local WinterTreeGiftable = Class(function(self, inst)
    self.inst = inst

    self.previousgiftday = -100
end)

function WinterTreeGiftable:GetDaysSinceLastGift()
    return TheWorld.state.cycles - self.previousgiftday
end

function WinterTreeGiftable:OnGiftGiven()
    self.previousgiftday = TheWorld.state.cycles
end

function WinterTreeGiftable:OnSave()
    return
    {
        previousgiftday = self.previousgiftday,
    }
end

function WinterTreeGiftable:OnLoad(data)
    if data ~= nil and self.previousgiftday ~= nil then
        self.previousgiftday = data.previousgiftday
    end
end

return WinterTreeGiftable
