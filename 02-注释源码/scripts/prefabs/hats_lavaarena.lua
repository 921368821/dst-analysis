--============================================================
-- 文件：prefabs/hats_lavaarena.lua
-- 模块：预制体 / hats_lavaarena（建筑与容器）
-- 职责：实体「hats_lavaarena」的预制体定义。SpawnPrefab("hats_lavaarena") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function MakeHat(name)
    local build = "hat_"..name
    local symbol = name.."hat"

    local assets =
    {
        Asset("ANIM", "anim/"..build..".zip"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(symbol)
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation("anim")

        inst:AddTag("hat")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        event_server_data("lavaarena", "prefabs/hats_lavaarena").master_postinit(inst, name, build, symbol)

        return inst
    end

    return Prefab("lavaarena_"..name.."hat", fn, assets)
end

return MakeHat("feathercrown"),
    MakeHat("lightdamager"),
    MakeHat("recharger"),
    MakeHat("healingflower"),
    MakeHat("tiaraflowerpetals"),
    MakeHat("strongdamager"),
    MakeHat("crowndamager"),
    MakeHat("healinggarland"),
    MakeHat("eyecirclet")
