--============================================================
-- 文件：01_class.lua
-- 模块：核心框架 / 面向对象基础设施
-- 职责：整个参考实现唯一的类系统。在纯 Lua 上实现「单继承 + 属性 setter +
--       只读属性」三项能力，本目录下所有模块都建立在它之上。
--
-- 【为什么不能只用原生 __index 继承链？】
-- 原生 __index 链只能做「方法查找」，做不到「写入拦截」。
-- 而生存游戏极度依赖写入拦截：一个数值从 100 变成 50，
-- 这个「赋值动作」本身必须自动触发网络同步、HUD 刷新、音效播放。
-- 如果让业务代码自己记得调 SetCurrent()，迟早有人漏写；
-- 用属性 setter 拦截后，赋值就是全部语义，**无法写错**。
-- 这是本文件最值得照搬的一个设计。
--
-- 【与原版 class.lua 的差异（都是非核心的工程性代码）】
-- 1. 删掉热重载相关的 ClassRegistry / ReloadedClass 的实际用途（保留表仅作展示）。
-- 2. 删掉 TrackClassInstances 实例追踪（那是原版的调试优化）。
-- 3. 补上了原版 scheduler.lua 里两处笔误/死分支的正确写法（见 02_scheduler 注释）。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》scripts/class.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4 均可运行（未使用 goto、位运算、整数除法 //）
--============================================================

local M = {}

--============================================================
-- 一、is_a / is_class / is_instance
--============================================================

-- is_a：沿元表的 _base 链逐级上溯，判断 self 是否派生自 klass。
--
-- 【为什么用 _base 链？】
-- 本类的继承是「浅拷贝」实现的（子类把父类字段拷进自己的表），
-- 实例的元表是子类 c，c._base 指向父类，父类._base 再指向祖父类……
-- 所以沿 _base 链走就等价于原型链。
-- 【代价】O(继承深度)。原版也接受了这个代价，因为继承深度极浅。
local function _is_a(self, klass)
    local m = getmetatable(self)
    while m do
        if m == klass then return true end
        m = m._base
    end
    return false
end

-- is_class：判断 self 是「一个类」而不是「一个实例」。
-- 类的特征是它自己带 is_instance 字段（由 Class() 统一注入）。
local function _is_class(self)
    return rawget(self, "is_instance") ~= nil
end

--============================================================
-- 二、属性的读写拦截（核心）
--============================================================

-- 有属性表时的读取：优先从隐藏表 obj._ 里取当前值；
-- 取不到说明这是普通字段/方法，落到类表（getmetatable(obj)）上找方法。
--
-- 【为什么普通字段不会走 __index？】
-- Lua 的元方法只在「原始表里查不到该 key」时才触发。
-- 非属性字段被 rawsert 进了 obj，rawget 能命中，根本不会调用 __index。
-- 这也是这套实现性能可接受的原因：热路径上的普通字段访问零额外开销。
local function __index(t, k)
    local props = rawget(t, "_")
    if props ~= nil then
        local p = props[k]
        if p ~= nil then
            return p[1]
        end
    end
    local mt = getmetatable(t)
    return mt ~= nil and mt[k] or nil
end

-- 写入拦截：这是本文件存在的全部理由。
--   - key 不在属性表里 → 当普通字段 rawsert（零成本）
--   - key 在属性表里     → 更新隐藏值，再回调 setter(self, new, old)
local function __newindex(t, k, v)
    local props = rawget(t, "_")
    local p = props ~= nil and props[k] or nil
    if p == nil then
        rawset(t, k, v)
    else
        local old = p[1]
        p[1] = v
        p[2](t, v, old)
    end
end

--============================================================
-- 三、只读属性的默认 setter
--============================================================

-- 只读保护：用「值必须等于旧值」实现。
-- 比直接拒绝一切写入更温和 —— 赋同样的值是合法的幂等操作。
-- 【为什么允许赋同值？】读档时会把所有字段无差别写一遍，
-- 如果严格拒绝任何写入，这些无害的幂等赋值会全部崩掉。
local function onreadonly(t, v, old)
    assert(v == old, "Cannot change read only property")
end

