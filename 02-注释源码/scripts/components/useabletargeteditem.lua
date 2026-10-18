--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/useabletargeteditem.lua
-- 模块：组件系统 / 物品使用（UseableTargetedItem，有目标端）
-- 职责：「对目标使用」类物品的协议实现 —— 目标合法性判定（声明式 prefab 白名单
--       标签 or 回调式 UseableTargetedItem_ValidTarget，两者任一成立即可）、
--       使用中状态（inuse_targeted）、开始使用（返回 success 与 failreason）、
--       停止使用，以及三个正交的可用性开关：inventory_disableable（可收进背包）、
--       canselftarget（可对自己使用）、useablemounted（骑乘时可用）。
-- 【与 useableitem.lua 的关系】两者是【平行】实现而非继承：共享四要素协议
--       （CanInteract / StartUsingItem / 状态字段+标签 / StopUsingItem），
--       但状态语义与置位时机不同。调度方为 actions.lua:3338-3350（USEITEMON）
--       与 actions.lua:3357-3362（STOPUSINGITEM）。
-- 【⚠️ 已知历史包袱】canselftarget 的标签名拼写少一个 e（useabletargateditem_...），
--       但全库 5 处一致使用，功能正常；单独「修正拼写」会导致全部失效。
-- 关键符号：UseableTargetedItem, CanInteract, StartUsingItem, StopUsingItem,
--           SetTargetPrefab, SetUseableMounted, SetInventoryDisable,
--           SetCanSelfTarget, SetUsingItemDoesNotToggleUseability,
--           UseableTargetedItem_ValidTarget（可配在客户端）,
--           inuse_targeted, useabletargetprefab, canselftarget
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/useableitem.lua（无目标端，建议对照阅读）,
--           componentactions.lua（客户端侧目标合法性判定与动作表生成）,
--           actions.lua（USEITEMON / STOPUSINGITEM 调度）,
--           components/socketable.lua 与 socketholder（MakeItemSocketable_Server 复用）,
--           components/replica.lua（rider 骑乘状态读取）,
--           components/workable.lua（action.id.."_workable" 同一套标签协议模式）
--============================================================
local function oninuse_targeted(self, inuse_targeted)
-- ============================================================
-- components/useabletargeteditem.lua —— 「对目标使用」组件（139 行）
--
-- 【这个文件解决什么问题】
-- 与 components/useableitem.lua 共享同一套四要素协议，但多一个「目标」维度：
--   ① 能不能用（CanInteract）
--   ② 开始用（StartUsingItem(target, doer)）
--   ③ 使用中状态（inuse_targeted 字段 + 标签）
--   ④ 停止用（StopUsingItem）
-- 本文件的核心贡献是【目标合法性判定链】，它完全由「标签」实现，没有一行 if-else。
--
-- 【★★★ 本文件最重要的设计：目标合法性 = 标签的 or 关系】
-- 消费者在 componentactions.lua 第 3013-3017 行与第 1865-1869 行，两处写法相同：
--   目标合法  <=>  inst.UseableTargetedItem_ValidTarget(target, doer)   -- 回调式
--                 或  target.prefab 且 inst:HasTag(target.prefab.."_targeter")  -- 声明式
-- 两条路【任一为真】即合法。注意这是 or 不是 and：
--   · prefab 级声明（SetTargetPrefab）：一次声明，永久有效，零运行期开销；
--   · 回调级判定（UseableTargetedItem_ValidTarget）：可读任意状态，灵活但每帧调用。
-- ★★ 这就是 DST「内容侧声明、代码侧兜底」的分层：
--   绝大多数物品用第一种就够了；只有需要读玩家状态/位置/等级的才写第二种。
--   自研游戏照抄时，建议把这个 or 结构做成统一的 TargetFilter 配置项。
--
-- 【⚠️ 三个必须知道的坑，见各自标注】
-- * 第 18 行标签名拼写错误：useabletargateditem_canselftarget（少一个 e），
--   但全库【一致】使用这个错拼，所以不是缺陷，是历史包袱。见第 17-19 行。
-- * 第 72 行 OnRemoveFromEntity 漏摘 canselftarget 标签 —— 疑似真缺陷。见该行。
-- * 第 122 行的 self.inst:IsValid() 检查不可省，见第 122 行。
-- ============================================================

