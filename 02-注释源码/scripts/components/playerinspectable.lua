--============================================================
-- 文件：components/playerinspectable.lua
-- 模块：组件 / playerinspectable
-- 职责：组件「playerinspectable」的实现。组件是挂在实体上的行为单元，通过 inst.components.playerinspectable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local EquipSlot = require("equipslotutil")

local function OnEquip(inst, data)
	inst.Network:SetPlayerEquip(EquipSlot.ToID(data.eslot), data.item:GetSkinName() or data.item.playerinspectable_override or data.item.prefab)
end

local function OnUnequip(inst, data)
    inst.Network:SetPlayerEquip(EquipSlot.ToID(data.eslot), "")
end

local function OnSkillSelectionUpdated(inst, data)
    local skilltreeupdater = inst.components.skilltreeupdater
    if skilltreeupdater == nil then
        return
    end

    inst.Network:SetPlayerSkillSelection(skilltreeupdater:GetPlayerSkillSelection())
end

local PlayerInspectable = Class(function(self, inst)
    self.inst = inst

    inst:ListenForEvent("equip", OnEquip)
    inst:ListenForEvent("unequip", OnUnequip)
    inst:ListenForEvent("onactivateskill_server", OnSkillSelectionUpdated)
    inst:ListenForEvent("ondeactivateskill_server", OnSkillSelectionUpdated)
    inst:ListenForEvent("onsetskillselection_server", OnSkillSelectionUpdated)
end)

return PlayerInspectable
