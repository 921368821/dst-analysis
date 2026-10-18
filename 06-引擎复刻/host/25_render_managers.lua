--[[
==============================================================================
 25_render_managers.lua —— main.lua 的四个渲染层管理器全局
==============================================================================
背景
   真实 DST 在 main.lua 的 `ModSafeStartup()` 里建一个全局实体，
   再从它身上取四个 C++ 渲染管理器：

       main.lua:441  TheGlobalInstance = CreateEntity("TheGlobalInstance")
       main.lua:442      .entity:AddTransform()
       main.lua:443      .entity:SetCanSleep(false)
       main.lua:444      .persists = false
       main.lua:445      .AddTag("CLASSIFIED")
       main.lua:451  ShadowManager   = TheGlobalInstance.entity:AddShadowManager()
       main.lua:452  ShadowManager:SetTexture("images/shadow.tex")
       main.lua:453  RoadManager     = TheGlobalInstance.entity:AddRoadManager()
       main.lua:454  EnvelopeManager = TheGlobalInstance.entity:AddEnvelopeManager()
       main.lua:456  PostProcessor   = TheGlobalInstance.entity:AddPostProcessor()

   ★ 这五行**在 `if not TheNet:IsDedicated()`（main.lua:458）之前**，
     所以专用服务器上这四个全局**也是非 nil 的** —— 这不是客户端专属。
     （对照：forest.lua:634 `if not TheNet:IsDedicated() then AddComponent("colourcube")`
       那种才是客户端专属。两处判据不同，别混。）

   宿主没跑 main.lua ⇒ 这四个全局一直是 nil。

实测后果（reachability.lua 抽样 300，3 个预制体）
   prefabs/pollen.lua:21                EnvelopeManager:AddColourEnvelope(...)
   prefabs/nightsword_sharp_fx.lua:32   EnvelopeManager:AddColourEnvelope(...)
   prefabs/lunar_goop_cloud_fx.lua:22   EnvelopeManager:AddColourEnvelope(...)
   ✘ attempt to index global 'EnvelopeManager' (a nil value)
   ★ `pollen` 由 **服务端** components/weather.lua:400 spawn；
     `lunar_goop_cloud_fx` 由 prefabs/lunar_grazer.lua:429 在 `ismastersim` 分支 spawn
     ⇒ 都是服务端路径，不能用「客户端专属」解释掉。

用法面（全库计数，不是印象）
   EnvelopeManager:AddColourEnvelope  93 次   ┐
   EnvelopeManager:AddVector          83 次   │ 返回值被保存的 **0 次**
   PostProcessor:SetColourCube*/Add*  ~70 次  ┘
   ShadowManager:SetTexture            1 次（就是 main.lua:452 本身）
   RoadManager:IsOnRoad                9 次（**全部**带 `RoadManager ~= nil` 守卫）

★★ RoadManager 为什么**单独**给真语义而不是代理
   代理法有个会「说谎」的角落：链式代理让 `IsOnRoad(...)` 返回 self（**真值**），
   而它的调用点是经典 and/or 三元：
       locomotor.lua:1232
         (self:FasterOnRoad() and ((RoadManager ~= nil and RoadManager:IsOnRoad(x,0,z))
                                   or GROUND_ROADWAYS[current_ground_tile])) or ...
   ⇒ 返回真值会让**所有**生物在**所有**地块上获得道路加速 —— 静默的行为谎言。
   而宿主没有「绘制道路条带」这套系统 ⇒ 真实 RoadManager 在本工程里
   对任何坐标都只会返回 false。所以这里**显式**给 `IsOnRoad = false`：
   既与原版语义一致，又不会污染 GROUND_ROADWAYS（静态道路地块）那条回退。

诚实边界
   · 这四个对象**只登记调用**（`_calls` 可查），**不产生任何视觉/后处理效果** ——
     宿主是 headless 服务端形态，没有渲染管线。
   · 由此**不影响任何被断言的逻辑量**：视觉效果由浏览器播放器那条完全不同的
     链路（tools/build_world_player.py）负责。
   · `PostProcessor` 在当前场景里**未被触达**（colourcube 组件是客户端专属，
     forest.lua:634 有 `not TheNet:IsDedicated()` 守卫）。
     补它是因为原版服务端确实有这个全局 —— 属于「同源补齐」，
     不是「已证实的缺口」，本行如实区分。
==============================================================================
]]

local Core = require("host.01_core")

local RM = {}

RM.Installed = false

--- 四个管理器的名字 -> 实体上的 Add 方法名
RM.MANAGERS = {
    { global = "ShadowManager",   adder = "AddShadowManager" },
    { global = "RoadManager",     adder = "AddRoadManager" },
    { global = "EnvelopeManager", adder = "AddEnvelopeManager" },
    { global = "PostProcessor",   adder = "AddPostProcessor" },
}

--- 复刻 main.lua:441-456（只做「非 networked 全局实体 + 四个管理器」这一段）
function RM.Install()
    if RM.Installed then return true end

    -- ★ 用 Core.NewEntity 而不是 CreateEntity：语义上一样（宿主里
    --   CreateEntity 就是 NewEntity 的别名），但这里写清意图 ——
    --   我们不是在「生成场景物件」，而是在复刻 main.lua 的启动期单例。
    local gi = Core.NewEntity("TheGlobalInstance")
    gi.entity:AddTransform()
    gi.entity:SetCanSleep(false)
    gi.persists = false
    gi:AddTag("CLASSIFIED")

    for _, m in ipairs(RM.MANAGERS) do
        local adder = gi.entity[m.adder]
        if type(adder) ~= "function" then
            Core.NoteGap("entity:" .. m.adder, "render-managers")
        else
            _G[m.global] = adder(gi.entity)
        end
    end

    -- ★ 显式语义（见文件头）：宿主无道路条带系统 ⇒ 任何坐标都不在道路上。
    if type(_G.RoadManager) == "table" then
        _G.RoadManager.IsOnRoad = function() return false end
    end

    Core.GlobalInstance = gi
    RM.GlobalInstance = gi
    RM.Installed = true
    return true
end

--- 供测试/报告取用：四个全局是否都是表
function RM.Status()
    local out = {}
    for _, m in ipairs(RM.MANAGERS) do
        out[m.global] = type(_G[m.global])
    end
    return out
end

return RM
