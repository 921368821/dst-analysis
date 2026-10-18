--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/deciduoustrees.lua
-- 模块：预制体层 / 植被（Tree）
-- 职责：落叶树。演示「运行时形态可变的预制体」：
--       长势（短/中/高）× 季节叶色（常绿/彩色/光秃/毒）× 怪物化 × 砍伐 × 烧毁，
--       两条正交状态轴 + 组件动态装卸 + 休眠时卸载能力。
-- 关键符号：builds（颜色系表）, makeanims, GetBuild, SpawnLeafFX, PushSway, Sway,
--           UpdateIdleLeafFx, GrowLeavesFn, OnChangeLeaves, SetShort/SetNormal/SetTall,
--           growth_stages, chop_tree, make_stump, chop_down_tree,
--           StartMonster/StopMonster/DoStartMonster/DoStopMonster,
--           OnEntitySleep/OnEntityWake, OnTimerDone, onsave/onload,
--           OnSeasonChanged, ChangeToSeason, OnCyclesChanged, makefn, tree
-- 变体清单（return 派生 6 个）：
--   deciduoustree / _normal / _tall / _short / _burnt / _stump
-- 架构要点：
--   · 颜色系（6 种）不是 6 个预制体，而是 inst.build 字段的取值（第 1310 行 SetPrefabName
--     统一为 deciduoustree）—— 预制体名 = 身份，外观 = 状态
--   · 渲染三层递进：改 bank（形态级）/ 改 build（贴图级）/ OverrideSymbol（季节级）
--   · target_leaf_state 与 leaf_state 分离，让异步过渡（11 秒动画）可中断与重定向
--   · make_stump 是「同一实体原地变形态」的范本：换组件等级、换物理、换交互方式
--   · OnEntitySleep 卸载 burnable/propagator/inspectable，OnEntityWake 严格镜像重建
--   · 存档只存状态描述与相对时间，不存 GetTime 绝对值
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：prefabs.lua（Prefab 全局工厂）, prefabutil.lua,
--           standardcomponents.lua（MakeObstaclePhysics / MakeSnowCoveredPristine /
--           MakeLargeBurnable / MakeMediumPropagator / MakeWaxablePlant /
--           RemovePhysicsColliders / SetLunarHailBuildupAmount*）,
--           components/growable.lua, components/plantregrowth.lua, components/timer.lua,
--           components/lootdropper.lua, components/workable.lua, components/cattoy.lua,
--           components/burnable.lua, components/combat.lua,
--           components/deciduoustreeupdater.lua,
--           stategraphs/SGdeciduoustree.lua, tuning.lua:2892（怪物概率阈值表）
--============================================================
local assets =
-- ============================================================
-- deciduoustrees.lua —— 落叶树（运行时形态可变的预制体）
--
-- 【这个文件演示了什么架构】
-- 1) ★★ 同一个预制体在运行时有 6 种「形态」，且形态之间会来回切换：
--   长势（short/normal/tall）× 季节叶色（normal/colorful/barren/poison）×
--   是否怪物化（monster）× 砍伐后（stump）× 烧毁（burnt）。
--   代码用两条正交轴表达：build 表管「颜色系」，growable 组件管「长势」，
--   inst.leaf_state 管「季节」，inst.monster 管「是否怪物化」。
-- 2) ★ 组件的动态装卸：怪物化时 AddComponent("combat")，结束时 RemoveComponent。
--   树可以是「可战斗的怪物」也可以是「静止的建筑」，靠组件的有无区分。
-- 3) ★ OnEntitySleep / OnEntityWake：休眠时卸掉 burnable/propagator/inspectable，
--   醒来再装回来。这是 DST 降低远距离实体开销的核心手段。
-- 4) 变体派生：makefn(build, stage, data) 是工厂，末尾派生 6 个预制体。
--
-- 【★ 与其他预制体文件的核心差别】
-- pighouse / treasurechest / boat 的形态在生成时就固定了；
-- 这棵树的形态会随世界时间（季节、天数）与玩家行为（砍伐、放火）持续变化。
-- ⇒ 预制体装配「可变对象」的难点全在这里：每个组件都要能装、能卸、能重配。
--
-- 【上游来源】Klei Entertainment《Don't Starve Together》游戏脚本
-- ============================================================
{
    Asset("ANIM", "anim/tree_leaf_short.zip"),
-- 【★ 资源清单的一个特点：同一批文件对应多种形态】
-- tree_leaf_short/normal/tall 三包 → 对应长势三档；tree_leaf_monster → 对应怪物化；
-- tree_leaf_trunk_build → 冬季光秃秃的树干造型。
-- ⇒ 「长势」改变的是 AnimState 的 bank/build，「季节」改变的是 OverrideSymbol（第 258 行）。
-- 两套机制叠加，实现一棵树 12 种视觉状态而只用 5 个资源包。
-- ★★ 这是 DST 美术资源复用的核心手法：把变化维度拆到 bank（换整套）与 symbol（换局部）。
    Asset("ANIM", "anim/tree_leaf_normal.zip"),
    Asset("ANIM", "anim/tree_leaf_tall.zip"),
    Asset("ANIM", "anim/tree_leaf_monster.zip"),
    Asset("ANIM", "anim/tree_leaf_trunk_build.zip"), --trunk build (winter leaves build)
-- ★-- 注释说明了 trunk build 其实是「冬季树叶用的」造型 —— 命名与用途相反，
-- 读源码时容易误解成「只在砍掉后显示」。
    Asset("ANIM", "anim/tree_leaf_green_build.zip"), --spring, summer leaves build
    Asset("ANIM", "anim/tree_leaf_red_build.zip"), --autumn leaves build
    Asset("ANIM", "anim/tree_leaf_orange_build.zip"), --autumn leaves build
    Asset("ANIM", "anim/tree_leaf_yellow_build.zip"), --autumn leaves build
    Asset("ANIM", "anim/tree_leaf_poison_build.zip"), --poison leaves build
    Asset("SOUND", "sound/forest.fsb"),
    Asset("SOUND", "sound/deciduous.fsb"),
    Asset("MINIMAP_IMAGE", "tree_leaf"),
-- ★ 三个 MINIMAP_IMAGE 对应三种地图图标：正常 / 烧毁 / 树桩。
-- 它们在运行中被动态替换（第 682、493、1423 行），是「一个实体、多个地图图标」的样本。
    Asset("MINIMAP_IMAGE", "tree_leaf_burnt"),
    Asset("MINIMAP_IMAGE", "tree_leaf_stump"),
}

local prefabs =
-- 【依赖清单】19 个。★ 值得注意的两个：
--   livinglog（第 36 行）—— 怪物化后的树掉落「活木」，普通树掉落 log。
--   birchnutdrake / small_puff —— 砍倒时的特效与响尾蛇式的小生物（季节相关）。
-- ⇒ 依赖表能看出「这棵树和哪些玩法系统有交互」，比读代码快得多。
{
    "log",
    "acorn",
    "charcoal",
    "green_leaves",
    "red_leaves",
    "orange_leaves",
    "yellow_leaves",
    "purple_leaves",
    "green_leaves_chop",
    "red_leaves_chop",
    "orange_leaves_chop",
    "yellow_leaves_chop",
    "purple_leaves_chop",
    "deciduous_root",
    "livinglog",
    "nightmarefuel",
    "spoiled_food",
    "birchnutdrake",
    "small_puff",
}

local builds =
-- ★★ builds 表：颜色系变体字典。这是本文件「变体配置化」的核心。
-- 每个变体 9 个字段：leavesbuild / prefab_name / 三档 loot / drop_acorns / fx / chopfx / shelter
-- ⇒ 【可移植模式】把「变体差异」全部收敛成一张同构数据表，
-- 代码只读表不看具体变体名 —— 新增一个颜色系只需加一个表项。
-- ★ 注意 prefab_name 一项：所有变体的 prefab_name 都是 "deciduoustree"（第 1310 行 SetPrefabName），
-- 也就是说颜色不是不同预制体，而是同一预制体的不同实例状态。
-- ⇒ 决定「是不是新东西」的标准是【预制体名】而不是【外观】。存档、图鉴、配方全都按预制体名走。
{
    normal = { --Green
        leavesbuild="tree_leaf_green_build",
        prefab_name="deciduoustree",
        normal_loot = {"log", "log"},
        short_loot = {"log"},
        tall_loot = {"log", "log", "log", "acorn"},
        drop_acorns=true,
        fx="green_leaves",
        chopfx="green_leaves_chop",
        shelter=true,
    },
    barren = {
-- barren（冬天的光树）：★ 唯一一个 leavesbuild = nil 的变体，
-- 后面第 260、322、766 行都靠判 nil 来决定用 ClearOverrideSymbol。
-- ⇒ 「nil 表达清除」是本文件处理变体差异的手法之一：不用写两套逻辑，只判一次 nil。
        leavesbuild=nil,
        prefab_name="deciduoustree",
        normal_loot = {"log", "log"},
        short_loot = {"log"},
        tall_loot = {"log", "log", "log"},
        drop_acorns=false,
-- barren 的 drop_acorns = false / shelter = false / fx = nil —— 冬天掉不了东西、不能避雨。
-- ⇒ 【设计】冬天的树变成纯装饰，不能当庇护所。这是靠数据表驱动实现的设计规则，
-- 没有任何一行 if 逻辑。移植时想加平衡性规则，优先加进表而不是加进代码。
        fx=nil,
        chopfx=nil,
        shelter=false,
    },
    red = {
        leavesbuild="tree_leaf_red_build",
        prefab_name="deciduoustree",
        normal_loot = {"log", "log"},
        short_loot = {"log"},
        tall_loot = {"log", "log", "log", "acorn"},
        drop_acorns=true,
        fx="red_leaves",
        chopfx="red_leaves_chop",
        shelter=true,
    },
    orange = {
        leavesbuild="tree_leaf_orange_build",
        prefab_name="deciduoustree",
        normal_loot = {"log", "log"},
        short_loot = {"log"},
        tall_loot = {"log", "log", "log", "acorn"},
        drop_acorns=true,
        fx="orange_leaves",
        chopfx="orange_leaves_chop",
        shelter=true,
    },
    yellow = {
        leavesbuild="tree_leaf_yellow_build",
        prefab_name="deciduoustree",
        normal_loot = {"log", "log"},
        short_loot = {"log"},
        tall_loot = {"log", "log", "log", "acorn"},
        drop_acorns=true,
        fx="yellow_leaves",
        chopfx="yellow_leaves_chop",
        shelter=true,
    },
    poison = {
-- poison（怪物化后的毒树）：★ loot 全换成了 livinglog + acorn，
-- 但它只是普通 build 表里的一项 —— 怪物化并没有新建一张表，而是改 inst.build（第 830 行）。
-- ⇒ 【架构精妙处】「怪物树」的实现是「把 build 字段改成 poison」，一行搞定全部视觉与掉落变化。
        leavesbuild="tree_leaf_poison_build",
        prefab_name="deciduoustree",
        normal_loot = {"livinglog", "acorn", "acorn"},
        short_loot = {"livinglog", "acorn"},
        tall_loot = {"livinglog", "acorn", "acorn", "acorn"},
        drop_acorns=true,
        fx="purple_leaves",
        chopfx="purple_leaves_chop",
        shelter=true,
    },
}

local function makeanims(stage)
-- ★★ makeanims(stage)：把「形态」映射成一整套动画名。
-- 输出的表有 18 个动画槽位：idle / sway1 / sway2 / swayaggro* / swayfx / chop /
-- fallleft / fallright / stump / burning / burnt / chop_burnt / idle_chop_burnt /
-- dropleaves / growleaves。
-- ⇒ 【可移植模式】不要在代码里到处写 AnimState:PlayAnimation("chop_tall") 这种字符串，
-- 而应收进一张表，用 inst.anims.chop 引用。改名时只改一处，运行期还能整体换表。
-- ★ 本文件第 162 行就是靠这个机制实现了「运行时切换长势」（第 353-358 行）。
    if stage == "monster" then
-- ★ monster 分支为什么不能拼接后缀？因为怪物树的所有动画名都不带 _tall 之类的后缀，
-- 它们是一套完全独立的命名（idle_tall 而非 idle_tall_monster，见第 116 行）。
-- ⇒ 【⚠️ 易踩的坑】若把 monster 分支也写成拼接式，会去找 idle_tall_monster 这个不存在的动画，
-- 表现为「怪物树站着不动」。这类「命名空间不统一」必须在数据层就分开处理。
        return {
            idle="idle_tall",
            sway1="sway_loop_agro",
            sway2="sway_loop_agro",
            swayaggropre="sway_agro_pre",
            swayaggro="sway_loop_agro",
            swayaggropst="sway_agro_pst",
            swayaggroloop="idle_loop_agro",
            swayfx="swayfx_tall",
            chop="chop_tall_monster",
            fallleft="fallleft_tall_monster",
            fallright="fallright_tall_monster",
            stump="stump_tall_monster",
            burning="burning_loop_tall",
            burnt="burnt_tall",
            chop_burnt="chop_burnt_tall",
            idle_chop_burnt="idle_chop_burnt_tall",
            dropleaves = "drop_leaves_tall",
            growleaves = "grow_leaves_tall",
        }
    else
        return {
            idle="idle_"..stage,
            sway1="sway1_loop_"..stage,
            sway2="sway2_loop_"..stage,
            swayaggropre="sway_agro_pre",
            swayaggro="sway_loop_agro",
            swayaggropst="sway_agro_pst",
            swayaggroloop="idle_loop_agro",
            swayfx="swayfx_"..stage,
            chop="chop_"..stage,
            fallleft="fallleft_"..stage,
            fallright="fallright_"..stage,
            stump="stump_"..stage,
            burning="burning_loop_"..stage,
            burnt="burnt_"..stage,
            chop_burnt="chop_burnt_"..stage,
            idle_chop_burnt="idle_chop_burnt_"..stage,
            dropleaves = "drop_leaves_"..stage,
            growleaves = "grow_leaves_"..stage,
        }
    end
end

