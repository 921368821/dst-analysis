--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/combat.lua
-- 模块：组件系统 / 战斗（Combat）
-- 职责：攻击目标的选择与维持、命中判定（距离 + 扇形弧）、伤害聚合结算
--       （CalcDamage）、攻击执行与反伤、范围伤害、友军与仇恨标签规则。
--       与 health.lua 的分工：Combat 只负责「算出该扣多少」，
--       真正的血量变动一律由 health.lua 的 DoDelta 承接。
-- 关键符号：Combat, CalcDamage, CanHitTarget, DoAttack, DoAreaAttack,
--           TryRetarget, EngageTarget, GiveUp, ShouldAggro, ShareTarget,
--           SetRange, SetHitArc, SetAreaDamage, CalcReflectedDamage,
--           CanBeAttacked, ClearAttackTemps, OnEntitySleep, OnEntityWake
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/health.lua（DoDelta 扣血落点）,
--           components/weapon.lua（GetDamage 武器伤害源）,
--           components/locomotor.lua（移动与到达判定）,
--           components/ridermount.lua（骑乘伤害继承）,
--           util/sourcemodifierlist.lua（externaldamagemultipliers 容器）,
--           stategraph（战斗状态切换）, entityscript.lua（组件挂载）
--============================================================
local SourceModifierList = require("util/sourcemodifierlist")
--[[
-- combat.lua —— 战斗组件（Combat）
--
-- 这是DST 里最核心的组件之一：所有「谁打谁、打多少、能不能打中」的判定都收口于此。
-- 全文件可分为五段：
--   1) 属性存取器（Set*/Get*，第 115-290 行）—— 纯数据搬运，几乎无逻辑
--   2) 目标选择（Retarget/Engage/GiveUp，第 246-560 行）—— AI 的「该打谁」
--   3) 命中判定（CanHitTarget，第 1034 行）—— 距离 + 扇形弧的几何测试
--   4) 伤害结算（CalcDamage，第 846 行）—— ★全文件最重要的函数，见下方详解
--   5) 攻击执行（DoAttack，第 1095 行）—— 真正扣血、发特效、触发反伤
--
-- 【移植要点】CalcDamage 的「八项乘法 + 一项加法」结构是DST 伤害系统的骨架，
-- 自己写引擎时照抄这个结构即可：各项修正器彼此正交、单一职责、顺序无关。
--]]
local SpDamageUtil = require("components/spdamageutil")

local function onattackrange(self, attackrange)
    self.inst.replica.combat:SetAttackRange(attackrange)
end

local function onminattackperiod(self, minattackperiod)
    self.inst.replica.combat:SetMinAttackPeriod(minattackperiod)
end

local function oncanattack(self, canattack)
    self.inst.replica.combat:SetCanAttack(canattack)
end

local function ontarget(self, target)
    self.inst.replica.combat:SetTarget(target)
end

local function onpanicthresh(self, panicthresh)
    self.inst.replica.combat:SetIsPanic(panicthresh ~= nil and self.inst.components.health ~= nil and panicthresh > self.inst.components.health:GetPercent())
end

local Combat = Class(function(self, inst)
    self.inst = inst

    self.nextbattlecrytime = nil
    self.battlecryenabled = true
    self.attackrange = 3
    self.hitrange = 3
    self.areahitrange = nil
	self.hitarc = nil
    self.temprange = nil
	--self.areahitcheck = nil
    self.areahitdamagepercent = nil
    --self.areahitdisabled = nil
    self.defaultdamage = 0
    --
    --use nil for defaults
    --self.playerdamagepercent = 1 --modifier for NPC dmg on players, only works with NO WEAPON
    --self.pvp_damagemod = 1
    --self.damagemultiplier = 1
    --self.damagebonus = 0
    --self.ignorehitrange = false
    --self.noimpactsound = false
    --

    -- NOTES(JBK): Aggro system for combat to help make things untargetable temporarily.
    -- None of this is saved in a restart and should be instantiated as things go.
    -- shouldaggrofn returns if the owner of this combat component should target the passed in target.
    -- shouldavoidaggro is a table that holds entity references as keys in it for temporary combat no target.
    -- forbiddenaggrotags is an ipairs table that holds tag strings as values in it to avoid targeting.
    self.shouldaggrofn = nil
    self.shouldavoidaggro = nil
    self.forbiddenaggrotags = nil
	self.lastwasattackedbytargettime = 0
	--self.lastattacker = nil
	--self.lastattacktype = nil
	--self.laststimuli = nil

    --self.tough = false
	--self.workmultiplierfn = nil
	--self.shouldrecoilfn = nil

	self.externaldamagemultipliers = SourceModifierList(self.inst) -- damage dealt to others multiplier
	self.externaldamagetakenmultipliers = SourceModifierList(self.inst) -- my damage taken multiplier (post armour reduction)
    -- self.conditionexternaldamagetakenmultipliers = {} -- extra damage taken on certain conditions (post armour reduction)

    self.min_attack_period = 4
    self.onhitfn = nil
    self.onhitotherfn = nil
    self.laststartattacktime = 0
    self.lastwasattackedtime = 0
    self.keeptargetfn = nil
    self.keeptargettimeout = 0
    self.hiteffectsymbol = "marker"
    self.canattack = true
    self.lasttargetGUID = nil
    self.target = nil
    self.panic_thresh = nil
    self.forcefacing = true
    self.bonusdamagefn = nil
    --self.playerstunlock = PLAYERSTUNLOCK.ALWAYS --nil for default

	self.losetargetcallback = function() self:DropTarget() end
	self.transfertargetcallback = function(target, newtarget)
		if newtarget ~= nil and self:CanTarget(newtarget) then
			self:SetTarget(newtarget)
			if self.target == target and self.target ~= newtarget then
				self:DropTarget()
			end
		else
			self:DropTarget()
		end
	end
	self.allycheckcallback = function(target)
		if self:CanBeAlly(target) then
			self:DropTarget()
		end
	end

	inst:ListenForEvent("knockback", CommonHandlers.ResetHitRecoveryDelay)
end,
nil,
{
    attackrange = onattackrange,
    min_attack_period = onminattackperiod,
    canattack = oncanattack,
    target = ontarget,
    panic_thresh = onpanicthresh,
})

local AREA_EXCLUDE_TAGS = { "INLIMBO", "notarget", "noattack", "flight", "invisible", "playerghost" }
-- 攻击时统一排除的标签。注意语义是「白名单式排除」而非「黑名单式许可」：
-- 只要带其中任一标签就一定打不到。仿写时建议反过来用黑名单，扩展新实体更省事。
--   INLIMBO     —— 正在加载/卸载，加载中的实体不可交互
--   notarget    —— 显式声明「不可被索敌」
--   noattack    —— 可被索敌但不可攻击（如某些中立单位）
--   flight      —— 飞行单位，地面单位够不着
--   invisible   —— 隐身
--   playerghost —— 幽灵形态的玩家

function Combat:SetLastTarget(target)
    self.lasttargetGUID = target ~= nil and target:IsValid() and target.GUID or nil
    self.inst.replica.combat:SetLastTarget(target ~= nil and target:IsValid() and target or nil)
end

function Combat:SetAttackPeriod(period)
-- 设置攻击间隔。冷却是「两次攻击之间的最小间隔」，用时间而非帧数表达。
-- ⚠️ 注意与 DoPeriodicTask 的区别：这里只是打点标记，真正的时间推进由
-- scheduler 驱动，且回调里不应 yield（见 bug-patterns A1）。
    self.min_attack_period = period
end

function Combat:TargetIs(target)
    return target ~= nil and self.target == target
end

function Combat:InCooldown()
-- 是否处于攻击冷却中。返回的是「剩余冷却是否为 0」而非时间戳。
    return self.laststartattacktime ~= nil and self.laststartattacktime + self.min_attack_period > GetTime()
end

