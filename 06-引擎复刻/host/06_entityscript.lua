--[[
==============================================================================
 06_entityscript.lua —— EntityScript 契约补全（表驱动）

 真实引擎的 EntityScript 有 130+ 个方法（entityscript.lua，5377 行）。
宿主 01_core 只实现了控制流必需的那十几个，其余需要补齐。

 ★ 为什么单独一个文件
   batch 测试暴露出：30 个候选预制体里 28 个失败，
   失败原因高度集中在少数几个未实现的 EntityScript 方法上
   （SetDeploySmartRadius 一家就占 7 次）。
   表驱动一次补齐，比逐个撞错误高效得多。

 分层：
   1) 语义覆写 —— 返回值影响控制流的（如 IsNearPlayer）
   2) 泛化桩   —— 契约内但宿主无真实语义的
   3) 不透传   —— _G 元表兜底（真未知才记缺口）
==============================================================================
]]

local Core = require("host.01_core")

local M = {}

-- WALKTO 判等（防御式）：ACTIONS 由 03_globals.lua 建为惰性自建表，
-- 正常一定有 WALKTO；但 BufferedAction 的几个分支要拿它比动作身份，
-- 万一 ACTIONS 没装上（极端加载顺序），也不能让整个方法炸掉。
local function is_walkto(a)
    if a == nil then return false end
    local A = rawget(_G, "ACTIONS")
    return A ~= nil and A.WALKTO ~= nil and a == A.WALKTO
end

