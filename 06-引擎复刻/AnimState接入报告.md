# AnimState 接入报告（第 1 项）

> 目标：把 ZipAnim 解码器接进 Lua 宿主，让 AnimState 不再只是桩。

## 1. 做了什么

### 桥接设计
```
DST 的 anim.zip
      ↓  tools/ktex.py      （KTEX + DXT5 → PNG）
      ↓  tools/export_anim.py（build+anim → Lua 表）
   anim_data/<build名>.lua     ← 宿主直接 loadfile
   anim_data/<build名>__atlas-0.png
      ↓  host/10_animstate.lua（装饰器接管 AnimState 桩）
   AnimState:PlayAnimation("idle_loop")
          :GetDrawList()   ← 每帧要画的图块（符号 + UV + 顶点 + 变换矩阵）
      ↓  render.lua（宿主导出绘制列表）
   _out/drawlist.txt
      ↓  tools/render_host.py（用图集光栅化）
   _out/host__<生物>.png
```

### 三个新增件
| 文件 | 作用 |
|---|---|
| `tools/export_anim.py` | 把 build+anim 合成一张 Lua 表（**可合并多个 zip**） |
| `host/10_animstate.lua` | AnimState 的**真实实现**（帧推进 / GetDrawList / GetAnimInfo） |
| `render.lua` + `tools/render_host.py` | 宿主导出 + 外部光栅化，闭环出图 |

### 关键实现点
- **装饰器机制**：给 `Stubs.Make` 加了 `Stubs.AddDecorator`，
  让宿主模块能在桩建好之后「接管」它。首个用户就是 AnimState。
  找不到数据时装饰器**自动退回桩行为**，所以既有五入口零回退。
- **多 zip 合并**：DST 把贴图(build)与动画(anim)拆成两个包
  （`pig_build.zip` + `ds_pig_basic.zip`），两边用同一套符号哈希指代，
  按 hash 合并即可。这也是此前「交叉引用 8% 未命中」的原因 —— 它们本就在彼此包里。

## 2. 验证结果

```
AnimState 真实实现已启用: true
pigman  build=pig_build  anim=idle_loop  帧=1/16  图块=10
rabbit  build=rabbit_build  anim=idle    帧=1/30  图块=21
spider  build=spider_build  anim=idle    帧=1/2   图块=14
beefalo build=beefalo_build anim=alert_idle 帧=1/44 图块=14
30 tick 后 frame=14  time=1.000        ← 帧真的在推进
```

绘制列表里是**真符号名与真变换**，例如：
```
pig_torso  顶点=126  mat=(0.85, 0.00, 0.00, 0.85, -0.5, -102.3)
pig_ear    顶点=12   mat=(-0.85, 0.00, 0.00, 0.85, 39.7, -247.2)   ← 负 x 缩放 = 镜像的左耳
```

### ★ 出图验证
| 生物 | 图集数 | 渲染结果 |
|---|---|---|
| **rabbit** | 1 | **✔ 一只完整的兔子**（棕毛、白尾、长耳、胡须） |
| **spider** | 1 | **✔ 一只完整的蜘蛛**（黑毛身体 + 腿） |
| **charlie** | 1 | ✔ 正立人物（第四阶段已验） |
| **pigman** | 2 | **✔ 一只完整的猪人**（猪头带耳、双臂、躯干、毛边裙、腿） |

## 3. 已完成 / 未完成（如实）

### 已完成
**从 prefab 到 PNG 的整条链路完全打通**，单图集与多图集都能正确渲染。
rabbit（兔）、spider（蜘蛛）、charlie（人物）、pigman（猪人）四例
都渲染出可辨认的完整生物。

### ★ 多图集 build 的「符号 → 图集」映射 —— **已解决**
`pig_build` / `beefalo_build` 各有 **2 个图集**（atlas-0 2048×2048、
atlas-1 1024×512），但 BILD 的符号条目里**没有图集索引字段**
（解析是逐字节守恒的，多一个字段就对不上），所以宿主不知道该拿哪个图集采样。

**解法：用一条可推导的等式判归属**

```
UV 跨度 × 图集尺寸 == bbox 的 w/h（像素）
```

也就是 **图集宽 = bbox_w ÷ du**，反推出来再跟候选图集比。实测：

| 符号 | bbox | UV 跨度 | ÷ 得 | 归属 |
|---|---|---|---|---|
| `pig_head` | 177×186 | 0.08643 | **2048** | atlas-0 ✓ |
| `pig_arm` | 86×222 | 0.08398 | **1024** | atlas-1 ✓ |
| `pig_ear` | 105×97 | 0.10254 | **1024** | atlas-1 ✓ |
| `pig_skirt` | 82×176 | 0.08008 | **1024** | atlas-1 ✓ |

每个符号都**只有一个**图集能让等式成立（另一个差 2 倍以上），判据是干净的。
已在 `tools/export_anim.py::assign_atlas` 实现，导出的表里每个符号带 `atlas=N`。

走错过的两条路（记下来免得重走）：
- **用 bbox 直接当图集矩形**：不行 —— bbox 是「相对锚点的裁剪框」，可为负
- **整个符号一律用 atlas-1**：更错（画面被劈成两半）

**修好之后猪人渲染正确**：猪头带耳朵、双臂、粉色躯干、橙色毛边裙、双腿。

## 4. 五个入口零回退

`run` / `batch` / `player` / `play` / `full` 全部仍 PASS，
并且 `play.lua` 里猪人的状态迁移从 21 次变成 24 次（AnimState 不再拖后腿）。