local short_anims = makeanims("short")
-- ★ 4 张 anims 表在文件加载时就一次性算好（makeanims 是纯函数，无副作用）。
-- 运行期只做 inst.anims = xxx_anims 的引用赋值（第 364、385、403 行）。
-- ⇒ 【性能范式】预计算所有组合、运行期只选表，避免每帧做字符串拼接。
local tall_anims = makeanims("tall")
local normal_anims = makeanims("normal")
local monster_anims = makeanims("monster")

local function GetBuild(inst)
-- GetBuild：★ 容错查找，查不到就回退到 normal（第 165 行）。
-- ⇒ 【移植建议】数据表查找一律给默认值，不要让 nil 一路传播到下游。
    return builds[inst.build] or builds.normal
end

local function SpawnLeafFX(inst, waittime, chop)
-- 【★ waittime 参数把「立刻播」与「延迟播」合并成同一个函数】
-- 第 174-177 行：传了 waittime 就转成 DoTaskInTime 再调自己一次，不传就立即执行。
-- ⇒ 【可移植模式】「现在做」与「等一下做」用同一个回调，比写两个函数省一半代码。
    if (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) or
-- 开头四个守卫：正在烧 / 是树桩 / 已烧毁 / 已休眠 —— 全部不产生特效。
-- ★ 最后一条（IsAsleep）最重要：远处休眠的树不会周期性掉叶子。
-- ⇒ 【性能范式】任何周期性特效都先判 IsAsleep，这是 DST 控制开销的第一道闸。
        inst:HasTag("stump") or
        inst:HasTag("burnt") or
        inst:IsAsleep() then
        return
    elseif waittime ~= nil then
        inst:DoTaskInTime(waittime, SpawnLeafFX, nil, chop)
        return
    end

    local fx = nil
    if chop then
        if GetBuild(inst).chopfx ~= nil then
            fx = SpawnPrefab(GetBuild(inst).chopfx)
        end
    elseif GetBuild(inst).fx ~= nil then
        fx = SpawnPrefab(GetBuild(inst).fx)
    end
    if fx ~= nil then
        local x, y, z = inst.Transform:GetWorldPosition()
        if inst.components.growable ~= nil then
-- ★ 特效高度按长势微调：normal 档下沉 0.3（第 193 行）。
-- 短/高两档的调整被注释掉了（第 191、195 行）—— 说明只有 normal 档视觉上需要。
-- ⇒ 读到注释掉的代码，先想「是不是不需要」而不是「是不是废弃」。
            if inst.components.growable.stage == 1 then
                --y = y + 0 --Short FX height
            elseif inst.components.growable.stage == 2 then
                y = y - .3 --Normal FX height
            elseif inst.components.growable.stage == 3 then
                --y = y + 0 --Tall FX height
            end
        end
        --Randomize height a bit for chop FX
        fx.Transform:SetPosition(x, chop and y + math.random() * 2 or y, z)
-- ★★ chop 时在 Y 方向加随机高度（第 2 个参数 chop and y + math.random()*2 or y）。
-- 砍击的碎叶应该从随机高度落下，飘落时的落叶则固定在树心高度。
-- ⇒ 【细节】Lua 的 and/or 三元表达：chop 为真走加随机，为假走原值。
-- ⚠️ 这种写法的坑：若加法结果为 0 或 false，and/or 会走错分支。这里 y + random*2 恒 > 0，安全。
    end
end

local function PushSway(inst, monster, monsterpost, skippre)
-- ★★ PushSway 与 Sway（第 217 行）是一对「同逻辑、不同 API」的函数：
--   PushSway 用 AnimState:PushAnimation（压栈，供稍后切状态用）
--   Sway      用 AnimState:PlayAnimation（替换，供直接播放用）
-- ★ 两者都先调状态机而不是直接播动画 —— 因为怪物态由 SGdeciduoustree 接管（第 1335 行）。
-- ⇒ 【可移植模式】有状态机时，动画播放也要走状态机；
-- 直接 PlayAnimation 会与状态机争夺 AnimState 控制权，产生闪烁。
	if inst.sg:HasStateTag("electrocute") then
		return
	elseif monster then
        inst.sg:GoToState("gnash_pre", { push = true, skippre = skippre })
    elseif monsterpost then
        inst.sg:GoToState(inst.sg:HasStateTag("gnash") and "gnash_pst" or "gnash_idle")
-- ★ HasStateTag("gnash") 二选一：正在龇牙就播收招，否则播待机。
-- ⇒ 【状态机用法】HasStateTag 查的是「当前状态属于哪一组」，是多状态互斥的廉价判断。
-- 移植时优先用 tag 分组而非逐个状态名比较。
    elseif inst.monster then
        inst.sg:GoToState("gnash_idle")
    else
        inst.AnimState:PushAnimation(math.random() < .5 and inst.anims.sway1 or inst.anims.sway2, true)
    end
end

local function Sway(inst, monster, monsterpost)
	if inst.sg:HasAnyStateTag("burning", "electrocute") or inst:HasTag("stump") then
-- HasAnyStateTag("burning", "electrocute")：★ 一次查多个 tag 的简写。
-- 与 or 写两个 HasStateTag 相比，HasAnyStateTag 有优化（一次遍历 tag 集合）。
        return
    elseif monster then
        inst.sg:GoToState("gnash_pre", { push = false, skippre = false })
    elseif monsterpost then
        inst.sg:GoToState(inst.sg:HasStateTag("gnash") and "gnash_pst" or "gnash_idle")
    elseif inst.monster then
        inst.sg:GoToState("gnash_idle")
    else
        inst.AnimState:PlayAnimation(math.random() < .5 and inst.anims.sway1 or inst.anims.sway2, true)
    end
end

local function UpdateIdleLeafFx(inst)
-- ★★ UpdateIdleLeafFx：只有「彩色落叶状态 + 实体醒着」才注册周期任务。
-- 第 234 行的 DoPeriodicTask 频率在 TUNING 给的两个值之间随机 ——
-- ⇒ 【美术手感】随机周期让多棵树的落叶不同步，避免整齐划一的机械感。
-- 第 236-239 行是取消分支：这个函数被大量状态切换调用（涨跌季节、怪物化、砍伐），
-- 所以必须写成「幂等的开关」而不是「只开不关」。
	if inst.leaf_state == "colorful" and inst.entity:IsAwake() then
		if inst.spawnleaffxtask == nil then
			inst.spawnleaffxtask = inst:DoPeriodicTask(math.random(TUNING.MIN_SWAY_FX_FREQUENCY, TUNING.MAX_SWAY_FX_FREQUENCY), SpawnLeafFX)
		end
	elseif inst.spawnleaffxtask ~= nil then
		inst.spawnleaffxtask:Cancel()
		inst.spawnleaffxtask = nil
	end
end

local function GrowLeavesFn(inst, monster, monsterout)
-- ★★ GrowLeavesFn 挂在 "animover" 事件上（第 326、334 行）：动画播完才执行。
-- ⇒ 【可移植模式】「播动画 → 动画结束时回调 → 应用结果」是状态切换的标准两段式。
-- 中间若被打断（燃烧/砍伐），第 246、251 行的 RemoveEventCallback 负责解绑。
-- ⚠️ 陷阱：连续两次换叶会注册两次回调，RemoveEventCallback 只解一个 ——
-- 第 296-299 行专门做了「10 秒内刚砍过就推迟换叶」的判断来避免这个竞态。
    if (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) or
-- 守卫的三个条件与第 169 行相同：烧 / 桩 / 焦。★ 被打断时只解绑不应用结果。
        inst:HasTag("stump") or
        inst:HasTag("burnt") then
        inst:RemoveEventCallback("animover", GrowLeavesFn)
        return
    end

    if inst.leaf_state == "barren" or inst.target_leaf_state == "barren" then
-- ★ 换叶中途如果目标是 barren，连 build 都要改（第 253 行）—— 光秃状态是「常态」而非「过渡态」。
-- ⇒ 冬季的树不是「掉完叶子」而是「变成另一张配置」，由 build 字段承载。
        inst:RemoveEventCallback("animover", GrowLeavesFn)
        if inst.target_leaf_state == "barren" then
            inst.build = "barren"
        end
    end

    if GetBuild(inst).leavesbuild then
-- ★★ OverrideSymbol("swap_leaves", builds, "swap_leaves") —— 局部换装。
-- 第三个参数是 OverrideSymbol 的「兜底符号名」，用于被瞄准高亮等需要联动替换的场景。
-- ⇒ 【DST 渲染核心概念】override 是一层符号替换：树干来自 build，
-- 叶子来自 override。两者独立，就能在不换整套模型的前提下换叶子。
-- ★ 全文件共 8 处 OverrideSymbol / ClearOverrideSymbol 对，都在管这 4 个符号：
--   swap_leaves（季节叶）、legs / legs_mouseover / eye / mouth（怪物化）。
        inst.AnimState:OverrideSymbol("swap_leaves", GetBuild(inst).leavesbuild, "swap_leaves")
    else
        inst.AnimState:ClearOverrideSymbol("swap_leaves")
    end

    if inst.components.growable ~= nil then
-- ★ 长势决定掉落：stage 1 短 / 2 中 / 3 高，三档 loot 全部取自 builds 表。
-- ⇒ 「砍倒掉几个木头」这件事完全由数据表决定，代码零分支。
        if inst.components.growable.stage == 1 then
            inst.components.lootdropper:SetLoot(GetBuild(inst).short_loot)
        elseif inst.components.growable.stage == 2 then
            inst.components.lootdropper:SetLoot(GetBuild(inst).normal_loot)
        else
            inst.components.lootdropper:SetLoot(GetBuild(inst).tall_loot)
        end
    end

    inst.leaf_state = inst.target_leaf_state
	UpdateIdleLeafFx(inst)
    if inst.leaf_state == "barren" then
-- ★ barren 状态要清掉 mouseover 符号（第 276 行）—— 光秃的树没有「可砍」的鼠标悬停提示。
-- ⇒ 【渲染细节】mouseover 是一个独立符号，用来在瞄准时高亮可交互部位。
-- 有没有这个符号直接决定玩家能不能看出「这棵树能砍」。
        inst.AnimState:ClearOverrideSymbol("mouseover")
    else
        if inst.build == "barren" then
            inst.build = inst.leaf_state == "normal" and "normal" or "red"
        end
        inst.AnimState:OverrideSymbol("mouseover", "tree_leaf_trunk_build", "toggle_mouseover")
-- 同一符号的另一分支：非 barren 时装上 mouseover + 悬停切换符号。
-- ⇒ 「可交互性」在 DST 里是可以通过符号切换表达的视觉语言。
    end

    if monster ~= true and monsterout ~= true then
        Sway(inst)
    end
end

local function OnChangeLeaves(inst, monster, monsterout)
-- ★★ OnChangeLeaves：换叶的总调度。★ 它同时被 6 处调用（第 328、822、1158 等），
-- 所以第 296 行的「刚砍过就推迟」防抖分支对正确性至关重要。
    if (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) or
        inst:HasTag("stump") or
        inst:HasTag("burnt") then
        inst.targetleaveschangetime = nil
        inst.leaveschangetask = nil
        return
    elseif not monster and inst.components.workable and inst.components.workable.lastworktime and inst.components.workable.lastworktime < GetTime() - 10 then
-- ⚠️ ★ 关键防抖：砍倒前 10 秒内砍过的树要等 11 秒再换叶。
-- 若不加这一条，玩家连砍会把换叶任务反复重启，出现「叶子一直不掉」或状态抖动。
-- ⇒ 【可移植模式】任何玩家可高频触发的状态切换，都要加冷却窗口。
        inst.targetleaveschangetime = GetTime() + 11
        inst.leaveschangetask = inst:DoTaskInTime(11, OnChangeLeaves)
        return
    else
        inst.targetleaveschangetime = nil
        inst.leaveschangetask = nil
    end

    if inst.target_leaf_state ~= "barren" then
        if inst.target_leaf_state == "colorful" then
-- ★ target_leaf_state 是「目标」，leaf_state 是「当前」。
-- 这对二元状态贯穿全文件（第 273、1056、1057、1129 行）。
-- ⇒ 【架构价值】引入「目标 vs 当前」而非直接改状态，让异步过渡（动画 11 秒）可被中断与重定向。
-- 移植时凡是「状态切换需要时间」的场景，都该用这个双字段模型。
            local rand = math.random()
            inst.build = ({ "red", "orange", "yellow" })[math.random(3)]
-- 秋天随机一种暖色（红/橙/黄）写进 inst.build —— 季节变化直接落到颜色系上。
-- ⇒ 第 43 行 builds 表里的 red/orange/yellow 三项在这里被动态选用。
-- 也就是说 builds 表的 6 项不是「6 种树」，而是「6 种可用外观」，
-- 季节逻辑负责决定当前用哪一项。★ 这个区别是理解本文件的关键。
            inst.AnimState:SetMultColour(1, 1, 1, 1)
-- SetMultColour(1,1,1,1)：彩色叶恢复原始贴图颜色（不被绿叶的染色压住）。
-- ⇒ 【可移植模式】一套贴图 + SetMultColour 染色 = 有限调色板。
-- 普通状态（第 314 行）用第 1339 行随机生成的 inst.color 染色，做出「每棵树颜色略不同」。
        elseif inst.target_leaf_state == "poison" then
            inst.AnimState:SetMultColour(1, 1, 1, 1)
            inst.build = "poison"
        else
            inst.AnimState:SetMultColour(inst.color, inst.color, inst.color, 1)
            inst.build = "normal"
        end

        if inst.leaf_state == "barren" then
            if GetBuild(inst).leavesbuild then
                inst.AnimState:OverrideSymbol("swap_leaves", GetBuild(inst).leavesbuild, "swap_leaves")
            else
                inst.AnimState:ClearOverrideSymbol("swap_leaves")
            end
            inst.AnimState:PlayAnimation(inst.anims.growleaves)
-- ★ 从 barren（光秃）长出叶子：播 growleaves 动画 + 音效 + 挂 animover 回调。
-- 与第 331 行的 dropleaves（掉叶子）形成一对对称流程。
            inst.SoundEmitter:PlaySound("dontstarve/forest/treeGrow")
