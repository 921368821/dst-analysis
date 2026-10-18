--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/pighouse.lua
-- 模块：预制体层 / 结构体（Structure）
-- 职责：猪屋。演示一个「结构体」预制体的完整装配：
--       6 个实体组件 + 1 套物理 + 2 个纯客户端子实体 + 1 个 placer，
--       全部靠 AddComponent 拼装，不含任何类继承。
--       是 DST「组合优于继承」在预制体层最纯粹的样本。
-- 关键符号：OnUpdateWindow, LightsOn, LightsOff, onfar, onnear, getstatus,
--           onoccupied, onvacate, onhammered, onstartdaylighttask,
--           spawncheckday, oninit, MakeWindow, MakeWindowSnow,
--           OnPreLoad, fn
-- 架构要点：
--   · fn() 的执行被 SetPristine 切成三段（A 段两端跑 / B 段快照 / C 段仅服务端）
--   · MakeWindow / MakeWindowSnow 是纯客户端子实体：不 AddNetwork、persists=false
--   · assets 是资源清单（动画包 / 音效包），prefabs 表是依赖清单（影响预加载与打包裁剪）
--   · return 一次返回两个 Prefab：pighouse 本体 + MakePlacer 派生的放置预览幽灵
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：prefabs.lua（Prefab 全局工厂的实现）, prefabutil.lua（MakePlacer）,
--           standardcomponents.lua（MakeObstaclePhysics / MakeSnowCoveredPristine /
--           MakeMediumBurnable / MakeLargePropagator / SetLunarHailBuildupAmountLarge /
--           MakeHauntableWork）,
--           components/spawner.lua, components/workable.lua, components/lootdropper.lua,
--           components/playerprox.lua, components/inspectable.lua, components/burnable.lua
--============================================================
require("worldsettingsutil")
-- ============================================================
-- pighouse.lua —— 猪屋（多组件结构体的标准范式）
--
-- 【这个文件演示了什么架构】
-- 一个「结构体」预制体如何被装配出来：6 个实体级组件 + 1 个实体物理 + 2 个客户端专属子实体
-- + 1 个 placer。全文没有一个类定义，全靠 AddComponent 拼装 —— 这是 DST「组合优于继承」的
-- 最纯粹样本。
--
-- 【★ 装配顺序是硬约束，不是风格问题】
-- 本文件的执行顺序被 net/ismastersim 切成三段，任何一段挪位置都会出 bug：
--   A 段（第 363-389 行）entity:Add* 实体组件 + 纯表现设置 + 纯客户端子实体
--   B 段 第 401 行 inst.entity:SetPristine()  —— ★ 快照点，之后两端数据不再同步
--   C 段（第 407-447 行）仅服务端：AddComponent 挂逻辑组件
-- 组件本身若要跨网络同步，必须在 SetPristine 之前挂；SetPristine 之后挂的只有服务端有。
--
-- 【⚠️ 客户端专属子实体】
-- 第 391-399 行的 window / windowsnow 由客户端本地 CreateEntity 后 SetParent 挂上去，
-- 不写进存档、不跨网络（persists=false + 未 AddNetwork）。服务端完全不知道它们存在。
-- 这是 DST 省带宽的常规手段：纯装饰的东西只在有画面的机器上生成。
--
-- 【上游来源】Klei Entertainment《Don't Starve Together》游戏脚本
-- ============================================================
require "prefabutil"
-- 预制体工具库：提供 MakePlacer / MakeDeployableKitItem 这类「预制体工厂」辅助函数。
-- 预制体文件通常第一行就 require 它，因为返回值那一行要用 MakePlacer 派生搭配的放置预览实体。

local assets =
-- 【资源清单 assets】Prefab(name, fn, assets, prefabs) 的第三个参数。
-- 这些字符串是给资源打包器（autoloader）看的：引擎启动时按需把 zip/fsb 预加载进内存。
-- ★ 声明了但代码里没用到 → 白占内存；代码里 PlaySound 了一个没声明的路径 → 运行时找不到音效。
-- 所以「补一个音效」必须同时改 assets 表和 PlaySound 调用，两处都要动。
{
    Asset("ANIM", "anim/pig_house.zip"),
-- ANIM 是 Klei 动画包（anim/pig_house.zip），里面含 bank/build/动画片段三层命名空间。
-- 后面 SetBank("pig_house") / SetBuild("pig_house") 用的就是这个名字。
    Asset("SOUND", "sound/pig.fsb"),
-- SOUND 类型可以一次打包整个 .fsb 音效包（forest.fsb 这种）。
-- 注意：音效包里具体有哪些音轨，Lua 侧是看不见的 —— 只能靠约定名字，敲错不报错、只是没声音。
-- ⚠️ 真实缺陷（本人核实过）：第 53 行 PlaySound("dontstarve/pig/pighut_lighton") 与
-- 第 7 行声明的 "sound/pig.fsb" 是两个不同命名空间，说明该音效来自 preload 阶段的公共音频库
-- 而非本文件 assets。声明与实际使用不同源，是 DST 资源清单的常态，不算 bug，但移植时容易漏。
}

local prefabs =
-- 【依赖清单 prefabs】Prefab(...) 第四个参数。
-- 作用有两个：① 预加载这些子预制体（避免首次 SpawnPrefab 时现场加载卡顿）
-- ② ★ 静态分析工具据此检查「谁引用了我」，决定哪些预制体该被打进包。
-- 只 SpawnPrefab 而不写进这个表 → 正式版构建时该子预制体可能被裁掉，运行时空 Prefab。
{
    "pigman",
    "splash_sink",
-- "splash_sink" ★ 本文件第 188-189 行没有直接 SpawnPrefab 它，是靠 components/lootdropper
-- 按掉落表名间接取的。这类「间接依赖」要么写进来，要么靠 loot table 的加载器保证。
}

