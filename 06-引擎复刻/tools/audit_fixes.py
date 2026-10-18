#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核对「该有的修复清单」—— 防「文件恢复不完整导致静默丢修复」。

为什么需要它
    2026-10-15 我用一次错误的字符串切片把 `host/01_core.lua` 从 ~980 行
    截断到 233 行，然后用一份**更早的备份**恢复。恢复后：

        · 文件能编译                  ✔（语法正确）
        · 十三入口回归                 ✔ 全部 PASS
        · full.lua 基线                ✔ 1525/0/6081 完全正常
        · tests.lua 断言               ✔ 0 失败

    **但静默丢掉了一条修复**：`NewEntity` 里的
        inst.replica = make_replica(inst)      -- entityscript.lua:244
    后果：没有任何组件的实体永远没有 replica，而 `FindEntity` 会把它们
    当候选目标 ⇒ 战斗代码访问 `target.replica.combat` 时崩。
    **只有 `WORLD_TICKS=30000` 的两天长局会崩**（4.33 s），短局全绿。

    ⇒ 「编译通过 + 短局全绿」**不能证明恢复完整**。
       要发现「丢了什么」，只能拿**一份该有的修复清单**逐条核对。

本脚本就是那份清单。每条 = (人话名, 文件, 特征串)。
特征串选「只有该修复才会出现的标识符」，不要选通用词。

