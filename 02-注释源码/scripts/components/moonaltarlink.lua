--============================================================
-- 文件：components/moonaltarlink.lua
-- 模块：组件 / moonaltarlink
-- 职责：组件「moonaltarlink」的实现。组件是挂在实体上的行为单元，通过 inst.components.moonaltarlink 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MoonAltarLink = Class(function(self, inst)
    self.inst = inst
    self.altars = nil

    self.onlinkfn = nil
    self.onlinkbrokenfn = nil
end)

function MoonAltarLink:EstablishLink(altars)
    local new_x, new_z = 0, 0

    for i, v in ipairs(altars) do
        local x, y, z = v.Transform:GetWorldPosition()
        new_x, new_z = new_x + x, new_z + z
        v.components.moonaltarlinktarget.link = self.inst

        if v.components.moonaltarlinktarget.onlinkfn ~= nil then
            v.components.moonaltarlinktarget.onlinkfn(v, self.inst)
        end
    end

    self.inst.Transform:SetPosition(new_x / #altars, 0, new_z / #altars)

    self.altars = altars
    if self.onlinkfn ~= nil then
        self.onlinkfn(self.inst, altars)
    end
end

function MoonAltarLink:BreakLink()
    if self.altars ~= nil and #self.altars > 0 then
        for i, v in ipairs(self.altars) do
            if v.components.moonaltarlinktarget ~= nil then
                v.components.moonaltarlinktarget.link = nil

                if v.components.moonaltarlinktarget.onlinkbrokenfn ~= nil then
                    v.components.moonaltarlinktarget.onlinkbrokenfn(v, self.inst)
                end
            end
        end
    end

    if self.onlinkbrokenfn ~= nil then
        self.onlinkbrokenfn(self.inst, self.altars)
    end
    self.altars = nil
end

return MoonAltarLink
