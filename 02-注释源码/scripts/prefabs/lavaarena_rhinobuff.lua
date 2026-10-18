--============================================================
-- 文件：prefabs/lavaarena_rhinobuff.lua
-- 模块：预制体 / lavaarena_rhinobuff（建筑与容器）
-- 职责：实体「lavaarena_rhinobuff」的预制体定义。SpawnPrefab("lavaarena_rhinobuff") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/lavaarena_rhino_buff_effect.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("lavaarena_rhino_buff_effect")
    inst.AnimState:SetBuild("lavaarena_rhino_buff_effect")
    inst.AnimState:PlayAnimation("in")

    inst.Transform:SetSixFaced()

    inst:AddTag("DECOR") --"FX" will catch mouseover
    inst:AddTag("NOCLICK")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("lavaarena", "prefabs/lavaarena_rhinobuff").master_postinit(inst)

    return inst
end

return Prefab("rhinobuff", fn, assets)
