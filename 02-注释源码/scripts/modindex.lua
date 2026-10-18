--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：modindex.lua
-- 模块：模组系统 / 中枢（发现、索引、筛选、加载模组）
-- 职责：模组系统的中枢单例（KnownModIndex）。负责四阶段：
--       1. 发现 —— TheSim:GetModDirectoryNames() 列出磁盘上的模组目录
--       2. 索引 —— 在受限沙箱内读取并校验各模组的 modinfo.lua
--       3. 筛选 —— GetModsToLoad 按启用来源 + 依赖 + standalone 规则决定装哪些
--       4. 加载 —— 实际 require 各模组 modmain.lua 的工作由 mods.lua 承担
-- ★★ 注意「索引」不等于「加载」：读 modinfo 不等于加载模组代码，
--       这样模组列表界面无需加载任何模组代码即可快速展示。
-- 关键符号：ModIndex（local 类 + 单例）, GetModsToLoad, UpdateModInfo,
--           InitializeModInfo, LoadModOverides, ApplyEnabledOverrides,
--           ApplyConfigOptionOverrides, BeginStartupSequence / EndStartupSequence,
--           GetModDependencies, CacheSaveData / RestoreCachedSaveData,
--           UpdateModSettings, ResolveModname, KnownAPIVersion, Save
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：mods.lua（实际加载模组代码的另一半）、
--           modutil.lua（模组 API 表面与配置读取优先级）、
--           netvars.lua:29-32（★模组使用 netvar 时两端必须装同一 MOD，
--           直接决定同步层能否正常工作 —— 模组系统与网络层的强耦合点）、
--           techtree.lua / strict.lua（沙箱需用 rawget 绕过 _G 检查）、
--           shardindex.lua（集群槽位存档路径）
-- 【★移植要点】① 「半途标记 + 启动自愈」的崩溃恢复机制（本文件第 97-123 行）；
--   ② package.preload 劫持以静默接管旧依赖系统（第 7-37 行）；
--   ③ 递归遍历依赖图必须自带 visited 集合防环（第 1150 行）；
--   ④ 白名单沙箱只暴露「意图声明」函数，不授予能力（第 1108 行）。
-- 【⚠️ 已知隐患】ApplyEnabledOverrides 与 ShardSaveIndex:SetSlotEnabledServerMods
--   的数据格式强耦合且无自动校验，改一处忘另一处会静默失效。
--============================================================
require("mods")
-- ★★ 模组系统的中枢：负责「发现、索引、加载、校验」模组。
--
-- 【★与 netutil.lua / entityreplica.lua 的对照】
-- 前几个文件管的是「运行时数据怎么同步」；本文件管的是「运行前装什么」。
-- 但两者有一处强耦合：netvars.lua:29-32 明确写着
-- 「若 MOD 使用 netvars，则服务端与客户端必须都装同一个 MOD」。
-- ★也就是说 modindex 的加载一致性直接决定同步层能否正常工作 ——
--   客户端与服务端 mod 列表不一致，会导致整个实体反序列化错位。
-- 这是「模组系统」与「网络同步层」之间最容易踩的坑。
--
-- 【★本文件的四个阶段】
--   1. 发现   —— TheSim:GetModDirectoryNames() 列出所有模组目录
--   2. 索引   —— UpdateModInfo 读每个 modinfo.lua 存入 known_mods
--   3. 筛选   —— GetModsToLoad 按启用状态 + 依赖 + standalone 规则决定装哪些
--   4. 加载   —— 由 mods.lua 实际 require 各模组的 modmain.lua
-- ★「索引」与「加载」是两件事：读 modinfo 不等于加载模组代码。
-- 这样设计使得「列表界面可以快速展示全部模组」而不必加载任何模组代码。
require("modutil")

local mod_config_path = "mod_config_data/"
-- 模组配置数据的存放目录前缀（相对于存档目录）。

--redirect existing mod dependency solutions into ours
package.preload["moddependencymanager"] = function() end
-- ★★★ 用 package.preload「吃掉」两个旧模组的依赖管理器。
--
-- 【★这是 Lua 里 hijack require 的标准手法，也是本文件最巧妙的一处】
-- 原注释：redirect existing mod dependency solutions into ours。
-- 做法：提前在 package.preload 里注册一个同名空实现，
-- 于是任何 require("moddependencymanager") 都会拿到它而非真实模块。
--
-- 【★为什么必须这样做：向后兼容】
-- 老版本 DST 用 moddependencymanager / librarymanager 管理模组依赖。
-- 新版改由本文件的依赖系统（第 1130-1160 行）统一处理。
-- 若不劫持，老模组 require 到真库会走老逻辑，与新系统冲突；
-- 劫持后老代码「能跑但什么都不做」，依赖已被新系统接管。
--
-- 【★移植启示：给第三方扩展系统做「静默接管」的标准做法】
-- 比在调用点逐个加 if 判版本号要干净得多，且对新老调用方都透明。
package.preload["librarymanager"] = function()
	return function(_dependencies)
		local modenv = getfenv(2)
		if not rawget(_G, "TheFrontEnd") or (not _dependencies or not modenv or not modenv.modname or (KnownModIndex.savedata.known_mods[modenv.modname] and
-- ★★ 双重防护的守卫条件，值得逐项读：
--   not rawget(_G, "TheFrontEnd")  —— 不在前端（菜单）界面，直接返回
--   not _dependencies                —— 没传依赖列表，返回
--   not modenv or not modenv.modname —— 不在模组环境里执行，返回
--   known_mods[modname].dependencies —— 本模组已登记过依赖，不重复处理
--
-- 【★为什么用 rawget(_G, ...) 而不是直接访问 _G.TheFrontEnd】
-- 与 modutil.lua:138 的注释呼应：strict.lua 会对 _G 的访问做检查。
-- rawget 绕过元方法，直接读原始槽位，避免触发 strict 的拦截。
-- ★这说明本文件运行在一个「开启了严格模式」的环境里 ——
--   模组系统自身也必须遵守严格模式的约束。
			KnownModIndex.savedata.known_mods[modenv.modname].dependencies)) then return end
		local dependencies = {}
		for i, v in ipairs(_dependencies) do
			table.insert(dependencies, {v})
		end
		KnownModIndex.savedata.known_mods[modenv.modname].dependencies = dependencies
		local mods_tab
		for i, screen in ipairs(TheFrontEnd.screenstack) do
-- 遍历前端界面栈找模组标签页（mods_tab）。找到就 break。
-- 【★为什么绕这么大弯去找】
-- 因为依赖变更最终要反映到「模组列表界面的勾选状态」上。
-- 模组代码加载时前端界面栈是活的，所以能从中拿到界面对象。
-- ★这是「加载逻辑顺手更新 UI」的做法，耦合度较高但实践中最省事。
-- ⚠️ 自研引擎建议改为事件通知（发一个 "moddepschanged" 事件让 UI 订阅），
--   否则界面栈结构一变这里就失效。
			if screen and screen.mods_tab then
				mods_tab = screen.mods_tab
				break
			end
		end
		if mods_tab then
			local mod_dependencies = KnownModIndex:GetModDependencies(modenv.modname, true)
			if KnownModIndex:DoModsExistAnyVersion(mod_dependencies) then
				mods_tab:EnableModDependencies(mod_dependencies)
			else
				mods_tab:DisplayModDependencies(modenv.modname, mod_dependencies)
				return
			end
		end
	end
end
package.preload["tools/librarymanager"] = package.preload["librarymanager"]
package.preload["libs/librarymanager"] = package.preload["librarymanager"]

-- Note: This is a singleton (created at the bottom of this file) so the class is local
-- 原注释：这是单例（在本文件末尾创建），所以类是 local 的。
-- ★「先局部、后在文件末尾实例化并赋给全局」是单例的标准写法。
-- 好处：类定义不污染全局命名空间，外部只能拿到那个唯一实例。
local ModIndex = Class(function(self)
-- ★★★ 类构造。注意几个状态字段的语义差别（后文大量使用）：
--   startingup    —— 加载序列进行中（影响部分函数的行为，见第 97 行）
--   cached_data   —— 供「取消修改后回滚」的快照（第 1065 行 CacheSaveData）
--   forceddirs    —— ★「强制目录」：即使磁盘上不存在也要尝试加载的模组名
--                     （第 431 行会为 workshop 前缀的 ID 建立它）
--   mod_dependencies —— 依赖图，分 server_dependency_list 与 dependency_list
	self.startingup = false
	self.cached_data = {}
	self.savedata =
	{
		known_mods = { },
		known_api_version = 0,
		disable_special_event_warning = false,
	}
	self.forceddirs = {}
	self.mod_dependencies =
	{
		server_dependency_list = {},
		dependency_list = {},
	}
	if IsConsole() then
-- 只有主机平台（PC 客户端）才有 modsettings。
-- 【★为什么要区分 IsConsole()】
-- 主机版（PS/Xbox/Switch）不允许本地加载模组，配置文件机制无意义。
-- ★平台能力差异应在最外层就短路，而不是在每个使用点判断。
-- 这一判断在第 184 行 Save 里再次出现，直接跳过存盘。
		self.modsettings = {}
	end
end)

