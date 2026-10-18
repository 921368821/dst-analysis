--[[
==============================================================================
 00_paths.lua —— 路径解析（**单一来源**）

 为什么有这个文件：
   原来 DST 源码根目录是**硬编码**在 3 个文件里的同一串字面量
   （`01_core.lua` 的 Core.SourceDir、`02_sim.lua` 的 SRC、`04_loader.lua` 的 SRC）。
   工作区一搬迁（用户目录改名 / 工程换盘符 / 源码目录变成 `02-注释源码/scripts`），
   三处就必须同时改；漏一处不会报错，只会「找不到模块 ⇒ 返回空表 ⇒ 世界安静地不对」
   —— 正是本工程反复记过的失败形态：**词在≠行为在**。

 ★★ 第二个坑（2026-10-17 迁移时踩到）：**Windows 上的 Lua 打不开中文路径**。
   Lua 5.1 的 `io.open` / `loadfile` 走 C 的 `fopen`，用**ANSI 代码页**解释路径；
   而本工程的文件名/目录名是 UTF-8（`02-注释源码`）⇒ 无论路径多正确，
   `io.open` 都返回 `No such file or directory`。
   症状极具误导性：**像是「目录不存在」**，实际是**编码不匹配**。
   ⇒ 工程根下放了一个 ASCII 目录联接 `dstsrc` → `02-注释源码`（Windows Junction，
     同一份文件的另一个名字，不是拷贝，不会漂移）。
   ⇒ 校验时优先走 ASCII 路径；若只剩非 ASCII 候选，**直接报「编码」而不是「不存在」**。

 解析顺序（**第一个通过校验的胜出**）：
   1. 环境变量 `DST_SRC`（显式指定，最高优先；迁移/换机时唯一要改的地方）
   2. `<工程根>/dstsrc/scripts`                ← ASCII 联接（推荐）
   3. `<工程根>/02-注释源码/scripts`           ← 真实目录（Lua 在 Windows 上可能打不开）
   4. `<工程根>/scripts/scripts`               ← 迁移前的老布局
   5. `<工程根>/../scripts/scripts`
   其中「工程根」= 本文件所在的 `host/` 目录的上两级。

 校验方式：**要求 `components/health.lua` 真实存在（且真的能打开）**。
   —— 不校验「目录存在」而校验「一个具体的、必须存在的文件」：
      目录名对、内容空的情况（拷贝中断）同样会静默跑错，这条能挡住。

 ★ 全部候选都失败时**直接 error**，不许退回某个默认值。
   「找不到就说出来」比「猜一个继续跑」重要：后者会让几十个入口集体变成
   「模块缺失 ⇒ 空表 ⇒ 0 桩调用」的假绿（本工程栽过）。
==============================================================================
]]

local Paths = {}

--- 统一成正斜杠（Windows 上 debug 信息、环境变量都可能是反斜杠）
local function norm(p)
    return (tostring(p):gsub("\\", "/"))
end

--- 取目录部分（不含末尾斜杠）
local function dirname(p)
    p = norm(p):gsub("/+$", "")
    local d = p:match("^(.*)/[^/]*$")
    if d == nil or d == "" then return "." end
    return d
end

--- 是否绝对路径（Windows 盘符 / UNC / POSIX）
local function is_abs(p)
    p = norm(p)
    return p:match("^%a:/") ~= nil or p:match("^//") ~= nil or p:match("^/") ~= nil
end

