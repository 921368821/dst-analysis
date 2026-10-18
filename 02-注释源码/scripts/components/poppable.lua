--============================================================
-- 文件：components/poppable.lua
-- 模块：组件 / poppable
-- 职责：组件「poppable」的实现。组件是挂在实体上的行为单元，通过 inst.components.poppable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Poppable = Class(function(self, inst)
    self.inst = inst

	--self.onpopfn  = nil
	--self.popped = false
end)

function Poppable:Pop()
	if not self.popped then
		self.popped = true

		if self.onpopfn ~= nil then
			self.onpopfn(self.inst)
		end
	end
end

return Poppable