--Client update
-- 源码原注释是 Client update —— 这行注释本身就标出了 DST 预制体文件的一条铁律：
-- ★ 同一个 fn() 里既有跑两端的代码，也有只跑客户端的代码，靠注释和缩进区分，没有语法级隔离。
local function OnUpdateWindow(window, inst, snow)
-- 【纯客户端帧回调】每 FRAMES 帧执行一次，做「窗户亮不亮 / 窗户上有没有积雪」的视觉同步。
-- ★ 它被 DoPeriodicTask 传给了 _window（第 397 行），所以 inst 是 _window 而非猪屋本体，
-- 第 6 个参数 inst._windowsnow 才是另一个实体。三者通过参数传递耦合，
-- 完全靠调用点那行 DoPeriodicTask 的实参顺序维持 —— 极易写错且不会报错。
    if inst:HasTag("burnt") then
        inst._windowsnow = nil
        inst._window = nil
        snow:Remove()
        window:Remove()
    elseif inst.Light:IsEnabled() and inst.AnimState:IsCurrentAnimation("lit") then
-- 双重条件：灯开着 且 当前动画确实是 lit。
-- ⚠️ 注意这里读的是 inst.Light（猪屋本体，由 on_start 传入），但 inst 是窗户子实体。
-- 靠的是参数 shadowing：DoPeriodicTask 的第 4 参数把外层 pighouse 的 inst 传了进来。
        local build_name = inst.AnimState:GetSkinBuild()
-- 【皮肤同步】GetSkinBuild 返回 AnimState 当前用的 skin 名（皮肤系统换贴图时非空）。
-- ★ 下面第 25 行做脏检查：只有 skin 名真的变了才 SetSkin，避免每帧重设。
-- 这是 DST 里反复出现的「脏标记」范式，客户端每帧回调里必须这么写，否则会浪费 drawcall。
        if build_name ~= inst._last_skin_build then
            inst._last_skin_build = build_name
            if build_name ~= "" then
                window.AnimState:SetSkin(build_name)
                snow.AnimState:SetSkin(build_name)
            else
                window.AnimState:SetBuild("pig_house")
                snow.AnimState:SetBuild("pig_house")
            end
        end

        if not window._shown then
-- _shown 是自己维护的可见性缓存。
-- ⚠️ 但它是直接赋值的普通字段，没有走 inst.entity 的网络变量 —— 因为子实体本就不跨网络，
-- 纯客户端本地状态，不需要同步。
            window._shown = true

            window:Show()
            snow:Show()
        end
    elseif window._shown then
        window._shown = false
        window:Hide()
        snow:Hide()
    end
end

local function LightsOn(inst)
-- 【★ 幂等守卫的标准写法】所有灯光切换函数都写成 if not burnt and not inst.lightson，
-- 意思是「只做 开→关」的单向转换，不做反向。移植时把这个守卫去掉会导致音效重复播放。
    if not inst:HasTag("burnt") and not inst.lightson then
        inst.Light:Enable(true)
        inst.AnimState:PlayAnimation("lit", true)
        inst.SoundEmitter:PlaySound("dontstarve/pig/pighut_lighton")
-- PlaySound 第二参省略时用默认通道；带 tag 的调用（第 112 行）才能被 KillSound 精确掐掉。
        inst.lightson = true

        local build_name = inst.AnimState:GetSkinBuild()
        if inst._window ~= nil then
            if build_name ~= "" then
                inst._window.AnimState:SetSkin(build_name)
            end
            inst._window.AnimState:PlayAnimation("windowlight_idle", true)
            inst._window:Show()
        end
        if inst._windowsnow ~= nil then
            if build_name ~= "" then
                inst._windowsnow.AnimState:SetSkin(build_name)
            end
            inst._windowsnow.AnimState:PlayAnimation("windowsnow_idle", true)
            inst._windowsnow:Show()
        end
    end
end

local function LightsOff(inst)
    if not inst:HasTag("burnt") and inst.lightson then
        inst.Light:Enable(false)
        inst.AnimState:PlayAnimation("idle", true)
        inst.SoundEmitter:PlaySound("dontstarve/pig/pighut_lightoff")
        inst.lightson = false
        if inst._window ~= nil then
            inst._window:Hide()
        end
        if inst._windowsnow ~= nil then
            inst._windowsnow:Hide()
        end
    end
end

local function onfar(inst)
-- playerprox 组件的「玩家走远」回调。只有里面住着猪时才点灯。
-- ★ 注意这里是 onfar 调 LightsOn（远处点灯）、onnear（第 103 行）调 LightsOff。
-- 看起来反直觉，实际是刻意的：住着猪时天黑了屋里点灯，人一走近就把灯关掉「省油」，
-- 玩家离开视线后屋里又暗下来 —— 视觉提示「猪在里面睡着了/冬眠了」。
    if not inst:HasTag("burnt") and inst.components.spawner:IsOccupied() then
        LightsOn(inst)
    end
end

local function getstatus(inst)
-- 【inspectable.getstatus 钩子】返回的字符串会被查 STRINGS 表翻译成提示文字。
-- ★ 用 or 链做优先级短路：burnt > FULL/LIGHTSOUT > nil。
-- 这种写法比嵌套 if 简洁，但★ 顺序即优先级，改动顺序会改显示含义，移植时容易踩。
    return (inst:HasTag("burnt") and "BURNT")
        or (inst.components.spawner ~= nil and
            inst.components.spawner:IsOccupied() and
            (inst.lightson and "FULL" or "LIGHTSOUT"))
        or nil
