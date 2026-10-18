--============================================================
-- 文件：prefabs/rabbithouse_yule_glow_fx.lua
-- 模块：预制体 / rabbithouse_yule_glow_fx（建筑与容器）
-- 职责：实体「rabbithouse_yule_glow_fx」的预制体定义。SpawnPrefab("rabbithouse_yule_glow_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
}

local function glowfn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("rabbithouse_glowfx")
    inst.AnimState:SetBuild("rabbit_house")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetLightOverride(0.7)
    inst.AnimState:SetFinalOffset(1)

    inst:AddTag("FX")

    inst.entity:SetPristine()

    inst.persists = false

    return inst
end

--------------------------------------------------------------------------

return Prefab("rabbithouse_yule_glow_fx", glowfn, assets)