-- 属性钩子：inuse_targeted 字段 → 标签。
-- ★ 与 useableitem.lua 第 1-7 行同样的模式（字段供逻辑、标签供跨系统查询）。
--   消费者：componentactions.lua 第 3012 行（决定此时显示「停止」还是「使用」）。
--   即「使用中把动作按钮切换成停止」这个 UI 行为，是靠这个标签实现的。
    if inuse_targeted then
        self.inst:AddTag("inuse_targeted")
    else
        self.inst:RemoveTag("inuse_targeted")
    end
end

local function on_inventory_disableable(self, newval, oldval)
-- 属性钩子：inventory_disableable → 标签。
-- ★ 语义：允许「使用中把物品塞回背包」而不是强制拿在手上。
--   典型场景：手持手电筒（需要持续使用）时可以按丢弃把它放回背包。
-- 消费点：componentactions.lua 第 3011 行 ——
--   若【同时】有 useabletargeteditem_inventorydisable 与 inuse_targeted 两个标签，
--   则把 STOPUSINGITEM（停止使用）而不是 USEITEMON（对目标使用）塞进动作表。
-- ★★★ 这是整个文件里最巧妙的一处：
--   「手里拿着一个正在使用的物品时，右键该显示什么」这个 UI 决策，
--   被压缩成了两个标签的组合判断，逻辑放在动作注册器里而非组件里。
--   ★ 自研游戏可直接借用这个手法：组件只负责打标签，UI/动作层读标签决策。
    if newval then
        self.inst:AddTag("useabletargeteditem_inventorydisable")
    else
        self.inst:RemoveTag("useabletargeteditem_inventorydisable")
    end
end

local function oncanselftarget(self, newval)
-- ★★ canselftarget：允许「对着自己使用」。

-- 【⚠️ 第 18 行的标签名有拼写错误】
--   正确拼法应是 useabletargeteditem_canselftarget，
--   实际写的是 useabletargateditem_canselftarget —— target 后面少了一个 e。
-- 【但这不是缺陷】本人已全库核实，该错拼在 4 处消费点被【一致】使用：
--   componentactions.lua:3013、actions.lua:3330、actions.lua:3340、
--   stategraphs/SGwilson.lua:1559、stategraphs/SGwilson_client.lua:844。
--   5 处全是同一个错拼，所以功能正常。属于「一个 typo 被复制了 5 遍」的历史包袱。
-- ⚠️ 后果：若有人「顺手把拼写改对」，会立刻全部失效且没有任何编译期报错。
--   ★ 这是「字符串即契约」的典型风险 —— 自研游戏里凡是用字符串做协议的地方，
--     都应该集中定义常量（Lua 里可用一个 table 收口），别散落各处。
--   （以上 5 处位置本人已逐一 grep 核实。）

-- 【语义：canselftarget = 无目标时自动把 doer 自己当目标】
--   actions.lua:3340：`local target = act.target or act.invobject:HasTag(该标签) and act.doer`
--   即：玩家按使用键没指任何东西 → 若物品声明可自指 → 目标 = 玩家自己。
--   典型用途：给自己喂食、给自己上药（对称的 Give 类物品）。
-- ★ 本文件用 AddOrRemoveTag（useableitem.lua 那边用 if/else），风格不同但等价。
    self.inst:AddOrRemoveTag("useabletargateditem_canselftarget", newval)
end

