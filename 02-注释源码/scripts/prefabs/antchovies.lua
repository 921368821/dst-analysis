--============================================================
-- 文件：prefabs/antchovies.lua
-- 模块：预制体 / antchovies（建筑与容器）
-- 职责：实体「antchovies」的预制体定义。SpawnPrefab("antchovies") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--This prefab is shipped but not used anymore.
local assets =
{
	Asset("PKGREF", "anim/antchovy.zip"),
}

local function fn()

    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()
    MakeInventoryPhysics(inst)

    inst.entity:AddDynamicShadow()

    inst.DynamicShadow:SetSize(0.65, 0.25)

    inst.AnimState:SetBank("antchovy")
    inst.AnimState:SetBuild("antchovy")
	inst.AnimState:PlayAnimation("idle_ground")

    inst.scrapbook_anim = "idle_ground"

	inst.Transform:SetTwoFaced()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

	--inst:SetStateGraph("SGantchovies")

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = TUNING.CALORIES_TINY
    inst.components.edible.sanityvalue = 0
    inst.components.edible.foodtype = FOODTYPE.MEAT

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    return inst
end

return Prefab("antchovies", fn, assets)
