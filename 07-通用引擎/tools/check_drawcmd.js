// check_drawcmd.js —— 离线渲染器与实时渲染器**共用同一份绘制指令**的验证（2.4）
//
// 背景（都是本轮实测出来的事实）
//   06 离线侧：render.lua → AnimState:GetDrawList() → 文本 BUNDLE/SUBJECT/FRAME/QUAD
//              → tools/export_drawcmd.py 转成 DrawCmd JSON
//   07 实时侧：rt/render_atlas.js 直接读**同一份** _out/json/<build>.json，
//              自己算 animFrame + uvRect + applyMat
//   两边数据同源，但指令格式不同 ⇒「画得一样」此前只能靠人相信。
//
// 这个脚本做的事
//   对每个 BUNDLE，在 build JSON 里**找出哪个动画的哪一帧**能解释离线的 QUAD 序列
//   （符号名序列 + 符号帧号逐项相同），然后逐符号**逐顶点**比对：
//     · 顶点 (x, y)  —— 不一致意味着**摆的位置/几何不同**
//     · 顶点 (u, v)  —— 不一致意味着**采到的不是同一块纹理**
//     · 仿射矩阵 mat —— 不一致意味着**整体位移/缩放不同**
//   全部一致 ⇒ 离线渲染器与实时渲染器确实在消费同一份绘制指令。
//
// ⚠️ 这条判据**证明什么、不证明什么**（别读过头）：
//   ✔ 证明：给定同一个动画帧，两侧算出的**几何/UV/矩阵完全一致**（数据同源）。
//   ✘ 不证明：「离线播的是 idle、实时也播 idle」—— 判据只要求**存在某个帧**能复现
//        这段 QUAD（不同动画可能共用同一批符号帧，例如 `rabbit` 与 `idle` 的某帧）。
//        动画选择本身由别的东西守（06 侧是 `render.lua` 的 `pick_anim`，
//        07 侧是 `render_atlas.js` 的帧推进），不在这条判据的射程内。
//
// 用法
//   node tools/check_drawcmd.js [--drawcmd <path>] [--json <dir>]
// 退出码：0 全一致 / 1 有差异 / 2 输入缺失
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const DEF_DRAWCMD = path.join(ROOT, '..', '06-引擎复刻', '_out', 'drawcmd.json');
const DEF_JSON = path.join(ROOT, '..', '06-引擎复刻', '_out', 'json');

// 容差按**数据精度**定，不按文本精度定（这条被踩过两次，写死在常量里）
//   · 离线 drawlist：render.lua 用 "%.4f" 打 xy、"%.6f" 打 uv、"%.5f" 打矩阵
//   · build JSON：xy 存 3 位小数（-62.003）、uv 存 4 位（0.3965）、矩阵存 1 位（-139.1）
//   ⇒ 舍入本身就能产生 5e-4(xy) / 5e-5(uv) / 5e-2(mat) 的差；
//     实测两侧最大差 xy+uv = 4.7e-5、mat ≈ 3e-5。阈值取"数据精度"的上界。
const TOL_XY = 1e-3;
const TOL_UV = 1e-4;
const TOL_MAT = 6e-2;      // 矩阵只存 1 位小数 ⇒ 半个末位 0.05，留一点余量

function arg(flag, dflt) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

/** 比对单个候选帧：返回 {ok, score, maxDUV, maxDXY, maxDMat, badSym}
 *
 * ★★★ 这个函数换过三版判据，每版都是"判据自己错"，记下来免得第四次重踩：
 *   ① v1 拿 `uvRect(symbol.verts)` 跟 QUAD 的 uv 比 —— **量错对象**。
 *   ② v2 以为 QUAD 只是"其中一组 6 个顶点"，于是在 symbol 帧顶点里按 `g += 6`
 *      找最接近的一组 —— **前提就错的**：render.lua 一个 QUAD 行 = 一个符号的
 *      **一整帧**顶点（实测 pig_torso 帧 2 = 126 个顶点、NF=515 = 4+126*4+7）。
 *      按 6 个切永远找不到，于是报"最接近的组误差 17744"这种天文数字 ——
 *      看着像两侧不一致，其实是判据在拿"整帧"跟"六分之一个四边形"比。
 *   ③ v3（本版）：两边都是**整帧顶点表**，直接逐项比。前提由
 *      `06/tools/export_drawcmd.py` 的解析保证（头 4 字段 + nv*4 顶点 + 尾 7 矩阵）。
 *   另有两条通用教训一并固化在这里：
 *     · 不能"第一个符号序列匹配的动画就收"—— 不同动画可能符号序列完全相同
 *       （`ta` 与 `idle_loop` 某帧都是这 10 个符号）但 UV 不同 ⇒ 收全部候选取最优。
 *     · 容差必须按**数据精度**定，不能按文本精度定（见文件头 TOL_*）。
 */
