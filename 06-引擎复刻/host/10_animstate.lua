--[[
==============================================================================
 10_animstate.lua —— AnimState 的**真实实现**（不再只是桩）

 背景
    宿主此前把 AnimState 当纯桩处理：PlayAnimation 记为「未实现」，
    _anim 只存个字符串。这导致状态机虽然跑得对，但**看不到任何画面**。

    现在 ZipAnim 已经能完整解析了（见 tools/ 与 ZipAnim解析报告.md），
    所以可以把导出的真实帧数据接进来，让：
        PlayAnimation("idle_loop") → 真的有一套逐帧的绘制指令
        SetTime(t)                 → 真的按帧率翻页
        GetCurrentAnimationFrame() → 真的返回当前帧号
        GetDrawList()              → 返回这一帧要画的图块（符号 + UV + 变换）

 数据来源
    tools/export_anim.py 把 DST 的 anim.bin + build.bin 合并导出成 Lua 表：
        anim_data/<build名>.lua
    合并是必要的：DST 把「贴图(build)」与「动画(anim)」拆成两个 zip，
    两边用同一套符号哈希相互指代。

 设计取舍
    · 懒加载：只在 SetBuild/首次 PlayAnimation 时才 loadfile，避免启动就吃几十 MB
    · 缺数据不报错：找不到对应 anim_data 时**退回桩行为**，
      这样没有导出数据的 prefab 仍能正常跑（保证不破坏既有五入口）
==============================================================================
]]

local M = {}

local cache = {}        -- build 名 → 导出表
local missing = {}      -- 记录哪些 build 没有数据（只警告一次）

-- ★★ 「GetDrawList 取不到数据」的**按 build 计次**表，必须在模块加载时就建好，
--   **不能等到失败分支里懒建**。
--   踩过的坑：懒建时，GetDrawList 的失败分支顺序是
--       ensure() → OnMissing 触发 → （转发 Core.MissingBuildHits = AS.MissingHits）
--                 → 回到 GetDrawList 才 `M.MissingHits = M.MissingHits or {}`
--   而转发那一步带 `AS.MissingHits ~= nil` 的前置条件
--   ⇒ 首次失败时转发被跳过；OnMissing 又因为 `missing[name]` 已置位而**永不重发**
--   ⇒ `Core.MissingBuildHits` 永远不存在。
--   症状：报告里「取不到 N 次」恒为 0，而实际可能不为 0 —— **指标自己骗自己**。
M.MissingHits = {}

--=========================================================================
-- 载入导出数据
--=========================================================================
function M.LoadBundle(name)
    if name == nil then return nil end
    if cache[name] ~= nil then
        return cache[name] ~= false and cache[name] or nil
    end
    local path = "anim_data/" .. name .. ".lua"
    local f = loadfile(path)
    if not f then
        cache[name] = false
        -- ★★ 记**请求次数**，不只记「缺了哪些」。
        --   「缺了哪些」只说明导出清单不全；「被请求了几次」才说明
        --   **这件事对画面有多大影响** —— 一个从未被请求的 build 缺数据无所谓，
        --   一个每帧都被请求的 build 缺数据意味着那个动画**根本画不出来**。
        --   （P3-1 的判断依据：先量代价，再决定值不值得补导。）
        --
        --   ⚠️ 原来走 Core.MissingBuildCount 那条路是**记不到次数**的：
        --   OnMissing 每个 build 只触发一次（下面 missing[name] 那个门），
        --   所以那个计数恒为 1，看着像次数其实是「缺了」这个布尔值。
        --   这里直接记到 Core.MissingBuildHits，绕开那道门。
        if not missing[name] then
            missing[name] = true
            -- 只记一次，避免刷屏；这是「有宿主但没导出数据」，不是错误
            if M.OnMissing then M.OnMissing(name, path) end
        end
        return nil
    end
    local ok, d = pcall(f)
    if not ok then
        cache[name] = false
        if M.OnError then M.OnError(name, d) end
        return nil
    end
    -- ★ 把符号哈希补进每个符号条目。
    --   导出的 anim_data 里符号表是**按哈希建键**的（`[1690368943] = {name="swap_hat",...}`），
    --   哈希本身不在值里。而 GetDrawList 的元素需要把哈希回传给渲染端
    --   （播放器的 build JSON 也按哈希建键，且覆盖可能把符号**换名**）。
    --   真实引擎里符号本来就带 hash（build.bin 里就是按 hash 索引的）。
    if type(d) == "table" and type(d.symbols) == "table" then
        for h, s in pairs(d.symbols) do
            if type(s) == "table" and s.hash == nil then
                s.hash = tonumber(h) or h
            end
        end
    end
    cache[name] = d
    return d
end

function M.HasBundle(name)
    return M.LoadBundle(name) ~= nil
end

function M.ListBundles()
    local out = {}
    for k, v in pairs(cache) do
        if v then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

