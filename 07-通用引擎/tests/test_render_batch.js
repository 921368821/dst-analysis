// test_render_batch.js —— C2：**批渲染路径的判据**
//
// ════════════════════════════════════════════════════════════════════════════
// 这份测试要回答的问题（C2 原文：「渲染管线只有 Canvas 2D，WebGL/批渲染未做
// ⇒ 大场景帧率上限」）
// ════════════════════════════════════════════════════════════════════════════
// 「做了批渲染」可以是一句很容易说出口但什么都没证明的话。所以判据必须是：
//   ① **几何等价**：批路径产出的每个四边形，4 个角的屏幕坐标必须与 Canvas 路径
//      `drawImage` 实际落到的位置**逐顶点相同**（≤1e-6），UV 也要相同；
//   ② **顺序等价**：strict 模式下，批路径拆开后的四边形序列必须与原始序列
//      **逐条同一对象**，且每个批都是原序列里**连续的一段**（这就是 run-length）；
//   ③ **收益是真的**：draw call 数从 N 降到多少，是**实测**出来的数字；
//   ④ **GL 层不靠看**：用一个记录调用的假 gl，验 drawArrays 的次数/偏移/顶点数
//      与批结构严格吻合，且**编译/链接失败会抛**（不许静默黑屏）；
//   ⑤ **判据有牙**：把批路径的数学**真的改坏**（源码级变异），①~③ 必须变红。
//
// ★★ 关键设计一：为什么"标准答案"不是拿两条同源公式互相比
//   如果两边都用 `toScreen()` 那套手写公式，比出来的只是「同一个函数调用两次」。
//   所以这里实现了一个**忠实的 Canvas 2D 变换栈**（save/restore/translate/scale/
//   transform 按 Canvas 规范的矩阵乘法累积），让**原版 `drawEntity` 自己**在它
//   上面跑，再把 drawImage 的目标矩形用这个矩阵栈映射到屏幕。两条路径的数学是
//   **独立写的**（一条矩阵栈累积、一条手写 T·S·M 展开式），"一致"才有信息量。
//
// ★★ 关键设计二：变异必须改**源码**，不能改导出对象
//   第一版把 `B.toScreen = 坏的`，判据全绿 —— 因为 `emitEntity` 内部调的是
//   闭包里的 `toScreen`，**不看导出对象**。改导出等于改了一个没人用的副本。
//   ⇒ 改成把 `rt/render_batch.js` 复制一份、定点替换源码、require 那个副本。
//     每个锚点必须**恰好命中 1 次**，否则报错（锚点过期就没人守这条判据了）。
'use strict';
const fs = require('fs');
const path = require('path');
const R = require('../rt/render_atlas.js');
const B = require('../rt/render_batch.js');

const RTPATH = path.join(__dirname, '..', 'rt');
const ATLAS = path.join(__dirname, '..', '..', '06-引擎复刻', '_out', 'json');
const MUTANTS = [];

let pass = 0, fail = 0;

// ★★ 本文件的**断言条数**必须显式声明，并在文件末尾自校验。
//   为什么不能静态数 `check(` 的调用行：①的几何/UV 等价是**按 4 个缩放档**
//   各跑一条断言，写在一个循环里 ⇒ 静态只数到 15 行，实跑 21 条。
//   两种口径并存 = 两张表各自计算、一起过期。⇒ 以声明值为唯一来源，
//   而声明值由测试自己守（条数对不上直接红）。
const EXPECT_ITEMS = 21;

function check(name, fn) {
  let r;
  try { r = fn(); }
  catch (e) {
    fail++; console.log('  ✘ ' + name + '  抛异常: ' + e.message);
    console.log('     ' + (e.stack || '').split('\n').slice(1, 3).join('\n     '));
    return;
  }
  if (r === true || (r && r.ok !== false)) { pass++; console.log('  ✔ ' + name + (r && r.info ? '  ' + r.info : '')); }
  else { fail++; console.log('  ✘ ' + name + (r && r.info ? '  ' + r.info : '')); }
}

