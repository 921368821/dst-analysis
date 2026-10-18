--============================================================
-- 文件：components/papereraser.lua
-- 模块：组件 / papereraser
-- 职责：组件「papereraser」的实现。组件是挂在实体上的行为单元，通过 inst.components.papereraser 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local PaperEraser = Class(function(self, inst)
    self.inst = inst

    --self.stacksize = 1
	--self.erased_prefab = "papyrus"

	self.inst:AddTag("papereraser")
end)

function PaperEraser:OnRemoveFromEntity()
    self.inst:RemoveTag("papereraser")
end

function PaperEraser:DoErase(paper, doer)
	return paper.components.erasablepaper:DoErase(self.inst, doer) ~= nil
end

return PaperEraser