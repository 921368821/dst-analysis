--============================================================
-- 文件：prefabs/sounddebugicon.lua
-- 模块：预制体 / sounddebugicon（建筑与容器）
-- 职责：实体「sounddebugicon」的预制体定义。SpawnPrefab("sounddebugicon") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/sounddebug.zip"),
}

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
    inst.entity:AddLabel()

    inst.Label:SetFontSize(20)
    inst.Label:SetFont(DEFAULTFONT)
    inst.Label:SetWorldOffset(0, .1, 0)
    inst.Label:SetUIOffset(0, 0, 0)
    inst.Label:SetColour(.73, .05, .02)
    inst.Label:Enable(true)

    inst.AnimState:SetBank("sound")
    inst.AnimState:SetBuild("sounddebug")
    inst.AnimState:PlayAnimation("idle")
    inst.AnimState:SetFinalOffset(1)

    inst:AddTag("FX")
    --[[Non-networked entity]]
    inst.persists = false

    inst.autokilltask = inst:DoTaskInTime(0.5, inst.Remove)
    return inst
end

return Prefab("sounddebugicon", fn, assets)