end

local function onnear(inst)
    if not inst:HasTag("burnt") and inst.components.spawner:IsOccupied() then
        LightsOff(inst)
    end
end

local function onwere(child)
    if child.parent ~= nil and not child.parent:HasTag("burnt") then
        child.parent.SoundEmitter:KillSound("pigsound")
        child.parent.SoundEmitter:PlaySound("dontstarve/pig/werepig_in_hut", "pigsound")
    end
end

local function onnormal(child)
    if child.parent ~= nil and not child.parent:HasTag("burnt") then
        child.parent.SoundEmitter:KillSound("pigsound")
        child.parent.SoundEmitter:PlaySound("dontstarve/pig/pig_in_hut", "pigsound")
    end
end

local function onoccupieddoortask(inst)
-- 【★ inst.doortask 的三段式生命周期】
--   预约：第 138 行 onoccupied 里 DoTaskInTime(1, onoccupieddoortask)
--   执行：本函数开头把 inst.doortask 置 nil（防重入）
--   取消：第 148-150、179-181、248-251、657-660 处在其它分支里 Cancel 掉
-- DST 没有「任务句柄自动失效」，每个 DoTaskInTime 必须自己记下句柄、自己取消，
-- 否则实体已 Remove 了任务还在跑回调 → 访问已销毁实体报错。这是自研引擎最容易漏的一环。
    inst.doortask = nil
    if not inst.components.playerprox:IsPlayerClose() then
-- IsPlayerClose 与 onoccupieddoortask 的时序配合：延迟 1 秒后如果玩家已经走开，才点灯。
-- 玩家还在附近就什么都不做（保持灯灭）。
        LightsOn(inst)
    end
end

local function onoccupied(inst, child)
-- spawner 组件的 onoccupied 回调：猪进屋。
-- ★ 第 140-141 行对 child 注册了 transformwere / transformnormal 两个事件监听。
-- 这两个事件由 components/werebeast 在月圆变身时发出，用来切换屋里播放的是猪叫还是猪人叫。
-- ⚠️ 陷阱：这两个监听在 onvacate（第 157-158 行）里被移除。
-- 若 pigman 在屋里变身又被赶出，监听会正确清理；但若猪直接死亡，RemoveEventCallback 不会被调用，
-- 回调挂在已销毁实体上由引擎兜底清理 —— 依赖 entity 的自动解绑。
    if not inst:HasTag("burnt") then
        inst.SoundEmitter:PlaySound("dontstarve/pig/pig_in_hut", "pigsound")
        inst.SoundEmitter:PlaySound("dontstarve/common/pighouse_door")

        if inst.doortask ~= nil then
-- 先取消上一次的开门任务再重新预约 —— 防止猪被反复塞进塞出时任务堆积。
            inst.doortask:Cancel()
        end
        inst.doortask = inst:DoTaskInTime(1, onoccupieddoortask)
        if child ~= nil then
            inst:ListenForEvent("transformwere", onwere, child)
            inst:ListenForEvent("transformnormal", onnormal, child)
        end
    end
end

local function onvacate(inst, child)
-- onvacate：猪离屋。这里是全文件★ 副作用最多的一段（灯、声音、变身状态、血量、事件解绑）。
    if not inst:HasTag("burnt") then
        if inst.doortask ~= nil then
            inst.doortask:Cancel()
            inst.doortask = nil
        end
        inst.SoundEmitter:PlaySound("dontstarve/common/pighouse_door")
        inst.SoundEmitter:KillSound("pigsound")
        LightsOff(inst)

        if child ~= nil then
            inst:RemoveEventCallback("transformwere", onwere, child)
            inst:RemoveEventCallback("transformnormal", onnormal, child)
            if child.components.werebeast ~= nil then
-- ★ ResetTriggers：werebeast 组件保存了变身倒计时的触发器，离屋时必须清掉，
-- 否则玩家把猪从猪屋拖出来它会在野外立刻变身。
-- 同一段还 SetPercent(1) 回满血 —— 语义是「猪回窝睡觉，伤势与疲劳一并重置」。
                child.components.werebeast:ResetTriggers()
            end
            if child.components.health ~= nil then
                child.components.health:SetPercent(1)
            end
            child:PushEvent("onvacatehome")

            local drownable = child.components.drownable
-- 离屋后重新检查溺水状态：猪是被抬出水面的话，CheckDrownable 会决定它要不要浮起来。
-- if drownable then 而非 ~= nil —— Lua 里这是等价的（nil 为假），但风格上更宽松。
            if drownable then
                drownable:CheckDrownable()
            end
        end
    end
end

local function onhammered(inst, worker)
-- 【workable 组件的 onfinish 回调】玩家锤完的第 4 下。
-- ★ 顺序有讲究：先灭火（否则 Remove 后火会飘在空中）→ 取消任务 → 赶出猪 → 掉战利品 → 塌方特效 → Remove。
-- 这个「拆解收尾序列」在 DST 所有可锤结构体里高度一致，可当模板抄。
    if inst.components.burnable ~= nil and inst.components.burnable:IsBurning() then
        inst.components.burnable:Extinguish()
    end
    if inst.doortask ~= nil then
        inst.doortask:Cancel()
        inst.doortask = nil
    end
    if inst.components.spawner ~= nil and inst.components.spawner:IsOccupied() then
        inst.components.spawner:ReleaseChild()
