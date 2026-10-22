// test_client.js —— 客户端侧验证（Node，无浏览器）
//
// 三项检查：
//   1) JS 语法合法（node --check 的等价物：真的编译一次）
//   2) 测试钩子 __rt 存在且可用（feed/frame/keys/cam/send/fps）
//   3) 绘制帧率达标：6 / 50 / 400 实体规模的**乐观下界**都 >= 55 fps
//      （真浏览器只会更慢；判据写法见 perf_client.js 顶部说明）
//
// 退出码：0 = 全过；1 = 有失败
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');

let pass = 0, fail = 0;
// ★★ B2：判据可以是 async（合成面板要等 fetch 的 promise 链才有结果）。
//   同步判据照旧立即执行并立即打印；async 判据进 PENDING，收尾统一 await 后再汇总。
//   不这么做的话，异步判据只能"发起请求就断言"，那就永远只能验到"点了一下"，
//   验不到"列表真的渲染成了 3 行"。
const PENDING = [];
function _report(name, ok) {
  if (ok === true || (ok && ok.ok !== false)) { pass++; console.log('  ✔ ' + name + (ok && ok.info ? '  ' + ok.info : '')); }
  else { fail++; console.log('  ✘ ' + name + (ok && ok.info ? '  ' + ok.info : '')); }
}
function check(name, fn) {
  try {
    const r = fn();
    if (r && typeof r.then === 'function') {
      PENDING.push(r.then((v) => _report(name, v))
                    .catch((e) => _report(name, { ok: false, info: '抛异常: ' + e.message })));
      return;
    }
    _report(name, r);
  } catch (e) {
    _report(name, { ok: false, info: '抛异常: ' + e.message });
  }
}
// 等 N 轮微任务 + 宏任务：fetch 桩是 Promise.resolve，客户端里还有 .then 套一层
const tick = (n) => new Promise((res) => {
  let i = 0;
  const step = () => { if (++i >= (n || 3)) return res(); setImmediate(step); };
  setImmediate(step);
});

console.log('═'.repeat(74));
console.log('  客户端验证（Node 桩化 canvas / 无浏览器）');
console.log('═'.repeat(74));

// ---------------------------------------------------------------- 1) 语法
check('F1 client.html 的内联 JS 能编译', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'rt', 'client.html'), 'utf8');
  const js = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  new vm.Script(js, { filename: 'client.html<script>' });
  return { ok: true, info: '(' + js.length + ' 字符)' };
});

// ---------------------------------------------------------------- 2) 钩子
check('F2 测试钩子 __rt 存在且字段齐', () => {
  const mod = require('../rt/perf_lib.js');
  const rt = mod.makeClient().__rt;
  const need = ['feed', 'frame', 'prev', 'keys', 'cam', 'send', 'fps', 'connected',
                'world', 'dark', 'paused', 'setPause', 'terrain', 'terrainDraws',
                'setTerrain', 'perf', 'resetPerf',
                // P20/P5：多人「我是谁」+ 预测 + 延迟
                'me', 'myScreen', 'pred', 'resetPred', 'moveSpeed', 'selfMissing',
                'rtt', 'rttState', 'pingNow', 'whoTick',
                // P22：交互
                'act', 'setTargets', 'actKey', 'actTick', 'pickAt', 'clearPick',
                // P23：触屏 / 指针
                'pad', 'setPad', 'pt', 'padHit',
                // P39：自身状态（血/饿/理智/背包）
                'state', 'stateText',
                // B2：合成面板
                'craft'];
  // ★ B2：`craft` 是**对象**（toggle/refresh/click/state 四个入口）不是函数 ——
  //   一刀切按 `typeof === 'function'` 判会把它误报成「缺」。
  const miss = need.filter((k) => {
    if (k === 'craft') {
      return !(rt.craft && typeof rt.craft.toggle === 'function'
               && typeof rt.craft.click === 'function'
               && typeof rt.craft.state === 'function');
    }
    return typeof rt[k] !== 'function';
  });
  return miss.length ? { ok: false, info: '缺: ' + miss.join(',') }
                     : { ok: true, info: '(' + need.length + ' 个)' };
});

// ---------------------------------------------------------------- 3) 帧率
check('F3 绘制帧率达标（6/50/400 实体，乐观下界 >= 55 fps）', () => {
  const mod = require('../rt/perf_lib.js');
  const rows = [];
  let worst = Infinity;
  for (const n of [6, 50, 400]) {
    const r = mod.measure(n, 400);
    const fps = 1000 / r.avg;
    worst = Math.min(worst, fps);
    rows.push(n + ':' + fps.toFixed(0) + 'fps');
  }
  return worst >= 55 ? { ok: true, info: rows.join('  ') }
                     : { ok: false, info: '最低 ' + worst.toFixed(1) + ' fps（' + rows.join(' ') + '）' };
});

// ---------------------------------------------------------------- 4) 输入钩子真的发得出去
check('F4 输入钩子 key() 与事件处理器同路径（按下/松开都生效）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  // 连按两次同样的键：第二次**不该**再发帧（防重复守卫）
  env.__rt.key('right', true);
  const d1 = env.__rt.keys().right, n1 = env.__sent.length;
  env.__rt.key('right', true);
  const n2 = env.__sent.length;
  // 松开
  env.__rt.key('right', false);
  const d3 = env.__rt.keys().right, n3 = env.__sent.length;
  const frames = env.__sent.slice();
  if (d1 !== 1) return { ok: false, info: '按下后 keys.right != 1' };
  if (d3 !== 0) return { ok: false, info: '松开后 keys.right != 0' };
  if (n2 !== n1) return { ok: false, info: '重复按下竟然又发了帧（防重复守卫失效）' };
  if (n3 !== n1 + 1) return { ok: false, info: '松开没发帧' };
  const hasDown = frames.some((f) => f.indexOf('"k":"right"') >= 0 && f.indexOf('"v":1') >= 0);
  const hasUp = frames.some((f) => f.indexOf('"k":"right"') >= 0 && f.indexOf('"v":0') >= 0);
  if (!hasDown || !hasUp) return { ok: false, info: '发出的帧里找不到 down/up' };
  return { ok: true, info: '按下发 down、重复按不发、松开发 up（共 ' + frames.length + ' 帧）' };
});

// ---------------------------------------------------------------- 5) 昼夜明暗
check('F5 昼夜明暗：帧里 phase=night ⇒ 画面**真的**暗下来（且能变回来）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  // 每跑一次 draw 就把 queued 的 rAF 取出来执行（与浏览器一致：draw 末尾再排一个）
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  const mk = (phase) => ({
    t: 1, tick: 30, n: 1, iseq: 1,
    ents: [{ id: 1000, x: 0, z: 0, p: 'wilson', a: 'idle', bld: 'wilson', fr: 0, f: 0 }],
    player: { id: 1000, x: 0, z: 0 },
    world: { phase, season: phase === 'winter' ? 'winter' : 'autumn',
             isday: phase === 'day', isdusk: phase === 'dusk', isnight: phase === 'night',
             temperature: 5 },
  });
  // 反向保护：白天必须先确认暗度是 0（否则「夜里变暗」这条有可能是别的东西造成的）
  for (let i = 0; i < 5; i++) { rt.feed(mk('day')); draw(); }
  const d0 = rt.dark();
  for (let i = 0; i < 90; i++) { rt.feed(mk('night')); draw(); }
  const dN = rt.dark();
  for (let i = 0; i < 90; i++) { rt.feed(mk('day')); draw(); }
  const dD = rt.dark();
  if (!(d0 < 0.01)) return { ok: false, info: '白天时暗度不为 0：' + d0.toFixed(4) };
  if (!(dN > 0.4)) return { ok: false, info: '夜晚跑了 90 帧暗度仍只有 ' + dN.toFixed(3) };
  if (!(dD < 0.02)) return { ok: false, info: '切回白天后暗度仍是 ' + dD.toFixed(3) };
  return { ok: true, info: `白天 ${d0.toFixed(3)} → 夜晚 ${dN.toFixed(3)} → 白天 ${dD.toFixed(3)}（平滑过渡）` };
});

check('F6 反向：帧里**没有** world 时，画面不得凭空变暗', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  for (let i = 0; i < 120; i++) {
    rt.feed({ t: 1, tick: 30, n: 1, iseq: 1, ents: [], player: { id: 1000, x: 0, z: 0 } });
    draw();
  }
  const d = rt.dark();
  if (rt.world() !== null) return { ok: false, info: 'world() 应为 null' };
  return d < 0.004 ? { ok: true, info: '始终是白天（暗度 ' + d.toFixed(4) + '）' }
                   : { ok: false, info: '没有 world 却暗了下来：' + d.toFixed(4) };
});

// ---------------------------------------------------------------- 6) 地形图层
check('F7 地形图层：注入瓦片表后**真的画出来**（且坏数据被拒）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  const frame = { t: 1, tick: 30, n: 0, iseq: 1, ents: [], player: { id: 1000, x: 0, z: 0 } };

  rt.feed(frame); draw();
  // ① 没注入之前：**不该**有地形，也**不该**画过
  if (rt.terrain() !== null) return { ok: false, info: '还没注入就报有地形' };
  const d0 = rt.terrainDraws();
  if (d0 !== 0) return { ok: false, info: '没地形却做了 drawImage' };

  // ② 反向：坏数据必须被**明确拒绝**，而不是画出一张错的地图
  const bad = [
    ['null', null],
    ['缺 w/h', { tiles: [1, 2, 3, 4] }],
    ['长度 ≠ w×h', { w: 4, h: 4, tile: 4, tiles: [1, 2] }],
    ['tiles 不是数组', { w: 4, h: 4, tiles: 'xxxx' }],
  ];
  for (const [name, t] of bad) {
    if (rt.setTerrain(t) !== false) return { ok: false, info: '坏数据没被拒: ' + name };
  }
  if (rt.terrain() !== null) return { ok: false, info: '拒绝了坏数据却仍报 ready（状态被污染）' };

  // ③ 正确数据：8×8，瓦片 id → 名字走通
  const W = 8, H = 8, tiles = new Array(W * H).fill(6);
  tiles[0] = 1; tiles[63] = 7;
  if (!rt.setTerrain({ w: W, h: H, tile: 4, tiles,
                       names: { '1': 'IMPASSABLE', '6': 'GRASS', '7': 'FOREST' } }))
    return { ok: false, info: '正确数据被拒了' };
  const T = rt.terrain();
  if (!T || T.w !== W || T.h !== H) return { ok: false, info: 'terrain() 形状不对' };
  for (let i = 0; i < 3; i++) { rt.feed(frame); draw(); }
  const d1 = rt.terrainDraws();
  if (d1 <= d0) return { ok: false, info: '地形就绪了却一次 drawImage 都没做（画面还是空的）' };
  return { ok: true, info: `坏数据 4 种全拒 ✔；就绪后 drawImage ${d1 - d0} 次（每帧 1 次，与帧数一致）` };
});

check('F8 反向：地形全在屏幕外时**不该**硬画（视口裁剪生效）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  const W = 4, H = 4, tiles = new Array(W * H).fill(6);
  rt.setTerrain({ w: W, h: H, tile: 4, tiles, names: { '6': 'GRASS' } });
  // 把相机挪到离地图极远的地方（地图半宽 8 单位）
  rt.feed({ t: 1, tick: 30, n: 0, iseq: 1, ents: [], player: { id: 1, x: 99999, z: 99999 } });
  draw();
  // 相机跟随玩家 ⇒ 地图完全在屏幕外
  const n = rt.terrainDraws();
  // 再挪回来，应该又能画（证明「不画」是因为裁剪，不是因为坏了）
  rt.feed({ t: 1, tick: 30, n: 0, iseq: 1, ents: [], player: { id: 1, x: 0, z: 0 } });
  draw();
  const m = rt.terrainDraws();
  if (n !== 0) return { ok: false, info: '地图在屏幕外却画了 ' + n + ' 次' };
  if (m <= n) return { ok: false, info: '挪回视野内仍不画（不是裁剪，是坏了）' };
  return { ok: true, info: `屏幕外 0 次 → 视野内 ${m - n} 次（裁剪生效且可恢复）` };
});

