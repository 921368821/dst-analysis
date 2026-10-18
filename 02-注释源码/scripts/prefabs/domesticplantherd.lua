--============================================================
-- 文件：prefabs/domesticplantherd.lua
-- 模块：预制体 / domesticplantherd（建筑与容器）
-- 职责：实体「domesticplantherd」的预制体定义。SpawnPrefab("domesticplantherd") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local prefabs =
{

}

local function OnInit(inst)
    inst.components.mood:ValidateMood()
end

local function RegisterWithWorld(inst)    
    TheWorld:PushEvent("plantherdspawned",inst)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("herd")
    --V2C: Don't use CLASSIFIED because herds use FindEntities on "herd" tag
    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")

    inst:AddComponent("herd")

    inst.components.herd:SetGatherRange(TUNING.DOMESTICPLANTHERD_RANGE)
    inst.components.herd:SetUpdateRange(20)
    inst.components.herd:SetOnEmptyFn(inst.Remove)
    inst.components.herd:SetMemberTag("lunarplant_target")
    inst.components.herd:SetMaxSize(36)

    inst:DoTaskInTime(0,RegisterWithWorld)

    return inst
end

return Prefab("domesticplantherd", fn, nil, prefabs)
