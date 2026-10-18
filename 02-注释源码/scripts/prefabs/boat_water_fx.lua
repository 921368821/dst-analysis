--============================================================
-- 文件：prefabs/boat_water_fx.lua
-- 模块：预制体 / boat_water_fx（建筑与容器）
-- 职责：实体「boat_water_fx」的预制体定义。SpawnPrefab("boat_water_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/boat_water_fx2.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst:AddTag("FX")
    inst:AddTag("NOBLOCK")
    inst:AddTag("ignorewalkableplatforms")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()

    local anim = inst.entity:AddAnimState()
    anim:SetBank("boat_water_fx")
    anim:SetBuild("boat_water_fx2")
    anim:PlayAnimation("idle_loop_1")
    anim:SetSortOrder(ANIM_SORT_ORDER_BELOW_GROUND.BOAT_TRAIL)
    anim:SetOrientation(ANIM_ORIENTATION.OnGround)
    anim:SetLayer(LAYER_BELOW_GROUND)
    anim:SetOceanBlendParams(TUNING.OCEAN_SHADER.EFFECT_TINT_AMOUNT)

    inst:AddComponent("boattrailmover")

    inst:ListenForEvent("animover", inst.Remove)
	inst:DoTaskInTime(80 * FRAMES, inst.Remove)

    return inst
end

return Prefab("boat_water_fx", fn, assets)
