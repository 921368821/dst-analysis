--============================================================
-- 文件：prefabs/archive_pillar.lua
-- 模块：预制体 / archive_pillar（建筑与容器）
-- 职责：实体「archive_pillar」的预制体定义。SpawnPrefab("archive_pillar") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pillar_archive.zip"),
    Asset("ANIM", "anim/pillar_archive_broken.zip"),
    Asset("MINIMAP_IMAGE", "pillar_archive"),
}

local function OnPoweredFn(inst, ispowered)
    inst.AnimState:PlayAnimation(ispowered and "idle_active" or "idle", ispowered)
end

local function choosebroken(inst, broken)
    local state = "full"
    if broken ~= nil then
        if broken == true then
            state = "broken"
        end
    else
        state = math.random() < 0.2 and "broken"
    end

    if state == "broken" then
        inst.broken = true
        inst.AnimState:SetBank("pillar_archive_broken")
        inst.AnimState:SetBuild("pillar_archive_broken")
    else
        inst.broken = false
    end
end

local function OnSave(inst, data)
    data.broken = inst.broken
end

local function OnLoad(inst, data)
    if data ~= nil and data.broken ~= nil then
        inst.broken = data.broken
        choosebroken(inst, inst.broken)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()
    inst.entity:AddMiniMapEntity()

    MakeObstaclePhysics(inst, 2.5)
    inst.Physics:SetCylinder(1.8, 6)

    inst.MiniMapEntity:SetIcon("pillar_archive.png")

    inst.AnimState:SetBank("pillar_archive")
    inst.AnimState:SetBuild("pillar_archive")
    inst.AnimState:PlayAnimation("idle", true)

    inst:AddTag("archive_pillar")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    choosebroken(inst)

    inst.OnSave = OnSave
    inst.OnLoad = OnLoad
   -- inst:ListenForEvent("atriumpowered", function(_, ispowered) OnPoweredFn(inst, ispowered) end, TheWorld)

    return inst
end

return Prefab("archive_pillar", fn, assets)