--=========================================================================
-- 语义覆写：这些方法的返回值会改变 Lua 层控制流
--=========================================================================
local OVERRIDE = {
    -- ---- 部署/建造半径三兄弟（entityscript.lua:820-841）----
    -- 原版实现就是「存下值 + 转告 Map 去更新一个全局间距常量」：
    --     function EntityScript:SetDeploySmartRadius(radius)
    --         self.deploy_smart_radius = radius
    --         if radius then TheWorld.Map:RegisterDeploySmartRadius(radius) end
    --     end
    --     -- components/map.lua:21
    --     function Map:RegisterDeploySmartRadius(radius)
    --         DEPLOY_EXTRA_SPACING = math.max(radius + DEPLOYSPACING_RADIUS[DEPLOYSPACING.LARGE] / 2,
    --                                         DEPLOY_EXTRA_SPACING)
    --     end
    -- 意义：决定「建造/放置时与旁边实体要留多远」，否则新放的草会叠在树上。
    -- 实测触发量：加了 90 个静态景物后，**每个景物都调一次**（x70）。
    -- 原版的值是「取最大值」累加语义，所以它不是空操作 —— 直接把值转给 Map。
    SetDeploySmartRadius = function(self, radius)
        self.deploy_smart_radius = radius
        local m = _G.TheWorld and _G.TheWorld.Map
        if radius ~= nil and m ~= nil and type(m.RegisterDeploySmartRadius) == "function" then
            pcall(m.RegisterDeploySmartRadius, m, radius)
        end
    end,
    SetDeployExtraSpacing = function(self, spacing)
        self.deploy_extra_spacing = spacing
        local m = _G.TheWorld and _G.TheWorld.Map
        if spacing ~= nil and m ~= nil and type(m.RegisterDeployExtraSpacing) == "function" then
            pcall(m.RegisterDeployExtraSpacing, m, spacing)
        end
    end,
    SetTerraformExtraSpacing = function(self, spacing)
        self.terraform_extra_spacing = spacing
        local m = _G.TheWorld and _G.TheWorld.Map
        if spacing ~= nil and m ~= nil and type(m.RegisterTerraformExtraSpacing) == "function" then
            pcall(m.RegisterTerraformExtraSpacing, m, spacing)
        end
    end,
    -- 地面目标阻挡半径：纯数值，供射线/放置判定用
    SetGroundTargetBlockerRadius = function(self, radius)
        self.ground_target_blocker_radius = radius
    end,

    -- ★ 标签查询：`HasAnyTag` 是 entityscript.lua:594 的**别名**
    --     EntityScript.HasAnyTag = EntityScript.HasOneOfTags
    --   实测 187 处调用（componentutil.lua:1426 等）。
    --   宿主表驱动补全里漏了这个别名，于是它掉进「未知方法」→ nil →
    --   `attempt to call method 'HasAnyTag' (a nil value)`。
    --   这类「原版自己起的别名」最容易漏，因为 grep 方法定义时看不到它。
    HasAnyTag = function(self, ...) return self:HasOneOfTags(...) end,
    -- HasTags 是「全部命中」，与 HasAllTags 同义（entityscript.lua:576）
    HasTags = function(self, ...) return self:HasAllTags(...) end,
    -- 距离/位置类
    -- ★★ 这一组原先全是「返回不接近」的假值。以前宿主不跑 brain，
    --    所以没人发现；一旦行为树真的开始跑（host/13_update.lua），
    --    它们立刻变成致命的语义空洞：生物看不见玩家、不会计算朝向。
    --    现在按 entityscript.lua:1421/1428/1436 逐行对齐实现。
    IsNearPlayer = function(self, range, isalive)
        local x, y, z = self.Transform:GetWorldPosition()
        if type(_G.IsAnyPlayerInRange) == "function" then
            return _G.IsAnyPlayerInRange(x, y, z, range, isalive) and true or false
        end
        return false
    end,
    GetNearestPlayer = function(self, isalive)
        local x, y, z = self.Transform:GetWorldPosition()
        if type(_G.FindClosestPlayer) == "function" then
            return _G.FindClosestPlayer(x, y, z, isalive)
        end
        return nil
    end,
    GetDistanceSqToClosestPlayer = function(self, isalive)
        local x, y, z = self.Transform:GetWorldPosition()
        if type(_G.FindClosestPlayer) == "function" then
            local player, d = _G.FindClosestPlayer(x, y, z, isalive)
            return d or math.huge
        end
        return math.huge
    end,
    IsNear = function(self, other, dist)
        return self:GetDistanceSqToInst(other) <= dist * dist
    end,
    GetDistanceSqToPoint = function(self, x, y, z)
        -- ★★★ P43：补上原版的「只传一个 Vector3」分支（entityscript.lua:3526-3537）
        --   原版第二行就是 `if x and not y and not z then x, y, z = x:Get() end` ——
        --   宿主**漏了这一条**，于是 `map.lua:484 near_other_fn` 里的
        --   `other:GetDistanceSqToPoint(pt)`（pt 是一个 Vector3）会把表当成 x、
        --   y/z 当 nil 处理，接着 `number - Vector3` 触发 `Vector3Meta.__sub(a.x…)`，
        --   报 `attempt to index local 'a' (a number value)`。
        --   ⇒ 后果不是「放置判定不准」，而是**整条 deployable/建造落地链路抛错**
        --   （实测 `deployable:CanDeploy()` 直接崩，见 mech.lua 第 10 段）。
        --   原版注释自己写了这条校验不严（(10,nil,nil) 会被误认为 Vector3），
        --   这里**照原样对齐**，不擅自加严 —— 判据是「与原版一致」，不是「我觉得更稳」。
        if x and not y and not z and type(x) ~= "number" then
            local ok, vx, vy, vz = pcall(function() return x:Get() end)
            if ok then x, y, z = vx, vy, vz end
        end
        -- ★ 健壮化：实体可能没有 Transform（未 AddTransform 或已卸载），
        --   也可能被传入 nil 坐标。返回一个大距离而不是让算术崩掉 ——
        --   simutil.lua:69 FindClosestPlayerInRangeSq 会遍历所有 AllPlayers，
        --   一个坏条目会让整条查找链崩掉。
        local x1, y1, z1 = 0, 0, 0
        if self.Transform then x1, y1, z1 = self.Transform:GetWorldPosition() end
        x = x or 0; y = y or 0; z = z or 0
        local dx, dy, dz = (x1 or 0) - x, (y1 or 0) - y, (z1 or 0) - z
        return dx * dx + dy * dy + dz * dz
    end,
    -- ★★ 原实现是 `local x1, y1, z1 = self:GetPosition()` —— 而 GetPosition()
    --    返回的是**一个 Vector3**（entityscript.lua:1356 `Point(...)`），
    --    于是 y1/z1 全是 nil，`z - z1` 直接算术崩。
    --    这条路径以前从没被走到（只有行为树/朝向计算会调它），
    --    现在按 entityscript.lua:1363 原样实现。
    GetAngleToPoint = function(self, x, y, z)
        if x == nil then
            return 0
        elseif y == nil and z == nil then
            x, y, z = x:Get()
        end
        local x1, y1, z1 = self.Transform:GetWorldPosition()
        return (x1 == x and z1 == z)
            and self.Transform:GetRotation()
            or math.atan2((z1 or 0) - z, x - (x1 or 0)) * 180 / math.pi
    end,
    -- ★ 原实现是空函数 ⇒ 实体永远不会转身朝向移动目标
    --   （locomotor:SetMoveDir 走的就是 FacePoint/FaceMovePoint）。
    FacePoint = function(self, x, y, z)
        if self.sg ~= nil and type(self.sg.HasStateTag) == "function"
            and self.sg:HasStateTag("busy") then
            return
        end
        self.Transform:SetRotation(self:GetAngleToPoint(x, y, z))
    end,
    ForceFacePoint = function(self, x, y, z)
        self.Transform:SetRotation(self:GetAngleToPoint(x, y, z))
    end,
    IsEntityInFrontConeSlice = function(self, other) return true end,

    -- ★ SetPrefabName：真实 entityscript.lua:814 实现 `self.prefab = name`。
    --   evergreens.lua:855 在 fn 构造期就调它，随后 :861 用 `inst.prefab.."_tall"` ——
    --   若 prefab 没设上（桩默认返回 nil 而不写字段），861 直接 nil 拼接崩。
    SetPrefabName = function(self, name)
        self.prefab = name
        return name
    end,
    SetPrefabNameOverride = function(self, name)
        self.prefab = name
        return name
    end,

    -- ---- 世界状态查询 ----
    -- ★★ 这一组全是「恒定型」假值，而它们**会 gate 玩法逻辑**：
    --     · IsInLight      → behaviours/avoidlight.lua:47、findlight.lua
    --                        （原版走 LightWatcher，C++ 光照贴图）
    --     · IsOnOcean      → 海洋相关分支
    --     · GetIsWet       → 潮湿相关（ drying / slipping ）
    --     · GetCurrentPlatform → 平台骑乘
    --   宿主没有这些子系统，所以只能给恒定值。**这不是 bug，但必须显式标注** ——
    --   否则「避光行为从不触发」会被误读成「AI 写错了」。
    --   （教训来自 DropDeathLoot：不标注的限制和静默空实现一样危险。）
    IsOnValidGround = function(self) return true end,
    IsOnPassablePoint = function(self) return true end,
    -- ★ 宿主限制：无海洋系统，恒 false
    IsOnOcean = function(self) return false end,
    -- ★★★ C4（2026-10-18 P44）：平台从「恒 nil」改成「可设置的状态」。
    --
    --   为什么要改：这个值**会 gate 玩法**，而且是两个真实路径：
    --     actions.lua:445   CheckIsOnPlatform(doer, dest) -> doer:GetCurrentPlatform() ~= nil
    --                      （BOARDPLATFORM 的 customarrivecheck：上船动作能不能触发）
    --     behaviours/chaseandram.lua:306   追上去后「对象不在平台上就放弃」
    --   恒 nil 的后果是这两条永远走 false 分支 —— 但那不是因为「不在平台上」，
    --   而是因为「根本没人回答」。两者在日志里长得一样。
    --
    --   宿主仍然没有船/码头（不造假平台），但「站在平台上」这件事
    --   现在是**可写、可读、可测** 的状态：SetCurrentPlatform(p) 之后
    --   GetCurrentPlatform() 真的返回 p，并同步到 Physics:IsOnPlatform()。
    --   → 「永不触发」变成「没人让它触发」：后者是能被判据验证的。
    GetCurrentPlatform = function(self) return self._currentplatform end,
    SetCurrentPlatform = function(self, p)
        self._currentplatform = p
        -- 两侧视图同步（真实引擎里它们是同一个 C++ 状态）
        local ph = rawget(self, "Physics")
        if ph ~= nil then ph._onplatform = (p ~= nil) end
        return p
    end,
    GetCurrentTileType = function(self) return 0 end,
    -- ★★★ C3（2026-10-18 P44）：**委托给 LightWatcher**，不再恒 false。
    --
    --   修之前：LightWatcher:IsInLight() 恒 **true**、这里恒 **false**。
    --   同一个宿主对同一个问题给出两个相反答案，而且谁都不随昼夜变。
    --   它不会报错，只会让「避光」与「找光」两类行为走到不同的假分支上。
    --
    --   现在两处同源（环境亮度 ← TheWorld.state.phase），
    --   并且没挂 LightWatcher 的实体也能答得出来（用环境亮度兑底）。
    IsInLight = function(self)
        local lw = rawget(self, "LightWatcher")
        if lw ~= nil and type(lw.IsInLight) == "function" then
            return lw:IsInLight() and true or false
        end
        if type(Core.AmbientLightLevel) == "function" then
            return Core.AmbientLightLevel() >= 0.2
        end
        return false
    end,
    -- ★ 与 IsInLight 严格互补（它们不能同时为真也不能同时为假——那会让
    --   `if not IsInLight() then` 与 `if IsInDark() then` 两种写法不等价）
    IsInDark = function(self)
        local lw = rawget(self, "LightWatcher")
        if lw ~= nil and type(lw.IsInDark) == "function" then
            return lw:IsInDark() and true or false
        end
        return not self:IsInLight()
    end,
    -- ★ floater.lua:4 构造期就调用：宿主只有一个进程，恒为权威
    GetIsMasterSimulation = function(self) return true end,

    -- debuff 托管：宿主无 debuff 系统，返回空
    DebuffsEnabled = function(self) return false end,
    HasDebuff = function(self, name) return false end,
    GetDebuff = function(self, name) return nil end,

    -- 交互能力
    CanInteractWith = function(self, other) return true end,
    CanDoAction = function(self, action) return true end,
    IsAsleep = function(self) return self._asleep == true end,

    -- 存档
    GetPersistData = function(self) return {} end,
    SetPersistData = function(self) end,

    -- 名字
    GetBasicDisplayName = function(self) return self._name end,
    GetDisplayName = function(self) return self._name end,
    GetAdjectivedName = function(self) return self._name end,
    GetAdjective = function(self) return nil end,
    GetSkinName = function(self) return "" end,
    GetSkinBuild = function(self)
        return self.AnimState and self.AnimState._build or ""
    end,
    GetComponentName = function(self, name) return name end,

    -- 湿滑/酸性
    -- ★ 宿主限制：无湿度系统，恒 false（原版由 moisture 组件驱动）
    GetIsWet = function(self) return false end,
    GetWetMultiplier = function(self) return 0 end,
    IsAcidSizzling = function(self) return false end,

    -- brain / stategraph 托管
    GetBrainString = function(self) return "" end,
    GetDebugString = function(self) return "" end,

    -- 平台跟随
    GetPlatformFollowers = function(self) return {} end,

    -- 任务查询
    TimeRemainingInTask = function(self, task) return 0 end,
    GetTaskInfo = function(self, task) return nil end,

    -- 子实体
    SpawnChild = function(self, name) return Core.SpawnPrefab(name) end,
    -- ---- entityscript.lua:895 / :885 父子关系 ----
    -- ★ 这两个原先写错了签名：
    --     AddChild    = function(self, name) return Core.SpawnPrefab(name) end
    --     RemoveChild = function(self, child) if child then child:Remove() end end
    --   而真实签名收的是**子实体（EntityScript）**，不是预制体名：
    --     function EntityScript:AddChild(child)
    --         child.platform = nil
    --         if child.parent then child.parent:RemoveChild(child) end
    --         child.parent = self
    --         if not self.children then self.children = {} end
    --         self.children[child] = true
    --         child.entity:SetParent(self.entity)
    --     end
    --   症状：任何 `owner:AddChild(inst)` 都会走成 SpawnPrefab(表) ——
    --   实测**每次把物品放进背包都会记一条 `prefab:<table>` 假缺口**
    --   （components/inventoryitem.lua:348 → inventory.lua:1150 GiveItem / :1364 Equip），
    --   而且父子链根本没建立。
    AddChild = function(self, child)
        if child == nil then return end
        child.platform = nil
        -- 换父：先让旧父摘掉自己（与原版同构，避免两处 children 都留着）
        if child.parent ~= nil and child.parent ~= self then
            pcall(child.parent.RemoveChild, child.parent, child)
        end
        child.parent = self
        self.children = self.children or {}
        self.children[child] = true
        if child.entity ~= nil and self.entity ~= nil then
            child.entity:SetParent(self.entity)
        end
    end,
    RemoveChild = function(self, child)
        if child == nil then return end
        child.parent = nil
        if self.children ~= nil then self.children[child] = nil end
        if child.entity ~= nil then child.entity:SetParent(nil) end
    end,

    -- ★ GetTimeAlive（entityscript.lua:435-437）
    --       return GetTime() - self.spawntime
    --   由 crow 等生物的 brain 用来做「按存活时长决定行为」，
    --   之前它在桩名单里（只有名字、没有语义），一调用就静默返回 nil。
    GetTimeAlive = function(self)
        return GetTime() - (self.spawntime or 0)
    end,

    -- 物理半径
    GetPhysicsRadius = function(self) return self._physradius or 0 end,
    GetBoatIntersectingPhysics = function(self) return nil end,

    -- 死亡掉落
    GetDeathLootLevel = function(self) return self._deathlootlevel end,
    SetDeathLootLevel = function(self, l) self._deathlootlevel = l end,
    -- ★★ DropDeathLoot 曾被桩成**空函数**（`function(self) end`）。
    --
    --   这是本工程迄今最危险的一类缺口：它不报错、不进缺口清单
    --   （因为在 OVERRIDE 表里静默提供，没走 Core.NoteStub），
    --   但让**整条死亡掉落链静默失效**：
    --     · 单独调 `lootdropper:DropLoot(pos)` → 正常掉（+2 个实体）
    --     · 走 `DropDeathLoot()`（SGpig.lua:105 死亡状态里调的）→ **一个都不掉**
    --   实测症状：生物能进 death 状态、能被移除，但从不掉东西。
    --
    --   现在按原版 entityscript.lua:2156-2167 实现真逻辑。
    DropDeathLoot = function(self)
        self:SetDeathLootLevel(1)
        local lootdropper = self.components.lootdropper
        if lootdropper then
            -- 原版直接写 self.components.health.is_corpsing；
            -- 加一个 nil 保护（带 lootdropper 却没有 health 的实体不该让整条链崩）
            local H = self.components.health
            if H ~= nil and H.is_corpsing then
                local dlh = self.components.deathloothandler
                if dlh ~= nil then
                    dlh:StoreLoot(lootdropper:GenerateLoot())
                end
            else
                lootdropper:DropLoot(self:GetPosition())
            end
        end
    end,

    -- 传送/刷新
    LongUpdate = function(self, dt) end,
    LoadPostPass = function(self, data, ents) end,
    -- 状态图：pigman.lua:311 `inst:SetStateGraph("SGpig")` 传的是**字符串**（SG 名字）
    -- 真实引擎会加载 stategraphs/<name>.lua 并用 StateGraphInstance 包裹。
    -- 宿主同样走真实链路：加载真实 SG 文件 + 真实 StateGraph/StateGraphInstance 类。
    SetStateGraph = function(self, sg)
        if type(sg) == "string" then
            local Core_ = Core
            local Loader = nil
            -- 延迟取 loader，避免循环 require
            local ok, inst = pcall(function()
                local L = require("host.04_loader")
                local _sgok, cls = L.LoadFile(
                    Core_.SourceDir .. "/stategraphs/" .. sg .. ".lua")
                if type(cls) == "table" and _G.StateGraphInstance then
                    local sgi = _G.StateGraphInstance(cls, self)
                    -- ★ 完整复刻 entityscript.lua:1148-1161 的四步：
                    --   ① 建实例 ② 登记 SGManager ③ GoToState(defaultstate)
                    --   ④ limbo 则 Stop
                    --   少了 ③ 状态图永远不会进入初始状态
                    --   （UpdateState 在 currentstate 为 nil 时直接返回，
                    --     实测 720 tick 后 currentstate 仍是 nil）。
                    if type(sgi) == "table" then
                        if sgi.mem == nil then sgi.mem = {} end
                        -- ★★ 必须在 GoToState 之前把 self.sg 指向真实实例！
                        --   原因：状态的 onenter 里普遍会写
                        --     inst.sg:GoToState(...)         （SGwilson.lua:2570 的 init 就是）
                        --   如果此刻 self.sg 还是 NewEntity 时给的**默认 sg**，
                        --   这个嵌套转移就打到了错误对象上 —— 结果是
                        --   currentstate 永远停在 init，且没有任何报错
                        --   （实测：追踪 GoToState 只看到 1 次调用）。
                        rawset(self, "sg", sgi)

                        local SG = _G.SGManager
                        if SG and type(SG.AddInstance) == "function" then
                            local ok, e = pcall(SG.AddInstance, SG, sgi, self:IsAsleep())
                            if not ok then Core.NoteStub("SGManager.AddInstance", "setstategraph") end
                        end
                        local dflt = sgi.sg and sgi.sg.defaultstate
                        if dflt and type(sgi.GoToState) == "function" then
                            local ok2, e2 = xpcall(function()
                                return sgi:GoToState(dflt)
                            end, debug.traceback)
                            if not ok2 then
                                -- 不静默：把真实错误记进缺口清单
                                Core.NoteGap("sg:GoToState(" .. tostring(dflt) .. ") → " ..
                                    tostring(e2):sub(1, 160), "setstategraph")
                            end
                        end
                        -- ★ 已经在初始状态且已登记，不需要再 Start()
                        rawset(self, "_sgstarted", true)
                    end
                    return sgi
                end
                return nil
            end)
            if ok and inst then
                self.sg = inst
                return inst
            end
            -- 加载失败：退化为最小 SG 实例，至少让 HasStateTag / HasState 可调用
            -- ★ 方法表统一来自 Core.SG_METHODS（原先这里手写一份，漏了 HasState）
            local fallback = Core.ApplySGMethods({
                _name = sg, _current = sg,
                -- ★ mem 状态表：player_common.lua:2895 写 `inst.sg.mem.nocorpse`
                mem = {},
            }, { only_missing = false })
            -- ★ 本分支特有的语义覆盖：保持原手写版的返回值不被动到
            --   （通用兜底里 GetCurrentState 返回 nil，这里历来返回 sg 名字）
            fallback.GetCurrentState = function() return sg end
            fallback.IsCurrent = function() return false end
            self.sg = fallback
        else
            -- ★ 即使传进来的不是字符串，也**绝不能**把 sg 设成
            --   非表对象（字符串/nil）。下游组件（slipperyfeet.lua:118）
            --   会直接 `inst.sg:HasAnyStateTag(...)`，非表就报
            --   "attempt to call method ... (a nil value)"。
            if type(sg) == "table" then
                self.sg = sg
            else
                local Core_ = Core
                self.sg = Core_.DefaultSG and Core_.DefaultSG(sg) or sg
            end
        end
        return self.sg
    end,
    ClearStateGraph = function(self) self.sg = nil end,
    SetBrain = function(self, b) self.brain = b end,
    StopBrain = function(self) end,
    RestartBrain = function(self) end,

    -- 墙更新（宿主无墙系统）
    StartWallUpdatingComponent = function(self, c) end,
    StopWallUpdatingComponent = function(self, c) end,

    -- 库存图像覆写
    -- ★ 真实语义就是「有没有登记过映射」（entityscript.lua:5059）。
    --   旧实现恒返 false，于是 06_entityscript 里刚补好的
    --   SetClientSideInventoryImageOverride 登记了映射却没人认。
    HasClientSideInventoryImageOverrides = function(self)
        return self.inventoryimageremapping ~= nil
    end,
    GetClientSideInventoryImageOverride = function(self) return nil end,

    -- entityscript.lua:783 / :789 —— Hide(false) 的 false 是「不隐藏阴影」
    --   （fishable.lua:71 收鱼、blinkstaff.lua:84 瞬移施法者都用它）
    Hide = function(self) self.entity:Hide(false) end,
    Show = function(self) self.entity:Show(false) end,

    -- ====================================================================
    -- limbo / inherent action / 静态延时任务 / 客户端图集覆写
    -- 全部逐行对齐 entityscript.lua 的真实实现。
    -- ====================================================================

    -- ---- entityscript.lua:865 ForceOutOfLimbo ----
    -- 这行三态真值表是原文里最绕的表达式之一，但语义完全确定：
    --     当前在 limbo?  forcedoutoflimbo?  →  SetInLimbo 参数
    --     false          nil                 →  false（本来就不在 limbo）
    --     true           nil/true            →  false（强制留在场景里）
    --     true           false               →  true （正常进 limbo）
    -- 关键：forcedoutoflimbo 只存真值（`state or nil` 归一化），nil 与 false 同义，
    --   所以 `not self.forcedoutoflimbo` 一行就覆盖两者。
    -- 调用点：inventoryitem_replica.lua:181/190（物品进/出背包时切 limbo）。
    ForceOutOfLimbo = function(self, state)
        self.forcedoutoflimbo = state or nil
        local ent = self.entity
        if ent ~= nil and type(ent.SetInLimbo) == "function" then
            local inlimbo = (type(self.IsInLimbo) == "function") and self:IsInLimbo() or false
            ent:SetInLimbo(inlimbo and not self.forcedoutoflimbo or false)
        end
    end,

    -- ---- entityscript.lua:1061 / :1068 Add/RemoveInherentAction ----
    -- 「固有动作」= 该实体天生支持的动作（不用道具就能做）。
    --   farm_hoe.lua:120 `inst:AddInherentAction(ACTIONS.TILL)`
    --   merm_tool.lua:111 同理
    -- 两处都会 SerializeInherentActions 同步给客户端 —— 宿主无网络，记一个函数调用即可。
    AddInherentAction = function(self, act)
        self.inherentactions = self.inherentactions or {}
        self.inherentactions[act] = true
        local ser = rawget(_G, "SerializeInherentActions")
        if type(ser) == "function" then pcall(ser, self) end
    end,
    RemoveInherentAction = function(self, act)
        if self.inherentactions ~= nil then
            self.inherentactions[act] = nil
            -- 空了就整体置 nil（与原版一致，避免残留空表）
            if next(self.inherentactions) == nil then
                self.inherentactions = nil
            end
            local ser = rawget(_G, "SerializeInherentActions")
            if type(ser) == "function" then pcall(ser, self) end
        end
    end,

    -- ---- entityscript.lua:3767 DoStaticTaskInTime ----
    -- 一次性静态延时任务。**staticScheduler 是真实 scheduler.lua 提供的全局**
    -- （scheduler.lua:474 `staticScheduler = Scheduler(true)`，
    --   ExecuteInTime 在 :395），所以这里直接委托，不用自己造调度器。
    -- 调用点：inventory_replica.lua:26（下一帧再开背包，等分类实体就位）、
    --   dryingrack.lua:312、clientpickupsoundsuppressor.lua:23。
    DoStaticTaskInTime = function(self, time, fn, ...)
        if not self.pendingtasks then self.pendingtasks = {} end
        local sched = rawget(_G, "staticScheduler")
        if sched == nil or type(sched.ExecuteInTime) ~= "function" then
            return nil
        end
        local args = { ... }
        local n = select("#", ...)
        local per = sched:ExecuteInTime(time, fn, self.GUID, self, unpack(args, 1, n))
        self.pendingtasks[per] = true
        -- 原版挂在 entityscript.lua:3715 的 task_finish：
        -- 任务结束时把自己从登记表里摘掉。原版还会在「摘不到」时打印
        -- "   NOT FOUND" —— 那是把静默的状态不一致变成可观测日志的自检，
        -- 宿主没有 print 调试流的习惯，这里只保留清理逻辑。
        if per ~= nil then
            per.onfinish = function()
                if self and self.pendingtasks then self.pendingtasks[per] = nil end
            end
        end
        return per
    end,

    -- ---- entityscript.lua:5042 SetClientSideInventoryImageOverride ----
    -- 客户端专属的背包图集换图优化（不走网络）。
    -- ★ 这里正好用上了本工程实证的 sdbm 哈希：原版就用 hash(图片名) 做键
    --   （整数键比字符串键在 Lua 表里快得多）。
    --   prefabs/abigail_flower.lua:244-245 是真实调用点。
    -- 依赖全局 ClientSideInventoryImageFlags（宿主在 03_globals 补了一张空表）。
    SetClientSideInventoryImageOverride = function(self, flagname, srcimage, destimage, destatlas)
        self.inventoryimageremapping = self.inventoryimageremapping or {}
        local remaps = self.inventoryimageremapping[flagname] or {}
        local H = rawget(_G, "hash")
        local key = (type(H) == "function" and type(srcimage) == "string") and H(srcimage) or srcimage
        remaps[key] = { image = destimage, atlas = destatlas }
        self.inventoryimageremapping[flagname] = remaps
        local flags = rawget(_G, "ClientSideInventoryImageFlags")
        local player = rawget(_G, "ThePlayer")
        if flags and flags[flagname] and player then
            player:PushEvent("clientsideinventoryflagschanged")
        end
    end,

    -- ---- entityscript.lua:5059 / :5073 查询侧 ----
    -- 旧实现恒返 nil，导致「已注册映射但查不到」的静默失效。
    -- 查询方不知道当前生效的是哪个 flag，所以要遍历所有 flag（通常 1-3 项）。
    GetClientSideInventoryImageOverride = function(self, imagenamehash)
        local remaps = self.inventoryimageremapping
        if remaps == nil then return nil end
        local flags = rawget(_G, "ClientSideInventoryImageFlags") or {}
        for flag, m in pairs(remaps) do
            if flags[flag] and m[imagenamehash] then
                return m[imagenamehash]
            end
        end
        return nil
    end,
    SetClientSideInventoryImageOverrideFlag = function(self, name, value)
        local flags = rawget(_G, "ClientSideInventoryImageFlags")
        if flags == nil then return end
        -- 原版 entityscript.lua:2090 的归一化：把 boolean 变成「true 或 nil」
        value = (not value) ~= true or nil
        local updated = flags[name] ~= value
        flags[name] = value
        local player = rawget(_G, "ThePlayer")
        if updated and player then
            player:PushEvent("clientsideinventoryflagschanged")
        end
    end,

    -- ====================================================================
    -- BufferedAction 体系（entityscript.lua:3894-4130）
    --
    --   bufferedaction =「这个实体现在想做的事」：
    --       { action, target, invobject, options, args, pos, ... }
    --   三阶段分离是为了「可撤销」：
    --       PreviewBufferedAction  —— 按下鼠标，预览（可反悔）
    --       PushBufferedAction     —— 松开鼠标，真正提交
    --       PerformBufferedAction  —— 执行的那一刻（由状态图/外部触发）
    --
    -- ★ 为什么必须真实实现（而不是返 nil 的桩）：
    --   全库有 216 处读它，而且**几乎全是 brain 的守卫条件**：
    --       dragonflybrain.lua:39      local action = self.inst:GetBufferedAction()
    --       dustmothbrain.lua:125      WhileNode(... GetBufferedAction() ~= nil ...)
    --       oceanfishbrain.lua:222     ConditionWaitNode(... == nil ...)
    --       monkeybrain.lua:407        local ba = inst.harassplayer:GetBufferedAction()
    --       wobycommon.lua:318         local act = performer:GetBufferedAction()
    --   语义是「这个实体正忙着做某个动作吗」—— 桩返 nil 等于**永远不忙**，
    --   于是「等它忙完」类节点立刻穿透、「它在忙」类分支永不进入。
    --   world.lua 实测：GetBufferedAction 被调 91 次，全是这类判断。
    --
    -- ★ 实现逐行对齐真实源码，不简化语义；只有 BA 对象自身的方法
    --   （Fail/Succeed/Do/TestForStart）做了 pcall 兜底 —— 因为
    --   bufferedaction.lua 未必被加载（宿主按需 loadfile）。
    -- ====================================================================

    -- entityscript.lua:4179 —— 就一行，但是整套体系的口子
    GetBufferedAction = function(self)
        return self.bufferedaction
            or (self.components.locomotor ~= nil and self.components.locomotor.bufferedaction)
            or nil
    end,

    -- entityscript.lua:3900 —— 先 Fail 再置 nil（Fail 回调里可能还要读它）
    ClearBufferedAction = function(self)
        if self.bufferedaction ~= nil then
            local ba = self.bufferedaction
            if type(ba.Fail) == "function" then pcall(ba.Fail, ba) end
            self.bufferedaction = nil
        end
    end,

    -- entityscript.lua:3912 —— InterruptBufferedAction 是 ClearBufferedAction 的别名
    --   （原版自己起的双命名，「中断」比「清空」更贴切，因为会触发 Fail）
    InterruptBufferedAction = function(self) self:ClearBufferedAction() end,

    -- entityscript.lua:3924 —— 按下鼠标时的预览
    --   去重守卫：新动作与已有动作的 target/action/invobject 全同则跳过
    --   （避免同一次点击被处理两遍）。
    --   ⚠️ 原版此处比 PushBufferedAction 多一个 `and self:HasTag("idle")`，
    --      注释明确标了「疑似不对称」—— 如实照抄，不擅自统一。
    PreviewBufferedAction = function(self, ba)
        if ba ~= nil and self.bufferedaction ~= nil
            and ba.target == self.bufferedaction.target
            and ba.action == self.bufferedaction.action
            and ba.invobject == self.bufferedaction.invobject
            and not (self.sg ~= nil and self.sg:HasStateTag("idle") and self:HasTag("idle")) then
            return
        end
        if ba == nil then return end
        local opts = ba.options or {}
        if is_walkto(ba.action) then
            -- "walkto is kind of a nil action"：移动由 locomotor 自己做
            self.bufferedaction = nil
        elseif opts.instant then
            self.bufferedaction = ba
            self:PerformPreviewBufferedAction()
        elseif self.sg ~= nil then
            self.bufferedaction = ba
            local ok, accepted = pcall(self.sg.PreviewAction, self.sg, ba)
            if not ok or not accepted then self.bufferedaction = nil end
        elseif ba.action and ba.action.instant then
            self.bufferedaction = ba
            self:PerformPreviewBufferedAction()
        else
            self.bufferedaction = nil
        end
    end,

    -- entityscript.lua:3966 —— ispreviewing 标记防重复执行（鼠标按住会连续发事件）
    PerformPreviewBufferedAction = function(self)
        local ba = self.bufferedaction
        if ba ~= nil and not ba.ispreviewing then
            local pc = self.components.playercontroller
            if pc ~= nil and type(pc.RemoteBufferedAction) == "function" then
                pcall(pc.RemoteBufferedAction, pc, ba)
            end
            ba.ispreviewing = true
        end
    end,

    -- entityscript.lua:3999 —— 松开鼠标，真正提交
    PushBufferedAction = function(self, ba)
        if ba ~= nil and self.bufferedaction ~= nil
            and ba.target == self.bufferedaction.target
            and ba.action == self.bufferedaction.action
            and ba.invobject == self.bufferedaction.invobject
            and not (self.sg ~= nil and self.sg:HasStateTag("idle")) then
            return
        end
        if ba == nil then return end

        -- ① 清掉旧动作（先 Fail 再置 nil）
        if self.bufferedaction ~= nil then
            local old = self.bufferedaction
            if type(old.Fail) == "function" then pcall(old.Fail, old) end
            self.bufferedaction = nil
        end

        -- ② 可用性测试。TestForStart 返回 (success, reason)，
        --    reason 用于 UI 提示「太远了」「材料不够」。
        local ok, success, reason = pcall(ba.TestForStart, ba)
        if ok and success == false then
            self:PushEvent("actionfailed", { action = ba, reason = reason })
            return
        end

        local opts = ba.options or {}
        if is_walkto(ba.action) then
            -- 走到这里时 locomotor 早已把位置处理好了，直接标成功
            self:PushEvent("performaction", { action = ba })
            if type(ba.Succeed) == "function" then pcall(ba.Succeed, ba) end
            self.bufferedaction = nil
        elseif (ba.action and ba.action.instant) or opts.instant then
            -- 立即动作前先转身（受 sg 的 canrotate 标签约束）
            if ba.target ~= nil and ba.target.Transform ~= nil
                and (self.sg == nil or self.sg:HasStateTag("canrotate")) then
                self:FacePoint(ba.target.Transform:GetWorldPosition())
            end
            self:PushEvent("performaction", { action = ba })
            if type(ba.Do) == "function" then pcall(ba.Do, ba) end
            self.bufferedaction = nil
        else
            -- 常规路径：交给状态图编排
            self.bufferedaction = ba
            if self.sg == nil then
                self:PushEvent("startaction", { action = ba })
            else
                local ok2, accepted = pcall(self.sg.StartAction, self.sg, ba)
                -- ⚠️ 原版在 sg 拒绝时「先执行再标记失败」—— 注释自己标了疑似缺陷。
                --   如实照抄：不改顺序，否则会偏离可观测行为。
                if ok2 and accepted == false then
                    self:PushEvent("performaction", { action = ba })
                    if type(ba.Fail) == "function" then pcall(ba.Fail, ba) end
                    self.bufferedaction = nil
                end
            end
        end
    end,

    -- entityscript.lua:4096 —— 执行的那一刻
    PerformBufferedAction = function(self)
        local ba = self.bufferedaction
        if ba == nil then return end
        -- 三重有效性校验：长动作执行时目标可能已被摧毁
        if ba.target ~= nil and ba.target:IsValid() and ba.target.Transform then
            self:FacePoint(ba.target.Transform:GetWorldPosition())
        end
        self:PushEvent("performaction", { action = ba })

        -- 动作专属 BGM：只有玩家才播（敌人拔刀不发音效，避免暴露）
        local theme = nil
        if self:HasTag("player") and ba.action then
            theme = ba.action.theme_music
            if theme == nil and type(ba.action.theme_music_fn) == "function" then
                local ok, t = pcall(ba.action.theme_music_fn, ba)
                if ok then theme = t end
            end
        end
        if theme then self:PushEvent("play_theme_music", { theme = theme }) end

        -- ★ 缓存到局部变量：PushEvent 的回调里可能改掉 self.bufferedaction
        --   （某个监听者调 ClearBufferedAction 或推入新动作）。
        --   原注释称这是个「精妙的防御」—— 不用局部变量就会对错对象收尾。
        if type(ba.Do) == "function" then pcall(ba.Do, ba) end
        if self.bufferedaction == ba then self.bufferedaction = nil end
    end,
}

