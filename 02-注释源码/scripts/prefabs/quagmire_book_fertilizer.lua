--============================================================
-- 文件：prefabs/quagmire_book_fertilizer.lua
-- 模块：预制体 / quagmire_book_fertilizer（建筑与容器）
-- 职责：实体「quagmire_book_fertilizer」的预制体定义。SpawnPrefab("quagmire_book_fertilizer") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/books.zip"),
    Asset("INV_IMAGE", "book_gardening")
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("books")
    inst.AnimState:SetBuild("books")
    inst.AnimState:PlayAnimation("book_gardening")

    inst:SetPrefabNameOverride("book_gardening")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_book_fertilizer").master_postinit(inst)

    return inst
end

return Prefab("quagmire_book_fertilizer", fn, assets)
