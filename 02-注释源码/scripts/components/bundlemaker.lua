--============================================================
-- 文件：components/bundlemaker.lua
-- 模块：组件 / bundlemaker
-- 职责：组件「bundlemaker」的实现。组件是挂在实体上的行为单元，通过 inst.components.bundlemaker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BundleMaker = Class(function(self, inst)
    self.inst = inst
    self.bundlingprefab = nil
    self.bundledprefab = nil
    self.onstartbundlingfn = nil
end)

function BundleMaker:SetBundlingPrefabs(bundling, bundled)
    self.bundlingprefab = bundling
    self.bundledprefab = bundled
end

function BundleMaker:SetSkinData(skinname, skin_id)
    self.bundledskinname = skinname
    self.bundledskin_id = skin_id
end

function BundleMaker:SetOnStartBundlingFn(fn)
    self.onstartbundlingfn = fn
end

function BundleMaker:OnStartBundling(doer)
    if self.onstartbundlingfn ~= nil then
        self.onstartbundlingfn(self.inst, doer)
    end
end

return BundleMaker
