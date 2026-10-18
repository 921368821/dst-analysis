--============================================================
-- 文件：prefabs/minimap.lua
-- 模块：预制体 / minimap（建筑与容器）
-- 职责：实体「minimap」的预制体定义。SpawnPrefab("minimap") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local shader_filename = "shaders/minimap.ksh"
local fs_shader = "shaders/minimapfs.ksh"

local GroundTiles = require("worldtiledefs")

local assets =
{
    Asset("DYNAMIC_ATLAS", "minimap/minimap_data.xml"), -- Legacy for mods.
    Asset("PKGREF", "minimap/minimap_atlas.tex"), -- Legacy for mods.
    Asset("ATLAS", "minimap/minimap_data1.xml"),
    Asset("IMAGE", "minimap/minimap_atlas1.tex"),
    Asset("ATLAS", "minimap/minimap_data2.xml"),
    Asset("IMAGE", "minimap/minimap_atlas2.tex"),

    Asset("ATLAS", "images/hud.xml"),
    Asset("IMAGE", "images/hud.tex"),

    Asset("ATLAS", "images/hud2.xml"),
    Asset("IMAGE", "images/hud2.tex"),

    Asset("SHADER", shader_filename),
    Asset("SHADER", fs_shader),

    Asset("IMAGE", "images/minimap_paper.tex"),
}

for k, v in pairs(GroundTiles.minimapassets) do
    table.insert(assets, v)
end

local function fn()
    local inst = CreateEntity()
    inst.entity:AddUITransform()
    inst.entity:AddMiniMap() --c side renderer

    inst:AddTag("minimap")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)

    inst.MiniMap:SetEffects(shader_filename, fs_shader)

    inst.MiniMap:AddAtlas(resolvefilepath("minimap/minimap_data1.xml"))
    inst.MiniMap:AddAtlas(resolvefilepath("minimap/minimap_data2.xml"))
    for _, atlases in ipairs(ModManager:GetPostInitData("MinimapAtlases")) do
        for _, path in ipairs(atlases) do
            inst.MiniMap:AddAtlas(resolvefilepath(path))
        end
    end

    for i, data in pairs(GroundTiles.minimap) do
        local tile_id, layer_properties = unpack(data)
        inst.MiniMap:AddRenderLayer(
            MapLayerManager:CreateRenderLayer(
                tile_id,
                layer_properties.atlas or resolvefilepath(GroundAtlas(layer_properties.name)),
                layer_properties.texture_name or resolvefilepath(GroundImage(layer_properties.name)),
                resolvefilepath(layer_properties.noise_texture)
            )
        )
    end

    return inst
end

return Prefab("minimap", fn, assets)