用法
    python tools/audit_fixes.py            # 核对
    python tools/audit_fixes.py --list     # 只列清单
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (人话名, 相对路径, 特征串)
#   ★ 特征串的选法：要能区分「修复在/不在」。
#     好例子：`inst.replica = make_replica(inst)`（这条语句本身就是修复）
#     坏例子：`replica`（到处都是，永远为真）
CHECKS = [
    # ---- 01_core.lua：实体结构 ----
    ("replica 在 NewEntity 里建（不是惰性）", "host/01_core.lua",
     "inst.replica = make_replica(inst)"),
    ("make_replica 前向声明", "host/01_core.lua", "local make_replica"),
    ("knownlocations 是引擎默认组件", "host/01_core.lua",
     'LoadRealComponent("knownlocations")'),
    ("spawntime 在 NewEntity 赋值", "host/01_core.lua", "inst.spawntime"),
    # ★★ 特征串必须指向**行为**而不是「文件里有这个词」。
    #   旧串 `lower_components_shadow` 在**闸门写坏成空转**时依然存在 ——
    #   实测就是这样：宿主只读了影子表却**从不写**（原版 entityscript.lua:635
    #   在成功添加后写 `= true`），于是闸门对所有普通组件都是死的，
    #   重复 AddComponent 会造出两个活实例。而旧检查一直是 ✔。
    #   ⇒ 换成那两行**登记/清除**语句本身。
    ("AddComponent **登记**影子表（不是只读）", "host/01_core.lua",
     "self.lower_components_shadow[string.lower(name)] = true"),
    ("RemoveComponent **清除**影子标记（成对）", "host/01_core.lua",
     "self.lower_components_shadow[string.lower(name)] = nil"),
    ("影子闸门有反向行为断言", "tests.lua",
     "if a ~= b then"),
    ("文档数字审计工具（扫全部 .md）", "tools/audit_doc_numbers.py",
     "def ground_truth()"),
    ("文档审计认「当时值」约定", "tools/audit_doc_numbers.py",
     "'当时值' in line"),
    ("文档审计第 5 条：未来时间戳", "tools/audit_doc_numbers.py",
     "def future_timestamps(now=None)"),
    # ★★ 特征串必须指向**行为**，不能指向**消息文本**。
    #   这条原本用成功语 `也没有未来时间戳` 当特征串 —— 我后来把成功语改成
    #   「…/ 未来时间戳 / 模糊时间戳 / 工具输出不符」⇒ **特征串凭空消失**，
    #   检查报「缺失」，而那条修复其实完好无损。
    #   这与影子闸门那次是同一类错误（指向字符串而非行为），只是换了条条目。
    #   ⇒ 改为指向合并处的**顺序契约哨兵注释**。
    ("未来时间戳/工具核对**在提前返回之前**合并（防死代码）",
     "tools/audit_doc_numbers.py",
     "顺序契约（防死代码）"),
    ("文档审计第 6 类：模糊时间戳", "tools/audit_doc_numbers.py",
     "'模糊时间戳', tok"),
    ("文档审计**每次运行自检** 5 条合成违规", "tools/audit_doc_numbers.py",
     "def self_check()"),
    ("自检不过 ⇒ 退出码 2 并点名死规则", "tools/audit_doc_numbers.py",
     "return 2"),
    ("可达性入口的分类**守恒断言**", "reachability.lua",
     "_conserve_ok = (_sum == #fail)"),
    ("闸门计数变成**被检查的期望**（基线 20）", "world.lua",
     "local GATE_BASELINE = 20"),
    ("特征串质量分级（防指向消息文本）", "tools/audit_fixes.py",
     "order = {'string': 0, 'comment': 1, 'code': 2, 'ok': 3}"),
    # ★★★ 本条**已退役**（2026-10-15 20:0x），原因值得记全：
    #   它原本的特征串是 `context = prev + line`，**只存在于本表自身**
    #   （文件里根本没有那行代码）⇒ **自满足特征串**：
    #   条目自己满足自己，无论被守护的行为在不在，检查都「在」。
    #   ★ 后果实测：我后来把 `_position_of` 重写成「按引号奇偶判身份」，
    #     顺手**删掉了「上一行纳入上下文」那段逻辑**，而这条检查**一直绿着** ——
    #     它守护的行为已经消失，它却因为自满足而毫无反应。
    #   ⇒ 处置：该行为已被**更好的判据取代**（引号奇偶法天然覆盖多行调用那种情形），
    #     所以不是「补回来」，而是**退役这条条目**并留下这段说明。
    #   ⇒ 并新增「自满足特征串」检查（见 self_satisfying_markers），防同类再犯。
    ("类别名全部收敛到 Boundaries.CLASS 表", "host/26_boundaries.lua",
     "Boundaries.CLASS = CLASS"),
    ("判据①：class 取值必须来自 CLASS 表", "host/26_boundaries.lua",
     "if not known[cls] then"),
    # ★ 又一条被 `--quality` 抓出来的（message ×1）：原用消息文本
    #   `有人又抄了一遍，会漂移` ⇒ 改指**行为**（那条判断的比较表达式）。
    ("判据②：类别字面量在**代码**里只出现 1 次", "host/26_boundaries.lua",
     "if cnt ~= 1 then"),
    ("质量报告进默认输出（T40）", "tools/audit_fixes.py",
     "n_msg = len([t for t in q if t[3] == 'string'])"),
    ("断言覆盖率**候选**报告（T41）", "tools/audit_fixes.py",
     "tp = os.path.join(ROOT, 'tests.lua')"),
    ("覆盖率排除规则（工具类 + 复核过）", "tools/audit_fixes.py",
     '"PhysicsWaker": "T42 已补断言'),
    ("T42 五条：PhysicsWaker 侧挂", "tests.lua",
     "e.entity:AddPhysicsWaker()"),
    ("T42：_G.Map 与 World.Map 同步", "tests.lua",
     "local m = _G.Map"),
    ("T44 第 7 类：类别名与文档同步", "tools/audit_doc_numbers.py",
     "def class_doc_consistency()"),
    ("第 7 类有可测内核 + 真自检", "tools/audit_doc_numbers.py",
     "def _class_doc_hits("),
    ("报告 §46 类别名规范清单（由代码生成）", "世界可跑可看报告.md",
     "边界类别名的**规范清单**"),
    ("断言条数判据收紧到**显式总数**写法", "tools/audit_doc_numbers.py",
     "只认**明确表示总数**的写法"),
    ("自检样本**相对当下**生成（不硬编码绝对时间）", "tools/audit_doc_numbers.py",
     "datetime.datetime.now() + datetime.timedelta(hours=2)"),
    ("歧义锚点检查（code+字符串/注释）", "tools/audit_fixes.py",
     "high, mid = [], []"),
    ("按**引号奇偶**判特征串身份", "tools/audit_fixes.py",
     "pre.count('\"') % 2 == 1"),
    ("入口印类别名清单（与 §46 对账）", "reachability.lua",
     "local CLS = Boundaries.CLASS or {}"),
    ("§46 的**数量**机器核对（T47）", "tools/audit_doc_numbers.py",
     "if m and int(m.group(1)) != n_code:"),
    ("自满足特征串检查（T51，最阴的假 ✅）", "tools/audit_fixes.py",
     "self_path = os.path.abspath(__file__)"),
    ("特征串豁免清单（数据名，逐条附理由）", "tools/audit_fixes.py",
     '"inventoryimages1.xml":'),
    ("豁免清单自检（理由齐备 + 未过期，T53）", "tools/audit_fixes.py",
     "def exemption_problems()"),
    # ★ 这两条我 T49/T50 时又用了消息文本当特征串 ——
    #   是 **T56 总入口第一次跑**就报出来的（`string` 类 2 条）。
    #   ⇒ 改指行为（那两处判断语句本身）。
    ("§46 表格**双向**核对（T49 反向 / T50 正向+名字）", "tools/audit_doc_numbers.py",
     "if k not in code_map:"),
    ("§46 表格名字一致性检查", "tools/audit_doc_numbers.py",
     "elif rows[k] != v:"),
    ("硬编码集合升级为**有理由的配置**（T54）", "tools/audit_doc_numbers.py",
     "def config_problems():"),
    ("record/target 集合**不能有交集**（否则静默失效）", "tools/audit_doc_numbers.py",
     "'record/target 有交集 %s"),
    ("入口输出 vs §46 机器比对（T55）", "tools/audit_doc_numbers.py",
     "def entry_class_list():"),
    ("次序契约判据**必须两个都在**（缺东西≠顺序对）", "tools/audit_doc_numbers.py",
     "_why.append('找不到合并行')"),
    ("核对三件套**总入口**（T56）", "tools/check_all.sh",
     'if [ "$FAILED" = "0" ]; then'),
    ("**安全编辑**工具（改文件前验锚点，T57）", "tools/safe_edit.py",
     "def classify(text, anchor, is_md=False):"),
    ("safe_edit 拒绝危险锚点（退出码 2）", "tools/safe_edit.py",
     "elif len(code_like) > 1:"),
    ("safe_edit 拒绝时**建议替代锚点**（T60）", "tools/safe_edit.py",
     "def suggest_anchors(text, code_occ, is_md=False):"),
    ("建议器**逐级加大窗口**（整行不够就带下一行）", "tools/safe_edit.py",
     "for win in (1, 2, 3):"),
    ("safe_edit **批量模式**（--anchor 可重复）", "tools/safe_edit.py",
     "任一个不过 ⇒ 整体不过"),
    ("safe_edit 认得 `.md` 的 `#` 是标题而非注释", "tools/safe_edit.py",
     "(not is_md and stripped.startswith('#'))"),
    ("特征串质量 string>0 ⇒ **退出码 1**（T61）", "tools/audit_fixes.py",
     "return 1"),
    ("总入口 **--json**（机器可读结论，T62）", "tools/check_all.sh",
     "exec 3>&1"),
    ("TC25：新组件可注册 + 新预制体可 spawn（能力声明锁死）", "tests.lua",
     'Core.RegisterComponent("t25_counter", T25Counter)'),
    ("TC25：新组件的 OnUpdate 真的被更新泵调到", "tests.lua",
     'if got ~= 30 then'),
    ("新内容 demo（新组件+新预制体+跑 tick）", "_demo_newcontent.lua",
     'inst:StartUpdatingComponent(inst.components.democounter)'),
    ("中文数字归一化（`## 八、` → 8，T59）", "tools/audit_doc_numbers.py",
     "def _cn2num(tok):"),
    ("历史节号必须**实际存在**于报告（T59）", "tools/audit_doc_numbers.py",
     "if key not in present:"),
    ("RESUME.md 接入总入口与安全编辑（T58）", "RESUME.md",
     "开工前先跑一遍"),
    ("未定性类别名**只定义一份**", "host/26_boundaries.lua",
     "Boundaries.UNDETERMINED ="),
    # ★ 这条的特征串原本用 `两处已经漂移` —— 那是**消息文本**
    #   （我用 --quality 查自己刚加的三条时抓到的，message ×1）。
    #   ⇒ 改指**行为**：那条断言里的**比较表达式**本身。
    ("未定性常量与 Explain 的一致性断言", "tests.lua",
     "cls ~= B.UNDETERMINED"),

    # ---- 01_core.lua：句柄与加载器 ----
    ("AddVFXEffect 返回可链式对象", "host/01_core.lua", "function h:AddVFXEffect"),
    ("AddGroundCreep 返回代理", "host/01_core.lua", "function h:AddGroundCreep"),
    ("12 个 entity:AddXxx 子对象代理", "host/01_core.lua", "CHILD_PROXIES"),
    ("子对象代理工厂", "host/01_core.lua", "local function proxy_child"),
    ("AddPhysicsWaker 双侧可见", "host/01_core.lua", "inst.PhysicsWaker = w"),
    ("LoadRealComponent 失败可重试", "host/01_core.lua", "Core.RealComponentFails"),
    ("Loader.Load 失败不永久缓存（可重试）", "host/04_loader.lua", "Loader.Retry"),

    # ---- 03_globals.lua ----
    ("PrefabExists 读 Core.Prefabs", "host/03_globals.lua", "Core.Prefabs[name]"),
    ("PrefabExists 先懒加载再判", "host/03_globals.lua", "Core._prefab_loader"),
    ("TheFocalPoint 初始 nil（忠于原版）", "host/03_globals.lua",
     "G.TheFocalPoint = nil"),
    ("TheCamera 是真实现（非泛化桩）", "host/03_globals.lua", "G.TheCamera = {"),
    ("TheCamera.GetRightVec", "host/03_globals.lua", "GetRightVec"),
    ("TALKINGFONT 全局", "host/03_globals.lua", "G.TALKINGFONT"),
    ("PhysicsWaker 全局静态", "host/03_globals.lua", "G.PhysicsWaker"),
    ("event_server_data 带降级", "host/03_globals.lua", "function G.event_server_data"),
    ("Vector3 Dot/Cross 有 nil 守卫", "host/03_globals.lua", "if other == nil then"),

    # ---- 02_sim.lua ----
    ("World.components 表", "host/02_sim.lua", "World.components"),
    ("PocketDimensionContainers", "host/02_sim.lua", "World.PocketDimensionContainers"),

    # ---- 05_bootstrap.lua ----
    ("DYNAMIC_FAMILY_FILES 清单", "host/05_bootstrap.lua", "DYNAMIC_FAMILY_FILES"),
    ("stringutil 进启动序列", "host/05_bootstrap.lua", '"stringutil"'),
    ("world 组件装配（walkableplatformmanager）", "host/05_bootstrap.lua",
     '"walkableplatformmanager"'),
    ("家族文件：meats", "host/05_bootstrap.lua", '"meats"'),
    ("家族文件：birds", "host/05_bootstrap.lua", '"birds"'),
    ("家族文件：farm_plants", "host/05_bootstrap.lua", '"farm_plants"'),

    # ---- 10_animstate.lua ----
    ("OverrideSymbol 成对撤销账本", "host/10_animstate.lua", "_ov_auto"),
    ("MissingHits 模块初始化即建表", "host/10_animstate.lua", "M.MissingHits = {}"),
    ("SetAddColour（加色）", "host/10_animstate.lua", "as.SetAddColour"),
    ("OverrideShade / GetShade", "host/10_animstate.lua", "as.OverrideShade"),
    ("SetLayer / SetSortOrder", "host/10_animstate.lua", "as.SetSortOrder"),
    ("SetOrientation / Bloom", "host/10_animstate.lua", "as.SetOrientation"),

    # ---- 其它 ----
    ("Transform:SetTwoFaced", "host/00_stubs.lua", "SetTwoFaced"),
    ("Transform:SetScale", "host/00_stubs.lua", "SetScale = function"),
    ("SoundEmitter:SetParameter", "host/00_stubs.lua", "SetParameter = function"),
    ("Physics:SetDontRemoveOnSleep", "host/11_physics.lua", "SetDontRemoveOnSleep"),
    ("netvar 按类型补默认初值", "host/12_netvars.lua", "NET_DEFAULTS"),
    ("Map 同时写 _G", "host/20_map.lua", "_G.Map = Map"),

    # ---- 第三轮（可达性抽样 1000）：10 类新根因，每条都对应真实失败样本 ----
    ("TheSim:AtlasContains 真查索引", "host/23_atlas.lua",
     "function TheSim:AtlasContains"),
    ("图集索引按需读取 + 缺口不静默", "host/23_atlas.lua",
     'Core.NoteGap("atlas:"'),
    ("图集索引导出工具", "tools/export_atlas_index.py", "inventoryimages1.xml"),
    ("sg 方法清单只维护一份（含 HasState）", "host/01_core.lua", "Core.SG_METHODS"),
    ("HasState 查定义表而非当前状态", "host/01_core.lua",
     "self.sg.states[statename]"),
    ("三处 sg 兜底统一走 ApplySGMethods", "host/01_core.lua", "Core.ApplySGMethods"),
    ("bootstrap 用 Core.ApplySGMethods 补 SG 类", "host/05_bootstrap.lua",
     "Core.ApplySGMethods(_G.StateGraphInstance"),
    ("WORLDSTATETAGS 运行时切真实段执行", "host/24_worldstatetags.lua",
     'WST.MarkBegin  = "local WORLDSTATE_NAMESPACES = {}"'),
    ("WORLDSTATETAGS 锚点缺失要记缺口", "host/24_worldstatetags.lua",
     "i = src:find(WST.MarkBegin, 1, true)"),
    ("main.lua 四个渲染管理器全局", "host/25_render_managers.lua",
     "{ global = \"EnvelopeManager\""),
    ("RoadManager:IsOnRoad 显式 false", "host/25_render_managers.lua",
     "IsOnRoad = function() return false end"),
    ("emitters.lua 进启动序列", "host/05_bootstrap.lua", '"emitters"'),
    ("vecutil.lua 进启动序列", "host/05_bootstrap.lua", '"vecutil"'),
    ("prefabskin 全局空表静态提取", "host/27_prefabskin_globals.lua",
     "function PSG.Extract(src)"),
    ("prefabskin 空表提取到 0 条要记缺口", "host/27_prefabskin_globals.lua",
     "local names = PSG.Extract(src)"),
    ("InGamePlay 常量真", "host/03_globals.lua",
     "function G.InGamePlay() return true end"),
    ("Profile 设置代理（Get→nil）", "host/03_globals.lua", "G.Profile = setmetatable"),
    ("Ents 别名到 Core.Spawned", "host/03_globals.lua", "G.Ents = Core.Spawned"),
    ("更新泵分桶表全局", "host/03_globals.lua", '"NewUpdatingEnts"'),
    ("TheSim 环境光颜色系列", "host/02_sim.lua", "function TheSim:SetAmbientColour"),
    ("Light 数值状态字段初值", "host/00_stubs.lua",
     "_intensity = 0, _falloff = 0"),
    ("world 组件两趟装配（早/晚）", "host/05_bootstrap.lua",
     'mount_world_components("late")'),
    ("ambientlighting 进世界组件清单", "host/05_bootstrap.lua",
     '"ambientlighting"'),
    ("event_server 降级计数（可观测）", "host/03_globals.lua",
     "Core.EventServerDegraded"),
    ("边界登记表（机器可读）", "host/26_boundaries.lua", "Boundaries.Explain"),
    ("边界登记表自检三要素齐全", "host/26_boundaries.lua",
     "function Boundaries.Audit"),
    ("可达性抽样成为正式入口", "reachability.lua", "os.getenv(\"REACH_SEED\")"),
    ("抽样失败带 why/proof（不靠猜）", "reachability.lua",
     "Boundaries.Explain(name, ctx)"),
    ("带参工厂静态扫描工具", "tools/scan_parameterized_factories.py",
     "WRAPPER_EVIDENCE"),
    ("hermitcrabtea 无 duration 的证明脚本",
     "tools/prove_hermitcrabtea_nil_duration.py", "split_tables(text, \"BUFF_DEFS\")"),

    # ---- 第三轮后半场：真实 ACTIONS / 账号对象 / 世界根登记 ----
    ("global() 声明函数（不加载 strict.lua）", "host/03_globals.lua",
     "function G.global(...) end"),
    ("真实 actions.lua 加载进启动序列", "host/05_bootstrap.lua",
     '"/actions.lua"'),
    ("ACTIONS 惰性兜底（自验证，防被重执行冲掉）", "host/04_loader.lua",
     "function Loader.EnsureActionsFallback()"),
    ("TheInventory 账号对象（Count 结尾返回数字）", "host/03_globals.lua",
     'k:match("Count$")'),
    ("FindFirstEntityWithTag 按标签找首个实体", "host/02_sim.lua",
     "function TheSim:FindFirstEntityWithTag(tag)"),
    ("SetPocketDimensionContainer（与 Get/Create 同源）", "host/02_sim.lua",
     "function World:SetPocketDimensionContainer(name, containerinst)"),
    ("TheCamera:GetHeading（与 GetHeadingTarget 分开）", "host/03_globals.lua",
     "G.TheCamera.GetHeading = function(self) return self._headingtarget end"),
    ("世界根预制体自动登记（调用嵌套，非反射）", "host/04_loader.lua",
     "function Loader.WrapWorldMakers()"),
    ("世界根标记在 Core.Prefab 里落账", "host/01_core.lua",
     "if Core._InWorldMaker ~= nil then"),
    ("包装器判据：当前值是不是我的包装器", "host/04_loader.lua",
     "cur ~= mine"),
    ("world 组件两趟装配晚趟", "host/05_bootstrap.lua",
     'mount_world_components("late")'),
    ("TC19 断言：真实 ACTIONS 字段", "tests.lua",
     "toss.distance ~= 8"),
    ("TC19 断言：TheInventory Count 返回数字", "tests.lua",
     "local v = TI:GetClientGiftCount(\"__test_userid__\")"),

    # ---- 第三轮第三场：N=3000 抽样才抽到的稀有缺口 ----
    ("平台函数补齐 5 个真名（IsXB1 等）", "host/03_globals.lua", '"IsXB1"'),
    ("平台函数从 main.lua 静态提取兜底", "host/03_globals.lua",
     "__PLATFORM_FNS_FOUND"),
    ("package.assetpath（资源搜索路径列表）", "host/03_globals.lua",
     "package.assetpath = {}"),
    ("kleifileexists 真查磁盘（不是桩）", "host/03_globals.lua",
     "function G.kleifileexists(filepath, manifest, originalpath)"),
    ("kleifileexists 命中/未命中可观测", "host/03_globals.lua",
     "G.__kleifileexists"),
    ("LOC 从 loc.lua 的**返回值**取（不是全局）", "host/05_bootstrap.lua",
     "_G.LOC = e"),
    ("LOC 加载失败要记缺口", "host/05_bootstrap.lua", "Bootstrap.LocLoaded = false"),

    # ---- P43：建造落地链路上游的两个真缺陷（U3）----
    #   ★ 特征串必须指向**那句判定本身**，不能指向注释。
    #     这两条的修复都是「补一个分支」，注释写得再详细也不代表分支在。
    ("GetDistanceSqToPoint 支持「只传一个 Vector3」", "host/06_entityscript.lua",
     'if x and not y and not z and type(x) ~= "number" then'),
    ("Vector3 支持 number ± Vector3（标量在左）", "host/03_globals.lua",
     'if type(a) == "number" then return G.Vector3(a + b.x, a + b.y, a + b.z) end'),

    # ---- P43：两条「判据错」（不是引擎缺陷，但会让判据永久绿/永久红）----
    ("render.lua 挑动画判据看 `_cur`（`_nframe` 恒 >0 是橡皮图章）", "render.lua",
     "if as._cur ~= nil and not as._synthetic then return n end"),
    ("render.lua 空动画不得进 spawned（空 BUNDLE 会污染下游判据）", "render.lua",
     "if an and as._cur and info and info.nframe then"),
    ("player.lua 状态机判据在**转移瞬间**采样动画", "player.lua",
     "anim_changed = (anim_after_go ~= prev_anim),"),
    ("player.lua 状态机判据真红（文末 error，不许打印 ✘ 却 PASS）", "player.lua",
     'error("状态机判据未通过：" .. SM_WHY, 0)'),

    # =====================================================================
    # C 类九项（2026-10-18 修复轮）—— **每一条都要能被这条清单守住**
    # =====================================================================
    # ★ 为什么 C 类也要登记：`校验报告-P43` 的 C 类是"当时没修"的账。
    #   账修好了却没人守，下一次文件恢复不完整就会**悄悄退回去**，
    #   而届时所有入口照样全绿（这正是本工具存在的理由）。
    # 特征串选「只有该修复才会有的那一行」，不选通用词。
    ("C3 光照真源：亮度读 TheWorld.state.phase（不是恒值）", "host/01_core.lua",
     "local function ambient_light_level()"),
    ("C3 LightWatcher:GetLightValue 存在且与 IsInLight 同源", "host/01_core.lua",
     "lw.GetLightValue = function(self) return ambient_light_level() end"),
    ("C3 EntityScript:IsInDark 存在（与 IsInLight 互补）", "host/06_entityscript.lua",
     "IsInDark = function(self)"),
    ("C4 GetCurrentPlatform/SetCurrentPlatform 成对（BOARDPLATFORM 可达）",
     "host/06_entityscript.lua", "return self._currentplatform"),
    ("C4 Physics:IsOnPlatform 返回 bool 且与 Setter 成对", "host/00_stubs.lua",
     'GetIsOnPlatform = function(self) return rawget(self, "_onplatform") == true end'),
    ("C4 Transform:SetPosition 标记显式位置（供 C6 区分）", "host/00_stubs.lua",
     "self._explicit_pos = true"),
    ("C5 越界瓦片映射成 INVALID（不是 IMPASSABLE）", "host/20_map.lua",
     "return self.OUT_OF_BOUNDS or 65535"),
    ("C5 Map:IsOutOfBoundsAtPoint 存在（界外可问，不必猜）", "host/20_map.lua",
     "function Map:IsOutOfBoundsAtPoint"),
    ("C6 父实体坐标跟随（跳过显式摆位的实体）", "host/02_sim.lua",
     "local function parent_of(inst)"),
    ("C7 Lua 5.2+ 兼容垫片（迁移前提，实测 14/14 入口通过）", "host/compat52.lua",
     '_G.__COMPAT52__ = { applied = applied, version = _VERSION }'),
]


