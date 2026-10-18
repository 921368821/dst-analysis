--============================================================
-- 文件：map/static_layouts/skeleton_notplayer.lua
-- 模块：static_layouts / skeleton_notplayer
-- 职责：static_layouts模块中的「skeleton_notplayer」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

return {
  version = "1.1",
  luaversion = "5.1",
  orientation = "orthogonal",
  width = 4,
  height = 4,
  tilewidth = 16,
  tileheight = 16,
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
      width = 4,
      height = 4,
      visible = true,
      opacity = 1,
      properties = {},
      encoding = "lua",
      data = {
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0
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
          type = "skeleton_notplayer_1",
          shape = "rectangle",
          x = 20,
          y = 21,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "skeleton_notplayer_2",
          shape = "rectangle",
          x = 40,
          y = 41,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "silk",
          shape = "rectangle",
          x = 7,
          y = 47,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "cavelight_small",
          shape = "rectangle",
          x = 30,
          y = 29,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "silk",
          shape = "rectangle",
          x = 29,
          y = 2,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        },
        {
          name = "",
          type = "silk",
          shape = "rectangle",
          x = 20,
          y = 56,
          width = 0,
          height = 0,
          visible = true,
          properties = {}
        }
      }
    }
  }
}
