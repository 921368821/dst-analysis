--============================================================
-- 文件：prefabs/burnable_locator_medium.lua
-- 模块：预制体 / burnable_locator_medium（建筑与容器）
-- 职责：实体「burnable_locator_medium」的预制体定义。SpawnPrefab("burnable_locator_medium") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function applytickdamage(inst)
	if inst.boat.components.health ~= nil then
		local damage = inst.boat ~= nil and inst.boat._fire_damage or TUNING.BOAT.FIRE_DAMAGE

		inst.boat.components.health:DoFireDamage(damage, nil, true)
	end
end

local function onsmoldering(inst)
	inst:RemoveTag("NOCLICK")
end

local function onignite(inst)
	if inst.boat ~= nil then
		inst.boat.activefires = inst.boat.activefires + 1
		inst.task = inst:DoPeriodicTask(1, applytickdamage)
	end

	inst:RemoveTag("NOCLICK")
end

local function onstopsmoldering(inst)
	inst:AddTag("NOCLICK")
end

local function onextinguish(inst)
	if inst.boat ~= nil then
		inst.boat.activefires = inst.boat.activefires - 1
	end
	inst:AddTag("NOCLICK")

	if inst.task ~= nil then
		inst.task:Cancel()
		inst.task = nil
	end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")
    inst:AddTag("ignorewalkableplatforms") -- because it is a child of the boat

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    MakeLargeBurnable(inst)
	inst.components.burnable.extinguishimmediately = false
	inst.components.burnable:SetBurnTime(nil)
	inst.components.burnable:SetOnIgniteFn(onignite)
	inst.components.burnable:SetOnExtinguishFn(onextinguish)
	inst.components.burnable:SetOnSmolderingFn(onsmoldering)
	inst.components.burnable:SetOnStopSmolderingFn(onstopsmoldering)
	MakeLargePropagator(inst)

    return inst
end

return Prefab("burnable_locator_medium", fn)