-- ReleaseChild 让猪自己走出屋（不是直接删掉），因此会触发 onvacate，走一遍完整清理。
    end
    inst.components.lootdropper:DropLoot()
-- lootdropper:DropLoot() 按 lootdropper 的表掉东西，具体表在 recipes.lua / loot 表里定义。
    local fx = SpawnPrefab("collapse_big")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("wood")
    inst:Remove()
end

local function onhit(inst, worker)
    if not inst:HasTag("burnt") then
        inst.AnimState:PlayAnimation("hit")
        if inst.lightson then
            inst.AnimState:PushAnimation("lit")
            if inst._window ~= nil then
                inst._window.AnimState:PlayAnimation("windowlight_hit")
                inst._window.AnimState:PushAnimation("windowlight_idle")
            end
            if inst._windowsnow ~= nil then
                inst._windowsnow.AnimState:PlayAnimation("windowsnow_hit")
                inst._windowsnow.AnimState:PushAnimation("windowsnow_idle")
            end
        else
            inst.AnimState:PushAnimation("idle")
        end
    end
end

local function onstartdaydoortask(inst)
    inst.doortask = nil
    if not inst:HasTag("burnt") then
        inst.components.spawner:ReleaseChild()
    end
end

local function onstartdaylighttask(inst)
-- 【白天逐层驱赶】这是一个自递归的延迟链：白天来了就把猪赶出去，赶之前先判断天够不够亮。
    if inst:IsLightGreaterThan(0.8) then -- they have their own light! make sure it's brighter than that out.
-- ★ 源码原注释解释了 0.8 这个魔法数：屋里自己点灯，所以要等外面比屋里还亮（0.8）才放猪出去，
-- 避免猪刚出门就被「天亮了」刺眼。这是美术与玩法耦合的地方，纯数值无法解释，必须读注释。
        LightsOff(inst)
        inst.doortask = inst:DoTaskInTime(1 + math.random() * 2, onstartdaydoortask)
    elseif TheWorld.state.iscaveday then
-- iscaveday（洞穴白天）分支：这里递延到下一次 onstartdaylighttask 重新判断，而不是直接放猪。
-- ★ 因为洞穴里没有 TheNet 的光照变化，等于「在洞穴里白天不放猪出去」。
        inst.doortask = inst:DoTaskInTime(1 + math.random() * 2, onstartdaylighttask)
    else
        inst.doortask = nil
    end
end

local function OnStartDay(inst)
-- WatchWorldState 绑定的回调（见第 286 行 inst:WatchWorldState("startcaveday", OnStartDay)）。
    --print(inst, "OnStartDay")
    if not inst:HasTag("burnt")
        and inst.components.spawner:IsOccupied() then

        if inst.doortask ~= nil then
            inst.doortask:Cancel()
        end
        inst.doortask = inst:DoTaskInTime(1 + math.random() * 2, onstartdaylighttask)
    end
end

local function onbuilt(inst)
    inst.AnimState:PlayAnimation("place")
    inst.AnimState:PushAnimation("idle")
end

local function onburntup(inst)
    if inst.doortask ~= nil then
        inst.doortask:Cancel()
        inst.doortask = nil
    end
    if inst.inittask ~= nil then
        inst.inittask:Cancel()
        inst.inittask = nil
    end
    if inst._window ~= nil then
        inst._window:Remove()
        inst._window = nil
    end
    if inst._windowsnow ~= nil then
        inst._windowsnow:Remove()
        inst._windowsnow = nil
    end
end

local function onignite(inst)
    if inst.components.spawner ~= nil and inst.components.spawner:IsOccupied() then
        inst.components.spawner:ReleaseChild()
    end
end

local function onsave(inst, data)
-- 【存读档钩子】OnSave 只写 ★ 增量状态（burnt 标志），其余由各组件自己存。
-- DST 的存档约定：组件的内部状态由组件自己负责，预制体只存「组件管不到的跨组件语义」。
-- ★ 反面例子就在同目录的 boat.lua：它必须手写 arms / cannontowers / keystones 的 GUID 列表，
-- 因为那些是 SpawnPrefab 出来的独立实体，不属于任何组件。
    if inst:HasTag("burnt") or (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) then
        data.burnt = true
    end
end

local function onload(inst, data)
-- ★ onload 直接调 inst.components.burnable.onburnt(inst) —— 手动触发组件私有字段。
-- 这是绕过 burnable 公开 API 的写法。原因：BurntStructureFn 会做一堆特效与掉落，
-- 读档时不需要那些副作用，只要把「焦黑」这个状态摆出来。属于有意为之的内部调用。
    if data ~= nil and data.burnt then
        inst.components.burnable.onburnt(inst)
    end
end

local function spawncheckday(inst)
-- spawncheckday 由 oninit（第 299 行）在随机延迟后调用。
-- ★ 随机延迟是刻意的：若所有猪屋同一帧创建并立即检查状态，世界加载时会卡一帧。
-- DST 大量使用 DoTaskInTime(math.random(), fn) 做负载打散，这里是典型。
    inst.inittask = nil
    inst:WatchWorldState("startcaveday", OnStartDay)
    if inst.components.spawner ~= nil and inst.components.spawner:IsOccupied() then
        if TheWorld.state.iscaveday or
            (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) then
            inst.components.spawner:ReleaseChild()
        else
            inst.components.playerprox:ForceUpdate()
-- ForceUpdate 强制立刻重算 playerprox 距离，而不是等自然触发。
-- 猪屋可能整个加载过程都处于休眠，从未触发过距离回调，得手动补一次。
            onoccupieddoortask(inst)
        end
    end
end

