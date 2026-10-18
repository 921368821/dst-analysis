--============================================================
-- 文件：components/sharkboimanagerhelper.lua
-- 模块：组件 / sharkboimanagerhelper
-- 职责：组件「sharkboimanagerhelper」的实现。组件是挂在实体上的行为单元，通过 inst.components.sharkboimanagerhelper 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ sharkboimanagerhelper class definition ]]
--------------------------------------------------------------------------

return Class(function(self, inst)
local _world = TheWorld
local _map = _world.Map

self.inst = inst

self.arena_origin_x = net_float(self.inst.GUID, "sharkboimanager.arena_origin_x") -- Could probably be a ushort if arenas are tile aligned only.
self.arena_origin_z = net_float(self.inst.GUID, "sharkboimanager.arena_origin_z")
self.arena_radius = net_float(self.inst.GUID, "sharkboimanager.arena_radius")
self.arena_origin_x:set(0)
self.arena_origin_z:set(0)
self.arena_radius:set(0)

function self:IsPointInArena(x, y, z)
    local radius = self.arena_radius:value()
    if radius <= 0 then
        return false
    end

    local dx, dz = x - self.arena_origin_x:value(), z - self.arena_origin_z:value()
    local dsq = dx * dx + dz * dz
    local r = math.ceil(radius / TILE_SCALE) * TILE_SCALE * SQRT2
    return dsq < r * r and _map:IsVisualGroundAtPoint(x, y, z)
end


end)