--- 纯文本化的路径归一：折叠 `.`、解析 `x/..`（**不碰文件系统**）
--- 相对路径开头的 `..` 会被保留（无法在没有 cwd 的情况下消掉）
local function collapse(p)
    p = norm(p)
    local abs = is_abs(p)
    local prefix = abs and (p:match("^(%a:)/") and (p:match("^(%a:)/") .. "/") or "/") or ""
    local rest = abs and p:sub(#prefix + 1) or p
    local out = {}
    for seg in rest:gmatch("[^/]+") do
        if seg == "." then
            -- 丢掉
        elseif seg == ".." then
            if #out > 0 and out[#out] ~= ".." then
                table.remove(out)
            elseif not abs then
                table.insert(out, "..")
            end
        else
            table.insert(out, seg)
        end
    end
    local body = table.concat(out, "/")
    if abs then return prefix .. body end
    if body == "" then return "." end
    return body
end

local function is_file(p)
    local f = io.open(p, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

--- 是否含非 ASCII 字节（**这是 Windows 上 Lua 打不开的根因**）
local function has_non_ascii(p)
    return tostring(p):find("[\128-\255]") ~= nil
end

--- 校验一个候选目录是不是「真的、并且 Lua 真的读得到」的 DST scripts 根
local function valid(src)
    if type(src) ~= "string" or src == "" then return false end
    return is_file(collapse(src) .. "/components/health.lua")
end

--- 本文件自身的路径（Lua 记的是**加载时用的名字**，可能是相对路径）
local function this_source()
    local src = debug.getinfo(1, "S").source or ""
    return norm((src:gsub("^@", "")))
end

--- 候选列表（**顺序即优先级**），每项带来源说明，失败时一起打印
function Paths.Candidates()
    local list = {}
    local function add(src, why)
        if src and src ~= "" then
            table.insert(list, { src = collapse(src), why = why })
        end
    end

    add(os.getenv("DST_SRC"), "环境变量 DST_SRC")

    -- 工程根 = host/ 的上两级（source 是相对路径也能用：`host/../../…` 由 io.open 解析）
    local src = this_source()
    local engine = src:find("/") and dirname(dirname(src)) or nil
    if engine then
        local root = engine .. "/.."
        add(root .. "/dstsrc/scripts",     "工程根/dstsrc/scripts（ASCII 联接，Linux 上不存在时自动跳过）")
        add(root .. "/02-注释源码/scripts", "工程根/02-注释源码/scripts")
        add(root .. "/scripts/scripts",     "工程根/scripts/scripts（老布局）")
        add(root .. "/../scripts/scripts",  "工程根/../scripts/scripts")
    end

    -- 兜底：按 cwd（当 source 只有文件名时才会用到）
    add("dstsrc/scripts",             "cwd/dstsrc/scripts")
    add("02-注释源码/scripts",         "cwd/02-注释源码/scripts")
    add("../dstsrc/scripts",          "cwd/../dstsrc/scripts")
    add("../02-注释源码/scripts",      "cwd/../02-注释源码/scripts")
    add("scripts/scripts",            "cwd/scripts/scripts（老布局）")

    return list
end

--- 解析出 DST 源码根目录；**找不到就 error**（列出所有试过的路径）
function Paths.SourceDir()
    if Paths._src then return Paths._src end
    local tried, nonascii = {}, {}
    for _, item in ipairs(Paths.Candidates()) do
        if valid(item.src) then
            Paths._src = item.src
            Paths.Why = item.why
            return Paths._src
        end
        table.insert(tried, string.format("  ✘ %s\n      （来源：%s）", item.src, item.why))
        if has_non_ascii(item.src) then
            table.insert(nonascii, item.src)
        end
    end

    local hint = ""
    if #nonascii > 0 then
        -- ★ 这一条是**编码诊断**，不是猜测：Windows 上 Lua 的 io.open 走 ANSI 代码页，
        --   UTF-8 的中文路径必然打不开（即使目录确实存在）。
        hint = "\n\n★ 注意：上面有 " .. #nonascii .. " 个候选路径含**非 ASCII 字符**。"
            .. "\n  Windows 上 Lua 5.1 的 io.open 用 ANSI 代码页解释路径 ⇒ UTF-8 中文路径"
            .. "\n  **无论存不存在都会报「No such file or directory」**。"
            .. "\n  处置：建一个 ASCII 目录联接，例如（PowerShell）："
            .. "\n    New-Item -ItemType Junction -Path \"<工程根>/dstsrc\" -Target \"<工程根>/02-注释源码\""
    end

    error("找不到 DST 源码根目录（校验文件 components/health.lua 打不开）。\n"
        .. "试过以下路径：\n" .. table.concat(tried, "\n")
        .. "\n\n★ 最可能的原因：**工程根缺 dstsrc 联接**（它是指向 02-注释源码 的 ASCII 联接）。"
        .. "\n  先跑一次环境自检（一条判定 + 自动修复，不会启动 14 个入口）："
        .. "\n    bash <工程根>/tools/preflight.sh --fix"
        .. "\n\n处置：设环境变量 DST_SRC 指向「含 components/prefabs/brains 的那个 scripts 目录」，"
        .. "例如\n  DST_SRC=<工程根>/dstsrc/scripts\n" .. hint, 0)
end

Paths.norm = norm
Paths.dirname = dirname
Paths.collapse = collapse
Paths.is_file = is_file
Paths.has_non_ascii = has_non_ascii

return Paths
