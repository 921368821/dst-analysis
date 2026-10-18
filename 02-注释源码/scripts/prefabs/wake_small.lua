--============================================================
-- 文件：prefabs/wake_small.lua
-- 模块：预制体 / wake_small（建筑与容器）
-- 职责：实体「wake_small」的预制体定义。SpawnPrefab("wake_small") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/water_squid_wake.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("water_squid_wake")
    inst.AnimState:SetBuild("water_squid_wake")
    inst.AnimState:PlayAnimation("wake"..math.random(1,3))
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    inst:AddTag("fx")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:ListenForEvent("animover", inst.Remove)

    return inst
end

return Prefab("wake_small", fn, assets)