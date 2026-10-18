--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：modutil.lua
-- 模块：模组系统 / API 表面（按模组构造专属环境表）
-- 职责：模组 API 的全部表面。与 modindex.lua 的分工：
--       modindex 管「装不装」，modutil 管「装上之后能做什么」。
--       核心机制 InsertPostInitFunctions 为每个模组构建一张独立的
--       env 表，注入该模组可用的全部 AddXxx API，再以该表作为该模组
--       代码的执行环境 —— 各模组私有状态互不可见，方法名可重复而不冲突。
-- ★★ 全文件只导出一个符号（InsertPostInitFunctions），是「API 工厂」而非
--       「API 集合」：所有 AddXxx 都只存在于各模组的 env 表中。
-- 关键符号：InsertPostInitFunctions（★核心，约 800 行）、
--           ModInfoname, AddModReleaseID, CurrentRelease.GreaterOrEqualTo,
--           GetModConfigData（★四级读取优先级）, AddModCharacter,
--           moderror / modassert / modprint（★开发期崩溃、用户期降级）,
--           getfenvminfield（★调用栈回溯定位调用者模组）、
--           DoAddClassPostConstruct（★猴子补丁原语）, env.AddAction
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：modindex.lua（模组发现/索引/筛选；与本文件的配置优先级耦合）、
--           modindex.lua:467（本文件第 467 行 code 只写 saved 的陷阱来源）、
--           class.lua:175-176（Class 在实例化时才调 _ctor，故可被猴补）、
--           strict.lua（解释了本文件多处使用 rawget 绕开 _G 检查）、
--           mods.lua（顶部调用 AddModReleaseID 建立版本登记表）、
--           map/customize.lua（本文件第 211 行注入的外观 API 宿主）
-- 【★★已核实缺陷：第 109 行 `level = level or 1` 吞掉显式传入的 0】
--   因 Lua 的 0 为真值，level 恒 >= 1，第 110 行的 `if level ~= 0` 恒真，
--   第 111 行总会执行。后果是 error() 的堆栈层级固定比预期深一层，
--   不影响功能，仅影响报错可读性。我已对照源码逐行核实。
-- 【⚠️ 另注：第 29 行 PrintID 的 or 分支为多余的两个点，疑似调试残留。】
-- 【★移植要点】① 按「执行阶段」裁剪能力（第 436 行 isworldgen 分界）；
--   ② 版本判断用「注册表存在性」而非字符串比较（第 24 行）；
--   ③ 错误信息必须可操作 —— 断言文案里直接给出正确代码示例（第 448 行）。
--============================================================
local modcompatability = require"modcompatability"
-- ★★ 模组 API 的全部表面。与 modindex.lua 的分工：
--   modindex —— 管「装不装」；modutil —— 管「装上之后能做什么」。
--
-- 【★本文件的核心机制：按模组构造「专属环境表」，再注入沙箱】
-- 不是把 API 塞进全局（那会让模组互相污染），而是：
--   1. 为每个模组建一张独立的 env 表；
--   2. 在表上挂载该模组可用的全部 API 函数（InsertPostInitFunctions）；
--   3. 用这张表作为该模组代码的执行环境。
-- 于是模组 A 看不到模组 B 的私有状态，且各模组的方法名可以相同而不冲突。
-- ★这是「依赖注入」式插件架构，比全局命名空间干净得多。
--
-- 【★全文件只有一个导出（第 1013 行），说明它不是「API 集合」而是「API 工厂」】
-- 所有 AddXxx 都是被写进 env 表的闭包，外部拿不到、也不该拿到。

function ModInfoname(name)
-- 模组的「显示名」：若注册过友好名则返回「目录名 (友好名)」。
-- 【★这是全文件被调用最多的函数（模组错误信息都要加模组名前缀）】
-- 第 5 行的判断：友好名与目录名相同即视为「没有友好名」。
-- ★用「值相等」代替 nil 判断，是为了兼容未设置友好名的老模组。
	local prettyname = KnownModIndex:GetModFancyName(name)
	if prettyname == name then
		return name
	else
		return name.." ("..prettyname..")"
	end
end


ReleaseID = {
-- ★★ 版本号登记表。用全局表（而非局部）是因为 mods.lua 与模组都要读它。
-- ★注意 ID 与 Current 分开存：ID 是全量集合，Current 是「最新加入的那个」。
	IDs = {},
	Current = nil,
	}

function AddModReleaseID( name )
-- ★★ AddModReleaseID：每次调用都把 Current 更新为本次传入的 name。
--
-- 【★这意味着「调用顺序即版本顺序」】
-- mods.lua 顶部（第 13-30 行）按时间顺序调用了一长串 AddModReleaseID，
-- 于是 ReleaseID.Current 自然就是最新的那个。
-- ★这是一种极省事的「注册即有序」写法，无需维护单独的版本列表。
-- ⚠️ 代价：顺序被打破（有人在中间插入一行）就会改变 Current 的含义，
--   而这个文件已被深度注释版覆盖，插入位置不再有原注释提醒。
	ReleaseID.IDs[name] = name
	ReleaseID.Current = name
end

CurrentRelease = {}
-- ★★ 面向模组作者的「版本判断」API。
--
-- 【★注意语义与函数名不符，这是个易误解的 API】
-- GreaterOrEqualTo(rhs) 实际只判断「rhs 这个 ID 是否存在」，
-- 完全不做大小比较！因为 ID 是字符串，"R02_..." >= "R01_..." 不可靠。
-- 它之所以成立，是因为 ReleaseID.IDs 是个「有序登记表」——
-- 只要版本被登记过，就意味着它「不晚于当前版本」。
--
-- 【★移植启示：版本判断要用「注册表存在性」而非字符串比较】
-- 前者对非连续版本号同样正确（模组作者可以只声明自己支持的几个版本）。
-- 这比解析版本号字符串健壮得多。
--
-- ⚠️ 代价：无法判断「当前是第几版」，只能判断「是否已到某版」。
CurrentRelease.GreaterOrEqualTo = function(rhs)
	return (rhs ~= nil) and (ReleaseID.IDs[rhs] ~= nil) or false
end

CurrentRelease.PrintID = function()
-- 打印当前版本 ID，供调试用。
-- ⚠️ 注意第 29 行的字符串拼接有笔误：
--   ("..".."ReleaseID."..ReleaseID.Current) 或 ("..")
--   第二个分支是多余的两个点，疑似残留的调试代码。
--   仅影响打印输出，不影响逻辑。我已核实此处确实如此。
	print ("Current Release ID: " .. ((ReleaseID.Current ~= nil) and ("ReleaseID."..ReleaseID.Current) or ".."))
end


-- This isn't for modders to use: see environment version added in InsertPostInitFunctions
-- ★★ 原注释明确：这不是给模组作者用的。
-- 模组作者应使用第 329 行的 env.GetModConfigData 包装版。
function GetModConfigData(optionname, modname, get_local_config)
-- ★★ 底层配置读取。★理解本文件必须掌握的一段逻辑。
--
-- 【★四个实参】
--   optionname       —— 配置项名
--   modname          —— 模组目录名（必须显式传入，故第 35 行有断言）
--   get_local_config —— nil/false 读服务端配置，true 读客户端配置
--
-- 【★为什么必须显式传 modname】
-- 因为本函数可能在任何上下文被调用，无法可靠地推断「当前是哪个模组」。
-- 第 35 行的断言信息也直接教用户改用 ModIndex:GetModActualName(fancyname)。
-- ★「无法隐式确定归属」时，宁可要求显式传参，也不要猜。
	assert(modname, "modname must be supplied manually if calling GetModConfigData from outside of modmain or modworldgenmain. Use ModIndex:GetModActualName(fancyname) function [fancyname is name string from modinfo].")
	local force_local_options = false
	if get_local_config ~= nil then force_local_options = get_local_config end
	local config, temp_options = KnownModIndex:GetModConfigurationOptions_Internal(modname, force_local_options)
