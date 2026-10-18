--============================================================
-- 文件：prefabs/oceanvine_deco.lua
-- 模块：预制体 / oceanvine_deco（建筑与容器）
-- 职责：实体「oceanvine_deco」的预制体定义。SpawnPrefab("oceanvine_deco") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets=
{
	Asset("ANIM", "anim/waterforest_vines.zip"),
	-- Asset("ANIM", "anim/vine.zip"),
	-- Asset("SOUND", "sound/frog.fsb"),
}

local prefabs =
{

}

local function onsave(inst, data)
    data.animnum = inst.animnum
end

local function onload(inst, data)
    if data then
        inst.animnum = data.animnum
        inst.AnimState:PlayAnimation("idle_"..inst.animnum,true)
    end
end

local function commonfn(Sim)
	local inst = CreateEntity()
	local trans = inst.entity:AddTransform()
	inst.entity:AddAnimState()
    inst.entity:AddNetwork()
	
	--inst.shadow = inst.entity:AddDynamicShadow()

	--inst.shadow:SetSize( 1.5, .75 )
    
	inst.AnimState:SetBank("vine_rainforest_border")
    inst.AnimState:SetBuild("waterforest_vines")
    inst.animnum = math.random(1,6)
	inst.AnimState:PlayAnimation("idle_"..inst.animnum,true)

    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")
    inst:AddTag("flying")

    if not TheNet:IsDedicated() then
    	inst:AddComponent("distancefade")
    	inst.components.distancefade:Setup(15,25)
    end

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.OnSave = onsave
    inst.OnLoad = onload
	
	return inst
end

return Prefab("oceanvine_deco", commonfn, assets, prefabs)
