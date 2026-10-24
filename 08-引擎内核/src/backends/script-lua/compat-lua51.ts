/**
 * L5 · Lua 5.1 兼容垫片（跑在 wasmoon / Lua 5.4 上）
 *
 * ★★ 为什么必须有这一层：
 *   运行时是 Lua 5.4（wasmoon 1.16），而内容层（153 万行）是 Lua 5.1。
 *   不是"少几个语法糖"的问题 —— 5.1 的 `module()` / `setfenv()` / `unpack` /
 *   `math.pow` / `loadstring` 在 5.4 里**全被删了**，任何 5.1 模块第一行就炸。
 *   没有这层垫片，`.lua` 资产"能导入但跑不起来"。
 *
 * ★★ 为什么写成 Lua 源码字符串而不是在 TS 里逐个 `engine.global.set(...)`：
 *   ① 每个 API 都要碰 `_ENV`/`debug` 的语义，用 Lua 写才是"就地实现"，用 TS 写要
 *      反复穿过 wasmoon 的调用边界（而且多返回值只保留第一个，见 runtime.ts 文件头）；
 *   ② 垫片整体是一个 chunk，出错时是一处可定位的编译/运行错误；
 *   ③ 它不是业务，也不该被 `expose()` 覆盖成宿主函数。
 *
 * ★★★ setfenv 的实现是这份文件里唯一"有设计"的地方（其余都是别名/补齐）：
 *   Lua 5.4 没有函数级环境，只有 `_ENV` 这个**普通 upvalue**。天真写法
 *   `debug.setupvalue(f, idx, t)` 有一个致命缺陷：`_ENV` upvalue 对象在同一个
 *   chunk 里是**共享**的，改它会把同一 chunk 的所有闭包 —— 连正在执行的调用者
 *   自己 —— 一起换掉。实测：一个 chunk 里 `debug.setupvalue(f, 1, {})` 之后，
 *   `tostring` 立刻变 nil（本文件的探针就是这么发现的）。
 *
 *   所以这里用 `debug.upvaluejoin` 造一个**私有** upvalue 对象：
 *     `holder = load("return _ENV", "=...", "t", t)`  ← 全新闭包，_ENV 是全新 upvalue
 *     `debug.upvaluejoin(f, idx, holder, 1)`           ← 让 f 的 _ENV 指向那个新对象
 *   效果与 5.1 一致：只影响 f 自己，以及 f **之后**新建的内部闭包（它们会捕获同一个
 *   upvalue），不影响 f 的兄弟闭包，也不影响调用者。这正是 5.1 `setfenv` 的语义。
 *   `debug.upvaluejoin` 不可用时退化为 `debug.setupvalue`（会牵连兄弟闭包，见报告）。
 *
 * ★ 已知且**未修**的差异（诚实标注，不粉饰）：
 *   ① `setfenv(level, t)`（数字参数）在 5.4 里没有可靠对应物 —— 明确 `error()`
 *      而不是静默失败。`getfenv(level)` 是只读查询，5.4 用 `debug.getinfo` 能精确
 *      做到，因此**没有**降级（内容层里 `getfenv(1)` 很常见）。
 *   ② 对 C 函数（`print` 之类）调用 `setfenv` 是空操作（5.1 会改它绑定的全局表，
 *      但 C 函数在 5.4 里没有 `_ENV` upvalue）。返回值仍是那个函数，不报错。
 *   ③ `module()` 会往**真正的 `_G`** 写嵌套表（5.1 就这么干），这部分不参与
 *      模块级隔离 —— 它是 5.1 语义里"全局"的本义，见 runtime.ts 的 `__engine_load`。
 *      **但卸载时会摘掉**：`__engine_compat_findtable` 记下"我建了哪几张表"，
 *      `__engine_compat_unmodule` 按**创建时的身份**（`parent[key] == 记录的表`）删除。
 *      身份不匹配就不删 —— 别人后来换掉的、或别人也往里加过东西的容器，一律不动。
 *      这条以前写作"已知且未修"，是 2026-10-23 修掉的：能修的不该留在"已知问题"里。
 *   ④ `require` **不读文件系统**（wasm 里没有 fs）：只查 `package.loaded` 与
 *      `package.preload`。`package.preload` 是引擎注册模块的唯一入口。
 */

