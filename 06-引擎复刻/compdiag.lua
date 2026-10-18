package.path = "./?.lua;./host/?.lua;" .. package.path
local Core = require("host.01_core")
local Bootstrap = require("host.05_bootstrap")
Bootstrap.Setup()
local comps = {"floater","fueled","combat","inventory","mound","deployer","lootdropper",
  "workable","spawner","playerprox","inspectable","burnable","health","drownable",
  "stackable","equippable","weapon","instrument","finiteuses","repairable",
  "harvestable","pickable","growable","age","preserver","tradable","leader",
  "locomotor","sanity","hunger","temperature","moisture","freezable",
  "prototyper","trader","complexprojectile","projectile","hauntable"}
print("组件加载诊断（走 Bootstrap）:")
local okc, failc = 0, 0
for _,c in ipairs(comps) do
  local e = Core.NewEntity("t")
  local r, err = pcall(function() return e:AddComponent(c) end)
  if r and e.components[c] then okc=okc+1 else failc=failc+1
    print(string.format("  ✘ %-18s %s", c, tostring(err):sub(1,140)))
  end
end
print(string.format("成功 %d / 失败 %d", okc, failc))
print("")
Core.DumpGaps()
