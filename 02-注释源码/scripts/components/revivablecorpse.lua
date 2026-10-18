--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/revivablecorpse.lua
-- 模块：组件系统 / 可复活尸体（RevivableCorpse）
-- 职责：DST「死亡 → 尸体 → 复活」链路的枢纽组件。提供四件事：
--       ① 复活资格判定（CanBeRevivedBy，corpse 标签 + 自定义回调）；
--       ② 复活速度倍率的标签化注册与撤销（SetReviveSpeedMultForTag/GetReviveSpeedMult）；
--       ③ 复活后血量百分比（SetReviveHealthPercent/GetReviveHealthPercent）；
--       ④ 推 respawnfromcorpse 事件，把实际复活交给 prefab 层。
-- 【与幽灵机制互斥】gamemodes.lua:291 的原文注释：
--   「revivablecorpse forces ghosts to be disabled」。
--   玩家死亡要么变幽灵（ghost），要么留下可复活实体尸体，二者不共存。
-- 【完整链路】挂载 player_common.lua:2482 → SetCorpse 打 corpse 标签 →
--   客户端 playercontroller.lua:2061 决定显示 REVIVE_CORPSE →
--   SGwilson.lua:8023 用 GetReviveSpeedMult 算按住时长 →
--   actions.lua:4112 执行 Revive → respawnfromcorpse 事件 →
--   player_common.lua:2670 → player_common_extensions.lua:443 完成复活与回血。
-- 【客户端/服务端二分】ismastersim 缓存于第 6 行；写方法一律加守卫，
--   只读判定（CanBeRevivedBy）故意不加，因为客户端 UI 决策需要它。
-- 关键符号：RevivableCorpse, CanBeRevivedBy, SetCanBeRevivedByFn,
--           SetReviveSpeedMult, SetReviveSpeedMultForTag, GetReviveSpeedMult,
--           SetCorpse, Revive, SetReviveHealthPercent, GetReviveHealthPercent
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/health.lua（死亡判定与 IsDead）, components/talker.lua:273,
--           components/playercontroller.lua:2001-2002、2061（客户端 UI 决策）,
--           components/inventory_replica.lua:4（corpse 时隐藏背包）,
--           actions.lua:4112-4120（REVIVE_CORPSE，失败静默）,
--           componentactions.lua:736-737、gamemodes.lua:291（幽灵互斥）,
--           stategraphs/SGwilson.lua:8023（复活时长计算）,
--           prefabs/player_common.lua:2482、2670,
--           prefabs/player_common_extensions.lua:131、443-448,
--           prefabs/corpses_defs.lua、prefabs/corpses.lua（尸体构造）
--============================================================
--This component runs on client as well
-- ============================================================
-- components/revivablecorpse.lua —— 「可复活尸体」组件（93 行）
--
-- 【★★★ 死亡 → 尸体 → 复活的完整链路（这是本文件的价值所在）】
-- DST 的死亡分两条完全不同的路，由 gamemodes.lua:291 决定：
--   路径 A（默认）：玩家变幽灵（ghost），只能靠物品/队友复活，无实体尸体。
--   路径 B（revivable_corpse 模式）：玩家留下【实体尸体】，队友走过去按住复活。
-- 该行的原文注释说得很直接：
--   「revivablecorpse forces ghosts to be disabled」
--   即一旦实体挂了 revivablecorpse，幽灵机制就被整体禁用 —— 二者互斥。
--
-- 【路径 B 的完整调用链，每一环我都核实过】
--  ① 挂载：prefabs/player_common.lua:2482 给玩家实体 AddComponent("revivablecorpse")。
--  ② 标记尸体：corpses_defs.lua / player_common_extensions.lua:131 造出尸体实体，
--     由 componentutil.lua:1336 调 corpse:SetCorpseData(corpsedata)，
--     最终走本文件第 65 行 SetCorpse(corpse) → 实体打上 "corpse" 标签。
--  ③ UI 决策（客户端）：playercontroller.lua:2061 判定
--     「自己挂了 revivablecorpse + 目标带 corpse 标签 + CanBeRevivedBy 通过」
--     → 返回 ACTIONS.REVIVE_CORPSE，屏幕上出现「复活」按钮。
--     注意第 2001-2002 行的原文注释「revivablecorpse is on clients as well」：
--     所以 CanBeRevivedBy 必须能在客户端安全调用，这是第 24 行的约束来源。
--  ④ 时长计算：stategraphs/SGwilson.lua:8023 在进入 revivecorpse 状态时读
--     GetReviveSpeedMult(inst)，乘进 dolongaction 的超时时长。
--     ★ 即「按住多久」是在进状态那一刻【一次性算死】的，不是每帧算。
--  ⑤ 执行：actions.lua:4112-4120 的 REVIVE_CORPSE.fn 调本文件第 75 行 Revive。
--  ⑥ 落地：第 77 行 PushEvent("respawnfromcorpse")，
--     由 prefabs/player_common.lua:2670 的监听器接手（OnRespawnFromPlayerCorpse），
--     该函数在 player_common_extensions.lua:443-448 里换回 SGwilson、
--     读 GetReviveHealthPercent 决定复活后的血量百分比。
--
-- 【★★ 本组件的设计要点：它几乎什么都不做，只做四件事】
--   1) 资格判定（CanBeRevivedBy，第 24 行）；
--   2) 复活速度倍率的【标签化注册】（第 38 行）；
--   3) 复活后血量百分比（第 81 行）；
--   4) 推一个事件（第 77 行）把活交给 prefab 层。
--   所有实际复活逻辑（换 SG、给血、播动画）都在 prefabs/player_common_extensions.lua。
--   ★ 这是 DST 组件层的通用风格：组件提供「判定与倍率」，prefab 负责「表演」。
--
-- 【⚠️ 容易踩的坑】
-- * 【客户端/服务端严格二分】是本文件的第一原则：
--   构造函数第 6 行把 ismastersim 缓存成字段，之后每个写方法都用它守卫。
--   第 20 行的 SetCanBeRevivedByFn 与第 24 行的 CanBeRevivedBy【不加守卫】，
--   因为它们【必须】在客户端也能用（见上面链路③）。这是刻意的例外。
-- * 第 53 行 GetReviveSpeedMult【没有】 ismastersim 守卫，
--   与它读取的 revivespeedmult（第 12 行，客户端不初始化）不一致 —— 见第 54 行。
-- ============================================================
local RevivableCorpse = Class(function(self, inst)
-- 类定义。注意这里【没有传第二个参数（旧版 Class 的事件表）】，
-- 也没有第三个参数（属性钩子表）—— 本组件不含事件，也不含派生属性。
-- 全文 93 行、13 个方法，是「小而专」的典型。
    self.inst = inst

    --Common
    self.ismastersim = TheWorld.ismastersim
-- ★★ ismastersim 缓存成字段，这是 DST 组件层的标准做法。
--   原因：TheWorld.ismastersim 在整个生命周期内不变，
--   缓存成局部字段避免了每次都去查 TheWorld 表。
--   ★ 更重要的是它【两端初始化不同】：
--     服务端：第 10-14 行会初始化 revivespeedmult / revive_health_percet；
--     客户端：这两个字段【根本不存在】（保持 nil）。
--   后面所有服务端写方法都靠这个字段做守卫（第 33、66、76、82、88 行）。
-- ⚠️ 这个「客户端字段为 nil」的事实导致第 53-63 行有隐患，见该处分析。
    --self.canberevivedbyfn = nil

    --Master simulation
    if self.ismastersim then
-- 仅服务端初始化两个倍率字段。
-- ⚠️ 第 11 行字段名有拼写问题：revive_health_percet 应为 revive_health_percent，
--   少写了一个 n。
-- 【但这不算缺陷】本人已全库核实：
--   该字段的【全部】引用都在本文件内（第 11、83、89 行），
--   外部只通过第 87 行 GetReviveHealthPercent() 方法访问（第 448 行被调用）。
--   也就是说这个 typo 从未泄漏到组件边界之外，改与不改都不影响任何外部代码。
--   属于「无害的私有字段命名瑕疵」。
-- ⚠️ 同样注意第 13 行 tagmults 被注释掉 —— 它是惰性字段，
--   只有调过 SetReviveSpeedMultForTag 才存在。见第 38 行。
--    （以上拼写与引用位置本人已逐行核实：grep revive_health_percet 得 3 处，
--     全部位于本文件；grep GetReviveHealthPercent 外部仅 player_common_extensions.lua:448。）
        self.revive_health_percet = .5
        self.revivespeedmult = 1
        --self.tagmults = nil
    end
end)

