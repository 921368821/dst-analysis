--[[
==============================================================================
 24_worldstatetags.lua —— WORLDSTATETAGS（世界状态标签位域）
==============================================================================
为什么需要它
   `WORLDSTATETAGS` 是 DST 的**纯 Lua** 全局，定义在 mainfunctions.lua：
       WORLDSTATETAGS = CreateWorldStateTag("WS:", "images/worldprogressionfilters.xml")
   宿主从未提供 ⇒ 21 处 `SetTagEnabled` 全部落在 nil 上。

   实测症状（reachability.lua 抽样，`moonrockseed`）：
       prefabs/moonrockseed.lua:276
       ✘ attempt to index global 'WORLDSTATETAGS' (a nil value)
   其他调用点：components/riftspawner.lua（4 处）、
               components/archivemanager.lua（2 处）。

★★ 为什么不是「整份加载 mainfunctions.lua」
   试过了，**不行**：该文件在 865 行左右就抛错（存档 newents 重建那段），
   而且**在抛错前已经写了 91 个全局**（`ProfileStatsSetField` / `Image` /
   `RemoveEntity` / 各种字体常量 …）—— 半执行状态比不执行更危险。
   ⇒ 整份加载被否决，不是因为「慢」，是因为**部分副作用不可控**。

★★ 为什么也不是「照抄一段」
   照抄会**随版本漂移**：项目里的 DST 源码是只读副本，一升级就对不上，
   而没人会记得回来同步这段副本。
   ⇒ 改成**运行时从真实文件里切出这一段**，用 loadstring 执行。
     这样执行的是**真实代码本身**，不是它的复制品。

切取范围（按内容锚定，不按行号 —— 行号会随版本变）
   起：    local WORLDSTATE_NAMESPACES = {}
   止：    WORLDSTATETAGS.Lock()          （含该行）
   区间内自带：CreateWorldStateTag / DeclareTag / Lock /
               SetTagEnabled / GetTagEnabled / EncodeTags / DecodeTags /
               DebugPrintTags / ClearAllTags，以及 7 个官方标签的声明。
   ★ 依赖只有 `bit`（宿主已提供，见 21_bit.lua）。

诚实边界
   · `DecodeTags` / `DebugPrintTags` 只在 debugcommands.lua 里用；
     本工程不跑交互命令，因此**未对它们做行为断言**
   · 若真实文件里锚点找不到（换版本 / 文件被裁剪），本模块**不静默**：
     记入缺口清单并要求显式失败
   · `atlas` 参数（"images/worldprogressionfilters.xml"）在本工程里
     只被 EncodeTags 之外的调试路径使用，索引不存在时不会影响标签读写
==============================================================================
]]

local Core = require("host.01_core")

local WST = {}

WST.File       = Core.SourceDir .. "/mainfunctions.lua"
WST.MarkBegin  = "local WORLDSTATE_NAMESPACES = {}"
WST.MarkEnd    = "WORLDSTATETAGS.Lock()"

WST.Installed  = false
WST.Error      = nil
WST.SourceText = nil     -- 实际执行的那段（供测试检查「切对了没有」）
WST.LineFrom   = nil
WST.LineTo     = nil

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- 取「从 pos 所在行行首到该行行尾」的完整行区间下标
local function line_span(src, from_pos, to_pos)
    local ls = from_pos
    while ls > 1 and src:sub(ls - 1, ls - 1) ~= "\n" do ls = ls - 1 end
    local le = to_pos
    while le <= #src and src:sub(le, le) ~= "\n" do le = le + 1 end
    return ls, le - 1
end

local function count_lines(src, upto)
    local n, p = 1, 1
    while true do
        local k = src:find("\n", p, true)
        if not k or k > upto then break end
        n = n + 1
        p = k + 1
    end
    return n
end

--- 从真实 mainfunctions.lua 切出 WorldStateTag 段并执行
function WST.Install()
    if WST.Installed then return true end

    local src = read_all(WST.File)
    if not src then
        WST.Error = "打不开 " .. WST.File
        Core.NoteGap("WORLDSTATETAGS: 源文件不可读", "worldstatetags")
        return false
    end

    local i = src:find(WST.MarkBegin, 1, true)
    if not i then
        WST.Error = "找不到起点锚 '" .. WST.MarkBegin .. "'"
        Core.NoteGap("WORLDSTATETAGS: 锚点缺失(起)", "worldstatetags")
        return false
    end
    local j = src:find(WST.MarkEnd, i, true)
    if not j then
        WST.Error = "找不到终点锚 '" .. WST.MarkEnd .. "'"
        Core.NoteGap("WORLDSTATETAGS: 锚点缺失(止)", "worldstatetags")
        return false
    end

    local ls, le = line_span(src, i, j + #WST.MarkEnd - 1)
    local text = src:sub(ls, le)

    WST.SourceText = text
    WST.LineFrom = count_lines(src, ls)
    WST.LineTo   = WST.LineFrom + select(2, text:gsub("\n", ""))
    WST.ByteLen  = #text

    local chunk, lerr = loadstring(text, "@" .. WST.File .. ":WorldStateTag")
    if not chunk then
        WST.Error = "loadstring 失败: " .. tostring(lerr)
        Core.NoteGap("WORLDSTATETAGS: 切出的段编译失败", "worldstatetags")
        return false
    end

    -- ★ 用 xpcall + traceback：万一真实段里有版本相关的新依赖，
    --   错误必须带上行号，否则「切出来但执行失败」会变成一个黑洞。
    local ok, err = xpcall(chunk, debug.traceback)
    if not ok then
        WST.Error = "执行失败: " .. tostring(err)
        local why = tostring(err):gsub("^.-:%d+: ", ""):sub(1, 70)
        Core.NoteGap("WORLDSTATETAGS: 段执行失败 (" .. why .. ")", "worldstatetags")
        return false
    end

    if type(_G.WORLDSTATETAGS) ~= "table" then
        WST.Error = "执行成功但 WORLDSTATETAGS 仍不是表"
        Core.NoteGap("WORLDSTATETAGS: 段执行后仍为空", "worldstatetags")
        return false
    end

    WST.Installed = true
    return true
end

--- 自检：API 面是否齐全（对齐 mainfunctions.lua 里的定义）
function WST.Audit()
    local W = _G.WORLDSTATETAGS
    local need = { "SetTagEnabled", "GetTagEnabled", "DeclareTag", "Lock",
                   "EncodeTags", "DecodeTags", "DebugPrintTags", "ClearAllTags" }
    local missing = {}
    if type(W) ~= "table" then return false, { "_G.WORLDSTATETAGS 不是表" } end
    for _, m in ipairs(need) do
        if type(W[m]) ~= "function" then missing[#missing + 1] = m end
    end
    return #missing == 0, missing
end

return WST
