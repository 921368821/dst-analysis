--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：entityscript.lua
-- 模块：核心框架 / 实体运行时（Entity Runtime）
-- 职责：定义 EntityScript —— 全游戏每个实体（生物 / 物品 / 玩家 / 光球）的
--       Lua 侧基类。承担组件装配、事件总线、limbo 虚体管理、更新调度注册、
--       存档序列化、StateGraph / Brain 挂载、子实体与平台跟随、标签查询、
--       距离与朝向计算、缓冲动作路由等职责。
--       它是「C++ 引擎实体 Entity」与「Lua 业务逻辑」之间的桥接层：
--       self 是 Lua 侧对象，self.entity 是 C++ 侧实体，二者一一对应。
-- 关键符号：EntityScript, GetSaveRecord, SetPersistData, RemoveFromScene,
--           ReturnToScene, IsInLimbo, ForceOutOfLimbo, StartUpdatingComponent,
--           StopUpdatingComponent, StopUpdatingComponent_Deferred,
--           StartWallUpdatingComponent, AddComponent, RemoveComponent,
--           AddTag, HasTag, HasTags, HasOneOfTags, ListenForEvent, PushEvent,
--           RemoveEventCallback, RemoveAllEventCallbacks, WatchWorldState,
--           AddChild, RemoveChild, AddPlatformFollower, SetBrain, SetStateGraph,
--           PushBufferedAction, PerformBufferedAction, PreviewBufferedAction,
--           DoPeriodicTask, DoTaskInTime, PushEventInTime, Remove
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：class.lua（类系统）, scheduler.lua（任务调度）,
--           entityreplica.lua（副本组件）, componentactions.lua（组件动作表）,
--           stategraph.lua（状态图）, brain.lua（大脑）,
--           entityscriptproxy.lua（跨端代理）, update.lua（主循环驱动）
--============================================================
--【唯一的全局依赖】整个游戏只有类系统是前置依赖。EntityScript 后续所有能力
--   （组件、状态图、大脑）都建立在 Class() 提供的元表继承之上。
-- 参见 class.lua:150 的 Class() 实现。
--★★ 参见 class.lua 是本文件唯一的硬依赖，见 class.lua:150。
require("class")
--【空行分隔模块级声明与函数定义】

--【★ 模块级缓存表】三张表在文件加载时创建，此后永不重置。
--   这是「require 一次、全局复用」的热路径优化：游戏里每帧可能创建上百个实体，
--   若每次都 require("components/xxx") 会产生可观的字符串拼接与哈希开销。
--   StateGraphs  —— 状态图函数缓存
--   Components   —— 组件类缓存，并被就地「猴补」注入 WatchWorldState 方法
--   EventServerFiles —— 事件服务器文件缓存（按 事件名 + 路径 双层维度）
local StateGraphs = {}
--【★ Components 表的双重身份】它既是「组件类的缓存」，
--   也是「猴补注入的载体」—— 注入只发生在首次加载时。
--   ★ 这带来一个重要后果：若某组件在猴补**之前**已被加载
--     （例如通过其他路径直接 require 了同一文件），
--     它将**缺少** WatchWorldState 方法。
--     实际不会发生，因为 LoadComponent 是唯一的加载入口。
local Components = {}
--【EventServerFiles：按「事件名/路径」双层命名空间缓存】
--   ★ 缓存的意义：事件分发时避免重复 require 同一文件。
--   ⚠ 代价：这些文件一旦加载就常驻内存，无法卸载。
--     对模组热重载不友好 —— 改完模组需重启游戏。
local EventServerFiles = {}
--【空行】

--【★★ 全局「待停组件」队列 —— 本文件最精妙也最容易被误改的设计】
--   它是全局变量（没有 local），主循环 update.lua 能直接看到。
--   结构：{ [组件实例] = 拥有它的EntityScript }
--   语义：某个组件「本帧要停止更新」，但**不能立刻**从self.updatecomponents 里删掉。
--   原因见 StopUpdatingComponent 的详细说明（遍历中删表的未定义行为）。
--   ★ 注意：它同时被普通更新循环（update.lua:277）与静态更新循环（update.lua:203）消费，
--     所以实体在暂停界面里停止更新也是安全的。
StopUpdatingComponents = {}
--【空行】

--【客户端图像标志表】哪些 flag 允许「客户端侧换图」。
--   ★ 与前四张表不同，这张表**故意做成进程级全局共享**（虽然声明为 local）：
--     它描述的是客户端的全局渲染策略，而非某个实体的状态。
--   若做成 per-entity，客户端就没有统一的地方查询「当前是否允许换图」。
local ClientSideInventoryImageFlags = {}
--【世界状态观察者工具函数区】

--【★ 世界状态观察者登记 —— 实体侧】
--   结构：self.worldstatewatching[变量名] = { 回调1, 回调2, ... }
--   为什么用「数组 + 线性查找」而不是哈希？
--     因为单个变量上的观察者通常只有1~3 个（季节、天气、月相这类全局量），
--     线性查找在这个规模下比哈希表更快，且内存布局连续。
--   ★ 注意这个 local 函数同时被 EntityScript:WatchWorldState 与组件版包装共用，
--     保证实体与组件登记到的是同一张表，便于统一清理。
local function EntityWatchWorldState(self, var, fn)
    self.worldstatewatching = self.worldstatewatching or {}
--【懒建 per-var 数组】

--【懒初始化】只有真的有人观察该变量时才建数组，避免每个实体都开一堆空表。
    local watcherfns = self.worldstatewatching[var]
    if watcherfns == nil then
        watcherfns = {}
        self.worldstatewatching[var] = watcherfns
    end

--【★ 允许重复登记】这里用 table.insert 而不做去重，
--   意味着同一个 fn 登记两次会被调用两次。
--   这是刻意的：EntityWatchWorldState / ComponentWatchWorldState 各自登记自己那份，
--   在某些「实体与组件都监听同一变量」的场合下，语义是「两次都要响应」。
--   取消时用 RemoveByValue 按值删除（只删一个），保持了登记/取消的严格配对。
    table.insert(watcherfns, fn)
--【EntityWatchWorldState 结束】
end

--【★ 反向操作：移除观察者】除了功能，还承担「内存收缩」职责。
--   Lua 里空表仍占内存且会被 GC 遍历，所以这里做了两级收缩：
--     ① 该变量下的观察者全空 → 删掉这个变量的条目
--     ② 整个 worldstatewatching 全空 → 把 self.worldstatewatching 置 nil
--   ★ 这是典型的「惰性释放」模式：只有用完才还，代价是几行 next() 判断，
--     收益是实体销毁时不必逐项清理。
local function EntityStopWatchingWorldState(self, var, fn)
--【早退保护】从未观察过任何变量时直接返回，这是最热的路径（大量实体无监听）。
    if self.worldstatewatching == nil then
        return
    end

    local watcherfns = self.worldstatewatching[var]
    if watcherfns ~= nil then
--【★ 按值删除】Lua 数组无法 O(1) 删除中间元素，RemoveByValue 是线性扫描 + table.remove。
--   再次印证「观察者数量必须很少」是这套设计成立的前提。
        RemoveByValue(watcherfns, fn)

        if next(watcherfns) == nil then
            self.worldstatewatching[var] = nil
        end
    end

--【第二级收缩】整张表空了就置 nil，让实体对象能真正变轻。
    if next(self.worldstatewatching) == nil then
        self.worldstatewatching = nil
    end
end
--【组件版包装函数区】

--【★ 组件版世界状态观察 —— 双写设计】
--   组件自己没有 worldstatewatching 表（否则每个组件都要开一张），
--   而是**代理到宿主实体** self.inst 上，再额外在 worldstate 组件里登记一份。
--   为什么写两处？
--     self.inst 的那份  → 给脚本用的「快速自查」：本实体到底监听了什么，
--                          StopAllWatchingWorldStates 可以不查全局表就批量注销。
--     worldstate 的那份 → 给世界用的「分发索引」：世界只认自己表里的观察者，
--                          否则每次变量变化都要全表扫描找订阅者。
--   ★ 代价是两处状态可能不一致；RemoveByValue 保证它们成对增删。
local function ComponentWatchWorldState(self, var, fn)
    EntityWatchWorldState(self.inst, var, fn)
    TheWorld.components.worldstate:AddWatcher(var, self.inst, fn, self)
end
--【空行】

--【对称的注销】必须两处都清，否则会留下悬垂回调（实体已 GC 但回调仍指向它 → 崩溃）。
local function ComponentStopWatchingWorldState(self, var, fn)
    EntityStopWatchingWorldState(self.inst, var, fn)
    TheWorld.components.worldstate:RemoveWatcher(var, self.inst, fn, self)
end
--【组件 / 状态图 加载器区】

--【★ 组件类加载器（懒加载 + 就地猴补）】
--   步骤：① 查缓存 ② require 对应路径 ③ 断言非 nil（把静默失败变成显式崩溃）
--        ④ **在组件类表上直接挂两个新方法**
--   第④步是本行的精髓：Components[name] 就是 require 返回的类表，
--   直接给它加字段，所有该类的实例就都自动获得 WatchWorldState/StopWatchingWorldState。
--   ★ 为什么用猴补而不是继承？因为组件类之间没有统一的基类（各组件互相独立），
--     猴补是唯一能做到「全体组件都拥有该能力」的低成本手段。
--     副作用：这段注入是**全局一次性**的，因Components[name] 已被缓存，
--     同一组件的第二次加载不会重复注入。
local function LoadComponent(name)
    if Components[name] == nil then
        Components[name] = require("components/"..name)
--【显式失败优于静默失败】require 失败返回 nil，assert 会打印组件名并中止加载。
--   若没有这行，错误会推迟到「AddComponent 返回 nil」时才以更难懂的方式爆发。
        assert(Components[name], "could not load component "..name)
        Components[name].WatchWorldState = ComponentWatchWorldState
        Components[name].StopWatchingWorldState = ComponentStopWatchingWorldState
    end
    return Components[name]
end
--【空行】

--【★ 状态图加载器】与 LoadComponent 的差异：
--   ① 不猴补——状态图没有 worldstate 需求
--   ② 返回的是**函数**（状态图是 { name=..., states=..., defaultstate=... } 的工厂函数），
--      实际实例由 StateGraphInstance(sg, self) 在 SetStateGraph 中创建。
--   两次 assert 是冗余的（第65 行已经断言过），但无害。
local function LoadStateGraph(name)
    if StateGraphs[name] == nil then
        local fn = require("stategraphs/"..name)
        assert(fn, "could not load stategraph "..name)
        StateGraphs[name] = fn
    end

    local sg = StateGraphs[name]

    assert(sg, "stategraph "..name.." is not valid")
    return sg
end
--【空行】

--────────────────────────────────────────────────────────────
-- 【事件服务器文件】区段分隔线
-------------------------------------------
--【★ 事件服务器 = 「谁在监听这个事件」的权威索引】
--Loading event server files
--【★ 事件分发的一环】event_server_data(eventname, path) 返回某个事件在某文件里的监听表。
--   path 通常是 "components/xxx" 或实体脚本路径。
--   游戏里每个事件（如 "onpickup"）都会把所有监听它的脚本文件路径列出来；
--   事件触发时，引擎据此只加载/执行相关的文件，而不是遍历全游戏脚本。
--   ★ 这就是为什么文件顶部有 stategraphs/brains 那样的大目录 —— 它们被当作数据索引。
function event_server_data(eventname, path)
--【双层命名空间】事件名 + 路径 拼成唯一键，保证同名事件在不同文件里的监听互不干扰。
    local fullpath = eventname.."_event_server/"..path
    if EventServerFiles[fullpath] == nil then
--【requireeventfile是引擎提供的特殊 require】它只解析「事件服务器目录」下的文件，
--   不会污染普通的 require 缓存。
        EventServerFiles[fullpath] = requireeventfile(fullpath)
--【★ 条件猴补】只有组件目录下的事件文件才注入 worldstate 观察方法。
--   因为 EntityWatchWorldState 需要 TheWorld.components.worldstate 这个宿主，
--   而非组件上下文的脚本拿不到 inst。
        if path.sub(1, 11) == "components/" then
            EventServerFiles[fullpath].WatchWorldState = ComponentWatchWorldState
            EventServerFiles[fullpath].StopWatchingWorldState = ComponentStopWatchingWorldState
        end
    end
    return EventServerFiles[fullpath]
--【event_server_data 结束】
end
--【空行】

--────────────────────────────────────────────────────────────
-- 【覆盖 AddNetwork】区段分隔线
-- 这一整段都在做一件事：让 C++ 侧的 Entity:AddNetwork() 多同步一批「动作」数据。
-------------------------------------------
--Override adding network component
--【空行】

--【★ 网络脏标记的客户端回调解码器】
--   actioncomponents 是一张「组件名 → 布尔」表，表示这个实体当前支持哪些动作组件。
--   net_bytearray 只传索引，服务端与客户端的表顺序不一致，所以要用 dirty 事件重取。
--   ★ 关键理解：replica 数据**不是每帧同步**的，而是「值变了才推一次 + 客户端收 dirty 回调解码」。
--   这个模式贯穿全游戏的所有 replica 组件（health、hunger、container...）。
local function OnActionComponentsDirty(inst)
    inst.actioncomponents = inst.actionreplica.actioncomponents:value()
end
--【空行】

--【★ 模组动作组件的动态键】
--   为什么模组要单独一张表？因为 modactioncomponents 的键是「模组名」，
--   数量不可预知，不能像基础组件那样用固定下标。
--   代价：每加一个模组，实体就多一个 net_smallbytearray，
--        这也是 SetClientSideInventoryImageFlags 之类机制存在的意义（控制规模）。
local function OnModActionComponentsDirty(inst, modname)
    inst.modactioncomponents = inst.modactioncomponents or {}
    inst.modactioncomponents[modname] = inst.actionreplica.modactioncomponents[modname]:value()
end
--【空行】

--【★ 固有能力（inherentactions）序列化】
--   「固有能力」= 实体天生就拥有的动作（如火把自带「点火」），
--   与「需要手持工具才有的动作」相对。
--   ★ 存储格式是「ACTIONS 数组的**下标列表**」而不是动作名，
--     因为下标是 1 字节，而动作名字符串很长。这是典型的空间优化。
--   ⚠ 但下标序列化依赖 pairs(ACTIONS) 的遍历顺序在服务端与客户端一致 ——
--     若某模组在两端加载顺序不同，动作就会错位。详见 DeserializeInherentActions。
local function SerializeInherentActions(inst)
    if inst.actionreplica == nil then
        return
    end

--【onent 表的懒初始化】
    local t = {}
    if inst.inherentactions ~= nil then
--【★ 遍历 pairs(ACTIONS) 累加 id】这依赖 Lua 表遍历顺序。
--   在 Lua 5.1 中，同一未修改的表在两次遍历中顺序是稳定的（同为哈希布局），
--   服务端与客户端只要加载了同一批模组，ACTIONS 内容相同，顺序就相同。
--   ⚠ 疑似缺陷：若客户端比服务端**晚**加载某个模组，ACTIONS 表内容不同，
--     顺序极可能不一致 → 固有能力全部错位。正确做法是传动作名字符串。
        local id = 1
        for k, v in pairs(ACTIONS) do
            if inst.inherentactions[v] then
                table.insert(t, id)
            end
            id = id + 1
        end
    end
    inst.actionreplica.inherentactions:set(t)
end
--【空行】

--【★ 反序列化：两遍扫描的巧思】
--   第一遍（121-123 行）：把收到的 id 列表展开成 { [id]=true }。
--   第二遍（128-135 行）：把键从 id 换成真正的动作对象。
--   ★ 为什么分两遍？因为第一遍的键已经是 id，第二遍要按同样的 pairs 顺序映射回来。
--   为什么先判空再进第二遍？空表没必要遍历 ACTIONS —— 纯性能优化。
local function DeserializeInherentActions(inst)
    inst.inherentactions = {}
    for _, v in ipairs(inst.actionreplica.inherentactions:value()) do
        inst.inherentactions[v] = true
    end

    if next(inst.inherentactions) == nil then
        inst.inherentactions = nil
    else
        local id = 1
--【★ 原地重映射的妙处与隐患】
--   inst.inherentactions[id] = nil → inst.inherentactions[action] = true
--   这样表里只有「真动作」作为键。
--   ⚠ 疑似缺陷：边遍历 pairs(ACTIONS) 边修改 inst.inherentactions ——
--     修改的是**另一个表**，所以遍历本身安全；但如果某个 action 对象恰好等于某个整数 id，
--     或者 id 超出 ACTIONS 长度，这些脏键会永远留在表里，导致 CanDoAction 误判。
        for _, v in pairs(ACTIONS) do
            if inst.inherentactions[id] then
                inst.inherentactions[id] = nil
                inst.inherentactions[v] = true
            end
            id = id + 1
        end
    end
end
--【空行】

--【单动作序列化】同inherentactions 的下标方案。0 表示「无固有能力」。
--   ★ 找不到时返回 0 而不是 nil：net_byte 只能传数字。
local function SerializeAction(action)
    if action ~= nil then
        local id = 1
        for _, v in pairs(ACTIONS) do
            if action == v then
                return id
            end
            id = id + 1
        end
    end
    return 0
end
--【空行】

--【反序列化】id > 0 才查表。找不到时隐式返回 nil，调用方需判空。
local function DeserializeAction(actionid)
    if actionid > 0 then
        local id = 1
        for k, v in pairs(ACTIONS) do
            if actionid == id then
                return v
            end
            id = id + 1
        end
    end
end
--【空行】

--【★ 场景交互固有能力（鼠标左键 / 右键）】
--   inherentsceneaction   —— 对场景使用（如「打开箱子」的主交互）
--   inherentscenealtaction —— 对场景使用的备选（如「长按打开」）
--   这两个是玩家鼠标右键最常触发的动作，必须网络同步给客户端才能正确画高亮。
local function OnInherentSceneActionDirty(inst)
    inst.inherentsceneaction = DeserializeAction(inst.actionreplica.inherentsceneaction:value())
end
--【空行】

local function OnInherentSceneAltActionDirty(inst)
    inst.inherentscenealtaction = DeserializeAction(inst.actionreplica.inherentscenealtaction:value())
end
--【空行：猴子补丁前的过渡】

--【★ 保存原函数再包装（猴子补丁）】
--   Klei 需要在 C++ 的 AddNetwork 之外追加自己的同步数据，但 C++ 代码不可改。
--   于是：先取出原函数 → 重定义同名全局函数 → 先调原函数再补逻辑。
--   ★ 这是 Lua 里扩展封闭模块的标准手法，全游戏大量使用（见 stategraph.lua、brain.lua）。
--   ⚠ 注意 AddNetworkProxy 保存的是**未加冒号**的函数，所以调用时传 self。
local AddNetworkProxy = Entity.AddNetwork
--【空行】

--【★ Entity:AddNetwork 的完整扩展】执行时机：由引擎在实体「变为联网实体」时调用一次。
--   步骤：① 先跑 C++ 原版逻辑建立基础连接
--        ② 用 GUID 去 Ents 表反查 Lua 侧实例
--        ③ 挂上 4 个动作相关网络变量 + 每个模组 1 个
--        ④ 客户端侧监听 dirty 事件做解码。
--   ★ 第②步的 Ents[guid] 说明：GUID 是连接 Lua 与 C++ 的唯一桥梁。
function Entity:AddNetwork()
    AddNetworkProxy(self)

    local guid = self:GetGUID()
    local inst = Ents[guid]
    inst.actionreplica =
--【actionreplica 表的字段区】
    {
--【★ 四类同步载荷一览】
--   actioncomponents       bytearray —— 组件→动作映射表（变长）
--   inherentactions        bytearray —— 固有能力 id 列表（变长）
--   inherentsceneaction     byte     —— 主场景交互动作 id（定长1字节）
--   inherentscenealtaction  byte     —— 备选场景交互动作 id
--   ★ 三次参数分别是：GUID、变量名、同步变化时的回调事件名。
--     第三个参数命名成 "xxxdirty" 是全局约定，见下方 ListenForEvent 的监听。
        actioncomponents = net_bytearray(guid, "actioncomponents", "actioncomponentsdirty"),
        inherentactions = net_bytearray(guid, "inherentactions", "inherentactionsdirty"),
        inherentsceneaction = net_byte(guid, "inherentsceneaction", "inherentsceneactiondirty"),
        inherentscenealtaction = net_byte(guid, "inherentscenealtaction", "inherentscenealtactiondirty"),

        modactioncomponents = {}
    }

--【★ 服务端模组列表决定客户端要监听哪些变量】
--   ⚠ 潜在时序问题：若客户端在本实体 AddNetwork 之后才加载完模组，
--     ModManager:GetServerModsNames() 的结果会与服务端不一致。
--     实践中 DST 要求两端模组版本严格一致，这个约束由前端菜单保证。
    for _,modname in pairs(ModManager:GetServerModsNames()) do
        inst.actionreplica.modactioncomponents[modname] = net_smallbytearray(guid, "modactioncomponents"..modname, "modactioncomponentsdirty"..modname)
    end


--【★ 只在客户端挂 dirty 监听】服务端是数据源，不需要「解码」自己的数据。
--   若两端都监听，服务端会多做一次无用的反序列化，且可能与本地状态打架。
    if not TheWorld.ismastersim then
        inst:ListenForEvent("actioncomponentsdirty", OnActionComponentsDirty)
        inst:ListenForEvent("inherentactionsdirty", DeserializeInherentActions)
        inst:ListenForEvent("inherentsceneactiondirty", OnInherentSceneActionDirty)
        inst:ListenForEvent("inherentscenealtactiondirty", OnInherentSceneAltActionDirty)

--【★ 闭包捕获循环变量的经典 Lua 陷阱 —— 这里安全的原因】
--   Lua 5.1 中 for循环变量是**每次迭代新建的局部变量**，
--   所以每个闭包捕获的都是自己那一份 modname，而不是循环结束后的最终值。
--   （Lua 5.0 才有这个 bug；本项目固定用 5.1，故安全。）
--   ★ 但要注意：这些闭包会一直活在事件的回调表里，直到实体销毁时才释放。
        for _, modname in pairs(ModManager:GetServerModsNames()) do
            inst:ListenForEvent("modactioncomponentsdirty"..modname, function(inst)
                OnModActionComponentsDirty(inst, modname)
            end)
        end
    end
end
--【空行：Entity:AddNetwork 结束】

--【★★ replica 容器的元表 —— 全游戏副本机制的核心技巧】
--   self.replica 是一个普通表 {_ = {}, inst = self}，它的「读未命中」被接管。
--   __index = function(t, k)
--       return rawget(t, "inst"):ValidateReplicaComponent(k, rawget(t, "_")[k])
--   end
--
--   ★★ 语义拆解：
--     rawget(t,"_")[k]—— 真实存储：副本组件实例（或 nil）
--     ValidateReplicaComponent(k, cmp) —— 见 entityreplica.lua:30
--         return self:HasTag("_"..name) and cmp or nil
--     即：**只有实体确实带 _<name> 标签时才返回副本，否则返回 nil**。
--   ★ 这就是「零成本可选组件」的答案：
--     脚本可以无条件写 self.replica.inventory:GetActiveItem()，
--     若该实体没有 inventory 副本，返回 nil，调用方判空即可；
--     而不需要每次都先 HasTag("_inventory") 再取。
--   ★★ 并且它同时实现了「客户端只读」：副本端根本不写这些字段。
--★★ 参见 entityreplica.lua:30 ValidateReplicaComponent
--   —— 它的 return self:HasTag('_'..name) and cmp or nil 正是本 __index 的核心。
--   entityreplica.lua:34 ReplicateComponent 是唯一填充 _ 表的入口。
local replica_mt =
{
	__index = function(t, k)
--【★ 每次访问都做一次 HasTag 校验】HasTag 是 C++ 侧调用，有一定开销。
--   这是「易用性换性能」的一处刻意取舍：副本访问频率远低于原生组件访问，
--   且避免了脚本里到处散落标签判断，显著降低 mod 写错代码的概率。
--   ⚠ 性能提示：高频循环里应缓存 local r = self.replica.inventory，而不是反复索引。
		return rawget(t, "inst"):ValidateReplicaComponent(k, rawget(t, "_")[k])
	end,
}
--【空行】

--★★ ★ ★ EntityScript —— 全游戏每个实体的 Lua 基类 ★ ★ ★
--【桥接层定位】
--   C++ 引擎创建 Entity 后，Lua 侧创建一个 EntityScript 实例与它一一对应。
--     self       = Lua 实体（业务逻辑写这里）
--     self.entity= C++ 实体（Transform/Physics/AnimState/网络/引擎回调在这里）
--   prefab 脚本继承本类后得到几百个免费能力（组件、事件、存档、AI 挂载...）。
--
--【构造顺序的设计意图】
--   ① 先 self.entity/entity 的引用，再 GUID —— 后面所有代码都依赖它
--   ② ★ 把几乎所有可选子表都显式初始化为 nil ——
--      在 Lua 中显式写 nil 是为了让字段「存在」，
--      这样后面到处使用的 if not self.xxx then self.xxx = {} end 走的是同一路径，
--      且调试时 dump 出的实体结构是完整的、可预测的。
--   ③ 默认值体现「安全默认」：persists=true（默认入存档）、inlimbo=false（在场景中）。
--★★ 参见 class.lua:150 Class() —— 本实体类的构造入口；
--   class.lua:257 / class.lua:276 是实例创建的 __call 实现。
EntityScript = Class(function(self, entity)
--【entity = C++ 实体引用】Lua 与 C++ 的连接点。
--   ★ 所有物理、变换、渲染、网络操作都要经过它转发。
    self.entity = entity
--【components：组件表】键是组件名（小写），值是组件实例。
--   ★ 注意是「名字 → 实例」，不是「数组」——这是为了让脚本能用名字直接取：
--     inst.components.health:IsAlive()
--   遍历顺序无保证（Lua hash 表），所以依赖顺序的逻辑必须显式排序。
    self.components = {}
--【★ lower_components_shadow：大小写不敏感的存在性影子表】
--   问题：Lua 表键是大小写敏感的，但脚本里有人写 AddComponent("health")、
--         有人写 AddComponent("Health")，若不管就会装出两个组件互相打架。
--   方案：用全小写的键做一张 {名字 → true} 的影子表，AddComponent 先查它。
--   ★ 只存 true 不存实例，因为它只回答「有没有」；真正取值仍走 self.components。
--   ⚠ 该表不做自动同步：若外部直接往 self.components 里塞组件，影子表不会知道。
    self.lower_components_shadow = {}
--【★ GUID：C++ 分配的全局唯一实体编号】
--   它是实体在 Lua 侧的一等身份：
--     · 协程归属（StartThread(fn, self.GUID) → KillThreadsWithID 可批量杀）
--     · 更新表索引（UpdatingEnts[self.GUID]）
--     · 网络变量命名空间（net_byte(guid, ...)）
--     · Ents[guid] 反查
--   ★ 注意它是**数字**，所以 __tostring 里用 %d 打印。
--【★ GUID 的四重用途小结（详见各处引用）】
--   ① 协程归属：StartThread(fn, self.GUID) → KillThreadsWithID 可批量清
--   ② 更新表索引：UpdatingEnts[self.GUID] / StaticUpdatingEnts[...]
--   ③ 网络命名空间：net_byte(guid, "变量名", "dirty事件名")
--   ④ 反查入口：Ents[guid] 拿回 Lua 实例
--   ★ 四者共用同一个数值，使实体成为全局系统中的一等公民。
    self.GUID = entity:GetGUID()
--【spawntime】实体创建时刻。GetTimeAlive = GetTime() - spawntime。
--   ★ 只在主模拟（服务端）有意义；客户端实体的 spawntime 是本地创建时刻。
    self.spawntime = GetTime()
--【★ sleepstatepending —— 一个防御性的时序补丁】
--   注释原文：「haven't received initial sleep state from engine yet」
--   问题背景：C++ 引擎会在实体创建后异步告知「我是醒着还是睡着」，
--     在这条消息到达之前，entity:IsAwake() 的返回值不可信。
--   若此时 SetBrain() 看到 IsAsleep()==false 就直接启动大脑，
--     一个本该沉睡的实体（比如被 chunk 未加载而睡着的实体）会错误地跑AI。
--   所以在收到初始状态前，一律按「要禁用」处理。见 SetBrain 中的使用（1106 行）。
	self.sleepstatepending = true --haven't received initial sleep state from engine yet
--【persists：是否写入存档】默认 true。
--   EntityScript:Remove() 末尾会置false —— ★ 因为实体正在被销毁，
--   如果此刻恰好触发一次存档，它就不该被写进去。
    self.persists = true
--【inlimbo：是否处于虚体状态】
--   ★ 与「睡眠（sleep）」是两个正交概念，详见 RemoveFromScene 的说明。
    self.inlimbo = false
--【name 初始为 nil】
    self.name = nil
--【data 槽：GetPersistData 的产物存放处】

--【以下是一批「可选子表」的统一显式置 nil】
--   data                  —— GetPersistData 的产物槽
--   listeners             —— 旧版事件监听残留字段
--   updatecomponents      —— 每帧更新的组件集合
--   updatestaticcomponents—— 暂停时仍更新的组件集合
--   event_listeners       —— 「我在监听谁」（事件名 → 源实体 → 回调数组）
--   event_listening       —— 「谁在监听我」（反向索引，用于断连时反查）
--   worldstatewatching    —— 世界状态观察者
--   pendingtasks          —— 未完成的定时/周期任务
--   children              —— 父子从属实体
--   platformfollowers     —— 跟随本实体平台的实体
--   ★ 全部置 nil 而非 {} 是为了省内存：
--     Lua 空表也占内存（表头约56 字节），而实体可能有上万个。
--     这些表只在真正用到时才创建。
    self.data = nil
--【listeners：旧版事件机制的残留字段】
    self.listeners = nil
    self.updatecomponents = nil
    self.updatestaticcomponents = nil
--【actioncomponents：客户端解码后的组件→动作表】
    self.actioncomponents = {}
--【inherentactions 的三种可能状态】
    self.inherentactions = nil
--【inherentsceneaction 的三种可能状态】
    self.inherentsceneaction = nil
--【inherentscenealtaction 的三种可能状态】
    self.inherentscenealtaction = nil
    self.event_listeners = nil
    self.event_listening = nil
    self.worldstatewatching = nil
    self.pendingtasks = nil
    self.children = nil
    self.platformfollowers = nil
--【platformfollowers 的懒创建前提：初值 nil】

--【actionreplica 初始为 nil】由 Entity:AddNetwork() 在第 179 行注入。
--   所以它是「可能不存在」的：非联网实体没有这张表。
    self.actionreplica = nil

    --Replica components container with overriden accessor
	--Replica components container with overriden accessor
--【★★ 副本容器的物理结构】
--   { _ = {}, inst = self }
--     _   —— 真实存放副本组件实例的表。**必须用 rawget/rawset 访问**，
--           否则会触发 __index 钩子造成无限递归。
--     inst —— 宿主实体，供 ValidateReplicaComponent 做标签检查。
--   ★ 注意 _ 会被 entityscriptproxy.lua:88 二次包一层代理，
--     使客户端/服务端代码拿到的 inst 一致。参见 entityscriptproxy.lua:62。
--★★ 参见 entityscriptproxy.lua:88 把 replica._ 再次包一层代理；
--   entityscriptproxy.lua:62 components_proxy_mt 描述其查找规则。
	self.replica = { _ = {}, inst = self }
--【挂上元表】这一步之后，self.replica.health 就变成「自动校验的副本访问」。
	setmetatable(self.replica, replica_mt)
--【构造完成：★ 此时实体还没有任何组件】
end)
--★ 构造完成后的实体具备的最小能力：
--   GUID / spawntime / 组件表 / 副本容器 / limbo 标志 / persists 标志
--   ★ 一切行为都要靠后续 AddComponent / SetStateGraph / SetBrain 装配出来。

--★★ ★ ★ 存档序列化 —— 全游戏存档格式的定义处 ★ ★ ★
--【调用时机】由 C++ 引擎在存档时回调（每个要持久化的实体调一次）。
--   调用方在 mainfunctions.lua 的 SaveToFile 路径。
--【返回值约定】返回 record（本体数据表）, references（需要全局唯一化的引用表）。
--   ★ references 是存档的「第二遍」机制：某些数据（如 GUID）必须先收集，
--     因为被引用的实体可能还没被保存。见 1934 行的判空返回。
--【★ 精度取舍 —— 本函数最重要的设计决策】
--   所有坐标都存成「毫米级定点数」：math.floor(x * 1000 + 0.5) * 0.001
--     · 乘 1000  → 保留 3 位小数（毫米精度）
--     · +0.5     → 实现四舍五入（而不是截断），保证误差对称不累积
--     · *0.001   → 还原为浮点
--   为什么不用更精确？因为存档是明文的，位数越少文件越小。
--   为什么不用更粗略？0.001 的误差在游戏里察觉不到（1 单位 = 1 像素）。
function EntityScript:GetSaveRecord()
--【record 本体表：prefab 是唯一必填字段】
	local record =
	{
		prefab = self.prefab,
	}
--【空行】

--【先取世界坐标】后续所有分支（平台相对化 / 校验 / 写record）都基于它。
	local x, y, z = self.Transform:GetWorldPosition()
--【空行】

--【★ 两条进入「平台相对坐标」分支的条件】
--   ① self.temp_save_platform_pos —— 该实体要求存档时相对平台存储
--   ② HasTag("player")          —— 玩家永远用相对坐标
--   为什么？平台（船、_components 移动平台）会移动，
--     若玩家存了世界坐标，重新加载时船可能不在原处 → 玩家掉进虚空。
--   相对坐标让玩家「焊」在船的局部空间里，船走到哪玩家跟到哪。
--   ★ 同时这里还顺便存了 record.age = 网络层记录的存活时长，
--     用于重连后恢复玩家饥饿度等随时间增长的数值。
	if self.temp_save_platform_pos or self.entity:HasTag("player") then
--【★ age：从网络层取玩家存活时长】
		record.age = self.Network:GetPlayerAge()
--【★ 相对存档 + 「只有 y 非零才存」的组合效果】
--   玩家站在船上：record = { puid=<船的UID>, rx=..., rz=..., age=... }
--   ★ 注意此时**不写** record.x/z/y —— 因为那是船的局部坐标，
--     只有在「没有找到平台」时才回退到世界坐标（256 行的条件不成立时）。
--   ★ 读档流程：先用 puid 找到船 → WorldToSpace(rx,ry,rz) 还原世界坐标。

--【★ 取当前所属平台（会递归向上）】
        local platform = self:GetCurrentPlatform()