-- 音效走硬编码路径（不走 inst.sounds 表，对比 boat.lua 第 130 行）——
-- 树音效简单，全文件共用两个即可，不必为变体做表。
            inst:ListenForEvent("animover", GrowLeavesFn)
        else
            GrowLeavesFn(inst, monster, monsterout)
        end
    else
        inst.AnimState:PlayAnimation(inst.anims.dropleaves)
        SpawnLeafFX(inst, 11 * FRAMES)
        inst.SoundEmitter:PlaySound("dontstarve/forest/treeWilt")
        inst:ListenForEvent("animover", GrowLeavesFn)
    end
    if GetBuild(inst).shelter then
-- ★ shelter 标签：能否避雨。冬天的 barren 变体会 RemoveTag（第 339 行）。
-- ⇒ 【关键设计】同一棵树的「庇护所」资格随季节变化，靠 tag 表达给所有系统查。
-- 第 1288 行的 SetDeploySmartRadius 与第 1423 行树桩化都涉及这类 tag 切换。
        inst:AddTag("shelter")
    else
        inst:RemoveTag("shelter")
    end

    if monster then
-- ★ 怪物化时移除 waxable（不可上蜡）——怪物化的树不再是「植物」。
-- 第 345-347 行的反向分支：变回普通树时补装 waxable。
-- ⇒ 【可移植模式】用「加/减一个组件」来表达身份切换，比加一个 is_monster 布尔更彻底：
-- 其它系统查 waxable == nil 就知道这不是棵树了，无需知道 monster 标志。
        inst:RemoveComponent("waxable")

    elseif inst.components.waxable == nil then
        MakeWaxablePlant(inst)
    end
end

local function ChangeSizeFn(inst)
-- ChangeSizeFn：同样挂在 animover 上（第 379、398、416 行）。
-- 第 353-358 行的四路分支顺序：短 → 中 →（怪物 → 怪物）→ 高。
-- ★ 注意 monster 判断排在 stage 2 之后：怪物树若长到中，会被判成「普通中树」而非怪物。
-- 推断这是有意的（怪物树本就会立即长高），但源码未说明，此为推断。
    inst:RemoveEventCallback("animover", ChangeSizeFn)
    if inst.components.growable ~= nil then
        inst.anims =
            (inst.components.growable.stage == 1 and short_anims) or
            (inst.components.growable.stage == 2 and normal_anims) or
            (inst.monster and monster_anims) or
            tall_anims
    end
    Sway(inst, nil, inst.monster)
end

local function SetShort(inst)
-- ★★ SetShort：★ 「设置当前状态」的四个函数之一（short/normal/tall）。
-- 三个函数结构完全一致：设 anims 表 → 改砍伐所需次数 → 改月石积聚量 → 改掉落。
-- ★ 第 363 行 if not inst.monster：★ 怪物化的树不响应长势设置。
-- ⇒ 【可移植模式】状态切换函数里第一件事就是判「当前是否处于另一种特殊态」，
-- 避免两种状态机同时修改同一组参数。
    if not inst.monster then
        inst.anims = short_anims
        if inst.components.workable ~= nil then
           inst.components.workable:SetWorkLeft(TUNING.DECIDUOUS_CHOPS_SMALL)
-- SetWorkLeft(DECIDUOUS_CHOPS_SMALL)：★ 砍伐次数随长势递减。
-- 「越高越难砍」在 DST 里普遍靠 workable:SetWorkLeft 实现，数值统一放 TUNING。
-- ⚠️ 但第 454 行的 SetWorkLeft(1) 是硬编码（怪物化过渡期防抖），属预制体级 override。
        end
        SetLunarHailBuildupAmountSmall(inst)
-- SetLunarHailBuildupAmountSmall/Medium/Large：★ 月石积聚量随体积变化。
-- 三档之间的量级差异由 TUNING 决定，预制体只做档位映射。
        inst.components.lootdropper:SetLoot(GetBuild(inst).short_loot)
    end
end

local function GrowShort(inst)
-- GrowShort：★ 「播放过渡动画」的三个函数之一（grow_tall_to_short 等）。
-- 注意动画名是「从 X 到 Y」，与 makeanims 表里的槽位名分开维护。
-- ⇒ 【观察】动画名有两套命名体系：一套是状态（第 113 行的表），一套是过渡。
-- 移植时建议统一成 {from, to} 的过渡描述，而不是硬编码动画名。
    if not inst.monster then
        inst.AnimState:PlayAnimation("grow_tall_to_short")
        if inst.leaf_state == "colorful" then
            SpawnLeafFX(inst, 17 * FRAMES)
        end
        inst:ListenForEvent("animover", ChangeSizeFn)
        inst.SoundEmitter:PlaySound("dontstarve/forest/treeGrow")
    end
end

local function SetNormal(inst)
    inst.anims = normal_anims
    if inst.components.workable ~= nil then
        inst.components.workable:SetWorkLeft(TUNING.DECIDUOUS_CHOPS_NORMAL)
    end
    SetLunarHailBuildupAmountMedium(inst)
    inst.components.lootdropper:SetLoot(GetBuild(inst).normal_loot)
end

local function GrowNormal(inst)
    inst.AnimState:PlayAnimation("grow_short_to_normal")
    if inst.leaf_state == "colorful" then
        SpawnLeafFX(inst, 10 * FRAMES)
    end
    inst:ListenForEvent("animover", ChangeSizeFn)
    inst.SoundEmitter:PlaySound("dontstarve/forest/treeGrow")
end

local function SetTall(inst)
    inst.anims = tall_anims
    if inst.components.workable ~= nil then
        inst.components.workable:SetWorkLeft(TUNING.DECIDUOUS_CHOPS_TALL)
    end
    SetLunarHailBuildupAmountLarge(inst)
    inst.components.lootdropper:SetLoot(GetBuild(inst).tall_loot)
end

local function GrowTall(inst)
    inst.AnimState:PlayAnimation("grow_normal_to_tall")
    if inst.leaf_state == "colorful" then
        SpawnLeafFX(inst, 10 * FRAMES)
    end
    inst:ListenForEvent("animover", ChangeSizeFn)
    inst.SoundEmitter:PlaySound("dontstarve/forest/treeGrow")
end

local growth_stages =
-- ★★ growth_stages 表：★ growable 组件的配置源。每项 = 名称 + 随机时长 + Set + Grow。
-- ★ Set 负责「已经是这个状态时做什么」，Grow 负责「正在变成这个状态时做什么」。
-- ⇒ 【设计范式】把「状态」与「转移」分开配置，是有限状态机最干净的表达方式。
-- growable 组件拿到这张表就能自己跑完整套生长流程，预制体一行逻辑都不用写。
{
    { name = "short", time = function(inst) return GetRandomWithVariance(TUNING.DECIDUOUS_GROW_TIME[1].base, TUNING.DECIDUOUS_GROW_TIME[1].random) end, fn = SetShort, growfn = GrowShort },
-- ★ time 是函数（而非数字）：每棵树独立随机，避免整片树林同步生长。
-- GetRandomWithVariance(base, random) 返回 [base-random, base+random] 区间的随机数。
    { name = "normal", time = function(inst) return GetRandomWithVariance(TUNING.DECIDUOUS_GROW_TIME[2].base, TUNING.DECIDUOUS_GROW_TIME[2].random) end, fn = SetNormal, growfn = GrowNormal },
    { name = "tall", time = function(inst) return GetRandomWithVariance(TUNING.DECIDUOUS_GROW_TIME[3].base, TUNING.DECIDUOUS_GROW_TIME[3].random) end, fn = SetTall, growfn = GrowTall },
    --{ name = "old", time = function(inst) return GetRandomWithVariance(TUNING.DECIDUOUS_GROW_TIME[4].base, TUNING.DECIDUOUS_GROW_TIME[4].random) end, fn = SetOld, growfn = GrowOld },
-- ★ 第 425 行是注释掉的第四档 "old"：一个被移除的成长阶段。
-- ⇒ 读源码时看到整档被注释，说明该阶段被砍掉了（可能是平衡性调整）。
-- 这是预制体文件里保留设计历史的痕迹，比直接删掉更有信息量。
}

local function chop_tree(inst, chopper, chopsleft, numchops)
-- chop_tree：每次挥斧的回调（workable 的 onwork）。
-- 第 431-433 行用 and/or 三元选音效：海狸砍 vs 普通人砍。
-- ⇒ 【标签驱动】用 HasTag("beaver") 而不是判断组件或类型，新增可砍的角色只要打 tag。
    if not (chopper ~= nil and chopper:HasTag("playerghost")) then
        inst.SoundEmitter:PlaySound(
            chopper ~= nil and chopper:HasTag("beaver") and
            "dontstarve/characters/woodie/beaver_chop_tree" or
            "dontstarve/wilson/use_axe_tree"
        )
    end

    SpawnLeafFX(inst, nil, true)

    -- Force update anims if monster
	-- V2C: added dostartmonster_task check, still transforming, bank hasn't changed yet
-- ★★ 这两行注释（V2C）说明了一个真实的竞态修复：
-- 怪物化过渡期间 bank 还没切，此时砍击会播普通树的砍击动画。
-- 第 441 行用 dostartmonster_task == nil 判断「不在过渡期」，是针对性的防御。
-- ⇒ 【读源码收获】V2C 注释是 Klei 官方补丁的标记，记录了「后来补了什么」。
-- 这些信息在 git 历史里查不到，是理解代码意图的关键线索。
	if inst.monster and inst.dostartmonster_task == nil then
        inst.anims = monster_anims
    end
    inst.AnimState:PlayAnimation(inst.anims.chop)

    if inst.monster then
		if inst.dostartmonster_task == nil then
			inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/deciduous/hurt_chop")
			if not inst.sg:HasStateTag("electrocute") then
				inst.sg:GoToState("chop_pst")
			end
		elseif inst.components.workable and chopsleft <= 0 then
-- ★ 第 454 行 SetWorkLeft(1)：原注释 admits it doesn't handle nicely being chopped down
-- during the short transformation window —— ★★ 作者自己标注了「这里处理得不好」。
-- 强行把剩余砍击次数设为 1，让玩家能立刻砍掉，避免卡在过渡态。
-- ⇒ 【移植建议】发现这种「知道自己不优雅」的代码时，不要照抄；
-- 自己的引擎里应该给状态转移加互斥锁，从根上禁止过渡期被其它转移打断。
			-- V2C: doesn't handle nicely being chopped down during the short transformation window
			inst.components.workable:SetWorkLeft(1)
		end
    else
        PushSway(inst)
    end
end

local function dig_up_stump(inst)
-- dig_up_stump：挖掉树桩。与砍树（chop_down_tree）完全不同的交互方式。
-- ★ 第 462 行：怪物树挖出 livinglog，普通树挖出 log —— 用 inst.monster 决定掉落。
    inst.components.lootdropper:SpawnLootPrefab(inst.monster and "livinglog" or "log")
    inst:Remove()
end

local function chop_down_tree_shake(inst)
-- chop_down_tree_shake：★ 震屏。震幅随长势变化（第 471 行 stage > 2 时翻倍）。
-- ShakeAllCameras 最后一个参数 6 是震源实体 GUID 或半径，本例传 6 而非 inst。
-- ⚠️ 推断：震源传 6 意味着震屏是「全屏」而非「从树的位置扩散」。
-- 源码未说明，此为推断。
    ShakeAllCameras(
        CAMERASHAKE.FULL,
        .25,
        .03,
        inst.components.growable ~= nil and inst.components.growable.stage > 2 and .5 or .25,
        inst,
        6
    )
end

local function delayed_start_monster(inst)
    inst.monster_start_task = nil
    inst:StartMonster()
end

local function make_stump(inst)
-- ★★★ make_stump：本文件最硬核的一段 —— 「同一个实体原地变成另一种东西」。
-- 它做了 12 类改动，可分成四组：
--   ① 换组件等级：burnable 大→小、propagator 中→小（第 483-486 行）
--   ② 换物理：RemovePhysicsColliders（第 512 行），树桩不再挡路
--   ③ 换交互：workable 从 CHOP 改为 DIG，工作量从 N 变 1（第 514-517 行）
--   ④ 清理状态：取消所有挂起任务、停生长、开衰减计时（第 495-525 行）
-- ⇒ ★★ 【架构价值最高的一段】这正是「组合优于继承」的终极体现：
--   树与树桩没有任何继承关系，就是同一个 Lua 对象换了组件配置与 tag。
--   换形态的成本 = 若干次 RemoveComponent + AddComponent + 几个字段赋值。
    inst:RemoveComponent("burnable")
-- ★★ RemoveComponent + MakeSmallBurnable 的配对调用出现了 5 次（第 483-487、931-933、
-- 1411-1416 行）。这是「动态换组件」的固定写法：先卸干净，再按新规格装。
-- ⚠️ 【可改进】DST 没有 RemoveComponentIfExists，若组件不存在 RemoveComponent 是安全的，
-- 所以这个模式能工作；但移植时最好封装成 replaceComponent(inst, name, factory)。
    MakeSmallBurnable(inst)
    inst:RemoveComponent("propagator")
    MakeSmallPropagator(inst)
    inst:RemoveComponent("workable")
    RemoveLunarHailBuildup(inst)
    inst:RemoveTag("shelter")
-- ★ RemoveTag("shelter")：★ 树桩不能避雨 —— 与第 336 行的季节逻辑同一套机制。
-- ⇒ 树桩 = 「失去庇护所资格的树」，与冬天的 barren 是同一个概念的不同触发路径。
    inst:RemoveTag("cattoyairborne")
    inst:AddTag("stump")
-- AddTag("stump") 是全文件的核心状态标记，被 12 处代码检查（第 169、218、553、586、
-- 853、911、930、1093、1151、1235 行等）。
-- ⇒ 【DST 状态表达】能用 tag 表达的状态就不用布尔字段，
-- 因为 tag 能被全代码库的 FindEntities 直接筛选（见第 529 行的 CANT_TAGS）。

    inst.MiniMapEntity:SetIcon("tree_leaf_stump.png")

    if inst.monster_start_task ~= nil then
        inst.monster_start_task:Cancel()
        inst.monster_start_task = nil
    end
    if inst.monster_stop_task ~= nil then
        inst.monster_stop_task:Cancel()
        inst.monster_stop_task = nil
    end
    if inst.leaveschangetask ~= nil then
        inst.leaveschangetask:Cancel()
        inst.leaveschangetask = nil
    end
    if inst.leaveschangetask ~= nil then
        inst.leaveschangetask:Cancel()
        inst.leaveschangetask = nil
    end

    RemovePhysicsColliders(inst)

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.DIG)
    inst.components.workable:SetOnFinishCallback(dig_up_stump)
    inst.components.workable:SetWorkLeft(1)

    if inst.components.growable ~= nil then
        inst.components.growable:StopGrowing()
    end

    if inst.components.timer ~= nil and not inst.components.timer:TimerExists("decay") then
