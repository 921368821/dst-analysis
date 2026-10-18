--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/pigelitebrain.lua
-- 模块：AI 大脑 / 精英猪（猪王争霸赛参赛者）
-- 职责：装配精英猪 AI。★★★ 全 DST 唯一实现【多单位目标分配】的大脑：
--       用 inst:IsSquadAlreadyTargeting(...) 让多只精英猪互不争抢同一道具。
--       另有一整套「And」后缀复合节点（PanicAndAvoid / ChaseAndAttackAndAvoid /
--       LeashAndAvoid），实现「做该做的事，同时保持与猪王的安全距离」，
--       以及 GetSeekObj 的目标锁定三段式、ShouldPanic 的单向锁存迟滞、
--       ShouldMatchOverPose 的群体同步等待等值得照抄的抗抖动技巧。
-- 关键符号：PigEliteBrain, GetSeekObj, ShouldPanic, ShouldMatchOverPose,
--           IsSquadAlreadyTargeting（定义在 prefabs/pigelite.lua）, FindObj,
--           IsValidObj, ShouldPickProp, ShouldDiveItem, AVOID_KING_DIST
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（共享底座）,
--           behaviours/{chaseandattackandavoid,leashandavoid,panicandavoid,
--           standstill,wander}.lua（★ 本文件的复合节点）,
--           prefabs/pigelite.lua（IsSquadAlreadyTargeting 的定义方）,
--           prefabs/pigking.lua（_minigame_elites 字段维护方）,
--           components/{inventory,combat,entitytracker,knownlocations}.lua
--============================================================
require("behaviours/chaseandattackandavoid")
--[ [
-- pigelitebrain.lua —— 精英猪（猪王争霸赛参赛者）大脑
--
-- 【★★★ 全DST 唯一的「多单位目标分配」大脑】
--   场上有多只精英猪同时找道具/金币，若都盯着同一个目标就会挤成一团。
--   ★ 本文件用 inst:IsSquadAlreadyTargeting(...) 实现去重：
--     每个精英猪在选目标时会问「我的队友是不是已经盯上它了」，
--     是则跳过，换下一个候选。
--   ★ 这是「分布式资源分配」的实用范例，无需队长仲裁。
--
-- 【★ 另一亮点：整套「And」后缀节点】
--   本文件不用标准的 Leash / ChaseAndAttack / Panic，而是：
--     PanicAndAvoid（第 200 行）           —— 恐慌时顺便躲开猪王
--     ChaseAndAttackAndAvoid（第 210 行） —— 追击时顺便躲开猪王
--     LeashAndAvoid（第 227、241、253、257 行）—— 牵引时顺便躲开猪王
--   ★★ 这些节点在 behaviours/ 里，是「动作 + 避让」的复合体。
--     语义：做该做的事，同时不要踩进猪王的判定圈。
--   ★ 这是 DST 处理「AI 做事时的空间约束」的解法，移植价值很高。
--   ★ 猪王不能被碰到（碰到会输），所以所有行为都要带避让。
--
-- 【⚠️ 容易踩的坑】
-- · 第 197 行 ActionNode 的函数体是个空函数，源码用长注释块（尖括号方括号形式）
--   写着「do nothing」。
--   ★ 它是【合法的】Lua 长注释，功能是「站着不动但不进入任何状态」。
--     ⚠️ 注意：本项目的注释文本里绝不能出现裸的长注释起止序列，
--     否则会提前闭合源码的注释块。已按规范改写为文字描述。
-- · 第 196 行 WhileNode 条件是 sg:HasStateTag("jumping")，其余文件是 not jumping。
--   ★ 本文件是唯一「跳跃中才执行」的 —— 因为跳跃=待机姿势（见第 197 行）。
--   ⚠️ 这与 knightbrain 第 328 行的守卫语义完全相反，对照阅读时容易混淆。
--] ]
require("behaviours/leashandavoid")
require("behaviours/panicandavoid")
require("behaviours/standstill")
require("behaviours/wander")
local BrainCommon = require("brains/braincommon")

