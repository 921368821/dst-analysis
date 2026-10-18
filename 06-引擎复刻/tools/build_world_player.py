#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_world_player.py —— 生成自包含的「世界实时播放器」HTML

这是「世界可跑可看」阶段的最后一环：
    world.lua 在宿主里真跑 2400 tick，把每 2 tick 的
    （位置 / 朝向 / 动画名 / 动画帧号 / 状态图状态）导出成 _out/world.json；
    本脚本把它和**真实图集**（anim_data/*.png + _out/json/*.build.json）
    打包成一个自包含 HTML，用 canvas 把整个世界播出来。

渲染要点（继承自 build_player.py，已验证）
    · 动画符号帧是「矩形做仿射变换」→ 目标必为平行四边形，
      直接 ctx.setTransform(A,B,C,D,E,F) + drawImage，精确且快。
    · DST 动画数据 y 向下为正，与 canvas 一致，无需翻转。

本脚本新增的关键决定：**sprite 是 billboard，不做平面旋转**
    DST 的世界是俯视 2.5D，生物的贴图永远正面朝镜头，
    转向只体现为「左右镜像」，而不是把贴图在屏幕平面里旋转。
    依据（两条独立证据）：
      1) 真实 locomotor.lua:1411 注释明确写了角度约定
         「+X 为 0°、顺时针为正」，而贴图只有一套朝向的画。
      2) 用 world.json 的轨迹反推：对 862 个「方向稳定的位移样本」
         做圆统计，rotation 与移动方向角 atan2(dz,dx) 的圆均值偏差
         只有 3.8°（r = θ 拟合），而任何「贴图旋转」模型都对不上。
    所以本播放器：贴图不旋转，仅当朝向朝西（cos r < 0）时水平镜像；
    真实的 rotation 用一根短线段画出来，避免丢失信息。

用法
    cd <工程根>/06-引擎复刻
    python tools/build_world_player.py
    → _out/world_player.html
"""
import base64
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# ★ 输入可用环境变量 / 命令行覆盖：
#     WORLD_JSON=_out/world_day.json python tools/build_world_player.py
#     python tools/build_world_player.py _out/world_day.json _out/day_player.html
_j = os.environ.get('WORLD_JSON') or (sys.argv[1] if len(sys.argv) > 1 else None)
_h = os.environ.get('WORLD_HTML') or (sys.argv[2] if len(sys.argv) > 2 else None)
OUT_JSON = os.path.join(ROOT, _j) if _j else os.path.join(ROOT, '_out', 'world.json')
OUT_HTML = os.path.join(ROOT, _h) if _h else os.path.join(ROOT, '_out', 'world_player.html')
JSON_DIR = os.path.join(ROOT, '_out', 'json')
ATLAS_DIR = os.path.join(ROOT, 'anim_data')

# 与 constants.lua:136 的 TILE_SCALE 一致；用于把动画单位换算成世界单位。
# DST 里动画单位与世界单位的换算系数没有 Lua 侧定义（在 C++ 渲染器里），
# 这里按「生物贴图宽 ≈ 0.4 个格子（=1.6 世界单位）」反推，并在 UI 里做成可调。
DEFAULT_SPRITE_SCALE = 0.0067
TILE_SCALE = 4


# ---------------------------------------------------------------------------
# PNG 读取 / 降采样 / base64（自带，不依赖 Pillow）—— 与 build_player.py 相同
# ---------------------------------------------------------------------------
def read_png(path):
    d = open(path, 'rb').read()
    o, w, h, idat = 8, None, None, b''
    while o < len(d):
        ln = int.from_bytes(d[o:o + 4], 'big')
        tag = d[o + 4:o + 8]
        p = d[o + 8:o + 8 + ln]
        o += 12 + ln
        if tag == b'IHDR':
            w = int.from_bytes(p[0:4], 'big')
            h = int.from_bytes(p[4:8], 'big')
        elif tag == b'IDAT':
            idat += p
        elif tag == b'IEND':
            break
    raw = zlib.decompress(idat)
    stride = w * 4
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    q = 0
    for y in range(h):
        ft = raw[q]; q += 1
        line = bytearray(raw[q:q + stride]); q += stride
        if ft == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(4, stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(4, stride):
                a = line[i - 4] if i >= 4 else 0
                b = prev[i]
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
        elif ft == 5:
            for i in range(4, stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + a) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bytes(out)


def downscale(w, h, px, f):
    nw, nh = w // f, h // f
    out = bytearray(nw * nh * 4)
    for y in range(nh):
        for x in range(nw):
            si = ((y * f) * w + (x * f)) * 4
            di = (y * nw + x) * 4
            out[di:di + 4] = px[si:si + 4]
    return nw, nh, bytes(out)


def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))


def png_b64(w, h, px):
    raw = b''.join(b'\x00' + px[y * w * 4:(y + 1) * w * 4] for y in range(h))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    return base64.b64encode(png).decode('ascii')


# ---------------------------------------------------------------------------
# 数据准备：裁剪 build JSON 到「真正用到的动画 + 符号」
# ---------------------------------------------------------------------------
def collect_builds(world):
    """返回 {buildName: pruned_json_dict}，只保留轨迹里实际用到的动画。

    ★ 符号覆盖（bld）：实体的 build 之外，还要把 sigs 里引用到的 build 一并载入。
      覆盖 build（帽子、鞍子…）**只有覆盖元素在画的时候**才用到，
      所以不必载入它的全部动画 —— 只要「符号」那一半。
    """
    sigs = world.get('sigs') or {}
    used = {}
    for e in world['entities']:
        b = e.get('build')
        if not b:
            continue
        s = used.setdefault(b, set())
        for f in e['frames']:
            if f[4]:
                s.add(f[4])
    # 覆盖 build：sigs[i] = { 元素下标: [符号名, 图集下标, build名] }
    ovb = {}
    # 内层表在 Lua 里是 { [元素下标] = {...} }，键是连续整数 → 序列化成数组；
    # 万一键不连续就是对象，两种都兼容。
    def _vals(t):
        return t.values() if isinstance(t, dict) else (t or [])
    for entries in sigs:                     # sigs 是数组（Lua 侧 #SIG_TABLE）
        for ent in _vals(entries):
            if ent and len(ent) >= 3 and ent[2]:
                # ★ build JSON 的 symbols 是按**字符串**哈希建键的
                #   （"_out/json/*.json" 里形如 "1690368943"），
                #   而 world.json 的 sigs 里是数字（Lua 的 table 键是整数）。
                #   不归一化就一个都匹配不上。
                ovb.setdefault(ent[2], set()).add(str(ent[0]))

    builds = {}
    for b, anim_names in sorted(used.items()):
        jp = os.path.join(JSON_DIR, b + '.json')
        if not os.path.exists(jp):
            print('  ✘ 缺 %s' % jp)
            continue
        d = json.load(open(jp, encoding='utf-8'))

        anims, need_syms = {}, set()
        for an in sorted(anim_names):
            a = d['anims'].get(an)
            if a is None:
                print('    ⚠ %s 缺动画 %s（这些帧将画不出）' % (b, an))
                continue
            anims[an] = a
            for fr in a['frames']:
                for el in fr:
                    need_syms.add(el['sym'])

        symbols = {k: v for k, v in d['symbols'].items() if k in need_syms}
        used_atlas = sorted({v.get('atlas', 0) for v in symbols.values()})
        builds[b] = dict(
            buildName=b,
            anims=anims,
            symbols=symbols,
            atlases=[d['atlases'][i] for i in used_atlas],
            _atlas_index_map={str(i): k for k, i in enumerate(used_atlas)},
        )
        print('    %s：动画 %d / 符号 %d / 图集 %s'
              % (b, len(anims), len(symbols), used_atlas))

    # ---- 覆盖 build：只要符号，不要动画 ----
    for b, sym_names in sorted(ovb.items()):
        if b in builds:
            # 已作为实体 build 载入过；补齐覆盖需要的符号即可
            jp = os.path.join(JSON_DIR, b + '.json')
            d = json.load(open(jp, encoding='utf-8'))
            cur = builds[b]['symbols']
            add = {k: v for k, v in d['symbols'].items()
                   if k in sym_names and k not in cur}
            if add:
                cur.update(add)
                used_atlas = sorted({v.get('atlas', 0)
                                     for v in cur.values()})
                old_map = builds[b]['_atlas_index_map']
                builds[b]['atlases'] = [d['atlases'][i] for i in used_atlas]
                builds[b]['_atlas_index_map'] = {
                    str(i): (old_map[str(i)] if str(i) in old_map else len(old_map))
                    for i in used_atlas}
                # 旧符号的 atlas 下标要按新映射重算
                remap = {int(k): v for k, v in builds[b]['_atlas_index_map'].items()}
                for v in builds[b]['symbols'].values():
                    v['atlas'] = remap.get(v.get('atlas', 0), 0)
            continue
        jp = os.path.join(JSON_DIR, b + '.json')
        if not os.path.exists(jp):
            print('    ✘ 覆盖 build %s 缺 %s（这些覆盖元素将画不出）' % (b, jp))
            continue
        d = json.load(open(jp, encoding='utf-8'))
        symbols = {k: v for k, v in d['symbols'].items() if k in sym_names}
        used_atlas = sorted({v.get('atlas', 0) for v in symbols.values()})
        builds[b] = dict(buildName=b, anims={}, symbols=symbols,
                         atlases=[d['atlases'][i] for i in used_atlas],
                         _atlas_index_map={str(i): k for k, i in enumerate(used_atlas)})
        print('    %s（覆盖）：符号 %d / 图集 %s'
              % (b, len(symbols), used_atlas))
    return builds


def embed_atlases(builds):
    """把每个 build 用到的图集读成 base64，并把符号的 atlas 下标重映射。"""
    for b, d in builds.items():
        arr = []
        for i, info in enumerate(d['atlases']):
            png = os.path.join(ATLAS_DIR, '%s__atlas-%s.png'
                               % (b, info['file'].split('.')[0].split('-')[-1]))
            if not os.path.exists(png):
                png = os.path.join(ATLAS_DIR, '%s__atlas-%d.png' % (b, i))
            w, h, px = read_png(png)
            if max(w, h) > 1200:
                w, h, px = downscale(w, h, px, 2)
            arr.append('data:image/png;base64,' + png_b64(w, h, px))
            print('    %s atlas-%d → %d×%d（嵌入）' % (b, i, w, h))
        d['atlasData'] = arr
        # 把符号里的「原图集下标」重映射成压缩后的下标
        m = d.pop('_atlas_index_map')
        for s in d['symbols'].values():
            s['atlas'] = m[str(s.get('atlas', 0))]
    return builds


# ---------------------------------------------------------------------------
# HTML 模板
# ---------------------------------------------------------------------------
HTML = r"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>DST 世界播放器 · 真实地形 + 真实大脑 + 真实物理</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing:border-box; }
  body { margin:0; background:#12141a; color:#e6e6e6;
         font:13px/1.5 "Segoe UI",-apple-system,sans-serif; overflow:hidden; }
  header { padding:9px 16px; border-bottom:1px solid #262b34; display:flex;
           align-items:baseline; gap:12px; flex-wrap:wrap; }
  h1 { font-size:15px; margin:0; font-weight:600; }
  .muted { color:#828b9a; font-size:11.5px; }
  b { color:#cdd6e0; font-weight:600; }
  #stage { position:relative; width:100vw; height:calc(100vh - 42px); }
  canvas { position:absolute; inset:0; width:100%; height:100%; display:block; }
  /* GL 层默认隐藏：只有 renderer=gl 且 glInit() 成功才显示。
     不显示时它是一块透明的空画布，不影响 2D 层的观感。 */
  #cvgl { display:none; }
  .panel { position:absolute; background:rgba(18,20,26,.9); border:1px solid #2a313c;
           border-radius:8px; padding:9px 11px; backdrop-filter:blur(4px); }
  #legend { left:12px; top:12px; width:190px; }
  #legend .row { display:flex; align-items:center; gap:7px; font-size:11.5px;
                 padding:1px 0; color:#9aa4b2; }
  .sw { width:12px; height:12px; border-radius:3px; flex:none; }
  #info { right:12px; top:12px; width:250px; max-height:calc(100% - 130px); overflow:auto; }
  #info .ent { padding:3px 0; border-bottom:1px dashed #262b34; font-size:11.5px; }
  #info .ent:last-child { border-bottom:none; }
  #ctl { left:12px; right:12px; bottom:12px; display:flex; gap:12px;
         align-items:center; flex-wrap:wrap; }
  button,select,input { background:#1a1e26; color:#e6e6e6; border:1px solid #333b47;
         border-radius:6px; padding:4px 9px; font-size:12.5px; }
  button { cursor:pointer; } button:hover { background:#242a34; }
  button.on { background:#2b6cb0; border-color:#2b6cb0; color:#fff; }
  label { display:flex; gap:5px; align-items:center; font-size:12px; color:#9aa4b2; }
  #tickbar { flex:1; min-width:200px; }
  .kv { display:flex; justify-content:space-between; gap:8px; }
  .kv span:last-child { color:#cdd6e0; }
  .combat { color:#ff8b8b; font-weight:600; }
</style></head><body>
<header>
  <h1>DST 世界播放器</h1>
  <span class="muted" id="src"></span>
</header>
<div id="stage">
  <canvas id="cv"></canvas>
  <!-- ★ WebGL 精灵层：透明、叠在地形层之上、不吃事件。
       为什么分层而不是单块 WebGL：地形是预渲染成 canvas 的（terr），
       把它也搬进 WebGL 要另写一套瓦片着色器，收益低而风险高。
       分层后两块画布各司其职，且 2D 层仍是降级路径。 -->
  <canvas id="cvgl" style="pointer-events:none"></canvas>
  <div class="panel" id="legend"></div>
  <div class="panel" id="info"></div>
  <div class="panel" id="ctl">
    <button id="play">⏸ 暂停</button>
    <label>tick <input type="range" id="tickbar" min="0" value="0"><span id="tnum"></span></label>
    <label>速度 <select id="speed">
      <option value="0.25">0.25×</option><option value="0.5">0.5×</option>
      <option value="1" selected>1×</option><option value="2">2×</option>
      <option value="4">4×</option></select></label>
    <label><input type="checkbox" id="follow" checked> 跟随玩家</label>
    <label><input type="checkbox" id="labels" checked> 名字</label>
    <label><input type="checkbox" id="facing"> 朝向线</label>
    <label><input type="checkbox" id="grid"> 格线</label>
    <label>比例 <select id="sscale">
      <option value="0.5">0.5×</option><option value="1" selected>1×</option>
      <option value="1.5">1.5×</option><option value="2.5">2.5×</option><option value="4">4×</option><option value="6">6×</option><option value="10">10×</option><option value="16">16×</option></select></label>
    <label>缩放 <input type="range" id="zoom" min="40" max="400" value="150" style="width:90px"></label>
  </div>
</div>
<script>
const WORLD = __WORLD__;
const BUILDS = __BUILDS__;
const SPRITE_SCALE = __SPRITE_SCALE__;
const TICK_SCALE = __TILE_SCALE__;

const M = WORLD.map, META = WORLD.meta;
// ★ 符号覆盖去重表：SIGS[i] = { 元素下标: [符号名, 图集下标, build名] }
//   由 world.lua 的 draw_sig() 导出（只在有覆盖时才有条目）。
//   帧数组的第 8 项就是这里的下标（1 基）。
const SIGS = WORLD.sigs || [];
// ★ 昼夜：WORLD.daylight.phases = [[时间秒, 相位名], ...]（只存变化点）
//   查表得到当前相位，据此给画面叠暮色/夜色，并在 HUD 显示「第 N 天 · 相位」。
const DL = WORLD.daylight || null;
// ⚠️ 挑颜色时要注意：叠色是 alpha 混合，**暖色会把画面整体提亮**。
//   第一版 dusk 用 rgba(196,108,44,.22)，实测画面平均亮度反而从 84.3 升到 87.7
//   —— 「黄昏」看着比白天还亮，明显不对。
//   改成低亮度暖色 + 更高 alpha，让 day > dusk > night 单调变暗：
//     白天 84.3 → 黄昏 ~71 → 夜晚 ~52（实测值）
const PHASE_TINT = {
  day:   null,                                  // 白天不叠色
  dusk:  'rgba(80, 40, 12, .40)',               // 黄昏：暗暖橙
  night: 'rgba(14, 20, 58, .52)',               // 夜晚：深蓝
};
function phaseAt(t) {
  if (!DL || !DL.phases || !DL.phases.length) return null;
  let cur = DL.phases[0][1];
  for (let i = 0; i < DL.phases.length; i++) {
    if (DL.phases[i][0] <= t) cur = DL.phases[i][1]; else break;
  }
  return cur;
}
// ★ 温度：WORLD.daylight.samples = [[tick, 温度], ...]，逐采样点。
//   数值连续，直接按 tick 二分/线性找最近一帧即可。
function tempAt(tickNow) {
  if (!DL || !DL.samples || !DL.samples.length) return null;
  const a = DL.samples;
  let lo = 0, hi = a.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (a[mid][0] <= tickNow) lo = mid; else hi = mid - 1;
  }
  return a[lo][1];
}
function seasonAt(t) {
  if (!DL || !DL.seasons || !DL.seasons.length) return null;
  let cur = DL.seasons[0][1];
  for (let i = 0; i < DL.seasons.length; i++) {
    if (DL.seasons[i][0] <= t) cur = DL.seasons[i][1]; else break;
  }
  return cur;
}
function dayCountAt(t) {
  if (!DL || !DL.day_length) return 1;
  return Math.floor(t / DL.day_length) + 1;
}
const NFRAMES = META.ticks;                 // 总 tick 数
const SAMPLE = META.sample_every;           // 采样间隔
const W = M.w, H = M.h, TS = M.tile, OX = M.ox, OY = M.oy;
// 世界坐标范围：x ∈ [-(OX*TS), (W-OX)*TS]
const WX0 = -OX * TS, WX1 = (W - OX) * TS;
const WZ0 = -OY * TS, WZ1 = (H - OY) * TS;
const TERR_PX = 2;                          // 地形底图：1 世界单位 = 2 px
const PALETTE = {}; M.palette.forEach(p => PALETTE[p.id] = p);

// ---------- 实体索引 ----------
// 每个实体的 frames 是按 SAMPLE 间隔排列的数组，这里补一个 tick→下标 的直接映射
const ENTS = WORLD.entities.map((e, i) => {
  const byTick = {};
  for (const f of e.frames) byTick[f[0]] = f;
  return { idx:i, label:e.label, build:e.build, isPlayer:!!e.is_player,
           frames:e.frames, byTick, states:e.states };
});
const PLAYER = ENTS.find(e => e.isPlayer) || ENTS[0];

// ---------- 图像 ----------
const imgs = {};
function loadImages() {
  const jobs = [];
  for (const b in BUILDS) {
    jobs.push(Promise.all(BUILDS[b].atlasData.map(src => new Promise(res => {
      const im = new Image(); im.onload = () => res(im); im.src = src;
    }))).then(a => { imgs[b] = a; }));
  }
  return Promise.all(jobs);
}

// ---------- 地形底图 ----------
const terr = document.createElement('canvas');
terr.width = (WX1 - WX0) * TERR_PX; terr.height = (WZ1 - WZ0) * TERR_PX;
(function paintTerrain() {
  const g = terr.getContext('2d');
  g.fillStyle = '#0b0d11'; g.fillRect(0, 0, terr.width, terr.height);
  const oob = PALETTE[M.out_of_bounds] ? M.out_of_bounds : 1;
  for (let cy = 0; cy < H; cy++) {
    for (let cx = 0; cx < W; cx++) {
      const id = M.tiles[cy * W + cx];
      const p = PALETTE[id];
      g.fillStyle = p ? p.color : '#ff00ff';
      const X = (WX0 + cx * TS - WX0) * TERR_PX;
      const Y = ((WZ1 - (cy + 1) * TS) - WZ0) * TERR_PX;
      g.fillRect(X, Y, TS * TERR_PX, TS * TERR_PX);
    }
  }
  // 走廊描边：把「可通行 / 不可通行」的分界描出来，边界一眼可见
  g.strokeStyle = 'rgba(0,0,0,.25)';
  for (let cy = 0; cy < H; cy++) for (let cx = 0; cx < W; cx++) {
    const id = M.tiles[cy * W + cx];
    if (id === oob) continue;
    const nb = [[1,0],[-1,0],[0,1],[0,-1]];
    for (const [dx,dy] of nb) {
      const nx = cx+dx, ny = cy+dy;
      if (nx<0||ny<0||nx>=W||ny>=H) continue;
      if (M.tiles[ny*W+nx] === oob) {
        const X = (cx*TS) * TERR_PX, Y = (WZ1 - (cy+1)*TS - WZ0) * TERR_PX;
        g.beginPath();
        if (dx===1) { g.moveTo(X+TS*TERR_PX, Y); g.lineTo(X+TS*TERR_PX, Y+TS*TERR_PX); }
        else if (dx===-1) { g.moveTo(X, Y); g.lineTo(X, Y+TS*TERR_PX); }
        else if (dy===1) { g.moveTo(X, Y+TS*TERR_PX); g.lineTo(X+TS*TERR_PX, Y+TS*TERR_PX); }
        else { g.moveTo(X, Y); g.lineTo(X+TS*TERR_PX, Y); }
        g.stroke();
      }
    }
  }
})();

// ---------- 相机 ----------
const cv = document.getElementById('cv'), ctx = cv.getContext('2d');
let camX = 0, camZ = 0, zoom = 1.5, followPlayer = true;
//=========================================================================
// WebGL 渲染后端（renderer=gl 启用；默认仍是 canvas 2D）
//=========================================================================
// 为什么要它：canvas 2D 的每个 quad 都要 `setTransform` + `drawImage`，
//   是一堆状态切换。WebGL 把所有 quad 合批成**一次 drawArrays**，
//   按图集分组绑定纹理（29 个图集最多 29 次绑定/帧，远便宜于逐 quad 切换）。
//
// ★ 保留 canvas 2D 作为默认与降级路径 —— 不是为了「看起来支持两种」，
//   而是为了**能 A/B 对比**：两个后端渲染同一份轨迹，画面差异必须很小，
//   否则说明某一端算错了。没有对照就无法证明「更快」也没错。

let GL = null, GLBUF = null, GLPROG = null, GLUNI = null;
// ★★ 默认走 WebGL（2026-10-15 改）。
//
//   改的依据是 tools/compare_renderers.py 的实测，两条都要成立才敢换默认：
//     ① 正确性：scale=1 时两后端**逐字节完全一致**（558000/558000 = 100.0000%）
//     ② 性能：  WebGL 约快 **3.5 倍**（6.217 → 1.780 ms/frame，软件光栅下测）
//   在此之前默认是 2d —— 因为那时只有「GL 更快」的印象，没有对照。
//
//   仍保留 `?renderer=2d` 强制走 canvas：它既是降级路径，也是 A/B 的对照组
//   （compare_renderers.py 就靠它）。glInit() 失败会自动退回 2d。
const RENDERER = (new URLSearchParams(location.search)).get('renderer') || 'gl';
// ★★ 「顺序段」而不是「按图集分桶」。
//   踩过的坑：一开始按 img 分桶（Map），遍历顺序 = **插入顺序**，
//   而 canvas 2D 的正确顺序是「实体间按 z、实体内按 layer」——
//   分桶把这个全局顺序打乱了：该压在上面的精灵被下面的盖住。
//   实测症状：两个后端差 11.82%，且差异像素的 2D 侧有纹理、GL 侧是纯背景色
//   （= GL 把那块盖掉了）。而 flush 统计 buckets=15 skipped=0 verts=5742
//   —— **一个都没漏画**，只是顺序错了。
//   修法：顺序**连续**的同类图集合成一段（segment），段间严格保序。
//   段数会比桶数多一点，但每段仍是一次 drawArrays，远比逐 quad 切换便宜。
const GLSEGS = [];
let GL_CUR = null, GLQUADN = 0;

function glInit() {
  try {
    // ★★ 必须用**独立的画布** `cvgl`，不能复用 `cv`。
    //   踩过的坑：`cv` 早在脚本开头就 `getContext('2d')` 了，
    //   而**一个 canvas 只能有一种 context 类型** —— 再向它要 webgl
    //   只会拿到 null（无任何报错）。实测症状：
    //       [gl] getContext returned null (canvas=found)
    //   「canvas 找到了但拿不到 GL」，很容易误以为是环境不支持。
    //   （对照组：用 document.createElement('canvas') 的独立测试页面
    //     在同样 flag 下 webgl2=yes ⇒ 环境是好的，是这块画布被占用了。）
    const c = document.getElementById('cvgl');
    if (!c) { console.log('[gl] #cvgl missing'); return false; }
    // GL 层要**透明**（alpha:true），因为它叠在地形层之上
    // premultipliedAlpha:true —— 帧缓冲里存的是预乘色（上面那条管线），
    //   浏览器合成时必须按预乘解释，否则整体会偏亮/偏暗。
    const gl = c.getContext('webgl2', { alpha: true, antialias: false,
                                        premultipliedAlpha: false })
            || c.getContext('webgl',  { alpha: true, antialias: false,
                                        premultipliedAlpha: false });
    if (!gl) { console.log('[gl] getContext returned null on #cvgl'
        + ' (可能被别的 context 类型占用)'); return false; }
    const VS = `attribute vec2 aPos; attribute vec2 aUV; varying vec2 vUV;
      void main(){ vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }`;
    const FS = `precision mediump float; varying vec2 vUV; uniform sampler2D uTex;
      uniform vec4 uTint;
      void main(){ vec4 c = texture2D(uTex, vUV) * uTint; if (c.a < 0.004) discard; gl_FragColor = c; }`;
    const mk = (t, src) => { const sh = gl.createShader(t); gl.shaderSource(sh, src); gl.compileShader(sh); return sh; };
    const pr = gl.createProgram();
    gl.attachShader(pr, mk(gl.VERTEX_SHADER, VS));
    gl.attachShader(pr, mk(gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(pr);
    if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) {
      console.log('[gl] link failed: ' + gl.getProgramInfoLog(pr));
      return false;
    }
    GLPROG = pr; gl.useProgram(pr);
    GLBUF = gl.createBuffer();
    GLUNI = {
      uTex: gl.getUniformLocation(pr, 'uTex'),
      uTint: gl.getUniformLocation(pr, 'uTint'),
    };
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    // 每个图集建一张纹理（尺寸各异，所以不能用 texture array —— 那要求各层同尺寸）
    let n = 0;
    for (const [bname, list] of Object.entries(imgs)) {
      for (let i = 0; i < (list || []).length; i++) {
        const img = list[i];
        if (!img || !img.naturalWidth) continue;
        const tx = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tx);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        // ★ 双后端 A/B 的结论（实测，别再重复走这条弯路）：
        //   · **scale=1（1:1）时两后端逐字节完全一致**：558000/558000 像素，100.0000%。
        //     ⇒ GL 侧的符号解析、UV、分段顺序、纹理选择**全都是对的**。
        //   · scale=6（6 倍放大）时差异 10.95%。
        //   ⇒ 这 10.95% 是**放大插值方式不同**（canvas `drawImage` 的平滑插值
        //     vs GL `texture2D` 的双线性采样），属**预期行为，不是 bug**。
        //
        // 曾怀疑是 alpha 管线（这里原本 UNPACK_PREMULTIPLY_ALPHA_WEBGL=false
        // 配 blendFunc(SRC_ALPHA,...)），改成预乘管线（true + ONE/ONE_MINUS_SRC_ALPHA）
        // 后差异 10.85% → 10.95% —— **没有改善**，实测是量化噪声。
        // 而两条管线在 scale=1 下**都是 0.00%**，说明 alpha 管线在此**根本不影响结果**。
        // ⇒ 保留原设置，别再改。
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
        img._gltex = tx;
        n++;
      }
    }
    GL = gl;
    console.log('[gl] READY: ' + n + ' textures, backend=' +
      (gl instanceof WebGL2RenderingContext ? 'webgl2' : 'webgl1') +
      ' maxTex=' + gl.getParameter(gl.MAX_TEXTURE_SIZE));
    return true;
  } catch (e) {
    console.log('[gl] init threw: ' + e);
    return false;
  }
}

// 统一收口：canvas 2D 走老路；WebGL 收进桶里等合批
function emitQuad(img, X0, Y0, X1, Y1, X2, Y2, su0, sv0, suw, svh, iw, ih) {
  if (RENDERER !== 'gl' || GL === null) return false;   // 让调用方走 2D
  // 图集换了就开新段（保序的关键）
  if (GL_CUR === null || GL_CUR.img !== img) {
    GL_CUR = { img: img, arr: [] };
    GLSEGS.push(GL_CUR);
  }
  const arr = GL_CUR.arr;
  const u0 = su0 / iw, v0 = sv0 / ih, u1 = (su0 + suw) / iw, v1 = (sv0 + svh) / ih;
  // 两个三角形（屏幕坐标已由调用方算好；这里只需转成 NDC）
  const w = GL.canvas.width, h = GL.canvas.height;
  const px = (x) => x / w * 2 - 1, py = (y) => 1 - y / h * 2;
  // 四角：0=(X0,Y0) 1=(X1,Y1) 2=(X2,Y2) 3=(X1+X2-X0, Y1+Y2-Y0)
  const x3 = X1 + X2 - X0, y3 = Y1 + Y2 - Y0;
  const P = [px(X0),py(Y0), px(X1),py(Y1), px(X2),py(Y2), px(x3),py(y3)];
  const U = [u0,v0, u1,v0, u0,v1, u1,v1];
  const tri = [0,1,2, 0,2,3];
  for (const k of tri) {
    arr.push(P[k*2], P[k*2+1], U[k*2], U[k*2+1]);
  }
  GLQUADN++;
  return true;
}

// ★ GL 层也要画「全屏 overlay」—— 否则与 canvas 2D 不一致。
//   原因：2D 模式下叠色是在 sprite **之上**盖一层半透明色，
//         `dst' = dst*(1-a) + tint*a` —— 它会给暗部**加一点颜色**（提亮）。
//         而着色器乘法 `sprite*k` 只会整体压暗，不加色。
//         对 dusk 'rgba(80,40,12,.40)' 来说，2D 会给每个 sprite 像素加
//         (32,16,5) 的偏移 —— 足以让 11.8% 的像素越过差异阈值。
//         实测：只做乘法时两个后端差 11.82%，且 bbox 铺满全屏。
//   所以 GL 层最后补一个全屏半透明 quad，行为与 2D 完全一致。
function glFlush(tint, overlay) {
  if (GL === null) return 0;
  const gl = GL;
  gl.viewport(0, 0, gl.canvas.width, gl.canvas.height);
  gl.clearColor(0, 0, 0, 0);          // ★ 透明清屏：这层只画精灵
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.useProgram(GLPROG);
  gl.uniform4f(GLUNI.uTint, tint[0], tint[1], tint[2], tint[3]);
  gl.bindBuffer(gl.ARRAY_BUFFER, GLBUF);
  const aPos = gl.getAttribLocation(GLPROG, 'aPos');
  const aUV  = gl.getAttribLocation(GLPROG, 'aUV');
  gl.enableVertexAttribArray(aPos);
  gl.enableVertexAttribArray(aUV);
  const STRIDE = 16;
  gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, STRIDE, 0);
  gl.vertexAttribPointer(aUV,  2, gl.FLOAT, false, STRIDE, 8);
  let calls = 0, skipped = 0, verts = 0;
  for (const seg of GLSEGS) {
    const img = seg.img, arr = seg.arr;
    if (!img._gltex || arr.length === 0) { skipped++; continue; }
    verts += arr.length / 4;
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, img._gltex);
    gl.uniform1i(GLUNI.uTex, 0);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(arr), gl.DYNAMIC_DRAW);
    gl.drawArrays(gl.TRIANGLES, 0, arr.length / 4);
    calls++;
  }
  // 全屏 overlay（与 2D 的 fillRect 叠色等价）
  if (overlay) {
    const q = new Float32Array([
      -1,-1, 0,0,   1,-1, 1,0,   -1,1, 0,1,
      -1, 1, 0,1,   1,-1, 1,0,    1,1, 1,1,
    ]);
    gl.bufferData(gl.ARRAY_BUFFER, q, gl.DYNAMIC_DRAW);
    // 用一个 1x1 的纯色纹理： tint 色 * alpha
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, _glSolidTex(overlay));
    gl.uniform1i(GLUNI.uTex, 0);
    gl.uniform4f(GLUNI.uTint, 1, 1, 1, 1);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }
  GLQUADN = 0;
  GLSEGS.length = 0;      // 清空段表（下一帧重新收集）
  GL_CUR = null;
  if (window.__GLDBG) {
    console.log('[gl] flush: segs=' + (calls + skipped) + ' skipped=' + skipped +
      ' verts=' + verts + ' drawCalls=' + calls + ' overlay=' + (overlay ? 1 : 0));
  }
  return calls;
}