console.log('═'.repeat(78));
console.log('  C2：批渲染路径（几何等价 / 顺序等价 / 收益实测 / GL 层 / 源码变异）');
console.log('═'.repeat(78));

// ---------------------------------------------------------------- 忠实模拟 Canvas 2D
/**
 * Canvas 2D 的变换矩阵 [a,b,c,d,e,f]，点映射：x' = a·x + c·y + e，y' = b·x + d·y + f。
 * `transform(a2..f2)` 是**右乘**（新变换作用在内层）。
 */
function makeCtx() {
  const calls = [];
  let m = [1, 0, 0, 1, 0, 0];
  const stack = [];
  const mul = (n) => {
    const [a, b, c, d, e, f] = m;
    m = [a * n[0] + c * n[1], b * n[0] + d * n[1],
         a * n[2] + c * n[3], b * n[2] + d * n[3],
         a * n[4] + c * n[5] + e, b * n[4] + d * n[5] + f];
  };
  return {
    calls,
    get matrix() { return m.slice(); },
    save() { stack.push(m.slice()); },
    restore() { if (stack.length) m = stack.pop(); },
    translate(x, y) { mul([1, 0, 0, 1, x, y]); },
    scale(sx, sy) { mul([sx, 0, 0, sy, 0, 0]); },
    transform(a, b, c, d, e, f) { mul([a, b, c, d, e, f]); },
    drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh) {
      calls.push({ img, sx, sy, sw, sh, dx, dy, dw, dh, m: m.slice() });
    },
    // drawEntity 走不到这些，但留着免得"少个方法"被误判成渲染逻辑坏了
    beginPath() {}, arc() {}, fill() {}, stroke() {}, fillRect() {}, fillText() {},
    moveTo() {}, lineTo() {},
  };
}

/** 把 drawImage 的目标矩形按当时的 CTM 映射成 4 个屏幕角（左上→右上→右下→左下） */
function callCorners(c) {
  const [a, b, cc, d, e, f] = c.m;
  const map = (x, y) => ({ x: a * x + cc * y + e, y: b * x + d * y + f });
  return [map(c.dx, c.dy), map(c.dx + c.dw, c.dy),
          map(c.dx + c.dw, c.dy + c.dh), map(c.dx, c.dy + c.dh)];
}

// ---------------------------------------------------------------- 真实图集数据
const buildFiles = fs.readdirSync(ATLAS).filter(f => f.endsWith('.json') && !f.startsWith('_'));
const builds = buildFiles.slice(0, 6).map(f => f.replace(/\.json$/, ''));
const DATA = {};
for (const b of builds) DATA[b] = JSON.parse(fs.readFileSync(path.join(ATLAS, b + '.json'), 'utf8'));
const ATLAS_W = 2048, ATLAS_H = 1024;

/**
 * 某个 build 的图集尺寸 —— **必须按 build 取，不能用一个全局常量**。
 * ★ 实测这批真实数据：beefalo_build 2048×2048、beefalo_fx 1024×512、
 *   bee_build 256×256、butterfly 512×512。第一版统一按 2048×1024 反推 UV，
 *   判据报「UV 最大偏差 1.00e+0」—— 差一个整数不是浮点噪声，是**基准错了**。
 *   （与 C1 那次 perf_counter/time.time 混用同源：判据的基准必须与被测对象一致。）
 */
function dimOf(build) {
  const d = DATA[build] || {};
  return { w: (d.atlas && d.atlas.w) || ATLAS_W, h: (d.atlas && d.atlas.h) || ATLAS_H };
}

