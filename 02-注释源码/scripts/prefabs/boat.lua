--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/boat.lua
-- 模块：预制体层 / 移动平台（Boat）
-- 职责：船族。DST 里最大的一族预制体，末尾一次注册 23 个平级实体。
--       演示：资源/依赖/音效三层按变体切表、pre/post 两段式装配、
--       数据表驱动变体、运行时程序化生成碰撞网格、变体派生变体。
-- 关键符号：create_common_pre, create_master_pst, build_boat_collision_mesh,
--           boat_player_collision_template, boat_item_collision_template,
--           wood_fn, grass_fn, pirate_fn, ancient_fn, otterden_fn, ice_fn,
--           ice_crabking_fn, item_fn, common_item_fn_pre, common_item_fn_pst,
--           ondeploy, CLIENT_CanDeployBoat, SpawnFragment, AddConstrainedPhysicsObj,
--           ReticuleTargetFn, DoSpawnIceTile, DoSpawnIceWall, otterden_on_update
-- 变体清单：boat / boat_pirate / boat_ancient / boat_otterden / boat_grass /
--           boat_ice / boat_ice_crabking（7 种船）+ 10 个碰撞体 + 3 个建造物品 +
--           3 个放置预览（MakePlacer）
-- 架构要点：
--   · 每种船只写一张 XXX_BOAT_DATA 同构表 + 一个五步式 fn，共性全在 pre/post 两函数
--   · create_common_pre 在 SetPristine 之前（两端跑，含网络组件与 net_bool 声明）
--   · create_master_pst 在 SetPristine 之后（仅服务端，AddComponent + 状态图）
--   · 碰撞体用 build_boat_collision_mesh 运行时生成三角网格，一套代码服务 5 种半径
--   · ice_crabking_fn 直接调用 ice_fn() 再覆盖，是「变体派生变体」的范式
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：prefabs.lua（Prefab 全局工厂）, prefabutil.lua（MakePlacer）,
--           prefabskins.lua（船与走路板的皮肤命名规则，第 1971-1980 行）,
--           mainfunctions.lua:73（MINIMAP_IMAGE 在专服被跳过加载）,
--           components/walkableplatform.lua, components/hullhealth.lua,
--           components/boatphysics.lua, components/boatring.lua,
--           components/healthsyncer.lua, components/reticule.lua,
--           components/entitytracker.lua, components/repairable.lua,
--           components/deployable.lua, components/fuel.lua,
--           components/boattrail.lua, prefabs/treasurechest.lua（boat_ancient_container）,
--           prefabs/crabking.lua（调用 boat_ice_crabking 与 boat.Physics）
--============================================================
-- ASSETS
-- ============================================================
-- boat.lua —— 船族（DST 里最大的一族预制体，23 个实体）
--
-- 【这个文件演示了什么架构】
-- 1) 资源 / 依赖 / 音效 三层全部按变体切表（8 组 assets、7 组 prefabs、4 组 sounds）
-- 2) ★★ pre / post 两段式装配：create_common_pre（两端跑）→ SetPristine →
--    create_master_pst（仅服务端）。这是 treasurechest.lua 工厂钩子的一般化形式。
-- 3) ★ 数据表驱动变体：每个变体只写一张 XXX_BOAT_DATA 表 + 一个 fn，
--    共性全在 create_common_pre / create_master_pst 两个函数里。
-- 4) 碰撞体用「运行时生成三角网格」而非美术资源（build_boat_collision_mesh）
-- 5) 部署物品（item_fn）与放置预览（MakePlacer）与船本体是三个独立预制体
--
-- 【★ 为什么这个文件值得逐行读】
-- 它把「同一个对象有 5 种形态（木/草/海盗/远古/海獭巢）+ 3 种冰面变体 + 1 个蟹王专用变体」
-- 全部塞进一个 Lua 文件，是观察「DST 如何控制变体爆炸」的最佳窗口。
--
-- 【⚠️ 已核实的一处命名不统一（不是缺陷）】
-- 第 3-6 行 wood_assets 写 Asset("MINIMAP_IMAGE", "boat")，不带扩展名；
-- 而第 763 行 WOOD_BOAT_DATA.minimap_image 写 "boat.png"，带扩展名。
-- 本人核实过：全库两种写法都有（如 prefabs/ancienttrees.lua:419 用了 .png，
-- prefabs/antlion_sinkhole.lua:6 没带）。SetIcon 侧与资源键侧并不共用一套规范，
-- 且 MINIMAP_IMAGE 在 mainfunctions.lua:73 还被 ShouldIgnoreResolve 特殊处理（专服不加载）。
-- ⇒ 【结论】不是写错，而是两套命名空间没有统一约束。移植时照抄任一种都能跑，
-- 但自己的引擎里最好把「图标资源键」与「SetIcon 名」合并成一个字段。
--
-- 【上游来源】Klei Entertainment《Don't Starve Together》游戏脚本
-- ============================================================
local wood_assets =
-- 【★ 资源清单按变体切分】本文件开头的 8 个 assets 表，每个对应一个变体。
-- 与 treasurechest.lua 用「文件级 + JoinArrays」不同，boat 选择「完全分开写」。
-- ⇒ 两种做法各有取舍：分开写读起来直观、合并写省重复。boat 用分开是因为变体差异太大。
{
    Asset("ANIM", "anim/boat_test.zip"),
    Asset("MINIMAP_IMAGE", "boat"),
-- MINIMAP_IMAGE 的值不带扩展名（对比第 763 行 minimap_image 字段带 .png）。
-- ★ 这里的 boat 是「无扩展名的资源键」，不是文件名。两处命名空间不同，不要混淆。
}

local grass_assets =
{
    Asset("ANIM", "anim/boat_grass.zip"),
    Asset("MINIMAP_IMAGE", "boat_grass"),
}

local ice_assets =
-- ★ 注意 ice_assets 里没有 MINIMAP_IMAGE —— 冰面不在小地图上显示。
-- 资源缺失不报错、只是不画，是 DST 的降级方式之一（另一个见第 142 行的 creak = nil）。
{
    Asset("ANIM", "anim/boat_ice.zip"),
}

local pirate_assets =
{
    Asset("ANIM", "anim/boat_pirate.zip"),
    Asset("MINIMAP_IMAGE", "boat_pirate"),
}

local ancient_assets =
-- ancient_assets 声明了 3 个动画包：本体 + yotd（Year of the Dolls 联动皮肤）+ 漏油特效。
-- ★ 一个变体可以打包多套美术资源，运行时由 AnimState:SetBank 切换。
{
    Asset("ANIM", "anim/boat_ancient.zip"),
    Asset("ANIM", "anim/boat_yotd.zip"),
    Asset("ANIM", "anim/boat_leak_ancient_build.zip"),
}

local otterden_assets =
{
    Asset("ANIM", "anim/boat_otterden.zip"),
    Asset("MINIMAP_IMAGE", "boat_otterden"),

    Asset("ANIM", "anim/boat_otterden_tuft.zip"),
}

local item_assets =
-- item_assets 是「背包里的建造物品」，与船本体是不同预制体（第 1642 行 Prefab("boat_item")）。
-- INV_IMAGE 是背包格子的图标资源；boat_item 没有 MINIMAP_IMAGE。
{
    Asset("ANIM", "anim/seafarer_boat.zip"),
    Asset("INV_IMAGE", "boat_item"),
}

local grass_item_assets =
{
    Asset("ANIM", "anim/boat_grass_item.zip"),
    Asset("INV_IMAGE", "boat_grass_item"),
}

local ancient_item_assets =
{
    Asset("ANIM", "anim/boat_ancient_kit.zip"),
}

-- PREFABS
local prefabs =
-- 【★ 依赖清单 prefabs】17 个子预制体。
-- 看这个表就能推断出船在运行时会用到的「零件」：桅杆、舵、转向轮、船唇、漏水、水花特效、
-- 船体碎片 03/04/05、玩家碰撞体、物品碰撞体、两套走路板。
-- ⇒ 【移植启示】依赖表等于一份「运行时零件清单」，比读代码里的 SpawnPrefab 更快摸清结构。
{
    "mast",
    "burnable_locator_medium",
    "steeringwheel",
    "rudder",
-- boatlip = 船唇（船体边缘的视觉装饰）。按材质分木/草/冰/远古/海獭五种（第 537-538 行挂载）。
    "boatlip",
    "boat_water_fx",
    "boat_leak",
-- ★ boat_leak：船体漏水实体。一个「可见的子实体」承担独立 HP 与状态，
-- 泄漏指标由 hullhealth 组件维护（第 198 行插进 leak_indicators_dynamic）。
-- ⇒ 【可移植模式】把「可被破坏的局部」做成独立预制体 + 独立组件，
-- 而不是把所有状态塞进主实体。
    "fx_boat_crackle",
    "boatfragment03",
    "boatfragment04",
    "boatfragment05",
    "fx_boat_pop",
    "boat_player_collision",
    "boat_item_collision",
    "boat_grass_player_collision",
    "boat_grass_item_collision",
    "walkingplank",
    "walkingplank_grass",
}

local grass_prefabs =
-- grass_prefabs：草船专属依赖。与 wood 的 prefabs（第 58 行）无交集，
-- ★ 说明变体之间的依赖是完全独立的，不是「木船依赖 + 草船增量」。
{
    "degrade_fx_grass",
    "boatlip_grass",
    "boat_grass_erode",
    "boat_grass_erode_water",
    "fx_grass_boat_fluff",
}

local ice_prefabs =
{
    "boat_ice_deploy_blocker",
    "boatlip_ice",
    "degrade_fx_ice",
}

local ancient_prefabs =
{
    "boatlip_ancient",
    "walkingplank_ancient",
    "boat_ancient_container",
}

local otterden_prefabs =
{
    "boatlip_otterden",
    "boat_otterden_erode",
    "boat_otterden_erode_water",
    "fx_grass_boat_fluff",
    "otterden",
    "boat_otterden_player_collision",
    "boat_otterden_item_collision",
}

local item_prefabs =
{
    "boat",
}

local grass_item_prefabs =
{
    "boat_grass",
}

local ancient_item_prefabs =
{
    "boat_ancient",
}

--
local sounds ={
-- 【★ 音效表按变体整表替换】inst.sounds = sounds（第 782 行）等 5 处赋值。
-- 全文所有 PlaySoundWithParams(inst.sounds.xxx) 都通过 inst.sounds 取路径。
-- ⇒ 换一套音效只要换一张表；这是 treasurechest.lua 第 18 行的同一范式。
    place = "turnoftides/common/together/boat/place",
    creak = "turnoftides/common/together/boat/creak",
    damage = "turnoftides/common/together/boat/damage",
    sink = "turnoftides/common/together/boat/sink",
    hit = "turnoftides/common/together/boat/hit",
    thunk = "turnoftides/common/together/boat/thunk",
    movement = "turnoftides/common/together/boat/movement",
}

local sounds_grass ={
    place = "monkeyisland/grass_boat/place",
    creak = nil, --"monkeyisland/grass_boat/creak",
-- ★★ creak = nil：这是一个「显式声明为没有」的字段。
-- 若写成 "monkeyisland/grass_boat/creak"，运行时找不到该音轨只会静默；
-- 写成 nil 并把真实字符串注释在旁边，是「明示缺失」而非「疑似 bug」。
-- ⇒ 【可移植约定】表驱动配置里，把「故意留空」的项显式写 nil 并注明原因，
-- 比留空字符串或留注释掉的字符串更利于后续维护。
    damage = "monkeyisland/grass_boat/damage",
    sink = "monkeyisland/grass_boat/sink",
    hit = "monkeyisland/grass_boat/hit",
    thunk = "monkeyisland/grass_boat/thunk",
    movement = "monkeyisland/grass_boat/movement",
}

local sounds_ice =
{
    place = "dontstarve_DLC001/common/iceboulder_hit",
    creak = "dontstarve_DLC001/common/iceboulder_hit",
    damage = "dontstarve_DLC001/common/iceboulder_hit",
    sink = "dontstarve_DLC001/common/iceboulder_hit",
    hit = "dontstarve_DLC001/common/iceboulder_hit",
    thunk = "dontstarve_DLC001/common/iceboulder_hit",
    movement = "dontstarve_DLC001/common/iceboulder_hit",
}

local BOAT_COLLISION_SEGMENT_COUNT = 20
-- ★ BOAT_COLLISION_SEGMENT_COUNT = 20：碰撞多边形每圈的段数。
-- 第 489、605 行都用了这个值，但一处乘 2（第 489 行采样双倍密度）。
-- 【移植提示】段数是性能与精度的权衡：段数越多碰撞越贴合、越费 CPU。20 段对半径约 3 的船够用。

local BOATBUMPER_MUST_TAGS = { "boatbumper" }
-- MUST_TAGS：TheSim:FindEntities 的标签过滤（见第 175 行）。
-- ★ 与 COMPONENTS.ANYTAGS 这类常量表一样，「标签即接口」是 DST 全局风格。

local function OnLoadPostPass(inst)
-- 【★ OnLoadPostPass：读档的「后处理」阶段，存档里 GUID → 实体的还原发生在这里】
-- 时序：OnSave → OnLoad → OnLoadPostPass
-- OnLoadPostPass 的 newents 参数是一张「存档记录的文件名 → 实体」的映射表，
-- ★ 只有这个阶段才能安全地把 GUID 换回实体引用。
-- 对比 pighouse.lua：它没有子实体，所以只需 OnLoad，treasurechest 也没用到后处理。
    local boatring = inst.components.boatring
    if not boatring then
        return
    end

    -- If cannons and bumpers are on a boat, we need to rotate them to account for the boat's rotation
    local x, y, z = inst.Transform:GetWorldPosition()

    -- Bumpers
    local bumpers = TheSim:FindEntities(x, y, z, boatring:GetRadius(), BOATBUMPER_MUST_TAGS)
-- FindEntities(x, y, z, radius, MUST_TAGS)：★ 只传 MUST_TAGS 不传 CANT_TAGS，
-- 意味着「半径内所有带 boatbumper 标签的实体」，不排除任何东西。
    for _, bumper in ipairs(bumpers) do
        -- Add to boat bumper list for future reference
        table.insert(boatring.boatbumpers, bumper)

        local bumperpos = bumper:GetPosition()
        local angle = GetAngleFromBoat(inst, bumperpos.x, bumperpos.z) / DEGREES

        -- Need to further rotate the bumpers to account for the boat's rotation
        bumper.Transform:SetRotation(-angle + 90)
