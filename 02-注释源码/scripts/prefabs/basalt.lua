--============================================================
-- 文件：prefabs/basalt.lua
-- 模块：预制体 / basalt（建筑与容器）
-- 职责：实体「basalt」的预制体定义。SpawnPrefab("basalt") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/blocker.zip"),
}

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data and data.anim then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)

    end
end

local function makebasalt(anims)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddMiniMapEntity()
        inst.entity:AddNetwork()

        MakeObstaclePhysics(inst, 1)

        inst.MiniMapEntity:SetIcon("basalt.png")

        inst.AnimState:SetBank("blocker")
        inst.AnimState:SetBuild("blocker")

        MakeSnowCoveredPristine(inst)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst.animname = anims[math.random(#anims)]
        inst.AnimState:PlayAnimation(inst.animname)
        inst.scrapbook_anim = inst.animname
        local color = 0.5 + math.random() * 0.5
        inst.AnimState:SetMultColour(color, color, color, 1)

        inst:AddComponent("inspectable")
        inst.components.inspectable.nameoverride = "BASALT"
        MakeSnowCovered(inst)
        SetLunarHailBuildupAmountLarge(inst)
        return inst
    end
end

return Prefab("basalt", makebasalt({"block1", "block4", "block2"}), assets),
       Prefab("basalt_pillar", makebasalt({"block3"}), assets)