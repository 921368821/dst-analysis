--[[
==============================================================================
 21_bit.lua —— 补上 DST 依赖的 `bit` 位运算库

 为什么需要
   DST 的 Lua 侧大量使用 `bit.band` / `bit.bor` / `bit.lshift` / `bit.rshift` /
   `bit.bxor` / `bit.bnot`，全库 **120 个调用点**：
       bit.band   x49     bit.bor    x34     bit.lshift x23
       bit.rshift  x9     bit.bxor    x4     bit.bnot    x1
   且 components/health.lua:648 的注释明说：
       「bit.bor 是 DST 注入的位运算库提供的」
   而宿主**从未提供过这个全局** —— 探针实测 `rawget(_G, "bit") == nil`。
   任何走到这些行的代码都会 `attempt to index global 'bit' (a nil value)`。

 ★ 为什么以前没暴露
   这些调用大多在**条件分支深处**（月光灼烧标志归约、农场养分打包、
   谜题编码 …），常规入口不一定够到；而 pcall 又把它们吞成「加载失败」
   或静默跳过。属于「不报错但功能缺失」那一类。

 实现要点
   · Lua 5.1 没有位运算符（`~`/`&`/`|` 是 5.3+），所以用**逐位算术**：
     每次取两数的最低位（`% 2`），右移一位（`math.floor(v/2)`），
     位权翻倍。循环次数 = 最高有效位的位置，不是固定 32 次。
   · 语义对齐 LuaBitOp（DST 实际用的就是它）：
       - 入参按 **32 位无符号**归一（`v % 2^32`，负数经 Lua 的 `%` 变正）
       - 返回值转成 **有符号 32 位**（≥2^31 时减 2^32），
         这样 `bit.bnot(0) == -1`、`bit.band(-1, 0xFF) == 255`
       - `lshift`/`rshift` 是**逻辑**移位；位移数为负时反向
       - `band`/`bor`/`bxor` 支持变参（从左折叠）
   · 数值安全：中间值最大 2^32-1，乘 2^n 最大 2^63 —— 超出双精度 2^53 精确上限！
     ⚠️ 所以 `lshift` 必须**逐位推进**而不是 `a * 2^n`，否则大位移会丢精度。
     本实现用「每次左移一位、位权乘 2」的方式，中间值始终 < 2^32，安全。
==============================================================================
]]

local M = {}

local TWO32 = 4294967296        -- 2^32
local SIGNBIT = 2147483648      -- 2^31

--- 归一成 [0, 2^32) 的无符号 32 位
local function norm(v)
    if type(v) ~= "number" then return 0 end
    if v ~= v then return 0 end            -- NaN
    v = math.floor(v)
    v = v % TWO32
    if v < 0 then v = v + TWO32 end
    return v
end

--- 转成 LuaBitOp 的有符号 32 位返回
local function signed(v)
    if v >= SIGNBIT then return v - TWO32 end
    return v
end

--- 两操作数的逐位归约。f(la, lb) -> 0/1
local function fold2(a, b, f)
    local r, w = 0, 1
    while a > 0 or b > 0 do
        if f(a % 2, b % 2) == 1 then r = r + w end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        w = w * 2
    end
    return r
end

--- 单操作数的逐位取反（32 位全覆盖）
local function not1(a)
    local r, w = 0, 1
    while w < TWO32 do
        if a % 2 == 0 then r = r + w end
        a = math.floor(a / 2)
        w = w * 2
    end
    return r
end

--- 变参折叠
-- ⚠️ 不能加「r 变 0 就提前返回」的优化：那只对 band 成立。
--    bor(0,0,5) 和 bxor(0,0,5) 都应该是 5，提前退出会算错。
--    变参调用本来就少，不值得为它冒险。
local function foldN(args, core)
    if #args == 0 then return 0 end
    local r = norm(args[1])
    for i = 2, #args do
        r = core(r, norm(args[i]))
    end
    return signed(r)
end

local band2 = function(a, b) return fold2(a, b, function(x, y)
    return (x == 1 and y == 1) and 1 or 0
end) end
local bor2 = function(a, b) return fold2(a, b, function(x, y)
    return (x == 1 or y == 1) and 1 or 0
end) end
local bxor2 = function(a, b) return fold2(a, b, function(x, y)
    return (x ~= y) and 1 or 0
end) end

function M.band(a, b, ...)  return foldN({ a, b, ... }, band2) end
function M.bor(a, b, ...)   return foldN({ a, b, ... }, bor2) end
function M.bxor(a, b, ...)  return foldN({ a, b, ... }, bxor2) end
function M.bnot(a)          return signed(not1(norm(a))) end

--- 逻辑左移：逐位推进，中间值始终 < 2^32（避免 a*2^n 的精度问题）
-- ⚠️ lshift1 与 rshift1 互相递归（负位移时转向对方），必须**前向声明** ——
--    Lua 的 `local function` 是「定义处才生效」，不加这句，
--    先定义的那个闭包会把对方解析成全局（nil），调用即炸。
local lshift1, rshift1

lshift1 = function(a, n)
    a = norm(a)
    n = math.floor(n or 0)
    if n < 0 then return rshift1(a, -n) end
    if n >= 32 then return 0 end
    local w = 1
    for _ = 1, n do
        w = w * 2
        if w >= TWO32 then return 0 end
    end
    -- 现在 w = 2^n；把 a 的每一位搬到高位
    local r, bit = 0, w
    while a > 0 do
        if a % 2 == 1 then r = r + bit end
        a = math.floor(a / 2)
        bit = bit * 2
        if bit >= TWO32 then break end
    end
    return r
end

--- 逻辑右移
rshift1 = function(a, n)
    a = norm(a)
    n = math.floor(n or 0)
    if n < 0 then return lshift1(a, -n) end
    if n >= 32 then return 0 end
    for _ = 1, n do a = math.floor(a / 2) end
    return a
end

function M.lshift(a, n) return signed(lshift1(a, n)) end
function M.rshift(a, n) return signed(rshift1(a, n)) end

-- 便捷别名（LuaBitOp 也有）
function M.arshift(a, n)
    a = norm(a)
    local neg = a >= SIGNBIT
    local r = rshift1(a, n)
    if neg and n > 0 and n < 32 then
        -- 补符号位
        local w = 1
        for _ = 1, n do w = w * 2 end
        r = r + (TWO32 - w)
    end
    return signed(r)
end

function M.bswap(a)
    a = norm(a)
    local r = 0
    for i = 0, 3 do
        r = r * 256 + (math.floor(a / 256^i) % 256)
    end
    return signed(r)
end

function M.rol(a, n)
    a = norm(a); n = math.floor(n or 0) % 32
    return signed(bor2(lshift1(a, n), rshift1(a, 32 - n)))
end
function M.ror(a, n)
    a = norm(a); n = math.floor(n or 0) % 32
    return signed(bor2(rshift1(a, n), lshift1(a, 32 - n)))
end

function M.tohex(v, n)
    v = norm(v)
    n = math.floor(n or 8)
    if n <= 0 then return "" end
    if n > 8 then n = 8 end
    local digits = "0123456789abcdef"
    local out = {}
    for _ = 1, n do
        out[#out + 1] = digits:sub(v % 16 + 1, v % 16 + 1)
        v = math.floor(v / 16)
    end
    local s = table.concat(out)
    return s:reverse()
end

return M
