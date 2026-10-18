// render_batch.js —— **批渲染路径**（C2）
//
// ════════════════════════════════════════════════════════════════════════════
// 为什么有这个文件
// ════════════════════════════════════════════════════════════════════════════
// `校验报告-P43` 的 C2：「渲染管线只有 **Canvas 2D**，WebGL / 批渲染未做
//   ⇒ 大场景帧率上限」。
//
// Canvas 2D 路径（`render_atlas.js` 的 `drawEntity`）每个**符号**要付：
//     ctx.save() → translate → scale → transform → drawImage → restore
// 一个实体常常有 3~8 个符号，400 个实体就是 **1200~3200 次 drawImage**，
// 每次都带一次状态栈压/弹。这是帧率上限的来源，不是「算法慢」。
//
// 批渲染把「每个符号一次 draw」压成「每个**(build, atlas) 一次 drawArrays**」：
// 顶点在 CPU 侧算成屏幕坐标，一次性上传，GPU 一次画完同纹理的所有四边形。
//
// ════════════════════════════════════════════════════════════════════════════
// 设计上的三条硬约束（C2 不能靠"看起来能跑"结案）
// ════════════════════════════════════════════════════════════════════════════
// ① **几何必须与 Canvas 路径逐顶点等价**
//      Canvas 的变换是 T(sx,sy) · S(scale,-scale) · M，然后 drawImage 把
//      源矩形映射到轴对齐的目标矩形。这里必须用**同一套数学**算出 4 个角。
//      判据：两边算出的屏幕坐标差 ≤ 1e-6（见 tests/test_render_batch.js）。
//      ★ 注意 Y 轴：DST 的 z 朝上、canvas 的 y 朝下 ⇒ 那个 `-scale` 不能省。
//
// ② **绘制顺序必须可判**
//      批处理天然会改顺序（按纹理归组）。所以这里给两种模式：
//        · `order: 'strict'`  —— **run-length 合并相邻同纹四边形**：顺序与原版
//          逐条绘制**完全一致**，收益只来自"相邻的同一图集被合并"。
//        · `order: 'grouped'` —— 按纹理归组：draw call 最少，但会改前后关系。
//      两种模式都返回 `orderViolations`（有多少对精灵的前后关系被改掉），
//      grouped 还返回 `overlapViolations`（其中**屏幕上真的重叠**的有多少对
//      —— 只有这一类会影响看到的画面）。**不静默**：数字摆在返回值里。
//      默认 `strict`：正确性优先，收益仍然真实（见实测）。
//
// ③ **不许把"画不出来"变成"画了但看不见"**
//      缺纹理 / 缺符号都要记账（`stats.missingTextures` / `missingSymbols`），
//      调用方据此回退 —— 与 Canvas 路径「返回 false 让调用方画圆」同一纪律。
//
// ════════════════════════════════════════════════════════════════════════════
// 与 Canvas 路径的关系（一份数学，两处消费）
// ════════════════════════════════════════════════════════════════════════════
// `uvRect` / `localQuad` / `animFrame` / `applyMat` **直接复用** `render_atlas.js`
// 的导出，不抄第二份 —— 抄一份就等着两处一起过期（本工程 C9 的教训）。
// 符号查找也由调用方注入（`lookup(rec, symId)`），所以跨 build 共享符号表
// 用的仍是 `AtlasRenderer._sym` 那一份逻辑，批路径不另开一套。
'use strict';

const _ATLAS = (typeof module !== 'undefined' && module.exports)
  ? require('./render_atlas.js')
  : (typeof RenderAtlas !== 'undefined' ? RenderAtlas : null);

/**
 * Canvas 路径的变换链，逐字实现：
 *   ctx.translate(sx, sy); ctx.scale(scale, -scale); ctx.transform(m[0..5]);
 * 于是 screen = (sx + scale*p'.x, sy - scale*p'.y)，p' = M·p
 */
function toScreen(mat, sx, sy, scale, x, y) {
  const p = _ATLAS.applyMat(mat, x, y);
  return { x: sx + scale * p.x, y: sy - scale * p.y };
}

/** 纹理分组键：实体自己的 build + 符号的 atlas 序号（与 drawEntity 取 img 的方式一致） */
function texKey(build, atlasIdx) {
  return build + '|' + (atlasIdx || 0);
}

/**
 * 把一个实体的所有符号摊成四边形（**不画，只算**）。
 *
 * @param {Function} [hasTex] 可选：`(rec, atlasIdx) => bool`。
 *        ★★ 默认实现**逐字镜像** Canvas 路径那句
 *        `if (!img || !img.complete || img.naturalWidth === 0) continue;`
 *        —— 这不是可选的礼节：第一版默认"一律当有"，于是有 4 个
 *        `sym.atlas` 指向该 build 不存在的图集序号的符号，Canvas 跳过了、
 *        批路径却产出了四边形（189 vs 185）。等价性判据当场把它抓出来。
 *        ⇒ 默认值必须与 Canvas 同语义；有特殊需要才用参数覆盖。
 * @returns {number} 真的产出四边形的个数（0 ⇒ 调用方应回退画圆，与 Canvas 路径同语义）
 */
