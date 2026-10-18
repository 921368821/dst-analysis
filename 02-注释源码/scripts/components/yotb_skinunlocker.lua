--============================================================
-- 文件：components/yotb_skinunlocker.lua
-- 模块：组件 / yotb_skinunlocker
-- 职责：组件「yotb_skinunlocker」的实现。组件是挂在实体上的行为单元，通过 inst.components.yotb_skinunlocker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local YOTB_SkinUnlocker = Class(function(self, inst)
    self.inst = inst
end)

function YOTB_SkinUnlocker:SetSkin(skin)
    self.skin = skin
end

function YOTB_SkinUnlocker:GetSkin()
    return self.skin
end

return YOTB_SkinUnlocker