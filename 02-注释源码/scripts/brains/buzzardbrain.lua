--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/buzzardbrain.lua
-- 模块：AI 大脑 / 秃鹫（争抢并占有尸体的空中单位）
-- 职责：装配秃鹫 AI。★★★ 本文件最大看点：覆写 DoUpdate 实现【逐帧失效的缓存】——
--       Brain:OnUpdate（顶层 brain.lua:228）每帧先调 DoUpdate 把威胁缓存标记待查，
--       再跑行为树，于是树内多次查询只做一次 FindEntity。
--       另含完整的「资源占有三件套」：模块级共享表 ignorethese 登记占有者、
--       SIZE_TO_NUM_OWNERS 按尸体尺寸分配名额、OnStop 释放防止表无限增长。
--       以及「设标志 / 执行分离」的三入口飞走机制、SuggestTarget 的群体协商、
--       「战斗距离 + 尸体半径」联动的拾取站位等模式。
--
-- ⚠️ 阅读警告：第 45-46 行的 FINDTHREAT_MUST_TAGS / FINDTHREAT_CANT_TAGS
--   变量名与实际传入 FindEntity 的位置【相反】（源码自带澄清注释）。
--   第 48 行的变异体版本命名却是正确的 —— 可反证前者是笔误。
-- 关键符号：BuzzardBrain, DoUpdate（逐帧缓存失效）, FindThreat（三态缓存）,
--           OwnCorpse / LoseCorpseOwnership（占有与释放）, ShouldIgnoreCorpse,
--           SIZE_TO_NUM_OWNERS（容量表）, DealWithThreat, GetCorpseRadius,
--           Buzzard_ShouldIgnoreCorpse, OnStop（★ 释放共享表）
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：顶层 brain.lua:228-236（Brain:OnUpdate —— DoUpdate 的调用点）,
--           brains/braincommon.lua（共享底座）,
--           behaviours/{standandattack,wander,doaction,faceentity,leash}.lua,
--           components/combat.lua（SuggestTarget / SetTarget / TargetIs）,
--           components/{inventory,health,burnable}.lua,
--           tuning.lua（TUNING.MUTATEDBUZZARD_FIND_CORPSE_DELAY）,
--           FOODGROUP.OMNI.types（FOOD_TAGS 的来源）
--============================================================
--[[
--[ [
-- buzzardbrain.lua —— 秃鹫大脑
--
-- 【★★★ 本文件最大的看点：脑覆写 DoUpdate 做跨节点缓存】
--   第 316-319 行 BuzzardBrain:DoUpdate 只做一件事：self.threat = false
--   ★★★ 为什么需要一个「每帧重置缓存」的钩子？
--     因为行为树的执行顺序不固定，同一帧里 FindThreat 可能被多个节点调用；
--     若直接每次都 FindEntity，空间搜索会重复执行（昂贵）。
--     做法：把结果缓存到 self.threat，用三态表达「未查/查过有/查过无」：
--       self.threat == nil  → 查过，没找到（或还没查，见下）
--       self.threat == false → 还没查过
--       self.threat == 其他   → 查到的实体
--     ★★ DoUpdate 由 brain.lua 在【每帧开头】调用并把缓存清空，
--       于是一帧内第一次调用触发搜索，后续调用直接命中缓存。
--     ★★ 这是「按帧失效的缓存」，比「按事件失效」更简单也更安全。
--     ★ 移植价值极高：任何需要「一帧内多次查询但结果不变」的场合都能套用。
--
-- 【★ 三态缓存的精妙之处（第 267-276 行 FindThreat）】
--   第 268 行 if self.threat == nil then return nil end
--     nil 被解释为「查过了，没有」。
--   第 270 行 elseif self.threat ~= false then return self.threat end
--     非 nil 非 false 则是查到的实体。
--   第 274 行真正搜索。
--   ★ 缺点：第一次调用时 self.threat 初始为 nil（第 331 行附近只设了 corpse_time），
--     会被误判成「查过、没有」，导致第一帧不搜。
--   ⚠️ 已逐字核对：BuzzardBrain:OnStart 第 331-333 行只设了 ismutated 与 corpse_time，
--     确实没设 self.threat = false。★ 所以首帧 IsThreatened 会返回 nil。
--     影响极小（仅第一帧），属真实但无害的不严密。标为轻微缺陷。
--
-- 【⚠️ 容易踩的坑】
-- · 第 45-49 行四个标签表的名字【与实际语义相反】，源码自己写了注释：
--   FINDTHREAT_MUST_TAGS 实际传的是 CANT_TAGS 位置（第 65 行）
--   FINDTHREAT_CANT_TAGS  实际传的是 ONE_OF_TAGS 位置
--   源码注释："This is actually CANT_TAGS" / "This is actually ONE_OF_TAGS"
--   ★★ 极易看错，详见对应锚点。
-- · 第 123 行 ignorethese 是【文件级共享表】而非局部变量，
--   意味着所有秃鹫共享同一份「尸体占有」记录。这是设计意图（见第 131 行）。
-- · 第 392-394 行 OnStop 释放尸体 —— ★ 全DST 少见的 OnStop 实现，
--   大部分脑只在 OnStart 建树。详见该行注释。
--] ]

    Buzzards will only eat food laying on the ground already. They will not harvest food.

    Buzzard spawner looks for food nearby and spawns buzzards on top of it.
    Buzzard spawners also randomly spawn/ call back buzzards so they have a presence in the world.

    When buzzards have food on the ground they'll land on it and consume it, then hang around as a normal creature.
    If the buzzard notices food while wandering the world, it will hop towards the food and eat it.


    If attacked while eating, the buzzard will remain near it's food and defend it.
    If attacked while wandering the world, the buzzard will fly away.

--]]

