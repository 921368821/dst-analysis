--[[
==============================================================================
 26_boundaries.lua —— 「哪些不可达不算缺陷」的**机器可读**登记表
==============================================================================
为什么要有这个文件
   可达性抽样的输出必须能把「宿主缺口」和「本来就不可达」分开。
   此前这条判断写在**我脑子里**（报告第 36 节的散文里），
   于是每次重跑都要重新推导一遍，而且很容易把
   「我猜错了」写成「宿主有缺口」（今天已经发生多次）。

   把判据落成**数据**之后：
     · reachability.lua 直接查它，不再靠猜
     · tests.lua 可以断言这张表本身（条目齐全、判据有出处）
     · 报告里的边界清单与代码里的表**同源**，不会各自漂移

每条登记必须给三样东西（缺一样就不算定性）：
   class   —— 类别
   why     —— 为什么不算宿主缺陷（一句话）
   proof   —— 可复跑的取证方式（文件:行 / 工具命令）

★★ 硬性要求：`proof` 里必须出现**可查证的具体位置**，
   不接受「经验上」「一般不会」这类说法。
==============================================================================
]]

local Boundaries = {}
local CLASS  -- 前向声明（定义在下方，CASES 要用）

--=========================================================================
-- 一、个案登记（按预制体名）
--=========================================================================
-- ★ 这些是**抽样实际撞到过**的个案，每条都有源码级证据。
-- ★★★ 未定性类别名 —— **只在这里定义一次**
--   原先这个字符串有**两处**：本文件的 `Explain()` 返回它，
--   而 `reachability.lua:277` 又用字面量 `buckets["未定性 —— 必须去查"]` 去查它。
--   两处靠「抄得一样」维系 ⇒ 只要有人改了其中一处的**措辞**，
--   查表就命中不了，而 `⚠ 未定性 N 条` 会**静默不再打印** ——
--   看起来像「本次没有任何未定性」，实际是**那条警告失效了**。
--   ⇒ 定义成常量，双方引用同一份；并加断言（见 tests.lua T23）保证
--     「常量 == Explain(未知名字) 的返回值」这个等式永远成立。
Boundaries.UNDETERMINED = "未定性 —— 必须去查"


--=========================================================================
-- ★★★ T39：**类别名只定义一次**
--=========================================================================
--   原先这 8 个类别名以**字面量**散在 CASES / RULES 里，共 **17 处** ——
--   同一个名字抄 2~4 遍（如「世界根预制体(非场景实体)」×4）。
--   两处靠「抄得一样」维系的名字，**改一处就会漂移**：
--     漂移之后不会报错，只会让查表/统计**静默命中不了**。
--   （今天已经因为同一类问题吃过亏：`未定性` 那处漂移会让 `⚠ N 条` 警告静默失效。）
--   ⇒ 全部收敛到本表；CASES/RULES 只引用 `CLASS.XXX`。
--   `Audit()` 里加了两道机械判据：
--     ① 每个 class 取值必须是本表里的某个值；
--     ② 每个类别**字面量**在本文件里只允许出现 **1 次**（就是本表的定义处）。
CLASS = {
    UNDETERMINED   = Boundaries.UNDETERMINED,
    EVENT_SERVER    = "宿主边界(数据·event_server)",
    WORLD_ROOT      = "世界根预制体(非场景实体)",
    WORLD_ROOT_NET  = "世界根预制体(网络单例)",
    WORLD_ROOT_REG  = "世界根预制体(注册期登记)",
    ORIGINAL_PARAM  = "原版缺陷(工厂声明参数·无无参调用点)",
    ORIGINAL_DEAD   = "原版潜在缺陷(无调用点)",
    ASSET_BUNDLE    = "资产包预制体(工厂故意为空)",
    CLIENT_RENDER   = "宿主边界(客户端渲染)",
    NO_ASSET_DATA   = "宿主边界(本机缺原版资产 data/)",
    -- ★★ P41 / T8：**运行时约束**这一类要单列。
    --   它不是「宿主没实现」，也不是「原版缺陷」，而是
    --   **我们选的这个 Lua 运行时**（lupa 的 lua51 / LuaJIT）的硬上限。
    --   同一个文件换 Lua 5.2+ 就能编译 —— 这说明问题不在代码、在运行时。
    --   登记成条件规则（见下面 RULES 里那条），条件写清楚：
    --     **只在 Lua 5.1 / LuaJIT 下成立**，换 5.2+ 就不成立。
    LUA51_UPVALUE   = "运行时约束(Lua 5.1/LuaJIT 的 60 upvalue 上限)",
}