-- +90 是美术约定：碰撞网格的基准朝向为 +Y 轴，而实体旋转基准是别的方向。
-- ⚠️ 这类「魔法角度补偿」是资产与代码的隐式契约，改美术朝向时必须同步改这里。
    end
end

local function OnSpawnNewBoatLeak(inst, data)
-- 【★ 事件驱动的动态子实体创建】OnSpawnNewBoatLeak 由 hullhealth 组件在产生新漏水时 PushEvent。
-- 预制体监听自己的事件、生成子实体、注册回调 —— 这是 DST 里「动态装配」的通用套路，
-- 对比静态装配（本文件 create_master_pst 里的固定子实体）。
	if data ~= nil and data.pt ~= nil then
        data.pt.y = 0
-- data.pt.y = 0：强制把漏水源压到海平面。★ 船会随浪起伏，但漏洞位置必须在固定高度，
-- 否则漏水点会跟着船上下浮动，视觉与判定都会错位。

		local leak = SpawnPrefab("boat_leak")
		leak.Transform:SetPosition(data.pt:Get())
		leak.components.boatleak.isdynamic = true
		leak.components.boatleak:SetBoat(inst)
		leak.components.boatleak:SetState(data.leak_size)

		table.insert(inst.components.hullhealth.leak_indicators_dynamic, leak)
-- ★ 直接往 hullhealth 的内部数组 leak_indicators_dynamic 里插元素 ——
-- 绕过 hullhealth 的公开 API。属于「自己组件的私有字段随便改，同事组件的尽量用方法」。
-- 【移植提示】组件内改自己的私有数组是安全的；改别人组件的私有数组要在组件间先约定。

		if inst.components.walkableplatform ~= nil then
-- ★★★ 关键：把漏水源也加进 walkableplatform。
-- ⇒ 玩家站在漏水点上时，第 202 行遍历所有在船上的玩家，推送 on_standing_on_new_leak 事件。
-- 这说明 walkableplatform 维护的不只是「站在上面的东西」，而是「随船移动的实体全集」。
-- ⇒ 【可移植模式】需要把一个实体加入另一个实体的「影响范围」时，
-- 找到那个组件的成员列表并显式注册，比轮询查找更可靠。
			inst.components.walkableplatform:AddEntityToPlatform(leak)
			for player_on_platform in pairs(inst.components.walkableplatform:GetPlayersOnPlatform()) do
				if player_on_platform:IsValid() then
					player_on_platform:PushEvent("on_standing_on_new_leak")
				end
			end
		end

		if data.playsoundfx then
			inst.SoundEmitter:PlaySoundWithParams(inst.sounds.damage, { intensity = 0.8 })
		end
	end
end

local function OnSpawnNewBoatLeak_Grass(inst, data)
-- OnSpawnNewBoatLeak_Grass：★ 草船的漏水处理完全不同 —— 不生成漏水实体，改为直接扣血。
-- ⇒ 草船 leakproof = true（第 845 行），漏了就掉血，不生成可交互的漏洞。
-- 「同一个事件、同一组参数、变体各自解释」：这是钩子机制在事件层面的体现。
	if data ~= nil and data.pt ~= nil then
		local leak_x, _, leak_z = data.pt:Get()

        if inst.material == "grass" then
            SpawnPrefab("fx_grass_boat_fluff").Transform:SetPosition(leak_x, 0, leak_z)
			SpawnPrefab("splash_green_small").Transform:SetPosition(leak_x, 0, leak_z)
        end

		local damage = TUNING.BOAT.GRASSBOAT_LEAK_DAMAGE[data.leak_size]
-- TUNING.BOAT.GRASSBOAT_LEAK_DAMAGE[leak_size] 用漏口大小做表索引，
-- 第 225 行的 ~= nil 判空说明并非所有 leak_size 都有对应伤害值。
		if damage ~= nil then
	        inst.components.health:DoDelta(-damage)
		end

		if data.playsoundfx then
			inst.SoundEmitter:PlaySoundWithParams(inst.sounds.damage, { intensity = 0.8 })
		end
	end
end

local function RemoveConstrainedPhysicsObj(physics_obj)
-- 【★★ ConstrainTo：物理约束的正解示范】
-- RemoveConstrainedPhysicsObj 做了两件事：先 ConstrainTo(nil) 解绑，再 Remove。
-- ⚠️ 顺序不可颠倒：先 Remove 再解绑，物理世界会因「被约束对象已消失」而崩溃。
-- 这正是第 336-338 行注释所说的 crash 现象的根因。
-- ⇒ 【移植要点】任何「一对多物理跟随」的实现都必须成对管理：
--   绑定时 ConstrainTo，被销毁时先解绑再删。这个 bug 在自研引擎里极易复现。
    if physics_obj:IsValid() then
        physics_obj.Physics:ConstrainTo(nil)
        physics_obj:Remove()
    end
end

local function constrain_object_to_boat(physics_obj, boat)
-- constrain_object_to_boat 在 DoTaskInTime(0) 里调用（第 251 行）。
-- ★ 为什么要延迟一帧：SpawnPrefab 返回的瞬间，新实体的 Transform 可能还没同步到世界坐标。
-- 直接读 GetWorldPosition 会拿到 (0,0,0)。这又是一个「DoTaskInTime(0) 二次初始化」的实例。
    if boat:IsValid() then
        physics_obj.Transform:SetPosition(boat.Transform:GetWorldPosition())
        physics_obj.Physics:ConstrainTo(boat.entity)
    end
end
local function AddConstrainedPhysicsObj(boat, physics_obj)
-- AddConstrainedPhysicsObj：★ 先注册 onremove 回调做自动清理，再延迟绑定。
-- 自动清理的意义：船被拆掉时，挂在上面的碰撞体不需要外部逐个通知，自己会解绑消失。
-- ⇒ 【可移植模式】把「解除关系」挂在被约束方自己的 onremove 上，而不是调用方负责，
-- 可以彻底避免「A 忘了通知 B」这类泄漏。
	physics_obj:ListenForEvent("onremove", function() RemoveConstrainedPhysicsObj(physics_obj) end, boat)

    physics_obj:DoTaskInTime(0, constrain_object_to_boat, boat)
end

local function on_start_steering(inst)
-- ★ 双重条件：ThePlayer 存在 且 playercontroller.isclientcontrollerattached。
-- 后者表示「有手柄输入设备接在客户端」，前者只是「本地有玩家」。
-- 手柄专属的 UI 逻辑必须查这个标志，不能只看 ThePlayer —— 服务器上 ThePlayer 为 nil，
-- 而专服虽然没有 ThePlayer 也不该崩。
    if ThePlayer and ThePlayer.components.playercontroller ~= nil and ThePlayer.components.playercontroller.isclientcontrollerattached then
        inst.components.reticule:CreateReticule()
    end
end

local function on_stop_steering(inst)
    if ThePlayer and ThePlayer.components.playercontroller ~= nil and ThePlayer.components.playercontroller.isclientcontrollerattached then
        inst.lastreticuleangle = nil
        inst.components.reticule:DestroyReticule()
    end
end

local function ReticuleTargetFn(inst)
-- ReticuleTargetFn：★ 手柄瞄准光标的落点计算。三段结构值得抄：
--   1) 读摇杆 → 死区判定（第 275-283 行）：死区内保持上次方向，全死区返回 nil 隐藏
--   2) 相机朝向 → 旋转摇杆向量（第 285-290 行）：因为摇杆是「屏幕空间」的
--   3) 沿方向反推落点（第 292-296 行）：range = 7 是固定投射距离
-- ⇒ 【易踩的坑】第 289-290 行的旋转矩阵：newx = x*cos - z*sin、newz = x*sin + z*cos，
-- 手算验证：对 (1,0) 代入得 (cos, sin)，即 x 轴转到 theta —— 是标准逆时针旋转，方向没错。
-- 但 newz 的符号与 newx 的 z 项一致，若以后改成 -z*sin 就成了顺时针，瞄准会左右反。
    local dir = Vector3(
        TheInput:GetAnalogControlValue(CONTROL_MOVE_RIGHT) - TheInput:GetAnalogControlValue(CONTROL_MOVE_LEFT),
        0,
        TheInput:GetAnalogControlValue(CONTROL_MOVE_UP) - TheInput:GetAnalogControlValue(CONTROL_MOVE_DOWN)
    )
	local deadzone = TUNING.CONTROLLER_DEADZONE_RADIUS

    if math.abs(dir.x) >= deadzone or math.abs(dir.z) >= deadzone then
-- ★ 死区用「或」：任一轴超出死区就算有效输入，然后整体归一化。
-- 若用「且」，手柄斜推时两个轴都在死区内会被判为无输入 —— 这是常见 bug。
        dir = dir:GetNormalized()

        inst.lastreticuleangle = dir
    elseif inst.lastreticuleangle ~= nil then
        dir = inst.lastreticuleangle
    else
        return nil
    end

    local Camangle = TheCamera:GetHeading()/180
-- GetHeading()/180 再乘 -PI*(0.5 - angle)：把「0~360 度的相机朝向」转成「弧度角」。
-- ★ 这里的 0.5 偏移与负号是为对齐 DST 相机坐标约定，改动相机系统时必须同步。
    local theta = -PI *(0.5 - Camangle)
    local sintheta, costheta = math.sin(theta), math.cos(theta)

    local newx = dir.x*costheta - dir.z*sintheta
    local newz = dir.x*sintheta + dir.z*costheta

    local range = 7
    local pos = inst:GetPosition()
    pos.x = pos.x - (newx * range)
    pos.z = pos.z - (newz * range)

    return pos
end

local function EnableBoatItemCollision(inst)
-- EnableBoatItemCollision：★ 惰性创建 —— 只在需要时才 SpawnPrefab 碰撞体。
-- 因为船睡着时不需要物品碰撞（第 330 行 OnPhysicsSleep 会关掉它）。
-- ⇒ 【性能范式】「不可见但必要」的辅助实体应当惰性创建 + 用完即销毁，而不是常驻。
    if not inst.boat_item_collision then
        inst.boat_item_collision = SpawnPrefab(inst.item_collision_prefab)
        AddConstrainedPhysicsObj(inst, inst.boat_item_collision)
    end
end

local function DisableBoatItemCollision(inst)
    if inst.boat_item_collision then
        RemoveConstrainedPhysicsObj(inst.boat_item_collision) --also :Remove()s object
        inst.boat_item_collision = nil
    end
end

local function OnPhysicsWake(inst)
-- OnPhysicsWake：★ 注意第 316-319 行用 stopupdatingtask 是否存在来区分「首次唤醒」与「重复唤醒」。
-- 首次唤醒立即 StartUpdating；后续唤醒先取消掉 1 秒延迟的停止任务再 StartUpdating。
-- ⇒ 这是「防抖」的 Lua 实现：用一个待取消的任务句柄代替计时器状态。
    EnableBoatItemCollision(inst)
    if inst.stopupdatingtask then
        inst.stopupdatingtask:Cancel()
        inst.stopupdatingtask = nil
    else
        inst.components.walkableplatform:StartUpdating()
    end
    inst.components.boatphysics:StartUpdating()
end

local function physicssleep_stopupdating(inst)
-- physicssleep_stopupdating：★ 为什么延迟 1 秒才停？
-- 推断：船进入休眠边缘时物理状态可能反复抖动，延迟 1 秒给出稳定期。
-- 源码未写明原因，此为依据代码结构所作的推断，标为【未核实】。
    inst.components.walkableplatform:StopUpdating()
    inst.stopupdatingtask = nil
end
local function OnPhysicsSleep(inst)
    DisableBoatItemCollision(inst)
    inst.stopupdatingtask = inst:DoTaskInTime(1, physicssleep_stopupdating)
    inst.components.boatphysics:StopUpdating()
end

local function StopBoatPhysics(inst)
-- ★★ StopBoatPhysics：注释明说 constraints 会导致崩溃，所以设 SetDontRemoveOnSleep(false)。
-- 结合第 235 行的分析：约束关系存活时，实体不能被物理世界移除。
-- ⇒ ★ 这条注释是全文件最有价值的信息之一：它解释了「为什么这里要反直觉地关掉优化」。
    --Boats currently need to not go to sleep because
    --constraints will cause a crash if either the target object or the source object is removed from the physics world
    inst.Physics:SetDontRemoveOnSleep(false)
end

local function StartBoatPhysics(inst)
    inst.Physics:SetDontRemoveOnSleep(true)
end

local function SpawnFragment(lp, prefix, offset_x, offset_y, offset_z, ignite)
-- SpawnFragment：沉船碎片的统一生成器。★ offset_y > 0 时给一个初速向下的「自然落体」手感。
-- ⚠️ 注意条件写的是 offset_y > 0（第 349 行），但施加的速度是 -0.25（向下）。
-- 推断：调用方传的 offset_y 为正表示「从上方生成」，配一个向下的初速加速下落。
-- 本人核实过：第 792 行等所有调用点 offset_y 都传 0，该分支实际不会走到 ——
-- ⇒ 【结论】这是一个未被触发的分支，疑似历史遗留（早期版本曾从更高处掉碎片）。
-- 保留它无成本，删除它无收益，故不视为缺陷，仅标注为死代码。
    local fragment = SpawnPrefab(prefix)
    fragment.Transform:SetPosition(lp.x + offset_x, lp.y + offset_y, lp.z + offset_z)

    if offset_y > 0 and fragment.Physics then
        fragment.Physics:SetVel(0, -0.25, 0)
    end

    if ignite and fragment.components.burnable then
        fragment.components.burnable:Ignite()
    end

    return fragment
end

local function OnEntityReplicated(inst)
-- 【★ OnEntityReplicated：客户端「收到实体」这一刻的钩子】
-- ★★ 关键约束（原注释第 362 行明写）：这个设置只能在 replicated 之后应用，
-- 所以它不能写在 fn() 的 A 段里，必须挂到 inst.OnEntityReplicated 上。
-- ⇒ 【移植要点】凡是「只在客户端、且需要实体已存在」的操作，DST 提供了专门的钩子位置。
-- 自己写引擎时若没有这个钩子，就会出现「客户端拿到实体瞬间状态不对」的时序 bug。
    --Use this setting because we can rotate, and we are not billboarded with discreet anim facings
    --NOTE: this setting can only be applied after entity replicated
    inst.Transform:SetInterpolateRotation(true)
