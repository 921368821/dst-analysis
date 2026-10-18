--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/shadowwaxwellbrain.lua
-- 模块：AI 大脑 / 暗影沃克斯的暗影碎片
-- 职责：装配暗影碎片 AI。★★★ 本文件最大看点：【一个大脑按 prefab 分派出
--       三棵完全不同的行为树】—— 工匠（采集+送货+打卡自毁）、
--       守卫（守点战斗+打卡自毁）、以及源码自标 DEPRECATED 的兜底分支
--       （决斗者风筝 / 伐木 / 挖矿 / 挖土）。另含「多圈搜索 + 距离闸」
--       组合拳、三级保守的战斗推断（IsLeaderInCombat）、Keep Working
--       状态图动作协议补偿、跟随者软锁表挂在主人身上等模式。
-- 关键符号：ShadowWaxwellBrain, FindAnyEntityToWorkActionsOn,
--           FilterAnyWorkableTargets, IsLeaderInCombat, CreateIdleOblivion,
--           ShouldRunAway, ShouldKite, FindEntityToWorkAction（已废弃）,
--           BrainCommon.NodeAssistLeaderPickUps, OnInitializationComplete
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（拾取/软锁底座）,
--           behaviours/{wander,faceentity,chaseandattack,panic,follow,
--           attackwall,standstill,leash,runaway}.lua,
--           components/{follower,inventory,locomotor}.lua,
--           tuning.lua（SHADOWWAXWELL_WORKER_WORK_RADIUS_LOCAL 等）
--============================================================
require "behaviours/wander"
--[ [
-- shadowwaxwellbrain.lua —— 暗影沃克斯的暗影碎片大脑
--
-- 【★★★ 全文件唯一的重大设计：一个大脑，三棵树】
--   第 362、440 行按 self.inst.prefab 分派：
--     prefab == "shadowworker"   → 工匠树（干活、送货、打卡自毁）
--     prefab == "shadowprotector" → 守卫树（守点、打卡自毁）
--     其他（duelist/lumber/miner/digger）→ ★ 标注为 "Fallback to DEPRECATED thinking"
--   ★★ 这是「按实体种类分派行为」的一个极端例子：
--     同一文件里三棵结构完全不同的 PriorityNode，各自独立构建。
--   ★ 移植价值：想用「一个大脑管一族生物」，这就是 DST 的答案。
--   ⚠️ 注意第 458 行的源码原注释直言第三分支是 "DEPRECATED"（已废弃）——
--     这是原作者标注的技术债，不是我们的判断。
--
-- 【三种暗影碎片的分工】
--   工匠   —— 采集（伐木/挖矿/挖地）+ 捡东西送给主人
--   守卫   —— 只战斗，守在出生点周围
--   决斗者 —— 会风筝（kiting），先躲再打
--   伐木/挖矿/挖土 —— 单一工种，只做一件事
--   ★ 全部共用同一个 master（暗影沃克斯），用 follower 组件的 leader 关联。
--
-- 【⚠️ 容易踩的坑】
-- · 第 88 行 FindEntityToWorkAction 已被源码标注 DEPRECATED，
--   第 169 行 FindAnyEntityToWorkActionsOn 是替代品。第 440 行之后仍在用旧的。
-- · 第 123 行 ignorethese 是「本地」软锁表，但第 366 行取的是
--   leader._brain_pickup_ignorethese —— ★ 挂在【主人】身上！
--   这样多个碎片共享同一张锁表，避免两只碎片抢同一堆石头。
-- · 第 495 行 OnInitializationComplete：★ 在大脑初始化完成的回调里
--   保存出生点。与 beargerbrain（第 308 行）同款手法。
--] ]
require "behaviours/faceentity"
require "behaviours/chaseandattack"
require "behaviours/panic"
require "behaviours/follow"
require "behaviours/attackwall"
require "behaviours/standstill"
require "behaviours/leash"
require "behaviours/runaway"

local BrainCommon = require("brains/braincommon")

local ShadowWaxwellBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

--Images will help chop, mine and fight.

local MIN_FOLLOW_DIST = 0
-- ★ 跟随距离：0 / 6 / 8。注意 MIN=0 —— 暗影碎片可以完全贴脸。
--   ★ 与 pigbrain 的 2/5/9 对比：碎片是「贴身仆从」，猪是「保持距离的同伴」。
--   数值差异直接反映角色定位。
local TARGET_FOLLOW_DIST = 6
local MAX_FOLLOW_DIST = 8

local START_FACE_DIST = 4
-- 注视距离 4/8 —— 启停跨度比 pigbrain 的 4/6 更宽，
--   即「开始看」得近、「放弃看」得远，视线粘性更强。
local KEEP_FACE_DIST = 8

local KEEP_WORKING_DIST = 14
-- ★ KEEP_WORKING_DIST=14 与 SEE_WORK_DIST=10（第 27 行）构成又是「反向」关系：
--   「继续干」的判定（14）比「找新目标」的搜索半径（10）还大。
--   与 pigbrain 的 keepgoing(10) < finder(15) 相反。
-- ★ 两种反向写法各有道理：这里「已经开工了就干到主人附近为止」，
--   容忍更大的距离偏离；猪那边则相反。★ 对照阅读能看出调参思路的差异。
local SEE_WORK_DIST = 10

local KEEP_DANCING_DIST = 2
-- 跳舞时保持在主人 2 距离内 —— 舞伴就该贴在一起。

local KITING_DIST = 3
-- ★ 风筝（kiting）距离 3/5：退到 3 开外，5 停下。
--   KITING 是「放风筝」的英文写法，指边跑边打 —— 见第 248 行 ShouldKite。
--   ★ 决斗者是唯一会风筝的暗影碎片，其战斗节奏与守卫完全不同。
local STOP_KITING_DIST = 5

local RUN_AWAY_DIST = 5
local STOP_RUN_AWAY_DIST = 8

local AVOID_EXPLOSIVE_DIST = 5
-- 躲爆炸物的距离 5。与 RUN_AWAY_DIST 相同但用途不同。

local DIG_TAGS = { "stump", "grave", "farm_debris" }
-- DIG 的额外标签要求：只挖树桩、坟墓、农场残骸。
-- ★ 与 braincommon 第 201 行 DIG_ONEOF_TAGS = { "farm_debris", "tree" }
--   几乎相同，区别是这里多了 "grave"（坟墓）。
--   ⚠️ 属于轻微的重复定义：braincommon 已有一份，本文件又写一份。
--   已逐字核对两份标签：braincommon 缺 "grave"，其余相同。
--   不构成行为差异（因为第 478-483 行只在 prefab 分支里用），
--   但确实是配置分散的迹象。

local WANDER_TIMING = {minwaittime = 6, randwaittime = 6}