#=========================================================================
# ★★ T36 / T37：**特征串的质量分级**（防「指向消息文本」）
#=========================================================================
#   由来：今天**两次**因为特征串指向**消息文本**而误判 ——
#     · 影子闸门那条用 `lower_components_shadow`（这个词在闸门**空转**时依然在）
#     · 未来时间戳那条用成功语 `也没有未来时间戳` —— 我一改成功语，
#       特征串**凭空消失**，检查报「缺失」，而修复其实完好无损。
#   ⇒ 「检查通过」有两种可能：**修复在**，或**特征串恰好在**。
#     要区分，就得看特征串落在**什么位置**。
#
#   判据（按稳定性从高到低）：
#     code    出现在**可执行语句**里（最稳：行为本身）
#     comment 只出现在注释里（较稳：描述行为，但仍是文本）
#     message 只出现在 print / io.write 的字符串里（**最脆**：一改措辞就断）
def _position_of(text, marker):
    """marker 在 text 里以哪些**身份**出现；返回 (类别集合, 出现次数)。

    ★★ 身份判定的关键：**在不在引号里**。
    第一版只把「传给 print/string.format 的字符串」算作消息文本 ⇒
    普通字符串字面量（如 `Core.NewEntity("__t24_waker__")`）被算成 `code`
    ⇒ **今天那次真实事故（`src.find('def main():')`）根本检测不到** ——
    因为 `'def main():'` 既出现在**代码**里（`src.find(` 那一行），
    也出现在一个**普通字符串**里（`_mi = src.find('def main():')`
    的实际匹配目标），而它不经过任何 print。
    反向测试（注入双身份 marker）没报 ⇒ 才发现判据太窄。

    ⇒ 改成按「引号奇偶」判身份（够用于单行情形，本工具的语料都是单行）：
        · 行首是 `--` / `#`，或 marker 之前有 `--`  ⇒ comment
        · marker 之前引号数为**奇数** ⇒ string（在字符串字面量里）
        · 否则 ⇒ code
    """
    kinds, n = set(), 0
    start = 0
    while True:
        i = text.find(marker, start)
        if i == -1:
            break
        n += 1
        start = i + 1
        ls = text.rfind('\n', 0, i) + 1
        le = text.find('\n', i)
        line = text[ls:le if le != -1 else len(text)]
        pre = line[:i - ls]
        stripped = line.lstrip()
        if stripped.startswith('--') or stripped.startswith('#') or '--' in pre:
            kinds.add('comment')
        elif (pre.count('"') % 2 == 1) or (pre.count("'") % 2 == 1):
            kinds.add('string')
        else:
            kinds.add('code')
    return kinds, n