end

local function create_common_pre(inst, bank, build, data)
-- ============================================================
-- ★★★ create_common_pre —— 所有船变体共用的「A 段」装配（两端都跑）。
--
-- 【data 表驱动】bank/build 走参数，其余全靠 data 表：
--   radius / max_health / minimap_image / scale / stategraph / fireproof
-- 第 369 行的 `data.radius or TUNING.BOAT.RADIUS` 提供默认值 → 各变体只需写差异项。
--
-- 【★ 装配顺序（本函数内）】
--   1. entity:AddTransform / AnimState / SoundEmitter（第 371-373 行）
--   2. 条件性 AddMiniMapEntity（第 374-378 行）—— ★ 有 minimap_image 才挂组件
--   3. entity:AddNetwork（第 379 行）—— ★ 必须在这之后
--   4. AddTag ×4（第 381-384 行）
--   5. entity:AddPhysics + 一组 Set（第 386-395 行）
--   6. AnimState 设置 + sortOrder / finalOffset / orientation / layer（第 397-402 行）
--   7. scrapbook_ 元数据（第 404-405 行）
--   8. AddComponent 系列（第 412-452 行）—— ★ 注意这一段在 AddNetwork 之后、SetPristine 之前
--
-- 【⚠️ 第 8 步是个值得注意的例外】
-- 这里的 AddComponent（walkableplatform / healthsyncer / waterphysics / reticule /
-- boatringdata）出现在 AddNetwork 之后，说明它们走的是「网络组件」路径
-- （会生成对应的 replica），与 C 段的纯 Lua 组件不同。
-- ⇒ 【判据】需要客户端知道其状态 → 必须在 SetPristine 前挂；纯服务端逻辑 → 放 C 段。
-- ============================================================
    data = data or {}
-- data = data or {}：容错写法，让调用方可以不传。★ 所有 *_BOAT_DATA 表都传了，属冗余但无害。

    local radius = data.radius or TUNING.BOAT.RADIUS

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    if data.minimap_image then
        inst.entity:AddMiniMapEntity()
-- ★ 条件挂载 MiniMapEntity：这是「资源清单缺失即降级」的具体实现（见第 14 行 ice_assets）。
-- ⇒ 【可移植模式】与其在运行时报错，不如「没有这个需求就不挂这个组件」。
        inst.MiniMapEntity:SetIcon(data.minimap_image)
        inst.MiniMapEntity:SetPriority(-1)
-- SetPriority(-1)：小地图图层优先级。负值 = 画在下面（被地形遮挡）。
-- ★ 船是浮在水面的，为什么要在下面？推断为避免小地图上盖住玩家图标。
-- 源码未说明，此为推断。
    end
    inst.entity:AddNetwork()

    inst:AddTag("ignorewalkableplatforms")
	inst:AddTag("antlion_sinkhole_blocker")
	inst:AddTag("boat")
    inst:AddTag("wood")

    local phys = inst.entity:AddPhysics()
-- ★ AddPhysics 只在这里出现一次（pre 段）。物理参数是所有变体共性的最纯粹体现：
--   MASS 质量 / FRICTION 摩擦 0（船靠摇橹不靠摩擦）/ DAMPING 阻尼 5（模拟水的阻力）
--   COLLISION.OBSTACLES 碰撞组 / WORLD+OBSTACLES 掩码
--   SetCylinder(radius, 3) 圆柱碰撞体，高 3
-- ⇒ 【移植要点】船类移动平台的物理配方：零摩擦 + 高阻尼 + 圆柱体。
    phys:SetMass(TUNING.BOAT.MASS)
    phys:SetFriction(0)
-- Friction(0) + Damping(5)：★ 这两个值合起来就是「在水面滑行」的物理表现。
-- 摩擦 0 表示不会自己停，阻尼 5 表示速度按指数衰减。移植时照抄这两个数即可。
    phys:SetDamping(5)
    phys:SetCollisionGroup(COLLISION.OBSTACLES)
	phys:SetCollisionMask(
		COLLISION.WORLD,
		COLLISION.OBSTACLES
	)
    phys:SetCylinder(radius, 3)
-- SetCylinder(radius, 3)：高度 3 让船有「体积感」，玩家会被正确挡住而不是从旁边穿过去。

    inst.AnimState:SetBank(bank)
    inst.AnimState:SetBuild(build)
    inst.AnimState:SetSortOrder(ANIM_SORT_ORDER.OCEAN_BOAT)
-- ★★ SetSortOrder / SetFinalOffset / SetOrientation / SetLayer 四连，
-- 是 DST 2.5D 渲染的「深度 + 朝向」控制组。
-- 对比 pighouse.lua 第 349 行：那里只用 FinalOffset 做两层的相对排序。
-- ⇒ 【移植要点】这四个调用是 DST 伪 3D 的核心，没有它们所有东西会画在同一平面。
	inst.AnimState:SetFinalOffset(1)
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)

    inst.scrapbook_anim = "idle_full"
-- scrapbook_* 又是图鉴元数据（同 treasurechest.lua 第 130 行）。扫源码时可忽略。
    inst.scrapbook_inspectonseen = true

    if data.scale then
        inst.AnimState:SetScale(data.scale, data.scale, data.scale)
    end

    --
    local walkableplatform = inst:AddComponent("walkableplatform")
-- 【★ walkableplatform：船的「移动平台」能力】
-- 这是全文件最核心的组件：它让船上的东西（玩家、物品、漏水口）随船一起移动。
-- ★ platform_radius 设为与物理半径相同（第 413 行），保证「站在甲板上」与「被船撞到」范围一致。
-- ⇒ 【可移植模式】移动平台组件必须同时管理三件事：
--   ① 谁在平台上（实体列表）② 玩家碰撞体（第 770 行单独指定 prefab）
--   ③ 外部实体如何知道自己「上了平台」（第 200 行的显式注册）
    walkableplatform.platform_radius = radius

    --
    local healthsyncer = inst:AddComponent("healthsyncer")
-- healthsyncer：把血量同步给客户端显示血条。max_health 从 data 取，缺省用 TUNING。
-- ★ 与 C 段的 health 组件（第 582 行）配对：health 管逻辑、healthsyncer 管同步。
-- ⇒ 【DST 组件命名通则】xxxsyncer = 「把 xxx 的状态同步到客户端」。移植时照此命名。
    healthsyncer.max_health = data.max_health or TUNING.BOAT.HEALTH

    --
    local waterphysics = inst:AddComponent("waterphysics")
    waterphysics.restitution = 0.75

    --
    local reticule = inst:AddComponent("reticule")
-- reticule：手柄瞄准组件（配合第 267 行的 ReticuleTargetFn）。
-- ispassableatallpoints = true：光标不需要额外做通行性检查（船可停任何水面点）。
    reticule.targetfn = ReticuleTargetFn
    reticule.ispassableatallpoints = true

    --
    inst.on_start_steering = on_start_steering
    inst.on_stop_steering = on_stop_steering

    --
    inst.doplatformcamerazoom = net_bool(inst.GUID, "doplatformcamerazoom", "doplatformcamerazoomdirty")
-- ★★★ net_bool：★ 本文件里唯一的网络变量声明，也是「客户端如何知道这个实体是什么」的样本。
-- 三个参数：实体 GUID、网络变量名、同步用的脏标记名。
-- 用法：inst.doplatformcamerazoom = true 之后，客户端会收到并执行「平台相机变焦」。
-- ⇒ ★ 对比 pighouse.lua：它整份文件没有一处 net_ 声明，
-- 因为猪屋不需要客户端做任何决策。
-- ⇒ 【移植要点】网络变量的正确用法是：改这个字段而不是普通字段，改完自动同步。
-- 直接写普通字段只改服务端本地，客户端看不到 —— 这是分布式游戏最常见的 bug 来源。

	if not TheNet:IsDedicated() then
-- ★ not TheNet:IsDedicated()：又一个「有画面才生成」的判断（同 pighouse.lua 第 391 行）。
-- 这里的 boattrail 是纯视觉的尾迹组件。
        inst:ListenForEvent("endsteeringreticule", function(inst2, event_data)
            if ThePlayer and ThePlayer == event_data.player then
                inst2:on_stop_steering()
            end
        end)
        inst:ListenForEvent("starsteeringreticule", function(inst2, event_data)
            if ThePlayer and ThePlayer == event_data.player then
                inst2:on_start_steering()
            end
        end)

        inst:AddComponent("boattrail")
-- ★ boattrail 组件在客户端生成，服务端不需要 → 不参与物理与玩法，纯装饰。
-- 第 1329-1336 行还按冰面半径缩放了尾迹，说明组件参数也支持变体化。
	end

    local boatringdata = inst:AddComponent("boatringdata")
-- boatringdata：把船的半径与分段数存成「数据」，供其它系统查询。
-- SetNumSegments(8)：★ 碰撞用 20 段（第 161 行），船体环用 8 段 ——
-- 两者精度需求不同（船体要贴合凸起，环只要大致形状），不必共用常量。
-- ⇒ 【移植提示】「同一个形状的两套精度」是常见优化，别盲目统一。
    boatringdata:SetRadius(radius)
    boatringdata:SetNumSegments(8)

    if not TheWorld.ismastersim then
        inst.OnEntityReplicated = OnEntityReplicated
    end

    return inst
end

local function empty_loot_function() end

local function InstantlyBreakBoat(inst)
    -- This is not for SGboat but is for safety on physics.
    if inst.components.boatphysics then
        inst.components.boatphysics:SetHalting(true)
    end
    --Keep this in sync with SGboat.
    for entity_on_platform in pairs(inst.components.walkableplatform:GetEntitiesOnPlatform()) do
        entity_on_platform:PushEvent("abandon_ship")
    end
    for player_on_platform in pairs(inst.components.walkableplatform:GetPlayersOnPlatform()) do
        player_on_platform:PushEvent("onpresink")
    end
    inst:sinkloot()
    if inst.postsinkfn then
        inst:postsinkfn()
    end
    inst:Remove()
end

local function GetSafePhysicsRadius(inst)
    return (inst.components.hull ~= nil and inst.components.hull:GetRadius() or TUNING.BOAT.RADIUS) + 0.18 -- Add a small offset for item overhangs.
end

local function IsBoatEdgeOverLand(inst, override_position_pt)
    local map = TheWorld.Map
    local radius = inst:GetSafePhysicsRadius()
    local segment_count = BOAT_COLLISION_SEGMENT_COUNT * 2
    local segment_span = TWOPI / segment_count
    local x, y, z
    if override_position_pt then
        x, y, z = override_position_pt:Get()
    else
        x, y, z = inst.Transform:GetWorldPosition()
    end
    for segement_idx = 0, segment_count do
        local angle = segement_idx * segment_span

        local angle0 = angle - segment_span / 2
        local x0 = math.cos(angle0) * radius
        local z0 = math.sin(angle0) * radius
        if not map:IsOceanTileAtPoint(x + x0, 0, z + z0) or map:IsVisualGroundAtPoint(x + x0, 0, z + z0) then
            return true
        end

        local angle1 = angle + segment_span / 2
        local x1 = math.cos(angle1) * radius
        local z1 = math.sin(angle1) * radius
        if not map:IsOceanTileAtPoint(x + x1, 0, z + z1) or map:IsVisualGroundAtPoint(x + x1, 0, z + z1) then
            return true
        end
    end

    return false
end

local PLANK_EDGE_OFFSET = -0.05
-- PLANK_EDGE_OFFSET = -0.05：走路板略微内缩，避免和船唇重叠闪烁。
-- ★ 视觉微调常量。数值无公式，靠反复调参 —— 预制体文件里这类硬编码小数值属正常。
local function create_master_pst(inst, data)
-- ============================================================
-- ★★★ create_master_pst —— 所有船变体共用的「C 段」装配（仅服务端）。
--
-- 【与 pre 段的分工】pre 管「看得见的 + 客户端需要知道的」，pst 管「逻辑与状态」。
-- 各变体的 fn 只需：create_common_pre → 少量变体专属表现 → SetPristine → 客户端返回
-- → create_master_pst → 变体专属逻辑。
--
-- 【★ 本函数内的静态子实体装配（与第 188 行的动态装配对照）】
--   第 538 行 boatlip   —— 船唇，固定挂载
--   第 542-544 行 plank —— 走路板，固定挂载并塞进 hull
--   第 550-568 行 burnable_locator ×5 —— ★ 火焰蔓延的「感应点」
-- 这些实体在船生成时就存在，之后不再变；而漏水（第 188 行）是运行时动态生成的。
-- ⇒ 【可移植模式】区分「构成实体」与「事件实体」：前者写在工厂里，后者挂在事件上。
-- ============================================================
    data = data or {}

    inst.leak_build = data.leak_build
    inst.leak_build_override = data.leak_build_override

    local radius = data.radius or TUNING.BOAT.RADIUS

    inst.Physics:SetDontRemoveOnSleep(true)
    inst.item_collision_prefab = data.item_collision_prefab
    EnableBoatItemCollision(inst)

    inst.entity:AddPhysicsWaker() --server only component
-- ★★ AddPhysicsWaker：服务端专属实体组件。
-- SetTimeBetweenWakeTests(TUNING.BOAT.WAKE_TEST_TIME)：周期性唤醒物理，
-- 因为船要随波起伏，不能真睡着（第 335 行的注释是同一件事的两面）。
-- 原注释明写 server only component —— 它必须放在 C 段。
    inst.PhysicsWaker:SetTimeBetweenWakeTests(TUNING.BOAT.WAKE_TEST_TIME)

    local hull = inst:AddComponent("hull")
-- hull 组件：船体几何（半径、船唇、走路板、附着实体）。
-- ★ 所有「船身上挂的实体」都由 hull:AttachEntityToBoat 统一管理（第 543、552 行），
-- 这样它们会随船的旋转与位移一起动，不需要各自写跟随逻辑。
    hull:SetRadius(radius)

    if data.boatlip_prefab then
        hull:SetBoatLip(SpawnPrefab(data.boatlip_prefab), data.scale or 1.0)
    end

    if data.plank_prefab then
        local walking_plank = SpawnPrefab(data.plank_prefab)
        hull:AttachEntityToBoat(walking_plank, 0, radius + PLANK_EDGE_OFFSET, true)
        hull:SetPlank(walking_plank)
    end

    if not data.fireproof then