// ---------------------------------------------------------------- 7) 暂停
check('F9 暂停：本地按键**发的是控制指令**（不是输入键），且以服务端帧为准', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  env.__sent.length = 0;
  rt.setPause(true);
  const sent = env.__sent.slice();
  if (rt.paused() !== true) return { ok: false, info: '本地镜像没更新' };
  const hit = sent.find((s) => s.indexOf('"cmd":"pause"') >= 0 && s.indexOf('"v":1') >= 0);
  if (!hit) return { ok: false, info: '没发出 {cmd:pause}：' + JSON.stringify(sent) };
  // ★ 反向：绝不能把它当输入键发出去（那会让 TheInput 里多一个叫 cmd 的怪键）
  if (sent.some((s) => s.indexOf('"k":"cmd"') >= 0))
    return { ok: false, info: '竟然把 cmd 当按键发了（"k":"cmd"）' };
  if (Object.keys(rt.keys()).length !== 0)
    return { ok: false, info: '暂停命令污染了本地按键表: ' + JSON.stringify(rt.keys()) };

  // ★ 服务端权威：帧里说没暂停，本地就得跟着回到「未暂停」
  rt.feed({ t: 1, tick: 30, n: 0, iseq: 1, ents: [], player: { id: 1, x: 0, z: 0 }, paused: false });
  if (rt.paused() !== false) return { ok: false, info: '帧说未暂停，本地却仍是暂停（没以服务端为准）' };
  rt.feed({ t: 1, tick: 30, n: 0, iseq: 1, ents: [], player: { id: 1, x: 0, z: 0 }, paused: true });
  if (rt.paused() !== true) return { ok: false, info: '帧说暂停，本地却未跟上' };
  return { ok: true, info: '发出 {cmd:pause,v:1} 且未污染按键表；帧 → 本地镜像双向同步 ✔' };
});

check('F10 反向：帧里**没有** paused 字段时，本地镜像不得被清成 false', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPause(true);
  // 老版本服务端（不带 paused 字段）—— 此时本地应保持原状，而不是被悄悄改掉
  rt.feed({ t: 1, tick: 30, n: 0, iseq: 1, ents: [], player: { id: 1, x: 0, z: 0 } });
  if (rt.paused() !== true)
    return { ok: false, info: '帧里没有 paused 就把本地清成了 false（无法区分「没这个字段」和「没暂停」）' };
  return { ok: true, info: '缺字段时保持原状（前向兼容）' };
});

// ---------------------------------------------------------------- 8) 绘制预算（P4 4.4）
check('F11 低优先级降级：低缩放下**远景**变点、近处与玩家仍是精灵', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  // 造 40 个实体：玩家在原点，其余沿 +x 每 2 单位一个（全都在视野内，避免被视口裁剪干扰）
  const N = 40;
  const ents = [{ id: 1, x: 0, z: 0, p: 'wilson', bld: 'wilson', a: 'idle_loop', fr: 1 }];
  for (let i = 1; i < N; i++) ents.push({ id: 1000 + i, x: i * 2, z: 0, p: 'beefalo' });
  const frame = { t: 1, tick: 30, n: N, iseq: 1, ents, player: { id: 1, x: 0, z: 0 } };
  // ★ 只画**一帧**：计数是累加的，画两帧就会把 1 个降级记成 2 个（第一版就是这么假红的）
  const one = (zoom) => {
    rt.resetPerf(); rt.cam().zoom = zoom; rt.feed(frame); draw(); return rt.perf();
  };

  // ① 高缩放：**一个都不该降级**（缩放大 ⇒ 精灵不小 ⇒ 没有降级理由）
  const hi = one(20);
  if (hi.dots !== 0) return { ok: false, info: '高缩放下仍有 ' + hi.dots + ' 个被降级' };
  if (hi.sprites < 10) return { ok: false, info: '高缩放下精灵决策数只有 ' + hi.sprites };

  // ② 低缩放：远景降级、近景与玩家保住
  const lo = one(2);
  if (lo.dots === 0) return { ok: false, info: '低缩放下一个都没降级（保护没生效）' };
  if (lo.sprites < 3) return { ok: false, info: '低缩放下近处/玩家也被降级了（sprites=' + lo.sprites + '）' };
  if (lo.sprites + lo.dots !== N)
    return { ok: false, info: '决策总数 ' + (lo.sprites + lo.dots) + ' ≠ ' + N + '（有实体既没画精灵也没记点）' };
  // ★ 精确切分：NEAR_R=24 ⇒ |x|>24 即 x≥26 ⇒ i≥13 共 27 个降级，前 13 个（含玩家）为精灵
  if (lo.dots !== 27 || lo.sprites !== 13)
    return { ok: false, info: `切分应为 精灵13/点27，实际 精灵${lo.sprites}/点${lo.dots}` };
  return { ok: true, info: `高缩放 0 降级（可见 ${hi.sprites} 个）；低缩放 精灵×${lo.sprites} + 点×${lo.dots} = ${N}（玩家与近景保住）` };
});

check('F12 反向：降级只发生在**低缩放 + 远景**两个条件同时成立时', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  const mk = (far) => ({
    t: 1, tick: 30, n: 2, iseq: 1,
    ents: [{ id: 1, x: 0, z: 0, p: 'wilson' }, { id: 2, x: far ? 200 : 10, z: 0, p: 'beefalo' }],
    player: { id: 1, x: 0, z: 0 },
  });
  // ★★ 每个子用例用**全新的客户端**：复用同一个客户端时，上一轮的 prevFrame 还在，
  //   而插值系数 a 在两帧时间戳相同时会取 0 ⇒ 实体被插值回**上一轮的位置**
  //   （第一版就因此把 x=10 的近景算成了 x=200 的远景，报「不该降级却降级」）。
  //   这类「测试之间共享状态」的假红与假绿一样贵 —— 所以宁可多建一次沙箱。
  const run = (zoom, far) => {
    const e2 = mod.makeClient();
    const r2 = e2.__rt;
    r2.cam().zoom = zoom;
    r2.feed(mk(far));
    const fn = e2.__rafQueue.shift();
    if (fn) fn(e2.__perf.now());
    return r2.perf();
  };
  const a = run(2, true);      // 低缩放 + 远景 ⇒ 降级 1 个
  if (a.dots !== 1) return { ok: false, info: '低缩放+远景应恰好降级 1 个，实际 ' + a.dots };
  const b = run(20, true);     // 高缩放 + 远景 ⇒ 不降级
  if (b.dots !== 0) return { ok: false, info: '高缩放+远景不该降级，实际 ' + b.dots };
  const c = run(2, false);     // 低缩放 + 近景 ⇒ 不降级
  if (c.dots !== 0) return { ok: false, info: '低缩放+近景不该降级，实际 ' + c.dots };
  return { ok: true, info: '低缩放+远景→降级 1；高缩放+远景→0；低缩放+近景→0（两个条件缺一不可）' };
});

// ---------------------------------------------------------------- 9) 客户端预测（P5 5.4）
// ★ 怎么「确定性地推进时间」：rAF 回调**接收 now 作为参数**，
//   所以传一个未来的时间戳就能精确制造「距上次绘制过了 T 毫秒」。
//   不这么做的话，连续 draw 之间的 dt≈0，永远测不出外推。
const predEnv = (mod) => {
  const env = mod.makeClient();
  const rt = env.__rt;
  const drawAt = (adv) => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now() + adv); };
  const P = (x, t) => ({
    t: t || 1, tick: Math.round((t || 1) * 30), n: 1, iseq: 1,
    ents: [{ id: 1, x, z: 0, p: 'wilson', bld: 'wilson', a: 'idle_loop', fr: 1 }],
    player: { id: 1, x, z: 0 },
  });
  return { env, rt, drawAt, P };
};

check('F13 客户端预测：有输入时**本地立刻前进**，不等服务端帧', () => {
  const mod = require('../rt/perf_lib.js');
  const t = predEnv(mod);
  const { rt, drawAt, P } = t;
  // 先给两帧**确实在动**的帧，让速度被自校准出来。
  // ★ 小步走（每 0.1 s 走 1 单位 = 10 单位/s）：两帧之间位移 1 < SNAP_EPS(3)，
  //   这样不会被当成「传送」而触发吸附 —— 第一版一步跨 10 个单位，
  //   结果测试自己制造了一次传送，然后抱怨「第一帧就吸附了」。
  rt.feed(P(0, 1)); drawAt(0);
  rt.feed(P(1, 1.1)); drawAt(0);
  const sp = rt.moveSpeed();
  if (!(sp > 9 && sp < 11)) return { ok: false, info: '速度自校准不对：' + sp };

  rt.key('right', true);
  const x0 = rt.pred().x, n0 = rt.pred().extrapolated;
  const scr0 = rt.playerScreen();
  drawAt(500);                      // 距上次绘制 0.5 s，且**不发新帧**
  const p = rt.pred();
  if (p.extrapolated <= n0) return { ok: false, info: '没有外推（预测根本没跑）' };
  const lead = p.x - x0;
  // ★ 外推有**上限 200 ms**（dt 被 clamp）：超过就不该继续猜 ——
  //   所以 0.5 s 的间隔**不该**前进 5 个单位，只该前进 ≈0.2 s 的量。
  //   （第一版按 0.5 s 断言，等于要求「猜得越久越好」——那恰恰是错的方向）
  if (lead < 1.0) return { ok: false, info: `0.2 s 上限内只前进 ${lead.toFixed(2)}` };
  if (lead > 0.2 * sp) return { ok: false, info: `超出 200 ms 外推上限：前进 ${lead.toFixed(2)} > ${(0.2 * sp).toFixed(2)}` };
  // ★ 关键：预测必须**真的到了画面**（算了却不用是这功能最常见的死法）
  const scr1 = rt.playerScreen();
  if (!scr1 || !scr0 || scr1[0] <= scr0[0]) return { ok: false, info: '画面上的玩家没有往前移（预测没接到绘制上）' };
  return { ok: true, info: `速度自校准 ${sp.toFixed(2)} 单位/s；0.5 s 无帧本地前进 ${lead.toFixed(2)}，屏幕上 x ${scr0[0].toFixed(0)}→${scr1[0].toFixed(0)}` };
});

check('F14 反向：**没有输入就不许外推**（否则一卡顿人物自己往前滑）', () => {
  const mod = require('../rt/perf_lib.js');
  const t = predEnv(mod);
  const { rt, drawAt, P } = t;
  rt.feed(P(0, 1)); drawAt(0);
  rt.feed(P(1, 1.1)); drawAt(0);
  const x0 = rt.pred().x, n0 = rt.pred().extrapolated;
  drawAt(500);
  drawAt(500);
  const p = rt.pred();
  if (p.extrapolated !== n0) return { ok: false, info: '没输入却外推了 ' + (p.extrapolated - n0) + ' 次' };
  // 位置只允许被「向权威位置收敛」微调（服务端仍在 10），不允许自己往前跑
  if (p.x > x0 + 0.5) return { ok: false, info: `没输入却前进了 ${(p.x - x0).toFixed(2)}` };
  return { ok: true, info: `无输入 1 s：外推 0 次、位置只从 ${x0.toFixed(2)} 收敛到 ${p.x.toFixed(2)}` };
});

check('F15 误差分级：小误差**平滑收敛**、大误差**立刻吸附**（不 rubber-band）', () => {
  const mod = require('../rt/perf_lib.js');
  const t = predEnv(mod);
  const { rt, drawAt, P } = t;
  rt.feed(P(0, 1)); drawAt(0);
  rt.feed(P(1, 1.1)); drawAt(0);
  if (rt.pred().snapped !== 0) return { ok: false, info: '前两帧就吸附了（初始化不该算吸附）' };

  // ① 小误差（服务端说 1.5，本地在 1 附近）⇒ 平滑：不吸附、误差逐帧变小
  const c0 = rt.pred().corrected;
  rt.feed(P(1.5, 1.2));
  // ★ 断言的是**相对权威位置的真实误差**，不是 `PRED.err`：
  //   后者只是「帧到达那一刻」的快照，不随绘制更新 ——
  //   第一版拿它比对，等于拿一个常量比自己（永远相等，于是假红）。
  const e1 = Math.abs(rt.pred().x - 1.5);
  drawAt(16); drawAt(16); drawAt(16);
  const e2 = Math.abs(rt.pred().x - 1.5);
  if (rt.pred().snapped !== 0) return { ok: false, info: '小误差却触发了吸附' };
  if (rt.pred().corrected <= c0) return { ok: false, info: '小误差没有走平滑收敛路径' };
  if (!(e2 < e1)) return { ok: false, info: `误差没有变小：${e1.toFixed(3)} → ${e2.toFixed(3)}` };

  // ② 大误差（服务端说 200 = 传送）⇒ **立刻吸附**，且一步到位
  const s0 = rt.pred().snapped;
  rt.feed(P(200, 4));
  const p = rt.pred();
  if (p.snapped !== s0 + 1) return { ok: false, info: '大误差没有吸附' };
  if (Math.abs(p.x - 200) > 1e-6) return { ok: false, info: `吸附后位置是 ${p.x}，应正好是 200` };
  return { ok: true, info: `小误差 ${e1.toFixed(2)}→${e2.toFixed(2)} 平滑收敛；大误差（传送 +190）一步吸附到 200` };
});

