--============================================================
-- 文件：components/socketable.lua
-- 模块：组件 / socketable
-- 职责：组件「socketable」的实现。组件是挂在实体上的行为单元，通过 inst.components.socketable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Socketable = Class(function(self, inst)
    self.inst = inst

	self.socketname = "socket_DEFAULT"
    self.socketquality = SOCKETQUALITY.NONE
end)


-- Common interface

function Socketable:SetSocketName(socketname)
    self.socketname = socketname
end

function Socketable:GetSocketName()
    return self.socketname
end


-- Server interface

function Socketable:SetSocketQuality(socketquality)
    self.socketquality = socketquality
end

function Socketable:GetSocketQuality()
    return self.socketquality
end


return Socketable
