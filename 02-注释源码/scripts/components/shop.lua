--============================================================
-- 文件：components/shop.lua
-- 模块：组件 / shop
-- 职责：组件「shop」的实现。组件是挂在实体上的行为单元，通过 inst.components.shop 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Shop = Class(function(self, inst)
    self.inst = inst
	self.tab = ""
	self.title = "Shop"
end)

function Shop:SetStartTab(tab)
	self.tab = tab
end

function Shop:SetTitle(title)
	self.title = title
end

function Shop:DeliverItems(items)
	assert(items)
	local x, y, z = self.inst.Transform:GetWorldPosition()
	local physcsPT = Vector3(x, y, z) + Vector3(0,4.5,0)

	-- loop through and create objects
	for k,prefab in pairs(items) do
		print('Spawning', prefab)
		local item = SpawnPrefab(prefab)
		if item then
			if item.Physics then
				item.Transform:SetPosition(physcsPT:Get())
				local angle = 0
				local sp = math.random()*6+3
				item.Physics:SetVel(sp*math.cos(angle), math.random()*3+10, sp*math.sin(angle))
			else
				item.Transform:SetPosition(	x-math.random()*6, y, z-math.random()*6 )
			end
		else
			print('Could not spawn', prefab)
		end
	end
end


return Shop