--[[
-- ★ 存档结构的权威说明（源码级注释，比我的转述更精确）。
-- known_mods[modname] 下的字段含义：
--   enabled                        —— 用户在菜单里勾选了
--   disabled_bad                   —— 因加载失败被自动禁用
--   modinfo                        —— 模组自述信息（★已不再存盘，见第 202 行）
--
-- 【★注意 modinfo 字段已被排除出存档，这是个有意的瘦身决策】
-- 见第 202 行注释：避免无效 modinfo 造成 modindex 文件不可读。
-- ★代价是每次启动都要重新读一遍所有 modinfo.lua（第 326 行）。
-- 权衡：牺牲一点启动时间，换存档文件的健壮性。
known_mods = {
	[modname] = {
		enabled = true,
		disabled_bad = true,
		modinfo = {
			version = "1.2",
			api_version = 2,
			failed = false,
		},
	}
}
--]]

function ModIndex:GetModIndexName()
-- ★ 分支名参与存档文件名：dev 分支用 "modindex_dev"，正式版用 "modindex"。
-- 【★为什么必须隔离】
-- 否则 dev 分支改了存档格式，再切回正式版就会读到不兼容的数据。
-- ★分支隔离是「多分支并行开发」的基础设施，成本极低、收益极高。
    return BRANCH ~= "dev" and "modindex" or ("modindex_"..BRANCH)
end

function ModIndex:GetModConfigurationPath(modname, client_config)
	if modname then
		return mod_config_path..self:GetModConfigurationName(modname, client_config)
	else
		return mod_config_path
	end
end

function ModIndex:GetModConfigurationName(modname, client_config)
-- 配置文件名规则：modconfiguration_<modname>，非正式分支加 _BRANCH 后缀。
-- 第 91 行：客户端专属模组的配置另存为 _CLIENT 文件，与服务端配置分开。
-- 【★为什么要分开存】
-- 服务端配置（如难度、刷怪率）必须全服一致；
-- 客户端配置（如音量、界面）应各人独立。
-- 混在一个文件里会出现「一个人改了设置，全服都变了」。
	local name = "modconfiguration_"..modname
	if BRANCH ~= "release" then
		name = name .. "_"..BRANCH
	end
	if self:GetModInfo(modname) and not self:GetModInfo(modname).client_only_mod and client_config then
		name = name .. "_CLIENT"
	end
	return name
end

function ModIndex:BeginStartupSequence(callback)
-- ★★ 加载序列的开始。核心是「上次是否崩在半路」的检测。
--
-- 【★这是一个精妙且廉价的崩溃恢复机制】
-- 思路：加载开始时在存档里写一个标记 "loading"，成功结束（第 125 行）改回 "done"。
-- 若下次启动读到的仍是 "loading"，说明上次加载中途崩溃了 ——
-- 于是把所有模组禁用，让用户能进游戏去修复。
--
-- 【★为什么这个设计优于「崩溃日志」】
-- 日志需要额外文件与清理逻辑；用一个两态字符串即可，
-- 且天然幂等：写 "loading" 本身是廉价的。
-- ★自研引擎若有模组/插件系统，这套「半途标记 + 启动时自愈」值得照抄。
	self.startingup = true

	if TheNet:IsDedicated() then
-- ★★ 专用服务器分支：不查崩溃，直接禁用所有模组。
-- 原注释：假定模组会被 modoverrides.lua 重新启用。
-- 【★为什么专用服务器必须这样】
-- 服务器上的模组列表由 modoverrides.lua 决定（第 366 行 LoadModOverides），
-- 而 known_mods 是玩家本地的勾选状态 —— 服务器不采信它。
-- ★这是「客户端状态与服务端状态分离」的典型：
--   客户端的勾选只影响本地；真正的模组列表由服务器文件指定。
		print("ModIndex: Beginning normal load sequence for dedicated server.\n")
		self:DisableAllMods() --We assume the mods will be re-enabled by the modoverrides.lua file
		callback()
	else
		local filename = "boot_"..self:GetModIndexName()
-- 存档键名加 "boot_" 前缀，与 modindex 主文件区分开。
		TheSim:GetPersistentString(filename,
			function(load_success, str)
				if load_success and str == "loading" then
-- ★★ 崩溃检测分支：读到 "loading" 说明上次崩了。
--
-- 【★这里有个重要细节：只有「存在待加载模组」时才判定为坏加载】
-- 若本来就没启用任何模组，"loading" 状态是正常的，不做任何处理。
-- 这个条件避免「纯净安装的游戏」被误判为崩溃。
					local modsenabled = self:GetModsToLoad()
					if #modsenabled > 0 then
						self.badload = true
						print("ModIndex: Detected bad load, disabling all mods.")
						self:DisableAllMods()
						self:Save(nil) -- write to disk that all mods were disabled!
-- ★ 立刻把「全禁用」写盘（第 114 行 self:Save(nil)）。
-- 【★为什么要马上存盘而不是退出时再存】
-- 因为如果这次启动又崩在别处，下一次启动仍需知道「已经禁用过模组」。
-- 不落盘的话崩溃-崩溃的组合会让状态反复。
-- ★把「已生效的降级动作」立即持久化，是崩溃恢复的必要条件。
					end
					callback()
				else
					print("ModIndex: Beginning normal load sequence.\n")
					SavePersistentString(filename, self.modsettings.disablemods and "loading" or "done", false, callback)
				end
			end)
	end
end

function ModIndex:EndStartupSequence(callback)
-- 加载序列正常结束：把标记改回 "done" 并回调。
-- ★这个 "done" 就是下一次启动第 108 行判断的依据，形成闭环。
	self.startingup = false
	local filename = "boot_"..self:GetModIndexName()
	SavePersistentString(filename, "done", false, callback)
	print("ModIndex: Load sequence finished successfully.")
end

function ModIndex:WasLoadBad()
	return self.badload == true
end

function ModIndex:GetModNames()
-- ★ 从 known_mods 的键（模组目录名）枚举全部模组。
-- 【★注意这里返回的是「目录名」而非 modinfo 里的「显示名」】
-- 二者不同：目录名如 "my_mod_folder"，显示名如 "My Cool Mod"。
-- 真正的加载必须用目录名，显示才用显示名。
-- 第 685 行 GetModActualName 负责显示名 -> 目录名的反查。
	local names = {}
	for name,_ in pairs(self.savedata.known_mods) do
		table.insert(names, name)
	end
	return names
end

function ModIndex:GetServerModNames()
-- 服务端模组列表：排除 client_only_mod。
-- 【★client_only_mod 的语义】
-- 「只在客户端生效」的模组（如纯 UI 美化、材质包）。
-- 服务器不需要它们，也不应因它们缺失而报错。
	local names = {}
	for modname,_ in pairs(self.savedata.known_mods) do
		if not self:GetModInfo(modname).client_only_mod then
			table.insert(names, modname)
		end
	end
	return names
end

function ModIndex:GetClientModNames()
	local names = {}
	for modname,_ in pairs(self.savedata.known_mods) do
		if self:GetModInfo(modname).client_only_mod then
-- ★ 与上一行互为镜像：只返回 client_only_mod 为真的那些。
-- 【★两个函数必须成对维护】
-- 若只改一个，另一个就会漏掉模组，表现为「列表里少一个模组」。
-- ★这类「正反成对」的查询是缺陷高发区，加注释很有必要。
			table.insert(names, modname)
		end
	end
	return names
end

function ModIndex:GetClientModNamesTable()
	local names = {}
	for known_modname,_ in pairs(self.savedata.known_mods) do
		if self:GetModInfo(known_modname).client_only_mod then
			table.insert(names, {modname = known_modname})
		end
	end
	return names
end

function ModIndex:GetServerModNamesTable()
	local names = {}
	for known_modname,_ in pairs(self.savedata.known_mods) do
		if not self:GetModInfo(known_modname).client_only_mod then
			table.insert(names, {modname = known_modname})
		end
	end
	return names
end

function ModIndex:Save(callback)
-- 存档写入。同样跳过主机平台（与第 55 行对应）。
    if IsConsole() then
        return
    end

	local newdata = { known_mods = {} }
	newdata.known_api_version = MOD_API_VERSION
	newdata.disable_special_event_warning = self.savedata.disable_special_event_warning

	for name, data in pairs(self.savedata.known_mods) do
-- ★ 逐字段白名单式拷贝，而不是 deepcopy 整个 known_mods。
-- 【★为什么必须白名单】
-- known_mods 里还挂着 modinfo（含 configuration_options 等大对象），
-- 若整体存盘，modindex 文件会膨胀到无法阅读，且被无效 modinfo 污染。
-- ★显式列举要存的字段，等于给存档格式加了「版本边界」。
-- 代价：新增字段时必须记得加进这个列表，否则静默丢失。
-- ★这种「忘记加字段就丢数据」的坑很隐蔽，建议在自研引擎里
--   改为「只排除黑名单字段」或加一个存档格式测试。
		newdata.known_mods[name] = {}
		newdata.known_mods[name].enabled = data.enabled
		newdata.known_mods[name].favorite = data.favorite
		newdata.known_mods[name].temp_enabled = data.temp_enabled
		newdata.known_mods[name].temp_disabled = data.temp_disabled
		newdata.known_mods[name].disabled_bad = data.disabled_bad
		newdata.known_mods[name].disabled_incompatible_with_mode = data.disabled_incompatible_with_mode
		newdata.known_mods[name].seen_api_version = MOD_API_VERSION
-- seen_api_version 记录的是「当前游戏版本」，不是模组自己的版本。
-- ★注意与 modinfo.api_version（模组声明的）区分：
--   前者 = 游戏侧当时是第几版；后者 = 模组自称兼容第几版。
-- 两者合起来才能判断「这个模组在此游戏版本下是否被正确处理过」。
		--newdata.known_mods[name].modinfo = data.modinfo --modinfo is no longer saved in the modindex. To remove the clutter from the modindex and to get rid of unreadable modindex files due to mods with invalid modinfo files