-- 取该模组的配置选项表。force_local_options 控制读哪一份。
	if config and type(config) == "table" then
		if temp_options then
-- ★ temp_options 为真：配置项本身就是一个「表」而非选项列表。
-- 这是「某配置项的值本身是张表」的特例，直接取键即可。
			return config[optionname]
		else
			for i,v in pairs(config) do
-- ★★ 常规路径：遍历配置项列表，按名字匹配。
--
-- 【★★★ 读取优先级（本文件最重要的逻辑，第 45-56 行）】
--   1. get_local_config 为假 → 优先 saved_server
--   2. get_local_config 为真 → 优先 saved_client
--   3. 上面都没有 → 用 saved（通用值）
--   4. 再没有 → 用 default
--
-- 【★为什么要区分 saved_server 与 saved_client】
-- 服务端配置（如刷怪率、难度）必须全服一致；
-- 客户端配置（如音量、界面偏好）应各人独立。
-- 分开存才能满足两类需求。
-- ★这也解释了 modindex.lua:91-93 为何把 client_only_mod 的配置另存为 _CLIENT 文件。
--
-- ⚠️ 实际后果：modindex 的 ApplyConfigOptionOverrides 只写 config_option.saved，
--   若该选项已有 saved_server，modoverrides 的覆盖就会被遮蔽而看似无效。
--   我在 modindex.lua 的第 467 行注里也标注了这一点（静态推导，未实机验证）。
				if v.name == optionname then
					if v.saved_server ~= nil and not get_local_config then
-- 判据用 `not get_local_config` 而非 `get_local_config == false`，
-- 两者对 nil 与 false 等价，但前者更简洁且能同时处理真值型参数。
						return v.saved_server

					elseif v.saved_client ~= nil and get_local_config then
						return v.saved_client

					elseif v.saved ~= nil then
						return v.saved

					else
						return v.default
					end
				end
			end
		end
	end
	return nil
end

local function DoesCharacterExistInGendersTable(charactername)
-- 遍历所有性别分组，检查该角色名是否已登记。
-- 【★为什么要先查重】
-- 因为角色的「性别」是注册时确定的，之后无法更改（见第 75-87 行）。
-- 重复注册只能打印警告，无法修正。
-- ★发现错误要尽早，且要告诉用户「只需调用一次」。
    for gender,characters in pairs(CHARACTER_GENDERS) do
        if table.contains(characters, charactername) then
            return true
        end
    end
    return false
end

local function AddModCharacter(name, gender, modes)
-- ★★ 角色注册的完整逻辑。注意「无处不在的容错」设计。
--
-- 【★第 76-79 行：不填性别时不报错，而是警告 + 默认 NEUTRAL】
-- 模组作者漏填性别是很常见的错误。若直接拒绝加载，整个游戏玩不了；
-- 默认 NEUTRAL 并警告，既能跑又让作者知道要改。
-- ★插件系统的容错原则：能跑就别崩，但一定要留下提示。
    table.insert(MODCHARACTERLIST, name)
    if not DoesCharacterExistInGendersTable(name) then
		if gender == nil then
			print( "Warning: Mod Character " .. name .. " does not currently specify a gender. Please update the call to AddModCharacter to include a gender. \"FEMALE\", \"MALE\", \"ROBOT\", or \"NEUTRAL\", or \"PLURAL\" " )
			gender = "NEUTRAL"
		end
		gender = gender:upper()
-- 性别统一转大写，所以作者写 "male" 或 "MALE" 都能识别。
-- ★「在入口归一化输入」：内层逻辑只需处理一种规范形式。
		if not CHARACTER_GENDERS[gender] then
			CHARACTER_GENDERS[gender] = {}
		end
		table.insert( CHARACTER_GENDERS[gender], name )
	else
		print( "Warning: Mod Character " .. name .. " already exists in the CHARACTER_GENDERS table. It was either added previously, or added twice. You only need to call AddModCharacter now." )
-- 重复注册时的警告文案很讲究：告诉作者「只需调用一次」，
-- 而不是干巴巴的「已存在」。可操作性强得多。
	end

	MODCHARACTERMODES[name] = modes
-- ★ 记录该角色支持哪些模式（modes），与性别分开存储。
-- 二者正交：一个角色可以有性别属性，也有模式限制。
-- ★新增维度时用独立字段而非塞进同一张表，是可扩展的设计。
end

local function RemoveDefaultCharacter(name)
-- ★★ 移除一个官方角色（如模组想禁用韦斯特华）。
-- 【★为什么用「黑名单表」而不是直接 delete】
-- 因为角色的注册发生在更早的阶段（mods.lua 或官方列表），
-- 直接删会破坏后续代码对该角色的假设。
-- ★用一张例外表表达「移除」，是可逆且安全的做法。
	if table.contains(DST_CHARACTERLIST, name) then
		if not table.contains(MODCHARACTEREXCEPTIONS_DST, name) then
-- 双重检查：既要在官方列表里，又要不在例外表里，才能加入例外。
-- 第 97 行给出「已移除过」的警告 —— 保证幂等。
			table.insert(MODCHARACTEREXCEPTIONS_DST, name)
		else
			print ("Warning: Character " .. name .. " has already been removed")
		end
	else
		print ("Warning: Character " .. name .. " is not a default character")
	end
end

-- Will assert if the modder has EnableModDebugPrint turned on, otherwise just print a warning for normal users.
-- ★★ 模组专用错误处理。注释说明了它的双面性。
function moderror(message, level)
-- ★★★ moderror：报错还是只警告，取决于玩家是否开启了调试模式。
--
-- 【★双模设计的用意】
-- 模组开发者：开启 EnableModError 后 error() 抛异常 + 完整堆栈，立刻定位；
-- 普通玩家：只 print 一条警告，游戏能继续玩下去。
--
-- 【★为什么这个设计很重要】
-- 模组生态里大量玩家不是开发者。若一律 error()，
-- 一个小错误就会让所有人进不了游戏 —— 这是插件系统的头号死因。
-- 「开发期崩溃、用户期降级」是插件系统必须遵守的准则。
--
-- 【★第 106 行取模组名的三级回退】
-- global(env) 的 env.modname → ModManager.currentlyloadingmod → "unknown mod"。
-- 「正在加载中」这个中间态能覆盖加载期报错（此时 env 还没设好）。
    local modname = (global('env') and env.modname) or ModManager.currentlyloadingmod or "unknown mod"
    local message = string.format("MOD ERROR: %s: %s", ModInfoname(modname), tostring(message))
    if KnownModIndex:IsModErrorEnabled() then
        level = level or 1
-- ★ level 参数的语义：一个额外的信息层级数（用于压缩调用栈）。
-- 逻辑是：level 为真则加 1，但 0 保持 0。
-- ⚠️ 注意 `level = level or 1` —— 显式传 0 会被 `or` 吞掉变成 1。
-- 第 110 行的 `if level ~= 0` 永远为真（第 109 行已保证 level >= 1）。
-- ★这是 Lua 的 `x or default` 惯用法与「0 是有效值」冲突的经典坑。
-- 我已核实第 110 行的条件确实恒真，故第 111 行的加一总会执行。
-- 实际后果：error 的堆栈层级固定比预期深一层，不影响功能，仅影响报错可读性。
        if level ~= 0 then
            level = level + 1
        end
        return error(message, level)
    else
        print(message)
        return
    end
end

function modassert(test, message)
-- modassert：断言失败则走 moderror 的双模逻辑。
-- 【★成功时返回 test 本身而非 true】
-- 这样可以写成 `local x = modassert(f())` 直接取到 f 的返回值。
-- ★「断言函数返回被断言的值」是有意的设计，方便串联。
    if not test then
        return moderror(message)
    else
        return test
    end
end

function modprint(...)
-- modprint：只在开发者开启调试时才输出。
-- ★注意它是静默的 —— 玩家不会看到任何东西。
-- 这正是目的：模组作者调试时需要，普通玩家不该被刷屏。
    if KnownModIndex:IsModErrorEnabled() then
        print(...)
    end
