// perf_lib.js —— 客户端无浏览器测试的共享库（被 perf_client.js / test_client.js 复用）
//
// 提供：
//   makeClient()  —— 在 Node 里造一个「跑着 client.html 全部 JS」的沙箱
//                     （canvas / DOM / WebSocket / rAF 全部桩化）
//   fakeFrame(n,t) —— 造一个与服务端快照同构的假帧
//   measure(n,frames) —— 跑 N 帧，返回 avg/p50/p95/p99 与帧数
//
// ★ 关键设计：沙箱里的 WebSocket 桩会把 send() 的内容记到 `sandbox.__sent`，
//   这样测试可以断言「输入真的被发出去了」，而不是空操作。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// ---------------------------------------------------------------- canvas 桩
// ★ C2：`getContext('webgl')` 默认返回 **null** —— 即"这个浏览器没有 WebGL"，
//   于是客户端会走 Canvas 2D 路径（与改动前的行为逐字一致，老的判据不受影响）。
//   `makeClient({ webgl: true })` 时才返回一个记录调用的假 gl，
//   用来验「批渲染这条路真的被走通了」。
let USE_WEBGL = false;

class GLStub {
  constructor() {
    this.calls = [];
    this.ARRAY_BUFFER = 0x8892; this.DYNAMIC_DRAW = 0x88E8; this.FLOAT = 0x1406;
    this.TRIANGLES = 0x0004; this.RGBA = 0x1908; this.UNSIGNED_BYTE = 0x1401;
    this.TEXTURE_2D = 0x0DE1; this.TEXTURE_MIN_FILTER = 0x2801; this.TEXTURE_MAG_FILTER = 0x2800;
    this.TEXTURE_WRAP_S = 0x2802; this.TEXTURE_WRAP_T = 0x2803;
    this.NEAREST = 0x2600; this.CLAMP_TO_EDGE = 0x812F;
    this.VERTEX_SHADER = 0x8B31; this.FRAGMENT_SHADER = 0x8B30;
    this.COMPILE_STATUS = 0x8B81; this.LINK_STATUS = 0x8B82;
    this.BLEND = 0x0BE2; this.SRC_ALPHA = 0x0302; this.ONE_MINUS_SRC_ALPHA = 0x0303;
    this.COLOR_BUFFER_BIT = 0x4000;
  }
  _r(n, a) { this.calls.push([n].concat(a || [])); }
  createShader() { return {}; } shaderSource(s, src) { s.src = src; } compileShader(s) { s.ok = !!s.src; }
  getShaderParameter(s, p) { return p === this.COMPILE_STATUS ? s.ok !== false : true; }
  getShaderInfoLog() { return ''; }
  createProgram() { return {}; } attachShader() {} linkProgram(p) { p.linked = true; }
  getProgramParameter(p, k) { return k === this.LINK_STATUS ? p.linked !== false : true; }
  getProgramInfoLog() { return ''; }
  getAttribLocation(p, n) { return n === 'a_pos' ? 0 : n === 'a_uv' ? 1 : -1; }
  getUniformLocation(p, n) { return { n }; }
  createBuffer() { return {}; } bindBuffer() {}
  bufferData(t, arr) { this._r('bufferData', [arr.length]); }
  enableVertexAttribArray() {} vertexAttribPointer() {}
  useProgram() {} uniform2f() {} uniform1i() {}
  createTexture() { return {}; } bindTexture() {} texImage2D() {} texParameteri() {}
  viewport() {} clearColor() {} clear() {} enable() {} blendFunc() {}
  drawArrays(m, first, count) { this._r('drawArrays', [m, first, count]); }
  draws() { return this.calls.filter(c => c[0] === 'drawArrays'); }
}

