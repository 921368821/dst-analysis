--============================================================
-- 文件：prefabs/wortox_portal_fx.lua
-- 模块：预制体 / wortox_portal_fx（建筑与容器）
-- 职责：实体「wortox_portal_fx」的预制体定义。SpawnPrefab("wortox_portal_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wortox_portal.zip"),
}

local function OnAnimOver(inst)
    inst:DoTaskInTime(2 * FRAMES, inst.Remove)
end

local function MakeFX(name, anim)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        inst.AnimState:SetBank("wilson")
        inst.AnimState:SetBuild("wortox_portal")
        inst.AnimState:PlayAnimation(anim)
        inst.AnimState:SetFinalOffset(3)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:ListenForEvent("animover", OnAnimOver)
        inst.persists = false

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeFX("wortox_portal_jumpin_fx", "wortox_portal_jumpin"),
    MakeFX("wortox_portal_jumpout_fx", "wortox_portal_jumpout")
