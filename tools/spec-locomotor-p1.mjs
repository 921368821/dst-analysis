// spec-locomotor-p1.mjs —— locomotor.lua 深度注释规格 第 1 部分
// 覆盖：文件头 → Dest 目的地类 → 双端函数分派 → Class 构造与 setter
// 锚点范围：1 ~ 330

export const BEFORE = {
  // ══════════════════════════════════════════════════════════════
  // 零、被注释掉的常量 —— 历史遗留的「关闭的性能优化」
  // ══════════════════════════════════════════════════════════════
  1: [
    "--★ 本文件唯一的 require：SourceModifierList（util/sourcemodifierlist.lua:8）。",
    "--   它只用在 548-565 行的「客户端预测用外部倍率」上——",
    "--   也就是说这个容器**只存在于客户端**，服务端不创建。",
  ],
  3: [
    "--⚠【被注释掉的 DOZE_OFF_TIME】原意是「连续移动多久后允许休眠（doze）」。",
    "--   现在改由实体自身的 dormancy 机制控制（见 update.lua 的休眠判定），",
    "--   locomotor 不再参与。保留注释是历史记录。",
  ],
  5: [
    "--⚠【被注释掉的 PATHFIND_PERIOD / PATHFIND_MAX_RANGE】",
    "--   ★ 这两条揭示了寻路策略的演进史：",
    "--     · PATHFIND_MAX_RANGE —— 曾限制「只对 40 格内的目标寻路」，",
    "--       现在无限制（1815 行的对应检查也被注释掉了）。",
    "--       放开的原因是玩家会要求「走到地图另一边」，硬限制会导致走不到。",
    "--     · PATHFIND_PERIOD —— 曾用于「每 1 秒才重新寻路一次」以省 CPU，",
    "--       现在改为「每帧都可能重新提交搜索」+「同目标地块去重」（1832 行 lastdesttile）。",
    "--       用空间去重代替时间节流，既不浪费 CPU 也不牺牲正确性。",
    "--   ★★ 这个演进是本文件性能设计的关键：见 1824 行的 lastdesttile 去重。",
  ],
  8: [
    "--★★★【寻路状态机的三个状态】0=计算中、1=找到路径、2=没找到。",
    "--   ★ 关键设计：STATUS_NOPATH(2) 被注释掉了，",
    "--     而 1552 行对 `pathstatus == nil` 做了单独处理（视为「搜索句柄丢失」）。",
    "--   ★★ 也就是说本文件只区分「还在算」与「算完了」两种状态；",
    "--     「算完了但没路」与「算丢了」都走 1551 的 else 分支，只打调试日志。",
    "--     这是刻意的降级：无路可走时最合理的做法是「直冲过去让物理挡住」，",
    "--     而不是停下。参见 1838 行 IsClear 为真时的 ResetPath。",
  ],
  12: [
    "--★★ ARRIVE_STEP = 0.15 —— 「到达」判定的基准半径（0.15 格）。",
    "--   数值极小，说明到达判定主要靠各处的 arrive_dist（通常 2~4 格），",
    "--   ARRIVE_STEP 只是「两实体半径之和都拿不到」时的兜底值。",
  ],
  14: [
    "--★ MOVE_TIMER_STOP_THRESHOLD = 0.3 秒 —— 「移动计时器」的迟滞阈值。",
    "--   短于 0.3 秒的停顿**不重置**移动计时器，理由见 403-412 行。",
  ],
  16: [
    "--★★ INVALID_PLATFORM_ID = \"INVALID PLATFORM\" —— 一个刻意不可能与实体相等的哨兵值。",
    "--   ★ 用途：last_platform_visited 的初始值。因为 Lua 表可以用任意值作 key，",
    "--     用字符串哨兵比用 nil 更安全（nil 无法作为「已访问过」的有效区分）。",
    "--   ★ 为什么不用实体？因为哨兵必须保证「不等于任何平台实体」，",
    "--     字符串常量天然满足。参见 1084 与 1203 行的初始化。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 一、Dest：目的地抽象
  // ══════════════════════════════════════════════════════════════
  18: [
    "--★★★【Dest 类：把「三种目的地」统一成一个对象】",
    "--   支持三种目标：",
    "--     ① 实体（inst）      —— 「走到这个东西旁边」",
    "--     ② 点（pt）          —— 「走到这个坐标」",
    "--     ③ 缓冲动作（buffered_action）—— 「走到这个动作的执行点」",
    "--   ★★ 设计动机：让 locomotor 的所有后续代码（OnUpdate、GetPlatform、",
    "--     到达判定）只需处理一种类型，不必到处写「如果是实体就取位置，",
    "--     否则如果是点就……」。这是最典型的「多态消除分支」手法。",
    "--   ⚠ 注意它是全局变量（没有 local），这是刻意的——",
    "--     因为模组与 stategraph 需要构造 Dest（search prefabs 见 `Dest(` 的外部用法）。",
    "--   ⚠ 但全局命名有污染风险，DST 里 Dest 是保留名。",
  ],
  20: [
    "--★ pt 为 nil 时不赋值 —— 保持 nil 语义，便于 GetPoint 的 else if 链。",
  ],
  23: [
    "--★ 三选一构造：不同调用方（GoToEntity / GoToPoint）填不同的组合。",
  ],
  "Dest:IsValid#1": [
    "--★★【IsValid：实体会被销毁，所以每帧都要重验】",
    "--   `self.inst == nil or self.inst:IsValid()` ——",
    "--   注意是「inst 为 nil 也算有效」（那意味着目标是个坐标点，永远有效）。",
    "--   ★ 这是「跟踪移动目标」的根本需求：目标被吃掉/摧毁后必须停止跟随。",
    "--   ★ OnUpdate:1452 每帧调它；GoToEntity 走的 path 会指向一个已消失的实体。",
  ],
  "Dest:__tostring#1": [
    "--★ __tostring 只服务调试输出（GetDebugString:1159 打印它）。",
    "--   ★ 优先级顺序：实体 > 点 > 动作点 > 无，恰好是构造的常见度顺序。",
  ],
  "Dest:GetPoint#1": [
    "--★★★【GetPoint：目的地的世界坐标】",
    "--   四条路径：有效实体 → 点的当前值 → 动作点 → 兜底 (0,0,0)。",
    "--   ⚠⚠ 兜底 (0,0,0) 是危险默认值：若三个字段都为 nil，",
    "--     实体会朝**世界原点**走去。应视为「构造错误」而非正常分支。",
    "--     强类型移植时应该返回 Optional 或抛异常。",
    "--   ★ 注意实体分支要求 IsValid()：无效实体走不到这里（会落到 elseif pt）。",
  ],
  "Dest:GetPoint#1+2": [
    "--★ 取实体的世界位置。移动目标每帧都在动，所以不能缓存。",
  ],
  "Dest:GetPoint#1+6": [
    "--★ 动作点的解析：GetActionPoint 返回 Point 对象，:Get() 才拿到 x,y,z。",
  ],
  "Dest:GetPlatform#1": [
    "--★★★【GetPlatform：目的地的「平台」归属 —— 跳跃逻辑的关键输入】",
    "--   为什么要知道目的地的平台？因为跳跃必须判断「目标是否在另一块平台上」。",
    "--   1719-1730 的 hopping 分支全靠这个判定。",
    "--   ⚠ 第一条分支的判定链很关键：目标实体在别人背包里（inventoryitem.owner 非 nil）",
    "--     → 返回**持有者**的平台。",
    "--     ★★ 这解决了「捡起一个放在船上的物品，走过去」的场景：",
    "--     物品随船移动，所以目标平台是船而不是地面。",
  ],
  "Dest:GetPlatform#1+1": [
    "--★ 三重 nil 守卫：实体存在 + 有 inventoryitem 组件 + 物品在背包里。",
  ],
  "Dest:GetPlatform#1+6": [
    "--★ 目标是坐标点时，用地图查询该点的平台。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 二、双端函数分派（server / client 各一套同名实现）
  // ══════════════════════════════════════════════════════════════
  "onrunspeed#1": [
    "--★★★【双端 setter：把 netvar 写入包在 nil 守卫里】",
    "--   `if self.inst.player_classified ~= nil` ——",
    "--   ★ player_classified 只在**玩家**上存在，而且是 C++ 侧分类对象。",
    "--     非玩家实体（怪物、物品）走这里会静默跳过——因为它们的速度不需要给客户端看",
    "--     （客户端只能看到自己控制的玩家和被网络同步的生物的粗略位置）。",
    "--   ★ 这是「同端同构、异端分派」模式的一个小切片：见 266 行构造函数的整体设计。",
  ],
  "ServerRunSpeed#1": [
    "--★★★【ServerRunSpeed：骑乘时用坐骑的速度】",
    "--   实体本身的 runspeed 在骑乘时被完全忽略，改用 mount.components.locomotor.runspeed。",
    "--   ★ 语义：骑马时你的速度是马的速度，不是你的速度。",
    "--   ★ 严格要求 mount 非 nil 才取——挂载物（boat）也有 locomotor 组件，所以统一取法。",
    "--   ★ 走的是服务端路径：骑乘关系（rider 组件）只有服务端权威。",
  ],
  "ServerRunSpeed#1+7": [
    "--★ 兜底：没骑乘就是自己的 runspeed。",
  ],
  "ClientRunSpeed#1": [
    "--★★★【ClientRunSpeed：客户端版本的三层取法】",
    "--   ① 骑乘 → 走**复制组件** replica.rider:IsRiding()，",
    "--      再调 rider:GetMountRunSpeed()（不是 mount.components.locomotor.runspeed！",
    "--      因为客户端上 mount 的 components 是 nil，必须通过 rider 副本转发）。",
    "--   ② 有 player_classified → 读 netvar 的 runspeed;value()。",
    "--   ③ 都没有（普通生物）→ 退回 self.runspeed（本地值）。",
    "--   ★★ 关键：客户端不能读 mount.components.locomotor，必须走副本链。",
    "--      这就是「同一逻辑在两端需要不同取法」的具体体现。",
    "--   ★ predicspeed（第 ③ 层前提）：",
    "--     `if self.predictrunspeed ~= nil and self.inst:HasTag(\"autopredict\")` ——",
    "--     ★★★ 「autopredict」tag 是**客户端预测的授权开关**。",
    "--       它只由 stategraph 在「玩家自己」的场景下加，",
    "--       意味着：只有自己的玩家实体才允许客户端本地预测速度，",
    "--       避免预测被用于作弊（移动其他实体）。",
  ],
  "ClientRunSpeed#1+4": [
    "--★ GetMountRunSpeed 是 rider 副本组件的方法 —— 它内部才知道挂载物怎么同步速度。",
  ],
  "ClientRunSpeed#1+10": [
    "--★ 读 netvar：value() 取当前值。这是「网络变量 = 客户端只读的服务端真值」。",
  ],
  "ServerFasterOnRoad#1": [
    "--★ ServerFasterOnRoad 与 ServerRunSpeed 完全同构：道路加速同理走坐骑。",
  ],
  "ClientFasterOnRoad#1": [
    "--★ ClientFasterOnRoad：不检查 player_classified —— 道路加速任何实体都可能触发。",
  ],
  "ServerFasterOnCreep#1": [
    "--★★★【ServerFasterOnCreep：骑乘时**直接返回 false**】",
    "--   ★★ 这不是 bug，是规则：骑乘时在地面 creep（地上的腐蚀/蕨地）上不会加速。",
    "--     原因是骑乘状态下移动由坐骑物理决定，creep 加速对玩家无效。",
    "--   ★ 服务端与客户端（145 行）严格对称 —— 这是本文件双端分派的一条铁律：",
    "--     任何影响速度的函数，两端实现必须给出相同结果，否则会「橡皮筋」抖动。",
  ],
  "ServerFasterOnCreep#1+4": [
    "--★ 注意这里不是 return self.fasteroncreep —— 语义完全不同。",
  ],
  "ServerExternalSpeedMutliplier#1": [
    "--★ ServerExternalSpeedMutliplier（注意原拼写少了个 l，外部 API 不能改）：",
    "--   直接返回本端维护的 externalspeedmultiplier 值（由 SetExternalSpeedMultiplier 维护）。",
  ],
  "ClientExternalSpeedMultiplier#1": [
    "--★★★【ClientExternalSpeedMultiplier：客户端 = netvar × 本地预测】",
    "--   `(player_classified.netvar 或 本地值) * self:GetPredictExternalSpeedMultipler()`",
    "--   ★★★ 这是「双端速度系统」最精妙的一处：",
    "--     · netvar 部分是**服务端权威**的外部倍率（来自装备/状态等）",
    "--     · 预测部分是**纯客户端**的（见 548 行 SetPredictExternalSpeedMultiplier）",
    "--     两者相乘得到最终值。",
    "--   ★★ 为什么要拆成两半？因为「外部倍率」的施加方分两类：",
    "--     · 服务端能算的（穿装备）→ 走 netvar，慢但权威",
    "--     · 客户端瞬时算的（预判「我马上要吃加速药」）→ 走预测容器，快但会丢",
    "--     服务端不认可预测时（如被减速），netvar 部分自然覆盖回来。",
    "--   ★ 预测失配的恢复：See 188-190 行 ServerGetSpeedMultiplier 末尾的 throttle。",
  ],
  "ServerExternalVelocityVectorX#1": [
    "--★ 外部速度向量（横/纵两轴）—— 用于「风/推力/传送残留」等非标准速度源。",
  ],
  "ClientExternalVelocityVectorX#1": [
    "--★ 客户端读 netvar；externalvelocityvectorx 同样在 player_classified 上。",
  ],
  "ServerGetSpeedMultiplier#1": [
    "--★★★【ServerGetSpeedMultiplier：速度倍率的合成中心】",
    "--   最终速度 = GetRunSpeed() × GetSpeedMultiplier()，",
    "--   而 GetSpeedMultiplier = 外部倍率 × 物品倍率 × 地面倍率 × 节流。",
    "--   四个来源的合成规则：",
    "--     ① ExternalSpeedMultiplier()  —— netvar/预测的外部倍率",
    "--     ② 装备或鞍的倍率            —— 骑乘时看鞍，否则看身上装备",
    "--     ③ TempGroundSpeedMultiplier() 或 groundspeedmultiplier —— 地面",
    "--     ④ throttle                  —— 见 898 行，移动指令时重置为 1",
    "--   ★★ 关键设计：② 骑乘与装备是**互斥**的（if rider then 鞍 else 装备）。",
    "--     骑马时不能还享受「穿靴子 +10% 速度」的效果。",
  ],
  "ServerGetSpeedMultiplier#1+3": [
    "--★★ 骑乘时看**鞍**的加成（saddle），不看角色的装备。",
  ],
  "ServerGetSpeedMultiplier#1+5": [
    "--★ 鞍需要 saddler 组件才有加成（不是所有鞍都有）。",
    "--   ★ 两层判空：saddle 实体存在 + 有 saddler 组件。",
  ],
  "ServerGetSpeedMultiplier#1+8": [
    "--★★★【库存必须打开才计算装备减速】英文原注释解释得很清楚：",
    "--   \"Check if inventory is open because client GetEquips returns nothing",
    "--   if inventory is closed. Don't check visibility though.\"",
    "--   ★★★ 这是**双端一致性**的精妙修补：",
    "--     客户端的 GetEquips 在背包关闭时返回空（为了省网络），",
    "--     若服务端仍按「装备齐全」算速度而客户端算「无装备」，",
    "--     玩家会感到「一关背包就走不动路」。",
    "--   ★★ 解法是让两端都用「背包是否打开」当条件，从而得到相同结果。",
    "--     这是一个很值得学的「在错误的地方对齐错误」的经典案例。",
    "--   ★ 「不检查 visibility」：打开背包但角色在屏幕外时也应该算，",
    "--     因为「关背包减速」是游戏规则，与是否被看见无关。",
  ],
  "ServerGetSpeedMultiplier#1+12": [
    "--★★【mightiness：韦爵「威猛」形态的减速免疫】",
    "--   `is_mighty and item_speed_mult < 1 → 视作 1` ——",
    "--   ★ 设计意图：威猛形态下免疫一切「装备减速」效果（但仍享受加速）。",
    "--     只挡 < 1 的减速，不挡 > 1 的加速 —— 所以雪人/ freezing 等减速无效，",
    "--     但仍能吃加血装备的速度加成。",
    "--   ⚠ is_mighty 判定本身在两端也不同（见 220 行的客户端版），也是一致性修补。",
  ],
  "ServerGetSpeedMultiplier#1+13": [
    "--★ 遍历 equipslots（物品栏槽位表），只累加有 equippable 组件的物品。",
  ],
  "ServerGetSpeedMultiplier#1+26": [
    "--★★★【最终合成：三个倍率相乘 × 节流】",
    "--   `mult * (TempGroundSpeedMultiplier() or groundspeedmultiplier) * self.throttle`",
    "--   ★★ `or` 优先取临时地面倍率（655 行），它是「短时修正」，",
    "--     优先级高于常态地面倍率（泥地减速、道路加速）。",
    "--   ★ throttle 是「节流阀」：RunInDirection:1144 传 throttle 参数（0~1），",
    "--     用于「慢慢走」类效果（如喝汤时的减速）。见 898 行 PushAction 重置为 1。",
    "--   ★★★ 临时值优先级高于常态值 —— 这个设计让「临时加速」能覆盖「泥地减速」，",
    "--     是常见的临时效果优先级约定。",
  ],
  "ClientGetSpeedMultiplier#1": [
    "--★★★【ClientGetSpeedMultiplier：客户端版，与服务端严格对称】",
    "--   ★★ 逐行对照服务端版（178 行），差异只有「数据来源」：",
    "--     装备 → replica.inventory:GetEquips()（与服务端 isopen 条件配对）",
    "--     鞍   → saddle.replica.inventoryitem:GetWalkSpeedMult()（经副本链）",
    "--   ★ 公式部分**逐字符相同** —— 这是本文件「双端同构」的铁律：",
    "--     合成公式必须一致，否则速度会在端间跳变（玩家感到「顿一下」）。",
  ],
  "ClientGetSpeedMultiplier#1+4": [
    "--★ 客户端的骑乘判定也走副本（replica.rider）。",
  ],
  "ClientGetSpeedMultiplier#1+9": [
    "--★ 注意：客户端鞍的倍率来自 inventoryitem 副本（GetWalkSpeedMult），",
    "--   而服务端来自 saddle.components.saddler:GetBonusSpeedMult()。",
    "--   ★ 两条不同路径但语义相同 —— saddler 组件的倍率最终写进 inventoryitem 副本。",
  ],
  "ClientGetSpeedMultiplier#1+12": [
    "--★ 再次强调 GetEquips 在背包关闭时为空 —— 注释重复一次因为这是极易踩的坑。",
  ],
  "ClientGetSpeedMultiplier#1+13": [
    "--★★ 客户端版 is_mighty 用**tag**（mightiness_mighty）判定，",
    "--   而服务端用 components.mightiness:GetState() == \"mighty\"（190 行）。",
    "--   ★★ 同一业务规则，两种表达方式：客户端读不到服务端组件，只能读 tag。",
    "--     所以 tag 既是「状态广播」也是「客户端可判定的状态快照」。",
  ],
  "ClientGetSpeedMultiplier#1+14": [
    "--★ pairs 遍历（不是 ipairs）—— equips 是字典表，key 是槽位类型。",
  ],
  "ServerIsFasterOnGroundTile#1": [
    "--★★★【ServerIsFasterOnGroundTile：地面加速的第二套判定（turf 系统）】",
    "--   ★★ 与 FasterOnRoad（116 行）不同，这条查的是 faster_on_tiles 表 ——",
    "--     即「特定地块类型上加速」（如绿蕈地/桦树皮地），",
    "--     常用于「跑鞋」类效果。",
    "--   ★ 第一层守卫：幽灵形态（isghostmode）下永不加速 —— 鬼不能跑步。",
    "--   ★ 骑乘时查挂载物自己的 faster_on_tiles —— 与 FasterOnRoad 同构。",
    "--   ★ `self.faster_on_tiles[ground_tile] == true` 用 `== true` 严格比较，",
    "--     防止传入非布尔时被真值化（Lua 里 0 也是 true）。",
  ],
  "ServerIsFasterOnGroundTile#1+5": [
    "--★ 挂载物也检查 `~= nil`（防御：有些实体有 locomotor 但没设 faster_on_tiles）。",
  ],
  "ClientIsFasterOnGroundTile#1": [
    "--★★★【ClientIsFasterOnGroundTile：客户端用 tag 而非表】",
    "--   `self.inst:HasTag(\"turfrunner_\"..tostring(ground_tile))`",
    "--   ★★ 原因：客户端拿不到服务端组件里的 faster_on_tiles 表。",
    "--     所以服务端在 SetFasterOnGroundTile:600 里同时挂了 tag，",
    "--     客户端读 tag —— 这就是「tag 作为跨端状态载体」的第二例。",
    "--   ★ 拼 tag 名时用 tostring 包裹 —— 因为 ground_tile 是数字（tile id），",
    "--     而 HasTag 要求字符串参数（引擎侧接口）。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 三、LocoMotor 类构造
  // ══════════════════════════════════════════════════════════════
  "ClientIsFasterOnGroundTile#1+14": [
    "--★★★★★【LocoMotor 构造：全文件最重要的 80 行】",
    "--   它做三件大事：",
    "--     ① 【双端分派】根据 ismastersim 把 8 个方法指向 server 或 client 实现",
    "--     ② 【状态初始化】把所有速度、目标、跳跃相关字段初始化",
    "--     ③ 【setter 绑定】把 4 个需同步到客户端的字段挂上 netvar 写入回调",
    "--   ★★★ 整个 DST 组件系统的「双端」设计在此一览无余：",
    "--     同一份 OnUpdate/OnUpdate 逻辑在两端各跑一遍，",
    "--     差异全部收敛到「哪些取数据的函数用哪个实现」这一个决策上。",
  ],
  "ClientIsFasterOnGroundTile#1+16": [
    "--★★ ismastersim 是全局常量（服务器为 true）。整个文件里到处判它。",
    "--   ★ 注意 ismastersim 指的是「本进程是权威模拟端」，",
    "--     对「非玩家实体」来说主机和客户端都会创建 locomotor 组件。",
  ],
  "ClientIsFasterOnGroundTile#1+18": [
    "--★ 服务端分支：给实例打 locomotor tag（客户端不用，因为客户端的实体不参与逻辑判定）。",
  ],
  "ClientIsFasterOnGroundTile#1+20": [
    "--★★★【双端分派的实现：把方法名指向不同的函数】",
    "--   `self.RunSpeed = ServerRunSpeed` —— 不是覆盖方法，而是「实例级的方法指针」。",
    "--   ★★★ 设计收益：OnUpdate 等公共代码里可以直接写 `self:RunSpeed()`，",
    "--     完全不需要写 `if self.ismastersim then ... else ... end`。",
    "--     分派只在这一处发生，公共代码保持端无关。",
    "--   ⚠ 副作用：这些方法不是类方法而是实例字段，",
    "--     无法通过 LocoMotor.RunSpeed 静态访问，也无法被子类统一 override；",
    "--     模组要改行为必须用 AddComponentPostInit 猴补。",
  ],
  "ClientIsFasterOnGroundTile#1+28": [
    "--★ 客户端分支同理。",
  ],
  "ClientIsFasterOnGroundTile#1+37": [
    "--★★★【客户端 removesetter：客户端摘掉 netvar 写入回调】",
    "--   `removesetter(self, \"runspeed\")` —— 参见 class.lua:75。",
    "--   ★★ 关键设计：客户端不需要（也不应该）写 netvar。",
    "--     netvar 是单向的（服务端→客户端），客户端赋值会报错或无意义。",
    "--     所以客户端把字段恢复成「普通字段」，赋值只改本地值。",
    "--   ★★ 这是双端组件的一个通用套路：",
    "--     「共享的字段在客户端要降级为纯本地字段」。",
    "--   ★ 对比 67 行 onrunspeed 里 `if player_classified ~= nil` 的 nil 守卫：",
    "--     两者共同保证「客户端赋值 runspeed 不会同步，也不会崩」。",
  ],
  "ClientIsFasterOnGroundTile#1+43": [
    "--★ dest（目标）与 atdestfn（到达回调）—— locomotor 的两大状态。",
  ],
  "ClientIsFasterOnGroundTile#1+46": [
    "--★ arrive_step_dist 是「路径拐点的到达半径」（= ARRIVE_STEP = 0.15）。",
    "--   ★ 与 arrive_dist（目的地的到达半径，通常 2~4）区分：",
    "--     arrive_step_dist 用于路径中间点（细），arrive_dist 用于终点（粗）。",
    "--   ★★ 为什么要分开？因为拐点要「精确经过」才转向，终点要「足够近就算到」。",
  ],
  "ClientIsFasterOnGroundTile#1+47": [
    "--★ arrive_dist 初值同样是 ARRIVE_STEP —— 无目标时的兜底。",
  ],
  "ClientIsFasterOnGroundTile#1+48": [
    "--★ WILSON_WALK_SPEED = 4 —— 基准走路速度。角色 prefab 在自己构造里改这个值。",
  ],
  "ClientIsFasterOnGroundTile#1+49": [
    "--★ WILSON_RUN_SPEED = 6 —— 基准跑步速度。原注释 \"-- 6\" 标明了默认值。",
  ],
  "ClientIsFasterOnGroundTile#1+50": [
    "--★★ throttle = 1（节流）。PushAction/PushStart 时重置为 1（898 行），",
    "--   RunInDirection 可传 0~1 的部分速度。「缓慢移动」效果的基础。",
  ],
  "ClientIsFasterOnGroundTile#1+51": [
    "--★★★【lastpos = {}：地面速度优化的缓存槽】",
    "--   ★★★ 性能关键：UpdateGroundSpeedMultiplier 每帧都调代价很高",
    "--     （要查 GroundCreep:OnCreep + 查地块 + 查道路）。",
    "--     优化：只有当所在**地块坐标**变化时才重算（见 1438-1444）。",
    "--   ★ lastpos 初始为空表，所以第一次 OnUpdate 必然触发一次重算。",
  ],
  "ClientIsFasterOnGroundTile#1+52": [
    "--★ slowmultiplier = 0.6 —— 在 creep（腐蚀地）上行走时速度 × 0.6。",
  ],
  "ClientIsFasterOnGroundTile#1+53": [
    "--★ fastmultiplier = 1.3 —— 在快地面（道路/turf）上行走时速度 × 1.3。",
  ],
  "ClientIsFasterOnGroundTile#1+54": [
    "--★ movestarttime = -1 —— 移动开始时刻，GetTimeMoving 用它算已移动时长。",
  ],
  "ClientIsFasterOnGroundTile#1+55": [
    "--★ movestoptime = -1 —— 移动停止时刻。-1 是哨兵值（不是 nil），",
    "--   因为 nil 在 Lua 里表示「无值」，而 -1 表示「有效但很久以前」。",
    "--   ★★ 这个区别很关键：见 407 行 `self.movestoptime ~= nil and ...`，",
    "--     用 -1 哨兵可以让条件简化为「减出来的时间差是否超阈值」，",
    "--     而不需要额外的「是否曾停止过」标志。",
  ],
  "ClientIsFasterOnGroundTile#1+56": [
    "--⚠【被注释的字段】movetimeoverride / predictmovestarttime / no_predict_fastforward",
    "--   实际在 435/438/441/890 行有对应逻辑，只是构造时不需要初始化（nil 是有效初值）。",
    "--   ★ 与 89 行 health.lua 一样：注释保留作为「这些字段存在」的记录。",
  ],
  "ClientIsFasterOnGroundTile#1+58": [
    "--★ no_predict_fastforward —— 见 PlayerController:RepeatHeldAction()，",
    "--   用来标记「这个动作不应该被客户端预测快进」。",
  ],
  "ClientIsFasterOnGroundTile#1+60": [
    "--★ groundspeedmultiplier = 1.0 —— 常态地面倍率（泥地/道路之外的默认）。",
  ],
  "ClientIsFasterOnGroundTile#1+61": [
    "--★ enablegroundspeedmultiplier —— 总开关。关闭时所有地面效果失效（583 行清空状态）。",
  ],
  "ClientIsFasterOnGroundTile#1+66": [
    "--★ isrunning：当前是否处于「跑」姿态。由 WalkForward/RunForward 设定。",
  ],
  "ClientIsFasterOnGroundTile#1+68": [
    "--★★ _externalspeedmultipliers 是「来源→倍率」的表（详见 480 行）。",
    "--   与 externalspeedmultiplier（计算结果）分离 —— 表是输入，字段是输出。",
  ],
  "ClientIsFasterOnGroundTile#1+69": [
    "--★ externalspeedmultiplier = 1 —— 计算结果初值（无来源时为 1 = 不减速也不加速）。",
  ],
  "ClientIsFasterOnGroundTile#1+71": [
    "--★ _externalvelocityvectors 同构 —— 外部速度向量的来源表。",
  ],
  "ClientIsFasterOnGroundTile#1+75": [
    "--★ wasoncreep：上一帧是否在 creep 上（用于边沿事件，610/624 行）。",
  ],
  "ClientIsFasterOnGroundTile#1+76": [
    "--★ triggerscreep：是否响应 creep。关闭后实体能在 creep 上正常走（如幽灵）。",
  ],
  "ClientIsFasterOnGroundTile#1+77": [
    "--★ is_prediction_enabled —— 客户端预测开关（当前仅记录，未在本文件内读取）。",
  ],
  "ClientIsFasterOnGroundTile#1+78": [
    "--★ hop_distance = TUNING.DEFAULT_LOCOMOTOR_HOP_DISTANCE = 6.0",
    "--   —— 跳跃探测的最大距离。太小跳不上船，太大会跳过头。",
  ],
  "ClientIsFasterOnGroundTile#1+80": [
    "--★ hopping：跳跃中标志。OnUpdate:1425 见到它就早退（跳跃期间不做移动决策）。",
  ],
  "ClientIsFasterOnGroundTile#1+81": [
    "--★ time_before_next_hop_is_allowed：跳跃冷却，防止连跳（见 1413 行）。",
  ],
  "ClientIsFasterOnGroundTile#1+84": [
    "--★ faster_on_tiles = {}：turf 加速表（绿蕈地等）。客户端读它对应的 tag。",
  ],
  "ClientIsFasterOnGroundTile#1+86": [
    "--⚠【被注释的字段】isupdating / predictrunspeed / pusheventwithdirection",
    "--   分别在 366/108/341 行有对应逻辑。pusheventwithdirection 主要是给玩家用的",
    "--   ——让「locomote」事件携带方向信息，供状态图处理「初始朝向」。",
  ],
  "ClientIsFasterOnGroundTile#1+89": [
    "--★★ pusheventwithdirection 的设计动机（英文原注释）：",
    "--   \"mainly for players, to handle initial move dir, and not have to add",
    "--   'canrotate' to all interruptible states\"",
    "--   ★★★ 翻译：玩家按下方向键时，locomotor 不知道该朝哪转，",
    "--     于是把方向塞进事件数据，让状态图自己决定怎么转。",
    "--   ★★ 这样就不必给「所有可打断的状态」都加 canrotate 标签，",
    "--     减少了状态图标签的维护成本。",
  ],
  "ClientIsFasterOnGroundTile#1+92": [
    "--★★ setter 表：4 个字段需同步到客户端。参见 class.lua:82 的 props 机制。",
    "--   与 health.lua 同构。注意这里没有 maxhealth 之类的纯服务端字段。",
  ],
};

export const AFTER = {};