function Combat:GetCooldown()
    return self.laststartattacktime ~= nil and math.max(0, self.min_attack_period - GetTime() + self.laststartattacktime) or 0
end

function Combat:ResetCooldown()
    self.laststartattacktime = nil
end

function Combat:RestartCooldown()
    self.laststartattacktime = GetTime()
end

function Combat:OverrideCooldown(cd)
-- 强制覆盖冷却。⚠️ 这是模组最常滥用的接口之一：
-- 若被用来做「攻速翻倍」，实际是直接把冷却清零，等于绕过了攻速上限的设计约束。
	self.laststartattacktime = GetTime() - self.min_attack_period + cd
end

function Combat:SetRange(attack, hit)
-- 同时设置「索敌距离」与「命中距离」。这两个是不同的量：
--   attackrange —— 进入这个距离才开始索敌/追击
--   hitrange    —— 挥出攻击时判定命中的距离，通常略小于 attackrange
-- 留出差距是为了避免「刚进入索敌范围就能立刻打到」，否则 AI 会显得过于精准。
    self.attackrange = attack
    self.hitrange = (hit or self.attackrange)
end

function Combat:SetHitArc(arc)
-- 设置命中扇形弧的角度（度）。nil 表示 360° 全向，攻击不需要瞄准。
-- 这是 2D 平面上的角度判定，见 CanHitTarget 的实现。
	self.hitarc = arc
end

function Combat:SetPlayerStunlock(stunlock)
    self.playerstunlock = stunlock
end

function Combat:SetAreaDamage(range, percent, areahitcheck)
-- 范围伤害：range=半径，percent=伤害比例，areahitcheck=是否要过命中判定。
-- ⚠️ areahitcheck 为 false 时会跳过 CanHitTarget 里的距离与扇形检查，
-- 直接对范围内所有目标生效——这是很多「范围技能打不到背后目标」类Bug 的来源。
    self.areahitrange = range
	self.areahitcheck = areahitcheck
    if self.areahitrange then
        self.areahitdamagepercent = percent or 1
    else
        self.areahitdamagepercent = nil
    end
end

function Combat:EnableAreaDamage(enable)
    self.areahitdisabled = enable == false
end

local function OnBlankOutOver(inst, self)
    self.blanktask = nil
    self.canattack = true
end

function Combat:BlankOutAttacks(fortime)
    self.canattack = false

    if self.blanktask ~= nil then
        self.blanktask:Cancel()
    end
    self.blanktask = self.inst:DoTaskInTime(fortime, OnBlankOutOver, self)
end

local DEFAULT_SHARE_TARGET_MUST_TAGS = { "_combat" }
function Combat:ShareTarget(target, range, fn, maxnum, musttags)
-- 让附近同伴共享自己的目标，实现群体围攻。
-- ⚠️ musttags 用的是「必须同时具备全部标签」的语义（AND），不是「任一」（OR）。
-- 误写成 OR 会让攻击范围意外扩大，这是很容易中招的语义陷阱。
    --NOTE: true param ignores my own forbidden tags when sharing someone else's aggro
    if not self:ShouldAggro(target, true) then
        return
    end
    if maxnum <= 0 then
        return
    end

    --print("Combat:ShareTarget", self.inst, target)

    local x, y, z = self.inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, SpringCombatMod(range), musttags or DEFAULT_SHARE_TARGET_MUST_TAGS)

    local num_helpers = 0
    for i, v in ipairs(ents) do
        if v ~= self.inst
            and not (v.components.health ~= nil and
                    v.components.health:IsDead())
            and (fn == nil or fn(v, self.inst))
            and v.components.combat:SuggestTarget(target) then

            --print("    share with", v)
            num_helpers = num_helpers + 1

            if num_helpers >= maxnum then
                return
            end
        end
    end
end

function Combat:SetDefaultDamage(damage)
    self.defaultdamage = damage
end

function Combat:SetOnHit(fn)
    self.onhitfn = fn
end

function Combat:SetCanSuggestTargetFn(fn)
    self.cansuggesttargetfn = fn
end

function Combat:SuggestTarget(target)
    if self.target == nil and target ~= nil and (self.cansuggesttargetfn == nil or self.cansuggesttargetfn(self.inst, target)) then
        --print("Combat:SuggestTarget", self.inst, target)
        self:SetTarget(target)
        return true
    end
end

function Combat:SetKeepTargetFunction(fn)
    self.keeptargetfn = fn
end

local function dotryretarget(inst, self)
-- 重新索敌的触发器。周期性地在候选目标里挑一个更合适的，
-- 避免AI 死盯一个已经不值得打的目标（例如逃跑的玩家）。
    self:TryRetarget()
end

function Combat:TryRetarget()
-- ★ TryRetarget 的策略：
--   1) 手里没有目标 → 走 shouldaggro 逻辑找一个
--   2) 有目标但已不可攻击（跑了/死了/无敌）→ 放弃
--   3) 有目标且仍可攻击 → 视 setretargetfunction 的配置决定是否换人
-- 关键设计：换目标有「切换冷却」，否则 AI 会在两个目标间反复横跳（抖动）。
    if self.targetfn ~= nil
        and not (self.inst.components.health ~= nil and
                self.inst.components.health:IsDead())
        and not (self.inst.components.sleeper ~= nil and
                self.inst.components.sleeper:IsInDeepSleep()) then

        local newtarget, forcechange = self.targetfn(self.inst)
        if newtarget ~= nil and newtarget ~= self.target and not newtarget:HasTag("notarget") then

            if forcechange then
                self:SetTarget(newtarget)
			    self.lastwasattackedbytargettime = GetTime()
            elseif self.target ~= nil and self.target:HasTag("structure") and not newtarget:HasTag("structure") then
                self:SetTarget(newtarget)
			    self.lastwasattackedbytargettime = GetTime()
            else
                if self:SuggestTarget(newtarget) then
					self.lastwasattackedbytargettime = GetTime()
				end
            end
        end
    end
end

function Combat:SetRetargetFunction(period, fn)
-- 注册重新索敌的周期任务。
-- ⚠️ 这里用的是 DoPeriodicTask，回调 dotryretarget 若间接 yield 会导致周期漂移
-- （见 bug-patterns A1 / N16）。dotryretarget 内部应保持非挂起。
    self.targetfn = fn
    self.retargetperiod = period

    if self.retargettask ~= nil then
        self.retargettask:Cancel()
        self.retargettask = nil
    end

	if period and fn and not self.inst:IsAsleep() then
        self.retargettask = self.inst:DoPeriodicTask(period, dotryretarget, period*math.random(), self)
    end
end

function Combat:OnEntitySleep()
-- 实体休眠时务必取消周期任务。反过来OnEntityWake 还要重建——
-- 这是「休眠机制」能真正省CPU 的关键：几百只怪物时，不取消就是几百个周期任务空转
-- （对应 bug-patterns F2 / F4 的性能命门）。
    if self.retargettask ~= nil then
        self.retargettask:Cancel()
        self.retargettask = nil
    end
end

function Combat:OnEntityWake()
-- 唤醒时重建索敌任务。
-- ⚠️ 第 303 行的第4 个参数是随机相位偏移（retargetperiod * random()）：
-- 让所有实体错开触发时刻，避免同一帧全部重算（帧尖峰）。这是很值得学的手法。
-- 代价是「第一个周期的实际间隔不再是整数倍」，属于有意为之的取舍。
    if self.retargettask ~= nil then
        self.retargettask:Cancel()
        self.retargettask = nil
    end

    if self.retargetperiod ~= nil then
        self.retargettask = self.inst:DoPeriodicTask(self.retargetperiod, dotryretarget, self.retargetperiod*math.random(), self)
    end

    if self.target ~= nil and self.keeptargetfn ~= nil then
        self.inst:StartUpdatingComponent(self)
    end
end

