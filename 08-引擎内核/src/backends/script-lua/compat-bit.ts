/**
 * L5 · 脚本后端：`bit` —— LuaJIT 的 32 位位运算库（DST 内容层当标准库用）
 *
 * ★ 为什么这不是「5.1 兼容垫片」的一部分，却又要装在那一层：
 *   `bit` **不是** Lua 5.1 标准库，它是 LuaJIT 扩展。DST 的内容层是跑在 LuaJIT 上的，
 *   于是 `bit.band` / `bit.bor` / `bit.lshift` 在 153 万行里被当成标准库用（实测
 *   `bit.band` 55 处、`bit.bor` 38 处、`bit.lshift` 27 处）。wasmoon 是 Lua 5.4，
 *   既没有 LuaJIT 也没有 5.2 的 `bit32`（5.3 起移除了）。
 *   把它单独成文件，是为了让「5.1 标准 API」与「LuaJIT 扩展」这两件事在看代码时
 *   依然分得开 —— 混进 `compat-lua51.ts` 之后，下一个人会以为 5.1 本来就有 `bit`。
 *
 * ★ 语义按 **32 位补码**，不是 Lua 5.4 的 64 位整数：
 *   5.4 的 `& | ~ << >>` 全是 64 位且 `>>` 是**逻辑**移位，而 LuaJIT 的 `bit.*`
 *   一律 32 位、返回值是**有符号** 32 位整数（`bit.band(0xFFFFFFFF, 0xFFFFFFFF)`
 *   要得到 `-1`，不是 `4294967295`）。直接把 5.4 的原生运算暴露出去，得到的是
 *   「看起来能跑、数值全错」——这是最坏的一种兼容（内容层不会报错，只是算错）。
 *
 * ★ 有争议的地方一律**定义清楚、不假装与 LuaJIT 逐位一致**：
 *   · `bit.band()` / `bit.bor()` / `bit.bxor()` 无参时返回各自的单位元（-1 / 0 / 0）；
 *   · `bit.tohex(x, n)` 的 `|n|` 是**低** `|n|` 位（`tohex(0x12345678, 4)` = `5678`），
 *     `n < 0` 出大写；`|n| = 0` 出空串；
 *   · 位移量按 `& 31` 掩码（`lshift(1, 32)` = `lshift(1, 0)` = 1），这条是 LuaJIT 的行为。
 *   这些都在 `tests/backends/script-bit.test.ts` 里钉成判据 —— 判据定了，实现才有意义。
 *
 * ★ 正确性的**外部**对照物：Lua 5.4 自己的原生位运算。`bit.band(a, b)` 必须等于
 *   `tobit(a & b)`，`bit.rshift` 必须等于 `tobit((a & 0xFFFFFFFF) >> n)`。
 *   判据里对一批取值做交叉验证：自己跟自己对不算验证。
 *
 * 安装：`LuaScriptRuntime.initEngine()` 在 `LUA51_COMPAT_SRC` 之后执行一次，
 * 并把 `bit` 及其函数名加进 `COMPAT_PROBE_SRC` 自检（静默装失败的话，错误会推迟到
 * 第一个用到 `bit` 的内容层文件，报错点离根因很远）。
 */

export const LUA_BIT_SRC: string = String.raw`
local __type = type
local __error = error
local __select = select
local __format = string.format
local __sub = string.sub
local __upper = string.upper
local __abs = math.abs
local __floor = math.floor

local TWO32 = 4294967296
local TWO31 = 2147483648

-- 规范成有符号 32 位（-2^31 .. 2^31-1）。这是整个库的地基：
-- 只在这一处做符号解释，别的函数一律先 tobit 再用 5.4 的原生整数运算。
local function tobit(x)
  if __type(x) ~= "number" then
    __error("bit: 参数必须是数字（收到 " .. __type(x) .. "）", 3)
  end
  local n = __floor(x) % TWO32
  if n >= TWO31 then n = n - TWO32 end
  return n
end

-- 规范成无符号 32 位（0 .. 2^32-1）。逻辑右移与 tohex 需要这个视角。
local function u32(x)
  if __type(x) ~= "number" then
    __error("bit: 参数必须是数字（收到 " .. __type(x) .. "）", 3)
  end
  return __floor(x) % TWO32
end

local M = {}

function M.tobit(x) return tobit(x) end

-- 三个变参函数：从**第二个**参数起才累加，所以第一个必须先单独取。
-- 无参是单位元（-1 / 0 / 0）：这样 band(x) == x、bor() == 0，与「空集合的与/或」一致。
function M.band(...)
  local n = __select("#", ...)
  if n == 0 then return -1 end
  local r = tobit((__select(1, ...)))
  for i = 2, n do r = r & tobit((__select(i, ...))) end
  return r
end

function M.bor(...)
  local n = __select("#", ...)
  if n == 0 then return 0 end
  local r = tobit((__select(1, ...)))
  for i = 2, n do r = r | tobit((__select(i, ...))) end
  return r
end

function M.bxor(...)
  local n = __select("#", ...)
  if n == 0 then return 0 end
  local r = tobit((__select(1, ...)))
  for i = 2, n do r = r ~ tobit((__select(i, ...))) end
  return r
end

function M.bnot(x) return ~tobit(x) end

-- 位移量按 & 31 掩码：LuaJIT 就是这么做的（lshift(1, 32) == 1，不是 0）。
function M.lshift(x, n)
  n = tobit(n) & 31
  return tobit((u32(x) << n) % TWO32)
end

function M.rshift(x, n)
  n = tobit(n) & 31
  return tobit(u32(x) >> n)
end

-- 算术右移：负数的高位补 1。用 // 而不是 >>（5.4 的 >> 是逻辑移位，
-- 对负数会得到 2147483644 这种明显错的答案 —— 见 M858/M859 两条变异）。
function M.arshift(x, n)
  n = tobit(n) & 31
  local v = tobit(x)
  if n == 0 then return v end
  return tobit(v // (1 << n))
end

function M.rol(x, n)
  n = tobit(n) & 31
  local u = u32(x)
  if n == 0 then return tobit(u) end
  return tobit(((u << n) | (u >> (32 - n))) % TWO32)
end

function M.ror(x, n)
  n = tobit(n) & 31
  local u = u32(x)
  if n == 0 then return tobit(u) end
  return tobit(((u >> n) | (u << (32 - n))) % TWO32)
end

function M.bswap(x)
  local u = u32(x)
  local b0 = u & 0xFF
  local b1 = (u >> 8) & 0xFF
  local b2 = (u >> 16) & 0xFF
  local b3 = (u >> 24) & 0xFF
  return tobit((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
end

function M.tohex(x, n)
  local s = __format("%08x", u32(x))
  if n == nil then return s end
  local wid = __floor(__abs(n))
  if wid >= 1 and wid < 8 then
    s = __sub(s, 9 - wid)
  elseif wid >= 8 then
    -- 保持不变：u32 最多 8 位十六进制
  else
    s = ""
  end
  if n < 0 then return __upper(s) end
  return s
end

rawset(_G, "bit", M)
`;
