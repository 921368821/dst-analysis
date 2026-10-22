// audio.js —— H1 音频后端（2026-10-22）
//
// 为什么先做"后端"而不是"音效内容"
// ---------------------------------
// 这个仓库里**一个音频资产都没有**（没有 .ogg / .wav / .fev / .fsb）。
// 所以真正的缺口不是"缺几个音效"，而是**没有任何一条能发声的路径**。
// 音效内容可以后面接资产，后端接错则要重写调用方 —— 先做后端。
//
// 音源用**程序合成**（oscillator + 包络）而不是采样：
//   · 没有资产可用，这是唯一能让"现在就有声音"的办法；
//   · 合成的成本是零字节，调试时能立刻听到"这一步到底有没有触发"；
//   · 将来接了资产，只换 `_makeSource` 一个函数，调用方一处都不用改。
//
// 浏览器的那条硬规则（必须记住，否则"代码全对但没声音"）
// ------------------------------------------------------
// `AudioContext` 在**没有用户手势**之前处于 `suspended`；`resume()` 也必须在手势的
// 同步调用栈里执行。所以：
//   · `ensure()` 只创建，不保证能播；
//   · 真正开始发声要等 `unlock()`（挂在 pointerdown / keydown 上，只挂一次）；
//   · 解锁之前的 `play()` 返回 null 并**记账**（denied+1），不抛异常、不排队 ——
//     排队会让"点了 20 下之后突然响一片"，那比没声音更像 bug。
'use strict';

