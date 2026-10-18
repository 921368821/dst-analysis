--============================================================
-- 文件：prefabs/ice_crack_grid_fx.lua
-- 模块：预制体 / ice_crack_grid_fx（建筑与容器）
-- 职责：实体「ice_crack_grid_fx」的预制体定义。SpawnPrefab("ice_crack_grid_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/gridicecrack.zip"),
}

local prefabs =
{

}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBuild("gridicecrack")
    inst.AnimState:SetBank("gridplacer")
    inst.AnimState:PlayAnimation(math.random() < 0.5 and "left" or "right")
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)    

    inst:AddTag("NOCLICK")
    inst:AddTag("NOBLOCK")
    inst:AddTag("FX")
    inst:AddTag("ice_crack_fx")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    return inst
end

return Prefab( "ice_crack_grid_fx", fn, assets, prefabs )