// perf_client.js —— **无浏览器**测量客户端的真实绘制帧率（Node）
//
// 为什么要有它：P2 判据里有「>=55 fps」。在浏览器里真测要装 playwright + 下载浏览器
// （几百 MB、还要网络）；而帧率主要取决于客户端每帧的绘制工作量，那部分可以搬到
// Node 里直接跑（canvas 桩化 + rAF 手动推进）。
//   桩比真 GPU 快 => 测出的是**乐观下界**，真浏览器只会更慢。
//   判据：乐观值 >=55 => 达标；乐观值 <55 => **逻辑本身**太重，与浏览器无关。
//   最终目视确认仍留给人工。
// 实现细节见 rt/perf_lib.js。
// 用法：node rt/perf_client.js [实体数...]

'use strict';
const { measure } = require('./perf_lib.js');

function pad(s, w) { s = String(s); while (s.length < w) s = ' ' + s; return s; }
function num(v, w) { return pad(v.toFixed(3), w); }

// ---------------------------------------------------------------- main
const argv = process.argv.slice(2).map(Number).filter((x) => x > 0);
const list = argv.length ? argv : [6, 50, 400];
console.log('客户端绘制帧率（Node 桩化 canvas；**乐观下界**，真浏览器只会更慢）');
console.log('  实体数   帧数    avg(ms)    p50(ms)    p95(ms)    p99(ms)     fps(avg)  判据>=55');
console.log('  ' + '-'.repeat(84));
let worst = Infinity;
for (const n of list) {
  const r = measure(n);
  const fps = 1000 / r.avg;
  worst = Math.min(worst, fps);
  console.log('  ' + pad(r.n, 6) + pad(r.frames, 7) + num(r.avg, 11) + num(r.p50, 11)
              + num(r.p95, 11) + num(r.p99, 11) + pad(fps.toFixed(1), 13)
              + (fps >= 55 ? '  ✔' : '  ✘ 逻辑本身太重'));
}
console.log('\n  结论：' + (worst >= 55
  ? '所有规模的乐观帧率都 >=55 fps => 绘制逻辑不是瓶颈 ✔'
  : '有规模低于 55 fps => 需要优化绘制逻辑（与浏览器无关）✘'));
process.exit(worst >= 55 ? 0 : 1);