Boundaries.CLASS = CLASS

Boundaries.CASES = {

    ["hermitcrabtea_firenettles_buff"] = {
        class = CLASS.ORIGINAL_DEAD,
        why = "prefab 工厂 `StartTimer(BUFF_TIMER, nil)` ⇒ `DoTaskInTime(nil)`。"
           .. "该 buff 在 BUFF_DEFS 里没有 duration，且**没有任何 TEA_DEFS 的 "
           .. "buff= 引用它** ⇒ 原版运行时从不 spawn 它。"
           .. "即便 spawn，原版 timer.lua:46 `end_time = GetTime() + time` 也会崩，"
           .. "与宿主调度器无关。",
        proof = "tools/prove_hermitcrabtea_nil_duration.py"
             .. "（BUFF_DEFS 无 duration: succulent_picked / firenettles；"
             .. "TEA_DEFS 引用的 buff 只有 6 个，不含这两个）；"
             .. "components/timer.lua:44-46",
    },

    ["hermitcrabtea_succulent_picked_buff"] = {
        class = CLASS.ORIGINAL_DEAD,
        why = "同 firenettles_buff：无 duration、无引用。",
        proof = "tools/prove_hermitcrabtea_nil_duration.py；components/timer.lua:44-46",
    },

    ["lavaarenastage_dialog"] = {
        class = CLASS.EVENT_SERVER,
        why = "工厂体是 `event_server_data(\"lavaarena\", \"prefabs/lavaarena_eventstages\")"
           .. "[\"dialogfn\"]()`，而 `lavaarena_event_server/` 不在本工程的脚本副本里"
           .. "（scripts/ 是部分提取）⇒ 降级代理返回 nil ⇒ 工厂返回 nil。"
           .. "缺的是活动专属数据，不是代码。",
        proof = "prefabs/lavaarena_eventstages.lua:15-17；"
             .. "宿主降级计数 Core.EventServerDegraded",
    },

    ["world"] = {
        class = CLASS.WORLD_ROOT,
        why = "它是**世界生成器**造出来的根预制体（MakeWorld 的产物），"
           .. "不是场景实体；用 `SpawnPrefab(\"world\")` 去生成它本来就没有意义。"
           .. "抽样脚本把所有注册名当普通预制体逐个 spawn，抽到它必然「返回 nil」。",
        proof = "prefabs/world.lua:401 `function MakeWorld(...)`；"
             .. "prefabs/world_network.lua:38 `MakeWorldNetwork`；"
             .. "prefabs/forest.lua / cave.lua / quagmire.lua / lavaarena.lua 都是它的调用方",
    },
    ["net"] = {
        class = CLASS.WORLD_ROOT,
        why = "同 world：world 与 net 是同一层的两个根预制体（一个世界进程只会注册其中一个），"
           .. "都不是可直接 spawn 的场景实体。",
        proof = "prefabs/world_network.lua:38 `MakeWorldNetwork(name, ...)` 建 "
             .. "`net`；prefabs/world.lua:401 建 `world`",
    },
    ["quagmire"] = {
        class = CLASS.WORLD_ROOT,
        why = "`return MakeWorld(\"quagmire\", ...)` —— 与 world/cave/forest 同类，"
           .. "是活动世界类型，不是场景实体。",
        proof = "prefabs/quagmire.lua:264 `return MakeWorld(\"quagmire\", ...)`",
    },

    ["global"] = {
        class = CLASS.ASSET_BUNDLE,
        why = "`prefabs/global.lua` 整份文件只做一件事：把声音包（fev/fsb）"
           .. "登记成资源，**工厂体字面就是空的**。原版靠 `LoadPrefabFile` 触发"
           .. "资源登记，从不 `SpawnPrefab` 它 ⇒ 返回 nil 是**设计如此**。"
           .. "★ 这是本轮唯一一条能直接指着源码字面量说清的："
           .. "工厂体写的就是 `function() end`。",
        proof = "prefabs/global.lua:641 `return Prefab(\"global\", function() end, assets)`",
    },

    ["quagmire_food"] = {
        class = CLASS.ASSET_BUNDLE,
        why = "与 `global` 同型：`quagmire_foods.lua` 用同一句注册好几个食物条目，"
           .. "工厂体是 `function() end` —— 只为把资源登记进去，从不 spawn。",
        proof = "prefabs/quagmire_foods.lua:116 "
             .. "`table.insert(ret, Prefab(\"quagmire_food\", function() end, nil, prefs))`",
    },

    ["carnivaldecor_figure"] = {
        class = CLASS.ORIGINAL_PARAM,
        why = "注册写的是 `Prefab(\"carnivaldecor_figure\", fn_season1, ...)`，"
           .. "而 `fn_season1(data)` 把 data 原样转给 `fn(data, 1, bank)`；"
           .. "无参调用时 data = nil ⇒ `data.physics_radius` 崩。"
           .. "★ 关键实证：`tools/scan_parameterized_factories.py` 扫出**全库 27 个**"
           .. "「直接注册的带参工厂」，逐个实测 **23 个在无参调用下正常生成** ⇒ "
           .. "「引擎无参调用工厂」这条约定在本工程的语料上是成立的；"
           .. "剩下 4 个（carnivaldecor_figure / _season2 / _season3 / carnivaldecor_lamp）"
           .. "是**同一份文件的同一种写法** ⇒ 更像该内容自身的缺陷而非宿主缺口。"
           .. "★ 外部证据（2026-10-15 用 WebSearch 找到，把这条从「待定」升级为「原版缺陷」）："
           .. "Klei 官方论坛的《Understanding Prefabs》把构造器写成 `local function fn()`"
           .. "（**无参**）；DST 模组 API 文档写 `fn — 创建并返回实体实例的工厂函数`，"
           .. "参数表里**没有** name/skin；entity 系统文档写 `SpawnPrefab(prefabname)`"
           .. "「查表 → 调用构造器」，**没有向构造器转发任何参数**。"
           .. "⇒ 三处独立文档一致：引擎不向工厂传参。"
           .. "证据级别：**外部文档 + 本工程实证（23/27）双重支持**，"
           .. "但**不是引擎二进制反汇编**——所以结论写「原版缺陷」而不是「已证实」。",
        proof = "tools/scan_parameterized_factories.py（27 命中 / 23 通过，"
             .. "4 个 carnival 系失败）；正面证据 prefabs/oar.lua:152 / "
             .. "schoolherd.lua:172 / cotl_tabernacle.lua:324；"
             .. "崩点 prefabs/carnivaldecor_figure.lua:189、carnivaldecor_lamp.lua:156",
    },
    ["carnivaldecor_figure_season2"] = {
        class = CLASS.ORIGINAL_PARAM,
        why = "同 carnivaldecor_figure（同一文件的 season2 变体，工厂参数 data 无来源）。",
        proof = "tools/scan_parameterized_factories.py；prefabs/carnivaldecor_figure.lua:189",
    },
    ["carnivaldecor_figure_season3"] = {
        class = CLASS.ORIGINAL_PARAM,
        why = "同 carnivaldecor_figure（同一文件的 season3 变体，工厂参数 data 无来源）。",
        proof = "tools/scan_parameterized_factories.py；prefabs/carnivaldecor_figure.lua:189",
    },
    ["carnivaldecor_lamp"] = {
        class = CLASS.ORIGINAL_PARAM,
        why = "同 carnivaldecor_figure：`Prefab(\"carnivaldecor_lamp\", fn, ...)` 而 "
           .. "`fn(data)`；无参调用时 data = nil ⇒ carnivaldecor_lamp.lua:156 崩。",
        proof = "tools/scan_parameterized_factories.py；prefabs/carnivaldecor_lamp.lua:156",
    },
}

