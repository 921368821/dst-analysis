--[[
==============================================================================
 render.lua —— 让宿主导出「当前帧绘制列表」，交给外部渲染器出图

 这是 ZipAnim 接进宿主之后的闭环验证：
     prefab → SetBuild → 状态机 → PlayAnimation → AnimState 真实帧数据
            → GetDrawList() → 导出 → 渲染成 PNG

 输出格式（纯文本，便于 Python 直接解析，不引入 JSON 依赖）
     BUNDLE <build名> <atlas文件名> <宽> <高>
     SUBJECT <名字>
     FRAME <帧号>
     QUAD <符号名> <symframe> <6×{x,y,u,v}> <mat7个>
     END
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core = require("host.01_core")
local Bootstrap = require("host.05_bootstrap")
local Sim = require("host.02_sim")

Bootstrap.Setup()

local outfile = os.getenv("RENDER_OUT") or "_out/drawlist.txt"
local TICKS = tonumber(os.getenv("RENDER_TICKS") or "0")

--=========================================================================
-- 生成生物
--=========================================================================
-- ⚠️ 不同生物的动画名不一样（**修好 pick_anim 之后**才真测出来的）：
--     pig_build      → idle_loop   （有）
--     rabbit_build   → idle        （没有 idle_loop）
--     spider_build   → idle        （没有 idle_loop）
--     beefalo_build  → idle_loop   （有；另有 alert_idle / graze_loop）
--   ⚠️ 注意：上面这张表在旧 pick_anim 下是**假的知识** —— 旧判据恒为真，
--      所有生物都被记成 idle_loop，于是"按生物挑动画"从未真的发生过。
local ANIM_CANDIDATES = {
    "idle_loop", "idle", "alert_idle", "graze_loop", "look", "taunt",
}
--[[ ★★★ 这里的判据改过一次，改之前是**橡皮图章**，记下来免得重踩：

     旧版：
         as:PlayAnimation(n, true)
         if as._nframe and as._nframe > 0 then return n end

     为什么不成立：`host/10_animstate.lua:689-696` 里，动画**不存在**时宿主会
     投影一条**合成动画**（FALLBACK_FRAMES=15 / FALLBACK_RATE=30，
     `_cur = nil`、`_synthetic = true`），目的是让 `_tick`/`AnimDone`/animover
     照常工作（否则生物会永久卡死）。副作用是 `_nframe` 恒 > 0 ——
     于是旧判据**恒为真**，pick_anim 永远返回候选表第一项 "idle_loop"，
     根本没在"按生物挑动画"。pigman/beefalo 只是碰巧真有 idle_loop 才没露馅。

     真实后果（实测）：rabbit_build / spider_build 没有 `idle_loop` 动画
     （它们叫 `idle`）⇒ 拿到合成动画 ⇒ `_cur = nil` ⇒ `GetDrawList()` 返回空
     ⇒ drawlist.txt 里这两个 build **0 个 QUAD**，`check_drawcmd.js` 只能跳过，
     "离线/实时共用同一份指令"这条判据在 4 个 build 上有 2 个是空跑的。

     正确判据：**是否真的绑上了动画数据**（`_cur ~= nil`），而不是帧数 > 0。
     判据的输入不能包含"被判定机制自己造出来的值"—— 这是本工程的老母题。
]]
local function pick_anim(as)
    for _, n in ipairs(ANIM_CANDIDATES) do
        as:PlayAnimation(n, true)
        if as._cur ~= nil and not as._synthetic then return n end
    end
    -- 兜底：从导出表里取任意一个真实存在的动画（按名字排序，保证可复现）
    if as._data and as._data.anims then
        local names = {}
        for k in pairs(as._data.anims) do names[#names + 1] = tostring(k) end
        table.sort(names)
        for _, k in ipairs(names) do
            as:PlayAnimation(k, true)
            if as._cur ~= nil and not as._synthetic then return k end
        end
    end
    return nil
end

local SUBJECTS = {
    { prefab = "pigman",  build = "pig_build" },
    { prefab = "rabbit",  build = "rabbit_build" },
    { prefab = "spider",  build = "spider_build" },
    { prefab = "beefalo", build = "beefalo_build" },
}

local fh = assert(io.open(outfile, "w"), "无法写 " .. outfile)

local spawned = {}
for _, s in ipairs(SUBJECTS) do
    Bootstrap.LoadPrefabFile(s.prefab)
    local ok, inst = pcall(Core.SpawnPrefab, s.prefab)
    if ok and inst and inst.AnimState then
        local as = inst.AnimState
        as:SetBuild(s.build)
        local an = pick_anim(as)
        s.anim = an
        if TICKS > 0 then Sim.Run(TICKS) end
        local info = as:GetAnimInfo()
        -- ★ 这里也必须看 `_cur`，不能看 `info.nframe`：没有真实动画时
        --   nframe 会被合成动画填成 15（见 pick_anim 上方注释），
        --   旧写法于是把"一条动画都没绑上"的生物也放进了 spawned，
        --   导出成 0 个 QUAD 的空 BUNDLE —— 空 BUNDLE 会污染下游判据。
        if an and as._cur and info and info.nframe then
            spawned[#spawned + 1] = { inst = inst, as = as, spec = s, info = info }
        else
            print(string.format("  ✘ %-10s 没有可用动画（build=%s）",
                s.prefab, tostring(s.build)))
        end
    else
        print(string.format("  ✘ %-10s 实例化失败", s.prefab))
    end
end

--=========================================================================
-- 导出
--=========================================================================
for _, it in ipairs(spawned) do
    local info = it.info
    local a = info.atlas
    -- 多图集：把每一张的尺寸都告诉渲染侧
    local atlases = it.as._data and it.as._data.atlases or nil
    fh:write(string.format("BUNDLE %s %s %d %d",
        tostring(info.build), a and a.file or "?", a and a.w or 0, a and a.h or 0))
    if atlases then
        for i = 0, 3 do
            local at = atlases[i]
            if at then
                fh:write(string.format(" %d:%d:%d", i, at.w, at.h))
            end
        end
    end
    fh:write("\n")
    fh:write(string.format("SUBJECT %s\n", it.spec.prefab))
    fh:write(string.format("FRAME %d\n", info.frame or 1))
    local dl = it.as:GetDrawList()
    if dl then
        for _, d in ipairs(dl) do
            local parts = { "QUAD", tostring(d.symbol), tostring(d.symframe),
                            tostring(d.atlas or 0) }
            for _, v in ipairs(d.verts) do
                parts[#parts + 1] = string.format("%.4f", v[1])
                parts[#parts + 1] = string.format("%.4f", v[2])
                parts[#parts + 1] = string.format("%.6f", v[3])
                parts[#parts + 1] = string.format("%.6f", v[4])
            end
            for i = 1, 7 do
                parts[#parts + 1] = string.format("%.5f", d.mat[i] or 0)
            end
            fh:write(table.concat(parts, " ") .. "\n")
        end
    end
    fh:write("END\n")
    print(string.format("  %-10s build=%-14s anim=%-12s frame=%d/%d  图块=%d",
        it.spec.prefab, tostring(info.build), tostring(info.cur),
        info.frame or 1, info.nframe or 0, dl and #dl or 0))
end
fh:close()
print("已写出 " .. outfile)
