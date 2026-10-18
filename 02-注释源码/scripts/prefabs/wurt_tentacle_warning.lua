--============================================================
-- 文件：prefabs/wurt_tentacle_warning.lua
-- 模块：预制体 / wurt_tentacle_warning（建筑与容器）
-- 职责：实体「wurt_tentacle_warning」的预制体定义。SpawnPrefab("wurt_tentacle_warning") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wurt_xray.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
	--[[Non-networked entity]]

    inst.AnimState:SetBank("wurt_xray")
    inst.AnimState:SetBuild("wurt_xray")
    inst.AnimState:PlayAnimation("idle_pre")
    inst.AnimState:PushAnimation("idle_loop", true)
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    inst:AddTag("DECOR")
    inst:AddTag("CLASSIFIED")
    inst:AddTag("NOCLICK")

    inst.entity:SetCanSleep(false)
    inst.persists = false

    return inst
end

return Prefab("wurt_tentacle_warning", fn, assets)
