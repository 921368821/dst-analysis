--============================================================
-- 文件：prefabs/damagenumber.lua
-- 模块：预制体 / damagenumber（建筑与容器）
-- 职责：实体「damagenumber」的预制体定义。SpawnPrefab("damagenumber") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local COLOUR = { 255 / 255, 80 / 255, 40 / 255, 1 }

local function PushDamageNumber(player, target, damage, large)
    player.HUD:ShowPopupNumber(damage, large and 48 or 32, target:GetPosition(), 40, COLOUR, large)
end

local function OnDamageDirty(inst)
    if inst.target:value() ~= nil then
        local player = inst.entity:GetParent()
        if player ~= nil and player.HUD ~= nil then
            PushDamageNumber(player, inst.target:value(), inst.damage:value(), inst.large:value())
        end
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddNetwork()

    inst.target = net_entity(inst.GUID, "damagenumber.target")
    inst.damage = net_shortint(inst.GUID, "damagenumber.damage")
    inst.large = net_bool(inst.GUID, "damagenumber.large", "damagedirty")

    inst:AddTag("CLASSIFIED")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        inst:ListenForEvent("damagedirty", OnDamageDirty)

        return inst
    end

    inst.PushDamageNumber = PushDamageNumber
    event_server_data("lavaarena", "prefabs/damagenumber").master_postinit(inst)

    return inst
end

return Prefab("damagenumber", fn)
