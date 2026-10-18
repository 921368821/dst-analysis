--============================================================
-- 文件：prefabs/warningshadow.lua
-- 模块：预制体 / warningshadow（建筑与容器）
-- 职责：实体「warningshadow」的预制体定义。SpawnPrefab("warningshadow") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/warning_shadow.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("warning_shadow")
    inst.AnimState:SetBuild("warning_shadow")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetFinalOffset(3)

    inst:AddTag("FX")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    return inst
end

return Prefab("warningshadow", fn, assets)