--============================================================
-- 文件：prefabs/charlie_heckler.lua
-- 模块：预制体 / charlie_heckler（建筑与容器）
-- 职责：实体「charlie_heckler」的预制体定义。SpawnPrefab("charlie_heckler") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/charlie_heckler2.zip"),
    Asset("ANIM", "anim/yoth_charlie_heckler2_build.zip"),
}

local prefabs =
{
    -- Year of the Clockwork Knight
    "playbill_the_princess_yoth",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()
    inst.entity:AddFollower()

    inst.Transform:SetSixFaced()

    inst.AnimState:SetBank("charlie_heckler2")
    inst.AnimState:SetBuild(IsSpecialEventActive(SPECIAL_EVENTS.YOTH) and "yoth_charlie_heckler2_build" or "charlie_heckler2")
    inst.AnimState:PlayAnimation("idle")

    inst:AddComponent("talker")
    inst.components.talker.fontsize = 30
    inst.components.talker.font = TALKINGFONT
    inst.components.talker.colour = Vector3(163/255, 212/255, 158/255)
    inst.components.talker.offset = Vector3(0, -80, 0)
    inst.components.talker:MakeChatter()

	inst:AddTag("NOCLICK") --starts in "idle" state with NOCLICK tag
    inst:AddTag("NOBLOCK")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stageactor")

    inst:AddComponent("inspectable")

    inst:AddComponent("named")

    inst:SetStateGraph("SGcharlie_heckler")

    inst.persists = false

    return inst
end

return Prefab("charlie_heckler", fn, assets, prefabs)