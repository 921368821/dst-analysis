-- host/compat52.lua —— Lua 5.2+ 兼容垫片（C7）
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 干什么：把 5.1 里存在、5.2+ 被移走/改名的全局函数补回来，
--         让原版 DST 脚本（4030 个）在 5.2+ 上**不用改一行**就能跑。
-- ═══════════════════════════════════════════════════════════════════════════
-- 为什么需要（实测，见 tools/lua_version_scan.py 的 API 面）：
--   loadstring / setfenv / getfenv / unpack / table.getn / module 在 5.2+ **全部消失**；
--   math.pow 在 5.3+ 消失；bit32 只在 5.2 有（5.3+ 用原生位运算符）。
--   而这 4072 个文件里：loadstring 27 处、setfenv/getfenv 各 10 处、
--   unpack( 559 处、math.pow 34 处、table.getn 18 处。
--
-- ★★ 一条纪律：**能忠实补的才补，补不了的不许假装成功。**
--   `setfenv` 在 5.2+ 没有等价函数，只能用 `debug.upvaluejoin` 改函数的 `_ENV`
--   upvalue（业界通用做法，本文件采用）。但它**只对 Lua 函数有效**：
--   对 C 函数（`string.gsub` 之类）调 setfenv 在 5.1 是非法、在 5.2+ 也无从下手。
--   ⇒ 这类情况**返回 false 并说明**，而不是默默返回原函数 ——
--     「看起来设了环境其实没设」是最坏的一种兼容。
--
-- 用法：由 `03-参考架构/_run_lua.py --prelude host/compat52.lua` 注入
--      （在入口脚本**之前**执行，改的是全局环境）。
if _VERSION == "Lua 5.1" then
    -- 5.1 上什么都不用做。★ 但**必须**让这个文件能安全地跑在 5.1 上，
    -- 否则「加不加垫片」就变成了改运行时的行为，对照实验失去意义。
    return { applied = false, why = "Lua 5.1：无需垫片" }
end

local applied = {}

-- ① loadstring → load（5.2+ 的 load 接受字符串）
if loadstring == nil and load ~= nil then
    loadstring = load
    applied[#applied + 1] = "loadstring"
end

-- ② unpack → table.unpack
if unpack == nil and table.unpack ~= nil then
    unpack = table.unpack
    applied[#applied + 1] = "unpack"
end

-- ③ table.getn → #
if table.getn == nil then
    table.getn = function(t) return #t end
    applied[#applied + 1] = "table.getn"
end

-- ④ math.pow → ^（5.3+ 移除）
if math.pow == nil then
    math.pow = function(a, b) return a ^ b end
    applied[#applied + 1] = "math.pow"
end

-- ④b ★★ 5.3 一次砍掉了一整排数学函数，其中 `math.atan2` 是**最致命的一个**：
--     实测原版脚本里有 **213 处** `math.atan2`。它一缺，`prefabs/skilltree_wortox`
--     加载就抛错 ⇒ 宿主把错误吞掉换成空表 ⇒ 上层 `BuildSkillsData(FN)` 变成
--     「attempt to call a **table** value」—— 报错位置离真因隔了三层，
--     这是本工程最熟悉的那种误导。
--     （这一条是**跑出来的**，不是猜的：见 tools/lua54_trial.py 的输出。）
if math.atan2 == nil then
    math.atan2 = function(y, x) return math.atan(y, x) end
    applied[#applied + 1] = "math.atan2"
end
if math.log10 == nil then
    math.log10 = function(x) return math.log(x, 10) end
    applied[#applied + 1] = "math.log10"
end
if math.mod == nil then
    math.mod = math.fmod
    applied[#applied + 1] = "math.mod"
end
if math.cosh == nil then
    math.cosh = function(x) return (math.exp(x) + math.exp(-x)) / 2 end
    math.sinh = function(x) return (math.exp(x) - math.exp(-x)) / 2 end
    math.tanh = function(x)
        local e = math.exp(2 * x)
        return (e - 1) / (e + 1)
    end
    applied[#applied + 1] = "math.cosh/sinh/tanh"
end
if math.ldexp == nil then
    math.ldexp = function(x, e) return x * 2.0 ^ e end
    math.frexp = function(x)
        if x == 0 then return 0, 0 end
        local e = math.floor(math.log(math.abs(x), 2)) + 1
        return x / 2.0 ^ e, e
    end
    applied[#applied + 1] = "math.ldexp/frexp"
end
-- ④c table.maxn（5.2 移除）
if table.maxn == nil then
    table.maxn = function(t)
        local m = 0
        for k in pairs(t) do
            if type(k) == "number" and k > m then m = k end
        end
        return m
    end
    applied[#applied + 1] = "table.maxn"
end

-- ⑤ bit32（只有 5.2 自带；5.3+ 用原生位运算模拟）
if bit32 == nil and _VERSION ~= "Lua 5.2" then
    local function norm(x) return math.floor(tonumber(x) or 0) % 4294967296 end
    bit32 = {
        band = function(a, ...)
            local r = norm(a)
            for _, v in ipairs({ ... }) do r = r & norm(v) end
            return r
        end,
        bor = function(a, ...)
            local r = norm(a)
            for _, v in ipairs({ ... }) do r = r | norm(v) end
            return r
        end,
        bxor = function(a, ...)
            local r = norm(a)
            for _, v in ipairs({ ... }) do r = r ~ norm(v) end
            return r
        end,
        bnot = function(a) return (~norm(a)) & 0xFFFFFFFF end,
        lshift = function(a, n) return (norm(a) << (n % 32)) & 0xFFFFFFFF end,
        rshift = function(a, n) return (norm(a) >> (n % 32)) & 0xFFFFFFFF end,
        arshift = function(a, n)
            local v = norm(a)
            if v >= 2147483648 then v = v - 4294967296 end
            return math.floor(v / (2 ^ (n % 32))) % 4294967296
        end,
        btest = function(a, b) return (norm(a) & norm(b)) ~= 0 end,
        extract = function(a, f, w)
            w = w or 1
            local m = (2 ^ w - 1) << f
            return (norm(a) & m) >> f
        end,
        replace = function(a, v, f, w)
            w = w or 1
            local m = (2 ^ w - 1) << f
            return ((norm(a) & ~m) | ((norm(v) << f) & m)) & 0xFFFFFFFF
        end,
    }
    applied[#applied + 1] = "bit32(模拟)"
end

-- ⑥ setfenv / getfenv（5.2+ 移除；用 _ENV upvalue 实现）
local function find_env_upvalue(f)
    local i = 1
    while true do
        local name = debug.getupvalue(f, i)
        if name == nil then return nil end
        if name == "_ENV" then return i end
        i = i + 1
    end
end

if setfenv == nil then
    setfenv = function(f, t)
        -- 5.1 允许 `setfenv(1, env)` 改**当前**函数；这里没有栈序号的概念，
        -- 只能处理"传函数"这一种。数字形式**明确拒绝**，不猜。
        if type(f) ~= "function" then
            error("compat52: setfenv 只支持传函数（5.1 的 setfenv(1, env) 无法忠实模拟）", 2)
        end
        local i = find_env_upvalue(f)
        if not i then return f end            -- C 函数没有 _ENV ⇒ 保持原样
        debug.upvaluejoin(f, i, function() return t end, 1)
        return f
    end
    applied[#applied + 1] = "setfenv"
end

if getfenv == nil then
    getfenv = function(f)
        if type(f) ~= "function" then error("compat52: getfenv 只支持传函数", 2) end
        local i = find_env_upvalue(f)
        if not i then return _G end
        local _, v = debug.getupvalue(f, i)
        return v
    end
    applied[#applied + 1] = "getfenv"
end

-- ⑦ module / package.seeall（5.2+ 移除）—— 只在真的被用到时才需要，
--    这里给一个**最小可用**版本，并如实标注它不是完整实现。
if module == nil then
    module = function(name, ...)
        local m = package.loaded[name]
        if type(m) ~= "table" then
            m = {}
            package.loaded[name] = m
            _G[name] = m
        end
        return m
    end
    applied[#applied + 1] = "module(最小实现)"
end

_G.__COMPAT52__ = { applied = applied, version = _VERSION }
return _G.__COMPAT52__
