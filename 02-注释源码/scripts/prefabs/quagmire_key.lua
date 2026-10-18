--============================================================
-- 文件：prefabs/quagmire_key.lua
-- 模块：预制体 / quagmire_key（建筑与容器）
-- 职责：实体「quagmire_key」的预制体定义。SpawnPrefab("quagmire_key") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_key.zip"),
}

local function MakeKey(name, anim)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("quagmire_key")
        inst.AnimState:SetBuild("quagmire_key")
        inst.AnimState:PlayAnimation(anim)

        inst:AddTag("irreplaceable")

        --klaussackkey (from klaussackkey component) added to pristine state for optimization
        inst:AddTag("klaussackkey")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        event_server_data("quagmire", "prefabs/quagmire_key").master_postinit(inst, anim)

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeKey("quagmire_key", "safe_key"),
    MakeKey("quagmire_key_park", "park_key")
