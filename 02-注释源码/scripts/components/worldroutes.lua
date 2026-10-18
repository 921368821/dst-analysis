--============================================================
-- 文件：components/worldroutes.lua
-- 模块：组件 / worldroutes
-- 职责：组件「worldroutes」的实现。组件是挂在实体上的行为单元，通过 inst.components.worldroutes 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- NOTES(JBK): WorldRoutes stores static information about a world for creating circular paths across traverseable terrain.
-- These calculations can be computationally complex and so it is cached in this component.
local WorldRoutes = Class(function(self, inst)
    local _world = TheWorld
    assert(_world.ismastersim, "WorldRoutes should not exist on client")
    assert(inst == _world, "WorldRoutes must be on TheWorld")
    self.inst = inst

    self.routes = {}
end)

function WorldRoutes:SetRoute(routename, route)
    self.routes[routename] = route
end

function WorldRoutes:GetRoute(routename)
    return self.routes[routename]
end

function WorldRoutes:OnSave()
    local routes_saved = {}
    for routename, route in pairs(self.routes) do
        local routesavedata = {}
        routes_saved[routename] = routesavedata
        for i, v in ipairs(route) do
            routesavedata[i] = {v.x, v.z}
        end
    end
    if next(routes_saved) == nil then
        return nil
    end

    return {
        routes = routes_saved,
    }
end

function WorldRoutes:OnLoad(data)
    if not data then
        return
    end

    if data.routes then
        for routename, routesavedata in pairs(data.routes) do
            local route = {}
            self.routes[routename] = route
            for i, v in ipairs(routesavedata) do
                route[i] = Vector3(v[1], 0, v[2])
            end
        end
    end
end

return WorldRoutes
