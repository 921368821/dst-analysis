--[[
==============================================================================
 31_filelist.lua —— 跨平台列目录（`*.lua` 文件名）

 为什么单独成一个模块（M6）
   宿主里原本有**三处**各自 `io.popen('dir /b ...')`：
     · `host/05_bootstrap.lua`  （behaviours 预加载 + prefab 索引）
     · `full.lua`               （全量注册）
     · `reachability.lua`       （抽样入口）
   `dir /b` 是 cmd.exe 专有命令：在没有 cmd 的环境（WSL / 容器 / 非 Windows CI）
   里必然拿到空列表 —— 而这些调用点的失败方式是**静默少加载**，
   症状会跑到「某个 brain 的行为类是 nil」那种离病因很远的地方。

 三路策略（越靠前越可移植）
   ① `$DST_FILELIST/<目录名>.txt`：Python 侧 `os.listdir` 写出的清单
      （`07/rt/server.py` 的 `Sim.boot()` 会准备；不依赖任何 shell）；
   ② POSIX `ls -1`（容器 / WSL / macOS）；
   ③ Windows `dir /b`（本机开发，保持原行为）。
   三路都拿不到 ⇒ 返回空表，调用方必须自己 `NoteGap`/打印，**不许静默**。
==============================================================================
]]

local M = {}

--- 列出 `dir` 下的 `*.lua` 文件名（只要文件名，不含路径）。
--- @return table names, string source   source ∈ {"filelist","ls","dir","none"}
function M.List(dir)
    local names = {}
    local function push(name)
        if name ~= nil then
            name = name:gsub("%s+$", "")
            if name:match("%.lua$") then names[#names + 1] = name end
        end
    end

    -- ① Python 提供的清单
    local mfdir = os.getenv("DST_FILELIST")
    if mfdir ~= nil and mfdir ~= "" then
        local base = dir:match("([^/\\]+)$") or "list"
        local f = io.open(mfdir .. "/" .. base .. ".txt", "r")
        if f ~= nil then
            for line in f:lines() do push(line) end
            f:close()
            if #names > 0 then return names, "filelist" end
        end
    end

    -- ② / ③ 平台命令
    local sep = package.config:sub(1, 1)
    local cmd
    if sep == "\\" then
        cmd = 'dir /b "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul'
    else
        cmd = 'ls -1 "' .. dir .. '" 2>/dev/null'
    end
    local f = io.popen(cmd)
    if f ~= nil then
        for line in f:lines() do push(line) end
        f:close()
    end
    return names, (#names > 0) and ((sep == "\\") and "dir" or "ls") or "none"
end

return M