def marker_quality():
    """返回 [(名称, 文件, 特征串, 类别, 出现次数)]，按稳定性升序"""
    order = {'string': 0, 'comment': 1, 'code': 2, 'ok': 3}
    out = []
    for name, rel, marker in CHECKS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        text = io.open(path, encoding='utf-8', errors='replace').read()
        kinds, n = _position_of(text, marker)
        if n == 0:
            continue                     # 缺失另有报错，这里只管「在但脆弱」
        best = sorted(kinds, key=lambda k: -order.get(k, 0))[0]
        if marker in STRING_OK:
            best = 'ok'           # ★ 豁免：本质是数据名，没有行为可指
        out.append((name, rel, marker, best, n))
    out.sort(key=lambda t: order.get(t[3], 9))
    return out


#=========================================================================
# ★★ T41：断言**覆盖率**报告（74 条断言 ↔ 106 条修复）
#=========================================================================
#   目的：找出「修过但**没有被断言锁住**」的条目 —— 那些修复会在将来
#   被人无意改回而**没有任何东西会响**。
#
#   ★ 判据只能是**候选**，不能是结论：
#     断言名是自然语言（如「Light 的数值 getter 不返回 nil」），
#     修复名也是自然语言 —— 两者之间**没有稳定的一一映射**。
#     任何自动匹配都必然有假阳/假阴。⇒ 本报告**只列候选**，
#     明确标注「需人工判断」，不当成判据用。
#   ★ 匹配方式：从修复条目的名字里抽**标识符**（英文字母/下划线组成的词，
#     长度 ≥4，排除常见词），看有没有一个出现在 tests.lua 里。
#=========================================================================
# ★★ T43：覆盖率报告的**排除规则**（把 20 条候选收敛成可看的短名单）
#=========================================================================
#   问题：第一版报告里 20 条候选，**12 条是工具类**条目
#   （`tools/*.py` 的修复）—— 那些由各自的**自检**保障，本来就不该进 tests.lua。
#   把它们混在里面，会让真正需要看的条目被淹没（**报告太长 = 报告没用**）。
#
#   两条排除规则：
#     ① 路径在 `tools/` 下的 ⇒ 排除（工具由自身自检保障）；
#     ② `COVERAGE_REVIEWED` 里登记过的 ⇒ 排除（人工复核过，附理由）。
COVERAGE_REVIEWED = {
    # 名称片段 → 复核结论。★ 必须是**复核过**的，不能凭印象写。
    "PhysicsWaker": "T42 已补断言（tests.lua T24）",
    "MissingHits": "T42 已补断言（tests.lua T24）",
    "Map 同时写": "T42 已补断言（tests.lua T24）",
    "emitters.lua 进启动序列": "T42 已补断言（tests.lua T24）",
    "更新泵分桶表全局": "T42 已补断言（tests.lua T24）",
    "包装器判据：当前值是不是我的包装器": "T19 世界根断言已间接覆盖",
    "LOC 从 loc.lua": "T20 已有「LOC 可用且 GetTextScale 返回数字」断言",
    "可达性抽样成为正式入口": "入口本身就是 14 入口之一，PASS 即验证",
}