--【★ _snapshot_platform —— 一个带V2C 标记的临时补丁】
--   场景：RestoreSnapshotUserSession（从快照恢复会话）时，
--         玩家的平台归属还没被正确重建。
--   做法：上一帧存档时记住平台，如果这次取不到平台但发现实体其实站在
--         同一个平台上（GetPlatformAtPoint 命中同一对象），就沿用旧平台。
--   注释里自称 "quick hack to fix that for now" —— ★ 即承认这是临时方案。
--   ⚠ 疑似缺陷：它用「平台对象相等」而非 UID 比较，
--     若两帧之间平台被销毁重建（对象不同但 UID 相同），hack 会失效并退化为世界坐标。
		if self._snapshot_platform ~= nil then
--【★ hack 的触发条件：本次取不到平台】
			if platform == nil and self._snapshot_platform == TheWorld.Map:GetPlatformAtPoint(x, z) then
--★V2C 注释明确说了这是 "quick hack"，值得原样保留。
--   ★ 这类注释在大型商业代码里很常见：它记录了「我们知道这是临时的」。
				--V2C: During RestoreSnapshotUserSession, players aren't attached to platforms correctly.
--【空行】
				--     This is quick hack to fix that for now.
				platform = self._snapshot_platform
--【恢复后立即清空快照标记】
			end
--【一次性使用，用完即弃】
			self._snapshot_platform = nil
--【平台赋值结束】
		end
--【WorldToLocalSpace】把世界坐标转成平台的局部坐标。
--   ★ 这是整个存档相对坐标机制的地基：存的是「我相对船的位置」。
        if platform then
--【★ 局部空间转换的入口】
			local rx, ry, rz = platform.entity:WorldToLocalSpace(x, y, z)
--【空行】

            -- NaN and +/-inf hunting
            -- NaN and +/-inf hunting
--【★★ NaN / ±Inf 防御 —— 存档系统最脏的问题在这里被解决】
--   背景：一旦某个实体坐标变成 NaN 或无穷大，它会被写进存档；
--        下次读档时，这个 NaN 会通过「相对坐标 → 世界坐标」的链式计算
--        **污染整张地图上所有引用它的东西**，最终世界无法加载。
--        这是 DST 历史上真实发生过的灾难级Bug。
--   isbadnumber 同时检测 NaN 与 ±Inf。
			if isbadnumber(rx) or isbadnumber(ry) or isbadnumber(rz) then
--【★ 生产环境不崩，开发环境崩】
--   print 始终执行 —— 线上留证据以便事后分析。
--   error 只在非 PRODUCTION 时抛 —— ★ 让 QA/开发立刻看到问题，
--     而不是让玩家带着坏档继续玩。
--   ★ 这是「快速失败 + 优雅降级」并存的典范：诊断信息不丢，游戏不中断。
				print("EntityScript:GetSaveRecord error saving position: ", self.prefab, rx, ry, rz, ":", x, y, z, ":", platform)
--【配置常量】CONFIGURATION 在开发版为 "DEVELOPMENT"，正式包为 "PRODUCTION"。
				if CONFIGURATION ~= "PRODUCTION" then
					error("EntityScript:GetSaveRecord qnan error")
--【PRODUCTION 下不抛错的收尾】
				end
--【降级：归零】NaN 坐标退化成 (0,0,0)，世界至少能加载。
				rx, ry, rz = 0, 0, 0
			end
--【★ 平台分支结束：只有此分支才写 puid/rx/rz】

--【★ puid = 平台的 WalkablePlatform UID】
--   不是实体 GUID，而是 walkableplatform 组件自己维护的 UID。
--   原因：同一条船在客户端与服务端的实体 GUID 不同，
--         但「这是同一条船的第几块可行走甲板」的 UID 是稳定的、随存档持久化的。
--   ★ 这是「跨端稳定的身份」与「本端运行身份」分离的典型设计。
            record.puid = platform.components.walkableplatform:GetUID()
--【空行】

--【★ 「x and ... or 0」的三元写法】
--   Lua 没有 ?: 运算符，惯用法是 a and b or c。
--   ★ 陷阱：当 b 为 false 或 nil 时会退化到 c。
--     这里 b = math.floor(...)*0.001，当坐标恰为 0 时结果是 0，
--     而 0 在 Lua 中是**真值**，所以不会退化 —— 这个写法是安全的。
--     （若写成 record.rx = cond and 0 or 0 就无意义了。）
			record.rx = rx and math.floor(rx * 1000 + 0.5) * 0.001 or 0
			record.rz = rz and math.floor(rz * 1000 + 0.5) * 0.001 or 0
--【★ Y 坐标的「选择性存储」优化】
--   注释说得很清楚："y is often 0 in our game, so be selective."
--   只在非 0 时才存 y，字段不存在则读档时视为 0。
--   ★ 这是「稀疏存档」的思路：游戏世界本质是 2.5D，绝大多数物品 y=0，
--     省下每个实体 6 个字符，几万个实体就是几百 KB。
   --   ⚠ 代价：读档端必须把缺失的 y 当0 处理，参见 loadworld 的反序列化。
			if ry and ry ~= 0 then
--【★ 注意顺序：先判 ry ~= 0 再取整】
--   这里先判断原始值是否为 0，再做四舍五入，然后**再次**判断是否为 0。
--   两段判断看似冗余，实则关键：
--     · 第一次判断 → 「本来就为 0，直接不存」
--     · 取整后再次判断 → 「原本是 0.0004 这类极小值，取整后变 0，也别存」
--   ★ 移植时若省略第二次判断，会往存档里塞大量 y=0 的字段。
				ry = math.floor(ry * 1000 + 0.5) * 0.001
--【二次判零后仍为 0 则不写字段】
				record.ry = ry ~= 0 and ry or nil
--【★ 相对 ry 的写入结束】
            end
--【end：if platform then】
        end
--【end：平台相对化分支】
    end
--【空行：离开平台分支】

    -- NaN and +/-inf hunting
    -- NaN and +/-inf hunting
--【★ 世界坐标也要做同样的 NaN 防御】
--   即使走了平台相对分支，世界坐标仍会写进 record.x/z/y，
--   所以必须再校验一次。这是「两处独立的污染源」思维。
	if isbadnumber(x) or isbadnumber(y) or isbadnumber(z) then
		print("EntityScript:GetSaveRecord error saving position: ", self.prefab, x, y, z)
		if CONFIGURATION ~= "PRODUCTION" then
			error("EntityScript:GetSaveRecord qnan error")
--【PRODUCTION 降级】
		end
		x, y, z = 0, 0, 0
--【世界坐标 NaN 检查结束】
	end
--【空行】

	record.x = x and math.floor(x * 1000 + 0.5) * 0.001 or 0
	record.z = z and math.floor(z * 1000 + 0.5) * 0.001 or 0
    --y is often 0 in our game, so be selective.
	if y and y ~= 0 then
		y = math.floor(y * 1000 + 0.5) * 0.001
		record.y = y ~= 0 and y or nil
    end
--【end：y 的选择性写入】

--【★ 皮肤三件套】skinname / skin_id / alt_skin_ids
--   DST 支持「同一 prefab 有多个皮肤」（如四季草、幻化道具）。
--   ★ 全部无条件写入（哪怕是 nil），因为它们不是坐标那种可以省略的稀疏字段 ——
--     皮肤逻辑需要区分「显式为 nil」与「未设置」两种情况。
    record.skinname = self.skinname
    record.skin_id = self.skin_id
    record.alt_skin_ids = self.alt_skin_ids
--【alt_skin_ids：备选皮肤列表】

--【★ 委托各组件序列化】
--   GetPersistData 会遍历 components，逐个调 OnSave，
--   把它们的产物合并到 data 里。参见本文件 1903 行。
--   ★ references 是「跨实体引用」列表：例如「谁拿我当目标」「我属于哪个容器」，
--     这些只能用 GUID 记录，且需要第二遍统一写盘。
    local references
    record.data, references = self:GetPersistData()
--【★ data 是主体，references 是附加的跨实体引用】

--【★ 关键：返回两个值】第二返回值 references 会一路冒泡到存档系统的顶层，
--   那里统一处理「引用去重 + 全局表写入」。
   --   这就是为什么本函数内部从不关心引用怎么落盘 —— 单一职责。
    return record, references
end
--★ 存档写出的完整字段清单：
--   prefab, [age], [puid, rx, ry, rz], x, y, z, skinname, skin_id, alt_skin_ids, data
--   ★ 方括号表示「条件性存在」。
--【空行】

--（空行）GetSaveRecord 与 Hide 之间的空行是风格上的分隔。

--【★ Hide/Show 直接转发给 C++】
--   注意参数是 false —— C++ 的 Hide 签名是 Hide(shadowhide)，
--   传 false 表示「不隐藏阴影」。
--   ★为什么不让脚本直接调self.entity:Hide()？
--     因为业务代码常常写 inst:Hide()（EntityScript 层面），
--     这一层薄封装统一了语义并留出了将来加逻辑的空间。
function EntityScript:Hide()
--【Hide(false)：不隐藏阴影】
    self.entity:Hide(false)
end
--【空行】

function EntityScript:Show()
--【Show(false)：对称实现】
    self.entity:Show(false)
end
--【空行】

-- NOTES(Omar): Deprecated, we do not use this function (still use the hack though!)
-- NOTES(Omar): Deprecated, we do not use this function (still use the hack though!)
--【⚠ 疑似缺陷：自我否定但仍在运行的函数】
--   注释明确说「已废弃，我们不用它」，但代码还留着，且仍有调用方。
--   推理依据：函数体返回一个永远为 true 或皮肤 build 相等的布尔值，
--   其中的 "AnimState hack"（331-333 行）说明真正的皮肤比对在别处实现了。
--   ★ 保留它的唯一理由是「兼容外部模组」—— 删除会破坏 mod 的脚本。
--   → 正确做法：标记 deprecated 并加警告日志，同时保留实现直到下个大版本移除。
function EntityScript:StackableSkinHack(target)
--【★ 注释里说的 hack 是什么】
--   原来靠 StackableSkinHack 判断「两个实体的皮肤是否兼容」，
--   但注释说「客户端不行，所以改用 AnimState 的 GetSkinBuild」。
--   AnimState 是 C++ 对象，其状态在两端都能读到，因此可跨端使用。
--   ★ 教训：凡是「纯 Lua 推断但两端不一致」的逻辑，都必须改由 C++ 提供权威答案。
    -- NOTES(JBK): This is a replacement function for old comments that were the following line.
--【★ 关于「客户端不行」的技术说明】
    -- (this does not work on clients, so we're going to use the AnimState hack instead)
--【缺 AnimState 就视为兼容】宁可放过（true）也不误杀。
    if self.AnimState == nil or target.AnimState == nil then
        return true
    end

    return self.AnimState:GetSkinBuild() == target.AnimState:GetSkinBuild()
--【StackableSkinHack 结束】
end

--★★ ★ ★ limbo（虚体）机制 ★ ★ ★
--【★ limbo 是什么】
--   limbo（虚体）= 实体仍然存在于内存与存档中，但不参与世界模拟。
--   进入 limbo 时：隐藏、停物理、停动画、停状态图、停大脑、不出现在小地图。
--   ★ 典型用途：
--     · 玩家离开加载范围（unload chunk）→ 实体休眠但保留存档数据
--     · 船驶离大陆 → 船上的东西跟着进 limbo
--     · hideout / 洞穴切换
--   ★★ limbo 与 sleep 是完全正交的两个维度：
--     sleep —— C++ 层实体休眠（不出现在活跃区、不参与网络）
--     limbo —— Lua 层业务挂起（brain/状态图/物理全停）
--     一个实体可以「睡着但不在 limbo」（网络休眠，逻辑冻结），
--     也可以「在 limbo 但醒着」（罕见，多见于调试）。
--   ——这正是 RemoveFromScene 与 ReturnToScene 需要分别处理两者的原因。
--【与 sleep 的耦合点】见 ReturnToScene 403-411 行：
--   回场时先看IsAsleep()，只有「不 asleep 且 sleepstatepending 已解除」才重启大脑。
function EntityScript:IsInLimbo()
    --V2C: faster than checking tag, but only valid on mastersim
    --V2C: faster than checking tag, but only valid on mastersim
--【★ 为什么直接返回字段而不是 self.entity:HasTag("INLIMBO")？】
--   注释说「比查标签快，但只在 mastersim 有效」。
--   推理依据：
--     · HasTag 是跨 Lua→C++ 的 FFI 调用，有固定开销；
--     · self.inlimbo 是纯 Lua 字段读取，几乎零成本。
--     · 客户端实体没有 RemoveFromScene/ReturnToScene 的调用（那是服务端行为），
--       所以客户端的 inlimbo 恒为 false，字段不可信。
--   ★ 这是一条重要的通用准则：**服务端专属的捷径必须注明只在一个模拟有效**。
   --   ⚠ 潜在陷阱：若将来在客户端也调RemoveFromScene，inlimbo 会失准。
    return self.inlimbo
--【★ limbo 与 sleep 的交叉表 —— 全文最重要的概念澄清】
   --★ ★★ 四种组合及其行为】
--   醒 + 不在 limbo：正常工作（常见情况）
--   睡 + 不在 limbo：引擎休眠，brain/sg 已停（网络裁剪的典型）
--   醒 + 在 limbo：不应出现；若出现说明 RemoveFromScene 后被 OnEntityWake 了
--   睡 + 在 limbo：合法（船离开加载范围时同时满足两者）
--   ★ 第四种组合正是ReturnToScene:403-411 需要三重判断的原因。
end
--【空行】

--【★ ForceOutOfLimbo：把「进 limbo」的决策权从外部夺过来】
--   语义：即使当前不在 limbo，也强制让实体保持在场景中。
--   典型用途：某些逻辑（如 hide-and-seek 的躲藏点）要求实体必须留在场景里，
--     不允许被常规的 RemoveFromScene 带走。
--   ★ 只设一个标志位，不做实际的 SetInLimbo —— 由调用者在合适时机落地。
function EntityScript:ForceOutOfLimbo(state)
--【★ 标志位归一化：true 或 nil，绝不存 false】
    self.forcedoutoflimbo = state or nil
--【★★ 三态真值表 —— 这行是全文最绕的表达式之一】
--   self.entity:SetInLimbo( self:IsInLimbo() and not self.forcedoutoflimbo or false )
--
--     当前在 limbo?  forcedoutoflimbo?  →  SetInLimbo 参数
--     ─────────────────────────────────────────────────────
--     false          nil                 →  false        （本来就不在 limbo）
--     true           nil/true            →  false        （强制留在场景）
--     true           false               →  true         （正常进 limbo）
--
--   ★ 为什么不用 if/else？因为 forcedoutoflimbo 只存「真值」，
--     nil 与 false 同义（344 行 state or nil 归一化了），
--     所以 `not self.forcedoutoflimbo` 天然覆盖两者。
--   ★ `or false` 是防止 `false and ... or ...` 缺省分支产出 nil 的惯用法。
    self.entity:SetInLimbo(self:IsInLimbo() and not self.forcedoutoflimbo or false)
end
--【空行】

--★★ RemoveFromScene：把实体从「活跃世界」中摘除 —— 进入 limbo 的完整流程
--【调用方】网络裁剪（客户端离开范围）、hideout、despawn 类逻辑。
--   参考调用点：components/inventoryitem.lua:349（放入容器时移出场景）、
--     components/hideout.lua:177、components/hermitcrab_relocation_manager.lua:240。
--【执行顺序的讲究】见 375 行后的说明。
--★★ 参见 components/inventoryitem.lua:349（入包即移出场景）、
--   components/hideout.lua:177、
--   components/hermitcrab_relocation_manager.lua:240 —— 均为调用方。
function EntityScript:RemoveFromScene()
--【★ 标签与布尔字段双写】
--   标签 INLIMBO  给「跨端/通用查询」用（如 UI 过滤），
--   字段 inlimbo  给「服务端高频查询」用（IsInLimbo）。
--   ★ 同一份状态两种表示，是为了兼顾「C++ 侧可见」与「Lua 侧低开销」。
    self.entity:AddTag("INLIMBO")
--【尊重强制留在场景的标志】与 ForceOutOfLimbo 呼应。
    self.entity:SetInLimbo(not self.forcedoutoflimbo)
    self.inlimbo = true
    self.entity:Hide()
--【★ Hide：limbo 实体不渲染】

--【★★ 先停大脑 —— 因为大脑会驱动状态图和组件，顺序至关重要】
--   若先停组件再停大脑，大脑在停止过程中还可能调组件方法 → 访问已停组件。
--   _DisableBrain_Internal 见1120 行。
	self:_DisableBrain_Internal()

--【★★ 状态图必须显式 Stop】
--   状态图不只是「不再 tick」，它内部还持有 OnTick 回调、定时等待、事件队列。
--   SGManager 侧需要被通知才能把这些从调度列表里摘掉。
--   ★ 注意：Stop 后 self.sg 仍然存在（对象还在），
--     回到场景时用 sg:Start(asleep) 恢复，见 408-410 行。
    if self.sg then
        self.sg:Stop()
--【★ sg:Stop 只停不销毁，保留实例供复用】
    end
--【逐组件「冻结」】顺序无关紧要，但清单必须完整：
--   Physics      —— 停止碰撞与重力，否则会继续下落穿地
--   Light        —— ★ 只在 GetDisableOnSceneRemoval() 为真时关，
--                   因为有些光源（如火把）是「隐藏但不熄火」的设定
--   AnimState    —— 停止动画播放，节省 CPU；Pause 而非 Stop 是为了保留当前帧
--   DynamicShadow—— 阴影是渲染开销大户，limbo 实体不需要投影
--   MiniMapEntity—— 从小地图消失，玩家不会跑到看不见的坑里
    if self.Physics then
        self.Physics:SetActive(false)
    end
    if self.Light and self.Light:GetDisableOnSceneRemoval() then
        self.Light:Enable(false)
    end
--【AnimState:Pause 保留当前帧以便恢复】
    if self.AnimState then
        self.AnimState:Pause()
--【DynamicShadow:Enable(false) 关闭阴影投射】
    end
    if self.DynamicShadow then
        self.DynamicShadow:Enable(false)
    end
    if self.MiniMapEntity then
        self.MiniMapEntity:SetEnabled(false)
    end
--【逐组件冻结结束】

--【★ enterlimbo 事件放在最后】
--   监听者（如 UI、音效、埋点）拿到的状态是「完全冻结之后」的，
--   读取任何组件属性都得到一致的静止值。
--   ★ 这是一个通用的「状态变更事件应在变更完成后触发」的约定，
--     在全游戏的 PushEvent 使用中都能看到。
    self:PushEvent("enterlimbo")
end
--【空行】

--★★ ReturnToScene：从 limbo 恢复 —— 与 RemoveFromScene 完全对称
--【★ 三态防护】若实体已无效，仍继续执行会把崩溃推迟到更难排查的地方，
--   所以打印错误日志（注释说 "Keep this for debug logs to come"）。
--   ⚠ 疑似缺陷：打印了错误却没有 return，也没有 error()，
--     于是调用方无法从返回值判断失败，继续操作已失效的 Transform。
--     更稳妥的做法是 return false 并让调用方处理。
function EntityScript:ReturnToScene()
    if not self:IsValid() then
--【原注释："Keep this for debug logs to come."】
--   即：这行日志是为了将来接入日志系统而保留的，暂不删。
        print("[ERROR] Calling ReturnToScene on an invalid entity!", self.prefab) -- Keep this for debug logs to come.
    end
--【★ 与RemoveFromScene 的对称解冻】

--【★ 与 RemoveFromScene 逐行对称】
--   RemoveTag → SetInLimbo(false) → inlimbo=false → Show()
--   这四步与 349-352 行严格对应。
--   ★ 维护提示：修改其中一个必须同步修改另一个，否则进出 limbo 行为会不一致。
    self.entity:RemoveTag("INLIMBO")
    self.entity:SetInLimbo(false)
    self.inlimbo = false
--【★ Show：恢复渲染】
    self.entity:Show()
--【★ 与 RemoveFromScene 的不对称：这里无条件恢复】
--   RemoveFromScene 里 Light 只在 GetDisableOnSceneRemoval() 时关闭，
--   这里却无条件 Enable(true)。
--   ★ 这是刻意的：只要之前没关，恢复就是安全的；
--     而如果进入前灯是关的，恢复时会错误地点亮。
--   ⚠ 疑似缺陷：更严谨的写法应该同样检查 GetDisableOnSceneRemoval()。
--     不过实践中 limbo 不太可能跨越「灯被手动关闭」的时间窗口。
    if self.Physics then
        self.Physics:SetActive(true)
--【Physics:SetActive(true)】
    end
    if self.Light then
        self.Light:Enable(true)
--【Light:Enable(true) 无条件恢复】
    end
    if self.AnimState then
        self.AnimState:Resume()
--【AnimState:Resume 从暂停处继续】
    end
    if self.DynamicShadow then
        self.DynamicShadow:Enable(true)
--【DynamicShadow 恢复】
    end
    if self.MiniMapEntity then
        self.MiniMapEntity:SetEnabled(true)
--【MiniMapEntity 恢复：小地图重新显示】
    end
--【brain / sg 恢复区结束】

--★★ ★ ★ 大脑与状态图的恢复 —— 与睡眠状态的三方协商 ★ ★ ★
--   三个输入：
--     brainfn —— 该实体配置了大脑吗（由 prefab 脚本设置）
--     sg     —— 该实体配置了状态图吗
--     IsAsleep() / sleepstatepending —— 引擎当前的休眠状态是否可信
--   ★ 三个条件缺一不可：
--     没配大脑 → 跳过；配了但实体在睡觉 → 不启动（省CPU）；
--     配了但初始休眠状态还没从引擎传来 → 不启动（否则会误启动）。
	if self.brainfn or self.sg then
--【★ 先算 asleep】因为下面两个分支都要用它，避免重复调用 C++。
		local asleep = self:IsAsleep()
--【★★ 三重条件：brain 存在 + 不 asleep + 休眠状态已知】
--   注意是 `not (asleep or self.sleepstatepending)`，
--   ★ 即「既没睡着、而且已经知道它没睡着」—— 双保险。
--   这正是构造器里 sleepstatepending 存在的原因（见 221 行），
--     两个相隔 800 行的决策点共享同一个时序补丁，非常值得注意。
		if self.brainfn and not (asleep or self.sleepstatepending) then
--【★ 重建大脑实例】
			self:_EnableBrain_Internal()
		end
		if self.sg then
--【★ sg:Start(asleep) 把休眠状态透传给状态图】
--   状态图据此决定是否立即进入 sleepstate ——
--   如果实体醒着，状态图正常跑；
--   如果实体还睡着，状态图进入「只在 OnEntityWake 里干活」的形态。
   --   ★ 这个参数传递是 Sleep 与 StateGraph 两个系统之间的唯一耦合点。
			self.sg:Start(asleep)
		end
    end
--【★ exitlimbo 在最后】与 enterlimbo 对称：状态完全恢复后才广播。
    self:PushEvent("exitlimbo")
end
--★ ReturnToScene 与 RemoveFromScene 的对称性检查清单：
--   RemoveTag('INLIMBO')   ↔ RemoveFromScene 的 AddTag
--   SetInLimbo(false)      ↔ SetInLimbo(...)
--   inlimbo = false        ↔ inlimbo = true
--   entity:Show()          ↔ entity:Hide()
--   Physics/AnimState/Shadow/MiniMap 恢复 ↔ 停用
--   _EnableBrain_Internal ↔ _DisableBrain_Internal
--   sg:Start(asleep)      ↔ sg:Stop()
--   PushEvent("exitlimbo") ↔ PushEvent("enterlimbo")
--   ★★ 唯二不对称：Light 的条件判断（见 362/390 行的分析）
--     与 sleep 状态的处理（RemoveFromScene 不动 sleep）。
--【空行】

--【★ __tostring = 调试身份】
--   "<GUID> - <prefab>(LIMBO)"
--   ★ 在日志里带上 (LIMBO) 后缀，排查「为什么实体没动」时一眼看穿。
--   ⚠ 注意 self.prefab 可能为 nil（还没走 SetPrefabName），
--     用 `self.prefab or ""` 兜住了。
function EntityScript:__tostring()
    return string.format("%d - %s%s", self.GUID, self.prefab or "", self.inlimbo and "(LIMBO)" or "")
end
--【空行】

function EntityScript:AddInherentAction(act)
--【★ inherentactions 的懒初始化】
    self.inherentactions = self.inherentactions or {}
    self.inherentactions[act] = true
--【★ 立即同步到网络】
    SerializeInherentActions(self)
end
--【空行】

function EntityScript:RemoveInherentAction(act)
--【★ 移除前判空】
    if self.inherentactions ~= nil then
        self.inherentactions[act] = nil
        if next(self.inherentactions) == nil then
            self.inherentactions = nil
        end
        SerializeInherentActions(self)
    end
end
--【空行】

--【GetTimeAlive】GetTime() - spawntime。
--   ★ 只用于调试显示与「实体活了多久」类的年龄逻辑（如小树苗成长）。
--   ⚠ 因为基于 GetTime()，会受游戏加速影响；不可用于需要真实时间的逻辑。
function EntityScript:GetTimeAlive()
--【★ 返回的是「已存活秒数」】
    return GetTime() - self.spawntime
end
--【★ 组件更新区起点】

--★★ ★ ★ 组件更新双缓冲机制 ★ ★ ★
--【三张全局更新表】理解本节必须先看update.lua:256 的主循环：
--   UpdatingEnts        —— 本帧要更新组件的实体（GUID → EntityScript）
--   NewUpdatingEnts     —— ★ 本帧新加入的实体（缓冲）
--   StaticUpdatingEnts / NewStaticUpdatingEnts —— 暂停时仍更新的那一份
--   WallUpdatingEnts / NewWallUpdatingEnts     —— 物理步之前更新的那一份
--
--【★ 为什么每张表都有 New 前缀的缓冲表？】
--   因为主循环正在 `for k,v in pairs(UpdatingEnts)` 中遍历，
--   如果某个组件的 OnUpdate 里调了 StartUpdatingComponent(另一个组件)，
--   那个组件会被立即插入正在遍历的表 —— 
--   ★★ 在 Lua 中给正在 pairs 遍历的表**新增键**是未定义行为：
--     可能被遍历到（时序不确定），也可能触发哈希重排导致漏遍历。
--   解决：新加入的先放NewUpdatingEnts，主循环遍历结束后再整体并入。
--   参见 update.lua:270-275。
--
--【★ 为什么停止必须是「延迟」的？—— 见 475 行的详细说明】
--★★ 参见 update.lua:256 是主循环的组件更新遍历；
--   update.lua:270 是 NewUpdatingEnts 的并表位置；
--   update.lua:277 是 StopUpdatingComponents 的帧末清理位置；
--   update.lua:54 是 WallUpdatingEnts 的遍历。
function EntityScript:StartUpdatingComponent(cmp, do_static_update)
--【★ 无效实体直接拒绝】
--   因为 self.updatecomponents = self 会把实体挂进全局表，
--   而已Retire 的实体再被遍历到就是「访问已释放资源」。
--   ★ 这是所有「把自己注册进全局表」的方法都必须做的防护。
    if not self:IsValid() then
--【★ 无效实体拒绝登记：防全局表污染】
        return
--【空行】
    end
--【★ 懒建 updatecomponents 的判据】

--【★★ 懒创建 + 一次性入表】
--   只有第一个组件调 StartUpdatingComponent 时才创建 updatecomponents 表，
--   并把实体登记进全局表。后续组件只填表不再碰全局表。
--   ★ num_updating_ents 是全局计数器，主循环用它决定是否需要遍历（快速退出）。
--   ⚠ 递增只在这里、递减只在 StopUpdatingComponent_Deferred 与 Remove 里，
--     这三处必须严格配对，否则计数会漂移。参见 1735 行。
    if not self.updatecomponents then
--【★ 第一次创建才入全局表】
        self.updatecomponents = {}
--【★ NewUpdatingEnts 是「本帧新加入」缓冲】
        NewUpdatingEnts[self.GUID] = self
--【★ num_updating_ents 全局计数 +1】
        num_updating_ents = num_updating_ents + 1
    end
--【end：懒建分支】

--【★ do_static_update：同时加入「暂停时也更新」集合】
--   典型用途：UI 驱动的组件（inventory、craftable）在游戏暂停时仍需响应。
--   ★ 注意 StaticUpdatingEnts 的入表没有计数—— 因为主循环靠 next() 判空而非计数。
    if do_static_update then
        if not self.updatestaticcomponents then
--【★ 静态更新表同样是懒建】
            self.updatestaticcomponents = {}
            NewStaticUpdatingEnts[self.GUID] = self
--【★ NewStaticUpdatingEnts 缓冲】
        end
    end
--【★ 撤销待停标记的判据：必须是自己】

--★★ 撤销「待停标记」—— 这是双缓冲里最容易漏掉的一环
--   场景：组件 C 在本帧 A 处调了 StopUpdatingComponent(C)，
--         随后在本帧 B 处又调了 StartUpdatingComponent(C)。
--   若不撤销，帧末的延迟清理会把 C 从 updatecomponents 里删掉，
--         ★ 结果是「明明启动了，却再也不会被更新」—— 一个极难排查的幽灵 bug。
--   `StopUpdatingComponents[cmp] == self` 确认这个待停标记确实属于自己，
--   避免误清除别的实体的待停标记（理论上同一 cmp 只属于一个实体，但保持严谨）。
--【★ 与 StopUpdatingComponent:477 的对偶关系】
--   Stop 把 cmp 放进 StopUpdatingComponents；
--   Start 把 cmp 从 StopUpdatingComponents 里拿掉。
--   ★ 一放一取，构成完整的「状态覆盖」语义。
    if StopUpdatingComponents[cmp] == self then
        StopUpdatingComponents[cmp] = nil
    end
--【★ 组件名反查开始】

--★★★ 反查组件名的 O(n) 遍历 —— 本节唯一的性能槽点
--   为什么需要 cmpname？因为 updatecomponents 的键是「组件实例」，
--     值是「组件名」，update.lua 的性能剖析器会用这个值做 ProfilerPush 的标签
--     （update.lua:260 被注释掉的那行），便于在分析器里看到「是哪个组件慢」。
--   ★★ 代价：这是 O(组件数) 的线性查找，且每次 StartUpdatingComponent 都做一遍。
--     好在组件数通常 < 10，且该操作并不在每帧热路径上。
--   ⚠ 性能提示：若某实体有 50 个组件且频繁切换更新状态，应改为反向索引
--     （self._cmp2name[cmp] = name）。当前实现选择了「可读性优先」。
   --   ★ 注意找不到时回退成字符串 "component"，保证值永不为 nil
--     （nil 值会让 updatecomponents[cmp]=nil 等价于「不存在」，是逻辑陷阱）。
    local cmpname = nil
    for k,v in pairs(self.components) do
        if v == cmp then
            cmpname = k
            break
--【命中即退出循环】
        end
    end
    self.updatecomponents[cmp] = cmpname or "component"
--【★ 值必须是字符串，绝不能是 nil】

    if do_static_update then
        self.updatestaticcomponents[cmp] = cmpname or "component"
--【★ 静态更新表同步登记】
    end
end
--【空行】

--★★ ★ ★ StopUpdatingComponent：为什么「停止」必须延迟 ★ ★ ★
--【问题】主循环 update.lua:259 正在这样遍历：
--     for cmp in pairs(v.updatecomponents) do
--         if cmp.OnUpdate and not StopUpdatingComponents[cmp] then
--             cmp:OnUpdate(dt)
--         end
--     end
--   若在 cmp:OnUpdate(dt) 内部直接执行 self.updatecomponents[cmp] = nil，
--   ★★ 就是「在 pairs 遍历中删除当前键」。在 Lua 5.1 里这是合法的（置 nil 安全），
--     但如果 OnUpdate 里又调了 StartUpdatingComponent 添加新组件，
--     就会与正在进行的遍历冲突 —— 新键可能被跳过或引发哈希重排。
--
--【★ 解决方案：两阶段】
--   阶段1（本函数）：只往全局 StopUpdatingComponents 里记一笔，
--            ★ 此时 cmp 仍在 updatecomponents 里，仍会被本帧遍历到，
--              但 update.lua:261 的 `not StopUpdatingComponents[cmp]` 会跳过它的 OnUpdate。
--              ★★ 所以「本帧不再更新」这个语义**立刻生效**了，
--                只是「从表里删掉」被推迟到帧末。
--   阶段2（StopUpdatingComponent_Deferred）：在主循环遍历结束后，
--            由 update.lua:277 调用，真正执行删除。
--
--【★ 语义精确性】两个阶段合起来保证：
--   · 停止请求当帧即生效（不会多跑一次 OnUpdate）
--   · 表结构改动延后到安全时刻
--   · 若同帧又有 Start，StartUpdatingComponent:457 会撤销待停标记
   --★ 移植到 C#/C++ 时必须显式区分这两个阶段，否则会遇到难以复现的时序 bug。
--★★ 参见 update.lua:261 的 `not StopUpdatingComponents[cmp]` 判断
--   正是本函数「延迟删除」能保持语义正确的原因；
--   update.lua:279 调用本函数的 Deferred 版本。
function EntityScript:StopUpdatingComponent(cmp)
--【★ 守卫条件】只有确实在更新表里才需要登记待停。
--   若实体从未注册过更新，登记只会给 StopUpdatingComponents 留下垃圾条目，
--   而帧末清理时 self.updatecomponents 为 nil 会直接跳过（见 482 行），
--   垃圾条目虽然无害但会让 `next(StopUpdatingComponents) ~= nil` 恒真，
--   ★ 每帧都白跑一次清理循环。
--【★ 守卫的真正意义 —— 避免 StopUpdatingComponents 永不收敛】
--   若无条件登记，帧末清理时 StopUpdatingComponent_Deferred:482
--   会因 self.updatecomponents 为 nil 而直接 return，
--   但 update.lua:207/281 已把 StopUpdatingComponents 整表重置，
--   所以条目不会残留。
--   ★ 所以这个守卫纯粹是「省一次无用调用」，不是正确性必需。
    if self.updatecomponents or self.updatestaticcomponents then
--【★ 登记而非删除：这是双缓冲的全部关键】
        StopUpdatingComponents[cmp] = self
--【★ 值的意义：帧末才知道该通知谁】
    end
end
--【空行】

--★★ 帧末的真正删除 —— 由 update.lua:277 调用
--   ★ 本函数是 public 的（带下划线前缀但确实是 EntityScript 方法），
--     因为主循环要通过 v: 冒号调用它。
--【★ 为什么表空了要置 nil 而不是留空表？】
--   ① 置 nil 后主循环的 `if v.updatecomponents then` 直接跳过，连 pairs 都不用进；
--   ② 省内存（空表也要占表头）；
--   ③ 让「是否在更新表」这个判断成为 O(1) 的 nil 检查。
--【★ 与 StartUpdatingComponent:439 的完整对偶清单】
--   对偶点1：本函数删，彼函数建
--   对偶点2：本函数不动 NewUpdatingEnts（由 488 行处理），
--           彼函数不动 StopUpdatingComponents（由 457 行处理）
--   ★ 两个「不动」正是双缓冲设计的关键：
--     「谁登记新实体」与「谁撤销待停标记」是两件正交的事。
function EntityScript:StopUpdatingComponent_Deferred(cmp)
    if self.updatecomponents then
--【★ 真正删除发生在这里】
        self.updatecomponents[cmp] = nil

--【★ 计数器递减的唯一出口之一】与 StartUpdatingComponent:447 配对。
   --⚠ 这里的 decrement 只在 updatecomponents 整体变空时发生，
--     若实体同时有 wallupdate 和 static 组件，计数语义是独立的。
        if IsTableEmpty(self.updatecomponents) then
--【★ 计数器 -1 的配对点】
            self.updatecomponents = nil
            UpdatingEnts[self.GUID] = nil
            NewUpdatingEnts[self.GUID] = nil
--【★ num_updating_ents 与 447 行配对】
            num_updating_ents = num_updating_ents - 1
--【end：updatecomponents 非空时】
        end
    end
--【空行】

--【★ 静态更新表的对称清理】
--   ★ 注意静态更新表没有配对的计数变量 ——
--     因为 update.lua:203 用 `if next(StopUpdatingComponents) ~= nil` 判断，
--     且 StaticUpdate 分支是 `if TheNet:IsServerPaused()` 才进入，
--     属于低频路径，不需要优化计数器。
    if self.updatestaticcomponents then
        self.updatestaticcomponents[cmp] = nil
--【静态表删除】

        if IsTableEmpty(self.updatestaticcomponents) then
--【★ 静态表变空 → 整体摘除】
            self.updatestaticcomponents = nil
--【同时从新旧两张表移除】
--   ★ 必要性：实体可能在本帧的 NewStaticUpdatingEnts 里（刚加入还没并入），
--     只清 StaticUpdatingEnts 会让它在下一帧的并表操作中复活。
--   对照 200行：entity Remove 时也要清 NewUpdatingEnts，见 1740/1746/1752。
            StaticUpdatingEnts[self.GUID] = nil
            NewStaticUpdatingEnts[self.GUID] = nil
        end
--【end：updatestaticcomponents 分支】
    end
end
--★ 帧末清理的完整动作清单（供 update.lua:279 参考）：
--   ① updatecomponents[cmp] = nil
--   ② 若整体空 → updatecomponents = nil + UpdatingEnts[GUID] = nil
--                  + NewUpdatingEnts[GUID] = nil + num_updating_ents -= 1
--   ③ updatestaticcomponents 同样处理（但无计数）
--【空行】

--★★WallUpdate：物理步之前的更新阶段
--【与 OnUpdate 的区别 —— 时机】
--   OnUpdate      —— 每帧的「逻辑帧」，dt 约 1/30 秒
--   OnWallUpdate  —— ★ 在物理模拟**之前**执行（update.lua:54），
--                    因此修改坐标/速度会影响本步物理结果。
--   典型用途：跟随平台的实体必须在物理前更新坐标，否则会「落后一帧」，
--              站在移动的船上会抖动或掉下去。
--【★ 与普通更新表的另一个区别】
--   它**没有** StopUpdatingComponents 延迟机制。
--   StopWallUpdatingComponent 是立即生效的。
--   ⚠ 这是一个真实的不对称：若某个 wallupdate 组件在 OnWallUpdate 中调
--     StopWallUpdatingComponent，会在遍历中删表（update.lua:56 是 for cmp in pairs(...))。
--     实践上很少有人在 OnWallUpdate 里停自己，暂未暴露。
--★★ 参见 update.lua:54 `for cmp in pairs(v.wallupdatecomponents)`
--   —— 该遍历没有 StopUpdatingComponents 缓冲，故本表是立即生效的。
function EntityScript:StartWallUpdatingComponent(cmp)
    if not self:IsValid() then
