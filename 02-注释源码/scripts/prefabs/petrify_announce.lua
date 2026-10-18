--============================================================
-- 文件：prefabs/petrify_announce.lua
-- 模块：预制体 / petrify_announce（建筑与容器）
-- 职责：实体「petrify_announce」的预制体定义。SpawnPrefab("petrify_announce") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function PlayPetrifySound(proxy)
    local inst = CreateEntity()

    --[[Non-networked entity]]

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()

    if TheFocalPoint ~= nil then
        local x, y, z = TheFocalPoint.Transform:GetWorldPosition()
        local x1, y1, z1 = proxy.Transform:GetWorldPosition()
        local dx, dz = x1 - x, z1 - z
        local dist = math.sqrt(dx * dx + dz * dz)
        local maxdist = 20
        if dist > maxdist then
            --too far to be heard, normalize to max distance
            dx = dx * maxdist / dist
            dz = dz * maxdist / dist
            x1 = x + dx
            z1 = z + dz
        end
        inst.Transform:SetPosition(x1, 0, z1)
    else
        inst.Transform:SetFromProxy(proxy.GUID)
    end

    inst.SoundEmitter:PlaySound("dontstarve/common/together/petrified/post_distant")
    inst:Remove()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    --Dedicated server does not need to spawn the local fx
    if not TheNet:IsDedicated() then
        --Delay one frame so that we are positioned properly before starting the effect
        --or in case we are about to be removed
        inst:DoTaskInTime(0, PlayPetrifySound)
    end

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.entity:SetCanSleep(false)
    inst.persists = false
    inst:DoTaskInTime(1, inst.Remove)

    return inst
end

return Prefab("petrify_announce", fn)
