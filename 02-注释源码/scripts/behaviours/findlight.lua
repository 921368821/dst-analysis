--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/findlight.lua
-- 模块：行为树节点库 / 查找
-- 职责：找最近的光源（与 avoidlight 的「躲光」互为镜像），用于扑火类生物。
-- 关键符号：FindLight, FindLight:Visit, FindLight:PickTarget, FindLight:DBString
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：avoidlight.lua（反向节点）, findclosest.lua, TheSim:FindEntities
--============================================================
local CHECK_INTERVAL = 5
--[[
-- findlight.lua —— 就近找光节点（FindLight）：走向最近的光源并停在旁边
--
-- 【★★ 本文件是 findclosest.lua 的「标签特化 + 双周期节流」改良版】
--
--   ┌──────────────┬──────────────────────┬──────────────────────┐
--   │              │  findclosest         │  findlight            │
--   ├──────────────┼──────────────────────┼──────────────────────┤
--   │ 目标筛选     │ 三种标签语义可组合    │ 固定 lightsource      │
--   │ 重选周期     │ 5 秒                 │ 5 秒                  │
--   │ 趋近判定     │ 每帧                │ **每 1 秒**           │
--   │ 达标判定     │ 每帧（IsNear）       │ 每 1 秒（IsNear）     │
--   │ 无目标时     │ 每帧重查标签          │ 每 1 秒查 HasTag       │
--   └──────────────┴──────────────────────┴──────────────────────┘
--
-- ★★★ 最值得学的一点：findlight 把「持续走动」的决策**整体降频到 1 秒**，
--   而把「重新找目标」保持 5 秒。两级节流分工明确：
--   · 重选目标贵（空间查询）→ 5 秒一次
--   · 趋近与判定便宜（一次 IsNear + 一次 GoToPoint）→ 1 秒一次
-- ★★ 对照 findclosest 第 62-77 行：那里的趋近判定是**每帧**做的，
--   于是「靠近某人」全程每帧跑 Visit（该文件也无 self:Sleep）。
--   ★ 本文件把它降到 1 秒，CPU 开销降到约 1/60 —— 这是明显的性能优化。
-- ★ 移植要点：**把持续性决策按「计算代价」分级节流**，
--   而不是简单地「统一 Sleep 一个固定间隔」。
--   ★ 代价：趋近精度下降到 1 秒粒度，可能看起来略有「迟疑」。
--     对「走向某处」这种粗行为可接受。
--
-- 【★ 与 avoidlight.lua 互为镜像】
--   findlight  走向光源；avoidlight 远离光源。两者骨架同源（详见 avoidlight 文件头）。
--]]
--★★ 两个节流周期常量并列，参数含义一目了然：
--   CHECK_INTERVAL = 5          —— 重选目标的周期（贵操作）
--   FOLLOW_CHECK_INTERVAL = 1   —— 趋近/达标判定的周期（便宜操作）
--★ 提取为模块常量（同 findclosest 第 1 行、findfarmplant 第 1 行的做法）。
local FOLLOW_CHECK_INTERVAL = 1

FindLight = Class(BehaviourNode, function(self, inst, see_dist, safe_dist)
--★★ 4 个形参：inst / see_dist / safe_dist。
--★ 比 findclosest 少三个标签参数 —— 因为目标类型固定为「光源」，无需筛选。
--★★ 这是一个合理的简化：把「调用方要传的参数」与「节点固定的语义」分离。
--   findclosest 是通用「找最近某个东西」，findlight 是专用「找光」。
-- ★ 移植建议：**通用节点 + 专用节点成对提供** ——
--     通用版用于组合，专用版用于高频调用（少传参数、少做无用筛选）。
    BehaviourNode._ctor(self, "FindLight")
    self.inst = inst
    self.targ = nil
    self.see_dist = see_dist
    self.safe_dist = safe_dist
    self.lastchecktime = 0
--★ lastchecktime 与 lastfollowchecktime 两个时间戳分别服务于两种节流。
--★ 初值 0，保证首次 Visit 时两个条件都成立。
    self.lastfollowchecktime = 0
end)

function FindLight:DBString()
--★ DBString：显示当前盯着哪个光源。
--★ 与 findclosest 第 16 行格式几乎相同（「Stay near target/light %s」）。
--★ 排查「它为什么不靠近那盏灯」时看这一行。
    return string.format("Stay near light %s", tostring(self.targ))
end

function FindLight:Visit()
--★★ Visit：两个独立节流块，是本文件的核心结构。
--★ 结构上仍是「顺序双 if」（READY 段 + RUNNING 段），与全目录一致。
    if self.status == READY then
--★ READY 段：先选目标，然后**无条件**转 RUNNING。
--★ 与 findclosest 第 20-23 行完全相同（不判空，直接进 RUNNING）。
--★ 找不到目标的情况由第 31 行在下一个检查周期转 FAILED。
        self:PickTarget()
        self.status = RUNNING
    end

    if self.status == RUNNING then
--★★ RUNNING 段由两个互不影响的节流块组成：
--   块 A（第 25-27 行）：5 秒一次 —— 重选目标
--   块 B（第 29-42 行）：1 秒一次 —— 趋近 / 达标 / 失效判定
-- ★★ 两块用**两个独立 if** 而非 if/elseif，这意味着二者可以同帧都执行。
--   这是正确的：重选目标后应当立即用它做趋近判定。
-- ★ 移植要点：节流块若相互独立，用并列 if；若互斥，才用 elseif。
        if GetTime() - self.lastchecktime > CHECK_INTERVAL then
--★ 5 秒重选目标。与 findclosest 第 26 行同一思路（理由详见那边的详解）：
--   空间查询昂贵，不能每帧做；但也不能不重选（目标会消失）。
            self:PickTarget()
        end

        if GetTime() - self.lastfollowchecktime > FOLLOW_CHECK_INTERVAL then
