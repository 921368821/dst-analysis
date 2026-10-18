--============================================================
-- 文件：prefabs/lantern_crystal_fx.lua
-- 模块：预制体 / lantern_crystal_fx（建筑与容器）
-- 职责：实体「lantern_crystal_fx」的预制体定义。SpawnPrefab("lantern_crystal_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("DYNAMIC_ANIM", "anim/dynamic/lantern_crystal.zip"),
    Asset("PKGREF", "anim/dynamic/lantern_crystal.dyn"),
}

local function KillFX(inst)
    inst:Remove()
end

local function commonfn( anim )
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.AnimState:SetBank("lantern_crystal_fx")
    inst.AnimState:SetBuild("lantern")
    inst.AnimState:PlayAnimation(anim, true)
    inst.AnimState:SetFinalOffset(1)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    inst.KillFX = KillFX

    return inst
end

local function groundfn()
    return commonfn( "idle_ground" )
end

local function heldfn()
    return commonfn( "idle_held" )
end

return Prefab("lantern_crystal_fx_ground", groundfn, assets),
Prefab("lantern_crystal_fx_held", heldfn, assets)