--=========================================================================
-- 契约内方法清单（从 entityscript.lua 实测提取，130 个）
--=========================================================================
local METHODS = {
    "GetSaveRecord", "StackableSkinHack", "ForceOutOfLimbo",
    "AddInherentAction", "RemoveInherentAction",
    "HasTags", "SetPrefabName", "SetPrefabNameOverride",
    "SetDeployExtraSpacing", "SetDeploySmartRadius",
    "SetTerraformExtraSpacing", "SetGroundTargetBlockerRadius",
    "RemovePlatformFollower", "AddPlatformFollower",
    "KillTasks", "RunScript", "StopAllWatchingWorldStates",
    "PushEventImmediate", "SetPhysicsRadiusOverride",
    "GetPositionAdjacentTo", "FaceAwayFromPoint",
    "CancelAllPendingTasks", "DoStaticPeriodicTask", "DoStaticTaskInTime",
    "PushEventInTime", "ResumeTask", "ClearBufferedAction",
    "PreviewBufferedAction", "PerformPreviewBufferedAction",
    "PushBufferedAction", "PerformBufferedAction", "GetBufferedAction",
    "OnBuilt", "OnUsedAsItem", "PutBackOnGround",
    "SetInherentSceneAction", "SetInherentSceneAltAction",
    "SetClientSideInventoryImageOverride",
    "SetClientSideInventoryImageOverrideFlag",
    "AddDebuff", "RemoveDebuff",
    "SetGroundTargetBlockerRadius",
}

--- 把 EntityScript 契约补全到 EntityMeta
-- 在 01_core 之后调用；只补 01_core 没有的。
function M.Install(EntityMeta)
    local added = 0
    for name, fn in pairs(OVERRIDE) do
        if EntityMeta[name] == nil then
            EntityMeta[name] = fn
            added = added + 1
        end
    end
    for _, name in ipairs(METHODS) do
        if EntityMeta[name] == nil then
            EntityMeta[name] = function(self, ...)
                Core.NoteStub("EntityScript:" .. name, "entityscript-contract")
                return nil
            end
            added = added + 1
        end
    end
    return added
end

return M