function compareOne(data, cand, bundle) {
  let maxDUV = 0, maxDXY = 0, maxDMat = 0, badSym = null;
  for (let i = 0; i < cand.entries.length; i++) {
    const e = cand.entries[i], q = bundle.quads[i];
    const sym = data.symbols[e.sym];
    const sf = sym && sym.frames ? sym.frames[String(e.frame)] : null;
    if (!sf || !sf.verts) { badSym = q.sym + '(符号帧缺失)'; break; }

    // 顶点数必须先相等 —— 不等说明两边根本不是同一帧，继续比数字没意义
    if (sf.verts.length !== q.verts.length) {
      badSym = q.sym + '(顶点数不同：实时 ' + sf.verts.length
             + ' vs 离线 ' + q.verts.length + ')';
      break;
    }
    for (let k = 0; k < sf.verts.length; k++) {
      const a = sf.verts[k], b2 = q.verts[k];
      const dxy = Math.max(Math.abs(a[0] - b2[0]), Math.abs(a[1] - b2[1]));
      const duv = Math.max(Math.abs(a[2] - b2[2]), Math.abs(a[3] - b2[3]));
      if (dxy > maxDXY) maxDXY = dxy;
      if (duv > maxDUV) maxDUV = duv;
      if (dxy > TOL_XY || duv > TOL_UV) {
        badSym = q.sym + ' 顶点#' + k + ' 超差（xy ' + dxy.toExponential(2)
               + ' / uv ' + duv.toExponential(2) + '）';
        break;
      }
    }
    if (badSym) break;

    // 矩阵 7 个分量：[a b c d tx ty tz]（离线 %.5f / JSON 1 位小数）
    const em = e.mat, qm = q.mat;
    if (!em || !qm || em.length < 7 || qm.length < 7) {
      badSym = q.sym + '(mat 缺失：实时 ' + (em ? em.length : 0)
             + ' / 离线 ' + (qm ? qm.length : 0) + ')';
      break;
    }
    for (let k = 0; k < 7; k++) {
      const d = Math.abs(qm[k] - em[k]);
      if (d > maxDMat) maxDMat = d;
      if (d > TOL_MAT) { badSym = q.sym + ' mat[' + k + '] 超差 ' + d.toExponential(2); break; }
    }
    if (badSym) break;
  }
  const ok = !badSym;
  return { ok, score: maxDUV * 1e4 + maxDXY * 1e2 + maxDMat,
           maxDUV, maxDXY, maxDMat, badSym };
}