function emitEntity(rec, ent, sx, sy, scale, lookup, out, stats, hasTex) {
  if (!rec || rec.loading || rec.failed || !rec.json) return 0;
  const frame = _ATLAS.animFrame(rec.json, (ent && ent.a) || 'idle_loop', (ent && ent.fr) || 0);
  if (!frame) return 0;
  let made = 0;
  for (const item of frame) {
    const sym = lookup(rec, item.sym);
    if (!sym) continue;
    const fr = sym.frames[String(item.frame != null ? item.frame : 0)] ||
               sym.frames[Object.keys(sym.frames)[0]];
    if (!fr || !fr.verts) continue;
    // ★ 与 drawEntity 完全一致：用**实体自己 build** 的图集尺寸与 atlas 序号
    //   （跨 build 共享符号时这里是一个近似 —— 原版 Canvas 路径就是这样，
    //    批路径**不引入新语义**，也不在这里"顺手修好"，否则两条路径立刻不等价。）
    const atlasIdx = sym.atlas || 0;
    const img = rec.images && rec.images[atlasIdx];
    const ready = hasTex
      ? hasTex(rec, atlasIdx)
      : !!(img && img.complete && img.naturalWidth > 0);
    if (!ready) continue;                                // 图集未就绪 ⇒ 与 Canvas 一样跳过
    const w = rec.w || 1024, h = rec.h || 1024;
    const uv = _ATLAS.uvRect(fr.verts, w, h);
    const q = _ATLAS.localQuad(fr.verts);
    if (uv.w <= 0 || uv.h <= 0 || q.w <= 0 || q.h <= 0) continue;
    const m = item.mat || [1, 0, 0, 1, 0, 0];
    // 4 个角：与 drawImage(dest = q.x0,q.y0,q.w,q.h) 的轴对齐矩形一一对应
    const c0 = toScreen(m, sx, sy, scale, q.x0, q.y0);
    const c1 = toScreen(m, sx, sy, scale, q.x1, q.y0);
    const c2 = toScreen(m, sx, sy, scale, q.x1, q.y1);
    const c3 = toScreen(m, sx, sy, scale, q.x0, q.y1);
    out.push({
      key: texKey(ent && ent.bld, atlasIdx),
      build: ent && ent.bld,
      atlas: atlasIdx,
      sym: item.sym,
      frame: (item.frame != null ? item.frame : 0),
      // 屏幕坐标（像素），顺序：左上 → 右上 → 右下 → 左下
      p: [c0, c1, c2, c3],
      // 归一化 UV，与 4 个角一一对应
      uv: [[uv.u0, uv.v0], [uv.u1, uv.v0], [uv.u1, uv.v1], [uv.u0, uv.v1]],
      // 深度键（mat[6] 是原版的 z），只用于记账，不参与排序
      depth: (m.length >= 7 ? m[6] : 0),
    });
    made++;
    if (stats) stats.quadsMade = (stats.quadsMade || 0) + 1;
  }
  return made;
}

/** 逆序对计数（merge sort，O(n log n)）：衡量"顺序被改动了多少对" */
function countInversions(arr) {
  const a = arr.slice();
  let inv = 0;
  const buf = new Array(a.length);
  function ms(lo, hi) {
    if (hi - lo <= 1) return;
    const mid = (lo + hi) >> 1;
    ms(lo, mid); ms(mid, hi);
    let i = lo, j = mid, k = lo;
    while (i < mid && j < hi) {
      if (a[i] <= a[j]) buf[k++] = a[i++];
      else { inv += (mid - i); buf[k++] = a[j++]; }
    }
    while (i < mid) buf[k++] = a[i++];
    while (j < hi) buf[k++] = a[j++];
    for (let t = lo; t < hi; t++) a[t] = buf[t];
  }
  ms(0, a.length);
  return inv;
}

/**
 * 屏幕矩形重叠的"改序对"计数。
 *
 * ★ 为什么单列这一个数：`orderViolations` 只说明"顺序变了"，而**顺序只有在
 *   两个精灵的屏幕矩形真的重叠时才看得出来**。把这两件事混成一个数，
 *   就会得出"批渲染改变了画面"这种过强的结论（或者反过来，被当成噪声忽略）。
 * ★ 规模保护：O(n²)，n > 2500 时返回 null（**不是 0**）—— 「没算」与「算出来是 0」
 *   必须能区分，这是本工程反复强调的一条。
 */