-- ★★ 一条被刻意注释掉的存盘语句，注释解释了原因：
-- modinfo 不再存入 modindex，以消除冗余与「因无效 modinfo 导致文件不可读」的问题。
-- 【★这是一个「主动删功能」的决策，值得学】
-- 保留它会让用户手写的 modindex 变得难以排错，收益却只有省一点启动时间。
-- ★判断标准：内部缓存数据 vs 用户可见的持久化数据，
--   后者要极度克制，前者可以随便写。
		newdata.known_mods[name].temp_config_options = data.temp_config_options
	end

	--print("\n\n---SAVING MOD INDEX---\n\n")
	--dumptable(newdata)
	--print("\n\n---END SAVING MOD INDEX---\n\n")
	local fastmode = true
-- ★ fastmode = true：DataDumper 的快速模式。
-- 【★通常是「牺牲可读性换速度」或反之，这里选了速度】
-- ⚠️ 我未核实 DataDumper 快速模式的具体差异（它在 C++ 侧），
--   注释中不臆测其行为。
	local data = DataDumper(newdata, nil, fastmode)
    local insz, outsz = SavePersistentString(self:GetModIndexName(), data, ENCODE_SAVES, callback)
end

local workshop_prefix = "workshop-"
-- ★★ workshop 模组命名前缀。整个模组系统的「双命名」问题源于此。
--
-- 【★为什么需要两套名字】
-- 本地模组：目录名即标识，如 "my_mod"。
-- 创意工坊模组：目录名形如 "workshop-123456789"。
-- 而用户在配置文件（modoverrides.lua）里写的是纯数字 ID。
-- 于是需要一套「ID <-> 内部名」的转换，且两者都可能匹配。
--This function only works if the modindex has been updated
function ResolveModname(modname)
-- 把 modname 解析为内部目录名。先试原名，再试加前缀。
-- 原注释明确：只有在 modindex 已更新后本函数才可靠。
-- 【★为什么依赖 DoesModExistAnyVersion】
-- 因为解析本质是「查这个目录是否存在」，所以必须先建好索引。
	--try to convert from Workshop id to modname
	if KnownModIndex:DoesModExistAnyVersion(modname) then
		return modname
	else
		--modname wasn't found, try it as a workshop mod
		local workshop_modname = workshop_prefix..modname
		if KnownModIndex:DoesModExistAnyVersion(workshop_modname) then
			return workshop_modname
		end
	end
	return nil
end

function IsWorkshopMod(modname)
	if modname == nil then
		return false
	end
	return modname:sub( 1, workshop_prefix:len() ) == workshop_prefix
end

function GetWorkshopIdNumber(modname)
-- 剥掉前缀，取出纯数字 ID。
	return string.sub(modname, workshop_prefix:len() + 1)
end

function ModIndex:GetTempEnabledMods()
	local moddirs = {}
	for name, data in pairs(self.savedata.known_mods) do
		if data.temp_enabled then
			table.insert(moddirs, name)
		end
	end
	return moddirs
end

function ModIndex:GetForceEnabledMods()
-- ★ 从 modsettings.lua 的 forceenable 列表取强制启用的模组。
-- 【★第 257 行的容错很实用】
-- 用户可能在 forceenable 里写纯数字 ID（创意工坊习惯），
-- 这里自动补上 workshop- 前缀。
-- ★「接受用户的多种写法并在边界处归一化」是好实践：
--   内层逻辑只需要处理一种规范形式。
	local moddirs = {}
	for name in pairs(self.modsettings.forceenable) do
		if (IsWorkshopMod(name)) then
			table.insert(moddirs, name)
		else
			if tonumber(name) then
				table.insert(moddirs, "workshop-"..name)
			else
				table.insert(moddirs, name)
			end
		end
	end
	return moddirs
end

function ModIndex:GetModsToLoad(usecached)
-- ★★★★ 全文件最复杂的筛选函数，决定「这次到底装哪些模组」。
--
-- 【★四类启用来源，本函数要合并它们】
--   ① IsModEnabled        —— 用户在菜单勾选（存于 known_mods）
--   ② IsModForceEnabled   —— modsettings.lua 强制启用（开发者用）
--   ③ IsModTempEnabled    —— 临时启用（本次会话有效，不落盘）
--   ④ IsModTempDisabled   —— ★反向否决，优先级最高：临时禁用会压过前三项
-- 公式：(① or ② or ③) and not ④
-- ★「正向 OR 汇总、反向 AND 取反」是权限/开关系统的标准结构。
	local cached = usecached or false

	local ret = {}
	if not cached then
-- ★ 非缓存分支：以「磁盘上真实存在的模组目录」为准。
-- 与第 298 行的缓存分支（以 known_mods 为准）相对。
-- 【★为什么要有两种模式】
--   非缓存：磁盘是真相，能发现「known_mods 里有但磁盘上没了」的模组；
--   缓存：只用已知信息，避免频繁扫盘（UI 列表刷新时用）。
-- ★缓存必须在数据变更后失效，否则会显示过期状态。
		local moddirs = TheSim:GetModDirectoryNames()
		local mods_to_load = {}
		for i,moddir in ipairs(moddirs) do
			if ((self:IsModEnabled(moddir) or self:IsModForceEnabled(moddir) or self:IsModTempEnabled(moddir) ) and not self:IsModTempDisabled(moddir)) and not mods_to_load[moddir] then
-- ★★ 筛选条件（磁盘分支）。四个条件合取，其中第三个是去重。
-- `not mods_to_load[moddir]` 是去重守卫 —— 因为下面第 281-297 行
-- 会把强制目录再扫一遍，可能与磁盘扫描结果重叠。
-- 【★注意 mods_to_load 这个表的键是 moddir，值恒为 true，
--   本质是个 Set，用来替代重复的 table.contains 线性查找。
-- ★用表当集合做 O(1) 去重，比 contains 的 O(n) 好，
--   在模组数量上百时差异明显。
				print("ModIndex:GetModsToLoad inserting moddir, ", moddir)
				mods_to_load[moddir] = true
				table.insert(ret, moddir)
			end
		end
		for i, moddir in ipairs(self:GetTempEnabledMods()) do
-- ★★ 关键细节：临时/强制启用但磁盘上不存在的模组，被登记进 forceddirs。
-- 【★为什么要登记而不是直接跳过】
-- 因为「磁盘上没有」可能只是模组文件夹被挪走或尚未下载，
-- 但用户的启用意图应当被记住。
-- 登记后第 331-342 行的 UpdateModInfo 仍会尝试读它的 modinfo，
-- 读不到就标记为「坏模组」并在 UI 里提示，而不是静默消失。
-- ★移植启示：外部资源缺失时，「保留意图 + 显式报错」优于「静默忽略」。
			if not table.contains(moddirs, moddir) then
				self.forceddirs[moddir] = true
			end
		end
		for i, moddir in ipairs(self:GetForceEnabledMods()) do
			if not table.contains(moddirs, moddir) then
				self.forceddirs[moddir] = true
			end
		end
		for moddir in pairs(self.forceddirs) do
-- 把 forceddirs 里的模组也纳入结果，用同样的条件与去重。
-- ★这一段与第 274 行几乎逐字重复 —— 属刻意的代码复制。
-- 【★为什么不抽成局部函数】
-- 抽出来需要额外参数传递，而这段逻辑只出现两次且都要改。
-- ★取舍：重复两次好过过早抽象。超过三处才值得提取。
			if ((self:IsModEnabled(moddir) or self:IsModForceEnabled(moddir) or self:IsModTempEnabled(moddir) ) and not self:IsModTempDisabled(moddir)) and not mods_to_load[moddir] then
				print("ModIndex:GetModsToLoad inserting forcedmoddir, ", moddir)
				mods_to_load[moddir] = true
				table.insert(ret, moddir)
			end
		end
	else
		if self.savedata and self.savedata.known_mods then
			for modname, moddata in pairs(self.savedata.known_mods) do
				if (self:IsModEnabled(modname) or self:IsModForceEnabled(modname) or self:IsModTempEnabled(modname) ) and not self:IsModTempDisabled(modname) then
					print("ModIndex:GetModsToLoad inserting modname, ", modname)
					table.insert(ret, modname)
				end
			end
		end
	end
	for i,modname in ipairs(ret) do
-- ★★★ standalone 模组的短路：只要有一个，其余全不装。
-- 【★为什么最后才检查】
-- 因为要先知道「全部候选模组」才能发现其中有 standalone。
-- 一旦发现就整体替换为单元素列表。
-- 【★语义：standalone 模组自带完整世界与资源，独占运行】
-- 典型如「韦斯特华不使用」这类大型独立 Mod。
-- 与其它模组共存会导致资源冲突，所以必须独占。
		if self:IsModStandalone(modname) then
			print("\n\n"..ModInfoname(modname).." Loading a standalone mod! No other mods will be loaded.\n")
			return { modname }
		end
	end
	return ret
end

function ModIndex:GetModInfo(modname)
	if self.savedata.known_mods[modname] then
		return self.savedata.known_mods[modname].modinfo or {}
	else
		modprint("unknown mod " .. tostring(modname))
		return nil
	end
end

function ModIndex:UpdateModInfo()
-- ★ 全量刷新索引：处理已消失的模组 + 新发现的模组 + 强制目录。
	modprint("Updating all mod info.")

	local modnames = TheSim:GetModDirectoryNames()

	for modname,moddata in pairs(self.savedata.known_mods) do