--=========================================================================
-- 二、结构性规则（按现象判定，不需要逐个点名）
--=========================================================================
-- detect(name, ctx) -> class | nil
--   ctx = {
--       exists              懒加载后注册表里有没有
--       err                 出错文本（nil = 没抛错）
--       nil_return          spawn 返回了 nil
--       event_server_hits   本次 spawn 期间 event_server_data 降级次数
--   }
Boundaries.RULES = {
    -- ★★★ P41 / T8：**Lua 5.1 的 60 upvalue 上限**（有条件的运行时约束）
    --
    --   实证（命令 + 输出都在下面对应字段里）：
    --     `components/weather.lua:2051: function at line 1622 has more than 60 upvalues`
    --   5.1 / LuaJIT 2.0 / 2.1 全部失败；**5.2 / 5.3 / 5.4 / 5.5 全部编译通过**。
    --
    --   ★★ 关键在于**这条规则是有条件的**，不能当成永久结论：
    --     条件写清楚 = 「本运行时是 5.1 族」。换 lupa 的 lua54 就能加载。
    --     所以这里**不改原版脚本、也不打补丁** —— 打补丁等于掩盖
    --     「我们选了 5.1」这个事实，而那个选择是可换的。
    --   ★ 反过来也要说清：DST 官方客户端也是 Lua 5.1 族，
    --     它能跑说明**原版 weather.lua 的 OnUpdate 没超 60**。
    --     我们这份是**逐行注释版**，最可能是在注释改写时把某些 `local`
    --     挪了作用域 ⇒ 多抓了 upvalue。这条**未完全证实**，如实写在这里，
    --     不冒充结论（要证实得拿到未注释副本逐行 diff，本机没有）。
    {
        class = CLASS.LUA51_UPVALUE,
        why = "Lua 5.1 与 LuaJIT 对**单个函数的 upvalue 数量**有硬上限 60，"
           .. "超出即编译期失败（不是运行时错）。同一份文件在 5.2+ 上编译通过 ⇒ "
           .. "这是**运行时选择的限制**，不是宿主实现缺口，也不是原版脚本的缺陷。"
           .. "⚠️ 本条**只在 Lua 5.1/LuaJIT 下成立**；换 5.2+ 运行时该规则不适用。",
        proof = "lupa 多运行时实测（2026-10-18）：5.1 / jit2.0 / jit2.1 ⇒ "
             .. "`components/weather.lua:2051: function at line 1622 has more than 60 "
             .. "upvalues`；5.2 / 5.3 / 5.4 / 5.5 ⇒ 编译通过（loadfile 返回非 nil）。"
             .. "复现：tools/check_lua_runtimes.py（同一份文件跑 7 个运行时）。",
        detect = function(name, ctx)
            local e = ctx and ctx.err
            return type(e) == "string"
               and e:find("has more than 60 upvalues", 1, true) ~= nil
        end,
    },
    {
        class = CLASS.WORLD_ROOT_REG,
        why = "宿主在注册期就打上标记认出它是由 `MakeWorld` / "
           .. "`MakeWorldNetwork` 注册的（`Core.WorldRootPrefabs`，见 01_core）。"
           .. "★ 注意实现方式：**不是反射** —— `debug.getinfo(2,\"n\").name` "
           .. "在本运行时**恒为 nil**（试过，失败）。用的是 `Loader.WrapWorldMakers` "
           .. "把两个 maker 包一层、执行期间置标记的**调用嵌套法**。"
           .. "这两条是所有世界根的唯一构造入口；原版世界里它们由世界生成器"
           .. "建一次，不通过 `SpawnPrefab`。`world.lua:418` 的 Lua 层闸门"
           .. "只 print 一句就 `return`，所以**不抛错**，用错误文本判不出来。",
        proof = "prefabs/world.lua:401 `function MakeWorld(...)` / "
             .. "prefabs/world_network.lua:38 `MakeWorldNetwork`；"
             .. "闸门文本 prefabs/world.lua:418；"
             .. "登记实现 host/01_core.lua 的 `Core.WorldRootPrefabs`",
        detect = function(name, ctx)
            -- ★ 延迟 require：本模块会被 reachability.lua 在启动后加载，
            --   这里不依赖文件顶部的 require 顺序（少一个加载期耦合）。
            local ok, C = pcall(require, "host.01_core")
            if not ok or type(C) ~= "table" then return false end
            return C.WorldRootPrefabs ~= nil and C.WorldRootPrefabs[name] ~= nil
        end,
    },
    {
        class = CLASS.WORLD_ROOT,
        why = "引擎**自己**拒绝了这次生成。DST 在 SpawnPrefab 里对世界根预制体"
           .. "有内建闸门，直接打印 `You cannot spawn multiple worlds!` 并返回 nil。"
           .. "⇒ 这是引擎的显式设计，不是宿主缺口（用它的原话当判据最有说服力）。",
        proof = "实测：`SpawnPrefab(\"cave\")` / `(\"forest\")` / `(\"lavaarena\")` "
             .. "都会打印 `You cannot spawn multiple worlds!` 并返回 nil；"
             .. "世界根的构造点在 prefabs/world.lua:401 MakeWorld / "
             .. "prefabs/world_network.lua:38 MakeWorldNetwork",
        detect = function(name, ctx)
            local e = ctx and ctx.err
            return type(e) == "string" and e:find("You cannot spawn multiple worlds", 1, true) ~= nil
        end,
    },
    {
        class = CLASS.WORLD_ROOT_NET,
        why = "世界网络根预制体的工厂第一句就是断言「这个世界还没挂过 net」："
           .. "`assert(TheWorld ~= nil and TheWorld.net == nil)`。"
           .. "抽样逐个 spawn 时，前面已经有别的世界根把 `TheWorld.net` 占掉了 ⇒ "
           .. "断言必然失败。原版世界里这类预制体**只在世界启动时挂一次**。",
        proof = "崩点文本匹配 `_network.lua:NN: assertion failed`；"
             .. "实例：prefabs/quagmire_network.lua:41 / lavaarena_network.lua:41 / "
             .. "world_network.lua:42；源头 prefabs/world_network.lua:38 MakeWorldNetwork",
        detect = function(name, ctx)
            local e = ctx and ctx.err
            if type(e) ~= "string" then return false end
            return e:find("_network%.lua:%d+: assertion failed") ~= nil
                or e:find("assertion failed") ~= nil and e:find("_network") ~= nil
        end,
    },
    {
        class = CLASS.EVENT_SERVER,
        why = "工厂走了活动专属数据（lavaarena/quagmire/yotd 的 *_event_server/），"
           .. "本工程脚本副本里没有这些目录。属数据边界。",
        proof = "宿主 G.event_server_data 的降级分支 + Core.EventServerDegraded",
        detect = function(name, ctx)
            return ctx and ctx.event_server_hits and ctx.event_server_hits > 0
        end,
    },
    {
        class = CLASS.CLIENT_RENDER,
        why = "需要渲染层 C++ 管理器（PostProcessor 等）；"
           .. "DST 自身在服务端也不装配（forest.lua:634 "
           .. "`if not TheNet:IsDedicated() then AddComponent(\"colourcube\")`）。",
        proof = "prefabs/forest.lua:634；components/colourcube.lua",
        detect = function(name, ctx)
            local e = ctx and ctx.err
            if type(e) ~= "string" then return false end
            return e:find("EnvelopeManager") ~= nil
                or e:find("PostProcessor") ~= nil
                or e:find("ShadowManager") ~= nil
        end,
    },
    --=========================================================================
    -- ★★★ 2026-10-18 新增：**「这台机器没装原版」**也算一种边界
    --=========================================================================
    --   现场：可达性穷举从「6039 可达 / 42 不可达 / 未定性 0」变成
    --         「6038 / 43 / **未定性 1**」，那 1 条是 `minimap`，崩在
    --         `util.lua:648` 的 `assert(resolved ~= nil, "Could not find an asset matching ...")`。
    --   根因**不是代码**：`prefabs/minimap.lua` 的工厂要
    --         `resolvefilepath("minimap/minimap_data1.xml")` 去 `data/` 里找图集，
    --         而这台机器**没装 DST**（`G.__kleifileexists.dir_ok == false`，
    --         与 `tests.lua` 里那两条 `⊘ 跳过` 是同一个原因）。
    --   ⇒ 换了台机器（旧机器装了原版）就少了一条「可达」，数字跟着变。
    --
    --   ★ 为什么写成**有条件的规则**而不是给 minimap 登记一条 CASES：
    --     如果无条件写死「minimap = 缺资产」，那么在**装了原版**的机器上
    --     它其实**可达** —— 那条登记就成了一句假话，而且从此没人再去看它。
    --     条件成立（资产真的缺）才归类；**资产齐了它就不匹配** ⇒ 重新变回
    --     「未定性」，逼下一个人去查。这就是本表开头那句「查不到时不要给一个
    --     像结论的东西」的用法。
    --   ⚠️ 顺带说明它为什么**不**算「宿主缺口」：宿主并没有假装文件存在
    --     （`03_globals.lua` 里 `kleifileexists` 的诚实边界：目录不存在 ⇒ 一律 false
    --      并计数），而是**如实说找不到**；原版在没有 data/ 的机器上也一样跑不起来。
    {
        class = CLASS.NO_ASSET_DATA,
        why = "工厂要 `resolvefilepath(<某图集>)` 去原版 `data/` 里找资产，"
           .. "而这台机器**没有装 DST**（`__kleifileexists.dir_ok == false`）"
           .. "⇒ 找不到 ⇒ 原版 `util.lua:648` 的 assert 按设计就抛。"
           .. "★ 这是**环境**边界，不是代码边界：同一份代码在装了原版的机器上可达。",
        proof = "util.lua:640-649 `resolvefilepath` 的 assert；"
             .. "host/03_globals.lua 的 `G.__kleifileexists.dir_ok`（探针文件 "
             .. "`data/minimap/minimap_data1.xml`）；prefabs/minimap.lua:44-46",
        detect = function(name, ctx)
            local e = ctx and ctx.err
            if type(e) ~= "string" then return false end
            if e:find("Could not find an asset matching", 1, true) == nil then return false end
            -- ★ 只有当**资产目录确实不存在**时才认这条；装了原版就不匹配。
            local st = rawget(_G, "__kleifileexists")
            return type(st) == "table" and st.dir_ok == false
        end,
    },
}