check('F16 反向：速度没测出来时**不许瞎猜**（记 noSpeed，不外推）', () => {
  const mod = require('../rt/perf_lib.js');
  const t = predEnv(mod);
  const { rt, drawAt, P } = t;
  // 只给一帧静止的帧 ⇒ 速度无从测出
  rt.feed(P(0, 1)); drawAt(0);
  if (rt.moveSpeed() !== 0) return { ok: false, info: '静止帧竟然测出了速度：' + rt.moveSpeed() };
  rt.key('right', true);
  const x0 = rt.pred().x;
  drawAt(500);
  const p = rt.pred();
  if (p.extrapolated !== 0) return { ok: false, info: '没速度却外推了（会猜错方向/速度）' };
  if (p.noSpeed === 0) return { ok: false, info: '没把「缺速度」记下来（静默跳过）' };
  if (Math.abs(p.x - x0) > 1e-6) return { ok: false, info: '没速度却移动了 ' + (p.x - x0) };
  return { ok: true, info: '无速度时不外推，且 noSpeed 计数 ' + p.noSpeed + '（不静默）' };
});

// ---------------------------------------------------------------- 10) 往返延迟（计划 2.4）
check('F17 往返延迟：ping/pong 按**序号**配对，且 pong 不会被当成一帧', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  // ★ 把沙箱时间变成**可控**的：`perf` 就是客户端里的 `performance`，
  //   直接换掉它的 `now` ⇒ 延迟测量完全确定（否则只能靠真实时间，测不稳）。
  let T = 1000;
  env.__perf.now = () => T;

  rt.feed({ t: 1, tick: 30, n: 1, iseq: 1,
            ents: [{ id: 1, x: 0, z: 0, p: 'wilson' }], player: { id: 1, x: 0, z: 0 } });
  env.__sent.length = 0;

  // ① 发一次 ping（序号 1）
  rt.pingNow(T);
  const sent = env.__sent.slice();
  if (!sent.some((s) => s.indexOf('"cmd":"ping"') >= 0 && s.indexOf('"v":1') >= 0))
    return { ok: false, info: '没发出 ping：' + JSON.stringify(sent) };
  if (rt.rttState().pending !== 1) return { ok: false, info: '待回包数不对：' + rt.rttState().pending };

  // ② 20 ms 后收到 pong ⇒ rtt ≈ 20
  T = 1020;
  rt.feed({ pong: 1 });
  const r1 = rt.rtt();
  if (!(r1 > 19 && r1 < 21)) return { ok: false, info: 'rtt 应为 ≈20，实际 ' + r1 };

  // ③ ★ 反向：pong **不是快照** —— 收完 pong，画面数据必须原样
  const fr = rt.frame();
  if (!fr || fr.n !== 1 || !fr.ents || fr.ents.length !== 1)
    return { ok: false, info: 'pong 把快照覆盖了：' + JSON.stringify(fr) };

  // ④ 反向：序号不匹配的 pong 一律丢弃 + **计数**（不静默）
  const before = rt.rtt(), un0 = rt.rttState().unmatched;
  T = 1040;
  rt.feed({ pong: 999 });
  if (rt.rtt() !== before) return { ok: false, info: '野 pong 改了 rtt' };
  if (rt.rttState().unmatched !== un0 + 1) return { ok: false, info: '野 pong 没被计数' };

  // ⑤ 节流：1 秒内不重复发
  env.__sent.length = 0;
  T = 1500; rt.pingNow(T);
  if (env.__sent.length !== 0) return { ok: false, info: '1 秒内重复发了 ping' };
  T = 2100; rt.pingNow(T);
  if (env.__sent.length === 0) return { ok: false, info: '超过 1 秒仍不发 ping（节流反了）' };
  return { ok: true, info: `rtt≈${r1.toFixed(1)} ms；野 pong 计数 ${rt.rttState().unmatched}；节流生效（1 s 内只发一次）` };
});

// ---------------------------------------------------------------- 11) 交互（P22）
check('F18 交互：目标来自服务端；按空格**只发一次**、按住**不重发**、松开发 unact', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  // ① 没有目标时按空格**什么都不该发**（没得做就不要瞎发）
  env.__sent.length = 0;
  rt.actKey(true);
  if (env.__sent.length !== 0) return { ok: false, info: '没有目标却发了 ' + env.__sent.length + ' 条' };
  if (!rt.act().held) return { ok: false, info: '按住状态没记下来' };
  rt.actKey(false);

  // ② 目标由服务端给（客户端只是收下并取最近的）
  rt.feed({ targets: [{ id: 42, p: 'evergreen', x: 1, z: 2, a: 'CHOP' },
                      { id: 43, p: 'sapling', x: 9, z: 9, a: 'DIG' }],
            last_act: { ok: true, msg: 'CHOP' } });
  rt.actTick(1000);
  const A = rt.act();
  if (A.targets !== 2) return { ok: false, info: '目标数不对: ' + A.targets };
  if (!A.pick || A.pick.id !== 42) return { ok: false, info: '没取最近的那个（列表第一个）' };
  if (A.ok !== true || A.msg !== 'CHOP') return { ok: false, info: '动作结果没显示出来' };

  // ③ 按一次只发一条 act
  // ★ 时间必须是**可控的**：`actKeyDown` 内部用 `performance.now()` 记「下次重发时刻」，
  //   若测试用假时间、实现用真时间，两边对不上（第一版就是这么假红的）。
  //   ⇒ 把沙箱时间换成可控函数，之后一律用它。
  let T = 1000;
  env.__perf.now = () => T;
  env.__sent.length = 0;
  rt.actKey(true);
  let acts = env.__sent.filter((x) => x.indexOf('"cmd":"act"') >= 0);
  if (acts.length !== 1) return { ok: false, info: '按下发了 ' + acts.length + ' 条 act（应 1 条）' };
  if (acts[0].indexOf('"v":42') < 0) return { ok: false, info: 'act 没带目标 id：' + acts[0] };
  const nActs = () => env.__sent.filter((x) => x.indexOf('"cmd":"act"') >= 0).length;
  // ④ ★★★ 按住**不许重发**（2026-10-16 改）。
  //   原来这里断言的是「过 0.7 s 要重发一次」—— 那条判据**锁住了一个有害行为**：
  //   原版动作链自己就是循环的，重发会把正在跑的那一轮打断重来，
  //   于是 workleft 卡在中途、树永远砍不倒（实测：只发一次 → 砍倒 + 掉 3 个 log；
  //   每 0.7/1.0/1.5 s 重发 → 分别卡在 5/4/8）。
  //   ⇒ 现在断言反过来写：按住 3 秒、每 0.1 s tick 一次，act 条数**必须一直是 1**。
  for (T = 1100; T <= 4000; T += 100) rt.actTick(T);
  if (nActs() !== 1)
    return { ok: false, info: `按住 3 s 竟然发了 ${nActs()} 条 act（重发会打断引擎自己的动作循环）` };
  // ⑤ 松开必须发 unact
  rt.actKey(false);
  if (!env.__sent.some((x) => x.indexOf('"cmd":"unact"') >= 0))
    return { ok: false, info: '松开没发 unact（服务端会一直砍下去）' };
  return { ok: true, info: '无目标不发；目标取最近(id=42)；按下 1 条、按住 3 s 仍 1 条（不重发）、松开发 unact' };
});

check('F19 反向：targets 控制消息**不是快照**（不能把画面清空）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  rt.feed({ t: 1, tick: 30, n: 1, iseq: 1,
            ents: [{ id: 1, x: 0, z: 0, p: 'wilson' }], player: { id: 1, x: 0, z: 0 } });
  draw();
  const before = rt.frame();
  rt.feed({ targets: [] });
  const after = rt.frame();
  if (!after || after.n !== before.n || !after.ents || after.ents.length !== before.ents.length)
    return { ok: false, info: 'targets 把快照覆盖了：' + JSON.stringify(after) };
  return { ok: true, info: '收到 targets 后 lastFrame 原样（画面不会空一帧）' };
});

// ---------------------------------------------------------------- 12) 触屏 / 指针（P23）
// ★ 这一节的判据全部围绕一句话：**面板与键盘必须走同一条输入路径**。
//   所以第一项不是「按了会动」，而是「两条路发出的帧**逐字节一致**」——
//   只要有人日后给面板单开一条 `send()`，它立刻红。
const normSeq = (arr) => arr.map((s) => s.replace(/"seq":\d+/g, '"seq":#'));
const keyFrames = (env) => env.__sent.filter((s) => /"k":"(up|down|left|right)"/.test(s));

check('F20 触屏：摇杆推「右」与键盘 D **走同一条路**（帧除 seq 外逐字节一致）', () => {
  const mod = require('../rt/perf_lib.js');
  // ① 键盘（走 keydown 处理器注册的那个函数）
  const k = mod.makeClient();
  k.__rt.key('right', true);
  const kb = keyFrames(k);
  // ② 摇杆：按住摇杆区右侧
  const t = mod.makeClient();
  const rt = t.__rt;
  rt.setPad(true);
  const p = rt.pad();
  rt.pt(1, p.sx + p.sr * 0.9, p.sy, 'down');
  const pad = keyFrames(t);
  if (!kb.length) return { ok: false, info: '键盘那条路根本没发帧' };
  if (!pad.length) return { ok: false, info: '摇杆那条路根本没发帧' };
  if (JSON.stringify(normSeq(kb)) !== JSON.stringify(normSeq(pad)))
    return { ok: false, info: '两条路的帧不一致：键盘 ' + JSON.stringify(normSeq(kb))
                             + ' vs 摇杆 ' + JSON.stringify(normSeq(pad)) };
  if (rt.keys().right !== 1) return { ok: false, info: '摇杆推右后本地 keys.right != 1' };
  return { ok: true, info: '键盘 ' + normSeq(kb)[0] + ' ≡ 摇杆 ' + normSeq(pad)[0] + '（同一函数、同一帧）' };
});

check('F21 触屏：摇杆八向 + 死区（死区内**不许**产生任何方向键）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPad(true);
  const p = rt.pad();
  const push = (fx, fy) => {                     // fy > 0 = 屏幕上推（= up 键）
    const x = p.sx + fx * p.sr, y = p.sy - fy * p.sr;
    rt.pt(9, x, y, 'down');
    const k = rt.keys();
    const got = { l: k.left | 0, r: k.right | 0, u: k.up | 0, d: k.down | 0 };
    rt.pt(9, x, y, 'up');
    return got;
  };
  const cases = [
    ['右',    1, 0,     0, 1, 0, 0],
    ['左',   -1, 0,     1, 0, 0, 0],
    ['上',    0, 1,     0, 0, 1, 0],
    ['下',    0, -1,    0, 0, 0, 1],
    ['右上',  0.8, 0.8, 0, 1, 1, 0],
    ['左下', -0.8, -0.8, 1, 0, 0, 1],
    ['死区',  0.1, 0.1, 0, 0, 0, 0],             // 半径 10% ⇒ 小于死区 28%
  ];
  for (const [nm, fx, fy, l, r, u, d] of cases) {
    const g = push(fx, fy);
    if (g.l !== l || g.r !== r || g.u !== u || g.d !== d)
      return { ok: false, info: `${nm} 期望 左${l}右${r}上${u}下${d}，实得 ` + JSON.stringify(g) };
  }
  return { ok: true, info: '四正 + 两斜 + 死区（0.1 半径不触发）共 ' + cases.length + ' 例全对' };
});

