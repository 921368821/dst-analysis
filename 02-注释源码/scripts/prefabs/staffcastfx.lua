--============================================================
-- 文件：prefabs/staffcastfx.lua
-- 模块：预制体 / staffcastfx（建筑与容器）
-- 职责：实体「staffcastfx」的预制体定义。SpawnPrefab("staffcastfx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/staff.zip"),
}

local assets_cointoss =
{
    Asset("ANIM", "anim/cointosscast_fx.zip"),
    Asset("ANIM", "anim/mount_cointosscast_fx.zip"),
}

local assets_pocketwatch =
{
    Asset("ANIM", "anim/pocketwatch_casting_fx.zip"),
    Asset("ANIM", "anim/pocketwatch_casting_fx_mount.zip"),
}

local assets_pocketwatch_warp =
{
    Asset("ANIM", "anim/pocketwatch_warp_casting_fx.zip"),
}

local function SetUp(inst, colour)
    inst.AnimState:SetMultColour(colour[1], colour[2], colour[3], 1)
end

local function MakeStaffFX(anim, build, bank, ismount)
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        inst:AddTag("FX")

		if ismount then
			inst.Transform:SetSixFaced()
		else
			inst.Transform:SetFourFaced()
		end

        inst.AnimState:SetBank(bank or "staff_fx")
        inst.AnimState:SetBuild(build or "staff")
        inst.AnimState:PlayAnimation(anim)
	    inst.AnimState:SetFinalOffset(1)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst.SetUp = SetUp

        inst.persists = false

        --Anim is padded with extra blank frames at the end
        inst:ListenForEvent("animover", inst.Remove)

        return inst
    end
end

return Prefab("staffcastfx", MakeStaffFX("staff"), assets),
	Prefab("staffcastfx_mount", MakeStaffFX("staff_mount", nil, nil, true), assets),
	Prefab("cointosscastfx", MakeStaffFX("cointoss", "cointosscast_fx", "cointosscast_fx"), assets_cointoss),
	Prefab("cointosscastfx_mount", MakeStaffFX("cointoss", "cointosscast_fx", "mount_cointosscast_fx", true), assets_cointoss),
	Prefab("pocketwatch_cast_fx", MakeStaffFX("pocketwatch_cast", "pocketwatch_casting_fx", "pocketwatch_cast_fx"), assets_pocketwatch),
	Prefab("pocketwatch_cast_fx_mount", MakeStaffFX("pocketwatch_cast", "pocketwatch_casting_fx_mount", "pocketwatch_casting_fx_mount", true), assets_pocketwatch),
	Prefab("pocketwatch_warpback_fx", MakeStaffFX("warpfx", "pocketwatch_warp_casting_fx", "pocketwatch_warp_casting_fx"), assets_pocketwatch_warp),
	Prefab("pocketwatch_warpbackout_fx", MakeStaffFX("warpfx_pst", "pocketwatch_warp_casting_fx", "pocketwatch_warp_casting_fx"), assets_pocketwatch_warp)
