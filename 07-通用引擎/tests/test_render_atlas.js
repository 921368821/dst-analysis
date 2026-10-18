// test_render_atlas.js —— 用**真实图集数据**验算精灵渲染的纯函数（P4）
//
// 为什么能测：render_atlas.js 的取图数学（uvRect/localQuad/applyMat/animFrame）
// 是**不碰 DOM 的纯函数**，所以可以在 Node 里拿真图集 JSON 直接验。
// 真正把像素画到屏幕上仍需浏览器（P4 待办已如实标注）。
'use strict';
const fs = require('fs');
const path = require('path');
const R = require('../rt/render_atlas.js');

const ATLAS = path.join(__dirname, '..', '..', '06-引擎复刻', '_out', 'json');
let pass = 0, fail = 0;
function check(name, fn) {
  try {
    const r = fn();
    if (r === true || (r && r.ok !== false)) { pass++; console.log('  ✔ ' + name + (r && r.info ? '  ' + r.info : '')); }
    else { fail++; console.log('  ✘ ' + name + (r && r.info ? '  ' + r.info : '')); }
  } catch (e) { fail++; console.log('  ✘ ' + name + '  抛异常: ' + e.message + '\n' + (e.stack||'').split('\n').slice(1,3).join('\n')); }
}

console.log('═'.repeat(74));
console.log('  精灵渲染纯函数（真实图集数据）');
console.log('═'.repeat(74));

// 挑几个有代表性的 build
const builds = fs.readdirSync(ATLAS).filter(f => f.endsWith('.json'))
  .filter(f => !f.startsWith('_')).slice(0, 6);
console.log('  受测 build：' + builds.join(', '));

check('读得到图集 JSON 且结构齐', () => {
  const miss = [];
  for (const f of builds) {
    const d = JSON.parse(fs.readFileSync(path.join(ATLAS, f), 'utf8'));
    if (!d.anims || !d.symbols) miss.push(f);
  }
  return miss.length ? { ok: false, info: '缺 anims/symbols: ' + miss.join(',') } : { ok: true };
});

check('每个 anim 帧的每个符号都能算出合法 UV 矩形与本地四边形', () => {
  let frames = 0, syms = 0, bad = [], softGap = 0, softBuilds = {}, frameFallback = 0;
  for (const f of builds) {
    const d = JSON.parse(fs.readFileSync(path.join(ATLAS, f), 'utf8'));
    const W = (d.atlas && d.atlas.w) || 2048, H = (d.atlas && d.atlas.h) || 1024;
    for (const an of Object.keys(d.anims)) {
      const fr = d.anims[an].frames;
      if (!fr || !fr.length) continue;
      for (let i = 0; i < Math.min(fr.length, 3); i++) {
        frames++;
        for (const item of fr[i]) {
          syms++;
          const sym = d.symbols[item.sym];
          if (!sym) {
            // ★ 软缺口：该符号在**别的 build** 文件里（实测全库 14.9% 的引用如此，
            //   例如 beefalo 的 anim 引用 saddle_basic.json 的 swap_saddle）。
            //   ⇒ 不计入失败，但要记账并在汇总里说出来（不静默）。
            softGap++;
            softBuilds[f] = (softBuilds[f] || 0) + 1;
            continue;
          }
          // ★ 与渲染器**同一套取帧逻辑**（含「取不到就用第一帧」的兜底）：
          //   实测有符号存在但**没有动画引用的那一帧**，渲染器靠兜底仍然画得出，
          //   所以测试必须照这个行为验，否则会把「兜底生效」误判成失败。
          let sf = sym.frames[String(item.frame != null ? item.frame : 0)];
          if (!sf) { sf = sym.frames[Object.keys(sym.frames)[0]]; frameFallback++; }
          if (!sf || !sf.verts) { bad.push(f + ':' + an + ' 连兜底帧都没有'); continue; }
          const uv = R.uvRect(sf.verts, W, H);
          const q = R.localQuad(sf.verts);
          if (!(uv.u0 >= 0 && uv.u1 <= 1.0001 && uv.v0 >= 0 && uv.v1 <= 1.0001))
            bad.push(f + ':' + an + ' UV 越界 ' + JSON.stringify([uv.u0, uv.v0, uv.u1, uv.v1]));
          if (uv.w <= 0 || uv.h <= 0) bad.push(f + ':' + an + ' UV 矩形退化');
          if (q.w <= 0 || q.h <= 0) bad.push(f + ':' + an + ' 四边形退化');
          if (!isFinite(q.x0) || !isFinite(q.y1)) bad.push(f + ':' + an + ' 四边形非有限');
        }
      }
    }
  }
  if (bad.length) return { ok: false, info: bad.slice(0, 3).join('；') };
  let gapInfo = softGap > 0
    ? '；跨 build 软缺口 ' + softGap + ' 次（' + Object.keys(softBuilds).length + ' 个 build）'
    : '；无跨 build 缺口';
  if (frameFallback > 0) gapInfo += '；帧号兜底 ' + frameFallback + ' 次';
  return { ok: true,
           info: '验了 ' + frames + ' 帧 / ' + syms + ' 个符号引用，全部合法' + gapInfo };
});