/** 造一个"图集已加载完"的 AtlasRenderer（不碰 DOM / XHR） */
function makeAtlas() {
  const ctx = makeCtx();
  const atlas = new R.AtlasRenderer('/atlas', ctx);
  for (const b of builds) {
    const d = DATA[b];
    const nAtlas = Math.max(1, (d.atlases || []).length);
    const dim = dimOf(b);
    const images = [];
    for (let i = 0; i < nAtlas; i++) {
      images.push({ complete: true, naturalWidth: dim.w, naturalHeight: dim.h, id: b + '#' + i });
    }
    atlas.builds[b] = { json: d, images, w: dim.w, h: dim.h, loading: false, failed: false };
    atlas._indexBuild(b, d);
  }
  return { atlas, ctx };
}

/** 构造一盘实体：每类 build 取若干 anim，位置取非整数/负数（对称点会掩盖 Y 翻转） */
function makeEnts(maxPerBuild) {
  const ents = [];
  let n = 0;
  for (const b of builds) {
    const anims = Object.keys(DATA[b].anims || {});
    let k = 0;
    for (const an of anims) {
      ents.push({ id: ++n, bld: b, a: an, fr: (k * 3) % 7,
                  x: (n * 37 % 91) - 45.5, z: (n * 53 % 77) - 38.25 });
      k++;
      if (k >= (maxPerBuild || 4)) break;
    }
  }
  return ents;
}

const ENTS = makeEnts(4);

/** 走 Canvas 路径：原版 drawEntity 在模拟 ctx 上真跑一遍 */
function canvasPass(ents, zoom) {
  const { atlas, ctx } = makeAtlas();
  for (const e of ents) atlas.drawEntity(e, e.x * zoom, e.z * zoom, zoom);
  return { ctx, atlas };
}

/** 走批路径：emitEntity 摊平 → packBatches（mod 可传入变异体） */
function batchPass(ents, zoom, order, mod) {
  const M = mod || B;
  const { atlas } = makeAtlas();
  const quads = [];
  const stats = {};
  // ★ 刻意**不传** hasTex：验的正是 render_batch 的默认实现是否与 Canvas 同语义
  //   （第一版默认"一律当有"⇒ 多出 4 个四边形，185 vs 189，判据当场抓到）。
  for (const e of ents) {
    const rec = atlas.builds[e.bld];
    M.emitEntity(rec, e, e.x * zoom, e.z * zoom, zoom, atlas._sym.bind(atlas), quads, stats);
  }
  return { quads, stats, packed: M.packBatches(quads, { order: order || 'strict' }) };
}

/** 几何/UV 等价的判据本体（①用的就是它，⑤的变异也用它） */
function geomVerdict(zoom, order, mod) {
  const cv = canvasPass(ENTS, zoom);
  const bt = batchPass(ENTS, zoom, order, mod);
  const calls = cv.ctx.calls, quads = bt.quads;
  if (calls.length !== quads.length) {
    return { ok: false, info: '四边形数量不等：Canvas ' + calls.length + ' vs 批 ' + quads.length };
  }
  let worstP = 0, worstUV = 0, badAt = null;
  for (let i = 0; i < calls.length; i++) {
    const cp = callCorners(calls[i]);
    const qp = quads[i].p;
    for (let k = 0; k < 4; k++) {
      const dx = Math.abs(cp[k].x - qp[k].x), dy = Math.abs(cp[k].y - qp[k].y);
      if (dx > worstP) worstP = dx;
      if (dy > worstP) worstP = dy;
      if ((dx > 1e-6 || dy > 1e-6) && !badAt) badAt = { i, k, canvas: cp[k], batch: qp[k], sym: quads[i].sym };
    }
    // UV：从 drawImage 的源矩形反推归一化 UV，与批路径比。
    // ★ 分母必须取**这张图所属 build** 的尺寸（img.id 形如 "build#idx"）。
    const c = calls[i];
    const dim = dimOf(String(c.img.id).split('#')[0]);
    const exp = [[c.sx / dim.w, c.sy / dim.h],
                 [(c.sx + c.sw) / dim.w, c.sy / dim.h],
                 [(c.sx + c.sw) / dim.w, (c.sy + c.sh) / dim.h],
                 [c.sx / dim.w, (c.sy + c.sh) / dim.h]];
    for (let k = 0; k < 4; k++) {
      worstUV = Math.max(worstUV, Math.abs(exp[k][0] - quads[i].uv[k][0]),
                                  Math.abs(exp[k][1] - quads[i].uv[k][1]));
    }
  }
  if (worstP > 1e-6) {
    return { ok: false, info: '顶点最大偏差 ' + worstP.toExponential(2) + ' px > 1e-6；首个越界 '
      + JSON.stringify(badAt) };
  }
  if (worstUV > 1e-9) return { ok: false, info: 'UV 最大偏差 ' + worstUV.toExponential(2) + ' > 1e-9' };
  return { ok: true, info: quads.length + ' 个四边形 · 顶点偏差 ' + worstP.toExponential(1)
    + ' · UV 偏差 ' + worstUV.toExponential(1) };
}

