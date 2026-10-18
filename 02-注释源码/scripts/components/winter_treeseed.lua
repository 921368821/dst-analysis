--============================================================
-- 文件：components/winter_treeseed.lua
-- 模块：组件 / winter_treeseed
-- 职责：组件「winter_treeseed」的实现。组件是挂在实体上的行为单元，通过 inst.components.winter_treeseed 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Winter_TreeSeed = Class(function(self, inst)
    self.inst = inst
    self.winter_tree = "winter_tree"
end)

function Winter_TreeSeed:SetTree(tree)
    self.winter_tree = tree
end

return Winter_TreeSeed