local function Unignore(inst, sometarget, ignorethese)
-- ★★★ ignorethese 软锁机制的又一个实现（braincommon 第 449-460 行同款）。
--   【机制】worker 盯住某目标时登记，5 秒后由 leader 的定时任务自动解锁。
--   【为什么表要挂在 leader 上】第 366-367 行：
--     ignorethese = leader._brain_pickup_ignorethese or {}
--     leader._brain_pickup_ignorethese = ignorethese
--   ★ 目的：让同一主人的多个碎片共享一张锁表。
--     若每个碎片自己建表，两只碎片会同时盯上同一块石头。
--   ⚠️ 第 364-368 行只在 leader 非 nil 时建表；若 owner 先消失，
--     表会随 leader 一起消失，碎片手上的引用失效。
--     已核对第 429 行 BrainCommon.NodeAssistLeaderPickUps 传的是 pickupparams.ignorethese，
--     而第 411 行用 pickupparams.ignorethese 取值，链路一致。
--   ⚠️ 真实隐患：若 leader == nil，ignorethese 为 nil，
--     第 187 行 shadowwaxwell 第 140 行等处的 ignorethese[sometarget] 会崩。
--   但第 175 行 GetLeader 为 nil 时提前 return nil，故实际不会走到。
--   结论：靠调用方前置条件保护，非缺陷，但耦合紧。
    ignorethese[sometarget] = nil
end
local function IgnoreThis(sometarget, ignorethese, leader, worker)
    if ignorethese[sometarget] ~= nil and ignorethese[sometarget].task ~= nil then
        ignorethese[sometarget].task:Cancel()
        ignorethese[sometarget].task = nil
    else
        ignorethese[sometarget] = {worker = worker,}
    end
    ignorethese[sometarget].task = leader:DoTaskInTime(5, Unignore, sometarget, ignorethese)
end

local function GetLeader(inst)
-- GetLeader：follower 组件取队长。全DST 随从 AI 的第一行标配。
    return inst.components.follower and inst.components.follower:GetLeader()
end

local function GetLeaderPos(inst)
-- ⚠️ 第 61 行 GetLeader(inst):GetPosition() —— 【没有判 GetLeader 为 nil】。
--   已逐字核对第 61 行确认无判空。
--   ★ 因此第 348 行 dance_party 的 Leash 锚点在「无主人」时会崩。
--   但第 346 行 WhileNode 条件是 ShouldDanceParty（第 221 行），
--   而后者第 223 行判了 leader ~= nil —— ★ 靠外层保护。
--   结论：与 mermbrain 第 175 行同样的模式（见那份注释），靠调用方保证。
    return GetLeader(inst):GetPosition()
end

local function GetFaceTargetFn(inst)
-- ★ 与 knightbrain 第 42 行逐字相同：排除 notarget 标签的玩家。
--   ★★★ 这是 DST 的跨文件一致性证据：
--     两个完全不同的大脑（一个 NPC、一个 Boss）、不同作者时期，
--     却有逐字相同的 GetFaceTargetFn/KeepFaceTargetFn。
--     说明这类「标准动作」是抄来抄去的，★ 也说明它已被验证可靠。
    local target = FindClosestPlayerToInst(inst, START_FACE_DIST, true)
    return target ~= nil and not target:HasTag("notarget") and target or nil
end

local function KeepFaceTargetFn(inst, target)
    return not target:HasTag("notarget") and inst:IsNear(target, KEEP_FACE_DIST)
end

local function GetFaceLeaderFn(inst)
-- ★ GetFaceLeaderFn 比 knightbrain 第 55 行多两个条件：
--   target.entity:IsVisible() 且 inst:IsNear(target, START_FACE_DIST)（4）。
--   而 KeepFaceLeaderFn（第 79 行）用的是 KEEP_FACE_DIST（8）。
--   ★ get 用 4、keep 用 8，形成正确的迟滞。
	local target = GetLeader(inst)
	return target ~= nil and target.entity:IsVisible() and inst:IsNear(target, START_FACE_DIST) and target or nil
end

local function KeepFaceLeaderFn(inst, target)
	return target.entity:IsVisible() and inst:IsNear(target, KEEP_FACE_DIST)
end

local function IsNearLeader(inst, dist)
    local leader = GetLeader(inst)
    return leader ~= nil and inst:IsNear(leader, dist)
end

local TOWORK_CANT_TAGS = { "fire", "smolder", "event_trigger", "waxedplant", "INLIMBO", "NOCLICK", "carnivalgame_part" }
-- TOWORK_CANT_TAGS：不能采集的东西。
-- ★ 比 braincommon 第 198 行的 MINE_CANT_TAGS 多了两个：
--   fire（正在烧）—— 碎片不该往火里走
--   smolder（阴燃）—— 余烬同样危险
--   INLIMBO / NOCLICK —— 标准排除
-- ★ 差异原因：暗影碎片没有「挖不动就跑」的顾虑，所以可以更保守。
local function FindEntityToWorkAction(inst, action, addtltags) -- DEPRECATED, use FindAnyEntityToWorkActionsOn.
-- ★⚠️ 源码已标注 DEPRECATED（废弃），替代品是第 169 行的版本。
--   但第 478-483 行仍在用它！
--   ★ 说明「废弃」只完成了一半：新逻辑给工匠用了，旧逻辑还服务于旧碎片。
--   已核对第 478-483 行确实调用 FindEntityToWorkAction，非笔误。
--   不标为缺陷（源码自己承认是技术债），但移植时要警惕这类半迁移状态。
    local leader = GetLeader(inst)
    if leader ~= nil then
        --Keep existing target?
-- ★★ 「优先保持已有目标」—— 一个目标必须通过 9 重校验才能续用：
--  1) target ~= nil  2) IsValid  3) 不在 limbo  4) 不 NOCLICK  5) 不是 event_trigger
--  6) IsOnValidGround（不在水面上/悬崖）
--  7) 有 workable 组件  8) CanBeWorked（没被别人抢去干活）
--  9) GetWorkAction() == action（还是这个动作，比如没从砍树变成挖矿）
-- 10) 不在燃烧/阴燃
-- 11) 可见  12) 距主人 14 距离内
-- ★ 第 101 行 action 相等判断是关键：换了工种就该换目标，不能将就。
--   ★ 第 108-113 行 addtltags 是可选的额外标签要求（只对特定标签生效）。
--     有 addtltags 时遍历它，有任一匹配就返回；无则直接返回。
        local target = inst.sg.statemem.target
        if target ~= nil and
            target:IsValid() and
            not (target:IsInLimbo() or
                target:HasTag("NOCLICK") or
                target:HasTag("event_trigger")) and
            target:IsOnValidGround() and
            target.components.workable ~= nil and
            target.components.workable:CanBeWorked() and
            target.components.workable:GetWorkAction() == action and
            not (target.components.burnable ~= nil
                and (target.components.burnable:IsBurning() or
                    target.components.burnable:IsSmoldering())) and
            target.entity:IsVisible() and
            target:IsNear(leader, KEEP_WORKING_DIST) then

            if addtltags ~= nil then
                for i, v in ipairs(addtltags) do
                    if target:HasTag(v) then
                        return BufferedAction(inst, target, action)
                    end
                end
            else
                return BufferedAction(inst, target, action)
            end
        end

        --Find new target
