--============================================================
-- 文件：prefabs/moon_altar_break.lua
-- 模块：预制体 / moon_altar_break（建筑与容器）
-- 职责：实体「moon_altar_break」的预制体定义。SpawnPrefab("moon_altar_break") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function make_break_fx(name)
    local break_prefab_name = name.."_break"

    local assets =
    {
        Asset("ANIM", "anim/"..name..".zip"),
        Asset("ANIM", "anim/"..break_prefab_name..".zip"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddNetwork()

        inst.AnimState:SetBank(break_prefab_name)
        inst.AnimState:SetBuild(break_prefab_name)
        inst.AnimState:AddOverrideBuild(name)
        inst.AnimState:PlayAnimation("break")

        inst:AddTag("FX")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:ListenForEvent("animover", inst.Remove)

        return inst
    end

    return Prefab(break_prefab_name, fn, assets)
end

-- moon_altar_break, moon_altar_claw_break, moon_altar_crown_break
return make_break_fx("moon_altar"),
    make_break_fx("moon_altar_claw"),
    make_break_fx("moon_altar_crown")
