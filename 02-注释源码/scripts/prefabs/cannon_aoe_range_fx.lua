--============================================================
-- 文件：prefabs/cannon_aoe_range_fx.lua
-- 模块：预制体 / cannon_aoe_range_fx（建筑与容器）
-- 职责：实体「cannon_aoe_range_fx」的预制体定义。SpawnPrefab("cannon_aoe_range_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cannon_aoe_range.zip"),
}

local assets_reticule =
{
    Asset("ANIM", "anim/cannon_reticule.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBank("cannon_aoe_range")
    inst.AnimState:SetBuild("cannon_aoe_range")
    inst.AnimState:PlayAnimation("idle")
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    return inst
end

local function fn_reticule()
    local inst = CreateEntity()

    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBank("cannon_reticule")
    inst.AnimState:SetBuild("cannon_reticule")
    inst.AnimState:PlayAnimation("idle")
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    return inst
end

return Prefab("cannon_aoe_range_fx", fn, assets),
    Prefab("cannon_reticule_fx", fn_reticule, assets_reticule)