-- ★ 第 120 行 FindEntity(leader, SEE_WORK_DIST, ...) —— 以【主人】为中心搜索！
--   不是以自己为中心。所以碎片会离开自己的位置去找主人附近的资源。
--   ★ 与 braincommon 第 303 行「自己找不到再以 leader 找」的两段式不同：
--     本文件直接用 leader 为中心，省掉了第一段。
--   ★ 这是「参数决定搜哪」的简化版，代价是可能要跑很远（超过 leash 范围）。
        target = FindEntity(leader, SEE_WORK_DIST, nil, { action.id.."_workable" }, TOWORK_CANT_TAGS, addtltags)
        return target ~= nil and BufferedAction(inst, target, action) or nil
    end
end

local ANY_TOWORK_ACTIONS = {ACTIONS.CHOP, ACTIONS.MINE, ACTIONS.DIG}
-- ANY_TOWORK_ACTIONS：三种采集动作的集合。
-- ★ 设计意图：一个函数（FindAnyEntityToWorkActionsOn）处理三种工作，
--   而不是为每种写一份。这是「多态化」的收益：新增第四种只需加进这个表。
-- ⚠️ 但代价是失去了「按工种特化」的可能 —— 无法对砍树/挖矿做差异化处理。
local ANY_TOWORK_MUSTONE_TAGS = {"CHOP_workable", "MINE_workable", "DIG_workable"}
-- ONE_OF 语义：「三样里有一种可采集」就行，用于 TheSim:FindEntities 的粗筛。
-- ★ 与 MUST_TAGS 的区别很关键，这里是 any-of（任一即可）。
local function PickValidActionFrom(target)
-- PickValidActionFrom：把目标实体反查成「该对它做什么动作」。
-- ★ 即「按对象的 workable 组件决定动作」，而不是「按动作找对象」。
--   两种设计方向：前者一次搜索支持多动作，后者需要多次搜索。
-- ★ 这是本文件对废弃版的改进点之一，避免了第 125 行的三重分支。
    if target.components.workable == nil then
        return nil
    end

    local desiredact = target.components.workable:GetWorkAction()
    for _, act in ipairs(ANY_TOWORK_ACTIONS) do
        if desiredact == act then
            return act
        end
    end
    return nil
end
local function FilterAnyWorkableTargets(targets, ignorethese, leader, worker)
-- ★★ FilterAnyWorkableTargets —— 带「软锁」的过滤器，逻辑很讲究：
-- 【第 142 行】被别的 worker 锁住 → 跳过（注释写了 "Ignore me!"）
-- 【第 144 行】正在燃烧/阴燃 → 跳过
-- 【第 145-153 行】DIG 特例：还要在 DIG_TAGS 里
--   ★ 第 148 行 GetWorkLeft() == 1 时登记软锁：
--     「只剩一点工作量」的资源，先锁住防止别人也来抢。
--   ★ 含义：碎片会把「快做完的活」当成自己的，避免做到一半被抢走。
-- 【第 155-157 行】CHOP/MINE 没有特例，但同样有 GetWorkLeft() == 1 的锁。
-- ★ 注意第 151 与 158 行都是 return：找到第一个可用就返回，不排序。
--   所以优先级取决于 TheSim:FindEntities 的返回顺序（通常是创建顺序）。
    for _, sometarget in ipairs(targets) do
        if ignorethese[sometarget] ~= nil and ignorethese[sometarget].worker ~= worker then
            -- Ignore me!
        elseif sometarget.components.burnable == nil or (not sometarget.components.burnable:IsBurning() and not sometarget.components.burnable:IsSmoldering()) then
            if sometarget:HasTag("DIG_workable") then
                for _, tag in ipairs(DIG_TAGS) do
                    if sometarget:HasTag(tag) then
                        if sometarget.components.workable:GetWorkLeft() == 1 then
                            IgnoreThis(sometarget, ignorethese, leader, worker)
                        end
                        return sometarget
                    end
                end
            else -- CHOP_workable and MINE_workable has no special cases to handle.
                if sometarget.components.workable:GetWorkLeft() == 1 then
                    IgnoreThis(sometarget, ignorethese, leader, worker)
                end
                return sometarget
            end
        end
    end
    return nil
end

local function GetSpawn(inst)
-- GetSpawn：取出生点。这是全文件的「空间锚点」来源。
-- ★ 第 374 行 ShouldDeliver 也用它作为送货目标 ——
--   所以「在主人附近」被换算成「在出生点附近」，
--   因为暗影碎片的活动范围以出生点为界（见第 428 行 leash）。
-- ★ 这是一个巧妙的降维：主人到处跑，但碎片只在出生点小范围内活动，
--   所以用出生点当「主人的代表位置」既近似又稳定（不会抽搐）。
	return inst.GetSpawnPoint ~= nil and inst:GetSpawnPoint() or nil
end

local function FindAnyEntityToWorkActionsOn(inst, ignorethese) -- This is similar to FindEntityToWorkAction, but to be very mod safe FindEntityToWorkAction has been deprecated.
-- ★★ FindAnyEntityToWorkActionsOn —— 替代废弃版的统一采集实现。
-- 【四段式】
--  第 170-172 行：状态图忙 → 不干（★ 与旧版不同，新版没有这一条在开头而是分散）
--  第 173-176 行：★ 无主人 → 直接放弃（注释："没有线的木偶没有存在的意义"）
--  第 178-193 行：复用旧目标（校验比旧版少，没查 KEEP_WORKING_DIST）
--  第 196-212 行：找新目标 —— ★★★ 两级同心圆搜索
--    先搜「自己附近的」SHADOWWAXWELL_WORKER_WORK_RADIUS_LOCAL
--    再搜「出生点附近的」SHADOWWAXWELL_WORKER_WORK_RADIUS
--    第 204-209 行：★ 但从出生点搜的结果还要过一道距离闸：
--      目标离出生点超过 LOCAL + RADIUS 就不认（说明它是碎片「顺路」才够到的）
-- 【★ 为什么这样设计】
--   第 202 行搜的是自己附近（小范围，反应快），
--   第 211 行搜的是出生点附近（大范围，覆盖主人要求的远处目标），
--   第 206 行再剪掉「离出生点太远」的 —— 三步组合出「在允许范围内尽量帮忙」的行为。
--   ★ 这是全DST 最值得学的「多圈搜索 + 距离闸」组合拳。
	if inst.sg:HasStateTag("busy") then
		return nil
	end
    local leader = GetLeader(inst)
    if leader == nil then -- There is no purpose for a puppet without strings attached.
        return nil
    end

    local target = inst.sg.statemem.target
    local action = nil
    if target ~= nil and target:IsValid() and not (target:IsInLimbo() or target:HasTag("NOCLICK") or target:HasTag("event_trigger") or target:HasTag("waxedplant")) and
        target:IsOnValidGround() and target.components.workable ~= nil and target.components.workable:CanBeWorked() and
        not (target.components.burnable ~= nil and (target.components.burnable:IsBurning() or target.components.burnable:IsSmoldering())) and
        target.entity:IsVisible() then
        -- Check if action is the one desired still.
        action = PickValidActionFrom(target)

        if action ~= nil and ignorethese[target] == nil then
            if target.components.workable:GetWorkLeft() == 1 then
                IgnoreThis(target, ignorethese, leader, inst)
            end
            return BufferedAction(inst, target, action)
        end
    end
    -- 'target' is invalid at this point, find a new one.

    local spawn = GetSpawn(inst)
    if spawn == nil then
        return nil
    end

    local px, py, pz = inst.Transform:GetWorldPosition()
