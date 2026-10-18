--============================================================
-- 文件：prefabs/pig_coin.lua
-- 模块：预制体 / pig_coin（建筑与容器）
-- 职责：实体「pig_coin」的预制体定义。SpawnPrefab("pig_coin") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pig_coin.zip"),
}

local prefabs =
{
	"cointosscastfx",
	"cointosscastfx_mount",
	"pigelitefighter1",
	"pigelitefighter2",
	"pigelitefighter3",
	"pigelitefighter4",
}

local function shine(inst)
    if not inst.AnimState:IsCurrentAnimation("sparkle") then
        inst.AnimState:PlayAnimation("sparkle")
        inst.AnimState:PushAnimation("idle", false)
    end
    inst:DoTaskInTime(4 + math.random() * 5, shine)
end

local function spellfn(inst, target, pos, caster)
	if caster ~= nil then
		local pos = caster:GetPosition()

		local elite = SpawnPrefab("pigelitefighter"..math.random(4))
		elite.Transform:SetPosition(pos.x, (caster.components.rider ~= nil and caster.components.rider:IsRiding()) and 3 or 0, pos.z)
		elite.components.follower:SetLeader(caster)

		local theta = math.random() * PI2
		local offset = FindWalkableOffset(pos, theta, 2.5, 16, true, true, nil, false, true)
						or FindWalkableOffset(pos, theta, 2.5, 16, false, false, nil, false, true)
						or Vector3(0, 0, 0)

		pos.x, pos.y, pos.z = pos.x + offset.x, 0, pos.z + offset.z
		elite.sg:GoToState("spawnin", { dest = pos })
	end

    if inst.components.stackable ~= nil and inst.components.stackable:IsStack() then
        inst.components.stackable:Get():Remove()
    else
        inst:Remove()
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("pig_coin")
    inst.AnimState:SetBuild("pig_coin")
    inst.AnimState:PlayAnimation("idle")

	MakeInventoryFloatable(inst, "small")

	inst:AddTag("cointosscast") -- for coint toss casting

    inst.scrapbook_specialinfo = "PIGCOIN"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.fxcolour = {248/255, 248/255, 198/255}
    inst.castsound = "dontstarve/pig/mini_game/cointoss"

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("spellcaster")
    inst.components.spellcaster:SetSpellFn(spellfn)
    inst.components.spellcaster.canuseontargets = true
    inst.components.spellcaster.canusefrominventory = true
    inst.components.spellcaster.canonlyuseonlocomotorspvp = true

    inst:AddComponent("tradable")

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    MakeHauntableLaunch(inst)

    shine(inst)

    return inst
end

return Prefab("pig_coin", fn, assets, prefabs)