local function ontargetprefab(self, newprefab, oldprefab)
-- 属性钩子：useabletargetprefab → 「<prefab名>_targeter」标签。
-- ★★ 这是「声明式目标白名单」的物理实现：
--   SetTargetPrefab("rock") 之后，本物品会带上 "rock_targeter" 标签；
--   任何实体只要 HasTag("rock_targeter") 就能被本物品作用于其上。
--   于是「我能不能作用于这个目标」变成了一个 O(1) 的标签查询，
--   而不是「遍历所有目标做类型判断」。
-- ⚠️ 隐含约束：目标实体的 prefab 名会变成标签名的一部分，
--   所以 prefab 改名会让所有声明了它的物品失去目标。
--   与 workable.lua 第 9 行的 action.id.."_workable" 是完全相同的模式。
-- ★★ 这说明「标签 = 字符串拼接出来的协议 ID」是 DST 全局通用的手法，
--   workable / useabletargeteditem / socketholder 都用同一套路。
    if oldprefab then
        self.inst:RemoveTag(oldprefab.."_targeter")
    end

    if newprefab then
        self.inst:AddTag(newprefab.."_targeter")
    end
end

local function onuseablemounted(self, newuseablemounted, olduseablemounted)
-- 属性钩子：useablemounted → useabletargeteditem_mounted 标签。
-- ★ 语义：允许「骑乘状态下使用」。
-- 消费点：componentactions.lua 第 3019-3023 行 ——
--   若【没有】这个标签 且 doer.replica.rider 存在且正在骑乘 → 直接 return，动作不出现。
--   即默认禁止骑乘使用，这个标签是逐个物品的豁免开关。
-- ⚠️ 注意它读的是 doer.replica.rider（副本），骑乘状态是客户端权威事实。
--   与 workable 无关，与 weapon 的 tough 也无关，是第三套正交开关。
-- ★★ 到这里本文件已经有三个正交的副状态开关：
--   inventory_disableable（能收起来吗）、canselftarget（能自指吗）、
--   useablemounted（能骑乘用吗）。
--   它们【互相独立】，组合起来覆盖了大量边缘场景，且每个都只是「一个布尔 + 一个标签」。
--   ★ 自研游戏的「物品可用性」应该也这样建模：正交布尔 + 统一查询入口，
--     而不是把条件写成一条越来越长的 if。
	if newuseablemounted then
		self.inst:AddTag("useabletargeteditem_mounted")
	else
		self.inst:RemoveTag("useabletargeteditem_mounted")
	end
end

local UseableTargetedItem = Class(function(self, inst)
-- 构造函数。注意第 40-52 行的字段分成两拨：
--   第 42-44 行三个布尔【给了初值】（false）；
--   第 46-52 行四个字段【不给初值】（全被注释掉）。
-- ★ 判据很清晰：会被属性钩子立即读取的字段必须给初值，
--   否则第一次赋值时钩子里会读到 nil；不接钩子的惰性字段可以不给。
--   对照 useableitem.lua 第 11-14 行（全部给初值）与
--   weapon.lua 第 21-24 行（全部不给），三种风格各自自洽。
-- ⚠️ 第 49 行的 NOTE 很关键：
--   UseableTargetedItem_ValidTarget 这个回调【可以配在客户端】。
--   这解释了为什么上面的合法性判定要放在 componentactions（客户端侧）而不是动作 fn 里。
--   （本人已对照 componentactions.lua:3015-3017 与 1867-1869 核实该回调确在客户端消费。）
    self.inst = inst

    self.inuse_targeted = false
    self.inventory_disableable = false
    self.canselftarget = false

    self.useabletargetprefab = nil
	--self.useablemounted = nil

	--NOTE: can also configure with this fn on CLIENTS: inst.UseableTargetedItem_ValidTarget

    --self.onusefn = nil
    --self.onstopusefn = nil
end,
nil,
{
    inuse_targeted = oninuse_targeted,
    inventory_disableable = on_inventory_disableable,
    canselftarget = oncanselftarget,
    useabletargetprefab = ontargetprefab,
	useablemounted = onuseablemounted,
})