// =============================================================================
// ① 几何等价
// =============================================================================
console.log('  受测实体：' + ENTS.length + ' 个，覆盖 ' + builds.length + ' 个 build');

check('① 几何等价 @ zoom=8（手写展开式 vs Canvas 矩阵栈）', () => geomVerdict(8));
check('① 几何等价 @ zoom=8 grouped（批不改几何）', () => geomVerdict(8, 'grouped'));
check('① 几何等价 @ zoom=1.7（非整数缩放，掩盖不了 Y 翻转）', () => geomVerdict(1.7));
check('① 几何等价 @ zoom=23（大缩放，1e-6 也藏不住）', () => geomVerdict(23, 'grouped'));

// =============================================================================
// ② 顺序等价（strict）
// =============================================================================
check('② strict：拆批后与原始序列逐条**同一对象**且每批是连续段', () => {
  const bt = batchPass(ENTS, 8, 'strict');
  const quads = bt.quads;
  const origIdx = new Map();
  for (let i = 0; i < quads.length; i++) origIdx.set(quads[i], i);
  let at = 0;
  for (const b of bt.packed.batches) {
    for (let k = 0; k < b.quads.length; k++) {
      if (b.quads[k] !== quads[at]) {
        return { ok: false, info: '第 ' + at + ' 个四边形被挪位（strict 必须保序）' };
      }
      if (origIdx.get(b.quads[k]) !== at) return { ok: false, info: '原下标错位 @' + at };
      at++;
    }
    // 批内相邻同纹理
    for (let k = 1; k < b.quads.length; k++) {
      if (b.quads[k].key !== b.key) return { ok: false, info: '批里混进了别的纹理：' + b.quads[k].key };
    }
  }
  if (at !== quads.length) return { ok: false, info: '拆批后只剩 ' + at + '/' + quads.length };
  return { ok: true, info: quads.length + ' 条逐条同序 · ' + bt.packed.drawCalls + ' 批' };
});

// =============================================================================
// ③ 收益实测（数字是量出来的）
// =============================================================================
function benefitVerdict(mod) {
  const bt = batchPass(ENTS, 8, 'strict', mod);
  const n = bt.quads.length, d = bt.packed.drawCalls;
  if (!(d < n)) return { ok: false, info: '批数 ' + d + ' 未少于符号数 ' + n + ' ⇒ 等于没批' };
  return { ok: true, info: n + ' 个符号 → ' + d + ' 次 drawArrays（省 '
    + (100 * (1 - d / n)).toFixed(1) + '%）' };
}

check('③ 收益：strict 模式的 draw call 数（真实图集数据）', () => benefitVerdict(B));