local MAX_WANDER_DIST = 8
local MIN_PANIC_DIST_SQ = 2 * 2
-- ★★★ 恐慌距离用的是【平方】：2 与 5，即真实距离 2 触发、5 解除。
--   MIN_PANIC_DIST_SQ = 2*2, MAX_PANIC_DIST_SQ = 5*5
--   ★ 全程平方比较，避免开方。移植时保持一致。
local MAX_PANIC_DIST_SQ = 5 * 5
local RUN_AWAY_DIST = 5
local STOP_RUN_AWAY_DIST = 8
local SEE_OBJ_DIST = 20
local SEE_OBJ_DIST_SQ = SEE_OBJ_DIST * SEE_OBJ_DIST
local KEEP_OBJ_DIST_SQ = 6 * 6
local PICK_PROP_DIST = 1
local DIVE_ITEM_DIST = 4.5
local KEEP_TARGET_THRESHOLD = 4
local AVOID_KING_DIST = 3 --pigking radius + pigelite radius + some breathing room
-- ★★ AVOID_KING_DIST = 3 —— 避让猪王的距离。
--   ★ 注释明确写了来源："pigking radius + pigelite radius + some breathing room"。
--   ★★ 这是「按物理尺寸推算安全距离」的做法，值 3 有明确来源而非拍脑袋。
--   ★ 全文件 8 处节点都用它，参数化的价值一目了然。

local FIND_PROP_TAGS =
-- ★★ FIND_PROP_TAGS / FIND_GOLD_TAGS 的差异：
--   PROP: MUST = { minigameitem, propweapon }（道具武器）
--   GOLD: MUST = { minigameitem }，NO_TAGS 多一个 propweapon
--   ★ 即「普通物品」与「道具武器」是互斥的两类目标。
--   ★ 用标签而非 prefab 名表达，可扩展（新增道具类型只需打标签）。
-- ★★ NO_TAGS 里 knockbackdelayinteraction 是本文件独有的：
--   「击退延迟交互」的道具不能抢 —— 可能是刚被击飞还没落地的。
{
    MUST_TAGS = { "minigameitem", "propweapon" },
    NO_TAGS = { "INLIMBO", "NOCLICK", "fire", "knockbackdelayinteraction" },
}
local FIND_GOLD_TAGS =
{
    MUST_TAGS = { "minigameitem" },
    NO_TAGS = { "INLIMBO", "NOCLICK", "fire", "knockbackdelayinteraction", "propweapon" },
}

local PigEliteBrain = Class(Brain, function(self, inst)
-- ★★ 构造函数里预置了 6 个字段，全是脑自己的状态：
--   pickprop —— 要捡的道具
--   seekprop —— 正在走向的道具
--   diveitem —— 要扑的金币
--   seekitem —— 正在走向的金币
--   matchovertime —— 比赛结束的时刻（第 172 行设置）
--   canpanic —— ★★ 恐慌的迟滞标志，见第 148 行
-- ★★ 与 mermbrain 第 392 行 inst.answerpotcall（放实体上）不同，
--   这些纯 AI 内部状态放【脑 self】上 —— 因为无需跨存档。
-- ★ 判断标准：需要存读档的放实体，只运行时用的放脑。
    Brain._ctor(self, inst)
    self.pickprop = nil
    self.seekprop = nil
    self.diveitem = nil
    self.seekitem = nil
    self.matchovertime = nil
    self.canpanic = true
end)

local function HasProp(inst)
-- HasProp：手上是否已有道具武器。已有就不需要再捡。
    local prop = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    return prop ~= nil and prop:HasTag("propweapon")
end

local function IsItemTarget(inst, target)
-- ★★ IsItemTarget / IsPropTarget（第 51 行）：★ 这两个函数的参数极易看错。
-- 【第 48 行】return inst.brain ~= nil and (inst.brain.seekitem == target or ...)
--   ★★ 注意是 inst.brain —— 它们接收的是【实体 inst】，
--     却反过来访问 inst.brain 去取脑上的字段。
-- ★ 为什么反着写？因为这些函数被当作 FindEntity 的回调或本地判定传入，
--   手上只有实体；而字段在脑上，必须绕一层。
-- ⚠️ 与其他函数的风格相反（本文件第 55 行 IsValidObj 也用 inst.brain）。
--   属有意为之，非错误，但确实容易看错。
-- ★ 它们的用途是「判断某目标是不是我自己已经盯着的」，
--   传给 squadcheckfn 做「队友目标排除」。
    return inst.brain ~= nil and (inst.brain.seekitem == target or inst.brain.diveitem == target)
