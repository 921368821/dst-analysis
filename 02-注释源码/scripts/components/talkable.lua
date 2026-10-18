--============================================================
-- 文件：components/talkable.lua
-- 模块：组件 / talkable
-- 职责：组件「talkable」的实现。组件是挂在实体上的行为单元，通过 inst.components.talkable 访问，负责本实体的某一类状态与逻辑。
--   关键机制：可对话组件：NPC 对话交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Talkable = Class(function(self, inst)
    self.inst = inst
    self.conversation = nil
    self.conv_index = 1
end)

return Talkable