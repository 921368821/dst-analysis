--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/hermitcrabbrain.lua
-- 模块：AI 大脑 / 蟹壳怪（Hermit Crab，全 DST 最复杂的社交型 NPC）
-- 职责：装配蟹壳怪 AI。★ 与其他大脑不同，它的独特之处在【社交层】：
--       好感度驱动三档态度、台词按好感度二级选择、用「定时器名拼玩家 GUID」
--       实现「对每个玩家分别记忆今天是否已打招呼」、茶会的选摊与级联清理、
--       钓鱼时按鱼群密度择优、泡温泉/钓鱼/采收/扔瓶子等日常活动，
--       以及雨天穿伞雪天穿外套这类「成对状态维护节点」。
--       按 SOP 对 796 行的大文件只精读并注释核心决策函数（覆盖主干）。
--
-- 【★ 三级优先级结构（与 pigbrain 同款但多一层「不友好」层）】
--   root（第 753 行）→ 跨人格节点（瞬移收尾/泡温泉/恐慌/躲猪/换装备/扔物/说完话）
--     → day（第 681 行，含第 683 行的不友好子层）
--     → night（第 743 行）
--   day 与 night 的条件严格互补，且都考虑 AllNightTest（蟹壳怪可通宵营业）。
--
-- ⚠️ 已核实的遗留问题：第 533 行 CHATTERPARAMS_HIGH 定义后全文件未使用。
-- 关键符号：HermitBrain, getfriendlevelspeech（好感度台词 ★）, GetFaceTargetFn,
--           GetTraderFn, SelectTeaShop / ValidateTeaShops（茶摊集合管理）,
--           DoFishingAction（按鱼群密度择优）, CanWanderAtPoint（夜光约束）,
--           DoSoakin, DoHarvestMeat, GetFoodForCritter, RemoveActiveTeaShop,
--           holding_umbrella / equipped_umbrella / has_umbrella（三态查询）
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（恐慌与帮工底座）,
--           behaviours/{wander,follow,faceentity,chaseandattack,runaway,
--           doaction,findlight,panic,chattynode,leash}.lua,
--           components/{trader,inventory,friendlevels,npc_talker,locomotor,
--           homeseeker,eater,petleash,knownlocations,timer}.lua,
--           strings.lua（HERMITCRAB_GREETING / LEVEL10_* 等台词表）, tuning.lua
--============================================================
require "behaviours/wander"
--[ [
-- hermitcrabbrain.lua —— 蟹壳怪（Hermit Crab）大脑
--
-- 【★ 定位：全DST 最复杂的「社交型 NPC」大脑】
--   其他大脑的战斗/生存/生产三件套，这里全有；
--   但真正让它不同的是【社交层】：
--     · 好感度（friendlevels.level）驱动三档态度（第 201 行）
--     · 按好感度选择台词组（第 207-247 行，六选一）
--     · 称呼玩家的敬语随好感度变化（"hermit_grannied" + 玩家 GUID 定时器）
--     · 茶会：多个茶摊间选一个（第 584-607 行）
--     · 钓鱼 / 采浆果 / 收肉 / 扔瓶子 / 泡温泉 / 喂宠物 等日常行为
--   ★★ 移植价值：这是「NPC 性格系统」最完整的参考实现。
--
-- 【★ 三级优先级结构（与 pigbrain 同款但多一层）】
--   root（第 753 行）
--     ├─ 各种跨人格节点（第 756-787 行）：瞬移收尾、泡温泉续场、恐慌、
--     │   躲猪、雨天穿伞/雪天穿外套、扔东西、说完话
--     ├─ day（第 681 行）—— 白天，含「不友好/友好」两种子态度（第 683 行）
--     └─ night（第 743 行）—— 夜晚
--   ★ 「不友好」那一层（第 683-740 行）是本文件的独有结构：
--     玩家好感不够时，蟹壳怪会【无视玩家】（跑开、不交易、不聊天），
--     直到好感够了才进入「friendly」分支。
--
-- 【⚠️ 容易踩的坑】
-- · 第 58 行 has_umbrella 用局部变量 ret 接收 HasItemWithTag 的【第一个】返回值，
--   源码自己用长注释形式标出了被忽略的第二个返回值（数量）。
--   ★ 这是合法的 Lua，但本项目的注释文本里不能出现该序列（本行已用文字描述）。
-- · 第 747 行与 pigbrain 第 366 行逐字相同的 or 写法（见 pigbrain 的注释）。
-- · 第 534 行 chattyparams 的 echotochatpriority = CHATPRIORITIES.HIGH，
--   但本文件里【没有】任何节点用 CHATTERPARAMS_HIGH（第 533 行定义后未使用）。
--   ⚠️ 已逐字核实：CHATTERPARAMS_HIGH 只在第 533-535 行出现，无使用者。
--     属真实的死代码/遗留定义。已在下方锚点标注。
--] ]
require "behaviours/follow"
require "behaviours/faceentity"
require "behaviours/chaseandattack"
require "behaviours/runaway"
require "behaviours/doaction"
require "behaviours/findlight"
require "behaviours/panic"
require "behaviours/chattynode"
require "behaviours/leash"

local BrainCommon = require "brains/braincommon"

local MAX_WANDER_DIST = 40

local START_RUN_DIST = 3
local STOP_RUN_DIST = 5
local MAX_CHASE_TIME = 10
local MAX_CHASE_DIST = 30
local SEE_LIGHT_DIST = 20
local TRADE_DIST = 20
local SEE_TREE_DIST = 15
local SEE_TARGET_DIST = 20
local SEE_FOOD_DIST = 10

local SEE_BURNING_HOME_DIST_SQ = 20*20

local COMFORT_LIGHT_LEVEL = 0.3

local KEEP_CHOPPING_DIST = 10

local RUN_AWAY_DIST = 5
local STOP_RUN_AWAY_DIST = 8

local START_FACE_DIST = 4
local KEEP_FACE_DIST = 6

