// test_protocol.js —— 二进制帧协议：往返一致 + 带宽收益（P5）
'use strict';
const P = require('../rt/protocol_bin.js');

let pass = 0, fail = 0;
function check(name, fn) {
  try {
    const r = fn();
    if (r === true || (r && r.ok !== false)) { pass++; console.log('  ✔ ' + name + (r && r.info ? '  ' + r.info : '')); }
    else { fail++; console.log('  ✘ ' + name + (r && r.info ? '  ' + r.info : '')); }
  } catch (e) { fail++; console.log('  ✘ ' + name + '  抛异常: ' + e.message); }
}
// ★ 坐标容差必须按**协议精度**给：二进制版是 1/16 格定点，
//   所以往返误差天然 ≤ 0.0625。第一版我给了 0.02（比精度还严）⇒ 假失败。
const FIX_TOL = 1 / 16 + 1e-9;
const near = (a, b, eps) => Math.abs(a - b) <= (eps === undefined ? FIX_TOL : eps);

console.log('═'.repeat(74));
console.log('  二进制帧协议（往返一致 / 定点精度 / 带宽收益）');
console.log('═'.repeat(74));

// 造一份像真快照的数据（含中文 build 名，验 UTF-8）
function fake(n) {
  const ents = [];
  for (let i = 0; i < n; i++) {
    ents.push({ id: 100 + i * 3, x: ((i * 37) % 200) - 100 + 0.031, z: ((i * 53) % 200) - 100 - 0.047,
                p: 'prefab_' + (i % 7), a: (i % 2 ? 'walk' : 'idle_loop'),
                bld: 'wilson', fr: i % 5, f: (i % 8) * 0.3927 });
  }
  return { t: 123.456, tick: 4096, n: n, iseq: 777,
           ents, player: { id: 100, x: ents[0].x, z: ents[0].z },
           paused: true,                       // ★ bit3：世界已暂停（零字节成本）
           // ★ 世界环境块：故意用**非默认**组合（夜晚 + 冬天 + 负温度，
           //   且三态位只亮 isnight），免得「碰巧等于默认值」掩盖编码错误
           world: { phase: 'night', season: 'winter',
                    isday: false, isdusk: false, isnight: true, temperature: -12.5 } };
}

check('往返一致：JSON 能表示的字段，二进制解回来逐字段相同', () => {
  const snap = fake(50);
  const d = new P.Dict();
  const { bytes } = P.encode(snap, d);
  const back = P.decode(bytes, d);
  if (back.tick !== snap.tick || back.n !== snap.n || back.iseq !== snap.iseq)
    return { ok: false, info: '头部字段不一致' };
  if (!near(back.t, snap.t, 1e-3)) return { ok: false, info: 't 差 ' + (back.t - snap.t) };
  for (let i = 0; i < snap.ents.length; i++) {
    const a = snap.ents[i], b = back.ents[i];
    if (b.id !== a.id) return { ok: false, info: 'id 不一致 @' + i };
    if (!near(b.x, a.x) || !near(b.z, a.z))
      return { ok: false, info: '坐标差 @' + i + ' (' + (b.x - a.x).toFixed(4) + ',' + (b.z - a.z).toFixed(4) + ')' };
    if (b.p !== a.p || b.a !== a.a || b.bld !== a.bld) return { ok: false, info: '字符串不一致 @' + i };
    if (b.fr !== a.fr) return { ok: false, info: '帧号不一致 @' + i };
    if (a.f && !near(b.f, a.f, 0.02)) return { ok: false, info: '朝向差 @' + i };
  }
  // ★ 世界环境块也要逐字段一致
  const w = snap.world, bw = back.world;
  if (!bw) return { ok: false, info: 'world 块没解出来' };
  for (const k of ['phase', 'season', 'isday', 'isdusk', 'isnight'])
    if (bw[k] !== w[k]) return { ok: false, info: 'world.' + k + ' 不一致: ' + bw[k] + ' vs ' + w[k] };
  if (!near(bw.temperature, w.temperature)) return { ok: false, info: '温度差 ' + (bw.temperature - w.temperature) };
  // ★ bit3 暂停位（零字节成本，但不能丢）
  if (back.paused !== snap.paused) return { ok: false, info: 'paused 位丢了: ' + back.paused };
  return { ok: true, info: '50 实体 × 8 字段 + world × 6 字段 + paused 全部一致' };
});

check('暂停位：paused=false 时 bit3 不置位（反向）', () => {
  const snap = fake(5);
  snap.paused = false;
  const d = new P.Dict();
  const bytes = P.encode(snap, d).bytes;
  if (bytes[3] & 8) return { ok: false, info: 'paused=false 却置了 bit3' };
  const back = P.decode(bytes, d);
  if (back.paused !== false) return { ok: false, info: '解出来 paused 不是 false: ' + back.paused };
  // 也确认「暂停位与 world 块互不干扰」
  if (!back.world) return { ok: false, info: 'world 块被暂停位吃掉了' };
  return { ok: true, info: 'bit3 未置位、解出 paused=false、world 块完好' };
});

