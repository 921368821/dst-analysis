--[[
==============================================================================
 07_universal.lua —— 万能兜底全局对象

 问题
   玩家预制体（player_common.lua 2986 行）会引用几十个宿主未定义的全局，
   逐个补会被「连锁式缺一个」拖死（实测连踩 GetGhostEnabled 等十几次）。

 做法
   给一个对象挂全套 metamethod：__call / __add / __sub / __mul / __div /
   __eq / __lt / __concat / __index / __tostring。它既能当函数调用，
   又能参与算术与比较 —— 无论原版怎么用它都不会炸。

 ★ 诚实性保证
   每次访问都会被记录（Core.NoteStub），缺口清单里能查到「哪些全局
   是兜底提供的」。这不会静默掩盖问题，只是把「崩溃」换成「可观测的宽松行为」。

 何时启用
   只在明确开启时（Bootstrap.Setup{universal_globals = true}）。
   默认关闭，避免掩盖真正的接口缺失。
==============================================================================
]]

local M = {}

local UniversalMeta = {}

--- 通用的「什么都能做」的值
local function make_universal(name)
    local u = setmetatable({ _univ_name = name }, UniversalMeta)
    return u
end

M.make = make_universal

-- __index：链式兜底，u.foo 也返回一个万能对象（而不是 nil）
UniversalMeta.__index = function(t, k)
    if type(k) ~= "string" or k:match("^__") or k:match("^_") then return nil end
    return make_universal(t._univ_name .. "." .. k)
end

-- 当函数调用：返回 nil（调用方通常有 nil 分支）
UniversalMeta.__call = function(self, ...)
    local Core = rawget(_G, "__CoreRef")
    if Core then Core.NoteStub("global:" .. self._univ_name, "universal-global") end
    return nil
end

-- 算术：与数字运算时把 self 当 0
local function asnum(v)
    if type(v) == "number" then return v end
    return 0
end
UniversalMeta.__add = function(a, b) return asnum(a) + asnum(b) end
UniversalMeta.__sub = function(a, b) return asnum(a) - asnum(b) end
UniversalMeta.__mul = function(a, b) return asnum(a) * asnum(b) end
UniversalMeta.__div = function(a, b)
    local d = asnum(b)
    if d == 0 then return 0 end
    return asnum(a) / d
end
UniversalMeta.__mod = function(a, b)
    local d = asnum(b)
    if d == 0 then return 0 end
    return asnum(a) % d
end
UniversalMeta.__unm = function(a) return -asnum(a) end
UniversalMeta.__pow = function(a, b) return asnum(a) ^ asnum(b) end

UniversalMeta.__eq = function(a, b) return rawequal(a, b) end
UniversalMeta.__lt = function(a, b) return asnum(a) < asnum(b) end
UniversalMeta.__le = function(a, b) return asnum(a) <= asnum(b) end
UniversalMeta.__concat = function(a, b) return tostring(a) .. tostring(b) end
UniversalMeta.__len = function() return 0 end
UniversalMeta.__tostring = function() return "[univ]" end

--- 在 _G 上装兜底：未知全局返回一个万能对象
--- @param Core  Core 模块（用于记录缺口）
function M.Install(Core)
    _G.__CoreRef = Core
    local seen = {}

    local mt = {
        __index = function(t, k)
            if type(k) ~= "string" or k:match("^_") then return nil end
            -- 原生 Lua 全局优先
            if rawget(t, k) ~= nil then return rawget(t, k) end
            seen[k] = true
            Core.NoteStub("global:" .. k, "universal-global")
            return make_universal(k)
        end,
    }

    setmetatable(_G, mt)
    M._meta = mt
    M._seen = seen
    return mt
end

function M.Uninstall()
    setmetatable(_G, nil)
    M._meta = nil
end

--- 列出所有被兜底提供的全局（供报告）
function M.List()
    local keys = {}
    for k in pairs(M._seen or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

return M