end

local function IsPropTarget(inst, target)
    return inst.brain ~= nil and (inst.brain.seekprop == target or inst.brain.pickprop == target)
end

local function IsValidObj(inst, obj, squadcheckfn)
-- ★★ IsValidObj —— 「这个目标还能要吗」的五重校验。
--   1) 非nil2) IsValid  3) 不在 limbo / NOCLICK
--   4) 没在燃烧
--   5) ★★ inst:IsSquadAlreadyTargeting(obj, 距离平方, squadcheckfn)
-- ★★ 第 5 项是全文件的核心：排除队友已选的目标。
--   ★ 注意第 60 行传的是 inst:GetDistanceSqToInst(obj)（平方距离）。
--   IsSquadAlreadyTargeting 定义在 prefabs/pigelite.lua，不在本文件。
-- ★ 移植提示：这类函数定义在 prefab 而大脑调用，是 DST 的常见分层。
    return obj ~= nil
        and obj:IsValid()
        and not (obj:IsInLimbo() or obj:HasTag("NOCLICK"))
        and not (obj.components.burnable ~= nil and obj.components.burnable:IsBurning())
        and not inst:IsSquadAlreadyTargeting(obj, inst:GetDistanceSqToInst(obj), squadcheckfn)
end

local function FindObj(inst, dist, tags, squadcheckfn)
-- FindObj：找到【没被队友盯上】的目标。
-- ★★ 第 64 行把「排除队友」作为 FindEntity 的回调（不是 CANT_TAGS）：
--   因为 IsSquadAlreadyTargeting 需要距离参数，无法用静态标签表达。
--   ★★★ 这正是「复杂排除条件必须用回调而非标签」的标准例子。
--   对比第 21-30 行的静态 NO_TAGS —— 两者互补。
    return FindEntity(inst, dist, function(obj) return not inst:IsSquadAlreadyTargeting(obj, inst:GetDistanceSqToInst(obj), squadcheckfn) end, tags.MUST_TAGS, tags.NO_TAGS)
end

local function GetSeekObj(inst, old, tags, squadcheckfn)
-- ★★★ GetSeekObj —— 「要不要换目标」的三段决策，本文件最巧的函数。
-- 【三段式，按距离判断】
--  第 73-75 行：★ 很近（< KEEP_OBJ_DIST_SQ = 36，即 6 距离）→ 【不换】
--    注释："don't switch if it's close" —— 近目标不换，避免抖动。
--  第 76-79 行：★ 太远（>= SEE_OBJ_DIST_SQ = 400，即 20 距离）→ 【忘掉】
--  第 80-88 行：★ 介于两者之间 → 【看新目标是否明显更近】
--    第 83 行 olddist = min(olddist * .75, olddist - KEEP_TARGET_THRESHOLD)
--    ★★★ 核心公式：要求新目标满足「距离 × 0.75」或「比现在近 4 格」才换。
--    两个条件取【更容易满足的那个】（min 作为阈值）。
--    ★ 语义：只有新目标好得多才换，否则凑合用现在的。
--  第 84-87 行：算出的阈值 ≤ 0 时直接返回旧目标（注释说"shouldn't be possible"）。
--    ★ 又一处作者自标的不可能情况 —— 防御性兜底，保留即可。
-- 【第 93 行】最后统一兜底：FindObj(...) or old
--   ★ 即「找不到更好的就继续用旧的」—— 永不放弃目标。
--
-- ★★★ 这就是「目标锁定 + 粘性 + 换目标门槛」的完整实现，
--   移植价值极高：任何需要 AI 锁定目标的系统都能直接套这个三段式。
    local olddist = nil
    if old ~= nil then
        if IsValidObj(inst, old, squadcheckfn) then
            local x, y, z = old.Transform:GetWorldPosition()
            olddist = inst:GetDistanceSqToPoint(x, y, z)
            if olddist < KEEP_OBJ_DIST_SQ then