def coverage_candidates():
    tp = os.path.join(ROOT, 'tests.lua')
    if not os.path.exists(tp):
        return None
    tests = io.open(tp, encoding='utf-8', errors='replace').read()
    STOP = {'host', 'lua', 'with', 'from', 'this', 'that', 'true', 'false',
            'test', 'tests', 'code', 'name', 'file', 'line', 'http'}
    cand, excluded = [], []
    for name, rel, marker in CHECKS:
        # 规则①：工具类（由自身自检保障）
        if rel.startswith('tools/'):
            excluded.append((name, rel, '工具类（有自身自检）'))
            continue
        # 规则②：人工复核过的
        hit = [r for k, r in COVERAGE_REVIEWED.items() if k in name]
        if hit:
            excluded.append((name, rel, hit[0]))
            continue
        toks = set(re.findall(r'[A-Za-z_][A-Za-z0-9_]{3,}', name + ' ' + marker))
        toks = {t for t in toks if t.lower() not in STOP}
        if not toks:
            cand.append((name, rel, '（无可抽标识符）'))
            continue
        if not any(t in tests for t in toks):
            cand.append((name, rel, '、'.join(sorted(toks)[:3])))
    return cand, excluded


#=========================================================================
# ★★ T45：**歧义锚点**检查（「锚点必须行首锚定」的机械化）
#=========================================================================
#   由来：今天两次事故都是同一个形态 —— **同一个字符串在目标文件里
#   既以「代码」身份出现、又以「字符串/注释内容」身份出现**：
#     · 我把新函数插到了 `src.find('def main():')` 这句**字符串里**，
#       因为 `'def main():'` 在文件里出现两次（一次是代码、一次是字符串内容）
#       ⇒ `replace(..., 1)` 命中的是**字符串里那次**，整个文件被写坏；
#     · 更早的 `lower_components_shadow` 也是「词在 ≠ 行为在」。
#
#   ⇒ 判据：**一个特征串在目标文件里只应以一种身份出现**。
#     若同时出现在 code 与 message（字符串）里 ⇒ **高危**（自动替换会打错地方）；
#     同时出现在 code 与 comment 里 ⇒ **中危**（人读没问题，程序改会踩）。
#
#   ★ 这不是「修复不存在」—— 那些特征串**确实在**，所以它**不是失败**，
#     是**提示**：告诉下一个人「你要动它时，别用第一次出现的那个位置」。
SEVERITY_ORDER = {'code+message': 0, 'code+comment': 1}

