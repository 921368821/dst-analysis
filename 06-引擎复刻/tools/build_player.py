#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_player.py —— 生成自包含的 HTML 动画播放器

为什么要做这个
    逻辑层与数据层都已打通（宿主能给出 GetDrawList、解码器能给出图集与顶点），
    但「看到生物动起来」这一步之前只能用 Python 逐像素光栅化出静态帧。
    LÖVE2D 本机没装，所以改用一个更直接的办法：把数据塞进 HTML，
    用浏览器的 canvas 实时播。

渲染做法（关键）
    每个符号帧是 6 个顶点（两个三角形，非索引），它们来自**一个矩形**做仿射变换，
    所以目标形状必然是平行四边形。于是不需要逐三角形光栅化 —— 直接用
    canvas 的 setTransform 把「图集里的 UV 矩形」映射到目标平行四边形：

        a = (x1-x0)/sw   b = (y1-y0)/sw
        c = (x2-x0)/sh   d = (y2-y0)/sh
        e = x0 - a*sx - c*sy
        f = y0 - b*sx - d*sy
        ctx.setTransform(a,b,c,d,e,f)
        ctx.drawImage(img, sx,sy,sw,sh, 0,0,sw,sh)

    这比逐像素快几个数量级，且是精确的（不是近似）。

坐标方向
    DST 的 anim 数据里 **y 向下为正**（第四阶段用 ty 语义排序验证过），
    与 canvas 一致，所以**不需要翻转 y**。UV 的 v 也直接对应图集 PNG 的上下。
