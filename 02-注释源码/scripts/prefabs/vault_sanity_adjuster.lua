--============================================================
-- 文件：prefabs/vault_sanity_adjuster.lua
-- 模块：预制体 / vault_sanity_adjuster（建筑与容器）
-- 职责：实体「vault_sanity_adjuster」的预制体定义。SpawnPrefab("vault_sanity_adjuster") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function NoSanityFalloffFn(inst, observer, distsq)
    return 1
end

local function SetSanityAuraValue(inst, auramagnitude, auraname)
    local sanityaura = inst.components.sanityaura or inst:AddComponent("sanityaura")
    sanityaura.aura = auramagnitude
    sanityaura:SetBaseAuraName(auraname)
    sanityaura.fallofffn = NoSanityFalloffFn
end

local function StartIncreasing(inst)
    SetSanityAuraValue(inst, TUNING.SANITYAURA_HUGE, "vault_sanity_adjuster_positive")
end

local function StartDecreasing(inst)
    SetSanityAuraValue(inst, -TUNING.SANITYAURA_HUGE, "vault_sanity_adjuster_negative")
end

local function TurnOff(inst)
    inst:RemoveComponent("sanityaura")
end

local function fn()
    local inst = CreateEntity()

    --[[Non-networked entity]]
    inst.entity:AddTransform()

    inst:AddTag("NOBLOCK")

    if not TheWorld.ismastersim then
        --Not meant for client!
        inst:DoTaskInTime(0, inst.Remove)
        return inst
    end

    inst.StartIncreasing = StartIncreasing
    inst.StartDecreasing = StartDecreasing
    inst.TurnOff = TurnOff

    return inst
end

------------------------------------------------------------------------------------------

local function fn_increasing()
    local inst = CreateEntity()

    --[[Non-networked entity]]
    inst.entity:AddTransform()

    inst:AddTag("NOBLOCK")

    if not TheWorld.ismastersim then
        --Not meant for client!
        inst:DoTaskInTime(0, inst.Remove)
        return inst
    end

    StartIncreasing(inst)

    return inst
end

------------------------------------------------------------------------------------------

local function fn_decreasing()
    local inst = CreateEntity()

    --[[Non-networked entity]]
    inst.entity:AddTransform()

    inst:AddTag("NOBLOCK")

    if not TheWorld.ismastersim then
        --Not meant for client!
        inst:DoTaskInTime(0, inst.Remove)
        return inst
    end

    StartDecreasing(inst)

    return inst
end

return Prefab("vault_sanity_adjuster", fn),
Prefab("vault_sanity_adjuster_alwaysincreasing", fn_increasing),
Prefab("vault_sanity_adjuster_alwaysdecreasing", fn_decreasing)