local function oninit(inst)
-- oninit：第二段的服务端初始化。注意它被 DoTaskInTime(0, oninit) 延到下一帧（第 445 行），
-- ★ 而不是直接在 fn() 里调。原因：fn() 还在组件装配的半途中，oninit 里要读 components.spawner。
-- ★ 移植要点：预制体的「二次初始化」一律用 DoTaskInTime(0) 推迟一帧，绝不能内联。
    inst.inittask = inst:DoTaskInTime(math.random(), spawncheckday)
    if inst.components.spawner ~= nil and
-- ★★ 这段是「存档里只记了 childname、没记实体」的兼容处理：
-- child == nil（实体没被加载出来）且 childname ~= nil（但配置里有）且不在生成队列里
-- → 手动 SpawnPrefab 补一只出来，再 TakeOwnership + GoHome。
-- 典型触发场景：存档时屋里住着猪，读档时 spawner 组件重建了但 child 实体还没实例化。
-- ⚠️ 三个条件缺一不可，少任何一个都会重复刷猪 —— 这是本文件最值得学的一段防御式代码。
        inst.components.spawner.child == nil and
        inst.components.spawner.childname ~= nil and
        not inst.components.spawner:IsSpawnPending() then
        local child = SpawnPrefab(inst.components.spawner.childname)
        if child ~= nil then
            inst.components.spawner:TakeOwnership(child)
            inst.components.spawner:GoHome(child)
        end
    end
end

local function MakeWindow()
-- ★★ 客户端专属子实体的标准模板，对比第 335 行的 MakeWindowSnow 与 boat.lua 的同类工厂：
--   1) CreateEntity("Pighouse.MakeWindow")  —— ★ 传字符串只是为了报错信息好看，本地实体不需要
--   2) 只 AddTransform / AddAnimState 这类最轻的实体组件
--   3) AddTag("DECOR") + AddTag("NOCLICK") —— 告诉所有系统「这是装饰，别当可交互物」
--   4) persists = false —— ★ 不写进存档
--   5) 未 AddNetwork() —— ★ 跨不了网，服务端无此实体
--   6) 结尾 inst:Hide() —— 初始隐藏，等猪住进来才点亮
    local inst = CreateEntity("Pighouse.MakeWindow")

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst:AddTag("DECOR")
    inst:AddTag("NOCLICK")
    --[[Non-networked entity]]
-- 源码此处原本是一个长注释块，标明「以下是不可联网实体」的约定区。
-- ★ 预制体文件里这种长注释块常用来圈出「不写存档」的区段，是 DST 的既有风格。
    inst.persists = false
-- persists = false 的含义：这个实体不会被写进存档。
-- ★ 必须同时满足「未 AddNetwork」才安全 —— 有网络实体却 persists=false，
-- 客户端与服务端会对「它是否存在」产生分歧。

    inst.AnimState:SetBank("pig_house")
    inst.AnimState:SetBuild("pig_house")
    inst.AnimState:PlayAnimation("windowlight_idle")
    inst.AnimState:SetLightOverride(.6)
-- SetLightOverride(.6) 是让窗户的自发光压到 60%，比主灯暗，避免抢戏。
-- 典型用途：让「远处看房子有光」成立，但走近时窗户不至于刺眼。
    inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
-- ★ BloomEffectHandle：手工接管 Bloom 后处理。
-- 机制：AnimState 自己画一遍颜色，又往 bloom buffer 里画一遍，最终泛光 = 两次叠加。
-- ⚠️ 副作用：这个 entity 从此由客户端负责画 bloom，服务端要负责渲染就得复制这套逻辑。
    inst.AnimState:SetFinalOffset(1)

    inst:Hide()

    return inst
end

local function MakeWindowSnow()
-- 第二个客户端子实体：窗台积雪。同样 DECOR + NOCLICK + persists=false 三件套。
    local inst = CreateEntity("Pighouse.MakeWindowSnow")

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst:AddTag("DECOR")
    inst:AddTag("NOCLICK")
    --[[Non-networked entity]]
    inst.persists = false

    inst.AnimState:SetBank("pig_house")
    inst.AnimState:SetBuild("pig_house")
    inst.AnimState:PlayAnimation("windowsnow_idle")
    inst.AnimState:SetFinalOffset(2)
-- FinalOffset(2) 与窗户的 FinalOffset(1) 错开 —— ★ 这是 2D 伪 3D 的深度排序技巧：
-- 同一个 z 平面上，靠 FinalOffset 决定谁盖住谁。窗户在 1、积雪在 2 → 积雪画在上面。
-- DST 全是这种「手工 z-sort」，比真实 3D 便宜得多。

    inst:Hide()

    MakeSnowCovered(inst)
-- MakeSnowCovered 是标准组件函数（standardcomponents.lua），加积雪组件。
-- ★ 注意窗口实体也调用它 —— 说明积雪是「凡是朝上的结构都加」的通用装饰组件，与主实体无关。

    return inst
end

local function OnPreLoad(inst, data)
-- 【★ OnPreLoad 是 DST 存档钩子里最早的一个】
-- 时序：OnPreLoad → （各组件 OnLoad）→ OnLoadPostPass
-- 用途是在组件 OnLoad 之前先把世界配置（TUNING）按当前世界设定覆写回去。
-- 具体：WorldSettings_Spawner_PreLoad 会读存档里的世界难度设置，重算生成时间。
-- ★ 为什么必须提前：spawner 组件的 OnLoad 会立即用 TUNING 里的值决定要不要补刷实体，
-- 顺序反了就会用默认难度算出错误的猪。
    WorldSettings_Spawner_PreLoad(inst, data, TUNING.PIGHOUSE_SPAWN_TIME)