function main() {
  const drawcmdPath = arg('--drawcmd', DEF_DRAWCMD);
  const jsonDir = arg('--json', DEF_JSON);
  if (!fs.existsSync(drawcmdPath)) {
    console.log('✘ 找不到 ' + drawcmdPath + '\n  处置：先跑 06 的 tools/export_drawcmd.py');
    return 2;
  }
  const lines = fs.readFileSync(drawcmdPath, 'utf8').split(/\r?\n/).filter(s => s.trim());
  if (!lines.length) { console.log('✘ drawcmd.json 是空的'); return 2; }

  let pass = 0, fail = 0, skipped = 0;
  const failed = [];

  console.log('='.repeat(78));
  console.log('  DrawCmd 一致性：离线(06 render.lua) vs 实时(07 render_atlas.js)');
  console.log('='.repeat(78));

  for (const line of lines) {
    const b = JSON.parse(line);
    const jf = path.join(jsonDir, b.build + '.json');
    if (!fs.existsSync(jf)) {
      console.log('  - ' + b.build + '  跳过：缺 ' + path.basename(jf));
      skipped++;
      continue;
    }
    const data = JSON.parse(fs.readFileSync(jf, 'utf8'));
    if (!b.quads || b.quads.length === 0) {
      console.log('  - ' + b.build + '  跳过：离线侧 0 个 QUAD（该帧没有可见符号）');
      skipped++;
      continue;
    }

    // 符号 id → 名字（anims 存 id，QUAD 存名字）
    const nameById = {};
    for (const id of Object.keys(data.symbols || {})) {
      nameById[id] = data.symbols[id].name;
    }

    // 找「能解释这段 QUAD」的动画帧
    const hits = [], why = [];
    for (const an of Object.keys(data.anims || {})) {
      const frames = data.anims[an].frames || [];
      for (let fi = 0; fi < frames.length; fi++) {
        // ★ 动画帧里的符号**不全有名字**：build 没有的占位符号（"swap_*" 之类）
        //   nameById 取不到 ⇒ 离线侧本来就不会画它（GetDrawList 跳过）。
        //   第一版没滤这一层，于是 10 个 QUAD 对 22 个符号，**永远匹配不上**，
        //   判据必然红 —— 而红的原因是判据自己写错了，不是两侧指令不一致。
        const fr = frames[fi].filter(e => nameById[e.sym] !== undefined);
        if (fr.length !== b.quads.length) continue;
        let ok = true;
        for (let i = 0; i < fr.length; i++) {
          if (nameById[fr[i].sym] !== b.quads[i].sym || fr[i].frame !== b.quads[i].sf) {
            ok = false; break;
          }
        }
        // ★★ 不能「第一个匹配就收」：不同动画可能**符号序列完全相同**
        //   （例如 `ta` 与 `idle_loop` 某一帧都是这 10 个符号），但 UV/矩阵不同 ——
        //   第一版取第一个，于是拿去比的是**错的动画**，报出「UV 差 177」，
        //   看起来像两侧不一致，其实是判据选错了比对对象。
        //   ⇒ 收集全部候选，只要**存在一个**完全一致的就算通过。
        if (ok) hits.push({ anim: an, frame: fi, entries: fr });
      }
      why.push(an + '(' + (data.anims[an].frames || []).length + ' 帧)');
    }
    if (hits.length === 0) {
      fail++; failed.push(b.build);
      console.log('  X ' + b.build + '  没有任何动画帧能解释这 ' + b.quads.length
        + ' 个 QUAD（符号名/帧号序列对不上）；试过：' + why.slice(0, 4).join(' '));
      continue;
    }

    // 逐候选比顶点 + 矩阵，取最好的那个
    let best = null;
    for (const cand of hits) {
      const diff = compareOne(data, cand, b);
      if (best === null || diff.score < best.score) {
        best = Object.assign({ anim: cand.anim, frame: cand.frame }, diff);
      }
      if (diff.ok) break;                       // 已有一个完全一致，无需再试
    }

    if (!best.ok) {
      fail++; failed.push(b.build);
      console.log('  X ' + b.build + '  anim=' + best.anim + ' frame=' + best.frame
        + '  xy 最大差=' + best.maxDXY.toExponential(2) + '（阈值 ' + TOL_XY + '）'
        + '  uv 最大差=' + best.maxDUV.toExponential(2) + '（阈值 ' + TOL_UV + '）'
        + '  mat 最大差=' + best.maxDMat.toExponential(2) + '（阈值 ' + TOL_MAT + '）');
      console.log('      首个问题：' + best.badSym);
      console.log('      候选 ' + hits.length + ' 个动画帧，已取误差最小的一个');
      continue;
    }
    pass++;
    console.log('  OK ' + b.build.padEnd(14) + ' anim=' + best.anim.padEnd(12)
      + ' frame=' + best.frame + '  符号 ' + b.quads.length + ' 个全部一致'
      + '  xy ' + best.maxDXY.toExponential(1) + '  uv ' + best.maxDUV.toExponential(1)
      + '  mat ' + best.maxDMat.toExponential(1));
  }

  console.log('');
  console.log('  一致 ' + pass + ' · 不一致 ' + fail + ' · 跳过 ' + skipped);
  if (fail > 0) {
    console.log('  X 有 ' + fail + ' 个 build 的两侧绘制指令不一致（' + failed.join(', ') + '）');
    console.log('  影响：离线出图与实时画面**不是同一份指令**，"看起来一样"没有依据');
    return 1;
  }
  if (pass === 0) {
    // ★ 空判据保护：一个都没比到也算失败 —— 否则「全一致」是假的
    console.log('  X 一个 build 都没比到（全被跳过）—— 这条判据是空的');
    return 1;
  }
  console.log('  OK 离线与实时消费同一份绘制指令（顶点 xy/uv 与矩阵逐符号一致）');
  return 0;
}

process.exit(main());
