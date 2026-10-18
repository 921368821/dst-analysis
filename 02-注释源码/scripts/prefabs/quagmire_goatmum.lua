--============================================================
-- 文件：prefabs/quagmire_goatmum.lua
-- 模块：预制体 / quagmire_goatmum（建筑与容器）
-- 职责：实体「quagmire_goatmum」的预制体定义。SpawnPrefab("quagmire_goatmum") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_goatmom_basic.zip"),
}

local prefabs =
{
    "quagmire_crate_pot_hanger",
    "quagmire_crate_oven",
    "quagmire_crate_grill_small",
    "quagmire_plate_silver",
    "quagmire_bowl_silver",
    "quagmire_goatmilk",
    "quagmire_portal_key",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    MakeCharacterPhysics(inst, 50, .4)

    inst.DynamicShadow:SetSize(2, 1)

    inst.Transform:SetFourFaced()
    inst.Transform:SetScale(1.3, 1.3, 1.3)

    inst.AnimState:SetBank("quagmire_goatmom_basic")
    inst.AnimState:SetBuild("quagmire_goatmom_basic")
    inst.AnimState:PlayAnimation("idle_loop", true)
    inst.AnimState:Hide("hat")

    inst:AddTag("character")

    inst:AddComponent("talker")
    inst.components.talker.fontsize = 35
    inst.components.talker.font = TALKINGFONT
    inst.components.talker.offset = Vector3(0, -400, 0)
    inst.components.talker:MakeChatter()

    inst.quagmire_shoptab = QUAGMIRE_RECIPETABS.QUAGMIRE_TRADER_MUM

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_goatmum").master_postinit(inst, prefabs)

    return inst
end

return Prefab("quagmire_goatmum", fn, assets, prefabs)