check('③ 收益：grouped 更省，且顺序代价**如数报出**', () => {
  const bt = batchPass(ENTS, 8, 'grouped');
  const n = bt.quads.length, d = bt.packed.drawCalls;
  const distinct = new Set(bt.quads.map(q => q.key)).size;
  if (d !== distinct) return { ok: false, info: '批数 ' + d + ' ≠ 不同纹理数 ' + distinct };
  const ov = bt.packed.overlapViolations;
  return { ok: true, info: n + ' 个符号 → ' + d + ' 次（省 ' + (100 * (1 - d / n)).toFixed(1)
    + '%）· 改序对 ' + bt.packed.orderViolations + ' · 其中屏幕重叠 '
    + (ov === null ? '未计算(n>2500)' : ov) };
});

check('③ 前提：strict ≥ grouped（保序必然更贵，否则分组逻辑反了）', () => {
  const s = batchPass(ENTS, 8, 'strict').packed.drawCalls;
  const g = batchPass(ENTS, 8, 'grouped').packed.drawCalls;
  if (s < g) return { ok: false, info: 'strict=' + s + ' < grouped=' + g };
  return { ok: true, info: 'strict=' + s + ' ≥ grouped=' + g };
});

// =============================================================================
// ④ GL 层
// =============================================================================
function makeFakeGL() {
  const log = [];
  const gl = {
    log,
    ARRAY_BUFFER: 0x8892, DYNAMIC_DRAW: 0x88E8, FLOAT: 0x1406, TRIANGLES: 0x0004,
    VERTEX_SHADER: 0x8B31, FRAGMENT_SHADER: 0x8B30, COMPILE_STATUS: 0x8B81, LINK_STATUS: 0x8B82,
    TEXTURE_2D: 0x0DE1, BLEND: 0x0BE2, SRC_ALPHA: 0x0302, ONE_MINUS_SRC_ALPHA: 0x0303,
    createShader: (t) => ({ t }),
    shaderSource: (s, src) => { s.src = src; },
    compileShader: (s) => { s.ok = !!(s.src && s.src.length > 10); },
    getShaderParameter: (s, p) => (p === gl.COMPILE_STATUS ? s.ok !== false : true),
    getShaderInfoLog: () => 'fake log',
    createProgram: () => ({}),
    attachShader: () => {},
    linkProgram: (p) => { p.linked = true; },
    getProgramParameter: (p, k) => (k === gl.LINK_STATUS ? p.linked !== false : true),
    getProgramInfoLog: () => 'fake link log',
    getAttribLocation: (p, n) => (n === 'a_pos' ? 0 : n === 'a_uv' ? 1 : -1),
    getUniformLocation: (p, n) => ({ n }),
    createBuffer: () => ({ buf: true }),
    bindBuffer: () => {},
    bufferData: (t, arr) => log.push(['bufferData', arr.length]),
    enableVertexAttribArray: () => {},
    vertexAttribPointer: (i, n, type, norm, stride, off) => log.push(['vertexAttribPointer', i, n, stride, off]),
    useProgram: () => {},
    uniform2f: (l, a, b) => log.push(['uniform2f', l.n, a, b]),
    uniform1i: (l, a) => log.push(['uniform1i', l.n, a]),
    createTexture: () => ({ tex: true }),
    bindTexture: () => {},
    drawArrays: (mode, first, count) => log.push(['drawArrays', mode, first, count]),
    enable: () => {}, blendFunc: () => {},
  };
  return gl;
}