function Combat:OnUpdate(dt)
-- OnUpdate：维持目标的有效性。
-- ★ 性能要点：一旦 target 为 nil 就立刻 StopUpdatingComponent，
--   把「每帧检查」的开销降到零。没有目标就没有理由每帧跑。
-- 这与 bug-patterns F3（状态图永不休眠）是同一类问题的不同层面。
    if self.target == nil then
        self.inst:StopUpdatingComponent(self)
        return
    end

    if self.keeptargetfn ~= nil then
-- keeptargetfn：自定义的「是否继续追这个目标」判定（如血量阈值、距离上限）。
-- 计时器每秒（而非每帧）才评估一次，见第 324 行 keeptargettimeout = 1。
-- 同样是「把高频判断降频」的手法。
        self.keeptargettimeout = self.keeptargettimeout - dt
        if self.keeptargettimeout < 0 then
            if self.inst:IsAsleep() then
                self.inst:StopUpdatingComponent(self)
                return
            end
            self.keeptargettimeout = 1

			local drop
			if not self.target:IsValid() or self.target:IsInLimbo() then
				drop = true
			else
				local iframeskeepaggro_combat = self.target.sg and self.target.sg:HasStateTag("iframeskeepaggro") and self.inst.replica.combat or nil --V2C: intentionally using replica on server
-- ⚠️ 第 330 行是一个真实的坑，注释里明确写了 "intentionally using replica on server"：
--   在服务端故意读客户端 replica 来决定是否保持仇恨。
--   正常 netvar 规则是「服务端写、客户端读」，这里反向使用，
--   意味着两端都要对该字段达成一致，否则 AI 行为会在客户端/服务端不一致。
--   仿写时务必理解清楚，否则会踩到「客户端显示追着、实际没追」的 bug。
				if iframeskeepaggro_combat then
					iframeskeepaggro_combat.temp_iframes_keep_aggro = true
				end
				drop = not (self.target.components.combat and self.keeptargetfn(self.inst, self.target) and self.target.components.combat:CanBeAttacked(self.inst))
				if iframeskeepaggro_combat then
					iframeskeepaggro_combat.temp_iframes_keep_aggro = nil
				end
			end

			if drop then
                self.inst:PushEvent("losttarget")
                self:DropTarget()
            end
        end
    end
end

function Combat:IsRecentTarget(target)
    return target ~= nil and (target == self.target or target.GUID == self.lasttargetGUID)
end

function Combat:StartTrackingTarget(target)
    if target then
        self.inst:ListenForEvent("enterlimbo", self.losetargetcallback, target)
        self.inst:ListenForEvent("onremove", self.losetargetcallback, target)
		self.inst:ListenForEvent("transfercombattarget", self.transfertargetcallback, target)
		self.inst:ListenForEvent("leaderchanged", self.allycheckcallback, target)
    end
end

function Combat:StopTrackingTarget(target)
	self.inst:RemoveEventCallback("leaderchanged", self.allycheckcallback, target)
	self.inst:RemoveEventCallback("transfercombattarget", self.transfertargetcallback, target)
    self.inst:RemoveEventCallback("enterlimbo", self.losetargetcallback, target)
    self.inst:RemoveEventCallback("onremove", self.losetargetcallback, target)
end

function Combat:DropTarget(hasnexttarget)
    if self.target then
        self:SetLastTarget(self.target)
        self:StopTrackingTarget(self.target)
        self.inst:StopUpdatingComponent(self)
        local oldtarget = self.target
        self.target = nil
        if not hasnexttarget then
            self.inst:PushEvent("droppedtarget", {target=oldtarget})
        end
		self.lastwasattackedbytargettime = 0
    end
end

--V2C: [oldtarget] and [hasnexttarget](above) are really internal use flags.
--     [oldtarget] is NOT an override, hence not "oldtarget or self.target".
--     We really should assert that they don't mismatch, but no need because [oldtarget]
--     was added very late, and should not be passed in externally (now or in the past).
function Combat:EngageTarget(target, oldtarget)
    if target then
		oldtarget = self.target or oldtarget
        self.target = target
        self.inst:PushEvent("newcombattarget", {target=target, oldtarget=oldtarget})
        self:StartTrackingTarget(target)
        if self.keeptargetfn then
            self.inst:StartUpdatingComponent(self)
        end
        local leader = self.inst.components.follower and self.inst.components.follower:GetLeader()
        if leader and leader == target and leader.components.leader and not self.inst.components.follower.keepleaderonattacked then
            leader.components.leader:RemoveFollower(self.inst)
        end
    end
end

function Combat:SetShouldAggroFn(fn)
    self.shouldaggrofn = fn
end

function Combat:SetShouldAvoidAggro(target)
    self.shouldavoidaggro = self.shouldavoidaggro or {}
    self.shouldavoidaggro[target] = (self.shouldavoidaggro[target] or 0) + 1
end

function Combat:RemoveShouldAvoidAggro(target)
    if self.shouldavoidaggro == nil then
        return
    end
    self.shouldavoidaggro[target] = (self.shouldavoidaggro[target] or 1) - 1
    if self.shouldavoidaggro[target] == 0 then
        self.shouldavoidaggro[target] = nil
    end
    if next(self.shouldavoidaggro) == nil then
        self.shouldavoidaggro = nil
    end
end

function Combat:ShouldAggro(target, ignore_forbidden)
-- ShouldAggro：能否把 target 列为攻击对象。
-- ⚠️ 这是「权限校验」与「业务校验」分离的典型：
--   位置校验（目标是否可达、是否在范围内）
--   合法性校验（tag 是否允许、是否为友方、是否已 dead）
-- 两者混在一起写就会出现「位置对但逻辑上不该打」的漏洞（对应 bug-patterns N6）。
    if target ~= nil and
        (self.shouldaggrofn == nil or self.shouldaggrofn(self.inst, target)) and
        (self.shouldavoidaggro == nil or not self.shouldavoidaggro[target]) and
        (target.components.combat == nil or target.components.combat.shouldavoidaggrofn == nil or target.components.combat.shouldavoidaggrofn(self.inst, target))
        then
        if not ignore_forbidden and self.forbiddenaggrotags ~= nil then
            for _, tag in ipairs(self.forbiddenaggrotags) do
                if target:HasTag(tag) then
                    return false
                end
            end
        end
		if target:HasTag("stealth") then
			return false
		end
		if target.components.health ~= nil and (target.components.health.minhealth or 0) > 0 and not target:HasTag("hostile") then
			target = target.components.follower ~= nil and target.components.follower:GetLeader() or target
			if not target.isplayer then
				--npc should not aggro on things that can't be killed (unless hostile!)
				return false
			end
		end
        return true
    end
    return false
end

function Combat:AddNoAggroTag(tag)
-- 无仇恨标签的增删。tag 机制让「不可攻击」变成数据驱动而非硬编码 if。
-- 仿写建议：新增实体时优先用 tag 表达规则，而不是在 ShouldAggro 里加实体名判断。
    self.forbiddenaggrotags = self.forbiddenaggrotags or {}
    table.insert(self.forbiddenaggrotags, tag)
end

function Combat:RemoveNoAggroTag(tag)
    if self.forbiddenaggrotags == nil then
        return
    end
    table.removearrayvalue(self.forbiddenaggrotags, tag)
    if self.forbiddenaggrotags[1] == nil then
        self.forbiddenaggrotags = nil
    end
end

function Combat:SetNoAggroTags(tags) -- Wants a table in an ipairs table format.
    self.forbiddenaggrotags = tags
end

function Combat:SetTarget(target)
    if target ~= self.target and
        (target == nil or (self:IsValidTarget(target) and self:ShouldAggro(target))) and
		not (target and target.isplayer and target.sg and target.sg:HasStateTag("hiding"))
	then
		local oldtarget = self.target
        self:DropTarget(target ~= nil)
		self:EngageTarget(target, oldtarget)
    end
end

function Combat:IsValidTarget(target)
    return self.inst.replica.combat:IsValidTarget(target)
end

function Combat:ValidateTarget()
    if self.target then
        if self:IsValidTarget(self.target) then
            return true
        else
            self:DropTarget()
        end
    end
