--============================================================
-- 文件：map/static_layouts/waterplant1.lua
-- 模块：static_layouts / waterplant1
-- 职责：static_layouts模块中的「waterplant1」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

return {
  version = "1.1",
  luaversion = "5.1",
  orientation = "orthogonal",
  width = 10,
  height = 10,
  tilewidth = 64,
  tileheight = 64,
  properties = {},
  tilesets = {
    {
      name = "ground",
      firstgid = 1,
      filename = "../../../../tools/tiled/dont_starve/ground.tsx",
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
      width = 10,
      height = 10,
      visible = true,
      opacity = 1,
      properties = {},
      encoding = "lua",
      data = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 26, 26, 0, 0, 0, 0,
        0, 0, 0, 26, 26, 26, 26, 0, 0, 0,
        0, 0, 0, 26, 26, 26, 26, 0, 0, 0,
        0, 0, 0, 26, 26, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
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
          type = "waterplant",
          shape = "rectangle",
          x = 400,
          y = 293,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "waterplant",
          shape = "rectangle",
          x = 323,
          y = 255,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "waterplant",
          shape = "rectangle",
          x = 239,
          y = 308,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "waterplant",
          shape = "rectangle",
          x = 266,
          y = 394,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        }
      }
    }
  }
}
