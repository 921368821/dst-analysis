// protocol_bin.js —— 二进制帧编解码（P5 / M3）
//
// 与 protocol.md §3 对应。设计要点：
//   · 坐标/朝向用**定点**（1/16 格、1/16 度）⇒ 比 float 省一半，且范围够（±2048 格）
//   · 字符串走**连接级字典**（跨帧累积，本帧只带新增）⇒ 重复的 prefab/anim/build 每帧 1 个 varint
//   · 与 JSON 版**语义必须一致**（同一快照解出来逐字段相同）—— 这条有测试守着
'use strict';

// ★★ L1：常量**不再手写**，全部来自 `rt/protocol.schema.json`（生成物 protocol_schema.js）。
//   原来 MAGIC/VERSION/FIX/PHASES/SEASONS 在 .js 与 .py 里各写一份；两边只改一边的后果是
//   「服务端发 day、客户端解成 night」或「位置缓慢漂移」，而 parity 测试只能抓到
//   「两边不一样」，抓不到「两边一起写错」。单源生成把后者变成不可能。
//   ⚠ 本文件依赖 protocol_schema.js **先加载**（client.html 的 <script> 顺序已保证）；
//     没加载就抛错，绝不静默用错误的默认值。
const _S = (typeof module !== 'undefined' && module.exports)
  ? require('./protocol_schema.js')
  : (typeof window !== 'undefined' ? window.ProtocolSchema : null);
if (!_S) {
  throw new Error('protocol_schema.js 未加载 —— 必须在本文件之前引入（见 client.html）');
}
const MAGIC = _S.MAGIC;          // 'R''T'（0x5254）
const VERSION = _S.VERSION;      // ★ v3 = v2 + 帧尾「世界环境块」（昼夜/季节/温度）
const FIX = _S.FIX;              // 1/16 格
// ★ 昼夜相位 / 季节 用**序数**发（1 字节）；顺序由 schema 单源定义
const PHASES = _S.PHASES;
const SEASONS = _S.SEASONS;

class Writer {
  constructor() { this.b = []; this.n = 0; }
  u8(v) { this.b.push(v & 0xff); this.n++; return this; }
  bytes(a) { for (const x of a) this.b.push(x & 0xff); this.n += a.length; return this; }
  varint(v) {                      // LEB128 无符号
    v = v >>> 0;
    do { let x = v & 0x7f; v >>>= 7; if (v) x |= 0x80; this.b.push(x); this.n++; } while (v);
    return this;
  }
  i16(v) {                          // 定点：1/16 格
    const q = Math.max(-32768, Math.min(32767, Math.round(v * FIX)));
    this.b.push(q & 0xff, (q >> 8) & 0xff); this.n += 2; return this;
  }
  f32(v) {                           // IEEE754 单精度（小端）
    const buf = new DataView(new ArrayBuffer(4));
    buf.setFloat32(0, v, true);
    for (let i = 0; i < 4; i++) this.b.push(buf.getUint8(i));
    this.n += 4; return this;
  }
  out() { return new Uint8Array(this.b); }
}

class Reader {
  constructor(buf) { this.d = new DataView(buf.buffer || buf); this.p = 0; this.buf = buf; }
  u8() { return this.d.getUint8(this.p++); }
  i16() { const q = this.d.getInt16(this.p, true); this.p += 2; return q / FIX; }
  f32() { const v = this.d.getFloat32(this.p, true); this.p += 4; return v; }
  varint() {
    let v = 0, shift = 0;
    for (;;) {
      const x = this.d.getUint8(this.p++);
      v |= (x & 0x7f) << shift;
      if (!(x & 0x80)) break;
      shift += 7;
      if (shift > 35) throw new Error('varint 过长');
    }
    return v >>> 0;
  }
  str(len) { const s = []; for (let i = 0; i < len; i++) s.push(this.d.getUint8(this.p++)); return s; }
}

/** 连接级字典：跨帧累积的字符串表 */
class Dict {
  constructor() { this.list = []; this.idx = new Map(); }
  intern(s) {
    if (s == null || s === '') return 0;
    let i = this.idx.get(s);
    if (i === undefined) { this.list.push(s); i = this.list.length; this.idx.set(s, i); }
    return i;
  }
  // ★ 边界检查同 Python 侧：字典是连接级的，客户端漏掉首帧后
  //   后续帧的索引在本地不存在 ⇒ 返回 null 并**记数**，不要抛下标越界
  get(i) {
    if (!i) return null;
    if (i > this.list.length) { this.misses = (this.misses || 0) + 1; return null; }
    return this.list[i - 1];
  }
  /** 本帧新增了哪些（要写进帧里） */
  fresh(strings) {
    const out = [];
    for (const s of strings) if (s != null && s !== '' && !this.idx.has(s)) out.push(s);
    return out;
  }
}