end

function Combat:GetDebugString()
    local str = string.format("target:%s, damage:%d", tostring(self.target), self.defaultdamage or 0 )
    if self.target then
        local dist = math.sqrt(self.inst:GetDistanceSqToInst(self.target)) or 0
        local atkrange = math.sqrt(self:CalcAttackRangeSq()) or 0
        str = str .. string.format(" dist/range: %2.2f/%2.2f", dist, atkrange)
        if self:InCooldown() then
            str = str .. " IN COOLDOWN"
        end
    end
    if self.targetfn and self.retargetperiod then
        str = str.. " Retarget set"
    end
    str = str..string.format(", can attack:%s", tostring(self:CanAttack(self.target)))
    str = str..string.format(", can be attacked: %s", tostring(self:CanBeAttacked()))

    return str
end

function Combat:GetGiveUpString(target)
    return nil
end

function Combat:GiveUp()
-- GiveUp：放弃当前目标。
-- 关键：要同时清空「仇恨来源」，否则会出现 A 打 B、B 打 A 的互相吸引死循环。
    if self.inst.components.talker ~= nil then
        local str, strid = self:GetGiveUpString(self.target)
        if str ~= nil then
            if strid ~= nil then
                self.inst.components.talker:Chatter(str, strid)
            else
                self.inst.components.talker:Say(str)
            end
        end
    end

    self.inst:PushEvent("giveuptarget", { target = self.target })
    self:DropTarget()
end

function Combat:GetBattleCryString(target)
    return nil
end

function Combat:ResetBattleCryCooldown(t)
    self.nextbattlecrytime = (t or GetTime()) + (self.battlecryinterval or 5) + math.random() * 3
end

function Combat:BattleCry()
    if self.battlecryenabled then
        local t = GetTime()
        if self.nextbattlecrytime == nil or t > self.nextbattlecrytime then
            self:ResetBattleCryCooldown(t)
            if self.inst.components.talker ~= nil then
                local cry, strid, echotochatpriority = self:GetBattleCryString(self.target)
                if cry ~= nil then
                    if strid ~= nil then
                        self.inst.components.talker:Chatter(cry, strid, 2, nil, echotochatpriority)
                    else
                        self.inst.components.talker:Say(cry, 2)
                    end
                end
            elseif self.inst.sg.sg.states.taunt and not self.inst.sg:HasStateTag("busy") then
                self.inst.sg:GoToState("taunt")
            end
        end
    end
end

function Combat:SetHurtSound(sound)
    self.hurtsound = sound
end

function Combat:GetAttacked(attacker, damage, weapon, stimuli, spdamage)
    if self.inst.components.health and self.inst.components.health:IsDead() then
        return true
    end
    self.lastwasattackedtime = GetTime()

    --print ("ATTACKED", self.inst, attacker, damage)
    --V2C: redirectdamagefn is currently only used by either mounting or parrying,
    --     but not both at the same time.  If we use it more, then it really needs
    --     to be refactored.
    local blocked = false
    local damageredirecttarget = self.redirectdamagefn ~= nil and self.redirectdamagefn(self.inst, attacker, damage, weapon, stimuli, spdamage) or nil
    local damageresolved = 0
	local original_damage = damage

    self.lastattacker = attacker

	--can add more attacktypes as needed
	--currently just "projectile" or nil, used for hit stun calculation
	if (damage or 0) > 0 and
		weapon and
		(	weapon.components.projectile or
			(weapon.components.weapon and weapon.components.weapon.projectile)
		)
	then
		self.lastattacktype = "projectile"
	else
		self.lastattacktype = nil
	end
	self.laststimuli = stimuli

    local recoil
    recoil, damage = self:ShouldRecoil(attacker, weapon, damage)

    if recoil then
        blocked = true
    end

    if self.inst.components.health ~= nil and damage ~= nil and damageredirecttarget == nil then
        if self.inst.components.attackdodger ~= nil and self.inst.components.attackdodger:CanDodge(attacker) then
            self.inst.components.attackdodger:Dodge(attacker)
            damage, spdamage = 0, nil
        end

		if self.inst.components.inventory and not self.inst.components.inventory.ignorecombat then
			if attacker ~= nil and attacker.components.planarentity ~= nil and not self.inst.components.inventory:EquipHasSpDefenseForType("planar") then
				attacker.components.planarentity:OnPlanarAttackUndefended(self.inst)
			end
			damage, spdamage = self.inst.components.inventory:ApplyDamage(damage, attacker, weapon, spdamage)
        end
		if self.inst.components.rideable ~= nil then
			local saddle = self.inst.components.rideable.saddle
			if saddle ~= nil then
                if saddle.components.saddler ~= nil then
                    damage, spdamage = saddle.components.saddler:ApplyDamage(damage, attacker, weapon, spdamage)
                end
			end
		end
        local damagetypemult = 1
		if self.inst.components.damagetyperesist ~= nil then
			damagetypemult = damagetypemult * self.inst.components.damagetyperesist:GetResist(attacker, weapon)
		end
        if self.conditionexternaldamagetakenmultipliers ~= nil then
            damage = damagetypemult * self:ApplyConditionExternalDamageTakenMultiplier(damage, attacker, weapon)
        end
		damage = damage * damagetypemult * self.externaldamagetakenmultipliers:Get()
		if (damage > 0 or spdamage ~= nil) and not self.inst.components.health:IsInvincible() then
			if damage > 0 then
				--Bonus damage only applies after unabsorbed damage gets through your armor
				if attacker ~= nil and attacker.components.combat ~= nil and attacker.components.combat.bonusdamagefn ~= nil then
					damage = damage + damagetypemult * (attacker.components.combat.bonusdamagefn(attacker, self.inst, damage, weapon) or 0)
				end
				--Planar entities dampen regular damage
				if self.inst.components.planarentity ~= nil then
					damage, spdamage = self.inst.components.planarentity:AbsorbDamage(damage, attacker, weapon, spdamage)
				end
            end
			--Special damage after bonus damage
			if spdamage ~= nil then
				spdamage = SpDamageUtil.ApplySpDefense(self.inst, spdamage)
				damage = damage + damagetypemult * SpDamageUtil.CalcTotalDamage(spdamage)
			end

            local cause = attacker == self.inst and weapon or attacker
            --V2C: guess we should try not to crash old mods that overwrote the health component
            damageresolved = self.inst.components.health:DoDelta(-damage, nil, cause ~= nil and (cause.nameoverride or cause.prefab) or "NIL", nil, cause)
            damageresolved = damageresolved ~= nil and -damageresolved or damage
            if self.inst.components.health:IsDead() then
                if attacker ~= nil then
                    attacker:PushEvent("killed", { victim = self.inst, attacker = attacker })
                end
                if self.onkilledbyother ~= nil then
                    self.onkilledbyother(self.inst, attacker)
                end
            end
        else
            blocked = true
        end
    end

    local redirect_combat = damageredirecttarget ~= nil and damageredirecttarget.components.combat or nil
    if redirect_combat ~= nil then
        -- Small hack for centipede
        redirect_combat.redirected_from = self.inst
		redirect_combat:GetAttacked(attacker, damage, weapon, stimuli, spdamage)
        redirect_combat.redirected_from = nil
    end

    if self.inst.SoundEmitter ~= nil and not self.inst:IsInLimbo() then
        local hitsound = self:GetImpactSound(damageredirecttarget or self.inst, weapon)
        if hitsound ~= nil then
            self.inst.SoundEmitter:PlaySound(hitsound)
        end
        if damageredirecttarget ~= nil then
            if redirect_combat ~= nil and redirect_combat.hurtsound ~= nil then
                self.inst.SoundEmitter:PlaySound(redirect_combat.hurtsound)
            end
        elseif self.hurtsound ~= nil then
            self.inst.SoundEmitter:PlaySound(self.hurtsound)
        end
    end

    if not blocked then
		self.inst:PushEvent("attacked", { attacker = attacker, damage = damage, damageresolved = damageresolved, original_damage = original_damage, weapon = weapon, stimuli = stimuli, spdamage = spdamage, redirected = damageredirecttarget, noimpactsound = self.noimpactsound })

        if self.onhitfn ~= nil then
			self.onhitfn(self.inst, attacker, damage, spdamage)
        end

        if attacker ~= nil then
			attacker:PushEvent("onhitother", { target = self.inst, damage = damage, damageresolved = damageresolved, stimuli = stimuli, spdamage = spdamage, weapon = weapon, redirected = damageredirecttarget })
            if attacker.components.combat ~= nil and attacker.components.combat.onhitotherfn ~= nil then
				attacker.components.combat.onhitotherfn(attacker, self.inst, damage, stimuli, weapon, damageresolved, spdamage, damageredirecttarget)
            end
        end
    else
        -- We blocked it, but we might still want to know how much they rattled us in damage value!
        self.inst:PushEvent("blocked", { attacker = attacker, damage = damage, spdamage = spdamage, original_damage = original_damage })
    end

	if self.target == nil or self.target == attacker then
		self.lastwasattackedbytargettime = self.lastwasattackedtime
	end

    return not blocked