-- 第一级搜索：自己周围。半径是 LOCAL（小）。
-- ★ 参数顺序：TheSim:FindEntities(x,y,z, 半径, MUST_TAGS, CANT_TAGS, ONE_OF_TAGS)
--   —— 与 FindEntity 不同，第 5 参是排除、第 7 参才是「任一」。
--   ⚠️ 与 braincommon 第 25 行的 FindEntity 参数顺序又不一样，
--     三个搜索函数三种顺序，移植时必须逐个核对，这是本项目最大的坑之一。
    local target = FilterAnyWorkableTargets(TheSim:FindEntities(px, py, pz, TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS_LOCAL, nil, TOWORK_CANT_TAGS, ANY_TOWORK_MUSTONE_TAGS), ignorethese, leader, inst)
    if target ~= nil then
        local maxdist = TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS + TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS_LOCAL
-- ★★ 距离闸门的实现（第 204-209 行）：
--   只算水平距离（dx, dz），不含 y。
--   超过 LOCAL + RADIUS 就不认这个目标。
-- ★ 语义：即使从出生点周围搜到了，若它离出生点太远也不要 ——
--   因为那意味着「主人要求了一个碎片不该跑那么远去做的活」。
-- ⚠️ 第 206 行 (dx*dx + dz*dz) 与 maxdist*maxdist 是平方比较，正确。
        local dx, dz = px - spawn.x, pz - spawn.z
        if dx * dx + dz * dz > maxdist * maxdist then
            target = nil
        end
    end
    if target == nil then
        target = FilterAnyWorkableTargets(TheSim:FindEntities(spawn.x, spawn.y, spawn.z, TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS, nil, TOWORK_CANT_TAGS, ANY_TOWORK_MUSTONE_TAGS), ignorethese, leader, inst)
    end
    action = target ~= nil and PickValidActionFrom(target) or nil
    return action ~= nil and BufferedAction(inst, target, action) or nil
end

local function DanceParty(inst)
-- DanceParty：推 dance 事件给实体，由状态图播放舞蹈动画。
-- ★ 与 abigailbrain 第 25 行的 DanceParty 逐字相同 ——
--   这类「推事件让状态图播动画」的小函数被大量复制。
    inst:PushEvent("dance")
end

local function ShouldDanceParty(inst)
-- ShouldDanceParty：看队长是否在跳舞。
-- ★ 用 sg:HasStateTag("dancing") —— 靠标签而非状态名，解耦状态图内部结构。
    local leader = GetLeader(inst)
    return leader ~= nil and leader.sg:HasStateTag("dancing")
end

local function ShouldAvoidExplosive(target)
-- ★ ShouldAvoidExplosive：躲会爆的东西，但火里烧着的让它烧。
--   第 229 行 target.components.burnable:IsBurning() 时返回 true（该躲）。
--   ★ 语义：如果目标已经在烧（快炸了/正在炸），碎片也应该躲。
--   三条 or 的意思：不是爆炸物，或者没烧，或者在烧。
    return target.components.explosive == nil
        or target.components.burnable == nil
        or target.components.burnable:IsBurning()
end

local function ShouldRunAway(target, inst)
-- ★★★ ShouldRunAway —— 全文件最复杂的逃跑判定，三类敌人三种策略：
-- 【第 233-234 行】目标已死 → 不跑（没必要）
-- 【第 235-240 行】暗影生物 / 噩梦生物：
--   用 target:HostileToPlayerTest(leader) 判断「它对主人有敌意吗」
--   ★ 即碎片跟着主人一起怕 —— 敌人对主人有敌意才跑，无敌意（如自己的影子）就不跑。
--   没有该方法时返回 false（保守不跑）。
-- 【第 241-244 行】追踪者（stalker）：
--   两种情况才跑：在中庭里，或者它正在和某人战斗
--   ★ 语义：追踪者很危险，除非它正忙着打别人。
-- 【第 245 行】其他一切 → 跑。
-- ★★ 这是「按敌人类型分派逃跑策略」的完整范例，移植价值很高。
	if target.components.health ~= nil and target.components.health:IsDead() then
		return false
	elseif target:HasAnyTag("shadowcreature", "nightmarecreature") then
		if target.HostileToPlayerTest ~= nil then
			local leader = GetLeader(inst)
			return leader ~= nil and target:HostileToPlayerTest(leader)
		end
		return false
	elseif target:HasTag("stalker") then
		return target.atriumstalker
			or (target.canfight and target.components.combat ~= nil and target.components.combat:HasTarget())
	end
	return true
end

local function ShouldKite(target, inst)
-- ★ ShouldKite：只有「它是我的当前目标」且「它还活着」才风筝。
--   第 249 行 combat:TargetIs(target) —— ★ 比「target ~= nil」更严格：
--     要求 combat 组件的目标确实指向这个实体（别人抢走就不风筝了）。
--   ★ 这正是 components/combat.lua 第 519 行 GiveUp 的配套：
--     目标被抢走时战斗组件会清空，这里自动返回 false。
    return inst.components.combat:TargetIs(target)
        and target.components.health ~= nil
        and not target.components.health:IsDead()
end

local function ShouldWatchMinigame(inst)
-- ShouldWatchMinigame 与 WatchingMinigame（第 264 行）成对。
-- ★ 第 257 行的额外条件：「我当前没在打架，或我的目标也是参赛者」。
--   即：与外人打架时不去观战，只有安全时才去看热闹。
-- ★ 这个「优先级让位」的设计在本项目很常见，值得学。
    local leader = GetLeader(inst)
	if leader ~= nil and leader.components.minigame_participator ~= nil then
		if inst.components.combat.target == nil or inst.components.combat.target.components.minigame_participator ~= nil then
			return true
		end
	end
	return false
