--[[==========================================================================
 rt_save.lua ---- 世界存档 / 读档（P3 / M5）

 为什么在 rt 侧而不是宿主
   宿主的 `SetPersistData` 是 `function(self) end`（no-op），`GetSaveRecord`
   只是名字表里的一项（调用返回 nil）。改宿主能修，但 **06-引擎复刻 的 14 入口
   是「保真度」的度量**，不该为实时引擎的需求去动它。
   ⇒ 在 rt 侧实现，复用**原版组件自己的 OnSave/OnLoad**（它们是真代码）。

 设计
   · collect() 产出一个**纯 Lua 表**（不自己拼 JSON ---- JSON 由 Python 侧做，
     避免再引一个 Lua JSON 库）；
   · apply() 按表恢复：先清场，再逐个重新 SpawnPrefab、回填位置/朝向、
     并调用各组件原版的 OnLoad；
   · **坏档案必须报错且不破坏当前世界**：apply 在**全部校验通过后才动世界**
     （先 dry-run 校验，再执行）---- 这是 P3 的核心反向判据。

 对外（由 rt_boot.lua 挂到 M 上）
   Save.collect() / Save.apply(t) / Save.validate(t)
============================================================================]]
local M = {}

--- 收集当前世界（纯表，Python 侧转 JSON）
function M.collect(Core, Sim, meta)
    local out = {
        version  = 1,
        seed     = meta.seed,
        time     = Sim.TheSim.time,
        tick     = meta.tick,
        player_guid = meta.player_guid,
        -- ★★ 多人 + 会话身份的持久化（2026-10-16 加）。
        --   为什么必须有这两个表：`save_apply` 会把读档后**没人认领**的 wilson 删掉，
        --   而「哪个客户端对应哪个角色」以前**完全没有持久化** ⇒ 重启之后
        --   每个客户端都会拿到**新**角色、旧角色（带着它走过的路）被丢弃。
        --   · `players`：槽位 → **旧 guid**（配合下面 `apply` 里那张 旧→新 的表就能重新绑定）
        --   · `keys`   ：槽位 → 会话 key（客户端拿同一个 key 回来就能认领回原槽位）
        players  = meta.players,
        keys     = meta.keys,
        ents     = {},
    }
    local n = 0
    for guid, inst in pairs(Core.Spawned) do
        n = n + 1
        -- ★ prefab 可能是 nil（世界实体 `TheWorld` 就没有 prefab 字段）
        --   ---- 不兜的话这个键在表里直接消失，validate 会报「缺 prefab 名」，
        --     而真实原因只是「它本来就没有」。⇒ 兜成 "world"。
        local pname = inst.prefab or (inst.prefabname) or "world"
        local rec = { guid = guid, prefab = pname }
        local t = inst.Transform
        if t ~= nil then
            rec.x, rec.y, rec.z = t:GetWorldPosition()
            -- ★ 世界实体（TheWorld）的 Transform 可能**没有位置**（GetWorldPosition 返回 nil）
            --   ---- 不兜底的话键会消失，validate 报「位置不是数字」，而真实原因只是「它本来就没有」。
            if rec.x == nil then rec.x, rec.y, rec.z = 0, 0, 0 end
            rec.rot = t._rot or 0
        else
            rec.x, rec.y, rec.z, rec.rot = 0, 0, 0, 0
        end
        -- 各组件原版的 OnSave（有就收；收不到不阻塞存档）
        local comps = {}
        for name, c in pairs(inst.components or {}) do
            if type(c) == "table" and type(c.OnSave) == "function" then
                local ok, d = pcall(c.OnSave, c, {})
                if ok and type(d) == "table" then
                    comps[name] = d
                end
            end
        end
        rec.components = comps
        out.ents[#out.ents + 1] = rec
    end
    out.n = n
    return out
end

--- 校验一份存档（**不动世界**）。返回 ok, err
function M.validate(t)
    if type(t) ~= "table" then return false, "存档不是表（类型 " .. type(t) .. "）" end
    if t.version ~= 1 then
        return false, "存档版本不支持: " .. tostring(t.version)
    end
    if type(t.ents) ~= "table" then return false, "缺 ents 字段" end
    if #t.ents == 0 then return false, "ents 为空（空世界不该被存/读）" end
    for i, rec in ipairs(t.ents) do
        if type(rec) ~= "table" then return false, "第 " .. i .. " 条不是表" end
        if type(rec.prefab) ~= "string" then
            return false, "第 " .. i .. " 条缺 prefab 名"
        end
        if type(rec.x) ~= "number" or type(rec.z) ~= "number" then
            return false, "第 " .. i .. " 条（" .. tostring(rec.prefab) .. "）位置不是数字"
        end
        if rec.components ~= nil and type(rec.components) ~= "table" then
            return false, "第 " .. i .. " 条的 components 不是表"
        end
    end
    if type(t.time) ~= "number" then return false, "time 不是数字" end
    -- ★★ 必须**始终返回两个值**：失败路径返回 (false, 原因)，
    --   成功路径若只 `return true`，lupa 那侧就变成单个 bool，
    --   Python `ok, err = ...` 直接 "cannot unpack non-iterable bool object"。
    return true, ""
end

--- 应用一份存档（先 validate，通过才动世界）
function M.apply(Core, Sim, meta, t)
    local ok, err = M.validate(t)
    if not ok then
        -- ★ 读坏档案**绝不破坏当前世界**
        return false, "存档校验失败（世界未改动）: " .. tostring(err)
    end

    -- ① 清场：移除当前全部实体
    --   ★★ 必须**双保险**：`inst:Remove()` 对某些实体是 no-op（实测玩家实体
    --      Remove 之后仍留在 Core.Spawned 里，位置还是旧的）⇒ 除了调用 Remove，
    --      还要**显式**把注册表项清掉。
    --      只调 Remove 的后果：读档后 meta.player 仍指向旧实体，
    --      位置看起来「没读回来」----而新实体其实是对的。
    for guid, inst in pairs(Core.Spawned) do
        if inst.Remove then pcall(inst.Remove, inst) end
        Core.Spawned[guid] = nil
    end

    -- ② 逐个重建
    --   ★★ 只重建「**能**重建的」：世界实体（TheWorld 等）没有对应 prefab 定义，
    --      硬 SpawnPrefab("world") 会触发原版的 "You cannot spawn multiple worlds!"
    --      并造出重复实体（实测 6 → 8）。⇒ 先查 Core.Prefabs，查不到就**跳过并计数**，
    --      不假装成功。
    local made, failed, skipped = 0, {}, {}
    -- ★★ 旧 guid → 重建出来的新实体（2026-10-16 加）。
    --   为什么需要：重建出来的实体是**新 guid**（老 guid 随清场消失），
    --   而存档里记的「槽位 → 旧 guid」只有在拿到这张表之后才能翻译成**新实体** ⇒
    --   否则读档后就没法把「客户端那个角色」重新绑回去，只能把它当没人认领的删掉。
    --   ★ 循环是 `ipairs(t.ents)`（**顺序**），所以每个 rec 与它的新实体一一对应。
    local by_old_guid = {}
    for _, rec in ipairs(t.ents) do
        if Core.Prefabs[rec.prefab] == nil then
            skipped[#skipped + 1] = rec.prefab
        else
            local inst = Core.SpawnPrefab(rec.prefab)
            if inst == nil then
                failed[#failed + 1] = rec.prefab
            else
                made = made + 1
                if rec.guid ~= nil then by_old_guid[rec.guid] = inst end
                if inst.Transform then
                    inst.Transform:SetPosition(rec.x, rec.y or 0, rec.z)
                    inst.Transform:SetRotation(rec.rot or 0)
                end
                for name, d in pairs(rec.components or {}) do
                    local c = inst.components and inst.components[name]
                    if c ~= nil and type(c.OnLoad) == "function" then
                        -- 原版 OnLoad(data, newents)
                        pcall(c.OnLoad, c, d, {})
                    end
                end
            end
        end
    end

    -- ③ 恢复世界时间与步数
    Sim.TheSim.time = t.time
    meta.tick = t.tick or meta.tick

    -- ④ 恢复玩家引用
    --   ★★ 不能只按 guid 找：重建出来的实体是**新 guid**，老 guid 已随清场消失
    --      （第一版就这么写的，结果 meta.player 是 nil 或指向旧实体，
    --       位置看起来「没读回来」——而新实体其实是对的）。
    --   ⇒ 先按 guid，找不到再按 prefab 名找，并如实记缺口。
    meta.player = Core.Spawned[t.player_guid]
    if meta.player == nil then
        for _g, inst in pairs(Core.Spawned) do
            if inst.prefab == "wilson" then
                meta.player = inst
                break
            end
        end
    end
    meta.restored = by_old_guid      -- ★ 旧 guid → 新实体（调用方用它重新绑定槽位）
    meta.player_ok = meta.player ~= nil
    if not meta.player_ok and Core.NoteGap then
        Core.NoteGap("save:player(guid=" .. tostring(t.player_guid) .. ")", "Save.apply")
    end

    -- ★ 如实汇报三类：重建成功 / 建不出来 / 跳过（不可重建）
    local msg = string.format("读档完成：重建 %d 个，跳过 %d 个（%s）",
        made, #skipped, #skipped > 0 and table.concat(skipped, ",") or "无")
    if #failed > 0 then
        msg = msg .. string.format("；另有 %d 个建不出来: %s", #failed, table.concat(failed, ","))
    end
    return true, msg .. string.format("，t=%.2f", Sim.TheSim.time)
end

return M
