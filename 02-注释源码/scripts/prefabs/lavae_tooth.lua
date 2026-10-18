--============================================================
-- 文件：prefabs/lavae_tooth.lua
-- 模块：预制体 / lavae_tooth（建筑与容器）
-- 职责：实体「lavae_tooth」的预制体定义。SpawnPrefab("lavae_tooth") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/lavae_egg_tooth.zip"),
    Asset("SOUND", "sound/together.fsb"),
}

local prefabs =
{
    "lavae_pet",
    "small_puff",
    "ash",
}

local function OnSpawnFX(pet)
    SpawnPrefab("small_puff").Transform:SetPosition(pet.Transform:GetWorldPosition())
end

local function OnSpawn(inst, pet)
    if not inst.nospawnfx then
        --Delayed in case we need to relocate for migration spawning
        pet:DoTaskInTime(0, OnSpawnFX)
    end
    inst:ListenForEvent("onremove", inst.OnPetLost, pet)
end

local function OnDespawn(inst, pet)
    SpawnPrefab("small_puff").Transform:SetPosition(pet.Transform:GetWorldPosition())
    inst:RemoveEventCallback("onremove", inst.OnPetLost, pet)
    pet:Remove()
end

local function OnPetLost(inst, pet)
    local remains = SpawnPrefab("ash")
    local owner = inst.components.inventoryitem.owner
    local holder = owner ~= nil and (owner.components.inventory or owner.components.container) or nil
    if holder ~= nil then
        local slot = holder:GetItemSlot(inst)
        inst:Remove()
        holder:GiveItem(remains, slot)
    else
        local x, y, z = inst.Transform:GetWorldPosition()
        inst:Remove()
        remains.Transform:SetPosition(x, y, z)
        SpawnPrefab("small_puff").Transform:SetPosition(x, y, z)
    end
    remains.SoundEmitter:PlaySound("dontstarve/creatures/together/lavae/egg_hatch", nil, .15)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBuild("lavae_egg_tooth")
    inst.AnimState:SetBank("lavae_egg_tooth")
    inst.AnimState:PlayAnimation("idle")

    inst.Transform:SetScale(0.75, 0.75, 0.75)

    MakeInventoryFloatable(inst, "small", 0.05)
    inst:AddTag("donotautopick")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    inst:AddComponent("inspectable")
    inst:AddComponent("leader")

    inst:AddComponent("petleash")
    inst.components.petleash:SetPetPrefab("lavae_pet")
    inst.components.petleash:SetOnSpawnFn(OnSpawn)
    inst.components.petleash:SetOnDespawnFn(OnDespawn)

    inst.nospawnfx = nil
    inst.OnPetLost = function(pet) OnPetLost(inst, pet) end

    return inst
end

return Prefab("lavae_tooth", fn, assets, prefabs)