-- ★ 换目标的第一道门：够近就不换。KEEP_OBJ_DIST_SQ = 36（6 距离）。
                --V2C: don't switch if it's close
                return old
            elseif olddist >= SEE_OBJ_DIST_SQ then
-- ★ 第二道门：太远就彻底忘掉（old = nil，下一帧重新找）。
                --V2C: forget if it's too far away
                old = nil
                olddist = nil
            else
                --V2C: switch if it's much closer
                olddist = math.sqrt(olddist)
                olddist = math.min(olddist * .75, olddist - KEEP_TARGET_THRESHOLD)
-- ★★★ 换目标阈值公式：min(olddist * .75, olddist - 4)。
--   ★ 读法：「新目标要同时/或者满足 —— 比现在近 25%，或比现在近 4 格」。
--   ★★ 为什么用 min（取较松的那个）？让换目标变得容易一点，
--     否则玩家会看到 AI 死抱着一个半远的道具不放。
--   ★ 这是「粘性强度」的直接调参点。移植时先调这个值。
-- ⚠️ 第 82 行 olddist = math.sqrt(olddist) 把平方变回线性 ——
--   因为这个公式是线性语义（4 格是线性差值，不能平方）。正确。
                if olddist <= 0 then
                    --shouldn't be possible
                    return old
                end
            end
        else
            old = nil
        end
    end
    return FindObj(inst, olddist or SEE_OBJ_DIST, tags, squadcheckfn) or old
end

local function ShouldPickProp(self)
-- ★ ShouldPickProp 的三分支（按距离优先级）：
--  1) 已有道具 → 清理 pickprop，返回 false（不需要了）
--  2) pickprop 在够近范围（1 格）内 → 可以捡
--  3) seekprop 在够近范围内 → 【把 seekprop 升级成 pickprop】
--     ★★ 这是「走向 → 到达 → 开始捡」的两阶段状态机。
--  4) 都不可用 → 就近搜一个（1 格内）当 pickprop
-- ★ 第 4 行的搜索半径 PICK_PROP_DIST=1 极小 —— 只捡脚下的。
--   远的交给第 110 行 GetSeekPropPos 用 LeashAndAvoid 去走。
    if HasProp(self.inst) then
        self.pickprop = nil
        return false
    elseif IsValidObj(self.inst, self.pickprop, IsPropTarget) and self.inst:IsNear(self.pickprop, PICK_PROP_DIST) then
        return true
    elseif IsValidObj(self.inst, self.seekprop, IsPropTarget) and self.inst:IsNear(self.seekprop, PICK_PROP_DIST) then
        self.pickprop = self.seekprop
        return true
    end
    self.pickprop = FindObj(self.inst, PICK_PROP_DIST, FIND_PROP_TAGS, IsPropTarget)
    return self.pickprop ~= nil
end

local function GetSeekPropPos(self)
-- GetSeekPropPos：提供给 LeashAndAvoid 的目标点函数。
-- ★★ 与 ShouldPickProp（第 96 行）形成两阶段：
--   这个函数处理「走过去」（seekprop），那个处理「捡起来」（pickprop）。
-- ★ 第 111-114 行：已有道具时清空 seekprop 并返回 nil ——
--   ★★★ 【返回 nil 会让 Leash 失去目标，企鹅就停下】。
--   ★ 这是「用 nil 表达『没目标了，停下吧』」的标准手法。
--   对比 GetWanderFormationPos（knightbrain 第 208 行）也用 nil。
    if HasProp(self.inst) then
        self.seekprop = nil
        return
    end
    self.seekprop = GetSeekObj(self.inst, self.seekprop, FIND_PROP_TAGS, IsPropTarget)
    return self.seekprop ~= nil and self.seekprop:GetPosition() or nil
end