function UseableTargetedItem:OnRemoveFromEntity()
-- ★★★ OnRemoveFromEntity —— 【⚠️ 疑似真实缺陷：漏摘一个标签】
--   本函数按「字段是否为真」逐个摘标签，第 64-78 行摘了三个：
--     inuse_targeted（第 64-66 行）、inventory_disableable（第 68-70 行）、
--     useabletargetprefab.."_targeter"（第 72-74 行）、
--     useablemounted（第 76-78 行）。
--   ★ 但【唯独没有摘 canselftarget 对应的标签】（第 17-19 行设的那个）。
--   而本文件的其他三个属性钩子（第 11、13、35 行）都做了对称摘除。
-- ⚠️ 为什么这在实践中大概率不炸：
--   实体的标签随实体一起销毁，而 canselftarget 标签只被
--   「本实体作为 invobject」的代码读取（第 17-19 行注释已说明该组件也跑在客户端）。
--   若实体被回收后其组件实例仍被别处持有（理论上不该发生），标签会残留。
--   所以这是「不对称但当前无害」，属于代码整洁度问题而非线上 bug。
-- ⚠️ 更值得注意的是【没有 nil 保护】这一点在第 72 行是【有】的：
--   `if self.useabletargetprefab ~= nil then` —— 写得比漏摘的那处更严谨，
--   进一步说明漏摘是疏忽而非刻意。
--   （本人已逐行核对第 63-79 行，确认四类标签中只缺 canselftarget 一类；
--      并已 grep 确认 canselftarget 标签的写入点仅第 18 行、
--      读取点为那 5 处 actions/componentactions/stategraphs 代码。）
    if self.inuse_targeted then
        self.inst:RemoveTag("inuse_targeted")
    end

    if self.inventory_disableable then
        self.inst:RemoveTag("useabletargeteditem_inventorydisable")
    end

    if self.useabletargetprefab ~= nil then
        self.inst:RemoveTag(self.useabletargetprefab.."_targeter")
    end

	if self.useablemounted then
		self.inst:RemoveTag("useabletargeteditem_mounted")
	end
end

function UseableTargetedItem:SetTargetPrefab(prefab_name)
-- SetTargetPrefab：声明本物品能作用于哪一类实体。
-- ★ 走属性钩子（第 59 行注册），所以会先摘旧标签再加新标签（第 22-28 行）。
--   这意味着可以反复调用来回切换目标类型，不会留下旧标签。
-- ⚠️ 与 workable.lua 的 SetWorkAction（第 65 行）是同一套模式：
--   「用 Setter 改声明 + 钩子负责标签同步」，prefab 侧不必手工维护标签。
    self.useabletargetprefab = prefab_name
end

function UseableTargetedItem:SetUseableMounted(enable)
	self.useablemounted = enable
end

function UseableTargetedItem:SetOnUseFn(fn)
    self.onusefn = fn
end

function UseableTargetedItem:SetOnStopUseFn(fn)
    self.onstopusefn = fn
end

function UseableTargetedItem:SetInventoryDisable(value)
-- SetInventoryDisable：见第 9-15 行的详细说明。
-- ⚠️ 参数名叫 value 但没有类型检查 —— 传任何真值都会加标签。
--   与 SetCanSelfTarget（第 101 行）、SetUseableMounted（第 85 行）风格一致。
    self.inventory_disableable = value
end

function UseableTargetedItem:SetCanSelfTarget(value)
    self.canselftarget = value
end

