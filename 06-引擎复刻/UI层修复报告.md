# UI 层修复报告（第 3 项）

> 目标：修掉 `screens/` 与 `widgets/` 的 require 失败（此前记录为 9 处）。

## 1. 先做的一件事：让缺口清单能说「为什么」

原先的缺口记录只写 `require:<模块名>`，看清单完全不知道失败原因。
改 `host/04_loader.lua`，把错误原因摘要带进缺口记录，并加了
`Loader.DumpFailures()` 打印全文。改完之后一眼就看出问题高度聚集：

```
require 失败 8 个:
  components/snowmandecoratable  …snowmandecoratable.lua:46: attempt to call global 'hash' (a nil value)
  cooking                        …cooking.lua:119: bad argument #1 to 'pairs' (table expected, got nil)
  prefabs/oceanfishdef           …oceanfishdef.lua:1079: attempt to index field '?' (a nil value)
  screens/chatinputscreen        …chatinputscreen.lua:15: attempt to call method 'PlatformUsesVirtualKeyboard' (a nil value)
  screens/redux/barterscreen     …barterscreen.lua:60: attempt to call global 'ValidateLineNumber' (a nil value)
  screens/redux/popupdialog      …popupdialog.lua:76: attempt to call global 'ValidateLineNumber' (a nil value)
  widgets/imagebutton            …imagebutton.lua:173: attempt to call global 'ValidateLineNumber' (a nil value)
  widgets/widget                 …widget.lua:123: attempt to call global 'ValidateLineNumber' (a nil value)
```

**8 个失败里 4 个是同一个原因**（`ValidateLineNumber`）。
「先让错误可读」这一步本身就省掉了大量盲猜。

## 2. 实际只补了三样东西

| 补的东西 | 定义处 | 修好了几个 |
|---|---|---:|
| `ValidateLineNumber(num)` | `main.lua:54`（只转发给 `TheSim`，no-op 即可） | **4** |
| `hash(s)` | C++ 引擎函数，Lua 侧无定义 | 1 |
| `TheInput:PlatformUsesVirtualKeyboard()` | 引擎方法 | 1 |

`chatinputscreen.lua:15` 是在**顶层**就调用 `PlatformUsesVirtualKeyboard()` 的，
所以 `TheInput` 必须**已经有**这个方法，不能靠惰性兜底。

### ⚠️ 一个 Lua 5.1 兼容性坑
`hash` 我一开始写成 FNV-1a —— **Lua 5.1 没有位运算符**，
`~`（异或）是 5.3+ 才有的。写完导致整个 `03_globals.lua` 加载失败。
改用纯算术的 31 进制多项式哈希（确定性够用，因为那些哈希值只在宿主内部做表键，
不与引擎或其他进程比较）。

## 3. ★ 最难的一个：`GROUND` 与 `WORLD_TILES` 必须同源

剩下两个失败（`oceanfishdef` 与连带的 `cooking`）根因很隐蔽：

```lua
-- oceanfishdef.lua:1032   用 WORLD_TILES 建表
[WORLD_TILES.OCEAN_SWELL] = { ... }

-- oceanfishdef.lua:1079   却用 GROUND 取值
SCHOOL_WEIGHTS[SEASONS.AUTUMN][GROUND.OCEAN_SWELL].oceanfish_small_6 = ...
```

真引擎里 **`WORLD_TILES` 就是 `GROUND` 再加一个 `INVALID`**（同一套编号），
所以两处指向同一个键。而宿主把两者做成了**独立的惰性表**，各自从 100 起发号 ——
`WORLD_TILES.OCEAN_SWELL ≠ GROUND.OCEAN_SWELL`，于是取到 nil 直接崩。

**这类坑很隐蔽**：单看任何一张表都完全正常，只有交叉使用时才暴露。

修法有两条，都做了：
1. `GROUND` 改用 `constants.lua:753` 的**真表**（而非「任何键都返 0」的假表）
2. `WORLD_TILES` 的惰性查找**先查 GROUND**，保证可用地形键两边同值

## 4. 结果

```
════ require 失败原因 ════
  （无 require 失败）
```

**8 → 0。** 全量扫描的覆盖率也跟着提升：

| 指标 | 修前 | 修后 |
|---|---:|---:|
| 注册了预制体的文件 | 1513 | **1521** |
| 加载失败 | 15 | **6** |
| 注册表预制体总数 | 5941 | **6010** |

六个入口（run / batch / player / play / full / render）全部 PASS。

## 5. 小结

UI 层的「9 处 require 失败」回头看**不是 UI 本身的问题**，
而是三个基础全局缺失 + 一个表同源问题。真正难的不是补函数，
而是**先让错误可读**（缺口清单带原因）和**发现两张表本该同源**。
