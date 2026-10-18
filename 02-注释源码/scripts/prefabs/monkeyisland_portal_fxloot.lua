--============================================================
-- 文件：prefabs/monkeyisland_portal_fxloot.lua
-- 模块：预制体 / monkeyisland_portal_fxloot（建筑与容器）
-- 职责：实体「monkeyisland_portal_fxloot」的预制体定义。SpawnPrefab("monkeyisland_portal_fxloot") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/fx_portal_items.zip"),
}

local FX_TYPES = { "grass", "pine", "rock", "shell", }

local function test_for_ground(inst)
    local x, y, z = inst.Transform:GetWorldPosition()
    if y < 0.2 then
        inst.AnimState:Resume()
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("fx_portal_items")
    inst.AnimState:SetBuild("fx_portal_items")
    inst.AnimState:PlayAnimation(FX_TYPES[math.random(#FX_TYPES)])
    inst.AnimState:Pause()

    if not TheNet:IsDedicated() then
        inst:AddComponent("groundshadowhandler")
        inst.components.groundshadowhandler:SetSize(0.8, 0.5)
    end

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    inst:ListenForEvent("animover", inst.Remove)

    -- Figure out when we've hit the ground, to die.
    inst:DoPeriodicTask(FRAMES, test_for_ground)

    return inst
end

return Prefab("monkeyisland_portal_fxloot", fn, assets)
