--============================================================
-- 文件：components/migrationpetsoverrider.lua
-- 模块：组件 / migrationpetsoverrider
-- 职责：组件「migrationpetsoverrider」的实现。组件是挂在实体上的行为单元，通过 inst.components.migrationpetsoverrider 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- This component is for overriding some behaviour in playerspawner for the inst.migrationpets handling.
local MigrationPetsOverrider = Class(function(self, inst)
    self.inst = inst

    --self.getoffsetfromfn = nil
    --self.onsetpositionfn = nil
end)

function MigrationPetsOverrider:SetOffsetFromFn(fn)
    self.getoffsetfromfn = fn
end

function MigrationPetsOverrider:GetOffsetFrom(x, y, z)
    local ox, oy, oz = 0, 0, 0
    if self.getoffsetfromfn then
        ox, oy, oz = self.getoffsetfromfn(self.inst, x, y, z)
    end
    return ox, oy, oz
end

return MigrationPetsOverrider