// 1x1 纯色纹理（按需缓存）：overlay 用
let _SOLID = null, _SOLID_RGBA = null;
function _glSolidTex(rgba) {
  if (_SOLID && _SOLID_RGBA && _SOLID_RGBA.join(',') === rgba.join(',')) return _SOLID;
  const gl = GL;
  if (!_SOLID) _SOLID = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, _SOLID);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
                new Uint8Array(rgba));
  _SOLID_RGBA = rgba.slice();
  return _SOLID;
}

// 把 rgba 叠色换算成乘法系数：k = (1-a) + (rgb/255)*a
//   day   → null（不叠）→ 返回 [1,1,1,1]
//   dusk  'rgba(80,40,12,.40)'  → R:0.6+0.4*80/255=0.725 ...
//   night 'rgba(14,20,58,.52)'  → R:0.48+0.52*14/255=0.508 ...
function tintMul(ph) {
  const t = ph && PHASE_TINT[ph];
  if (!t) return [1, 1, 1, 1];
  const m = /rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/.exec(t);
  if (!m) return [1, 1, 1, 1];
  const a = parseFloat(m[4]), k = (v) => (1 - a) + a * (parseInt(v, 10) / 255);
  return [k(m[1]), k(m[2]), k(m[3]), 1];
}
// rgba 叠色的四个分量（给 GL 的 1x1 纹理用）
function tintRGBA(ph) {
  const t = ph && PHASE_TINT[ph];
  if (!t) return null;
  const m = /rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/.exec(t);
  if (!m) return null;
  return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10),
          Math.round(parseFloat(m[4]) * 255)];
}
const GLSTAT = { drawCalls: 0, quads: 0 };
window.__GLDBG = false;  // true 打开 glFlush 统计日志（调试用）