-- ★ 衰减计时器：树桩最终会自己消失并长出新树（regrowth 组件在第 1351 行）。
-- 第 524 行 TimerExists("decay") 判重：若已在计时就不重置，避免读档后计时被意外延长。
-- ⇒ 【可移植模式】计时器相关操作永远先问「是否已存在」。
        inst.components.timer:StartTimer("decay", GetRandomWithVariance(TUNING.DECIDUOUS_REGROWTH.DEAD_DECAY_TIME, TUNING.DECIDUOUS_REGROWTH.DEAD_DECAY_TIME * .5))
    end
end

local FINDTREETOTRANSFORM_MUST_TAGS = { "birchnut" }
-- ★★ 两张 FindEntities 过滤表：MUST_TAGS 只找 birchnut（同种树），
-- CANT_TAGS 排除掉火里 / 树桩 / 焦 / 怪物 / 特效 / 点击穿透 / 装饰 / 加载中 的。
-- ⇒ 【可移植模式】「让附近的同类一起变异」的标准写法：
-- 用 MUST/CANT 标签筛选，而不是遍历全表自己判断，交给引擎的空间索引。
local FINDTREETOTRANSFORM_CANT_TAGS = { "fire", "stump", "burnt", "monster", "FX", "NOCLICK", "DECOR", "INLIMBO" }
local function chop_down_tree(inst, chopper)
-- ★★ chop_down_tree：全文件最长的函数（近 100 行），做四件事：
--   ① 判定附近树是否一起怪物化（第 532-575 行）
--   ② 若自己是怪物树，卸掉战斗能力（第 577-598 行）
--   ③ 播倒下动画并按左右侧掉战利品（第 600-621 行）
--   ④ 转成树桩（第 623 行）
    local days_survived = chopper.components.age ~= nil and chopper.components.age:GetAgeInDays() or TheWorld.state.cycles
-- ★ days_survived：优先用砍伐者的年龄组件，取不到则退回世界天数。
-- ⇒ 【容错写法】chopper 可能不是有 age 的实体（那是代码调用的情况），故有兜底。
    if not inst.monster and inst.leaf_state ~= "barren" and inst.components.growable ~= nil and inst.components.growable.stage == 3 and days_survived >= TUNING.DECID_MONSTER_MIN_DAY then