class CtxStub {
  constructor() { this.ops = 0; this.draws = 0; }
  _op() { this.ops++; }
  fillRect() { this._op(); }  strokeRect() { this._op(); }
  beginPath() { this._op(); } closePath() { this._op(); }
  arc() { this._op(); }      rect() { this._op(); }
  moveTo() { this._op(); }   lineTo() { this._op(); }
  fill() { this._op(); }     stroke() { this._op(); }
  fillText() { this._op(); }
  // ★ 地形图层用到的两个：drawImage（缩放画整张地形）+ imageSmoothingEnabled。
  //   沙箱少了它们，地形路径一跑就 TypeError —— 与 XHR/Image 缺失是同一类失真。
  drawImage() { this._op(); this.draws++; }
  // ★★ C2：变换栈。**以前不需要**，因为沙箱里图集永远加载不出来 ⇒
  //   `Atlas.drawEntity` 第一步就 return false，那六行 save/translate/scale/
  //   transform/drawImage/restore 从来没被执行过。一旦让图集"加载成功"，
  //   缺一个方法就是 `ctx.save is not a function` —— 桩比浏览器少东西的又一例。
  save() { this._op(); }      restore() { this._op(); }
  translate() { this._op(); } scale() { this._op(); }  transform() { this._op(); }
  set fillStyle(_) {}  set strokeStyle(_) {}  set lineWidth(_) {}
  set font(_) {}       set textBaseline(_) {}  set imageSmoothingEnabled(_) {}
}
class CanvasStub {
  constructor(w, h) { this.width = w || 1280; this.height = h || 720; this._ls = {};
                      this._gl = null; }
  // ★ C2：按 type 分派。原来不管传什么都返回 2D ctx —— 于是客户端那句
  //   `getContext('webgl')` 会拿到一个"能当 2D 用"的对象，WebGL 特性检测
  //   就变成了恒真（假绿）。桩化掉的东西必须**长得像真的**：没有 WebGL 就返 null。
  getContext(type) {
    if (type === 'webgl' || type === 'experimental-webgl') {
      if (!USE_WEBGL) return null;
      return this._gl || (this._gl = new GLStub());
    }
    return this._ctx || (this._ctx = new CtxStub());
  }
  // ★ P23：**记录**监听器，而不是当没听见。
  //   为什么：桩化掉 addEventListener 的话，判据只能测「处理器函数本身对不对」，
  //   测不到「它到底有没有被挂上去」。而「检查写好了 ≠ 检查生效过」是本工程的老母题
  //   —— 挂监听这一行删掉，所有「按了有反应」的测试照样绿。
  addEventListener(t, fn) { (this._ls[t] = this._ls[t] || []).push(fn); }
  removeEventListener(t, fn) {
    const a = this._ls[t]; if (!a) return;
    const i = a.indexOf(fn); if (i >= 0) a.splice(i, 1);
  }
  // ★ 由测试**真的派发一次**事件（走的是注册时那个函数引用）
  fire(type, ev) {
    const a = this._ls[type] || [];
    for (const fn of a) fn(ev || {});
    return a.length;
  }
}
class ElemStub {
  constructor() {
    this.textContent = ''; this.value = '';
    this.checked = false; this.disabled = false;
    this.style = {}; this.dataset = {}; this.children = [];
    this._ls = {};
    const self = this;
    // ★★ C4（2026-10-22）：`className` 与 `classList` 必须是**同一份状态**。
    //   桩原来把 className 当普通属性存、classList 用另一个 Set ——
    //   于是 `classList.toggle('on')` 之后读 `el.className` 读到的还是初始值。
    //   浏览器里两者当然一致。
    //   这个差异**不会崩溃**，只会让判据读到"面板没有展开"，而实现明明是对的 ——
    //   与 B2 的 `getElementById` 不按 id 缓存是同一类错：**桩给出假否定**。
    //   （假否定会让人去改一个没坏的实现，比假绿灯一样贵。）
    const set = new Set();
    Object.defineProperty(this, 'className', {
      get: () => Array.from(set).join(' '),
      set: (v) => {
        set.clear();
        String(v == null ? '' : v).split(/\s+/).filter(Boolean).forEach((c) => set.add(c));
      },
      configurable: true,
    });
    // ★★ 桩要覆盖**客户端实际用到的 DOM 面**，否则「方法缺失」会伪装成
    //   「客户端崩了」。P62 的编辑器用到 classList / appendChild / value / onclick，
    //   每缺一个就整页 TypeError —— 而 perf_client 不在闸门里，没人会发现。
    // ★★ B2：`innerHTML = ''` 在浏览器里**会清空子节点**，桩原来只是存了个字符串。
    //   于是「先清空再重画」的列表在桩里会**越画越长**（第二次 refresh 之后
    //   3 行变 6 行），而判据读到的长度就成了"实现越界"的假证据。
    //   这不是性能问题，是桩与浏览器的语义差 —— 必须补。
    let _html = '';
    Object.defineProperty(this, 'innerHTML', {
      get: () => _html,
      set: (v) => { _html = String(v); if (_html === '') this.children.length = 0; },
      configurable: true,
    });
    this.classList = {
      add: (...c) => c.forEach((x) => set.add(x)),
      remove: (...c) => c.forEach((x) => set.delete(x)),
      contains: (c) => set.has(c),
      toggle: (c, f) => {
        const want = f === undefined ? !set.has(c) : !!f;
        if (want) set.add(c); else set.delete(c);
        return want;
      },
      get length() { return set.size; },
    };
    void self;
  }
  addEventListener(t, fn) { (this._ls[t] = this._ls[t] || []).push(fn); }
  removeEventListener() {}
  appendChild(c) { this.children.push(c); return c; }
  removeChild(c) {
    const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1);
    return c;
  }
  setAttribute(k, v) { this[k] = v; }
  getAttribute(k) { return this[k]; }
  hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this, k); }
  querySelectorAll() { return []; }
  querySelector() { return new ElemStub(); }
  getBoundingClientRect() { return { left: 0, top: 0, width: 1280, height: 720 }; }
}