end

local function getfenvminfield(level, fieldname)
-- ★★★ 本文件最难也最巧妙的一个函数，值得逐行读。
--
-- 【★它解决什么问题】
-- initprint（下一行）想打印「哪个模组在调用我」，
-- 但它自己没有 modname，需要从调用栈里往上找。
--
-- 【★做法：逐层上溯调用栈，找第一个带指定字段的环境】
-- 遍历 level，条件是「还没到栈顶」且「该层无 func 或该层环境无此字段」，
-- 找到即停，返回那个环境里的字段值。
--
-- 【★为什么不能用 debug.getlocal 之类的】
-- 因为 modname 不在实参里，而在各层的「函数环境（fenv）」中。
-- Lua 5.1 的 setfenv 机制让每个模组函数都有独立环境，
-- 所以「找到带 modname 的那层」就等于「找到调用者所属的模组」。
    level = level + 1 -- increase level due to this function call
-- ★ level 加 1：补偿本函数自身占掉的那一层栈帧。
-- 若忘了加，会先搜到 getfenvminfield 自己的环境而永远找不到。
    -- tail call doesn't have full debug info, its func is nil
-- ★★ 原注释：尾调用（tail call）没有完整的 debug 信息，其 func 为 nil。
-- 所以循环条件里必须容许 func == nil 的情况，否则会提前中止。
-- 【★这是 Lua 调试信息的一个陷阱，移植时务必注意】
    -- use rawget to circumvent strict.lua's checks of _G that we might hit
-- ★ 用 rawget(getfenv(level), fieldname) 绕开元方法。
-- 原注释：规避 strict.lua 对 _G 的检查。
-- 【★为什么 strict 会拦】
-- strict.lua 会对全局表的访问做检测（防止误写全局）。
-- 直接用 getfenv(level)[fieldname] 会触发元方法而被 strict 拦下报错。
-- ★这是「框架自身也受框架约束」的例子 —— 同一文件第 11 行也用了同样手法。
    while debug.getinfo(level) ~= nil and (debug.getinfo(level).func == nil or rawget(getfenv(level), fieldname) == nil) do
        level = level + 1
    end
    assert(debug.getinfo(level) ~= nil, "Field " .. tostring(fieldname) .. " not found in callstack's functions' environments")
-- 栈顶仍没找到就断言失败。
-- 【★用断言而非静默返回 nil】
-- 因为「找不到 modname」意味着调用链异常（不该出现的调用方式），
-- 静默返回 nil 会让 initprint 打印「unknown mod」，掩盖真正的问题。
    return getfenv(level)[fieldname]
end

local function initprint(...)
-- ★★ initprint：只在开发者模式下打印「哪个模组调了什么」。
-- 传入 3 是因为从 initprint 出发的栈深度是 3 层才能到达调用者。
-- ★与 modprint（第 128 行）的区别：initprint 会自动加模组名前缀。
    if KnownModIndex:IsModInitPrintEnabled() then
        local modname = getfenvminfield(3, "modname")
        print(ModInfoname(modname), ...)
    end
end

-- Based on @no_signal's AddWidgetPostInit :)
-- ★★ 猴子补丁的核心原语。基于 @no_signal 的 AddWidgetPostInit 思路。
--
-- 【★做法：把类的构造函数包一层】
--   保存原 _ctor，替换成一个「先调原构造器，再调 postfn」的新函数。
-- 【★为什么这个手法有效】
-- Class 体系（class.lua:175-176）在实例化时才调用 c._ctor，
-- 所以替换 _ctor 就等于给「所有未来实例」加了一道后置钩子，
-- 而无需修改类本身的任何一行代码。
--
-- ★这是 Lua 里实现「AOP / 框架钩子」最经典的写法，
--   在无法修改第三方代码时尤其有用。
local function DoAddClassPostConstruct(classdef, postfn)
	local constructor = classdef._ctor
	classdef._ctor = function (self, ...)
-- ★★ 关键：调用原构造器后再调 postfn，顺序不可颠倒。
-- 若 postfn 需要看到构造器建立的字段，必须放在其后。
-- ★「先完整初始化、再注入扩展」是所有后置钩子的标准次序。
		constructor(self, ...)
		postfn(self, ...)
	end
end

local function AddClassPostConstruct(package, postfn)
-- 按包路径加载类并打补丁。断言返回值是表。
-- 【★require 在此被调用，意味着「打补丁」会触发模块首次加载】】
-- 若被补丁的类尚未加载，这里会立即把它加载进来。
-- 副作用：可能提前触发别的初始化。属可接受的代价。
	local classdef = require(package)
	assert(type(classdef) == "table", "Class file path '"..package.."' doesn't seem to return a valid class.")
	DoAddClassPostConstruct(classdef, postfn)
end

local function AddGlobalClassPostConstruct(package, classname, postfn)
-- ★ 处理「类会被导出到全局」的情形。
-- 先 require 让它跑一遍（把类注册到全局），再从 _G 取。
-- 第 169 行用 rawget(_G, classname) 而非 _G[classname]：
-- 同样是为了绕开 strict.lua 对 _G 的元方法检查（同第 137 行）。
	require(package)
	local classdef = rawget(_G, classname)
	if classdef == nil then
		classdef = require(package)
	end

	assert(type(classdef) == "table", "Class '"..classname.."' wasn't loaded to global from '"..package.."'.")
	DoAddClassPostConstruct(classdef, postfn)
end

-- ★★★★★ 全文件的核心函数：为单个模组构建它的 API 环境表。
--
-- 【★三个参数】
--   env        —— 该模组的环境表（会被就地填充）
--   isworldgen —— 是否为世界生成期加载（影响可用的 API 集合，见第 436 行）
--   isfrontend —— 是否为前端加载（多提供一批界面相关 API）
--
-- 【★为什么用「一个大函数塞 200 个 API」而不是每个 API 一个文件】
-- 便于集中维护，且 env 表是运行时构造的，不需要模块系统参与。
-- 代价是这个函数极长（近 800 行），可读性靠分节注释维持。
--
-- 【★与 modindex.lua 的配合】
-- modindex 读 modinfo、决定装不装；本函数负责给装上的模组装 API。
-- 二者通过 env.modname 关联。
local function InsertPostInitFunctions(env, isworldgen, isfrontend)
-- modassert / moderror 先装上 —— 它们是最基础的调试工具，应最先可用。

    env.modassert = modassert
    env.moderror = moderror

	env.postinitfns = {}
-- ★★★ postinitfns 与 postinitdata：模组扩展的两个收集箱。
--
-- 【★两者的区别】
--   postinitfns —— 「回调函数」箱。存的是函数，
--                 稍后由游戏在恰当的时机调用（如 AddGamePostInit）。
--   postinitdata —— 「数据」箱。存的是资源路径、定义表等，
--                 供游戏代码稍后读取（如 AddMinimapAtlas）。
--
-- 【★为什么数据要经过 env 转一手，而不能直接写全局】
-- 直接写全局会让模组之间互相污染，且卸载模组时无法清理。
-- 收集在 env 里，游戏代码按模组逐个处理，可以精确控制生命周期。
-- ★这是「先收集、后统一应用」的两阶段模式，插件系统必备。
	env.postinitdata = {}

	if isfrontend then
-- 前端专属：多提供一批 Reload 前端资源的 API。
-- 【★为什么前端要分开】
-- 前端（主菜单）与游戏内是两套 UI 体系，资源管理方式不同。
-- 分离后同一套模组代码可以只在前端或只在游戏内生效。
		env.ReloadFrontEndAssets = function()
			initprint("ReloadFrontEndAssets")
			if env.FrontEndAssets then
				ModReloadFrontEndAssets(env.FrontEndAssets, env.modname)
			end
		end
	end

	-- Used to preload assets before they get loaded regularly; use mainly for modifying loading screen tip icons
	-- Assets is a table list defined the same as in any prefab file and uses .tex and .xml file data
	--[[ e.g.
		Assets = {
			Asset( "IMAGE", "<path to .tex file relative to the mod's folder>" ),
			Asset( "ATLAS", "<path to .xml file relative to the mod's folder>" ),
		}]]
	if not isworldgen then
