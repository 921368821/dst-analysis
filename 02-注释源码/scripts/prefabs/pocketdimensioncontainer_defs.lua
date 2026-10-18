--============================================================
-- 文件：prefabs/pocketdimensioncontainer_defs.lua
-- 模块：预制体 / pocketdimensioncontainer_defs（建筑与容器）
-- 职责：实体「pocketdimensioncontainer_defs」的预制体定义。SpawnPrefab("pocketdimensioncontainer_defs") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local POCKETDIMENSIONCONTAINER_DEFS = {
	{
		name = "shadow",
		prefab = "shadow_container",
		ui = "anim/ui_portal_shadow_3x4.zip",
		widgetname = "shadow_container",
		tags = { "spoiler" },
	},
	{
		name = "rabbitkinghorn",
		prefab = "rabbitkinghorn_container",
		ui = "anim/ui_portal_rabbitkinghorn_3x4.zip",
		widgetname = "rabbitkinghorn_container",
	},
}

return { POCKETDIMENSIONCONTAINER_DEFS = POCKETDIMENSIONCONTAINER_DEFS, }