check('world 块：没有就不发（反向 —— 不该凭空补一个默认世界）', () => {
  const snap = fake(10);
  delete snap.world;
  const d = new P.Dict();
  const bytes = P.encode(snap, d).bytes;
  if (bytes[3] & 4) return { ok: false, info: '没有 world 却置了 bit2' };
  const back = P.decode(bytes, d);
  if ('world' in back) return { ok: false, info: '没有 world 却解出了 ' + JSON.stringify(back.world) };
  if (back.n !== 10 || back.ents[9].p !== snap.ents[9].p)
    return { ok: false, info: '去掉 world 后实体段解错（帧尾对齐被破坏）' };
  return { ok: true, info: 'bit2 未置位、无 world 字段、实体段仍解对' };
});

check('world 块：未知 phase/season 必须给 null，而不是瞎猜一个', () => {
  const snap = fake(3);
  snap.world = { phase: '血月', season: '??', isday: false, isdusk: false,
                 isnight: true, temperature: 0 };
  const d = new P.Dict();
  const back = P.decode(P.encode(snap, d).bytes, d);
  const w = back.world;
  if (!w) return { ok: false, info: 'world 块没解出来' };
  if (w.phase !== null || w.season !== null)
    return { ok: false, info: '未知枚举被解成 ' + w.phase + '/' + w.season + '（应为 null）' };
  if (w.isnight !== true) return { ok: false, info: '三态布尔丢了' };
  return { ok: true, info: '未知 phase/season → null，三态布尔与温度仍保住' };
});

check('定点精度在 1/16 格内（够用且可预期）', () => {
  const snap = fake(1);
  snap.ents[0].x = 12.0313;            // 1/16 = 0.0625 的 1/2
  const d = new P.Dict();
  const back = P.decode(P.encode(snap, d).bytes, d);
  const err = Math.abs(back.ents[0].x - snap.ents[0].x);
  return err <= 1 / 16 + 1e-9 ? { ok: true, info: '误差 ' + err.toFixed(4) + ' ≤ 1/16 格' }
                              : { ok: false, info: '误差 ' + err.toFixed(4) + ' 超出 1/16' };
});

check('字符串字典跨帧累积：第二帧起字符串只花 1 个 varint', () => {
  const d = new P.Dict();
  const s1 = fake(50);
  const b1 = P.encode(s1, d).bytes.length;
  // 同一份数据再编一帧（字符串都已在字典里）
  const b2 = P.encode(fake(50), d).bytes.length;
  if (!(b2 < b1 * 0.75))
    return { ok: false, info: `第二帧 ${b2} 字节 vs 首帧 ${b1}（省得不够）` };
  return { ok: true,
           info: `首帧 ${b1} B → 次帧 ${b2} B（省 ${(100 * (1 - b2 / b1)).toFixed(0)}%）` };
});

check('带宽收益：二进制 vs JSON', () => {
  const snap = fake(200);
  const d = new P.Dict();
  P.encode(snap, d);                       // 首帧建字典
  const bin = P.encode(fake(200), d).bytes.length;
  const json = Buffer.byteLength(JSON.stringify(fake(200)));
  if (!(bin < json))
    return { ok: false, info: `二进制 ${bin} B 没比 JSON ${json} B 小` };
  return { ok: true,
           info: `200 实体：JSON ${json} B → 二进制 ${bin} B（省 ${(100 * (1 - bin / json)).toFixed(0)}%）` };
});

check('反向：坏帧必须抛错（而不是解出垃圾）', () => {
  const cases = [
    ['空缓冲', new Uint8Array([])],
    ['魔数错', new Uint8Array([0x00, 0x00, 2, 3, 0, 0, 0, 0, 0])],
    ['版本错', new Uint8Array([0x52, 0x54, 99, 3, 0, 0, 0, 0, 0])],
  ];
  const d = new P.Dict();
  for (const [name, buf] of cases) {
    try { P.decode(buf, d); return { ok: false, info: name + ' 竟然没抛错' }; }
    catch (e) { /* 期望抛错 */ }
  }
  return { ok: true, info: '3 种坏帧全部抛错 ✔' };
});

check('反向：帧被截断必须抛错', () => {
  const d = new P.Dict();
  const full = P.encode(fake(20), d).bytes;
  for (const cut of [1, 5, 10, Math.floor(full.length / 2)]) {
    try { P.decode(full.slice(0, cut), d); return { ok: false, info: '截到 ' + cut + ' 字节竟没抛错' }; }
    catch (e) { /* 期望 */ }
  }
  return { ok: true, info: '4 种截断长度全部抛错 ✔' };
});

console.log('\n  结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
