--============================================================
-- 文件：prefabs/moonrockcrater.lua
-- 模块：预制体 / moonrockcrater（建筑与容器）
-- 职责：实体「moonrockcrater」的预制体定义。SpawnPrefab("moonrockcrater") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/mooneyes.zip"),
}

local prefabs =
{
    "purplemooneye",
    "bluemooneye",
    "redmooneye",
    "orangemooneye",
    "yellowmooneye",
    "greenmooneye",
}

local function ItemTradeTest(inst, item)
    if item == nil then
        return false
    elseif string.sub(item.prefab, -3) ~= "gem" or not item:HasTag("gem") then
        return false, "NOTGEM"
    elseif string.sub(item.prefab, -11, -4) == "precious" then
        return false, "WRONGGEM"
    end
    return true
end

local function OnGemGiven(inst, giver, item)
    local mooneye = SpawnPrefab(string.sub(item.prefab, 1, -4).."mooneye")
    local container = inst.components.inventoryitem:GetContainer()
    if container ~= nil then
        local slot = inst.components.inventoryitem:GetSlotNum()
        inst:Remove()
        container:GiveItem(mooneye, slot)
    else
        local x, y, z = inst.Transform:GetWorldPosition()
        inst:Remove()
        mooneye.Transform:SetPosition(x, y, z)
    end
    mooneye.SoundEmitter:PlaySound("dontstarve/common/telebase_gemplace")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:SetBank("mooneyes")
    inst.AnimState:SetBuild("mooneyes")
    inst.AnimState:PlayAnimation("crater")
    inst.scrapbook_anim = "crater"

    inst:AddTag("gemsocket")

    --trader (from trader component) added to pristine state for optimization
    inst:AddTag("trader")
	inst:AddTag("give_dolongaction")

    inst.scrapbook_specialinfo = "CRATEREDMOONROCK"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.MOONROCK
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_MOONROCK_CRATER_HEALTH
    inst.components.repairer.workrepairvalue = TUNING.REPAIR_MOONROCK_CRATER_WORK

    inst:AddComponent("trader")
    inst.components.trader:SetAbleToAcceptTest(ItemTradeTest)
    inst.components.trader.onaccept = OnGemGiven

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("moonrockcrater", fn, assets, prefabs)
