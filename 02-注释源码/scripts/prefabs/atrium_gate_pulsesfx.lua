--============================================================
-- 文件：prefabs/atrium_gate_pulsesfx.lua
-- 模块：预制体 / atrium_gate_pulsesfx（建筑与容器）
-- 职责：实体「atrium_gate_pulsesfx」的预制体定义。SpawnPrefab("atrium_gate_pulsesfx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local easing = require("easing")

local function PlayWarningSound(proxy, sound, playanywhere)
	local player = ThePlayer
	if playanywhere then
		--anywhere except vault =)
		if player and TheWorld.Map:IsPointInAnyVault(player.Transform:GetWorldPosition()) then
			return
		end
	elseif not (player and
				player.components.areaaware and
				player.components.areaaware:CurrentlyInTag("Nightmare"))
	then
		return
    end

    local inst = CreateEntity()

    --[[Non-networked entity]]

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:SetParent(TheFocalPoint.entity)

    local sfx_offset = TheFocalPoint:GetPosition() - proxy:GetPosition()
    local dist = sfx_offset:Length()

    local min = 0.4
    local radius = 30 * (1 - (((1-min)/(math.pow(dist/15, 2) + 1)) + min))

    inst.Transform:SetPosition(((sfx_offset / dist) * radius):Get())
    inst.SoundEmitter:PlaySound(sound)

    inst:Remove()
end

local function makesfx(sound, playanywhere)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddNetwork()

        inst:AddTag("FX")

        --Dedicated server does not need to spawn the local fx
        if not TheNet:IsDedicated() then
            inst:DoTaskInTime(0, PlayWarningSound, sound, playanywhere)
        end

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst.entity:SetCanSleep(false)
        inst.persists = false

        inst:DoTaskInTime(1, inst.Remove)

        return inst
    end
end

return Prefab("atrium_gate_pulsesfx", makesfx("dontstarve/common/together/atrium_gate/shadow_pulse")),
    Prefab("atrium_gate_explodesfx", makesfx("dontstarve/common/together/atrium_gate/explode")),
    Prefab("grotto_war_sfx", makesfx("grotto/common/archive_switch/shadow_war", true))
