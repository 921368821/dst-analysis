--============================================================
-- 文件：shadeeffects.lua
-- 模块： / shadeeffects
-- 职责：模块中的「shadeeffects」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

if TheNet:IsDedicated() then
    local nullfunc = function() end
    ShadeEffectUpdate = nullfunc
    SpawnLeafCanopy = nullfunc
    DespawnLeafCanopy = nullfunc
    EnableShadeRenderer = nullfunc
    return
end

ShadeTypes.LeafCanopy = ShadeRenderer:CreateShadeType()

ShadeRenderer:SetShadeMaxRotation(ShadeTypes.LeafCanopy, TUNING.CANOPY_MAX_ROTATION)
ShadeRenderer:SetShadeRotationSpeed(ShadeTypes.LeafCanopy, TUNING.CANOPY_ROTATION_SPEED)

ShadeRenderer:SetShadeMaxTranslation(ShadeTypes.LeafCanopy, TUNING.CANOPY_MAX_TRANSLATION)
ShadeRenderer:SetShadeTranslationSpeed(ShadeTypes.LeafCanopy, TUNING.CANOPY_TRANSLATION_SPEED)

ShadeRenderer:SetShadeTexture(ShadeTypes.LeafCanopy, "images/tree.tex")

function SpawnLeafCanopy(x, z)
    return ShadeRenderer:SpawnShade(ShadeTypes.LeafCanopy, x, z, math.random() * 360, TUNING.CANOPY_SCALE)
end

function DespawnLeafCanopy(id)
    ShadeRenderer:RemoveShade(ShadeTypes.LeafCanopy, id)
end

function ShadeEffectUpdate(dt)
    local r, g, b = TheSim:GetAmbientColour()

    ShadeRenderer:SetShadeStrength(ShadeTypes.LeafCanopy, Lerp(TUNING.CANOPY_MIN_STRENGTH, TUNING.CANOPY_MAX_STRENGTH, ((r + g + b) / 3) / 255))
    ShadeRenderer:Update(dt)
end

function EnableShadeRenderer(enable)
    print("EnableShadeRenderer: ", enable)
    ShadeRenderer:Enable(enable)
end