"""
import base64
import json
import os
import sys
import struct
import zlib

sys.path.insert(0, os.path.dirname(__file__))


# ---------------------------------------------------------------------------
# PNG 下采样（自带，不依赖 Pillow）
#   2048×2048 的图集 base64 后太大，2×2 盒式滤波降一半就够（渲染本身会缩放）
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
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bytes(out)


def downscale(w, h, px, f=2):
    """2×2 盒式滤波降采样，保留 alpha 加权颜色。"""
    nw, nh = w // f, h // f
    out = bytearray(nw * nh * 4)
    for y in range(nh):
        for x in range(nw):
            r = g = b = a = 0
            for dy in range(f):
                for dx in range(f):
                    i = ((y * f + dy) * w + (x * f + dx)) * 4
                    r += px[i]; g += px[i + 1]; b += px[i + 2]; a += px[i + 3]
            n = f * f
            o = (y * nw + x) * 4
            out[o] = r // n
            out[o + 1] = g // n
            out[o + 2] = b // n
            out[o + 3] = a // n
    return nw, nh, bytes(out)


def png_b64(w, h, rgba):
    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload +
                struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    return base64.b64encode(png).decode('ascii')


# ---------------------------------------------------------------------------
# HTML 模板
# ---------------------------------------------------------------------------
HTML = r"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>DST 动画播放器 · 契约复刻宿主输出</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; background:#14161a; color:#e6e6e6;
         font:14px/1.5 "Segoe UI",-apple-system,sans-serif; }
  header { padding:14px 18px; border-bottom:1px solid #2a2e36;
           display:flex; align-items:baseline; gap:14px; flex-wrap:wrap; }
  h1 { font-size:16px; margin:0; font-weight:600; }
  .muted { color:#8b93a1; font-size:12px; }
  .wrap { display:flex; height:calc(100vh - 56px); }
  aside { width:270px; border-right:1px solid #2a2e36; overflow:auto; padding:12px; }
  main { flex:1; display:flex; flex-direction:column; }
  .tabs { display:flex; gap:6px; padding:10px 14px; border-bottom:1px solid #2a2e36; flex-wrap:wrap;}
  .tab { padding:5px 12px; border:1px solid #333944; border-radius:6px;
         background:#1b1e24; cursor:pointer; font-size:13px; }
  .tab.on { background:#2b6cb0; border-color:#2b6cb0; color:#fff; }
  .stage { flex:1; display:grid; place-items:center; overflow:hidden;
           background:
             linear-gradient(45deg,#191c21 25%,transparent 25%) 0 0/16px 16px,
             linear-gradient(-45deg,#191c21 25%,transparent 25%) 0 8px/16px 16px,
             linear-gradient(45deg,transparent 75%,#191c21 75%) 8px -8px/16px 16px,
             linear-gradient(-45deg,transparent 75%,#191c21 75%) -8px 0/16px 16px,
             #1e2127; }
  canvas { image-rendering:pixelated; max-width:100%; max-height:100%; }
  .ctl { padding:10px 14px; border-top:1px solid #2a2e36;
         display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
  select,input,button { background:#1b1e24; color:#e6e6e6;
         border:1px solid #333944; border-radius:6px; padding:5px 9px; font-size:13px; }
  button { cursor:pointer; }
  button:hover { background:#242833; }
  label { display:flex; gap:6px; align-items:center; font-size:13px; }
  .animlist { display:flex; flex-direction:column; gap:3px; }
  .animlist button { text-align:left; font-size:12.5px; padding:4px 9px; }
  .animlist button.on { background:#2b6cb0; border-color:#2b6cb0; color:#fff; }
  .kv { display:flex; justify-content:space-between; font-size:12px;
        color:#8b93a1; padding:2px 0; }
  .kv b { color:#c9d1d9; font-weight:500; }
</style></head><body>
<header>
  <h1>DST 动画播放器</h1>
  <span class="muted">数据来自 <b id="src"></b> —— 由契约复刻宿主解析 DST 原始 <code>anim.zip</code> 得到</span>
</header>
<div class="wrap">
  <aside>
    <div class="muted" style="margin-bottom:6px">动画（<span id="nAnim"></span> 个）</div>
    <div class="animlist" id="animlist"></div>
  </aside>
  <main>
    <div class="tabs" id="tabs"></div>
    <div class="stage"><canvas id="cv" width="420" height="420"></canvas></div>
    <div class="ctl">
      <button id="play">⏸ 暂停</button>
      <label>帧 <input type="range" id="slider" min="0" max="0" value="0" style="width:200px">
        <span id="fnum" class="muted"></span></label>
      <label>速度 <select id="speed">
        <option value="1">1×</option><option value="0.5">0.5×</option>
        <option value="0.25">0.25×</option><option value="2">2×</option>
      </select></label>
      <label><input type="checkbox" id="showbox"> 显示包围盒</label>
      <span id="info" class="muted"></span>
    </div>
  </main>
</div>
<script>
const BUNDLES = __BUNDLES__;
let cur = 0, animName = null, frame = 0, playing = true, speed = 1, showbox = false;
let last = performance.now(), acc = 0;
const cv = document.getElementById('cv'), ctx = cv.getContext('2d');
const imgs = {};   // bundleIdx -> [Image]

function loadImages() {
  return Promise.all(BUNDLES.map((b, bi) => Promise.all(
    b.atlasData.map(src => new Promise(res => {
      const im = new Image();
      im.onload = () => res(im);
      im.src = src;
    })).then(arr => { imgs[bi] = arr; })));
}

function setBundle(i) {
  cur = i; const b = BUNDLES[i];
  document.getElementById('src').textContent = b.name;
  document.getElementById('tabs').querySelectorAll('.tab')
    .forEach((t, k) => t.classList.toggle('on', k === i));
  const list = document.getElementById('animlist');
  list.innerHTML = '';
  b.animNames.forEach(n => {
    const btn = document.createElement('button');
    btn.textContent = n + '  (' + b.anims[n].frames.length + ' 帧)';
    btn.onclick = () => { animName = n; frame = 0; acc = 0; syncAnim(); };
    btn.dataset.n = n;
    list.appendChild(btn);
  });
  document.getElementById('nAnim').textContent = b.animNames.length;
  // 默认挑一个含 idle 的动画
  animName = b.animNames.find(n => n === 'idle_loop')
          || b.animNames.find(n => n === 'idle')
          || b.animNames.find(n => n.indexOf('idle') >= 0)
          || b.animNames[0];
  frame = 0; acc = 0;
  syncAnim();
}

function syncAnim() {
  const b = BUNDLES[cur], a = b.anims[animName];
  document.getElementById('animlist').querySelectorAll('button')
    .forEach(x => x.classList.toggle('on', x.dataset.n === animName));
  const sl = document.getElementById('slider');
  sl.max = a.frames.length - 1; sl.value = frame;
  document.getElementById('fnum').textContent = (frame + 1) + '/' + a.frames.length;
  document.getElementById('info').textContent =
    animName + '  ·  ' + a.rate + ' fps  ·  ' + a.frames.length + ' 帧';
  draw();
}

function draw() {
  const b = BUNDLES[cur], a = b.anims[animName];
  if (!a) return;
  const fr = a.frames[frame] || [];
  const cw = cv.width, ch = cv.height;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, cw, ch);

  // 算包围盒：把每个元素变换到屏幕空间，取其四角
  let minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9;
  const items = [];
  for (const el of fr) {
    const sym = b.symbols[el.sym];
    if (!sym) continue;
    const sfr = sym.frames[el.frame] ?? sym.frames[String(el.frame)];
    if (!sfr) continue;
    const m = el.mat, vs = sfr.verts;
    const pts = vs.map(v => [m[0]*v[0] + m[1]*v[1] + m[4],
                             m[2]*v[0] + m[3]*v[1] + m[5],
                             v[2], v[3]]);
    let x0=1e9,x1=-1e9,y0=1e9,y1=-1e9;
    for (const p of pts){ if(p[0]<x0)x0=p[0]; if(p[0]>x1)x1=p[0];
                          if(p[1]<y0)y0=p[1]; if(p[1]>y1)y1=p[1]; }
    if (x0<minx)minx=x0; if(x1>maxx)maxx=x1;
    if (y0<miny)miny=y0; if(y1>maxy)maxy=y1;
    items.push([el.mat[6], sym, pts, x0,y0,x1,y1]);   // tz 排序键
  }
  if (!items.length) return;

  const pad = 8;
  const w = maxx - minx + pad*2, h = maxy - miny + pad*2;
  const sc = Math.min(cw / w, ch / h);
  const ox = (cw - w*sc) / 2 + (pad - minx)*sc;
  const oy = (ch - h*sc) / 2 + (pad - miny)*sc;

  items.sort((p, q) => p[0] - q[0]);       // tz 从远到近
  for (const [, sym, pts] of items) {
    const img = imgs[cur][sym.atlas || 0];
    if (!img) continue;
    // 四边形四角：pts[0](uv 原点) / pts[1](+u) / pts[2](+v)
    const p0 = pts[0], p1 = pts[1], p2 = pts[2];
    const iw = img.naturalWidth, ih = img.naturalHeight;
    const sx = p0[2]*iw, sy = p0[3]*ih;
    const sw = (p1[2]-p0[2])*iw, sh = (p2[3]-p0[3])*ih;
    if (Math.abs(sw) < 0.01 || Math.abs(sh) < 0.01) continue;
    const X0 = p0[0]*sc+ox, Y0 = p0[1]*sc+oy;
    const X1 = p1[0]*sc+ox, Y1 = p1[1]*sc+oy;
    const X2 = p2[0]*sc+ox, Y2 = p2[1]*sc+oy;
    const A = (X1-X0)/sw, B = (Y1-Y0)/sw;
    const C = (X2-X0)/sh, D = (Y2-Y0)/sh;
    const E = X0 - A*sx - C*sy, F = Y0 - B*sx - D*sy;
    ctx.save();
    ctx.setTransform(A, B, C, D, E, F);
    ctx.imageSmoothingEnabled = true;
    ctx.drawImage(img, sx, sy, sw, sh, 0, 0, sw, sh);
    ctx.restore();
  }

  if (showbox) {
    ctx.setTransform(1,0,0,1,0,0);
    ctx.strokeStyle = 'rgba(255,120,120,.5)';
    ctx.strokeRect(ox + minx*sc, oy + miny*sc, (maxx-minx)*sc, (maxy-miny)*sc);
    ctx.fillStyle = 'rgba(255,120,120,.9)';
    ctx.font = '12px monospace';
    ctx.fillText(`${Math.round(maxx-minx)}×${Math.round(maxy-miny)}`, 6, 16);
  }
  ctx.setTransform(1,0,0,1,0,0);
}

function tick(now) {
  const dt = (now - last) / 1000; last = now;
  if (playing && animName) {
    const a = BUNDLES[cur].anims[animName];
    acc += dt * speed;
    const spf = 1 / (a.rate || 30);
    while (acc >= spf) {
      acc -= spf;
      frame = (frame + 1) % a.frames.length;
    }
    const sl = document.getElementById('slider');
    sl.value = frame;
    document.getElementById('fnum').textContent = (frame+1) + '/' + a.frames.length;
    draw();
  }
  requestAnimationFrame(tick);
}

document.getElementById('play').onclick = e => {
  playing = !playing; e.target.textContent = playing ? '⏸ 暂停' : '▶ 播放';
};
document.getElementById('slider').oninput = e => { frame = +e.target.value; draw();
  document.getElementById('fnum').textContent = (frame+1)+'/'+BUNDLES[cur].anims[animName].frames.length; };
document.getElementById('speed').onchange = e => speed = +e.target.value;
document.getElementById('showbox').onchange = e => { showbox = e.target.checked; draw(); };

loadImages().then(() => {
  const tabs = document.getElementById('tabs');
  BUNDLES.forEach((b, i) => {
    const t = document.createElement('button');
    t.className = 'tab'; t.textContent = b.name.replace('_build','');
    t.onclick = () => setBundle(i);
    tabs.appendChild(t);
  });
  setBundle(0);
  requestAnimationFrame(tick);
});
</script></body></html>
"""