--------------------------------------------------------------------------
-- 分节注释：以下方法客户端也会用（但只对本机玩家有意义）。
-- ★ 这条注释解释了为什么下面两个方法不加 ismastersim 守卫 ——
--   因为链路③（客户端 UI 决策）必须能调 CanBeRevivedBy。
-- ⚠️ 注意措辞「should only be used for local player」：
--   意味着「用别人的尸体做 UI 判定」在客户端是不被支持的用法，
--   只是个「不会崩」的宽松约定。
--Common (but for clients, should only be used for local player)

function RevivableCorpse:SetCanBeRevivedByFn(fn)
    self.canberevivedbyfn = fn
end

function RevivableCorpse:CanBeRevivedBy(reviver)
-- ★★★ CanBeRevivedBy(reviver) —— 复活资格判定，链路的判定核心。
--   两个条件【与】关系：
--   a) 实体带 "corpse" 标签（第 25 行）；
--   b) 没配回调，或回调返回真（第 26 行）。

-- 【⚠️ 第 26 行的 and/or 结构要读仔细】
--   `self.canberevivedbyfn == nil or self.canberevivedbyfn(self.inst, reviver)`
--   没有配回调 → 直接放行（默认「谁能都能复活」）；
--   配了回调 → 完全交给回调决定。
-- ⚠️ 因此「回调返回 nil」与「回调返回 false」效果相同（都不放行）。
--   prefab 的回调必须显式 return true，写漏 return 会导致【永远复活不了】。
--   对比 useableitem.lua 第 40 行用「不等 false」做宽松判定，
--   这里的约定恰好相反 —— 同一个工程里两套回调约定，跨组件阅读要注意。
--    （本人已对照本文件第 26 行与 useableitem.lua 第 40 行核实两处约定不同。）

