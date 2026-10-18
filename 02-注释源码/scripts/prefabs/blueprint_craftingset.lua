--============================================================
-- 文件：prefabs/blueprint_craftingset.lua
-- 模块：预制体 / blueprint_craftingset（建筑与容器）
-- 职责：实体「blueprint_craftingset」的预制体定义。SpawnPrefab("blueprint_craftingset") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local RUINSTURF_BLUEPRINTS = {
    "turf_ruinsbrick",
    "turf_ruinstiles",
    "turf_ruinstrim",
}

local RUINSGLOWTURF_BLUEPRINTS = {
    "turf_ruinsbrick_glow",
    "turf_ruinstiles_glow",
    "turf_ruinstrim_glow",
}

-------------------------------------------------------------------------------------------------------

local function builder_onbuilt(inst, builder)
    local x, y, z = builder.Transform:GetWorldPosition()

    for _, v in ipairs(inst.blueprints) do
        local blueprint = SpawnPrefab(v.."_blueprint")
        blueprint.Transform:SetPosition(x, 0, z)

        builder.components.inventory:GiveItem(blueprint, nil, Vector3(x, 0, z))
    end

    inst:Remove()
end

local function MakeBlueprintSet(name, blueprints)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()

        inst:AddTag("CLASSIFIED")

        --[[Non-networked entity]]
        inst.persists = false

        --Auto-remove if not spawned by builder.
        inst:DoTaskInTime(0, inst.Remove)

        if not TheWorld.ismastersim then
            return inst
        end

        inst.blueprints = blueprints
        inst.OnBuiltFn = builder_onbuilt

        return inst
    end

    return Prefab(name, fn, nil, blueprints)
end

return
    MakeBlueprintSet("blueprint_craftingset_ruins_builder",     RUINSTURF_BLUEPRINTS    ),
    MakeBlueprintSet("blueprint_craftingset_ruinsglow_builder", RUINSGLOWTURF_BLUEPRINTS)
