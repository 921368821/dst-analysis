--============================================================
-- 文件：prefabs/lichen.lua
-- 模块：预制体 / lichen（建筑与容器）
-- 职责：实体「lichen」的预制体定义。SpawnPrefab("lichen") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    -- Asset("ANIM", "anim/grass.zip"),
    Asset("ANIM", "anim/algae_bush.zip"),
    Asset("SOUND", "sound/common.fsb"),
}

local prefabs =
{
    "cutlichen",
}

local function onpickedfn(inst)
    inst.SoundEmitter:PlaySound("dontstarve/wilson/pickup_lichen")
    inst.AnimState:PlayAnimation("picking")
    inst.AnimState:PushAnimation("picked", false)
end

local function onregenfn(inst)
    inst.AnimState:PlayAnimation("grow")
    inst.AnimState:PushAnimation("idle", true)
end

local function makeemptyfn(inst)
    inst.AnimState:PlayAnimation("picked")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst:AddTag("lichen")

    inst.AnimState:SetBank("algae_bush")
    inst.AnimState:SetBuild("algae_bush")
    inst.AnimState:PlayAnimation("idle", true)

    inst.MiniMapEntity:SetIcon("lichen.png")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)

    local color = 0.75 + math.random() * 0.25
    inst.AnimState:SetMultColour(color, color, color, 1)

    inst:AddComponent("pickable")
    inst.components.pickable.picksound = "dontstarve/wilson/pickup_reeds"
    inst.components.pickable:SetUp("cutlichen", TUNING.LICHEN_REGROW_TIME)
    inst.components.pickable.onregenfn = onregenfn
    inst.components.pickable.onpickedfn = onpickedfn
    inst.components.pickable.makeemptyfn = makeemptyfn

    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)
    MakeNoGrowInWinter(inst)
    MakeHauntableIgnite(inst)

    return inst
end

return Prefab("lichen", fn, assets, prefabs)