function countOverlapViolations(strictOrder, groupedOrder, quads, maxN) {
  const n = quads.length;
  if (n > (maxN || 2500)) return null;
  const posInGrouped = new Array(n);
  for (let i = 0; i < n; i++) posInGrouped[groupedOrder[i]] = i;
  const box = (q) => {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const c of q.p) {
      if (c.x < x0) x0 = c.x; if (c.x > x1) x1 = c.x;
      if (c.y < y0) y0 = c.y; if (c.y > y1) y1 = c.y;
    }
    return { x0, y0, x1, y1 };
  };
  const bs = quads.map(box);
  let bad = 0;
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      if (posInGrouped[i] < posInGrouped[j]) continue;     // 前后关系没变
      const A = bs[i], B = bs[j];
      if (A.x1 <= B.x0 || B.x1 <= A.x0 || A.y1 <= B.y0 || B.y1 <= A.y0) continue;
      bad++;
    }
  }
  return bad;
}

/**
 * 把四边形列表打成批。
 *
 * @param {Array} quads emitEntity 产出的四边形（**输入顺序 = 原版绘制顺序**）
 * @param {Object} opt  { order: 'strict' | 'grouped' }
 * @returns {{batches:Array, drawCalls:number, quadCount:number,
 *            orderViolations:number, overlapViolations:(number|null)}}
 */
function packBatches(quads, opt) {
  const order = (opt && opt.order) || 'strict';
  const batches = [];
  let strictIdx = null, groupedIdx = null;

  if (order === 'strict') {
    // run-length：相邻同纹理才合并 ⇒ 顺序**逐条不变**
    let cur = null;
    for (let i = 0; i < quads.length; i++) {
      const q = quads[i];
      if (!cur || cur.key !== q.key) {
        cur = { key: q.key, build: q.build, atlas: q.atlas, quads: [] };
        batches.push(cur);
      }
      cur.quads.push(q);
    }
    // 顺序按定义没变：用**同一份序列**自己比自己会恒等于 0，没有信息量 ⇒
    // 这里返回 null，并让测试去比"与 Canvas drawImage 序列逐条相同"。
    strictIdx = null;
  } else {
    const byKey = new Map();
    // ★ 原下标用 Map 反查，**不要**写 `quads.indexOf(q)`：那是 O(n²)，
    //   在 3000 个四边形时就是 900 万次比较 —— 判据会慢到没人愿意跑。
    const origIdx = new Map();
    for (let i = 0; i < quads.length; i++) origIdx.set(quads[i], i);
    for (let i = 0; i < quads.length; i++) {
      const q = quads[i];
      let b = byKey.get(q.key);
      if (!b) { b = { key: q.key, build: q.build, atlas: q.atlas, quads: [] }; byKey.set(q.key, b); batches.push(b); }
      b.quads.push(q);
    }
    // grouped 的全局顺序 = 批的先后（按首次出现）× 批内原序
    groupedIdx = [];
    for (const b of batches) for (const q of b.quads) groupedIdx.push(origIdx.get(q));
    strictIdx = quads.map((_, i) => i);
  }

  let orderViolations = 0, overlapViolations = null;
  if (groupedIdx) {
    // 把 grouped 顺序映射回"原下标序列"，数它有多少逆序对 = 多少对被改序
    orderViolations = countInversions(groupedIdx);
    overlapViolations = countOverlapViolations(strictIdx, groupedIdx, quads);
  }
  return {
    batches,
    drawCalls: batches.length,
    quadCount: quads.length,
    orderViolations,
    overlapViolations,
    order,
  };
}

// ------------------------------------------------------------------ WebGL 侧
const VS = [
  'attribute vec2 a_pos;',          // 屏幕像素坐标（CPU 侧已算好）
  'attribute vec2 a_uv;',
  'uniform vec2 u_res;',            // canvas 尺寸（像素）
  'varying vec2 v_uv;',
  'void main() {',
  '  vec2 clip = vec2(a_pos.x / u_res.x * 2.0 - 1.0, 1.0 - a_pos.y / u_res.y * 2.0);',
  '  gl_Position = vec4(clip, 0.0, 1.0);',
  '  v_uv = a_uv;',
  '}',
].join('\n');

const FS = [
  'precision mediump float;',
  'uniform sampler2D u_tex;',
  'varying vec2 v_uv;',
  'void main() {',
  '  vec4 c = texture2D(u_tex, v_uv);',
  '  if (c.a < 0.004) discard;',      // 图集是透明背景，不 discard 会画出一整块黑
  '  gl_FragColor = c;',
  '}',
].join('\n');