-- makereadonly(t, k)：把实体上某个属性改成只读。
-- 参数 t 是「实例」而非「类」，因为属性表 obj._ 是每实例独立的。
-- 这与原版一致，是个容易踩的坑：想在类表上加只读属性是做不到的。
function M.makereadonly(t, k)
    local props = rawget(t, "_")
    assert(props ~= nil, "Class does not support read only properties")
    local p = props[k]
    if p == nil then
        props[k] = { t[k], onreadonly }
        rawset(t, k, nil)   -- 关键：把裸字段清掉，否则 __newindex 不会被触发
    else
        p[2] = onreadonly
    end
end

-- addsetter(t, k, fn)：运行期给已有属性换/加一个 setter。
-- 典型用途：基类声明了 max 属性但没给 setter，
-- 派生类需要「设置 max 时额外做点事」，此时在派生类构造时调 addsetter。
-- 【注意】只替换 setter 函数、保留当前值；且必须在实例上调用。
function M.addsetter(t, k, fn)
    local props = rawget(t, "_")
    assert(props ~= nil, "Class does not support property setters")
    local p = props[k]
    if p == nil then
        props[k] = { t[k], fn }
        rawset(t, k, nil)
    else
        p[2] = fn
    end
end

-- removesetter(t, k)：彻底取消该属性的拦截，退化成普通字段。
-- 用于「临时关掉某种副作用」，比如状态机暂停时关闭状态切换。
function M.removesetter(t, k)
    local props = rawget(t, "_")
    if props ~= nil and props[k] ~= nil then
        rawset(t, k, props[k][1])
        props[k] = nil
    end
end

--============================================================
-- 四、Class 构造器
--============================================================

-- 类注册表：类表 -> 它从父类继承来的成员表。教学版只作展示。
M.Registry = {}

-- Class(base, _ctor, props) -> 类表
--   base  : 父类（table）或 nil；也允许直接传一个函数当 _ctor（等价 base=nil）
--   _ctor : 构造函数 function(self, ...)；实例建好后调用
--   props : 属性表 { key = setterfn }，这些 key 会从实例的裸字段里"消失"
--
-- 返回的 c 同时是「类本身」和「它所有实例的元表」。
--
-- 【为什么浅拷贝而不是只保留父类引用？】
-- 原版注释说得很清楚：为了支持热重载（monkey patch）时能干净区分
-- 「本类覆盖的成员」与「继承来的成员」。
-- 【代价】父类后续新增的方法不会自动出现在已创建的子类里。忠实保留原版行为。
--
-- ★★★ 移植时最容易踩的坑：构造函数**不会自动串联** ★★★
--   下面这行 `c._ctor = _ctor` 是**无条件覆盖**：
--     - 传了新 ctor  -> 父类的 ctor 被顶掉，父构造函数不再自动执行
--     - 传了 nil ctor -> 父类的 ctor 也被顶成 nil，父构造函数彻底不执行
--   原版 DST 靠「子类 ctor 里手工调 `Base._ctor(self, inst)`」来解决。
--   实例：components/aoeweapon_lunge.lua 开头就是
--       local AOEWeapon_Lunge = Class(AOEWeapon_Base, function(self, inst)
--           AOEWeapon_Base._ctor(self, inst)   -- ← 必须手工调
--           ...
--       end)
--   这里的 `AOEWeapon_Base._ctor` 能被访问到，正是因为浅拷贝把 _ctor 也拷进了子类表。
--   ★ 这不是 bug 而是原版有意为之（避免隐式的双次初始化），
--     但移植到 C#/C++ 时**很容易不自觉地写成自动串联**，导致行为与 Lua 版不一致。
-- Class 定义成 vararg 函数，是为了能用 select("#", ...) 拿到实参个数做守卫。
function M.Class(...)
    -- ★★★ 实参个数守卫（教学版新增，原版没有）★★★
    -- Lua 对「实参多于形参」是**静默丢弃**的，不报错。
    -- 于是下面这个极常见的笔误会毫无征兆地让整套属性机制失效：
    --     Class(Base, ctor, nil, { max = onmax })   -- ← 传了 4 个，props 被丢弃
    -- 症状是「setter 好像不触发了」，但没有任何报错，极难排查
    -- （本仓库开发 04_meter.lua 时就真的踩中了这个坑）。
    -- 这里显式检查，让错误在第一次运行时立刻暴露。
    local nargs = select("#", ...)
    assert(nargs <= 3,
        "Class() 最多接受 3 个参数 (base, ctor, props)，实际收到 " .. nargs ..
        " 个 —— 多传的会被 Lua 静默丢弃。若派生类要带 props，正确写法是去掉中间的 nil。")

    local base, _ctor, props = ...

    local c = {}                -- 这个 table 既是类，也是实例的元表
    local c_inherited = {}      -- 记录哪些成员是从父类拷来的（供热重载对比）

    if not _ctor and type(base) == "function" then
        _ctor = base            -- 简写：Class(function(self, ...) ... end)
        base = nil
    elseif type(base) == "table" then
        for i, v in pairs(base) do
            c[i] = v
            c_inherited[i] = v
        end
        c._base = base
    end

    -- 有属性表才装拦截元方法。
    -- 【为什么可以按需装？】绝大多数类（纯工具类、只有方法的类）没有属性，
    -- 装上拦截只会白白增加每次写入的开销。
    if props ~= nil then
        c.__index = __index
        c.__newindex = __newindex
    else
        c.__index = c
    end

    -- mt 的 __call 让「调用类」等价于「构造实例」，从而支持 Animal() 这种写法
    local mt = {}
    mt.__call = function(class_tbl, ...)
        local obj = {}
        if props ~= nil then
            obj._ = {}
            for k, fn in pairs(props) do
                obj._[k] = { nil, fn }
            end
        end
        setmetatable(obj, c)
        -- ★ 构造函数必须在 setmetatable 之后调用 —— 这样构造函数体里的
        --   第一次赋值才会被 __newindex 拦截到，语义才正确。
        if c._ctor then
            c._ctor(obj, ...)
        end
        return obj
    end

    c._ctor = _ctor
    c.is_a = _is_a
    c.is_class = _is_class
    c.is_instance = function(obj)
        return type(obj) == "table" and _is_a(obj, c)
    end
    -- is_instance 是「静态」判断：Child.is_instance(obj) 问的是
    -- 「obj 是不是 Child 的实例」，与实例上调用 is_a 是同一件事。

    setmetatable(c, mt)
    M.Registry[c] = c_inherited
    return c