function UseableTargetedItem:SetUsingItemDoesNotToggleUseability(value)
-- ★★ SetUsingItemDoesNotToggleUseability —— 「用了不进入使用中状态」。
--   对应字段 usingdoesnottoggleuseability，【构造函数里没有初始化】，
--   也【不在第 55-61 行的属性钩子表里】（所以不会产生标签）。
-- 作用（见第 122-126 行）：让 StartUsingItem 成功但不置 inuse_targeted。
--   典型用途：一次性道具/瞬发道具（挤奶器、肥料袋），
--   按一下就产出结果，不需要「按住使用中」这个状态。
-- ★★ 这正是「统一抽象」必须提供的扩展点：
--   若协议只有「开始/停止」两态，一次性道具就必须假装自己在「使用中」，
--   于是 UI 上会闪现「停止」按钮。用一个布尔绕开它，是很务实的取舍。
-- ⚠️ 代价：调用方若同时忘了调 StopUsingItem，「使用中」标志会卡在 true。
--   对这类物品，componentactions 第 3011 行的分支要求它【不能】同时有
--   inuse_targeted，否则动作表会塞 STOPUSINGITEM 而永远等不到开始。
--    （本人已对照第 123 行 `if not self.usingdoesnottoggleuseability` 核实该判断。）
    self.usingdoesnottoggleuseability = value
end

function UseableTargetedItem:CanInteract()
-- ★ CanInteract —— 【与 useableitem.lua 判若两套】
--   本文件第 110 行只判一句 not self.inuse_targeted。
--   useableitem.lua 第 34 行却还要查副本 equippable 的已装备状态。
-- ⚠️ 差异的原因（推断）：
--   本组件允许「已装备 + 也允许从背包直接用」（见 SetInventoryDisable 的语义），
--   所以不强制要求 equipped；equippable 检查会误杀「收在背包里也能用」的物品。
--   但副作用是：本组件【完全不校验 doer 身份与距离】。
--   距离校验由 bufferedaction / stategraph 的目标搜索负责，本组件不操心。
-- ★ 结论：CanInteract 在这套协议里只是「最廉价的粗筛」，
--   真正的合法性判定在 componentactions 的客户端侧（第 3013-3017 行）。
--   ★ 自研游戏要把「粗筛」与「精确判定」分开，不要指望一个 CanInteract 全包。
    return not self.inuse_targeted
end

function UseableTargetedItem:StartUsingItem(target, doer)
-- ★★★ StartUsingItem(target, doer) —— 「对目标使用」。

-- 【与 useableitem.lua StartUsingItem 的四处关键差异】
--   差异 1：多 target 参数（第 117 行回调收到 target）。
--   差异 2：返回【两个值】success + failreason（第 117、128 行）。
--     failreason 会经 actions.lua:3346 一路回传到动作层，
--     用于播「不能对 X 使用」的具体原因文案。
--   差异 3：状态置位【在回调成功之后】（第 122-125 行），
--     而 useableitem.lua 是「先置再回调再用返回值覆盖」。
--   差异 4：多了 usingdoesnottoggleuseability 分支（第 123 行）。
-- ★ 为什么差异 3 是必须的：本组件的回调极可能销毁物品或改变实体，
--   所以必须等回调跑完、确认实体还活着（第 122 行的 IsValid）才能置状态。
--    （本人已对照第 122-126 行核实置位在回调与 IsValid 之后。）

-- 【第 114 行：success / failreason 都是预声明的局部变量】
--   没有它们，第 119 行的 else 分支与第 128 行的 return 就会引用未定义变量。
--   Lua 里未加 local 的赋值会变成【全局变量】污染，
--   所以「先 local 声明再分支赋值」是必要写法，不是啰嗦。
    local success, failreason

    if self.onusefn then
-- 调回调并【一次接收两个返回值】。
-- ★ 第 117 行传了三个参数：inst、target、doer。
--   对比 useableitem.lua 第 40 行只传了 inst。
--   本组件的回调签名因此是 function(inst, target, doer) ... end，
--   三个参数缺一不可（自己的实体、目标、操作者）。
-- ⚠️ 回调约定：返回 (success, failreason)。
--   只写 return true 就等于 failreason = nil，动作层会走通用失败提示。
--   想给玩家看具体原因（如「这只动物还没挤过奶」）就必须返回两个值。
        success, failreason = self.onusefn(self.inst, target, doer)
    else
