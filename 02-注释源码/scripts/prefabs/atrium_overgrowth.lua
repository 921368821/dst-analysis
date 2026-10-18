--============================================================
-- 文件：prefabs/atrium_overgrowth.lua
-- 模块：预制体 / atrium_overgrowth（建筑与容器）
-- 职责：实体「atrium_overgrowth」的预制体定义。SpawnPrefab("atrium_overgrowth") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/atrium_overgrowth.zip"),
}

local nightmare_assets =
{
    Asset("ANIM", "anim/atrium_overgrowth.zip"),
}

local _storyprogress = 0
local NUM_STORY_LINES = 5

local function rune_AdvanceStory(inst)
	if inst.storyprogress == nil then
		_storyprogress = (_storyprogress % NUM_STORY_LINES) + 1
		inst.storyprogress = _storyprogress
	end
end

local function rune_getstatus(inst)
	rune_AdvanceStory(inst)
    return nil
end

local function rune_getdescription(inst, viewer)
	if viewer.components.inventory and viewer.components.inventory:EquipHasTag("ancient_reader") then
		rune_AdvanceStory(inst)
		return STRINGS.ATRIUM_OVERGROWTH["LINE_"..tostring(inst.storyprogress)]
	end
end

local function rune_onsave(inst, data)
    data.storyprogress = inst.storyprogress
end

local function rune_onload(inst, data)
	if data then
		if data.storyprogress then
			inst.storyprogress = data.storyprogress
			_storyprogress = math.max(_storyprogress, inst.storyprogress)
		end
	end
end

local function fn(bank)
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

	inst:AddTag("ancient_text")

    inst.AnimState:SetBuild(bank)
    inst.AnimState:SetBank(bank)
    inst.AnimState:PlayAnimation("idle")

    inst.MiniMapEntity:SetIcon(bank..".png")

    MakeObstaclePhysics(inst, 1.5)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("sanityaura")
    inst.components.sanityaura.aura = -TUNING.SANITYAURA_SUPERHUGE

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = rune_getstatus
    inst.components.inspectable.descriptionfn = rune_getdescription
    MakeRoseTarget_CreateFuel_IncreasedHorror(inst)

    inst.OnSave = rune_onsave
    inst.OnLoad = rune_onload

    return inst
end

local function idolfn()
    local inst = fn("atrium_overgrowth")

    inst:SetPrefabName("atrium_overgrowth")

    if not TheWorld.ismastersim then
        return inst
    end

    return inst
end

return Prefab("atrium_overgrowth", function() return fn("atrium_overgrowth") end, assets, prefabs),
    Prefab("atrium_idol", idolfn, assets, prefabs) -- deprecated