check('④ GL：drawArrays 的次数/偏移/顶点数严格吻合批结构', () => {
  const bt = batchPass(ENTS, 8, 'strict');
  const gl = makeFakeGL();
  const rd = new B.WebGLAtlasRenderer(gl);
  for (const q of bt.quads) rd.setTexture(q.key, { tex: true });
  rd.draw(bt.packed, 1280, 720);
  const draws = gl.log.filter(x => x[0] === 'drawArrays');
  if (draws.length !== bt.packed.drawCalls) {
    return { ok: false, info: 'drawArrays ' + draws.length + ' 次 ≠ 批数 ' + bt.packed.drawCalls };
  }
  let first = 0;
  for (let i = 0; i < draws.length; i++) {
    const b = bt.packed.batches[i];
    if (draws[i][1] !== gl.TRIANGLES) return { ok: false, info: '第 ' + i + ' 批 mode 不是 TRIANGLES' };
    if (draws[i][2] !== first) return { ok: false, info: '第 ' + i + ' 批 first=' + draws[i][2] + ' 应为 ' + first };
    if (draws[i][3] !== b.quads.length * 6) {
      return { ok: false, info: '第 ' + i + ' 批顶点数 ' + draws[i][3] + ' ≠ ' + (b.quads.length * 6) };
    }
    first += draws[i][3];
  }
  if (first !== bt.quads.length * 6) return { ok: false, info: '总顶点 ' + first + ' ≠ ' + bt.quads.length * 6 };
  const bd = gl.log.find(x => x[0] === 'bufferData');
  if (bd[1] !== bt.quads.length * 6 * 4) {
    return { ok: false, info: '上传 float 数 ' + bd[1] + ' ≠ ' + (bt.quads.length * 6 * 4) };
  }
  return { ok: true, info: draws.length + ' 次 drawArrays · ' + first + ' 顶点 · 上传 '
    + (bd[1] * 4 / 1024).toFixed(1) + ' KB' };
});

check('④ GL：缺纹理 ⇒ 跳过 + 记账（不许拿上一张纹理凑合）', () => {
  const bt = batchPass(ENTS, 8, 'strict');
  const gl = makeFakeGL();
  const rd = new B.WebGLAtlasRenderer(gl);
  const only = bt.packed.batches[0].key;
  rd.setTexture(only, { tex: true });
  const res = rd.draw(bt.packed, 1280, 720);
  const draws = gl.log.filter(x => x[0] === 'drawArrays').length;
  // ★ strict 是 run-length：**同一个纹理键会在多个批里出现**（a,b,a,b…）。
  //   第一版把期望写成"只画 1 批"，结果 4 批都被算成"多画了" —— 是**期望错了**，
  //   不是实现错了。这里按"键相同的批数"算，才是这条判据的真实含义。
  const expectDraws = bt.packed.batches.filter(b => b.key === only).length;
  const miss = bt.packed.batches.length - expectDraws;
  if (draws !== expectDraws) {
    return { ok: false, info: '画了 ' + draws + ' 批 ≠ 有纹理的批数 ' + expectDraws };
  }
  if (res.missingTextures !== miss) return { ok: false, info: '记账 ' + res.missingTextures + ' ≠ 期望 ' + miss };
  if (rd.stats.missingTextures !== miss) return { ok: false, info: 'stats.missingTextures 没同步' };
  return { ok: true, info: '只画 ' + expectDraws + ' 批（同键）· 记账 ' + miss + ' 批缺纹理' };
});

check('④ GL：着色器编译失败必须**抛**（不许静默黑屏）', () => {
  const gl = makeFakeGL();
  gl.compileShader = (s) => { s.ok = false; };
  let threw = false, msg = '';
  try { void new B.WebGLAtlasRenderer(gl); } catch (e) { threw = true; msg = e.message; }
  if (!threw) return { ok: false, info: '编译失败却构造成功了 —— 这正是"假绿"的形状' };
  if (!/着色器编译失败/.test(msg)) return { ok: false, info: '抛了但消息不含"着色器编译失败"：' + msg };
  return { ok: true, info: '抛出并带原文' };
});

check('④ GL：程序链接失败必须**抛**', () => {
  const gl = makeFakeGL();
  gl.linkProgram = (p) => { p.linked = false; };
  let threw = false, msg = '';
  try { void new B.WebGLAtlasRenderer(gl); } catch (e) { threw = true; msg = e.message; }
  if (!threw) return { ok: false, info: '链接失败却构造成功了' };
  if (!/程序链接失败/.test(msg)) return { ok: false, info: '抛了但消息不含"程序链接失败"：' + msg };
  return { ok: true, info: '抛出并带原文' };
});

