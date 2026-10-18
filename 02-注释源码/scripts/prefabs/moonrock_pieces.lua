--============================================================
-- 文件：prefabs/moonrock_pieces.lua
-- 模块：预制体 / moonrock_pieces（建筑与容器）
-- 职责：实体「moonrock_pieces」的预制体定义。SpawnPrefab("moonrock_pieces") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/moonrock_pieces.zip"),
}

local prefabs =
{
    "rock_break_fx",
}

local NUM_MOONROCK_PIECES = 8

local function setpiecetype(inst, piece)
    if inst.piece == nil or (piece ~= nil and inst.piece ~= piece) then
        inst.piece = piece or math.random(NUM_MOONROCK_PIECES)
        inst.AnimState:PlayAnimation("s"..inst.piece)
    end
end

local function onsave(inst, data)
    data.piece = inst.piece
end

local function onload(inst, data)
    setpiecetype(inst, data ~= nil and data.piece or nil)
end

local function onworkfinished(inst)
    SpawnPrefab("rock_break_fx").Transform:SetPosition(inst.Transform:GetWorldPosition())
    inst:Remove()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("moonrock_pieces")
    inst.AnimState:SetBuild("moonrock_pieces")

    inst.scrapbook_anim = "s1"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    MakeHauntableWork(inst)

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.MINE)
    inst.components.workable:SetWorkLeft(1)
    inst.components.workable:SetOnFinishCallback(onworkfinished)

    if not POPULATING then
        setpiecetype(inst)
    end

    --------SaveLoad
    inst.OnSave = onsave
    inst.OnLoad = onload

    return inst
end

return Prefab("moonrock_pieces", fn, assets, prefabs)
