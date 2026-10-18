--============================================================
-- 文件：prefabs/stalker_ferns.lua
-- 模块：预制体 / stalker_ferns（建筑与容器）
-- 职责：实体「stalker_ferns」的预制体定义。SpawnPrefab("stalker_ferns") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/forest_ferns.zip"),
}

local prefabs =
{
    "foliage",
}

local NUM_VARIATIONS = 4

local function KillPlant(inst)
    inst._killtask = nil
    inst.components.pickable.caninteractwith = false
    inst:ListenForEvent("animover", inst.Remove)
    inst.AnimState:PlayAnimation("wilt"..inst.variation)
end

local function OnBloomed(inst)
    inst:RemoveEventCallback("animover", OnBloomed)
    inst.AnimState:PlayAnimation("idle"..inst.variation, true)
    inst.components.pickable.caninteractwith = true
    inst._killtask = inst:DoTaskInTime(TUNING.STALKER_BLOOM_DECAY + math.random(), KillPlant)
end

local function OnPicked(inst)--, picker, loot)
    if inst._killtask ~= nil then
        inst._killtask:Cancel()
        inst._killtask = nil
    end
    inst:RemoveEventCallback("animover", OnBloomed)
    inst:ListenForEvent("animover", inst.Remove)
    inst.AnimState:PlayAnimation("picked"..inst.variation)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("forest_fern")
    inst.AnimState:SetBuild("forest_ferns")
    inst.AnimState:PlayAnimation("bloom")

    inst:AddTag("stalkerbloom")

    inst:SetPrefabNameOverride("cave_fern")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.SoundEmitter:PlaySound("dontstarve/creatures/together/stalker/flowergrow")

    inst.variation = math.random(NUM_VARIATIONS)
    if inst.variation > 1 then
        inst.variation = tostring(inst.variation)
        inst.AnimState:PlayAnimation("bloom"..inst.variation)
    else
        inst.variation = ""
    end

    inst:AddComponent("pickable")
    inst.components.pickable.picksound = "dontstarve/wilson/pickup_plants"
    inst.components.pickable.onpickedfn = OnPicked
    inst.components.pickable.quickpick = true
    inst.components.pickable.caninteractwith = false
    inst.components.pickable:SetUp("foliage", 1000000, inst.variation == "2" and 1 or 2)
    inst.components.pickable:Pause()

    inst:AddComponent("inspectable")
    inst:AddComponent("lootdropper")

    inst:ListenForEvent("animover", OnBloomed)

    ---------------------
    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)
    --Clear default handlers so we don't stomp our .persists flag
    inst.components.burnable:SetOnIgniteFn(nil)
    inst.components.burnable:SetOnExtinguishFn(nil)
    ---------------------

    MakeHauntableIgnite(inst)

    inst.persists = false

    return inst
end

return Prefab("stalker_fern", fn, assets, prefabs)