--[[

    Mutated Buzzard behaviours

        No panicking (possessed by gestalt now)
--]]

require("stategraphs/commonstates")
require("behaviours/standandattack")
require("behaviours/wander")

local BuzzardBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local FLY_AWAY_AFTER_NO_CORPSE_TIME = 20
-- ★ 20 秒没有尸体就飞走（变异体的自限时）。

local SEE_FOOD_DIST = 15
-- ★ SEE_FOOD_DIST=15 同时用于找食物（第 91 行）与找尸体（第 242 行）。
--   ⚠️ 名字叫 FOOD 却也管尸体，属命名与用途不符（非缺陷，但阅读时要注意）。

local SEE_THREAT_DIST = 7.5
-- ★★ 普通秃鹫的威胁感知距离 7.5，变异体只有 3 ——
--   ★ 差 2.5 倍。注释说明变异秃鹫「更自信」（实为「更迟钝」）。
--   ★ 这是用参数表达角色差异的最简做法。
local MUTATED_SEE_THREAT_DIST = 3

local NO_TAGS = { "FX", "NOCLICK", "DECOR", "INLIMBO", "outofreach" }
-- NO_TAGS：排除特效、不可点击、装饰、加载中、够不到。
local FOOD_TAGS = {}
-- ★★ FOOD_TAGS 在【模块加载时】从 FOODGROUP.OMNI.types 动态生成。
--   for i, v in ipairs(FOODGROUP.OMNI.types) do table.insert(FOOD_TAGS, "edible_"..v) end
--   ★★★ 「什么能吃」由 FOODGROUP 定义，大脑不硬编码。
--     ★★ 移植价值极高：食物类别变更时所有秃鹫行为自动跟随，零改动。
--   ★ 这是「配置驱动而非代码驱动」的教科书案例。
--   ⚠️ 代价：调试时看不到具体标签，只能去 FOODGROUP 里查。
for i, v in ipairs(FOODGROUP.OMNI.types) do
    table.insert(FOOD_TAGS, "edible_"..v)
end

local FINDTHREAT_MUST_TAGS = { "notarget", "playerghost" } -- This is actually CANT_TAGS
-- ⚠️⚠️⚠️ ★★★ 本文件最危险的地方：变量名与实际用途【完全相反】。
--
-- 【源码自带的澄清注释】
--   第 45 行 FINDTHREAT_MUST_TAGS = { "notarget", "playerghost" }
--     -- This is actually CANT_TAGS
--   第 46 行 FINDTHREAT_CANT_TAGS = { "player", "monster", "scarytoprey" }
--     -- This is actually ONE_OF_TAGS
--
-- 【为什么】
--   第 65 行 FindEntity(inst, radius, 过滤函数, nil, FINDTHREAT_MUST_TAGS, FINDTHREAT_CANT_TAGS)
--   ★ FindEntity 的第 5 参是 CANT_TAGS、第 6 参是 ONE_OF_TAGS。
--   ★ 作者按【CANT在前 ONE_OF在后】的顺序命名，却对调了实际传入的位置。
--
-- 【实际语义】
--   第 5 参（真 CANT）：notarget（不可索敌）、playerghost（幽灵玩家）→ 排除
--   第 6 参（真 ONE_OF）：player、monster、scarytoprey → 只要有其中之一就算
--
-- ★★ 移植警示：如果你「修正」这两个名字而不同时调整第 65、66 行的
--   传入顺序，行为会直接反转（把该躲的当目标，把目标当该躲的）。
--   ★ 我已用 grep 核实这两处注释确在源码中，非我的误读。
local FINDTHREAT_CANT_TAGS = { "player", "monster", "scarytoprey" } -- This is actually ONE_OF_TAGS

local FINDTHREAT_MUTATED_CANT_TAGS = { "notarget", "lunar_aligned", "playerghost" } -- This really is CANT_TAGS!
-- 变异体的两个标签表命名【是正确的】（作者在这里没搞反）。
--   第 48 行 FINDTHREAT_MUTATED_CANT_TAGS 确实传在第 5 参（第 63 行）。
--   ★ 对比第 45-46 行：同一文件里两种命名风格并存，且第 48 行是对的。
--   ★ 这反证了第 45-46 行确实是笔误而非某种刻意的「对称命名」。
local FINDTHREAT_MUTATED_ONE_OF_TAGS = { "player", "monster", "scarytoprey", } -- This really is ONE_OF_TAGS!

-- Regular buzzards care about protecting their food from other buzzards, but mutated, they are united!
-- ★★ Normal_IsValidThreat —— ★ 一个精心设计的「例外规则」。
--   return not guy:HasTag("buzzard") or inst:IsNear(guy, 攻击距离+对方半径)
-- 【语义】
--   非秃鹫 → 算威胁
--   是秃鹫 → 【只有已经贴到脸上了才算威胁】
-- ★★★ 含义：「平时互不攻击，只在靠得很近时才打起来」。
--   ★ 注释说：普通秃鹫在乎保护自己的食物不被别的秃鹫抢，变异体则团结一致。
--   ★ 即「只有为争食才打架」—— 用距离阈值表达「争抢范围」。
--   ★★ 这种「规则里内嵌例外」比堆叠标签优雅得多，移植价值高。
local function Normal_IsValidThreat(guy, inst)
    return not guy:HasTag("buzzard") or inst:IsNear(guy, inst.components.combat:GetAttackRange() + guy:GetPhysicsRadius(0))
end

local function Mutated_IsValidThreat(guy)
-- Mutated_IsValidThreat：变异体只认「有战斗组件」的。
--   ★ 注释解释了原因：有 scarytoprey 标签但没战斗组件的东西会让它卡住。
--   ★ 即「把打不了的东西从威胁列表剔除」，避免 AI 反复扑向无法交战的敌人。
    return guy.components.combat ~= nil -- Some things have scarytoprey but no combat component, so we get stuck.
