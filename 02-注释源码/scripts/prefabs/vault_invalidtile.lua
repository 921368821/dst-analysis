--============================================================
-- 文件：prefabs/vault_invalidtile.lua
-- 模块：预制体 / vault_invalidtile（建筑与容器）
-- 职责：实体「vault_invalidtile」的预制体定义。SpawnPrefab("vault_invalidtile") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("datagrid")

local BLOCKERS
local function InitializeBlockersGrid()
    if BLOCKERS == nil then
        BLOCKERS = DataGrid(TheWorld.Map:GetSize())
    end
end

local function OnUpdateSleepStatus(inst)
    if inst.OnEntityWake then
        inst.OnEntityWake = nil
        inst.OnEntitySleep = nil
    end

    InitializeBlockersGrid()
    local tx, ty = TheWorld.Map:GetTileCoordsAtPoint(inst.Transform:GetWorldPosition())
    BLOCKERS:SetDataAtPoint(tx, ty, true)
end

local function OnRemove(inst)
    local tx, ty = TheWorld.Map:GetTileCoordsAtPoint(inst.Transform:GetWorldPosition())
    BLOCKERS:SetDataAtPoint(tx, ty, nil)
end

-- Global
function IsVaultTileInvalid(tx, ty)
    return BLOCKERS and BLOCKERS:GetDataAtPoint(tx, ty)
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
    inst.entity:AddNetwork()

    -- Don't use CLASSIFIED because vaultroom uses FindEntities
    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")

    inst.OnEntityWake = OnUpdateSleepStatus
    inst.OnEntitySleep = OnUpdateSleepStatus
    inst.OnRemoveEntity = OnRemove

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	return inst
end

return Prefab("vault_invalidtile", fn)