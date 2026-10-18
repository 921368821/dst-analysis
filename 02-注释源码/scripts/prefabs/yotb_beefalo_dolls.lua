--============================================================
-- 文件：prefabs/yotb_beefalo_dolls.lua
-- 模块：预制体 / yotb_beefalo_dolls（建筑与容器）
-- 职责：实体「yotb_beefalo_dolls」的预制体定义。SpawnPrefab("yotb_beefalo_dolls") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/beefalo_doll.zip"),

    Asset("INV_IMAGE", "beefalo_doll_doll"),
    Asset("INV_IMAGE", "beefalo_doll_festive"),
    Asset("INV_IMAGE", "beefalo_doll_formal"),
    Asset("INV_IMAGE", "beefalo_doll_ice"),
    Asset("INV_IMAGE", "beefalo_doll_nature"),
    Asset("INV_IMAGE", "beefalo_doll_robot"),
    Asset("INV_IMAGE", "beefalo_doll_victorian"),
    Asset("INV_IMAGE", "beefalo_doll_war"),
    Asset("INV_IMAGE", "beefalo_doll_beast"),
}

local function getstatus(inst)
    return IsSpecialEventActive(SPECIAL_EVENTS.YOTB) and "YOTB"
end

local function doappraise(inst,target)
    if target.components.yotb_stager then
        target.components.yotb_stager:appraisedoll(inst)
    end
end

local function canappraise(inst,target)
    if not target.sg:HasStateTag("ready") then
        return false, "NOTNOW"
    end

    return true
end

local function make(name,build,bank,anim, category)

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation(anim)

        inst:AddTag("cattoy")
        inst:AddTag("beefalo_doll")

        MakeInventoryFloatable(inst, "med", 0.05, 0.68)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("appraisable")
        inst.components.appraisable.appraisefn = doappraise
        inst.components.appraisable.canappraisefn = canappraise

        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem:ChangeImageName("beefalo_doll_"..anim)

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        inst:AddComponent("inspectable")
        inst.components.inspectable.getstatus = getstatus

        inst:AddComponent("tradable")
        inst.components.tradable.goldvalue = TUNING.GOLD_VALUES.YOTB_BEEFALO_DOLL

        inst:AddComponent("fuel")
        inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL

        MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
        MakeSmallPropagator(inst)

        MakeHauntableLaunchAndIgnite(inst)
        inst.category = category

        return inst
    end

    return Prefab(name, fn, assets)
end

return  make("yotb_beefalo_doll_war","beefalo_doll","beefalo_doll","war","WAR"),
        make("yotb_beefalo_doll_doll","beefalo_doll","beefalo_doll","doll","DOLL"),
        make("yotb_beefalo_doll_festive","beefalo_doll","beefalo_doll","festive","FESTIVE"),
        make("yotb_beefalo_doll_nature","beefalo_doll","beefalo_doll","nature", "NATURE"),
        make("yotb_beefalo_doll_robot","beefalo_doll","beefalo_doll","robot", "ROBOT"),
        make("yotb_beefalo_doll_ice","beefalo_doll","beefalo_doll","ice", "ICE"),
        make("yotb_beefalo_doll_formal","beefalo_doll","beefalo_doll","formal", "FORMAL"),
        make("yotb_beefalo_doll_victorian","beefalo_doll","beefalo_doll","victorian", "VICTORIAN"),
        make("yotb_beefalo_doll_beast","beefalo_doll","beefalo_doll","beast", "BEAST")