# ★★ T51 的豁免清单：有些特征串**本质就是数据名**，只在字符串里出现是**正确**的 ——
#   强行改成代码锚点反而是错的（数据名没有「行为」可指）。
#   ★ 豁免必须**逐条附理由**，不能整类放过 —— 否则豁免会变成「什么都放过」。
STRING_OK = {
    "inventoryimages1.xml":
        "资源文件名（图集导出工具的目标列表之一）—— 数据名，没有行为可指",
}


def exemption_problems():
    """T53：豁免清单的**自检** —— 豁免必须真的被论证过，且不能过期。

    两个风险：
      ① **空理由/占位理由** ⇒ 豁免退化成「什么都放过」（豁免的理由是唯一约束）；
      ② **过期豁免** ⇒ 被豁免的特征串在 CHECKS 里已经不存在了，
         留着它会让下一个人以为「这里有个已论证的例外」。
    """
    problems = []
    markers_in_use = {m for _n, _r, m in CHECKS}
    for marker, reason in STRING_OK.items():
        if not isinstance(reason, str) or len(reason.strip()) < 8:
            problems.append("豁免「%s」的理由太短或为空 —— 豁免必须附**实质理由**"
                            % marker[:40])
        if marker not in markers_in_use:
            problems.append("豁免「%s」**已过期** —— CHECKS 里已经没有用这个特征串的条目"
                            % marker[:40])
    return problems