/**
 * 兼容垫片源码。由 `LuaScriptRuntime.initEngine()` 在 `BOOTSTRAP` 之后执行一次。
 *
 * 结构：内部工具 → setfenv/getfenv → module/package.seeall/require →
 *       math/table/string 补齐 → 全局别名（unpack/loadstring/arg）。
 * 所有内部函数名以 `__engine_compat_` 开头，避免与内容层的局部/全局撞名。
 */
export const LUA51_COMPAT_SRC: string = String.raw`
-- ============================== 内部工具 ==============================

local __type = type
local __error = error
local __select = select
local __tostring = tostring
local __setmetatable = setmetatable
local __getmetatable = getmetatable
local __rawget = rawget
local __load = load
local __debug = debug

-- 找到函数的 _ENV upvalue 序号；没有（函数不读全局 / 是 C 函数）返回 nil。
-- 注意：5.4 里 _ENV 可能不是 1 号（函数先捕获了别的局部变量），必须按名字找。
local function __engine_compat_envindex(f)
  if __type(f) ~= "function" then return nil end
  local i = 1
  while true do
    local name = __debug.getupvalue(f, i)
    if name == nil then return nil end
    if name == "_ENV" then return i end
    i = i + 1
  end
end

local function __engine_compat_getenv(f)
  local idx = __engine_compat_envindex(f)
  if idx == nil then return nil end
  local _, v = __debug.getupvalue(f, idx)
  if __type(v) ~= "table" then return nil end
  return v
end

local __engine_compat_has_join = __type(__debug.upvaluejoin) == "function"

-- 把 f 的 _ENV 换成 t（私有 upvalue，不牵连兄弟闭包）。返回是否真的换了。
local function __engine_compat_bind(f, t)
  local idx = __engine_compat_envindex(f)
  if idx == nil then
    -- 函数根本没读过全局 ⇒ 没有可观察差异。5.1 会给它 env，但读了才有意义。
    return false
  end
  if __engine_compat_has_join then
    local holder = __load("return _ENV", "=__engine_compat_envholder", "t", t)
    if holder ~= nil then
      __debug.upvaluejoin(f, idx, holder, 1)
      return true
    end
  end
  -- 退化路径：upvaluejoin 不可用。语义仍对，但会牵连同 chunk 的兄弟闭包。
  __debug.setupvalue(f, idx, t)
  return true
end

-- ============================== setfenv / getfenv ==============================

function setfenv(f, t)
  if __type(f) == "number" then
    __error(
      "setfenv: Lua 5.4 无法按栈层号(level=" .. __tostring(f) .. ")设置环境；"
        .. "5.1 的这个用法在 5.4 里没有对应物，请改成传函数本身",
      2
    )
  end
  if __type(f) ~= "function" then
    __error("setfenv: 第一个参数必须是函数（收到 " .. __type(f) .. "）", 2)
  end
  if __type(t) ~= "table" then
    __error("setfenv: 第二个参数必须是 table（收到 " .. __type(t) .. "）", 2)
  end
  __engine_compat_bind(f, t)
  return f
end

function getfenv(f)
  if f == nil then f = 1 end
  if __type(f) == "number" then
    -- 5.1 的 getfenv(level) 只是查询，5.4 能**精确**做到，因此不降级。
    -- +1 是因为 level 1 在 5.1 里指"调用 getfenv 的那个函数"，
    -- 而在 debug.getinfo 里 level 1 是 getfenv 自己。
    local info = __debug.getinfo(f + 1, "f")
    if info == nil or __type(info.func) ~= "function" then return _G end
    return __engine_compat_getenv(info.func) or _G
  end
  if __type(f) ~= "function" then
    __error("getfenv: 参数必须是函数或栈层号（收到 " .. __type(f) .. "）", 2)
  end
  return __engine_compat_getenv(f) or _G
end

-- ============================== module / package.seeall ==============================

-- 在真正的 _G 上建（或复用）点号嵌套的表。5.1 的 findtable 就是往全局表里写。
-- ★ 返回 tbl, created：created 是"本次真正新建的那几张表"的记录（父表 + 键 + 表本身），
--   顺序是**从外到内**，最后一条就是模块自己的那张表。卸载时靠它精确摘除。
--   只记"新建"的：复用的表是别人的，动它就是删别人的数据。
local function __engine_compat_findtable(name)
  local cur = _G
  local created = {}
  for part in string.gmatch(name, "[^.]+") do
    local nxt = cur[part]
    if __type(nxt) ~= "table" then
      nxt = {}
      cur[part] = nxt
      created[#created + 1] = { parent = cur, key = part, value = nxt }
    end
    cur = nxt
  end
  return cur, created
end

-- "模块名的点号路径 → 我建过哪些表"。卸载时按记录反向摘除。
__engine_compat_modtables = {}

-- "当时还不能删的空容器"。例：shared.a 与 shared.b 是两个模块先后建的，
-- 卸 a 时 shared 里还有 b，不能删 —— 但也不能忘，否则 shared 这张空表会永远留在 _G 里。
-- 每次卸载都扫一遍待办，谁变空了就摘谁。
__engine_compat_pending = {}

-- 释放一条"容器"记录：身份还对上、且已经空 ⇒ 摘掉并返回 true；
-- 身份被换掉（别人接管了这个键）⇒ 记录作废，返回 true（不用再管）；
-- 还非空 ⇒ false（转入待办）。
local function __engine_compat_release(e)
  if e.parent[e.key] ~= e.value then return true end
  for _ in pairs(e.value) do return false end
  e.parent[e.key] = nil
  return true
end

-- 摘掉 module() 往真 _G 写的表。规则只有一条：**身份必须还是我建的那张**。
--   · 叶子（模块自己的表）：身份对上就摘，不管里面还有多少函数 —— 那些函数随模块一起作废。
--   · 中间容器（a.b 里的 a）：只有变成空表才摘。别人往 a 里加过东西就留着并转入待办，
--     否则会把别人的模块一起摘掉（这是最容易写错的一步）。
function __engine_compat_unmodule(name)
  if __type(name) ~= "string" then return false end
  local removed = 0
  local rec = __engine_compat_modtables[name]
  if __type(rec) == "table" then
    __engine_compat_modtables[name] = nil
    for i = #rec, 1, -1 do
      local e = rec[i]
      if i == #rec then
        if e.parent[e.key] == e.value then
          e.parent[e.key] = nil
          removed = removed + 1
        end
      elseif not __engine_compat_release(e) then
        __engine_compat_pending[#__engine_compat_pending + 1] = e
      else
        removed = removed + 1
      end
    end
  end
  -- 扫待办：随别的模块卸载，之前非空的容器可能已经空了
  local keep = {}
  for i = 1, #__engine_compat_pending do
    local e = __engine_compat_pending[i]
    if not __engine_compat_release(e) then
      keep[#keep + 1] = e
    else
      removed = removed + 1
    end
  end
  __engine_compat_pending = keep
  return removed > 0
end

function module(name, ...)
  if __type(name) ~= "string" or name == "" then
    __error("module: 模块名必须是非空字符串", 2)
  end

  -- ① 建/取模块表，并登记到 package.loaded
  local mod = package.loaded[name]
  if __type(mod) ~= "table" then
    local created
    mod, created = __engine_compat_findtable(name)
    if #created > 0 then
      local log = __engine_compat_modtables[name]
      if __type(log) ~= "table" then
        log = {}
        __engine_compat_modtables[name] = log
      end
      for i = 1, #created do log[#log + 1] = created[i] end
    end
  end
  package.loaded[name] = mod

  -- ② 取调用者的旧 env（module 之后模块里还要能看见全局，5.1 靠这个兜底链）
  local caller = __debug.getinfo(2, "f")
  local caller_fn = nil
  local caller_env = _G
  if caller ~= nil and __type(caller.func) == "function" then
    caller_fn = caller.func
    caller_env = __engine_compat_getenv(caller_fn) or _G
  end

  -- ③ 先铺默认 __index（链到调用者旧 env ⇒ 最终到 _G），再跑选项覆盖它。
  --    ★ 严格的 5.1 没有这条默认（所以才需要 package.seeall），但缺了它，
  --      任何 module("x") 之后 math/string/engine_* 全部变 nil —— 5.1 生态里
  --      这条默认被视为"本来就该有"。加上它只会让更多内容层跑得起来。
  local mt = __getmetatable(mod)
  if __type(mt) ~= "table" then
    mt = {}
    __setmetatable(mod, mt)
  end
  if mt.__index == nil then mt.__index = caller_env end

  -- ④ 跑选项（package.seeall 等）。5.1 在 setfenv **之前**跑，顺序会影响
  --    __index 的最终值，这里保持一致。
  local n = __select("#", ...)
  for i = 1, n do
    local opt = __select(i, ...)
    if __type(opt) ~= "function" then
      __error("module: 第 " .. __tostring(i + 1) .. " 个参数不是函数（选项应为 package.seeall 之类）", 2)
    end
    opt(mod)
  end

  -- ⑤ 换调用者的 env。5.1 的 setfenv(2, mod) 就是这一步。
  if caller_fn ~= nil then
    __engine_compat_bind(caller_fn, mod)
  end
  return mod
end

function package.seeall(t)
  if __type(t) ~= "table" then
    __error("package.seeall: 需要 table（收到 " .. __type(t) .. "）", 2)
  end
  local mt = __getmetatable(t)
  if __type(mt) ~= "table" then
    __setmetatable(t, { __index = _G })
  else
    mt.__index = _G
  end
end

-- ============================== require ==============================

-- 5.1 语义：package.loaded → package.preload → 报错。
-- ★ 不碰文件系统：wasm 里没有 fs，package.preload 才是引擎注册模块的入口。
function require(name)
  if __type(name) ~= "string" then
    __error("require: 模块名必须是字符串（收到 " .. __type(name) .. "）", 2)
  end

  local loaded = package.loaded[name]
  if loaded ~= nil then return loaded end

  local loader = package.preload[name]
  if loader == nil then
    __error("module '" .. name .. "' not found", 2)
  end
  if __type(loader) ~= "function" then
    __error("module '" .. name .. "': package.preload 里登记的不是函数", 2)
  end

  local r = loader(name)
  if r ~= nil then package.loaded[name] = r end
  local v = package.loaded[name]
  if v == nil then
    v = true
    package.loaded[name] = v
  end
  return v
end

-- ============================== math 补齐 ==============================

function math.pow(x, y) return x ^ y end
math.mod = math.fmod
function math.ldexp(x, e) return x * 2.0 ^ e end
function math.log10(x) return math.log(x, 10) end

-- frexp：x = m * 2^e，要求 0.5 <= |m| < 1（C 库的 frexp 定义）。
-- 用循环而不是位运算：Lua 5.4 的整数/浮点边界比这里需要的精度更容易出错。
function math.frexp(x)
  if x == 0 or x ~= x or x == math.huge or x == -math.huge then return x, 0 end
  local sign = 1
  local m = x
  if m < 0 then sign = -1; m = -m end
  local e = 0
  -- 次数上限：极值/非规格化数下也不会转不出来（每步最多把 |x| 缩一半）
  for _ = 1, 1200 do
    if m >= 1 then m = m / 2; e = e + 1 else break end
  end
  for _ = 1, 1200 do
    if m < 0.5 and m > 0 then m = m * 2; e = e - 1 else break end
  end
  return sign * m, e
end

-- ============================== table / string 补齐 ==============================

function table.getn(t) return #t end
function table.setn()
  __error("table.setn 在 Lua 5.1 已废弃（表长度由 # 决定），5.4 没有对应实现", 2)
end

string.gfind = string.gmatch

-- ============================== 全局别名 ==============================

unpack = table.unpack

-- 5.1 的 loadstring 与 5.4 的 load 返回值形状一致（成功 fn / 失败 nil, err），
-- 差别只在"默认 env"：5.1 用**全局表**，这里不传第 4 个参数即同一行为。
-- 也正因如此，loadstring 出来的 chunk 看不见调用它的模块 env —— 与 5.1 一致。
function loadstring(s, chunkname)
  if __type(s) ~= "string" then
    return nil, "bad argument #1 to 'loadstring' (string expected, got " .. __type(s) .. ")"
  end
  return __load(s, chunkname or s, "t")
end

-- 5.1 的启动参数表。wasm 里没有 argv，但内容层会读 arg[0]/arg[1]（拿到 nil 就行）。
if __rawget(_G, "arg") == nil then _G.arg = {} end
`;
