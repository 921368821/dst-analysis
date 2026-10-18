--============================================================
-- 文件：prefabs/canopyshadows.lua
-- 模块：预制体 / canopyshadows（建筑与容器）
-- 职责：实体「canopyshadows」的预制体定义。SpawnPrefab("canopyshadows") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function spawnshadow(inst, range, no_lightrays)
    if not TheWorld.shadetiles then
        TheWorld.shadetiles = {}
    end
    if not TheWorld.shadetile_key_to_leaf_canopy_id then
        TheWorld.shadetile_key_to_leaf_canopy_id = {}
    end
    
    local data = { lightrays = {}, shadetile_keys = {} }
	
    local x,y,z = inst.Transform:GetWorldPosition()
    for i=-range,range do
        for t=-range,range do
            if ((t*t) + (i*i)) <= range*range then
                local newx = (math.floor((x+(i*4))/4)*4) +2
                local newz = (math.floor((z+(t*4))/4)*4) +2

                local shadetile_key = newx.."-"..newz
                table.insert(data.shadetile_keys, shadetile_key)

                if not TheWorld.shadetiles[shadetile_key] or TheWorld.shadetiles[shadetile_key] <= 0 then
                    if math.random()<0.8 then
                        TheWorld.shadetile_key_to_leaf_canopy_id[shadetile_key] = SpawnLeafCanopy(newx, newz)
                    elseif not no_lightrays then
                        if math.random()<0.5 then
                            local rays = SpawnPrefab("lightrays_canopy")
                            rays.Transform:SetPosition(newx, 0, newz)
                            table.insert(data.lightrays, rays)
                        end
                    end
                    TheWorld.shadetiles[shadetile_key] = 1
                else
                    TheWorld.shadetiles[shadetile_key] = TheWorld.shadetiles[shadetile_key] + 1
                end
            end
        end
    end
    
    return data
end

return { spawnshadow = spawnshadow }