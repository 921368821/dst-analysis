// render_atlas.js —— 真实图集精灵渲染（P4）
//
// 数据来源（由服务端 /atlas/ 路由提供）：
//   /atlas/json/<build>.json            —— { buildName, atlas:{file,w,h}, atlases:[…],
//                                            symbols:{id:{name,atlas,frames:{n:{verts,bbox}}}},
//                                            anims:{name:{rate,frames:[[{sym,frame,mat},…],…]}}} }
//   /atlas/anim_data/<build>__atlas-N.png —— 真实贴图
//
// 渲染一个实体 = 取 anims[anim].frames[frameIdx] 里的每个符号，按它的
//   verts（6 个顶点 = 2 个三角形，每点 [x, y, u, v]）求出 UV 矩形与本地四边形，
//   再用 mat（[a,b,c,d,tx,ty,z] 仿射）摆到世界上。
//
// ★ 这个文件刻意写成**不碰 DOM 的纯函数 + 一个薄的适配层**：
//   纯函数部分（uvRect / localQuad / applyMat）可以在 Node 里直接单测，
//   不需要浏览器。视觉确认仍留给人工（P4 待办里如实标注）。
'use strict';

// ---------------------------------------------------------------- 纯函数（可单测）
/** 从 6 个顶点求 UV 矩形（归一化 → 乘图集尺寸得像素矩形） */
function uvRect(verts, atlasW, atlasH) {
  let u0 = 1, v0 = 1, u1 = 0, v1 = 0;
  for (const v of verts) {
    if (v[2] < u0) u0 = v[2];
    if (v[2] > u1) u1 = v[2];
    if (v[3] < v0) v0 = v[3];
    if (v[3] > v1) v1 = v[3];
  }
  return { x: u0 * atlasW, y: v0 * atlasH, w: (u1 - u0) * atlasW, h: (v1 - v0) * atlasH,
           u0, v0, u1, v1 };
}

/** 从 6 个顶点求本地四边形（精灵空间，原点在精灵中心） */
function localQuad(verts) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const v of verts) {
    if (v[0] < x0) x0 = v[0];
    if (v[0] > x1) x1 = v[0];
    if (v[1] < y0) y0 = v[1];
    if (v[1] > y1) y1 = v[1];
  }
  return { x0, y0, x1, y1, w: x1 - x0, h: y1 - y0 };
}

/** 2x3 仿射作用于一点：mat = [a,b,c,d,tx,ty,z] */
function applyMat(mat, x, y) {
  if (!mat || mat.length < 6) return { x, y };
  return { x: mat[0] * x + mat[2] * y + mat[4],
           y: mat[1] * x + mat[3] * y + mat[5] };
}

/** 取某一帧的符号表；帧号越界时**夹到最近一帧**（原版动画循环） */
function animFrame(buildData, animName, frameIdx) {
  const anims = buildData && buildData.anims;
  if (!anims) return null;
  const a = anims[animName];
  if (!a || !a.frames || a.frames.length === 0) return null;
  let i = Math.floor(frameIdx || 0);
  if (i < 0) i = 0;
  if (i >= a.frames.length) i = i % a.frames.length;   // 循环
  return a.frames[i];
}

// ---------------------------------------------------------------- 浏览器侧
class AtlasRenderer {
  /**
   * @param {string} baseUrl 图集基址（如 "/atlas"）
   * @param {CanvasRenderingContext2D} ctx
   */
  constructor(baseUrl, ctx) {
    this.base = baseUrl;
    this.ctx = ctx;
    this.builds = {};        // build -> { json, images: [Image], w, h, loading, failed }
    // ★★ 跨 build **共享符号表**：实测全库有 14.9% 的符号引用指向**别的** build
    //   （例如 beefalo 的 anim 引用 swap_saddle，而它在 saddle_basic.json 里）。
    //   不共享的后果：缺符号就整块不画 —— 而缺的往往只是配件，主角身子应该照画。
    this.symIndex = {};      // symId -> { build, sym }
    this.missing = {};       // symId -> 次数（**记账，不静默**）
    this.stats = { requested: 0, loaded: 0, failed: 0, symbolsDrawn: 0,
                   entsDrawn: 0, missingSymbols: 0 };
  }

