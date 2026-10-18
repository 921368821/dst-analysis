--============================================================
-- 文件：prefabs/pillar.lua
-- 模块：预制体 / pillar（建筑与容器）
-- 职责：实体「pillar」的预制体定义。SpawnPrefab("pillar") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function makeassetlist(name)
    return {
        Asset("ANIM", "anim/"..name..".zip")
    }
end

local function doshake(inst)
    inst.AnimState:PlayAnimation("hit")
    inst.AnimState:PushAnimation("idle")

    -- JIGGLE SOUND [AMANDA]
end

local function makefn(name, collide)
    return function()
    	local inst = CreateEntity()

    	inst.entity:AddTransform()
    	inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        if name == "pillar_ruins" then
           inst.entity:AddSoundEmitter()
           inst:AddTag("charge_barrier")
           inst:AddTag("quake_on_charge")           
        end

        if collide then
            MakeObstaclePhysics(inst, 2.35)
        else
            inst:AddTag("NOBLOCK")
        end

        inst.AnimState:SetBank(name)
        inst.AnimState:SetBuild(name)
        inst.AnimState:PlayAnimation("idle", true)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:ListenForEvent("shake", doshake)

        return inst
    end
end

local function pillar(name, collide)
    return Prefab(name, makefn(name, collide), makeassetlist(name))
end

return pillar("pillar_ruins", true),
       pillar("pillar_algae", true),
       pillar("pillar_cave", true),
       pillar("pillar_cave_flintless", true),
       pillar("pillar_cave_rock", true),
       pillar("pillar_stalactite")--,
       --pillar("pillar_cave_moon", true),
       --pillar("pillar_stalactite_moon"),
