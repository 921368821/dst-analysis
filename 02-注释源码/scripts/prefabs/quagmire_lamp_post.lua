--============================================================
-- 文件：prefabs/quagmire_lamp_post.lua
-- 模块：预制体 / quagmire_lamp_post（建筑与容器）
-- 职责：实体「quagmire_lamp_post」的预制体定义。SpawnPrefab("quagmire_lamp_post") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function LightFn(bank_build, radius, falloff, intensity, color)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddLight()
        inst.entity:AddNetwork()

        MakeObstaclePhysics(inst, .5)

        inst.AnimState:SetBank(bank_build)
        inst.AnimState:SetBuild(bank_build)
        inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
        inst.AnimState:PlayAnimation("idle")

        inst.Light:Enable(true)
        inst.Light:SetRadius(radius)
        inst.Light:SetFalloff(falloff)
        inst.Light:SetIntensity(intensity)
        inst.Light:SetColour(color / 255, color / 255, color / 255)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")

        return inst
    end
end

return Prefab("quagmire_lamp_post", LightFn("quagmire_lamp_post", 3.5, 0.58, 0.75, 235), { Asset("ANIM", "anim/quagmire_lamp_post.zip") }),
    Prefab("quagmire_lamp_short", LightFn("quagmire_lamp_short", 2, 0.58, 0.75, 200), { Asset("ANIM", "anim/quagmire_lamp_short.zip") })