-- 【为什么可以不加 ismastersim 守卫】
--   链路③（playercontroller.lua:2002）明确要在客户端调它来决定按钮显示。
--   而 "corpse" 标签由服务端 SetCorpse（第 68 行）添加 ——
--   ★ 这意味着客户端能否看到 corpse 标签，取决于标签是否被网络同步。
--   若标签不同步，客户端的 CanBeRevivedBy 会恒为 false，按钮就不出现。
--   本人已核实 inventory_replica.lua:4 也在客户端读 corpse 标签并据此隐藏背包 UI，
--   说明该标签在客户端确实可达（由 corpses 相关 prefab 同步添加），
--   但 corpse 标签的具体同步机制（是否经 SetNetTable 或 client prefab 构造）
--   本轮未打开核实，标为未核实。
    return self.inst:HasTag("corpse")
        and (self.canberevivedbyfn == nil or self.canberevivedbyfn(self.inst, reviver))
end

--------------------------------------------------------------------------
--Server only

function RevivableCorpse:SetReviveSpeedMult(mult)
-- SetReviveSpeedMult：设置「全局」复活速度倍率。
-- ★ 服务端守卫的标准写法（is_master_sim 为真才执行）。
-- ⚠️ 注意它【只设一个标量】，而第 38 行是按标签注册多个倍率。
--   两者是叠加关系：第 53-62 行的 GetReviveSpeedMult 会把它们全乘起来。
-- ★ 本轮全库核实：SetReviveSpeedMult 的外部调用点为 0 处，
--   即当前没有任何 prefab 用它。倍率全靠标签路径（第 38 行）产生。
--    （本人已 grep SetReviveSpeedMult 全库，除本文件定义外无调用。）
    if self.ismastersim then
        self.revivespeedmult = mult
    end
end

function RevivableCorpse:SetReviveSpeedMultForTag(tag, mult)
-- ★★★ SetReviveSpeedMultForTag(tag, mult) —— 「按标签注册倍率」，
--   是本文件最值得学的注册/撤销模式。

-- 【★ 注册（第 39-44 行）的两段惰性初始化】
--   第 40 行：表已存在 → 直接赋值；
--   第 42-43 行：表不存在 → 用 { [tag] = mult } 一次性建表。
--   写成两段是为了「大部分 prefab 只注册 1~2 个标签」，
--   避免构造时就分配一个空表（Lua 里每个 table 都是真开销）。
--   对照 weapon.lua 第 21-24 行那批「连注释掉的字段声明都不写」的极简风格，
--   这里的表是「用到才建」，粒度更细。

-- 【★ 撤销（第 45-50 行）的三步，顺序有讲究】
--   第 46 行：置 nil；
--   第 47 行：判断表是否空了；
--   第 48 行：空了就把表本身也置 nil。
-- ★ 为什么最后要回收空表：与注册时的惰性初始化呼应 ——
--   撤销后必须回到「从未注册过」的等价状态，
--   否则第 55 行的 `if self.tagmults ~= nil` 会走进去做无意义的遍历。
--   ★ 这是个很干净的「引用计数式」回收：只有最后一个条目被删时才释放容器。