/** 快照 → 二进制；返回 {bytes, dict} */
function encode(snap, dict) {
  const w = new Writer();
  // 先算本帧新增字符串
  const strs = [];
  for (const e of snap.ents) { strs.push(e.p, e.a, e.bld); }
  const fresh = dict.fresh(strs);
  w.u8(0x52).u8(0x54).u8(VERSION);
  const world = snap.world;
  // bit3 = 世界已暂停（零字节成本，借 flags 里没用的一位）
  const flags = (snap.player ? 1 : 0) | (snap.ents && snap.ents.length ? 2 : 0)
              | (world ? 4 : 0) | (snap.paused ? 8 : 0);
  w.u8(flags);
  w.varint(snap.tick | 0).f32(snap.t).varint(snap.n | 0).varint(snap.iseq | 0);
  w.varint(fresh.length);
  for (const s of fresh) { const b = Writer.utf8(s); w.varint(b.length).bytes(b); dict.intern(s); }
  if (snap.player) {
    w.varint(snap.player.id | 0).i16(snap.player.x).i16(snap.player.z);
  }
  let prev = 0;
  for (const e of snap.ents) {
    w.varint((e.id | 0) - prev); prev = e.id | 0;
    w.i16(e.x).i16(e.z);
    w.varint(dict.intern(e.p)).varint(dict.intern(e.a)).varint(dict.intern(e.bld));
    w.varint(e.fr | 0);
    w.i16((e.f || 0) * (180 / Math.PI));      // 弧度 → 度
  }
  // ---- 世界环境块（可选，**帧尾**）----
  if (world) {
    const pi = PHASES.indexOf(world.phase);
    const si = SEASONS.indexOf(world.season);
    w.u8(pi < 0 ? 255 : pi).u8(si < 0 ? 255 : si);
    w.u8((world.isday ? 1 : 0) | (world.isdusk ? 2 : 0) | (world.isnight ? 4 : 0));
    w.i16(world.temperature || 0);
  }
  return { bytes: w.out(), dict };
}

Writer.utf8 = function (s) {
  const out = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
    else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
  }
  return out;
};

/** 二进制 → 快照 */
function decode(buf, dict) {
  const r = new Reader(buf);
  if (r.u8() !== 0x52 || r.u8() !== 0x54) throw new Error('魔数不对');
  const ver = r.u8();
  if (ver !== VERSION) throw new Error('协议版本不支持: ' + ver);
  const flags = r.u8();
  const out = { tick: r.varint(), t: r.f32(), n: r.varint(), iseq: r.varint(),
                paused: !!(flags & 8) };
  const dn = r.varint();
  for (let i = 0; i < dn; i++) {
    const len = r.varint();
    const bytes = r.str(len);
    dict.intern(new TextDecoder().decode(new Uint8Array(bytes)));
  }
  if (flags & 1) {
    out.player = { id: r.varint(), x: r.i16(), z: r.i16() };
  }
  out.ents = [];
  let prev = 0;
  for (let i = 0; i < out.n; i++) {
    prev += r.varint();
    const e = { id: prev, x: r.i16(), z: r.i16() };
    e.p = dict.get(r.varint()); e.a = dict.get(r.varint()); e.bld = dict.get(r.varint());
    e.fr = r.varint();
    const deg = r.i16();
    if (deg) e.f = deg * (Math.PI / 180);
    out.ents.push(e);
  }
  if (flags & 4) {
    const phi = r.u8(), sei = r.u8(), df = r.u8();
    out.world = {
      phase:  phi < PHASES.length  ? PHASES[phi]  : null,
      season: sei < SEASONS.length ? SEASONS[sei] : null,
      isday:  !!(df & 1), isdusk: !!(df & 2), isnight: !!(df & 4),
      temperature: r.i16(),
    };
  }
  return out;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { encode, decode, Dict, VERSION, PHASES, SEASONS };
} else if (typeof window !== 'undefined') {
  window.ProtocolBin = { encode, decode, Dict, VERSION, PHASES, SEASONS };
}
