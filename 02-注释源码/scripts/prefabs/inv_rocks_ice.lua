--============================================================
-- 文件：prefabs/inv_rocks_ice.lua
-- 模块：预制体 / inv_rocks_ice（建筑与容器）
-- 职责：实体「inv_rocks_ice」的预制体定义。SpawnPrefab("inv_rocks_ice") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/ice.zip"),
}

local names = { "f1","f2","f3" }

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data and data.anim then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)
    end
end

local function onperish(inst)
    local owner = inst.components.inventoryitem.owner
    if owner ~= nil then
        local stacksize = inst.components.stackable:StackSize()
        DoDeltaMoistureToEntity(owner, 2 * stacksize, 2, true)
        inst:Remove()
    else
        local stacksize = inst.components.stackable:StackSize()
		local x, y, z = inst.Transform:GetWorldPosition()
        TheWorld.components.farming_manager:AddSoilMoistureAtPoint(x, y, z, stacksize * TUNING.ICE_MELT_GROUND_MOISTURE_AMOUNT)

		inst.persists = false
        inst.components.inventoryitem.canbepickedup = false
        inst.AnimState:PlayAnimation("melt")
        inst:ListenForEvent("animover", inst.Remove)
    end
end

local function onfiremelt(inst)
    inst.components.perishable.frozenfiremult = true
end

local function onstopfiremelt(inst)
    inst.components.perishable.frozenfiremult = false
end

local function onuseaswatersource(inst)
    if inst.components.stackable:IsStack() then
        inst.components.stackable:Get():Remove()
    else
        inst:Remove()
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("ice")
    inst.AnimState:SetBuild("ice")

    inst:AddTag("frozen")
    inst:AddTag("molebait")
    -- From watersource component
    inst:AddTag("watersource")

    MakeInventoryFloatable(inst, "med", 0.05, {0.65, 0.5, 0.65})

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.animname = names[math.random(#names)]
    inst.AnimState:PlayAnimation(inst.animname)

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.GENERIC
    inst.components.edible.healthvalue = TUNING.HEALING_TINY/2
    inst.components.edible.hungervalue = TUNING.CALORIES_TINY/4
    inst.components.edible.degrades_with_spoilage = false
    inst.components.edible.temperaturedelta = TUNING.COLD_FOOD_BONUS_TEMP
    inst.components.edible.temperatureduration = TUNING.FOOD_TEMP_BRIEF * 1.5

    inst:AddComponent("smotherer")

    inst:ListenForEvent("firemelt", onfiremelt)
    inst:ListenForEvent("stopfiremelt", onstopfiremelt)

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_SUPERFAST)
    inst.components.perishable:StartPerishing()
    inst.components.perishable:SetOnPerishFn(onperish)

    inst:AddComponent("tradable")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem.imagename = "ice"
    inst.components.inventoryitem:SetOnPutInInventoryFn(onstopfiremelt)

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.ICE
    inst.components.repairer.perishrepairpercent = .25

    inst:AddComponent("watersource")
    inst.components.watersource.onusefn = onuseaswatersource
    inst.components.watersource.override_fill_uses = 1

	inst:AddComponent("snowmandecor")

    inst:AddComponent("bait")

    inst.OnSave = onsave
    inst.OnLoad = onload

    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab( "ice", fn, assets)