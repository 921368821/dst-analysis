--============================================================
-- 文件：map/static_layouts/vault_vault.lua
-- 模块：static_layouts / vault_vault
-- 职责：static_layouts模块中的「vault_vault」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

return {
  version = "1.1",
  luaversion = "5.1",
  orientation = "orthogonal",
  width = 13,
  height = 13,
  tilewidth = 64,
  tileheight = 64,
  properties = {},
  tilesets = {
    {
      name = "tiles",
      firstgid = 1,
      tilewidth = 64,
      tileheight = 64,
      spacing = 0,
      margin = 0,
      image = "../../../../tools/tiled/dont_starve/tiles.png",
      imagewidth = 512,
      imageheight = 512,
      properties = {},
      tiles = {}
    }
  },
  layers = {
    {
      type = "tilelayer",
      name = "BG_TILES",
      x = 0,
      y = 0,
      width = 13,
      height = 13,
      visible = true,
      opacity = 1,
      properties = {},
      encoding = "lua",
      data = {
        0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0,
        0, 1, 1, 1, 1, 51, 51, 51, 1, 1, 1, 1, 0,
        0, 1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1, 0,
        0, 1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1, 0,
        1, 1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1, 1,
        1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1,
        1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1,
        1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1,
        1, 1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1, 1,
        0, 1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1, 0,
        0, 1, 51, 51, 51, 51, 51, 51, 51, 51, 51, 1, 0,
        0, 1, 1, 1, 1, 51, 51, 51, 1, 1, 1, 1, 0,
        0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0
      }
    },
    {
      type = "objectgroup",
      name = "FG_OBJECTS",
      visible = true,
      opacity = 1,
      properties = {},
      objects = {
        {
          name = "",
          type = "vaultmarker_vault_center",
          shape = "rectangle",
          x = 416,
          y = 416,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "vaultmarker_vault_north",
          shape = "rectangle",
          x = 416,
          y = 96,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "vaultmarker_vault_east",
          shape = "rectangle",
          x = 736,
          y = 416,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "vaultmarker_vault_south",
          shape = "rectangle",
          x = 416,
          y = 736,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "vaultmarker_vault_west",
          shape = "rectangle",
          x = 96,
          y = 416,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        }
      }
    }
  }
}