end

local function WatchingMinigame(inst)
    local leader = GetLeader(inst)
	return (leader ~= nil and leader.components.minigame_participator ~= nil) and leader.components.minigame_participator:GetMinigame() or nil
end

local function WatchingMinigame_MinDist(inst)
-- ★ 观看距离三段从 minigame 组件读，且每处都带 or 0 兜底（第 271/275/279 行）。
--   ⚠️ 但找不到小游戏时返回 0 而不是 nil —— 与 mermbrain 第 271 行一致。
--   Follow 拿到距离 0 会怎么处理？未核实 behaviours/follow.lua 的实现，
--   不下结论，仅标注此处与 mermbrain 的一致写法。
	local minigame = WatchingMinigame(inst)
	return minigame ~= nil and minigame.components.minigame.watchdist_min or 0
end
local function WatchingMinigame_TargetDist(inst)
	local minigame = WatchingMinigame(inst)
	return minigame ~= nil and minigame.components.minigame.watchdist_target or 0
end
local function WatchingMinigame_MaxDist(inst)
	local minigame = WatchingMinigame(inst)
	return minigame ~= nil and minigame.components.minigame.watchdist_max or 0
end

local function CreateWanderer(self, maxdist)
-- ★★ CreateWanderer：制造一个「小范围、不跑」的游荡节点。
--   第 286 行连续四个 nil —— ★ 说明 Wander 有至少 9 个位置参数，本文件只传前三个。
--   ⚠️ 大量位置参数 + 连续 nil 是可读性最差的调用形式。
--   第 287-290 行的注释 "Small wander radius with a dapper stroll"（小范围、优雅的漫步）
--   说明 should_run = false 是刻意的：暗影碎片要显得优雅而非狼狈。
--   ★ 数值本身不影响功能，只影响观感 —— 但作者专门为它写了注释。
    return Wander(self.inst,
		function() return GetSpawn(self.inst) end,
        maxdist,
        nil, nil, nil, nil,
        { -- Small wander radius with a dapper stroll.
            should_run = false,
            wander_dist = 4,
        }
    )
end

local function CreateIdleOblivion(self, delay, range)
-- ★★★ CreateIdleOblivion —— 「打卡自毁」机制，本文件最独特的设计。
--
-- 【机制】LoopNode{ WaitNode(delay), ActionNode(...) }
--   每 delay 秒检查一次：主人离出生点是否已超过 range；
--   超过就 PushEvent("seekoblivion") —— 状态图收到后让碎片消失。
--
-- 【★ 为什么需要这个】
--   暗影碎片是「召唤物」，主人在附近时有用，走远了就是白占性能。
--   ★ 与 brain.lua 的「实体休眠」机制不同：这不是让实体休息，是让它消失。
--   （休眠是 brain.lua 的事；这里是「用完就回收」，属于资源回收策略。）
--
-- 【第 295 行 range = range * range】
--   ★ 提前平方化，后面第 302 行才能用 GetDistanceSqToPoint 直接比。
--   第 301 行源码自己写了注释 "--NOTE: range is squared already" ——
--   ★ 作者意识到这个平方化容易忘，专门加注释说明。这是好习惯。
-- ⚠️ 但 API 设计有风险：参数名叫 range（听起来是距离）却要调用方自己平方。
--   若调用方忘了平方，比较会永远成立/永远不成立。
--   已核对第 436、455 行两处调用都传的是未平方的 TUNING 值，正确。
	range = range * range
	return LoopNode{
		WaitNode(delay),
		ActionNode(function()
			local leader = GetLeader(self.inst)
			local spawnpt = GetSpawn(self.inst)
			--NOTE: range is squared already
			if leader ~= nil and spawnpt ~= nil and leader:GetDistanceSqToPoint(spawnpt) >= range then
				self.inst:PushEvent("seekoblivion")
			end
		end),
	}
end

local COMBAT_TIMEOUT = 6
-- ★★ IsLeaderInCombat —— 「6 秒内打过架就算在战斗」。
--
-- 【★ 三级判定，从确定到推测】
--  第 310-315 行：主人没有 combat 组件 → 明确不战斗（注释："无法以常规方式战斗"）
--  第 317-322 行：★ laststartattacktime / lastdoattacktime 在 6 秒内 → 在打
--    ★ 取两个时间的 max，因为「开始攻击」和「实际挥出」是不同时间点，
--      取晚的那个 → 更保守（更容易判定为「在战斗」）。
--  第 324-331 行：GetLastAttackedTime 在 6 秒内 → 挨过打 → 在战斗
--    ★ 但第 326-329 行要排除「打了我的东西没有 combat 组件」→ 认为是环境伤害，不算。
--    ★ 注释："Done by something that is unable to attack, presume environmental"
--      ——【推测环境伤害】。这个「无攻击能力者造成的伤害视为环境」的假设很聪明。
--  第 333-334 行：都不满足 → 无威胁
--
-- 【★ 为什么要这个函数】第 370-376 行 ShouldDeliver：
--   主人正在打架 → 碎片不送货（送去会被误伤/没意义）。
-- ★ 6 秒的窗口是为了避免「主人一停手碎片就立刻出发」的抖动。
local function IsLeaderInCombat(leader)
    local leader_combat = leader.components.combat
    if leader_combat == nil then
        -- Leader can not attack nor be attacked by standard means.
        return false
    end

    local timeout_time = GetTime() - COMBAT_TIMEOUT
-- ★★ attack_time 取 max(laststartattacktime, lastdoattacktime) —— 保守判定。
--   若只用 laststartattacktime（准备攻击），会出现「举剑未落」就被判为战斗中；
--   若只用 lastdoattacktime，可能漏判刚蓄力的一次。取 max 更安全。
    local attack_time = math.max(leader_combat.laststartattacktime or 0, leader_combat.lastdoattacktime or 0)
    if attack_time > timeout_time then
        -- Recently attacked something.
        return true
    end

    if leader_combat:GetLastAttackedTime() > timeout_time then
        -- Recent damage.
        if leader_combat.lastattacker ~= nil and leader_combat.lastattacker.components.combat == nil then
            -- Done by something that is unable to attack, presume environmental.
            return false
        end
        return true
    end

    -- No threats known at this time.
    return false
end

