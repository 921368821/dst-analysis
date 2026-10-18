--[[
==============================================================================
 12_netvars.lua —— 网络变量层（补 C++ 的那一侧）

 为什么需要这个文件
   真实 DST 里 `net_bool / net_float / net_entity / ...` **一行 Lua 实现都没有**。
   我核实过：scripts/netvars.lua 全文件只有注释，grep 不到任何
   `function net_bool` 或 `net_bool =` —— 它们是 C++ 侧
   （luanetworkvariable.cpp）注册进 Lua 的全局函数。

   宿主此前把它们做成「返回 nil 的哑桩」。这在「只加载、不联网」阶段看不出问题，
   但一旦有真实代码去**读** netvar，哑桩立刻暴露：

     · components/combat_replica.lua:724
           target:GetPosition().y <= self._attackrange:value()
       _attackrange 是 net_float → 哑桩返回 nil → `number <= nil` 直接抛错。
     · components/combat.lua:578  Combat:IsValidTarget → replica 的判定链断在这里，
       于是 `Combat:SetTarget(player)` 永远设不上目标 —— 生物一个都追不起来。

   所以这一层不是「顺手补个桩」，而是「让服务端真组件与 replica 之间的
   那条数据通道重新有值」的必需件。

 本文件实现什么 / 不实现什么
   ✔ 实现：netvar 的**本地值语义**（set / value / set_local / dirty / push）
           —— 单机无网时，netvar 退化成「一个带脏事件的值容器」，
              这正是它在真实引擎里对服务端自己的表现。
   ✔ 实现：set() 仅在值**真的变化**时派发脏事件（netvars.lua:100-113 的核心契约）。
   ✔ 实现：net_event 直接复用**真实** netvars.lua 里的 Lua 实现
           （它只是 net_bool 的语法糖，构造函数与 push 都是纯 Lua）。
   ✘ 不实现：真正的序列化 / 增量同步 / 客户端预测回正 —— 宿主没有网络层，
           也没有「另一端」需要同步。凡是依赖这些的部分都会明确记录为桩。

 关键契约（来自 scripts/netvars.lua 的注释与全树调用实测）
   net_X(guid, name, [dirtyevent]) -> netvar
   netvar:value()        读当前值
   netvar:set(v)         权威写：值真变时派发脏事件
   netvar:set_local(v)  本地写：不派发脏事件（客户端预测入口）
   net_event:push()      一次性触发（内部 set_local(true) + set(true)）
==============================================================================
]]

local Core = require("host.01_core")

local M = {}

--=========================================================================
-- 1) netvar 对象
--=========================================================================
-- 真实 C++ 侧为每个 netvar 保存「上一帧的值」以便做脏值检测（内存换带宽）。
-- 宿主同样保存 _v，只在变化时才推事件 —— 语义与 netvars.lua:100-113 一致。
local function push_dirty(guid, event)
    if type(event) ~= "string" then return end
    local inst = Core.Spawned[guid]
    if inst ~= nil and type(inst.PushEvent) == "function" then
        pcall(inst.PushEvent, inst, event)
    end
end

--- 创建一个 netvar。typname 只用于记录与报错，值语义各类型一致
--- （真实引擎里差异在**线格式宽度**上：net_tinybyte 只有 3 位，
---   net_float 是 32 位浮点 —— 宿主无网络，宽度差异不影响计算结果）。
local function new_netvar(typname, guid, name, dirtyevent, default)
    local nv = {
        _type  = typname,
        _guid  = guid,
        _name  = name,
        _dirty = dirtyevent,
        _v     = default,
    }

    function nv:value() return self._v end

    -- ★ 唯一的「权威写」入口。脏事件**只在值真的变了时**才触发。
    --   （netvars.lua:100-113：每帧无条件广播会让带宽爆炸；
    --     脏值检测让「静止不动」的成本降到接近零。）
    function nv:set(v)
        if v ~= self._v then
            self._v = v
            push_dirty(self._guid, self._dirty)
        end
    end

    -- ★ 「本地写」：不触发同步、不触发脏事件。客户端预测的唯一入口。
    function nv:set_local(v) self._v = v end

    function nv:get() return self._v end

    -- net_event:push 会用到（见下面用真实实现覆盖的部分）
    function nv:push()
        if self._dirty ~= nil then
            self._v = true
            push_dirty(self._guid, self._dirty)
        end
    end

    function nv:dirty() return false end

    -- ↓ 以下都是真实引擎里 C++ 侧的「同步调参」接口。
    --   宿主的模拟是同步的，没有插值/平滑/归属权可调，因此都是无副作用的记录。
    function nv:set_owner(o) self._owner = o end
    function nv:get_owner() return self._owner end
    function nv:set_range(a, b) self._range = { a, b } end
    function nv:set_time(t) self._time = t end
    function nv:set_playforward(b) self._playforward = b end
    function nv:set_position_smoothing(f) self._smoothing = f end
    function nv:set_interpolation(f) self._interp = f end

    return nv
