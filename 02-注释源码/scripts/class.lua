--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：class.lua
-- 模块：核心框架 / 面向对象基础设施
-- 职责：整个游戏唯一的类系统。在纯 Lua 5.1 上实现单继承、属性 setter
--       （写入拦截）、只读属性三项能力。全游戏的实体、组件、AI、UI 都基于它构建。
-- 关键符号：Class, ClassRegistry, makereadonly, addsetter, removesetter,
--           ReloadedClass, HandleClassInstanceTracking
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- class.lua
-- Compatible with Lua 5.1 (not 5.0).
--【兼容声明】仅兼容 Lua 5.1。整套元表实现依赖 5.1 的语义（如rawget/rawset、
--   tostring 等行为），在 5.0 上无法工作。移植时若目标语言是 5.3+，
--   需注意整数除法等差异，但本文件的元表技巧在 5.3/5.4 上同样有效。

local TrackClassInstances = false
--【运行时诊断开关】是否追踪所有类的实例数量，用于排查内存泄漏与对象膨胀。
--   正式发布版本恒为 false，仅调试期手动改为 true。
--   开启后每 100 次 HandleClassInstanceTracking 调用输出一次「实例数 Top10」。

ClassRegistry = {}
--【全局类注册表】记录每个类「继承了父类的哪些成员」。
--   用途：热重载时，若子类没有重写某方法，可安全地删除该成员而不误删子类的实现。
--   热重载结束后调用 ReloadedClass() 清理。

if TrackClassInstances == true then
    global("ClassTrackingTable")
    global("ClassTrackingInterval")

    ClassTrackingInterval = 100
    --【追踪输出间隔】每累计 100 帧输出一次实例统计。
end


--== 类型判断 ================================================================

local function _is_a(self, klass)
    --【继承链回溯】沿 _base 一路向上比对。
    --   Class() 中执行了 c._base = base，因此继承关系被显式记录成一条链，
    --   而非依赖 Lua 原生的 __index 查找——这样 is_a 的复杂度是 O(继承深度)，
    --   很快，且语义明确。
    local m = getmetatable(self)
    while m do
        if m == klass then return true end
        m = m._base
    end
    return false
end

local function _is_class(self)
    --【区分「类」与「实例」】只有 Class() 返回的表上才有 is_instance 字段
    --   （见 Class 末尾）。普通实例通过元表间接访问到它，而类本身是 rawget 直接命中。
    return rawget(self, "is_instance") ~= nil
end


--== 元表钩子：属性读写拦截 ===================================================

local function __index(t, k)
    --【__index 钩子】仅当 Class() 传入了 props 参数时才启用（见 Class 中 c.__index 赋值）。
    --   传入 props  → 实例走这条钩子，属性被拦截
    --   未传入 props → c.__index = c，退化为标准方法查找
    local p = rawget(t, "_")[k]
    if p ~= nil then
        --【命中被拦截属性】_ 是一张 { 属性名 -> {当前值, setter函数} } 的隐藏表。
        return p[1]
    end
    return getmetatable(t)[k]
    --【未拦截】按普通表查找方法（此时 t 的元表就是类本身）。
end

local function __newindex(t, k, v)
    --【__newindex 钩子】属性 setter 机制的核心。
    --   赋值不再真正写入 t，而是更新 _ 中的当前值并调用 setter。
    --   由 setter 自行决定如何通知外部（网络同步、事件触发等）。
    local p = rawget(t, "_")[k]
    if p == nil then
        rawset(t, k, v)
        --【普通字段】直接写入。
    else
        local old = p[1]
        p[1] = v
        p[2](t, v, old)
        --【setter 签名】function(实例, 新值, 旧值)
        --   注意顺序：新值在前，旧值在后。移植时容易搞反。
    end
end

local function onreadonly(t, v, old)
    --【默认只读校验器】被 makereadonly 标记的属性使用它。
    --   ★ 注意是 local function——改错会改变作用域并破坏整个模块。
    assert(v == old, "Cannot change read only property")
end


--== 属性修饰器 API ===========================================================

function makereadonly(t, k)
    --【标记为只读】典型用途是「构造后就不应改变的标识」，例如实体的 network_id。
    local _ = rawget(t, "_")
    assert(_ ~= nil, "Class does not support read only properties")
    --【前提】必须在 Class() 时传入 props，否则实例没有 _ 表，此处断言失败。
    local p = _[k]
    if p == nil then
        _[k] = { t[k], onreadonly }
        rawset(t, k, nil)
        --【关键两步】① 把真实值搬进隐藏表 _
        --           ② 把 t[k] 清空
        --   之后所有读取都会被 __index 导向 _，所有写入都被 __newindex 拦截。
    else
        p[2] = onreadonly
        --【已存在】仅替换 setter 为只读校验，保留当前值。
    end
