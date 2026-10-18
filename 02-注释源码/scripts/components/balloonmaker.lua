--============================================================
-- 文件：components/balloonmaker.lua
-- 模块：组件 / balloonmaker
-- 职责：组件「balloonmaker」的实现。组件是挂在实体上的行为单元，通过 inst.components.balloonmaker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BalloonMaker = Class(function(self, inst)
    self.inst = inst
end)

function BalloonMaker:MakeBalloon(x,y,z)
    local balloon = SpawnPrefab("balloon")
    if balloon then
        balloon.Transform:SetPosition(x,y,z)
        --Trying without timer removal first since
        --we have a max cap on balloons in a world
        --if balloon.components.timer ~= nil then
        --    balloon.components.timer:StartTimer("flyoff", TUNING.TOTAL_DAY_TIME)
        --end
    end
end

return BalloonMaker