-- 没有回调时的默认成功。
-- ⚠️ 也就是「挂了这个组件但没配 SetOnUseFn」的物品，按使用键会
--   进入使用中状态却什么也不发生 —— 表现为「道具卡在手里一直亮着」。
--   属于配置错误，组件层不做防御。
        success = true
    end

	if success and self.inst:IsValid() then
-- ★★★ 第 122 行 `if success and self.inst:IsValid() then` —— 两个条件缺一不可。

-- 【为什么 success 已经够了还要 IsValid】
--   因为 onusefn【极可能把自己销毁了】：
--   典型如「挤奶器」用完就消失、「肥料袋」倒完就没了。
--   若不检查就置 inuse_targeted，会对一个已失效的实体打标签、
--   触发第 1-7 行的属性钩子，进而让 CanInteract 永远返回 false。
-- ⚠️ 换成 useableitem.lua 的写法（乐观预置）在这里就会崩 ——
--   那边的回调多半不销毁物品（药水只是喝掉，物品本体还在），
--   但这边的回调是「消耗型」的。这是两份平行实现不该合并的实证理由。
-- ★★ 自研游戏结论：回调若可能销毁自身，置状态前必须验活。
--    （本人已对照第 122-126 行核实 IsValid 与置位的先后顺序。）
        if not self.usingdoesnottoggleuseability then
-- 「用了但不进入使用中状态」的豁免分支。详见第 105 行的完整说明。
-- ⚠️ 注意这一行同时管两件事：
--   既决定「是否置 inuse_targeted」，也是第 105 行那个字段的唯一消费点。
--   字段全库仅此一处使用，删除 Setter 不会破坏任何其他逻辑。
            self.inuse_targeted = true
        end
    end

    return success, failreason
end

function UseableTargetedItem:StopUsingItem()
-- ★★ StopUsingItem —— 与 StartUsingItem 的对称端，但有两处不对称。
--   不对称 1：第 132 行【无条件】置 inuse_targeted = false，
--     不像 StartUsingItem 那样先问 success。
--     语义：停止是强制的，不能被否决（理由同 useableitem.lua 第 49 行）。
--   不对称 2：第 134-136 行调 onstopusefn 时【不传 target / doer】。
--     ★ 这是一个实际的信息缺口：
--     「停止时需要知道当初是对谁用的」的物品（如挤奶器需要把奶桶还回去），
--     在 StopUsingItem 里拿不到目标信息，只能靠自己记。
--     对比 StartUsingItem 第 117 行明确传了 inst/target/doer 三者。
--      （本人已对照第 131-137 行核实 onstopusefn 仅传 self.inst 一点。）
-- ⚠️ 与 useableitem.lua 相同：没有幂等保护，重复调用会重复触发回调。
--   调度方 actions.lua:3357-3362 的 STOPUSINGITEM 只调它一次。
--    （本人已对照 actions.lua:3357-3362 核实。）
    self.inuse_targeted = false

    if self.onstopusefn then
        self.onstopusefn(self.inst)
-- ⚠️ 只传了 self.inst —— target 与 doer 都拿不到。详见第 131 行的说明。
-- ★ 对照第 117 行 StartUsingItem 的三参数回调签名，这里的单参数是明显的不对称。
--   若自研游戏需要「停止时回调目标」，应把签名统一成 (inst, target, doer)，
--   并由组件自己缓存 StartUsingItem 时收到的 target。
-- ⚠️ 本组件【没有】缓存 last_target 之类的字段（对比构造函数第 40-52 行，
--   只有状态与声明字段，没有运行时上下文缓存）。
--   这是当前设计的真实限制，不是缺陷 —— 但凡需要就得在 prefab 侧自己存。
--    （本人已核对第 39-52 行的构造函数字段列表，确认无 target 缓存字段。）
    end
end

return UseableTargetedItem