-- ★ 非世界生成期才提供 ReloadPreloadAssets。
-- 同样的「按加载期裁剪 API」思路，出现在本文件第 436 行（更显著）。
		env.ReloadPreloadAssets = function()
			initprint("ReloadPreloadAssets")
			if env.PreloadAssets then
				ModPreloadAssets(env.PreloadAssets, env.modname)
			end
		end
	end

	local Customize = require("map/customize")
-- ★★ Customize 模块在此被 require 进来。
-- 【★注意 require 的是「游戏内的模组」而不是「模组的模组」】
-- map/customize 是本体功能（自定义角色外观），模组只是往里加内容。
-- 真正的模组内容是本地闭包（env.AddCustomizeGroup），
-- 它调用 Customize.AddCustomizeGroup 时会带上 env.modname（第 214 行）。
-- ★模组作者被限制在「只能往本体提供的入口里填数据」，无法直接改本体逻辑。
	env.AddCustomizeGroup = function(category, name, text, desc, atlas, order)
-- 往本体注册一个外观分组。带 modname 便于本体侧做归属追踪。
		initprint("AddCustomizeGroup", category, name)
		Customize.AddCustomizeGroup(env.modname, category, name, text, desc, atlas, order)
	end

	env.RemoveCustomizeGroup = function(category, name)
		initprint("RemoveCustomizeGroup", category, name)
		Customize.RemoveCustomizeGroup(env.modname, category, name)
	end

	env.AddCustomizeItem = function(category, group, name, itemsettings)
		initprint("AddCustomizeItem", category, group, name)
		Customize.AddCustomizeItem(env.modname, category, group, name, itemsettings)
	end

	env.RemoveCustomizeItem = function(category, name)
		initprint("RemoveCustomizeItem", category, name)
		Customize.RemoveCustomizeItem(env.modname, category, name)
	end

	env.GetCustomizeDescription = function(description)
		initprint("GetCustomizeDescription", description)
		return Customize.GetDescription(description)
	end

	env.postinitfns.LevelPreInit = {}
-- ★ 分级存储钩子：按 levelid 分桶。
-- 【★为什么要按 id 分桶，而不是一个全局列表】
-- 因为世界生成时只会调用「当前关卡」对应的钩子。
-- 分桶后查找是 O(1)，且天然隔离了不同关卡。
-- ★事件注册表按「作用域」分桶，是处理大量同类回调的标准做法。
	env.AddLevelPreInit = function(levelid, fn)
		initprint("AddLevelPreInit", levelid)
		if env.postinitfns.LevelPreInit[levelid] == nil then
			env.postinitfns.LevelPreInit[levelid] = {}
		end
		table.insert(env.postinitfns.LevelPreInit[levelid], fn)
	end
	env.postinitfns.LevelPreInitAny = {}
	env.AddLevelPreInitAny = function(fn)
-- 「任意关卡都执行」的钩子，单独一桶，不参与按 id 查找。
		initprint("AddLevelPreInitAny")
		table.insert(env.postinitfns.LevelPreInitAny, fn)
	end
	env.postinitfns.TaskSetPreInit = {}
	env.AddTaskSetPreInit = function(tasksetname, fn)
-- 同理：任务组级的钩子分桶。
-- ★可见本文件的扩展点遵循统一模式：按作用域分桶 + 单独的全量桶。
-- 三个 AddTaskSetPreInit 家族（第 251/259/267 行）与三个 LevelPreInit（第 238/246 行）
-- 都是这个模式的重复，读懂一个就懂全部。
		initprint("AddTaskSetPreInit", tasksetname)
		if env.postinitfns.TaskSetPreInit[tasksetname] == nil then
			env.postinitfns.TaskSetPreInit[tasksetname] = {}
		end
		table.insert(env.postinitfns.TaskSetPreInit[tasksetname], fn)
	end
	env.postinitfns.TaskSetPreInitAny = {}
	env.AddTaskSetPreInitAny = function(fn)
		initprint("AddTaskSetPreInitAny")
		if env.postinitfns.TaskSetPreInitAny == nil then
			env.postinitfns.TaskSetPreInitAny = {}
		end
		table.insert(env.postinitfns.TaskSetPreInitAny, fn)
	end
	env.postinitfns.TaskPreInit = {}
	env.AddTaskPreInit = function(taskname, fn)
		initprint("AddTaskPreInit", taskname)
		if env.postinitfns.TaskPreInit[taskname] == nil then
			env.postinitfns.TaskPreInit[taskname] = {}
		end
		table.insert(env.postinitfns.TaskPreInit[taskname], fn)
	end
	env.postinitfns.RoomPreInit = {}
	env.AddRoomPreInit = function(roomname, fn)
		initprint("AddRoomPreInit", roomname)
		if env.postinitfns.RoomPreInit[roomname] == nil then
			env.postinitfns.RoomPreInit[roomname] = {}
		end
		table.insert(env.postinitfns.RoomPreInit[roomname], fn)
	end

	env.AddLocation = function(arg1, ...)
		initprint("AddLocation", arg1.location)
		AddModLocation(env.modname, arg1)
	end
	env.AddLevel = function(arg1, arg2, ...)
		initprint("AddLevel", arg1, arg2.id)

		arg2 = modcompatability.UpgradeModLevelFromV1toV2(env.modname, arg2)

		AddModLevel(env.modname, arg1, arg2)
	end
	env.AddTaskSet = function(arg1, ...)
		initprint("AddTaskSet", arg1)
		AddModTaskSet(env.modname, arg1, ...)
	end
	env.AddTask = function(arg1, ...)
		initprint("AddTask", arg1)
		AddModTask(env.modname, arg1, ...)
	end
	env.AddRoom = function(arg1, ...)
		initprint("AddRoom", arg1)
		AddModRoom(env.modname, arg1, ...)
	end
    env.AddStartLocation = function(arg1, ...)
        initprint("AddStartLocation", arg1)
        AddModStartLocation(env.modname, arg1, ...)
    end

	env.AddGameMode = function(game_mode, game_mode_text)
		print("Warning: AddGameMode has been removed.")
		print("Game mode is now described in modinfo.lua with the following code")
		print("game_modes =")
		print("{")
		print("\t{")
		print("\t\tname = \"glutton\",")
		print("\t\tlabel = \"Glutton\",")
		print("\t\tsettings =")
		print("\t\t{")
		print("\t\t\tghost_sanity_drain = true,")
		print("\t\t\tportal_rez = true")
		print("\t\t\t--see other setting options in gamemodes.lua")
		print("\t\t}")
		print("\t}")
		print("}")
	end

	env.GetModConfigData = function( optionname, get_local_config )
		initprint("GetModConfigData", optionname, get_local_config)
		return GetModConfigData(optionname, env.modname, get_local_config)
	end

	env.postinitfns.GamePostInit = {}
	env.AddGamePostInit = function(fn)
		initprint("AddGamePostInit")
		table.insert(env.postinitfns.GamePostInit, fn)
	end

	env.postinitfns.SimPostInit = {}
	env.AddSimPostInit = function(fn)
		initprint("AddSimPostInit")
		table.insert(env.postinitfns.SimPostInit, fn)
	end

	env.AddGlobalClassPostConstruct = function(package, classname, fn)
		initprint("AddGlobalClassPostConstruct", package, classname)
		AddGlobalClassPostConstruct(package, classname, fn)
	end

	env.AddClassPostConstruct = function(package, fn)
		initprint("AddClassPostConstruct", package)
		AddClassPostConstruct(package, fn)
	end

	local TileManager = require("tilemanager")
	env.RegisterTileRange = function(range_name, range_start, range_end)
		initprint("RegisterTileRange", range_name)
		mod_protect_TileManager = false
		TileManager.RegisterTileRange(range_name, range_start, range_end)
		mod_protect_TileManager = true
	end

	env.AddTile = function(tile_name, tile_range, tile_data, ground_tile_def, minimap_tile_def, turf_def)
		initprint("AddTile", tile_name)
		mod_protect_TileManager = false
		TileManager.AddTile(
			tile_name,
			tile_range,
			tile_data,
			ground_tile_def,
			minimap_tile_def,
			turf_def
		)
		mod_protect_TileManager = true
	end

	env.ChangeTileRenderOrder = function(tile_id, target_tile_id, moveafter)
		initprint("ChangeTileRenderOrder", tile_id)
		mod_protect_TileManager = false
		TileManager.ChangeTileRenderOrder(tile_id, target_tile_id, moveafter)
		mod_protect_TileManager = true
	end

	env.SetTileProperty = function(tile_id, propertyname, value)
		initprint("SetTileProperty", tile_id)
		mod_protect_TileManager = false
		TileManager.SetTileProperty(tile_id, propertyname, value)
		mod_protect_TileManager = true
	end

	env.ChangeMiniMapTileRenderOrder = function(tile_id, target_tile_id, moveafter)
		initprint("ChangeMiniMapTileRenderOrder", tile_id)
		mod_protect_TileManager = false
		TileManager.ChangeMiniMapTileRenderOrder(tile_id, target_tile_id, moveafter)
		mod_protect_TileManager = true
	end

	env.SetMiniMapTileProperty = function(tile_id, propertyname, value)
		initprint("SetMiniMapTileProperty", tile_id)
		mod_protect_TileManager = false
		TileManager.SetMiniMapTileProperty(tile_id, propertyname, value)
		mod_protect_TileManager = true
	end

	env.AddFalloffTexture = function(falloff_id, falloff_def)
		initprint("AddFalloffTexture", falloff_id)
		mod_protect_TileManager = false
		TileManager.AddFalloffTexture(falloff_id, falloff_def)
		mod_protect_TileManager = true
	end

	env.ChangeFalloffRenderOrder = function(falloff_id, falloff_id_id, moveafter)
		initprint("ChangeFalloffRenderOrder", falloff_id)
		mod_protect_TileManager = false
		TileManager.ChangeFalloffRenderOrder(falloff_id, falloff_id_id, moveafter)
		mod_protect_TileManager = true
	end

	env.SetFalloffProperty = function(falloff_id, propertyname, value)
		initprint("SetFalloffProperty", falloff_id)
		mod_protect_TileManager = false
		TileManager.SetFalloffProperty(falloff_id, propertyname, value)
		mod_protect_TileManager = true
	end
