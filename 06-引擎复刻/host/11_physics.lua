--[[
==============================================================================
 11_physics.lua —— Physics 的真实语义（位移积分 + 地形碰撞）

 背景
   宿主的 Physics 一直是纯桩：`SetMotorVel` 只把参数记进 `_setmotorvel`，
   位置永远不动。而 DST 的移动链是这样的：

       locomotor:GoToPoint / WalkForward
            ↓
       LocoMotor:SetMotorSpeed(speed)  →  inst.Physics:SetMotorVel(speed, 0, 0)
            ↓
       ★ C++ 物理每帧把 motor velocity 积分成位移 ★   ← 宿主缺的就是这一步
            ↓
       实体真的移动；locomotor:OnUpdate 里比较「离目标还有多远」决定是否到点

   所以没有这一层，`locomotor` 的所有距离判断都停在原地 ——
   `WantsToMoveForward()` 一直为真、`AtDestination` 永远不成立、生物永远不动。

 ★ 关键：motor velocity 是**实体局部坐标**，不是世界坐标
   证据（可自行核对，不是猜的）：
     · `LocoMotor:SetMotorSpeed` 在非 strafe 情况下直接 `SetMotorVel(speed, 0, 0)`，
       而朝向是靠 `Transform:SetRotation(dir)` 设的 —— 所以 x 分量必然是「朝前」，
       与朝向绑定，即局部坐标。
     · `LocoMotor:SetMotorVelRelToStrafeDir` 传 `speed*cos(α), 0, -speed*sin(α)`
       （α = strafedir - dir）。按局部 → 世界的旋转变换展开：
           world = (a·cosθ + c·sinθ, ·, -a·sinθ + c·cosθ) = speed·(cos(α+θ), ·, -sin(α+θ))
       而 α+θ = strafedir，正好是「沿 strafe 方向移动」——
       与 DST 传说中的「横移朝向独立」语义完全吻合。这条等式反证了局部坐标假设。
     · `GetAngleToPoint`（entityscript.lua:1363）返回 `atan2(z1-z, x-x1) * RADIANS`，
       即 θ = atan2(-Δz, Δx) ⇒ 前方向量 = (cosθ, -sinθ)。旋转矩阵由此确定。

 与真实引擎的差异（如实标注）
   · 真实物理另有阻尼/摩擦/碰撞解算与障碍推挤；宿主只做「积分 + 瓦片可通行判定」。
     直线被挡时尝试沿单轴滑动（滑墙），两轴都挡才停下。
   · 实体与实体之间的碰撞（推挤、卡位）未实现；Pathfinder 的墙体登记是空操作。
==============================================================================
]]

local Stubs = require("host.00_stubs")

local M = {}

local DEG = math.pi / 180

