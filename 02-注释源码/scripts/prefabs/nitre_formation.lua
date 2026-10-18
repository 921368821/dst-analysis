--============================================================
-- 文件：prefabs/nitre_formation.lua
-- 模块：预制体 / nitre_formation（建筑与容器）
-- 职责：实体「nitre_formation」的预制体定义。SpawnPrefab("nitre_formation") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pond_nitrecrystal.zip"),
}

local function OnRemoveEntity(inst)
	if inst.pond ~= nil and inst.pond.highlightchildren ~= nil then
		table.removearrayvalue(inst.pond.highlightchildren, inst)
		if #inst.pond.highlightchildren <= 0 then
			inst.pond.highlightchildren = nil
		end
	end
end

local function OnEntityReplicated(inst)
	local parent = inst.entity:GetParent()
	if parent ~= nil and parent.prefab == "pond_cave" then
		if parent.highlightchildren == nil then
			parent.highlightchildren = { inst }
		else
			table.insert(parent.highlightchildren, inst)
		end

		inst.pond = parent
		inst.OnRemoveEntity = OnRemoveEntity
	end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("pond_rock")
    inst.AnimState:SetBuild("pond_nitrecrystal")
    inst.AnimState:PlayAnimation("idle1")
    inst.AnimState:SetScale(0.75, 0.75)

	inst:AddTag("FX")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
		inst.OnEntityReplicated = OnEntityReplicated

        return inst
    end

    return inst
end

return Prefab("nitre_formation", fn, assets)
