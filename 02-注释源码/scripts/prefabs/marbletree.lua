--============================================================
-- 文件：prefabs/marbletree.lua
-- 模块：预制体 / marbletree（建筑与容器）
-- 职责：实体「marbletree」的预制体定义。SpawnPrefab("marbletree") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local NUM_TREES = 4

local assets =
{
    Asset("ANIM", "anim/marble_trees.zip"),
}

local prefabs =
{
    "marble",
    "rock_break_fx",
}

SetSharedLootTable( 'marble_tree',
{
    {'marble', 1.0},
    {'marble', 0.5},
})

local function onsave(inst, data)
    data.anim = inst.animnumber
end

local function onload(inst, data)
    if data and data.anim then
        inst.animnumber = data.anim
        inst.AnimState:PlayAnimation("full_"..inst.animnumber)
    end
end

local function onworked(inst, worker, workleft)
    if workleft <= 0 then
        local pos = inst:GetPosition()
        SpawnPrefab("rock_break_fx").Transform:SetPosition(pos:Get())
        inst.components.lootdropper:DropLoot(pos)
        inst:Remove()
    else
        inst.AnimState:PlayAnimation(
            (workleft < TUNING.MARBLETREE_MINE / 3 and ("low_"..inst.animnumber)) or
            (workleft < TUNING.MARBLETREE_MINE * 2 / 3 and ("med_"..inst.animnumber)) or
            ("full_"..inst.animnumber)
        )
    end
end

local function makeMarbleTree(animnumber)
    local name = "marbletree"
    if animnumber > 0 then
        name = name.."_"..tostring(animnumber)
    end
    local prefabname = name

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddMiniMapEntity()
        inst.entity:AddNetwork()

        MakeObstaclePhysics(inst, 0.1)
		inst:SetDeploySmartRadius(DEPLOYSPACING_RADIUS[DEPLOYSPACING.DEFAULT] / 2) --seed/planted_tree deployspacing/2

        inst.MiniMapEntity:SetIcon("marbletree.png")
        inst.MiniMapEntity:SetPriority(-1)

        inst.AnimState:SetBank("marble_trees")
        inst.AnimState:SetBuild("marble_trees")
        if animnumber > 0 then
            inst.AnimState:PlayAnimation("full_"..animnumber)
        end
        inst.scrapbook_anim ="full_1"

        MakeSnowCoveredPristine(inst)

        inst:SetPrefabName("marbletree")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("lootdropper")
        inst.components.lootdropper:SetChanceLootTable('marble_tree')

        if animnumber > 0 then
            inst.animnumber = animnumber
        else
            inst.animnumber = math.random(1, NUM_TREES)
            inst.AnimState:PlayAnimation("full_"..inst.animnumber)
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("workable")
        inst.components.workable:SetWorkAction(ACTIONS.MINE)
        inst.components.workable:SetWorkLeft(TUNING.MARBLETREE_MINE)
        inst.components.workable:SetOnWorkCallback(onworked)

        MakeHauntableWork(inst)

        MakeSnowCovered(inst)

        inst.OnSave = onsave
        inst.OnLoad = onload

        return inst
    end
    return Prefab(prefabname, fn, assets, prefabs)
end

local ret = {}
for k = 0, NUM_TREES do -- 0 is the "random" tree
    table.insert(ret, makeMarbleTree(k))
end

return unpack(ret)