-- ★ 处理「known_mods 里有、磁盘上没了」的模组。
-- 【★第 333-337 行的分支很微妙】
--   若该模组是 temp_enabled（临时启用）→ 保留记录并重试加载；
--   否则 → 直接从索引删除。
-- ★为什么临时启用要保留：它可能是「本会话刚被服务器要求加载」的新模组，
--   文件尚未同步到本地，删了就再也加载不上。
		if not table.contains(modnames, modname) and not self.forceddirs[modname] then
			if moddata.temp_enabled then
				if not self.savedata.known_mods[modname] then
					self.savedata.known_mods[modname] = {}
				end
				self.savedata.known_mods[modname].modinfo = self:LoadModInfo(modname, self.savedata.known_mods[modname].modinfo)
			else
				self.savedata.known_mods[modname] = nil
			end
		end
	end

	for i,modname in ipairs(modnames) do
-- 处理磁盘上存在但索引里没有的模组，补建记录。
-- ★这是「模组第一次出现」的路径。每次启动都会走到。
		if not self.savedata.known_mods[modname] then
			self.savedata.known_mods[modname] = {}
		end
		self.savedata.known_mods[modname].modinfo = self:LoadModInfo(modname, self.savedata.known_mods[modname].modinfo)
	end

	for modname in pairs(self.forceddirs) do
		if not self.savedata.known_mods[modname] then
			self.savedata.known_mods[modname] = {}
		end
		self.savedata.known_mods[modname].modinfo = self:LoadModInfo(modname, self.savedata.known_mods[modname].modinfo)
	end
end

function ModIndex:UpdateSingleModInfo(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].modinfo = self:LoadModInfo(modname, self.savedata.known_mods[modname].modinfo)
end

function ModIndex:LoadModOverides(shardGameIndex)
-- ★★ 读 modoverrides.lua —— 专用服务器上模组列表的真正来源。
--
-- 【★这是模组系统的「服务端权威」机制】
-- 专用服务器忽略玩家本地勾选（第 100 行），改用这个文件。
-- 文件里可以写：启用哪些模组、禁用哪些模组、各模组的配置项覆盖值。
-- 【★为什么用异步回调读文件】
-- TheSim:GetPersistentString 是跨平台的异步存档接口（磁盘 IO 不可阻塞）。
-- ★自研引擎做配置加载时要注意：不要在主线程同步读文件。
	if TheNet:GetIsClient() then
		return {}
	end

    local overrides = {}
    local filename = "../modoverrides.lua"

    local function onload(load_success, str)
        if load_success == true then
            local fn, message = loadstring(str)
-- ★ 用 loadstring 编译文件内容 —— 原文未标注 V2C，故仍是旧 API。
-- ⚠️ 注意：SOP 提到的 Lua 5.5 已移除 loadstring，那是我们的校验环境；
--   DST 运行时（Lua 5.1）仍支持。两者不冲突，只是版本差异。
-- 【★为什么用 loadstring 而不是 kleiloadlua】
-- kleiloadlua 直接从磁盘读并 load（第 602 行用的就是它）；
-- 而这里内容已由 TheSim 读成字符串，故需手动 loadstring。
            if fn ~= nil then
                local env = {}
                local success, r = RunInEnvironment(fn, env)
-- ★ 在空环境里执行，取其返回值作为配置表。
-- 【★RunInEnvironment 的意义：配置脚本不能污染全局】
-- 配置文件本质是「一段返回数据的代码」，不应有副作用。
-- ★比 loadstring 后直接调用安全得多 —— 沙箱化执行是配置系统的标准做法。
				if success and type(r) == "table" then
					print("SUCCESS: Loaded modoverrides.lua")
                    overrides = r
                else
                    print("ERROR: Failed to run code from modoverrides.lua")
                end
            else
                print("ERROR: Failed to load modoverrides.lua")
            end
        end
    end

	--ShardGameIndex isn't loaded yet, load a temp one for this test...
-- ★ ShardGameIndex 尚未就绪时的兜底：临时建一个来查询存档位置。
-- 【★为什么需要这个间接层】
-- 集群模式下，同一份存档存在不同「槽位」，路径由 shardGameIndex 决定。
-- 此时它还没加载，只能先造个临时的来问路径。
-- ★注意它用了局部变量遮蔽参数，不修改调用方的值 —— 副作用控制得当。
	shardGameIndex = shardGameIndex or ShardGameIndex
	if not shardGameIndex then
		require("shardindex")
		shardGameIndex = ShardIndex()
		shardGameIndex:Load()
	end
    if not TheNet:IsDedicated() and shardGameIndex:IsValid() and not shardGameIndex:GetServerData().use_legacy_session_path then
-- ★★ 三选一的存储路径决策，很值得学：
--   条件 A：非专用服务器 且 shardGameIndex 有效 且 未用 legacy 路径
--         → 用 GetPersistentStringInClusterSlot(slot, "Master", ...)
--   否则 → 用普通的 GetPersistentString(...)
-- 【★为什么主客户端（房主单机）走集群槽位路径】
-- 因为它要读的是「自己作为服务端时写入的那份」，槽位由存档决定。
-- 而 legacy 路径是给旧版本存档的，槽位信息不可用，只能退回旧路径。
-- ★三条件复合判断写在 if 里可读性差；抽成具名布尔（如 local use_cluster_slot = ...）
--   会更清楚。此处属「能跑但可读性待改善」。
        TheSim:GetPersistentStringInClusterSlot(shardGameIndex:GetSlot(), "Master", filename, onload)
    else
        TheSim:GetPersistentString(filename, onload)
    end

    return overrides
end


function ModIndex:TryLoadMod(modname)
	if self.savedata.known_mods[modname] then return true end
	if kleifileexists(MODS_ROOT..modname.."/modinfo.lua") then
		self.forceddirs[modname] = true
		self:UpdateSingleModInfo(modname)
		return true
	end
	return false
end

function ModIndex:ApplyEnabledOverrides(mod_overrides) --Note(Peter): This function is now coupled with the format written by ShardSaveIndex:SetSlotEnabledServerMods
-- ★★ 应用 modoverrides 里的启用/禁用指令。
-- 注释警告：本函数与 ShardSaveIndex:SetSlotEnabledServerMods 的格式强耦合。
-- 【★「格式强耦合」是本文件最大的维护隐患】
-- 两个文件必须保持字段名一致，改一处忘另一处就会静默失效，
-- 且没有任何机制能检测到。
-- ★自研引擎应避免跨文件隐式格式约定，至少写一个校验函数。
	if mod_overrides == nil then
		print("Warning: modoverrides.lua is empty, or is failing to return a table.")
	else
		--Enable mods that are being forced on in the modoverrides.lua file
		--print("ModIndex:ApplyEnabledOverrides for mods" )
		for modname,env in pairs(mod_overrides) do
			if modname == "client_mods_disabled" then
-- ★ 特殊键 client_mods_disabled：整键禁用所有客户端模组。
-- 用它当「全局开关」，避免逐个枚举客户端模组名。
				self:DisableClientMods( env ) --env is a bool in this case
			else
				if env.enabled ~= nil then
					if not self:TryLoadMod(modname) then
-- ★★ 先尝试按原名加载，不行再按 workshop 前缀名加载。
-- 【★为什么需要 TryLoadMod】
-- modoverrides 可能引用了一个本机还没下载过的创意工坊模组。
-- TryLoadMod（第 409 行）会检查 modinfo.lua 是否存在，
-- 存在则登记进索引并强制加载。
-- ★即：配置文件里写一个模组，能触发「尝试从磁盘加载它」。
						self:TryLoadMod(workshop_prefix..modname)
					end
					local actual_modname = ResolveModname(modname)
					if actual_modname ~= nil then
-- ★ 解析成真实目录名后才执行启用/禁用。
-- 解析失败（模组不存在）则静默跳过 —— 不报错。
-- ⚠️ 静默跳过是这里的问题：配置里写错模组名不会有任何提示。
-- ★对管理员而言，「我配了但没生效」很难排查，加一条 warning 更好。
						if env.enabled then
							print( "modoverrides.lua enabling " .. actual_modname )
							self:Enable(actual_modname)
						else
							self:Disable(actual_modname)
						end
					end
				end
			end
		end
	end
end

function ModIndex:ApplyConfigOptionOverrides(mod_overrides)
-- ★★ 应用 modoverrides 里的配置项覆盖。
-- 【★第 459 行的 force_local_options = true 是个关键细节】
-- 它要求读取「客户端配置」而非服务端配置。
-- 原因：modoverrides 是服务端写的，覆盖的应当是服务器侧生效的配置。
-- 而 modutil.lua:45-49 的 GetModConfigData 中，
--   get_local_config 为真 → 读 saved_client；为假 → 读 saved_server。
-- ★这两处必须一致理解，否则会读错配置来源。
	--print("ModIndex:ApplyConfigOptionOverrides for mods" )
	for modname,env in pairs(mod_overrides) do
		if modname == "client_mods_disabled" then
			--Do nothing here for this entry
		else
			if env.configuration_options ~= nil then
				local actual_modname = ResolveModname(modname)
				if actual_modname ~= nil then
					print( "applying configuration_options from modoverrides.lua to mod " .. actual_modname )

					local force_local_options = true
					local config_options = self:GetModConfigurationOptions_Internal(actual_modname,force_local_options)

					if config_options and type(config_options) == "table" then
						for option,override in pairs(env.configuration_options) do
							for _,config_option in pairs(config_options) do
			  					if config_option.name == option then
			  						print( "Overriding mod " .. actual_modname .. "'s option " .. option .. " with value " .. tostring(override) )
			  						config_option.saved = override