check('F22 触屏：松开 / pointercancel / 失焦 ⇒ 方向键归零（不会一直往前走）', () => {
  const mod = require('../rt/perf_lib.js');
  const press = (rt, p) => rt.pt(5, p.sx + p.sr * 0.9, p.sy, 'down');
  const make = () => { const e = mod.makeClient(); e.__rt.setPad(true); return e; };

  // ① 正常松开
  let e = make(); let p = e.__rt.pad();
  press(e.__rt, p);
  if (e.__rt.keys().right !== 1) return { ok: false, info: '按下后没动' };
  e.__rt.pt(5, p.sx + p.sr * 0.9, p.sy, 'up');
  if (e.__rt.keys().right !== 0) return { ok: false, info: '松开后 keys.right 仍为 1' };
  if (e.__rt.pad().stickOn) return { ok: false, info: '松开后摇杆仍标为「按住」' };

  // ② pointercancel（浏览器收回手势：切后台 / 来电 / 系统手势）
  e = make(); p = e.__rt.pad();
  press(e.__rt, p);
  e.__rt.pt(5, p.sx, p.sy, 'cancel');
  if (e.__rt.keys().right !== 0) return { ok: false, info: 'pointercancel 后没归零（角色会一直走）' };

  // ③ 失焦（切标签页 / 弹窗抢焦点）
  e = make(); p = e.__rt.pad();
  press(e.__rt, p);
  e.__fireWin('blur', {});
  if (e.__rt.keys().right !== 0) return { ok: false, info: '失焦后没归零' };
  if (e.__rt.pad().active !== 0) return { ok: false, info: '失焦后仍记着按下的手指' };
  return { ok: true, info: '松开 ✔ / pointercancel ✔ / 失焦 ✔（三种打断都会归零）' };
});

check('F23 触屏：动作键 = actKeyDown/actKeyUp **同一条路**（发 act、松开发 unact）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPad(true);
  rt.setTargets([{ id: 7, p: 'evergreen', x: 1, z: 1, a: 'CHOP' }]);
  rt.actTick(1000);                                 // 目标由服务端给，这一步只是让客户端取最近
  const p = rt.pad();
  env.__sent.length = 0;
  rt.pt(4, p.ax, p.ay, 'down');
  let acts = env.__sent.filter((s) => s.indexOf('"cmd":"act"') >= 0);
  if (acts.length !== 1) return { ok: false, info: '动作键按下发了 ' + acts.length + ' 条 act（应 1 条）' };
  if (acts[0].indexOf('"v":7') < 0) return { ok: false, info: 'act 没带目标 id：' + acts[0] };
  rt.pt(4, p.ax, p.ay, 'up');
  if (!env.__sent.some((s) => s.indexOf('"cmd":"unact"') >= 0))
    return { ok: false, info: '动作键松开没发 unact（服务端会一直砍下去）' };
  if (rt.pad().actOn) return { ok: false, info: '松开后动作键仍标为「按住」' };
  // ★ 反向：动作键**不许**碰方向键（它和移动是两回事）
  if (rt.keys().up || rt.keys().down || rt.keys().left || rt.keys().right)
    return { ok: false, info: '按动作键污染了方向键：' + JSON.stringify(rt.keys()) };
  return { ok: true, info: '按下 1 条 act(v:7)、松开发 unact；方向键未被污染' };
});

check('F24 反向：面板**关**时（桌面），左下角按下 = 平移相机，且不产生任何按键帧', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPad(true);
  const p = rt.pad();          // 先算一次布局（关掉之后布局还在）
  rt.setPad(false);            // ← 桌面：面板关掉
  if (rt.pad().on !== false) return { ok: false, info: 'setPad(false) 没关掉' };
  env.__sent.length = 0;
  const x0 = rt.cam().x;
  rt.pt(6, p.sx, p.sy, 'down');       // 恰好按在「摇杆区」的位置上
  rt.pt(6, p.sx + 60, p.sy, 'move');
  rt.pt(6, p.sx + 60, p.sy, 'up');
  const kf = keyFrames(env);
  if (kf.length) return { ok: false, info: '面板关着却产生了 ' + kf.length + ' 条按键帧：' + JSON.stringify(kf) };
  if (!(rt.cam().x < x0)) return { ok: false, info: '面板关着时拖动没有平移相机（x ' + x0 + '→' + rt.cam().x + '）' };
  // ★ 反向的反向：开着面板时，**同样**的位置按下必须被当成摇杆（不是平移）
  const e2 = mod.makeClient();
  e2.__rt.setPad(true);
  const q = e2.__rt.pad();
  const cx0 = e2.__rt.cam().x;
  e2.__rt.pt(6, q.sx + q.sr * 0.9, q.sy, 'down');
  if (e2.__rt.keys().right !== 1) return { ok: false, info: '开着面板却按下没反应' };
  if (e2.__rt.cam().x !== cx0) return { ok: false, info: '开着面板时按摇杆竟然平移了相机' };
  return { ok: true, info: '关=平移相机 0 按键帧；开=摇杆推右、相机不动（两种模式分得清）' };
});

check('F25 触屏：双指捏合缩放；单指只平移（不缩放）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPad(true);
  const z0 = rt.cam().zoom;
  // ① 单指在**面板外**拖动 ⇒ 只平移，不缩放
  rt.pt(1, 400, 200, 'down');
  rt.pt(1, 500, 200, 'move');
  if (rt.cam().zoom !== z0) return { ok: false, info: '单指拖动竟然缩放了' };
  if (rt.cam().x === 0 && rt.cam().z === 0) return { ok: false, info: '单指拖动没有平移' };
  rt.pt(1, 500, 200, 'up');
  // ② 双指：基准距离 100 单位，张开到 300 ⇒ 缩放 ×3
  const zb = rt.cam().zoom;
  rt.pt(2, 400, 200, 'down');
  rt.pt(3, 500, 200, 'down');
  rt.pt(3, 700, 200, 'move');
  const zc = rt.cam().zoom;
  if (!(zc > zb * 2.9 && zc < zb * 3.1)) return { ok: false, info: `捏合张开 3 倍，缩放却 ${zb.toFixed(2)}→${zc.toFixed(2)}` };
  // ③ 反向：双指时必须**关掉平移**（否则两指中点一动画面就乱窜）
  //    ★ 注意：两条断言必须**同时**成立才有意义 —— 只把两指一起平移（距离不变）
  //      缩放也不该变，那是「基准没被重置」的证据；继续张开才该继续放大。
  const cx = rt.cam().x;
  rt.pt(2, 410, 200, 'move'); rt.pt(3, 710, 200, 'move');       // 距离仍是 300 ⇒ 缩放不变
  if (rt.cam().x !== cx) return { ok: false, info: '捏合过程中相机被平移了（画面会乱窜）' };
  if (rt.cam().zoom !== zc) return { ok: false, info: `距离不变（300）缩放却变了：${zc.toFixed(2)}→${rt.cam().zoom.toFixed(2)}` };
  rt.pt(2, 380, 200, 'move'); rt.pt(3, 730, 200, 'move');       // 距离 300 → 350 ⇒ 缩放 ×350/300
  const zd = rt.cam().zoom;
  if (!(zd > zc * 1.16 && zd < zc * 1.18))
    return { ok: false, info: `继续张开（300→350）缩放应为 ×1.167，实际 ${zc.toFixed(2)}→${zd.toFixed(2)}` };
  if (rt.cam().x !== cx) return { ok: false, info: '继续张开时相机又被平移了' };
  return { ok: true, info: `单指只平移（zoom ${z0}）→ 双指张开 ${zb.toFixed(1)}→${zc.toFixed(1)}（×3）→ ${zd.toFixed(1)}（×3.5）；全程零平移` };
});

check('F26 触屏：事件**真的挂在** canvas / window 上（派发真实事件，不是直接调函数）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPad(true);
  const p = rt.pad();
  env.__sent.length = 0;
  // ① canvas 上的 pointerdown —— 走**注册过**的那个监听器
  const n = env.__fireCv('pointerdown',
    { pointerId: 11, clientX: p.sx + p.sr * 0.9, clientY: p.sy, preventDefault() {} });
  if (n <= 0) return { ok: false, info: 'canvas 上根本没挂 pointerdown（挂载那行被删了也测不出来就糟了）' };
  if (rt.keys().right !== 1) return { ok: false, info: '真实 pointerdown 没有推动摇杆' };
  // ② window 上的 pointerup
  const m = env.__fireWin('pointerup', { pointerId: 11 });
  if (m <= 0) return { ok: false, info: 'window 上没挂 pointerup' };
  if (rt.keys().right !== 0) return { ok: false, info: '真实 pointerup 没有归零' };
  // ③ ★ 反向：真实 **keydown** 必须走同一条路（这是此前从未被验证过的一条：
  //    以前测试只用 __rt.key，那是手抄的第二份实现）
  const c = env.__fireWin('keydown', { code: 'KeyA', preventDefault() {} });
  if (c <= 0) return { ok: false, info: 'window 上没挂 keydown' };
  if (rt.keys().left !== 1) return { ok: false, info: '真实 keydown(KeyA) 没有把 left 置 1' };
  const kf = keyFrames(env);
  if (!kf.some((s) => s.indexOf('"k":"left"') >= 0 && s.indexOf('"v":1') >= 0))
    return { ok: false, info: '真实 keydown 没有发出输入帧' };
  env.__fireWin('keyup', { code: 'KeyA', preventDefault() {} });
  if (rt.keys().left !== 0) return { ok: false, info: '真实 keyup 没有归零' };
  // ④ 反向：没映射的键不许产生帧
  const n0 = env.__sent.length;
  env.__fireWin('keydown', { code: 'KeyQ', preventDefault() {} });
  if (env.__sent.length !== n0) return { ok: false, info: '没映射的键 KeyQ 竟然发了帧' };
  return { ok: true, info: 'pointerdown/pointerup/keydown/keyup 四种真实事件全部生效；未映射键不发帧' };
});

check('F27 触屏：方向键按「来源」记账 —— 松开其中一个来源不该把方向整个清掉', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  rt.setPad(true);
  const p = rt.pad();
  // 键盘 ArrowRight 与 KeyD **都**映射到 right —— 先用它验「两个来源」，
  // 再用摇杆当第三个来源。
  env.__fireWin('keydown', { code: 'ArrowRight', preventDefault() {} });
  env.__fireWin('keydown', { code: 'KeyD', preventDefault() {} });
  rt.pt(8, p.sx + p.sr * 0.9, p.sy, 'down');
  if (rt.keys().right !== 1) return { ok: false, info: '多来源按下后 right 不是 1' };
  env.__fireWin('keyup', { code: 'ArrowRight', preventDefault() {} });
  if (rt.keys().right !== 1) return { ok: false, info: '松开 ArrowRight 后 right 被清成 0（可 KeyD 还按着）' };
  env.__fireWin('keyup', { code: 'KeyD', preventDefault() {} });
  if (rt.keys().right !== 1) return { ok: false, info: '松开 KeyD 后 right 被清成 0（可摇杆还推着）' };
  rt.pt(8, p.sx + p.sr * 0.9, p.sy, 'up');
  if (rt.keys().right !== 0) return { ok: false, info: '三个来源都松开后 right 仍为 1' };
  // ★ 反向：三个来源之间**只发有效变化的帧**（松开一个来源但不改变方向 ⇒ 不发帧）
  const n0 = env.__sent.length;
  env.__fireWin('keydown', { code: 'ArrowRight', preventDefault() {} });
  env.__fireWin('keydown', { code: 'KeyD', preventDefault() {} });
  env.__fireWin('keyup', { code: 'ArrowRight', preventDefault() {} });
  const extra = env.__sent.slice(n0).filter((s) => s.indexOf('"k":"right"') >= 0);
  if (extra.length !== 1)
    return { ok: false, info: '右方向共应只发 1 条帧（按下时），实际 ' + extra.length + ' 条：' + JSON.stringify(extra) };
  return { ok: true, info: 'ArrowRight/KeyD/摇杆 三来源按引用计数：逐个松开都不中断，且只发 1 条帧' };
});

