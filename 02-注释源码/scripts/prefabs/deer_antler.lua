--============================================================
-- 文件：prefabs/deer_antler.lua
-- 模块：预制体 / deer_antler（建筑与容器）
-- 职责：实体「deer_antler」的预制体定义。SpawnPrefab("deer_antler") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function MakeAntler(antlertype, trueklaussackkey)
    local assets = antlertype ~= nil and {
        Asset("ANIM", "anim/deer_antler.zip"),
    } or nil

    local prefabs = antlertype == nil and {
        "deer_antler1",
        "deer_antler2",
        "deer_antler3",
    } or nil

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("deer_antler")
        inst.AnimState:SetBuild("deer_antler")
        inst.AnimState:PlayAnimation("idle"..tostring(antlertype or 1))

        inst:AddTag("deerantler")

        --klaussackkey (from klaussackkey component) added to pristine state for optimization
        inst:AddTag("klaussackkey")

        if trueklaussackkey then
            inst:AddTag("irreplaceable")
        else
            if antlertype == nil then
                inst:SetPrefabName("deer_antler1")
            end
            inst:SetPrefabNameOverride("deer_antler")
        end

        MakeInventoryFloatable(inst, "med", nil, 0.88)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst.scrapbook_anim = "idle"..tostring(antlertype or 1)

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")

        inst:AddComponent("klaussackkey")
        inst.components.klaussackkey:SetTrueKey(trueklaussackkey)

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(trueklaussackkey and "klaussackkey" or "deer_antler"..tostring(antlertype or ""), fn, assets, prefabs)
end

return MakeAntler(),
        MakeAntler(1),
        MakeAntler(2),
        MakeAntler(3),
        MakeAntler(4, true)