end

-- 兼容原版的全局名，方便把本文件直接替换进原版工程试跑
_G.Class = M.Class
_G.makereadonly = M.makereadonly
_G.addsetter = M.addsetter
_G.removesetter = M.removesetter

--============================================================
-- 五、自测
--============================================================

local T = {}

-- 断言助手：失败直接 error，错误信息带模块名便于定位
local function check(ok, msg)
    if not ok then error("[01_class] 断言失败: " .. msg, 2) end
end

-- 一个带属性的类：value 有 setter，会记录每次 (new, old)
local function on_value(self, new, old)
    table.insert(self.log, { newvalue = new, oldvalue = old })
end
local WithProp = M.Class(function(self, v)
    self.log = {}
    self.value = v          -- 构造函数在 setmetatable 之后调用，所以这次赋值会触发 setter
end, nil, { value = on_value })

function T.inheritance()
    local Animal = M.Class(function(self, name)
        self.name = name
        self.legs = 4
    end)
    function Animal:Speak() return self.name .. " 说" end

    -- ★ 注意：子类构造函数必须**手工**调父类构造函数，父类不会自动执行。
    --   这与原版 DST 完全一致（参见 components/aoeweapon_lunge.lua）。
    local Dog = M.Class(Animal, function(self, name)
        Animal._ctor(self, name)          -- 手工串联
        self.breed = "dog"
    end)
    function Dog:Speak() return self.name .. " 汪汪" end     -- 覆写父类方法

    local Bird = M.Class(Animal, function(self, name)
        Animal._ctor(self, name)
        self.breed = "bird"
    end)
    function Bird:Speak() return self.name .. " 叽叽" end

    local d = Dog("旺财")
    local b = Bird("小鸡")

    check(d.name == "旺财", "构造参数应传入构造函数")
    check(d.legs == 4, "应继承父类字段")
    check(d.breed == "dog", "子类构造函数的额外初始化应生效")
    check(d:Speak() == "旺财 汪汪", "子类应覆写方法")
    check(b:Speak() == "小鸡 叽叽", "兄弟类不应互相污染")
    check(d:is_a(Animal), "Dog 实例 is_a Animal 应为真")
    check(not d:is_a(Bird), "Dog 实例 is_a Bird 应为假")
    check(Animal.is_class(Animal), "类本身 is_class 应为真")
    check(not Animal.is_class(d), "实例 is_class 应为假")
    check(Animal.is_instance(d), "静态 is_instance 应为真")

    -- 验证「传 nil ctor 会顶掉父类构造函数」这一原版语义
    local NoCtor = M.Class(Animal, nil)
    local n = NoCtor()
    check(n.name == nil, "子类传 nil ctor 时父构造函数不执行（原版语义）")
    check(n:is_a(Animal), "但方法继承依然有效")
    check(type(Animal._ctor) == "function", "父类 _ctor 可被子类访问（供手工串联）")

    print("  [OK] 继承 / 覆写 / is_a / 手工串联构造函数")
