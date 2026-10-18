--============================================================
-- 文件：components/quagmire_map.lua
-- 模块：组件 / quagmire_map
-- 职责：组件「quagmire_map」的实现。组件是挂在实体上的行为单元，通过 inst.components.quagmire_map 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


-- these functions have moved into map.lua

function Map:IsFarmableSoilAtPoint(x, y, z)
    return self:GetTileAtPoint(x, y, z) == WORLD_TILES.QUAGMIRE_SOIL
end

local TILLSOILBLOCKED_MUST_TAGS = { "plantedsoil" }
function Map:CanTillSoilAtPoint(pt)
    return TheWorld.Map:IsFarmableSoilAtPoint(pt:Get())
        and #TheSim:FindEntities(pt.x, 0, pt.z, 1, TILLSOILBLOCKED_MUST_TAGS) <= 0
end