end

function Combat:GetImpactSound(target, weapon)
    if target == nil or self.noimpactsound then
        return
    end

    local weaponmod = weapon ~= nil and weapon:HasTag("sharp") and "sharp" or "dull"
    local tgtinv = target.components.inventory
    if tgtinv ~= nil and tgtinv:IsWearingArmor() then
        local armor_impact_sound = GetArmorImpactSound(tgtinv, weaponmod)
        if armor_impact_sound ~= nil then
            return armor_impact_sound
        end
	end

	if target:HasTag("wall") then
        return GetWallImpactSound(target, weaponmod)
    elseif target:HasTag("object") then
        return GetObjectImpactSound(target, weaponmod)
    else
        return GetCreatureImpactSound(target, weaponmod)
    end
end

function Combat:StartAttack()
    if self.forcefacing and self.target ~= nil and self.target:IsValid() then
        self.inst:ForceFacePoint(self.target:GetPosition())
    end
	self:RestartCooldown()
end

Combat.CancelAttack = Combat.ResetCooldown

function Combat:CanTarget(target)
    return self.inst.replica.combat:CanTarget(target)
end

function Combat:HasTarget()
    return self.target ~= nil
end

function Combat:CanAttack(target)
    if not self:IsValidTarget(target) then
        return false, true
    end

    return self.canattack
        and not self:InCooldown()
        and (   self.inst.sg == nil or
                not self.inst.sg:HasStateTag("busy") or
                self.inst.sg:HasStateTag("hit")
            )
        and (   -- V2C: this is 3D distsq
                self.ignorehitrange or
                distsq(target:GetPosition(), self.inst:GetPosition()) <= self:CalcAttackRangeSq(target)
            )
end

function Combat:LocomotorCanAttack(reached_dest, target)
    if not self:IsValidTarget(target) then
        return false, true, false
    end

	local attackrangesq = self:CalcAttackRangeSq(target)

    reached_dest = reached_dest or
		(self.ignorehitrange or distsq(target:GetPosition(), self.inst:GetPosition()) <= attackrangesq)

    local valid = self.canattack
        and (   self.inst.sg == nil or
                not self.inst.sg:HasStateTag("busy") or
                self.inst.sg:HasStateTag("hit")
            )

	if attackrangesq > 4 and self.inst.isplayer then
        local weapon = self:GetWeapon()
		local is_ranged_weapon = weapon ~= nil and weapon:HasAnyTag("projectile", "rangedweapon")

        if not is_ranged_weapon then
            local currentpos = self.inst:GetPosition()
            local voidtest = currentpos + ((target:GetPosition() - currentpos):Normalize() * (self:GetAttackRange() / 2))
            if TheWorld.Map:IsNotValidGroundAtPoint(voidtest:Get()) and not TheWorld.Map:IsNotValidGroundAtPoint(target.Transform:GetWorldPosition()) then
                reached_dest = false
            end
        end
    end

    return reached_dest, not valid, self:InCooldown()
end

function Combat:TryAttack(target)
    local target = target or self.target

    local is_attacking = self.inst.sg:HasStateTag("attack")
    if is_attacking then
        return true
    end

    if self:CanAttack(target) then
        self.inst:PushEvent("doattack", {target = target})
        return true
    end

    return false
end

function Combat:ForceAttack()
    if self.target and self:TryAttack() then
        return true
    else
        self.inst:PushEvent("doattack")
    end
end

function Combat:GetWeapon()
    if self.inst.components.inventory ~= nil then
        local item = self.inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
        return item ~= nil
            and item.components.weapon ~= nil
            and (item.components.projectile ~= nil or
                not (self.inst.components.rider ~= nil and
                    self.inst.components.rider:IsRiding()) or
                item:HasTag("rangedweapon"))
            and item
            or nil
    end
end

function Combat:GetLastAttackedTime()
    return self.lastwasattackedtime
end

function Combat:CalcDamage(target, weapon, multiplier)
-- ★★★ CalcDamage —— 伤害聚合公式，DST 伤害系统的单一事实来源。
--
-- 【返回值】damage（普通伤害）, spdamage（护盾/穿刺伤害，走独立通道）
--
-- 【最终公式（第 913-921 行）】
--   damage = basedamage
--          * basemultiplier            -- 攻击者全局倍率
--          * externaldamagemultipliers -- 攻击者身上的「外部伤害修正袋」
--          * damagetypemult            -- 对特定伤害类型的加成/减益
--          * multiplier                -- 本次调用的额外倍率（默认 1）
--          * playermultiplier          -- 攻击玩家时的修正
--          * pvpmultiplier             -- 玩家对战修正
--          * customdamagemultfn(...)   -- 自定义钩子（模组扩展点）
--          + bonus                     -- ⚠️ 加法，且不参与任何乘区
--
-- 【为什么这个结构值得抄】
--  · 各修正器彼此正交、顺序无关，新增一种修正只需插一项，不用改已有逻辑
--  · 全部写成乘法 → 天然可叠加、可组合，调试时能逐项拆解
--  · bonus 单独走加法 → 明确区分「放大伤害」与「固定加值」两种语义
--  · customdamagemultfn 作为最后的扩展点 → 模组无需改源码即可改伤害
--
-- 【三个必须注意的细节】
--  a) 第 847 行 alwaysblock 标签：命中前直接返回 0，是最高优先级的免疫。
--  b) 第 867 行：有武器时 playermultiplier 被强制置 1。
--     也就是说「对玩家伤害修正」只在徒手攻击生效——这是有意的平衡设计，
--     但极易被误读为bug。注释里也写了 "No playermultiplier when using weapons"。
--  c) 第 879-904 行：骑乘时整套参数改从坐骑（含鞍）读取，
--     攻击者的属性被完全覆盖。鞍的 damagetypemult 是「相乘」进主乘区（第 901 行），
--     而坐骑的 bonus 是「相加」（第 899 行）——同一件装备的两类修正走了不同通道。
    if target:HasTag("alwaysblock") then
        return 0
    end

    local basedamage
    local basemultiplier = self.damagemultiplier
-- ★ 修正器的读取顺序暗示了「优先级」概念：
--   越靠前读到的越接近「攻击者的固有属性」，越靠后越是「本次攻击的临时修正」。
--   但因为全部是乘法，实际结果与顺序无关（浮点误差除外）。
    local externaldamagemultipliers = self.externaldamagemultipliers
	local damagetypemult = 1
    local bonus = self.damagebonus --not affected by multipliers
-- bonus 不受乘区影响（第 921 行是独立的加法）。
-- 典型用途：固定伤害追加（如灼烧、点火的每 tick 伤害）。
	local playermultiplier = CanApplyPlayerDamageMod(target)
	local pvpmultiplier = playermultiplier and self.inst.isplayer and self.pvp_damagemod or 1
	local mount = nil
	local spdamage

    --NOTE: playermultiplier is for damage towards players
    --      generally only applies for NPCs attacking players

    if weapon ~= nil then