// ---------------------------------------------------------------- 13) 死亡与复活（P26）
check('F28 会话自愈：重问「我是谁」收到**同一个** guid 不许重置预测；guid 变了要采纳', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const F = (id) => ({ t: 1, tick: 30, n: 1, iseq: 1,
                       ents: [{ id, x: 0, z: 0, p: 'wilson' }], player: { id, x: 0, z: 0 } });
  // ★ 先让客户端**采纳**一次（这时 ME.id 从 undefined 变成 1，属于「变化」，重置是对的），
  //   再谈「同样的 guid 不该重置」—— 否则第一帧就把前置条件当成回归了。
  rt.feed({ you: 1, slot: 0 });
  rt.feed(F(1));                       // 帧里有个可跟随的玩家 ⇒ 预测会被初始化
  if (!rt.pred().ok) return { ok: false, info: '喂了一帧之后预测仍未初始化（前置不成立）' };
  // ① 同样的 guid（例行重问每 2 s 会收到一次）⇒ **不许**重置预测
  rt.feed({ you: 1, slot: 0 });
  if (rt.me().id !== 1) return { ok: false, info: 'me().id 应为 1，实得 ' + rt.me().id };
  if (rt.pred().ok !== true)
    return { ok: false, info: '收到**同一个** guid 就把预测重置了 —— 那会每 2 s 顿一下' };
  // ② 换了身体（复活）⇒ 必须采纳新 guid 并重置预测
  rt.feed({ you: 7, slot: 0 });
  if (rt.me().id !== 7) return { ok: false, info: 'guid 变了却没采纳：' + rt.me().id };
  if (rt.pred().ok !== false) return { ok: false, info: '换了身体却没重置预测' };
  // ③ 节流：2 s 内只问一次，超了要再问（自愈必须真的会发作）
  env.__sent.length = 0;
  // ★ 起点要 ≥ 2000：`lastWhoAt` 初值是 0，而页面刚加载时 `performance.now()` 也接近 0
  //   ⇒ 头 2 s 不重问（那段时间本来就由连接时的 `askWhoami` 负责）—— 这是有意的，不是 bug。
  let T = 2500;
  env.__perf.now = () => T;
  rt.whoTick(T);
  const n1 = env.__sent.length;
  if (n1 !== 1) return { ok: false, info: '第一次 whoTick 发了 ' + n1 + ' 条（应 1）' };
  if (env.__sent[0].indexOf('"cmd":"whoami"') < 0)
    return { ok: false, info: 'whoTick 发的不是 whoami：' + env.__sent[0] };
  T = 3000; rt.whoTick(T);
  if (env.__sent.length !== n1) return { ok: false, info: '2 s 内又问了（节流失效）' };
  T = 5000; rt.whoTick(T);
  if (env.__sent.length === n1) return { ok: false, info: '超过 2 s 仍不问（自愈不发作）' };
  return { ok: true, info: '同 guid 不重置预测 ✔ / 换 guid 采纳并重置 ✔ / 每 2 s 问一次且节流正常 ✔' };
});

check('F29 选中目标：点某个目标就作用于它（不再是「永远是最近的那个」）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  // 三个目标：A 最近(在原点右侧 2 格)、B 更远、C 也在视野里
  rt.setTargets([{ id: 11, p: 'evergreen', x: 2, z: 0, a: 'CHOP' },
                 { id: 12, p: 'sapling', x: 8, z: 0, a: 'DIG' },
                 { id: 13, p: 'berrybush', x: 5, z: 5, a: 'PICKUP' }]);
  rt.cam().x = 0; rt.cam().z = 0; rt.cam().follow = false;
  rt.actTick(1000);
  if (!rt.act().pick || rt.act().pick.id !== 11)
    return { ok: false, info: '默认应当选最近的（id=11）' };
  // ① 点 B 的屏幕位置 ⇒ 选中 B
  const w2s = (x, z) => [(x - rt.cam().x) * rt.cam().zoom + 1280 / 2,
                         (rt.cam().z - z) * rt.cam().zoom + 720 / 2];
  const [bx, by] = w2s(8, 0);
  const hit = rt.pickAt(bx, by);
  if (!hit || hit.id !== 12) return { ok: false, info: '点 B 没选中 B：' + JSON.stringify(hit) };
  rt.actTick(1100);
  if (rt.act().pick.id !== 12) return { ok: false, info: '选中的不是 B（act tick 后又变回最近的？）' };
  // ② 目标列表刷新（服务端每 0.5 s 发一次）⇒ 选择必须**按 guid 保持**
  rt.setTargets([{ id: 12, p: 'sapling', x: 8, z: 0, a: 'DIG' },
                 { id: 11, p: 'evergreen', x: 2, z: 0, a: 'CHOP' }]);
  rt.actTick(1200);
  if (!rt.act().pick || rt.act().pick.id !== 12)
    return { ok: false, info: '列表刷新后选择丢了（应按 guid 保持，而不是按下标）' };
  // ③ 按住空格/动作键 ⇒ 作用于**选中的那个**
  env.__sent.length = 0;
  rt.actKey(true);
  const acts = env.__sent.filter((s) => s.indexOf('"cmd":"act"') >= 0);
  if (acts.length !== 1 || acts[0].indexOf('"v":12') < 0)
    return { ok: false, info: '按下的不是选中的那个：' + JSON.stringify(acts) };
  rt.actKey(false);
  // ④ 反向：点空白处**不该**改变选择（也不该把相机拖走 —— 那是另一条判据）
  rt.clearPick();
  rt.actTick(1300);
  const before = rt.act().pick.id;
  const none = rt.pickAt(600, 60);            // 那块地方没有目标
  if (none) return { ok: false, info: '点在空白处竟然命中了目标：' + JSON.stringify(none) };
  rt.actTick(1400);
  if (rt.act().pick.id !== before) return { ok: false, info: '点空白改变了选择' };
  // ⑤ 选中的目标消失 ⇒ 明确回退到最近的（而不是继续指着一个不存在的东西）
  rt.pickAt(...w2s(8, 0));
  rt.setTargets([{ id: 11, p: 'evergreen', x: 2, z: 0, a: 'CHOP' }]);
  rt.actTick(1500);
  if (rt.act().pickId !== null) return { ok: false, info: '目标没了却还记着 pickId=' + rt.act().pickId };
  if (rt.act().pick.id !== 11) return { ok: false, info: '目标没了之后没回退到最近的' };
  return { ok: true, info: '点 B 选 B ✔ / 列表刷新按 guid 保持 ✔ / 按空格作用于选中项 ✔ /' +
                           ' 点空白不改变 ✔ / 目标消失后回退到最近 ✔' };
});

check('F30 「找不到自己」要说出来（复活会换身体，别让用户只看到画面卡了一下）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const F = (id) => ({ t: 1, tick: 30, n: 1, iseq: 1,
                       ents: [{ id, x: 0, z: 0, p: 'wilson' }], player: { id, x: 0, z: 0 } });
  // 还没握手 ⇒ 不算「找不到自己」（那叫「还没开始」，报这个只会误导）
  if (rt.selfMissing(9999) !== false) return { ok: false, info: '没握手就报「找不到自己」' };
  rt.feed({ you: 1, slot: 0 });
  rt.feed(F(1));
  if (rt.selfMissing(1000) !== false) return { ok: false, info: '自己明明在帧里，却报找不到' };
  rt.feed(F(1));
  rt.selfMissing(1000);                       // 记下「看到自己」的时刻
  // ① 之后帧里没有我自己（复活换身体的窗口）⇒ 超过 1.5 s 必须报
  const F2 = { t: 2, tick: 60, n: 1, iseq: 2,
               ents: [{ id: 999, x: 1, z: 1, p: 'evergreen' }], player: { id: 1, x: 0, z: 0 } };
  rt.feed(F2);
  if (rt.selfMissing(1200) !== false) return { ok: false, info: '才过了 0.2 s 就报（单帧抖动不该报警）' };
  if (rt.selfMissing(3000) !== true) return { ok: false, info: '过了 2 s 仍不报 —— 用户看不到任何解释' };
  // ② 反向：自己回来了 ⇒ 立刻不再报（不许粘住）
  rt.feed(F(1));
  if (rt.selfMissing(3100) !== false) return { ok: false, info: '自己回来了还在报（粘住了）' };
  // ③ 服务端把「我」换成了新 guid（复活）：客户端采纳之后就不算找不到了
  rt.feed({ you: 7, slot: 0 });
  rt.feed({ t: 3, tick: 90, n: 1, iseq: 3,
            ents: [{ id: 7, x: 3, z: 0, p: 'wilson' }], player: { id: 7, x: 3, z: 0 } });
  if (rt.selfMissing(3200) !== false) return { ok: false, info: '换身体并采纳新 guid 之后仍报找不到' };
  return { ok: true, info: '没握手不报 / 在帧里不报 / 消失 0.2 s 不报、2 s 才报 / 回来后立刻不报 /' +
                           ' 换身体采纳新 guid 后不报' };
});

check('F31 画面**真的在画东西**（不是「帧率很高但屏幕是黑的」）', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  const draw = () => { const fn = env.__rafQueue.shift(); if (fn) fn(env.__perf.now()); };
  // 三个实体都在相机附近（相机默认跟随玩家 ⇒ 都在视野内）
  const frame = { t: 1, tick: 30, n: 3, iseq: 1,
                  ents: [{ id: 1, x: 0, z: 0, p: 'wilson', bld: 'wilson', a: 'idle_loop', fr: 1 },
                         { id: 2, x: 3, z: 0, p: 'evergreen', bld: 'evergreen' },
                         { id: 3, x: -3, z: 2, p: 'sapling', bld: 'sapling' }],
                  player: { id: 1, x: 0, z: 0 } };
  rt.resetPerf();
  rt.feed(frame); draw();
  const p1 = rt.perf();
  // ★ 判的是**决策计数**（该画精灵/该降级成点），不是「图集是否加载好」——
  //   沙箱里图集永远加载不出来（XHR 桩不回调），所以 `drew` 恒 0 是正常的。
  if (p1.sprites + p1.dots !== 3)
    return { ok: false, info: `3 个实体只处理了 ${p1.sprites + p1.dots} 个（画面会缺东西）` };
  if (p1.sprites !== 3) return { ok: false, info: '视野内 3 个实体却只有 ' + p1.sprites + ' 个走精灵路径' };
  const scr = rt.playerScreen();
  if (!scr) return { ok: false, info: '玩家没有被画到屏幕上（playerScreen 为空）' };
  // ② 反向：空帧 ⇒ 一个实体都不该画（否则计的是噪声，不是实体）
  rt.resetPerf();
  rt.feed({ t: 2, tick: 60, n: 0, iseq: 2, ents: [], player: { id: 1, x: 0, z: 0 } });
  draw();
  const p2 = rt.perf();
  if (p2.sprites !== 0 || p2.dots !== 0)
    return { ok: false, info: `空帧却记了 ${p2.sprites} 精灵 / ${p2.dots} 点（计数在数别的东西）` };
  return { ok: true, info: `3 个实体都进了绘制路径（精灵×${p1.sprites}）、玩家画在 ` +
                           `(${scr[0].toFixed(0)},${scr[1].toFixed(0)})；反向：空帧 0 个` };
});

