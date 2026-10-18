--============================================================
-- 文件：prefabs/spear_lance.lua
-- 模块：预制体 / spear_lance（建筑与容器）
-- 职责：实体「spear_lance」的预制体定义。SpawnPrefab("spear_lance") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/spear_lance.zip"),
    Asset("ANIM", "anim/swap_spear_lance.zip"),
}

local prefabs =
{
    "reticuleaoesmall",
    "reticuleaoesmallping",
    "reticuleaoesmallhostiletarget",
    "weaponsparks",
    "weaponsparks_thrusting",
    "firehit",
    "superjump_fx",
}

local function ReticuleTargetFn()
    local player = ThePlayer
    local ground = TheWorld.Map
    local pos = Vector3()
    --Cast range is 8, leave room for error
    --2 is the aoe range
    for r = 5, 0, -.25 do
        pos.x, pos.y, pos.z = player.entity:LocalToWorldSpace(r, 0, 0)
        if ground:IsPassableAtPoint(pos:Get()) and not ground:IsGroundTargetBlocked(pos) then
            return pos
        end
    end
    return pos
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("spear_lance")
    inst.AnimState:SetBuild("spear_lance")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("sharp")
    inst:AddTag("pointy")
    inst:AddTag("superjump")

    --weapon (from weapon component) added to pristine state for optimization
    inst:AddTag("weapon")

    --aoeweapon_leap (from aoeweapon_leap component) added to pristine state for optimization
    inst:AddTag("aoeweapon_leap")

    --rechargeable (from rechargeable component) added to pristine state for optimization
    inst:AddTag("rechargeable")

    inst:AddComponent("aoetargeting")
	inst.components.aoetargeting:SetAllowRiding(false)
    inst.components.aoetargeting:SetRange(16)
    inst.components.aoetargeting.reticule.reticuleprefab = "reticuleaoesmall"
    inst.components.aoetargeting.reticule.pingprefab = "reticuleaoesmallping"
    inst.components.aoetargeting.reticule.targetfn = ReticuleTargetFn
    inst.components.aoetargeting.reticule.validcolour = { 1, .75, 0, 1 }
    inst.components.aoetargeting.reticule.invalidcolour = { .5, 0, 0, 1 }
    inst.components.aoetargeting.reticule.ease = true
    inst.components.aoetargeting.reticule.mouseenabled = true

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("lavaarena", "prefabs/spear_lance").master_postinit(inst)

    return inst
end

return Prefab("spear_lance", fn, assets, prefabs)
