--[[==========================================================================
 rt_input.lua —— 真实的 `TheInput`（P2-2 / M2）

 为什么单独一个文件
   宿主的 `TheInput` 是个空壳（`03_globals.lua`：IsKeyDown→false、GetWorldPosition→0,0,0），
   §0.2 把它列为「输入」缺口。但**不能去改宿主** —— 06-引擎复刻 的 14 入口基线
   是「保真度」的度量，改它会让基线失去意义。
   ⇒ 在实时引擎这一侧**给同一个表补上真实实现**（原地改字段，不换表对象，
     这样早先 `local TheInput = G.TheInput` 抓到的也是同一张）。

 设计
   1) 只补**原版真的会读**的那几个接口（见组件清单），其余走 `__index` 兜底：
      兜底会**记录**被调用的名字（`__rt_unknown_calls`），不静默返回 nil。
      —— 这与工程的「不静默」纪律一致：未知接口要么被看见，要么被补上。
   2) `IsControlPressed(CONTROL_*)` 由键位映射而来，**控制名是原版的**
      （CONTROL_MOVE_RIGHT / CONTROL_ACTION / CONTROL_ATTACK / CONTROL_PRIMARY…）。
   3) 数字键 → 0/1 的模拟量（GetAnalogControlValue），供原版手柄路径读。

 对外（给 rt_boot.lua 用）
   RTInput.Install(TheInputTable)   —— 补实现，返回 { set, clear, stats }
============================================================================]]
local M = {}

-- 控制名 → 键位（原版控制名，值是我们的键名）
local CONTROL_KEYS = {
    CONTROL_MOVE_RIGHT = { "right", "d" },
    CONTROL_MOVE_LEFT  = { "left",  "a" },
    CONTROL_MOVE_UP    = { "up",    "w" },
    CONTROL_MOVE_DOWN  = { "down",  "s" },
    CONTROL_ACTION     = { "space", "e" },
    CONTROL_ATTACK     = { "f" },
    CONTROL_PRIMARY    = { "mouse1" },
    CONTROL_SECONDARY  = { "mouse2" },
    CONTROL_INSPECT    = { "r" },
    CONTROL_ZOOM_IN    = { "zoomin" },
    CONTROL_ZOOM_OUT   = { "zoomout" },
    CONTROL_ROTATE_LEFT  = { "q" },
    CONTROL_ROTATE_RIGHT = { "e2" },
    CONTROL_PAUSE      = { "esc" },
    CONTROL_MAP        = { "tab" },
    CONTROL_INV_ACTION = { "i" },
}

function M.Install(TI)
    if TI == nil then TI = _G.TheInput or G.TheInput end
    if TI == nil then error("rt_input.Install: 拿不到 TheInput 表") end

    -- 输入状态：key -> bool；鼠标：x, z, down
    local state = {}
    local mouse = { x = 0, z = 0, down1 = false, down2 = false }
    local unknown = {}          -- ★ 未知接口调用记录（不静默）
    local seq = 0

    -- ★ 兜底：任何没实现的接口都返回「安全的空值」并**记账**
    local function noop(...) return nil end
    setmetatable(TI, {
        __index = function(t, k)
            unknown[k] = (unknown[k] or 0) + 1
            return noop
        end,
    })

    -- ---------- 键盘 ----------
    function TI:IsKeyDown(code)
        return state[tostring(code)] == true
    end
    function TI:IsKeyPressed(code)      -- 边沿版：调用方自己维护边沿，这里给当前态
        return state[tostring(code)] == true
    end
    function TI:IsControlPressed(control)
        local keys = CONTROL_KEYS[tostring(control)]
        if not keys then return false end
        for _, k in ipairs(keys) do
            if state[k] then return true end
        end
        return false
    end
    function TI:GetAnalogControlValue(control)
        return TI:IsControlPressed(control) and 1 or 0
    end
    function TI:IsControlSelected(control) return TI:IsControlPressed(control) end

    -- ---------- 鼠标 ----------
    function TI:IsMouseDown()      return mouse.down1 end
    function TI:IsMouse2Down()     return mouse.down2 end
    function TI:IsMouseOverWidget() return false end
    function TI:GetWorldPosition() return mouse.x, mouse.y or 0, mouse.z end
    function TI:GetScreenPos()     return mouse.x, mouse.z end
    function TI:GetWorldEntityUnderMouse() return nil end
    function TI:GetHUDEntityUnderMouse()   return nil end

    -- ---------- 手柄：明确「没有」（不是假装有） ----------
    function TI:ControllerAttached() return false end
    function TI:GetControllerID() return 0 end
    function TI:SupportsControllerFreeCamera() return false end
    function TI:ControlsHaveSameMapping() return true end

    -- ---------- 其它：给安全默认值 ----------
    function TI:GetLocalizedControl(control) return tostring(control) end
    function TI:EnableMouseFilters() end
    function TI:DisableMouseFilters() end
    function TI:EnableMouse() end
    function TI:DisableMouse() end
    function TI:Cache() end
    function TI:TryRecacheController() end
    function TI:ResolveVirtualControls() end
    function TI:OnKeyDown(fn)  _G.__rt_on_keydown = fn end
    function TI:OnKeyUp(fn)    _G.__rt_on_keyup   = fn end
    function TI:AddKeyDownHandler(control, fn)
        _G.__rt_key_handlers = _G.__rt_key_handlers or {}
        _G.__rt_key_handlers[tostring(control)] = fn
    end
    function TI:AddKeyUpHandler(control, fn)
        _G.__rt_key_handlers = _G.__rt_key_handlers or {}
        _G.__rt_key_handlers[tostring(control)] = fn
    end
    function TI:AddMoveHandler(fn) _G.__rt_move_handler = fn end
    function TI:AddZoomHandler(fn) _G.__rt_zoom_handler = fn end

    -- ---------- 对外 ----------
    local api = {}
    function api.set(key, down)
        key = tostring(key)
        state[key] = down and true or false
        if key == "mouse1" then mouse.down1 = state[key] end
        if key == "mouse2" then mouse.down2 = state[key] end
        seq = seq + 1
        -- 原版事件钩子（若有人注册过）
        local h = down and _G.__rt_on_keydown or _G.__rt_on_keyup
        if h then pcall(h, key) end
        return seq
    end
    function api.set_mouse(x, z)
        mouse.x, mouse.z = tonumber(x) or 0, tonumber(z) or 0
    end
    function api.clear()
        for k in pairs(state) do state[k] = nil end
        mouse.down1, mouse.down2 = false, false
    end
    function api.state() return state end
    function api.mouse() return mouse end
    function api.seq() return seq end
    --- ★ 未知接口的调用记录：**这是本文件的重点之一** —— 让人看见「还有谁在读我没实现的面」
    function api.unknown_calls()
        local out = {}
        for k, v in pairs(unknown) do out[#out + 1] = k .. "×" .. v end
        table.sort(out)
        return out
    end
    function api.controls() return CONTROL_KEYS end

    api.TI = TI          -- ★ 把这张表也暴露出去（测试/调试要直接调它）
    api.controls_map = CONTROL_KEYS
    M.api = api
    M.TI = TI
    return api
end

return M