end

function addsetter(t, k, fn)
    --【安装自定义 setter】
    --   setter 是实现「数据变更→副作用」钩子的地方。
    --   例如网络变量在值变化时调 SetNetworkedVar 触发同步，
    --   例如 UI 控件在值变化时重绘。
    local _ = rawget(t, "_")
    assert(_ ~= nil, "Class does not support property setters")
    local p = _[k]
    if p == nil then
        _[k] = { t[k], fn }
        rawset(t, k, nil)
    else
        p[2] = fn
        --【已存在】保留当前值，仅替换 setter。
        --   允许重复调用以更新 setter 实现——模组常用这招覆盖原版行为。
    end
end

function removesetter(t, k)
    --【解除拦截，恢复为普通字段】
    local _ = rawget(t, "_")
    if _ ~= nil and _[k] ~= nil then
        rawset(t, k, _[k][1])
        --【还原】把隐藏表中的当前值写回实例本体。
        _[k] = nil
        --【清除拦截记录】之后读写都走普通 Lua 语义。
    end
end


--== Class 构造函数 ===========================================================

function Class(base, _ctor, props)
    --【整个游戏最重要的函数】理解它的返回值语义即可掌握类系统。
    --
    --  ① c 既是「类」又是「实例的元表」
    --     c.__index = c（无属性时）意味着实例查不到方法时去元表 c 上找，
    --     而 c 上浅拷贝着父类的所有方法。这实现了继承——
    --     ★ 但注意是**浅拷贝**而非原型链回溯：父类后续新增的方法，子类看不到。
    --     这是本实现的一个显著局限（见「不要照抄的地方」）。
    --
    --  ② mt 是 c 的元表，靠 mt.__call 让「调用类」等价于「创建实例」
    --     Lua 中表不可调用；给表设元表并定义 __call 后，
    --     `MyClass(...)` 就等价于 `mt.__call(MyClass, ...)`。这是本文件最关键的技巧。
    --
    --  ③ props 决定是否启用属性拦截
    --     传 props → c.__index/__newindex 指向本文件定义的钩子，实例带隐藏表 _；
    --     不传     → c.__index = c，退化为普通 Lua 类，无拦截能力。
    local c = {}    -- a new class instance
    local c_inherited = {}
	--【继承成员记录】记录哪些成员是从父类拷贝来的，供热重载时区分。

	if not _ctor and type(base) == 'function' then
        --【重载1】Class(function(self, ...) end)
        --   只传了一个函数：视为「无父类 + 直接指定构造函数」。
        _ctor = base
        base = nil
    elseif type(base) == 'table' then
        -- our new class is a shallow copy of the base class!
		-- while at it also store our inherited members so we can get rid of them
		-- while monkey patching for the hot reload
		-- if our class redefined a function peronally the function pointed to by our member is not the in in our inherited
		-- table
        for i,v in pairs(base) do
            c[i] = v
            c_inherited[i] = v
        end
        c._base = base
        --【继承实现】浅拷贝父类全部成员到 c，同时把 _base 指向父类供 is_a() 回溯。
        --   若子类重写了某方法，c 中保存子类版本，而 c_inherited 仍指向父类版本。
    end

    -- the class will be the metatable for all its objects,
    -- and they will look up their methods in it.
    if props ~= nil then
        c.__index = __index
        c.__newindex = __newindex
    else
        c.__index = c
    end
    --【元表选择】有属性表 → 走读写拦截钩子；否则 → 直接指向类自身（标准查找）。

    -- expose a constructor which can be called by <classname>(<args>)
    local mt = {}

    if TrackClassInstances == true and CWD~=nil then
        --【调试分支】开启实例追踪时，额外记录「每个实例是从哪个类的定义行创建的」。
        if ClassTrackingTable == nil then
            ClassTrackingTable = {}
        end
        ClassTrackingTable[mt] = {}
		local dataroot = "@"..CWD.."\\"
        local tablemt = {}
        setmetatable(ClassTrackingTable[mt], tablemt)
        tablemt.__mode = "k"         -- now the instancetracker has weak keys
        --【弱键表】实例被回收后，追踪表中的条目自动消失，不会造成二次泄漏。

        local source = "**unknown**"
        if _ctor then
  			-- what is the file this ctor was created in?
			--【定位类定义行】用 debug.getinfo 拿到构造函数所在的源码行，
			--   再回溯到 class 定义那一行，提取类名，便于调试时定位。
			local info = debug.getinfo(_ctor, "S")
			-- strip the drive letter
			-- convert / to \\
			source = info.source
			source = string.gsub(source, "/", "\\")
			source = string.gsub(source, dataroot, "")
			local path = source

			local file = io.open(path, "r")
			if file ~= nil then
				local count = 1
   				for i in file:lines() do
					if count == info.linedefined then
						source = i
						-- okay, this line is a class definition
						-- so it's [local] name = Class etc
						-- take everything before the =
						local equalsPos = string.find(source,"=")
						if equalsPos then
							source = string.sub(source,1,equalsPos-1)
						end
						-- remove trailing and leading whitespace
						source = source:gsub("^%s*(.-)%s*$", "%1")
						-- do we start with local? if so, strip it
						if string.find(source,"local ") ~= nil then
							source = string.sub(source,7)
						end
						-- trim again, because there may be multiple spaces
						source = source:gsub("^%s*(.-)%s*$", "%1")
						break
					end
					count = count + 1
				end
				file:close()
			end
		end

        mt.__call = function(class_tbl, ...)
			--【实例创建入口·追踪版】比标准版多一行：把实例登记进追踪表。
			local obj = {}
			if props ~= nil then
				obj._ = {}
				for k, v in pairs(props) do
					obj._[k] = { nil, v }
					--【属性表结构】{ 默认值(nil), setter函数 }
					--   注意初值统一为 nil：真实默认值由构造函数或后续赋值决定。
				end
			end
			setmetatable(obj, c)
			ClassTrackingTable[mt][obj] = source
			if c._ctor then
				c._ctor(obj, ...)
			end
			return obj
		end
	else
		mt.__call = function(class_tbl, ...)
			--【★ 实例创建入口·正式版】整个类系统的热点路径，无任何多余开销。
			--  步骤：① 建空表 ② 若有属性表则初始化隐藏表 _  ③ 挂元表  ④ 调构造函数
			local obj = {}
			if props ~= nil then
				obj._ = {}
				for k, v in pairs(props) do
					obj._[k] = { nil, v }
					--【关键结构】每个被拦截的属性存为 {当前值, setter} 二元组，
					--   __index 返回 p[1]，__newindex 写入 p[1] 并回调 p[2]。
				end
			end
			setmetatable(obj, c)
			--【挂元表】使 obj 的方法查找回溯到类 c。
			if c._ctor then
			   c._ctor(obj, ...)
			end
			--【构造函数】签名 function(实例, ...)。★ 返回值被丢弃——
			--   构造器只能通过给实例赋值来初始化，不能 return。
			--   移植到 C# 时，构造函数天然能return，此处需注意语义差异。
			return obj
		end
	end

    c._ctor = _ctor
	--【保存构造器】供 mt.__call 回调。
	c.is_a = _is_a					-- is_a: is descendent of this class
	--【继承检查】判断某实例是否属于本类（含子类）。
	c.is_class = _is_class			-- is_class: is self a class instead of an instance
	c.is_instance = function(obj)	-- is_instance: is obj an instance of this class
		return type(obj) == "table" and _is_a(obj, c)
	end

    setmetatable(c, mt)
    --【★ 关键一步】把 mt 设为 c 的元表。正是这一步让「类」变得可调用。
    ClassRegistry[c] = c_inherited
    --【登记继承成员】供热重载时安全地猴子补丁（monkey patch）。
    return c
