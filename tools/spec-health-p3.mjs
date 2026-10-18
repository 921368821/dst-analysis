// spec-health-p3.mjs —— health.lua 深度注释规格 第 3 部分：交叉引用补充层
// 目的：按要求补足「参见 xxx.lua:行号」格式的交叉引用，覆盖上下游关键机制。

export const BEFORE = {
  // ── 与 class.lua 的关系：属性 setter 机制 ──
  62: [
    "--★★ 参见 class.lua:82 Class(base, _ctor, props) —— 本行是 Class 的第一个实参（构造器），",
    "--   第二个实参 nil 表示「不继承任何基类」，所以 Health 是独立类（不是 StandardEntity 的子类）。",
    "--   class.lua:75 removesetter 是客户端分支用来摘除 setter 的函数。",
  ],
  104: [
    "--★★ 参见 class.lua:82 中 `if props ~= nil then c.__index = __index; c.__newindex = __newindex`",
    "--   —— 传入 props 才会启用属性 setter 派发。",
    "--   class.lua:64 addsetter 是运行期追加 setter 的接口。",
  ],
  613: [
    "--★★ 参见 entityscript.lua:1714 Remove —— 组件卸载会触发 OnRemoveFromEntity（116 行），",
    "--   那里停掉所有 regen 任务与事件监听。",
  ],

  // ── 与 util/sourcemodifierlist.lua 的关系 ──
  92: [
    "--★★ 参见 util/sourcemodifierlist.lua:8 SourceModifierList 构造签名",
    "--   `Class(function(self, inst, base_value, fn, dirtycb)`。",
    "--   util/sourcemodifierlist.lua:28 是 multiply（默认），:32 是 additive（本文件用后者），",
    "--   :36 是 boolean。util/sourcemodifierlist.lua:60 SetModifier 内部会为实体来源",
    "--   自动注册 onremove 清理，:46 RecalculateModifier 是重算入口。",
  ],
  81: [
    "--★ 参见 util/sourcemodifierlist.lua:60 SetModifier(source, m, key) ——",
    "--   本行用默认 multiply 语义（火焰倍率相乘），与 92/93 行的 additive 区分。",
  ],

  // ── 与 replica 的同步链路 ──
  10: [
    "--★★ 参见 components/health_replica.lua:57 SetMax ——",
    "--   内部走 `self.classified:SetValue(\"maxhealth\", max)` 写 netvar。",
    "--   参见 netvars.lua 的 netvar 声明；netvar 的「声明顺序即 wire format」约束",
    "--   记录在 bug-patterns.md 的 B1。",
  ],
  19: [
    "--★★ 参见 components/health_replica.lua:51 SetCurrent / :130 SetIsDead。",
    "--   health_replica.lua:41 GetPenaltyPercent_Client 揭示了惩罚的定点数同步（/200）。",
  ],
  41: [
    "--★ 参见 components/health_replica.lua:63 SetPenalty ——",
    "--   内部 assert(penalty >= 0 and penalty <= 1) 并做 ×200 定点化。",
    "--   也就是说 penalty 的上界（0.75）由 tuning.lua:2161 保证，",
    "--   而 replica 侧的 assert 是最后一道防线。",
  ],

  // ── 与 combat.lua 的关系 ──
  3: [
    "--★★ 参见 components/combat.lua 的 panic_thresh 属性 setter ——",
    "--   本文件通过自赋值触发它。同文件 combat.lua:653 是 DoDelta 的主调用方，",
    "--   它把 combat 的 damage 计算结果作为 amount 传入，并消费 DoDelta 的返回值",
    "--   来判定「实际造成的伤害」。",
  ],

  // ── 环境扣血的三条调用链 ──
  616: [
    "--★★ 参见 components/temperature.lua:519（cold）与 :521（hot）、",
    "--   components/hunger.lua:160（hunger）—— 这三处是 nonlethal_* 保护服务的唯一来源。",
    "--   参见 tuning.lua:6834-6837 的 NONLETHAL_TEMPERATURE / NONLETHAL_HUNGER /",
    "--   NONLETHAL_PERCENT 三项默认值。",
  ],
  194: [
    "--★★ 参见 components/burnable.lua 的燃烧更新循环 —— 它是本函数的调用方之一。",
    "--   火焰倍率的另一来源 burnable:GetControlledBurn() 定义在 components/burnable.lua。",
  ],
  229: [
    "--★★ 对比 components/combat.lua:653 的 DoDelta 调用：",
    "--   那里是 `DoDelta(-damage, nil, cause_name, nil, cause)` ——",
    "--   刻意把 cause 放字符串、afflicter 放实体，与本行完全同构。",
    "--   ★ 这是全文件最值得模仿的调用范式。",
  ],

  // ── 死亡流程的事件顺序契约 ──
  585: [
    "--★★★ 参见 entityscript.lua 的 PushEvent / PushEventImmediate ——",
    "--   本行用 PushEvent 是因为实体此刻还有效（只是血量归零）。",
    "--   对比 561 行 OnCorpsingEntitySleep 用的 PushEventImmediate。",
    "--   参见 entityscript.lua 的 ListenForEvent / RemoveEventCallback（本文件 273/295 使用）。",
  ],
  589: [
    "--★ 参见 componentutil.lua:1298 CanEntityBecomeCorpse —— 尸体化资格判定。",
    "--   TheWorld:PushEvent 的定义在 entityscript.lua 的 World 类里。",
  ],
  602: [
    "--★ 参见 simutil.lua:570 ErodeAway —— 淡出实现。",
  ],
  595: [
    "--★ 参见 events / playerdeaths.lua —— 玩家死亡事件的后续统计。",
  ],

  // ── 复活机制 ──
  583: [
    "--★★★【复活相关】health.lua **本身不含任何 revive 接口**。",
    "--   复活由外部完成：revivablecorpse.lua:75 Revive(reviver) 推 \"respawnfromcorpse\"，",
    "--   玩家的复活流程在 components/playercontroller.lua:2212 附近。",
    "--   ★ 为什么放在外部？因为 health 只管「血量归零」，",
    "--     而「复活点是半血还是满血」「复活后是否保留装备」属于玩法规则。",
    "--   ⚠ 但 health.lua 的 583 行「老血 > 0 才触发 death」对复活至关重要：",
    "--     复活流程通常先 SetVal(复活血量) 再做其余，",
    "--     必须确保复活时 currenthealth 已被置为正数，death 事件才不会重放。",
    "--     参见 components/revivablecorpse.lua:11 的 revive_health_percet = 0.5。",
  ],
  550: [
    "--★ 复活时血量通常通过 SetPercent(0.5) 恢复 —— 参见 revivablecorpse.lua 的",
    "--   revive_health_percet 字段（注意原变量名拼写为 percet 而非 percent）。",
  ],

  // ── 存档 ──
  154: [
    "--★ 参见 entityscript.lua 的 GetSaveRecord / OnSave 约定 ——",
    "--   组件的 OnSave 返回表会被合并进实体的存档记录。",
  ],

  // ── modifier 集成（生命惩罚 / 生命上限的第三方修改）──
  468: [
    "--★ 外部施加生命惩罚的入口。搜 prefabs 可找到调用方（如各种战败标记相关实体）。",
    "--   参见 tuning.lua:2161 MAXIMUM_HEALTH_PENALTY = 0.75。",
  ],
  452: [
    "--★ 奖励类道具（如某些食物的「治疗上限」）会读 GetPercentWithPenalty 来决定效果量。",
  ],

  // ── 与 locomotor / stategraph 的联动 ──
  20: [
    "--★ 参见 components/locomotor.lua:1457 ——",
    "--   移动组件每帧检查 `self.inst.components.health:IsDead()`，",
    "--   死掉就立刻 Clear() 中断移动。也就是说「死亡」会通过 health 组件",
    "--   影响 locomotor 的行为，是两个组件之间最直接的一处耦合。",
  ],
  590: [
    "--★ 参见 components/locomotor.lua:1457 的死亡检查与 components/playercontroller.lua",
    "--   的死亡处理，以及 stategraphs/SGwilson.lua 的死亡状态。",
  ],
};

export const AFTER = {};