-- ★ fireproof 分支：ice_fn 传了 fireproof = true（第 1317 行），
-- 所以冰面船跳过整个燃烧感应点装配 —— 冰当然不会烧。
-- ⇒ 一个布尔关掉 20 行代码，是 data 表驱动最直观的收益。
        inst.activefires = 0
-- activefires：★ 普通 Lua 字段，记录当前有几个着火点。
-- 船烧毁时用它决定碎片要不要点着（第 785 行）。既然是服务端逻辑，不需要 net_。

        local burnable_locator = SpawnPrefab("burnable_locator_medium")
-- ★★ 5 个 burnable_locator 按十字形布在船体上（0,0 / ±2.5,0 / 0,±2.5）。
-- 它们不带 burnable 组件，只是「火焰蔓延的感应器」—— 火从这里传到船，而不是从船中心烧。
-- ⇒ 【可移植模式】大型可燃物的火源应该沿表面多点分布，单点会导致「要么秒烧要么烧不着」。
-- 第 551 行 `burnable_locator.boat = inst` 是反向引用，让 locator 能回调船。
        burnable_locator.boat = inst
        hull:AttachEntityToBoat(burnable_locator, 0, 0, true)

        burnable_locator = SpawnPrefab("burnable_locator_medium")
        burnable_locator.boat = inst
        hull:AttachEntityToBoat(burnable_locator, 2.5, 0, true)

        burnable_locator = SpawnPrefab("burnable_locator_medium")
        burnable_locator.boat = inst
        hull:AttachEntityToBoat(burnable_locator, -2.5, 0, true)

        burnable_locator = SpawnPrefab("burnable_locator_medium")
        burnable_locator.boat = inst
        hull:AttachEntityToBoat(burnable_locator, 0, 2.5, true)

        burnable_locator = SpawnPrefab("burnable_locator_medium")
        burnable_locator.boat = inst
        hull:AttachEntityToBoat(burnable_locator, 0, -2.5, true)
    end

    --
    local repairable = inst:AddComponent("repairable")
-- repairable：可修理组件。repairmaterial 决定修理需要什么材料。
-- ★ 各变体覆盖这个字段：草船改 HAY（第 847 行）、海獭巢改 KELP（第 1217 行）、
-- 冰面直接置 nil（第 1358 行，即不可修）。⇒ 变体覆写 pre/post 共用字段的典型。
    repairable.repairmaterial = MATERIALS.WOOD

    --
    inst:AddComponent("boatring")
-- ★★ 一次加 5 个组件：boatring / hullhealth / boatphysics / boatdrifter / savedrotation。
-- 每个都是独立能力：船体环（范围查询）、船体耐久（漏与自损）、船物理（摇橹）、
-- 漂流（无人时随波）、旋转记忆（存档用）。
-- ⇒ 【移植要点】这就是「组合优于继承」：船的行为 = 这 5 个组件 + health + 状态机，
-- 没有一个 "Boat" 类。想给船加新能力，加一个组件即可，不影响其它船。
    inst:AddComponent("hullhealth")
    inst:AddComponent("boatphysics")
    inst:AddComponent("boatdrifter")
    inst:AddComponent("savedrotation")

    local health = inst:AddComponent("health")
-- health 组件（与 pre 段的 healthsyncer 第 416 行配对）。
-- ★ nofadeout = true：血量归零时不淡出消失 —— 船沉没走的是状态机的 sink 状态（第 595 行）。
-- ⇒ 「死亡表现」由状态机负责而非 health 组件，是 DST 生物/载具的通例。
    health:SetMaxHealth(data.max_health or TUNING.BOAT.HEALTH)
    health.nofadeout = true

    inst:SetStateGraph(data.stategraph or "SGboat")
-- SetStateGraph(data.stategraph or "SGboat")：★ 状态图名也可由 data 指定（冰面用 SGboat_ice）。
-- 状态图决定船的所有行为（漂浮 / 摇橹 / 沉没 / 放置），是船的「行为大脑」。
-- ⇒ 【预制体与状态图的分工】预制体负责装配组件，状态图负责组件之间的时序协作。
-- 一个状态图可被多个预制体复用，这就是 SGboat 被 4 个船变体共享的原因。

    inst.StopBoatPhysics = StopBoatPhysics
    inst.StartBoatPhysics = StartBoatPhysics

    inst.OnPhysicsWake = OnPhysicsWake
    inst.OnPhysicsSleep = OnPhysicsSleep

    inst.sinkloot = empty_loot_function
-- ★ sinkloot 先给一个空实现（第 461 行 empty_loot_function），各变体再覆盖。
-- 好处：所有调用点（crabking 也会调）不必判空 —— 默认什么都不掉。
-- ⇒ 【可移植模式】「先给默认空实现，再由变体覆盖」比「调用点层层判空」干净得多。
    inst.InstantlyBreakBoat = InstantlyBreakBoat
    inst.GetSafePhysicsRadius = GetSafePhysicsRadius
    inst.IsBoatEdgeOverLand = IsBoatEdgeOverLand

    inst.OnLoadPostPass = OnLoadPostPass
-- OnLoadPostPass 挂在 C 段（服务端）—— 见第 165 行的阶段说明。

    return inst
end

local function build_boat_collision_mesh(radius, height)
-- ★★★ build_boat_collision_mesh：运行时程序化生成三角网格碰撞体。
-- 输入半径与高度，输出一个扁平的三角形顶点数组（每 3 个数一个顶点）。
-- 【为什么程序化】船有 4 种半径（木/草/远古/海獭/冰面共 5 种），
-- 若每种都要美术出一份碰撞网格，资产量翻 5 倍且容易不同步。
-- ⇒ ★【可移植模式】规则形状的碰撞体应当运行时生成，而不是做成美术资源。
-- ⇒ 【移植要点】DST 的碰撞是「网格 vs 实体」而非「形状 vs 实体」，三角形是最低通用形式。
    local segment_count = BOAT_COLLISION_SEGMENT_COUNT
    local segment_span = TWOPI / segment_count

    local triangles = {}
    local y0 = 0
    local y1 = height

    for segement_idx = 0, segment_count do
-- 循环 segement_idx 从 0 到 segment_count（含），比 segment_count 多一圈 ——
-- ★ 闭环技巧：多生成一个重合点把圆环接上，避免接缝处漏碰撞。

        local angle = segement_idx * segment_span
        local angle0 = angle - segment_span / 2
        local angle1 = angle + segment_span / 2
-- 每段生成 2 个三角形（4 个顶点）构成一圈「墙面」，拼成一个 20 面的圆柱壳。
-- ★ 只生成侧面不生成顶面和底面 —— 船上下是可通行的，不需要碰撞面。
-- ⇒ 少画 2×20 = 40 个三角形，碰撞检测也更快。这是「按需生成」的典型优化。

        local x0 = math.cos(angle0) * radius
        local z0 = math.sin(angle0) * radius

        local x1 = math.cos(angle1) * radius
        local z1 = math.sin(angle1) * radius

        table.insert(triangles, x0)
        table.insert(triangles, y0)
        table.insert(triangles, z0)

        table.insert(triangles, x0)
        table.insert(triangles, y1)
        table.insert(triangles, z0)

        table.insert(triangles, x1)
        table.insert(triangles, y0)
        table.insert(triangles, z1)

        table.insert(triangles, x1)
        table.insert(triangles, y0)
        table.insert(triangles, z1)

        table.insert(triangles, x0)
        table.insert(triangles, y1)
        table.insert(triangles, z0)

        table.insert(triangles, x1)
        table.insert(triangles, y1)
        table.insert(triangles, z1)
    end

	return triangles
end

local function boat_player_collision_template(radius)
-- boat_player_collision_template：★ 玩家碰撞体模板。
-- 第 658 行 AddTag("CLASSIFIED")：分类子实体标记 —— 它以「命名子槽」的形式挂在船下，
-- 客户端也知道有这个子实体，但内容由客户端各自计算（不同玩家的碰撞形状不同）。
-- ⇒ ★ CLASSIFIED 的含义：「网络知道它存在，但不传输它的状态」。
-- 对比 pighouse 的窗户（无 CLASSIFIED、也不联网）：那是完全私有。
    local inst = CreateEntity()

    inst.entity:AddTransform()

    --[[Non-networked entity]]
    inst:AddTag("CLASSIFIED")

    local phys = inst.entity:AddPhysics()
-- ★ SetMass(0)：质量 0 ⇒ 不受重力影响、不推动其它物体。玩家碰撞体只是「挡路墙」。
-- 第 664 行 SetRestitution(0)：不弹开。挡人而非弹人。
    phys:SetMass(0)
    phys:SetFriction(0)
    phys:SetDamping(5)
	phys:SetRestitution(0)
    phys:SetCollisionGroup(COLLISION.BOAT_LIMITS)
	phys:SetCollisionMask(
		COLLISION.CHARACTERS,
		COLLISION.WORLD
	)
    phys:SetTriangleMesh(build_boat_collision_mesh(radius + 0.1, 3))
-- ★ 半径 +0.1：比船体略大一圈，保证「玩家脚在船上但身体边缘略微出界」时仍被正确约束。
-- 物理与美术边缘的双保险：宁可多挡一点，也不要出现「站在船沿却没被带着走」。

    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")

    inst.entity:SetPristine()
-- ★★★ SetPristine 后立即判 ismastersim 返回 —— 碰撞体是纯服务端逻辑，无客户端状态。
-- 但它 AddNetwork 了（第 658 行是 CLASSIFIED 而非纯私有），
-- ⇒ 因为玩家碰撞体的位置必须两端一致，否则会出现「服务端说被挡、客户端说没挡」。
-- 这是 CLASSIFIED 存在的根本理由：位置要同步，内容各自算。
    if not TheWorld.ismastersim then
        return inst
    end

	inst.persists = false

    return inst
end

local function boat_item_collision_template(radius)
-- boat_item_collision_template：★ 与玩家碰撞体的三处关键差异：
--   1) SetMass(1000) —— 有质量，会推动物品（对比玩家碰撞体的 0）
--   2) 碰撞掩码含 ITEMS + FLYERS —— 只挡物品与飞行物
--   3) 半径 +0.2 —— 比玩家碰撞体再大一点，因为物品落地时有滚落余量
-- ⇒ 【可移植模式】同一形状按「谁会被挡住」拆成多个碰撞体，用质量与掩码区分。
    local inst = CreateEntity()

    inst.entity:AddTransform()

    --[[Non-networked entity]]
    inst:AddTag("CLASSIFIED")

    local phys = inst.entity:AddPhysics()
    phys:SetMass(1000)
    phys:SetFriction(0)
    phys:SetDamping(5)
    phys:SetCollisionGroup(COLLISION.BOAT_LIMITS)
	phys:SetCollisionMask(
		COLLISION.ITEMS,
		COLLISION.FLYERS,
		COLLISION.WORLD
	)
    phys:SetTriangleMesh(build_boat_collision_mesh(radius + 0.2, 3))
    --Boats currently need to not go to sleep because
    --constraints will cause a crash if either the target object or the source object is removed from the physics world
    --while the above is still true, the constraint is now properly removed before despawning the object, and can be safely ignored for this object, kept for future copy/pasting.
    phys:SetDontRemoveOnSleep(true)
-- ★ 第 704-706 行注释很有意思：明确说这条约束「现在已经正确解除了、可以忽略」，
-- 但仍保留 SetDontRemoveOnSleep(true) 以防万一。
-- ⇒ 【读源码收获】注释会记录「曾经有 bug、现在修好了、为何还没删」。这类信息读代码读不出来。

    inst:AddTag("NOBLOCK")
    inst:AddTag("ignorewalkableplatforms")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    return inst
end

local function ondeploy(inst, pt, deployer)
-- 【★ ondeploy：部署物品 → 实体结构的转换点】
-- 第 723 行 SpawnPrefab 的三个参数：prefab 名 + 关联皮肤名 + skin_id，
-- ⇒ 皮肤信息在「物品 → 成品」的传递靠这一行，是皮肤系统与部署系统的接口。
    local boat = SpawnPrefab(inst.deploy_product, inst.linked_skinname, inst.skin_id)
    if not boat then return end

    local boat_hull = boat.components.hull
    if boat.skinname and boat_hull and boat_hull.plank then
-- ★★★ 皮肤名的「按部位改写」：船有皮肤时，把走路板也换成对应的皮肤。
-- 皮肤名形如 boat_nautical / boat_grass_pirate，而走路板皮肤叫
-- walkingplank_nautical / walkingplank_grass_pirate（见 prefabskins.lua 第 1971-1980 行）。
-- ⇒ 做法是【剥掉船的前缀、拼上走路板的前缀】：
--   string.sub("boat_nautical", 5)      = "_nautical"       （5 = "boat_" 长度）
--   string.sub("boat_grass_pirate", 11) = "_pirate"         （11 = "boat_grass_" 长度）
-- 本人已核实：prefabs/boat.lua:731 与 prefabskins.lua:1971-1980 完全对得上，代码正确。
--
-- ⚠️ ★ 但这写法确实脆弱，两个隐患：
--   1) 魔法数 5 / 11 硬编码，等于「前缀长度」。新增一种船（如 boat_ice 有自己的前缀）时，
--      若忘了在第 730 行加一个判断分支，走路板皮肤就会算错。
--   2) 第 731 行的 `or 0`：两个条件都不成立时截取位置为 0，Lua 会当 1 处理，
--      结果是整个 skinname 被保留下来 —— 不会崩，但会拼出错误的名字。
-- ⇒ 【移植建议】改用 `boat.skinname:gsub("^boat_grass_", ""):gsub("^boat_", "")`
-- 或直接由皮肤表给出对应的走路板皮肤名，让命名规则只有一处定义。
        local iswoodboat = boat_hull.plank.prefab == "walkingplank"
        local isgrassboat = boat_hull.plank.prefab == "walkingplank_grass"
        if iswoodboat or isgrassboat then
            local plank_skinname = boat_hull.plank.prefab .. string.sub(boat.skinname, iswoodboat and 5 or isgrassboat and 11 or 0)
            TheSim:ReskinEntity( boat_hull.plank.GUID, nil, plank_skinname, boat.skin_id )
        end
    end

    boat.Physics:SetCollides(false)
