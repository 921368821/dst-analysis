--============================================================
-- 文件：prefabs/blinkfocus_marker.lua
-- 模块：预制体 / blinkfocus_marker（建筑与容器）
-- 职责：实体「blinkfocus_marker」的预制体定义。SpawnPrefab("blinkfocus_marker") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function MakeTemporary(inst, duration)
    inst.persists = false
    if inst._blinkfocus_task ~= nil then
        inst._blinkfocus_task:Cancel()
        inst._blinkfocus_task = nil
    end
    inst._blinkfocus_task = inst:DoTaskInTime(duration, inst.Remove)
end

local function SetMaxRange(inst, range)
    inst.maxrange:set(range)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState() -- NOTES(JBK): This is here in case we want to use this focus with art later and do it only if the player has a controller plugged in!
    inst.entity:AddNetwork()

    inst.maxrange = net_float(inst.GUID, "blinkfocus_marker.maxrange")
    inst:AddTag("blinkfocus")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.MakeTemporary = MakeTemporary
    inst.SetMaxRange = SetMaxRange

    return inst
end

return Prefab("blinkfocus_marker", fn)