var AudioEngine = (function () {
  var ctx = null;
  var master = null;
  var unlocked = false;
  var muted = false;
  var voices = {};        // id -> {osc, gain, name, startedAt}
  var seq = 0;
  var cache = {};         // name -> {kind:'tone', freq, dur} | {kind:'buffer', buf}
  var unlocked_hooked = false;

  var stats = {
    created: 0,      // ensure() 真正创建 ctx 的次数（应恒为 1）
    unlocks: 0,      // unlock() 实际 resume 成功的次数
    plays: 0,        // 成功发声的次数
    denied: 0,       // 未解锁时的播放请求（**不是错误**，是浏览器的规则）
    stops: 0,        // 显式停止
    decodeHits: 0,   // 音源描述命中缓存
    decodeMisses: 0, // 首次生成音源描述
    dropped: 0,      // 同时发声数超上限被丢弃的
    byName: {},      // 每个音名各播了几次（**判据靠它区分"播了"和"播对了"**）
  };

  // 同时最多 24 个声部。超了丢最旧的 —— 与渲染层的"帧里只给最近 12 个目标"同一条思路：
  // 声音是**感知**通道，堆到一定程度之后加更多只是噪音。
  var MAX_VOICES = 24;

  // 音名 → 合成参数。频率按五声音阶取，避免出现刺耳的小二度。
  var TONES = {
    'ui.click': { freq: 880, dur: 0.06, wave: 'square', gain: 0.08 },
    'ui.error': { freq: 220, dur: 0.18, wave: 'sawtooth', gain: 0.10 },
    'act.chop': { freq: 330, dur: 0.09, wave: 'triangle', gain: 0.12 },
    'act.hit': { freq: 440, dur: 0.10, wave: 'square', gain: 0.12 },
    'act.pickup': { freq: 660, dur: 0.07, wave: 'sine', gain: 0.10 },
    'craft.ok': { freq: 523, dur: 0.16, wave: 'sine', gain: 0.12 },
    'player.hurt': { freq: 196, dur: 0.22, wave: 'sawtooth', gain: 0.14 },
    'player.die': { freq: 131, dur: 0.45, wave: 'triangle', gain: 0.16 },
  };

  function _now() { return (ctx && ctx.currentTime) || 0; }

  function ensure() {
    if (ctx) return ctx;
    var AC = (typeof AudioContext !== 'undefined') ? AudioContext
           : (typeof webkitAudioContext !== 'undefined' ? webkitAudioContext : null);
    if (!AC) return null;                       // 无音频环境：调用方要能接受 null
    try {
      ctx = new AC();
    } catch (e) {
      ctx = null;
      return null;
    }
    stats.created++;
    try {
      master = ctx.createGain();
      master.gain.value = muted ? 0 : 1;
      master.connect(ctx.destination);
    } catch (e) {
      master = null;                            // 桩环境可能没有 createGain，不算致命
    }
    return ctx;
  }

  function unlock() {
    ensure();
    if (!ctx || typeof ctx.resume !== 'function') return false;
    if (ctx.state === 'running') { unlocked = true; return true; }
    try {
      // ⚠️ 不返回 promise 给调用方：浏览器要求 resume 在**手势同步栈**里发起，
      //   把 then 链丢给别人用会让调用点离开手势上下文（Safari 尤其严格）。
      ctx.resume();
      unlocked = true;
      stats.unlocks++;
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 把第一个用户手势接到 unlock 上（只挂一次）。 */
  function hookUnlock(target) {
    if (unlocked_hooked) return;
    var t = target || (typeof window !== 'undefined' ? window : null);
    if (!t || typeof t.addEventListener !== 'function') return;
    unlocked_hooked = true;
    var once = function () {
      unlock();
      t.removeEventListener('pointerdown', once);
      t.removeEventListener('keydown', once);
    };
    t.addEventListener('pointerdown', once);
    t.addEventListener('keydown', once);
  }

  function _source(name) {
    if (Object.prototype.hasOwnProperty.call(cache, name)) {
      stats.decodeHits++;
      return cache[name];
    }
    stats.decodeMisses++;
    var spec = TONES[name] || TONES['ui.click'];
    cache[name] = { kind: 'tone', freq: spec.freq, dur: spec.dur,
                    wave: spec.wave, gain: spec.gain };
    return cache[name];
  }

  function _trim() {
    var ids = Object.keys(voices);
    if (ids.length <= MAX_VOICES) return;
    ids.sort(function (a, b) { return voices[a].startedAt - voices[b].startedAt; });
    for (var i = 0; i < ids.length - MAX_VOICES; i++) {
      try { voices[ids[i]].osc.stop(); } catch (e) { /* 已停 */ }
      delete voices[ids[i]];
      stats.dropped++;
    }
  }

  /**
   * 播放一个音名。
   * @returns {number|null} 声部 id；未解锁 / 无音频环境时返回 null（**不是错误**）
   */
  function play(name, opt) {
    var o = opt || {};
    if (!ensure()) { stats.denied++; return null; }
    if (!unlocked) {
      // 未解锁：记账后直接返回。**不排队** —— 排队会造成"点了一串之后突然响一片"。
      stats.denied++;
      return null;
    }
    var src = _source(name);
    var t0 = _now();
    var gain = null, osc = null;
    try {
      osc = ctx.createOscillator();
      gain = ctx.createGain();
      osc.type = src.wave;
      osc.frequency.value = src.freq;
      var vol = (o.gain !== undefined ? o.gain : src.gain);
      // 简单 ADSR（只有 A 和 R）：起音 5 ms、衰减到 0。
      // 不做长包络是因为这些音都在 0.5 s 以内，长包络反而听不出差别。
      gain.gain.setValueAtTime(0.0001, t0);
      gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, vol), t0 + 0.005);
      gain.gain.exponentialRampToValueAtTime(0.0001, t0 + src.dur);
      osc.connect(gain);
      if (master) gain.connect(master); else gain.connect(ctx.destination);
      osc.start(t0);
      osc.stop(t0 + src.dur + 0.02);
      stats.plays++;
      stats.byName[name] = (stats.byName[name] || 0) + 1;
    } catch (e) {
      return null;
    }
    seq++;
    voices[seq] = { osc: osc, gain: gain, name: name, startedAt: t0 };
    _trim();
    return seq;
  }

  function stop(id) {
    var v = voices[id];
    if (!v) return false;
    try { v.osc.stop(); } catch (e) { /* 已经停了 */ }
    delete voices[id];
    stats.stops++;
    return true;
  }

  function stopAll() {
    var n = 0;
    for (var k in voices) { if (stop(Number(k))) n++; }
    return n;
  }

  function setMuted(on) {
    muted = !!on;
    if (master && master.gain) {
      try { master.gain.value = muted ? 0 : 1; } catch (e) { /* 桩 */ }
    }
    return muted;
  }

  function isUnlocked() { return unlocked; }

  function getStats() {
    var out = {};
    for (var k in stats) {
      out[k] = (k === 'byName') ? Object.assign({}, stats.byName) : stats[k];
    }
    out.voices = Object.keys(voices).length;
    out.unlocked = unlocked;
    out.muted = muted;
    out.hasCtx = !!ctx;
    return out;
  }

  function _resetForTest() {
    for (var k in voices) { try { voices[k].osc.stop(); } catch (e) { /* noop */ } }
    voices = {}; cache = {}; seq = 0; ctx = null; master = null;
    unlocked = false; muted = false; unlocked_hooked = false;
    for (var s in stats) {
      if (s === 'byName') stats.byName = {}; else stats[s] = 0;
    }
  }

  return {
    ensure: ensure, unlock: unlock, hookUnlock: hookUnlock,
    play: play, stop: stop, stopAll: stopAll, setMuted: setMuted,
    isUnlocked: isUnlocked, stats: getStats, _resetForTest: _resetForTest,
    TONES: TONES,
  };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = { AudioEngine: AudioEngine };
