--[[
==============================================================================
 seasons.lua —— 完整四季循环验证（走原版 seasons 组件，不自造任何逻辑）
==============================================================================
目的
    此前只演示过「用 `ms_setseason` 切到 winter」，**没有跑过完整循环**。
    本入口验证的是原版 `components/seasons.lua` 的整条推进链：
        OnAdvanceSeason → GetNextSeason → _season netvar → 推 seasontick
        → worldstate 更新 state.season / remainingdaysinseason
        → 反过来按季节改写昼夜分段（PushSeasonClockSegs）
    全部由原版代码完成，宿主只负责「把时间往前推」。

为什么用 ms_setseasonlength 缩短
    默认季节长度：autumn 20 / winter 15 / spring 20 / summer 15 = **70 游戏日**
    = 70 × 480 s = 33600 s = 100.8 万 tick，按 ~1300 tick/s 要跑 13 分钟。
    `ms_setseasonlength`（seasons.lua:388 OnSetSeasonLength）**正是 DST
    世界生成设置里的「季节长度档」**（very short / short / default / long …），
    所以用它不是作弊，而是走原版配置入口。
    每季 3 天 ⇒ 完整循环 12 游戏日 = 172800 tick，约 2 分钟。

环境变量
    SEASON_DAYS   每个季节的天数（默认 3）
    SEASON_DAYS_TOTAL  跑多少个游戏日（默认自动算满一个循环）
    SEASON_START  起始季节（默认 autumn）
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

-- 分节标题（world.lua 里同款，那里是局部函数，这里自带一个）
local function hr(t)
    print("")
    print(string.rep("═", 70))
    print("  " .. tostring(t))
    print(string.rep("═", 70))
end

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

Bootstrap.Setup()

local SEASON_DAYS  = tonumber(os.getenv("SEASON_DAYS")) or 3
local SEASON_START = os.getenv("SEASON_START") or "autumn"
-- 四季 × N 天 + 1 天余量，保证看到「回到起点」那一刻
local TOTAL_DAYS   = tonumber(os.getenv("SEASON_DAYS_TOTAL")) or (SEASON_DAYS * 4 + 1)

hr("1) 挂载世界组件")
local W = _G.TheWorld
local mounted = {}
for _, nm in ipairs({ "clock", "worldtemperature", "seasons", "shardstate",
                      "worldreset" }) do
    pcall(W.AddComponent, W, nm)
    if W.components ~= nil and W.components[nm] ~= nil then
        mounted[#mounted + 1] = nm
    end
end
print(string.format("  世界组件 %d/5：%s", #mounted, table.concat(mounted, ", ")))

hr("2) 配置季节（走原版 ms_setseason / ms_setseasonlength 事件）")
-- 起点：原版入口 seasons.lua:469 监听 ms_setseason
W:PushEvent("ms_setseason", SEASON_START)
print(string.format("  起始季节 → %s（实测 %s）", SEASON_START, tostring(W.state.season)))
-- 长度：原版入口 seasons.lua:470 监听 ms_setseasonlength，data = {season, length, random}
local ORDER = { "autumn", "winter", "spring", "summer" }
for _, s in ipairs(ORDER) do
    W:PushEvent("ms_setseasonlength", { season = s, length = SEASON_DAYS, random = false })
end
print(string.format("  每季 %d 天（原版默认 autumn20/winter15/spring20/summer15）",
    SEASON_DAYS))

hr("3) 记录季节变化点")
-- 用原版事件拿变化点：seasons.lua:248 推 `seasontick`，worldstate 据此更新
local transitions = {}   -- { {游戏日, 季节, 温度, 分段}, ... }
-- ★ 昼夜分段没有公开 getter（clock.lua 里是局部 netvar），
--   但 `clocksegschanged` 事件带的 data 就是 {day=, dusk=, night=}（clock.lua:386）。
--   第一版我读 `st.daysegs` 这种不存在的字段，结果全是 -1 ——
--   「数字好看（没报错）但内容是空的」，比报错更难发现。
local live_segs = nil
W:ListenForEvent("clocksegschanged", function(_, d)
    if type(d) == "table" then live_segs = d end
end)
-- 每个季节的温度区间（不是只记切换那一刻的点）
--
-- ★★ 必须在 `temperaturetick` 里记，**不能在 `seasontick` 里记**。
--   这两个状态由**两个不同事件**更新：
--     · `state.season`      ← worldstate.lua:116 OnSeasonTick（seasontick）
--     · `state.temperature` ← worldstate.lua:134 OnTemperatureTick（temperaturetick），
--                             而 temperaturetick 是 worldtemperature 的 OnUpdate 推的
--   在 seasontick 处理器里读 temperature，拿到的是**上一季**算的值
--   —— 实测症状：四季区间首尾相接，winter 记到 5.3（autumn 末端）、
--   spring 记到 -29.0（winter 谷底）。这是测量 bug，不是引擎 bug。
local season_range = {}
W:ListenForEvent("temperaturetick", function()
    local st = W.state
    local s = tostring(st.season)
    local t = tonumber(st.temperature) or 0
    local r = season_range[s]
    if r == nil then r = { min = 1e9, max = -1e9, n = 0 } end
    r.min = math.min(r.min, t)
    r.max = math.max(r.max, t)
    r.n = r.n + 1
    season_range[s] = r
end)

W:ListenForEvent("seasontick", function()
    local st = W.state
    local s = tostring(st.season)
    -- ⚠️ 这里只用于「变化点那一行的展示值」，统计区间用的是 temperaturetick 里的
    --    season_range。两处读同一个字段但**时机不同**，别把展示值当成统计数据。
    local t = tonumber(st.temperature) or 0
    local last = transitions[#transitions]
    if last == nil or last[2] ~= s then
        local sg = live_segs
        transitions[#transitions + 1] = {
            Sim.TheSim.time / 480,          -- 游戏日
            s,
            t,
            sg and string.format("%d/%d/%d", sg.day or -1, sg.dusk or -1,
                                 sg.night or -1) or "?",
        }
    end
end)

hr(string.format("4) 跑 %d 个游戏日（%d tick）", TOTAL_DAYS, TOTAL_DAYS * 14400))
local t0 = os.clock()
local ticks = TOTAL_DAYS * 14400
-- 不需要实体，但时钟与世界状态要靠更新泵推进
local ok, err = pcall(function()
    for i = 1, ticks do Sim.Step() end
end)
if not ok then
    print("  ✘ 运行中断：" .. tostring(err):sub(1, 200))
end
local dt = (os.clock() - t0) * 1000

hr("5) 结果")
print(string.format("  跑完 %d tick（%.0f s 世界时间）用时 %.0f ms（%.0f tick/s）",
    ticks, ticks * Sim.TheSim.TICK_TIME, dt, ticks / math.max(dt / 1000, 0.001)))
print("")
print("  ── 每个季节的温度区间（temperaturetick 全程采样）──")
for _, s in ipairs(ORDER) do
    local r = season_range[s]
    if r then
        print(string.format("    %-8s [%7.1f, %7.1f]°C  （%d 个采样点）",
            s, r.min, r.max, r.n))
    end
end
print("")
print("  ── 季节变化点（游戏日 / 季节 / 温度 / 昼夜分段）──")
for i, t in ipairs(transitions) do
    print(string.format("    %2d. 第 %5.1f 天  %-8s  %6.1f°C  分段 %s",
        i, t[1], t[2], t[3], t[4]))
end

-- 校验：顺序必须严格等于 原版 SEASON_NAMES 的循环
hr("6) 校验")
local seen = {}
for _, t in ipairs(transitions) do
    if seen[#seen] ~= t[2] then seen[#seen + 1] = t[2] end
end
print("  实测季节顺序：" .. table.concat(seen, " → "))
local expected = { SEASON_START }
for i = 2, #ORDER + 1 do
    local idx = 1
    for k, v in ipairs(ORDER) do if v == SEASON_START then idx = k end end
    expected[#expected + 1] = ORDER[((idx + i - 2) % #ORDER) + 1]
end
print("  原版 SEASON_NAMES 顺序：" .. table.concat(expected, " → "))

local okorder = #seen >= 5
for i = 1, math.min(#seen, #expected) do
    if seen[i] ~= expected[i] then okorder = false end
end
print(string.format("  顺序一致：%s", okorder and "✔" or "✘"))

-- 四季都真的出现过
local have = {}
for _, t in ipairs(transitions) do have[t[2]] = true end
local allfour = true
for _, s in ipairs(ORDER) do if not have[s] then allfour = false end end
print(string.format("  四季都出现过：%s", allfour and "✔" or "✘"))

-- 冬天必须比秋天冷（温度区间）
local ta, tw = nil, nil
for _, t in ipairs(transitions) do
    if t[2] == "autumn" then ta = math.min(ta or 1e9, t[3]) end
    if t[2] == "winter" then tw = math.min(tw or 1e9, t[3]) end
end
if ta ~= nil and tw ~= nil then
    print(string.format("  冬季最低 %.1f°C vs 秋季最低 %.1f°C：%s",
        tw, ta, tw < ta and "✔ 冬天更冷" or "✘ 温度不符合预期"))
else
    print("  温度对比：数据不足")
end

Core.DumpGaps()
hr("完成")