function resize() {
  cv.width = cv.clientWidth * devicePixelRatio;
  cv.height = cv.clientHeight * devicePixelRatio;
  // GL 层必须与 2D 层**同尺寸同位置**，否则 sprite 会错位
  const g = document.getElementById('cvgl');
  if (g) { g.width = cv.width; g.height = cv.height; }
}
window.addEventListener('resize', resize);

// 世界 → 屏幕
function w2s(x, z) {
  return [ (x - camX) * zoom * TERR_PX + cv.width/2,
           ((camZ - z)) * zoom * TERR_PX + cv.height/2 ];
}
// 注意：屏幕 Y 向下，北（+z）朝上 ⇒ 用 (camZ - z)

// ---------- 取实体在 tick t 的采样帧 ----------
function frameAt(e, t) {
  // 优先精确命中；否则取 ≤ t 的最近一帧并与下一帧线性插值
  const exact = e.byTick[t];
  if (exact) return exact;
  let lo = 0, hi = e.frames.length - 1;
  while (lo < hi) { const mid = (lo+hi+1)>>1; if (e.frames[mid][0] <= t) lo = mid; else hi = mid-1; }
  const a = e.frames[lo], b = e.frames[Math.min(lo+1, e.frames.length-1)];
  if (b[0] === a[0]) return a;
  const k = (t - a[0]) / (b[0] - a[0]);
  return [ t,
           a[1] + (b[1]-a[1])*k,
           a[2] + (b[2]-a[2])*k,
           a[3], a[4], a[5], a[6] ];
}

