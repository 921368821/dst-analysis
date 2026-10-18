--[[
==============================================================================
 27_prefabskin_globals.lua —— prefabskin.lua 顶层的 8 张全局空表
==============================================================================
问题
   `components/skinner.lua` **直接索引**一批全局表，没有 nil 守卫：
       :64   local tuck_torso    = BASE_TORSO_TUCK[base_skin] or "skirt"
       :67   local legs_cuff_size= BASE_LEGS_SIZE[base_skin] or 1
       :344  ... ONE_PIECE_SKIRT[base_skin] ...
   而这些全局由 `prefabskin.lua` 在文件**最开头**声明（初始为空表），
   之后由 CreatePrefabSkin 内部逐条填充。宿主不加载 prefabskin.lua
   （实测负收益：失败 4→38、注册表 6075→5190），于是它们全是 nil。

   实测症状（reachability.lua 抽样）：
       ✘ attempt to index global 'BASE_TORSO_TUCK' (a nil value)   （第一层）
       ✘ attempt to index global 'ONE_PIECE_SKIRT' (a nil value)   （补了 5 个之后露出的第二层）
   ★★ 这就是「枚举法会漏」的第 N 次实证：
      我先手工列了 5 个（BASE_* 系列），漏掉 ONE_PIECE_SKIRT /
      SKIN_FX_PREFAB / SKIN_SOUND_FX —— 因为我是**凭印象**列的。
      ⇒ 改成**从真实文件静态提取**，不再手写清单。
      （与 `entity:AddXxx` 那次的修法完全一致：静态扫描 + 做差。）

做法
   启动时读 prefabskin.lua，匹配零缩进的 `NAME = {}` 声明，逐个建空表。
   这样**清单永远与真实文件同步**，换版本也自动跟上。

诚实边界
   · 只重建「声明为空表」的那些。原版后续会填充（皮肤专属覆盖），
     宿主不填 ⇒ 一律走**默认值**（`or "skirt"` / `or 1` / `or nil`）。
     这与原版「该皮肤没有特殊设置」的语义一致，不是「假装有皮肤系统」。
   · `SKIN_FX_PREFAB` / `SKIN_SOUND_FX` 在宿主里同样保持空 ⇒
     `skinner` 相关的特效/音效查找返回 nil，走「没有特效」分支。
==============================================================================
]]

local Core = require("host.01_core")

local PSG = {}

PSG.File = Core.SourceDir .. "/prefabskin.lua"
PSG.Names = {}          -- 提取到的名字（按出现顺序）
PSG.Created = {}        -- 实际创建了的名字
PSG.Error = nil

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- 提取零缩进的 `NAME = {}` 声明
-- ★ 只认「顶层」：行首不能有空白 —— 缩进的赋值是函数内的，不是全局声明。
function PSG.Extract(src)
    local names = {}
    for line in src:gmatch("[^\r\n]+") do
        local nm = line:match("^([A-Z][A-Z0-9_]*)%s*=%s*{%s*}%s*$")
        if nm ~= nil then
            names[#names + 1] = nm
        end
    end
    return names
end

function PSG.Install()
    local src = read_all(PSG.File)
    if src == nil then
        PSG.Error = "打不开 " .. PSG.File
        Core.NoteGap("prefabskin 全局表: 源文件不可读", "prefabskin-globals")
        return false
    end

    local names = PSG.Extract(src)
    PSG.Names = names
    if #names == 0 then
        -- ★ 一条都提取不到 = 锚点失效（文件结构变了）。
        --   不静默：这是「静默空实现」的温床，必须显式记缺口。
        PSG.Error = "一个全局空表都没提取到（文件结构可能变了）"
        Core.NoteGap("prefabskin 全局表: 提取到 0 条", "prefabskin-globals")
        return false
    end

    for _, nm in ipairs(names) do
        if _G[nm] == nil then
            _G[nm] = {}
            PSG.Created[#PSG.Created + 1] = nm
        end
    end
    return true
end

--- 自检：真实文件里的每一个都必须在 _G 里存在
function PSG.Audit()
    local missing = {}
    for _, nm in ipairs(PSG.Names) do
        if type(_G[nm]) ~= "table" then missing[#missing + 1] = nm end
    end
    return #missing == 0, missing
end

return PSG