local function getstring(inst, stringdata)
    if stringdata["LOW"] then
        local gfl = inst.getgeneralfriendlevel(inst)
        return stringdata[gfl][math.random(1,#stringdata[gfl])]
    else
        return stringdata[math.random(1,#stringdata)]
    end
end

-- UMBRELLA
local function holding_umbrella(inst) --hand slot specifically
-- ★★ 伞的三个查询函数（区分「手持/装备中/背包里」）：
--   第 48 行 holding_umbrella  —— 手持槽（HANDS）
--   第 53 行 equipped_umbrella —— 任何装备槽
--   第 57 行 has_umbrella      —— 背包里有
--   ★★★ 三级区分不是冗余，而是对应三个不同的行为决策：
--     第 777 行：下雨 且【背包里有】 且【没装备上】→ 去装备
--     第 379 行 DoFishingAction：★【手持伞】时【不】钓鱼（要腾手）
--     第 441 行 DoBottleToss：★【手持伞】时【不】扔瓶子
--   ★★ 即「手持伞会阻止其他动作」，这是状态互斥的实现方式。
--   ★ 移植价值：用一个装备槽作为「忙」的标志，隐式排斥其他动作。
	local tool = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	return tool ~= nil and tool:HasTag("umbrella")
end

local function equipped_umbrella(inst) --any slot
	return inst.components.inventory:EquipHasTag("umbrella")
end

local function has_umbrella(inst)
	local ret--[[, num]] = inst.components.inventory:HasItemWithTag("umbrella", 1)
-- ★ has_umbrella 只取 HasItemWithTag 的【第一个】返回值（是否存在）。
--   ★ 源码自己用长注释标出了被忽略的第二个返回值（数量），
--     说明作者清楚语义但只需布尔值。
--   ★ 局部变量 ret 的写法（多写一行）是为了可读性，可直接 return。
--   ⚠️ 注意本行【不在条件表达式里】，若返回多个值会全部返回给调用方。
--     但这里先赋给 ret 再 return ret（单值），行为正确。
	return ret
end

local function item_is_umbrella(item)
-- item_is_umbrella：传给 FindItem 的谓词（找伞用）。
	return item:HasTag("umbrella")
end

local function EquipUmbrella(inst)
-- ★ EquipUmbrella：找伞并装备。
--   第 69 行 Equip(umbrella) —— 装备动作由 inventory 处理。
--   ★ 与第 99 行 EquipCoat 同款结构。
	local umbrella = inst.components.inventory:FindItem(item_is_umbrella)
    if umbrella then
        inst.components.inventory:Equip(umbrella)
    end
end

local function try_unequip_umbrella(item, inst)
-- ★ try_unequip_umbrella：★ 参数顺序反直觉。
--   ForEachEquipment 的回调签名是 (item, inst)，
--   所以第 75 行的 inst 其实是第二个参数。
--   ★★★ 移植提示：读 Lua 回调时先确认回调签名，别被参数名误导。
	if item:HasTag("umbrella") then
		item = inst.components.inventory:Unequip(item.components.equippable.equipslot)
		inst.components.inventory:GiveItem(item)
	end
end

local function UnEquipUmbrella(inst)
-- ★ UnEquipUmbrella：遍历所有装备槽卸下伞。
--   第 81 行 ForEachEquipment(try_unequip_umbrella, inst) —— 传入额外参数。
--   ★ 与第 106 行 UnEquipBody 的直接 Unequip(EQUIPSLOTS.BODY) 写法不同，
--     因为伞可能在【任意】槽位，而大衣只在 BODY 槽。
--   ★★★ 这是「按物品特性选择卸下方式」的准确处理。
	inst.components.inventory:ForEachEquipment(try_unequip_umbrella, inst)
end

-- COAT
local function using_coat(inst)
-- ★ using_coat：是否穿着大衣。返回值是 equipped（物品）或 nil，
--   ★ 注意它返回的是【物品本身】而非布尔 —— 但用作条件时等价。
--   ⚠️ 与第 90 行 has_coat 返回【物品】、第 94 行 getcoat 返回【物品】一致，
--     三个函数都返回物品。统一风格，不是缺陷。
    local equipped = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
    return equipped and inst.iscoat(equipped) or nil
end

local function has_coat(inst)
    return inst.components.inventory:FindItem(function(testitem) return inst.iscoat(testitem) end)
end

local function getcoat(inst)
-- ★★ getcoat 的「or 降级链」：
--   先在背包里找（FindItem），找不到才看身上穿的。
--   ★★★ 这个顺序有实际意义：
--     若背包里有新大衣，优先装备新的而不是身上旧的。
--   ★ 移植提示：「找背包 or 用现有的」是常见的物品选择模式。
    local bodyequipped = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY)
    return inst.components.inventory:FindItem(function(testitem) return inst.iscoat(testitem) end) or (bodyequipped and  inst.iscoat(bodyequipped) and bodyequipped )
end

local function EquipCoat(inst)
    local coat = getcoat(inst)
    if coat then
        inst.components.inventory:Equip(coat)
    end
end

local function UnEquipBody(inst)
    local item = inst.components.inventory:Unequip(EQUIPSLOTS.BODY)
    inst.components.inventory:GiveItem(item)
end

local function ShouldRunAway(inst, target)
-- ShouldRunAway：与 pigbrain 第 41 行逐字相同（正在交易就不跑）。
    return not inst.components.trader:IsTryingToTradeWithMe(target)
end

local function GetTraderFn(inst)
-- ★★★ GetTraderFn —— 一个「有副作用」的 getter，本文件最需要注意的写法。
-- 【★ 它在求值过程中做了四件事（第 125-140 行）】
--   1) 选台词并立即 Chatter（说话！）
--   2) 启/重置 speak_time 定时器（说话冷却）
--   3) 启/延长 complain_time 定时器（抱怨冷却）
--   4) 最后才 return 交易对象
-- ★★★ 这意味着每帧调用 GetTraderFn 都可能「说出台词」。
--   ★ 之所以没问题，全靠第 129 行 starttimer 的保护：
--     第 129 行 if not inst.components.timer:TimerExists("speak_time") then
--     ★★ 只有【定时器不存在】时才说话，存在则整个 if 块跳过。
--     ★ 这就是「用定时器给副作用限频」的经典手法。
--   ★★★ 移植价值极高：
--     「getfn 有副作用」本身是危险设计（易被误用），
--     但用「定时器存在即跳过」做节流后，可以安全地放在条件函数里。
--     与 braincommon 第 392 行 answerpotcall 的副作用同款，但更精细。
-- ★ 第 125-127 行按好感度选台词（getgeneralfriendlevel）：
--   chatter_name = "HERMITCRAB_ATTEMPT_TRADE."..gfl
--   ★★★ 即台词表是二级结构：先按好感度选组，再组内随机。
--     ★ 对比第 38 行 getstring 的同款结构（见该行注释）。
-- ★ 第 136-137 行 ★ complain_time 的特殊处理：SetTimeLeft(剩余 + 10)
--   ★ 不是重置为固定值，而是【在现有剩余基础上加 10 秒】。
--   ★ 语义：抱怨计时器越接近到期，加得越多 → 实际是「不断延长」。
--   ★ 这是一种「软性冷却」：抱怨越来越难被触发。
    if inst.sg:HasStateTag("talking") then
        return nil
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local players = FindPlayersInRange(x, y, z, TRADE_DIST, true)
    for i, v in ipairs(players) do
        if inst.components.trader:IsTryingToTradeWithMe(v) then

            local gfl = inst.getgeneralfriendlevel(inst)
            local chatter_name = "HERMITCRAB_ATTEMPT_TRADE."..gfl
            inst.components.npc_talker:Chatter(chatter_name, math.random(#(STRINGS["HERMITCRAB_ATTEMPT_TRADE"][gfl])), nil, nil, true)

            if inst.components.timer:TimerExists("speak_time") then
                inst.components.timer:SetTimeLeft("speak_time", TUNING.HERMITCRAB.SPEAKTIME)
            else
                inst.components.timer:StartTimer("speak_time",TUNING.HERMITCRAB.SPEAKTIME)
            end

            if inst.components.timer:TimerExists("complain_time") then
                local time = inst.components.timer:GetTimeLeft("complain_time")
                inst.components.timer:SetTimeLeft("complain_time", time + 10)
            else
                inst.components.timer:StartTimer("complain_time",10 + (math.random()*30))
            end

            return v
        end
    end
end

local function KeepTraderFn(inst, target)
-- KeepTraderFn：与 GetTraderFn 配对，但【没有副作用】。
--   ★★ 这个不对称很关键：GetFn 有副作用（说话），KeepFn 干净。
--   ★ 因为 FaceEntity 每帧调 KeepFn 多次、调 GetFn 一次（进入时）。
--   ★★★ 「get 与 keep 必须成对，且副作用只放 get」是本项目的通用约定。
--   ★ 与 braincommon 第 12 行 AnchorToSaltlick 的 GetSaltlick（有副作用）
--     + 无独立 keepfn 的结构对照，属不同场景下的合理差异。
    if inst.sg:HasStateTag("talking") then
        return nil
    end

    return inst.components.trader:IsTryingToTradeWithMe(target)
end

local function HasValidHome(inst)
-- ★★ HasValidHome 的四重校验，与 pigbrain 第 125 行逐字相同。
--   ★ 全项目出现 3 次（pigbrain / mermbrain / hermitcrabbrain）的标准写法。
    local home = inst.components.homeseeker ~= nil and inst.components.homeseeker.home or nil
    return home ~= nil
        and home:IsValid()
        and not (home.components.burnable ~= nil and home.components.burnable:IsBurning())
        and not home:HasTag("burnt")
end

local function GoHomeImmediatelyAction(inst)
-- ★ GoHomeImmediatelyAction：不检查任何前置条件，有家就回。
--   ★ 对比第 169 行 GoHomeAction 额外检查 not AllNightTest()（是否通宵营业）。
--   ★★ 两个「回家」函数的区别是【是否看营业时间】。
--   第 689 行皮肤请求时用 Immediate（第 685 行条件含 skinrequest）。
    if HasValidHome(inst) then
        return BufferedAction(inst, inst.components.homeseeker.home, ACTIONS.GOHOME)
    end
end

local function GoHomeAction(inst)
-- GoHomeAction：正常回家，会检查 AllNightTest（蟹壳怪可能整夜营业）。
    if HasValidHome(inst) and not inst:AllNightTest() then
        return BufferedAction(inst, inst.components.homeseeker.home, ACTIONS.GOHOME)
    end
end

local function GetHomePos(inst)
    return HasValidHome(inst) and inst.components.homeseeker:GetHomePos()
end

local LIGHTS_TAGS = {"lightsource"}

local function GetNearestLightPos(inst)
    local light = GetClosestInstWithTag(LIGHTS_TAGS, inst, SEE_LIGHT_DIST)
    if light then
        return Vector3(light.Transform:GetWorldPosition())
    end
    return nil
end

local function GetNearestLightRadius(inst)
    local light = GetClosestInstWithTag(LIGHTS_TAGS, inst, SEE_LIGHT_DIST)
    if light then
        return light.Light:GetCalculatedRadius()
    end
    return 1
end

local function formatstring(inst,str,target)
-- formatstring：把台词里的占位符替换成目标名字。
--   第 198 行 string.format(str, target:GetDisplayName())
--   ★ 即台词里可能有 %s 之类占位符。
    return string.format(str,target:GetDisplayName())
end

local function getfriendlevelspeech(inst, target)
-- ★★★ getfriendlevelspeech —— 本文件最长的函数（61 行），社交 AI 的核心。
-- 【第 202 行】★ 单向锁存：说话冷却没到就直接返回 nil
--   ★ 与第 115 行 GetTraderFn 用同一个 speak_time 定时器 ——
--     即【打招呼与交易叫卖共享冷却】，不会同时吵。
-- 【第 204-215 行】★ 两级台词选择：
--   第 205 行 str = STRINGS.HERMITCRAB_GREETING[level][随机] —— 按好感度选组
--   第 207-215 行：★★ 若选中的是【表】则逐条格式化，否则格式化单条
--     ★ 即台词支持「数组（多句连说）」与「字符串（单句）」两种形态。
--     ★ 这就是第 38 行 getstring 提到的结构，此处是它的完整实现。
-- 【第 217-248 行】★★★ 三层覆盖，优先级递减】
--   ① 第 219-226 行：有奖励 → 用奖励台词，并取消待发的奖励任务
--     ★ inst.rewardcheck(inst) 返回台词字符串或 nil。
--     ★ 第 223-225 行取消 giverewardstask —— 奖励只发一次。
--   ② 第 229-247 行：★ 满好感(10) 且 今天没跟【这个玩家】打过招呼 → 特殊台词
--     ★★ 第 229 行用一个复合 key 的定时器：
--       "hermit_grannied"..target.GUID
--     ★★★ 极高明的设计：每个玩家一个定时器，于是「今天对 A 说过、对 B 没说」
--       可以分别记录。用 GUID 拼 key 是 DST 实现「按玩家记忆」的通用手法。
--       ★ 移植价值：把「N 个对象各自的状态」压进一个字典，而不是 N 个字段。
--     ★ 第 232-234 行读玩家的三项状态（sanity/health/hunger 百分比）
--     ★ 第 236-247 行 ★★ 五级台词分支（按谁最差排序）：
--       都 > 50%      → LEVEL10_PLAYERGOOD
--       sanity 最差   → LEVEL10_LOWSANITY
--       health 最差   → LEVEL10_LOWHEALTH
--       hunger 最差   → LEVEL10_LOWHUNGER
--     ★ 第 240-246 行的判断是「比较 sanity/health/hunger 三者谁最小」，
--       写得比较绕（互相用 <= 比较），但语义正确。
--     ⚠️ 第 240 行 (not health or sanity <= health) —— 若 health 为 nil，
--       只要 sanity 存在就可能误判为「sanity 最差」。属边界缺陷。
--       已逐字核对第 240、242、244 行，三处都有相同的 nil 简化模式。
--       标为疑似：实际玩家总有 health 组件，故难以触发。
--   ③ 第 250-257 行：启动 speak_time 并延长 complain_time（与第 129 行同款）
-- 【第 259 行】return str, is_chatter —— 第二个返回值区分「说」与「聊」
--   ★ is_chatter 只在奖励分支（第 222 行）被置 true。
--   ★ 下游（第 278-283 行）据此选择 Chatter 或 Say —— ★★ 重要区别：
--     Say   —— 一句话，念完就完（不打断当前行为）
--     Chatter —— 可以排队、多句、显示气泡
--   ★ 移植价值：区分「单句应答」与「多句闲聊」两种表达形式。
    if not inst.components.timer:TimerExists("speak_time") then
-- ★★ speak_time 定时器是【社交行为的总闸门】：
--   第 129 行（GetTraderFn）与第 202 行（本函数）共用同一个定时器名。
--   ★★★ 效果：蟹壳怪不会「一边跟人打招呼一边吆喝卖货」。
--   ★ 这是「用单一冷却资源协调多个行为」的简洁设计，移植价值高。
--   ⚠️ 副作用：这两类行为的频率被【互相牵制】——
--     若频繁交易吆喝，就打不了招呼。属于可接受的取舍。

        local level = inst.components.friendlevels.level
        local str = STRINGS.HERMITCRAB_GREETING[level][math.random(#STRINGS.HERMITCRAB_GREETING[level])]
-- ★★ 台词表是【二级结构】：STRINGS.HERMITCRAB_GREETING[好感度][随机项]。
--   ★ 与第 38 行 getstring 的判断条件（是否有 "LOW" 子键）同源。
--   ★★ 结构解读：
--     STRINGS.HERMITCRAB_GREETING = { [好感度] = { 台词1, 台词2, ... } }
--   即「每档好感度有一组台词，组内随机」。这是 DST 台词系统的标准形态。

        if type(str) == "table" then
            local new = {}
            for i,sstr in ipairs(str)do
                table.insert(new,formatstring(inst,sstr,target))
            end
            str = new
        else
            str = formatstring(inst,str,target)
        end

        -- override if there are rewards.
        local is_chatter
        local rewardstr = inst.rewardcheck(inst)
        if rewardstr then
            str = rewardstr
            is_chatter = true
            if inst.giverewardstask then
                inst.giverewardstask:Cancel()
                inst.giverewardstask = nil
            end
        else
            --othewise, do some cutsom stuff for fun.
            if target and level == 10 and not inst.components.timer:TimerExists("hermit_grannied"..target.GUID) then
-- ★★★ 满好感玩家的专属台词 —— 用「玩家 GUID」拼定时器名。
--   第 229 行 "hermit_grannied"..target.GUID
--   ★★★ 这个技巧值得单独学：
--     · 需求：对每个玩家分别记录「今天是否已打过招呼」
--     · 直觉做法：在实体上加 player1_done / player2_done ... 字段（不可行，玩家不定数）
--     · 本文件做法：★ 用定时器名做字典的键。
--   ★ 定时器本身就是一张可枚举的表，等于零成本获得了「按玩家记忆」。
--   ★★★ 移植价值极高：任何「对多个对象分别限频」的需求都能套用。
--   ★ 第 230 行时长用 TUNING.TOTAL_DAY_TIME（一整天）。
                inst.components.timer:StartTimer("hermit_grannied"..target.GUID,TUNING.TOTAL_DAY_TIME)

                local sanity = target.components.sanity and target.components.sanity:GetPercent() or nil
                local health = target.components.health and target.components.health:GetPercent() or nil
                local hunger = target.components.hunger and target.components.hunger:GetPercent() or nil

                if (not sanity or sanity > 0.5) and
                    (not health or health > 0.5) and
                    (not hunger or hunger > 0.5) then
                    str = STRINGS.HERMITCRAB_LEVEL10_PLAYERGOOD[math.random(1,#STRINGS.HERMITCRAB_LEVEL10_PLAYERGOOD)]
                elseif sanity and (not health or sanity <= health) and (not hunger or sanity <= hunger) then
-- ⚠️ 疑似边界缺陷：三个「谁最差」的比较都用 not nil 简化。
--   第 240 行 (not health or sanity <= health) and (not hunger or sanity <= hunger)
--   ★ 若 health 为 nil，第一支直接为真 → 判为「sanity 最差」。
--   ⚠️ 但玩家实体总有 health 组件，故实际难触发。
--   已逐字核对第 240、242、244 行，三处结构完全对称。
--   ★ 作者显然为了简化而牺牲了边界严谨性，属「风格换健壮性」的取舍。
                    str = STRINGS.HERMITCRAB_LEVEL10_LOWSANITY[math.random(1,#STRINGS.HERMITCRAB_LEVEL10_LOWSANITY)]
                elseif health and (not sanity or health <= sanity) and (not hunger or health <= hunger) then
                    str = STRINGS.HERMITCRAB_LEVEL10_LOWHEALTH[math.random(1,#STRINGS.HERMITCRAB_LEVEL10_LOWHEALTH)]
                elseif hunger and (not sanity or hunger <= sanity) and (not health or hunger <= health) then
                    str = STRINGS.HERMITCRAB_LEVEL10_LOWHUNGER[math.random(1,#STRINGS.HERMITCRAB_LEVEL10_LOWHUNGER)]
                end
            end
        end

        inst.components.timer:StartTimer("speak_time",TUNING.HERMITCRAB.SPEAKTIME)

        if inst.components.timer:TimerExists("complain_time") then
            local time = inst.components.timer:GetTimeLeft("complain_time")
            inst.components.timer:SetTimeLeft("complain_time", time + 10)
        else
            inst.components.timer:StartTimer("complain_time",10 + (math.random()*30))
        end

        return str, is_chatter
    end
end

local function GetFaceTargetFn(inst)
-- ★★ GetFaceTargetFn 把「打招呼」逻辑【塞进了取目标的过程】。
-- 【四个分支】
--  第 264-266 行：正在交谈（talking）→ 返回 nil（不打断对话）
--  第 267-270 行：附近没玩家 → 重置 hasgreeted（允许下次再打招呼）
--  第 271 行：找 4 距离内最近的玩家，排除 notarget 标签
--  第 273-286 行：★★ 应看向玩家 且 不忙 且 没打过招呼 → 说台词
--   ★ 第 285 行 inst.hasgreeted = true 标记「已打招呼」
--   ★★ 第 269 行的 inst.hasgreeted = nil 与第 285 行的 = true 配对：
--     玩家走远 → 重置 → 玩家回来 → 还能再打招呼。
--   ★ 「hasgreeted 无定时器，但通过「玩家离开」来失效」——
--     巧妙地避免了为 hasgreeted 也配一个定时器。
-- 【第 288-291 行】★★ 打断钓鱼：
--   应看向玩家 且 正在钓鱼(npc_fishing) → 停止钓鱼，理由 "bothered"
--   ★★★ 理由字符串写死在事件里，是很生动的细节。
--   第 289 行 RemoveStateTag("canrotate") —— 解除可旋转状态。
-- 【第 293-297 行】玩家有特殊音乐 → push（触发音乐）
-- ★★★ 这个函数是「一个 getter 干四件事」的极端例子，
--   与第 115 行 GetTraderFn 同款策略：副作用 + 定时器限频。
    if inst.sg:HasStateTag("talking") then
        return nil
    end
    local target = FindClosestPlayerToInst(inst, START_FACE_DIST, true)
    if not target then
        inst.hasgreeted = nil
    end
    local shouldface = target ~= nil and not target:HasTag("notarget") and target or nil

    if shouldface and not inst.sg:HasStateTag("busy") and not inst.sg:HasStateTag("alert") and not inst.hasgreeted then
        local str, is_chatter = getfriendlevelspeech(inst, target)
        if str then
            -- TODO (SAM) Leaving this as Say for now, because some of the getfriendspeechlevel options
            -- format in the player's name.
            if is_chatter then
                local sound = nil -- stub
                inst.components.npc_talker:Chatter(str, nil, nil, nil, nil, sound)
            else
                inst.components.npc_talker:Say(str, nil, true)
            end
        end
        inst.hasgreeted = true
    end

    if shouldface and inst.sg:HasStateTag("npc_fishing") then
        inst.sg:RemoveStateTag("canrotate")
        inst:PushEvent("oceanfishing_stoppedfishing",{reason="bothered"})
    end

    if shouldface then
        if target and target._hermit_music then
            target._hermit_music:push()
        end
    end
    return shouldface
end

local function KeepFaceTargetFn(inst, target)
-- ★★★ KeepFaceTargetFn —— 与 GetFaceTargetFn 配对，但【判据完全不同】。
--   第 306-308 行排除 notarget / playerghost / 对方在 talking
--   ★★ 注意：它【没有】排除 hasgreeted，也没有 distance 的 4 分档。
--   ★ 而 GetFaceTargetFn 用 START_FACE_DIST(4)，这里用 KEEP_FACE_DIST(6)。
--   ★ 又一处 get/keep 的距离不对称（迟滞），与其他文件同款。
-- ⚠️ 第 308 行 target.sg:HasStateTag("talking") —— 未判 target.sg 非 nil。
--   ★ 但 since 有 notarget/playerghost 排除在前（第 306-307 行），
--     且 target 是玩家（有 sg）。可接受。
    return inst ~= nil
        and target ~= nil
        and inst:IsValid()
        and target:IsValid()
        and not (target:HasTag("notarget") or
                target:HasTag("playerghost") or
                    target.sg:HasStateTag("talking"))
        and inst:IsNear(target, KEEP_FACE_DIST)
end

local function DoCommentAction(inst)
    if inst.comment_data then
        if inst.comment_data.speech then
            return BufferedAction(inst, nil, ACTIONS.COMMENT, nil, inst.comment_data.pos, nil, inst.comment_data.distance)
        else
            local buffered_action = BufferedAction(inst, nil, ACTIONS.WALKTO, nil, inst.comment_data.pos, nil, inst.comment_data.distance)
            if buffered_action then
                buffered_action:AddSuccessAction(function() inst.comment_data = nil end)
            end
            return buffered_action
        end
    end
end

local function IsItemHarvestableMeat(item)
-- ★★ IsItemHarvestableMeat：只收「不可晾晒的鲜肉」。
--   第 327 行 components.dryable == nil and foodtype == MEAT
--   ★★★ 语义：晾肉架上【已经晒好】的（没 dryable）与【正在晒】的分别处理
--     （见第 338-349 行）。这是「同一个设施的两种状态」。
    return item.components.dryable == nil and item.components.edible and item.components.edible.foodtype == FOODTYPE.MEAT
end

local function DoHarvestMeat(inst)
-- ★★ DoHarvestMeat：肉架的三态处理（第 334-350 行）。
--   遍历所有肉架，逐个判断：
--   ① 架上有可收的鲜肉 → targetitem = 收它，target = 架子（第 338-344 行）
--   ② 架子自带 dryer 且已烘干 → targetitem = nil，target = 架子（第 345-349 行）
--   ★★ 区别在于【收获鲜肉】与【收取烘干品】传不同的 targetitem。
--   第 352 行 BufferedAction(inst, target, ACTIONS.HARVEST, targetitem)
--   ★ HARVEST 的第 4 参可为 nil（只收成品）或指定物品（收鲜肉）。
    local source = inst.CHEVO_marker
    if source then
        local x, y, z = source.Transform:GetWorldPosition()
        local ents = inst:GetAllMeatRacksNear(x, y, z)
        local target = nil
        local targetitem = nil
        for _, ent in ipairs(ents) do
            local container = ent.components.dryingrack and ent.components.dryingrack:GetContainer() or nil
            if container and not container:IsEmpty() then
                targetitem = container:FindItem(IsItemHarvestableMeat)
                if targetitem then
                    target = ent
                    break
                end
            elseif ent.components.dryer and ent.components.dryer:IsDone() then
                target = ent
                targetitem = nil
                break
            end
        end
        if target then
            return BufferedAction(inst, target, ACTIONS.HARVEST, targetitem)
        end
    end
end

local PICKABLE_TAGS = {"pickable","bush"}
-- ★ PICKABLE_TAGS 同时含 "pickable" 与 "bush" ——
--   ★ 即灌木本身也可摘（摘浆果）。用标签而非 prefab 列表，更易扩展。
local function DoHarvestBerries(inst)
    local source = inst.CHEVO_marker
    if source then
        local x,y,z = source.Transform:GetWorldPosition()
        local ents = TheSim:FindEntities(x,y,z, inst.island_radius, PICKABLE_TAGS)
        local target = (#ents > 0 and ents[1]) or nil
        if target then
            return BufferedAction(inst, target, ACTIONS.PICK)
        end
    end
end

local FISHING_MARKER_TAGS = {"hermitcrab_marker_fishing"}

local FISH_TAGS = {"oceanfish", "oceanfishable"}
local FISH_NO_TAGS = {"INLIMBO"}

local function DoFishingAction(inst)
-- ★★★ DoFishingAction —— 「选最优钓鱼点」的两段式算法。
-- 【第 376 行】★ 两个前置：没手持伞（第 48 行）且不在恶劣居住区
--   ★ 手持伞不钓鱼：伞要腾手（见文件头说明）。
-- 【第 382-389 行】★★ 关键：对每个标记点做【8 距离内的鱼群密度统计】
--   local fish = TheSim:FindEntities(x1,y1,z1, 8, FISH_TAGS, FISH_NO_TAGS)
--   if #fish > mostfish.total then mostfish = {total=#fish, idx=i} end
--   ★★★ 「不去鱼多的地方钓，只去鱼最多的地方」—— 最大化收益。
--   ★ 这是一个「对候选点逐一评分再取最优」的小型实例，移植价值高。
-- 【第 393-395 行】
--   第 393 行 inst.startfishing(inst) —— 先切状态图
--   ★★ 【先启动钓鱼流程，再提交抛竿动作】—— 顺序不能反。
--   第 394 行找鱼竿：优先背包里的，否则用手上的。
-- ★⚠️ 第 394 行的 or 优先级：
--   local rod = FindItem(...) or inst.components.inventory:GetEquippedItem(...)
--   ★ 正确。返回 FindItem 的结果，或（FindItem 为 nil 时）用手上的。
--   ★ 注意与 GetClosestToolShed（mermbrain 第 224 行）的「升级版立即返回」不同，
--     这里用 or 降级 —— 因为「背包鱼竿」与「手持竿」都可用，无优劣之分。
	if not holding_umbrella(inst) and not inst:IsInBadLivingArea() then
        local source = inst.CHEVO_marker
        if source then
            local x,y,z = source.Transform:GetWorldPosition()
            local ents = TheSim:FindEntities(x,y,z, inst.island_radius, FISHING_MARKER_TAGS)
            local mostfish = {total=0,idx=0}
            for i,ent in ipairs(ents)do
                local x1,y1,z1 = ent.Transform:GetWorldPosition()

                local fish = TheSim:FindEntities(x1,y1,z1, 8, FISH_TAGS, FISH_NO_TAGS)
                if #fish > mostfish.total then
                    mostfish = {total=#fish,idx=i}
                end
            end
            if mostfish.idx > 0 then
                local pos = Vector3(ents[mostfish.idx].Transform:GetWorldPosition())
                if pos then
                    inst.startfishing(inst)
                    local rod = inst.components.inventory:FindItem(function(item) return item.prefab == "oceanfishingrod" end) or inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    return BufferedAction(inst, nil, ACTIONS.OCEAN_FISHING_CAST, rod, pos)
                end
            end
        end
    end
end

local function DoReel(inst)
-- ★ DoReel：收线。条件是「有鱼 且 处于钓鱼待机」。
    if inst.hookfish and inst:HasTag("fishing_idle") then
        return BufferedAction(inst, nil, ACTIONS.OCEAN_FISHING_REEL)
    end
end

local function runawaytest(inst)
    if inst.components.friendlevels.level <= TUNING.HERMITCRAB.UNFRIENDLY_LEVEL then
        local player = FindClosestPlayerToInst(inst, STOP_RUN_DIST, true)
        if not player then
            inst.hasgreeted = nil
        end
        if player and not inst.sg:HasStateTag("busy") and not inst.hasgreeted then
            local str, is_chatter = getfriendlevelspeech(inst, player)
            if str then
                -- TODO (SAM) Leaving this as Say for now, because some of the getfriendspeechlevel options
                -- format in the player's name.
                if is_chatter then
                    local sound = nil -- stub
                    inst.components.npc_talker:Chatter(str, nil, nil, nil, nil, sound)
                else
                    inst.components.npc_talker:Say(str, nil, true)
                end
            end
            inst.hasgreeted = true
        end
        return true
    end
end

local RUN_AWAY_FROM_PIG_PARAMS =
{
	tags = { "pig", "_combat" },
	fn = function(guy, inst)
		return guy.components.combat:TargetIs(inst)
	end,
}

local function DoBottleToss(inst)
-- ★★★ DoBottleToss：★ 用三次随机重试来「确保投到海里」。
--   第 447 行 for attempt = 1, 3 do
--   第 448 行 pos = 随机选一个标记点
--   第 450 行 if pos and IsOceanTileAtPoint(...) then 成功则返回
--   ★★★ 语义：标记点【不保证是海面】，所以随机挑最多 3 次试海面。
--   ★ 这是「有限重试」的简洁实现，不需要显式的 retry 状态机。
--   ⚠️ 若 3 次都没抽到海面，函数返回 nil（放弃）。可接受。
--   ★ 第 453-459 行的工具准备（找/生成/装备瓶子）与 DoFishingAction 第 394 行同款。
--   ★ ★ 复用套路：缺工具就 SpawnPrefab 一个再装备。
	if not inst.components.timer:TimerExists("bottledelay") and not holding_umbrella(inst) and not inst:IsInBadLivingArea() then
        local source = inst.CHEVO_marker
        if source then
            local x,y,z = source.Transform:GetWorldPosition()
            local ents = TheSim:FindEntities(x,y,z, inst.island_radius, FISHING_MARKER_TAGS)
            if #ents > 0 then
                for attempt = 1, 3 do
                    local pos = ents[math.random(1,#ents)]:GetPosition()

                    if pos and TheWorld.Map:IsOceanTileAtPoint(pos.x, 0, pos.z) then
                        local equipped = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                        local bottle = inst.components.inventory:FindItem(function(item) return item.prefab == "messagebottle_throwable" end) or (equipped and  equipped.prefab == "messagebottle_throwable" and equipped )
                        if not bottle  then
                            bottle = SpawnPrefab("messagebottle_throwable")
                            inst.components.inventory:GiveItem(bottle)
                        end
                        if not bottle.components.equippable.isequipped then
                            inst.components.inventory:Equip(bottle)
                        end

                        inst.dotalkingtimers(inst)
                        return BufferedAction(inst, nil, ACTIONS.WATER_TOSS, bottle, pos)
                    end
                end
            end
        end
    end
end

local SITTABLE_TAGS = {"cansit"}
local SITTABLE_WONT_TAGS = { "uncomfortable_chair", "fire" }
local function DoChairSit(inst)
-- ★ DoChairSit：坐下休息。
--   第 480-483 行 for _, ent in ipairs(ents) do target = ent; break end
--   ★★★ 写法冗余：等价于 target = ents[1]。
--   ★ 已逐字核对第 480-483 行：确实是无意义的 for + break。
--   标为冗余代码，非缺陷（行为正确）。
    if not inst:HasTag("sitting_on_chair") and not inst.components.timer:TimerExists("sat_on_chair") then
        local source = inst.CHEVO_marker
        if source then
            local x,y,z = source.Transform:GetWorldPosition()
            local ents = TheSim:FindEntities(x,y,z, inst.island_radius, SITTABLE_TAGS, SITTABLE_WONT_TAGS)
            local target = nil
            if #ents > 0 then
                for _, ent in ipairs(ents)do
                    target = ent
                    break
                end
            end
            if target then
                return BufferedAction(inst, target, ACTIONS.SITON)
            end
        end
    end
end

local HOTSPRING_TAGS = { "hermithotspring" }
local HOTSPRING_NO_TAGS = { "bathbombable" }
local function DoSoakin(inst)
-- ★★ DoSoakin：泡温泉的三个前置条件。
--   第 495 行 不在泡 且 没有「泡过」的定时器
--   第 500-503 行 ★★ 若温泉被「bathbomb」过，剩余时间不足则不泡
--     ★ 即「刚被人炸过、正在恢复的温泉别去」。
--     ★ 与第 501 行比较 TUNING.HERMITCRAB_HOTSPRING_SOAK_TIME（所需时长）。
--   第 505 行 return BufferedAction(inst, v, ACTIONS.SOAKIN)
--   ⚠️ 第 496 行用 y=0 搜索（TheSim:FindEntities(x, 0, z, 20, ...)），
--     忽略了自身高度。多处（第 362、380 行）都是如此，属既定简化。
	if not (inst.sg:HasStateTag("soakin")  or inst.components.timer:TimerExists("soaked_in_hotspring")) then
		local x, y, z = inst.Transform:GetWorldPosition()
		for _, v in ipairs(TheSim:FindEntities(x, y, z, 20, HOTSPRING_TAGS, HOTSPRING_NO_TAGS)) do
			if v.components.bathingpool then
				if v.components.timer then
					local remaining = v.components.timer:GetTimeLeft("bathbombed")
					if remaining == nil or remaining < TUNING.HERMITCRAB_HOTSPRING_SOAK_TIME then
						return
					end
				end
				return BufferedAction(inst, v, ACTIONS.SOAKIN)
			end
		end
	end
end

local function ExitHotSpring(inst)
-- ★ ExitHotSpring：主动离开温泉。
--   第 512 行从状态图记忆取当前占用的温泉。
--   ★ 与第 695、765 行的调用点配对（出口热泉的三处）。
	local target = inst.sg.statemem.occupying_bathingpool
	if target and target.components.bathingpool then
		target.components.bathingpool:LeavePool(inst)
	end
end

local function DoTalkQueue(inst)
-- ★★ DoTalkQueue：把待说的话逐条说完。
--   第 519 行四个条件：npc_talker 有待说的话 且 不在说话 且 不忙 且 说话冷却已过
--   ★★★ 「说完话」这件事被建模成一个【持续行为】（root 里的一个节点），
--     而不是一次性触发。因为一句话可能被打断，需要续说。
--   ★ 第 758、787 行两处调用 —— 第 758 行在「瞬移收尾」里（第 756 行），
--     即传送前一定要把话说完。设计细节很到位。
    if inst.components.npc_talker:HasLines() and not inst.sg:HasStateTag("talking") and not inst.sg:HasStateTag("busy") and not inst.components.timer:TimerExists("speak_time") then
        inst.components.npc_talker:DoNextLine()
    end
end

local function DoThrow(inst)
    if inst.itemstotoss and not inst.sg:HasStateTag("mandatory") then
        inst:PushEvent("tossitem")
    end
end

local CHATTERPARAMS_LOW = {
-- ★ CHATTERPARAMS_LOW：把台词优先级设为低，避免打断重要提示。
--   第 531 行 echotochatpriority = CHATPRIORITIES.LOW
--   ★★★ 「台词也有优先级」—— 防止 NPC 闲聊盖过任务提示音。
--   ★ 本文件几乎所有 ChattyNode 都用 LOW（第 688、696、714 行等）。
	echotochatpriority = CHATPRIORITIES.LOW,
}
local CHATTERPARAMS_HIGH = {
-- ⚠️ CHATTERPARAMS_HIGH 定义后【全文件未使用】。
--   ★ 已逐字核实：该变量只出现在第 533-535 行的定义处，无任何使用点。
--   ★ 属真实的死代码（可能是早期版本用过高优先级后改用 LOW 的遗留）。
--   ★ 不影响功能。标为遗留定义。
	echotochatpriority = CHATPRIORITIES.HIGH,
}

local HermitBrain = Class(Brain, function(self, inst)
-- ★★ 类构造里初始化茶摊表（构造器而非 OnStart）。
--   第 540 行 self.tea_shops = {}    -- [ent] = true（集合）
--   第 541 行 self.selected_tea_shop = nil
--   ★ 用【表当集合】（value 全 true）是 Lua 里的标准做法。
--   ★ 与 buzzardbrain 第 138-139 行ignorethese 的建表方式同款。
    Brain._ctor(self, inst)
    --
    self.tea_shops = {} -- [ent] = true
    self.selected_tea_shop = nil
end)

---------------------------------------------------------------------

local function IsTeaShopValid(teashop)
-- ★ IsTeaShopValid：三重校验（存在/有效/没烧）。
--   ★ 比 HasValidHome（第 155 行）少一个 burnt 检查 —— 但第 548 行合并了。
    return teashop ~= nil and teashop:IsValid()
        and not (teashop:HasTag("burnt") or (teashop.components.burnable ~= nil and teashop.components.burnable:IsBurning()))
end

function HermitBrain:AddActiveTeaShop(teashop)
-- ★ AddActiveTeaShop：登记一个可用茶摊（由外部调用）。
--   ★ 即「茶摊可以随时加入/退出」，支持动态场景。
    self.tea_shops[teashop] = true
end

function HermitBrain:RemoveActiveTeaShop(teashop)
-- ★★★ RemoveActiveTeaShop —— 移除时的级联处理。
--   第 558-561 行：★ 若被移除的正是当前选中的，则
--     1) 清空 selected_tea_shop
--     2) ★★ inst.components.locomotor:Stop() —— 立刻停下脚步
--   ★★★ 第 560 行为什么要 Stop？
--     因为 Leash 节点正朝那个茶摊跑，茶摊没了却还在跑向它。
--     ★★ 即「目标消失时立即停止移动」—— 通用且必要。
--   ★ 与 knightbrain 第 208 行 GetWanderFormationPos 返回自身位置是同类防御，
--     但这里更主动（直接停）。两种做法都对。
    self.tea_shops[teashop] = nil

    if teashop == self.selected_tea_shop then
        self.selected_tea_shop = nil
        self.inst.components.locomotor:Stop()
    end
end

function HermitBrain:AnyActiveTeaShop()
-- ★ AnyActiveTeaShop：有没有茶摊。next(self.tea_shops) ~= nil
--   ★ 用 next() 检查表非空，比 # 或 pairs 更严谨（支持稀疏键）。
    return next(self.tea_shops) ~= nil
end

function HermitBrain:GetFirstTeaShop()
    return next(self.tea_shops)
end

function HermitBrain:ValidateTeaShops()
-- ★ ValidateTeaShops：批量清理失效茶摊。
--   ★★ 与 buzzardbrain 第 167 行 LoseCorpseOwnership 同款：
--     「清理共享表时发现无效项就地删除」。
--   ★ 第 577-579 行还要额外清 selected_tea_shop。
--   ★★ 移植要点：任何长生命周期的缓存表都要有「批量校验并清理」的方法。
    for teashop in pairs(self.tea_shops) do
        if not IsTeaShopValid(teashop) then
            self.tea_shops[teashop] = nil

            if self.selected_tea_shop == teashop then
                self.selected_tea_shop = nil
            end
        end
    end
end

function HermitBrain:SelectTeaShop()
-- ★★★ SelectTeaShop：选茶摊 + 宣布。
--   第 585 行 先 Validate（清理失效项）
--   第 586 行 self.selected_tea_shop = self:GetFirstTeaShop()
--   ★★★ 「选第一个」而非「选最近的」—— 最简单但缺乏空间智能。
--     ★ 与 mermbrain 第 210 行 GetClosestToolShed 的「遍历找最近」不同。
--     ★ 这里因为茶摊由外部（第 551 行）登记，顺序即登记顺序。
--   第 589 行 ★ 有茶摊就 Chatter 宣布「我要去茶会了」
--   ★★★ 行为与台词绑定：做了决定就先说出来。
--   第 593 行 return nil（没有茶摊）
    self:ValidateTeaShops()
    self.selected_tea_shop = self:GetFirstTeaShop()

    if self.selected_tea_shop ~= nil then
        self.inst.components.npc_talker:Chatter("HERMITCRAB_ANNOUNCE_GOING_TEASHOP", math.random(#STRINGS.HERMITCRAB_ANNOUNCE_GOING_TEASHOP))
        return true
    end

    return nil
end

function HermitBrain:CheckSelectedTeaShop()
-- ★ CheckSelectedTeaShop：校验当前选中的是否还可用。
--   ★ 第 597 行也先 Validate —— 每次用之前都清理。
    self:ValidateTeaShops()
    return IsTeaShopValid(self.selected_tea_shop)
end

function HermitBrain:GetSelectedTeaShopPos()
-- GetSelectedTeaShopPos：给 Leash 用的坐标提供者。
--   ★ 与第 605 行 GetSelectedTeaShop 成对。
--   ★ 返回 nil 时（茶摊失效），第 697-704 行的 Leash 回调会走到第 703 行，
--     ★★ 那里显式调用 locomotor:Stop() —— 停下并等下一个茶摊。
--     ★ 这是本文件处理「目标消失」的第三处防御（前两处：第 560、703 行）。
	return self:CheckSelectedTeaShop() and self.selected_tea_shop:GetPosition() or nil
end

function HermitBrain:GetSelectedTeaShop()
    return self:CheckSelectedTeaShop() and self.selected_tea_shop or nil
end

---------------------------------------------------------------------

local function GetFirstHungryPetCritter(inst)
    local pets = inst.components.petleash:GetPets()
    for k, v in pairs(pets) do
        local x, y, z = v.Transform:GetWorldPosition()
        if v:HasTag("critter") and v:IsHungry() and not v:IsOnOcean(true) and not IsPointCoveredByBlocker(x, y, z) then
            return v
        end
    end
end
local function IsPetCritterHungry(inst)
-- ★★ IsPetCritterHungry 与 GetFirstHungryPetCritter（第 611 行）的筛选条件
--   【逐字相同】（第 615 行 vs 第 624 行）：
--   critter 标签 且 饿 且 不在海上 且 不被阻挡物遮住。
--   ★★ 这是典型的复制粘贴 —— 两个函数本可合并为一个「找第一个」。
--   ★ 实际无害（两个功能都需要），但维护时改一处忘一处就会出 bug。
--   ⚠️ 与 pigbrain 第 165 行同样问题（GetTraderFn / KeepTraderFn 判据重复）。
--   ★ 这似乎是本项目的普遍写法，属可接受的冗余。
    local pets = inst.components.petleash:GetPets()
    for k, v in pairs(pets) do
        local x, y, z = v.Transform:GetWorldPosition()
        if v:HasTag("critter") and v:IsHungry() and not v:IsOnOcean(true) and not IsPointCoveredByBlocker(x, y, z) then
            return true
        end
    end

    return false
end

local function is_honey(ent)
    return ent.prefab == "honey"
end
local function GetFoodForCritter(inst)
-- ★★★ GetFoodForCritter：★ 没有食物就【凭空生成】一个。
--   第 639-640 行 honey = SpawnPrefab("honey"); inventory:GiveItem(honey)
--   ★★★ 「AI 需要某个物品而背包没有时，直接造一个」——
--     省掉「先找蜂蜜/没有就没喂」的分支，逻辑极简。
--   ★ 代价：凭空出现的蜂蜜可能让玩家困惑（背包里多了个蜂蜜）。
--   ★ 移植提示：这是「让 AI 永远能完成目标」的务实技巧，代价是物品守恒被打破。
    local honey = inst.components.inventory:FindItem(is_honey)

    if honey == nil then
        honey = SpawnPrefab("honey")
        inst.components.inventory:GiveItem(honey)
    end

    return honey
end

local function DoFeedPetCritterAction(inst)
-- ★ DoFeedPetCritterAction：喂宠物，喂完聊一句。
--   ★ 第 648 行四参 BufferedAction：目标 + FEED + 指定食物。
--   ★ 第 650-652 行成功回调里 Chatter —— 「喂食有台词」。
    if IsPetCritterHungry(inst) then
        local buffered_action = BufferedAction(inst, GetFirstHungryPetCritter(inst), ACTIONS.FEED, GetFoodForCritter(inst))

        buffered_action:AddSuccessAction(function()
            inst.components.npc_talker:Chatter("HERMITCRAB_CRITTER_FEED", math.random(#STRINGS.HERMITCRAB_CRITTER_FEED))
		end)

        return buffered_action
    end
end

---------------------------------------------------------------------

local WANDER_DIST = 12
local LIGHTSOURCE_TAGS = { "lightsource" }
local function CanWanderAtPoint(pos)
-- ★★★ CanWanderAtPoint —— 「夜里不去暗处游荡」。
-- 【第 663 行】不是白天 → 才需要检查
-- 【第 664-671 行】遍历 12 距离内的光源，任一光照范围覆盖 pos → 可以去
--   第 666 行 v.Light and v.Light:GetCalculatedRadius() —— ★ 有 nil 保护
--   ★ 并非所有带 lightsource 标签的实体都有 Light 组件
--     （如未点燃的火堆）。这个 and 保护是必要的。
--   ★ 第 667-668 行用距离平方与半径平方比较，全程不开方。
-- 【第 673 行】一个光照都没有 → 返回 false
-- ★★★ 这是【游荡的合法性过滤器】—— 让蟹壳怪夜里只在灯下晃悠。
--   ★★ 它作为第 737 行 Wander 的第 7 参传入（wander_dist 之后的位置）。
--   ★ 即「不是每个想去的地方都能去」—— 移动可达性 + 光照要求双重约束。
    if not TheWorld.state.isday then
        for i, v in ipairs(TheSim:FindEntities(pos.x, pos.y, pos.z, WANDER_DIST, LIGHTSOURCE_TAGS)) do
            local x, y, z = v.Transform:GetWorldPosition()
            local light_radius = v.Light and v.Light:GetCalculatedRadius()
            local light_radius_sq = light_radius and light_radius * light_radius
            if light_radius_sq and distsq(pos.x, pos.z, x, z) < light_radius_sq then
                return true
            end
        end

        return false
    end

    return true
end

function HermitBrain:OnStart()
-- ★★ OnStart：先建 day / night 两棵子树，再拼 root。

    local day = WhileNode( function() return TheWorld.state.isday or self.inst:AllNightTest() end, "IsDay",
-- ★★★ day 的条件是 isday【或】AllNightTest（第 681 行）。
--   return TheWorld.state.isday or self.inst:AllNightTest()
--   ★★ 「营业到通宵」：蟹壳怪有夜市设定，所以晚上也能开门。
--   ★ 这也解释了第 169 行 GoHomeAction 要检查 not AllNightTest()，
--     两者是配套的：营业时不回家。
--   ★★ 与 night（第 743 行）的条件 not isday and not AllNightTest 严格互补。
--     ★ 又一处对称设计，读代码时两者要对照看。
        PriorityNode{
            WhileNode( function() return not self.inst.sg:HasStateTag("mandatory") end, "unfriendly",
-- ★★★ 「不友好」层 —— 本文件独有的第三层优先级。
--   条件：not sg:HasStateTag("mandatory")
--   ★★ mandatory（强制）标签让这一整层【在特定剧情中失效】，
--     此时直接走下面的友好分支。
--   ★★★ 这是「好感度不足 → 无视玩家」的完整实现：
--   里面依次是：皮肤请求、喂宠物、去茶会、评论、交易（面朝/看向）、
--   逃跑（若仍不友好）、打招呼（若已友好）、收线、
--   采收（肉/浆果/椅子/钓鱼/瓶子/温泉）、游荡。
--   ★★ 注意第 720-723 行的分界：
--     第 720 行 IfNode(runawaytest) —— 仍然不友好 → 逃跑
--     第 722 行 IfNode(level > UNFRIENDLY_LEVEL) —— 已友好 → 打招呼
--   ★ 这是「同一层内的态度分叉」，用两个互斥 IfNode 实现。
                PriorityNode{
                    WhileNode(function() return not self.inst.sg:HasStateTag("busy") and self.inst.hermitcrab_skinrequest ~= nil and HasValidHome(self.inst) end, "skinrequest",
-- ★ 皮肤请求 → 回家换皮肤（第 686-689 行）。
--   ★ 第 687 行台词名是【函数】："HERMITCRAB_TALK_ONSKINREQUEST." .. 好感度
--   ★ ChattyNode 支持名字为函数 —— 按当时的好感度动态选台词。
--   ★★ 与第 715 行的同款写法（也是函数形式）对照，
--     而第 746、749 行用的是【字符串】形式。两种都支持。
--   ★ 迁移细节：函数形式让台词随好感度动态变化，更细腻。
                        ChattyNode(self.inst, {
                            name = function(inst) return "HERMITCRAB_TALK_ONSKINREQUEST." .. inst:getgeneralfriendlevel() end,
                            chatterparams = CHATTERPARAMS_LOW,
                        }, DoAction(self.inst, GoHomeImmediatelyAction, "go home", true))),
                    IfNode(function() return IsPetCritterHungry(self.inst) end, "Is critter hungry",
                        DoAction(self.inst, DoFeedPetCritterAction, "feed critter", true, 10)),
                    IfNode(function() return self:SelectTeaShop() end, "go to tea shop",
-- ★ 茶会节点（第 692-710 行）：本文件最复杂的行为。
--   第 694-695 行 ★ 若正在泡温泉 → 先离开
--   第 696-707 行 ★★ FailIfSuccessDecorator(Leash 到茶摊)
--     ★ 「到位即完成」，避免到位后还继续往下走。
--     ★ 第 698-704 行的回调：★ 返回位置，没茶摊则 locomotor:Stop()
--     第 705-706 行 ★★ 距离是动态的：茶摊物理半径 + 1.5 / + 1
--       ★ 与 knightbrain 第 321 行同样的「建筑半径 + 余量」手法。
--       ★ 减 1 与 0.5 形成迟滞。
--   第 708-709 行 到位 → 推 hermitcrab_entered 事件给茶摊
						PriorityNode({
							IfNode(function() return self.inst.sg:HasStateTag("soakin") end, "exit hotspring",
								ActionNode(function() ExitHotSpring(self.inst) end)),
							FailIfSuccessDecorator(
								Leash(self.inst,
									function()
										local pos = self:GetSelectedTeaShopPos()
										if pos then
											return pos
										end
										self.inst.components.locomotor:Stop()
									end,
									function() return self.selected_tea_shop:GetPhysicsRadius(0) + 1.5 end,
-- ★★★ leash 距离是【动态函数】，取决于茶摊本身的物理大小。
--   外距 = 茶摊半径 + 1.5，内距 = 茶摊半径 + 1
--   ★ 大茶摊要站得更远。合理的自适应。
--   ★ 与第 243 行 mermbrain GetClosestToolShedPosition 同思路。
									function() return self.selected_tea_shop:GetPhysicsRadius(0) + 1 end,
									true)),
							IfNode(function() return self:CheckSelectedTeaShop() end, "tea shop exists",
								ActionNode(function() self.selected_tea_shop:PushEventImmediate("hermitcrab_entered", { hermitcrab = self.inst }) end)),
						}, .25)),

                    WhileNode( function() return self.inst.comment_data ~= nil end, "comment",
                        DoAction(self.inst, DoCommentAction, "comment", true, 10 )),
                    ChattyNode(self.inst, {
-- ★ ChattyNode 台词名也是函数形式（第 715 行），按好感度动态选择。
--   ★ 与第 686-689 行同款。与第 746、749 行的字符串形式对照。
                            name = function(inst) return "HERMITCRAB_ATTEMPT_TRADE."..inst.getgeneralfriendlevel(inst) end,
                            chatterparams = CHATTERPARAMS_LOW,
                        },
                        FaceEntity(self.inst, GetTraderFn, KeepTraderFn)),
                    FaceEntity(self.inst, GetTraderFn, KeepTraderFn),
                    IfNode( function() return runawaytest(self.inst) end, "unfriendly",
-- ★ runawaytest（第 408 行）作为 IfNode 条件：仍不友好就躲开玩家。
--   ★★ 注意它不是纯判定 —— 它还有【说话副作用】（第 415-426 行）。
--   ★ 依赖第 414 行的 not hasgreeted 与第 202 行的 speak_time 限频。
                        RunAway(self.inst, "player", START_RUN_DIST, STOP_RUN_DIST)),
                    IfNode( function() return self.inst.components.friendlevels.level > TUNING.HERMITCRAB.UNFRIENDLY_LEVEL end, "friendly",
-- ★★★ 好感度够 → 打招呼（第 723 行）。
--   FaceEntity(inst, GetFaceTargetFn, KeepFaceTargetFn, 7)
--   ★ 第 4 参 7 —— FaceEntity 的第 4 参未逐字核实。
--     与 pigbrain 第 294 行的 (…, 5, 15) 两个参数形式不同。
--     ⚠️ 不下结论，仅记录：同一节点在不同文件里参数个数不同。
                        FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn, 7)),
                    DoAction(self.inst, DoReel, "reel", true ),
                    IfNode( function() return not self.inst.sg:HasStateTag("alert")
-- ★★★ 「空闲时才做日常」的四重与（第 725-728 行）。
--   not alert（没有被惊动）
--   not npg_fishing（没在钓鱼）
--   not busy（不忙）
--   ★ not locomotor.dest（★ 脚下没有移动目标）
-- ★★★ 第 728 行这一条最关键：「有目的地移动时不插队做别的事」。
--   ★ 即「正在赶路就好好赶路」。合理的 AI 优先级设计。
--   ★ 第 729-739 行的子 PriorityNode 依次是：
--     收肉 → 采浆果 → 坐椅子 → 钓鱼 → 扔瓶子 → 泡温泉 → 游荡
--   ★★ 顺序即偏好：先干「有产出」的（肉/浆果），再干「消遣」的
--     （坐/钓/扔），最后是「休息」（温泉）与「无目的」（游荡）。
--   ★ 第 736 行 if not sitting and not soakin —— 坐着/泡着就不游荡。
--   ★ 第 737 行 Wander 的第 7 参是 CanWanderAtPoint（夜光限制）。
                                        and not self.inst.sg:HasStateTag("npc_fishing")
                                        and not self.inst.sg:HasStateTag("busy")
                                        and not self.inst.components.locomotor.dest end, "Not Acting",
-- ★★★ not inst.components.locomotor.dest —— 「正在赶路时不插队」。
--   ★★★ 这是本文件最值得学的一条细节。
--   几乎所有大脑都会检查 busy，但【很少有检查「有没有移动目标」】。
--   ★ 而这一条恰恰阻止了「边走向 A 边突然跑去采浆果」的低级 AI 表现。
--   ★ 移植建议：给任何有「多活动可选」的 NPC 都加这条守卫。
                        PriorityNode{
                            DoAction(self.inst, DoHarvestMeat, "meat harvest", true ),
                            DoAction(self.inst, DoHarvestBerries, "berry harvest", true ),
                            DoAction(self.inst, DoChairSit, "sit on chairs", true ),
                            DoAction(self.inst, DoFishingAction, "gone fishing", true ),
                            DoAction(self.inst, DoBottleToss, "bottle", true ),
							DoAction(self.inst, DoSoakin, "soak in hotspring", true),
							IfNode( function() return not self.inst.sg:HasAnyStateTag("sitting", "soakin") end, "not sitting or soaking in hotspring",
                                Wander(self.inst, GetHomePos, MAX_WANDER_DIST, nil, nil, nil, CanWanderAtPoint, {should_run = false})
                            ),
                        },0.5),
                },0.5),
        }, 0.5)

    local night = WhileNode( function() return not TheWorld.state.isday and not self.inst:AllNightTest() end, "IsNight",
-- ★★ night 的条件与 day（第 681 行）严格互补：
--   not isday and not AllNightTest()
--   ★ 三行：跑开玩家 → 喊话回家 → 喊话恐慌。
--   ★ 对比 pigbrain 第 358 行的 night 子树（7 个节点），
--     本文件夜晚行为极简 —— 因为白天已经包办了绝大多数活动。
--   ★ 优先级：先跑（第 745 行）再考虑回家 —— 危险优先。
        PriorityNode{
            RunAway(self.inst, "player", START_RUN_DIST, STOP_RUN_DIST, function(target) return ShouldRunAway(self.inst, target) end ),
            ChattyNode(self.inst, { name = "HERMITCRAB_GO_HOME", chatterparams = CHATTERPARAMS_LOW },
                WhileNode( function() return not TheWorld.state.iscaveday or not self.inst:IsInLight() end, "Cave nightness",
                    DoAction(self.inst, GoHomeAction, "go home", true ))),
            ChattyNode(self.inst, { name = "HERMITCRAB_PANIC", chatterparams = CHATTERPARAMS_LOW },
                Panic(self.inst)),
        }, 1)

    local root =
-- ★★★ root 的八个小节（按行号）逐一解读：
--  第 756-761 行：★★ 瞬移收尾 —— 传送前把话说完、然后等 1 秒
--    第 758 行 DoTalkQueue + 第 759 行 WaitNode(1)
--    ★★★ 「传送前先说完话」是很人性化的细节，值得学。
--  第 762-771 行：泡温泉续场（已泡着的处理）
--    第 764-765 行 泡够了（无 soaktime 定时器）→ 离开
--    第 766-770 行 ★ 还有话没说 → 继续说
--  第 772-774 行：恐慌（用 BrainCommon.ShouldTriggerPanic 判定）
--    ★★ 注意用的是【ShouldTriggerPanic】而非【PanicTrigger】——
--      前者是判定函数，后者是节点工厂。
--      ★ 对比 pigbrain 第 386-391 行直接用 Panic 节点。
--      ★ 这里把判定提到外层，可以与其他条件组合。
--  第 775 行：躲攻击我的猪（与 pigbrain 第 408 行同款参数表）
--  第 777-778 行：★★ 下雨 且 有伞 且 没装备 → 装备伞
--  第 779-780 行：★★ 不下雨 且 已装备 → 卸下伞
--  第 781-782 行：★★ 下雪 且 有外套 且 没穿 → 穿外套
--  第 783-784 行：★★ 不下雪 且 已穿 → 脱外套
--  第 786 行：扔东西（DoThrow）
--  第 787 行：说完待说的话
--  第 788-789 行：day / night
--  第 790 行：重评估间隔 0.5 秒
        PriorityNode(
        {
            WhileNode(function() return self.inst.sg.mem.teleporting end, "Teleporting",
-- ★★★ 瞬移收尾：传送前先把话说完。
--   条件 inst.sg.mem.teleporting —— 状态图已在传送流程中
--   第 758 行 DoTalkQueue（把待说的话说完）
--   第 759 行 WaitNode(1) —— ★ 说完再等 1 秒，给传送动画留时间
--   ★★★ 极人性化的细节：NPC 被打断对话/传送时，至少把话说完。
--   ★ 移植建议：这类「善后」节点能显著提升 AI 的「像活物」感受。
                PriorityNode({
                    DoAction(self.inst, DoTalkQueue, "finish talking", true),
                    WaitNode(1),
                })
            ),
			WhileNode(function() return self.inst.sg:HasStateTag("soakin") end, "soaking in hotspring",
				PriorityNode{
					IfNode(function() return not self.inst.components.timer:TimerExists("soaktime") end, "exit hotspring",
						ActionNode(function() ExitHotSpring(self.inst) end)),
					ActionNode(function()
						if self.inst.components.npc_talker:HasLines() and self.inst.sg.statemem.soakintalktask == nil then
							self.inst.components.npc_talker:DoNextLine()
						end
					end),
				}),
            WhileNode( function() return BrainCommon.ShouldTriggerPanic(self.inst) end, "PanicHaunted",
                ChattyNode(self.inst, { name = "HERMITCRAB_PANICHAUNT", chatterparams = CHATTERPARAMS_LOW },
                    Panic(self.inst))),
			RunAway(self.inst, RUN_AWAY_FROM_PIG_PARAMS, RUN_AWAY_DIST, STOP_RUN_AWAY_DIST ),

            IfNode( function() return not self.inst.sg:HasStateTag("busy") and TheWorld.state.israining and has_umbrella(self.inst) and not equipped_umbrella(self.inst) end, "umbrella",
-- ★★ 装备类行为的「成对节点」模式（本文件反复使用）。
--   第 777-778 行：需要时装备（下雨 + 有伞 + 未装备）
--   第 779-780 行：不需要时卸下（不下雨 + 已装备）
--   第 781-782 行 / 第 783-784 行：外套的同款一对
--   ★★★ 与第 73-82 行的 try_unequip_umbrella / UnEquipUmbrella 配套。
--   ★★ 每对都额外检查 not sg:HasStateTag("busy") —— 忙时不去换装备。
--   ★ 移植价值：装备/穿脱这类「状态维护」行为必须成对写，
--     漏掉反向分支会导致「雨停了还打着伞」。
                    DoAction(self.inst, EquipUmbrella, "umbrella", true )),
            IfNode( function() return not self.inst.sg:HasStateTag("busy") and not TheWorld.state.israining and equipped_umbrella(self.inst) end, "stop umbrella",
					DoAction(self.inst, UnEquipUmbrella, "stop umbrella", true )),
            IfNode( function() return not self.inst.sg:HasStateTag("busy") and TheWorld.state.issnowing and has_coat(self.inst) and not using_coat(self.inst) end, "coat",
                    DoAction(self.inst, EquipCoat, "coat", true )),
            IfNode( function() return not self.inst.sg:HasStateTag("busy") and not TheWorld.state.issnowing and using_coat(self.inst) end, "stop coat",
                    DoAction(self.inst, UnEquipBody, "stop coat", true )),

            DoAction(self.inst, DoThrow, "toss item", true ),
            DoAction(self.inst, DoTalkQueue, "finish talking", true ),
            day,
            night,
        }, .5)
-- ★ 重评估间隔 0.5 秒（与 pigbrain 第 418 行相同）。
--   ★ 比 knightbrain/penguin 的 0.25 宽松 —— 
--     蟹壳怪的行为都是「慢节奏社交」，不需要高频重算。
-- ★ 第 792 行 self.bt = BT(self.inst, root) —— 第 11 个文件，同样收尾。

    self.bt = BT(self.inst, root)
end

return HermitBrain