def build(zips_by_name, atlas_dir, json_dir, out_html):
    """zips_by_name: [(显示名, [zip路径...]), ...]"""
    bundles = []
    for name, zips in zips_by_name:
        jp = os.path.join(json_dir, f'{name}.json')
        if not os.path.exists(jp):
            print(f'  ✘ 缺 JSON {jp}')
            continue
        data = json.load(open(jp, encoding='utf-8'))
        atlas_data = []
        for i in range(len(data.get('atlases') or [1])):
            png = os.path.join(atlas_dir, f'{name}__atlas-{i}.png')
            if not os.path.exists(png):
                atlas_data.append('')
                continue
            w, h, px = read_png(png)
            if max(w, h) > 1200:
                w, h, px = downscale(w, h, px, 2)
            atlas_data.append('data:image/png;base64,' + png_b64(w, h, px))
            print(f'    {name} atlas-{i}: {w}×{h}')
        bundles.append(dict(
            name=data['buildName'] or name,
            atlasData=atlas_data,
            symbols=data['symbols'],
            anims=data['anims'],
            animNames=sorted(data['anims'].keys()),
        ))
    html = HTML.replace('__BUNDLES__', json.dumps(bundles, separators=(',', ':')))
    with open(out_html, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f'  → {out_html}  ({os.path.getsize(out_html) / 1048576:.1f} MB)')
    return 0


if __name__ == '__main__':
    base = '_animtest'
    specs = [
        ('pig_build', [f'{base}/pig_build.zip', f'{base}/ds_pig_basic.zip',
                       f'{base}/ds_pig_actions.zip']),
        ('rabbit_build', [f'{base}/rabbit_build.zip', f'{base}/ds_rabbit_basic.zip']),
        ('spider_build', [f'{base}/spider_build.zip', f'{base}/ds_spider_basic.zip']),
        ('beefalo_build', [f'{base}/beefalo_build.zip', f'{base}/beefalo_actions.zip']),
    ]
    build(specs, 'anim_data', '_out/json', '_out/anim_player.html')
