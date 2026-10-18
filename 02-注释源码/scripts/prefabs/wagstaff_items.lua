--============================================================
-- 文件：prefabs/wagstaff_items.lua
-- 模块：预制体 / wagstaff_items（建筑与容器）
-- 职责：实体「wagstaff_items」的预制体定义。SpawnPrefab("wagstaff_items") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wagstaff_personal_items.zip"),
}

local function CloneAsFx(inst)
	local fx = SpawnPrefab("hermithouse_ornament_fx")
	fx.AnimState:SetBank("wagstaff_personal_items")
	fx.AnimState:SetBuild("wagstaff_personal_items")
	return fx
end

local function MakeItem(info)
	local prefabs = info.isornament and
	{
		"hermithouse_ornament_fx",
	} or nil

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("wagstaff_personal_items")
        inst.AnimState:SetBuild("wagstaff_personal_items")
        inst.AnimState:PlayAnimation(info.anim)

        MakeInventoryFloatable(inst)

		if info.isornament then
			inst:AddTag("hermithouse_ornament")
		end
		inst:AddTag("wagstaff_item")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")

        MakeHauntableLaunch(inst)

		if info.isornament then
			inst.CloneAsFx = CloneAsFx
		end

        return inst
    end

    return Prefab(info.name, fn, assets, prefabs)
end

return MakeItem({ name = "wagstaff_item_1", anim = "glove1", isornament = true }),
	MakeItem({ name = "wagstaff_item_2", anim = "clipboard" })