function ShadowWaxwellBrain:OnStart()
-- ★★★ OnStart 的前 30 行全是「公共节点」，三种碎片共用。
--   注释原文："Common AI for most of the shadow minions"。
--   ★ 设计：先建公共子树，再按 prefab 拼装。避免重复代码。
    -- Common AI for most of the shadow minions.
	local watch_game = WhileNode( function() return ShouldWatchMinigame(self.inst) end, "Watching Game",
-- watch_game：观战。与 pigbrain 第 297 行的观战节点结构几乎相同。
        PriorityNode({
            Follow(self.inst, WatchingMinigame, WatchingMinigame_MinDist, WatchingMinigame_TargetDist, WatchingMinigame_MaxDist),
            RunAway(self.inst, "minigame_participator", 5, 7),
            FaceEntity(self.inst, WatchingMinigame, WatchingMinigame),
        }, 0.25))
    
    local dance_party = WhileNode(function() return ShouldDanceParty(self.inst) end, "Dance Party",
-- dance_party：跳舞。优先级最高（注释见第 179 行 pigbrain 同款）。
            PriorityNode({
                Leash(self.inst, GetLeaderPos, KEEP_DANCING_DIST, KEEP_DANCING_DIST),
                ActionNode(function() DanceParty(self.inst) end),
        }, 0.25))

    local avoid_explosions = RunAway(self.inst, { fn = ShouldAvoidExplosive, tags = { "explosive" }, notags = { "INLIMBO" } }, AVOID_EXPLOSIVE_DIST, AVOID_EXPLOSIVE_DIST)
-- ★ avoid_explosions 与 avoid_danger 是两个不同节点，用第 353 行的标签参数区分。
--   躲爆炸物：{ fn = ShouldAvoidExplosive, tags = {"explosive"}, notags = {"INLIMBO"} }
--   躲危险：  { fn = ShouldRunAway, oneoftags = {"monster","hostile"}, notags = {...} }
-- ★ 参数表支持的键：fn / tags(AND) / oneoftags(OR) / notags / getfn。
--   ★ 这五种目标指定方式覆盖了全部场景，本文件与 pigbrain 合起来是完整参考。
    local avoid_danger = RunAway(self.inst, { fn = ShouldRunAway, oneoftags = { "monster", "hostile" }, notags = { "player", "INLIMBO", "companion", "spiderden" } }, RUN_AWAY_DIST, STOP_RUN_AWAY_DIST)
-- ★ notags 里的 "companion" 排除友方，"spiderden" 排除蜘蛛巢穴方向（安全区）。

    local face_player = WhileNode(function() return GetLeader(self.inst) ~= nil end, "Face Player",
-- face_player：★ WhileNode 条件只用「有没有主人」，不看敌友。
--   即：只要跟着主人，就一直看着主人附近最近的玩家。
--   ⚠️ 与第 358 行 face_leader（无条件）重复：两者都在 rooth里，
--     face_player 优先。face_leader 只在 face_player 不适用时生效。
--   已核对第 358 行 face_leader 不带 WhileNode 包裹，故作为兜底存在。
        FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn))

	local face_leader = FaceEntity(self.inst, GetFaceLeaderFn, KeepFaceLeaderFn)

    -- Select which shadow Waxwell brain to focus on based off of prefab.
    local root = nil
-- ★ root 初始为 nil，按 prefab 重新赋值 —— ★ 说明「不是所有 prefab 都有对应分支」。
--   若 prefab 三个分支都不匹配（第 440 行的 else 兜住了），不会为 nil。
--   ⚠️ 但若 prefab 恰好等于 nil 且不匹配任何条件，仍走 else 兜底，安全。
    if self.inst.prefab == "shadowworker" then
-- ★★ 工匠分支。三点设计值得学：
--  第 363-368 行：软锁表挂在主人身上（见第 43 行的详解）
--  第 369 行：★ ShouldPickup 只在「不处于相位移动」时成立
--    phasing 是暗影碎片瞬移时的状态，期间不能拾取（否则传送到一半捡东西）。
--  第 370-376 行：★ ShouldDeliver = 不 phasing 且 ★ 主人不在战斗
--    「主人打架时不送货」是这一分支的核心取舍：
--    与 IsLeaderInCombat（第 310 行）联动。
        local leader = GetLeader(self.inst)
        local ignorethese = nil
        if leader ~= nil then
            ignorethese = leader._brain_pickup_ignorethese or {}
            leader._brain_pickup_ignorethese = ignorethese
        end
		local function ShouldPickup() return not self.inst.sg:HasStateTag("phasing") end