-- ★★ 传送的三段式：先关碰撞 → 传送 → 开碰撞。
-- 缺任何一步都会出问题：直接传送可能被卡在陆地里，关了不开会让船永久无碰撞。
-- ⇒ 【可移植模式】「移动一个带碰撞的实体」的标准做法：临时关碰撞、搬位置、恢复碰撞。
    boat.Physics:Teleport(pt.x, 0, pt.z)
    boat.Physics:SetCollides(true)

    boat.sg:GoToState("place")

    if boat_hull then
        boat_hull:OnDeployed()
    end

    inst:Remove()
-- ★ 部署后立即 Remove 掉背包物品 —— 「一物一换」。
-- ⚠️ 但第 748 行 return boat：ondeploy 的返回值被 deployable 组件接收。
-- ⇒ 【移植提示】部署系统的约定是「回调返回新实体，原物品消失」，第 1543 行也用了同一返回值。

    return boat
end

local function wood_fn()
-- ★★★ 木船 fn：全文第一个变体，也是后续 4 个变体的写法范本。
-- 【变体 fn 的标准五步】
--   1) CreateEntity()
--   2) 写 XXX_BOAT_DATA 表
--   3) create_common_pre(inst, bank, build, DATA)
--   4) 变体专属的 A 段表现设置（第 768、770 行）
--   5) SetPristine → 客户端返回 → create_master_pst(inst, DATA) → 变体专属 C 段
-- ⇒ 【移植要点】把「共性」与「差异」在 fn 里分得这么开，是本文件最值得学的东西。
    local inst = CreateEntity()

    local bank = "boat_01"
    local build = "boat_test"

    local WOOD_BOAT_DATA = {
-- ★★ WOOD_BOAT_DATA 就是「变体配置表」。5 个变体各有一张，字段名完全一致。
-- ⇒ 【可移植模式】把变体差异收敛成一张「同构数据表」，
-- 共性代码只认表、不认具体变体 —— 这比一堆 if/else 分支好维护一个数量级。
-- 各表差异一览：
--   radius       —— 木=默认，草=GRASS_BOAT，远古=ANCIENT_BOAT，海獭=OTTERDEN_BOAT，冰=OCEAN_ICE_RADIUS
--   scale        —— 草=0.75，远古=1.334（见第 954 行常量），木/海盗/海獭=nil
--   plank_prefab —— 木/草/远古有，海盗/海獭无（海盗船没走路板）
--   fireproof    —— 仅冰面=true
--   stategraph   —— 仅冰面=SGboat_ice
        radius = TUNING.BOAT.RADIUS,
        max_health = TUNING.BOAT.HEALTH,
        item_collision_prefab = "boat_item_collision",
        boatlip_prefab = "boatlip",
        plank_prefab = "walkingplank",
        minimap_image = "boat.png",
    }

    inst = create_common_pre(inst, bank, build, WOOD_BOAT_DATA)

    inst.walksound = "wood"

    inst.components.walkableplatform.player_collision_prefab = "boat_player_collision"
-- ★★ player_collision_prefab 是变体专属的 A 段设置，不在 DATA 表里。
-- 因为它在 pre 段之后、SetPristine 之前赋值，第 412 行 AddComponent 已经执行过了，
-- 属于「给已挂好的组件补参数」。
-- ⇒ 【细节】同属变体差异，却分成「表内字段」与「表外补参数」两类。
-- 判断标准：能不能在 add 之前算出来。radius / scale 能，碰撞 prefab 名也能，
-- 但写代码时作者选择了直接赋值。移植时保持一致更重要，不必强行统一。

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst = create_master_pst(inst, WOOD_BOAT_DATA)

	inst:ListenForEvent("spawnnewboatleak", OnSpawnNewBoatLeak)
    inst.boat_crackle = "fx_boat_crackle"

    inst.sounds = sounds

    inst.sinkloot = function()
-- ★ sinkloot 覆盖了 pre/post 段的空实现（第 594 行）。
-- ★★ 第 785 行 ignitefragments = inst.activefires > 0：
-- 沉船时若船上正在着火，掉落的碎片会被点着（第 353-355 行 SpawnFragment 里的 Ignite）。
-- ⇒ 战斗与物理的耦合点之一，通过一个普通过渡的实例字段传递。
        local ignitefragments = inst.activefires > 0
        local locus_point = inst:GetPosition()
        local num_loot = 3
        local loot_angle = PI2/num_loot
        for i = 1, num_loot do
            local r = math.sqrt(math.random())*(WOOD_BOAT_DATA.radius - 2) + 1.5
-- ★★ 掉落物位置的均匀圆盘采样：r = sqrt(random) * (R-2) + 1.5。
-- 用 sqrt 保证面积均匀（若直接用 random，半径小的地方会挤成一团）——
-- 这是「极坐标下的均匀圆盘采样」标准公式，任何自研游戏都能用。
-- +1.5 的偏移保证碎片不会掉在船心（会被船体挡住）。
            local t = (i + 2 * math.random()) * loot_angle
-- t = (i + 2 * random()) * loot_angle：★ 第 i 个碎片的角度加了最多 ±一格的随机抖动，
-- 避免所有碎片整齐排成一圈。这是「规则布局 + 随机扰动」的典型手法。
            SpawnFragment(locus_point, "boards", math.cos(t) * r,  0, math.sin(t) * r, ignitefragments)
        end
    end

    inst.postsinkfn = function()
        local fx_boat_crackle = SpawnPrefab("fx_boat_pop")
        fx_boat_crackle.Transform:SetPosition(inst.Transform:GetWorldPosition())
        inst.SoundEmitter:PlaySoundWithParams(inst.sounds.damage, {intensity= 1})
        inst.SoundEmitter:PlaySoundWithParams(inst.sounds.sink)
    end

    return inst
end

local function grass_fn()
-- 草船 fn：★ 与木船的差异集中在「漏水机制」与「材料」两条线。
    local inst = CreateEntity()

    local bank = "boat_grass"
    local build = "boat_grass"
    local GRASS_BOAT_DATA = {
        radius = TUNING.BOAT.GRASS_BOAT.RADIUS,
        max_health = TUNING.BOAT.HEALTH,
        item_collision_prefab = "boat_grass_item_collision",
        scale = 0.75,
-- ★ scale = 0.75：草船模型小 25%。物理半径不变（第 812 行用 GRASS_BOAT.RADIUS），
-- ⇒ 视觉与物理尺寸不一致是刻意的：草船「看起来小」但判定范围与木船相同。
-- 【移植提示】美术缩放与碰撞体解耦，能让同一套物理服务多种外观。
        boatlip_prefab = "boatlip_grass",
        plank_prefab = "walkingplank_grass",
        minimap_image = "boat_grass.png",
    }

    inst = create_common_pre(inst, bank, build, GRASS_BOAT_DATA)

    inst.leaky = true
-- ★★ leaky = true + leakproof = true（第 845 行）看似矛盾，实际是：
-- 「会漏水」= 会持续掉血（有漏点表现），「防漏」= 不生成可交互的漏水实体。
-- 草船的漏点由第 215 行的 OnSpawnNewBoatLeak_Grass 直接扣血处理。
-- ⇒ 【命名陷阱】leaky 与 leakproof 是两套独立语义，不是一对反义词，命名有误导性。
    inst.material = "grass"

    inst.walksound = "marsh"
    inst.second_walk_sound = "tallgrass"

    inst.components.walkableplatform.player_collision_prefab = "boat_grass_player_collision"

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst = create_master_pst(inst, GRASS_BOAT_DATA)

	inst:ListenForEvent("spawnnewboatleak", OnSpawnNewBoatLeak_Grass)

    inst.sounds = sounds_grass

    local hullhealth = inst.components.hullhealth
    hullhealth:SetSelfDegrading(5)
-- SetSelfDegrading(5)：★ 草船会「自我劣化」，不漏也会慢慢坏。
-- 海獭巢也用了同一机制（第 1039 行），冰面用 1（第 1355 行）。
-- ⇒ 同一组件参数被三个变体改成三个值，说明这是「船的耐久衰减」通用机制。
    hullhealth.degradefx = "degrade_fx_grass"
    hullhealth.leakproof = true
-- ★ leakproof = true 与第 823 行 leaky = true 配对，见上面的说明。

    inst.components.repairable.repairmaterial = MATERIALS.HAY
-- ★ repairmaterial 从 WOOD（第 573 行）覆盖成 HAY —— 草船要用干草修。
-- 覆盖的是 create_master_pst 里已设置的组件字段，属于「变体改共性参数」的标准位置。

    inst.sinkloot = function()
        local ignitefragments = inst.activefires > 0
        local locus_point = inst:GetPosition()
        local num_loot = 6
        local loot_angle = PI2/num_loot
        for i = 1, num_loot do
            local r = math.sqrt(math.random())*(GRASS_BOAT_DATA.radius-2) + 1.5
            local t = (i + 2 * math.random()) * loot_angle
            SpawnFragment(locus_point, "cutgrass", math.cos(t) * r,  0, math.sin(t) * r, ignitefragments)
        end
    end
    inst.postsinkfn = function(inst)
        local ix, iy, iz = inst.Transform:GetWorldPosition()
        local erode = SpawnPrefab("boat_grass_erode")
        erode.Transform:SetPosition(ix, iy, iz)

        local erode_water = SpawnPrefab("boat_grass_erode_water")
        erode_water.Transform:SetPosition(ix, iy, iz)
    end

    return inst
end


local function pirate_initialize(inst)
-- pirate_initialize：★ 延迟一帧初始化（第 943 行 DoTaskInTime(0, ...)）。
-- 原因：需要等所有平台上的实体都就位（GetEntitiesOnPlatform）。
    local ents = inst.components.walkableplatform:GetEntitiesOnPlatform()

    local function oncannonremoved(cannon)
-- ★ oncannonremoved 用 table.removearrayvalue 而不是 table.remove ——
-- 前者会「按值删除所有相同项」且删除后不会产生空洞（会重排）。
-- ⇒ 【Lua 细节】DST 有大量 table.removearrayvalue 等扩展，标准库没有，写移植时需自己实现。
        table.removearrayvalue(inst.cannons, cannon)
    end

    for ent in pairs(ents) do
        if ent:HasTag("boatcannon") then
            table.insert(inst.cannons, ent)

            ent:ListenForEvent("onremove", oncannonremoved)
        end
    end
end

local function pirate_fn()
    local inst = CreateEntity()

    local bank = "boat_01"
    local build = "boat_pirate"
    local PIRATE_BOAT_DATA = {
        radius = TUNING.BOAT.RADIUS,
        max_health = TUNING.BOAT.HEALTH,
        item_collision_prefab = "boat_item_collision",
        scale = nil,
-- scale = nil：★ 显式写 nil 与不写效果相同，写出来是为了「六个变体字段对齐、便于对比」。
-- pirate 船沿用木船的物理参数，只换模型。⇒ 表驱动让「只换皮」成为两行 diff。
        boatlip_prefab = "boatlip",
        minimap_image = "boat_pirate.png",
    }

    inst = create_common_pre(inst, bank, build, PIRATE_BOAT_DATA)

    inst.walksound = "wood"

    inst.components.walkableplatform.player_collision_prefab = "boat_player_collision"

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.scrapbook_deps = { "pirate_flag_pole", "prime_mate", "powder_monkey" }
-- ★ scrapbook_deps（注意与文件头的 scrapbook_adddeps 是不同字段）——
-- 前者声明「本预制体依赖谁」，后者声明「本预制体解锁谁的图鉴」。
-- ⚠️ 字段极多且拼写相近（deps / adddeps / removedeps），扫源码时极易看错归属。
-- 【移植建议】这类元数据字段应统一前缀或收进子表，避免裸字段平铺。

    inst = create_master_pst(inst, PIRATE_BOAT_DATA)

    inst:ListenForEvent("spawnnewboatleak", OnSpawnNewBoatLeak)

    inst.boat_crackle = "fx_boat_crackle"
    inst.sounds = sounds

    inst.sinkloot = function()
        local ignitefragments = inst.activefires > 0
        local locus_point = inst:GetPosition()
        local num_loot = 3
        local loot_angle = PI2/num_loot
        for i = 1, num_loot do
            local r = math.sqrt(math.random())*(PIRATE_BOAT_DATA.radius-2) + 1.5
            local t = (i + 2 * math.random()) * loot_angle
            SpawnFragment(locus_point, "boards", math.cos(t) * r,  0, math.sin(t) * r, ignitefragments)
        end
    end

    inst.postsinkfn = function()
        local fx_boat_crackle = SpawnPrefab("fx_boat_pop")
        fx_boat_crackle.Transform:SetPosition(inst.Transform:GetWorldPosition())
        inst.SoundEmitter:PlaySoundWithParams(inst.sounds.damage, {intensity= 1})
        inst.SoundEmitter:PlaySoundWithParams(inst.sounds.sink)
    end
    inst.cannons = {}
    
    inst:DoTaskInTime(0, pirate_initialize)

    return inst
end

local function do_boat_container_offset(boat, container)
	if container ~= nil and container:IsValid() then
    	container.Transform:SetPosition(boat.Transform:GetWorldPosition())
    end
end

local ANCIENT_BOAT_SCALE = 1.334
-- ★ ANCIENT_BOAT_SCALE = 1.334：抽成常量是因为它被用了两次 ——
-- 第 966 行的 data.scale 与第 1626 行 placer 的 SetScale。
-- ⇒ 【可移植模式】同一个数值在「实体」与「放置预览」两处使用时必须抽常量，
-- 否则预览与实体会大小不符，玩家看到的预览不是真实占地。

local function ancient_fn()
    local inst = CreateEntity()

    local bank  = "boat_yotd"
    local build = "boat_ancient"

    local ANCIENT_BOAT_DATA = {
        radius = TUNING.BOAT.ANCIENT_BOAT.RADIUS,
        max_health = TUNING.BOAT.ANCIENT_BOAT.HEALTH,
        item_collision_prefab = "boat_item_collision",
        scale = ANCIENT_BOAT_SCALE,
        boatlip_prefab = "boatlip_ancient",
        plank_prefab = "walkingplank_ancient",
        minimap_image = "boat_ancient.png",
        leak_build_override = "boat_leak_ancient_build",
    }

    inst = create_common_pre(inst, bank, build, ANCIENT_BOAT_DATA)

    inst.walksound = "wood"

    inst.components.walkableplatform.player_collision_prefab = "boat_player_collision"

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst = create_master_pst(inst, ANCIENT_BOAT_DATA)

    if not POPULATING then
