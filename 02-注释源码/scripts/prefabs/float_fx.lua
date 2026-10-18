--============================================================
-- 文件：prefabs/float_fx.lua
-- 模块：预制体 / float_fx（建筑与容器）
-- 职责：实体「float_fx」的预制体定义。SpawnPrefab("float_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/float_fx.zip"),
}

local prefabs =
{
}


local function common_fn(is_front)
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()

    inst.persists = false

    inst:AddTag("NOBLOCK")
    inst:AddTag("FX")
    inst:AddTag("ignorewalkableplatforms")
    inst.AnimState:SetBuild("float_fx")
    inst.AnimState:SetOceanBlendParams(TUNING.OCEAN_SHADER.EFFECT_TINT_AMOUNT)

    if is_front then
        inst.AnimState:SetBank("float_front")
        inst.AnimState:PlayAnimation("idle_front_small", true)
    else
        inst.AnimState:SetBank("float_back")
        inst.AnimState:SetLayer(LAYER_BACKGROUND)
        inst.AnimState:PlayAnimation("idle_back_small", true)
    end

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    return inst
end

local function front_fn()
    return common_fn(true)
end

local function back_fn()
    return common_fn(false)
end

return Prefab("float_fx_front", front_fn, assets, prefabs),
       Prefab("float_fx_back", back_fn, assets, prefabs)