/**
 * 造一个跑着 client.html 全部 JS 的沙箱。
 *
 * @param {Object} [opt]
 *   · `webgl: true`     —— 让 `getContext('webgl')` 返回一个记录调用的假 gl
 *                          （默认 **null**：与"这台机器没有 WebGL"一致，
 *                            此时客户端走 Canvas 2D 路径，老的帧率判据不受影响）
 *   · `atlasJson: {}`   —— `{build: json对象}`：XHR/Image 桩会**真的回调**，
 *                          于是图集被当成"已加载"，批路径才可能摊出四边形。
 *                          不给则模拟"永远加载不完"（浏览器首帧的合法状态）。
 *   · `search: '?render=batch'` —— 覆盖 location.search（验模式开关）
 */
function makeClient(opt) {
  const O = opt || {};
  USE_WEBGL = !!O.webgl;                     // ★ 模块级开关，见 CanvasStub.getContext
  const rafQueue = [];
  const sent = [];
  const winLs = {};                       // window 上的监听器（★ P23：要能真的派发）
  const perf = { now: () => Number(process.hrtime.bigint()) / 1e6 };   // ms，亚毫秒
  const sandbox = {
    console, Math, JSON, Object, Array, Number, String, isNaN, parseInt,
    Set, Map, Symbol, Error, TypeError, RangeError,
    performance: perf,
    document: {
      // ★★ B2：**必须按 id 缓存**。原来每次调用都 `new ElemStub()` —— 于是
      //   `getElementById('craftList')` 两次拿到的是**两个不同对象**，
      //   往其中一个 appendChild 之后，测试从另一个去数 children，永远为 0。
      //   这种桩不会崩、只会让判据永远读到"空"，比崩溃更难发现。
      //   （P62 那晚的教训是反方向：桩少一个方法就整组崩。两种都要防。）
      getElementById: (id) => {
        if (id === 'cv') return sandbox.__cv || (sandbox.__cv = new CanvasStub(1280, 720));
        const m = sandbox.__els || (sandbox.__els = {});
        return m[id] || (m[id] = new ElemStub());
      },
      addEventListener() {},
      // ★★ P63：`querySelectorAll` 必须给。P62 的编辑器在加载时用
      //   `document.querySelectorAll('#edBar [data-tool]')` 绑工具栏 —— 桩里没有这个方法，
      //   于是 `perf_client.js` **整个崩掉**（不是「帧率不达标」，是 TypeError）。
      //   而它不在闸门里 ⇒ 崩了两轮没人知道：文档仍写着「≥55 fps 实测通过」。
      //   返回空数组是本桩的**诚实选择**：性能测量不需要工具栏处理器，
      //   但"少一个方法就崩"这件事必须在桩这一层修掉，不能靠客户端写防御绕过。
      querySelectorAll: () => [],
      querySelector: () => new ElemStub(),
      // ★ 地形图层会 `document.createElement('canvas')` 做离屏画布（1 像素 = 1 瓦片）。
      //   沙箱必须给 —— 与 location / XHR / Image 缺失是同一类「沙箱比浏览器少东西」。
      // ★★ C2：**必须把创建出来的画布记下来**。批渲染的 GL 上下文挂在
      //   离屏画布上（`SPR` 里 `document.createElement('canvas')`），不是 `#cv`；
      //   不记录就只能去 `__cv._gl` 找 ⇒ 永远为 null ⇒「GL 一次 drawArrays 都没有」
      //   这种假红。测试要能拿到**那个**画布。
      // ★★ B2：按 tag 分派。原来**任何** tag 都返回 CanvasStub ——
      //   合成面板 `createElement('div')` 拿到画布，`textContent` / appendChild 全没有，
      //   一旦判据真的走到渲染那条路就是 TypeError。canvas 保持原样（地形离屏画布靠它）。
      createElement: (tag) => {
        if (tag === 'canvas' || tag === undefined) {
          const c = new CanvasStub(1, 1);
          (sandbox.__created || (sandbox.__created = [])).push(c);
          return c;
        }
        return new ElemStub();
      },
    },
    // ★★ P23：window 上的监听器要**记下来并真的派发** —— 键盘输入、指针移动/抬起
    //   都挂在 window 上。原来这里是个空的 `addEventListener(){}`，
    //   于是「键盘真的能操控」这件事在 Node 侧**从来没被验证过**：
    //   测试用的 `__rt.key` 是手抄的第二份实现（正是本工程的老根因）。
    //   现在 `__fireWin('keydown', {code:'KeyD'})` 走的是**注册的那个函数**。
    addEventListener: (t, fn) => { (winLs[t] = winLs[t] || []).push(fn); },
    removeEventListener: (t, fn) => {
      const a = winLs[t]; if (!a) return;
      const i = a.indexOf(fn); if (i >= 0) a.splice(i, 1);
    },
    innerWidth: 1280, innerHeight: 720,
    // ★ 沙箱要照浏览器的**全部**字段给：漏了 search，客户端那句
    //   `location.search.includes('json=1')` 就 TypeError（第一版就是这么挂的）
    location: { protocol: 'http:', host: '127.0.0.1:8765',
                search: O.search !== undefined ? O.search : '',
                href: 'http://127.0.0.1:8765/' },
    requestAnimationFrame: (fn) => { rafQueue.push(fn); return rafQueue.length; },
    WebSocket: function () {
      this.readyState = 1;
      this.send = (d) => sent.push(String(d));      // ★ 记录，供断言
      this.close = () => { this.readyState = 3; };
    },
    setTimeout: () => 0,
    // ★★ B2：合成面板用 setInterval 定时刷新，桩里没有 ⇒ ReferenceError。
    //   故意**不真的定时**：判据要的是"打开时刷一次"，不是"等 8 秒"。
    setInterval: () => 0,
    clearInterval: () => {},
    // ★★ B2：fetch 桩。客户端所有编辑器/合成接口都走 `fetch(...).then(r => r.json())`。
    //   沙箱原来没有 fetch —— 也就是说**编辑器那批请求路径在 Node 侧从来没跑过**，
    //   `edJson` 一调就 ReferenceError（被 try/catch 吃掉或直接崩）。
    //   现在：记录 URL 到 `__fetched`，并按 `O.fetchReply(url)` 返回预设 JSON。
    //   没给 responder 时返回一个空 ok 包，保证不崩（与"图集没加载好"同一个思路：
    //   桩只覆盖要验的那条路，其余保持沉默而不是假装成功）。
    fetch: (url) => {
      (sandbox.__fetched || (sandbox.__fetched = [])).push(String(url));
      let body = { ok: false, error: 'sandbox: 没有为这个 URL 配 fetchReply' };
      if (typeof O.fetchReply === 'function') {
        const r = O.fetchReply(String(url));
        if (r !== undefined && r !== null) body = r;
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve(body) });
    },
    // ★ P21：给一个**极简 localStorage**（沙箱比浏览器少东西的老问题之一）。
    //   少了它，客户端那句 `localStorage.getItem('rt_key')` 会抛异常 →
    //   被 try/catch 吃掉 → SKEY 恒为 '' → **测试永远走不到「带会话 key」那条路**。
    // ★★ H1：音频引擎**按需注入**（`opt.audio`），默认不给。
    //   为什么不默认给：AudioEngine 是模块级单例，默认注入会让 35 条老判据
    //   共享同一份状态（谁先播了一个音，后面的人看到的 stats 就是脏的）。
    //   需要验音频接线的判据（F36）自己建一份并 `_resetForTest()`。
    AudioEngine: (O.audio !== undefined ? O.audio : undefined),
    localStorage: {
      _d: {},
      getItem(k) { return Object.prototype.hasOwnProperty.call(this._d, k) ? this._d[k] : null; },
      setItem(k, v) { this._d[k] = String(v); },
      removeItem(k) { delete this._d[k]; },
    },
    // ★★ 沙箱还要给 XHR / Image：render_atlas.js 的 `ensure()` 会 `new XMLHttpRequest()`
    //   去取 build 的 json。桩化后**永远不回调 onload** ⇒ build 一直停在 loading
    //   ⇒ drawEntity 返回 false ⇒ 回退画圆。这正是「图集还没加载好」的合法状态，
    //   与浏览器里首帧的表现一致。
    //   （不补这两个，任何「带 bld 的实体」一测就 'XMLHttpRequest is not defined' ——
    //     与之前 location.search 缺失是同一类沙箱失真。）
    XMLHttpRequest: function () {
      const self = this;
      this.open = (m, url) => { self._url = url; };
      this.setRequestHeader = () => {};
      this.send = () => {
        // ★ C2：给了 `atlasJson` 就**真的回调**（模拟"图集取回来了"）。
        //   不给则永不回调 —— 那是"首帧还没加载好"的合法状态，也是老判据依赖的路径。
        if (!O.atlasJson) return;
        // ★★ 只认 `/atlas/json/` 这一种请求。第一版用宽正则 + `else onerror()`，
        //   于是地形那个 XHR（`/terrain?...`）在**模块求值期**同步触发了 onerror，
        //   而它内部引用 `TERR` —— 那是个后面才 `let` 的变量 ⇒ TDZ 报错
        //   `Cannot access 'TERR' before initialization`，8 条判据全变成"抛异常"。
        //   ⇒ 桩的行为必须**只覆盖要验的那条路**，其余一律保持原样（什么都不做）。
        const m = /\/atlas\/json\/(.+)\.json$/.exec(self._url || '');
        if (!m) return;
        const key = decodeURIComponent(m[1]);
        if (O.atlasJson[key]) {
          self.responseText = JSON.stringify(O.atlasJson[key]);
          if (self.onload) self.onload();
        } else if (self.onerror) {
          self.onerror();
        }
      };
      this.responseText = '{}';
    },
    Image: function () {
      const self = this;
      self.onload = null; self.onerror = null;
      self.complete = false; self.naturalWidth = 0; self.naturalHeight = 0;
      let _src = '';
      Object.defineProperty(self, 'src', {
        get: () => _src,
        set: (v) => {
          _src = v;
          // ★ 只有在"图集数据已给"的模式下才当成加载完成；否则保持 pending，
          //   这样"图集没加载好 ⇒ 回退画圆"那条老判据仍然成立。
          if (O.atlasJson) {
            self.complete = true;
            self.naturalWidth = 64; self.naturalHeight = 64;
            if (self.onload) self.onload();
          }
        },
      });
    },
    __rafQueue: rafQueue, __perf: perf, __sent: sent, __winLs: winLs,
    // ★ 派发一个 window 事件（走**注册过的**监听器）。返回被调用的监听器数：
    //   0 表示「根本没挂上」—— 与「挂上了但没反应」是两件不同的事，测试要能分辨。
    __fireWin: (type, ev) => {
      const a = winLs[type] || [];
      for (const fn of a) fn(ev || {});
      return a.length;
    },
    // ★ 派发一个 canvas 事件（同上）
    __fireCv: (type, ev) => (sandbox.__cv ? sandbox.__cv.fire(type, ev) : -1),
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  // ★ 先加载 render_atlas.js —— 浏览器里它是 <script src="render_atlas.js">，
  //   排在客户端脚本**之前**；沙箱不照这个顺序就会 RenderAtlas is not defined。
  // 顺序必须与 client.html 里的 <script src> 一致：
  //   render_atlas.js → render_batch.js → protocol_schema.js → protocol_bin.js → 客户端主体
  //   （★ C2：render_batch.js 依赖 render_atlas.js 的导出，顺序不能反）
  //   （★ L1：protocol_bin.js 的常量来自 protocol_schema.js（schema 生成），
  //     少了它 protocol_bin.js 会**主动抛错**——这是刻意的：宁可启动即崩，
  //     也不要悄悄用一份过期的默认值把「服务端发 day、客户端解成 night」发到线上。）
  for (const f of ['render_atlas.js', 'render_batch.js', 'protocol_schema.js', 'protocol_bin.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, f), 'utf8'), sandbox, { filename: f });
  }
  const html = fs.readFileSync(O.htmlPath || path.join(__dirname, 'client.html'), 'utf8');
  const js = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  vm.runInContext(js, sandbox, { filename: 'client.html<script>' });
  return sandbox;
}

function fakeFrame(n, t) {
  const ents = [];
  for (let i = 0; i < n; i++) {
    ents.push({ id: 1000 + i,
                x: ((i * 37) % 200) - 100 + Math.sin(t + i) * 2,
                z: ((i * 53) % 200) - 100 + Math.cos(t + i) * 2,
                p: 'prefab_' + (i % 17), a: 'run' });
  }
  // ★ 带上世界环境块：服务端现在**每帧都发**，不带的话测的就是
  //   比真实更轻的路径（少一个分支），帧率数字会偏乐观。
  const phase = ['day', 'dusk', 'night'][Math.floor(t / 3) % 3];
  return { t, tick: Math.round(t * 30), n, ents, iseq: 1,
           player: { id: 1000, x: ents[0] ? ents[0].x : 0, z: ents[0] ? ents[0].z : 0 },
           world: { phase, season: 'autumn',
                    isday: phase === 'day', isdusk: phase === 'dusk', isnight: phase === 'night',
                    temperature: 20 } };
}

function measure(n, frames = 600) {
  const env = makeClient();
  const rt = env.__rt;
  if (!rt || typeof rt.feed !== 'function') throw new Error('客户端没有暴露 __rt.feed 钩子');
  rt.feed(fakeFrame(n, 0.0));
  rt.feed(fakeFrame(n, 1 / 30));
  const times = [];
  for (let i = 0; i < frames; i++) {
    rt.feed(fakeFrame(n, (i + 2) / 30));
    const t0 = env.__perf.now();
    const fn = env.__rafQueue.shift();
    if (!fn) break;
    fn(env.__perf.now());
    times.push(env.__perf.now() - t0);
  }
  times.sort((a, b) => a - b);
  const at = (p) => times[Math.min(times.length - 1, Math.floor(times.length * p))];
  const avg = times.reduce((a, b) => a + b, 0) / times.length;
  return { n, frames: times.length, avg, p50: at(0.5), p95: at(0.95), p99: at(0.99) };
}

module.exports = { makeClient, fakeFrame, measure };
