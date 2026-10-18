--============================================================
-- 文件：prefabs/abigail_attack_fx.lua
-- 模块：预制体 / abigail_attack_fx（建筑与容器）
-- 职责：实体「abigail_attack_fx」的预制体定义。SpawnPrefab("abigail_attack_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
   Asset("ANIM", "anim/abigail_attack_fx.zip"),
   Asset("ANIM", "anim/abigail_attack_fx_shadow_build.zip"),
}

local function normal_kill_fx(inst, attack_level)
    inst.AnimState:PlayAnimation("attack" .. tostring(attack_level) .. "_pst")
    inst:DoTaskInTime(FRAMES * 15, function() inst:Remove() end)
end

local function ground_kill_fx(inst, attack_level)
    inst.AnimState:PlayAnimation("attack" .. tostring(attack_level) .. "_ground_pst")
    inst:DoTaskInTime(FRAMES * 12, function() inst:Remove() end)
end

local function ground_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddLight()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("abigail_attack_fx")
    inst.AnimState:SetBuild("abigail_attack_fx")

    inst.AnimState:SetOrientation( ANIM_ORIENTATION.OnGround )
    inst.AnimState:SetLayer( LAYER_BACKGROUND )
    inst.AnimState:SetSortOrder( 3 )

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    inst.kill_fx = ground_kill_fx

    return inst
end

local function normal_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddLight()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("abigail_attack_fx")
    inst.AnimState:SetBuild("abigail_attack_fx")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    inst.kill_fx = normal_kill_fx

    return inst
end

return Prefab("abigail_attack_fx", normal_fn, assets),
       Prefab("abigail_attack_fx_ground", ground_fn, assets)