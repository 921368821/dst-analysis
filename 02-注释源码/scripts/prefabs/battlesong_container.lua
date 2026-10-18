--============================================================
-- 文件：prefabs/battlesong_container.lua
-- 模块：预制体 / battlesong_container（建筑与容器）
-- 职责：实体「battlesong_container」的预制体定义。SpawnPrefab("battlesong_container") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/ui_icepack_2x3.zip"),
    Asset("ANIM", "anim/battlesong_container.zip"),
    Asset("INV_IMAGE", "battlesong_container_open"),
}

local prefabs =
{

}

-----------------------------------------------------------------------------------------------

local SOUNDS =
{
    open  = "meta3/wigfrid/battlesong_container_open",
    close = "meta3/wigfrid/battlesong_container_close",
}

-----------------------------------------------------------------------------------------------

local function OnOpen(inst)
    if inst:HasTag("burnt") then
        return
    end

    inst.AnimState:PlayAnimation("open")
    inst.components.inventoryitem:ChangeImageName("battlesong_container_open")
    inst.SoundEmitter:PlaySound(inst._sounds.open)
end

local function OnClose(inst)
    if inst:HasTag("burnt") then
        return
    end

    if inst.components.inventoryitem.owner == nil then
        inst.AnimState:PlayAnimation("close")
        inst.AnimState:PushAnimation("closed", false)
    else
        inst.AnimState:PlayAnimation("closed", false)
    end
    inst.components.inventoryitem:ChangeImageName()
    inst.SoundEmitter:PlaySound(inst._sounds.close)
end

local function OnPutInInventory(inst)
    inst.components.container:Close()
    inst.AnimState:PlayAnimation("closed", false)
end

-----------------------------------------------------------------------------------------------

local function OnBurnt(inst)
    inst.components.container:DropEverything()
    DefaultBurntFn(inst)
end

-----------------------------------------------------------------------------------------------

local function OnSave(inst, data)
    if (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) or inst:HasTag("burnt") then
        data.burnt = true
    end
end

local function OnLoad(inst, data)
    if data ~= nil and data.burnt and inst.components.burnable ~= nil then
        inst.components.burnable.onburnt(inst)
    end
end

-----------------------------------------------------------------------------------------------

local floatable_swap_data = { bank = "battlesong_container", anim = "closed" }

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst.MiniMapEntity:SetIcon("battlesong_container.png")

    inst.AnimState:SetBank("battlesong_container")
    inst.AnimState:SetBuild("battlesong_container")
    inst.AnimState:PlayAnimation("closed")

    MakeInventoryPhysics(inst)

    MakeInventoryFloatable(inst, "small", 0.3, {0.8, 1, 0.8}, nil, nil, floatable_swap_data)

    inst.entity:SetPristine()

    inst:AddTag("portablestorage")

    if not TheWorld.ismastersim then
        return inst
    end

    inst._sounds = SOUNDS

    inst:AddComponent("inspectable")
    inst:AddComponent("lootdropper")

    inst:AddComponent("container")
    inst.components.container:WidgetSetup("battlesong_container")
    inst.components.container.restrictedtag = "battlesongcontaineruser"
    inst.components.container.onopenfn = OnOpen
    inst.components.container.onclosefn = OnClose
    inst.components.container.skipclosesnd = true
    inst.components.container.skipopensnd = true
    inst.components.container.droponopen = true

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetOnPutInInventoryFn(OnPutInInventory)

    MakeSmallBurnable(inst)
    MakeMediumPropagator(inst)

    inst.components.burnable:SetOnBurntFn(OnBurnt)

    inst.OnSave = OnSave
    inst.OnLoad = OnLoad

    MakeHauntableLaunchAndDropFirstItem(inst)

    return inst
end


return Prefab("battlesong_container", fn, assets, prefabs)