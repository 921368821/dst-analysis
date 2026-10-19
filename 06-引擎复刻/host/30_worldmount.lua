--[[
==============================================================================
 30_worldmount.lua —— 世界级组件的**唯一**清单与**唯一**挂法

 为什么要有这个文件（M3）
   世界级组件清单原来被抄了两份：
     · `06-引擎复刻/world.lua:119`  的 `WORLD_COMPONENTS`
     · `07-通用引擎/rt/rt_boot.lua:63` 的同名表（注释自陈「照抄 06」）
   两份各自维护，原版一旦新增世界组件（或某个组件改名），必然**只改一处**，
   症状是「06 世界正常、07 少了季节」这种最难查的差异 —— 而且没人会想到
   去看另一份清单。

   ＊这里放的是**清单 + 挂法**，不放任何打印/日志/业务：
     06 要在挂完后打印「n/5 成功」，07 要在失败时吵「昼夜会是死值」，
     这些是各自的策略，不该被单源化绑在一起。

 原版权威列表：`world_network.lua:52-61`。顺序也照它，别自己重排 ——
 组件构造之间存在隐含依赖（如 `seasons` 会改写 `clock` 的段长）。
==============================================================================
]]

local M = {}

--- 世界级组件（顺序 = `world_network.lua:52-61`）
M.COMPONENTS = {
    "clock",            -- 昼夜（一天 480 s = 10/4/2 段 ×30 s）
    "worldtemperature", -- 温度（季节内扰动 + 相位正弦；构造需要 perlin）
    "seasons",          -- 季节（autumn/winter/spring/summer 循环）
    "shardstate",       -- 分片状态（构造需要 TheWorld.meta.session_identifier）
    "worldreset",       -- 世界重置计数
}

--- 把世界组件挂到 `W` 上。
--- @param W table|nil  世界实体（通常是 TheWorld）
--- @param opt table|nil `{ skip = true }` ⇒ 一个都不挂（反向开关，给测试用）
--- @return table `{ mounted = {...}, missing = {...}, ok = bool, total = n }`
---
--- ★ 单个组件挂载失败**不抛错**：世界仍然可用，只是那个维度退化成死值。
---   调用方必须把 `missing` 报出来（06 打印、07 吵），否则这就是「静默失真」。
--- ★ `AddComponent` 用 `pcall(W.AddComponent, W, nm)` 保持方法语义；
---   重复添加由 `host/01_core.lua` 的影子闸门挡住并返回旧实例（见那里的注释）。
function M.Mount(W, opt)
    opt = opt or {}
    local out = { mounted = {}, missing = {}, ok = false, total = #M.COMPONENTS }

    local function all_missing()
        for _, nm in ipairs(M.COMPONENTS) do
            out.missing[#out.missing + 1] = nm
        end
        return out
    end

    if W == nil then return all_missing() end          -- 世界还没建：如实报「一个都没挂」
    if opt.skip then return all_missing() end           -- 反向开关：故意不挂

    for _, nm in ipairs(M.COMPONENTS) do
        pcall(W.AddComponent, W, nm)
        if W.components ~= nil and W.components[nm] ~= nil then
            out.mounted[#out.mounted + 1] = nm
        else
            out.missing[#out.missing + 1] = nm
        end
    end

    out.ok = (#out.missing == 0)
    return out
end

return M