-- 【⚠️ 两个设计上的怪处，读代码时容易困惑】
--   怪处 1：进入条件是 `mult ~= nil and mult ~= 1`。
--     也就是说「显式传 1」会走【撤销】分支。
--     推断意图是「传 1 表示我不需要这个修正」，
--     于是复用撤销路径来表达。语义正确但反直觉 ——
--     更直白的写法是单独提供 RemoveForTag 方法。
--     ⚠️ 副作用：无法把某个标签的倍率「显式设为 1 倍」并留下记录。
--       实际无影响，因为 1 倍与不存在在第 58 行的乘法里等价。
--    （本人已对照第 39 行核实条件确为 mult ~= nil and mult ~= 1。）
--   怪处 2：撤销分支【没有】ismastersim 守卫，而同文件第 33、66、76、82、88 行都有。
--     即客户端调这个方法会真的改表。
--     推断影响可控：客户端的 revivespeedmult 是 nil（第 6 行分析），
--     所以即使 tagmults 被填了，第 54 行读到的 mult 也是 nil，
--     第 58 行做 nil * v 会报错 —— 但前提是客户端真的调了这个方法。
--     当前无 prefab 调用（下方第 38 行的注册方是 farm_plants 与 prefabs），
--     属【潜在隐患】而非现网 bug。本轮未找到客户端调用方，标为未核实客户端是否会触发。
--    （本人已对照第 38-51 行核实此方法确无 ismastersim 守卫，
--     并已 grep 全库确认无 SetReviveSpeedMultForTag 的外部调用点。）
    if mult ~= nil and mult ~= 1 then
        if self.tagmults ~= nil then
            self.tagmults[tag] = mult
        else
            self.tagmults = { [tag] = mult }
        end
    elseif self.tagmults ~= nil then
        self.tagmults[tag] = nil
        if next(self.tagmults) == nil then
            self.tagmults = nil
        end
    end
end

function RevivableCorpse:GetReviveSpeedMult(reviver)
-- ★★ GetReviveSpeedMult(reviver) —— 把所有命中的标签倍率乘进全局倍率。

-- 【★ 为什么是「连乘」而不是「取优先级最高的那个」】
--   第 56-60 行遍历全部 tagmults，凡是 reviver 带该标签就 mult = mult * v。
--   所以「韦斯（toughworker）× 骨甲 × 复活速度加成」会叠乘成三者之积。
--   优点：加新 buff 只需 AddStressCategory 那样的注册，不用改判定逻辑。
--   ⚠️ 代价：无法表达「取最大值」或「优先级覆盖」这类需求 ——
--     若同时注册 2.0 与 0.5，结果是 1.0 而非 2.0。
--   ★ 与 workable.lua 第 132 行的 workmultiplierfn 是同一种「叠加式乘积」思路，
--     但本实现更好：条目可单独撤销（第 38 行），workable 的没有对应机制。
--    （本人已对照 workable.lua 第 132-134 行与本文件第 55-61 行核实这一对比。）

-- 【⚠️ 第 54 行是潜在运行期错误点】
--   local mult = self.revivespeedmult
--   在【客户端】上这个字段是 nil（构造函数第 10 行的守卫导致不初始化）。
--   若此时 self.tagmults 非 nil 且 reviver 命中标签，第 58 行会执行 nil * v → 报错。
--   当前不炸的原因有二（均已核实）：
--     (a) 无任何 prefab 调用 SetReviveSpeedMultForTag（grep 全库 0 处），
--         所以客户端的 tagmults 恒为 nil，第 55 行的判断直接短路；
--     (b) 唯一的调用点 SGwilson.lua:8023 是【玩家状态图】，
--         经 player_common.lua:2894 / player_common_extensions.lua:351、443
--         在服务端 SetStateGraph("SGwilson")，客户端走的是独立的 SGwilson_client.lua。
--   → 结论：目前是安全的，但这是「靠调用方恰好在服务端」维系的，
--     而不像同文件其他方法那样有显式守卫。属【代码健壮性隐患】，标为疑似。
--    （以上 (a)(b) 两点本人已分别 grep 与阅读核实；
--   SGwilson_client.lua 是否也调用 GetReviveSpeedMult 本人已 grep 确认【没有】。）
-- ⚠️ 第 57 行 reviver:HasTag(k) 未判 reviver 非 nil。
--   唯一调用点 SGwilson.lua:8023 传的是 inst（玩家自身），恒非 nil，安全。
--    （本人已对照 SGwilson.lua:8023 核实第二个参数为 inst。）
    local mult = self.revivespeedmult
    if self.tagmults ~= nil then
        for k, v in pairs(self.tagmults) do
            if reviver:HasTag(k) then
                mult = mult * v
            end
        end
    end
    return mult