  /** 把一个 build 的符号并进共享表（后加载的不覆盖先加载的同名项） */
  _indexBuild(build, json) {
    for (const id of Object.keys(json.symbols || {})) {
      if (!this.symIndex[id]) this.symIndex[id] = { build, sym: json.symbols[id] };
    }
  }

  /** 取符号：先本 build，再共享表；都找不到就记账并返回 null */
  _sym(rec, id) {
    if (rec.json.symbols && rec.json.symbols[id]) return rec.json.symbols[id];
    const hit = this.symIndex[id];
    if (hit && hit.build !== undefined && this.builds[hit.build]) return hit.sym;
    this.missing[id] = (this.missing[id] || 0) + 1;
    this.stats.missingSymbols++;
    return null;
  }

  /** 触发加载（不等待）；重复调用同一个 build 只会触发一次 */
  ensure(build) {
    if (!build || this.builds[build]) return;
    const rec = { json: null, images: [], w: 0, h: 0, loading: true, failed: false };
    this.builds[build] = rec;
    this.stats.requested++;
    const jx = new XMLHttpRequest();
    jx.open('GET', this.base + '/json/' + encodeURIComponent(build) + '.json', true);
    jx.onload = () => {
      try {
        rec.json = JSON.parse(jx.responseText);
        this._indexBuild(build, rec.json);      // ★ 并入共享符号表
        const at = rec.json.atlas || (rec.json.atlases && rec.json.atlases[0]) || {};
        rec.w = at.w || 1024; rec.h = at.h || 1024;
        const n = (rec.json.atlases || []).length || 1;
        let left = n;
        if (left === 0) { rec.loading = false; this.stats.loaded++; return; }
        for (let i = 0; i < n; i++) {
          const img = new Image();
          img.onload = () => { if (--left === 0) { rec.loading = false; this.stats.loaded++; } };
          img.onerror = () => { rec.failed = true; if (--left === 0) { rec.loading = false; this.stats.failed++; } };
          img.src = this.base + '/anim_data/' + encodeURIComponent(build) + '__atlas-' + i + '.png';
          rec.images[i] = img;
        }
      } catch (e) {
        rec.failed = true; rec.loading = false; this.stats.failed++;
      }
    };
    jx.onerror = () => { rec.failed = true; rec.loading = false; this.stats.failed++; };
    jx.send();
  }

  /** 画一个实体；返回 true 表示真的画了精灵，false 表示回退（调用方画圆） */
  drawEntity(ent, sx, sy, scale) {
    const b = ent.bld;
    if (!b) return false;
    const rec = this.builds[b];
    if (!rec || rec.loading || rec.failed || !rec.json) return false;
    const frame = animFrame(rec.json, ent.a || 'idle_loop', ent.fr || 0);
    if (!frame) return false;
    const ctx = this.ctx;
    let drew = 0;
    for (const item of frame) {
      const sym = this._sym(rec, item.sym);   // ★ 跨 build 共享符号表
      if (!sym) continue;
      const fr = sym.frames[String(item.frame != null ? item.frame : 0)] ||
                 sym.frames[Object.keys(sym.frames)[0]];
      if (!fr || !fr.verts) continue;
      const img = rec.images[sym.atlas || 0];
      if (!img || !img.complete || img.naturalWidth === 0) continue;
      const uv = uvRect(fr.verts, rec.w, rec.h);
      const q = localQuad(fr.verts);
      if (uv.w <= 0 || uv.h <= 0 || q.w <= 0 || q.h <= 0) continue;
      const m = item.mat || [1, 0, 0, 1, 0, 0];
      ctx.save();
      // 世界 → 屏幕：再叠上相机缩放与 Y 翻转（DST 的 z 朝上，canvas 的 y 朝下）
      ctx.translate(sx, sy);
      ctx.scale(scale, -scale);
      ctx.transform(m[0], m[1], m[2], m[3], m[4], m[5]);
      ctx.drawImage(img, uv.x, uv.y, uv.w, uv.h, q.x0, q.y0, q.w, q.h);
      ctx.restore();
      drew++;
    }
    if (drew > 0) { this.stats.symbolsDrawn += drew; this.stats.entsDrawn++; }
    return drew > 0;
  }
}

// 两端导出：浏览器挂 window，Node 走 module.exports
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { uvRect, localQuad, applyMat, animFrame, AtlasRenderer };
} else if (typeof window !== 'undefined') {
  window.RenderAtlas = { uvRect, localQuad, applyMat, animFrame, AtlasRenderer };
}
