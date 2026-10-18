--============================================================
-- 文件：components/cattoy.lua
-- 模块：组件 / cattoy
-- 职责：组件「cattoy」的实现。组件是挂在实体上的行为单元，通过 inst.components.cattoy 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- Consider adding the "cattoy" or "cattoyairborne" in conjunction with adding this component.
-- While this component can behave without them, some creatures use that tag to identify items to play with.

local CatToy = Class(function(self, inst)
    self.inst = inst
    self.onplay_fn = nil
    self.bypass_last_air_time = nil
end)

function CatToy:SetOnPlay(fn)
    self.onplay_fn = fn
end

function CatToy:SetBypassLastAirTime(boolval)
    self.bypass_last_air_time = boolval or nil
end

function CatToy:ShouldBypassLastAirTime()
    return self.bypass_last_air_time
end

function CatToy:Play(doer, is_airborne)
	if self.onplay_fn ~= nil then
		return self.onplay_fn(self.inst, doer, is_airborne)
	end
    return false
end

return CatToy