-- ★ 直接写 config_option.saved（而不是 saved_client / saved_server）。
-- 【★注意这里用的是通用 saved 字段】
-- 按 modutil.lua:51-52，读取时的优先级是：
--   get_local_config 为假 → 先看 saved_server，为真 → 先看 saved_client，
--   都没有才回落到 saved。
-- ★所以覆盖 saved 只在没有 saved_server / saved_client 时才生效。
-- ⚠️ 若某模组已保存过服务端配置，覆盖会被 saved_server 遮蔽而看似无效。
-- 这是我静态推导的潜在陷阱，未实机验证。
			  					end
							end
						end
					end
				end
			end
		end
	end
end

local function FindEnabledMod(self, v)
-- ★ 在「可能的模组名列表」里找出第一个已启用的。
-- 【★为什么要「试多个名字」】
-- 老模组用别的库声明依赖时，写的是显示名或别的标识符。
-- 同一个依赖可能有多种写法（显示名、目录名、workshop 名）。
-- 这里逐个尝试，返回第一个命中的。
-- ★向后兼容的代价：无法严格校验输入，只能「能匹配上就算」。
    if self:IsModEnabledAny(v.workshop) then
        return v.workshop
    end
    for modname, isfancy in ipairs(v) do
        if modname ~= "workshop" then
            modname = not isfancy and modname or self:GetModActualName(modname)
-- isfancy 为真表示这是显示名，需要反查成目录名；否则视为已是目录名。
            if self:IsModEnabledAny(modname) then
                return modname
            end
        end
    end
end