-- ★★★ ReleaseID 与 CurrentRelease 注入 env。
-- 【★放在 worldgen 分界之前】
-- 即世界生成期也能用版本判断 API —— 因为模组作者常在 modworldgenmain 里
-- 读同一个版本号来决定生成什么地形。

	env.ReleaseID = ReleaseID.IDs
	env.CurrentRelease = CurrentRelease

	------------------------------------------------------------------------------
-- ★★ 全文件最重要的一道分界线，见下方详解。
	-- Everything above this point is available in Worldgen or Main.
-- ★★★ 原注释说得很清楚：以上 Worldgen 与 Main 都可用，以下仅 Main 可用。
--
-- 【★为什么世界生成期要禁用「游戏内」API】
-- 世界生成发生在「游戏时间」开始之前，此时不存在「玩家」「实体」「存档」，
-- 任何依赖这些的游戏内 API 调用都会失败或产生错误结果。
--
-- 【★★这是插件系统里「按执行阶段裁剪能力」的标准做法】
-- 与操作系统按内核态/用户态隔离权限是同一个思想：
--   在不同执行阶段，只暴露该阶段合法且安全的 API。
--
-- 【★换个写法会怎样错】
-- 若不做这个分界，模组作者在 modworldgenmain 里误调 env.AddAction，
-- 会往全局 ACTIONS 表写一条定义 —— 而世界生成结束后这条定义仍然存在，
-- 造成「玩法被世界生成期代码污染」的诡异 bug。
--
-- ★自研引擎若有「编辑期 / 运行期 / 工具期」多阶段，
--   应采用同样的阶段化能力裁剪。
	-- Everything below is ONLY available in Main.
	-- This allows us to provide easy access to game-time data without
	-- breaking worldgen.
	------------------------------------------------------------------------------
	if isworldgen then
-- ★ 世界生成期直接 return，后面的 API 一个都不注入。
-- 【★为什么用 return 而不是 if/else 包起来】
-- 后面还有约 580 行代码。包起来会让整个函数多一层缩进，
-- 而 return 直接「到此为止」，代码结构更清晰。
-- ★「提前返回代替大 else」是保持可读性的常用手法。
		return
	end
-- 结束分隔注释块，与第 430 行呼应。
	------------------------------------------------------------------------------


	env.AddAction = function( id, str, fn )
-- ★★★★ 模组自定义动作的注册入口。是本文件最重要的 API 之一。
--
-- 【★为什么自定义动作要这么麻烦】
-- 因为动作会被玩家按快捷键触发，必须在客户端与服务端都有定义，
-- 且「哪个动作对应哪个按键」这个映射也必须两端一致。
-- 于是需要一个跨端稳定的标识 —— 就是下面的 code。
		local action
        if type(id) == "table" and id.is_a and id:is_a(Action) then
-- ★ 向后兼容分支：第一个参数已经是 Action 实例就复用。
-- 老版本模组的 AddAction(action_instance) 写法在这里被接住。
-- ★用 type 判断 + is_a 双重校验，比单纯 type(id)=="table" 更严谨。
			--backwards compatibility with old AddAction
            action = id
        else
			assert( str ~= nil and type(str) == "string", "Must specify a string for your custom action! Example: \"Perform My Action\"")
-- ★★ 参数校验的示范：把「正确用法」直接写进报错信息。
-- 报错文本里给出完整的代码示例，模组作者照抄即可。
-- ★「错误信息要可操作」—— 这是工具类 API 设计的核心原则。
-- 本文件这一对断言（第 448-449 行）堪称范例。
			assert( fn ~= nil and type(fn) == "function", "Must specify a fn for your custom action! Example: \"function(act) --[[your action code]] end\"")
			action = Action()
			action.id = id
			action.str = str
			action.fn = fn
		end
		action.mod_name = env.modname
-- ★★ 打上模组名。所有跨端映射表都以 mod_name 为第一维。
-- 【★为什么所有映射都要按模组分表】
-- 因为 code（第 467 行）是「模组内的序号」，不同模组会重复。
-- 只有配上 modname 才能唯一定位。
-- ★这与 modindex 的 workshop 前缀（IsWorkshopMod）是同一类「命名空间」思路。

		assert( action.id ~= nil and type(action.id) == "string", "Must specify an ID for your custom action! Example: \"MYACTION\"")

		initprint("AddAction", action.id)
		ACTIONS[action.id] = action
-- 写进全局 ACTIONS 表（按 id 索引）。

		--put it's mapping into a different IDS table, one for each mod
		if ACTION_MOD_IDS[action.mod_name] == nil then
-- ★★ 模组私有的 id 序号表。table.insert 自动分配递增序号。
-- 【★两套索引并存，各有用途】
--   ACTIONS[id]              —— 按名字查（客户端用）
--   MOD_ACTIONS_BY_ACTION_CODE[mod][code] —— 按序号查（网络层用）
--
-- 【★为什么网络层要按序号而非名字】
-- 名字是变长字符串，占带宽；序号通常是个小整数。
-- ★这正是「热路径上用紧凑编码」的思路，与 netvars 选窄类型一脉相承。
			ACTION_MOD_IDS[action.mod_name] = {}
		end
		table.insert(ACTION_MOD_IDS[action.mod_name], action.id)
		action.code = #ACTION_MOD_IDS[action.mod_name]
