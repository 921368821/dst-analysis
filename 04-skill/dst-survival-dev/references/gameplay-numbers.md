# 生存数值调优方法

> 沉淀自《Don't Starve Together》`tuning.lua`（约 9500 行）与四条数值条组件的完整拆解。所有数值均已回到源码核实。

---

## 目录

1. [设计方法论：先定时钟，再定速率](#1-设计方法论先定时钟再定速率)
2. [节段制时钟基准](#2-节段制时钟基准)
3. [衰减速率怎么定](#3-衰减速率怎么定)
4. [四条数值条的调参流程](#4-四条数值条的调参流程)
5. [阈值设计：电平式 + 迟滞](#5-阈值设计电平式--迟滞)
6. [耦合关系矩阵](#6-耦合关系矩阵)
7. [平衡性验证清单](#7-平衡性验证清单)
8. [难度曲线的设计手段](#8-难度曲线的设计手段)
9. [参数表模板](#9-参数表模板)
10. [已核实的基准数值表](#10-已核实的基准数值表)

---

## 1. 设计方法论：先定时钟，再定速率

生存游戏的数值有一条铁律：**所有"随时间变化"的量必须相对于游戏内时钟来定义，不能相对于现实时间。**

### 1.1 三步法

```
第 1 步：定节段（seg）
    SEG_TIME = 30 秒是原子单位
    ↓
第 2 步：定周期
    白天 = 10 段 = 300 秒
    黄昏 = 4 段 = 120 秒
    夜晚 = 2 段 = 60 秒
    全循环 = 16 段 = 480 秒（8 分钟）
    ↓
第 3 步：定速率，用意图表达式写
    "6 天掉满一条理智槽" → 100/(day_time*6)
    "每天需要 75 热量"   → calories_per_day/total_day_time
```

### 1.2 为什么必须用意图表达式

| 写法 | 策划看到时 | 改时钟时 |
|---|---|---|
| `100/(day_time*6)` | 立刻知道"6 天掉满一条" | **自动等比缩放**，语义不变 |
| `0.0556` | 得心算 | **悄悄失衡** |

**更妙的副作用：** 表达式天然暴露了哪些量该归一化、哪些不该。

```lua
DAPPERNESS_MED           = 100/(day_time*6)      -- 速率 → 归一化 ✓
STARVE_KILL_TIME         = 120                    -- 时长 → 裸数字 ✓
STARTING_TEMP            = 35                     -- 物理量 → 裸数字 ✓
INSULATION_MED           = 120                    -- 物理量（与速率无关）→ 裸数字 ✓
```

**判据：** 这个量是"玩家感知的流逝速率/累积量"（应归一化），还是"物理量/时长"（不该归一化）？

### 1.3 ⚠ 必须避开的坑：`day_time` ≠ `total_day_time`

DST 的 `tuning.lua` 里两种分母混用：

| 修辞 | 分母 | 语义 |
|---|---|---|
| `100/(day_time*N)` | 白天（300 秒） | "N 个**白天**"，黑暗时是否生效取决于该常量是否被夜间分支覆盖 |
| `100/(seg_time*N)` | 节段（30 秒） | 与昼夜无关的**恒定**速率 |
| `100/(night_time*N)` | 夜晚（60 秒） | 只在夜间生效 |
| `x/(total_day_time*N)` | 全循环（480 秒） | "N 个整天" |

**同一个概念在不同常量里用不同分母，会造成数量级错觉：**

```lua
DAPPERNESS_MED = 100/(day_time*6)      -- 26.7 理智/天
SANITYAURA_MED = 100/(seg_time*5)      -- 320 理智/天
-- 光环比衣服强约 12 倍！因为分母不同（seg_time=30 vs day_time=300）
```

**规范：在你的代码里显式命名，禁止使用含义模糊的 `day_time`：**

```lua
SEG_SECONDS          = 30
DAY_SECONDS_ACTIVE   = SEG_SECONDS * day_segs      -- 300，"玩家能干活的时间"
NIGHT_SECONDS        = SEG_SECONDS * night_segs    -- 60
TOTAL_CYCLE_SECONDS  = SEG_SECONDS * (day_segs + dusk_segs + night_segs)  -- 480
```

> DST 没做到这点，导致季节变化（昼夜长度改变）时数值漂移。这是十年维护里必然反复踩过的坑——你的实现应该做对。

### 1.4 配平对：让表达式互相抵消

用同一套表达式写出的数值之间可以精确比较，DST 源码里大量出现这种"配平对"：

```lua
MOISTURE_SANITY_PENALTY_MAX = -100/(day_time*6)    -- 全身湿透的理智损失
DAPPERNESS_MED             =  100/(day_time*6)    -- 中等帽子
-- → 一顶 DAPPERNESS_MED 的帽子【精确抵消】全身湿透的理智损失
```

**调优手法：** 当你需要一个道具恰好抵偿某个环境惩罚时，**用同一个表达式写它们**，不要手算数值。这样后续调整任一侧都不会破坏配平。

### 1.5 建议的两层参数表结构

```lua
-- ═══ 第 1 层：设计意图（给人看，单位是"天"/"次"/"度"）═══
TUNE_INTENT = {
    clock = { seg_seconds = 30, day_segs = 10, dusk_segs = 4, night_segs = 2 },

    player = {
        health           = 150,
        hunger_capacity  = 150,
        sanity_max       = 200,
        calories_per_day = 75,
        starve_seconds   = 120,      -- 饥饿归零到饿死
        freezing_seconds = 120,      -- 冻结到致死
    },

    -- 所有"每 N 秒掉满一条"的东西统一写成这个形状
    per_day = {
        dapperness_tiny     = { per_day = 10.7 },
        dapperness_med      = { per_day = 26.7 },
        dapperness_huge     = { per_day = 160  },
        moisture_sanity_max = { per_day = -26.7 },
    },

    -- 光环用"节段"分母，量级与 per_day 不同，必须单列
    per_seg = {
        aura_med = { per_seg = 0.8 },
        aura_huge = { per_seg = 0.05 },
    },

    -- 物理量：不参与归一化
    physical = {
        starting_temp = 35, overheat_temp = 70,
        entity_temp_min = -20, entity_temp_max = 90,
        warm_per_sec = 1, thaw_per_sec = 5,      -- ★ 注意不对称
        moisture_temp_penalty = 30,
    },
}

-- ═══ 第 2 层：编译期换算（给机器看，单位是 /秒）═══
local T = {}
T.SEG_SECONDS = TUNE_INTENT.clock.seg_seconds
T.DAY_SECONDS_ACTIVE = T.SEG_SECONDS * TUNE_INTENT.clock.day_segs
T.NIGHT_SECONDS = T.SEG_SECONDS * TUNE_INTENT.clock.night_segs
T.TOTAL_CYCLE_SECONDS = T.SEG_SECONDS * (day_segs + dusk_segs + night_segs)

for k, v in pairs(TUNE_INTENT.per_day) do
    T[k] = v.per_day / T.TOTAL_CYCLE_SECONDS     -- per_day → 每秒
end
for k, v in pairs(TUNE_INTENT.per_seg) do
    T[k] = v.per_seg / T.SEG_SECONDS
end
for k, v in pairs(TUNE_INTENT.physical) do
    T[k] = v
end
```

**收益：** 平衡讨论直接看第 1 层（全是"天/次/度"）；改时钟时第 1 层不动，第 2 层自动重算。

---

## 2. 节段制时钟基准

DST 的时钟（`tuning.lua:18-30`）：

```
SEG_TIME = 30          -- 原子单位
day_segs   = 10        -- 白天 300 秒（5 分钟）
dusk_segs  = 4         -- 黄昏 120 秒（2 分钟）
night_segs = 2         -- 夜晚  60 秒（1 分钟）
TOTAL      = 480 秒（8 分钟）
```

**为什么夜晚这么短？** 60 秒短到让"熬过一夜"几乎无成本，但 60 秒内若暴露在完全黑暗中会掉 50 点理智。所以夜晚的威胁不是"活不下来"，而是"理智一次性掉一大块 + 可能被影子生物杀"。

**季节修正：** 默认的昼夜比例会随季节变化（源码注释：*"default day composition. changes in winter, etc"*）。**这正是为什么必须显式命名分母——否则季节一变，所有 `/(day_time*N)` 的语义就漂了。**

### 玩家生存时钟全表（以基准角色、标准晴天为例）

| 时刻 | 事件 | 依据 |
|---|---|---|
| 0 秒 | 出门，满饥饿 150 / 满理智 200 / 体温 35 °C | `player_common.lua:2777` |
| 300 秒 | 天黑 | `DAY_TIME` |
| 300–420 秒 | 黄昏（夏季保暖 +60） | `DUSK_TIME` |
| 420 秒 | 全黑 | 夜晚起算于第 14 节段 |
| 420–480 秒 | 夜晚（夏季保暖 +120） | `NIGHT_TIME` |
| **960 秒** | **饥饿归零** | 150 ÷ 0.15625 |
| 420–480 秒 | 无光源则理智流失 0.833×60 = 50 | `SANITY_NIGHT_DARK` |
| 960–1080 秒 | **饿死** | `STARVE_KILL_TIME=120`，1.25 hp/s × 120 = 150 hp |

**关键结论：一个白天+一夜 = 480 秒，恰好是从"满饥饿"到"饿死"周期（960 秒）的 1/2。** 也就是说，不做任何补充的话，你必须在**第 2 个白天开始前**找到食物。

---

## 3. 衰减速率怎么定

### 3.1 四步法

```
第 1 步：从满值到归零需要多少秒？
        这决定"多久必须做一次补给"。这是玩家能直接感知的节奏。
        ↓
第 2 步：归零后多久会死？
        这决定"漏掉一次补给的惩罚"。通常设为归零时间的 1/8 ~ 1/4。
        ↓
第 3 步：补给的量应该是多少？
        让"一次典型补给"能覆盖 第1步×(1/2~2/3) 的时间。
        即：补给频率 ≈ 每 1.5 个周期一次，而不是每天一次。
        ↓
第 4 步：环境惩罚速率取多少？
        让"不处理的惩罚"在 一个完整周期 内可感知但不致命。
        参考：完全黑暗的理智流失 = 全身湿透的 24 倍（0.833 vs 0.0347）
              → 形成清晰的优先级：先解决光源，再解决雨
```

### 3.2 实例：饥饿度

```
容量 = 150
每天所需热量 = 75 热量
WILSON_HUNGER_RATE = 75/480 = 0.15625/s
满到饿 = 150 ÷ 0.15625 = 960 秒 = 2 个整天
饿到死 = STARVE_KILL_TIME = 120 秒
致死速率 = HEALTH / STARVE_KILL_TIME = 150/120 = 1.25 hp/s
```

**食物定价（按每天所需 75 热量反推份数）：**

| 食物 | 热量 | 每天需要几份 |
|---|---|---|
| 浆果 | 9.375 | 8 份 |
| 蔬菜 | 12.5 | 6 份 |
| 肉 | 25 | 3 份 |
| 熟肉 | 37.5 | 2 份 |
| 锅 | 75 | **1 份** |

**平衡洞察：种田的收益是"每天 1 锅"而不是"每天 8 颗浆果"**——烹饪是把低效率食材转化为高效率的关键中转站。**这个换算表是设计食物系统的核心工具。**

### 3.3 实例：理智值（多源累加型）

```lua
rate = dapper_delta + moisture_delta + light_delta + aura_delta + ghost_delta + external
if custom_rate_fn then rate = rate + custom_rate_fn(inst, dt) end
rate = rate * rate_modifier
DoDelta(rate * dt, true)
```

**各来源的量级（/秒）：**

| 来源 | 速率 | 掉光 200 点需要 |
|---|---|---|
| 完全黑暗 | −0.833 | 240 秒 = 半个白天 |
| 夜晚微光 / 中等光 | −0.083 | 2400 秒 = 5 个白天 |
| 白天（有光） | **0**（精确中性） | ∞ |
| 全身湿透 | −0.0347 | ~5800 秒 |
| 戴中等帽 | +0.0347 | —— |
| 戴巨大帽 | +0.2083 | —— |

**三个设计要点：**

1. **白天是精确中性（0），不是正向。** 玩家不会从太阳那里*获得*理智，只是停止流失。
2. **黑暗的流失量是有光的 10 倍**（0.833 vs 0.083）。
3. **服装是缓冲，不是答案。** 一顶 `DAPPERNESS_LARGE` 帽子（+0.0533/s）在完全黑暗中只能抵消约 6% 的流失。玩家必须解决光源本身。

### 3.4 速率的显示分级

UI 上的上升/下降箭头用**离散档位**，且**阈值刻意不对称**——增益比损失更容易被注意到：

```lua
rate > 0.2       → INCREASE_HIGH      -- 大幅上升
rate > 0.1       → INCREASE_MED
rate > 0.01      → INCREASE_LOW
rate < -0.3      → DECREASE_HIGH      -- 大幅下降
rate < -0.1      → DECREASE_MED
rate < -0.02     → DECREASE_LOW
否则             → NEUTRAL
```

**不对称设计：** 上升只需 +0.01 就提示，下降要 -0.02 才提示。让玩家更容易察觉"我变强了"。

### 3.5 `LongUpdate` 的仁慈规则

```lua
function Hunger:LongUpdate(dt)
    self:DoDec(dt, true)          -- ★ ignore_damage = true
end
```

**离线时间会消耗数值条但永远不会杀死你。** 一行代码，值得抄。

同理，理智值的光环累加在 `LongUpdate` 中也要小心：一次性唤醒大量光环源会导致 `Recalc` 被调用上千次。DST 的做法是"一帧内被调用很多次"时用**模块级复用表 + 游标**作为 scratchpad，避免 GC 压力。

**规范：`LongUpdate` 里一律跳过"致死/惩罚类"效果，只保留"衰减类"。**

---

## 4. 四条数值条的调参流程

### 4.1 生命值

```
基准 = 150（角色可覆写）
致死时间（归零到死亡）= 120 秒   × 各种环境原因
致死速率 = MAXHEALTH / KILL_TIME = 150/120 = 1.25 hp/s
```

| 环境原因 | 致死速率 | 从满血到死 |
|---|---|---|
| 饥饿归零 | 1.25 hp/s | 120 秒 |
| 冻结 | 1.25 hp/s | 120 秒 |
| 站在普通火里 | **120 hp/s** | **1.25 秒** |
| 复活惩罚累积 3 次（上限 37.5） | 1.25 hp/s | **30 秒** |

**惩罚系统（乘法累积，不是线性）：**

```lua
MAXIMUM_HEALTH_PENALTY  = 0.75     -- 上限最多缩到 25%
REVIVE_HEALTH_PENALTY   = 0.25     -- 每次复活固定扣 25% 上限
-- 三次复活：150 → 112.5 → 84 → 37.5
```

**平衡洞察：死亡惩罚是螺旋式的，不是线性的。** 三次复活后 `penalty=0.75`，上限变 37.5，此后任何环境伤害都是 30 秒内致死。**唯一的解药是"完全治疗"类道具或死亡重置。** 这是 DST 最狠的一个设计，也是玩家抱怨最多的点——你的实现应当**有意**做这个设计并明确告诉玩家，而不是无意做成螺旋。

**伤害管线的七个有序阶段**（`Health:DoDelta`，顺序不可改）：

```
1. 非致死地板    环境原因（cold/hot/hunger）在 20% 血以下可设为不致命
2. redirect 钩子 函数指针，可吞掉或改道整个 delta（骑乘、格挡）
3. 无敌判定      invincible 或状态标签 temp_invincible，外加 is_teleporting
4. 百分比吸收    废弃的扁平 absorb + 现代的 externalabsorbmodifiers
                  再套 externalreductionmodifiers，以 math.min(0, amount+reduction) 应用
                  ★ 保证减伤永远不会变成治疗
5. deltamodifierfn  最终的任意改写
6. 单次伤害下限  maxdamagetakenperhit（注意符号翻转：对正输入取负）
7. SetVal        钳制、死亡检测、事件广播
```

**⚠ 陷阱：`externalreductionmodifiers` 的守卫条件是 `afflicter ~= nil`。** 也就是说**环境伤害（cold/hot/hunger 这些 afflicter 为 nil 的调用）完全绕过减伤**。所以"减伤 20%"的护符对火/冻/饿无效。这是原版行为不是 bug，但是一个你必须知道的限制。

**副作用的守卫：**

```lua
amount = afflicter ~= nil
     and math.min(0, amount + self.externalreductionmodifiers:Get())
     or amount
```

这里用到了 `and/or` 三元——因为 `math.min(0, ...)` 保证结果 ≤ 0，而 Lua 里 **0 是 truthy**，所以这条恰好安全。但**这是运气好，不是设计好**。你的实现应写显式分支。

### 4.2 饥饿度

```
容量 = 150（组件默认 100，玩家 SetMax(150)）
速率 = 0.15625/s   （× burnrate × burnratemodifiers:Get()）
满到饿 = 960 秒
饿到死 = 120 秒

★ 百分比永远相对 self.max 计算，不是相对 100
★ 会被生命值无敌状态暂停 —— 上帝模式的玩家不会变饿
```

**边缘触发：** `startstarving` / `stopstarving` 在 `current` 跨越 0 时触发（电平式比较，不是百分比）。

**`DoDelta` 语义：**

```lua
if not ignore_invincible and (inst.components.health:IsInvincible() or inst.is_teleporting) then return end
self:SetCurrent(self.current + delta, overtime)
```

**进食后的乘数：**

| 状态 | 标签 | 饥饿乘数 | 生命乘数 |
|---|---|---|---|
| 新鲜 | `fresh` (≥50%) | 1.0 | 1.0 |
| 变质 | `stale` (20–50%) | 0.667 | 0.333 |
| 腐烂 | `spoiled` (<20%) | 0.5 | **0** |

**平衡洞察：腐烂食物的生命乘数是 0——吃腐烂食物不治疗也不扣血，只是营养减半。腐烂本身不会伤你。** 这是宽松的设计：惩罚是"变弱"而非"变危险"。**这个选择值得抄——它避免了"惩罚导致二次死亡"的死亡螺旋。**

### 4.3 理智值

见 §3.3。多源累加型，`Recalc(dt)` 一次算清所有来源。

**光环系统的"同类去重"模式：**

```lua
function SanityAura:SetBaseAuraName(baseauraname)
    -- 同名光环只计一次。假设同名光环量级相同。
    self.baseauraname = baseauraname
end
```

**通用化：「同类计数上限」。** 任何"周围同类实体提供增益"的系统都要回答：100 只猪给 100 份加成还是 1 份？答案几乎总是**后者**，否则效果失控。

```lua
-- 通用骨架：在一次查询内，按 key 去重，每个 key 最多贡献一次
function GatherAuras(query_results, get_group_key, compute_value, aggregate)
    local seen = {}
    local total = 0
    for _, e in ipairs(query_results) do
        local k = get_group_key(e)
        if k ~= nil then
            if not seen[k] then
                seen[k] = true
                total = aggregate(total, compute_value(e))
            end
        else
            total = aggregate(total, compute_value(e))
        end
    end
    return total
end
```

**性能注记：** `seen = {}` 每次调用分配新表会给 GC 造成压力。因为这个函数"一帧内被调用很多次"（每个有 sanity 的实体每帧一次），DST 用模块级复用表 + `ENDPOS` 游标。

> **移植建议：** 如果你的引擎是 .NET/Java（有分代 GC，小对象分配几乎免费），**不要**照抄这个优化，直接用 `HashSet`。如果是 C++/Rust，用栈上的 `SmallVector` 或定长 bitset。

### 4.4 体温

**核心不对称设计：**

```
WARM_DEGREES_PER_SEC = 1    -- 变冷的速率
THAW_DEGREES_PER_SEC  = 5    -- 从冻结回温的速率（快 5 倍）
```

**"惩罚"与"挫败"的区别就在这里：** 一旦你找到火，5 °C/s 的速度足以让你在 20 秒内脱离死亡螺旋。**任何生存游戏都应该是"找到解法后快速脱离痛苦"，而不是"持续缓慢消耗"。**

**环境温度的累加顺序（10 个阶段，顺序不可改）：**

```
0. 确定环境温度与所在容器（口袋维度用世界温度，不做空间查询）
1. 环境温度 = 温度覆盖器 → 地热场 → 世界状态温度
2. 修饰器总量（手写带键增删表，比 SourceModifierList 更便宜）
3. 潮湿惩罚 = -Lerp(0, 30, moisturePercent)
4. 遮蔽（sheltered_level > 1 把环境温度钳到 overheattemp - 5）
5. 已装备取暖物 → 手持取暖物 → 溢出容器 → 光标上的物品
6. 腹中（最近吃下的冷/热食物，受阈值门控）
7. 树荫降温
8. 世界取暖物（篝火等，用 FindEntities 找 HASHEATER 标签）
9. 保暖钳制 —— 保暖只抵抗危险的方向
10. 积分 + 扣血
```

**第 9 阶段的手感核心：**

```lua
if ambient_temperature >= STARTING_TEMP then
    -- 暖和：夏季保暖只抵抗变热
    if self.delta > 0 then
        self.rate = math.min(self.delta, SEG_TIME / (SEG_TIME + summerInsulation))
    else
        self.rate = math.max(self.delta,
            self.current >= overheattemp and -THAW_DEGREES_PER_SEC or -WARM_DEGREES_PER_SEC)
    end
elseif self.delta < 0 then
    -- 冷：冬季保暖抵抗变冷
    self.rate = math.max(self.delta, -SEG_TIME / (SEG_TIME + winterInsulation))
else
    self.rate = math.min(self.delta,
        self.current <= 0 and THAW_DEGREES_PER_SEC or WARM_DEGREES_PER_SEC)
end
```

**两条不对称规则：**
1. **冬季保暖只在冷的时候起作用，夏季保暖只在热的时候起作用**
2. **从冻结回温是 5 °C/s，从正常变冷是 1 °C/s**

**第 8 阶段：潮湿让火更糟，同时让吸热（冷）火更好。**

```lua
if self.inst:GetIsWet() then
    if heat > 0 then heatfactor = heatfactor * heat_factor_penalty        -- 0.75，潮湿时火弱
    elseif heat_factor_penalty ~= 0 then heatfactor = heatfactor / heat_factor_penalty end  -- 潮湿时制冷强
end
```

**冬季失温时间线（环境 −20 °C，体温 35 °C）：**

| 配置 | 变冷速率 | 到 0 °C | 死亡 |
|---|---|---|---|
| 无保暖 | −1.0 °C/s（受速率上限限制，不是 55） | 35 秒 | **155 秒** |
| 一件 LARGE(240) | −30/(30+240) = −0.111 °C/s | 315 秒 | 435 秒 |
| 两件 LARGE(480) | −30/(30+480) = −0.059 °C/s | 595 秒 | 715 秒 |

**规范：计算"环境 - 当前"的差值后，必须用速率上限钳制。** 否则 −55 °C/s 会让玩家瞬间冻死，保暖装备完全失去意义。

### 4.5 湿度

```
上限 = 100（5 格）
变湿速率 max = 0.75/s    → 133 秒全身湿透
自然干燥 max = 0.1/s     → 1000+ 秒才能干
火边干燥 ≈ 5/s           → 20 秒干透
```

**湿度时间线（下雨，无保暖，降水率 1.0）：**
```
t=0       湿度 0
变湿速率 = inSine(1.0, minMoistureRate, 0.75, 1) × (1 − 0) = 0.75/s
          100 / 0.75 = 133 秒全身湿透
湿透后（雨停）：
  环境 −20 °C → 有效环境 = −20 − 30 = −50 °C
带火（externalheaterpower=1, 环境 25 °C）：
  ≈ 5 + 0.05 + 0.1 ≈ 5/s → 20 秒干透
```

**平衡洞察：湿透后站着不动是死亡螺旋，站在火边 20 秒就解决。** 极端的"好解决"，这是 DST 手感的核心。

**复合缓动的用法：** 湿度对理智的影响用 `inSine` 缓动（`easing.inSine(moisture, 0, MAX_PENALTY, maxMoisture)`），所以**微微潮湿时几乎不掉，彻底湿透时才崩塌**。这个缓动是"惩罚可控"的关键。

**干燥速率依赖 `externalheaterpower`**，而后者是在温度累加的第 8 阶段累加的——**这是一个干净的单向依赖（温度 → 湿度），不要打破它。**

---

## 5. 阈值设计：电平式 + 迟滞

### 5.1 电平式而非百分比式

阈值应基于**绝对值（电平）**，不是百分比：

```lua
-- ✅ 正确
self.lo_threshold = 0           -- temperature 的冻结点
self.hi_threshold = 70          -- overheattemp
if self.current < 0 then health:DoDelta(-hurtrate*dt, true, "cold")
elseif self.current > overheattemp then health:DoDelta(-hurtrate*dt, true, "hot") end

-- ❌ 错误：百分比会随 max 变化而漂移
if self:GetPercent() < 0.1 then ... end
```

### 5.2 迟滞（双阈值）

**跨越阈值时触发事件，而不是"在阈值上"触发：**

```lua
-- 电平式比较
if (newval < self.lo_threshold) ~= (old < self.lo_threshold) then
    self.inst:PushEvent(newval < self.lo_threshold and self.enter_event or self.exit_event)
end
```

**有状态的双阈值（进出不同门）：**

```lua
SANITY_BECOME_INSANE_THRESH    = 30/200 = 15%    -- 进入疯癫
SANITY_BECOME_SANE_THRESH      = 35/200 = 17.5%  -- 脱离疯癫
SANITY_BECOME_ENLIGHTENED_THRESH     = 170/200 = 85%     -- 进入"清醒"
SANITY_LOSE_ENLIGHTENMENT_THRESH     = 165/200 = 82.5%   -- 掉出"清醒"
```

**没有迟滞会怎样：** 理智在 30 点附近反复横跳 → 影子生物反复刷出/销毁 → 每帧触发刷怪检查 + 寻路 → 视觉刺眼且 CPU 浪费。

**同样的规则适用于 AI 的所有距离判断：**

| 判断 | 触发阈值 | 停止阈值 |
|---|---|---|
| `RunAway` | 看到 3 距离就逃 | 到 6 才停止 |
| `Leash` | > 30 启动回家 | < 10 才算到家 |
| `Follow` | `max_dist` → APPROACH | `min_dist` → BACKOFF，`target_dist` → 成功 |
| `Wander` | 超出 `max_dist` 改为回家 | 回到范围内恢复闲逛 |

**规范：迟滞是硬性要求，不是优化。** 单阈值会导致生物在边界抖动，每帧触发一次寻路请求。

### 5.3 攻击范围的双距离

战斗系统里有两个独立的距离：
- **攻击范围**（`attackrange`）：能否打到
- **转向/跟随范围**（`followrange`）：是否去追

`CalcDamage` 里的组合写法（注意 `and/or` 优先级）：

```lua
return weapon ~= nil and weapon.components.weapon.attackrange ~= nil
    and math.max(0, self.attackrange + weapon.components.weapon.attackrange)
    or self.attackrange
```

**这里恰好安全**因为 `math.max(0, ...)` 的结果 ≥ 0，而 Lua 里 0 是 truthy。**但这是运气。** 你的实现应写显式分支：

```lua
local range = self.attackrange
if weapon ~= nil and weapon.components.weapon ~= nil
   and weapon.components.weapon.attackrange ~= nil then
    range = math.max(0, self.attackrange + weapon.components.weapon.attackrange)
end
return range
```

---

## 6. 耦合关系矩阵

**这是数值调优时最容易被忽略的部分——一条数值改动会通过这张表产生连锁反应。**

| 源 | 目标 | 机制 | 系数/上限 |
|---|---|---|---|
| 湿度 | 体温 | 全身湿透时环境温度最多再降 | 30 °C |
| 湿度 | 理智 | 带 `inSine` 缓动的持续流失 | `MOISTURE_SANITY_PENALTY_MAX` |
| 潮湿 | 取暖效率 | 湿着烤火，取暖效率差 | × 0.75 |
| 潮湿 | 制冷效率 | 湿着靠近冷源，制冷更强 | ÷ 0.75 |
| 潮湿 | 电击伤害 | `ELECTRIC_WET_DAMAGE_MULT × GetWetMultiplier()` | 随湿度 |
| 潮湿 | 易腐品 | 腐败速率乘数 | × 1.3 |
| 潮湿 | 装备 | 每件湿装备 −0.1 风度；湿度 ≥4/5 格时工具打滑 | −0.1 |
| 湿度 | 干燥 | 体温组件累加的 `externalheaterpower` 决定干燥速率 | 单向依赖 |
| 饥饿 = 0 | 生命 | `hurtrate = 150/120` | 1.25 hp/s |
| 体温 < 0 / > 70 | 生命 | `hurtrate = HEALTH/FREEZING_KILL_TIME` | 1.25 hp/s |
| 理智 < 15% | 战斗 | 影子生物刷出并攻击 | 阈值 15% |
| 生命 | 战斗 | `panic_thresh` → 封锁目标选择 | 约 1/3 血量 |
| 生命 | 制作 | `MAX_HEALTH` 类材料是永久 0–75% 惩罚 | 0.75 |
| 死亡队友数 | 理智 | 每个幽灵抽干活着的人，被幽灵比例二次方阻尼 | 上限 ×3 |
| 光照 | 理智 | 黑暗 vs 微光 | 10 倍差距 |
| 光环 | 理智 | 同名光环只计一次 | 去重 |

**调优操作清单：**

改任何一个速率前，先在这张表里查一遍：
1. 它是别的系统的**输入**吗？（改了会影响下游）
2. 它是别的系统的**输出**吗？（改了上游会不会突然不合理）
3. 它的影响是**线性**还是**有阈值**？（阈值型会产生悬崖式体验）
4. 有没有**配平对**需要同步调整？

**特别是"温度 → 湿度"这条链是单向的**：修改温度累加时不要引入对湿度的反向读取，否则会产生振荡。

---

## 7. 平衡性验证清单

### 7.1 时间线验证（每个数值条都要算一遍）

对每条数值条，手算这四个时间点：

```
T1 = 满值 → 归零            （补给节奏）
T2 = 归零 → 死亡            （漏补给的惩罚）
T3 = 一次典型补给能覆盖的时间 （补给效率）
T4 = 一个完整昼夜循环内的净变化（节奏感）
```

**示例（饥饿）：** T1=960s，T2=120s，T3=一次浆果 9.375 热量 = 60 秒（一天需 8 颗），T4=480s 内 -75 热量。

**判定标准：**
- T1 应 ≈ 1.5–2 个完整循环（玩家必须每隔一天半补给一次）
- T2 应 ≈ T1/8 ~ T1/4（漏一次补给不至于立刻死，但明确感到压力）
- T3 应 ≈ T1/2（一次补给覆盖半个周期，留有余裕）

### 7.2 场景验证（极端情况）

| 场景 | 期望 | 检查方法 |
|---|---|---|
| 全裸无任何装备，标准白天 | 能撑过至少 1 个白天 | 手算或写个模拟脚本 |
| 全裸过冬夜 | 应该在 T1~T2 之间死亡，不是立刻死 | 检查变冷速率是否被钳制 |
| 站在普通火里 | 应该 1–3 秒内致命（不能是慢慢烧死） | 检查火伤速率上限 |
| 连续复活 3 次 | 应该进入"30 秒内任何环境伤害致死"的螺旋 | 检查惩罚是乘法还是加法 |
| 完全黑暗站 35 秒 | 应该刚好触及疯癫阈值 | 阈值 / 黑暗速率 ≈ 35 |
| 全身湿透 + 冬季无火 | 应该进入死亡螺旋 | 检查两者的叠加是否可逆 |
| 满食物 + 满理智 | 应该能连续活 2 天 | T1 × 2 |

### 7.3 数值安全检查

```
□ 所有除法都有分母非零守卫
□ 所有 min/max 钳制的上下界不是 NaN
□ 所有速率乘数都有上限（防止指数爆炸）
□ 所有百分比计算的分母是 self.max 而非硬编码 100
□ 所有阈值都是电平式（绝对值）而非百分比式
□ 所有跨状态切换都有迟滞双阈值
□ LongUpdate 路径不产生致死效果
□ 累加器的输入有数量上限（例如同时生效的 buff < 10）
```

### 7.4 手感验证（最难但最重要）

```
□ 找到一个解法后，脱离痛苦的时间 < 20 秒
   （回温 5 °C/s vs 变冷 1 °C/s；火边干身 5/s vs 自然 0.1/s）
□ 犯错的惩罚是"变弱"而非"立刻死"
   （腐烂食物生命乘数 = 0 而非负数）
□ 优先级清晰可辨
   （黑暗 24 倍于湿透 → 玩家自然先解决光源）
□ 一次失败的代价可承受，但连续失败不可承受
   （T2 = 120 秒够玩家跑回营地）
```

---

## 8. 难度曲线的设计手段

### 8.1 手段一：时间梯度

| 手段 | 做法 | DST 的例子 |
|---|---|---|
| 递增消耗 | 后期速率更快 | 冬季保暖需求随季节上升 |
| 递增阈值 | 后期环境更极端 | 冬季温度从 0 降到 −20 |
| 递增危险 | 后期事件更致命 | 影子生物数量随理智阈值分档（>50%→0，>10%→1，否则→2） |
| 递增惩罚 | 死亡代价随次数上升 | 复活惩罚乘法累积 |

### 8.2 手段二：地理梯度

**DST 的 `story_depth` 机制：** 距离出生点越远的任务，解锁的东西越"后期"（`KEYS.TIER4`/`TIER5`）。**地图的地理距离 ≈ 进度。**

```
maxdepth = max(node.story_depth for node in rootNode:GetChildren())
partSpread = maxdepth / #parts
-- 把第 n 个场景件挂到 story_depth ≈ ceil(n * partSpread) 的任务上
```

**⚠ 更好的做法：记录图上的真实 BFS 距离，而不是用计数器。**

```python
dist[startNode] = 0
queue = [startNode]
while queue:
    n = queue.pop()
    for m in neighbors(n):
        if m not in dist:
            dist[m] = dist[n] + 1
            queue.append(m)
```

**`story_depth` 计数器在"分支多"的模式下会严重失真**（所有新内容都挂到最浅节点，深度增长极慢）。真实 BFS 距离不受分支策略影响。

### 8.3 手段三：资源梯度

用**加权抽样的稀疏度**控制不同区域的资源密度，而不是均匀撒：

```lua
-- 需求 = countprefabs 数量 × (1/distributepercent)
if #points_x < math.floor(pos_needed) then
    -- ★ 静默放弃整个节点（DST 的真实弱点）
end
```

**设计手法：** 早期区域 `distributepercent` 高（密集、好找），后期区域低（稀疏、需要规划路线）。

### 8.4 手段四：锁—钥匙图（同时也是可达性保证）

**这是"难度曲线"与"地图结构"的交点：**

```
每个锁声明它需要哪些钥匙
钥匙只能从"更早的任务"获得
→ 玩家被迫按拓扑序推进
→ 难度天然递增（后面的任务需要更多准备）
```

**校验：** 生成后检查每个锁的钥匙都可达（沿图搜索），任一不可达则重生成。

### 8.5 难度曲线的自检

```
□ 第 1 天：应该能靠基础资源活下来（采集即可）
□ 第 2 天：应该需要一个小的"技术突破"（建篝火 / 种田）
□ 第 3 天：应该需要一次远征（探索洞穴 / 找关键材料）
□ 第 5 天以后：应该开始依赖前面积累的设施
□ 难度上升应该来自【要求变多】而不是【数值突然变狠】
□ 惩罚应该来自【资源不足】而不是【突然的即死】
```

**核心原则：难度曲线的斜率应该来自玩家自己的准备不足，而不是系统的数值跳跃。** 当玩家觉得"太难"时，先检查是不是缺少"做准备"的空间，而不是直接把系数调高。

---

## 9. 参数表模板

**新建一个内容时，用这张表把所有数值写清楚。**

```markdown
## <内容名> 数值表

### 身份
| 项 | 值 | 来源/理由 |
|---|---|---|
| prefab 名 | | 必须全局唯一 |
| 标签 | | mob / hostile / canmove / 可食性 |
| 所属阵营 | | 用于仇恨判定 |

### 生存数值
| 数值条 | 容量 | 速率 | 致死时间 | 备注 |
|---|---|---|---|---|
| 生命 | | | | |
| 饥饿 | | | | |
| 理智 | | | | |
| 体温 | | | | |

### 移动与战斗
| 项 | 值 | 备注 |
|---|---|---|
| 行走速度 | | |
| 奔跑速度 | | |
| 攻击伤害 | | |
| 攻击间隔 | | 冷却 |
| 攻击范围 | | 与跟随范围区分 |
| 跟随范围 | | **双带：>max 追，<min 退** |
| 脱战半径 | | **双带：>30 回家，<10 算到家** |

### AI 决策
| 项 | 值 | 备注 |
|---|---|---|
| 脑 period | | 猎物 0.25s / 村民 0.5s / Boss 1s |
| 转向频率 | | **≥ period 的 3–8 倍** |
| 初始相位 | | `period*(0.5+random())` |
| 战斗坚持时间 | | `ChaseAndAttack(max_time, give_up_dist)` |
| 逃跑触发/停止距离 | | 双带 |

### 掉落
| 项 | 值 | 备注 |
|---|---|---|
| 掉落物 | | 概率 |
| 掉落数量 | | 范围 |
| 击杀奖励 | | 经验/分数 |

### 存档
| 项 | 说明 |
|---|---|
| 是否持久化 | `persists` |
| 需要保存的字段 | 脑的目标状态、战斗目标 |
| 是否需要引用 | 若引用其他实体，需在 `OnSave` 返回引用列表 |
| 版本兼容 | 加 `add_component_if_missing` |

### 网络
| 项 | 说明 |
|---|---|
| 是否 AddNetwork | 必须在 SetPristine 之前 |
| netvar 列表 | 字段名 + 类型 + 脏事件名 |
| 类型选择依据 | 取值范围 → 位宽 |
| 是否 classified | 私密状态需单独实体 |

### 平衡验证
| 检查项 | 结果 |
|---|---|
| 从满值到归零的时间 | |
| 归零到死亡的时间 | |
| 一次补给覆盖的时间 | |
| 一个循环内的净变化 | |
| 强度 vs 同阶段其它内容 | |
| 最优/最差操作下的表现 | |
```

---

## 10. 已核实的基准数值表

以下全部来自 `tuning.lua` 及相关组件的实测，可作为设计新内容时的**参照系**。

### 10.1 时钟与节律

| 常量 | 值 | 出处 |
|---|---|---|
| `SEG_TIME` | 30 | `tuning.lua:62` |
| `DAY_TIME` | 300 秒 | 推导 |
| `DUSK_TIME` | 120 秒 | 推导 |
| `NIGHT_TIME` | 60 秒 | 推导 |
| `TOTAL_DAY_TIME` | 480 秒 | 推导 |
| `DUSK_INSULATION_BONUS` | 60 | 原文引用 |
| `NIGHT_INSULATION_BONUS` | 120 | 原文引用（相当于一件中等保暖） |

### 10.2 玩家基准

| 常量 | 值 |
|---|---|
| `wilson_attack` | 34 |
| `wilson_health` | 150 |
| `wilson_hunger`（胃容量） | 150 |
| `wilson_sanity` | 200 |
| `calories_per_day` | 75 |
| `wilson_attack_period` | 0.4 |
| `MAXITEMSLOTS` | 15 |
| `EQUIPSLOTS` | HANDS / HEAD / BODY / BEARD |

### 10.3 生命值

| 常量 | 值 | 备注 |
|---|---|---|
| `STARVE_KILL_TIME` | 120 | 饿 2 分钟死 |
| `FREEZING_KILL_TIME` | 120 | 冻 2 分钟死 |
| `MAX_FIRE_DAMAGE_PER_SECOND` | 120 | **站火里 1.25 秒掉光全部血** |
| `MAXIMUM_HEALTH_PENALTY` | 0.75 | 复活后上限最多缩到 25% |
| `REVIVE_HEALTH_PENALTY` | 0.25 | 每次复活固定扣 25% |
| `NONLETHAL_PERCENT` | 0.2 | 环境伤害可设为不致命的血量百分比 |

### 10.4 饥饿与食物

| 常量 | 值 |
|---|---|
| `WILSON_HUNGER_RATE` | 75/480 = 0.15625/s |
| 满到饿 | 960 秒 = 2 天 |
| `CALORIES_TINY`（浆果） | 9.375 |
| `CALORIES_SMALL`（蔬菜） | 12.5 |
| `CALORIES_MED`（肉） | 25 |
| `CALORIES_LARGE`（熟肉） | 37.5 |
| `CALORIES_HUGE`（锅） | 75 |
| `STALE_FOOD_HUNGER` | 0.667 |
| `STALE_FOOD_HEALTH` | 0.333 |
| `SPOILED_FOOD_HUNGER` | 0.5 |
| `SPOILED_FOOD_HEALTH` | 0 |

### 10.5 理智值

| 常量 | 值 | 人类读法 |
|---|---|---|
| `DAPPERNESS_TINY` | `100/(day_time*15)` | 10.7 理智/天 |
| `DAPPERNESS_SMALL` | `100/(day_time*10)` | 16.0 /天 |
| `DAPPERNESS_MED` | `100/(day_time*6)` | 26.7 /天 |
| `DAPPERNESS_MED_LARGE` | `100/(day_time*4.5)` | 35.5 /天 |
| `DAPPERNESS_LARGE` | `100/(day_time*3)` | 53.3 /天 |
| `DAPPERNESS_HUGE` | `100/(day_time)` | 160 /天 |
| `SANITYAURA_MED` | `100/(seg_time*5)` | 320 理智/天（**分母不同，量级差 12 倍**） |
| `MOISTURE_SANITY_PENALTY_MAX` | `-100/(day_time*6)` | −26.7 /天 |
| `SANITY_NIGHT_DARK` | `-100/(night_time*2)` | −0.833/s |
| `SANITY_NIGHT_LIGHT` | `-100/(night_time*20)` | −0.083/s |
| `SANITY_DAY_GAIN` | 0 | 白天精确中性 |
| `SANITY_HIGH_LIGHT` | 0.6 | |
| `SANITY_LOW_LIGHT` | 0.1 | |
| `SANITY_BECOME_INSANE_THRESH` | 30/200 = 15% | |
| `SANITY_BECOME_SANE_THRESH` | 35/200 = 17.5% | 迟滞 |
| `SANITY_BECOME_ENLIGHTENED_THRESH` | 170/200 = 85% | |
| `SANITY_LOSE_ENLIGHTENMENT_THRESH` | 165/200 = 82.5% | 迟滞 |
| `MAX_SANITY_GHOST_PLAYER_DRAIN_MULT` | 3 | |
| `SANITY_EFFECT_RANGE` | 10 | |
| `SANITY_AURA_SEARCH_RANGE` | 20 | |
| `WET_ITEM_DAPPERNESS` | −0.1 | |

### 10.6 体温与湿度

| 常量 | 值 |
|---|---|
| `STARTING_TEMP` | 35 |
| `OVERHEAT_TEMP` | 70 |
| `MIN_ENTITY_TEMP` | −20 |
| `MAX_ENTITY_TEMP` | 90 |
| `WARM_DEGREES_PER_SEC` | 1 |
| `THAW_DEGREES_PER_SEC` | **5** |
| `MOISTURE_TEMP_PENALTY` | 30 |
| `WET_HEAT_FACTOR_PENALTY` | 0.75 |
| `PERISH_WET_MULT` | 1.3 |
| 湿度上限 | 100（5 格） |
| `maxMoistureRate` | 0.75/s |
| `maxDryingRate` | 0.1/s |
| `maxPlayerTempDrying` | 5/s |
| `optimalPlayerTempDrying` | 2/s |
| `optimalDryingTemp` | 50 °C |

### 10.7 护甲

| 装备 | 耐久 | 吸收率 | 每次满耐久可承伤 |
|---|---|---|---|
| 草甲 | 157.5 | 0.60 | 262 原始伤害 |
| 木甲 | 315 | 0.80 | 394 |
| 橄榄球头盔 | 315 | 0.80 | 394 |
| 大理石甲 | 735 | 0.95 | 774 |
| 石化甲 | 1260 | 0.90 | 1400 |
| `multiplayer_armor_durability_modifier` | 0.7 | 多人时耐久 × 0.7 |
| `multiplayer_armor_absorption_modifier` | 1 | 多人时吸收不变 |

**护甲破损门槛（`GetAbsorption` 返回 nil 时该护甲完全不参与吸收）：**

```lua
-- ★ 移植到强类型语言时必须显式过滤 nil
-- Lua 里 t[k]=nil 等价于删键，所以 pairs 不会遍历到它（安全）
-- 但 Dictionary<Armor, float?> 会把 null 算进 max 里 —— 这是最容易踩的坑之一
for armor, amt in pairs(absorbers) do
    if amt == nil then goto continue end     -- ★ 强类型语言必须显式写这行
    absorbed_percent = math.max(amt, absorbed_percent)
    total_absorption = total_absorption + amt
    ::continue::
end
```

### 10.8 驯服与服从

| 常量 | 表达式 | 人类读法 |
|---|---|---|
| `BEEFALO_DOMESTICATION_GAIN` | `1/(480*20)` | 20 天满驯化 |
| `OBEDIENCE_DECAY_RATE` | `-1/(TOTAL_DAY_TIME*2)` | 2 天掉满服从 |
| `FEEDBACK_DECAY_RATE` | `-1/(TOTAL_DAY_TIME*45)` | 45 天淡出倾向 |

**设计洞察：** `OBEDIENCE_DECAY_RATE`（2 天掉满）比 `DOMESTICATION_GAIN`（20 天满）快 10 倍。**驯服是长期投资，但维护成本很高**——玩家必须持续喂养，否则宠物会跑掉。