const COMBAT_STATES = { attack:1, hit:1, hit_stunlock:1, death:1, corpse:1 };

// ---------- 画一个实体 ----------
function drawEnt(e, t) {
  const f = frameAt(e, t);
  if (!f) return;
  const x = f[1], z = f[2], rot = f[3], anim = f[4], fr = f[5], sg = f[6];
  const [sx, sy] = w2s(x, z);
  const spr = SPRITE_SCALE * sprMul;

  // 贴图（billboard + 左右镜像），没有图集的画成标记
  const B = e.build && BUILDS[e.build];
  // ★ 符号覆盖：帧第 8 项是 sigs 的下标（无覆盖时 undefined）。
  //   SIG[元素下标] = [覆盖后的符号名, 覆盖 build 的图集下标, 覆盖 build 名]。
  //   宿主的 GetDrawList 已经把覆盖解析完并回传，这里只负责按它选 build/图集。
  const SIG = (f[7] != null) ? (SIGS[f[7] - 1]) : null;
  // 逐元素解析成 {B, sym, img} 的小工具（无覆盖时走零开销快路径）
  const pick = SIG ? (function(i, el) {
    const ov = SIG[i];
    if (!ov) return [B, B && B.symbols[el.sym], B ? (imgs[e.build]||[])[el.atlas||0] : null];
    const ob = BUILDS[ov[2]];
    return [ob, ob && ob.symbols[ov[0]], (imgs[ov[2]]||[])[ov[1] || 0]];
  }) : function(i, el) {
    return [B, B && B.symbols[el.sym], B ? (imgs[e.build]||[])[el.atlas||0] : null];
  };
  if (B && anim && B.anims[anim]) {
    const a = B.anims[anim];
    const frs = a.frames;
    const els = frs[Math.min(fr, frs.length) - 1] || frs[0] || [];
    // 包围盒（动画空间）→ 用于把「脚底」对到实体位置
    // ★ 锚点只按**实体自己的 build** 算，不把覆盖层算进去。
    //   为什么：包围盒决定「脚底对到实体位置、水平居中」，它是**角色体型的属性**，
    //   不该随穿戴变化。实测把帽子算进去会让 cxAnim 漂移 →
    //   整个角色平移几个像素（对照实验里表现为差异散成 22 块而不是聚在头部）。
    let minx=1e9,maxx=-1e9,miny=1e9,maxy=-1e9;
    for (let ei = 0; ei < els.length; ei++) {
      const el = els[ei];
      const sym = (B && B.symbols[el.sym]); if (!sym) continue;
      const sf = sym.frames[el.frame] ?? sym.frames[String(el.frame)]; if (!sf) continue;
      const m = el.mat;
      for (const v of sf.verts) {
        const px = m[0]*v[0] + m[1]*v[1] + m[4];
        const py = m[2]*v[0] + m[3]*v[1] + m[5];
        if (px<minx)minx=px; if (px>maxx)maxx=px;
        if (py<miny)miny=py; if (py>maxy)maxy=py;
      }
    }
    if (maxx > minx) {
      const flip = Math.cos(rot * Math.PI/180) < 0 ? -1 : 1;
      // 脚底 = 动画包围盒的 bottom；把 bbox 中心 X 对到实体位置
      const cxAnim = (minx+maxx)/2, botAnim = maxy;
      const s = spr * flip;
      // 动画空间 → 世界：anim_x*sc + dx ; anim_y*sc + dz（y 向下，与屏幕一致）
      const dx = x - cxAnim*spr, dz = z - botAnim*spr;
      ctx.save();
      items.length = 0;
      for (let ei = 0; ei < els.length; ei++) {
        const el = els[ei];
        const pk = pick(ei, el);
        const sym = pk[1]; if (!sym) continue;
        const sf = sym.frames[el.frame] ?? sym.frames[String(el.frame)]; if (!sf) continue;
        items.push([el.mat[6], sym, sf, el.mat, pk[2]]);
      }
      items.sort((p,q)=>p[0]-q[0]);
      for (const [, sym, sf, m, img] of items) {
        if (!img) continue;
        const vs = sf.verts;
        const p0 = vs[0], p1 = vs[1], p2 = vs[2];
        const iw = img.naturalWidth, ih = img.naturalHeight;
        const au0 = m[0]*p0[0]+m[1]*p0[1]+m[4], av0 = m[2]*p0[0]+m[3]*p0[1]+m[5];
        const au1 = m[0]*p1[0]+m[1]*p1[1]+m[4], av1 = m[2]*p1[0]+m[3]*p1[1]+m[5];
        const au2 = m[0]*p2[0]+m[1]*p2[1]+m[4], av2 = m[2]*p2[0]+m[3]*p2[1]+m[5];
        // 动画空间 → 屏幕（含缩放与相机）
        const X0=(au0*spr+dx-camX)*zoom*TERR_PX + cv.width/2;
        const Y0=((camZ-(av0*spr+dz)))*zoom*TERR_PX + cv.height/2;
        const X1=(au1*spr+dx-camX)*zoom*TERR_PX + cv.width/2;
        const Y1=((camZ-(av1*spr+dz)))*zoom*TERR_PX + cv.height/2;
        const X2=(au2*spr+dx-camX)*zoom*TERR_PX + cv.width/2;
        const Y2=((camZ-(av2*spr+dz)))*zoom*TERR_PX + cv.height/2;
        const su0=p0[2]*iw, sv0=p0[3]*ih;
        const suw=(p1[2]-p0[2])*iw, svh=(p2[3]-p0[3])*ih;
        if (Math.abs(suw)<.01||Math.abs(svh)<.01) continue;
        // 走统一收口：GL 模式收进桶里合批；否则回落到 canvas 2D 老路
        if (!emitQuad(img, X0, Y0, X1, Y1, X2, Y2, su0, sv0, suw, svh, iw, ih)) {
          const A=(X1-X0)/suw, Bm=(Y1-Y0)/suw, C=(X2-X0)/svh, D=(Y2-Y0)/svh;
          const E=X0-A*su0-C*sv0, F=Y0-Bm*su0-D*sv0;
          ctx.setTransform(A,Bm,C,D,E,F);
          ctx.imageSmoothingEnabled = true;
          ctx.drawImage(img, su0, sv0, suw, svh, 0, 0, suw, svh);
        }
      }
      ctx.restore();
    }
  } else {
    // 无图集（如 wilson）：画一个带名字的标记
    const R = 0.6 * zoom * TERR_PX;
    ctx.setTransform(1,0,0,1,0,0);
    ctx.beginPath(); ctx.arc(sx, sy, R, 0, 7);
    ctx.fillStyle = e.isPlayer ? '#6cb6ff' : '#c9a26b';
    ctx.fill();
    ctx.lineWidth = 2; ctx.strokeStyle = '#ffffff88'; ctx.stroke();
  }

  // 朝向线（真实 rotation，别弄丢这条信息）
  if (showFacing) {
    const L = 1.2 * zoom * TERR_PX;
    ctx.setTransform(1,0,0,1,0,0);
    ctx.beginPath();
    ctx.moveTo(sx, sy);
    ctx.lineTo(sx + Math.cos(rot*Math.PI/180)*L, sy - Math.sin(rot*Math.PI/180)*L);
    ctx.strokeStyle = 'rgba(255,210,120,.85)'; ctx.lineWidth = 1.5; ctx.stroke();
  }

  // 战斗高亮圈
  if (sg && COMBAT_STATES[sg]) {
    ctx.setTransform(1,0,0,1,0,0);
    ctx.beginPath(); ctx.arc(sx, sy, 22*zoom*TERR_PX/1.5, 0, 7);
    ctx.strokeStyle = 'rgba(255,90,90,.8)'; ctx.lineWidth = 2; ctx.stroke();
  }

  // 名字 / 状态
  if (showLabels) {
    ctx.setTransform(1,0,0,1,0,0);
    ctx.font = (11*devicePixelRatio|0) + 'px "Segoe UI",sans-serif';
    ctx.textAlign = 'center';
    const ty = sy - 26*zoom*TERR_PX/1.5;
    ctx.fillStyle = 'rgba(0,0,0,.55)';
    const txt = e.label + (sg ? '  · ' + sg : '');
    const wtxt = ctx.measureText(txt).width;
    ctx.fillRect(sx - wtxt/2 - 4, ty - 12, wtxt + 8, 16);
    ctx.fillStyle = e.isPlayer ? '#9fd0ff' : '#e6e6e6';
    ctx.fillText(txt, sx, ty);
  }
}
const items = [];
let sprMul = 1, showLabels = true, showFacing = false, showGrid = false;

