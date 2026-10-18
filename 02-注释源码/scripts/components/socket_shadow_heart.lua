--============================================================
-- 文件：components/socket_shadow_heart.lua
-- 模块：组件 / socket_shadow_heart
-- 职责：组件「socket_shadow_heart」的实现。组件是挂在实体上的行为单元，通过 inst.components.socket_shadow_heart 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Socket_Shadow_Heart = Class(function(self, inst)
    self.inst = inst

    if not self.inst.isplayer then
        if self.inst.prefab == "wx78_backupbody" then
            self.spawner = SpawnPrefab("wx78_heartveinspawner")
            self.spawner:ListenForEvent("onremove", function()
                self.spawner = nil
            end)
            self.spawner.entity:SetParent(self.inst.entity)
        end
    end
end)

function Socket_Shadow_Heart:OnRemoveFromEntity()
    if self.spawner then
        self.spawner:Remove()
    end
end

return Socket_Shadow_Heart