local function ShouldDiveItem(self)
-- ★★ ShouldDiveItem 的四分支，比 ShouldPickProp 多一个「放弃」：
--  1) diveitem 在 4.5 格内 → 扑
--  2) seekitem 在 4.5 格内 → 升级为 diveitem
--  3) ★ seekitem 在 4.5+4 = 8.5 格内 → 【放弃 diveitem，返回 false】
--     ★★ 这是「够近就放弃远处目标」的近端化逻辑：既然金币在脚边，
--       就不必扑远处那个了。
--  4) 都没有 → 就近搜（4.5 格）
-- ★ 第 126 行 DIVE_ITEM_DIST + KEEP_TARGET_THRESHOLD 的加法是刻意的：
--   放弃阈值比行动阈值大 4 格，形成「迟滞 + 主动放弃」。
    if IsValidObj(self.inst, self.diveitem, IsItemTarget) and self.inst:IsNear(self.diveitem, DIVE_ITEM_DIST) then
        return true
    elseif IsValidObj(self.inst, self.seekitem, IsItemTarget) then
        if self.inst:IsNear(self.seekitem, DIVE_ITEM_DIST) then
            self.diveitem = self.seekitem
            return true
        elseif self.inst:IsNear(self.seekitem, DIVE_ITEM_DIST + KEEP_TARGET_THRESHOLD) then
            self.diveitem = nil
            return false
        end
    end
    self.diveitem = FindObj(self.inst, DIVE_ITEM_DIST, FIND_GOLD_TAGS, IsItemTarget)
    return self.diveitem ~= nil
end

local function GetSeekItemPos(self)
    self.seekitem = GetSeekObj(self.inst, self.seekitem, FIND_GOLD_TAGS, IsItemTarget)
    return self.seekitem ~= nil and self.seekitem:GetPosition() or nil
end

local function GetHome(inst)
-- ★ GetHome：用 knownlocations 存的「家」而不是家实体。
--   ★ 与 pigbrain 第 141 行 GetHomePos 用 homeseeker 组件不同。
--   ★ 因为精英猪不认实体（它是比赛 NPC，没有 homeseeker）。
    return inst.components.knownlocations:GetLocation("home")
end

local function GetPigKing(inst)
-- GetPigKing：★ 用 entitytracker 按名字「king」查猪王。
--   ★ 全局唯一的名录查询，O(1)，比 FindEntity 空间搜索快得多。
--   ★ 与 knightbrain 第 113 行 GetEntity(name) 同一手法。
    return inst.components.entitytracker:GetEntity("king")
end

local function ShouldPanic(self)
-- ★★★ ShouldPanic —— 一个纯正的【迟滞（hysteresis）开关】。
-- 【两段状态机】
--  第 149-153 行：当前可以恐慌 时
--     离 home 近（< 5）→ 恐慌
--     离 home 远（>= 5）→ 【把 canpanic 置 false 并退出】
--     ★★ 即「已经跑远了就别再恐慌了」—— 一个单向锁存器。
--  第 154-157 行：当前不能恐慌 时
--     回到 home 很近（< 2）→ 【重新解锁 canpanic】并恐慌
--     ★ 「接近家才能再次恐慌」。
-- 【★ 为什么要这个】
--   避免「在家门口反复恐慌抖动」：跑远了→停止恐慌→回来→又恐慌→跑远……
--   用两个不同阈值（5 触发、2 解锁）形成非对称区间，彻底消除抖动。
-- ★★★ 这是全文件最值得移植的技巧：
--   「进入条件」与「退出条件」用不同阈值，且退出条件更宽松。
--   与本文件第 67 行的目标三段式异曲同工，都是「抗抖动」。
-- ★ 代价：canpanic 一旦为 false，除非回家否则永不恢复。属于有意设计。
    if self.canpanic then
        if self.inst:GetDistanceSqToPoint(GetHome(self.inst)) < MAX_PANIC_DIST_SQ then
            return true
        end
        self.canpanic = false
    elseif self.inst:GetDistanceSqToPoint(GetHome(self.inst)) < MIN_PANIC_DIST_SQ then
        self.canpanic = true
        return true
    end
    return false
end

