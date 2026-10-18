package.path = "./?.lua;./host/?.lua;" .. package.path
local Core=require("host.01_core"); local Loader=require("host.04_loader")
local Sim=require("host.02_sim"); local Bootstrap=require("host.05_bootstrap")
Bootstrap.Setup()
Bootstrap.LoadPrefabFile("pigman")
local U=require("host.07_universal")
U.Install(Core); local p=Core.SpawnPrefab("pigman"); U.Uninstall()
print("  DropDeathLoot = " .. tostring(p.DropDeathLoot))
print("  是桩吗：调一次看 Core.Stubs")
Core.NoteStub("__probe__", "test")
local before = 0
for k,v in pairs(Core.StubCounts or {}) do before = before + v end
print("  StubCounts 存在 = " .. tostring(Core.StubCounts ~= nil))
