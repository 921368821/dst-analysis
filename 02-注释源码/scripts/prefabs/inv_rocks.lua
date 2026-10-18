--============================================================
-- 文件：prefabs/inv_rocks.lua
-- 模块：预制体 / inv_rocks（建筑与容器）
-- 职责：实体「inv_rocks」的预制体定义。SpawnPrefab("inv_rocks") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/rocks.zip"),
}

local names = { "f1", "f2", "f3" }

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data and data.anim then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("rocks")
    inst.AnimState:SetBuild("rocks")

    inst.pickupsound = "rock"

    inst:AddTag("molebait")
    inst:AddTag("quakedebris")
    inst:AddTag("rocks")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.animname = names[math.random(#names)]
    inst.AnimState:PlayAnimation(inst.animname)

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ELEMENTAL
    inst.components.edible.hungervalue = 1

    inst:AddComponent("tradable")
    inst.components.tradable.rocktribute = 1

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("bait")

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.STONE
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_ROCKS_HEALTH

	inst:AddComponent("snowmandecor")

    if TheNet:GetServerGameMode() == "quagmire" then
        event_server_data("quagmire", "prefabs/inv_rocks").master_postinit(inst)
    end

    MakeHauntableLaunchAndSmash(inst)

    inst.OnSave = onsave
    inst.OnLoad = onload

    return inst
end

return Prefab("rocks", fn, assets)
