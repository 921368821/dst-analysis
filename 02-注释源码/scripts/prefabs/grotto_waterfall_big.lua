--============================================================
-- 文件：prefabs/grotto_waterfall_big.lua
-- 模块：预制体 / grotto_waterfall_big（建筑与容器）
-- 职责：实体「grotto_waterfall_big」的预制体定义。SpawnPrefab("grotto_waterfall_big") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/moonglass_bigwaterfall.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.Transform:SetTwoFaced()

    inst.AnimState:SetBuild("moonglass_bigwaterfall")
    inst.AnimState:SetBank("moonglass_bigwaterfall")
    inst.AnimState:PlayAnimation("water_big", true)

    inst:AddTag("NOCLICK")

    inst.no_wet_prefix = true

	inst:SetDeploySmartRadius(3.5)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

	inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)

    return inst
end

return Prefab("grotto_waterfall_big", fn, assets)