end

local function FindThreat(inst, radius)
-- FindThreat：普通与变异走不同参数表（第 62-66 行）。
--   ★ 同一个函数、两个分支 —— 比写两个函数简洁，且保证了「只有一个搜索点」。
    local ismutated = inst:HasTag("lunar_aligned")
    if ismutated then
        return FindEntity(inst, radius, Mutated_IsValidThreat, nil, FINDTHREAT_MUTATED_CANT_TAGS, FINDTHREAT_MUTATED_ONE_OF_TAGS)
    else
        return FindEntity(inst, radius, Normal_IsValidThreat, nil, FINDTHREAT_MUST_TAGS, FINDTHREAT_CANT_TAGS)
    end
end

local function IsSgBusy(inst)
-- IsSgBusy：睡眠 / 忙 / 飞行中。
-- ★★ 这三个状态都会「暂时放弃决策」，很多判定都先问它。
--   ★ 用一个函数统一表达「暂时别管我」，避免各处重复判断。
    return inst.sg:HasAnyStateTag("sleeping", "busy", "flight")
end

local function CanEat(food)
-- CanEat：★ 极简 —— 只能吃在地上的东西。
--   ★ 与文件头注释（第 3 行）吻合：秃鹫只吃地上的食物，不会采集。
--   ★ 判定故意极简，因为变异体根本不用这个函数（第 79 行直接返回 nil）。
    return food:IsOnValidGround()
end

local function FindFood(inst, radius)
-- FindFood：★ 变异体直接返回 nil —— 「变异秃鹫对食物没兴趣」。
--   ★★★ 用一个 early return 实现「完全换掉一套需求」，非常干净。
--     变异体要的是尸体（第 241 行 FindCorpse），不是食物。
--   ★ 移植提示：给同一实体加形态时，用 early return 关掉不需要的需求分支。
    -- Mutated buzzard isn't interested in actual food.
    if inst:HasTag("lunar_aligned") then
        return nil
    end
    --
    return FindEntity(inst, radius, CanEat, nil, NO_TAGS, FOOD_TAGS)
end

local function EatFoodAction(inst)  --Look for food to eat
    if inst.sg:HasStateTag("busy") then
        return
    end

    local food = FindFood(inst, SEE_FOOD_DIST)
    return food ~= nil and BufferedAction(inst, food, ACTIONS.EAT) or nil
end

local function GoHome(inst)
-- GoHome：★ 注意它【不检查 shouldGoAway】，只读它 ——
--   return inst.shouldGoAway and BufferedAction(inst, nil, ACTIONS.GOHOME) or nil
--   ★ 即「别人决定要不要走，我只负责执行」。
--   ★★ 这是「决策与执行分离」：ShouldFlyAwayFromFire（第 99 行）与
--     Mutated_ShouldFlyAway（第 107 行）只负责设标志，
--     root 里的三个 DoAction 节点负责执行。
--   ★ 同一件事有三个入口（第 341、345、348 行），都复用这个执行函数。
    return inst.shouldGoAway and BufferedAction(inst, nil, ACTIONS.GOHOME) or nil
end

local function ShouldFlyAwayFromFire(inst)
-- ★ ShouldFlyAwayFromFire：着火了但自己没在烧 → 飞走。
--   第 101 行的 and not (...IsBurning()) 语义：
--   「正在受火焰伤害」且「燃烧组件说自己没在烧」——
--   ★ 即「被别的火源烧到但自己不燃」，此时飞走而不是灭火。
--   ★ 若自己真的在烧（第 2 项为假），则不飞 —— 因为飞也没用。
--   ★ 条件判断的精度值得学。
    if not IsSgBusy(inst)
        and (inst.components.health ~= nil and inst.components.health.takingfiredamage and not (inst.components.burnable and inst.components.burnable:IsBurning())) then
        inst.shouldGoAway = true
        return true
    end
end

local function Mutated_ShouldFlyAway(inst)
-- ★★ Mutated_ShouldFlyAway：★ 变异体的「找不到尸体就走」。
-- 【第 110 行】GetTime() - inst.brain.corpse_time > 20
--   ★ corpse_time 由 LoseCorpseOwnership（第 178 行）设置。
--   ★★ 于是语义是：「失去尸体后已超过 20 秒」→ 离开。
--   ★ 注意第 109 行 not inst.brain.corpse —— 必须当前没有尸体。
--   ★ 三者与即：没尸体 + 超过时限 + 自己不在烧。
    if not IsSgBusy(inst)
        and not inst.brain.corpse
        and GetTime() - inst.brain.corpse_time > FLY_AWAY_AFTER_NO_CORPSE_TIME
        and not (inst.components.burnable and inst.components.burnable:IsBurning()) then
        inst.shouldGoAway = true
        return true
    end
end

local function GetHomePos(inst)
-- GetHomePos：★ 直接返回自己的位置。
--   ★★ 意味着「家」概念对秃鹫不存在 —— 它到处为家。
--   ★ 第 385 行 Wander(self.inst, GetHomePos, 5) 因此就是「在原地附近晃悠」。
--   ★ 与 pigbrain 第 142 行 GetHomePos 返回真实家位置形成对照。
    return inst:GetPosition()
end

--------------------------------------------------------------------------