// ★ URL 参数：?scale=2.5&zoom=300&tick=1200&labels=0&play=0
//   便于（a）无头浏览器自动截图到指定时刻的指定倍率
//       （b）把某个特定视角做成可分享的链接
//   缺省行为与原来完全一致。
(function applyQueryParams() {
  const q = new URLSearchParams(location.search);
  const num = (k, d) => (q.has(k) ? parseFloat(q.get(k)) : d);
  const bool = (k, d) => (q.has(k) ? (q.get(k) !== '0' && q.get(k) !== 'false') : d);
  const vScale = num('scale', null), vZoom = num('zoom', null);
  const vTick = num('tick', null), vLabels = bool('labels', null);
  const vPlay = bool('play', null), vFacing = bool('facing', null);
  // ui=0：隐藏所有面板与工具条，只留画布 —— 自动截图/对照时用
  const vUI = bool('ui', null);
  if (vScale !== null) { sprMul = vScale; }
  if (vLabels !== null) { showLabels = vLabels; }
  if (vFacing !== null) { showFacing = vFacing; }
  // ★ bench 也必须进 __qp —— 第一版只在外面用 URLSearchParams 读，
  //   而初始化块（IIFE）早就把参数收进 window.__qp 了，
  //   后面的 `qp.bench` 读到 undefined ⇒ bench 静默不跑（无任何报错）。
  const vBench = (function () {
    const v = new URLSearchParams(location.search).get('bench');
    return v === null ? null : (parseInt(v, 10) || 0);
  })();
  window.__qp = { scale: vScale, zoom: vZoom, tick: vTick, labels: vLabels,
                  play: vPlay, ui: vUI, bench: vBench };
})();

