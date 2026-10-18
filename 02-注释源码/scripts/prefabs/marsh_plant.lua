--============================================================
-- 文件：prefabs/marsh_plant.lua
-- 模块：预制体 / marsh_plant（建筑与容器）
-- 职责：实体「marsh_plant」的预制体定义。SpawnPrefab("marsh_plant") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/marsh_plant.zip"),
    Asset("ANIM", "anim/pond_plant_cave.zip"),
}

local function fn(bank, build)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation("idle", true)

        inst:AddTag("plant")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        MakeMediumBurnable(inst)
        MakeSmallPropagator(inst)
        MakeHauntableIgnite(inst)

        inst:AddComponent("inspectable")

        return inst
    end
end

return Prefab("marsh_plant", fn("marsh_plant", "marsh_plant"), assets),
    Prefab("pond_algae", fn("pond_rock", "pond_plant_cave"), assets)