-- ★ not POPULATING：世界生成期间不生成容器。
-- 原因：生成期还没有 shipwrecked 的遗迹布局信息，容器会出现在不该出现的位置。
-- ⇒ 【DST 通则】POPULATING 是个全局标志，凡是「依赖世界已生成完毕」的逻辑都要判它。
        inst._container = SpawnPrefab("boat_ancient_container")
        inst:DoTaskInTime(0, do_boat_container_offset, inst._container)
-- DoTaskInTime(0, do_boat_container_offset, inst._container) 再一次印证：
-- 新生成的子实体要延迟一帧才能读到正确的世界坐标（对比第 242-251 行）。
    end

    inst.components.hullhealth.max_health_damage = TUNING.BOAT.ANCIENT_BOAT.MAX_HULL_HEALTH_DAMAGE
-- ★ 三个阈值全部覆盖：max_health_damage / small_leak_dmg / med_leak_dmg。
-- 远古船漏得更狠但也更耐打 —— 通过覆盖 hullhealth 组件的参数实现，
-- 不需要为它写一套新的耐久逻辑。
    inst.components.hullhealth.small_leak_dmg = TUNING.BOAT.ANCIENT_BOAT.SMALL_LEAK_DMG_THRESHOLD
    inst.components.hullhealth.med_leak_dmg = TUNING.BOAT.ANCIENT_BOAT.MED_LEAK_DMG_THRESHOLD

    inst._fire_damage = TUNING.BOAT.ANCIENT_BOAT.FIRE_DAMAGE

	inst:ListenForEvent("spawnnewboatleak", OnSpawnNewBoatLeak)
    inst.boat_crackle = "fx_boat_crackle"

    inst.sounds = sounds

    inst.sinkloot = function()
        local ignitefragments = inst.activefires > 0
        local locus_point = inst:GetPosition()
        local num_loot = 3
        local loot_angle = PI2/num_loot
        for i = 1, num_loot do
            local r = math.sqrt(math.random())*(ANCIENT_BOAT_DATA.radius - 2) + 1.5
            local t = (i + 2 * math.random()) * loot_angle
            SpawnFragment(locus_point, "boards", math.cos(t) * r,  0, math.sin(t) * r, ignitefragments)
        end
    end

    inst.postsinkfn = function()
        local fx_boat_crackle = SpawnPrefab("fx_boat_pop")
        fx_boat_crackle.Transform:SetPosition(inst.Transform:GetWorldPosition())
        inst.SoundEmitter:PlaySoundWithParams(inst.sounds.damage, {intensity= 1})
        inst.SoundEmitter:PlaySoundWithParams(inst.sounds.sink)
    end

    return inst
end

-- OTTER DEN PLATFORM
local function OnRowed_OtterDen(inst, rower)
-- OnRowed_OtterDen：★ 摇橹时惊动船上的敌人（打标签判定，而非写死生物类型）。
-- ⇒ 【可移植模式】用 tag 表达「被摇船会生气」，新增生物时只要打 tag 即可，
-- 不必改船的代码。这是 DST 标签系统最实用的场景之一。
    local entities_on_platform = inst.components.walkableplatform:GetEntitiesOnPlatform()
    for entity_on_platform in pairs(entities_on_platform) do
        if entity_on_platform:HasTag("angry_when_rowed") then
            entity_on_platform:PushEvent("onmoved", rower)
        end
    end
end

local function otterden_comment_timeout(inst)
    inst._comment_timeout_task = nil
end
local function otterden_start_erosion(inst, amount)
-- ★★ otterden_start_erosion 的「反向播放」技巧（第 1042-1050 行）：
-- 若当前正播 crack_reverse（正在恢复），算出 54 - 当前帧 作为新动画的起始帧。
-- ⇒ 让 crack 与 crack_reverse 两段动画在视觉上接得上，不会突然跳帧。
-- ⚠️ 魔法数 54 应为 crack 动画总帧数，源码未抽常量 ——
-- ⚠️ 真实技术债（本人核实过）：第 1044、1058 行两处硬编码 54，
-- 改动画长度需同时改这两个位置。等级低于 CUHIDERFRAMES（那里有注释标记），但同样脆弱。
    amount = amount or TUNING.BOAT_OTTERDEN_ERODE_RATE
    inst.components.hullhealth:SetSelfDegrading(amount)
    if not inst.AnimState:IsCurrentAnimation("crack") then
-- IsCurrentAnimation("crack") 判重：已在播放就什么都不做，避免打断。
-- ★ 这类「幂等 + 脏检查」写法在本文件出现多次（第 1040、1080、1096 行），是 DST 事件处理的通用习惯。
        local start_frame = nil
        if inst.AnimState:IsCurrentAnimation("crack_reverse") then
            local current_crack_frame = inst.AnimState:GetCurrentAnimationFrame()
            start_frame = 54 - current_crack_frame
            if start_frame < 1 then start_frame = nil end
        end
        inst.AnimState:PlayAnimation("crack")
        if start_frame then
            inst.AnimState:SetFrame(start_frame)
        end
    end
end
local function otterden_stop_erosion(inst)
    inst.components.hullhealth:SetSelfDegrading(0)
    local start_frame = nil
    if inst.AnimState:IsCurrentAnimation("crack") then
        local current_crack_frame = inst.AnimState:GetCurrentAnimationFrame()
        start_frame = 54 - current_crack_frame
        if start_frame < 1 then start_frame = nil end
    end
    inst.AnimState:PlayAnimation("crack_reverse")
    if start_frame then
        inst.AnimState:SetFrame(start_frame)
    end
    inst.AnimState:PushAnimation("idle_full")
end
local function otterden_on_update(inst, dt)
-- ★ otterden_on_update：每 0.5 秒检查一次船所在的地块类型。
-- 第 1076-1079 行的判定：不是三个「近岸」地块、但仍是海洋 ⇒ 已漂到深水 ⇒ 开始腐蚀。
-- ⇒ 【可移植模式】用「排除若干特例」的写法而非黑名单，加新地块类型时不易漏。
    -- If we're already missing our den, we should already be degrading,
    -- so don't waste cycles checking map tiles or anything, and
    -- don't accidentally stop doing the degrading for that.
    local den = inst.components.entitytracker:GetEntity("otterden")
    if not den then return end

    local hullhealth = inst.components.hullhealth
    local boat_tile = TheWorld.Map:GetTileAtPoint(inst.Transform:GetWorldPosition())
    if boat_tile ~= WORLD_TILES.OCEAN_COASTAL
            and boat_tile ~= WORLD_TILES.OCEAN_COASTAL_SHORE
            and boat_tile ~= WORLD_TILES.OCEAN_WATERLOG
            and TileGroupManager:IsOceanTile(boat_tile) then
        if hullhealth.selfdegradingtime == 0 then
-- ★ selfdegradingtime == 0 判重：只有从「没在腐蚀」变成「在腐蚀」的那一刻才触发后续逻辑。
-- 第 1096 行的停止判定用 == TUNING.BOAT_OTTERDEN_ERODE_RATE 做同样的判重。
-- ⇒ 【易踩的坑】用「期望值相等」判重在外部把速率改掉时会失效；
-- 用 > 0 更稳妥。这里两处写法不统一，属可改进点。
            otterden_start_erosion(inst)
            if inst._comment_timeout_task ~= nil then
                return
            end

            local players_on_platform = inst.components.walkableplatform:GetPlayersOnPlatform()
            if next(players_on_platform) ~= nil then
-- 随机挑一个船上的玩家推事件：GetRandomWithVariance 之类的辅助都在 util.lua。
-- ★ 只对一个人说话，避免多人客户端同时收到提示 —— 常见的「本地化通知」处理。
                local random_player_on_platform = GetRandomKey(players_on_platform)
                if random_player_on_platform then
                    inst._comment_timeout_task = inst:DoTaskInTime(20, otterden_comment_timeout)
                    random_player_on_platform:PushEvent("otterboaterosion_begin", "deepwater")
                end
            end
        end
    else
        if hullhealth.selfdegradingtime == TUNING.BOAT_OTTERDEN_ERODE_RATE then
            otterden_stop_erosion(inst)
        end
    end
end

local function otterden_initialize(inst)
-- otterden_initialize：★ 第 1111 行把 inst._on_den_removed 注册在 den 上，
-- 而 _on_den_removed 的定义在第 1252 行 —— 位于函数调用点的后面。
-- Lua 闭包在第 1111 行执行时能读到它，因为第 1252 行已在 fn() 之前跑完。
-- ⇒ 【阅读提示】跨 140 行的前向引用，全靠「第 1261 行 DoTaskInTime(0) 推迟一帧」兜住。
-- 若改成同步调用就会读到 nil。★ 这又是「DoTaskInTime(0) 隐性依赖全局初始化顺序」的例子。
    local entitytracker = inst.components.entitytracker
    local den = entitytracker:GetEntity("otterden")
    if not den and not inst._den_spawned then
        den = SpawnPrefab("otterden")
        den.Transform:SetPosition(inst.Transform:GetWorldPosition())
        entitytracker:TrackEntity("otterden", den)
        inst._den_spawned = true
    end
    inst:ListenForEvent("onremove", inst._on_den_removed, den)
end

local function on_dead_otterden_added(inst, den)
-- on_dead_otterden_added：★ 往 hullhealth 的私有数组里插实体（同第 198 行的做法）。
-- 把「已死的巢」也当成一个漏点，让船持续掉血。属于「敌人死后仍施加影响」的设计。
    if not inst.components.entitytracker:GetEntity("otterden_dead") then
        inst.components.entitytracker:TrackEntity("otterden_dead", den)
        table.insert(inst.components.hullhealth.leak_indicators_dynamic, den)
    end
end

local function otterden_onsave(inst, data)
    if inst._den_spawned then
        data.den_spawned = true
    end

    if inst.components.hullhealth.selfdegradingtime ~= 0 then
        data.erosion_rate = inst.components.hullhealth.selfdegradingtime
    end
end

local function otterden_onload(inst, data)
    if data then
        inst._den_spawned = data.den_spawned
        if data.erosion_rate then
            otterden_start_erosion(inst, data.erosion_rate)
        end
    end
end

local function otterden_onloadpostpass(inst, newents, data)
-- otterden_onloadpostpass：★ 又一个 OnLoadPostPass（第 599 行那个是 create_master_pst 里挂的）。
-- 变体可以覆写主干的 OnLoadPostPass —— 这里是追加逻辑，不是替换。
-- ⚠️ 注意与第 165 行的 OnLoadPostPass 是不同函数：那个管碰撞体朝向，这个管巢的漏点重挂。
    local dead_den = inst.components.entitytracker:GetEntity("otterden_dead")
    if dead_den then
        if inst.components.hullhealth then
            table.insert(inst.components.hullhealth.leak_indicators_dynamic, dead_den)
        end
    end
end

local function CLIENT_MakeOtterdenTuft(inst, anim_index)
-- CLIENT_MakeOtterdenTuft：★ 又一个「纯客户端装饰子实体」（对比 pighouse 的窗户）。
-- 同样的三件套：AddTag("FX") / persists = false / 不 AddNetwork / SetParent。
-- ⇒ 【DST 装饰实体的标准配方】本文件与 pighouse.lua、terasurechest.lua 三处一致。
-- 第 1150 行 anim_index = anim_index or math.random(3)：随机 3 种草丛造型之一。
    anim_index = anim_index or math.random(3)

    local tuft = CreateEntity()
    tuft:AddTag("FX")
    --[[Non-networked entity]]
    tuft.persists = false
    tuft.entity:AddTransform()
    tuft.entity:AddAnimState()
    tuft.entity:SetParent(inst.entity)

    tuft.AnimState:SetBank("boat_otterden_tuft")
    tuft.AnimState:SetBuild("boat_otterden_tuft")
    tuft.AnimState:PlayAnimation("idle"..anim_index)

    return tuft
end

local function otterden_fn()
    local inst = CreateEntity()

    local bank = "boat_otterden"
    local build = "boat_otterden"
    local OTTERDEN_BOAT_DATA = {
        radius = TUNING.BOAT.OTTERDEN_BOAT.RADIUS,
        max_health = TUNING.BOAT.OTTERDEN_BOAT.HEALTH,
        item_collision_prefab = "boat_otterden_item_collision",
        boatlip_prefab = "boatlip_otterden",
        minimap_image = "boat_otterden.png",
    }

    inst = create_common_pre(inst, bank, build, OTTERDEN_BOAT_DATA)

    inst.material = "kelp"
    inst.walksound = "marsh"
    inst.second_walk_sound = "tallgrass"

    inst.components.walkableplatform.player_collision_prefab = "boat_otterden_player_collision"

    if not TheNet:IsDedicated() then
-- ★ 6 丛草按 GetRandomWithVariance(基准角, PI/6) 分布 —— 在均匀分布上叠一层抖动。
-- 偏移半径用 sqrt(random()) 保证圆盘均匀分布（同第 790 行的碎片散布公式）。
-- ⇒ ★ 同一个「均匀圆盘采样」公式在本文件出现 3 次（第 790、855、1194 行），
-- DST 没有把它收进 util —— 属于值得提炼的通用工具函数。
        local tuft_angle, tuft_offset
        local NUM_TUFTS = 6
        for i = 1, NUM_TUFTS do
            local tuft = CLIENT_MakeOtterdenTuft(inst)
            tuft_angle = GetRandomWithVariance((i * TWOPI/NUM_TUFTS), PI/6)
            tuft_offset = 1.0 + (OTTERDEN_BOAT_DATA.radius * 0.5) * (math.sqrt(math.random()))
            tuft.Transform:SetPosition(
                tuft_offset * math.cos(tuft_angle),
                0,
                tuft_offset * math.sin(tuft_angle)
            )
        end
    end

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    --inst.scrapbook_deps = { "otter", "otterden" }

    inst = create_master_pst(inst, OTTERDEN_BOAT_DATA)

    inst:ListenForEvent("spawnnewboatleak", OnSpawnNewBoatLeak_Grass)
    inst:ListenForEvent("rowed", OnRowed_OtterDen)

    inst.sounds = sounds_grass

    inst.components.repairable.repairmaterial = MATERIALS.KELP
    inst.components.hullhealth.leakproof = true