--【★ 无效实体拒绝登记】
        return
    end
--【空行】

--【懒创建 + 入表】与 StartUpdatingComponent 结构一致，但少了计数器和待停撤销。
    if not self.wallupdatecomponents then
--【★ wallupdate 表懒建】
        self.wallupdatecomponents = {}
--【★ 无计数的缓冲表】
        NewWallUpdatingEnts[self.GUID] = self
--【end：懒建分支】
    end
--【空行】

--【同样的 O(n) 组件名反查】与 461行 相同的技术债。
    local cmpname = nil
    for k,v in pairs(self.components) do
        if v == cmp then
            cmpname = k
            break
        end
    end

    self.wallupdatecomponents[cmp] = cmpname or "component"
--【★ 与普通更新表的差别：无计数、无待停撤销】
end
--【空行】

--【空行】

--【空行】

--★★ 立即停止 WallUpdate —— 无延迟缓冲
--【★ 与 StopUpdatingComponent 的核心差异】
--   那里是「标记 +帧末删」，这里是「当场删」。
--   原因推测：wallupdate 组件数量少（通常只有 platform follower 一个），
--   且 OnWallUpdate 内的增删极少发生。
--   ⚠ 疑似缺陷：从 update.lua:56 的 for cmp in pairs(v.wallupdatecomponents) 看，
--     此处在遍历中置 nil 属于「修改已有键」，Lua 5.1 允许，但行为依赖实现。
--     更安全的是像 OnUpdate 那套加缓冲。
function EntityScript:StopWallUpdatingComponent(cmp)
--【★ 立即删表：与 StopUpdatingComponent 的重大差异】

--【★ 判空：不在 wallupdate 表中就什么都不做】
    if self.wallupdatecomponents then
        self.wallupdatecomponents[cmp] = nil
--【★ 立即从表里删（无延迟）】

--★ 这里没有用 IsTableEmpty 而是手写了一个「只数一个就 break」的循环。
--   推理：这可能是在热路径上避免一次函数调用（IsTableEmpty 是全局 Lua 函数），
--   属于微优化。但写法晦涩，与 StopUpdatingComponent_Deferred:485 用 IsTableEmpty 不一致。
--   → 建议统一为 next(t) == nil，可读性更好且同样快。
        local num = 0
        for k,v in pairs(self.wallupdatecomponents) do
            num = num + 1
            break
--【★ break 让循环只跑一次 —— 等价于 next() ~= nil】
        end

--【★ 变空则整体摘除】
        if num == 0 then
            self.wallupdatecomponents = nil
--【★ 同时清 NewWallUpdatingEnts】理由同498 行：新表里可能残留刚入表未并入的实体。
            WallUpdatingEnts[self.GUID] = nil
            NewWallUpdatingEnts[self.GUID] = nil
--【★ 同时清 New 表，防止「未并表即销毁」的复活】
        end
    end
end
--【空行】

--【空行】

--【GetComponentName：调试与性能剖析用的名字查询】
--   ★ 失败时返回 "component" 而不是 nil —— 保证永远能拼进字符串。
--   ⚠ 这也是一次 O(n) 线性查找，若在每帧调用会成为热点。
--     update.lua:260 那行 `v:GetComponentName(cmp)` 正被注释掉，
--     说明官方也意识到它的开销。
function EntityScript:GetComponentName(cmp)
    for k,v in pairs(self.components) do
        if v == cmp then
--【未命中即返回兜底名】
            return k
        end
    end
    return "component"
end
--★ 这三个函数（StartUpdating / StartWallUpdating / GetComponentName）
--   都做了「O(n) 组件名反查」。这是本文件已知的性能债，
--   在 update.lua:260 那行被注释掉的 ProfilerPush 里也能看出痕迹。
--【空行】

--★★★ 标签系统 —— 游戏逻辑的「零成本布尔查询」层★★★
--【标签是什么】
--   标签（tag）是附着在实体上的字符串标记，供 C++ 侧做快速分组查询。
--   它不是布尔字段：实体可以同时有 500 个标签，查询是哈希查找。
--【★ 标签 vs 字段 —— 为什么两者并存】
--   · 字段（self.myflag = true）：Lua 侧读取，零开销，但不能被 C++ 查询
--   · 标签（self:AddTag("myflag")）：跨 Lua/C++ 边界可见，
--     能被 TheSim:FindEntities(..., tags) 之类的空间查询直接使用，
--     也能被 UI 层、以及「组件是否该安装」这类框架逻辑读取。
--   ★ 典型例子：EntityScript:ValidateReplicaComponent 用 HasTag("_"..name)
--     决定副本可见性（entityreplica.lua:30），这是纯 Lua 访问不到的。
--【本节四个查询函数的性能差异 —— 这是本节的重点】
function EntityScript:AddTag(tag)
--【直接转发 C++】★ 标签的存储在 C++ 侧，Lua 只是句柄。
    self.entity:AddTag(tag)
--【AddTag 结束】
end
--【空行】

function EntityScript:RemoveTag(tag)
    self.entity:RemoveTag(tag)
end
--【RemoveTag 结束】

--【★ AddOrRemoveTag：条件式标签切换的便利 API】
--   ★ 这是极常见的写法：某状态改变时，「有就加、无就删」。
--     写成 if cond then AddTag else RemoveTag end 会有 4 行样板代码。
--   典型：SetTerraformExtraSpacing（846行）用它维护 terraformblocker 标签。
function EntityScript:AddOrRemoveTag(tag, condition)
    if condition then
        self.entity:AddTag(tag)
    else
        self.entity:RemoveTag(tag)
    end
end
--【空行】

--★★ HasTag：单标签查询 —— 最常用
--【性能特征】
--   一次 Lua → C++ FFI 调用 + C++ 侧哈希查找。
--   ★ 相比「读一个 Lua 字段」大约慢一个数量级，
--     因此在每帧执行上百次的循环里应缓存结果。
--   ★ 但相比「遍历 components 表找组件」要快得多（那是 O(n) 的纯 Lua 循环）。
--   —— 结论：需要跨端可见或被FindEntities 使用的标志，用标签；
--     纯内部状态，用字段。
function EntityScript:HasTag(tag)
    return self.entity:HasTag(tag)
end
--【★ select(1, ...) 取第一个变长参数】

--★★ HasTags：全部满足（AND 语义）
--【★ 双形态签名：变长参数 or 数组】
--   local tags = select(1, ...)  -- 取第一个变长参数
--   if type(tags) == "table" then -- 若传的是表 → unpack 后交给 C++
--   ★ 为什么需要两种形态？因为 Lua 的 unpack 只能处理「连续的尾部参数」，
--     当标签集合是运行时构造的数组时，只能走 unpack 路径；
--     而固定几个标签时直接写 HasTags("a","b","c") 更高效（无表分配）。
   --   ★ 细节：只判断 type(tags)=="table" 就切换模式，
--     若第一个参数恰好是字符串而后续是表（不可能的调用），行为未定义。实际无风险。
--【★ 短路优化】C++ 侧 HasAllTags 会在第一个不匹配时立即返回 false，
--   所以顺序很重要：把「最可能不满足」的标签放前面，可以更早退出。
function EntityScript:HasTags(...)
    local tags = select(1, ...)
--【★ 数组形态：unpack 后交给 C++ 的 HasAllTags】
    if type(tags) == "table" then
        return self.entity:HasAllTags(unpack(tags))
    else
        return self.entity:HasAllTags(...)
    end
end
--【★ 别名】HasAllTags 是语义更清晰的名字，与 C++ 侧 HasAnyTag/HasAllTags 对齐。
--   ★ 直接赋值别名而非再包一层函数，省一次函数调用。
--   ⚠ 代价：两者是同一个函数对象，debug 里无法区分，且
--     猴补其中一个会同时影响另一个（模组踩坑点）。
EntityScript.HasAllTags = EntityScript.HasTags
--【空行：别名之间】

--★★ HasOneOfTags：任一满足（OR 语义）
--   对应 C++ 侧 HasAnyTag。是AIMove 目标筛选（如找 "hostile" 或 "cattoy"）的主力。
--【★ OR 查询的短路优势更明显】一旦命中立即返回，
--   所以在长列表里，把最可能命中的标签放前面能显著提速。
function EntityScript:HasOneOfTags(...)
    local tags = select(1, ...)
    if type(tags) == "table" then
        return self.entity:HasAnyTag(unpack(tags))
    else
        return self.entity:HasAnyTag(...)
    end
--【HasOneOfTags 结束】
end
--【★ HasAnyTag 别名】
EntityScript.HasAnyTag = EntityScript.HasOneOfTags
--【空行】

--【★ require("entityreplica") —— 通过副作用扩展本类】
--   entityreplica.lua 顶部没有 return，它靠直接给EntityScript 挂方法来扩展。
--   这种「require 即混入」的模块组织方式在 DST 里很常见。
--   它给本类带来：ValidateReplicaComponent / ReplicateComponent /
--                UnreplicateComponent / PrereplicateEntity / ReplicateEntity
   --   ★ 见 597-602 行的原始说明（保留原文）。
--★★ 参见 entityreplica.lua 的 ReplicateComponent:34
--   由本文件的 AddComponent:631 调用。
require("entityreplica")
--Additional initialization for network entity replicas
--Additional initialization for network entity replicas
--defines: EntityScript:ValidateReplicaComponent(name)
--defines: EntityScript:ValidateReplicaComponent(name)
--         EntityScript:ReplicateComponent(name)
--         EntityScript:ReplicateComponent(name)
--         EntityScript:UnreplicateEntity(name)
--         EntityScript:UnreplicateEntity(name)
--         EntityScript:PrereplicateEntity(name)
--         EntityScript:PrereplicateEntity(name)
--         EntityScript:ReplicateEntity()
--         EntityScript:ReplicateEntity()
--【注意 602 行的 ReplicateEntity() 与 598-601 的 (name) 版本不匹配】
--   ⚠ 疑似缺陷：602 行写作 UnreplicateEntity(name) 但实体replica.lua 中
--     实际提供的方法名是 UnreplicateComponent。
--     推理依据：注释里写 ReplicateEntity() 无参数，而 entityreplica.lua 里
--     定义的是 ReplicateComponent(name)。这行注释显然没跟上重构。
--     纯注释错误，不影响运行，但会误导后来者。

--【同样用副作用混入】componentactions.lua 为每个组件生成 action 定义，
--   带来：RegisterComponentActions / UnregisterComponentActions /
--            CollectActions / IsActionValid。
--★★ 参见 componentactions.lua 的 RegisterComponentActions
--   —— 由本文件 AddComponent:643 调用、RemoveComponent:661 撤销。
require("componentactions")
--defines: EntityScript:RegisterComponentActions(name)
--defines: EntityScript:RegisterComponentActions(name)
--         EntityScript:UnregisterComponentActions(name)
--         EntityScript:UnregisterComponentActions(name)
--         EntityScript:CollectActions(type, ...)
--         EntityScript:CollectActions(type, ...)
--         EntityScript:IsActionValid(action, right)
--         EntityScript:IsActionValid(action, right)

--★★★ AddComponent —— 组件装配的唯一入口
--【为什么组件要「动态安装」而不是「静态继承」】
--   ① 内存：DST 世界里可能有 5 万个实体，只有 1% 有 health 组件。
--      静态继承意味着每个实体都背上所有方法的查找开销。
--   ② 组合优于继承：一个「会飞的牛」= flyable + beefalo，
--      用组合只需两行，不需要 100 个类。
--   ③ 行为可插拔：mod 可以给任意实体追加组件。
--【执行流水线 —— 顺序极其重要】见各行注释。
function EntityScript:AddComponent(name)
--【★ 全小写化：大小写不敏感去重的第一步】
--   这是 218 行 lower_components_shadow 的核心用法。
--【★ 为什么 lower 在这里而不是在 SetPrefabName 等处统一处理？】
--   因为组件名来源不可控：prefab 脚本写死、模组传入、配置文件读取。
--   ★ 只能在唯一的收口点（AddComponent）做归一化。
    local lower_name = string.lower(name)
--★★ 重复安装检测 —— 三种结局
--   情况A：正常重复调用（同一名字大小写也相同）→ 返回已有实例
--   情况B：大小写不同（Health vs health）→ 遍历找到真实实例并返回
--   情况C：影子表说有、components 里找不到 → 返回 nil（下方 623 行）
    if self.lower_components_shadow[lower_name] ~= nil then
--【★ 用 print 而非 error —— 显式记录但不让游戏崩溃】
--   ★ debugstack_oneline(3) 打印的是**调用栈**而非调用者信息，
--     所以看不出是谁调来的。这在排查「mod 重复加组件」时是个遗憾。
--   更好的做法是 debugstack_oneline(3) 的实际语义需要确认——
--     若它返回的是「从第3 层往上的栈文本」，仍有定位价值。
--   ⚠ 疑似缺陷：返回 nil 而不是 error，调用方若不判空会在后续解引用处崩溃，
--     报错信息与真正的根因（重复添加）相隔很远。
        print("component "..name.." already exists on entity "..tostring(self).."!"..debugstack_oneline(3))
--【★ 情况B 的兜底查找：忽略大小写遍历】
--   影子表有记录但按原名取不到 → 说明历史上有过大小写不一致的安装。
--   这段线性查找是为了兼容这类「已被模组弄脏」的实体，
--   代价是仅在异常路径执行。
		local existingcmp = self.components[lower_name]
		if existingcmp == nil then
			for k, v in pairs(self.components) do
				if string.lower(k) == lower_name then
					existingcmp = v
					break
				end
			end
--【兜底遍历结束】
		end
--【★ 情况C：返回 nil 是「诚实」的失败】
--   宁可不返回错误的组件实例，也不返回 nil 之外的错误对象。
		return existingcmp
--【end：重复安装检测】
    end
--【空行】

--【LoadComponent：懒加载 + 猴补 worldstate 方法】见 52 行详解。
    local cmp = LoadComponent(name)
--【★ 显式 error】与 613 行的 print 形成鲜明对比：
--   「装了个不存在的组件」是脚本 bug，必须立刻炸出来；
--   「装了两次」可能是模组的合理行为，只记日志。
--   —— 错误处理策略的经典分层。
	if not cmp then
	    error("component ".. name .. " does not exist!")
	end

--★★ 步骤①：安装网络副本（在构造组件之前！）
--   ★ 为什么先做这步？ReplicateComponent 内部会 AddTag("_"..name)，
--     而 ValidateReplicaComponent 靠这个标签决定副本是否可见。
--   ★ 顺序要求：必须在 cmp(self) 之前，因为组件构造函数里
--     可能就会访问 self.replica.xxx（很常见）。
--   详见 entityreplica.lua:34 的 ReplicateComponent。
--【★ ReplicateComponent 在构造之前调用的完整推理】
--   ReplicateComponent 内部（entityreplica.lua:39）执行：
--     self:AddTag("_"..name)
--     rawset(self.replica._, name, cmp(self))   ← 这里就构造了副本！
--   ★★ 所以副本组件在主组件构造之前就已经存在了。
--     这不是 bug 而是有意：副本只依赖标签与网络，
--     不依赖主组件的构造结果。
--   ★ 副作用：副本组件的构造器里访问 self.components[自己的名字] 会拿到 nil。
--★★ 参见 entityreplica.lua:41 AddTag('_'..name) 与 :46 rawset
--   —— 说明副本组件在主组件构造前就已创建。
    self:ReplicateComponent(name)
--【★ 组件构造前的准备完毕】

--【★ 步骤②：构造组件实例】
--   cmp(self) 调用组件类的构造器，签名 function(component, inst)。
--   组件在自己的构造器里做初始化（加标签、装子组件、注册更新等）。
   --   ★ 构造器里可以访问 self.components —— 但此时新组件**尚未**登记进去，
--     所以构造器内不要依赖 self.components[自己的名字]。
    local loadedcmp = cmp(self)
--【★ 步骤③：登记到两张表】
--   components[name] —— 用**原始大小写**作键（保持脚本可读性）
--   lower_components_shadow[小写] —— 用小写作影子键（保证去重）
--   ★ 这个「双键」设计解释了为什么 AddComponent:616 还需要兜底遍历：
--     因为真正存进 components 的键可能是任意大小写。
    self.components[name] = loadedcmp
    self.lower_components_shadow[lower_name] = true
--【★ 两张表登记完毕】

--【★ 步骤④：模组后初始化钩子】
--   ModManager:GetPostInitFns("ComponentPostInit", name) 收集所有模组为该组件
--   注册的后初始化函数，按注册顺序依次调用。
--   ★ 语义：组件「构造完成」之后、动作注册之前。
--     模组在这里可以安全地读组件状态、改属性。
--   ★ 为什么放在构造后？某些组件构造后字段才齐备（如 locomotor 需要 inst.Transform）。
--   ⚠ 执行顺序依赖模组的加载顺序，若模组之间有依赖需谨慎。
    local postinitfns = ModManager:GetPostInitFns("ComponentPostInit", name)
--【★ 收集模组后初始化钩子】

    for _, fn in ipairs(postinitfns) do
        fn(loadedcmp, self)
--【end：模组钩子循环】
    end
--【空行】

--【★ 步骤⑤：注册组件动作】
--   让该组件定义的 action（如 chop、mine）在选中此实体时被收集到。
--   ★ 必须最后一步：动作收集要读组件的完整状态。
--   详见 componentactions.lua。
--★★ 参见 componentactions.lua:RegisterComponentActions(name)
--   必须在组件构造与模组钩子之后调用，否则读不到完整状态。
    self:RegisterComponentActions(name)
--【★ 动作注册在本函数最后一步】

--【★ 返回实例】调用方写法：local h = inst:AddComponent("health")
	return loadedcmp
end
--【空行】

--★★★ RemoveComponent —— 动态组件的拆卸
--【★ 清理顺序是本函数的核心，逐行解释见下】
--   ★ 值得注意：本函数没有调用组件的 OnRemoveFromEntity 之外的任何钩子，
--     也没有处理 worldstate 观察者、事件监听 —— 
--     这些全部依赖 EntityScript:Remove 的整体清理（1705 行）。
--   ⚠ 重要含义：单独调RemoveComponent 并不会自动注销该组件注册的
--     worldstate watcher 或事件监听。热插拔组件的代码需自行处理。
--【★ RemoveComponent 开始】
function EntityScript:RemoveComponent(name)
--【★ 用原始 name 取组件】
--   ⚠ 疑似缺陷：这里没有做大小写不敏感处理，与 AddComponent:611 不对称。
--     若组件是 AddComponent("Health") 装的，RemoveComponent("health") 会取不到，
--     静默失败—— 调用方以为卸载了，实际还在。
--     修复思路：复用 AddComponent:616 的兜底查找逻辑。
    local cmp = self.components[name]
--【★ 组件存在才继续】
    if cmp then
--【★ 清理顺序第①步：停止普通更新】
--   用的是**延迟版**（StopUpdatingComponent），不是 _Deferred。
--   ★ 正确性论证：如果这里用 _Deferred（当场删表），
--     而本函数正是在某个组件的 OnUpdate 中被调用的话，
--     就会在 update.lua:259 的遍历中删表。延迟版恰好规避了这个风险。
        self:StopUpdatingComponent(cmp)
--【★ 清理顺序第②步：停止 wall 更新】
--   ★ 这里用的是立即版 StopWallUpdatingComponent（527行），
--     与上一步不对称。理由推测：wallupdate 组件极少被动态移除，风险可控。
--   ⚠ 这是一处真实的风格/正确性不一致，值得统一。
        self:StopWallUpdatingComponent(cmp)
--【★ 清理顺序第③步：先从表里摘除】
--   ★ 顺序要点：先摘表，再回调 OnRemoveFromEntity。
--     这样回调里若再遍历 self.components，已经看不到自己 ——
--     避免了「回调中访问一个半拆卸状态的组件」。
        self.components[name] = nil
--【★ 影子表同步清理：与 AddComponent:635 对称】
        self.lower_components_shadow[string.lower(name)] = nil

--【★ 清理顺序第④步：通知组件自己收尾】
--   典型收尾工作：停线程、停协程、移除标签、注销更新。
--   ★ 此时组件已不在 self.components 里，所以回调里不能再用 self.components[name]。
--   ⚠ 但可以把自己传进来的引用继续用（cmp 变量仍在作用域内）。
        if cmp.OnRemoveFromEntity then
            cmp:OnRemoveFromEntity()
        end
--【★ 回调执行完毕：此时 cmp 已不在 self.components 里】

--【★ 清理顺序第⑤步：撤销网络副本】
--   UnreplicateComponent 会 RemoveTag("_"..name) 并从 replica._ 移除，
--   于是 self.replica.xxx 立即返回 nil —— 无需等待网络同步。
--★★ 参见 entityreplica.lua 的 UnreplicateComponent
--   —— 撤销副本与 '_' 标签，使 self.replica.xxx 立即返回 nil。
        self:UnreplicateComponent(name)
--【★ 清理顺序第⑥步：注销动作】
--   ★ 放在最后：与 AddComponent:643 完全反向对应。
--     注册是「构造→ 副本 → 钩子 → 动作」，注销是它的严格镜像。
        self:UnregisterComponentActions(name)
--【★ 注销动作：与 AddComponent:643 对称】
    end
end
--★ 组件完整生命周期回顾：
--   AddComponent: LoadComponent → ReplicateComponent → cmp(self) → 登记 →
--                ModPostInit → RegisterComponentActions
--   RemoveComponent: StopUpdating → StopWallUpdating → 摘表 →
--                  OnRemoveFromEntity → UnreplicateComponent →
--                  UnregisterComponentActions
--   ★ 两个函数的步骤严格逆序，且★缺失「worldstate 观察者」与
--     「事件监听」的清理 —— 这两项只能靠 EntityScript:Remove 整体处理。
--【空行】

--★★ GetBasicDisplayName：名字解析的四级回退链
--【★ 回退顺序（第一个非 nil 即胜出）】
--   ① displaynamefn     —— prefab 自定义函数（最高优先级）
--   ② nameoverride     —— SetPrefabNameOverride 指定的名字（走 STRINGS.NAMES）
--   ③ name_author_netid—— 玩家命名物品，按作者 netid 做文本过滤
--   ④ self.name        —— 最终回退到 pretab 名
--   ★ 这个顺序把「mod 的完全控制权」放在最前，
--     而「玩家命名」只比默认值高一级—— 这样玩家的自定义名不会被莫名覆盖。
function EntityScript:GetBasicDisplayName()
--【★ 四级回退用 or 串联，一行完成】
    return (self.displaynamefn ~= nil and self:displaynamefn())
--【★ nameoverride 走 STRINGS.NAMES 查表】
        or (self.nameoverride ~= nil and STRINGS.NAMES[string.upper(self.nameoverride)])
--★ 原注释承认这个上下文常量用得不准确（更像 NAME 而非 CHAT），
--  但因为「所有玩家输入（如给牛牛起名）」都走这里，只能统一用更严格的 CHAT。
--  ★ 这是「安全优先于精确」的取舍：宁可过滤得更狠，不可漏过滤。
		or (self.name_author_netid ~= nil and ApplyLocalWordFilter(self.name, TEXT_FILTER_CTX_CHAT, self.name_author_netid)) -- this is more lika a TEXT_FILTER_CTX_NAME but its all user input (eg, naming a beefalo) so lets go with TEXT_FILTER_CTX_CHAT
        or self.name
end
--【空行】

--★★ GetAdjectivedName：状态形容词修饰 —— 游戏最讨喜的设计之一
--【★ 设计目标】物品名由「基础名 + 状态修饰」拼成，如：
--     "湿的 火把" / "腐烂的 浆果" / "破的 草" / "凋零的 眼骨"
--   玩家一眼就能从名字看出状态，不必打开物品栏。
--【★ if/elseif 链的顺序 = 优先级】从上到下：
--   1. 玩家       → 永不加形容词（不能叫「湿的玩家」）
--   2. smoldering → 燃烧中
--   3. diseased   →  diseased
--   4. rotten     → 变质
--   5. withered   → 枯萎
--   6. waxed plant→ 上蜡（★ 例外：不加「湿」前缀）
--   7. 湿前缀分支（下面详述）
--   8. broken / deadcreature（非湿时的单独处理）
--   ★ 顺序即语义：越「特殊」的状态越靠前，因为一个物品通常只处于一种特殊状态。
function EntityScript:GetAdjectivedName()
--【★ 先取基础名】
    local name = self:GetBasicDisplayName()
--【★ 形容词链开始】

--【★ 优先级①：玩家不加形容词】
    if self:HasTag("player") then
        --No adjectives for players
--【★ 玩家分支直接返回】
        return name
    elseif self:HasTag("smolder") then
        return ConstructAdjectivedName(self, name, STRINGS.SMOLDERINGITEM)
    elseif self:HasTag("diseased") then
        return ConstructAdjectivedName(self, name, STRINGS.DISEASEDITEM)
    elseif self:HasTag("rotten") then
        return ConstructAdjectivedName(self, name, STRINGS.UI.HUD.SPOILED)
    elseif self:HasTag("withered") then
--【★ 优先级⑤：枯萎】
        return ConstructAdjectivedName(self, name, STRINGS.WITHEREDITEM)
--【★ 蜡化植物特例】注释明说 "No wet prefix for waxed plants."
--   理由：蜡化植物会被雨淋坏，若同时是湿的会产生矛盾描述。
--   ★ 典型的「文案一致性」需求 —— 说明 Klei 非常在意描述的自洽。
    elseif self:HasTag("waxedplant") then
--【★ 蜡化植物特例】
        -- No wet prefix for waxed plants.
        return ConstructAdjectivedName(self, name, STRINGS.WAXEDPLANT)
--★★ 湿前缀分支 —— 三重条件（4 个 and 连接）
--   not self.no_wet_prefix  —— prefab 可以整体禁用湿前缀
--   and (self.always_wet_prefix or self:GetIsWet())
--     ★ always_wet_prefix 让「永远湿的」实体（如水母、水瓶）强制走这条路径；
--     ★ GetIsWet() 是客户端可用的版本（见 770 行）。
--   这一整块是 else-if 链的一部分，失败会落到 726 行的 broken 检查。
    elseif not self.no_wet_prefix and (self.always_wet_prefix or self:GetIsWet()) then
--【★ 湿前缀的细分逻辑】
        --custom
        if self.wet_prefix ~= nil then
            return ConstructAdjectivedName(self, name, self.wet_prefix)
--【★ 装备槽位分支】
        end
        --equippable
--【★ 装备类物品：按装备槽位决定前缀】
--   ★ 注意访问的是 self.replica.equippable 而不是 components.equippable——
--     因为 GetAdjectivedName 需要在客户端也能跑（客户端没有 components）。
--   HANDS       → "湿的 斧头"（工具前缀）
--   HEAD / BODY → "湿的 帽子"（衣物前缀）
--   ★ 这是「按用途而非按类型命名」的设计：玩家关心的是「能不能用」，不是「是什么」。
        local equippable = self.replica.equippable
        if equippable ~= nil then
            local eslot = equippable:EquipSlot()
            if eslot == EQUIPSLOTS.HANDS then
--【★ 工具前缀】
                return ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.TOOL)
            elseif eslot == EQUIPSLOTS.HEAD or eslot == EQUIPSLOTS.BODY then
--【★ 衣物前缀】
                return ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.CLOTHING)
            end
--【★ 装备槽位分支结束】
        end
        --edible
--【★ 可食用：遍历 FOODTYPE 拼标签】
--   因为食物类型是标签编码的（edible_meat / edible_vegetable），
--   没有集中的表，只能遍历常量表反向拼。
--   ⚠ 性能：FOODTYPE 有若干项，每项一次 HasTag（FFI 调用）。
--     在「遍历背包所有物品生成名字」的 UI 路径上会被放大 N倍。
--     建议后续优化时给 EntityScript 加一个「湿状态缓存字段」由变动时更新。
        for _, v in pairs(FOODTYPE) do
            if self:HasTag("edible_"..v) then
                return ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.FOOD)
            end
--【★ 食物前缀分支】
        end
        --fuel
--【燃料：标签是 <type>_fuel 的形式】同样是标签编码，反向拼常量表。
        for _, v in pairs(FUELTYPE) do
            if self:HasTag(v.."_fuel") then
                return ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.FUEL)
            end
--【★ 燃料前缀分支】
        end
		--broken
--【★ 双重形容词：湿 + 破】
--   ConstructAdjectivedName 嵌套调用 → "湿的 破 草"。
--   ★ 之所以要嵌套而非拼接字符串，是因为 ConstructAdjectivedName 会处理
--     本地化语言的语序（在某些语言里形容词在名词之后）。
--   ★ 这是「不要用字符串拼接做本地化」的正面例子。
		if self:HasTag("broken") then
			return ConstructAdjectivedName(self, ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.GENERIC), STRINGS.BROKENITEM)
--【★ 双重形容词：湿 + 破】
		end
        --dead creatures
		if self:HasTag("deadcreature") then
			return ConstructAdjectivedName(self, ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.GENERIC), STRINGS.DEADCREATURE)
--【★ 双重形容词：湿 + 尸体】
		end
        --generic
--【★ 通用湿前缀（兜底）】
        return ConstructAdjectivedName(self, name, STRINGS.WET_PREFIX.GENERIC)
--【★ 非湿情况下的单独处理】
--   注意这里是 else-if 链的尾巴，只有「不湿」时才会到达。
--   ★ 与 717 行的湿+破 形成对称：湿且破 → 双重；不湿但破 → 单个。
	elseif self:HasTag("broken") then
		return ConstructAdjectivedName(self, name, STRINGS.BROKENITEM)
    elseif self:HasTag("deadcreature") then
        return ConstructAdjectivedName(self, name, STRINGS.DEADCREATURE)
--【★ 形容词链全部条件结束】
    end

--【★ 全部不命中：返回基础名】
    return name
--【GetAdjectivedName 结束】
end
--【空行】

--【★ GetDisplayName = GetAdjectivedName + prefab 专属描述】
--   NAME_DETAIL_EXTENTION 提供 tooltip 里的补充说明（如「能点燃的树枝」）。
--   ★ 用 "\n" 而非 " " 分隔：物品 tooltip 是多行布局，
--     名字与描述各占一行是既定的UI 约定。
function EntityScript:GetDisplayName()
    local name = self:GetAdjectivedName()
--【★ prefab 专属描述查找】

    if self.prefab ~= nil then
        local name_extention = STRINGS.NAME_DETAIL_EXTENTION[string.upper(self.prefab)]
        if name_extention ~= nil then
            return name.."\n"..name_extention
        end
    end
--★ 没有匹配到扩展说明时只返回名字——tooltip 仍能正常显示。
    return name
end
--【空行】