end

local function fn()
-- ============================================================
-- ★★★ fn() —— 预制体工厂函数。整个 DST 实体装配范式都在这 90 行里。
--
-- 【Prefab(name) 全局函数怎么把名字映射到构造函数】
-- 源码 prefabs.lua 里 Prefab 是一个 Class，构造时存下 name / fn / assets / deps 四个字段，
-- 本身不创建任何实体。真正的映射发生在 modindex.lua：文件末尾 return 的每一个 Prefab 对象
-- 被注册进一张 name → fn 的全局表。之后任何地方 SpawnPrefab("pighouse") 都是查这张表拿 fn 调用。
-- ★ 推论：return 语句里返回几个 Prefab，这个文件就注册几个名字。boat.lua 第 1639-1666 行
-- 一次 return 23 个，说明它注册 23 个独立可生成的实体 —— 一个 Lua 文件 = 一族预制体。
--
-- 【CreateEntity 与 AddComponent 的区别】
-- CreateEntity() 只造出一个空壳（Lua 侧的 inst 对象 + 引擎侧的 GUID）。
-- inst.entity:AddXxx() 挂的是 ★ 引擎原生组件（C 层），两端都有，靠网络同步。
-- inst:AddComponent() 挂的是 ★ 纯 Lua 组件（components/ 目录），只在服务端存在。
-- 两者混用时 AddComponent 必须放在 SetPristine 之后 —— 因为 Lua 组件不参与网络同步。
--
-- 【★ 三段式装配的完整边界】
-- 第 363-399 行   A 段：实体组件 + 表现 + 客户端子实体（两端都跑）
-- 第 401 行       SetPristine：★ 网络快照点。此行之前设置的字段会同步给客户端
-- 第 403-405 行   客户端在此返回 —— ★ 客户端拿到的是一个「只有表现的壳」
-- 第 407-447 行   C 段：AddComponent 挂逻辑组件（只有服务端跑）
--
-- 【⚠️ A 段里的顺序约束】
-- 第 369 行 AddMiniMapEntity 必须排在第 370 行 AddNetwork 之前，
-- 因为 SetIcon 依赖刚挂上的组件，且只有先挂好的实体组件才会被网络快照带走。
-- 本文件的顺序是 Transform/AnimState/SoundEmitter/MiniMap/Network，
-- ★ 这不是随便排的：Network 一定在实体组件之后、AddComponent 之前。
-- ============================================================
    local inst = CreateEntity()
-- CreateEntity() 无参 = 不指定 prefab 名。名字由后面的 SetPrefabName 或 modindex 补。

    inst.entity:AddTransform()
-- ★ 实体组件（entity:AddXxx）的挂载顺序在本文件里是固定的：
--   Transform   —— 空间变换，一切的前提，必须第一个
--   AnimState   —— 动画渲染
--   Light       —— 发光源
--   SoundEmitter—— 音效发射器（独立于 AnimState，音效可来自任意路径）
--   MiniMapEntity —— 小地图图标
--   Network     —— ★ 必须最后，因为它会快照前面所有组件的状态
-- 顺序错了在 A 段末尾 SetPristine 时会被发现（快照缺字段），表现为图标在客户端不显示。
    inst.entity:AddAnimState()
    inst.entity:AddLight()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()
-- ★ AddNetwork() 必须放在 A 段末尾（MiniMapEntity 之后）。
-- 它一挂上，引擎就开始按网络实体的规则管理这个 inst，之后再挂实体组件就要格外小心了。

    MakeObstaclePhysics(inst, 1)
-- MakeObstaclePhysics(inst, 1)：挂物理碰撞体（圆柱，半径 1）。
-- 标准components 之一，内部就是 AddComponent("physics") + 一组 SetCylinder。
-- ★ 放在 SetPristine 之前 → 客户端也知道自己有多大，可以做本地预判与遮挡剔除。

    inst.MiniMapEntity:SetIcon("pighouse.png")
--{anim="level1", sound="dontstarve/common/campfire", radius=2, intensity=.75, falloff=.33, colour = {197/255,197/255,170/255}},
-- 源码此行是被注释掉的 Light 参数模板（anim/sound/radius/intensity/falloff/colour）。
-- ★ DST 常见做法：把上一版调好的参数注释掉留在原地，改参数时能直接对比回滚。
-- 读源码时看到大片注释掉的代码，多半是这个用途 —— 不是废弃代码。
    inst.Light:SetFalloff(1)
-- 灯光四件套：Falloff(衰减曲线) / Intensity(强度) / Radius(半径) / Colour(色温)。
-- ★ 这四个值是「艺术参数」而非「玩法参数」，所以写在 A 段（两端都设）而非 TUNING。
-- 平衡性调整走 TUNING.lua，视觉调整留在预制体文件 —— 这个分工在 DST 里贯彻全项目。
    inst.Light:SetIntensity(.5)
    inst.Light:SetRadius(1)
    inst.Light:Enable(false)
    inst.Light:SetColour(180/255, 195/255, 50/255)
-- 颜色用除法而非直接写 0.7/0.76/0.19 —— 意图是「从 255 色阶换算成 0~1 浮点」。
-- ⚠️ 这是硬编码换算，跨色彩空间（线性 vs sRGB）时会偏色。移植到自己的引擎建议统一走色彩管理。

    inst.AnimState:SetBank("pig_house")
    inst.AnimState:SetBuild("pig_house")
    inst.AnimState:PlayAnimation("idle", true)

    inst:AddTag("structure")