-- 相位状态是暗影碎片的移动方式（瞬间消失/出现）。
-- ★ 所有动作都要排除 phasing，否则会出现「传送到一半开始干活」的错位。
--   本文件第 371、398、478、480、482 行都做了这个排除。
		local function ShouldDeliver()
			if self.inst.sg:HasStateTag("phasing") then
				return false
			end
			local leader = GetLeader(self.inst)
			return leader ~= nil and not IsLeaderInCombat(leader)
		end
        local pickupparams = {
-- pickupparams：拾取参数表，直接传给 braincommon 的通用节点（第 429 行）。
-- ★ 这些参数名与 braincommon 第 566-578 行逐字对应，是标准的「参数化调用」。
-- ★ wholestacks = true：只凑整堆（与 braincommon 第 475 行的实现对应）。
-- ★ positionoverride = GetSpawn：★ 注意这里传的是【函数】而非调用结果，
--   braincommon 第 572 行会识别出函数型并每帧求值（第 581、600 行）。
			cond = ShouldPickup,
            range = TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS,
            range_local = TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS_LOCAL,
			give_cond = ShouldDeliver,
			give_range = TUNING.SHADOWWAXWELL_WORKER_WORK_RADIUS,
            furthestfirst = false,
			positionoverride = GetSpawn, --pass as function
            ignorethese = ignorethese,
            wholestacks = true,
            allowpickables = true,
        }
        root = PriorityNode({ -- This worker is set to do work and then vanish.
-- ★★ 工匠的 root：优先级顺序解读
--  1) dance_party（第 391 行）—— 跳舞，最高
--  2) watch_game（第 392 行）—— 观战
--  3) avoid_explosions（第 394 行）—— 躲爆炸
--  4) avoid_danger（第 395 行）—— 躲危险
--  ★ 注释说明 1-4 是 "Fun stuff" 与 "Keep watch out for danger"，即保命优先。
--  5) 第 396-438 行：状态守卫（不 phasing/不 recoil）里的工作子树
--  ★ 注意守卫条件是 or 的否定：不是 phasing 也不是 recoil 才工作。
--    recoil（被击退）期间不能干活，否则会被打断。
-- ★ 守卫包住的是一整个 PriorityNode —— 与 pigelitebrain 第 196 行的
--   「空 ActionNode 占位法」不同，这里是「包裹子树」，功能更完整。
            -- Fun stuff.
            dance_party,
            watch_game,
            -- Keep watch out for danger.
            avoid_explosions,
            avoid_danger,
			WhileNode(
-- ★ 状态守卫：排除 phasing（第 398 行）与 recoil（第 399 行）。
-- ★ 注释标注为 "<busy state guard>" —— 与 knightbrain 第 329 行、
--   beargerbrain 第 259 行、pigelitebrain 第 196 行同一命名惯例。
--   ★ 这是 DST 全项目的统一命名法，grep 这个字符串能找到所有守卫点。
				function()
					return not (self.inst.sg:HasStateTag("phasing") or
								self.inst.sg:HasStateTag("recoil"))
				end,
				"<busy state guard>",
				PriorityNode({
					-- Do the work needed to be done.
					WhileNode(
-- ★★★ "Keep Working" 节点 —— 一个罕见的技术活。
-- 【第 405-408 行的条件函数有副作用】
--   每帧求值时先把 self.keepworking 置 false，再无条件 return true。
--   ★ 即「永远进入这个节点」，但顺带把上一轮的遗留状态清干净。
--   ★ 用 WhileNode 的条件函数做「状态重置」，是个巧招。
--
-- 【第 410-421 行的动作函数】
--   找到工作 → 检查状态图是否已在做「同类预动作」
--   第 415 行 ★★ self.inst.sg:HasStateTag("pre"..act.action.id)
--     源码注释（@V2C）解释：「检查动作是否匹配 prechop/premine/predig，
--     因为状态图会直接拒绝重复的同类动作」。
--   ★★ 即：若状态图已经在做"准备砍"的预动作，就不要重复提交动作，
--     而是设 keepworking = true 让 DoAction 保持挂起状态。
--   第 418 行：否则正常返回 act 执行。
--
-- 【★ 这个机制解决的是什么问题】
--   源码第 422-424 行注释自陈："This is very gnarly"（这段很麻烦）：
--   当 DoAction 失败（被状态图拒绝）但状态图正在重复同类工作动作时，
--   需要让 "Keep Working" 节点继续挂着而不是退出。
--   ★ 这是「大脑与状态图动作协议不匹配」时的补偿代码。
--   ⚠️ 属于典型技术债，但注释已诚实说明，移植时需理解其必要性。
						function()
							self.keepworking = false
							return true
						end,
						"Keep Working",
						DoAction(self.inst, function()
							local act = FindAnyEntityToWorkActionsOn(self.inst, pickupparams.ignorethese)
							if act then
								--@V2C: check if our action matches "prechop", "premine", "predig" etc.
								--      because the stategraph would just reject the same action.
								if self.inst.sg:HasStateTag("pre"..string.lower(act.action.id)) then
									self.keepworking = true
								else
									return act
								end
							end
						end)),
					--@V2C: This is very gnarly, but this is so we can stay as "Keep Working" even when
					--      DoAction failed above, when we're still waiting on the stategraph to repeat
					--      work actions.
					FailIfSuccessDecorator(ConditionWaitNode(
-- ★ 第 425-426 行的 FailIfSuccessDecorator(ConditionWaitNode(...))：
--   条件 not self.keepworking 为真时成功（结束整个节点），
--   为假则挂起等待 —— ★ 即「还有重复动作要等，就别退出」。
--   与第 404 行的 keepworking 配合闭环。
-- ⚠️ ConditionWaitNode 里只做判断不产生活动，靠的是「等待」语义。
--   若状态图一直重复工作，这个节点会一直挂着 —— 这是期望行为。
						function() return not self.keepworking end, "Repeating action")),
					-- This Leash is to stop chasing after leader with loot if they keep moving too far away.
					Leash(self.inst, GetSpawn, pickupparams.range + 4, math.min(6, pickupparams.range)),
-- ★ leash 距离 pickupparams.range + 4 —— 「带着战利品追主人」的容忍度。
--   第 431 行注释："This Leash is to stop chasing after leader with loot if they keep moving too far away"。
-- ★ 与第 431 行的低优先级 leash 形成对比：
--   第 428 行范围更大（+4）、优先级更高（第 429 行之前）；
--   第 431 行范围更小（min(8,range)）、优先级更低。
--   ★ 即：带着东西时走远一点没关系，但空闲时别跑太远。
					BrainCommon.NodeAssistLeaderPickUps(self, pickupparams),
-- BrainCommon.NodeAssistLeaderPickUps：调用共享的「捡东西送给主人」节点。
-- ★ 一行调用就获得完整的「软锁 + 捡 + 送 + 送不了就丢」行为。
--   这是 braincommon 抽象价值的最直接体现 —— 对比第 43-77 行的软锁代码，
--   这里的复杂逻辑全在 braincommon 里，本文件只需传参数。
					-- Leashing is low priority.
					Leash(self.inst, GetSpawn, math.min(8, pickupparams.range), math.min(4, pickupparams.range)),
					-- Wander around and stare.
					face_leader,
					ParallelNode{
						CreateWanderer(self, math.min(6, pickupparams.range)),
-- ★ ParallelNode：游荡与打卡同时跑。
--   第 436 行的 delay 用 TUNING 里的碎片自毁等待时间。
--   ★ 游荡与「准备消失」并行：一边正常晃悠，一边倒计时。
						CreateIdleOblivion(self, TUNING.SHADOWWAXWELL_MINION_IDLE_DESPAWN_TIME, pickupparams.range),
					},
				}, 0.25)),
        }, 0.25)
    elseif self.inst.prefab == "shadowprotector" then
-- ★★ 守卫分支 —— 与工匠分支对比可以看清「角色差异 = 优先级表差异」：
--   【工匠有、守卫没有】
--     第 429 行 NodeAssistLeaderPickUps（捡东西送人）
--     第 428 行 leash + range + 4（带战利品追人）
--     第 410-426 行 Keep Working（干活）
--     avoid_danger（第 476 行在 else 分支里，工匠有）
--   【守卫有、工匠没有】
--     第 448 行 ChaseAndAttack（★★ 主动攻击！）
--   ★ 守卫的唯一本职就是打。第 448 行位置很靠前（第 4 位），
--     高于 leash 与游荡 —— 意味着「优先战斗，其次站岗」。
--   ★ 代码注释也印证：工匠那句写 "This worker is set to do work and then vanish"，
--     守卫那句写 "This protector is set to defend an area and then vanish"，
--     ★ 同一个骨架，只换中间那一段 —— 极好的对照阅读材料。
        root = PriorityNode({ -- This protector is set to defend an area and then vanish.
            -- Fun stuff.
            dance_party,
            watch_game,
            -- Keep watch out for immediate danger.
            avoid_explosions,
            -- Attack.
            ChaseAndAttack(self.inst),
-- ChaseAndAttack(self.inst) —— 不传任何参数，全用默认值。
-- ★ 与工匠分支对比：守卫的战斗参数完全写死在 behaviours/ 里。
--   意味着守卫的攻击距离/时间不可调。
--   ⚠️ 但守卫分支没引入 avoid_danger —— 它只躲爆炸（第 446 行），
--     不躲普通怪物。对「守卫」这个定位是合理的（它就该站着打）。
            -- Leashing is low priority.
            Leash(self.inst, GetSpawn, math.min(8, TUNING.SHADOWWAXWELL_PROTECTOR_DEFEND_RADIUS), math.min(4, TUNING.SHADOWWAXWELL_PROTECTOR_DEFEND_RADIUS)),
-- ★ 守卫的 leash 用 min(8, DEFEND_RADIUS)：半径不够 8 就用实际半径。
--   ★ 这是「上限截断」手法：min(8, X) 保证 leash 不会超过 8。
--   ★ 与第 454 行的 min(6, ...) 同款。本文件大量使用 min 上限，
--     作用是让小半径的变体不会被大常量撑爆。
            -- Wander around and stare.
			face_leader,
			ParallelNode{
				CreateWanderer(self, math.min(6, TUNING.SHADOWWAXWELL_PROTECTOR_DEFEND_RADIUS)),
				CreateIdleOblivion(self, TUNING.SHADOWWAXWELL_MINION_IDLE_DESPAWN_TIME, TUNING.SHADOWWAXWELL_PROTECTOR_DEFEND_RADIUS),
			},
        }, 0.25)
    else -- Fallback to DEPRECATED thinking.
