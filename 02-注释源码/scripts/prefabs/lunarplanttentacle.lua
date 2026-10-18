--============================================================
-- 文件：prefabs/lunarplanttentacle.lua
-- 模块：预制体 / lunarplanttentacle（建筑与容器）
-- 职责：实体「lunarplanttentacle」的预制体定义。SpawnPrefab("lunarplanttentacle") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/lunarthrall_plant_vine.zip"),
}

local function shouldKeepTarget()
    return true
end

local function Despawn(inst)
    if inst.sg.currentstate.name ~= "attack_pst" then
        inst.sg:GoToState("attack_pst")
    else
        inst:Remove()
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.entity:AddPhysics()
    inst.Physics:SetCylinder(0.25, 2)

    inst.Transform:SetScale(0.55, 0.55, 0.55)

    inst.AnimState:SetBank("lunarthrall_plant_vine")
    inst.AnimState:SetBuild("lunarthrall_plant_vine")
    inst.AnimState:PlayAnimation("idle")
    inst.scrapbook_anim = "breach_idle"

    inst:AddTag("soulless")
    inst:AddTag("lunar_aligned")
    inst:AddTag("notarget")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

	--inst.owner is set when spawned from lunarplant_tentacle_weapon

    --
    local health = inst:AddComponent("health")
    health:SetMaxHealth(TUNING.TENTACLE_HEALTH)

    --
    local combat = inst:AddComponent("combat")
    combat:SetRange(2)
    combat:SetDefaultDamage(TUNING.LUNARPLANTTENTACLE_DAMAGE)
    combat:SetAttackPeriod(TUNING.TENTACLE_ATTACK_PERIOD)
    combat:SetKeepTargetFunction(shouldKeepTarget)

    --
    inst:AddComponent("planarentity")

    --
    local planardamage = inst:AddComponent("planardamage")
    planardamage:SetBaseDamage(TUNING.LUNARPLANTTENTACLE_PLANARDAMAGE)

    --
    local lootdropper = inst:AddComponent("lootdropper")
    lootdropper:SetLoot({})

    --
    MakeLargeFreezableCharacter(inst)

    --
    inst:SetStateGraph("SGlunarplanttentacle")

    --
    inst:DoTaskInTime(9, Despawn)
    inst.persists = false

    return inst
end

return Prefab("lunarplanttentacle", fn, assets)