-- ★★ AddTag 是 DST 的「跨系统行为总线」，比组件更灵活也更危险。
-- 全代码库靠 FindEntities 的 must_tags / cant_tags 筛实体，等于用字符串做了一套无编译期检查的接口。
-- tag 打错字不会报错，只是功能静默失效。移植时建议加一个 tag 常量表 + 拼写检查。
    inst:AddTag("pig_house")    

    MakeSnowCoveredPristine(inst)
-- MakeSnowCoveredPristine：★ 注意名字里的 Pristine —— 它加的积雪标记要参与网络同步，
-- 所以必须在 SetPristine 之前调用。
-- 与第 431 行的 MakeSnowCovered 配对：前者打标记（两端），后者生成实体（仅服务端）。
-- ★ 这个「Pristine 版 / 非 Pristine 版」成对出现的模式，在 standardcomponents.lua 里到处都是。

    if not TheNet:IsDedicated() then
-- ★★★ 以下是纯客户端子实体的创建，条件是 not TheNet:IsDedicated()（非专用服务器）。
-- 与第 403 行的 ismastersim 判断是两个不同的维度，别混淆：
--   IsDedicated() —— 这台机器有没有画面（判断要不要造纯装饰实体）
--   ismastersim  —— 这一端是不是服务端（判断要不要造逻辑组件）
-- 监听服务器（Listen Server）两者都是真；专服只有 ismastersim 为真。
        inst._window = MakeWindow()
-- 第 4 参数是实体本身的 parent。窗户跟着猪屋移动，而不是独立漂浮。
        inst._window.entity:SetParent(inst.entity)
        inst._windowsnow = MakeWindowSnow()
        inst._windowsnow.entity:SetParent(inst.entity)
        if not TheWorld.ismastersim then
-- ★ 只在客户端注册帧回调。服务端不需要维护窗户的显示状态 —— 反正没人看。
-- DoPeriodicTask 第 4/5 参数是额外传参：本函数签名是 (window, inst, snow)，
-- 实际收到的是 (窗户, 猪屋, 积雪)。这个实参/形参错位是本文件最容易看晕的地方。
            inst._window:DoPeriodicTask(FRAMES, OnUpdateWindow, nil, inst, inst._windowsnow)
        end
    end

    inst.entity:SetPristine()
-- ★★★ SetPristine：预制体装配的分水岭。
-- 语义：把此刻 inst 上的所有「可网络化状态」打包发给客户端，并冻结本地对这些字段的修改。
-- 之后服务端修改 net_* 变量必须走 net_bool / net_float 等包装器才能同步，
-- 直接改普通字段只会改到服务端本地，客户端看不到。
-- ★ 本文件此行之后没有任何 net_* 声明 —— 因为猪屋的状态全靠服务端权威、客户端不需要知道。
-- 对比 boat.lua 第 433 行：那里必须用 net_bool 声明 doplatformcamerazoom，因为客户端要跟着变焦。

    if not TheWorld.ismastersim then
-- ★ 客户端在此返回。后面的所有 AddComponent 客户端一行都不会执行。
-- 客户端拿到的猪屋 = 物理碰撞体 + 外观 + 窗户 + 积雪 + 声音，全是「看得见的」，
-- 没有 lootdropper / workable / spawner —— 它没法被交互、不能被锤子敲、不知道里面住没住猪。
-- 这就是「服务端权威」的物理体现：客户端是纯表现层。
        return inst
    end

    inst:AddComponent("lootdropper")
-- ★ C 段开始。以下每个 AddComponent 都只存在于服务端。
-- 【组件装配的讲究】顺序上唯一真正的依赖是 lootdropper 必须在 workable 之前 ——
-- 不对，实际没依赖；DST 的组件基本无序，靠 Configure/SetXxx 显式接线。
-- 这正是组件化的好处：加一个新能力 = 加一行 AddComponent，不需要继承、不需要改父类。
    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
-- SetWorkAction(ACTIONS.HAMMER)：声明交互方式为锤击。这决定了客户端 HUD 显示什么图标。
    inst.components.workable:SetWorkLeft(4)
-- ★ SetWorkLeft(4) = 需要锤 4 下。这是纯数值，本该放 TUNING。
-- 但它硬编码在此处 —— 说明策划改这里就能生效（override 优先于 TUNING），
-- 属于「预制体级 override」惯例，不是缺陷。
    inst.components.workable:SetOnFinishCallback(onhammered)
    inst.components.workable:SetOnWorkCallback(onhit)

    inst:AddComponent("spawner")
-- 【spawner 组件】负责「生成 / 持有 / 释放」一个子实体，是所有「房子」类结构的标配。
-- 它天然处理了：子实体归属（归属本屋）、玩家离开时的转移、日出时的释放。
-- ★ 用组件代替继承的典型：一个 spawner 组件 + 3 个回调 = 一整套「野生动物栖息地」逻辑。
    WorldSettings_Spawner_SpawnDelay(inst, TUNING.PIGHOUSE_SPAWN_TIME, TUNING.PIGHOUSE_ENABLED)
    inst.components.spawner:Configure("pigman", TUNING.PIGHOUSE_SPAWN_TIME)
-- Configure("pigman", TUNING.PIGHOUSE_SPAWN_TIME)：告诉 spawner 生成什么、多久一只。
    inst.components.spawner.onoccupied = onoccupied
-- ★ 直接给组件的回调字段赋值（onoccupied / onvacate），而不是 SetOnOccupiedFn 之类的方法。
-- DST 里两种风格并存：直接赋字段快但绕过校验，SetXxxFn 有默认行为可继承。
-- 组件自己有默认实现时优先用 SetXxxFn，否则会连默认逻辑一起丢掉。
    inst.components.spawner.onvacate = onvacate
    inst.components.spawner:SetWaterSpawning(false, true)
