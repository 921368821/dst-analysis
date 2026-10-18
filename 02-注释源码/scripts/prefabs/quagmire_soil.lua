--============================================================
-- 文件：prefabs/quagmire_soil.lua
-- 模块：预制体 / quagmire_soil（建筑与容器）
-- 职责：实体「quagmire_soil」的预制体定义。SpawnPrefab("quagmire_soil") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_soil.zip"),
}

local function IsLowPriorityAction(act)
    return act == nil or act.action ~= ACTIONS.PLANTSOIL
end

--Runs on clients
local function CanMouseThrough(inst)
    if ThePlayer ~= nil and ThePlayer.components.playeractionpicker ~= nil then
        local lmb, rmb = ThePlayer.components.playeractionpicker:DoGetMouseActions(inst:GetPosition(), inst)
        return IsLowPriorityAction(rmb) and IsLowPriorityAction(lmb), true
    end
end

local function DisplayNameFn(inst)
	return TheInput:ControllerAttached() and TheInput:GetLocalizedControl(TheInput:GetControllerID(), VIRTUAL_CONTROL_INV_ACTION_LEFT).." "..GetActionString(ACTIONS.PLANTSOIL.id) or ""
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("quagmire_soil")
    inst.AnimState:SetBuild("quagmire_soil")
    inst.AnimState:PlayAnimation("rise")
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    inst:AddTag("soil")

    inst.CanMouseThrough = CanMouseThrough
    inst.displaynamefn = DisplayNameFn

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_soil").master_postinit(inst)

    return inst
end

return Prefab("quagmire_soil", fn, assets)