local function IsMatchOver(inst)
-- ★ IsMatchOver：比赛结束了吗。
--   第 162 行 flagmatchover 是外部设置的强制结束标志。
--   第 166 行 ★ 猪王不存在 或 猪王已不在比赛中 → 结束。
--   ★ 兼容「猪王死了」「猪王提前结束比赛」两种情况。
    if inst.flagmatchover then
        return true
    end
    local king = GetPigKing(inst)
    return king == nil or not king:IsMinigameActive()
end

local function ShouldMatchOverPose(self)
-- ★★★ ShouldMatchOverPose —— 群体性的「统一摆姿势」。
-- 【三步】
--  第 170-174 行：比赛刚结束 → 【记下结束时刻】，但本轮不摆（返回 false）
--     ★ 至少延迟一轮，让行为切换更平滑。
--  第 175-177 行：结束不到 2 秒 → 继续等（返回 false）
--     ★★ 2 秒宽限期，让所有企鹅都「注意到」比赛结束了。
--  第 178-185 行：★★ 检查队友是否都已就位
--     遍历猪王的 _minigame_elites，若有队友既不 idle 也不 endpose → 再等。
--     ★★★ 这是【群体同步等待】：所有成员都准备好，才一起摆姿势。
--     与 knightbrain 第 195 行的编队协调同属「无通信同步」，
--     但这里靠「查询队友状态」而非确定性随机。
-- ★ 读取 king._minigame_elites —— ★ 私有字段，跨对象访问。
--   ⚠️ 隐式契约：依赖猪王 prefab 维护该字段。移植需注意。
-- ★★ 第 243 行也有 while 循环反复调本函数（见该行注释），
--   说明它被设计为可重复调用且有副作用推进状态机。
    if self.matchovertime == nil then
        if IsMatchOver(self.inst) then
            self.matchovertime = GetTime()
        end
        return false
    elseif self.matchovertime + 2 > GetTime() then
        return false
    end
    local king = GetPigKing(self.inst)
    if king ~= nil then
        for k, v in pairs(king._minigame_elites) do
            if k ~= self.inst and not (k.sg:HasStateTag("idle") or k.sg:HasStateTag("endpose")) then
                return false
            end
        end
    end
    return true
end

local function GetMatchOverPos(inst)
-- GetMatchOverPos：比赛结束后回「家」（其实是集合点）。
--   ★ 与第 253 行 LeashAndAvoid(..., 0, 0, true) 配对：距离传 0 意味着
--   「只要不在就过去」，第 253 行用这个函数当目标。
    return IsMatchOver(inst) and GetHome(inst) or nil
end