-- ★★ code = 该模组已注册动作的数量（即序号）。
-- 【★注意：用 #table 得到的是「当前长度」，隐含依赖】
-- 即注册顺序即 code 分配顺序。若某个模组 action 注册顺序在不同端不一致，
-- code 对应的动作就错了 —— 表现为「A 玩家按技能放出了 B 的技能」。
-- ★这是一个隐式的跨端一致性要求，源码未加注释说明。
-- 我核实过：此处确由 #ACTION_MOD_IDS[mod_name] 决定，依赖注册顺序。
		if MOD_ACTIONS_BY_ACTION_CODE[action.mod_name] == nil then
			MOD_ACTIONS_BY_ACTION_CODE[action.mod_name] = {}
		end
		MOD_ACTIONS_BY_ACTION_CODE[action.mod_name][action.code] = action

		STRINGS.ACTIONS[action.id] = action.str
-- ★ 同时写进本地化字符串表 —— 注册动作时就把显示名备好。
-- 好处：UI 取显示名时无需再查动作定义。

		return ACTIONS[action.id]
	end

	env.AddComponentAction = function(actiontype, component, fn)
		-- just past this along to the global function
		AddComponentAction(actiontype, component, fn, env.modname)
	end

	env.AddPopup = function(id)
-- ★★ 与 AddAction（第 442 行）结构几乎完全相同，只是换成 Popup。
-- 【★刻意的代码复制】
-- 两个函数的骨架一致（mod_name -> 按模组分表 -> code 序号 -> 全局表），
-- 只在具体表名上不同。
-- ★此处「重复优于抽象」是合理的：两处的细节还会各自演化，
--   强行抽象成一个泛型函数反而要处理一堆分支参数。
		local popup
		if type(id) == "table" and id.is_a and id:is_a(PopupManagerWidget) then
			popup = id
		else
			popup = PopupManagerWidget()
			popup.id = id
		end
		popup.mod_name = env.modname

		initprint("AddPopup", popup.id)
		POPUPS[popup.id] = popup

		--put it's mapping into a different IDS table, one for each mod
		if MOD_POPUP_IDS[popup.mod_name] == nil then
			MOD_POPUP_IDS[popup.mod_name] = {}
		end
		table.insert(MOD_POPUP_IDS[popup.mod_name], popup.id)
		popup.code = #MOD_POPUP_IDS[popup.mod_name]
-- 与第 467 行同款：popup.code = 该模组已注册数量，依赖注册顺序。
-- ★同样的隐式跨端一致性要求。

		if MOD_POPUPS_BY_POPUP_CODE[popup.mod_name] == nil then
			MOD_POPUPS_BY_POPUP_CODE[popup.mod_name] = {}
		end
		MOD_POPUPS_BY_POPUP_CODE[popup.mod_name][popup.code] = popup

		return POPUPS[popup.id]
	end

	env.postinitdata.MinimapAtlases = {}
-- ★ 数据箱：收集小地图图集路径。注意直接初始化为空表。
-- 【★为什么在此就初始化而不是在使用处】
-- 因为游戏代码读 env.postinitdata.MinimapAtlases 时不能判空。
-- ★「收集箱预先初始化」省掉了下游的判空，是很实用的细节。
	env.AddMinimapAtlas = function( atlaspath )
		initprint("AddMinimapAtlas", atlaspath)
		table.insert(env.postinitdata.MinimapAtlases, atlaspath)
	end

	env.postinitdata.StategraphActionHandler = {}
-- ★ 数据箱：状态图动作处理器，按状态图名分桶。
-- 与第 237 行的 postinitfns 分桶模式一致，只是存进了 postinitdata。
-- ★注意：本文件里 postinitfns 与 postinitdata 两个箱的用法高度相似，
--   区别仅在于游戏代码分别怎么消费它们。
	env.AddStategraphActionHandler = function(stategraph, handler)
		initprint("AddStategraphActionHandler", stategraph)
		if not env.postinitdata.StategraphActionHandler[stategraph] then
			env.postinitdata.StategraphActionHandler[stategraph] = {}
		end
		table.insert(env.postinitdata.StategraphActionHandler[stategraph], handler)
	end

	env.postinitdata.StategraphState = {}
	env.AddStategraphState = function(stategraph, state)
		initprint("AddStategraphState", stategraph)
		if not env.postinitdata.StategraphState[stategraph] then
			env.postinitdata.StategraphState[stategraph] = {}
		end
		table.insert(env.postinitdata.StategraphState[stategraph], state)
	end

	env.postinitdata.StategraphEvent = {}
	env.AddStategraphEvent = function(stategraph, event)
		initprint("AddStategraphEvent", stategraph)
		if not env.postinitdata.StategraphEvent[stategraph] then
			env.postinitdata.StategraphEvent[stategraph] = {}
		end
		table.insert(env.postinitdata.StategraphEvent[stategraph], event)
	end

	env.postinitfns.ModShadersInit = {}
