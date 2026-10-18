--============================================================
-- 文件：prefabs/lavaarena_network.lua
-- 模块：预制体 / lavaarena_network（建筑与容器）
-- 职责：实体「lavaarena_network」的预制体定义。SpawnPrefab("lavaarena_network") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function PostInit(inst)
    inst:LongUpdate(0)
    inst.entity:FlushLocalDirtyNetVars()

    for k, v in pairs(inst.components) do
        if v.OnPostInit ~= nil then
            v:OnPostInit()
        end
    end
end

local function OnRemoveEntity(inst)
    if TheWorld ~= nil then
        assert(TheWorld.net == inst)
        TheWorld.net = nil
    end
end

local function DoPostInit(inst)
    if not TheWorld.ismastersim then
        if TheWorld.isdeactivated then
            --wow what bad timing!
            return
        end
        --master sim would have already done a proper PostInit in loading
        TheWorld:PostInit()
    end
    if not TheNet:IsDedicated() then
        if ThePlayer == nil then
            TheNet:SendResumeRequestToServer(TheNet:GetUserID())
        end
        PlayerHistory:StartListening()
    end
end

--------------------------------------------------------------------------

local function fn()
    local inst = CreateEntity()

    assert(TheWorld ~= nil and TheWorld.net == nil)
    TheWorld.net = inst

    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddNetwork()
    inst:AddTag("CLASSIFIED")

    inst.entity:SetPristine()

    inst:AddComponent("autosaver")
    inst:AddComponent("worldcharacterselectlobby")
    inst:AddComponent("lavaarenaeventstate")
    inst:AddComponent("lavaarenamusic")

    inst.PostInit = PostInit
    inst.OnRemoveEntity = OnRemoveEntity

    inst:DoStaticTaskInTime(0, DoPostInit)

    return inst
end

return Prefab("lavaarena_network", fn)
