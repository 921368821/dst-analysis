--============================================================
-- 文件：components/migrationpetowner.lua
-- 模块：组件 / migrationpetowner
-- 职责：组件「migrationpetowner」的实现。组件是挂在实体上的行为单元，通过 inst.components.migrationpetowner 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MigrationPetOwner = Class(function(self, inst)
    -- A lightweight component to easily pass through a prefab
    -- capable of migrating alongside an inventory item.

    self.inst = inst

    --self.get_pet_fn = nil
end)

function MigrationPetOwner:SetPetFn(petfn)
    self.get_pet_fn = petfn
end

function MigrationPetOwner:GetPet() -- Partial deprecation useful for checking if a pet exists but nothing else.
    if self.get_pet_fn then
        local pets = self.get_pet_fn(self.inst)
        if EntityScript.is_instance(pets) then -- Backwards compatability.
            return pets
        elseif type(pets) == "table" then
            return pets[1]
        end
    end
    return nil
end

function MigrationPetOwner:GetAllPets()
    if self.get_pet_fn then
        local pets = self.get_pet_fn(self.inst)
        if EntityScript.is_instance(pets) then -- Backwards compatibility
            return { pets }
        end
        return pets
    end
    return nil
end

return MigrationPetOwner
