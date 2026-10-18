--============================================================
-- 文件：prefabs/quagmire_altar_statue.lua
-- 模块：预制体 / quagmire_altar_statue（建筑与容器）
-- 职责：实体「quagmire_altar_statue」的预制体定义。SpawnPrefab("quagmire_altar_statue") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function MakeStatue(name, build_bank, anim, save_rotation, physics_rad)
    local assets =
    {
        Asset("ANIM", "anim/"..build_bank..".zip"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        inst.AnimState:SetBank(build_bank)
        inst.AnimState:SetBuild(build_bank)
        inst.AnimState:PlayAnimation(anim or "idle")

        if physics_rad ~= 0 then
            MakeObstaclePhysics(inst, physics_rad or .5)
        end

        if save_rotation then
            inst.Transform:SetTwoFaced()
        end

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")

        if save_rotation then
            inst:AddComponent("savedrotation")
        end

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeStatue("quagmire_altar_statue1", "quagmire_altar_statue1", "idle", true),
    MakeStatue("quagmire_altar_statue2", "quagmire_altar_statue2", "idle", true),
    MakeStatue("quagmire_altar_queen", "quagmire_altar_queen", "idle", false, 1),
    MakeStatue("quagmire_altar_bollard", "quagmire_bollard", "idle", false, 0.25),
    MakeStatue("quagmire_altar_ivy", "quagmire_ivy_topiary", "idle", false, .33),
    MakeStatue("quagmire_park_fountain", "quagmire_birdbath", "idle", true),
    MakeStatue("quagmire_park_angel", "quagmire_cemetery", "angel", true),
    MakeStatue("quagmire_park_angel2", "quagmire_cemetery", "angel2", true),
    MakeStatue("quagmire_park_urn", "quagmire_cemetery", "urn", true),
    MakeStatue("quagmire_park_obelisk", "quagmire_cemetery", "obelisk", true),
    MakeStatue("quagmire_merm_cart1", "quagmire_mermcart", "idle1", false, 1.5),
    MakeStatue("quagmire_merm_cart2", "quagmire_mermcart", "idle2", false)
