// test_client_batch.js —— C2 在**客户端侧**的判据
//
// ════════════════════════════════════════════════════════════════════════════
// tests/test_render_batch.js 证明的是「批路径这个模块本身算得对」。
// 这个文件证明的是另一件事：**客户端真的会用它，而且用得对**。
// 两者必须都有 —— 本工程的老教训是「检查写好了 ≠ 检查生效过」：
// 一个 21 项全绿的模块，完全可能根本没被 client.html 引用。
//
// 判据：
//   G1 没有 WebGL ⇒ 走 Canvas 2D，且**说清原因**（不静默降级）
//   G2 有 WebGL + 图集已加载 ⇒ 走批路径：drawArrays>0、贴回恰好 1 次
//   G3 收益：批路径的 draw call 数**明显少于**四边形数（数字是量出来的）
//   G4 稳定态：fallback = 0（图集加载完后没有实体被迫回退画圆）
//   G5 反向：`?render=canvas` 时即使有 WebGL 也**不许**走批路径
//   G6 反向：`?render=batch` 但没有 WebGL ⇒ 如实说「强制 batch 但不可用」，
//            不许假装成功
//   G7 源码变异：把「贴回 2D 画布」那一行删掉 ⇒ G2 的贴回判据必须红
//   G8 源码变异：flush 里不打包（每格一批）⇒ G3 的收益判据必须红
'use strict';
const fs = require('fs');
const path = require('path');
const LIB = require('../rt/perf_lib.js');

const RT = path.join(__dirname, '..', 'rt');
const ATLAS = path.join(__dirname, '..', '..', '06-引擎复刻', '_out', 'json');
const MUTANTS = [];

let pass = 0, fail = 0;

// ★ 断言条数显式声明（见文件末尾的自校验）
const EXPECT_ITEMS = 8;

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
console.log('  C2 客户端侧：批路径**真的被用上了吗**（模式开关 / 收益 / 贴回 / 变异）');
console.log('═'.repeat(78));

// ---------------------------------------------------------------- 真实图集（2 个小的）
const bb = fs.readdirSync(ATLAS).filter(f => f.endsWith('.json') && !f.startsWith('_'));
// 挑体积最小的两个，测试跑得快
const picked = bb.map(f => ({ f, sz: fs.statSync(path.join(ATLAS, f)).size }))
                 .sort((a, b) => a.sz - b.sz).slice(0, 2).map(x => x.f.replace(/\.json$/, ''));
const ATLAS_JSON = {};
for (const b of picked) ATLAS_JSON[b] = JSON.parse(fs.readFileSync(path.join(ATLAS, b + '.json'), 'utf8'));
const ANIM = {};
for (const b of picked) ANIM[b] = Object.keys(ATLAS_JSON[b].anims || {})[0];

/** 造一帧：所有实体都用同一个 build（保证能拿出四边形），并带上 world 块 */
function frameWith(build, anim, n, t) {
  const ents = [];
  for (let i = 0; i < n; i++) {
    ents.push({ id: 2000 + i, x: ((i * 31) % 60) - 30, z: ((i * 47) % 60) - 30,
                p: 'p' + i, bld: build, a: anim, fr: 0 });
  }
  return { t, tick: Math.round(t * 30), n, ents, iseq: 1,
           player: { id: 2000, x: ents[0].x, z: ents[0].z },
           world: { phase: 'day', season: 'autumn', isday: true, isdusk: false,
                    isnight: false, temperature: 20 } };
}

/** 建客户端并跑几帧；返回 { env, rt, gl, ctx2d, frameDelta } */
function run(opts, frames) {
  const env = LIB.makeClient(opts);
  const rt = env.__rt;
  const build = picked[0], anim = ANIM[picked[0]];
  rt.setPause(false);
  for (let i = 0; i < 2; i++) rt.feed(frameWith(build, anim, 12, i / 30));   // 让图集加载
  // ★ 数「一帧里的 2D drawImage 次数」：批路径每帧只贴回 1 次；
  //   Canvas 路径每个符号 1 次 —— 这两个数字本身就是两条路径的分界。
  const ctx2d = env.__cv && env.__cv._ctx;
  const before = ctx2d ? ctx2d.draws : 0;
  for (let i = 0; i < (frames || 6); i++) {
    rt.feed(frameWith(build, anim, 12, (i + 2) / 30));
    const fn = env.__rafQueue.shift();
    if (fn) fn(env.__perf.now());
  }
  const gl = env.__cv ? env.__cv._gl : null;
  // ★ GL 上下文挂在**离屏画布**上（`SPR` 里 createElement 出来的那个），
  //   不是 `#cv`。第一版去 `__cv._gl` 找 ⇒ 恒 null ⇒ 假红「一次 drawArrays 都没有」。
  const glc = (env.__created || []).filter(c => c && c._gl).pop();
  return { env, rt, gl: glc ? glc._gl : gl, ctx2d,
           drawImageDelta: (ctx2d ? ctx2d.draws : 0) - before,
           frames: frames || 6 };
}

