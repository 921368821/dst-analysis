--[[
==============================================================================
 22_perlin.lua —— 真实的三维 Perlin 噪声（C++ 全局 `perlin` 的 Lua 等价物）

为什么需要它
    原版有 6 处直接调 `perlin(x, y, z)`，全是 C++ 侧提供的：
        components/worldtemperature.lua:115  世界温度的季节内扰动
        components/weather.lua:402           下雨强度的噪声
        components/caveweather.lua:319       洞穴雨的噪声
        components/fumarolelocaltemperature.lua:101
        map/ocean_gen.lua:178                海洋生成的噪声叠加
        prefabs/floatinglantern.lua:126      灯笼闪烁
    宿主没提供 ⇒ 这些组件的**构造函数直接抛**
    "attempt to call global 'perlin' (a nil value)"，
    于是 `worldtemperature` 这类世界组件根本挂不上（实测缺口记录就是这么写的）。

★ 诚实边界：**不是逐位复刻**
    DST 的 perlin 在 C++ 里，种子、置换表、梯度生成方式都看不到。
    所以这里的数值**不可能与真引擎逐位相同** —— 任何依赖「具体某个坐标上的
    噪声值」的逻辑都会与真引擎不同。
    能对齐的是**统计性质与调用契约**：
      · 返回值域 ≈ [-1, 1]，均值 ≈ 0
      · 连续、可微（相邻采样点平滑过渡，不会跳变）
      · 同参数同结果（确定性）
      · 整数格点处为 0（Perlin 的定义性质）
    对上面 6 处调用来说这就够了：它们要的是「平滑的随机扰动」，
    不是某个特定数值。

算法
    Ken Perlin 2002 改进版（与经典版相比去掉了立方体的 12 个角梯度表，
    改用 3 位散列选梯度，且梯度不含 -1/+1 分量，噪声范围更接近 [-1,1]）：
        fade(t) = 6t^5 - 15t^4 + 10t^3
        grad(hash, x, y, z) = 按 hash 低 4 位选 12 个梯度之一
        noise = lerp(lerp over 8 corners) * 0.9701   -- 归一化因子
==============================================================================
]]

local M = {}

-- 置换表：标准做法是 0..255 的随机排列再复制一遍（共 512），避免取模。
-- 用固定种子生成 —— 必须确定性，否则同一份轨迹重跑两次结果不同。
local p = {}
do
    local perm = {}
    for i = 0, 255 do perm[i] = i end
    -- 带种子的 Fisher–Yates（自实现，不依赖 math.random 的全局状态）
    -- ⚠️ 用 LCG 而不是 xorshift：**Lua 5.1 没有位运算符**，
    --    xorshift 的 `~`/`<<`/`>>` 写不出来（本工程实证 sdbm 哈希时已踩过这个坑）。
    --    数值取自 Numerical Recipes 的经典参数。
    local seed = 2463534242
    local function nextrand()
        seed = (1103515245 * seed + 12345) % 2147483648
        return seed
    end
    for i = 255, 1, -1 do
        local j = nextrand() % (i + 1)
        perm[i], perm[j] = perm[j], perm[i]
    end
    for i = 0, 255 do
        p[i] = perm[i]
        p[i + 256] = perm[i]
    end
end

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
local function lerp(a, b, t) return a + t * (b - a) end

--- 12 个梯度方向（Perlin 2002 的改进集：不含 ±1 分量，值域更收敛）
local GRAD3 = {
    { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
    { 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 },
    { 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 },
}

--- 三维 Perlin 噪声，返回 [-1, 1] 附近的值
--- 与原版 `perlin(x, y, z)` 的三参数签名一致。
function M.perlin(x, y, z)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    z = tonumber(z) or 0

    -- 注意：Lua 的 % 对负数返回非负（与 C 的取模不同），所以直接 % 256 就对
    local xr = x - math.floor(x)
    local yf = y - math.floor(y)
    local zf = z - math.floor(z)
    local xi = math.floor(x) % 256
    local yi = math.floor(y) % 256
    local zi = math.floor(z) % 256

    local u, v, w = fade(xr), fade(yf), fade(zf)

    local A  = p[xi] + yi
    local AA = p[A] + zi
    local AB = p[A + 1] + zi
    local B  = p[xi + 1] + yi
    local BA = p[B] + zi
    local BB = p[B + 1] + zi

    local function dot3(h, dx, dy, dz)
        local g = GRAD3[(h % 12) + 1]
        return g[1] * dx + g[2] * dy + g[3] * dz
    end

    local x1 = lerp(dot3(p[AA],     xr,     yf,     zf),
                    dot3(p[BA],     xr - 1, yf,     zf), u)
    local x2 = lerp(dot3(p[AB],     xr,     yf - 1, zf),
                    dot3(p[BB],     xr - 1, yf - 1, zf), u)
    local y1 = lerp(x1, x2, v)

    local x3 = lerp(dot3(p[AA + 1], xr,     yf,     zf - 1),
                    dot3(p[BA + 1], xr - 1, yf,     zf - 1), u)
    local x4 = lerp(dot3(p[AB + 1], xr,     yf - 1, zf - 1),
                    dot3(p[BB + 1], xr - 1, yf - 1, zf - 1), u)
    local y2 = lerp(x3, x4, v)

    local n = lerp(y1, y2, w)
    -- 归一化：3D 改进版 Perlin 的理论极值约 ±1.03，缩到 [-1,1]
    return n * 0.9701
end

M._perm = p   -- 供探针检查确定性

return M
