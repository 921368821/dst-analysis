--============================================================
-- 文件：prefabs/quagmire_salts.lua
-- 模块：预制体 / quagmire_salts（建筑与容器）
-- 职责：实体「quagmire_salts」的预制体定义。SpawnPrefab("quagmire_salts") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_saltrock.zip"),
    Asset("ANIM", "anim/quagmire_salt.zip"),
}

local function rock_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_saltrock")
    inst.AnimState:SetBuild("quagmire_saltrock")
    inst.AnimState:PlayAnimation("idle")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_salts").master_postinit_rock(inst)

    return inst
end

local function ground_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_salt")
    inst.AnimState:SetBuild("quagmire_salt")
    inst.AnimState:PlayAnimation("idle")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_salts").master_postinit_ground(inst)

    return inst
end

return Prefab("quagmire_saltrock", rock_fn, assets),
    Prefab("quagmire_salt", ground_fn, assets)
