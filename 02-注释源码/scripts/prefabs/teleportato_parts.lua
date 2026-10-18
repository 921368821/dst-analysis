--============================================================
-- 文件：prefabs/teleportato_parts.lua
-- 模块：预制体 / teleportato_parts（建筑与容器）
-- 职责：实体「teleportato_parts」的预制体定义。SpawnPrefab("teleportato_parts") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/teleportato_parts.zip"),
    Asset("ANIM", "anim/teleportato_parts_build.zip"),
    Asset("ANIM", "anim/teleportato_adventure_parts_build.zip"),
	Asset("INV_IMAGE", "teleportato_box_adv" ),
	Asset("INV_IMAGE", "teleportato_crank_adv" ),
	Asset("INV_IMAGE", "teleportato_potato_adv" ),
	Asset("INV_IMAGE", "teleportato_ring_adv" ),
}

local function makefn(name, frame)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("parts")
        inst.AnimState:PlayAnimation(frame, false)
        inst.scrapbook_anim = frame

        inst:AddTag("irreplaceable")
        inst:AddTag("teleportato_part")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")

        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem:SetSinks(true)

        inst.AnimState:SetBuild("teleportato_parts_build")

        inst:AddComponent("tradable")

        MakeHauntableLaunch(inst)

        return inst
    end
end

local function TeleportatoPart(name, frame)
    return Prefab(name, makefn(name, frame), assets)
end

return TeleportatoPart("teleportato_ring", "ring"),
    TeleportatoPart("teleportato_box", "lever"),
    TeleportatoPart("teleportato_crank", "support"),
    TeleportatoPart("teleportato_potato", "potato")