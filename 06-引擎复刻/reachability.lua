--[[
==============================================================================
 reachability.lua —— 预制体可达性抽样（第 14 个入口）
==============================================================================
为什么要做成入口
    「985 / 1000 = 1.50%」这个数字此前是**内联脚本**跑出来的，
    脚本没留下 ⇒ 数字**不可复现**，直接违反本工程自己的验收标准第 7 条
    （「所有数字都能用文档里的命令复现」）。
    同时 `armor_lunarplant` 那条「根因未定」也没法在固定上下文里重放
    —— 抽样脚本一删，症状就再也复现不出来。

本入口做什么
   1. 与 full.lua 同样的全量注册（保证注册表口径一致）
   2. 在注册表名字上做**带种子的确定性抽样**（默认 300，可用 REACH_N 覆盖）
   3. 逐个 xpcall spawn，失败时抓**出错文件:行号**（不是只有一句文字）
   4. 按**已查明的性质**分类，并把每一类的处置写清

分类口径（必须与文档一致，改口径要同步改文档）
   未注册        —— 懒加载之后注册表里依然没有
   运行时报错    —— 注册了，但工厂函数抛错（带 prefabs/xxx.lua:NN）
   宿主边界(数据)—— DLC/活动内容：宿主 scripts/ 是部分提取
   宿主边界(客户端) —— 需要 EnvelopeManager 而 DST 里它就是 nil
   已知假象      —— world / net 互斥单例，两个只能有一个被注册

环境变量
   REACH_N      样本量（默认 300）
   REACH_SEED   抽样种子（默认 20261015）
   REACH_LIST   1 = 逐条打印全部失败（默认只打前 20）
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")

Bootstrap.Setup()
WorldMap.Generate({ seed = 20261015 })

local N    = tonumber(os.getenv("REACH_N")) or 300
local SEED = tonumber(os.getenv("REACH_SEED")) or 20261015

--=========================================================================
-- 一、全量注册（与 full.lua 同口径）
--=========================================================================
local PF = Core.SourceDir .. "/prefabs"

local function listdir(dir)
    local out = {}
    local p = io.popen('dir /b "' .. dir:gsub("/", "\\") .. '" 2>nul')
    if p then
        for line in p:lines() do
            local name = line:match("^%s*(.-)%s*$")
            if name ~= "" and name:match("%.lua$") then out[#out + 1] = name end
        end
        p:close()
    end
    return out
end

local files = listdir(PF)
table.sort(files)
if #files == 0 then
    print("✘ 无法枚举 prefabs/ 目录: " .. PF)
    os.exit(1)
end

local regok, regfail = 0, 0
for _, f in ipairs(files) do
    local ok = Loader.LoadFile(PF .. "/" .. f)
    if ok then regok = regok + 1 else regfail = regfail + 1 end
end

--=========================================================================
-- 二、确定性抽样
--=========================================================================
local names = {}
for k in pairs(Core.Prefabs) do names[#names + 1] = k end
table.sort(names)

-- ★ 用自带 LCG 而不是 math.random：Lua 5.1 的 math.random 在不同解释器上
--   序列可能不同（lupa 里尤其），那样「种子固定」也只是看起来可复现。
local function lcg(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s
    end
end

local function sample(list, n, seed)
    local idx = {}
    for i = 1, #list do idx[i] = i end
    local rnd = lcg(seed)
    local out = {}
    local want = math.min(n, #list)
    for i = 1, want do
        local j = i + (rnd() % (#list - i + 1))
        idx[i], idx[j] = idx[j], idx[i]
        out[i] = list[idx[i]]
    end
    return out
end

local pick = sample(names, N, SEED)

--=========================================================================
-- 三、逐个 spawn
--=========================================================================
-- ★ 分类**不再靠猜**：全部走 host/26_boundaries.lua 的登记表。
--   规则（按优先级）：
--     ① 个案登记（CASES）—— 有源码级证据的已知不可达
--     ② 结构性规则（RULES）—— 按现象判定（event_server 降级 / 客户端渲染）
--     ③ 查不到 ⇒ **「未定性 —— 必须去查」**，直接印在报告里
--   ⚠️ 上一版把这三类混在一个 if/else 链里、判据写死在函数体内，
--      结果 `lavaarenastage_dialog` 被归成「工厂返回 nil」（看着像代码缺陷），
--      而它其实是 event_server 数据边界。判据必须与解释放在同一张表里。
local Boundaries = require("host.26_boundaries")
local okB, auditProblems = Boundaries.Audit()
if not okB then
    print("⚠ 边界登记表自检不过：")
    for _, p in ipairs(auditProblems) do print("   " .. p) end
end

local function first_src_line(err)
    local e = tostring(err)
    -- 取第一条指向 DST 源码的 `xxx.lua:NN`
    local best = nil
    for path, line in e:gmatch("([%w_%./%-]+%.lua):(%d+)") do
        if path:find("prefabs/") or path:find("scripts/") or path:find("components/") then
            local short = path:match("([^/\\]+)$") or path
            if not best then best = short .. ":" .. line end
        end
    end
    if best then return best end
    local first = e:match("^[^\n]*")
    return (first or "?"):sub(1, 140)
end

local function esd_hits()
    return (Core.EventServerDegraded and Core.EventServerDegraded.count) or 0
end

--- （已移除）工厂参数个数的运行时反射
-- ★ 曾经想用「工厂声明了几个参数」来识别 `carnivaldecor_figure` 那一类，
--   试了两种反射，**在这个 Lua 5.1 实现上都不成立**：
--     ✘ debug.getinfo(fn, "u").nparams  —— 恒为 nil（nups 有值、nparams 没有）
--     ✘ debug.getlocal(fn, 1)           —— 5.1 的签名是 getlocal(level, local)，要栈层号
--   ⇒ 改成**静态扫描**：tools/scan_parameterized_factories.py
--     结果落进 host/26_boundaries.lua 的个案表（4 个 carnival 系条目）。
--   留这段注释是为了防止后人再试一遍这两条路。

local pass, fail = 0, {}
local t0 = os.clock()

for _, name in ipairs(pick) do
    local hit0 = esd_hits()
    -- ★ 先 PrefabExists：它会做懒加载（对齐真实引擎的「spawn 前一定注册好」）
    local exists = PrefabExists(name)

    local ctx = { exists = exists, event_server_hits = 0 }
    local ok, res = true, nil
    local record = false

    if not exists then
        ctx.nil_return = false
        record = true
    else
        ok, res = xpcall(function()
            local inst = SpawnPrefab(name)
            if inst ~= nil then pcall(function() inst:Remove() end) end
            return inst
        end, debug.traceback)
        ctx.event_server_hits = esd_hits() - hit0
        if ok and res ~= nil then
            pass = pass + 1
        else
            ctx.err = ok and nil or res
            ctx.nil_return = (ok and res == nil)
            record = true
        end
    end

    if record then
        local cls, why, proof = Boundaries.Explain(name, ctx)
        fail[#fail + 1] = {
            name = name,
            kind = cls,
            line = (ctx.err and first_src_line(ctx.err))
                or (ctx.nil_return and "（SpawnPrefab 返回 nil）")
                or "（懒加载后仍未注册）",
            why = why,
            proof = proof,
        }
    end
end

local dt = (os.clock() - t0) * 1000

--=========================================================================
-- 四、报告
--=========================================================================
print("")
print("══════════════════════════════════════════════════════════════")
print("  预制体可达性抽样")
print("══════════════════════════════════════════════════════════════")
print(string.format("  注册表预制体总数   : %d", #names))
print(string.format("  扫描文件           : %d（成功 %d / 失败 %d）", #files, regok, regfail))
print(string.format("  样本量 REACH_N     : %d      种子 REACH_SEED: %d", #pick, SEED))
print(string.format("  可达               : %d", pass))
print(string.format("  不可达             : %d", #fail))
print(string.format("  可达率             : %.2f%%", pass / #pick * 100))
print(string.format("  用时               : %.0f ms", dt))
print("")

-- 分类统计
local buckets, order = {}, {}
for _, f in ipairs(fail) do
    if not buckets[f.kind] then buckets[f.kind] = {}; order[#order + 1] = f.kind end
    table.insert(buckets[f.kind], f)
end
table.sort(order)

--=========================================================================
-- ★★ T27 分类**守恒断言**：各类别条数之和必须 == 不可达数
--=========================================================================
--   为什么要这条：分类是**人工登记 + 规则匹配**，而它直接决定报告的结论
--   （「42 条全部定性质」这句话的支撑就是它）。
--   一旦有人改动分类逻辑、或某条失败项的 kind 变成空串，
--   可能出现「有失败项没被计入任何类别」—— 而报告仍会照样印出分类表，
--   **少一行没人看得出来**。这正是本工程反复吃亏的「静默漏掉」。
--
--   判据选「**守恒量**」而不是「逐项检查」：类别名会变、条目会增减，
--   但「各类别之和 = 总数」这个等式**任何改动下都必须成立**。
local _sum, _empty = 0, 0
for _, k in ipairs(order) do
    _sum = _sum + #buckets[k]
    if k == "" or k == "?" then _empty = _empty + 1 end
end
local _conserve_ok = (_sum == #fail) and (_empty == 0)
if not _conserve_ok then
    print(string.format("  ✘ 分类守恒被打破：各类别之和 %d ≠ 不可达 %d（空类别 %d 个）" ..
        " —— 有失败项没被计入，报告的分类表不可信", _sum, #fail, _empty))
end

if #fail > 0 then
    print("── 失败分类 ──")
    for _, k in ipairs(order) do
        print(string.format("  %-18s %d", k, #buckets[k]))
    end
    print("")

    local limit = os.getenv("REACH_LIST") == "1" and #fail or math.min(20, #fail)
    print(string.format("── 失败明细（%d / %d）──", limit, #fail))
    for i = 1, limit do
        local f = fail[i]
        print(string.format("  %-34s %-24s %s", f.name, f.kind, f.line))
        -- ★ 连 why/proof 一起打：只给类别名等于让人回去重推一遍。
        --   这是本工程反复吃亏的地方（「我猜错了」被当成「宿主有缺口」）。
        if f.why then
            print(string.format("      理由: %s", f.why))
        end
        if f.proof then
            print(string.format("      取证: %s", f.proof))
        end
    end
    if limit < #fail then
        print(string.format("  … 另有 %d 条（REACH_LIST=1 看全部）", #fail - limit))
    end
    print("")

    -- ★ 未定性条目数必须**显眼**：> 0 就说明还有活要干
    -- ★ 用 Boundaries 的**常量**查，不再抄字面量（见 host/26_boundaries.lua 的说明）
    local undetermined = buckets[Boundaries.UNDETERMINED]
    if undetermined then
        print(string.format("  ⚠ 未定性 %d 条 —— 这些都是**待查缺口**，不是已知边界。",
            #undetermined))
        print("")
    end
end

if regfail > 0 then
    print(string.format("⚠ 注册阶段有 %d 个文件加载失败（与 full.lua 口径对齐才能比数）", regfail))
end
-- ⚠️ 措辞：`_sum` 是「各类别**条数**之和」，不是「类数」——
--    第一版写成「%d 类之和」⇒ 印出「42 类之和 = 不可达 42」，
--    读起来像「有 42 个类别」，而实际只有 %d 个类别、共 42 条。
print(string.format("  分类守恒           : %s（%d 个类别 / 共 %d 条 = 不可达 %d）",
    _conserve_ok and "✔" or "✘ 被打破", #order, _sum, #fail))
-- ★★ T46：印出**类别名清单**，与报告 §46 的规范清单对账。
--   为什么值得单独印：报告 §46 是一张**由代码生成**的规范表，
--   而「生成过」不等于「现在还对得上」。把类别名与数量印在入口输出里，
--   任何一次运行都能肉眼（或机器）对齐一次，不需要额外工具。
do
    local names, keys = {}, {}
    local CLS = Boundaries.CLASS or {}
    for k, v in pairs(CLS) do
        if k ~= "UNDETERMINED" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do names[#names + 1] = k .. "=" .. CLS[k] end
    print(string.format("  类别名定义         : %d 个（报告 §46 应与之一致）", #keys))
    print("    " .. table.concat(names, " ｜ "))
end

local ncase, nrule = Boundaries.Count()
print(string.format("  边界登记表         : %d 条个案 / %d 条规则（host/26_boundaries.lua）"
    .. (okB and "  自检通过" or "  ✘ 自检不过"), ncase, nrule))
print(string.format("  event_server 降级  : 累计 %d 次", esd_hits()))
print("══════════════════════════════════════════════════════════════")