-- leakproof = true：与草船相同，海獭巢也靠持续掉血而非漏水实体。

    -- Just start a steady regeneration on the boat, so that it can recover from being moved out to the deep ocean.
    inst.components.health:StartRegen(1, 5*TUNING.BOAT_OTTERDEN_ERODE_RATE)
-- ★ StartRegen(1, 5 * ERODE_RATE)：定时回血，防止船被推到深水后回不回来。
-- 数值 5 与自腐蚀速率挂钩 —— ★ 设计意图是「回血速度 5 倍于掉血速度」，
-- 玩家只要尽快摇橹回来就能救回。
-- ⇒ 【平衡性设计】把「惩罚」做成「可挽回」：设定明确的追赶速率而不是无解死亡。

    -- To track our den, especially between save/loads
    inst:AddComponent("entitytracker")
-- entitytracker 组件：★ 追踪并持久化一个具名子实体（这里是海獭的巢）。
-- ⇒ 组件提供的正是「存档时记住 GUID、读档时还原实体」的能力（第 1103、1108、1114 行）。
-- 【移植要点】需要跨存档保持的子实体关系，用专门的 tracker 组件，
-- 不要自己手写 GUID 映射（对比 crabking.lua 第 537 行的手写版）。

    --
    inst._check_for_tile_degrade_task = inst:DoPeriodicTask(0.5, otterden_on_update, 0.5 * (1 + math.random()))
-- DoPeriodicTask(0.5, fn, 初始延迟 0.5*(1+random()))：★ 初次延迟随机化，打散负载。
-- 同 pighouse.lua 第 299 行、deciduoustrees.lua 的处理，是 DST 统一惯例。

    --
    inst.sinkloot = function()
        local ignitefragments = inst.activefires > 0
        local locus_point = inst:GetPosition()
        local num_loot = 6
        local loot_angle = PI2/num_loot
        local sqrt, random, sin, cos = math.sqrt, math.random, math.sin, math.cos
        for i = 1, num_loot do
            local r = sqrt(random())*(OTTERDEN_BOAT_DATA.radius-2) + 1.5
            local t = (i + 2 * random()) * loot_angle
            SpawnFragment(locus_point, "kelp", cos(t) * r, 0, sin(t) * r, ignitefragments)
        end
    end
    inst.postsinkfn = function(inst)
        local ix, iy, iz = inst.Transform:GetWorldPosition()
        local erode = SpawnPrefab("boat_otterden_erode")
        erode.Transform:SetPosition(ix, iy, iz)

        local erode_water = SpawnPrefab("boat_otterden_erode_water")
        erode_water.Transform:SetPosition(ix, iy, iz)
    end

    --
    inst._on_den_removed = function()
        local players_on_platform = inst.components.walkableplatform:GetPlayersOnPlatform()
        if next(players_on_platform) ~= nil then
            local random_player_on_platform = GetRandomKey(players_on_platform)
            if random_player_on_platform then
                random_player_on_platform:PushEvent("otterboaterosion_begin", "dengone")
            end
        end
    end
    inst:DoTaskInTime(0, otterden_initialize)

    --
    inst:ListenForEvent("dead_otterden_added", on_dead_otterden_added)

    --
    inst.OnSave = otterden_onsave
    inst.OnLoad = otterden_onload
    inst.OnLoadPostPass = otterden_onloadpostpass

    return inst
end

-- ICE FLOE
local function ice_floe_deploy_blocker_fn()
-- ice_floe_deploy_blocker_fn：★ 一个「无视觉的阻挡体」。
-- 它只有 Transform + Network + SetDeployExtraSpacing，没有任何表现组件。
-- ⇒ 【可移植模式】「限制玩家把东西放哪」这类纯逻辑约束，
-- 可以做成一个看不见的实体，而不是给每块冰各写一段判定。
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    -- Prevent things from being deployed onto the ice floes. 
    inst:SetDeployExtraSpacing(TUNING.OCEAN_ICE_RADIUS + 0.1)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    return inst
end

local function ice_ondeath(inst)
-- ice_ondeath：★ 双重守卫 IsAsleep() 与 HasStateTag("dead")。
-- 双重守卫的原因：状态机的 dead 标签与 health 组件的死亡是两套通知，
-- ★ 靠两个都满足才执行沉没动画，是防御「双重触发」的标准写法。
	if inst:IsAsleep() then
		if not inst.sg:HasStateTag("dead") then
			for ent in pairs(inst.components.walkableplatform:GetEntitiesOnPlatform()) do
				ent:PushEvent("abandon_ship")
			end
		end
		inst.sinkloot_asleep()
		inst:Remove()
	end
end

local function ice_fn()
    local inst = CreateEntity()

    local bank = "boat_ice"
    local build = "boat_ice"
    local OCEANICE_BOAT_DATA = {
        radius = TUNING.OCEAN_ICE_RADIUS,
        max_health = TUNING.OCEAN_ICE_HEALTH,
        item_collision_prefab = "boat_ice_item_collision",
        boatlip_prefab = "boatlip_ice",
        stategraph = "SGboat_ice",
        fireproof = true,
    }

    inst = create_common_pre(inst, bank, build, OCEANICE_BOAT_DATA)

    inst:RemoveTag("wood") -- Cookie Cutters should not eat it.
-- ★ RemoveTag("wood") + 原注释 Cookie Cutters should not eat it：
-- 用 tag 表达「不是木头」，让 Cookie Cutters 组件的查询自动跳过。
-- ⇒ 【零修改扩展】新增一个 Cookie Cutters 时只需检查这个 tag，不必改冰面代码。

    inst.material = "ice"
    inst.walksound = "ice"

    inst.components.walkableplatform.player_collision_prefab = "boat_ice_player_collision"

    local boattrail = inst.components.boattrail
-- ★ boattrail 可能为 nil（第 447 行只在非专服创建）——这里做了判空。
-- 专服上 inst.components.boattrail 为 nil，直接访问会崩。
-- ⇒ 【⚠️ 常见坑】AddComponent 放在 if not IsDedicated() 里（pre 段），
-- 却在 C 段无判空访问 —— 本文件这里处理对了，写新代码时最容易漏。
    if boattrail then
        local scale = TUNING.OCEAN_ICE_RADIUS / TUNING.BOAT.RADIUS
        boattrail.scale_x = scale
        boattrail.scale_y = scale

        boattrail.radius = boattrail.radius * scale
    end

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.GetIdleLevel = function()
-- ★ GetIdleLevel：按血量三档返回 "1"/"2"/"3"，供状态图决定用哪套待机动画。
-- ⇒ 【状态图与预制体的接口】预制体提供数据，状态图决定表现。
-- 这种「预制体给函数、状态图调」的分工，避免了状态图里写死血量阈值。
        local health_percent = inst.components.health:GetPercent()
        return (health_percent > 0.66 and "1")
            or (health_percent > 0.33 and "2")
            or "3"
    end

    inst = create_master_pst(inst, OCEANICE_BOAT_DATA)

	inst:ListenForEvent("spawnnewboatleak", OnSpawnNewBoatLeak)
	inst:ListenForEvent("death", ice_ondeath)

    inst.components.hullhealth:SetSelfDegrading(1)
    inst.components.hullhealth.leakproof = true

    inst.components.repairable.repairmaterial = nil
-- ★ repairmaterial = nil：冰面船不可修理。覆盖了共性的 WOOD（第 573 行）。
-- ⇒ 用 nil 表达「禁用某能力」比加一个 enabled=false 更简洁，但可读性差一些。

    inst.sounds = sounds_ice
    inst.boat_crackle = "mining_ice_fx"

    inst:DoTaskInTime(FRAMES, function(i)
-- DoTaskInTime(FRAMES, ...)：延迟一帧生成 deploy_blocker。
-- ★ 为什么用 FRAMES 而不是 0：阻挡体要等船的位置确定后再生成。
        local ix, iy, iz = i.Transform:GetWorldPosition()
        local deploy_blocker = SpawnPrefab("boat_ice_deploy_blocker")
        deploy_blocker.Transform:SetPosition(ix, iy, iz)
    end)

    inst.sinkloot = function()
        local ignitefragments = false --(inst.activefires > 0)
        local locus_point = inst:GetPosition()
        local num_loot = 3
        local loot_angle = PI2/num_loot
        local loot_radius = (OCEANICE_BOAT_DATA.radius/2)
        for i = 1, num_loot do
            local r = (1 + math.sqrt(math.random()))*loot_radius
            local t = (i + 2 * math.random()) * loot_angle
            SpawnFragment(locus_point, "ice", math.cos(t) * r, 0, math.sin(t) * r, ignitefragments)

            r = (1 + math.sqrt(math.random()))*loot_radius
            t = t + loot_angle * (0.3 + 0.6 * math.random())
            SpawnFragment(locus_point, "degrade_fx_ice", math.cos(t) * r, 0, math.sin(t) * r)
        end
    end
	inst.sinkloot_asleep = function()
		local num_loot = math.random(3) - 1
-- sinkloot_asleep：★ 冰面沉没时若实体已睡着，只掉 0~2 块（math.random(3) - 1 可能是 0 或负数）。
-- 第 1387 行 `if num_loot > 0` 兜住了负数与 0 的情况。
-- ⇒ 【⚠️ 隐患】math.random(3) 返回 1..3，减 1 得 0..2，不会为负。判空是多余的但无害。
-- 真正需要判空的是 num_loot == 0 的情况（loot_angle = TWOPI/0 = inf）。
-- ★ 好在第 1387 行的 if 挡住了 —— 属于「靠巧合正确」但结论是对的写法。
		if num_loot > 0 then
			local locus_point = inst:GetPosition()
			local loot_angle = PI2/num_loot
			local loot_radius = (OCEANICE_BOAT_DATA.radius/2)
			for i = 1, num_loot do
				local r = (1 + math.sqrt(math.random()))*loot_radius
				local t = (i + 2 * math.random()) * loot_angle
				SpawnFragment(locus_point, "ice", math.cos(t) * r, 0, math.sin(t) * r, false)
			end
		end
	end
    inst.postsinkfn = function(inst)
        local break_fx = SpawnPrefab("mining_ice_fx")
        break_fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    end

    inst.SpawnFragment = SpawnFragment

    return inst
end

local function ice_crabking_fn()
-- ★★★ ice_crabking_fn：最极端的变体 —— 直接调用另一个变体的 fn！
-- 第 1409 行 `local inst = ice_fn()`：复用了冰面船的全部装配，
-- 再覆盖三个东西：sinkloot（只掉碎冰渣）、血量设 10、返回。
-- ⇒ ★★【可移植模式】「变体派生变体」：不用重写 fn，直接调另一个变体的构造函数再打补丁。
-- 这比在工厂里加第 10 个布尔参数优雅得多 ——
-- ★ 【对照】treasurechest.lua 走的是「工厂 + 钩子」路线，本文件走的是「调用 + 覆盖」路线。
-- 两条路各有适用面：变体数量多且差异正交时用工厂；变体少且高度相似时用覆盖。
    local inst = ice_fn()

    if not TheWorld.ismastersim then
-- ★ 覆盖前先判 ismastersim 返回 —— 因为 ice_fn 的 C 段已经执行过了。
-- ⚠️ 【⚠️ 陷阱，务必注意】本函数没有 SetPristine，也没有客户端早返回，
-- 它完全依赖 ice_fn 内部已经做完这一切。
-- ⇒ 读这个函数时必须先确认 ice_fn 做了什么，不能只看本函数体。
-- 【移植建议】派生变体时把「返回前是否已过 SetPristine」写成显式注释，否则极易误改。
        return inst
    end

    local function sinkloot()
        local ignitefragments = false --(inst.activefires > 0)
        local locus_point = inst:GetPosition()
        local num_loot = 3
        local loot_angle = TWOPI/num_loot
        local loot_radius = (inst.components.hull:GetRadius()/2)
        for i = 1, num_loot do
            local r = (1 + math.sqrt(math.random()))*loot_radius
            local t = (i + 2 * math.random()) * loot_angle
            
            r = (1 + math.sqrt(math.random()))*loot_radius
            t = t + loot_angle * (0.3 + 0.6 * math.random())
            inst.SpawnFragment(locus_point, "degrade_fx_ice", math.cos(t) * r, 0, math.sin(t) * r)
        end
    end
    
    inst.sinkloot = sinkloot
    inst.components.health:SetVal(10)
-- SetVal(10)：★ 蟹王冰面的血量被强制改成 10（因为它不是用来打的，是场地）。
-- ⇒ 这是「复用预制体但语义完全不同」的极端案例：看起来是船，实际是地图的一部分。

    return inst
end

-- ITEMS

function CLIENT_CanDeployBoat(inst, pt, mouseover, deployer, rotation)
-- ★★ 注意这里是 `function`（全局）而不是 `local function` —— 全文件唯一一处。
-- 本人已核实：grep 全库，CLIENT_CanDeployBoat 只在本文件定义与使用（第 1459 行），
-- 另有 5 处以注释形式引用它（util.lua:1958、prefabs/yotd_boats.lua:746-747、
-- 以及本文件第 1613-1614 行）。
-- ⇒ 【判定】刻意为之：它被写成「可被跨文件引用的公共约定」。
-- util.lua 与 yotd_boats.lua 的注释都明确写着 see CLIENT_CanDeployBoat，
-- 说明作者有意让它成为船放置规则的「唯一事实来源」。
-- ⇒ 【移植建议】这个写法本身值得学（把跨文件约定显式暴露成一个全局函数），
-- 但仍要注意：Lua 的全局是「无声明的隐式契约」，拼错不会报错。
-- 更好的做法是放进一个具名模块（如 boatutil）再 require。
	local inventory = deployer and deployer.replica.inventory
	if inventory and inventory:IsFloaterHeld() then
		local hop_range = TUNING.FLOATING_HOP_DISTANCE_PLATFORM - 0.01 --make sure we're close enough to hop at max range
		local max_range = inst._boat_radius + hop_range
		local min_range = inst._boat_radius + 0.5
		local dsq = deployer:GetDistanceSqToPoint(pt)
		if dsq > max_range * max_range or dsq < min_range * min_range then
			return false
		end
	end
    return TheWorld.Map:CanDeployBoatAtPointInWater(pt, inst, mouseover,
-- ★★ hop_range = FLOATING_HOP_DISTANCE_PLATFORM - 0.01：减 0.01 保证边界内判定。
-- 第 1446 行用平方比较（dsq > max_range * max_range）避免开方 —— 标准的距离优化。
-- ⇒ 【可移植模式】「勾一个玩家站在平台上放船」的手感，靠一个减 0.01 的容差控制。
-- 数值小到看着像 hack，但这是 DST 处理浮点与玩家预期的标准做法。
    {
        boat_radius = inst._boat_radius,
        boat_extra_spacing = 0.2,
        min_distance_from_land = 0.2,
    })
