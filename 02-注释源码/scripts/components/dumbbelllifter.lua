--============================================================
-- 文件：components/dumbbelllifter.lua
-- 模块：组件 / dumbbelllifter
-- 职责：组件「dumbbelllifter」的实现。组件是挂在实体上的行为单元，通过 inst.components.dumbbelllifter 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local DumbbellLifter = Class(function(self, inst)
    self.inst = inst
end)

function DumbbellLifter:CanLift(dumbbell)
    return true
end

function DumbbellLifter:IsLiftingAny()
    return self.dumbbell ~= nil
end

function DumbbellLifter:IsLifting(dumbbell)
    return self.dumbbell ~= nil and self.dumbbell == dumbbell
end

function DumbbellLifter:StartLifting(dumbbell)
    self.dumbbell = dumbbell
    self.dumbbell.components.mightydumbbell:StartWorkout(self.inst)
    self.inst:AddTag("liftingdumbbell")
end

function DumbbellLifter:StopLifting()
    if self.dumbbell then
        self.dumbbell.components.mightydumbbell:StopWorkout()
        self.dumbbell = nil
    end
    
    self.inst:RemoveTag("liftingdumbbell")
end

function DumbbellLifter:Lift()
    if self.dumbbell and self.dumbbell:IsValid() then
        if self.dumbbell.components.mightydumbbell:DoWorkout(self.inst) then
            return true
        else
            self.dumbbell = nil
            return false
        end
    end
end

return DumbbellLifter