--============================================================
-- 文件：components/vaultorbteleporter.lua
-- 模块：组件 / vaultorbteleporter
-- 职责：组件「vaultorbteleporter」的实现。组件是挂在实体上的行为单元，通过 inst.components.vaultorbteleporter 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local VaultOrbTeleporter = Class(function(self, inst)
    self.inst = inst

    --self.onactivatefn = nil

    --self.bufferedmapaction = nil
    --self.onstartmapactionfn = nil
    --self.oncancelmapactionfn = nil
    self._onremovebufferedmapaction = function(bufferedmapaction)
        if self.oncancelmapactionfn then
            self.oncancelmapactionfn(self.inst, bufferedmapaction.doer)
        end
    end
end)

function VaultOrbTeleporter:OnRemoveEntity()
    if self.bufferedmapaction then
        self.bufferedmapaction:Remove()
        if self.oncancelmapactionfn then
            self.oncancelmapactionfn(self.inst, self.bufferedmapaction.doer)
        end
        self.bufferedmapaction = nil
    end
end

function VaultOrbTeleporter:OnRemoveFromEntity()
    self:CancelMapAction()
end

function VaultOrbTeleporter:SetOnActivateFn(fn)
    self.onactivatefn = fn
end

function VaultOrbTeleporter:SetOnStartMapActionFn(fn)
    self.onstartmapactionfn = fn
end

function VaultOrbTeleporter:SetOnCancelMapActionFn(fn)
    self.oncancelmapactionfn = fn
end

function VaultOrbTeleporter:StartMapAction(doer)
    if self.bufferedmapaction then
        return false
    end
    if self.onstartmapactionfn then
        local success, reason = self.onstartmapactionfn(self.inst, doer)
        if not success then
            return false, reason
        end
    end

    self.bufferedmapaction = SpawnPrefab("bufferedmapaction")
    self.inst:ListenForEvent("onremove", self._onremovebufferedmapaction, self.bufferedmapaction)
    self.bufferedmapaction:SetupMapAction(ACTIONS.VAULTORBTELEPORT_MAP, self.inst, doer)
    return true
end

function VaultOrbTeleporter:CancelMapAction()
    if self.bufferedmapaction then
        self.bufferedmapaction:Remove()
        self.bufferedmapaction = nil
    end
end

function VaultOrbTeleporter:Activate(doer, target)
    if not target.components.vaultorbteleportdestination then
        return false, "NOTARGET"
    end

    if self.onactivatefn then
        local success, reason = self.onactivatefn(self.inst, doer, target)
        if not success then
            return false, reason
        end
    end

    return true
end

return VaultOrbTeleporter
