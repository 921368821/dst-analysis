--[[
==============================================================================
 perish.lua —— 腐烂 / 饥饿链路验证
==============================================================================
为什么单独验
    按「后续任务清单」P1-2，也按第 21 节 DropDeathLoot 的教训：
    **主循环不会自然走到的分支必须显式去走**。
    腐烂和饥饿都是「慢速推进 + 阈值触发」型，80 s 演示里根本走不到阈值。

两条链路
    ① 腐烂：meat 有 perishable 组件，`onperishreplacement = "spoiled_food"`
       → 推进到保质期终点 → 打上 "spoiled" 标签
       → 换成 spoiled_food（`perishable.lua:295`）
    ② 饥饿：wilson 的 hunger 组件每 tick 下降
       → 归零后 `IsStarving()` 为真
       → 继续掉会由 health 接手（`hunger.lua:128 DoDelta` 里转给 health）

判据
    腐烂：掉到保质期终点后，物品**不再是 meat**，而是 spoiled_food
    饥饿：饥饿值真的在下降，且能掉到 0 触发 IsStarving()
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Loader    = require("host.04_loader")
local Sim       = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

Bootstrap.Setup()
WorldMap.Generate({ seed = 20261013 })

local function hr(t)
    print("")
    print(string.rep("═", 70))
    print("  " .. tostring(t))
    print(string.rep("═", 70))
end

local function spawn(name)
    Universal.Install(Core)
    local ok, inst = pcall(Core.SpawnPrefab, name)
    Universal.Uninstall()
    if ok and inst ~= nil then inst.Transform:SetPosition(0, 0, 0) end
    return ok and inst or nil
end

PERISH_RESULT = nil
HUNGER_RESULT = nil

--=========================================================================
hr("1) 腐烂：meat → spoiled_food")
do
    Bootstrap.LoadPrefabFile("meat")
    local m = spawn("meat")
    if m == nil then
        print("  ✘ meat 生成失败")
    else
        local P = m.components.perishable
        print(string.format("  meat: perishable=%s  prefab=%s  HasTag('spoiled')=%s",
            tostring(P), tostring(m.prefab), tostring(m:HasTag("spoiled"))))
        if P == nil then
            print("  ✘ 没有 perishable 组件 —— 这本身是个缺口")
        else
            print(string.format("  保质期 = %s 秒   当前剩余 = %s",
                tostring(P.perishtime), tostring(P.perishremainingtime)))
            print(string.format("  onperishreplacement = %s", tostring(P.onperishreplacement)))

            -- 把保质期设成 2 秒（60 tick），缩短等待
            local ok_s, err_s = pcall(P.SetPerishTime, P, 2)
            print(string.format("  SetPerishTime(2) → ok=%s %s", tostring(ok_s),
                tostring(err_s):sub(1, 120)))
            print(string.format("  设完后剩余 = %s 秒", tostring(P.perishremainingtime)))

            print("")
            -- ★★ 别以为「每 tick 掉一点」—— Perishable **不用 OnUpdate**，
            --   而是 `DoPeriodicTask(dt, Update)`，其中
            --       `dt = 10 + math.random()*FRAMES*8`（秒）
            --   即**每约 10+ 秒才推进一次**，每次按 dt 秒扣。
            --   第一版只跑 200 tick（6.7 s），连一次周期都没到，
            --   于是看到「剩余从 2 掉到 0.56 就再也不动」—— 那其实是一次 Update。
            --   要等变质，至少得跑 2~3 个周期（约 20~30 s）。
            local NT = 1200   -- 40 秒，约 3 个周期
            print(string.format("  推进 %d tick（%.0f 秒，约 3 个周期）……", NT, NT / 30))
            local became_spoiled, replaced = nil, nil
            for i = 1, NT do
                Sim.Step()
                if i == 1 or i == 300 or i == 600 or i == 900 then
                    print(string.format("    tick %-4d 剩余=%s 秒",
                        i, tostring(P.perishremainingtime)))
                end
                if m:IsValid() then
                    if m:HasTag("spoiled") and became_spoiled == nil then
                        became_spoiled = i
                    end
                else
                    if replaced == nil then replaced = i end
                    break
                end
            end
            print(string.format("  实体仍有效 = %s", tostring(m:IsValid())))
            if m:IsValid() then
                print(string.format("  打上 spoiled 标签于第 %s tick；现在 prefab=%s",
                    tostring(became_spoiled), tostring(m.prefab)))
                print(string.format("  IsSpoiled() = %s   IsFresh() = %s",
                    tostring(P.IsSpoiled and P:IsSpoiled()),
                    tostring(P.IsFresh and P:IsFresh())))
            else
                print(string.format("  实体被移除于第 %s tick（已换成别的东西）",
                    tostring(replaced)))
            end
            -- 数场上是否出现 spoiled_food
            local n_spoiled = 0
            for _, v in pairs(Core.Spawned) do
                if v.prefab == "spoiled_food" then n_spoiled = n_spoiled + 1 end
            end
            print(string.format("  场上 spoiled_food 数量 = %d", n_spoiled))
            -- 把结果存到外层供判定
            PERISH_RESULT = {
                had_perishable = P ~= nil,
                set_ok = ok_s,
                still_valid = m:IsValid(),
                spoiled_tag = m:IsValid() and m:HasTag("spoiled") or false,
                became_spoiled = became_spoiled,
                spoiled_count = n_spoiled,
            }
        end
    end
end

--=========================================================================
hr("2) 饥饿：hunger 下降 → 归零 → IsStarving()")
do
    Bootstrap.LoadPrefabFile("wilson")
    local p = spawn("wilson")
    if p == nil then
        print("  ✘ wilson 生成失败")
    else
        local H = p.components.hunger
        print(string.format("  wilson: hunger=%s  prefab=%s", tostring(H), tostring(p.prefab)))
        if H == nil then
            print("  ✘ 没有 hunger 组件")
        else
            print(string.format("  current = %s   max = %s",
                tostring(H.current), tostring(H.max)))
            -- 把当前值压到很低，并把**速率调高**（原版 hunger 默认掉得很慢：
            -- 20 秒只掉 2.65，从 5 掉到 0 要 37 秒以上）
            pcall(H.DoDelta, H, -(H.current or 0) + 5)
            pcall(H.SetRate, H, 5)      -- 5 点/秒 ⇒ 1 秒就归零
            print(string.format("  压到 current = %s   rate = %s",
                tostring(H.current), tostring(H.rate)))
            print(string.format("  IsStarving() = %s（当前）", tostring(H:IsStarving())))

            print("")
            print("  推进 300 tick（10 秒）……")
            local drained, starved_at = 0, nil
            for i = 1, 300 do
                Sim.Step()
                if not p:IsValid() then break end
                if starved_at == nil and H:IsStarving() then starved_at = i end
            end
            drained = H.current or 0
            print(string.format("  推进后 current = %s", tostring(drained)))
            print(string.format("  IsStarving() 首次为真于第 %s tick", tostring(starved_at)))
            print(string.format("  实体仍有效 = %s", tostring(p:IsValid())))
            HUNGER_RESULT = {
                had_hunger = true,
                drained = drained,
                starved_at = starved_at,
                starving = H:IsStarving(),
            }
        end
    end
end

--=========================================================================
hr("3) 判定")
local pass = true
local function chk(c, n)
    print(string.format("  %s %s", c and "✔" or "✘", n))
    if not c then pass = false end
end
if PERISH_RESULT ~= nil then
    chk(PERISH_RESULT.had_perishable, "meat 有 perishable 组件")
    chk(PERISH_RESULT.set_ok, "SetPerishTime 可用（能改保质期）")
    chk(PERISH_RESULT.spoiled_count > 0
        or (PERISH_RESULT.spoiled_tag and PERISH_RESULT.still_valid),
        "腐烂链路走通：出现 spoiled_food，或该物品被打上 spoiled 标签")
end
if HUNGER_RESULT ~= nil then
    chk(HUNGER_RESULT.had_hunger, "wilson 有 hunger 组件")
    chk(HUNGER_RESULT.starved_at ~= nil or HUNGER_RESULT.starving,
        "饥饿值能掉到 0 并触发 IsStarving()")
end
print("")
print(string.format("  总判定：%s", pass and "✔ 通过" or "✘ 有失败项"))

Core.DumpGaps()
