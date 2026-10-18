--============================================================
-- 文件：prefabs/gunpowder.lua
-- 模块：预制体 / gunpowder（建筑与容器）
-- 职责：实体「gunpowder」的预制体定义。SpawnPrefab("gunpowder") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/gunpowder.zip"),
}

local prefabs =
{
    "explode_small",
}

local function OnIgniteFn(inst)
    inst.SoundEmitter:PlaySound("dontstarve/common/blackpowder_fuse_LP", "hiss")
    DefaultBurnFn(inst)
end

local function OnExtinguishFn(inst)
    inst.SoundEmitter:KillSound("hiss")
    DefaultExtinguishFn(inst)
end

local function OnExplodeFn(inst)
    inst.SoundEmitter:KillSound("hiss")
    SpawnPrefab("explode_small").Transform:SetPosition(inst.Transform:GetWorldPosition())
end

local function OnPutInInv(inst, owner)
    if owner.prefab == "mole" then
        inst.components.explosive:OnBurnt()
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("gunpowder")
    inst.AnimState:SetBuild("gunpowder")
    inst.AnimState:PlayAnimation("idle")

    --inst.pickupsound = "grainy"

    inst:AddTag("molebait")
    inst:AddTag("explosive")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst, 3 + math.random() * 3)
    MakeSmallPropagator(inst)
    --V2C: Remove default OnBurnt handler, as it conflicts with
    --explosive component's OnBurnt handler for removing itself
    inst.components.burnable:SetOnBurntFn(nil)
    inst.components.burnable:SetOnIgniteFn(OnIgniteFn)
    inst.components.burnable:SetOnExtinguishFn(OnExtinguishFn)

    inst:AddComponent("explosive")
    inst.components.explosive:SetOnExplodeFn(OnExplodeFn)
    inst.components.explosive.explosivedamage = TUNING.GUNPOWDER_DAMAGE

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetOnPutInInventoryFn(OnPutInInv)
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("bait")

    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("gunpowder", fn, assets, prefabs)