end

--=========================================================================
-- 2) 全局 net_* 工厂
--=========================================================================
-- 真实引擎注册的类型（scripts/netvars.lua:44-60 的类型表）。
-- 逐个登记，而不是写一个万能兜底 —— 这样「用到了没登记的类型」能被 GAPS 抓到。
local NET_TYPES = {
    "net_bool", "net_tinybyte", "net_smallbyte", "net_byte",
    "net_uint", "net_int", "net_ushortint", "net_shortint",
    "net_uint64", "net_int64",
    "net_float", "net_string", "net_hash", "net_entity",
    "net_bytearray", "net_smallbytearray", "net_entityarray",
    "net_ushortarray", "net_uint16", "net_uint32",
}

local installed = {}

-- ★★ 每种 netvar 的**默认初值**：不传 default 时用它，而不是 nil。
--
--   为什么必须补：真实引擎的 net_* 是 C++ 实现，**不传 default 时给类型的零值**。
--   宿主原来直接传 nil ⇒ 未显式设过初值的 netvar 读出来就是 nil，
--   而调用点会拿它做运算 ⇒ 报「arithmetic on nil / compare nil with number」。
--
--   实测症状（300 抽样里 2 个）：
--     `prefabs/fireflies.lua:71`  resolvefaderate(inst._faderate:value())
--         → `x < 32` where x is nil ⇒ `attempt to compare nil with number`
--     `components/colouraddersync.lua:5`  self.colour:value() → 拆字节时 nil 运算
--
--   ⇒ 数值型给 0、布尔给 false、字符串给 ""、entity 给 nil（实体确实可以没有）。
local NET_DEFAULTS = {
    net_bool = false,
    net_string = "",
    net_hash = 0,
    net_entity = nil,          -- 实体可以真的没有
}
for _, t in ipairs({ "net_tinybyte", "net_smallbyte", "net_byte",
                     "net_uint", "net_int", "net_ushortint", "net_shortint",
                     "net_uint64", "net_int64", "net_float",
                     "net_uint16", "net_uint32" }) do
    NET_DEFAULTS[t] = 0
end

for _, tname in ipairs(NET_TYPES) do
    _G[tname] = function(guid, name, dirtyevent, default)
        if default == nil then default = NET_DEFAULTS[tname] end
        return new_netvar(tname, guid, name, dirtyevent, default)
    end
    installed[tname] = true
end

--=========================================================================
-- 3) net_event —— 直接用**真实** netvars.lua 的 Lua 实现
--=========================================================================
-- netvars.lua 里唯一有实现的部分就是 net_event（Class 构造 + push）。
-- 它只依赖 net_bool，而 net_bool 现在已由本文件提供 —— 所以可以真加载。
-- ★ 注意它 `require("class")`：宿主已把真实 class.lua 装成全局 Class，
--   但 require("class") 需要 package.path 能找到 class.lua。
--   找不到就退回本文件提供的等价实现（语义完全一致，见 netvars.lua:218-235）。
local real_net_event = nil
do
    local ok, chunk = pcall(require, "netvars")
    if ok and type(chunk) == "table" then
        real_net_event = rawget(_G, "net_event")
    end
    -- 不论真实现是否加载成功，都保证 net_event 存在且语义正确
    if type(rawget(_G, "net_event")) ~= "function" and type(rawget(_G, "net_event")) ~= "table" then
        _G.net_event = function(guid, event)
            return {
                _bool = _G.net_bool(guid, event, event),
                push = function(self)
                    self._bool:set_local(true)
                    self._bool:set(true)
                end,
            }
        end
        M.NetEventReal = false
    else
        M.NetEventReal = real_net_event ~= nil
    end
end

M.Types = installed
M.NewNetVar = new_netvar
M.RealNetEvent = (real_net_event ~= nil)

function M.Install()
    -- 本文件在 require 时就完成了安装（net_* 是全局函数）。
    -- 留一个显式入口，方便 bootstrap 报告状态。
    return true
end

return M