// ---------- 主循环 ----------
let tick = 0, playing = true, speed = 1, last = performance.now(), acc = 0;

function draw() {
  ctx.setTransform(1,0,0,1,0,0);
  ctx.fillStyle = '#080a0e'; ctx.fillRect(0,0,cv.width,cv.height);

  if (followPlayer) {
    const f = frameAt(PLAYER, tick);
    if (f) { camX = f[1]; camZ = f[2]; }
  }

  // 地形
  const [tx, ty] = w2s(WX0, WZ1);
  const tw = (WX1-WX0) * zoom * TERR_PX, th = (WZ1-WZ0) * zoom * TERR_PX;
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(terr, tx, ty, tw, th);

  // 格线
  if (showGrid) {
    ctx.strokeStyle = 'rgba(255,255,255,.06)'; ctx.lineWidth = 1;
    ctx.beginPath();
    for (let cx = 0; cx <= W; cx++) {
      const [ax, ay] = w2s(WX0 + cx*TS, WZ0), [bx, by] = w2s(WX0 + cx*TS, WZ1);
      ctx.moveTo(ax, ay); ctx.lineTo(bx, by);
    }
    for (let cy = 0; cy <= H; cy++) {
      const [ax, ay] = w2s(WX0, WZ0 + cy*TS), [bx, by] = w2s(WX1, WZ0 + cy*TS);
      ctx.moveTo(ax, ay); ctx.lineTo(bx, by);
    }
    ctx.stroke();
  }

  // 实体：按 z 从远到近画（北边的先画，南边的压在上面）
  const order = ENTS.map(e => ({e, f: frameAt(e, tick)})).filter(o => o.f);
  order.sort((p,q) => q.f[2] - p.f[2]);
  for (const o of order) drawEnt(o.e, tick);

  // ★ 昼夜叠色：画在实体之上、HUD 之下。
  //   白天不叠；黄昏暖橙；夜晚深蓝 —— 只影响画布，面板不受影响（面板是 DOM）。
  // ★ GL 模式下 sprite 在**另一块画布**上，canvas 叠色盖不到它们，
  //   所以走着色器乘法：k = (1-a) + tint_rgb/255 * a
  //   （这正是「alpha 混合下暖色会提亮画面，黄昏要用低亮度暖色」那条经验的来源）
  {
    const ph = phaseAt(tick / 30);
    const tint = ph && PHASE_TINT[ph];
    if (tint) { ctx.setTransform(1,0,0,1,0,0); ctx.fillStyle = tint;
                ctx.fillRect(0, 0, cv.width, cv.height); }
    if (GL !== null) {
      // GL 模式下：2D 层的 fillRect 仍然负责压暗**地形**；
      // GL 层用全屏 overlay quad 压暗**精灵**。两者叠加后与纯 2D 等价。
      GLSTAT.drawCalls = glFlush([1, 1, 1, 1], tintRGBA(ph));
    } else {
      GLSTAT.drawCalls = 0;
    }
  }

  const _ph = phaseAt(tick / 30);
  const _phCn = _ph === 'day' ? '白天' : _ph === 'dusk' ? '黄昏'
              : _ph === 'night' ? '夜晚' : (_ph || '—');
  const _T = tempAt(tick);
  const _sea = seasonAt(tick / 30);
  const SEA_CN = { autumn: '秋', winter: '冬', spring: '春', summer: '夏' };
  document.getElementById('tnum').textContent =
    't=' + tick + '  (' + (tick/30).toFixed(1) + 's)'
    + (DL ? ('   第 ' + dayCountAt(tick/30) + ' 天 · ' + _phCn) : '')
    + (_T !== null ? ('   ' + _T.toFixed(1) + '°C') : '')
    + (_sea ? ('   ' + (SEA_CN[_sea] || _sea) + '季') : '');
  document.getElementById('tickbar').value = tick;
  updateInfo();
}

