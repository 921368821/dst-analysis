--============================================================
-- 文件：prefabs/ice_puddle.lua
-- 模块：预制体 / ice_puddle（建筑与容器）
-- 职责：实体「ice_puddle」的预制体定义。SpawnPrefab("ice_puddle") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/ice_puddle.zip"),
}

local function fn()
    local inst = CreateEntity()

    --Use FX, not DECOR, otherwise won't inspect properly when parented
    inst:AddTag("FX")
    --[[Non-networked entity]]
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBank("ice_puddle")
    inst.AnimState:SetBuild("ice_puddle")
    inst.AnimState:PlayAnimation("full")
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    return inst
end

return Prefab("ice_puddle", fn, assets)
