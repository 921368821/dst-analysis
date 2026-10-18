// spec-playercontroller-p3.mjs —— 第 3 段：1300-2100 行
// 覆盖：DoControllerAttackButton 及其服务端对端、库存格子操作、相机旋转、
//       建造/部署放置、AOE 瞄准与蓄力、攻击目标筛选（ValidateAttackTarget/GetAttackTarget）、
//       拾取动作优先级链（GetPickupAction）

export const BEFORE = {
  1300: [
    "--============================================================",
    "-- 【第三段】1300-2100 行：攻击 / 库存格子 / 相机 / 放置 / AOE / 攻击目标筛选",
    "--============================================================",
  ],

  1281: [
    "--★★★ 【DoControllerAttackButton(target)】手柄扳机/X 攻击。target 通常为 nil。",
    "--   结构：",
    "--   ① 1282-1294 target==nil 且处于特殊状态时的三条早退路径",
    "--   ② 1296-1314 target 非 nil（连击重定向）时的校验",
    "--   ③ 1315-1354 无 target 时从 controller_attack_target 取，并判断「空气攻击」",
    "--   ④ 1356-1380 构造 ATTACK 动作并走标准三分支发送",
  ],

  1282: [
    "--   ★ 参数 target 由 3151 行传入（连击攻击时非 nil），其余调用点传 nil。",
  ],

  1283: [
    "--   ★ 1283 行的两个早退：AOE 瞄准中 / 坐在椅子上时攻击无效。",
    "--     理由：AOE 瞄准时按扳机会误放法术；椅子上（笼子/椅子的拟态攻击）攻击无效。",
  ],

  1285: [
    "--   ★★ IsOverrideAttack 的第三返回值体系（1981 行）：",
    "--     「攻击键被重定义为别的功能」——如温蒂的「 Abigail 出来」、",
    "--     猎犬的「扑咬」等。这里改为 PushEvent(\"attackbutton\") 让对应 prefab 接管。",
    "--   1286 行的 PushEventImmediate：★立即派发，不排队 ——",
    "--     攻击手感要求零延迟，这与普通 PushEvent 的排队语义不同。",
  ],

  1287: [
    "--   --Need to let server know NOW, wheter we have prediciton or not.",
    "--   → K 的原注释有拼写错误（wheter / prediciton），照录。",
    "--   ★「不管有没有预测能力都要立刻通知」——因为 overrideattack 可能改变玩家位置",
    "--     （如韦布斯特的口哨召唤），服务器必须马上知道。",
  ],

  1296: [
    "--   ★ 1297 行的注释点明了防刷机制：连击重定向时若 remote_controls 还在冷却，",
    "--     直接 return —— 避免「持续按住扳机」在每次重定向时都发一次 RPC。",
  ],

  1302: [
    "--   ★ 双端判定的 attack 状态：客户端有 sg 看状态标签，否则看 inst:HasTag。",
    "--     与 IsBusy:769-777 同样的双端不对称设计。",
  ],

  1310: [
    "--   ★★ 攻击前的三重合法性校验（客户端提前拦，服务端还会再查一遍）：",
    "--     ① LocomotorCanAttack(nil, target)：locomotor 能否边移动边攻击这个目标",
    "--        参见 locomotor.lua 的 LocomotorCanAttack（如正在挖矿时不能攻击）",
    "--     ② IsEntityDead(target, true)：目标已死",
    "--     ③ CanEntitySeeTarget：视线判定（模组可改，如-visible-distance）",
    "--   ⇒ 即便如此，服务端 OnRemoteControllerAttackButton:1400 仍会重查 CanTarget。",
  ],

  1316: [
    "--   无显式 target → 取手柄当前选中的攻击目标 controller_attack_target。",
  ],

  1318: [
    "--   ★ 1318-1326：目标已经是当前战斗目标 → 只发「按钮按下」通知，不重复攻击。",
    "--     这是「按住扳机不重复攻击同一目标」的实现，靠 1322 行的 nil 检查去重 RPC。",
  ],

  1327: [
    "--   CanTarget 为假 → 目标作废（掉到 nil）。",
    "--     参见 combat_replica.lua:311 —— 判据是目标是否已死/是否已归属别人。",
  ],

  1331: [
    "--   --V2C: controller attacks still happen even with no valid target",
    "--   ★ 1332 行的 target==nil 块：即使没有目标也允许「挥空」。",
    "--     为什么要挥空：攻击是「播放动画 + 判定命中」，玩家按了就得有反应，",
    "--     否则远程客户端的本地动画不会播，且服务端状态与客户端不一致。",
  ],

  1334: [
    "--★ no_air_attack 的五种例外（这个表就是「什么时候不能空挥」的完整清单）：",
    "--     ① directwalking：正在用摇杆直接行走（手会忙）",
    "--     ② HasAnyTag(\"playerghost\",\"weregoose\")：幽灵/沃古斯形态",
    "--     ③ classified.inmightygym > 0：练力场（Infinite Gym）里",
    "--     ④ GetGameModeProperty(\"no_air_attack\")：游戏模式级开关",
    "--     ⑤ inventory:IsHeavyLifting() or IsFloaterHeld()：举着重物/漂浮物",
    "--   ⇒ 注意前三项是「状态」，后两项是「装备」——它们都会用不同的 tag/字段表达。",
  ],

  1356: [
    "--   ★ 构造 ATTACK 的 BufferedAction。1357 行没有传 distance，",
    "--     说明攻击距离由 actions.lua 的 ATTACK.rangecheckfn 决定（默认 3）。",
  ],

  1361: [
    "--   ★ 1362 行 `self.remote_controls[CONTROL_CONTROLLER_ATTACK] = BUTTON_REPEAT_COOLDOWN`",
    "--     与 1368 行的差异：non_preview_cb 路径设 0（立即可再发），",
    "--     preview 路径设 0.5。",
    "--   ⚠ 疑似缺陷（不一致）：non_preview_cb 意味着「无 locomotor，无法缓冲」，",
    "--     动作会立刻执行，无需防刷（也确实不会刷）。但 0 与 0.5 的语义不一致",
    "--     会让 IsControlPressed 在两种客户端上返回不同的「按下中」时长。",
    "--     推理依据：对比 1362 行与 1368 行，以及 1975 行 DoAttackButton 路径",
    "--       统一用 0（本文件没有对应的 BUTTON_REPEAT_COOLDOWN 用法）。",
  ],

  1371: [
    "--   ★★ preview_cb 的 1374 行与 1362 行对比：",
    "--     1374 行 `not isreleased and BUTTON_REPEAT_COOLDOWN or nil` —— 抬起时置 nil。",
    "--   ⇒ 所以 BUTTON_REPEAT_COOLDOWN 实际上是「攻击按钮被视作按下的时长」，",
    "--     不是「重发间隔」。它在 1965 行（键盘路径）也是同样用法。",
  ],

  1383: [
    "--【OnRemoteControllerAttackButton(target, isreleased, noforce)】服务端对端。",
    "--   ★ 与 944 行的 ControllerActionButton 不同，本函数**不重算动作**，",
    "--     而是把攻击塞进 self.attack_buffer 交给 OnUpdate 执行。",
    "--   为什么：攻击需要 sg 的 attack 状态配合，OnControl 时刻状态可能还没切。",
  ],

  1388: [
    "--   target == true：客户端只发了「按钮按下」。",
    "--   1390 行注释掉的重复赋值：1387 行已经设过了。",
  ],

  1394: [
    "--   ★ not noforce 分支：客户端没按强制攻击键 → 允许重新选目标。",
    "--   noforce 分支（1405-1415）：客户端已按强制 → 目标不可重选（1400 行跳过）。",
    "--   ★ noforce=true 时若 CanTarget 为假，构造一个 target=nil 的 ATTACK 并",
    "--     设置 overridedest = self.inst（1413 行）——",
    "--     这是「强制攻击时打空气」的动作，动作执行体据此决定特效落点。",
  ],

  1395: [
    "--   ★★ \"abouttoattack\" vs \"attack\" 的双标签判定：",
    "--     1817/1940/3114 行有完全相同的三元表达式。",
    "--     → remote_authority 且正在预测时查 \"abouttoattack\"（发起攻击的过渡态），",
    "--       否则查 \"attack\"（真正在打）。",
    "--   ⇒ 为什么可空？因为 stategraph 可以自定义标签集。",
    "--     但这意味着**任何自定义状态图若不用 attack 标签，攻击连击就会失效**。",
    "--     ⚠ 疑似缺陷（隐式契约）：没有 sg 时（第 1820/1806 行的 elseif 分支）",
    "--       只查 HasTag(\"attack\")，与有 sg 时的判定不对称。",
    "--     推理依据：1816-1822 行的 if/elseif 结构。",
  ],

  1396: [
    "--   ★★ chainattack_cb = function() ... end —— **连击攻击的延迟回调**。",
    "--   场景：玩家在攻击动画（attack 状态）中再次按下扳机，",
    "--     此时不能立即开始新攻击（会打断当前动画），",
    "--     于是把「再打一次」的请求**存进状态图的 statemem**，",
    "--     由 3110-3120 行的 OnUpdate 在攻击结束前触发。",
    "--   ⚠ 疑似缺陷（参数丢失）：1397 行 `self:OnRemoteControllerAttackButton(target)`",
    "--     **丢掉了 isreleased 与 noforce**。若客户端在发起连击的同时松开了扳机，",
    "--     服务器执行时 isreleased=nil → 1416 行不清理 remote_controls，",
    "--     服务器会认为扳机还按着，直到下一个 RPC。",
    "--     推理依据：1942 行的 chainattack_cb 同样丢参（丢 isleftmouse/isreleased），",
    "--       说明这是复制粘贴的产物而非有意为之。",
    "--     缓解：ControlC 抬起会发 StopControl（546 行）独立于 isreleased，",
    "--       所以最终状态仍会被清理，但中间会有一帧的「按住」状态。",
  ],

  1400: [
    "--   ★ CanTarget 失败则 target=nil → 「打空气」，不是丢弃请求。",
  ],

  1422: [
    "--【DoControllerDropItemFromInvTile】手柄在库存格上「丢弃」。",
    "--   1424-1426 行的双条件：",
    "--     未锁定在格子里（IsLockedInSlot）→ 可丢",
    "--     或者 single（长按一次一个）且物品可堆叠 → 可丢",
    "--   ★ 单（single）= 移出 1 个；全 = 移出整堆。",
  ],

  1436: [
    "--【DoControllerUseItemOnSelfFromInvTile】在库存格上「对自己用」。",
    "--   1438-1440 行：设置了**长按重复的三件套**：",
    "--     actionholdtime / lastheldaction / actionrepeatfunction",
    "--   ★★★ 这三个字段是长按重复机制的全部。2588 行 RepeatHeldAction 每帧调用",
    "--     actionrepeatfunction；2609/2619 行设置 no_predict_fastforward。",
    "--   ⇒ 1443 行 `if item == nil then self.actionrepeatfunction = nil return end`：",
    "--     长按重发时 item 参数为 nil（104 行没有参数），必须自己取光标物品。",
  ],

  1445: [
    "--   ★ 可部署物品在鼠标模式下进入放置模式（而不是直接使用）。",
    "--     这是「手持火把右键出现放置预览」的实现。",
    "--   1447 行的 IsGrandOwner 校验：只能部署自己的东西。",
  ],

  1454: [
    "--【DoControllerUseItemOnSceneFromInvTile】在库存格上「对世界用」。",
    "--   ★ 1464-1468 行是个特例：不是自己背里的、且未锁定 → 从容器里**取出**。",
    "--     这是手柄操作的「一键拿取」：从马厩/冰箱里直接把物品拿到手上，",
    "--     免去「先按方向键选中容器、再打开、再选物品」。",
    "--   1465 行 GetCursorInventorySlotAndContainer 拿的是「光标所在的槽位与容器」，",
    "--     这是 controller-only 的 API（788 行，鼠标模式下返回 nil）。",
  ],

  1474: [
    "--【RotLeft / RotRight】相机 45° 步进旋转。",
    "--   1479 行 `local rotamount = 45 ---90-- ...`：",
    "--     英文原注释留下了曾经的方案：洞穴里 22.5°，后来改回统一 45°。",
    "--   ★ 步进而非连续旋转：手柄的「视角吸附」是 DST 手柄体验的核心之一，",
    "--     与鼠标的自由旋转共存靠的就是这个 45° 网格。",
  ],

  1475: [
    "--   --V2C: exception for drone cam: zoom disabled, but rotate allowed",
    "--   → 使用无人机（韦德沃克斯的 Drone）时相机不可控，但允许旋转。",
    "--     这个例外同时出现在 4441 行 DoCameraControl。",
  ],

  1481: [
    "--   ★ 带速度的旋转（手柄摇杆）：SetContinuousHeadingTarget(target, -speed)。",
    "--   1482 行的取整公式 `(math.ceil((heading - speed)/rotamount) - 1) * rotamount`：",
    "--     向下取到 45° 网格，减去一个格——这是「转一整格」而非「转到最近格」的手感。",
  ],

  1487: [
    "--   ★ 暂停 + 地图打开时用 Snap()：地图内旋转要立刻生效（不能有插值）。",
  ],

  1512: [
    "--【GetHoverTextOverride】建造模式下鼠标悬停的提示文字。",
    "--   1515 行的优先级：recipe 自定义函数 > 按 product/name 查字符串 > 「这里」。",
    "--   ★ 1535 行的 `canmouse.data_item` 不存在时返回 nil（不覆盖原提示）。",
  ],

  1522: [
    "--【CancelPlacement(cache)】★ cache 参数是「保留蓝图以便重建」。",
    "--   ★ 为什么需要 cache：HUD 打开/关闭会触发 2709 行的 CancelPlacement(true)，",
    "--     若清掉 recipe，玩家关一下合成菜单就得重新选蓝图。",
    "--   1527-1528 行 K 的注释说明了 V2C 的补丁：",
    "--     \"Leave cache alone if recipe is already nil / This can get called",
    "--      repeatedly when controls are disabled\"",
    "--   ⚠ 副作用：2806-2811 行 OnUpdate 会在 IsEnabled 后自动重建缓存的 placer，",
    "--     这就是「菜单打开时蓝图仍显示」的机制。",
  ],

  1539: [
    "--【CancelDeployPlacement】取消部署放置。",
    "--   1540 行 `self.deploy_mode = not TheInput:ControllerAttached()`：",
    "--     ★ 取消时重置为「鼠标模式默认有 deploy_mode」，所以鼠标玩家每次取消后",
    "--       仍可用右键进入放置。手柄玩家则通过 TOGGLE_DEPLOY_MODE 切换（5552 行）。",
  ],

  1547: [
    "--【StartBuildPlacementMode(recipe, skin)】进入建造模式。",
    "--   ★ 1561 行 testfn：把「能不能在这建」的判定从 placer 组件改为",
    "--     replica.builder:CanBuildAtPoint —— 因为建造合法性（含材料）只有 builder 知道。",
    "--   ★ 这是一个**客户端自定义判定函数**注入服务端组件的范式，",
    "--     它让 placer 无需认识 builder。",
  ],

  1567: [
    "--【IsTwinStickAiming】双摇杆瞄准（用手柄右摇杆瞄准射击）。",
  ],

  1571: [
    "--【GetAOETargetingPos】当前 AOE 瞄准点的世界坐标（来自准星）。",
  ],

  1575: [
    "--【IsAOETargeting】★ 注意它**只看准星**，不看手持物。",
    "--   对比 1579 行的 HasAOETargeting：后者查「当前手持物是否支持 AOE 瞄准」。",
    "--   ⇒ 两个函数名的区别是「**正在瞄**」与「**能瞄**」。",
  ],

  1579: [
    "--【HasAOETargeting】手持物是否具备 AOE 瞄准能力。",
    "--   ★ 1584/1594 行的 allowriding：允许骑乘时使用的道具（如韦德的自行车加速器）。",
  ],

  1597: [
    "--   ⚠ 疑似缺陷（缓存变量语义不一致）：",
    "--     1597 行 `if isriding == nil then` 试图「若之前没算过 riding 就补算」，",
    "--     但 1588/1599 行都把 isriding 赋成了 **布尔值**（isriding ~= nil and ...），",
    "--     所以 isriding 永远不可能是 nil（除非从没进过任何一个分支）。",
    "--   推理依据：1582 行 local isriding 初值为 nil；",
    "--     1587-1588 与 1598-1599 行都是 `isriding = X ~= nil and X:IsRiding()`，",
    "--     结果必然是 true/false，永不为 nil。",
    "--   ⇒ 后果：若手持物**只有** aoecharging 而无 aoetargeting，",
    "--     isriding 保持 nil，1597 行会补算 —— 恰好是正确的；",
    "--     若两个都有，1588 行算出的值被 1599 行跳过 —— 也正确。",
    "--     所以当前行为无误，但 1597 行的判据是**巧合成立**而非显式设计。",
    "--     重构建议：改用 `local isriding_cached = false` 之类的显式标志。",
  ],

  1609: [
    "--【TryAOETargeting】开始 AOE 瞄准（魔杖类）。返回是否成功。",
    "--   1612-1617 行：不允许骑乘时，若在骑乘则拒绝。",
    "--   ★ 返回 boolean 的意义：1109 行用它做短路（Try 或 Try 的语义互斥）。",
  ],

  1624: [
    "--【StartAOETargetingUsing(item)】★ 由 prefab 直接调用（不走 OnControl）。",
    "--   4 个外部调用点：ghostcommand_defs / waxwelljournal / willow_ember / winona_remote。",
    "--   ★ 1626-1630 行的四连清理：这是「按一个外部事件进入瞄准态」的标准收尾，",
    "--     与 1075-1081 行（Y 键的取消链）对称。",
  ],

  1635: [
    "--【GetActiveSpellBook】当前准星是否属于一本法术书。",
    "--   ⚠ 1636 行没有 nil 检查 self.reticule：若 reticule 为 nil 会崩。",
    "--   推理依据：`self.reticule.inst.components.spellbook ~= nil` 首字段即索引。",
    "--     但所有调用点（836/4736/5389）都在 IsAOETargeting 为真之后，",
    "--     而 IsAOETargeting 保证了 reticule ~= nil，故实际安全。",
    "--     隐式契约：调用前必须 reticule ~= nil。",
  ],

  1645: [
    "--★ _CalcAOEChargingStartingRotation：算蓄力起始朝向。",
    "--   1646-1647 行的英文注释说明了返回 nil 的两种情况：",
    "--     \"handler should always exist when we get here\"（正常路径）",
    "--     \"nil return only when mouse position unavailable, should not be",
    "--      possible normally\"（鼠标位置拿不到，理论上不可能）",
  ],

  1653: [
    "--   ★ 手柄分支：把方向向量转成角度。",
    "--     math.atan2(-dir.z, dir.x) * RADIANS —— 注意 **-dir.z**。",
    "--     参见文件头 480 行的说明：Transform 的 Z 轴与数学 Z 轴相反。",
    "--     这行与 4360 行的 -math.atan2(dir.z, dir.x) / DEGREES 是同一约定的两个写法。",
  ],

  1659: [
    "--★★ 【TryAOECharging(force_rotation, iscontroller)】蓄力类道具（弹弓/ pneumatic）。",
    "--   ★★ 三个调用点传入的 force_rotation 语义完全不同：",
    "--     · 1109 行 TryAOECharging(nil, true) —— force_rotation=nil（客户端首次）",
    "--     · 5021 行 TryAOECharging(nil, false) —— 鼠标右键版",
    "--     · 1671 行 TryAOECharging(rotation, iscontroller) —— 服务端从 RPC 收到 rotation",
    "--   ⇒ 1669 行 `if force_rotation then` 区分的就是「服务端已告知角度」还是「自己算」。",
  ],

  1671: [
    "--   --server received remote rpc",
    "--   ★ 客户端已经在 1686-1688 行把 rotation 发了过来，服务端直接复用。",
    "--     服务端**不重算**角度 —— 因为蓄力方向是玩家当时看的方向，重算会漂。",
  ],

  1674: [
    "--   --server or prediction client",
    "--   ★ 预测客户端在**本地**就 SetRotation + GoToState 先行表演（1677-1678 行），",
    "--     动画立即播，服务器随后跟上。这是「动画预测」而非「位置预测」。",
  ],

  1680: [
    "--   --non-prediction client",
    "--   --We still need to know our desired starting angle for the RPC, /",
    "--   --but we can't set transform rotation on non-prediction clients",
    "--   ★★ 无 locomotor 的客户端**不能**改 Transform（会与服务端冲突），",
    "--     但仍要算出角度发 RPC。所以 1686 行的条件不含 sg 判断。",
  ],

  1686: [
    "--   ★ startflag：1 = 鼠标右键，2 = 手柄 Y 键。",
    "--     客户端用它反推「服务器该把哪个 remote_controls 置 0」。",
  ],

  1695: [
    "--【OnRemoteAOECharging(rotation, startflag)】蓄力的服务端对端。",
    "--   1697 行的 if startflag：非零 = 开始蓄力；nil/0 = **持续更新角度**。",
    "--   ★ 这是一个「start + 后续 update」共用一条 RPC 的省流设计：",
    "--     1707 行 RemoteAOEChargingDir 每帧/每次转方向都发一次（只带 rotation）。",
  ],

  1711: [
    "--【EchoReticuleAt(x,y,z)】在指定位置生成一个一次性准星涟漪实体。",
    "--   1718 行的 `reticule:DoTaskInTime(1, reticule.Remove)`：",
    "--     没有 Flash 方法的预制体，1 秒后自行移除。这是「特效实体的生命周期管理」。",
  ],

  1723: [
    "--【RefreshReticule(item)】重建准星。 Activate(326) / OnEquip(232) /",
    "--   ToggleController(399) / 8 处外部调用。",
    "--   ★ 与 OnEquip 的 reticule 逻辑重复（232-244 与 1725-1734 几乎一样），",
    "--     但 RefreshReticule 是通用入口，接受可选 item 参数。",
  ],

  1737: [
    "--★★ 【TargetIsHostile】敌对判定三级回退：",
    "--     ① 实体自己有 HostileTest（生物侧优先）",
    "--     ② 目标有 HostileToPlayerTest（如猪人村民对村民）",
    "--     ③ 兜底查 target 的 hostile 标签",
    "--   ★ 顺序不可交换：①解决「我怎么看它」，②解决「它怎么看我」，",
    "--     ③是纯标签的最终兜底。第三方模组只需实现 ① 或 ② 之一即可。",
  ],

  1747: [
    "--★★★ 【ValidateAttackTarget】★ 攻击目标合法性四道闸（本文件最重要的过滤器）。",
    "--   签名 (combat, target, force_attack, x, z, has_weapon, reach)",
    "--   ⚠ 注意 has_weapon 参数在函数体里**完全没被使用**（grep 确认）。",
    "--     ⇒ 疑似缺陷（死参数）：1830/1835/1846/1858 四处认真计算并传入 has_weapon，",
    "--       但 ValidateAttackTarget 从头到尾没读它。推测是早期版本用武器类型",
    "--       区分「武器攻击 / 赤手攻击」的射程，现已改由 combat:GetAttackRangeWithWeapon",
    "--       统一处理，但参数没删。",
    "--     推理依据：1747-1786 行内 has_weapon 出现 0 次（仅在形参里）。",
  ],

  1748: [
    "--   闸①：combat:CanTarget（未死、未被别人锁定）+ 非 stealth 潜行。",
  ],

  1753: [
    "--   ★★ targetcombat 为 nil 的实体（光/扑灭器）**跳过敌对判定**，直接进距离检查。",
    "--     注释：\"no combat if light/extinguish target\"",
    "--     设计取舍：火把/扑灭器能点任何东西，包括玩家自己（这是某些角色的技能）。",
  ],

  1755: [
    "--   闸②：友军永不误伤（除非 force_attack 也过不了这一关？实际是直接 return false）。",
    "--   ⚠ 注意：IsAlly 为真时**无条件** return false，force_attack 也不能强制攻击友军。",
    "--     这与「强制攻击可以打队友的随从」（1769-1777）的处理不一致——",
    "--     后者只针对 follower。所以「强制攻击友方随从」是允许的，",
    "--     「强制攻击玩家队友」不允许。",
  ],

  1757: [
    "--   ★★ 闸③（非 force 且非最近目标时）：必须「对方也把我当敌人」或「对方是敌对生物」。",
    "--   1759 行 shadowsubmissive（暗影驯服者）：",
    "--     \"shadowsubmissive needs to ignore GetTarget() test, since they have you",
    "--      targeted even when not hostile\"",
    "--     → 已驯服的暗影生物虽然 GetTarget() 指向玩家，但不算敌对，不能再打。",
    "--     这是为了避免「驯服后被误杀」。",
  ],

  1763: [
    "--   ★ targetcombat:GetTarget() ~= inst：目标正在被别人打 → 允许玩家插队。",
    "--     注释：\"must use force attack non-hostile creatures\"",
    "--     逻辑：非敌对生物（如猪）只要在跟你打架，就可以打；站着不动的猪不行。",
  ],

  1768: [
    "--   ★ 1769-1777 行：目标若是「某个玩家的随从」，且它主人正在跟你打，",
    "--     那你也打它；否则不能打（防止误伤主人的宠物）。",
    "--     ⚠ 1763 行的 `targetcombat:GetTarget() ~= inst` 与这里形成**双重条件**：",
    "--       一个随从只有在「目标已指向我」或「主人已指向我」时才可被打。",
    "--     推理依据：1774 行 leader.replica.combat:GetTarget() ~= inst 直接 return false。",
  ],

  1784: [
    "--   ★★ 距离判定：`reach + target:GetPhysicsRadius(0)` ——",
    "--     ★ 这是「点边缘即可命中」的实现：攻击范围是**边缘到边缘**，不是中心距。",
    "--     所以大体型目标（牛 2.5 格）在同样 attackrange 下更容易被打中。",
    "--     注释：\"light/extinguish targets may not have physics\" ——",
    "--       没有物理实体的目标半径为 0，退化为中心距判定。",
  ],

  1788: [
    "--★★ TheSim:RegisterFindTags —— ★ 向引擎注册一个**空间查询索引**。",
    "--   { \"_combat\" }：只匹配带 _combat 标签的实体（entityreplica.lua 里自动加）。",
    "--   { \"INLIMBO\" }：排除在「limbo 暂停」中的实体（存档中暂存的实体）。",
    "--   ⇒ 这个注册是**模块加载时**执行的全局副作用，只做一次。",
    "--   ★ 为什么用 _combat 标签而不是遍历所有实体：空间查询是每帧多次的热路径。",
    "--   ⚠ 但注释说 \"Only include combat targets for auto-targetting, not",
    "--     light/extinguish\"（1850 行）—— 而 ValidateAttackTarget 里却要处理",
    "--     targetcombat == nil 的灯光目标。两者矛盾。",
    "--     推理依据：1850 行注释 vs 1753 行的灯光分支；",
    "--       REGISTERED_FIND_ATTACK_TARGET_TAGS 只查 _combat。",
    "--     可能的调和：灯光分支只在 force_target 路径（1846 行）生效。",
  ],

  1790: [
    "--★★ 【GetAttackTarget(force_attack, force_target, isretarget, use_remote_predict)】",
    "--   ★ 本函数被**双端**调用：",
    "--     客户端：1895 行 DoAttackButton 算目标 → 决定发哪个 code",
    "--     服务端：1945/1950 行 OnRemoteAttackButton 重算 → 校验客户端的 code",
    "--   ⇒ 这就是「意图编号校验」在攻击路径上的落点。",
  ],

  1791: [
    "--   ★ 1791-1795 行：幽灵/沃古斯形态/无限练力场里**不能自动索敌**。",
    "--     幽灵要主动 HAUNT，沃古斯攻击是技能，练力场里攻击无意义。",
  ],

  1798: [
    "--   ★ 举重物 / 举漂浮物 → 不能攻击（双手被占用）。",
    "--     与 1341-1343 行的 no_air_attack 判据一致。",
  ],

  1807: [
    "--   --Don't want to spam the attack button before the server actually starts",
    "--   the buffered action",
    "--   ★ 这是「按键去重」的第二道闸（第一道是 BUTTON_REPEAT_COOLDOWN 的 remote_controls）。",
    "--     1808 行 `(self.remote_controls[CONTROL_ATTACK] or 0) > 0` 在客户端才生效。",
  ],

  1812: [
    "--   ★ isretarget && force_target 且可见 → 直接返回，不做任何重新搜索。",
    "--     连击攻击的目标保持（避免「打着打着换了目标」）。",
  ],

  1824: [
    "--★★ 【1826 行的 attackrange 扩张】`local rad = self.directwalking and attackrange",
    "--   or attackrange + 6` —— ★ 手柄/鼠标「直接行走」时缩到恰好 attackrange，",
    "--   「点地面走过去」（自动行走）时**放大 6 格**。",
    "--   为什么：自动行走时玩家不在瞄准，是「走过去打」，需要更宽的搜索半径；",
    "--     而直接行走是「边跑边打」，必须严格限制在攻击距离内。",
    "--   ⇒ 这是「交互范围判定」在攻击路径上的体现。",
    "--   ⚠ 注释 \"--\\\"not self.directwalking\\\" is autowalking\" 位置写反了：",
    "--     代码里 directwalking 为真时用小半径，注释却说「不是 directwalking 就是 autowalking」，",
    "--     描述的是 else 分支（+6）。注释本身没错但紧贴在小半径那一行，容易误读。",
  ],

  1829: [
    "--   --Beaver teeth counts as having a weapon",
    "--   ★ 海狸（Beaver）默认带武器。1830 行用 inst:HasTag 而非查装备。",
  ],

  1836: [
    "--   propweapon（长矛等投掷武器）：自动视为 force_attack。",
    "--   \"don't require pressing force_attack when using prop weapons\"",
    "--     ⇒ 长矛可以插地/点燃而不会误伤友军，因为自动 force。",
  ],

  1843: [
    "--   ★ reach = 自己半径 + 搜索半径 + 0.1。0.1 是浮点保护。",
  ],

  1849: [
    "--   --To deal with entity collision boxes we need to pad the radius.",
    "--   ★ 因为目标有体积，「中心距 ≤ R」会把「体型 2.5 的牛在 3.2 处」判为不可达。",
  ],

  1855: [
    "--   ★★ 1855-1856 行**变量复用**做「状态机式」处理：",
    "--     isretarget 原是入参（是否强制重定向），此处被复用为「是否找到最近目标」标志；",
    "--     force_target 原是入参（强制目标），此处被复用为「最近目标」。",
    "--   ⚠ 疑似缺陷（可读性/易错）：函数入参被覆写，退出时 1876 行返回的 force_target",
    "--     已经是「最近目标」而非入参。后续维护极易出错。",
    "--     推理依据：1856 行 force_target = nil 显式清空入参值；1876 行 return force_target。",
  ],

  1857: [
    "--   ★★★ 1857-1875 行是「最近目标优先，但最近目标有额外特权」的完整逻辑：",
    "--     ① ValidateAttackTarget 通过 + 可见 → 算「边缘距」（减物理半径）",
    "--     ② 若是 combat:IsRecentTarget（战斗系统认为的当前目标）",
    "--        且边缘距 < attackrange+0.1 → **立即返回**（绝不放弃）",
    "--        否则标记 isretarget = true（已见过最近目标但太远）",
    "--     ③ 常规比较 dist < nearest_dist → 更新最近目标",
    "--   ⇒ 效果：玩家点着一个敌人走来走去时，只要还在攻击范围内就永远打它，",
    "--     哪怕旁边有个更近的路人。",
  ],

  1872: [
    "--   elseif 分支：目标不合法但它是「最近目标」→ 只标记 isretarget，不更新最近目标。",
    "--   ★ 与 1862 行的区别：这里目标已经不可打了，只是为了防止 1862 的立即返回逻辑",
    "--     在目标离开后仍然生效。",
  ],

  1879: [
    "--★★ 【DoAttackButton(retarget, isleftmouse)】★ 攻击按钮的统一入口。",
    "--   三个调用点：638 行（OnControl 直接调）、2778 行（attack_buffer）、3149 行（连击）。",
    "--   ★ isleftmouse：区分「用鼠标左键打」和「用攻击键打」。",
    "--     原因：1953 行 `elseif not isleftmouse and self:IsOverrideAttack()` ——",
    "--     鼠标左键**不**触发 overrideattack，只有专用攻击键才触发。",
  ],

  1893: [
    "--   ★ control 的选择：isleftmouse ? CONTROL_PRIMARY : CONTROL_ATTACK。",
    "--     决定了 1899/1918 行往 remote_controls 里写哪个键。",
  ],

  1894: [
    "--   force_attack = TheInput:IsControlPressed(CONTROL_FORCE_ATTACK) ——",
    "--   ★ 注意读的是 TheInput 而非 IsControlPressed(511 行)：",
    "--     这是纯客户端路径，服务端从不读这一行（服务端走 OnRemoteAttackButton）。",
  ],

  1895: [
    "--   ★★ `retarget ~= self:GetCombatTarget()` 三个参数复用同一表达式：",
    "--     force_target = retarget（可能重定向的目标）",
    "--     isretarget  = 「目标是否和当前战斗目标不同」",
    "--     ⚠ GetCombatTarget（2643 行）读的是 sg.statemem.attacktarget，",
    "--       而 4603 行 DoAction 才写它 —— 存在一帧延迟。",
  ],

  1897: [
    "--   没有目标 → 只发「按钮按下」RPC（1898 行的注释解释了这个范式）。",
  ],

  1910: [
    "--   -- NOTES(JBK): Does not call locomotor component functions needed for",
    "--   pre_action_cb, manual call here.",
    "--   ★★ 这个 --V2C 注释在全文件出现 12 次，是无 locomotor 客户端的适配手法：",
    "--     locomotor:PreviewAction 内部会调 pre_action_cb（切换客户端状态标签），",
    "--     无 locomotor 的客户端没有 locomotor 组件，只能手工调。",
    "--   ⇒ 副作用：这两个分支的客户端**没有**客户端状态图，所以不能预测动作。",
  ],

  1917: [
    "--   ★ 1918 行的写法与 1899 行对称：先确保「按钮按下」已通知，再装 preview_cb。",
  ],

  1921: [
    "--   ★ 只有 CanLocomote 才能 PreviewAction —— 移动预测能力是动作预测的前提。",
    "--     为什么：PreviewAction 会让 locomotor 立刻开始移动到目标点，",
    "--       若此时状态图说「你在攻击中」，移动就是错的。",
  ],

  1932: [
    "--   --V2C: isreleased at the end because added a lot later",
    "--   ★★ 一条极有价值的注释：isreleased 排在最后是因为它是**后加的参数**。",
    "--   ⇒ 这暴露了 RPC 的兼容性约定：**只能在末尾追加可选参数**，",
    "--     否则老客户端的实参会错位。这是本文件多处参数顺序怪异的根因。",
  ],

  1933: [
    "--【OnRemoteAttackButton(target, force_attack, noforce, isleftmouse, isreleased)】",
    "--   ★★ 与 944 行的 ControllerActionButton 相比，本函数**不重算动作**，",
    "--     因为 ATTACK 是固定动作（不需要 picker），只需要重算「打谁」。",
    "--   ⇒ 重算逻辑在 1945/1950 行的 GetAttackTarget 调用里。",
  ],

  1939: [
    "--   ★ 1945 行 use_remote_predict = true：服务端重算时启用 abouttoattack 标签检查。",
    "--     （与 1817 行同一表达式，此处传 true。）",
  ],

  1941: [
    "--   ★ 与 1396 行同款的 chainattack_cb，★ 同样丢参：",
    "--     `self:OnRemoteAttackButton(target, force_attack)` 丢了 isleftmouse 与 isreleased。",
    "--   ⚠ 后果比 1397 行更严重：isleftmouse 丢失后，1937 行会把 control 算成",
    "--     CONTROL_ATTACK 而不是 CONTROL_PRIMARY → 1958 行清错键 →",
    "--     服务器的 remote_controls[CONTROL_PRIMARY] 永远不会被清。",
    "--   推理依据：1942 行参数表只到 force_attack；1937/1957 依赖 isleftmouse 与 isreleased。",
    "--     缓解：ControlC 抬起走独立的 StopControl RPC（546 行）。",
  ],

  1964: [
    "--【RemoteAttackButton】发 RPC 的薄封装。",
    "--   ★ 1965 行是本文件按键计时的**标准范式**：",
    "--     `self.remote_controls[键] = not isreleased and (target and COOLDOWN or 0) or nil`",
    "--     → 按下且有目标：设冷却时长；按下但无目标：设 0（可以连续发「打空气」）；",
    "--       松开：设 nil。",
    "--   ⇒ 1374/2302/2355 等处的变体都是这个式子的裁剪。",
  ],

  1968: [
    "--   ★ 1966-1972 三分支：noforce 只在「无 locomotor」且「有目标」时才置真。",
    "--     因为有 locomotor 的客户端走 preview，服务器重定向时不需要 noforce。",
  ],

  1975: [
    "--【SetIsOverrideAttack / IsOverrideAttack】★ 攻击键重映射的读写。",
    "--   ★★ 1981-1986 行的双端不对称值得注意：",
    "--     有 sg → 查状态标签 \"overrideattack\"（权威）",
    "--     无 sg → 查 classified.isoverrideattack（同步量）",
    "--   ⚠ 疑似缺陷（双端判定不一致）：客户端有 sg 时查标签，",
    "--     而写 classified 的是 1975 行的服务端函数。",
    "--     若某端有 sg 另一端没有，两端对同一个玩家会得出不同的答案。",
    "--     推理依据：1975 行的写入只发生在 ismastersim；",
    "--       1982 行 `if self.inst.sg then` 只检查本地是否有状态图。",
  ],

  1988: [
    "--★★ 四个 Validate* 谓词（1988-2003）：给 FindEntity 用的候选过滤器。",
    "--   ⚠ ValidateHaunt:1989 的 HasActionComponent(\"hauntable\") 是**组件检查**，",
    "--     而后面 ValidateBugNet/ValidateUnsaddler 只查死亡。",
    "--     三者风格不统一，说明是随需求逐步添加的。",
  ],

  2000: [
    "--   --V2C: revivablecorpse is on clients as well",
    "--   ★ 注释解释了为什么这个 Validate 可以双端跑：revivablecorpse 组件客户端也有。",
    "--     大多数组件只在服务端有（客户端会 nil 索引），这个是少数例外。",
  ],

  2005: [
    "--★★★ 【GetPickupAction(self, target, tool)】★★ **动作优先级链，全文件最长的 if-else 链**。",
    "--   2080 行之前的 65 行里排了 18 个分支。★ 顺序即优先级，不可随意调整。",
    "--   每一条都是「标签 → 动作」的映射，模组加标签即可扩展。",
    "--   两个调用点：2267 行（空间搜索后逐个试）与 2274 行（force_target 直试）。",
  ],

  2006: [
    "--   ① smolder（余烬）→ 扑灭。★ 放在最前是因为「正在烧」必须最先处理，",
    "--     否则后面任何分支都可能先匹配上「这是可采集物」。",
  ],

  2009: [
    "--   ★ LunarBuildup（月光堆积）需要 MINE 工具才能清除。",
    "--     这是 2024 新增的内容，插在 TOOLACTIONS 循环之前。",
  ],

  2012: [
    "--★ 【TOOLACTIONS 循环】14-17 行是与「工具 vs 可作业物」匹配的通用机制。",
    "--   标签约定：目标有 `CHOP_workable` + 工具刀有 `CHOP_tool` → ACTIONS.CHOP。",
    "--   参见 constants.lua:2183 TOOLACTIONS = { CHOP, DIG, HAMMER, MINE, NET, PLAY,",
    "--   UNSADDLE, SCYTHE } —— 8 个工具动作。",
    "--   ⚠ 循环体里的 break（2017 行）：★ 只匹配第一个标签就 break，",
    "--     意味着「同时有 CHOP_workable 和 DIG_workable 的目标」只会匹配 TOOLACTIONS",
    "--     遍历顺序里的第一个。pairs 遍历顺序不保证 → 行为不确定。",
    "--     推理依据：constants.lua 的 TOOLACTIONS 是**数组**，但 pairs 对数组的遍历",
    "--       顺序在 Lua 中不保证与索引顺序一致（虽然实践中通常是 1..n）。",
    "--     现实中双标签目标极少，故未暴露。",
  ],

  2022: [
    "--   ★★ 注意每个分支都带 `not target:HasTag(\"fire\")` 之类的否定条件：",
    "--     「着火的东西不能这么处理」。这是 DST 火灾机制的统一约定，",
    "--     也是为什么 2006 行的扑灭必须放最前面。",
  ],

  2028: [
    "--   ★ 2029 行：inactive（未激活的机器）需靠近 2.5 格才能激活 ——",
    "--     但只对 wall 生效（`(not target:HasTag(\"wall\") or IsNear(target, 2.5))`）。",
    "--   ⚠ 这个 2.5 是**独立的距离常量**，与 actions.lua 的 rangecheckfn 无关。",
  ],

  2032: [
    "--   ★★ 2032-2039 行的 PICKUP 分支有五重守卫：",
    "--     ① 是 inventoryitem",
    "--     ② CanBePickedUp(self.inst)（能否被**这个人**捡：所有者/堆叠上限）",
    "--     ③ 不是 heavy（太重）/ 不是可燃物（除非 lighter）/ 不是 catchable（要抓的）",
    "--     ④ 不是 spider（蜘蛛蛋要孵化）",
    "--     ⑤ ★ 有背包格子 或 目标可装备 → 否则捡不了（玩家是幽灵时）",
    "--   ⚠ 2034 行的 `(target:HasTag(\"fire\") and not target:HasTag(\"lighter\"))` ——",
    "--     着火的东西**可以**被 lighter 标签的物品处理（如火把本身带 fire+lighter）。",
  ],

  2036: [
    "--   ★★ HasItemSlots() 的两个用途之一：幽灵/无背包实体捡不了东西。",
    "--     这是 31-39 行猴补模式的实际消费点。",
  ],

  2040: [
    "--   ★ pickable（可采摘，如草）→ PICK。",
  ],

  2044: [
    "--   ★ 2045 行的 withered（枯萎）特例：已枯萎的也算「准备好采摘」。",
  ],

  2049: [
    "--   ★ 2049 行 `not self.inst:HasTag(\"mime\")`：哑谜演员不能照料作物",
    "--     （mime 的机制是「模仿 NPC」，照料作物会破坏伪装）。",
  ],

  2055: [
    "--   ★ inventoryitemholder_take → TAKEITEM（从盒子里拿东西）。",
    "--   ⚠ 这个标签是「容器专门给 TAKEITEM 动作用」的，不是通用容器标记。",
  ],

  2061: [
    "--   ★ 2061 行的守卫是 `self.inst.components.revivablecorpse ~= nil`：",
    "--     「只有本身可被复活的玩家才能复活别人」——对应 2213 行的注释",
    "--     \"only need to do this if i am also revivable\"。",
  ],

  2067: [
    "--【IsDoingOrWorking】★ 双端判据的第三种形态（除 IsBusy 外的第二个 busy）。",
    "--   sg 标签：doing / working；实体标签：doing / working。",
    "--   2071 行的 autopredict 分支：非预测客户端且带 autopredict 标签时只用 sg 标签。",
    "--   ⚠ 疑似缺陷（条件覆盖不全）：2071 行的 elseif 只在 `not ismastersim and",
    "--     HasTag(\"autopredict\")` 时生效，**主sim 分支没有对应逻辑**——",
    "--     主sim 走到 2075 行的兜底（sg 标签 + inst 标签都查）。",
    "--     这意味着主sim 会用更宽的判据（多查 inst:HasTag），与 autopredict 客户端",
    "--     的窄判据不一致。",
    "--     推理依据：2071 行含 not self.ismastersim，2075 行无此限制。",
  ],

  2081: [
    "--★ TARGET_EXCLUDE_TAGS：目标查询的通用排除表。",
    "--   FX（特效）/ NOCLICK（不可点）/ DECOR（装饰）/ INLIMBO（存档暂存）/ stealth。",
    "--   ⚠ 2081 行有 5 个标签但 3375 行的注释只说 \"FX\" 和 \"DECOR\"：",
    "--     \"\\\"FX\\\" and \\\"DECOR\\\" tag should never change, should be safe to skip",
    "--      that check\" —— 说明作者认为 FX/DECOR 是永久不变的，故在有效性检查里省掉。",
    "--     但 stealth 没被这样对待（1748 行单独检查），说明 stealth 会变。",
  ],

  2082: [
    "--   ★ 攻击索敌用**独立注册**（1788 行），因为排除表不同（这里排除了 stealth）。",
  ],

  2084: [
    "--   PICKUP / HAUNT 的排除表由 TARGET_EXCLUDE_TAGS 扩展而来（2086-2089 行）。",
    "--   ★ 注意 2087 行的 table.insert 是在**循环里直接改被遍历的表**的副本 ——",
    "--     PICKUP_TARGET_EXCLUDE_TAGS 是本地表，安全；但若有人复用 TARGET_EXCLUDE_TAGS",
    "--     本身就会死循环。当前是安全的（2084 行是新表）。",
  ],

  2091: [
    "--   六个 CATCHABLE_TAGS 常量表：catchable / pinned / corpse /",
    "--   gestaltcapturable / moonstormstaticcapturable。",
    "--   ★ 都是「FindEntity 的 musttags 参数」——FindEntity（simutil.lua:31）",
    "--     接受 musttags/canttags/mustoneoftags 三个标签过滤参数。",
  ],
};

export const AFTER = {};