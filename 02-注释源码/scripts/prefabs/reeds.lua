--============================================================
-- 文件：prefabs/reeds.lua
-- 模块：预制体 / reeds（自然与资源）
-- 职责：实体「reeds」的预制体定义。SpawnPrefab("reeds") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/grass.zip"),
    Asset("ANIM", "anim/reeds.zip"),
    Asset("SOUND", "sound/common.fsb"),

    Asset("MINIMAP_IMAGE", "reeds"),
}

local prefabs =
{
    "cutreeds",
}

local function onpickedfn(inst)
    inst.SoundEmitter:PlaySound("dontstarve/wilson/pickup_reeds")
    inst.AnimState:PlayAnimation("picking")
    inst.AnimState:PushAnimation("picked")
end

local function onregenfn(inst)
    inst.AnimState:PlayAnimation("grow")
    inst.AnimState:PushAnimation("idle", true)
end

local function makeemptyfn(inst)
    inst.AnimState:PlayAnimation("picked")
end

local function MakeReeds(name, build, icon)
    local function fn()
        local inst = CreateEntity()
    
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddMiniMapEntity()
        inst.entity:AddNetwork()

        inst.MiniMapEntity:SetIcon(icon)
    
        inst:AddTag("plant")
        inst:AddTag("silviculture") -- for silviculture book
    
        inst.AnimState:SetBank("grass")
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation("idle", true)
    
        inst.entity:SetPristine()
    
        if not TheWorld.ismastersim then
            return inst
        end
    
		inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)
        local color = 0.75 + math.random() * 0.25
        inst.AnimState:SetMultColour(color, color, color, 1)
    
        inst:AddComponent("pickable")
        inst.components.pickable.picksound = "dontstarve/wilson/pickup_reeds"
        inst.components.pickable:SetUp("cutreeds", TUNING.REEDS_REGROW_TIME)
        inst.components.pickable.onregenfn = onregenfn
        inst.components.pickable.onpickedfn = onpickedfn
        inst.components.pickable.makeemptyfn = makeemptyfn
    
        inst:AddComponent("inspectable")
    
        ---------------------
        inst:AddComponent("fuel")
        inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL
    
        MakeSmallBurnable(inst, TUNING.SMALL_FUEL)
        AddToRegrowthManager(inst)
        MakeSmallPropagator(inst)
        MakeNoGrowInWinter(inst)
        MakeHauntableIgnite(inst)
        ---------------------
    
        return inst
    end

    return Prefab(name, fn, assets, prefabs)
end

return MakeReeds("reeds", "reeds", "reeds.png")