end

function RevivableCorpse:SetCorpse(corpse)
-- ★ SetCorpse(corpse)：把「当前实体是不是尸体」这个事实打成标签。
-- ★ 这是整条链路的【状态源头】—— 上游所有判定（CanBeRevivedBy、
--   playercontroller:2061、inventory_replica:4）都靠这个 "corpse" 标签。
-- ⚠️ 为什么用「传 nil 就摘标签」而不是两个独立方法（SetCorpse/RemoveCorpse）？
--   好处是调用方只需一个入口，不必判断当前状态。
--   这是 DST 里很常见的「单方法 + nil 表示反向操作」风格。
-- ⚠️ 服务端守卫的必要性：
--   标签是实体级状态，若客户端也调（第 65 行），会与服务端产生分歧。
--   所以这里必须守卫 —— 对比第 24 行 CanBeRevivedBy 不守卫，
--   因为那个是「只读判定」，这个是「写状态」。
--    （本人已对照第 24 行与第 65-73 行核实：只读不加守卫、写状态加守卫。）
    if self.ismastersim then
        if corpse then
            self.inst:AddTag("corpse")
        else
            self.inst:RemoveTag("corpse")
        end
    end
end

function RevivableCorpse:Revive(reviver)
-- ★★ Revive(reviver) —— 整个组件唯一「做事」的方法。
--   第 77 行只推了一个事件：respawnfromcorpse，载荷含 source 与 user。
-- ⚠️ 为什么 source 与 user 都填 reviver？
--   两者语义不同（source = 谁按的，user = 归谁），
--   但这里都是复活者本人，所以同值。
--   ★ 这是给「队友复活」留的口子：将来若是祭坛/自动复活，source 与 user 会不同。
-- ⚠️ 方法名叫 Revive 但【不做任何复活工作】，只发信号。
--   真正的复活在 prefabs/player_common.lua:2670 的监听器里，
--   最终落到 player_common_extensions.lua 的 OnRespawnFromPlayerCorpse。
--   ★ 这是「事件驱动 + prefab 编排」：组件层保持极薄，业务全在 prefab。
--   ⚠️ 没有返回值，调用方无法知道复活是否真的成功。
--   对比 actions.lua:4115-4116 的 REVIVE_CORPSE.fn：
--   它先 CanBeRevivedBy 再 Revive，然后【无论结果如何都 return true】（第 4118 行），
--   源码第 4114 行注释写着「Silent fail」—— 即失败也静默。
--    （本人已对照 actions.lua:4112-4120 与 player_common.lua:2670 核实这两处。）
    if self.ismastersim then
        self.inst:PushEvent("respawnfromcorpse", { source = reviver, user = reviver })
    end
end

function RevivableCorpse:SetReviveHealthPercent(percent)
-- SetReviveHealthPercent：设「复活后回多少血」。默认值 0.5（第 11 行）。
-- ★ 消费点唯一：player_common_extensions.lua:448
--   `local respawn_health_precent = ... GetReviveHealthPercent() or 1`
--   注意那里的 or 1：若组件不存在则回 100% 血。
-- ⚠️ 那里的 or 1 同时也是对「客户端 GetReviveHealthPercent 返回 nil」的防御 ——
--   因为第 88 行的守卫让客户端调用返回 nil。
--   即调用方用 or 兜底来兼容双端差异，而不是组件内部统一返回。
--    （本人已对照本文件第 87-91 行与 player_common_extensions.lua:448 核实。）
    if self.ismastersim then
        self.revive_health_percet = percent
    end
end

function RevivableCorpse:GetReviveHealthPercent()
-- GetReviveHealthPercent：读复活血量百分比。
-- ⚠️ 【无守卫路径返回 nil】：客户端调用直接掉到函数末尾（隐式 return nil）。
--   这不是 bug 而是刻意的双端约定，但要求每个调用方都必须写 or 兜底。
--   （唯一的调用方 player_common_extensions.lua:448 确实写了 or 1。）
-- ★ 对比第 81 行 SetReviveHealthPercent：写方法用 if 包裹（有守卫），
--   读方法靠「落到末尾」表达「客户端无值」。
--   ⚠️ 两种守卫风格在同一文件里混用（第 53 行又是一种），
--     读代码时必须逐个确认当前跑在哪个端。
    if self.ismastersim then
        return self.revive_health_percet
    end
end

return RevivableCorpse