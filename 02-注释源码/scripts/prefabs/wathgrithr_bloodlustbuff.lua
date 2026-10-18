--============================================================
-- 文件：prefabs/wathgrithr_bloodlustbuff.lua
-- 模块：预制体 / wathgrithr_bloodlustbuff（建筑与容器）
-- 职责：实体「wathgrithr_bloodlustbuff」的预制体定义。SpawnPrefab("wathgrithr_bloodlustbuff") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function MakeBuff(name, build, scale, offset)
    local assets =
    {
        Asset("ANIM", "anim/"..build..".zip"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        inst.AnimState:SetBank(build)
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation("in")
        inst.AnimState:SetMultColour(1, 1, 1, .5)

        inst.Transform:SetScale(scale, scale, scale)

        inst:AddTag("DECOR") --"FX" will catch mouseover
        inst:AddTag("NOCLICK")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        event_server_data("lavaarena", "prefabs/wathgrithr_bloodlustbuff").master_postinit(inst, offset)

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeBuff("wathgrithr_bloodlustbuff_self", "lavaarena_attack_buff_effect", 1.4, 0),
    MakeBuff("wathgrithr_bloodlustbuff_other", "lavaarena_attack_buff_effect2", 1, 1)