end

local function common_item_fn_pre(inst)
-- common_item_fn_pre：★ 建造物品的 pre 段（与船的 create_common_pre 同构但更短）。
-- 第 1459 行把 _custom_candeploy_fn 挂到实例上 —— 部署前的合法性检查函数。
-- ⇒ 【部署系统扩展点】物品自己决定「能不能放在这里」，不需要改 deployable 组件。
    inst._custom_candeploy_fn = CLIENT_CanDeployBoat
    inst._boat_radius = TUNING.BOAT.RADIUS

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst:AddTag("boatbuilder")
	inst:AddTag("deploykititem")
    inst:AddTag("usedeployspacingasoffset")

    MakeInventoryPhysics(inst)
-- MakeInventoryPhysics：背包物品专用物理（可被丢、可掉落、有浮空效果）。
-- 与船的 AddPhysics（第 386 行）是两套不同预设，别混用。

    inst.AnimState:SetBank("seafarer_boat")
    inst.AnimState:SetBuild("seafarer_boat")
    inst.AnimState:PlayAnimation("IDLE")

    MakeInventoryFloatable(inst, "med", 0.25, 0.83)
-- MakeInventoryFloatable(inst, "med", 0.25, 0.83)：★ 物品浮在水面的参数。
-- "med" 是尺寸档位（还有 small/large），后两个数是高度与缩放。
-- ⇒ 【可移植模式】物品浮水做成统一组件 + 尺寸档位，而不是逐个物品调物理。

    return inst
end

local function common_item_fn_pst(inst)
-- common_item_fn_pst：物品的 C 段。★ deployable 组件的 ondeploy 指向第 722 行的 ondeploy。
-- 第 1485 行 SetDeployMode(DEPLOYMODE.CUSTOM)：让放置预览行为完全自定义。
-- 第 1490-1491 行 fuel 组件 + LARGE_FUEL：★ 烧掉船物品释放的燃料量，
-- 是「烧一艘船 = 多少燃料」这一玩法的落点。
    local deployable = inst:AddComponent("deployable")
    deployable.ondeploy = ondeploy
    deployable:SetDeploySpacing(DEPLOYSPACING.LARGE)
    deployable:SetDeployMode(DEPLOYMODE.CUSTOM)

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    local fuel = inst:AddComponent("fuel")
    fuel.fuelvalue = TUNING.LARGE_FUEL

    MakeLargeBurnable(inst)
    MakeLargePropagator(inst)
    MakeHauntableLaunch(inst)
-- MakeHauntableLaunch（注意是 Launch 不是 Work，对比 pighouse.lua 第 442 行的 Work）：
-- 两种闹鬼模式的区别：Work = 鬼替你敲一下；Launch = 鬼替你使用一次。
-- ⇒ 同一个 hauntable 组件 + 不同的初始化函数 = 两种玩法。组件的组合性体现于此。

    return inst
end

local function item_fn()
-- item_fn：木船物品。★ 全流程只有 5 行有效代码，因为 pre/pst 都复用了。
-- 第 1505 行 deploy_product = "boat"：★ 「这个物品造出什么」由字段声明，
-- 于是第 722 行的 ondeploy 第 723 行直接 SpawnPrefab(inst.deploy_product) 即可通用。
-- ⇒ 【可移植模式】物品与产物通过一个字符串字段解耦，新增船不需要改部署逻辑。
    local inst = CreateEntity()

    inst = common_item_fn_pre(inst)

    inst.deploy_product = "boat"

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst = common_item_fn_pst(inst)

    return inst
end

local function grass_item_fn()
-- grass_item_fn：草船物品。★ 注意只改 build 与 deploy_product，pre/pst 照抄。
-- 第 1534 行覆盖 deployspacing（LARGE → PLACER_DEFAULT）：草船更小所以间距更小。
    local inst = CreateEntity()

    inst = common_item_fn_pre(inst)
    inst._boat_radius = TUNING.BOAT.GRASS_BOAT.RADIUS

    inst.AnimState:SetBank("seafarer_boat")
    inst.AnimState:SetBuild("boat_grass_item")

    inst.deploy_product = "boat_grass"

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst = common_item_fn_pst(inst)
    inst.components.deployable:SetDeploySpacing(DEPLOYSPACING.PLACER_DEFAULT)

    return inst
end

local function ancient_ondeploy(...)
-- ★★ ancient_ondeploy：覆盖共用的 ondeploy（第 1483 行）。
-- 第 1542 行 Hide 掉容器，第 1543 行 0.5 秒后手动调 boat._container.OnPlaced。
-- ★ 这与 treasurechest.lua 第 750 行「This is called manually in boat.lua」互为镜像 ——
-- 本文件调那个预制体的钩子，那个预制体的注释反过来指向这里。
-- ⇒ ⚠️ 【架构债】跨文件的双向手工调用，没有任何静态检查能发现对方被删。
-- 【移植建议】改用 PushEvent 让双方各自监听，不要手工调对方的回调。
    local boat = ondeploy(...)

    boat._container:Hide()
    boat._container:DoTaskInTime(.5, boat._container.OnPlaced)
end

local function ancient_item_fn()
    local inst = CreateEntity()

    inst = common_item_fn_pre(inst)

    inst.deploy_product = "boat_ancient"

    inst.AnimState:SetBank("seafarer_boat")
    inst.AnimState:SetBuild("boat_ancient_kit")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst = common_item_fn_pst(inst)

    inst.components.deployable.ondeploy = ancient_ondeploy

    return inst
end

-- COLLISIONS
local function boat_player_collision_fn()
-- ★ 碰撞体预制体就是「模板函数 + 固定半径」的组合：
-- 同一套 build_boat_collision_mesh 代码，5 种船各调一次，得到 10 个碰撞体实体。
-- ⇒ 【可移植模式】模板函数 + 参数 = 廉价派生。比复制粘贴 10 份碰撞代码好得多。
    return boat_player_collision_template(TUNING.BOAT.RADIUS)
end

local function boat_item_collision_fn()
    return boat_item_collision_template(TUNING.BOAT.RADIUS)
end

-- Grass boat collisions
local function boat_grass_player_collision_fn()
    return boat_player_collision_template(TUNING.BOAT.GRASS_BOAT.RADIUS)
end

local function boat_grass_item_collision_fn()
    return boat_item_collision_template(TUNING.BOAT.GRASS_BOAT.RADIUS)
end

--
local function boat_ice_player_collision_fn()
    return boat_player_collision_template(TUNING.OCEAN_ICE_RADIUS)
end

local function boat_ice_item_collision_fn()
    return boat_item_collision_template(TUNING.OCEAN_ICE_RADIUS)
end

local function boat_otterden_player_collision_fn()
    return boat_player_collision_template(TUNING.BOAT.OTTERDEN_BOAT.RADIUS)
end

local function boat_otterden_item_collision_fn()
    return boat_item_collision_template(TUNING.BOAT.OTTERDEN_BOAT.RADIUS)
end

-- Placer post init
local function _set_placer_layer(inst)
	inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
	inst.AnimState:SetSortOrder(2)
	inst.AnimState:SetFinalOffset(7)
end

local function _check_placer_offset(inst, boat_radius)
-- ★ _check_placer_offset：让放置预览的偏移量不超过船半径 + 跳跃距离。
-- 第 1613 行原注释直接引用 CLIENT_CanDeployBoat（第 1439 行）—— ★ 跨函数的一致性约束。
-- min 上限保证「预览显示的位置」一定在「实际可放置的范围内」。
-- ⇒ 【可移植模式】UI 预览与合法性判定必须共享同一套边界，否则会出现「看着能放却放不下」。
	local inventory = ThePlayer and ThePlayer.replica.inventory
	if inventory and inventory:IsFloaterHeld() then
		local hop_range = TUNING.FLOATING_HOP_DISTANCE_PLATFORM - 0.01 --see CLIENT_CanDeployBoat
		local offset_range = hop_range - 0.01 --make sure placer stays within valid range of CLIENT_CanDeployBoat
		inst.components.placer.offset = math.min(inst.components.placer.offset, boat_radius + offset_range)
	end
end

local function wood_placer_postinit(inst)
-- wood_placer_postinit：placer 的 postinit 钩子，由 MakePlacer（第 1643 行最后两个参数）调用。
-- ★ MakePlacer 支持 postinit_fn 钩子（prefabutil.lua 第 57-59 行），
-- 这是 placer 的「变体机制」—— 本文件三个 placer 各自传不同的 postinit（第 1619、1625、1632 行）。
	_set_placer_layer(inst)
	_check_placer_offset(inst, TUNING.BOAT.RADIUS)
	ControllerPlacer_Boat_SpotFinder(inst, TUNING.BOAT.RADIUS)
end

local function ancient_placer_postinit(inst)
    inst.AnimState:SetScale(ANCIENT_BOAT_SCALE, ANCIENT_BOAT_SCALE)
	_set_placer_layer(inst)
	_check_placer_offset(inst, TUNING.BOAT.ANCIENT_BOAT.RADIUS)
	ControllerPlacer_Boat_SpotFinder(inst, TUNING.BOAT.ANCIENT_BOAT.RADIUS)
end

local function grass_placer_postinit(inst)
	_set_placer_layer(inst)
	_check_placer_offset(inst, TUNING.BOAT.GRASS_BOAT.RADIUS)
	ControllerPlacer_Boat_SpotFinder(inst, TUNING.BOAT.GRASS_BOAT.RADIUS)
end

--
return Prefab("boat", wood_fn, wood_assets, prefabs),
-- ★★★ return —— 23 个预制体，四个族群：
--
-- 【族群一：木船】boat / boat_player_collision / boat_item_collision /
--            boat_item / boat_item_placer
-- 【族群二：海盗船】boat_pirate
-- 【族群三：远古船】boat_ancient / boat_ancient_item / boat_ancient_item_placer
-- 【族群四：海獭巢】boat_otterden + 两个碰撞体
-- 【族群五：草船】boat_grass + 两个碰撞体 + boat_grass_item + boat_grass_item_placer
-- 【族群六：冰面】boat_ice / boat_ice_crabking / 两个碰撞体 / deploy_blocker
--
-- 【★ 观察：碰撞体为何要独立注册】
-- 船本体不 SpawnPrefab 碰撞体，而是把 prefab 名挂在组件字段上（第 528 行 item_collision_prefab、
-- 第 770 行 player_collision_prefab），运行时再 SpawnPrefab。
-- ⇒ 这样同一个「碰撞体工厂」可以服务 5 种半径不同的船，无需为每种船复制碰撞代码。
-- ⇒ 【移植要点】「动态创建 + 名字注入」是本文件应对「一个形状、多种尺寸」的核心手法。
--
-- 【⚠️ 读 return 时的常见误解】
-- 这些名字不是「23 个互不相干的实体」，而是「一族共享骨架的实例」。
-- 理解 DST 预制体层，必须把 return 读成「一个注册表」而非「一堆定义」。
       Prefab("boat_player_collision", boat_player_collision_fn),
-- ★ Prefab("boat_player_collision", boat_player_collision_fn) 的第 3、4 参数省略。
-- Prefab 的签名是 (name, fn, assets, deps)，后两个在 prefabs.lua 里有 `or {}` 兜底（第 10-11 行）。
-- ⇒ 省略是安全的，与本文件其他调用等价。
       Prefab("boat_item_collision", boat_item_collision_fn),
       Prefab("boat_item", item_fn, item_assets, item_prefabs),
       MakePlacer("boat_item_placer", "boat_01", "boat_test", "idle_full", true, false, false, nil, nil, nil, wood_placer_postinit, 6),
-- ★ MakePlacer 的 12 个位置参数里，最后两个是 postinit_fn 与 offset。
-- 第 1643 行 offset=6、第 1666 行 offset=4.5 —— 不同船的预览偏移不同。
-- ⚠️ 12 个位置参数：★ 这是本文件最脆弱的调用形式，改动 prefabutil.lua 的参数顺序
-- 会静默地让所有 placer 行为错乱而无任何编译期检查。
-- 【移植建议】MakePlacer 应该收一个 options table。

       Prefab("boat_pirate", pirate_fn, pirate_assets, prefabs),

       Prefab("boat_ancient", ancient_fn, ancient_assets, ancient_prefabs),
       Prefab("boat_ancient_item", ancient_item_fn, ancient_item_assets, ancient_item_prefabs),
       MakePlacer("boat_ancient_item_placer", "boat_yotd", "boat_ancient", "idle_full", true, false, false, nil, nil, nil, ancient_placer_postinit, 6),

       Prefab("boat_otterden", otterden_fn, otterden_assets, otterden_prefabs),
       Prefab("boat_otterden_player_collision", boat_otterden_player_collision_fn),
       Prefab("boat_otterden_item_collision", boat_otterden_item_collision_fn),

       Prefab("boat_grass", grass_fn, grass_assets, grass_prefabs),
       Prefab("boat_grass_player_collision", boat_grass_player_collision_fn),
       Prefab("boat_grass_item_collision", boat_grass_item_collision_fn),

       Prefab("boat_ice", ice_fn, ice_assets, ice_prefabs),
       Prefab("boat_ice_crabking", ice_crabking_fn, ice_assets, ice_prefabs),
-- boat_ice_crabking：★ 唯一「同文件内派生」的预制体（见第 1408 行）。
-- 它与 boat_ice 共用 ice_assets 与 ice_prefabs（第 1659、1660 行）——
-- ⇒ ★ 连资源清单都是共享的，这正是「派生变体」的最大收益。
       Prefab("boat_ice_player_collision", boat_ice_player_collision_fn),
       Prefab("boat_ice_item_collision", boat_ice_item_collision_fn),
       Prefab("boat_ice_deploy_blocker", ice_floe_deploy_blocker_fn),

       Prefab("boat_grass_item", grass_item_fn, grass_item_assets, grass_item_prefabs),
       MakePlacer("boat_grass_item_placer", "boat_grass", "boat_grass", "idle_full", true, false, false, 0.85, nil, nil, grass_placer_postinit, 4.5)