-- 有武器分支：武器伤害取代默认伤害，且吞掉 playermultiplier。
        --No playermultiplier when using weapons
		basedamage, spdamage = weapon.components.weapon:GetDamage(self.inst, target)
        playermultiplier = 1
		--#V2C: entity's own damagetypebonus stacks with weapon's damagetypebonus
		if self.inst.components.damagetypebonus ~= nil then
			damagetypemult = self.inst.components.damagetypebonus:GetBonus(target)
		end

        --#DiogoW: entity's own SpDamage stacks with weapon's SpDamage
        spdamage = SpDamageUtil.CollectSpDamage(self.inst, spdamage)
    else
        basedamage = self.defaultdamage
        playermultiplier = playermultiplier and self.playerdamagepercent or 1

        if self.inst.components.rider ~= nil and self.inst.components.rider:IsRiding() then
-- 骑乘分支：无武器时若骑着坐骑，整套伤害参数改从坐骑取。
-- ⚠️ 注意这里 basemultiplier / externaldamagemultipliers / bonus 三项都被覆盖，
--   而第 920 行的 customdamagemultfn 仍然作用于self.inst（骑乘者）而非坐骑。
--   同一函数里作用对象发生切换，是这块最容易出错的点。
            mount = self.inst.components.rider:GetMount()
            if mount ~= nil and mount.components.combat ~= nil then
                basedamage = mount.components.combat.defaultdamage
                basemultiplier = mount.components.combat.damagemultiplier
                externaldamagemultipliers = mount.components.combat.externaldamagemultipliers
                bonus = mount.components.combat.damagebonus
				if mount.components.damagetypebonus ~= nil then
					damagetypemult = mount.components.damagetypebonus:GetBonus(target)
				end
				spdamage = SpDamageUtil.CollectSpDamage(mount, spdamage)
			else
				if self.inst.components.damagetypebonus ~= nil then
					damagetypemult = self.inst.components.damagetypebonus:GetBonus(target)
				end
				spdamage = SpDamageUtil.CollectSpDamage(self.inst, spdamage)
            end

            local saddle = self.inst.components.rider:GetSaddle()
            if saddle ~= nil and saddle.components.saddler ~= nil then
                basedamage = basedamage + saddle.components.saddler:GetBonusDamage()
				if saddle.components.damagetypebonus ~= nil then
					damagetypemult = damagetypemult * saddle.components.damagetypebonus:GetBonus(target)
				end
				spdamage = SpDamageUtil.CollectSpDamage(saddle, spdamage)
            end
		else
			if self.inst.components.damagetypebonus ~= nil then
				damagetypemult = self.inst.components.damagetypebonus:GetBonus(target)
			end
			spdamage = SpDamageUtil.CollectSpDamage(self.inst, spdamage)
        end
    end

	local damage = (basedamage or 0)
-- ★ 八项相乘 + 一项相加。每一项都做了 (x or 1) 兜底，
--   避免某个修正袋为空时整条链变成 nil。
-- 仿写提醒：Lua 里一旦某项算出 nil，整个表达式就静默变 nil，
--   不会报错但伤害会变成 nil 并在下游炸掉——这里的 or 兜底是必要防御。
        * (basemultiplier or 1)
        * externaldamagemultipliers:Get()
		* damagetypemult
        * (multiplier or 1)
        * playermultiplier
        * pvpmultiplier
		* (self.customdamagemultfn ~= nil and self.customdamagemultfn(self.inst, target, weapon, multiplier, mount) or 1)
        + (bonus or 0)

	if spdamage ~= nil then
-- spdamage（护盾/穿刺伤害）走独立通道，乘区比普通伤害少：
-- 不吃 playermultiplier（注释写明是为了避免调参噩梦）。
-- ⚠️ 这意味着 spdamage 与 damage 的倍率集合不一致，
--   调「攻击力」时需要同时考虑两条通道，否则会出现一种伤害涨了另一种没涨。
		local spmult =
			damagetypemult *
			--playermultiplier * --@V2C excluded to avoid tuning nightmare
			pvpmultiplier

        if self.customspdamagemultfn then
            spmult = spmult * (self.customspdamagemultfn(self.inst, target, weapon, multiplier, mount) or 1)
        end

		if spmult ~= 1 then
			spdamage = SpDamageUtil.ApplyMult(spdamage, spmult)
		end

	end
	return damage, spdamage
end

local function _CalcReflectedDamage(inst, attacker, dmg, weapon, stimuli, reflect_list, spdmg)
    if inst == nil then
        return 0
    end

	local reflected_dmg = 0
	local reflected_spdmg

    if inst.components.damagereflect ~= nil then
		local dmg1, spdmg1 = inst.components.damagereflect:GetReflectedDamage(attacker, dmg, weapon, stimuli, spdmg)
        if dmg1 > 0 or spdmg1 ~= nil then
			reflected_dmg = reflected_dmg + dmg1
			reflected_spdmg = SpDamageUtil.MergeSpDamage(reflected_spdmg, spdmg1)
			table.insert(reflect_list, { inst = inst, attacker = attacker, reflected_dmg = dmg1, reflected_spdmg = spdmg1 })
        end
    end

    if inst.components.inventory ~= nil then
        for k, v in pairs(EQUIPSLOTS) do
            local equip = inst.components.inventory:GetEquippedItem(v)
            if equip ~= nil and equip.components.damagereflect ~= nil then
				local dmg1, spdmg1 = equip.components.damagereflect:GetReflectedDamage(attacker, dmg, weapon, stimuli, spdmg)
				if dmg1 > 0 or spdmg1 ~= nil then
					reflected_dmg = reflected_dmg + dmg1
					reflected_spdmg = SpDamageUtil.MergeSpDamage(reflected_spdmg, spdmg1)
					table.insert(reflect_list, { inst = equip, attacker = attacker, reflected_dmg = dmg1, reflected_spdmg = spdmg1 })
                end
            end
        end
    end

	return reflected_dmg, reflected_spdmg
end

function Combat:CalcReflectedDamage(targ, dmg, weapon, stimuli, reflect_list, spdmg)
    if self.ignoredamagereflect then
        return 0, nil
    end

	if targ.components.rider ~= nil and targ.components.rider:IsRiding() then
		local dmg1, spdmg1 = _CalcReflectedDamage(targ.components.rider:GetMount(), self.inst, dmg, weapon, stimuli, reflect_list, spdmg)
		local dmg2, spdmg2 = _CalcReflectedDamage(targ.components.rider:GetSaddle(), self.inst, dmg, weapon, stimuli, reflect_list, spdmg)
		return dmg1 + dmg2, SpDamageUtil.MergeSpDamage(spdmg1, spdmg2)
	end

	return _CalcReflectedDamage(targ, self.inst, dmg, weapon, stimuli, reflect_list, spdmg)
end

function Combat:GetAttackRange()
    local weapon = self:GetWeapon()
    return weapon ~= nil
        and weapon.components.weapon.attackrange ~= nil
        and math.max(0, self.attackrange + weapon.components.weapon.attackrange)
        or self.attackrange
end

function Combat:CalcAttackRangeSq(target)
    local range = (target or self.target):GetPhysicsRadius(0) + self:GetAttackRange()
    return range * range
end

function Combat:GetHitRange()
    local weapon = self:GetWeapon()
    return self.temprange or weapon ~= nil and weapon.components.weapon.hitrange ~= nil and self.hitrange + weapon.components.weapon.hitrange or self.hitrange
end

function Combat:CalcHitRangeSq(target)
    local range = (target or self.target):GetPhysicsRadius(0) + self:GetHitRange()
    return range * range
end

