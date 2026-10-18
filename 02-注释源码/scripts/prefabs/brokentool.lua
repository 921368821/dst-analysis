--============================================================
-- 文件：prefabs/brokentool.lua
-- 模块：预制体 / brokentool（建筑与容器）
-- 职责：实体「brokentool」的预制体定义。SpawnPrefab("brokentool") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/broken_tool.zip"),
}

local function PlayBrokenAnim(proxy)
    local inst = CreateEntity()

    inst:AddTag("FX")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    MakeInventoryPhysics(inst)

    inst.Transform:SetFromProxy(proxy.GUID)

    inst.AnimState:SetBank("broketool")
    inst.AnimState:SetBuild("broken_tool")
    inst.AnimState:PlayAnimation("used")

    inst:ListenForEvent("animover", inst.Remove)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    --Delay one frame so that we are positioned properly before starting the effect
    --or in case we are about to be removed
    inst:DoTaskInTime(0, PlayBrokenAnim)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    inst:DoTaskInTime(1, inst.Remove)

    return inst
end

return Prefab("brokentool", fn, assets)
