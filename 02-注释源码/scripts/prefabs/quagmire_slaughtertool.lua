--============================================================
-- 文件：prefabs/quagmire_slaughtertool.lua
-- 模块：预制体 / quagmire_slaughtertool（建筑与容器）
-- 职责：实体「quagmire_slaughtertool」的预制体定义。SpawnPrefab("quagmire_slaughtertool") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_slaughtertool.zip"),
}

local function GetSlaughterActionString(inst, target)
    local t = GetTime()
    if target ~= inst._lasttarget or inst._lastactionstr == nil or inst._actionresettime < t then
        inst._lastactionstr = GetRandomItem(STRINGS.ACTIONS.SLAUGHTER)
        inst._lasttarget = target
    end
    inst._actionresettime = t + .1
    return inst._lastactionstr
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_slaughtertool")
    inst.AnimState:SetBuild("quagmire_slaughtertool")
    inst.AnimState:PlayAnimation("idle")

    inst.GetSlaughterActionString = GetSlaughterActionString

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_slaughtertool").master_postinit(inst)

    return inst
end

return Prefab("quagmire_slaughtertool", fn, assets)
