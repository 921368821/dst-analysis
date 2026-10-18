--============================================================
-- 文件：prefabs/torchfire_tesla.lua
-- 模块：预制体 / torchfire_tesla（建筑与容器）
-- 职责：实体「torchfire_tesla」的预制体定义。SpawnPrefab("torchfire_tesla") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MakeTorchFire = require("prefabs/torchfire_common")

local assets =
{
    Asset("DYNAMIC_ANIM", "anim/dynamic/lantern_tesla.zip"),
    Asset("PKGREF", "anim/dynamic/torch_tesla.dyn"),
}

local function common_postinit(inst)
    inst.AnimState:SetBank("torch_tesla_fx")
	inst.AnimState:SetBuild("swap_torch")
	inst.AnimState:PlayAnimation("idle", true)
	inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
	inst.AnimState:SetFinalOffset(1)
end

local function AssignSkinData(inst, parent)
	inst.AnimState:OverrideItemSkinSymbol("bolt_b", "torch_tesla", "bolt_b", parent.GUID, "torch")
	inst.AnimState:OverrideItemSkinSymbol("bolt_c", "torch_tesla", "bolt_c", parent.GUID, "torch")
	inst.AnimState:OverrideItemSkinSymbol("torch_overlay", "torch_tesla", "torch_overlay", parent.GUID, "torch")
end

local function master_postinit(inst)
	inst.AssignSkinData = AssignSkinData
    inst.fx_offset = -125
end

return MakeTorchFire("torchfire_tesla", assets, nil, common_postinit, master_postinit, { -- Overrides.
    hasanimstate = true,
    sfx_torchloop = "skin_sfx/common/torch_tesla",
})
