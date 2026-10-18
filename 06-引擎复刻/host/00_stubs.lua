--[[
==============================================================================
 00_stubs.lua —— C++ 组件桩生成器（表驱动）

 真实引擎里 AnimState / Light / SoundEmitter / Transform / Physics / Network
 都由 C++ 实现，Lua 只调方法。宿主需要为每个组件提供「契约等价」的实现。

 ★ 为什么用表驱动而不是手写
   实测各组件的方法面：
        AnimState     94 个
        Physics       97 个
        Transform     36 个
        Light         18 个
        SoundEmitter   8 个
        MiniMapEntity 14 个
        Network       17 个
   手写必然遗漏，而遗漏就表现为「attempt to call method X (a nil value)」。
   表驱动 + 分层覆写 = 一次覆盖全部，且关键方法仍有真实语义。

 ★ 三层结构
   1) 泛化桩：任何方法都可调用，返回哑值，同时记录缺口
   2) 语义覆写：对「影响控制流的方法」给出真实返回值
      （如 AnimState:IsCurrentAnimation 决定 pighouse 是否开灯）
   3) 状态字段：供外部断言检查
==============================================================================
]]

local bitlib = require("host.21_bit")   -- USERFLAGS 位运算（Lua 5.1 无位运算符）

local Stubs = {}

--- ★ 音频事件出口：`host/29_audio.lua` 会把自己的表挂到 `_G.__AUDIO_SINK`。
--  为什么是**每次现查**而不是在这里 require：
--    00_stubs 在 03_globals 之前加载，而 29_audio 在 03_globals 尾部装 ——
--    这里 require 会拿到 nil（或者造成循环依赖）。
--  没有 sink 时（例如只 require 了 stubs 的极简探针）**静默降级为空操作**，
--  但**不影响 `_playing` 的记账** —— 状态永远是真的，只是没人订阅。
local function audio_sink()
    local a = rawget(_G, "__AUDIO_SINK")
    if type(a) == "table" then return a end
    return nil
end

--- ★ 装饰器注册表：Stubs.Decorators["AnimState"] = { fn(obj, inst, name) ... }
--- 让宿主模块能在桩建好之后「接管」它，把纯桩升级为真实实现。
--- 首个用户是 host/10_animstate.lua（用真实 ZipAnim 帧数据替换 AnimState 桩）。
--- ⚠️ 必须在任何 Stubs.Make 调用之前就存在，所以在这里初始化。
Stubs.Decorators = {}

--- 装饰器抛错时的回调（由 Core 注入，避免静默掩盖）
Stubs.OnDecoratorError = nil

