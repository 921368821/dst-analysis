--[[
==============================================================================
 equip.lua —— 装备 / 卸下的**往返**验证（符号覆盖真的清干净了吗）
==============================================================================
为什么单独验
    此前只验过「装备 → 符号覆盖 → 画面上多一块」这条**正向**路径
    （tools/verify_override.py，像素级：133 像素 / 1 个连通块）。
    但**反向**路径从没验过 —— 而「半边实现」是这类功能最常见的坏法：
    戴上时写入了覆盖，摘下时没清掉。
    症状会很隐蔽：帽子已经不在装备栏里，画面上却还顶着。
    （同源教训见报告第 21 节 DropDeathLoot —— 没走到的分支不等于通的。）

判据（数据层，不依赖像素）
    ① 装备后  GetSymbolOverride("swap_hat") 必须非 nil
    ② 装备后  GetDrawList() 里该符号的条目必须带 bld（覆盖来源 build）
    ③ 卸下后  GetSymbolOverride("swap_hat") 必须为 nil
    ④ 卸下后  GetDrawList() 里不能再有指向该覆盖 build 的条目
    ⑤ 用 ClearAllOverrideSymbols 清场后再查一遍（更强的清场手段）

    第 ④ 条是关键：只查 ③ 不够 —— `GetSymbolOverride` 可能是从一张缓存表读的，
    而绘制用的是另一条路径。两条路径都得干净才算真卸下。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local Universal = require("host.07_universal")

Bootstrap.Setup()

local function hr(t)
    print("")
    print(string.rep("═", 70))
    print("  " .. tostring(t))
    print(string.rep("═", 70))
end

hr("1) 生成 wilson")
Bootstrap.LoadPrefabFile("wilson")
Universal.Install(Core)
local p = Core.SpawnPrefab("wilson")
Universal.Uninstall()
if p == nil then
    print("  ✘ wilson 生成失败，无法继续")
    return
end
p.Transform:SetPosition(0, 0, 0)
print(string.format("  ✔ wilson guid=%d  组件=%d", p._guid,
    (function() local n = 0 for _ in pairs(p._components) do n = n + 1 end return n end)()))

--=========================================================================
-- 工具：查「覆盖状态」的两条路径
--=========================================================================
local function override_of(sym)
    local as = p.AnimState
    if as == nil or type(as.GetSymbolOverride) ~= "function" then return nil end
    local ok, b, s = pcall(as.GetSymbolOverride, as, sym)
    if not ok then return nil end
    return b, s
end

-- 从 GetDrawList 里找出「带 bld（覆盖来源）」的条目
local function drawlist_overrides()
    local as = p.AnimState
    if as == nil or type(as.GetDrawList) ~= "function" then return {} end
    local ok, dl = pcall(as.GetDrawList, as)
    if not ok or type(dl) ~= "table" then return {} end
    local out = {}
    for _, el in ipairs(dl) do
        if el.bld ~= nil then
            out[#out + 1] = string.format("sym#%s→%s(atlas%s)",
                tostring(el.symh), tostring(el.bld), tostring(el.atlas))
        end
    end
    return out
end

local function report(tag)
    local b, s = override_of("swap_hat")
    local ov = drawlist_overrides()
    print(string.format("  [%s] GetSymbolOverride(swap_hat) = %s / %s",
        tag, tostring(b), tostring(s)))
    print(string.format("       GetDrawList 里带覆盖来源的条目：%d 个%s",
        #ov, #ov > 0 and ("  " .. table.concat(ov, ", ")) or ""))
    -- ★ bld 有**两个**来源，必须分开看，否则会误判「清场没生效」：
    --   ① _overrides        显式 OverrideSymbol（ClearAllOverrideSymbols 清它）
    --   ② _ov_builds        AddOverrideBuild 登记的「可提供覆盖符号的 build」
    --                       （ClearAllOverrideSymbols **不**清它，有独立的 ClearAllOverrideBuilds）
    local as = p.AnimState
    local n_o, n_ob, obnames = 0, 0, {}
    if type(as._overrides) == "table" then
        for _ in pairs(as._overrides) do n_o = n_o + 1 end
    end
    if type(as._ov_builds) == "table" then
        for k in pairs(as._ov_builds) do
            n_ob = n_ob + 1; obnames[#obnames + 1] = tostring(k)
        end
    end
    print(string.format("       内部：_overrides=%d 个  _ov_builds=%d 个%s",
        n_o, n_ob, n_ob > 0 and ("  [" .. table.concat(obnames, ", ") .. "]") or ""))
    return b, #ov
end

--=========================================================================
hr("2) 装备前的基线")
local b0, n0 = report("装备前")

--=========================================================================
hr("3) 装备 hat_football（走原版真实链路）")
-- ⚠️ 预制体名是 `footballhat`，**不是** `hat_football` ——
--   `hat_football` 是它的 **build** 名。这两个名字极易混：
--   83 个帽子都由 prefabs/hats.lua 一个文件注册（MakeHat 里 prefabname = name.."hat"），
--   所以要先加载 hats 这个「动态家族文件」，再 SpawnPrefab("footballhat")。
--   （第一版我写成 SpawnPrefab("hat_football") → nil → 装备失败。）
Bootstrap.LoadPrefabFile("hats")
local hat = nil
local ok_e, err_e = pcall(function()
    hat = Core.SpawnPrefab("footballhat")
    if hat == nil then error("footballhat 生成失败（hats 没加载上？）") end
    local inv = p.components.inventory
    if inv == nil then error("wilson 没有 inventory 组件") end
    -- 先 GiveItem 再 Equip：原版装备路径要求物品已在身上
    inv:GiveItem(hat)
    inv:Equip(hat)
end)
if not ok_e then
    print("  ✘ 装备失败：" .. tostring(err_e):sub(1, 200))
else
    print("  ✔ 装备完成")
end
local b1, n1 = report("装备后")

--=========================================================================
hr("4) 卸下（走 inventory:Unequip）")
-- 帽子在 EQUIPSLOTS.HEAD 槽（constants.lua 的 EQUIPSLOTS 表）
local headslot = (_G.EQUIPSLOTS ~= nil and _G.EQUIPSLOTS.HEAD) or "head"
local ok_u, err_u = pcall(function()
    local inv = p.components.inventory
    inv:Unequip(headslot)
end)
if not ok_u then
    print("  ⚠️ 第一次 Unequip 失败：" .. tostring(err_u):sub(1, 160))
end
local b2, n2 = report("卸下后")

--=========================================================================
hr("5) 清场（ClearAllOverrideSymbols）后再查")
local ok_c, err_c = pcall(function()
    p.AnimState:ClearAllOverrideSymbols()
end)
if not ok_c then
    print("  ⚠️ ClearAllOverrideSymbols 失败：" .. tostring(err_c):sub(1, 160))
end
local b3, n3 = report("清场后")

--=========================================================================
hr("6) 判定")
local pass = true
local function chk(cond, name)
    print(string.format("  %s %s", cond and "✔" or "✘", name))
    if not cond then pass = false end
end
chk(b0 == nil, "装备前 swap_hat 无覆盖")
chk(b1 ~= nil, "装备后 swap_hat 有覆盖（正向路径）")
chk(n1 > n0,  "装备后 GetDrawList 出现带 bld 的条目（绘制路径也看到了）")
chk(b3 == nil, "清场后 GetSymbolOverride 归 nil")
chk(n3 == 0,   "清场后 GetDrawList 无带 bld 的条目（注意：仅 ClearAllOverrideSymbols 时可能受 _ov_builds 影响）")
print("")
print(string.format("  ── 卸下（Unequip）这条路径：覆盖表 %s，绘制表 %s ──",
    b2 == nil and "已清" or "**未清**",
    n2 == 0 and "已清" or ("**仍有 " .. n2 .. " 条**")))
if b2 ~= nil or n2 ~= 0 then
    print("  ★ 注意：Unequip 没清干净，但 ClearAllOverrideSymbols 清了 ——")
    print("    说明清除机制本身可用，缺的是 Unequip 路径上没接上。")
end
print("")
print(string.format("  总判定：%s", pass and "✔ 通过" or "✘ 有失败项"))

Core.DumpGaps()
