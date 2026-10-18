--============================================================
-- 文件：prefabs/gestalt_head.lua
-- 模块：预制体 / gestalt_head（建筑与容器）
-- 职责：实体「gestalt_head」的预制体定义。SpawnPrefab("gestalt_head") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/brightmare_gestalt_head.zip"),
}

local assets_guard =
{
    Asset("ANIM", "anim/brightmare_gestalt_head_evolved.zip"),
}

local function fn(bank)
    local inst = CreateEntity()

    inst:AddTag("FX")
    --[[Non-networked entity]]
    --Should be following parent's sleep state
    --inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddFollower()

    inst.AnimState:SetBank(bank)
    inst.AnimState:SetBuild(bank)
    inst.AnimState:PlayAnimation("idle", true)

    inst.Transform:SetFourFaced()

    return inst
end

return Prefab("gestalt_head", function() return fn("brightmare_gestalt_head") end, assets),
		Prefab("gestalt_guard_head", function() return fn("brightmare_gestalt_head_evolved") end, assets_guard)