-- ★★ 源码自标 DEPRECATED 的兜底分支。
--   注释："Fallback to DEPRECATED thinking."
--   ★ 覆盖 shadowduelist / shadowlumber / shadowminer / shadowdigger 四种。
--   结构上是「一个公共骨架 + 若干个 prefab 专属的 IfNode」，
--   而不是像前两个分支那样整棵换掉。
--   ★ 所以严格来说本文件是「两种组织方式并存」：
--     工匠/守卫 = 整棵换；duelist/工种 = 同树内分派。
        root = PriorityNode({
            --#1 priority is dancing beside your leader. Obviously.
            dance_party,
            watch_game,
    
            WhileNode(function() return IsNearLeader(self.inst, KEEP_WORKING_DIST) end, "Leader In Range",
-- ★ 条件「主人还在附近」才进入工作区（第 26 行 KEEP_WORKING_DIST=14）。
--   即：主人走远了就只跟随（第 486 行），不再干活。
--   ★ 守卫没有这一层 —— 守卫守的是「地点」不是「主人」。
                PriorityNode({
                    --All shadows will avoid explosives
                    avoid_explosions,
                    --Duelists will try to fight before fleeing
                    IfNode(function() return self.inst.prefab == "shadowduelist" end, "Is Duelist",
-- ★ 决斗者专属：先看能不能风筝，不能则直接打。
--   第 471 行条件：★ 冷却超过 0.5 秒 且 ShouldKite ——
--     即「攻击刚结束（冷却在走）才躲」。不是随时都躲。
--   ★ 这个 0.5 秒的门槛让风筝成为「攻击后的反应」而非「持续行为」，
--     符合风筝的操作节奏：打一下、退一下。
                        PriorityNode({
                            WhileNode(function() return self.inst.components.combat:GetCooldown() > .5 and ShouldKite(self.inst.components.combat.target, self.inst) end, "Dodge",
                                RunAway(self.inst, { fn = ShouldKite, tags = { "_combat", "_health" }, notags = { "INLIMBO" } }, KITING_DIST, STOP_KITING_DIST)),
-- 风筝的 RunAway 用 { fn = ShouldKite, tags = {"_combat","_health"}, notags = {"INLIMBO"} }。
-- ★ tags 里的 _combat/_health 是「组件标签」，DST 用它表达「有战斗和血量组件的东西」。
--   比写具体 prefab 列表健壮得多 —— 新增生物自动兼容。
-- ★ 这是「按组件而非按名字」筛敌的范例，移植价值高。
                            ChaseAndAttack(self.inst),
                    }, .25)),
                    --All shadows will flee from danger at this point
                    avoid_danger,
                    --Workers will try to work if not fleeing
					WhileNode(function() return self.inst.prefab == "shadowlumber" and not self.inst.sg:HasStateTag("phasing") end, "Keep Chopping",
-- ★ 三个工种的 IfNode，全部形如：prefab == "X" 且 不 phasing。
--   三者结构完全一致，只是动作不同（CHOP/MINE/DIG）。
--   ★ 正是这种重复促使 Klei 后来写了统一版（第 169 行）。
--   ⚠️ 印证了「重复三次就该抽象」这条工程判断。
                        DoAction(self.inst, function() return FindEntityToWorkAction(self.inst, ACTIONS.CHOP) end)),
					WhileNode(function() return self.inst.prefab == "shadowminer" and not self.inst.sg:HasStateTag("phasing") end, "Keep Mining",
                        DoAction(self.inst, function() return FindEntityToWorkAction(self.inst, ACTIONS.MINE) end)),
					WhileNode(function() return self.inst.prefab == "shadowdigger" and not self.inst.sg:HasStateTag("phasing") end, "Keep Digging",
                        DoAction(self.inst, function() return FindEntityToWorkAction(self.inst, ACTIONS.DIG, DIG_TAGS) end)),
            }, 0.25)),
    
            Follow(self.inst, GetLeader, MIN_FOLLOW_DIST, TARGET_FOLLOW_DIST, MAX_FOLLOW_DIST),
-- 跟随主人。MIN=0（第 19 行）—— 碎片会贴到主人身上。
-- ★ 优先级在 root 最后（工作区之后）：工作时不跟随，跟不上才跟随。
    
            face_player,
        }, 0.25)
    end

    self.bt = BT(self.inst, root)
-- ★★ 三个分支的共同收尾。三处都有这一行。
--   self.bt = BT(self.inst, root)
-- ★ 与 pigbrain（第 420 行）、knightbrain（第 388 行）完全一致。
--   至此本项目已完成 4 个大脑的验证：「DST 大脑 = 一棵 PriorityNode」成立。
end

function ShadowWaxwellBrain:OnInitializationComplete()
-- ★★ OnInitializationComplete —— 大脑初始化完成后才执行。
--   第 496-498 行：★ 若实体有 SaveSpawnPoint 方法，
--     就调 SaveSpawnPoint(true)，注释明写 "true: dont_overwrite"。
--   ★ 第 4 参 dont_overwrite = true 表示「已有记录就别覆盖」，
--     防止存档读档后把原始出生点改掉。
--   ★★ 这个时机很关键：不是 OnStart 而是 OnInitializationComplete，
--     因为出生点要等实体完全初始化（含读档）后才最终确定。
--   ★ beargerbrain 第 308-310 行用的是另一套（RememberLocation("spawnpoint")），
--     两者目标相同但机制不同，值得对比。
	if self.inst.SaveSpawnPoint ~= nil then
		self.inst:SaveSpawnPoint(true) --true: dont_overwrite
	end
end

return ShadowWaxwellBrain