check('F32 自身状态上 HUD（血量/饥饿/理智/背包）—— 且「没数据」要显示 — 不是 NaN', () => {
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient();
  const rt = env.__rt;
  // ① 正常一帧：服务端推来 me
  rt.feed({ me: { ok: true, health: 120, maxhealth: 150, hunger: 80, maxhunger: 150,
                  sanity: 200, maxsanity: 200, used: 2, slots: 15,
                  items: [{ p: 'log', n: 3 }, { p: 'twigs', n: 1 }] } });
  const st = rt.state();
  if (st.health !== 120 || st.hunger !== 80 || st.sanity !== 200)
    return { ok: false, info: '数值没进来：' + JSON.stringify(st) };
  const t = rt.stateText();
  for (const want of ['♥ 120/150', '🍖 80/150', '🧠 200/200', '背包 2/15', 'log×3', 'twigs']) {
    if (t.indexOf(want) < 0) return { ok: false, info: 'HUD 上没有「' + want + '」：' + t };
  }
  // ★ 数量为 1 时不该写 ×1（噪音）；这条同时证明聚合没把 n 丢掉
  if (t.indexOf('twigs×1') >= 0) return { ok: false, info: '×1 也写出来了：' + t };

  // ② 反向：字段缺失（服务端还没算出来）⇒ 必须显示 —，**不许 NaN/undefined**
  rt.feed({ me: { ok: false, why: '还没算出来' } });
  const t2 = rt.stateText();
  if (/NaN|undefined|null/.test(t2)) return { ok: false, info: '缺数据时 HUD 出现 NaN/undefined：' + t2 };
  if (t2.indexOf('♥ —') < 0) return { ok: false, info: '缺数据时没显示 —：' + t2 };

  // ③ 反向：字段类型不对（服务端改坏了）⇒ 同样降级成 —，不传染成 NaN
  rt.feed({ me: { ok: true, health: '150', maxhealth: null, hunger: 12 } });
  const t3 = rt.stateText();
  if (/NaN|undefined/.test(t3)) return { ok: false, info: '坏类型被拼成了 NaN：' + t3 };

  // ④ 节流：一次 actTick 只发一条 me（血/饿是秒级的量，不按帧推）
  env.__sent.length = 0;
  rt.actTick(5000);
  const mes = env.__sent.filter((s) => s.indexOf('"cmd":"me"') >= 0);
  if (mes.length !== 1) return { ok: false, info: '一次节拍发了 ' + mes.length + ' 条 me（应为 1）' };
  rt.actTick(5100);                            // 0.5 s 内再 tick ⇒ 不该再发
  const mes2 = env.__sent.filter((s) => s.indexOf('"cmd":"me"') >= 0);
  if (mes2.length !== 1) return { ok: false, info: '0.5 s 内重复发了 me（' + mes2.length + ' 条）' };

  return { ok: true, info: '♥/🍖/🧠/背包 都上屏 ✔ / 缺数据显示 — ✔ / 坏类型不传染 ✔ / 0.5 s 一条 ✔' };
});

check('F33 合成面板（B2）：列表真的渲染出来 · 点可造的才发请求；反向：点置灰的零请求且说出缺什么', async () => {
  // 这条判据存在的理由：B2 之前，客户端**没有任何一处**能走到 `fetch` 那条路
  // （沙箱里连 fetch 都没有）—— 也就是说「编辑器/合成面板的请求链」在 Node 侧
  // 从来没被跑过，全靠人眼看浏览器。P62 那次「闸门全绿但 31 条判据红」就是
  // 同一类缺口：闸门覆盖不到的地方，等于没有守护。
  const mod = require('../rt/perf_lib.js');
  const env = mod.makeClient({
    fetchReply: (u) => {
      if (u.indexOf('/editor/recipes') >= 0) {
        return { ok: true, total: 1122, valid: 933, skipped: 35, craftable: 1, n: 3, ms: 4.1,
                 items: [
                   { name: 'campfire', product: 'campfire', ingredients: 'cutgrass:3,log:2', can: true },
                   { name: 'axe', product: 'axe', ingredients: 'twigs:1,flint:1', can: false },
                   { name: 'torch', product: 'torch', ingredients: 'cutgrass:2,twigs:2', can: false },
                 ] };
      }
      if (u.indexOf('/editor/craft') >= 0) {
        return { ok: true, recipe: 'campfire', ents_before: 27, ents_after: 31, x: 1.2, z: 0 };
      }
      return null;
    },
  });
  const rt = env.__rt;
  if (!rt || !rt.craft) return { ok: false, info: '__rt.craft 钩子不存在' };
  const el = (id) => (env.__els || {})[id];
  const fetched = () => (env.__fetched || []);

  rt.craft.toggle(true);
  await tick(6);

  if (!fetched().some((u) => u.indexOf('/editor/recipes') >= 0)) {
    return { ok: false, info: '打开面板没有请求配方列表（请求过：' + JSON.stringify(fetched()) + '）' };
  }
  const list = el('craftList');
  if (!list) return { ok: false, info: '拿不到 #craftList' };
  if (list.children.length !== 3) {
    return { ok: false, info: '列表渲染了 ' + list.children.length + ' 行，期望 3 行' };
  }
  const row0 = list.children[0], row1 = list.children[1];
  if (!/\byes\b/.test(row0.className)) return { ok: false, info: '可造那行没有 yes 类：' + row0.className };
  if (!/\bno\b/.test(row1.className)) return { ok: false, info: '不可造那行没有 no 类：' + row1.className };

  // 反向①：点置灰的**不许发请求**（发了就等于「客户端说不能造、服务端还要试一次」）
  const n0 = fetched().length;
  row1.onclick();
  await tick(3);
  if (fetched().length !== n0) {
    return { ok: false, info: '点了置灰配方仍然发了请求：' + fetched()[n0] };
  }
  const msg1 = el('craftMsg').textContent;
  if (msg1.indexOf('材料不足') < 0 || msg1.indexOf('twigs:1') < 0) {
    return { ok: false, info: '点了置灰配方，提示没说清缺什么：' + msg1 };
  }

  // 正向：点可造的 ⇒ 恰好一次请求且带对配方名
  row0.onclick();
  await tick(6);
  const craftReq = fetched().filter((u) => u.indexOf('/editor/craft') >= 0);
  if (craftReq.length !== 1) {
    return { ok: false, info: '点可造配方发了 ' + craftReq.length + ' 次合成请求（期望 1）' };
  }
  if (craftReq[0].indexOf('recipe=campfire') < 0) {
    return { ok: false, info: '合成请求没带对配方名：' + craftReq[0] };
  }
  if (el('craftMsg').textContent.indexOf('造出') < 0) {
    return { ok: false, info: '合成成功后没有成功提示：' + el('craftMsg').textContent };
  }

  return { ok: true, info: '3 行渲染 ✔ / 可造 yes 与置灰 no 分得开 ✔ / 点置灰零请求且说缺 twigs:1 ✔ / 点可造 1 次请求且 recipe=campfire ✔' };
});

check('F34 编辑器撤销按钮（M1-1）：点撤销/重做真的发请求 · 状态栏回显服务端的事实；反向：栈空显示失败不显示成功', async () => {
  // 为什么这条必须存在：E18 验的是**服务端**能不能撤销，而用户是按**按钮**的。
  //   中间那一段（按钮 → 请求 → 状态栏）在 B6 之前完全没有判据 ——
  //   按钮没绑上、绑错端点、把 400 当成成功，三种错在 E18 里全都看不出来。
  const mod = require('../rt/perf_lib.js');
  let undoReply = { ok: false, error: '没有可撤销的操作', empty: true };
  const env = mod.makeClient({
    fetchReply: (u) => {
      if (u.indexOf('/editor/entities') >= 0) return { ok: true, count: 0, listed: 0, items: [] };
      if (u.indexOf('/editor/undo') >= 0) return undoReply;
      if (u.indexOf('/editor/redo') >= 0) return { ok: true, kind: 'move', target: 7, to: { x: 9, z: 4 }, undo_depth: 1 };
      return null;
    },
  });
  const el = (id) => (env.__els || {})[id];
  const fetched = () => (env.__fetched || []);
  const rt = env.__rt;

  // 编辑器关着的时候按撤销：不许发请求，要提示先打开
  const btn = el('edUndo');
  if (!btn) return { ok: false, info: '拿不到 #edUndo（按钮没渲染出来）' };
  if (typeof btn.onclick !== 'function') return { ok: false, info: '#edUndo 没绑 onclick' };
  const n0 = fetched().length;
  btn.onclick();
  await tick(3);
  if (fetched().length !== n0) {
    return { ok: false, info: '编辑器没打开时按撤销仍然发了请求' };
  }
  if (el('edStatus').textContent.indexOf('F1') < 0) {
    return { ok: false, info: '编辑器没打开时按撤销，状态栏没有提示：' + el('edStatus').textContent };
  }

  // 打开编辑器
  const edrt = rt.ed || null;
  if (edrt && typeof edrt.toggle === 'function') edrt.toggle(true);
  else {
    // 没有暴露钩子时退化成"直接派发按钮"—— 用 edBtn 的 onclick 打开
    const edBtn = el('edBtn');
    if (edBtn && typeof edBtn.onclick === 'function') edBtn.onclick();
  }
  await tick(4);

  // ① 栈空：显示失败，不许显示成功
  btn.onclick();
  await tick(4);
  const s1 = el('edStatus').textContent;
  if (s1.indexOf('没有可撤销') < 0) {
    return { ok: false, info: '栈空时状态栏没有回显服务端的原因：' + s1 };
  }
  if (s1.indexOf('已撤销') >= 0) {
    return { ok: false, info: '栈空时状态栏竟然显示「已撤销」：' + s1 };
  }

  // ② 成功：状态栏要回显**服务端给的事实**（kind/target/落点）
  undoReply = { ok: true, kind: 'move', target: 23, to: { x: 1, z: 2 }, undo_depth: 0 };
  btn.onclick();
  await tick(4);
  const s2 = el('edStatus').textContent;
  for (const frag of ['已撤销', 'move', '23', '(1,2)']) {
    if (s2.indexOf(frag) < 0) {
      return { ok: false, info: '撤销成功的状态栏缺「' + frag + '」：' + s2 };
    }
  }

  // ③ 重做
  const redo = el('edRedo');
  if (!redo || typeof redo.onclick !== 'function') return { ok: false, info: '#edRedo 没绑 onclick' };
  redo.onclick();
  await tick(4);
  const s3 = el('edStatus').textContent;
  if (s3.indexOf('已重做') < 0) return { ok: false, info: '重做之后状态栏不对：' + s3 };
  if (!fetched().some((u) => u.indexOf('/editor/redo') >= 0)) {
    return { ok: false, info: '点重做没有发出 /editor/redo' };
  }

  return { ok: true, info: '关着编辑器不发请求且提示按 F1 ✔ / 栈空回显原因且不显示成功 ✔ / 成功回显 kind#target 与落点 ✔ / 重做走对端点 ✔' };
});

