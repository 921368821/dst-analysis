--============================================================
-- 文件：components/spidermutator.lua
-- 模块：组件 / spidermutator
-- 职责：组件「spidermutator」的实现。组件是挂在实体上的行为单元，通过 inst.components.spidermutator 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SpiderMutator = Class(function(self, inst)
    self.inst = inst
end)

function SpiderMutator:SetMutationTarget(target)
    self.mutation_target = target
end

function SpiderMutator:CanMutate(spider)
    return spider.prefab ~= self.mutation_target
end

function SpiderMutator:Mutate(spider, skip_event, giver)
    if spider.components.inventoryitem and spider.components.inventoryitem.owner ~= nil then
        
        local owner = spider.components.inventoryitem.owner
    	local new_spider = SpawnPrefab(self.mutation_target)
        local component_name = owner.components.inventory ~= nil and "inventory" or "container"
        local slot = owner.components[component_name]:GetItemSlot(spider)

        owner.components[component_name]:RemoveItem(spider)
        spider:Remove()

        owner.components[component_name]:GiveItem(new_spider, slot)
        new_spider.components.follower:SetLeader(giver)
    else	
	    spider.mutation_target = self.mutation_target
		spider.mutator_giver = giver

	    if not skip_event then
	    	spider:PushEvent("mutate")
	    end
    end


    if self.inst.components.stackable then
    	self.inst.components.stackable:Get():Remove()
    else
    	self.inst:Remove()
    end
end

return SpiderMutator