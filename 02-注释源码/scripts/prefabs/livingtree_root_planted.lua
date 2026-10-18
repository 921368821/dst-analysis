--============================================================
-- 文件：prefabs/livingtree_root_planted.lua
-- 模块：预制体 / livingtree_root_planted（建筑与容器）
-- 职责：实体「livingtree_root_planted」的预制体定义。SpawnPrefab("livingtree_root_planted") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local assets =
{
    Asset("ANIM", "anim/livingtree_root.zip"),
}

local prefabs =
{
    "livingtree_halloween",
	"livingtree_root",
	"livinglog",
}

local function growtree(inst)
    local tree = SpawnPrefab("livingtree_halloween")
    if tree then
        tree.Transform:SetPosition(inst.Transform:GetWorldPosition())
        tree:growfromseed()
        inst:Remove()
    end
end

local function SetGrowth(inst, anim)
	inst.AnimState:PlayAnimation(anim, true)
end

local function DoGrow(inst)
    inst.AnimState:PlayAnimation("burst")
    inst.SoundEmitter:PlaySound("dontstarve/halloween_2018/living_tree/grow_1")
    inst.AnimState:PushAnimation("idle_planted", true)
end

local GROWTH_STAGES =
{
    {
        time = function(inst) return GetRandomWithVariance(TUNING.LIVINGTREE_YOUNG_GROW_TIME, TUNING.LIVINGTREE_YOUNG_GROW_TIME*0.05) end,
        fn = function(inst) SetGrowth(inst, "idle_planted_flask") end,
    },
    {
        time = function(inst) return GetRandomWithVariance(TUNING.LIVINGTREE_YOUNG_GROW_TIME, TUNING.LIVINGTREE_YOUNG_GROW_TIME*0.05) end,
        fn = function(inst) SetGrowth(inst, "idle_planted") inst.components.lootdropper:SetLoot({"livinglog"}) end,
        growfn = function(inst) DoGrow(inst) end,
    },
	{
        fn = function(inst) inst.components.growable:StopGrowing() SetGrowth(inst, "idle_planted") inst:DoTaskInTime(0, growtree) end,
	},
}


local function digup(inst, digger)
    inst.components.lootdropper:DropLoot()
    inst:Remove()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("plant")

    inst.AnimState:SetBank("livingtree_root")
    inst.AnimState:SetBuild("livingtree_root")

	inst:SetDeploySmartRadius(DEPLOYSPACING_RADIUS[DEPLOYSPACING.DEFAULT] / 2) --livingtree_root deployspacing/2

	inst.AnimState:PlayAnimation("idle_planted_flask", true)
	if not IsSpecialEventActive(SPECIAL_EVENTS.HALLOWED_NIGHTS) then
		inst.AnimState:Hide("eye")
	end

    inst.scrapbook_proxy = "livingtree"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("growable")
    inst.components.growable.stages = GROWTH_STAGES
	inst.components.growable.growoffscreen = true
    inst.components.growable:SetStage(1)
    inst.components.growable:StartGrowing()

    inst:AddComponent("inspectable")

    inst:AddComponent("lootdropper")
    inst.components.lootdropper:SetLoot({"livingtree_root"})

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.DIG)
    inst.components.workable:SetOnFinishCallback(digup)
    inst.components.workable:SetWorkLeft(1)

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableIgnite(inst)

    return inst
end

return Prefab("livingtree_sapling", fn, assets, prefabs)