function PigEliteBrain:OnStart()
-- ★★ OnStart。★ 关键观察：root 用的是重评估间隔 0.1（本文件最激进）。
--   ★ 对比其他大脑：pigbrain 0.5 / knightbrain 0.25 / penguin 0.25。
--   ★★ 为什么精英猪要 0.1？因为它处于高强度竞技混战中，
--     反应慢就抢不到道具。★ 「AI 决策频率 = 竞技激烈程度」的量化体现。
    local root = PriorityNode(
    {
        WhileNode(function() return self.inst.sg:HasStateTag("jumping") end, "Standby",
-- ★★ 与其他文件相反的守卫：条件是 sg:HasStateTag("jumping")。
--   第 197 行 ActionNode 里源码写了个长注释块说「什么都不做」。
--   ★★★ 语义：跳跃（待机姿势）时进入这个节点，空转。
--   ★★ 与 knightbrain 第 328 行 not jumping 对比：那边是「跳跃时停工」，
--     这边是「跳跃时空转占位」。方向相反，务必别混。
--   ★ 为什么需要一个「什么都不做」的节点？
--     因为它是 root 的第一个子节点：当企鹅在跳跃待机时，
--     让 root 立刻「成功」而不去做任何别的事。
--   ★★★ 即「用一个空节点实现『本轮什么都不做』」，比 return nil 更明确。
            ActionNode(function() --[[do nothing]] end)),
        WhileNode(function() return self.inst.components.hauntable.panic end, "PanicHaunted",
-- PanicAndAvoid：恐慌 + 躲猪王。第 200 行定义于 behaviours/panicandavoid.lua。
--   ★ 三个相同的恐慌分支（第 198、201、204 行）都用这个复合节点。
--   ★ 对比 pigbrain 第 386-391 行用纯 Panic（无避让）——
--     因为猪可以碰到猪王而不输，精英猪不行。角色差异的准确表达。
            ChattyNode(self.inst, "PIG_TALK_PANICHAUNT",
                PanicAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST))),
        WhileNode(function() return self.inst.components.health.takingfiredamage end, "OnFire",
            ChattyNode(self.inst, "PIG_TALK_PANICFIRE",
                PanicAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST))),
        WhileNode(function() return BrainCommon.ShouldAvoidElectricFence(self.inst) end, "Shocked",
            ChattyNode(self.inst, "PIG_TALK_PANICELECTRICITY",
                PanicAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST))),
        ChattyNode(self.inst, "PIG_ELITE_SMACK",
-- ★★ 攻击节点的「副作用清理」（第 211-216 行）：
--   ★ 进入攻击前，把 pickprop / seekprop / diveitem / seekitem 全部清空。
--   ★★ 语义：「打架时不再惦记道具」。
--   ★ 用 ActionNode 与 ChaseAndAttackAndAvoid 组成 ParallelNode（第 209 行），
--     一个负责攻击、一个负责清状态，并行执行。
--   ★ 这是「并行节点做两件独立小事」的标准用法。
            WhileNode(function() return self.inst.components.combat.target == nil or not self.inst.components.combat:InCooldown() end, "AttackMomentarily",
-- 攻击条件：无目标 或 不在冷却。与 pigbrain 第 397 行同款。
                ParallelNode{
                    ChaseAndAttackAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST),
-- ChaseAndAttackAndAvoid：追击时保持与猪王的距离。
--   ★ 第 210 行传 GetPigKing 作为避让对象，AVOID_KING_DIST=3 为半径。
                    ActionNode(function()
                        self.pickprop = nil
                        self.seekprop = nil
                        self.diveitem = nil
                        self.seekitem = nil
                    end),
                })),
        --Dive for gold
-- ★★ 第 225 行 Dive 分支的动作只推事件（第 223 行），
--   而第 232 行 Gold 分支是 ParallelNode{Leash, ActionNode}。
--   ★ 为什么 Dive 不需要 Leash？因为 DIVE_ITEM_DIST 只有 4.5 格，
--     已经在附近了，直接扑即可。距离近就不必牵引。
--   ★ 合理的距离分层简化。
        WhileNode(function() return ShouldDiveItem(self) end, "Dive",
            ActionNode(function()
                self.pickprop = nil
                self.seekprop = nil
                self.inst:PushEvent("diveitem", { item = self.diveitem })
            end)),
        ChattyNode(self.inst, "PIG_ELITE_GOLD",
-- ★★ Gold 分支用 ParallelNode 让「走向金币」与「清理道具目标」并行。
--   ★ 第 228-231 行的 ActionNode 负责清 pickprop / seekprop，
--     语义：「去捡金币的同时不再惦记道具」。
--   ★ 与第 211-216 行（攻击时的清理）同构，只是清理的字段不同。
--   ★ 这是「切换目标时清理上一目标的状态」的统一手法。
            ParallelNode{
-- ★★ 第 233-238 行 PickProp 的 WhileNode 条件【有副作用】：
--   第 234-235 行：先清 diveitem / seekitem，再调 ShouldPickProp。
--   ★★ 语义：「想捡道具 ⇒ 放弃金币」。两种资源互斥，每次只惦记一种。
--   ★ 这是「用条件函数表达资源切换」——比在两个节点里各自清更简洁。
--   ★ 对照第 244-246 行 MatchOverPose 的同样手法（先清再判断）。
--   ★ 本文件共 3 处「先清后判」（第 212、234、244 行），模式统一，值得学。
--     模式统一，值得学。
                LeashAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST, function() return GetSeekItemPos(self) end, DIVE_ITEM_DIST, 0, true),
                ActionNode(function()
                    self.pickprop = nil
                    self.seekprop = nil
                end),
            }),
        --Pick up prop
        WhileNode(function()
                self.diveitem = nil
                self.seekitem = nil
                return ShouldPickProp(self)
            end,
            "PickProp",
            ActionNode(function() self.inst:PushEvent("pickprop", { prop = self.pickprop }) end)),
        LeashAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST, function() return GetSeekPropPos(self) end, PICK_PROP_DIST, 0, true),