end

function ReloadedClass(mt)
	ClassRegistry[mt] = nil
	--【标记热重载完成】清除该类的继承成员记录。
	--   仅开发期热重载机制使用，正式运行不调用。
end

local lastClassTrackingDumpTick = 0

function HandleClassInstanceTracking()
    --【周期性输出实例数量 Top10】由主循环每帧调用，仅调试期生效。
    if TrackClassInstances and CWD~=nil then
        lastClassTrackingDumpTick = lastClassTrackingDumpTick + 1

        if lastClassTrackingDumpTick >= ClassTrackingInterval then
            collectgarbage()
            print("------------------------------------------------------------------------------------------------------------")
            lastClassTrackingDumpTick = 0
            if ClassTrackingTable then
                local sorted = {}
                local index = 1
                for i,v in pairs(ClassTrackingTable) do
                    local count = 0
                    local first = nil
                    for j,k in pairs(v) do
                        if count == 1 then
                            first = k
                        end
                        count = count + 1
                    end
                    if count>1 then
                        sorted[#sorted+1] = {first, count-1}
                    end
                    index = index + 1
                end
                -- get the top 10
                table.sort(sorted, function(a,b) return a[2] > b[2] end )
                for i=1,10 do
                    local entry = sorted[i]
                    if entry then
                        print(tostring(i).." : "..tostring(sorted[i][1]).." - "..tostring(sorted[i][2]))
                    end
                end
                print("------------------------------------------------------------------------------------------------------------")
            end
        end
    end
end
--【★ 内存泄漏排查利器】若某个类的实例数持续增长，说明这些对象没被正确回收。
--   典型场景：事件监听未注销、协程未Kill、父子引用成环。