--- 给一个 Physics 桩装上真实位移语义
function M.Decorate(obj, inst)
    obj._inst = inst
    obj._mvx, obj._mvy, obj._mvz = 0, 0, 0
    obj._motor = 0
    obj._moved_total = 0
    obj._blocked = 0

    local function setmotor(x, y, z)
        obj._mvx = x or 0
        obj._mvy = y or 0
        obj._mvz = z or 0
        obj._motor = math.sqrt(obj._mvx * obj._mvx + obj._mvz * obj._mvz)
        if obj._motor == 0 then rawset(obj, "_stopped", true) end
    end
    M._setmotor = M._setmotor or setmotor

    -- ---- setter：三种写法在真实引擎里语义相同（外部/覆盖只是优先级差异）----
    obj.SetMotorVel = function(self, x, y, z) setmotor(x, y, z) end
    obj.SetMotorVelExternal = function(self, x, y, z) setmotor(x, y, z) end
    obj.SetVel = function(self, x, y, z) setmotor(x, y, z) end
    obj.Stop = function(self) setmotor(0, 0, 0) end
    obj.StopUpdating = function(self) setmotor(0, 0, 0) end
    obj.SetHalting = function(self, v) self._halting = v end
    obj.ClearMotorVelOverride = function(self) end

    -- ★ SetDontRemoveOnSleep(v)：物理体在实体入睡时**不被移除**。
    --   DST 里有些物理附件（如挂在身上的东西）会跟着实体一起休眠保留；
    --   缺了这个标志它们会在实体睡下时被清掉，醒来时「东西不见了」。
    --   宿主有实体休眠机制（13_update 的 UpdateSleepStates），所以这个标志
    --   有实际意义，不是摆设。
    obj.SetDontRemoveOnSleep = function(self, v)
        if v == nil then self._dontremoveonsleep = not self._dontremoveonsleep
        else self._dontremoveonsleep = not not v end
        return self._dontremoveonsleep
    end
    obj.IsDontRemoveOnSleep = function(self) return self._dontremoveonsleep and true or false end
    obj.SetMotorVelOverride = function(self, x, y, z) setmotor(x, y, z) end

    -- ---- getter ----
    obj.GetMotorVel = function(self) return self._mvx, self._mvy, self._mvz end
    obj.GetMotorSpeed = function(self) return self._motor or 0 end
    obj.GetVelocity = function(self) return self._mvx, self._mvy, self._mvz end
    obj.GetNormalizedVelocities = function(self)
        local s = self._motor or 0
        if s == 0 then return 0, 0 end
        return self._mvx / s, self._mvz / s
    end
    obj.GetMoveDirection = function(self)
        local s = self._motor or 0
        if s == 0 then return 0 end
        return math.atan2(-self._mvz, self._mvx) / DEG
    end
    obj.GetMaxVelocity = function(self) return self._maxvel or 0 end
    obj.SetMaxVelocity = function(self, v) self._maxvel = v end

    --=========================================================================
    -- 碰撞体 / 材质属性
    --
    -- ★ 这里修了一个**真实的字段名错配**：
    --   00_stubs.lua 的泛化桩把所有 setter 统一存成 `_" .. 方法名小写 `，
    --   于是 SetMass(5) 落进 `_setmass`；而 OVERRIDES 表里的
    --   GetMass 读的是 `_mass`（初值 1）—— **存的和读的完全不是同一个键**。
    --   实测 world.lua 2400 tick 里这组 setter 被调 76 次，全部落进这个黑洞：
    --   SetMass 之后 GetMass 永远返回 1，谁也没发现，因为没人断言过它。
    --
    -- ★ 为什么这些值在宿主里「只存不用」是诚实的：
    --   本文件头部已声明 —— 宿主只做「motor velocity 积分 + 瓦片可通行判定」，
    --   **不建模**实体间碰撞、推挤、摩擦耗散。所以 mass/friction/damping/
    --   restitution/collision-group 存下来供读取与断言，但不喂进积分器：
    --   喂了就是伪造一套宿主并没有的物理。
    --   ⚠️ 唯一的例外是**半径** —— 它直接决定「身体能不能塞进这条缝」，
    --      下面的 _integrate 会真的用它（见该处注释）。
    -- ========================================================================
    obj.SetMass = function(self, v) self._mass = v end
    obj.SetTempMass = function(self, v) self._tempmass = v end
    obj.SetFriction = function(self, v) self._friction = v end
    obj.SetDamping = function(self, v) self._damping = v end
    obj.SetRestitution = function(self, v) self._restitution = v end
    -- ⚠️ GetFriction / GetDamping / GetRestitution 不在 00_stubs 的
    --   METHODS 清单里 —— 不补的话它们会掉进「真缺口」（契约外接口），
    --   而原版确实在调（components/heavyobstaclephysics.lua 等）。
    obj.GetFriction = function(self) return self._friction or 0 end
    obj.GetDamping = function(self) return self._damping or 0 end
    obj.GetRestitution = function(self) return self._restitution or 0 end

    obj.SetCollisionGroup = function(self, v) self._group = v end
    obj.SetCollisionMask = function(self, v) self._mask = v end
    obj.SetLocalCollisionMask = function(self, v) self._localmask = v end
    obj.ClearCollisionMask = function(self) self._mask = 0 end
    obj.ClearLocalCollisionMask = function(self) self._localmask = nil end
    obj.SetCollides = function(self, v) self._collides = v end
    -- ★★ `ClearCollidesWith(mask)` 是 `CollidesWith(mask)` 的**逆操作**：
    --   把这几个碰撞组从掩码里**拿掉**（调用点：`projectile.lua:164`
    --   `self.inst.Physics:ClearCollidesWith(COLLISION.LIMITS)`）。
    --   此前写成 `self._collideswith = nil` —— 既没有参数，也没有真的清掩码，
    --   于是 `CollidesWith` 加进去的组**永远拿不掉**。
    --   ⚠️ 装饰器在 `00_stubs.lua` 的语义覆写**之后**跑，所以这里会**盖掉**那边；
    --   两边必须写同一套语义（同一份判据只写一次，见 00_stubs 的注释）。
    obj.ClearCollidesWith = function(self, mask)
        local bit = rawget(_G, "bit")
        local m = tonumber(mask) or 0
        local cur = tonumber(self._mask) or 0
        if bit ~= nil and type(bit.band) == "function" and type(bit.bnot) == "function" then
            self._mask = bit.band(cur, bit.bnot(m))
        else
            self._mask = cur - (bit ~= nil and bit.band(cur, m) or 0)
        end
    end

    -- 碰撞体形状。DST 的签名（从真实调用点反推，不是猜的）：
    --   SetCapsule(radius, height)  —— heavyobstaclephysics.lua:23
    --                                  `SetCapsule(radius, 2)`
    --   SetCylinder(radius, height) —— archive_pillar.lua:59 `SetCylinder(1.8, 6)`
    --   SetSphere(radius)           —— balloonparty.lua:291 `SetSphere(0.5)`
    --   SetRadius(radius)           —— 二维圆形碰撞体
    obj.SetCapsule = function(self, r, h) self._radius = r; self._height = h end
    obj.SetCylinder = function(self, r, h) self._radius = r; self._height = h end
    obj.SetSphere = function(self, r) self._radius = r end
    obj.SetRadius = function(self, r) self._radius = r end
    obj.GetHeight = function(self) return self._height or 2 end

    -- ---- 直接放置 ----
    obj.Teleport = function(self, x, y, z)
        local t = self._inst and self._inst.Transform
        if t then t:SetPosition(x, y, z) end
    end
    obj.TeleportOffset = function(self, x, y, z)
        local t = self._inst and self._inst.Transform
        if t then
            local px, py, pz = t:GetWorldPosition()
            t:SetPosition((px or 0) + (x or 0), (py or 0) + (y or 0), (pz or 0) + (z or 0))
        end
    end

    --=========================================================================
    -- ★ 每 tick 积分：把局部 motor velocity 变成世界位移
    --=========================================================================
    obj._integrate = function(self, dt)
        local mx, mz = self._mvx, self._mvz
        if mx == 0 and mz == 0 then return 0 end

        local inst = self._inst
        local t = inst and inst.Transform
        if t == nil then return 0 end

        local rot = (t:GetRotation() or 0) * DEG
        local cosr, sinr = math.cos(rot), math.sin(rot)
        -- 局部 → 世界（见文件头推导）
        local wx = mx * cosr + mz * sinr
        local wz = -mx * sinr + mz * cosr

        local x, y, z = t:GetWorldPosition()
        x, y, z = x or 0, y or 0, z or 0
        local nx, nz = x + wx * dt, z + wz * dt
        if nx == x and nz == z then return 0 end

        local map = _G.TheWorld and _G.TheWorld.Map
        -- ★ 半径进入碰撞判定。
        --   此前只用**中心点**判可通行，于是 SetRadius 设了个寂寞 ——
        --   world.lua 自己就调了 `inst.Physics:SetRadius(0.5)`，却被完全忽略：
        --   一个半径 0.5 的生物可以脸贴进不可通行瓦片，只要中心点还在空地上。
        --   近似做法：把目的地沿移动方向的前后各退/进一个半径，
        --   等价于「用一条长度为 2r 的线段代替点去做可通行判定」。
        --   r = 0 时两点重合，行为与旧版逐字节一致（无回归）。
        -- ⚠️ 仍是近似：真实引擎是胶囊体与瓦片求交，宿主只采样两个点。
        --    但不采样就等于没有碰撞体，比近似更错。
        local r = self._radius or 0
        local speed = math.sqrt(wx * wx + wz * wz)
        local ox, oz = 0, 0
        if r > 0 and speed > 1e-9 then
            ox, oz = wx / speed * r, wz / speed * r
        end
        local function passable(px, pz)
            if map == nil then return true end
            if type(map.IsPassableAtPoint) == "function" then
                local ok, rr = pcall(map.IsPassableAtPoint, map, px, 0, pz)
                if ok then return rr and true or false end
                return true
            end
            if type(map.IsAboveGroundAtPoint) == "function" then
                local ok, rr = pcall(map.IsAboveGroundAtPoint, map, px, 0, pz)
                if ok then return rr and true or false end
            end
            return true
        end
        -- 身体占位：中心点 + 沿运动方向的前缘（+r）与后缘（−r）
        local function body_ok(px, pz)
            if not passable(px, pz) then return false end
            if r <= 0 then return true end
            if not passable(px + ox, pz + oz) then return false end
            if not passable(px - ox, pz - oz) then return false end
            return true
        end

        if not body_ok(nx, nz) then
            -- ★ 计数语义：只要「按原方向走」被拒绝就算一次撞墙 ——
            --   包括被完全刹停，也包括只能沿单轴滑动的情况。
            --   （早前只在「两轴都挡」时才计数，于是贴着墙滑行时 counter 恒为 0，
            --     看起来像「碰撞从未触发」——这是个会误导结论的度量。）
            self._blocked = (self._blocked or 0) + 1
            -- 滑墙：只沿能走的那一轴移动；两轴都挡就停下（等价于撞墙）
            -- ★ 这里也必须用 body_ok —— 滑墙时同样要保证身体塞得进去，
            --   否则会出现「中心点过了、身体还有一半在墙里」的半穿模。
            local okx, okz = body_ok(nx, z), body_ok(x, nz)
            if okx and not okz then
                nx, nz = nx, z
            elseif okz and not okx then
                nx, nz = x, nz
            else
                setmotor(0, 0, 0)
                return 0
            end
        end

        t:SetPosition(nx, y, nz)
        local moved = math.sqrt((nx - x) * (nx - x) + (nz - z) * (nz - z))
        self._moved_total = (self._moved_total or 0) + moved
        return moved
    end

    -- 诊断用
    obj.GetMovedTotal = function(self) return self._moved_total or 0 end
    obj.GetBlockedCount = function(self) return self._blocked or 0 end

    return true
end

--=========================================================================
-- 注册为装饰器：Stubs.Make("Physics", ...) 建好桩之后自动接管
--=========================================================================
Stubs.AddDecorator("Physics", M.Decorate)

return M