// =============================================================================
// ⑤ 源码级变异：改坏实现，①②③ 必须变红
// =============================================================================
console.log('');
console.log('  ⑤ 源码变异（改坏 rt/render_batch.js，判据必须变红）');

let MUT_SEQ = 0;
function loadMutant(tag, edits) {
  let src = fs.readFileSync(path.join(RTPATH, 'render_batch.js'), 'utf8');
  src = src.replace(/\r\n/g, '\n');        // 锚点按 LF 写，先归一化（本工程混用两种换行）
  for (const [oldS, newS] of edits) {
    const n = src.split(oldS).length - 1;
    if (n !== 1) throw new Error('变异锚点命中 ' + n + ' 次（要求恰好 1 次）：' + oldS.slice(0, 70));
    src = src.replace(oldS, newS);
  }
  const name = '_mut_' + tag + '_' + (++MUT_SEQ) + '.js';
  const p = path.join(RTPATH, name);
  fs.writeFileSync(p, src, 'utf8');
  MUTANTS.push(p);
  return require(p);
}

function expectRed(name, edits, verdict) {
  check(name, () => {
    const m = loadMutant('m', edits);
    const r = verdict(m);
    if (r.ok) return { ok: false, info: '★ 实现被改坏了，判据居然还是绿的 —— 判据没牙' };
    return { ok: true, info: '如预期变红：' + String(r.info).slice(0, 70) };
  });
}

const S_TO_SCREEN = '  return { x: sx + scale * p.x, y: sy - scale * p.y };';
const S_APPLYMAT = '  const p = _ATLAS.applyMat(mat, x, y);';
const S_RUNLEN = '      if (!cur || cur.key !== q.key) {';
const S_ORDER = "  const order = (opt && opt.order) || 'strict';";
const S_UV = '      uv: [[uv.u0, uv.v0], [uv.u1, uv.v0], [uv.u1, uv.v1], [uv.u0, uv.v1]],';
const S_INV = '      else { inv += (mid - i); buf[k++] = a[j++]; }';

expectRed('⑤a 丢 Y 翻转（y: sy + scale*p.y）⇒ ①红',
  [[S_TO_SCREEN, '  return { x: sx + scale * p.x, y: sy + scale * p.y };']],
  (m) => geomVerdict(8, 'strict', m));

expectRed('⑤b 不套 mat（p = {x,y}）⇒ ①红',
  [[S_APPLYMAT, '  const p = { x, y };']],
  (m) => geomVerdict(8, 'strict', m));

expectRed('⑤c 角点 x/y 对调 ⇒ ①红',
  [[S_TO_SCREEN, '  return { x: sy - scale * p.y, y: sx + scale * p.x };']],
  (m) => geomVerdict(8, 'strict', m));

expectRed('⑤d 每格一批（不合并）⇒ ③收益判据红',
  [[S_RUNLEN, '      if (true) {']],
  (m) => benefitVerdict(m));

expectRed('⑤e strict 偷偷按纹理归组 ⇒ ②顺序判据红',
  [[S_ORDER, "  const order = 'grouped' || (opt && opt.order);"]],
  (m) => {
    const bt = batchPass(ENTS, 8, 'strict', m);
    const quads = bt.quads;
    let at = 0;
    for (const b of bt.packed.batches) {
      for (const q of b.quads) {
        if (q !== quads[at]) return { ok: false, info: '第 ' + at + ' 个四边形被挪位（' + q.key + '）' };
        at++;
      }
    }
    return { ok: true };
  });

expectRed('⑤f UV 少乘图集尺寸（u 变像素）⇒ ①的 UV 判据红',
  [[S_UV, '      uv: [[uv.u0 * w, uv.v0], [uv.u1 * w, uv.v0], [uv.u1 * w, uv.v1], [uv.u0 * w, uv.v1]],']],
  (m) => geomVerdict(8, 'strict', m));

