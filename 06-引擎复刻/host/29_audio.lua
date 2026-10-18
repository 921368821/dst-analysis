--[[
==============================================================================
 29_audio.lua —— 音频事件通道（让 SoundEmitter 有**可观测的真实副作用**）
==============================================================================
为什么需要它（审计结论）
  审计前，`SoundEmitter` 只是「一张记账表」：`PlaySound` 把名字塞进 `self._playing`，
  `KillSound` 删掉，然后什么都没有。于是：
    · 没法回答「这一段有没有真的播过声音」
    · 没法回答「播了几次、什么参数」（音效回归测试无从下手）
    · `SetVolume` 之类连字段都没有（泛化桩 return nil）

★ 但本工程**没有也不打算做音频后端**（headless，没有声卡/混音器）。
  「不出声」是可以接受的；「连发生过什么都不知道」不可接受。
  ⇒ 本模块把音频做成**事件通道**，而不是假装在放音：
    · 每次播放/停止都落一条**结构化事件**（tick / 实体 prefab / 声音名 / 音量 / 音高）
    · 事件可 `Drain()` 取走（取走即清空 —— 判据能验「有没有重复取」）
    · 可 `Subscribe(fn)`（将来接真正的后端，就是在这个钩子上接）
    · 环形缓冲有上限（声音是高频事件，不能无限涨内存）

★ 诚实边界（写清楚，别让读者以为有声音）
  · 本模块**不产生任何声音**。它是「音频事件的账本 + 订阅点」。
  · `SetVolume/SetPitch` 改的是**事件里带的参数**与 emitter 的状态字段，
    不是任何混音器的增益。
  · 真要出声，需要在这条通道上接一个后端（Web Audio / SDL_mixer 等），
    那不是本工程的形态。
==============================================================================
]]

local Sim = require("host.02_sim")

local Audio = {}
Sim.Audio = Audio

local MAX_EVENTS = 512          -- 环形缓冲上限

local events = {}               -- 队列（数组，1 是最旧）
local subs   = {}               -- id -> fn
local next_sub = 0

local stats = {
    played     = 0,   -- PlaySound 次数
    killed     = 0,   -- KillSound 次数
    killed_all = 0,   -- KillAllSounds 次数
    dropped    = 0,   -- 因为超过 MAX_EVENTS 被丢掉的条数（**不许静默**）
    delivered  = 0,   -- 交给订阅者的条数
}

local function tick()
    local T = Sim.TheSim
    return (T ~= nil and T.tick) or 0
end

--- 取 prefab 名（实体可能已经析构，取不到就如实给 "?"）
local function prefab_of(inst)
    if inst == nil then return "?" end
    local p = rawget(inst, "prefab")
    if type(p) == "string" then return p end
    return "?"
end

local function push(ev)
    events[#events + 1] = ev
    if #events > MAX_EVENTS then
        table.remove(events, 1)
        stats.dropped = stats.dropped + 1
    end
    if next_sub > 0 then
        for _, fn in pairs(subs) do
            -- 订阅者抛错**不许**带走播放方：音频是旁路，不能影响主循环
            local ok = pcall(fn, ev)
            if ok then stats.delivered = stats.delivered + 1 end
        end
    end
end

--=========================================================================
-- 由 SoundEmitter 的覆写调用（见 host/00_stubs.lua 的 OVERRIDES.SoundEmitter）
--=========================================================================
--- 记一条「播放」事件
function Audio.PushPlay(inst, name, vol, pitch, tag)
    stats.played = stats.played + 1
    push({
        kind = "play", t = tick(), prefab = prefab_of(inst),
        name = tostring(name), id = (tag ~= nil) and tostring(tag) or nil,
        vol = tonumber(vol) or 1, pitch = tonumber(pitch) or 1,
    })
end

--- 记一条「停止」事件
function Audio.PushKill(inst, id)
    stats.killed = stats.killed + 1
    push({ kind = "kill", t = tick(), prefab = prefab_of(inst),
           id = (id ~= nil) and tostring(id) or nil })
end

--- 记一条「全部停止」事件（带被停掉的数量，便于判据核对）
function Audio.PushKillAll(inst, n)
    stats.killed_all = stats.killed_all + 1
    push({ kind = "killall", t = tick(), prefab = prefab_of(inst), n = n or 0 })
end

--=========================================================================
-- 读取接口
--=========================================================================
--- 取走全部事件并清空（**取走即清空**：判据用它验「不能重复取」）
function Audio.Drain()
    local out = events
    events = {}
    return out
end

--- 看一眼但不取走（limit 只取最近 N 条）
function Audio.Events(limit)
    local n = #events
    local out = {}
    local from = 1
    if limit ~= nil and limit < n then from = n - limit + 1 end
    for i = from, n do out[#out + 1] = events[i] end
    return out
end

function Audio.Count() return #events end

function Audio.Stats()
    local out = {}
    for k, v in pairs(stats) do out[k] = v end
    out.queued = #events
    out.max = MAX_EVENTS
    out.subscribers = next_sub
    return out
end

--- 订阅（返回 id，用于 Unsubscribe）。音频事件是旁路，订阅者抛错被吞并计数。
function Audio.Subscribe(fn)
    if type(fn) ~= "function" then return nil end
    next_sub = next_sub + 1
    subs[next_sub] = fn
    return next_sub
end

function Audio.Unsubscribe(id)
    if subs[id] == nil then return false end
    subs[id] = nil
    return true
end

--- 清空（测试用）
function Audio.Reset()
    events = {}
    for k in pairs(stats) do stats[k] = 0 end
end

--- 模块缺失时给 stub 一个安全的软着陆点：
--  `00_stubs.lua` 在本模块**之前**加载，所以它每次调用都现查 `_G.__AUDIO_SINK`。
_G.__AUDIO_SINK = Audio

return Audio