check('applyMat 仿射正确（含平移）', () => {
  const p = R.applyMat([2, 0, 0, 2, 10, -5], 3, 4);
  if (Math.abs(p.x - 16) > 1e-9 || Math.abs(p.y - 3) > 1e-9)
    return { ok: false, info: '得 ' + JSON.stringify(p) };
  const q = R.applyMat(null, 7, 8);            // 无矩阵 ⇒ 原样
  return (q.x === 7 && q.y === 8) ? { ok: true } : { ok: false, info: 'null 矩阵未原样' };
});

check('animFrame 取帧与越界处理', () => {
  const d = JSON.parse(fs.readFileSync(path.join(ATLAS, builds[0]), 'utf8'));
  const an = Object.keys(d.anims)[0];
  const n = d.anims[an].frames.length;
  const f0 = R.animFrame(d, an, 0);
  const fLast = R.animFrame(d, an, n - 1);
  const fOver = R.animFrame(d, an, n + 5);      // 越界 ⇒ 循环
  if (!f0 || !fLast) return { ok: false, info: '取不到帧' };
  if (!fOver) return { ok: false, info: '越界帧返回 null（应循环）' };
  if (fOver !== fLast) return { ok: false, info: '越界未循环到末帧' };
  const fNeg = R.animFrame(d, an, -3);
  if (fNeg !== f0) return { ok: false, info: '负帧号未夹到 0' };
  return { ok: true, info: an + ' 共 ' + n + ' 帧，越界循环/负号夹取均正确' };
});

check('反向：坏输入必须返回 null 而不是抛错', () => {
  const d = JSON.parse(fs.readFileSync(path.join(ATLAS, builds[0]), 'utf8'));
  const an = Object.keys(d.anims)[0];
  const bad = [
    ['不存在的 anim', R.animFrame(d, 'no_such_anim', 0)],
    ['空 buildData', R.animFrame(null, an, 0)],
    ['空 anims', R.animFrame({}, an, 0)],
  ];
  const notNull = bad.filter(b => b[1] !== null);
  return notNull.length ? { ok: false, info: notNull.map(b => b[0]).join(',') + ' 竟非 null' }
                        : { ok: true };
});

check('反向：UV 矩形对空/坏顶点不炸', () => {
  const r = R.uvRect([], 100, 100);
  if (!(r.w <= 0 && r.h <= 0)) return { ok: false, info: '空顶点应得退化矩形' };
  const q = R.localQuad([]);
  return (q.w <= 0 && q.h <= 0) ? { ok: true } : { ok: false, info: '空顶点四边形应退化' };
});

console.log('\n  结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