// =============================================================================
check('G1 没有 WebGL ⇒ 走 Canvas 2D，且**说清原因**', () => {
  const r = run({ webgl: false, atlasJson: ATLAS_JSON }, 4);
  const st = r.rt.render();
  if (st.on) return { ok: false, info: '没有 WebGL 却 on=true' };
  if (st.mode !== 'canvas') return { ok: false, info: 'mode=' + st.mode };
  if (!/WebGL/.test(st.why)) return { ok: false, info: 'why 没说明原因: ' + st.why };
  if (r.gl && r.gl.draws().length) return { ok: false, info: '没 WebGL 却调了 drawArrays' };
  return { ok: true, info: 'mode=canvas · why=' + st.why };
});

check('G2 有 WebGL ⇒ 走批路径：drawArrays>0 且贴回恰好 1 次/帧', () => {
  const r = run({ webgl: true, atlasJson: ATLAS_JSON }, 6);
  const st = r.rt.render();
  if (!st.on || st.mode !== 'batch') return { ok: false, info: 'mode=' + st.mode + ' why=' + st.why };
  const draws = r.gl ? r.gl.draws() : [];
  if (!draws.length) return { ok: false, info: 'GL 一次 drawArrays 都没有' };
  if (st.draws < 1) return { ok: false, info: 'st.draws=' + st.draws };
  // 贴回：6 帧 ⇒ 6 次 drawImage（每帧 1 次；地形未加载，不会多）
  if (r.drawImageDelta !== r.frames) {
    return { ok: false, info: '2D drawImage ' + r.drawImageDelta + ' 次 ≠ ' + r.frames
      + ' 帧（批路径必须每帧贴回 1 次）' };
  }
  return { ok: true, info: 'drawArrays ' + draws.length + ' 次 · 贴回 ' + r.drawImageDelta
    + '/' + r.frames + ' 帧 · quads=' + st.quads + ' draws/frame=' + st.draws };
});

check('G3 收益：draw call 数明显少于四边形数（数字是量出来的）', () => {
  const r = run({ webgl: true, atlasJson: ATLAS_JSON }, 6);
  const st = r.rt.render();
  if (!st.quads) return { ok: false, info: 'quads=0，无法判收益' };
  if (!(st.draws < st.quads)) {
    return { ok: false, info: 'draws=' + st.draws + ' 未少于 quads=' + st.quads + ' ⇒ 等于没批' };
  }
  return { ok: true, info: st.quads + ' 个四边形 → ' + st.draws + ' 次 draw call（省 '
    + (100 * (1 - st.draws / st.quads)).toFixed(1) + '%）' };
});

check('G4 稳定态：fallback = 0（没有实体被迫回退画圆）', () => {
  const r = run({ webgl: true, atlasJson: ATLAS_JSON }, 8);
  r.rt.resetPerf();
  r.rt.feed(frameWith(picked[0], ANIM[picked[0]], 12, 0.5));
  const fn = r.env.__rafQueue.shift();
  if (fn) fn(r.env.__perf.now());
  const p = r.rt.perf();
  if (p.fallback !== 0) {
    return { ok: false, info: 'fallback=' + p.fallback + '（图集已加载却仍有实体回退画圆）' };
  }
  if (p.drew < 1) return { ok: false, info: 'drew=' + p.drew + '（一个精灵都没画成）' };
  return { ok: true, info: 'drew=' + p.drew + ' fallback=0 dots=' + p.dots };
});

check('G5 反向：?render=canvas 时即使有 WebGL 也不许走批路径', () => {
  const r = run({ webgl: true, atlasJson: ATLAS_JSON, search: '?render=canvas' }, 4);
  const st = r.rt.render();
  if (st.on || st.mode !== 'canvas') return { ok: false, info: 'mode=' + st.mode + '（应强制 canvas）' };
  if (!/canvas/.test(st.why)) return { ok: false, info: 'why 没说明是模式指定: ' + st.why };
  if (r.gl && r.gl.draws().length) return { ok: false, info: '强制 canvas 却调了 drawArrays' };
  // 而且确实走了 Canvas 路径：每帧多次 drawImage（每个符号一次）
  if (!(r.drawImageDelta > r.frames)) {
    return { ok: false, info: 'drawImage ' + r.drawImageDelta + ' 次，不像 Canvas 路径（每帧多符号）' };
  }
  return { ok: true, info: 'mode=canvas · drawImage ' + r.drawImageDelta + ' 次/' + r.frames + ' 帧' };
});

