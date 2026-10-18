--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：actions.lua（7092 行，DST 最大的单一脚本文件）
-- 模块：动作系统 / 动作注册表（Action Registry）
-- 职责：回答「玩家能做什么」的唯一入口。包含五层内容：
--   ① 范围与到达距离的校验函数族（1-291 行，共 14 个工具函数）
--   ② Action 基类（294-351 行）—— 约 40 个字段，全部为「可选声明」
--   ③ ACTIONS 表（357-741 行）—— 约 240 个动作的**原型声明**
--   ④ 动作编号与网络映射（743-756 行）—— 把字符串 id 压成整数 code
--   ⑤ 每个动作的 fn / strfn / stroverridefn / validfn / theme_music_fn 实现
--      （768-7092 行）。★ 这 6300 行里 90% 是**同构模板**，只有少数动作
--      有独特的判定链（详见下面 §三「同构模板谱系」）。
--
-- ★★ 全文件最重要的认知：Action 是**原型（prototype）**，不是执行实例。
--   ACTIONS.CHOP 只是「斧头这一类动作的规格说明书」，真正的执行实例是
--   BufferedAction（见 bufferedaction.lua），由 components/playercontroller.lua:4542
--   在玩家按键时用 (doer, target, ACTIONS.CHOP, invobject, pos, ...) 现构造。
--   一个 Action 对象在进程生命周期内**只创建一次**，被成千上万次引用。
--   ⇒ 推论：Action 上任何「每次执行都要重置」的字段都是设计错误。
--
-- ★★ 关于 condition / act 分离 —— 本文件**没有**这两个字段，请勿照搬
--   其他引擎的 Action 设计。DST 的对应机制是三件不同的东西：
--     · fn         —— 执行体（服务端权威），见 307 行 `self.fn = function() return false end`
--     · strfn      —— 「当前这个动作显示成什么字」（纯 UI 字符串）
--     · validfn    —— 额外的**持续**有效性判据（bufferedaction.lua:46 只在
--                    客户端 `not TheWorld.ismastersim` 时才调用）
--   「能不能做」的判定**不在本文件**，而在 componentactions.lua 的
--   COMPONENT_ACTIONS 表（3100+ 行）。那里才是 condition 的等价物。
--   ★ 混淆这两个层次是读 actions.lua 最容易踩的坑。
--
-- 关键符号：
--   Action（基类）, ACTIONS（动作原型表）, ACTION_IDS, ACTION_MOD_IDS,
--   ACTIONS_BY_ACTION_CODE, MOD_ACTIONS_BY_ACTION_CODE, ACTIONS_MAP_REMAP,
--   CLIENT_REQUESTED_ACTION, HIGH_ACTION_PRIORITY,
--   SetClientRequestedAction / ClearClientRequestedAction,
--   MakeRangeCheckFn / DefaultRangeCheck / PickRangeCheck / ExtraPickRange /
--   PhysicsPaddedRangeCheck / CheckFishingOceanRange / CheckRowRange /
--   CheckIsOnPlatform / CheckOceanFishingCastRange / CheckTileWithinRange /
--   CheckInsideGolfGame / ShowPourWaterTilePlacer / ExtraPickupRange /
--   ExtraDeployDist / ExtraDropDist / ExtraPourWaterDist / ExtraHealRange /
--   ArriveAnywhere / ExtraWobyForagingDist / ExtraOpenCraftingRange /
--   DoToolWork / ValidToolWork / CanOpenCharacterSpecificContainer /
--   ShouldBlockGiving / IsFoodSafeToEat / ShouldLOOKATStopLocomotor /
--   ShouldItemMimicBeRevealedFor / TryToSoulhop / COMPARE_WEIGHABLE_TEST
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 bufferedaction.lua —— 动作实例（执行体在这里，不在本文件）
--   参见 componentactions.lua:3108 AddComponentAction —— 动作的第二个注册入口
--   参见 componentactions.lua:3181 CollectActions —— condition 的等价物在这里
--   参见 componentactions.lua:3063-3066 workable 的注册（CHOP/MINE/DIG 的标签判定）
--   参见 componentactions.lua:3209 isvalid_list —— validfn 的第二个注册入口
--   参见 entityscript.lua:1609 PushBufferedAction（客户端预测入口）
--   参见 entityscript.lua:1650 PerformBufferedAction（提交执行 Do()）
--   参见 entityscript.lua:1689 GetBufferedAction（当前动作的查询）
--   参见 entityscript.lua:1563 ClearBufferedAction（打断 → Fail）
--   参见 entityscript.lua:1794 CanDoAction（inherentactions / 标签 / 手持物）
--   参见 entityscript.lua:93 actioncomponents（动作组件的网络同步载体）
--   参见 components/playercontroller.lua:4542 DoAction（客户端按键入口）
--   参见 components/playercontroller.lua:4585 「重复动作」判定（防连点）
--   参见 components/playercontroller.lua:4623 lastheldaction（invalid_hold_action 的消费点）
--   参见 components/playercontroller.lua:4634 DoActionAutoEquip（自动装备白名单）
--   参见 components/playercontroller.lua:5272-5281 OnMapAction（地图动作的鉴权）
--   参见 components/playercontroller.lua:2356 SendRPCToServer(ActionButton, actioncode)
--   参见 components/locomotor.lua:882 PushAction（走路去做的分流）
--   参见 components/locomotor.lua:1079 SetBufferedAction（覆盖旧动作 → Fail）
--   参见 components/locomotor.lua:1452 每帧 IsValid → Clear（移动中的打断）
--   参见 components/locomotor.lua:1466-1487 customarrivecheck 的调度与 invalid 处理
--   参见 components/locomotor.lua:937-942 forced + rangecheckfn 的降级
--   参见 stategraph.lua:405 PreviewAction（客户端预测动画）
--   参见 stategraph.lua:430 StartAction（服务端权威动画）
--   参见 modutil.lua:442 AddAction（模组注册动作）
--   参见 modutil.lua:478 AddComponentAction（模组包装）
--   参见 components/workable.lua:189 ShouldRecoil（反弹判定）
--   参见 components/inventory.lua:1390 Inventory:RemoveItem（RemoveFromOwner 的返回语义）
--   参见 components/inventoryitem.lua:468 RemoveFromOwner
--   参见 components/talker.lua:266 Talker:Say（十参数签名的耦合点）
--   参见 simutil.lua:547 CanEntitySeeTarget（静默失败的判据）
--   参见 componentutil.lua:2087 ShouldItemMimicBeRevealedFor（反伪装守卫）
--   参见 stringutil.lua:331 GetActionString / :434 GetActionFailString
--   参见 prefabs/player_classified.lua:1590 actionmeter（长按进度环）
--   参见 prefabs/wortox.lua:614 TryToPortalHop（BLINK 调用的 doer 方法）
--   参见 behaviourtree.lua（AI 侧的缓冲动作用法：brains/beefalobrain.lua:171）
--   参见 locomotor.lua（表现层与动作层的交接）
--============================================================
--
--【阅读导航】
--  §零   范围与距离函数族（8-291） —— ★★ 「距离」在本文件有三套并存的语义
--  §一   Action 基类（294-351） —— ★★ 原型对象，40 个可选字段
--  §二   ACTIONS 表 · 基础动作（357-460）
--  §三   ACTIONS 表 · 物品/容器动作（461-570）
--  §四   ACTIONS 表 · 船只/钓鱼/农场（571-741）
--  §五 ★ 动作编号与网络映射（743-764） —— code 是联机同步的唯一标识
--
--【★★ 全文件最重要的八条】
--  1. ★★ Action 是**原型**，BufferedAction 才是**实例**。见文件头。
--  2. ★★ 本文件没有 condition/act 字段。DST 的「能不能做」在
--     componentactions.lua:3181 CollectActions 里，「做了什么」在 fn。
--     本文件负责的第三件事是「显示成什么字」—— strfn / stroverridefn。
--  3. ★★ 距离三语义（同一个动作里可以同时出现三个不同的距离）：
--     · distance      —— 走到多远就停（ locomotor.arrive_dist）
--     · extra_arrive_dist —— 在 distance 之上再加的**固定余量**，
--                          由一个 (doer, dest, act) → number 的函数算出
--     · mindistance   —— 近到多少就**不能**做了（反向约束）
--     ★ 464 行 WAX 同时用了 mindistance=1.5，说明「太近了也不行」
--       是合法需求（涂蜡要能看清蜡面）。
--  4. ★ priority 不是排序键，是**同层抢占仲裁**。见 HIGH_ACTION_PRIORITY
--     的注释（353-354）：高优先级动作被期望「一旦可用就压过一切」，
--     且不允许两个 HIGH_ACTION_PRIORITY 动作同时可用。
--     ⇒ 遵守这条不变量是模组作者的责任，框架不校验。
--  5. ★ instant 的语义是「不进入状态图的长动作流程」—— locomotor.lua:945
--     直接 PushBufferedAction → entityscript.lua:1640 立即 Do()。
--     于是 instant 动作**没有取消时机**，点下去就执行完了。
--     ★ 因此所有需要「按住」的动作都必须 instant=false。
--  6. ★ invalid_hold_action 的作用（见 339 行）:让 playercontroller 不把
--     该动作记进 lastheldaction（4623 行），从而禁止「长按重复触发」。
--     ★ 与 instant 相反：instant=true 会自动断开放任意重复。
--  7. ★★ 失败原因字符串是动作契约的一部分。fn 的第二个返回值 reason
--     会被 stringutil.lua:434 GetActionFailString 翻译成玩家能看懂的话。
--     常见约定：大写 = 通用失败码；小写 = 专有。
--     ★ 这也是本文件里 400+ 处 `return false, "XXX"` 的意义。
--  8. ★★ 「静默失败」是本文件的第一大设计模式。形如：
--       if CanEntitySeeTarget(doer, target) then 真的去做 end
--       return true   ← 无论如何都返回 true
--     为什么？因为这些动作要经过**走过去**的异步过程，条件在途中可能失效；
--     若返回 false，玩家会看到「不能这么做」的语音与抖动 UI，体感极差。
--     于是选择：条件失效 → 什么都不做，但告诉系统「成功了」。
--     ★ 代表位置：1120/2806/4075/4335/4418/6054/6098。
--
--【⚠ 疑似缺陷清单（本文件 18 条，均只记录不修改）】
--  —— 严重级（可导致崩溃或物品损失）——
--  L1 ★★★ actions.lua:3461  运算符优先级 bug（DIRECTCOURIER_MAP 校验）
--                    ⇒ 非沃尔特玩家（无 skilltreeupdater 组件）必崩；
--                      且「技能未激活」的检查完全失效。同一文件 1025 行有正确范例。
--  L2 ★★  actions.lua:2789-2790 CHANGEIN 的 and/or 优先级错误
--                    ⇒ act.target 为 nil 时对 nil 取 .components 崩溃。
--  L3 ★★  actions.lua:1146   RUMMAGE.strfn 对 mount 无 nil 保护
--                    ⇒ 玩家点自己且未骑乘时崩。strfn 每帧可能被调用。
--  L12 ★★  actions.lua:4805   BATHBOMB 对可能为 nil 的返回值直接取方法
--                    ⇒ RemoveItem 返回 nil 时崩溃。与全文件 12 处同类写法不一致。
--  L16 ★★  actions.lua:5612   YOTB_UNLOCKSKIN 先 Remove 物品再 return false
--                    ⇒ 重复解锁已知皮肤会白白损失道具（玩家可见的物品损失）。
--  —— 中等级（行为异常但不易触发）——
--  L6 ★★  actions.lua:2747   HITCH.fn 无返回值 ⇒ 报告失败（但副作用已生效）
--  L9 ★★  actions.lua:1730   DoToolWork 在 1731 行只 return false（无 reason）
--                    ⇒ 「目标不可干」时 CHOP/MINE/HAMMER/DIG 反而 report 成功。
--  L10 ★★  actions.lua:6284   WOBY_PICK.validfn 语义与其自身注释完全相反
--                    ⇒ 若字面生效，狗的 AI 采摘无法开始。
--  L14 ★★  actions.lua:3299 / 3374  USEITEM 系把 IsOpenedBy(doer) 用作
--                    「手里拿着东西」的判据 ⇒ 对玩家几乎恒假。两处一致。
--  L15 ★★  actions.lua:4335   BUNDLE 的 CanEntitySeeTarget(doer, doer)
--                    ⇒ 恒为真，打包动作的「黑暗中静默失败」完全失效。
--  L17 ★   actions.lua:5679   STOP_LIFT_DUMBBELL.fn 无返回值
--  L18 ★   actions.lua:6534   ADD_CARD_TO_DECK 取出的局部变量 invobject 未被使用
--  —— 轻微级（风格 / 一致性 / 重构建议）——
--  L4  ★   actions.lua:1475   CHANGE_TACKLE 传 act.invobject 而非 item
--                    （已核对：当前不是缺陷，但依赖 1470 行的 acceptsstacks 前置）
--  L5  ★   actions.lua:1871   NET.fn 末尾无条件 return true（粗糙的静默失败）
--  L7  ※   actions.lua:3887   CATPLAYGROUND 的 end 缩进错位（结构正确但可读性差）
--  L8  ※   actions.lua:57-66  PhysicsPaddedRangeCheck 死代码（作者已自行标注）
--  L11 ※   actions.lua:2189  注释掉的 print 遗留
--  L13 ※   actions.lua:758    IsItemInReadOnlyContainer 定义为 local 却从不使用
--                    （其真实对应物在 componentutil.lua:2080）
--  —— 未编号的其它发现（详见各段标注）——
--  · ACTIONS 表的 action.code 由字母序决定（745 行 orderedPairs）
--    ⇒ **插入新动作会让后面所有 code 偏移**，这是未被任何注释记录的隐式协议。
--  · 「海洋瓦片 + 不可通行」判定在 49/158/181/216/4026 五处重复抄写。
--  · 「工具不被 restricted」检查在 1688/1736/6631 三处复制。
--  · ValidToolWork 四条件双写（1688 vs 1736）→ 若加条件会漏同步。
--  · talker:Say 的十参数写法在 1234/1252 两处逐字重复。
--  · talker:Say 十参数中「nil 算成功」的三态容忍模式在 3086/6918 两处重复。
--  · REPLATE.fn 的场景②③（5274/5294）、DECORATESNOWMAN 的模式②③（6108/6135）、
--    CHANGE_TACKLE 的三级回退（1494/2546/6353）均为未抽取的重复。
--  · USESPELLBOOK.strfn 有 dogrider 而 CLOSESPELLBOOK.strfn 没有（5890 vs 5960）。
--  · 5530/4518 的 ITEMMIMIC 守卫位置不一致（在 waxable 之后 vs CanCast 之后）。
--
--【★ 同构模板谱系 —— 6300 行实现只用了 12 种形状】
--  T1 纯转发（占绝大多数，约 300 个动作）:
--        if act.target.components.X ~= nil then act.target.components.X:Y(...) end
--        ★ 举一反三：CHECKTRAP/SUMMONGUARDIAN/MOLEPEEK/CYCLE/ADVANCE_TREE_GROWTH
--        这类动作的全部逻辑就是这一句，读懂一个就懂了一百个。
--  T2 二段式检查 + reason:
--        local ok, reason = comp:CanX(...); if not ok then return false, reason end
--        ★ 举一反三：HERD_FOLLOWERS / BEDAZZLE / GRAVEDIG / MUTATE /
--        UPGRADE / DISMANTLE_POCKETWATCH
--  T3 ITEMMIMIC 前置守卫（2026 年新增的统一反伪装检查）:
--        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
--            return false, "ITEMMIMIC"
--        ★★ 全文件出现 **26 次**，是新增模组动作的强制接入点。
--        ★ 为什么放在 fn 开头而不是 condition？因为伪装检测需要运行时状态。
--  T4 「先问 Can，再问 Is」的双检（对应 condition 与 act 分离）:
--        TURNON/TURNOFF 查 machine:IsOn()，ACTIVATE 查 CanActivate/DoActivate
--  T5 状态图驱动（fn 只做 GoToState，逻辑在 stategraph 里）:
--        JUMPIN / CLIMB / SITON / TELEPORT / OCEAN_FISHING_STOP / CATCH
--        ★★ 这类动作的 fn 返回 true 但什么都不「做」，因为表演在 SG 里。
--        ★ WINTERSFEAST_FEAST(5198) 是极端例子：整个函数体只有 return true
--          与一句「Logic is handled from stategraph」的注释。
--  T6 _FAIL 影子动作（8 个）:
--        SING_FAIL / LOWER_SAIL_FAIL / ROW_FAIL / APPLYMODULE_FAIL /
--        REMOVEMODULES_FAIL / PLANTREGISTRY_RESEARCH_FAIL /
--        LIFT_GYM_FAIL / MAPSCOUT_MAP_TOOFAR
--        ★★ 为什么要影子动作？因为失败反馈（说话、扣血、掉耐久）发生在
--          stategraph 的某个特定状态里。用一个专门的动作 id 路由过去，
--          就能复用同一段状态而不用在 fn 里塞副作用。
--        ★ 这是 DST 里「把失败也建模成一个动作」的通用手法。
--  T7 「target 或 invobject」双向（12 个）:
--        local x = act.target or act.invobject   ← 同一动作两种发起方式
--        ★ 举一反三：RUMMAGE / TELLSTORY / WRITE / UNWRAP / SHAVE / HEAL /
--        STARTREMOVINGMODULE / MAPSCOUT_SELECT 等。
--  T8 force-move（forced + rangecheckfn）:
--        locomotor.lua:930 会在动作开始前用 rangecheckfn 重测距离，
--        不通过就把 target 置 nil（=「够不着，改为走到坐标」）。
--        ★ 只对 canforce~=nil 的动作启用（320 行），共 13 个。
--  T9 地图重映射（maponly_checkvalidpos_fn，8 个）:
--        在地图上点的动作，统一约定用一个 fn 校验「这个坐标能不能用」，
--        返回 (valid, reason, x, z, entity)。stroverridefn 与 fn 都调它。
--        ★ 单一真源，避免 UI 显示与实际执行不一致。
--  T10 pre_action_cb（客户端钩子，10 个）:
--         在动作**开始前**跑，且可能跑在客户端。用途只有两类：
--         关 HUD 弹窗（STEER_BOAT / USESPELLBOOK / GOLF_START_AIMING）
--         与清手柄状态（APPLYMODULE / STARTREMOVINGMODULE）。
--  T11 消耗道具（remove → 尝试 → 失败则还回）:
--         这是本文件的**通用事务模板**，出现在 COOK / DRY / ADDFUEL /
--         PLANT / BAIT / DRAW_FROM_DECK 等。正确性全靠「还回」那一步。
--  T12 强制成对（fn 相同、字符串不同）:
--         WATER_TOSS=TOSS / ADDWETFUEL=ADDFUEL / DEPLOY_FLOATING=DEPLOY /
--         POUR_WATER_GROUNDTILE=POUR_WATER / STOPUSINGEQUIPPEDITEM 的 strfn
--         ★ 为什么要拆成两个动作？因为它们的 `priority` 与 `rmb` 不同，
--           而 fn 可以直接复用（Lua 里 `A.fn = B.fn` 是值拷贝指针）。
--
--★ actions.lua 的 6 个 require 说明它在整个启动序列中的位置：
--   class          → Action 基类的元类
--   bufferedaction → ★ 只为了在 1277/3642/4003/4030 处 new 出实例
--                   （地图动作重映射时构造替代动作）
--   debugtools     → 301 行 debugstack_oneline（只在模组用旧式位置参数时触发）
--   util / vecutil → 常规数学与向量工具
--   components/embarker → 让本文件能读写 embarker 组件（标记地标用）
--★ 注意：actions.lua **不 require locomotor / playercontroller / inventory**。
--   它只通过 `act.doer.components.xxx` 的形式在运行时去摸组件，
--   所以加载顺序上它可以是整个组件体系之前的第一批文件。
require "class"
require "bufferedaction"
require "debugtools"
require 'util'
require 'vecutil'
require ("components/embarker")

--★★【范围校验函数族 —— 本节是全文件最被低估的 280 行】
--   它们回答一个问题：「玩家离目标**现在**够不够近？」
--   ★★ 但更重要的是：这些函数**只做判断，不做移动**。
--     移动由 locomotor 的 arrive_dist 负责，判断由这里的 rangecheckfn 负责，
--     两者是不同的层。搞混就会出现「判定说够近但角色还在走过去」。
--
--★ 命名约定（13 个函数，无一例外）：
--   XxxRangeCheck  —— 返回 **布尔**，用于 canforce 动作的「强制够不着就降级」
--   ExtraXxxRange / ExtraXxxDist —— 返回 **数字**，用于加大 arrive_dist
--   CheckXxx      —— customarrivecheck，返回 (reached_dest, invalid)
--★ 三者的返回值语义完全不同，混用会直接导致动作不执行或立刻执行。
local function MakeRangeCheckFn(range)
--★ 工厂函数而不是直接写死：只有需要「不同距离的同款判断」时才 new 一个。
--   全文件共调用两次：16 行的 4 格，以及 700/703 行的 7 格。
--   ★ 若不需要闭包环境，直接 `return doer:IsNear(target, 4)` 就够了。
	return function(doer, target)
--★★ target 为 nil 时**返回 nil 而不是 true**。
--   在 Lua 里 nil 与 false 同样为假，但作者坚持写 if 而非 `and`，
--   是为了让「无目标」这个语义在阅读时一眼可见。
--   ⚠ 注意：这个 nil 会被 320 行当作「不设 rangecheckfn」的信号之一。
		if target then
			return doer:IsNear(target, range)
		end
	end
end

--★★【DefaultRangeCheck = 4 格】—— 这是全游戏的默认交互距离基准。
--   ★ 它的数值出现在 2 处：ATTACK 的行尾注释（364 行说明攻击范围
--     「already handles that」）与 STEAL.fn:811 的 `GetDistanceSqToInst < 16`
--     （4*4）。
--   ★★ 811 行那个 16 是**手抄的魔数**，与这里的 4 没有任何代码关联。
--     改 DefaultRangeCheck 不会同步 STEAL 的范围。这是一处真实的耦合缺失。
local DefaultRangeCheck = MakeRangeCheckFn(4)

--★★【PickRangeCheck —— 全文件唯一一处「按目标体积算范围」的判断】
--   为什么需要它？因为世界上的可拾取物大小差异极大：
--     · 树（半径 1~2）    → 需要走近 4 格
--     · 眼骨（半径 ~0.3） → 4 格太远，捡不起来，手感差
--   于是判据改成「目标的物理半径 + 4 + 武器额外范围」。
--   ★★ 这意味着**大目标比小目标允许更远的距离**——反直觉但是对的：
--     大目标的碰撞体本身就是「你至少要碰到它这么大一块地方」。
local function PickRangeCheck(doer, target)
    if target == nil then
        return
    end
    local extrarange = 0
--★ jostle* 系列标签是「翻找/搜刮」动作（拾取时附带翻找效果）的标记。
--   携带这些标签的目标会额外加上武器的攻击距离。
--   ★ 条件极长（3 层嵌套）的典型：因为它同时要满足
--     「有 combat 副本」「有标签」「拿得出武器」三个独立条件。
--   ★ 副本（replica.combat）而非组件：因为玩家侧也要做这个判断。
    if doer.replica.combat then
        if target:HasAnyTag("jostlepick", "jostlerummage", "jostlesearch") then
            extrarange = doer.replica.combat:GetWeaponAttackRange()
        end
    end
    local target_x, target_y, target_z = target.Transform:GetWorldPosition()
    local doer_x, doer_y, doer_z = doer.Transform:GetWorldPosition()
--★★ target_r = 目标物理半径 + 4 + 武器范围，再平方比较。
--   ★ 用 distsq（距离平方）而不是 Dist，避免每帧开根号。
--     这类「每帧对每个候选目标调用」的热路径必须走平方距离。
--   ★ GetPhysicsRadius(0) 的参数 0 表示「用真实碰撞半径」——
--     locomotor.lua:1004 有对应注释：忽略 physicsradiusoverride。
--     原因是覆盖半径是为了**防碰撞**而放大的，不代表实际能触及的距离。
    local target_r = target:GetPhysicsRadius(0) + 4 + extrarange
    local dst = distsq(target_x, target_z, doer_x, doer_z)
    return dst <= target_r * target_r
end

--★★【ExtraPickRange —— 「走近一点才能捡」的距离余量】
--   签名 (doer, dest, bufferedaction) 与 RangeCheck 家族不同：
--   ★★ 第一个参数是 dest（目标点）而非 target（实体）。
--     因为函数体里用 `dest:GetPoint()`，说明它可能在实体不存在时
--     也能工作（纯地面点）。见 48 行 dest:GetPoint() 与 48 行的 nil 检查。
local function ExtraPickRange(doer, dest, bufferedaction)
    local extrarange = 0
    if bufferedaction then
        if bufferedaction.target then
            if doer.replica.combat then
--★★ 这段 4 层嵌套 if 完全可以展平成一个 and 链，作者选择保留嵌套
--   是因为它想强调「逐步收窄信息」：
--     bufferedaction → .target → 有标签 → 有 combat → 拿到武器。
--   ★ 展平后会变成一行 130 字符的表达式，反而更难验证 nil 短路顺序。
                if bufferedaction.target:HasAnyTag("jostlepick", "jostlerummage", "jostlesearch") then
                    extrarange = doer.replica.combat:GetWeaponAttackRange()
                end
            end
        end
    end
--★ 有 dest 才谈得上「这个点在不在水上」。无 dest（纯实体动作）不加余量。
	if dest ~= nil then
		local target_x, target_y, target_z = dest:GetPoint()

--★★【海面判定 = 「是海洋」且「不可通行」】
--   两个条件缺一不可：
--     · 海洋瓦片（IsOceanTileAtPoint）→ 覆盖了 boat（船地板也是海洋瓦片）
--     · 不可通行（not IsPassableAtPoint）→ 排除船，把真正的开阔水面留下
--   ★ 于是「站在船上捡东西」不会触发 +0.75 的余量，「从船上扔东西到水里」会。
--     这套双重判定在 154/158/212/216/181 五处重复出现，是本文件最密集的
--     重复模式之一（拼写甚至完全一致）。
		local is_on_water = TheWorld.Map:IsOceanTileAtPoint(target_x, 0, target_z) and not TheWorld.Map:IsPassableAtPoint(target_x, 0, target_z)
		if is_on_water then
			return 0.75 + extrarange
		end
	end
    return 0 + extrarange
end

--⚠疑似缺陷 L8：PhysicsPaddedRangeCheck 从未被调用。
--   作者自己在行尾写了 `-- Currently unused.`。
--   ★★ 它与 PickRangeCheck(18 行) 几乎完全相同，唯一差别是**不叠加武器范围**。
--     推测是早期版本 PickRangeCheck 还没长出 extrarange 分支时的副本。
--   保留死代码的成本：读者会以为「物理感知范围」是可用能力，
--     从而写出拿不到距离加成的 mod 动作。
local function PhysicsPaddedRangeCheck(doer, target) -- Currently unused.
    if target == nil then
        return
    end
    local target_x, target_y, target_z = target.Transform:GetWorldPosition()
    local doer_x, doer_y, doer_z = doer.Transform:GetWorldPosition()
    local target_r = target:GetPhysicsRadius(0) + 4
    local dst = distsq(target_x, target_z, doer_x, doer_z)
    return dst <= target_r * target_r
end

--★★【CheckFishingOceanRange —— customarrivecheck 家族的第一个样本】
--   ★★★ 重要：customarrivecheck 的返回值是二元组 (reached_dest, invalid)，
--     **不是**单布尔。这是 locomotor.lua:1467 决定的：
--       reached_dest, invalid = action.customarrivecheck(inst, dest, act)
--     随后 1487 行 `if invalid then Stop(); Clear(); return end` ——
--     ★ invalid=true 的语义是「动作作废」，与 reached_dest=true「可以执行」
--       是完全相反的方向。写错会导致「永远走不到」或「永远立刻执行」。
--   ★★ 四个家族的返回值约定各不相同，必须逐一核对：
--     · CheckFishingOceanRange → (bool, bool)  —— 真·customarrivecheck
--     · CheckIsOnPlatform      → (bool,)        —— 只当 true 用
--     · CheckInsideGolfGame    → (bool,)        —— 同上
--     · maponly_checkvalidpos_fn → (bool, reason, x, z, ent) —— 不是这一族
local function CheckFishingOceanRange(doer, dest)
--★ 三个局部变量连成一条：doer 位置 → 目标点 → 方向向量。
--   接下来只做一件事：从 doer 出发朝目标走 0.25+r 处的那个「探针点」。
	local doer_pos = doer:GetPosition()
--★ Vector3(dest:GetPoint()) —— dest 是 Point（2 维 + 高度）转成 3 维向量。
--   高亮 dest 而非 Point：Point 是「地面上的一个格子」，Vector3 是「空间位移」。
	local target_pos = Vector3(dest:GetPoint())
	local dir = target_pos - doer_pos

--★★【探针点 = doer 位置 + 归一化方向 × (自身半径 + 0.25)】
--   这是整个自定义到达检查家族的**通用手法**，全文件出现 3 次
--   （73 / 90 / 108），差别只在最后的 0.25 还是 1.5。
--   ★★ 为什么要探针而不是直接问「目标点是什么地形」？
--     因为真正要判断的是「**从角色到目标之间的第一步**踩在什么上」。
--     角色站在岸边、目标是水里 ⇒ 探针落在水上 ⇒ 该抛竿不能抛。
--   ★ 0.25 = 探针刚离开自身碰撞体；108 行的 1.5 则要求探针离得更远，
--     因为抛竿要有一段助跑空间。
	local test_pt = doer_pos + dir:GetNormalized() * (doer:GetPhysicsRadius(0) + 0.25)

--★★ 分支的核心：「探针下面**有没有可站的地面**」。
--   有地面 → 继续看这地面上有没有虚拟海洋实体（船就是海洋）。
--   没地面（悬空/虚空）→ 直接放行，因为虚空区域允许玩家作业。
--   ★ 顺序不可交换：`or` 的短路保证了 IsVisualGround 失败时不会去查平台。
    if TheWorld.Map:IsVisualGroundAtPoint(test_pt.x, 0, test_pt.z) or TheWorld.Map:GetPlatformAtPoint(test_pt.x, test_pt.z) ~= nil then
--★ FindVirtualOceanEntity 是 TheSim 的查询，找出「看起来是海洋的实体」。
--   用实体而非地形来问「是不是水」，是为了区分船地板与真海面。
        if FindVirtualOceanEntity(test_pt.x, 0, test_pt.z) ~= nil then
            return true
        end

		return false
	else
        return true
	end
end
--★ CheckRowRange —— 划船。与钓鱼的差别只有一处：
--   只查 GetPlatformAtPoint（有没有船板），不查海洋实体。
--   因为玩家划船时只要脚下有平台就是船上，桨不应该扔进海里。
local function CheckRowRange(doer, dest)
	local doer_pos = doer:GetPosition()
	local target_pos = Vector3(dest:GetPoint())
	local dir = target_pos - doer_pos

	local test_pt = doer_pos + dir:GetNormalized() * (doer:GetPhysicsRadius(0) + 0.25)

--★ 注意这里是反过来的：探针**有**平台 ⇒ 返回 false（不许划）。
--   玩家站在跳板（walkingplank）上时不能划桨 —— 与钓鱼的语义正好相反。
--   ★ 这说明 customarrivecheck 的 true/false 含义**逐个动作不同**，
--     不能靠函数名推断。看它的调用点与 fn 才是可靠办法。
    if TheWorld.Map:GetPlatformAtPoint(test_pt.x, test_pt.z) ~= nil then
		return false
	else
        return true
	end
end

--★★ CheckIsOnPlatform —— 全文件最短的 customarrivecheck（只有 2 行）。
--   它甚至**不看 dest**：只看 doer 自己是不是站在船上。
--   对应 BOARDPLATFORM（568 行），fn 也就是 `return true`（1380 行）。
--   ★★ 这是「动作本身没有任何逻辑，纯粹靠 customarrivecheck 决定何时触发」
--     的极端样本。fn 是空的，全部语义在到达判定里。
local function CheckIsOnPlatform(doer, dest)
    return doer:GetCurrentPlatform() ~= nil
end

--★ CheckOceanFishingCastRange 与 CheckFishingOceanRange 结构完全相同，
--   只有探针距离从 0.25 变成 1.5（见 108 行）。
--   ⚠疑似缺陷：这 11 行是纯复制粘贴。若日后要修 bug 需同时改两处。
local function CheckOceanFishingCastRange(doer, dest)
	local doer_pos = doer:GetPosition()
	local target_pos = Vector3(dest:GetPoint())
	local dir = target_pos - doer_pos

	local test_pt = doer_pos + dir:GetNormalized() * (doer:GetPhysicsRadius(0) + 1.5)

    if TheWorld.Map:IsVisualGroundAtPoint(test_pt.x, 0, test_pt.z) or TheWorld.Map:GetPlatformAtPoint(test_pt.x, test_pt.z) ~= nil then
        if FindVirtualOceanEntity(test_pt.x, 0, test_pt.z) ~= nil then
            return true
        end

		return false
	else
        return true
	end
end

--★★【CheckTileWithinRange —— 「格子级」到达判定，与前三个的思路完全不同】
--   前三个都用「探针 + 地形查询」，这一个直接问「目标格子的中心离我多远」。
--   ★ 因为 POUR_WATER_GROUNDTILE / DEPLOY_TILEARRIVE 的目标不是实体而是**格子**，
--     必须把坐标吸附到 TILE_SCALE 的格网上才有意义。
--   ★ TILE_SCALE * 0.5 = 半格宽，即「我只要在这一格内就算到位」。
local function CheckTileWithinRange(doer, dest)
	local doer_pos = doer:GetPosition()
	local target_pos = Vector3(dest:GetPoint())

    local tile_x, tile_y, tile_z = TheWorld.Map:GetTileCenterPoint(target_pos.x, 0, target_pos.z)
    local dist = TILE_SCALE * 0.5
    if math.abs(tile_x - doer_pos.x) <= dist and math.abs(tile_z - doer_pos.z) <= dist then
        return true
    end
end

--★★【CheckInsideGolfGame —— 把「地标」语义带进到达判定】
--   唯一用到 bufferedaction.target.IsInGolfArea 这个**实体方法**的检查。
--   高尔夫球场的球洞是逻辑区域而非实体，所以面积判定要问目标自己。
local function CheckInsideGolfGame(doer, dest, bufferedaction)
    local target = bufferedaction and bufferedaction.target or nil
    if target and target.IsInGolfArea then
        local x, y, z = doer.Transform:GetWorldPosition()
        return target:IsInGolfArea(x, z)
    end
--★ 行尾英文注释「Lost target have the player reach the destination
--   immediately to fail.」是理解本函数意图的关键：
--   ★★ 目标丢了 → **故意**返回 true 让玩家「立刻到位」，
--     然后 fn 里因为 target 为 nil 而失败，玩家看到的是「走到那儿发现没了」
--     而不是「站在原地点不动」。这是刻意的交互选择。
    return true -- Lost target have the player reach the destination immediately to fail.
end

--★ ShowPourWaterTilePlacer 是 show_tile_placer_fn，不是 customarrivecheck。
--   它决定「地面格子放置器」要不要显示高亮框 —— 纯视觉，客户端跑。
local function ShowPourWaterTilePlacer(right_mouse_action)
    if right_mouse_action ~= nil then

        if right_mouse_action.target ~= nil and right_mouse_action.target:HasTag("farm_plant") then
            local x, y, z = right_mouse_action.target.Transform:GetWorldPosition()
            return TheWorld.Map:IsFarmableSoilAtPoint(x, y, z)
        else
--★★ 英文原注释解释了这里的 `return false` 是**依赖顺序**：
--   「悬停在农田上时，若没有 target，POUR_WATER_GROUNDTILE 已经抢先了」。
--   ★★ 也就是说：两个竞品动作靠 priority 排序（571-572 行都无 priority，
--     默认 0），而这个函数在**渲染层**再补一刀防重叠显示。
--   ★ 这是典型的「同一语义在三处重复表达」—— 拆动作、加 priority、
--     加渲染守卫。改规则时三处必须同步。
            -- If there is no target while hovering farm turf the POUR_WATER_GROUNDTILE point action will have taken priority anyway
            return false
        end
    end
end

--★★ ExtraPickupRange 与 ExtraPickRange(35 行) 的唯一差别：
--   ★★ 不看 bufferedaction.target，不加武器范围。固定返回 0.75 或 0。
--   理由：捡东西不需要「能打到的距离」，只需要「别在水面上够不着」。
--   ★ 也因此这个函数的 doer / bufferedaction 两个参数**完全没用到**。
--     函数签名保留是为了与 extra_arrive_dist 家族的统一接口（209 行注释）。
local function ExtraPickupRange(doer, dest)
	if dest ~= nil then
		local target_x, target_y, target_z = dest:GetPoint()

		local is_on_water = TheWorld.Map:IsOceanTileAtPoint(target_x, 0, target_z) and not TheWorld.Map:IsPassableAtPoint(target_x, 0, target_z)
		if is_on_water then
			return 0.75
		end
	end
    return 0
end

--★★【ExtraDeployDist —— 全文件最复杂的一个 extra_arrive_dist，共 44 行】
--   它要解决的问题：玩家在**船**上、目标是**陆地**（或反过来）时，
--   8 格的抛射距离在跨介质时会算错，所以要按介质组合决定余量。
--   ★ 判据矩阵（177-196 行）：
--     doer 在陆地/船 + 目标在真海洋 → 加余量（要把东西抛到水里）
--     doer 在陆地/船 + 目标在虚空   → 加余量（虚空也要能扔）
--     doer 在海洋/虚空 + 目标在陆地 → 加余量（反过来）
--     doer 与目标同介质              → 不加
--   ★★ 177 行用 `if passable(doer)` 二分，于是 has_ocean（180 行）
--     只能在 doer 在陆地分支里被读到 —— 这是「分支内才关心世界类型」。
local function ExtraDeployDist(doer, dest, bufferedaction)
	if dest ~= nil then
		local invobject = bufferedaction and bufferedaction.invobject or nil
		if invobject and invobject:HasTag("projectile") then
--★ `8 - ACTIONS.DEPLOY.distance` = 8 - 1.1 = 6.9。
--   ⚠ 这个魔数 8 就是 ACTIONS.TOSS(501 行) 的 distance。
--   ★★ 真正的设计意图是「让 DEPLOY 与 TOSS 的**总**射程一致」：
--     TOSS 总射程 8，DEPLOY 总射程 1.1 + 6.9 = 8。
--   ★ 但写成两处独立的字面量而不是共用常量，改 TOSS 距离时不会同步。
--     并且 170 行**硬编码 ACTIONS.DEPLOY 自己的 distance** ——
--     若将来把 DEPLOY 的 distance 改成 1.5，总射程会变成 8.5，静默漂移。
			return 8 - ACTIONS.DEPLOY.distance
--★ 171 行回到 DefaultRangeCheck 的定义之后 ——
--   ★★ 第零节到此结束。§一（Action 基类）从 294 行开始。
--   ★ 记住本节的 14 个函数在 ACTIONS 表里被引用了 30+ 次。
		end

		local doer_x, doer_y, doer_z = doer.Transform:GetWorldPosition()
		local target_x, target_y, target_z = dest:GetPoint()
--★★ ExtraPickRange 内部（35-55 行）的四层嵌套逐步收窄：
--   ① 37  bufferedaction 存在？
--   ② 38    └ bufferedaction.target 存在？
--   ③ 39-43     └ doer 有 combat 副本？
--   ④ 40          └ 目标有 jostle* 标签？ → 25 拿到 extrarange
--   ★★★ 这与 §p1 40 行的分析一致：逐层收窄而非展平。
		local use_extra_space = false

		if TheWorld.Map:IsPassableAtPoint(doer_x, 0, doer_z) then
			--doer on land or boat

			if TheWorld.has_ocean then
				if TheWorld.Map:IsOceanTileAtPoint(target_x, 0, target_z) and not TheWorld.Map:IsPassableAtPoint(target_x, 0, target_z) then
					--target on ocean
					use_extra_space = true
--★★ 184 行 —— 三重 and 全部通过，进入距离计算。
--   ★★ extrarange 此时已确定（非武器目标时为 0）。
				end
			elseif TheWorld.Map:IsInvalidTileAtPoint(target_x, 0, target_z) then
				--target on void
				use_extra_space = true
			end
		else
--★★ 190-197 行 —— dest 的水面判定与返回。
--   ★★ 与 §p1 49 行同一套双重判定（海洋瓦片 + 不可通行）。
--   ★ 到此 §零 的范围函数族全部注释完毕。
			--doer on ocean or void

			if TheWorld.Map:IsPassableAtPoint(target_x, 0, target_z) then
				--target on land or boat
				use_extra_space = true
			end
		end

--★★ extra_deploy_distance 是物品自带的字段（由 prefab 设置），
--   与 use_extra_space 触发的默认值 1.0 是**或**关系不是叠加。
--   200 行的 `x = x or 1` 明确表达了「物品的设置优先，否则用 1」。
        local extra_deploy_distance = invobject and invobject.extra_deploy_distance or nil
		if use_extra_space or extra_deploy_distance then
            extra_deploy_distance = extra_deploy_distance or 1

--★ usedeployspacingasoffset 标签让「余量」变成「以碰撞半径为基准」。
--   ★★ DeploySpacingRadius 是 net 变量（客户端可读），所以这整个分支
--     能在服务端正确计算的同时让客户端也读到同样的半径。
			if invobject and invobject:HasTag("usedeployspacingasoffset") then
				local inventoryitem = invobject.replica.inventoryitem
				return (inventoryitem and inventoryitem:DeploySpacingRadius() or 0) + extra_deploy_distance
			end
			return extra_deploy_distance
		end
	end
    return 0
end

--★ ExtraDropDist 三段式：水中 1.75 → 碰撞体半径+0.5 → 0。
--   ★ 中间那段（224-234 行）是给「会撞到角色的大物品」用的：
--     掉落时物品会落在角色身上，需要额外推开一点避免立刻又被捡起。
local function ExtraDropDist(doer, dest, bufferedaction)
    if dest ~= nil then
        local target_x, target_y, target_z = dest:GetPoint()

        local is_on_water = TheWorld.Map:IsOceanTileAtPoint(target_x, 0, target_z) and not TheWorld.Map:IsPassableAtPoint(target_x, 0, target_z)
        if is_on_water then
            return 1.75
        end

        local invobject = bufferedaction and bufferedaction.invobject or nil

        -- Extra drop dist to items that collide with doer, or explicitly set it (use_physics_radius_for_extra_drop_dist).
        if invobject ~= nil and doer ~= nil and invobject.Physics ~= nil and doer.Physics ~= nil then
--★★ 225 行是全文件最精细的一处条件：
--   `not use_physics_radius_for_extra_drop_dist and not checkbit(mask, group)`
--   读作「物品没要求用半径 **且** 碰撞掩码与角色不冲突 ⇒ 返回 0」。
--   ★★ 这里用位运算 checkbit 检查碰撞分组，而不是简单比较类名，
--     所以大象掉落物与普通石头走不同分支。注释也点明了这一点。
            if not invobject.use_physics_radius_for_extra_drop_dist and not checkbit(invobject.Physics:GetCollisionMask(), doer.Physics:GetCollisionGroup()) then
                return 0
            end

--★ 半径为 0（无碰撞体，如纯数据物品）时跳过整个逻辑。
            local physics_rad = invobject:GetPhysicsRadius(0)

            if physics_rad > 0 then
                return physics_rad + 0.5
            end
        end
    end

    return 0
end

--★★ 最简单的 extra_arrive_dist：无条件返回 1.5。
--   ★ 为什么倒水要 1.5 格余量？因为水会泼到脚下的格子，
--     角色若站在格心之外，水就洒在别的格子上了。
--   ★ 函数三个参数全部未使用 —— 保留签名只为统一接口。
local function ExtraPourWaterDist(doer, dest, bufferedaction)
    return 1.5
end

--★★ 保留的英文注释说明了这是**已知的技术债**：
--   「Brightshades 的 physics radius override 比实际碰撞体小，
--     这里应该更全面地处理，但先给这个动作打个补丁。」
--   ★★ 缺陷成因清楚了：Brightshades 通过 override 缩小了半径，
--     导致按半径算的到达判定认为玩家已经够近，实际还差一截。
--   ★ 补丁做法是取差值的绝对值当余量（249-252 行）。
--★ 这处注释本身就是「为什么这样设计」的最佳范例，请勿删除。
-- Small hack, some things (Brightshades) have a lower physics radius override than their actual physics,
-- This should probably be more encompassing, but let's just fix up this action for now.
--★ phys_rad_delta < 0 才处理 —— 因为 override 只会让半径变小。
--   变大的情况（0.5 那种为防卡住而放大的）不需要补距离。
local function ExtraHealRange(doer, dest, bufferedaction)
    local target = bufferedaction and bufferedaction.target or nil
    if target and target.Physics then
        local phys_rad_delta = target:GetPhysicsRadius(0) - target.Physics:GetRadius()
        if phys_rad_delta < 0 then
            return math.abs(phys_rad_delta)
        end
    end
    --
    return 0
end

--★★ ArriveAnywhere —— 「不需要到达判定」的哨兵值。
--   全文件被 458/502/565/690/724/734 六个地图动作复用。
--   ★ 为什么需要一个函数而不是直接让 customarrivecheck=nil？
--     因为 locomotor.lua:1466 判断的是 `if ... .action.customarrivecheck then`，
--     nil 会走 else 分支去做通用距离判断。地图动作必须显式覆盖掉。
--   ★★ 这是「用恒真函数表达『禁用默认逻辑』」的典型手法。
local function ArriveAnywhere()
    return true
end

--★ ExtraWobyForagingDist：大型生物（Woby 机器狗）多走 1 格。
--   largecreature 标签同时被别处用于物理体积，此处是语义标签。
local function ExtraWobyForagingDist(doer, dest, bufferedaction)
    return .5 + (doer:HasTag("largecreature") and 1 or 0)
end

--★★【ExtraOpenCraftingRange —— 一个「反向」的距离计算】
--   ★★ 它不是在加余量，而是在**求差**：把 arrive_dist 抬到
--     RESEARCH_MACHINE_DIST - 1 这个期望值，若当前已超过则返回 0。
--   override_open_crafting_range 是实体的可选覆盖字段。
--   效果：研究台永远不会因为「站得远一点」而需要额外走动，
--     也不会因为站太远而无法开 —— 因为 WALKTO 已经保证了基础距离。
local function ExtraOpenCraftingRange(doer, dest, bufferedaction, arrive_dist)
    local target = bufferedaction and bufferedaction.target or nil
    local dist = (target and target.override_open_crafting_range) or TUNING.RESEARCH_MACHINE_DIST - 1
    return dist > arrive_dist and (dist - arrive_dist)
        or 0
end

--★★【CLIENT_REQUESTED_ACTION —— 跨文件传递「玩家刚刚按了哪个动作」的全局变量】
--   global(...) 是 DST 的全局注册宏，让该名字在所有沙盒里都存在。
--   ★★ 它解决的是**参数化动作**的困境：RPC 到来的只有一个整数 actioncode，
--     但很多动作（ROW_FAIL / DEPLOY_TILEARRIVE / FILL_OCEAN…）
--     需要知道自己是被**哪个上下文**触发的。
--   用法：clientcontroller.lua 收 RPC → SetClientRequestedAction(code)
--        → componentactions.lua:32/66/2046 读它做分支 → 结束后清空。
--   ★ 这是一个「用全局变量当旁路通道」的做法。
--     干净之处：不改 RPC 签名即可扩展；风险之处：跨调用残留。
--     因此 ClearClientRequestedAction（289 行）必须成对调用。
global("CLIENT_REQUESTED_ACTION")
CLIENT_REQUESTED_ACTION = nil

--★★ 保留的英文注释解释了 ACTIONS_MAP_REMAP 的存在意义：
--   「把玩家本可以在游戏里做的动作，改为**在地图上**做。
--   举例：原本要走到传送门才能传送，现在在地图上点一个点就跳过去。
--   ★★ 注释还给出了一句自我限制：「能支持的动作数量，取决于地图本身的限制」
--     —— 即地图分辨率与探索度是硬约束，不是代码问题。
-- NOTES(JBK): This is used to translate normal actions the player could do in the game but done on the map instead.
--             The amount of actions will be limited with how limiting the map itself is.
global("ACTIONS_MAP_REMAP")
ACTIONS_MAP_REMAP = {}

--★ SetClientRequestedAction 的两个分支处理「原版动作」与「模组动作」。
--   ★★ 282 行 `if mod_name then` 是**必须显式写**的，不能写 and/or：
--     因为模组动作的 code 空间是每个模组独立的（见 modutil.lua:466），
--     拿不到 mod_name 时**绝不能**回退到原版表 —— 回退会执行错的动作。
function SetClientRequestedAction(actioncode, mod_name)
    if mod_name then
--★ 双重索引 MOD_ACTIONS_BY_ACTION_CODE[mod_name][actioncode]。
--   ★ 与 743 行的 ACTIONS_BY_ACTION_CODE 结构完全对称，
--     这让调用方（playercontroller.lua:5272-5277）能用同一段代码处理两者。
--   ※ 代价是 mod_name 必须从 RPC 一路透传，中间任一环丢失就查不到。
        CLIENT_REQUESTED_ACTION = MOD_ACTIONS_BY_ACTION_CODE[mod_name] and MOD_ACTIONS_BY_ACTION_CODE[mod_name][actioncode] or nil
    else
        CLIENT_REQUESTED_ACTION = ACTIONS_BY_ACTION_CODE[actioncode]
    end
end

function ClearClientRequestedAction()
    CLIENT_REQUESTED_ACTION = nil
end

--★★ 保留的英文注释：「位置参数已废弃，请传入 table。」
--   ★ 这是全文件唯一的向后兼容代码块（295-304 行）。
--   ★★ 为什么保留？因为模组大量使用 AddAction(Action()) 或
--     AddAction(priority, instant, rmb, ...) 这类旧签名，
--     直接删掉会让整个创意工坊崩溃。
--Positional parameters have been deprecated, pass in a table instead.
--★★★【Action 基类 —— 全文件的设计核心，只有一处，就是这段构造】
--
--★ 为什么构造函数的形参是一长串位置参数（instant, rmb, distance, ...）
--   而不是立刻改成表？因为 295-304 行的兼容层需要它们。
--   表参数是新的正路，形参只是历史包袱。
--
--★★ 40 个字段可以分成六组，理解这六组就理解了 DST 的动作系统：
--   【A】优先级与选择：priority
--   【B】空间与时间：distance / mindistance / arrivedist / extra_arrive_dist /
--                  customarrivecheck / is_relative_to_platform /
--                  disable_platform_hopping / do_not_locomote /
--                  skip_locomotor_facing / canforce / rangecheckfn
--   【C】角色状态许可：mount_valid / encumbered_valid / floating_valid /
--                  paused_valid / ghost_valid / ghost_exclusive
--   【D】执行时机：instant / invalid_hold_action / actionmeter /
--                  pre_action_cb / silent_fail / silent_generic_fail
--   【E】显示：strfn / stroverridefn / theme_music / theme_music_fn /
--              show_primary_input_left / show_secondary_input_right /
--              keepgroundactionhint
--   【F】地图专用：map_action / map_only / closes_map /
--              map_works_on_unexplored / map_works_on_impassable
--
--★★ 全部字段都**没有默认值语义上的约束**：
--   Action() 一个参数都不给也能构造成功，得到一个「什么都不能做」的动作。
--   modutil.lua:448 的 AddAction 正是这么用的（先 Action() 再逐个赋值）。
Action = Class(function(self, data, instant, rmb, distance, ghost_valid, ghost_exclusive, canforce, rangecheckfn)
--★★ 295-297：data 为 nil 时补一个空表。
--   这让 `Action(nil, true)` 这种半吊子调用不至于崩在 type(nil) 上。
--   ★ 也让模组可以只写 `Action({instant=true})` 而不必关心 nil 检查。
    if data == nil then
        data = {}
    end
--★★ 298-304：兼容层。检测到 data 不是表（即旧式位置参数）时打印警告
--   并把位置参数重排进表。注意 301 行的 debugstack_oneline(4) ——
--   ★ 这行只在**模组写错**时触发，所以正常游戏不会产生任何日志开销。
--   ★ 301 行的存在是为了让模组作者能在自己的代码里找到调用位置。
    if type(data) ~= "table" then
        --#TODO: get rid of the positional parameters all together, this warning here is for mods that may be using the old interface.
        print("WARNING: Positional Action parameters are deprecated. Please pass action a table instead.")
        print(string.format("Action defined at %s", debugstack_oneline(4)))
--★ 注意 local priority = data 这一行的类型变化：
--   进入这个分支时 data 是数字（旧的 priority），取出后立即被覆盖为表。
--   ★ 写法上是「先抢救第一个参数，再整体重建」，读起来略绕但无副作用。
        local priority = data
--★★ 兼容映射表：旧位置参数 → 新字段名。
--   ★ 逐项对照 355 行之后的默认值声明，可见**新增字段没有被加进来**：
--     数据表 params（298-301 的 7 项）与现代 40 字段表不等价。
--   ⚠ 这意味着走兼容层的模组动作**拿不到** theme_music、actionmeter、
--     pre_action_cb 等所有新字段 —— 它们会被静默丢弃。
--     ★ 这是「向后兼容往往意味着向前不兼容」的典型代价。
        data = {priority=priority, instant=instant, rmb=rmb, ghost_valid=ghost_valid, ghost_exclusive=ghost_exclusive, canforce=canforce, rangecheckfn=rangecheckfn}
    end

--★★【priority 默认 0 —— 全游戏的中间值】
--   ★★ 这不是随便定的。看表里的实际分布：
--     高于 0：PICKUP=1 / COOK=1 / GIVETOPLAYER=3 / CATCH=3 / GIVE_TACKLESKETCH=0
--     等于 0：TRAVEL / BUILD / PLANT / HARVEST / RUMMAGE…（默认值）
--     低于 0：DROP=-1 / RUMMAGE=-1 / UNHITCH=-1 / UNEQUIP=-2 / WALKTO=-4
--   ★ 三档的语义：
--     >0  「我比通用交互更具体」—— 给专用工具/语境让路
--      0 「通用交互」—— 没人抢就用它
--     <0  「我是兜底」—— 只在其他动作都不适用时才显示
--   ★★ 典型对比：WALKTO=-4 与 LOOKAT=-3 都是负数，
--     保证任何具体交互（喂食、砍树）永远压过「走过去看一眼」。
--   ※ 完整排序发生在 componentactions.lua 与 playercontroller 的
--     动作收集阶段，priority 只是输入之一，还受 rmb / 标签 / 手持物影响。
    self.priority = data.priority or 0
--★★★【self.fn —— 「做了什么」的唯一入口，也是全文件的核心】
--   ★★ 默认值是 `function() return false end` —— 一个永远失败的空动作。
--   ★★ 为什么默认值是「失败」而不是「成功」？
--     因为漏写 fn 的动作必须**安静地失败**：如果默认成功，
--     玩家点了没反应的场景会变成「动作成功但什么都没发生」，
--     物品被白白消耗。后者的 bug 报告率会高得多。
--     ★ 这是「fail-safe 默认值」的正确写法，值得记住。
--   ★ fn 的签名是 fn(bufferedaction)，返回一个值 success 与可选的 reason。
--     第二个返回值会经 bufferedaction.lua:26-27 → entityscript.lua:1672
--     → stringutil.lua:434 翻译成玩家听得到的话。
--   ★★ fn 只在**服务端**执行（经 bufferedaction:Do()）。
--     客户端从来不会调用它 —— 客户端只调用 validfn 与 strfn。
--     这是 DST 联机模型的基础：状态只由服务端改。
    self.fn = function() return false end
--★ strfn 默认 nil，表示「用 STRINGS.ACTIONS[id] 这个默认串」。
--   见 bufferedaction.lua:65：modifier 为 nil 时走基础串。
    self.strfn = nil
--★★【instant —— 「不播动作动画、立即结算」】
--   ★★ 它影响两层：
--     ① locomotor.lua:945 走 `action.instant` 分支直接 PushBufferedAction，
--        不进入 GoToPoint，也就不进入状态图的长动作流程；
--     ② entityscript.lua:1640 立即 Do() 而非 StartAction。
--   ★ 结果：instant 动作**没有「按住」的过程**，点一下就完成。
--   ★ 典型：EQUIP/UNEQUIP（400-401）、REEL（417）、WRAPBUNDLE（477）、
--     STOPCHANNELING（486）、OCEAN_FISHING_STOP（421）。
--   ★★ 副作用：instant 动作也**无法被取消**。所以任何需要
--     「中途松手要停下」的动作都不能设 instant。
    self.instant = data.instant or false
--★★【rmb —— 「这个动作绑定右键」】
--   ★★ 保留的英文注释划出了关键边界：
--     「注意！这实际上只对工具有效，其他所有东西在 componentactions
--      里都直接判断 'right'。」
--   ★★★ 也就是说 rmb 有**两套实现**：
--     · 本字段：动作原型上的声明，供 UI 显示与默认绑定使用
--     · componentactions 的第 3 个参数 right：逐组件硬编码
--   ★ 后果：给非工具物品写 rmb=true **不会**让它出现在右键菜单里，
--     因为 componentactions 不看这个字段。这是本文件最容易误解的字段之一。
--   ★ 在 ACTIONS 表里统计：约 70 个动作声明了 rmb=true。
    self.rmb = data.rmb or nil -- note! This actually only does something for tools, everything tests 'right' in componentactions
--★ distance = 走到多近就停。nil 意味着「由到达判定或状态图自行决定」。
--   ★ 对比 313 行 mindistance —— 一个是下限上限，另一个是下限。
    self.distance = data.distance or nil
--★★【mindistance —— 「太近了反而不能做」】
--   ★★ 全文件仅 3 处使用，而且都不是「距离」语义而是「拒绝」语义：
--     462 行 HAUNT mindistance=2  —— 鬼魂太贴近会吓跑目标
--     579 行 WAX  mindistance=1.5 —— 涂蜡需要看清蜡面
--   ★★ mindistance 的判据在哪里执行？本文件里搜不到 ——
--     它由 locomotor / stategraph 的到达逻辑消费。
--   ★ 所以它是本文件中「声明了但实现完全在别处」的字段之一。
    self.mindistance = data.mindistance or nil
--★ arrivedist —— 直接指定到达距离，覆盖 distance 的换算。
--   ★ 三个例子：STEER_BOAT=0.1（舵要贴得很近）、WOBY_PICKUP=2（狗要站远点）、
--     MAKEMOLEHILL=0（原地不动）。
    self.arrivedist = data.arrivedist or nil
--★★ ghost_exclusive / ghost_valid —— 幽灵（未复活玩家）的动作资格。
--   315 行的耦合是不对称的：
--     self.ghost_valid = self.ghost_exclusive or data.ghost_valid or false
--   ★★ 即「exclusive 蕴含 valid」：只要排他，就必然合法。
--     理由：ghost_exclusive 的语义是「只有幽灵能做」，那么它当然要对幽灵合法。
--   ★ 用 HAUNT（462 行）验证：ghost_valid=true, ghost_exclusive=true ——
--     玩家幽灵只能做「附身」，普通存活玩家看不到这个动作。
--   ★ 另一个例子：MIGRATE（508 行）ghost_valid 但不 exclusive，
--     因为活人也能用（Mootown 之类的迁移台）。
    self.ghost_exclusive = data.ghost_exclusive or false
    self.ghost_valid = self.ghost_exclusive or data.ghost_valid or false -- If it's ghost-exclusive, then it must be ghost-valid
--★ mount_valid —— 骑乘状态下仍然允许。默认 false 的理由：
--   骑牛时喂食、开箱都会破坏骑乘，所以默认禁止、逐个显式开放。
--   ★ 统计：ACTIONS 表里约 40 个动作声明 mount_valid=true。
    self.mount_valid = data.mount_valid or false
--★★ encumbered_valid —— 「负重超限时仍然允许」。
--   ★ 为什么需要这个？WILLOW 的「火把不灭」、WX78 的「充电」等
--     生存类操作不能因为背包装满而失效。
--   ★ 对应 628 行 LIFT_DUMBBELL 的 `mount_valid=false` 组合 ——
--     举哑铃既不能骑乘又要允许超重，是限制最严的动作之一。
    self.encumbered_valid = data.encumbered_valid or false
--★ floating_valid —— 允许在浮空（海面/小船）平台上使用。
--   ★ 出现在 EAT/DROP/EQUIP/UNEQUIP/DEPLOY_FLOATING 等少数几个。
	self.floating_valid = data.floating_valid or false
--★ canforce —— 「允许玩家强制发起」，即无视距离直接执行。
--   ★★ 这是 320 行那行耦合的开关，务必与 rangecheckfn 一起看。
    self.canforce = data.canforce or nil
--★★【rangecheckfn 只在 canforce~=nil 时才生效】
--   `self.rangecheckfn = self.canforce ~= nil and data.rangecheckfn or nil`
--   ★★ 为什么要这个耦合？有两个后果：
--     ① 作者忘记写 canforce 时 rangecheckfn 会被静默丢弃（无报错）；
--     ② 想知道「本动作支持强制」只需看 canforce，无需再查 rangecheckfn。
--   ★★ 注意 `X and Y or nil` 这个 Lua 惯用法：
--     当 Y 为 nil 时表达式结果是 nil 而不是 false。两种情况下 320 行都对，
--     但如果写成 `or false` 就会让 rangecheckfn 变成 false 值，
--     而 locomotor.lua:931 判断的是 `~= nil` —— false ~= nil 为真，会崩。
--   ★ 这是一个极易踩的坑，本行是全文件最微妙的一行之一。
--   参见 locomotor.lua:930-935 的实际消费点。
    self.rangecheckfn = self.canforce ~= nil and data.rangecheckfn or nil
--★ mod_name 默认 nil。赋值发生在 modutil.lua:456（AddAction）。
--   ★ 它把动作与模组绑定，用于 (a) 生成模组独立的 code 空间；
--     (b) 服务器校验客户端上报的 mod_name 是否合法。
    self.mod_name = nil
--★★ silent_fail —— 「失败时不显示通用失败提示」】
--   ★ 只有一个用户：OCEAN_FISHING_REEL（420 行）。
--     深海钓鱼收线失败时，如果每失败一次都播一次语音，玩家会被吵疯。
--   ★ 与 323 行 silent_generic_fail 的区别见后者的注释。
	self.silent_fail = data.silent_fail or nil
--★ silent_generic_fail —— 抑制**通用**失败串（保留专有 reason）。
--   ★ 只有一个用户：JOUST（713 行）。
--   ★★ 两个字段的分工由此明确：
--     silent_fail          → 什么都不播
--     silent_generic_fail  → 播 reason 对应的专有提示，只是不追加通用后缀
--   ★ 这个细分说明「失败提示」本身是被精心设计的 UX，不是随便一句话。
	self.silent_generic_fail = data.silent_generic_fail or nil

--★★ 保留的英文注释标出了分界线：
--   「以下是新参数，**只支持**通过 data 字段传入。」
--   ★★ 结合 303 行的兼容映射表，可以确认这个「分界线」在实现上是严格的：
--     326 行之后的字段在兼容路径上完全不可达。这就是上一条 L 类隐患。
    --new params, only supported by passing via data field
--★ paused_valid —— 「游戏暂停时仍可点」。ADDFUEL / ADDFELFUEL / EQUIP 用了它。
--   ★ 用途：多人服务器房主暂停时仍能管理火堆燃料（避免别人饿着）。
    self.paused_valid = data.paused_valid or false
--★★【actionmeter —— 「显示长按进度环」】
--   ★★ 全文件只有 1 个动作使用：REVIVE_CORPSE（507 行）。
--   ★★ 为什么只有它？因为 actionmeter 的数据链路是：
--     sg.timeinstate → SGwilson.lua:399 player_classified.actionmeter:set_local
--     → prefabs/player_classified.lua:826-829 HUD 的 RingMeter
--   ★★ 也就是说「按住的进度」由**状态图的状态时长**驱动，
--     而不是由动作系统驱动。任何非 instant 动作都天然有进度，
--     只是默认不显示。actionmeter=true 仅仅是「把这条数据接上 HUD」。
--   ★ 若要给别的动作加进度环，只需在对应 SG 状态里写 SetActionMeter。
    self.actionmeter = data.actionmeter or nil
--★★ customarrivecheck —— 覆盖默认到达判定，签名 (doer, dest, act)。
--   ★★ 它是**唯一**能返回「invalid」的扩展点（见 §零 的返回值约定）。
--   ★ 全文件 8 个动作使用：FISH_OCEAN / OCEAN_FISHING_CAST / OCEAN_TOSS /
--     WATER_TOSS / DEPLOY_TILEARRIVE / POUR_WATER_GROUNDTILE /
--     ROW / ROW_FAIL / BOARDPLATFORM / TERRAFORM_REMOVE。
--   ★★ 全是「与水/船/地图格子相关」的动作 —— 因为只有这些场景
--     的到达判定无法用「距离」表达。
    self.customarrivecheck = data.customarrivecheck
--★ is_relative_to_platform —— 坐标相对船体而非世界。
--   ★ 8 个动作用（FILL_OCEAN / ROW / OCEAN_TOSS / WATER_TOSS…）。
--   ★★ 船会移动。若目标坐标以世界坐标记录，玩家站在船上等船漂远了
--     就会去错地方。相对坐标让「脚下这块地板」始终正确。
    self.is_relative_to_platform = data.is_relative_to_platform
--★ disable_platform_hopping —— 禁止跳到相邻的船上（省一次路径搜索）。
--   ★★ 全是海洋动作。玩家在船上点海面时若允许跳板，locomotor 会
--     先尝试跳到邻船，走到一半才失败，白跑一趟。
    self.disable_platform_hopping = data.disable_platform_hopping
--★ skip_locomotor_facing —— 到达后不自动转向目标。
--   ★ 用于「玩家必须保持自己朝向」的场景：ROW_FAIL / LIFT_GYM_*。
    self.skip_locomotor_facing = data.skip_locomotor_facing
--★★ do_not_locomote —— 「完全不走，直接执行」。
--   ★★ 与 instant 的区别必须说清：
--     instant      → 仍然转向目标（entityscript.lua:1635 FacePoint）
--     do_not_locomote → 不转向也不走近，一步到位
--   ★ 全文件 16 个动作用。SET_HEADING（562 行 distance=9999）与之配合，
--     即「转向但不走」—— 摇船时人要面对船头但不移动。
    self.do_not_locomote = data.do_not_locomote
--★ extra_arrive_dist —— 一个返回数字的函数，§零 已详述。
    self.extra_arrive_dist = data.extra_arrive_dist
--★ tile_placer —— 「地面格子放置器」的名字（gridplacer 等）。
--   ★ 只有 TERRAFORM（430）与 POUR_WATER（571）用它。
--   ★★ 它让玩家在移动光标时就能看到「哪些格子会被改成什么」，
--     这是 WASD/手柄玩家唯一能看清落点的手段。
    self.tile_placer = data.tile_placer
--★ show_tile_placer_fn —— 决定放置器高亮框要不要显示（141 行那个函数）。
    self.show_tile_placer_fn = data.show_tile_placer_fn
--★ theme_music —— 动作进行时播放的主题音乐名。
--   ★ 全文件只有 TILL / PLANTSOIL / DEPLOY_TILEARRIVE / POUR_WATER_GROUNDTILE
--     四个，都指向 "farming"。
	self.theme_music = data.theme_music
--★★ theme_music_fn —— theme_music 的**函数版**，运行在客户端。
--   ★ 为什么需要函数版？因为「是否 farming」取决于**当前目标**，
--     而目标在客户端是 replica。
--   ★ 三个用户：INTERACT_WITH（1558）/ DIG（1800）/ DEPLOY（1656）——
--     全部是「对着农田/作物做的事」。
	self.theme_music_fn = data.theme_music_fn -- client side function
--★★【pre_action_cb —— 「动作开始前」的钩子，客户端 + 服务端都跑】
--   ★ 三类用途（穷举全文件 10 个用户）：
--     ① 关 HUD：STEER_BOAT(4903) / BOAT_CANNON_START_AIMING(5049) /
--        USESPELLBOOK(5898) / CLOSESPELLBOOK(5964) / GOLF_START_AIMING(7038)
--        GOLF_START_CHARGING(7062)
--     ② 清手柄状态：APPLYMODULE(5767) / STARTREMOVINGMODULE(6679) /
--        REMOVEMODULE(6693)
--     ③ 立即反馈：LIFT_GYM_FAIL(5718) / LIFT_GYM_SUCCEED(5742) 敲铃。
--   ★★ 为什么放在 cb 而不是 fn？因为 fn 只在服务端跑，
--     而「关弹窗」必须在客户端发生。pre_action_cb 是少数几个双端钩子。
--   ★ 调用点：locomotor.lua:895（PushAction 开头，先于 TestForStart）。
    self.pre_action_cb = data.pre_action_cb -- runs on client and server
--★★【invalid_hold_action —— 「禁止长按连续触发」】
--   ★★ 语义在 playercontroller.lua:4623：
--     if not action.instant and not action.invalid_hold_action and act:IsValid()
--     then self.lastheldaction = buffaction
--     else self.actionholdtime = nil
--   ★ 即「不要把这个动作记进 lastheldaction」，于是松手再按住不会重发。
--   ★★ 为什么需要？凡是**长动作**（砍树、钓鱼、摇船、开垦）都必须有它，
--     否则玩家按住鼠标时「到达即完成，完成即重发」，会变成机器连打。
--   ★ 统计：约 30 个动作声明 invalid_hold_action=true，
--     几乎全部是「需要按住一段时间」的工具类动作。
--   ★★ 这与 instant 是一对反向旋钮：
--     instant=true          → 4622 行已经清空 actionholdtime，效果相同
--     invalid_hold_action=true → 主动拒绝进入 lastheldaction 队列
    self.invalid_hold_action = data.invalid_hold_action

--★ show_primary_input_left —— 强制显示「左键」图标提示。
--   ★ 只有一个用户：ROTATE_BOAT_COUNTERCLOCKWISE（586 行）。
--     因为它不用左键，所以 UI 要显式告诉玩家「其实按右键」。
    self.show_primary_input_left = data.show_primary_input_left
--★ show_secondary_input_right —— 同理，显示「右键」提示（585 行）。
    self.show_secondary_input_right = data.show_secondary_input_right

--★★【五个地图专用字段构成一套完整的「地图动作协议」】
--   map_action  —— 「这是一个地图动作」（可以由地图翻译产生）
--   map_only    —— 「这个动作**只能**从地图发起」
--   closes_map  —— 「动作一开始就该关掉地图」
--   map_works_on_unexplored —— 绕过「已探索」检查
--   map_works_on_impassable  —— 允许选不可通行的格子
--   ★★ 校验点：playercontroller.lua:5279 `if act == nil or
--     not (act.map_action or act.map_only) then return end`
--     —— 只有带这两个标记之一才接受地图 RPC。
--   ★ 安全含义：普通动作无法被地图 RPC 滥用成远程执行。
    self.map_action = data.map_action -- Should only be handled from the map and has action translations.
    self.closes_map = data.closes_map -- Should immediately close the minimap on action start.
    self.map_only = data.map_only -- Action only exists from a map.
    self.map_works_on_unexplored = data.map_works_on_unexplored -- Bypass seeable checks.
    self.map_works_on_impassable = data.map_works_on_impassable -- Allow impassable tiles for selection.

--★ keepgroundactionhint —— 「即使目标无名也保留地面动作提示」。
--   ★★ 唯一用户：TERRAFORM_REMOVE（740 行，高尔夫球场的球位标记）。
--     它是一个「无名的临时目标」，若不留住提示，玩家松手后不知道该点哪。
    self.keepgroundactionhint = data.keepgroundactionhint -- Allow a nameless target to retain the ground action hint for controllers.
--★ 到此 Action 构造结束。整个基类**没有任何方法**，只有数据字段。
--   ★★★ 这是刻意的：Action 不需要行为，它的「行为」全在 fn 字段里。
--     它更像一张「动作规格表」而非一个对象。
--     好处：Actions 表可以纯粹地按分类排列 240 行声明，阅读成本极低。
--   ★★ 也因此 Action 是**无状态**的 —— 这正是它能被安全共享的前提。
end)

--★★【HIGH_ACTION_PRIORITY = 10 —— 全文件唯一的高优先级常量】
--   ★★ 保留的英文注释写明了它的**使用契约**：
--     「高优先级的意图是作为快捷标志，用于那些我们预期一旦可用就永远
--       压过其他动作的动作。」
--     「我们同时预期**不会有两个** HIGH_ACTION_PRIORITY 动作同时可用。」
--   ★★★ 这个「不变量」完全靠人工维护，框架不校验。
--     实际使用者（全部数得出，共 10 个）：
--       JUMPIN_MAP(432) BLINK(457) BLINK_MAP(458)
--       TOGGLE_DEPLOY_MODE(460) COMPARE_WEIGHABLE(492)
--       CATAOE(522) CAST_NET(564)
--       PLANTREGISTRY_RESEARCH(574) DIRECTCOURIER_MAP(690)
--   ★ 观察：全部是「打开某个界面 / 传送到某处」这类**界面型**动作。
--     共同点是它们会立刻改变玩家的操作模式（开地图、开轮盘、进入建造），
--     此时应该压过一切具体交互，否则会出现「右键想开轮盘却砍了树」。
--   ★★ 若模组新增了一个 HIGH 动作且与上述某个在同一目标上同时可用，
--     排序结果将由 playercontroller 的收集顺序决定 —— 不可预测。
-- NOTE: High priority is intended to be a shortcut flag for actions that we expect to always dominate if they are available.
-- We also expect that no two HIGH_ACTION_PRIORITY actions overlap with each other.
local HIGH_ACTION_PRIORITY = 10

--★★★【ACTIONS 表 —— 240 个动作原型的声明，385 行纯数据】
--
--★★ 为什么是「一张大表」而不是分散注册？
--   因为动作之间存在**同名字段的密集对照**（哪些 mount_valid、哪些优先 3、
--   哪些是地图专用）。集中在一处才能一眼看出「这类动作的统一约定」，
--   也能发现异常值（如 RUMMAGE=-1 与 CHANGEIN=0 的注释「必须比 RUMMAGE 大」）。
--   ★ 例证：395 行 CHANGEIN 的行尾注释明确引用了 405 行 RUMMAGE 的值，
--     「-- Must be bigger than RUMMAGE.」这种跨行约束只有集中排列才写得出来。
--
--★★【每一条声明只写「与默认值不同的字段」】
--   于是 `REPAIR = Action({ mount_valid=true, encumbered_valid=true })` 只有 12 字符，
--   而 `TOSS = Action({priority=1, rmb=true, distance=8, mount_valid=true})` 也只有 60。
--   ★ 这是数据驱动的可读性红利：Action({}) 的默认值设计得足够小，
--     使得 95% 的声明都能一眼看出「这个动作特殊在哪」。
--
--★★【表内注释按 DLC 分组，这是唯一有组织的地方】
--   --Quagmire(534) --WEBBER(618) --WANDA(624) --WOLFGANG(627)
--   --WX78(640) --MAXWELL(649) --WOODIE(656) --WINONA(659) --Rifts(662)
--   -- Hallowed Nights 2024(672) -- Winter's Feast 2024(675) -- Meta 5(679)
--   -- Deck O' Cards(694) -- Rifts 5(699) -- Winter 2025(708)
--   -- Year of the Clockwork Knight(712) -- Meta 6(715) -- Rifts 7(731)
--   -- Crow Carnival 2026(736)
--   ★★ 这个分组**暴露了一个真实的维护问题**：新增动作时永远追加到末尾，
--     所以顺序大致等于「该功能加入游戏的时间」。查找某个动作属于哪个
--     角色/季节，只能靠名字猜。
--   ★ 对比 357 行的动作在文件头 360 行就出现了，而 WEBBER 在 618 ——
--     「基础动作」在前，「DLC 动作」在后，两者并未严格分离。
ACTIONS =
{
--★ REPAIR：修理 / 给月亮神像供能（月亮门槛 repairable_moon_altar）
--   mount_valid + encumbered_valid ⇒ 骑着牛、拿着大理石也能供。
--   ★ 印证了 317 行 encumbered_valid 的用途：供能是基地维护，不能被背包满拦住。
    REPAIR = Action({ mount_valid=true, encumbered_valid=true }),
--★ READ：读书 / 读告示。只需 mount_valid（书在手上）。
--   ★ 对比 385 行 TALKTO 也只有 mount_valid + encumbered_valid ——
--     两者同属「手持物 + 骑乘兼容」的轻交互族。
    READ = Action({ mount_valid=true }),
--★★ DROP 是全表信息量最大的一行声明，六个字段各有含义：
--   priority=-1        ⇒ 兜底。「对地面丢东西」永远排最后，
--                        避免抢走更具体的动作（比如对箱子丢）。
--   floating_valid=true ⇒ 可以从浮空平台丢出去
--   is_relative_to_platform ⇒ ★★ 相对船体坐标（329 行）
--                        船在动，用世界坐标会丢到水里
--   extra_arrive_dist=ExtraDropDist ⇒ §零 的碰撞半径余量
--   ⚠ 没有 rm！丢东西可以是左键或右键，由 fn 自行决定（1173 行读
--     act.options.wholestack）。
	DROP = Action({ priority=-1, mount_valid=true, encumbered_valid=true, floating_valid=true, is_relative_to_platform=true, extra_arrive_dist=ExtraDropDist }),
--★ TRAVEL：完全空的 Action()。它的实现不在 fn 里 ——
--   3699 行 fn 只做 `if act.target.travel_action_fn then ... end`，
--   即**由实体自带回调**。这是「无内容动作」的标准形态：
--   动作只负责被选中，具体做什么由目标实体决定。
    TRAVEL = Action(),
--★★ CHOP：砍树。四类工具动作的模板（另三个是 MINE / HAMMER / DIG）。
--   distance=1.75 ⇒ 比默认 4 格近得多。为什么？
--     ★★ 因为砍树的判定是 workaction（workable 组件的 GetWorkAction），
--       走近 4 格才能砍会让玩家觉得「明明够得着却砍不到」
--       ——1.75 正好是树的碰撞半径加上手臂长度。
--   invalid_hold_action=true ⇒ 砍完不会自动连砍下一棵（见 339 行）
--   ⚠ 没有 canforce ⇒ 不能「隔空砍树」。这与 NET（可强制）形成对比。
	CHOP = Action({ distance=1.75, invalid_hold_action=true }),
--★★ ATTACK：攻击。三条注释说明了一切：
--   priority=2 ⇒ 比 PICKUP(1) 高。为什么？
--     ★★ 因为玩家拿着武器对着敌人时，几乎总是想攻击；
--       而「捡起来」永远是次优解。
--   canforce=true ⇒ 允许强制（长矛、铳子这类需要更宽射程的武器）
--   行尾注释「No custom range check, attack already handles that」：
--     ★★★ 因为 320 行的耦合，canforce=true 而没有 rangecheckfn 时，
--       rangecheckfn 就是 nil，locomotor.lua:931 的检查自然跳过。
--       范围由 combat 组件自己在攻击瞬间判定。
--     ★ 这不是 bug 而是**分工**：攻击距离取决于武器而非动作。
--   invalid_hold_action=true ⇒ 长按攻击不自动连击下一目标
	ATTACK = Action({priority=2, canforce=true, mount_valid=true, invalid_hold_action=true }), -- No custom range check, attack already handles that
--★ EAT：吃东西。floating_valid ⇒ 可以站在浮空平台（船）上吃。
--   ★ fn（793 行）是三分支的「能力探测」：
--     edible → eater:Eat（普通玩家）
--     soul  → souleater:EatSoul（韦伯）
--     oceanfishable → 装鱼竿（韦伯带鱼）
--   ★★ 一个动作服务三种完全不同的角色，靠**目标有没有某个组件**来分派。
--     这是 DST 消除「角色专属动作」的主要手法。
	EAT = Action({ mount_valid=true, floating_valid=true }),
--★★ PICK：采摘 / 翻找 / 搜索。这是唯一用了自定义 rangecheckfn 的基础动作。
--   ★ 三件套：canforce=true / rangecheckfn=PickRangeCheck（§零 18 行）/
--     extra_arrive_dist=ExtraPickRange（§零 35 行）。
--   ★★ 「可强制 + 自定义范围」的标准范例：玩家可以隔着一定距离采摘，
--     因为植物往往比玩家判定框小。
--   ★ 而 PICKUP（捡起掉落物）用的是 priority=1 而非 canforce ——
--     捡东西不需要强制，因为掉落物通常就在脚下。
    PICK = Action({ canforce=true, rangecheckfn=PickRangeCheck, extra_arrive_dist=ExtraPickRange, mount_valid = true }),
--★★ PICKUP：捡起掉落物。与 PICK 的区别是「目标是地面上的东西」。
--   priority=1 ⇒ 比 PICK 高一档。为何？
--     ★★ 因为「捡」是零思考的下意识行为，「采摘」需要判断。
--       玩家同时能碰到地上的一堆东西和一个浆果丛时，
--       框架必须先问「捡」而不是「摘」。
--   mount_valid ⇒ 骑着牛也能捡（很常用）
--   extra_arrive_dist=ExtraPickupRange（§零 154 行，固定 0.75 水面余量）
    PICKUP = Action({ priority=1, extra_arrive_dist=ExtraPickupRange, mount_valid=true }),
--★ MINE：采矿。与 CHOP 完全同构（只有 distance 不同，MINE 用默认）。
--   ★★ 为什么挖矿可以用默认距离而砍树要 1.75？
--     因为矿脉通常是单个石头，体积小，走近 4 格反而容易「够不着」。
--   ★★ 这与 PickRangeCheck 的动机相反（那里是「目标小所以要走近」），
--     这里是「目标小所以不能走太近 —— 否则会走过它」。
	MINE = Action({ invalid_hold_action=true }),
--★★ DIG：挖掘。与 CHOP/MINE 的唯一差别是 rmb=true。
--   ★ 这意味着**右键才能挖**（左键通常是别的用途）。
--   ★ 所以「四类工具动作同构」并不完全：DIG 还多了输入键位约定。
--   ★★ 呼应 310 行的注释「rmb 只对工具有效」—— DIG 正是「工具」。
	DIG = Action({ rmb=true, invalid_hold_action=true }),
--★ GIVE：给 NPC 送东西。canforce + DefaultRangeCheck（§零 16 行）。
--   ★★ GIVE 家族的三个动作全部 priority=3（GIVETOPLAYER/GIVEALLTOPLAYER/
--     FEEDPLAYER）。为什么是全表最高的常规优先级？
--     因为「把东西给某个特定的人」是极强的意图，
--     必须压过「对地面丢东西」(-1)、「采摘」(0)、「攻击」(2)。
--   ★ 对照 405 行 RUMMAGE=-1 的注释「CHANGEIN 必须比 RUMMAGE 大」，
--     可以看出这一组的 priority 是成体系设计的。
    GIVE = Action({ mount_valid=true, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ GIVETOPLAYER：给玩家 1 个。priority=3（与 GIVE 同级，靠 canforce/rmb 区分）。
    GIVETOPLAYER = Action({ priority=3, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ GIVEALLTOPLAYER：给玩家全部。
--   ★★ 与 GIVETOPLAYER 的差别完全在 fn 里（2362-2382 行）：
--     前者 CanAcceptCount(act.invobject, 1)，后者 CanAcceptCount(act.invobject)。
--   ★ 两行代码的差别 = 一个游戏的「全给」功能。
    GIVEALLTOPLAYER = Action({ priority=3, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ FEEDPLAYER：喂别人吃。注意 rmb=true（右键喂）——
--   ★★ 因为喂食与「给东西」在按键上刻意分开，避免误操作：
--     右键 = 我给你食物（善意），左键 = 给东西（可能是交易）。
--   ★ fn（2400 行）有一长串 sg 状态标签检查（idle / busy / attacking /
--     sleeping / playerghost / wereplayer），是全文件最长的单次判定链之一。
    FEEDPLAYER = Action({ priority=3, rmb=true, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ DECORATEVASE：装饰花瓶。与 RUMMAGE 配对使用（RUMMAGE 的 strfn 会返回
--   「DECORATE」，见 1153 行）。
--   ★ 又是 priority 缺省 0 的一对，说明它们靠 **target 上的标签**区分
--     而不是靠 priority。
    DECORATEVASE = Action(),
--★ COOK：烹饪（放材料进锅）。priority=1 高于 STORE(0)。
--   ★★ 优先级理由很实在：锅里已经有东西时，「继续放材料」比「打开锅」
--     更符合直觉。
--   ★ 呼应 2001 行 stroverridefn 的注释：为了不破坏容器里对 COOK 串的
--     访问方式，这里用 stroverridefn 而非 strfn 返回 SPICE。
    COOK = Action({ priority=1, mount_valid=true }),
--★ FILL：装水（从水源往容器里灌）。空的 Action()：无距离、无优先级。
--   ★ fn（2120 行）是「双向」动作：source 与 filled 谁是 target 都行，
--     所以**没有**优先级的必要。
    FILL = Action(),
--★ FILL_OCEAN：直接从海里装水。is_relative_to_platform + ExtraDropDist。
--   ★★ is_relative_to_platform 的必要场景：站在船上往海里倒/装水。
--   ★ 2160 行 `ACTIONS.FILL_OCEAN.fn = ACTIONS.FILL.fn` —— T12 同构模板。
--     两者 fn 相同但 stroverridefn 不同（2161 行强制显示 FILL 串）。
    FILL_OCEAN = Action({ is_relative_to_platform=true, extra_arrive_dist=ExtraDropDist }),
--★ DRY：晾干。空 Action()，逻辑全在 dryer 组件。
    DRY = Action(),
--★★ ADDFUEL：加燃料。三个字段共同表达「这是玩家维护动作」：
--   mount_valid  骑着牛也能添柴
--   paused_valid ★★ 游戏暂停时也能添柴（房主福利）
--   ★★ 326 行说 paused_valid 全文件只有 4 个动作用，ADDFUEL 是其中之一。
--     理由：服务器管理员需要能保证所有人都有火。
    ADDFUEL = Action({ mount_valid=true, paused_valid=true }),
--★ ADDWETFUEL：加湿燃料（韦伯）。2207 行 fn 直接 = ADDFUEL.fn。
    ADDWETFUEL = Action({ mount_valid=true, paused_valid=true }),
--★★ LIGHT：点火。priority=-4 —— 全表**最低**的优先级之一（与 WALKTO 并列）。
--   ★★ 为什么点火这么不重要？因为「点火」几乎总是「先走过去再点」，
--     玩家的真实意图是到达火堆，所以必须让位。
--   ★ 对照 384 行 LOOKAT=-3、386 行 WALKTO=-4 —— 这一档是「兜底移动」。
    LIGHT = Action({ priority=-4 }),
--★ EXTINGUISH：灭火。priority=0（默认），与 LIGHT 的 -4 形成有趣对比：
--   ★★ 灭火是默认级，而点火是最低级。
--     推断：灭火通常只有右键一个明确入口，没有左键的竞争；
--     而点火要和「走过去」「看一眼」竞争。
    EXTINGUISH = Action({ priority=0 }),
--★★ STOKEFIRE：添柴（拨旺火）。四个字段都很讲究：
--   rmb=true ⇒ 右键（与 ADDFUEL 的左键区分）
--   distance=8 ⇒ 8 格！比其他动作远得多，因为长矛/火把可以远程拨火
--   mount_valid ⇒ 骑着牛也能拨
--   invalid_hold_action ⇒ 拨火是长动作
--   ★ fn（2879 行）还额外检查 `HasTag("controlled_burner")` 与
--     `HasTag("stokeablefire")` —— 两个标签双重确认。
    STOKEFIRE = Action({ rmb=true, mount_valid=true, distance=8, invalid_hold_action=true }),
--★★ LOOKAT：查看。四处细节：
--   priority=-3  兜底档
--   instant=true  ★★ 查看是瞬间的，不播「弯腰看」动画
--   distance=3    ★ 保留的行内英文注释 --[[for close inspection]] 说明
--                     这是为了「凑近看」而不是「远远看」
--   ghost_valid + mount_valid + encumbered_valid ⇒ 幽灵/骑乘/超重都能看
--   ★★ instant 与 distance 的组合值得注意：instant 让 locomotor 直接
--     PushBufferedAction，但仍会「走过去」，只是不做长动作流程。
--     fn（1220 行）里显式调 locomotor:Stop() 解释了这个组合。
	LOOKAT = Action({ priority=-3, instant=true, distance=3--[[for close inspection]], ghost_valid=true, mount_valid=true, encumbered_valid=true }),
--★ TALKTO：对话。instant + priority=3 + ghost_valid。
--   ★★ ghost_valid 的原因：幽灵可以与 NPC 说话（这是韦伯的核心玩法之一）。
--   ★ priority=3 表示「明确意图」，与 GIVE 家族同级。
    TALKTO = Action({ priority=3, instant=true, mount_valid=true, encumbered_valid=true }),
--★ WALKTO：走到。priority=-4（与 LIGHT 并列最低）。
--   ★★ WALKTO 是「最后的兜底」：当没有任何具体动作可用时，
--     「走过去」永远可用，所以它的优先级必须最低，
--     否则会抢走所有具体交互。
--   ghost_valid ⇒ 幽灵能走到某处（MOON 门），是韦伯核心机制
--   invalid_hold_action ⇒ 按住鼠标不会连续「走」
    WALKTO = Action({ priority=-4, ghost_valid=true, mount_valid=true, encumbered_valid=true, invalid_hold_action=true }),
--★ INTERACT_WITH：互动（照料作物）。distance=1.5 很近。
--   ★ 因为「照料」需要贴身操作，与 1.75 的砍树同属近距离族。
--   ★ 它还有 theme_music_fn（1558 行）：对作物互动时播 farming 音乐。
    INTERACT_WITH = Action({ distance=1.5, mount_valid=true }),
--★ BAIT：放饵。空 Action()，fn（1594 行）直接 trap:SetBait。
--   ★★ 这是 T1 纯转发模板的最简样本，建议作为阅读入门。
    BAIT = Action(),
--★★ CHECKTRAP：检查陷阱。priority=2 —— 与 ATTACK 同级。
--   ★ 推断：检查陷阱时玩家拿着武器，攻击不该抢走它；
--     而检查又比「捡地上的东西」(1) 更具体。
--   ★ mount_valid ⇒ 骑牛也能查陷阱（猎人常见操作）。
    CHECKTRAP = Action({ priority=2, mount_valid=true }),
--★ BUILD：建造。空 Action()，fn（2609 行）只有两行：
--   转发给 builder:DoBuild(recipe, 点, 朝向, 皮肤)。
--   ★★ 注意 recipe 来自 act.recipe —— **动作实例**携带配方，
--     而 Action 原型不知道配方。这是「原型 vs 实例」分层的又一例证。
    BUILD = Action({ mount_valid=true }),
--★ PLANT：种植。空 Action()。fn（2619 行）有两分支：
--   grower:PlantItem（普通种植）与 winter_treestand（冬季树支架）。
    PLANT = Action(),
--★ HARVEST：收获。空 Action()。fn（2638 行）是**七分支 if 链**：
--   crop / harvestable / stewer / dryer / dryingrack / occupiable /
--   quagmire_tappable。这是「一个动作服务七种作物」的例子。
--   ★★ 全部靠「目标有没有某个组件」分派 —— 与 EAT 的三分支同源。
    HARVEST = Action(),
--★ GOHOME：回家（牛棚/洞穴）。空 Action()。
--   ★ fn（2943 行）带一句保留的英文自嘲：「this is gross. make it better
--     later.」—— 作者自己也知道这一坨 if 嵌套该重构。
--   ★★ 该 fn 会**销毁执行者**（`act.doer:Remove()`，2957/2960 行）。
--     全文件唯一一个会删除 doer 的玩家动作。
    GOHOME = Action(),
--★ SLEEPIN：睡觉。空 Action()。fn（2686 行）用 `or` 链同时处理
--   「手上的睡袋」与「地上的睡袋」两种情况。
    SLEEPIN = Action(),
--★★ CHANGEIN：换衣服。四行声明里藏着全表最重要的一条行尾注释：
--   `-- Must be bigger than RUMMAGE.`
--   ★★★ 这是一条**跨行动作的硬约束**：405 行的 RUMMAGE 是 -1，
--     所以 CHANGEIN 必须 ≥ 0，否则「打开衣柜」会被「翻找」抢走。
--   ★★ 为什么 RUMMAGE 要压到 -1？因为「翻找」是个**泛用**动作，
--     任何带 container 的东西都能翻找，包括衣柜。
--     若两者同级，收集候选动作时的遍历顺序会决定谁赢 —— 不可预测。
--     于是把泛用动作压低、专用动作抬高。
--   ★★★ 这是本文件 priority 设计意图最清晰的证据，也是唯一一处
--     用自然语言写下的约束。读懂它就理解了 priority 的全部用法。
    CHANGEIN = Action({ priority=0 }), -- Must be bigger than RUMMAGE.
--★ HITCHUP：拴牛。priority=-1（与 RUMMAGE 同档，也是泛用动作）。
--   ★ mount_valid 未设 ⇒ **不能骑着牛再拴另一头牛**。符合直觉。
    HITCHUP = Action({ priority=-1 }),
--★ MARK：标记。distance=2（很近，标记是在地图上画的点）。
    MARK = Action({ distance=2, priority=-1 }),
--★ UNHITCH：解开拴绳。distance=2。priority=-1 与 HITCHUP 对称。
    UNHITCH = Action({ distance=2, priority=-1 }),
--★ HITCH：被拴住时的跟随动作。priority=-1，**无距离**（distance=nil）。
--   ★★ 这是「无距离」的正确用例：牛被拴住后自动走向桩子，
--     不该有距离约束。fn（2747 行）只做两件事，清 hitchingspot 并 SetHitched。
--   ★⚠ L6：fn 没有 return 值 ⇒ 返回 nil ⇒ BufferedAction:Do() 视为失败。
--     对 AI 用的动作而言「失败但已生效」没有副作用（HITCH 只被
--     brains/beefalobrain.lua:171 使用，AI 不关心返回值），
--     但若玩家也能触发就会「点了没反应」。
    HITCH = Action({ priority=-1 }),
--★★ EQUIP：装备。字段极多，因为「装备」要处理的状态最多：
--   priority=0 + instant=true ⇒ 瞬间完成（换装不该有动画延迟）
--   mount_valid/encumbered_valid/floating_valid/paused_valid 四个 true
--   ★★ 这四个标记全开，说明 EQUIP 被视作「永远不会出错的操作」——
--     无论玩家在什么状态下，换装都应该允许。
--     这是很合理的设计判断：装备失败会让人完全无法玩。
	EQUIP = Action({ priority=0,instant=true, mount_valid=true, encumbered_valid=true, floating_valid=true, paused_valid=true }),
--★ UNEQUIP：卸下。与 EQUIP 镜像但 priority=-2（低于 DROP 的 -1）。
--   ★★ 为什么卸装备比丢东西优先级低？
--     因为「丢」是完全放弃，「卸」只是换回背包 —— 玩家的犹豫度不同。
--   ★ strfn（858 行）会根据物品类型返回 "HEAVY" 变体（区分重物）。
	UNEQUIP = Action({ priority=-2,instant=true, mount_valid=true, encumbered_valid=true, floating_valid=true, paused_valid=true }),
--★ 402 行是被注释掉的 OPEN_SHOP —— 保留 commented-out 代码的样本。
--   ★★ 商店功能在 Klei 商城时代被移除，但代码位置留着，
--     方便未来 DLC 复活时知道该往哪放。这是有意保留而非遗忘。
    --OPEN_SHOP = Action(),
--★ SHAVE：刮胡子。mount_valid（坐着也能刮）。
--   ★ strfn（2813 行）会在手柄模式下返回 "SELF" ——
--     因为手柄没有「点自己」的操作，必须靠 strfn 区分。
    SHAVE = Action({ mount_valid=true }),
--★ STORE：把物品放进箱子/锅/冰箱。与 COOK(1) / RUMMAGE(-1) 形成三档：
--   ★★ 「打开箱子翻找」(-1) → 「把东西放进去」(0) → 「往锅里放材料」(1)
--     这是一个完整的、由 priority 编码的**交互语义层级**。
	STORE = Action({ mount_valid=true }),
--★★ RUMMAGE：翻找容器。priority=-1 —— 全表最低的非负以下档位之一。
--   ★★★ 它是「priority 设计」的锚点：
--     · 泛用性最高（任何 container 都触发）⇒ 必须压低
--     · 395 行 CHANGEIN 的注释直接依赖它
--     · 1152-1157 行 strfn 还要为它做特殊分支（decoratable / unwrappable）
--   ★★ fn（1051 行）是全文件最长的动作实现（80 行），因为「打开容器」
--     要处理：代理容器（container_proxy）、变身容器（container_transform）、
--     骑乘中的自己、角色专属限制（CanOpenCharacterSpecificContainer）、
--     黑暗中静默失败、口袋维度容器……
--   ★ 每一个 elseif 分支都是历史上某个功能留下的痕迹。
    RUMMAGE = Action({ priority=-1, mount_valid=true }),
--★★ 保留的英文注释解释了 DEPLOY_TILEARRIVE 为什么还在：
--   「DEPLOY_TILEARRIVE should stay a hold action.」
--   ★★ 即「它是按住的」—— 铺地板需要按住不放。
--     408 行的声明里确实**没有** invalid_hold_action，与 DEPLOY(407) 相反。
--   ★ 两者的对比非常 instructive：
--     DEPLOY           invalid_hold_action=true  → 放单个物品不重复
--     DEPLOY_TILEARRIVE 无 invalid_hold_action    → 铺地板可以按住连续
--   ★ 同一个 fn（1662 行 `ACTIONS.DEPLOY_TILEARRIVE.fn = ACTIONS.DEPLOY.fn`），
--     两个截然不同的输入手感。这是最能说明「Action 是数据」的例子。
    -- DEPLOY_TILEARRIVE should stay a hold action.
--★★ DEPLOY：放置。三个字段：
--   distance=1.1  ★★ 全表最小的 distance。为什么？
--     因为放置需要**精确位置**。1.1 格意味着「必须站得很近，
--     否则放下去会挡住自己的路」。
--   extra_arrive_dist=ExtraDeployDist ⇒ §零 的介质矩阵，最终总射程 8
--   invalid_hold_action=true ⇒ 放一个物品不会连续放
	DEPLOY = Action({distance=1.1, mount_valid=true, extra_arrive_dist=ExtraDeployDist, invalid_hold_action=true }),
--★ DEPLOY_TILEARRIVE：铺地板/地面格子。用 customarrivecheck=CheckTileWithinRange
--   （§零 121 行）—— 因为目标不是实体而是**格子**。
--   theme_music="farming" ⇒ 铺地板时播农场主题。
--   ★★ 保留的英文注释说明了它未来复用时的陷阱：
--     「如果将来用于非农业用途，需要换成 theme_music_fn。」
--     这是作者主动留下的技术债提示，非常难得。
    DEPLOY_TILEARRIVE = Action({customarrivecheck=CheckTileWithinRange, theme_music = "farming"}), -- Note: If this is used for non-farming in the future, this would need to be swapped to theme_music_fn
--★ DEPLOY_FLOATING：放置浮空物品。do_not_locomote ⇒ 原地放，不走过去。
--   ★★ 为什么浮空放置不需要走过去？因为浮空物（如浮标、告示牌）
--     总是放在**当前所在**的位置，走过去反而会改变落点。
--   ★ floating_valid + invalid_hold_action 同为 true。
	DEPLOY_FLOATING = Action({do_not_locomote=true, floating_valid=true, invalid_hold_action=true }),
--★ PLAY：演奏乐器 / 吹哨子。mount_valid。
--   ★ strfn（2833 行）里 coach_whistle 分支会返回 COACH_ON/COACH_OFF ——
--     沃尔夫冈的「教练模式」用同一动作实现开关切换。
    PLAY = Action({ mount_valid=true }),
--★ CREATE：创造。空 Action()。
    CREATE = Action(),
--★ JOIN：加入。空 Action()。
    JOIN = Action(),
--★ NET：网捕。priority=3 + canforce + DefaultRangeCheck。
--   ★★ priority=3 表示「强意图」：拿网子的玩家几乎一定是要抓。
--   ★ fn（1853 行）是「四工具动作」之外的第五种：它不走 DoToolWork，
--     而是自己判断 workaction===ACTIONS.NET 后调 WorkedBy。
--   ⚠ L5：1871 行无条件 `return true` —— 见该行注释。
    NET = Action({ priority=3, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★★ CATCH：接住。distance=math.huge —— **无限距离**！
--   ★★ 这是 locomotor 的特殊约定：locomotor.lua:947 判定
--     `distance ~= nil and distance >= math.huge` ⇒ 「实质瞬间」，
--     直接 FaceMovePoint + PushBufferedAction，不走路。
--     同样的写法在 CASTUNSUMMON(496)/ROW/TACKLE/DASH 等处出现。
--   ★ 语义：捕蝇草类的「接」不需要走近，因为目标会自己飞来。
--   ★ fn（1874 行）只有 `return true` —— 真正的接住在捕蝇草组件里。
    CATCH = Action({ priority=3, distance=math.huge, mount_valid=true }),
--★★ FISH_OCEAN：海钓。三个字段是「海洋三件套」：
--   rmb=true                        ⇒ 右键抛竿
--   customarrivecheck=CheckFishingOceanRange ⇒ §零 68 行，探针法
--   is_relative_to_platform=true    ⇒ 船动时坐标不漂
--   disable_platform_hopping=true   ⇒ 不跳到邻船
--   ★★ 注意 fn（1878 行）**永远失败**：
--     `return false, "TOODEEP"`
--     这不是 bug —— 玩家在「太深」的位置抛竿，失败提示正是反馈本身。
--     ★ 「用失败原因做 UI 反馈」的样本。
    FISH_OCEAN = Action({rmb=true, customarrivecheck=CheckFishingOceanRange, is_relative_to_platform = true, disable_platform_hopping=true}),
--★ FISH：钓鱼（淡水）。空 Action()。
--   ★ 与 FISH_OCEAN 对比：本动作连 customarrivecheck 都没有，
--     因为钓池塘/河不需要特殊到达判定。
    FISH = Action(),
--★★ REEL：收线。instant=true ⇒ 收线是单次点击（不是按住）。
--   ★★ fn（1890 行）是一个**三态分派**：
--     有鱼上钩 → Reel() / 咬钩但没刺中 → Hook() / 否则 → StopFishing()
--   ★ 一个动作 = 收线 + 刺 + 取消，全部靠状态判断。
--   ★ strfn（1904 行）用 client 副本 replica.fishingrod 来决定显示哪个词，
--     保证 UI 与实际状态一致。这是「strfn 必须只读副本」的好例子。
    REEL = Action({ instant=true }),
--★ OCEAN_FISHING_POND：鱼塘。空 Action()。fn（1384 行）只检查虚拟海洋标签。
    OCEAN_FISHING_POND = Action(),
--★★ OCEAN_FISHING_CAST：投竿。priority=3 + invalid_hold_action。
--   ★★ 海洋三件套之二（customarrivecheck=CheckOceanFishingCastRange，
--     探针距离 1.5 而不是 0.25 —— 要助跑空间）。
--   ★ priority=3：拿鱼竿对着水时，投竿要压过一切其他动作。
    OCEAN_FISHING_CAST = Action({priority=3, rmb=true, customarrivecheck=CheckOceanFishingCastRange, is_relative_to_platform=true, disable_platform_hopping=true, invalid_hold_action=true}),
--★★ OCEAN_FISHING_REEL：收深海鱼。priority=5 —— 全表最高的非 HIGH 值。
--   ★★ 为什么是 5？因为钓鱼是一个「长流程」：
--     玩家一旦上钩，必须保证收线动作不会被任何其他动作抢走。
--     priority=5 让它压过 CASTSPELL(3) 等全部常规动作。
--   do_not_locomote ⇒ 收线时不移动
--   silent_fail ⇒ §二 提到的唯一用户：收线失败太频繁，别吵玩家。
--   ★★ 值得注意：priority=5 > HIGH_ACTION_PRIORITY/2，说明
--     「界面型动作」与「流程型动作」的优先级是同一个连续谱。
    OCEAN_FISHING_REEL = Action({priority=5, rmb=true, do_not_locomote=true, silent_fail = true }),
--★ OCEAN_FISHING_STOP：停止钓鱼。instant=true。
--   ★ fn（1416 行）示范了 T5 模板：显式 GoToState + 调组件方法。
--     `act.doer.sg:GoToState("oceanfishing_stop")`
    OCEAN_FISHING_STOP = Action({instant=true}),
--★ OCEAN_FISHING_CATCH：钓上鱼。priority=6 —— 全表最高（除 HIGH=10）。
--   ★★ 比 REEL(5) 高一档，因为「上钩」是整个流程的**终点**，
--     必须在同一帧被抓住，不能给任何其他动作插队的机会。
--   instant=true ⇒ 拿到就结束。
    OCEAN_FISHING_CATCH = Action({priority=6, instant=true}),
--★★ CHANGE_TACKLE：装子弹 / 换诱饵。priority=3 + instant + mount_valid。
--   ★★ 保留的英文注释透露了它已被泛化：
--     「this is now a generic 'put item into the container of the
--       equipped hand item'」
--   ★ 所以 1444-1524 行那 80 行实现其实是一个通用的
--     「往手持物的容器里塞东西」引擎（含堆叠、特定槽位、替换三种情形）。
--   ★ 这是本文件里「注释说明了重构历史」的又一例。
    CHANGE_TACKLE = Action({priority=3, rmb=true, instant=true, mount_valid=true}), -- this is now a generic "put item into the container of the equipped hand item"
--★ POLLINATE：授粉（韦伯）。空 Action()。fn（2850 行）两分支：
--   有目标 → Pollinate(target)；无目标 → CreateFlower()（凭空造花）。
    POLLINATE = Action(),
--★ FERTILIZE：施肥。priority=1 —— 高于 STORE(0)，因为「对着作物」比
--   「对着箱子」更具体。
--   ★★ fn（1806 行）是**六分支**的组件探测（crop/grower/pickable/
--     quagmire_fertilizable/fertilizable），且注意 1823 行的回退：
--     没作用于目标时**可以给自己施肥**（对泥土堆）。
    FERTILIZE = Action({priority=1, mount_valid=true }),
--★ SMOTHER：闷火。priority=1 + mount_valid。
--   ★★ fn（1838 行）用 `act.invobject or act.doer` ——
--     意味着「用物品闷」与「用手闷」都是同一个动作（T7 模板）。
--   ★ 而 485 行 STARTCHANNELING 的注释提到「priority 高于 smother」，
--     说明两者会在同一目标（水泵）上竞争。
    SMOTHER = Action({ priority=1, mount_valid=true }),
--★ MANUALEXTINGUISH：手动灭火（用冰块）。priority=1。
--   ★ fn（1846 行）要求 invobject 有 "frozen" 标签 + 目标在燃烧，
--     并调用 Extinguish 带回热量的版本。
    MANUALEXTINGUISH = Action({ priority=1 }),
--★ LAYEGG：产蛋。空 Action()。fn（2890 行）用 `not canbepicked` 判定
--   「现在是否可以采蛋」。
    LAYEGG = Action(),
--★ HAMMER：锤击。第四个工具动作（CHOP/MINE/DIG 之外）。
--   ★ priority=3（而非缺省 0）—— 拿锤子时锤击是强意图。
--   ★★ 注意 HAMMER 是四工具中**唯一**有 priority 的。
--     原因在 componentactions.lua:3063：
--       workable = function(inst, action, right)
--           return (right or action ~= ACTIONS.HAMMER)
--              and inst:HasTag(action.id.."_workable")
--     ★★ `right or action ~= HAMMER` 意味着「锤击只能右键触发」，
--       且这个特判**写在 componentactions 里而不是 Action 字段里**。
--       呼应 310 行的注释：rmb 字段只对工具有效。
	HAMMER = Action({ priority=3, invalid_hold_action=true }),
--★★ TERRAFORM：改造地形（树叶变木头、草变土）。tile_placer="gridplacer"。
--   ★ 这是「批量改造」的入口，fn（2860 行）只转发给 terraformer 组件。
--   ★ 批量操作的代价：无法 instant（要按住），也无法 canforce。
    TERRAFORM = Action({ tile_placer="gridplacer" }),
--★ JUMPIN：跳进（门 / 洞穴）。ghost_valid + encumbered_valid。
--   ★★ fn（2969 行）是 T5 模板的典范：
--     它**检查 sg 当前状态**（currentstate.name == "jumpin_pre"），
--     只有在「准备跳」的动画帧里才切到 jumpin 状态。
--   ★★★ 这是 DST 的「两阶段动作」模式：
--     动作 → sg 切到 *_pre → 动画中再触发同一动作 → 切到正式状态。
--     ★ 出现三次：JUMPIN(2972) / CLIMB(6971) / SITON(5993) /
--       JUMPIN_MAP(3029) / TELEPORT(3061)。
--     ★★ 目的：让长距离传送（Winona 的洞）有「蓄力」的表现，且能被打断。
--     ⚠ 副作用：fn 在非 *_pre 状态下返回 nil（失败），
--       这使得重复触发同一动作会被静默忽略。
    JUMPIN = Action({ ghost_valid=true, encumbered_valid=true }),
--★ JUMPIN_MAP：地图版跳跃。HIGH_ACTION_PRIORITY + rmb + map_action + closes_map。
--   ★★ 四字段组合的含义：打开地图 → 右键点一个位置 → 立刻关地图 → 传过去。
--   ★ 呼应 §零 276 行的英文注释「translate normal actions the player could
--     do in the game but done on the map instead」。
    JUMPIN_MAP = Action({priority=HIGH_ACTION_PRIORITY, rmb=true, ghost_valid=true, encumbered_valid=true, map_action=true, closes_map=true,}),
--★ TELEPORT：传送（给物品）。rmb=true + distance=2（很近）。
--   ★ fn（3057 行）也是两阶段：检查 sg 处于 dolongaction 或 give 状态。
--     ★★ `elseif act.target ~= nil and sg.currentstate.name == "give"` ——
--       意味着「对别人使用传送物」这个意图被编码成**送礼动作的变体**。
--       这是「复用已有状态」而不是新造状态的典型。
    TELEPORT = Action({ rmb=true, distance=2 }),
--★ RESETMINE：重置地雷（炸了之后重置引信）。priority=3。
    RESETMINE = Action({ priority=3 }),
--★★ ACTIVATE：激活。priority=2 + invalid_hold_action。
--   ★★ 这是「最泛用的动作」：门、箱子、机关、洞穴… 全走它。
--     因此它的 strfn 与 stroverridefn 都被设计成**委托给实体**：
--       strfn         → act.target:GetActivateVerb(doer)
--       stroverridefn → act.target:OverrideActivateVerb(doer)
--   ★★ 这是一个值得学的模式：**通用动作 + 实体自描述 UI**。
--     模组新增可激活物时，只要实现这两个方法即可，无需动 actions.lua。
--   ★ fn（3082 行）还做了 activatable/CanActivate/DoActivate 三段，
--     其中 3091 行的注释「for legacy reasons, nil will be true」说明
--     DoActivate 返回 nil 被当作成功 —— 又一处「为兼容牺牲严格性」。
    ACTIVATE = Action({ priority=2, invalid_hold_action = true }),
--★★ OPEN_CRAFTING：打开制作台。distance=nil（不用距离，靠状态图）
--   + extra_arrive_dist=ExtraOpenCraftingRange（§零 266 行的「反向」计算）。
--   ★★ priority=2 与 ACTACTIVATE 同级：对着制作台时，「打开」优先于「翻找」。
    OPEN_CRAFTING = Action({priority=2, distance = nil, extra_arrive_dist=ExtraOpenCraftingRange}),
--★ MURDER：谋杀（杀掉手里的生物并抢走战利品）。priority=1 + mount_valid。
--   ★★★ fn（3153 行）是全文件**唯一执行完整处决流程**的动作：
--     取出物品 → 播放 murder 音效 → 推 murdered/killed 事件 →
--     生成战利品 → 转移背包 → Remove()
--   ★ 3170 行「NOTES(JBK): Push the events before spawning any giving any
--     loot.」是关键的顺序说明：事件必须先于战利品掉落，
--     否则监听 killed 的模组/成就拿不到正确的死亡时刻。
--   ★★ 3157 行的 `RemoveFromOwner(true, true)` 双 true 是「连同堆叠一起」，
--     保证处决整堆。
    MURDER = Action({ priority=1, mount_valid=true }),
--★ HEAL：治疗。mount_valid + extra_arrive_dist=ExtraHealRange（§零 246 行，
--   那个针对 Brightshades 的补丁）。
    HEAL = Action({ mount_valid=true, extra_arrive_dist=ExtraHealRange }),
--★ INVESTIGATE：调查。空 Action()。fn（2896 行）读 knownlocations。
    INVESTIGATE = Action(),
--★ UNLOCK：解锁。空 Action()。fn（3215 行）里保留了被注释掉的 Lock 分支 ——
--   ★★ 说明「重新上锁」功能曾存在后被移除，但 Unlock/Lock 的接口设计
--     在 components/lock.lua 里仍然对称。
    UNLOCK = Action(),
--★ USEKLAUSSACKKEY：开魔法高礼帽。空 Action()。
    USEKLAUSSACKKEY = Action(),
--★ TEACH：教（ scrapbook / 地图 / 菜谱扫描）。mount_valid。
--   ★ strfn（3236 行）四分支显示不同动词（NOTES/SCRAPBOOK/READ/SCAN）。
    TEACH = Action({ mount_valid=true }),
--★ TURNON：开机（研究机器）。priority=2 + invalid_hold_action。
--   ★★ T4 模板：`if tar.components.machine and not tar.components.machine:IsOn()`
--     —— 只在「关着的时候」提供这个动作。这就是「用状态控制可用性」。
    TURNON = Action({ priority=2, invalid_hold_action = true, }),
--★ TURNOFF：关机。与 TURNON 严格镜像（检查 IsOn 为真）。
--   ★ strfn（3280 行）在有 hasemergencymode 标签时显示 "EMERGENCY"。
    TURNOFF = Action({ priority=2, invalid_hold_action = true, }),
--★ SEW：缝补。mount_valid。
--   ★ strfn（1003 行）在用胶带时返回 "PATCH"（缝 vs 补的语义区分）。
    SEW = Action({ mount_valid=true }),
--★★ STEAL：偷窃。声明里没有任何特殊字段，但行尾注释很重要：
--   「NOTES(JBK): If range check changes here do the appropriate checks in
--     the action.fn.」
--   ★★★ 这条注释解释了 811 行那段重复的距离检查为何存在：
--     动作**没有**声明 canforce/rangecheckfn，所以没有统一的范围校验，
--     fn 里就自己手写了一个 `GetDistanceSqToInst < 16`。
--   ★★ 于是 16 这个魔数与 16 行的 DefaultRangeCheck 完全独立。
--     改一处不会影响另一处 —— 这是本文件已知的技术债，注释已明确警告。
    STEAL = Action(), -- NOTES(JBK): If range check changes here do the appropriate checks in the action.fn.
--★ USEITEM：使用物品。priority=1 + instant。
--   ★★ fn（3293 行）里有一处**语义可疑**的检查：
--     3302 行 `act.doer.components.inventory:IsOpenedBy(act.doer)`
--     Inventory:IsOpenedBy(guy) 的实现（inventory.lua:2015）是
--       return self.isopen and self.isvisible and guy == self.inst
--     传入自己 ⇒ 判断「自己的背包是否开着且可见」，对玩家而言几乎恒为假。
--     ⚠ 推测原意是 `GetOpenContainer() ~= nil`（手里拿着东西）。
--     ★ 若确实恒假，则 useableitem 组件的物品（草、浆果的自动使用）
--       在某些状态下无法使用。记为疑似缺陷，见 p7。
    USEITEM = Action({ priority=1, instant=true }),
--★ USEITEMON：对某物使用。distance=2 + priority=1 + mount_valid。
--   ★★ 有 pre_action_cb（3322 行）：手柄模式下先关手柄背包。
--     注释解释「socketable 组件在客户端也可读」⇒ 可以纯客户端判断。
	USEITEMON = Action({ distance=2, priority=1, mount_valid=true }),
--★ STOPUSINGITEM：停止使用。priority=1。
    STOPUSINGITEM = Action({ priority=1 }),
--★★ USEEQUIPPEDITEM：使用已装备的物品。priority=1 + mount_valid，
--   **无 instant** —— 行尾注释「use case similar to USEITEM except not instant」。
--   ★★ USEITEM 与 USEEQUIPPEDITEM 的 instant 差异是有意的：
--     USEITEM 是「拿起即用」（一次性），USEEQUIPPEDITEM 是「按住持续用」。
--   ★ fn（3368 行）同样有 3374 行那个 IsOpenedBy 疑似问题。
	USEEQUIPPEDITEM = Action({ priority=1, mount_valid=true }), --use case similar to USEITEM except not instant
--★ STOPUSINGEQUIPPEDITEM：停止使用装备物。priority=1 + **instant** + mount_valid。
--   ★★ 与 450 行紧邻但 instant 相反（450 无，451 有），且 3380 行：
--     `ACTIONS.STOPUSINGEQUIPPEDITEM.strfn = ACTIONS.USEEQUIPPEDITEM.strfn`
--     注释写明「same fn, diff str table」——
--     ★★ 一个微妙的对照：函数共用，字符串表不同。
--     复用 fn 但不复用 strfn，于是 UI 上两者仍可区分。
	STOPUSINGEQUIPPEDITEM = Action({ priority=1, instant=true, mount_valid=true }),
--★ TAKEITEM：拿取（从架子上拿特定物品）。
--   ★ fn（3388 行）开头有英文注释解释它与 PICK/HARVEST 的区别：
--     「用于拿取**指定**物品，而不是像 Pick/Harvest 那样生成物品」。
--   ★★ 这是「取出」与「产出」的语义区别：TAKEITEM 不产生新物品。
    TAKEITEM = Action(),
--★ TAKESINGLEITEM：拿单个。与 TAKEITEM 共用 strfn 但 fn 不同（3418 行
--   传 false 表示不拿整堆）。这是 T12 模板的「只共用一半」变体。
    TAKESINGLEITEM = Action(),
--★ MAKEBALLOON：做气球（韦伯）。mount_valid。
    MAKEBALLOON = Action({ mount_valid=true }),
--★ CASTSPELL：施法（魔杖）。priority=-1 + rmb + distance=20 + mount_valid。
--   ★★ distance=20 —— 极远。因为魔杖是远程的。
--   ★ priority=-1（泛用档）：拿魔杖对着怪时，攻击(2) 会赢。合理。
    CASTSPELL = Action({ priority=-1, rmb=true, distance=20, mount_valid=true }),
--★ CAST_POCKETWATCH：施法（阿比盖尔的怀表）。行尾注释提到
--   「pocketwatch_mountedcast 标签」。★ 同样是 priority=-1 + rmb + mount_valid。
	CAST_POCKETWATCH = Action({ priority=-1, rmb=true, mount_valid=true }), -- to actually use the mounted action, the pocket watch will need the pocketwatch_mountedcast tag
--★★ BLINK：闪现（韦伯）。HIGH_ACTION_PRIORITY + rmb + distance=36 + mount_valid
--   + encumbered_valid。
--   ★★ distance=36 是全表第二远（仅次于 SET_HEADING 的 9999）。
--     36 是「灵魂跳跃」的理论最大距离。
--   ★ encumbered_valid：背着东西也能跳（代价在 fn 里按负重打折，见 3650 行）。
--   ★★ 高优先级 + 右键的组合意味着「右键永远优先闪现」，
--     除非该场景下某个 HIGH 动作也可用（如 BLINK_MAP）。
    BLINK = Action({ priority=HIGH_ACTION_PRIORITY, rmb=true, distance=36, mount_valid=true, encumbered_valid=true }),
--★ BLINK_MAP：地图闪现。HIGH + customarrivecheck=ArriveAnywhere + rmb +
--   mount_valid + encumbered_valid + map_action。
--   ★★ 3630 行之后的 ACTIONS_MAP_REMAP[ACTIONS.BLINK.code]（3604 行）
--     是本文件最复杂的函数（62 行）：它要计算消耗多少灵魂、
--     处理船上的 fogrevealer 瞄准辅助、算 distanceperhop…
--   ★ 那段代码是「地图动作重映射」的教科书。详见 p5。
    BLINK_MAP = Action({ priority=HIGH_ACTION_PRIORITY, customarrivecheck=ArriveAnywhere, rmb=true, mount_valid=true, encumbered_valid=true, map_action=true, }),
--★ COMBINESTACK：合并堆叠。mount_valid + extra_arrive_dist=ExtraPickupRange。
--   ★★★ 复用 ExtraPickupRange（§零 154 行）而不是新建一个，
--     是因为「把两个堆叠合起来」与「从水里捡起来」的到达条件相同。
--   ★ 4634 行的 DoActionAutoEquip 把它列入**不自动装备**白名单，
--     否则合并堆叠时会把物品塞进手里打断操作。
    COMBINESTACK = Action({ mount_valid=true, extra_arrive_dist=ExtraPickupRange }),
--★ TOGGLE_DEPLOY_MODE：切换放置模式。HIGH + instant + mount_valid +
--   floating_valid。
--   ★★ 1672 行 `ACTIONS.TOGGLE_DEPLOY_MODE.strfn = ACTIONS.DEPLOY.strfn` ——
--     复用 strfn 但不共用 fn（没有自己的 fn）。
--     这是 T12 的变体：只借 UI 字符串。
	TOGGLE_DEPLOY_MODE = Action({ priority=HIGH_ACTION_PRIORITY, instant=true, mount_valid=true, floating_valid=true }),
--★ SUMMONGUARDIAN：召唤守护者（阿比盖尔）。rmb=false + distance=5。
--   ★★ 显式写 rmb=false 很少见（不写默认也是 nil≈false）。
--     ★ 说明作者在「这个必须左键」的语义上想要**显式声明**，
--       大概是为了与周围 rmb=true 的动作做视觉对比。
    SUMMONGUARDIAN = Action({ rmb=false, distance=5 }),
--★★ HAUNT：附身。ghost_valid + ghost_exclusive + canforce +
--   DefaultRangeCheck + mindistance=2。
--   ★★★ ghost_exclusive=true（315 行）⇒ 幽灵专属动作。
--   ★ mindistance=2（312 行）—— 全文件仅 2 处用到 mindistance 之一。
--     ★★ 语义不是「距离下限」而是「太近不行」：
--       玩家幽灵需要靠近目标，但 2 格内附身会「吓跑」对方。
--     ⇒ mindistance 是一个**反向**约束，判断逻辑在别处。
    HAUNT = Action({ rmb=false, mindistance=2, ghost_valid=true, ghost_exclusive=true, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ UNPIN：拔图钉。空 Action()。
    UNPIN = Action(),
--★ STEALMOLEBAIT：偷鼹鼠的诱饵。rmb=false + distance=0.75（极近）。
--   ★★ 距离 0.75 说明这是「必须贴着鼹鼠才能偷」的技能动作。
    STEALMOLEBAIT = Action({ rmb=false, distance=.75 }),
--★ MAKEMOLEHILL：造鼹鼠丘。priority=4 + distance=0（原地）。
--   ★★ priority=4 —— 很高，因为这是鼹鼠玩家的核心技能，
--     必须压过几乎所有其他动作。
--   ★ fn（3721 行）两个分支生成两种丘（molehill / molebathill）。
    MAKEMOLEHILL = Action({ priority=4, rmb=false, distance=0 }),
--★ MOLEPEEK：鼹鼠偷看。rmb=false + distance=1。
--   ★ fn（3738 行）只 PushEvent("peek") —— 纯粹的信号动作。
    MOLEPEEK = Action({ rmb=false, distance=1 }),
--★★ FEED：喂食。priority=1 + rmb=true + mount_valid。
--   ★★ 有趣的是 FEED 与 FEEDPLAYER 都是 rmb=true，但优先级不同（1 vs 3）。
--     ★ 推测：喂 NPC 比喂玩家更需要「明确指向」，所以优先级更高。
--   ★★ fn（3749 行）是本文件**最长的单动作实现之一**（106 行），
--     因为「喂饱的宠物可能会死（吃肉）」需要完整的处决 + 战利品流程。
--     ★ 3825-3854 行还保留了一整段**被注释掉的旧实现**（30 行）——
--       保留了「处决流程的参考版本」，方便对照理解重构原因。
	FEED = Action({ priority=1, rmb=true, mount_valid=true }),
--★ UPGRADE：升级。rmb=true + priority=1。
    UPGRADE = Action({ rmb=true, priority=1 }),
--★ HAIRBALL：吐毛球（韦伯）。rmb=false + distance=3。
    HAIRBALL = Action({ rmb=false, distance=3 }),
--★ CATPLAYGROUND：猫玩闹（猫猫）。rmb=false + distance=1。
    CATPLAYGROUND = Action({ rmb=false, distance=1 }),
--★ CATPLAYAIR：猫空中玩闹。rmb=false + distance=2。
    CATPLAYAIR = Action({ rmb=false, distance=2 }),
--★ FAN：扇风。rmb=true + mount_valid。
    FAN = Action({ rmb=true, mount_valid=true }),
--★ ERASE_PAPER：擦纸。rmb=true + mount_valid。
    ERASE_PAPER = Action({ rmb=true, mount_valid=true }),
--★ DRAW：画画。空 Action()。
--   ★★ 4255 行在函数中间插了一行 `require("components/drawingtool")` ——
--     在 actions.lua 的函数体中间 require！这是为了延迟加载：
--     drawingtool 可能是个很大的组件文件，只在真正画时才需要。
--   ★★ 若 require 被重复执行（玩家画第二次画时），Lua 的 require 会
--     查缓存返回，所以安全。但这个位置仍然很反直觉。
    DRAW = Action(),
--★ BUNDLE：打包。rmb=true + priority=2。
    BUNDLE = Action({ rmb=true, priority=2 }),
--★ BUNDLESTORE：打包后放入容器。instant=true。
--   ★ 2598 行 `ACTIONS.BUNDLESTORE.fn = ACTIONS.STORE.fn` —— T12 模板。
--   ★★ strfn（2588 行）会在「正在为这个容器施工」时返回 "CONSTRUCT"，
--     即**同一个动作在建造语境下显示成另一个词**。
    BUNDLESTORE = Action({ instant=true }),
--★ WRAPBUNDLE：捆扎完成。instant=true。
    WRAPBUNDLE = Action({ instant=true }),
--★ UNWRAP：拆包。rmb=true + priority=2。
    UNWRAP = Action({ rmb=true, priority=2 }),
--★ PEEKBUNDLE：窥视包内。rmb=true + priority=2。
    PEEKBUNDLE = Action({rmb=true, priority=2}),
--★ BREAK：破坏。rmb=true + priority=2。
--   ★ strfn（4376 行）在目标有 pickapart 标签时返回 "PICKAPART"。
	BREAK = Action({ rmb=true, priority=2 }),
--★ CONSTRUCT：施工。priority=1 + distance=2.5。
--   ★★★ 这是本文件里**分支最多的 strfn**（4393-4405 行）：
--     手上没材料 → OFFER_TO / REPAIR / REBUILD
--     手上材料 + 目标是工地 → STORE
--     手上材料 + 目标是材料堆 → OFFER
--   ★★ 五种显示名对应五条完全不同的流程，是「一个动作多种语义」的极致。
	CONSTRUCT = Action({ priority=1, distance=2.5 }),
--★ STOPCONSTRUCTION：停止施工。priority=1 + instant + distance=2。
	STOPCONSTRUCTION = Action({ priority=1, instant=true, distance=2 }),
--★ APPLYCONSTRUCTION：应用材料（放最后一个材料）。priority=1 + instant。
	APPLYCONSTRUCTION = Action({ priority=1, instant=true, distance=2 }),
--★ 484 行的行内注释 `--channeling for scene entity` 是一处**分类标记**。
--   ★★ 它把动作分成两类：
--     · channeling for scene entity（485/486）—— 对场景物体引导
--     · channeling for equipped item（488/489）—— 用手持物品引导
--   ★ 两组都有 START/STOP 成对，且 fn 名称遵循同一命名法。
	--channeling for scene entity
--★★ STARTCHANNELING：对物体引导（抽水机等）。priority=2 + distance=2.1。
--   ★★ 保留的英文注释是一句**设计权衡记录**：
--     「保持比 smother 更高的优先级，让水泵能用；但如果以后有更多
--       东西变得可引导，就需要另做处理。」
--   ★★★ 这是全文件最重要的一条「未来隐患」注释：
--     它承认 priority=2 是为了压过 SMOTHER(426 行 priority=1) 而硬设的，
--     并且明确指出扩展时会冲突。
    STARTCHANNELING = Action({ priority=2, distance=2.1 }), -- Keep higher priority over smother for waterpump but do something else if channelable is added to more things.
--★ STOPCHANNELING：停止引导。instant + distance=2.1（与 START 一致）。
    STOPCHANNELING = Action({ instant=true, distance=2.1 }),
--★ 487 行的行内注释标记「第二个 channeling 类别」。
	--channeling for equipped item
--★ START_CHANNELCAST：用装备引导。priority=-1 + rmb + do_not_locomote。
--   ★★ do_not_locomote：引导时人不能移动（与 SCENE 版不同，
--     因为手持物品的引导本来就是站桩）。
	START_CHANNELCAST = Action({ priority=-1, rmb=true, do_not_locomote=true }),
--★ STOP_CHANNELCAST：停止用装备引导。与 488 对称。
	STOP_CHANNELCAST = Action({ priority=-1, rmb=true, do_not_locomote=true }),
--★ 490 行单个 `--` 注释是「空注释块」的收尾，标记前面这一段结束。
	--
--★ APPLYPRESERVATIVE：涂防腐剂（盐）。空 Action()。
	APPLYPRESERVATIVE = Action(),
--★★ COMPARE_WEIGHABLE：比重量。HIGH_ACTION_PRIORITY + encumbered_valid。
--   ★★★ 这是 encumbered_valid 最合理的用例：
--     玩家**正在**搬重物（超重）时，反而需要能上称。
--     4124 行 fn 印证：没手持物时会去查 BODY 槽的装备。
--   ★★ LOCAL 辅助函数 COMPARE_WEIGHABLE_TEST（4628 行）用标签交叉验证：
--     目标是 trophiescale_XX 且物品是 weighable_XX。
--   ★ 这是「标签即类型」的典型：不需要继承、不需要查表。
    COMPARE_WEIGHABLE = Action({ encumbered_valid=true, priority=HIGH_ACTION_PRIORITY }),
--★ WEIGH_ITEM：称重（电子秤）。空 Action()。
--   ★ fn（4660 行）用一个漂亮的表达式同时确定「谁是秤谁是物」：
--     `weigher ~= act.target and act.target or act.invobject`
--   ★★ 这种「三元 Lua」写法要求读者熟悉 Lua 的 and/or 惯用法。
	WEIGH_ITEM = Action(),
--★ START_CARRAT_RACE：开赛（嘉年华）。rmb=true。
	START_CARRAT_RACE = Action({ rmb = true }),
--★ CASTSUMMON：召唤幽灵。rmb=true + mount_valid + priority=3。
	CASTSUMMON = Action({ rmb=true, mount_valid=true, priority=3 }),
--★ CASTUNSUMMON：收回幽灵。mount_valid + distance=math.huge + priority=3。
--   ★★ distance=math.huge：「在任意远处收回」—— 幽灵跟着你，不需要靠近。
	CASTUNSUMMON = Action({ mount_valid=true, distance=math.huge, priority=3 }),
--★ COMMUNEWITHSUMMONED：与幽灵交流。rmb=true + mount_valid + priority=2。
--   ★ strfn（3680 行）根据 has_aggressive_follower 标签切换「改为攻击/改为防御」，
--     即「同一动作，一键切换幽灵指令」。
	COMMUNEWITHSUMMONED = Action({ rmb=true, mount_valid=true, priority=2 }),
--★ TELLSTORY：讲故事。rmb=true + distance=3。
--   ★★ 1574 行保留的英文注释解释了 stroverridefn 的用意：
--     「我们只是返回同样的字符串，但因为它被『覆盖』了，
--       它不会显示目标：例如不会显示『Tell Story Portable Campfire』。」
--   ★★★ 这解释了 bufferedaction.lua:53-64 的 overriden 机制：
--     stroverridefn 返回 (str, true) 时，第二个返回值告诉调用方
--     「我已经完全接管了这个字符串，别再拼接目标名」。
--   ★ 对比 strfn：strfn 返回的只是**修饰词**（会与目标名拼接）。
--     ★ 这是两种字符串钩子的根本区别，见 bufferedaction.lua:52。
    TELLSTORY = Action({ rmb=true, distance=3 }),
--★ PERFORM：表演。rmb=true + distance=1.5 + invalid_hold_action。
    PERFORM = Action({ rmb=true, distance=1.5, invalid_hold_action=true }),
--★ 500 行空行把「基础动作」与「投掷/季节动作」分隔开。
--   ★ 这不是硬分组，但确实形成了本表最长的一个视觉段落（359-499）。

--★★ TOSS：投掷。priority=1 + rmb=true + distance=8 + mount_valid。
--   ★★ distance=8 与 170 行 `ExtraDeployDist` 里的 `8 - DEPLOY.distance`
--     是同一个 8。两处独立字面量，靠注释而非常量关联。
--   ★ fn（3934 行）是本文件最复杂的投掷实现（47 行），要处理：
--     无手��物时用手持物（须有 special_action_toss 标签）、
--     物品有 equippable 时检查限制、伪装检查、投掷偏移量（targetoffset）。
    TOSS = Action({priority=1, rmb=true, distance=8, mount_valid=true }),
--★ TOSS_MAP：地图投掷。HIGH + ArriveAnywhere + rmb + map_action + closes_map。
--   ★★ 4003 行 `ACTIONS_MAP_REMAP[ACTIONS.TOSS.code]` 是地图重映射的
--     第二个实例（第一个是 ACTIVATE 1277 行，第三个是 BLINK 3604 行）。
--     它做了 min/max 距离夹取与「目标必须是真水面」的校验。
    TOSS_MAP = Action({ priority=HIGH_ACTION_PRIORITY, customarrivecheck=ArriveAnywhere, rmb=true, mount_valid=true, map_action=true, closes_map=true, }),
--★ NUZZLE：蹭。空 Action()。fn（4057 行）只 return true（连 print 都是注释）。
--   ★★ 4059 行有一行被注释掉的 print，作者自己把它去掉了。
    NUZZLE = Action(),
--★ WRITE：写（告示牌）。空 Action()。
--   ★ fn（4064 行）里又一处「黑暗中静默失败」（4075 行 CanEntitySeeTarget）。
    WRITE = Action(),
--★ ATTUNE：调频（韦伯）。空 Action()。
    ATTUNE = Action(),
--★★ REMOTERESURRECT：远程复活。rmb=false + ghost_valid + ghost_exclusive。
--   ★★ ghost_exclusive ⇒ 只有幽灵能用「复活自己」的道具。
--     与 HAUNT 同族。fn（4098 行）读 attuner 的调频目标。
    REMOTERESURRECT = Action({ rmb=false, ghost_valid=true, ghost_exclusive=true }),
--★★ REVIVE_CORPSE：复活尸体。rmb=false + **actionmeter=true**。
--   ★★ 全文件唯一使用 actionmeter 的动作（§一 327 行已详述）。
--     玩家按住复活尸体时会看到进度环 —— 因为「读条」是必要的反馈。
--   ★ 对比普通的复活（用骨头）不需要读条，所以没有 actionmeter。
    REVIVE_CORPSE = Action({ rmb=false, actionmeter=true }),
--★ MIGRATE：迁移（狼人传送？）。rmb=false + encumbered_valid + ghost_valid。
    MIGRATE = Action({ rmb=false, encumbered_valid=true, ghost_valid=true }),
--★ MOUNT：骑乘。priority=1 + rmb=true + encumbered_valid。
--   ★★ fn（4122 行）是全文件**判定链最长**的动作之一（24 行，7 个分支）：
--     战斗中的生物（除战斗坐骑）→ 不可骑
--     无 rideable / canride 为假 / 已死 / 冰冻 / 已被拴 → 不可骑
--     已被骑 → INUSE
--     dogrider_only 标签与骑手不符 → 不可骑
--   ★ 每一条都有对应的失败原因或静默 false，是「穷举式校验」的范本。
    MOUNT = Action({ priority=1, rmb=true, encumbered_valid=true }),
--★ DISMOUNT：下坐骑。priority=1 + instant + rmb + mount_valid + encumbered_valid。
--   ★★ mount_valid=true 的含义特殊：下坐骑时当然还骑着，
--     这个标记保证「骑着时能下马」这件事不被 mount_valid 拦住。
--     ★ 这是 mount_valid 语义最容易误解的一处，注释里隐含但没写明。
    DISMOUNT = Action({ priority=1, instant=true, rmb=true, mount_valid=true, encumbered_valid=true }),
--★ SADDLE：上鞍。priority=1。
    SADDLE = Action({ priority=1 }),
--★ UNSADDLE：卸鞍。priority=3（比 SADDLE 高）+ rmb=false。
--   ★★ priority 不对称（1 vs 3）：卸鞍是「明确指令」，上鞍是「顺手」。
    UNSADDLE = Action({ priority=3, rmb=false }),
--★ BRUSH：刷毛。priority=3 + rmb=false。
    BRUSH = Action({ priority=3, rmb=false }),
--★ ABANDON：遗弃。rmb=true。fn（4200 行）两分支：
--   petleash（韦伯的宠物）或 follower（跟随者）。
--   ★★ 4202-4208 行有一段特殊逻辑：如果玩家没解锁 ORPHANAGE 科技树，
--     却「看起来应该能」（10 格内有 critterlab），则静默失败。
--     英文注释说「we could've been in range but the pet was out of range」——
--     即「距离判定已经放行了，但宠物实际不在附近，所以别真删」。
    ABANDON = Action({ rmb=true }),
--★ PET：撸。空 Action()。fn（4218 行）对 crittertraits 与 kitcoon 各推一个事件。
    PET = Action(),
--★ DISMANTLE：拆除。rmb=true。fn（4550 行）有完整的拆除前置检查：
--   容器打开中 → INUSE；非空 → NOTEMPTY；不可打开（烹饪中）→ COOKING。
--   ★★ 三种失败原因都是玩家会立刻理解的，很好的一致性设计。
    DISMANTLE = Action({ rmb=true }),
--★ TACKLE：冲撞。rmb=true + distance=math.huge + invalid_hold_action。
--   ★ distance=math.huge：冲撞是「朝一个方向扑」，不需要锁定目标距离。
    TACKLE = Action({ rmb=true, distance=math.huge, invalid_hold_action = true, }),
--★ GIVE_TACKLESKETCH：给鱼饵图纸。空 Action()。
	GIVE_TACKLESKETCH = Action(),
--★ REMOVE_FROM_TROPHYSCALE：从荣誉榜上取下物品。空 Action()。
	REMOVE_FROM_TROPHYSCALE = Action(),
--★ CYCLE：循环（唱歌贝壳、高尔夫球座）。rmb=true + priority=2。
--   ★ strfn（5155 行）按 singingshell / golf_tee 标签返回 TUNE / PAR。
--   ★ 这是「同一个组件 cyclable 服务多个道具」的例子。
	CYCLE = Action({ rmb=true, priority=2 }),
--★ 521 行空行标记「季节/扩展动作」段的开始。

--★★ CASTAOE：范围施法。HIGH + rmb + mount_valid + distance=8 +
--   invalid_hold_action。
--   ★★ 它是 HIGH 动作里唯一的「战斗」类，说明「开局必须能放 AOE」
--     比「攻击单个目标」更不能让路。
--   ★★ 另有一处特殊待遇：playercontroller.lua:4563-4574 允许
--     施法在 busy 状态下重复（CanRepeatCast）。见 §五 的说明。
	CASTAOE = Action({ priority=HIGH_ACTION_PRIORITY, rmb=true, mount_valid=true, distance=8, invalid_hold_action=true }),
--★ 523 行空行。

--★ HALLOWEENMOONMUTATE：万圣节月相药水。priority=-1。
--   ★★ fn（4582 行）里有一行**被注释掉的判据**（4585 行）：
--     `--or (not act.target:HasTag("flying") and not IsPassableAtPoint(...))`
--   ★ 这行注释揭示了一个被**放宽**的限制：曾要求目标不能飞行、
--     且必须站在可通行地面上。现在去掉了 —— 大概是为了允许在船上使用。
--   ★★ 保留被注释掉的判据是好习惯：它记录了「为什么现在的逻辑更宽松」。
	HALLOWEENMOONMUTATE = Action({ priority=-1 }),
--★ 525 行空行。

--★ WINTERSFEAST_FEAST：冬至节盛宴。priority=1。
--   ★★★ fn（5198-5201）是全文件**最极端的空实现**：
--       function(act)
--           return true
--           -- Logic is handled from stategraph; action is never actually performed
--       end
--   ★★ 注意 return true **写在注释之前** —— 也就是说后面那行注释
--     在语法上已经不可达（虽然注释本来就不影响语义）。
--     ★ 作者的意图是「return true 之后的代码不会执行」，
--       于是把说明放在了后面。写法古怪但意图清晰。
--   ★★ 为什么会这样？因为「吃宴席」的表演（坐下、吃、多人同时）
--     必须在状态图里实现，动作本身只是个触发信号。
	WINTERSFEAST_FEAST = Action({ priority=1 }),
--★ 527 行空行。

--★ BEGIN_QUEST：接任务。空 Action()。
    BEGIN_QUEST = Action(),
--★ ABANDON_QUEST：放弃任务。空 Action()。
    ABANDON_QUEST = Action(),
--★ 530 行空行。

--★ SING：唱歌。rmb=true + mount_valid。
    SING = Action({ rmb=true, mount_valid=true }),
--★★ SING_FAIL：唱歌失败。rmb=true + mount_valid —— 与 SING 声明完全相同！
--   ★★★ 这是 T6 影子动作最纯粹的一个例子：
--     两个 Action 的**声明一字不差**，只有 fn 不同。
--       SING      fn → 有 singinginspiration 就 Sing（5235 行）
--       SING_FAIL fn → `return true`（5246 行）
--   ★★ 为什么要这样？见 SGwilson.lua:1301：
--       ActionHandler(ACTIONS.SING_FAIL, "sing_fail")
--     ★ 失败时要走**另一个状态**（sing_fail），而状态图按动作 id 路由。
--       如果复用 SING，SG 无法区分「正常唱」与「唱失败」这两个事件。
--   ★★ 本质上：影子动作 = 「同一个玩家意图，不同的执行结果」
--     在状态图里的两个不同状态。这是一种很 economical 的建模。
    SING_FAIL = Action({ rmb=true, mount_valid=true }),
--★ 533 行空行 —— 标记从「基础/通用动作」到「Quagmire 等 DLC 动作」的分界。

--★ 534 行的 `--Quagmire` 标记引入了第一批带玩法归属的动作。
--   ★★ 534-741 共 200 行里，约 60% 属于某个角色或季节。
--     这解释了为什么表尾越积越长：每加一个角色就追加一段。
    --Quagmire
--★★ TILL：开垦。distance=0.5（极近！）+ theme_music="farming"。
--   ★★ distance=0.5 是全表最小值。为什么？
--     因为开垦要求玩家**站在田的正中间**，否则格子会被算到隔壁。
--     ★ 这是「格子级精度」要求到达距离的例子，与 CheckTileWithinRange
--       （§零 121 行）呼应 —— 两者一起把开垦做成了「精准站位」交互。
    TILL = Action({ distance=0.5, theme_music = "farming" }),
--★ PLANTSOIL：种土。theme_music="farming"，无距离。
    PLANTSOIL = Action({ theme_music = "farming" }),
--★ INSTALL：安装（Quagmire）。空 Action()。
    INSTALL = Action(),
--★ TAPTREE：接树液管。priority=1 + rmb=true。
    TAPTREE = Action({priority=1, rmb=true}),
--★ SLAUGHTER：屠宰。canforce + DefaultRangeCheck。
--   ★ fn（4772 行）里有**独立的手写距离检查**（4778 行 IsNear(target, 2)），
--     与 446 行 STEAL 的做法相同：没有声明 rangecheckfn 就自己写。
--   ★★ 这里是 2 而 DefaultRangeCheck 是 4 —— 屠宰允许更近。
    SLAUGHTER = Action({ canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ REPLATE：换盘子。空 Action()。
    REPLATE = Action(),
--★ SALT：腌渍。空 Action()。
    SALT = Action(),
--★ 542 行空行。

--★ BATHBOMB：浴弹。空 Action()。
    BATHBOMB = Action(),
--★ 544 行空行。

--★ COMMENT：点评（动物花纹）。distance=4。
--   ★★ fn（2908 行）区分 npc_talker 与 talker 两套组件 ——
--     「能评论」这个玩法同时对玩家与 NPC 开放。
    COMMENT = Action({distance = 4}),
--★ WATER_TOSS：水中投掷。priority=3 + rmb + CheckOceanFishingCastRange
--   + is_relative_to_platform + disable_platform_hopping。
--   ★★ 3982 行 `ACTIONS.WATER_TOSS.fn = ACTIONS.TOSS.fn` —— T12 模板。
--     与 TOSS 的差别：priority(3 vs 1) 与 customarrivecheck（有 vs 无）。
--   ★ priority=3 保证「对着水面投掷」压过「对地面投掷」。
    WATER_TOSS = Action({ priority=3, rmb=true, customarrivecheck=CheckOceanFishingCastRange, is_relative_to_platform=true, disable_platform_hopping=true}),
--★ 547 行空行 + 548 行 `-- boats` 标记：船只动作段开始。
--   ★★ 549-601 共 53 行全是船相关动作，是 ACTIONS 表里最大的单一主题块。
--     共同特征：几乎全部有 distance 且都带 invalid_hold_action，
--     因为船上操作必须「按住」且不能误触。

    -- boats
--★ RAISE_SAIL：升帆。distance=1.25 + invalid_hold_action。
--   ★★ 4810 行保留的英文注释直言「this name is backwards」：
--     「raising 在这里意味着『把帆升满』」—— 作者认为命名反了但不改。
--   ★★ 这种「明知命名不佳但保留」的情况是重构债的化石，注释是唯一的线索。
    RAISE_SAIL = Action({ distance=1.25, invalid_hold_action = true }),
--★ LOWER_SAIL：降帆。distance=1.25 + invalid_hold_action。
--   ★★ 4821 行又一句「this name is backwards」：
--     「lowering 意味着『把帆卷起来』」。同样不改。
    LOWER_SAIL = Action({ distance=1.25, invalid_hold_action = true }),
--★ LOWER_SAIL_BOOST：加速降帆。distance=1.25 + invalid_hold_action。
--   ★ fn（4829 行）叠加两个乘数：expertsailor 的力量 × 船员加成。
    LOWER_SAIL_BOOST = Action({ distance=1.25, invalid_hold_action = true }),
--★★ LOWER_SAIL_FAIL：降帆失败。distance=1.25 + **do_not_locomote** +
--   invalid_hold_action。
--   ★★ 与 551 行的唯一差别是 do_not_locomote=true。
--     含义：失败时玩家已经站在那了，不要再走一次。
--     ★ 又一个 T6 影子动作 —— 连距离都要抄一遍，
--       说明「影子动作必须完整复制声明」是这个模式的固有负担。
    LOWER_SAIL_FAIL = Action({ distance=1.25, do_not_locomote=true, invalid_hold_action = true }),
--★ RAISE_ANCHOR：抛锚。distance=2.5 + invalid_hold_action。
    RAISE_ANCHOR = Action({ distance=2.5, invalid_hold_action = true }),
--★ LOWER_ANCHOR：起锚。distance=2.5 + invalid_hold_action。
    LOWER_ANCHOR = Action({ distance=2.5, invalid_hold_action = true }),
--★ EXTEND_PLANK：伸出跳板。distance=2.5 + invalid_hold_action。
    EXTEND_PLANK = Action({ distance=2.5, invalid_hold_action = true }),
--★ RETRACT_PLANK：收回跳板。distance=2.5 + invalid_hold_action。
    RETRACT_PLANK = Action({ distance=2.5, invalid_hold_action = true }),
--★ ABANDON_SHIP：弃船。distance=2.5 + priority=4 + invalid_hold_action。
--   ★★ priority=4 很高：弃船是「不可逆」的极端操作，需要玩家明确意图。
    ABANDON_SHIP = Action({ distance=2.5, priority=4, invalid_hold_action = true }),
--★ MOUNT_PLANK：上跳板。distance=0.5 —— 极近，呼应 TILL 的精度要求。
    MOUNT_PLANK = Action({ distance=0.5, invalid_hold_action = true }),
--★ DISMOUNT_PLANK：下跳板。distance=2.5。
--   ★★ 注意与 MOUNT_PLANK 不对称：上要 0.5，下要 2.5。
--     推断：上跳板要在板根（判定点），下跳板可以远远走下。
    DISMOUNT_PLANK = Action({ distance=2.5 }),
--★ REPAIR_LEAK：补船漏。distance=2.5 + invalid_hold_action。
    REPAIR_LEAK = Action({ distance=2.5, invalid_hold_action = true }),
--★★ STEER_BOAT：掌舵。**arrivedist=0.1**（全表最小）。
--   ★★ 0.1 格 —— 必须站得极近才能掌舵。
--     原因：舵要求「抓住舵柄」，站太远就抓不到。
--   invalid_hold_action ⇒ 掌舵不会自动重复。
--   ★ 它是全表**唯一**使用 arrivedist 而非 distance 的动作（另有 WOBY_PICKUP）。
    STEER_BOAT = Action({ arrivedist=0.1, invalid_hold_action = true }),
--★★ SET_HEADING：设定航向。distance=9999 + do_not_locomote。
--   ★★★ 9999 不是「无限」的等价写法吗？是的，但作者选择了具体数字。
--     ★★ 差别在于：locomotor.lua:947 判断 `>= math.huge`，
--       而 9999 < math.huge，所以它**不会**走「实质瞬间」那条分支！
--     ★★★ 这是一个真实的差异：
--       distance=math.huge → 走 947 行分支 → FaceMovePoint + Push
--       distance=9999        → 走最后的 else 分支 → GoToPoint(9999 格外)
--     ★ 幸而 do_not_locomote=true（945 行）在前面就拦住了，
--       所以结果一致 —— 但这是**两个标志的巧合**，不是设计。
--       ★ 同一份「转但不移动」的需求，这里用 (9999 + do_not_locomote)，
--         另一边 420 行 BOAT_MAGNET 与 596 行 BOAT_CANNON_SHOOT 也用 9999。
--   ★ 与 414 行 CATCH 用的是真正的 math.huge。对比之下更明显。
    SET_HEADING = Action({distance=9999, do_not_locomote=true, invalid_hold_action = true }),
--★ STOP_STEERING_BOAT：停止掌舵。**instant=true** —— 与 SET_HEADING 配对。
    STOP_STEERING_BOAT = Action({ instant = true }),
--★★ CAST_NET：撒网。HIGH + rmb + distance=12 + mount_valid
--   + disable_platform_hopping。
--   ★ distance=12 —— 海钓投竿的 1.2 倍。
--   ★★ 这是 HIGH 动作里唯一的「渔具」类，理由与 BLINK 类似：
--     撒网是长按蓄力动作，必须保证不被其他交互打断启动。
    CAST_NET = Action({ priority=HIGH_ACTION_PRIORITY, rmb=true, distance=12, mount_valid=true, disable_platform_hopping=true }),
--★ ROW_FAIL：划桨失败。ArriveAnywhere + disable_platform_hopping +
--   skip_locomotor_facing + invalid_hold_action。
--   ★★ ArriveAnywhere 让它「立即触发」—— 失败不需要走过去。
--   ★★ fn（1335 行）有一段极有价值的英文注释：
--     「不能靠返回 false 来触发失败串，因为返回 false 会跳过
--       finite uses 回调，桨就不会掉耐久。」
--   ★★★ 这解释了 T6 影子动作的**根本动机**：
--     有些副作用（耐久、语音）必须执行，但动作仍要报告「成功」，
--     否则 inventory 的 finiteuses 回调不会跑。
--     ⇒ 于是只能「真的成功」，失败反馈全部手动 Say（1343 行）。
    ROW_FAIL = Action({customarrivecheck=ArriveAnywhere, disable_platform_hopping=true, skip_locomotor_facing=true, invalid_hold_action = true}),
--★★ ROW：划桨。priority=3 + CheckRowRange + is_relative_to_platform
--   + disable_platform_hopping + invalid_hold_action。
--   ★★ ROW 与 ROW_CONTROLLER（567 行）的 fn 相同（1372/1376 行都调 row()），
--     但 ROW 有 CheckRowRange 而 ROW_CONTROLLER 没有。
--   ★ 推断：手柄玩家不需要「探针检查站位」，因为摇杆输入本身保证了站在船上。
--     ★★★ 这是「按输入设备分出两个动作」的少见做法。
    ROW = Action({priority=3, customarrivecheck=CheckRowRange, is_relative_to_platform=true, disable_platform_hopping=true, invalid_hold_action = true}),
--★ ROW_CONTROLLER：手柄划桨。priority=3 + is_relative_to_platform
--   + disable_platform_hopping + do_not_locomote + invalid_hold_action。
--   ★ do_not_locomote ⇒ 手柄玩家原地划。
    ROW_CONTROLLER = Action({priority=3, is_relative_to_platform=true, disable_platform_hopping=true, do_not_locomote=true, invalid_hold_action = true}),
--★ BOARDPLATFORM：上船。customarrivecheck=CheckIsOnPlatform（§零 99 行）。
--   ★★ fn（1380 行）只有 `return true`。这是 T5 的极端样本。
    BOARDPLATFORM = Action({ customarrivecheck=CheckIsOnPlatform }),
--★ OCEAN_TOSS：往海里扔。priority=3 + rmb + CheckOceanFishingCastRange
--   + is_relative_to_platform + disable_platform_hopping。
--   ★ 5174 行 fn 用 oceanthrowable 组件 + 手动 Launch（与 TOSS 的
--     complexprojectile:Launch 不同路径）。
    OCEAN_TOSS = Action({priority=3, rmb=true, customarrivecheck=CheckOceanFishingCastRange, is_relative_to_platform=true, disable_platform_hopping=true}),
--★ UNPATCH：拆补丁（Quagmire 临时）。distance=0.5。
    UNPATCH = Action({ distance=0.5 }),
--★★ POUR_WATER：浇水。rmb + tile_placer="gridplacer" +
--   show_tile_placer_fn + extra_arrive_dist=ExtraPourWaterDist（1.5）。
--   ★★ 它是**唯一一个 tile_placer + show_tile_placer_fn 同时使用**的动作：
--     有高亮框（因为要连续浇多格），且高亮逻辑要判断是否农田（141 行）。
--   ★ 注释互证：§零 148 行的英文注释说「悬停农田上时，
--     POUR_WATER_GROUNDTILE 会抢先」—— 即 572 行的动作。
    POUR_WATER = Action({rmb=true, tile_placer="gridplacer", show_tile_placer_fn=ShowPourWaterTilePlacer, extra_arrive_dist=ExtraPourWaterDist }),
--★★ POUR_WATER_GROUNDTILE：浇单个地面格子。rmb +
--   CheckTileWithinRange + tile_placer="gridplacer" + theme_music="farming"。
--   ★★ 5421 行 `ACTIONS.POUR_WATER_GROUNDTILE.fn = ACTIONS.POUR_WATER.fn`
--     —— T12 模板。
--   ★★ 注意两者都**没有 priority**（默认 0），所以「浇一格」与「浇一片」
--     是同级竞争。§零 148 行承认了这个竞争并用渲染守卫兜底。
    POUR_WATER_GROUNDTILE = Action({rmb=true, customarrivecheck=CheckTileWithinRange, tile_placer="gridplacer", theme_music = "farming" }),
--★ PLANTREGISTRY_RESEARCH_FAIL：植物研究失败。priority=-1。
--   ★★ 与 PLANTREGISTRY_RESEARCH（574 行 HIGH）成对。
--     失败版 priority=-1 而成功版 HIGH —— 优先级差 11，
--     保证了「成功研究」永远压过「失败研究」。
--   ★ fn（5426 行）返回 false + 失败原因（FERTILIZER / ITEMMIMIC）。
    PLANTREGISTRY_RESEARCH_FAIL = Action({ priority = -1 }),
--★ PLANTREGISTRY_RESEARCH：植物研究。priority=HIGH_ACTION_PRIORITY。
--   ★★ 优先级 10 与所有界面动作同级 —— 因为「打开研究界面」
--     与「传送到地图某点」一样会改变操作模式。
--   ★ 5432 行在 fn 开头 require 了 weed_defs（5501 行）—— 又一处延迟加载。
    PLANTREGISTRY_RESEARCH = Action({ priority = HIGH_ACTION_PRIORITY }),
--★ ASSESSPLANTHAPPINESS：评估作物心情。priority=1。
    ASSESSPLANTHAPPINESS = Action({ priority = 1 }),
--★ ATTACKPLANT：攻击作物（减压）。空 Action()。
    ATTACKPLANT = Action(),
--★ PLANTWEED：种草（替代作物）。空 Action()。
    PLANTWEED = Action(),
--★ ADDCOMPOSTABLE：加堆肥。空 Action()。
    ADDCOMPOSTABLE = Action(),
--★★ WAX：上蜡。encumbered_valid + **mindistance=1.5**。
--   ★★ 全文件仅 2 处 mindistance 之一（另一处是 HAUNT）。
--     语义：涂蜡需要看清蜡面，贴太近反而看不清（§一 312 行已述）。
--   ★ encumbered_valid：手上拿着东西也要能涂。
    WAX = Action({ encumbered_valid = true, mindistance=1.5 }),
--★ APPRAISE：鉴定。空 Action()。fn（768 行）是本文件**第一个 fn**。
    APPRAISE = Action(),
--★ UNLOAD_WINCH：绞盘卸货。rmb=true + priority=3。
    UNLOAD_WINCH = Action({rmb=true, priority=3}),
--★ USE_HEAVY_OBSTACLE：使用重型障碍物。encumbered_valid + rmb + priority=1。
--   ★★ 与 COMPARE_WEIGHABLE(492) 并列使用 encumbered_valid 的两个动作，
--     都是「超重状态下才需要做的事」。语义高度一致。
    USE_HEAVY_OBSTACLE = Action({encumbered_valid=true, rmb=true, priority=1}),
--★ ADVANCE_TREE_GROWTH：催长树。空 Action()。
    ADVANCE_TREE_GROWTH = Action(),
--★ 584 行空行。

--★★ ROTATE_BOAT_CLOCKWISE：船顺时针旋转。show_secondary_input_right=true
--   + rmb=true + priority=1。
--   ★★ show_secondary_input_right 是 342 行那个字段的唯一用户。
--     它的存在说明「按键提示」本身也需要被数据驱动 ——
--     因为这个动作绑定右键但长得像左键动作，UI 必须显式纠正。
    ROTATE_BOAT_CLOCKWISE = Action({ show_secondary_input_right = true, rmb = true, priority = 1 }),
--★ ROTATE_BOAT_COUNTERCLOCKWISE：船逆时针旋转。show_primary_input_left=true
--   + priority=1。
--   ★★ 两个旋转动作**刻意镜像**（一个显示右键提示，一个显示左键提示），
--     因为手柄上左右两个摇杆/按键对应两个方向。
    ROTATE_BOAT_COUNTERCLOCKWISE = Action({ show_primary_input_left = true, priority = 1 }),
--★ ROTATE_BOAT_STOP：停止旋转。空 Action()。
    ROTATE_BOAT_STOP = Action(),
--★ 588 行空行。

--★ BOAT_MAGNET_ACTIVATE：激活船磁铁。空 Action()。
    BOAT_MAGNET_ACTIVATE = Action(),
--★ BOAT_MAGNET_DEACTIVATE：取消船磁铁。空 Action()。
    BOAT_MAGNET_DEACTIVATE = Action(),
--★ BOAT_MAGNET_BEACON_TURN_ON：信标开启。rmb=true + priority=3。
    BOAT_MAGNET_BEACON_TURN_ON = Action({ rmb = true, priority=3 }),
--★ BOAT_MAGNET_BEACON_TURN_OFF：信标关闭。rmb=true + priority=3。
--   ★★ 与 591 完全对称（都是 rmb + priority=3），是成对设计的样本。
    BOAT_MAGNET_BEACON_TURN_OFF = Action({ rmb = true, priority=3 }),
--★ 593 行空行。

--★ BOAT_CANNON_LOAD_AMMO：装炮弹。distance=1.4 + mount_valid
--   + paused_valid + rmb=true + priority=3。
--   ★★ paused_valid 第二次出现（第一次是 ADDFUEL）——
--     理由相同：房主暂停时也要能管船。
--   ★ 5030 行 fn 显示：空手时会在背包里自动找炮弹（FindItem），
--     手上有东西时只用手上的。两种输入路径共用一个动作。
    BOAT_CANNON_LOAD_AMMO = Action({ distance=1.4, mount_valid=true, paused_valid=true, rmb=true, priority=3 }),
--★ BOAT_CANNON_START_AIMING：开始瞄准。distance=1.4。
--   ★ 有 pre_action_cb（5049 行）关法术轮盘。
    BOAT_CANNON_START_AIMING = Action({ distance=1.4 }),
--★★ BOAT_CANNON_SHOOT：开炮。distance=9999 + do_not_locomote。
--   ★ 与 562 行 SET_HEADING 同样的 (9999 + do_not_locomote) 组合。
--     fn（5066 行）有一个双分支：有 boatcannonuser 就用玩家的炮，
--     否则直接把目标的炮开火（NPC 触发）。
    BOAT_CANNON_SHOOT = Action({distance=9999, do_not_locomote=true}),
--★ BOAT_CANNON_STOP_AIMING：停止瞄准。instant=true。
    BOAT_CANNON_STOP_AIMING = Action({instant=true}),
--★ 598 行空行。

--★ OCEAN_TRAWLER_LOWER：放下拖网。distance=2.8 + rmb=true。
    OCEAN_TRAWLER_LOWER = Action({ distance=2.8, rmb=true }),
--★ OCEAN_TRAWLER_RAISE：升起拖网。distance=2.8 + rmb=true。
    OCEAN_TRAWLER_RAISE = Action({ distance=2.8, rmb=true }),
--★ OCEAN_TRAWLER_FIX：修拖网。distance=2.8。
    OCEAN_TRAWLER_FIX = Action({ distance=2.8 }),
--★ 602 行空行。

--★ EMPTY_CONTAINER：清空容器。空 Action()。
--   ★★ fn（959 行）有一处很有意思的「保留注释」：
--     964 行 `--act.target.components.container:DropEverything()` 被注释掉，
--     改成调用 `workable.onwork` 回调。
--   ★★ 保留了被注释的旧实现，读者能看出「清空」曾被重新设计为
--     「触发目标自己的 onwork 逻辑」——可能只是显示一下。
    EMPTY_CONTAINER = Action(),
--★ 604 行空行。

--★ CARNIVAL_HOST_SUMMON：召唤主持人。空 Action()。
    CARNIVAL_HOST_SUMMON = Action(),
--★ 606 行空行。

--★ 607 行的 `-- YOTB` 标记：Year of the Buffalo 系列。
    -- YOTB
--★ YOTB_SEW：缝纫。priority=1 + mount_valid。
    YOTB_SEW = Action({ priority=1, mount_valid=true }),
--★ YOTB_STARTCONTEST：开始比赛。空 Action()。
--   ★ fn（5580 行）有一段有趣的分支：主持人「有反应」(GetHostVisible) 时
--     会区分「是你」→ RIGHTTHERE 与「别人」→ NORESPONSE。
    YOTB_STARTCONTEST = Action(),
--★ YOTB_UNLOCKSKIN：解锁皮肤。空 Action()。
    YOTB_UNLOCKSKIN = Action(),
--★ 611 行空行。

--★ CARNIVALGAME_FEED：喂嘉年华游戏。mount_valid。
	CARNIVALGAME_FEED = Action({ mount_valid=true }),
--★ 613 行空行。

--★ 614 行的 `-- YOT_Catcoon` 标记。
	-- YOT_Catcoon
--★ RETURN_FOLLOWER：归还跟随者（猫猫）。空 Action()。
    RETURN_FOLLOWER = Action(),
--★ HIDEANSEEK_FIND：捉迷藏找藏身处。rmb=true + priority=1 + mount_valid。
    HIDEANSEEK_FIND = Action({ rmb=true, priority=1, mount_valid=true }),
--★ 617 行空行。

--★ 618 行的 `-- WEBBER` 标记：韦伯专属动作段。
--   ★★ 有趣：韦伯的动作**不全在这个段里** —— BLINK(457)、
--     REMOTERESURRECT(506)、BLINK_MAP(458) 都在前面的通用段。
--   ★ 分组依据是「作者写这段时的心情」而非「谁能用」。
    -- WEBBER
--★ MUTATE_SPIDER：变异蜘蛛。priority=2。
    MUTATE_SPIDER = Action({priority = 2}),
--★ HERD_FOLLOWERS：驱赶跟随者群。mount_valid。
    HERD_FOLLOWERS = Action({ mount_valid=true }),
--★ REPEL：驱赶。mount_valid。
    REPEL = Action({ mount_valid=true }),
--★ BEDAZZLE：眩光。空 Action()。fn（5641 行）是 T2 模板的干净样本。
    BEDAZZLE = Action(),
--★ 623 行空行。

--★ 624 行的 `-- WANDA` 标记。
    -- WANDA
--★ DISMANTLE_POCKETWATCH：拆怀表。mount_valid。
    DISMANTLE_POCKETWATCH = Action({ mount_valid=true }),
--★ 626 行空行。

--★ 627 行的 `-- WOLFGANG` 标记。
    -- WOLFGANG
--★★ LIFT_DUMBBELL：举哑铃。priority=2 + **mount_valid=false**。
--   ★★ 唯一显式写 mount_valid=false 的动作 —— 显式声明「默认值之外」
--     是一件有噪音的事，作者却写了，因为后面 630/631/632/635 行
--     也都重复了一遍。
--   ★ 行尾注释「Higher than TOSS」解释了 priority=2：
--     ★★ 举哑铃要压过投掷（438 行 TOSS 的 priority=3 其实是更高）——
--       等等，3 > 2，所以这个注释在数值上**与 TOSS 的声明矛盾**。
--   ★★★ 可能的解释：这里的「TOSS」指的是别的动作，或者注释指的是
--     「原版设计时的 TOSS 优先级」。不管哪种，这是一个可疑之处。
    LIFT_DUMBBELL = Action({ priority = 2, mount_valid=false }), -- Higher than TOSS
--★ 629 行空行。

--★ STOP_LIFT_DUMBBELL：停止举哑铃。priority=2 + mount_valid=false + instant。
    STOP_LIFT_DUMBBELL = Action({ priority = 2, mount_valid=false, instant = true }),
--★ ENTER_GYM：进健身房。mount_valid=false + invalid_hold_action。
    ENTER_GYM = Action({ mount_valid=false, invalid_hold_action = true }),
--★ UNLOAD_GYM：卸载杠铃。mount_valid=false。
    UNLOAD_GYM = Action({ mount_valid=false}),
--★ 633 行空行 + 634 行注释 `Minigame actions:` —— 引入 4 个小游戏动作。
--   ★★ 这组是 §6 的独特子型：动作本身没有业务逻辑，
--     全部表现与结算在 SGwilson.lua 的 minigame 状态里。
--   ★ 它们的共同字段：do_not_locomote + disable_platform_hopping
--     + skip_locomotor_facing + invalid_hold_action。
--     ★★ 四字段组合 = 「站在原地、按住、动画固定、动作中不可被其他动作抢占」。
--       这就是「禁止一切干扰」的表达方式。

--★ 634 行的注释标记了「小游戏动作」这一子类。
    -- Minigame actions:
--★ LEAVE_GYM：离开健身房。mount_valid=false + instant。
    LEAVE_GYM = Action({ mount_valid=false, instant = true }),
--★ LIFT_GYM_SUCCEED_PERFECT：举重完美成功。四字段全开（见 634 行说明）。
--   ★★ 三兄弟（LIFT_GYM_SUCCEED_PERFECT / LIFT_GYM_SUCCEED / LIFT_GYM_FAIL）
--     的声明**完全相同**，只有 pre_action_cb 的铃声不同（perfect/succeed/fail）。
--     ★ 又一个 T6 影子动作的变体，且是三个一组的。
--   ★★ 唯一区别在 pre_action_cb —— 声音在动作**开始前**就响了，
--     保证玩家不需要等 fn 执行。
    LIFT_GYM_SUCCEED_PERFECT = Action({ do_not_locomote=true, disable_platform_hopping=true, skip_locomotor_facing=true, invalid_hold_action = true }),
--★ LIFT_GYM_SUCCEED：举重成功。四字段全开。
    LIFT_GYM_SUCCEED = Action({ do_not_locomote=true, disable_platform_hopping=true, skip_locomotor_facing=true, invalid_hold_action = true }),
--★ LIFT_GYM_FAIL：举重失败。四字段全开。
    LIFT_GYM_FAIL = Action({ do_not_locomote=true, disable_platform_hopping=true, skip_locomotor_facing=true, invalid_hold_action = true }),
--★ 639 行空行。

--★ 640 行的 `-- WX78` 标记。
    -- WX78
--★ APPLYMODULE：安装模块。mount_valid。
    APPLYMODULE = Action({ mount_valid=true }),
--★ APPLYMODULE_FAIL：安装失败。mount_valid + instant。
--   ★★ 与 APPLYMODULE(641 行) 的唯一差别是 instant=true。
--     推断：失败是瞬间的（没有模块位了，立刻失败），成功是长按的。
	APPLYMODULE_FAIL = Action({ mount_valid=true, instant = true }),
--★ REMOVEMODULES：卸下模块。mount_valid。
    REMOVEMODULES = Action({ mount_valid=true }),
--★ REMOVEMODULES_FAIL：卸下失败。mount_valid + instant。
	REMOVEMODULES_FAIL = Action({ mount_valid=true, instant = true }),
--★ CHARGE_FROM：充电。distance=1.25 + mount_valid=false。
    CHARGE_FROM = Action({ distance=1.25, mount_valid=false }),
--★ 646 行空行。

--★ ROTATE_FENCE：旋转栅栏。rmb=true。
    ROTATE_FENCE = Action({ rmb=true }),
--★ 648 行空行。

--★ 649 行的 `-- MAXWELL` 标记。
	-- MAXWELL
--★ USEMAGICTOOL：使用魔杖。mount_valid + priority=1。
	USEMAGICTOOL = Action({ mount_valid = true, priority = 1 }),
--★ STOPUSINGMAGICTOOL：停止使用。mount_valid + priority=2 + distance=math.huge
--   + do_not_locomote。
--   ★ priority=2 高于 USEMAGICTOOL(1)，保证「停止」总能赢。
	STOPUSINGMAGICTOOL = Action({ mount_valid = true, priority = 2, distance = math.huge, do_not_locomote = true }),
--★ USESPELLBOOK：打开法术书。instant + mount_valid + priority=2。
--   ★★ priority=2（而非 1）—— 与 STOPUSINGMAGICTOOL 同档，
--     说明「打开界面」与「停止施法」需要互相压制。
	USESPELLBOOK = Action({ instant = true, mount_valid = true, priority = 2 }),
--★ CLOSESPELLBOOK：关闭法术书。instant + mount_valid + priority=2。
	CLOSESPELLBOOK = Action({ instant = true, mount_valid = true, priority = 2 }),
--★ CAST_SPELLBOOK：施放法术。mount_valid。
	CAST_SPELLBOOK = Action({ mount_valid = true }),
--★ 655 行空行。

--★ 656 行的 `-- WOODIE` 标记。
    -- WOODIE
--★ USE_WEREFORM_SKILL：使用狼形技能。rmb=true + distance=math.huge。
    USE_WEREFORM_SKILL = Action({ rmb=true, distance=math.huge }),
--★ 658 行空行。

--★ 659 行的 `-- WINONA` 标记。
    -- WINONA
--★ REMOTE_TELEPORT：远程传送。rmb=true + invalid_hold_action + mount_valid。
    REMOTE_TELEPORT = Action({ rmb = true, invalid_hold_action = true, mount_valid = true }),
--★ 661 行空行。

--★ 662 行的 `-- Rifts` 标记：第二波大型更新。
    -- Rifts
--★ SCYTHE：镰刀。rmb=true + distance=1.8 + rangecheckfn=DefaultRangeCheck
--   + invalid_hold_action。
--   ★★ 这是四工具动作之外的第五个，特点是**同时**有 rmb、rangecheckfn
--     与 invalid_hold_action。
    SCYTHE = Action({ rmb=true, distance=1.8, rangecheckfn=DefaultRangeCheck, invalid_hold_action=true }),
--★ SITON：坐下。invalid_hold_action=true。
--   ★★ fn（5990 行）是两阶段模式：检查 sg 处于 "start_sitting"。
--     与 JUMPIN/CLIMB 同族（见 431 行的说明）。
	SITON = Action({invalid_hold_action = true,}),
--★ 665 行空行 + 666 行 `-- Rifts / Meta QoL` 标记。

    -- Rifts / Meta QoL
--★ INCINERATE：焚烧。priority=1 + mount_valid。
    INCINERATE = Action({ priority=1, mount_valid=true }),
--★ 668 行空行。

--★ 669 行的 `-- Rifts 4` 标记。
	-- Rifts 4
--★ BOTTLE：装瓶。mount_valid。
	BOTTLE = Action({ mount_valid=true }),
--★ 671 行空行。

--★ 672 行的 `-- Hallowed Nights 2024` 标记 —— 按**年份**分组。
--   ★★ 这是全表唯一的按年份标注的段，与前面按角色分组的风格不同。
--     说明到 2024 年时团队的组织方式变了（按活动排期而非按角色）。
	-- Hallowed Nights 2024
--★ CARVEPUMPKIN：雕刻南瓜。distance=1.5。
	CARVEPUMPKIN = Action({ distance=1.5 }),
--★ 674 行空行。

--★ 675 行的 `-- Winter's Feast 2024` 标记。
	-- Winter's Feast 2024
--★ DECORATESNOWMAN：装饰雪人。distance=1.5 + encumbered_valid
--   + invalid_hold_action。
--   ★★★ 这是本文件里**最复杂的单个动作 fn**（6087-6166 行，80 行）：
--     它要处理「手上没东西 → 戴帽子 / 用物品装饰 / 叠雪球」三种模式，
--     每种模式还有 CanBegin/CanStack 前置检查与黑暗中静默失败。
--   ★ 而且 6117-6130 与 6146-6159 是**两段几乎相同的代码**
--     （叠小雪球 vs 叠大雪球），只有取装备的来源不同。
	DECORATESNOWMAN = Action({ distance=1.5, encumbered_valid=true, invalid_hold_action=true }),
--★ START_PUSHING：开始推。distance=1.5 + rmb=true + priority=1
--   + invalid_hold_action。
	START_PUSHING = Action({ distance=1.5, rmb=true, priority=1, invalid_hold_action=true }),
--★ 678 行空行。

--★ 679 行的 `-- Meta 5` 标记。
--   ★★ 「Meta」指元进度（Metabolic）。这些动作服务养成系统。
    -- Meta 5
--★ APPLYELIXIR：涂灵药。mount_valid。
    APPLYELIXIR = Action({mount_valid = true}),
--★ NABBAG：抓取（网袋）。rmb=true + distance=1.8 + rangecheckfn
--   + invalid_hold_action。
--   ★ 与 SCYTHE(663) 同型。两个都是「远程工具 + 精确距离」。
    NABBAG = Action({ rmb=true, distance=1.8, rangecheckfn=DefaultRangeCheck, invalid_hold_action=true }),
--★ GRAVEDIG：挖坟。rmb=true + invalid_hold_action + distance=1.8。
    GRAVEDIG = Action({ rmb=true, invalid_hold_action=true, distance = 1.8 }),
--★ MUTATE：变异。priority=2 + invalid_hold_action + mount_valid。
--   ★★ 与 WEBBER 段的 MUTATE_SPIDER(619 行 priority=2) 同名不同物。
--     ★ 这是命名冲突的隐患：搜 MUTATE 会同时命中两个玩法。
    MUTATE = Action({ priority=2, invalid_hold_action = true, mount_valid = true }),
--★★ WOBY_PICKUP：狗捡东西。**arrivedist = 2**（不是 distance）。
--   ★★ 与 STEER_BOAT(561) 并列使用 arrivedist 的两个动作。
--     语义：狗要站在 2 格外才能「够到」物品 —— 这是**宠物的拾取距离**，
--     而不是玩家的手能伸多远。
--   ★ fn（6245 行）用 components.container（狗的口袋）而非 inventory。
    WOBY_PICKUP = Action({ arrivedist = 2 }),
--★ WOBY_PICK：狗采摘。extra_arrive_dist=ExtraWobyForagingDist（§零 262 行，
--   大型生物 +1 格）。
--   ⚠ L10：6286 行的 validfn 语义存疑，详见 p8。
    WOBY_PICK = Action({ extra_arrive_dist=ExtraWobyForagingDist }),
--★★ CONTAINER_INSTALL_ITEM：把物品装进容器。priority=3 + rmb=true
--   + instant + mount_valid。
--   ★ priority=3 很高：这是「整理背包」的精细操作，
--     必须能压过普通的 GIVE(370 行) 与 STORE(404 行)。
--   ★ 有 pre_action_cb（6331 行）：装不下时播「否定音效」。
--     ★★ 这是本文件中 pre_action_cb 的**第三个用途**：立即负反馈。
--       与 LIFT_GYM 的敲铃同类。
	CONTAINER_INSTALL_ITEM = Action({ priority = 3, rmb = true, instant = true, mount_valid = true }),
--★ MODSLINGSHOT：改装弹弓。mount_valid。
	MODSLINGSHOT = Action({ mount_valid=true }),
--★ STOPMODSLINGSHOT：停止改装。instant + mount_valid。
	STOPMODSLINGSHOT = Action({ instant=true, mount_valid=true }),
--★ DASH：冲刺。distance=math.huge + mount_valid + invalid_hold_action。
	DASH = Action({ distance = math.huge, mount_valid = true, invalid_hold_action = true }),
--★★ DIRECTCOURIER_MAP：地图直递快递。HIGH + ArriveAnywhere + rmb +
--   instant + map_action + map_only + map_works_on_unexplored + closes_map。
--   ★★ 唯一同时设置了 map_only **和** map_works_on_unexplored 的动作。
--     原因是沃尔特的新技能要在**未探索**区域也能直接发快递。
--   ⚠ L1：3461 行 maponly_checkvalidpos_fn 有一处运算符优先级 bug，详见 p5。
    DIRECTCOURIER_MAP = Action({priority=HIGH_ACTION_PRIORITY, customarrivecheck=ArriveAnywhere, rmb=true, instant=true, map_action=true, map_only=true, map_works_on_unexplored=true, closes_map=true,}),
--★ WHISTLE：吹口哨召回狗。rmb=true + distance=math.huge +
--   invalid_hold_action。
	WHISTLE = Action({ rmb=true, distance=math.huge, invalid_hold_action=true }),
--★ ACTIVATE_CONTAINER：激活容器（点按钮）。priority=1 + mount_valid。
--   ★ fn（2108 行）走 `act.target.cookbuttonfn` ——
--     与 TRAVEL(3699) 的 travel_action_fn 同型：**实体自带回调**。
    ACTIVATE_CONTAINER = Action({ priority=1, mount_valid=true }),
--★ 693 行空行。

--★ 694 行的 `-- Deck O' Cards` 标记。
    -- Deck O' Cards
--★ DRAW_FROM_DECK：抽牌。priority=2 + distance=1.8 + mount_valid。
    DRAW_FROM_DECK = Action({priority=2, distance=1.8, mount_valid=true}),
--★ FLIP_DECK：翻牌堆。mount_valid。
    FLIP_DECK = Action({mount_valid=true}),
--★ ADD_CARD_TO_DECK：加牌进牌堆。mount_valid + canforce + DefaultRangeCheck。
--   ★★ 又一组 canforce + DefaultRangeCheck 组合（共 13 个，见 §五 清单）。
    ADD_CARD_TO_DECK = Action({ mount_valid=true, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ 698 行空行。

--★ 699 行的 `-- Rifts 5` 标记。
	-- Rifts 5
--★★ POUNCECAPTURE：扑抓。priority=3 + distance=5 + canforce
--   + rangecheckfn=MakeRangeCheckFn(7)。
--   ★★ 唯一在 ACTIONS 表里**直接调用 MakeRangeCheckFn** 的地方。
--     distance=5（要走到 5 格内）但允许 rangecheck 到 7 格 ——
--     ★★ 这就是「走到 5 格停下，但若在 5-7 格之间仍可执行」的组合。
--       即「允许的判定范围 ⊇ 允许的移动范围」，多出来的 2 格是余量，
--       避免玩家「明明看见扑到了却没反应」。
--   ★ 703 行 DIVEGRAB 用完全相同的参数组合 —— 成对设计。
	POUNCECAPTURE = Action({ priority = 3, distance = 5, canforce = true, rangecheckfn = MakeRangeCheckFn(7) }),
--★ 701 行空行。

--★ 702 行的 `-- rifts5.1` 标记 —— 小版本号。
    -- rifts5.1
--★★ DIVEGRAB：潜水抓取。声明与 700 行 POUNCECAPTURE **逐字相同**。
--   ★★ 两个不同玩法用了完全相同的动作规格 ——
--     因为它们的技术需求确实一样（远程扑击）。
--   ★ 这再次印证「Action 是数据」：玩法差异全在 fn 里。
    DIVEGRAB = Action({ priority = 3, distance = 5, canforce = true, rangecheckfn = MakeRangeCheckFn(7) }),
--★ STARTELECTRICLINK：开始电线连接。priority=2 + invalid_hold_action。
    STARTELECTRICLINK = Action({ priority = 2, invalid_hold_action = true  }),
--★ ENDELECTRICLINK：结束电线连接。priority=1 + invalid_hold_action。
--   ★★ priority 比 START 低一档（2 vs 1）。
--     推断：连接中时，结束应该比「开始新连接」更容易触发。
    ENDELECTRICLINK = Action({ priority = 1, invalid_hold_action = true }),
--★ REMOVELUNARBUILDUP：清除月雹堆积。priority=3 + invalid_hold_action。
    REMOVELUNARBUILDUP = Action({priority=3, invalid_hold_action=true}),
--★ 707 行空行。

--★ 708 行的 `-- Winter 2025` 标记。
	-- Winter 2025
--★ SOAKIN：泡澡。invalid_hold_action=true。
	SOAKIN = Action({ invalid_hold_action = true }),
--★ TRANSFER_CRITTER：转移宠物。invalid_hold_action=true。
    TRANSFER_CRITTER = Action({ invalid_hold_action = true }),
--★ 711 行空行。

--★ 712 行的 `-- Year of the Clockwork Knight` 标记。
    -- Year of the Clockwork Knight
--★★ JOUST：马上决斗。rmb=true + distance=math.huge + invalid_hold_action
--   + silent_generic_fail。
--   ★★ 唯一使用 silent_generic_fail 的动作（§一 323 行）。
--     决斗失败会频繁发生，每次都播完整提示太吵。
--   ★ fn（6663 行）最后 `return joustuser:CanJoust()` ——
--     ★★ 注意：这里返回的是「能不能」而不是「做了没有」。
--       是个语义上的小瑕疵：调用方无法从返回值知道是否真的开始了决斗。
    JOUST = Action({ rmb=true, distance=math.huge, invalid_hold_action = true, silent_generic_fail = true,}),
--★ 714 行空行。

--★ 715 行的 `-- Meta 6` 标记。
    -- Meta 6
--★ STARTREMOVINGMODULE：开始拆模块。mount_valid + invalid_hold_action。
    STARTREMOVINGMODULE = Action({ mount_valid = true, invalid_hold_action=true }),
--★★ REMOVEMODULE：拆模块。mount_valid + invalid_hold_action + **instant**。
--   ★★ 行尾注释是关键：「The action we use when we're already in the UI.」
--     ★★★ 「已经进入界面」时还需要一个动作？这是一个很反直觉的设计。
--     推断：拆模块流程是「按住 STARTREMOVINGMODULE → 进入界面 →
--       在界面里逐个点 REMOVEMODULE」。后者是 instant 的。
--     ★ 两个动作共用 upgrademoduleowner 组件的 StartInspecting/StopInspecting。
    REMOVEMODULE = Action({ mount_valid = true, invalid_hold_action=true, instant = true }), -- The action we use when we're already in the UI.
--★ STOPREMOVINGMODULE：停止拆模块。mount_valid + invalid_hold_action。
    STOPREMOVINGMODULE = Action({ mount_valid = true, invalid_hold_action=true }),
--★ MAPSCOUT_MAP：地图侦察。instant + mount_valid + map_only
--   + map_works_on_unexplored + map_works_on_impassable。
	MAPSCOUT_MAP = Action({ instant = true, mount_valid = true, map_only = true, map_works_on_unexplored = true, map_works_on_impassable = true }),
--★ MAPSCOUT_MAP_TOOFAR：目标太远。instant + mount_valid + map_only
--   + map_works_on_unexplored + map_works_on_impassable。
--   ★★ 与 719 行声明**完全相同**，但 6820 行：
--     `ACTIONS.MAPSCOUT_MAP_TOOFAR.maponly_checkvalidpos_fn = ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn`
--     ★ 复用同一个校验函数，但 stroverridefn 与 pre_action_cb 完全不同 ——
--       太远时播「否定音效」（6826 行）而 fn 只 return true。
--   ★★★ 「失败」被建模成了一个动作，而不是让 fn 返回 false。
--     这是 T6 影子动作的第三种用途：**表达「够不着」这个状态**。
	MAPSCOUT_MAP_TOOFAR = Action({ instant = true, mount_valid = true, map_only = true, map_works_on_unexplored = true, map_works_on_impassable = true }),
--★ MAPSCOUTSELECT_MAP：选择侦察目标。instant + mount_valid + rmb=true
--   + map_only + map_works_on_unexplored + map_works_on_impassable。
	MAPSCOUTSELECT_MAP = Action({ instant = true, mount_valid = true, rmb = true, map_only = true, map_works_on_unexplored = true, map_works_on_impassable = true }),
--★ STARTMAPDELIVER：开始地图投递。rmb=true。
	STARTMAPDELIVER = Action({ rmb = true }),
--★ MAPDELIVER_MAP：地图投递。map_only + closes_map。
--   ★★ 全表唯一不带 mount_valid 的 map_only 动作。
	MAPDELIVER_MAP = Action({ map_only=true, closes_map=true, }),
--★ SWAPBODIES_MAP：地图换身。ArriveAnywhere + rmb=true + map_only
--   + map_works_on_unexplored + closes_map。
    SWAPBODIES_MAP = Action({ customarrivecheck=ArriveAnywhere, rmb=true, map_only=true, map_works_on_unexplored=true, closes_map=true,}),
--★ TOGGLEWXSCREECH：切换尖啸。priority=1 + invalid_hold_action。
    TOGGLEWXSCREECH = Action({ priority = 1, invalid_hold_action=true }),
--★ TOGGLEWXSHIELDING：切换护盾。priority=0 + invalid_hold_action。
--   ★★ priority 不对称（1 vs 0）。SCREECH 是「主动释放」，
--     SHIELDING 是「被动开关」。
    TOGGLEWXSHIELDING = Action({ priority = 0, invalid_hold_action=true, }),
--★ 727 行空行 + 728 行注释解释 EQUIPONBODY 的存在理由。

--★★ 728 行保留的英文注释说明了 EQUIPONBODY 的存在理由：
--   「一个给**附身的身体**装备物品的专属动作，但仍能往它的背包里放东西。」
--   ★★ 这解释了它与 GIVEALLTOPLAYER(372) 的分工：
--     GIVE 系列给**活着的玩家**（inventory 已打开），
--     EQUIPONBODY 给**被附身的身体**（可直接操作其 inventory）。
--   ★★ 换句话说：GIVE 的检查 `IsOpenedBy(act.target) or HasTag("playerghost")`
--     （2348 行）在附身场景下不成立，于是需要一个新动作。
    -- A unique action to equip things on the possessed bodies, but can still give stuff to their inventory
--★★ EQUIPONBODY：给被附身的身体装备。priority=3 + canforce
--   + rangecheckfn=DefaultRangeCheck。
--   ★ priority=3（与 GIVE 同级）：两者都是「给别人东西」，不该互相压制。
    EQUIPONBODY = Action({ priority=3, canforce=true, rangecheckfn=DefaultRangeCheck }),
--★ 730 行空行。

--★ 731 行的 `-- Rifts 7` 标记。
    -- Rifts 7
--★ CLIMB：攀爬。ghost_valid + encumbered_valid。
--   ★ 与 JUMPIN(431) 同族的两阶段模式（见 431 行说明）。
    CLIMB = Action({ ghost_valid=true, encumbered_valid=true }),
--★ STARTVAULTORBTELEPORT：开始金库球传送。rmb=true。
    STARTVAULTORBTELEPORT = Action({ rmb = true }),
--★ VAULTORBTELEPORT_MAP：金库球地图传送。ArriveAnywhere + rmb=true
--   + map_only + map_works_on_unexplored + closes_map。
	VAULTORBTELEPORT_MAP = Action({ customarrivecheck = ArriveAnywhere, rmb = true, map_only=true, map_works_on_unexplored = true, closes_map=true, }),
--★ 735 行空行。

--★ 736 行的 `-- Crow Carnival 2026` 标记 —— 最新内容。
--   ★★ 全表最后 4 个动作。可以看到新增动作的典型形状：
--     声明极简（1-3 个字段），逻辑全在 fn 里。
	-- Crow Carnival 2026
--★ GOLF_START_AIMING：高尔夫瞄准。rmb=true + invalid_hold_action。
	GOLF_START_AIMING = Action({ rmb = true, invalid_hold_action = true }),
--★ GOLF_STOP_AIMING：停止瞄准。instant=true。
	GOLF_STOP_AIMING = Action({ instant = true }),
--★ GOLF_START_CHARGING：高尔夫蓄力。distance=9999 + do_not_locomote
--   + invalid_hold_action。
--   ★ 第三个使用 (9999 + do_not_locomote) 组合的动作（562/596/739）。
	GOLF_START_CHARGING = Action({ distance = 9999, do_not_locomote = true, invalid_hold_action = true }),
--★★ TERRAFORM_REMOVE：移除地形（高尔夫）。CheckInsideGolfGame + rmb=true
--   + invalid_hold_action + **keepgroundactionhint=true**。
--   ★★ 全表唯一使用 keepgroundactionhint（350 行）的动作。
--     因为高尔夫的球位标记是**无名临时实体**，
--     若不留住地面动作提示，玩家松手后不知道还能点什么。
    TERRAFORM_REMOVE = Action({ customarrivecheck = CheckInsideGolfGame, rmb = true, invalid_hold_action = true, keepgroundactionhint = true, }),
--★ 741 行 ACTIONS 表结束。
--★★ 统计（可核对）：
--   · 动作原型总数 ≈ 240 条
--   · 带 priority 的 ≈ 130 条（其余用默认 0）
--   · 用 HIGH_ACTION_PRIORITY 的 = 10 条（见 353 行清单）
--   · 带 canforce 的 = 13 条：PICK(366) GIVE(370) GIVETOPLAYER(371)
--     GIVEALLTOPLAYER(372) FEEDPLAYER(373) NET(413) HAUNT(462)
--     SLAUGHTER(539) POUNCECAPTURE(700) DIVEGRAB(703) EQUIPONBODY(729)
--     ADD_CARD_TO_DECK(697)
--   · 有 customarrivecheck 的 = 10 条
--   · 有 stroverridefn 的 ≈ 45 条
--   · 有 pre_action_cb 的 = 10 条
--   · 有 actionmeter 的 = 1 条（REVIVE_CORPSE）
--   · distance = math.huge 的 = 6 条
--   · distance = 9999 的 = 3 条（562/596/739）
--   · _FAIL 影子动作 = 8 条
--★ 注意：ACTIONS 表里**只有声明**，一个 fn 都没有。
--   所有实现都在 743 行之后。这是刻意的分层。
}

--★★★【ACTIONS_BY_ACTION_CODE —— 字符串 id 到整数 code 的双向映射】
--
--★★ 为什么需要它？联机时不可能传字符串。
--   客户端点一下按钮 → SendRPCToServer(RPC.ActionButton, actioncode, ...)
--   （playercontroller.lua:2356）→ 服务端 ACTIONS_BY_ACTION_CODE[code] 还原。
--   ★ 这就是「协议里的一切枚举都用整数」的标准做法。
--
--★★★⚠⚠ 最重要的隐患：code 由**遍历顺序**决定，而遍历用的是
--   `orderedPairs`（745 行）—— 按字母序！
--   ★★ 后果：任何在 ACTIONS 表里**插入新动作**的改动，
--     都可能让后面所有动作的 code 全部偏移。
--   ★ 而 code 已经写进了玩家的存档之外的世界状态（正在进行的动作），
--     也被写进了某些模组的硬编码值。
--   ★★★ 因此：**动作 id 的字母序是这个协议的一部分**。
--     重命名一个动作等于破坏协议。
--   ★ 模组用独立的 MOD_ACTIONS_BY_ACTION_CODE（754 行）规避了这一点，
--     因为模组的 code 从 1 开始单独计数（modutil.lua:466）。
--   ★ 这是本文件最值得记住的隐式契约，代码里没有任何注释说明。
ACTIONS_BY_ACTION_CODE = {}

--★ orderedPairs 保证遍历顺序 = id 的字典序。
--   ★★ 这一点在 743 行的注释里**没有**被点明，是隐含契约。
--   ★ 参见 util.lua 的 orderedPairs 定义。
ACTION_IDS = {}
for k, v in orderedPairs(ACTIONS) do
--★★ v.str = STRINGS.ACTIONS[k] or "ACTION"
--   ★★ 兜底值 "ACTION"（而不是报错或空串）的理由：
--     新加的动作如果忘了在 STRINGS 里定义，UI 会显示英文 "ACTION"，
--     这比崩溃或显示 nil 更容易被语言包维护者发现。
--   ★★ 这是「把缺失暴露出来但不致命」的好设计。
    v.str = STRINGS.ACTIONS[k] or "ACTION"
--★ v.id = k —— 把字符串 id 回写到动作对象上。
--   ★★★ 这个回写极其重要，因为下游全部靠它：
--     · entityscript.lua:1799 CanDoAction 检查 `self:HasTag(action.id.."_tool")`
--     · componentactions.lua:3065 检查 `inst:HasTag(action.id.."_workable")`
--     · bufferedaction.lua:65 用 action.id 查 STRINGS
--   ★★★ 于是「加一个新动作」要让它可用，需要：
--     ① ACTIONS 表声明 ② STRINGS 定义 ③ 目标 prefab 加对应标签。
--     三处缺一不可。这是最容易漏的一处。
    v.id = k
    table.insert(ACTION_IDS, k)
--★ v.code = #ACTION_IDS —— 用当前长度当 code，即从 1 开始连续编号。
    v.code = #ACTION_IDS
--★ 反向表。注意它是 code → action 对象，**不是** id → action。
--   ★ 因为 id → action 直接用 ACTIONS[id] 就行，不需要额外表。
    ACTIONS_BY_ACTION_CODE[v.code] = v
end

--★ MOD_ACTIONS_BY_ACTION_CODE：模组动作的独立编号空间。
--   ★★ 结构是 [mod_name][code] → action，两层索引。
--   ★ 由 modutil.lua:468-470 在 AddAction 中填充。
MOD_ACTIONS_BY_ACTION_CODE = {}

--★ ACTION_MOD_IDS：模组的动作 id 列表，注释说明它在 modutil 中被填。
--   ★ 与 MOD_ACTIONS_BY_ACTION_CODE 不同：这里存 id（供遍历），
--     那里存 action 对象（供 O(1) 查找）。
ACTION_MOD_IDS = {} --This will be filled in when mods add actions via AddAction in modutil.lua

--★ IsItemInReadOnlyContainer —— 本文件里**唯一**的普通局部函数（用途辅助）。
--   ★★ 它定义在这里但全文没有调用点 —— 它是被其它文件 require 走的
--     （作为 actions.lua 的 upvalue 之一，通过 require("actions") 拿到）。
--   ★ 注意它被声明为 `local` —— 也就是说它**无法**被外部访问。
--   ⚠疑似缺陷 L13：定义了一个 local 函数却从不使用，且不可被外部访问。
--     最可能的解释是作者忘了删，或者原本打算 export。
local function IsItemInReadOnlyContainer(item)
    return item ~= nil and
        item.components.inventoryitem ~= nil and
        item.components.inventoryitem.owner ~= nil and
        item.components.inventoryitem.owner.components.container ~= nil and
        item.components.inventoryitem.owner.components.container.readonlycontainer
--★ 764 行是 IsItemInReadOnlyContainer 的结束（763 行 return）。
--★ 到此「动作声明与编号」部分结束（743-765 行）。
--  从 766 行开始是 6300 行的动作实现。
end

--★★ 保留的英文注释 `----set up the action functions!` 是本部分的标题。
--★★ 从 768 到 7092 共 6325 行，全部是「给 ACTIONS 里的原型挂实现」。
--   ★★ 挂载方式全是直接赋值：ACTIONS.X.fn = function(act) ... end
--     没有 SetActionFn 这类封装，原因是这个文件不需要抽象：
--     它是**唯一**的动作注册处。
--   ★★ 挂载顺序**完全没有组织** —— 从 APPRAISE 到 TERRAFORM_REMOVE，
--     按字母序（大约）而非按主题。查找某动作要靠全文搜索。
--   ★ 这与 357-741 行的声明段（按主题分组）风格相反。
----set up the action functions!

--★ APPRAISE.fn —— 本文件第一个 fn，也是 T1 模板的规范样本：
--   「问组件的 Can*，成功就调用对应方法」。
--   ★★ 注意 776-778 行的三分支返回：
--     · CanAppraise 为真 → Appraise + return true
--     · reason == "NOTNOW" → return false, "NOTNOW"（保留原因）
--     · 其他 reason   → **什么都不返回**（nil）
--   ★★ 第三种情况是「静默失败」：不提示玩家任何东西。
--     ★ 推断：appraisable 组件会在自己失败时已经说过了话，
--       再播一遍通用失败会很吵。
--   ★★★ 这是全文件里 return 形态最标准的一段，建议作为对照基准。
ACTIONS.APPRAISE.fn = function(act)
    local obj = act.invobject

    local target = act.target
    local canappraise, reason = obj.components.appraisable:CanAppraise(target)
    if canappraise then
        obj.components.appraisable:Appraise(target)
        return true
    elseif reason == "NOTNOW" then
        return false, "NOTNOW"
    end
--★ 隐式 return nil（走到函数末尾）。见上行的说明。
end

--★ EAT.strfn —— strfn 的第一个实例。
--   ★★ strfn 的返回值是「修饰词」而非完整字符串。
--     bufferedaction.lua:65 会做 GetActionString(action.id, modifier)，
--     由 stringutil.lua:331 把它拼成 "PROCESS EAT" 之类。
--   ★★ 785-787 行的 or 链一次返回三个可能值：
--     "PROCESS"（腐烂处理者）、"DRINK"（fooddrink 标签）、nil（普通进食）
--   ★ 三元结构靠 Lua 的 and/or 惯用法实现（784-786 行），无括号。
ACTIONS.EAT.strfn = function(act)
    if act.invobject ~= nil then
--★ 三个 and 的括号是必需的，因为 `and` 优先级高于 `or`。
--   ★★ 括号分组：(A and B) or (C and D) or nil
--     其中 A = invobject~=nil，B = doer:HasTag(...) and invobject:HasTag(...)
--   ★ 若去掉括号会得到完全不同的语义 —— 这是全文件少见的「括号必需」处。
        return (act.doer ~= nil and
                (act.doer:HasTag("spoiledprocessor") and act.invobject:HasTag("spoiledfood"))
                or (act.doer:HasTag("allspoiledprocessor") and act.invobject:HasTag("spoiled"))) and "PROCESS"
--★ 注意此处用的是 `invobject:HasTag("fooddrink")` 而非 `foodtype == DRINK`。
--   ★★ 标签优先于枚举：加新食物时只要打标签，不必改 Lua。
            or act.invobject:HasTag("fooddrink") and "DRINK"
            or nil
    end

    return nil
end

--★★ EAT.fn —— 「一个动作三种能力」的完整演示（§二 365 行已预告）。
--   ★★ 第 794 行 `local obj = act.target or act.invobject` 是 T7 模板的源头。
--     EAT 的对象可以是：地上的浆果（target）或者手里的浆果（invobject）。
--     ★ 为什么两者都要？因为玩家既能「右键地上的」也能「左手拿着吃」。
--   ★★★ 三个分支的顺序即优先级：edible > soul > oceanfishable。
--     若一个物品同时有 edible 与 soul 组件，先走 edible。
--   ★★ 每个分支都检查**双方**的组件：
--     `obj.components.edible ~= nil and act.doer.components.eater ~= nil`
--     缺一不可 —— 物品能吃但角色没有 eater（NPC）就吃不了。
--   ★★ 798-799 行 souleater:EatSoul 只有一个参数（没有 doer），
--     因为韦伯吃灵魂不需要「谁来喂」的信息。
ACTIONS.EAT.fn = function(act)
    local obj = act.target or act.invobject
    if obj ~= nil then
        if obj.components.edible ~= nil and act.doer.components.eater ~= nil then
            return act.doer.components.eater:Eat(obj, act.doer)
        elseif obj.components.soul ~= nil and act.doer.components.souleater ~= nil then
            return act.doer.components.souleater:EatSoul(obj)
        elseif act.doer.components.oceanfishable ~= nil and obj.components.oceanfishable ~= nil then
            return act.doer.components.oceanfishable:SetRod(obj.components.oceanfishable:GetRod())
        end
    end
end

--★★ STEAL.fn —— 距离魔数 16 的现场（§二 446 行已预告）。
--   ★★ 807-808 两行的连写值得逐字读：
--     owner  = target 有 inventory ? target : (target 有 inventoryitem
--                                                ? target.inventoryitem.owner : nil)
--     target = target 没有 inventory ? target : nil
--   ★★ 语义：偷「箱子里的东西」时 target 被清空（因为真正要偷的是箱子里的物），
--     「偷「地上的东西」时 target 保留。
--   ★ 也就是说 target 在这个动作里有**两种含义**，由目标有无 inventory 决定。
--   ★★ 这种「一个变量两种含义」的写法让下游代码（811 行的 inrange 检查、
--     818 行的 thief:StealItem）都变得含糊。建议读到这里时记住这条规则。
ACTIONS.STEAL.fn = function(act)
    local owner = act.target.components.inventory ~= nil and act.target or act.target.components.inventoryitem ~= nil and act.target.components.inventoryitem.owner or nil
    local target = act.target.components.inventory == nil and act.target or nil

    -- NOTES(JBK): Recheck the range in here because buffered actions will go through a stategraph and the target may have moved out of range before we get here from actions.
--★★⚠ 保留的英文注释是理解本行存在理由的唯一线索：
--   「NOTES(JBK): 在这里重新检查范围，因为缓冲动作会经过状态图，
--     等我们从 actions 执行到这里时，目标可能已经走出范围了。」
--   ★★★ 这是一条**关于架构的注释**：
--     动作从按键到执行之间要经过 locomotor（走过去）+ stategraph（播动画），
--     这个过程可能有数百毫秒。目标在这段时间里完全可以跑掉。
--     ★ 所以 fn 里必须自己再校验一次。这与 bufferedaction.lua:39 的 IsValid()
--       是**两个不同层次**的校验（见 p11）：
--         IsValid()  → 目标还在不在、owner 变没变（结构性）
--         这一行       → 距离还在不在（空间性）
--   ★★ 结构性失效 IsValid 会拦下，空间性失效必须由每个动作自己拦。
--     ★ 这就是为什么只有 3 个动作（STEAL/SLAUGHTER/COOK）手写了距离检查 ——
--       因为只有它们的距离**特别重要**（偷窃/屠宰/烹饪需要精确贴身）。
--   ★ `< 16` 是距离平方，注释也写了「4*4 is default range above」
--     —— 它明确承认这是抄 DefaultRangeCheck 的值，两处无代码关联。
    local inrange = act.doer and act.target and (act.doer:GetDistanceSqToInst(act.target) < 16) -- 4*4 is default range above.
    if not inrange then
        return nil
    end

    if owner ~= nil then
        if act.doer.components.thief ~= nil then
--★ act.attack == true —— 从 BufferedAction 读的额外标记。
--   ★ 这个字段不是 BufferedAction 构造函数的参数（bufferedaction.lua:2），
--     而是后续被别处赋值的。用于「攻击式偷窃」（韦伯技能）。
--   ★ 属于「靠 duck typing 扩展字段」的写法，不是显式契约。
            return act.doer.components.thief:StealItem(owner, target, act.attack == true)
        end
--★ elseif 分支：目标是 dryer（晾晒架）时直接取下正在晾的东西。
--   ★★★ 这是「偷窃动作」的第二种完全不同的语义 ——
--     「从晾晒架上抢走正在风干的东西」。
--   ★ 与 thief 组件无关，所以放在 elseif 而非 owner 分支里。
    elseif act.target.components.dryer ~= nil then
        return act.target.components.dryer:DropItem()
    end
end

--★ MAKEBALLOON.fn —— 韦伯专属能力。四个与/and 的守卫之后进入正题。
ACTIONS.MAKEBALLOON.fn = function(act)
    if act.doer ~= nil and
            act.invobject ~= nil and
            act.invobject.components.balloonmaker ~= nil and
            act.doer:HasTag("balloonomancer") then

--★★ 831-836 行：「先扣理智，再做」。这是一个**先付代价**的设计。
--   ★ 为什么先扣？保证即使后面的 MakeBalloon 失败，代价也已经付了。
--     ★★ 反过来说：如果先做后扣，玩家在 SANITY_TINY 边界上可能
--       「做出气球但没扣理智」，反复刷气球。
--   ★ 832 行的判断是 `< TUNING.SANITY_TINY`（低于阈值就不行）。
        if act.doer.components.sanity ~= nil then
            if act.doer.components.sanity.current < TUNING.SANITY_TINY then
                return false
            end
            act.doer.components.sanity:DoDelta(-TUNING.SANITY_TINY)
        end
        --Spawn it to either side of doer's current facing with some variance
--★★ 生成位置的计算：朝角色朝向的左右两侧 ±65~75 度丢气球。
--   ★ 840-842 行：
--     angle_offset = RandomMinMax(-10, 10) + (正数 ? +65 : -65)
--     ⇒ 落在 [55, 75] 或 [-75, -55] 度
--   ★★★ 为什么偏向两侧而不是正前方？
--     因为正前方是玩家的视线焦点，气球挡住视野会很烦。
--     这个 ±10 度的抖动是为了避免多个气球完全重叠。
--   ★★ 但注意 843-846 行 MakeBalloon 的第三个参数写死了 0（高度），
--     所以 y 轴不会跟着角色在坡地上的高度 —— 气球总是落在海平面高度。
--     ★ 这在有洞穴层的地方可能造成视觉穿模。属于小瑕疵。
        local x, y, z = act.doer.Transform:GetWorldPosition()
        local angle = act.doer.Transform:GetRotation()
        local angle_offset = GetRandomMinMax(-10, 10)
        angle_offset = angle_offset + (angle_offset < 0 and -65 or 65)
        angle = (angle + angle_offset) * DEGREES
        act.invobject.components.balloonmaker:MakeBalloon(
            x + .5 * math.cos(angle),
            0,
            z - .5 * math.sin(angle)
        )
        return true
    end
end

--★ EQUIP.fn —— 三行转发，T1 模板的最简形态。
--   ★★ 与 867 行 UNEQUIP.fn 对比：EQUIP 只有一个组件检查，
--     而 UNEQUIP 需要判断「能不能卸」（有锁？）与「卸下来放哪」（背包 or 地上）。
--   ★ 「装备」永远是安全的，「卸装备」可能有后果 —— 判定量差异由此解释。
ACTIONS.EQUIP.fn = function(act)
    if act.doer.components.inventory ~= nil then
        return act.doer.components.inventory:Equip(act.invobject)
    end
end

--★ UNEQUIP.strfn —— 「HEAVY」变体。
--   ★★★ 三个条件用 or 连，判断的是「这算不算卸下重物」：
--     · 物品有 heavy 标签
--     · 游戏模式属性 non_item_equips
--     · 玩家的背包格数为 0（`GetNumSlots() <= 0`）
--   ★★ 第三个条件最有意思：**没有背包格子可用**时也显示 HEAVY。
--     因为这种情况下卸下来的东西只能丢在地上（fn 的 875 行 DropItem 分支）。
--     ★ 即 strfn 在预测 UI 上告知玩家「这个操作会把东西扔地上」。
ACTIONS.UNEQUIP.strfn = function(act)
    return (act.invobject ~= nil and
            act.invobject:HasTag("heavy") or
            GetGameModeProperty("non_item_equips") or
            act.doer.replica.inventory:GetNumSlots() <= 0)
        and "HEAVY"
        or nil
end

--★★ UNEQUIP.fn —— 「卸下」的两步判定：能不能卸 + 卸哪去。
--   ★ 869-871 行：equippable:ShouldPreventUnequipping() 为真则静默失败。
--     ★ 这类组件（e.g. 被蜡封住的装备、骑乘中的缰绳）会自己处理提示。
--   ★★ 872-876 行的分岔逻辑：
--     can go in container 且非 non_item_equips 模式 → GiveItem（回背包）
--     否则                                  → DropItem（扔地上）
--     ★★ 第三个参数 `(droprandomdir)` —— 扔出去时给点随机方向，
--       否则重物会精确落在脚点被立刻捡回。
ACTIONS.UNEQUIP.fn = function(act)
    if act.invobject ~= nil and act.doer.components.inventory ~= nil then
        if act.invobject.components.equippable ~= nil and act.invobject.components.equippable:ShouldPreventUnequipping() then
            return nil
        end
        if act.invobject.components.inventoryitem.cangoincontainer and not GetGameModeProperty("non_item_equips") then
            act.doer.components.inventory:GiveItem(act.invobject)
        else
            act.doer.components.inventory:DropItem(act.invobject, true, true)
        end
        return true
    end
end

--★ PICKUP.strfn —— 判断「这是重物吗」。
--   ★★★ 只看目标有没有 heavy 标签，不看玩家能不能搬。
--     而 fn（910 行）里有 `doer.components.inventory.noheavylifting` 判断。
--     ★★ 于是「UI 显示 HEAVY」与「能不能捡」是两个独立判断。
--       差异场景：韦伯的狗捡东西时（noheavylifting）
--       UI 仍显示 HEAVY，但实际能捡。属于「提示过于保守」的无害偏差。
ACTIONS.PICKUP.strfn = function(act)
    return act.target ~= nil
        and act.target:HasTag("heavy")
        and "HEAVY"
        or nil
end

--★★★ PICKUP.fn —— 本文件最值得逐行读的动作之一（70 行），
--   因为它是「捡东西」这条最常用的路径，包含了大量边界处理。
--   ★★ 结构分四层：
--     ① 889-899  大条件：能不能捡这个实体（8 个条件）
--     ② 901-922  拒绝清单：4 类「不能捡」并各带失败原因
--     ③ 924-926  副作用：目标自带背包的直接转移
--     ④ 928-956  主流程：事件 + 装备槽处理 + 最终 GiveItem
ACTIONS.PICKUP.fn = function(act)
    if act.doer.components.inventory ~= nil and
        act.target ~= nil and
        act.target.components.inventoryitem ~= nil and
--★★ 三个 canbepick 类条件用括号分组，等价于：
--   canbepickedup
--   或 (canbepickedupalive 且 doer 不是 player)
--   或 (grabbableoverridetag 存在 且 doer 有该标签)
--   ★★ 第二个条件「能捡活的」是韦伯机制：对人类玩家禁用（不能徒手抓人），
--     对生物/幽灵开放。
--   ★ 第三个条件是「标签覆盖」：某些东西只允许特定角色捡。
        (
            act.target.components.inventoryitem.canbepickedup or
            (act.target.components.inventoryitem.canbepickedupalive and not act.doer:HasTag("player")) or
            act.target.components.inventoryitem.grabbableoverridetag ~= nil and act.doer:HasTag(act.target.components.inventoryitem.grabbableoverridetag)
        ) and
--★★【三个「捡不了」的黑名单】
--   ① IsInLimbo()        —— 在「虚空缓冲区」里的实体（正在被删除）
--   ② 正在燃烧且没有 lighter 组件 —— 徒手不能捡起火的东西
--   ③ 投掷物正在飞行中（projectile:IsThrown()）
--   ★★ 三者都是「**状态性**」的拒绝，与「配置性」的 canbepickedup 不同。
--     ★ 897 行的括号闭合在 899 行，注意这个 not 覆盖了三项。
--   ★ 第二个条件 `burnable ~= nil and IsBurning() and lighter == nil`：
--     ★★★ 带 lighter 组件的火源（篝火）可以捡（= 捡起篝火），
--       没有的（正在烧的木头）不能捡。这就是「拿着火把走」的规则。
        not (act.target:IsInLimbo() or
			(act.target.components.burnable ~= nil and act.target.components.burnable:IsBurning() and act.target.components.lighter == nil) or
            (act.target.components.projectile ~= nil and act.target.components.projectile:IsThrown())) then

--★ 四条拒绝按顺序检查，返回四组不同的失败原因。
--   ★★ 注意它们的优先级顺序 = 「玩家最需要知道的原因」排序：
--     restriction（职业限制）→ INUSE（别人在用）→ NOTMINE_YOTC（赛事物品）
--     → NO_HEAVY_LIFTING（超重）
        if act.doer.components.itemtyperestrictions ~= nil and not act.doer.components.itemtyperestrictions:IsAllowed(act.target) then
            return false, "restriction"
        elseif act.target.components.container ~= nil and act.target.components.container:IsOpenedByOthers(act.doer) then
            return false, "INUSE"
        elseif (act.target.components.yotc_racecompetitor ~= nil and act.target.components.entitytracker ~= nil) then
            local trainer = act.target.components.entitytracker:GetEntity("yotc_trainer")
            if trainer ~= nil and trainer ~= act.doer then
                return false, "NOTMINE_YOTC"
            end
--★ noheavylifting —— 韦伯/狗形态不能搬重物。
--   ★ 与 910 行的 tab 缩进不同（用 tab 而非空格），属风格不一致。
		elseif act.doer.components.inventory.noheavylifting and act.target:HasTag("heavy") then
			return false, "NO_HEAVY_LIFTING"
        end

--★★ 蜘蛛特殊分支：韦伯可以「回收自己的蜘蛛」，别人的不行。
--   ★★★ 915 行 `act.target.components.follower:GetLeader()` 没有 nil 保护 ——
--     ★ 若目标同时有 "spider" 标签与 spiderwhisperer doer 但**没有 follower 组件**，
--       就会崩。
--     ★ 实践中所有 spider prefab 都有 follower，所以不会触发。
--       记为潜在隐患（见 p10 的同类清单）。
--   ★ 这个分支的缩进也比周围多一级，暗示它可能是后加的补丁。
        if act.target:HasTag("spider") and act.doer:HasTag("spiderwhisperer") then
            local leader = act.target.components.follower:GetLeader()
            if leader ~= nil and leader ~= act.doer then
                return false, "NOTMINE_SPIDER"
            end
        end
--★ curseditem —— 诅咒物品（韦伯）。背包没空间时不能捡。
--   ★ 921 行的失败原因 "FULL_OF_CURSES" 会被翻译成对应提示。
        if act.target.components.curseditem and not act.target.components.curseditem:checkplayersinventoryforspace(act.doer) then
            return false, "FULL_OF_CURSES"
        end

--★ drop_inventory_onpickup 标签：捡起的东西会连带倒出它的背包。
--   ★★ 典型：捡起一个背包时，里面的东西会直接进你的背包。
--     TransferInventory 的存在让这个特性只需一个标签。
        if act.target.components.inventory ~= nil and act.target:HasTag("drop_inventory_onpickup") then
            act.target.components.inventory:TransferInventory(act.doer)
        end

--★★ onpickupitem 事件 —— 在**实际给物品之前**推。
--   ★★ 顺序很重要：监听这个事件的组件（如成就、任务）可以在
--     「物品即将易主」的时刻响应，而 954 行之后才是真正的 GiveItem。
--   ★ 与 3169 行 MURDER 里「先推事件再掉战利品」是同一种谨慎。
        act.doer:PushEvent("onpickupitem", { item = act.target })

--★★★ 装备槽优先处理 —— 本 fn 最微妙的一段（930-952 行）。
--   ★★ 场景：手里拿着斧头（已装备），地上有一件可以装备的背心。
--     玩家点它，是应该「捡进背包」还是「直接换上」？
--   ★★★ 答案分三层，且每层都可能 return true 提前结束：
--     第一层（932-941）：要装备的东西**不能进背包**（如第二个背包）
--       → 必须卸下当前的，进背包，换上新装备。★ 唯一会同时动两件物品的分支。
--     第二层（942-945）：玩家 + 当前槽为空 或 没有背包格
--       → 直接装备（跳过背包）。
--     第三层（946-950）：non_item_equips 模式下 → 扔掉旧的，直接换。
--   ★★ 三层都不满足时，落到 954 行走普通 GiveItem。
--   ★★★ 这段代码的正确理解方式是：**「装备」优先于「拾取」**，
--     但只有当条件明确时才自动装备。含糊时退回普通拾取。
        if act.target.components.equippable ~= nil and not act.target.components.equippable:IsRestricted(act.doer) then
            local equip = act.doer.components.inventory:GetEquippedItem(act.target.components.equippable.equipslot)
--★ 933 行的英文注释解释了特殊分支：
--   「special case for trying to carry two backpacks」（尝试带两个背包）。
--   ★★ 背包装备的槽位是唯一的，玩家「捡第二个背包」时必须先卸第一个。
--   ★ 935 行被注释掉的 SelectActiveItemFromEquipSlot 是更早期的实现，
--     被 936 行的 Unequip + GiveItem 组合取代。
            if equip ~= nil and not act.target.components.inventoryitem.cangoincontainer then
                --special case for trying to carry two backpacks
--★ 934-937 行的三层判断：
--   ① 旧装备能进背包 → Unequip 后 GiveItem（进背包）
--   ② 否则 → DropItem（扔地上）
--   ③ 然后 Equip 新物品
--   ★★ 「旧装备没有 inventoryitem 组件」时 935 行的 select 路径，
--     这里用 DropItem 兜底。
                if equip.components.inventoryitem ~= nil and equip.components.inventoryitem.cangoincontainer then
                    --act.doer.components.inventory:SelectActiveItemFromEquipSlot(act.target.components.equippable.equipslot)
                    act.doer.components.inventory:GiveItem(act.doer.components.inventory:Unequip(act.target.components.equippable.equipslot))
                else
                    act.doer.components.inventory:DropItem(equip)
                end
                act.doer.components.inventory:Equip(act.target)
                return true
            elseif act.doer:HasTag("player") then
--★ `GetNumSlots() <= 0` —— 没有背包格子时也直接装备。
--   ★★ 与 859 行 strfn 的第三个条件呼应：「没有背包格 ⇒ 显示 HEAVY」。
--     两处条件相同，说明「没有背包格」是一种明确的已知状态。
                if equip == nil or act.doer.components.inventory:GetNumSlots() <= 0 then
                    act.doer.components.inventory:Equip(act.target)
                    return true
--★ GetGameModeProperty("non_item_equips") —— 特殊模式（如韦伯变体）。
--   ★★ 这个属性出现 3 次：859（strfn）、872（UNEQUIP.fn）、946（这里）。
--     三处都在处理「装备不占用背包格」的规则变化。
                elseif GetGameModeProperty("non_item_equips") then
                    act.doer.components.inventory:DropItem(equip)
                    act.doer.components.inventory:Equip(act.target)
                    return true
                end
            end
        end

--★★ 最终的 GiveItem —— 第三个参数是「物品当前的世界坐标」。
--   ★★ 这个参数的作用：物品在飞向背包的动画中先从**世界上的位置**出发，
--     而不是从玩家身上凭空出现。视觉正确性的关键。
--   ★ 对比 3281 行的 DropItem 也传了 act:GetActionPoint()，
--     两者是同一套「起点坐标」约定。
        act.doer.components.inventory:GiveItem(act.target, nil, act.target:GetPosition())
        return true
    end
end

--★★ EMPTY_CONTAINER.fn —— 一个「什么都不做但报告成功」的动作。
--   ★★ 960-963 行：只调 `workable.onwork` 回调（通常是个动画/音效），
--     然后 return true。
--   ★★ 964 行被注释掉的 DropEverything() 说明：
--     「清空容器」这个动作**曾经**是真的清空，现在只触发回调。
--     ★ 保留注释的价值：读者能看出这个动作被简化过，
--       以及为什么现在不真的清空（可能是不想白拿物品）。
--   ★★ 副作用：调用方无法通过返回值知道是否真的清了东西。
ACTIONS.EMPTY_CONTAINER.fn = function(act)
    if act.target.components.container ~= nil and act.target.components.workable ~= nil then
            if act.target.components.workable.onwork then
                act.target.components.workable.onwork(act.target, act.doer)
            end
        --act.target.components.container:DropEverything()
        return true
    end
end

--★ REPAIR.strfn —— 「SOCKET」与「REFRESH」两个变体。
--   ★★ 月亮神像（repairable_moon_altar）用 SOCKET 词（供能而非修理），
--     韦伯的生命维持（repairable_vitae）用 REFRESH（刷新而非修理）。
--   ★ 这是「同一个组件在不同 prefab 上语义不同」的例子。
ACTIONS.REPAIR.strfn = function(act)
	return act.target ~= nil
			and ( 
                     (act.target:HasTag("repairable_moon_altar") and "SOCKET")
                  or (act.target:HasTag("repairable_vitae") and "REFRESH")
                  )
			or nil
end

--★★ REPAIR.fn —— 「修理材料从哪来」的两条路径。
--   ★★ 981-990 行的判断链：
--     玩家在搬运重物（IsHeavyLifting）且没有骑乘 → 用 BODY 槽的装备当材料
--     否则 → 用 invobject（手上的东西）
--   ★★★ 这个分支很务实：搬运时手上没空，需要自动取背上的装备。
--     ★ 986 行特意排除了「骑乘中」—— 骑着牛时 BODY 槽装备的是鞍，
--       不能拿来修。
--   ★★ forgerepairable 分支（994-999 行）只接受 invobject，没有搬运特例。
--     不对称的原因推测：熔炉修理不需要那么高的自动化程度。
ACTIONS.REPAIR.fn = function(act)
	if act.target ~= nil then
		if act.target.components.repairable ~= nil then
			local material
			if act.doer ~= nil and
				act.doer.components.inventory ~= nil and
				act.doer.components.inventory:IsHeavyLifting() and
				not (act.doer.components.rider ~= nil and
				act.doer.components.rider:IsRiding()) then
				material = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
			else
				material = act.invobject
			end
--★ material 必须有 repairer 组件才继续 —— 防止「拿石头修」。
			if material ~= nil and material.components.repairer ~= nil then
				return act.target.components.repairable:Repair(act.doer, material)
			end
		elseif act.target.components.forgerepairable ~= nil then
			local material = act.invobject
			if material ~= nil and material.components.forgerepair ~= nil then
				return act.target.components.forgerepairable:Repair(act.doer, material)
			end
		end
    end
end

--★ SEW.strfn —— "PATCH" 变体（用胶带 = 补，用线 = 缝）。
--   ★ 同理 995 行的 forgerepairable 也有类似的双路径。
ACTIONS.SEW.strfn = function(act)
    return act.invobject ~= nil
        and (act.invobject:HasTag("tape") and "PATCH")
        or nil
end

--★ SEW.fn —— 四条件：目标有 fueled（要缝的是火器）、材料有 sewing。
--   ★★ fueled 组件意味着「缝的东西最终能点着」。所以针线活只对火器有效。
ACTIONS.SEW.fn = function(act)
    if act.target ~= nil and
        act.invobject ~= nil and
        act.target.components.fueled ~= nil and
        act.invobject.components.sewing ~= nil then
        return act.invobject.components.sewing:DoSewing(act.target, act.doer)
    end
end

--★★★【CanOpenCharacterSpecificContainer —— 「谁才能开这个箱子」的知识库】
--   ★★ 它是一个**纯条件**函数（返回 (bool, reason)），不执行任何开箱动作。
--     ★★ 它被两处调用：1091（RUMMAGE 翻找）与 2502（STORE 放东西）。
--       两个动作都要经过同一份「角色专属」判断 —— 这是正确的去重。
--   ★★ 四条规则（每个都是「特定角色才能开特定容器」）：
--     ① mastercookware  → 需要 masterchef 标签（大厨）
--     ② mermonly       → 需要 merm 标签（美人鱼）
--     ③ souljar        → 需要 wortox_souljar_1 技能激活（韦伯）
--     ④ wx78_backupbody→ 需要 WX-78 身份 + 是自己的备用身体 + 不超上限
local function CanOpenCharacterSpecificContainer(doer, target)
--★ 大厨专属厨具。失败原因 "NOTMASTERCHEF"。
    if target:HasTag("mastercookware") and not doer:HasTag("masterchef") then
        return false, "NOTMASTERCHEF"
    end
--★ 美人鱼专属。失败原因 "NOTAMERM"。
--   ★ 与 1019 行结构完全一致 —— 两行代码的模板复用。
    if target:HasTag("mermonly") and not doer:HasTag("merm") then
        return false, "NOTAMERM"
    end
--★★ 韦伯灵魂罐：判据是 **技能树激活**而非标签。
--   ★★★ `doer.components.skilltreeupdater == nil or not IsActivated(...)`
--     ★ 双层保护：没有 skilltreeupdater 组件（旧存档/非韦伯）也判为不可用。
--     ★ 与 3461 行的写法对比，那里**缺少**这层保护，见 L1。
--   ★ 这是本文件里「技能树作为权限判据」的三处用法之一。
    if target:HasTag("souljar") and (doer.components.skilltreeupdater == nil or not doer.components.skilltreeupdater:IsActivated("wortox_souljar_1")) then
        return false, "NOTSOULJARHANDLER"
    end
--★★ WX-78 备用身体 —— 全函数最复杂的一条（20 行），四个子判断：
--   ① follower 的 leader 是这个身体 → 无人机特例，放行（1029-1031 行）
--   ② 必须是 WX-78 身份                     → NOTAROBOT
--   ③ 必须 linked 到自己的备用身体        → NOTMYBACKUP
--   ④ 没设过归属时尝试认领，超上限则拒绝  → TOOMANYBACKUPBODIES
--   ★★ 1030 行注释「Drone bypass.」揭示了一个重要的联机设计：
--     无人机跟随主人时，主人能直接开自己身体上的箱。
--     否则无人机每开一次都要 RPC，交互会很别扭。
    if target:HasTag("wx78_backupbody") then
        if doer.components.follower and doer.components.follower:GetLeader() == target then -- Drone bypass.
            return true
        end

        if not doer.wx78_classified then
            return false, "NOTAROBOT"
        end
        local linkeditem = target.components.linkeditem
        if not linkeditem then
            return false, "NOTMYBACKUP"
        end
        local owneruserid = linkeditem:GetOwnerUserID()
        if owneruserid and owneruserid ~= doer.userid then
            return false, "NOTMYBACKUP"
        end
--★ TryToAttachToOwner —— 「第一次用」时建立归属关系。
--   ★★ 与 1041 行的 owneruserid 判断配合：
--     有 owneruserid → 严格比对（必须是自己的）
--     无 owneruserid → 宽松认领（但有数量上限）
--   ★ 「先到先得 + 有上限」的常见设计。
        if not owneruserid and not target:TryToAttachToOwner(doer) then
            return false, "TOOMANYBACKUPBODIES"
        end
    end
    return true
end

--★★【RUMMAGE.fn —— 全文件最长的动作实现（80 行）】
--   ★★ 它要处理「打开一个容器」这件事在 DST 里的**全部**形态：
--     ① container_proxy（代理：地图上的图标指向真容器）
--     ② 自己是容器（翻自己的背包）
--     ③ 骑乘中的自己（翻坐骑的鞍包）
--     ④ container_transform（会变形的箱子，如四季箱）
--     ⑤ 角色专属限制（1018 行那个函数）
--     ⑥ 被别人打开（INUSE）
--     ⑦ 载具专属（portablestorage 标记）
--     ⑧ 口袋维度容器（魔术高礼帽）
--     ⑨ 黑暗中静默失败
--   ★★ 每一个分支都是历史上某个特性留下的。删任何一个都会破坏某个功能。
--   ★★ 这也是 §0「同构模板谱系」里 T7（target or invobject）的极端样本。
ACTIONS.RUMMAGE.fn = function(act)
--★ targ 可能是 target（地上的箱子）也可能是 invobject（手里的盒子）。
    local targ = act.target or act.invobject
    if targ == nil then
        return
    end

--★★ container_proxy 处理 —— 「地图图标代表真实容器」的机制。
--   ★★ 1059-1063 行：拿到 master 后把 targ 指向 master，proxy 保留原对象。
--     ★ 为什么要区分 proxy 与 master？
--       因为**关闭**时必须通知 proxy（1081 行），而**打开/存放**时用 master。
--     ★★★ 理由：proxy 是「玩家看到的东西」，玩家点它要有反馈。
--       直接对 master 操作会显得「点了没反应」。
--   ★★ 这解释了为什么 RUMMAGE.fn 里 proxy 与 targ 两个变量反复交叉使用。
	local proxy
	if targ.components.container_proxy ~= nil then
		local master = targ.components.container_proxy:GetMaster()
		if master ~= nil then
			proxy = targ
			targ = master
		end
	end

--★ 1066-1068 行：目标是自己时，改查自己骑的坐骑。
--   ★★ 条件写成 `targ.components.container == nil and targ == act.doer` ——
--     顺序反直觉：先看组件再比身份。
--     ★ 结果一致但可读性差。属风格问题。
--   ★ 1067 行 rider:GetMount() 可能返回 nil（没骑东西）→ targ 变 nil。
--     后面的 `if targ and ...` 都在保护这一点。写法是对的。
	if targ and targ.components.container == nil and targ == act.doer then
		targ = targ.components.rider and targ.components.rider:GetMount() or nil
	end

--★★ container_transform —— 「会变的箱子」（如四季箱在不同季节换内容）。
--   ★★ 1071-1076 行：先问 CanTransform(doer)，不行就带原因返回。
--     可以的话调用 TryTransformToContainer() 得到**实际的**容器。
--   ★★★ 这是本文件里唯一会「在运行时替换掉 act.target」的地方 ——
--     targ 是 local 不影响 act，所以 fn 结束后 act.target 仍是原对象。
--     ★ 这是安全的，但也意味着 IsValid 检查的是原对象，
--       变形后的容器若无效不会被发现。极边缘。
    if targ and targ.components.container_transform ~= nil then
        local success, reason = targ.components.container_transform:CanTransform(act.doer)
        if not success then
            return false, reason
        else
            targ = targ.components.container_transform:TryTransformToContainer()
        end
    end

--★★ 从这里开始是「开箱 / 关箱」的主逻辑。
--   ★★ 1079-1130 共 51 行，是本文件里分支密度最高的段落。
    if targ ~= nil and targ.components.container ~= nil then
--★★ 1080-1083：**通过代理关闭**。
--   ★★ 1082 行的 closecontainer 事件是给 UI 用的 ——
--     玩家需要看到「箱子关上了」的提示。
--   ★★★ 注意每个关闭分支都要手动 PushEvent 一次，
--     没有走 Close() 内部的统一路径。这是一处重复。
        if proxy ~= nil and proxy.components.container_proxy:IsOpenedBy(act.doer) then
            proxy.components.container_proxy:Close(act.doer)
            act.doer:PushEvent("closecontainer", { container = targ })
            return true
--★ 1084-1087：**直接关闭**（无代理）。与 1080 完全对称。
        elseif proxy == nil and targ.components.container:IsOpenedBy(act.doer) then
            targ.components.container:Close(act.doer)
            act.doer:PushEvent("closecontainer", { container = targ })
            return true
--★ 1088-1090：被限制访问（如需要钥匙的箱子）→ RESTRICTED。
--   ★★ 注意这里只检查一次，且在「关」之后、「开」之前。
--     即「已经开着的受限容器可以关上，但不能打开」。合理。
        elseif targ.components.container:IsRestricted(act.doer) then
            return false, "RESTRICTED"
        end
--★ 调用 §1018 那个角色专属判断，并把它的 reason 透传出去。
--   ★★ 这就是「统一的知识库被两个动作共享」的具体形态。
        local success, reason = CanOpenCharacterSpecificContainer(act.doer, targ)
        if not success then
            return false, reason
        end
--★★ 1095-1096：「没打开过且不能打开」→ INUSE。
--   ★★★ 条件是 `not IsOpenedBy and not CanOpen` ——
--     已经打开的（IsOpenedBy 为真）就直接放行，无需 CanOpen。
--     CanOpen 表达的是「能不能**从关闭状态**打开」。
--   ★ 这是「重复点击同一个箱子不该报错」的正确处理。
        if not targ.components.container:IsOpenedBy(act.doer) and not targ.components.container:CanOpen() then
            return false, "INUSE"
--★★★ 大条件：canbeopened 且（无代理或代理可被打开）】
--   ★★ 1097 行末尾是整个 fn 的最后一个 return true（1128 行）。
--   ★ 但**它之前有大量「不 return」的分支**（1104-1118 的 droponopen 逻辑），
--     这些分支执行完会继续往下走，最终落到 1128 的 return true。
--   ★★ 这个「fall through」结构是本 fn 最难读的地方：
--     1104-1118 处理的是「先把容器从主人手里拿出来，再打开」，
--     处理完**继续**执行打开流程，而不是提前返回。
--     ★ 作者用注释 "--Silent fail, should not reach here"（1115 行）
--       标记了一个自认为不该到达的分支，说明作者自己对这段的控制流
--       已经没有十足把握了。
        elseif targ.components.container.canbeopened and (proxy == nil or proxy.components.container_proxy:CanBeOpened()) then
--★★ owner = 物品的 GrandOwner（背包→容器→主人，一路向上）。
--   ★★ 「Grand」是 DST 容器体系的关键概念：物品可能在自己的背包里、
--     在背包里的箱子、再在箱子里的另一个箱子里…
--     GetGrandOwner 一路向上找到最终持有者。
--   ★ 本文件里 owner/grandowner 的区分出现在 STORE/CHANGE_TACKLE/REPLATE 等。
            local owner = targ.components.inventoryitem ~= nil and targ.components.inventoryitem:GetGrandOwner() or nil
--★ ismount —— 打开者正是这个容器主人的骑手。
--   ★★ 1102 行的表达式 `(ismount and act.doer or owner):HasTag("player")`
--     用 and/or 三元：如果 ismount 为真用 doer，否则用 owner。
--     ★★ 目的是判断「打开者的真实身份」：骑马时打开自己的鞍包，
--       打开者是坐骑（没有 player 标签），但真实玩家是 doer。
--   ★ 这是本文件里最绕的一个三元表达式，读的时候拆成两步看。
			local ismount = (owner and owner.components.rideable and owner.components.rideable:GetRider()) == act.doer
--★★ droponopen / quagmire_stewer：这两个容器在被打开时会先「掉出来」。
--   ★★ 为什么？手机箱（portablestorage）被装备时打开，物品会凭空
--     从鞍袋里出来 —— 视觉上应该是「先拿出背包再打开」。
--   ★ 并且只对「打开者是真人」生效（1102 行），
--     打开者自己的坐骑打开时不需要掉落（因为本来就是连着的）。
			if owner and
				(targ.components.container.droponopen or targ.components.quagmire_stewer) and
				not ((ismount and act.doer or owner):HasTag("player") and targ:HasTag("portablestorage"))
			then
                if owner == act.doer then
                    owner.components.inventory:DropItem(targ, true, true)
--★★ 口袋维度容器（魔术高礼帽等）—— 特殊处理。
--   ★★ 1107-1109 行的保留英文注释解释了为什么跳过检查：
--     「跳过 IsOpenedBy(doer) 检查，因为魔术帽在做动作时会关闭，
--       但假定这个动作有效是相当安全的。」
--   ★★★ 这条注释揭示了一个真实的时序问题：
--     动作会关闭容器 → 之后想验证「是否已打开」必然为假。
--     作者的解决方案是「信任这个动作」。
--   ★ 1110 行还用了 GetOpenContainerProxyFor(owner) 拿世界坐标，
--     而不是用 owner 自己的坐标（因为口袋里的东西坐标是 0,0,0）。
				elseif owner:HasTag("pocketdimension_container") then
					--V2C: skipped IsOpenedBy(act.doer) check because magician's top hat
					--     closes when performing actions, but it's pretty safe to assume
					--     this action is valid.
					local x, y, z = (act.doer.components.inventory ~= nil and act.doer.components.inventory:GetOpenContainerProxyFor(owner) or act.doer).Transform:GetWorldPosition()
					owner.components.container:DropItemAt(targ, x, y, z)
                elseif owner.components.container ~= nil and owner.components.container:IsOpenedBy(act.doer) then
                    owner.components.container:DropItem(targ)
                else
--★ 作者自认的「不该到达」分支：return true 但什么都不做。
--   ★★★ 这是一个**诚实的兜底**：在逻辑不完整的情况下，
--     宁可「什么都不做但报告成功」，也不要崩。
--   ★ 与 §一 307 行「fn 默认返回失败」是同一种防御思路的另一个面。
                    --Silent fail, should not reach here
                    return true
                end
            end
--★★ 黑暗中静默失败 —— 全文件第 6 处（1120/2806/4075/4335/4418/6054/6098）。
--   ★★★ 为什么开箱要「看得见」？
--     因为黑暗里打开箱子，UI 弹出时玩家看不到里面是什么，
--     会以为箱子是空的。宁可不开。
--   ★★ 但 1120 行的条件里 ismount 或 owner == act.doer 会绕过这个检查：
--     ★ 自己的箱子在黑暗中也能开。★★ 因为玩家「知道」自己箱子里有什么。
--   ★ 这是一个很贴心的例外，值得记住。
            --Silent fail for opening containers in the dark
			if ismount or owner == act.doer or CanEntitySeeTarget(act.doer, proxy or targ) then
                act.doer:PushEvent("opencontainer", { container = targ })
                if proxy ~= nil then
                    proxy.components.container_proxy:Open(act.doer)
                else
                    targ.components.container:Open(act.doer)
                end
            end
            return true
        end
    end
end

--★★ RUMMAGE.strfn —— 「这个开箱动作现在该显示成什么词」。
--   ★★ 它比 fn 简单得多（27 行 vs 80 行），因为 strfn **只管 UI**
--     且必须在客户端跑 —— 客户端没有容器组件，所以只能用 replica。
--   ★★ 1137 行的注释「exists on clients too」点明了 container_proxy
--     是少数「客户端也有」的组件。
ACTIONS.RUMMAGE.strfn = function(act)
    local targ = act.target or act.invobject
    if targ == nil then
        return nil
--★★ 客户端分��：container_proxy 在客户端可读，所以能判断 CLOSE。
    elseif targ.components.container_proxy ~= nil then --exists on clients too
        if targ.components.container_proxy:IsOpenedBy(act.doer) then
            return "CLOSE"
        end
	else
--★ 非代理路径：用 replica.container（客户端副本）。
--   ★★★ 「客户端用 replica、服务端用 components」这条规则在此体现。
		local container = targ.replica.container
--★ 目标是自己时查坐骑 —— 与 fn 的 1066 行对称，但用 replica.rider。
		if container == nil and targ == act.doer then
			local rider = targ.replica.rider
			local mount = rider and rider:GetMount() or nil
--★★★⚠⚠ 疑似缺陷 L3：`container = mount.replica.container`
--   ★★★ mount 在 1145 行是 `rider and rider:GetMount() or nil`，
--     **完全可能是 nil**（没有 rider、或 rider 没有 mount）。
--     下一行无条件 `mount.replica` ⇒ **index a nil value** 崩溃。
--   ★★ 对比紧邻的 fn 版本（1066-1068 行）写法是安全的：
--     `if targ and targ.components.container == nil and targ == act.doer then`
--     之后 `targ.components.rider and ... or nil`，全程 nil 安全。
--   ★★ 推理依据：strfn 在客户端每帧都可能被调用（用于显示提示），
--     「没有骑乘却点自己」是极常见的操作序列 ⇒ 崩溃可复现。
--   ★ 但实际上 1143 行要求 `container == nil`（自己没开容器）
--     且 `targ == act.doer`。玩家点自己时若无骑乘 ⇒ targ=doer, container=nil
--     ⇒ 进入分支 ⇒ mount=nil ⇒ 崩。
--   ★★★ 缓解：可能 strfn 只在服务端被调用（bufferedaction.lua:65），
--     而服务端组件齐全时 rider 存在但 GetMount() 仍可为 nil。
--   ★ 结论：真实的 nil 解引用缺陷。严重度中等（影响 UI 显示路径）。
--     只记录不修改。
			container = mount.replica.container
		end
		if container and container:IsOpenedBy(act.doer) then
			return "CLOSE"
		end
    end
--★★ 1152-1158：目标标签决定显示词。
--   ★★ decoratable → "DECORATE"（装饰）
--     unwrappable → "PEEK"（偷看包内）
--   ★★★ 这是「RUMMAGE 被多个系统复用」的直接证据：
--     装饰花瓶、偷看捆扎包都借用开箱动作，只改显示词与 fn 分支。
--   ★ 装饰实现在 DECORATEVASE.fn（2439 行），偷看在 PEEKBUNDLE.fn（4365 行）。
    if act.target then
        if act.target:HasTag("decoratable") then
            return "DECORATE"
        elseif act.target:HasTag("unwrappable") then
            return "PEEK"
        end
    end
    return nil
end

--★★ DROP.fn —— 「丢东西」的完整逻辑（含四种丢弃方式）。
--   ★★ 1163-1168：先检查「能不能卸」（与 UNEQUIP 同一判据）。
--   ★★ 1170-1183 的 DropItem 有 4 个参数，每一个都有讲究：
--     ① wholestack（整堆丢？）= act.options.wholestack 且该物品允许
--        ★ 1173-1176 的三重否定：不是整堆 **或** forcedropsingle ⇒ 单个丢。
--          forcedropsingle 用于「信标」这类必须一个个放的物品。
--     ② droprandomdir = 物品有 droprandomdir 标签时给随机方向
--        ★ 与 232 行的 ExtraDropDist 呼应：随机方向防止立刻被捡回。
--     ③ 第三个参数是 `or IsFloaterHeld()` —— ★★ 注意运算符优先级：
--        `(act.invobject.components.inventoryitem ~= nil and
--          act.invobject.components.inventoryitem.droprandomdir)
--        or act.doer.components.inventory:IsFloaterHeld()`
--        第三个参数是「是否保持被持有」或「是否浮空持有」。
--        ★ 写在一行里的 and/or 组合最容易误读。
--     ④ GetActionPoint() —— 丢在光标处而不是脚下。
--     ⑤ true = keepoverstacked（★ 行尾注释标明）—— 叠放的物品
--        被丢下时保留原有的堆叠关系。这是给「装饰性堆叠」用的。
ACTIONS.DROP.fn = function(act)
    if act.invobject ~= nil and
        act.invobject.components.equippable ~= nil and
        act.invobject.components.equippable:IsEquipped() and
        act.invobject.components.equippable:ShouldPreventUnequipping() then
        return nil
    end

--★ inventory 检查与 `and ... or nil` 结构：
--   ★★ 若 inventory 存在但 DropItem 返回 false，最终结果是 nil（失败）。
--     这是 Lua 的 and/or 惯用法的正常行为：
--       (true and false) or nil → false or nil → nil
--     ★ 即「失败」被转成了「返回 nil」，而 nil 在 Do() 里同样视为失败。
--       行为正确，但写法隐晦。
    return act.doer.components.inventory ~= nil
        and act.doer.components.inventory:DropItem(
                act.invobject,
                act.options.wholestack and
                not (act.invobject ~= nil and
                    act.invobject.components.stackable ~= nil and
                    act.invobject.components.stackable.forcedropsingle),
                (act.invobject.components.inventoryitem ~= nil
                    and act.invobject.components.inventoryitem.droprandomdir)
				or act.doer.components.inventory:IsFloaterHeld(),
				act:GetActionPoint(),
				true -- <--keepoverstacked
			)
        or nil
end

--★★ DROP.strfn —— 12 个变体的巨型 or 链。
--   ★★★ 顺序即优先级，从「确定的类���」到「可扩展的回调」：
--     trap/mine/soul/pumpkin_lantern → 具体标签
--     playerfloater                 → 浮标
--     GetDropActionString ~= nil    → ★ 自定义回调（最后一个兜底）
--   ★★ 1187 行的前置条件 `not HasActionComponent("deployable")` 很重要：
--     可部署物品（帐篷、旗子）**不走 DROP**，走 DEPLOY。
--     所以 DROP 落到这里的一定是「真正丢在地上」的东西。
--   ★ 1191 行 `prefab == "pumpkin_lantern"` 是硬编码 prefab 名 ——
--     与满文件的标签风格不一致，是一处特例。
--   ★★ 1196 行的 GetDropActionString 回调是给模组的扩展点，
--     优先级最低（放在 or 链末尾）。
ACTIONS.DROP.strfn = function(act)
    if act.invobject ~= nil and not act.invobject:HasActionComponent("deployable") then
        return (act.invobject:HasTag("trap") and "SETTRAP")
            or (act.invobject:HasTag("mine") and "SETMINE")
            or (act.invobject:HasTag("soul") and "FREESOUL")
            or (act.invobject.prefab == "pumpkin_lantern" and "PLACELANTERN")
--★ playerfloater —— 玩家的浮空标记（死亡后留下的气泡？）。
--   ★★ 1194 行被注释掉的 IsEquipped() 检查，行尾注释说明是「冗余的，
--     playerfloater 只在装备着的时候才有 equippable 组件」。
--   ★ 又一处「保留被注释的检查 + 解释为何可以删」。好习惯。
			or (act.invobject:HasTag("playerfloater") and
				act.invobject.replica.equippable and
				--act.invobject.replica.equippable:IsEquipped() and --redundant, playerfloater only has equippable component when it is equipped
				"PLAYERFLOATER")
            or (act.invobject.GetDropActionString ~= nil and act.invobject:GetDropActionString(act:GetActionPoint()))
            or nil
    end
end

--★ ShouldLOOKATStopLocomotor —— 一个反直觉的小函数。
--   ★★★ 它返回 true 的条件是「**不是**（直接操控 或 状态覆盖移动）」：
--     · playercontroller.directwalking（玩家正在用键盘直走）
--     · sg 有 overridelocomote 状态标签（状态图正在接管移动）
--   ★★ 意思是「这两种情况下不要打断移动」。
--     ★ 直走时若被 Stop()，玩家会突然停步 —— 体感很差。
--     ★ overridelocomote 时（传送动画中）打断移动会破坏状态。
--   ★★ 正确读法：函数名是「是否应该停」，返回 true = 应该停。
--     ★ 名字里的 Should 前缀 + or 组合容易读反，加注释很有必要。
local function ShouldLOOKATStopLocomotor(act)
    return not (
        (act.doer.components.playercontroller ~= nil and act.doer.components.playercontroller.directwalking) or
        (act.doer.sg ~= nil and act.doer.sg:HasStateTag("overridelocomote"))
    )
end

--★ LOOKAT.strfn —— CLOSEINSPECT 与 READ 两个变体。
--   ★★ 1210 行的条件 `act.invobject == nil and CanCloseInspect(...)`：
--     ★★★ 手上拿着东西时不允许「凑近看」—— 因为手持物优先级更高。
--       「查看」是兜底动作，手持物出现时必须让位。
--   ★ 1212-1217：拿着 ancient_reader 标签的装备看 ancient_text → "READ"。
--     ★ 这里用了 EquipHasTag（检查装备槽），说明「拿着放大镜」才能读书。
ACTIONS.LOOKAT.strfn = function(act)
	if act.invobject == nil and CLOSEINSPECTORUTIL.CanCloseInspect(act.doer, act.target or act:GetActionPoint()) then
		return "CLOSEINSPECT"
	end
	if act.target and act.target:HasTag("ancient_text") then
		local inventory = act.doer and act.doer.replica.inventory
		if inventory and inventory:EquipHasTag("ancient_reader") then
			return "READ"
		end
	end
end

--★★【LOOKAT.fn —— 60 行，四条互斥路径】
--   ★★ 结构：
--     ① 凑近看实体（有 closeinspector 装备）→ 1231
--     ② 凑近看位置（无 target）              → 1249
--     ③ 普通查看（inspectable 组件）        → 1269
--   ★★★ 1231 与 1249 两段结构完全相同，只有 CloseInspectTarget
--     与 CloseInspectPoint 的差别，以及 1223/1240 的 if/else。
--     ★ 这是「实体版与坐标版看东西」的重复实现。
--   ★★ 1225 行的 `for k, v in pairs(EQUIPSLOTS)`：
--     ★★★ 遍历**所有装备槽**找 closeinspector 组件 ——
--       意味着「凑近看」的能力可以挂在任何装备上（眼镜、望远镜）。
--       不只是主手。
--     ★ 代价：每次 LOOKAT 都要遍历 10 个装备槽。频率低，可接受。
ACTIONS.LOOKAT.fn = function(act)
	--Try close inspection first
	if act.invobject == nil and act.doer.components.inventory then
		if act.target then
			if CLOSEINSPECTORUTIL.CanCloseInspect(act.doer, act.target) then
				for k, v in pairs(EQUIPSLOTS) do
					local equip = act.doer.components.inventory:GetEquippedItem(v)
					if equip and equip.components.closeinspector then
						if ShouldLOOKATStopLocomotor(act) then
							act.doer.components.locomotor:Stop()
						end
--★★ CloseInspectTarget 的失败处理很特别（1232-1235 行）：
--   ★★ 它不返回 false，而是**用 talker 说一句失败原因**然后返回 success。
--     ★★★ 为什么？因为「凑近看」是一个长动作（要走到位），
--       如果返回 false，玩家看到的是通用失败（抖动 + 「不能这么做」），
--       但实际上真正的失败原因（「太远了」「没对准」）更有信息量。
--     ★ 而 talker:Say 直接说出来是最有效的反馈。
--   ★★★ sgparam = { closeinspect = true } 传给 talker：
--     ★★★ 让状态图知道「这次说话是因为凑近看」，从而选对应的说话动画。
--       这是一个「用参数把 fn 与状态图联系起来」的手法。
						local success, reason = equip.components.closeinspector:CloseInspectTarget(act.doer, act.target)
						if not success then
							local sgparam = { closeinspect = true }
--★ 十个连续 nil 参数只为把 sgparam 放到第十位。
--   ★★★ 这是 Lua 无命名参数的直接代价 ——
--     talker:Say 的签名有十几个可选参数。
--   ★★★ 但也说明一个事实：**参数位置是一种隐式契约**。
--     改 talker:Say 的签名会静默破坏这里。
--   ★ 签名核对：talker.lua:266 Talker:Say(script, time, noanim, force,
--     nobroadcast, colour, text_filter_context, original_author_netid,
--     onfinishedlinesfn, sgparam) —— 正好 10 个，sgparam 排第 10。
--     ★ 本行「1 个实参 + 8 个 nil + sgparam」正好对上，少一个或多个都会串位。
--     1269 行的 8 参调用则把 original_author 放在第 8 位，对应正确。
--   ★ 这是全文件里最脆的耦合形态，值得警惕。
							act.doer.components.talker:Say(GetActionFailString(act.doer, "LOOKAT", reason), nil, nil, nil, nil, nil, nil, nil, nil, sgparam)
--★★ LOOKAT.fn 内部：1220-1259 是「凑近看」的实体版与坐标版两段。
--   ★★ 1235-1240 行是「实体版结束、坐标版开始」的分界。
--   ★ 两段的差异只在 `if act.target then` / `else`，
--     以及 CloseInspectTarget vs CloseInspectPoint。
						end
						return success, reason
--★★ LOOKAT.fn 的坐标版（1240-1258 行）与实体版（1223-1239）结构对称。
--   ★★ 唯一差异：
--     · 实体版：if act.target then ... CloseInspectTarget
--     · 坐标版：else ... CloseInspectPoint(act.doer, pt)
--   ★★★ 这是全文件里少见的「有目标 / 无目标」双分支都用同一套逻辑，
--     而不是写成两个独立动作（如 PICKUP vs PICKUP_MAP）。
--       ★ 因为「看一个东西」与「看一个位置」在体感上完全一样。
					end
				end
			end
		else
			local pt = act:GetActionPoint()
			if pt and CLOSEINSPECTORUTIL.CanCloseInspect(act.doer, pt) then
				for k, v in pairs(EQUIPSLOTS) do
					local equip = act.doer.components.inventory:GetEquippedItem(v)
					if equip and equip.components.closeinspector then
						if ShouldLOOKATStopLocomotor(act) then
							act.doer.components.locomotor:Stop()
--★ 1248 行 —— 坐标版的「停步」判断（ShouldLOOKATStopLocomotor）。
--   ★★ 与 1228 行完全相同。★ 两处都调 locomotor:Stop()。
--   ★★ 注意 1229/1247 行的调用形式不同：
--     1229 `act.doer.components.locomotor:Stop()`
--     ★ 两者可读性略有差异，但行为相同。
						end
						local success, reason = equip.components.closeinspector:CloseInspectPoint(act.doer, pt)
						if not success then
							local sgparam = { closeinspect = true }
--★ 1252 行 —— 坐标版的失败说话（与 1234 行对称）。
--   ★★★ 这里再次出现 talker:Say 的十个位置参数。
--     ★ 1234 与 1252 两处各写了一遍完全相同的十个 nil + sgparam。
--       ★ 属 L 类重复（若 talker:Say 签名变化需改两处）。
							act.doer.components.talker:Say(GetActionFailString(act.doer, "LOOKAT", reason), nil, nil, nil, nil, nil, nil, nil, nil, sgparam)
						end
						return success, reason
					end
				end
			end
		end
	end

--★★ 普通查看路径：`local targ = act.target or act.invobject`（T7）。
--   ★★ 1262 行用 `targ.components.inspectable` —— 注意这里是 components
--     而非 replica。★ 说明 fn 只在服务端跑（见 §一 307 行）。
	local targ = act.target or act.invobject
	if targ and targ.components.inspectable then
--★ GetDescription 返回三个值：描述文本、文本过滤上下文、原作者。
--   ★★★ text_filter_context 与 original_author 是多人游戏的必要字段：
--     自定义告示牌可以设置「只对某个玩家显示原文」。
--   ★ 若 desc 为 nil（这东西没描述）则整个分支不执行，fn 返回 nil。
		local desc, text_filter_context, original_author = targ.components.inspectable:GetDescription(act.doer)
		if desc then
			if ShouldLOOKATStopLocomotor(act) then
				act.doer.components.locomotor:Stop()
			end
			if act.doer.components.talker then
--★ noanim = inspectable.noanim ——「不播说话动画」。
--   ★★★ 为什么需要？因为某些 inspectable（书籍、告示牌）说话时
--     应该保持自己的姿势而不是换成说话姿势。
--   ★★ 这说明**组件自己决定「该不该播动画」**，而不是调用方。
--     设计上更干净。
				act.doer.components.talker:Say(desc, nil, targ.components.inspectable.noanim, nil, nil, nil, text_filter_context, original_author)
--★★ 1270 行 —— LOOKAT.fn 结尾。
--   ★★ 1261-1273 的「普通查看」路径与 1222-1259 的「凑近看」路径
--     是两个互斥的功能分支：
--     · 手上装备了 closeinspector 组件 → 走凑近看
--     · 目标/位置可被 inspectable 描述   → 走普通查看
--   ★★ 返回值有两种可能：1220 段的 success/reason 或 1271 的 true。
--   ★ 落在 1274 行之后的「无描述」情况返回 nil（静默失败）。
			end
			return true
		end
	end
end

local MAP_SELECT_WORMHOLE_MUST = { "CLASSIFIED", "globalmapicon", "wormholetrackericon" }
ACTIONS_MAP_REMAP[ACTIONS.ACTIVATE.code] = function(act, targetpos)
    local doer = act.doer
    if doer == nil then
--★★★ ACTIONS_MAP_REMAP[ACTIONS.ACTIVATE.code] —— 地图重映射的第 1 例（44 行）
--   ★★ 它把「在地图上点某个图标」翻译成「在世界里对某个目标做 ACTIVATE」。
--     ★ 翻译的产物是一个**新的 BufferedAction**（1310 行）：
--       BufferedAction(doer, charlieresidue, ACTIONS.JUMPIN_MAP,
--         nil, targetpos)
--     ★★★ 注意它的 action 是 **JUMPIN_MAP 而不是 ACTIVATE** ——
--       「地图上的激活」被翻译成另一个动作。
--     ★ 原因是：地图上的点没有实体 target，JUMPIN_MAP 有专门的处理。
--   ★★ 整个函数的核心是「找上下文」：
--     1286 行 先问 LOOKAT.strfn 是不是 CLOSEINSPECT（凑近看）
--     1290-1299 找章鱼残留物（客户端从 maptarget、服务端从组件）
--     1304-1314 若上下文是「虫洞」，在附近找另一个虫洞作为出口
--   ★★★ 这就是 §0 T9「地图动作重映射」的最小完整实例。
        return nil
    end

    -- NOTES(JBK): This is where contexts are provided to enforce restrictions on this remap action.
    local act_remap = nil

    local actstr = ACTIONS.LOOKAT.strfn(act)
    if actstr == "CLOSEINSPECT" then
        -- First, let us try to find a charlieresidue to attach our actions to.
        local charlieresidue = nil
        if act.maptarget then -- From local client map.
            if act.maptarget.prefab == "charlieresidue" then
                charlieresidue = act.maptarget
            end
        else
--★★ 客户端/服务端两套来源的写法（1290 vs 1295）：
--   客户端：`act.maptarget.prefab == "charlieresidue"`（地图上的对象）
--   服务端：`doer.components.roseinspectableuser.residue`（组件记录）
--   ★★★ 同构的双端处理，与 actions.lua:1402 那套 replica/components 对照。
            local roseinspectableuser = doer.components.roseinspectableuser
            if roseinspectableuser then
                charlieresidue = roseinspectableuser.residue
            end
        end
--★ 保留的英文注释是一份**给翻译/本地化人员的注意事项**：
--   「V2C: 我们只是返回同一个字符串，但因为它技术上被『覆盖』了，
--     它不会显示目标：例如『Tell Story Portable Campfire』。」
--   ★★ 注意这条注释出现在 1574 行，但紧挨着 1277 行的
--     ACTIONS_MAP_REMAP 与 READ.fn —— 位置略偏，说明它是后补的。
        if charlieresidue and charlieresidue:IsValid() then
            local residuetarget = charlieresidue:GetTarget()
            local rx, ry, rz = residuetarget.Transform:GetWorldPosition()
            local context = charlieresidue:GetMapActionContext()
            if context > CHARLIERESIDUE_MAP_ACTIONS.NONE then
                if context == CHARLIERESIDUE_MAP_ACTIONS.WORMHOLE then
                    local ents = TheSim:FindEntities(targetpos.x, targetpos.y, targetpos.z, TUNING.SKILLS.WINONA.WORMHOLE_DETECTION_RADIUS, MAP_SELECT_WORMHOLE_MUST)
                    for _, ent in ipairs(ents) do
                        local ex, ey, ez = ent.Transform:GetWorldPosition()
                        if ex ~= rx and ez ~= rz then
                            act_remap = BufferedAction(doer, charlieresidue, ACTIONS.JUMPIN_MAP, nil, targetpos)
                            break
                        end
                    end
                end
            end
        end
    end

    return act_remap
end

--★★ READ.fn —— 「读」的三种形态。
--   ★★ 1325 行的三元写法要注意：
--     `targ.components.book ~= nil and act.doer.components.reader ~= nil`
--     短路求值保证 components.book 为 nil 时不会去读它。
--   ★★ 三分支：
--     book     → 需要 reader 组件（韦伯读「书」？）
--     simplebook→ 直接调 Read，不需要 reader（普通书本）
--   ★★ 1328 行的 elseif 不检查 doer 是否有 reader —— 
--     「简单书」不需要特殊能力，任何人都能读。
ACTIONS.READ.fn = function(act)
    local targ = act.target or act.invobject
    if targ ~= nil and act.doer ~= nil then
		if targ.components.book ~= nil and act.doer.components.reader ~= nil then
            local success, reason = act.doer.components.reader:Read(targ)
	        return success, reason
		elseif targ.components.simplebook ~= nil then
			targ.components.simplebook:Read(act.doer)
			return true
		end
	end
end

--★★★ ROW_FAIL.fn —— T6 影子动作价值最清晰的样本（§2 565 行已预告）。
--   ★★★ 请对照这段与 fn 主体（1350 行）一起读，能看到影子动作的全部动机：
--     · fn 主体在「桨掉耐久」时走 oar:Row(1341 行的 RowFail)
--     · 影子动作 ROW_FAIL 专门处理「没桨」或「桨坏了」的失败路径
--   ★★ 1339-1340 行的保留注释解释了一切：
--     「不能靠返回 false 来触发动作失败串，因为返回 false 会跳过
--       finite uses 回调，桨就不会掉耐久。」
--   ★★★ 这条注释揭示了一个**跨系统耦合**：
--     bufferedaction.lua:34 的 Fail() 会跑 onfail 回调，
--     而 finiteuses 的回调挂在 Succeed 路径上。
--     也就是说「返回失败」不只是「告诉玩家失败」，
--     它还会**改变物品被如何处理**。
--   ★⇒ 推论（贯穿全文件）：fn 的返回值不只是 UI 反馈，
--     它是「物品耐久是否消耗」的总开关。
--     ★★ 这解释了为什么这么多动作宁可 return true 也不 return false。
--   ★ 1341-1345：手动 Say 失败串 + 1346 行补一个假的 "working" 事件。
--     ★★★ 1346 行有注释「it's not actually doing work, but it can fall
--       out of your hand when wet.」—— 即「防止湿手时桨自己掉出来」。
--     ★★★ 这是一处**副作用驱动**的伪事件：不是为了工作，
--       而是为了触发「手湿了会掉东西」这个副作用。
ACTIONS.ROW_FAIL.fn = function(act)
    local oar = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    if (oar == nil) or (oar.components.oar == nil) then return false end

    --Can't rely on return false to trigger action fail string because returning
    --false skips the finite uses callback and the oar won't lose durability
    local fail_string_id = oar.components.oar:RowFail(act.doer)
    if act.doer.components.talker ~= nil then
        local fail_str = GetActionFailString(act.doer, "ROW_FAIL", fail_string_id)
        act.doer.components.talker:Say(fail_str)
    end
    act.doer:PushEvent("working",{}) -- it's not actually doing work, but it can fall out of your hand when wet.
    return true
end

--★【row() 局部函数 —— ROW 与 ROW_CONTROLLER 共用的实现】
--   ★★ 1372/1376 两行都只做 `return row(act)`。
--     抽成局部函数而不是写两遍，因为两者的差异只在**声明**
--     （CheckRowRange 有无），实现完全相同。
--   ★★ 1353-1355 行的防御性检查：
--     `if oar and not oar.components.oar then oar = nil end`
--     ★★★ 这是本文件里唯一使用 `and not` 做「取反归一」的写法。
--       作用：手上拿的东西**没有** oar 组件时，把它当作「没拿桨」。
--       为什么要这样写而不是直接在下一行判断 components.oar？
--       因为后面 1365 行要用 `oar.components.oar:Row`，
--       需要先保证 oar 非 nil 或有 oar 组件。
--       ★ 归一化前置，后面就能放心使用。
local function row(act)
    local oar = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)

    if oar and not oar.components.oar then
        oar = nil
    end

--★ `not oar and not act.doer.components.crewmember` —— 船员也能划。
--   ★★★ 全文件唯一一次 crewmember（船员）检查。
--     船员不需要桨也能划船。1361-1362 行专门为它开了一个分支。
--   ★★ 1357 行的条件是 `not oar and not crewmember` ⇒ 两者都没有才失败。
--     写法上不如 `oar == nil and crewmember == nil` 直观。
    if not oar and not act.doer.components.crewmember then
        return false
    end

    if act.doer.components.crewmember then
        act.doer.components.crewmember:Row()
    elseif oar then
--★ `act:GetActionPoint() or act.target:GetPosition()` —— 坐标兜底。
--   ★★ 这是一个通用模式：当动作既可能有点又可能有实体目标时，
--     用 GetActionPoint 统一处理。
--     ★★ 为什么划船会有点？467 行 ROW_CONTROLLER 没有 target。
        local pos = act:GetActionPoint() or act.target:GetPosition()
        oar.components.oar:Row(act.doer, pos)
--★ 又一处「伪 working 事件」，与 1346 行同一个理由。
        act.doer:PushEvent("working",{}) -- it's not actually doing work, but it can fall out of your hand when wet.
    end

    return true
end

--★ ROW.fn → row()。两行转发。
ACTIONS.ROW.fn = function(act)
    return row(act)
end

--★ ROW_CONTROLLER.fn → row()。与 1372 完全相同。
--   ★★ 实现相同但声明不同（566 vs 567）：
--     ROW              有 CheckRowRange（探针检查站位）
--     ROW_CONTROLLER  没有，且 do_not_locomote=true
--   ★★★ 这印证了 §2 566 行的推断：手柄玩家用摇杆驱动，
--     不需要站位检查，且原地划即可。
ACTIONS.ROW_CONTROLLER.fn = function(act)
    return row(act)
end

--★★ BOARDPLATFORM.fn —— 一个只有一行的 fn（return true）。
--   ★★ 配合 customarrivecheck=CheckIsOnPlatform（§零 99 行），
--     这个动作的全部语义都在「何时触发」上，「做什么」是空。
--   ★ 这是 T5「状态图驱动」的最纯粹形态：动作只是个信号。
ACTIONS.BOARDPLATFORM.fn = function(act)
	return true
end

--★ OCEAN_FISHING_POND.fn —— 判断目标是不是「虚拟海洋」（鱼塘）。
--   ★★ 失败原因 "WRONGGEAR" 有点误导：不是装备问题，是地点问题。
--     ★ 可能沿用了「地点不对」的旧措辞未改。轻微不一致。
ACTIONS.OCEAN_FISHING_POND.fn = function(act)
    if act.target:HasTag("virtualocean") then
        return true
    end

	return false, "WRONGGEAR"
end

--★★ OCEAN_FISHING_CAST.fn —— 抛竿的标准三步：取竿、定点、调用。
--   ★★ 1393 行 `act.invobject or GetEquippedItem(EQUIPSLOTS.HANDS)` ——
--     ★★★ T7 的第三种变体：动作的两个对象槽（target/invobject）
--       都不是「装备」，而是「手上的东西」或「手持的竿」。
--     ⇒ 于是每个钓鱼动作都要写这一行。
--     ★ 全文件共出现约 8 次（1403/1410/1417/1427/1393/1883/1891/1905）。
--     其中 1403 与 1905 用的是 **replica** 版本（strfn 必须在客户端跑），
--     1393/1410/1417/1427 用的是 **components** 版本（fn 在服务端跑）。
--     ★★★ 这条区分是本文件最重要的 client/server 对照，见下。
ACTIONS.OCEAN_FISHING_CAST.fn = function(act)
    local rod = act.invobject or act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    local pos = act:GetActionPoint()
    if pos == nil then
        pos = act.target:GetPosition()
    end

    return (rod ~= nil and rod.components.oceanfishingrod ~= nil) and rod.components.oceanfishingrod:Cast(act.doer, pos) or nil
end

--★★ OCEAN_FISHING_REEL.strfn —— 「客户端读副本」的标准示范。
--   ★★★ 1403-1404 行逐字对照 fn（1410 行）：
--     strfn: act.doer.**replica**.inventory ... rod.**replica**.oceanfishingrod
--     fn:    act.doer.**components**.inventory ... rod.**components**.oceanfishingrod
--   ★★★ 其余逻辑完全一致。这不是重复，而是**同一套逻辑跑两遍**：
--     fn 在服务端决定「成功/失败」，strfn 在客户端决定「显示什么字」。
--     ★★ 为什么不用副本跑 fn？因为 fn 要改状态，必须在服务端。
--     ★★ 为什么不用组件跑 strfn？因为客户端没有 components。
--   ★⇒ 结论：**凡是同时有 fn 和 strfn 的动作，都要写两份逻辑**。
--     本文件里这样的动作有 12 个（COOK 除外，COOK 用 stroverridefn）。
--     ★ 这是 DST 联机架构必然带来的重复，没有办法完全消除。
--   ★ 1404 行的 `rod:IsValid()` 检查在副本上调用 —— 副本也有 IsValid。
ACTIONS.OCEAN_FISHING_REEL.strfn = function(act)
    local rod = act.invobject or act.doer.replica.inventory ~= nil and act.doer.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
	local target = (rod ~= nil and rod:IsValid() and rod.replica.oceanfishingrod ~= nil) and rod.replica.oceanfishingrod:GetTarget() or nil
	return (target ~= nil and target:HasTag("partiallyhooked")) and "SETHOOK"
			or nil
end

--★ OCEAN_FISHING_REEL.fn —— 服务端版。silent_fail 让失败不吵玩家。
ACTIONS.OCEAN_FISHING_REEL.fn = function(act)
    local rod = act.invobject or act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if rod ~= nil and rod.components.oceanfishingrod ~= nil then
		return rod.components.oceanfishingrod:Reel()
	end
end

--★ OCEAN_FISHING_STOP.fn —— T5 模板：显式 GoToState + 组件调用。
--   ★★ 1420 行 `StopFishing("reeledin")` 的字符串参数说明原因，
--     供组件决定播放什么动画/音效。
--   ★★★ 三个动作（STOP 1416/CATCH 1426/REEL 1409）连续排列，
--     都是同一套「取竿 → 调组件」结构。
ACTIONS.OCEAN_FISHING_STOP.fn = function(act)
    local rod = act.invobject or act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if rod ~= nil and rod.components.oceanfishingrod ~= nil then
        act.doer.sg:GoToState("oceanfishing_stop")
		rod.components.oceanfishingrod:StopFishing("reeledin")
	end

	return true
end

--★ OCEAN_FISHING_CATCH.fn —— priority=6（最高非 HIGH），执行完即结束。
ACTIONS.OCEAN_FISHING_CATCH.fn = function(act)
    local rod = act.invobject or act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if rod ~= nil and rod.components.oceanfishingrod ~= nil then
        act.doer.sg:GoToState("oceanfishing_catch")
		rod.components.oceanfishingrod:CatchFish()
	end

	return true
end

--★ CHANGE_TACKLE.strfn —— REMOVE / AMMO 两个变体 + 副本读取。
--   ★★ 1439 行 `equipped.replica.container:IsHolding(item)` ——
--     ★ 用副本判断「手持物里是否已装着」，客户端可读。
--   ★ 1440 行回退到 `HasTag("reloaditem_ammo")` —— 标签驱动。
ACTIONS.CHANGE_TACKLE.strfn = function(act)
	local item = (act.invobject ~= nil and act.invobject:IsValid()) and act.invobject or nil
    local equipped = (item ~= nil and act.doer.replica.inventory ~= nil) and act.doer.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
	return (equipped ~= nil and equipped.replica.container ~= nil and equipped.replica.container:IsHolding(item)) and "REMOVE"
			or (item ~= nil and item:HasTag("reloaditem_ammo")) and "AMMO"
			or nil
end

--★★★ CHANGE_TACKLE.fn —— 80 行，四条互斥路径（弹药容器的四种情形）。
--   ★★ 结构：
--     ① 1445-1448  前置检查（必须有手持物且它有 container）
--     ② 1450-1459  已持有 → 取出来（整堆取出，带 prevcontainer 清理）
--     ③ 1460-1493  usespecificslotsforitems → 特定槽位逻辑（3 个子分支）
--     ④ 1494-1522  普通容器 → 尝试放入，失败则换位/回退
--   ★★ 这是本文件里**最接近「通用引擎」的代码**：
--     它的逻辑与「钓鱼」「投掷」无关，只与「容器 + 堆叠 + 特定槽位」有关。
--     ★ §2 423 行的英文注释说得对：它已经被泛化成通用容器操作。
ACTIONS.CHANGE_TACKLE.fn = function(act)
	local equipped = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if act.invobject == nil or equipped == nil or equipped.components.container == nil then
		return false
	end

	if act.invobject.components.inventoryitem:IsHeldBy(equipped) then
		local item = equipped.components.container:RemoveItem(act.invobject, true, nil, true)

		if item ~= nil then
--★★ 1454-1455 行清理 prevcontainer / prevslot。
--   ★★★ 这两个字段是容器体系的「回滚信息」：
--     当 GiveItem 失败时，物品要能被送回原来的槽位。
--     ★ 1476-1481 与 6359-6360 都在做同样的清理。
--   ★★ 为什么手动清？因为 RemoveItem 之后这两个字段还留着，
--     会让「失败回滚」把物品送到一个已经不属于它的容器。
--     ★ 这是一个「忘记清理就会出幽灵物品」的坑，值得记住。
	        item.prevcontainer = nil
	        item.prevslot = nil

			act.doer.components.inventory:GiveItem(item, nil, equipped:GetPosition())
			return true
		end
--★★ 特定槽位容器（如弹药带的 6 个格子）—— 三分支：
--   ① 槽位空            → 直接放入（1467-1469）
--   ② 可堆叠且没满      → 合并（1470-1482）
--   ③ 其它（会腐烂/不能堆）→ 替换（1483-1493）
--   ★★ 三分支的顺序即优先级：空 > 可堆 > 可替换。
	elseif equipped.components.container.usespecificslotsforitems then
		local targetslot = equipped.components.container:GetSpecificSlotForItem(act.invobject)
		if targetslot == nil then
			return false
		end

		local cur_item = equipped.components.container:GetItemInSlot(targetslot)
		if cur_item == nil then
			local item = act.invobject.components.inventoryitem:RemoveFromOwner(equipped.components.container.acceptsstacks, true)
			equipped.components.container:GiveItem(item, targetslot, nil, false)
		elseif equipped.components.container.acceptsstacks and cur_item.components.stackable ~= nil
            and cur_item.components.stackable:CanStackWith(act.invobject)
			and not cur_item.components.stackable:IsFull()
		then
			local item = act.invobject.components.inventoryitem:RemoveFromOwner(equipped.components.container.acceptsstacks, true)
--★★★⚠ 可疑处（已核对：当前**不是**缺陷，但极脆）：
--     `GiveItem(act.invobject, targetslot, nil, false)`
--   ★★ 对比紧邻的 1469 行（同一分支的兄弟写法）：
--       1469: equipped.components.container:GiveItem(item, targetslot, nil, false)
--     1469 用的是 1468 行 RemoveFromOwner 的返回值 **item**，
--     1475 用的是 **act.invobject**（原始对象）。两处不一致。
--   ★★★ 核对结论（inventory.lua:1390-1404）：
--     RemoveFromOwner(wholestack) 在 `not wholestack` 且物品是堆叠时，
--       返回 `stack:Get()` —— 一个**不同的实体**（剥离出来的那一个）；
--       否则才返回原对象。
--     而 1470 行进入本分支的前置条件包含
--       `equipped.components.container.acceptsstacks` 为真，
--       而 1474 行传的正是 `acceptsstacks` 作为 wholestack
--       ⇒ wholestack 必为 true ⇒ item 与 act.invobject **恒等**。
--   ★★ 所以两处写法在当前代码下**行为完全一致**，不是 bug。
--   ★★★ 但它是一个**依赖前置条件维持的不变量**：
--     若将来有人放宽 1470 行的 acceptsstacks 前置条件（如允许非堆叠容器），
--     1475 行会立刻退化为「把已被剥离的实体重新 GiveItem」，
--     而失败分支（1476-1481）操作的 item 会变成另一个实体 ⇒ 物品可能复制。
--   ★⇒ 归类为「高危代码形状」而非缺陷。正确写法应统一用 item。
--     只记录不修改。
			if not equipped.components.container:GiveItem(act.invobject, targetslot, nil, false) then
				if item.prevcontainer then
					item.prevcontainer.inst.components.container:GiveItem(item, item.prevslot)
				else
					act.doer.components.inventory:GiveItem(item, item.prevslot)
				end
			end
			return true
        elseif cur_item.components.perishable or not (cur_item.components.stackable and cur_item.components.stackable:CanStackWith(act.invobject)) then
			local item = act.invobject.components.inventoryitem:RemoveFromOwner(equipped.components.container.acceptsstacks, true)
			local old_item = equipped.components.container:RemoveItemBySlot(targetslot)
			if not equipped.components.container:GiveItem(item, targetslot, nil, false) then
				act.doer.components.inventory:GiveItem(item, nil, act.doer:GetPosition())
			end
			if old_item then
				act.doer.components.inventory:GiveItem(old_item, nil, act.doer:GetPosition())
			end
			return true
		end
--★★ 普通容器路径 —— 三层回退（1496-1519 行），设计相当精细：
--   ① 放入成功 → 完事
--   ② 放入失败但**数量变了**（部分放入）→ 把剩余的还回玩家（1500 行）
--   ③ 放入失败且数量没变（完全没放进去）→ 与槽位 1 的物品交换
--   ★★ ② 的注释「something got moved, so just return the remainder」
--     说明作者清楚 GiveItem 可能部分成功。
--   ★★★ ③ 里还有一个子分支（1505-1509）：槽位 1 的物品**超量堆叠**，
--     此时不能交换（会破坏堆叠），只能还回玩家并提示。
--     ★ 1508 行的提示文案专属 slingshot 标签（弹弓的弹药槽超量堆叠）。
--     ⇒ 这是全文件里最长的一个失败分支（4 层判断）。
	elseif equipped.components.container:CanTakeItemInSlot(act.invobject) then
		local item = act.invobject.components.inventoryitem:RemoveFromOwner(equipped.components.container.acceptsstacks, true)
		local original_count = item.components.stackable and item.components.stackable:StackSize() or 1
		if not equipped.components.container:GiveItem(item, nil, nil, false) then
			local new_count = item.components.stackable and item.components.stackable:StackSize() or 1
			if original_count ~= new_count then
				--something got moved, so just return the remainder
				act.doer.components.inventory:GiveItem(item, nil, act.doer:GetPosition())
			else
				--nothing got moved, so lets swap with the first slot
				local old_item = equipped.components.container:GetItemInSlot(1)
				if old_item.components.stackable and old_item.components.stackable:IsOverStacked() then
					act.doer.components.inventory:GiveItem(item, nil, act.doer:GetPosition())
					if equipped:HasTag("slingshot") then
						act.doer.components.talker:Say(GetString(act.doer, "ANNOUNCE_AMMO_SLOT_OVERSTACKED"))
					end
				else
					old_item = equipped.components.container:RemoveItemBySlot(1)
					if not equipped.components.container:GiveItem(item, 1, nil, false) then
						act.doer.components.inventory:GiveItem(item, nil, act.doer:GetPosition())
					end
					if old_item then
						act.doer.components.inventory:GiveItem(old_item, nil, act.doer:GetPosition())
					end
				end
--★ 1523 行 `return false` —— 容器满且无槽位 1 时的兜底。
			end
		end
		return true
	end
	return false
end

--★★ TALKTO.fn —— 「说话」与「Maxwell 特殊处理」。
--   ★★ 1529 行显式 locomotor:Stop()：对话要停步。
--     ★ 与 LOOKAT.fn 里的 ShouldLOOKATStopLocomotor 形成对比 ——
--       那里要有条件判断（因为「查看」不该总停步），
--       这里直接停（因为对话本来就该站定）。
--   ★★ 1534 行的 StartThread 是本文件里**唯一**的协程调用：
--     `act.target.task = act.target:StartThread(function() ... DoTalk ... end)`
--     ★★★ 为什么要开协程？Maxwell 的对话是一个**持续多轮**的流程，
--       不能在一个 fn 里阻塞式做完。
--     ★ 存入 target.task 字段是为了「只允许一个对话在跑」，
--       覆盖前一个会取消旧的。
--   ★★★ 这与 bug-patterns.md A 类（协程相关）有关：
--     StartThread 返回的 task 若被丢弃，中断处理就失效。
--     ★ 这里存进了字段，所以可被找到 —— 是正确用法。
ACTIONS.TALKTO.fn = function(act)
    local targ = act.target or act.invobject
    if targ and targ.components.talkable then
        act.doer.components.locomotor:Stop()

        if act.target.components.maxwelltalker then
            if not act.target.components.maxwelltalker:IsTalking() then
                act.target:PushEvent("talkedto")
                act.target.task = act.target:StartThread(function() act.target.components.maxwelltalker:DoTalk(act.target) end)
            end
        end
        return true
    end
end

--★ INTERACT_WITH.strfn —— FARM_PLANT 变体（照料作物）。
ACTIONS.INTERACT_WITH.strfn = function(act)
    return act.target ~= nil
        and act.target:HasTag("farm_plant") and "FARM_PLANT"
		or nil
end

--★★ INTERACT_WITH.fn —— 「照料成功也要说话」的设计。
--   ★★ 1551 行 `sg:AddStateTag("idle")` 很关键：
--     ★★★ 加了 idle 状态标签，状态图才允许 talker 接管。
--       否则 talker:Say 会被 SG 的当前状态压掉（说话动画播不出来）。
--     ★ 这是一个「跨系统的隐式协议」：动作要在说话前让 SG 知道「我空闲了」。
--   ★ 1552 行的固定台词 "ANNOUNCE_TALK_TO_PLANTS" —— 
--     「照料作物」是少数带专属台词的动作。
ACTIONS.INTERACT_WITH.fn = function(act)
	if act.target ~= nil and act.target.components.farmplanttendable ~= nil then
        if act.target.components.farmplanttendable:TendTo(act.doer) then
            if act.doer.components.talker ~= nil then
                act.doer.sg:AddStateTag("idle") -- allow talker state to take over
                act.doer.components.talker:Say(GetString(act.doer, "ANNOUNCE_TALK_TO_PLANTS"))
            end
			return true
		end
	end
end
--★ INTERACT_WITH.theme_music_fn —— 「对着作物做 → farming 音乐」。
--   ★★★ 注意它读的是 `act.target:HasTag("farm_plant")` ——
--     纯客户端判断（tag 在客户端可读），所以不需要组件副本。
ACTIONS.INTERACT_WITH.theme_music_fn = function(act)
    return act.target ~= nil
        and act.target:HasTag("farm_plant") and "farming"
		or nil
end

--★ ATTACKPLANT.fn —— 「打作物来减压」。两个副作用：压压力 + 变为可照料。
--   ★★ 1567-1569 行的联动很妙：攻击作物之后它变成「可照料」状态，
--     于是玩家需要接着用 INTERACT_WITH 照料它。
--     ★ 这是一个「两个动作协同构成一个玩法」的小设计。
ACTIONS.ATTACKPLANT.fn = function(act)
    if act.target ~= nil and act.target.components.farmplantstress ~= nil then
        act.target.components.farmplantstress:SetStressed("happiness", true, act.doer)
        if act.target.components.farmplanttendable then
            act.target.components.farmplanttendable:SetTendable(true)
        end
        return true
    end
end

--V2C: We're just returning the same string, but because it's technically "overridden",
--     it won't show the target: e.g. "Tell Story Portable Campfire"
ACTIONS.TELLSTORY.stroverridefn = function(act)
	return STRINGS.ACTIONS.TELLSTORY
end

ACTIONS.TELLSTORY.fn = function(act)
    local targ = act.target or act.invobject
	if act.doer.components.storyteller ~= nil then
		return act.doer.components.storyteller:TellStory(act.target or act.invobject)
	end
end

--★ PERFORM.fn —— 表演。stdactor + stageactingprop 双重组件检查。
ACTIONS.PERFORM.fn = function(act)
    if (act.doer ~= nil and act.doer.components.stageactor ~= nil)
            and (act.target ~= nil and act.target.components.stageactingprop ~= nil) then
        return act.target.components.stageactingprop:DoPerformance(act.doer)
    end
end

--★ BAIT.fn —— T1 模板：trap 组件 + RemoveItem + SetBait。
--   ★★ 1596 行把 bait 作为 RemoveItem 的结果直接传入 —— 
--     若背包里没有诱饵，RemoveItem 返回 nil，SetBait(nil) 的行为由组件决定。
ACTIONS.BAIT.fn = function(act)
    if act.target.components.trap then
        act.target.components.trap:SetBait(act.doer.components.inventory:RemoveItem(act.invobject))
        return true
    end
end

--★★★ DEPLOY.fn —— 「放置」的三种模式（42 行）。
--   ★★ 三模式对应三类可部署物：
--     ① complexprojectile（1648 行的岩浆球类）→ 先 DropItem 再 Launch
--        ★★ 关键差异：物品**没有**离开背包的所有权就发射了 ——
--          DropItem 才真正创建地面实体。
--     ② keep_in_inventory_on_deploy（1616 行）→ 部署但物品还在包里
--        ★ 这类物品是「布置」而非「消耗」（如某些魔法阵）。
--     ③ 普通（1618-1632）→ RemoveItem → Deploy，**失败要还回**
--   ★★★ ③ 的事务模板最值得学：
--       obj = container:RemoveItem(act.invobject)
--       if obj then
--           obj.prevcontainer = nil; obj.prevslot = nil   ← 清理回滚信息
--           success, reason = obj.components.deployable:Deploy(...)
--           if success then return true
--           else container:GiveItem(obj); return false, reason end
--       end
--     ★ 三步缺一不可：清理（否则还回位置不对）、尝试、还回。
--     ★ 这是 T11「消耗道具」模板的完整形态，见 §0。
ACTIONS.DEPLOY.fn = function(act)
	local act_pos = act:GetActionPoint()
    if act.invobject ~= nil and act.invobject.components.deployable ~= nil then
        local candeploy, reason = act.invobject.components.deployable:CanDeploy(act_pos, nil, act.doer, act.rotation)
        if not candeploy then
            return false, reason
        end
--★★ complexprojectile 分支 —— 「投掷型部署」。
--   ★★ 1610-1612 行：DropItem 产生地面实体，再 Launch 发射。
--     ★★ 与 TOSS.fn（3934 行）的结构相同，差别在于这里用的是
--       `complexprojectile:Launch` 而不是 `complexprojectile:Launch(pos, doer)`
--       —— 实际上是同样的调用，参数不同（TOSS 从 act.target 或 act point 取点）。
--     ★ 换句话说 DEPLOY 的这个分支是 TOSS 的简化版。
		if act.invobject.components.complexprojectile then
			if act.doer.components.inventory then
				local projectile = act.doer.components.inventory:DropItem(act.invobject, false)
				if projectile then
					projectile.components.complexprojectile:Launch(act_pos, act.doer)
					return true
				end
			end
		elseif act.invobject.components.deployable.keep_in_inventory_on_deploy then
            return act.invobject.components.deployable:Deploy(act_pos, act.doer, act.rotation)
        else
--★ `container = inventory or components.container` —— 兼容玩家与 AI。
--   ★★ 玩家有 inventory，AI（牛、蜘蛛）有 container。
--     同一个动作服务两类执行者。
            local container = act.doer.components.inventory or act.doer.components.container
            local obj = container ~= nil and container:RemoveItem(act.invobject) or nil
--★★ 清理 prevcontainer/prevslot（与 1454 行同一个理由，见 p3 的说明）。
            if obj ~= nil then
                obj.prevcontainer = nil
                obj.prevslot = nil

--★★ 部署失败 ⇒ 物品还回容器，并返回失败原因。
--   ★★★ 这是「事务」的 rollback 步骤。整个函数只有这一处失败还回，
--     说明作者对「部署会失败」这件事有清醒认识。
                local success, reason = obj.components.deployable:Deploy(act_pos, act.doer, act.rotation)
                if success then
                    return true
                else
                    container:GiveItem(obj)
                    return false, reason
                end
            end
        end
    end
end

--★★ DEPLOY.strfn —— 13 个变体的标签 or 链。
--   ★★ 值得注意的两个「同词不同标签」：
--     trap → TURRET        deploykititem → TURRET
--     eyeturret → TURRET   ★★★ 三个不同标签输出同一个词 TURRET。
--   ★ 这说明标签体系是「一词多标签」的。反过来「一标签多词」也成立
--     （groundtile→GROUNDTILE 但 wallbuilder→WALL）。
--   ★★ 顺序即优先级：projectile 在 groundtile 之前，
--     所以「既像投射物又像地面砖」的物品会显示成投掷。
ACTIONS.DEPLOY.strfn = function(act)
    return act.invobject ~= nil
        and (   (act.invobject:HasTag("usedeploystring") and "DEPLOY") or
				(act.invobject:HasTag("projectile") and "DEPLOY_TOSS") or
                (act.invobject:HasTag("groundtile") and "GROUNDTILE") or
                (act.invobject:HasTag("wallbuilder") and "WALL") or
                (act.invobject:HasTag("fencebuilder") and "FENCE") or
                (act.invobject:HasTag("gatebuilder") and "GATE") or
                (act.invobject:HasTag("portableitem") and "PORTABLE") or
                (act.invobject:HasTag("boatbuilder") and "WATER") or
                (act.invobject:HasTag("trap_fumarole") and "HOT_ROCKS") or
                (act.invobject:HasTag("trap") and "TURRET") or
                (act.invobject:HasTag("deploykititem") and "TURRET") or
                (act.invobject:HasTag("eyeturret") and "TURRET") or
                (act.invobject:HasTag("fertilizer") and "FERTILIZE_GROUND") or
                (act.invobject:HasTag("graveplanter") and "GRAVEPLANT")  )
        or nil
end

--★ DEPLOY.theme_music_fn —— 只有「部署农田作物」才播 farming。
ACTIONS.DEPLOY.theme_music_fn = function(act)
    return act.invobject ~= nil
        and act.invobject:HasTag("deployedfarmplant") and "farming"
		or nil
end

--★★ T12 同构模板的样板句：`ACTIONS.X.fn = ACTIONS.Y.fn`。
--   ★ 同一行的 stroverridefn（1663 行）引用 ACTIONS.DEPLOY.strfn(act)，
--   ★★ 于是 TILEARRIVE 的 UI 是「DEPLOY 的大类词 + 小类修饰」两层结构。
--     而 1668 行的 DEPLOY_FLOATING 用了完全相同的写法。
ACTIONS.DEPLOY_TILEARRIVE.fn = ACTIONS.DEPLOY.fn
ACTIONS.DEPLOY_TILEARRIVE.stroverridefn = function(act)
    return STRINGS.ACTIONS.DEPLOY[ACTIONS.DEPLOY.strfn(act) or "GENERIC"]
end

ACTIONS.DEPLOY_FLOATING.fn = ACTIONS.DEPLOY.fn
ACTIONS.DEPLOY_FLOATING.stroverridefn = function(act)
	return STRINGS.ACTIONS.DEPLOY[ACTIONS.DEPLOY.strfn(act) or "GENERIC"]
end

--★ T12 变体：只借用 strfn，不共用 fn（因为本动作没有 fn）。
--   ★★ 复用 UI 字符串而不复用逻辑 —— 这是最轻量的 T12。
ACTIONS.TOGGLE_DEPLOY_MODE.strfn = ACTIONS.DEPLOY.strfn

--★ SUMMONGUARDIAN.fn —— 两行转发。distance=5 但无 canforce。
ACTIONS.SUMMONGUARDIAN.fn = function(act)
    if act.doer and act.target and act.target.components.guardian then
        act.target.components.guardian:Call()
    end
end

--★ CHECKTRAP.fn —— T1 模板。
ACTIONS.CHECKTRAP.fn = function(act)
    if act.target.components.trap then
        act.target.components.trap:Harvest(act.doer)
        return true
    end
end

--★★★【DoToolWork —— 全文件最重要的局部函数（46 行）】
--   ★★ 它是 CHOP / MINE / HAMMER / DIG 四个动作的**共同实现**，
--     也是整个游戏「干活」系统的唯一入口。
--   ★★★ 它的五步流程：
--     ① 1688-1692  四条件准入（workable 组件 + 可干 + workaction 匹配 +
--                    工具未被 restricted）
--     ② 1693-1695  ITEMMIMIC 反伪装守卫（T3 模板）
--     ③ 1697-1711  计算 numworks（本次敲多少工作量）
--     ④ 1713-1725  反弹处理（ShouldRecoil / ResolveSpecialWorkAmount）
--     ⑤ 1728       执行 WorkedBy_Internal
--   ★★ 签名带 `workaction` 参数而不是读 act.action ——
--     ★★★ 这是关键设计：四个动作共用一个函数，靠参数区分。
--       于是「斧头砍树」与「锄头挖地」的代码 100% 相同，
--       只有传入的 ACTIONS.CHOP / ACTIONS.DIG 不同。
local function DoToolWork(act, workaction)
--★★ 四条件准入与 ValidToolWork（1734 行）完全相同。
--   ★★★ 这是一处**有意的重复**而不是疏忽：
--     ValidToolWork 是 validfn 用的纯条件函数，
--     DoToolWork 要在通过之后再做事，不能直接调它。
--     ★ 四个条件被复制了两份（1688-1692 与 1736-1739）。
--   ★⚠ 隐患：若将来往 ValidToolWork 加一个条件（如「目标未冻结」），
--     忘记同步 DoToolWork 就会导致「UI 说能做但执行时不做」。
--     ★ 这是典型的「判断逻辑双写」缺陷类型。记为 L 类隐患。
    if act.target.components.workable ~= nil and
        act.target.components.workable:CanBeWorked() and
        act.target.components.workable:GetWorkAction() == workaction and
--★ 第四个条件：工具不被 restricted（如韦伯被限制的装备）。
--   ★★ 1691 行用了三个 or 把「invobject 为 nil」「doer 为 nil」
--     「equippable 为 nil」都当作「不限制」。
--     ★ 写法冗长但语义正确。
        (act.invobject == nil or act.doer == nil or act.invobject.components.equippable == nil or not act.invobject.components.equippable:IsRestricted(act.doer))
    then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

--★★★【numworks 的计算 —— 决定「敲一下能刮掉多少」。】
--   ★★★ 两个乘数：
--     ① 工具/角色的「效率」（1698-1706）：
--       优先用 invobject.components.tool:GetEffectiveness(workaction)
--       其次用 doer.components.worker:GetEffectiveness（空手时的角色能力）
--       都拿不到就用 1（普通敲击）
--       ★★★ 注意是 or 链，不是乘积：
--         「拿着斧头」与「韦伯天生强」不是叠加，是**取更高的**。
--         ★ 这是一个设计决策：工具效率已经包含了角色加成。
--     ② 通用乘数 workmultiplier（1708-1711）：
--       `doer.components.workmultiplier:GetMultiplier(workaction)`
--       ★ 这是**真正的乘积**，与上面的 or 链不同。
--       ★★★ 所以有两层机制：
--         · tool/worker 的 effectiveness —— 「用什么敲」
--         · workmultiplier —— 「角色对这类工作的全局加成」（如火油助燃）
--       ★ 两者相乘（1707 行）得到最终 numworks。
		local numworks =
--★★ 1700 行 `tool:GetEffectiveness(workaction)` 传的是 workaction。
--   ★★ 同一个工具对不同工作有不同效率（斧头砍树 1，斧头挖矿 0.5）。
--     所以 workaction 参数必须一路传到底。
			(	(	act.invobject ~= nil and
					act.invobject.components.tool ~= nil and
					act.invobject.components.tool:GetEffectiveness(workaction)
				) or
--★ 空手时的角色能力分支（韦伯的无工具修理等）。
				(	act.doer ~= nil and
					act.doer.components.worker ~= nil and
					act.doer.components.worker:GetEffectiveness(workaction)
				) or
				1
--★ 第一个乘数结束，开始第二个乘数。
			) *
			(	act.doer.components.workmultiplier ~= nil and
				act.doer.components.workmultiplier:GetMultiplier(workaction) or
				1
			)

--★★★【反弹（recoil）机制 —— 工具太弱时敲不动】】
--   ★★ 1714 行 `recoil, numworks = ShouldRecoil(doer, invobject, numworks)`
--     —— ★★★ 注意这是**覆盖**了 numworks，不是叠加。
--     ShouldRecoil（workable.lua:189）在工具太弱时返回 (true, 0)，
--     即「反弹且本次工作量归零」。
--   ★★ 1720-1725 行的处理：
--     ① 先推 recoil_off 事件（播放反弹动画）
--     ② 若 numworks 变 0，推 tooltooweak 事件（播「工具太弱」语音）
--   ★★★ 注意这里用 PushEventImmediate 而不是 PushEvent：
--     ★ 立即事件会**跳过事件队列**立刻触发。
--     ★ 为什么？反弹动画必须立刻开始，不能被前面的事件延迟。
--     ★★ 这是本文件里唯一用 PushEventImmediate 的地方（除了 1721）。
		local recoil
		recoil, numworks = act.target.components.workable:ShouldRecoil(act.doer, act.invobject, numworks)

		if act.doer.components.workmultiplier ~= nil then
			numworks = act.doer.components.workmultiplier:ResolveSpecialWorkAmount(workaction, act.target, act.invobject, numworks, recoil)
		end

--★★ `act.doer.sg.statemem.recoilstate ~= nil` —— 只有存在 recoil 状态时处理。
--   ★★ 这说明「反弹动画」由 SG 侧的 recoilstate 负责，
--     而工作系统只负责「推送事件」。
--     ★ 分层很清晰：工作系统不碰动画。
		if recoil and act.doer.sg ~= nil and act.doer.sg.statemem.recoilstate ~= nil then
            act.doer:PushEventImmediate("recoil_off", { target = act.target } )
			if numworks == 0 then
				act.doer:PushEvent("tooltooweak", { workaction = workaction })
			end
		end
--★★ 保留的英文注释解释了为什么调 Internal 版本：
--   「调用『internal』函数因为我们已经算过反弹了。
--     选『internal』这个名字就是为了阻止更多地方直接调用它。」
--   ★★★ 这是极好的工程注释范式：
--     · 解释「为什么用这个版本」（因为外部已处理反弹）
--     · 解释「为什么起这个名字」（为了警示后来者）
--   ★ WorkedBy（公开版，workable.lua:123）内部会自己再算一次反弹，
--     重复计算会让「先反弹后干活」的顺序错乱。
		--V2C: Call the "internal" function directly since we've already accounted for recoil.
		--     Chose the "internal" naming to discourage more places from calling it directly.
		act.target.components.workable:WorkedBy_Internal(act.doer, numworks)
--★ return true —— 只要进了 if 就报告成功。
--   ★★ 与 1731 行的 `return false` 对照：
--     进 if ⇒ 成功；没进 if ⇒ 返回 false（但不返回 reason）。
--     ★ 这就是 §0 里 T2 模板的「弱化版」。
        return true
--★ 1731 行的 return false —— 没进 if 时。
--   ★★★ 但注意这里返回的是**纯 false**，没有 reason。
--     而 CHOP.fn（1742 行）会把这个结果转成 `false, work_fail_reason`。
--     ★★★ 关键点：DoToolWork 的两个返回值分别是 (success, reason)，
--       而 1731 行的 return false 只给了一个值 ⇒ reason 为 nil。
--       ⇒ 所以 CHOP 里 `not work_success and work_fail_reason ~= nil`
--         在「目标不可干」时为假 ⇒ 走 else 分支 return **true**！
--   ★★★ 这是一个真实的逻辑后果，值得仔细看 p4 的 CHOP 分析。
    end
    return false
end

--★★ ValidToolWork —— 纯条件版本，供 validfn 使用。
--   ★★ 四个动作的 validfn 都只调它一行：
--     CHOP.validfn  = function(act) return ValidToolWork(act, ACTIONS.CHOP) end
--     MINE.validfn  = 同上（MINE）
--     HAMMER.validfn= 同上（HAMMER）
--     DIG.validfn   = 同上（DIG）
--   ★★ 「四行一模一样的函数」是本文件的典型风格：
--     显式重复优于抽象，因为每个动作以后都可能单独加条件。
local function ValidToolWork(act, workaction)
    return
        act.target.components.workable ~= nil and
        act.target.components.workable:CanBeWorked() and
        act.target.components.workable:GetWorkAction() == workaction and
        (act.invobject == nil or act.doer == nil or act.invobject.components.equippable == nil or not act.invobject.components.equippable:IsRestricted(act.doer))
end

--★★★【CHOP.fn —— 「工具工作」动作的统一外壳（14 行）】
--   ★★ 四个动作的 fn 都是这个形状，只有额外的一句不同：
--     CHOP   : DoToolWork + spooked:Spook(target)（1744-1749）
--     MINE   : DoToolWork（1761）
--     HAMMER : DoToolWork（1774）
--     DIG    : DoToolWork（1787）
--   ★★★ 只有 CHOP 有额外逻辑 —— 砍树会惊动树上的乌鸦（spooked 组件）。
--   ★★ 1743-1754 行的返回值逻辑值得逐字读（★ 重要）：
--       local ok, reason = DoToolWork(act, ACTIONS.CHOP)
--       if ok and doer.spooked and target:IsValid() then Spook(target) end
--       if not ok and reason ~= nil then return false, reason
--       else return true end
--   ★★★ 推理：因为 DoToolWork 在 1731 行只 `return false`（reason 为 nil），
--     所以「目标不可干」这条路径上 ok=false, reason=nil
--     ⇒ `not ok and reason ~= nil` 为 **false** ⇒ 走 else ⇒ **return true**。
--   ★★ 也就是说：对着一个不能砍的东西「砍」，动作报告**成功**。
--     之所以无害，是因为 DoToolWork 什么都没做。
--   ★★★ 这正是「静默失败」模式的一种变体：
--     §0 第 8 条列的静默失败是「条件不满足但 return true」，
--     这里是通过返回值组合「间接」达到同样效果。
--   ★ 只有 ITEMMIMIC（1694 行）与 recoil（1720 行）会给出真实 reason，
--     那两条路径才会真的返回 false。
--   ★ 记录为 L9：一个刻意的、但极度隐晦的「静默失败」实现。
ACTIONS.CHOP.fn = function(act)
    local work_success, work_fail_reason = DoToolWork(act, ACTIONS.CHOP)
    if work_success and
            act.doer ~= nil and
            act.doer.components.spooked ~= nil and
            act.target:IsValid() then
        act.doer.components.spooked:Spook(act.target)
    end
--★ 只有有 reason 时才真失败。reason 只有两个来源（见上）。
    if not work_success and work_fail_reason ~= nil then
        return false, work_fail_reason
    else
        return true
    end
end

--★★ CHOP.validfn —— validfn 的语义要点。
--   ★★★ validfn 在哪里被调用？bufferedaction.lua:46：
--       (not TheWorld.ismastersim or
--         (self.action.validfn == nil or self.action.validfn(self)))
--   ★★★ 这行代码的含义（★ 极易误读）：
--     · 客户端（not ismastersim 为真）⇒ 整个子句短路，**validfn 根本不调用**
--     · 服务端 ⇒ 调用 validfn
--   ★★ 所以 validfn 是**只在服务端执行**的持续有效性检查。
--     它在 locomotor.lua:1452 每帧被间接调用（`not bufferedaction:IsValid()`）。
--   ★ 用途：目标在「走过去」的过程中变得不能砍了 → 中断动作。
--     ★★ 这就是 CHOP 声明 invalid_hold_action 之外的第二道保险。
ACTIONS.CHOP.validfn = function(act)
    return ValidToolWork(act, ACTIONS.CHOP)
end

--★ MINE.fn —— 与 CHOP 完全相同，只少了 spooked 那一段。
--   ★★ 结构对称到可以直接 diff 出 4 行差异。
ACTIONS.MINE.fn = function(act)
    local work_success, work_fail_reason = DoToolWork(act, ACTIONS.MINE)
    if not work_success and work_fail_reason ~= nil then
        return false, work_fail_reason
    else
        return true
    end
end

--★ MINE.validfn —— ValidToolWork(act, ACTIONS.MINE)。
ACTIONS.MINE.validfn = function(act)
    return ValidToolWork(act, ACTIONS.MINE)
end

--★ HAMMER.fn —— 第三个同构实现。
ACTIONS.HAMMER.fn = function(act)
    local work_success, work_fail_reason = DoToolWork(act, ACTIONS.HAMMER)
    if not work_success and work_fail_reason ~= nil then
        return false, work_fail_reason
    else
        return true
    end
end

--★ HAMMER.validfn —— ValidToolWork(act, ACTIONS.HAMMER)。
ACTIONS.HAMMER.validfn = function(act)
    return ValidToolWork(act, ACTIONS.HAMMER)
end

--★ DIG.fn —— 第四个同构实现。
ACTIONS.DIG.fn = function(act)
    local work_success, work_fail_reason = DoToolWork(act, ACTIONS.DIG)
    if not work_success and work_fail_reason ~= nil then
        return false, work_fail_reason
    else
        return true
    end
end

--★ DIG.validfn —— ValidToolWork(act, ACTIONS.DIG)。
ACTIONS.DIG.validfn = function(act)
    return ValidToolWork(act, ACTIONS.DIG)
end

--★ DIG.theme_music_fn —— 清理农田残骸/作物时播 farming。
--   ★★ 只有 DIG 有 theme_music_fn 而 CHOP/MINE 没有 ——
--     因为「清作物残骸」与「耕种」在玩家感知上是同一件事。
ACTIONS.DIG.theme_music_fn = function(act)
    return act.target ~= nil
        and (act.target:HasTag("farm_debris") or act.target:HasTag("farm_plant")) and "farming"
		or nil
end

--★★ FERTILIZE.fn —— 「施肥」的四目标分支 + 一个自我分支。
--   ★★ 1809 行的前置排除：`rider:IsRiding()` 时不施肥。
--     ★★ 为什么？骑着牛时点击会把肥料给坐骑？
--       更可能：设计上不允许「骑马施肥」，所以静默跳过。
--     ★ 注意这里是「跳过」而不是「return false」，所以动作会 return false
--       （因为 applied 保持 nil），行为上是静默失败。
ACTIONS.FERTILIZE.fn = function(act)
    if act.invobject ~= nil and act.invobject.components.fertilizer ~= nil then
		local applied = false
        if not (act.doer ~= nil and act.doer.components.rider ~= nil and act.doer.components.rider:IsRiding()) then
            if act.target ~= nil then
--★ 作物未成熟或非枯萎才可施肥。与 2611 行的 PLANT 检查对称。
            if act.target.components.crop ~= nil and not (act.target.components.crop:IsReadyForHarvest() or act.target:HasTag("withered")) then
                    applied = act.target.components.crop:Fertilize(act.invobject, act.doer)
            elseif act.target.components.grower ~= nil and act.target.components.grower:IsEmpty() then
                    applied = act.target.components.grower:Fertilize(act.invobject, act.doer)
            elseif act.target.components.pickable ~= nil and act.target.components.pickable:CanBeFertilized() then
                    applied = act.target.components.pickable:Fertilize(act.invobject, act.doer)
--★ CHEVO_fertilized 事件 —— 一个成就相关的世界事件。
--   ★★ 只在 pickable 分支推（1815 行），其他分支不推。
--     ⇒ 成就在「给野花施肥」时触发，「给农田施肥」时不触发。
--     ★ 这是有意还是遗漏？不确定，记为可疑但非缺陷。
                    TheWorld:PushEvent("CHEVO_fertilized", {target = act.target, doer = act.doer})
            elseif act.target.components.quagmire_fertilizable ~= nil then
                    applied = act.target.components.quagmire_fertilizable:Fertilize(act.invobject, act.doer)
            end
        end
        end
--★★ 1823-1828：「没有目标或目标是自己的时候，可以给自己施肥」。
--   ★★ 条件 `act.target == nil or act.doer == act.target`：
--     没有目标（点在空气）⇒ 给自己（顾自己的皮肤）
--     目标是自己的背包 ⇒ 给自己
--   ★★★ 这是「同一动作的第二用途」，与 FEED 的 T7 模板同源。
--   ★ 1826 行被注释掉的旧实现 `fertilizer:Heal(doer)` ——
--     保留了「曾经是直接回血」的历史信息。
        if not applied and act.doer ~= nil and (act.target == nil or act.doer == act.target) then
			if act.doer.components.fertilizable ~= nil then
				applied = act.doer.components.fertilizable:Fertilize(act.invobject)
				--applied = act.invobject.components.fertilizer:Heal(act.doer)
			end
        end

		if applied then
			act.invobject.components.fertilizer:OnApplied(act.doer, act.target)
    end

		return applied
    end
end

--★★ SMOTHER.fn —— 「闷火」。判定极简：只要目标在冒烟。
--   ★★ 1840 行 `act.invobject or act.doer` —— T7 模板的又一次使用。
--     「用手闷」与「用物品闷」都是同一个动作。
ACTIONS.SMOTHER.fn = function(act)
    if act.target.components.burnable and act.target.components.burnable:IsSmoldering() then
        local smotherer = act.invobject or act.doer
        act.target.components.burnable:SmotherSmolder(smotherer)
        return true
    end
end

--★ MANUALEXTINGUISH.fn —— 「用冰灭火」需要 frozen 标签 + 目标在烧。
--   ★★ 1848 行传 `TUNING.SMOTHERER_EXTINGUISH_HEAT_PERCENT` ——
--     灭火时保留一部分热量（防止「一桶水浇灭整片森林」）。
--     ★ 与 1838 行的 SmotherSmolder 是两套不同的灭火逻辑。
ACTIONS.MANUALEXTINGUISH.fn = function(act)
    if act.invobject:HasTag("frozen") and act.target.components.burnable and act.target.components.burnable:IsBurning() then
        act.target.components.burnable:Extinguish(true, TUNING.SMOTHERER_EXTINGUISH_HEAT_PERCENT, act.invobject)
        return true
    end
end

--★★★ NET.fn —— 「网捕」是自己写的一套，不走 DoToolWork。
--   ★★ 理由：网不需要「工具效率」，只需要「能不能抓」。
--     ★★ 所以它自己检查 workable:GetWorkAction() == ACTIONS.NET（1857 行），
--       绕开了 DoToolWork。
--   ★★ 1858 行多了 DoToolWork 没有的检查：`not (health and IsDead())`
--     —— 已死的生物不该被网捕（要剥皮）。
--   ★★ 1864 行直接调 `WorkedBy(act.doer)`（**公开版**，无 numworks）。
--     与 DoToolWork 用 WorkedBy_Internal 不同 ⇒ 会自己再算反弹。
--     ★ 说明网捕不需要精细的工作量控制。
--   ★★ 1866-1868 行：nabbag 组件要把网捕结果复制给自己
--     （网袋功能）。这是模组/装备扩展点。
ACTIONS.NET.fn = function(act)
    if act.target ~= nil and
        act.target.components.workable ~= nil and
        act.target.components.workable:CanBeWorked() and
        act.target.components.workable:GetWorkAction() == ACTIONS.NET and
        not (act.target.components.health ~= nil and act.target.components.health:IsDead())
    then
        if (act.invobject == nil or not act.invobject:HasTag(ACTIONS.NET.id.."_tool")) and act.target.components.grabbable ~= nil and not act.target.components.grabbable:CanGrab(act.doer) then
            return false
        end

        act.target.components.workable:WorkedBy(act.doer)

        if act.invobject and act.invobject:IsValid() and act.invobject.components.nabbag then
            act.invobject.components.nabbag:ReplicateNetFromAct(act)
        end
--★★⚠ 疑似缺陷 L5：1871 行的无条件 `return true`。
--   ★★★ 推理依据：
--     · 1854-1859 的外层 if 不成立时（目标不是可网之物、已死、
--       没有 workable 组件等），函数会直接落到 1871 行 return true；
--     · 而 1861 行在 grabbable 检查失败时 return false。
--   ★★ 结果：**同一种「不能网」的情况，有的返回 false 有的返回 true**。
--     · grabbable 不通过 → false（玩家看到失败反馈）
--     · 目标根本不是网捕物 → true（玩家看到「成功」但什么都没发生）
--   ★★★ 与 CHOP 1742 行的分析完全同源（靠 reason 是否为 nil 区分），
--     这里是更粗糙的版本 —— 显式无条件 return true。
--   ★ 影响：对着不可网捕的生物「使用网」不会报错（这是好事，
--     避免 spam 语音），但也意味着不会出现「这里不能网」的提示。
--   ★ 结论：**刻意但粗糙**的静默失败。若要给出清晰反馈应改为返回 reason。
--     只记录不修改。
    end

    return true
end

--★ CATCH.fn —— 一行 return true（接住由捕蝇草组件自己完成）。
ACTIONS.CATCH.fn = function(act)
    return true
end

--★★ FISH_OCEAN.fn —— 永远失败并带原因 "TOODEEP"。
--   ★★★ 这是「用失败做 UI 反馈」的标准样本（§2 415 行已预告）。
--     玩家在水太深的地方点「钓鱼」，会得到「太深了」的提示。
--   ★★ 为什么不在 fn 里做位置检查再返回 false（无 reason）？
--     因为 reason 需要被翻译成语音/文字，而 TUNING 里有对应的字符串。
ACTIONS.FISH_OCEAN.fn = function(act)
	return false, "TOODEEP"
end

--★★ FISH.fn —— 淡水钓鱼。1883 行直接 `act.invobject.components.fishingrod`。
--   ★⚠ 隐患：没有 nil 检查。若 invobject 为 nil（手上有东西但不是鱼竿），
--     `act.invobject.components` 会崩。
--     ★ 实际不会触发，因为 componentactions 只在有 fishingrod 时才提供本动作。
--     ★ 属「依赖上游保证」而非「自身防御」的写法。
--   ★★★ 1885 行调 StartFishing 后无条件 return true（1887 行），
--     即「即使不是鱼竿也报告成功」。与 NET 同款静默失败。
ACTIONS.FISH.fn = function(act)
    local fishingrod = act.invobject.components.fishingrod
    if fishingrod then
        fishingrod:StartFishing(act.target, act.doer)
    end
    return true
end

--★★ REEL.fn —— 三态分派（收线 / 刺 / 取消）。
--   ★★ 1891 行的 fishingrod 直接取组件（无 nil 检查），同 1883 行。
--   ★★ 三态的顺序即优先级：有鱼 > 在咬 > 空闲。
--     ★★★ 1898 行的 else 是「什么都没有」时的 StopFishing ——
--       于是「点一下收线」在没有鱼时会变成「结束钓鱼」。
--       ★ 这是玩家最容易「手滑取消钓鱼」的原因。
--     ★ 而 strfn（1904 行）会把这种情况显示为 "CANCEL"，
--       提示了玩家这一点。strfn 与 fn 的三态是配对的。
ACTIONS.REEL.fn = function(act)
    local fishingrod = act.invobject.components.fishingrod
    if fishingrod and fishingrod:IsFishing() then
        if fishingrod:HasHookedFish() then
            fishingrod:Reel()
        elseif fishingrod:FishIsBiting() then
            fishingrod:Hook()
        else
            fishingrod:StopFishing()
        end
    end
    return true
end

--★★ REEL.strfn —— 与 fn 严格镜像的三态，且**必须用副本**。
--   ★★★ 1905 行 `act.invobject.replica.fishingrod` —— 客户端没有组件。
--     这就是「同一套逻辑写两遍」的代价（见 1402 行的对照说明）。
--   ★★ 1906 行 `fishingrod:GetTarget() == act.target` ——
--     ★★★ 只有「收的是当前目标」时才显示收线词。
--       防止玩家对着另一个东西看到「收线」的误导提示。
--   ★★ 1909 行的 `act.doer:HasTag("nibble")` 决定是 "HOOK" 还是 "CANCEL"
--     —— 「会钓鱼的特性」（韦伯的钓鱼钩）。
ACTIONS.REEL.strfn = function(act)
    local fishingrod = act.invobject.replica.fishingrod
    if fishingrod ~= nil and fishingrod:GetTarget() == act.target then
        if fishingrod:HasHookedFish() then
            return "REEL"
        elseif act.doer:HasTag("nibble") then
            return "HOOK"
        else
            return "CANCEL"
        end
    end
end

--★★ PICK.strfn —— 四个标签变体。
--   ★★ pickable_harvest_str → HARVEST / pickable_rummage_str → RUMMAGE
--     pickable_search_str   → SEARCH / gemsocket → UNSOCKET
--   ★★★ 所有标签都以 `_str` 结尾 —— 这是一个命名约定：
--     「带 _str 后缀的标签只影响 UI 显示，不影响能否执行」。
--     ★ 这样区分「能力标签」与「显示标签」，模组作者容易混淆。
ACTIONS.PICK.strfn = function(act)
    if not act.target then return nil end

	return (act.target:HasTag("pickable_harvest_str") and "HARVEST")
        or (act.target:HasTag("pickable_rummage_str") and "RUMMAGE")
        or (act.target:HasTag("pickable_search_str") and "SEARCH")
        or (act.target:HasTag("gemsocket") and "UNSOCKET")
        or nil
end

--★★ PICK.fn —— 采摘 / 搜索二分。
--   ★★ 1930-1932 行的 STUCK 检查：物品「卡住」时不能采。
--     ★★★ 这是为了防止「卡在两个碰撞体之间的物品被无限次采摘」。
--   ★ 1935 行 elseif searchable → Search：搜索（草丛、石头缝）。
--     ★ 采摘与搜索共用一个动作，靠目标组件区分。
ACTIONS.PICK.fn = function(act)
    if act.target ~= nil then
        if act.target.components.pickable ~= nil then
			if act.target.components.pickable:IsStuck() then
				return false, "STUCK"
			end
            act.target.components.pickable:Pick(act.doer)
            return true
        elseif act.target.components.searchable ~= nil then
            return act.target.components.searchable:Search(act.doer)
        end
    end
end

--★★ PICK.validfn —— 「能不能采」的纯条件版本。
--   ★★ 注意它复述了 fn 的部分条件（pickable:CanBePicked / searchable.canbesearched），
--     但**没有**复述 STUCK 检查。
--   ★⚠ 不一致：fn 会因 STUCK 失败，validfn 却认为有效。
--     后果：玩家按住采集一个卡住的物品，validfn 不报错，
--     但 fn 每次都返回 false → 语音 spam。
--     ★ 记录为 L 类隐患（与 1688/1736 的双写同类）。
ACTIONS.PICK.validfn = function(act)
    return act.target
        and (
            (act.target.components.pickable and act.target.components.pickable:CanBePicked())
            or (act.target.components.searchable and act.target.components.searchable.canbesearched)
        )
end

ACTIONS.PICK.theme_music_fn = function(act)
    return act.target ~= nil
        and act.target:HasTag("farm_plant") and "farming"
		or nil
end

--★★★ ATTACK.fn —— 「攻击」的三种特殊模式 + 通用路径。
--   ★★ 1957-1970 行：检查 sg 的三个状态标签，各走一条武器特殊路径：
--     propattack     → 道具武器，不做真实攻击，直接 return true
--     thrusting      → 多头 thrusts（StartThrusting）
--     helmsplitting  → 头盔劈砍（StartHelmSplitting）
--   ★★★ 这三个标签都是「武器正在播放某种攻击动画」的状态标记。
--     ★ 含义：本次点击不是新的一次攻击，而是「继续那套连招」。
--   ★★ 1958 行的英文注释「don't do a real attack with prop weapons」
--     说明道具武器（草叉、捕蝇草）的攻击伤害由别处处理。
--   ★★ 1973 行的英文注释「Recoil logic done in combat.lua instead of here」
--     —— 与 DoToolWork 1714 行相反：攻击的反弹逻辑在 combat.lua 里。
--     ★★ 对比很有价值：工具工作在本文件算反弹，攻击在组件里算。
--       原因是 combat 还要处理伤害、闪避、击退，反弹只是其中一环。
ACTIONS.ATTACK.fn = function(act)
    if act.doer.sg ~= nil then
        if act.doer.sg:HasStateTag("propattack") then
            --don't do a real attack with prop weapons
            return true
        elseif act.doer.sg:HasStateTag("thrusting") then
--★ thrusting 分支：要求武器有 multithruster 组件。
--   ★★★ `weapon ~= nil and weapon.components.multithruster ~= nil and`
--     整条表达式作为返回值 ⇒ 三个条件同时满足才 return true。
--     ★ 写法上把一个逻辑表达式直接当返回值，可读性偏低。
            local weapon = act.doer.components.combat:GetWeapon()
            return weapon ~= nil
                and weapon.components.multithruster ~= nil
                and weapon.components.multithruster:StartThrusting(act.doer)
        elseif act.doer.sg:HasStateTag("helmsplitting") then
            local weapon = act.doer.components.combat:GetWeapon()
            return weapon ~= nil
                and weapon.components.helmsplitter ~= nil
                and weapon.components.helmsplitter:StartHelmSplitting(act.doer)
        end
    end

    --NOTE: Recoil logic done in combat.lua instead of here
    act.doer.components.combat:DoAttack(act.target)
    return true
end

--★★ ATTACK.strfn —— 六个变体，全部是「武器改变攻击方式」。
--   ★★ 1984 行 `act.doer.replica.combat ~= nil` —— 用副本，客户端可跑。
--   ★★ 三个 combat 分支的顺序即优先级：
--     CanExtinguishTarget → RANGEDSMOTHER（远程闷火）
--     CanLightTarget      → RANGEDLIGHT（远程点火）
--     whackable + hammer  → WHACK（敲打）
--   ★★★ 前两个是「战斗组件说这个武器能点火/灭火」，
--     第三个是「目标标签 + 武器标签」的静态组合。
--   ★ 1995 行的 smashable 是目标标签（与武器无关）——
--     ★ 唯一一个只看目标的变体，放在最后作为兜底。
ACTIONS.ATTACK.strfn = function(act)
    if act.target ~= nil then
        --act.invobject is weapon
        if act.invobject ~= nil then
            if act.invobject:HasTag("propweapon") then
                return "PROP"
            elseif act.doer.replica.combat ~= nil then
                if act.doer.replica.combat:CanExtinguishTarget(act.target, act.invobject) then
                    return "RANGEDSMOTHER"
                elseif act.doer.replica.combat:CanLightTarget(act.target, act.invobject) then
                    return "RANGEDLIGHT"
                elseif act.target:HasTag("whackable") and act.invobject:HasTag("hammer") then
                    return "WHACK"
                end
            end
        end

        if act.target:HasTag("smashable") then
            return "SMASHABLE"
        end
    end
end

--★★ COOK.stroverridefn —— 用「覆盖」而非 strfn 返回 SPICE（§2 375 行已预告）。
--   ★★★ 保留的英文注释解释了动机，这是全文件最重要的一段设计说明：
--     「这样写而不是用 .strfn 加一个 "SPICE" 修饰符，是为了避免
--       破坏模组 —— 因为 containers.lua 访问 COOK 字符串的方式会出问题。」
--   ★★★ 也就是说：这不是风格偏好，而是**为了不破坏下游代码**。
--     containers.lua 里某处直接读了 STRINGS.ACTIONS.COOK 的某个子键，
--     若 COOK 的 strfn 会返回 "SPICE"，那个读取就会拿到错误值。
--   ★★ 这是「一个字段的改变会波及全仓库」的典型记录。
--     ★ 读这类注释时要记住：作者的「怪写法」往往是为了兼容某个外部依赖。
ACTIONS.COOK.stroverridefn = function(act)
    --done this way instead of using .strfn and "SPICE" modifier to try and avoid
    --breaking mods due to the way the COOK string is accessed in containers.lua.
    return act.target ~= nil and act.target:HasTag("spicer") and STRINGS.ACTIONS.SPICE or nil
end

--★★★【COOK.fn —— 94 行，三种「烹饪」的完整实现】
--   ★★ 三个主分支：
--     ① 20xx cooker 组件   → 往「灶台」里放材料（锅里煮）
--     ② 20xx stewer 组件   → 启动炖锅（自己带食材）
--     ③ 20xx cookable 组件 → 用「手持的锅具」烹饪（手持烹调）
--   ★★ 三者对应完全不同的交互模型：
--     ① 目标消耗动作，产物进背包
--     ② 目标启动长流程，之后用 HARVEST 取
--     ③ 目标（食材）被消耗，产物掉在地上
ACTIONS.COOK.fn = function(act)
--★ 第一分支：往有 cooker 的目标里放材料（营火 + 锅）。
    if act.target.components.cooker ~= nil then
        local cook_pos = act.target:GetPosition()
--★★ 2010 行先 RemoveItem（把材料从背包拿出），2016 行可能还回。
--   ★★★ 这是 T11 事务模板：先拿后试，失败还回。
--     ★★ 与 TOSS/DEPLOY 的差别：COOK 是「拿完立刻可能还回」，
--       而 DROP 是「拿完直接丢地上」（无失败路径）。
--     ★ 关键点：2016 行还回时传了 cook_pos（灶台坐标），
--       让物品从灶台飞回背包，视觉上不出戏。
        local ingredient = act.doer.components.inventory:RemoveItem(act.invobject)

--★ 保留的英文注释：位置对 "killed" 事件的监听者很重要。
--   ★★★ 为什么要把材料移动到灶台位置？
--     因为 2021 行的 murdered / 2023 行的 killed 事件会被
--     成就系统、任务系统监听，它们会记录「在哪里被烹杀了」。
--     ★ 这是一个「为了下游可观测性而做的额外操作」，很值得学。
        --V2C: position usually matters for listeners of "killed" event
        ingredient.Transform:SetPosition(cook_pos:Get())

--★★ CanCook 检查失败 → 立刻还回材料并 return false。
--   ★★★ 注意这里 return **false 但没有 reason**（2050 行的 COOL 才有）。
--     ⇒ 玩家看到「通用失败」（不能这么做），而不是具体原因。
--     ★ 推测：因为「不能这样烹饪」的原因太多，逐个给 reason 反而啰嗦。
        if not act.target.components.cooker:CanCook(ingredient, act.doer) then
            act.doer.components.inventory:GiveItem(ingredient, nil, cook_pos)
            return false
        end

--★★ 「烹杀活物」—— 烹饪一个有 health 组件的食材时触发。
--   ★★ 2021 行 `murdered` 事件（JBK 注释 "Cooking something alive."）
--     2023 行 `killed` 事件（只有有 combat 组件时才推）。
--   ★★★ 两个事件的区别很重要：
--     `murdered` —— 「被杀了」（含非战斗场合，如烹杀）
--     `killed`   —— 「在战斗中被杀」（有 combat 组件才推）
--     ★ 所以「烤兔子」会触发 murdered 但不触发 killed。
--     ⇒ 这是「同一件事用两个事件表达不同语义」的样本。
--     ★ 对比 3169-3170 行 MURDER.fn 里两个事件**都**推。
        if ingredient.components.health ~= nil then
            act.doer:PushEvent("murdered", { victim = ingredient, stackmult = 1 }) -- NOTES(JBK): Cooking something alive.
            if ingredient.components.combat ~= nil then
                act.doer:PushEvent("killed", { victim = ingredient })
            end
        end

--★ CookItem 返回产物。返回非 nil 则给玩家（2029 行），否则还回原料。
        local product = act.target.components.cooker:CookItem(ingredient, act.doer)
        if product ~= nil then
            act.doer.components.inventory:GiveItem(product, nil, cook_pos)
            return true
        elseif ingredient:IsValid() then
            act.doer.components.inventory:GiveItem(ingredient, nil, cook_pos)
        end
        return false
--★★ 第二分支：炖锅（stewer）。结构像 COOK 函数的微缩版。
--   ★★ 2036-2038：已在烹饪中 → 直接 return true（不给失败反馈）。
--     ★★★ 为什么不给失败？玩家点炖锅就是想「看看进度」，
--       看到「已在烹饪」这种提示会很烦。静默成功体验最好。
--     ★ 这是「静默失败」的轻量版：不返回 false，也不说话。
--   ★★ 2041 行：被别人打开 → INUSE
--   ★★ 2043 行：CanCook 失败 → **返回 false 无 reason**（与 2016 同）。
    elseif act.target.components.stewer ~= nil then
        if act.target.components.stewer:IsCooking() then
            --Already cooking
            return true
        end
        local container = act.target.components.container
        if container ~= nil and container:IsOpenedByOthers(act.doer) then
            return false, "INUSE"
        elseif not act.target.components.stewer:CanCook() then
            return false
        end
        act.target.components.stewer:StartCooking(act.doer)
        return true
--★★★ 第三分支：手持烹调（锅具 + 食材）。三者缺一不可。
--   ★★★ 这个分支与前两个的最大不同：**食材在目标上，锅具在手上**。
--     所以 2062 行要处理「目标是一堆，只取一个」：
--       stacked = stackable:IsStack()
--       ingredient = stacked and stackable:Get() or act.target
--     ★★★ 与 REPLATE.fn（5253 行）的写法几乎一致。
--     「从堆叠里临时抽出一个来加工，处理完再放回去」是通用模式。
--   ★★ 2065 行：抽出来的不是目标本身时要单独设置坐标
--     （理由同 2012 行：为事件监听者准备正确的位置）。
    elseif act.target.components.cookable ~= nil
        and act.invobject ~= nil
        and act.invobject.components.cooker ~= nil then

        local cook_pos = act.target:GetPosition()

--★★★ 保留的英文注释解释了为什么这里用三维距离：
--   「Intentional use of 3D dist check for birds.」
--   ★★★ 其它地方的「够不够近」几乎都用 distsq（2D，忽略高度），
--     但这一处用了 `Dist()`（3D）。
--   ★★ 原因：鸟（及其他飞行生物）可以停在**空中或高台上**，
--     玩家站在地面时 2D 距离很近但 3D 距离很远。
--     ⇒ 用 2D 会允许玩家「隔着一层楼板把鸟烤了」。
--     ★ 这是全文件里唯一一处主动选择 3D 距离的地方，注释及时指出了。
        --Intentional use of 3D dist check for birds.
        if act.doer:GetPosition():Dist(cook_pos) > 2 then
            return false, "TOOFAR"
        end

--★ owner = 食材的 GrandOwner，用于把产物送回原处。
--   ★★ 若食材在玩家的背包里，owner 就是玩家 ⇒ container 是 inventory。
--     若在地上，owner 为 nil ⇒ container 为 nil ⇒ 产物掉在地上。
--   ★ 2060 行的 `owner.components.inventory or owner.components.container`
--     ★★★ 又是「玩家 / AI」的兼容写法（§p4 1619 行同款）。
        local owner = act.target.components.inventoryitem:GetGrandOwner()
        local container = owner ~= nil and (owner.components.inventory or owner.components.container) or nil
--★ stacked 判定 —— 决定后续是「临时抽一个」还是「整个用掉」。
        local stacked = act.target.components.stackable ~= nil and act.target.components.stackable:IsStack()
        local ingredient = stacked and act.target.components.stackable:Get() or act.target

        if ingredient ~= act.target then
            --V2C: position usually matters for listeners of "killed" event
            ingredient.Transform:SetPosition(cook_pos:Get())
        end

        if not act.invobject.components.cooker:CanCook(ingredient, act.doer) then
            if container ~= nil then
                container:GiveItem(ingredient, nil, cook_pos)
--★★ 2072-2074 行的「堆叠还原」逻辑：
--     失败时把 stacksize 加回去并 Remove 掉临时抽出的那个。
--   ★★★ 注意顺序：先加回数量再 Remove。若反过来，
--     Add 会作用在一个即将消失的实体上。
--   ★★ 这个 pattern 在 2099-2101（第三分支的末尾）重复了一次。
--     两处完全相同 ⇒ 可以抽函数，但作者选择了复制。
            elseif stacked and ingredient ~= act.target then
                act.target.components.stackable:SetStackSize(act.target.components.stackable:StackSize() + 1)
                ingredient:Remove()
            end
            return false
        end

        if ingredient.components.health ~= nil and ingredient.components.combat ~= nil then
            act.doer:PushEvent("killed", { victim = ingredient })
        end

        local product = act.invobject.components.cooker:CookItem(ingredient, act.doer)
        if product ~= nil then
            if container ~= nil then
                container:GiveItem(product, nil, cook_pos)
            else
                product.Transform:SetPosition(cook_pos:Get())
--★★ 产物掉在地上时给一点物理速度（2089-2093 行）。
--   ★★★ 只有堆叠产物才有物理速度（stacked and product.Physics）。
--     为什么堆叠才有？因为堆叠产物是「从一堆里掉出来的」，
--     飞一下更自然；非堆叠的（如整只烤鸡）是直接从锅里拿出来。
--   ★ 2090-2092 行：随机角度 + 随机水平速度 + 固定向上速度（GetRandomWithVariance）。
--     ★★ 向上速度 8±4 而水平只有 0~2 —— 是为了让掉落看起来是「抛出」而非「弹出」。
--     ★ 这类手感参数通常要反复调才能定下来，能保留在代码里值得称赞。
                if stacked and product.Physics ~= nil then
                    local angle = math.random() * TWOPI
                    local speed = math.random() * 2
                    product.Physics:SetVel(speed * math.cos(angle), GetRandomWithVariance(8, 4), speed * math.sin(angle))
                end
            end
            return true
        elseif ingredient:IsValid() then
            if container ~= nil then
                container:GiveItem(ingredient, nil, cook_pos)
            elseif stacked and ingredient ~= act.target then
                act.target.components.stackable:SetStackSize(act.target.components.stackable:StackSize() + 1)
                ingredient:Remove()
            end
        end
        return false
    end
end

--★ ACTIVATE_CONTAINER.fn —— 「点容器上的按钮」范式（§2 692 行已预告）。
--   ★★ 2109 行 `if act.target.cookbuttonfn then` ——
--     ★★★ 注意是**实例字段**而不是组件方法。
--       这意味着容器自己在自己的 prefab 文件里挂一个函数。
--     ★ 与 TRAVEL 的 travel_action_fn（3699 行）完全同型。
--     ★ 这类「实体自带回调」是 DST 扩展机制里最轻量的一种。
--   ★★ 2111 行先检查 IsOpenedByOthers（别人开着）→ INUSE。
--     ★ 这是「多客户端一致性」的必要检查：不能让两人同时触发同一个按钮。
ACTIONS.ACTIVATE_CONTAINER.fn = function(act)
    if act.target.cookbuttonfn then
        local container = act.target.components.container
        if container ~= nil and container:IsOpenedByOthers(act.doer) then
            return false, "INUSE"
        else        
            act.target.cookbuttonfn(act.target)
            return true
        end
    end
end

--★★★ FILL.fn —— 「装水」的「双向对象」处理（38 行）。
--   ★★ 2121 行两个变量：source_object（水的来源）、filled_object（被装的容器）。
--   ★★ 2123-2133 的四分支：
--     target 为 nil           → 装 invobject（往手上拿的瓶子里装）
--     target 是 watersource    → 往手上的容器里装（target 装水）
--     invobject 是 watersource → 装 target（手上的东西是水）
--     都不是                   → 两者都 nil
--   ★★★ 这是「一个动作、两个对象槽、可能任意一方是源」的模式。
--     完整实现在 COOK 里也有（2059 行的 owner 双写）。
--   ★★ 2128 与 2131 的镜像结构说明作者是有意做成对称的。
ACTIONS.FILL.fn = function(act)
    local source_object, filled_object = nil, nil

    if act.target == nil then
        filled_object = act.invobject
    else
        if act.target:HasTag("watersource") then
            source_object = act.target
            filled_object = act.invobject
        elseif act.invobject:HasTag("watersource") then
            source_object = act.invobject
            filled_object = act.target
        end
    end

--★★ 2135-2142 行的两个守卫：
--   ① filled_object 为 nil → false（没有可装的东西）
--   ② 源与目标的 prefab 相同 → false
--     ★★ 第 ② 条就是「不能把水装进水瓶」的判断（2139 行）。
--       比较 prefab 字符串是最廉价可靠的类型判定。
--     ★★★ 全文都用这种 `x.prefab == y.components.X.yprefab` 的比较，
--       而不是查标签。标签系统用于「能力」，prefab 比较用于「精确类型」。
    if filled_object == nil then
        return false
    elseif source_object ~= nil
        and filled_object.components.fillable ~= nil
        and source_object.prefab == filled_object.components.fillable.filledprefab then

        return false
    end

--★★ 2144-2153：直接对着地面点（海水路径）。
--   ★★ 「从海里接水」不需要 source_object，只需要一个坐标。
--     ★ 检查 `acceptsoceanwater`（容器是否能装海水）+ IsOceanAtPoint。
--   ★ 2151 行返回 `filled_object.components.fillable.oceanwatererrorreason`
--     —— ★★★ 容器的**自定义失败原因字段**。
--     ★ 这意味着「为什么不能接海水」由容器自己决定（陶罐可以、玻璃瓶不行…）。
--       很好的扩展设计。
    local groundpt = act:GetActionPoint()
    if groundpt ~= nil then
        local success = filled_object.components.fillable.acceptsoceanwater and TheWorld.Map:IsOceanAtPoint(groundpt.x, 0, groundpt.z)
        if success then
            filled_object.components.fillable:Fill()
            return true
        else
            return false, filled_object.components.fillable.oceanwatererrorreason
        end
    end

    return source_object ~= nil
        and source_object:HasTag("watersource")
        and filled_object.components.fillable:Fill(source_object)
end

--★ FILL_OCEAN.fn = FILL.fn —— T12 同构模板（§2 377 行已预告）。
ACTIONS.FILL_OCEAN.fn = ACTIONS.FILL.fn
--★ FILL_OCEAN.stroverridefn —— 强制显示 "FILL" 串（不加任何后缀）。
--   ★★ 为什么用 stroverridefn 而不是 strfn？
--     因为 strfn 返回的字符串会被拼成 "FILL <目标名>"，
--     而「从海里装水」应该显示为「装水」。
--     ★ 与 TELLSTORY（1574 行）同款理由：需要一个「干净的词」。
ACTIONS.FILL_OCEAN.stroverridefn = function(act)
    return STRINGS.ACTIONS.FILL
end

--★★ DRY.fn —— 「晾干」的 T11 事务模板（16 行）。
--   ★★ 与 COOK 的结构完全一致：CanDry → RemoveItem → StartDrying
--     → 失败还回。
--   ★ 2172 行的 `not StartDrying(...)` 为真时还回 —— 
--     ★★ 注意这里用 `not` 而非 `== false`，
--       所以 StartDrying 返回 nil 也会走还回路径（更安全）。
ACTIONS.DRY.fn = function(act)
    if act.target.components.dryer then
        if not act.target.components.dryer:CanDry(act.invobject) then
            return false
        end

        local ingredient = act.doer.components.inventory:RemoveItem(act.invobject)
        if not act.target.components.dryer:StartDrying(ingredient) then
            act.doer.components.inventory:GiveItem(ingredient, nil, act.target:GetPosition())
            return false
        else
--★ CHEVO_starteddrying 事件 —— 与 1817 行的 CHEVO_fertilized 同族。
--   ★★ 这两个事件都是成就钩子，且都是**推给 TheWorld** 而非 doer。
--     ⇒ 成就在服务端订阅世界事件，客户端不需要感知。
            TheWorld:PushEvent("CHEVO_starteddrying",{target=act.target,doer=act.doer})
        end
        return true
    end
end

--★★ ADDFUEL.fn —— 「加燃料」含一个 stackable 回填技巧（25 行）。
--   ★★ 结构：
--     ① 2183-2200 玩家有 inventory：RemoveItem → TakeFuelItem → 失败还回
--     ② 2201-2205 无 inventory（AI）：调 TakeFuelItem(nil, doer)
--   ★★★ 2190-2196 是一个精细的「部分消费」处理：
--     若燃料被部分取走（invobject ~= fuel，说明堆叠里还有剩余），
--     且手上拿的正是那堆，且没满，则把取出的那部分 Put 回去。
--     ★★★ 换言之：「点火失败时把燃料还回玩家手上的那堆里」。
--     ★ 这是 stackable 的「拆一个出来用，用不掉就放回去」模式，
--       与 REPLATE（5262 行）的处理同源。
ACTIONS.ADDFUEL.fn = function(act)
    if act.doer.components.inventory and act.invobject then
        local fuel = act.doer.components.inventory:RemoveItem(act.invobject)
        if fuel then
            if act.target.components.fueled and act.target.components.fueled:TakeFuelItem(fuel, act.doer) then
                return true
            end
--★ 2189 行被注释掉的 print("False") —— 调试遗留（L11）。
--   ★★ 作者在关键分支留过调试打印，后来去掉了但忘了删注释行。
--     ★ 无害，但说明这段代码被调试过 —— 「加燃料失败」曾是问题区域。
			--print("False")
			if act.invobject ~= fuel and
				act.invobject == act.doer.components.inventory:GetActiveItem() and
				act.invobject.components.stackable and
				not act.invobject.components.stackable:IsFull()
			then
				fuel = act.invobject.components.stackable:Put(fuel)
			end
			if fuel then
				act.doer.components.inventory:GiveItem(fuel)
			end
        end
	elseif act.doer.components.fueler then
        if act.target.components.fueled and act.target.components.fueled:TakeFuelItem(nil, act.doer) then
            return true
		end
    end
end
--★ ADDWETFUEL.fn = ADDFUEL.fn —— T12 同构模板（§2 380 行）。
ACTIONS.ADDWETFUEL.fn = ACTIONS.ADDFUEL.fn

--★ GIVE.strfn —— 四个 NPC 类标签变体（SOCKET/SHOW/REPAIR/CELESTIAL）。
ACTIONS.GIVE.strfn = function(act)
    return act.target ~= nil
        and ((act.target:HasTag("gemsocket") and "SOCKET") or
            (act.target:HasTag("trader_just_show") and "SHOW")or
			(act.target:HasTag("trader_repair") and "REPAIR") or
            (act.target:HasTag("moontrader") and "CELESTIAL"))
        or nil
end

--★★★ GIVE.stroverridefn —— 「给」这个词的四种完整改写（33 行）。
--   ★★ 四个分支：
--     ① ghostlyelixirable + ghostlyelixir → "把{物品}涂在…"
--     ② 冬宴桌 / 展示架 / 家具装饰架 → "放置{物品}"
--     ③ nameoverride + quagmire_stewer    → 按菜系查表
--     ④ quagmire_altar                    → 献祭（按食物查特定词）
--   ★★★ 分支 ③/④ 用 `prefab:sub(1, 14)` 做字符串切片来推断菜系：
--     2234 行 `act.invobject.prefab:sub(1, 14) == "quagmire_food_"`
--     ★★ 「quagmire_food_」正好 14 个字符。
--     ★★★ 这是**用 prefab 命名规范反推元数据**的做法 ——
--       不查表，直接从名字猜。灵活但脆弱（改名即失效）。
--     ★ 2237 行的 `find("_", 15)` 是找第 15 个字符之后的下划线，
--       用来切出菜系名（如 quagmire_food_mushroom_dish → MUSHROOM）。
--       ★★ find 找不到时返回 nil，而 Lua 里 `string:find` 返回 nil, nil，
--         代码检查 `if i ~= nil` 是正确的。
ACTIONS.GIVE.stroverridefn = function(act)
    --Quagmire & Winter's Feast action strings
    if act.target ~= nil and act.invobject ~= nil then
		if act.target:HasTag("ghostlyelixirable") and act.invobject:HasTag("ghostlyelixir") then
			return subfmt(STRINGS.ACTIONS.GIVE.APPLY, { item = act.invobject:GetBasicDisplayName() })
		elseif act.target:HasAnyTag(
				"wintersfeasttable",
				"inventoryitemholder_give",
				"furnituredecortaker")
		then
			return subfmt(STRINGS.ACTIONS.GIVE.PLACE_ITEM, { item = act.invobject:GetBasicDisplayName() })
--★ nameoverride —— 实体自定义的名字覆盖字段（自定义拼法）。
--   ★★ 用 `string.upper(nameoverride)` 去 STRINGS 里查 ——
--     说明 nameoverride 存的是小写的显示名，STRINGS 里是大写键。
        elseif act.target.nameoverride ~= nil and act.invobject:HasTag("quagmire_stewer") then
            return subfmt(STRINGS.ACTIONS.GIVE[string.upper(act.target.nameoverride)], { item = act.invobject:GetBasicDisplayName() })
        elseif act.target:HasTag("quagmire_altar") then
            if act.invobject.prefab == "quagmire_portal_key" then
                return STRINGS.ACTIONS.GIVE.SOCKET
            elseif act.invobject.prefab:sub(1, 14) == "quagmire_food_" then
                local dish = act.invobject.basedish
                if dish == nil then
                    local i = act.invobject.prefab:find("_", 15)
                    if i ~= nil then
                        dish = STRINGS.NAMES[string.upper(act.invobject.prefab:sub(1, i - 1))]
                    end
                end
                local str = dish ~= nil and STRINGS.ACTIONS.GIVE.QUAGMIRE_ALTAR[string.upper(dish)] or nil
                if str ~= nil then
                    return subfmt(str, { food = act.invobject:GetBasicDisplayName() })
                end
            end
            return subfmt(STRINGS.ACTIONS.GIVE.QUAGMIRE_ALTAR.GENERIC, { food = act.invobject:GetBasicDisplayName() })
        end
    end
end

--★★【ShouldBlockGiving —— 「这东西不能给出去」的统一规则（24 行）】
--   ★★★ 两条规则（都是「只能放进口袋」类物品）：
--     ① CanOnlyGoInPocket() → 一律禁止给予
--     ② CanOnlyGoInPocketOrPocketContainers() → 除非目标是「自己的口袋」
--   ★★★ 这是 DST 的「物品归属」系统：某些物品（任务物品、誓约物品）
--     只能待在玩家的口袋里，不能进箱子、不能给别人。
--   ★★ 2253 行用 `replica.inventoryitem` —— 必须能在客户端读，
--     因为它被 GIVE.fn、GIVETOPLAYER.fn、GIVEALLTOPLAYER.fn 三处共用。
--   ★★★ 三处共用一个守卫函数是本文件里少见的「提取公共判定」，
--     说明这个规则**足够重要**到不能复制三份。
local function ShouldBlockGiving(act)
    local inventoryitem = act.invobject.replica.inventoryitem
    if not inventoryitem then
        return false
    end

    if inventoryitem:CanOnlyGoInPocket() then
        return true
    end

--★ 第二条规则的例外逻辑（2263-2271 行），三层嵌套：
--   ① 目标自己也是只能进口袋的物品
--   ② 且目标的容器可以打开
--   ③ 且这个物品的最终持有者是自己 → 允许
--   ★★★ 语义：「任务物品可以给另一个任务物品，但只能在你自己的袋子里」。
--     ★ 注意 2266 行的 IsGrandOwner(act.doer) 用的是**递归**持有者，
--       所以「在你自己背包里的另一个背包里的任务物品」也算。
    if inventoryitem:CanOnlyGoInPocketOrPocketContainers() then
        if act.target and act.target.replica.inventoryitem and act.target.replica.inventoryitem:CanOnlyGoInPocket() then
            if act.target.replica.container and act.target.replica.container:CanBeOpened() or
                act.target.replica.container_proxy and act.target.replica.container_proxy:CanBeOpened() then
                if inventoryitem:IsGrandOwner(act.doer) then
                    return false
                end
            end
        end
        return true
    end

    return false
end

--★★ GIVE.fn —— 「一个动作服务 7 类接收方」的最大样本（62 行）。
--   ★★ 七个 elseif 分支（按优先级）：
--     ① playbill_lecturn + playbill  → 换戏单
--     ② ghostlyelixirable + ghostlyelixir → 涂灵药
--     ③ trader  → 商人（可给堆叠）
--     ④ moontrader → 月亮商人
--     ⑤ furnituredecortaker → 家具装饰
--     ⑥ inventoryitemholder → 通用物品架
--     ⑦ quagmire_cookwaretrader → Quagmire 厨具商
--     ⑧ quagmire_altar → 献祭
--   ★★★ 注意每个分支的「判定方式」不同：
--     有的查标签（①），有的查组件（②③④⑤⑥⑦⑧）。
--     ★ ①用标签是因为 playbill_lecturn 只是个容器，功能在手里的戏单上。
--   ★★ 全文件没有第二个动作有这么多分支 ⇒ 「给东西」是 DST 最复杂
--     的交互类型，因为它要兼容所有 NPC。
ACTIONS.GIVE.fn = function(act)
    if ShouldBlockGiving(act) then
        return false
    end

    if act.target ~= nil then
--★ 分支①：换戏单（戏园看板）。标签 + 组件双重判定。
        if act.target:HasTag("playbill_lecturn") and act.invobject.components.playbill then
            act.target.components.playbill_lecturn:SwapPlayBill(act.invobject, act.doer)
            return true

        elseif act.target.components.ghostlyelixirable ~= nil and act.invobject.components.ghostlyelixir ~= nil then
            return act.invobject.components.ghostlyelixir:Apply(act.doer, act.target)

--★★ 分支③：商人。20 行的「可堆叠给予」逻辑，是全文件最精细的 NPC 交易。
--   ★★ 2293-2306 行计算「给多少个」：
--     · 商人支持堆叠 → 问 CanAcceptCount（还能收几个）
--     · 物品本身可堆叠 → 用当前堆叠数
--     · 都拿不到 → 1
--     ★★★ 三级回退。②③ 其实是**上限与需求的交集**问题。
--   ★★ 2303 行 `count <= 0 then return false` ——
--     ★ 静默失败，无 reason。与 WEIGH_ITEM.fn（4674 行）同款。
--     ★ 而 GiveItem 这类操作给不出有意义的 reason（「背包满了」太笼统）。
        elseif act.target.components.trader ~= nil then
            local count

            if act.target.components.trader:IsAcceptingStacks() then
                count = (
                    act.target.components.inventory ~= nil and
                    act.target.components.inventory:CanAcceptCount(act.invobject)
                ) or (
                    act.invobject.components.stackable ~= nil and
                    act.invobject.components.stackable.stacksize
                )
                or 1

                if count <= 0 then
                    return false
                end
            end

--★ AbleToAccept 返回 (bool, reason)，reason 直接透传给玩家。
--   ★★★ 透传失败原因是本文件的通例：
--     §0 第 7 条「失败原因字符串是动作契约的一部分」。
            local able, reason = act.target.components.trader:AbleToAccept(act.invobject, act.doer, count)
            if not able then
--★★ GIVE.fn 的分支③（商人）内部：2290-2315。
--   ★★ 2308 行是本分支的关键一行：`AbleToAccept(invobject, doer, count)`。
--   ★★★ 注意它传了**三个**参数（含 count），而 GIVETOPLAYER（2352）
--     与 FEED（3763）都只传两个 ——
--       ★ 「支持堆叠的商人」需要知道打算给多少。
--       ★⇒ AbleToAccept 的第三参是可选的，缺省时视为 1。
                return false, reason
            end

--★★ GIVE.fn 的分支③（商人）在 2313-2315 结束，
--   ★★ 接下来 2317-2336 是另外四个分支（每个都很短）。
--   ★★★ 四个分支的共同形状：
--     if target.components.X ~= nil then return X:Y(...) end
--   ★★ 这就是 §0 T1 模板的最纯粹形态 —— 一行 if、一行 return。
--   ★★ 分支④（moontrader）2317-2319
--   ★★ 分支⑤（furnituredecortaker）2320-2326：
--     唯一做了「AbleToAccept 预检」的分支（2321 行）。
--   ★★ 分支⑥（inventoryitemholder）2328-2329：一行转发
--   ★★ 分支⑦⑧（quagmire 两个）2331-2336：各一行转发
            act.target.components.trader:AcceptGift(act.doer, act.invobject, count)

            return true

        elseif act.target.components.moontrader ~= nil then
            return act.target.components.moontrader:AcceptOffering(act.doer, act.invobject)

--★ 分支⑤（家具装饰）的三行：判 AbleToAccept → 不行 return false,reason
--   ★ ★ 行 → 调 AcceptDecor。
        elseif act.target.components.furnituredecortaker then
            local able, reason = act.target.components.furnituredecortaker:AbleToAcceptDecor(act.invobject, act.doer)
            if not able then
                return false, reason
            else
                return act.target.components.furnituredecortaker:AcceptDecor(act.invobject, act.doer)
            end

        elseif act.target.components.inventoryitemholder ~= nil then
            return act.target.components.inventoryitemholder:GiveItem(act.invobject, act.doer)

        elseif act.target.components.quagmire_cookwaretrader ~= nil then
            return act.target.components.quagmire_cookwaretrader:AcceptCookware(act.doer, act.invobject)

        elseif act.target.components.quagmire_altar ~= nil then
            return act.target.components.quagmire_altar:AcceptFoodTribute(act.doer, act.invobject)
        end
    end
end

--★★ GIVETOPLAYER.fn —— 「给别的玩家」的判定与 GIVE 完全不同。
--   ★★★ 2348 行：
--       (target.components.inventory:IsOpenedBy(act.target)
--        or act.target:HasTag("playerghost"))
--   ★★★ 两个条件都是「**目标自己的背包开着**」或「目标是幽灵」：
--     ① 玩家的背包打开着才能往里放东西（否则玩家看不见）
--     ② 幽灵背包始终可写（幽灵没有 UI）
--   ★★ 于是「给玩家东西」的前提是**对方主动打开了背包**。
--     ★ 这解释了游戏里为什么「要先让对方开背包」—— 不是限制，是这套规则。
--   ★ 2350 行返回 `"FULL"` —— 有明确 reason，好于 GIVE 的静默失败。
ACTIONS.GIVETOPLAYER.fn = function(act)
    if ShouldBlockGiving(act) then
        return false
    end

    if act.target ~= nil and
            act.target.components.trader ~= nil and
            act.target.components.inventory ~= nil and
            (act.target.components.inventory:IsOpenedBy(act.target) or act.target:HasTag("playerghost")) then
        if act.target.components.inventory:CanAcceptCount(act.invobject, 1) <= 0 then
            return false, "FULL"
        end
        local able, reason = act.target.components.trader:AbleToAccept(act.invobject, act.doer)
        if not able then
            return false, reason
        else
            act.target.components.trader:AcceptGift(act.doer, act.invobject, 1)
            return true
        end
    end
end

--★ GIVEALLTOPLAYER.fn —— 与 GIVETOPLAYER 的差别只有两处：
--   ① 不需要 playerghost 分支（幽灵本来就不需要「全部给」）
--   ② count = CanAcceptCount(act.invobject) 而非 (…, 1)
--   ★★ 2362-2382 共 20 行，与 GIVETOPLAYER 的 2340-2360 几乎逐行对称。
ACTIONS.GIVEALLTOPLAYER.fn = function(act)
    if ShouldBlockGiving(act) then
        return false
    end

    if act.target ~= nil and
        act.target.components.trader ~= nil and
        act.target.components.inventory ~= nil and
        act.target.components.inventory:IsOpenedBy(act.target) then
        local count = act.target.components.inventory:CanAcceptCount(act.invobject)
        if count <= 0 then
            return false, "FULL"
        end
        local able, reason = act.target.components.trader:AbleToAccept(act.invobject, act.doer)
        if not able then
            return false, reason
        end
        act.target.components.trader:AcceptGift(act.doer, act.invobject, count)
        return true
    end
end

--★★★【IsFoodSafeToEat —— 「这个食物对方敢不敢吃」的联机判定（15 行）】
--   ★★★ 三个「无条件放行」：
--     ① possessedbody —— 附身的身体（你是它，全权控制）
--     ② TheNet:GetPVPEnabled() —— 开了 PVP 就别管安全了
--     ③ 三条实质规则：
--       · strongstomach + monstermeat → 强胃能吃怪肉
--       · spoiled + ignoresspoilage + 不是 badfood/unsafefood → 不怕臭
--       · 不是 badfood/unsafefood/spoiled → 安全
--   ★★★ 为什么需要这个函数？因为「喂别人吃东西」在联机里是个**攻击向量**：
--     玩家可以强行喂队友腐肉/毒蘑菇/石头。
--     ★ PVP 开启时免责 —— 因为那时玩家本来就能互相伤害。
--   ★★ 这是全文件里唯一一处主动考虑「恶意玩家」的地方，
--     值得作为安全设计的正面样本。
--   ★ 2396 行 `not (HasAnyTag(...))` 是「都不沾才算安全」，
--     ★★★ 三层判定里最严格的一层。
local function IsFoodSafeToEat(invobject, target)
    if target:HasTag("possessedbody") then -- No limitations, you're in full control of what you feed to them.
        return true
    end

    if TheNet:GetPVPEnabled() then -- PVP is on, no regards for safety
        return true
    end

    return (
        (target:HasTag("strongstomach") and invobject:HasTag("monstermeat")) or
        (invobject:HasTag("spoiled") and target:HasTag("ignoresspoilage") and not invobject:HasAnyTag("badfood", "unsafefood")) or
        not (invobject:HasAnyTag("badfood", "unsafefood", "spoiled"))
    )
end

--★★★【FEEDPLAYER.fn —— 「喂别人吃」的 38 行，含完整状态机操作】
--   ★★ 2401-2408 的七条件准入：
--     ① target 有效
--     ② sg 处于 idle 状态（2403）
--     ③ sg 不在 busy/attacking/sleeping 之一（2404）
--     ④ 目标不是 playerghost / wereplayer（2404）
--     ⑤ 目标有 eater 组件
--     ⑥ 食物有 edible 组件
--     ⑦ CanEat 通过 + IsFoodSafeToEat 通过
--   ★★★ ②③ 的组合是「既要在空闲、又不在忙」的检查 ——
--     ★★ 用 HasStateTag("idle") 加 HasAnyStateTag("busy",...) 双重判定，
--       比单看一个标签可靠。这是状态图标签管理的典型做法。
--       ★★ 参见 stategraph.lua：状态可以有多个标签，判定要看**标签集合**。
--   ★★ ②③ 在客户端也可读（sg 是 replica 的），但 fn 在服务端跑，
--     所以这里用 sg 直接访问没问题。
ACTIONS.FEEDPLAYER.fn = function(act)
    if act.target ~= nil and
        act.target:IsValid() and
        act.target.sg:HasStateTag("idle") and
        not (act.target.sg:HasAnyStateTag("busy", "attacking", "sleeping") or act.target:HasAnyTag("playerghost", "wereplayer")) and
        act.target.components.eater ~= nil and
        act.invobject.components.edible ~= nil and
        act.target.components.eater:CanEat(act.invobject) and
        IsFoodSafeToEat(act.invobject, act.target) then

--★★ PrefersToEat —— 「这个 NPC 愿不愿意吃这个」的第二层判定。
--   ★★★ 愿意吃 → 走 2412-2431 的完整流程；
--     不愿意 → 2433 推 wonteatfood 事件，**但仍然 return true**。
--   ★★★ 2434 行的英文注释解释了：
--     「动作仍然『成功』了，只是这一端没有结果。」
--     ★★★ 这是「区分『动作失败』与『效果未发生』」的教科书案例。
--     动作层成功（玩家正确地尝试了喂食），组件层拒绝（NPC 不饿）。
--     ★ 若 return false，玩家会看到「不能这么做」—— 完全错误的反馈。
        if act.target.components.eater:PrefersToEat(act.invobject) then
--★ isactive —— 食物是否正拿在手上（要传给状态图决定动画）。
--   ★★★ 这个信息必须**冻结**在动作执行的那一刻，
--     因为状态图播动画时物品已经是目标玩家的子实体了，
--     再去查「原玩家手上有没有它」已经查不到。
			local isactive = act.doer.components.inventory:GetActiveItem() == act.invobject
            local food = act.invobject.components.inventoryitem:RemoveFromOwner()
            if food ~= nil then
--★★★ 2414-2419 行的「五步转移」—— 把食物交给对方的技术细节：
--   ① RemoveFromOwner() 从原主人背包取出
--   ② act.target:AddChild(food)   → 成为对方的子实体
--   ③ food:RemoveFromScene()      → 从世界移除
--   ④ HibernateLivingItem()       → 冻结逻辑更新
--   ⑤ food.persists = false       → 不进存档
--   ★★★ 每一步都有必要：
--     · AddChild 让食物跟随对方移动与消失
--     · RemoveFromScene 阻止它还留在世界里被看到
--     · Hibernate 阻止它自己跑 OnUpdate（比如烧焦）
--     · persists=false 保证「喂到一半存档」不会留下幽灵食物
--   ★★ 2415 行的注释「Keep in sync with SGwilson.lua::TryReturnItemToFeeder」
--     ★★★ 这是一条**跨文件的同步契约**：状态图里有一个「喂食失败时
--       把食物还给喂食者」的函数，它依赖这里设置的这些字段。
--       ★★ 这类契约极脆：改了这里不改那边，就会出现「喂食中断后
--         食物凭空消失」。
--     ★ 值得在其他注释里也找找类似的 "keep in sync" 标注。
				--Config food assuming it is deleted when eaten.
				--NOTE: Keep in sync with SGwilson.lua::TryReturnItemToFeeder
                act.target:AddChild(food)
                food:RemoveFromScene()
                food.components.inventoryitem:HibernateLivingItem()
                food.persists = false
--★★ 保留的英文注释：状态要与 SGwilson.lua 的 ACTIONS.EAT 处理器保持一致。
--   ★★ 2421-2429 行是**在动作层手工选择目标状态**：
--       quickeat（标签）→ quickeat
--       sloweat（标签）→ eat
--       是肉类且不是饮品 → eat
--       否则 → quickeat
--   ★★★ 这意味着「自己吃」与「被喂」走的是不同状态，
--     决定了不同的动画与时长。
--   ★★★ 注释还指出一个已知限制：「Floating not supported
--     (should not make it past the "idle" check.)」——
--     ★★ 「漂浮状态不支持，但应该过不了 idle 检查」。
--     ★ 这是一个「用上游检查兜底未实现分支」的写法。
--   ★★ 注意这里读的是 `food:HasTag(...)` 与 `food.components.edible.foodtype`
--     —— 都在 RemoveFromOwner 之后、AddChild 之前，是安全的时刻。
				--
				--NOTE: Keep states in sync with SGwilson.lua ACTIONS.EAT handler.
				--NOTE: Floating not supported (should not make it past the "idle" check.)
                act.target.sg:GoToState(
					(food:HasTag("quickeat") and "quickeat") or
					(food:HasTag("sloweat") and "eat") or
					(food.components.edible.foodtype == FOODTYPE.MEAT and not food:HasTag("fooddrink") and "eat") or
					"quickeat",
					{ feed = food, feeder = act.doer, active = isactive }
                )
                return true
            end
        else
            act.target:PushEvent("wonteatfood", { food = act.invobject })
            return true -- the action still "succeeded", there's just no result on this end
        end
    end
end

--★ DECORATEVASE.fn —— 装饰花瓶。检查 vase.enabled（装饰是否被「禁用」）。
--   ★★ enabled 字段说明花瓶上的装饰可以临时失效（万圣节换装饰）。
ACTIONS.DECORATEVASE.fn = function(act)
    if act.target ~= nil and act.target.components.vase ~= nil and act.target.components.vase.enabled then
        act.target.components.vase:Decorate(act.doer, act.invobject)
        return true
    end
end

--★★ CARNIVALGAME_FEED.fn —— 嘉年华喂食，四层有效性检查。
--   ★★ 2447 行的四个 and：invobject 有效 + target 有效 + target 非 nil
--     + carnivalgamefeedable 组件。
--   ★★ 2448 行的 TOO_LATE —— 「太晚了」（游戏已结束）。
--     ★ 这是一个「状态性失败原因」的样本：不是「不能」，而是「晚了」。
ACTIONS.CARNIVALGAME_FEED.fn = function(act)
    if act.invobject ~= nil and act.invobject:IsValid() and act.target ~= nil and act.target:IsValid() and act.target.components.carnivalgamefeedable ~= nil then
		if not act.target.components.carnivalgamefeedable.enabled then
			return false, "TOO_LATE"
		end
        return act.target.components.carnivalgamefeedable:DoFeed(act.invobject, act.doer)
    end
end

--★★★ STORE.fn —— 「把东西放进去」，100 行，全文件第二长的动作实现。
--   ★★ 它要处理五种「放进去」的场景：
--     ① 玩家背包 → 容器（主路径）
--     ② 容器 → 容器（AI 或特殊实体）
--     ③ 材料堆（无 container 的 constructionsite）→ 工地
--     ④ 特殊：quagmire_stewer 强制掉落后再放
--     ⑤ occupiable（占用槽位，如六格冰箱的固定位）
--   ★★ 五种场景的判定顺序即优先级（2462 行的 constructionsite 最先）。
ACTIONS.STORE.fn = function(act)
--★ islockedinslot —— 「锁定在槽位」的物品不能被移走。
--   ★★ 返回 false 无 reason。玩家会看到「不能这么做」。
	if act.invobject.components.inventoryitem and act.invobject.components.inventoryitem.islockedinslot then
		return false
	end

    local target = act.target
--★★ 2461-2468：往「施工中的建筑」放材料。
--   ★★ 保留的英文注释：「V2C: 为了把物品放到物体上而非建造挂件上」。
--     ★★★ 「V2C」= 韦伯视角到玩家视角（View as Character）的转换注释前缀。
--     ★★ 这是本文件中一种独特的注释类型：它标记「这段逻辑是给韦伯补的」。
--       韦伯（Wortox）是「多人角色视角」，很多交互需要特殊处理。
--       ★ 全文共约 12 处 V2C 注释，是理解「为什么这段这么写」的钥匙。
--   ★ 2464 行的三元链：先看 builder 是不是自己，再看 builder 有没有
--     constructionbuilder 组件，最后看它有没有 constructioninst。
--     ★ 三层 nil 检查用 and/or 链实现，写法紧凑但易读性差。
    --V2C: For dropping items onto the object rather than construction widget
    if target.components.container == nil and target.components.constructionsite ~= nil then
        local builder = target.components.constructionsite.builder
        target = builder == act.doer and builder.components.constructionbuilder ~= nil and builder.components.constructionbuilder.constructioninst or nil
        if target == nil then
            return false
        end
    end
    --

--★★ 2471-2478 行：container_proxy 处理（与 RUMMAGE.fn 同构，p3 已详述）。
--   ★★ 再次出现「proxy 用于关闭/交互，master 用于实际数据」的分工。
	local proxy
	if target.components.container_proxy ~= nil then
		local master = target.components.container_proxy:GetMaster()
		if master ~= nil then
			proxy = target
			target = master
		end
	end

    if target.components.container ~= nil and act.invobject.components.inventoryitem ~= nil then
--★★★ 分支②：容器 → 容器（2481-2497 行）。
--   ★★★ 条件 `doer.components.inventory == nil and doer.components.container ~= nil`
--     ⇒ 「执行者没有背包但有容器」—— 即 AI（蜘蛛、螃蟹）。
--   ★★ 2483-2488 行：AI 放东西时若容器没开，**自动打开**。
--     ★ 与玩家路径不同：玩家路径要求容器已经开着。
--   ★★ 2490 行的 `CanAcceptCount >= stacksize` 是「能不能整堆收下」的判断：
--     ★★★ 容器不够收整堆就整个失败（2496 行 NOTALLOWED），
--       而不是「收一部分」。
--       ★ 这与 2089 行的手持烹调（可部分）策略不同 ——
--         同一个动作的两种路径有**不同的部分成功语义**。
        if act.doer.components.inventory == nil and act.doer.components.container ~= nil then
            -- Container to container.
            if not target.components.container:IsOpenedBy(act.doer) then
                if not target.components.container:CanOpen() then
                    return false, "INUSE"
                end
                target.components.container:Open(act.doer)
            end
            local stacksize = act.invobject.components.stackable and act.invobject.components.stackable.stacksize or 1
            if target.components.container:CanAcceptCount(act.invobject) >= stacksize then
                local pt = act.doer:GetPosition()
                local item = act.doer.components.container:RemoveItem(act.invobject, true)
                target.components.container:GiveItem(item, nil, pt, true)
                return true
            end
            return false, "NOTALLOWED"
        end
--★ 分支①：玩家背包 → 容器（2498-2577，80 行，是本 fn 的主体）。
        if act.doer.components.inventory ~= nil then
            if target.components.container:IsRestricted(act.doer) then
                return false, "RESTRICTED"
            end
            local success, reason = CanOpenCharacterSpecificContainer(act.doer, target)
            if not success then
                return false, reason
            end
            if not target.components.container:IsOpenedBy(act.doer) and not target.components.container:CanOpen() then
                return false, "INUSE"
            end
--★★ 2509-2520：灵魂罐的「 Hack」（JBK 注释）。
--   ★★ 保留的英文注释：
--     「Hack：让罐子更好用 —— 当玩家往罐子里放灵魂时，
--       在这里复制「灵魂跳跃计时器过期」的行为。」
--   ★★★ 也就是说：放灵魂的动作会顺带推进一次「传送冷却」计时，
--     让玩家不用等。
--   ★ 这是一个纯粹的**体验优化 hack**，用条件（>1 个灵魂）限制以防滥用。
--     ★ 条件判断 souls > 1 说明「只有一个时不加速」，避免被用来卡 CD。
            if act.doer.finishportalhoptask ~= nil and target:HasTag("souljar") and act.invobject:HasTag("soul") then
                -- NOTES(JBK): Hack to make the jar easier to use by replicating soul hop timer expiration for opening a jar here when trying to put items into the jar.
                local souls = 0
                act.doer.components.inventory:ForEachItem(function(item)
                    if item.prefab == act.invobject.prefab then
                        souls = souls + (item.components.stackable and item.components.stackable:StackSize() or 1)
                    end
                end)
                if souls > 1 then
                    act.doer:TryToPortalHop(1, true)
                end
            end

--★★★ 2522-2537 行：「建造挂件」的特殊槽位分配。
--   ★★ 条件：`constructionbuilderuidata:GetContainer() == target`
--     ⇒ 玩家正在为**这个容器**施工。
--   ★★★ 于是 STORE 动作在建造语境下会「认领特定槽位」：
--     2524 行 GetSlotForIngredient(prefab) 问「这个材料该放哪个格子」。
--   ★★ 2527 行与 2533 行都是「强制说话」：
--     即使 return false 会被静默处理，这里先 Say 一句 NOTALLOWED。
--     ★★★ 与之相对的是 2536 行的普通 `return false, "NOTALLOWED"`。
--     ★⇒ 同样是 NOTALLOWED，两条路径的玩家反馈完全不同。
--     ★ 注释说明原因（2526 行）：「建造是一个忙状态，需要强制说话」。
--     ★★★ 推理：忙状态下普通失败提示会被 SG 吞掉或表现不出来，
--       所以必须用 talker 直接说。这是「状态机吞事件」的补偿。
--   ★ 2531-2535 行对 bundle 标签做完全相同的处理（注释说明同理）。
--     ★ 两个特例：constructionbuilderuidata 与 bundle。
--       ⇒ 凡「动作处于某个忙碌状态里」的场景都要这样处理。
            local targetslot = nil
            if act.doer.components.constructionbuilderuidata ~= nil and act.doer.components.constructionbuilderuidata:GetContainer() == target then
                targetslot = act.doer.components.constructionbuilderuidata:GetSlotForIngredient(act.invobject.prefab)
                if targetslot == nil or not target.components.container:CanTakeItemInSlot(act.invobject, targetslot) then
                    --V2C: construction is a busy state, so we need to force the speech
                    act.doer.components.talker:Say(GetActionFailString(act.doer, "CONSTRUCT", "NOTALLOWED"))
                    return true
                end
            elseif not target.components.container:CanTakeItemInSlot(act.invobject) then
                if target:HasTag("bundle") then
                    --V2C: bundling is a busy state, so we need to force the speech
                    act.doer.components.talker:Say(GetActionFailString(act.doer, "STORE", "NOTALLOWED"))
                    return true
                end
                return false, "NOTALLOWED"
            end

--★★ quagmire_stewer 强制打开路径（2539-2557）。
--   ★★ forceopen = 目标是 quagmire_stewer 且它自己是个物品。
--     forcedrop = 它当前的主人（grandowner）。
--   ★★ 2541-2544 行：forcedrop 不是自己 → 静默 return true。
--     ★ 作者注明「Silent fail, should not reach here」。
--     ★★ 与 1115 行的 RUMMAGE 同款兜底（见 p3）。
            local forceopen = target.components.quagmire_stewer ~= nil and target.components.inventoryitem ~= nil
            local forcedrop = forceopen and target.components.inventoryitem:GetGrandOwner() or nil
            if forcedrop ~= nil and forcedrop ~= act.doer then
                --Silent fail, should not reach here
                return true
            end

--★★ RemoveFromOwner(acceptsstacks) —— 拿走物品。
--   ★★ 与 1475 行同款「整堆与否由容器能力决定」的用法。
            local item = act.invobject.components.inventoryitem:RemoveFromOwner(target.components.container.acceptsstacks)
            if item ~= nil then
--★ forcedrop 分支：先把炖锅从主人手里丢出来，再放入新容器。
                if forcedrop ~= nil then
                    forcedrop.components.inventory:DropItem(target, true, true)
                end
--★★ 2551-2557 行：forceopen 或目标不是物品时才打开容器。
--   ★★ 条件 `forceopen or target.components.inventoryitem == nil`：
--     炖锅（forceopen）或不是物品（本身就开着）。
--     ★★★ 也就是说「把东西放进一个已经打开着的容器里」不会重开它。
                if forceopen or target.components.inventoryitem == nil then
                    if proxy ~= nil then
                        proxy.components.container_proxy:Open(act.doer)
                    else
                        target.components.container:Open(act.doer)
                    end
                end

--★★★ 2559-2572 行：放入失败的三级回退（与 CHANGE_TACKLE 的 1494 行同型）。
--   ★★ 2560-2562 行有个联机特有的分支：
--       `playercontroller.isclientcontrollerattached`
--       ⇒ 手柄玩家用 GiveItem 而不是 GiveActiveItem。
--     ★★★ 原因：手柄没有「点物品」的概念，不能把手上的东西塞到光标处。
--       这个差异在 playercontroller.lua:4364 等处也反复出现。
--   ★ 2566-2572：bundle 标签时强制说话（同 2531 的处理）。
                if not target.components.container:GiveItem(item, targetslot, nil, false) then
                    if act.doer.components.playercontroller ~= nil and
                        act.doer.components.playercontroller.isclientcontrollerattached then
                        act.doer.components.inventory:GiveItem(item)
                    else
                        act.doer.components.inventory:GiveActiveItem(item)
                    end
                    if target:HasTag("bundle") then
                        --V2C: bundling is a busy state, so we need to force the speech
                        act.doer.components.talker:Say(GetActionFailString(act.doer, "STORE"))
                        return true
                    else
                        return false
                    end
                end
                return true
            end
            return false
        end
        -- Intentional fall through.
    end
--★ 分支⑤：occupiable —— 「占用型容器」（如六格冰箱的固定位置）。
--   ★★ 2581 行的双重否定很绕：
--     物品有 occupier 组件 **且** 目标有 occupiable 组件
--       **且** CanOccupy(物品) 为真。
--     ★★★ 三个条件缺一不可，这是全文件最深的条件嵌套之一。
--   ★★ 2584 行的 return 直接返回 Occupy 的结果，
--     丢掉了 2583 的 CanOccupy 检查结果（只用它做门槛）。
    if act.invobject ~= nil and
        act.invobject.components.occupier ~= nil and
        target.components.occupiable ~= nil and
        target.components.occupiable:CanOccupy(act.invobject) then
        return target.components.occupiable:Occupy(act.invobject.components.inventoryitem:RemoveFromOwner())
    end
end

--★ BUNDLESTORE.strfn —— 建造语境下显示 CONSTRUCT（同 2598 行的 fn 复用配对）。
ACTIONS.BUNDLESTORE.strfn = function(act)
    return act.target ~= nil
        and act.doer ~= nil
        and act.doer.components.constructionbuilderuidata ~= nil
        and (act.doer.components.constructionbuilderuidata:GetContainer() == act.target or
            act.doer.components.constructionbuilderuidata:GetTarget() == act.target)
        and "CONSTRUCT"
        or nil
end

--★ BUNDLESTORE.fn = STORE.fn —— T12 同构模板。
ACTIONS.BUNDLESTORE.fn = ACTIONS.STORE.fn

--★ STORE.strfn —— 三个 NPC 类标签变体。
ACTIONS.STORE.strfn = function(act)
    if act.target ~= nil then
        return ((act.target:HasTag("stewer") or act.target:HasTag("quagmire_stewer")) and (act.target:HasTag("spicer") and "SPICE" or "COOK"))
            or (act.target.prefab == "birdcage" and "IMPRISON")
            or (act.target:HasTag("decoratable") and "DECORATE")
            or nil
    end
end

--★★ BUILD.fn —— 三行转发，却承载了建造系统的全部入口。
--   ★★ `DoBuild(recipe, act:GetActionPoint(), act.rotation, act.skin)`
--     四个参数全部来自 BufferedAction：
--       recipe  ← act.recipe   （建造配方，构造函数第 6 参）
--       点      ← act:GetActionPoint()（GetActionPoint 而非 GetDynamicActionPoint）
--       朝向    ← act.rotation （构造函数第 10 参）
--       皮肤    ← act.skin      （构造函数第 19 参，默认为 nil）
--   ★★★ 这印证了 §0 的核心论点：**动作实例携带所有上下文**，
--     而 Action 原型只描述「这是个建造动作」。
--     ★ 若只用 ActPoints 里某个固定属性，就不需要这些参数。
--   ★ 2610 行的 builder 检查说明「不是所有实体都能建造」。
ACTIONS.BUILD.fn = function(act)
    if act.doer.components.builder ~= nil then
        return act.doer.components.builder:DoBuild(act.recipe, act:GetActionPoint(), act.rotation, act.skin)
    end
end

--★ PLANT.strfn —— PLANTER 变体（冬季树支架）。
ACTIONS.PLANT.strfn = function(act)
    return act.target ~= nil and act.target:HasTag("winter_treestand") and "PLANTER" or nil
end

--★★ PLANT.fn —— 三分支：普通种植 / 冬季树支架 / 还回种子。
--   ★★ 2623 行 `grower:PlantItem(seed, doer)` 为真才 return true。
--   ★★ 2625-2630 行的 elseif 链：
--     `act.target:HasTag("winter_treestand") and burnable ~= nil
--      and not (IsBurning() or IsSmoldering())`
--     ★★★ 为什么要检查「没在烧」？因为树支架是木制品，
--       在燃烧的支架上种种子不合理。
--     ★ 但注意：失败时**没有还回种子**（2631 行才还）——
--       elseif 条件不成立才会走 2632 的还回路径。
--       ★★★ 这里是 if / elseif / else 三分支的经典陷阱：
--         elseif 条件为真但内部逻辑未执行成功时，不会走 else。
--         这里恰好因为 PushEvent 后无条件 return true 而正确，
--         但**结构脆弱** —— 若将来 2629 行改成有条件返回，种子就丢了。
--         ★ 记录为 L 类隐患（结构脆弱，非当前 bug）。
ACTIONS.PLANT.fn = function(act)
    if act.doer.components.inventory ~= nil then
        local seed = act.doer.components.inventory:RemoveItem(act.invobject)
        if seed ~= nil then
            if act.target.components.grower ~= nil and act.target.components.grower:PlantItem(seed, act.doer) then
                return true
            elseif act.target:HasTag("winter_treestand")
                and act.target.components.burnable ~= nil
                and not (act.target.components.burnable:IsBurning() or
                        act.target.components.burnable:IsSmoldering()) then
                act.target:PushEvent("plantwintertreeseed", { seed = seed, doer = act.doer })
                return true
            else
                act.doer.components.inventory:GiveItem(seed)
            end
        end
    end
end

--★★ HARVEST.fn —— 七分支 if 链（§2 392 行已预告，这里看细节）。
--   ★★ 分支：
--     ① crop      → 收作物（成熟/枯萎都收）
--     ② harvestable → 通用收获
--     ③ stewer    → 取炖锅产物
--     ④ dryer     → 取晾干的产物
--     ⑤ dryingrack → 按 invobject 指定取（2648-2655）
--     ⑥ occupiable → 从占用型容器取
--     ⑦ quagmire_tappable → 取树液
--   ★★★ ★★ 分支⑤与其他六个**结构完全不同**：
--     它是「按指定物品取」而不是「取全部产物」。
--     2649 行 RemoveItem(act.invobject) —— 精确取那一个。
--     ★ 这就是 §2 452 行 TAKEITEM 注释说的「取出 vs 产出」区别，
--       在 HARVEST 里也有。
--   ★★ 2640 行的返回值是 harvested（来自 crop:Harvest），
--     后两返回值被注释掉了 —— 说明曾想返回 (bool, product) 但没用。
--     ★ 又一处「保留了被注释的返回值」。
ACTIONS.HARVEST.fn = function(act)
--★★ HARVEST.fn 的七分支在 2639-2665；此处是分支⑤（2648）的说明。
--   ★★ 分支⑤的独特之处：「取出指定物品」而非「产出全部」。
--     ★★ 2649 行 `RemoveItem(act.invobject)` —— 
--       invobject 是「玩家手上拿着的、要从架子上取下来的那个」。
--     ★ 语义：晾晒架上有一堆肉，玩家手上有肉 ⇒ 取一份下来。
--       ★ 若手上没有对应的肉，RemoveItem 返回 nil ⇒ 整个分支失败。
    if act.target.components.crop ~= nil then
--★★ HARVEST.fn 的七分支逐个看（2639-2665）：
--   ① crop        → 2639-2641（成熟/枯萎都收）
--   ② harvestable → 2642-2643（通用收获，两行）
--   ③ stewer      → 2644-2645（取炖锅产物，两行）
--   ④ dryer       → 2646-2647（取晾干产物，两行）
--   ⑤ dryingrack  → 2648-2655（按 invobject 指定取）
--   ⑥ occupiable  → 2656-2661（从占用型容器取）
--   ⑦ quagmire_tappable → 2662-2664（取树液）
--   ★★★ ②③④ 是**逐字对称**的三段（各两行），只有组件名不同。
--     ★ 这是「同构模板」在单个函数内的体现。
--   ★★ ⑥2656 行的条件用 and 连接 IsOccupied() 与组件存在。
        local harvested--[[, product]] = act.target.components.crop:Harvest(act.doer)
        return harvested
    elseif act.target.components.harvestable ~= nil then
        return act.target.components.harvestable:Harvest(act.doer)
    elseif act.target.components.stewer ~= nil then
        return act.target.components.stewer:Harvest(act.doer)
    elseif act.target.components.dryer ~= nil then
        return act.target.components.dryer:Harvest(act.doer)
    elseif act.target.components.dryingrack ~= nil and act.invobject and act.target.components.container ~= nil then
        local targetitem = act.target.components.container:RemoveItem(act.invobject)
        if targetitem ~= nil then
            targetitem.prevcontainer = nil
            targetitem.prevslot = nil
            act.doer.components.inventory:GiveItem(targetitem)
            return true
        end
--★★ 分支⑥（occupiable）的六行 —— 「从占用型容器取走」。
--   ★★ 2658 行的 `if item ~= nil then` 检查：
--     ★ Occupy 可能返回 nil（容器里其实没东西）。
--     ★★ 这里**做了** nil 检查 —— 与 §p9 4805 行的 BATHBOMB 形成对比。
--       ★ 说明作者知道这个陷阱，只是没处处设防。
    elseif act.target.components.occupiable ~= nil and act.target.components.occupiable:IsOccupied() then
        local item = act.target.components.occupiable:Harvest(act.doer)
        if item ~= nil then
            act.doer.components.inventory:GiveItem(item)
            return true
        end
	elseif act.target.components.quagmire_tappable ~= nil then
		return act.target.components.quagmire_tappable:Harvest(act.doer)
    end
end

--★ HARVEST.strfn —— 两个变体（FREE 鸟笼 / WITHERED 枯萎）。
--   ★★ 2671 行 `crop and HasTag("withered")` 用 and 连接，
--     与其它 strfn 用 or 串联不同 —— 这里只处理一种情况。
ACTIONS.HARVEST.strfn = function(act)
    if act.target ~= nil and act.target.prefab == "birdcage" then
        return "FREE"
    end
    if act.target ~= nil and act.target.components.crop and act.target:HasTag("withered") then
        return "WITHERED"
    end
end

--★ LIGHT.fn —— 点火。2679 行先推 onstartedfire 事件再点。
--   ★★★ 事件先行（与 3169 行「先推事件再掉战利品」同源原则）。
ACTIONS.LIGHT.fn = function(act)
    if act.invobject ~= nil and act.invobject.components.lighter ~= nil then
        if act.doer ~= nil then
            act.doer:PushEvent("onstartedfire", { target = act.target })
        end
        act.invobject.components.lighter:Light(act.target, act.doer)
        return true
    end
end

--★★ SLEEPIN.fn —— 「睡袋在手上或地上」的双路径（2688-2691 行）。
--   ★★★ `(invobject 有 sleepingbag and invobject) or
--      (target 有 sleepingbag and target) or nil`
--   ★★★ 这个 or 链的写法很巧妙：每个分支返回**实体本身**而不是 true，
--     所以 2692 行 `if bag ~= nil` 同时起到「三选一」的作用。
--     ★ 与 p3 1052 行的 `targ = act.target or act.invobject` 同源，
--       但这里更简洁。
ACTIONS.SLEEPIN.fn = function(act)
    if act.doer ~= nil then
        local bag =
            (act.invobject ~= nil and act.invobject.components.sleepingbag ~= nil and act.invobject) or
            (act.target ~= nil and act.target.components.sleepingbag ~= nil and act.target) or
            nil
        if bag ~= nil then
            bag.components.sleepingbag:DoSleep(act.doer)
            return true
        end
    end
end

--★★ HITCHUP.fn —— 「叫牛来」的四步判定（37 行）。
--   ★★ 判定链：
--     ① 2700-2702  doer/target 必须存在
--     ② 2704-2711  背包里找「牛铃」（GetBeefalo 非 nil）
--     ③ 2718-2721  牛铃与目标的距离 < 400（20 格²）→ NEEDBEEF_CLOSER
--     ④ 2723-2725  牛不在「坏心情」里 → INMOOD
--   ★★★ ★★ 第③条的理由由 2719 行的失败原因暗示：
--     「need beefer closer」—— 但英文注释在 2719 行说：
--     「we could've been in range but the pet was out of range」
--     ★★★ 这句注释说的是**另一个场景**（ABANDON 动作，4202 行），
--       但它同样适用于这里：玩家对着远处的桩子按「叫牛」，
--       动作的 rangecheck（DefaultRangeCheck 4 格）通过了，
--       但牛本身在 20 格外 —— 于是需要这个二次检查。
--     ★★ 这是 §2 446 行 STEAL 那条注释的同款思路：
--       「动作范围过了不等于真正可行」。
--   ★★ 400 这个魔数 = 20²，同样是无注释的独立字面量。
ACTIONS.HITCHUP.fn = function(act)
--★★ HITCHUP.fn（2699-2735）的四道判定已在 2700 行起逐条注释。
--   ★★ 需要特别记住的是 2718 行的距离魔数 400（= 20 格²）：
--     ★ 它与 DefaultRangeCheck(4 格) 无关，是「牛铃到桩子」的距离。
--     ★★ 而玩家的距离（4 格）由 ACTIONS.HITCHUP 的声明控制。
--       ⇒ 两个距离约束叠加，任一不满足就失败。
--     ★ 这是「双重距离检查」的范例：一个管人，一个管畜。
    if act.doer == nil or act.target == nil then
        return false
    end

    local bell = nil
--★★ HITCHUP.fn 的判定链逐步展开：
--   ②7005-2711 背包里找牛铃（FindItem + GetBeefalo）
--   ③2713-2716 取出 beefalo，没有 → NEEDBEEF
--   ④2718-2721 距离 < 400 → NEEDBEEF_CLOSER
--   ⑤2723-2725 牛不在坏心情 → INMOOD
--   ⑥2727       推 hitchto 事件
--   ⑦2729-2732 让牛哞叫（并清 comment_data）
--   ★★★ 2731 行 `act.doer.comment_data = nil` 是隐藏的副作用：
--     ★ 它清除玩家「待说的话」，因为这次动作要用说话通道播牛的叫声。
--     ★ 与 §p5 2940 行 COMMENT.fn 的清空同款 ——
--       「doer 上的临时字段当参数通道」的模式。
    if act.doer.components.inventory then
        bell = act.doer.components.inventory:FindItem(function(item)
            if item.GetBeefalo and item:GetBeefalo() then
                return true
            end
        end)
    end

    local beefalo = bell and bell:GetBeefalo()
    if not beefalo then
        return false, "NEEDBEEF"
    end

    local inrange = act.target:GetDistanceSqToInst(beefalo) < 400
    if not inrange then
        return false, "NEEDBEEF_CLOSER"
    end

    if beefalo:GetIsInMood() then
        return false, "INMOOD"
    end

--★★ 2727 行的 hitchto 事件 —— 「牛走向桩子」的信号。
--   ★★ 事件负载只有 doer 与 target（牛的移动由 hitcher 组件处理）。
    beefalo:PushEvent("hitchto", {doer = act.doer, target = act.target})

    if act.doer.components.talker ~= nil then
        act.doer.components.talker:Say(GetString(act.doer, "ANNOUNCE_CALL_BEEF"))
        act.doer.comment_data = nil
    end

    return true
end

--★ UNHITCH.fn —— 注意 2741 行 `not act.target:HasTag("hitcher")` 的反直觉条件。
--   ★★★ 2742 行的缩进错误（多一级）暗示这个分支是后加的。
--     语义：目标是「系马桩」时不能解绳（因为桩子本身就是系的地方）。
--     ★ 「hitcher」标签表示「这个实体是拴绳的起点」。
ACTIONS.UNHITCH.fn = function(act)
    if act.doer ~= nil and
        act.target ~= nil and
        act.target.components.hitcher and
        not act.target:HasTag("hitcher") then
            act.target.components.hitcher:Unhitch()
        return true
    end
end

--★★★⚠ 疑似缺陷 L6：HITCH.fn 没有返回值。
--   ★★★ 函数体最后一行是 `end`（2752 行），没有 return。
--     ⇒ Lua 隐式返回 nil ⇒ bufferedaction.lua:26-34：
--       success = nil → 走 else 分支 → self:Fail()
--   ★★ 后果：
--     · 动作被标记为「失败」→ 触发 onfail 回调；
--     · 但 fn 里 2749-2751 行的实际效果（SetHitched）**已经生效**。
--   ★★★ 为什么这可能无害？
--     HITCH 唯一的调用者是 AI：brains/beefalobrain.lua:171
--       `return BufferedAction(inst, inst.hitchingspot, ACTIONS.HITCH)`
--     AI 侧不会注册 onfail 回调（DoAction fn 里直接返回），
--     且 stategraph 的 ActionHandler 也不检查返回值。
--     ★ ⇒ 对 AI 而言「成功还是失败」没有区别。
--   ★★ 但这是一个真实的语义瑕疵：动作执行了副作用却报告失败。
--     若将来玩家也能触发 HITCH（看到「牵牛」选项），会「点了没反应」。
--     ★ 正确写法应是 `return true`。
--     ★ 与 1871 行 NET.fn 的无条件 return true 恰好相反 ——
--       同样是「执行了副作用但返回值不对」，一个报成功一个报失败。
--     ★★ 这个对比很有价值：**两个同类问题的处理方向相反**。
--   ★ 结论：真实的语义瑕疵（当前无实际影响）。只记录不修改。
ACTIONS.HITCH.fn = function(act)
    act.doer.hitchingspot = nil
    if act.target:HasTag("hitcher") then
        act.target.components.hitcher:SetHitched(act.doer)
    end
end

--★ MARK.strfn —— 「已标记 / 未标记」的双态显示。
--   ★★ 2755 行用 HasMarked(doer) 判断 —— 「自己标记过」才显示 UNMARK。
ACTIONS.MARK.strfn = function(act)
    if act.target and act.target.components.markable and act.target.components.markable:HasMarked( act.doer ) then
        return "UNMARK"
    end
end

--★★ MARK.fn —— markable 与 markable_proxy 的双写模式。
--   ★★ 2763-2768 行：先试 markable，失败了再试 markable_proxy。
--     ★★★ 与 RUMMAGE.fn 1057 行的 proxy/master 是同一种思路的简化版：
--       有些对象有真正的组件，有些只有代理。
--   ★★ 2776-2779 行的两种失败原因：
--     not_participant → NOT_PARTICIPANT（不是活动参与者）
--     其它             → ALREADY_MARKED
--     ★★★ 注意「其它」这个兜底会掩盖真正的失败原因。
--       若 Mark 因别的原因失败（如距离太远），玩家会看到「已标记」。
--       ★ 属于「粗粒度失败原因」的例子。
ACTIONS.MARK.fn = function(act)
    local can, fail = nil, nil

    if act.target.components.markable then
        can, fail = act.target.components.markable:Mark(act.doer)
    end
    if not can and act.target.components.markable_proxy then
        can, fail = act.target.components.markable_proxy:Mark(act.doer)
    end

    if can then
        if act.doer.yotb_post_to_mark then
            act.doer.yotb_post_to_mark = nil
        end
        return true
    else
        if fail == "not_participant" then
            return false, "NOT_PARTICIPANT"
        end
        return false, "ALREADY_MARKED"
    end
end

--★ CHANGEIN.strfn —— DRESSUP 变体。
ACTIONS.CHANGEIN.strfn = function(act)
    return act.target ~= nil and act.target:HasTag("dressable") and "DRESSUP" or nil
end

--★★★⚠⚠ 疑似缺陷 L2（运算符优先级）：
--     `act.doer ~= nil and act.target ~= nil and
--      act.target.components.wardrobe ~= nil or act.target.components.groomer ~= nil`
--   ★★★ Lua 的 `and` 优先级**高于** `or`，所以实际解析为：
--       (doer~=nil) and (target~=nil) and (wardrobe~=nil)
--         or (groomer~=nil)
--   ★★ 后果一（逻辑漏洞）：若 `act.doer == nil` 但 target 有 groomer 组件，
--       整个表达式仍为 true ⇒ 后续 2800 行 `component:CanBeginChanging(nil)`
--       会被调用 ⇒ 传入 nil doer。
--   ★★ 后果二（潜在崩溃）：若 `act.target == nil`，
--       则第二个 or 分支 `act.target.components.groomer` 对 nil 取索引
--       ⇒ **index a nil value** 崩溃。
--   ★★★ 对比同文件其它三处类似的写法：
--     · actions.lua:5507 `doer and object and doer.components.inventory`
--     · actions.lua:3048 `act.doer and act.target and targ.components.groomer`
--     · actions.lua:1943 `act.target and (... or ...)`
--     ★★ 这些都正确地加了括号或前置 nil 保护。
--       说明 2789 行是**漏加括号**，而非风格差异。
--   ★★ 作者本意应是：
--       `act.doer ~= nil and act.target ~= nil and
--        (act.target.components.wardrobe ~= nil
--         or act.target.components.groomer ~= nil)`
--     ★ 注意 2796-2798 行的内部逻辑（先 wardrobe 后 groomer，groomer 覆盖）
--       说明作者确实把两者当成「或」关系。
--   ★ 实际影响：仅当 doer 或 target 为 nil 时触发。
--     ★ fn 在服务端由 BufferedAction 调用，doer/target 通常非 nil，
--       ⇒ 实际触发概率低。但仍是真实的逻辑缺陷。
--     ★★★ 修复只需加一对括号（但本项目要求不改代码，只记录）。
ACTIONS.CHANGEIN.fn = function(act)
    if act.doer ~= nil and
        act.target ~= nil and
        act.target.components.wardrobe ~= nil or act.target.components.groomer ~= nil then

--★ 2792-2798 行：组件选择。groomer 优先级更高（会覆盖 wardrobe）。
--   ★★ 写成一个 if 一个 if 而非 if/elseif，
--     结果是「两者都有时用 groomer」。这是刻意的还是笔误？
--     ★ 没有注释说明。按语义推断 wardrobe（衣柜）应该更常用。
--       记为可疑但不足以判定缺陷。
        local component = nil
        if act.target.components.wardrobe then
            component = act.target.components.wardrobe
        end
        if act.target.components.groomer then
            component = act.target.components.groomer
        end

        local success, reason = component:CanBeginChanging(act.doer)
        if not success then
            return false, reason
        end

--★★ 黑暗中静默失败（§0 第 8 条清单的第 2 处）。
--   ★★ 与 1120 行 RUMMAGE 的处理完全一致：CanEntitySeeTarget 才真的开衣柜。
--   ★★ 但注意 2809 行的 return **true** ——
--     ★ 与 CHANGEIN 里的 CanBeginChanging 失败（2802 行）不同，
--       那个是真失败（return false, reason），这个是静默成功。
--     ★★★ 两种「不能做」用了**不同的失败策略**：
--       · 客观不能（箱子锁着）→ 明确报错
--       · 主观看不见（黑暗中）  → 静默成功
--     ★ 这个区分非常合理：玩家在黑暗中点灯是有意义的，
--       但锁着的箱子点了会白点。
        --Silent fail for opening wardrobe in the dark
        if CanEntitySeeTarget(act.doer, act.target) then
            component:BeginChanging(act.doer)
        end
        return true
    end
end

--★ SHAVE.strfn —— 「刮自己 vs 刮别人」由输入设备决定。
--   ★★ 2815 行 `TheInput:ControllerAttached()` ——
--     ★★★ strfn 在客户端跑，可以直接问输入设备。
--       这是「strfn 能做 fn 不能做的事」的典型。
--     ★ 手柄玩家没有「点击自己」的操作，所以当 target 为自己时显示 SELF。
ACTIONS.SHAVE.strfn = function(act)
    return (act.target == nil or act.target == act.doer)
        and TheInput:ControllerAttached()
        and "SELF"
        or nil
end

--★★ SHAVE.fn —— 「刮自己」的实现（2822 行 target or doer）。
--   ★★ 两个组件分支：beard（胡子）与 shaveable（毛茸茸的东西如牛）。
--     ★ beard 传两个参数（actor, shaver），shaveable 也传两个 —— 
--       1951 行的写法相同，但签名可能不同。属「看起来一样实则不同」的隐患。
ACTIONS.SHAVE.fn = function(act)
    if act.invobject ~= nil then
        local shavee = act.target or act.doer
        if shavee ~= nil and act.invobject.components.shaver ~= nil then
            if shavee.components.beard ~= nil then
                return shavee.components.beard:Shave(act.doer, act.invobject)
            elseif shavee.components.shaveable ~= nil then
                return shavee.components.shaveable:Shave(act.doer, act.invobject)
            end
        end
    end
end

--★ PLAY.strfn —— 三态：COACH_ON / COACH_OFF / TWEET。
--   ★★★ 2836-2837 行用「标签组合」表达三态：
--       有 wolfgang_coach 标签 且 有 mightiness_normal 标签 → 才能当教练
--       有 coaching 标签 → 正在教练中（显示 OFF）
--       否则 → 普通哨子（TWEET）
--     ★★★ 「能不能当教练」由**两个标签的组合**决定，不是单个标签。
--       这是标签系统表达「状态组合」的常见手法。
ACTIONS.PLAY.strfn = function(act)
	if act.invobject ~= nil then
		if act.invobject:HasTag("coach_whistle") then
			if act.doer:HasTag("wolfgang_coach") and act.doer:HasTag("mightiness_normal") then
				return act.doer:HasTag("coaching") and "COACH_OFF" or "COACH_ON"
			end
			return "TWEET"
		end
	end
end

ACTIONS.PLAY.fn = function(act)
    if act.invobject and act.invobject.components.instrument then
        return act.invobject.components.instrument:Play(act.doer)
    end
end

--★ POLLINATE.fn —— 「有目标播粉 / 无目标造花」二分。
ACTIONS.POLLINATE.fn = function(act)
    if act.doer.components.pollinator ~= nil then
        if act.target ~= nil then
            return act.doer.components.pollinator:Pollinate(act.target)
        else
            return act.doer.components.pollinator:CreateFlower()
        end
    end
end

--★ TERRAFORM.fn —— 转发给 terraformer 组件。
ACTIONS.TERRAFORM.fn = function(act)
    if act.invobject ~= nil and act.invobject.components.terraformer ~= nil then
        return act.invobject.components.terraformer:Terraform(act:GetActionPoint(), act.doer)
    end
end

--★★ EXTINGUISH.fn —— 「灭火」的两种模式。
--   ★★ 模式①（2867-2873）：正在燃烧的 → 有燃料就减少一节，否则直接熄。
--     ★★★ 为什么要「有燃料就 ChangeSection(-1)」？
--       因为大型火源（营火）熄火需要多次点击，每次灭掉一节燃料。
--       ★ 这是「给大型对象做的渐进式交互」。
--   ★★ 模式②（2874-2876）：没在烧但有 canbespecialextinguished 标签
--     且非空 → 也能减一节。
--     ★ 用于「没点着但可以手动灭」的东西（如漏油的机器）。
--   ★★ 2874 行的 `canbespecialextinguished` 字段名见 §二（未在 Action 里，
--     是在 fueled 组件上的）。
--   ★★ 函数末尾隐式返回 nil ⇒ 「什么都不满足」时静默失败。
ACTIONS.EXTINGUISH.fn = function(act)
    if act.target.components.burnable ~= nil and act.target.components.burnable:IsBurning() then
        if act.target.components.fueled ~= nil and not act.target.components.fueled:IsEmpty() then
            act.target.components.fueled:ChangeSection(-1)
        else
            act.target.components.burnable:Extinguish()
        end
        return true
    elseif act.target.components.fueled ~= nil and act.target.components.fueled.canbespecialextinguished and not act.target.components.fueled:IsEmpty() then
        act.target.components.fueled:ChangeSection(-1)
    end
end

--★★ STOKEFIRE.fn —— 「拨火」的三条件。
--   ★★ `doer:HasTag("controlled_burner")` ——
--     ★★★ 这是「只有韦伯能做」的实现方式：用标签而非组件。
--       与 1019 行的 masterchef 标签同族。
--     ★ 标签方式的优点：不需要新增组件；缺点：无法携带参数。
--   ★★ 2885 行的 else 分支 `return false` —— 目标不是 stokeablefire。
--     ★★★ 注意这**没有 reason**，与 2885 的 return true 不对称：
--       「能拨」→ true；「不能拨但目标在烧」→ false。
--       而「目标没在烧」→ 落到 2888 行隐式 nil。
--       ★ 三种情况两种反馈，是「反馈不完全」的样本。
ACTIONS.STOKEFIRE.fn = function(act)
    if act.target.components.burnable ~= nil and act.target.components.burnable:IsBurning() and act.doer:HasTag("controlled_burner") then
        if act.target:HasTag("stokeablefire") then
            act.target.components.burnable:StokeControlledBurn()
            return true
        else
            return false
        end
    end
end

--★ LAYEGG.fn —— 「现在能不能采蛋」的取反判断。
--   ★★★ `not act.target.components.pickable.canbepicked` ——
--     注意字段名是 **canbepicked**（无 up），与 PICKUP.fn 用的
--     **canbepickedup** 不同。两个拼写。
--     ★ 值得警惕：两个近似字段名在不同 prefab 上混用，
--       阅读时极易混淆。记为 L 类隐患。
ACTIONS.LAYEGG.fn = function(act)
    if act.target.components.pickable ~= nil and not act.target.components.pickable.canbepicked then
        return act.target.components.pickable:Regen()
    end
end

--★ INVESTIGATE.fn —— 调查热点。读 knownlocations 的「investigate」标记。
--   ★★ 2899 行 RememberLocation(..., nil) 把标记清掉（用一次就没）。
--   ★★ 2901-2903 行的额外动作：TryRetarget —— 
--     「顺便看看附近有没有该打的东西」。
--     ★★★ 这是「调查」这个玩法在战斗系统里的延伸：
--       考古调查点往往在怪物附近，所以调查完立刻重新选目标。
ACTIONS.INVESTIGATE.fn = function(act)
    local investigatePos = act.doer.components.knownlocations ~= nil and act.doer.components.knownlocations:GetLocation("investigate") or nil
    if investigatePos ~= nil then
        act.doer.components.knownlocations:RememberLocation("investigate", nil)
        --try to get a nearby target
        if act.doer.components.combat ~= nil then
            act.doer.components.combat:TryRetarget()
        end
        return true
    end
end

--★★ COMMENT.fn —— 「点评动物花纹」的动作，34 行。
--   ★★ 结构：读 doer.comment_data（由别处预填），然后：
--     ① 2915-2927 有 npc_talker（NPC 评论）→ Chatter 或 Say
--     ② 2928-2939 有 talker（玩家评论）→ 同样两种
--   ★★★ 为什么 NPC 与玩家要分两套？
--     npc_talker 与 talker 是**不同的组件**，但接口相似。
--     ★ 作者选择写两遍而非抽象，说明它们的差异足够大。
--     ★ 2927 行的 DoNextLine() 只在 npc_talker 分支被调 ——
--       玩家说话不需要「下一句」。
--   ★★ 2940 行 `doer.comment_data = nil` 在 if/elseif 之外 ——
--     ★★★ 无论走哪个分支都清空。
--     ★ 这是「用 doer 上的临时字段当参数通道」的模式，与 p6 的
--       CLIENT_REQUESTED_ACTION 同源。
--     ★ 好处：不需要改 fn 签名；风险：字段可能被别处覆盖。
ACTIONS.COMMENT.fn = function(act)
    local doer = act.doer
--★★ COMMENT.fn 的两套 talker 分支在 2915-2939。
--   ★★ 注意 2927 行的 DoNextLine() 只在 npc_talker 分支里。
--     ★ 「NPC 说完了继续说下一句」——玩家说话不需要这个机制。
--   ★★ 2940 行的清空在 if/elseif 之外（两分支共用）。
    local comment_data = doer.comment_data
    if not comment_data then
        return
    end

--★★ COMMENT.fn 的两套 talker 逐步展开：
--   ①2915-2927 npc_talker（NPC 评论）：
--     · 2916-2922 do_chatter → Chatter，否则 Say
--     · 2927 DoNextLine()（「NPC 说完继续下一句」）
--   ②2928-2939 talker（玩家评论）：同款但无 DoNextLine
--   ③2940 两条路径共用：清空 comment_data
--   ★★★ 两套组件接口相似但不完全相同（Chatter 的参数更多），
--     所以作者选择复制而非抽象。
    if doer.components.npc_talker then
        if comment_data.do_chatter then
            doer.components.npc_talker:Chatter(
                comment_data.speech,
                comment_data.chatter_index,
                nil, nil,
                comment_data.chat_priority
            )
        else
            doer.components.npc_talker:Say(comment_data.speech)
        end

--★ 2927 行 —— 「让 NPC 继续说下一句」。
--   ★★ 只有 npc_talker 有这个方法，玩家没有。
--     ★ 语义：NPC 评论是一串连续的话，说完这句自动接下一句。
        doer.components.npc_talker:DoNextLine()
    elseif doer.components.talker then
        if comment_data.do_chatter then
            doer.components.talker:Chatter(
                comment_data.speech,
                comment_data.chatter_index,
                nil, nil,
                comment_data.chat_priority
            )
        else
            doer.components.talker:Say(comment_data.speech)
        end
    end
    doer.comment_data = nil
end

--★★ GOHOME.fn —— 「回家」，20 行，含自我销毁。
--   ★★ 保留的自嘲注释「this is gross. make it better later.」——
--     ★★★ 作者对这段代码的评价。读到这里应该理解为什么：
--       它把四种「家」的判定（spawner / childspawner / hideout / 通用）
--       硬编码在一个 if 链里，且要处理 target 为 nil 与 pos 两种情况。
--       ★ 最后还要 `act.doer:Remove()` —— 玩家实体消失（回到洞穴）。
--   ★★ 2945-2947 行的 `force_onwenthome_message` 是一个调试/特效开关：
--     只有强制设置时才推 onwenthome 事件。
ACTIONS.GOHOME.fn = function(act)
    --this is gross. make it better later.
    if act.doer.force_onwenthome_message then
        act.doer:PushEvent("onwenthome")
    end
    if act.target ~= nil then
        if act.target.components.spawner ~= nil then
            return act.target.components.spawner:GoHome(act.doer)
        elseif act.target.components.childspawner ~= nil then
            return act.target.components.childspawner:GoHome(act.doer)
        elseif act.target.components.hideout ~= nil then
            return act.target.components.hideout:GoHome(act.doer)
        end
--★ 兜底分支：既不是已知 home 类型就推事件 + 销毁玩家。
--   ★★★ 这里**直接 Remove 掉执行者**。
--     全文件唯一的「动作删除执行者」的行为。
--     ★ 玩家从消失中回来时由世界重新生成实体。
--     ★ 若 Remove 之后 fn 还返回 true，BufferedAction 会继续跑 Succeed，
--       访问已被移除的 doer —— 幸好 Succeed 只跑 onsuccess 回调数组，
--       通常是空的。属「侥幸安全」。
        act.target:PushEvent("onwenthome", { doer = act.doer })
        act.doer:Remove()
        return true
    elseif act.pos ~= nil then
        act.doer:Remove()
        return true
    end
end

--★ JUMPIN.strfn —— 「附身 / 跳跃」的名字由 doer 是不是幽灵决定。
--   ★★ 与 CLIMB.strfn（6964 行）完全相同的写法 ——
--     ★ 两个动作共用一套「幽灵时改名」的规则。
ACTIONS.JUMPIN.strfn = function(act)
    return act.doer ~= nil and act.doer:HasTag("playerghost") and "HAUNT" or nil
end

--★★★ JUMPIN.fn —— 「两阶段动作」的第一阶段（§2 431 行已预告）。
--   ★★ 2972 行 `sg.currentstate.name == "jumpin_pre"` ——
--     ★★★ 动作**只有在特定状态下才生效**。
--     ★ 完整时序：
--       ① 玩家点击 → 动作触发 → sg 切到 jumpin_pre（动画：走向洞穴）
--       ② 动画中玩家再次触发同一动作（或 sg 自己触发）
--       ③ 这次 sg 已在 jumpin_pre ⇒ fn 切到 jumpin（真正传送）
--     ★ 目的：给长距离传送一个「蓄力」阶段，玩家可以被打断。
--   ★★ 2979 行的 `GoToState("idle")` 是「条件不满足就回空闲」——
--     ★ 因为此时 fn 会隐式返回 nil ⇒ 动作报告失败 ⇒
--       但 sg 已经回到 idle，视觉上不会出现卡死。
--     ★★★ 这是「用状态机兜住失败」的写法：
--       动作层返回失败，状态层已经自我修复。
ACTIONS.JUMPIN.fn = function(act)
    if act.doer ~= nil and
        act.doer.sg ~= nil and
        act.doer.sg.currentstate.name == "jumpin_pre" then
        if act.target ~= nil and
            act.target.components.teleporter ~= nil and
            act.target.components.teleporter:IsActive() then
            act.doer.sg:GoToState("jumpin", { teleporter = act.target })
            return true
        end
        act.doer.sg:GoToState("idle")
    end
end

--★ JUMPIN_MAP.stroverridefn —— 地图版显示固定的 MAP_WORMHOLE 词。
--   ★★ 与 TELLSTORY 同款：用 stroverridefn 得到「干净的词」。
ACTIONS.JUMPIN_MAP.stroverridefn = function(act)
    return STRINGS.ACTIONS.JUMPIN.MAP_WORMHOLE
end

--★ 两个 FindEntities 的 must-tag 列表。
--   ★★ ★★★ 「章鱼洞」这个玩法用两级 indirection 实现：
--     charlieresidue（章鱼残留物）—— 一个**地图上的标记实体**
--       它自己有一个 target（真正的虫洞或触手柱）
--     玩家在地图上点残留物 ⇒ 需要在附近找另一个虫洞作为**出口**
--     找到就双向传送。
--   ★ 这是本文件里最复杂的「多级目标」逻辑（1300-1320 的 remap +
--     2989-3027 的 fn + 3028-3051 的 MAP 变体，共 100 行）。
local WORMHOLE_MUST_TAGS = {"wormhole"}
local TENTACLE_PILLAR_MUST_TAGS = { "tentacle_pillar" }
--★★【DoCharlieResidueMapAction —— 章鱼洞地图传送的 39 行】
--   ★★ 两个大分支：
--     ① 2993 residuetarget 有 wormhole 标签   → 找另一个虫洞作出口
--     ② 3006 residuetarget.prefab == "tentacle_pillar_hole" → 找触手柱
--   ★★ 两个分支的结构几乎逐行对应，差别只在：
--     · 搜索用的 must tags（2995 vs 3008）
--     · 3016-3019 的「沉睡的触手柱要先唤醒」（Overtake）
--   ★★★ 3002 行与 3015 行的注释「Default back to itself because end node
--     was not picked correctly.」——
--     ★★★ 这是「找不到就退化为原地传送」的兜底。
--       玩家从 A 点进、从 A 点出（什么都没变）而不是卡死。
--     ★ 一个刻意的 graceful degradation。
local function DoCharlieResidueMapAction(act, target, charlieresidue, residue_context)
--★★ DoCharlieResidueMapAction 内部（2989-3027）的两个对称分支。
--   ★★ 2993 的 wormhole 分支与 3006 的 tentacle_pillar 分支
--     结构几乎逐行对应，差别仅在：
--     · 搜索用的 must tags（2995 / 3008）
--     · 3016-3019 的 Overtake（唤醒沉睡的触手柱）
--   ★★ 3002/3015 两处相同的兜底注释值得逐字读：
--     「默认回到自己，因为终点没有被正确选中。」
--     ★★★ 即「找不到出口就原地传送」—— graceful degradation。
    if residue_context == CHARLIERESIDUE_MAP_ACTIONS.WORMHOLE then
        local residuetarget = charlieresidue:GetTarget()
        local pt = act:GetActionPoint()
		if residuetarget:HasTag("wormhole") then
			local teleporterexit = nil
			local wormholes = TheSim:FindEntities(pt.x, pt.y, pt.z, TUNING.SKILLS.WINONA.WORMHOLE_DETECTION_RADIUS, WORMHOLE_MUST_TAGS)
			for _, wormhole in ipairs(wormholes) do
--★★ DoCharlieResidueMapAction 的 wormhole 分支（2993-3014）内部：
--   ①2995      在 WORMHOLE_DETECTION_RADIUS 内找所有 wormhole
--   ②2996-3001 遍历，取第一个「有 teleporter 且不是我」的
--   ③3002      兜底：找不到就用自己
--   ④3003      GoToState("jumpin", {teleporter, teleporterexit})
--   ⑤3004      DecayCharlieResidueIfItExists（残留物消失）
--   ★★★ ②的 `wormhole ~= residuetarget` 排除：
--     ★ 不能「从自己传送到自己」。
--   ★★ ③的兜底让「只找到一个虫洞」时传送退化为原地。
				if wormhole.components.teleporter and wormhole ~= residuetarget then
					teleporterexit = wormhole
					break
				end
			end
			teleporterexit = teleporterexit or target -- Default back to itself because end node was not picked correctly.
			act.doer.sg:GoToState("jumpin", { teleporter = target, teleporterexit = teleporterexit })
			DecayCharlieResidueIfItExists(act.doer)
			return true
		elseif residuetarget.prefab == "tentacle_pillar_hole" then
			local teleporterexit = nil
			local wormholes = TheSim:FindEntities(pt.x, pt.y, pt.z, TUNING.SKILLS.WINONA.WORMHOLE_DETECTION_RADIUS, TENTACLE_PILLAR_MUST_TAGS)
--★★ tentacle_pillar 分支（3006-3023）的遍历：
--   ★★ 与 2996-3001 逐行对称，只是 must tags 换成 TENTACLE_PILLAR。
--   ★★ 3016-3019 多了一步 Overtake（唤醒沉睡的触手柱）。
			for _, wormhole in ipairs(wormholes) do
				if wormhole.components.teleporter and wormhole ~= residuetarget then
					teleporterexit = wormhole
					break
				end
			end
			teleporterexit = teleporterexit or target -- Default back to itself because end node was not picked correctly.
--★ 沉睡的触手柱要先 Overtake()（唤醒成实体形态）才能当出口。
--   ★★ 3018 行 `teleporterexit:Overtake() or teleporterexit` ——
--     ★ or 兜底：唤醒失败就用原实体。
			if teleporterexit.prefab == "tentacle_pillar" then
				--If asleep, the exit is instantly converted to hole and returned
				teleporterexit = teleporterexit:Overtake() or teleporterexit
			end
			act.doer.sg:GoToState("jumpin", { teleporter = target, teleporterexit = teleporterexit })
			DecayCharlieResidueIfItExists(act.doer)
			return true
		end
	end
--★★ 3025 行：条件都不满足 → 「让残留物消失并进入冷却」+ return false。
--   ★★ DecayCharlieResidueAndGoOnCooldownIfItExists —— 玩家点错了地方，
--     章鱼残留物会消失并冷却一段时间（防止反复尝试刷传送）。
--   ★★★ 「点错也消耗资源」是一个常见的设计：让玩家谨慎。
--   ★ 与 3004/3021 行的 DecayCharlieResidueIfItExists（成功时）对比：
--     成功 → 只消失；失败 → 消失 + 冷却。
	DecayCharlieResidueAndGoOnCooldownIfItExists(act.doer)
	return false
end
--★★ JUMPIN_MAP.fn —— 30 行，与 JUMPIN.fn（2969）的差异：
--   ★★ ① 3033-3038 行要解包「残留物 → 真正的目标」这一层 indirection
--   ★★ ② 3040 行区分「走残留物路径」还是「普通虫洞路径」
--   ★★★ 3037 行的 `target = target and target:IsValid() and target or nil`
--     是一个防 nil 的三段式 —— 若 target 无效则置 nil。
ACTIONS.JUMPIN_MAP.fn = function(act)
    if act.doer ~= nil and act.doer.sg ~= nil and act.doer.sg.currentstate.name == "jumpin_pre" then
        local target = act.target
        local charlieresidue = nil
        local residue_context = CHARLIERESIDUE_MAP_ACTIONS.NONE
        if target ~= nil and target.prefab == "charlieresidue" then
            charlieresidue = target
            residue_context = target:GetMapActionContext()
            target = target:GetTarget()
            target = target and target:IsValid() and target or nil
        end
        if target ~= nil and target.components.teleporter ~= nil and target.components.teleporter:IsActive() then
            if residue_context > CHARLIERESIDUE_MAP_ACTIONS.NONE then
                if not DoCharlieResidueMapAction(act, target, charlieresidue, residue_context) then
                    act.doer.sg:GoToState("idle")
                end
            else
                act.doer.sg:GoToState("jumpin", {teleporter = target,})
            end
            return true
        end
        act.doer.sg:GoToState("idle")
    end
end

--★ TELEPORT.strfn —— 「传送到城镇」固定词。
ACTIONS.TELEPORT.strfn = function(act)
    return act.target ~= nil and "TOWNPORTAL" or nil
end

--★★ TELEPORT.fn —— 「复用已有状态」的典范（§2 433 行已预告）。
--   ★★ 3061 行检查 sg 处于 **dolongaction**（长动作中）：
--     ★★★ 这个状态是「玩家正在播放长动作」的通用态。
--       传送作为「长动作的一种」搭了它的便车。
--     ★ 3065 行检查 sg 处于 **give**（送礼中）：
--       「把传送物品给别人」被编码成送礼动作的变体。
--   ★★★ 三个动作（dolongaction / give / jumpin_pre）被借用，
--     说明这些状态是**通用容器**，而非某个动作的私有状态。
--   ★★ 3068 行的 teleporter 标签检查是最后一道守卫。
ACTIONS.TELEPORT.fn = function(act)
    if act.doer ~= nil and act.doer.sg ~= nil then
        local teleporter
        if act.invobject ~= nil then
            if act.doer.sg.currentstate.name == "dolongaction" then
                teleporter = act.invobject
            end
        elseif act.target ~= nil
            and act.doer.sg.currentstate.name == "give" then
            teleporter = act.target
        end
        if teleporter ~= nil and teleporter:HasTag("teleporter") then
            act.doer.sg:GoToState("entertownportal", { teleporter = teleporter })
            return true
        end
    end
end

--★ RESETMINE.fn —— 两行转发（地雷重置）。
ACTIONS.RESETMINE.fn = function(act)
    if act.target.components.mine ~= nil then
        act.target.components.mine:Reset()
        return true
    end
end

--★★★ ACTIVATE.fn —— 「最泛用动作」的实现（13 行）。
--   ★★ 3084 行的前置：目标有 activatable 组件，
--     ★★ 且目标**不在燃烧也不在冒烟**：
--       `burnable == nil or not (IsSmoldering() or IsBurning())`
--     ★★★ 为什么要排除着火的目标？
--       「激活」通常意味着「开启使用」，而一个正在燃烧的物体
--       不应该被激活（如烧着的门、烧着的机器）。
--   ★★ 3086-3092 行的 CanActivate → DoActivate 两段式：
--     3087-3089  CanActivate 返回 **false** 时才失败（=== false 而非 not）
--     ★★★ 注意是 `success == false` 不是 `not success`！
--       ⇒ CanActivate 返回 nil 时**不失败**，继续执行 DoActivate。
--       这是刻意的宽松（对比 3091 行「for legacy reasons, nil will be true」）。
--       ★★★ 「三态容忍」在本文件里反复出现，是很典型的兼容策略。
--   ★★ 3091 行返回 `(success ~= false)` —— 同样的「nil 算成功」。
--   ★★ 与 6918-6923 行 SWAPBODIES_MAP.fn 的写法完全一致 ——
--     同一个模式在两个文件区域重复。
ACTIONS.ACTIVATE.fn = function(act)
    
    if act.target.components.activatable ~= nil and (act.target.components.burnable == nil or not (act.target.components.burnable:IsSmoldering() or act.target.components.burnable:IsBurning())) then

        local success, msg = act.target.components.activatable:CanActivate(act.doer)
        if success == false then
            return false, msg        
        else
            success, msg = act.target.components.activatable:DoActivate(act.doer)
            return (success ~= false), msg -- note: for legacy reasons, nil will be true
        end
    end
end

--★★ ACTIVATE.strfn —— 委托给实体的 GetActivateVerb。
--   ★★ 3097 行检查 `act.target.GetActivateVerb ~= nil` 而非 components ——
--     ★★★ 因为这个方法挂在 prefab 的实例上（inst 方法），不是组件上。
--     ★ 与 TRAVEL 的 travel_action_fn 同型（§p5 2109 行）。
ACTIONS.ACTIVATE.strfn = function(act)
    if act.target.GetActivateVerb ~= nil then
        return act.target:GetActivateVerb(act.doer)
    end
end

--★ ACTIVATE.stroverridefn —— OverrideActivateVerb（完全覆盖）。
--   ★★ 与 strfn 的区别：strfn 只给修饰词（会拼目标名），
--     stroverridefn 给完整字符串（不拼目标名）。见 p3 498 行的说明。
ACTIONS.ACTIVATE.stroverridefn = function(act)
    if act.target.OverrideActivateVerb ~= nil then
        return act.target:OverrideActivateVerb(act.doer)
    end
end


--★ OPEN_CRAFTING.strfn —— 从 PROTOTYPER_DEFS 查动作词。
--   ★★ 3111 行用 prefab 名查表 —— 「制作台按 prefab 配置显示词」。
ACTIONS.OPEN_CRAFTING.strfn = function(act)
	local target = act.target
	if target ~= nil and PROTOTYPER_DEFS[target.prefab] ~= nil then
		return PROTOTYPER_DEFS[target.prefab].action_str
	end
end

--★★ OPEN_CRAFTING.fn —— 「隐藏的原型台」处理（9 行）。
--   ★★ 3119-3120 行：
--       prototyper = (target.prototyper.redirect_to_prototyper) or target
--   ★★★ 两层含义：
--     ① `target:HasTag("hideprototyperaction")` → 整个动作不出现
--       （如某些「装饰用的假制作台」）
--     ② 否则，若组件有 redirect_to_prototyper → 打开**别处的**制作台
--       （如韦伯的「便携制作台」可能转到主角色台？）
--   ★★ 3122 行 `return ...UsePrototyper(prototyper)` 且 3124 行兜底 false。
--     注意 3122 是 return，3124 的 false 只有 prototyper 为 nil 时到达。
ACTIONS.OPEN_CRAFTING.fn = function(act)
    if act.doer and act.doer.components.builder then
        local prototyper = nil
        if act.target and not act.target:HasTag("hideprototyperaction") then
            prototyper = (act.target.components.prototyper and act.target.components.prototyper.redirect_to_prototyper) or act.target
        end
        return act.doer.components.builder:UsePrototyper(prototyper)
    end
	return false
end

--★ CAST_POCKETWATCH.strfn —— FunctionOrValue 工具的用法。
--   ★★ 3129 行 `FunctionOrValue(fn, self, doer, target)` ——
--     ★★★ 这是 DST 处理「字段可以是函数也可以是值」的通用惯例。
--       避免每个 prefab 都写一个 `if type(f) == "function"`。
--     ★ 全文件出现 2 次（3129/3161/3163/3794）。
ACTIONS.CAST_POCKETWATCH.strfn = function(act)
    if act.invobject ~= nil then
        return FunctionOrValue(act.invobject.GetActionVerb_CAST_POCKETWATCH, act.invobject, act.doer, act.target)
    end
end

--★ CAST_POCKETWATCH.fn —— 施法。pocketwatchcaster 标签守卫。
ACTIONS.CAST_POCKETWATCH.fn = function(act)
    local caster = act.doer
    if act.invobject ~= nil and caster ~= nil and caster:HasTag("pocketwatchcaster") then
		return act.invobject.components.pocketwatch:CastSpell(caster, act.target, act:GetActionPoint())
	end
end

--★★ HAUNT.fn —— 「附身」，七条件准入。
--   ★★ 六个否定条件：
--     ① target 无效                     → 不能
--     ② target 在 limbo（即将被删）      → 不能
--     ③ 没有 hauntable 组件              → 不能
--     ④ 是被别人拿着的物品              → 不能
--     ⑤ 有 haunted 或 catchable 标签    → 已被附身/可被抓
--   ★★ 3147 行先推 haunt 事件再调 DoHaunt —— 与 2679/3169 同款「事件先行」。
ACTIONS.HAUNT.fn = function(act)
    if act.target ~= nil and
        act.target:IsValid() and
        not act.target:IsInLimbo() and
        act.target.components.hauntable ~= nil and
        not (act.target.components.inventoryitem ~= nil and act.target.components.inventoryitem:IsHeld()) and
        not (act.target:HasTag("haunted") or act.target:HasTag("catchable")) then
        act.doer:PushEvent("haunt", { target = act.target })
        act.target.components.hauntable:DoHaunt(act.doer)
        return true
    end
end

--★★★【MURDER.fn —— 完整的「处决」流程（41 行）】
--   ★★ 七步流程：
--     ① 3154-3155  取出对象（invobject 或 target）
--     ② 3156-3158  从背包取出并移到执行者位置
--     ③ 3160-3164  播放 murder 音效（health 或 murderable 组件）
--     ④ 3168-3170  推 murdered + killed 事件（★ 顺序有讲究，见下）
--     ⑤ 3172-3184  生成战利品（按堆叠数循环）
--     ⑥ 3186-3188  转移目标背包
--     ⑦ 3190       移除目标
--   ★★★ 与 FEED.fn（3771）的分支对比：
--     FEED 的处决流程写在 3779-3821，但**只有 owner ~= nil 时**才 Remove。
--     MURDER 无条件 Remove。
--     ★ 差异原因：MURDER 是「主动杀」，对象从背包取出后已无归属；
--       FEED 的对象还在背包里，要先判断是否还在。
ACTIONS.MURDER.fn = function(act)
    local murdered = act.invobject or act.target
    if murdered ~= nil and (murdered.components.health ~= nil or murdered.components.murderable ~= nil) then
        local x, y, z = act.doer.Transform:GetWorldPosition()
		murdered = murdered.components.inventoryitem:RemoveFromOwner(true, true) or murdered
        murdered.Transform:SetPosition(x, y, z)

        if murdered.components.health ~= nil and murdered.components.health.murdersound ~= nil then
            act.doer.SoundEmitter:PlaySound(FunctionOrValue(murdered.components.health.murdersound, murdered, act.doer))
        elseif murdered.components.murderable ~= nil and murdered.components.murderable.murdersound ~= nil then
            act.doer.SoundEmitter:PlaySound(FunctionOrValue(murdered.components.murderable.murdersound, murdered, act.doer))
        end

        local stacksize = murdered.components.stackable ~= nil and murdered.components.stackable:StackSize() or 1

--★★ 保留的英文注释「Push the events before spawning any giving any loot.」
--   ★★★ 这是一条**顺序约束**：事件先于战利品。
--     原因：监听 killed 的系统（如成就、任务、统计）会在回调里
--     读取目标的状态。若战利品已生成，目标的 lootdropper 可能已被消费，
--     统计就会算错。
--     ★ 这是「事件驱动系统对执行顺序的隐式要求」，非常容易在重构时破坏。
        -- NOTES(JBK): Push the events before spawning any giving any loot.
        act.doer:PushEvent("murdered", { victim = murdered, stackmult = stacksize })
        act.doer:PushEvent("killed", { victim = murdered, stackmult = stacksize })

--★★★ 3175 行的 `for i = 1, stacksize` —— 「一整堆全杀」。
--   ★★★ 杀掉 10 个浆果就要生成 10 次战利品。
--     ★ 3173 行 causeofdeath = doer —— 「谁杀的」必须记录，
--       用于死亡归属（如韦伯的罪业系统、骷髅的复仇）。
--   ★★ 3174 行的 `local pos = Vector3(x, y, z)` 与 3156 行的 x,y,z 重复取值，
--     纯性能考量（避免在循环里反复解包）。
        if murdered.components.lootdropper ~= nil then
            murdered.causeofdeath = act.doer
            local pos = Vector3(x, y, z)
            for i = 1, stacksize do
                local loots = murdered.components.lootdropper:GenerateLoot()
                for k, v in pairs(loots) do
                    local loot = SpawnPrefab(v)
                    if loot ~= nil then
                        act.doer.components.inventory:GiveItem(loot, nil, pos)
                    end
                end
            end
        end

--★ drop_inventory_onmurder 标签：被杀时倒出背包。
--   ★★ 与 PICKUP.fn 924 行的 drop_inventory_onpickup 对称。
        if murdered.components.inventory and murdered:HasTag("drop_inventory_onmurder") then
            murdered.components.inventory:TransferInventory(act.doer)
        end

        murdered:Remove()
        return true
    end
end

--★★ HEAL.strfn —— 「治自己 vs 治别人」的三态显示。
--   ★★ 3196 行的 `isself` 同样依赖 TheInput:ControllerAttached()，
--     与 SHAVE.strfn（2813 行）同款。
--   ★★ 3198 行的 cannotheal 标签让「不能治」的对象也显示动词（USE/SELF）——
--     ★★★ 这是「让玩家点了才知道不行」而不是「不显示」：
--       隐藏动作会让玩家困惑「为什么这个不能治」。
--     ★ 显示但点了报错，是更好的 UX。
ACTIONS.HEAL.strfn = function(act)
    local isself = (act.target == nil or act.target == act.doer) and TheInput:ControllerAttached()
    local target = act.target or act.doer
    if target ~= nil and target:HasTag("cannotheal") then
        return isself and "USEONSELF" or "USE"
    end
    return isself and "SELF" or nil
end

--★★ HEAL.fn —— 两个治疗组件分支。
--   ★★ 3206 行的三重否定：
--       target 有 health 组件 且 未死 且 不是 playerghost
--     ★★ playerghost 排除的原因：幽灵没有 health 组件，
--       但为了让 `not (IsDead() or HasTag("playerghost"))` 表达
--       「不能给已经死亡的东西治疗」，显式列出。
--   ★★ healer 分支传两个参数，maxhealer 分支只传一个 ——
--     ★ 又一个「看起来一样实则不同」的签名差异（与 2825 行的 Shave 同类）。
ACTIONS.HEAL.fn = function(act)
    local target = act.target or act.doer
    if target ~= nil and act.invobject ~= nil and target.components.health ~= nil and not (target.components.health:IsDead() or target:HasTag("playerghost")) then
        if act.invobject.components.healer ~= nil then
            return act.invobject.components.healer:Heal(target, act.doer)
        elseif act.invobject.components.maxhealer ~= nil then
            return act.invobject.components.maxhealer:Heal(target)
        end
    end
end

--★ UNLOCK.fn —— 3219-3221 行的注释块是被移除的「重新上锁」功能。
--   ★★ 保留了注释，说明「锁」的接口设计考虑了对称性，但只用了一半。
ACTIONS.UNLOCK.fn = function(act)
    if act.target.components.lock ~= nil then
        if act.target.components.lock:IsLocked() then
            act.target.components.lock:Unlock(act.invobject, act.doer)
        --else
            --act.target.components.lock:Lock(act.doer)
        end
        return true
    end
end

--★ USEKLAUSSACKKEY.fn —— T2 模板的干净样本（9 行）。
ACTIONS.USEKLAUSSACKKEY.fn = function(act)
    if act.target.components.klaussacklock ~= nil then
        local able, reason = act.target.components.klaussacklock:UseKey(act.invobject, act.doer)
        if not able then
            return false, reason
        end
        return true
    end
end

--★ TEACH.strfn —— 四个标签对应四个动词。
ACTIONS.TEACH.strfn = function(act)
    return
        act.invobject ~= nil and (
            (act.invobject:HasTag("scrapbook_note") and "NOTES") or
            (act.invobject:HasTag("scrapbook_data") and "SCRAPBOOK") or
			(act.invobject:HasTag("mapspotrevealer") and "READ") or
			(act.invobject:HasTag("recipescanner") and "SCAN") or
            nil
        )
end

--★★ TEACH.fn —— 五个组件分支，其中两个带特殊返回处理。
--   ★★ 3255-3259 行的 maprecorder 分支：
--       if success or reason == "BLANK" then return true
--   ★★★ 「BLANK」（空白纸）被当作成功 ——
--     ★ 因为「在空白纸上写地图」确实是个成功的动作，只是没内容可写。
--     ★ 但失败原因仍被吞掉（不 return reason）。
--   ★★ 3260-3265 行的 mapspotrevealer 分支有一个**副作用顺序问题**：
--       3262 行的 postreveal 在 3261 行的 RevealMap **之后**立即调用，
--       而不管 RevealMap 是否成功。
--     ★ 若 RevealMap 失败（success=false），postreveal 仍会跑。
--       取决于 postreveal 的实现 —— 若它负责「消耗物品」，
--       则会出现「没揭示成功但物品被消耗」。
--     ★ 记录为 L 类隐患（依赖 mapspotrevealer.postreveal 的实现细节）。
ACTIONS.TEACH.fn = function(act)
    if act.invobject ~= nil then
        local target = act.target or act.doer
        if act.invobject.components.scrapbookable ~= nil then
            return act.invobject.components.scrapbookable:Teach(act.doer)
        elseif act.invobject.components.teacher ~= nil then
            return act.invobject.components.teacher:Teach(target)
        elseif act.invobject.components.maprecorder ~= nil then
            local success, reason = act.invobject.components.maprecorder:TeachMap(target)
            if success or reason == "BLANK" then
                return true
            end
            return success, reason
		elseif act.invobject.components.mapspotrevealer ~= nil then
			local success, reason = act.invobject.components.mapspotrevealer:RevealMap(act.doer)
            if act.invobject.components.mapspotrevealer.postreveal then
                act.invobject.components.mapspotrevealer.postreveal(act.invobject)
            end
			return success, reason
		elseif act.invobject.components.recipescanner then
			return act.invobject.components.recipescanner:Scan(target, act.doer)
        end
    end
end

--★ TURNON.fn —— T4「用状态控制可用性」的样本（7 行）。
--   ★★ `tar = act.target or act.invobject` —— T7 模板的又一次使用。
--     ★「开关自己的手持物」（如灯的开关）是常见需求。
ACTIONS.TURNON.fn = function(act)
    local tar = act.target or act.invobject
    if tar and tar.components.machine and not tar.components.machine:IsOn() then
        tar.components.machine:TurnOn(tar)
        return true
    end
end

--★ TURNOFF.strfn —— EMERGENCY 变体（有紧急模式标签）。
ACTIONS.TURNOFF.strfn = function(act)
    local tar = act.target
    return tar ~= nil and tar:HasTag("hasemergencymode") and "EMERGENCY" or nil
end

--★ TURNOFF.fn —— TURNON 的严格镜像（IsOn 为真时才执行）。
ACTIONS.TURNOFF.fn = function(act)
    local tar = act.target or act.invobject
    if tar and tar.components.machine and tar.components.machine:IsOn() then
        tar.components.machine:TurnOff(tar)
        return true
    end
end

--★★★【USEITEM.fn —— 「使用手持物」的两分支（20 行）】
--   ★★ 两个组件：
--     ① toggleableitem → ToggleItem（可开关的物品）
--     ② useableitem     → StartUsingItem（一次性使用的物品）
--   ★★ ② 分支里的 3303-3304 行保留英文注释解释了一个 hack：
--     「因为 USEITEM 是 instant 动作，而 useableitem 很可能强制改状态
--       （那很糟！），所以做了这个变通。」
--   ★★★ 「instant 动作不该改状态图」这条规则被明确写了出来。
--     ★ 但 useableitem 又必须改状态（用它才能生效）—— 于是妥协：
--       3305 行设 `statemem.is_going_to_action_state = true` 作为「预告」，
--       3308 行立刻清掉（注释说「万一没发生状态改变」）。
--     ★★★ 这是「用临时状态位协调两个系统」的典型手法。
ACTIONS.USEITEM.fn = function(act)
    if act.invobject ~= nil then
        if  act.invobject.components.toggleableitem ~= nil and 
            act.invobject.components.toggleableitem:CanInteract(act.doer) then
            local ret = act.invobject.components.toggleableitem:ToggleItem(act.doer)
            return ret
--★★★⚠ 可疑处：`act.doer.components.inventory:IsOpenedBy(act.doer)`
--   ★★★ 核对 inventory.lua:2015：
--       function Inventory:IsOpenedBy(guy)
--           return self.isopen and self.isvisible and guy == self.inst
--     传入自己 ⇒ 判断「自己的背包是否开着且可见」。
--     玩家的背包默认**不处于打开状态**（物品栏总是可见但 isopen 为假），
--     所以这个条件对普通玩家几乎恒为假。
--   ★★ 推测的原意（三选一，都更合理）：
--     · `GetOpenContainer() ~= nil`  —— 「手里拿着东西」
--       （与 3374 行 USEEQUIPPEDITEM.fn 里的同样写法对照，
--         两处一致 ⇒ 不像笔误，而是同样的误解）
--     · `not inventory:HasOpenContainer()` —— 「没开着箱子」
--   ★★★ 后果：useableitem 组件的物品（草、浆果这类「拿到就用」）
--     可能无法被使用。
--   ★★ 归类为**疑似逻辑缺陷**：写法自洽、处处一致，
--     但语义上像是把 IsOpenedBy 当成了「有没有拿着东西」来判断。
--     ★ 若如此，正确的 API 是 inventory:GetActiveItem() ~= nil
--       或 GetOpenContainer()。
--     ★ 记录为 L14。**无法从静态代码确定玩家影响**，
--       需要运行时验证。只记录不修改。
        elseif act.invobject.components.useableitem ~= nil and
            act.invobject.components.useableitem:CanInteract(act.doer) and
            act.doer.components.inventory ~= nil and
            act.doer.components.inventory:IsOpenedBy(act.doer) and not act.invobject:HasTag("cannotuse") then
    		--V2C: kinda hack since USEITEM is instant action, and the useableitem will
    		--     liklely force state change (bad!) instead.
    		act.doer.sg.statemem.is_going_to_action_state = true
    		local ret = act.invobject.components.useableitem:StartUsingItem(act.doer)
    		--And clear it now in case no state change happened
    		act.doer.sg.statemem.is_going_to_action_state = nil
    		return ret
        end
    end
end

--★★ USEITEMON.strfn —— 四级回退的动词选择。
--   ★★ 3316 行 `act.invobject == nil and "GENERIC"` ——
--     ★★★ 注意这条在最前面：**没有手持物时直接返回 GENERIC**，
--       后面的 or 链全部短路。
--     ★ 但 3338 行的 fn 里同样处理了 invobject == nil 的情况
--       （3340 行 `act.target or invobject:HasTag(...)`）——
--       ★★★ 矛盾：strfn 假设 invobject 必非 nil，fn 却做了 nil 保护。
--       说明 fn 更 defensive。这是 strfn/fn 逻辑不同步的一个实例。
ACTIONS.USEITEMON.strfn = function(act)
	--socketable is available on client
	return (act.invobject == nil and "GENERIC")
		or (act.invobject.GetUseItemOnVerb and act.invobject:GetUseItemOnVerb(act.target, act.doer))
		or (act.invobject.components.socketable and string.upper(act.invobject.components.socketable:GetSocketName()))
		or string.upper(act.invobject.prefab)
end

--★★ USEITEMON.pre_action_cb —— 「关手柄背包 + 清模组移除状态」。
--   ★★ 3322-3336 共 15 行做两件事：
--     ① 3324-3326 关手柄背包 UI（防止挡住目标）
--     ② 3329-3334 若目标是 socketholder（插槽），清掉
--        doer._controller_start_moduleremover
--   ★★ ②的理由（注释没写，但可推断）：
--     「先按住卸模块，再对目标使用」的流程不能同时进行，
--     所以清除那个标志。
--     ★ 这是 UI 状态与游戏状态的一致性维护。
--   ★★ 注释「socketable and socketholder components are available on
--     client」—— 再次强调「能在客户端判断，所以放在 pre_action_cb」。
ACTIONS.USEITEMON.pre_action_cb = function(act)
	if act.doer.HUD and TheInput:ControllerAttached() then
		if act.doer.HUD:IsControllerInventoryOpen() then
			act.doer.HUD:CloseControllerInventory()
		end

		--socketable and socketholder components are available on client
		if act.invobject and act.invobject.components.socketable then
			local target = act.target or (act.invobject:HasTag("useabletargateditem_canselftarget") and act.doer or nil)
			if target and target.components.socketholder then
				act.doer._controller_start_moduleremover = nil
			end
		end
	end
end

--★★ USEITEMON.fn —— 「对目标使用物品」的九行。
--   ★★ 3340 行：
--       `local target = act.target or act.invobject:HasTag(...) and act.doer`
--   ★★★ 这是一行**没有括号的三元混合表达式**，实际解析为：
--       act.target or ((act.invobject:HasTag(...) and act.doer))
--     ★ 而 3340 行的 act.invobject 在此处可能为 nil（见 3316 行的矛盾），
--       `nil:HasTag(...)` 会崩。
--     ★★ 与 2789 行的 CHANGEIN 属同类问题（运算符优先级 + nil 保护缺失）。
--       但这里因为 3316 行的 strfn 已假设非 nil，实际不崩。
--     ★ 记录为 L 类隐患（**依赖 strfn 的隐式保证**）。
--   ★★ 3343-3347 行的返回：`if success then return true else return success, reason`
--     ★ 等价于 `return success, reason`，但保留了分支的意图可读性。
--       属「防御式冗余」。
ACTIONS.USEITEMON.fn = function(act)
    if act.invobject then
        local target = act.target or act.invobject:HasTag("useabletargateditem_canselftarget") and act.doer
        if target and act.invobject.components.useabletargeteditem and act.invobject.components.useabletargeteditem:CanInteract() then
            local success, reason = act.invobject.components.useabletargeteditem:StartUsingItem(target, act.doer)
            if success then
                return true
            else
                return success, reason
            end
        end
    end
end

--★ STOPUSINGITEM.strfn —— 用 prefab 大写名当动词（兜底显示 prefab 名）。
--   ★★★ 这是全文件里最「偷懒」但最有效的 strfn：
--     直接把 prefab 名大写当动词（"PISTOL"、"LANTERN"…）。
--   ★ 好处：任何新物品零成本获得 UI 提示。
--   ★ 缺点：物品改了 prefab 名，UI 就变了（可能正是想要的）。
ACTIONS.STOPUSINGITEM.strfn = function(act)
    return (act.invobject ~= nil and string.upper(act.invobject.prefab))
            or "GENERIC"
end

ACTIONS.STOPUSINGITEM.fn = function(act)
    if act.invobject ~= nil and act.invobject.components.useabletargeteditem ~= nil then
        act.invobject.components.useabletargeteditem:StopUsingItem()
        return true
    end
end

--★ USEEQUIPPEDITEM.strfn —— 与 STOPUSINGITEM 同款（无 GENERIC 兜底）。
--   ★★ 3365 行 `act.invobject and string.upper(act.invobject.prefab)` ——
--     ★ 三元式：invobject 为 nil 时返回 **nil**（不是 GENERIC）。
--     与 3353 行的 `or "GENERIC"` 不同 —— 微小但真实的差异。
ACTIONS.USEEQUIPPEDITEM.strfn = function(act)
	return act.invobject and string.upper(act.invobject.prefab)
end

ACTIONS.USEEQUIPPEDITEM.fn = function(act)
	if act.invobject and
		act.invobject.components.useableequippeditem and
		act.invobject.components.equippable and
		act.invobject.components.equippable:IsEquipped() and
		act.doer.components.inventory and
--★ 3374 行重复了 3299 行的 IsOpenedBy 疑点（同款写法）。
		act.doer.components.inventory:IsOpenedBy(act.doer)
	then
		return act.invobject.components.useableequippeditem:StartUsingItem(act.doer)
	end
end

--★★ 保留的英文注释「same fn, diff str table」——
--   ★★★ 精确描述了 T12 模板的「部分复用」：
--     · fn   不同（StartUsingItem vs StopUsingItem）
--     · strfn 相同（共用 USEEQUIPPEDITEM.strfn）
--   ★★ 这行注释本身就是一份「如何在不抽象的前提下复用」的示范文档。
ACTIONS.STOPUSINGEQUIPPEDITEM.strfn = ACTIONS.USEEQUIPPEDITEM.strfn --same fn, diff str table

ACTIONS.STOPUSINGEQUIPPEDITEM.fn = function(act)
	if act.invobject and act.invobject.components.useableequippeditem then
		return act.invobject.components.useableequippeditem:StopUsingItem(act.doer)
	end
end

--★ TAKEITEM.fn —— 两个分支（shelf 的 cantakeitem 与 inventoryitemholder）。
ACTIONS.TAKEITEM.fn = function(act)
    --Use this for taking a specific item as opposed to having an item be generated as it is in Pick/ Harvest
    if act.target ~= nil and act.target.components.shelf ~= nil and act.target.components.shelf.cantakeitem then
        act.target.components.shelf:TakeItem(act.doer)
        return true

    elseif act.target.components.inventoryitemholder ~= nil then
        return act.target.components.inventoryitemholder:TakeItem(act.doer)
    end
end

--★ TAKEITEM.strfn —— BIRDCAGE 变体 + GENERIC 兜底。
--   ★★ 3400 行 `act.target.prefab` 无 nil 保护 ——
--     ★ 若 act.target 为 nil 会崩。
--     ★ 而 3403 行的 stroverridefn 里（3404 行）也直接访问 act.target，
--       同样无保护。
--     ★ 实践中 TAKEITEM 只在有 inventoryitemholder 的目标上出现，
--       target 必非 nil。属「依赖上游保证」。
ACTIONS.TAKEITEM.strfn = function(act)
    return act.target.prefab == "birdcage" and "BIRDCAGE" or "GENERIC"
end

--★★ TAKEITEM.stroverridefn —— 「显示要拿走的东西的名字」。
--   ★★ 3408-3413 行的三层：
--     ① winter_feast 桌 / 特定标签 → 固定的 GENERIC
--     ② 有 takeitem 字段 → 用它的 GetBasicDisplayName()
--     ③ 是堆叠 → 追加 " x<数量>"
--   ★★★ 「追加数量」是本文件里唯一的动态字符串拼接（3412 行），
--     因为 UI 需要显示「拿 5 个浆果」。
--   ★ 3404 行的 `or (HasTag("inventoryitemholder_take") and takeitem == nil)`
--     ★★★ 是「已知拿不出东西时给通用提示」的兜底。
--     注意 `act.target.takeitem` 在 3404 与 3408 行读法不同
--     （前者裸访问，后者 `~= nil and ... :value()`）——
--     ★ takeitem 是 **network variable**，需要 `:value()` 取值。
--       3404 行的裸访问只能判「字段是否存在」，不能判「值是否为空」。
--       3408 行才正确取值。写法正确但两条路径的可读性差异较大。
ACTIONS.TAKEITEM.stroverridefn = function(act)
	if act.target.prefab == "table_winters_feast" or (act.target:HasTag("inventoryitemholder_take") and act.target.takeitem == nil) then
		return STRINGS.ACTIONS.TAKEITEM.GENERIC
    end

    local item = act.target.takeitem ~= nil and act.target.takeitem:value() or nil
    local str = item ~= nil and item:GetBasicDisplayName() or nil

    if str ~= nil and item.replica.stackable ~= nil and item.replica.stackable:IsStack() then
        str = str.." x"..tostring(item.replica.stackable:StackSize())
    end

    return str ~= nil and subfmt(STRINGS.ACTIONS.TAKEITEM.ITEM, { item = str }) or nil
end

--★ TAKESINGLEITEM.fn —— 与 TAKEITEM 只差一个 false 参数（不拿整堆）。
ACTIONS.TAKESINGLEITEM.fn = function(act)
    if act.target.components.inventoryitemholder ~= nil then
        return act.target.components.inventoryitemholder:TakeItem(act.doer, false)
    end
end

--★ TAKESINGLEITEM.stroverridefn —— 直接返回固定串（不做任何动态拼接）。
--   ★★ 与 3403 行那个 14 行的动态版形成鲜明对比 ——
--     「拿单个」不需要告诉玩家拿的是什么（只有一件，无数量）。
ACTIONS.TAKESINGLEITEM.stroverridefn = function(act)
    return STRINGS.ACTIONS.TAKESINGLEITEM
end

--★ CASTSPELL.strfn —— 用物品自己的 spelltype 字段当动词。
--   ★★ 3429 行 `act.invobject.spelltype` —— 字段而非标签。
--     ★ 物品自己声明「我是什么法术」比用标签更精确。
ACTIONS.CASTSPELL.strfn = function(act)
    return act.invobject ~= nil and act.invobject.spelltype or nil
end

--★★★【CASTSPELL.fn —— 施法（25 行），三道守卫 + 两段调用】
--   ★★ 三道守卫：
--     ① 3437-3439 ITEMMIMIC 反伪装（T3 模板，第 27 次出现）
--     ② 3440-3447 crushitemcast 标签：坐骑中不能施法 + 搬运重物时不能施法
--     ③ 3449-3455 CanCast → CastSpell
--   ★★ 3440 行的 crushitemcast 是「会砸碎施法者」的法术（如炸药棒）。
--   ★★ 3444 行的双重检查有点冗余：
--       `act.doer.components.inventory and act.doer.replica.inventory:IsHeavyLifting()`
--     ★ 前半检查 inventory 组件，后半却用 **replica**。
--     ★ fn 在服务端跑，两种写法都可以 —— 混用显得犹豫。
--     ★ 但也可以解释为「replica 版本更快」（无组件查找开销）。
ACTIONS.CASTSPELL.fn = function(act)
    --For use with magical staffs
    local staff = act.invobject or act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
--★★ CASTSPELL.fn 的三道守卫在 3437-3455。
--   ★★ 守卫①（3437-3439）ITEMMIMIC、
--     守卫②（3440-3447）crushitemcast 的两条限制、
--     守卫③（3449）CanCast。
--   ★★★ 三道守卫的顺序：**反伪装 → 通用限制 → 能力检查**。
--     ★ 与 CAST_AOE.fn（4516）相比，那里 ITEMMIMIC 在 CanCast 之后 ——
--       顺序不一致但无正确性问题。
	local act_pos = act:GetActionPoint()
    if staff and staff.components.spellcaster then
        if ShouldItemMimicBeRevealedFor(staff, act.doer) then
            return false, "ITEMMIMIC"
        end
        if staff:HasTag("crushitemcast") then
            if act.doer.components.rider and act.doer.components.rider:IsRiding() then
                return false
            end
            if act.doer.components.inventory and act.doer.replica.inventory:IsHeavyLifting() then
                return false
            end
        end

        local can_cast, cant_cast_reason = staff.components.spellcaster:CanCast(act.doer, act.target, act_pos)
        if can_cast then
            staff.components.spellcaster:CastSpell(act.target, act_pos, act.doer)
            return true
        else
            return can_cast, cant_cast_reason
        end
    end
end

--★★★⚠⚠⚠ 疑似缺陷 L1（**本文件最严重的一处**）：
--     `if act.doer == nil or not act.doer.components.skilltreeupdater and
--         act.doer.components.skilltreeupdater:IsActivated("walter_camp_wobycourier") then`
--   ★★★★★ 解析（and 优先级高于 or）：
--       act.doer == nil
--         or ( (not act.doer.components.skilltreeupdater)
--              and (act.doer.components.skilltreeupdater:IsActivated(...)) )
--   ★★ 缺陷一（★ 必然崩溃）：若 `skilltreeupdater` 组件不存在，
--     `not nil` 为 true ⇒ 进入 and 的右操作数
--     ⇒ `nil:IsActivated(...)` ⇒ **index a nil value 崩溃**。
--     ★★★ 而这正是**非沃尔特玩家**（没有 skilltreeupdater 组件）
--       打开地图、在某个点上按「直递快递」时的必然路径。
--       ★ 该动作 map_only=true（690 行），任何玩家都能在地图上按到它，
--         只要客户端有技能树数据就会被收集为候选动作。
--   ★★ 缺陷二（★ 语义反转）：即使组件存在，
--     `not component` 为 false ⇒ 整个 and 为 false ⇒ 条件不成立
--     ⇒ **不会** return false。
--     ★★★ 于是「技能未激活」这个检查**完全失效**。
--   ★★ 作者的本意（对照 1025 行的正确写法）应是：
--       if act.doer == nil
--           or act.doer.components.skilltreeupdater == nil
--           or not act.doer.components.skilltreeupdater:IsActivated(...) then
--   ★★★ 1025 行 CanOpenCharacterSpecificContainer 里的韦伯灵魂罐检查
--     写的正是这个三段式 —— **同一个文件里有正确范例**。
--     ★ 这强烈支持「漏写 = `== nil or not`」的判断。
--   ★★ 影响范围：DIRECTCOURIER_MAP 的 strfn（3507）与 fn（3522）都调它，
--     所以地图上的「发快递」提示与执行都受此影响。
--   ★★★ 结论：**真实的、必然触发的缺陷**。只记录不修改。
--     ★ 修复方式只需把 `not X` 改成 `X == nil or not X`。
local DIRECTCOURIER_MAP_MUST = { "CLASSIFIED", "globalmapicon", "globalmapicon_player" }
ACTIONS.DIRECTCOURIER_MAP.maponly_checkvalidpos_fn = function(act)
    if act.doer == nil or not act.doer.components.skilltreeupdater and act.doer.components.skilltreeupdater:IsActivated("walter_camp_wobycourier") then
        return false
    end

    local act_pos = act:GetActionPoint()
    if act_pos == nil then
        return false
    end

    local within_radius = TUNING.SKILLS.WALTER.COURIER_DETECTION_RADIUS
    local within_radiussq = within_radius * within_radius
    local act_posx, act_posz
    local mindsq = math.huge
    local mapent
--★ TryToUpdateNearest —— 「找最近目标」的内部辅助函数（9 行）。
--   ★★ 它是闭包，能访问外层的 mindsq / act_posx / act_posz。
--     ★ 用闭包做「带状态的查找」比返回多个值更简洁。
    local function TryToUpdateNearest(x, z)
        local dx, dz = x - act_pos.x, z - act_pos.z
        local dsq = dx * dx + dz * dz
        if dsq < mindsq and dsq < within_radiussq then
            mindsq = dsq
            act_posx, act_posz = x, z
            return true
        end
        return false
    end
    -- Check for chest first.
--★★ 3485-3489 行：`-- Check for chest first.` 注释说明了顺序的重要性。
--   ★★ 先查箱子再查玩家 —— 若查了玩家，箱子（更常见的用法）会被跳过。
--   ★ 「先查更常见的」是找不到最优时的实用折中。
    local x, z = GetWobyCourierChestPosition(act.doer)
    if x then
        TryToUpdateNearest(x, z)
    end
    -- Now players.
    local ents = TheSim:FindEntities(act_pos.x, act_pos.y, act_pos.z, TUNING.SKILLS.WALTER.COURIER_DETECTION_RADIUS, DIRECTCOURIER_MAP_MUST)
    for _, ent in ipairs(ents) do
--★★ 3493 行的三重过滤：
--   ① `ent.MiniMapEntity:EntityHasRestriction(doer.GUID)` —— 有权限
--   ② `GetDistanceSqToInst(ent) > WOBYCOURIER_MIN_DIST_TO_PLAYER_SQ` —— 不贴脸
--   ★★★ ②的意图：太近的玩家不允许「快递」，否则可以贴脸戏弄。
--   ★ 三次 GetPosition / GetDistanceSqToInst 在循环里 ——
--     每次都在遍历实体做 O(1) 查询，实体数量有限，可接受。
        if ent.MiniMapEntity:EntityHasRestriction(act.doer.GUID) and act.doer:GetDistanceSqToInst(ent) > WOBYCOURIER_MIN_DIST_TO_PLAYER_SQ then
            local x, y, z = ent.Transform:GetWorldPosition()
            if TryToUpdateNearest(x, z) then
                mapent = ent
            end
        end
    end
    -- Valid target checks.
--★★ 3501-3503：找不到任何目标 → `return false, "NOTARGET"`。
--   ★★ 与 3601 行的 BLINK_MAP 同款失败原因名。
--     ★ 说明这是「地图动作找不到目标」的标准原因码。
    if mindsq == math.huge then
        return false, "NOTARGET"
    end

--★★ `return true, nil, act_posx, act_posz, mapent` —— 五元返回。
--   ★★ maponly_checkvalidpos_fn 家族的统一返回契约（§0 T9）：
--     (valid, reason, x, z, entity)
--   ★★★ 把它设计成一个函数给 strfn 与 fn 共用（3508/3523 都调它），
--     杜绝了「UI 说能发、实际发不了」的分裂。
--     ★★ 这是本文件里少见的「单一真源」正确实践。
    return true, nil, act_posx, act_posz, mapent
end
--★ DIRECTCOURIER_MAP.stroverridefn —— 复用同一个校验函数生成动词。
--   ★★★ 3508 行直接调 3460 行的 maponly_checkvalidpos_fn ——
--     完美体现了 T9 的价值。
ACTIONS.DIRECTCOURIER_MAP.stroverridefn = function(act)
    local valid, reason, act_posx, act_posz, mapent = ACTIONS.DIRECTCOURIER_MAP.maponly_checkvalidpos_fn(act)
    if not valid then
        return nil
    end

--★ 3513-3520 行：目标是玩家显示 SEND{target}，否则显示 CHEST。
--   ★★ 3514 行用 prefab == "globalmapiconnamed" 精确判定。
    if mapent then
        local targetname = mapent.prefab == "globalmapiconnamed" and mapent._target_displayname:value() or nil
        if targetname and targetname ~= "" then
            return subfmt(STRINGS.ACTIONS.DIRECTCOURIER_MAP.SEND, {target = targetname})
        end
    end

    return STRINGS.ACTIONS.DIRECTCOURIER_MAP.CHEST
end
--★★ DIRECTCOURIER_MAP.fn —— 20 行，含平台偏移计算。
--   ★★ 3524 行 `local ischest = mapent == nil` 在 valid 检查**之前**：
--     ★ 若 valid 为 false，mapent 为 nil ⇒ ischest = true，
--       但 3526 行已经 return 了，所以无影响。
--     ★ 顺序略乱但无害。
--   ★★ 3535-3539 行的平台偏移：
--       若目标点在船上，platformoffset = 平台位置 - 目标点。
--     ★★★ 这与 locomotor 的 is_relative_to_platform（329 行）是同一概念的
--       手动实现 —— 因为这里不走 locomotor。
--       ★ 同一个概念在两处用两种方式实现，说明地图动作路径缺少统一抽象。
ACTIONS.DIRECTCOURIER_MAP.fn = function(act)
    local valid, reason, act_posx, act_posz, mapent = ACTIONS.DIRECTCOURIER_MAP.maponly_checkvalidpos_fn(act)
    local ischest = mapent == nil
    if not valid then
        return valid, reason
    end

    if not act.doer.components.playercontroller or not act.doer.woby_commands_classified then
        return false
    end

    local act_pos = Vector3(act_posx, 0, act_posz)

    local platform = TheWorld.Map:GetPlatformAtPoint(act_pos.x, act_pos.z)
    local platformoffset
    if platform then
        platformoffset = platform:GetPosition() - act_pos
    end

    act.doer.woby_commands_classified:SendCourierWoby({destpos = act_pos, platform = platform, platformoffset = platformoffset, ischest = ischest,})
    return valid
end

--★★【TryToSoulhop —— 「灵魂跳跃」的前置判定（8 行）】
--   ★★ 四个条件全满足才返回 true：
--     ① doer 非 nil  ② sg 存在  ③ sg 处于 **portal_jumpin_pre** 状态
--     ④ act_pos 非 nil  ⑤ doer.TryToPortalHop 存在
--   ★★★★ 第③条与 2972 行 JUMPIN.fn 的 `jumpin_pre` 是**同一手法**：
--     动作只在状态图的「预备状态」里才真正执行。
--     ★ 这说明「两阶段动作」是本文件里反复出现的通用模式，
--       至少 5 处使用（jumpin / jumpin_map / climb / siton / soulhop）。
--   ★★ `act.distancecount` —— 这个字段在别处由 BLINK_MAP 的 remap 设置
--     （3660 行）。BLINK.fn（3558）调用本函数时该字段为 nil，
--     ⇒ TryToPortalHop(nil, ...) 拿到 nil souls。
--     ★ 推断由 prefabs/wortox.lua:614 的实现兜底。属可接受的松散耦合。
local function TryToSoulhop(act, act_pos, consumeall)
    return act.doer ~= nil
    and act.doer.sg ~= nil
    and act.doer.sg.currentstate.name == "portal_jumpin_pre"
    and act_pos ~= nil
    and act.doer.TryToPortalHop ~= nil
    and act.doer:TryToPortalHop(act.distancecount, consumeall)
end

--★ BLINK.strfn —— FREESOUL / SOUL 两态，由 _freesoulhop_counter 决定。
--   ★★ 3555 行的 `(act.doer._freesoulhop_counter or 0) > 0` ——
--     ★★★ doer 上的下划线前缀字段：`_` 开头是 DST 的约定，
--       表示「内部状态，不要从外部改」。
--     ★ 全文件大量使用（_freesoulhop_counter / _controller_start_moduleremover
--       / _freesoulhop_counter 等），是一个**软约定**（无语言强制）。
ACTIONS.BLINK.strfn = function(act)
    return act.invobject == nil and act.doer ~= nil and act.doer:HasTag("soulstealer") and ((act.doer._freesoulhop_counter or 0) > 0 and "FREESOUL" or "SOUL") or nil
end

--★★【BLINK.fn —— 韦伯闪现的两分支（19 行）】
--   ★★ 分支①：手持闪烁法杖 ⇒ blinkstaff:Blink(点, doer)
--   ★★ 分支②：空手 ⇒ TryToSoulhop（3545 行）成功则跳状态
--     ★★ 3567 行的第三个参数：
--       `act.doer.components.inventory and IsHeavyLifting() or false`
--       ★★★ 这就是 consumeall 参数：「负重时是否消耗全部灵魂」。
--         推断：负重时若还保留灵魂会「没动」，所以全部消耗以保证位移。
--         ★ 这是一个「用惩罚保证成功率」的设计。
--   ★★ 3573 行的 GoToState 参数与 3598 行几乎相同，
--     差别只是后者多了 `from_map = true`。
--     ★★★ 这个 flag 让状态图知道「这次传送来自地图」，
--       从而播放不同的过场（地图传送不应有角色的施法动画）。
ACTIONS.BLINK.fn = function(act)
	local act_pos = act:GetActionPoint()
    if act.invobject ~= nil then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
        if act.invobject.components.blinkstaff ~= nil then
            return act.invobject.components.blinkstaff:Blink(act_pos, act.doer)
        end
    elseif TryToSoulhop(act, act_pos, act.doer.components.inventory and act.doer.components.inventory:IsHeavyLifting() or false) then
        local platform = TheWorld.Map:GetPlatformAtPoint(act_pos.x, act_pos.z)
        local platformoffset
        if platform then
            platformoffset = platform:GetPosition() - act_pos
        end
        act.doer.sg:GoToState("portal_jumpin", {dest = act_pos, platform = platform, platformoffset = platformoffset,})
        return true
    end
end

--★ BLINK_MAP.stroverridefn —— 显示所需灵魂数。
ACTIONS.BLINK_MAP.stroverridefn = function(act)
    return act.invobject == nil and act.doer ~= nil and act.doer:HasTag("soulstealer") and subfmt(STRINGS.ACTIONS.BLINK_MAP.SOUL, { souls = act.distancecount, }) or nil
end

--★ ActionCanMapSoulhop —— 「地图跳跃够不够灵魂」的判定（6 行）。
--   ★★ 3585 行 `act.doer:CanSoulhop(act.distancecount)` ——
--     ★ distancecount 由 remap（3660 行）预先算好。
--     ★★★ ⇒ 本函数**依赖 remap 已经跑过**。
--       在 3592 行 BLINK_MAP.fn 里调用顺序正确（先 ActionCanMapSoulhop 再 remap），
--       在 3662 行 remap 内部调用时 distancecount 也已设置（3660 行在前）。
--       ★ 顺序正确，但这是隐式契约。
local function ActionCanMapSoulhop(act)
    if act.invobject == nil and act.doer and act.doer.CanSoulhop then
        return act.doer:CanSoulhop(act.distancecount)
    end
    return false
end

--★★★【BLINK_MAP.fn —— 带一条关键英文注释（13 行）】
--   ★★ 3590 行的保留注释：
--     「NOTES(JBK): 这目前只支持灵魂跳跃，因为存在理论上的无限距离。」
--   ★★★ 这条注释解释了为什么 BLINK_MAP 不能用法杖（blinkstaff）传送：
--     地图坐标可以是世界任何位置 ⇒ 距离无上限 ⇒ blinkstaff 的
--     距离限制机制无法适用。
--     ★★★ 「明确说出被砍掉的功能与原因」—— 这是极好的注释习惯。
ACTIONS.BLINK_MAP.fn = function(act)
    -- NOTES(JBK): This only supports soul hopping for now due to the theoretical infinite range.
    local act_pos = act:GetActionPoint()
    if ActionCanMapSoulhop(act) and TryToSoulhop(act, act_pos, true) then
        local platform = TheWorld.Map:GetPlatformAtPoint(act_pos.x, act_pos.z)
        local platformoffset
        if platform then
            platformoffset = platform:GetPosition() - act_pos
        end
        act.doer.sg:GoToState("portal_jumpin", {dest = act_pos, platform = platform, platformoffset = platformoffset, from_map = true,})
        return true
    end
end

--★★★【ACTIONS_MAP_REMAP[ACTIONS.BLINK.code] —— 地图重映射的 63 行】
--   ★★ 它是本文件最长的地图重映射函数，做六件事：
--     ① 3609-3640  无地形格时的瞄准辅助（找 boat 上的 fogrevealer）
--     ② 3641        计算距离
--     ③ 3642        构造替代动作 act_remap
--     ④ 3643-3654   计算「每跳能走多远」与「需要几跳」
--     ⑤ 3656-3661   把计算结果挂到 act_remap 上（供 UI 读取）
--     ⑥ 3662-3664   灵魂不够就返回 nil
--   ★★ 3630 行 `if revealer._target ~= nil then` 注释「Server only code.」
--     ★★★ remap 函数**在客户端与服务端都会跑**，
--       而 _target 只在服务端存在 ⇒ 客户端走不进这个分支。
--       ★ 这意味着客户端算出的 targetpos 与服务端可能不同，
--         但服务端会自行修正（注释 3626-3627 明确说了这点）。
--       ★★★ 「客户端预测 + 服务端修正」的标准模式。
local BLINK_MAP_MUST = { "CLASSIFIED", "globalmapicon", "fogrevealer" }
ACTIONS_MAP_REMAP[ACTIONS.BLINK.code] = function(act, targetpos)
    local doer = act.doer
    if doer == nil then
        return nil
    end
--★ 3609 行 `not IsAboveGroundAtPoint(...)` —— 「光标处没有地图格」。
--   ★★ 注释（3612-3613 行）解释了原因：「船上可能有 maprevealer 组件，
--     即使该处没有地图格也可能是可行区域。」
    local aimassisted = false
    local distoverride = nil
    if not TheWorld.Map:IsAboveGroundAtPoint(targetpos.x, targetpos.y, targetpos.z) then
        -- NOTES(JBK): No map tile at the cursor but the area might contain a boat that has a maprevealer component around it.
        -- First find a globalmapicon near here and look for if it is from a fogrevealer and assume it is on landable terrain.
        local ents = TheSim:FindEntities(targetpos.x, targetpos.y, targetpos.z, PLAYER_REVEAL_RADIUS * 0.4, BLINK_MAP_MUST)
        local revealer = nil
--★ MAX_WALKABLE_PLATFORM_DIAMETERSQ = MAX_WALKABLE_PLATFORM_RADIUS² × 4。
--   ★★ 注释说明「半径的 4 倍 = 直径」。
--   ★★★ 于是这个变量名叫 DIAMETER 但存的是**直径的平方**。
--     名字里的 SQ 后缀是对的唯一提示。
        local MAX_WALKABLE_PLATFORM_DIAMETERSQ = TUNING.MAX_WALKABLE_PLATFORM_RADIUS * TUNING.MAX_WALKABLE_PLATFORM_RADIUS * 4 -- Diameter.
        for _, v in ipairs(ents) do
--★★ 3618 行 `if doer:GetDistanceSqToInst(v) > MAX_... then` —— 反直觉的「忽略近的」。
--   ★★ 保留的注释给出了理由：「忽略近处的船，因为瞄准辅助的范围非常大。」
--   ★★★ 逻辑：附近（屏幕上很近）的**自己的**船不该成为目标，
--     因为玩家不是在传送，而是在传送前就站在船上。
--   ★ 「太近反而忽略」的思路与 3493 行的 WOBYCOURIER_MIN_DIST 相同。
            if doer:GetDistanceSqToInst(v) > MAX_WALKABLE_PLATFORM_DIAMETERSQ then -- Ignore close boats because the range for aim assist is huge.
                revealer = v
                break
            end
        end
        if revealer == nil then
            return nil
        end
--★★★ 3626-3627 行注释解释了「doverride」的必要性：
--   「Ocuvigils（侦测眼）通常放在船边，会导致被传送者被挤出船边界。
--     服务端会做调整，但客户端无法得知，
--     所以我们强制用原始距离作为 override。」
--   ★★★ 这是「客户端预测与服务端权威不一致」时的处理范式：
--     客户端用「未经修正」的版本算 UI（保证 UI 立即响应），
--     服务端用「修正后」的版本执行。
--     ★ distoverride = act.pos 到修正后 targetpos 的实际距离。
        -- NOTES(JBK): Ocuvigils are normally placed at the edge of the boat and can result in the teleportee being pushed out of the boat boundary.
        -- The server will make the adjustments to the target position without the client being able to know so we force the original distance to be an override.
        targetpos.x, targetpos.y, targetpos.z = revealer.Transform:GetWorldPosition()
        distoverride = act.pos:GetPosition():Dist(targetpos)
        if revealer._target ~= nil then
            -- Server only code.
            local boat = revealer._target:GetCurrentPlatform()
            if boat == nil then
                -- This should not happen but in case it does fail the act to not teleport onto water.
                return nil
            end
            targetpos.x, targetpos.y, targetpos.z = boat.Transform:GetWorldPosition()
        end
        aimassisted = true
    end
    local dist = distoverride or act.pos:GetPosition():Dist(targetpos)
    local act_remap = BufferedAction(doer, nil, ACTIONS.BLINK_MAP, act.invobject, targetpos)
--★★ 3643-3661 行：把大量计算结果**挂在动作实例上**。
--   ★★★ 挂载的 6 个字段（maxsouls / distancemod / distanceperhop /
--     distancefloat / distancecount / aimassisted）全部是给 UI 用的。
--   ★★★ 这是「BufferedAction 作为数据载体」的又一次体现 ——
--     它不只携带执行参数，还携带「UI 渲染需要的中间量」。
--   ★★ 3650-3651 行的两个乘数：
--     heavylifting_mod  搬运时灵魂效率打折
--     dist_perhop_mod    按「可见地图比例」缩放每跳距离
--       ★★ 3651 行的公式：
--         (MAX - BASE) * seeabletilepercent + BASE
--       ★★★ 探索度越高（seeabletilepercent → 1），每跳距离越远。
--         ⇒ 地图跳跃的效率**奖励探索**。这是个漂亮的元进度设计。
--       ★ 公式里 3650 与 3652 都是乘法，且 3653 的注释明确警告：
--         「不要用 GetHopsPerSoul 调整，因为那是对同一效果的两个乘数。」
--         ★★★ 又一处「避免重复乘」的显式警告。
--   ★★ 3654 行 `dist_mod` 用 doer 的自由灵魂计数器补距离，
--     注释说明「这里的计数不包含地图加成」。
--     ★ 这是一个「两个系统共用一个计数器」的设计，需要注释才不会误解。
    local seeabletilepercent = 0
    local skilltreeupdater = doer.components.skilltreeupdater
    if skilltreeupdater then
        if skilltreeupdater:IsActivated("wortox_liftedspirits_4") and doer.GetSeeableTilePercent then
            seeabletilepercent = doer:GetSeeableTilePercent()
        end
    end
    local heavylifting_mod = act.doer.replica.inventory and act.doer.replica.inventory:IsHeavyLifting() and TUNING.WORTOX_SOULHOP_HEAVYLIFTING_EFFICIENCY or 1
    local dist_perhop_mod = ((TUNING.SKILLS.WORTOX.MAPHOP_DISTANCE_SCALER_MAX - TUNING.WORTOX_MAPHOP_DISTANCE_SCALER) * seeabletilepercent + TUNING.WORTOX_MAPHOP_DISTANCE_SCALER)
    local hopspersoul = TUNING.WORTOX_FREEHOP_HOPSPERSOUL * heavylifting_mod
    local dist_perhop = act.distance * dist_perhop_mod * hopspersoul -- NOTES(JBK): Do not adjust by GetHopsPerSoul here because it is two multipliers for the same effect.
    local dist_mod = math.min((doer._freesoulhop_counter or 0), hopspersoul) * act.distance -- Adds to the total distance based off of the counter to remove distance able to be done from the hop do not include map gains here.
    local dist_souls = (dist + dist_mod) / dist_perhop
    act_remap.maxsouls = TUNING.WORTOX_MAX_SOULS
    act_remap.distancemod = dist_mod
    act_remap.distanceperhop = dist_perhop
    act_remap.distancefloat = dist_souls
    act_remap.distancecount = math.clamp(math.ceil(dist_souls), 1, act_remap.maxsouls)
    act_remap.aimassisted = aimassisted
--★ 3662-3664：灵魂不够则 remap 失败（返回 nil ⇒ 不生成替代动作）。
    if not ActionCanMapSoulhop(act_remap) then
        return nil
    end
    return act_remap
end

--★ CASTSUMMON.fn —— 召唤幽灵（韦伯）。三重 and 检查。
ACTIONS.CASTSUMMON.fn = function(act)
	if act.invobject ~= nil and act.invobject.components.summoningitem and act.doer ~= nil and act.doer.components.ghostlybond ~= nil then
		return act.doer.components.ghostlybond:Summon( act.invobject.components.summoningitem.inst )
	end
end

--★ CASTUNSUMMON.fn —— 收回幽灵。与 CASTSUMMON 严格对称。
ACTIONS.CASTUNSUMMON.fn = function(act)
	if act.invobject ~= nil and act.invobject.components.summoningitem and act.doer ~= nil and act.doer.components.ghostlybond ~= nil then
		return act.doer.components.ghostlybond:Recall(false)
	end
end

--★ COMMUNEWITHSUMMONED.strfn —— 「改为防御 / 改为攻击」双态。
ACTIONS.COMMUNEWITHSUMMONED.strfn = function(act)
    return act.doer:HasTag("has_aggressive_follower") and "MAKE_DEFENSIVE" or "MAKE_AGGRESSIVE"
end

ACTIONS.COMMUNEWITHSUMMONED.fn = function(act)
	if act.invobject ~= nil and act.invobject.components.summoningitem and act.doer ~= nil and act.doer.components.ghostlybond ~= nil then
		return act.doer.components.ghostlybond:ChangeBehaviour()
	end
end

--★ COMBINESTACK.fn —— 合并堆叠的六行实现。
--   ★★ 3693 行的三条件：可堆叠 + CanStackWith + 没满。
--     ★★★ 与 CHANGE_TACKLE 的 1470 行同款三连。
ACTIONS.COMBINESTACK.fn = function(act)
    local target = act.target
    local invobj = act.invobject
    if invobj and target and target.components.stackable ~= nil and target.components.stackable:CanStackWith(invobj) and not target.components.stackable:IsFull() then
        target.components.stackable:Put(invobj)
        return true
    end
end

--★★【TRAVEL.fn —— 「实体自带回调」的原型样本（6 行）】
--   ★★ 全函数只有一句 `act.target.travel_action_fn(act.doer)`。
--     ★★★ 没有组件检查、没有条件判断、没有失败原因。
--     ★ 即「有这个字段就能用，没有就静默失败」。
--   ★★ ACTIVATE_CONTAINER.fn（2108 行）与它同型 ——
--     ★ 这两个是本文件里最「轻」的动作。
--     ★ 适合由 prefab 自己控制行为的场景（不需要统一策略）。
ACTIONS.TRAVEL.fn = function(act)
    if act.target and act.target.travel_action_fn then
        act.target.travel_action_fn(act.doer)
        return true
    end
end

--★ UNPIN.fn —— 三条件：不是自己 + 有 pinnable + 卡住了。
ACTIONS.UNPIN.fn = function(act)
    if act.doer ~= act.target and act.target.components.pinnable and act.target.components.pinnable:IsStuck() then
        act.target:PushEvent("unpinned")
        return true
    end
end

--★ STEALMOLEBAIT.fn —— 猴子的专属动作（doer.prefab == "mole"）。
--   ★★ 与 3721 行的 MAKEMOLEHILL 一样用 **prefab 硬判定**角色，
--     ★ 而非标签。
--     ★★ 为什么猴子用 prefab 而不是标签？
--       因为「猴子」是一种**动物 prefab**，不是玩家角色。
--       标签方案对 AI 无效（AI 不打标签），所以必须查 prefab。
--       ★★★ 这是「标签用于玩家角色，prefab 用于动物」的分界线。
ACTIONS.STEALMOLEBAIT.fn = function(act)
    if act.doer ~= nil and act.target ~= nil and act.doer.prefab == "mole" then
        act.target.selectedasmoletarget = nil
        act.target:PushEvent("onstolen", { thief = act.doer })
        return true
    end
end

--★★ MAKEMOLEHILL.fn —— 生成丘并把自己收进去。
--   ★★ 3726 行 `molehill:AdoptChild(act.doer)` ——
--     ★★★ 「收进丘里」= 把猴子设为丘的子实体。
--     ★ 3727 行清掉 needs_home_time —— 「不再需要回家」。
--   ★★ 两个 prefab 分支（mole / molebat）结构逐行对应。
ACTIONS.MAKEMOLEHILL.fn = function(act)
    if act.doer then
        if act.doer.prefab == "mole" then
			local molehill = SpawnPrefab("molehill")
			molehill.Transform:SetPosition(act.doer.Transform:GetWorldPosition())
			molehill:AdoptChild(act.doer)
			act.doer.needs_home_time = nil
			return true
        elseif act.doer.prefab == "molebat" then
            local molebathill = SpawnPrefab("molebathill")
            molebathill.Transform:SetPosition(act.doer.Transform:GetWorldPosition())
            molebathill:AdoptChild(act.doer)
            return true
		end
	end
end

--★ MOLEPEEK.fn —— 三行，只推事件。最小动作的实现。
ACTIONS.MOLEPEEK.fn = function(act)
    if act.doer then
        act.doer:PushEvent("peek")
        return true
    end
end

--★ FEED.strfn —— TREAT 变体（宠物零食）。
ACTIONS.FEED.strfn = function(act)
	return act.invobject and act.invobject:HasTag("pet_treat") and "TREAT" or nil
end

--★★【FEED.fn —— 106 行，全文件最长的单一动作实现】
--   ★★ 结构：
--     ① 3750-3752  ITEMMIMIC 守卫（T3）
--     ② 3754-3760  目标推断（没有目标就用坐骑）
--     ③ 3762-3770  trader 分支（喂商人）
--     ④ 3771-3823  eater 分支（喂生物）+ 处决流程
--     ⑤ 3825-3854  **被整段注释掉的旧实现**（30 行）
--   ★★★ 第⑤段是本文件最长的注释代码块。它保留的是
--     「直接从背包杀动物并抢战利品」的旧版 MURDER 逻辑。
--     ★★ 保留它的价值：新版（3779-3821）更复杂（要处理 owner、槽位、
--       prevslot 替换），旧版作为对照能看出「为什么要重写」。
--     ★ 旧版里也有 grandowner 这个未定义变量（3831 行），
--       说明这段代码**从未真正跑过**，只是被留下的草稿。
ACTIONS.FEED.fn = function(act)
    if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
        return false, "ITEMMIMIC"
    end

--★ 3754-3760 行：目标为 nil 时用坐骑。
--   ★★★ 与 3757 行的提前 return false 组合：
--     「既没有目标也没有坐骑」⇒ 失败。
--     ★ 这是 T7 模板的一个变体：不是「target or invobject」，
--       而是「target 或（从 doer 推导出的默认值）」。
	local target = act.target
	if target == nil then
		target = act.doer.components.rider and act.doer.components.rider:GetMount() or nil
		if target == nil then
			return false
		end
	end

--★ trader 分支 —— 喂商人。九行，与 GIVE.fn 的 trader 分支同型。
	if target.components.trader then
		local abletoaccept, reason = target.components.trader:AbleToAccept(act.invobject,act.doer)
        if abletoaccept then
			target.components.trader:AcceptGift(act.doer, act.invobject, 1)
            return true
        else
            return false, reason
        end

--★★★ 3771 行的 eater 分支 —— 「喂生物吃」。
--   ★★ 3773-3777 行的 `murdered` 局部变量推导很紧凑：
--       target:IsValid() and target.components.health
--         and target.components.health:IsDead() and target or nil
--   ★★★ 四段 and 链的三元式，最终结果是「已死且有 health 的 target」。
--     ★ 用 `or nil` 收尾确保 false 也变成 nil。
--     ★ 这种写法紧凑但可读性差 —— 拆成 if 会更好。
--   ★★ 注意此时只调用了 `eater:Eat`，**没有 CanEat 的预检查**
--     （对比 FEEDPLAYER.fn 2407 行有 CanEat）。
--     ★⇒ CanEat 的检查被下推到 eater 组件内部。
--       与 FEEDPLAYER 的做法不一致。记录为 L 类差异。
	elseif act.doer and target and target.components.eater and target.components.eater:CanEat(act.invobject) then
		target.components.eater:Eat(act.invobject, act.doer)
        local murdered =
			target:IsValid() and
			target.components.health and
			target.components.health:IsDead() and
			target or nil

--★★ 3779-3821 行：喂食导致死亡时的处决流程（42 行）。
--   ★★★ 与 MURDER.fn（3153）的差异（注释 3784-3787 行说明了）：
--     · 「因为受害者是**原地吃然后死**的，所以不该有 looting 动画」
--     · 「战利品应该**总是替换受害者原来的槽位**」
--   ★★ 具体实现差异：
--     MURDER：战利品进 doer 的背包（GiveItem(loot, nil, pos)）
--     FEED：  战利品进 owner 的容器并**指定槽位**（GiveItem(loot, prevslot)）
--   ★★ 3788 行的 grandowner 用于取坐标（物品在背包里时坐标是 0,0,0）。
--   ★ 3806-3807 行的保留注释「Searchable for inventory component
--     reference.」—— 作者自己标注了「这里应该查一下 inventory 组件但没查」。
--     ★★★ 又一处显式的技术债标注，非常难得。
        if murdered ~= nil then
            murdered.causeofdeath = act.doer

            local owner = murdered.components.inventoryitem ~= nil and murdered.components.inventoryitem.owner or nil
            if owner ~= nil then
                --In inventory or container:
                --Slightly different from MURDER action since victim ate and died
                --in place, so there should be no looting animation, and the loot
                --should always replace the victim's old slot.
                local grandowner = murdered.components.inventoryitem:GetGrandOwner()
                local x, y, z = grandowner.Transform:GetWorldPosition()
                murdered.components.inventoryitem:RemoveFromOwner(true)
                murdered.Transform:SetPosition(x, y, z)

--★ 3793 行的 `grandowner.SoundEmitter` 双重保护（组件 + 字段）。
--   ★★ 与 3161 行 MURDER 里的 `act.doer.SoundEmitter` 不同 ——
--     这里不检查 doer 是否是玩家（因为可能不是）。
                if murdered.components.health.murdersound ~= nil and grandowner.SoundEmitter then
                    grandowner.SoundEmitter:PlaySound(FunctionOrValue(murdered.components.health.murdersound, murdered, act.doer))
                end

                if murdered.components.lootdropper ~= nil then
                    local container = owner.components.inventory or owner.components.container
                    if container ~= nil then
                        local stacksize = murdered.components.stackable ~= nil and murdered.components.stackable:StackSize() or 1
                        for i = 1, stacksize do
                            local loots = murdered.components.lootdropper:GenerateLoot()
                            for k, v in pairs(loots) do
                                local loot = SpawnPrefab(v)
                                if loot ~= nil then
                                    -- NOTES(JBK): Searchable for inventory component reference.
                                    -- inventory:GiveItem(
                                    container:GiveItem(loot, murdered.prevslot)
                                end
                            end
                        end
                    end
                end
            end

            act.doer:PushEvent("killed", { victim = murdered })

--★★ 3818-3820 行：`if owner ~= nil then murdered:Remove() end`
--   ★★★ 条件：只有「原本在背包/容器里」才 Remove。
--     若在地上喂死（owner 为 nil），3820 行不执行 ⇒ 尸体留在原地。
--     ★ 这是有意的：地上的尸体应该留在地上。
--     ★ 但注意 3790 行的 RemoveFromOwner(true) 在 owner 非 nil 时已执行，
--       所以 Remove 是必要的清理。
            if owner ~= nil then
                murdered:Remove()
--★★ FEED.fn 内部的「处决流程」在 3779-3821（已逐行注释）。
--   ★★ 3825-3854 是**被整段注释掉的旧实现**（30 行）。
--     ★★ 保留它的价值：新版（3779-3821）更复杂（要处理 owner、
--       槽位、prevslot 替换），旧版作为对照能看出「为什么要重写」。
--     ★ 旧版里也有 grandowner 这个未定义变量（3831 行），
--       说明这段代码**从未真正跑过**，只是被留下的草稿。
            end
        end
        return true
--★★ FEED.fn 的分支④（eater）在 3822 结束 —— return true。
--   ★★ 3825-3854 是**被整段注释掉的旧实现**（30 行）。
--     ★★★ 保留它的三个价值：
--       ① 能看出「直接从背包杀动物并抢战利品」的老做法；
--       ② 新版（3779-3821）为何复杂（要处理 owner、槽位、prevslot 替换）
--          —— 有对照才能理解重构动机；
--       ③ 3831 行的 grandowner 在旧版里是**未定义变量**，
--          ★★ 说明这段代码从未真正跑过（只是草稿）。
--     ★★★ 这是一条重要的历史记录，不要删除。
    end
--★★ 3824 行 —— FEED.fn 主体结束，进入 30 行被注释掉的旧实现。
--   ★★ 这段（3825-3854）全部以 `--[[` 包裹（3831 行可见开标记），
--     属于 Lua 的**长注释块**，因此整块不参与语法解析。
--   ★★★ 「保留大段被注释的旧代码」在本文件里罕见（只有 4 处）：
--     · 384 行 LOOKAT 的 distance=3 行内短注释
--     · 964 行 EMPTY_CONTAINER 的 DropEverything()
--     · 1981 行 UPGRADE 的 weapon 不能为 nil 的隐含断言
--     · 3825-3854 本块
--   ★★ 保留它们的价值：记录「这个功能曾是什么样子」，
--     对理解重构动机与「为什么会漏掉某个分支」极有帮助。

--[[    local murdered = act.invobject or act.target
    if murdered ~= nil and murdered.components.health ~= nil then
        local x, y, z = act.doer.Transform:GetWorldPosition()
        murdered.components.inventoryitem:RemoveFromOwner(true)
        murdered.Transform:SetPosition(x, y, z)

        if murdered.components.health.murdersound ~= nil and grandowner.SoundEmitter then
            grandowner.SoundEmitter:PlaySound(FunctionOrValue(murdered.components.health.murdersound, murdered, act.doer))
        end

        if murdered.components.lootdropper ~= nil then
            murdered.causeofdeath = act.doer
            local pos = Vector3(x, y, z)
            local stacksize = murdered.components.stackable ~= nil and murdered.components.stackable:StackSize() or 1
            for i = 1, stacksize do
                local loots = murdered.components.lootdropper:GenerateLoot()
                for k, v in pairs(loots) do
                    local loot = SpawnPrefab(v)
                    if loot ~= nil then
                        act.doer.components.inventory:GiveItem(loot, nil, pos)
                    end
                end
            end
        end

        act.doer:PushEvent("killed", { victim = murdered })
        murdered:Remove()

        return true
    end]]
end

--★ HAIRBALL.fn —— 猫猫吐毛球。两行。
--   ★★ 3858 行 `doer.prefab == "catcoon"` —— 又是 prefab 硬判定（§p6 3713）。
--     ★ 而且它返回 true 但什么都不做 —— 纯信号动作。
--     ★★ 与 3888 行的 CATPLAYGROUND 形成对比：后者返回 true 且做很多事。
ACTIONS.HAIRBALL.fn = function(act)
    if act.doer and act.doer.prefab == "catcoon" then
        return true
    end
end

--★★★【CATPLAYGROUND.fn —— 猫猫玩闹（26 行）】
--   ★★ 一个动作内的「概率分支大杂烩」（3870/3876/3884 三处 math.random）：
--     ① cattoy    → 玩玩具（必现）
--     ② poppable  → 戳破（必现）
--     ③ 攻击      → CATCOON_ATTACK_CONNECT_CHANCE 概率
--     ④ 捡东西    → CATCOON_PICKUP_ITEM_CHANCE 概率
--     ⑤ 激活      → CATCOON_ACTIVATE_CONNECT_CHANCE 概率
--   ★★ 这是一个**故意随机**的动作：猫猫的行为本就不该可预测。
--     ★ 与本文件其它动作（全是确定性判定）形成鲜明对比。
--   ★★★ 与 CATPLAYAIR.fn（3892）几乎逐行对应，差别是：
--     · CATPLAYGROUND 有捡东西分支（3876），CATPLAYAIR 没有
--     · CATPLAYGROUND 的攻击分支多了「不是玩家」的限制（3873）
--     · CATPLAYAIR 记录 last_play_air_time（3907）
--   ★★ 两个动作≈30 行几乎重复 —— 典型的「复制后小改」演进。
ACTIONS.CATPLAYGROUND.fn = function(act)
    if act.doer then
        if act.target then
			if act.target.components.cattoy ~= nil then
				act.target.components.cattoy:Play(act.doer, false)
			elseif act.target.components.poppable ~= nil then
				act.target.components.poppable:Pop()
--★★ 3870-3875 行：攻击分支的**五重限制**：
--   ① 有 combat 组件
--   ② 概率通过 CATCOON_ATTACK_CONNECT_CHANCE
--   ③ 目标有 health 且 maxhealth <= PENGUIN_HEALTH
--      ★★★ 注释「Only bother attacking if it's a penguin or weaker」——
--        猫猫**不会**去打强大的生物。这是刻意的性格设定。
--   ④ 目标有 combat 且 CanBeAttacked
--   ⑤ 不是自己的跟随者（3872）
--   ⑥ 不是玩家（3873）
--   ★★ 六重限制说明「猫猫攻击」是一个需要严加管制的行为，
--     否则玩家会不断被自己的猫猫误伤。
--   ★ 3875 行 `DoAttack(target, nil, nil, nil, 2)` 的最后一个 2 ——
--     ★★★ 行尾注释「2*25 dmg」：这是「倍数 × 基础伤害」的表示法。
--       猫猫攻击伤害是普通攻击的 2 倍。
            elseif act.doer.components.combat ~= nil and math.random() < TUNING.CATCOON_ATTACK_CONNECT_CHANCE and act.target.components.health and act.target.components.health.maxhealth <= TUNING.PENGUIN_HEALTH -- Only bother attacking if it's a penguin or weaker
				and act.target.components.combat and act.target.components.combat:CanBeAttacked(act.doer)
				and not (act.doer.components.follower and act.doer.components.follower:IsLeaderSame(act.target))
				and not act.target:HasTag("player") then

                act.doer.components.combat:DoAttack(act.target, nil, nil, nil, 2) --2*25 dmg
--★★ 3876-3883 行：捡东西分支的四层判断。
--   ★★★ 3877 行：目标是 bait → 推 onstolen 事件（而不是真的拿走）
--     ★ 推测：诱饵被「偷」时游戏会记一��（成就/统计）。
--   ★★ 3879-3883 行的三段：
--     有 inventory → GiveItem（真的拿走）
--     无 inventory → target:Remove()（直接删除）
--     ★★★ 第二段很危险：猫猫没有背包时**直接删除物品**。
--       若条件判断（3876）宽松，可能凭空吞物品。
--     ★ 条件要求 canbepickedup，所以只吞可捡的物品。
--       仍属「静默销毁」。记录为 L 类观察点。
            elseif act.doer.components.inventory ~= nil and act.target.components.inventoryitem and act.target.components.inventoryitem.canbepickedup and math.random() < TUNING.CATCOON_PICKUP_ITEM_CHANCE then
			    if act.target.components.bait ~= nil then
					act.target:PushEvent("onstolen", { thief = act.doer })
				elseif act.doer.components.inventory ~= nil then
					act.doer.components.inventory:GiveItem(act.target)
				else
					act.target:Remove()
				end
--★ 3887 行的 end 缩进错位（比函数体深一级）。
--   ★★ 这是 §0 L7：3887 行的 `end` 缩进与 3886 行不匹配。
--     语法上正确（Lua 不看缩进），但阅读时极易误判作用域。
--     ★ 推测是从别处复制代码后缩进未调整。
			elseif act.target.components.activatable ~= nil and act.target.components.activatable:CanActivate(act.doer) and math.random() < TUNING.CATCOON_ACTIVATE_CONNECT_CHANCE then
				act.target.components.activatable:DoActivate(act.doer)
            end
        end
        return true
    end
end

--★★ CATPLAYAIR.fn —— 空中玩闹。与 3863 高度重复。
--   ★★ 3905 行 `local ret, msg = ...DoActivate(...)` ——
--     ★★★ ret 与 msg **从未被使用**！
--       ★ 典型的「预留返回值但忘了用」——作者可能打算 Say 一句失败提示。
--       ★ 记录为 L 类瑕疵（未使用的局部变量）。
--       ★★ 对比 3863 行的 CATPLAYGROUND：3885 行直接丢弃返回值，
--         没有赋值。399 行与 4096 行写法不一致。
ACTIONS.CATPLAYAIR.fn = function(act)
    if act.doer and act.target then
		if act.target.components.cattoy ~= nil then
			act.target.components.cattoy:Play(act.doer, true)
		elseif act.target.components.poppable ~= nil then
			act.target.components.poppable:Pop()
        elseif act.doer.components.combat ~= nil and act.target and math.random() < TUNING.CATCOON_ATTACK_CONNECT_CHANCE
			and act.target.components.health and act.target.components.health.maxhealth <= TUNING.PENGUIN_HEALTH -- Only bother attacking if it's a penguin or weaker
			and act.target.components.combat and act.target.components.combat:CanBeAttacked(act.doer)
			and not (act.doer.components.follower and act.doer.components.follower:IsLeaderSame(act.target)) then

            act.doer.components.combat:DoAttack(act.target, nil, nil, nil, 2) --2*25 dmg
		elseif act.target.components.activatable ~= nil and act.target.components.activatable:CanActivate(act.doer) and math.random() < TUNING.CATCOON_ACTIVATE_CONNECT_CHANCE then
			local ret, msg = act.target.components.activatable:DoActivate(act.doer)
        end
--★ last_play_air_time = GetTime() —— 「上次空中玩闹的时间」。
--   ★★ 这个时间戳供其它系统（可能是冷却或成就）读取。
--     ★ doer 上的 `_` 命名不统一：last_play_air_time 没有下划线前缀，
--       而 _freesoulhop_counter 有。见 p6 3554 行的约定说明。
        act.doer.last_play_air_time = GetTime()
        return true
    end
end

--★ ERASE_PAPER.fn —— 擦纸。四条件准入。
--   ★★ 3916-3917 行排除 fire / burnt 标签 —— 「烧着的纸不能擦」。
ACTIONS.ERASE_PAPER.fn = function(act)
    if act.invobject and act.target
        and act.invobject.components.erasablepaper
		and act.target.components.papereraser
		and not act.target:HasTag("fire")
        and not act.target:HasTag("burnt")
		then
		
        return act.target.components.papereraser:DoErase(act.invobject, act.doer)
    end
end

--★ FAN.fn —— 扇风（吹灭余烬）。四行。
ACTIONS.FAN.fn = function(act)
    if act.invobject ~= nil and act.invobject.components.fan ~= nil then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        return act.invobject.components.fan:Fan(act.target or act.doer)
    end
end

--★★★【TOSS.fn —— 投掷的完整实现（47 行）】
--   ★★ 六步流程：
--     ① 3935-3942  doer 与 inventory 存在
--     ② 3944-3954  确定投掷物（invobject 或手持的 special_action_toss）
--     ③ 3956-3960  必须有 complexprojectile 且装备无限制
--     ④ 3962-3964  ITEMMIMIC 守卫
--     ⑤ 3966       DropItem（真正变成地面实体）
--     ⑥ 3968-3976  定目标点并 Launch
--   ★★ ②的三级回退：没有 invobject → 用手持有物 → 但手持有物必须有
--     special_action_toss 标签 → 否则 projectile = nil → return nil。
--     ★★★ 这个标签让「用手投掷」变成显式同意的行为。
ACTIONS.TOSS.fn = function(act)
    if not act.doer then
        return nil
    end

    local doer_inventory = act.doer.components.inventory
    if not doer_inventory then
        return nil
    end

    local projectile = act.invobject
    if not projectile then
        --for Special action TOSS, we can also use equipped item.
        projectile = doer_inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
--★ special_action_toss 标签 —— 「这个物品可以徒手投掷」。
--   ★★ 3949 行 `projectile = nil` 而不是 return —— 
--     让流程继续到 3952 行的统一失败出口。风格统一。
        if projectile ~= nil and not projectile:HasTag("special_action_toss") then
            projectile = nil
        end
    end
    if not projectile then
        return nil
    end

--★★ 3957-3958 行：必须有 complexprojectile 组件。
--   ★★ 且装备有三种限制时都拒绝：IsRestricted / ShouldPreventUnequipping。
--     ★ 与 3961 行 PERFORM 的同类检查同款。
    local equippable = projectile.components.equippable
    if not projectile.components.complexprojectile or
            (equippable ~= nil and (equippable:IsRestricted(act.doer) or equippable:ShouldPreventUnequipping())) then
        return nil
    end

    if ShouldItemMimicBeRevealedFor(projectile, act.doer) then
        return false, "ITEMMIMIC"
    end

    projectile = doer_inventory:DropItem(projectile, false)
    if projectile then
--★★ 3969-3974 行：有目标用目标位置，无目标用光标位置。
--   ★★★ 3971 行 `targetoffset = {x=0, y=1.5, z=0}` ——
--     ★★ 投掷目标有 1.5 格的**高度偏移**。
--     ★ 为什么？因为 launch 的目标是「实体中心」，而角色中心在脚下。
--       加 1.5 让投掷物落在目标脚下而不是穿地。
--     ★ 这个偏移是硬编码的字面量表，没有配置项。
--     ★ 同样的字面量在 5187 行（OCEAN_TOSS）重复出现。
        local pos
        if act.target then
            pos = act.target:GetPosition()
            projectile.components.complexprojectile.targetoffset = {x=0,y=1.5,z=0}
        else
            pos = act:GetActionPoint()
        end

        projectile.components.complexprojectile:Launch(pos, act.doer)

        return true
    end
end

--★ WATER_TOSS.fn = TOSS.fn —— T12 同构模板（§2 546 行）。
ACTIONS.WATER_TOSS.fn = ACTIONS.TOSS.fn

--★ TOSS_MAP.stroverridefn —— 用物品的 CanTossOnMap 回调决定能否显示。
--   ★★★ 与 DIRECTCOURIER_MAP（3507）的模式一致：
--     「物品自己说能不能用」。
ACTIONS.TOSS_MAP.stroverridefn = function(act)
    return act.doer ~= nil and act.invobject ~= nil and act.invobject.CanTossOnMap ~= nil and act.invobject:CanTossOnMap(act.doer) and STRINGS.ACTIONS.TOSS or nil
end

--★ ActionCanMapToss —— 5 行的判定辅助函数。
--   ★★ 3989 行的条件里同时检查 `act.doer ~= nil and act.invobject ~= nil`
--     —— 但 3508/3523 行的调用点已经检查过。这是防御式冗余。
local function ActionCanMapToss(act)
    if act.doer ~= nil and act.invobject ~= nil and act.invobject.CanTossOnMap ~= nil then
        return act.invobject:CanTossOnMap(act.doer)
    end
    return false
end

--★★ TOSS_MAP.fn —— 8 行，只做一件事：设 from_map 后转发。
--   ★★★ 3998 行 `act.from_map = true` ——
--     ★★ 与 BLINK_MAP 的 3598 行 `from_map = true` 同款机制。
--     ★ 该 flag 会被状态的 handler 读取，用来选择「从地图传送」的过场动画。
--     ★★★ 同一个约定在两处独立出现（没有共用常量或辅助函数），
--       属「约定靠注释传递」的典型。
ACTIONS.TOSS_MAP.fn = function(act)
	local act_pos = act:GetActionPoint()
    if ActionCanMapToss(act) then
        act.from_map = true
        return ACTIONS.TOSS.fn(act)
    end
end

--★★★【ACTIONS_MAP_REMAP[ACTIONS.TOSS.code] —— 距离夹取 + 水面校验（33 行）】
--   ★★ 4008-4024 行：「物品自带的最小/最大投掷距离」处理。
--     ★★ 4013-4015 行有一个 **除零保护**：
--       `if dx == 0 and dz == 0 then dx = 1 end`
--       ★★★ 玩家与光标完全重合时 dx=dz=0 ⇒ 后续 dx/dist 会除零。
--         用 dx=1 打破。经典的防御技巧。
--   ★★ 4017-4023 行的夹取：
--     距离 < min ⇒ 把目标点拉到恰好 min 远
--     距离 > max ⇒ 把目标点拉到恰好 max 远
--     ★★★ 这是「软性距离限制」：不是禁止，而是把目标点改到边界上。
--       比直接 return false 的 UX 好得多（玩家看到抛物线被截断）。
--   ★★ 4026 行的水面校验：`IsOceanTile and not IsVisualGround`
--     ⇒ 与 §零 49 行的判定完全一致（海洋瓦片 + 不可通行 = 真水面）。
--     ★ 又一处重复的判定表达式（第五次出现）。
ACTIONS_MAP_REMAP[ACTIONS.TOSS.code] = function(act, targetpos)
--★★ ACTIONS_MAP_REMAP[ACTIONS.TOSS.code] 内部（4003-4035）。
--   ★★ 核心是 4008-4024 的「距离夹取」：
--     物品可自带 map_remap_min_dist / map_remap_max_dist，
--     超出范围时**不是拒绝，而是把目标点拉回边界**。
--   ★★★ 与 §p8 6785-6791（MAPSCOUT_MAP 的 math.min 钳制）同源手法。
--     ★ 两处独立实现，属 L 类不一致（但两处都正确）。
--   ★★ 4013-4015 行的除零保护：`if dx == 0 and dz == 0 then dx = 1 end`。
--     ★ 玩家与光标完全重合时的经典保护。
    if act.doer == nil or act.invobject == nil then
        return nil
    end

    local min_dist = act.invobject.map_remap_min_dist
    local max_dist = act.invobject.map_remap_max_dist
    if min_dist or max_dist then
        local x, y, z = act.doer.Transform:GetWorldPosition()
        local dx, dz = targetpos.x - x, targetpos.z - z
        if dx == 0 and dz == 0 then
            dx = 1
        end
        local dist = math.sqrt(dx * dx + dz * dz)
--★★ TOSS_MAP 重映射的「距离夹取」在 4017-4023：
--   ★★ 两个分支只差方向：
--     · 距离 < min → 拉到 min 远（4018-4019）
--     · 距离 > max → 拉到 max 远（4021-4022）
--   ★★★ 「软性距离限制」：不是禁止，而是把目标点改到边界。
--     ★ 玩家看到抛物线被截断，比看到「不能扔」友好得多。
--     ★★★ 这与 §p8 6785-6791 的 MAPSCOUT_MAP 钳制同源手法。
        if min_dist and dist <= min_dist then
            targetpos.x = x + dx * (min_dist / dist)
            targetpos.z = z + dz * (min_dist / dist)
        elseif max_dist and dist >= max_dist then
            targetpos.x = x + dx * (max_dist / dist)
            targetpos.z = z + dz * (max_dist / dist)
        end
    end

--★ 4026 行 —— 水面校验（与 §p1 49 行的双重判定完全一致）。
--   ★★ 这是该表达式在 actions.lua 里**第五次**出现。
--     ★ 49 / 158 / 216 / 181 / 4026 —— 五处。
--     ★★★ 应该是候选函数，但作者选择复制。
--       ★ 记为 L 类重构建议（去重收益最高的一处）。
    if not TheWorld.Map:IsOceanTileAtPoint(targetpos.x, targetpos.y, targetpos.z) or TheWorld.Map:IsVisualGroundAtPoint(targetpos.x, targetpos.y, targetpos.z) then
        return nil
    end

    local act_remap = BufferedAction(act.doer, nil, ACTIONS.TOSS_MAP, act.invobject, targetpos)
    if not ActionCanMapToss(act_remap) then
        return nil
    end
    return act_remap
end

--★★ UPGRADE.fn —— 升级的七行双检（CanUpgrade 调了两次！）。
--   ★★★ 4041 行 `act.invobject.components.upgrader:CanUpgrade(target, doer)`
--     是「**升级工**能否升级这个目标」。
--     4043 行 `act.target.components.upgradeable:CanUpgrade()`
--     是「目标自己**是否可被升级**」。
--     ★★★ 两个不同的组件、两个不同的 CanUpgrade，返回值都叫 can_upgrade。
--       ★ 命名相同但语义不同，是本文件里最容易读错的一处。
--   ★★ 4044-4048 行的结构：
--     可以 → return Upgrade(...)  （透传升级结果）
--     不可 → return false, reason
--     ★★★ 第三个 return 缺失（4044 行为真时 return，4048 行 return false），
--       若 Upgrade 返回 nil 则整个 fn 返回 nil。
ACTIONS.UPGRADE.fn = function(act)
    if act.invobject and act.target and
		act.target.components.upgradeable and
        act.invobject.components.upgrader and
		act.invobject.components.upgrader:CanUpgrade(act.target, act.doer)
	then
        local can_upgrade, reason = act.target.components.upgradeable:CanUpgrade()
        if can_upgrade then
            return act.target.components.upgradeable:Upgrade(act.invobject, act.doer)
        end

        return false, reason
    end
end

--★ UPGRADE.strfn —— WATERPLANT 变体（用前缀拼接的标签）。
--   ★★ 4053 行 `HasTag(UPGRADETYPES.WATERPLANT.."_upgradeable")` ——
--     ★★★ **动态拼接标签**：`"waterplant_upgradeable"`。
--     ★ 这意味着每个植物类型都需要一个对应的标签，
--       而标签的构造依赖 UPGRADETYPES 常量。
--     ★ 与 COMPARE_WEIGHABLE_TEST（4628 行）同款「标签交叉验证」模式。
ACTIONS.UPGRADE.strfn = function(act)
    return (act.target ~= nil and act.target:HasTag(UPGRADETYPES.WATERPLANT.."_upgradeable") and "WATERPLANT")
            or nil
end

--★ NUZZLE.fn —— 蹭。4059 行有被注释掉的 print（作者调试过）。
ACTIONS.NUZZLE.fn = function(act)
    if act.target then
        --print(string.format("%s loves %s!", act.doer.prefab, act.target.prefab))
        return true
    end
end

--★★ WRITE.fn —— 写告示牌的 17 行，教科书式的「静默失败」。
--   ★★ 四步：
--     ① 写过了吗？→ 条件不满足（隐式 nil）
--     ② 别人正在写吗？→ 4071 行 return false, "INUSE"
--     ③ 看得见吗？     → 4075 行 CanEntitySeeTarget，**静默跳过**
--     ④ 真的开始写     → BeginWriting
--   ★★★ ②与③的**失败策略不同**：
--     ② INUSE 有明确 reason（玩家理解「他在写」）
--     ③ 黑暗中静默（玩家理解「我看不见」）
--   ★ 这个区分（他人冲突 = 报错 / 环境限制 = 静默）在本文件里反复出现。
--   ★★ 4078 行的 return true 覆盖了③的情况 —— 静默成功。
ACTIONS.WRITE.fn = function(act)
    if act.doer ~= nil and
        act.target ~= nil and
        act.target.components.writeable ~= nil and
        not act.target.components.writeable:IsWritten() then

        if act.target.components.writeable:IsBeingWritten() then
            return false, "INUSE"
        end

        --Silent fail for writing in the dark
        if CanEntitySeeTarget(act.doer, act.target) then
            act.target.components.writeable:BeginWriting(act.doer)
        end
        return true
    end
end

--★ ATTUNE.fn —— 调频（韦伯）。四行。
ACTIONS.ATTUNE.fn = function(act)
    if act.doer ~= nil and
        act.target ~= nil and
        act.target.components.attunable ~= nil then
        return act.target.components.attunable:LinkToPlayer(act.doer)
    end
end

--★ MIGRATE.fn —— 迁移。函数上方有注释标注失败原因："NODESTINATION"。
--   ★★ 4091 行的注释 `--fail reasons: "NODESTINATION"` ——
--     ★★★ 这种「注释声明失败原因」的写法非常好：
--       它把「本函数会返回哪些 reason」变成了契约。
--       全文件只有这一处这么做。值得推广。
ACTIONS.MIGRATE.fn = function(act)
    --fail reasons: "NODESTINATION"
    return act.doer ~= nil
        and act.target ~= nil
        and act.target.components.worldmigrator ~= nil
        and act.target.components.worldmigrator:Activate(act.doer)
end

--★★ REMOTERESURRECT.fn —— 远程复活（韦伯）。
--   ★★ 4102 行的双条件：doer 是幽灵（playerghost 标签）。
--   ★★ 4103-4104 行两级 attuner 目标：
--       先找 remoteresurrector，再找 gravestoneresurrector
--     ★★★ 两个道具都可能配「复活器」，按优先级取。
--     ★ 用 or 链表达「优先级 fallback」，比嵌套 if 简洁。
ACTIONS.REMOTERESURRECT.fn = function(act)
    if act.doer == nil then return end

    local doer_attuner = act.doer.components.attuner
    if doer_attuner and act.doer:HasTag("playerghost") then
        local target = doer_attuner:GetAttunedTarget("remoteresurrector")
            or doer_attuner:GetAttunedTarget("gravestoneresurrector")
        if target ~= nil then
            act.doer:PushEvent("respawnfromghost", { source = target })
            return true
        end
    end
end

--★ REVIVE_CORPSE.fn —— 复活尸体的静默失败（§2 507 行已预告 actionmeter）。
--   ★★ 4114 行注释 `--Silent fail` + 4115 行的检查：
--     ★★★ 「能不能复活」失败时**仍 return true**。
--       理由与 1231 行 LOOKAT 同款：复活是一个长动作（有进度环），
--       走到位后条件可能已变，此时不该报错。
ACTIONS.REVIVE_CORPSE.fn = function(act)
    if act.doer ~= nil and act.target ~= nil and act.target.components.revivablecorpse ~= nil then
        --Silent fail
        if act.target.components.revivablecorpse:CanBeRevivedBy(act.doer) then
            act.target.components.revivablecorpse:Revive(act.doer)
        end
        return true
    end
end

--★★★【MOUNT.fn —— 骑乘判定的 7 条规则（24 行）】
--   ★★ 4123-4127 行：战斗中不可骑 —— 但有例外！
--       `(rideable == nil or rideable.saddle == nil
--        or not rideable.saddle:HasTag("combatmount"))`
--     ★★★ 「鞍上有 combatmount 标签」⇒ 战斗坐骑**可以**骑。
--       （韦伯的指南针坐骑？或者战斗用牛？）
--     ★ 这是全文件里少见的「例外否定」三层嵌套。
--   ★★ 4128-4137 行的六条 or 条件（全是静默 return false，无 reason）：
--     无 rideable / 不能骑 / 已死 / 冰冻 / 已被拴 / 有 hitchingspot
--     ★★★ 「有 hitchingspot」这一条很有意思（4136 行）：
--       牛正在被牵走时不能骑它。hitchingspot 是「拴绳的目标点」。
--     ★ 六条全部无 reason ⇒ 玩家点了只看到「不能这么做」。
--       ★ 猜测是因为这些原因（冰冻？死了？）说出来玩家也不理解。
--   ★★ 4140 行的 dogrider_only 检查：`and act.target._playerlink ~= act.doer`
--     ⇒ 只有「自己的狗骑手」能骑专用的狗。
--     ★ _playerlink 是韦伯的「玩家与身体的链接」字段。
ACTIONS.MOUNT.fn = function(act)
    if act.target.components.combat ~= nil and act.target.components.combat:HasTarget()
            and (act.target.components.rideable == nil
--★★ MOUNT.fn 的 7 条判定在 4123-4142。
--   ★★ 特别注意 4123-4127 的「战斗坐骑例外」：
--     战斗中不可骑，但**鞍上有 combatmount 标签**时例外。
--   ★★★ 这个例外藏在三层 or 里：
--     `rideable == nil or rideable.saddle == nil
--      or not rideable.saddle:HasTag("combatmount")`
--     ⇒ 三者全假（有 rideable、有 saddle、saddle 是战斗坐骑）才允许骑。
--   ★★ 4128-4137 的六条 or 全部静默 return false（无 reason）。
                or act.target.components.rideable.saddle == nil
                or not act.target.components.rideable.saddle:HasTag("combatmount")) then
        return false, "TARGETINCOMBAT"
    elseif act.target.components.rideable == nil
        or not act.target.components.rideable.canride
        or (act.target.components.health ~= nil and
            act.target.components.health:IsDead())
        or (act.target.components.freezable and
            act.target.components.freezable:IsFrozen())
        or (act.target.components.hitchable ~= nil and
            act.target.components.hitchable:GetHitch() ~= nil)
        or (act.target.hitchingspot ~= nil) then
        return false
    elseif act.target.components.rideable:IsBeingRidden() then
        return false, "INUSE"
    elseif act.target:HasTag("dogrider_only") and act.doer:HasTag("dogrider") and act.target._playerlink ~= act.doer then
        return false
    end

    act.doer.components.rider:Mount(act.target)
    return true
end

--★ DISMOUNT.fn —— 下坐骑。四条件全是「自我指涉」检查。
--   ★★★ `act.doer == act.target and doer.components.rider ~= nil
--     and rider:IsRiding()` ——
--     ★ 三个条件都是「检查自己状态」，不需要目标实体。
--     ★ 这解释了 DISMOUNT 的距离字段：声明里没有 distance！
--       ⇒ 玩家在哪都能下马（因为不需要走到坐骑旁边）。
--       ★★ 这是「声明与实现的一致性」的一个好例子。
ACTIONS.DISMOUNT.fn = function(act)
    if act.doer == act.target and act.doer.components.rider ~= nil and act.doer.components.rider:IsRiding() then
        act.doer.components.rider:Dismount()
        return true
    end
end

--★ SADDLE.fn —— 上鞍。四道守卫（战斗中/已死/ITEMMIMIC/rideable）。
--   ★★ 4163-4164 行的保留注释「V2C: currently, rideable component
--     implies saddleable always」——
--     ★★★ 「目前 rideable 组件就意味着可以上鞍」。
--     ★ 这是一个**简化的耦合**：本应有两个组件（rideable/saddleable），
--       但实际只检查 rideable。注释明确指出了这个假设。
--     ★ 若将来某个生物可骑但不可上鞍，需要在这里加组件检查。
ACTIONS.SADDLE.fn = function(act)
    if act.target.components.combat ~= nil and act.target.components.combat:HasTarget() then
        return false, "TARGETINCOMBAT"
    elseif act.target.components.health ~= nil and act.target.components.health:IsDead() then
        return false
    elseif ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
        return false, "ITEMMIMIC"
    elseif act.target.components.rideable ~= nil then
        --V2C: currently, rideable component implies saddleable always
        act.doer:PushEvent("saddle", { target = act.target })
        act.doer.components.inventory:RemoveItem(act.invobject)
        act.target.components.rideable:SetSaddle(act.doer, act.invobject)
        return true
    end
end

--★ UNSADDLE.fn —— 与 SADDLE.fn 严格对称的四道守卫。
--   ★★ 4179 行重复了 4163 行的同一句 V2C 注释 ——
--     ★ 同一注释被复制到两处。任何一方修改都会造成不一致。
--     ★ 典型的「注释也应被抽取」的场景。
ACTIONS.UNSADDLE.fn = function(act)
    if act.target.components.combat ~= nil and act.target.components.combat:HasTarget() then
        return false, "TARGETINCOMBAT"
    elseif act.target.components.health ~= nil and act.target.components.health:IsDead() then
        return false
    elseif ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
        return false, "ITEMMIMIC"
    elseif act.target.components.rideable ~= nil then
        --V2C: currently, rideable component implies saddleable always
        act.doer:PushEvent("saddle", { target = act.target })
        act.target.components.rideable:SetSaddle(act.doer, nil)
        return true
    end
end

--★ BRUSH.fn —— 刷毛。与 SADDLE 同样四道守卫 + brushable 组件。
--   ★★ 4187-4192 的守卫块与 4156-4161 逐字相同（除组件名）。
--     ★ 三连复制（SADDLE / UNSADDLE / BRUSH）+ 与 4138 附近的 MOUNT 同款。
ACTIONS.BRUSH.fn = function(act)
    if act.target.components.combat ~= nil and act.target.components.combat:HasTarget() then
        return false, "TARGETINCOMBAT"
    elseif act.target.components.health ~= nil and act.target.components.health:IsDead() then
        return false
    elseif ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
        return false, "ITEMMIMIC"
    elseif act.target.components.brushable ~= nil then
        act.target.components.brushable:Brush(act.doer, act.invobject)
        return true
    end
end

--★ CRITTER_MUST_TAGS —— 供 4205 行 FindEntities 使用的标签表。
local CRITTER_MUST_TAGS = { "critterlab" }
--★★ ABANDON.fn —— 遗弃宠物/跟随者。
--   ★★ 4202-4208 的 ORPHANAGE 科技树检查（§2 514 行已预告）。
--   ★★★ 4204-4206 行：只有「附近 10 格内完全没有 critterlab」时才失败。
--     ★★★ 这是一个**反向的距离检查**：
--       玩家的动作距离校验通过了（对着宠物），
--       但若附近根本没有收容所 ⇒ 这个「遗弃」显然不合理（无处可去）。
--       ★ 保留的英文注释「we could've been in range but the pet was out of
--         range」其实是**上一句的误读** ——
--         它想说的是「我们可能在范围内，但宠物不在范围内」，
--         与实际的代码逻辑（找 critterlab）不完全对应。
--       ★ 注释与代码有偏差，属 L 类瑕疵。
--   ★★ 4212 行的 elseif 分支处理 follower（非宠物类跟随者）。
ACTIONS.ABANDON.fn = function(act)
    if act.doer.components.petleash ~= nil and act.target.components.crittertraits ~= nil then
        if not (act.doer.components.builder ~= nil and act.doer.components.builder.accessible_tech_trees.ORPHANAGE > 0) then
            --we could've been in range but the pet was out of range
            local x, y, z = act.doer.Transform:GetWorldPosition()
            if #TheSim:FindEntities(x, y, z, 10, CRITTER_MUST_TAGS) <= 0 then
                return false
            end
        end
        act.doer.components.petleash:DespawnPet(act.target)
        return true

	elseif act.target.components.follower ~= nil and act.target.components.follower:GetLeader() == act.doer then
		act.target.components.follower:StopFollowing()
		return true
   end
end

--★ PET.fn —— 撸猫猫。三个 if 各自独立（非 elseif）。
--   ★★★ 4222 行注释掉的 `--if act.doer.components.inventory then` ——
--     ★ 第三行（target:Remove()）需要 inventory 判断，被注释掉了。
--       ★ 意味着现在无条件 Remove —— 与 p6 3876 行的隐患相同。
--       ★ 若是刻意删除注释则应删掉整行。记录为 L 类瑕疵。
ACTIONS.PET.fn = function(act)
    if act.target ~= nil then
		if act.doer.components.petleash ~= nil and act.target.components.crittertraits ~= nil then
			act.target.components.crittertraits:OnPet(act.doer)
		end

		if act.target.components.kitcoon ~= nil then
			act.target:PushEvent("on_petted", {doer = act.doer})
		end
        return true
    end
end

--★ RETURN_FOLLOWER.fn —— 归还猫猫到猫窝。
--   ★★ 4232 行四条件：target 有 follower + leader 是自己 +
--     doer 有 near_kitcoonden 标签 + 附近有 kitcoonden 实体。
--   ★★★ 最后一条是**运行时环境检查**（4234 行 FindEntities）。
--     ★ 一个动作需要「附近存在某个实体」才能执行 ——
--       这类检查通常应该在条件层（componentactions），
--       放在 fn 里意味着 UI 会显示动作但点击后失败。
--       ★ 4239 行的 `return false` 无 reason。
ACTIONS.RETURN_FOLLOWER.fn = function(act)
    if act.target ~= nil and act.target.components.follower ~= nil and act.target.components.follower:GetLeader() == act.doer and act.doer:HasTag("near_kitcoonden") then
		local x, y, z = act.target.Transform:GetWorldPosition()
		local den = TheSim:FindEntities(x, y, z, TUNING.KITCOON_NEAR_DEN_DIST, {"kitcoonden"})[1]
		if den ~= nil then
			den.components.kitcoonden:AddKitcoon(act.target, act.doer)
	        return true
		else
			return false
		end
    end
end

--★ HIDEANSEEK_FIND.fn —— 捉迷藏找藏身处。目标可以是 invobject。
ACTIONS.HIDEANSEEK_FIND.fn = function(act)
    local targ = act.target or act.invobject

    if targ ~= nil then
		if targ.components.hideandseekhidingspot ~= nil then
			targ.components.hideandseekhidingspot:SearchHidingSpot(act.doer)
			return true
		end
    end
end

--★★ 4255 行在函数中间 require —— 见 §2 474 行的详细分析。
--   ★★ 4256 行的 stroveroverridefn 定义在 require **之后** ——
--     ★ 而 4257 行就调用了 FindEntityToDraw。
--     ★ require 必须在使用之前，这行位置是「刚好正确」的。
--     ★ 若以后有人在 4255 行之前用到 FindEntityToDraw 会崩。
require("components/drawingtool")
ACTIONS.DRAW.stroverridefn = function(act)
    local item = FindEntityToDraw(act.target, act.invobject)
    return item ~= nil
        and subfmt(STRINGS.ACTIONS.DRAWITEM, { item = item.drawnameoverride or item:GetBasicDisplayName() })
        or nil
end

--★★ DRAW.fn —— 画画的七行。
--   ★★ 4269 行一次解包五个返回值：
--       image, src, atlas, bgimage, bgatlas
--     ★★★ 五个值全部来自 drawingtool:GetImageToDraw。
--     ★ 4270-4272 行 image 为 nil → return false, "NOIMAGE"。
--       ★★ 有明确 reason —— 画板里没画东西是很常见的用户错误，
--         值得给提示。
ACTIONS.DRAW.fn = function(act)
    if act.invobject ~= nil and
            act.target ~= nil and
            act.invobject.components.drawingtool ~= nil and
            act.target.components.drawable ~= nil and
            act.target.components.drawable:CanDraw() then
        local image, src, atlas, bgimage, bgatlas = act.invobject.components.drawingtool:GetImageToDraw(act.target, act.doer)
        if image == nil then
            return false, "NOIMAGE"
        end
        act.invobject.components.drawingtool:Draw(act.target, image, src, atlas, bgimage, bgatlas)
        return true
    end
end

--★ STARTCHANNELING.strfn —— PUMP 变体。
ACTIONS.STARTCHANNELING.strfn = function(act)
    return act.target:HasTag("pump") and "PUMP" or nil
end

--★★ STARTCHANNELING.fn —— 两行，**无组件 nil 保护**。
--   ★★★ 4283 行 `act.target.components.channelable:StartChanneling(doer)`：
--     ★ 若目标没有 channelable 组件 ⇒ `nil:StartChanneling` 崩溃。
--     ★ 依赖 componentactions 只在有 channelable 时提供本动作。
--     ★★ 对比本文件其它 fn 大多写 `components.X ~= nil and`：
--       这里假设了「有动作就一定有组件」。
--     ★ 4283 行还用了 `act.target ~= nil and` 而不是 `if`，
--       所以 target 为 nil 时返回 nil（安全）。
--     ★ 但 target 非 nil 而组件为 nil 时会崩。
--     ★ 记录为 L 类隐患（与 1883 行 FISH.fn 同型）。
ACTIONS.STARTCHANNELING.fn = function(act)
    return act.target ~= nil and act.target.components.channelable:StartChanneling(act.doer)
end

--★ STOPCHANNELING.fn —— 无条件 return true（即使 target 为 nil）。
--   ★★★ 4290 行的 `return true` 在 `if` 块**外面**：
--       if act.target ~= nil then StopChanneling end
--       return true
--     ★ 即「目标不存在也报告成功」。
--     ★ 与 STOPCHANNELING 的 instant 声明（486 行）一致：
--       停止动作应该总是「成功」（玩家的意图是「停下来」）。
ACTIONS.STOPCHANNELING.fn = function(act)
    if act.target ~= nil then
        act.target.components.channelable:StopChanneling(true)
    end
    return true
end

--★ START_CHANNELCAST.strfn —— LIGHTER 变体。
ACTIONS.START_CHANNELCAST.strfn = function(act)
	return act.invobject and act.invobject:HasTag("lighter") and "LIGHTER" or nil
end

--★★ START_CHANNELCAST.fn —— 「三种引导方式」的分支（14 行）。
--   ★★ 三个分支：
--     ① 4299-4301 invobject 为 nil → 副手引导（不传物品）
--     ② 4302-4308 invobject 有 channelcastable 且无人引导 → 用物品引导
--     ③ 4310      其余 → return false
--   ★★ 4302 行的 `not IsAnyUserChanneling()` ——
--     ★★★ 「**已经有人在引导**」检查。多人协作时防止两人同时引导。
--     ★ 与「别人在用箱子」的 IsOpenedByOthers 属同一类「联机独占」检查。
--   ★★ 4303-4305 的 ITEMMIMIC 守卫插在分支内部而非开头 ——
--     ★ 因为 ① 分支没有 invobject，不需要检查。
--     ★ 这个「守卫位置随分支变化」容易遗漏。
ACTIONS.START_CHANNELCAST.fn = function(act)
	if act.doer and act.doer.components.channelcaster then
		if act.invobject == nil then
			--off-hand channel casting
			return act.doer.components.channelcaster:StartChanneling()
		elseif act.invobject.components.channelcastable and not act.invobject.components.channelcastable:IsAnyUserChanneling() then
            if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
                return false, "ITEMMIMIC"
            end
			--equipped item channel casting
			return act.doer.components.channelcaster:StartChanneling(act.invobject)
		end
	end
	return false
end

--★ STOP_CHANNELCAST.strfn = START_CHANNELCAST.strfn —— T12 部分复用。
ACTIONS.STOP_CHANNELCAST.strfn = ACTIONS.START_CHANNELCAST.strfn

--★ STOP_CHANNELCAST.fn —— 停止引导，无条件 return true（同 4286 行）。
ACTIONS.STOP_CHANNELCAST.fn = function(act)
	if act.invobject and
		act.invobject.components.channelcastable and
		act.invobject.components.channelcastable:IsUserChanneling(act.doer)
	then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
		act.invobject.components.channelcastable:StopChanneling()
	end
	return true
end

--★★ BUNDLE.fn —— 打包。八行，含一个**参数疑似写错**的地方。
--   ★★★ 4335 行 `CanEntitySeeTarget(act.doer, act.doer)`：
--     ★★★ 两个参数都传了 **doer 自己**！
--       · 第一个参数应是「看的人」→ doer ✓
--       · 第二个参数应是「被看的东西」→ 这里也是 doer ✗
--     ★ 而打包的「目标」是 4329 行的 `target = act.invobject or act.target`。
--       正确写法应是 CanEntitySeeTarget(act.doer, target)。
--     ★★ 后果：`CanEntitySeeTarget(doer, doer)` 恒为真（自己当然看得见自己），
--       于是 4335-4337 行的「黑暗中静默失败」**完全失效**。
--       ★⇒ 玩家在黑暗中打包会正常打包（而 RUMMAGE/CHANGEIN/CONSTRUCT 等
--         都不会）。行为不一致。
--     ★★★ 判定依据：simutil.lua:547 CanEntitySeeTarget(inst, target)
--       的第二个参数在全文其它 6 处调用（1120/2806/4075/4418/6054/6098）
--       **无一例外**都传的是 act.target。
--     ★ 结论：**真实的笔误**（复制粘贴时漏改）。
--       影响：打包动作没有黑暗保护。只记录不修改。
ACTIONS.BUNDLE.fn = function(act)
    local target = act.invobject or act.target
    if target ~= nil and
        act.doer ~= nil and
        act.doer.components.bundler ~= nil and
        act.doer.components.bundler:CanStartBundling() then
        --Silent fail for bundling in the dark
        if CanEntitySeeTarget(act.doer, act.doer) then
            return act.doer.components.bundler:StartBundling(target)
        end
        return true
    end
end

--★★ WRAPBUNDLE.fn —— 捆扎完成。「空包」用说话反馈。
--   ★★ 4348-4350 行：容器为空时 Say 一句 WRAPBUNDLE/EMPTY。
--     ★★★ 为什么这里说话而 RUMMAGE 那种情况静默？
--       因为「捆扎」是一个**已经开始**的流程（玩家在捆东西），
--       走到最后一步发现是空的 ⇒ 必须解释。
--       ★ 这是「流程中段的失败」与「独立动作的失败」的区别。
ACTIONS.WRAPBUNDLE.fn = function(act)
    if act.doer ~= nil and
        act.doer.components.bundler ~= nil and
        act.doer.components.bundler:IsBundling(act.target) then
        if act.target.components.container ~= nil and not act.target.components.container:IsEmpty() then
            return act.doer.components.bundler:FinishBundling()
        elseif act.doer.components.talker ~= nil then
            act.doer.components.talker:Say(GetActionFailString(act.doer, "WRAPBUNDLE", "EMPTY"))
        end
        return true
    end
end

--★ UNWRAP.fn —— 拆包。canbeunwrapped 检查。
ACTIONS.UNWRAP.fn = function(act)
    local target = act.target or act.invobject
    if target ~= nil and
        target.components.unwrappable ~= nil and
        target.components.unwrappable.canbeunwrapped then
        target.components.unwrappable:Unwrap(act.doer)
        return true
    end
end

--★★ PEEKBUNDLE.fn —— 偷看包内（12 行）。
--   ★★ 4367 行的五条件 or/and 链：
--     有 unwrappable + canbeunwrapped + canpeek 标签
--     + 没在烧/冒烟 + bundler:CanStartBundling
--   ★★ 4370 行的 ReturnActiveItem ——
--     ★★★ 「把手上的东西先放回背包」再窥视。
--     ★ 因为窥视需要腾出手。
--     ★ 与 USESPELLBOOK.fn（5937 行）的同类调用同款。
ACTIONS.PEEKBUNDLE.fn = function(act)
    local target = act.target
    if target ~= nil and target.components.unwrappable ~= nil and target.components.unwrappable.canbeunwrapped and target:HasTag("canpeek") and not target:HasAnyTag("smolder", "fire") and
        act.doer and act.doer.components.bundler and act.doer.components.bundler:CanStartBundling() then
        if act.invobject and act.doer.components.inventory then
            act.doer.components.inventory:ReturnActiveActionItem(act.invobject)
        end
        return target.components.unwrappable:PeekInContainer(act.doer)
    end
end

--★ BREAK.strfn —— PICKAPART 变体。
ACTIONS.BREAK.strfn = function(act)
    local target = act.target or act.invobject
    return target ~= nil and target:HasTag("pickapart") and "PICKAPART" or nil
end

--★★ CONSTRUCT.stroverridefn —— 「建造 {名字}」的完整句子。
--   ★★ 4382-4390 的两个分支（手持材料 / 无材料）：
--     ★★ 4383 行的双重否定 `constructionname ~= nil and
--       not HasTag("constructionsite")` ——
--       有名字且**目标不是工地** ⇒ 这是「第一次放材料」（创建工地）。
--     ★ 名字来自 STRINGS.NAMES[string.upper(constructionname)]。
--     ★★ 与 4469 行 STOPCONSTRUCTION 用同一套写法。
ACTIONS.CONSTRUCT.stroverridefn = function(act)
    if act.invobject ~= nil then
        if act.invobject.constructionname ~= nil and not act.target:HasTag("constructionsite") then
            local name = STRINGS.NAMES[string.upper(act.invobject.constructionname)]
            return name ~= nil and subfmt(STRINGS.ACTIONS.CONSTRUCT.GENERIC_FMT, { name = name }) or nil
        end
    elseif act.target ~= nil and act.target.constructionname ~= nil then
        local name = STRINGS.NAMES[string.upper(act.target.constructionname)]
        return name ~= nil and subfmt(STRINGS.ACTIONS.CONSTRUCT.GENERIC_FMT, { name = name }) or nil
    end
end

--★★【CONSTRUCT.strfn —— 一个动作五种显示名（13 行）】
--   ★★ 五个分支：
--     手上材料 + offerconstructionsite → OFFER（递交）
--     手上材料 + constructionsite      → STORE（存放）
--     无材料 + offerconstructionsite  → OFFER_TO（交给某人）
--     无材料 + repairconstructionsite → REPAIR（维修）
--     无材料 + rebuildconstructionsite → REBUILD（重建）
--   ★★★ 分支顺序 = 「手持状态」× 「目标类型」的二维查表。
--     ★ 注意前两个分支的整体是 `and (...)`，后三个是 `or (...)`；
--       ★★★ 括号分组是关键：去掉括号会变成 5 个平级 or，
--         语义变成「任一条件满足就显示」而非「按优先级取第一个」。
--         ★ 这是全文件里最需要括号的一处（与 2789 行的缺陷对照）。
ACTIONS.CONSTRUCT.strfn = function(act)
    return act.invobject ~= nil
        and (
                (act.target:HasTag("offerconstructionsite") and "OFFER") or
                (act.target:HasTag("constructionsite")      and "STORE")
            )
        or  (
				(act.target:HasTag("offerconstructionsite") and "OFFER_TO") or
				(act.target:HasTag("repairconstructionsite") and "REPAIR") or
				(act.target:HasTag("rebuildconstructionsite") and "REBUILD")
            )
        or nil
end

--★★★【CONSTRUCT.fn —— 建造流程（59 行）】
--   ★★ 五步流程：
--     ① 4409-4410  前置（target/doer/constructionbuilder 都要有）
--     ② 4411-4415  已在建造中 → **静默 return true**
--     ③ 4416-4435  CanStartConstruction → StartConstruction
--     ④ 4417-4420  黑暗中静默 return true
--     ⑤ 4436-4462  「顺手把手上的材料放进去」
--   ★★★ ②的注释非常有价值（4412-4414 行）：
--     「静默失败，以防手柄玩家连打按钮，
--       因为我们在开始后仍会返回施工动作一次，
--       以免动作提示闪烁。」
--   ★★★ 这解释了一个反直觉的设计：**已经开始建造后还返回动作**。
--     玩家会看到「建造」提示持续存在而不是消失。
--     ★ 因为如果立即隐藏，手柄玩家会以为按钮没生效而继续按。
--     ★★ 「为特定输入设备做的 UI 妥协」的清晰记录。
ACTIONS.CONSTRUCT.fn = function(act)
    local target = act.target
    if target == nil or act.doer == nil or act.doer.components.constructionbuilder == nil then
        return false
    elseif act.doer.components.constructionbuilder:IsConstructingAny() then
        --Silent fail, in case of controller mashing buttons, since we continue to
        --return the construction action after it's initiated once, to prevent the
        --action prompts from flickering.
        return true
    elseif act.doer.components.constructionbuilder:CanStartConstruction() then
        --Silent fail for construction in the dark
        if not CanEntitySeeTarget(act.doer, target) then
            return true
        end

--★★ 4424-4431 行：「图纸纸」的处理（constructionplans 组件）。
--   ★★★ 玩家拿着「建筑图纸」对着空地 →
--       ① StartConstruction(target) 得到真正的工地
--       ② `item:Remove()` 消耗图纸
--       ③ `item = nil` 避免后续重复处理
--   ★★ 4429 行的无条件 Remove 是「消耗型蓝图」的正确处理。
        local item = act.invobject
        local success, reason
        if item ~= nil and item.components.constructionplans ~= nil and target.components.constructionsite == nil then
            target, reason = item.components.constructionplans:StartConstruction(target)
            if target == nil then
                return false, reason
            end
            item:Remove()
            item = nil
        end
        success, reason = act.doer.components.constructionbuilder:StartConstruction(target)
        if not success then
            return false, reason
        end
--★★★ 4436-4462 行：「顺手把手上的东西放进刚打开的工地」。
--   ★★ 流程：
--     ① 找到刚建的工地容器（constructioninst）
--     ② 若已打开，在 CONSTRUCTION_PLANS 里找该物品对应的槽位
--     ③ 找到了且槽位能放 → 放进去
--     ④ 没找到 → 说话（4458-4460 行）
--   ★★ 4442-4447 行是「按类型查槽位」的循环。
--     ★★★ CONSTRUCTION_PLANS[target.prefab] 是静态配置表。
--       「材料 prefab → 第几个槽位」的关系由配置决定，
--       所以是 O(n) 线性查找。
--       ★ 表不大，可接受。
--   ★★ 4450-4457 行的失败还回：与 §p5 2559 行的手柄分支同款。
        --Try to store whatever was on our mouse pointer
        if item ~= nil and item.components.inventoryitem ~= nil and act.doer.components.inventory ~= nil then
            local container = act.doer.components.constructionbuilder.constructioninst
            container = container ~= nil and container.components.container or nil
--★★ CONSTRUCT.fn 的「顺手放材料」在 4436-4462。
--   ★★ 流程：找工地容器 → 若已打开 → 按 prefab 查槽位 → 放入。
--   ★★★ 4442-4447 行的槽位查找是 O(n) 线性扫描 CONSTRUCTION_PLANS。
--     ★ 表不大（每种建材几个槽），可接受。
--   ★★ 4450-4457 的失败还回与 §p5 2559 行同款（手柄分支）。
            if container ~= nil and container:IsOpenedBy(act.doer) then
                local slot
                for i, v in ipairs(CONSTRUCTION_PLANS[target.prefab] or {}) do
                    if v.type == item.prefab then
                        slot = i
                        break
                    end
                end
--★★ CONSTRUCT.fn 的「顺手放材料」在 4448-4462：
--   ①4448  槽位能放？
--   ②4449  取出物品（按容器是否接受堆叠）
--   ③4450-4451 GiveItem，失败则还回（4452-4456 分手柄/键鼠）
--   ④4558-4460 没找到槽位 → 说话
--   ★★★ 与 §p5 2559 行的失败还回是同一段代码的第三次出现
--     （2546/4449/6353 都有 RemoveFromOwner + GiveItem + 还回）。
--   ★★ 4452-4456 的手柄分支：手柄玩家 GiveItem，键鼠玩家 GiveActiveItem。
--     ★★ 因为手柄没有「点物品」的概念。
                if slot ~= nil and container:CanTakeItemInSlot(item, slot) then
                    item = item.components.inventoryitem:RemoveFromOwner(container.acceptsstacks)
                    if item ~= nil and not container:GiveItem(item, slot, nil, false) then
                        if act.doer.components.playercontroller ~= nil and
                            act.doer.components.playercontroller.isclientcontrollerattached then
                            act.doer.components.inventory:GiveItem(item)
                        else
                            act.doer.components.inventory:GiveActiveItem(item)
                        end
                    end
                elseif act.doer.components.talker ~= nil then
--★ 4459 行 —— 「材料放不进去」的说话反馈。
--   ★★★ 与 §p5 2527/2533 的强制说话同款：
--     「构造是一个忙状态，所以需要强制说话」。
                    act.doer.components.talker:Say(GetActionFailString(act.doer, "CONSTRUCT", "NOTALLOWED"))
                end
            end
        end
        return true
    end
end

--★ STOPCONSTRUCTION.stroverridefn —— 「停止建造 {名字}」。
ACTIONS.STOPCONSTRUCTION.stroverridefn = function(act)
    if act.invobject == nil and act.target ~= nil and act.target.constructionname ~= nil then
        local name = STRINGS.NAMES[string.upper(act.target.constructionname)]
        return name ~= nil and subfmt(STRINGS.ACTIONS.STOPCONSTRUCTION.GENERIC_FMT, { name = name }) or nil
    end
end

--★ STOPCONSTRUCTION.strfn —— 与 4393 行的后三个分支相同。
ACTIONS.STOPCONSTRUCTION.strfn = function(act)
	return (act.target:HasTag("offerconstructionsite") and "OFFER")
		or (act.target:HasTag("repairconstructionsite") and "REPAIR")
		or (act.target:HasTag("rebuildconstructionsite") and "REBUILD")
		or nil
end

--★ STOPCONSTRUCTION.fn —— 四行，无条件 return true。
ACTIONS.STOPCONSTRUCTION.fn = function(act)
    if act.doer ~= nil and act.doer.components.constructionbuilder ~= nil then
        act.doer.components.constructionbuilder:StopConstruction()
    end
    return true
end

--★ APPLYCONSTRUCTION.strfn —— 与 4474 行完全相同的三个分支。
--   ★★ 与 STOPCONSTRUCTION.strfn 的差异：APPLY 用 `or` 起头且分支相同。
--     ★ 两个动作（停止 / 应用）的显示词完全一样，靠 stroverridefn 区分。
ACTIONS.APPLYCONSTRUCTION.strfn = function(act)
	return (act.target:HasTag("offerconstructionsite") and "OFFER")
		or (act.target:HasTag("repairconstructionsite") and "REPAIR")
		or (act.target:HasTag("rebuildconstructionsite") and "REBUILD")
		or nil
end

--★★ APPLYCONSTRUCTION.fn —— 「放最后一个材料」。
--   ★★ 与 WRAPBUNDLE.fn（4342）结构一致：
--     容器非空 → FinishConstruction
--     容器为空 → Say CONSTRUCT/EMPTY
--     return true
--   ★★★ 「流程中段」的动作都用这个模式。
ACTIONS.APPLYCONSTRUCTION.fn = function(act)
    if act.doer ~= nil and
        act.doer.components.constructionbuilder ~= nil and
        act.doer.components.constructionbuilder:IsConstructing(act.target) then
        if act.target.components.container ~= nil and not act.target.components.container:IsEmpty() then
            return act.doer.components.constructionbuilder:FinishConstruction()
        elseif act.doer.components.talker ~= nil then
            act.doer.components.talker:Say(GetActionFailString(act.doer, "CONSTRUCT", "EMPTY"))
        end
        return true
    end
end

--★ CASTAOE.stroverridefn —— 从 spellbook 组件取法术名。
ACTIONS.CASTAOE.stroverridefn = function(act)
	return act.invobject ~= nil and act.invobject.components.spellbook ~= nil and act.invobject.components.spellbook:GetSpellName() or nil
end

--★ CASTAOE.strfn —— 用 prefab 大写名当动词（与 3353 行同款）。
ACTIONS.CASTAOE.strfn = function(act)
    return act.invobject ~= nil and string.upper(act.invobject.prefab) or nil
end

--★ CASTAOE.fn —— AOE 施法。ITEMMIMIC 守卫在 CanCast **之后**。
--   ★★★ 4518 行的条件顺序：先 `CanCast(doer, pos)` 才做 ITEMMIMIC 检查。
--     ★ 与 CASTSPELL.fn（3437）的顺序**相反**（那里 ITEMMIMIC 在前）。
--     ★ 不一致但不致错（都只是不执行）。
--   ★★ 4522 行的返回值：`CastSpell(doer, pos)` 透传。
ACTIONS.CASTAOE.fn = function(act)
	local act_pos = act:GetActionPoint()
    if act.invobject ~= nil and act.invobject.components.aoespell ~= nil and act.invobject.components.aoespell:CanCast(act.doer, act_pos) then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
		return act.invobject.components.aoespell:CastSpell(act.doer, act_pos)
    end
end

--★ SCYTHE.fn —— 镰刀。用 `act.invobject.DoScythe` 而非组件。
--   ★★ 4527 行判断的是**方法存在**而不是组件存在。
--     ★ 与 ACTIVATE 的 GetActivateVerb（3097 行）同型：
--       「实体/物品自己提供方法」。
--   ★★ 4535 行的 `return false` 无 reason。
ACTIONS.SCYTHE.fn = function(act)
    if act.invobject ~= nil and act.invobject.DoScythe then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
        act.invobject:DoScythe(act.target, act.doer)
        return true
    end

    return false
end

--★ NABBAG.fn —— 网袋抓取。ITEMMIMIC 守卫 + 四层 and。
ACTIONS.NABBAG.fn = function(act)
    if act.doer and act.doer.components.inventory and act.invobject and act.invobject.components.nabbag then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        return act.invobject.components.nabbag:DoNabFromAct(act)
    end

    return false
end

--★★★【DISMANTLE.fn —— 拆除的完整前置检查（25 行）】
--   ★★ 4552-4553 行的条件有个例外：
--       `not (burnable and IsBurning()) or HasTag("campfire")`
--     ★★★ 「正在燃烧的东西不能拆，**但营火可以**」。
--       营火是唯一可以在燃烧时被拆除的东西（拆下来还能用）。
--       ★ 这条例外藏在双重否定里，是全文件最难读的条件之一。
--   ★★ 三种失败原因（4557/4559/4561）：
--     容器开着   → INUSE
--     容器非空   → NOTEMPTY
--     不可打开   → COOKING（★ 用于「正在烹饪的锅不能拆」）
--   ★★★ NOTEMPTY 与 COOKING 的区分很聪明：
--     「里面有东西」与「正在用但里面空着」是两种不同的拒绝理由。
--   ★★ 4567 行的 candismantle 回调 —— prefab 级的额外许可检查。
ACTIONS.DISMANTLE.fn = function(act)
    if act.target ~= nil and
        act.target.components.portablestructure ~= nil and
--★★ DISMANTLE.fn 的前置检查在 4552-4569。
--   ★★ 三种失败原因（INUSE / NOTEMPTY / COOKING）已在 4557/4559/4561 注释。
--   ★★★ 「NOTEMPTY」与「COOKING」的区分很聪明：
--     「里面有东西」与「正在用但里面空着」是两种不同的拒绝理由。
--   ★★ 4567 行的 candismantle 回调 —— prefab 级的额外许可检查。
		(not (act.target.components.burnable and act.target.components.burnable:IsBurning()) or act.target:HasTag("campfire")) then

        if act.target.components.container ~= nil then
            if act.target.components.container:IsOpen() then
                return false, "INUSE"
            elseif not act.target.components.container:IsEmpty() or (act.target.components.stewer ~= nil and act.target.components.stewer:IsDone()) then
                return false, "NOTEMPTY"
            elseif not act.target.components.container.canbeopened then
                return false, "COOKING"
            end
        elseif act.target.components.sleepingbag and act.target.components.sleepingbag:InUse() then
            return false, "INUSE"
        end

		if act.target.candismantle and not act.target:candismantle(act.doer) then
            return false
        end

        act.target.components.portablestructure:Dismantle(act.doer)
        return true
    end
end

--★ TACKLE.fn —— 冲撞。三条件 and 链直接作为返回值。
ACTIONS.TACKLE.fn = function(act)
    return act.doer ~= nil
        and act.doer.components.tackler ~= nil
        and act.doer.components.tackler:StartTackle()
end

--★★ HALLOWEENMOONMUTATE.fn —— 含一处**被放宽的判据**（§2 524 行已预告）。
--   ★★ 4585 行的注释块是被注释掉的完整条件：
--     `--or (not HasTag("flying") and not IsPassableAtPoint(...))`
--     ★★★ 保留这条注释的价值很高：它记录了
--       「曾经不允许对飞行物或非站立点使用，现在允许了」。
--   ★★ 4586 行的条件：目标在燃烧或冒烟 ⇒ 拒绝。
--     ★ 与 DASH 无关，纯游戏性限制（月亮药水不能浇着火的东西）。
ACTIONS.HALLOWEENMOONMUTATE.fn = function(act)
	if act.invobject ~= nil and act.invobject.components.halloweenpotionmoon ~= nil then
		if act.target == nil
			--or (not act.target:HasTag("flying") and not TheWorld.Map:IsPassableAtPoint(act.target.Transform:GetWorldPosition()))
			or (act.target.components.burnable ~= nil and (act.target.components.burnable:IsBurning() or act.target.components.burnable:IsSmoldering()))
			or (act.target.components.freezable ~= nil and act.target.components.freezable:IsFrozen()) then

			return false
		else
			act.invobject.components.halloweenpotionmoon:Use(act.doer, act.target)
			return true
		end
	end
end

--★ APPLYPRESERVATIVE.strfn —— SALT 变体（用盐岩）。
ACTIONS.APPLYPRESERVATIVE.strfn = function(act)
	return act.invobject ~= nil and act.invobject.prefab == "saltrock" and "SALT" or nil
end

--★★ APPLYPRESERVATIVE.fn —— 涂防腐剂的六条件准入。
--   ★★ 4603 行 `act.target.components.health == nil` ——
--     ★★★ 「不能给活着的东西涂防腐剂」（只能给食物）。
--     ★ 用 health 组件作为「是否活物」的判据 —— 简洁但间接。
--   ★★ 4604 行三个互斥的保质期标签（fresh/stale/spoiled）。
--   ★★ 4608-4614 行的除法：
--       `divide_effect_by_stack_size and stackable and
--        percent_increase / stacksize or percent_increase`
--     ★★★ 三元 + and 的混合。语义：一整叠盐岩的效果 = 单个的效果。
--       ★ 这意味着玩家用一叠盐岩比用一个更划算 —— 一个设计权衡。
--   ★★ 4616-4622 行：先改保质期，再消耗物品。
--     ★★★ 顺序是「先给效果后扣材料」—— 若扣材料失败（4617 行为 nil），
--       已经改了效果却 return false ⇒ 玩家白得一次效果。
--       ★ 潜在的小 bug，但 RemoveItem 失败概率极低（物品明明在手上）。
ACTIONS.APPLYPRESERVATIVE.fn = function(act)
	if act.target ~= nil and act.invobject ~= nil and act.invobject.components.preservative ~= nil
		    and act.target.components.health == nil
		    and (act.target:HasTag("fresh") or act.target:HasTag("stale") or act.target:HasTag("spoiled"))
--★★ APPLYPRESERVATIVE.fn 的除法技巧在 4608-4614。
--   ★★ 语义：一整叠盐岩的效果 = 单个的效果（除以叠数）。
--   ★★★ 这意味着玩家用一叠盐岩比用一个**更划算** —— 一个设计权衡。
--   ★★ 4616-4622 的「先给效果后扣材料」顺序有极小风险（见该处注释）。
		    and act.target:HasTag("cookable")
		    and not act.target:HasTag("deployable") then

		act.target.components.perishable:SetPercent(act.target.components.perishable:GetPercent() + (
			    act.invobject.components.preservative.divide_effect_by_stack_size and
                act.target.components.stackable and
                act.invobject.components.preservative.percent_increase / act.target.components.stackable.stacksize or
                act.invobject.components.preservative.percent_increase
			)
        )

		local used_preservative = act.doer.components.inventory:RemoveItem(act.invobject)
        if used_preservative ~= nil then
            used_preservative:Remove()
            return true
        else
			return false
        end
	else
		return false
	end
end

--★【COMPARE_WEIGHABLE_TEST —— 「标签交叉验证」（8 行）】
--   ★★★ 4630 行 `HasTag("trophyscale_"..v) and weighable:HasTag("weighable_"..v)`
--     ★★ 两侧都用同一个枚举值 v 拼接标签。
--     ★ 这是「无查表的类型匹配」：
--       「这个物品适不适合放这种秤上」由两组同名标签隐式表达。
--   ★★ TROPHYSCALE_TYPES 是个数组，遍历它就得到全部合法组合。
--     ★ 加新类型只需往 TROPHYSCALE_TYPES 加一个值。
--   ★★★ 这是本文件里最优雅的扩展设计之一。
local function COMPARE_WEIGHABLE_TEST(target, weighable)
    for _, v in pairs(TROPHYSCALE_TYPES) do
        if target:HasTag("trophyscale_"..v) and weighable:HasTag("weighable_"..v) then
            return true
        end
    end
    return false
end

--★★ COMPARE_WEIGHABLE.fn —— 「比重量」的 21 行。
--   ★★ 4638-4645 行的物体重推导：
--       weighable = invobject
--       若 invobject 为 nil → 查 BODY 槽（重物装备）
--     ★★★ 与 §p7 4660 行 WEIGH_ITEM.fn 的「三元推导」同族，
--       但这里是**逐个 if 递进**而非三元，更易读。
--   ★★ 4647-4653 行的六条件准入：target 有 trophyscale
--     + accept s_items + 不是 fire/burnt + COMPARE_WEIGHABLE_TEST
--   ★★ 4657 行的 `return false` 无 reason ——
--     ★ 而 4655 行的 return 是 Compare 的结果。
--       ⇒ 「不能比」与「比了但结果不通过」用不同返回值区分。
ACTIONS.COMPARE_WEIGHABLE.fn = function(act)
    local weighable = act.invobject

    if weighable == nil then
        local equipped = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
        if equipped ~= nil and equipped:HasTag("heavy") then
            weighable = equipped
        end
    end

	if act.target ~= nil and weighable ~= nil and
        weighable.components.weighable ~= nil and
		act.target.components.trophyscale ~= nil and
		act.target.components.trophyscale.accepts_items and
		not act.target:HasTag("fire") and
		not act.target:HasTag("burnt") and
        COMPARE_WEIGHABLE_TEST(act.target, weighable) then

		return act.target.components.trophyscale:Compare(weighable, act.doer)
	end
	return false
end

--★★★【WEIGH_ITEM.fn —— 「电子秤称重」的 16 行】
--   ★★ 4662-4665 行的**双向对象识别**（本文件最精妙的一段）：
--       weigher = target 有 itemweigher and target
--             or invobject 有 itemweigher and invobject
--             or nil
--       weighable = weigher ~= act.target and act.target or act.invobject
--   ★★★ 逐段读：
--     「秤在目标上」或「秤在手上」⇒ weigher 就位；都不是 ⇒ nil。
--     然后「不是秤的那一方就是被称物」。
--     ★★ 结果：无论玩家把秤放地上还是拿手上、
--       无论物品在地上还是拿着，四个组合全部正确。
--   ★★★ 这比 TOSS/DROP 里的 `target or invobject` 更高一阶 ——
--     它需要**判断哪个对象扮演哪个角色**，而不仅是「二选一」。
--     ★ 这是本文件里最值得学习的对象识别写法。
--   ★★ 4668-4669 行的 fire/burnt 检查与 COMPARE_WEIGHABLE 完全一致。
ACTIONS.WEIGH_ITEM.fn = function(act)
	if act.target ~= nil and act.invobject ~= nil then
		local weigher = act.target.components.itemweigher and act.target
						or act.invobject.components.itemweigher and act.invobject
						or nil
		local weighable = weigher ~= act.target and act.target or act.invobject

		if weigher and weighable and
			not weigher:HasTag("fire") and
			not weigher:HasTag("burnt") then

			return weigher.components.itemweigher:DoWeighIn(weighable, act.doer)
		end
	end
	return false
end

--★ START_CARRAT_RACE.fn —— 开赛。赛程存在世界组件里。
--   ★★ 4686-4688 行的延时说话：DoTaskInTime(2, ...) ——
--     ★★★ 「开赛后 2 秒再说一句话」。
--       ★ 目的是等玩家喊完话再触发赛跑台词。
--       ★★ 这是本文件里**唯一的 DoTaskInTime 调用**（延时任务）。
--       ★ 与协程不同（DoTask 是定时器，不阻塞）。
--     ★ 4687 行的闭包里又访问 act —— act 可能已失效（已释放）。
--       ★ 实践中 2 秒内动作不会失效。但属潜在的悬垂引用。
--       ★ 记录为 L 类隐患（闭包持有已过期的 act）。
ACTIONS.START_CARRAT_RACE.fn = function(act)
	if act.target ~= nil and act.target.components.yotc_racestart ~= nil and act.target.components.yotc_racestart:CanInteract() and
		not (act.target:HasTag("fire") or act.target:HasTag("burnt")) then

        local race_data = TheWorld.components.yotc_raceprizemanager ~= nil and TheWorld.components.yotc_raceprizemanager:GetRaceById(act.target) or nil
        if not race_data or (race_data.num_racers == nil or race_data.num_racers == 0) then
            return false, "NO_RACERS"
        end
		act.target.components.yotc_racestart:StartRace()
        if act.doer and act.target.racestartstring then
            act.doer:DoTaskInTime(2,function() if act.target:HasTag("race_on") then act.doer.components.talker:Say(GetString(act.doer, act.target.racestartstring)) end end)
        end
		return true
	end
end

--★ TILL.fn —— 开垦（§2 535 行 distance=0.5 的原因在此实现）。
--   ★★ 4694 行 `tiller = act.invobject or act.doer` ——
--     ★ 「没有工具也能犁地」（某些角色自带）。
--     ★ 与 SHAVE/SMOTHER 同款的 T7 变体。
--   ★★ 4699 行 ITEMMIMIC 守卫的**参数是 tiller 而非 invobject** ——
--     ★ 若 tiller 是 doer（空手），ShouldItemMimicBeRevealedFor(doer, doer)
--       的行为由该函数决定（componentutil.lua:2087 应该有组件检查）。
ACTIONS.TILL.fn = function(act)
    local tiller = act.invobject or act.doer
    if tiller ~= nil then
        if ShouldItemMimicBeRevealedFor(tiller, act.doer) then
            return false, "ITEMMIMIC"
        end

		if tiller.components.farmtiller ~= nil then
			return tiller.components.farmtiller:Till(act:GetActionPoint(), act.doer)
		elseif tiller.components.quagmire_tiller ~= nil then --Quagmire
        	return tiller.components.quagmire_tiller:Till(act:GetActionPoint(), act.doer)
        end
    end
end

--★ PLANTSOIL.fn —— 种土。四层分支 + 一处还回（4723 行）。
--   ★★ 4714-4722 行的 if/elseif 结构：
--     quagmire_plantable → Plant
--     farmplantable     → Plant
--     都不行 → 4723 行还回种子
--   ★★★ 这里是**正确的 if/elseif + 尾部还回**结构，
--     与 2619 行 PLANT.fn 的「elseif 不成立就不还回」形成对照。
--     ★⇒ 同一文件里两种写法，一种健壮一种脆弱。
ACTIONS.PLANTSOIL.fn = function(act)
    if act.invobject ~= nil and
        act.doer.components.inventory ~= nil and
        act.target ~= nil and act.target:HasTag("soil") then
        local seed = act.doer.components.inventory:RemoveItem(act.invobject)
        if seed ~= nil then
            if seed.components.quagmire_plantable ~= nil then
				if seed.components.quagmire_plantable:Plant(act.target, act.doer) then
                return true
            end
			elseif seed.components.farmplantable ~= nil then
				if seed.components.farmplantable:Plant(act.target, act.doer) then
					return true
				end
            end
            act.doer.components.inventory:GiveItem(seed)
        end
    end
end

--★ INSTALL.fn —— 安装。两条 Quagmire 安装路径。
--   ★★ 4734 行的 SpawnPrefab + 4736 行的 invobject:Remove() ——
--     ★ 「消耗安装件，生成安装物」。
--   ★★ 4742 行的 `DoInstall(act.target)` 直接返回布尔，
--     作为整个函数的结果（短路）。
ACTIONS.INSTALL.fn = function(act)
    if act.invobject ~= nil and act.target ~= nil then
        if act.invobject.components.quagmire_installable ~= nil and
            act.invobject.components.quagmire_installable.installprefab ~= nil and
            act.target.components.quagmire_installations ~= nil and
            act.target.components.quagmire_installations:IsEnabled() then
            local part = SpawnPrefab(act.invobject.components.quagmire_installable.installprefab)
            if part ~= nil then
                act.invobject:Remove()
                act.target.components.quagmire_installations:Install(part)
                return true
            end
        elseif act.invobject.components.quagmire_saltextractor ~= nil
            and act.target.components.quagmire_saltpond ~= nil
            and act.invobject.components.quagmire_saltextractor:DoInstall(act.target) then
            act.invobject:Remove()
            return true
        end
    end
end

--★ TAPTREE.fn —— 接/卸树液管。两分支。
ACTIONS.TAPTREE.fn = function(act)
    if act.target ~= nil and  act.target.components.quagmire_tappable ~= nil then
        if act.target.components.quagmire_tappable:IsTapped() then
            act.target.components.quagmire_tappable:UninstallTap(act.doer)
            return true
        elseif act.invobject ~= nil and act.invobject.components.quagmire_tapper ~= nil then
            act.target.components.quagmire_tappable:InstallTap(act.doer, act.invobject)
            return true
        end
    end
end

--★ TAPTREE.strfn —— UNTAP 变体。
--   ★★ 4762 行 `not HasTag("tappable") and "UNTAP" or nil` ——
--     ★ 三元模式：(not X) and "UNTAP" or nil。
--       ★ 用 and/or 而不是 if，因为要「条件不满足返回 nil 而非 false」。
--         ★★★ 这正是 p1 320 行讲过的 Lua 惯用法的关键点：
--           `X and A or nil` 当 X 为假时结果是 nil；
--           若写成 `X and A or false` 结果是 false（语义等价但不同值）。
--       ★ 很多下游代码用 `~= nil` 判断，两种值行为相同。
ACTIONS.TAPTREE.strfn = function(act)
    return not act.target:HasTag("tappable") and "UNTAP" or nil
end

--★ SLAUGHTER.stroverridefn —— 用物品的 GetSlaughterActionString 回调。
ACTIONS.SLAUGHTER.stroverridefn = function(act)
    return act.invobject ~= nil
        and act.invobject.GetSlaughterActionString ~= nil
        and act.invobject:GetSlaughterActionString(act.target)
        or nil
end

--★★ SLAUGHTER.fn —— 手写距离检查（§2 539 行已预告）。
--   ★★ 4778 行 `not (IsInLimbo() or doer:IsNear(target, 2))` ——
--     ★★★ 距离是 **2 格**，比 DefaultRangeCheck(4) 近一半。
--     ★ 屠宰需要「贴身」（用刀在喉子上），2 格合理。
--     ★ 与 811 行 STEAL 的 `< 16`（=4 格）是同类但不同值的写法。
--     ★★ 4780 行 `health ~= nil and not IsDead()` ⇒ 死了就返回 nil（静默）。
ACTIONS.SLAUGHTER.fn = function(act)
    if act.invobject.components.quagmire_slaughtertool ~= nil and act.invobject:IsValid() and act.doer:IsValid() then
        if act.target == nil then
            return false, "TOOFAR"
        elseif not (act.target:IsValid() and act.target:HasTag("canbeslaughtered")) then
            return false
        elseif not (act.target:IsInLimbo() or act.doer:IsNear(act.target, 2)) then
            return false, "TOOFAR"
        elseif act.target.components.health ~= nil and not act.target.components.health:IsDead() then
            act.invobject.components.quagmire_slaughtertool:Slaughter(act.doer, act.target)
            return true
        end
    end
end

--★ REPLATE.stroverridefn —— 用 prefab 名切片推断菜系（与 p4 2229 行同型）。
ACTIONS.REPLATE.stroverridefn = function(act)
    --Quagmire action strings
    local replatable_inst = (act.target ~= nil and act.target:HasTag("quagmire_replatable") and act.target) or (act.invobject ~= nil and act.invobject:HasTag("quagmire_replatable") and act.invobject) or nil
    if replatable_inst ~= nil then
        local i = replatable_inst.prefab:find("_", 15)
        if i ~= nil then
            local dish = STRINGS.NAMES[string.upper(replatable_inst.prefab:sub(1, i - 1))]
            return dish ~= nil and subfmt(STRINGS.ACTIONS.REPLATE.FMT, { dish = dish }) or nil
        end
    end
end

--★★★⚠ 疑似缺陷 L12：BATHBOMB.fn 的连锁调用。
--     `act.doer.components.inventory:RemoveItem(act.invobject):Remove()`
--   ★★★ 推理：RemoveItem **可能返回 nil**（§p3 4650 行已核实：
--     它在找不到物品时返回 nil，inventory.lua:1391-1392 直接 return）。
--     此处用 `:` 直接调 Remove() ⇒ 若返回 nil ⇒ **index a nil value 崩溃**。
--   ★★ 对比本文件其它 12 处同类调用，**全都先判 nil**：
--     · 2159 `local ingredient = ...:RemoveItem(...)` 后判 `ingredient ~= nil`
--     · 2383 `local item = ...` 后判
--     · 3005 `local removeditem = ...` 后判
--     · 4735 `local part = SpawnPrefab(...)` 后判
--     · 5450 `local new_weed = SpawnPrefab(...)` 无判（但 5507 行）
--   ★★ 唯一一处直接链式调用 ⇒ 与全文件风格不一致。
--   ★★★ 条件（4798 行无检查）只保证 invobject 非 nil，
--     不保证 RemoveItem 成功。
--   ★ 触发条件：玩家在浴缸旁丢了一个浴弹（RemoveItem 会成功），
--     或者某种竞态下物品已被移除。可复现性中等。
--   ★★★ 结论：**真实的 nil 解引用风险**。只记录不修改。
--     ★ 顺带：4807 行的 end 缩进错位，说明这段代码质量本就偏低。
ACTIONS.BATHBOMB.fn = function(act)
    local bathbombable = (act.target ~= nil and act.target.components.bathbombable) or nil
    local bathbomb = (act.invobject ~= nil and act.invobject.components.bathbomb) or nil

	if bathbomb ~= nil and bathbombable ~= nil and bathbombable.can_be_bathbombed then
	    bathbombable:OnBathBombed(act.invobject, act.doer)
		act.doer.components.inventory:RemoveItem(act.invobject):Remove()
		return true
        end
    end

--★★ 保留的英文注释「this name is backwards」（§2 549 行已详述）。
ACTIONS.RAISE_SAIL.fn = function(act)     -- this name is backwards. "raising" in this case means making a full sail
	if act.target ~= nil and act.target.components.mast ~= nil then
		act.target.components.mast:UnfurlSail()
		return true
	end
end

ACTIONS.RAISE_SAIL.stroverridefn = function(act)
    return STRINGS.ACTIONS.RAISE_SAIL
end

ACTIONS.LOWER_SAIL.fn = function(act) -- this name is backwards. "lowering" in this case means wrapping the sail up
    return true
end

ACTIONS.LOWER_SAIL.stroverridefn = function(act)
    return STRINGS.ACTIONS.LOWER_SAIL
end

--★ LOWER_SAIL_BOOST.fn —— 加速降帆。两个乘数相乘（4832 行）。
--   ★★ `expertsailor:GetLowerSailStrength() or TUNING.DEFAULT_SAIL_BOOST_STRENGTH`
--     × `(doer:HasTag("master_crewman") and MULT or 1)`
--     ★★★ 与 1697 行的 numworks 是同一「效率 × 乘数」结构。
--   ★★ 4836 行的 on_lower_sail_boost 事件 —— 「降帆加速」的自定义事件。
ACTIONS.LOWER_SAIL_BOOST.fn = function(act)
	if act.target ~= nil and act.target.components.mast ~= nil and act.target.components.mast.is_sail_raised then

        local strength = (act.doer.components.expertsailor ~= nil and act.doer.components.expertsailor:GetLowerSailStrength() or TUNING.DEFAULT_SAIL_BOOST_STRENGTH) * (act.doer:HasTag("master_crewman") and TUNING.MASTER_CREWMAN_MULT.LOWER_SAILT_BOOST or 1)

        act.target.components.mast:AddSailFurler(act.doer, strength)

		act.doer:PushEvent("on_lower_sail_boost")
		return true
	end
end

--★ GetLowerSailStr —— 「按船长相选词」（11 行）。
--   ★★ 4846 行只检查 doer:HasTag("switchtoho") 一个条件。
--     ★★★ 这是一个「极简的个性化」：只区分「切换到了霍」的角色。
--       ★ 用一个标签就做出了「不同玩家看到不同的台词」的体验。
--   ★★ 三处调用（4853/4861/以及 4857 的 LOWER_SAIL_FAIL.stroverridefn）——
--     ★ 成功与失败共用同一个词选择器。
local function GetLowerSailStr(act)
    local doer = act.doer

    local str_idx = 1

    if doer:HasTag("switchtoho") then
        str_idx = 2
    end

    return STRINGS.ACTIONS.LOWER_SAIL_BOOST[str_idx]
end

ACTIONS.LOWER_SAIL_BOOST.stroverridefn = function(act)
    return GetLowerSailStr(act)
end

--★★ LOWER_SAIL_FAIL.fn —— 一行 return true（影子动作，§2 552 行已预告）。
--   ★★ 与 LOWER_SAIL_BOOST 的差别只在 **do_not_locomote**（§2 已述）。
--   ★ 4857-4859 这两行 fn 加一行注释，是本文件里最简的实现。
ACTIONS.LOWER_SAIL_FAIL.fn = function(act)
    return true
end

ACTIONS.LOWER_SAIL_FAIL.stroverridefn = function(act)
    return GetLowerSailStr(act)
end


--★ RAISE_ANCHOR.fn / LOWER_ANCHOR.fn —— 各一行转发。
ACTIONS.RAISE_ANCHOR.fn = function(act)
    return act.target.components.anchor:AddAnchorRaiser(act.doer)
end

ACTIONS.LOWER_ANCHOR.fn = function(act)
    return act.target.components.anchor:StartLoweringAnchor()
end

--★ MOUNT_PLANK.fn / DISMOUNT_PLANK.fn —— 跳板上下。
--   ★★ 两者的距离差异（0.5 vs 2.5，§2 558 行已解释）。
ACTIONS.MOUNT_PLANK.fn = function(act)
    return act.target.components.walkingplank:MountPlank(act.doer)
end

ACTIONS.DISMOUNT_PLANK.fn = function(act)
    act.target.components.walkingplank:DismountPlank(act.doer)
    return true
end

--★ ABANDON_SHIP.fn —— 弃船。
ACTIONS.ABANDON_SHIP.fn = function(act)
    return act.target.components.walkingplank:AbandonShip(act.doer)
end

ACTIONS.EXTEND_PLANK.fn = function(act)
    act.target.components.walkingplank:Extend()
    return true
end

ACTIONS.RETRACT_PLANK.fn = function(act)
    act.target.components.walkingplank:Retract()
    return true
end

--★ REPAIR_LEAK.fn —— 补船漏。
--   ★★ 4898 行同时检查 boatleak 组件与 boat_leak 标签 ——
--     ★ 组件与标签双重确认，避免误触。
ACTIONS.REPAIR_LEAK.fn = function(act)
    if act.invobject ~= nil and act.target ~= nil and act.target.components.boatleak ~= nil and act.target:HasTag("boat_leak") then
	    return act.target.components.boatleak:Repair(act.doer, act.invobject)
	end
end

--★ STEER_BOAT.pre_action_cb —— 关法术轮盘（§2 T10 的第 1 类用途）。
--   ★★ 4904 行 `if act.doer.HUD ~= nil` —— HUD 可能不存在（服务端）。
--     ★★★ pre_action_cb 在**双端都跑**（§p4 338 行），
--       所以必须有 HUD nil 检查。
--       ★ 这与 fn（fn 只在服务端跑，不需要 HUD 检查）是重要区别。
ACTIONS.STEER_BOAT.pre_action_cb = function(act)
	if act.doer.HUD ~= nil then
		act.doer.HUD:CloseSpellWheel()
	end
end

--★ STEER_BOAT.fn —— 掌舵的准入检查。
--   ★★ 4911 行 `steeringwheel.sailor == nil` ——
--     ★★★ 「还没有人在掌舵」。多人服务器上多人可同时握舵？
--       4915 行的 SetSteeringWheel(act.target) 会设置这个字段。
--       ★ 但 4944 行的职业限定（expertsailor）说明每次只能一人掌舵。
--   ★★ 4912 行排除「正在燃烧的舵轮」。
ACTIONS.STEER_BOAT.fn = function(act)
	if act.target ~= nil
		and (act.target.components.steeringwheel ~= nil and act.target.components.steeringwheel.sailor == nil)
		and (act.target.components.burnable ~= nil and not act.target.components.burnable:IsBurning())
		and act.doer.components.steeringwheeluser ~= nil then

		act.doer.components.steeringwheeluser:SetSteeringWheel(act.target)
		return true
	end
end

--★ SET_HEADING.fn —— 摇船的三行（§2 562 行的 9999 已详述）。
--   ★★ 4923 行 `Steer(act_pos.x, act_pos.z)` ——
--     ★★★ 只取 x/z（水平），忽略 y —— 船的航向是水平面概念。
--   ★ 4925 行的 return false 无 reason。
ACTIONS.SET_HEADING.fn = function(act)
	if act.doer.components.steeringwheeluser ~= nil then
		local act_pos = act:GetActionPoint()
	    return act.doer.components.steeringwheeluser:Steer(act_pos.x, act_pos.z)
	end
    return false
end

--★ STOP_STEERING_BOAT.fn —— 停止掌舵，无条件 return true（instant）。
ACTIONS.STOP_STEERING_BOAT.fn = function(act)
	if act.doer.components.steeringwheeluser ~= nil then
	    act.doer.components.steeringwheeluser:SetSteeringWheel(nil)
	end
    return true
end

--★★【CAST_NET.fn —— 撒网（16 行）】
--   ★★ 4941-4947 行：目标点优先用 GetActionPoint，回退到 target 位置。
--     ★★★ 与 OCEAN_FISHING_CAST.fn（1395 行）**完全同型**：
--       `if pos == nil then pos = act.target:GetPosition() end`
--     ★ 「玩家用光标点海面」而不是「点某个船」。
--   ★★ 4950 行的 `return false` 无 reason。
ACTIONS.CAST_NET.fn = function(act)
    if act.invobject and act.invobject.components.fishingnet then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

		local act_pos = act:GetActionPoint()
        if act_pos == nil then
            local pos_x, pos_y, pos_z = act.target.Transform:GetWorldPosition()
            act.invobject.components.fishingnet:CastNet(pos_x, pos_z, act.doer)
        else
            act.invobject.components.fishingnet:CastNet(act_pos.x, act_pos.z, act.doer)
        end
        return true
    end
    return false
end

--★★ ROTATE_BOAT_* 三兄弟 —— 「旋转船」的三个动作。
--   ★★ 三行 fn 的结构完全相同，只差传入的 -1/1/0：
--     CLOCKWISE       → 1  （顺时针）
--     COUNTERCLOCKWISE→ -1 （逆时针）
--     STOP            → 0  （停止）
--   ★★★ **三个动作 + 一个数值字段** 表达「一个可连续调节的参数」。
--     ★ 这是一种很轻量的「模拟量输入」建模：
--       不用模拟摇杆，而是用三个离散动作 + 方向值。
--     ★ 对比 SET_HEADING（4920）用光标位置做模拟量 —— 两种风格并存。
--   ★★ 4953-4957 的 CLOCKWISE 无 stroverridefn（用默认串），
--     而 4967 行的 COUNTERCLOCKWISE 有 ——
--     ★ 不对称。可能是遗漏（§2 585-586 行那两个 show_* 字段也不对称）。
ACTIONS.ROTATE_BOAT_CLOCKWISE.fn = function(act)
    if act.target.components.boatrotator ~= nil then
        act.target.components.boatrotator:SetRotationDirection(1)
    end
    return true
end

ACTIONS.ROTATE_BOAT_COUNTERCLOCKWISE.fn = function(act)
    if act.target.components.boatrotator ~= nil then
        act.target.components.boatrotator:SetRotationDirection(-1)
    end
    return true
end

ACTIONS.ROTATE_BOAT_COUNTERCLOCKWISE.stroverridefn = function(act)
    return STRINGS.ACTIONS.ROTATE_BOAT_COUNTERCLOCKWISE
end

--★ ROTATE_BOAT_STOP.fn —— 第三兄弟。
ACTIONS.ROTATE_BOAT_STOP.fn = function(act)
    if act.target.components.boatrotator ~= nil then
        act.target.components.boatrotator:SetRotationDirection(0)
    end
    return true
end

ACTIONS.ROTATE_BOAT_STOP.stroverridefn = function(act)
    return STRINGS.ACTIONS.ROTATE_BOAT_STOP
end

--★ BOAT_MAGNET_ACTIVATE.fn —— 「跳到船的找船」按钮。
--   ★★ 4984 行 `act.target.sg:GoToState("search_pre")` ——
--     ★★★ **直接操作目标的状态图**（不是执行者 doer 的）。
--     ★ 这意味着「船会自己做出找船的表演」，与玩家无关。
--       ★ 很少见的「动作触发 NPC 的状态」写法。
--     ★ 4985 行的 return true 在 if 外（无条件成功）。
ACTIONS.BOAT_MAGNET_ACTIVATE.fn = function(act)
    if act.target.components.boatmagnet ~= nil then
        act.target.sg:GoToState("search_pre")
    end
    return true
end

ACTIONS.BOAT_MAGNET_DEACTIVATE.fn = function(act)
    if act.target.components.boatmagnet ~= nil then
        act.target.components.boatmagnet:UnpairWithBeacon()
    end
    return true
end

--★ BOAT_MAGNET_BEACON_TURN_* —— 信标开关。两行。
--   ★★ 4997 行 `act.target ~= nil and act.target or act.invobject` ——
--     ★★★ 三元的 and/or 用法：target 存在就用它，否则用 invobject。
--       ★ 等价于 `act.target or act.invobject`（因为 target 非 nil 时 and 返回它）。
--       ★ 写成前者是为了「强调这是有条件的降级」。属冗余但无害。
ACTIONS.BOAT_MAGNET_BEACON_TURN_ON.fn = function(act)
    local beacon = act.target ~= nil and act.target or act.invobject
    if beacon == nil then
        return
    end

    if beacon.components.boatmagnetbeacon ~= nil then
        beacon.components.boatmagnetbeacon:TurnOnBeacon()
    end
    return true
end

ACTIONS.BOAT_MAGNET_BEACON_TURN_OFF.fn = function(act)
    local beacon = act.target ~= nil and act.target or act.invobject
    if beacon == nil then
        return
    end

    if beacon.components.boatmagnetbeacon ~= nil then
        beacon.components.boatmagnetbeacon:TurnOffBeacon()
    end
    return true
end

--★ IsBoatCannonAmmo —— 一个两行的「物品谓词」（predicate）。
--   ★★ 5021 行要求两个条件：projectilepefab 字段 + boatcannon_ammo 标签。
--     ★ 字段存在 ⇒ 这个物品有对应的炮弹 prefab。
--   ★★★ 这个函数被传给 inventory:FindItem（5030 行）——
--     ★ 「按谓词在背包里找物品」，比手写循环更清晰。
local function IsBoatCannonAmmo(item)
	return item.projectileprefab ~= nil and item:HasTag("boatcannon_ammo")
end

--★★【BOAT_CANNON_LOAD_AMMO.fn —— 装弹的 24 行】
--   ★★ 5028-5033 行的双输入路径：
--     手上没东西 → 在背包里自动找（右键装弹）
--     手上有东西且是炮弹 → 用手上的
--     ★★★ 于是「装弹」支持两种交互方式。
--   ★★ 5037 行 `RemoveItem(ammo, false, true)` 的三个参数：
--     wholestack=false（只拿一个）、checkallcontainers=true
--     ★★★ checkallcontainers=true 意味着「背包里没有也会去打开的箱子里找」。
--       ★ 这是为了支持「把弹药放在旁边的箱子里也能装」。
--       ★ 但 5030 行的 FindItem **不**查容器 ⇒ 两条路径不一致。
--       ★ 记录为 L 类不一致。
--   ★★ 5038 行 `removeditem:Remove()` —— ★ 与 4805 行 BATHBOMB 同样的
--     无 nil 保护链式调用（L12 的同型问题）。
--     ★ 这里更容易触发（若 ammo 已被别处移除）。
--   ★★ 5039/5043 行的 Say —— 「装好了」「没弹药」两种反馈。
--     ★ 5042 行的条件 `talker ~= nil and activeitem == nil`：
--       ★★★ 「没弹药」的提示**只在空手时**播。
--         ★ 逻辑：手上拿着东西却装不了弹 → 那是「弹药不对」而非「没弹药」。
--         ★★★ 区分两种失败原因的精细 UX 设计。
--   ★ 5046 行的 `return true` 在 if 外 —— 与 5044 行的 Say 组合：
--     「说了『没弹药』但仍报告成功」。★ 静默失败模式。
ACTIONS.BOAT_CANNON_LOAD_AMMO.fn = function(act)
    if act.target.components.boatcannon ~= nil and not act.target.components.boatcannon:IsAmmoLoaded() and act.doer.components.inventory ~= nil then
        local activeitem = act.doer.components.inventory:GetActiveItem()
		local ammo
		if activeitem == nil then
			-- Not holding an item, so we must be right-clicking to reload.
			ammo = act.doer.components.inventory:FindItem(IsBoatCannonAmmo)
		elseif IsBoatCannonAmmo(activeitem) then
			ammo = activeitem
		end

		if ammo ~= nil then
			act.target.components.boatcannon:LoadAmmo(ammo.projectileprefab)
            local removeditem = act.doer.components.inventory:RemoveItem(ammo, false, true)
            removeditem:Remove()
            act.doer.components.talker:Say(GetDescription(act.doer, act.target, "AMMOLOADED"))

            return true
        elseif act.doer.components.talker ~= nil and activeitem == nil then
            act.doer.components.talker:Say(GetDescription(act.doer, act.target, "NOAMMO"))
        end
	end
    return true
end

--★ BOAT_CANNON_START_AIMING.pre_action_cb —— 关法术轮盘（同 STEER_BOAT）。
ACTIONS.BOAT_CANNON_START_AIMING.pre_action_cb = function(act)
	if act.doer.HUD ~= nil then
		act.doer.HUD:CloseSpellWheel()
	end
end

--★ BOAT_CANNON_START_AIMING.fn —— 与 STEER_BOAT.fn 结构完全相同。
ACTIONS.BOAT_CANNON_START_AIMING.fn = function(act)
    if act.target ~= nil
		and (act.target.components.boatcannon ~= nil and act.target.components.boatcannon.operator == nil)
		and (act.target.components.burnable ~= nil and not act.target.components.burnable:IsBurning())
		and act.doer.components.boatcannonuser ~= nil then

		act.doer.components.boatcannonuser:SetCannon(act.target)
		return true
	end
end

--★★★【BOAT_CANNON_SHOOT.fn —— 开炮的 22 行，双分支】
--   ★★ 分支①（5067-5080）：玩家正在用炮
--     ① 取 cannon（5070 行 GetCannon）
--     ② 有瞄准点就 FacePoint 转向（5071-5074）
--     ③ `cannon.sg:GoToState("shoot")` —— ★ 与 4984 行同型：
--       操作**炮的状态图**（不是玩家）。
--     ④ SetCannon(nil) 解除绑定
--     ⑤ 若玩家在 is_using_cannon 状态 → 切到 aim_cannon_pst（收炮姿势）
--   ★★ 分支②（5081-5086）：无绑定 → 直接让目标的炮开火。
--     ★★★ 这支持「NPC 炮手」或「触发器」场景。
--   ★★ 5087 行的 return true 无条件。
ACTIONS.BOAT_CANNON_SHOOT.fn = function(act)
    local boatcannonuser = act.doer.components.boatcannonuser
    if boatcannonuser ~= nil then
        local cannon = boatcannonuser:GetCannon()
        if cannon ~= nil then
            local pos = act:GetActionPoint()
            if pos ~= nil then
                cannon:FacePoint(pos)
            end
            cannon.sg:GoToState("shoot")
            boatcannonuser:SetCannon(nil)
            if act.doer.sg ~= nil and act.doer.sg:HasStateTag("is_using_cannon") then
                act.doer.sg:GoToState("aim_cannon_pst")
            end
        end
    else
        local cannon = act.target
        if cannon ~= nil then
            cannon.sg:GoToState("shoot")
        end
    end
    return true
end

--★ BOAT_CANNON_STOP_AIMING.fn —— 解除炮绑定，无条件 true。
ACTIONS.BOAT_CANNON_STOP_AIMING.fn = function(act)
	if act.doer.components.boatcannonuser ~= nil then
	    act.doer.components.boatcannonuser:SetCannon(nil)
	end
    return true
end

--★ OCEAN_TRAWLER_* 三兄弟 —— 拖网的放下/升起/修理。
--   ★★ 三者都是「调组件 + return true」的三行结构。
ACTIONS.OCEAN_TRAWLER_LOWER.fn = function(act)
    if act.target.components.oceantrawler ~= nil then
        act.target.components.oceantrawler:Lower()
	end
    return true
end

ACTIONS.OCEAN_TRAWLER_RAISE.fn = function(act)
    if act.target.components.oceantrawler ~= nil then
        act.target.components.oceantrawler:Raise()
	end
    return true
end

--★ OCEAN_TRAWLER_FIX.fn —— 唯一会先说话再行动的。
--   ★★ 5113 行 Say 在 5114 行的 Fix **之前** —— 顺序在这里不重要。
ACTIONS.OCEAN_TRAWLER_FIX.fn = function(act)
    if act.target.components.oceantrawler ~= nil then
        act.doer.components.talker:Say(GetDescription(act.doer, act.target, "FIXED"))
        act.target.components.oceantrawler:Fix()
	end
    return true
end

--★ GIVE_TACKLESKETCH.fn —— 给鱼饵图纸。
--   ★★ 5125 行 `KnowsItem(GetSpecificSketchPrefab())` ——
--     ★★★ 「图纸是否已知」检查。方法名是 GetSpecificSketchPrefab ——
--       「把这个图纸换成对应的鱼饵 prefab」。
--   ★ 5126 行的 `return false, "DUPLICATE"` ——
--     ★ 有明确 reason，玩家能理解「已经会做了」。
ACTIONS.GIVE_TACKLESKETCH.fn = function(act)
	if act.invobject and act.target and
		act.target.components.craftingstation ~= nil and
		not act.target:HasTag("burnt") and
		not (act.target.components.burnable and act.target.components.burnable:IsBurning()) then

		if act.target.components.craftingstation:KnowsItem(act.invobject:GetSpecificSketchPrefab()) then
			return false, "DUPLICATE"
		else
			act.invobject.components.tacklesketch:Teach(act.target)
			return true
		end
	end
	return false
end

--★ REMOVE_FROM_TROPHYSCALE.fn —— 从荣誉榜取下物品。
--   ★★ 5141-5148 行的 takeitemtestfn 回调：
--     ★★★ 「取之前先问一下能不能取」，且**透传 reason**。
--       ★ 5145 行 `return testresult, reason` —— 当 testresult 为假时透传原因。
--       ★ 这是本文件里少见的「回调透传失败原因」的写法。
ACTIONS.REMOVE_FROM_TROPHYSCALE.fn = function(act)
	if not act.target:HasTag("burnt") and
		not act.target:HasTag("fire") and
		act.target.components.trophyscale ~= nil and
		act.target:HasTag("trophycanbetaken") then

		if act.target.components.trophyscale.takeitemtestfn ~= nil then
			local testresult, reason = act.target.components.trophyscale.takeitemtestfn(act.target, act.doer)

			if not testresult then
				return testresult, reason
			else
				return act.target.components.trophyscale:TakeItem(act.doer)
			end
		else
			return act.target.components.trophyscale:TakeItem(act.doer)
		end
	end
end

--★ CYCLE.strfn —— TUNE / PAR 两变体（唱歌贝壳 / 高尔夫球座）。
ACTIONS.CYCLE.strfn = function(act)
    return (act.target ~= nil and
        (act.target:HasTag("singingshell") and "TUNE") or
        (act.target:HasTag("golf_tee") and "PAR")
    ) or nil
end

--★ CYCLE.fn —— 「循环」组件的通用实现（10 行）。
--   ★★ 5165 行的 cancycle 检查 —— 组件自己说「能不能循环」。
--   ★★ 5169 行的 `return false` 无 reason（不能循环）。
ACTIONS.CYCLE.fn = function(act)
	local tar = act.target
	if tar.components.cyclable ~= nil then
		if tar.components.cyclable.cancycle then
			tar.components.cyclable:Cycle(act.doer)
			return true
		else
			return false
		end
	end
end

--★★【OCEAN_TOSS.fn —— 「往海里扔」（22 行）】
--   ★★ 与 TOSS.fn（3934）几乎逐行对应，差别：
--     ① 5180 行检查 oceanthrowable（而非 complexprojectile）
--     ② 5183 行多一步 `AddProjectile()`
--     ③ 其余完全相同（包括 5187 行的 targetoffset 魔数）
--   ★★★ 两处重复的 {x=0,y=1.5,z=0} 魔数（3971/5187）——
--     ★ 说明「投掷物落点高度」这个常数被硬编码了两次。
--     ★ 记为 L 类隐患（魔数重复）。
ACTIONS.OCEAN_TOSS.fn = function(act)
    if act.invobject and act.doer then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        if act.invobject.components.oceanthrowable and act.doer.components.inventory then
            local projectile = act.doer.components.inventory:DropItem(act.invobject, false)
            if projectile then
                projectile.components.oceanthrowable:AddProjectile()
                local pos = nil
                if act.target then
                    pos = act.target:GetPosition()
                    projectile.components.complexprojectile.targetoffset = {x=0,y=1.5,z=0}
                else
                    pos = act:GetActionPoint()
                end
                projectile.components.complexprojectile:Launch(pos, act.doer)
                return true
            end
        end
    end
end

--★★【WINTERSFEAST_FEAST.fn —— 全文件最极端的空实现（4 行）】
--   ★★★ 完整代码：
--       function(act)
--           return true
--           -- Logic is handled from stategraph; action is never actually performed
--       end
--   ★★ 注意 return true **在注释之前**：
--     作者的意图是「return true 之后的代码不可达」，
--     于是把说明放在后面。语法上无问题（注释不影响语义），
--     但阅读时容易误以为注释在描述 return。
--   ★★★ 为什么可以做到「函数体只有 return true」？
--     因为「吃宴席」的表演（坐下、多人同时吃、撒彩带）
--     **必须**在状态图里实现 —— 涉及多方实体的同步表演。
--     ★ 这解释了 §0 的 T5 模板（状态图驱动）的极端形态。
ACTIONS.WINTERSFEAST_FEAST.fn = function(act)
	return true
	-- Logic is handled from stategraph; action is never actually performed
end

--★ BEGIN_QUEST.fn —— 接任务。
--   ★★ 5208-5212 行的 Can → Begin 两段式，且透传 message。
--     ★ 与 questowner 组件的接口设计一致。
ACTIONS.BEGIN_QUEST.fn = function(act)
    if not act.target.components.questowner then
        return false
    end

    local success, message = act.target.components.questowner:CanBeginQuest(act.doer)
    if success then
        success, message = act.target.components.questowner:BeginQuest(act.doer)
    end

    return success, message
end

--★ ABANDON_QUEST.fn —— 放弃任务。`(success ~= false)` 三态容忍（§p4 3091）。
ACTIONS.ABANDON_QUEST.fn = function(act)
    if act.target.components.questowner ~= nil and act.target.components.questowner:CanAbandonQuest(act.doer) then
        local success, message = act.target.components.questowner:AbandonQuest(act.doer)
        return (success ~= false), message
    end
end

--★★★【SING.fn —— 唱歌（21 行），含一个重要注释】
--   ★★ 5227 行的 `act.invobject.songdata` ——
--     ★ 歌曲数据挂在**物品实例**上，不是组件也不是全局表。
--       ★⇒ 「不同的歌笛唱不同的歌」通过实例字段实现。
--   ★★ 5230-5232 行的保留注释解释了一个防御性检查：
--     「we need this test incase the client asks to do this action due to lag.」
--     ★★★ 「因为客户端可能因延迟而请求这个动作」——
--       「客户端**又**请求了同一个动作」（5231 行 `return true`）。
--     ★★★ 这是**幂等性保护**：重复请求不重复执行。
--       ★★★ 联机架构的核心要求之一：**所有动作都必须能安全重放**。
--       ★ 参照 playercontroller.lua:4585 也有「防重复动作」检查，
--         属于同一类问题的两层防护。
--   ★★ 5234-5236 行：CanAddSong 通过才 Sing，但 5239 行无条件 return true。
--     ★ 「不能加歌」也是成功（静默失败模式）。
ACTIONS.SING.fn = function(act)
    local singinginspiration = act.doer.components.singinginspiration
    if act.invobject and singinginspiration ~= nil then

        local songdata = act.invobject.songdata
        if songdata ~= nil then

            if singinginspiration:IsSongActive(songdata, act.invobject) then --we need this test incase the client asks to do this action due to lag.
                return true
            end

            if singinginspiration:CanAddSong(songdata, act.invobject) then
                act.invobject.components.singable:Sing(act.doer)
            end
        end

        return true
    end

    return false
end

--★★ SING_FAIL.fn —— 一行 return true（影子动作，§2 532 行已详述）。
--   ★★ 5245-5251 共 7 行，其中 3 行是 fn（返回 true），
--     2 行是 stroverridefn，2 行空。
--     ★★ 全文最短的动作实现之一。
ACTIONS.SING_FAIL.fn = function(act)
    return true
end

ACTIONS.SING_FAIL.stroverridefn = function(act)
    return STRINGS.ACTIONS.SING
end

--★★★【REPLATE.fn —— 换盘子（68 行），全文件最复杂的事务逻辑】
--   ★★ 结构：
--     ① 5255-5257  四对象识别（replater / replatable 各两个来源）
--     ② 5258-5262  三道早期校验（MISMATCH / SAMEDISH）
--     ③ 5264-5271  盘子在地上：DropItem + Remove + Replate
--     ④ 5274-5292  盘子在**物品槽里**（新盘子）：销毁旧建新
--     ⑤ 5294-5311  食物盘子在**背包里**：销毁旧建新
--     ⑥ 5313-5316  盘子在地上（另一个分支）
--   ★★★ 核心难点：「换盘子」要保持**物品在玩家背包里的位置不变**
--     （否则 UI 上的格子会跳）。
--     ★ 解决办法（5280-5292）：记下 slot/perish/salted，
--       销毁原物，SpawnPrefab 出新物，恢复属性，放回**同一个 slot**。
--       ★★★ 「用重建代替修改」的技巧 —— 因为实体的组件无法热替换。
--   ★★ 5276 行的注释「spawn new entity so UI animates on clients」——
--     ★★★ 不只是「UI 不跳格子」，而是**需要客户端播放物品变化的动画**。
--       原地改组件的话客户端的物品图标不会刷新。
--       ★ 这个问题只有联机游戏才会遇到，注释点明了它。
--   ★★ ④⑤ 两段代码（5274-5292 与 5294-5311）**几乎逐行重复**，
--     只有 GetItemSlot 的来源不同（replater_owner vs inventory）。
--     ★ 与 PLANT.fn（2619 行）、CONSTRUCT.fn（4436 行）同属「未抽象的重复」。
ACTIONS.REPLATE.fn = function(act)
    if act.target ~= nil and act.invobject ~= nil then
--★★ REPLATE.fn 的四种场景在 5254-5321。
--   ★★ 核心难点：「换盘子」要保持**物品在玩家背包里的位置不变**。
--     ★ 解决办法（5280-5292）：记下 slot/perish/salted，
--       销毁原物，SpawnPrefab 出新物，恢复属性，放回**同一个 slot**。
--       ★★★ 「用重建代替修改」—— 因为实体的组件无法热替换。
--   ★★ 5276 行的注释「spawn new entity so UI animates on clients」
--     说明了重建的**真正目的**：客户端需要播放物品变化的动画。
        local replater = act.target.components.quagmire_replater or act.invobject.components.quagmire_replater
        local replatable = act.target.components.quagmire_replatable or act.invobject.components.quagmire_replatable
        if replater ~= nil and replatable ~= nil and replater ~= replatable then
            if replater.basedish ~= replatable.basedish then
                return false, "MISMATCH"
            elseif replater.dishtype == replatable.dishtype then
                return false, "SAMEDISH"
            end

            local dishtype = replater.dishtype
--★★ REPLATE.fn 的 owner 推导（5265-5268）：
--   ★★ `replatable.inst.components.inventoryitem:GetGrandOwner()`
--     ★★ 用 GetGrandOwner（递归）而非 owner ——
--       因为盘子可能在「背包里的箱子」里。
--   ★★ 5267 行的 `owner.components.inventory or owner.components.container`
--     ★★★ 又是「玩家 / AI」的兼容写法（§p4 1619 行同款）。
--   ★★ 5268 行的 replater_owner 为 nil ⇒ 「盘子在地上」（5269-5273 分支）。
            local owner = replatable.inst.components.inventoryitem:GetGrandOwner()
            if owner ~= nil then
                local inventory = owner.components.inventory or owner.components.container
                local replater_owner = replater.inst.components.inventoryitem.owner
                if replater_owner == nil then
                    --new plate on the ground
                    inventory:DropItem(replatable.inst, true, false, replater.inst:GetPosition())
                    replater.inst:Remove()
                    replatable:Replate(dishtype, nil, act.doer)
                elseif replatable.inst == act.invobject then
--★★ REPLATE 的场景②（盘子在物品槽）5274-5292 的十行重建：
--   ①5276-5277 注释：必须 Spawn 新实体让客户端播动画
--   ②5278      记住 replater 的槽位（不是 replatable 的！）
--   ③5280-5281 记住 perish（保质期）与 salted（是否腌过）
--   ④5282-5283 销毁两个旧实体
--   ⑤5284      SpawnPrefab 新实体
--   ⑥5285-5290 恢复 perish 与 salted
--   ⑦5291      Replate(dishtype, true, doer)
--   ⑧5292      放回**记住的槽位**
--   ★★★ 「记住状态 → 销毁 → 重建 → 恢复 → 放回原槽」是完整的
--     「实体不可热替换组件」的标准解法。
                    --new plate in inventory
                    --spawn new entity so UI animates on clients
                    local replater_container = replater_owner.components.inventory or replater_owner.components.container
                    local replater_slot = replater_container:GetItemSlot(replater.inst)
                    local prefab = replatable.inst.prefab
                    local perish = replatable.inst.components.perishable ~= nil and replatable.inst.components.perishable:GetPercent() or nil
                    local salted = replatable.inst:HasTag("quagmire_salted")
                    replatable.inst:Remove()
                    replater.inst:Remove()
                    local newitem = SpawnPrefab(prefab)
                    if perish ~= nil then
                        newitem.components.perishable:SetPercent(perish)
                    end
                    if salted then
                        newitem.components.quagmire_saltable:Salt(0, true)
                    end
                    newitem.components.quagmire_replatable:Replate(dishtype, true, act.doer)
                    replater_container:GiveItem(newitem, replater_slot, replater_owner:GetPosition())
                else
--★★ REPLATE 的场景③（食物盘子在背包）5294-5311 ——
--   ★★ 与场景②（5274-5292）**几乎逐行相同**，
--     唯一差别是 5296 行 `inventory:GetItemSlot(replatable.inst)`
--     而 5278 行取的是 replater 的槽位。
--   ★★★ 这是全文件里最明显的「未抽取重复」之一。
--     ★ 若重构，自然的抽取是：
--       local function RebuildInSlot(container, old, prefab, dishtype)
--       ★ 但两处的槽位语义不同（一个换 replater 一个换 replatable），
--         抽象时容易搞混 —— 这可能是作者没抽的原因。
                    --food plate in inventory
                    --spawn new entity so UI animates on clients
--★★ REPLATE.fn 场景③（5294-5311）的对称说明已在上方，
--   ★★ 5312-5321 是最后两个分支：
--     ①5312-5316 「盘子在地上」：最简（Remove + Replate 两行）
--     ②5317-5320 return true
--   ★★★ 四个场景的复杂度排序：
--     · 盘子在地上（5313-5316）    → 2 行
--     · 新盘子在地上（5269-5273）  → 5 行
--     · 盘子在物品槽（5274-5292）  → 19 行
--     · 食物盘子在背包（5294-5311）→ 18 行
--   ★★ 复杂度差异的**唯一原因**是「物品是否在某个容器里需要保持原位」。
--     ★★★ 这是「UI 一致性要求」如何驱动实现复杂度的绝佳样本。
--   ★★ 5313 行的 else 分支（owner 为 nil）用最简实现 ——
--     ★ 因为地上的东西不需要重建（没有 UI 要同步）。
--   ★★ 与 SALT.fn（5350）的 else 分支同理。
                    local slot = inventory:GetItemSlot(replatable.inst)
                    local prefab = replatable.inst.prefab
                    local perish = replatable.inst.components.perishable ~= nil and replatable.inst.components.perishable:GetPercent() or nil
                    local salted = replatable.inst:HasTag("quagmire_salted")
                    replatable.inst:Remove()
                    replater.inst:Remove()
                    local newitem = SpawnPrefab(prefab)
                    if perish ~= nil then
                        newitem.components.perishable:SetPercent(perish)
                    end
                    if salted then
                        newitem.components.quagmire_saltable:Salt(0, true)
                    end
                    newitem.components.quagmire_replatable:Replate(dishtype, true, act.doer)
                    inventory:GiveItem(newitem, slot, owner:GetPosition())
                end
            else
                --food plate on the ground
                replater.inst:Remove()
                replatable:Replate(dishtype)
            end
            return true
        end
    end
end

--★★★【SALT.fn —— 腌渍（34 行），与 REPLATE 同款「重建」技巧】
--   ★★ 5324-5328 行：消耗盐（处理堆叠）。
--   ★★ 5330-5348 行：重建盘子（与 REPLATE 的 ⑤ 同款）。
--   ★★ 5351 行的 else 分支：盘子在地上时直接 Salt(1)。
--     ★★★ 对比背包里需要「重建 + 还原属性」，
--       在地上只需要调 Salt —— 因为没有 UI 需要同步。
--     ★★ 同一个操作在两种场景下需要两种实现，
--       差异根源就是「实体能否热替换组件」。
ACTIONS.SALT.fn = function(act)
    if act.target ~= nil and act.target.components.quagmire_saltable ~= nil then
        if act.invobject.components.stackable ~= nil then
--★★ SALT.fn 与 REPLATE.fn 的「重建」技巧在 5324-5352。
--   ★★ 关键对照：
--     · 盘子在背包里 → 重建 + 还原属性 + 放回同槽位
--     · 盘子在地上   → 直接 Salt(1)（不需要重建）
--   ★★★ 差异根源：「实体能否热替换组件」——
--     有 UI 需要同步的地方才必须重建。
            act.invobject.components.stackable:Get():Remove()
        else
            act.invobject:Remove()
        end

--★★ SALT.fn 的「重建」在 5330-5348，与 REPLATE 场景③同款：
--   ①5332-5335 找容器与槽位
--   ②5336-5338 记住 prefab / perish / replated（★ 三个状态）
--   ③5339      销毁原物
--   ④5340      SpawnPrefab 新实体
--   ⑤5341-5346 恢复 perish 与 replated
--   ⑥5347      Salt(1, true)
--   ⑦5348      放回记住的槽位
--   ★★★ 与 REPLATE 相比多记了「replated」（盘子被替换过没有）。
--     ★ 因为 SALT 要同时保留「换过盘子」与「腌过」两个状态。
        local owner = act.target.components.inventoryitem:GetGrandOwner()
        if owner ~= nil then
            --food plate in inventory
            --spawn new entity so UI animates on clients
            local inventory = owner.components.inventory or owner.components.container
            local slot = inventory:GetItemSlot(act.target)
            local prefab = act.target.prefab
            local perish = act.target.components.perishable ~= nil and act.target.components.perishable:GetPercent() or nil
            local replated = act.target.components.quagmire_replatable ~= nil and act.target.components.quagmire_replatable.dishtype or nil
            act.target:Remove()
            local newitem = SpawnPrefab(prefab)
            if perish ~= nil then
                newitem.components.perishable:SetPercent(perish)
            end
            if replated ~= nil then
                newitem.components.quagmire_replatable:Replate(replated, true)
            end
            newitem.components.quagmire_saltable:Salt(1, true)
            inventory:GiveItem(newitem, slot, owner:GetPosition())
        else
--★ 5350-5352 行 —— 「盘子在地上」的简单路径。
--   ★★★ 只有一行 `quagmire_saltable:Salt(1)`。
--     ★ 与背包路径的 18 行形成极端对比 ——
--       「同一操作，地上 1 行、背包里 18 行」。
--       ★★ 差异全部来自「实体能否热替换组件」与「UI 需不需要同步」。
            --food plate on the ground
            act.target.components.quagmire_saltable:Salt(1)
        end
        return true
    end
end

--★★★【UNPATCH.fn —— 拆补丁（38 行），含一个「临时方案」注释】
--   ★★ 5362-5364 行：`lootdropper == nil then return true` ——
--     ★★★ **没有 lootdropper（战利品掉落器）就报告成功**。
--       ★ 这意味着「有些被补的洞根本不掉战利品」，此时拆补丁是免费动作。
--   ★★ 5368 行的保留注释「NOTES(DiogoW): Temporary boat patch.」——
--     ★★★ 明确标注为**临时方案**。
--     ★ 这条注释让后来者知道这段逻辑是权宜之计。
--   ★★ 5375 行的双 prefab 分派：
--       `build == "boat_repair_tape_build" and "sewing_tape" or "boatpatch"`
--     ★★★ 根据动画状态决定给什么。
--     ★ 5379-5388 行：补丁带 repairer 组件则**顺手修船**（DoDelta 负值）。
--       ★★★ 「拆补丁」这个动作被顺带赋予了「修 25 血」的副作用。
--       ★ 这是一个很「贪婪」的设计 —— 用小道具解决大问题。
--   ★★ 5390 行 FlingItem —— 战利品掉到地上。
ACTIONS.UNPATCH.fn = function(act)
    if act.target == nil or act.target.components.boatleak == nil then
        return false
--★★ UNPATCH.fn 的核心在 5362-5392。
--   ★★ 5362-5364：没有 lootdropper（不掉战利品）就报成功 ⇒ 免费拆。
--   ★★ 5368 行的「NOTES(DiogoW): Temporary boat patch.」
--     ★★★ 明确标注为**临时方案**。作者主动标记技术债。
--   ★★ 5379-5388：补丁带 repairer 组件则**顺手修船 25 血**。
--     ★ 用小道具解决大问题的「贪婪设计」。
    end

    if act.target.components.lootdropper == nil then
        return true
    end

--★★ UNPATCH.fn 的「临时方案」在 5368-5373：
--   ★★ 条件 `GetRemainingRepairedTime()` —— 「这个洞已经被修过一次」。
--     ★★ 于是直接转成 small_leak 并 return true，**不掉任何战利品**。
--       ★ 这是「二次修补只缩小规模、不给战利品」的规则。
--   ★★★ 5368 行的「NOTES(DiogoW): Temporary boat patch.」
--     明确标注了这是权宜之计 —— 后来者应知。
    local build = act.target.AnimState:GetBuild()

    -- NOTES(DiogoW): Temporary boat patch.
    if act.target.components.boatleak:GetRemainingRepairedTime() then
        act.target.components.boatleak:SetState("small_leak")

        return true
    end

    local prefab = build == "boat_repair_tape_build" and "sewing_tape" or "boatpatch"
--★★ 5376-5388 行 —— 「补丁顺手修船」：
--   ★★ 5375 行按动画状态选 prefab（boat_repair_tape_build → sewing_tape）。
--   ★★ 5379-5382 的双重条件：patch 非 nil 且有 repairer 且有 healthrepairvalue。
--   ★★ 5383-5388：取船（GetCurrentPlatform）→ 扣血。
--     ★★★ 「拆补丁」被顺带赋予「修 25 血」的副作用 ——
--       ★ 用小道具解决大问题，典型的「贪婪设计」。

    local patch = SpawnPrefab(prefab)

    if patch ~= nil and
        patch.components.repairer ~= nil and
        patch.components.repairer.healthrepairvalue ~= nil
    then
        local boat = act.target:GetCurrentPlatform()

        if boat.components.health ~= nil then
            boat.components.health:DoDelta(-patch.components.repairer.healthrepairvalue)
        end
    end

    act.target.components.lootdropper:FlingItem(patch)

    act.target.components.boatleak:SetState("small_leak")

    return true
end

--★★【POUR_WATER.fn —— 浇水（19 行），三层守卫】
--   ★★ 三层：
--     ① 5398  invobject 存在且有效
--     ② 5399  ITEMMIMIC 守卫（T3）
--     ③ 5403  容器还有水（finiteuses > 0）
--   ★★ 5404 行的失败原因是**条件表达式**：
--       `(HasTag("wateringcan") and "OUT_OF_WATER" or nil)`
--     ★★★ 洒水壶没水 ⇒ 「OUT_OF_WATER」（没水了）；
--       其它容器 ⇒ nil（静默）。
--       ★★ 差异化失败原因的精细设计。
--   ★★ 5407-5411 行的目标分流：
--     有 target → SpreadProtection(target)（对着作物）
--     无 target → SpreadProtectionAtPoint(act:GetActionPoint():Get())
--     ★★★ 与 §p7 4941 行的 CAST_NET 完全同型。
--   ★ 5410 行的 `:Get()` 把 Vector3 转成 Point。
ACTIONS.POUR_WATER.fn = function(act)
    if act.invobject ~= nil and act.invobject:IsValid() then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        if act.invobject.components.finiteuses ~= nil and act.invobject.components.finiteuses:GetUses() <= 0 then
			return false, (act.invobject:HasTag("wateringcan") and "OUT_OF_WATER" or nil)
        end

        if act.target ~= nil and act.target:IsValid() then
			act.invobject.components.wateryprotection:SpreadProtection(act.target)
        else
			act.invobject.components.wateryprotection:SpreadProtectionAtPoint(act:GetActionPoint():Get())
        end

        return true
    end
end

--★ POUR_WATER.strfn —— EXTINGUISH 变体（对火浇水）。
--   ★★ 5418 行 `(HasTag("fire") or HasTag("smolder")) and "EXTINGUISH" or nil`。
--     ★★★ 与 §p7 4762 行的 TAPTREE.strfn 是同一个三元惯用法。
ACTIONS.POUR_WATER.strfn = function(act)
    return (act.target:HasTag("fire") or act.target:HasTag("smolder")) and "EXTINGUISH" or nil
end

--★ POUR_WATER_GROUNDTILE.fn = POUR_WATER.fn —— T12 同构模板。
ACTIONS.POUR_WATER_GROUNDTILE.fn = ACTIONS.POUR_WATER.fn
--★ POUR_WATER_GROUNDTILE.stroverridefn —— 固定 GENERIC 词。
ACTIONS.POUR_WATER_GROUNDTILE.stroverridefn = function(act)
    return STRINGS.ACTIONS.POUR_WATER.GENERIC
end

--★★ PLANTREGISTRY_RESEARCH_FAIL.fn —— 影子动作（§2 573 行）。
--   ★★ 5433 行的「肥料不能研究」特殊原因 ——
--     ★ 与 PLANTREGISTRY_RESEARCH.fn（5441）的 fertilizerresearchable
--       分支对应：研究动作支持肥料，失败动作必须解释「这个不行」。
ACTIONS.PLANTREGISTRY_RESEARCH_FAIL.fn = function(act)
    local targ = act.target or act.invobject
    if targ then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        if targ:HasTag("fertilizerresearchable") then
            return false, "FERTILIZER"
        end
    end

    return false
end

--★★★【PLANTREGISTRY_RESEARCH.fn —— 研究植物/肥料（30 行）】
--   ★★ 三分支：
--     ① plantresearchable + IsRandomSeed → 说话「这是随机种子」（5452）
--     ② plantresearchable               → LearnPlant + 说话
--     ③ fertilizerresearchable         → LearnFertilizer + 说话
--   ★★ 5452/5458/5465 三处都有 `targ.components.inspectable.noanim` ——
--     ★★★ **隐式依赖 inspectable 组件**：若目标只有 plantresearchable
--       而没有 inspectable ⇒ `nil.noanim` 崩溃。
--     ★ 实际上「可研究」的东西（种子、肥料）都有 inspectable（可被查看），
--       所以实践中不崩。但这仍是**未声明的组件依赖**。
--       ★ 记录为 L 类隐患（与 4882 行同类）。
--   ★★ 5461-5467 行的括号错位（5467 行的 end 缩进不对）：
--     if/elseif 嵌套 + 尾部 return true。缩进混乱但结构正确。
--   ★★ 5468 行的 return true 在 targ ~= nil 时无条件返回 ——
--     「研究完成」与「研究失败」都成功（静默失败模式）。
ACTIONS.PLANTREGISTRY_RESEARCH.fn = function(act)
    local targ = act.target or act.invobject

    if targ ~= nil then
--★★ PLANTREGISTRY_RESEARCH.fn 的三分支在 5444-5468。
--   ★★ 5452/5458/5465 三处都有 `targ.components.inspectable.noanim` ——
--     ★★★ **隐式依赖 inspectable 组件**（未声明的组件依赖）。
--     ★ 实践中不崩（「可研究」的东西都有 inspectable）。
--   ★★ 5468 行的 return true 无条件（研究失败也是成功）。
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

--★★ PLANTREGISTRY_RESEARCH.fn 的三分支（5444-5468）：
--   ①5449-5459  plantresearchable
--     · 5450-5453 IsRandomSeed → 说话「这是随机种子」（不学）
--     · 5455-5459 否则 LearnPlant + 说话
--   ②5461-5467  fertilizerresearchable → LearnFertilizer + 说话
--   ③5468      无条件 return true（失败也算成功）
--   ★★★ 三处的说话都传了 `inspectable.noanim` ——
--     ★ 隐式依赖 inspectable 组件（未声明的依赖，见 5452 处注释）。
        if targ.components.plantresearchable then
            if targ.components.plantresearchable:IsRandomSeed() then
                if act.doer.components.talker then
                    act.doer.components.talker:Say(GetString(act.doer, "ANNOUNCE_PLANT_RANDOMSEED"), nil, targ.components.inspectable.noanim)
                end
            else
                targ.components.plantresearchable:LearnPlant(act.doer)

                if act.doer.components.talker then
                    act.doer.components.talker:Say(GetString(act.doer, "ANNOUNCE_PLANT_RESEARCHED"), nil, targ.components.inspectable.noanim)
                end
            end
        elseif targ.components.fertilizerresearchable then
--★ 5462-5466 行 —— 肥料研究分支。四行，无随机种子概念。
            targ.components.fertilizerresearchable:LearnFertilizer(act.doer)

            if act.doer.components.talker then
                act.doer.components.talker:Say(GetString(act.doer, "ANNOUNCE_FERTILIZER_RESEARCHED"), nil, targ.components.inspectable.noanim)
        end
        end
        return true
    end
end

--★ ASSESSPLANTHAPPINESS.stroverridefn —— 「评估{植物}」的完整句子。
ACTIONS.ASSESSPLANTHAPPINESS.stroverridefn = function(act)
    local targ = act.target or act.invobject
    if targ then
        local plant = targ:GetDisplayName()
        return plant ~= nil and subfmt(STRINGS.ACTIONS.ASSESSPLANTHAPPINESS.GENERIC_FMT, { plant = plant }) or nil
    end
end

--★ ASSESSPLANTHAPPINESS.fn —— 评估作物心情（20 行）。
--   ★★ 5489-5493 行的三分支文案选择：
--     有 farmplantstress → 用它的描述
--     否则              → 用通用描述 DESCRIBE_PLANTHAPPY
--   ★★ 5497 行的 return true 无条件（无 stress 组件也成功）。
ACTIONS.ASSESSPLANTHAPPINESS.fn = function(act)
    local targ = act.target or act.invobject

    if targ ~= nil then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        local desc
        if targ.components.farmplantstress then
            desc = targ.components.farmplantstress:GetStressDescription(act.doer)
        else
            desc = GetString(act.doer, "DESCRIBE_PLANTHAPPY")
        end
        if desc and act.doer.components.talker then
            act.doer.components.talker:Say(desc, nil, targ.components.inspectable.noanim)
        end
        return true
    end
end

--★ `local WEIGHTED_SEED_TABLE = require("prefabs/weed_defs").weighted_seed_table`
--   ★★ 又一处**延迟加载**，但这次是模块级的（文件加载时执行）。
--     ★★ 与 4255 行的区别：
--       · 4255 行在函数体内 require（真正延迟，只在画的时候加载）
--       · 5501 行在文件顶层 require（只要加载 actions.lua 就执行）
--     ★ 所以 5501 并**不节省加载时间**，只是保持代码局部性。
--   ★★★ 它写在 PLANTWEED.fn 之前（5502 行）而不是文件头部，
--     保持了「谁用到谁 require」的风格。
local WEIGHTED_SEED_TABLE = require("prefabs/weed_defs").weighted_seed_table
--★★ PLANTWEED.fn —— 种草（18 行）。
--   ★★ 5507 行 `weighted_random_choice(WEIGHTED_SEED_TABLE)` ——
--     ★★★ 「按权重随机选一种草」。
--       ★ 权重表来自 prefab 定义，所以「长哪种草」由内容决定而非代码。
--   ★★ 5511 行的音效在 new_weed.SoundEmitter 上 ——
--     ★★★★ `if new_weed.SoundEmitter ~= nil` 是必要的 nil 保护！
--       因为 SpawnPrefab 出来的实体**不一定**有 SoundEmitter
--       （取决于 prefab 的定义）。
--       ★★ 与 4805 行 BATHBOMB 形成鲜明对比：
--         这里的作者记得保护，4805 行却没保护。
--       ★ 说明作者知道这个陷阱，但并非处处一致。
--   ★★ 5516 行 `targ:Remove()` —— 「种草」会消耗原土（农场优化）。
--   ★★ 5514 行的 on_planted 事件带 in_soil=true ——
--     ★ 区分「种在土里」与「种在地上」。
ACTIONS.PLANTWEED.fn = function(act)
    local targ = act.target or act.invobject

    if targ and targ:HasTag("soil") then
        local x, y, z = targ.Transform:GetWorldPosition()
        local new_weed = SpawnPrefab(weighted_random_choice(WEIGHTED_SEED_TABLE))
        new_weed.Transform:SetPosition(x, y, z)

        if new_weed.SoundEmitter ~= nil then
            new_weed.SoundEmitter:PlaySound("dontstarve/common/plant")
        end

        new_weed:PushEvent("on_planted", {in_soil = true, doer = act.doer})

        targ:Remove()
        return true
    end
end

--★ ADDCOMPOSTABLE.fn —— 加堆肥。两行。
ACTIONS.ADDCOMPOSTABLE.fn = function(act)
    if act.target ~= nil and act.target.components.compostingbin ~= nil then
        return act.target.components.compostingbin:AddCompostable(act.invobject)
    end
end


--★ WAX.fn —— 涂蜡。ITEMMIMIC 守卫 + waxable 组件。
--   ★★ 5530 行的守卫在 waxable 检查**之后** ——
--     ★ 与 4516 行 CASTAOE 相反（那边在 CanCast 之后）。
--     ★★★ 两种顺序都无错误，属风格差异。
ACTIONS.WAX.fn = function(act)
    if act.target.components.waxable then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
        return act.target.components.waxable:Wax(act.doer, act.invobject)
    end
end

--★ UNLOAD_WINCH.fn —— 绞盘卸货。用 prefab 上的 unloadfn 字段。
--   ★★ 5538 行的双 nil 检查：组件存在 + unloadfn 字段存在。
--     ★★★ 「组件在但没配 unloadfn」是可能的（通用组件 + 特殊配置）。
--     ★ 与 TRAVEL（3699）的单字段检查不同，这里更严谨。
ACTIONS.UNLOAD_WINCH.fn = function(act)
    if act.target.components.winch ~= nil and act.target.components.winch.unloadfn ~= nil then
        return act.target.components.winch.unloadfn(act.target)
    end
end

--★ USE_HEAVY_OBSTACLE.strfn —— 用 prefab 上的 use_heavy_obstacle_string_key。
ACTIONS.USE_HEAVY_OBSTACLE.strfn = function(act)
	return act.target.use_heavy_obstacle_string_key
end

--★★ USE_HEAVY_OBSTACLE.fn —— 使用重型障碍物（13 行）。
--   ★★ 5548 行用 **replica** 读 BODY 槽的装备 ——
--     ★★★ fn 在服务端跑，却用 replica 读装备。
--       ★ 对比 4641 行（COMPARE_WEIGHABLE 的同一操作）用的是 components。
--       ★★ **同一语义的操作，一处用 components 一处用 replica**。
--       ★ 两者在服务端结果相同（replica 是 components 的镜像），
--         但表达上不一致，且 replica 可能滞后。
--       ★ 记录为 L 类不一致。
--   ★★ 5550-5554 行的三条件合并为一个 return false，无 reason。
--   ★★ 5551 行的 use_heavy_obstacle_action_filter ——
--     ★ 三参回调（target, doer, heavy_item），允许 prefab 做精细过滤。
ACTIONS.USE_HEAVY_OBSTACLE.fn = function(act)
    local heavy_item = act.doer.replica.inventory:GetEquippedItem(EQUIPSLOTS.BODY)

    if heavy_item == nil or not act.target:HasTag("can_use_heavy")
        or (act.target.use_heavy_obstacle_action_filter ~= nil and not act.target.use_heavy_obstacle_action_filter(act.target, act.doer, heavy_item)) then

        return false
    end

    if heavy_item ~= nil and act.target ~= nil and act.target.components.heavyobstacleusetarget ~= nil then
        return act.target.components.heavyobstacleusetarget:UseHeavyObstacle(act.doer, heavy_item)
    end
end

--★★ YOTB_SEW.fn —— 缝纫机。四个失败/成功出口。
--   ★★ 5563-5566 行的「已在缝」→ return true（静默）。
--   ★★ 5569 行 `container:IsOpen() and not IsOpenedBy(doer)` → INUSE。
--     ★★★ 精确条件：「开着但不是我开的」才是 INUSE。
--       「我开的」不算冲突。这比 2484 行的 `not CanOpen()` 判定更精细。
--   ★★ 5569 行的条件顺序：先 IsOpen 再 not IsOpenedBy（短路）。
ACTIONS.YOTB_SEW.fn = function(act)
    if act.target:HasTag("sewingmachine") then
        if act.target.components.yotb_sewer:IsSewing() then
            --Already sewing
            return true
        end

        local container = act.target.components.container
        if container ~= nil and container:IsOpen() and not container:IsOpenedBy(act.doer) then
            return false, "INUSE"
        elseif not act.target.components.yotb_sewer:CanSew() then
            return false
        end

        act.target.components.yotb_sewer:StartSewing(act.doer)
        return true
    end
end

--★★ YOTB_STARTCONTEST.fn —— 比赛（19 行）的三种「不能开始」。
--   ★★ 三种失败原因都很具体：
--     DOESNTWORK（组件不存在）
--     ALREADYACTIVE（已有比赛）
--     RIGHTTHERE（就是你）/ NORESPONSE（别人）
--   ★★★★ RIGHTTHERE 与 NORESPONSE 的区分很有意思：
--     「主持人有反应」时，看主持人**是不是被点的那个**。
--     是 → 「你自己去点那个主持人」；不是 → 「找那个人去」。
--     ★★★ 这是「把 NPC 的对话反应写进失败原因」的优秀 UX。
ACTIONS.YOTB_STARTCONTEST.fn = function(act)
    local yotb_stagemanager = TheWorld.components.yotb_stagemanager
    if not yotb_stagemanager then
        return false, "DOESNTWORK"
    elseif yotb_stagemanager:IsContestActive() then
        return false, "ALREADYACTIVE"
    else
        local host_visible = yotb_stagemanager:GetHostVisible()
        if host_visible then
            if host_visible == act.target then
                return false, "RIGHTTHERE"
            else
                return false, "NORESPONSE"
            end
        end
    end

    act.target.components.yotb_stager:StartContest(act.doer)
    return true
end

--★ YOTB_UNLOCKSKIN.fn —— 解锁皮肤。
--   ★★ 5607 行的 makedoll 回调 —— 「做成玩偶」（另一个用途）。
--   ★★ 5612 行的 `return false, "ALREADYKNOWN"` ——
--     ★★★★ 注意：**已经消耗了物品**（5612 行 Remove 之后）才返回失败！
--       ★★★ 玩家重复解锁已知皮肤会白白损失一个解锁道具！
--       ★ 对比 5617 行的成功路径（先解锁再 Remove）。
--       ★★ 严格来说这是个**真实的物品损失缺陷**。
--       ★ 推理依据：`act.invobject:Remove()` 在 5612 行无条件执行，
--         然后才 return false。玩家「误操作」会永久损失道具。
--       ★ 记为 L16（中等严重：玩家可见的物品损失）。只记录不修改。
ACTIONS.YOTB_UNLOCKSKIN.fn = function(act)
    if act.invobject and act.invobject.components.yotb_skinunlocker and
       act.doer and act.doer.YOTB_unlockskinset ~= nil and act.doer.YOTB_issetunlocked ~= nil then

        local skin = act.invobject.components.yotb_skinunlocker:GetSkin()

        if act.invobject.makedoll then
            act.invobject:makedoll(act.invobject,act.doer)
        end

        if act.doer:YOTB_issetunlocked(skin) then
            act.invobject:Remove()
            return false, "ALREADYKNOWN"
        else
            act.doer:YOTB_unlockskinset(skin)
            act.invobject:Remove()
            return true
        end
    end
end

--★ MUTATE_SPIDER.fn —— 变异蜘蛛。直接访问组件（无 nil 检查）。
--   ★★ 5623 行 `act.invobject.components.spidermutator:CanMutate(...)` ——
--     ★ 与 4283 行 STARTCHANNELING 同型：依赖上游保证组件存在。
ACTIONS.MUTATE_SPIDER.fn = function(act)
    if act.invobject.components.spidermutator:CanMutate(act.target) then
        act.invobject.components.spidermutator:Mutate(act.target, false, act.doer)
        return true
    else
        return false, "SAMETYPE"
    end
end

--★ HERD_FOLLOWERS.fn —— T2 模板（Can → 执行）。
--   ★★ 5631 行 `function (act)` —— 注意 function 与括号之间有空格，
--     ★ 与全文其它 `function(act)` 不一致。风格不一致。
ACTIONS.HERD_FOLLOWERS.fn = function (act)
    local can_herd, reason = act.invobject.components.followerherder:CanHerd(act.doer)
    if not can_herd then
        return false, reason
    end

    act.invobject.components.followerherder:Herd(act.doer)
    return true
end

--★ BEDAZZLE.fn —— 眩光。T2 模板。
ACTIONS.BEDAZZLE.fn = function (act)
    local can_bedazzle, reason = act.invobject.components.bedazzler:CanBedazzle(act.target)
    if not can_bedazzle then
        return false, reason
    end

    act.invobject.components.bedazzler:Bedazzle(act.target)
    return true
end

--★ REPEL.fn —— 驱赶。ITEMMIMIC 守卫**没有**，直接调组件。
--   ★★ 5652 行 `act.invobject.components.repellent` 无 nil 检查。
ACTIONS.REPEL.fn = function(act)
    if act.invobject.components.repellent then
        act.invobject.components.repellent:Repel(act.doer)
        return true
    end

    return false
end

--★ ADVANCE_TREE_GROWTH.fn —— 催长树。行内分号 `;` 分隔语句。
--   ★★ 5661 行的 `act.invobject.components.treegrowthsolution` 无 nil 检查。
--     ★ 又一处依赖上游。
ACTIONS.ADVANCE_TREE_GROWTH.fn = function(act)
    if act.target ~= nil and act.invobject.components.treegrowthsolution then
        return act.invobject.components.treegrowthsolution:GrowTarget(act.target)
    end

    return false
end

--★ DISMANTLE_POCKETWATCH.fn —— 拆怀表。
--   ★★ 5674 行 `return can_dismantle, reason` ——
--     ★★★★ **即使失败也返回 reason**（而不只失败时返回）。
--       这是一个「总是透传 reason」的写法，比常见的
--       「失败才 return false, reason」更简洁。
--       ★ 但注意：如果 can_dismantle 为 true，reason 也会被返回，
--         而成功的返回值应该只有 true。
--       ★★★ 多余的第二个返回值通常无害（调用方只在失败时用 reason），
--         但严格来说是不规范的。
--   ★★ 这是本文件里唯一「无条件返回 reason」的写法。
ACTIONS.DISMANTLE_POCKETWATCH.fn = function(act)
    local can_dismantle, reason = act.invobject.components.pocketwatch_dismantler:CanDismantle(act.target, act.doer)
    if can_dismantle then
        act.invobject.components.pocketwatch_dismantler:Dismantle(act.target, act.doer)
    end

    return can_dismantle, reason
end



--★★ STOP_LIFT_DUMBBELL.fn —— **两行且无返回值**。
--   ★★ 与 2747 行 HITCH.fn 相同的问题：隐式返回 nil ⇒ 报告失败。
--     ★ 但这个动作是纯「推事件」（5680 行 PushEvent）。
--     ★★ 后果：玩家举着哑铃停下时，状态机会走 Fail 路径。
--       ★ 若 Fail 路径会导致「动画回退」则可见；若有 onfail 回调则触发。
--     ★ 与 HITCH 的区别是 HITCH 至少执行了实质副作用（SetHitched），
--       而这个只有事件 —— 事件的监听者仍会执行。
--     ★★ 归类为 L17（语义瑕疵，与 L6 同型但后果更轻）。
ACTIONS.STOP_LIFT_DUMBBELL.fn = function(act)
    act.doer:PushEvent("stopliftingdumbbell")
end

--★ LIFT_DUMBBELL.fn —— 举哑铃。标准守卫 + CanLift + StartLifting。
--   ★★ 5686 行的 ITEMMIMIC 守卫在「dummybell 存在」之后。
ACTIONS.LIFT_DUMBBELL.fn = function(act)
    local dumbbell = act.invobject
    if act.doer ~= nil and dumbbell ~= nil then
        if ShouldItemMimicBeRevealedFor(dumbbell, act.doer) then
            return false, "ITEMMIMIC"
        end

        local lifter = act.doer.components.dumbbelllifter
        if lifter ~= nil then
            local can_lift, reason = lifter:CanLift(dumbbell)
            if not can_lift then
                return false, reason
            end

            lifter:StartLifting(dumbbell)
            return true
        end
    end

    return false
end

--★ ENTER_GYM.fn —— 进健身房。
--   ★★ 5713 行的 `return false, reason` 在 `if can_workout` 的 else 分支 ——
--     ★ 正确写法（失败时才透传 reason）。对比 5674 行。
ACTIONS.ENTER_GYM.fn = function(act)
    if act.doer ~= nil and act.target ~= nil and act.target.components.mightygym then
        local gym = act.target.components.mightygym
        local can_workout, reason = gym:CanWorkout(act.doer)
        if can_workout then
            gym:CharacterEnterGym(act.doer)
            return true
		end
        return false, reason
    end
    return false
end

--★★★【LIFT_GYM_FAIL.pre_action_cb —— 「立即反馈」的第二个实例】
--   ★★ 5720 行的 `bell:ding("fail")` —— 敲钟。
--   ★★ 5723-5725 行：`if not TheNet:IsDedicated() then PushEvent(...)`。
--     ★★★★ **专门排除了专用服务器**。
--       ★★★ 为什么？PushEvent("lift_gym", {result="fail"}) 大概会
--         在服务器上生成一个表现实体或播放音效 ——
--         专用服务器没有客户端，会浪费资源或报错。
--       ★ 这是「专用服务器优化」的显式写法，值得学习。
--       ★★ 对比 5732/5742 行的两个 pre_action_cb：
--         它们**只** ding 钟，没有 PushEvent —— 说明只有失败需要推送。
ACTIONS.LIFT_GYM_FAIL.pre_action_cb = function(act)
    if act.doer and act.doer.bell  then
        act.doer.bell:ding("fail")
    end

    if not TheNet:IsDedicated() then
        act.doer:PushEvent("lift_gym",{result = "fail"})
    end
end

--★★ LIFT_GYM_FAIL.fn —— 一行 return true。
--   ★★ 「失败的影子动作」也是 return true —— 因为失败反馈已在
--     pre_action_cb 里给完了（敲钟 + 推送事件）。
--     ★★ 这是 T6 影子动作的完整设计闭环：
--       pre_action_cb（立即反馈）→ fn（无操作，返回成功）→
--       状态图的 fail 状态（表现）。
ACTIONS.LIFT_GYM_FAIL.fn = function(act)
    return true
end

--★ LIFT_GYM_SUCCEED_PERFECT.pre_action_cb —— 敲「perfect」钟。
ACTIONS.LIFT_GYM_SUCCEED_PERFECT.pre_action_cb = function(act)
    if act.doer and act.doer.bell  then
        act.doer.bell:ding("perfect")
    end
end

ACTIONS.LIFT_GYM_SUCCEED_PERFECT.fn = function(act)
    return true
end

--★ LIFT_GYM_SUCCEED.pre_action_cb —— 敲「succeed」钟。
--   ★★ 三个 pre_action_cb 的结构完全相同，只差 ding 的字符串。
ACTIONS.LIFT_GYM_SUCCEED.pre_action_cb = function(act)
    if act.doer and act.doer.bell  then
        act.doer.bell:ding("succeed")
    end
end

ACTIONS.LIFT_GYM_SUCCEED.fn = function(act)
    return true
end

--★★ LEAVE_GYM.fn —— 5653 行直接访问 `doer.components.strongman.gym`。
--   ★★★★ **无 nil 检查链**：`doer.components.strongman.gym` 若 strongman
--     或 gym 为 nil ⇒ 立即崩溃。
--     ★ 与本文件其它 fn 的写法完全不同（几乎都有 nil 保护）。
--     ★★★ 推理依据：能执行 LEAVE_GYM 必然先进过健身房，
--       所以 strongman 与 gym 必然存在。这是「状态机不变量」的依赖。
--     ★ 与 4283 行 STARTCHANNELING 同型：**用「动作前提」代替 nil 检查**。
--     ★ 若将来有别的路径设置 gym，这行会崩。
--     ★ 归类为 L 类隐患（可接受但脆弱）。
ACTIONS.LEAVE_GYM.fn = function(act)
    local gym = act.doer.components.strongman.gym
	if gym ~= nil then
		gym.components.mightygym:CharacterExitGym(act.doer)
		return true
	end
end

--★ UNLOAD_GYM.fn —— 卸载杠铃。target 检查后直接调组件（无 nil 检查）。
ACTIONS.UNLOAD_GYM.fn = function(act)
    if act.target then
        act.target.components.mightygym:UnloadWeight()
        return true
    end
end

--★★ APPLYMODULE.pre_action_cb —— 「清手柄状态」的第 2 个实例。
--   ★★ 5769 行 `doer._controller_start_moduleremover = nil` ——
--     ★★★ 与 USEITEMON.pre_action_cb（3332 行）做的事完全相同！
--       「清掉『正在用卸模块器』这个手柄状态」。
--     ★★ 两处都在「要开始用别的模块相关操作」时清除它。
--       ★ 这说明「手柄状态」是**跨动作共享的瞬时标志**。
--       ★ 类似客户端状态的还有 _controller_start_moduleremover（3342 置位）、
--         controller_removing_module（6695 推事件）等。
--   ★ 5768 行的三重 and：doer + HUD + ControllerAttached。
ACTIONS.APPLYMODULE.pre_action_cb = function(act)
	if act.doer and act.doer.HUD and TheInput:ControllerAttached() then
		act.doer._controller_start_moduleremover = nil
	end
end

--★ APPLYMODULE.fn —— 装模块（17 行）。标准守卫 + CanUpgrade + PushModule。
--   ★★ 5780 行 `RemoveFromOwner()` 无参数 —— 整堆取出？
--     ★ 不对，RemoveFromOwner() 无参 ⇒ wholestack 为 nil ⇒ 视为 falsy ⇒
--       只取一个（见 inventory.lua:1397 `not wholestack and ...IsStack()`）。
--       ★★ 容易误读为「整堆」。这里实际是「一个」。
--   ★★ 5781 行 GetType() 取模块类型字符串（泛型伤害/护甲/…）。
ACTIONS.APPLYMODULE.fn = function(act)
    if (act.invobject ~= nil and act.invobject.components.upgrademodule ~= nil)
            and (act.doer ~= nil and act.doer.components.upgrademoduleowner ~= nil) then

        local can_upgrade, reason = act.doer.components.upgrademoduleowner:CanUpgrade(act.invobject)

        if can_upgrade then
            local individual_module = act.invobject.components.inventoryitem:RemoveFromOwner()
            local module_type = individual_module.components.upgrademodule:GetType()
            act.doer.components.upgrademoduleowner:PushModule(module_type, individual_module)
            return true
        else
            return false, reason
        end
    end

    return false
end

--★ APPLYMODULE_FAIL.fn —— 「槽位不足」的反馈 + return true。
--   ★★ 5793-5795 行 Say(NOTOUGHSLOTS) 后 return true ——
--     ★ 与 5728 行同型：失败反馈在 fn 里给，动作本身报成功。
--     ★★ 但注意它**没有** pre_action_cb（对比 LIFT_GYM_FAIL 有）。
--       ★ 因为 Say 是在服务端执行的，客户端也能收到 talker 事件，
--         所以不需要 pre_action_cb。
--       ★→ 区别在于：ding 钟是纯客户端行为（pre_action_cb），
--         Say 是服务端广播。两种反馈机制对应两种钩子。
ACTIONS.APPLYMODULE_FAIL.fn = function(act)
	if act.doer.components.talker ~= nil then
		act.doer.components.talker:Say(GetActionFailString(act.doer, "APPLYMODULE", "NOTENOUGHSLOTS"))
	end
    return true
end

--★ APPLYMODULE_FAIL.stroverridefn —— 固定串（避免显示「安装失败」）。
--   ★★ 与 SING_FAIL.stroverridefn（5249）、REMOVEMODULES_FAIL（5829）同款。
--     ★★★ **所有 _FAIL 影子动作都有 stroverridefn 返回成功动作的串**。
--       ★ 理由：玩家看到的应该是「安装模块」而不是「安装失败」——
--         「失败」信息由 Say 传达（5794 行）。
--       ★ 这是「动词与结果分离」的完整实现。
ACTIONS.APPLYMODULE_FAIL.stroverridefn = function(act)
    return STRINGS.ACTIONS.APPLYMODULE
end

--★ REMOVEMODULES.fn —— 卸模块。四层结构。
--   ★★ 5809 行的 `if energy_cost ~= 0 then` ——
--     ★★★ 「如果耗能不为 0 才扣」。
--       ★ 为什么不直接 DoDeltaCharge(-0)？因为 0 值可能被当作「无限制」。
--       ★ 谨慎的写法。
ACTIONS.REMOVEMODULES.fn = function(act)
    if (act.invobject ~= nil and act.invobject.components.upgrademoduleremover ~= nil)
            and (act.doer ~= nil and act.doer.components.upgrademoduleowner ~= nil) then
        if act.doer.components.upgrademoduleowner:NumModules() > 0 then

            local energy_cost = act.doer.components.upgrademoduleowner:PopOneModule()
            if energy_cost ~= 0 then
                act.doer.components.upgrademoduleowner:DoDeltaCharge(-energy_cost)
            end

            return true
        else
            return false, "NO_MODULES"
        end
    end

    return false
end

--★ REMOVEMODULES_FAIL.fn —— 与 APPLYMODULE_FAIL 严格对称。
ACTIONS.REMOVEMODULES_FAIL.fn = function(act)
	if act.doer.components.talker ~= nil then
		act.doer.components.talker:Say(GetActionFailString(act.doer, "REMOVEMODULES", "NO_MODULES"))
	end
    return true
end

ACTIONS.REMOVEMODULES_FAIL.stroverridefn = function(act)
    return STRINGS.ACTIONS.REMOVEMODULES
end

--★ CHARGE_FROM.strfn —— ITEM / SELF 双变体。
--   ★★ 5834-5836 行的三元链：
--       invobject 是电池用户 → "ITEM"
--       否则 doer 是电池用户   → "SELF"
--       否则                   → nil
--     ★★★ 「给自己充电」与「给装备充电」用同一动作。
ACTIONS.CHARGE_FROM.strfn = function(act)
    return act.invobject and act.invobject:HasTag("batteryuser") and "ITEM"
        or act.doer and act.doer:HasTag("batteryuser") and "SELF"
        or nil
end

--★ CHARGE_FROM.fn —— 充电的「谁是电池用户」判定（17 行）。
--   ★★ 5844-5849 行同样是三级回退：invobject 有 batteryuser → 用它；
--     否则 doer 有 → 用自己；否则 return false。
--     ★ 与 6165 行 WEIGH_ITEM 的「双向识别」同族。
--   ★★ 5840 行的 target 必须有 battery 组件（电池组）。
ACTIONS.CHARGE_FROM.fn = function(act)
    if not act.target or act.target.components.battery == nil then
        return false
    end

    local user
    if act.invobject and act.invobject.components.batteryuser then
        user = act.invobject
    elseif act.doer and act.doer.components.batteryuser then
        user = act.doer
    end
    if not user then
        return false
    end

    return user.components.batteryuser:ChargeFrom(act.target)
end

--★ ROTATE_FENCE.fn —— 旋转栅栏。ITEMMIMIC 守卫 + fencerotator 组件。
--   ★★ 5865 行用 TUNING.FENCE_DEFAULT_ROTATION 作参数 ——
--     ★ 固定 45 度或 90 度。旋转不连续。
--   ★★ 5870 行的 `return false` 无 reason。
ACTIONS.ROTATE_FENCE.fn = function(act)
    if act.invobject ~= nil then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

        local fencerotator = act.invobject.components.fencerotator
        if fencerotator then
            fencerotator:Rotate(act.target, TUNING.FENCE_DEFAULT_ROTATION)
            return true
        end
    end

    return false
end

--★ USEMAGICTOOL.fn —— 麦克斯韦用魔杖。四行。
ACTIONS.USEMAGICTOOL.fn = function(act)
	if act.doer.components.magician ~= nil then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
		return act.doer.components.magician:StartUsingTool(act.invobject)
	end
	return false
end

--★ STOPUSINGMAGICTOOL.fn —— 停止用魔杖。无条件 return true。
ACTIONS.STOPUSINGMAGICTOOL.fn = function(act)
	if act.doer.components.magician ~= nil then
		act.doer.components.magician:StopUsing()
	end
	return true
end

--★★ USESPELLBOOK.strfn —— 「角色专属的四个打开方式」。
--   ★★ 5891-5895 行的标签链：
--     pyromaniac    → PYROKINESIS（操纵火）
--     handyperson   → REMOTE（远程）
--     dogrider      → WOBY（指挥狗）
--     abigail_flower→ GHOSTTALK（与幽灵对话）
--   ★★★ 三个**角色**标签 + 一个**物品**标签，混在一个 or 链里。
--     ★ 角色决定「用哪种能力」，物品决定「用哪种道具」。
--     ★ 四者互斥（不可能同时满足），所以 or 链顺序无关。
--   ★ 5960 行的 CLOSESPELLBOOK.strfn 只有三项（少了 dogrider）——
--     ★★★ 打开时有 WOBY，关闭时没有。
--       这是一个可观察的**不一致**（打开显示「指挥狗」，关闭不显示）。
--       ★ 可能是刻意的（关闭时不需要强调），也可能是遗漏。
--       ★ 记录为 L 类不一致。
ACTIONS.USESPELLBOOK.strfn = function(act)
	return (act.doer:HasTag("pyromaniac") and "PYROKINESIS")
		or (act.doer:HasTag("handyperson") and "REMOTE")
		or (act.doer:HasTag("dogrider") and "WOBY")
        or (act.invobject and act.invobject:HasTag("abigail_flower") and "GHOSTTALK")
		or nil
end

--★★★【USESPELLBOOK.pre_action_cb —— 全文件最长的 pre_action_cb（35 行）】
--   ★★ 它做五件事：
--     ① 5903  检查燃料是否耗尽（fueldepleted 标签）
--     ② 5909-5912 若手上拿的不是它，ReturnActiveItem（换到手上）
--     ③ 5913-5918 若 HUD 挡着（ishudblocking），先关制作栏
--     ④ 5919-5924 ShouldOpen 检查后打开法术书
--     ⑤ 5925-5927 若 SG 在 overridelocomote 态，推「locomote」事件
--   ★★★ ②的原因：`inventory:GetActiveItem() ~= target` 时
--     先把当前手上的东西放回背包。这保证了「打开法术书」时手是空的。
--   ★★★ ④的注释「ShouldOpen is useful for silently blocking it
--     eg. when classified commands are in a busy preview state」——
--     ★★★ 又一处显式的「静默阻止」机制：ShouldOpen 返回假时不开书，
--       也不报错。适用于「正在预览其他指令时不要被打断」。
--   ★★★ ⑤是 p3 1228 行 sgparam 机制的另一面：
--     直接调 `sg.currentstate:HandleEvent(sg, "locomote")` 手动触发事件。
--     ★ 这是「状态图私有 API 的外部调用」—— 破坏性较强。
--     ★★ 对比 5939 行的同样调用（在 fn 里），说明这是必要操作。
--   ★★ 5899 行 `if act.doer.HUD then` —— pre_action_cb 双端运行，
--     服务端可能没有 HUD。这是必需的检查（对比 4904 行用 ~= nil）。
ACTIONS.USESPELLBOOK.pre_action_cb = function(act)
	if act.doer.HUD then
--★★ USESPELLBOOK.pre_action_cb（5898-5932）的五步流程。
--   ★★ ②5909-5912：若手上拿的不是它，ReturnActiveItem（腾出手）。
--   ★★ ④5922-5924：ShouldOpen 允许**静默阻止**开书。
--   ★★ ⑤5925-5927：若 SG 在 overridelocomote 态，手推 locomote 事件。
--   ★★ 这是本文件里最长的 pre_action_cb，也是「清界面」模式的集大成者。
		local target, isvalid
		if act.invobject then
			target = act.invobject
			isvalid = not target:HasTag("fueldepleted")
		elseif act.target and act.target.inventoryitem == nil then
			target = act.target
			isvalid = true
		end
		if target and target.components.spellbook and target.components.spellbook:CanBeUsedBy(act.doer) then
			local inventory = act.doer.replica.inventory
			if inventory and inventory:GetActiveItem() ~= target then
				inventory:ReturnActiveItem()
			end
--★★ USESPELLBOOK.pre_action_cb 的③④⑤（5913-5927）：
--   ③5913-5918 HUD 挡着（ishudblocking）→ 先关制作栏，再重新检查
--     ★★★ 5917 行的「重新检查」很关键：
--       关上制作栏后 playercontroller 的启用状态可能变了。
--       ★ 「检查 → 动作 → 再检查」的循环是 UI 状态机的常见模式。
--   ④5919-5924 ShouldOpen 后才真正 OpenSpellBook
--   ⑤5925-5927 若 SG 在 overridelocomote 态，手推 locomote 事件
--     ★ 与 fn（5939-5941）里同样的调用 ——
--       「pre_action_cb 与 fn 各做一遍」是这个动作的双端协作。
			if isvalid and act.doer.components.playercontroller then
				local isenabled, ishudblocking = act.doer.components.playercontroller:IsEnabled()
				if ishudblocking then
					act.doer.HUD:CloseCrafting()
					isenabled, ishudblocking = act.doer.components.playercontroller:IsEnabled()
				end
				if isenabled then
					--V2C: ShouldOpen is useful for silently blocking it
--★★ 5922 行的 ShouldOpen —— 「静默阻止开书」的钩子。
--   ★★ 注释（5920-5921 行）说明了用途：
--     「ShouldOpen 对静默阻止很有用，比如指令正处于忙的预览状态时。」
--   ★★★ 「静默阻止」= 不开书也不报错，玩家只看到「没反应」。
--     ★ 适用于「此时不该被打断」的场景，而不是「玩家做错了」。
					--     eg. when classified commands are in a busy preview state
					if target.components.spellbook:ShouldOpen(act.doer) then
						target.components.spellbook:OpenSpellBook(act.doer)
					end
					if act.doer.sg and act.doer.sg:HasStateTag("overridelocomote") then
						act.doer.sg.currentstate:HandleEvent(act.doer.sg, "locomote")
					end
				end
			end
		end
	end
end

--★★★【USESPELLBOOK.fn —— 25 行，四件事】
--   ★★ ① 5937 ReturnActiveActionItem(act.invobject, true) ——
--     ★★★ 第二个参数 instant=true（inventory.lua:336）。
--       该函数的条件是 `(inst.bufferedaction ~= nil) == not instant`：
--         · instant=false ⇒ 要求「当前**没有** bufferedaction」
--         · instant=true  ⇒ 要求「当前**有** bufferedaction」
--       ★★ 这是「在动作执行期间归还手持物」的正确调用方式。
--       ★ 对比 4370 行 PEEKBUNDLE 用单参数版：
--         那里是在动作**开始前**执行（pre 阶段），所以 instant=false。
--         ★★★ 两处的参数差异不是笔误，而是时序差异。
--   ★★ ② 5939-5941 手推 locomote 事件（与 5925 同款）。
--   ★★ ③ 5942 CloseAllChestContainers() ——
--     ★★★ 「打开法术书前关上所有**箱子类型**的容器」。
--       ★ 已核实 inventory.lua:2118-2124：它只关
--         `k.components.container.type == "chest"` 的容器 ——
--         锅、冰箱、种植箱**不会**被关。
--       ★★ 所以这不是「关闭一切」，而是「只关散落在世界上的箱子」，
--         避免它们在地图上闪图标。语义比函数名暗示的窄得多。
--       ★ 注意它**不检查 IsOpenedBy** ⇒ 也会关别人开着的箱子。
--         ★★ 在多人服务器上可能造成「别人的箱子突然关了」。
--         ★ 记录为 L 类观察点（多人下的副作用）。
--   ★★ ④ 5944-5949 解除舵轮与炮的绑定 ——
--     ★★★ 「开法术书前先把手上正在用的东西放下」。
--       ★ 与 5039 行的 SetCannon(nil) / 5945 行的 SetSteeringWheel(nil) 同族。
--       ★ 这是一个「统一的『准备开界面』清理序列」。
--   ★★ 5950-5954 行的返回值：
--     invobject → 看 fueled 是否为空（没燃料就失败）
--     target    → 目标必须**没有** inventoryitem 组件（不是物品）
--     ★★★ 后者意味着「只能给自己施法」（自己是实体而非物品）。
--       ★ 这就是 WOBY 那个变体的工作方式。
ACTIONS.USESPELLBOOK.fn = function(act)
	if act.doer.components.inventory ~= nil then
		if act.invobject then
			act.doer.components.inventory:ReturnActiveActionItem(act.invobject, true)
		end
		if act.doer.sg:HasStateTag("overridelocomote") then
			act.doer.sg.currentstate:HandleEvent(act.doer.sg, "locomote")
		end
		act.doer.components.inventory:CloseAllChestContainers()
	end
	if act.doer.components.steeringwheeluser ~= nil then
		act.doer.components.steeringwheeluser:SetSteeringWheel(nil)
	end
	if act.doer.components.boatcannonuser ~= nil then
		act.doer.components.boatcannonuser:SetCannon(nil)
	end
	if act.invobject then
		return not (act.invobject.components.fueled and act.invobject.components.fueled:IsEmpty())
	else
		return act.target ~= nil and act.target.components.inventoryitem == nil
	end
end

--★ CLOSESPELLBOOK.strfn —— 三项（缺 dogrider，§p7 5890 行已指出）。
ACTIONS.CLOSESPELLBOOK.strfn = function(act)
	return (act.doer:HasTag("pyromaniac") and "PYROKINESIS")
		or (act.doer:HasTag("handyperson") and "REMOTE")
        or (act.invobject and act.invobject:HasTag("abigail_flower") and "GHOSTTALK")
		or nil
end

--★ CLOSESPELLBOOK.pre_action_cb —— 只做一件事：关法术轮盘。
--   ★★ 5965 行用 `GetCurrentOpenSpellBook() == (invobject or target)` 确认
--     「关的正是当前打开的那个」—— 防止误关。
ACTIONS.CLOSESPELLBOOK.pre_action_cb = function(act)
	if act.doer.HUD and act.doer.HUD:GetCurrentOpenSpellBook() == (act.invobject or act.target) then
		act.doer.HUD:CloseSpellWheel()
	end
end

--★ CLOSESPELLBOOK.fn —— 一行 return true（关闭不需要逻辑）。
ACTIONS.CLOSESPELLBOOK.fn = function(act)
	return true
end

--★★ CAST_SPELLBOOK.fn —— 施放（14 行）。
--   ★★ 5985 行的 elseif：`act.target == act.doer` ——
--     ★★★ 「目标是自己」⇒ 用**自己身上的**法术书施法。
--       ★ 与 5953 行的「target 没有 inventoryitem」呼应。
--       ★ 这是「WOBY（自己就是书）」的实现。
--   ★★ 5979-5981 行的三重条件确保「是自己包里的、且我能用」。
--     ★★★ GetGrandOwner() == act.doer 检查防止「用别人包里的书」。
ACTIONS.CAST_SPELLBOOK.fn = function(act)
	if act.invobject then
		if act.doer.components.inventory then
			act.doer.components.inventory:ReturnActiveActionItem(act.invobject)
		end
		if act.invobject.components.inventoryitem and
			act.invobject.components.inventoryitem:GetGrandOwner() == act.doer and
			act.invobject.components.spellbook and act.invobject.components.spellbook:CanBeUsedBy(act.doer)
		then
			return act.invobject.components.spellbook:CastSpell(act.doer)
		end
	elseif act.target == act.doer and act.target.components.spellbook and act.target.components.spellbook:CanBeUsedBy(act.doer) then
		return act.target.components.spellbook:CastSpell(act.doer)
	end
end

--★ SITON.fn —— 「两阶段动作」的第 5 个实例（§p4 664 行）。
--   ★★ 5993 行检查 sg 处于 **start_sitting** 状态。
--   ★★ 与 JUMPIN 的 jumpin_pre 是完全相同的手法。
--   ★★ 5996 行的 `not IsOccupied()` —— 「座位没被占」。
--     ★ 无失败原因（隐式 nil）。
ACTIONS.SITON.fn = function(act)
	if act.doer ~= nil and
		act.doer.sg ~= nil and
		act.doer.sg.currentstate.name == "start_sitting" then
		if act.target ~= nil and
--★ 6000 行的 end 缩进比 5994 行深一级 —— 属风格瑕疵。
			act.target.components.sittable ~= nil and
			not act.target.components.sittable:IsOccupied() then
			act.target.components.sittable:SetOccupier(act.doer)
			return true
		end
	end
end

--★ USE_WEREFORM_SKILL.fn —— 伍迪的狼形技能。
--   ★★ `return act.doer ~= nil and act.doer:UseWereFormSkill(act)` ——
--     ★★★ **把整个 act 传给实体方法**。
--       ★ 这是本文件里唯一把完整 BufferedAction 传给下游的地方。
--       ★ 意味着木头人的技能实现可以读取 act 的所有字段。
--       ★ 灵活但破坏了封装（实体不该知道动作系统的细节）。
--       ★ 记为 L 类设计观察。
ACTIONS.USE_WEREFORM_SKILL.fn = function(act)
    return act.doer ~= nil and act.doer:UseWereFormSkill(act)
end

--★ REMOTE_TELEPORT.stroverridefn —— 「{物品}」的完整句子。
ACTIONS.REMOTE_TELEPORT.stroverridefn = function(act)
	return act.invobject
		and subfmt(STRINGS.ACTIONS.REMOTE_TELEPORT.GENERIC_FMT, { item = act.invobject:GetDisplayName() })
		or nil
end

--★ REMOTE_TELEPORT.fn —— 远程传送（韦伯/温蒂）。标准 T2 模板。
--   ★★ 6019 行的 CanActivate 在服务端调 —— 注意命名与 ACTIVATE 的
--     CanActivate 同名但不同组件。
ACTIONS.REMOTE_TELEPORT.fn = function(act)
	if act.invobject and act.invobject.components.remoteteleporter then
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end

		local success, reason = act.invobject.components.remoteteleporter:CanActivate(act.doer)
		if success then
			success, reason = act.invobject.components.remoteteleporter:Teleport(act.doer)
		end
		return success, reason
	end
end

--★ INCINERATE.fn —— 焚烧。四行。
ACTIONS.INCINERATE.fn = function(act)
    if act.target.components.incinerator ~= nil then
        return act.target.components.incinerator:Incinerate(act.doer)
    end

    return false
end

--★ BOTTLE.fn —— 装瓶。三行。
ACTIONS.BOTTLE.fn = function(act)
	if act.invobject and act.invobject.components.bottler then
		return act.invobject.components.bottler:Bottle(act.target, act.doer)
	end
end

--★★★【CARVEPUMPKIN.fn —— 雕刻南瓜（34 行），「先放下再雕」】
--   ★★ 6043 行的双组件：`pumpkincarvable or pumpkinhatcarvable`。
--     ★★★ 「南瓜」与「南瓜帽」用同一套逻辑，但走不同组件。
--     ★ 这就是「一个动作两个组件」的又一样本（与 EAT/HARVEST 同族）。
--   ★★ 6045-6047 行的保留注释（V2C）：
--     「for searching => pumpkinhatcarvable:CanBeginCarving / BeginCarving」
--     ★★★ 这是**给搜索者留的线索**：告诉读者「南瓜帽的对应实现在哪」。
--       ★ 这种注释在大型代码库里极有价值 —— 它是导航而非解释。
--   ★★ 6053-6070 行的「先从背包放下」流程（雕刻中不能手持物品）：
--     ① 6054 黑暗中静默跳过（6053 行注释「Silent fail for carving in the dark」）
--     ② 6055-6068 若在别人（或自己）背包里 → DropItem
--        ★★ 6065-6067 行的检查很妙：
--          `if IsHeld() then return false` —— 「放下来失败了?!?」
--          ★ 作者用「?!?」表达「这不该发生但万一发生了要兜住」。
--     ③ 6069 BeginCarving
--   ★★ 6058 行的 grandowner 检查：别人拿着就拒绝（6059 行注释
--     「someone else holding it?!」）。
ACTIONS.CARVEPUMPKIN.fn = function(act)
	if act.doer and act.target then
		local pumpkincarvable = act.target.components.pumpkincarvable or act.target.components.pumpkinhatcarvable
		if pumpkincarvable then
--★★ CARVEPUMPKIN.fn 的「先放下再雕」流程在 6053-6070。
--   ★★ 6055-6068 的四层：
--     ① 6058 grandowner 不是自己 → 拒绝（有人拿着）
--     ② 6062-6063 DropItem 从背包/容器里放出来
--     ③ 6065-6067 放下来失败 → return false（「?!?」注释）
--   ★★★ 「雕刻前必须把手腾空」是这类长动作的通用前置。
			--V2C: for searching =>
			--  pumpkinhatcarvable:CanBeginCarving(act.doer)
			--  pumpkinhatcarvable:BeginCarving(act.doer, act.target)
			local success, reason = pumpkincarvable:CanBeginCarving(act.doer)
			if not success then
				return false, reason
			end

			--Silent fail for carving in the dark
			if CanEntitySeeTarget(act.doer, act.target) then
				local owner = act.target.components.inventoryitem and act.target.components.inventoryitem.owner
--★★ CARVEPUMPKIN.fn 的「先放下」在 6056-6068：
--   ①6056  owner = 目标的直接持有者
--   ②6057  grandowner = 递归持有者（见 §p3 1098 行的说明）
--   ③6058-6059 grandowner 不是自己 → return false（别人拿着）
--   ④6061  inventory 或 container
--   ⑤6063  DropItem 放出来
--   ⑥6065-6067 仍 IsHeld → return false（「?!?」）
--   ⑦6069  BeginCarving
--   ★★★ ③用 grandowner 而 ①用 owner ——
--     「谁的手包里」与「最终是谁的」是两个概念。
--     ★ 这里两者都用，是为了「不能雕刻别人背包里的南瓜」。
				if owner then
					local grandowner = act.target.components.inventoryitem:GetGrandOwner()
					if grandowner ~= act.doer and grandowner.components.inventory then
						return false --someone else holding it?!
					end
					local inventory = owner.components.inventory or owner.components.container
					if inventory then
						inventory:DropItem(act.target)
--★★ 6064-6067 行 —— 「放下来失败」的兜底。
--   ★★ `if act.target.components.inventoryitem:IsHeld() then return false`
--   ★★★ 注释「failed to drop?!?!」表达了作者的不确定 ——
--     ★ 这是一处「作者自己也不认为会发生」的防御分支。
					end
					if act.target.components.inventoryitem:IsHeld() then
						return false --failed to drop?!?!
					end
				end
				pumpkincarvable:BeginCarving(act.doer)
			end
			return true
		end
	end
end

--★★ DECORATESNOWMAN.strfn —— 三态（STACK 自重 / STACK 小雪球 / nil）。
--   ★★ 6080 行 `IsHeavyLifting() and "STACK" or nil` ——
--     ★★★ 「正在搬运重物」⇒ 显示 STACK（叠大雪球）。
--       ★ 与 §p7 5548 行 USE_HEAVY_OBSTACLE 用同一个 IsHeavyLifting。
--       ★ 这个字段是「搬运状态」的统一判据。
--   ★ 6082 行的注释「for small throwable snowballs」说明第二个 STACK
--     变体对应「小雪球道具」。
ACTIONS.DECORATESNOWMAN.strfn = function(act)
	if act.doer then
		if act.invobject == nil then
			local inventory = act.doer.replica.inventory
			return inventory and inventory:IsHeavyLifting() and "STACK" or nil
		elseif act.invobject.components.snowmandecoratable then
			return "STACK" --for small throwable snowballs
		end
	end
end

--★★★【DECORATESNOWMAN.fn —— 装饰雪人（80 行）】
--   ★★ 这是全文件里**最长的单一 fn**，三种模式：
--     ① 手上没有 snowmandecoratable → 「开始装饰」（戴帽子或用物品）
--     ② 手上是 snowmandecoratable    → 「叠小雪球」
--     ③ 手上没东西但在搬运重物       → 「叠大雪球」
--   ★★★ 判定入口（6089 行）：
--       `if act.invobject then if invobject.snowmandecoratable == nil then ①
--        else ② end else ③ end`
--     ★★★ 二分判定的精妙之处：**用「手上物品是否也是可装饰物」来
--       区分「开始装饰」与「叠雪球」**。
--       ★ 因为「叠雪球」用的也是 snowmandecoratable 组件的物品。
--       ★ 这是「组件既表示能力又表示用途」带来的歧义的巧妙消解。
--   ★★★ ②③ 两段代码（6108-6134 与 6135-6164）**高度重复**：
--     都是「取 size → 删掉旧的 → SpawnPrefab("snowman") → SetSize → Stack」。
--     唯一差别是「大雪球从 BODY 槽取」（6137 行）vs「小雪球从手上取」。
--     ★ 与 REPLATE.fn（5253）的 ④⑤ 同款「未抽象的重复」。
--     ★ 若要重构，最自然的抽取是 `local function StackSnowman(target, from)`。
--   ★★ 6121-6123 行的堆叠处理：
--       `if target.stackable and IsStack() then stackable:Get():Remove()`
--       ★★★ 堆叠的雪人只取一个来「长」，其余留在原地。
--         6123 行的 DoDropPhysics 把其余的散落在地上。
--     ★ 这与 REPLATE 的 stacksize 处理同族，但方向相反
--       （REPLATE 是「放回去」，这里是「取出来」）。
--   ★★ 6118/6147 行的 `not target:HasTag("heavy")` ——
--     ★ 大雪人（heavy）不能「再往上叠」。
--       ★ 用标签表达「这是顶天了」的状态。
--   ★★★ 三处「黑暗中静默失败」（6098/6116/6145）——
--     全部遵循 §0 第 8 条的统一模式。
--     ★ 一致性极高：装饰类动作的黑暗保护是**强制约定**。
ACTIONS.DECORATESNOWMAN.fn = function(act)
	if act.doer and act.target and act.target.components.snowmandecoratable then
		if act.invobject then
--★★ DECORATESNOWMAN.fn 的三种模式在 6089-6164。
--   ★★ 模式判定（6089 行）：「手上物品是否也是 snowmandecoratable」
--     ★★★ 这是「组件既表示能力又表示用途」带来的歧义的巧妙消解。
--   ★★ ②6108-6134 与 ③6135-6164 两段**高度重复**，
--     唯一差别是「大雪球从 BODY 槽取」vs「小雪球从手上取」。
--     ★ 与 REPLATE.fn（5253）的 ④⑤ 同款「未抽象的重复」。
			if act.invobject.components.snowmandecoratable == nil then
				--Start decorating
				local success, reason = act.target.components.snowmandecoratable:CanBeginDecorating(act.doer)
				if not success then
					return false, reason
				end

				--Silent fail for decorating in the dark
				if CanEntitySeeTarget(act.doer, act.target) then
					if act.invobject.components.equippable and act.invobject.components.equippable.equipslot == EQUIPSLOTS.HEAD then
						--Equip hat
						act.target.components.snowmandecoratable:EquipHat(act.invobject)
					else
						--Begin decorating with items
						act.target.components.snowmandecoratable:BeginDecorating(act.doer, act.invobject)
					end
				end
				return true
			else
				--Stacking throwable snowballs
--★★ DECORATESNOWMAN.fn 的模式②（叠小雪球）6108-6134：
--   ①6110  CanStack 预检
--   ②6116  CanEntitySeeTarget（黑暗中静默）
--   ③6117-6130 「长出新雪人」的四步：
--     · 6118-6126 不是 heavy 才有资格「长大」
--     · 6121-6123 堆叠的只取一个，其余 DoDropPhysics 散落
--     · 6127-6129 SpawnPrefab("snowman") + SetSize + SetPosition
--   ④6131  Stack(doer, invobject)
--   ★★★ 6121-6123 的「堆叠拆分」与 REPLATE 的「堆叠还原」是镜像操作。
				local success, reason = act.target.components.snowmandecoratable:CanStack(act.doer, act.invobject)
				if not success then
					return false, reason
				end

				--Silent fail for stacking in the dark
				if CanEntitySeeTarget(act.doer, act.target) then
					local target = act.target
					if not target:HasTag("heavy") then
						local x, y, z = target.Transform:GetWorldPosition()
						local size = target.components.snowmandecoratable:GetSize()
						if target.components.stackable and target.components.stackable:IsStack() then
							target.components.stackable:Get():Remove()
							target.components.inventoryitem:DoDropPhysics(x, y, z, true)
						else
--★★ 6125-6130 行 —— 「销毁旧的、长出新的」。
--   ★★ 6127 行硬编码 prefab 名 "snowman"。
--     ★ 与 DROP.strfn（1191 行）硬编码 "pumpkin_lantern" 同款 ——
--       全文件大量使用标签，唯独这里用 prefab 名（因为要 Spawn 新的）。
--   ★★ 6128 行 SetSize(size) 保留原有尺寸 ⇒ 「长大」而非「重造」。
							target:Remove()
						end
						target = SpawnPrefab("snowman")
						target:SetSize(size)
						target.Transform:SetPosition(x, 0, z)
					end
					target.components.snowmandecoratable:Stack(act.doer, act.invobject)
				end
				return true
			end
		elseif act.doer.components.inventory and act.doer.components.inventory:IsHeavyLifting() then
			--Stacking large snowballs
			local item = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
			if item and item.components.snowmandecoratable then
				local success, reason = act.target.components.snowmandecoratable:CanStack(act.doer, item)
				if not success then
					return false, reason
				end

				--Silent fail for stacking in the dark
				if CanEntitySeeTarget(act.doer, act.target) then
					local target = act.target
--★★ 模式③（叠大雪球）6135-6164 与模式②**几乎逐行相同**：
--   ★★ 唯一差别：6137 行从 BODY 槽取装备而非从 invobject 取。
--   ★★★ 6174-6181 与 6108-6134 的结构完全对应 ——
--     ★ 又一处「未抽取的重复」。
--     ★ 若重构，可抽成 StackSnowman(target, source_item)。
					if not target:HasTag("heavy") then
						local x, y, z = target.Transform:GetWorldPosition()
						local size = target.components.snowmandecoratable:GetSize()
						if target.components.stackable and target.components.stackable:IsStack() then
							target.components.stackable:Get():Remove()
							target.components.inventoryitem:DoDropPhysics(x, y, z, true)
						else
							target:Remove()
						end
						target = SpawnPrefab("snowman")
						target:SetSize(size)
						target.Transform:SetPosition(x, 0, z)
					end
					target.components.snowmandecoratable:Stack(act.doer, item)
				end
				return true
			end
		end
	end
end

--★ START_PUSHING.strfn —— ROLL 变体（推雪球）。
ACTIONS.START_PUSHING.strfn = function(act)
	return act.target and act.target:HasTag("pushing_roll") and "ROLL" or nil
end

--★ START_PUSHING.fn —— 四行。IsPushing 检查防止重复推。
ACTIONS.START_PUSHING.fn = function(act)
	if act.target and act.target.components.pushable and not act.target.components.pushable:IsPushing() then
		act.target.components.pushable:StartPushing(act.doer)
		return true
	end
end

--★★ APPLYELIXIR.stroverridefn —— DRINK / APPLY 两变体。
--   ★★ 6181 行的 `HasTag("elixir_drinker")` 决定是「喝」还是「涂」。
--     ★★★ 同一种物品（灵药），对不同目标用不同动词。
--       ★ 与 DROP.strfn（1186）的 13 个标签是同一手法。
ACTIONS.APPLYELIXIR.stroverridefn = function(act)
    if act.invobject then
        if act.target and act.target:HasTag("elixir_drinker") then
            return subfmt(STRINGS.ACTIONS.GIVE.DRINK, {item = act.invobject:GetBasicDisplayName()})
        else    
            return subfmt(STRINGS.ACTIONS.GIVE.APPLY, {item = act.invobject:GetBasicDisplayName()})
        end
    end
end

--★ find_elixirable_fn —— 6190 行前的一个单行谓词函数。
--   ★★★ `local function find_elixirable_fn(item) return item.components.ghostlyelixirable ~= nil end`
--     ★ 三种写法对比（本文件三种谓词风格齐全）：
--       · 单行箭头式（本处）
--       · 多行函数式（5020 行 IsBoatCannonAmmo）
--       · 闭包捕获式（3475 行 TryToUpdateNearest）
--     ★ 说明谓词写法完全按当时的心情，无统一规范。
--   ★ 6190-6210 行：先看目标是「elixir_drinker」还是玩家自己，
--     再决定给谁涂灵药。
--   ★★ 6202 行 FindItem(find_elixirable_fn) —— 在背包里找「可涂的东西」。
local function find_elixirable_fn(item) return item.components.ghostlyelixirable ~= nil end
ACTIONS.APPLYELIXIR.fn = function(act)
    local doer = act.doer
    local object = act.invobject
    if doer and object and doer.components.inventory then
        if act.target and act.target:HasTag("elixir_drinker") then
            if object:HasTag("super_elixir") then
                return false, "TOO_SUPER"
            else
                object.components.ghostlyelixir:Apply(doer, act.target)
                return true
            end
        else
            local elixirable_item = doer.components.inventory:FindItem(find_elixirable_fn)
            if elixirable_item then
                return object.components.ghostlyelixir:Apply(doer, elixirable_item)
            else
                return false, "NO_ELIXIRABLE"
            end
        end
    end
end

--★ GRAVEDIG.fn —— 挖坟（14 行）。
--   ★★ 6213 行 `local success, reason = false, nil` ——
--     ★★★ 显式初始化为 false, nil，然后在末尾 return。
--       ★ 这是「保证函数总有返回二元组」的正确写法。
--       ★ 与多数动作「隐式返回 nil」的风格不同，但更严谨。
--   ★★ 6220 行 `gravedigger:OnUsed(doer, target)` 在 DigUp **之前**：
--     ★ 「先用工具（可能是手），再挖」。
--       ★ 顺序意味着工具的副作用先发生（可能改变目标状态）。
ACTIONS.GRAVEDIG.fn = function(act)
    local success, reason = false, nil

    local target = act.target
    if target and target.components.gravediggable then
        local tool = act.invobject

        if tool and tool.components.gravedigger then
            tool.components.gravedigger:OnUsed(act.doer, target)
        end
        success, reason = target.components.gravediggable:DigUp(tool, act.doer)
    end

    return success, reason
end

--★ MUTATE.stroverridefn —— 「变异成 {目标}」的完整句子。
--   ★★ 6229 行的 `act.target.getghostgestalttarget` ——
--     ★ prefab 实例上的方法（无 components 前缀），
--       与 ACTIVATE 的 GetActivateVerb 同型。
ACTIONS.MUTATE.stroverridefn = function(act)
    return act.target and act.target.getghostgestalttarget
        and subfmt(STRINGS.ACTIONS.MUTATE.MUTATE_TARGET, { target = act.target:getghostgestalttarget(act.doer) })
        or nil
end

--★ MUTATE.fn —— 变异。14 行，与 GRAVEDIG 结构相同。
ACTIONS.MUTATE.fn = function(act)
    local success, reason = false, nil

    local target = act.target
    if target and target.components.ghostgestalter then
        success, reason = target.components.ghostgestalter:DoMutate(act.doer)
    end

    return success, reason
end

--★★★【WOBY_PICKUP.fn —— 狗捡东西（38 行），几乎复制 PICKUP.fn】
--   ★★ 6249 行的**异常缩进**（多一级）说明这段代码被后来插入。
--   ★★ 6250 行 `act.doer.components.container == nil then return false` ——
--     ★★★★ 狗有 container 而不是 inventory（§2 684 行已预告）。
--     ★ 6254-6261 行的可捡条件与 PICKUP.fn（889）几乎一致，
--       但**少了** canbepickedupalive 与三个特殊分支：
--       ★ 对比 PICKUP 的四个拒绝原因（901/903/905/910），
--         这里只有三个（6263 restriction / 6265 INUSE / 6267 YOTC）
--         且 6272 的 heavy 检查改为**无条件拒绝**。
--       ★★★ 因为狗的 container 没有 noheavylifting 概念 ——
--         狗天生搬不了重物，所以「重物一律不行」。
--       ★★ 结论：这是**复制后裁剪**的产物，两处会独立演化。
--       ★ 记为 L 类维护风险（非缺陷）。
--   ★★ 6286 行的 validfn 存疑（见 L10 详解，该行在 WOBY_PICK 而非 PICKUP）。
ACTIONS.WOBY_PICKUP.fn = function(act)
    if act.target == nil then
        return false
    end

    if act.doer.components.container == nil then
        return false
    end

    if act.target.components.inventoryitem ~= nil and
        (
            act.target.components.inventoryitem.canbepickedup or
            act.target.components.inventoryitem.grabbableoverridetag ~= nil and act.doer:HasTag(act.target.components.inventoryitem.grabbableoverridetag)
        ) and
        not (act.target:IsInLimbo() or
            (act.target.components.burnable ~= nil and act.target.components.burnable:IsBurning() and act.target.components.lighter == nil) or
            (act.target.components.projectile ~= nil and act.target.components.projectile:IsThrown()))
    then
        if act.doer.components.itemtyperestrictions ~= nil and not act.doer.components.itemtyperestrictions:IsAllowed(act.target) then
--★ 6264 行的失败原因 "restriction" 是**小写** ——
--   ★★★ 全文件其它失败原因都是大写（如 "INUSE"、"FULL"）。
--     ★ 与 PICKUP.fn 的 902 行同样是 "restriction"，
--       说明这是一对复制，错误也一起复制了。
--     ★ 记录为 L 类风格瑕疵（可能影响语言包的查找）。
            return false, "restriction"
        elseif act.target.components.container ~= nil and act.target.components.container:IsOpenedByOthers(act.doer) then
            return false, "INUSE"
        elseif (act.target.components.yotc_racecompetitor ~= nil and act.target.components.entitytracker ~= nil) then
            local trainer = act.target.components.entitytracker:GetEntity("yotc_trainer")
            if trainer ~= nil and trainer ~= act.doer then
                return false, "NOTMINE_YOTC"
            end
        elseif act.target:HasTag("heavy") then
            return false, "NO_HEAVY_LIFTING"
        end

        act.doer:PushEvent("onpickupitem", { item = act.target })

        act.doer.components.container:GiveItem(act.target, nil, act.target:GetPosition())

        return true
    end
end

--★★★⚠⚠ 疑似缺陷 L10：WOBY_PICK.validfn 的语义与 validfn 约定相反。
--     `return act.doer:GetForagerTarget() ~= nil or (act.target ~= nil
--        and act.target.components.pickable ~= nil
--        and not act.target.components.pickable:CanBePicked())`
--   ★★★★ 推理依据（三条）：
--     ① validfn 的契约（bufferedaction.lua:46）：返回 **真** 表示「有效，
--        允许继续执行」；返回假/nil 表示「无效，应中止」。
--        ★ 参照本文件另外 3 个 validfn（CHOP/MINE/HAMMER/DIG 的）
--          全部返回 ValidToolWork(...) —— 「目标可干」为真时有效。
--     ② 本函数返回真的条件是：
--        · 「狗**已经有**采食目标」——按注释（6285 行）
--          「Walter is picking or has picked the target already.」
--          ⇒ 这是一个「**已经在采**」的状态
--        · 或者「目标**不能**被采摘」（not CanBePicked）
--          ⇒ 这是一个「**不可行**」的状态
--        ★★★ 两个条件都是「负面状态」，却被当成「有效性」返回。
--     ③ 与 fn 对照（6289 行）：
--        fn 只在 `pickable ~= nil` 时才做正事（SpawnProductLoot），
--        且不检查 CanBePicked。
--        ★⇒ fn 的准入条件（目标有 pickable）与 validfn 的准入条件
--          （已经有目标 **或** 不能采摘）**几乎不相交**。
--   ★★★ 结论：validfn 写的很可能是 `not` 写错了位置，
--     应该是「**没有**采食目标 且 目标**能**被采摘」。
--   ★★ 实际影响：
--     · 服务端每帧调用（locomotor.lua:1452 间接）
--     · validfn 返回真 ⇒ BufferedAction:IsValid() 返回真 ⇒ 动作继续
--     · ⇒ **恰好在「已经有目标」时允许继续**，
--       「没有目标」时反而 return false（因为第一个条件不成立、
--       而第二个条件通常也不成立）⇒ **动作永远无法开始**。
--     ★★★ 除非有别的代码路径（brains/wobycommon.lua:178）绕过。
--       ★ 确认：wobycommon.lua:178 确实用 BufferedAction(inst, target, WOBY_PICK)，
--         所以 AI 路径会走 PushAction → TestForStart → IsValid → validfn。
--       ★⇒ 若 validfn 真的反了，狗的 AI 采摘会失败。
--   ★ 可能性说明：也可能 validfn 的语义是「**允许中断**」的反面 ——
--     但那样的话变量名与注释都不对。
--     ★ 无论如何，注释（6285 行）与返回值表达的状态完全相反。
--   ★★★ 结论：**注释与代码严重矛盾，疑似缺陷**。只记录不修改。
--     ★ 若实际游戏里狗能正常采摘，说明这条路径被绕过或另有分支。
ACTIONS.WOBY_PICK.validfn = function(act)
    -- Walter is picking or has picked the target already.
    return act.doer:GetForagerTarget() ~= nil or (act.target ~= nil and act.target.components.pickable ~= nil and not act.target.components.pickable:CanBePicked())
end

--★★★【WOBY_PICK.fn —— 狗采摘（28 行），一个「临时改字段」的手法】
--   ★★ 6297-6302 行的核心技巧：
--       local _numtoharvest = pickable.numtoharvest
--       pickable.numtoharvest = 1      -- Just one, always.
--       local loot = pickable:SpawnProductLoot(doer)
--       pickable.numtoharvest = _numtoharvest
--   ★★★★ 「借字段 + 立刻还原」的经典模式。
--     ★ 为什么需要？pickable 组件每次产出 numtoharvest 个，
--       但狗每次只摘一个 ⇒ 临时改字段控制产出量。
--     ★★ 这是一种**侵入式适配**：修改别人组件的内部字段。
--       ★ 好处：不用改 pickable 组件（要兼容所有调用者）。
--       ★ 风险：若 SpawnProductLoot 抛错，字段不会被还原。
--     ★★★ 而且这段代码**没有 pcall 保护** ——
--       异常路径会导致 numtoharvest 永久停留在 1。
--       ★ 记为 L 类隐患（异常安全）。
--   ★★ 6305 行的类型归一：`EntityScript.is_instance(loot) and {loot} or loot` ——
--     ★★★ 「产出可能是单个实体也可能是数组」⇒ 归一成数组。
--       ★ 这是处理「Lua 无重载」的标准手段。
--       ★ 与 actions.lua 里其它地方的归一手法（如 1353 行的 oar）同族。
--   ★★ 6307-6309 行的 LaunchAt —— 「把采到的东西抛向狗的方向」。
--     ★ 参数 `target:GetPhysicsRadius(0) + .25` 是抛射起点偏移。
ACTIONS.WOBY_PICK.fn = function(act)
	if act.target == nil then
        return false
    end

    local pickable = act.target.components.pickable
--★★ WOBY_PICKUP.fn 是 PICKUP.fn 的裁剪版（6245-6282）。
--   ★★ 判定链与 PICKUP 几乎一致，但少了三个特殊分支
--     （canbepickedupalive / curseditem / drop_inventory_onpickup），
--     且 6272 的 heavy 检查改为**无条件拒绝**。
--   ★★★ 原因：狗没有 noheavylifting 概念，天生搬不了重物。

    if pickable ~= nil then
        local _numtoharvest = pickable.numtoharvest
        pickable.numtoharvest = 1 -- Just one, always.

        local loot = pickable:SpawnProductLoot(act.doer)

        pickable.numtoharvest = _numtoharvest

        if loot ~= nil then
            loot = EntityScript.is_instance(loot) and {loot} or loot

            for i, item in ipairs(loot) do
                LaunchAt(item, act.target, act.doer, nil, nil, act.target:GetPhysicsRadius(0) + .25)
            end

            return true
        end
    end

    return false
end

--★ CONTAINER_INSTALL_ITEM.strfn —— UNINSTALL 变体。
--   ★★ 注释「containerinstallableitem exists on clients too」——
--     ★ 与 3315 行的 socketable 同款注释。
--     ★★ 「组件在客户端也可读」是本文件里反复出现的注释主题，
--       它标记了「哪些判定可以放在客户端做预测」。
ACTIONS.CONTAINER_INSTALL_ITEM.strfn = function(act)
	--containerinstallableitem exists on clients too
	if act.invobject.components.containerinstallableitem then
		local containerinst = act.invobject.components.containerinstallableitem:GetValidOpenContainer(act.doer)
		if containerinst then
			local inventoryitem = act.invobject.replica.inventoryitem
			if inventoryitem and inventoryitem:IsHeldBy(containerinst) then
				return "UNINSTALL"
			end
		end
	end
end

--★★ CONTAINER_INSTALL_ITEM.pre_action_cb —— 「即时负反馈」的第三例。
--   ★★ 6332-6348 行的三段音效判断：
--     ① 容器不存在        → click_negative
--     ② 特定槽位模式下没槽 → click_negative
--     ③ 容器满了          → click_negative
--   ★★★ 全部只**播音效**不 return 任何东西 ——
--     「告诉玩家不行」但不改变流程（动作仍会尝试执行并在 fn 里失败）。
--   ★★ 6339/6342/6345 行用 **TheFocalPoint.SoundEmitter** ——
--     ★ 全局焦点点的音频发射器（UI 音效的公共通道），不是 doer 的。
--       ★ 因为音效应该从「界面焦点」发出而非从玩家位置。
--   ★★ 6332 行的 `act.invobject.components...` 无 nil 保护 ——
--     ★ 但被 `act.doer.HUD and` 短路了（服务端的 doer.HUD 为 nil）。
--       ★★★ 副作用：服务端**不会**执行这段逻辑。
--         对「播 UI 音效」来说正确（音效是客户端的事）。
--       ★ 但这是「用 nil 检查顺便做端判断」的写法 —— 隐式且脆弱。
--       ★ 记为 L 类观察点。
ACTIONS.CONTAINER_INSTALL_ITEM.pre_action_cb = function(act)
	if act.doer.HUD and act.invobject.components.containerinstallableitem then
		local containerinst = act.invobject.components.containerinstallableitem:GetValidOpenContainer(act.doer)
		if containerinst then
			local inventoryitem = act.invobject.replica.inventoryitem
			if inventoryitem and not inventoryitem:IsHeldBy(containerinst) then
				local container = containerinst.replica.container
				if container == nil then
					TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
				elseif container.usespecificslotsforitems then
					if container:GetSpecificSlotForItem(act.invobject) == nil then
						TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
					end
				elseif container:IsFull() then
					TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
				end
			end
		end
	end
end

--★★★【CONTAINER_INSTALL_ITEM.fn —— 装卸容器（46 行）】
--   ★★ 三条路径：
--     ① 6356-6371 已装上 → **卸载**
--     ② 6372-6388 特定槽位模式 → 换位
--     ③ 6389-6392 普通模式 → 直接放
--   ★★★ ①路径的 12 行是本文件里最精细的「静音操作」：
--     6358  RemoveItem
--     6359-6360  清理 prevcontainer / prevslot（同 1454 行）
--     6361-6363  clientpickupsoundsuppressor:IgnoreNextPickupSound()
--       ★★★ 客户端组件，但**在服务端被调用** ——
--         这是「服务端预置客户端状态」的技巧。
--       ★ 「先告诉客户端别播拾取音效，因为这不是拾取」。
--     6364-6365  inventory.ignoresound = true / silentfull = true
--       ★★★ 举一反三：在 GiveItem 之前**静默化**整个背包操作：
--         不播音、不提示满。
--       ★ 因为「把装好的东西拿出来」在玩家看来不是「捡东西」。
--     6366      GiveItem（静默）
--     6367-6368 立刻还原两个标志
--     6369-6371 若是手上拿着的，丢掉它
--   ★★★ 6364-6368 的模式（设标志 → 操作 → 还原）在全文件出现 3 次
--     （此处、6384-6386、以及 3305/3308 的 sg.statemem）。
--     ★ 它是「**临时覆盖行为标志**」的统一手法。
--   ★★ 6393 行的 return true 在 `if containerinst then` 内 ——
--     ★ 找不到有效容器时走 6396 行 return false。
ACTIONS.CONTAINER_INSTALL_ITEM.fn = function(act)
	if act.invobject.components.containerinstallableitem and act.invobject.components.inventoryitem then
		local containerinst = act.invobject.components.containerinstallableitem:GetValidOpenContainer(act.doer)
--★★ CONTAINER_INSTALL_ITEM.fn 的三条路径在 6352-6397。
--   ★★ ①6356-6371 卸载路径含 12 行的「静音操作」（见该处注释）：
--     clientpickupsoundsuppressor + inventory.ignoresound + silentfull。
--   ★★ ②6372-6388 特定槽位换位；③6389-6392 普通放入。
--   ★★★ 「临时覆盖行为标志 → 操作 → 还原」的模式在 6364-6368 出现。
		if containerinst then
			if act.invobject.components.inventoryitem:IsHeldBy(containerinst) then
				--uninstall
				local item = containerinst.components.container:RemoveItem(act.invobject, true)
				item.prevcontainer = nil
				item.prevslot = nil
				if item.components.clientpickupsoundsuppressor then
					item.components.clientpickupsoundsuppressor:IgnoreNextPickupSound()
				end
				act.doer.components.inventory.ignoresound = true
				act.doer.components.inventory.silentfull = true
				act.doer.components.inventory:GiveItem(item, nil, act.doer:GetPosition())
				act.doer.components.inventory.silentfull = false
				act.doer.components.inventory.ignoresound = false
				if act.doer.components.inventory:GetActiveItem() == item then
					act.doer.components.inventory:DropItem(item, true, true)
				end
			elseif containerinst.components.container.usespecificslotsforitems then
				local slot = containerinst.components.container:GetSpecificSlotForItem(act.invobject)
				if slot then
--★★ CONTAINER_INSTALL_ITEM 的路径②（特定槽位）6372-6388：
--   ①6373-6374 GetSpecificSlotForItem → slot
--   ②6375      取出新物品（RemoveFromOwner(true)）
--   ③6376-6377 取出槽位原物品，GiveItem(新) 放进去
--   ④6378-6387 原物品还回玩家（**同样静音**：ignoresound + suppressor）
--   ★★★ 6373 行的 `if slot then` ——
--     ★ 物品在特定槽位模式下没有对应槽位时不动作。
--     ★ 与 6341 行的 pre_action_cb 播否定音效配对 ——
--       「预告失败」+「实际不动」的一致设计。
					local item = act.invobject.components.inventoryitem:RemoveFromOwner(true)
					local item2 = containerinst.components.container:RemoveItemBySlot(slot)
					containerinst.components.container:GiveItem(item, slot)
					if item2 then
						item2.prevcontainer = nil
						item2.prevslot = nil
						if item2.components.clientpickupsoundsuppressor then
							item2.components.clientpickupsoundsuppressor:IgnoreNextPickupSound()
						end
						act.doer.components.inventory.ignoresound = true
						act.doer.components.inventory:GiveItem(item2, nil, act.doer:GetPosition())
						act.doer.components.inventory.ignoresound = false
					end
				end
			elseif not containerinst.components.container:IsFull() then
				local item = act.invobject.components.inventoryitem:RemoveFromOwner(true)
				containerinst.components.container:GiveItem(item)
			end
--★ 6393 行 —— 路径结束的统一 return true。
--   ★★ 6396 行的 return false 只在「找不到有效容器」时到达。
			return true
		end
	end
	return false
end

--★★★ MODSLINGSHOT.fn —— 改装弹弓（19 行），「三级目标搜索」。
--   ★★ 6401-6411 行的搜索顺序：
--     ① 6401  手持的弹弓（且我能开）
--     ② 6404-6409 遍历背包里所有带 slingshot 标签的物品
--     ★★ 6405 行的 `GetItemsWithTag("slingshot")` ——
--       按标签批量取出。6406 行排除 activeitem（手上拿着的）。
--   ★★ 6412-6414 行：都没有 → return false, "NOSLINGSHOT"。
--     ★ 唯一一个有明确失败原因的「找不到目标」场景。
--   ★★ 6415 行 `StartModding(target, doer)` 返回值直接透传。
ACTIONS.MODSLINGSHOT.fn = function(act)
	if act.doer and act.doer.components.inventory and act.invobject and act.invobject.components.slingshotmodder then
		local target = act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
		if not (target and target.components.slingshotmods and target.components.slingshotmods:CanBeOpenedBy(act.doer)) then
			target = nil
			local activeitem = act.doer.components.inventory:GetActiveItem()
			for i, v in ipairs(act.doer.components.inventory:GetItemsWithTag("slingshot")) do
				if v ~= activeitem and v.components.slingshotmods and v.components.slingshotmods:CanBeOpenedBy(act.doer) then
					target = v
					break
				end
			end
		end
		if target == nil then
			return false, "NOSLINGSHOT"
		end
		return act.invobject.components.slingshotmodder:StartModding(target, act.doer)
	end
	return false
end

--★ STOPMODSLINGSHOT.fn —— 停止改装。
--   ★★ 6422 行的遍历 `for k in pairs(opencontainers)` ——
--     ★★★ 在**打开的容器**里找 slingshotmodscontainer。
--       ★「改装界面」被实现成一个打开的容器 ——
--         于是「停止」= 找到那个容器并调它的 install_target。
--       ★ 这是「用容器 UI 承载复杂交互」的架构选择。
--       ★ 与 CONTAINER_INSTALL_ITEM（6318）同源思路。
ACTIONS.STOPMODSLINGSHOT.fn = function(act)
	if act.doer and act.doer.components.inventory and act.invobject and act.invobject.components.slingshotmodder then
		for k in pairs(act.doer.components.inventory.opencontainers) do
			if k.prefab == "slingshotmodscontainer" and k.install_target then
				return act.invobject.components.slingshotmodder:StopModding(k.install_target, act.doer)
			end
		end
	end
	return false
end

--★ DASH.fn —— 冲刺。只做「转向」（5 行）。
--   ★★★ 6434 行 `doer:ForceFacePoint(pt)` + return true。
--     ★ 「冲刺」的移动由 SG 状态负责，动作只负责指定方向。
--       ★ 这是 T5 模板的最小形态：动作 = 设定一个状态参数。
--   ★ 6437 行的 return false 无 reason。
ACTIONS.DASH.fn = function(act)
	local pt = act:GetActionPoint()
	if pt then
		act.doer:ForceFacePoint(pt)
		return true
	end
	return false
end

--★ WHISTLE.fn —— 吹口哨召回狗。四行。
ACTIONS.WHISTLE.fn = function(act)
	if act.doer and act.doer.woby_commands_classified then
		act.doer.woby_commands_classified:RecallWoby()
		return true
	end
	return false
end

--★★★ DRAW_FROM_DECK.fn —— 抽牌（34 行），三处库存满的降级处理。
--   ★★ 6451 行的 `if not top_card_id then return false end` ——
--     ★★ 「牌堆空了」有明确处理（但无 reason）。
--   ★★ 6456-6462 行的双路径：
--     有 playingcardsmanager 组件 → 用它造牌
--     否则                     → SpawnPrefab + SetID
--     ★★ 6460 行的注释「This is a workaround if the component does not
--       exist to do what the component is doing move into a component util?」
--     ★★★★ 又一处显式的技术债标注，且作者**当场给出了建议**：
--       「这段逻辑应该挪到组件工具里去」。
--       ★ 这种「在代码里写下重构建议」的注释极其罕见，非常值得学。
--   ★★ 6465-6473 行的**三级降级**（「背包满了怎么办」）：
--     ① 先试 GiveItem（6465 行）
--     ② 失败且手上有东西 → 丢掉手上的，给 activeitem（6468-6469）
--     ③ 失败且手上没东西 → 直接掉物理在地上（6471 行）
--     ★★★ 三级降级保证「牌一定会到玩家手上/地上」，不会消失。
--       ★ 这是「永不丢物品」原则的完整实现。
--     ★ 6469 行 GiveActiveItem 会让牌在手上闪一下 ——
--       比直接掉地上更好（玩家能立刻看到抽到的牌）。
--   ★★ 6465 行**没有 nil 检查返回值**（`if not GiveItem then` 是隐式）——
--     写法正确（GiveItem 返回布尔）。
--   ★ 6475-6477 行的音效在 doer.SoundEmitter（对比 6339 行的 TheFocalPoint）。
ACTIONS.DRAW_FROM_DECK.fn = function(act)
    if act.target and act.target.components.deckcontainer then
--★★ DRAW_FROM_DECK.fn 的三级降级在 6465-6473。
--   ★★ ① 先试 GiveItem；②失败且手上有东西→丢手上的、给 activeitem；
--     ③失败且手上没东西→直接掉物理。
--   ★★★ 三级降级保证「牌一定会到玩家手上/地上」，不会消失。
--   ★★ 6456-6462 行的组件缺失兜底与 6459-6461 的 V2C 注释
--     是本文件里少见的「当场写下重构建议」的例子。
        local top_card_id = act.target.components.deckcontainer:RemoveCard()
        if not top_card_id then return false end

        local target_position = act.target:GetPosition()

--★★ DRAW_FROM_DECK.fn 的造牌与降级（6455-6477）：
--   ①6455-6462 造牌（组件 or 直接 Spawn 的双路径）
--   ②6463      SetPosition 到牌堆位置
--   ③6465      试 GiveItem
--   ④6466-6473 三级降级（见各行注释）
--   ⑤6475-6477 播 UI 音效
--   ★★★ 「造牌」的两条路径（6460 行的注释）说明了：
--     这个组件的存在只是为了「复用造牌逻辑」，
--     而它的实现本身也可以直接调用。
        local card
        if TheWorld.components.playingcardsmanager then
            card = TheWorld.components.playingcardsmanager:MakePlayingCard(top_card_id)
        else
            -- NOTES(JBK): This is a workaround if the component does not exist to do what the component is doing move into a component util?
            card = SpawnPrefab("playing_card")
            card.components.playingcard:SetID(top_card_id)
        end
        card.Transform:SetPosition(target_position:Get())

        if not act.doer.components.inventory:GiveItem(card, nil, target_position) then
--★★ 6466-6473 行 —— 「背包满了怎么办」的三级降级。
--   ★★ ②6166 取当前 activeitem → 6468 丢掉它 → 6469 给新牌
--     ★★★ 「丢掉手上的东西来腾位」—— 粗暴但有效。
--       ★ 玩家体验：手上正在用的东西突然没了。
--       ★ 换来的好处：牌一定拿得到，且能立刻看到。
--   ★★ ③6471 无 activeitem → 直接 DoDropPhysics 掉地上。
            local current_active_item = act.doer.components.inventory:GetActiveItem()
			if current_active_item then
				act.doer.components.inventory:DropItem(current_active_item, true, true, target_position)
				act.doer.components.inventory:GiveActiveItem(card)
			else
				card.components.inventoryitem:DoDropPhysics(target_position.x, target_position.y, target_position.z, true)
			end
        end

        if act.doer.SoundEmitter then
            act.doer.SoundEmitter:PlaySound("balatro/cards/pickup_UI")
        end

        return true
    end
end

--★ FLIP_DECK.fn —— 翻牌堆。音效 + PushEvent。
--   ★★ 6488 行 `act.invobject:PushEvent("flipdeck")` ——
--     ★★★ 往**物品**推事件（不是往 doer）。
--       ★ 与 TRAVEL（3699）、ACTIVATE（3097）同族：
--         「物品自己处理这件事」。
ACTIONS.FLIP_DECK.fn = function(act)
    if act.invobject and (act.invobject.components.deckcontainer or act.invobject.components.playingcard) then
        if act.doer and act.doer.SoundEmitter then
            act.doer.SoundEmitter:PlaySound("balatro/cards/pickup_UI")
        end
        act.invobject:PushEvent("flipdeck")
        return true
    end
end

--★★★【ADD_CARD_TO_DECK.fn —— 加牌（66 行），四种组合】
--   ★★ 结构：外层按「手上是牌还是牌堆」× 「目标是牌堆还是牌」二分：
--     ① 牌 → 牌堆   （加入牌堆）
--     ② 牌 → 牌     （**两张牌合并成一个牌堆**）
--     ③ 牌堆 → 牌堆（合并两个牌堆）
--     ④ 牌堆 → 牌  （加入牌底）
--   ★★★ 分支②（6505-6529）最有趣：两张单牌合并成牌堆。
--     6516-6520 行的注释解释了 why：
--       「在加入第二张牌前先翻牌堆，这样**加入顺序仍然『说得通』**。」
--       ★★★ 这是在维护「牌堆的正反面朝向」不变式 ——
--         若目标牌是正面朝上（_faceup），新牌堆也要正面朝上。
--         ★ 面朝上的牌在牌堆里是「最上面」，所以要先翻再加入。
--       ★ 6516 行读的是 `_target._faceup` —— 实例字段（服务端）。
--   ★★ 分支③（6531-6543）按「目标牌堆是否在手上」二分：
--     在地上（6532-6536）→ 自己过去合并
--     在手上（6537-6543）→ 把目标牌堆收进自己的 activeitem
--       ★★ 6538-6539 行的注释「这样我们可以继续做加牌操作」——
--         「把手上的牌堆换成合并后的」，让玩家能连续合并多副。
--   ★★★ 6549-6550 行的注释「我们要把目标加到我们的『底』位置，
--     就像刚被叠在它上面一样」—— 6546 行的注释更清楚。
--     ★ AddCard(cardid, 1) 的第二个参数 1 是「位置」，不是数量。
--     ★★★ 这个参数名极易误解（看起来像「加 1 张」）。
ACTIONS.ADD_CARD_TO_DECK.fn = function(act)
    if act.doer and act.doer.components.inventory and act.invobject and act.target then
--★★ ADD_CARD_TO_DECK.fn 的四种组合在 6494-6557。
--   ★★ ②6505-6529「两张牌合并成牌堆」最有趣：
--     6516-6520 解释了为什么要先翻牌堆 ——
--     「这样加入顺序仍然『说得通』」（维护牌堆正反面朝向不变式）。
--   ★★ ③6531-6543 按「目标牌堆是否在手上」二分，
--     6538-6539 的注释说明「把手上的牌堆换成合并后的，方便连续操作」。
--   ★★ ④6549-6551 的 AddCard(cardid, 1) 第二参是**位置**不是数量。
        if act.doer.SoundEmitter then
            act.doer.SoundEmitter:PlaySound("balatro/cards/pickup_UI")
        end
        if act.invobject.components.playingcard then
            if act.target.components.deckcontainer then
                local invobject = act.doer.components.inventory:RemoveItem(act.invobject)
                act.target.components.deckcontainer:AddCard(invobject.components.playingcard:GetID())
                invobject:Remove()

                return true
            elseif act.target.components.playingcard then
--★★ ADD_CARD_TO_DECK.fn 的四种组合（6494-6557）：
--   ①6505-6529 牌 → 牌     （**两张牌合并成牌堆**）
--   ②6530-6543 牌堆 → 牌堆 （合并两副）
--   ③6544-6555 牌堆 → 牌   （加入牌底）
--   ①6498-6504 牌 → 牌堆   （加入牌堆）—— 最短，分支③之前
--   ★★ 四分支的判定顺序 = 「手上是牌？」× 「目标是牌堆？」。
--     ★ 注意 6498 行的 if 只判 `invobject.components.playingcard`，
--       6530 行才是 deckcontainer —— 两者的 else 链是平行的。
                local is_held = act.target.components.inventoryitem:IsHeld()
                local target_card = (act.target.components.inventoryitem:IsHeld() and act.doer.components.inventory:RemoveItem(act.target))
                    or act.target

                local invobject = act.doer.components.inventory:RemoveItem(act.invobject)

                -- We're trying to merge two cards... we need to make a deck.
                local deck = SpawnPrefab("deck_of_cards")
                deck.Transform:SetPosition(target_card.Transform:GetWorldPosition())
                deck.components.deckcontainer:AddCard(target_card.components.playingcard:GetID())
                if target_card._faceup then
                    -- Flip the deck before we add the second card,
                    -- so that the add order still "makes sense".
                    deck:FlipDeck()
                end
                deck.components.deckcontainer:AddCard(invobject.components.playingcard:GetID())

                invobject:Remove()
                target_card:Remove()

                act.doer.components.inventory:GiveActiveItem(deck)

                return true
            end
        elseif act.invobject.components.deckcontainer then
--★★ ②6531-6543「牌堆 → 牌堆」的二分：
--   ★★ 6532 行 `if not IsHeld()` —— 目标牌堆在地上：
--     ★ 6533-6536 把自己挪过去合并（但 6534 行 RemoveItem 后
--       6535 行却传 act.invobject —— ★ 局部变量 invobject 被取了却没用！
--       ★★ 这是 §p4 L4 同型的可疑写法，但此处更明显：
--         6534 行 `local invobject = RemoveItem(act.invobject)`
--         6535 行 `MergeDecks(act.invobject.components.deckcontainer)`
--         ⇒ invobject 局部变量**完全未被使用**。
--       ★ 若 RemoveItem(acceptsstacks) 使两值不同，则传的是可能已失效的
--         act.invobject。
--       ★★★ 记为 L18（疑似缺陷，与 L4 同源但更可疑：
--         局部变量被显式取出却完全不使用）。
--   ★★ 6537-6543 的 else：目标在手上 → 把它收进自己的 activeitem
--     ★ 6538-6539 注释：这样可以继续做加牌操作。
            if act.target.components.deckcontainer then
                if not act.target.components.inventoryitem:IsHeld() then
                    -- If we're adding to a deck on the ground, just add ourselves to it.
                    local invobject = act.doer.components.inventory:RemoveItem(act.invobject)
                    act.target.components.deckcontainer:MergeDecks(act.invobject.components.deckcontainer)
                    return true
                else
                    -- If we're adding to a deck in our inventory, let's slurp that deck up into our active slot,
                    -- so we can keep doing add operations if we want.
                    local target = act.doer.components.inventory:RemoveItem(act.target)
                    act.invobject.components.deckcontainer:MergeDecks(target.components.deckcontainer)
                    return true
                end
            elseif act.target.components.playingcard then
                local is_held = act.target.components.inventoryitem:IsHeld()
--★★ ADD_CARD_TO_DECK 的场景④（牌堆 → 牌）6544-6555：
--   ★★ 6545-6547 又是「目标是否在手上」的二分：
--     · 在手上 → 6546 取下来当作「要加入的那张」
--     · 在地上 → 直接用它
--   ★★ 6549-6550 行的注释解释了 AddCard 的第二个参数：
--     「我们要把目标加到我们的『底』位置，就像刚被叠在它上面一样。」
--     ★★★ 「底」= 牌的堆叠顺序，与 6516-6520 的 faceup 处理配套。
--   ★★ 6551 行 `AddCard(target_card.playingcard:GetID(), 1)` ——
--     ★★★ 第二参 **1 是位置**（加到第 1 位/底部），不是「加 1 张」。
--       ★ 这个参数名极易误解为数量。属高危 API。
--   ★★ 6553 行 target_card:Remove() —— 「单牌消失了，它变成牌堆的一部分」。
--   ★★ 到此四种组合全部注释完毕。
--   ★★★ 场景①（牌→牌）6505-6529 是最复杂的：
--     需要 Spawn 一个新牌堆、把两张牌都加进去、翻面以保持朝向、
--     再把新牌堆塞到手上。
--     ★ 6516 行 `if target_card._faceup then deck:FlipDeck() end`
--       —— _faceup 是实例字段（服务端可读）。
                local target_card = (is_held and act.doer.components.inventory:RemoveItem(act.target))
                    or act.target

                -- We're a deck and our target isn't, so we want to add the target to us, but in our "bottom" position,
                -- like we were just stacked on top of it.
                act.invobject.components.deckcontainer:AddCard(target_card.components.playingcard:GetID(), 1)

                target_card:Remove()
                return true
            end
        end
    end
end

--★ POUNCECAPTURE.fn —— 扑抓。标准守卫 + Capture。
ACTIONS.POUNCECAPTURE.fn = function(act)
	local cage = act.invobject
	if cage and cage.components.gestaltcage then
        if ShouldItemMimicBeRevealedFor(cage, act.doer) then
            return false, "ITEMMIMIC"
        end

        if act.target then
			return cage.components.gestaltcage:Capture(act.target, act.doer)
        end
	end
	return false
end

--★ DIVEGRAB.fn —— 潜水抓取。与 POUNCECAPTURE 结构相同。
ACTIONS.DIVEGRAB.fn = function(act)
    local catcher = act.invobject
    if catcher and catcher.components.moonstormstaticcatcher then
        if ShouldItemMimicBeRevealedFor(catcher, act.doer) then
            return false, "ITEMMIMIC"
        end

        if act.target then
            return catcher.components.moonstormstaticcatcher:Catch(act.target, act.doer)
        end
    end
    return false
end

--★★ STARTELECTRICLINK.fn —— 「开始/结束」的切换（10 行）。
--   ★★ 6591-6595 行：
--       if IsLinking() then return EndLinking() else return StartLinking() end
--     ★★★ **一个动作同时是开始与结束**。
--       ★ 与 STOP_LIFT_DUMBBELL（5679）用两个动作的做法不同。
--       ★ 推断：电线连接是「按住拖动」型交互，中途要能反向，
--         所以用一个动作 + 状态判断比两个动作更自然。
--       ★★ 这是「状态驱动的单动作」vs「成对动作」的两种范式并存。
--   ★★ 6598 行的 return false 无 reason。
ACTIONS.STARTELECTRICLINK.fn = function(act)
    local fence = act.target
    if fence and fence.components.electricconnector then
        if fence.components.electricconnector:IsLinking() then
            return fence.components.electricconnector:EndLinking()
        else
            return fence.components.electricconnector:StartLinking()
        end
    end

    return false
end

--★ ENDELECTRICLINK.fn —— 结束连接。依赖 STARTCELECTRICLINK 的同款假设。
ACTIONS.ENDELECTRICLINK.fn = function(act)
    local fence = act.target
    if fence and fence.components.electricconnector then
        return fence.components.electricconnector:Disconnect()
    end

	return false
end

--★★ REMOVELUNARBUILDUP.fn —— 清除月雹（15 行）。
--   ★★ 6620-6621 行的保留注释「TODO: Quick hack to let Bright-beaks
--     insta-clear」+ 代码：
--       `local numworks = act.doer.clear_buildup_in_one
--         and lunarhailbuildup.totalworkamount or 1`
--     ★★★ 与 EXTRA_HEALRANGE（§p1 246 行）的 Brightshades 是同一类补丁：
--       「某个角色的半径/强度算错了，用一个字段让其在例外」。
--     ★★ `clear_buildup_in_one` 是**标签**还是字段？
--       代码用点号（doer.clear_buildup_in_one）⇒ 是**实例字段**。
--       ★ 与 Brightshades 用 prefab 特判不同。
--   ★★ 6612 行的 `not IsBuildupWorkable()` —— 「还没到能清除的程度」。
--     ★ return false 无 reason。
ACTIONS.REMOVELUNARBUILDUP.fn = function(act)
    local lunarhailbuildup = act.target and act.target.components.lunarhailbuildup or nil
    if not lunarhailbuildup or not lunarhailbuildup:IsBuildupWorkable() then
        return false
    end

    if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
        return false, "ITEMMIMIC"
    end

    -- TODO: Quick hack to let Bright-beaks insta-clear
    local numworks = act.doer.clear_buildup_in_one and lunarhailbuildup.totalworkamount or 1
    lunarhailbuildup:DoWorkToRemoveBuildup(numworks, act.doer)

    return true
end

--★★ REMOVELUNARBUILDUP.validfn —— 又一个 validfn，且**只有一个条件**。
--   ★★ 6631 行的条件与 ValidToolWork（1739）的**最后一项完全相同**：
--       `invobject == nil or doer == nil
--        or invobject.components.equippable == nil
--        or not invobject.components.equippable:IsRestricted(doer)`
--     ★★★ 同一段逻辑第三次被复制（1688/1736/6631）。
--     ★ 这已经是**明确的重复**，可以安全抽成局部函数。
--       ★ 记录为 L 类重构建议（与 1688 的双写隐患同类但更严重）。
--   ★★ 6628 行的 `act.target.components.lunarhailbuildup == nil then`
--     —— 注意 6611 行用的是 `act.target and ... or nil` 的安全写法，
--     而 validfn 里是直接访问。风格不一致。
ACTIONS.REMOVELUNARBUILDUP.validfn = function(act)
    if act.target.components.lunarhailbuildup == nil then
        return false
    end
    return (act.invobject == nil or act.doer == nil or act.invobject.components.equippable == nil or not act.invobject.components.equippable:IsRestricted(act.doer))
end

--★ SOAKIN.fn —— 泡澡。四行。
ACTIONS.SOAKIN.fn = function(act)
	if act.target and act.target.components.bathingpool then
		return act.target.components.bathingpool:EnterPool(act.doer)
	end
end

--★ HERMITCRAB_MUST_TAGS —— 「找附近的小螃蟹」用的标签表。
local HERMITCRAB_MUST_TAGS = { "hermitcrab", "character" }
--★★【TRANSFER_CRITTER.fn —— 转移宠物给螃蟹（21 行），含事务回滚】
--   ★★ 三步：
--     ① 6643-6648  找附近 10 格的小螃蟹（必须有 petleash 组件且没满）
--     ② 6650-6651  DetachPet（旧主人）+ AttachPet（螃蟹）
--     ③ 6656-6658  **失败时回滚** —— 重新 Attach 回原主人
--   ★★★ 6657 行的回滚是本文件里最完整的事务实现：
--       先摘下（不可逆操作），失败后挂回。
--       ★ 与 T11 模板（§p3 1601）的「拿 → 试 → 还回」同构。
--       ★ 但这里「还回」的载体是组件方法而非 GiveItem。
--   ★★ 6647 行 `return false--, "FULL"` ——
--     ★★★ **被注释掉的失败原因**。
--       ★ 作者知道应该返回 "FULL" 但没启用（可能因为没有对应字符串）。
--       ★ 保留注释表达了意图，是好习惯。
ACTIONS.TRANSFER_CRITTER.fn = function(act)
    if act.doer.components.petleash ~= nil and act.target.components.crittertraits ~= nil then
        local hermitcrab = FindEntity(act.doer, 10, nil, HERMITCRAB_MUST_TAGS)
        if not hermitcrab or hermitcrab.components.petleash == nil then
            return false
        elseif hermitcrab.components.petleash:IsFull() then
            return false--, "FULL"
        end

        act.doer.components.petleash:DetachPet(act.target)
        local success = hermitcrab.components.petleash:AttachPet(act.target)
        if success then
            act.target.components.crittertraits:OnPet(act.doer)
            hermitcrab:PushEvent("adopted_critter", { critter = act.target })
            return true
        else
            act.doer.components.petleash:AttachPet(act.target)
            return false
        end
    end
end

--★★ JOUST.fn —— 马上决斗（14 行）。
--   ★★ 6675 行 `return joustuser:CanJoust()` ——
--     ★★★ §p5 713 行已指出：**返回「能不能」而非「做了没有」**。
--       ★ 语义瑕疵：调用方无法知道是否真的开始了决斗。
--       ★ 与 3444 行的 RAISE_SAIL（「返回做了没有」）语义不同。
--       ★★★ **本文件里「fn 的返回值语义」并非完全统一** ——
--         有的返回 bool，有的返回 (bool, reason)，
--         有的透传组件结果，有的返回常量。
--         ★ 这是「注册式动作系统」的固有代价：
--           每个动作作者各自决定。
--       ★★ 但 BufferedAction:Do() 只看第一个返回值是否为真，
--         所以只要不返回 false 就不会有问题。
--   ★★ 6667/6671 行的两个裸 `return`（无值）—— 提前退出，隐式 nil。
ACTIONS.JOUST.fn = function(act)
    if act.doer and act.invobject then
        local joustuser = act.doer.components.joustuser
        if not joustuser then
            return
        end
        if not act.invobject.components.joustsource then
            return
        end
        if ShouldItemMimicBeRevealedFor(act.invobject, act.doer) then
            return false, "ITEMMIMIC"
        end
        return joustuser:CanJoust()
    end
end

--★ STARTREMOVINGMODULE.pre_action_cb —— 「清/设手柄状态」的第 3 例。
--   ★★ 6681 行 `doer._controller_start_moduleremover = act.invobject` ——
--     ★★★ 这里**设值**（与 5769 行的清空相对）。
--       ★ 三处 pre_action_cb 对同一字段的操作：
--         5769 APPLYMODULE       → 清空
--         6681 STARTREMOVINGMODULE → 设为当前物品
--         3332 USEITEMON          → 有 socketholder 时清空
--       ★★★ 这是一个「跨动作的手柄交互状态机」，靠 pre_action_cb 隐式维护。
--         ★ 没有集中的状态机，也没有注释说明这个字段的完整语义。
--         ★ 记为 L 类观察点（隐式状态难以追踪）。
ACTIONS.STARTREMOVINGMODULE.pre_action_cb = function(act)
	if act.invobject and act.doer and act.doer.HUD and TheInput:ControllerAttached() then
		act.doer._controller_start_moduleremover = act.invobject
	end
end

--★ STARTREMOVINGMODULE.fn —— 「开始检视模块」六行。
--   ★★ 6686 行 `local target = act.target or act.doer` ——
--     ★★★ 行尾注释「back up body or ourselves」——
--       ★ 两种场景：给自己拆 / 给备用身体拆。
--       ★ 与 §p6 6055 行的 grandowner 逻辑呼应（WX78 的核心玩法）。
ACTIONS.STARTREMOVINGMODULE.fn = function(act)
    local target = act.target or act.doer -- back up body or ourselves
	if target.components.upgrademoduleowner ~= nil then
		return target.components.upgrademoduleowner:StartInspecting(act.doer)
	end
	return false
end

--★ REMOVEMODULE.pre_action_cb —— 推「手柄移除模块」事件。
--   ★★ 6695 行 `PushEventImmediate("controller_removing_module", invobject)` ——
--     ★ 与 1721 行 DoToolWork 的 recoil 事件同款「立即事件」。
--     ★★ 这里是客户端预动作 ⇒ 事件会被传到服务端。
ACTIONS.REMOVEMODULE.pre_action_cb = function(act)
	if act.invobject and act.doer and act.doer.HUD and TheInput:ControllerAttached() then
		act.doer:PushEventImmediate("controller_removing_module", act.invobject)
	end
end

--★★★【REMOVEMODULE.fn —— 界面内拆模块（19 行），手柄分叉】
--   ★★ 6703 行的手柄分叉（与 p5 2560 行同款）：
--     手柄 ⇒ 不设 activeitem，推事件后 return true
--       ★★ 6705 行的双重条件 `if act.doer.HUD == nil then` ——
--         「服务端没有 HUD ⇒ pre_action_cb 没跑过 ⇒ 这里补一次」。
--         ★★★ 注释「already done in pre_action_cb」明确了意图。
--         ★ 这是「客户端做一半、服务端补一半」的显式协作。
--     键鼠 ⇒ 若手上的不是它，换到手上（6709-6712），return true
--   ★★ 6712 行的 `return true` 表示「只是换到手上，不算完成」。
--     ★ 与 6708 行的 return true 语义相同但触发条件不同。
ACTIONS.REMOVEMODULE.fn = function(act)
    local doer_inventory = act.doer ~= nil and act.doer.components.inventory or nil
    local moduleremover = act.invobject
    if moduleremover ~= nil and doer_inventory ~= nil then
		if act.doer.components.playercontroller and act.doer.components.playercontroller.isclientcontrollerattached then
			--don't set activeitem for controllers
			if act.doer.HUD == nil then --already done in pre_action_cb
				act.doer:PushEventImmediate("controller_removing_module", moduleremover)
			end
			return true
		elseif moduleremover ~= doer_inventory:GetActiveItem() then
            moduleremover.components.inventoryitem:RemoveFromOwner()
            doer_inventory:GiveActiveItem(moduleremover)
            return true
        end
    end

	return false
end

--★ STOPREMOVINGMODULE.fn —— 停止检视。无条件 return true。
ACTIONS.STOPREMOVINGMODULE.fn = function(act)
    local target = act.target or act.doer
	if target.components.upgrademoduleowner ~= nil then
		target.components.upgrademoduleowner:StopInspecting()
	end
	return true
end

--★★★【MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn —— 「T9 家族」的规范样本】
--   ★★ 6744-6749 行有**一整段被注释掉的距离检查**（8 行）。
--   ★★★ 注释里的代码是：
--       先取 mapent 位置，再算 `mapent:GetDroneRange(doer) + 1`
--       （注释说「Small fudge factor to avoid floating precision」），
--       然后用 math2d.DistSq 比对。
--     ★ 现在的实现改成了 FindClosestMapIconInRange(..., DETECTION_RADIUS)。
--     ★★ 保留这一段的价值：它解释了「为什么加 1 格余量」，
--       并且揭示了重构方向（从自己算距离改为复用统一查询）。
--     ★★★ 「Small fudge factor」这个注释词说明作者清楚浮点误差问题。
--   ★★ 三道权限检查（6728-6732）：
--     ① WX-78 身份          ② skilltreeupdater + wx78_scoutdrone_1 技能
--     ★★ ① 与 ② 的写法都很规范（每层都判 nil），
--       与 p6 3461 行的 DIRECTCOURIER_MAP 形成鲜明对比。
--       ★ 同一个文件里的同类函数，一个正确一个有 bug。
--   ★★ 6740 行的 FindClosestMapIconInRange 是**统一查询函数** ——
--     ★ 「在范围内找最近的地图图标」，封装了距离计算。
--       ★ 与 6888 行 SWAPBODIES_MAP 用的同一个函数。
--       ★★★ 这是本文件里少见的「已经抽取好的公共查询」。
ACTIONS.MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn = function(act)
	if not (act.doer and act.doer.wx78_classified) then
		return false
--★★ MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn 的三道权限检查在 6728-6732。
--   ★★ 每层都判 nil（与 p6 3461 行的错误写法形成对比）。
--   ★★ 6744-6749 有一整段**被注释掉的距离检查**（含浮点误差补偿说明）。
--     ★ 「Small fudge factor to avoid floating precision inaccuracies」
--     ★★★ 这段注释的价值：它解释了「为什么加 1 格余量」，
--       并揭示了重构方向（从自己算距离改为复用统一查询）。
	elseif not (act.doer.components.skilltreeupdater and act.doer.components.skilltreeupdater:IsActivated("wx78_scoutdrone_1")) then
		return false
	end

    local act_pos = act:GetActionPoint()
    if act_pos == nil then
        return false
    end

	local x, y, z = act_pos:Get()
	local mapent = FindClosestMapIconInRange("wx78_drone_scout", x, y, z, TUNING.SKILLS.WX78.MAPSCOUTSELECT_DETECTION_RADIUS, act.doer)
	if mapent == nil then
		return false, "NOTARGET"
	end
	--[[x, y, z = mapent.Transform:GetWorldPosition()
    local validdist = mapent:GetDroneRange(act.doer) + 1 -- Small fudge factor for selection to avoid floating precision inaccuracies.
    local px, py, pz = act.doer.Transform:GetWorldPosition()
    if math2d.DistSq(x, z, px, pz) > validdist * validdist then
        return false, "NOTARGET"
    end]]
	return true, nil, x, z, mapent
end

--★★ MAPSCOUTSELECT_MAP.pre_action_cb —— 「设置地图目标」（8 行）。
--   ★★ 6758 行 `mapscreen:SetNewMapTarget(mapent, ACTIONS.MAPSCOUT_MAP)` ——
--     ★★★ 把「选中的目标」与「按下时执行的动作」**一起交给地图界面**。
--       ★ 两个参数分别是 target 与 action。
--     ★ 这意味着「选择」与「执行」是分离的：pre_action_cb 只选择，
--       真正的执行由地图界面在玩家松开右键时触发（6824 行的 MAPSCOUT_MAP）。
--       ★★★ 一个完整的「拖放交互」模式：
--         按下 → pre_action_cb 选中 → 拖动 → 松开 → 执行。
--   ★ 6757 行的 TheFrontEnd:GetActiveScreen() ——
--     ★ 直接拿当前活动界面并强转类型。
--       ★ 这是一种**不加类型检查的假设**（假定地图开着）。
--       ★ 由 6754 行的 IsMapScreenOpen() 保证。
ACTIONS.MAPSCOUTSELECT_MAP.pre_action_cb = function(act)
	if act.doer.HUD and act.doer.HUD:IsMapScreenOpen() then
		local valid, reason, act_posx, act_posz, mapent = ACTIONS.MAPSCOUTSELECT_MAP.maponly_checkvalidpos_fn(act)
		if valid then
			local mapscreen = TheFrontEnd:GetActiveScreen()
			mapscreen:SetNewMapTarget(mapent, ACTIONS.MAPSCOUT_MAP)
		end
	end
end

--★ MAPSCOUTSELECT_MAP.fn —— `return true --do nothing`（3 行）。
--   ★★★ 「选择」动作的 fn 什么都不做 ——
--     全部逻辑在 pre_action_cb（选择）与 MAPSCOUT_MAP.fn（执行）。
--     ★ 这是「一个玩家意图拆成两个动作」的完整实例。
ACTIONS.MAPSCOUTSELECT_MAP.fn = function(act)
	return true --do nothing
end


--★★ MAPSCOUT_MAP.maponly_checkvalidpos_fn —— 带**距离钳制**的版本（26 行）。
--   ★★ 6773 行的 `not act.target.GetDroneRange` ——
--     ★ 目标必须实现这个方法（能力探测）。
--   ★★★ 6785-6791 行的**距离钳制**是本函数的核心：
--       dx, dz = 目标点 - 玩家
--       dist = sqrt(dx² + dz²)
--       r = math.min(dist, validdist)     -- ★ 钳制到射程内
--       ndx, ndz = 归一化方向 × r + 玩家位置   -- ★ 沿方向走 r 格
--     ★★★ 效果：「点得太远就在射程边缘那个方向上飞」。
--       ★ 这与 §p6 4017 行的 TOSS_MAP「距离夹取」是**同一手法**，
--         但实现方式不同（一个改 targetpos，一个重算落点）。
--       ★★★ 同一概念两处实现，属 L 类不一致（但两处都正确）。
--   ★★ 6788-6790 行的零距离保护：`if dist > 0 then 归一化 end`。
--     ★ 与 p6 4013 行的 `dx = 1` 是同款保护（不同实现）。
ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn = function(act)
	if not (act.doer and act.doer.wx78_classified and act.target) then
--★★ MAPSCOUT_MAP.maponly_checkvalidpos_fn 的距离钳制在 6782-6792。
--   ★★★ 核心是 6787 行的 `r = math.min(dist, validdist)` ——
--     「点得太远就在射程边缘的那个方向上飞」。
--   ★★ 与 §p6 4017 行的 TOSS_MAP「距离夹取」是同一手法，
--     但实现方式不同（一个改 targetpos，一个重算落点）。
--   ★★ 6788-6790 的零距离保护：`if dist > 0 then 归一化 end`。
		return false
	elseif not (act.doer.components.skilltreeupdater and act.doer.components.skilltreeupdater:IsActivated("wx78_scoutdrone_1")) then
		return false
    elseif not act.target.GetDroneRange then
        return false
	end

    local act_pos = act:GetActionPoint()
    if act_pos == nil then
        return false
    end

	local x, y, z = act_pos:Get()
    local x1, y1, z1 = act.doer.Transform:GetWorldPosition()
    local validdist = act.target:GetDroneRange(act.doer)
    local dx, dz = x - x1, z - z1
    local dist = math.sqrt(dx * dx + dz * dz)
    local r = math.min(dist, validdist)
    if dist > 0 then
        dx, dz = dx / dist, dz / dist
    end
    local ndx, ndz = dx * r + x1, dz * r + z1
    return true, nil, ndx, ndz, act.target
end

--★ MAPSCOUT_MAP.pre_action_cb —— 清除地图目标（一行）。
ACTIONS.MAPSCOUT_MAP.pre_action_cb = function(act)
	if act.doer.HUD and act.doer.HUD:IsMapScreenOpen() then
		local mapscreen = TheFrontEnd:GetActiveScreen()
		mapscreen:SetNewMapTarget(nil, nil)
	end
end

--★★ MAPSCOUT_MAP.fn —— 「派无人机去某点」（17 行）。
--   ★★ 6808-6811 行的**两层间接**：
--       if target:HasTag("globalmapicon") then target = target._target end
--     ★★★ 与 JUMPIN_MAP（3033）的 charlieresidue 模式完全同型。
--       ★ 「地图图标」是代理（proxy），真正的东西在 _target 上。
--   ★★ 6813 行 `mapdeliverable:Stop()` —— 先停止当前的飞行，
--     ★★ 然后 6815 行 SendToPoint 送去新位置。
--     ★ 「先停后送」避免了「无人机同时在两处」的竞态。
ACTIONS.MAPSCOUT_MAP.fn = function(act)
    local valid, reason, act_posx, act_posz, mapent = ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn(act)
    if not valid then
        return valid, reason
    end

	local target = mapent
	if target and target:HasTag("globalmapicon") then
		target = target._target
	end
	if target and target.components.mapdeliverable then
		target.components.mapdeliverable:Stop()
        local pt = Vector3(act_posx, 0, act_posz)
		return target.components.mapdeliverable:SendToPoint(pt, act.doer)
	end
	return false
end

--★★★ MAPSCOUT_MAP_TOOFAR 复用 MAPSCOUT_MAP 的校验函数（影子动作家族）。
--   ★★ 6820 行直接赋值 maponly_checkvalidpos_fn。
--   ★★ 6821-6823 行的 stroverridefn 返回固定的「太远了」串。
--   ★★ 6824-6828 行的 pre_action_cb 播否定音效。
--   ★★ 6829-6831 行的 fn `return true`。
--   ★★★★ 「太远」这个状态的完整表达 = 五个要素：
--     ① 复用同一校验（保证判定一致）
--     ② 固定文案（让玩家知道为什么）
--     ③ 否定音效（即时反馈）
--     ④ fn 返回 true（不打断流程）
--     ⑤ 独立的 action code（能被状态图/UI 区分）
--   ★★★ 这比「返回 false + reason」复杂得多，但 UX 好得多。
--   ★ 与 p7 5179 行 STOKEFIRE 的「三情况两种反馈」形成对比。
ACTIONS.MAPSCOUT_MAP_TOOFAR.maponly_checkvalidpos_fn = ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn
ACTIONS.MAPSCOUT_MAP_TOOFAR.stroverridefn = function(act)
    return STRINGS.ACTIONS.MAPSCOUT_MAP_TOOFAR
end
ACTIONS.MAPSCOUT_MAP_TOOFAR.pre_action_cb = function(act)
    if act.doer.HUD and act.doer.HUD:IsMapScreenOpen() then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_negative")
    end
end
ACTIONS.MAPSCOUT_MAP_TOOFAR.fn = function(act)
    return true
end

--★ STARTMAPDELIVER.fn —— 「开始地图投递」六行。
--   ★★ 6835 行 `IsFlyingPermittedFromPoint(...)` ——
--     ★★★ 「从这地方能不能起飞」（可能有禁飞区）。
--       ★ 返回 false 无 reason。
ACTIONS.STARTMAPDELIVER.fn = function(act)
	if act.target and act.target.components.mapdeliverable then
        if not IsFlyingPermittedFromPoint(act.target.Transform:GetWorldPosition()) then
            return false
        end
		return act.target.components.mapdeliverable:StartMapAction(act.doer)
	end
end

--★★ MAPDELIVER_MAP.maponly_checkvalidpos_fn —— 「两点之间能否飞」。
--   ★★ 6855 行用 IsFlyingPermittedFromPointToPoint（**双点**版本）。
--     ★ 与 6835 行的单点版本对照：地图上要考虑「起点与终点都要允许飞」。
--   ★★ 6862-6872 行的 fn **重复了同样的检查**（6866 行）。
--     ★★ 这是「冗余但正确的双重检查」：
--       strfn 校验一次（UI），fn 再校验一次（执行）。
--       ★ 与 DIRECTCOURIER_MAP（3508/3523）的做法一致，是**正确模式**。
--       ★★ 但这里是**手动重复**而非调用同一个函数 ——
--         两个函数体一样但没有共用。属 L 类不一致。
ACTIONS.MAPDELIVER_MAP.maponly_checkvalidpos_fn = function(act)
    local mapent = act.target
    if mapent == nil then
--★★ MAPDELIVER_MAP 的五元返回在 6842-6860。
--   ★★ 6855 行的 IsFlyingPermittedFromPointToPoint（**双点**版本）：
--     ★ 对比 6835 行的单点版本（STARTMAPDELIVER）。
--     ★★ 地图上要考虑「起点与终点都要允许飞」，世界内只要起点。
--   ★★ 6862-6872 的 fn **重复了同样的检查**（6866 行）——
--     手动重复而非调用同一函数，属 L 类不一致（但两处都正确）。
        return false
    end

    local act_pos = act:GetActionPoint()
    if act_pos == nil then
        return false
    end

    local fx, fy, fz = mapent.Transform:GetWorldPosition()
    local tx, ty, tz = act_pos:Get()
--★★ MAPDELIVER_MAP 的双点飞行许可检查在 6853-6859：
--   ★★ 6853-6854 分别取「飞行起点」（图标）与「终点」（光标）。
--   ★★ 6855 行的双点 API：两端都必须允许飞行。
--     ★★ 对比 6835 行的单点版（只要起点允许）。
--       ★ 「世界内起飞的地点」与「地图上两点的航线」是两种判定。
    if not IsFlyingPermittedFromPointToPoint(fx, fy, fz, tx, ty, tz) then
        return false
    end

	return true, nil, tx, tz, mapent
end

ACTIONS.MAPDELIVER_MAP.fn = function(act)
--★★ 6863-6872 行 —— fn 里重复了同样的检查（6866 行）。
--   ★★★ 「strfn 查一次、fn 再查一次」是**正确的双端模式**
--     （对比 6842 行的 maponly_checkvalidpos_fn 也是这样做的）。
--   ★★ 但这里**没有调用同一个函数**而是手写了一遍 ——
--     ★ 与 DIRECTCOURIER_MAP（3508/3523 调同一个函数）不同。
--     ★★ 同款逻辑两处独立实现，属 L 类不一致（风险：改一处忘另一处）。
    local pt = act:GetActionPoint()
	if pt and act.target and act.target.components.mapdeliverable then
        local fx, fy, fz = act.target.Transform:GetWorldPosition()
        if not IsFlyingPermittedFromPointToPoint(fx, fy, fz, pt.x, pt.y, pt.z) then
            return false
        end
		return act.target.components.mapdeliverable:SendToPoint(pt, act.doer)
    end
	return false
end

--★★★【SWAPBODIES_MAP.maponly_checkvalidpos_fn —— 地图换身的 28 行】
--   ★★ 6875-6880 行的三道权限检查（WX78 身份 + 技能激活），写法规范。
--   ★★ 6893 行的保留注释解释了一个重要机制：
--     「WX-78 同时存在于两处，所以『换身』不是传送而是『换身』，
--       但它被 Wagstaff 的屏障挡住以阻止信号。」
--   ★★★ 「阻止信号」—— 这是叙事设定驱动的**技术限制**。
--     ★ 具体实现（6896-6899）：若屏障竖起且两点分处屏障两侧则拒绝。
--     ★★ 这个检查必须在**地图层**做（因为玩家看不见屏障边界）。
--   ★ 6888 行复用 FindClosestMapIconInRange（同 6740 行）。
ACTIONS.SWAPBODIES_MAP.maponly_checkvalidpos_fn = function(act)
    if act.doer == nil or not act.doer.wx78_classified then
        return false
--★★ SWAPBODIES_MAP 的地图层屏障检查在 6893-6900。
--   ★★ 6893 行的保留注释解释了一个叙事驱动的技术限制：
--     「WX-78 同时存在于两处，所以『换身』不是传送，
--       但它被 Wagstaff 的屏障挡住以阻止信号。」
--   ★★ 6896-6899 的实现：若屏障竖起且两点分处屏障两侧则拒绝。
--     ★ 这个检查必须在**地图层**做（玩家看不见屏障边界）。
    end
    if act.doer.components.skilltreeupdater == nil or not act.doer.components.skilltreeupdater:IsActivated("wx78_remotebodyswap") then
        return false
    end

    local act_pos = act:GetActionPoint()
    if act_pos == nil then
        return false
    end

    local x, y, z = act_pos:Get()
--★★ SWAPBODIES_MAP.maponly_checkvalidpos_fn 的五道检查（6875-6901）：
--   ①6875-6876 doer 存在且是 WX-78
--   ②6878-6879 skilltreeupdater + wx78_remotebodyswap 技能
--   ③6882-6885 act_pos 存在
--   ④6888-6891 FindClosestMapIconInRange 找到备用身体，否则 NOTARGET
--   ⑤6893-6900 **WagPunk 竞技场屏障检查**
--   ★★★ ⑤是本函数最独特的一步，且必须在地图层做。
	local mapent = FindClosestMapIconInRange("wx78_backupbody", x, y, z, TUNING.SKILLS.WX78.REMOTEBODYSWAP_DETECTION_RADIUS, act.doer)
	if mapent == nil then
        return false, "NOTARGET"
    end
	x, y, z = mapent.Transform:GetWorldPosition()
    -- NOTES(JBK): WX-78 exists in both places at once so swapping bodies is WX-78 not teleporting but it is blocked by Wagstaff's barrier to stop the signal.
    local px, py, pz = act.doer.Transform:GetWorldPosition()
    local map = TheWorld.Map
--★★ 6896-6900 行 —— 「竞技场屏障」的几何判定：
--   ★★ `map:IsPointInWagPunkArena(px,py,pz) ~= map:IsPointInWagPunkArena(x,y,z)`
--     ★★★ 「两点分处屏障两侧」⇒ 拒绝。
--       ★ 这是一个纯几何判定，与叙事设定（Wagstaff 的信号屏障）绑定。
--       ★★ 若 mod 改动了 arena 的形状，这里必须同步。
    if map:IsWagPunkArenaBarrierUp() then
        if map:IsPointInWagPunkArena(px, py, pz) ~= map:IsPointInWagPunkArena(x, y, z) then
            return false, "NOTARGET"
        end
    end
	return true, nil, x, z, mapent
end

--★ SWAPBODIES_MAP.fn —— 「换身」的执行（22 行）。
--   ★★ 6914-6915 行的四重 nil 检查 + NOTARGET 原因：
--       `not mapent or not mapent._target or not mapent._target:IsValid()`
--         `or not mapent._target.components.activatable`
--     ★★★ 逐层剥开「代理 → 真实实体 → 组件」。
--     ★ 与 MAPSCOUT_MAP（6809）的 `_target` 解包同族。
--   ★★ 6918-6923 行的 CanActivate/DoActivate 与 ACTIVATE.fn（3086）
--     **完全同型**（包括「nil 算成功」的注释）。
--     ★★ 第三次出现「(success ~= false) -- note: for legacy reasons,
--       nil will be true」这个模式（3086/6918 两处）。
--       ★ 同一注释被复制到两处。属 L 类不一致风险。
ACTIONS.SWAPBODIES_MAP.fn = function(act)
    if not act.doer.wx78_classified then
        return false
    end

    local valid, reason, act_posx, act_posz, mapent = ACTIONS.SWAPBODIES_MAP.maponly_checkvalidpos_fn(act)
    if not valid then
        return valid, reason
    end

    if not mapent or not mapent._target or not mapent._target:IsValid() or not mapent._target.components.activatable then
        return false, "NOTARGET"
    end

    local success, msg = mapent._target.components.activatable:CanActivate(act.doer)
    if success == false then
        return false, msg
    else
        success, msg = mapent._target.components.activatable:DoActivate(act.doer)
        return (success ~= false), msg -- note: for legacy reasons, nil will be true
    end
end

--★★ TOGGLEWXSCREECH/TOGGLEWXSHIELDING —— 「开关型动作」的最简实现。
--   ★★ 两个动作的完整内容：
--       strfn: 有 wx_screeching 标签 → "TURNOFF"
--       fn:    return true
--   ★★★ 「开关」不需要 fn 做任何事 —— 因为**动作本身被按下**
--     就是「切换」的信号，真正的状态切换在状态图里。
--   ★★★ 这是本文件里最纯粹的「动作即信号」形态：
--     连 fn 都不需要做任何判断。
--     ★★ 对比 CLIMB/JUMPIN（还要检查状态），
--       这两个连状态都不检查 —— 因为「开」和「关」由 sg 的状态区分。
ACTIONS.TOGGLEWXSCREECH.strfn = function(act)
    return (act.doer and act.doer:HasTag("wx_screeching")) and "TURNOFF"
        or nil
end

ACTIONS.TOGGLEWXSCREECH.fn = function(act)
	return true
end

ACTIONS.TOGGLEWXSHIELDING.strfn = function(act)
    return (act.doer and act.doer:HasTag("wx_shielding")) and "TURNOFF"
        or nil
end

ACTIONS.TOGGLEWXSHIELDING.fn = function(act)
	return true
end

--★★ 保留的英文注释解释 EQUIPONBODY 的存在理由与扩展可能：
--   「For possessed bodies, but maybe we can expand to other ents
--     in the future?」
--   ★★ 疑问句形式的注释 —— 作者自己也不确定这个机制能否泛化。
-- For possessed bodies, but maybe we can expand to other ents in the future?
--★★【EQUIPONBODY.fn —— 给被附身身体装备（17 行）】
--   ★★ 6952 行的条件：
--       `(target.inventory:IsOpenedBy(act.target) or HasTag("playerghost"))`
--     ★★★ 注意是 `IsOpenedBy(**act.target**)` ——
--       「被附身的身体**自己**的背包是否开着」。
--       ★ 与 GIVETOPLAYER.fn（2348）的 `IsOpenedBy(act.target)` 相同写法。
--     ★★ 两个动作都用同一判据 ⇒ 被附身的身体在两种场景下表现一致。
--   ★★ 6957 行的处理是 **DropItem** 而非 Unequip：
--       `inventory:DropItem(current)` —— 直接扔到地上。
--     ★★ 对比 PICKUP.fn（938）在类似情况用 DropItem(equip)，一致。
--       ★ 但 UNEQUIP.fn（872）在同类情况下优先 GiveItem。
--       ★★★ 三处「替换装备」的处理各不相同：
--         · PICKUP   → 旧装备进背包，新装备直接穿（932-941）
--         · UNEQUIP  → 优先进背包，装不下就丢（872-876）
--         · EQUIPONBODY → **直接丢**（6957）
--       ★ EQUIPONBODY 的最简策略是可疑的：
--         玩家的旧装备（帽子、护甲）会直接掉在地上。
--         ★ 「给别人的身体换装备会丢东西」——
--           ★★ 这可能是**真实的物品损失问题**。
--         ★ 但也可能玩家预期就是如此（不想让别人的东西进自己包）。
--         ★ 归类为 L 类可疑点（需要玩家反馈确认）。
ACTIONS.EQUIPONBODY.fn = function(act)
    if act.target ~= nil and
            act.target.components.inventory ~= nil and
            act.invobject ~= nil and
            act.invobject.components.equippable ~= nil and
            not act.invobject.components.equippable:IsRestricted(act.target) and
            (act.target.components.inventory:IsOpenedBy(act.target) or act.target:HasTag("playerghost")) then

        local equipslot = act.invobject.components.equippable.equipslot
        local current = act.target.components.inventory:GetEquippedItem(equipslot)
        if current ~= nil then
            act.target.components.inventory:DropItem(current)
        end
        act.target.components.inventory:Equip(act.invobject)
        return true
    end
end

--★ CLIMB.strfn —— 与 JUMPIN.strfn（2965）完全相同的一行。
--   ★★ 两处重复的一行代码。属 L 类轻微重复。
ACTIONS.CLIMB.strfn = function(act)
    return act.doer ~= nil and act.doer:HasTag("playerghost") and "HAUNT" or nil
end

--★ CLIMB.fn —— 与 JUMPIN.fn（2969）完全同型（climb_pre → climb）。
--   ★★ 6978 行的 GoToState("idle") 兜底同 2979 行。
ACTIONS.CLIMB.fn = function(act)
    if act.doer ~= nil and
        act.doer.sg ~= nil and
        act.doer.sg.currentstate.name == "climb_pre" then
        if act.target ~= nil and
            act.target.components.teleporter ~= nil and
            act.target.components.teleporter:IsActive() then
            act.doer.sg:GoToState("climb", { teleporter = act.target })
            return true
        end
        act.doer.sg:GoToState("idle")
    end
end

--★ STARTVAULTORBTELEPORT.fn —— 「开始金库球传送」五行。
ACTIONS.STARTVAULTORBTELEPORT.fn = function(act)
    if act.invobject and act.invobject.components.vaultorbteleporter then
        return act.invobject.components.vaultorbteleporter:StartMapAction(act.doer)
    end
end

--★ MAP_VAULTORB_MUST —— 三个标签的 must 表（CLASSIFIED + 两种图标）。
local MAP_VAULTORB_MUST = { "CLASSIFIED", "globalmapicon", "vaultorbteleportdestinationtrackericon" }
--★★★【VAULTORBTELEPORT_MAP.maponly_checkvalidpos_fn —— 26 行】
--   ★★ 7001 行 `FindEntities(...)[1]` —— 直接取第一个，
--     ★★ **不做距离比较**！
--       ★ 对比 6740/6888 行用的是 FindClosestMapIconInRange（会找最近的）。
--       ★★★ 语义差异：这里是「范围内任一图标」
--         （FindEntities 的返回顺序由引擎决定，通常不稳定），
--         而别处是「最近的那个图标」。
--       ★ 「取第一个」可能选到非预期的目标。
--       ★ 记录为 L 类不一致（但功能上仍能工作）。
--   ★★ 7009 行 `IsTeleportingPermittedFromPointToPoint` ——
--     7009 行是本文件里**第三个**传送许可 API（前两个是飞行许可）。
--     ★ 命名区分：FlyingPermitted（无人机）vs Teleporting（玩家传送）。
--       ★ 三者都是「区域限制」的判定，被放在 world/map 相关文件里。
ACTIONS.VAULTORBTELEPORT_MAP.maponly_checkvalidpos_fn = function(act)
    local target = act.target or act.invobject
    if act.doer == nil or target == nil then
--★★ VAULTORBTELEPORT_MAP.maponly_checkvalidpos_fn 在 6989-7014。
--   ★★ 7001 行 `FindEntities(...)[1]` —— **不做距离比较**！
--     ★★★ 对比 6740/6888 行的 FindClosestMapIconInRange（找最近的）。
--       「取第一个」的顺序由引擎决定，可能选到非预期目标。
--       ★ 属 L 类不一致（但功能上仍能工作）。
--   ★★ 7009 行的 IsTeleportingPermittedFromPointToPoint 是
--     本文件里**第三个**传送许可 API（前两个是飞行许可）。
        return false
    end

    local act_pos = act:GetActionPoint()
    if act_pos == nil then
        return false
    end

    local x, y, z = act_pos:Get()
    local mapent = TheSim:FindEntities(x, y, z, TUNING.VAULT_ORB_REFINED_DETECTION_RADIUS, MAP_VAULTORB_MUST)[1]
    if mapent == nil then
        return false, "NOTARGET"
    end

    x, y, z = mapent.Transform:GetWorldPosition()
    local px, py, pz = act.doer.Transform:GetWorldPosition()

    if not IsTeleportingPermittedFromPointToPoint(px, py, pz, x, y, z) then
        return false
    end

    return true, nil, x, z, mapent
end

--★★ VAULTORBTELEPORT_MAP.fn —— 32 行，五重 nil 检查。
--   ★★ 7022-7029 行的双重来源 + 双重组件检查：
--       item = act.invobject or act.target
--       if not item or not item.components.inventoryitem then return false, "NOTARGET"
--       if item.components.vaultorbteleporter == nil then return false, "NOTARGET"
--     ★★ **两处不同的检查都返回同一个 NOTARGET** ——
--       ★ 玩家无法区分「没拿到球」与「球不支持传送」。
--       ★ 属 L 类反馈不足。
--   ★★ 7031-7033 行的第三次检查：地图图标的目标无效。
--   ★ 7035 行 `Activate(doer, mapent._target)` —— 透传组件结果。
ACTIONS.VAULTORBTELEPORT_MAP.fn = function(act)
    local valid, reason, act_posx, act_posz, mapent = ACTIONS.VAULTORBTELEPORT_MAP.maponly_checkvalidpos_fn(act)
    if not valid then
        return valid, reason
    end

    local item = act.invobject or act.target
    if not item or not item.components.inventoryitem then
        return false, "NOTARGET"
    end

    if item.components.vaultorbteleporter == nil then
        return false, "NOTARGET"
    end

    if not mapent or not mapent._target or not mapent._target:IsValid() then
        return false, "NOTARGET"
    end

    return item.components.vaultorbteleporter:Activate(act.doer, mapent._target)
end

--★ GOLF_START_AIMING.pre_action_cb —— 关法术轮盘（STEER_BOAT 同款）。
--   ★★ 四个 pre_action_cb 关法术轮盘（4903/5049/5964/7038）——
--     ★★★ 「持球类/引导类动作都要先关轮盘」是一条隐式约定，
--       但没有统一实现（4 处重复的三行代码）。
--       ★ 记为 L 类重构建议。
ACTIONS.GOLF_START_AIMING.pre_action_cb = function(act)
	if act.doer.HUD then
		act.doer.HUD:CloseSpellWheel()
	end
end

--★ GOLF_START_AIMING.fn —— 高尔夫瞄准的六条件准入。
--   ★★ 7045-7047 行的三重身份确认：
--       有 golfclub 组件 + equippable:IsEquipped() + inventoryitem:IsHeldBy(doer)
--     ★★★ 三个「持有」相关的检查全做了一遍。
--       ★ 必要性：防止用「别人装备的球杆」瞄准。
ACTIONS.GOLF_START_AIMING.fn = function(act)
	if act.invobject and act.invobject.components.golfclub and
		act.invobject.components.equippable and act.invobject.components.equippable:IsEquipped() and
		act.invobject.components.inventoryitem and act.invobject.components.inventoryitem:IsHeldBy(act.doer)
	then
		return act.invobject.components.golfclub:StartAiming(act.doer, act.target)
	end
	return false
end

--★ GOLF_STOP_AIMING.fn —— 停止瞄准（从手部取球杆）。
ACTIONS.GOLF_STOP_AIMING.fn = function(act)
	local club = act.doer.components.inventory and act.doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if club and club.components.golfclub then
		club.components.golfclub:StopAiming()
	end
	return true
end

--★★★【GOLF_START_CHARGING.pre_action_cb —— 「双端分别做不同事」的范例（17 行）】
--   ★★ 7068 行的注释「server and predicted clients」与
--     7073 行的「server and local clients」——
--     ★★★ 作者显式标注了两段代码各自的运行环境：
--       ① 7069-7072 服务端与预测客户端：设置 Transform 的朝向
--       ② 7074-7077 服务端与本地客户端：启动准星（reticule）
--     ★★ 为什么分成两个条件块？
--       · 7071 行的 SetRotation 是**状态同步**的（客户端要预测）
--       · 7075 行的 StartCharging 是**纯视觉**的（只需本地）
--       ★★★ 这解释了 DST 的「预测客户端」概念：
--         拥有该玩家控制权的客户端会预测动作，服务端验证。
--         ★ 这些概念在本文件里只在此处显式出现。
--   ★★ 7070-7071 行的三元：
--       `club.components.golfclub and golfclub:GetTarget() or doer`
--     ★ 目标为空时朝自己转（因为 `(target or doer):GetAngleToPoint(pt)`）。
--       ★ 写法紧凑。
--   ★★ 7074 行的 `doer.components.playercontroller and golfclub_reticule`
--     —— 检查**客户端组件**（playercontroller 只在客户端存在）。
--       ★★ 于是这一段天然只在客户端执行（服务端没有 playercontroller）。
--         ★ 与 6332 行（用 HUD 隐式过滤）不同，这里是**显式**的。
ACTIONS.GOLF_START_CHARGING.pre_action_cb = function(act)
	local pt = act:GetActionPoint()
	if pt then
		local inventory = act.doer.replica.inventory
		local club = inventory and inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
		if club then
			--server and predicted clients
			if act.doer.components.locomotor then
				local target = club.components.golfclub and club.components.golfclub:GetTarget()
				act.doer.Transform:SetRotation((target or act.doer):GetAngleToPoint(pt))
			end
			--server and local clients
			if act.doer.components.playercontroller and club.components.golfclub_reticule then
				club.components.golfclub_reticule:StartCharging(act.doer, pt)
			end
		end
	end
end

--★ GOLF_START_CHARGING.fn —— `return true`（一行，无操作）。
--   ★★ 蓄力的全部工作在 pre_action_cb（转向 + 准星）与状态图里。
--     ★ 又一个「动作为信号」的例子。
ACTIONS.GOLF_START_CHARGING.fn = function(act)
	return true
end


--★★【TERRAFORM_REMOVE.fn —— 移除地形（7 行，全文件最后一个 fn）】
--   ★★ 7088 行的两个否定条件：
--       `invobject.components.terraformer and
--        not invobject.components.terraformer.plow
--        and act.target.components.terraformerremoveable`
--     ★★★ `not ...terraformer.plow` ——
--       「**排除**犁」。
--       ★★★ 同一个 terraformer 组件有两种工具形态（犁 / 普通工具），
--         移除动作只允许后者。
--       ★ 与 4633 行 DM 掉落、1319 行 PLAY 是同类「按子类型分支」。
--       ★★ 这种「一个组件 + 一个布尔字段区分变体」的设计在本文件里很常见，
--         好处是组件复用，代价是必须处处记得检查那个字段。
--   ★★ 7089 行的 TryToRemove —— 注意是「尝试」（Try 前缀）
--     ★ 返回值直接透传。
ACTIONS.TERRAFORM_REMOVE.fn = function(act)
    if act.invobject and act.target then
        if act.invobject.components.terraformer and not act.invobject.components.terraformer.plow and act.target.components.terraformerremoveable then
            return act.target.components.terraformerremoveable:TryToRemove(act.doer)
        end
--★ 到此 actions.lua 全文结束（7092 行源文件，7093 行含末尾换行）。
--★★ 全文件结构回顾：
--  §零   8-291     范围/距离函数族（14 个）—— 「够不够近」的所有算法
--  §一   294-351   Action 基类（40 个字段）
--  §二   357-741   ACTIONS 表（约 240 个动作原型声明）
--  §三   743-764   编号与网络映射
--  §四   768-7092  动作实现（约 350 个 fn/strfn/stroverridefn/validfn）
--
--★★★ 最后三条总结（读完整个文件后最该记住的）：
--  1. ★★ **Action 是数据，fn 是行为，condition 在别的文件**。
--     把本文件当成「动作注册表」是误解；它只是「动作的行为库」。
--     「能不能做」的判定全部在 componentactions.lua:3181 CollectActions。
--  2. ★★ 「静默失败」是本文件的**第一设计模式**（至少 15 处）。
--     条件不满足时宁可 return true 也不报错 —— 因为动作要经过
--     「走过去 + 播动画」的异步过程，途中条件必然可能失效。
--     ★★ 这是 DST 动作系统与「即时判定」引擎最大的差异。
--  3. ★★ 「同构模板」是本文件的**节省手段也是理解障碍**。
--     350 个 fn 里约 300 个是 §0 定义的 T1~T12 十二种形状之一。
--     ★ 读懂 12 个模板 = 读懂 90% 的文件；
--       剩下 10% 才是真正需要逐行读的部分（COOK/PICKUP/STORE/RUMMAGE/
--       DoToolWork/FEED/MURDER/BLINK_MAP 的 remap/TRANSFER_CRITTER 等）。
--
--【⚠ 疑似缺陷总清单（18 条，完整版见文件头 §0）】
--  严重（可导致崩溃或物品损失）：
--    L1  3461   DIRECTCOURIER_MAP 优先级 bug → 非沃尔特玩家必然崩溃
--    L2  2789   CHANGEIN and/or 优先级 → target 为 nil 时崩溃
--    L3  1146   RUMMAGE.strfn → mount 为 nil 时崩溃
--    L12 4805   BATHBOMB 链式调用 → RemoveItem 返回 nil 时崩溃
--    L16 5612   YOTB_UNLOCKSKIN → 已解锁也消耗道具（物品损失）
--  中等（行为异常但不易触发）：
--    L6  2747   HITCH.fn 无返回值 → 报告失败（有副作用）
--    L9  1730   DoToolWork 的 false 无 reason → 「砍不动」报成功
--    L10 6284   WOBY_PICK.validfn 语义与注释完全相反
--    L14 3299/3374 USEITEM 的 IsOpenedBy(doer) 恒假
--    L15 4335   BUNDLE 的 CanEntitySeeTarget(doer,doer) 恒真
--    L17 5679   STOP_LIFT_DUMBBELL 无返回值
--    L18 6534   ADD_CARD_TO_DECK 取出的 invobject 未使用
--  轻微（风格/一致性/重构建议）：
--    L4  1475   CHANGE_TACKLE 传 act.invobject（依赖前置不变量）
--    L5  1871   NET.fn 无条件 return true
--    L7  3887   CATPLAYGROUND 的 end 缩进错位
--    L8  57     PhysicsPaddedRangeCheck 死代码（作者已标注）
--    L11 2189   注释掉的 print 遗留
--    L13 758    IsItemInReadOnlyContainer 未使用且为 local
--  ★ 另有两类未编号的系统性问题（完整清单见文件头）：
--    · 隐式协议：action.code 由字母序决定 ⇒ 插入新动作会整体偏移 code。
--    · 大面积重复：判定表达式（海洋瓦片×5 / restricted×3 / ValidToolWork 双写）、
--      事务模板（Remove→试→还回 出现在 10+ 处）、以及 REPLATE /
--      DECORATESNOWMAN / CHANGE_TACKLE 内部的未抽取重复。
    end
end
