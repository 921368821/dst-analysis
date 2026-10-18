--============================================================
-- 文件：prefabs/hermit_pearl.lua
-- 模块：预制体 / hermit_pearl（建筑与容器）
-- 职责：实体「hermit_pearl」的预制体定义。SpawnPrefab("hermit_pearl") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/hermit_pearl.zip"),
}

local function commonfn(anim, minimapicon)
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()

    if minimapicon ~= nil then
        inst.entity:AddMiniMapEntity()
    end

    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    if minimapicon ~= nil then
        inst.MiniMapEntity:SetIcon(minimapicon..".png")
        inst.MiniMapEntity:SetPriority(7)
    end

    inst:AddTag("irreplaceable")
    inst:AddTag("hermitpearl")

    inst.AnimState:SetBank("hermit_pearl")
    inst.AnimState:SetBuild("hermit_pearl")
    inst.AnimState:PlayAnimation(anim)

    MakeInventoryFloatable(inst, "med", .15, 0.7)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    WORLDSTATETAGS.SetTagEnabled("CRABBY_HERMIT_HAPPY", true) -- NOTES(JBK): Placing it on the pearl itself instead of the hermitcrab since this is the key for game logic.

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst:AddComponent("tradable")

    MakeHauntableLaunch(inst)

    return inst
end

local function fn()
    local inst = commonfn("idle", "hermit_pearl")

    inst:AddTag("gem")

    return inst
end

local function crackedfn()
    return commonfn("cracked")
end

return
    Prefab("hermit_pearl",         fn,        assets),
    Prefab("hermit_cracked_pearl", crackedfn, assets)