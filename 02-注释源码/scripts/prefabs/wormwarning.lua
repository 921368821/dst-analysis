--============================================================
-- 文件：prefabs/wormwarning.lua
-- 模块：预制体 / wormwarning（建筑与容器）
-- 职责：实体「wormwarning」的预制体定义。SpawnPrefab("wormwarning") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SPAWN_DIST = 30 --hounded.lua::SPAWN_DIST

local WARNING_LEVEL_DISTANCE =
{
    SPAWN_DIST + 30,
    SPAWN_DIST + 20,
    SPAWN_DIST + 10,
    SPAWN_DIST,
}

local function PlayWarningSound(inst, radius, soundoveride)

    inst.entity:SetParent(TheFocalPoint.entity)

    --Everyone gets their own hounds and therefore their own warnings
    local theta = math.random() * TWOPI

    inst.Transform:SetPosition(radius * math.cos(theta), 0, radius * math.sin(theta))
    local sound = soundoveride or "dontstarve/creatures/worm/distant"
    inst.SoundEmitter:PlaySound(sound)
    inst:Remove()
end

local function makewarning(distance, soundoveride)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddSoundEmitter()

        inst:AddTag("FX")

        inst:DoTaskInTime(0, function()
            PlayWarningSound(inst, distance, soundoveride)
        end)

        inst.entity:SetCanSleep(false)
        inst.persists = false

        return inst
    end
end

local t = {}
for level, distance in ipairs(WARNING_LEVEL_DISTANCE) do
    table.insert(t, Prefab("wormwarning_lvl"..level, makewarning(distance)))
end

table.insert(t,Prefab("wormwarning_worm_boss", makewarning(SPAWN_DIST, "rifts4/worm_boss/distant")))

return unpack(t)
        