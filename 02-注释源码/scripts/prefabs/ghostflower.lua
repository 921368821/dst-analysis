--============================================================
-- 文件：prefabs/ghostflower.lua
-- 模块：预制体 / ghostflower（建筑与容器）
-- 职责：实体「ghostflower」的预制体定义。SpawnPrefab("ghostflower") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/ghostflower.zip"),

    Asset("ANIM", "anim/spell_icons_wendy.zip"),
}

local prefabs =
{
	"ghostflower_spirit1_fx",
	"ghostflower_spirit2_fx",
}

local function dofx(inst)
	if not inst.inlimbo then
		local fx = SpawnPrefab("ghostflower_spirit"..tostring(math.random(2)).."_fx")
		fx.Transform:SetPosition(inst.Transform:GetWorldPosition())

		inst:DoTaskInTime(3 + math.random() * 6, dofx) -- the min delay needs to be greater than the grow animation + it's delay
	end
end

local function DoGrow(inst)
	inst:Show()
    inst.AnimState:PlayAnimation("grow")
    inst.AnimState:PushAnimation("idle", true)
end

local function DelayedGrow(inst)
	inst:Hide()
	inst:DoTaskInTime(0.25 + math.random() * 0.25, DoGrow)
end

local function toground(inst)
    inst.AnimState:PlayAnimation("idle", true)
	inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)

	inst:DoTaskInTime(3 + math.random() * 6, dofx)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
    inst.AnimState:SetBank("ghostflower")
    inst.AnimState:SetBuild("ghostflower")
    inst.AnimState:PlayAnimation("idle", true)

    inst:AddTag("ghostflower")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
	inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:ListenForEvent("ondropped", toground)

	inst.DelayedGrow = DelayedGrow

	toground(inst)

    return inst
end

return Prefab("ghostflower", fn, assets, prefabs)