function updateInfo() {
  const rows = [];
  for (const e of ENTS) {
    const f = frameAt(e, tick);
    if (!f) continue;
    const d = Math.hypot(f[1]-0, f[2]-0);
    const pd = PLAYER && e !== PLAYER ? Math.hypot(f[1]-frameAt(PLAYER,tick)[1],
                                                   f[2]-frameAt(PLAYER,tick)[2]) : null;
    rows.push('<div class="ent"><div class="kv"><span><b>' + e.label + '</b>'
      + (e.isPlayer ? ' <span class="muted">玩家</span>' : '')
      + '</span><span>' + (e.build||'') + '</span></div>'
      + '<div class="kv"><span>状态</span><span class="'
      + (COMBAT_STATES[f[6]]?'combat':'') + '">' + (f[6]||'-') + '</span></div>'
      + '<div class="kv"><span>动画</span><span>' + (f[4]||'-') + ' #' + f[5] + '</span></div>'
      + '<div class="kv"><span>朝向</span><span>' + f[3].toFixed(0) + '°</span></div>'
      + (pd !== null ? '<div class="kv"><span>离玩家</span><span>' + pd.toFixed(1) + '</span></div>' : '')
      + '</div>');
  }
  document.getElementById('info').innerHTML = rows.join('');
}