--Can NOT be used on clients
--Can NOT be used on clients
--★★ GetWetMultiplier：湿润度倍率 —— 服务端权威计算
--【★ 为什么要分成「服务端版」与「客户端版」两个函数？】
--   GetWetMultiplier（服务端）：能拿到 components，读真实组件状态，
--                            还能返回连续值（0~1 的湿度百分比）。
--   GetIsWet（客户端）：只能用 replica，返回布尔。
--   ★ 因为服务端需要精确湿度做燃烧/导电判定，客户端只需要「亮不亮图标」。
--【本函数的五级回退】
--   ① wet 标签               → 1（强制湿）
--   ② moistureimmunity 标签  → 0（免疫）
--   ③ components.inventoryitem → 读物品自身的湿度
--   ④ components.temp_moisture / moisture → 读组件的湿度百分比（连续值）
--   ⑤ 兜底：世界是否在下雨 / 是否在游泳
function EntityScript:GetWetMultiplier()
	if self:HasTag("wet") then
--【★ 强制湿 → 倍率 1】
		return 1
	elseif self:HasTag("moistureimmunity") then
--【★ 免疫湿 → 倍率 0】
        return 0
--★ 原注释坦承了这个「为了保持旧行为一致」的妥协：
--   InventoryItem 组件其实能给出湿度百分比，但这里只返回 0/1 布尔，
--   以免改变既有判定结果。
--   ★ 这类注释记录了「为什么明知有更好方案却不改」—— 极有价值的知识。
	elseif self.components.inventoryitem then --Inventoryitemmoisture can give us percent, but keep it consistent with how it was before, for now......
        return self.components.inventoryitem:IsWet() and 1 or 0
--【★ 走到这里说明没装 inventoryitem，跳过】
	end
--【end：inventoryitem 分支】

--【★ 注释里被划掉的那行是关键】
--   local moisture = self.components.temp_moisture or self.components.moisture --or self.components.inventoryitem
--   曾经想把 inventoryitem 也纳入，但那样会改变行为（见上），故注释掉。
--   ★ 保留「历史方案」在注释里，是重构时的安全网。
	local moisture = self.components.temp_moisture or self.components.moisture --or self.components.inventoryitem 
	if moisture then
--【返回连续湿度百分比】0.3 表示 30% 湿度。
--   ★ 这就是本函数与 GetIsWet 的本质区别：一个是连续量，一个是布尔。
        return moisture:GetMoisturePercent()
    else
--【★ 未装任何湿度组件 → 走兜底表达式】
        return
--★★ 兜底分支用了一个极其别扭的写法：
--     return ( A or B ) and 1 or 0
--   ★ 拆解：`(TheWorld.state.iswet and not rainimmunity) or (swimming and not duck)`
--     先算出「是否湿」的布尔，再转成 0/1。
--   ⚠ 可读性差：多对括号容易看错。建议写成局部变量再判断。
--   ★ 之所以要分开写而不是合并：两个条件要访问不同的组件（none 存在时只能用标签）。
        (
			(TheWorld.state.iswet and not self:HasTag("rainimmunity")) or
			(self:HasTag("swimming") and not self:HasTag("likewateroffducksback"))
        ) and 1 or 0
--【★ 兜底表达式结束】
    end
end
--【空行】

--Can be used on clients
--Can be used on clients
--★★ GetIsWet：客户端安全的布尔版
--【★ 与服务端版的对照 —— 这是理解 DST 双端模型的绝佳样本】
--   服务端：self.components.temp_moisture:GetMoisturePercent()
--   客户端：self.replica.inventoryitem 或 self.replica.moisture
--   ★ 关键：客户端**没有** components 表（组件含服务端逻辑与状态），
--     只能读 replica。这就是「replica 机制」存在的根本原因。
--   ★ 客户端也不需要 5 级回退的完整精度，二元判断足够驱动 UI。
function EntityScript:GetIsWet()
	if self:HasTag("wet") then
		return true
	elseif self:HasTag("moistureimmunity") then
--【★ 客户端版的两个提前返回】
        return false
    end

--【★ replica 的自动校验在这里体现了价值】
--   inventoryitem 或 moisture 都没有时返回 nil，调用方判空即可。
--   若用传统写法，需要先 HasTag 判断再索引，样板代码多三倍。
    local replica = self.replica.inventoryitem or self.replica.moisture
    if replica then
        return replica:IsWet()
--【★ replica 分支：有副本就问副本】
    else
		return (TheWorld.state.iswet and not self:HasTag("rainimmunity"))
            or (self:HasTag("swimming") and not self:HasTag("likewateroffducksback"))
--【★ 客户端兜底：只看世界与标签】
    end
--【GetIsWet 结束】
end
--【空行：客户端可用标记】
--Can be used on clients
--【★ IsAcidSizzling：酸雨腐蚀 —— 两级特殊处理】
--   ① acidrainimmune 标签 → 直接免疫
--   ② 有 inventoryitem 副本 → 问物品自己（物品可能自带抗性）
--   ③ 玩家专属：读 player_classified 的网络变量
--   ④ 都没有 → false
--   ★ 第③级值得注意：这是给玩家的特殊通道，因为「玩家正在被酸雨淋」
--     这个状态存在 player_classified（网络同步的分类组件）里。
function EntityScript:IsAcidSizzling()
    if self:HasTag("acidrainimmune") then
        return false
    end
--【★ 无 inventoryitem 副本 → 走玩家专用通道】

    local replica = self.replica.inventoryitem
    if replica ~= nil then
        return replica:IsAcidSizzling()
    end

--【player_classified：只在玩家实体上存在的组件】
--   ★ 「classified」意为「给旁观者看的状态」，只同步给相关客户端。
--     是DST 网络分层（replica vs classified vs private）的一个实例。
    local player_classified = self.player_classified
    if player_classified ~= nil then
--【:value() 解包网络变量】网络变量的值需要显式取出，不是直接索引。
        return player_classified.isacidsizzling:value()
    end

--【★ 都不是 → 不在酸雨中】
    return false
--【IsAcidSizzling 结束】
end
--【空行】

--【★ 皮肤 build 名缓存】
--   GetBuildForItem(self.skinname) 是一次表查找 + 字符串处理，开销不小。
--   ★ 但 GetSkinBuild 会在「显示名字」时被调用，而命名是高频路径
--     （背包每帧重绘都要给所有物品取名）。缓存是必需的。
--   ★ 用 `or` 惰性求值：第一次调用才真正计算。
function EntityScript:GetSkinBuild()
    -- We cache the build name so we don't need to search for it in the item tables.
    self.skin_build_name = self.skin_build_name or GetBuildForItem(self.skinname)
    return self.skin_build_name
end
--【空行】

--【★ 两级皮肤名：override 优先】
--   override_skinname 用于「物品被染色/幻化但prefab 不变」的场景。
--   ★ 两者都要支持是因为：override 只改外观不改 prefab，而
--     skinname 本身是与 prefab 绑定的存档字段（见 308 行）。
function EntityScript:GetSkinName()
    return self.override_skinname or self.skinname
end
--【空行】

--★ SetPrefabName 同时更新 Lua 与 C++ 两侧。
--   C++ 侧需要它来做资源加载与网络标识。
--   ★ `self.name = self.name or (...)` 保证「已有名字不被prefab 名覆盖」——
--     这让玩家命名的物品在重载后保留名字。
function EntityScript:SetPrefabName(name)
    self.prefab = name
--【★ C++ 侧同步改名】
    self.entity:SetPrefabName(name)
--【★ 三级名字回退】预制名 → 大写查 STRINGS → "MISSING NAME"。
--   ★ "MISSING NAME" 是显式的失败信号：一眼看出是预制表缺条目，
--     而不是显示空白或崩溃。
--   ★ 用 string.upper 查表：让 STRINGS 的键统一大写，避免大小写不一致。
    self.name = self.name or (STRINGS.NAMES[string.upper(self.prefab)] or "MISSING NAME")
end
--【空行】

--★★ SetPrefabNameOverride：借用另一个prefab 的名字与描述
--【★ 典型用例（注释给了）】spiderhole_rock 借用 spiderhole 的名字。
--   即「洞里的石头」显示为「蜘蛛洞穴」，因为玩家看到的是同一个地标。
--【★ 与SetPrefabName 的关键区别】
--   它**不改** prefab 本身，也不调 entity:SetPrefabName ——
--   所以存档、资源加载、物品图标全部仍用真prefab。
--   纯显示层覆盖，零副作用。
--   ★ 在 665 行 GetBasicDisplayName 中优先级仅次于 displaynamefn。
function EntityScript:SetPrefabNameOverride(nameoverride)
    --Changes what description and name will show for the prefab without actually overriding the prefab itself.
    --nameoverride should be the prefab that you wish to use for name and description. (IE: "spiderhole_rock" uses "spiderhole")
    self.nameoverride = nameoverride
end
--【空行】

--★ 部署间距系列（826–868）：三个 Set*Spacing/Radius 函数共用同一套范式。
--  【共同范式】
--    ① 在实体上记一个字段，供其它系统查询
--    ② 若值为 nil → 移除对应标签并注销
--    若值非 nil → 加上标签并向 TheWorld.Map 注册
--  【为什么要向全局注册？】
--    因为「放置新实体时的间距校验」发生在玩家的光标处，
--    那里可能站着几十个候选阻挡物，需要一次性查询所有相关实体。
--    分散查询需要遍历 Ents（可能上万个），全局注册则只需查一张表。
--    ★ 这与 entityreplica 的「集中式分发」是同一种架构思路。
--  【三个函数的一致性检查】
--    SetDeployExtraSpacing    — 部署时对其他实体的额外间距
--    SetDeploySmartRadius     — 部署时考虑双方半径
--    SetTerraformExtraSpacing — 地形编辑时的阻挡
--    SetGroundTargetBlockerRadius — 地表点击阻挡
--    ★ 最后一个在 858 行，共四个。注释原文说 "cannot be terraformed"
--      在 847 与 859 行重复出现且完全一样，是复制粘贴残留，
--      SetGroundTargetBlockerRadius 应说的是 "cannot be a ground target"。
--      ⚠ 疑似缺陷（文档层面）：误导性注释，建议修正。
function EntityScript:SetDeployExtraSpacing(spacing)
    --Extra spacing required when deploying other entities near this one.
    --Extra spacing required when deploying other entities near this one.
--【★ 记字段供查询】
    self.deploy_extra_spacing = spacing
    if spacing ~= nil then
        --see components/map.lua
        --see components/map.lua
--【★ 注册到全局地图系统】components/map.lua 是唯一消费者。
--   详见 map.lua 的 RegisterDeployExtraSpacing。
--★★ 参见 components/map.lua RegisterDeployExtraSpacing
--   —— 本行注释已指明「see components/map.lua」。
        TheWorld.Map:RegisterDeployExtraSpacing(spacing)
--【★ 注册到地图全局】
    end
end
--【空行】

--【★ SmartRadius 与ExtraSpacing 的本质区别】
--   ExtraSpacing 是「我单方面声明我的排斥半径」；
--   SmartRadius 是「用我的半径参与双向计算」——注释明说：
--   "will calculate spacing using our radius and the radii of entities near me too"
--   ★ 且注释指出：传统 legacy 部署间距「一般不考虑其他实体的大小」，
--     除非对方也声明了 deploy_extra_spacing。
--   —— 这是「新旧两套系统并存」的典型痕迹。
function EntityScript:SetDeploySmartRadius(radius)
	--Smart radius will calculate spacing using our radius and the radii of entities near me as well.
	--NOTE: legacy deplay spacing generally does not care about size of other entities,
	--      unless those entities specify deploy_extra_spacing.
	self.deploy_smart_radius = radius
--【★ 智能半径的注册】
	if radius then
        --see components/map.lua
		--see components/map.lua
--★★ 参见 components/map.lua RegisterDeploySmartRadius
		TheWorld.Map:RegisterDeploySmartRadius(radius)
	end
end
--【空行】

--【terraformblocker 标签】与间距值绑定：非 nil 时加，nil 时去。
--   ★ 标签是给C++/UI 快速查询用的（快速跳过不可编辑地形）。
function EntityScript:SetTerraformExtraSpacing(spacing)
    --Extra spacing around entity that connot be terraformed.
    self.terraform_extra_spacing = spacing
--【★ 非 nil 时打标签】
    if spacing ~= nil then
--【★ terraformblocker：供 C++/UI 快速查询】
        self:AddTag("terraformblocker")
        --see components/map.lua
--★★ 参见 components/map.lua RegisterTerraformExtraSpacing
        TheWorld.Map:RegisterTerraformExtraSpacing(spacing)
    else
        self:RemoveTag("terraformblocker")
--【★ nil 时撤销标签】
    end
end
--【空行】

--【★ 第三类阻挡：地表目标阻挡】
--   与 terraformblocker 的区别：
--     terraformblocker  阻挡「地形编辑」（锄地、放树）
--     groundtargetblocker 阻挡「地表交互目标」（点地面放东西）
--   ★ 例如「蜂巢」「蜘蛛洞穴」这类需要地面有空地的结构会声明它。
function EntityScript:SetGroundTargetBlockerRadius(radius)
    --Extra spacing around entity that connot be terraformed.
    self.ground_target_blocker_radius = radius
--【★ 非 nil 时打 groundtargetblocker】
    if radius ~= nil then
        self:AddTag("groundtargetblocker")
        --see components/map.lua
--★★ 参见 components/map.lua RegisterGroundTargetBlocker
        TheWorld.Map:RegisterGroundTargetBlocker(radius)
    else
        self:RemoveTag("groundtargetblocker")
--【★ nil 时撤销标签】
    end
end
--【空行】

--★★★ 子实体与平台跟随（870–950）：两套独立的从属关系★★★
--【为什么要分成「父子」与「平台跟随」两套？】
--   语义完全不同：
--     parent（父子）：子实体的坐标**真的**挂在父实体上。
--                    父动子动，父转子转。用于「牛的背上站着乘客」。
--     platform（平台）：子实体坐标独立，只是每帧被平台的位置带动。
--                       用于「船上的货物」——货物可以自由走动、独立碰撞。
--   ★ 若混用，会出现「货物被焊死」或「乘客不受船运动影响」的错误。
--【数据结构对照】
--   self.children          = { [子EntityScript] = true }
--   self.platformfollowers = { [跟EntityScript] = true }
--   子实体侧：child.parent = 父 / child.platform = 平台
--   ★ 两侧都记一份，是为了能在子实体上直接回答「我的父/平台是谁」，
--     且让移除操作能O(1) 定位（见 RemoveChild:888 直接 child.parent = nil）。
function EntityScript:SpawnChild(name)
--【★ 双形态子实体：具名 vs 直接 prefab 名】
--   若 self.prefabs 存在（本实体定义过子实体表），则 name 是表里的**键**；
--   否则 name 直接当作 prefab 名。
--   典型：牛的 prefabs = { beefalo = "beefalo" } → SpawnChild("beefalo")
--   ★ 这个「表或直名」的二义性是 DST 的老设计，代价是容易写错。
    if self.prefabs then
--【★ 双重断言：第一层防「表不存在」，第二层防「键不存在」】
--   871 行已经 if self.prefabs 判断，872 行的 assert(self.prefabs) 在逻辑上永真。
--   ⚠ 疑似缺陷：冗余断言，可能是重构后残留。
--     无害但增加了阅读负担——读者会以为它有什么深意。
        assert(self.prefabs, "no prefabs registered for this entity ".. name)
        local prefab = self.prefabs[name]
--【★ 键不存在则断言失败】
        assert(prefab, "Could not spawn unknown child type "..name)
        local inst = SpawnPrefab(prefab)
--【SpawnPrefab 失败的防护】返回的 inst 必须非nil，否则 AddChild(nil) 会崩。
        assert(inst, "Could not spawn prefab "..name.." "..prefab)
        self:AddChild(inst)
        return inst
--【★ else 分支：name 直接当 prefab 名】
    else
        local inst = SpawnPrefab(name)
        self:AddChild(inst)
        return inst
    end

--【空行】
end
--【空行】

--★★ RemoveChild：解除父子关系
--【★ 清理顺序】先断子侧指针 → 再断父侧集合 → 最后通知 C++。
--   顺序要点：child.parent = nil 必须在最前，
--   因为 AddChild:898 会检查 child.parent 来决定是否先调旧父的 RemoveChild，
--   若不先置 nil 会产生递归。
function EntityScript:RemoveChild(child)
--【★ 断子侧指针放最前：防AddChild 的递归】
    child.parent = nil
    if self.children then
        self.children[child] = nil
--【★ 断父侧集合（可能为 nil，故先判）】
    end
--【SetParent(nil) 通知 C++ 侧】
--   ★ C++ 侧的父子关系驱动坐标继承与网络同步，
--     所以 Lua 的 child.parent = nil 只是记账，真正生效的是这一句。
    child.entity:SetParent(nil)
end
--【空行】

--★★ AddChild：建立父子关系
--【★ 三条不变量】
--   ① child.platform = nil —— ★ 加为子实体时脱离原平台。
--     一个人不能同时既挂在父实体上又站在平台上。
   --   ② if child.parent then child.parent:RemoveChild(child) end
--     —— 先从旧父摘除。★ 这里不判重入：若 child.parent 已是 self，
   --     会先RemoveChild 再重新Add，net 结果正确但多做了无用功，
   --     且若 RemoveChild 有副作用（如发事件）会造成「短暂脱离」。
   --   ③ 懒建 children 表（保持 nil 语义，省内存）。
function EntityScript:AddChild(child)
--【★ 脱离原平台：不能既是子又是乘客】
    child.platform = nil
--【空行】

    if child.parent then
        child.parent:RemoveChild(child)
    end
--【★ 从旧父摘除（重入安全但有多余副作用）】

--【★ 建立新父子关系】
    child.parent = self
--【★ 懒建 children 表】
    if not self.children then
        self.children = {}
--【★ children 存 true 而非 child 本身】
    end

--【★ 用 child 作键 → 反查 O(1)】
    self.children[child] = true
--【★ SetParent(self.entity) 才真正建立父子变换关系】
--   self.children[child]=true 只是 Lua 侧索引。
   --   ★ 对称性保证：AddChild 与 RemoveChild 必须成对实现，
--     否则 Lua 侧与 C++ 侧的父子关系会不一致（表现为「幽灵挂载」）。
    child.entity:SetParent(self.entity)
end
--【空行】

--★★ RemovePlatformFollower：解除平台跟随
--【★ 首行守卫：不是我的跟随者就直接返回】
--   ★ 这是「幂等 + 安全」的写法：即便误调也不会破坏别人的关系。
--   与 RemoveChild:887 对比——RemoveChild 没有这个守卫，
--     因为 child.parent 必然指向正确对象。
   --   ★ 差别的原因：platform 的解除可能来自多个来源（换船、落地、被拾取），
--     更容易出现「已经不在了还来解绑」的情况。
function EntityScript:RemovePlatformFollower(child)
    if child.platform ~= self then
--【★ 非我的平台直接返回：幂等保护】
        return
    end
--【★ 清 platform 指针】

    child.platform = nil
--【★ 懒建前判空】
    if self.platformfollowers then
        self.platformfollowers[child] = nil
--【★ 从集合移除】
    end
--【★ 通知 C++ 侧脱离平台】
    child.entity:SetPlatform(nil)

--【★ 可覆写的钩子 OnRemovePlatformFollower】
--   预制脚本可覆写此方法来响应「跟随关系解除」。
--   ★ 典型用途：船上乘客落水时播放音效/特效。
--   ★ 注意是 self:OnRemovePlatformFollower(child) 冒号调用，
--     第一个参数会被自动补成 self。
	if self.OnRemovePlatformFollower then
		self:OnRemovePlatformFollower(child)
--【★ 业务钩子：乘客落水等】
	end
--【RemovePlatformFollower 结束】
end
--【空行】

--★★ AddPlatformFollower：建立平台跟随
   --★ 与 AddChild 的三处差异（务必注意）：
--   ① child.parent = nil —— 解除父子关系（方向相反！）
--   ② if child.platform then child.platform:RemovePlatformFollower(child) end
--      —— 从旧平台摘除
--   ③ child.platform = self（AddChild 里是 child.parent = self）
   --   ★ 一句话记忆：AddChild 让子「归属」父，AddPlatformFollower 让子「踩」在平台上。
function EntityScript:AddPlatformFollower(child)
    child.parent = nil
--【★ 与 AddChild 相反：这里解除的是父子关系】

    if child.platform then
        child.platform:RemovePlatformFollower(child)
    end
--【★ 从旧平台摘除】

--【★ 建立平台关系】
    child.platform = self
    if not self.platformfollowers then
        self.platformfollowers = {}
--【★ 懒建 platformfollowers 表】
    end

--【★ 登记为跟随者】
    self.platformfollowers[child] = true
--【★ 通知 C++ 侧站到平台上】
    child.entity:SetPlatform(self.entity)

--【★ 与 RemovePlatformFollower:922 对称的钩子】
--   两侧钩子的存在说明「平台关系」被业务逻辑高度关注（船是核心玩法）。
	if self.OnAddPlatformFollower then
		self:OnAddPlatformFollower(child)
--【★ 业务钩子：上船等】
	end
--【AddPlatformFollower 结束】
end
--【空行】

--only works on master sim
--only works on master sim
--【GetPlatformFollowers：返回平台跟随者集合】
--   ★ 注释警告只能在主模拟（服务端）用：
--     客户端的 platformfollowers 为 nil，且客户端也不需要这个信息。
--   ★ 返回的是内部表本身（不是拷贝）—— 调用方可直接遍历但不应修改。
   --   ⚠ 轻微封装问题：返回内部引用，调用方误改会破坏不变量。
function EntityScript:GetPlatformFollowers()
    return self.platformfollowers
--【GetPlatformFollowers 结束】
end
--【空行】

--【GetBrainString：大脑状态的调试串】
--   ★ 注意格式 "--------\n" 用转义换行而非真实换行，
--     使整个字符串能被 table.concat 成单行日志。
function EntityScript:GetBrainString()
--【★ 调试串数组初始化】
    local str = {}

--【★ 有条件才输出】没配大脑的实体返回空串，不产生无意义的"BRAIN:\n--------"。
    if self.brain then
        table.insert(str, "BRAIN:\n")
        table.insert(str, tostring(self.brain))
--【★ 分隔线用转义换行，保持单行】
        table.insert(str, "--------\n")
    end

--【空行】
    return table.concat(str, "")
end
--【空行】

--★★ GetDebugString：实体的完整状态快照（调试核心工具）
--【★ 注意开头有大约 100 行被注释掉的代码（992–1061）】
--   被禁用的部分：组件列表、事件监听表、pendingtasks 列表。
--   ★ 为什么禁用？它们都是 O(n) 遍历，而 GetDebugString 会被调试菜单高频调用，
--     在有上千组件/监听的实体上会明显卡顿。
--   ★ 保留注释而非删除，是为了在需要深度排查时能临时打开。
--   ⚠ 但注释块里有一处代码错误（见 1003 行的说明），打开前需修正。
--【本函数实际输出的内容】tostring / 睡眠标记 / 年龄 / C++ 调试串 /
--   当前缓冲动作 / StateGraph 状态 / prefab 自定义调试串。
function EntityScript:GetDebugString()
--【★ 无效实体也能出字符串】
--   ★ 关键考虑：**调试工具在实体已崩溃时最需要工作**。
--     若此处直接崩溃，开发者就失去了最后的诊断手段。
    if not self:IsValid() then
        return tostring(self).." <INVALID>"
    end
--【★ 收集中间数组，最后统一 concat】

    local str = {}

    table.insert(str, tostring(self))
--【IsAsleep 标记】睡眠的实体行为异常，调试时第一眼就能确认。
    if self:IsAsleep() then
        table.insert(str, " <ASLEEP>")
--【★ 睡眠标记】
    end
--【★ "%2.2f" 格式：秒数保留两位小数】spawntime 差值，秒为单位。
    table.insert(str, string.format(" age %2.2f", self:GetTimeAlive()))
    table.insert(str, "\n")
--【★ C++ 调试串拼接位置】

--【★ 拼接 C++ 侧调试信息】实体索引、碰撞体、动画状态等都在那边。
--   ★ 这是「跨语言调试信息拼接」的范例：Lua 侧负责高层语义，
--     C++ 侧负责底层细节。
    table.insert(str, self.entity:GetDebugString())
--【空行】

--【★ 缓冲动作永远打印（即使是nil）】
--   「正在等待什么动作」是排查「为什么点击无效」的第一线索。
    table.insert(str, "Buffered Action: "..tostring(self.bufferedaction).."\n")
--【★ 状态图状态】

    if self.sg then
        table.insert(str, "SG:" .. tostring(self.sg).."\n")
    end
--【★ prefab 自定义调试串】

    if self.debugstringfn then
        table.insert(str, "DebugString: "..self:debugstringfn().."\n")
--【★ 自定义部分结束】
    end
--【★ 分隔线：下方是禁用的深度输出】

    table.insert(str, "-----------\n")
--【★ 以下所有代码已被注释禁用，见各段说明】

--★★ 下面三大段是已禁用的深度调试输出，逐段说明其意图：
--第1 段（992–1003）：组件列表 + 各组件的 GetDebugString
--   意图：打印每个组件的调试串（health 会输出当前生命等）。
    ----[[
    local cmpkeys = {}
    for k,v in pairs(self.components) do
        table.insert(cmpkeys, k)
    end
    table.sort(cmpkeys)
    for i,key in ipairs(cmpkeys) do
        if self.components[key].GetDebugString and self.components[key]:GetDebugString() then
            table.insert(str, key..": "..self.components[key]:GetDebugString().."\n")
        end
    end
--★原代码】  local cmpkeys = {}
--★重新启用时必须修的两处问题：
--   ① 变量名冲突：cmpkeys 在 993 行声明，而 993-1002 行的 for 循环体里
--      用 cmp 引用组件；没问题。但外层的 k,v 来自 pairs(self.components)，
--      与后续 for i,key in ipairs(cmpkeys) 中的 key 无冲突。可运行。
--   ② sort 的第二参数缺失：table.sort(cmpkeys) 只传了 1 个参数！
--★ 原文：`table.sort(cmpkeys)` —— Lua 中 table.sort(t) 无效，
--     必须传比较函数。正确写法是 table.sort(cmpkeys) 之前先
--     table.sort(cmpkeys, function(a,b) return a<b end)，
--     或直接写成 table.sort(cmpkeys)。
--★ 结论：这段注释掉的代码里存在 bug（table.sort 缺比较函数），
--     重新启用会抛 "bad argument #2 to 'sort'"。
--   → 重新启用时必须先补上比较函数。
    --]]
--【空行】

--第 2 段（1005–1010）：Brain 状态
--★ 为什么被禁用？GetBrainString:952 已经提供了等价能力（同一份数据），
--     属于早期重复实现。
    --[[if self.brain then
        table.insert(str, "-------\nBRAIN:\n")
        table.insert(str, tostring(self.brain))
        table.insert(str, "--------\n")
    end
    --]]
--【★ 第二段：Brain 状态（已禁用）】

