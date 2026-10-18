--============================================================
-- 文件：prefabs/moonglass_stalactites.lua
-- 模块：预制体 / moonglass_stalactites（建筑与容器）
-- 职责：实体「moonglass_stalactites」的预制体定义。SpawnPrefab("moonglass_stalactites") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/moonglass_bigwaterfall.zip"),
}

local function stalactite(num)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        inst.AnimState:SetBank("moonglass_bigwaterfall")
        inst.AnimState:SetBuild("moonglass_bigwaterfall")
        inst.AnimState:PlayAnimation("stalactite"..tostring(num), true)

        inst:AddTag("NOBLOCK")

        inst.entity:SetPristine()
        if not TheWorld.ismastersim then
            return inst
        end

        return inst
    end

    return Prefab("moonglass_stalactite"..tostring(num), fn, assets)
end

return stalactite(1),
        stalactite(2),
        stalactite(3)