def self_satisfying_markers():
    """找出**自满足特征串**：特征串只出现在 **CHECKS 表自身**里。

    ★★★ 为什么单列这一类（本轮最重要的一条）：
    一个条目如果拿「自己在表里写的那串字」当特征串，那么
    **无论被守护的行为在不在，检查永远都「在」** —— 它连「词在」都不算，
    只是**抄了自己的名字**。
    实测后果：`context = prev + line` 那条自满足条目，在我重写 `_position_of`
    时**顺手删掉了它守护的逻辑**之后，**仍然一直是绿的** ——
    一个已经消失的行为，被一个永远为真的检查「守护」了很久。

    ⚠️ 判据只对**目标是本文件**的条目有效（跨文件的特征串不可能出现在本表里）。
    """
    self_path = os.path.abspath(__file__)
    try:
        src = io.open(self_path, encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    # CHECKS 表的源码区间
    i = src.index('CHECKS = [')
    j = src.index('\n]', i) + 2
    out = []
    for name, rel, marker in CHECKS:
        if os.path.abspath(os.path.join(ROOT, rel)) != self_path:
            continue                       # 只对本文件条目有意义
        occ, pos = [], 0
        while True:
            k = src.find(marker, pos)
            if k == -1:
                break
            occ.append(k)
            pos = k + 1
        if occ and all(i <= k < j for k in occ):
            out.append((name, rel, marker, occ))
    return out


def ambiguous_markers():
    """返回 (高危, 中危) 两个列表：特征串在目标文件里以**多种身份**出现。"""
    high, mid = [], []
    seen = set()
    self_path = os.path.abspath(__file__)
    for name, rel, marker in CHECKS:
        key = (rel, marker)
        if key in seen:
            continue
        seen.add(key)
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        # ★★ 目标是**本文件自身**的条目，**本质上必然歧义** ——
        #   因为特征串总会在 CHECKS 表里以字符串身份出现**一次**（这是它自己的定义处），
        #   再在代码里出现一次。这是**结构性的**，不是疏漏。
        #   ⇒ 豁免它们，改由 **`self_satisfying_markers()`** 覆盖另一个风险：
        #     那一条查的是「特征串**只**在表里、代码里根本没有」——
        #     这才是真正危险的情形（条目自己满足自己）。
        if os.path.abspath(path) == self_path:
            continue
        kinds, n = _position_of(
            io.open(path, encoding='utf-8', errors='replace').read(), marker)
        if len(kinds) < 2:
            continue
        rec = (name, rel, marker, sorted(kinds), n)
        if 'string' in kinds:
            high.append(rec)
        else:
            mid.append(rec)
    return high, mid


def main():
    if '--coverage' in sys.argv:
        r = coverage_candidates()
        if r is None:
            print('  ✘ 打不开 tests.lua')
            return 2
        cand, excluded = r
        print('  断言覆盖率**候选**报告  ——  %d 条修复里，%d 条待看（已排除 %d 条）'
              % (len(CHECKS), len(cand), len(excluded)))
        print('  排除规则：① `tools/` 下的工具类（由自身自检保障）'
              '；② COVERAGE_REVIEWED 里复核过的')
        print('  ' + '─' * 68)
        for n, rel, tk in cand:
            print('    · %-44s %s' % (n[:44], rel))
            print('        抽出标识符：%s' % tk)
        print('  ' + '─' * 68)
        print('  ★ 这是**候选**不是结论：断言名与修复名都是自然语言，')
        print('    自动匹配必然有假阳（如「补了字段」这类无标识符的描述）。')
        print('    **需人工过一遍**：确认是真的没断言，还是只是描述里没出现标识符。')
        return 0

    if '--quality' in sys.argv:
        q = marker_quality()
        print('  特征串质量分级  ——  共 %d 条' % len(q))
        print('  ' + '─' * 68)
        for label, desc in (('string', '★ 只出现在**字符串字面量**里（一改措辞就断）'),
                            ('comment', '只出现在注释里（较稳，但仍是文本）'),
                            ('code', '出现在可执行语句里（最稳）')):
            grp = [t for t in q if t[3] == label]
            print('  %-8s %3d 条   %s' % (label, len(grp), desc))
            if label == 'message':
                for n, rel, mk, _k, cnt in grp:
                    print('        · %-38s %s:%s  ×%d' % (n[:38], rel, mk[:30], cnt))
        print('  ' + '─' * 68)
        print('  ★ 判据：`message` 类**不是错**，但它「修复不在」时也可能仍然通过 ——')
        print('    因为消息文本本身就还在。要区分「修复在」与「串在」，')
        print('    只能把特征串指向**行为**（code/comment）。')
        return 0

    if '--list' in sys.argv:
        for i, (n, p, m) in enumerate(CHECKS, 1):
            print("  %2d. %-40s %s" % (i, n, p))
        return 0

    print("  修复清单核对  ——  %d 条" % len(CHECKS))
    print("  " + "─" * 68)
    missing = []
    for name, rel, marker in CHECKS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            missing.append((name, rel, "文件不存在"))
            print("  ✘ %-40s 文件不存在: %s" % (name, rel))
            continue
        src = open(path, encoding='utf-8', errors='replace').read()
        if marker in src:
            pass
        else:
            missing.append((name, rel, marker))
            print("  ✘ %-40s 缺特征串 %r（%s）" % (name, marker, rel))

    print("  " + "─" * 68)
    print("  共 %d 条，缺失 %d 条" % (len(CHECKS), len(missing)))

    # ★★ T40：把特征串**质量**接进默认输出（原先要显式 `--quality` 才跑）。
    #   理由：质量问题是**慢性**的 —— 不会当场报错，但会让将来的误判变多。
    #   只在默认路径里**提示**（warn），不判失败：
    #     `message` 类**不是错**（它照样能用），只是「修复不在也可能通过」。
    q = marker_quality()
    n_msg = len([t for t in q if t[3] == 'string'])
    n_cmt = len([t for t in q if t[3] == 'comment'])
    print("  特征串质量：string %d（只在字符串里）/ comment %d（只在注释里）/ code %d"
          % (n_msg, n_cmt, len(q) - n_msg - n_cmt))
    print("      （`--quality` 看明细）")
    if n_msg > 0:
        print("  ⚠ 有 %d 条特征串只出现在**字符串字面量**里 —— 一改措辞就会断："
              % n_msg)
        for nm, rel, mk, _k, _c in [t for t in q if t[3] == 'string']:
            print("      · %-38s %s" % (nm[:38], mk[:40]))
        # ★★ T61：不只提示 —— **返回非 0**，把「新条目必须过特征串质量」变成**流程**。
        #   逃生口只有一个：`STRING_OK`（**逐条附理由**，且自带「未过期」自检）。
        #   ★ 为什么不留 `--no-strict-quality` 之类的开关：那会让「忽略质量」
        #     变成**零成本的习惯动作**，等于没有约束。要让「忽略」有代价 ——
        #     必须写下理由并登记。
        print("  ✘ 判定不过（退出码 1）—— 要么把特征串改指**行为**，要么登记豁免（附理由）")
        return 1

    # ★★ T53：豁免清单自检
    ex = exemption_problems()
    if ex:
        print("  ✘ 豁免清单有问题 %d 条：" % len(ex))
        for e in ex:
            print("      · %s" % e)
    else:
        print("  豁免清单：%d 条，理由齐备且未过期 ✔" % len(STRING_OK))

    # ★★★ 「自满足特征串」——最阴的一类假 ✅
    ss = self_satisfying_markers()
    if ss:
        print("  ✘ 自满足特征串 %d 条 —— 特征串只出现在 CHECKS 表自身里：" % len(ss))
        print("     这类条目**无论被守护的行为在不在都会通过**（它只是抄了自己的名字）。")
        for nm, rel, mk, occ in ss:
            print("      · %-36s %s" % (nm[:36], mk[:40]))
    else:
        print("  自满足特征串：0 条 ✔")

    # ★★ T45：歧义锚点（今天两次事故的形态）——**提示，不是失败**
    high, mid = ambiguous_markers()
    print("  歧义锚点：高危 %d 条（code+字符串）/ 中危 %d 条（code+注释）"
          % (len(high), len(mid)))
    if high:
        print("  ⚠ 以下特征串**同时**以「代码」和「字符串内容」出现 ——")
        print("     自动替换（如 str.replace）会命中**字符串里那一次**，今天已因此写坏过文件：")
        for nm, rel, mk, k, _c in high:
            print("      · %-38s %s  %s" % (nm[:38], rel, mk[:34]))
    if not missing:
        print("  ✔ 该有的修复全部在位")
    else:
        print("  ★ 有 %d 条修复缺失 —— 很可能是文件被覆盖/恢复不完整。" % len(missing))
        print("    逐条对照报告与工作日志确认「这些修复本该在不在」。")
    return 0 if not missing else 1


if __name__ == '__main__':
    sys.exit(main())
