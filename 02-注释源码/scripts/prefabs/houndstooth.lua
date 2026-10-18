--============================================================
-- 文件：prefabs/houndstooth.lua
-- 模块：预制体 / houndstooth（敌对生物）
-- 职责：实体「houndstooth」的预制体定义。SpawnPrefab("houndstooth") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/hounds_tooth.zip"),
    Asset("ANIM", "anim/hounds_tooth_water.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("houndstooth")
    inst.AnimState:SetBuild("hounds_tooth")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("blowpipeammo")
    inst:AddTag("reloaditem_ammo") -- Action string.

    inst.pickupsound = "rock"

    MakeInventoryFloatable(inst, "small", nil, {0.6, 0.55, 0.6})
    inst.AnimState:AddOverrideBuild("hounds_tooth_water")

    --selfstacker (from selfstacker component) added to pristine state for optimization
    inst:AddTag("selfstacker")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("reloaditem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("selfstacker")

	inst:AddComponent("snowmandecor")

    MakeHauntableLaunchAndSmash(inst)

    inst:ListenForEvent("floater_startfloating", function(inst) inst.AnimState:PlayAnimation("float") end)
    inst:ListenForEvent("floater_stopfloating", function(inst) inst.AnimState:PlayAnimation("idle") end)

    return inst
end

return Prefab("houndstooth", fn, assets)