--- 注册一个装饰器（幂等：同名同函数只注册一次）
function Stubs.AddDecorator(name, fn)
    local list = Stubs.Decorators[name]
    if not list then
        list = {}
        Stubs.Decorators[name] = list
    end
    for _, f in ipairs(list) do
        if f == fn then return end
    end
    list[#list + 1] = fn
end

--=========================================================================
-- 各组件的「语义覆写」表
--   key = 方法名, value = function(self, ...) end
--   这些方法的返回值会影响 Lua 层的控制流，必须给对。
--=========================================================================

local OVERRIDES = {

    AnimState = {
        -- ★ SetRayTestOnBB(on)：开关「用包围盒做射线检测」。
        --   真实用途：鼠标拾取 / 点击命中判定（animstate 的**渲染**能力）。
        --   ⚠️ 一开始我把它加到了 Transform 段（因为紧挨着 SetFourFaced），
        --     但 SetFourFaced 其实是 Transform 的 —— 放错段就不会生效。
        --   宿主没有渲染与拾取管线，所以**存下开关值**而不是凭空返回：
        --   这是个可读的渲染配置，接渲染器时直接可用。
        SetRayTestOnBB = function(self, on) self._raytestonbb = on and true or false end,
        IsRayTestOnBB = function(self) return self._raytestonbb == true end,
        -- ★ SetErosionParams(t, cutoff_height, intensity)：**着色器**参数
        --   （溶解/侵蚀效果，把贴图按高度阈值裁掉）。
        --   调用点：projectedeffects.lua:19/88（投射物消散）、
        --           beef_bell.lua:232（牛铃召唤时地面牛身淡入）、
        --           penguin_ice.lua:32 等。
        --   宿主没有着色器管线 —— 但**存下来**而不是丢掉：
        --   它是可读的渲染状态，接渲染器时直接可用；
        --   同时让「有没有被调用过」可断言。
        SetErosionParams = function(self, t, cutoffheight, intensity)
            self._erosion = { t = t, cutoff = cutoffheight, intensity = intensity }
        end,
        GetErosionParams = function(self) return self._erosion end,
        -- ★ SetMultColour(r, g, b, a)：**整身着色**（各分量 0..1，与贴图相乘）。
        --   与 SetAddColour（叠加）不同，这个是乘法变暗/染色。
        --   调用点：burnable.lua:326（烧焦时 `SetMultColour(.2,.2,.2,1)` 变黑）、
        --           avengingghost.lua:129（怨灵染红 207/92/92）、
        --           aoecharging.lua:168 等 —— **是「烧焦/激怒」这类状态的可见表现**。
        --   宿主无渲染，但把**四个分量原样存下**：这是可读的状态，
        --   播放器/将来接 GPU 时直接可用。
        SetMultColour = function(self, r, g, b, a)
            self._multcolour = { r or 1, g or 1, b or 1, a or 1 }
        end,
        GetMultColour = function(self)
            local c = self._multcolour
            if c == nil then return 1, 1, 1, 1 end
            return c[1], c[2], c[3], c[4]
        end,
        -- ★ Pause / Resume：暂停/恢复动画推进。
        --   entityscript.lua:394 在实体从休眠唤醒时会 `self.AnimState:Resume()`。
        --   宿主此前连 Pause 都没有 —— 记录标志位，语义完整。
        Pause = function(self) self._animpaused = true end,
        Resume = function(self) self._animpaused = false end,
        IsPaused = function(self) return self._animpaused == true end,
        -- ★ 影响控制流：pighouse.lua:23 `inst.AnimState:IsCurrentAnimation("lit")`
        IsCurrentAnimation = function(self, name)
            return self._anim == name
        end,
        GetCurrentAnimationName = function(self) return self._anim end,
        GetCurrentAnimationNumFrames = function(self) return self._frames or 1 end,
        GetCurrentAnimationTime = function(self) return self._time or 0 end,
        GetCurrentAnimationLength = function(self) return self._length or 1 end,
        GetBuild = function(self) return self._build end,
        GetBankHash = function(self) return self._bank or "" end,
        GetSkinBuild = function(self) return self._skin or "" end,
        GetScale = function(self) return self._scale or 1 end,
        GetLayer = function(self) return self._layer or 0 end,
        AnimDone = function(self) return self._animdone ~= false end,
        -- ★ 状态记录型 setter：让外部能断言动画状态
        SetBank = function(self, b) self._bank = b end,
        SetBuild = function(self, b) self._build = b end,
        SetSkin = function(self, s) self._skin = s or "" end,
        PlayAnimation = function(self, a, loop)
            self._anim = a
            self._looping = loop or false
            self._queue = {}
            return loop and 0 or 1
        end,
        PushAnimation = function(self, a, loop)
            table.insert(self._queue, a)
            return loop and 0 or 1
        end,
        SetFinalOffset = function(self, o) self._finaloffset = o end,
        SetLightOverride = function(self, v) self._lightoverride = v end,
        SetBloomEffectHandle = function(self, h) self._bloomhandle = h end,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
    },

    Light = {
        -- ★ 影响控制流：pighouse.lua:23 `inst.Light:IsEnabled()`
        IsEnabled = function(self) return self._enabled == true end,
        GetIntensity = function(self) return self._intensity end,
        GetFalloff = function(self) return self._falloff end,
        GetRadius = function(self) return self._radius end,
        GetCalculatedRadius = function(self) return self._radius end,
        GetColour = function(self) return unpack(self._colour) end,
        DBString = function(self) return "" end,
        -- ★ 状态记录型 setter
        Enable = function(self, on) self._enabled = on and true or false end,
        SetIntensity = function(self, v) self._intensity = v end,
        SetFalloff = function(self, v) self._falloff = v end,
        SetRadius = function(self, v) self._radius = v end,
        SetColour = function(self, r, g, b) self._colour = { r, g, b } end,
    },

    SoundEmitter = {
        PlayingSound = function(self, name) return self._playing[name] ~= nil end,
        -- ★ SetParameter(param, value)：给正在播的声音实时调参（音高/音量/滤波）。
        --   burnable 点火时会用（把火焰声调亮）。原为桩 → 声音始终是原始参数。
        SetParameter = function(self, param, value)
            self._params = self._params or {}
            self._params[param] = value
            return value
        end,
        GetParameter = function(self, param)
            return self._params ~= nil and self._params[param] or nil
        end,
        PlaySound = function(self, name, tag)
            self._playing[tag or name] = name
            -- ★ P41：除了记账，还要**产出可观测事件**（tick / prefab / 音量 / 音高）。
            --   没有这一步，「这一段到底有没有播过声音」永远只能靠猜。
            local A = audio_sink()
            if A ~= nil then A.PushPlay(self._inst, name, self._volume, self._pitch, tag) end
        end,
        --- `PlaySoundWithParams(name, params, tag)`：原版用它带音量/音高/滤波参数。
        --  宿主把 params 里的 volume/pitch 提出来到事件里（其余参数原样带到 ev.params）。
        PlaySoundWithParams = function(self, name, params, tag)
            self._playing[tag or name] = name
            local A = audio_sink()
            if A ~= nil then
                local p = (type(params) == "table") and params or {}
                A.PushPlay(self._inst, name, p.volume or self._volume,
                           p.pitch or self._pitch, tag)
            end
        end,
        KillSound = function(self, tag)
            if self._playing[tag] ~= nil then
                self._playing[tag] = nil
                local A = audio_sink()
                if A ~= nil then A.PushKill(self._inst, tag) end
            end
        end,
        KillAllSounds = function(self)
            local n = 0
            for _ in pairs(self._playing) do n = n + 1 end
            self._playing = {}
            local A = audio_sink()
            if A ~= nil then A.PushKillAll(self._inst, n) end
        end,
        --- ★ 音量/音高：原版是 emitter 上的真实状态（默认 1）。
        --  此前这两个方法**连字段都没有**（泛化桩 return nil），
        --  于是「SetVolume(0) 之后事件该带 vol=0」这类判据根本无从谈起。
        SetVolume = function(self, v) self._volume = tonumber(v) or 1 end,
        GetVolume = function(self) return self._volume or 1 end,
        SetPitch = function(self, v) self._pitch = tonumber(v) or 1 end,
        GetPitch = function(self) return self._pitch or 1 end,
        --- `OverrideVolumeMultiplier(m)`：乘一个全局倍率（原版用于「静音区」等）。
        OverrideVolumeMultiplier = function(self, m)
            self._volmult = tonumber(m) or 1
            return self._volmult
        end,
    },

    MiniMapEntity = {
        GetIcon = function(self) return self._icon end,
        SetIcon = function(self, i) self._icon = i end,
        -- ★ 小地图的显示开关与排序（真实调用点）：
        --     globaltrackingicon.lua:31/61   SetEnabled(false/true)
        --       —— 「追踪图标暂时不显示」（如玩家死亡时）
        --     maprevealable.lua:38/147/173   SetPriority(n)
        --     SetDrawOverFogOfWar / SetCanUseCache —— 战争迷雾绘制与缓存开关
        --   宿主没有小地图 UI，所以这些**只记录状态**：既不静默吞掉调用，
        --   也绝不假装自己在渲染。
        SetEnabled = function(self, on)
            self._enabled = on and true or false
        end,
        IsEnabled = function(self) return self._enabled ~= false end,
        SetPriority = function(self, p) self._priority = p end,
        GetPriority = function(self) return self._priority or 0 end,
        SetDrawOverFogOfWar = function(self, on) self._drawoverfog = on and true or false end,
        SetCanUseCache = function(self, on) self._usecache = on and true or false end,
        SetAtlas = function(self, a) self._atlas = a end,
        GetAtlas = function(self) return self._atlas end,
        SetFocusMode = function(self, m) self._focusmode = m end,
        SetFadeTime = function(self, t) self._fadetime = t end,
    },

    Transform = {
        -- ★ 影响控制流：onhammered 用 GetWorldPosition 定位特效
        GetWorldPosition = function(self) return self._x, self._y, self._z end,
        GetPosition = function(self) return self._x, self._y, self._z end,
        GetLocalPosition = function(self) return self._x, self._y, self._z end,
        GetRotation = function(self) return self._rot or 0 end,
        GetScale = function(self) return self._scale or 1 end,
        GetWorldScale = function(self) return self._scale or 1 end,
        IsTryingToOpenMe = function(self) return false end,
        CanTransform = function(self) return self._cantransform ~= false end,
        SetPosition = function(self, x, y, z)
            self._x, self._y, self._z = x or self._x, y or self._y, z or self._z
            -- ★ C6：标记「这个实体的位置是**别人显式给的**」。
            --   `_x/_y/_z` 初值是 0，所以光看值分不清「摆在原点」和「从没摆过」。
            --   而父实体跟随（02_sim）必须能分清这两者：
            --     · classified 镜像实体从没摆过 ⇒ 应该跟着父实体走
            --     · 被显式摆到某处的东西 ⇒ 不该被父坐标覆盖
            --   ⇒ 一个布尔标记，比猜坐标可靠。
            self._explicit_pos = true
        end,
        SetRotation = function(self, r)
            -- ★★ 原版 locomotor.lua 的 SetMoveDir 会把 **Vector3（表）** 直接传进来：
            --        self.inst.Transform:SetRotation(dir)
            --    宿主原来照单全收 ⇒ `_rot` 变成表 ⇒ 11_physics 的 _integrate 做
            --    `math.cos(_rot)` 抛 "bad argument #1 to 'cos' (number expected, got table)"，
            --    而 Sim.Step 用 pcall 把它吞掉 ⇒ 症状是「**设了速度却不动，且毫无日志**」。
            --    （这是 P2-2 走原版 locomotor 路径时暴露出来的真 bug。）
            --   ⇒ 统一收敛成数字：非数字 ⇒ 0，并记一次桩（不静默）。
            if type(r) ~= "number" then
                if Core and Core.NoteStub then
                    Core.NoteStub("Transform:SetRotation(非数字:" .. type(r) .. ")",
                                  "rotation-coerce")
                end
                r = 0
            end
            self._rot = r
        end,
        -- ★ SetFourFaced / SetSixFaced：贴图**朝向数**。
        --   真实含义：渲染时把 rotation 量化到固定档位（4 向 = 90°，6 向 = 60°），
        --   因为这些生物的贴图只画了那么几个朝向，不量化会插出「不存在的侧面」。
        --   调用点：rider.lua:117/204（骑乘时生物跟着马头朝向）、
        --     sharkboibrain.lua:26（鲨鱼只能朝 4 个方向）。
        --   宿主无渲染，但**语义要记下来** —— 播放器和将来的 GPU 渲染都要用。
        -- ★ SetScale(v)：缩放。与 GetScale / GetWorldScale 成对（原实现只有读）。
        SetScale = function(self, v) self._scale = v == nil and 1 or v end,
        SetFourFaced = function(self) self._faced = 4 end,
        SetSixFaced = function(self) self._faced = 6 end,
        GetFacingCount = function(self) return self._faced or 1 end,
        -- ★ SetTwoFaced：精灵**左右镜像**（真实引擎的 C++ 方法）。
        --   与 SetFourFaced/SixFaced 是同一族「贴图朝向」设置，区别在于：
        --     前两者量化**旋转角**，这个只决定「要不要按 facing 翻转 x」。
        --   调用点：fx.lua:2682/2695/2708（粒子）、abysspillar_minion.lua:40。
        --   原先它在桩名单里 —— 一调用就静默返回 nil，
        --   等于**粒子特效永远单面**（而特效正是靠它决定翻不翻）。
        --   语义留在这里，播放器/GPU 渲染可以据此镜像。
        SetTwoFaced = function(self, v)
            if v == nil then self._twofaced = not self._twofaced
            else self._twofaced = not not v end
            return self._twofaced
        end,
        IsTwoFaced = function(self) return self._twofaced and true or false end,
        -- ★ SetFromProxy(guid)：让本实体的位置**跟随另一个实体**。
        --   真实用途：纯特效实体（cane_ancient_fx / brokentool / bishop_charge …）
        --   不自己算位置，而是每帧抓被跟随者的坐标。
        --   实现：记下 proxy 的 GUID，实际跟随在 Sim.Step 的同步趟里做
        --   （见 02_sim.lua 的 「proxy 跟随」段）。
        SetFromProxy = function(self, guid)
            self._proxyguid = guid
            return self
        end,
        GetProxy = function(self) return self._proxyguid end,
        -- ★ C4：`Transform:SetIsOnPlatform` 是**设置器**，真实调用点
        --   `components/walkableplatformplayer.lua:207/247/286`（上/下船时开合）。
        --   它原先只在 `STUB_NAMES.Transform` 名单里 ⇒ 一调用就静默返回 nil，
        --   状态**完全丢失**：`Physics:IsOnPlatform()` 既没有来源、也没有去处。
        --   ⇒ 转发到 Physics 的同一字段，让 Set/Query 成为一条真的通路。
        --   （真实引擎里这是 C++ 两侧同步的同一个状态，这里等价实现。）
        SetIsOnPlatform = function(self, v)
            local flag = v and true or false
            self._onplatform = flag
            -- 同步到 Physics（真实引擎里是同一个 C++ 状态的两侧视图）。
            -- ⚠️ 直接**写**，不要先读 —— 读未设字段会命中泛化桩返回函数。
            local inst = self._inst
            if inst ~= nil and rawget(inst, "Physics") ~= nil then
                inst.Physics._onplatform = flag
            end
        end,
        GetIsOnPlatform = function(self) return rawget(self, "_onplatform") == true end,
    },

    Physics = {
        GetMass = function(self) return self._mass end,
        GetCollisionGroup = function(self) return self._group end,
        GetCollisionMask = function(self) return self._mask end,
        GetRadius = function(self) return self._radius end,
        GetVelocity = function(self) return self._vx or 0, self._vy or 0, self._vz or 0 end,
        GetMotorVel = function(self) return self._motor or 0 end,
        GetMotorSpeed = function(self) return self._motor or 0 end,
        GetPhysicsState = function(self) return self._state or "static" end,
        IsActive = function(self) return self._active ~= false end,
        IsFalling = function(self) return self._falling == true end,
        IsObstacle = function(self) return self._obstacle == true end,
        IsItem = function(self) return self._item == true end,

        -- ★★ 原版 `Physics:CollidesWith(mask)` 是**设置器**，不是查询。
        --   实测调用点（`components/heavyobstaclephysics.lua:90`）：
        --       `inst.Physics:CollidesWith(COLLISION.CHARACTERS)`
        --   参数是**碰撞组位掩码**（`COLLISION.*`，见真 constants.lua：
        --   GROUND=32 / LIMITS=192 / WORLD=224 / ITEMS=256 / OBSTACLES=512 /
        --   CHARACTERS=1024 / FLYERS=2048 / SANITY=4096 / GIANTS=16384），
        --   语义是「把这几个组加进我的碰撞掩码」，C++ 绑定**不返回值**。
        --
        --   ★ 此前宿主写成 `function(self, other) return true end` ——
        --     双重错误：① 把设置器当查询；② 恒定返回 true。
        --     后果：任何读它的返回值做判定的代码都会得到「永远碰上了」。
        --   ★ 另一处相关修正：`ClearCollidesWith`（`projectile.lua:164`）是它的逆操作。
        CollidesWith = function(self, mask)
            local bit = rawget(_G, "bit")
            local m = tonumber(mask) or 0
            local cur = tonumber(self._mask) or 0
            if bit ~= nil and type(bit.bor) == "function" then
                self._mask = bit.bor(cur, m)
            else
                self._mask = cur + m     -- 退化：没有位运算库时至少不丢信息
            end
            -- ★ 不返回值（对齐原版 C++ 绑定）
        end,
        ClearCollidesWith = function(self, mask)
            local bit = rawget(_G, "bit")
            local m = tonumber(mask) or 0
            local cur = tonumber(self._mask) or 0
            if bit ~= nil and type(bit.band) == "function" and type(bit.bnot) == "function" then
                self._mask = bit.band(cur, bit.bnot(m))
            else
                self._mask = cur - bit.band(cur, m)
            end
        end,

        -- ★★★ C4（2026-10-18 P44）：`IsOnPlatform` 是**查询**，且返回值必须是布尔。
        --
        --   旧行为：它不在覆写表里 ⇒ 落到泛化桩 ⇒ 恒 `nil`。
        --   `nil` 在 `if ... then` 里与 false 等价，看起来"没区别"，
        --   但它**不是同一个东西**：
        --     · `inst.Physics:IsOnPlatform() == false` 恒为 false（nil ≠ false）
        --     · 把返回值传下去/存起来的代码会拿到 nil，错误被推迟到别处
        --     · C++ 绑定的返回类型是 **bool**，nil 属于"接口契约被破坏"
        --   ⇒ 这不是"少一个功能"，是"接口说谎"。平台系统可以没有，
        --     但「有没有站在平台上」这个问题必须能被**明确回答**（默认 false）。
        --
        --   与 `SetIsOnPlatform` 成对：只有 Query/Setter 成对，
        --   「设了之后能读到」才成其为语义，而不是又一个恒定值。
        -- ★ 用 rawget：不带 rawget 的话，未设值时读 `self._onplatform` 会命中
        --   泛化桩的 __index，返回一个**函数**（并记一次桩调用），
        --   `函数 == true` 虽然也是 false，但那是"碰巧对"，不是"契约对"。
        IsOnPlatform = function(self) return rawget(self, "_onplatform") == true end,
        SetIsOnPlatform = function(self, v) self._onplatform = v and true or false end,
    },

    Network = {
        GetNetworkID = function(self) return self._netid or 0 end,
        -- ★ SetPlayerEquip(eslotID, name)：把「某装备槽上是什么」推给网络，
        --   用于**别人看你**时的外观（components/playerinspectable.lua:4/8）。
        --   宿主无网络层，但把它**存下来**而不是丢掉 ——
        --   语义真实（「这个槽位现在挂着什么」是个可读的状态），
        --   将来做装备外观同步时直接可用。
        --   调用点：playerinspectable.lua:4（装备）/:8（卸下，name=""）
        SetPlayerEquip = function(self, eslot, name)
            self._playerequip = self._playerequip or {}
            self._playerequip[eslot] = name
        end,
        GetPlayerEquip = function(self, eslot)
            return self._playerequip and self._playerequip[eslot] or nil
        end,
        GetUserID = function(self) return self._userid or "" end,
        GetPlayerAge = function(self) return self._age or 0 end,
        GetClientName = function(self) return self._clientname or "" end,
        IsServerAdmin = function(self) return false end,
        -- ★ GetUserFlags 原先**恒返 0**（硬编码假值）。
        --   widgets/targetindicator.lua:47/108 靠它决定目标指示器的显隐，
        --   恒 0 等于「所有玩家都无任何标志」。
        --   USERFLAGS 是 6 位掩码（constants.lua:3228）：
        --     IS_GHOST=1  IS_AFK=2  CHARACTER_STATE_1=4
        --     CHARACTER_STATE_2=8  IS_LOADING=16  CHARACTER_STATE_3=32
        GetUserFlags = function(self) return self._userflags or 0 end,
        -- ★ SetPlayerAge 修的是**字段名错配**（与 Physics 的 SetMass 同一类病）：
        --   泛化桩把所有 setter 统一存成 `_"..方法名小写`，
        --   于是 SetPlayerAge(5) 落进 `_setplayerage`，而 GetPlayerAge 读 `_age`。
        --   → GetPlayerAge() 永远返回 0，后果是**真实的**：
        --     · components/age.lua:12 用它判断是否该发成就
        --       （存活 20/35/55/70 天）—— 恒 0 会让判定每 10 秒重复成立
        --     · entityscript.lua:618 `record.age = self.Network:GetPlayerAge()`
        --       —— **玩家年龄被永久存成 0 写进存档**
        --     · widgets/uiclock.lua:152、worldresettimer.lua:175、
        --       playerdeathnotification.lua:163 的 UI 显示
        SetPlayerAge = function(self, v) self._age = v end,
        -- USERFLAGS 位掩码维护。Lua 5.1 无位运算符，用 21_bit 库。
        -- 真实用法（player_common.lua:1181）传的是**组合掩码**：
        --   RemoveUserFlag(CHARACTER_STATE_1 + CHARACTER_STATE_2 + CHARACTER_STATE_3 + ...)
        -- 所以必须按位清，不能整体赋值。
        SetUserFlag = function(self, flags)
            self._userflags = bitlib.bor(self._userflags or 0, flags)
        end,
        AddUserFlag = function(self, flag)
            self._userflags = bitlib.bor(self._userflags or 0, flag)
        end,
        RemoveUserFlag = function(self, flags)
            self._userflags = bitlib.band(self._userflags or 0, bitlib.bnot(flags))
        end,
        ClearUserFlags = function(self) self._userflags = 0 end,
        -- SetClassifiedTarget(target)：把 classified 实体的「可见目标」设为 target。
        -- 容器/背包的开关都是靠它触发的（container_replica.lua:74/118/294/302/312、
        -- inventory.lua:OnOpen/OnClose、inventory_replica.lua:147/158）。
        -- ⚠️ **Lua 侧只写不读** —— 全库 grep 不到任何 GetClassifiedTarget，
        --   它是纯 C++ 网络复制指令（决定 netvar 向谁复刻）。
        --   宿主不联网，所以如实存下来供断言，不伪造行为。
        SetClassifiedTarget = function(self, target) self._classifiedtarget = target end,
        GetClassifiedTarget = function(self) return self._classifiedtarget end,
    },
}

--=========================================================================
-- 方法名清单（从 4030 个原版文件实测提取，2026-10-12）
--=========================================================================
local METHODS = {
    AnimState = {
        "AddOverrideBuild", "AnimateWhilePaused", "AssignItemSkins",
        "BuildHasSymbol", "ClearAllOverrideSymbols", "ClearBloomEffectHandle",
        "ClearOverrideBuild", "ClearOverrideSymbol", "FastForward", "GetAddColour", "GetCurrentFacing", "GetHistoryData",
        "GetMultColour", "GetSymbolMultColour", "GetSymbolOverride",
        "GetSymbolPosition", "GetVisualBB", "Hide", "HideSymbol",
        "MakeFacingDirty", "OverrideBrightness", "OverrideItemSkinSymbol",
        "OverrideMultColour", "OverrideSkinSymbol",
        "OverrideSymbol", "Pause", "PlayAnimation", "PushAnimation", "Resume",
        "SetBank", "SetBankAndPlayAnimation",
        "SetBloomEffectHandle", "SetBrightness", "SetBuild",
        "SetClientSideBuildOverrideFlag", "SetClientsideBuildOverride",
        "SetDefaultEffectHandle", "SetDeltaTimeMultiplier",
        "SetErosionParallax", "SetErosionParams", "SetFinalOffset",
        "SetFloatParams", "SetForceSinglePass", "SetFrame", "SetHatOffset",
        "SetHighlightColour", "SetHue", "SetInheritsSortKey",
        "SetLightOverride", "SetMultColor", "SetMultColour",
        "SetOceanBlendParams", "SetPercent",
        "SetRayTestOnBB", "SetSaturation", "SetScale", "SetSkin",
        "SetSortWorldOffset", "SetSymbolAddColour",
        "SetSymbolBrightness", "SetSymbolHue",
        "SetSymbolMultColour", "SetSymbolSaturation",
        "SetTime", "SetUILightParams", "Show", "ShowSymbol", "UseColourCube",
        "UseHeadHatExchange", "UsePointFiltering",
    },

    Light = {
        "Enable", "EnableClientModulation", "GetDisableOnSceneRemoval",
        "PickNewAngle", "PickTarget", "SetColour", "SetFalloff",
        "SetIntensity", "SetRadius", "Visit", "Wait",
    },

    SoundEmitter = {
        "KillAllSounds", "KillSound", "OverrideVolumeMultiplier", "PlaySound",
        "PlaySoundWithParams", "SetVolume",
    },

    MiniMapEntity = {
        "CopyIcon", "EntityHasRestriction", "SetCanUseCache",
        "SetDrawOverFogOfWar", "SetEnabled", "SetIcon", "SetIsFogRevealer",
        "SetIsProxy", "SetPriority", "SetRenderOnTopOfMask", "SetRestriction",
    },

    Transform = {
        "ClearPredictedFacingModel", "ClearTransformationHistory",
        "GetPredictionPosition", "LoadRotation", "OffsetPosition",
        "SetCanTransform", "SetEightFaced", "SetFacing", "SetFourFaced",
        "SetFromProxy", "SetHAnchor", "SetInterpolateRotation",
        "SetMaxPropUpscale", "SetNoFaced",
        "SetOnTransform", "SetPosition", "SetPredictedEightFaced",
        "SetPredictedNoFaced", "SetPredictedSixFaced", "SetRotation",
        "SetScaleMode", "SetScissor", "SetSixFaced",
        "SetVAnchor", "TryTransformToContainer",
        "UpdateTransform",
    },

    Physics = {
        "AddAnchorCmp", "AddBoatDrag", "AddEmergencyBrakeSource",
        "AddFallingStates", "AddMagnet", "AddMast", "AddPushingStates",
        "ApplyDrag", "ApplyForce", "ApplyMagnetForce", "ApplyRowForce",
        "ApplySailForce", "CheckGridOffset", "ClearCollidesWith",
        "ClearCollisionMask", "ClearLocalCollisionMask",
        "ClearMotorVelOverride", "CloseAllSails", "ConstrainTo",
        "DoApplyForce", "ForceDropPhysics", "GetAnchorSailForceModifier",
        "GetBoatDrag", "GetDebugString", "GetForceDampening",
        "GetMaxVelocity", "GetMoveDirection", "GetNormalizedVelocities",
        "GetRudderDirection", "GetRudderTurnSpeed", "GetTargetRudderDirection",
        "GetTotalAnchorDrag", "MakeSmallObstacle", "OnDeath", "OnEntitySleep",
        "OnEntityWake", "OnLoad", "OnRemoveFromEntity", "OnSave", "OnUpdate",
        "RemoveAnchorCmp", "RemoveBoatDrag", "RemoveEmergencyBrakeSource",
        "RemoveMagnet", "RemoveMast", "SetActive", "SetCanSteeringRotate",
        "SetCapsule", "SetCollides", "SetCollisionCallback",
        "SetCollisionGroup", "SetCollisionMask", "SetCylinder", "SetDamping",
        "SetFriction", "SetHalting",
        "SetLocalCollisionMask", "SetMass", "SetMotorVel",
        "SetMotorVelExternal", "SetMotorVelOverride", "SetOnChangeToItemFn",
        "SetOnChangeToObstacleFn", "SetOnPhysicsStateChangedFn",
        "SetOnStartFallingFn", "SetOnStopFallingFn", "SetP", "SetRadius",
        "SetRestitution", "SetSphere", "SetTargetRudderDirection",
        "SetTempMass", "SetTriangleMesh", "SetVel", "Setonstartpushingfn",
        "Setonstoppushingfn", "StartUpdating", "Stop", "StopUpdating",
        "Teleport", "TeleportOffset", "TeleportRespectingInterpolation",
    },

    Network = {
        -- AddUserFlag / RemoveUserFlag / SetPlayerAge / SetClassifiedTarget
        -- 已升为 OVERRIDES 里的真实实现（见上），不再走泛化桩。
        "SetPlayerEquip", "SetPlayerSkillSelection", "SetPlayerSkin",
    },
}

--=========================================================================
-- 默认返回值：nil（大多数 setter 型方法返回 nil）
-- 少数方法真实引擎返回数字/布尔，用 DEFAULT_RETURN 覆写
--=========================================================================
local NUMERIC = {
    SetFinalOffset = 0, SetLayer = 0, SetPercent = 0, SetTime = 0,
    SetMass = 0, SetCollisionGroup = 0, SetRadius = 0, SetHeight = 0,
    SetIntensity = 0, SetFalloff = 0,
}

--- 生成一个组件桩
-- @param name     组件名（AnimState / Light / ...）
-- @param inst     所属实体
-- @param noteGap  契约外方法记录函数（真缺口）
-- @param noteStub 契约内桩调用记录函数（已知接口，桩实现）
function Stubs.Make(name, inst, noteGap, noteStub)
    local obj = {
        _kind = name,
        _enabled = false, _anim = nil, _bank = nil, _build = nil,
        _skin = "", _queue = {}, _colour = { 1, 1, 1 },
        _mass = 1, _group = 0, _mask = 0, _radius = 0, _height = 2,
        _active = true, _scale = 1, _layer = 0,
        -- ★★★ Light 的**数值**状态字段必须初始化 —— 与 Transform 的位置同一条教训。
        --   实测症状（reachability.lua 抽样，ambientlighting 修好之后露出来的下一层）：
        --       prefabs/moon_fissure.lua:59
        --         local cur_intensity = inst.Light:GetIntensity()
        --         inst.Light:SetIntensity(cur_intensity + (target - cur_intensity) * ...)
        --       ✘ attempt to perform arithmetic on local 'cur_intensity' (a nil value)
        --   真实引擎里新建的 Light 有确定的初值（未配置 = 0），
        --   所以「没 Set 过就读」必须得到 **0** 而不是 nil。
        --   _radius 上面已经有了（同为 Light 所需），这里补齐另外两个。
        --   ⇒ 通用原则：**数值型 getter 绝不能返回 nil**，
        --     因为下游多半是算术；返回 nil 只会把错误推迟到更难定位的地方。
        _intensity = 0, _falloff = 0,
        -- ★ Transform 的位置字段：**必须初始化**。
        --   元表的 __index 不拦下划线开头的键，所以未初始化的 _x 会是 nil，
        --   GetWorldPosition 就返回 nil,nil,nil，
        --   进而让 simutil 的距离计算 "attempt to perform arithmetic on nil"。
        _x = 0, _y = 0, _z = 0, _rot = 0,
    }
    obj._playing = {}
    obj._icon = nil
    -- ★ 回指实体：音频事件要能说出「是谁在响」（prefab 名）。
    --   没有这一条，事件里只有声音名，判据就没法核对「这声音来自火堆还是玩家」。
    obj._inst = inst
    -- ★ 音量/音高的**初始值必须是 1**（与真实引擎一致）。
    --   数值型 getter 返回 nil 会把错误推到下游算术里（见 _intensity 那条注释）。
    obj._volume = 1
    obj._pitch = 1
    obj._volmult = 1

    local ov = OVERRIDES[name] or {}
    local seen = {}

    -- 1) 先装语义覆写
    for k, fn in pairs(ov) do
        obj[k] = fn
        seen[k] = true
    end

    -- 2) 再装泛化桩（不与覆写冲突）
    --    ★ 区分两类记录：
    --      · 契约内方法（METHODS 表里有）→ 记 StubCalls（已知接口，桩实现）
    --      · 契约外方法（表里没有）    → 记 Gaps（真未知，需补）
    for _, m in ipairs(METHODS[name] or {}) do
        if not seen[m] then
            seen[m] = true
            local default = NUMERIC[m] or nil
            obj[m] = function(self, ...)
                if noteStub then noteStub(name .. ":" .. m) end
                local first = ...
                if first ~= nil and type(first) ~= "table" then
                    rawset(self, "_" .. m:lower(), first)
                end
                return default
            end
        end
    end

    -- 3) ★ 装饰器：让宿主模块能在桩建好之后接管它。
    --    用途：把「纯桩」升级成「真实实现」。首个用户是 AnimState ——
    --    宿主现在能解 ZipAnim 了，所以 AnimState 不必再是桩，
    --    可以用真实帧数据驱动（见 host/10_animstate.lua）。
    --    装饰器在泛化桩之后跑，因此可以覆盖它们。
    local decos = Stubs.Decorators[name]
    if decos then
        for _, fn in ipairs(decos) do
            local ok, err = pcall(fn, obj, inst, name)
            if not ok and Stubs.OnDecoratorError then
                Stubs.OnDecoratorError(name, err)
            end
        end
    end

    -- 4) metatable 兜底：任何未列出的方法也能调，不炸
    --    ⚠️ 不拦截下划线开头的键——那些是状态字段（_bank/_anim/_radius...），
    --    拦截了会让 `obj._bank` 返回函数而不是 nil，破坏外部断言。
    return setmetatable(obj, {
        __index = function(t, k)
            if type(k) ~= "string" then return nil end
            if k:match("^_") or k:match("^__") then return nil end
            if seen[k] then return nil end
            seen[k] = true
            -- 契约外方法：真缺口
            return function(self, ...)
                if noteGap then noteGap(name .. ":" .. k) end
                local first = ...
                if first ~= nil and type(first) ~= "table" then
                    rawset(t, "_" .. k:lower(), first)
                end
                return nil
            end
        end,
        __tostring = function() return "[stub " .. name .. "]" end,
    })
end

return Stubs
