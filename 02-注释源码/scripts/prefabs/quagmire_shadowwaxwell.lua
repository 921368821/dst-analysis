--============================================================
-- 文件：prefabs/quagmire_shadowwaxwell.lua
-- 模块：预制体 / quagmire_shadowwaxwell（建筑与容器）
-- 职责：实体「quagmire_shadowwaxwell」的预制体定义。SpawnPrefab("quagmire_shadowwaxwell") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/waxwell_shadow_mod.zip"),
    Asset("SOUND", "sound/maxwell.fsb"),
    Asset("ANIM", "anim/swap_axe.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeGhostPhysics(inst, 1, .5)

    inst.Transform:SetFourFaced()

    inst.AnimState:SetBank("wilson")
    inst.AnimState:SetBuild("waxwell_shadow_mod")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetMultColour(0, 0, 0, .5)

    inst.AnimState:OverrideSymbol("swap_object", "swap_axe", "swap_axe")
    inst.AnimState:Hide("ARM_normal")
    inst.AnimState:Hide("HAT")
    inst.AnimState:Hide("HAIR_HAT")

    inst:AddTag("scarytoprey")
    inst:AddTag("shadowminion")
    inst:AddTag("NOBLOCK")

    inst:SetPrefabNameOverride("shadowwaxwell")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_shadowwaxwell").master_postinit(inst)

    return inst
end

return Prefab("quagmire_shadowwaxwell", fn, assets)
