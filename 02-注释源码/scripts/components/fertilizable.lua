--============================================================
-- 文件：components/fertilizable.lua
-- 模块：组件 / fertilizable
-- 职责：组件「fertilizable」的实现。组件是挂在实体上的行为单元，通过 inst.components.fertilizable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Fertilizable = Class(function(self, inst)
    self.inst = inst

	--self.onfertlizedfn = nil
end)

function Fertilizable:Fertilize(fertilizer)
	return self.onfertlizedfn ~= nil and self.onfertlizedfn(self.inst, fertilizer)
end

return Fertilizable
