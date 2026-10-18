--============================================================
-- 文件：prefabs/winona_battery_sparks.lua
-- 模块：预制体 / winona_battery_sparks（建筑与容器）
-- 职责：实体「winona_battery_sparks」的预制体定义。SpawnPrefab("winona_battery_sparks") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/sparks.zip"),
}

--Not using proxy because this FX needs to be synced to other entities' anims
local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst:AddTag("FX")
    inst:AddTag("NOCLICK")

    inst.AnimState:SetBank("sparks")
    inst.AnimState:SetBuild("sparks")
    inst.AnimState:PlayAnimation("sparks_1")
    inst.AnimState:SetAddColour(1, 1, 0, 0)
	inst.AnimState:SetLightOverride(0.3)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    local rnd = math.random(3)
    if rnd > 1 then
        inst.AnimState:PlayAnimation("sparks_"..tostring(rnd))
    end

    inst:ListenForEvent("animover", inst.Remove)
    inst.persists = false

    return inst
end

return Prefab("winona_battery_sparks", fn, assets)
