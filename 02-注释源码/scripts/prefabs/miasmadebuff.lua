--============================================================
-- 文件：prefabs/miasmadebuff.lua
-- 模块：预制体 / miasmadebuff（建筑与容器）
-- 职责：实体「miasmadebuff」的预制体定义。SpawnPrefab("miasmadebuff") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnTick(inst, target)
    if target.components.health ~= nil and
        not target.components.health:IsDead() and
        not target:HasTag("playerghost") then
        if target.components.inventory == nil or not target.components.inventory:EquipHasTag("miasmaimmune") then
            target.components.health:DoDelta(TUNING.MIASMA_DEBUFF_TICK_VALUE, nil, "miasma")
        end
    else
        inst.components.debuff:Stop()
    end
end

local function OnAttached(inst, target)
    inst.entity:SetParent(target.entity)
    inst.Transform:SetPosition(0, 0, 0) --in case of loading
    inst.task = inst:DoPeriodicTask(TUNING.MIASMA_DEBUFF_TICK_RATE, OnTick, nil, target)
    inst:ListenForEvent("death", function()
        inst.components.debuff:Stop()
    end, target)
end

local function fn()
    local inst = CreateEntity()

    if not TheWorld.ismastersim then
        --Not meant for client!
        inst:DoTaskInTime(0, inst.Remove)

        return inst
    end

    inst.entity:AddTransform()

    --[[Non-networked entity]]
    --inst.entity:SetCanSleep(false)
    inst.entity:Hide()
    inst.persists = false

    inst:AddTag("CLASSIFIED")

    inst:AddComponent("debuff")
    inst.components.debuff:SetAttachedFn(OnAttached)
    inst.components.debuff:SetDetachedFn(inst.Remove)

    return inst
end

return Prefab("miasmadebuff", fn)
