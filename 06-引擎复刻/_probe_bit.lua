-- 探针：bit 库正确性对照（与 Python 真位运算逐例对齐）
-- 覆盖 DST 实际用到的 6 个函数 + 边界（0、全 1、符号位、大位移、变参）
package.path = "./?.lua;./host/?.lua;" .. package.path

local bit = require("host.21_bit")

local cases = {}
local function T(expr, got, want)
    cases[#cases + 1] = { expr, got, want }
end

-- band
T("band(0xFF, 0x0F)", bit.band(0xFF, 0x0F), 0x0F)
T("band(6, 3)", bit.band(6, 3), 2)
T("band(-1, 0xFF)", bit.band(-1, 0xFF), 255)
T("band(0, 0xFFFFFFFF)", bit.band(0, 0xFFFFFFFF), 0)
T("band(0xFFFFFFFF, 0xFFFFFFFF)", bit.band(0xFFFFFFFF, 0xFFFFFFFF), -1)
T("band(255,15,7) 变参", bit.band(255, 15, 7), 7)
T("band(0x12345678, 0xFFFF)", bit.band(0x12345678, 0xFFFF), 0x5678)

-- bor
T("bor(1, 2)", bit.bor(1, 2), 3)
T("bor(4, 8, 32)", bit.bor(4, 8, 32), 44)
T("bor(0xFF00, 0x00FF)", bit.bor(0xFF00, 0x00FF), 0xFFFF)
T("bor(-1, 0)", bit.bor(-1, 0), -1)
T("bor(0,0,0,5) 变参", bit.bor(0, 0, 0, 5), 5)

-- bxor
T("bxor(0xFF, 0x0F)", bit.bxor(0xFF, 0x0F), 0xF0)
T("bxor(5, 3)", bit.bxor(5, 3), 6)
T("bxor(7, 7)", bit.bxor(7, 7), 0)
T("bxor(1,2,3) 变参", bit.bxor(1, 2, 3), 0)

-- bnot
T("bnot(0)", bit.bnot(0), -1)
T("bnot(-1)", bit.bnot(-1), 0)
T("bnot(0xFF)", bit.bnot(0xFF), -256)

-- lshift
T("lshift(1, 4)", bit.lshift(1, 4), 16)
T("lshift(0xFF, 8)", bit.lshift(0xFF, 8), 0xFF00)
T("lshift(1, 31)", bit.lshift(1, 31), -2147483648)   -- LuaBitOp 返回有符号
T("lshift(1, 32)", bit.lshift(1, 32), 0)
T("lshift(1, -4)", bit.lshift(1, -4), 0)          -- 负位移反向 = rshift(1,4)=0
T("lshift(0xFFFF, 16)", bit.lshift(0xFFFF, 16), -65536)

-- rshift
T("rshift(0xFF00, 8)", bit.rshift(0xFF00, 8), 0xFF)
T("rshift(1, 31)", bit.rshift(1, 31), 0)
T("rshift(0x80000000, 31)", bit.rshift(0x80000000, 31), 1)
T("rshift(-1, 1)", bit.rshift(-1, 1), 2147483647)  -- 逻辑右移
T("rshift(255, -4)", bit.rshift(255, -4), 4080)    -- 负位移反向 = lshift(255,4)

-- 真实用法复现
-- farming_manager.lua:96
T("farming 打包", bit.lshift(bit.band(0xAB, 0xFF), 16)
    + bit.lshift(bit.band(0xCD, 0xFF), 8) + bit.band(0xEF, 0xFF), 0xABCDEF)
-- health.lua:657
T("lunar burn 归约", bit.bor(bit.bor(0, 1), 4), 5)
-- inspectaclesparticipant.lua:81
-- inspectaclesparticipant.lua:81-83：x = (tx & 0xFFF) << 12; z = ty & 0xFFF;
--   result = (gameid * (x + z)) & 0xFFFFFF。tx=0x123, ty=0x456, gameid=1
--   → (0x123000 + 0x456) & 0xFFFFFF = 0x123456 = 1193046
T("谜题编码", bit.band(bit.lshift(bit.band(0x123, 0xFFF), 12) + bit.band(0x456, 0xFFF), 0xFFFFFF),
    0x123456)

local pass, fail = 0, 0
for _, c in ipairs(cases) do
    if c[2] == c[3] then
        pass = pass + 1
    else
        fail = fail + 1
        print(string.format("  ✘ %-34s 得 %s  期望 %s", c[1], tostring(c[2]), tostring(c[3])))
    end
end
print(string.format("bit 库对照：%d 通过 / %d 失败（共 %d 例）", pass, fail, #cases))
