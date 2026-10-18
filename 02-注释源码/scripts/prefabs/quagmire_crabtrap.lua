--============================================================
-- 文件：prefabs/quagmire_crabtrap.lua
-- 模块：预制体 / quagmire_crabtrap（建筑与容器）
-- 职责：实体「quagmire_crabtrap」的预制体定义。SpawnPrefab("quagmire_crabtrap") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_crab_trap.zip"),
    Asset("SCRIPT", "scripts/prefabs/wortox_soul_common.lua"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.MiniMapEntity:SetIcon("birdtrap.png")

    inst.AnimState:SetBank("quagmire_crab_trap")
    inst.AnimState:SetBuild("quagmire_crab_trap")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("trap")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_crabtrap").master_postinit(inst)

    return inst
end

return Prefab("quagmire_crabtrap", fn, assets)
