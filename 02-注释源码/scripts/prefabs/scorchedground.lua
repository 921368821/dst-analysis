--============================================================
-- 文件：prefabs/scorchedground.lua
-- 模块：预制体 / scorchedground（建筑与容器）
-- 职责：实体「scorchedground」的预制体定义。SpawnPrefab("scorchedground") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/scorched_ground.zip"),
}

local anim_names =
{
    "idle",
}

for i = 2, 10 do
    table.insert(anim_names, "idle"..tostring(i))
end

local function OnSave(inst, data)
    data.anim = inst.anim
    data.rotation = inst.Transform:GetRotation()
    --data.scale = { inst.Transform:GetScale() }
end

local function OnLoad(inst, data)
    if data ~= nil then
        if data.anim ~= nil then
            inst.anim = data.anim
            inst.AnimState:PlayAnimation(inst.anim)
        end
        if data.rotation ~= nil then
            inst.Transform:SetRotation(data.rotation)
        end
        --if data.scale ~= nil then
        --    inst.Transform:SetScale(data.scale[1] or 1, data.scale[2] or 2, data.scale[3] or 3)
        --end
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBuild("scorched_ground")
    inst.AnimState:SetBank("scorched_ground")
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    inst:AddTag("NOCLICK")
    inst:AddTag("FX")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.anim = anim_names[math.random(#anim_names)]
    inst.AnimState:PlayAnimation(inst.anim)

    inst.Transform:SetRotation(math.random() * 360)

    --local scale = GetRandomMinMax(1, 1.33)
    --inst.Transform:SetScale(scale, scale, scale)

    inst.OnSave = OnSave
    inst.OnLoad = OnLoad

    return inst
end

return Prefab("scorchedground", fn, assets)