check('F35 音频后端（H1）：懒创建只一次 · 未解锁不发声但记账 · 解锁后真的 start · 音源缓存 · 声部上限', () => {
  // 为什么这条判据非有不可：这个仓库**一个音频资产都没有**，也就是说
  // "有没有声音"这件事在 F35 之前完全没有任何证据 —— 代码写了、没写、接没接上，
  // 三种状态在浏览器里看起来都像"安静"。而"安静"恰恰是最难注意到的失败。
  //
  // 判据分两段，因为它们失败的原因完全不同：
  //   ① 环境不支持（没有 AudioContext）⇒ 必须**静默降级**，不许抛异常拖垮页面；
  //   ② 环境支持但未解锁 ⇒ 必须**记账**（denied），不许假装播过、也不许排队。
  const path = require('path');
  const audioPath = path.join(__dirname, '..', 'rt', 'audio.js');
  delete require.cache[require.resolve(audioPath)];

  // ---- ① 没有 AudioContext 的环境
  const savedAC = global.AudioContext;
  delete global.AudioContext;
  if (global.webkitAudioContext) delete global.webkitAudioContext;
  const AE0 = require(audioPath).AudioEngine;
  AE0._resetForTest();
  if (AE0.ensure() !== null) return { ok: false, info: '没有 AudioContext 时 ensure() 竟然返回了东西' };
  if (AE0.play('ui.click') !== null) return { ok: false, info: '没有音频环境时 play() 竟然返回了 id' };
  if (AE0.stats().denied < 1) return { ok: false, info: '没有音频环境时 play() 没有被记账（denied=0）' };

  // ---- ② 桩一个 AudioContext
  const calls = { osc: 0, start: 0, stop: 0, connect: 0, gain: 0 };
  function StubParam(v) {
    this.value = v;
    this.setValueAtTime = () => this;
    this.exponentialRampToValueAtTime = () => this;
  }
  function StubCtx() {
    this.state = 'suspended';
    this.currentTime = 0;
    this.destination = { name: 'dest' };
    this.resume = () => { this.state = 'running'; };
  }
  StubCtx.prototype.createGain = function () {
    calls.gain++;
    return { gain: new StubParam(1), connect: () => { calls.connect++; } };
  };
  StubCtx.prototype.createOscillator = function () {
    calls.osc++;
    const self = this;
    return {
      type: 'sine',
      frequency: new StubParam(440),
      connect: () => { calls.connect++; },
      start: () => { calls.start++; },
      stop: () => { calls.stop++; },
    };
  };
  global.AudioContext = StubCtx;

  delete require.cache[require.resolve(audioPath)];
  const AE = require(audioPath).AudioEngine;
  AE._resetForTest();

  // 懒创建只一次
  const c1 = AE.ensure();
  const c2 = AE.ensure();
  if (!c1 || c1 !== c2) return { ok: false, info: 'ensure() 两次拿到的不是同一个 ctx' };
  if (AE.stats().created !== 1) return { ok: false, info: 'created = ' + AE.stats().created + '（应恒为 1）' };

  // 未解锁：不发、记账、不抛
  const before = AE.stats();
  const v0 = AE.play('act.chop');
  if (v0 !== null) return { ok: false, info: '未解锁时 play() 返回了 id' };
  if (calls.start !== 0) return { ok: false, info: '未解锁时竟然调了 osc.start（浏览器里会被静默忽略，但这里不该发生）' };
  if (AE.stats().denied !== before.denied + 1) {
    return { ok: false, info: '未解锁的播放请求没被记账（denied 没 +1）' };
  }

  // 解锁后：真的发声
  if (AE.unlock() !== true) return { ok: false, info: 'unlock() 返回 false' };
  if (!AE.isUnlocked()) return { ok: false, info: 'unlock() 之后 isUnlocked() 仍是 false' };
  const v1 = AE.play('act.chop');
  if (v1 === null) return { ok: false, info: '解锁后 play() 仍返回 null' };
  if (calls.start !== 1) return { ok: false, info: '解锁后 osc.start 被调了 ' + calls.start + ' 次（应 1）' };
  if (AE.stats().plays !== 1) return { ok: false, info: 'plays = ' + AE.stats().plays + '（应 1）' };

  // 音源缓存：同名字第二次不该再 miss
  const m1 = AE.stats();
  AE.play('act.chop');
  const m2 = AE.stats();
  if (m2.decodeMisses !== m1.decodeMisses) {
    return { ok: false, info: '同名音源第二次仍然 decodeMiss（缓存没命中）' };
  }
  if (m2.decodeHits !== m1.decodeHits + 1) {
    return { ok: false, info: '同名音源第二次没有记 decodeHit（hits=' + m2.decodeHits + '）' };
  }

  // stop
  const s0 = AE.stats().stops;
  if (AE.stop(v1) !== true) return { ok: false, info: 'stop() 返回 false' };
  if (AE.stats().stops !== s0 + 1) return { ok: false, info: 'stop() 没记账' };

  // 声部上限：超了要丢最旧的，不是无限堆
  for (let i = 0; i < 40; i++) AE.play('ui.click');
  const st = AE.stats();
  if (st.voices > 24) return { ok: false, info: '同时声部数 ' + st.voices + '，超过上限 24 没被裁剪' };
  if (st.dropped <= 0) return { ok: false, info: '超上限却没记 dropped' };

  // 静音：master.gain 归零，但仍允许播放（静音不等于停止）
  AE.setMuted(true);
  if (AE.stats().muted !== true) return { ok: false, info: 'setMuted(true) 没生效' };
  const v2 = AE.play('ui.click');
  if (v2 === null) return { ok: false, info: '静音状态下 play() 返回 null（静音不等于停止播放）' };

  // 还原全局，免得影响后面的判据
  if (savedAC === undefined) delete global.AudioContext; else global.AudioContext = savedAC;

  return { ok: true, info: '无环境静默降级 ✔ / 懒创建 1 次 ✔ / 未解锁 accounts denied 且不 start ✔ / 解锁后 start ✔ / 同名音源走缓存 ✔ / stop 记账 ✔ / 声部上限 24 裁剪 ' + st.dropped + ' 个 ✔ / 静音仍可播 ✔' };
});

check('F36 音效接线（H1）：按目标动作选音 · 掉血与死亡选不同的音；反向：首帧不掉血不许响、血量上升不许响', async () => {
  // F35 验的是 AudioEngine 自己（懒创建/解锁/缓存/上限）。
  // 这条验**接线**：客户端在什么时候播哪个音。两者失败原因完全不同 ——
  // 引擎全对但一处都没接上，用户在浏览器里听到的仍然是"安静"。
  const path = require('path');
  const audioPath = path.join(__dirname, '..', 'rt', 'audio.js');
  delete require.cache[require.resolve(audioPath)];

  const calls = { start: 0 };
  function StubParam(v) { this.value = v; this.setValueAtTime = () => this; this.exponentialRampToValueAtTime = () => this; }
  function StubCtx() { this.state = 'suspended'; this.currentTime = 0; this.destination = {}; this.resume = () => { this.state = 'running'; }; }
  StubCtx.prototype.createGain = function () { return { gain: new StubParam(1), connect: () => {} }; };
  StubCtx.prototype.createOscillator = function () {
    return { type: 'sine', frequency: new StubParam(440), connect: () => {},
             start: () => { calls.start++; }, stop: () => {} };
  };
  const saved = global.AudioContext;
  global.AudioContext = StubCtx;

  const AE = require(audioPath).AudioEngine;
  AE._resetForTest();
  AE.ensure();
  AE.unlock();
  const n0 = AE.stats().plays;

  const mod = require('../rt/perf_lib.js');
  const mkEnv = () => mod.makeClient({
    audio: AE,
    // 每次都用**新的沙箱**：`ACT.pick` 的更新有节流，同一个沙箱里连换三次目标
    // 拿到的仍是第一个 pick（首跑就是这么错的，报出来却是"音效计数没 +1"）。
    fetchReply: (u) => (u.indexOf('/editor/entities') >= 0 ? { ok: true, count: 0, listed: 0, items: [] } : { ok: true }),
  });

  // ① 动作：CHOP / PICKUP / ATTACK 要发不同的音
  const cases = [
    [{ id: 1, a: 'CHOP' }, 'act.chop'],
    [{ id: 2, a: 'PICKUP' }, 'act.pickup'],
    [{ id: 3, a: 'ATTACK' }, 'act.hit'],
  ];
  for (const [tgt, want] of cases) {
    const before = AE.stats().byName[want] || 0;
    const e = mkEnv();
    e.__rt.setTargets([tgt]);
    e.__rt.actTick(2e9);                       // 让 actPoll 挑出 pick
    e.__rt.actKey(true);
    e.__rt.actKey(false);
    const after = AE.stats().byName[want] || 0;
    if (after !== before + 1) {
      return { ok: false, info: '动作 ' + tgt.a + ' 之后 ' + want + ' 的计数没 +1（byName=' + JSON.stringify(AE.stats().byName) + '）' };
    }
  }
  const env = mkEnv();
  const rt = env.__rt;

  // ② 掉血：150 → 120 要发 player.hurt
  const h0 = AE.stats().byName['player.hurt'] || 0;
  // 用 feed 模拟服务端推 me 消息（与真实路径一致）
  rt.feed({ me: { ok: true, health: 150, maxhealth: 150 } });
  await tick(2);
  const hMid = AE.stats().byName['player.hurt'] || 0;
  if (hMid !== h0) {
    return { ok: false, info: '首帧（没有旧值可比较）就播了受伤音 —— 会一进游戏就响一下' };
  }
  rt.feed({ me: { ok: true, health: 120, maxhealth: 150 } });
  await tick(2);
  const h1 = AE.stats().byName['player.hurt'] || 0;
  if (h1 !== h0 + 1) {
    return { ok: false, info: '掉血 150→120 没有播 player.hurt（byName=' + JSON.stringify(AE.stats().byName) + '）' };
  }

  // ③ 反向：血量回升不许响
  rt.feed({ me: { ok: true, health: 140, maxhealth: 150 } });
  await tick(2);
  if ((AE.stats().byName['player.hurt'] || 0) !== h1) {
    return { ok: false, info: '血量回升也播了受伤音' };
  }

  // ④ 死亡：归零播 player.die
  const d0 = AE.stats().byName['player.die'] || 0;
  rt.feed({ me: { ok: true, health: 0, maxhealth: 150 } });
  await tick(2);
  if ((AE.stats().byName['player.die'] || 0) !== d0 + 1) {
    return { ok: false, info: '血量归零没有播 player.die（byName=' + JSON.stringify(AE.stats().byName) + '）' };
  }

  if (saved === undefined) delete global.AudioContext; else global.AudioContext = saved;
  const names = AE.stats().byName;
  return { ok: true, info: 'CHOP/PICKUP/ATTACK 各发不同的音 ✔ / 首帧不响 ✔ / 掉血播 hurt ✔ / 回升不响 ✔ / 归零播 die ✔ / byName=' + JSON.stringify(names) };
});

check('F37 场景导出/导入（C4）：导出填文本框并展开 · 导入**只发一个原子 POST**（不许再发 clear、文本不许进 URL）；反向：空文本零请求 · 导入失败要说服务端原因', async () => {
  // E22 验的是服务端往返，用户按的是**按钮**。中间那段（按钮 → 请求顺序 → 文本框 → 状态栏）
  // 在 F37 之前没有判据。最容易错的一处不是"发不发请求"，而是**顺序**：
  // 先 import 后 clear 的话，导入的实体紧接着被自己清掉，用户看到空世界，
  // 而状态栏还会显示"已导入 14 个实体"。
  const mod = require('../rt/perf_lib.js');
  const TEXT = 'evergreen\t1.000\t2.000\nrocks\t3.000\t4.000';
  let importReply = { ok: true, made: 2 };
  const env = mod.makeClient({
    fetchReply: (u) => {
      if (u.indexOf('/editor/entities') >= 0) return { ok: true, count: 0, listed: 0, items: [] };
      if (u.indexOf('/editor/scene_export') >= 0) return { ok: true, n: 2, version: 1, text: TEXT };
      if (u.indexOf('/editor/scene_clear') >= 0) return { ok: true, removed: 7 };
      if (u.indexOf('/editor/scene_import') >= 0) return importReply;
      return null;
    },
  });
  const el = (id) => (env.__els || {})[id];
  const fetched = () => (env.__fetched || []);
  const rt = env.__rt;
  if (!rt || !rt.scene) return { ok: false, info: '__rt.scene 钩子不存在' };

  // 编辑器关着：三个按钮都不许发请求
  for (const id of ['edSceneOut', 'edSceneIn', 'edSceneClear']) {
    const b = el(id);
    if (!b || typeof b.onclick !== 'function') return { ok: false, info: '#' + id + ' 没绑 onclick' };
  }
  const n0 = fetched().length;
  el('edSceneOut').onclick();
  await tick(3);
  if (fetched().length !== n0) return { ok: false, info: '编辑器没打开时按「场景↓」仍然发了请求' };

  // 打开编辑器
  const edBtn = el('edBtn');
  if (edBtn && typeof edBtn.onclick === 'function') edBtn.onclick();
  await tick(4);
  if (!rt.ed || !rt.ed.state || !rt.ed.state().on) {
    // 兜底：直接调 toggle
    if (rt.ed && typeof rt.ed.toggle === 'function') rt.ed.toggle(true);
  }
  await tick(3);

  // ① 导出：文本框被填、面板展开、状态栏有数量
  el('edSceneOut').onclick();
  await tick(5);
  if (!fetched().some((u) => u.indexOf('/editor/scene_export') >= 0)) {
    return { ok: false, info: '按「场景↓」没有请求 /editor/scene_export' };
  }
  if (rt.scene.text() !== TEXT) {
    return { ok: false, info: '导出之后文本框内容是 ' + JSON.stringify(rt.scene.text()) + '，期望与返回的 text 一致' };
  }
  const box = el('edSceneBox');
  if (!box || !/\bon\b/.test(box.className)) {
    return { ok: false, info: '导出之后场景面板没有展开（class=' + (box && box.className) + '）' };
  }
  if ((el('edStatus').textContent || '').indexOf('2') < 0) {
    return { ok: false, info: '导出后状态栏没写导出了几个：' + el('edStatus').textContent };
  }

  // ② 导入：**只发一个 import**，清空交给服务端在导入内部原子完成
  //
  // ★★ C3b（2026-10-22）换了契约，这条判据也跟着换：
  //   原来是「先 clear 后 import」两个请求 —— 那中间失败会留下一个空世界，
  //   而且占两步撤销。现在服务端 `scene_import` 自己负责清空（原子、一步可撤销），
  //   客户端再发 clear 就是**多余且危险**的（多发一次 clear = 多一步撤销 + 多一个空窗）。
  //   ⇒ 断言从"顺序对"改成"**根本不许发 clear**"。判据守的是"一次编辑一次请求"。
  fetched().length = 0;
  el('edSceneIn').onclick();
  await tick(6);
  if (fetched().some((u) => u.indexOf('/editor/scene_clear') >= 0)) {
    return { ok: false, info: '导入时仍然先发了 scene_clear（清空已由服务端原子完成，多发一次会多一步撤销）：' + JSON.stringify(fetched()) };
  }
  const idxImport = fetched().findIndex((u) => u.indexOf('/editor/scene_import') >= 0);
  if (idxImport < 0) {
    return { ok: false, info: '导入没有发出 scene_import：' + JSON.stringify(fetched()) };
  }
  const impUrl = fetched()[idxImport];
  // ★★ C3c：导入改走 **POST + JSON body**，文本**不该再出现在 URL 里**。
  //   断言随之从"URL 里带不带 text"改成"body 里有没有、URL 里有没有"——
  //   两边都要断言：只断 body 会漏掉"URL 里还在塞文本"，只断 URL 会漏掉"body 是空的"。
  if (impUrl.indexOf('text=') >= 0) {
    return { ok: false, info: '导入仍然把文本塞在 URL 里（会在上百实体时撞长度上限）：' + impUrl };
  }
  const posted = (env.__posted || []).filter((x) => x.url.indexOf('/editor/scene_import') >= 0);
  if (posted.length !== 1) {
    return { ok: false, info: '导入没有发出带 body 的 POST（记录到 ' + posted.length + ' 次）' };
  }
  if (posted[0].method !== 'POST') {
    return { ok: false, info: '导入请求的方法不是 POST：' + posted[0].method };
  }
  let jb = null;
  try { jb = JSON.parse(posted[0].body); } catch (e) { jb = null; }
  if (!jb || typeof jb.text !== 'string') {
    return { ok: false, info: '导入 body 不是 {"text": string}：' + posted[0].body };
  }
  if (jb.text.indexOf('evergreen') < 0) {
    return { ok: false, info: '导入 body 里的文本不是导出内容：' + jb.text.slice(0, 60) };
  }
  if ((el('edStatus').textContent || '').indexOf('已导入 2') < 0) {
    return { ok: false, info: '导入成功后状态栏不对：' + el('edStatus').textContent };
  }

  // ③ 反向：空文本 ⇒ 零请求
  rt.scene.box(true);
  const ta = el('edSceneText');
  if (ta) ta.value = '';
  fetched().length = 0;
  el('edSceneIn').onclick();
  await tick(4);
  if (fetched().length !== 0) {
    return { ok: false, info: '文本框为空时按导入仍然发了请求：' + JSON.stringify(fetched()) };
  }
  if ((el('edStatus').textContent || '').indexOf('空') < 0) {
    return { ok: false, info: '文本框为空时没提示：' + el('edStatus').textContent };
  }

  // ④ 反向：导入失败必须显示服务端原因，不许显示"已导入"
  if (ta) ta.value = 'bad\tline';
  importReply = { ok: false, error: '第 1 行格式不对（要 prefab\\tx\\tz）：bad' };
  fetched().length = 0;
  el('edSceneIn').onclick();
  await tick(6);
  const s4 = el('edStatus').textContent || '';
  if (s4.indexOf('第 1 行') < 0) {
    return { ok: false, info: '导入失败时没有回显服务端原因：' + s4 };
  }
  if (s4.indexOf('已导入') >= 0) {
    return { ok: false, info: '导入失败却显示「已导入」：' + s4 };
  }

  return { ok: true, info: '关着编辑器零请求 ✔ / 导出填文本框+展开+写数量 ✔ / 导入单请求 POST，文本在 body 里（URL 无 text、无 clear）✔ / 空文本零请求 ✔ / 失败回显第 1 行原因且不假称成功 ✔' };
});