--=========================================================================
-- 三、查询入口
--=========================================================================


--- @return class, why, proof   （都查不到时 class = Boundaries.UNDETERMINED）
function Boundaries.Explain(name, ctx)
    local case = Boundaries.CASES[name]
    if case ~= nil then
        return case.class, case.why, case.proof
    end
    for _, r in ipairs(Boundaries.RULES) do
        local ok, hit = pcall(r.detect, name, ctx)
        if ok and hit then
            return r.class, r.why, r.proof
        end
    end
    -- ★ 关键：查不到时**不要**给一个像结论的东西。
    --   「未定性」会直接印在抽样报告里，逼着下一次必须去查。
    return Boundaries.UNDETERMINED,
           "没有匹配到任何已登记的边界规则；按本工程的原则，这属于**待查缺口**。",
           "在 host/26_boundaries.lua 登记前，不要把它写进「已知边界」"
end

--- 自检：每条登记必须三要素齐全且 proof 非空
function Boundaries.Audit()
    local problems = {}
    for name, e in pairs(Boundaries.CASES) do
        if type(e.class) ~= "string" or e.class == "" then
            problems[#problems + 1] = name .. ": 缺 class"
        end
        if type(e.why) ~= "string" or #e.why < 10 then
            problems[#problems + 1] = name .. ": why 太短/缺失"
        end
        if type(e.proof) ~= "string" or #e.proof < 8 then
            problems[#problems + 1] = name .. ": proof 太短/缺失"
        end
    end
    for i, r in ipairs(Boundaries.RULES) do
        if type(r.class) ~= "string" or r.class == "" then
            problems[#problems + 1] = "RULES[" .. i .. "]: 缺 class"
        end
        if type(r.detect) ~= "function" then
            problems[#problems + 1] = "RULES[" .. i .. "]: 缺 detect"
        end
    end

    --★★ T39 判据①：每个 class 取值必须来自 CLASS 表（防「随手写个新名字」）
    local known = {}
    for _, v in pairs(Boundaries.CLASS) do known[v] = true end
    local function chk(label, cls)
        if not known[cls] then
            problems[#problems + 1] = label .. ": class「" .. tostring(cls)
                .. "」不在 Boundaries.CLASS 表里（类别名必须单点定义）"
        end
    end
    for nm, e in pairs(Boundaries.CASES) do chk("CASES." .. nm, e.class) end
    for i, r in ipairs(Boundaries.RULES) do chk("RULES[" .. i .. "]", r.class) end

    --★★ T39 判据②：类别**字面量**在本文件里只允许出现 1 次（就是 CLASS 表的定义处）
    --  这是「只定义一处」的直接检验：出现 ≥2 次说明有人又抄了一遍。
    do
        local f = io.open(Boundaries.__FILE or "host/26_boundaries.lua", "r")
        if f ~= nil then
            local src = f:read("*a"); f:close()
            -- ★★ 只数**代码**里的出现次数：注释里的提及不算。
            --   （第一版连注释一起数 ⇒ 我在说明里举了个例子
            --     「如『世界根预制体(非场景实体)』×4」⇒ 被自己判成「抄了第 2 遍」。）
            --   这与「判据必须指向行为、不要指向文本」是同一条原则：
            --   要约束的是**代码重复**，不是**文字重复**。
            local code = {}
            -- ★ 不用 `string.split`（那是宿主/其它文件提供的，不该在这里隐式依赖）；
            --   用 gmatch 手动切行 —— 少一个隐藏前提。
            for ln in src:gmatch("[^\n]*") do
                local t = ln:gsub("%s+$", "")
                local stripped = t:gsub("^%s+", "")
                if stripped:sub(1, 2) ~= "--" then
                    -- 去掉行尾注释（这里够用：本文件的注释里没有 `--` 字面量）
                    code[#code + 1] = t:gsub("%-%-.*$", "")
                end
            end
            local codesrc = table.concat(code, "\n")
            for k, v in pairs(Boundaries.CLASS) do
                if k ~= "UNDETERMINED" then      -- UNDETERMINED 另有单独定义行 + 表里引用
                    local cnt, pos = 0, 1
                    while true do
                        local i = codesrc:find(v, pos, true)
                        if i == nil then break end
                        cnt = cnt + 1; pos = i + 1
                    end
                    if cnt ~= 1 then
                        problems[#problems + 1] = string.format(
                            "CLASS.%s 的字面量出现 %d 次（应为 1）—— 有人又抄了一遍，会漂移",
                            k, cnt)
                    end
                end
            end
        end
    end

    return #problems == 0, problems
end

--- 统计：个案登记条数（供报告引用）
function Boundaries.Count()
    local n = 0
    for _ in pairs(Boundaries.CASES) do n = n + 1 end
    return n, #Boundaries.RULES
end

return Boundaries
