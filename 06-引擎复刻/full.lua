--[[
==============================================================================
 full.lua —— 全量预制体加载：把 prefabs/ 整个目录装进注册表

 为什么做这个
   现在注册表只有 112 个预制体，真实 DST 有 **1594 个 prefab 文件**。
   数量差距造成两个后果：
     · SpawnPrefab("hostile_flame") 这类调用返回 nil，
       让「依赖声明的预制体一定存在」这个前提不成立
     · batch 28/28 的通过率是在「40 个候选」上测的，
       不能代表全量

 做法
   遍历 prefabs/*.lua → 逐个 LoadFile → 统计注册数
   失败的单独列出（含原因），这才是**真实的契约覆盖率**。

 注意
   · 有些文件不是预制体（如 xxx_defs.lua / _common.lua），加载它们无害
   · 加载顺序按文件名排序，保证可重现
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core = require("host.01_core")
local Loader = require("host.04_loader")
local Bootstrap = require("host.05_bootstrap")

Bootstrap.Setup()

-- ⚠️ 千万不要在这里把 require 换回原生实现！
--   实测踩到：换成 NativeRequire 后，每个 prefab 的 require("prefabutil")
--   之类全部失败，602/1594 报 "module not found"。
--   扫描阶段的 require 也必须走 Loader 钩子，才能解析到 DST 源码。
-- （保留这行说明，防止后人重犯）

--=========================================================================
-- 枚举 prefabs/ 目录
--=========================================================================
local PF = Core.SourceDir .. "/prefabs"
local files = {}

-- Windows 用 dir，Unix 用 ls。宿主环境是 Windows（Git Bash 下也能跑 dir）
-- ★ M6：统一走 host/31_filelist（① Python 清单 → ② ls → ③ dir，三级降级）。
--   原来这里是 `io.popen('dir /b ...')`，在没有 cmd.exe 的环境里会静默返回空表。
local function listdir(dir)
    return (require("host.31_filelist").List(dir))
end

files = listdir(PF)
table.sort(files)

if #files == 0 then
    -- 退化方案：目录枚举失败时不静默，明确报出来
    print("✘ 无法枚举 prefabs/ 目录（io.popen 受限）")
    print("  目录: " .. PF)
    os.exit(1)
end

print("════ 全量预制体加载 ════")
print(string.format("prefabs/ 目录共 %d 个 .lua 文件", #files))
print("")

--=========================================================================
-- 逐个加载
--=========================================================================
local loaded, failed, noprefab = 0, 0, 0
local faildetail = {}
local t0 = os.clock()

for i, f in ipairs(files) do
    local before = 0
    for _ in pairs(Core.Prefabs) do before = before + 1 end

    local ok, err = Loader.LoadFile(PF .. "/" .. f)

    local after = 0
    for _ in pairs(Core.Prefabs) do after = after + 1 end

    if not ok then
        failed = failed + 1
        if #faildetail < 25 then
            faildetail[#faildetail + 1] = f .. " → " .. tostring(err):sub(1, 110)
        end
    elseif after == before then
        noprefab = noprefab + 1      -- 加载成功但没注册预制体（数据文件）
    else
        loaded = loaded + 1
    end
end

local dt = (os.clock() - t0) * 1000
local total = 0
for _ in pairs(Core.Prefabs) do total = total + 1 end

print("════ 加载结果 ════")
print(string.format("  ✔ 注册了预制体的文件 : %d", loaded))
print(string.format("  – 加载成功但无预制体 : %d（数据/工具文件，正常）", noprefab))
print(string.format("  ✘ 加载失败           : %d", failed))
print(string.format("  ── 注册表预制体总数  : %d", total))
print(string.format("  用时 %.0f ms", dt))
print("")

if #faildetail > 0 then
    print("失败明细（前 25）:")
    for _, d in ipairs(faildetail) do print("  " .. d) end
    print("")
end

print("════ 缺口清单 ════")
Core.DumpGaps()