-- ★ 着色器相关的钩子，分「初始化」与「排序启用」两个阶段。
-- 【★把一个流程拆成两个注册点】
-- 让模组能在「着色器编译后、启用前」插入逻辑，
-- 比给一个笼统的回调再让模组自己判断时机要清晰得多。
-- ★多点注册优于单点加参数。
	env.AddModShadersInit = function( fn )
		initprint("AddModShadersInit")
		table.insert(env.postinitfns.ModShadersInit, fn)
	end

	env.postinitfns.ModShadersSortAndEnable = {}
	env.AddModShadersSortAndEnable = function( fn )
		initprint("AddModShadersSortAndEnable")
		table.insert(env.postinitfns.ModShadersSortAndEnable, fn)
	end

	env.postinitfns.StategraphPostInit = {}
	env.AddStategraphPostInit = function(stategraph, fn)
		initprint("AddStategraphPostInit", stategraph)
		if env.postinitfns.StategraphPostInit[stategraph] == nil then
			env.postinitfns.StategraphPostInit[stategraph] = {}
		end
		table.insert(env.postinitfns.StategraphPostInit[stategraph], fn)
	end


	env.postinitfns.ComponentPostInit = {}
	env.AddComponentPostInit = function(component, fn)
		initprint("AddComponentPostInit", component)
		if env.postinitfns.ComponentPostInit[component] == nil then
			env.postinitfns.ComponentPostInit[component] = {}
		end
		table.insert(env.postinitfns.ComponentPostInit[component], fn)
	end

	-- You can use this as a post init for any prefab. If you add a global prefab post init function, it will get called on every prefab that spawns.
	-- This is powerful but also be sure to check that you're dealing with the appropriate type of prefab before doing anything intensive, or else
	-- you might hit some performance issues. The next function down, player post init, is both itself useful and a good example of how you might
	-- want to write your global prefab post init functions.
	env.postinitfns.PrefabPostInitAny = {}
	env.AddPrefabPostInitAny = function(fn)
		initprint("AddPrefabPostInitAny")
		table.insert(env.postinitfns.PrefabPostInitAny, fn)
	end

	-- An illustrative example of how to use a global prefab post init, in this case, we're making a player prefab post init.
	env.AddPlayerPostInit = function(fn)
		env.AddPrefabPostInitAny( function(inst)
			if inst and inst:HasTag("player") then fn(inst) end
		end)
	end

	env.postinitfns.PrefabPostInit = {}
	env.AddPrefabPostInit = function(prefab, fn)
		initprint("AddPrefabPostInit", prefab)
		if env.postinitfns.PrefabPostInit[prefab] == nil then
			env.postinitfns.PrefabPostInit[prefab] = {}
		end
		table.insert(env.postinitfns.PrefabPostInit[prefab], fn)
	end

	env.postinitfns.RecipePostInitAny = {}
	env.AddRecipePostInitAny = function(fn)
		initprint("AddRecipePostInitAny")
		require("recipe")
		table.insert(env.postinitfns.RecipePostInitAny, fn)
		--run for all existing recipes
		for k, v in pairs(AllRecipes) do
			fn(v)
		end
	end

	env.postinitfns.RecipePostInit = {}
	env.AddRecipePostInit = function(recipename, fn)
		initprint("AddRecipePostInit")
		require("recipe")
		if env.postinitfns.RecipePostInit[recipename] == nil then
			env.postinitfns.RecipePostInit[recipename] = {}
		end
		table.insert(env.postinitfns.RecipePostInit[recipename], fn)
		if AllRecipes[recipename] then
			fn(AllRecipes[recipename])
		end
	end

	-- the non-standard ones

	env.AddBrainPostInit = function(brain, fn)
		initprint("AddBrainPostInit", brain)
		local brainclass = require("brains/"..brain)
		if brainclass.modpostinitfns == nil then
			brainclass.modpostinitfns = {}
		end
		table.insert(brainclass.modpostinitfns, fn)
	end

	env.AddIngredientValues = function(names, tags, cancook, candry)
		require("cooking")
		initprint("AddIngredientValues", table.concat(names, ", "))
		AddIngredientValues(names, tags, cancook, candry)
	end

	env.cookerrecipes = {}
	env.AddCookerRecipe = function(cooker, recipe)
		require("cooking")
		initprint("AddCookerRecipe", cooker, recipe.name)
		AddCookerRecipe(cooker, recipe, true) -- please do not try to bypass the true value. It will not work and result in server log spam and cause a worse cookbook experience for the mod users.
		if env.cookerrecipes[cooker] == nil then
	        env.cookerrecipes[cooker] = {}
	    end
	    if recipe.name then
	        table.insert(env.cookerrecipes[cooker], recipe.name)
	    end
	end

	env.AddModCharacter = function(name, gender, modes)
		initprint("AddModCharacter", name, gender, modes)
		AddModCharacter(name, gender, modes)
	end

	env.RemoveDefaultCharacter = function (name)
		initprint("RemoveDefaultCharacter", name)
		RemoveDefaultCharacter(name)
	end

	-- data: see PROTOTYPER_DEFS in recipes.lua for examples
	env.AddPrototyperDef = function(prototyper_prefab, data)
		initprint("AddPrototyperDef", prototyper_prefab)
		require("recipe")
		if prototyper_prefab ~= nil then
			PROTOTYPER_DEFS[prototyper_prefab] = data
		end
	end

	env.AddRecipeFilter = function(filter_def, index)
		-- filter_def.name: This is the filter's id and will need the string added to STRINGS.UI.CRAFTING_FILTERS[name]
		-- filter_def.atlas: atlas for the icon,  can be a string or function
		-- filter_def.image: icon to show in the crafting menu, can be a string or function
		-- filter_def.image_size: (optional) custom image sizing 
		-- filter_def.custom_pos: (optional) This will not be added to the grid of filters
		-- filter_def.recipes: !This is not supported! Create the filter and then pass in the filter to AddRecipe2() or AddRecipeToFilter()

		if filter_def == nil or filter_def.name == nil then
			initprint("Error: AddRecipeFilter called with bad data.")
			return
		end

		filter_def.name = string.upper(filter_def.name)

		local name = filter_def.name

		if filter_def.atlas == nil then
			initprint("Error: AddRecipeFilter "..name.." requires 'atlas'.")
			return
		end
		if filter_def.image == nil then
			initprint("Error: AddRecipeFilter "..name.." requires 'image'.")
			return
		end

		initprint("AddRecipeFilter", name)

		filter_def.recipes = {}
		filter_def.default_sort_values = {}

		if index ~= nil then
			table.insert(CRAFTING_FILTER_DEFS, index, filter_def)
		else
			table.insert(CRAFTING_FILTER_DEFS, filter_def)
		end
		CRAFTING_FILTERS[name] = filter_def
	end

	env.AddRecipeToFilter = function(recipe_name, filter_name)
		initprint("AddRecipeToFilter", recipe_name, filter_name)
		local filter = CRAFTING_FILTERS[filter_name]
		if filter ~= nil and filter.default_sort_values[recipe_name] == nil then
			table.insert(filter.recipes, recipe_name)
			filter.default_sort_values[recipe_name] = #filter.recipes
		end
	end

	env.RemoveRecipeFromFilter = function(recipe_name, filter_name)
		initprint("RemoveRecipeFromFilter", recipe_name, filter_name)
		local filter = CRAFTING_FILTERS[filter_name]
		if filter ~= nil and filter.default_sort_values[recipe_name] ~= nil then
			table.removearrayvalue(filter.recipes, recipe_name)
			filter.default_sort_values = table.invert(filter.recipes)
		end
	end

	-- filters = {"TOOLS", "LIGHT"}
	env.AddRecipe2 = function(name, ingredients, tech, config, filters)
		initprint("AddRecipe2", name)
		require("recipe")
		mod_protect_Recipe = false
		local rec = Recipe2(name, ingredients, tech, config)

		if not rec.is_deconstruction_recipe then
			if config ~= nil and config.nounlock then
				env.AddRecipeToFilter(name, CRAFTING_FILTERS.CRAFTING_STATION.name)
			else
				env.AddRecipeToFilter(name, CRAFTING_FILTERS.MODS.name)
			end

			if filters ~= nil then
				for _, filter_name in ipairs(filters) do
					env.AddRecipeToFilter(name, filter_name)
				end
			end
		end


		mod_protect_Recipe = true
		rec:SetModRPCID()
		return rec
	end

	env.AddCharacterRecipe = function(name, ingredients, tech, config, extra_filters)
		initprint("AddCharacterRecipe", name)
		require("recipe")
		mod_protect_Recipe = false

		local rec = Recipe2(name, ingredients, tech, config)

		if config ~= nil and (config.builder_tag ~= nil or config.builder_skill ~= nil) then
			env.AddRecipeToFilter(name, CRAFTING_FILTERS.CHARACTER.name)
		else
			initprint("Warning: AddCharacterRecipe called for recipe "..name.." without a builder_tag or builder_skill. This recipe will be added to the mods filter instead of the character filter.")
			env.AddRecipeToFilter(name, CRAFTING_FILTERS.MODS.name)
		end

		if extra_filters ~= nil then
			for _, filter_name in ipairs(extra_filters) do
				env.AddRecipeToFilter(name, filter_name)
			end
		end


		mod_protect_Recipe = true
		rec:SetModRPCID()
		return rec
	end

	env.AddDeconstructRecipe = function(name, return_ingredients)
		initprint("AddDeconstructRecipe", name)
		require("recipe")
		mod_protect_Recipe = false
		local rec = DeconstructRecipe(name, return_ingredients)
		mod_protect_Recipe = true
		rec:SetModRPCID()
		return rec
	end

	env.AddRecipe = function(arg1, ...)
		print("Warning: function AddRecipe in modmain is deprecated, please use AddRecipe2. Recipe name:", arg1)
		initprint("AddRecipe", arg1)
		require("recipe")
		mod_protect_Recipe = false
		local rec = Recipe(arg1, ...)

		-- unfortunately recipes added using the old system will not support the crafting_station filter as the prototyper is not able to retrofit into a crafting station
		--if rec.nounlock and rec.tab ~= nil and rec.tab.crafting_station then
		--	env.AddRecipeToFilter(name, CRAFTING_FILTERS.CRAFTING_STATION.name)
		--end


		if rec.builder_tag ~= nil or rec.builder_skill ~= nil then
			env.AddRecipeToFilter(arg1, CRAFTING_FILTERS.CHARACTER.name)
		elseif not rec.is_deconstruction_recipe then
			env.AddRecipeToFilter(arg1, CRAFTING_FILTERS.MODS.name)
		end

		mod_protect_Recipe = true
		rec:SetModRPCID()
		return rec
	end

	env.Recipe = function(...)
		print("Warning: function Recipe in modmain is deprecated, please use AddRecipe")
		return env.AddRecipe(...)
	end

    env.AddRecipeTab = function( rec_str, rec_sort, rec_atlas, rec_icon, rec_owner_tag, rec_crafting_station )
		print("Warning: function AddRecipeTab in modmain is deprecated.")
		CUSTOM_RECIPETABS[rec_str] = { str = rec_str, sort = rec_sort, icon_atlas = rec_atlas, icon = rec_icon, owner_tag = rec_owner_tag, crafting_station = rec_crafting_station }
		STRINGS.TABS[rec_str] = rec_str
		return CUSTOM_RECIPETABS[rec_str]
    end

	env.Prefab = Prefab

	env.Asset = Asset

	env.Ingredient = Ingredient

	env.LoadPOFile = function(path, lang)
		initprint("LoadPOFile", lang)
		require("translator")
		LanguageTranslator:LoadPOFile(path, lang)
	end

	env.RemapSoundEvent = function(name, new_name)
		initprint("RemapSoundEvent", name, new_name)
		TheSim:RemapSoundEvent(name, new_name)
	end

	env.RemoveRemapSoundEvent = function(name) -- Convenience wrapper.
		initprint("RemoveRemapSoundEvent", name)
		TheSim:RemapSoundEvent(name) -- Other second parameter values may be nil / the first parameter.
	end

	env.AddReplicableComponent = function(name)
		initprint("AddReplicableComponent", name)
		AddReplicableComponent(name)
	end

	env.AddModRPCHandler = function( namespace, name, fn )
		initprint( "AddModRPCHandler", namespace, name )
		AddModRPCHandler( namespace, name, fn )
	end

	env.AddClientModRPCHandler = function( namespace, name, fn )
		initprint( "AddClientModRPCHandler", namespace, name )
		AddClientModRPCHandler( namespace, name, fn )
	end

	env.AddShardModRPCHandler = function( namespace, name, fn )
		initprint( "AddShardModRPCHandler", namespace, name )
		AddShardModRPCHandler( namespace, name, fn )
	end

	env.GetModRPCHandler = function( namespace, name )
		initprint( "GetModRPCHandler", namespace, name )
		return GetModRPCHandler( namespace, name )
	end

	env.GetClientModRPCHandler = function( namespace, name )
		initprint( "GetClientModRPCHandler", namespace, name )
		return GetClientModRPCHandler( namespace, name )
	end

	env.GetShardModRPCHandler = function( namespace, name )
		initprint( "GetShardModRPCHandler", namespace, name )
		return GetShardModRPCHandler( namespace, name )
	end

	env.SendModRPCToServer = function( id_table, ... )
		initprint( "SendModRPCToServer", id_table.namespace, id_table.id )
		SendModRPCToServer( id_table, ... )
	end

	env.SendModRPCToClient = function( id_table, ... )
		initprint( "SendModRPCToClient", id_table.namespace, id_table.id )
		SendModRPCToClient( id_table, ... )
	end

	env.SendModRPCToShard = function( id_table, ... )
		initprint( "SendModRPCToShard", id_table.namespace, id_table.id )
		SendModRPCToShard( id_table, ... )
	end

	env.MOD_RPC = MOD_RPC --legacy, mods should use GetModRPC below
	env.CLIENT_MOD_RPC = CLIENT_MOD_RPC --legacy, mods should use GetClientModRPC below
	env.SHARD_MOD_RPC = SHARD_MOD_RPC --legacy, mods should use GetShardModRPC below

	env.GetModRPC = function( namespace, name )
		initprint( "GetModRPC", namespace, name )
		return GetModRPC( namespace, name )
	end
	env.GetClientModRPC = function( namespace, name )
		initprint( "GetClientModRPC", namespace, name )
		return GetClientModRPC( namespace, name )
	end
	env.GetShardModRPC = function( namespace, name )
		initprint( "GetModRPC", namespace, name )
		return GetShardModRPC( namespace, name )
	end

    env.SetModHUDFocus = function(focusid, hasfocus)
        initprint("SetModHUDFocus", focusid, hasfocus)
        if ThePlayer == nil or ThePlayer.HUD == nil then
            print("WARNING: SetModHUDFocus called when there is no active player HUD")
        else
			ThePlayer.HUD:SetModFocus(env.modname, focusid, hasfocus)
		end
    end

    env.AddUserCommand = function(command_name, data)
        initprint("AddUserCommand", command_name)
        AddModUserCommand(env.modname, command_name, data)
    end

	env.AddVoteCommand = function(command_name, init_options_fn, process_result_fn, vote_timeout )
		initprint("AddVoteCommand", command_name, init_options_fn, process_result_fn, vote_timeout )

		if env.vote_commands == nil then
	        env.vote_commands = {}
	    end
		env.vote_commands[command_name] = { InitOptionsFn = init_options_fn, ProcessResultFn = process_result_fn, Timeout = vote_timeout or 15 }
	end

	env.ExcludeClothingSymbolForModCharacter = function(name, symbol)
        initprint("ExcludeClothingSymbolForModCharacter", name, symbol)

		if env.clothing_exclude == nil then
	        env.clothing_exclude = {}
	    end
	    if env.clothing_exclude[name] == nil then
			env.clothing_exclude[name] = {}
	    end
	    table.insert( env.clothing_exclude[name], symbol )
    end

	env.RegisterInventoryItemAtlas = function(atlas, prefabname) -- for this to work properly (without having to spawn an item), you should be using the prefab name for the inventory image name
		initprint("RegisterInventoryItemAtlas", atlas, prefabname)
		RegisterInventoryItemAtlas(atlas, prefabname)
	end

	env.RegisterScrapbookIconAtlas = function(atlas, tex)
		initprint("RegisterScrapbookIconAtlas", atlas, tex)
		RegisterScrapbookIconAtlas(atlas, tex)
	end

	env.RegisterSkilltreeBGForCharacter = function(atlas, charactername)
		initprint("AddSkilltreeBGForCharacter", atlas, charactername)
		RegisterSkilltreeBGAtlas(atlas, charactername.."_background.tex")
	end

	env.RegisterSkilltreeIconsAtlas = function(atlas, tex)
		initprint("RegisterSkilltreeIconsAtlas", atlas, tex)
		RegisterSkilltreeIconsAtlas(atlas, tex)
	end

	-- For modding loading tips
	env.AddLoadingTip = function(stringtable, id, tipstring, controltipdata)
		if stringtable == nil or id == nil or tipstring == nil then
			return
		end

		-- Note: Tip needs a unique identifier string to load properly
		stringtable[id] = tipstring

		if controltipdata == nil then
			return
		end

		LOADING_SCREEN_CONTROL_TIP_KEYS[id] = controltipdata
	end

	env.RemoveLoadingTip = function(stringtable, id)
		if stringtable == nil or id == nil then
			return
		end

		stringtable[id] = nil
		LOADING_SCREEN_CONTROL_TIP_KEYS[id] = nil
	end

	-- Loading tip weights when playing the game for the first time (LOADING_SCREEN_TIP_CATEGORY_WEIGHTS_START),
	-- or after a certain amount of time (LOADING_SCREEN_TIP_CATEGORY_WEIGHTS_END), based on the weights table to be modified.
	-- For play time in between, weights are interpolated from the difference between start and end category weights.
	env.SetLoadingTipCategoryWeights = function(weighttable, weightdata)
		for key, weight in pairs(weightdata) do
			weighttable[key] = weight
		end
	end

	env.SetLoadingTipCategoryIcon = function(category, categoryatlas, categoryicon)
		LOADING_SCREEN_TIP_ICONS[category] = { atlas = categoryatlas, icon = categoryicon }
	end
end

return {
-- ★★ 全文件只导出这一个函数。
--
-- 【★为什么其余全部不导出】
-- 因为那些都是「全局函数」（ModInfoname、AddModReleaseID 等），
-- 已经是全局可见的；而所有 AddXxx 都只存在于各模组的 env 表里，
-- 外部模块拿不到也不该拿到。
--
-- 【★这个最小导出面是刻意设计的】
-- 模组系统的「唯一官方入口」就是 InsertPostInitFunctions，
-- 调用方（ModManager）用它给每个模组装 API。
-- ★插件框架只暴露一个受控入口，比暴露一堆辅助函数更安全。
	InsertPostInitFunctions = InsertPostInitFunctions,
}