--★★第 3 段（1012–1051）：事件监听表 —— 信息量最大的一段
--【它想展示什么】
--   event_listening —— 「我在监听谁」（事件 → 源实体 → 回调数组）
--   event_listeners—— 「谁在监听我」
--   ★ 这是排查「事件没触发」与「事件触发太多次」的最佳工具。
--【★ 限流设计值得学习】max_list = 5，每个事件最多列 5 个源。
--   ★ 理由：有些事件（如 onremove）有上千个监听者，全列会刷爆控制台。
--     这个「输出也要有上限」的思路适用于所有调试打印。
    --[[
    if self.event_listening or self.event_listeners then
        table.insert(str, "-------\n")
    end
    if self.event_listening then
--【★ 该段想输出的格式】对每个被监听的事件，列出「事件名: 源实体列表」。
--   ★ 注意它遍历的是 event_listening（我在监听谁），
--     而非 event_listeners（谁在监听我）—— 
--     调试时「我订阅了什么」通常比「谁订阅了我」更直观。
        table.insert(str, "Listening for Events:\n")
        for event, sources in pairs(self.event_listening) do
--【★ 计数后缀：(N)】当同一事件有多个源时显示总数，避免误解为只有一个。
--   ★ 这是输出限流模式：告诉你「被截断了」但不让你知道总数之外的细节。
            table.insert(str, string.format("\t%s%s: ", event, GetTableSize(sources) > 1 and string.format("(%u)", GetTableSize(sources)) or "") )

--★原注释："this can be a very long list" —— 作者自己也知道列表可能极长，
--   所以加了 max_list 限制。这与第 2 段（1005–1010）的 brain 列表不同：
--★   第 2 段的 GetTableSize(sources) 显示总数但只列 5 个；
--   第 3 段（1038）用 GetTableSize(listeners) 同样处理。两处风格一致。
            local max_list = 5 -- this can be a very long list
            local n = 0
--【★ 三层限流：事件列表只列 5 个源，每源只标数量不列回调】
--   设计意图：这是「快速发现问题」的工具，不是完整清单。
--   ★ 真正的完整信息应该用一个专门的调试命令按需输出。
            for source, fns in pairs(sources) do
                table.insert(str, string.format("%s%s%s", n > 0 and ", " or "", tostring(source), #fns > 1 and string.format("(%u)", #fns) or ""))
                n = n + 1
--★注意 break 在 n >= max_list 时触发，实际会列出 5 个（n=0..4），
--   即第 5 次迭代时 n 已是 5（前面 +1），break。行为正确。
                if n >= max_list then 
                    break 
                end
            end
            table.insert(str, "\n")
--【★ 事件名行的格式化】
        end
--【★ 换行收尾】
    end

--【★ 方向②：监听我的人】格式与上面完全对称。
--   ★ 两个方向都输出，才可能发现「本该一对一却有多对多」的不对称。
    if self.event_listeners then
--【★ 监听我的人：标题行】
        table.insert(str, "Broadcasting Events:\n")
        for event, listeners in pairs(self.event_listeners) do
            table.insert(str, string.format("\t%s%s: ", event, GetTableSize(listeners) > 1 and string.format("(%u)", GetTableSize(listeners)) or "") )
            local max_list = 5 -- this can be a very long list
            local n = 0
--【★ 同样限流 5 个】体现「调试输出必须有上限」的纪律。
            for listener, fns in pairs(listeners) do
                table.insert(str, string.format("%s%s%s", n > 0 and ", " or "", tostring(listener), #fns > 1 and string.format("(%u)", #fns) or ""))
                n = n + 1
                if n >= max_list then 
                    break 
--【★ 限流退出】
                end
--【★ 这段代码要展示「我监听了什么」与「谁在监听我」的对照】
--   ★ 在排查「事件重复触发」时，两者的差异能立刻暴露问题：
--     若 event_listening 只有一个源，但 event_listeners 里有 5 个，
--     说明有人在监听我，而我没监听它们 —— 这在「自己触发自己的事件」时是正常的。
            end
            table.insert(str, "\n")
        end
    end
--【★ 监听我的人：结束】

    --]]
--第 4 段（1052–1061）：pendingtasks 列表
--★意图：打印所有未完成的延时/周期任务（task.name + task.tick）。
   --★ 它的价值在于发现「泄漏的任务」——若某实体 Remove 后任务还在跑，
--     这里能直接看到。
   --★ task.name 在 Scheduler 体系里并不存在（Task 类只有 guid/id/fn/co），
--     所以这段若打开会输出 "nil"。属于历史遗留代码。
    --[[
    if self.pendingtasks then
        table.insert(str, "-------\nPending tasks:\n")
        for id,task in pairs(self.pendingtasks) do
--【★ 打印任务名与tick】
            if task then
                table.insert(str, tostring(id)..": "..task.name.. " " ..task.tick)
            end
        end
    end
--【★ 第四段结束】
    --]]
--【★ table.concat 一次性拼接】
--   全部收集完再拼，而不是边加边拼 —— 避免 O(n²) 字符串复制。
--   ★ 这是所有「拼接调试串」的标准做法。
    return table.concat(str, "")
end
--★ GetDebugString 的实际输出（禁用段落除外）：
--   "<GUID> - <prefab> <ASLEEP?> age <N.NN>\n<C++ 调试串>"
--   "Buffered Action: <action>\nSG:<状态图>\nDebugString:<自定义>\n-----------\n"
--【空行】

--★★ KillTasks：实体级协程清杀 —— 防泄漏的第一道防线
--【★ 为什么这行至关重要】
--   实体上用 StartThread(fn) 创建的协程，其id 是 self.GUID（见 1070 行）。
--   若实体销毁时不杀，这些协程会：
--     ① 继续持有已销毁实体的引用 → 内存泄漏
--     ② 在后续tick 里访问已释放的组件 → 崩溃
--   ★ 这与scheduler.lua:442 KillTasksWithID 是同一套机制的上下游。
--   参见 scheduler.lua:607 的 KillThreadsWithID 的说明。
--★★ 参见 scheduler.lua:442 KillTasksWithID 是本行的下游实现；
--   scheduler.lua:607 KillThreadsWithID 是对外的全局入口。
--   参见 scheduler.lua:556 StartThread 的 id 继承机制。
function EntityScript:KillTasks()
--【★ 按 GUID 清杀全部协程】
    KillThreadsWithID(self.GUID)
end
--【空行】

--★ StartThread 的封装：固定用 self.GUID 作为任务归属 id。
--   ★ 这样 EntityScript:KillTasks 与 KillThreadsWithID(self.GUID) 就成了
--     「一个实体销毁 = 一次调用清掉所有协程」的标准模式。
   --   ⚠ 强制传 GUID 也意味着「无法为子任务分组」——
   --     所有协程被视作同一归属，无法只杀一部分。
--★★ 参见 scheduler.lua:556 StartThread(fn, id, param)
--   ★ 参见 scheduler.lua:563 的 id 继承说明——本函数显式传 GUID，
--     因此不会走「继承当前协程 id」的分支。
function EntityScript:StartThread(fn)
    return StartThread(fn, self.GUID)
--【空行】
end

--【★ RunScript：在运行时执行另一个脚本文件】
--   LoadScript(name) 加载并返回该文件的顶层函数，然后立即以 self 为参数调用。
--   ★ 用途：把大量初始化逻辑（尤其是数据驱动的 prefab 配置）拆到独立文件，
--     保持主 prefab 脚本简洁。
   --   ⚠ 疑似缺陷：没有对 fn 做 nil 检查。若文件不存在或加载失败，
--     `fn(self)` 会抛 "attempt to call a nil value"，
--     错误信息不会指出是哪个脚本名 —— 排查成本高。
--     建议加 `assert(fn, "could not load script "..name)`。
--   ⚠ 另一个隐患：脚本里若定义 `function EntityScript:XXX()`，
--     执行 fn(self) 会给**全局的 EntityScript 类**加方法，
--     污染所有实体。这可能是有意的（模组惯例），但极易误用。
function EntityScript:RunScript(name)
    local fn = LoadScript(name)
--【★ 直接调用脚本顶层函数】
    fn(self)
end
--【空行】

--★★ Brain 控制的三层结构（1078–1146）：重启 / 停止 / 构造 ★ ★
--【★ 为什么要三层？因为「停 brain」有三个不同的语义需求：】
--   1. 临时暂停（打嗝、被打断）→ StopBrain(reason)，之后要能RestartBrain(reason)
--   2. 因休眠/limbo 而停 → _DisableBrain_Internal（不可被 Restart 恢复）
--   3. 构造时就不该启动 → SetBrain 里的 _braindisabled
--   ★★ 关键：只有第1 类有恢复接口。区分它们的是两个独立字段：
--     _brainstopped  —— 可恢复的停止原因集合（{ reason → true }）
--     _braindisabled —— 不可恢复的禁用标记
--   这是一个精妙的设计：用一个「带 key 的表」而非布尔，
--   天然支持「多种原因并存」，只有当所有原因都被解除时才重启。
function EntityScript:RestartBrain(reason)
--【★ reason 默认空串】使 `StopBrain()` 不传参时 reason 为 ""，
--   而空串在 Lua 中是**真值**，所以 _brainstopped[""] = true 能正常登记。
--   ★ 注意这与 nil 语义不同——这就是为什么 1079 和 1092 都要 `or ""`。
	reason = reason or ""
--★★ 多原因计数式恢复 —— 本文件最精妙的一段
--   场景：StopBrain("eating") 然后 StopBrain("fleeing")
--         → _brainstopped = { eating=true, fleeing=true }
--   RestartBrain("eating")
--         → 删掉 eating，还剩 fleeing → **不重启**
--   RestartBrain("fleeing")
--         → 删掉 fleeing，表空 → _brainstopped = nil → 重启
--   ★ 这精确实现了「多系统独立申请暂停，任一仍在就不跑」。
--   ★ 与 1093-1100 的配合：StopBrain 只在「从无到有」时才真正停 brain，
--     避免重复调 _Stop_Internal（那会把 brain 从调度表里摘掉，重复调用虽无害但浪费）。
	if self._brainstopped and self._brainstopped[reason] then
--【★ 删除对应原因】
		self._brainstopped[reason] = nil
		if next(self._brainstopped) == nil then
			self._brainstopped = nil
--【★ 只有最后一道原因解除时才真正重启 brain】
--   重启走 brain:_Start_Internal()（brain.lua 提供），它会把 brain
--   重新加入 BrainManager 的 updaters 列表。
			if self.brain then
				self.brain:_Start_Internal()
--【★ 全部原因解除 → 重启大脑】
			end
		end
	end
--【RestartBrain 结束】
end

--★★ StopBrain：可恢复的暂停
--【★ 双重保护的意义】
--   if self._brainstopped then   —— 已有暂停原因，仅登记新原因
--   else                        —— 首次暂停，记录并真正停止
--       self._brainstopped = { [reason] = true }
--       if self.brain then self.brain:_Stop_Internal() end
--   ★ 双重保护确保 _Stop_Internal 只被调一次 —— 
--     因为它会从 BrainManager 的调度列表里移除 brain，重复调虽不出错但徒增开销。
function EntityScript:StopBrain(reason)
	reason = reason or ""
	if self._brainstopped then
		self._brainstopped[reason] = true
	else
--【★ 首次暂停：登记原因并真正停止】
		self._brainstopped = { [reason] = true }
		if self.brain then
			self.brain:_Stop_Internal()
--【★ 真正停止大脑】
		end
	end
--【StopBrain 结束】
end
--【空行】

--★★ SetBrain：挂载 / 更换大脑
--【这是大脑生命周期的总入口，执行顺序每一步都有讲究】
--   ① 记下工厂函数 brainfn（必须记住，因为 brain 对象会在停/启时被重建）
--   ② 计算是否应当禁用（三个条件）
--   ③ 若有旧 brain，先停掉
--   ④ 根据禁用标记决定是否真的创建 brain 对象
--   ⑤ 新 brain 绑定 inst，若无待恢复的停止原因则立即启动
--★★ 参见 brain.lua:257 / brain.lua:273 BrainManager:RemoveInstance
--   —— brain 对象销毁时从调度表摘除。
function EntityScript:SetBrain(brainfn)
--【★ 工厂函数必须记住：大脑对象会被反复重建】
    self.brainfn = brainfn
--★V2C 注释直接说明了 sleepstatepending 的用途，与 221 行呼应：
--   "sleepstatepending check to prevent brain starting at construction when
--    :IsAsleep() always returns false"
--   ★ 翻译：构造期IsAsleep() 因引擎尚未发来初始状态而恒返回 false，
--     若不检查 sleepstatepending，休眠实体会在构造时被错误启动大脑。
	--V2C: -sleepstatepending check to prevent brain starting at construction when :IsAsleep() always returns false
--★★ 三条件或判定—— "brainfn and (A or B or C) or nil"
--   语义：只有在「配了大脑」且「在 limbo / 已睡着 / 休眠状态未知」时才禁用。
--   ★ 末尾的 `or nil` 是必需的：否则 false 会被存入 _braindisabled，
--     而 _DisableBrain_Internal:1126 与 _EnableBrain_Internal:1136 都用它做真值判断，
--     false 与 nil 语义相同所以功能上没问题，但 `or nil` 让字段语义更干净
--     （未设置 = nil）。
	self._braindisabled = brainfn and (self.sleepstatepending or self:IsInLimbo() or self:IsAsleep()) or nil
	if self.brain then
--【★ 先停旧 brain】更换大脑时必须停，否则旧 brain 残留在调度表里。
		self.brain:_Stop_Internal()
--【空行】
	end
--★★ 三元表达式（Lua 的 a and b or c）】
--   brainfn and not self._braindisabled and brainfn() or nil
--   拆解：(brainfn and (not _braindisabled) and brainfn()) or nil
--   ★ brainfn() 即调用工厂函数创建 brain 对象。
--   ★★ 陷阱提示：这个写法在「中间结果可能为 false/nil」时会退化。
--     这里 brainfn() 返回的是 Brain 实例（表），恒为真值，安全。
	self.brain = brainfn and not self._braindisabled and brainfn() or nil
	if self.brain then
--【★ brain.inst = self —— 回指宿主实体】
--   Brain 类通过 .inst 访问实体，两者形成双向引用。
--   ★ 这也是 _DisableBrain_Internal:1129 里 `self.brain = nil` 的原因：
--     ★★ 断开回指，防止「实体 → brain → inst → 实体」形成引用环导致无法 GC。
--     在有 GC 的 Lua 里环会被回收，但在无 GC 或引用计数环境下就是泄漏。
		self.brain.inst = self
--【★ 挂上 brain 后立刻检查是否有待恢复的暂停原因】
--   若 _brainstopped 存在（早先 StopBrain 过），则**不启动** ——
--   ★ 正确：换 brain 不应绕过「正在暂停」的状态。
		if not self._brainstopped then
			self.brain:_Start_Internal()
		end
--【★ 无待恢复原因时才启动】
	end
end
--★ Brain 生命周期完整状态机：
--   SetBrain  → 若 _braindisabled 则 self.brain = nil（不创建）
--   StopBrain(reason) → _brainstopped[reason]=true → brain:_Stop_Internal()
--   RestartBrain(reason) → 删该 reason；全删完才 brain:_Start_Internal()
--   _DisableBrain_Internal → _braindisabled=true → brain=nil（对象销毁）
--   _EnableBrain_Internal  → _braindisabled=nil → 重新 brainfn() 创建
--   ★★ 关键区别：_brainstopped 保留 brain 对象（可恢复），
--     _braindisabled 直接销毁 brain 对象（重建）。
--【空行】

--V2C: should only be called from OnEntitySleep, RemoveFromScene
--★V2C 注释："should only be called from OnEntitySleep, RemoveFromScene"
--   ★ 这是调用契约的正式声明。实际调用点：
--     RemoveFromScene:354（ limbo）、
--     以及 C++ 引擎的 OnEntitySleep 回调（由 prefab 脚本转发，
--     参见 components/amphibiouscreature.lua:29 的写法）。
--★★ 参见 components/amphibiouscreature.lua:29 OnEntitySleep
--   components/boatphysics.lua:684 OnEntitySleep
--   —— 组件层的 sleep 回调与本函数在同一条休眠链路上。
function EntityScript:_DisableBrain_Internal()
--【★ 有工厂函数才可能需要禁用】
	if self.brainfn then
--★★ 原注释解释了「为何不检查 _braindisabled 已为 true」】
--   "_braindisabled flag is only valid if we have a brainfn.
--   Don't bother checking 'not self._braindisabled'. This code is safe to run
--   multiple times"
--   ★ 翻译要点：
--     ① 标志有效性依赖于 brainfn 的存在，所以用 brainfn 作为总开关；
--     ② 不做「已禁用」的重入检查，因为本函数天然幂等；
--     ③ 依赖引擎只在必要时调用。
--   ——这是「用简单可重入的代码替代状态机」的思路，值得学习。
		--_braindisabled flag is only valid if we have a brainfn.
		--Don't bother checking "not self._braindisabled".  This code is safe to run
		--multiple times, and we can also assume that the engine properly calls this
		--only when necessary.
--【置 _braindisabled = true】与 _EnableBrain_Internal:1137 成对。
		self._braindisabled = true
--★★ 停止并丢弃 brain 对象 —— 与 SetBrain:1110 的关键区别
--   这里 `self.brain = nil` 彻底销毁对象（不只是停止），
--   ★ 原因：brain 内部可能持有行为状态（当前目标、计时器），
--     长时间休眠后这些状态早已过时，不如重建。
--   ★ 重建时用的 brainfn 仍保存在 self.brainfn，不会丢失。
		if self.brain then
--★★ 参见 brain.lua:89 BrainWrangler:RemoveInstance —— 停止大脑的核心。
			self.brain:_Stop_Internal()
			self.brain = nil
		end
--【end：脑销毁】
	end
--【_DisableBrain_Internal 结束】
end
--【空行】

--V2C: should only be called from OnEntityWake, ReturnToScene
--★V2C 注释："should only be called from OnEntityWake, ReturnToScene"
--   ★ 与 1120 行严格配对。两个函数构成「禁用/启用」的一对。
--★★ 参见 components/amphibiouscreature.lua:33 OnEntityWake
--   components/boatdrifter.lua:85 OnEntityWake
--   —— 与 1120 行严格配对。
function EntityScript:_EnableBrain_Internal()
--★ 守卫：只有在被禁用状态下才重建。
--   ★ 若实体本来就没 brain（_braindisabled 为 nil），本函数是 no-op，
--     因此 ReturnToScene:405 可以无条件调用它。
	if self._braindisabled then
--【★ 清禁用标记】
		self._braindisabled = nil
--【★ 重新创建 brain 对象】用的是 self.brainfn 工厂函数。
--   ★ 与 SetBrain 的区别：这里不需要再检查 _brainstopped 之外的条件，
--     因为 ReturnToScene:405 已经保证了「不 asleep 且 sleepstatepending 已解除」。
		self.brain = self.brainfn()
		if self.brain then
			self.brain.inst = self
			if not self._brainstopped then
				self.brain:_Start_Internal()
			end
--【end：brain 创建成功】
		end
	end
--【_EnableBrain_Internal 结束】
end
--【空行】

--★★ SetStateGraph：挂载状态图
--【★ 与 SetBrain 的对照 —— 二者结构惊人地相似】
--   SetBrain        用「工厂函数 + _braindisabled + _brainstopped」
--   SetStateGraph   用「工厂函数 + sg:Stop() + SGManager 调度」
--   ★ 共同模式：
--     ① 先清理旧实例 ② 创建新实例 ③ 挂到全局管理器 ④ 按需暂停
--   —— 两个 AI 框架在这一点上刻意保持一致，便于统一理解。
--★★ 参见 stategraph.lua:82 SGManager:RemoveInstance（清理实例）；
--   stategraph.lua:60 SendToList（按 asleep 决定入哪个调度表）。
function EntityScript:SetStateGraph(name)
--【★ 先移除旧实例】SGManager:RemoveInstance 会清理事件缓冲与调度列表。
--   参见 stategraph.lua:82。
    if self.sg ~= nil then
        SGManager:RemoveInstance(self.sg)
--【★ 移除旧实例的第二步】
    end
--【LoadStateGraph：加载状态图定义（函数）】见 62 行。
    local sg = LoadStateGraph(name)
--【★ 加载失败即崩】
    assert(sg ~= nil)
    if sg ~= nil then
--★★ StateGraphInstance(sg, self) —— 包装定义成运行时实例】
--   定义（工厂函数，静态）vs 实例（动态，含当前状态、变量）
--   ★ StateGraphInstance 是 stategraph.lua 提供的类，持有：
--     当前状态、当前/前一状态、历史、sg 定义、inst 宿主。
        self.sg = StateGraphInstance(sg, self)
--★SGManager:AddInstance(self.sg, self:IsAsleep())
--   ★★ 第二个参数是休眠状态：若实体正睡着，状态图直接进入「休眠形态」，
--     不做任何 tick 处理。参见 stategraph.lua 的 SendToList 逻辑。
--   —— 与 ReturnToScene:409 的 sg:Start(asleep) 呼应。
--★★ 参见 stategraph.lua:62-70 —— 休眠态下实例进入 tickwaiters 桶，
--   直到唤醒 tick 才会被调度。
		SGManager:AddInstance(self.sg, self:IsAsleep())
--★ GoToState(defaultstate) —— 立即进入初始状态。
--   ★ 注意是直接调用而非 PushEvent("gointostate")，
--     保证状态图挂上的第一刻就处于有效状态，而不是空壳。
        self.sg:GoToState(self.sg.sg.defaultstate)
--★★ 「在 limbo 则立即停止」的补偿】
--   1156 行已经告诉 SGManager 按 asleep 处理，
--   但 SGManager 的休眠是基于 **IsAsleep**（引擎状态），
--   而 limbo 是独立的概念 —— 一个醒着但被 RemoveFromScene 的实体
--   IsAsleep() 返回 false，SGManager 会正常调度它！
--   所以这里必须显式 sg:Stop()。
--   ★ 这正好印证了「limbo 与 sleep 正交」的论断 —— 
--     若二者等价，这行代码就是多余的。
--★★ 参见 stategraph.lua 的 SGManager:OnPushEvent
--   —— 返回 false 时 PushEvent_Internal:1307 会跳过状态图。
		if self:IsInLimbo() then
--【★ limbo 时立即停：sleep 与 limbo 正交的证据】
			self.sg:Stop()
		end
        return self.sg
    end
--【SetStateGraph 结束】
end
--【空行】

--★ ClearStateGraph 与 SetStateGraph:1149 的清理部分完全一致，
--   但额外把 self.sg 置 nil（因为它没有紧接着创建新实例）。
--   ★ 出现这个函数说明有时需要「只拆不装」——
--     例如实体形态变化后不再需要 AI 调度。
function EntityScript:ClearStateGraph()
--【★ 移除实例】
    if self.sg ~= nil then
        SGManager:RemoveInstance(self.sg)
        self.sg = nil
    end
end
--★ StateGraph 生命周期：
--   SetStateGraph(name) → RemoveInstance(旧) → LoadStateGraph →
--                     StateGraphInstance → SGManager:AddInstance(sg, asleep) →
--                     GoToState(default) → 若 inlimbo 则 Stop
--   ClearStateGraph()  → RemoveInstance + self.sg = nil
--   ★ 销毁时由 stategraph.lua:77 的 OnRemoveEntity 钩子兜底清理。
--【空行】

--★★★ 事件总线（1172–1323）：全游戏最核心的解耦机制 ★ ★ ★
--【★ 数据结构 —— 双向索引是防泄漏的关键】
--   source.event_listeners[event][listener_entity] = { fn1, fn2, ... }
--   self.event_listening  [event][source_entity] = { fn1, fn2, ... }
--   ★★ 为什么要在**两端**各存一份？
--     正向（event_listeners）：PushEvent 时按事件名快速找到所有监听者。
--     反向（event_listening）：★ 当 source 要销毁时（RemoveAllEventCallbacks），
--       需要「我监听了谁」的完整清单，才能主动去对方的正向表里摘掉自己。
--       若只有单向索引，source 销毁后其他实体的 event_listeners 里
--       仍残留指向它的键 → ★★ 悬垂引用 → 内存泄漏 + 崩溃。
--       （Lua 有 GC，能回收不可达对象；但 table 中残留的键会让那些表
--         永远可达，从而钉住整棵对象树——这才是真正的危害。）
--   ★ 这套「双向链表式索引」是解耦系统防泄漏的标准范式，值得学习。
--【三层嵌套的代价】
--   每次 PushEvent 要做两层哈希查找。但只查 event_listeners 一侧，
--   反向表只在注册/注销时用，所以热路径成本可接受。
local function AddListener(t, event, inst, fn)
--【★三层懒建】每一层都是「用到才建」。
--   对没有事件的实体（占大多数），event_listeners 保持 nil。
    local listeners = t[event]
    if not listeners then
        listeners = {}
        t[event] = listeners
--【end：三层懒建】
    end

--【★ 第二层：同一实体对同一事件的多个回调用数组存】
--   同一个 fn 登记两次会被调用两次（不去重）。
--   ★ 这与 WorldState 的处理一致（见 20 行的注释）。
   --★ 为什么允许重复？严格说这是个坑：
--     若模组不小心 ListenForEvent 两次（比如一个回调既由 prefab 注册，
--     又由某个 OnLoad 路径再注册一次），事件会触发两次，
--     导致「血量减两次」这类难查的 bug。
--     更安全的做法是登记时检查 fn 是否已存在并跳过。
    local listener_fns = listeners[inst]
    if not listener_fns then
        listener_fns = {}
        listeners[inst] = listener_fns
    end

--【★ table.insert：允许重复登记同一 fn】
    table.insert(listener_fns, fn)
end
--【空行】

--【★ ListenForEvent(event, fn, source) —— 监听一个事件】
--   source 默认是自己（监听自己的事件，即 PushEvent 会调到自己）。
--【★ 两种用法】
--   ① inst:ListenForEvent("onuse", fn)          —— 监听自己
--   ② inst:ListenForEvent("onuse", fn, other)    —— 监听另一个实体
--   第② 种是「观察者模式」：A 想在 B 被使用时做反应。
--   ★ 这让实体间可以通信而不必互相持有强引用类型耦合。
function EntityScript:ListenForEvent(event, fn, source)
    --print ("Listen for event", self, event, source)
--【★ source 缺省即自己】
    source = source or self

    if not source.event_listeners then
        source.event_listeners = {}
    end

--【★ 写入对方的正向表】source.event_listeners[event][self] = {fn}
--   ★ 注意参数顺序：AddListener(t, event, inst, fn) 的 inst 是「监听者」，
--     所以这里传的是 self（监听者），t 是 source.event_listeners。
    AddListener(source.event_listeners, event, self, fn)
--【空行】

    if not self.event_listening then
        self.event_listening = {}
    end

--【★ 写入自己的反向表】AddListener(self.event_listening, event, source, fn)
--   ★ 与 1196 完全镜像：同一个函数，因为结构是对称的。
--   —— 这个对称性是双向索引设计最优雅的地方：
--     一次 AddListener 调用同时建立正反两条边。
    AddListener(self.event_listening, event, source, fn)
--【ListenForEvent 结束】
end
--【空行】

--★★ RemoveListener：摘除一条边（同时用于正反两个方向）
--【★ 逐层早退】任何一层不存在就直接返回 —— 
--   这让「注销一个从未注册的监听」是安全的（幂等）。
local function RemoveListener(t, event, inst, fn)
    if not t then return end

    local listeners = t[event]
    if not listeners then return end

--【★ 查第三层】
    local listener_fns = listeners[inst]
    if listener_fns then
--【★ 按值删除，与登记时 table.insert 严格配对】
--   ★ 注意 RemoveByValue 只删一个匹配项 —— 若误登记两次，
--     注销一次后还剩一条。这正是「不去重」设计的代价，需在调用侧注意。
        RemoveByValue(listener_fns, fn)
--【★ 三级收缩】回调数组空 → listeners[inst] 删→ t[event] 删。
--   与 WorldState 的收缩逻辑完全同构（23–40 行），
--   ★ 说明这是团队内统一的「惰性释放」风格。
        if next(listener_fns) == nil then
            listeners[inst] = nil
        end
    end
    if next(listeners) == nil then
        t[event] = nil
--【★ 第二级收缩】
    end
--【RemoveListener 结束】
end
--【空行】

--★★ RemoveEventCallback：取消监听
   --★ assert(type(fn) == "function") —— 签名变更的强制校验
--   原注释："signature change, fn is new parameter and is required"
--   ★ 历史上 RemoveEventCallback 只需 event（用于旧式全局监听），
--     现在必须传 fn。断言强制模组适配，是 API 破坏性变更的标准做法。
function EntityScript:RemoveEventCallback(event, fn, source)
    assert(type(fn) == "function") -- signature change, fn is new parameter and is required

    source = source or self

--【★ 与 ListenForEvent:1196/1202 完全镜像的两条反向摘除】
--   ★ 顺序无所谓（两张表互不依赖）。
    RemoveListener(source.event_listeners, event, self, fn)
    RemoveListener(self.event_listening, event, source, fn)
--【RemoveEventCallback 结束】
end
--【空行】

--★★★ RemoveAllEventCallbacks：一次性断开所有事件连接
--【★ 两个方向都要通知，缺一不可】
--   方向①（1233）：「我不再监听别人了」→去每个人的正向表里摘掉我
--   方向②（1248）：「别人别再监听我了」→去他们的反向表里摘掉我
--   ★★ 方向② 才是关键：绝大多数监听关系是「我监听别人」，
--     若只做方向①，被我监听的人的正向表里仍然留着我的键 → 悬垂引用。
--【★ 为什么能保证完整？】
--   因为反向表 self.event_listening 精确记录了我发出的每一条 ListenForEvent。
--   只要登记/注销都走 ListenForEvent/RemoveEventCallback 这对 API，
--   反向表就是完备的。
   --★⚠ 前提：如果有人直接手工改 self.event_listeners（比如猴补），
--     就会破坏这个完备性。框架依赖「所有变更都走 API」这个约定。
function EntityScript:RemoveAllEventCallbacks()
    --tell others that we are no longer listening for them
--【★ 方向①：遍历我监听的 (event, source, fns)】
--   ★ 注意 fns 变量未被使用 —— 因为反向表只需要「键」即可整条摘除。
    if self.event_listening then
        for event, sources  in pairs(self.event_listening) do
            for source, fns in pairs(sources) do
                if source.event_listeners then
--【★ 三重保护：source.event_listeners 存在 / listeners[event] 存在 / 直接置 nil】
--   置 nil 而非逐个 fn 删除 —— ★ 因为我作为 listener 的**所有**回调都不要了。
                    local listeners = source.event_listeners[event]
                    if listeners then
                        listeners[self] = nil
                    end
                end
--【★ 遍历结束】
            end
        end
--【★ 整表置 nil】释放反向索引的引用。
        self.event_listening = nil
--【空行：两方向之间】
    end    

    --tell others who are listening to us to stop
--【★ 方向②：遍历监听我的 (event, listener, fns)】
--   ★ 与方向① 对称。listener.event_listening[event] 里存的是「谁在听这个事件」，
--     摘掉自己这一项。
    if self.event_listeners then
        for event, listeners in pairs(self.event_listeners) do
            for listener, fns in pairs(listeners) do
                if listener.event_listening then
                    local sources = listener.event_listening[event]
                    if sources then
                        sources[self] = nil
--【★ 反向表摘除完毕】
                    end
                end
--【end：方向②】
            end
        end
        self.event_listeners = nil
    end
end
--【空行】

--★★ EntityScript:WatchWorldState —— 世界状态观察的实体入口
   --★ 与 42行的 ComponentWatchWorldState 是同一个动作，只是 self 的类型不同：
--     组件版：EntityWatchWorldState(self.inst, var, fn)
--     实体版：EntityWatchWorldState(self, var, fn)
--   两处都再调TheWorld.components.worldstate:AddWatcher 完成分发索引。
--【★ 为什么观察者要传第四个参数 self？】
--   AddWatcher(var, inst, fn, self) 的第四个参数用于区分「实体自己观察」与
--   「组件代实体观察」—— worldstate 组件可能需要据此回调不同的清理路径。
function EntityScript:WatchWorldState(var, fn)
    EntityWatchWorldState(self, var, fn)
    TheWorld.components.worldstate:AddWatcher(var, self, fn, self)
--【WatchWorldState 结束】
end
--【空行】

function EntityScript:StopWatchingWorldState(var, fn)
    EntityStopWatchingWorldState(self, var, fn)
    TheWorld.components.worldstate:RemoveWatcher(var, self, fn, self)
--【StopWatchingWorldState 结束】
end
--【空行】

--★★★ StopAllWatchingWorldStates：批量注销全部观察者
--【★ 与 RemoveEventCallbacks 的对照 —— 三者结构惊人一致】
--   RemoveAllEventCallbacks  遍历反向表逐个通知对方
--   StopAllWatchingWorldStates 直接批量调 worldstate:RemoveWatcher(var, self)
--   ★ 区别在于：worldstate 组件有独立的批量删除接口（只传 var 与 self，
--     不传 fn），所以不需要逐个 fn 匹配，效率更高。
function EntityScript:StopAllWatchingWorldStates()
    if not self.worldstatewatching then
        return
    end
--【★ 无观察者直接返回】

--★★ 只遍历 key（变量名），不遍历 fn 列表 —— 依赖 RemoveWatcher 的批量语义】
--   RemoveWatcher(var, self) 删掉该实体在这个变量上的**所有**观察者。
--   ★ 这比逐个 RemoveWatcher(var, self, fn) 快得多，
--     但前提是「这个实体的所有该变量观察者都要删」——
--     ★★ 这里确实是这个语义（函数名就是 All），所以正确。
--   ⚠ 但如果将来有「只删特定 fn」的批量需求，这个实现就不适用了。
    for var in pairs(self.worldstatewatching) do
        TheWorld.components.worldstate:RemoveWatcher(var, self)
    end
--【★ 通知 worldstate 组件批量删除】

    self.worldstatewatching = nil
end
--【空行】

--★★★ PushEvent_Internal —— 事件分发的三个目的地
--【★ 一次 PushEvent 会把事件送到三个地方，顺序固定】
--   ① 普通监听者（event_listeners）—— 同步调用 fn(self, data)
--   ② StateGraph—— 排队（sg:PushEvent）或立即（sg:HandleEvent）
--   ③ Brain          —— brain:PushEvent
--   ★ 顺序意味着：普通监听者先于 AI 逻辑被通知。
--     这样「组件收到事件后做出的状态改变」能被 AI 看到，
--     AI 决策基于的是事件的最终结果而非中间状态。
--【★ PushEvent 的三个目的地顺序不可交换】
   --★★  为什么组件监听者必须在 AI 之前？】
--   场景：生物吃了浆果 → 组件处理 OnEat（加饱食度、播放音效）
--     → 然后 brain 收到 "oneat" 事件，决定「吃饱了，回窝睡觉」。
--   ★ 若 brain 先收到事件，它读到的饱食度还是旧值 → 决策错误。
--   ★★ 这就是「状态先更新，AI 后决策」的强保证。
function EntityScript:PushEvent_Internal(event, data, immediate)
--【★ 两级早退：没有监听表 → 无监听者 → 什么都不做】
--   ★ 这是PushEvent 的绝对热路径（每帧可能成百上千次），
--     两级判空把「无监听实体」的开销压到最低。
    if self.event_listeners then
        local listeners = self.event_listeners[event]
--【★ 查事件对应的监听者表】
        if listeners then
--★★ 原注释："make a copy list of all callbacks first in case listener
--            tables become altered in some handlers"
--【★ 为什么必须先拷贝？—— 事件系统的经典崩溃点】
--   典型场景：实体 A 监听实体 B 的 "onuse"。
--   B:PushEvent("onuse") 遍历到 A 的回调 → A 的回调里调 A:Remove() →
--     → RemoveAllEventCallbacks 把 A 从 B.event_listeners 中删掉 →
--     → ★★ 此时正在遍历的 listeners 表被修改！
--   Lua 中「遍历中删当前键」是安全的，但删之后若继续访问已失效结构，
--   或有新的回调被加入，就会出问题。
--   ★ 拷贝到 tocall 后，遍历的是稳定的快照，
--     回调列表的变化只影响「下一次」PushEvent。
--   ★★ 代价：每次事件分发都分配一个数组。
--     在高频事件（如 onframeupdate）上这可能成为 GC 压力来源。
   --   ⚠ 潜在优化：若监听者数量为 0/1 可跳过拷贝（直接调用），
--     但那会让行为不一致（单回调时仍可能触发同样的问题）。
            --make a copy list of all callbacks first in case
--【★ 快照的必要性：见上方分析】
            --listener tables become altered in some handlers
--【★ tocall：一维回调数组】
            local tocall = {}
--【★ 两层扁平化：entity → fns[] → 展平成一维回调数组】
--   ★ 回调被无序展平（pairs 顺序不确定），
--     所以**监听者之间的执行顺序是不确定的**。
--     ★ 这是重要的使用约束：多个监听者时不要依赖彼此的执行顺序。
            for entity, fns in pairs(listeners) do
                for i, fn in ipairs(fns) do
                    table.insert(tocall, fn)
                end
--【end：展平】
            end
--【★ 执行快照中的回调】不检查 fn 是否仍有效 —— 见上面的拷贝理由。
--【★ 回调的调用签名 fn(self, data)】
--   第一个参数恒为「事件源实体」（即 self），
--   ★ 这让监听者无需闭包捕获即可知道是谁发出的事件。
            for i, fn in ipairs(tocall) do
--【★ 执行回调】
                fn(self, data)
--【end：执行快照】
            end
        end
    end
--【end：目的地①】

--★★ 目的地②：StateGraph
--【★ 两条路径：立即 vs 排队】
--   immediate = true  → sg:HandleEvent（立刻在当前调用栈内处理）
--   immediate = false → sg:PushEvent（进入状态图的事件队列）
--   ★ 区别：
--     排队模式下，状态图会在自己的 tick 里消费事件，
--     所以 PushEvent 立即返回时状态图可能还没反应。
--     立即模式则是同步的，但**不允许在状态图事件处理中做某些操作**
--     （否则会破坏状态图的内部状态机）。
--【★ StateGraph 事件的两种投递方式的技术含义】
--   排队（PushEvent）：事件进入 sg.eventqueue，在 SGManager:Update 时消费。
--     ★ 优点：不会重入；缺点：延迟一帧。
--   立即（HandleEvent）：在当前调用栈内直接处理。
--     ★ 优点：同步；缺点：可能重入，需要调用方保证安全。
--   PushEventImmediate:1321 就是给需要同步的场景准备的出口。
--★★ 参见 stategraph.lua 的 HandleEvent / PushEvent / IsListeningForEvent
--   —— 本行的两个分支分别对应它们。
	if self.sg then
		if immediate then
--【★ 立即模式：直接 HandleEvent】
			self.sg:HandleEvent(event, data)
--★★ 双重短路：先问状态图是否对该事件有反应，再问它此刻能否处理】
--   IsListeningForEvent(event) —— 该事件是否被任何 OnEvent 关注
--   SGManager:OnPushEvent(self.sg) —— ★ 状态图当前是否可接受事件
--     （例如正在 sleepstate / 正在 stop 状态时返回 false）。
--   ★ 这两个检查把「事件到状态图」的通道开销降到最低。
--     对比 1304 的 `if self.sg then` 只判断存在性。
--【★ SGManager:OnPushEvent 的作用 —— 参见 stategraph.lua】
--   它检查状态图实例是否处于可接受事件的状态，
--   并返回布尔。状态图在 stop/sleep/destroy 状态下返回 false。
--   ★ 这避免了「往已停止的状态图里塞事件」导致的内部状态损坏。
--★★ 参见 stategraph.lua 的 SGManager:OnPushEvent；
--   以及 stategraph.lua:715 RemoveInstance 中的 ClearBufferedEvents。
		elseif self.sg:IsListeningForEvent(event) and SGManager:OnPushEvent(self.sg) then
			self.sg:PushEvent(event, data)
--【end：目的地②】
		end
--【end：if self.sg】
    end
--【空行】

--【目的地③：Brain】无任何检查，直接转发。
--   ★ 相比状态图的双重短路，brain 没有这么精细的守卫，
--     说明 brain 的事件处理本身就是轻量的（brain.lua 里是个简单的表）。
    if self.brain then
        self.brain:PushEvent(event, data)
    end
--【PushEvent_Internal 结束】
end
--【空行】

--【★ PushEvent = 非立即版】这是99% 的调用方用的接口。
function EntityScript:PushEvent(event, data)
--【★ 非立即版转发】
	self:PushEvent_Internal(event, data, false)
end
--【空行】

--【★ PushEventImmediate = 立即版】
--   何时需要立即？「我 PushEvent 后马上要读状态图的状态」的场景。
--   ★ 典型：玩家在客户端预测执行一个动作，需要立刻看到反馈。
--   ⚠ 使用需谨慎：立即处理意味着状态图会在当前调用栈内执行其逻辑，
--     可能触发协程/事件的重入。
function EntityScript:PushEventImmediate(event, data)
--【★ 立即版转发】
	self:PushEvent_Internal(event, data, true)
end
--★ PushEvent 两个入口的完整对照表：
--   PushEvent(event, data)          → PushEvent_Internal(e, d, false) → 状态图排队
--   PushEventImmediate(event, data) → PushEvent_Internal(e, d, true)  → 状态图立即
--   ★ 普通监听者与 brain 在两种模式下行为完全相同（都是同步调用）。
--【空行】

--【★ 物理半径覆盖：让实体的逻辑半径与视觉大小解耦】
--   典型：一株「刚种下的树苗」视觉很小但碰撞要按成熟大小算；
--   或者相反—— 大型的装饰物不需要碰撞。
function EntityScript:SetPhysicsRadiusOverride(radius)
--【★ 覆盖值可为 nil（取消覆盖）】
    self.physicsradiusoverride = radius
--【空行】
end

--★★ GetPhysicsRadius 的三级回退】
--   ① physicsradiusoverride —— 显式覆盖（1325 行设的）
--   ② Physics:GetRadius() —— 组件的真实半径
--   ③ default          —— 调用方给的兜底值
--   ★ 为什么不用 ② 的返回值作为唯一答案？
--     因为无 Physics 组件的实体（纯视觉物）也需要一个查询半径。
function EntityScript:GetPhysicsRadius(default)
--【★ or 链三级回退】
    return self.physicsradiusoverride or (self.Physics ~= nil and self.Physics:GetRadius()) or default
--【空行】
end
--【空行】

--【★BOAT_MUST_TAGS：必须带 "boat" 标签才算船】
--   FindEntities 的最后一个参数是「标签过滤」，会走 C++ 侧的空间索引，
--   ★ 这是「用空间查询替代全表遍历」的标准优化。
local BOAT_MUST_TAGS = {"boat"}
--★★ GetBoatIntersectingPhysics：查询「与我物理重叠的船」
--【用途】玩家在船上时切船、掉落判定、以及「船并靠」时的浮动平台处理。
--【★ 两段式空间查询策略 —— 值得学习的性能范式】
--   第一步（1339）：用 TheSim:FindEntities 取一个**保守的大圆**内的所有 boat
--                 check_radius = self_radius + MAX_PHYSICS_RADIUS + 0.18
--   第二步（1340-1349）：对每个候选做**精确**的圆-圆相交判定
--   ★ 为什么要两步？因为空间索引只能做「圆内包含」的粗筛（且半径统一），
--     而船有各种大小，必须逐个精确判断。
--   ★ 若直接遍历 Ents 找所有船（可能几百条），开销会大得多。
function EntityScript:GetBoatIntersectingPhysics()
--★ 原注释："Intentionally ignoring physics override radius."
--   ★ 刻意不用 GetPhysicsRadius（含 override），只用真实物理半径。
--     理由：船的物理重叠必须反映真实的碰撞体积，
--     而 override 是给逻辑（如攻击判定）用的。
--   ★ 这体现了「同一实体有多套半径语义，各有用途」的常见工程现实。
--【★ 忽略 override，只用真实物理半径】
    local self_radius = self.Physics ~= nil and self.Physics:GetRadius() or 0 -- Intentionally ignoring physics override radius.
--【★ max_boat_radius = MAX_PHYSICS_RADIUS + 0.18】
--   +0.18 的偏移量注释说是 "Add a small offset for item overhangs"
--   ★ 原因：物品可能伸出船体（如栏杆上的花盆），
--     所以船的「有效占用半径」比物理碰撞半径略大。
   --   ⚠ 魔法数字 0.18 出现两次（1336 与 1342），
--     应提取为常量，否则调整时容易漏改一处。
    local max_boat_radius = MAX_PHYSICS_RADIUS + 0.18 -- Add a small offset for item overhangs.
--【★ 粗筛半径 = 自身 + 最大船 + 悬挂余量】
    local check_radius = self_radius + max_boat_radius
--【★ 取自身位置】
    local x, y, z = self.Transform:GetWorldPosition()
--★ 注释提醒：大半径查询可能包含小船，所以还要逐个精确判定。
    local boats = TheSim:FindEntities(x, y, z, check_radius, BOAT_MUST_TAGS) -- Biggest radius check may include smaller boats.
--【★ 遍历候选船只】
    for _, boat in ipairs(boats) do
--【★ 排除自己】
        if boat ~= self then
--★★ 三级回退取船的半径】
--   ① GetSafePhysicsRadius() —— 船脚本可覆写的安全半径（最优先）
--   ② components.hull:GetRadius() —— 船体组件的半径
--   ③ TUNING.BOAT.RADIUS       —— 配置默认值
--   ★ 三级回退保证：无论船用哪种实现（标准船、mod 船、简化的船），
--     都能拿到一个合理半径。
            local boat_radius = boat.GetSafePhysicsRadius and boat:GetSafePhysicsRadius() or (boat.components.hull ~= nil and boat.components.hull:GetRadius() or TUNING.BOAT.RADIUS) + 0.18 -- Add a small offset for item overhangs.
            local bx, by, bz = boat.Transform:GetWorldPosition()
--【★ 只用水平面差值】
            local dx, dz = bx - x, bz - z
            local dist = math.sqrt(dx * dx + dz * dz)
--【★ 精确判定：圆心距 ≤ 两半径之和】
--   dist - boat_radius <= self_radius  等价于  dist <= self + boat
--   ★ 只用 x/z（忽略 y）—— 因为 DST 是 2.5D，船的垂直分层不重要。
            if dist - boat_radius <= self_radius then
--【★ 相交则返回该船】
                return boat
            end
        end
    end

--★ 找到第一个就返回（不排序）—— 「任一船相交」而非「最近的船」。
    return nil
--【GetBoatIntersectingPhysics 结束】
end
--【空行】

--【★ GetPosition 返回 Point 而非裸三元组】
--   Point 是 DST 的封装类型，带 :Get() / :Distance() 等方法。
--   ★ 为什么不是三元组？因为元组每次都要重新解包，
--     而 Point 在 C++ 侧有更快的向量运算。
--   ⚠ 需注意：Point/Vector3 都是有引用的可变对象，
--     别把 self:GetPosition() 的结果长期持有。
function EntityScript:GetPosition()
--【★ Point 包装】
    return Point(self.Transform:GetWorldPosition())
--【空行】
end

--【★ GetRotation 返回角度制角度（0–360）】
--   ★ 游戏中朝向以「0 = 正北，顺时针」表示；
--     而 Transform 底层用弧度，故内部到处乘/除 RADIANS（见 1372）。
function EntityScript:GetRotation()
--【★ 原样透传角度】
    return self.Transform:GetRotation()
end
--【空行】

--★ GetAngleToPoint：算出「我该转多少度才能面向某点」
--【★ 两种调用形态】
--   ① (x, y, z)     —— 三个数字
--   ② (point)       —— 只有一个参数且 y/z 为 nil
--   ★ 这种「重载式」签名在 Lua 中靠 nil 检查实现，是常见惯用法。
function EntityScript:GetAngleToPoint(x, y, z)
--【★ 形态①无参 → 返回 0（无朝向目标）】
    if x == nil then
--【★ 形态②：y 与 z 同时为 nil 才是「只传了一个点」】
        return 0
--【空行】
    elseif y == nil and z == nil then
--【形态②：解包 Point】x = point:Get() 返回 x,y,z 三元组。
        x, y, z = x:Get()
--【★ 取自身世界坐标】
    end
--【★ 只算水平面朝向】取自身位置 (x1,y1,z1)。
    local x1, y1, z1 = self.Transform:GetWorldPosition()
--★★ 退化处理：已经在目标点上则保持当前朝向】
--   若 x1 == x and z1 == z（即已重合），atan2(0,0) 返回 0，
--   ★ 那会让实体突然「面向北方」，视觉上是一次突兀的转身。
--   所以显式保持当前朝向。
--   ⚠ 隐患：与「刚好在正北方」的情况无法区分（两者的结果一致，
--     所以无害）—— 这是一个巧妙的容错。
	return x1 == x and z1 == z
--【★ 已重合 → 保持当前朝向，避免突兀转身】
		and self.Transform:GetRotation()
--★ math.atan2(z1 - z, x - x1) * RADIANS
--   ★ atan2 返回弧度，* RADIANS(=180/π) 转成角度。
--   ★ 注意参数顺序是 atan2(dz, dx) 而非 atan2(dy, dx) ——
--     因为这是 2D 水平面角度，用的是 z 轴（南北）而非 y 轴（上下）。
--   ★ 这是全游戏最容易搞错的坐标约定：
--     数学里 atan2(y, x)，这里 atan2(z, x)。
		or math.atan2(z1 - z, x - x1) * RADIANS
--【GetAngleToPoint 结束】
end
--【空行】

--【★ GetPositionAdjacentTo：算「离 target 恰好 distance 的、朝向我的点」】
--   用于「站在攻击者旁边」「绕到目标正面」等 AI 计算。
function EntityScript:GetPositionAdjacentTo(target, distance)
--【★ 无目标返回 nil】
    if target == nil then
        return nil
--【★ p1 自身 / p2 目标】
    end
--【★ 方向向量】
    local p1 = Vector3(self.Transform:GetWorldPosition())
    local p2 = Vector3(target.Transform:GetWorldPosition())
--【★ offset = p1 - p2（我朝目标的方向向量）】
    local offset = p1-p2
--★ Normalize() —— 若两位置重合则得到零向量（不被正规化）。
   --★⚠ 潜在缺陷：若 p1 == p2，offset 为 (0,0,0)，Normalize 无效果，
--     乘distance 仍为 (0,0,0)，结果就是目标点本身 ——
--     行为退化但不崩溃，属可接受的边界情况。
    offset:Normalize()
--【★ 缩放到指定距离】
    offset = offset * distance
--【★ p2 + offset = 以目标为圆心、指向我的那个点】
    return (p2 + offset)
--【GetPositionAdjacentTo 结束】
end
--【空行】

--【ForceFacePoint：无视状态图地转身】
--   ★ 与 FacePoint 的唯一区别是不检查 busy 状态。
--     典型用途：玩家主动交互（如转头看箱子）。
function EntityScript:ForceFacePoint(x, y, z)
--【★ 强制转向：无视状态图】
    self.Transform:SetRotation(self:GetAngleToPoint(x, y, z))
--【空行】
end
--【空行】

--★★ FacePoint：AI 转向的标准入口
--【★ "busy" 状态标签：状态图声明「我正忙」时禁止被外部转向打断】
--   ★ 这是「AI 自主性与外部控制权」的仲裁点：
--     攻击时正在挥剑（busy），你就不能让它突然转身面向别处。
--   ★★★ 关键洞察：FacePoint 的权威性完全依赖 StateGraph 是否存在。
--     若实体没有状态图（sg == nil），FacePoint 就总是生效；
--     行为随「有没有挂 sg」而突变——
--     ★ 所以不能给同一个 prefab 配置两个版本（一个有 sg 一个没有）。
function EntityScript:FacePoint(x, y, z)
    if self.sg ~= nil and self.sg:HasStateTag("busy") then
--【★ busy 状态下直接放弃】
        return
--【★ 不做任何事】
    end
    self.Transform:SetRotation(self:GetAngleToPoint(x, y, z))
--【FacePoint 结束】
end
--【空行】

-- consider using IsNear if you're checking if something is inside/outside a certain horizontal distance
-- consider using IsNear if you're checking if something is inside/outside a certain horizontal distance
--★ 原注释的建议很实用：调用方若只是「是否在范围内」
--   请直接用 IsNear，少写一次平方。
--【★ 距离计算只取 x/z —— 2D 距离】
--   ★ 这是 2.5D 游戏的核心约定：
--     「牛距离你 3 格」指的是水平距离，与高度无关。
--     （连游泳的鸭子「像鸭子一样把水甩掉」判定也只看水平距离。）
function EntityScript:GetDistanceSqToInst(inst)
--★ assert 两个实体都有效——计算需要读它们的 Transform。
   --★⚠ 缺陷：热路径上的断言。GetDistanceSqToInst 在 AI 中可能每帧调数十次，
--     每次两个 IsValid()（都是 FFI 调用）开销不小。
--     生产构建若关闭断言则完全白付这两个调用的开销。
    assert(self:IsValid() and inst:IsValid())
    local p1x, p1y, p1z = self.Transform:GetWorldPosition()
    local p2x, p2y, p2z = inst.Transform:GetWorldPosition()
    return distsq(p1x, p1z, p2x, p2z)
--【★ 平方距离：只算水平面】
end
--【空行】

--【★IsNear：平方比较，避免开方】
--   `self_radius² > dist²` 等价于 `self_radius > dist`（均非负）
--   ★ 性能技巧：省掉一次 sqrt。
function EntityScript:IsNear(otherinst, dist)
--【★ 平方比较免开方】
    return otherinst ~= nil and self:GetDistanceSqToInst(otherinst) < dist * dist
end
--【空行】

--★ GetDistanceSqToPoint：与 1399 同构，但目标是点而非实体。
function EntityScript:GetDistanceSqToPoint(x, y, z)
    -- If x is the only input, assume it's a Vector3 or Point
    -- If x is the only input, assume it's a Vector3 or Point
--【★ 形态检测：只有 x、y 和 z 均为 nil 时】
--   若调用方传 (10, nil, nil)（只想算 2D 距离），
--   ★ 条件 `x and not y and not z` 为真 → 会误认为是 Vector3 而崩溃。
--   ⚠ 潜在缺陷：参数校验不严。实际代码中很少这样调用，故未暴露。
--     更稳妥的是检查 type(x) == "userdata" 或 x.Get ~= nil。
    if x and not y and not z then
        x, y, z = x:Get()
--【★ 解包 Vector3 / Point】
    end
--【空行】
    local x1, y1, z1 = self.Transform:GetWorldPosition()
    return distsq(x, z, x1, z1)
end
--【空行】

--【★ IsNearPlayer：范围查询玩家的便利函数】
--   isalive 参数控制是否只算活着的玩家（死掉的幽灵不算）。
function EntityScript:IsNearPlayer(range, isalive)
    local x, y, z = self.Transform:GetWorldPosition()
--【★ 委托给全局函数】
    return IsAnyPlayerInRange(x, y, z, range, isalive)
--【空行】
end

--★ GetNearestPlayer：找到最近玩家实体（可能有多个玩家）。
function EntityScript:GetNearestPlayer(isalive)
    local x, y, z = self.Transform:GetWorldPosition()
--【★ 委托给全局函数】
    return FindClosestPlayer(x, y, z, isalive)
end
--【空行】

--【★ 找不到玩家时返回 math.huge】
--   ★ 而不是 0 或 nil —— 因为调用方会直接做 `< threshold` 比较，
--     huge 与任何阈值比较都得到 false，语义自然正确。
--   ★ 这是「用哨兵值避免调用方判空」的好范式。
function EntityScript:GetDistanceSqToClosestPlayer(isalive)
    local x, y, z = self.Transform:GetWorldPosition()
    local player, distsq = FindClosestPlayer(x, y, z, isalive)
--【★ 兜底 huge：调用方无需判空】
    return distsq or math.huge
end
--【空行】

--★ FaceAwayFromPoint：转身背对某点（如被击退时、逃离时）。
function EntityScript:FaceAwayFromPoint(dest, force)
--【★ 与 FacePoint 同样的 busy 保护，但由 force 参数可覆盖】
--   ★ 设计得比 FacePoint 更好：提供了 force 逃生口，
--     强制行为（如被击退）可以绕开 busy 检查。
--   ⚠ 不对称：FacePoint 没有 force 参数。
   --   → 一致性上应给 FacePoint 也加 force。
    if not force and self.sg ~= nil and self.sg:HasStateTag("busy") then
--【★ busy 保护，但可用 force 绕过】
        return
--【★ 放弃转身】
    end
--【★ 取自身位置】
    local x, y, z = self.Transform:GetWorldPosition()
--【★ 重合位置保护】与 1370 同样的容错。
	if x == dest.x and z == dest.z then
		return
--【★ 与目标重合 → 无需转身】
	end
--★★ / DEGREES + 180 —— 注意这里与 GetAngleToPoint:1372 不同！
--   GetAngleToPoint 用 * RADIANS（弧度→角度），
--   ★ 这里用 / DEGREES（角度→弧度）后再+180。
--   推理依据：atan2(z - dest.z, dest.x - x) 算的是「从目标指向我」的方向，
--   转成弧度后 +180（π弧度）就得到「背对目标」的方向。
--   ⚠ 两种换算写法在同一文件里混用（×RADIANS 与 ÷DEGREES）虽等价
--     （DEGREES = 1/RADIANS），但极不一致，增加了理解与移植风险。
--     建议统一为 * RADIANS。
    self.Transform:SetRotation(math.atan2(z - dest.z, dest.x - x) / DEGREES + 180)
--【★ 弧度转角度 + 180：注意用/ DEGREES 而非 * RADIANS】
end
--【空行】

--★★ IsEntityInFrontConeSlice：前方扇形区域判定
--【★ 三层判定（代价递增）】
--   ① 距离粗筛（若传了 max_dist / circle_dist）—— 最便宜
--   ② 圆形例外（circle_dist）—— 近身无视角度
--   ③ 扇形精确判定（角度 + 距离）—— 最贵
--   ★ 这种「由廉价到昂贵逐级收紧」的短路结构是热路径的标准写法。
function EntityScript:IsEntityInFrontConeSlice(otherinst, wholearcangle_degrees, max_dist, circle_dist)
--【★ 距离参数可选】
    -- Distances are optional.
    -- circle_dist lets a small circle around self to be counted regardless of the angle.
--【★ 距离检查可选】注释说 "Distances are optional." ——
--   不传就只做角度判定（如「面前扇形区域里的所有东西」）。
    if max_dist or circle_dist then
--【★ 距离粗筛：最便宜的检查先做】
        local dsq = self:GetDistanceSqToInst(otherinst)
--【★ circle_dist：一个围绕自己的小圆，圈内一律算「在前面」】
--   原注释："circle_dist lets a small circle around self to be counted
--             regardless of the angle"
--   ★ 典型用途：玩家手里的物品。近距离时玩家手会遮挡视野，
--     若纯按角度判定会漏掉正下方的物品。
        if circle_dist and (dsq < circle_dist * circle_dist) then
--【★ 近身例外：无视角度】
            return true -- This is valid close.
        end
--【★ 超出最远距离直接否】
        if max_dist and (dsq > max_dist * max_dist) then
            return false -- Too far.
--【★ 距离在范围内 → 进入昂贵的角度判定】
        end
--【end：距离粗筛】
    end

    -- More expensive calculations for cone slice.
--【★ 转向角取弧度】
    local rotation = self.Transform:GetRotation()
--★★ forward_vector：把朝向角转成方向向量】
--   Vector3(cos(-rot/RADIANS), 0, sin(-rot/RADIANS))
--   ★ y 分量固定为 0 —— 再次强调 2D 水平面语义。
--   ★ 取负号：Transform 的旋转方向与 atan2 的定义相反（见 1372 的约定），
--     所以要取负才能得到「世界坐标里的朝向」。
--   ★⚠ 这里是全文件最容易搞错的坐标变换：
--     两处负号（rotation 的负号与 cos/sin 的参数）缺一不可。
    local forward_vector = Vector3(math.cos(-rotation / RADIANS), 0 , math.sin(-rotation / RADIANS))
--★ IsWithinAngle(pos, dir, angle, targetpos) —— C++ 侧向量运算。
--   ★ 把整个扇形判定交给 C++，避免在 Lua 里手写点积运算。
   --★ 全角与半角：wholearcangle_degrees / RADIANS 传给 C++（它要弧度）。
--【★ 全角转弧度后交给 C++】
    return IsWithinAngle(self:GetPosition(), forward_vector, wholearcangle_degrees / RADIANS, otherinst:GetPosition())
--【IsEntityInFrontConeSlice 结束】
end
--【空行】

--★★★ IsAsleep：睡眠状态查询 —— 全篇最重要的一个函数
--【★ 实现只有一行，但它是「引擎状态」与「Lua 逻辑」的边界】
--   引擎决定实体何时睡眠（远离玩家、未加载 chunk、长时间无活动），
--   Lua 侧通过它调整自己的行为：
--     · brain 是否启动（1106、405行）
--     · StateGraph 是否运行（1156、409行）
--     · GetDebugString 的标记（972行）
--【★ 与 IsInLimbo:338 的对照 —— 两个正交状态查询】
--   IsAsleep()   —— 引擎层的「休眠」（网络/性能层面的剔除）
--   IsInLimbo()  —— 逻辑层的「虚体」（主动摘出世界）
--   ★ 一个实体可能：醒来+ 在 limbo / 睡着 + 不在 limbo / 睡着 + 在 limbo。
--     理解这一点，就不会把两个概念混为一谈。
--【⚠ 使用注意】IsAsleep 反映的是 C++ 引擎状态，在实体创建后的极短时间内
--   不可信（见 221 行 sleepstatepending）。
--   初始化期间应改用 sleepstatepending 判断。
function EntityScript:IsAsleep()
--【★ 一行实现：直接问引擎是否醒着】
    return not self.entity:IsAwake()
end
--★ IsAsleep 的四个消费点（本文件内）：
--   1106 SetBrain     —— 决定是否禁用新挂的 brain
--   404  ReturnToScene —— 决定是否重启 brain
--   1156 SetStateGraph —— 传给 SGManager 作为初始休眠态
--   972  GetDebugString —— 显示 <ASLEEP> 标记
--   ★★ 全部是「AI 相关」决策 —— 因为睡眠对实体逻辑的影响主要就是停 AI。

--★★ 定时任务封装（1469–1561）：EntityScript 与 Scheduler 之间的适配层
--【★ 所有任务都以 self.GUID 作为归属 id】
--   这样 Remove 时能用 KillTasksWithID / CancelAllPendingTasks 一次清空。
--   ★ 与 StartThread:1070 完全一致的原则。
   --★pendingtasks 结构：{ [Periodic对象] = true }
--   ★ 存 Periodic 对象作为键（而非 id），因为 Cancel 需要对象而非 id。
function EntityScript:CancelAllPendingTasks()
--【★ 遍历中调Cancel —— 一个微妙的陷阱】
--   for k in pairs(self.pendingtasks) do k:Cancel() end
--   ★★ Cancel 会触发 onfinish → task_finish:1480 →
--     `inst.pendingtasks[task] = nil` —— 在遍历中修改正在遍历的表。
--   在 Lua 5.1 中「把当前键置 nil」是**合法且安全**的（不会破坏遍历）。
--   ★ 所以这里是安全的，但依赖于 Lua 的这一保证。
--   ⚠ 若某个 onfinish 回调又**新增**了任务（table.insert 式赋值新键），
--     那就是非法的遍历中新增。极端情况下的隐患。
    if self.pendingtasks then
        for k in pairs(self.pendingtasks) do
            k:Cancel()
        end
        self.pendingtasks = nil
--【★ 协程已结束：置 nil 省内存】
    end
--【CancelAllPendingTasks 结束】
end
--【空行】

--★★ task_finish：所有任务共用的结束回调
--【★ 签名 (task, success, inst) —— 注意第三个参数才是实体】
--   ★ scheduler.lua:110 调 onfinish(self, false, unpack(self.arg))，
--     而所有 Do*Task 都把 self 放在 arg 的第一个位置，
--     所以这里第三个参数是 inst。★ 这个「把 self 塞进 arg 首位」
--     的做法保证了 onfinish 永远能定位宿主实体。
local function task_finish(task, success, inst)
    --print ("TASK DONE", task, success, inst)
    if inst and inst.pendingtasks and inst.pendingtasks[task] then
--【★ 清理登记表条目】
        inst.pendingtasks[task] = nil
    else
--★ "   NOT FOUND" 打印 —— 任务完成时若实体已不在 pendingtasks 里，
--   会打印这个警告。
--   ⚠ 正常情况下不应发生；出现了说明任务登记/清理有 bug。
--     这个自检的价值在于：**它把静默的状态不一致变成了可观测的日志**。
        print ("   NOT FOUND")
    end
--【task_finish 结束】
end
--【空行】

--【★ DoStaticPeriodicTask：走 staticScheduler】
--   ★ 静态调度器不受游戏暂停影响 —— 用于「暂停菜单里也要动的 UI 逻辑」。
--   ★ 签名ExecutePeriodic(time, fn, nil, initialdelay, self.GUID, self, ...)
--     注意第三个参数 limit 传 nil（无限次）。
--★★ 参见 scheduler.lua:424 ExecutePeriodic（周期任务本体）
--   参见 scheduler.lua:330 里「回调内 yield 会导致周期漂移」的警告。
function EntityScript:DoStaticPeriodicTask(time, fn, initialdelay, ...)
--【★ 静态周期任务】
    --print ("DO PERIODIC", time, self)
--★ 第六个参数 self 会进入 arg，展开后成为 onfinish 的第三个参数。
    local per = staticScheduler:ExecutePeriodic(time, fn, nil, initialdelay, self.GUID, self, ...)
--【★ 懒建 pendingtasks】

    if not self.pendingtasks then
        self.pendingtasks = {}
    end
--【★ 登记到待结束集合】

    self.pendingtasks[per] = true
--★ onfinish = task_finish —— 挂在任务对象上，完成时自动回调。
   --★ 原来的内联实现被注释掉，改为共用函数（见 1496 行的被注释代码）。
--   ★ 这种「抽成共用函数」的重构痕迹，保留了决策的上下文。
    per.onfinish = task_finish --function() if self.pendingtasks then self.pendingtasks[per] = nil end end
--【★ 原内联实现被抽成共用函数】
    return per
--【DoStaticPeriodicTask 结束】
end
--【空行】

--【★ DoStaticTaskInTime：静态调度器的一次性延时任务】
--   ★★ 与 DoPeriodicTask 的写法差异值得注意：
--     这里用 `if not self.pendingtasks then self.pendingtasks = {} end`
--     （1511 行处则用 `self.pendingtasks = self.pendingtasks or {}`）
--   ★ 两种写法等价，但同一文件内不统一。
--     后者更简洁，建议统一为后者。
--★★ 参见 scheduler.lua:395 ExecuteInTime —— 实现是 limit=1 的周期任务。
function EntityScript:DoStaticTaskInTime(time, fn, ...)
--【★ 懒建 pendingtasks】
    --print ("DO TASK IN TIME", time, self)
    if not self.pendingtasks then
        self.pendingtasks = {}
    end

--【★ 一次性静态延时任务】
    local per = staticScheduler:ExecuteInTime(time, fn, self.GUID, self, ...)
--【★ 登记】
    self.pendingtasks[per] = true
    per.onfinish = task_finish -- function() if self and self.pendingtasks then self.pendingtasks[per] = nil end end
--【★ 挂结束回调】
    return per
--【DoStaticTaskInTime 结束】
end
--【空行】

--【★ DoPeriodicTask：最常用的定时接口】
--   走常规 scheduler（受暂停影响）。
--   ★ 调用示例：self:DoPeriodicTask(1, function() ... end)
--     period 单位是**秒**（不是 tick）—— 由 scheduler 内部换算。
--★★ 参见 scheduler.lua:431 的返回值使用说明
--   （调用方应保存 Periodic 对象以便 Cancel）。
function EntityScript:DoPeriodicTask(time, fn, initialdelay, ...)
--【★ 常规周期任务】
    --print ("DO PERIODIC", time, self)
    local periodic = scheduler:ExecutePeriodic(time, fn, nil, initialdelay, self.GUID, self, ...)
--【★ 懒建 pendingtasks】

--【★ 登记】
    self.pendingtasks = self.pendingtasks or {}
    self.pendingtasks[periodic] = true
--【★ 挂结束回调】
    periodic.onfinish = task_finish --function() if self.pendingtasks then self.pendingtasks[per] = nil end end
--【空行】
    return periodic
--【DoPeriodicTask 结束】
end
--【空行】

--【★ DoTaskInTime：延时执行一次】=周期任务且 limit=1。
function EntityScript:DoTaskInTime(time, fn, ...)
--【★ 常规一次性延时任务】
    --print ("DO TASK IN TIME", time, self)
    local periodic = scheduler:ExecuteInTime(time, fn, self.GUID, self, ...)
--【★ 懒建 pendingtasks】

--【★ 登记】
    self.pendingtasks = self.pendingtasks or {}
    self.pendingtasks[periodic] = true
--【★ 挂结束回调】
    periodic.onfinish = task_finish -- function() if self and self.pendingtasks then self.pendingtasks[per] = nil end end
--【空行】
    return periodic
--【DoTaskInTime 结束】
end
--【空行】

--★ PushEventInTime(time, eventname, data)
--【★ 便利函数：定时 PushEvent，等价于 DoTaskInTime + PushEvent】
--   ★ 这个函数的存在本身就说明「延迟事件」在游戏逻辑里极其常见
--     （如「3 秒后这个火把熄灭」）。
function EntityScript:PushEventInTime(time, eventname, data)
--【★ 懒建 pendingtasks】
    self.pendingtasks = self.pendingtasks or {}

--【★ 闭包包一层：把 eventname/data 绑进回调】
    local event_function = function(inst)
        inst:PushEvent(eventname, data)
--【★ 真正的事件投递】
    end
    local periodic = scheduler:ExecuteInTime(time, event_function, self.GUID, self, data)
--【★ 登记】
    self.pendingtasks[periodic] = true
    periodic.onfinish = task_finish
--【★ 挂结束回调】
    return periodic
--【PushEventInTime 结束】
end
--【空行】

--【★ GetTaskInfo / TimeRemainingInTask：给状态图用的「任务进度」】
--   返回 { start=GetTime(), time=期望时长 }，
--   TimeRemainingInTask 回传剩余秒数（最小 1）。
--   ★ 用途：攻击判定中的「蓄力进度条」——
--     状态图知道期望时长，就能画出进度条并在完成时播放动画。
function EntityScript:GetTaskInfo(time)
    local taskinfo = {}
    taskinfo.start = GetTime()
    taskinfo.time = time
--【★ 记录起始时刻与期望时长】
    return taskinfo
--【GetTaskInfo 结束】
end
--【空行】

function EntityScript:TimeRemainingInTask(taskinfo)
    local timeleft = (taskinfo.start + taskinfo.time) - GetTime()
--★ `timeleft < 1 and 1 or timeleft` —— ★ 强制最小返回 1 秒。
--   推测意图是「至少显示 1 格进度」，避免除以极小数时进度条爆炸。
--   ⚠ 但这也意味着剩余时间为负时（比如已完成）仍返回 1，
--     调用方不能用返回值判断「是否已完成」。
--   → 更清晰的做法是同时返回 (timeleft, isdone)。
--【★ 迟滞夹取到最小 1（见分析）】
--★★ 参见 scheduler.lua:110 onfinish 的调用方式
--   —— 本函数的 TimeRemainingInTask 与之配套，供状态图算进度。
    return (timeleft < 1 and 1) or timeleft
--【TimeRemainingInTask 结束】
end
--【空行】

--【★ ResumeTask：DoTaskInTime + GetTaskInfo 的一站式封装】
--   返回 task, taskinfo —— 调用方立刻就能算出进度。
   --★ 命名 "ResumeTask" 有歧义：这里不是「恢复」，而是「恢复一个任务的进度条」。
function EntityScript:ResumeTask(time, fn, ...)
    local task = self:DoTaskInTime(time, fn, ...)
--【★ 配一份进度信息】
    local taskinfo = self:GetTaskInfo(time)

    return task, taskinfo
--【ResumeTask 结束】
end
--【空行】

--★★★ BufferedAction 体系（1563–1691）：玩家操作的执行链路
--【★ 概念】
--   bufferedaction =「我现在想做的事」：{ action, target, invobject, options, args }。
--   它在「玩家按键」「动作可用性检查」「实际执行」之间充当中间态。
--【★ 三个阶段对应三个方法】
--   PreviewBufferedAction (1572) —— 按下鼠标时，预览效果（如高亮目标）
--   PushBufferedAction     (1609) —— 松开鼠标，真正开始执行
--   PerformBufferedAction  (1654) —— 执行的那一刻，由状态图或外部触发
--   ★ 三阶段的分离是为了「可撤销」：预览阶段还能反悔。
function EntityScript:ClearBufferedAction()
    if self.bufferedaction ~= nil then
--【★ Fail()：把动作标记为失败并做清理（如播放失败音效）】
--   ★ 先 Fail 再置 nil：若Fail 的回调里还要读 self.bufferedaction，
--     此时它仍然有效 —— 顺序不能反。
        self.bufferedaction:Fail()
        self.bufferedaction = nil
    end
--【ClearBufferedAction 结束】
end
--【空行】

--【★ InterruptBufferedAction 是 ClearBufferedAction 的别名】
--   ★ 语义上「中断」比「清空」更贴切（会触发 Fail）。
--   两个名字对应两种心智模型，属历史遗留的双命名。
EntityScript.InterruptBufferedAction = EntityScript.ClearBufferedAction
--【空行】

--★★ PreviewBufferedAction：按下鼠标时的预览
--【★ 第一个守卫：去重】
--   若「新动作」与「已有动作」的 target/action/invobject 完全相同，则跳过。
--   ★ 作用：避免同一次点击被处理两遍（如鼠标按下事件重复触发）。
--   ★ 第四个条件（not (sg idle 且 HasTag idle)）是「已经空闲则不必预览」。
function EntityScript:PreviewBufferedAction(bufferedaction)
    if bufferedaction ~= nil and
        self.bufferedaction ~= nil and
        bufferedaction.target == self.bufferedaction.target and
        bufferedaction.action == self.bufferedaction.action and
        bufferedaction.invobject == self.bufferedaction.invobject and
--★ 注意此处的条件比 PushBufferedAction:1615 多了一个 `and self:HasTag("idle")`。
--   ⚠ 疑似不对称：预览时要求「状态图 idle 且实体有 idle 标签」，
--     真正执行时只要求「状态图 idle」。
--     推理依据：两处守卫代码几乎逐字相同，差异只在这一项。
--     可能是预览与执行的判定确实不同，也可能是一方漏改。
--     → 建议核对业务预期后统一。
        not (self.sg ~= nil and self.sg:HasStateTag("idle") and self:HasTag("idle")) then
--【★ 去重条件不满足 → 直接跳过】
        return
    end
--【★ 四路分派开始】

--★ WALKTO（走路）：无副作用，直接清空。
--   ★ 注释解释得很清楚："walkto is kind of a nil action"（见 1630 行）——
--     移动由 locomotor 组件自己完成，这个 action 只是历史包袱。
    if bufferedaction.action == ACTIONS.WALKTO then
--【★ WALKTO 清空即可】
        self.bufferedaction = nil
--★ options.instant —— 按选项立即执行（如吃药不走路直接生效）。
--   ★ 与 1592 行的 action.instant 区分：
--     options 是这次调用的覆盖选项，action 是动作定义本身的属性。
--     两者任一为真即走立即路径（见 1635 的 PushBufferedAction 对照）。
	elseif bufferedaction.options.instant then
		self.bufferedaction = bufferedaction
--【★ 立即执行预览】
		self:PerformPreviewBufferedAction()
--★★ 有状态图 → 交给状态图预览】
--   sg:PreviewAction 返回 false 表示状态图不认这个动作 → 清空。
--   ★ 状态图的 OnPreviewaction 里通常会播放「拔刀」等起手动画。
    elseif self.sg ~= nil then
        self.bufferedaction = bufferedaction
--【★ 状态图不接受 → 清空】
        if not self.sg:PreviewAction(bufferedaction) then
            self.bufferedaction = nil
--【★ 清空】
        end
--★ 无状态图但动作本身是 instant（如戳一下）→ 直接执行预览。
    elseif bufferedaction.action.instant then
        self.bufferedaction = bufferedaction
--【★ 动作自带 instant 属性】
        self:PerformPreviewBufferedAction()
    else
--【★ 其他情况：清空（该实体不做这件事）】
        self.bufferedaction = nil
    end
--【PreviewBufferedAction 结束】
end
--【空行】

--【★ PerformPreviewBufferedAction：真正执行预览】
--   ispreviewing 标记防止重复执行（鼠标按住会连续发事件）。
--   ★ playercontroller 的 RemoteBufferedAction 是远程转发 ——
--     客户端按下鼠标时把动作转发给服务端执行，这是联机架构的一环。
function EntityScript:PerformPreviewBufferedAction()
--【★ 尚未在预览中才执行】
    if self.bufferedaction ~= nil and not self.bufferedaction.ispreviewing then
        if self.components.playercontroller ~= nil then
            self.components.playercontroller:RemoteBufferedAction(self.bufferedaction)
        end
        self.bufferedaction.ispreviewing = true
    end
--【PerformPreviewBufferedAction 结束】
end
--【空行】

--★★ PushBufferedAction：真正的动作提交
--【★ 五步流程】
--   ① 去重守卫（与 Preview 同构）
--   ② 清掉旧动作（Fail 并置 nil）
--   ③ TestForStart 可用性测试（距离、目标类型、资源是否够）
--   ④ 分派：WALKTO / instant / 交给状态图
--   ⑤ 失败路径统一发 actionfailed 事件
function EntityScript:PushBufferedAction(bufferedaction)
    if bufferedaction ~= nil and
--【★ 去重守卫开始】
        self.bufferedaction ~= nil and
        bufferedaction.target == self.bufferedaction.target and
        bufferedaction.action == self.bufferedaction.action and
        bufferedaction.invobject == self.bufferedaction.invobject and
        not (self.sg ~= nil and self.sg:HasStateTag("idle")) then
        return
    end
--【★ 已有动作 → Fail 并清空】

    if self.bufferedaction ~= nil then
--【★ 先让旧动作失败（做清理）】
        self.bufferedaction:Fail()
        self.bufferedaction = nil
    end
--【★ 可用性测试结束】

--★ TestForStart 返回 (success, reason) —— reason 用于 UI 提示。
   --★ actionfailed 事件让 UI 能显示「太远了」「材料不够」等反馈。
    local success, reason = bufferedaction:TestForStart()
    if not success then
        self:PushEvent("actionfailed", { action = bufferedaction, reason = reason })
--【★ 失败 → 通知 UI】
        return
    end
--【★ 三路分派开始】

--★★ 原注释精辟："walkto is kind of a nil action - the locomotor will
--            have put us at the destination by now if we get to here"
--   翻译：走到这里时 locomotor 组件早已把位置处理好了，
--   所以这个 action 实际上什么都不用做，直接标记成功即可。
--   ★ 这解释了为什么它是「历史包袱」——移动逻辑在 locomotor 里，
--     WALKTO 只是触发移动的信号。
    --walkto is kind of a nil action - the locomotor will have put us at the destination by now if we get to here
    if bufferedaction.action == ACTIONS.WALKTO then
        self:PushEvent("performaction", { action = bufferedaction })
--【★ 走完了 → 直接标成功】
        bufferedaction:Succeed()
--【★ 清空缓冲动作】
        self.bufferedaction = nil
--★ instant 判定合并了 action.instant 与 options.instant（与 1584 对称）。
	elseif bufferedaction.action.instant or bufferedaction.options.instant then
--★★ 立即动作前先转身 —— 三个条件层层收紧】
--   ① target 存在且有 Transform（防无效目标）
--   ② sg == nil 或状态图有 "canrotate" 标签
--   ★ "canrotate" 标签：状态图可以禁止旋转（如正在攻击的僵直帧）。
--   ★ 注意这里调的是 FacePoint（受 busy 检查）而非 ForceFacePoint，
--     所以与 1391 的仲裁机制一致。
        if bufferedaction.target ~= nil and bufferedaction.target.Transform ~= nil and (self.sg == nil or self.sg:HasStateTag("canrotate")) then
            self:FacePoint(bufferedaction.target.Transform:GetWorldPosition())
--【★ 立即动作前转身】
        end
        self:PushEvent("performaction", { action = bufferedaction })
        bufferedaction:Do()
--【★ 清空】
        self.bufferedaction = nil
--★★★ 常规路径：交给状态图编排】
--   ★ 无状态图 → 直接 PushEvent("startaction")，
--     监听者（通常是组件）会自己处理。这是「无 AI 的实体」的做法。
--   ★ 有状态图 → sg:StartAction，状态图的 OnStartaction 决定后续。
    else
--【★ 常规路径：交给状态图】
        self.bufferedaction = bufferedaction
        if self.sg == nil then
--【★ 无 sg → 直接发 startaction】
            self:PushEvent("startaction", { action = bufferedaction })
--★★ 状态图拒绝时的兜底：直接执行并立即失败】
--   若 sg:StartAction 返回 false（状态图不接受），
--   代码选择「立刻执行它，然后标记失败」——
--   ⚠ 疑似缺陷：先 PushEvent("performaction") 再 Fail()，
--     意味着动作**已经被执行了**（例如已扣掉材料）却又被标记为失败。
--     推理依据：PushEvent("performaction") 的监听者会真的去做事。
--     更合理的顺序是先 Fail 不执行，或干脆忽略该动作。
--     （不过在实机中 StartAction 很少返回 false，故未暴露。）
        elseif not self.sg:StartAction(bufferedaction) then
--【★ sg 拒绝 → 直接执行】
            self:PushEvent("performaction", { action = bufferedaction })
            self.bufferedaction:Fail()
--【★ 标记失败并清空】
            self.bufferedaction = nil
        end
--【end：常规路径】
    end
--【PushBufferedAction 结束】
end
--【空行】

--★★★ PerformBufferedAction：动作的实际执行时刻
--【★ 由谁调用？】
--   通常是状态图的某个状态在 OnPerformaction 中调；
--   也可能被组件（如 locomotor 走完后）直接调。
--   ★ 这个「二段式」设计让长动作可以分段（走路→ 到达 → 交互）。
function EntityScript:PerformBufferedAction()
    if self.bufferedaction then
--★★ 三重有效性校验（目标有效 + 有 Transform）】
--   ★ 长动作执行时目标可能已被摧毁（如对方跑掉了）。
--     这是「动作开始于目标存在时，结束于可能不存在时」的必然。
        if self.bufferedaction.target and self.bufferedaction.target:IsValid() and self.bufferedaction.target.Transform then
--【★ 执行前先转身】
            self:FacePoint(self.bufferedaction.target.Transform:GetWorldPosition())
        end
--【★ 通知各监听者开始执行】

        self:PushEvent("performaction", { action = self.bufferedaction })
--【空行】

--★ 动作专属 BGM：只有玩家才播（敌人拔刀不发音效，避免暴露）。
--   theme_music_fn 是动态版本（可依赖动作的运行时状态）。
		local action_theme_music = self:HasTag("player") and (self.bufferedaction.action.theme_music or (self.bufferedaction.action.theme_music_fn ~= nil and self.bufferedaction.action.theme_music_fn(self.bufferedaction)))
		if action_theme_music then
			self:PushEvent("play_theme_music", {theme = action_theme_music})
--【★ BGM 事件：仅玩家】
		end
--【end：BGM 分支】

--★★ 缓存 bufferedaction 到局部变量 —— 一个精妙的防御】
--   ★ 原因（原注释）：self.bufferedaction 可能在 PushEvent 的回调中被改变！
--     比如某个监听者调用了 ClearBufferedAction 或推入了新动作。
--   ★ 用局部变量保证后面 Do() 的是「原本要执行的那个」。
		local bufferedaction = self.bufferedaction
--★★V2C 原注释列出了三个关键点】
--   "- cahced in case self.bufferedaction changes"  ← 缓存（防回调中改变）
--   "- ideally, should clear self.bufferedaction here" ← 理想情况下应在此清空
--   "- however, legacy code might rely on inst.bufferedaction during Do()"
--     ← ★ 但遗留代码在Do() 期间还依赖 inst.bufferedaction
--   ★★ 这是「为了兼容历史代码而保留技术债」的明证。
--     清理被推迟到 Do() 之后（1674-1676），用相等性检查确保不误清新动作。
--   → 移植/重构时的建议：新代码不应在 Do() 期间读 inst.bufferedaction。
		--@V2C: - cahced in case self.bufferedaction changes
		--      - ideally, should clear self.bufferedaction here
		--      - however, legacy code might rely on inst.bufferedaction during Do()

--★ Do() 返回 (success, reason) —— 真正干活的地方（在 bufferedaction.lua）。
--【★ 真正干活】
		local success, reason = bufferedaction:Do()
--★★ 成功后「条件性清空」】
--   `if self.bufferedaction == bufferedaction then self.bufferedaction = nil end`
--   ★★ 这个相等性检查极其重要：
--     若 Do() 内部有回调压入了**新**动作，无条件置 nil 会把新动作丢掉。
--     只有确认「当前缓冲的仍是刚才那个」才清空。
--   ★ 这是「重新入队安全」模式，在事件驱动的 UI 代码中也很常见。
        if success then
--【★ 条件性清空：防止误清回调中压入的新动作】
			if self.bufferedaction == bufferedaction then
				self.bufferedaction = nil
			end
--【★ 成功即返回】
            return true
        end
--【★ 失败 → 发 actionfailed】

--【★ 失败路径同样是「条件性清空」】
--   先 PushEvent("actionfailed") 让 UI 播提示，
--   再 Fail()（可能做音效清理），最后条件性清空。
--   ★ 顺序与成功路径对称（先事件后清空）。
		self:PushEvent("actionfailed", { action = bufferedaction, reason = reason })
--【★ Fail 做清理】

		bufferedaction:Fail()
		if self.bufferedaction == bufferedaction then
			self.bufferedaction = nil
		end
    end
--【PerformBufferedAction 结束】
end
--【空行】

--★★ GetBufferedAction：三级回退取当前动作】
--   ① self.bufferedaction      —— 本实体自己的
--   ② components.locomotor.bufferedaction —— ★ 移动组件代存的
--   ③ nil
--   ★ 第②级的原因：WALKTO 期间，「走向某处」这个动作存在 locomotor 里
--     而不是本实体上（如「走向野莓丛再采摘」是两个动作）。
--   ⚠ 第②级直接访问 locomotor 内部字段而非方法，破坏了封装；
--     正确做法是给 locomotor 加一个 GetBufferedAction() 方法。
function EntityScript:GetBufferedAction()
--【★ locomotor 代存的动作作为次选】
    return self.bufferedaction or (self.components.locomotor ~= nil and self.components.locomotor.bufferedaction) or nil
end
--【空行】

--【★ OnBuilt：建造完成回调（向后转发给所有组件）】
--【★ 顺序：先组件（按 pairs 顺序，无保证）再 OnBuiltFn】
--   为什么组件优先？因为 builder 可能是 prefab 脚本的处理函数，
--   ★ 它通常会读组件状态。
--   ⚠ 但 pairs 顺序不确定 → **组件之间的 OnBuilt 执行顺序不确定**。
--     若两个组件的 OnBuilt 有依赖，需改为显式排序或放到 OnBuiltFn 里。
function EntityScript:OnBuilt(builder)
    for k,v in pairs(self.components) do
--【★ 有 OnBuilt 的组件才转发】
        if v.OnBuilt then
            v:OnBuilt(builder)
        end
--【end：组件遍历】
    end

--★ OnBuiltFn：prefab 脚本可覆写的钩子（约定式命名）。
--   ★ 「OnBuiltFn」而非「OnBuilt」是为了避开已用的函数名，
--     但同一个对象上两个不同名字做同一件事，容易混淆。
    if self.OnBuiltFn then
--【★ prefab 钩子在组件之后】
        self:OnBuiltFn(builder)
    end
--【OnBuilt 结束】
end
--【空行】

--★★★ ★ ★ Remove —— 实体的完整销毁流程（全文件最长最关键的函数）★★★
   --★【执行顺序的六步，顺序本身就是设计】
--   步骤0 （1706-1712）：先从父实体/ 平台脱离 ——
--        ★ 必须在通知任何人之前完成，否则父实体也会被级联删除。
--   步骤1 （1714）：OnRemoveEntity(GUID) —— 通知全局管理器
--        ★ SGManager / BrainManager / 地图 / etc 在此摘除本实体。
--   步骤2 （1716）：PushEvent("onremove") —— 让业务逻辑做最后清理
--   步骤3 （1719-1721）：★ 断开所有对外连接（防泄漏三件套）
   --        StopAllWatchingWorldStates / RemoveAllEventCallbacks /
   --        CancelAllPendingTasks
--   步骤4 （1723-1733）：通知组件与副本组件 OnRemoveEntity
--   步骤5 （1735-1752）：从所有全局更新表摘除自己
--   步骤6 （1754-1765）：处理子实体与平台跟随者
--   步骤7 （1767-1771）：prefab 钩子 + 置 persists=false + C++ Retire
function EntityScript:Remove()
--【步骤0-a：从父实体脱离】
--   ★ 注意是 RemoveChild（只解绑不删除），父实体仍存活。
    if self.parent then
--【★ 先脱离父实体】
        self.parent:RemoveChild(self)
    end

    if self.platform then
--【★ 再脱离平台】
        self.platform:RemovePlatformFollower(self)
    end
--【空行】

--★★ 步骤1：通知全局管理器 —— 最容易被忽视却最关键的一步】
--   OnRemoveEntity(self.GUID) 会让所有注册了全局钩子的系统摘除本实体：
--     · SGManager:OnRemoveEntity     → 移除状态图实例（stategraph.lua:77）
--     · BrainManager:OnRemoveEntity   → 移除大脑（brain.lua:11）
--     · 其他：地图、实体列表、网络连接等
--   ★★ 若这一步缺失，所有全局表里都会残留已销毁的实体 → 每次遍历都白跑。
--   ⚠ 注意它传的是 GUID 而非实例，说明各系统按 GUID 建索引。
    OnRemoveEntity(self.GUID)

--★★ 步骤2：onremove 事件】
--   ★ 必须在断开事件连接**之前**推送 —— 因为清理步骤3会清空 event_listeners。
--     这是一个「先通知，后静默」的顺序，若颠倒则无人能收到事件。
--   ★ 这是本函数里最容易被后人「优化」错的一处顺序。
    self:PushEvent("onremove")
--【★ 防泄漏三件套开始】

--★ 原注释："tell our listeners to forget about us" —— 防泄漏三件套的总说明。
    --tell our listeners to forget about us
--★★ 步骤3 之一：断开世界状态观察】
--   ★ 若不断，worldstate 组件下次变化时会调用已销毁实体的回调 → 崩溃。
    self:StopAllWatchingWorldStates()
--★★ 步骤3 之二：断开所有事件连接（正反双向）】
--   详见 1232行的 RemoveAllEventCallbacks 详解。
   --★ 这是防止「悬垂回调」的最后一道闸门。
    self:RemoveAllEventCallbacks()
--★★ 步骤3 之三：取消所有定时/周期任务】
--   ★ 配合 1065 的 KillTasks（协程），共同保证「没有东西还会回来碰这个实体」。
--   ★★ 防泄漏三件套 + KillTasks = 四道闸门，缺一不可。
    self:CancelAllPendingTasks()
--【end：三件套】

--★★ 步骤4-a：遍历组件调用 OnRemoveEntity】
--【★ type(v) == "table" 的双重校验】
--   防御两种情况：① components[k] 为 nil；② 某项不是 table（脏数据）。
--   ⚠ 疑似缺陷：在 pairs(self.components) 遍历中，
--     若某个组件的 OnRemoveEntity 调了 RemoveComponent，
--     就会在遍历中修改 self.components ——
--     置 nil 当前键是安全的，但若新增键则可能出问题。
--     实践中 RemoveComponent 在此处调用较少，故未暴露。
--     → 稳妥做法是先复制一份组件列表再遍历。
--【★ 遍历顺序不确定：pairs 的哈希顺序】
--   ★ 因此组件的 OnRemoveEntity 之间**没有执行顺序保证**。
--     若两个组件的清理互相依赖，必须改为显式排序。
    for k, v in pairs(self.components) do
        if v and type(v) == "table" and v.OnRemoveEntity then
            v:OnRemoveEntity()
        end
    end
--【★ 组件通知结束】

--★★ 步骤4-b：遍历副本组件调用 OnRemoveEntity】
--   ★★ 必须用 rawget(self.replica, "_") —— 
--     若写 self.replica._ 触发 __index 钩子会走到 ValidateReplicaComponent，
--     产生额外的 HasTag 调用。rawget 直接拿到底层表。
--   ★ 副本组件也需要清理：它们也有定时器（如 inventory 的 UI 刷新）。
--★★ 参见 entityreplica.lua:46 rawset(self.replica._, name, ...)
--   —— 本行的 rawget 正是读同一张表，必须绕过 __index 钩子。
    for k, v in pairs(rawget(self.replica, "_")) do
        if v and type(v) == "table" and v.OnRemoveEntity then
--【★ 副本通知】
            v:OnRemoveEntity()
        end
--【end：副本遍历】
    end
--【★ 全局表摘除开始】

--★★ 步骤5：从全局更新表摘除】
--【★ 计数器递减的唯一出口之二（另一处是 489 行）】
--   ★ 条件是 `if self.updatecomponents then` —— 
--     只有曾经注册过才递减，精确对应 447 行的递增。
--   ★★ 三级清理（普通/静态/墙）都必须做，且普通的那张有计数、另两张没有，
--     这种不对称让漏改成为可能。
--   ⚠ 建议：统一封装成 update.lua:1740 那种「无条件清New表」的形式。
    if self.updatecomponents then
        self.updatecomponents = nil
        UpdatingEnts[self.GUID] = nil
        num_updating_ents = num_updating_ents - 1
--【end：普通更新表】
    end
--★ 新增实体表无条件清理（不判 updatecomponents 是否存在）。
--   ★ 必要性：实体可能在「已加入 New 表但尚未并表」时就被销毁，
--     此时 updatecomponents 为 nil（已被 1736 清掉），
--     若不无条件清 NewUpdatingEnts，帧末并表会让它复活 → ★ 已销毁实体复活。
--   ★ 这是三张New 表都必须无条件清理的原因。
    NewUpdatingEnts[self.GUID] = nil
--【★ 静态更新表】

    if self.updatestaticcomponents then
        self.updatestaticcomponents = nil
        StaticUpdatingEnts[self.GUID] = nil
--【end：静态更新表】
    end
    NewStaticUpdatingEnts[self.GUID] = nil
--【★ 墙更新表】

    if self.wallupdatecomponents then
        self.wallupdatecomponents = nil
        WallUpdatingEnts[self.GUID] = nil
--【end：墙更新表】
    end
    NewWallUpdatingEnts[self.GUID] = nil
--【★ 子实体与跟随者处理】

--★★ 步骤6-a：级联删除子实体】
--   ★ k.parent = nil 先断开反向引用，再调k:Remove()。
--   ★ 不调RemoveChild 是因为父实体自己正在销毁，
--     RemoveChild 会去改一个即将被丢弃的表，纯属浪费。
--   ⚠ 遍历中修改 self.children（k:Remove() 内部可能调 parent:RemoveChild，
--     但 parent 已置 nil 所以不会）—— 当前实现是安全的。
   --⚠ 但 self.children 在循环后没被置 nil，白留一个即将被丢弃的表引用。
    if self.children then
        for k in pairs(self.children) do
            k.parent = nil
            k:Remove()
--【★ 级联删除子实体】
        end
    end
--【★ 平台跟随者：只解绑不删除】

--★★ 步骤6-b：平台跟随者只解绑不删除】
--   ★★ 与子实体处理的根本差异：
--     子实体是「我的的一部分」→ 级联删除
--     平台跟随者是「站在我身上的独立实体」→ 只解除跟随
--   ★ 举例：船被摧毁，乘客不该跟着消失（否则玩家会莫名死亡）。
--     这里只把 k.platform = nil，让它落在原地。
    if self.platformfollowers then
        for k in pairs(self.platformfollowers) do
            k.platform = nil
        end
--【end：平台跟随者】
    end
--【★ prefab 最终钩子】

--★ 步骤7-a：prefab 脚本的最终钩子 OnRemoveEntity】
--   ★ 放在最后：此时所有基础设施都已清理，
--     prefab 脚本可以做最彻底的收尾（如显示死亡特效的宿主标记）。
    if self.OnRemoveEntity then
        self:OnRemoveEntity()
--【end：prefab 钩子】
    end
--★★ 步骤7-b：persists = false】
--   ★ 时机精准：在 Retire 之前。
--   若此刻触发一次存档，已销毁的实体不该被写入。
   --★ 这是一处「防竞态」的细节：存档系统按 persists 字段筛选实体。
--【★ persists=false 与存档系统的协作】
--   ★ GetPersistData:1903 会检查 self.persists 吗？—— 不会。
--     实际上 persists 由更上层（mainfunctions 的存档流程）检查。
--   ⚠ 但 Retire 之后 C++ 侧的实体已经无效，上层遍历 Ents 时自然遇不到。
--     所以这行更像是「防御性标注」—— 明确表达「此刻我不该被存档」。
    self.persists = false
--★★ 步骤7-c：entity:Retire() —— 交还给 C++】
--   ★ Retire 而非 Delete：Retire 会通知网络层「这个实体要消失了」，
--     让客户端正确地把它删掉，然后延迟释放资源。
--   ★★至此 Lua 侧的工作全部结束。C++ 侧会做它自己的清理，
--     并且可能回调某些 Entity 级的方法。
--   ★ 这是「Lua 管理逻辑、C++ 管理资源」分界的最后一行代码。
    self.entity:Retire()
end
--【空行】

--★★ IsValid：实体有效性 —— 全游戏最热也最容易被误用的函数
--【★ 直接转发 C++】因为实体有效性由 C++ 侧决定（Retire 时标记），
--   Lua 无法自行判断。
--【★★ 何时为 false？】
--   · entity:Retire() 之后 → Remove:1771 的最后一步
--   · Remove 过程中已 Retire 但 Remove 尚未跑完（短暂窗口）
--   · 世界卸载时批量 Retire
--【★ 使用纪律】
--   持有 EntityScript 引用的代码，在访问 Transform/components 前必须判 IsValid。
--   ★ 最危险的是「异步」场景：
--     StartThread 里的实体引用可能在下次 resume 时已失效；
--     PushEvent 的回调里，目标实体可能刚被上一个监听者删除。
--   ★ 参见 1290 行的拷贝列表方案，它正是为了规避这类问题。
--★★ 参见 stategraph.lua:77 SGManager:OnRemoveEntity
--   brain.lua:11 BrainManager:OnRemoveEntity
--   —— 二者都靠本文件的 Remove:1714 触发。
function EntityScript:IsValid()
--【★ 直接问引擎】
    return self.entity:IsValid()
end
--【空行】

--★★ CanInteractWith：能否与某实体交互
--【★ 语义：只能交互「世界中的」或「自己的」东西】
--   若目标的父实体存在且不是自己 → 拒绝。
--【★ 为什么需要这个？】
--   一个放在背包里的物品，它的 parent 是背包容器。
--   ★ 若不检查，玩家拿着物品 A 时对着背包里的物品 B 按右键，
--     逻辑上会「对自己背包里的东西交互」——这显然不对。
--   参见 components/inventoryitem.lua:349 正是「入包即移出场景」的逻辑。
   --★ 逻辑上等价于「目标没有父，或父是我」。
function EntityScript:CanInteractWith(inst)
--【★ 无效目标直接拒绝】在读 parent 之前必须判，否则是访问已释放对象。
    if not inst:IsValid() then
--【★ 取 C++ 侧的父实体】
        return false
    end
    local parent = inst.entity:GetParent()
    return (parent == nil) or (parent == self)
--【CanInteractWith 结束】
end
--【空行】

--【OnUsedAsItem：向后转发给所有组件】
--   当该实体被当作「物品」使用（如「给牛刷毛」）时调用。
--   ★ 与 OnBuilt:1694 结构完全相同 —— 都是「广播给组件」。
--   ★ 注意只转发给 components，不含 replica ——
--     因为该操作在服务端权威执行。
function EntityScript:OnUsedAsItem(action, doer, target)
    for k,v in pairs(self.components) do
--【★ 有该钩子的组件才转发】
        if v.OnUsedAsItem then
            v:OnUsedAsItem(action, doer, target)
        end
--【★ 转发】
    end
--【OnUsedAsItem 结束】
end
--【空行】

--★★★ CanDoAction：能否执行某个动作 —— 动作系统的统一入口
--【★ 四级判定（任一通过即返回 true）】
--   ① 固有能力（inherentactions，含网络的 inherentsceneaction）
--   ② <action.id>_tool 标签 —— 该动作需要某类工具
--   ③ 手上（inventory 手持位）物品能做
--   ④ 已装备的（EQUIPSLOTS.HANDS）物品能做
   --★ 注意②的标签命名法：动作 id + "_tool"（如 "chop_tool"），
--     这是 DST 里「工具类需求」的标准表达方式。
function EntityScript:CanDoAction(action)
--【★ 固有能力优先】即使手里拿着东西，实体自带的动作仍可用。
--   因为 inherentactions 在客户端也会被 DeserializeInherentActions:119 同步，
--   ★ 这让客户端能在本地预判「这个动作是否可用」而无需问服务端。
    if self.inherentactions ~= nil and self.inherentactions[action] then
        return true
--【★ 标签方式判定：<actionid>_tool】
    end
    if self:HasTag(action.id.."_tool") then
        return true
    end
--★ ★ 用 replica 而非 components —— 因为该函数要在客户端也能跑。
--   ★ 客户端实体没有 components，只有 replica。
--   与 GetIsWet:777 完全一致的双端访问范式。
    local inventory = self.replica.inventory
    if inventory ~= nil then
        local item = inventory:GetActiveItem()
--【★ 手持物能做 → 可执行】
        if item ~= nil and item:CanDoAction(action) then
            return true
        end
--★ 同时检查已装备的双手物品 —— 盾、工具类装备也算。
--   ★ 两处检查的原因：inventory 的「手持物」与「装备槽物品」是两个概念。
        item = inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
        if item ~= nil and item:CanDoAction(action) then
            return true
--【★ 装备物能做 → 可执行】
        end
--【end：replica.inventory 分支】
    end
--【CanDoAction 结束】
end
--【空行】

--★★ IsOnValidGround：脚下是否是合法地面
--【★ 原注释的重要警告】"this currently does not support boats."
--   ★即：站在船上的生物会得到错误答案（船不是「地面」）。
--     注释同时给出建议：「IsOnPassablePoint may be what you actually want to call」
--   ⚠ 这个缺陷在「船上的牛想刨地」这类逻辑上会产生 bug。
--     根本原因：IsVisualGroundAtPoint 查的是地形网格，
--     而船是动态平台，不在地形网格里。
function EntityScript:IsOnValidGround() -- this currently does not support boats. IsOnPassablePoint may be what you actually want to call
--【★ 不支持船：直接问视觉地面】
	return TheWorld.Map:IsVisualGroundAtPoint(self.Transform:GetWorldPosition())
end
--【空行】

--【★ 两个可选参数都做了 or false 归一】
--   传入 nil 与 false 等价，保证C++ 侧收到确定的布尔值。
--   ★ floating_platforms_are_not_passable：
--     「飘浮平台不算可通行」—— 用于「雕像能否把东西放上去」这类判定。
function EntityScript:IsOnPassablePoint(include_water, floating_platforms_are_not_passable)
    local x, y, z = self.Transform:GetWorldPosition()
--【★ 两个可选参数归一为 false】
    return TheWorld.Map:IsPassableAtPoint(x, y, z, include_water or false, floating_platforms_are_not_passable or false)
end
--【空行】

--【IsOnOcean：是否在海里】allow_boats 控制「船算不算海」。
function EntityScript:IsOnOcean(allow_boats)
    local x, y, z = self.Transform:GetWorldPosition()
--【★ allow_boats 控制「船算不算海」】
    return TheWorld.Map:IsOceanAtPoint(x, y, z, allow_boats)
end
--【空行】

--deprecated
--deprecated
--★ 保留旧名 IsOnWater 作为别名，避免破坏模组代码。
--★ 与 327 行的 StackableSkinHack 同属「明知废弃但保留」的兼容性做法。
EntityScript.IsOnWater = EntityScript.IsOnOcean

--★★★ GetCurrentPlatform：递归向上查找所属平台
--【★ 主/客双端两套实现 —— 原因见下】
--【★ 为什么必须递归？】
--   组合链很常见：牛站在船上，牛身上站着乘客。
--   ★ 此时牛.GetCurrentPlatform() 应返回船（递归向上）。
--   函数名里的 "Current" 就是这个意思——「最终所属的平台」。
   --★ 对照 1833：主模拟用 self.parent（Lua 侧记账），
--     客户端用 self.entity:GetParent()（C++ 侧记账）。
--【★ 递归查找最终所属平台】
function EntityScript:GetCurrentPlatform()
--【★TheWorld.ismastersim —— 主/客分支的唯一依据】
--   ★ 这是 DST 双端架构的核心标志位：
--     主模拟（服务端）有权威状态（components、平台记账），
--     客户端只有副本（replica）与引擎侧的变换关系。
--   ★ 本文件里这样的分支出现在 1832、194、776、797 等多处，
--     每一个都意味着「此处两端行为不同，写代码时必须小心」。
    if TheWorld.ismastersim then
--★ 递归顺序：先问父实体的平台，再问自己站着的平台。
--   ★ 注意父实体的 GetCurrentPlatform 是「方法调用」，会继续递归上去。
        return (self.parent ~= nil and self.parent:GetCurrentPlatform())
            or self.platform
    else
--【★ 客户端：用 C++ 侧的父实体】
        local parent = self.entity:GetParent()
        return (parent ~= nil and parent:GetCurrentPlatform())
            or self.entity:GetPlatform()
--【end：平台链】
    end
--【GetCurrentPlatform 结束】
end
--【空行】

--★★ GetCurrentTileType：判断脚下地块类型（含容错）
--★原注释的警告很重要】
--  "WARNING: This function is only an approximate, if you only care if the
--ground is valid or not then call IsOnValidGround()"
--  ★ 即：这是一个「近似」函数 —— 它会对非陆地瓦片做邻域采样来修正结果，
--    因为「站在森林边缘」时，取到的中心瓦片可能不是真正的地面。
--★ 【近似算法详解 —— 本函数最核心的逻辑，见 1850-1876】
--   问题：GetTile(tx,ty) 只返回「实体坐标所在的瓦片」。
--     若该点恰好落在两片瓦片的交界处或落在树冠上，取值可能不准。
--   修正：若取到的不是陆地块（IsLandTile 为假），
--     就检查 3×3 邻域中偏移在 ±0.166 内的四个邻块，取其中最大的瓦片号。
--   ★ 意图：如果实体踩在「树枝」的投影上，就用周围的实际地面类型。
function EntityScript:GetCurrentTileType()
--【★ 近似算法的警告注释】
-- WARNING: This function is only an approximate, if you only care if the ground is valid or not then call IsOnValidGround()
    local map = TheWorld.Map
--【★ 取实体世界坐标】
    local ptx, pty, ptz = self.Transform:GetWorldPosition()
--★ GetTileCenterPoint 取瓦片中心 —— 用于计算实体在瓦片内的相对位置。
    local tilecenter_x, tilecenter_y, tilecenter_z  = map:GetTileCenterPoint(ptx, 0, ptz)
--【★ 瓦片坐标】
    local tx, ty = map:GetTileCoordsAtPoint(ptx, 0, ptz)
--【★ 中心瓦片类型】
    local actual_tile = map:GetTile(tx, ty)
--【空行】

--★ 三重判空（瓦片存在 + 中心坐标存在）—— 地图边缘时可能拿不到。
    if actual_tile ~= nil and tilecenter_x ~= nil and tilecenter_z ~= nil then
--★★ 「非陆地瓦片才需要修正」】
--   IsLandTile 判断是否已是地面（如草地）。
--   ★ 已经是地面就不做邻域采样 —— 因为地面上的取值本来就准。
--   需要修正的是「非地面」瓦片（树、石头、水、花等物件占据的格子）。
        if not TileGroupManager:IsLandTile(actual_tile) then
--★★ xpercent / ypercent：实体相对瓦片中心的偏移（归一化到 ±0.5）】
--   TILE_SCALE 是瓦片的物理边长，除完得到「瓦片内的相对位置」。
--   ★ 变量名 ypercent 其实是**z**方向的偏移（1853 行用 tilecenter_z - ptz），
--     沿用 y 指「第二个平面轴」的旧习惯 —— 阅读时容易误解。
			local xpercent = (tilecenter_x - ptx) / TILE_SCALE
			local ypercent = (tilecenter_z - ptz) / TILE_SCALE

--★★★ ±0.166 阈值 —— 这是整个算法的魔法常数】
--   x_min = xpercent > 0.166 and -1 or 0 —— 即实体在瓦片中心偏右 → 查左边一块
--   ★ 为什么是 1/6？因为一块瓦片被视作 6×6 的采样网格，
--     0.166 ≈ 1/6，即「只在明显偏离中心时才去采样邻居」，
--     避免在瓦片中心区域做无意义的邻域搜索。
--   ★ 结果只有 4 种组合：(-1,0) (0,0) (0,1) (1,0) 等，
--     即至多查 4 个方向，且相邻的 2×2 块。
   --★⚠ 魔法数字无说明：代码里没有注释解释 0.166 的来历，
--     这是本函数最难理解的部分。应补注释或提取为常量。
			local x_min = xpercent > 0.166 and -1 or 0
			local x_max = xpercent < -0.166 and 1 or 0
			local y_min = ypercent > 0.166 and -1 or 0
			local y_max = ypercent < -0.166 and 1 or 0

            --local x_off = 0 -- These are only calculated for debugging
            --local y_off = 0 -- These are only calculated for debugging

--【★★ 双层循环：至多 2×2 = 4 个邻块】
--   ★ 性能可接受：仅在「取到的不是地面」时才执行，
--     而这通常是少数情况。
            for x = x_min, x_max do
                for y = y_min, y_max do
                    local tile = map:GetTile(tx + x, ty + y)
--★ 取瓦片号更大的那个 —— 瓦片号即优先级（如地面 < 道路 < 人工地板）。
--   ★ 与TileGroupManager:IsLandTile 的语义配套。
                    if tile > actual_tile then
                        actual_tile = tile
                        --x_off = x -- These are only calculated for debugging
                        --y_off = y -- These are only calculated for debugging
                    end
                end
--【end：邻域采样】
            end
--【end：非陆地瓦片分支】
        end
--【空行】

--【★ 第二个返回值 GetTileInfo(actual_tile) —— 瓦片的完整信息表】
--   含标签、湿度、可挖掘性等。第一个返回值只是瓦片号（便于快速比较）。
        return actual_tile, GetTileInfo(actual_tile)
--【end：条件返回】
    end

--★ 被注释掉的调试打印：会输出坐标偏移与采样结果。
--   ★ 这行证明了 x_off / y_off 变量原本用于调试采样结果，现已无用。
    --print (string.format("(%d+%d, %d+%d), (%2.2f, %2.2f), %d", tx, x_off, ty, y_off, xpercent, ypercent, actual_tile))
--【GetCurrentTileType 结束】
end

--【空行】
-- NOTES(JBK): This function will return true if the entity is now on valid ground, false if it could not find a suitable location.
--★ 原注释（JBK）："This function will return true if the entity is now on
--valid ground, false if it could not find a suitable location."
--【★ 三级策略】① 原地可通行 → 直接返回；② 附近有陆地 → 传送；③ 否则 false。
function EntityScript:PutBackOnGround(radius)
--【★ 默认搜索半径 8】
    radius = radius or 8
	local x, y, z = self.Transform:GetWorldPosition()
    if TheWorld.Map:IsPassableAtPoint(x, y, z, true) then
--【★ 原地可通行 → 无需移动】
        return true
    else
--【★ 构造 Point 以便搜索】
        local pt = Point(x, y, z)
--★★ 先找陆地，再找海洋 —— 顺序体现「优先站到安全的地方」】
--   ★ FindNearbyLand 返回 Point 或 nil。
--   ★ 玩家掉出世界时被调用，把人拉回最近的合法位置。
        local dest = FindNearbyLand(pt, radius) or FindNearbyOcean(pt, radius)
--【★ 找到候选地】
        if dest ~= nil then
--【★ 传送优先走 Physics，有 Physics 才会走 Transform】
--   ★ 为什么？Physics:Teleport 会处理碰撞体同步与速度清零，
--     而 Transform:SetPosition 只是硬改位置，可能与物理体不同步。
--   ★ 无 Physics 的实体（纯装饰）才退而求其次。
            if self.Physics ~= nil then
--【★ 优先用 Physics 传送】
                self.Physics:Teleport(dest:Get())
--★ 传送成功】
                return true
            elseif self.Transform ~= nil then
                self.Transform:SetPosition(dest:Get())
--【★ 无 Physics 则硬改 Transform】
                return true
            end
--【end：找到候选地】
        end
    end
--【★ 无处可去 → 返回 false】
    return false
--【PutBackOnGround 结束】
end
--【空行】

--★★★ GetPersistData —— 存档写出的数据收集
--【★ 逐组件调OnSave 并合并到 data】
--   ★★ 关键：只有非空表才写入（1909 行 `not IsTableEmpty(t)`），
--     这就是「稀疏存档」的第二层（第一层是坐标的 y=0 省略）。
--   ★ 收益极大：绝大多数组件的 OnSave 返回 nil 或空表，
--     所以实际写入存档的组件通常不到 10%。
   --★⚠ 副作用：无法区分「组件存在但无状态」与「组件不存在」，
--     读档时只能靠 SetPersistData 遍历 data 的键来推断。
--【★ 与 SetPersistData:1954 的严格对偶关系】
--   GetPersistData  →  SetPersistData
--   组件 OnSave()    →  组件 OnLoad(data)
--   prefab OnSave    →  prefab OnPreLoad / OnLoad
--   references 汇总  →  LoadPostPass(newents) 解析
--   ★ 四对关系全部对应，这是理解存档系统的骨架。
function EntityScript:GetPersistData()
--【★ references 用数组而非哈希的原因】
--   同一个引用可能被多个组件重复报告（如「我引用了玩家 A」，
--   但 player_classified 组件和 health 组件都报告了它）。
--   ★ 收集阶段不去重，把去重交给上层统一处理 —— 
--   分工清晰，且避免了在遍历中去重可能引入的顺序问题。
    local references = {}
    local data = {}
    for k, v in pairs(self.components) do
        if v.OnSave then
            local t, refs = v:OnSave()
            if type(t) == "table" and not IsTableEmpty(t) then
--【★ 非空才写入：稀疏存档】
                data[k] = t
--★★ add_component_if_missing —— 跨版本兼容的巧思】
--   组件返回的表里若带这个标记，base 就会在 data 上也打一个同名的标记。
--   ★ 用途：某组件是在某个版本之后才加入的。
--     旧存档里没有它的数据，读档时需要根据这个标记重新装上组件。
--   ★ 参见 SetPersistData:1955 —— 读档时先扫一遍标记补装组件，再加载数据。
--     ★ 这是「数据驱动的向后兼容」的标准做法：
--     新版本加组件不需要迁移旧存档，只需加一个标记。
				if t.add_component_if_missing then
					data.add_component_if_missing = true
				end
--【end：组件数据合并】
            end

--★ references 的收集：把各组件返回的引用列表汇入总表。
--   ★ 注意是 table.insert（数组式）而非哈希式收集 ——
--     因为引用可能被多个组件重复报告，需要后续去重。
            if refs then
                for k1, v1 in pairs(refs) do
                    table.insert(references, v1)
                end
            end
        end
--【end：组件遍历】
    end

--【★ prefab 自己的 OnSave —— 在所有组件之后】
--   ★ 顺序要点：组件数据先写，prefab 数据后写。
--     这样若两者写同一字段，prefab 的值胜出（可控的覆盖）。
--   ★ OnSave 的签名是 (self, data) —— 能看到已收集的组件数据，
--     可以据此做条件性保存。
    if self.OnSave then
        local refs = self.OnSave(self, data)

        if refs then
            for k, v in pairs(refs) do
                table.insert(references, v)
            end
        end
    end
--【★ prefab 的 refs 汇入】

--★★「全空则什么都不返回」】
--   if not IsTableEmpty(data) or not IsTableEmpty(references) then
--       return data, references
--   end
--   ★ 什么都不返回 → 调用方拿到两个 nil → 整个实体不进存档。
--   ★ 这就是 1770 行 persists=false 的作用：让「不该存的实体」真的不存。
   --★⚠ 细节：条件是 or 而非 and，
--     即「数据非空 **或** 引用非空」就返回。若只有引用（data 空），
--     会返回 (空表, 引用表) —— 行为正确（引用也需要写盘）。
--     但若 data 为空且 references 非空，返回的是空表而非 nil，
--     序列化端需能正确处理「空 data + 有 references」的组合。
    if not IsTableEmpty(data) or not IsTableEmpty(references) then
        return data, references
    end
end
--★ GetPersistData 的返回值三个可能：
--   (data, references) —— 两者至少一者非空（常见）
--   (nil, nil)         —— 完全无状态 → 不写入存档（省空间的关键）
--   ★ 这就是为什么「绝大多数实体的存档很小」。
--【空行】

--★★★ LoadPostPass —— 存档读入的「第二遍」
--【★ 为什么需要两遍？】
--   有些数据只能在其**依赖的实体都加载完之后**才能恢复。
--   典型：容器里的物品需要知道容器实体的 ID 才能算「我属于谁」；
--         玩家需要知道自己背包里的物品才能恢复饥饿度。
--【★ 机制】
--   第一遍（SetPersistData）：加载所有能独立加载的数据。
--   第二遍（本函数）：拿到 newents（全局的 GUID → 实体表），
--     可以解析出「那个 GUID 对应哪个实体」并建立引用。
--   ★ 这就是 GetSaveRecord:315 返回 references 的原因 —— 
--     它们正是要在这一遍被解析的。
function EntityScript:LoadPostPass(newents, savedata)
--【★ 无存档数据则跳过】
    if savedata ~= nil then
        for k, v in pairs(savedata) do
--【★ 按组件名取回组件】
            local cmp = self.components[k]
--★ 双重守卫：组件存在 且 组件定义了 LoadPostPass。
            if cmp ~= nil and cmp.LoadPostPass ~= nil then
                cmp:LoadPostPass(newents, v)
            end
        end
--【end：组件 LoadPostPass】
    end

--★ prefab 自己的 OnLoadPostPass —— 在组件之后。
    if self.OnLoadPostPass ~= nil then
        self:OnLoadPostPass(newents, savedata)
--【★ prefab 的 LoadPostPass 在最后】
    end
end
--【空行】

--★★★ SetPersistData —— 存档读入的第一遍
--【★ 四步严格有序】
--   步骤1（1955-1961）：★ 预扫描补装组件（向后兼容）
--   步骤2（1963）：OnPreLoad —— prefab 在组件加载前的钩子
--   步骤3（1967-1984）：逐组件 OnLoad
--   步骤4（1986）：OnLoad —— prefab 在组件加载后的钩子
--【★ OnPreLoad / OnLoad 这一对钩子是最灵活的设计】
--   prefab 脚本可以：
--     · OnPreLoad：读取 data 里的自定义字段，用于决定要装什么组件
--     · OnLoad：所有组件已就绪，进行跨组件的初始化
--   ★ 这解决了「组件数据依赖另一个组件」的问题。
function EntityScript:SetPersistData(data, newents)
--★★ 步骤1：向后兼容的组件补装（★ 必须最先执行）】
--   ★★ 原因：若某组件的数据在存档里，但实体上还没装这个组件，
--     步骤3 的 self.components[k] 会取到 nil，数据永远加载不进去。
--   ★ 所以必须先扫一遍 data，把标记了 add_component_if_missing 的组件装上。
	if data and data.add_component_if_missing then
		for k, v in pairs(data) do
			if self.components[k] == nil and type(v) == "table" and v.add_component_if_missing then
				self:AddComponent(k)
			end
--【end：标记扫描】
		end
--【空行】
	end

--★ OnPreLoad(data, newents) —— 组件尚未加载时。
--   ★ 可用于「根据存档数据决定加哪个组件」等场景。
    if self.OnPreLoad ~= nil then
--【★ OnPreLoad：组件尚未加载】
        self:OnPreLoad(data, newents)
    end
--【空行】

    if data ~= nil then
        for k, v in pairs(data) do
--【★ 按键取组件】
            local cmp = self.components[k]

--★V2C 原注释完整保留了这段逻辑的演进史】
--  "backward compatibility for add_component_if_missing"
--  "the flag has since been added to the base data table as well so that we
--   can add the missing components before preload"
--★ 翻译：
--   ① 最初设计时，标记只在各组件自己的数据表里；
--   ② 后来把标记也提到 base data 顶层，于是能在 preload 前统一补装。
--   → 这就是 1955-1961 那一段存在的原因。
--★★ 这段注释的价值：它记录了「为什么会有两处看似重复的补装逻辑」。
--   1955 行（顶层扫描）与 1974 行（逐项兼容）确实是冗余的，
--   但 V2C 注释解释了冗余的成因 —— 读代码的人不会再困惑。
--   ★ 这种「解释历史遗留」的注释是维护大型代码库的宝贵财富。
			--V2C: -backward compatibility for add_component_if_missing
			--     -the flag has since been added to the base data table as well so that we
			--      can add the missing components before preload
--★ 1974-1977 的逐项补装 —— 与 1955 段在功能上重叠】
--   ★ 保留它是为了兼容「标记只在组件数据里、不在顶层」的旧存档。
--   两处并存 = 向后兼容做到极致，代价是代码冗余。
            if cmp == nil and type(v) == "table" and v.add_component_if_missing then
				self:AddComponent(k)
                cmp = self.components[k]
            end
			------
--【★ V2C 兼容段结束】

--【步骤3：逐组件加载数据】
--   ★注意 OnLoad 的参数是 (data, newents)，与 GetSaveRecord 的 OnSave 对称。
            if cmp ~= nil and cmp.OnLoad ~= nil then
                cmp:OnLoad(v, newents)
            end
--【end：组件 OnLoad 循环】
        end
    end
--【空行】

--★ OnLoad(data, newents) —— 所有组件就绪后。
    if self.OnLoad ~= nil then
        self:OnLoad(data, newents)
--【★ OnLoad 在最后】
    end
end
--★ SetPersistData 的对称返回值：无（in-place 修改）
--   ★ 与 GetPersistData 不同，读入不需要收集 references —— 
--     references 是在 LoadPostPass:1939 阶段由 newents 表解析的。
--【空行】

--★★ GetAdjective：给 HUD 用的状态形容词（「一只饥饿的牛」）
--【★ 与 GetAdjectivedName 的区别】
--   GetAdjectivedName —— 物品名修饰（本地化字符串，可含两词组合）
--   GetAdjective      —— 生物状态描述（单个词，取自 STRINGS.UI.HUD）
--   ★ 前者用于物品栏，后者用于生物头顶显示的浮动文字。
--【★ 完整分支】
--   ① displayadjectivefn —— 自定义函数
--   ② critter      → 查trait_ 标签（TUNING.CRITTER_TRAITS）
--   ③ small_livestock → 饥饿/腐败（stale→HUNGRY，spoiled→STARVING）
--   ④ stale        → STALE / STALE_FROZEN
--   ⑤ spoiled      → SPOILED / STALE_FROZEN
function EntityScript:GetAdjective()
	if self.displayadjectivefn ~= nil then
--【★ 自定义形容词函数优先】
		return self:displayadjectivefn()
--【★ critter：按 trait 标签反查】
	elseif self:HasTag("critter") then
--★★ critter 的特征标签反向查找】
--   与 GetAdjectivedName:705 的 FOODTYPE 遍历同构：
--   标签是 trait_<name>，反查 TUNING.CRITTER_TRAITS 拿显示名。
--   ★ 同样存在遍历开销，但 critter 数量远少于物品。
		for k in pairs(TUNING.CRITTER_TRAITS) do
			if self:HasTag("trait_"..k) then
				return STRINGS.UI.HUD.CRITTER_TRAITS[k]
--【end：trait 遍历】
			end
--【★ 转到小牲口分支】
		end
--★★ small_livestock 的布尔表达式】
--   return not sick and ( (stale and HUNGRY) or (spoiled and STARVING) ) or nil
--   ★ 拆解：
--     ① 生病 → 返回 nil/false（不显示任何形容词）
--     ② 没病 且 (stale → HUNGRY | spoiled → STARVING)
--   ★ 末尾 or nil 把 false 归一化成 nil，便于上层 `if adj then` 判断。
--   ⚠ 表达式的 true 分支是 `not sick and ...` 的值，可能是 true（当条件成立）
--     也可能是 HUNGRY 字符串。外层 `or nil` 只在整体为 false 时生效。
--     写法正确但可读性一般 —— 建议拆成 if/elseif 链（与本函数其他分支统一）。
    elseif self:HasTag("small_livestock") then
        return not self:HasTag("sickness")
            and ((self:HasTag("stale") and STRINGS.UI.HUD.HUNGRY) or
                (self:HasTag("spoiled") and STRINGS.UI.HUD.STARVING))
--【★ 生病则无形容词】
            or nil
--★ frozen 的通用处理：stale 与 spoiled 都共用 STALE_FROZEN 字符串。
--   ★ 复用同一字符串而非各写一个，减少本地化条目。
    elseif self:HasTag("stale") then
        return self:HasTag("frozen") and STRINGS.UI.HUD.STALE_FROZEN or STRINGS.UI.HUD.STALE
    elseif self:HasTag("spoiled") then
        return self:HasTag("frozen") and STRINGS.UI.HUD.STALE_FROZEN or STRINGS.UI.HUD.SPOILED
--【★ spoilt + frozen 复用同一字符串】
    end
end
--【空行】

--【SetInherentSceneAction：设置场景交互的固有动作】
--【★ 两步：写本地字段 + 写网络变量】
--   本地字段供服务端逻辑立即使用；网络变量供客户端画高亮。
--   ★ 两者的顺序无关（互不依赖），但都要做。
function EntityScript:SetInherentSceneAction(action)
    self.inherentsceneaction = action
--★ 判空 actionreplica —— 非联网实体没有这张表。
    if self.actionreplica.inherentsceneaction ~= nil then
        self.actionreplica.inherentsceneaction:set(SerializeAction(action))
--【★ 写网络变量同步给客户端】
    end
end
--【空行】

function EntityScript:SetInherentSceneAltAction(action)
    self.inherentscenealtaction = action
    if self.actionreplica.inherentscenealtaction ~= nil then
        self.actionreplica.inherentscenealtaction:set(SerializeAction(action))
--【★ 同步备选场景动作】
    end
end
--【空行】

--★★★ LongUpdate —— 大跨度时间跳跃时的单帧推进
--【★ 何时调用？调用方在 update.lua:301】
--   用于「跳过夜晚」「从洞穴回来」这类 dt 极大（几十秒）的场景。
--   ★ 此时正常 tick 会被补跑无数次（因为 update.lua:239 的 for i = last+1, tick），
--     所以需要「一次算完」的替代路径。
--【★ 覆盖范围：所有 Ents（不只是活跃实体）】
--   update.lua:349 `for k, v in pairs(Ents) do v:LongUpdate(dt) end`
--   ★ 连休眠/limbo 的实体也会被调用 —— 因为它们的时间流逝也是真实的。
--【★ ignore_player 参数】
--   update.lua:315-341：为 true 时会跳过玩家及其相关实体，
--   并临时把胡子的 pause 置 true（防止长跳跃导致胡子瞬间长好）。
--   ★ 典型用途：载入存档时补算离线时间，物品不该跟着腐败。
--【★ 与 OnUpdate 的三个本质区别】
--   ① 触发频率：OnUpdate 每 tick；LongUpdate 只在大跳跃时
--   ② 覆盖范围：OnUpdate 只遍历 UpdatingEnts；LongUpdate 遍历全部 Ents
--   ③ 是否有忽略玩家开关：LongUpdate 有（update.lua:308）
--   ★★ ②意味着休眠实体的时间也在推进 —— 这是正确的时间语义。
--★★ 参见 update.lua:301 LongUpdate —— 本函数由它遍历 Ents 逐个调用；
--   update.lua:315-341 是 ignore_player 分支的过滤逻辑。
function EntityScript:LongUpdate(dt)
--【★ prefab 的 OnLongUpdate 优先于组件】
--   ★ 顺序与 LongUpdate 的「先自己后组件」相反—— 
--     因为 LongUpdate 是「先实体后组件」，这里先调实体的 OnLongUpdate。
--   ⚠ 不对称之处：OnUpdate 里实体和组件的顺序与这里相反。
--     目前 EntityScript 没有定义 OnUpdate（由 C++ 引擎直接调），
--     所以未暴露问题。
    if self.OnLongUpdate ~= nil then
        self:OnLongUpdate(dt)
--【★ prefab 优先】
    end
--【空行】

    for k, v in pairs(self.components) do
        if v.LongUpdate ~= nil then
            v:LongUpdate(dt)
--【★ 组件遍历结束】
        end
    end
--【LongUpdate 结束】
end
--【空行】

--★★ 客户端侧物品图标重映射 —— mod 换肤的通用方案
--【★ 三层数据结构】
--   self.inventoryimageremapping[flagname][hash(源图名)] = { image=新图, atlas=新atlas }
--     flagname  → 什么条件下生效（如 "valheimrunes"）
--     hash(源图) → 用哈希而非字符串，省内存与比较开销
--   ★ 有了 ClientSideInventoryImageFlags:9 的全局开关表，
--     不同实体可以注册同一 flagname 下的不同映射，
--     而实际是否生效由全局 flag 决定（见 2061）。
--【★ 为什么这套机制要放在客户端？】
--   因为换图纯属显示优化，不值得走网络同步（浪费带宽）。
--   客户端本地注册本地生效 —— 典型的「客户端专属优化」。
function EntityScript:SetClientSideInventoryImageOverride(flagname, srcinventoryimage, destinventoryimage, destatlas)
    --destatlas is optional
    self.inventoryimageremapping = self.inventoryimageremapping or {}
--【★ 两层懒建】
    self.inventoryimageremapping[flagname] = self.inventoryimageremapping[flagname] or {}
--★ hash(srcinventoryimage) —— 对图名求哈希作为键。
--   ★ 整数键比字符串键在 Lua 表里快得多（无需字符串哈希比较）。
    self.inventoryimageremapping[flagname][hash(srcinventoryimage)] = {image = destinventoryimage, atlas = destatlas}
--★ 只有该 flag 已在全局表中开启、且存在本地玩家时才通知刷新。
--   条件严格避免不必要的 UI 重建。
    if ClientSideInventoryImageFlags[flagname] and ThePlayer then
        ThePlayer:PushEvent("clientsideinventoryflagschanged")
    end
--【SetClientSideInventoryImageOverride 结束】
end
--【空行】

function EntityScript:HasClientSideInventoryImageOverrides()
    return self.inventoryimageremapping ~= nil
--【HasClientSideInventoryImageOverrides 结束】
end

--【空行】
--do not call this if you have no client side inventory image overrides
--【GetClientSideInventoryImageOverride：按图名哈希查映射】
--   ★ 遍历所有 flag —— 因为查询方不知道当前生效的是哪个 flag。
--   ⚠ 性能：每次查询都遍历 remaps（通常1-3 项），可接受。
function EntityScript:GetClientSideInventoryImageOverride(imagenamehash)
    for flag, remaps in pairs(self.inventoryimageremapping) do
        if ClientSideInventoryImageFlags[flag] and remaps[imagenamehash] then
--【★ flag 需全局开启】
            return remaps[imagenamehash]
        end
    end
end
--【空行】

--★★ SetClientSideInventoryImageOverrideFlag：设置全局开关】
--【★ 2072 行的巧妙表达式 `value = (not value) ~= true or nil`】
--   拆解：not value 得到布尔 b；`b ~= true` 判断 b 是否为 false。
--     · b 为 true（value 为 false）→ true ~= true → false → or nil → nil
--     · b 为 false（value 为 true）→ false ~= true → true → true
--   即：把 boolean 归一化成「true 或 nil」。
--   ★ 目的与 1106 行的 `or nil` 一致：让字段语义干净（关闭 = nil）。
function EntityScript:SetClientSideInventoryImageOverrideFlag(name, value)
    value = (not value) ~= true or nil
--【★ updated：只有值真的变了才通知 UI 重建】
--   ★ 这是避免无效刷新的标准做法。
    local updated = ClientSideInventoryImageFlags[name] ~= value
    ClientSideInventoryImageFlags[name] = value
    if updated and ThePlayer then
        ThePlayer:PushEvent("clientsideinventoryflagschanged")
--【★ 值变了才通知】
    end
end
--【空行】

--★★★ IsInLight —— 带迟滞（hysteresis）的光照判定
--【★ 两条路径】
--   ① 有 LightWatcher 组件 → 委托给它（组件内可能有多光源合成逻辑）
--   ② 否则 → 单点查询 + 本地缓存
--【★★ 迟滞设计 —— 本函数最精妙的部分，见 2074-2086】
--   ★ 问题：光照值在阈值附近抖动时（比如玩家站在火光边缘），
--     若用单阈值，inLight 会每帧翻转 → 光标/图标疯狂闪烁。
--   ★ 解法：双阈值 + 状态记忆：
--     lightThresh = 0.1（进黑暗区）darkThresh = 0.05（出黑暗区）
--     · 当前 inLight ~= false（亮），只有 light <= 0.05 才变暗
--     · 当前 inLight == false（暗），只有 light >= 0.1 才变亮
--   ★ 这就是电子电路里的施密特触发器 —— 游戏里大量使用。
function EntityScript:IsInLight()
    if self.LightWatcher then
--【★ 有 LightWatcher 组件则委托】
        return self.LightWatcher:IsInLight()
    else
        local lightThresh = self.lightThresh or 0.1
        local darkThresh = self.darkThresh or 0.05

--【★ 取自身位置】
        local x, y, z = self.Transform:GetWorldPosition()
--【★ 查询光照值】
        local light = TheSim:GetLightAtPoint(x, y, z, lightThresh)
--【★ 迟滞判定的变量】

--★★ move_to_light 的计算 —— 只在「跨过上阈值」时为真】
--   self.inLight == false and light >= lightThresh
--   ★ 即「现在是暗的，且光够亮」→ 想要变亮。
   --★ 注意这里只处理「变亮」，「变暗」在下一行处理 —— 两条路径不对称。
        local move_to_light = self.inLight == false and light >= lightThresh

--★★ 状态更新的双条件】
--   if move_to_light or (self.inLight ~= false and light <= darkThresh) then
--       self.inLight = move_to_light
--   ★ 解读：
--   · 要变亮 → move_to_light 为真 → inLight = true
--   · 要变暗 → 当前是亮 且 光 <= darkThresh → inLight = false（= move_to_light）
--   · 否则不变（inLight 保持原值，但被重新赋成同值）
--   ★★注意「不变」时也会执行赋值 self.inLight = move_to_light，
--     而此时 move_to_light 必为 false，所以 inLight 被写成 false ——
--     ★ 等价于「保持不变」，但只有在前两种情况之外的
--     「当前暗 + 光还不够亮」这一种。分析：
--       当前暗 + light < 0.1 → 两个条件都假 → inLight = false
--       当前亮 + 0.05 < light < 0.1 → 都假 → inLight = false ← ★★ 这里会错误地变暗！
--★ ⚠ 疑似缺陷：当前亮(0.08)介于两个阈值之间时，
--     会被赋值为 false，尽管光照仍高于 darkThresh。
--     不过下一帧若仍在此区间，还是 false —— 所以它是「粘滞」的。
--     实际效果：迟滞区间内的光照会被判为「暗」。
--     这与「双阈值迟滞」的预期（区间内保持原状态）有细微偏差。
--     推测：作者本意是保持不变，正确的写法应是：
--       if move_to_light then self.inLight = true
--       elseif self.inLight ~= false and light <= darkThresh then self.inLight = false end
        if move_to_light or (self.inLight ~= false and light <= darkThresh) then
            self.inLight = move_to_light
--【★ 状态更新：迟滞区间内粘滞】
        end

--【★ 统一返回「是否在光中」而非原始光值】
--   这让调用方不必关心迟滞逻辑，只需一个布尔。
        return self.inLight ~= false
    end
--【end：IsInLight】
end
--★ IsInLight 的迟滞参数可由 prefab 覆盖：
--   self.lightThresh —— 进入「暗」的上阈值（默认 0.1）
--   self.darkThresh  —— 退出「暗」的下阈值（默认 0.05）
--   ★ 两个阈值**故意不相等** —— 相等就没有迟滞效果了。

--【★ IsLightGreaterThan：不做迟滞的原始光值查询】
--   ★ 与 IsInLight 的区别：这里返回「光值 >= 阈值」而非「是否在光中」。
--     所以没有缓存，每次都问 C++（成本更高但精确）。
--   ★ 有 LightWatcher 时走组件的 GetLightValue()（可能是多光源合成值）。
function EntityScript:IsLightGreaterThan(lightThresh)
--【★ 有 LightWatcher → 取组件的光值】
    if self.LightWatcher then
        return self.LightWatcher:GetLightValue() >= lightThresh
    else
--【★ 无组件 → 直接查 C++】
        local x, y, z = self.Transform:GetWorldPosition()
        return TheSim:GetLightAtPoint(x, y, z, lightThresh) >= lightThresh
    end
end
--【空行】

--
--【空行】

--★ 减益（Debuff）系统（2101–2135）—— 状态类效果的标准接口。
--【★ 统一走 debuffable 组件】
--   好处：① 效果类型统一 ② 存档统一 ③ 死亡清理统一。
function EntityScript:DebuffsEnabled()
--★★ 没有 debuffable 组件视为「支持减益」】
--   `self.components.debuffable == nil or ...:IsEnabled()`
--   ★ 默认开放：普通实体（草、石头）不装这个组件，
--     但若有人对它施加重力压制等效果，AddDebuff:2116 会现场装一个。
    return self.components.debuffable == nil or self.components.debuffable:IsEnabled()
end
--【空行】

function EntityScript:HasDebuff(name)
--【★ 委派组件并归一为布尔】
    return (self.components.debuffable ~= nil and self.components.debuffable:HasDebuff(name))
        or false
end

function EntityScript:GetDebuff(name)
--【★ 委派组件】
    return (self.components.debuffable ~= nil and self.components.debuffable:GetDebuff(name))
        or nil
end
--【空行】

--★★ AddDebuff：施加重益效果
--【★ 四步】
--   ① 按需安装 debuffable 组件（懒加载）
--   ② 三重可用性测试（skip_test / 减益系统开启 / 实体未死亡）
--   ③ pre_buff_fn 钩子（在正式施加前跑，如播放特效/音效）
--   ④ 调用组件施加
   --★ skip_test 参数：用于「已确认有效、只要强制施加」的场景
--     （如从存档恢复时、或已通过其他检查的重入调用）。
function EntityScript:AddDebuff(name, prefab, data, skip_test, pre_buff_fn, buffer)
--★ 懒安装：调用者无需关心组件是否存在。
    if self.components.debuffable == nil then
--【★ 懒装 debuffable】
        self:AddComponent("debuffable")
--【空行】
    end
--【空行】

--★★ IsEntityDeadOrGhost —— 死亡/幽灵状态不接受减益】
--   ★ 典型：僵尸化的玩家不应再被「点燃」。
    if skip_test or (self:DebuffsEnabled() and not IsEntityDeadOrGhost(self)) then
        if pre_buff_fn then
            pre_buff_fn()
--【★ 施加前的业务钩子】
        end
--★ AddDebuff(name, prefab, data, buffer) —— buffer 参数被透传。
--   ★ 注意 pre_buff_fn 在函数内被调用（2115 行的参数），而非传给组件，
--     说明它是 EntityScript 层的钩子而非 debuffable 的参数。
        self.components.debuffable:AddDebuff(name, prefab, data, buffer)
        return true
--【★ 施加成功返回 true】
    end

    return false
--【AddDebuff 结束】
end

--【RemoveDebuff：移除减益】存在性检查后转发。
function EntityScript:RemoveDebuff(name)
    if self.components.debuffable then
--【★ 存在才转发】
        self.components.debuffable:RemoveDebuff(name)
    end
end
--★ Debuff 系统的五个接口与组件的关系：
--   DebuffsEnabled()    —— 无组件时视为 true（默认开放）
--   HasDebuff(name)     —— 委托组件
--   GetDebuff(name)     —— 委托组件
--   AddDebuff(...)      —— 按需装组件 + 三重测试 + pre_buff_fn 钩子
--   RemoveDebuff(name)  —— 委托组件

--【空行】
--
--【空行】

-- For mob/corpse death states on save/load
--★ 死亡掉落（DeathLoot）系列（2140–2173）：尸体状态跨存档保持。
--【★ 为什么要存死亡掉落？】
--   场景：生物死亡 → 玩家搜刮尸体 → 中途退出游戏 → 重新登录。
--   ★ 掉落物必须已生成并持久化，否则玩家会「刷出」额外战利品或丢失物品。
--   机制：掉落物存进尸体（deathloothandler），尸体存档时保留。
function EntityScript:SetDeathLootLevel(num)
    local deathloothandler = self.components.deathloothandler
--★ 按需安装 —— 与 AddDebuff:2116 同构的懒加载范式。
    if deathloothandler == nil then
--【★ 懒装 deathloothandler】
        deathloothandler = self:AddComponent("deathloothandler")
    end
--【空行】

--【★ 设置掉落等级】
    deathloothandler:SetLevel(num)
--【SetDeathLootLevel 结束】
end

function EntityScript:GetDeathLootLevel()
    local deathloothandler = self.components.deathloothandler
    return (deathloothandler and deathloothandler:GetLevel())
--【★ 兜底 0 = 不掉落】
        or 0
--【GetDeathLootLevel 结束】
end
--【空行】

-- To handle just dropping it like usual, OR store it in the corpse if we're corpsing.
--★★ DropDeathLoot —— 两条分支的真正差异】
--【★ 原注释揭示的意图】"To handle just dropping it like usual, OR store
--   it in the corpse if we're corpsing."
--【★ 两个分支】
--   ① 正在「尸体化」（is_corpsing）→ 掉落物存进尸体，不掉在地上
--   ② 正常死亡 → 掉落物直接掉在原地
--   ★ why：在尸体化的生物（如被巨人吃剩的牛）身上搜刮时，
--     掉落物应该出现在尸体里而不是地上。
function EntityScript:DropDeathLoot()
--【★ SetDeathLootLevel(1) 必须在分支之前】
--   保证 deathloothandler 组件已装且等级为 1（标准掉落率）。
    self:SetDeathLootLevel(1)
    --
--【★ 取 lootdropper 组件】
    local lootdropper = self.components.lootdropper
--【★ 无掉落组件则什么都不做】
    if lootdropper then
--★★ ⚠ 疑似缺陷：直接访问 components.health.is_corpsing】
--   if self.components.health.is_corpsing then
--   推理依据：
--     ① 没有检查 self.components.health 是否为 nil ——
--        若实体没有 health 组件（不可能掉落战利品的实体才会如此），
--        会抛 "attempt to index a nil value"。
--     ② is_corpsing 看起来是 health 组件内部的状态字段，
--        直接读内部字段而非调用 health:IsCorpsing()，破坏封装。
--   ★ 对比：同函数内其他访问都用局部变量 + 判空（2159 行做了 lootdropper 判空），
--     唯独这一处既无判空又读了深层字段。
--   → 建议：local health = self.components.health
--           if health and health:IsCorpsing() then
--   ⚠ 注意：2162 行同样直接访问 components.deathloothandler，
--     依赖 2157 行 SetDeathLootLevel 已确保它存在 —— 这是一种隐式契约。
        if self.components.health.is_corpsing then
            self.components.deathloothandler:StoreLoot(lootdropper:GenerateLoot())
        else
--【★ 正常死亡：直接掉地上】
            lootdropper:DropLoot(self:GetPosition())
        end
--【end：分支】
    end
--【DropDeathLoot 结束】
end

--【GetDeathLoot：查询已存放的掉落物】
--   ★ 供 UI / 搜刮逻辑使用。
function EntityScript:GetDeathLoot()
--【★ 取 deathloothandler】
    local deathloothandler = self.components.deathloothandler
    return (deathloothandler and deathloothandler:GetLoot())
        or nil
end
--★ 死亡掉落的三种状态存储位置：
--   SetDeathLootLevel(n) —— 设定掉落等级（0=不掉落）
--   DropDeathLoot()      —— 执行掉落：存尸体 或 掉地上
--   GetDeathLoot()       —— 查询已存放的掉落物（供 UI）
--   ★ 三者共同保证「死亡掉落状态」能被正确存档与恢复。
--【空行】

--【空行】
--
--【空行】

--★ require("entityscriptproxy") —— 通过副作用挂上 EntityScriptProxy 类。
--   ★ 文件末尾的这个 require 不是为了返回值，而是为了「执行副作用」。
--   entityscriptproxy.lua:81 定义了：
--     EntityScriptProxy = ProxyClass(EntityScript, function(self) ... end)
--   ★ 它的作用（见 entityscriptproxy.lua:81–91）：
--     创建一个「看起来和 EntityScript 完全一样」的代理对象，
--     但它的 .inst 指向自己，于是 inst.components.xxx.inst 依然是同一个代理，
--     ★ 解决了「跨端/跨层传递时 inst 引用不一致」的问题。
   --★ 具体解决什么问题？当一个客户端实体需要把「某组件的 inst」传给
--     一个期望 EntityScript 的函数时，代理保证 .inst 解引用能回到同一个对象，
--     ★ 而不会因components 层的包装而丢失代理身份。
--   —— 「代理模式」在 Lua 里常见的实现方式。
--★★ 参见 entityscriptproxy.lua:81 EntityScriptProxy = ProxyClass(...)
--   —— 本行 require 的目的就是执行这行副作用。
require("entityscriptproxy")

--★ 文件末尾的 require 是「副作用式混入」的典型：
--   它不为返回值，只为执行 module body。
--   ★ DST 里大量使用这种模式（见 596、604 行的 require）。
--   ⚠ 副作用式 require 的缺点：读代码时看不出它做了什么，
--     必须打开被 require 的文件才知道。
--     本行上方的注释正是为弥补这一点。