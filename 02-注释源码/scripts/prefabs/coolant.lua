--============================================================
-- 文件：prefabs/coolant.lua
-- 模块：预制体 / coolant（建筑与容器）
-- 职责：实体「coolant」的预制体定义。SpawnPrefab("coolant") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets = {
    Asset("ANIM", "anim/coolant.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("coolant")
    inst.AnimState:SetBuild("coolant")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetSymbolLightOverride("bubble_parts", 0.5)

    --waterproofer (from waterproofer component) added to pristine state for optimization
    inst:AddTag("waterproofer")
    inst:AddTag("coolant")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("waterproofer")
    inst.components.waterproofer:SetEffectiveness(0)

    MakeHauntableLaunch(inst)

    inst:AddComponent("inventoryitem")

    return inst
end

return Prefab("coolant", fn, assets)