--★★★ 1 秒一次的趋近/判定块 —— 本文件相对 findclosest 的核心改进。
--★ 第 30 行立即更新时间戳（先记后算，避免执行耗时导致下次判定提前）。
--★★ 先更新再执行的写法值得学：若先执行后更新，
--   当 PickTarget/GoToPoint 耗时较长时，实际间隔会短于 1 秒。
            self.lastfollowchecktime = GetTime()
            if not (self.targ ~= nil and self.targ:IsValid() and self.targ:HasTag("lightsource")) then
--★★★ 失效判定：目标不在了，或不再是光源。
--   三重与：非 nil + IsValid + HasTag("lightsource")
-- ★★ 第三条 HasTag 很关键：光源可能被替换（篝火熄灭后变成灰烬），
--   此时它仍是有效实体，却已无光可寻 → 必须放弃。
-- ★ 移植要点：**目标可能从「可用」变成「不可用」而非「消失」**，
--   只判 IsValid 不够，还要判「业务上是否仍然成立」。
--★ 与 findclosest 第 29-60 行的三层标签复核是同类思想，
--   但本文件只用单条 HasTag —— 因为目标类型单一。
                self.status = FAILED
            else
                local actual_safe_dist = FunctionOrValue(self.safe_dist, self.inst, self.targ) or 5
--★ safe_dist 支持「值或函数」，传 (inst, targ) 两个参数，兜底 5。
--★ 与 findclosest 第 70 行逐字相同 —— 同族节点的一致写法。
                if self.inst:IsNear(self.targ, actual_safe_dist) then
--★ 达标判定：站在 safe_dist 内 → SUCCESS + 停止移动。
--★ 与 findclosest 第 71-73 行逐字相同。
--★★ 注意与 findclosest 第 116 行的差异（前者每帧判、此处每秒判）：
--   本文件达标后会最多多走 0.5 秒 —— 观感上略有「冲过头」。
--   ★ 这是「降频」换来 CPU 的直接代价，属有意的取舍。
                    self.status = SUCCESS
                    self.inst.components.locomotor:Stop()
                else
                    self.inst.components.locomotor:GoToPoint(self.inst:GetPositionAdjacentTo(self.targ, actual_safe_dist * 0.98), nil, true)
--★ 未达标 → 走向「目标旁边 safe_dist 处」。
--★★★ `actual_safe_dist * 0.98` 的 0.98 系数是本文件最值得抄的一处：
--   目标点比判定边界**略微靠内**，保证走到后一定满足第 35 行的 IsNear。
--   ★★ 这就是「判定阈值与执行阈值留一条缝」—— 极简版的滞回思想。
--   与 findclosest 第 75 行完全相同（同款写法）。
-- ★ 移植建议：**任何「走到某距离就停」的行为都要加这个余量**，
--   否则会在边界反复徘徊（float 误差 + 追逐效应）。
--⚠️ 但在本文件里 0.98 的收益被 1 秒节流削弱了 ——
--   节流误差（可达 1 秒的移动量）远大于 2% 的余量。
--   即余量在「每帧判定」下很有用，在「每秒判定」下作用有限。
--   标注为「已核实的效力差异」：两处写法相同，但实际收益不同。
                end
            end
        end
    end
end

local LIGHTS_TAGS = {"lightsource"}
--★ LIGHTS_TAGS = {"lightsource"} —— 模块级常量，目标标签唯一。
--★ 与 findfarmplant 第 49 行的 FARMPLANT_MUSTTAGS 同款写法。
function FindLight:PickTarget()
--★★ PickTarget：目标查找，两行搞定。
-- ★ 用 GetClosestInstWithTag（与 findfarmplant 第 37 行同款便捷函数），
--   而非 findclosest 的 TheSim:FindEntities + 手动取 ents[1]。
--★★ 两种 API 的区别值得记：
--   · TheSim:FindEntities  —— 通用，支持任意标签组合，返回**列表**
--   · GetClosestInstWithTag —— 便捷，单标签 + 基准实例 + 半径，直接返回**最近的一个**
-- ★ 移植要点：**能用便捷函数就别取列表再挑第一个** ——
--   后者要求你手动处理「结果里第一个是自己」的排除（findclosest 第 84 行）。
--   这里由引擎处理，少一处易错点。
    self.targ = GetClosestInstWithTag(LIGHTS_TAGS, self.inst, self.see_dist)
    self.lastchecktime = GetTime()
--★ 更新时间戳（重选周期用）。
--★ 注意第 29 行的 lastfollowchecktime **不在**这里更新 ——
--   两者是独立的时钟，分开管理才不会互相干扰。
end
--★★ 全文件结束在 PickTarget —— 印证了它没有任何终态转换逻辑。
--   节点的生命周期：READY → RUNNING →（重选 or 达标）→ SUCCESS/FAILED。
--   ★ 全程无 self:Sleep 调用 ——
--     但**这不是性能问题**：因为大部分分支被 1 秒节流挡住，
--     大脑虽然每帧被唤醒（GetSleepTime 返回 0），Visit 内部很快返回，
--     开销远小于 findclosest 的每帧全量执行。
--   ★★★ 这是一个重要的性能认知修正：
--     「没有 Sleep」不等于「开销最大」，真正决定开销的是**函数内部做了什么**。
--     findclosest 每帧做标签三层遍历 + IsNear + GetPositionAdjacentTo；
--     findlight 每帧只做两个时间比较。
--     ★ 移植要点：优化 AI 时先看「每次唤醒干多少活」，
--       而不是只盯着有没有调 Sleep。
--     两条优化路径（Sleep 节流 / 内部降频）可以叠加，也可以二选一。