-- ★ 怪物化的四个前置条件：非怪物 / 非光秃 / 长到最高档 / 存活够久。
-- 第 536-540 行的 or 链按季节取概率，四季都写了（WINTER 那行注释说明是 0）。
-- ⇒ 【平衡性设计】概率按季节与季节长度乘积，再叠加「存活天数档位」（第 542-548 行）
-- 与「砍伐者身份」修正（第 549-553 行）。共三层修正，是标准的概率型设计结构。
        --print("Chance of making a monster")
        --winter should always be 0 (because barren trees can't become monsters), but is included in tuning values for consistency
        local chance =
            (TheWorld.state.isautumn and TUNING.DECID_MONSTER_SPAWN_CHANCE_AUTUMN) or
            (TheWorld.state.isspring and TUNING.DECID_MONSTER_SPAWN_CHANCE_SPRING) or
            (TheWorld.state.issummer and TUNING.DECID_MONSTER_SPAWN_CHANCE_SUMMER) or
            (TheWorld.state.iswinter and TUNING.DECID_MONSTER_SPAWN_CHANCE_WINTER) or
            0

        local chance_mod = TUNING.DECID_MONSTER_SPAWN_CHANCE_MOD[1]
        for i, v in ipairs(TUNING.DECID_MONSTER_DAY_THRESHOLDS) do
-- ★ 第 544 行 break 而非 continue：找到第一个超过的阈值就停。
-- 本人已核实 tuning.lua:2892 的 DECID_MONSTER_DAY_THRESHOLDS = { 20, 35, 70 }，确为升序，
-- ⇒ break 的语义正确（取「满足条件的最高档」）。若阈值表非升序这里会算错。
-- 【移植建议】这类「查表定位」应在读取时断言表有序，或直接改用二分查找。
            if days_survived < v then
                break
            end
            chance_mod = TUNING.DECID_MONSTER_SPAWN_CHANCE_MOD[i + 1]
        end
        if chopper:HasTag("beaver") then
-- 砍伐者修正：海狸与伐木工有加成（第 550、552 行）。用 tag 判定而非类型判定。
-- ⇒ 与第 431 行的砍击音效用同一套 tag，前后一致。
            chance_mod = chance_mod * TUNING.BEAVER_DECID_MONSTER_CHANCE_MOD
        elseif chopper:HasTag("woodcutter") then
            chance_mod = chance_mod * TUNING.WOODCUTTER_DECID_MONSTER_CHANCE_MOD
        end

        --print("Chance is ", chance * chance_mod, TheWorld.state.season)
        if TryLuckRoll(chopper, chance * chance_mod, LuckFormulas.DeciduousMonsterSpawn) then
-- ★★★ TryLuckRoll(chopper, chance*mod, LuckFormulas.DeciduousMonsterSpawn)
-- 这是 DST 概率系统的统一入口：★ 除概率外还吃玩家的 luck 影响。
-- ⇒ 【关键移植要点】直接用 math.random() 做概率判定是错的 ——
-- 它绕过了玩家的幸运值机制（饱食度、装备、雕像等都会改 luck），
-- 玩家会觉得「概率不对」。自研游戏若要做概率玩法，务必留一个统一的 roll 入口。
            --print("Trying to spawn monster")
            local x, y, z = inst.Transform:GetWorldPosition()
            local ents = TheSim:FindEntities(x, y, z, 30, FINDTREETOTRANSFORM_MUST_TAGS, FINDTREETOTRANSFORM_CANT_TAGS)
-- ★ 半径 30 内的 birchnut 都是候选。第 560 行再随机限制 3~4 个一起变。
-- ⇒ 【手感设计】不是整片林子全变，而是「一棵树倒下，感染附近几棵」——
-- 制造「刚刚还是普通树林」的突然恐怖感。
            local max_monsters_to_spawn = math.random(3, 4)
            for i, v in ipairs(ents) do
                if v.leaf_state ~= "barren" and
-- ★ 四重判重：非光秃 / 非怪物 / 无启动任务 / 无停止任务 / 无 domonsterstop 任务。
-- 三个任务字段分别对应第 567、845、890 行 —— 三条异步路径都要排除，否则重复触发。
-- ⇒ 【可移植模式】异步启动前必须检查「是否已在路上」，
-- 且要覆盖所有可能的启动路径（本例有 3 条）。
                    not v.monster and
                    v.monster_start_task == nil and
                    v.monster_stop_task == nil and
                    v.domonsterstop_task == nil then
                    v.monster_start_task = v:DoTaskInTime(math.random(1, 4), delayed_start_monster)
                    if max_monsters_to_spawn <= 1 then
                        break
                    end
                    max_monsters_to_spawn = max_monsters_to_spawn - 1
                end
            end
        end
    end

    if inst.monster then
-- ★★ 怪物树被砍倒：卸掉 combat / deciduoustreeupdater，sg 切到 empty 状态。
-- 第 591-592 行：★ 直接改状态图的 mem 字段（burn_on_electrocute / noelectrocute），
-- 这是在预制体层操作状态图内部状态 —— 属于「越层访问」，但 DST 状态图的 mem 本就是公开表。
-- ⚠️ 【移植注意】同一段代码在第 591、693、711、878、963、1080 行出现了 6 次，
-- 全部是「卸战斗能力 + 改 sg.mem + GoToState(empty)」的复制粘贴。
-- ⇒ 明确的重复代码，提取成 removeCombatCapability(inst) 会好得多。
        inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/deciduous/death")
        inst.components.lootdropper:AddChanceLoot("livinglog", TUNING.DECID_MONSTER_ADDITIONAL_LOOT_CHANCE)
        inst.components.lootdropper:AddChanceLoot("nightmarefuel", TUNING.DECID_MONSTER_ADDITIONAL_LOOT_CHANCE)
        if inst.monster_stop_task ~= nil then
            inst.monster_stop_task:Cancel()
            inst.monster_stop_task = nil
        end
        --V2C: monster flag still needed for stump
        --inst.monster = false
        inst.monster_start_time = nil
        inst.monster_duration = nil
        inst:RemoveComponent("deciduoustreeupdater")
        inst:RemoveComponent("combat")
		inst.sg.mem.burn_on_electrocute = nil
		inst.sg.mem.noelectrocute = true
        inst.sg:GoToState("empty")
        if inst.domonsterstop_task ~= nil then
            inst.domonsterstop_task:Cancel()
            inst.domonsterstop_task = nil
        end
    end

    inst.SoundEmitter:PlaySound("dontstarve/forest/treefall")
-- ★★ 第 602-617 行：按砍伐者在树的左/右侧决定倒向与战利品抛射方向。
-- 第 604 行 (hispos - pt):Dot(TheCamera:GetRightVec()) > 0 —— 用相机右向量做左右判定。
-- ⇒ 【2D/3D 混合】表现上是 2D 侧视，判定却用 3D 相机向量。
-- 代价：玩家转动相机时，同一次砍伐可能算出不同的倒向。可接受，换来的是「树朝你倒」的直觉。
-- ⚠️ 潜在问题：若树与砍伐者同位置（x、z 相同），第 604 行结果为 0，判定为 false 走 fallright。
-- 不会出错，但结果不对称。

    local pt = inst:GetPosition()
    local hispos = chopper:GetPosition()
    local he_right = (hispos - pt):Dot(TheCamera:GetRightVec()) > 0
    if he_right then
        inst.AnimState:PlayAnimation(inst.anims.fallleft)
        if inst.components.growable ~= nil and inst.components.growable.stage == 3 and inst.leaf_state == "colorful" then
            inst.components.lootdropper:SpawnLootPrefab("acorn", pt - TheCamera:GetRightVec())
        end
        inst.components.lootdropper:DropLoot(pt - TheCamera:GetRightVec())
    else
        inst.AnimState:PlayAnimation(inst.anims.fallright)
        if inst.components.growable ~= nil and inst.components.growable.stage == 3 and inst.leaf_state == "colorful" then
            inst.components.lootdropper:SpawnLootPrefab("acorn", pt + TheCamera:GetRightVec())
        end
        inst.components.lootdropper:DropLoot(pt + TheCamera:GetRightVec())
    end

    inst:DoTaskInTime(.4, chop_down_tree_shake)
-- DoTaskInTime(.4, chop_down_tree_shake)：★ 延迟 0.4 秒再震屏。
-- 让玩家先看到树开始倒，再震屏 —— 视听反馈的先后顺序影响体感。

    inst.AnimState:PushAnimation(inst.anims.stump, false)

    make_stump(inst)
end

local function chop_down_burnt_tree(inst, chopper)
-- chop_down_burnt_tree：★ 焦树砍掉后直接消失（不像活树会留树桩）。
-- 第 632 行 ListenForEvent("animover", inst.Remove)：★ 动画播完自动删除。
-- ⇒ 【可移植模式】「一次性实体」的标准写法：不需要 OnRemove 清理，直接挂 animover 删自己。
    inst:RemoveComponent("workable")
    inst.SoundEmitter:PlaySound("dontstarve/forest/treeCrumble")
    inst.SoundEmitter:PlaySound("dontstarve/wilson/use_axe_tree")
    inst.AnimState:PlayAnimation(inst.anims.chop_burnt)
    RemovePhysicsColliders(inst)
    inst:ListenForEvent("animover", inst.Remove)
    inst.components.lootdropper:SpawnLootPrefab("charcoal")
    inst.components.lootdropper:DropLoot()
    if inst.acorntask ~= nil then
        inst.acorntask:Cancel()
        inst.acorntask = nil
    end
end

local function _onburntchanges2(inst)
-- _onburntchanges2：★ 两段式烧毁处理的后半段（延迟 3 帧）。
-- 为什么要延迟？因为 onburntchanges 已经在第 685 行被 DoTaskInTime 调过一次，
-- 而这一段做的是「火已经灭了、该拆组件了」的事。
-- ⇒ 【为什么分两段】推断：给燃烧动画留时间播，避免组件先没导致动画中断。
-- 源码未明说，此为推断。
    if inst.components.burnable ~= nil and inst.components.propagator ~= nil then
        inst.components.burnable:Extinguish()
        inst.components.propagator:StopSpreading()
        inst:RemoveComponent("burnable")
        inst:RemoveComponent("propagator")
    end
end

local function onburntchanges(inst)
-- onburntchanges：★ 拆掉 growable —— 焦掉的树不再生长。
-- 第 666-669 行：★ 战利品清空后按 drop_acorns 决定是否给 10% 概率掉橡子。
-- ⇒ 焦树仍可能掉橡子（种下去能长新树），这是「死亡不等于完全失去」的生态设计。
    inst:RemoveComponent("growable")
    inst:RemoveTag("shelter")
    inst:RemoveTag("cattoyairborne")
    inst:RemoveTag("monster")
    inst.monster = false

    if inst.monster_start_task ~= nil then
        inst.monster_start_task:Cancel()
        inst.monster_start_task = nil
    end
    if inst.monster_stop_task ~= nil then
        inst.monster_stop_task:Cancel()
        inst.monster_stop_task = nil
    end

    inst.components.lootdropper:SetLoot({})
    if GetBuild(inst).drop_acorns then
        inst.components.lootdropper:AddChanceLoot("acorn", .1)
    end

    if inst.components.workable ~= nil then
        inst.components.workable:SetWorkLeft(1)
        inst.components.workable:SetOnWorkCallback(nil)
        inst.components.workable:SetOnFinishCallback(chop_down_burnt_tree)
    end

    if inst.leaveschangetask ~= nil then
        inst.leaveschangetask:Cancel()
        inst.leaveschangetask = nil
    end

    inst.MiniMapEntity:SetIcon("tree_leaf_burnt.png")
-- ★ 换小地图图标为 tree_leaf_burnt.png —— 运行时切换地图图标的三处之一
-- （另两处是第 493 行树桩、第 1423 行树桩初始化）。

    inst.AnimState:PlayAnimation(inst.anims.burnt, true)
    inst:DoTaskInTime(3 * FRAMES, _onburntchanges2)
end

local function _OnBurnt2(inst)
    if inst.monster then
        inst.monster = false
        inst:RemoveComponent("deciduoustreeupdater")
        inst:RemoveComponent("combat")
		inst.sg.mem.burn_on_electrocute = nil
		inst.sg.mem.noelectrocute = true
        inst.sg:GoToState("empty")
        inst.AnimState:SetBank("tree_leaf")
        inst:DoTaskInTime(FRAMES, onburntchanges)
    else
        onburntchanges(inst)
    end
end

local function OnBurnt(inst, immediate)
-- ★★ OnBurnt：immediate 参数区分「自然烧尽」与「主动强制烧毁」。
-- immediate=true 走同步路径（第 705-717 行），false 走 0.5 秒延迟（第 719 行）。
-- 强制烧毁用于状态机（如被雷劈、被怪物点燃），自然烧尽用延迟让特效播完。
-- ⇒ 【可移植模式】「同一效果两种触发方式」时，用一个 immediate 布尔分流，
-- 而不是写两个几乎一样的函数。
    inst:AddTag("burnt")
    if immediate then
        if inst.monster then
            inst.monster = false
            inst:RemoveComponent("deciduoustreeupdater")
            inst:RemoveComponent("combat")
			inst.sg.mem.burn_on_electrocute = nil
			inst.sg.mem.noelectrocute = true
            inst.sg:GoToState("empty")
            inst.AnimState:SetBank("tree_leaf")
            inst:DoTaskInTime(FRAMES, onburntchanges)
        else
            onburntchanges(inst)
        end
    else
        inst:DoTaskInTime(.5, _OnBurnt2)
    end

    if inst.components.timer ~= nil and not inst.components.timer:TimerExists("decay") then
        inst.components.timer:StartTimer("decay", GetRandomWithVariance(TUNING.DECIDUOUS_REGROWTH.DEAD_DECAY_TIME, TUNING.DECIDUOUS_REGROWTH.DEAD_DECAY_TIME * .5))
    end

    inst.AnimState:SetRayTestOnBB(true)
-- SetRayTestOnBB(true)：★ 焦掉的树用包围盒射线检测。
-- ⇒ 【性能优化】树的模型很复杂但焦了之后只要个方块形状参与射线，
-- 玩家砍不动了，可以简化碰撞。属于「按状态降级渲染与物理」的典型。
end

local function OnAcornTask(inst)
    inst.acorntask = nil
    inst.components.lootdropper:DropLoot(math.random() < .5 and inst:GetPosition() + TheCamera:GetRightVec() or inst:GetPosition() - TheCamera:GetRightVec())
end

local function tree_burnt(inst)
-- tree_burnt：★ 与 OnBurnt 分开的烧毁回调（burnable 的 SetOnBurntFn，第 1344 行）。
-- 区别：它额外安排了一个 10 秒后掉橡子的任务（第 736 行）。
-- ⇒ 【命名坑】OnBurnt 是函数（被调），tree_burnt 也是函数（作为回调传入），
-- 名字太像。移植时给回调起名时注意区分「做什么」与「被谁调用」。
    OnBurnt(inst)
    inst.acorntask = inst:DoTaskInTime(10, OnAcornTask)
    if inst.leaveschangetask ~= nil then
        inst.leaveschangetask:Cancel()
        inst.leaveschangetask = nil
    end
end

local function handler_growfromseed(inst)
-- handler_growfromseed：★ 从种子长成小树时的初始化。
-- ★ 第 746-759 行：长出来的树要立刻匹配当前季节（秋=彩色 / 冬=光秃 / 其它=绿）。
-- 推断：世界生成期间 season 可能还没准备好，所以种树要自己判断一次。
    inst.components.growable:SetStage(1)

    if TheWorld.state.isautumn then
        inst.build = ({ "red", "orange", "yellow" })[math.random(3)]
        inst.AnimState:SetMultColour(1, 1, 1, 1)
        inst.leaf_state = "colorful"
        inst.target_leaf_state = "colorful"
    elseif TheWorld.state.iswinter then
        inst.build = "barren"
        inst.leaf_state = "barren"
        inst.target_leaf_state = "barren"
    else
        inst.build = "normal"
        inst.leaf_state = "normal"
        inst.target_leaf_state = "normal"
    end

    --print(inst, "growfromseed, ", inst.target_leaf_state)

    if GetBuild(inst).leavesbuild ~= nil then
        inst.AnimState:OverrideSymbol("swap_leaves", GetBuild(inst).leavesbuild, "swap_leaves")
    else
        inst.AnimState:ClearOverrideSymbol("swap_leaves")
    end
    inst.AnimState:PlayAnimation("grow_seed_to_short")
    if inst.leaf_state == "colorful" then
        SpawnLeafFX(inst, 5 * FRAMES)
    end
    inst.SoundEmitter:PlaySound("dontstarve/forest/treeGrow")
    inst.anims = short_anims

	UpdateIdleLeafFx(inst)
    PushSway(inst)
end

local function inspect_tree(inst)
    return (inst:HasTag("burnt") and "BURNT")
        or (inst:HasTag("stump") and "CHOPPED")
        or (inst.monster and "POISON")
        or nil
end

local function DoStartMonster(inst, starttimeoffset)
-- ★★ DoStartMonster：怪物化的实际执行（延迟 26 帧后由第 845 行触发）。
-- 它做 5 组事：换 bank + 播 transform_in + 换 4 个符号 + 加 combat + 加 treeupdater。
-- ⇒ 与 make_stump（第 482 行）对照：两者都是「同一个实体换形态」的实现，
-- 但怪物化保留了战斗能力而树桩彻底移除 —— 形态转换可以增能力也可以减能力。
	inst.dostartmonster_task = nil
    if inst.components.workable ~= nil then
       inst.components.workable:SetWorkLeft(TUNING.DECIDUOUS_CHOPS_MONSTER)
    end
    inst.AnimState:SetBank("tree_leaf_monster")
    inst.AnimState:PlayAnimation("transform_in")
    inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/deciduous/transform_in")
    inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/deciduous/transform_voice")
    SpawnLeafFX(inst, 7 * FRAMES)
    local leavesbuild = GetBuild(inst).leavesbuild
    if leavesbuild ~= nil then
        inst.AnimState:OverrideSymbol("legs", leavesbuild, "legs")
-- ★ 换 4 个符号（legs / legs_mouseover / eye / mouth）用同一个 leavesbuild 作来源。
-- ⇒ 【美术技巧】怪物的四肢、眼睛、嘴巴都从「叶子贴图」里取 ——
-- 同一张叶子拼图，按不同符号裁出不同部件。这是 DST 的经典「一图多用」。
        inst.AnimState:OverrideSymbol("legs_mouseover", leavesbuild, "legs_mouseover")
        inst.AnimState:OverrideSymbol("eye", leavesbuild, "eye")
        inst.AnimState:OverrideSymbol("mouth", leavesbuild, "mouth")
    else
        inst.AnimState:ClearOverrideSymbol("legs")
        inst.AnimState:ClearOverrideSymbol("legs_mouseover")
        inst.AnimState:ClearOverrideSymbol("eye")
        inst.AnimState:ClearOverrideSymbol("mouth")
    end
    if inst.components.combat == nil then
        inst:AddComponent("combat")
		inst.sg.mem.noelectrocute = nil
		inst.sg.mem.burn_on_electrocute = true

        MakeCollidesWithElectricField(inst)
-- MakeCollidesWithElectricField：怪物树会被电 fence 拦住，普通树不会。
-- 第 880 行 StopMonster 里有配对的 ClearCollidesWithElectricField。
-- ⇒ 【配对范式】第 813 行与第 880 行、第 810 行与第 878 行都是严格配对。
-- 【移植建议】这类「加一个能力」与「减一个能力」的函数应放在一起声明，避免漏掉解除。
    end
    if inst.components.deciduoustreeupdater == nil then
        inst:AddComponent("deciduoustreeupdater")
    end
    inst.components.deciduoustreeupdater:StartMonster(starttimeoffset)
end

local function DoStartMonsterChangeLeaves(inst)
    OnChangeLeaves(inst, true)
    inst.components.growable:StopGrowing()
end

local function StartMonster(inst, force, starttimeoffset)
-- ★★ StartMonster：怪物化的总入口。两个触发源：
--   第 1270 行（OnHaunt 闹鬼触发的稀有事件）与第 1061 行（读档恢复）。
-- force=true 时跳过生长直接变（第 838-839 行），否则先长到最高档再变（第 841-842 行）。
-- ⇒ 「长高 → 变怪」的两段式（第 841、845 行的 12 帧 / 26 帧延迟）是为了给玩家
-- 一个「它要变了」的预警窗口。
    -- Become a monster. Requires tree to have leaves and be medium size (it will grow to large size when become monster)
    if force or (inst.anims == normal_anims and inst.leaf_state ~= "barren") then
-- ★ 判断条件 `inst.anims == normal_anims`：比较的是【表引用】而非名字。
-- 只有当前用的是「中树动画表」且非光秃才变身 —— 即必须是中长势的树。
-- ⇒ 【可移植模式】用「状态对象引用相等」做判断，比用字符串名字比较更可靠。
-- ⚠️ 前提是 anims 只能从那 4 张预计算的表里取（第 353-358 行保证了这点）。
        inst.monster = true
        inst.target_leaf_state = "poison"
        inst:RemoveTag("cattoyairborne")

        if inst.leaveschangetask ~= nil then
            inst.leaveschangetask:Cancel()
            inst.leaveschangetask = nil
        end

        if force then
            OnChangeLeaves(inst, true)
        else
            inst.components.growable:DoGrowth()
            inst:DoTaskInTime(12 * FRAMES, DoStartMonsterChangeLeaves)
        end

		inst.dostartmonster_task = inst:DoTaskInTime(26 * FRAMES, DoStartMonster, starttimeoffset)
    end
end

local function DoStopMonster(inst)
-- DoStopMonster：变回普通树的实际执行（延迟 16 帧，由第 890 行触发）。
-- 第 856 行 StartGrowing：★ 变回来后重新开始生长 —— 树「返老还童」了。
-- ⇒ 与第 827 行原注释 Return to normal tree behavior (also grow from tall to short) 一致：
-- 怪物树的 monster_anims 帧数最多（idle_tall），变回来后按第 1085-1090 行的逻辑重算 anims，
-- 会落到 tall 或 short。整体效果是「怪物死后树变回普通并继续生长」。
    inst.domonsterstop_task = nil
    inst.AnimState:ClearOverrideSymbol("eye")
    inst.AnimState:ClearOverrideSymbol("mouth")
    if not inst:HasTag("stump") then
        inst.AnimState:ClearOverrideSymbol("legs")
        inst.AnimState:ClearOverrideSymbol("legs_mouseover")
        inst.components.growable:StartGrowing()
    end
    inst.AnimState:SetBank("tree_leaf")
    inst:AddTag("cattoyairborne")

    inst.target_leaf_state =
        (TheWorld.state.isautumn and "colorful") or
        (TheWorld.state.iswinter and "barren") or
        "normal"

    inst.components.growable:DoGrowth()
    inst:DoTaskInTime(12 * FRAMES, OnChangeLeaves, false, true)
end

local function StopMonster(inst)
-- StopMonster：怪物化的反向入口（由 OnEntityWake 第 956 行在超时后调用）。
-- ★ 第 887-890 行：只 Cancel 不置 nil 就立刻 DoTaskInTime 赋值 ——
-- 因为 DoTaskInTime 会返回新句柄，所以顺序正确。这与第 496-502 行的写法不同
-- （那里 Cancel 后置 nil 再重新赋值），两种写法都对但不统一。
    -- Return to normal tree behavior (also grow from tall to short)
    if inst.monster then
        inst.monster = false
        inst.monster_start_time = nil
        inst.monster_duration = nil
        inst:RemoveComponent("deciduoustreeupdater")
        inst:RemoveComponent("combat")
		inst.sg.mem.burn_on_electrocute = nil
		inst.sg.mem.noelectrocute = true
        ClearCollidesWithElectricField(inst)
        if not (inst:HasTag("stump") or inst:HasTag("burnt")) then
            inst.AnimState:PlayAnimation("transform_out")
            inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/deciduous/transform_out")
            SpawnLeafFX(inst, 8 * FRAMES)
            inst.sg:GoToState("empty")
        end
        if inst.domonsterstop_task ~= nil then
            inst.domonsterstop_task:Cancel()
        end
        inst.domonsterstop_task = inst:DoTaskInTime(16 * FRAMES, DoStopMonster)
    end
end

local function onignite(inst)
	if inst.monster and not (inst.sg:HasStateTag("electrocute") or inst:HasTag("stump")) then
        inst.sg:GoToState("burning_pre")
    end
    if inst.components.deciduoustreeupdater ~= nil then
        inst.components.deciduoustreeupdater:SpawnIgniteWave()
    end
end

local function onextinguish(inst)
	if inst.monster and not (inst.sg:HasStateTag("electrocute") or inst:HasTag("stump")) then
        inst.sg:GoToState("gnash_idle")
    end
end

local function OnEntitySleep(inst)
-- ★★★ OnEntitySleep：★ DST 性能优化的教科书案例。
-- 树休眠时：
--   ① 若在燃烧中，记住 _wasonfire 并卸 growable（第 910-918 行）
--   ② 卸掉 burnable / propagator / inspectable 三个组件（第 919-921 行）
--   ③ 停掉落叶特效任务（第 923 行）
-- ⇒ 【为什么卸组件而不是关掉】组件的存在本身有开销（事件监听、周期任务、物理体），
-- 远距离休眠的树数以百计，全留着会拖垮服务器。
-- ⇒ 【★ 移植要点】自研引擎必须设计「休眠时卸载能力、醒来时重建」的机制。
-- DST 的做法是：把「这个实体会变成什么样」的推导逻辑（OnEntityWake 第 926 行）写得足够完整，
-- 以至于「醒来后重建」不需要外部通知。
    if inst._wasonfire or (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) then
-- ★ _wasonfire：一个「跨休眠期的临时标志」，用来在醒来时补做烧毁处理。
-- 它在第 987 行（OnEntityWake 末尾）清空 —— 每轮休眠/唤醒周期都会重设。
-- ⇒ 【可移植模式】休眠会丢失内存状态时，用少量布尔字段把「上次的状态」编码下来，
-- 醒来时据此重建。比保存完整状态对象轻得多。
        if inst:HasTag("stump") then
            DefaultBurntFn(inst)
            return
        end
        inst._wasonfire = true
        inst:RemoveComponent("growable")
        inst:RemoveEventCallback("animover", ChangeSizeFn)
    end
    inst:RemoveComponent("burnable")
-- ★ 三个组件被卸载。为什么是这三个？
--   burnable   —— 不会自己烧，卸掉省去火焰模拟
--   propagator —— 不传播火，卸掉省去邻域查询
--   inspectable —— 玩家看不到，不需要「悬停提示」
-- ⇒ 原则很清晰：【休眠时卸掉一切「对外交互」的能力】。
-- 物理（第 512 行的 RemovePhysicsColliders）同理，只是树桩才做而非休眠时做。
    inst:RemoveComponent("propagator")
    inst:RemoveComponent("inspectable")

	UpdateIdleLeafFx(inst)
end

local function OnEntityWake(inst)
-- ★★★ OnEntityWake：与 OnEntitySleep 严格对称，负责重建。
-- 结构：① 重建 burnable/propagator（第 927-949 行）② 处理怪物超时（第 951-966 行）
-- ③ 处理休眠前在燃烧的情况（第 968-980 行）④ 补装 inspectable（第 982-985 行）
-- ⇒ 【⚠️ 移植核心难点】这一段必须与 OnEntitySleep 严格镜像，否则会出现
-- 「醒来后某个能力永久缺失」。本文件用 _wasonfire 覆盖了这个易漏的场景。
    if not (inst._wasonfire or
            (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) or
            inst:HasTag("burnt")) then
        if inst:HasTag("stump") then
            inst:RemoveComponent("burnable")
            MakeSmallBurnable(inst)
            inst:RemoveComponent("propagator")
            MakeSmallPropagator(inst)
        else
            if inst.components.burnable == nil then
                MakeLargeBurnable(inst, TUNING.TREE_BURN_TIME)
-- ★ MakeLargeBurnable 的参数 TUNING.TREE_BURN_TIME 被显式传入。
-- 第 1342 行的首次装配是同样写法 —— 保证重建后与初始一致。
-- ⇒ 【可移植模式】「卸载-重建」必须使用与「初始装配」完全相同的参数，否则状态会漂移。
                inst.components.burnable:SetFXLevel(5)
                inst.components.burnable:SetOnBurntFn(tree_burnt)
                inst.components.burnable.extinguishimmediately = false
-- ★ extinguishimmediately = false：着火后不会立刻熄灭。
-- 这个字段的默认值是 true（即立刻灭），这里显式改成 false 才能正常燃烧。
-- ⇒ 【易踩的坑】Lua 组件的默认值常常「反直觉」，覆写时要看清在改什么。
                inst.components.burnable:SetOnIgniteFn(onignite)
                inst.components.burnable:SetOnExtinguishFn(onextinguish)
            end

            if inst.components.propagator == nil then
                MakeMediumPropagator(inst)
            end
        end
    end

    if inst.monster and inst.monster_start_time ~= nil and inst.monster_duration ~= nil and GetTime() - inst.monster_start_time > inst.monster_duration then
        if not (inst._wasonfire or
                (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) or
                inst:HasTag("burnt") or
                inst:HasTag("stump")) then
            StopMonster(inst)
        else
            inst.monster = false
            inst.monster_start_time = nil
            inst.monster_duration = nil
            inst:RemoveComponent("deciduoustreeupdater")
            inst:RemoveComponent("combat")
			inst.sg.mem.burn_on_electrocute = nil
			inst.sg.mem.noelectrocute = true
        end
    end

    if (inst._wasonfire or
        (inst.components.burnable ~= nil and inst.components.burnable:IsBurning())) and
-- ★ 休眠时正在燃烧的树，醒来后立刻执行 OnBurnt(immediate=true)（第 979 行）。
-- ★ 这解释了第 1115 行的注释：OnLoad 时只设 _wasonfire = true，把活留给 OnEntityWake。
-- ⇒ 【时序理解】读档流程是：OnLoad（轻量、只记标志）→ …… → OnEntityWake（真正重建）。
-- 两者之间的分工让 OnLoad 保持轻量，是 DST 存档性能优化的常见手法。
        not inst:HasTag("burnt") then
        inst.sg:GoToState("empty")
        inst.AnimState:ClearOverrideSymbol("eye")
        inst.AnimState:ClearOverrideSymbol("mouth")
        if not inst:HasTag("stump") then
            inst.AnimState:ClearOverrideSymbol("legs")
            inst.AnimState:ClearOverrideSymbol("legs_mouseover")
        end
        inst.AnimState:SetBank("tree_leaf")
        OnBurnt(inst, true)
    end

    if inst.components.inspectable == nil then
        inst:AddComponent("inspectable")
        inst.components.inspectable.getstatus = inspect_tree
    end

    inst._wasonfire = nil

	UpdateIdleLeafFx(inst)
end

local REMOVABLE =
-- REMOVABLE 表：★ 清理地面杂物时只删这三种。
-- 第 1009 行配合第 1008 行的 FindEntities 用。原注释（第 1006 行）说明了动机：
-- too many objects is as bad for server health as too few!
-- ⇒ 【★ 值得学的心态】对象数量本身就是资源。清理无关杂物与生成重要物件同等重要。
{
    ["log"] = true,
    ["acorn"] = true,
    ["charcoal"] = true,
}

local DECAYREMOVE_MUST_TAGS = { "_inventoryitem" }
-- DECAYREMOVE 的标签过滤：只要是背包物品，排除加载中与火里的。
-- ★ 第 1008 行传了 MUST_TAGS 与 CANT_TAGS 两个表，用引擎的空间索引而非全表遍历。
local DECAYREMOVE_CANT_TAGS = { "INLIMBO", "fire" }
local function OnTimerDone(inst, data)
-- OnTimerDone：★ 树消失的瞬间顺手清理地面 —— 死树不该留一地杂物。
    if data.name == "decay" then
        local x, y, z = inst.Transform:GetWorldPosition()
        if inst:IsAsleep() then
-- ★★ 休眠分支的清理方式完全不同：睡觉时不生成小 puff 特效，只静静清场。
-- 第 1018 行的 SpawnPrefab("small_puff") 只在实体醒着时执行 ——
-- 因为特效是纯客户端表现，休眠的实体没有客户端在看。
-- ⇒ 与第 169 行（SpawnLeafFX 判 IsAsleep）同一原则，判断依据都是「有没有人在看」。
            -- before we disappear, clean up any crap left on the ground
            -- too many objects is as bad for server health as too few!
            local leftone = false
            for i, v in ipairs(TheSim:FindEntities(x, y, z, 6, DECAYREMOVE_MUST_TAGS, DECAYREMOVE_CANT_TAGS)) do
                if REMOVABLE[v.prefab] then
                    if leftone then
                        v:Remove()
                    else
                        leftone = true
                    end
                end
            end
        else
            SpawnPrefab("small_puff").Transform:SetPosition(x, y, z)
        end
        inst:Remove()
    end
end

local function on_cattoyplay(inst, doer, is_airborne)
    SpawnLeafFX(inst)
end

local function onsave(inst, data)
-- ★★ onsave 存了 8 个字段，是本文件状态复杂度的直接体现：
-- burnt / stump / build / monster / monster_start_offset /
-- target_leaf_state / leaf_state / leaveschangetime
-- ⇒ 【重要观察】存的是「状态描述」而非「组件状态」。
-- 组件（growable/burnable/workable）的内部数据由组件自己存。
-- 预制体只存那些「跨组件的复合语义」，比如「当前正在换叶，还剩几秒」。
    if inst.components.burnable ~= nil and inst.components.burnable:IsBurning() or inst:HasTag("burnt") then
        data.burnt = true
    end

    if inst:HasTag("stump") then
        data.stump = true
    end

    if inst.build ~= "normal" then
-- ★ build 只在非 normal 时才存 —— 压缩存档体积的小技巧。
-- 读档端（第 1054 行）用 `data.build ~= nil and builds[data.build] ~= nil and data.build or "normal"`
-- 三重兜底：存在 且 是合法 build 名 才用，否则回退 normal。
-- ⇒ 【★ 存档反序列化的标准范式】任何用户数据回填都要「校验合法性 + 给默认值」，
-- 因为存档可能被旧版本写入、手工编辑、或版本回退污染。
        data.build = inst.build
    end

    data.monster = inst.monster
    if inst.monster and inst.components.deciduoustreeupdater ~= nil and inst.components.deciduoustreeupdater.monster_start_time ~= nil then
-- ★ monster_start_offset 存的是「距开始变怪还剩多久」（第 1043 行）而非绝对时间戳。
-- ⇒ 【★ 存档时间处理】绝不要存 GetTime() 的绝对值（读档后时间基准会变），
-- 必须存相对差值。这是所有带计时器系统的通用要求。
        data.monster_start_offset = inst.components.deciduoustreeupdater.monster_start_time - GetTime()
    end
    data.target_leaf_state = inst.target_leaf_state
    data.leaf_state = inst.leaf_state
    if inst.leaveschangetask ~= nil and inst.targetleaveschangetime ~= nil then
        data.leaveschangetime = inst.targetleaveschangetime - GetTime()
    end
end

local function onload(inst, data)
-- ★★ onload：★★ 恢复逻辑比保存逻辑长 3 倍，且分支极多。
-- 四种组合：正常树 / 怪物树 / 怪物树桩 / 焦树，各自的处理路径不同。
    if data ~= nil then
        inst.build = data.build ~= nil and builds[data.build] ~= nil and data.build or "normal"

        inst.target_leaf_state = data.target_leaf_state
        inst.leaf_state = data.leaf_state

        if data.monster and not (data.stump or data.burnt) then
-- ★ 第 1062-1083 行是「怪物但已砍/已烧」的分支 —— 恢复 monster 标志但不重建能力。
-- 第 586 行原注释 monster flag still needed for stump 说的就是这里：
-- 树桩需要知道自己曾经是怪物树（决定挖出什么，第 462 行）。
-- ⇒ 【★ 状态残留的价值】有时候「已经不成立的能力标志」仍要保留，用于决定后续行为。
-- 移植时容易误以为该清掉 —— 保留它是有意的。
            inst.monster = data.monster
            StartMonster(inst, true, data.monster_start_offset)
        elseif data.monster then
            if data.stump then
                inst.monster = data.monster
                inst.components.growable.stage = 3
                RemoveLunarHailBuildup(inst)
                inst:AddTag("stump")
            elseif not data.burnt then
                inst.monster = false
                inst.target_leaf_state =
                    (TheWorld.state.isautumn and "colorful") or
                    (TheWorld.state.iswinter and "barren") or
                    "normal"

                inst.components.growable:DoGrowth()
                inst:DoTaskInTime(12 * FRAMES, OnChangeLeaves, false)
            end
            inst:RemoveComponent("deciduoustreeupdater")
            inst:RemoveComponent("combat")
			inst.sg.mem.burn_on_electrocute = nil
			inst.sg.mem.noelectrocute = true
            inst.sg:GoToState("empty")
        end

        inst.anims =
-- ★★ 四路分支的顺序与第 353-358 行（ChangeSizeFn）完全一致。
-- ⚠️ 【可改进】这两处逻辑相同却分散在两个函数里，改一处忘另一处会出隐蔽 bug。
-- 建议提取成 `local function pickAnims(inst)` 共用。
            (inst.components.growable == nil and tall_anims) or
            (inst.components.growable.stage == 1 and short_anims) or
            (inst.components.growable.stage == 2 and normal_anims) or
            (inst.monster and monster_anims) or
            tall_anims

        if data.stump then
            if data.monster then
                inst.AnimState:SetBank("tree_leaf_monster")
                if GetBuild(inst).leavesbuild ~= nil then
                    inst.AnimState:OverrideSymbol("legs", GetBuild(inst).leavesbuild, "legs")
                    inst.AnimState:OverrideSymbol("legs_mouseover", GetBuild(inst).leavesbuild, "legs_mouseover")
                    inst.AnimState:OverrideSymbol("eye", GetBuild(inst).leavesbuild, "eye")
                    inst.AnimState:OverrideSymbol("mouth", GetBuild(inst).leavesbuild, "mouth")
                else
                    inst.AnimState:ClearOverrideSymbol("legs")
                    inst.AnimState:ClearOverrideSymbol("legs_mouseover")
                    inst.AnimState:ClearOverrideSymbol("eye")
                    inst.AnimState:ClearOverrideSymbol("mouth")
                end
            end
            inst.AnimState:PlayAnimation(inst.anims.stump)

            make_stump(inst)
            if data.burnt or inst:HasTag("burnt") then
                DefaultBurntFn(inst)
                RemoveLunarHailBuildup(inst)
            end
        elseif data.burnt then
            inst._wasonfire = true--OnEntityWake will handle it actually doing burnt logic
-- ★★ 原注释说 OnEntityWake will handle it actually doing burnt logic。
-- ⇒ 【时序设计】onload 故意「不把焦树做完」，只打 _wasonfire 标记，
-- 让随后的 OnEntityWake 统一处理。这样「读档恢复」与「正常唤醒」共用一条路径，
-- 避免两份逻辑漂移。★ 这是很值得学的存档设计手法。
            RemoveLunarHailBuildup(inst)
        end
    end

    if not inst:IsValid() then
        return
    end

    if data ~= nil and data.leaveschangetime ~= nil then
-- ★ 换叶的剩余时间也恢复（第 1125 行）—— 读档后树继续按原进度换叶。
-- 注意它排除了 burnt/stump 的情况（第 1128 行），因为那两种不会再换叶。
        inst.leaveschangetask = inst:DoTaskInTime(data.leaveschangetime, OnChangeLeaves)
    end

    if data == nil or not (data.burnt or data.stump) then
-- ★ 与第 1129-1139 行的分支：恢复后若 build/leaf_state 不一致就重新换一次，
-- 一致则只补 mouseover 符号与摇摆动画（不重播换叶动画）。
-- ⇒ 【★ 读档体验细节】不重播过渡动画 —— 玩家读档后看到树「正在长叶」会很突兀。
        if inst.build ~= "normal" or inst.leaf_state ~= inst.target_leaf_state then
            OnChangeLeaves(inst)
        else
            if inst.build == "barren" then
                inst:RemoveTag("shelter")
                inst.AnimState:ClearOverrideSymbol("mouseover")
            else
                inst.AnimState:OverrideSymbol("mouseover", "tree_leaf_trunk_build", "toggle_mouseover")
            end
            Sway(inst)
        end
    end

    if inst.monster then
        inst:RemoveComponent("waxable")

    elseif inst.components.waxable == nil then
        MakeWaxablePlant(inst)
    end
end

local function OnSeasonChanged(inst, season)
-- OnSeasonChanged：★ 季节切换时立即换叶（不走随机延迟）。
-- 与 ChangeToSeason（第 1178 行）的区别：季节真正切换是确定的，无需随机。
-- ★ 而 ChangeToSeason 用于「季节长度配置导致的提前预告」（第 1212 行），需要随机延迟
-- 让所有树不同时变色。两种触发源，同一套状态逻辑。
    if not (inst.monster or inst:HasTag("stump") or inst:HasTag("burnt")) then
        if season == SEASONS.AUTUMN then
            if inst.leaf_state ~= "colorful" then
                inst.target_leaf_state = "colorful"
                if inst.leaveschangetask ~= nil then
                    inst.leaveschangetask:Cancel()
                end
                OnChangeLeaves(inst)
            end
        elseif season == SEASONS.WINTER then
            if inst.leaf_state ~= "barren" then
                inst.target_leaf_state = "barren"
                if inst.leaveschangetask ~= nil then
                    inst.leaveschangetask:Cancel()
                end
                OnChangeLeaves(inst)
            end
        elseif inst.leaf_state ~= "normal" then
            inst.target_leaf_state = "normal"
            if inst.leaveschangetask ~= nil then
                inst.leaveschangetask:Cancel()
            end
            OnChangeLeaves(inst)
        end
    end
end

local function ChangeToSeason(inst, targetSeason)
-- ChangeToSeason：★ 带随机延迟的换叶预告。
-- 第 1188 行 time = random(MIN_LEAF_CHANGE_TIME, MAX_LEAF_CHANGE_TIME)。
-- ⇒ 【体验设计】季节到了不是所有树同时变色，而是在一个时间窗内随机错开，
-- 视觉上自然得多。移植时凡是「全局性外观变化」都该加这种随机化。
    inst.target_leaf_state =
        (targetSeason == SEASONS.AUTUMN and "colorful") or
        (targetSeason == SEASONS.WINTER and "barren") or
        "normal"

    if inst.leaveschangetask ~= nil then
        inst.leaveschangetask:Cancel()
    end
    if inst.target_leaf_state ~= inst.leaf_state then
		local time = math.random(TUNING.MIN_LEAF_CHANGE_TIME, TUNING.MAX_LEAF_CHANGE_TIME)
		inst.targetleaveschangetime = GetTime() + time
		inst.leaveschangetask = inst:DoTaskInTime(time, OnChangeLeaves)
    else
        inst.targetleaveschangetime = nil
        inst.leaveschangetask = nil
    end
end

local nextSeason =
-- ★★ nextSeason 表：季节循环的显式映射。
-- ★ 用 or 链代替查表的地方也有（如第 1179-1182、1236-1239 行），
-- 两种写法混用。查表更清晰，or 链更短。移植时建议统一用表。
{
    [SEASONS.AUTUMN] = SEASONS.WINTER,
    [SEASONS.WINTER] = SEASONS.SPRING,
    [SEASONS.SPRING] = SEASONS.SUMMER,
    [SEASONS.SUMMER] = SEASONS.AUTUMN,
}
local seasonlengths =
-- ★ seasonlengths 表：把季节枚举映射到 TheWorld.state 的字段名。
-- ⇒ 【可移植模式】「枚举 → 配置字段名」的映射表，是配置驱动设计的常见手法。
-- 第 1219 行用查表拿到该季节的长度配置字段，再去 TheWorld.state 上取值。
{
    [SEASONS.AUTUMN] = "autumnlength",
    [SEASONS.WINTER] = "winterlength",
    [SEASONS.SPRING] = "springlength",
    [SEASONS.SUMMER] = "summerlength"
}

local function OnCyclesChanged(inst, cycles)
-- OnCyclesChanged：★ 每天检查一次，在季节结束前 3 天开始预告变色。
-- 第 1213 行的双守卫：已有换叶任务（不打断）+ 距结束还早（不处理）。
-- ⇒ 【★★ 值得学的边界处理】第 1223-1225 行的 while 循环处理「某季节长度为 0（禁用）」的情况：
-- 跳过被禁用的季节，继续找下一个有效季节；若绕一圈回到当前季节则什么都不做。
-- 这是关卡定制（如「只有夏天」）下必然要遇到的边界，作者处理得很完整。
    if inst.leaveschangetask ~= nil or TheWorld.state.remainingdaysinseason > 3 then
        return
    end
    local currentSeason = TheWorld.state.season
    local targetSeason = nextSeason[currentSeason]
    if targetSeason ~= nil then
        if TheWorld.state[seasonlengths[targetSeason]] > 0 then
            ChangeToSeason(inst, targetSeason)
        else
            targetSeason = nextSeason[targetSeason]
            while targetSeason ~= currentSeason and TheWorld.state[seasonlengths[targetSeason]] <= 0 do
                targetSeason = nextSeason[targetSeason]
            end
            if targetSeason ~= currentSeason and TheWorld.state[seasonlengths[targetSeason]] > 0 then
-- 双重判断：找到了不同的季节 且 该季节长度 > 0 才换。
                ChangeToSeason(inst, targetSeason)
            end
        end
    end
end

-- Set up leaf state at start of game
local function OnInitSeason(inst)
-- OnInitSeason：★ 生成时的初始季节设定。由第 1427 行直接调用、第 1436 行延迟再调一次。
-- 第 1425-1426 行原注释解释了为什么要调两次：
-- When POPULATING, season won't be valid yet at this point。
-- ⇒ 【★ 重要时序】世界生成期（POPULATING）TheWorld.state.season 还没准备好，
-- 所以延迟一帧重试。移植时凡依赖「世界已就绪」的数据，都要处理这个窗口期。
    if not (inst.monster or inst:HasTag("stump") or inst:HasTag("burnt")) then
        inst.target_leaf_state =
            (TheWorld.state.isautumn and "colorful") or
            (TheWorld.state.iswinter and "barren") or
            "normal" --SPRING AND SUMMER

        OnChangeLeaves(inst)
    end
end

local function onsway(inst, data)
    --NOTE: monster and monsterpost are booleans (hence no "or nil")
    Sway(inst, data ~= nil and data.monster, data ~= nil and data.monsterpost)
end

local function OnHaunt(inst, haunter)
-- ★★ OnHaunt：★ 同一个 hauntable 组件，三种闹鬼结局：
--   ① 常见（第 1252-1257 行）：鬼替你砍一下 → HAUNT_SMALL
--   ② 被注释掉的（第 1261-1267 行，标 #HAUNTFIX）：鬼替你点火 —— ★ 作者主动禁用
--   ③ 极稀有（第 1268-1273 行）：★ 直接让树怪物化 → HAUNT_HUGE
-- ⇒ 【★ 组件组合的极致】普通树 → 被闹鬼 → 变成怪物树。
-- 这条链把「闹鬼」「砍伐」「怪物化」三个系统串起来，中间没有任何专门的衔接代码。
-- 每个系统只管自己的输入输出，组合产生的涌现行为免费获得。
-- ★★ 这就是「组合优于继承」最有说服力的案例。
    local isstump = inst:HasTag("stump")
    if not isstump and
        inst.components.workable ~= nil and
        math.random() <= TUNING.HAUNT_CHANCE_OFTEN then
        inst.components.workable:WorkedBy(haunter, 1)
        inst.components.hauntable.hauntvalue = TUNING.HAUNT_SMALL
        return true
    elseif inst:HasTag("burnt") then
        return false
    --#HAUNTFIX
-- ★★ 第 1260 行 #HAUNTFIX 标记说明这段是被「有意禁用」的（而非废弃）。
-- 本人已核实：#HAUNTFIX 是 Klei 的全库统一标记，共 22 处，遍布 prefabs/ 与
-- standardcomponents.lua（coldfirepit / cookpot / firepit / mound / mushrooms /
-- nightlight / stickheads / telebase_gemsocket 等都有）。
-- ⇒ 说明这是一次覆盖全项目的批量决策（大概率是「鬼魂点火」引发问题被整体关闭），
-- 而非本文件的个别问题。移植时若要恢复该机制，需检查全部 22 处。
-- 禁用原因源码未说明，标为【推断】。
-- ⇒ 【读源码收获】DST 会给「故意禁用的代码」加标记（如 #HAUNTFIX、NOTES(名字)），
-- 保留它们是为了将来可能恢复。删掉这些注释会丢失设计意图。
    --elseif inst.components.burnable ~= nil and
        --not inst.components.burnable:IsBurning() and
        --math.random() <= TUNING.HAUNT_CHANCE_VERYRARE then
        --inst.components.burnable:Ignite()
        --inst.components.hauntable.hauntvalue = TUNING.HAUNT_MEDIUM
        --inst.components.hauntable.cooldown_on_successful_haunt = false
        --return true
    elseif not (isstump or inst.monster) and
        math.random() <= TUNING.HAUNT_CHANCE_SUPERRARE then
        inst:StartMonster(true)
-- ★ StartMonster(true) 的 force=true：闹鬼触发时不需要先长到最高档，直接变。
        inst.components.hauntable.hauntvalue = TUNING.HAUNT_HUGE
        return true
    end
    return false
end

local function makefn(build, stage, data)
-- ★★★ makefn(build, stage, data)：★ 预制体工厂。
-- 三个参数控制三组差异：
--   build —— 颜色系（normal / barren / red / orange / yellow / poison）
--   stage —— 初始长势（0 = 随机 1~3，1/2/3 = 固定短/中/高）
--   data  —— 初始特殊态（"stump" / "burnt" / nil）
-- ⇒ 与 treasurechest.lua 的 MakeChest 同构，但参数是 3 个而非 9 个 ——
-- ★ 差异越少，工厂越好写，但也说明 boat/tree 这类「同族变体」不需要那么多旋钮。
    return function()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddMiniMapEntity()
        inst.entity:AddNetwork()

        MakeObstaclePhysics(inst, .25)
		inst:SetDeploySmartRadius(DEPLOYSPACING_RADIUS[DEPLOYSPACING.DEFAULT] / 2) --seed/planted_tree deployspacing/2
-- SetDeploySmartRadius：★ 部署判定半径 = 配方间距的一半，注释明说这是为了防重叠。
-- 与 treasurechest.lua 第 397 行同一手法：让预制体的放置判定与配方间距一致。
-- ⚠️ 【两处要同步】改了 recipes.lua 里的 min_spacing 却没改这里，放置会异常。

        inst.MiniMapEntity:SetIcon("tree_leaf.png")
        inst.MiniMapEntity:SetPriority(-1)

        inst:AddTag("plant")
        inst:AddTag("tree")
        inst:AddTag("birchnut")
        inst:AddTag("cattoyairborne")
        inst:AddTag("deciduoustree")
        inst:AddTag("shelter")

        inst.build = build
        inst.AnimState:SetBank("tree_leaf")
-- ★★ SetBank("tree_leaf") + SetBuild("tree_leaf_trunk_build")：
-- 「bank」是整套动画，「build」是贴图。★ 长势改变时改 build，怪物化时改 bank（第 791 行）。
-- ⇒ 【★★ 渲染层级归纳】
--   改 bank   → 换整套（如 tree_leaf → tree_leaf_monster）= 形态级变化
--   改 build  → 换贴图（如 tree_leaf_trunk_build）= 细节级变化
--   OverrideSymbol → 换局部符号 = 季节级变化
-- 三层递进，构成 DST 全部的视觉变化手段。移植时照这个层级设计资源系统。
        inst.AnimState:SetBuild("tree_leaf_trunk_build")

        inst.AnimState:Hide("mouseover")
-- ★ Hide("mouseover")：初始隐藏鼠标悬停符号。
-- 因为生成时还不知道季节（第 1427 行 OnInitSeason 决定），先全部藏起来。

        if GetBuild(inst).leavesbuild ~= nil then
            inst.AnimState:OverrideSymbol("swap_leaves", GetBuild(inst).leavesbuild, "swap_leaves")
        end

        inst:SetPrefabName(GetBuild(inst).prefab_name)
-- ★★ SetPrefabName(GetBuild(inst).prefab_name)：6 个 builds 的 prefab_name 全是 "deciduoustree"。
-- ⇒ 这一行是「所有颜色系都是同一个预制体」的官方声明。
-- 客户端、存档、图鉴、配方全都认这一个名字；颜色只是运行时状态。
-- ★★ 【★ 移植核心结论】预制体名 = 身份，外观 = 状态。
-- 想做一个「红色的树」，正确做法是新增一个预制体；
-- 想让这棵树变红，正确做法是改 build 字段 —— 不要混用这两者。

        inst.scrapbook_specialinfo = "TREE"
-- scrapbook_* 元数据（同 boat.lua 第 914 行）。★ scrapbook_proxy = "deciduoustree_tall"
-- 表示图鉴里用「高树」的图代表所有形态。
        inst.scrapbook_overridedata={"swap_leaves", "tree_leaf_green_build", "swap_leaves"}
        inst.scrapbook_proxy = "deciduoustree_tall"
        inst.scrapbook_speechname = inst.prefab

        MakeSnowCoveredPristine(inst)

        --Sneak these into pristine state for optimization
        inst:AddTag("__combat")
-- ★★ 第 1320-1329 行是一个精妙技巧：把 __combat 标签「偷渡」进 pristine 状态。
-- 流程：① SetPristine 之前 AddTag("__combat")（第 1321 行）
--      ② SetPristine（第 1322 行）—— ★ 标签随快照同步到客户端
--      ③ 之后 RemoveTag("__combat")（第 1329 行）
--      ④ PrereplicateComponent("combat")（第 1331 行）
-- 原注释第 1319 行：Sneak these into pristine state for optimization。
-- ⇒ 【★★ 极其值得学的技巧】用「双下划线前缀的临时标签」把一个本不该两端存在的标记
-- 安全地穿过网络快照边界，客户端据此跳过不必要的副本计算。
-- 这解决的是「客户端想优化但服务端不想让客户端知道内部状态」的矛盾。
-- 标签命名用 __ 前缀明确标示「这是内部协议，不要在别处用」，是很好的约定。

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        --Remove these tags so that they can be added properly when replicating components below
        inst:RemoveTag("__combat")

        inst:PrereplicateComponent("combat")
-- ★★ PrereplicateComponent("combat")：★ 告诉引擎「我要预挂这个组件的副本」。
-- 效果：客户端提前建好 combat 组件的空壳，等真正的组件数据同步下来时直接填。
-- 因为此刻 AddComponent("combat") 还没调用（第 809 行才是），这里是「预告」而非「创建」。
-- ⇒ 【★ 移植要点】「客户端优化」不等于「服务端少做事」，而是「客户端提前准备」。
-- 这套机制让「服务端权威」与「客户端省带宽」不再冲突。

		inst.override_combat_fx_size = "large"

        inst:SetStateGraph("SGdeciduoustree")
-- ★ SetStateGraph("SGdeciduoustree") + GoToState("empty")：
-- ★ 树在非怪物态时的状态是 "empty"（什么都不做）—— 因为它本来就不动。
-- 状态图只在怪物化时接管（第 593、713、885、971、1082 行的 GoToState）。
-- ⇒ 【设计】给「静止物体」也挂状态图，是为了在它变成动态物体时能无缝接管。
-- 预先装好状态机，等需要时 GoToState 即可 —— 比临时创建状态机简单得多。
		inst.sg.mem.noelectrocute = true
-- ★ sg.mem.noelectrocute = true：默认不被电 fence 拦（第 810 行怪物化时改成 nil）。
-- sg.mem 是状态图的「记忆」表，预制体可以直接读写。
-- ⇒ 【可移植模式】给状态机一个「记忆」字典，让预制体与状态图交换上下文，
-- 比在两者之间建回调通道更轻。
        inst.sg:GoToState("empty")

        inst.color = .5 + math.random() * .5
-- ★★ inst.color = 0.5 + random()*0.5：每棵树一个随机绿度（0.5~1.0）。
-- 第 1340 行立即染色，第 314 行换叶时会复用这个 color 重新染色。
-- ⇒ 【美术手感】同一片树林有深浅不一的绿，比清一色真实得多。
-- ★ 移植要点：一个随机标量 + SetMultColour 就能消除「复制粘贴感」，性价比极高。
        inst.AnimState:SetMultColour(inst.color, inst.color, inst.color, 1)

        MakeLargeBurnable(inst, TUNING.TREE_BURN_TIME)
-- ★ burnable 四个回调全部显式设置（第 1344-1347 行），没有依赖默认值。
-- ⇒ 【可移植模式】回调宁可不依赖默认值：默认值可能随版本变化，显式写死更稳。
-- 也正因为显式写了，第 937-942 行 OnEntityWake 的重建才能与此处完全一致。
        inst.components.burnable:SetFXLevel(5)
        inst.components.burnable:SetOnBurntFn(tree_burnt)
        inst.components.burnable.extinguishimmediately = false
        inst.components.burnable:SetOnIgniteFn(onignite)
        inst.components.burnable:SetOnExtinguishFn(onextinguish)

        MakeMediumPropagator(inst)

        inst:AddComponent("plantregrowth")
-- ★ plantregrowth 组件：★ 「树死后原地长出新树」的机制。
-- 第 1353 行 SetProduct("acorn_sapling")：掉落的不是树苗而是「橡子树苗」物品。
-- ⇒ 【生态闭环】砍树 → 掉原木 + 橡子 → 种橡子 → 树苗 → 长成树 → 落橡子 → 怪物化。
-- 整条链由 4 个组件（growable / plantregrowth / timer / lootdropper）接力完成。
-- ★ 没有任何一行代码是这个「闭环」，它从组件能力里涌现出来。
        inst.components.plantregrowth:SetRegrowthRate(TUNING.DECIDUOUS_REGROWTH.OFFSPRING_TIME)
        inst.components.plantregrowth:SetProduct("acorn_sapling")
        inst.components.plantregrowth:SetSearchTag("deciduoustree")

        inst:AddComponent("timer")
        inst:ListenForEvent("timerdone", OnTimerDone)

        inst:AddComponent("inspectable")
        inst.components.inspectable.getstatus = inspect_tree

        inst:AddComponent("workable")
        inst.components.workable:SetWorkAction(ACTIONS.CHOP)
        inst.components.workable:SetOnWorkCallback(chop_tree)
        inst.components.workable:SetOnFinishCallback(chop_down_tree)

        inst:AddComponent("lootdropper")

        inst:ListenForEvent("sway", onsway)

        inst.SpawnLeafFX = SpawnLeafFX

        inst:AddComponent("growable")
-- ★★★ growable 组件的完整配置（7 行）：
--   stages        —— 第 420 行的阶段表（含随机时长与转移回调）
--   SetStage      —— 0 表示随机初始档位（第 1375 行的 `stage == 0 and random(1,3)`）
--   loopstages    —— ★ 长到最高档后回落到最低档，循环生长（树不会「长大到死」）
--   springgrowth  —— 春天长得快
--   magicgrower   —— 被魔法催熟
--   StartGrowing  —— 立刻开始
-- ⇒ 【★ 循环生长】loopstages 是这个文件能长期存在的关键：
-- 若不循环，树长到第三档就永远不动了，一局游戏后期所有树都一样高。
-- 【移植要点】长周期成长系统必须处理「到达终点之后怎么办」，
-- 循环 / 衰减 / 变异都是可行解。
        inst.components.growable.stages = growth_stages
        inst.components.growable:SetStage(stage == 0 and math.random(1, 3) or stage)
        inst.components.growable.loopstages = true
        inst.components.growable.springgrowth = true
        inst.components.growable.magicgrowable = true
        inst.components.growable:StartGrowing()

        inst:AddComponent("simplemagicgrower")
-- ★ simplemagicgrower：第 1382 行用 #inst.components.growable.stages 算最后一档。
-- 用 Lua 的 # 取数组长度，而非硬编码 3 —— 以后加一档生长魔法也自动适配。
-- ⇒ 【可移植模式】配置驱动的数量一律从表算，不要硬编码。
        inst.components.simplemagicgrower:SetLastStage(#inst.components.growable.stages)

        inst.growfromseed = handler_growfromseed

        inst:AddComponent("hauntable")
        -- Haunt effects more or less the same as evergreens
        inst.components.hauntable:SetOnHauntFn(OnHaunt)

        inst:WatchWorldState("cycles", OnCyclesChanged)
-- ★★ WatchWorldState × 2：把两个世界事件绑到本实体上。
-- cycles（每天）与 season（每季）。事件到达时回调 onload 之外的那些函数。
-- ⇒ 【机制】entity:WatchWorldState 让实体订阅世界状态变化，
-- 比自己在世界里注册监听再自己清理要安全 —— 实体销毁时订阅自动解除。
        inst:WatchWorldState("season", OnSeasonChanged)

        inst.leaf_state = "normal"

        MakeWaxablePlant(inst)

        inst.StartMonster = StartMonster
-- ★★ inst.StartMonster = StartMonster / inst.StopMonster = StopMonster：
-- ★ 把模块级函数挂到实例上，让别的预制体能调用（见第 1270 行 OnHaunt 调 inst:StartMonster(true)）。
-- ⇒ 【★ 重要约定】预制体通过给 inst 挂函数来「导出自己的 API」，
-- 这就是 DST 里「跨预制体协作」的标准手段。
-- 对比 crabking.lua 第 1638-1676 行的做法：那里把 30 多个内部函数全挂到 inst 上。
-- 【移植建议】这条约定等价于「类的 public 方法」，但没有类、没有继承表。
-- 移植时可以借鉴：Lua 对象 = 一张表，方法直接挂在表上。
        inst.StopMonster = StopMonster
        inst.monster = false

        inst.OnSave = onsave
        inst.OnLoad = onload

        MakeSnowCovered(inst)

        if data == "stump" then
-- ★ data == "stump" 分支：生成时就直接是树桩。
-- 与 make_stump（第 482 行）重复了大部分逻辑 ——
-- ⚠️ 【可改进】这里应该直接调 make_stump(inst) 而非复制一遍。
-- 现状是：改了 make_stump 忘了改这里，两处行为会漂移。
            RemovePhysicsColliders(inst)
            inst:AddTag("stump")
            inst:RemoveTag("shelter")

            inst:RemoveComponent("burnable")
            MakeSmallBurnable(inst)
            inst:RemoveComponent("workable")
            RemoveLunarHailBuildup(inst)
            inst:RemoveComponent("propagator")
            MakeSmallPropagator(inst)
            inst:RemoveComponent("growable")
            inst:AddComponent("workable")
            inst.components.workable:SetWorkAction(ACTIONS.DIG)
            inst.components.workable:SetOnFinishCallback(dig_up_stump)
            inst.components.workable:SetWorkLeft(1)
            inst.AnimState:PlayAnimation(inst.anims.stump)
            inst.MiniMapEntity:SetIcon("tree_leaf_stump.png")
        else
            --When POPULATING, season won't be valid yet at this point,
            --but we want this immediate for all later spawns.
            OnInitSeason(inst)
			inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)
-- ★★ SetFrame(random(GetCurrentAnimationNumFrames()) - 1)：随机起始帧。
-- 目的：让一片树林的摇摆动画不同步。★ 同第 1339 行的随机染色思路一致 ——
-- 消除「复制粘贴感」的两种手段：随机染色 + 随机动画相位。
-- ⚠️ 若 GetCurrentAnimationNumFrames() 返回 1，random(1)-1 = 0，SetFrame(0) 是合法的。
            if data == "burnt" then
                OnBurnt(inst, true)
            else
				inst:AddComponent("cattoy")
-- data == "burnt" 分支：生成即焦树。第 1430 行 immediate=true 走同步路径。
				inst.components.cattoy:SetOnPlay(on_cattoyplay)
				if POPULATING then
-- ★ cattoy 组件：可被猫玩。★ 只有非焦树、非树桩才有（第 1432-1437 行在 else 分支里）。
-- ⇒ 【 delightful 细节】猫能玩树是 DST 的经典彩蛋，通过「普通树加个组件」实现。
-- 玩的时候飘落叶（第 1024 行 on_cattoyplay）—— 一个组件带来了完整的互动。
					--Redo this after season is valid
					inst:DoTaskInTime(0, OnInitSeason)
				end
            end
        end

        inst.OnEntitySleep = OnEntitySleep
-- ★ OnEntitySleep / OnEntityWake 的最后一块拼图（见第 909、926 行）。
-- 放在 fn() 最末尾是有意的：必须确保所有组件都装好了再挂这两个钩子，
-- 否则唤醒时会访问到未初始化的组件。
-- ⇒ 【移植要点】钩子要在对象完全构建后才注册，这是「构造顺序」的最后一步。
        inst.OnEntityWake = OnEntityWake
        inst._wasonfire = nil

        return inst
    end
end

local function tree(name, build, stage, data)
-- ★★ tree() 辅助函数：三行代码把「工厂调用」变成「Prefab 声明」。
-- 与直接写 Prefab(name, makefn(...), assets, prefabs) 等价，只是更短。
-- ⇒ 【★ 读源码提示】看到 tree(...) 就知道是工厂，看 Prefab(...) 就知道是手写。
-- 这是一处轻量语法糖，让末尾的变体声明表一目了然。
    return Prefab(name, makefn(build, stage, data), assets, prefabs)
end

return tree("deciduoustree", "normal", 0),
-- ★★★ return：6 个变体，全部是同一份 makefn 的不同参数组合。
--   deciduoustree          —— stage=0（随机长势），普通色
--   deciduoustree_normal   —— stage=2 固定中树
--   deciduoustree_tall     —— stage=3 固定高树
--   deciduoustree_short    —— stage=1 固定小树
--   deciduoustree_burnt    —— data="burnt" 焦树
--   deciduoustree_stump    —— data="stump" 树桩
--
-- 【★ 为什么颜色系不在这里派生】
-- 因为颜色（red/orange/yellow/barren/poison）不是预制体，是 inst.build 字段的取值。
-- 预制体层面只有 6 个；颜色由季节与怪物化在运行期决定（第 308、830 行）。
-- ⇒ 【★ 再次印证第 1310 行的结论】预制体名 = 身份，外观 = 状态。
--
-- 【★ 与 boat.lua 的对比】
-- boat.lua 派生 23 个预制体（每种船一个名字，因为它们的行为/物理/资产都不同）；
-- 本文件只派生 6 个（同族行为一致，只是初始状态不同）。
-- ⇒ 判定标准：变体之间「行为不同」才派生新预制体，只是「初始状态不同」就用参数 + 同一预制体。
        tree("deciduoustree_normal", "normal", 2),
        tree("deciduoustree_tall", "normal", 3),
        tree("deciduoustree_short", "normal", 1),
        tree("deciduoustree_burnt", "normal", 0, "burnt"),
        tree("deciduoustree_stump", "normal", 0, "stump")