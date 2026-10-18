--============================================================
-- 文件：prefabs/walkingplank.lua
-- 模块：预制体 / walkingplank（建筑与容器）
-- 职责：实体「walkingplank」的预制体定义。SpawnPrefab("walkingplank") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local prefabs =
{
    "collapse_small",
}

local function MakeWalkingPlank(name, build)
    local assets = {
        Asset("ANIM", "anim/boat_plank.zip"),
        Asset("ANIM", "anim/"..build..".zip"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddNetwork()

        inst:AddTag("walkingplank") -- From walkingplank component.
        inst:AddTag("ignorewalkableplatforms") -- Because it is a child of the boat.

        inst:SetStateGraph("SGwalkingplank")

        inst.AnimState:SetBank("plank")
        inst.AnimState:SetBuild(build)
        inst.AnimState:SetSortOrder(ANIM_SORT_ORDER.OCEAN_BOAT)
        inst.AnimState:SetFinalOffset(2)
        inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
        inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)

        inst.entity:SetPristine()
        if not TheWorld.ismastersim then
            return inst
        end

        inst.persists = false

        inst:AddComponent("lootdropper") -- The loot that this drops is generated from the uncraftable recipe; see recipes.lua for the items.
        inst:AddComponent("inspectable")
        inst:AddComponent("walkingplank")

        inst:AddComponent("hauntable")
        inst.components.hauntable:SetHauntValue(TUNING.HAUNT_TINY)

        return inst
    end

    return Prefab(name, fn, assets, prefabs)
end

return
    MakeWalkingPlank( "walkingplank",         "boat_plank_build"         ),
    MakeWalkingPlank( "walkingplank_grass",   "boat_plank_grass_build"   ),
    MakeWalkingPlank( "walkingplank_yotd",    "boat_plank_yotd_build"    ),
    MakeWalkingPlank( "walkingplank_ancient", "boat_ancient_plank_build" )
