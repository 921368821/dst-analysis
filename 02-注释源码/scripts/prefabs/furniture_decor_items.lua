--============================================================
-- 文件：prefabs/furniture_decor_items.lua
-- 模块：预制体 / furniture_decor_items（建筑与容器）
-- 职责：实体「furniture_decor_items」的预制体定义。SpawnPrefab("furniture_decor_items") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local EMPTY_TABLE = {}
local function MakeDecorItem(name, bank, build, data)
    data = data or EMPTY_TABLE

    local assets =
    {
        Asset("ANIM", "anim/"..bank..".zip"),
    }
    if build then
        if bank ~= build then
            table.insert(assets, Asset("ANIM", "anim/"..build..".zip"))
        end
    else
        build = bank
    end

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddFollower()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation("idle")

        inst:AddTag("furnituredecor") -- From "furnituredecor", for optimization

        local float = data.float
        if float then
            MakeInventoryFloatable(inst, float[1], float[2], float[3])
        end

        if data.common_postinit then
            data.common_postinit(inst)
        end

        inst.entity:SetPristine()
        if not TheWorld.ismastersim then
            return inst
        end

        --
        local furnituredecor = inst:AddComponent("furnituredecor")
        furnituredecor.onputonfurniture = data.put_on_furniture

        --
        inst:AddComponent("inspectable")

        --
        inst:AddComponent("inventoryitem")

        --
        MakeHauntable(inst)

        --
        local burnable = MakeSmallBurnable(inst)
        if data.onburnt then
            burnable:SetOnBurntFn(data.onburnt)
        end

        MakeSmallPropagator(inst)

        --
        inst.OnSave = data.onsave
        inst.OnLoad = data.onload

        --
        if data.master_postinit then
            data.master_postinit(inst)
        end

        return inst
    end

    return Prefab(name, fn, assets)
end

local decor_items = {}

local CENTERPIECE_DATA =
{
    float = {"med", 0.05, 0.68},
}
table.insert(decor_items, MakeDecorItem("decor_centerpiece", "decor_centerpiece", nil, CENTERPIECE_DATA))

local PORTRAITFRAME_DATA =
{
    float = {"med", 0.05, 0.64},
}
table.insert(decor_items, MakeDecorItem("decor_portraitframe", "decor_portraitframe", nil, PORTRAITFRAME_DATA))

--
return unpack(decor_items)