local function BuildModPriorityList(self, v, is_workshop)
-- ★★ 构造「优先尝试列表」，比上一个函数更进一步：
-- 它返回一个有序列表（而非第一个命中的名字），
-- 因为加载顺序会影响谁覆盖谁，所以需要保持候选顺序。
-- 【★第 505 行是本函数的核心决策】
-- table.insert(mods, is_workshop and 1 or #mods+1, workshop)
-- 创意工坊模组被放到列表**开头**（is_workshop 为真时）。
-- 注释说：creative 模组优先，否则作为最后手段。
-- ★即「创意工坊版本覆盖本地版本」，这是模组更新时最常见的期望行为。
    local workshop = v.workshop
	local mods = {}
    for modname, isfancy in pairs(v) do
-- ★ 用 pairs 遍历候选名（顺序不确定），但后面会把 workshop 插到确定位置。
-- ⚠️ 候选名之间的相对顺序仍不确定，若多个候选都存在，加载顺序随机。
-- 对本场景影响有限（一般只有一个候选存在），属可接受的简化。
        if modname ~= "workshop" then
            modname = not isfancy and modname or self:GetModActualName(modname)
            if self:DoesModExistAnyVersion(modname) then
                table.insert(mods, modname)
            end
        end
	end
	if workshop then
		--prioritize workshop mods if the mod is_workshop, otherwise its the last resort
		table.insert(mods, is_workshop and 1 or #mods+1, workshop)
	end
	return mods
end

local print_atlas_warning = true
-- print_atlas_warning 是模块级的一次性标志，避免重复刷屏。
-- ★「警告只打一次」是控制日志噪音的常用手法。
function ModIndex:LoadModInfo(modname, prev_info)
-- 读取并更新单个模组的信息。prev_info 用于版本比对以跳过重复工作。
	modprint(string.format("Updating mod info for '%s'", modname))

	local info = self:InitializeModInfo(modname)
	if info.failed then
		modprint("  But there was an error loading it.")
		self:DisableBecauseBad(modname)
	else
		-- we've already "dealt" with this in the past; if the user
		-- chooses to enable it, then try loading it!
	end

	self.savedata.known_mods[modname].modinfo = info
	for i,v in pairs(self.savedata.known_mods[modname].modinfo) do
		-- print(i,v)
	end

	info.version = TrimString(info.version or "")
-- ★★★ 版本号归一化三连：TrimString -> lower -> 兼容版本同样处理。
-- 【★为什么要归一化】
-- modinfo 里作者可能写 "1.2 "（带空格）或 "V1.2"（带前缀）。
-- 归一化后才能与其它版本号正确比较。
-- ★版本比较是模组系统的核心，必须先归一化，否则 "1.10" < "1.9" 会出错。
-- ⚠️ 我核实过：这里只做字符串归一化，未见做语义化版本比较，
--   比较依赖第 534 行的相等判断。
	info.version = string.lower(info.version)
	info.version_compatible = type(info.version_compatible) == "string" and info.version_compatible or info.version
	info.version_compatible = TrimString( info.version_compatible )
	info.version_compatible = string.lower(info.version_compatible)

	if prev_info ~= nil and prev_info.version == info.version then return prev_info end
-- ★ 版本号与上次相同就直接复用旧 info，跳过后续昂贵处理。
-- 【★这是缓存失效策略：按「版本」而非「时间」判断】
-- 好处：启动时对未更新的模组省掉大量重复解析。
-- ★自研引擎的插件系统值得用同样的思路：版本未变就别重新加载元数据。

	if info.icon_atlas ~= nil and info.icon ~= nil and info.icon_atlas ~= "" and info.icon ~= "" then
		local atlaspath = MODS_ROOT..modname.."/"..info.icon_atlas
		local iconpath = string.gsub(atlaspath, "/[^/]*$", "") .. "/"..info.icon
		if softresolvefilepath(atlaspath) and softresolvefilepath(iconpath) then
			info.icon_atlas = atlaspath
			info.iconpath = iconpath
		else
			-- This prevents malformed icon paths from crashing the game.
			if print_atlas_warning then
				print(string.format("WARNING: icon paths for mod %s are not valid. Got icon_atlas=\"%s\" and icon=\"%s\".\nPlease ensure that these point to valid files in your mod folder, or else comment out those lines from your modinfo.lua.", ModInfoname(modname), info.icon_atlas, info.icon))
				print_atlas_warning = false
			end
			info.icon_atlas = nil
			info.iconpath = nil
			info.icon = nil
		end
	else
		info.icon_atlas = nil
		info.iconpath = nil
		info.icon = nil
	end

	--Add game modes
	if info.game_modes then
		for _,mode in pairs(info.game_modes) do
			local gm = AddGameMode(mode.name, mode.label)
			gm.description = mode.description or ""
			if mode.settings then
				for option,value in pairs(mode.settings) do
					gm[option] = value
				end
			end
		end
	end

    if info.mod_dependencies and not info.client_only_mod then --todo(Zachary): support client mods in the future
		local dependencies = {}
		self.savedata.known_mods[modname].dependencies = dependencies
        for i, v in ipairs(info.mod_dependencies) do
            --if a mod is already enabled, use that version.
            local enabledmod = FindEnabledMod(self, v)
            if enabledmod then
                table.insert(dependencies, {enabledmod})
            else
                local mods = BuildModPriorityList(self, v, IsWorkshopMod(modname))
                if #mods == 0 then
                    modprint("no valid dependent mod found for mod "..modname)
					self:DisableBecauseBad(modname)
				end
				table.insert(dependencies, mods)
            end
        end
	end

	return info
end

function ModIndex:InitializeModInfo(modname)
-- ★★★★ 读取并校验 modinfo.lua，是模组可信度的把关点。
--
-- 【★沙箱环境 env 只有三个键】
--   folder_name —— 模组自己的目录名（只读）
--   locale      —— 当前语言
--   ChooseTranslationTable —— 语言回退助手函数
-- ★modinfo.lua 在这个受限环境里执行，不能修改任何全局状态。
-- 【★沙箱的价值：modinfo 是「元数据」，本该是纯声明】
-- 一旦允许它改全局，一个写错的 modinfo 就能破坏整个加载流程。
	local env = {
		folder_name = modname,
		locale = LOC.GetLocaleCode(),
		ChooseTranslationTable = function(tbl)
			local locale = LOC.GetLocaleCode()
			return tbl[locale] or tbl[1]
		end,
	}
	local fn = kleiloadlua(MODS_ROOT..modname.."/modinfo.lua")
-- kleiloadlua 加载 modinfo.lua。返回函数，或返回错误信息字符串。
-- 【★注意返回类型的多态：函数 或 字符串（错误）或 nil（文件不存在）】
-- 下面第 604、608 行分别处理这三种情况。
-- ★Lua 的这种「返回值类型取决于结果」的约定可读性差，
--   但在需要区分「编译失败」与「文件缺失」时确实必要。
	local modinfo_message = ""
	if type(fn) == "string" then
-- 情况一：返回字符串 = 编译/语法错误。直接标记 failed。
		print("Error loading mod: "..ModInfoname(modname).."!\n "..fn.."\n")
		--table.insert( self.failedmods, {name=modname,error=fn} )
		env.failed = true
	elseif not fn then
-- 情况二：返回 nil = modinfo.lua 不存在。
-- ★选择「用默认值继续」而非失败 —— 这样老的、没有 modinfo 的模组仍可加载。
-- 容错优先于严格，符合模组生态的诉求。
		modinfo_message = modinfo_message.."No modinfo.lua, using defaults... "
	else
		local status, r = RunInEnvironment(fn,env)
-- ★★ 在沙箱里执行，status 为 false 表示执行期出错。
-- 【★RunInEnvironment 返回 (成功标志, 错误信息)】
-- 执行出错（如 modinfo 里除以 nil）也标记 failed，而不是让整个加载崩掉。
-- ★一个坏模组绝不能拖垮整个模组加载流程 —— 这是插件系统的基本要求。

		--if api_version_dst exists, we want to promote it to be the actual api_version of this mod.
		if env.api_version_dst ~= nil then
-- ★ api_version_dst 覆盖 api_version：显式指定 DST 版本的模组优先。
-- 因为同一个模组可能要同时支持 DS 与 DST，用不同字段区分。
			env.api_version = env.api_version_dst
		end

		if status == false then
			print("Error loading mod: "..ModInfoname(modname).."!\n "..r.."\n")
			env.failed = true
		elseif env.api_version == nil or env.api_version < MOD_API_VERSION then
-- ★★ 三档 API 版本判定：太旧 / 正好 / 太新。
--   太旧 → 只记录一条 message，不阻止加载（向后兼容）；
--   正好 → 进入必填字段校验；
--   太新 → 判定 failed。
-- 【★「太旧」与「太新」的处置不同，是有讲究的】
--   太旧：模组可能仍能跑，只是用了过时 API，放行更友好；
--   太新：模组依赖了本版本不存在的 API，必然跑不起来，必须拦。
-- ★这就是「向后兼容优先，向前兼容保守」的版本策略。
			modinfo_message = modinfo_message.."Old API! (mod: "..tostring(env.api_version).." game: "..MOD_API_VERSION..") "
		elseif env.api_version > MOD_API_VERSION then
			local old = "api_version for "..modname.." is in the future, please set to the current version. (api_version is version "..env.api_version..", game is version "..MOD_API_VERSION..".)"
			print("Error loading mod: "..ModInfoname(modname).."!\n "..old.."\n")
			env.failed = true
		else
			local checkinfo = { "name", "description", "author", "version", "api_version", "dont_starve_compatible", "reign_of_giants_compatible", "configuration_options", "dst_compatible" }
-- ★ 必填字段清单。少任何一个都算加载失败。
--
-- 【★三个字段被显式豁免（见第 633-644 行）】
--   dont_starve_compatible / reign_of_giants_compatible —— 仅警告；
--   dst_compatible —— 警告（会打印）；
--   configuration_options —— 完全忽略（没有配置项很正常）。
-- ★分级处置（忽略 < 警告 < 失败）是好实践：
--   必填项才失败，可选项才警告。
			local missing = {}

			for i,v in ipairs(checkinfo) do
				if env[v] == nil then
					if v == "dont_starve_compatible" then
						-- Print a warning but let the mod load
						--print("WARNING loading modinfo.lua: "..modname.." does not specify if it is compatible with the base game. It may not work properly.")
					elseif v == "reign_of_giants_compatible" then
						-- Print a warning but let the mod load
						--print("WARNING loading modinfo.lua: "..modname.." does not specify if it is compatible with Reign of Giants. It may not work properly.")
					elseif v == "dst_compatible" then
						-- Print a warning but let the mod load
						print("WARNING loading modinfo.lua: "..modname.." does not specify if it is compatible with Don't Starve Together. It may not work properly.")
					elseif v == "configuration_options" then
						-- Do nothing. It's perfectly fine not to have config options!
					else
						table.insert(missing, v)
					end
				end
			end

			if #missing > 0 then
-- 缺必填项 → 汇总成一条错误信息并标记失败。
-- ★用 table.concat 汇总所有缺失项，而非逐条报错 —— 用户体验更好。
				local e = "Error loading modinfo.lua. These fields are required: " .. table.concat(missing, ", ")
				print (e)
				--table.insert( self.failedmods, {name=modname,error=e} )

				env.failed = true
			else
				-- everything loaded okay!
			end
		end
	end

	env.modinfo_message = modinfo_message

	-- If modinfo hasn't been updated to specify compatibility yet, set it to true for both modes and set a flag
	if env.dont_starve_compatible == nil then
-- ★ 未声明兼容性标记时，默认当作兼容，并记录「未声明」标志。
-- 【★为什么默认兼容而不是默认不兼容】
-- 因为 DST 时期绝大多数模组只关心 DST，写全三个标记是额外负担。
-- 默认兼容保证老模组不会因新增必填项而失效。
-- 同时置 *_compatibility_specified = false，UI 可提示「未声明兼容性」。
-- ★向后兼容的典型手法：新增字段给默认值，并记录是否显式设置。
		env.dont_starve_compatible = true
		env.dont_starve_compatibility_specified = false
	end
	if env.reign_of_giants_compatible == nil then
		env.reign_of_giants_compatible = true
		env.reign_of_giants_compatibility_specified = false
	end
	if env.dst_compatible == nil then
		env.dst_compatible = true
		env.dst_compatibility_specified = false
	end

	if env.client_only_mod and env.all_clients_require_mod then
-- ★ client_only_mod 与 all_clients_require_mod 互斥，只警告不失败。
-- 【★为什么这两个标志互斥】
-- client_only_mod 表示「只有装了它的客户端才需要」，
-- all_clients_require_mod 表示「所有客户端都必须装」。
-- 同时声明语义矛盾（要么无关，要么必须）。
-- ★用警告而非失败，与「configuration_options 缺失」的宽松处理一致：
--   这是模组作者的表达问题，不该阻断玩家的游戏。
		print("WARNING loading modinfo.lua: "..modname.." specifies client_only_mod and all_clients_require_mod. These flags are mutually exclusive.")
	end

	return env
end

function ModIndex:GetModActualName(fancyname)
-- ★ 显示名 -> 目录名。全表线性扫描。
-- 【★O(n) 查找：模组上百时每次调用都有开销】
-- 但调用频率低（通常只在配置解析时），可接受。
-- ★若要优化，可加一张 name -> modname 的反向索引缓存。
	for i,v in pairs(self.savedata.known_mods) do
		if v and v.modinfo and v.modinfo.name then
			if v.modinfo.name == fancyname then
				return i
			end
		end
	end
end

function ModIndex:GetModFancyName(modname)
-- 目录名 -> 显示名。找不到就原样返回（目录名）。
-- ★优雅降级：没有显示名时用目录名，至少不会崩或显示 nil。
	local knownmod = self.savedata.known_mods[modname]
	if knownmod and knownmod.modinfo and knownmod.modinfo.name then
		return knownmod.modinfo.name
	else
		return modname
	end
end

function ModIndex:Load(callback)

	self:UpdateModSettings()

    local filename = self:GetModIndexName()
    TheSim:GetPersistentString(filename,
        function(load_success, str)
        	if load_success == true then
				local success, savedata = RunInSandboxSafe(str)
				if success and string.len(str) > 0 and savedata ~= nil then
					self.savedata = savedata
					print ("loaded "..filename)
					--print("\n\n---LOADING MOD INDEX---\n\n")
					--dumptable(self.savedata)
					--print("\n\n---END LOADING MOD INDEX---\n\n")


					--print("\n\n---LOADING MOD INFOS---\n\n")
					self:UpdateModInfo()
					--dumptable(self.savedata)
					--print("\n\n---END LOADING MOD INFOS---\n\n")
				else
					print ("Could not load "..filename)
					if string.len(str) > 0 then
						print("File str is ["..str.."]")
					end
				end
			else
				print ("Could not load "..filename)
			end

			callback()
        end)
end

function ModIndex:IsModCompatibleWithMode(modname, dlcmode)
	local known_mod = self.savedata.known_mods[modname]
	if known_mod and known_mod.modinfo then
		return known_mod.modinfo.dst_compatible
	end
	return false
end

function ModIndex:HasModConfigurationOptions(modname)
	local modinfo = self:GetModInfo(modname)
	if modinfo and modinfo.configuration_options and type(modinfo.configuration_options) == "table" and #modinfo.configuration_options > 0 then
		return true
	end
	return false
end

function ModIndex:UpdateConfigurationOptions(config_options, savedata, client_config)
	for i,v in pairs(savedata) do
		for j,k in pairs(config_options) do
			if v.name == k.name and v.saved ~= nil then
				if client_config then
					k.saved_client = v.saved
				else
					k.saved_server = v.saved
				end

				k.saved = v.saved -- don't know if this is still needed, but keeping it.
			end
		end
	end
end

-- Just returns the table itself, and a bool specifying if it's a temp or regular table
-- In the frontend this function is not reliable without actually loading the mods from disk again due to the periodic updater.
function ModIndex:GetModConfigurationOptions_Internal(modname,force_local_options)
	local known_mod = self.savedata.known_mods[modname]
	if known_mod then
		if known_mod.temp_enabled and not force_local_options then
			return known_mod.temp_config_options, true
		elseif not ModManager.worldgen and ((TheNet:GetIsServer() and not TheNet:IsDedicated()) and not force_local_options) then
			return known_mod.temp_config_options, false
		else
			return known_mod.modinfo.configuration_options, false
		end
	end
end

function ModIndex:SetConfigurationOption(modname, option_name, value)
	local known_mod = self.savedata.known_mods[modname]
	if known_mod and known_mod.modinfo and known_mod.modinfo.configuration_options then
		for _,option in pairs(known_mod.modinfo.configuration_options) do
			if option.name == option_name then
				option.saved = value
			end
		end
	end
end

-- Loads the actual file from disk
function ModIndex:LoadModConfigurationOptions(modname, client_config)
	local known_mod = self.savedata.known_mods[modname]
	if known_mod == nil then
		print("Error: mod isn't known", modname )
		return nil
	end

	-- Try to find saved config settings first
	local filename = self:GetModConfigurationPath(modname, client_config)
	TheSim:GetPersistentString(filename,
        function(load_success, str)
        	if load_success == true then
				local success, savedata = RunInSandboxSafe(str)
				if success and string.len(str) > 0 then
					-- Carry over saved data from old versions when possible
					if self:HasModConfigurationOptions(modname) then
						self:UpdateConfigurationOptions(known_mod.modinfo.configuration_options, savedata, client_config)
					else
						if known_mod.modinfo ~= nil then
							known_mod.modinfo.configuration_options = savedata
						else
							print("Error: modinfo was not available for mod ", modname) --something went wrong, likely due to workshop update during FE loading, load modinfo now to try to recover
							self:UpdateSingleModInfo(modname)
							known_mod.modinfo.configuration_options = savedata
						end
					end
					print ("loaded "..filename)
				else
					print ("Could not load "..filename)
				end
			else
				print ("Could not load "..filename)
			end

			-- callback()
        end)

	if known_mod and known_mod.modinfo and known_mod.modinfo.configuration_options then
		return known_mod.modinfo.configuration_options
	end
	return nil
end

function ModIndex:SaveHostConfiguration(modname)
	local known_mod = self.savedata.known_mods[modname]
	if known_mod then
		if known_mod.modinfo then
			if known_mod.modinfo.configuration_options then
				self:SaveConfigurationOptions(function() end, modname, known_mod.modinfo.configuration_options, false)
			end
		end
	end
end

function ModIndex:SaveConfigurationOptions(callback, modname, configdata, client_config)
	if IsConsole() or not configdata then
        return
    end
    --print("### SaveConfigurationOptions ", modname)
    --write to existing table
    for _,v in pairs(configdata) do
		self:SetConfigurationOption(modname, v.name, v.saved)
	end

    -- Save it to disk
    local name = self:GetModConfigurationPath(modname, client_config)
	local data = DataDumper(configdata, nil, false)

	local cb = function()
		callback()
		-- And reload it to make sure there's parity after it's been saved
		self:LoadModConfigurationOptions(modname, client_config)
	end

    local insz, outsz = SavePersistentString(name, data, ENCODE_SAVES, cb)
end

function ModIndex:IsModEnabled(modname)
	local known_mod = self.savedata.known_mods[modname]
	return known_mod and known_mod.enabled
end

function ModIndex:IsModTempEnabled(modname)
	local known_mod = self.savedata.known_mods[modname]
	return known_mod and known_mod.temp_enabled
end

function ModIndex:IsModTempDisabled(modname)
	local known_mod = self.savedata.known_mods[modname]
	return known_mod and known_mod.temp_disabled
end

function ModIndex:IsModForceEnabled(modname)
	if self.modsettings.forceenable[modname] ~= nil then
		return self.modsettings.forceenable[modname]
	else
		--try to fall back and find the mod without the workshop prefix (sometimes users force enable a mod by just the workshop id)
		if string.sub( modname, 0, string.len(workshop_prefix) ) == workshop_prefix then
			local alt_name = string.sub( modname, string.len(workshop_prefix) + 1 )
			return self.modsettings.forceenable[alt_name]
		end
	end
	return false
end

function ModIndex:IsModEnabledAny(modname)
	return modname and
		((self:IsModEnabled(modname) or
		self:IsModForceEnabled(modname) or
		self:IsModTempEnabled(modname)) and
		not self:IsModTempDisabled(modname))
end

function ModIndex:SetDisableSpecialEventModWarning()
	self.savedata.disable_special_event_warning = true
end

function ModIndex:GetIsSpecialEventModWarningDisabled()
	return self.savedata.disable_special_event_warning
end

function ModIndex:IsModStandalone(modname)
	local known_mod = self.savedata.known_mods[modname]
	return known_mod and known_mod.modinfo and known_mod.modinfo.standalone == true
end

function ModIndex:IsModInitPrintEnabled()
	return self.modsettings.initdebugprint
end

function ModIndex:IsModErrorEnabled()
	return self.modsettings.moderror
end

function ModIndex:IsLocalModWarningEnabled()
	return self.modsettings.localmodwarning
end

function ModIndex:Disable(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].enabled = false
end

function ModIndex:DisableAllMods()
	for k,v in pairs(self.savedata.known_mods) do
		self:Disable(k)
	end
end

function ModIndex:ClearTempModFlags(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].temp_enabled = false
	self.savedata.known_mods[modname].temp_disabled = false
	self.savedata.known_mods[modname].temp_config_options = nil

end

function ModIndex:ClearAllTempModFlags()
	--print( "ModIndex:ClearAllTempModFlags" )

	local function internal_clear_all_temp_mod_flags()
		for k,v in pairs(self.savedata.known_mods) do
			self:ClearTempModFlags(k)
		end
		self:Save(nil)
	end
	if self.savedata == nil then
		self:Load( internal_clear_all_temp_mod_flags )
	else
		internal_clear_all_temp_mod_flags()
	end
end

function ModIndex:SetTempModConfigData( temp_mods_config_data )
	print( "ModIndex:SetTempModConfigData" )
	for modname,config_data in pairs(temp_mods_config_data) do
		if self.savedata.known_mods[modname] ~= nil then
			print( "Setting temp mod config for mod ", modname )
			self.savedata.known_mods[modname].temp_config_options = config_data
		else
			assert(false, "Temp mod is missing from known mods")
		end
	end
end

function ModIndex:DisableBecauseBad(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].disabled_bad = true
	self.savedata.known_mods[modname].enabled = false
end

function ModIndex:DisableBecauseIncompatibleWithMode(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].disabled_incompatible_with_mode = true
	self.savedata.known_mods[modname].enabled = false
end

function ModIndex:Enable(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end

	if not self.savedata.known_mods[modname].enabled then
		self.savedata.disable_special_event_warning = false
	end

	self.savedata.known_mods[modname].enabled = true
	self.savedata.known_mods[modname].disabled_bad = false
	self.savedata.known_mods[modname].disabled_incompatible_with_mode = false
end

function ModIndex:TempEnable(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].temp_enabled = true
	self.savedata.known_mods[modname].disabled_bad = false
	self.savedata.known_mods[modname].disabled_incompatible_with_mode = false
end

function ModIndex:TempDisable(modname)
	if not self.savedata.known_mods[modname] then
		self.savedata.known_mods[modname] = {}
	end
	self.savedata.known_mods[modname].temp_disabled = true
end

function ModIndex:IsModNewlyBad(modname)
	local known_mod = self.savedata.known_mods[modname]
	if known_mod and known_mod.modinfo.failed then
		-- After a mod is disabled it can no longer fail;
		-- in addition, the index is saved when a mod fails.
		-- So we just have to check if the mod failed in the index
		-- and that indicates what happened last time.
		return true
	end
	return false
end

function ModIndex:KnownAPIVersion(modname)
-- ★★ 用 -1 / -2 这样的「哨兵负数」编码「模组有多旧」。
--   -2 = 从未见过（ REALLY old）；-1 = 见过但无 api_version（ Old）。
-- 【★哨兵编码的价值】
-- 调用方只需比较 `ver >= 某阈值` 就能表达「是否新到某版本」，
-- 无需关心具体是「没有」还是「很旧」。
-- ★但也有代价：哨兵值一旦被误当作真实版本号参与运算就会出错。
-- ★这是「用单个整数编码多档状态」的经典手法，移植时要注意语义隔离。
	local known_mod = self.savedata.known_mods[modname]
	if not known_mod or not known_mod.modinfo then
		return -2 -- If we've never seen the mod before, we assume it's REALLY old
	elseif not known_mod.modinfo.api_version then
		return -1 -- If we've seen it but it has no info, it's just "Old"
	else
		return known_mod.modinfo.api_version
	end
end

function ModIndex:IsModNew(modname)
-- 「是否为新模组」= 索引里没有 或 还没有 modinfo。
	return not self.savedata.known_mods[modname] or not self.savedata.known_mods[modname].modinfo
end

function ModIndex:IsModKnownBad(modname)
	return self.savedata.known_mods[modname] and self.savedata.known_mods[modname].disabled_bad
end

-- When the user changes settings it messes directly with the index data, so make a backup
-- ★★ 深度拷贝快照，供「用户取消修改后回滚」使用。
-- 原注释：When the user changes settings it messes directly with the index data,
--           so make a backup。
-- 【★为什么需要】
-- 模组勾选界面直接改 known_mods（没有「编辑-提交」的两阶段）。
-- 用户点「取消」时必须能撤销。
-- ★代价是 deepcopy 一整个表 —— 模组多时有一定开销。
--   更省的做法是「操作日志」（记录改了什么，取消时反向应用）。
function ModIndex:CacheSaveData()
	self.cached_data = {}
	self.cached_data.savedata = deepcopy(self.savedata)
	self.cached_data.modsettings = deepcopy(self.modsettings)
	return self.cached_data
end

-- If the user cancels their mod changes, restore the index to how it was prior the changes.
function ModIndex:RestoreCachedSaveData(ext_data)
-- 恢复快照。ext_data 优先，允许调用方传入别的快照（多份备份）。
-- 【★「外部传入快照」支持了什么】
-- 模组列表界面可以先保存一份、试探性修改、再对比选择保留哪份。
	if ext_data then
		self.savedata = ext_data.savedata
		self.modsettings = ext_data.modsettings
	elseif self.cached_data then
		self.savedata = self.cached_data.savedata
		self.modsettings = self.cached_data.modsettings
	end
end

function ModIndex:UpdateModSettings()
-- ★ 从 modsettings.lua 读取开发者专用开关。
-- ★全部默认值都是「安全」的一侧：
--   disablemods = true          → 默认禁用模组（出问题时的安全姿态）
--   localmodwarning = true      → 默认警告本地模组
-- 强制启用必须通过显式调用 ForceEnableMod，且会打印醒目警告（第 1092 行）。
-- ★「默认禁用 + 显式开启」+「开启时告知后果」，是好实践。

	self.modsettings = {
		forceenable = {},
		disablemods = true,
		localmodwarning = true
	}

	local function ForceEnableMod(modname)
-- ★ 警告文案很有分寸：「若你不是在开发模组，请用游戏内菜单」。
-- 因为模组开发者清楚 forceenable 会覆盖玩家设置，普通玩家不知道。
		print("WARNING: Force-enabling mod '"..modname.."' from modsettings.lua! If you are not developing a mod, please use the in-game menu instead.")
		self.modsettings.forceenable[modname] = true
	end
	local function EnableModDebugPrint()
		self.modsettings.initdebugprint = true
	end
	local function EnableModError()
		self.modsettings.moderror = true
	end
	local function DisableModDisabling()
		self.modsettings.disablemods = false
	end
	local function DisableLocalModWarning()
		self.modsettings.localmodwarning = false
	end

	local env = {
-- ★★ 沙箱只有 6 个白名单函数，没有任何其他能力。
-- 与 InitializeModInfo（第 593 行）同样的安全思路。
-- 【★这个沙箱比 modinfo 更严】
-- modsettings 只提供 6 个「开关 setter」，不给任何读接口，更不给 I/O。
-- ★白名单式沙箱的设计原则：暴露的每个函数都是纯粹的「意图声明」，
--   而非「能力授予」。
		ForceEnableMod = ForceEnableMod,
		EnableModDebugPrint = EnableModDebugPrint,
		EnableModError = EnableModError,
		DisableModDisabling = DisableModDisabling,
		DisableLocalModWarning = DisableLocalModWarning,
	}

	local filename = MODS_ROOT.."modsettings.lua"
	local fn = kleiloadlua( filename )
	if fn == nil then
		print("could not load modsettings: "..filename)
		print("Warning: You may want to try reinstalling the game if you need access to forcing mods on.")
	else
		if type(fn)=="string" then
			error("Error loading modsettings:\n"..fn)
		end
		setfenv(fn, env)
-- ★ setfenv(fn, env) —— Lua 5.1 的环境替换机制。
-- ⚠️ Lua 5.2 起 setfenv 已被移除（改用 load 的 env 参数）。
--   DST 运行时是 Lua 5.1，所以可用；我们的 Lua 5.5 校验环境则会失败。
-- ★这属于「运行时版本相关代码」，迁移到新 Lua 时需改写。
		fn()
-- ★ 立即执行。执行结果被丢弃 —— 它只靠副作用改 modsettings。
	end
end

local function IsModAlreadyDepended(deps, new_deps)
-- 判断新依赖列表里是否已有某个依赖（用于去重）。
-- ★用表当 Set：deps[mod] 为真即已依赖。O(1) 且天然去重。
	for i, mod in ipairs(new_deps) do
		if deps[mod] then
			return true
		end
	end
	return false
end

function ModIndex:GetModDependencies(modname, recursive, rec_deps)
-- ★★★ 递归解析模组依赖树。
--
-- 【★防循环依赖的两处设计，是本函数的关键】
--   第 1140 行：`if not rec_deps then self:UpdateModInfo() end`
--     只在首次调用时更新索引，递归途中不再更新 ——
--     否则每层递归都重扫磁盘，性能会爆炸。
--   第 1150 行：`deps[modname] = true`
--     ★先把「自己」标记为已依赖，再递归子依赖。
--     这是标准的有向图 DFS 环检测手法：A->B->A 时，
--     第二次遇到 A 已在 deps 里，就地剪枝，不会无限递归。
--
-- 【★换个写法会怎样错】
-- 若不加第 1150 行，A 依赖 B、B 依赖 A 会导致栈溢出（无限递归）。
-- ★移植启示：任何递归遍历图结构，都必须自带 visited 集合。
	if not rec_deps then
		self:UpdateModInfo()
	end
	local dependencies = self.savedata.known_mods[modname] and self.savedata.known_mods[modname].dependencies
-- 取本模组的直接依赖列表。取不到就返回空表（而非 nil）。
-- ★返回空表而非 nil，调用方就无需判空 —— 「用空集合代替空值」的好习惯。
	if not dependencies then
		return {}
	end
	local deps = rec_deps or {}
	local new_deps = {}
	--add our modname to the deps to prevent circular dependency loops
	deps[modname] = true
	for i, mods_dep in ipairs(dependencies) do
		if not IsModAlreadyDepended(deps, mods_dep) then
-- 去重后加入新依赖集合。
-- 【★依赖以「表」而非数组存储】
-- 因为依赖天然去重，且第 1158 行要按名字遍历它们 ——
-- 用数组会导致同一依赖重复出现并需要额外去重。
			deps[mods_dep[1]] = true
			new_deps[mods_dep[1]] = true
		end
	end
	if recursive then
-- ★ 递归展开子依赖，形成传递闭包。
-- 传的是同一个 deps 表（第 1159 行），所以标记会累积 ——
-- 这正是防环机制能在多层生效的原因。
-- ⚠️ 注意遍历用的是 pairs，顺序不确定。
-- 对「收集依赖集合」无影响（结果是集合），但若将来依赖之间有顺序语义，
--   需要改成 ipairs 并对 dependencies 数组排序。
		for _modname, _ in pairs(new_deps) do
			self:GetModDependencies(_modname, recursive, deps)
		end
	end
	--rec_deps will be nil when called externally
	if not rec_deps then
		deps[modname] = nil
		return table.getkeys(deps)
	end
end

function ModIndex:GetModDependents(modname, recursive, rec_deps)
	local deps = rec_deps or {}
	local new_deps = {}
	--add our modname to the deps to prevent circular dependency loops
	deps[modname] = true
	for _modname, modslist in pairs(self.mod_dependencies.dependency_list) do
		if not deps[_modname] then
			for _, _modnamedep in ipairs(modslist) do
				if modname == _modnamedep then
					deps[_modname] = true
					new_deps[_modname] = true
				end
			end
		end
	end
	if recursive then
		for _modname, _ in pairs(new_deps) do
			self:GetModDependents(_modname, recursive, deps)
		end
	end

	--rec_deps will be nil when called externally
	if not rec_deps then
		deps[modname] = nil
		return table.getkeys(deps)
	end
end

function ModIndex:IsModDependedOn(modname)
	return (self.mod_dependencies.server_dependency_list[modname] or 0) > 0
end

function ModIndex:SetDependencyList(modname, modslist, nosubscribe)
	self.mod_dependencies.dependency_list[modname] = modslist
	for i, mod in ipairs(modslist) do
		self:AddModDependency(mod, nosubscribe)
	end
end

function ModIndex:AddModDependency(modname, nosubscribe)
	if IsWorkshopMod(modname) and not KnownModIndex:DoesModExistAnyVersion(modname) then
		if nosubscribe then return end
		TheSim:SubscribeToMod(modname)
	end
	self.mod_dependencies.server_dependency_list[modname] = (self.mod_dependencies.server_dependency_list[modname] or 0) + 1
end

function ModIndex:ClearModDependencies(modname)
    if modname == nil then
        self.mod_dependencies.server_dependency_list = {}
        self.mod_dependencies.dependency_list = {}
    else
        for i, v in ipairs(self.mod_dependencies.dependency_list[modname] or {}) do
            self.mod_dependencies.server_dependency_list[v] = (self.mod_dependencies.server_dependency_list[v] or 0) - 1
        end
        self.mod_dependencies.dependency_list[modname] = nil
    end
end

function ModIndex:GetModDependenciesEnabled()
	for k, v in pairs(self.mod_dependencies.server_dependency_list) do
		if (v or 0) > 0 and not self:IsModEnabled(k) then
			return false
		end
	end
	return true
end

function ModIndex:DoesModExistAnyVersion( modname )
	local modinfo = self:GetModInfo(modname)
	if modinfo ~= nil then
		return true
	else
		return false
	end
end

function ModIndex:DoModsExistAnyVersion(modlist)
    for i, v in ipairs(modlist) do
        if not self:DoesModExistAnyVersion(v) then
            return false
        end
    end
    return true
end

function ModIndex:DoesModExist( modname, server_version, server_version_compatible )
	self:UpdateSingleModInfo(modname)
	if server_version_compatible == nil then
		--no compatible flag, so we want to do an exact version check
		local modinfo = self:GetModInfo(modname)
		if modinfo ~= nil then
			return server_version == modinfo.version
		end
		print("Mod "..modname.." v:"..server_version.." doesn't exist in mod dir ")
		return false
	else
		local modinfo = self:GetModInfo(modname)
		if modinfo ~= nil then
			if server_version >= modinfo.version then
				--server is ahead or equal version, check if client is compatible with server
				return modinfo.version >= server_version_compatible
			else
				--client is ahead, check if server is compatible with client
				return server_version >= modinfo.version_compatible
			end
		end
		print("Mod "..modname.." v:"..server_version.." vc:"..server_version_compatible.." doesn't exist in mod dir ")
		return false
	end
end

function ModIndex:GetEnabledModTags()
	local tags = {}
	for name,data in pairs(self.savedata.known_mods) do
		if data.enabled then
			local modinfo = self:GetModInfo(name)
			if modinfo ~= nil and modinfo.server_filter_tags ~= nil then
				for i,tag in pairs(modinfo.server_filter_tags) do
					table.insert(tags, tag)
				end
			end
		end
	end
	return tags
end


function ModIndex:DisableClientMods( disabled ) --to be called from the server/host when loading mod overrides. Note, this is not saved out to the mod index file on the clients, it's applied through the server listing temp disabling individual client mods when connecting
	self.client_mods_disabled = disabled
end

function ModIndex:AreClientModsDisabled()
	return self.client_mods_disabled
end

KnownModIndex = ModIndex()