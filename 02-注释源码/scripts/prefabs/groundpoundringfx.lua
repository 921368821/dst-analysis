--============================================================
-- 文件：prefabs/groundpoundringfx.lua
-- 模块：预制体 / groundpoundringfx（建筑与容器）
-- 职责：实体「groundpoundringfx」的预制体定义。SpawnPrefab("groundpoundringfx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/bearger_ring_fx.zip"),
}

local function PlayRingAnim(proxy)
    local inst = CreateEntity()

    inst:AddTag("FX")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.Transform:SetFromProxy(proxy.GUID)

    inst.AnimState:SetBank("bearger_ring_fx")
    inst.AnimState:SetBuild("bearger_ring_fx")
    inst.AnimState:PlayAnimation("idle")
    inst.AnimState:SetFinalOffset(3)

    inst.AnimState:SetOrientation( ANIM_ORIENTATION.OnGround )
    inst.AnimState:SetLayer( LAYER_BACKGROUND )
    inst.AnimState:SetSortOrder( 3 )

    inst:ListenForEvent("animover", inst.Remove)

	if proxy._fastforward:value() then
		inst.AnimState:SetFrame(5)
	end
end

local function FastForward(inst)
	inst._fastforward:set(true)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    --Dedicated server does not need to spawn the local fx
    if not TheNet:IsDedicated() then
        --Delay one frame so that we are positioned properly before starting the effect
        --or in case we are about to be removed
		inst:DoTaskInTime(0, PlayRingAnim)
    end

	inst._fastforward = net_bool(inst.GUID, "groundpoundring_fx._fastforward")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst.FastForward = FastForward
    inst.persists = false
    inst:DoTaskInTime(3, inst.Remove)

    return inst
end

return Prefab("groundpoundring_fx", fn, assets)
