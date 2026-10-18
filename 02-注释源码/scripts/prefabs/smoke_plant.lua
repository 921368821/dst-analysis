--============================================================
-- 文件：prefabs/smoke_plant.lua
-- 模块：预制体 / smoke_plant（建筑与容器）
-- 职责：实体「smoke_plant」的预制体定义。SpawnPrefab("smoke_plant") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/smoke_plants.zip"),
    Asset("SOUND", "sound/common.fsb"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddLight()
    inst.entity:AddNetwork()

    inst.Light:SetRadius(.6)
    inst.Light:SetFalloff(1)
    inst.Light:SetIntensity(.5)
    inst.Light:SetColour(235/255,165/255,12/255)
    inst.Light:Enable(true)

    --inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
    inst.AnimState:SetBank("smoke_out")
    inst.AnimState:SetBuild("smoke_plants")
    inst.AnimState:PlayAnimation("smoke_loop", true)
    --inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:SetFinalOffset(2)

    inst:AddTag("FX")

    inst.SoundEmitter:PlaySound("dontstarve_DLC001/summer/smolder", "smolder")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    return inst
end

return Prefab("smoke_plant", fn, assets)