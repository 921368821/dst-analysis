--============================================================
-- 文件：prefabs/pocketdimensioncontainers.lua
-- 模块：预制体 / pocketdimensioncontainers（建筑与容器）
-- 职责：实体「pocketdimensioncontainers」的预制体定义。SpawnPrefab("pocketdimensioncontainers") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local POCKETDIMENSIONCONTAINER_DEFS = require("prefabs/pocketdimensioncontainer_defs").POCKETDIMENSIONCONTAINER_DEFS

local function OnAnyOpenStorage(inst, data)
	if inst.components.container.opencount > 1 then
		--multiple users, make it global to all players now
		inst.Network:SetClassifiedTarget(nil)
	else
		--just one user, only network to that player
		inst.Network:SetClassifiedTarget(data.doer)
	end
end

local function OnAnyCloseStorage(inst, data)
	local opencount = inst.components.container.opencount
	if opencount == 0 then
		--all closed, disable networking
		inst.Network:SetClassifiedTarget(inst)
	elseif opencount == 1 then
		--only one user remaining, only network to that player
		local opener = next(inst.components.container.openlist)
		inst.Network:SetClassifiedTarget(opener)
	end
end

local function MakeContainer(def)
	local assets = {
		Asset("ANIM", def.ui),
		Asset("SCRIPT", "scripts/prefabs/pocketdimensioncontainer_defs.lua"),
	}

	local function fn()
		local inst = CreateEntity()
	
		if TheWorld.ismastersim then
			inst.entity:AddTransform() --So we can save
		end
		inst.entity:AddNetwork()
		inst.entity:AddServerNonSleepable()
		inst.entity:SetCanSleep(false)
		inst.entity:Hide()
		inst:AddTag("CLASSIFIED")
		inst:AddTag("pocketdimension_container")
		inst:AddTag("irreplaceable")

		if def.tags ~= nil then
			for i, v in ipairs(def.tags) do
				inst:AddTag(v)
			end
		end

		inst.entity:SetPristine()
	
		if not TheWorld.ismastersim then
			return inst
		end
	
		inst.Network:SetClassifiedTarget(inst)
	
		inst:AddComponent("container")
		inst.components.container:WidgetSetup(def.widgetname)
		inst.components.container.skipclosesnd = true
		inst.components.container.skipopensnd = true
		inst.components.container.skipautoclose = true
		inst.components.container.onanyopenfn = OnAnyOpenStorage
		inst.components.container.onanyclosefn = OnAnyCloseStorage

		TheWorld:SetPocketDimensionContainer(def.name, inst)
	
		return inst
	end
	
	return Prefab(def.prefab, fn, assets)
end


local container_prefabs = {}
for _, v in ipairs(POCKETDIMENSIONCONTAINER_DEFS) do
	if not v.data_only then -- Allow mods to skip our prefab constructor.
		table.insert(container_prefabs, MakeContainer(v))
	end
end

return unpack(container_prefabs)