check('G6 反向：?render=batch 但没有 WebGL ⇒ 如实说"不可用"，不许假装成功', () => {
  const r = run({ webgl: false, atlasJson: ATLAS_JSON, search: '?render=batch' }, 3);
  const st = r.rt.render();
  if (st.on) return { ok: false, info: '没有 WebGL 却 on=true（假装成功）' };
  if (st.mode !== 'canvas') return { ok: false, info: 'mode=' + st.mode };
  if (!/强制 batch/.test(st.why)) {
    return { ok: false, info: 'why 没写清"强制 batch 但不可用": ' + st.why };
  }
  return { ok: true, info: 'why=' + st.why };
});

// =============================================================================
// 源码变异：客户端侧的两条判据也必须**有牙**
// =============================================================================
console.log('');
console.log('  源码变异（改坏 client.html，G2/G3 判据必须变红）');

let SEQ = 0;
function makeMutant(tag, edits) {
  let html = fs.readFileSync(path.join(RT, 'client.html'), 'utf8');
  html = html.replace(/\r\n/g, '\n');
  for (const [oldS, newS] of edits) {
    const n = html.split(oldS).length - 1;
    if (n !== 1) throw new Error('变异锚点命中 ' + n + ' 次（要求 1）：' + oldS.slice(0, 70));
    html = html.replace(oldS, newS);
  }
  const p = path.join(RT, '_mut_client_' + tag + '_' + (++SEQ) + '.html');
  fs.writeFileSync(p, html, 'utf8');
  MUTANTS.push(p);
  return p;
}

const S_BLIT = '        if (r.quads > 0) ctx2d.drawImage(glc, 0, 0);';
const S_PACK = "        const packed = RenderBatch.packBatches(quads, { order: 'strict' });";

check('G7 变异：删掉「贴回 2D 画布」⇒ G2 的贴回判据必须红', () => {
  const p = makeMutant('noblit', [[S_BLIT, '        /* ★ 变异：不贴回 */']]);
  const r = run({ webgl: true, atlasJson: ATLAS_JSON, htmlPath: p }, 4);
  const st = r.rt.render();
  // 前提：批路径仍然在工作（不是整个挂掉）
  if (!st.on) return { ok: false, info: '变异体连批路径都没起来，红的原因不可信: ' + st.why };
  if (st.quads < 1) return { ok: false, info: '变异体没摊出四边形，红的原因不可信' };
  if (r.drawImageDelta === r.frames) {
    return { ok: false, info: '★ 不贴回了，贴回判据居然还是绿的（drawImage ' + r.drawImageDelta + ' 次）' };
  }
  return { ok: true, info: '如预期变红：drawImage ' + r.drawImageDelta + ' 次 ≠ ' + r.frames + ' 帧' };
});

check('G8 变异：flush 里不打包（每格一批）⇒ G3 的收益判据必须红', () => {
  const p = makeMutant('nopack', [[S_PACK,
    '        const packed = { batches: quads.map(q => ({ key: q.key, build: q.build, atlas: q.atlas, quads: [q] })), drawCalls: quads.length, quadCount: quads.length };']]);
  const r = run({ webgl: true, atlasJson: ATLAS_JSON, htmlPath: p }, 4);
  const st = r.rt.render();
  if (!st.quads) return { ok: false, info: '变异体没摊出四边形，红的原因不可信' };
  if (st.draws < st.quads) {
    return { ok: false, info: '★ 每格一批了，收益判据居然还是绿的（draws=' + st.draws
      + ' quads=' + st.quads + '）' };
  }
  return { ok: true, info: '如预期变红：draws=' + st.draws + ' = quads=' + st.quads };
});

// ---------------------------------------------------------------- 清理
let leftover = 0;
for (const p of MUTANTS) {
  try { fs.unlinkSync(p); } catch (e) { /* ignore */ }
  if (fs.existsSync(p)) leftover++;
}

console.log('');
console.log('═'.repeat(78));
console.log('  结果：通过 ' + pass + ' · 失败 ' + fail
  + '（变异体建了 ' + MUTANTS.length + ' 个，残留 ' + leftover + ' 个）');
console.log('═'.repeat(78));

// ★ 断言条数显式声明 + 自校验（与 test_render_batch.js 同一约定：
//   静态数 `check(` 只能数调用行，循环/条件里一次调用可能跑出多条断言；
//   两种口径并存会各自过期。所以以声明值为唯一来源，由测试自己守）。
if (pass + fail !== EXPECT_ITEMS) {
  console.log('  ✘ 断言条数与声明不符：声明 ' + EXPECT_ITEMS + ' 条，实跑 ' + (pass + fail)
    + ' 条（增删断言后请同步本文件的 EXPECT_ITEMS）');
  process.exit(1);
}
process.exit(fail || leftover ? 1 : 0);