check('F38 场景落盘 UI（C3）：空名字零请求 · 存盘回显盘上字节数并刷新列表 · 读取失败要把「已清空 N 个」一起说出来', async () => {
  // E28 验服务端能存能读，用户按的是按钮。中间那段（空名字拦不拦、回显的是谁的数字、
  // 读取失败时世界已经空了却只报原因）在 F38 之前没有判据。
  // ★ 最后一条最要紧：读取失败时世界**已经被清空** —— 只报"场景不存在"会把
  //   "我把你的世界清空了"藏起来，用户接着存盘就会把空世界覆盖掉唯一的存档。
  const mod = require('../rt/perf_lib.js');
  let loadReply = { ok: true, name: 'lv1', made: 14, removed: 14 };
  const env = mod.makeClient({
    fetchReply: (u) => {
      if (u.indexOf('/editor/entities') >= 0) return { ok: true, count: 0, listed: 0, items: [] };
      if (u.indexOf('/editor/scene_save') >= 0) return { ok: true, name: 'lv1', n: 14, bytes: 529, version: 2 };
      if (u.indexOf('/editor/scene_load') >= 0) return loadReply;
      if (u.indexOf('/editor/scene_list') >= 0) return { ok: true, n: 1, names: ['lv1'], dir: 'scenes' };
      return null;
    },
  });
  // ★ 用 `env.document.getElementById` 而不是直接读 `env.__els[id]`：
  //   桩是**按需创建**元素的，直接读 `__els` 只能拿到"已经被取过"的那些 ——
  //   `#edSceneName` 只在点按钮时才被取（`sceneName()` 里），所以直接读会假报"不存在"。
  //   这是桩的惰性语义带来的第三个坑（前两个是 className 不同步、innerHTML 不清子节点）。
  const el = (id) => env.document.getElementById(id);
  const fetched = () => (env.__fetched || []);
  const rt = env.__rt;
  if (!rt || !rt.scene || typeof rt.scene.save !== 'function') {
    return { ok: false, info: '__rt.scene.save 钩子不存在' };
  }
  for (const id of ['edSceneSave', 'edSceneLoad', 'edSceneName']) {
    if (!el(id)) return { ok: false, info: '#' + id + ' 不存在（按钮/输入框没渲染出来）' };
  }

  // 打开编辑器
  const edBtn = el('edBtn');
  if (edBtn && typeof edBtn.onclick === 'function') edBtn.onclick();
  await tick(4);
  if (rt.ed && typeof rt.ed.toggle === 'function' && (!rt.ed.state || !rt.ed.state().on)) {
    rt.ed.toggle(true);
  }
  await tick(3);

  // ① 空名字：零请求
  el('edSceneName').value = '   ';
  fetched().length = 0;
  el('edSceneSave').onclick();
  await tick(4);
  if (fetched().length !== 0) {
    return { ok: false, info: '名字为空时仍然发了请求：' + JSON.stringify(fetched()) };
  }
  if ((el('edStatus').textContent || '').indexOf('名字') < 0 && (el('edStatus').textContent || '').indexOf('场景名') < 0) {
    return { ok: false, info: '名字为空时没提示：' + el('edStatus').textContent };
  }

  // ② 存盘：请求带编码名字，回显盘上字节数，并刷新列表
  el('edSceneName').value = '关卡 1';
  fetched().length = 0;
  el('edSceneSave').onclick();
  await tick(6);
  const saveUrl = fetched().find((u) => u.indexOf('/editor/scene_save') >= 0);
  if (!saveUrl) return { ok: false, info: '点存盘没有发出 scene_save 请求' };
  if (saveUrl.indexOf('name=') < 0) return { ok: false, info: '存盘请求没带 name：' + saveUrl };
  if (saveUrl.indexOf('%') < 0 && saveUrl.indexOf(' ') >= 0) {
    return { ok: false, info: '名字里有空格却没编码：' + saveUrl };
  }
  const s2 = el('edStatus').textContent || '';
  if (s2.indexOf('529') < 0) {
    return { ok: false, info: '存盘后状态栏没有回显盘上字节数（529）：' + s2 };
  }
  if (!fetched().some((u) => u.indexOf('/editor/scene_list') >= 0)) {
    return { ok: false, info: '存盘之后没有刷新场景列表' };
  }

  // ③ 读取成功
  el('edSceneName').value = 'lv1';
  el('edSceneLoad').onclick();
  await tick(6);
  const s3 = el('edStatus').textContent || '';
  if (s3.indexOf('已读取') < 0) return { ok: false, info: '读取成功后状态栏不对：' + s3 };

  // ④ 读取失败：必须同时说出「已清空 N 个」
  loadReply = { ok: false, error: '导入失败（世界已被清空）：第 2 行格式不对', removed: 14 };
  fetched().length = 0;
  el('edSceneLoad').onclick();
  await tick(6);
  const s4 = el('edStatus').textContent || '';
  if (s4.indexOf('第 2 行') < 0) {
    return { ok: false, info: '读取失败没有回显服务端原因：' + s4 };
  }
  if (s4.indexOf('14') < 0) {
    return { ok: false, info: '读取失败时没有说出「已清空 14 个实体」—— 用户会以为世界还在：' + s4 };
  }
  if (s4.indexOf('已读取') >= 0) {
    return { ok: false, info: '读取失败却显示「已读取」：' + s4 };
  }

  return { ok: true, info: '空名字零请求且提示 ✔ / 存盘带编码名字+回显 529 字节+刷新列表 ✔ / 读取成功回显 ✔ / 失败时同时说「已清空 14 个」与原因 ✔' };
});

check('F39 删除提示（C2）：摘掉子实体要说出来 · 反向：没摘就别说 · 失败要给原因', async () => {
  // E33 验服务端会回报 detached，用户看到的却是**状态栏**。
  // 这条判据守的是"说了没有"：数字对了但界面不说，等于没做 ——
  // 删一个容器后里面的东西变孤儿，屏幕上完全看不出来。
  const mod = require('../rt/perf_lib.js');
  let removeReply = { ok: true, guid: 7, prefab: 'chest', removed: true, detached: 2 };
  const env = mod.makeClient({
    fetchReply: (u) => {
      if (u.indexOf('/editor/entities') >= 0) return { ok: true, count: 0, listed: 0, items: [] };
      if (u.indexOf('/editor/remove') >= 0) return removeReply;
      return null;
    },
  });
  const el = (id) => env.document.getElementById(id);
  const rt = env.__rt;
  if (!rt || !rt.ed || typeof rt.ed.remove !== 'function') {
    return { ok: false, info: '__rt.ed.remove 钩子不存在（判据没法驱动删除）' };
  }
  if (typeof rt.ed.status !== 'function') {
    return { ok: false, info: '__rt.ed.status 钩子不存在' };
  }

  // ① detached=2 ⇒ 状态栏必须说"摘掉 2 个"
  rt.ed.remove(7);
  await tick(6);
  const s1 = rt.ed.status();
  if (s1.indexOf('摘掉 2') < 0) {
    return { ok: false, info: '删掉一个带 2 个子实体的父实体，状态栏没说摘掉了几个：' + s1 };
  }
  if (s1.indexOf('已删除') < 0) {
    return { ok: false, info: '删除成功的状态栏不对：' + s1 };
  }

  // ② 反向：detached=0 ⇒ 不许出现"摘掉"
  removeReply = { ok: true, guid: 8, prefab: 'evergreen', removed: true, detached: 0 };
  rt.ed.remove(8);
  await tick(6);
  const s2 = rt.ed.status();
  if (s2.indexOf('摘掉') >= 0) {
    return { ok: false, info: '没有子实体却提示「摘掉」：' + s2 };
  }
  if (s2.indexOf('已删除') < 0) {
    return { ok: false, info: '删除成功但状态栏没有「已删除」：' + s2 };
  }

  // ③ 反向：失败要原样给原因
  removeReply = { ok: false, error: '拒绝删除玩家实体：会破坏会话身份（key→角色）' };
  rt.ed.remove(9);
  await tick(6);
  const s3 = rt.ed.status();
  if (s3.indexOf('拒绝删除玩家实体') < 0) {
    return { ok: false, info: '删除失败没有回显服务端原因：' + s3 };
  }
  if (s3.indexOf('已删除') >= 0) {
    return { ok: false, info: '删除失败却显示「已删除」：' + s3 };
  }

  return { ok: true, info: 'detached=2 时说「摘掉 2 个」✔ / detached=0 时不提 ✔ / 失败回显服务端原因且不假称成功 ✔' };
});

(async () => {
  await Promise.all(PENDING);
  console.log('\n  结果：' + pass + ' 通过 / ' + fail + ' 失败');
  process.exit(fail === 0 ? 0 : 1);
})();