local ignorethese = { --[[ [corpse] = { [buzzard] = true ]] }
-- ★★★ ignorethese —— ★ 文件级共享表，不是局部变量。
--   源码用注释形式示范了它的结构（实体 → { 实体 → true }）。
--   ★★★ 这是【两层字典】：ignorethese[尸体][占有者秃鹫] = true
--   ★★ 为什么必须是文件级（而非每个脑实例一份）？
--     因为「哪只秃鹫占有了哪具尸体」是【跨实例的共享事实】。
--     若每只秃鹫各有一张表，它们互相看不见，就会一起扑向同一具尸体。
--   ★★★ 移植要点：需要跨 AI 实例协调时，状态表必须放在模块级，
--     而不是放在脑实例或实体上。这是本文件最核心的设计决策。

local SIZE_TO_NUM_OWNERS = { -- How many buzzards can eat this corpse?
-- ★★★ SIZE_TO_NUM_OWNERS —— 尸体容量表，按尸体尺寸分配占有名额。
--   tiny=1（兔子）small=2（猎犬）med=5（牛）large=10（Boss 如温蒂/独眼巨鹿）
-- ★★ 语义：大尸体能养活更多秃鹫，小尸体只能一只独享。
--   ★★★ 这是一个【资源容量 + 多方分配】的完整设计，
--     且与游戏世界设定挂钩（大 Boss 的尸体能喂饱一整群）。
--   ★ 移植价值：适用于任何「可被多个单位采集的资源」。
--   ★ 第 132 行 TODO 承认还有改进空间（满了也应允许「稍微挤一挤」）。
    ["tiny"] = 1, -- e.g. rabbits
    ["small"] = 2, -- e.g. hounds
    ["med"] = 5, -- e.g. beefalo
    ["large"] = 10, -- e.g. bosses, like bearger or deerclops
}
-- Corpses can have multiple buzzards eating them depending on size
-- TODO buzzards shouldnt ignore a corpse even if its maxxed out, just encourage splitting up slightly, but if there's only one, go for it!
function BuzzardBrain:OwnCorpse(corpse)
-- ★★★ OwnCorpse —— 「取得尸体独占权」，本文件最重要的方法。
-- 【第 134 行】★ 先无条件释放旧尸体
--   ★ 即使要占的正是现在占的，也先释放再重新占 ——
--   保证第 138-141 行的登记逻辑一定执行。
-- 【第 138-141 行】★ 登记进共享表
--   ignorethese[corpse][self.inst] = true
--   ★ 这一行让全世界的秃鹫都能看到「我占了它」。
-- 【第 143-161 行】★★ 惰性创建事件回调
--   self._on_corpse_ignite = self._on_corpse_ignite or function(...) end
--   ★★★ `x = x or function` 的惯用法：只在第一次调用时创建闭包，之后复用。
--     ★ 意义：闭包内的 self 是固定的脑实例，若每次重建会造成 GC 压力
--     且 RemoveEventCallback 需要【同一个函数对象】才能正确注销。
--     ★★ 这正是第 174-175 行能正确注销的前提 —— 回调必须是同一个对象。
--     ★ 移植必读：事件回调若要注销，必须保证引用稳定。
-- 【第 152-161 行】_on_corpse_chomped：有人抢食就还击
--   第 157 行 ★★ (ismutated and not eater:HasTag("gestaltmutant")) or not ismutated
--   语义：变异体只对「非变异体」还击；普通秃鹫对谁都还击。
--   ★ 与第 51 行 Normal_IsValidThreat 的「同类不互殴」策略一致（此处是例外后门）。
-- 【第 163-164 行】ListenForEvent(事件, 回调, 源实体)
--   ★★ 第 3 参指定源实体 = 尸体，即「监听这具尸体身上的事件」。
--     与第 130 行 inst:ListenForEvent("epicscare", fn)（不指定源）不同。
    self:LoseCorpseOwnership()

    self.corpse = corpse

    if not ignorethese[corpse] then
        ignorethese[corpse] = {}
    end
    ignorethese[corpse][self.inst] = true

    self._on_corpse_ignite = self._on_corpse_ignite or function(ent, data)
        -- doer could actually be source, yuck!
        local doer = data ~= nil and (data.doer or data.source) or nil
        if doer and self.inst.components.combat:CanTarget(doer) then
            self.inst.components.combat:SuggestTarget(doer)
        end
    end

    local ismutated = self.inst:HasTag("lunar_aligned")
    self._on_corpse_chomped = self._on_corpse_chomped or function(ent, data)
        local eater = data ~= nil and data.eater or nil
        if eater and self.inst.components.combat:CanTarget(eater) then
            -- If we're mutated, and the eater isn't a fellow mutant, we're getting ya!
            -- If we're not mutated, we don't like sharing at all!
            if (ismutated and not eater:HasTag("gestaltmutant")) or not ismutated then
                self.inst.components.combat:SetTarget(eater)
            end
        end
    end

    self.inst:ListenForEvent("onignite", self._on_corpse_ignite, self.corpse)
    self.inst:ListenForEvent("chomped", self._on_corpse_chomped, self.corpse)
end

function BuzzardBrain:LoseCorpseOwnership()
-- ★★★ LoseCorpseOwnership —— 与 OwnCorpse 严格对称的释放。
-- 【第 169-172 行】★★ 两级清理
--   ignorethese[self.corpse][self.inst] = nil   移除自己
--   if GetTableSize(...) == 0 then ignorethese[self.corpse] = nil end
--   ★★★ 关键：没人占了就删掉整个尸体条目，否则共享表会无限增长
--     （内存泄漏）。★ 这是「引用计数式清理」的标准写法。
--   ★ 移植价值：任何共享表都要有「空了就删」的逻辑。
-- 【第 174-175 行】注销事件 —— 依赖第 143/152 行的「引用稳定」保证
-- 【第 178 行】★★ corpse_time = GetTime()
--   ★ 这个时间戳被第 110 行的 Mutated_ShouldFlyAway 用来判断「失去多久了」。
--   ★ 即「释放尸体」顺带启动了「变异体倒计时」。两个功能耦合在一个方法里。
--   ⚠️ 耦合度较高：若将来在别处也调用 LoseCorpseOwnership，
--     会意外启动倒计时。当前调用点只有第 134 与 247 行，暂无问题。
    if self.corpse then
        ignorethese[self.corpse][self.inst] = nil
        if GetTableSize(ignorethese[self.corpse]) == 0 then
            ignorethese[self.corpse] = nil
        end

        self.inst:RemoveEventCallback("onignite", self._on_corpse_ignite, self.corpse)
        self.inst:RemoveEventCallback("chomped", self._on_corpse_chomped, self.corpse)
        self.corpse = nil

        self.corpse_time = GetTime()
    end
end

function BuzzardBrain:ShouldIgnoreCorpse(corpse)
-- ★★ ShouldIgnoreCorpse：★ 「我该不该让开这具尸体」的三段判定。
--  第 183-186 行：没人占 → 不忽略
--  第 189-192 行：★ 还没占满（GetTableSize < 容量）→ 不忽略
--  第 195-199 行：★★ 但如果我自己就是占有者之一 → 也不忽略
--  第 202 行：否则忽略
-- ★★★ 三段式的意义：占满了也不该把自己正在吃的赶走。
--   ★ 这是一个很常见的易漏点：容量检查必须给「已占有者」开后门。
-- ★ 与第 206 行的 Buzzard_ShouldIgnoreCorpse 对比：后者【少了第三段】。
    local owners = ignorethese[corpse]
    if not owners then
        return false
    end

    -- Enough space in the list for us.
    local _, sz, _ = GetCombatFxSize(corpse)
    if GetTableSize(owners) < SIZE_TO_NUM_OWNERS[sz] then
        return false
    end

    -- No more space, check if we're one of the owners
    for buzzard in pairs(owners) do
        if buzzard == self.inst then
            return false
        end
    end

    -- Don't eat this corpse.
    return true
end

-- For non-brain logic to use in manager component
-- ★★ Buzzard_ShouldIgnoreCorpse —— 非脑逻辑（管理器组件）用的版本。
-- 【与第 182 行 ShouldIgnoreCorpse 的差异】
--   ★★ 这个函数【少了「我就是占有者」的第三段判定】（第 195-199 行）。
--   源码注释解释：用途是「供 manager 组件在非脑逻辑中调用」。
-- ★ 为什么可以省掉第三段？
--   因为调用它的是【秃鹫生成器/管理器】（不是具体的秃鹫），
--   它没有「自己正在吃的尸体」这回事，所以不需要后门。
--   ★★ 这是「同一逻辑的两个变体，各自简化」的好例子。
-- ⚠️ 但两个函数逻辑已产生分叉，未来若只改其中一个就会不一致。
--   属真实的维护隐患，非当前 bug。
function Buzzard_ShouldIgnoreCorpse(corpse)
    local owners = ignorethese[corpse]
    if not owners then
        return false
    end

    -- Enough space in the list for us.
    local _, sz, _ = GetCombatFxSize(corpse)
    if GetTableSize(owners) < SIZE_TO_NUM_OWNERS[sz] then
        return false
    end

    -- Don't eat this corpse.
    return true
end

------------

local function IsNotBurning(inst)
    return inst.components.burnable == nil or not inst.components.burnable:IsBurning()
end

local CORPSE_MUST_TAGS = { "creaturecorpse" }
-- IsCorpseValid 的六重校验（第 232-238 行），★ 两条与变异有关：
--   第 234 行 (ismutated or IsNotBurning(guy)) —— ★ 变异体【不介意尸体在烧】
--   第 236 行 (not ismutated or not guy:HasGestaltArriving()) ——
--   ★★ 变异体【会避开正在变身的实体】（合体的成员不该被当尸体）。
-- ★ 两条都用 ismutated 做短路，把「变异体的特殊需求」压缩进两个条件。
-- ★ 写法紧凑但可读性下降，移植时建议拆开。
-- ★ 第 238 行注释："for non-entity scans" —— 双重保险（标签已在 MUST_TAGS 里）。
local CORPSE_NO_TAGS = { "NOCLICK" }
local function IsCorpseValid(guy, inst)
    local ismutated = inst:HasTag("lunar_aligned")
    return guy ~= nil
        and guy:IsValid()
        and (ismutated or IsNotBurning(guy))
        and not guy:IsMutating()
        and (not ismutated or not guy:HasGestaltArriving())
        and not inst.brain:ShouldIgnoreCorpse(guy)
        and guy:HasTag("creaturecorpse") -- for non-entity scans
end

function BuzzardBrain:FindCorpse()
-- ★ FindCorpse：找到就占有，找不到就释放。
--   ★★★ 这就是「目标获取即占有」的封装 —— 找到的瞬间就登记。
--   ★ 与第 247 行的 else 分支对称（找不到 → LoseCorpseOwnership）。
--   ★ 这种「要么占有要么释放」的原子性保证不会留下脏状态。
	local corpse = FindEntity(self.inst, SEE_FOOD_DIST, IsCorpseValid, CORPSE_MUST_TAGS, CORPSE_NO_TAGS)
    if corpse ~= nil then
        self:OwnCorpse(corpse)
        return true
    else
        self:LoseCorpseOwnership()
    end
end

function BuzzardBrain:IsCorpseValid()
-- IsCorpseValid / GetCorpsePosition：给节点用的轻量包装。
--   ★ GetCorpsePosition 返回 nil 表示「不该靠近了」，Leash 会停下。
--   ★ 与 knightbrain 第 208 行的 nil 语义一致。
	return IsCorpseValid(self.corpse, self.inst)
end

function BuzzardBrain:GetCorpsePosition()
	return self:IsCorpseValid() and self.corpse:GetPosition() or nil
end

--------------------------------------------------------------------------

-- Mutated buzzards are a bit more confident and detect a threat at a shorter distance
-- GetSeeThreatDist：按形态选感知距离。与第 36-37 行常量呼应。
local function GetSeeThreatDist(inst)
    return inst:HasTag("lunar_aligned") and MUTATED_SEE_THREAT_DIST
        or SEE_THREAT_DIST
end

function BuzzardBrain:FindThreat()
-- ★★★ FindThreat —— 三态缓存的读取逻辑，本文件的核心技巧。
--   第 268-269 行：★ nil → 视为「查过，没有」，直接返回 nil
--   第 270-272 行：★ 非 nil 非 false → 视为实体，直接返回
--   第 274-275 行：false → 才真正搜索
-- ★★★ 详见文件头注释中的三态说明与首帧的轻微不严密问题。
-- ⚠️ 已核实 OnStart（第 330-333 行）未初始化 self.threat = false，
--   故首帧会走第 268 行返回 nil（跳过搜索）。影响仅限第一帧。
    if self.threat == nil then -- nil means we tried finding a threat and there's none
        return nil
    elseif self.threat ~= false then -- false means we haven't tried a cache yet
        return self.threat
    end

    self.threat = FindThreat(self.inst, GetSeeThreatDist(self.inst)) or nil
    return self.threat
end

function BuzzardBrain:IsThreatened()
-- ★★ IsThreatened：★ 忙的时候【直接返回 nil】而不是 false。
--   return not IsSgBusy(self.inst) and self:FindThreat() or nil
--   ★★★ 注意这是 and/or 惯用法：
--     忙 → not true = false → and 短路 → false or nil = nil
--     不忙且找到 → 返回实体
--     不忙但没找到 → FindThreat 返回 nil → nil or nil = nil
--   ★★ 所以这个函数【永远不返回 false，只返回 nil 或实体】。
--     作为 IfNode 条件（第 352 行）用没问题，但函数名有误导性。
--   ★ 属风格问题，不是缺陷（IfNode 只看真假）。
    return not IsSgBusy(self.inst) and self:FindThreat() or nil
end

function BuzzardBrain:DealWithThreat()
-- ★★★ DealWithThreat —— 「有食物就守，没食物就跑」的核心决策。
-- 【第 286 行】★ 守卫条件
--   FindFood(inst, 1.5) ~= nil  → 脚边 1.5 格内有食物 → 守
--   ★ 或（变异体）self:FindCorpse()  → 找到尸体 → 守
--   ★★★ 注意：普通秃鹫的守卫条件只看「脚边 1.5 格」——
--     它守卫的是【正在吃的那个食物】的具体位置，不是「占有」概念。
--   ⚠️ 普通秃鹫的 FindCorpse 从不在这里被调用，
--     所以普通秃鹫【不使用尸体占有机制】。
--     ★ 核实：第 356-381 行 FindCorpse 只在 ismutated 条件下进入（第 358 行），
--     确认该机制仅变异体使用。而 OwnCorpse 的第 133 行注释提到两种都有。
--   ★ 这是有意区分：普通秃鹫抢食即走，变异秃鹫守着尸体吃。
-- 【第 289-292 行】★ 威胁在够不着的地方（水面上）→ 放弃食物逃走
--   注释："we should just go away. Sorry, cheese it."（溜了）
--   ★ 幽默注释，但逻辑合理：追不上就别追了。
-- 【第 293-306 行】★★ 变异体用 SuggestTarget（建议）而非 SetTarget（强制）
--   第 296 行 if SuggestTarget(...) 成功 → 停下并清缓冲动作
--   第 300 行 失败 → ★ return false，让 PriorityNode 继续试下一个节点
--   ★★★ 「建议」机制让多只变异秃鹫协商同一目标（Combat 内部处理冲突），
--     比直接 SetTarget 更有群体协调能力。
--   第 303-305 行 普通秃鹫直接 SetTarget（不需要协调）。
-- ★★ 这是本文件第二处「群体协调」设计（第一处是 ignorethese 表）。
    --If you have some food then defend it! Otherwise... cheese it!
    local ismutated = self.inst:HasTag("lunar_aligned")

    if FindFood(self.inst, 1.5) ~= nil or (ismutated and self:FindCorpse()) then
        local threat = self:FindThreat()
        if threat ~= nil then
            if not threat:IsOnValidGround() then
                -- If our threat is out on the ocean, or otherwise somewhere we can't reach,
                -- we should just go away. Sorry, "cheese it".
                self.inst.shouldGoAway = true
            elseif not self.inst.components.combat:TargetIs(threat) then
                -- For mutated we suggest the target, to see if there's already other buzzards on it or not
                if ismutated then
                    if self.inst.components.combat:SuggestTarget(threat) then
                        self.inst.components.locomotor:Stop()
                        self.inst:ClearBufferedAction()
                    else
                        return false -- To the next node
                    end
                else
                    self.inst.components.locomotor:Stop()
                    self.inst:ClearBufferedAction()
                    self.inst.components.combat:SetTarget(threat)
                end
            end
        end
    else
        self.inst.shouldGoAway = true
    end

    return true
end

function BuzzardBrain:DoUpdate()
-- ★★★★ DoUpdate —— ★★★ 本文件最值得移植的一段。
-- 【机制】每帧只做一件事：把 threat 缓存标记为「待查」。
-- 【为什么要这个钩子】
--   行为树的节点执行顺序不保证固定，同一帧内 IsThreatened 可能被调用多次
--   （第 279 行在两个节点里各出现一次）。
--   若每次都 FindEntity（球形空间搜索），一帧会做多次昂贵查询。
-- 【为什么「标记待查」优于「清除结果」】
--   若把 threat 设为 nil，会被第 268 行误解为「查过没有」，缓存永远失效。
--   设成 false 则明确表示「还没查」，下次调用才真正搜索。
-- ★★★ DoUpdate 由 brain.lua 逐帧调用，顺序已核实（顶层 brain.lua 第 228-236 行）：
--   function Brain:OnUpdate()
--       if self.DoUpdate then self:DoUpdate() end
--       if self.bt then self.bt:Update() end
--   end
--   ★★ 即【先清缓存，再跑行为树】—— 顺序正是缓存能生效的前提：
--     每次跑树之前缓存都被标记为「待查」，树内多次查询只搜一次。
--   ★★ 所以这是一个【脑级别的生命周期钩子】，与行为树节点无关。
--   ★★ Brain:OnUpdate 是 Brain 基类的虚方法，子类可覆写（本文件覆写 DoUpdate）；
--     而 OnStart 是【必须】实现的（每个大脑都实现），OnUpdate/OnStop 是可选的。
--   ★ 移植要点：需要「每帧失效的缓存」时，用脑级钩子而不是节点钩子。
--   ★ 顺带解释了第 392 行 OnStop 的对偶：OnStop 由 StopBrain 触发，
--     用于释放本文件第 133 行登记的模块级共享状态。
-- ★ 这是全DST 少数几个覆写 DoUpdate 的大脑，grep DoUpdate 可找到全部案例。
    -- Reset our caches.
    self.threat = false
end

--------------------------------------------------------------------------

-- Some creatures physics radii are obscenely small (see Deerclops) so calculate combat fx size and get the larger of the two.
-- ★★★ GetCorpseRadius —— 一个很实际的工程细节。
--   第 326 行 return math.max(r, corpse:GetPhysicsRadius(0))
--   ★ 注释说明了原因：「有些生物的物理半径小得离谱（见独眼巨鹿）」。
--   ★★★ 所以取「战斗特效尺寸」与「物理半径」两者的较大值。
--     ★ 这是「美术/玩法尺寸与碰撞尺寸不一致」时的通用处理办法。
--   ★ 用途：第 370-371 行用它决定 Leash 到尸体的距离（停在嘴够得着的地方）。
local function GetCorpseRadius(corpse)
    local r, sz, ht = GetCombatFxSize(corpse)
    return math.max(r, corpse:GetPhysicsRadius(0))
end

local UPDATE_RATE = .5
-- UPDATE_RATE = 0.5 —— 本文件所有 PriorityNode 的重评估间隔。
--   ★ 比 pigbrain 的 0.5 相同，比 knightbrain 的 0.25 宽松。
--   ★ 秃鹫的行为「不需要精确反应」，所以省 CPU。
function BuzzardBrain:OnStart()
-- OnStart：★ ismutated 在【开头】就确定，后续节点直接用闭包捕获。
--   ★★ 关键设计：第 331 行 local ismutated = self.inst:HasTag("lunar_aligned")
--   之后第 339、343、358 行全部用这个局部变量，而不是重新查标签。
--   ★ 效率考量：标签查询虽便宜但每次都调没必要，闭包捕获更清晰。
--   ★ 对比 shadowwaxwellbrain 第 293 行也是这个手法（但那个要算距离）。
--   ⚠️ 第 333 行只设了 corpse_time，【没设 self.threat = false】，
--   即文件头注释提到的首帧缓存不严密问题。
    local ismutated = self.inst:HasTag("lunar_aligned")

    self.corpse_time = GetTime()

    local root = PriorityNode(
    {
        WhileNode(function() return not self.inst.sg:HasAnyStateTag("flight", "flamethrowering") end, "Not Flying or Flamethrowering",
-- ★★ 最外层守卫：不在飞行、不在喷火。
--   条件 not sg:HasAnyStateTag("flight", "flamethrowering")
--   ★ 与其他文件的单一 jumping 守卫不同，这里排除了【两个】状态。
--   ★ 喷火（flamethrowering）期间不能做觅食/找尸体 ——
--     否则会在喷火途中跑去找食物。合理的排除。
        PriorityNode({
            IfNode(function() return not ismutated end, "NormalPanic",
-- ★ 普通秃鹫的着火逃跑（不适用变异体）。
--   ★ 用 IfNode 包裹而非 WhileNode —— 一次判断即可。
--   ⚠️ 与第 343 行变异体的 IfNode 条件互为否定，
--     但两者之间还有第 347 行的通用 shouldGoAway 节点。
--     ★ 若普通秃鹫着火了，第 339 行已处理；不会走到第 347 行。逻辑自洽。
                WhileNode(function() return ShouldFlyAwayFromFire(self.inst) end, "Go Away From Fire",
                    DoAction(self.inst, GoHome))),

            IfNode(function() return ismutated end, "NoMoreCorpses",
-- ★ 变异体的「找不到尸体就飞走」。与第 339 行互斥。
                WhileNode(function() return Mutated_ShouldFlyAway(self.inst) end, "Fly away",
                    DoAction(self.inst, GoHome))),

            WhileNode(function() return self.inst.shouldGoAway end, "Go Away",
-- ★★ shouldGoAway 是三个逃跑入口的【统一标志】：
--   三个节点（第 339、343、347 行）都在自己的条件里设 inst.shouldGoAway = true，
--   而第 347 行负责在标志已设但上面两个条件都不满足时执行离开。
--   ★★★ 「设标志」与「执行」分离 —— 与第 95 行 GoHome 的设计一脉相承。
--   ★ 好处：一个动作函数（第 96 行）服务三种触发原因。
                DoAction(self.inst, GoHome)),

            StandAndAttack(self.inst),
-- ★ StandAndAttack：站着打。behaviours/standandattack.lua。
--   ★ 秃鹫是「守食」型：不追着打，就在原地打走靠近的。
--   ★ 与 ChaseAndAttack（追击型）形成对比，
--     monkeybrain 第 343 行用的是后者。

            IfNode(function() return self:IsThreatened() end, "Threat Near",
-- ★★ 「有威胁」的三个入口之一（第 352 行）。
--   第 353 行 ConditionNode(DealWithThreat) ——
--   ★ ConditionNode 只执行条件函数、不产生持续行为，
--     「有威胁就处理一下威胁」。
--   ★★ DealWithThreat 返回 false 时（第 300 行变异体协商失败），
--     条件失败 → PriorityNode 继续试后续节点。
--   ★ 这就是第 300 行那句 "To the next node" 的实际效果。
--   ★ 机制设计得不错：协商失败时优雅降级为「先做别的」。
                ConditionNode(function() return self:DealWithThreat() end)),

            -- Eating a corpse, for mutated buzzards only (for now?)
-- ★★★ 变异体吃尸体的完整子树（本文件最长的节点块）。
-- 【第 358 行条件】★ 三个 or：变异体 且 不忙 且
--   （无战斗目标 或 最后被攻击已超过 TUNING.MUTATEDBUZZARD_FIND_CORPSE_DELAY）
--   ★★ 最后那个 or 很有意思：「正在打架时不找尸体，被打了一会儿才去找」
--     —— 给战斗留出合理的时间窗口，不会一被打就放弃打架去吃饭。
-- 【第 365-381 行结构】
--   IfNode(找尸体成功) → PriorityNode{
--     FailIfSuccessDecorator(Leash 到尸体旁), 到达即完成
--     IfNode(尸体有效 且 不在冷却) → 推 corpse_eat 事件
--     FaceEntity(看着尸体)
--   }
-- 【★ 第 370-371 行】★★ Leash 距离是【函数】：
--   自己的攻击距离 + 尸体半径 - 1
--   ★★★ 语义：站在「我刚好能碰到尸体」的距离上吃。
--     ★ 把战斗参数与拾取距离联动，非常实用（长柄武器能站更远）。
--     ★ 外减 1 与内减 1.5 形成迟滞（外 1 / 内 1.5），避免边界抖动。
-- 【★ 第 375 行】FacePoint —— 「尸体正好在我脚下，导致没能走到 FaceEntity」
--   ★ 注释解释了这个边缘情况：贴着尸体时 Leash 距离 0 立刻成功，
--     跳过了 FaceEntity，所以这里补一个转身。
--   ★ 典型的「兜底处理」，作者把原因写进注释，值得学。
-- 【第 376 行】PushEventImmediate —— 立即派发
--   ★ 与 braincommon 第 651 行的 PossessChassis 同款：
--     需要立刻生效的场景用 Immediate 版本。
			WhileNode(
				function()
					return ismutated and
                        not IsSgBusy(self.inst) and (
						not self.inst.components.combat:HasTarget() or
						self.inst.components.combat:GetLastAttackedTime() + TUNING.MUTATEDBUZZARD_FIND_CORPSE_DELAY < GetTime()
					)
				end,
				"WeCanEatACorpse!",
				IfNode(function() return self:FindCorpse() end, "Eat Corpse",
					PriorityNode({
						FailIfSuccessDecorator(
							Leash(self.inst,
								function() return self:GetCorpsePosition() end,
								function() return self.inst.components.combat:GetHitRange() + GetCorpseRadius(self.corpse) - 1 end,
								function() return self.inst.components.combat:GetHitRange() + GetCorpseRadius(self.corpse) - 1.5 end,
								true)),
						IfNode(function() return self:IsCorpseValid() and not self.inst.components.combat:InCooldown() end, "chomp",
							ActionNode(function()
                                self.inst:FacePoint(self.corpse.Transform:GetWorldPosition()) -- In case the corpse was right on top of us and so we couldn't get to FaceEntity node first.
                                self.inst:PushEventImmediate("corpse_eat", { corpse = self.corpse })
                            end)),
						FaceEntity(self.inst,
							function() return self.corpse end,
							function() return self:IsCorpseValid() end),
					}, .25))),
			--

            DoAction(self.inst, EatFoodAction),
-- ★ 觅食（普通秃鹫；变异体在第 79 行已被 FindFood 排除，这里自然不生效）。
--   ★ 第 385 行 Wander(self.inst, GetHomePos, 5) 作为最后兜底。
--   ★ 与其他文件一致，末尾必有永不失败的节点。
            Wander(self.inst, GetHomePos, 5)
        }, UPDATE_RATE))
    }, UPDATE_RATE)

    self.bt = BT(self.inst, root)
end

function BuzzardBrain:OnStop()
-- ★★★ OnStop —— ★★ 全DST 少见：大脑停止时释放资源。
-- 【为什么要】
--   秃鹫被杀死、卸载、或场景结束时，第 133 行登记的「尸体占有」
--   必须释放。否则共享表 ignorethese 里会留下【已死秃鹫的记录】，
--   ★ 导致那具尸体永远显示「已占满」，其他秃鹫再也不去吃。
-- ★★ 这就是「共享表的生命周期必须与参与者绑定」的直接体现。
--   ★ 移植必读：任何进程级/模块级共享状态，都要有在实体消失时的清理钩子。
--   ★ 对比：绝大多数大脑文件【没有】OnStop，因为它们不持有跨实例状态。
--   ★ 这恰好说明「需要 OnStop」与「有模块级共享表」强相关。
	self:LoseCorpseOwnership()
end

return BuzzardBrain