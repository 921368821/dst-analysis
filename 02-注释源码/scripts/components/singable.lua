--============================================================
-- 文件：components/singable.lua
-- 模块：组件 / singable
-- 职责：组件「singable」的实现。组件是挂在实体上的行为单元，通过 inst.components.singable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Singable = Class(function(self, inst)
    self.inst = inst
    self.onsingfn = nil
end)

function Singable:SetOnSing(onsingfn)
    self.onsingfn = onsingfn
end

function Singable:Sing(singer)
    if singer.components.singinginspiration == nil then
        print ("ATTEMPTING TO SING WITH NO INSPIRATION")
        return
    end

    -- if self.inst.components.finiteuses ~= nil then
    --     self.inst.components.finiteuses:Use()
    -- end

    if self.onsingfn then
        self.onsingfn(self.inst, singer)
    end

    singer.components.singinginspiration:AddSong(self.inst.songdata, nil, self.inst)
end

return Singable