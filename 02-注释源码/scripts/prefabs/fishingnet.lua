--============================================================
-- 文件：prefabs/fishingnet.lua
-- 模块：预制体 / fishingnet（建筑与容器）
-- 职责：实体「fishingnet」的预制体定义。SpawnPrefab("fishingnet") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	--fishingnet unused, so switching to PKGREF
	Asset("PKGREF", "anim/boat_net.zip"),
	Asset("PKGREF", "anim/swap_boat_net.zip"),
}

local prefabs =
{
    "fishingnetvisualizer"
}

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_object", "swap_boat_net", "swap_boat_net")
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function onunequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
end

local function onpocket(inst, owner)

end

local function onattack(weapon, attacker, target)

end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst:AddTag("allow_action_on_impassable")

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("boat_net")
    inst.AnimState:SetBuild("boat_net")
    inst.AnimState:PlayAnimation("idle")

    inst.MiniMapEntity:SetIcon("boat_net.png")

    MakeInventoryFloatable(inst, "large", nil, {0.68, 0.5, 0.68})

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.FISHING_NET_USES)
    inst.components.finiteuses:SetUses(TUNING.FISHING_NET_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)
    inst.components.finiteuses:SetConsumption(ACTIONS.CAST_NET, 1)

    inst:AddComponent("inventoryitem")
    inst:AddComponent("fishingnet")
    inst:AddComponent("inspectable")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnPocket(onpocket)
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    inst:AddComponent("burnable")
    inst.components.burnable.canlight = false
    inst.components.burnable.fxprefab = nil

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("fishingnet", fn, assets, prefabs)