function Combat:CanExtinguishTarget(target, weapon)
	local burnable = target.components.burnable
    return burnable ~= nil
        and (burnable:IsSmoldering() or burnable:IsBurning())
        and (weapon ~= nil and weapon:HasTag("extinguisher") or self.inst:HasTag("extinguisher"))
end

function Combat:CanLightTarget(target, weapon)
    return weapon ~= nil
        and weapon:HasTag("rangedlighter")
        and target.components.burnable ~= nil
        and target.components.burnable.canlight
        and not target.components.burnable:IsBurning()
        and not target:HasTag("burnt")
        --[[and (target.components.fueled == nil or
            not target.components.fueled.accepting or
            target.components.fueled.fueltype == FUELTYPE.BURNABLE or
            target.components.fueled.secondaryfueltype == FUELTYPE.BURNABLE)]]
        --V2C: fueled or fueltype should not really matter. if we can burn it, should still allow lighting.
end

--@V2C: WARNING!  This doesn't match combat replica's version.  Why is this needed on clients anyway?
function Combat:CanHitTarget(target, weapon)
-- ★★★ CanHitTarget —— 命中判定的唯一权威。全文件最该精读的几何代码。
--
-- 【判定的四个层次，任何一层不通过就返回 false】
--  1) 前置有效性：self/target 非 nil、双方 IsValid、target 不在 limbo
--  2) 业务许可：能灭火 / 能点火 / 对方可被攻击（三者任一）
--  3) 距离：三维平方距离 <= 命中距离平方
--  4) 方向：若设了扇形弧，目标方位角与朝向的夹角 <= 弧的一半
--
-- 【三个容易抄错的点】
--  a) 第 1062 行用三维距离（含 y），而很多同类实现用水平距离。
--     DST 选择三维→ 高低差会影响命中。若你的游戏要「只算平面距离」，需显式改。
--  b) 第 1065 行的 (dx == 0 and dz == 0) 是退化保护：目标与自身重合时
--     atan2(0,0) 结果不可靠，直接判定命中。
--  c) 第 1083 行：投射物判定用的是「目标半径 + 投射物命中距离」，
--     且最后直接 return—— 即「近战判定失败后由投射物兜底」，不是二者取交集。
--
-- 【self.temppos】：DoAttack 可传入临时坐标（攻击发生时的瞬时位置），
-- 用于处理「攻击者此刻已移动」的场景，见第 1053 行。
    if self.inst ~= nil and
        self.inst:IsValid() and
        target ~= nil and
        target:IsValid() and
        not target:IsInLimbo() and
        (   self:CanExtinguishTarget(target, weapon) or
            self:CanLightTarget(target, weapon) or
            (   target.components.combat ~= nil and
                target.components.combat:CanBeAttacked(self.inst)
            )
        ) then

		if self.ignorehitrange then
			return true
		end

		local x1, y1, z1 = target.Transform:GetWorldPosition()
		local x, y, z
		if self.temppos then
			x, y, z = self.temppos:Get()
		else
			x, y, z = self.inst.Transform:GetWorldPosition()
		end

		local dx = x1 - x
-- 三维平方距离。用平方是为了避免开方，DST 全程避免 sqrt。
		local dy = y1 - y
		local dz = z1 - z
		local dsq3d = dx * dx + dy * dy + dz * dz

		if dsq3d <= self:CalcHitRangeSq(target) then
			if self.hitarc == nil or (dx == 0 and dz == 0) then
				return true
			end
			local rot = self.inst.Transform:GetRotation()
			local rot1 = math.atan2(-dz, dx) * RADIANS
-- 目标相对自身朝向的方位角。
-- ⚠️ math.atan2(-dz, dx)：两个分量都取了负，
--   因为 DST 的坐标系 y 轴朝向与常规 2D 数学约定相反。
--   抄这个公式时务必连同坐标系一起理解，否则弧形判定会左右镜像。
			if DiffAngle(rot, rot1) * 2 <= self.hitarc then
-- DiffAngle 取两角之差的绝对值（已处理 ±360° 环绕），
-- 乘 2 是因为 atan2 换算成角度时范围是 ±180°，而 hitarc 存的是整圆度数。
				return true
			end
		end

		--OOR, but check projectile as well
		if weapon and weapon.components.projectile then
			x, y, z = weapon.Transform:GetWorldPosition()
			dx = x1 - x
			dy = y1 - y
			dz = z1 - z
			dsq3d = dx * dx + dy * dy + dz * dz

            local range = target:GetPhysicsRadius(0) + weapon.components.projectile.hitdist
			return dsq3d <= range * range
		end
    end
    return false
end

function Combat:ClearAttackTemps()
    self.temppos = nil
    self.temprange = nil
end

function Combat:DoAttack(targ, weapon, projectile, stimuli, instancemult, instrangeoverride, instpos)
-- ★★★ DoAttack —— 真正执行攻击。
--
-- 【参数较多，用法上分组理解】
--   targ / weapon / projectile —— 目标与武器
--   stimuli                 —— 伤害刺激源（决定受击特效与音效）
--   instancemult            —— 本次攻击的临时倍率
--   instrangeoverride       —— 临时覆盖命中距离（配合 self.temprange）
--   instpos                 —— 临时攻击坐标（配合 self.temppos）
--
-- 【重要约定】后面三个 override 参数只影响「这一次」判定，
--   因此 ClearAttackTemps（第 1090 行）必须被调用来复位，
--   否则会污染后续所有攻击判定。这是典型的「临时状态需显式清理」陷阱。
    if instrangeoverride then