--=========================================================================
-- 给一个 AnimState 实例装真实行为
--=========================================================================
function M.Decorate(as, inst)
    -- ---- 内部状态 ----
    as._inst = inst          -- ★ 需要向实体回推 animover / animqueueover
    as._cur = nil            -- 当前动画表
    as._curName = nil
    as._frame = 1
    as._time = 0
    as._loop = false
    as._playing = {}
    as._real = false         -- 是否拿到了真实数据
    as._queue = {}           -- ★ 动画队列（PushAnimation 排队）
    as._fired = false        -- ★ animover 是否已为「当前动画」发过
    as._queuefired = false   -- ★ animqueueover 是否已发过（防止每 tick 刷屏）

    -- ★★ 符号覆盖（换装 / 皮肤）系统 —— 见本文件末尾「符号覆盖系统」一节
    as._overrides = {}       -- [符号名] = { build=覆盖来源 build, sym=替换符号名 }
    as._ov_builds = {}       -- [build 名] = true，登记可用的覆盖 build
    -- ★★ 「被 OverrideSymbol 自动登记」的账本：[build 名] = 引用它的符号集合。
    --   为什么需要它：宿主的 OverrideSymbol 会顺手把 build 登记进 _ov_builds
    --   （原版 C++ 似乎也这么做，依据是 skinner.lua:300 直接
    --    `anim_state:OverrideSymbol(sym, "wonkey", sym)` 而**没有**先 AddOverrideBuild）。
    --   但原版 `_onunequip` 只调 `ClearOverrideSymbol("swap_hat")`，
    --   ⇒ `_ov_builds` 里的 build 永远不会被撤掉
    --   ⇒ GetDrawList 的回退路径仍旧从它取几何
    --   ⇒ **卸下帽子后帽子的几何还留在画面上**。
    --   实测：_overrides 5→6→5（正确清除），而 _ov_builds 22→23→**23**（没撤）。
    --   所以记下「谁自动登记的」，在最后一个引用者被清掉时一并撤销。
    as._ov_auto = {}         -- [build 名] = { [符号名] = true }
    as._sym_hidden = {}      -- [符号名] = true，被 HideSymbol 藏起来的符号
    as._skin = nil           -- SetSkin(skin, default_build) 的 skin 名
    as._skin_build = nil     --   ↑ 的 default_build
    as._ov_nameidx = {}      -- [build 名] = { [符号名] = 符号表 }（懒建索引）
    as._ov_by_hash = nil     -- [符号哈希] = { build=, sym= }（懒建；登记表变动即失效）

    -- ★ 前向声明：下面几个方法（OverrideSymbol 等）在定义时就要引用它们，
    --   而 Lua 的 `local function` 是「定义处才生效」—— 不加这句前向声明，
    --   早期闭包会把名字解析成**全局**（= nil），调用即炸。

    --- 尝试为当前 build 装载数据
    local function ensure()
        if as._real then return true end
        local d = M.LoadBundle(as._build)
        if not d then return false end
        as._data = d
        as._real = true
        return true
    end
    as._ensure = ensure

    --- ★ 把引擎事件回推给实体。
    --   真实引擎里 AnimState 是 C++ 的，它在动画播完时会
    --   `PushEvent("animover")`（单条动画结束）与
    --   `PushEvent("animqueueover")`（队列清空）。
    --   状态图大量依赖它们来「走出」一次性状态，例如
    --   commonstates.lua:753 的 `walk_stop` 只有 `EventHandler("animqueueover", idleonanimover)`
    --   —— 没有这两个事件，生物会在 walk_stop 里**永久卡死**（实测：猪人走完一次就再也不动）。
    local function fire(evt)
        local e = as._inst
        if e ~= nil and type(e.PushEvent) == "function" then
            pcall(e.PushEvent, e, evt)
        end
    end

    -- ---- SetBuild / SetBank ----
    -- 真实引擎里 build 决定贴图、bank 决定动画集。
    -- 宿主的导出表是按 build 名命名的（同一生物的 anim 与 build 已合并），
    -- 所以两者都试一遍。
    local function remember(v)
        if type(v) ~= "string" then return end
        if M.LoadBundle(v) then as._build = v end
    end
    as.SetBuild = function(self, v) remember(v); self._build = v; self._real = false end
    as.SetBank = function(self, v) remember(v); self._bank = v; self._real = false end

    -- ======================================================================
    -- 符号覆盖（换装 / 皮肤）系统
    --
    -- 契约全部从原版 Lua 的**实际用法**反推，不猜：
    --   OverrideSymbol(sym, build, replace_sym)
    --       把当前 build 里的 sym 换成 build 里的 replace_sym。
    --       三处实证：
    --         skinner.lua:307   OverrideSymbol(sym, "wonkey", sym)      ← 猴化诅咒
    --         mightygym.lua:144 OverrideSymbol(slot, build, symbol)     ← 举重配重块
    --         oceanfishingrod:185 OverrideSymbol("lure", build, symbol) ← 鱼饵
    --   GetSymbolOverride(sym) → (build, replace_sym)，无覆盖返 nil。
    --       最热的调用点是**脚步声**：
    --         player_common_extensions.lua:1277
    --           local skin_sfx = CLOTHING_SFX[... GetSymbolOverride("foot")]
    --       FootstepOverrideFn 每次落地都调一次 → world.lua 2400 tick 里 182 次。
    --       这是真实的皮肤音效路径：换装后脚步声该变，不是纯视觉。
    --   ClearOverrideSymbol(sym) / ClearAllOverrideSymbols()
    --       撤销覆盖，符号回落到当前 build 的版本。
    --   AddOverrideBuild(build) / ClearOverrideBuild(build)
    --       登记/注销一个「可提供覆盖符号」的 build。
    --       ClearOverrideBuild 会连带撤掉该 build 带来的全部覆盖
    --       （beefalo.lua:283 用它撤销 personality build）。
    --   ShowSymbol(sym) / HideSymbol(sym) —— 符号显隐，与覆盖正交。
    --   BuildHasSymbol(sym) —— 当前 build（含已登记覆盖 build）有没有这个符号。
    --       skinner.lua:69 用它判断「是不是 legacy 无 torso_pelvis 的角色」。
    --   SetSkin(skin, default_build) —— 皮肤模式。
    --       skinner.lua:51 的 base_skin 对默认皮肤就等于 prefab 的 build 名，
    --       所以 skin 名本身可以当 build 名用（skinner.lua:337
    --       `OverrideSkinSymbol("torso", base_skin, ...)` 正是这么干的）。
    --
    -- ★ 为什么 SetBuild **不**清覆盖：
    --   ClearOverrideBuild 与 ClearAllOverrideSymbols 作为**独立方法**存在 ——
    --   如果 SetBuild 已经清了，这两个方法就是冗余的。反证 SetBuild 不清。
    --   （这也保住 beefalo：先 AddOverrideBuild 登记 tendency build，
    --     之后 world.lua 再 SetBuild 换图集，覆盖不该丢。）
    -- ======================================================================
    -- ★ 前向声明：下面几个方法（OverrideSymbol 等）在定义时就要引用它们，
    --   而 Lua 的 `local function` 是「定义处才生效」—— 不加前向声明，
    --   早期闭包会把名字解析成**全局**（= nil），调用即炸。
    local ov_name_index, build_name_of, ov_symbol, ov_by_hash
    ov_name_index = function(build)
        local idx = as._ov_nameidx[build]
        if idx ~= nil then return idx end
        local d = M.LoadBundle(build)
        if d == nil then
            as._ov_nameidx[build] = false
            return nil
        end
        idx = {}
        for h, s in pairs(d.symbols) do
            -- ★ 同时按**名字**和**哈希**建索引。
            --   只按名字不够：saddle_basic.zip 的 build.bin 里 hash_to_name
            --   **没有** swap_saddle 这一项（导出出来 name=None），
            --   但 OverrideSymbol("swap_saddle", "saddle_basic", ...) 是真实调用
            --   （rideable.lua:157 / rider.lua:109）。
            --   所以名字查不到时，用 hash(名字) 反查哈希键 —— 两者等价。
            if s.name then idx[s.name] = s end
            idx[h] = s
        end
        as._ov_nameidx[build] = idx
        return idx
    end
    as._ov_name_index = ov_name_index

    --- 取「某个 build 里名叫 name 的符号表」，找不到返 nil
    -- build 可以是名字（常见）或哈希（OverrideSymbol 也收哈希）。
    -- 收到哈希时靠「已装载 bundle 的 哈希→名字」反查 —— 反查不到就放弃这个覆盖
    -- （保留原符号，不静默吞掉整个元素）。
    local _hash2name_cache = {}
    build_name_of = function(build)
        if type(build) == "string" then return build end
        if type(build) ~= "number" or not HASH then return nil end
        if _hash2name_cache[build] ~= nil then
            return _hash2name_cache[build] or nil
        end
        local found = nil
        for bname, d in pairs(cache) do
            if d then
                for _, s in pairs(d.symbols) do
                    if s.name and HASH(s.name) == build then found = bname; break end
                end
            end
            if found then break end
        end
        _hash2name_cache[build] = found or false
        return found
    end
    as._build_name_of = build_name_of

    local ov_symbol
    ov_symbol = function(build, name)
        local bname = build_name_of(build)
        if bname == nil then return nil end
        local idx = ov_name_index(bname)
        -- ⚠️ ov_name_index 失败时缓存的是 **false**（不是 nil），
        --    所以必须用 `not idx` 判空 —— 写 `idx == nil` 会漏掉 false，
        --    接着就去索引一个布尔值，直接炸。
        if not idx then return nil end
        -- 先按名字；名字查不到再按 hash(名字) —— saddle_basic 的 build.bin 里
        -- hash_to_name 缺 swap_saddle 这一项（导出 name=None），但调用方传的是名字。
        local s = idx[name]
        if s ~= nil then return s end
        if type(name) == "string" and HASH then
            return idx[HASH(name)]
        end
        return nil
    end

    --- 当前符号实际由哪个 build 提供（供 GetSymbolOverride / 绘制用）
    --   优先级：显式覆盖 > 皮肤 build > 当前 build
    local function resolve_symbol(name)
        local ov = as._overrides[name]
        if ov ~= nil then return ov.build, ov.sym end
        if as._skin ~= nil and as._skin ~= "" then return as._skin, name end
        return as._build, name
    end
    as._resolve_symbol = resolve_symbol

    -- 把「build 参数」归一成 (名字, 哈希)。
    -- OverrideSymbol 两种传法都见过：
    --   · 传名字（skin 系统）—— skinner.lua:307 `OverrideSymbol(sym, "wonkey", sym)`
    --   · 传哈希（回填场景）—— wx78_backupbody.lua:1115
    --       `local build, sym = GetSymbolOverride(v)` 拿到来又传回去
    -- 所以入参兼容两者；内部一律留名字（宿主要靠名字去 loadfile 拿顶点/UV），
    -- 同时留哈希（GetSymbolOverride 要返回哈希，见下）。
    local HASH = rawget(_G, "hash")
    local function to_hash(v)
        if type(v) == "number" then return v end
        if type(v) == "string" and HASH then return HASH(v) end
        return nil
    end
    as._to_hash = to_hash

    as.OverrideSymbol = function(self, symbol, build, replace_symbol)
        if symbol == nil then return end
        if build == nil then
            -- 真实引擎里 build 传 nil = 撤销（skinner 的 fixup 分支就这么用）
            self._overrides[symbol] = nil
            return
        end
        local bname = type(build) == "string" and build or nil
        local sname = type(replace_symbol) == "string" and replace_symbol
                      or (replace_symbol == nil and type(symbol) == "string" and symbol)
                      or nil
        self._overrides[symbol] = {
            build = bname or build,                 -- 名字优先（宿主要靠它取数据）
            build_hash = to_hash(build),            -- 传入是哈希时就地用
            sym = sname or replace_symbol or symbol,
            sym_hash = to_hash(replace_symbol or symbol),
        }
        -- OverrideSymbol 会自动把 build 登记为可用覆盖 build
        -- （skinner.lua:307 的 "wonkey" 就没先 AddOverrideBuild）
        if bname and not self._ov_builds[bname] then
            self._ov_builds[bname] = true
            self._ov_by_hash = nil      -- 登记表变了 → 哈希缓存失效
        end
        -- 记进「自动登记」账本（供 ClearOverrideSymbol 成对撤销）
        if bname then
            local refs = self._ov_auto[bname]
            if refs == nil then refs = {}; self._ov_auto[bname] = refs end
            refs[symbol] = true
        end
    end
    as.OverrideSkinSymbol = as.OverrideSymbol
    as.OverrideItemSkinSymbol = as.OverrideSymbol

    -- ★ 返回**哈希**而不是名字 —— 这是被两个独立调用点逼出来的：
    --   ① clothing.lua:11765 的 CLOTHING_SFX 用数字键：
    --        [0x7BB765F7] = { -- feet_horseshoe ... }
    --      而 player_common_extensions.lua:1277 是
    --        CLOTHING_SFX[... GetSymbolOverride("foot")]
    --      → 第一返回值必须是个数字，否则这张表永远查不中。
    --      已实证 sdbm("feet_horseshoe") == 0x7BB765F7（67/67 全中，见 03_globals.lua）。
    --   ② balloon_held_child.lua:46 `inst._swap_build:set(swap_build or 0)`
    --      塞进的是 netvar，回退值写 0 → 也说明是数字。
    --   反过来 OverrideSymbol 却收名字（skinner 传 "wonkey"）——
    --   所以两边都必须容得下两种形态，见上面的 to_hash。
    as.GetSymbolOverride = function(self, symbol)
        local ov = self._overrides[symbol]
        if ov ~= nil then
            return ov.build_hash, ov.sym_hash
        end
        -- 皮肤模式：skin 名对默认皮肤就等于 build 名，语义上等价
        if self._skin ~= nil and self._skin ~= "" then
            return to_hash(self._skin), to_hash(symbol)
        end
        return nil
    end

    -- ★ 清覆盖时必须**成对**撤掉「自动登记」的 build。
    --   判据：这个 build 只被刚清掉的那个符号引用 ⇒ 说明它是随这次覆盖进来的 ⇒ 撤。
    --   若还有别的符号在用它（或它是显式 AddOverrideBuild 登记、不在 _ov_auto 里），则保留。
    local function drop_auto_build_for(self, symbol)
        local ov = self._overrides[symbol]
        local bname = ov ~= nil and ov.build or nil
        if type(bname) ~= "string" then return end
        local refs = self._ov_auto[bname]
        if refs == nil then return end          -- 不是自动登记的（显式 AddOverrideBuild）→ 不动
        refs[symbol] = nil
        if next(refs) == nil then
            self._ov_auto[bname] = nil
            self._ov_builds[bname] = nil
            self._ov_by_hash = nil              -- 登记表变了 → 哈希缓存失效
        end
    end

    -- ★ OverrideShade(shade) —— 覆盖「暗面着色系数」。
    --   调用方：components/sheltered_replica.lua:11/36/72 ——
    --     躲在棚子下的实体用 SHELTERED_SHADE 压暗，出来时 OverrideShade(1) 还原。
    --   原先它在桩名单里，一调用就静默返回 nil ⇒ **「躲在棚下会变暗」这个
    --   视觉反馈完全失效**，而画面照常渲染，看不出任何异常。
    --   语义：存成 AnimState 上的数值，渲染端乘到顶点色上；
    --   `nil` 参数按原版语义当作「还原为 1」。
    -- ★ SetAddColour(r, g, b, a) —— **加色**（不是乘法染色）。
    --   燃烧时 burnable.lua 会反复给它加橙色，让实体整体发红光
    --   （实测一次 burn.lua 就调了 25 次，是火焰视觉的主要来源）。
    --   它与 OverrideMultColour 的区别：后者是**相乘**，这个是**相加**，
    --   所以叠在暗部上的效果完全不同 —— 不能拿其中一个冒充另一个。
    --   原先在桩名单里 ⇒ 一调用就返回 nil ⇒ **烧着的树看不出在烧**。
    as.SetAddColour = function(self, r, g, b, a)
        self._addcolour = { r or 0, g or 0, b or 0, a or 1 }
        return self._addcolour
    end
    as.GetAddColour = function(self)
        return self._addcolour and self._addcolour[1], self._addcolour and self._addcolour[2],
               self._addcolour and self._addcolour[3], self._addcolour and self._addcolour[4]
    end
    as.ClearAddColour = function(self) self._addcolour = nil end

    -- ★ SetLayer(n) / GetLayer —— 渲染层号。
    --   DST 的贴图按 layer 叠放：同一实体内 layer 大的压在小的上面
    --   （「帽子在头前」这类效果就靠它）。原为桩 ⇒ layer 恒 0，
    --   所有部件被当成同一层 ⇒ 叠放次序由几何顺序决定，**会画错**。
    as.SetLayer = function(self, n)
        self._layer = n or 0
        -- 符号表里的 layer 也同步更新（渲染端读的是这一份）
        local d = self._data
        if d ~= nil and d.symbols ~= nil and self._build then
            local syms = d.symbols[self._build]
            if syms ~= nil then
                for _, s in pairs(syms) do s.layer = self._layer end
            end
        end
        return self._layer
    end
    as.GetLayer = function(self) return self._layer or 0 end

    -- ★ SetSortOrder(n) —— **跨实体**的绘制次序。
    --   与 layer 的区别：layer 管「实体内」，sortorder 管「实体间」——
    --   比如掉落物要压在生物上面。原为桩 ⇒ 排序全部退化成「插入顺序」。
    as.SetSortOrder = function(self, n)
        self._sortorder = n or 0
        return self._sortorder
    end
    as.GetSortOrder = function(self) return self._sortorder or 0 end

    -- ★ SetSymbolLightOverride(sym, value) —— 覆盖单个符号的光照。
    --   原为桩。存成 [符号名] = value，渲染端按符号查。
    as.SetSymbolLightOverride = function(self, sym, value)
        if sym == nil then return end
        self._sym_light = self._sym_light or {}
        self._sym_light[sym] = value
    end
    as.GetSymbolLightOverride = function(self, sym)
        return self._sym_light ~= nil and self._sym_light[sym] or nil
    end

    -- ★ SetOrientation(ori) —— 镜像朝向（左右翻转）。
    --   与 Transform:SetTwoFaced 是**两套机制**：那是 C++ 侧的精灵镜像，
    --   这个是 AnimState 内部记录、朝向变化时靠它决定 UV 是否翻转。
    --   原为桩 ⇒ 实体左右转身时贴图**不跟着翻**。
    as.SetOrientation = function(self, ori)
        if ori == nil then self._orientation = not self._orientation
        else self._orientation = not not ori end
        return self._orientation
    end
    as.GetOrientation = function(self) return self._orientation and true or false end

    -- ★ ClearSymbolBloom(sym) —— 取消某个符号的辉光。
    --   与 SetSymbolBloom 成对；原为桩 ⇒ bloom 只加不清。
    as.ClearSymbolBloom = function(self, sym)
        if sym == nil or self._bloom == nil then return end
        self._bloom[sym] = nil
        if next(self._bloom) == nil then self._bloom = nil end
    end
    as.SetSymbolBloom = function(self, sym, level)
        if sym == nil then return end
        self._bloom = self._bloom or {}
        self._bloom[sym] = level or 0
    end
    as.GetSymbolBloom = function(self, sym)
        return self._bloom ~= nil and self._bloom[sym] or nil
    end

    -- ★ SetHaunted(v) —— 闹鬼状态（影响动画与材质）。原为桩。
    as.SetHaunted = function(self, v)
        if v == nil then self._haunted = not self._haunted
        else self._haunted = not not v end
        return self._haunted
    end
    as.IsHaunted = function(self) return self._haunted and true or false end

    as.OverrideShade = function(self, shade)
        if shade == nil then self._shade = 1 else self._shade = shade end
        return self._shade
    end
    as.GetShade = function(self) return self._shade or 1 end

    as.ClearOverrideSymbol = function(self, symbol)
        -- 先按「当前覆盖」撤自动登记的 build，再清覆盖本身
        drop_auto_build_for(self, symbol)
        self._overrides[symbol] = nil
    end

    as.ClearAllOverrideSymbols = function(self)
        -- 对每个被清的符号都走一遍成对撤销（不能只把表清空）
        for sym in pairs(self._overrides) do
            drop_auto_build_for(self, sym)
        end
        self._overrides = {}
    end

    as.AddOverrideBuild = function(self, build)
        if type(build) == "string" then
            if not self._ov_builds[build] then
                self._ov_builds[build] = true
                -- 登记表变了 → 「哈希→符号」缓存失效（下面 GetDrawList 用）
                self._ov_by_hash = nil
            end
        end
    end

    -- ★ 「按哈希在登记的 override build 里找符号」—— 这才是 AddOverrideBuild 的
    --   真正用途，此前漏了：
    --     真实引擎里，动画帧的元素按**符号哈希**引用符号，而这个哈希**不一定
    --     在当前 build 里**。AddOverrideBuild 登记的那些 build 就是用来补这批
    --     「base build 没有的符号」的。
    --   实证（_out/json/*.json 全量统计）：
    --     wilson      动画引用了 **12** 个不在 wilson build 里的符号哈希
    --                （swap_hat / SWAP_BODY / skirt / arm_lower_cuff /
    --                  swap_object / BEARD / tail ... 全是装备槽）
    --     beefalo_build 引用了 4 个（其中 0x85462241 就在 beefalo_fx.zip 里）
    --   旧实现只覆盖「base build 里已有的符号」，这 12+4 个元素被**静默丢弃** ——
    --   画面缺件但不报错，正是最难发现的那类 bug。
    --   ⚠️ 遍历顺序必须确定：pairs(_ov_builds) 的顺序不确定，多个 build 含同一
    --      哈希时会给出不同结果。按名字排序后逐個找，保证可复现。
    ov_by_hash = function()
        if as._ov_by_hash ~= nil then return as._ov_by_hash end
        local names = {}
        for b in pairs(as._ov_builds) do names[#names + 1] = b end
        table.sort(names)
        local idx = {}
        for _, b in ipairs(names) do
            local d = M.LoadBundle(b)
            if d then
                for h, s in pairs(d.symbols) do
                    if idx[h] == nil then idx[h] = { build = b, sym = s } end
                end
            end
        end
        as._ov_by_hash = idx
        return idx
    end
    as._ov_by_hash_fn = ov_by_hash

    as.ClearOverrideBuild = function(self, build)
        if type(build) ~= "string" then return end
        self._ov_builds[build] = nil
        self._ov_by_hash = nil          -- 登记表变了 → 缓存失效
        -- 连带撤掉该 build 带来的全部覆盖。
        -- ⚠️ 覆盖里的 build 可能是名字也可能是哈希（OverrideSymbol 两种都收），
        --   所以两边都比一遍，不能只比名字。
        local bh = to_hash(build)
        for sym, ov in pairs(self._overrides) do
            if ov.build == build or (bh ~= nil and ov.build_hash == bh) then
                self._overrides[sym] = nil
            end
        end
    end

    as.ShowSymbol = function(self, symbol)
        if symbol ~= nil then self._sym_hidden[symbol] = nil end
    end
    as.HideSymbol = function(self, symbol)
        if symbol ~= nil then self._sym_hidden[symbol] = true end
    end

    -- Show/Hide 是**双义**的：带符号名 = ShowSymbol/HideSymbol，
    -- 不带参 = 整个 AnimState 显隐（pighouse 的开关灯就用后者）。
    local base_show = as.Show
    local base_hide = as.Hide
    as.Show = function(self, symbol, ...)
        if symbol ~= nil then
            self._sym_hidden[symbol] = nil
            return
        end
        return base_show(self, ...)
    end
    as.Hide = function(self, symbol, ...)
        if symbol ~= nil then
            self._sym_hidden[symbol] = true
            return
        end
        return base_hide(self, ...)
    end

    as.BuildHasSymbol = function(self, symbol)
        if symbol == nil then return false end
        if ensure() then
            for _, s in pairs(self._data.symbols) do
                if s.name == symbol then return true end
            end
        end
        for b in pairs(self._ov_builds) do
            if ov_symbol(b, symbol) ~= nil then return true end
        end
        return false
    end

    -- ★ SetClientsideBuildOverride(name, build, build2)
    --   真实语义：**仅客户端**的 build 替换（"insane" 状态下换成怪物外形）。
    --   调用点：prefabs/bunnyman.lua:384、corpses_defs.lua:679/680/870
    --     `AnimState:SetClientsideBuildOverride("insane", "rabbit_build", "beard_monster")`
    --   第一个参数是**状态名**（不是符号名），后两个是 build 名。
    --   宿主是单机、服务端即客户端，所以语义上等价于「按状态切 build」——
    --   记进 _ov_by_state，GetDrawList 在 build 为该状态时取它。
    as.SetClientsideBuildOverride = function(self, state, build, build2)
        self._ov_by_state = self._ov_by_state or {}
        self._ov_by_state[state] = { build = build, build2 = build2 }
    end
    as.ClearClientsideBuildOverride = function(self, state)
        if self._ov_by_state then self._ov_by_state[state] = nil end
    end

    -- 皮肤模式。skin 名对默认皮肤 == prefab 的 build 名
    -- （skinner.lua:473 `base_skin = ... or default_build or self.inst.prefab`）
    as.SetSkin = function(self, skin, default_build)
        self._skin = skin or ""
        self._skin_build = default_build
    end

    -- IsSkinBuild(build)：这个 build 是不是「皮肤 build」。
    -- 唯一调用点 wx78_backupbody.lua:1114 —— WX-78 备份体要复制建造者的
    -- 皮肤，于是先问一句「这是皮肤还是普通 build」，再决定走
    -- OverrideSkinSymbol 还是 OverrideSymbol。
    -- 宿主能观察到的最小充要集：SetSkin 登记过的 skin 名。
    as.IsSkinBuild = function(self, build)
        if build == nil then return false end
        if type(build) == "number" then return false end
        return self._skin ~= nil and self._skin ~= "" and build == self._skin
    end

    -- ---- 老一代「符号交换」机制 ----
    -- 与 OverrideSymbol 是两套东西（exchange 是按帧号成对换）。
    -- 宿主只做簿记，不参与绘制 —— 当前没有一个入口依赖它的绘制结果，
    -- 但 skinner.lua:55 每帧都会调 ClearSymbolExchanges()，必须存在。
    as._exchanges = {}
    as.ClearSymbolExchanges = function(self) self._exchanges = {} end
    as.SetSymbolExchange = function(self, sym, frame, alt_sym, alt_frame)
        self._exchanges[sym] = { frame = frame, sym = alt_sym, frame2 = alt_frame }
    end
    as.SetMultiSymbolExchange = function(self, sym, exchanges) end
    as.UseHeadHatExchange = function(self, on) self._headhat_exchange = on end

    -- ---- 播放 ----
    -- ★★ 没有导出数据时，**不能**让动画「永不结束」
    --
    --   真实引擎里每条动画都有真实时长，播完会 `PushEvent("animover")`。
    --   而状态图里大量状态**只靠 animover 这一个出口**：
    --     SGwilson.lua:11668  run_stop 的 events 只有
    --         EventHandler("animover", function(inst)
    --             if inst.AnimState:AnimDone() then inst.sg:GoToState("idle") end
    --         end)
    --   宿主此前对「没有 anim_data 的 build」把 `_nframe` 留成 nil，
    --   于是 `_tick` 直接 return、永不回推 animover ——
    --   **生物一旦进入这类状态就永久卡死**。
    --   实测：真实玩家 wilson（未导出动画）跑到第 600 tick 进入 run_stop 后再也不动。
    --
    --   做法：把「无数据」投影成一条**合成动画**（15 帧 @30fps = 0.5 秒），
    --   这样 `_tick` / `AnimDone` / `GetCurrentAnimationLength` 全部照常工作，
    --   非循环动画播完照样回推 animover，事件链不断。
    --   绘制列表仍返回 nil（没有真实帧可画），所以不会画出错误画面。
    --   ⚠️ 有导出数据的 build 完全不经过这条分支，行为零影响。
    local FALLBACK_FRAMES = 15
    local FALLBACK_RATE = 30

    local function applyAnim(self, name, loop)
        self._curName = name
        self._loop = loop and true or false
        self._frame = 1
        self._time = 0
        self._fired = false
        self._queuefired = false      -- ★ 新动画开始 → 允许下一次「队列播完」事件
        if ensure() then
            local a = self._data.anims[name]
            self._cur = a or nil
            if a then
                self._anim = name
                self._playing[name] = true
                self._nframe = #a.frames
                self._rate = a.rate or 30
                self._synthetic = nil
                return true
            end
        end
        -- 没有数据：保持桩语义（记 _anim）+ 合成时长，保证 animover 仍会来
        self._cur = nil
        self._anim = name
        self._nframe = FALLBACK_FRAMES
        self._rate = FALLBACK_RATE
        self._synthetic = true
        return false
    end

    as.PlayAnimation = function(self, name, loop)
        self._queue = {}
        return applyAnim(self, name, loop)
    end

    -- ★ PushAnimation 是**排队**：不打断当前动画，等它播完再播。
    as.PushAnimation = function(self, name, loop)
        local q = self._queue
        if q == nil then q = {}; self._queue = q end
        q[#q + 1] = { name = name, loop = loop and true or false }
    end

    as.SetAnimation = as.PlayAnimation
    as.PlayAnimationEx = as.PlayAnimation

    -- ---- 时间与帧 ----
    as.GetCurrentAnimationLength = function(self)
        return self._nframe and (self._nframe / (self._rate or 30)) or 0
    end
    as.GetCurrentAnimationFrame = function(self)
        return self._frame or 1
    end
    as.GetCurrentAnimationTime = function(self)
        return self._time or 0
    end
    as.SetTime = function(self, t)
        self._time = t or 0
        if self._nframe and self._rate then
            local f = math.floor(self._time * self._rate) + 1
            if self._loop then
                f = ((f - 1) % self._nframe) + 1
            else
                f = math.max(1, math.min(self._nframe, f))
            end
            self._frame = f
        end
    end
    as.SetFrame = function(self, f)
        if self._nframe then
            self._frame = math.max(1, math.min(self._nframe, f or 1))
            self._time = (self._frame - 1) / (self._rate or 30)
        end
    end
    as.IsCurrentAnimation = function(self, name)
        return self._curName == name
    end
    as.AnimDone = function(self)
        if not self._nframe then return true end
        return self._frame >= self._nframe and not self._loop
    end

    -- ---- 每 tick 推进 ----
    -- 由 Sim.Step 调用（宿主没有渲染循环，所以由仿真循环代劳）
    as._tick = function(self, dt)
        if not self._nframe or self._nframe <= 0 then return end
        self._time = (self._time or 0) + dt
        local f = math.floor(self._time * (self._rate or 30)) + 1

        if self._loop then
            self._frame = ((f - 1) % self._nframe) + 1
            return
        end

        if f <= self._nframe then
            self._frame = f
            return
        end

        -- 一次性动画播完：停在最后一帧
        self._frame = self._nframe

        -- ① 首次播完 → 补发 animover（只发一次）
        if not self._fired then
            self._fired = true
            local played = self._curName
            fire("animover")
            -- ★ 状态图**可能**在 animover 处理里同步切了状态（= 重新 PlayAnimation）。
            --   那时 _curName 已变，本次不该再动队列 —— 新动画已由 applyAnim 接管。
            if self._curName ~= played then return end
        end

        -- ② ★★ 队列消费：必须在**每一次**「动画已播完」时检查，绝不能放在
        --    `if self._fired then return end` 之后。
        --
        --    为什么（这是一个真实的时序 bug，由 SGspider 暴露）：
        --      状态图切状态是**刻末批处理**（stategraph.lua:1506 把事件塞进
        --      `bufferedevents`，由 SGManager:UpdateEvents 在本帧最后统一处理，
        --      见 host/02_sim.lua 的 Step 尾部）。而 animover 就是在 _tick 里
        --      `fire()` 出去的 —— 也就是说：
        --          tick N  ：walk_pre 播完 → animover 入队（此刻 _queue 仍是空的）
        --          tick N 末：SG 才把 premoving → moving，onenter 里 PushAnimation("walk_loop")
        --                     → **队列到这时候才有了东西**
        --          tick N+1：_tick 再来，若在这里短路就永远看不到那个 walk_loop
        --      实测症状：蜘蛛在真实地形上位移 40 世界单位，动画却永久冻结在
        --      walk_pre 第 6 帧（SGspider.lua:184 用的正是 PushAnimation）。
        --
        --    真实引擎里 PushAnimation 就是「把动画挂到当前动画之后」，
        --    哪怕当前动画已经播完，下一个 update 也该把它接上 —— 这里对齐。
        local q = self._queue
        if q ~= nil and #q > 0 then
            local nxt = table.remove(q, 1)
            applyAnim(self, nxt.name, nxt.loop)
            return
        end

        -- ③ 队列确实空了 → 补发 animqueueover（也只发一次，否则会每 tick 刷屏）
        if not self._queuefired then
            self._queuefired = true
            fire("animqueueover")
        end
    end

    -- ---- ★ 绘制列表：这一帧要画什么 ----
    -- 返回 { {symbol=名字, atlas=图集下标, bld=提供该符号的 build(或 nil),
    --          verts={{x,y,u,v}×6}, bbox, mat} ... }
    -- 这是宿主与任何渲染器之间的**唯一接口**：有了它，接 LÖVE2D / Web / 终端都行。
    --
    -- ★★ 符号解析分三级，顺序即优先级：
    --   ① 显式覆盖（OverrideSymbol）—— skinner 给角色换衣服/猴化走这条
    --   ② base build 自己就有这个符号 —— 绝大多数情况
    --   ③ base build 没有 → 去 AddOverrideBuild 登记的那些 build 里按哈希找
    --      —— 这是 AddOverrideBuild 的**真正用途**，此前漏了：
    --        wilson 的动画引用了 12 个不在 wilson build 里的符号哈希
    --        （swap_hat / SWAP_BODY / skirt / swap_object / BEARD / tail ...
    --          全是装备槽），旧实现把它们**静默丢弃** —— 画面缺件但不报错。
    --
    --   每个元素带回 `bld`（提供该符号的 build 名）。渲染端必须用它选图集：
    --   覆盖符号的 atlas 下标是**目标 build 自己的**下标，跟实体的 build 混用会错。
    as.GetDrawList = function(self)
        if not ensure() then
            -- ★★ 计在这里，不在 ensure() 里 —— 位置决定了这个数代表什么。
            --   ensure() 失败一次就把 cache[name] 置 false，之后每次调用
            --   都走「缓存命中但值为 false」的短路分支直接返回 nil，
            --   **根本不会再进 ensure 里那段计数**。
            --   实测踩过：计数放在 ensure 里，结果 34 个 build 全是「请求 1 次」
            --            —— 那是「缓存未命中次数」，与画面代价无关。
            --   计在 GetDrawList 的失败分支，才是**真正画不出来的次数**。
            local bn = as._build or "?"
            M.MissingHits[bn] = (M.MissingHits[bn] or 0) + 1
            return nil, "no data"
        end
        local a = self._cur
        if not a then return nil, "no animation" end
        local fr = a.frames[self._frame]
        if not fr then return nil, "frame out of range" end
        local syms = self._data.symbols
        local has_ov = next(self._overrides) ~= nil
        local has_ovb = next(self._ov_builds) ~= nil
        local hidden = next(self._sym_hidden) ~= nil and self._sym_hidden or nil
        local out = {}
        -- 导出格式里「帧」本身就是元素数组（紧凑），所以直接 ipairs(fr)。
        -- ⚠️ 一开始我按 `fr.elements` 取，得到 nil —— 导出侧与读取侧的
        --    结构约定必须对齐，这类不一致不会在导出时报错，只在读时炸。
        for _, el in ipairs(fr) do
            local s = syms[el.sym]      -- ② base build 里的符号（可能 nil）
            local name = s and s.name

            -- ① 符号显隐（HideSymbol）—— 按名字判，所以只在拿得到名字时有效
            if not (hidden and name and hidden[name]) then
                local sym, bld = s, nil

                -- ①' 显式覆盖优先于一切
                if has_ov and name ~= nil then
                    local ov = self._overrides[name]
                    if ov ~= nil then
                        local osym = ov_symbol(ov.build, ov.sym)
                        if osym ~= nil then
                            local ob = build_name_of(ov.build)
                            sym, bld = osym, ob
                        end
                        -- 覆盖符号在目标 build 里找不到 → 保留原符号（不静默吞掉）
                    end
                end

                -- ③ base build 没有这个符号 → 去登记的 override build 里找
                if sym == nil and has_ovb then
                    local hit = ov_by_hash()[el.sym]
                    if hit ~= nil then
                        sym, bld = hit.sym, hit.build
                    end
                end

                if sym ~= nil then
                    local f = sym.frames[el.frame] or sym.frames[0]
                    if f then
                        out[#out + 1] = {
                            symbol = sym.name or name,
                            -- ★ 符号哈希（**渲染端真正要用的键**）。
                            --   symbol 只是显示名：播放器的 build JSON 是按哈希建键的
                            --   （`_out/json/*.json` 的 symbols 键形如 "1690368943"），
                            --   而覆盖可能把符号**换名**（几何替换：wilson 的 foot →
                            --   rabbit 的 foot），所以必须回传「目标 build 里那个符号」的哈希。
                            symh = sym.hash,
                            symframe = el.frame,
                            -- ★ 符号属于哪个图集。多图集 build（如 pig_build 有
                            --   atlas-0 2048² 与 atlas-1 1024×512）必须区分，
                            --   否则采样错图集 → 画面直接是错的。
                            --   归属由 export_anim.py 用「UV跨度×图集尺寸==bbox w/h」推导。
                            --   ⚠️ 覆盖符号的 atlas 下标是**目标 build 自己的**下标，
                            --     必须与 bld 一起用，不能与实体的 build 混。
                            atlas = sym.atlas or 0,
                            bld = bld,
                            verts = f.verts,     -- 6 个 {x, y, u, v}
                            bbox = f.bbox,
                            mat = el.mat,        -- a,b,c,d,tx,ty,tz
                        }
                    end
                end
            end
        end
        return out
    end

    -- 便于诊断
    as.GetAnimInfo = function(self)
        if not ensure() then return nil end
        return {
            build = self._data.buildName,
            atlas = self._data.atlas,
            n_anims = (function() local n = 0 for _ in pairs(self._data.anims) do n = n + 1 end return n end)(),
            cur = self._curName,
            frame = self._frame,
            nframe = self._nframe,
            rate = self._rate,
        }
    end

    return true
end

return M