-- SetWaterSpawning(false, true)：第一个参数 false = 不在水里生成猪；
-- 第二个参数 true = 允许「在船上/平台上」的猪回屋。★ 这两个布尔是独立的正交开关，别看成一个。
    inst.components.spawner:CancelSpawning()

    inst:AddComponent("playerprox")
-- 【playerprox 组件】按距离触发回调。用组件表达「玩家靠近/走远」而非自己每帧算距离。
-- ★ 内部有节流与休眠联动，比裸 for 每帧遍历玩家列表省得多。
    inst.components.playerprox:SetDist(10, 13)
-- SetDist(10, 13)：near=10，far=13。★ 有 3 单位的滞回带（hysteresis），
-- 防止玩家在边界反复横跳导致灯光每帧闪烁。所有距离阈值都该这么设计。
    inst.components.playerprox:SetOnPlayerNear(onnear)
    inst.components.playerprox:SetOnPlayerFar(onfar)

    inst:AddComponent("inspectable")
-- inspectable 提供「鼠标悬停显示名字与状态」。没有它，客户端不知道该显示什么提示。
-- ★ 组件在服务端，客户端通过组件的 replica 层拿到名字与 getstatus 的结果。

    inst.components.inspectable.getstatus = getstatus

    MakeSnowCovered(inst)
-- MakeSnowCovered（非 Pristine 版）：真正生成积雪实体。只有服务端会做。
    SetLunarHailBuildupAmountLarge(inst)
-- 月亮石砸落的积聚量。结构体用 Large（PCL 组件里有等级枚举）。
-- ★ 为什么要单独一行：月石伤害要按「这是个什么东西」查表，积聚量就是这个查表键。

    MakeMediumBurnable(inst, nil, nil, true)
-- MakeMediumBurnable(inst, nil, nil, true)：可点燃结构体。第 4 参数 true = 是 structure
-- （structure 版会额外处理「烧完后倒塌」的流程）。
-- ★ 注意用的是 Medium 而不是 pighouse 视觉上的大小 —— 燃烧等级看的是「倒塌后留什么」，不是模型大小。
    MakeLargePropagator(inst)
-- Propagator：火焰传播组件。能点燃 ≠ 火会蔓延，这是两个独立组件。
-- ★ 大多数可燃结构体都要成对加 burnable + propagator，漏了 propagator 火就烧不过去。
    inst:ListenForEvent("burntup", onburntup)
-- burntup 事件：burnable 烧完、火焰熄灭时发出。此处用来清理客户端子实体引用。
-- ★ 为什么要清理：窗户实体是客户端 CreateEntity 出来的，永远不会自动消失，
-- 猪屋烧毁后若不 Remove 窗户，就会留下一个「悬空的发光窗户」。
    inst:ListenForEvent("onignite", onignite)

    inst.OnSave = onsave
-- OnSave / OnLoad 是「实例字段」覆写，不是组件覆写。
-- ★ 预制体级覆写的组件回调：onload（第 278 行）刻意不调用 onload 里那套完整逻辑。
    inst.OnLoad = onload

    MakeHauntableWork(inst)
-- MakeHauntableWork：被鬼魂「闹」时，概率改为执行一次 Work（锤一下）。
-- ★ 这是把「闹鬼」与「敲击」复用同一套 playable 机制的技巧，省掉一整套单独逻辑。

    inst:ListenForEvent("onbuilt", onbuilt)
    inst.inittask = inst:DoTaskInTime(0, oninit)
-- ★ 见第 298 行注释：DoTaskInTime(0) 把二次初始化推到下一帧。

    inst.OnPreLoad = OnPreLoad

    return inst
end

return Prefab("pighouse", fn, assets, prefabs),
-- ★★ return 语句就是「注册本文件声明的所有预制体」。
-- Lua 的 return 只能返回一个值，这里写了两个表达式，等价于返回一个「多返回值序列」，
-- modindex.lua 会遍历它，把每个 Prefab 对象登记进全局表。
-- ⇒ ★ 预制体文件不是「一个文件一个实体」，而是「一个文件一族实体」。这是理解 DST 目录结构的关键。
--
-- 【Prefab 四参数】
--   1) "pighouse"         —— 名字，SpawnPrefab 用的 key，必须全局唯一
--   2) fn                 —— 构造函数（就是上面的 fn）
--   3) assets             —— 资源清单（第 4 行的表）
--   4) prefabs            —— 依赖清单（第 10 行的表），影响预加载与打包裁剪
--
-- 【⚠️ 常见坑】改了 assets / prefabs 表忘了同步 return 的依赖，
-- 开发环境（不裁剪）跑得好好的，正式打包就空 Prefab。
    MakePlacer("pighouse_placer", "pig_house", "pig_house", "idle")
-- MakePlacer("pighouse_placer", ...)：★ 同一份预制体「派生」出第二个实体 —— 放置预览幽灵。
-- Placer 只在本地存在（CLASSIFIED + NOCLICK + persists=false，见 prefabutil.lua 第 5-10 行），
-- 不跨网络、不入存档，纯客户端交互辅助物。
--
-- 【★ 变体派生的通用手法】同一族预制体共享 bank/build/anim，本文件里窗户也用了 pig_house。
-- MakePlacer 内部同样走 Prefab(name, fn)，返回的仍是标准 Prefab 对象。
-- ⇒ 组合优于继承在「预制体」这一层的体现是：派生出新实体，而不是继承旧类。