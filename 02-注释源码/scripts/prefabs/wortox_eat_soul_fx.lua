--============================================================
-- 文件：prefabs/wortox_eat_soul_fx.lua
-- 模块：预制体 / wortox_eat_soul_fx（建筑与容器）
-- 职责：实体「wortox_eat_soul_fx」的预制体定义。SpawnPrefab("wortox_eat_soul_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wortox_eat_soul_fx.zip"),
}

local function MakeMounted(inst)
    inst.Transform:SetSixFaced()
    inst.AnimState:PlayAnimation("mounted_eat")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.Transform:SetFourFaced()

    inst.AnimState:SetBank("wortox_eat_soul_fx")
    inst.AnimState:SetBuild("wortox_eat_soul_fx")
    inst.AnimState:PlayAnimation("eat")
    inst.AnimState:SetFinalOffset(1)

    inst:AddTag("DECOR") --"FX" will catch mouseover
    inst:AddTag("NOCLICK")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:ListenForEvent("animover", inst.Remove)
    inst.persists = false
    inst.MakeMounted = MakeMounted

    return inst
end

return Prefab("wortox_eat_soul_fx", fn, assets)