-- ★ LeashAndAvoid 走向道具：距猪王 3 格，牵引半径 0/0（都要到 0 意味着「必须到位」）。
--   ★ 第 241 行末尾的 0, 0 与 true 三个参数：
--     搜新目标距离 0（不搜，靠 seekprop）
--     牵引距离 0（必须精确到位）
--     true（不可打断）
--   ★ 与第 227 行的 4.5, 0 对照：那边给了一点搜索余量。
        --
        WhileNode(function()
-- ★★★ MatchOverPose 的 ParallelNode（第 249-252 行）：
--   第 250 行 StandStill —— 站定不动
--   第 251 行 LoopNode{ ActionNode(推 matchover 事件) } —— 循环推事件
--   ★★ 为什么循环推？因为 PushEvent 是一次性的，
--     而 matchover 表演需要状态图持续维持在「结束姿势」。
--   ★ LoopNode 包一个 ActionNode = 「反复执行这个动作」，是常见惯用法。
--   ★ 「反复执行这个动作」的惯用法，移植时可直接复用。
                self.pickprop = nil
                self.seekprop = nil
                return ShouldMatchOverPose(self)
            end,
            "MatchOverPose",
            ParallelNode{
                StandStill(self.inst),
                LoopNode({ ActionNode(function() self.inst:PushEvent("matchover") end) }),
            }),
        LeashAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST, GetMatchOverPos, 0, 0, true),
-- ★ 比赛结束后回集合点。LeashAndAvoid(..., GetMatchOverPos, 0, 0, true)。
--   ★★ 目标函数 GetMatchOverPos 在比赛未结束时返回 nil（第 190 行）。
--     ★ 返回 nil 时 Leash 无目标 → 企鹅原地不动。
--     ★ 但这个节点在第 243 行之后（第 243 行条件成立时不会走到这），
--       所以 nil 情况实际不会发生。优先级隔离了它。
        --
        WhileNode(function() return not IsMatchOver(self.inst) and ShouldPanic(self) end, "Panic",
-- ★★ 恐慌节点排在「回家」之前（第 255 行 vs 257 行）。
--   语义：先保命再归位。与 pigbrain 第 386 行同款优先级逻辑。
--   ★ 条件 not IsMatchOver and ShouldPanic：
--     ★ 比赛结束后不再恐慌（该摆姿势了）。跨节点的语义互斥。
            PanicAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST)),
        LeashAndAvoid(self.inst, GetPigKing, AVOID_KING_DIST, GetHome, 0, 0, true),
-- 兜底回「家」。LeashAndAvoid(..., GetHome, 0, 0, true)。
--   ★ 第 258 行 Wander(self.inst, GetHome, MAX_WANDER_DIST=8) 作为最后兜底。
--   ★ 与其他文件一样，末尾必有永不失败的节点。
        Wander(self.inst, GetHome, MAX_WANDER_DIST),
    }, .1)

    self.bt = BT(self.inst, root)
end

function PigEliteBrain:OnInitializationComplete()
-- ★★ OnInitializationComplete：把出生点存为「家」。
--   第 265 行 RememberLocation("home", 位置, true)
--   ★★ 第 3 个参数 true 是 dont_overwrite（已核实 shadowwaxwell 第 497 行注释）。
--     语义：存档读档后不覆盖原始家位置。
--   ★ 与 beargerbrain 第 309 行 RememberLocation("spawnpoint", ...) 同款，
--     但用的 key 名不同（home vs spawnpoint）。
--   ★★ 这是本文件 GetHome（第 140 行）能工作的前提 ——
--     必须先在这里记住，大脑里才能读到。
    self.inst.components.knownlocations:RememberLocation("home", self.inst:GetPosition(), true)
end

return PigEliteBrain