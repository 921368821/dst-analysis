--============================================================
-- 文件：components/distancefade.lua
-- 模块：组件 / distancefade
-- 职责：组件「distancefade」的实现。组件是挂在实体上的行为单元，通过 inst.components.distancefade 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local DistanceFade = Class(function(self, inst)
    self.inst = inst

    self.range = 25
    self.fadedist = 15
end)

function DistanceFade:Setup(range, fadedist)
    self.range = range
    self.fadedist = fadedist
end

function DistanceFade:SetExtraFn(fn)
    self.extrafn = fn
end

function DistanceFade:OnEntitySleep()
    self.inst:StopWallUpdatingComponent(self)
end

function DistanceFade:OnEntityWake()
    self.inst:StartWallUpdatingComponent(self)
end

function DistanceFade:OnWallUpdate(dt)
    if not ThePlayer then
        self.inst.AnimState:OverrideMultColour(1, 1, 1, 1)
        return
    end

    local camx, camy, camz = TheCamera.currentpos:Get()
    local x, y, z = self.inst.Transform:GetWorldPosition()
    local diffcoords = Vector3(x - camx, y - camy, z - camz)

    local down = TheCamera:GetDownVec()
    local mody = diffcoords:Dot(down)

    local extrapercent = self.extrafn and self.extrafn(self.inst, dt) or 1
    if mody > self.range then
        mody = mody - self.range
        mody = math.min(mody, self.fadedist) * 1.7
        local percent = (1 - (mody / self.fadedist)) * extrapercent
        self.inst.AnimState:OverrideMultColour(1, 1, 1, percent)
    else
        local percent = 1 * extrapercent
        self.inst.AnimState:OverrideMultColour(1, 1, 1, percent)
    end
end

return DistanceFade