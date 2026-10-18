--============================================================
-- 文件：components/skeletonsweeper.lua
-- 模块：组件 / skeletonsweeper
-- 职责：组件「skeletonsweeper」的实现。组件是挂在实体上的行为单元，通过 inst.components.skeletonsweeper 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ SkeletonSweeper class definition ]]
--------------------------------------------------------------------------

return Class(function(self, inst)

assert(TheWorld.ismastersim, "SkeletonSweeper should not exist on client")

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--Private
local _enabled = true
local _nosweep = true --until after post init
local _skeletons = {}

--------------------------------------------------------------------------
--[[ Private member functions ]]
--------------------------------------------------------------------------

local function age_descending(a, b)
    return a.skeletonspawntime < b.skeletonspawntime
end

--------------------------------------------------------------------------
--[[ Private event handlers ]]
--------------------------------------------------------------------------

local function OnSkeletonRemove(skeleton)
    for i, v in ipairs(_skeletons) do
        if v == skeleton then
            table.remove(_skeletons, i)
            return
        end
    end
end

local function OnSkeletonSpawn(inst, skeleton)
    table.insert(_skeletons, skeleton)
    inst:ListenForEvent("onremove", OnSkeletonRemove, skeleton)

    if _enabled and not _nosweep then
        table.sort(_skeletons, age_descending)
        self:Sweep()
    end
end

local function OnEnableSkeletonSweeper(inst, enable)
    if _enabled ~= enable then
        _enabled = enable
        if enable and not _nosweep then
            table.sort(_skeletons, age_descending)
            self:Sweep()
        end
    end
end

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

inst:ListenForEvent("ms_skeletonspawn", OnSkeletonSpawn)
inst:ListenForEvent("ms_enableskeletonsweeper", OnEnableSkeletonSweeper)

--------------------------------------------------------------------------
--[[ Post initialization ]]
--------------------------------------------------------------------------

function self:OnPostInit()
    _nosweep = nil
    if _enabled then
        table.sort(_skeletons, age_descending)
        self:Sweep(nil, true)
    end
end

--------------------------------------------------------------------------
--[[ Public member functions ]]
--------------------------------------------------------------------------

function self:Sweep(max_to_keep, no_decay)
    if not _enabled then
        return
    end

    max_to_keep = max_to_keep or TUNING.MAX_PLAYER_SKELETONS

    while #_skeletons > max_to_keep do
        local todecay = _skeletons[1]

        table.remove(_skeletons, 1)
        inst:RemoveEventCallback("onremove", OnSkeletonRemove, todecay)

        if no_decay or todecay.Decay == nil then
            todecay:Remove()
        else
            todecay:Decay()
        end
    end
end

--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)