-- override 只写不还原——还原靠 ClearAttackTemps。
-- ⚠️ 任何提前 return 的分支若没有调用 ClearAttackTemps，temppos/temprange 就会残留，
--   导致后续攻击用到错误坐标。移植时务必检查所有 return 路径。
        self.temprange = instrangeoverride
    end
    if instpos then
        self.temppos = instpos
    end
    if targ == nil then
        targ = self.target
    end
    if weapon == nil then
        weapon = self:GetWeapon()
    end
    if stimuli == nil then
		if weapon and weapon.components.weapon then
			if weapon.components.weapon.overridestimulifn then
				stimuli = weapon.components.weapon.overridestimulifn(weapon, self.inst, targ)
			end
			if stimuli == nil and weapon.components.weapon.stimuli == "electric" then
				stimuli = "electric"
			end
        end
        if stimuli == nil and self.inst.components.electricattacks ~= nil then
            stimuli = "electric"
        end
    end

    if not self:CanHitTarget(targ, weapon) or self.AOEarc then
        self.inst:PushEvent("onmissother", { target = targ, weapon = weapon })
        if self.areahitrange ~= nil and not self.areahitdisabled then
            self:DoAreaAttack(projectile or self.inst, self.areahitrange, weapon, self.areahitcheck, stimuli, AREA_EXCLUDE_TAGS)
        end
        self:ClearAttackTemps()
        return
    end

    if targ.components.combat then
        local recoil, damage = targ.components.combat:ShouldRecoil(self.inst, weapon)
	    if recoil and self.inst.sg ~= nil and self.inst.sg.statemem.recoilstate ~= nil then
            self.inst:PushEventImmediate("recoil_off", { target = targ } )
	    	if damage == 0 or damage == nil then
	    		self.inst:PushEvent("weapontooweak")
	    	end
	    end
    end

    self.inst:PushEvent("onattackother", { target = targ, weapon = weapon, projectile = projectile, stimuli = stimuli })

    if weapon ~= nil and projectile == nil then
        if weapon.components.projectile ~= nil then
            local projectile = self.inst.components.inventory:DropItem(weapon, false)
            if projectile ~= nil then
                projectile.components.projectile:Throw(self.inst, targ)
            end
            self:ClearAttackTemps()
            return

        elseif weapon.components.complexprojectile ~= nil and not weapon.components.complexprojectile.ismeleeweapon then
            local projectile = self.inst.components.inventory:DropItem(weapon, false)
            if projectile ~= nil then
                projectile.components.complexprojectile:Launch(targ:GetPosition(), self.inst)
            end
            self:ClearAttackTemps()
            return

        elseif weapon.components.weapon:CanRangedAttack() then
            weapon.components.weapon:LaunchProjectile(self.inst, targ)
            self:ClearAttackTemps()
            return
        end
    end

    local reflected_dmg = 0
	local reflected_spdmg
    local reflect_list = {}
    if targ.components.combat ~= nil then
        local mult = 1

        local _weapon_cmp = weapon ~= nil and weapon.components.weapon or nil

        if  (
                stimuli == "electric" or
                (_weapon_cmp ~= nil and _weapon_cmp.stimuli == "electric")
            )
            and not IsEntityElectricImmune(targ)
        then
            local electric_damage_mult = _weapon_cmp ~= nil and _weapon_cmp.electric_damage_mult or TUNING.ELECTRIC_DAMAGE_MULT
            local electric_wet_damage_mult = _weapon_cmp ~= nil and _weapon_cmp.electric_wet_damage_mult or TUNING.ELECTRIC_WET_DAMAGE_MULT

            mult = electric_damage_mult + electric_wet_damage_mult * targ:GetWetMultiplier()
        end

		local dmg, spdmg = self:CalcDamage(targ, weapon, mult)
		dmg = dmg * (instancemult or 1)
        --Calculate reflect first, before GetAttacked destroys armor etc.
        if projectile == nil then
			reflected_dmg, reflected_spdmg = self:CalcReflectedDamage(targ, dmg, weapon, stimuli, reflect_list, spdmg)
        end
		targ.components.combat:GetAttacked(self.inst, dmg, weapon, stimuli, spdmg)
    elseif projectile == nil then
		reflected_dmg, reflected_spdmg = self:CalcReflectedDamage(targ, 0, weapon, stimuli, reflect_list)
    end

    if weapon ~= nil then
        weapon.components.weapon:OnAttack(self.inst, targ, projectile)
    end

    if self.areahitrange ~= nil and not self.areahitdisabled then
        self:DoAreaAttack(targ, self.areahitrange, weapon, self.areahitcheck, stimuli, AREA_EXCLUDE_TAGS)
    end
    self:ClearAttackTemps()
    self.lastdoattacktime = GetTime()

    --Apply reflected damage to self after our attack damage is completed
	if (reflected_dmg > 0 or reflected_spdmg ~= nil) and self.inst.components.health ~= nil and not self.inst.components.health:IsDead() then
		self:GetAttacked(targ, reflected_dmg, nil, nil, reflected_spdmg)
        for i, v in ipairs(reflect_list) do
            if v.inst:IsValid() then
                v.inst:PushEvent("onreflectdamage", v)
            end
        end
    end
end

function Combat:SetRequiresToughCombat(tough)
	self.tough = tough
end

function Combat:SetShouldRecoilFn(fn)
	self.shouldrecoilfn = fn
end

function Combat:ShouldRecoil(attacker, weapon, damage)
	if self.shouldrecoilfn ~= nil then
		local recoil, remaining_damage = self.shouldrecoilfn(self.inst, attacker, weapon, damage)
		if recoil ~= nil then
			if recoil then
				return true, remaining_damage or nil
			end
			return false, remaining_damage or damage
		end
	end

	if self.tough and
		not (attacker ~= nil and attacker:HasTag("toughfighter")) and --TODO reuse toughworker?
		not (weapon ~= nil and weapon.components.weapon ~= nil and weapon.components.weapon:CanDoToughFight())
		then
		return true, nil
	end

	return false, damage
end

function Combat:AddConditionExternalDamageTakenMultiplier(fn)
    self.conditionexternaldamagetakenmultipliers = self.conditionexternaldamagetakenmultipliers or {}
    self:RemoveConditionExternalDamageTakenMultiplier(fn)
    table.insert(self.conditionexternaldamagetakenmultipliers, fn)
end

function Combat:RemoveConditionExternalDamageTakenMultiplier(fn)
    if self.conditionexternaldamagetakenmultipliers ~= nil then
        table.removearrayvalue(self.conditionexternaldamagetakenmultipliers, fn)
    end
end

function Combat:ApplyConditionExternalDamageTakenMultiplier(damage, attacker, weapon)
    local damagetakenmult = 1

    for k, fn in ipairs(self.conditionexternaldamagetakenmultipliers) do
        damagetakenmult = damagetakenmult * (fn(self.inst, attacker, weapon) or 1)
    end

    return damage * damagetakenmult
end

--#V2C: what's this? not used?
function Combat:GetDamageReflect(target, damage, weapon, stimuli)
    if target.components.rider ~= nil and target.components.rider:IsRiding() then
        local mount = target.components.rider:GetMount()
        if mount ~= nil then
            if mount.components.damagereflect ~= nil then
                mount.components.damagereflect:OnAttacked(self.inst, damage, weapon, stimuli)
            end
            return
        end
    end
    if target.components.damagereflect ~= nil then
        target.components.damagereflect:OnAttacked(self.inst, damage, weapon, stimuli)
    end
end

local AREAATTACK_MUST_TAGS = { "_combat" }
function Combat:DoAreaAttack(target, range, weapon, validfn, stimuli, excludetags, onlyontarget)
    local hitcount = 0
    local x, y, z = target.Transform:GetWorldPosition()
    if onlyontarget then
        local ent = target
        if self:IsValidTarget(ent) and
            (validfn == nil or validfn(ent, self.inst)) then
            self.inst:PushEvent("onareaattackother", { target = ent, weapon = weapon, stimuli = stimuli })
            local dmg, spdmg = self:CalcDamage(ent, weapon, self.areahitdamagepercent)
            ent.components.combat:GetAttacked(self.inst, dmg, weapon, stimuli, spdmg)
            hitcount = hitcount + 1
        end
    else
        local ents = TheSim:FindEntities(x, y, z, range, AREAATTACK_MUST_TAGS, excludetags)
        for i, ent in ipairs(ents) do
            if ent ~= target and
                ent ~= self.inst and
                self:IsValidTarget(ent) and
                (validfn == nil or validfn(ent, self.inst)) then
                self.inst:PushEvent("onareaattackother", { target = ent, weapon = weapon, stimuli = stimuli })
                local dmg, spdmg = self:CalcDamage(ent, weapon, self.areahitdamagepercent)
                ent.components.combat:GetAttacked(self.inst, dmg, weapon, stimuli, spdmg)
                hitcount = hitcount + 1
            end
        end
    end

    return hitcount
end

function Combat:CanBeAlly(guy)
-- 友军判定。与 ShouldAggro 一样，属于「业务规则」而非「物理可达性」。
	return self.inst.replica.combat:CanBeAlly(guy)
end

function Combat:IsAlly(guy)
    return self.inst.replica.combat:IsAlly(guy)
end

--V2C: *deprecated* use similar functions IsAlly/CanBeAlly instead
function Combat:TargetHasFriendlyLeader(target)
    return self.inst.replica.combat:TargetHasFriendlyLeader(target)
end

function Combat:CanBeAttacked(attacker)
    return self.inst.replica.combat:CanBeAttacked(attacker)
end

function Combat:OnRemoveFromEntity()
-- ★ OnRemoveFromEntity：实体销毁时的清理。
-- 这是 bug-patterns A5/A7（销毁后泄漏）的标准落点——
-- 组件里注册的周期任务、事件监听、replica 字段都要在这里断开。
-- 仿写检查清单：组件里每一次 DoPeriodicTask / AddEventListener / ListenForEvent
-- 都必须在本函数里找到对应的 Cancel / RemoveListener。
    if self.target ~= nil then
        self:StopTrackingTarget(self.target)
    end
    if self.blanktask ~= nil then
        self.blanktask:Cancel()
        self.blanktask = nil
    end
    if self.retargettask ~= nil then
        self.retargettask:Cancel()
        self.retargettask = nil
    end
	self.inst:RemoveEventCallback("knockback", CommonHandlers.ResetHitRecoveryDelay)
end

return Combat