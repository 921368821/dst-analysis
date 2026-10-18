--============================================================
-- 文件：prefabs/yotc_carrat_rug.lua
-- 模块：预制体 / yotc_carrat_rug（建筑与容器）
-- 职责：实体「yotc_carrat_rug」的预制体定义。SpawnPrefab("yotc_carrat_rug") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/yotc_carrat_rug.zip"),
}

local function onbuilt(inst)
	inst.AnimState:PlayAnimation("place")
	inst.AnimState:PushAnimation("idle")
end

local function onburntup(inst)
	inst.AnimState:PlayAnimation("burnt")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("carrat_rug")
    inst.AnimState:SetBuild("yotc_carrat_rug")
    inst.AnimState:PlayAnimation("idle")

    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    inst.AnimState:SetSortOrder(1)

	inst:AddTag("DECOR")
	inst:AddTag("NOCLICK")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst:ListenForEvent("onbuilt", onbuilt)
	inst:ListenForEvent("onburntup", onburntup)

    return inst
end

return Prefab("yotc_carrat_rug", fn, assets)