end

function T.setter()
    local o = WithProp(10)
    -- 构造函数里 self.value = 10 也走 setter，所以 log 至少有 1 条
    check(#o.log == 1, "构造函数内的首次赋值也应触发 setter")

    o.value = 20
    check(o.value == 20, "setter 后应能读到新值")

    local last = o.log[#o.log]
    check(last.newvalue == 20 and last.oldvalue == 10,
        "setter 应收到 (self, new, old)，old 必须是上一次的值")

    -- 普通字段不受拦截影响（性能路径）
    o.plainfield = 123
    check(rawget(o, "plainfield") == 123, "非属性字段应走 rawsert 快路径")
    print("  [OK] 属性 setter 拦截 (self, new, old)")
end

function T.readonly()
    local obj = WithProp(5)
    M.makereadonly(obj, "value")

    -- 赋同值：允许（幂等）
    local ok = pcall(function() obj.value = 5 end)
    check(ok, "只读属性赋同值应被允许（幂等）")

    -- 赋不同值：必须报错
    local ok2, err = pcall(function() obj.value = 6 end)
    check(not ok2, "只读属性赋新值必须报错")
    check(tostring(err):find("read only") ~= nil, "错误信息应包含 'read only'")

    -- 移除 setter 后恢复可写
    M.removesetter(obj, "value")
    obj.value = 99
    check(obj.value == 99, "removesetter 后应恢复为普通字段")
    print("  [OK] 只读属性保护 + removesetter 恢复")
end

function T.addsetter()
    local o = WithProp(1)
    local hits = 0
    M.addsetter(o, "value", function(self, new, old) hits = hits + 1 end)
    o.value = 2
    check(hits == 1, "addsetter 应替换为新的 setter（旧的 on_value 不应再触发）")
    check(#o.log == 1, "旧 setter 不应再被调用")
    print("  [OK] addsetter 运行期替换 setter")
end

function T.plain_class()
    local Plain = M.Class(function(self) self.x = 1 end)
    function Plain:Get() return self.x end
    local p = Plain()
    p.x = 2
    check(p:Get() == 2, "无 props 的类应走普通字段赋值路径")
    print("  [OK] 无 props 类的普通路径")
end

function T.run()
    print("=== 01_class.lua 自测 ===")
    T.inheritance()
    T.setter()
    T.readonly()
    T.addsetter()
    T.plain_class()
    print("01_class 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 六、导出
--   两种用法：
--     require("01_class")  -> 返回模块表（不会自动跑自测）
--     lua 01_class.lua     -> 直接跑自测
--
-- 【为什么不用 `if ... == nil then` 判断是否主 chunk？】
--   在 Lua 5.1 里主 chunk 是 vararg 函数，顶层写 `...` 合法；
--   但 Lua 5.2+ 用 load/loadstring 编译出来的 chunk **不是** vararg 函数，
--   此时顶层出现 `...` 是**语法错误**（不是运行时报错，是编译不过）。
--   为了同时兼容 5.1 与 5.3/5.4/5.5，这里改用「源文件名 == 命令行入口参数」
--   来判断：lua foo.lua 时 arg[0] == "foo.lua"；被 require 时 arg[0] 是
--   入口脚本名，与本文件名不同。
local function IS_MAIN_CHUNK()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) ~= "@" then return false end        -- 非文件加载
    local fname = src:sub(2):gsub("\\", "/"):match("([^/]+)$") or ""
    if fname == "" then return false end
    return arg ~= nil and arg[0] ~= nil
        and (arg[0]:gsub("\\", "/"):match("([^/]+)$")) == fname
end

if IS_MAIN_CHUNK() then
    T.run()
end

return {
    Class = M.Class,
    makereadonly = M.makereadonly,
    addsetter = M.addsetter,
    removesetter = M.removesetter,
    Registry = M.Registry,
    test = T,
}