expectRed('⑤g 逆序计数恒 0（顺序代价记账造假）⇒ 必须红',
  [[S_INV, '      else { buf[k++] = a[j++]; }']],
  (m) => {
    // 交替纹理必然产生逆序
    const quads = [];
    for (let i = 0; i < 8; i++) {
      quads.push({ key: (i % 2) ? 'a|0' : 'b|0', build: (i % 2) ? 'a' : 'b', atlas: 0, sym: 's' + i, frame: 0,
                   depth: 0, p: [{ x: i, y: 0 }, { x: i + 1, y: 0 }, { x: i + 1, y: 1 }, { x: i, y: 1 }],
                   uv: [[0, 0], [1, 0], [1, 1], [0, 1]] });
    }
    const packed = m.packBatches(quads, { order: 'grouped' });
    if (!(packed.orderViolations > 0)) {
      return { ok: false, info: 'orderViolations=' + packed.orderViolations + '（交替纹理下不可能为 0）' };
    }
    return { ok: true };
  });

check('⑤h 空输入 / 缺字段不许崩，且必须如实返回 0', () => {
  const p0 = B.packBatches([], { order: 'strict' });
  if (p0.drawCalls !== 0 || p0.quadCount !== 0) return { ok: false, info: '空输入返回 ' + JSON.stringify(p0) };
  const e1 = B.emitEntity({ json: { anims: {} }, w: 1, h: 1 }, { bld: 'x' }, 0, 0, 1, () => null, [], {}, null);
  if (e1 !== 0) return { ok: false, info: 'emitEntity 对空 anims 返回 ' + e1 };
  const e2 = B.emitEntity(null, {}, 0, 0, 1, () => null, [], {}, null);
  if (e2 !== 0) return { ok: false, info: 'emitEntity 对 null rec 返回 ' + e2 };
  return { ok: true, info: '空 anims / null rec / 空 quads 都返回 0' };
});

check('⑤i 锚点唯一性：所有变异锚点在当前源码里各命中恰好 1 次', () => {
  const src = fs.readFileSync(path.join(RTPATH, 'render_batch.js'), 'utf8').replace(/\r\n/g, '\n');
  const anchors = [S_TO_SCREEN, S_APPLYMAT, S_RUNLEN, S_ORDER, S_UV, S_INV];
  const bad = [];
  for (const a of anchors) {
    const n = src.split(a).length - 1;
    if (n !== 1) bad.push(n + '× ' + a.trim().slice(0, 40));
  }
  if (bad.length) return { ok: false, info: '锚点不唯一/不存在：' + bad.join(' | ') };
  return { ok: true, info: anchors.length + ' 个锚点各 1 次' };
});

// ---------------------------------------------------------------- 清理变异体
let leftover = 0;
for (const p of MUTANTS) {
  try { delete require.cache[require.resolve(p)]; } catch (e) { /* ignore */ }
  try { fs.unlinkSync(p); } catch (e) { /* ignore */ }
  if (fs.existsSync(p)) leftover++;
}

console.log('');
console.log('═'.repeat(78));
console.log('  结果：通过 ' + pass + ' · 失败 ' + fail
  + '（变异体建了 ' + MUTANTS.length + ' 个，残留 ' + leftover + ' 个）');
console.log('═'.repeat(78));

// ★ 声明值自校验（见文件头 EXPECT_ITEMS 的说明）
const done = pass + fail;
if (done !== EXPECT_ITEMS) {
  console.log('  ✘ 断言条数与声明不符：声明 ' + EXPECT_ITEMS + ' 条，实跑 ' + done
    + ' 条（增删断言后请同步本文件的 EXPECT_ITEMS）');
  process.exit(1);
}
process.exit(fail || leftover ? 1 : 0);
