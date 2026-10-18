--============================================================
-- 文件：prefabs/slingshotmodscontainer.lua
-- 模块：预制体 / slingshotmodscontainer（建筑与容器）
-- 职责：实体「slingshotmodscontainer」的预制体定义。SpawnPrefab("slingshotmodscontainer") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/ui_slingshotmods.zip"),
}

local function PostUpdate(inst)
	TheFocalPoint.SoundEmitter:PlaySound("meta5/walter/slingshot_UI_modify")

	inst.components.updatelooper:RemovePostUpdateFn(PostUpdate)
	inst._sfxqueued = nil
end

local function OnItemChanged(inst)
	if inst._sfxqueued == nil then
		local container = inst.replica.container
		--works fine for nil ThePlayer 
		--busy check to ignore the events when server data arrives on
		--clients since container prediction already played the sound
		if container:IsOpenedBy(ThePlayer) and not container:IsBusy() then
			inst._sfxqueued = true
			inst.components.updatelooper:AddPostUpdateFn(PostUpdate)
		end
	end
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddNetwork()

	inst:AddTag("CLASSIFIED")

	if not TheNet:IsDedicated() then
		inst:ListenForEvent("itemget", OnItemChanged)
		inst:ListenForEvent("itemlose", OnItemChanged)
		inst:AddComponent("updatelooper")
	end

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("container")
	inst.components.container:WidgetSetup("slingshotmodscontainer")
	inst.components.container.skipautoclose = true

	inst.install_target = nil

	return inst
end

return Prefab("slingshotmodscontainer", fn, assets)