function loop(now) {
  const dt = (now - last)/1000; last = now;
  // ★ 推进与渲染分开：**暂停时也要继续渲染**。
  //   原先 draw() 被包在 if (playing) 里，于是「暂停 + 图片尚未加载完」时
  //   画面会一直停在空白（headless 自动截图、慢网络首屏都能撞到）。
  if (playing) {
    acc += dt * speed;
    const spf = 1/30;
    while (acc >= spf) { acc -= spf; tick++; if (tick >= NFRAMES) { tick = 0; break; } }
  }
  draw();
  requestAnimationFrame(loop);
}

// ---------- UI ----------
document.getElementById('play').onclick = e => {
  playing = !playing; e.target.textContent = playing ? '⏸ 暂停' : '▶ 播放';
};
document.getElementById('tickbar').max = NFRAMES;
document.getElementById('tickbar').oninput = e => { tick = +e.target.value; draw(); };
document.getElementById('speed').onchange = e => speed = +e.target.value;
document.getElementById('follow').onchange = e => followPlayer = e.target.checked;
document.getElementById('labels').onchange = e => { showLabels = e.target.checked; draw(); };
document.getElementById('facing').onchange = e => { showFacing = e.target.checked; draw(); };
document.getElementById('grid').onchange = e => { showGrid = e.target.checked; draw(); };
document.getElementById('sscale').onchange = e => { sprMul = +e.target.value; draw(); };
document.getElementById('zoom').oninput = e => { zoom = +e.target.value/100; draw(); };
window.addEventListener('keydown', ev => {
  if (ev.code === 'Space') { ev.preventDefault(); document.getElementById('play').click(); }
});

// ---------- 图例 ----------
(function legend() {
  const el = document.getElementById('legend');
  el.innerHTML = '<div class="muted" style="margin-bottom:5px">地形（真实 GROUND 编号）</div>'
    + M.palette.map(p => '<div class="row"><span class="sw" style="background:'
      + p.color + '"></span>' + p.name + ' <span class="muted">#' + p.id + '</span></div>').join('')
    + '<div class="muted" style="margin-top:7px">线段 = 真实朝向<br>红圈 = 战斗状态</div>';
})();

document.getElementById('src').innerHTML =
  '数据来自 <b>_out/world.json</b>（world.lua 在契约复刻宿主里真跑 '
  + META.ticks + ' tick / ' + (META.ticks/30).toFixed(0) + ' 秒世界时间，'
  + META.entities + ' 个实体 · 种子 ' + META.seed + '）';

loadImages().then(() => {
  resize();
  // ★ GL 后端在这里初始化（要等图片解码完才能 texImage2D）
  if (RENDERER === 'gl') {
    if (glInit()) {
      document.getElementById('cvgl').style.display = 'block';
    } else {
      // 初始化失败就静默回落到 2D —— 但要在控制台说清楚，
      // 否则会以为在用 GL 实际在用 2D
      console.log('[gl] fallback to canvas 2D');
    }
  }
  zoom = +document.getElementById('zoom').value/100;
  // ★ 应用 URL 参数到控件与运行状态（必须在 resize 之后，否则画布尺寸不对）
  const qp = window.__qp || {};
  if (qp.zoom !== null && qp.zoom !== undefined) {
    const z = document.getElementById('zoom');
    z.value = String(Math.round(qp.zoom));
    zoom = qp.zoom / 100;
    resize();
  }
  if (qp.scale !== null && qp.scale !== undefined) {
    const sc = document.getElementById('sscale');
    if (sc) sc.value = String(qp.scale);
    sprMul = qp.scale;
  }
  // NOTE 画布用的是**变量**（showLabels / showFacing），不是 checkbox 本身 ——
  //   只改 checkbox 不会生效，必须同时改变量（onchange 处理器就是干这个的）。
  if (qp.labels === false) {
    showLabels = false;
    const lb = document.getElementById('labels'); if (lb) lb.checked = false;
  }
  if (qp.facing) {
    showFacing = true;
    const fc = document.getElementById('facing'); if (fc) fc.checked = true;
  }
  if (qp.tick !== null && qp.tick !== undefined) tick = Math.max(0, Math.min(NFRAMES, qp.tick | 0));
  if (qp.play === false) playing = false;
  if (qp.ui === false) {
    for (const id of ['legend', 'info', 'ctl']) {
      const el = document.getElementById(id); if (el) el.style.display = 'none';
    }
  }
  draw();
  // ★ 布局可能还没就绪（headless 浏览器首帧 cv.clientWidth 常常是 0，
  //   慢布局的真实浏览器也会），此时画布尺寸为 0，画出来是空的。
  //   所以在下一帧再 resize + 重画一次 —— 播放器在 play=0（暂停）时尤其需要它。
  requestAnimationFrame(() => { resize(); draw(); });

  // ★★ bench 入口（?bench=N）：连续跑 N 次 draw()，把平均耗时打到 console。
  //   为什么要有：双后端的意义是「GL 更快」，但**光有更快的结果没用**，
  //   必须先证明两边画的是同一幅图（tools/compare_renderers.py 负责那个），
  //   才有资格比速度。本入口补上速度那一半。
  //   用法：?bench=200&renderer=gl 与 ?bench=200&renderer=2d 对读 console。
  //   ⚠️ headless 下 GPU 可能走软件光栅（SwiftShader），绝对值没有参考意义，
  //      **只有两个后端在同一次运行里的比值有意义**。
  const qbench = parseInt(qp.bench || '0', 10);
  if (qbench > 0) {
    const N = qbench;
    let tsum = 0;
    for (let i = 0; i < N; i++) {
      const t0 = performance.now();
      draw();
      // 强制同步：GL 侧要把命令刷出去，否则测到的只是「入队」时间
      if (GL) { try { GL.finish(); } catch (e) { /* finish 不可用则忽略 */ } }
      tsum += performance.now() - t0;
    }
    console.log('[bench] renderer=' + RENDERER + ' N=' + N
                + ' avg=' + (tsum / N).toFixed(3) + ' ms  total='
                + tsum.toFixed(1) + ' ms');
  }
  requestAnimationFrame(loop); });
</script></body></html>
"""


def main():
    world = json.load(open(OUT_JSON, encoding='utf-8'))
    print('读入 %s（%d 实体）' % (OUT_JSON, len(world['entities'])))

    print('裁剪动画数据…')
    builds = collect_builds(world)
    print('嵌入图集…')
    embed_atlases(builds)

    html = (HTML
            .replace('__WORLD__', json.dumps(world, separators=(',', ':')))
            .replace('__BUILDS__', json.dumps(builds, separators=(',', ':')))
            .replace('__SPRITE_SCALE__', repr(DEFAULT_SPRITE_SCALE))
            .replace('__TILE_SCALE__', repr(TILE_SCALE)))
    with open(OUT_HTML, 'w', encoding='utf-8') as f:
        f.write(html)
    print('  → %s  (%.1f MB)' % (OUT_HTML, os.path.getsize(OUT_HTML) / 1048576))
    return 0


if __name__ == '__main__':
    sys.exit(main())