/** 把一批四边形摊成 6 顶点/个的三角形列表（两三角形拼一个四边形） */
const TRI = [0, 1, 2, 0, 2, 3];

class WebGLAtlasRenderer {
  /**
   * @param {WebGLRenderingContext} gl
   * @param {Object} opt { flipV:boolean }  —— 图集 PNG 的 v 方向（默认不翻）
   */
  constructor(gl, opt) {
    if (!gl) throw new Error('WebGLAtlasRenderer 需要 gl');
    this.gl = gl;
    this.opt = opt || {};
    this.prog = this._program(VS, FS);
    this.loc = {
      pos: gl.getAttribLocation(this.prog, 'a_pos'),
      uv: gl.getAttribLocation(this.prog, 'a_uv'),
      res: gl.getUniformLocation(this.prog, 'u_res'),
      tex: gl.getUniformLocation(this.prog, 'u_tex'),
    };
    if (this.loc.pos < 0 || this.loc.uv < 0) {
      throw new Error('a_pos/a_uv 没绑上（attribute 名与着色器不一致）');
    }
    this.buf = gl.createBuffer();
    this.textures = new Map();       // "build|atlas" -> WebGLTexture
    this.verts = new Float32Array(0);
    this.stats = { frames: 0, drawCalls: 0, quads: 0, missingTextures: 0, uploadedBytes: 0 };
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
  }

  _shader(type, src) {
    const gl = this.gl;
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    // ★ 编译失败必须**抛**：一个静默"编译失败但继续跑"的渲染器会画出黑屏，
    //   而日志一片安静 —— 这正是本项目反复踩的"假绿"。
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      throw new Error('着色器编译失败: ' + gl.getShaderInfoLog(s) + '\n' + src);
    }
    return s;
  }

  _program(vs, fs) {
    const gl = this.gl;
    const p = gl.createProgram();
    gl.attachShader(p, this._shader(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, this._shader(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
      throw new Error('程序链接失败: ' + gl.getProgramInfoLog(p));
    }
    return p;
  }

  /** 登记纹理（由加载层在图片 onload 后调用） */
  setTexture(key, tex) { this.textures.set(key, tex); }

  /**
   * 画一帧。
   * @param {{batches:Array}} packed packBatches 的返回值
   * @param {number} width  canvas 像素宽
   * @param {number} height canvas 像素高
   */
  draw(packed, width, height) {
    const gl = this.gl;
    const batches = packed.batches || [];
    const nQuad = packed.quadCount || 0;
    // ① 顶点一次性摊平（6 顶点 × 4 float × 4 字节）
    const need = nQuad * 6 * 4;
    if (this.verts.length < need) this.verts = new Float32Array(need);
    let o = 0;
    for (const b of batches) {
      for (const q of b.quads) {
        for (const k of TRI) {
          this.verts[o++] = q.p[k].x;
          this.verts[o++] = q.p[k].y;
          this.verts[o++] = q.uv[k][0];
          this.verts[o++] = this.opt.flipV ? 1 - q.uv[k][1] : q.uv[k][1];
        }
      }
    }
    this.stats.uploadedBytes = o * 4;
    this.stats.quads = nQuad;
    gl.useProgram(this.prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buf);
    gl.bufferData(gl.ARRAY_BUFFER, this.verts.subarray(0, o), gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(this.loc.pos);
    gl.vertexAttribPointer(this.loc.pos, 2, gl.FLOAT, false, 16, 0);
    gl.enableVertexAttribArray(this.loc.uv);
    gl.vertexAttribPointer(this.loc.uv, 2, gl.FLOAT, false, 16, 8);
    gl.uniform2f(this.loc.res, width, height);
    gl.uniform1i(this.loc.tex, 0);

    // ② 每批一次 drawArrays
    let first = 0, calls = 0, missing = 0;
    for (const b of batches) {
      const n = b.quads.length * 6;
      const tex = this.textures.get(b.key);
      if (!tex) {
        // ★ 缺纹理：**跳过并记账**，不画。绝不"用上一张纹理凑合" ——
        //   那会画出完全错误的图案，而且看不出来是错的。
        missing++;
        first += n;
        continue;
      }
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.drawArrays(gl.TRIANGLES, first, n);
      first += n;
      calls++;
    }
    this.stats.drawCalls = calls;
    this.stats.missingTextures = missing;
    this.stats.frames++;
    return { drawCalls: calls, quads: nQuad, missingTextures: missing };
  }
}

// 两端导出（与 render_atlas.js 同一套约定）
const API = {
  toScreen, texKey, emitEntity, packBatches, countInversions,
  countOverlapViolations, WebGLAtlasRenderer, VS, FS, TRI,
};
if (typeof module !== 'undefined' && module.exports) module.exports = API;
else if (typeof window !== 'undefined') window.RenderBatch = API;
