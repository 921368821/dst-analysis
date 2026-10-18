--============================================================
-- 文件：prefabs/spider_whistle.lua
-- 模块：预制体 / spider_whistle（敌对生物）
-- 职责：实体「spider_whistle」的预制体定义。SpawnPrefab("spider_whistle") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/spider_whistle.zip"),
}

local prefabs = 
{
    "spider_whistle_buff",
    "spider_summoned_buff",
}

local function CanHerd(whistle, leader)
    if not leader:HasTag("spiderwhisperer") then
        return false, "WEBBERONLY"
    end

    return true
end

local SPIDER_MUST_TAGS = { "spider" }
local SPIDER_CANT_TAGS = { "spiderqueen", "creaturecorpse", "NOCLICK" }

local SPIDERDEN_ONEOF_TAGS = { "spidercocoon", "spiderden" }
local function OnHerd(whistle, leader)
    local x, y, z = leader.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, TUNING.SPIDER_WHISTLE_RANGE, nil, nil, SPIDERDEN_ONEOF_TAGS)

    for _, den in pairs(ents) do
        if den.components.childspawner and den.components.childspawner.childreninside > 0 and den.SummonChildren then
            den:SummonChildren()
        end
    end

    ents = TheSim:FindEntities(x, y, z, TUNING.SPIDER_WHISTLE_RANGE, SPIDER_MUST_TAGS, SPIDER_CANT_TAGS)
    for _, spider in pairs(ents) do
        if spider.components.sleeper and spider.components.sleeper:IsAsleep() then
            spider.components.sleeper:WakeUp()
            spider:AddDebuff("spider_summoned_buff", "spider_summoned_buff")
        end
    end

    for follower, v in pairs(leader.components.leader.followers) do
        if follower:HasTag("spider") then
            follower:AddDebuff("spider_whistle_buff", "spider_whistle_buff")
        end
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("spider_whistle")
    inst.AnimState:SetBuild("spider_whistle")
    inst.AnimState:PlayAnimation("idle", true)
    MakeInventoryPhysics(inst)

    MakeInventoryFloatable(inst, "small", 0.15, 0.9)

	inst:AddTag("spider_whistle")

    inst.scrapbook_specialinfo = "SPIDERWHISTLE"

	inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")
    inst:AddComponent("inspectable")
    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetOnFinished(function() inst:Remove() end)

    inst:AddComponent("followerherder")
    inst.components.followerherder:SetCanHerdFn(CanHerd)
    inst.components.followerherder:SetOnHerdFn(OnHerd)
    inst.components.followerherder:SetUseAmount(TUNING.SPIDER_WHISTLE_USE_AMOUNT)

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)

    MakeSmallPropagator(inst)
    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("spider_whistle", fn, assets, prefabs)