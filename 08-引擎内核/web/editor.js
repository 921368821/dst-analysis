// src/foundation/math/scalar.ts
var TAU = Math.PI * 2;
function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

// src/foundation/log/logger.ts
var LogLevel = {
  Trace: 10,
  Debug: 20,
  Info: 30,
  Warn: 40,
  Error: 50,
  Off: 100
};
var DEFAULT_LIMIT = { maxPerWindow: 5, windowMs: 1e3 };
var MemorySink = class {
  constructor(capacity = 2e3) {
    this.capacity = capacity;
  }
  buf = [];
  dropped = 0;
  write(rec) {
    if (this.buf.length >= this.capacity) {
      this.buf.shift();
      this.dropped++;
    }
    this.buf.push(rec);
  }
  records() {
    return this.buf;
  }
  /** 按通道/级别过滤，判据里最常用的两个查询。 */
  byChannel(channel) {
    return this.buf.filter((r) => r.channel === channel);
  }
  has(level, substr) {
    return this.buf.some((r) => r.level >= level && r.message.includes(substr));
  }
  clear() {
    this.buf.length = 0;
    this.dropped = 0;
  }
  get droppedCount() {
    return this.dropped;
  }
};
var Logger = class {
  constructor(now = () => Date.now()) {
    this.now = now;
  }
  sinks = [];
  channelLevel = /* @__PURE__ */ new Map();
  limiters = /* @__PURE__ */ new Map();
  defaultLevel = LogLevel.Info;
  addSink(sink) {
    this.sinks.push(sink);
  }
  setLevel(level, channel) {
    if (channel === void 0) this.defaultLevel = level;
    else this.channelLevel.set(channel, level);
  }
  levelOf(channel) {
    return this.channelLevel.get(channel) ?? this.defaultLevel;
  }
  /**
   * 取一个通道的 logger。
   * ★ 通道名用 `点分层`（`gfx.webgl2` / `asset.registry`），这样"给 gfx 全开 debug"
   *   可以用前缀匹配（见 `setLevelPrefix`），不需要一处一处改。
   */
  channel(name) {
    return new ChannelLogger(this, name);
  }
  setLevelPrefix(prefix, level) {
    this.channelLevel.set(prefix.endsWith("*") ? prefix : prefix + "*", level);
  }
  log(level, channel, message, fields, limit) {
    const lv = this.levelOf(channel);
    if (level < lv || lv >= LogLevel.Off) return;
    let suppressed = 0;
    if (limit) {
      const key = channel + "\0" + message;
      const t = this.now();
      const st = this.limiters.get(key);
      if (st === void 0 || t - st.windowStart >= limit.windowMs) {
        suppressed = st ? st.folded : 0;
        this.limiters.set(key, { windowStart: t, count: 1, folded: 0 });
      } else {
        st.count++;
        if (st.count > limit.maxPerWindow) {
          st.folded++;
          return;
        }
      }
    }
    const rec = {
      t: this.now(),
      level,
      channel,
      message,
      ...fields === void 0 ? {} : { fields },
      suppressed
    };
    for (const s of this.sinks) s.write(rec);
  }
  flush() {
    for (const s of this.sinks) s.flush?.();
  }
};
var ChannelLogger = class {
  constructor(root, name) {
    this.root = root;
    this.name = name;
  }
  trace(msg, fields) {
    this.root.log(LogLevel.Trace, this.name, msg, fields);
  }
  debug(msg, fields) {
    this.root.log(LogLevel.Debug, this.name, msg, fields);
  }
  info(msg, fields) {
    this.root.log(LogLevel.Info, this.name, msg, fields);
  }
  warn(msg, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Warn, this.name, msg, fields, limit);
  }
  error(msg, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Error, this.name, msg, fields, limit);
  }
};
var ConsoleSink = class {
  constructor(minLevel = LogLevel.Info, echo = (l) => console.log(l)) {
    this.minLevel = minLevel;
    this.echo = echo;
  }
  write(rec) {
    if (rec.level < this.minLevel) return;
    const tag = rec.level >= LogLevel.Error ? "E" : rec.level >= LogLevel.Warn ? "W" : "I";
    const fold = rec.suppressed > 0 ? ` (+${rec.suppressed} \u540C\u7C7B\u88AB\u6298\u53E0)` : "";
    const f = rec.fields ? " " + JSON.stringify(rec.fields) : "";
    this.echo(`[${tag}][${rec.channel}] ${rec.message}${f}${fold}`);
  }
};

// src/foundation/time/clock.ts
var SystemClock = class {
  /** 高精度优先；没有就降级到 Date.now（可能回退，但只在极老环境）。 */
  impl;
  constructor() {
    const perf = globalThis.performance;
    if (perf && typeof perf.now === "function") {
      const p = perf;
      this.impl = () => p.now();
    } else {
      this.impl = () => Date.now();
    }
  }
  now() {
    return this.impl();
  }
};

// src/foundation/event/event-bus.ts
var EventBus = class {
  listeners = /* @__PURE__ */ new Map();
  emitted = 0;
  listenerErrors = 0;
  lastError = null;
  /** 错误回调：默认什么都不做，由宿主接到 logger 上（L0 不依赖具体 logger 实例，避免全局单例）。 */
  onListenerError = null;
  on(topic, fn) {
    let set = this.listeners.get(topic);
    if (set === void 0) {
      set = /* @__PURE__ */ new Set();
      this.listeners.set(topic, set);
    }
    set.add(fn);
    return () => {
      set.delete(fn);
    };
  }
  once(topic, fn) {
    const off = this.on(topic, (p) => {
      off();
      fn(p);
    });
    return off;
  }
  emit(topic, payload) {
    this.emitted++;
    const set = this.listeners.get(topic);
    if (set === void 0 || set.size === 0) return;
    const snapshot = Array.from(set);
    for (const fn of snapshot) {
      try {
        fn(payload);
      } catch (e) {
        this.listenerErrors++;
        this.lastError = e instanceof Error ? e.message : String(e);
        this.onListenerError?.(topic, e);
      }
    }
  }
  listenerCount(topic) {
    return this.listeners.get(topic)?.size ?? 0;
  }
  /** 清空所有订阅。宿主 dispose 时调用，避免模块卸载后仍被事件引用。 */
  clear() {
    this.listeners.clear();
  }
  stats() {
    return {
      emitted: this.emitted,
      listenerErrors: this.listenerErrors,
      lastError: this.lastError
    };
  }
};

// src/foundation/memory/disposable.ts
var DisposableBag = class {
  items = [];
  disposed = false;
  add(label, d) {
    if (this.disposed) {
      releaseOne(d);
      throw new Error(`DisposableBag \u5DF2\u91CA\u653E\uFF0C\u4E0D\u5141\u8BB8\u518D add\uFF08${label}\uFF09`);
    }
    this.items.push({ label, d });
  }
  /** 逆序释放。单个失败**不中断**其余释放，但把失败收集起来抛一个聚合错误。 */
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    const failures = [];
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i];
      try {
        releaseOne(it.d);
      } catch (e) {
        failures.push(`${it.label}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    this.items.length = 0;
    if (failures.length > 0) {
      throw new Error(`\u91CA\u653E\u65F6\u6709 ${failures.length} \u9879\u5931\u8D25\uFF1A
  ${failures.join("\n  ")}`);
    }
  }
  get size() {
    return this.items.length;
  }
  get isDisposed() {
    return this.disposed;
  }
};
function releaseOne(d) {
  if (typeof d === "function") d();
  else d.dispose();
}

// src/foundation/random.ts
var XorShift128 = class {
  s0;
  s1;
  constructor(seed) {
    let x = seed | 0 || 2654435769;
    const next = () => {
      x = x + 2654435769 | 0;
      let z = x;
      z = Math.imul(z ^ z >>> 16, 2246822507);
      z = Math.imul(z ^ z >>> 13, 3266489909);
      return (z ^ z >>> 16) >>> 0;
    };
    this.s0 = next() || 1;
    this.s1 = next() || 2;
  }
  /** 32 位 xorshift128，返回 [0, 2^32) */
  nextU32() {
    let x = this.s0;
    const y = this.s1;
    this.s0 = y;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.s1 = x >>> 0;
    return this.s1;
  }
  next() {
    const hi = this.nextU32() >>> 5;
    const lo = this.nextU32() >>> 6;
    return (hi * 67108864 + lo) / 9007199254740992;
  }
  int(lo, hi) {
    if (hi <= lo) return lo;
    return lo + Math.floor(this.next() * (hi - lo));
  }
  range(lo, hi) {
    return lo + this.next() * (hi - lo);
  }
  chance(p) {
    return this.next() < p;
  }
  shuffle(arr) {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = this.int(0, i + 1);
      const t = arr[i];
      arr[i] = arr[j];
      arr[j] = t;
    }
    return arr;
  }
  pick(arr) {
    if (arr.length === 0) return void 0;
    return arr[this.int(0, arr.length)];
  }
  getState() {
    return { s0: this.s0, s1: this.s1 };
  }
  setState(s) {
    if (s.s0 === 0 && s.s1 === 0) throw new RangeError("\u968F\u673A\u72B6\u6001\u4E0D\u80FD\u662F\u5168\u96F6");
    this.s0 = s.s0 >>> 0;
    this.s1 = s.s1 >>> 0;
  }
};

// src/foundation/result.ts
function ok(value) {
  return { ok: true, value };
}
function err(error) {
  return { ok: false, error };
}
function engineError(code, message, detail) {
  return detail === void 0 ? { code, message } : { code, message, detail };
}

// src/platform/registry.ts
var BackendRegistry = class {
  tables = /* @__PURE__ */ new Map();
  register(kind, entry) {
    let table = this.tables.get(kind);
    if (table === void 0) {
      table = /* @__PURE__ */ new Map();
      this.tables.set(kind, table);
    }
    if (table.has(entry.id)) {
      throw new Error(`\u540E\u7AEF ${kind}/${entry.id} \u5DF2\u7ECF\u6CE8\u518C\u8FC7\uFF08\u540C id \u4E0D\u5141\u8BB8\u91CD\u590D\u6CE8\u518C\uFF09`);
    }
    table.set(entry.id, entry);
  }
  /** 便捷注册：从工厂对象批量取 probe/create。 */
  registerGfx(f, priority = 100) {
    this.register("gfx", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerAudio(f, priority = 100) {
    this.register("audio", {
      id: f.id,
      priority,
      probe: f.probe,
      create: f.create
    });
  }
  registerInput(f, priority = 100) {
    this.register("input", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerFs(f, priority = 100) {
    this.register("fs", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerNet(f, priority = 100) {
    this.register("net", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerScript(f, priority = 100) {
    this.register("script", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  list(kind) {
    return Array.from(this.tables.get(kind)?.keys() ?? []).sort();
  }
  has(kind, id) {
    return this.tables.get(kind)?.has(id) ?? false;
  }
  /**
   * 创建后端。选择顺序：
   *   1) `prefer` 指定 → 必须成功（除非 `allowFallbackToNull` 且 `null` 可用）
   *   2) `allow` 白名单内、probe 通过、priority 最高的
   *   3) 全失败 → 返回聚合错误
   */
  create(kind, opts = {}) {
    const table = this.tables.get(kind);
    if (table === void 0 || table.size === 0) {
      return err(
        engineError(
          "BACKEND.NONE_REGISTERED",
          `\u6CA1\u6709\u4EFB\u4F55 ${kind} \u540E\u7AEF\u88AB\u6CE8\u518C\uFF08\u5BBF\u4E3B\u5E94\u8BE5\u5728 bootstrap \u9636\u6BB5\u8C03\u7528 register* \uFF09`
        )
      );
    }
    const notes = [];
    if (opts.prefer !== void 0) {
      const e = table.get(opts.prefer);
      if (e === void 0) {
        notes.push(`prefer=${opts.prefer} \u672A\u6CE8\u518C`);
      } else if (!e.probe(opts.options)) {
        notes.push(`prefer=${opts.prefer} \u63A2\u6D4B\u5931\u8D25\uFF08\u8BE5\u73AF\u5883\u4E0D\u652F\u6301\uFF09`);
      } else {
        const r = e.create(opts.options);
        if (r.ok) return ok(r.value);
        notes.push(`prefer=${opts.prefer} \u521B\u5EFA\u5931\u8D25\uFF1A${r.error.message}`);
      }
    }
    const cands = Array.from(table.values()).filter((e) => opts.allow === void 0 || opts.allow.includes(e.id)).sort((a, b) => b.priority - a.priority);
    for (const e of cands) {
      if (opts.allowFallbackToNull === false && e.id === "null") continue;
      let probed = false;
      try {
        probed = e.probe(opts.options);
      } catch (ex) {
        notes.push(`${e.id} \u63A2\u6D4B\u629B\u9519\uFF1A${ex instanceof Error ? ex.message : String(ex)}`);
        continue;
      }
      if (!probed) {
        notes.push(`${e.id} \u4E0D\u53EF\u7528`);
        continue;
      }
      const r = e.create(opts.options);
      if (r.ok) return ok(r.value);
      notes.push(`${e.id} \u521B\u5EFA\u5931\u8D25\uFF1A${r.error.message}`);
    }
    return err(
      engineError("BACKEND.UNAVAILABLE", `\u6CA1\u6709\u53EF\u7528\u7684 ${kind} \u540E\u7AEF`, {
        kind,
        candidates: opts.allow ?? Array.from(table.keys()),
        reasons: notes
      })
    );
  }
};

// src/platform/platform.ts
function createPlatform(req) {
  const { registry: registry2 } = req;
  const clock = req.clock ?? new SystemClock();
  const gfxR = registry2.create("gfx", {
    ...req.prefer?.gfx === void 0 ? {} : { prefer: req.prefer.gfx },
    ...req.allow?.gfx === void 0 ? {} : { allow: req.allow.gfx },
    options: req.backendOptions?.gfx
  });
  if (!gfxR.ok) return gfxR;
  const audioR = registry2.create("audio", {
    ...req.prefer?.audio === void 0 ? {} : { prefer: req.prefer.audio },
    ...req.allow?.audio === void 0 ? {} : { allow: req.allow.audio },
    options: req.backendOptions?.audio
  });
  if (!audioR.ok) {
    gfxR.value.destroy();
    return audioR;
  }
  const inputR = registry2.create("input", {
    ...req.prefer?.input === void 0 ? {} : { prefer: req.prefer.input },
    ...req.allow?.input === void 0 ? {} : { allow: req.allow.input },
    options: req.backendOptions?.input
  });
  if (!inputR.ok) {
    audioR.value.destroy();
    gfxR.value.destroy();
    return inputR;
  }
  const fsR = registry2.create("fs", {
    ...req.prefer?.fs === void 0 ? {} : { prefer: req.prefer.fs },
    ...req.allow?.fs === void 0 ? {} : { allow: req.allow.fs },
    options: req.backendOptions?.fs
  });
  if (!fsR.ok) {
    inputR.value.destroy();
    audioR.value.destroy();
    gfxR.value.destroy();
    return fsR;
  }
  let net = null;
  let netId = null;
  if (registry2.list("net").length > 0) {
    const netR = registry2.create("net", {
      ...req.prefer?.net === void 0 ? {} : { prefer: req.prefer.net },
      ...req.allow?.net === void 0 ? {} : { allow: req.allow.net },
      options: req.backendOptions?.net
    });
    if (netR.ok) {
      net = netR.value;
      netId = req.prefer?.net ?? "auto";
    }
  }
  let script = null;
  let scriptId = null;
  if (registry2.list("script").length > 0) {
    const scriptR = registry2.create("script", {
      ...req.prefer?.script === void 0 ? {} : { prefer: req.prefer.script },
      ...req.allow?.script === void 0 ? {} : { allow: req.allow.script },
      options: req.backendOptions?.script
    });
    if (scriptR.ok) {
      script = scriptR.value;
      scriptId = scriptR.value.id;
    } else if (req.prefer?.script !== void 0) {
      inputR.value.destroy();
      audioR.value.destroy();
      gfxR.value.destroy();
      return scriptR;
    }
  }
  const size = gfxR.value.size;
  const caps = {
    id: req.id,
    interactive: req.interactive,
    hasGpu: gfxR.value.caps.backend !== "null",
    hasAudio: audioR.value.caps.backend !== "null",
    hasDom: typeof globalThis.document !== "undefined",
    maxTextureSize: gfxR.value.caps.maxTextureSize
  };
  return {
    ok: true,
    value: {
      id: req.id,
      caps,
      gfx: gfxR.value,
      audio: audioR.value,
      input: inputR.value,
      fs: fsR.value,
      net,
      script,
      clock,
      backends: {
        gfx: gfxR.value.caps.backend,
        audio: audioR.value.caps.backend,
        input: inputR.value.caps.backend,
        fs: fsR.value.scheme,
        net: netId,
        script: scriptId
      },
      dispose() {
        script?.dispose();
        net?.close(1e3, "platform dispose");
        inputR.value.destroy();
        audioR.value.destroy();
        gfxR.value.destroy();
      }
    }
  };
}

// src/core/module/module.ts
var ModuleState = {
  Created: "created",
  Initialized: "initialized",
  Started: "started",
  Stopped: "stopped",
  Disposed: "disposed",
  Failed: "failed"
};
var ModuleRegistry = class {
  constructor(ctx, opts = {}) {
    this.ctx = ctx;
    this.opts = opts;
  }
  entries = /* @__PURE__ */ new Map();
  /** 拓扑序（启动顺序）。stop/dispose 时逆序用。 */
  order = [];
  started = false;
  /**
   * 注册。**可以在 start 之前注册任意多个**，顺序无关（排序在启动时做）。
   * 启动后注册直接拒绝：热插拔模块需要先 stop，否则会出现"半个世界在用它"。
   */
  register(mod) {
    if (this.started) {
      return err({
        code: "MODULE.REGISTER_AFTER_START",
        message: `\u6A21\u5757 ${mod.id} \u5728\u542F\u52A8\u540E\u6CE8\u518C \u2014\u2014 \u5148 stop \u518D register\uFF08\u70ED\u63D2\u62D4\u9700\u8981\u663E\u5F0F\u505C\u6B62\uFF0C\u4E0D\u5141\u8BB8\u9690\u5F0F\uFF09`
      });
    }
    if (this.entries.has(mod.id)) {
      return err({
        code: "MODULE.DUPLICATE_ID",
        message: `\u6A21\u5757 id \u91CD\u590D\uFF1A${mod.id}`
      });
    }
    this.entries.set(mod.id, { mod, state: ModuleState.Created, error: null });
    return ok(void 0);
  }
  get(id) {
    return this.entries.get(id)?.mod;
  }
  state(id) {
    return this.entries.get(id)?.state;
  }
  ids() {
    return Array.from(this.entries.keys());
  }
  /** 拓扑序（稳定：同层按 id 字典序，保证两次运行顺序一致 ⇒ 可回放）。 */
  topoSort() {
    const indeg = /* @__PURE__ */ new Map();
    const out = /* @__PURE__ */ new Map();
    for (const id of this.entries.keys()) {
      indeg.set(id, 0);
      out.set(id, []);
    }
    for (const [id, e] of this.entries) {
      for (const d of e.mod.deps ?? []) {
        if (!this.entries.has(d)) {
          if ((this.opts.onMissingDep ?? "fail") === "fail") {
            return err({
              code: "MODULE.MISSING_DEP",
              message: `\u6A21\u5757 ${id} \u4F9D\u8D56 ${d}\uFF0C\u4F46\u5B83\u6CA1\u6709\u6CE8\u518C`
            });
          }
          this.ctx.log.channel("module").warn(`\u6A21\u5757 ${id} \u4F9D\u8D56 ${d} \u7F3A\u5931\uFF08\u5BBD\u5BB9\u6A21\u5F0F\uFF0C\u7EE7\u7EED\uFF09`);
          continue;
        }
        out.get(d).push(id);
        indeg.set(id, (indeg.get(id) ?? 0) + 1);
      }
      for (const d of e.mod.optionalDeps ?? []) {
        if (this.entries.has(d)) {
          out.get(d).push(id);
          indeg.set(id, (indeg.get(id) ?? 0) + 1);
        }
      }
    }
    const ready = Array.from(indeg.entries()).filter(([, n]) => n === 0).map(([id]) => id).sort();
    const result = [];
    while (ready.length > 0) {
      const id = ready.shift();
      result.push(id);
      const next = [];
      for (const succ of out.get(id)) {
        const n = (indeg.get(succ) ?? 1) - 1;
        indeg.set(succ, n);
        if (n === 0) next.push(succ);
      }
      next.sort();
      ready.push(...next);
      ready.sort();
    }
    if (result.length !== this.entries.size) {
      const stuck = Array.from(this.entries.keys()).filter((id) => !result.includes(id)).sort();
      return err({
        code: "MODULE.CYCLE",
        message: `\u6A21\u5757\u4F9D\u8D56\u5B58\u5728\u73AF\uFF0C\u6D89\u53CA\uFF1A${stuck.join(", ")}\u3002\u73AF\u610F\u5473\u7740"\u8C01\u5148\u542F\u52A8"\u6CA1\u6709\u7B54\u6848\uFF0C\u5FC5\u987B\u62C6\u5F00`,
        detail: { stuck }
      });
    }
    return ok(result);
  }
  /** 初始化并启动全部模块。失败时**已启动的逆序回滚**。 */
  async start() {
    if (this.started) {
      return err({ code: "MODULE.ALREADY_STARTED", message: "\u5DF2\u7ECF\u542F\u52A8\u8FC7" });
    }
    const sorted = this.topoSort();
    if (!sorted.ok) return sorted;
    this.order = sorted.value;
    const log = this.ctx.log.channel("module");
    for (const id of this.order) {
      const e = this.entries.get(id);
      const r = await this.withTimeout(e.mod.init(this.ctx), id, "init");
      if (!r.ok) {
        e.state = ModuleState.Failed;
        e.error = r.error;
        log.error(`\u6A21\u5757 ${id} init \u5931\u8D25\uFF1A${r.error.message}`, { code: r.error.code });
        await this.rollback(id);
        return err({
          code: "MODULE.INIT_FAILED",
          message: `\u6A21\u5757 ${id} init \u5931\u8D25\uFF1A${r.error.message}`,
          detail: { moduleId: id, cause: r.error }
        });
      }
      e.state = ModuleState.Initialized;
    }
    for (const id of this.order) {
      const e = this.entries.get(id);
      if (e.mod.start === void 0) {
        e.state = ModuleState.Started;
        continue;
      }
      const r = await this.withTimeout(e.mod.start(), id, "start");
      if (!r.ok) {
        e.state = ModuleState.Failed;
        e.error = r.error;
        log.error(`\u6A21\u5757 ${id} start \u5931\u8D25\uFF1A${r.error.message}`, { code: r.error.code });
        await this.rollback(id);
        return err({
          code: "MODULE.START_FAILED",
          message: `\u6A21\u5757 ${id} start \u5931\u8D25\uFF1A${r.error.message}`,
          detail: { moduleId: id, cause: r.error }
        });
      }
      e.state = ModuleState.Started;
    }
    this.started = true;
    log.info(`\u6A21\u5757\u542F\u52A8\u5B8C\u6210\uFF1A${this.order.length} \u4E2A\uFF08${this.order.join(" \u2192 ")}\uFF09`);
    return ok(void 0);
  }
  /** 逆序 stop + dispose。单个模块抛错不阻断其余（但那一条会被记录并上抛）。 */
  async dispose() {
    const log = this.ctx.log.channel("module");
    const failures = [];
    for (const id of [...this.order].reverse()) {
      const e = this.entries.get(id);
      if (e === void 0) continue;
      if (e.state === ModuleState.Started) {
        try {
          e.mod.stop?.();
        } catch (ex) {
          failures.push(`${id}.stop: ${ex instanceof Error ? ex.message : String(ex)}`);
        }
        e.state = ModuleState.Stopped;
      }
      if (e.state === ModuleState.Stopped || e.state === ModuleState.Initialized) {
        try {
          e.mod.dispose?.();
        } catch (ex) {
          failures.push(`${id}.dispose: ${ex instanceof Error ? ex.message : String(ex)}`);
        }
        e.state = ModuleState.Disposed;
      }
    }
    this.started = false;
    if (failures.length > 0) {
      log.error(`\u91CA\u653E\u65F6 ${failures.length} \u9879\u5931\u8D25`, { failures });
      return err({
        code: "MODULE.DISPOSE_FAILED",
        message: `\u91CA\u653E\u65F6\u6709 ${failures.length} \u9879\u5931\u8D25`,
        detail: { failures }
      });
    }
    return ok(void 0);
  }
  /** 诊断快照：编辑器与 healthz 用同一份（避免两套状态描述）。 */
  snapshot() {
    return this.order.map((id) => {
      const e = this.entries.get(id);
      return {
        id,
        state: e.state,
        desc: e.mod.describe?.() ?? ""
      };
    });
  }
  async rollback(failingId) {
    const idx = this.order.indexOf(failingId);
    const done = idx >= 0 ? this.order.slice(0, idx) : this.order.slice();
    for (const id of [...done].reverse()) {
      const e = this.entries.get(id);
      try {
        if (e.state === ModuleState.Started) e.mod.stop?.();
        if (e.state !== ModuleState.Created) e.mod.dispose?.();
      } catch {
      }
      e.state = ModuleState.Disposed;
    }
  }
  /** 把 `void | Result | Promise<...>` 归一成 `Promise<Result>`。 */
  async withTimeout(p, id, phase) {
    const ms = this.opts.initTimeoutMs ?? 0;
    if (ms <= 0) {
      const v = await p;
      return v === void 0 ? ok(void 0) : v;
    }
    let timer;
    const timeout = new Promise((resolve) => {
      timer = setTimeout(
        () => resolve(
          err({
            code: "MODULE.TIMEOUT",
            message: `${id}.${phase} \u8D85\u8FC7 ${ms} ms`
          })
        ),
        ms
      );
    });
    const normalized = Promise.resolve(p).then(
      (v) => v === void 0 ? ok(void 0) : v
    );
    try {
      return await Promise.race([normalized, timeout]);
    } finally {
      if (timer !== void 0) clearTimeout(timer);
    }
  }
};

// src/core/module/services.ts
function defineService(key) {
  return { key };
}
var ServiceRegistry = class {
  map = /* @__PURE__ */ new Map();
  owner = /* @__PURE__ */ new Map();
  /**
   * 注册服务。`ownerId` 只用于诊断（"这个服务是谁提供的"）。
   * 重复注册直接抛：静默覆盖会让"到底注入的是哪个"变成运气。
   */
  provide(token, impl, ownerId = "unknown") {
    if (this.map.has(token)) {
      throw new Error(
        `\u670D\u52A1 ${token.key} \u5DF2\u88AB ${this.owner.get(token)} \u63D0\u4F9B\uFF0C${ownerId} \u4E0D\u80FD\u91CD\u590D\u63D0\u4F9B\uFF08\u8981\u66FF\u6362\u8BF7\u5148 revoke\uFF0C\u5BBF\u4E3B\u7EC4\u88C5\u9636\u6BB5\u624D\u5141\u8BB8\u66FF\u6362\uFF09`
      );
    }
    this.map.set(token, impl);
    this.owner.set(token, ownerId);
  }
  /** 供宿主在测试/热替换时显式撤销。 */
  revoke(token) {
    this.map.delete(token);
    this.owner.delete(token);
  }
  /** 可选取：没有就 undefined（软依赖用它）。 */
  get(token) {
    return this.map.get(token);
  }
  /** 必需取：没有就抛，并在错误里列出当前已提供的服务（便于一眼看出拼错）。 */
  require(token) {
    const v = this.map.get(token);
    if (v === void 0) {
      throw new Error(
        `\u7F3A\u5C11\u5FC5\u9700\u670D\u52A1 ${token.key}\u3002\u5DF2\u63D0\u4F9B\uFF1A${Array.from(this.map.keys()).map((t) => t.key).sort().join(", ") || "(\u7A7A)"}`
      );
    }
    return v;
  }
  has(token) {
    return this.map.has(token);
  }
  describe() {
    return Array.from(this.map.keys()).map((t) => ({ key: t.key, owner: this.owner.get(t) ?? "?" })).sort((a, b) => a.key.localeCompare(b.key));
  }
  dispose() {
    this.map.clear();
    this.owner.clear();
  }
};

// src/core/scene/component.ts
var FieldType = {
  Int: "i32",
  Float: "f32",
  Double: "f64",
  Bool: "bool",
  String: "string",
  Vec2: "vec2",
  Color: "color",
  /** 资产引用：存 AssetId（GUID），不存路径 —— 路径会变，GUID 不会。 */
  Asset: "asset",
  /** 场景内节点引用：存节点 id。 */
  NodeRef: "noderef",
  /** 字符串数组（标签、配方列表）。 */
  StringArray: "string[]"
};
function zeroValue(t) {
  switch (t) {
    case FieldType.Int:
    case FieldType.Float:
    case FieldType.Double:
      return 0;
    case FieldType.Bool:
      return false;
    case FieldType.String:
      return "";
    case FieldType.Vec2:
      return { x: 0, y: 0 };
    case FieldType.Color:
      return { r: 1, g: 1, b: 1, a: 1 };
    case FieldType.Asset:
    case FieldType.NodeRef:
      return "";
    case FieldType.StringArray:
      return [];
    default:
      return null;
  }
}
var Component = class {
  /** 所属节点。`null` 只在 attach 之前/ detach 之后。 */
  node = null;
  enabled = true;
  /** 场景内部用：记录 enabled 状态，避免重复触发 onEnable。 */
  lastActive = false;
  /** 便捷：组件类型（来自 schema，避免两处写）。 */
  get type() {
    return this.schema.type;
  }
  onAttach() {
  }
  onDetach() {
  }
  onEnable() {
  }
  onDisable() {
  }
  onUpdate(_tick, _dt) {
  }
  /** 通用保存：按 schema 逐字段取。**顺序由 schema 决定**（字节确定）。 */
  save() {
    const out = { type: this.schema.type };
    for (const k of Object.keys(this.schema.fields)) {
      const v = this[k];
      out[k] = v === void 0 ? zeroValue(this.schema.fields[k]) : v;
    }
    return out;
  }
  /**
   * 通用读取。**缺字段时保留实例上的值**（类初始化器就是这个字段的出生默认值），
   * 同时把缺失的字段名报告给调用方（AssetDatabase / 存档）判断"是不是旧版本"。
   *
   * ★★ 为什么不是"缺字段填类型零值"（这是被一条真判据逼出来的改动）：
   *   schema 演化时唯一可能正确的默认值写在**类的初始化器**里
   *   （`pivotX = 0.5`）。压成零值的话，旧存档读回来 `pivotX = 0` ——
   *   所有已有精灵右移半格，而**新存档完全正常**，所以新写的判据一个都不会红。
   *   这类错误只在"用户打开旧档"时出现，也就是永远不会在开发机上出现。
   *   实测：`Sprite.pivotX` 加进来的当天，这一条就抓到了（world-visuals 的旧档判据）。
   *
   * 顺序：实例已有值 → `schema.defaults`（显式声明的默认值） → 类型零值（字段压根没声明）。
   */
  load(data) {
    const missing = [];
    const self = this;
    for (const [k, t] of Object.entries(this.schema.fields)) {
      if (data[k] === void 0) {
        missing.push(k);
        if (self[k] !== void 0) continue;
        self[k] = this.schema.defaults?.[k] ?? zeroValue(t);
        continue;
      }
      self[k] = data[k];
    }
    return { missing };
  }
  /** 场景内部：由 Scene 调用，管理 onEnable/onDisable 的边沿。 */
  _setActive(active) {
    if (active === this.lastActive) return;
    this.lastActive = active;
    if (active) this.onEnable();
    else this.onDisable();
  }
  get isActive() {
    return this.lastActive;
  }
};
function isFastForwardable(c) {
  return typeof c.onFastForward === "function";
}
var ComponentRegistry = class {
  factories = /* @__PURE__ */ new Map();
  schemas = /* @__PURE__ */ new Map();
  register(schema, factory) {
    if (this.factories.has(schema.type)) {
      throw new Error(`\u7EC4\u4EF6\u7C7B\u578B ${schema.type} \u5DF2\u6CE8\u518C\uFF08\u540C\u7C7B\u578B\u4E0D\u5141\u8BB8\u91CD\u590D\u6CE8\u518C\uFF09`);
    }
    this.factories.set(schema.type, factory);
    this.schemas.set(schema.type, schema);
  }
  create(type) {
    return this.factories.get(type)?.();
  }
  schemaOf(type) {
    return this.schemas.get(type);
  }
  has(type) {
    return this.factories.has(type);
  }
  types() {
    return Array.from(this.factories.keys()).sort();
  }
};

// src/foundation/math/vec.ts
var Vec2 = class _Vec2 {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
  static zero = new _Vec2(0, 0);
  static one = new _Vec2(1, 1);
  static up = new _Vec2(0, 1);
  static right = new _Vec2(1, 0);
  add(v) {
    return new _Vec2(this.x + v.x, this.y + v.y);
  }
  sub(v) {
    return new _Vec2(this.x - v.x, this.y - v.y);
  }
  scale(s) {
    return new _Vec2(this.x * s, this.y * s);
  }
  dot(v) {
    return this.x * v.x + this.y * v.y;
  }
  /** 二维叉积（标量），用于判定左右与三角形朝向。 */
  cross(v) {
    return this.x * v.y - this.y * v.x;
  }
  get lengthSq() {
    return this.x * this.x + this.y * this.y;
  }
  get length() {
    return Math.sqrt(this.lengthSq);
  }
  /** 零向量归一化返回零向量，不产生 NaN。 */
  normalized() {
    const l = this.length;
    return l > 0 ? new _Vec2(this.x / l, this.y / l) : _Vec2.zero;
  }
  equals(v, eps = 0) {
    return Math.abs(this.x - v.x) <= eps && Math.abs(this.y - v.y) <= eps;
  }
  toString() {
    return `(${this.x}, ${this.y})`;
  }
};
var Vec3 = class _Vec3 {
  constructor(x, y, z) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
  static zero = new _Vec3(0, 0, 0);
  static one = new _Vec3(1, 1, 1);
  add(v) {
    return new _Vec3(this.x + v.x, this.y + v.y, this.z + v.z);
  }
  sub(v) {
    return new _Vec3(this.x - v.x, this.y - v.y, this.z - v.z);
  }
  scale(s) {
    return new _Vec3(this.x * s, this.y * s, this.z * s);
  }
  dot(v) {
    return this.x * v.x + this.y * v.y + this.z * v.z;
  }
  cross(v) {
    return new _Vec3(
      this.y * v.z - this.z * v.y,
      this.z * v.x - this.x * v.z,
      this.x * v.y - this.y * v.x
    );
  }
  get lengthSq() {
    return this.x * this.x + this.y * this.y + this.z * this.z;
  }
  get length() {
    return Math.sqrt(this.lengthSq);
  }
  normalized() {
    const l = this.length;
    return l > 0 ? new _Vec3(this.x / l, this.y / l, this.z / l) : _Vec3.zero;
  }
  /** 取 XZ 平面（2.5D 里"地面"就是 XZ）。 */
  toXZ() {
    return new Vec2(this.x, this.z);
  }
  toString() {
    return `(${this.x}, ${this.y}, ${this.z})`;
  }
};

// src/foundation/math/geometry.ts
var Rect = class _Rect {
  constructor(x, y, width, height) {
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }
  static zero = new _Rect(0, 0, 0, 0);
  get xMin() {
    return this.x;
  }
  get yMin() {
    return this.y;
  }
  get xMax() {
    return this.x + this.width;
  }
  get yMax() {
    return this.y + this.height;
  }
  get center() {
    return new Vec2(this.x + this.width / 2, this.y + this.height / 2);
  }
  contains(p) {
    return p.x >= this.xMin && p.x <= this.xMax && p.y >= this.yMin && p.y <= this.yMax;
  }
  /** 相交判定用 `<` 而非 `<=`：贴边不算重叠（与 SAT 的严格内部分离一致）。 */
  intersects(o) {
    return this.xMin < o.xMax && this.xMax > o.xMin && this.yMin < o.yMax && this.yMax > o.yMin;
  }
  intersect(o) {
    const x0 = Math.max(this.xMin, o.xMin);
    const y0 = Math.max(this.yMin, o.yMin);
    const x1 = Math.min(this.xMax, o.xMax);
    const y1 = Math.min(this.yMax, o.yMax);
    return new _Rect(x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0));
  }
  expand(by) {
    return new _Rect(this.x - by, this.y - by, this.width + by * 2, this.height + by * 2);
  }
};
var Color = class _Color {
  constructor(r, g, b, a = 1) {
    this.r = r;
    this.g = g;
    this.b = b;
    this.a = a;
  }
  static white = new _Color(1, 1, 1, 1);
  static black = new _Color(0, 0, 0, 1);
  static transparent = new _Color(0, 0, 0, 0);
  /** `0xRRGGBBAA` → Color。资产文件里用得多。 */
  static fromRgba8(rgba) {
    return new _Color(
      (rgba >>> 24 & 255) / 255,
      (rgba >>> 16 & 255) / 255,
      (rgba >>> 8 & 255) / 255,
      (rgba & 255) / 255
    );
  }
  toArray() {
    return [this.r, this.g, this.b, this.a];
  }
};
var Affine2 = class _Affine2 {
  constructor(m00, m01, m02, m10, m11, m12) {
    this.m00 = m00;
    this.m01 = m01;
    this.m02 = m02;
    this.m10 = m10;
    this.m11 = m11;
    this.m12 = m12;
  }
  static identity = new _Affine2(1, 0, 0, 0, 1, 0);
  static fromTrs(pos, rotationRad, scale) {
    const c = Math.cos(rotationRad);
    const s = Math.sin(rotationRad);
    return new _Affine2(c * scale.x, -s * scale.y, pos.x, s * scale.x, c * scale.y, pos.y);
  }
  /** this ∘ o（先应用 o，再应用 this）—— 与父子变换的语义一致。 */
  multiply(o) {
    return new _Affine2(
      this.m00 * o.m00 + this.m01 * o.m10,
      this.m00 * o.m01 + this.m01 * o.m11,
      this.m00 * o.m02 + this.m01 * o.m12 + this.m02,
      this.m10 * o.m00 + this.m11 * o.m10,
      this.m10 * o.m01 + this.m11 * o.m11,
      this.m10 * o.m02 + this.m11 * o.m12 + this.m12
    );
  }
  transformPoint(p) {
    return new Vec2(
      this.m00 * p.x + this.m01 * p.y + this.m02,
      this.m10 * p.x + this.m11 * p.y + this.m12
    );
  }
  /** 展开成 WebGL 需要的 9 元素列主序数组。 */
  toMat3Array(out) {
    const m = out ?? new Float32Array(9);
    m[0] = this.m00;
    m[1] = this.m10;
    m[2] = 0;
    m[3] = this.m01;
    m[4] = this.m11;
    m[5] = 0;
    m[6] = this.m02;
    m[7] = this.m12;
    m[8] = 1;
    return m;
  }
  equals(o, eps = 1e-9) {
    return Math.abs(this.m00 - o.m00) <= eps && Math.abs(this.m01 - o.m01) <= eps && Math.abs(this.m02 - o.m02) <= eps && Math.abs(this.m10 - o.m10) <= eps && Math.abs(this.m11 - o.m11) <= eps && Math.abs(this.m12 - o.m12) <= eps;
  }
};

// src/core/scene/node.ts
var NEXT_NODE_ID = 1;
var Node = class {
  id;
  name;
  parent = null;
  children = [];
  components = [];
  /** 局部变换成分。改它们要调 `markTransformDirty()`（或用 setter）。 */
  localPosition = Vec2.zero;
  localRotation = 0;
  localScale = Vec2.one;
  /** 层级顺序微调（同一父下 `zIndex` 大的后画）。 */
  zIndex = 0;
  /** 整棵子树的开关：`false` 时组件不更新、不渲染。 */
  active = true;
  /** 渲染层（编辑器可以按层隐藏）。 */
  layer = 0;
  /** 变换版本：任何影响世界变换的改动都 +1。 */
  version = 0;
  cacheVersion = -1;
  cachedWorld = Affine2.identity;
  destroyed = false;
  constructor(name = "Node", id) {
    this.id = id ?? NEXT_NODE_ID++;
    if (id !== void 0) NEXT_NODE_ID = Math.max(NEXT_NODE_ID, id + 1);
    this.name = name;
  }
  get isDestroyed() {
    return this.destroyed;
  }
  addChild(child) {
    if (child.parent === this) return this;
    child.parent?.removeChild(child);
    child.parent = this;
    this.children.push(child);
    child.markTransformDirty();
    return this;
  }
  removeChild(child) {
    const i = this.children.indexOf(child);
    if (i < 0) return false;
    this.children.splice(i, 1);
    child.parent = null;
    child.markTransformDirty();
    return true;
  }
  attach(c) {
    if (c.node === this) return;
    c.node?.detach(c);
    c.node = this;
    this.components.push(c);
    c.onAttach();
  }
  detach(c) {
    const i = this.components.indexOf(c);
    if (i < 0) return false;
    if (c.isActive) c._setActive(false);
    this.components.splice(i, 1);
    c.node = null;
    c.onDetach();
    return true;
  }
  get(type) {
    for (const c of this.components) if (c.type === type) return c;
    return void 0;
  }
  /** 世界变换（惰性 + 版本缓存）。 */
  get worldTransform() {
    if (this.cacheVersion === this.version) return this.cachedWorld;
    const local = Affine2.fromTrs(this.localPosition, this.localRotation, this.localScale);
    const w = this.parent === null ? local : this.parent.worldTransform.multiply(local);
    this.cachedWorld = w;
    this.cacheVersion = this.version;
    return w;
  }
  get worldPosition() {
    return this.worldTransform.transformPoint(Vec2.zero);
  }
  setLocalPosition(x, y) {
    this.localPosition = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }
  /** ★ 一律用 setter：直接赋 `localScale` 字段**不会**推进版本号 ⇒ 世界变换用旧缓存。 */
  setLocalScale(x, y) {
    this.localScale = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }
  setLocalRotation(rad) {
    this.localRotation = rad;
    this.markTransformDirty();
    return this;
  }
  /** 标脏：自己 + 整棵子树（子节点的世界变换都依赖我）。 */
  markTransformDirty() {
    this.version++;
    for (const c of this.children) c.markTransformDirty();
  }
  /** 是否在整条祖先链上都 active。 */
  get activeInHierarchy() {
    let n = this;
    while (n !== null) {
      if (!n.active) return false;
      n = n.parent;
    }
    return true;
  }
  /** 深度优先遍历（顺序**确定**：子节点按添加顺序）。 */
  walk(fn) {
    fn(this);
    for (const c of this.children) c.walk(fn);
  }
  /** 从根到自己的路径（诊断/日志用）。 */
  path() {
    const parts = [];
    let n = this;
    while (n !== null) {
      parts.unshift(n.name);
      n = n.parent;
    }
    return "/" + parts.join("/");
  }
  /** 内部：销毁时标记，避免使用已销毁节点。 */
  _markDestroyed() {
    this.destroyed = true;
    for (const c of this.components) {
      if (c.isActive) c._setActive(false);
      c.node = null;
      c.onDetach();
    }
    this.components.length = 0;
    for (const c of this.children) c._markDestroyed();
    this.children.length = 0;
    this.parent = null;
  }
};

// src/core/scene/scene.ts
var Scene = class {
  name;
  root;
  byId = /* @__PURE__ */ new Map();
  /** 类型 → 组件集合。用数组而非 Set：遍历要顺序稳定且可索引。 */
  byType = /* @__PURE__ */ new Map();
  /** 类型更新顺序：按首次注册的稳定序（不是节点顺序）。 */
  typeOrder = [];
  pending = [];
  _steps = 0;
  _updates = 0;
  _fastForwarded = 0;
  /**
   * 本世界的节点 id 分配器（root 固定 1，新节点从 2 起）。
   *
   * ★★ 为什么**不能**用模块级全局自增（阶段 2 改的）：
   *   `Node` 原本有个进程级 `NEXT_NODE_ID`，于是第二个 `Scene` 的第一个节点是 3。
   *   后果比"id 不好看"严重得多：
   *     · **存档不可比** —— 同种子同操作的两个世界，存档只差 id，逐字节比对永远失败
   *       （脚本层出口判据就是这么抓到的）；
   *     · **PIE 两个世界**（编辑器 + 预览）的 id 交错，粘贴一个 prefab 过去会撞 id；
   *     · 回放时 id 依赖"这台机器之前跑过什么"。
   *   每个世界自己的 id 空间反而是**更强**的性质：存档可以跨世界互换。
   *   `Node` 的全局分配器保留给"游离节点"（判据、编辑器里还没入场景的对象）。
   */
  nextId = 2;
  allocateId(explicit) {
    if (explicit !== void 0) {
      if (explicit >= this.nextId) this.nextId = explicit + 1;
      return explicit;
    }
    return this.nextId++;
  }
  /** 组件注册表：编辑器"可挂哪些组件"、读档"遇到未知类型找谁"都读它。 */
  components;
  constructor(name, components) {
    this.components = components;
    this.name = name;
    this.root = new Node("__root__", 1);
    this.byId.set(this.root.id, this.root);
  }
  // ---------------------------------------------------------------- 查询
  get rootId() {
    return this.root.id;
  }
  find(id) {
    return this.byId.get(id);
  }
  /** 按类型取全部组件（返回内部数组，**只读用**；要改请走命令）。 */
  componentsOf(type) {
    return this.byType.get(type) ?? [];
  }
  countOf(type) {
    return this.byType.get(type)?.length ?? 0;
  }
  // ---------------------------------------------------------------- 结构性修改（排队）
  spawn(name, parent = this.root.id, id) {
    const nid = this.allocateId(id);
    if (this.byId.has(nid)) {
      return err({ code: "SCENE.DUPLICATE_ID", message: `\u8282\u70B9 id ${nid} \u5DF2\u5B58\u5728` });
    }
    const node = new Node(name, nid);
    this.pending.push({ kind: "spawn", node, parent });
    return ok(node);
  }
  /** 立即建好（加载/编辑器用）。**游戏逻辑里请用 spawn（走队列）**。 */
  spawnImmediate(name, parent = this.root.id, id) {
    const node = new Node(name, this.allocateId(id));
    this.attachNodeTo(node, parent);
    return node;
  }
  destroy(id) {
    this.pending.push({ kind: "destroy", node: id });
  }
  attach(nodeId, make) {
    const c = make();
    if (!this.components.has(c.type)) {
      return err({
        code: "SCENE.UNKNOWN_COMPONENT",
        message: `\u7EC4\u4EF6\u7C7B\u578B ${c.type} \u672A\u6CE8\u518C\uFF08\u5148 components.register\uFF09`
      });
    }
    this.pending.push({ kind: "attach", node: nodeId, component: c });
    return ok(c);
  }
  detach(nodeId, type) {
    this.pending.push({ kind: "detach", node: nodeId, type });
  }
  reparent(nodeId, newParent) {
    this.pending.push({ kind: "reparent", node: nodeId, parent: newParent });
  }
  /** 排队一个任意回调（在同一处 flush 执行 ⇒ 顺序确定）。 */
  enqueue(fn, label = "custom") {
    this.pending.push({ kind: "run", fn, label });
  }
  get pendingCount() {
    return this.pending.length;
  }
  /**
   * 执行排队命令。
   * ★ 用**队列置换**而不是边遍历边 shift：命令里可能再 spawn（入新队列），
   *   那样本帧不会无限膨胀，且顺序严格按投递序。
   */
  flush() {
    if (this.pending.length === 0) return 0;
    const run = this.pending;
    this.pending = [];
    let n = 0;
    for (const cmd of run) {
      switch (cmd.kind) {
        case "spawn":
          if (!cmd.node.isDestroyed) this.attachNodeTo(cmd.node, cmd.parent);
          break;
        case "destroy": {
          const node = this.byId.get(cmd.node);
          if (node !== void 0 && node.parent !== null) this.detachNode(node, true);
          break;
        }
        case "attach": {
          const node = this.byId.get(cmd.node);
          if (node !== void 0) this.attachTo(node, cmd.component);
          break;
        }
        case "detach": {
          const node = this.byId.get(cmd.node);
          const c = node?.get(cmd.type);
          if (node !== void 0 && c !== void 0) this.detachFrom(node, c);
          break;
        }
        case "reparent": {
          const node = this.byId.get(cmd.node);
          const parent = cmd.parent === null ? this.root : this.byId.get(cmd.parent);
          if (node !== void 0 && parent !== void 0) {
            parent.addChild(node);
            node.markTransformDirty();
          }
          break;
        }
        case "run":
          cmd.fn();
          break;
      }
      n++;
    }
    return n;
  }
  // ---------------------------------------------------------------- 步进
  /**
   * 推进一个固定步。
   * 顺序：flush（结构命令）→ 逐类型更新组件 → 再 flush（更新期投递的命令）
   * 两次 flush 是必须的：更新里投递的"销毁自己"不该延迟到下一帧。
   */
  step(tick, dt) {
    this.flush();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === void 0 || list.length === 0) continue;
      const n = list.length;
      for (let i = 0; i < n; i++) {
        const c = list[i];
        if (c === void 0 || c.node === null) continue;
        const active = c.enabled && c.node.activeInHierarchy;
        c._setActive(active);
        if (active) {
          c.onUpdate(tick, dt);
          this._updates++;
        }
      }
    }
    this.flush();
    this._steps++;
  }
  /**
   * 跳时间结算（`LongUpdate` 语义）。
   *
   * 场景：存档 → 离线 8 小时 → 读档。不能真的跑 864000 个 tick，
   * 所以让**实现了 `IFastForwardable` 的组件**按解析式结算 elapsed 秒。
   *
   * ★ 关键设计：**报告跳过了多少**。没实现该接口的组件（例如 AI、
   *   状态机）在跳过的时段里"什么都没发生" —— 这必须是一个**可见的事实**，
   *   而不是"看起来读档成功了"。调用方据此决定"要不要改成循环 step"。
   */
  fastForward(elapsedSec) {
    if (!(elapsedSec >= 0)) {
      throw new RangeError(`fastForward \u4E0D\u63A5\u53D7\u8D1F\u7684 elapsed\uFF1A${elapsedSec}`);
    }
    let handled = 0;
    let skipped = 0;
    const skippedByType = /* @__PURE__ */ new Map();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === void 0) continue;
      for (const c of list) {
        if (c.node === null) continue;
        if (isFastForwardable(c)) {
          c.onFastForward(elapsedSec);
          handled++;
        } else {
          skipped++;
          skippedByType.set(type, (skippedByType.get(type) ?? 0) + 1);
        }
      }
    }
    this._fastForwarded += elapsedSec;
    return { elapsed: elapsedSec, handled, skipped, skippedByType };
  }
  /** 累计跳过的秒数（诊断：用来判断"这个存档是不是被跳过太多次"）。 */
  get totalFastForwarded() {
    return this._fastForwarded;
  }
  // ---------------------------------------------------------------- 内部
  attachNodeTo(node, parentId) {
    const parent = parentId === null ? this.root : this.byId.get(parentId);
    if (parent === void 0) {
      throw new Error(`spawn \u7684\u7236\u8282\u70B9 ${parentId} \u4E0D\u5B58\u5728\uFF08\u547D\u4EE4\u5DF2\u5165\u961F\uFF0C\u7236\u8282\u70B9\u53EF\u80FD\u5DF2\u88AB\u9500\u6BC1\uFF09`);
    }
    parent.addChild(node);
    node.walk((n) => {
      this.byId.set(n.id, n);
      for (const c of n.components) this.indexComponent(c);
    });
  }
  attachTo(node, c) {
    node.attach(c);
    this.indexComponent(c);
  }
  detachFrom(node, c) {
    this.unindexComponent(c);
    node.detach(c);
  }
  detachNode(node, recursive) {
    node.parent?.removeChild(node);
    node.walk((n) => {
      for (const c of [...n.components]) this.unindexComponent(c);
      this.byId.delete(n.id);
    });
    if (recursive) node._markDestroyed();
  }
  indexComponent(c) {
    let list = this.byType.get(c.type);
    if (list === void 0) {
      list = [];
      this.byType.set(c.type, list);
      this.typeOrder.push(c.type);
    }
    list.push(c);
  }
  unindexComponent(c) {
    const list = this.byType.get(c.type);
    if (list === void 0) return;
    const i = list.indexOf(c);
    if (i >= 0) list.splice(i, 1);
  }
  stats() {
    let comps = 0;
    for (const l of this.byType.values()) comps += l.length;
    return {
      nodes: this.byId.size,
      components: comps,
      pendingCommands: this.pending.length,
      stepsRun: this._steps,
      componentUpdates: this._updates
    };
  }
  /** 清空（切场景/读档前）。不走命令 —— 它的语义就是"立刻什么都没了"。 */
  clear() {
    for (const child of [...this.root.children]) {
      this.detachNode(child, true);
    }
    this.pending = [];
  }
  /** 新建一个带标准变换的节点（便捷）。 */
  spawnAt(name, x, z, parent = this.root.id) {
    const r = this.spawn(name, parent);
    if (r.ok) r.value.setLocalPosition(x, z);
    return r;
  }
  /** 世界坐标（便利方法，供 2.5D 用）。 */
  worldPositionOf(id) {
    return this.byId.get(id)?.worldPosition;
  }
};

// src/core/scheduler/scheduler.ts
var FixedStepScheduler = class {
  fixedDt;
  maxSteps;
  maxFrameDt;
  _tick = 0;
  _time = 0;
  _accumulator = 0;
  _timeScale;
  _paused = false;
  _dropped = 0;
  _total = 0;
  _lastSteps = 0;
  _alpha = 0;
  /** 记录"已经回调过的最大 tick"，幂等保护用。 */
  _served = -1;
  steps = [];
  constructor(cfg) {
    if (!(cfg.fixedDt > 0)) throw new RangeError("fixedDt \u5FC5\u987B > 0");
    this.fixedDt = cfg.fixedDt;
    this.maxSteps = cfg.maxStepsPerFrame ?? 5;
    this.maxFrameDt = cfg.maxFrameDt ?? 0.25;
    this._timeScale = cfg.timeScale ?? 1;
  }
  /** 订阅每一步。返回退订函数。 */
  onStep(fn) {
    this.steps.push(fn);
    return () => {
      const i = this.steps.indexOf(fn);
      if (i >= 0) this.steps.splice(i, 1);
    };
  }
  /**
   * 推进。返回本帧实际执行的步数。
   * `realDtSec` 是**真实**经过的秒数（来自 IClock 的差值），不是逻辑时间。
   */
  advance(realDtSec) {
    if (!(realDtSec >= 0)) {
      return 0;
    }
    if (this._paused) {
      this._lastSteps = 0;
      return 0;
    }
    const clamped = Math.min(realDtSec, this.maxFrameDt);
    this._accumulator += clamped * this._timeScale;
    let steps = 0;
    while (this._accumulator >= this.fixedDt && steps < this.maxSteps) {
      this._accumulator -= this.fixedDt;
      steps++;
    }
    if (this._accumulator >= this.fixedDt) {
      const leftover = Math.floor(this._accumulator / this.fixedDt);
      this._dropped += leftover;
      this._accumulator -= leftover * this.fixedDt;
    }
    for (let i = 0; i < steps; i++) {
      this._tick++;
      this._time = this._tick * this.fixedDt;
      this.runStep(this._tick, this.fixedDt);
    }
    this._lastSteps = steps;
    this._alpha = this._accumulator / this.fixedDt;
    return steps;
  }
  /**
   * 直接跳到某个 tick（编辑器"运行到此处"、回放快进用）。
   * ★ 幂等：`target <= 当前 tick` 返回 0，不重放。
   */
  stepTo(targetTick) {
    if (targetTick <= this._tick) return 0;
    const n = targetTick - this._tick;
    for (let i = 0; i < n; i++) {
      this._tick++;
      this._time = this._tick * this.fixedDt;
      this.runStep(this._tick, this.fixedDt);
    }
    this._lastSteps = n;
    return n;
  }
  /** 单步（编辑器单帧调试）。返回新 tick。 */
  stepOnce() {
    return this.stepTo(this._tick + 1);
  }
  runStep(tick, dt) {
    if (tick <= this._served) return;
    this._served = tick;
    this._total++;
    for (const fn of this.steps) fn(tick, dt);
  }
  set paused(v) {
    this._paused = v;
    if (!v) {
      this._accumulator = 0;
    }
  }
  get paused() {
    return this._paused;
  }
  set timeScale(v) {
    this._timeScale = clamp(v, 0.01, 16);
  }
  get timeScale() {
    return this._timeScale;
  }
  get tick() {
    return this._tick;
  }
  get time() {
    return this._time;
  }
  get alpha() {
    return this._alpha;
  }
  /** 存档/回放：把 tick 设回来（**不执行**中间的步）。 */
  resetTo(tick, served = tick) {
    this._tick = tick;
    this._time = tick * this.fixedDt;
    this._served = served;
    this._accumulator = 0;
    this._alpha = 0;
    this._lastSteps = 0;
  }
  stats() {
    return {
      tick: this._tick,
      time: this._time,
      lastSteps: this._lastSteps,
      droppedSteps: this._dropped,
      totalSteps: this._total,
      timeScale: this._timeScale,
      paused: this._paused,
      alpha: this._alpha
    };
  }
};

// src/core/asset/asset.ts
var AssetHandle = class {
  constructor(asset, onRelease) {
    this.asset = asset;
    this.onRelease = onRelease;
  }
  released = false;
  get id() {
    return this.asset.id;
  }
  release() {
    if (this.released) {
      this.onRelease(this.asset);
      return;
    }
    this.released = true;
    this.onRelease(this.asset);
  }
  get isReleased() {
    return this.released;
  }
};
var AssetDatabase = class {
  constructor(fs, log) {
    this.fs = fs;
    this.log = log;
  }
  slots = /* @__PURE__ */ new Map();
  byPath = /* @__PURE__ */ new Map();
  loaders = [];
  hit = 0;
  miss = 0;
  registerLoader(l) {
    this.loaders.push(l);
  }
  /** 注册/更新元数据。同一个 id 重复注册允许（= 重新导入），但会作废已加载实例。 */
  register(meta) {
    const prev = this.slots.get(meta.id);
    if (prev !== void 0) {
      if (prev.refs > 0) {
        return err({
          code: "ASSET.REIMPORT_WHILE_IN_USE",
          message: `\u8D44\u4EA7 ${meta.id} \u6B63\u88AB ${prev.refs} \u5904\u4F7F\u7528\uFF0C\u4E0D\u80FD\u91CD\u65B0\u5BFC\u5165\uFF08\u5148\u5168\u90E8 release\uFF09`
        });
      }
      if (prev.asset !== null) prev.asset.dispose();
      this.byPath.delete(prev.meta.path);
    }
    this.slots.set(meta.id, { meta, asset: null, refs: 0, inDegree: 0, loading: null });
    this.byPath.set(meta.path, meta.id);
    return ok(void 0);
  }
  meta(id) {
    return this.slots.get(id)?.meta;
  }
  /**
   * 反注册（源资产被删除）。
   *
   * ★ 为什么必须有（阶段 2 补）：导入器要处理"源文件被删了"——这是**正常事件**，
   *   不是异常。没有反注册时，删除只让文件消失、注册表里留下一条幽灵：
   *   `describe()` 还看得到它、`dependents()` 还把它算进依赖、`idAtPath` 还能查到，
   *   于是"这个资产到底还在不在"从可判定退化成了靠猜。
   *   上一代引擎里同类的债是"prefab 表只增不减"，改一版涨一版。
   *
   * 两条拒绝条件都不是保守，而是正确性：
   *   · `refs > 0`：有句柄在用，删了它句柄就指向已释放实例（随机崩）；
   *   · 有反向依赖：删了被引用的资产，依赖方下次加载会失败，而失败点离根因很远。
   * 都不满足才算"真的没人要它了"。
   */
  unregister(id) {
    const slot = this.slots.get(id);
    if (slot === void 0) return ok(void 0);
    if (slot.refs > 0) {
      return err({
        code: "ASSET.IN_USE",
        message: `\u8D44\u4EA7 ${id} \u8FD8\u6709 ${slot.refs} \u4E2A\u53E5\u67C4\u672A\u91CA\u653E\uFF0C\u4E0D\u80FD\u53CD\u6CE8\u518C`
      });
    }
    const users = this.dependents(id);
    if (users.length > 0) {
      return err({
        code: "ASSET.STILL_REFERENCED",
        message: `\u8D44\u4EA7 ${id} \u4ECD\u88AB ${users.join(", ")} \u4F9D\u8D56\uFF0C\u4E0D\u80FD\u53CD\u6CE8\u518C\uFF08\u5148\u5220\u4F9D\u8D56\u65B9\u7684\u5F15\u7528\uFF09`,
        detail: { id, dependents: users }
      });
    }
    this.byPath.delete(slot.meta.path);
    this.slots.delete(id);
    slot.asset?.dispose();
    return ok(void 0);
  }
  idAtPath(path) {
    return this.byPath.get(path);
  }
  /** 直接依赖 / 反向依赖（编辑器"谁用了它"）。 */
  dependencies(id) {
    return this.slots.get(id)?.meta.dependencies ?? [];
  }
  dependents(id) {
    const out = [];
    for (const [k, s] of this.slots) {
      if (s.meta.dependencies.includes(id)) out.push(k);
    }
    return out.sort();
  }
  /**
   * 加载。相同的 id 并发调用会**共享同一个 Promise**（不会加载两次）。
   * 依赖按 meta 里声明的顺序加载；任一失败则整体失败并回滚已加载的依赖计数。
   */
  async load(id, _stack = []) {
    const slot = this.slots.get(id);
    if (slot === void 0) {
      return err({
        code: "ASSET.NOT_REGISTERED",
        message: `\u8D44\u4EA7 ${id} \u672A\u6CE8\u518C\uFF08\u5148\u7531\u5BFC\u5165\u5668\u5199\u5165 meta\uFF09`
      });
    }
    if (_stack.includes(id)) {
      return err({
        code: "ASSET.DEPENDENCY_CYCLE",
        message: `\u8D44\u4EA7\u4F9D\u8D56\u6210\u73AF\uFF1A${[..._stack, id].join(" \u2192 ")}`,
        detail: { cycle: [..._stack, id] }
      });
    }
    if (slot.asset !== null) {
      this.hit++;
      slot.refs++;
      return ok(this.makeHandle(slot));
    }
    if (slot.loading !== null) {
      this.hit++;
      const r2 = await slot.loading;
      if (!r2.ok) return err(r2.error);
      slot.refs++;
      return ok(this.makeHandle(slot));
    }
    this.miss++;
    const p = this.doLoad(slot, [..._stack, id]);
    slot.loading = p;
    const r = await p;
    slot.loading = null;
    if (!r.ok) return err(r.error);
    slot.refs++;
    return ok(this.makeHandle(slot));
  }
  async doLoad(slot, stack) {
    const { meta } = slot;
    const loadedDeps = [];
    for (const depId of meta.dependencies) {
      const r = await this.load(depId, stack);
      if (!r.ok) {
        for (const d of loadedDeps) this.decRef(d);
        if (r.error.code === "ASSET.DEPENDENCY_CYCLE" || r.error.code === "ASSET.DEPENDENCY_FAILED") {
          return err(r.error);
        }
        return err({
          code: "ASSET.DEPENDENCY_FAILED",
          message: `\u8D44\u4EA7 ${meta.id} \u7684\u4F9D\u8D56 ${depId} \u52A0\u8F7D\u5931\u8D25\uFF1A${r.error.message}`,
          detail: { asset: meta.id, dep: depId, cause: r.error }
        });
      }
      loadedDeps.push(depId);
    }
    const loader = this.loaders.find((l) => l.types.includes(meta.type));
    if (loader === void 0) {
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.NO_LOADER",
        message: `\u6CA1\u6709\u80FD\u5904\u7406\u7C7B\u578B ${meta.type} \u7684\u52A0\u8F7D\u5668\uFF08\u5DF2\u6CE8\u518C\u7684\uFF1A${this.loaders.flatMap((l) => l.types).sort().join(", ") || "(\u7A7A)"}\uFF09`
      });
    }
    const ctx = {
      fs: this.fs,
      log: this.log,
      load: async (depId) => {
        const r = await this.load(depId, stack);
        return r.ok ? ok(r.value.asset) : err(r.error);
      }
    };
    let asset;
    try {
      const r = await loader.load(meta, ctx);
      if (!r.ok) {
        for (const d of loadedDeps) this.decRef(d);
        return err(r.error);
      }
      asset = r.value;
    } catch (e) {
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.LOADER_THREW",
        message: `\u52A0\u8F7D\u5668 ${meta.type} \u629B\u5F02\u5E38\uFF1A${e instanceof Error ? e.message : String(e)}`
      });
    }
    if (asset.id !== meta.id) {
      asset.dispose();
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.ID_MISMATCH",
        message: `\u52A0\u8F7D\u5668\u8FD4\u56DE\u7684\u8D44\u4EA7 id ${asset.id} \u4E0E\u8BF7\u6C42\u7684 ${meta.id} \u4E0D\u4E00\u81F4`
      });
    }
    slot.asset = asset;
    return ok(asset);
  }
  /** 减引用。`slots.get(x)?.refs--` 在 TS 里不合法（可选属性不能自减），必须走这个。 */
  decRef(id) {
    const s = this.slots.get(id);
    if (s !== void 0) s.refs = Math.max(0, s.refs - 1);
  }
  makeHandle(slot) {
    return new AssetHandle(slot.asset, (a) => {
      slot.refs = Math.max(0, slot.refs - 1);
      if (slot.refs === 0 && this.dependents(slot.meta.id).length === 0) {
        slot.asset?.dispose();
        slot.asset = null;
      }
    });
  }
  /**
   * 卸载计划：**依赖的反拓扑序**（先卸使用者，再卸被使用者）。
   * 编辑器"重新导入前先卸载"与关场景时用。
   */
  unloadPlan() {
    const loaded = Array.from(this.slots.entries()).filter(([, s]) => s.asset !== null).map(([id]) => id);
    const order = [];
    const state = /* @__PURE__ */ new Map();
    const visit = (id) => {
      const st = state.get(id) ?? 0;
      if (st !== 0) return;
      state.set(id, 1);
      for (const dep of this.dependencies(id)) visit(dep);
      state.set(id, 2);
      order.push(id);
    };
    for (const id of loaded.sort()) visit(id);
    return order.reverse();
  }
  /** 强制卸载全部（关场景）。返回真正释放的个数。 */
  unloadAll() {
    const plan = this.unloadPlan();
    for (const id of plan) {
      const s = this.slots.get(id);
      if (s?.asset != null) {
        s.asset.dispose();
        s.asset = null;
      }
      if (s !== void 0) s.refs = 0;
    }
    return plan.length;
  }
  stats() {
    let loaded = 0;
    let refs = 0;
    for (const s of this.slots.values()) {
      if (s.asset !== null) loaded++;
      refs += s.refs;
    }
    return {
      registered: this.slots.size,
      loaded,
      refs,
      cacheHit: this.hit,
      cacheMiss: this.miss
    };
  }
  /** 诊断：列出所有资产的 id / 类型 / 是否加载。 */
  describe() {
    return Array.from(this.slots.entries()).map(([id, s]) => ({
      id,
      type: s.meta.type,
      path: s.meta.path,
      loaded: s.asset !== null,
      refs: s.refs
    })).sort((a, b) => a.id.localeCompare(b.id));
  }
};

// src/core/tokens.ts
var Services = {
  /**
   * 帧宿主：提供 `onRender(fn)`。
   * ★ 为什么渲染不能靠"事件"：事件是"发生了什么，谁关心谁订阅"，
   *   而渲染是**每个宿主都必须执行的一个阶段**（哪怕没人订阅）。
   *   用事件的话，"没有任何渲染器订阅"与"渲染器都注销了"无法区分，
   *   画面会静默变黑。
   */
  Frame: defineService("core.frame"),
  Scene: defineService("core.scene"),
  Assets: defineService("core.assets"),
  Scheduler: defineService("core.scheduler"),
  /**
   * 脚本运行时（可空）。
   * ★ 为什么作为服务而不是"模块私有字段"：UI/AI/关卡这些上层模块都要调脚本，
   *   如果各自 new 一个运行时，就会出现"两个 VM 两份全局状态"——
   *   脚本里的全局变量会莫名其妙地不共享。
   */
  Script: defineService("core.script")
};

// src/runtime/GameApp.ts
var GameApp = class _GameApp {
  platform;
  log;
  memorySink;
  events = new EventBus();
  services = new ServiceRegistry();
  components = new ComponentRegistry();
  scene;
  scheduler;
  assets;
  modules;
  random;
  tickSource;
  /** 渲染阶段回调（`onRender` 注册）。按注册顺序执行。 */
  renderers = [];
  bag = new DisposableBag();
  frameCount = 0;
  running = false;
  disposed = false;
  constructor(opts, platform, log, memorySink, fs) {
    this.platform = platform;
    this.log = log;
    this.memorySink = memorySink;
    this.tickSource = opts.tickSource ?? null;
    this.random = new XorShift128(opts.seed);
    this.scheduler = new FixedStepScheduler({
      fixedDt: opts.fixedDt ?? 1 / 30,
      maxStepsPerFrame: opts.maxStepsPerFrame ?? 5
    });
    this.scene = new Scene("main", this.components);
    this.assets = new AssetDatabase(fs, log.channel("asset"));
    const renderers = this.renderers;
    const frameHost = {
      onRender: (fn) => {
        renderers.push(fn);
        return () => {
          const i = renderers.indexOf(fn);
          if (i >= 0) renderers.splice(i, 1);
        };
      },
      get rendererCount() {
        return renderers.length;
      }
    };
    this.services.provide(Services.Frame, frameHost, "core");
    this.services.provide(Services.Scene, this.scene, "core");
    this.services.provide(Services.Scheduler, this.scheduler, "core");
    this.services.provide(Services.Assets, this.assets, "core");
    this.services.provide(Services.Script, platform.script, "core");
    this.events.on("scheduler:steps-dropped", (p) => {
      log.channel("core.scheduler").warn(
        `\u5E27\u9884\u7B97\u4E0D\u8DB3\uFF0C\u4E22\u5F03\u4E86 ${p.dropped} \u4E2A\u903B\u8F91\u6B65\uFF08tick=${p.tick}\uFF09\u2014\u2014 \u4E16\u754C\u65F6\u95F4\u843D\u540E\u4E8E\u771F\u5B9E\u65F6\u95F4`,
        { dropped: p.dropped, tick: p.tick }
      );
    });
    const ctx = {
      log,
      events: this.events,
      services: this.services,
      platform,
      random: this.random,
      module: (id) => this.modules.get(id)
    };
    this.modules = new ModuleRegistry(ctx);
    for (const m of opts.modules) {
      const r = this.modules.register(m);
      if (!r.ok) {
        throw new Error(`\u6A21\u5757\u6CE8\u518C\u5931\u8D25\uFF1A${r.error.message}`);
      }
    }
    this.bag.add("platform", { dispose: () => platform.dispose() });
    this.bag.add("services", this.services);
    this.bag.add("logsink", { dispose: () => this.log.flush() });
  }
  static create(opts) {
    const memorySink = new MemorySink(4e3);
    const clock = opts.clock ?? new SystemClock();
    const log = new Logger(() => clock.now());
    log.addSink(new ConsoleSink(opts.logLevel ?? LogLevel.Info));
    log.addSink(memorySink);
    for (const s of opts.extraSinks ?? []) log.addSink(s);
    const platformR = createPlatform({
      id: opts.platformId,
      interactive: opts.interactive,
      registry: opts.registry,
      clock,
      ...opts.prefer === void 0 ? {} : { prefer: opts.prefer },
      ...opts.allow === void 0 ? {} : { allow: opts.allow },
      ...opts.backendOptions === void 0 ? {} : { backendOptions: opts.backendOptions }
    });
    if (!platformR.ok) {
      log.channel("app").error(`\u5E73\u53F0\u521B\u5EFA\u5931\u8D25\uFF1A${platformR.error.message}`, {
        code: platformR.error.code,
        detail: platformR.error.detail
      });
      return platformR;
    }
    const platform = platformR.value;
    const fs = opts.fs ?? platform.fs;
    log.channel("app").info(
      `\u5E73\u53F0\u5C31\u7EEA\uFF1A${platform.id} gfx=${platform.backends.gfx} audio=${platform.backends.audio} input=${platform.backends.input} fs=${platform.backends.fs} script=${platform.backends.script ?? "(\u65E0)"}`,
      { caps: platform.caps }
    );
    try {
      return ok(new _GameApp(opts, platform, log, memorySink, fs));
    } catch (e) {
      platform.dispose();
      return err(
        engineError("APP.CREATE_FAILED", `GameApp \u6784\u9020\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`)
      );
    }
  }
  /** 启动全部模块（拓扑序）。失败时模块已自行回滚。 */
  async start() {
    if (this.running) return err(engineError("APP.ALREADY_RUNNING", "\u5DF2\u7ECF\u5728\u8FD0\u884C"));
    const r = await this.modules.start();
    if (!r.ok) {
      this.events.emit("module:failed", { id: String(r.error.detail?.["moduleId"] ?? "?"), code: r.error.code, message: r.error.message });
      return r;
    }
    this.running = true;
    return ok(void 0);
  }
  /**
   * 推进一帧。`realDtSec` 是真实经过时间。
   * ★ 这是**唯一**的帧入口：外部（rAF / interval / 判据）都只能通过它驱动，
   *   否则"有两条帧路径"就必然有一条被忘记维护。
   */
  frame(realDtSec) {
    if (this.disposed) return;
    const before = this.scheduler.stats().droppedSteps;
    const steps = this.scheduler.advance(realDtSec);
    const after = this.scheduler.stats();
    if (after.droppedSteps > before) {
      this.events.emit("scheduler:steps-dropped", {
        dropped: after.droppedSteps - before,
        tick: after.tick
      });
    }
    this.frameCount++;
    const info = {
      frame: this.frameCount,
      realDtSec,
      steps,
      alpha: this.scheduler.alpha,
      tick: this.scheduler.tick
    };
    for (const fn of this.renderers) {
      try {
        fn(info);
      } catch (e) {
        this.log.channel("app.render").error(
          `\u6E32\u67D3\u56DE\u8C03\u629B\u9519\uFF1A${e instanceof Error ? e.message : String(e)}`,
          { frame: this.frameCount },
          null
        );
      }
    }
    this.events.emit("frame:end", {
      frame: this.frameCount,
      realDtMs: realDtSec * 1e3,
      steps
    });
  }
  /** 用 tickSource 自动驱动。没有 tickSource 时返回错误（不静默不动）。 */
  run() {
    if (this.tickSource === null) {
      return err(
        engineError("APP.NO_TICK_SOURCE", "\u6CA1\u6709 tickSource \u2014\u2014 \u7528 frame(dt) \u624B\u52A8\u9A71\u52A8\uFF0C\u6216\u5728 create \u65F6\u4F20 tickSource")
      );
    }
    if (this.tickSource.running) return ok(void 0);
    this.tickSource.start((dt) => this.frame(dt));
    return ok(void 0);
  }
  stopRun() {
    this.tickSource?.stop();
  }
  set paused(v) {
    this.scheduler.paused = v;
  }
  get paused() {
    return this.scheduler.paused;
  }
  set timeScale(v) {
    this.scheduler.timeScale = v;
  }
  get frameIndex() {
    return this.frameCount;
  }
  /** 诊断快照：`/healthz`、编辑器状态栏、判据都读这一份（避免三套描述）。 */
  snapshot() {
    return {
      platformId: this.platform.id,
      backends: this.platform.backends,
      tick: this.scheduler.tick,
      time: this.scheduler.time,
      paused: this.scheduler.paused,
      timeScale: this.scheduler.timeScale,
      droppedSteps: this.scheduler.stats().droppedSteps,
      scene: this.scene.stats(),
      assets: this.assets.stats(),
      modules: this.modules.snapshot(),
      eventStats: this.events.stats()
    };
  }
  /** 停止模块并释放。幂等。 */
  async dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.stopRun();
    const r = await this.modules.dispose();
    if (!r.ok) this.log.channel("app").error(`\u6A21\u5757\u91CA\u653E\u5931\u8D25\uFF1A${r.error.message}`);
    try {
      this.bag.dispose();
    } catch (e) {
      this.log.channel("app").error(`\u8D44\u6E90\u91CA\u653E\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`);
    }
    this.events.clear();
  }
};
async function bootGameApp(opts) {
  const appR = GameApp.create(opts);
  if (!appR.ok) return appR;
  const app = appR.value;
  const startR = await app.start();
  if (!startR.ok) {
    await app.dispose();
    return startR;
  }
  return ok(app);
}

// src/foundation/hash.ts
var FNV_PRIME = 16777619;
var FNV_BASIS_A = 2166136261;
var FNV_BASIS_B = 2654435769;
function hashStateCreate() {
  return { h1: FNV_BASIS_A, h2: FNV_BASIS_B, bytes: 0 };
}
function hashStateUpdate(s, bytes) {
  let h1 = s.h1;
  let h2 = s.h2;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    h1 = Math.imul(h1 ^ b, FNV_PRIME) >>> 0;
    h2 = Math.imul(h2 ^ b, FNV_PRIME) >>> 0;
  }
  s.h1 = h1;
  s.h2 = h2;
  s.bytes += bytes.length;
}
function hex8(n) {
  return (n >>> 0).toString(16).padStart(8, "0");
}
function hashStateHex(s) {
  return hex8(s.h1) + hex8(s.h2);
}
function hashBytes(bytes) {
  const s = hashStateCreate();
  hashStateUpdate(s, bytes);
  return hashStateHex(s);
}
function hashText(s) {
  return hashBytes(new TextEncoder().encode(s));
}

// src/platform/gfx/types.ts
var BufferUsage = {
  Vertex: 1,
  Index: 2,
  Uniform: 3
};
var PixelFormat = {
  RGBA8: "rgba8",
  RGB8: "rgb8",
  R8: "r8",
  /**
   * 16 位无符号归一化，每通道 0..65535（8 字节/像素）。
   * 进 GPU 的类型是 `UNSIGNED_SHORT` + 归一化采样：片元里拿到的仍是 0..1 的 float，
   * 只是**中间精度**不再被 8 位截断（渐变/法线/高度图不会出带状色块）。
   *
   * ★ 字节序边界：`Uint16Array` 的内存布局是宿主字节序；WebGL 的
   *   `UNSIGNED_SHORT` 纹理同样按宿主字节序解释，所以「值数组 → texImage2D」
   *   不需要交换字节。反过来说，**不能**把 PNG 里的大端原始字节直接塞进来。
   */
  RGBA16: "rgba16",
  /** 半精度浮点（8 字节/像素）。上传时需要真正的 half 字节流，不能直传 Float32Array。 */
  RGBA16F: "rgba16f"
};
function bytesPerPixel(format) {
  switch (format) {
    case PixelFormat.RGBA8:
      return 4;
    case PixelFormat.RGB8:
      return 3;
    case PixelFormat.R8:
      return 1;
    case PixelFormat.RGBA16:
      return 8;
    case PixelFormat.RGBA16F:
      return 8;
    default:
      throw new Error(`\u672A\u77E5 PixelFormat\uFF1A${String(format)}\uFF08bytesPerPixel \u6CA1\u6709\u9ED8\u8BA4\u503C\uFF0C\u4E0D\u731C\uFF09`);
  }
}
var TextureFilter = { Nearest: "nearest", Linear: "linear" };
var TextureWrap = { Clamp: "clamp", Repeat: "repeat" };
var SPRITE_VERTEX_LAYOUT = {
  attributes: [
    { name: "a_position", components: 2 },
    { name: "a_uv", components: 2 },
    { name: "a_color", components: 4 }
  ]
};
var BlendMode = { None: 0, Alpha: 1, Additive: 2, Premultiplied: 3 };
var Topology = { Triangles: 0, TriangleStrip: 1 };

// src/backends/gfx-null/device.ts
function asBytes(view) {
  return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
}
var NullGraphicsDevice = class {
  caps = {
    backend: "null",
    version: "1",
    maxTextureSize: 4096,
    maxTextureUnits: 8,
    maxVerticesPerDraw: 65536,
    instancing: false,
    floatTextures: false,
    readback: true,
    srgbTextures: false
  };
  nextHandle = 1;
  buffers = /* @__PURE__ */ new Map();
  textures = /* @__PURE__ */ new Map();
  shaders = /* @__PURE__ */ new Map();
  pipelines = /* @__PURE__ */ new Map();
  targets = /* @__PURE__ */ new Map();
  frameIndex = 0;
  current = null;
  _stats = {
    frameIndex: 0,
    drawCalls: 0,
    verticesSubmitted: 0,
    textureBindings: 0,
    pipelineSwitches: 0,
    bytesUploaded: 0
  };
  _size = { width: 0, height: 0 };
  /** 所有完成的帧（判据读最近若干帧）。 */
  frames = [];
  /** 错误调用记录：契约测试会断言"非法操作没有静默通过"。 */
  rejectedCalls = [];
  constructor(width = 1280, height = 720) {
    this._size = { width, height };
  }
  get stats() {
    return this._stats;
  }
  get size() {
    return this._size;
  }
  resize(width, height) {
    this._size = { width, height };
  }
  // ---------------------------------------------------------------- buffer
  createBuffer(desc) {
    if (!(desc.byteLength > 0)) {
      return err(engineError("GFX.BAD_BUFFER", `\u7F13\u51B2\u533A\u5927\u5C0F\u5FC5\u987B > 0\uFF0C\u6536\u5230 ${desc.byteLength}`));
    }
    if (desc.byteLength > 64 * 1024 * 1024) {
      return err(engineError("GFX.BAD_BUFFER", `\u7F13\u51B2\u533A\u8FC7\u5927\uFF1A${desc.byteLength} \u5B57\u8282\uFF08\u4E0A\u9650 64 MB\uFF09`));
    }
    const h = this.nextHandle++;
    this.buffers.set(h, {
      byteLength: desc.byteLength,
      usage: desc.usage,
      dynamic: desc.dynamic,
      label: desc.label ?? ""
    });
    return ok(h);
  }
  updateBuffer(handle, data, byteOffset = 0) {
    const rec = this.buffers.get(handle);
    if (rec === void 0) {
      this.rejectedCalls.push(`updateBuffer(\u65E0\u6548\u53E5\u67C4 ${handle})`);
      return err(engineError("GFX.INVALID_HANDLE", `\u7F13\u51B2\u533A\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728\uFF08\u53EF\u80FD\u5DF2\u9500\u6BC1\uFF09`));
    }
    const end = byteOffset + data.byteLength;
    if (byteOffset < 0 || end > rec.byteLength) {
      this.rejectedCalls.push(`updateBuffer(\u8D8A\u754C ${byteOffset}+${data.byteLength} > ${rec.byteLength})`);
      return err(
        engineError("GFX.BUFFER_OVERFLOW", `\u5199\u5165\u8D8A\u754C\uFF1Aoffset=${byteOffset} len=${data.byteLength} \u5BB9\u91CF=${rec.byteLength}`, {
          label: rec.label
        })
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
  }
  destroyBuffer(handle) {
    if (!this.buffers.delete(handle)) {
      this.rejectedCalls.push(`destroyBuffer(\u5DF2\u5931\u6548 ${handle})`);
    }
  }
  // ---------------------------------------------------------------- texture
  createTexture(desc, data) {
    if (!(desc.width > 0) || !(desc.height > 0)) {
      return err(engineError("GFX.BAD_TEXTURE", `\u7EB9\u7406\u5C3A\u5BF8\u975E\u6CD5\uFF1A${desc.width}x${desc.height}`));
    }
    if (desc.width > this.caps.maxTextureSize || desc.height > this.caps.maxTextureSize) {
      return err(
        engineError(
          "GFX.TEXTURE_TOO_LARGE",
          `\u7EB9\u7406 ${desc.width}x${desc.height} \u8D85\u8FC7\u4E0A\u9650 ${this.caps.maxTextureSize}`,
          { label: desc.label ?? "" }
        )
      );
    }
    const h = this.nextHandle++;
    const format = desc.format ?? PixelFormat.RGBA8;
    const bpp = bytesPerPixel(format);
    if (data !== void 0 && data !== null) {
      const expect = desc.width * desc.height * bpp;
      if (data.byteLength !== expect) {
        this.rejectedCalls.push(`createTexture(\u6570\u636E ${data.byteLength} != ${desc.width}x${desc.height}x${bpp})`);
        return err(
          engineError(
            "GFX.SIZE_MISMATCH",
            `\u7EB9\u7406\u6570\u636E ${data.byteLength} \u5B57\u8282\uFF0C\u4F46 ${desc.width}x${desc.height} \u7684 ${format} \u9700\u8981 ${expect}`,
            { label: desc.label ?? "", format }
          )
        );
      }
    }
    const hash = hashStateCreate();
    if (data !== void 0 && data !== null) hashStateUpdate(hash, asBytes(data));
    this.textures.set(h, {
      width: desc.width,
      height: desc.height,
      label: desc.label ?? "",
      format,
      bytesPerPixel: bpp,
      wrap: desc.wrap ?? TextureWrap.Clamp,
      hash
    });
    return ok(h);
  }
  updateTexture(handle, region, data) {
    const rec = this.textures.get(handle);
    if (rec === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7EB9\u7406\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728`));
    }
    if (region.x < 0 || region.y < 0 || region.x + region.width > rec.width || region.y + region.height > rec.height) {
      return err(
        engineError("GFX.REGION_OUT_OF_BOUNDS", `\u4E0A\u4F20\u533A\u57DF\u8D85\u51FA\u7EB9\u7406\uFF1A${JSON.stringify(region)} vs ${rec.width}x${rec.height}`)
      );
    }
    const expect = region.width * region.height * rec.bytesPerPixel;
    if (data.byteLength !== expect) {
      this.rejectedCalls.push(
        `updateTexture(\u6570\u636E ${data.byteLength} != ${region.width}x${region.height}x${rec.bytesPerPixel} ${rec.format})`
      );
      return err(
        engineError(
          "GFX.SIZE_MISMATCH",
          `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${expect} \u4E0D\u7B26\uFF08${rec.format}\uFF0C${region.width}x${region.height}\uFF09`,
          { label: rec.label, format: rec.format }
        )
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    hashStateUpdate(rec.hash, asBytes(data));
    return ok(void 0);
  }
  /**
   * 纹理的像素格式（句柄不存在 → `undefined`，与 `textureDigest` 同语气）。
   *
   * ★ 为什么必须有它：`textureDigest` 只能证明"字节到了"，证明不了
   *   "以什么格式到的"—— 同一份 8 字节/像素的数据，声明成 rgba16 还是
   *   rgba16f、或者干脆被当成 rgba8 上传，摘要都可能一样（前者一样，后者长度就不同）。
   *   判据要断言"上传的真的是 16 位"，就必须能把设备记录的格式读出来。
   */
  textureFormat(handle) {
    return this.textures.get(handle)?.format;
  }
  /**
   * 纹理的环绕方式（句柄不存在 → `undefined`，与 `textureFormat` 同语气）。
   *
   * ★ 为什么必须有它（T288）：地形平铺要求瓦片页是 `repeat`、主图集是 `clamp`。
   *   两者传错的表现都**不报错**：主图集开 repeat ⇒ 邻居帧被采进来；
   *   瓦片页开 clamp ⇒ 接缝被抻成脏边。而字节摘要、格式、帧表全都一样 ——
   *   没有这个访问器，"哪张页是什么 wrap"在 headless 里根本无法断言。
   */
  textureWrap(handle) {
    return this.textures.get(handle)?.wrap;
  }
  /**
   * 纹理的"上传字节流"摘要（16 hex），用于断言"解码出的 pixels == GPU 实际收到的字节"。
   * 句柄不存在 → `undefined`（不抛：这不是程序错误，是查询语气）。
   * 从未上传过任何字节 → 也返回 `undefined`：空流的摘要看起来像一个真摘要，
   * 让调用方误以为"上传过了"。
   */
  textureDigest(handle) {
    const rec = this.textures.get(handle);
    if (rec === void 0 || rec.hash.bytes === 0) return void 0;
    return hashStateHex(rec.hash);
  }
  /**
   * 已创建且未销毁的纹理句柄（按创建顺序）。
   *
   * ★ 判据需要它才能回答"渲染模块到底传了哪张图"：
   *   `stats.bytesUploaded` 只能说明"传了 65536 字节"，分不清"传对了"
   *   和"传了同样大小的另一张图"—— 而后者正是"假贴图"在生产环境里的样子。
   */
  get textureHandles() {
    return Array.from(this.textures.keys());
  }
  destroyTexture(handle) {
    if (!this.textures.delete(handle)) {
      this.rejectedCalls.push(`destroyTexture(\u5DF2\u5931\u6548 ${handle})`);
    }
  }
  // ---------------------------------------------------------------- shader / pipeline
  createShader(desc) {
    if (desc.vertex.trim() === "" || desc.fragment.trim() === "") {
      return err(engineError("GFX.SHADER_EMPTY", "\u7740\u8272\u5668\u6E90\u7801\u4E3A\u7A7A"));
    }
    if (!/(void\s+main|fn\s+main)/.test(desc.vertex + desc.fragment)) {
      return err(engineError("GFX.SHADER_COMPILE", "\u7740\u8272\u5668\u6CA1\u6709 main \u5165\u53E3", { label: desc.label ?? "" }));
    }
    const h = this.nextHandle++;
    this.shaders.set(h, { label: desc.label ?? "" });
    return ok(h);
  }
  destroyShader(handle) {
    this.shaders.delete(handle);
  }
  createPipeline(desc) {
    if (!this.shaders.has(desc.shader)) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7BA1\u7EBF\u5F15\u7528\u7684\u7740\u8272\u5668 ${desc.shader} \u4E0D\u5B58\u5728`));
    }
    const h = this.nextHandle++;
    this.pipelines.set(h, { shader: desc.shader, label: desc.label ?? "" });
    return ok(h);
  }
  destroyPipeline(handle) {
    this.pipelines.delete(handle);
  }
  createRenderTarget(desc) {
    if (!this.textures.has(desc.color)) {
      return err(engineError("GFX.INVALID_HANDLE", `\u6E32\u67D3\u76EE\u6807\u7684\u989C\u8272\u7EB9\u7406 ${desc.color} \u4E0D\u5B58\u5728`));
    }
    const h = this.nextHandle++;
    this.targets.set(h, { color: desc.color });
    return ok(h);
  }
  destroyRenderTarget(handle) {
    this.targets.delete(handle);
  }
  // ---------------------------------------------------------------- frame
  beginFrame(target) {
    if (this.current !== null) {
      this.rejectedCalls.push("beginFrame(\u4E0A\u4E00\u5E27\u6CA1\u6709 endFrame)");
    }
    const record = {
      frameIndex: this.frameIndex++,
      clears: [],
      draws: [],
      scissorSets: 0,
      viewportSets: 0
    };
    this.current = record;
    this._stats = {
      frameIndex: record.frameIndex,
      drawCalls: 0,
      verticesSubmitted: 0,
      textureBindings: 0,
      pipelineSwitches: 0,
      bytesUploaded: 0
    };
    return new NullCommandList(this, target);
  }
  endFrame() {
    if (this.current === null) {
      this.rejectedCalls.push("endFrame(\u6CA1\u6709 beginFrame)");
      return;
    }
    this.frames.push(this.current);
    if (this.frames.length > 120) this.frames.shift();
    this.current = null;
  }
  readPixels(target, rect) {
    if (!this.caps.readback) {
      return err(engineError("GFX.NO_READBACK", "\u8BE5\u8BBE\u5907\u4E0D\u652F\u6301\u8BFB\u56DE\u50CF\u7D20"));
    }
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    const out = new Uint8Array(w * h * 4);
    if (target !== null) {
      const t = this.targets.get(target);
      if (t === void 0) return err(engineError("GFX.INVALID_HANDLE", `\u6E32\u67D3\u76EE\u6807 ${target} \u4E0D\u5B58\u5728`));
      for (let i = 0; i < out.length; i += 4) {
        out[i] = 32;
        out[i + 1] = 64;
        out[i + 2] = 96;
        out[i + 3] = 255;
      }
    }
    return ok(out);
  }
  destroy() {
    this.buffers.clear();
    this.textures.clear();
    this.shaders.clear();
    this.pipelines.clear();
    this.targets.clear();
    this.current = null;
  }
  /** 内部：命令列表回调。 */
  _pushDraw(rec) {
    this.current?.draws.push(rec);
    this._stats = {
      ...this._stats,
      drawCalls: this._stats.drawCalls + 1,
      verticesSubmitted: this._stats.verticesSubmitted + rec.vertices,
      textureBindings: this._stats.textureBindings + rec.textures.length
    };
  }
  _pushClear(color, flags) {
    this.current?.clears.push({ color, flags });
  }
  _pushPipeline() {
    this._stats = { ...this._stats, pipelineSwitches: this._stats.pipelineSwitches + 1 };
  }
  _bumpScissor() {
    if (this.current) this.current.scissorSets++;
  }
  _bumpViewport() {
    if (this.current) this.current.viewportSets++;
  }
};
var NullCommandList = class {
  constructor(dev, target) {
    this.dev = dev;
    this.target = target;
    void this.target;
  }
  pipeline = 0;
  textures = /* @__PURE__ */ new Map();
  uniforms = /* @__PURE__ */ new Map();
  finished = false;
  setViewport(rect) {
    this.dev._bumpViewport();
  }
  setScissor(rect) {
    this.dev._bumpScissor();
  }
  clear(color, flags) {
    this.assertOpen("clear");
    this.dev._pushClear(color, flags);
  }
  setPipeline(pipeline) {
    this.assertOpen("setPipeline");
    this.pipeline = pipeline;
    this.dev._pushPipeline();
  }
  setUniform(name, value, _kind = "float") {
    this.assertOpen("setUniform");
    this.uniforms.set(name, value);
  }
  bindTexture(slot, texture) {
    this.assertOpen("bindTexture");
    this.textures.set(slot, texture);
  }
  draw(batch) {
    this.assertOpen("draw");
    this.dev._pushDraw({
      vertices: batch.vertexCount,
      indices: batch.indexCount,
      firstIndex: batch.firstIndex ?? 0,
      pipeline: this.pipeline,
      textures: Array.from(this.textures.values())
    });
  }
  finish() {
    this.finished = true;
  }
  assertOpen(what) {
    if (this.finished) {
      throw new Error(`\u547D\u4EE4\u5217\u8868\u5DF2 finish\uFF0C\u4ECD\u5728\u8C03\u7528 ${what}`);
    }
  }
};
var nullGfxBackend = {
  id: "null",
  priority: 0,
  probe(_options) {
    return true;
  },
  create(options) {
    const o = options ?? {};
    return ok(new NullGraphicsDevice(o.width ?? 1280, o.height ?? 720));
  }
};

// src/backends/audio-null/device.ts
var NullAudioDevice = class {
  caps = {
    backend: "null",
    maxVoices: 32,
    requiresGesture: true,
    spatial: true
  };
  nextHandle = 1;
  clips = /* @__PURE__ */ new Map();
  voices = /* @__PURE__ */ new Map();
  buses = /* @__PURE__ */ new Map([["master", { name: "master", volume: 1, muted: false }]]);
  clock = 0;
  resumed = false;
  resumeCalls = 0;
  playLog = [];
  /** 因为超过 maxVoices 被拒绝的播放次数（"声音被吞掉"必须可见）。 */
  voicesRejected = 0;
  async init() {
    return ok(void 0);
  }
  async resume() {
    this.resumeCalls++;
    if (!this.caps.requiresGesture) {
      this.resumed = true;
      return ok(void 0);
    }
    if (!this.resumed) {
      this.resumed = true;
      return err(
        engineError("AUDIO.NEEDS_GESTURE", "\u97F3\u9891\u9700\u8981\u7528\u6237\u624B\u52BF\u624D\u80FD\u89E3\u9501\uFF08\u7B2C\u4E00\u6B21 resume \u5FC5\u7136\u5931\u8D25\uFF0C\u8FD9\u662F\u5951\u7EA6\uFF09")
      );
    }
    return ok(void 0);
  }
  /** 判据用：模拟"用户点了"（跳过手势检查）。 */
  forceUnlock() {
    this.resumed = true;
    this.capsUnlockPatch();
  }
  capsUnlockPatch() {
    this.caps.requiresGesture = false;
  }
  async loadClip(name, data) {
    if (data.byteLength === 0) {
      return err(engineError("AUDIO.BAD_CLIP", "\u97F3\u9891\u6570\u636E\u4E3A\u7A7A\uFF1A" + name));
    }
    const durationMs = Math.max(50, Math.round(data.byteLength / 8e3 * 1e3));
    const h = this.nextHandle++;
    this.clips.set(h, { name, durationMs });
    return ok(h);
  }
  releaseClip(clip) {
    this.clips.delete(clip);
    for (const [h, v] of this.voices) if (v.clip === clip) this.voices.delete(h);
  }
  play(clip, opts = {}) {
    const c = this.clips.get(clip);
    if (c === void 0) return err(engineError("AUDIO.INVALID_CLIP", `clip ${clip} \u4E0D\u5B58\u5728`));
    if (this.voices.size >= this.caps.maxVoices) {
      this.voicesRejected++;
      return err(
        engineError("AUDIO.NO_FREE_VOICE", `\u5DF2\u8FBE ${this.caps.maxVoices} \u4E2A\u58F0\u90E8\u4E0A\u9650`, { clip: c.name })
      );
    }
    const busName = opts.bus ?? "master";
    const bus = this.buses.get(busName) ?? { name: busName, volume: 1, muted: false };
    this.buses.set(busName, bus);
    if (bus.muted) {
      this.playLog.push({
        clip,
        name: c.name,
        bus: busName,
        volume: 0,
        loop: opts.loop === true,
        atMs: this.clock,
        position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
      });
      return err(engineError("AUDIO.BUS_MUTED", `\u603B\u7EBF ${busName} \u5DF2\u9759\u97F3`, { clip: c.name }));
    }
    const rate = opts.rate ?? 1;
    const volume = (opts.volume ?? 1) * bus.volume;
    const loop2 = opts.loop === true;
    const h = this.nextHandle++;
    this.voices.set(h, {
      handle: h,
      clip,
      name: c.name,
      bus: busName,
      volume,
      rate,
      loop: loop2,
      endsAtMs: loop2 ? Number.POSITIVE_INFINITY : this.clock + Math.round(c.durationMs / rate),
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    });
    this.playLog.push({
      clip,
      name: c.name,
      bus: busName,
      volume,
      loop: loop2,
      atMs: this.clock,
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    });
    return ok(h);
  }
  stop(voice) {
    this.voices.delete(voice);
  }
  setVoice(voice, patch) {
    const v = this.voices.get(voice);
    if (v === void 0) return;
    if (patch.volume !== void 0) v.volume = patch.volume;
    if (patch.rate !== void 0) v.rate = patch.rate;
    if (patch.loop !== void 0) v.loop = patch.loop;
  }
  getVoice(voice) {
    const v = this.voices.get(voice);
    if (v === void 0) return void 0;
    return {
      handle: v.handle,
      playing: true,
      clip: v.clip,
      bus: v.bus,
      volume: v.volume,
      rate: v.rate,
      loop: v.loop
    };
  }
  bus(name) {
    let b = this.buses.get(name);
    if (b === void 0) {
      b = { name, volume: 1, muted: false };
      this.buses.set(name, b);
    }
    return b;
  }
  setListener(_pos) {
  }
  get timeMs() {
    return this.clock;
  }
  get activeVoices() {
    return this.voices.size;
  }
  /** 判据用：推进音频时钟并结束到期 voice。 */
  advance(ms) {
    this.clock += ms;
    for (const [h, v] of [...this.voices]) {
      if (!v.loop && this.clock >= v.endsAtMs) this.voices.delete(h);
    }
  }
  destroy() {
    this.voices.clear();
    this.clips.clear();
  }
};
var nullAudioBackend = {
  id: "null",
  priority: 0,
  probe(_options) {
    return true;
  },
  create(_options) {
    return ok(new NullAudioDevice());
  }
};

// src/backends/input-null/device.ts
var NullInputDevice = class {
  caps = {
    backend: "null",
    pointer: true,
    touch: false,
    gamepad: false,
    textInput: true
  };
  down = /* @__PURE__ */ new Set();
  pressed = /* @__PURE__ */ new Set();
  released = /* @__PURE__ */ new Set();
  pointerDown = false;
  pointerPressed = false;
  pointerReleased = false;
  px = 0;
  py = 0;
  wheelX = 0;
  wheelY = 0;
  text = "";
  subs = /* @__PURE__ */ new Set();
  poll() {
    const snap = {
      keysDown: new Set(this.down),
      keysPressed: new Set(this.pressed),
      keysReleased: new Set(this.released),
      pointer: {
        x: this.px,
        y: this.py,
        down: this.pointerDown,
        pressed: this.pointerPressed,
        released: this.pointerReleased,
        button: 0
      },
      wheel: { dx: this.wheelX, dy: this.wheelY },
      text: this.text
    };
    this.pressed.clear();
    this.released.clear();
    this.pointerPressed = false;
    this.pointerReleased = false;
    this.wheelX = 0;
    this.wheelY = 0;
    this.text = "";
    return snap;
  }
  subscribe(fn) {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }
  setFocusTarget(_target) {
  }
  reset() {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.pointerDown = false;
    this.pointerPressed = false;
    this.pointerReleased = false;
  }
  destroy() {
    this.subs.clear();
    this.reset();
  }
  // ---- 编程接口（判据/编辑器用）
  keyDown(code) {
    if (!this.down.has(code)) {
      this.down.add(code);
      this.pressed.add(code);
    }
    this.emit({ kind: "key", code, down: true });
  }
  keyUp(code) {
    if (this.down.delete(code)) {
      this.released.add(code);
    }
    this.emit({ kind: "key", code, down: false });
  }
  movePointer(x, y) {
    this.px = x;
    this.py = y;
    this.emit({ kind: "pointer", x, y });
  }
  pointerDownAt(x, y) {
    this.px = x;
    this.py = y;
    this.pointerDown = true;
    this.pointerPressed = true;
    this.emit({ kind: "pointer", x, y, down: true });
  }
  pointerUpAt(x, y) {
    this.px = x;
    this.py = y;
    this.pointerDown = false;
    this.pointerReleased = true;
    this.emit({ kind: "pointer", x, y, down: false });
  }
  wheel(dx, dy) {
    this.wheelX += dx;
    this.wheelY += dy;
    this.emit({ kind: "wheel", x: dx, y: dy });
  }
  typeText(s) {
    this.text += s;
    this.emit({ kind: "text", value: s });
  }
  emit(e) {
    for (const f of this.subs) f(e);
  }
};
var nullInputBackend = {
  id: "null",
  priority: 0,
  probe(_options) {
    return true;
  },
  create(_options) {
    return ok(new NullInputDevice());
  }
};

// src/backends/fs-memory/fs.ts
function norm(path) {
  let p = path.replace(/\\/g, "/");
  if (p.startsWith("mem:")) p = p.slice(4);
  if (!p.startsWith("/")) p = "/" + p;
  const parts = [];
  for (const seg of p.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      return err(
        engineError("FS.PATH_ESCAPE", `\u8DEF\u5F84\u91CC\u51FA\u73B0 ".."\uFF1A${path}\uFF08\u62D2\u7EDD\uFF0C\u4E0D\u505A'\u806A\u660E'\u7684\u89E3\u6790\uFF09`)
      );
    }
    parts.push(seg);
  }
  return ok("/" + parts.join("/"));
}
var MemoryFileSystem = class {
  /** 前缀，用于同一进程里隔离多个内存盘（`mem:/a` vs `mem:/b`）。 */
  constructor(prefix = "") {
    this.prefix = prefix;
  }
  scheme = "mem";
  /** 内存盘/真实盘都能列目录。 */
  canList = true;
  files = /* @__PURE__ */ new Map();
  dirs = /* @__PURE__ */ new Set(["/"]);
  nowCounter = 1;
  /** 写入次数：判据可以断言"没有多余的落盘"。 */
  writeCount = 0;
  key(p) {
    const n = norm(this.prefix + p);
    return n;
  }
  async readText(path) {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `\u4E0D\u662F\u5408\u6CD5 UTF-8\uFF1A${path}\uFF08${e instanceof Error ? e.message : ""}\uFF09`));
    }
  }
  async readBinary(path) {
    const k = this.key(path);
    if (!k.ok) return k;
    const f = this.files.get(k.value);
    if (f === void 0) {
      if (this.dirs.has(k.value)) {
        return err(engineError("FS.IS_DIR", `${k.value} \u662F\u76EE\u5F55\uFF08\u8FD9\u4E2A\u63A5\u53E3\u53EA\u8BFB\u6587\u4EF6\uFF09`));
      }
      return err(
        engineError("FS.NOT_FOUND", `\u6587\u4EF6\u4E0D\u5B58\u5728\uFF1A${k.value}`, {
          known: Array.from(this.files.keys()).sort().slice(0, 20)
        })
      );
    }
    return ok(f.data.slice());
  }
  async writeText(path, text) {
    return this.writeBinary(path, new TextEncoder().encode(text));
  }
  async writeBinary(path, data) {
    const k = this.key(path);
    if (!k.ok) return k;
    this.files.set(k.value, { data: data.slice(), mtimeMs: this.nowCounter++ });
    this.writeCount++;
    const segs = k.value.split("/").filter(Boolean);
    for (let i = 1; i <= segs.length - 1; i++) {
      this.dirs.add("/" + segs.slice(0, i).join("/"));
    }
    return ok(void 0);
  }
  async remove(path) {
    const k = this.key(path);
    if (!k.ok) return k;
    if (!this.files.delete(k.value)) {
      if (this.dirs.has(k.value)) {
        return err(engineError("FS.IS_DIR", `${k.value} \u662F\u76EE\u5F55\uFF08\u8FD9\u4E2A\u63A5\u53E3\u53EA\u5220\u6587\u4EF6\uFF09`));
      }
      return err(engineError("FS.NOT_FOUND", `\u8981\u5220\u9664\u7684\u8DEF\u5F84\u4E0D\u5B58\u5728\uFF1A${k.value}`));
    }
    return ok(void 0);
  }
  async exists(path) {
    const k = this.key(path);
    if (!k.ok) return false;
    return this.files.has(k.value) || this.dirs.has(k.value);
  }
  async list(dir) {
    const k = this.key(dir);
    if (!k.ok) return k;
    if (this.files.has(k.value)) {
      return err(engineError("FS.NOT_A_DIR", `${k.value} \u662F\u6587\u4EF6\uFF0C\u4E0D\u662F\u76EE\u5F55`));
    }
    if (!this.dirs.has(k.value)) {
      return err(engineError("FS.NOT_FOUND", `\u76EE\u5F55\u4E0D\u5B58\u5728\uFF1A${k.value}`));
    }
    const base = k.value === "/" ? "/" : k.value + "/";
    const out = [];
    for (const [p, f] of this.files) {
      if (!p.startsWith(base)) continue;
      const rest = p.slice(base.length);
      if (rest === "" || rest.includes("/")) continue;
      out.push({ name: rest, path: p, isDirectory: false, size: f.data.byteLength });
    }
    for (const d of this.dirs) {
      if (d === k.value || !d.startsWith(base)) continue;
      const rest = d.slice(base.length);
      if (rest === "" || rest.includes("/")) continue;
      out.push({ name: rest, path: d, isDirectory: true, size: 0 });
    }
    out.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    return ok(out);
  }
  async stat(path) {
    const k = this.key(path);
    if (!k.ok) return k;
    const f = this.files.get(k.value);
    if (f !== void 0) {
      return ok({ size: f.data.byteLength, mtimeMs: f.mtimeMs, isDirectory: false });
    }
    if (this.dirs.has(k.value)) return ok({ size: 0, mtimeMs: 0, isDirectory: true });
    return err(engineError("FS.NOT_FOUND", `\u8DEF\u5F84\u4E0D\u5B58\u5728\uFF1A${k.value}`));
  }
  async ensureDir(dir) {
    const k = this.key(dir);
    if (!k.ok) return k;
    this.dirs.add(k.value);
    return ok(void 0);
  }
  // ---- 判据/编辑器便利（不在 IFileSystem 接口里，避免所有实现都要有）
  snapshotFiles() {
    const m = /* @__PURE__ */ new Map();
    for (const [k, v] of this.files) m.set(k, v.data.slice());
    return m;
  }
  reset() {
    this.files.clear();
    this.dirs.clear();
    this.dirs.add("/");
    this.writeCount = 0;
  }
};
var memFsBackend = {
  id: "mem",
  scheme: "mem",
  priority: 50,
  probe(_options) {
    return true;
  },
  create(options) {
    const o = options ?? {};
    return ok(new MemoryFileSystem(o.prefix ?? ""));
  }
};

// src/platform/script/runtime.ts
var ScriptErrorCode = {
  NotSupported: "SCRIPT.NOT_SUPPORTED",
  Disposed: "SCRIPT.DISPOSED",
  NoFunction: "SCRIPT.NO_FUNCTION",
  CallFailed: "SCRIPT.CALL_FAILED",
  Timeout: "SCRIPT.TIMEOUT",
  LoadFailed: "SCRIPT.LOAD_FAILED",
  BadValue: "SCRIPT.BAD_VALUE"
};

// src/backends/script-null/runtime.ts
var NullScriptRuntime = class {
  id = "null";
  caps = {
    language: "none",
    version: null,
    interruptible: false,
    hostCalls: false,
    executes: false
  };
  modules = /* @__PURE__ */ new Map();
  hostFns = /* @__PURE__ */ new Map();
  loaded = [];
  calls = 0;
  errors = 0;
  disposed = false;
  async loadModule(name, source) {
    if (this.disposed) return this.disposedErr();
    this.modules.set(name, source);
    this.loaded.push({ name, bytes: source.length });
    return ok(void 0);
  }
  async unloadModule(name) {
    if (this.disposed) return this.disposedErr();
    this.modules.delete(name);
    return ok(void 0);
  }
  hasModule(name) {
    return this.modules.has(name);
  }
  listModules() {
    return Array.from(this.modules.keys()).sort();
  }
  async call(fn, args = [], _opts = {}) {
    if (this.disposed) return this.disposedErr();
    this.calls++;
    this.errors++;
    return err(
      engineError(
        ScriptErrorCode.NotSupported,
        `null \u811A\u672C\u540E\u7AEF\u4E0D\u80FD\u6267\u884C ${fn}\uFF08\u8FD9\u4E2A\u5E73\u53F0\u6CA1\u6709\u811A\u672C\u80FD\u529B\uFF1Acaps.executes=false\uFF09`,
        { fn }
      )
    );
  }
  expose(name, fn) {
    if (this.disposed) return this.disposedErr();
    this.hostFns.set(name, fn);
    return ok(void 0);
  }
  exposed() {
    return Array.from(this.hostFns.keys()).sort();
  }
  async ready() {
    return this.disposed ? this.disposedErr() : ok(void 0);
  }
  stats() {
    return {
      modules: this.modules.size,
      calls: this.calls,
      errors: this.errors,
      timeouts: 0
    };
  }
  /** 诊断：加载历史（含热重载的重复项）。 */
  history() {
    return this.loaded.slice();
  }
  dispose() {
    this.disposed = true;
    this.modules.clear();
    this.hostFns.clear();
  }
  disposedErr() {
    return err(engineError(ScriptErrorCode.Disposed, "\u811A\u672C\u8FD0\u884C\u65F6\u5DF2\u91CA\u653E"));
  }
};
var nullScriptBackend = {
  id: "null",
  probe: () => true,
  create: () => ok(new NullScriptRuntime())
};

// src/backends/index.ts
function registerNullBackends(reg, opts = {}) {
  reg.registerGfx(nullGfxBackend, 0);
  reg.registerAudio(nullAudioBackend, 0);
  reg.registerInput(nullInputBackend, 0);
  reg.registerFs(
    {
      id: memFsBackend.id,
      scheme: memFsBackend.scheme,
      probe: memFsBackend.probe,
      create: (o) => memFsBackend.create({ prefix: opts.fsPrefix ?? "", ...o })
    },
    0
  );
  reg.registerScript(nullScriptBackend, 0);
}

// src/backends/gfx-webgl2/gl2.ts
var GL = {
  // buffer
  ARRAY_BUFFER: 34962,
  ELEMENT_ARRAY_BUFFER: 34963,
  STATIC_DRAW: 35044,
  DYNAMIC_DRAW: 35048,
  // shader
  VERTEX_SHADER: 35633,
  FRAGMENT_SHADER: 35632,
  COMPILE_STATUS: 35713,
  LINK_STATUS: 35714,
  // texture
  TEXTURE_2D: 3553,
  TEXTURE0: 33984,
  RGBA: 6408,
  RGBA8: 32856,
  RGB: 6407,
  R8: 33321,
  UNSIGNED_BYTE: 5121,
  FLOAT: 5126,
  UNSIGNED_SHORT: 5123,
  UNSIGNED_INT: 5125,
  TEXTURE_MIN_FILTER: 10241,
  TEXTURE_MAG_FILTER: 10240,
  TEXTURE_WRAP_S: 10242,
  TEXTURE_WRAP_T: 10243,
  NEAREST: 9728,
  LINEAR: 9729,
  CLAMP_TO_EDGE: 33071,
  REPEAT: 10497,
  UNPACK_ALIGNMENT: 3317,
  // state
  BLEND: 3042,
  DEPTH_TEST: 2929,
  SCISSOR_TEST: 3089,
  SRC_ALPHA: 770,
  ONE_MINUS_SRC_ALPHA: 771,
  ONE: 1,
  COLOR_BUFFER_BIT: 16384,
  DEPTH_BUFFER_BIT: 256,
  TRIANGLES: 4,
  TRIANGLE_STRIP: 5,
  // limits
  MAX_TEXTURE_SIZE: 3379,
  MAX_TEXTURE_IMAGE_UNITS: 34930,
  MAX_VERTEX_ATTRIBS: 34921,
  MAX_ELEMENTS_VERTICES: 33e3,
  // framebuffer
  FRAMEBUFFER: 36160,
  COLOR_ATTACHMENT0: 36064,
  FRAMEBUFFER_COMPLETE: 36053
};
function isGL2Like(x) {
  if (x === null || typeof x !== "object") return false;
  const o = x;
  return typeof o["createBuffer"] === "function" && typeof o["createShader"] === "function" && typeof o["drawElements"] === "function" && typeof o["getParameter"] === "function";
}

// src/backends/gfx-webgl2/device.ts
var SPRITE_STRIDE = 8 * 4;
var GL2Device = class {
  caps;
  gl;
  next = 1;
  recs = /* @__PURE__ */ new Map();
  frameIndex = 0;
  recording = null;
  _size;
  _stats = {
    frameIndex: 0,
    drawCalls: 0,
    verticesSubmitted: 0,
    textureBindings: 0,
    pipelineSwitches: 0,
    bytesUploaded: 0
  };
  // 状态缓存：只在**真的变化**时才调 GL
  curProgram = null;
  curTextureSlot = -1;
  curTexture = null;
  constructor(gl) {
    if (!isGL2Like(gl)) {
      throw new Error("GL2Device \u9700\u8981\u4E00\u4E2A WebGL2 \u4E0A\u4E0B\u6587\uFF08webgl2\uFF09\uFF0C\u4F20\u8FDB\u6765\u7684\u5BF9\u8C61\u4E0D\u50CF WebGL2 context");
    }
    this.gl = gl;
    const maxTex = gl.getParameter(GL.MAX_TEXTURE_SIZE) || 2048;
    const maxUnits = gl.getParameter(GL.MAX_TEXTURE_IMAGE_UNITS) || 8;
    const maxVerts = gl.getParameter(GL.MAX_ELEMENTS_VERTICES) || 65536;
    this.caps = {
      backend: "webgl2",
      version: "3.0",
      maxTextureSize: maxTex,
      maxTextureUnits: maxUnits,
      maxVerticesPerDraw: Math.max(1024, maxVerts),
      instancing: true,
      floatTextures: true,
      readback: true,
      srgbTextures: true
    };
    this._size = { width: gl.canvas.width, height: gl.canvas.height };
    gl.enable(GL.BLEND);
    gl.blendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA);
    gl.disable(GL.DEPTH_TEST);
    gl.pixelStorei(GL.UNPACK_ALIGNMENT, 1);
  }
  get stats() {
    return this._stats;
  }
  get size() {
    return this._size;
  }
  resize(width, height) {
    this._size = { width, height };
    this.gl.canvas.width = width;
    this.gl.canvas.height = height;
  }
  // ---------------------------------------------------------------- buffer
  createBuffer(desc) {
    if (!(desc.byteLength > 0)) {
      return err(engineError("GFX.BAD_BUFFER", `\u7F13\u51B2\u533A\u5927\u5C0F\u5FC5\u987B > 0\uFF0C\u6536\u5230 ${desc.byteLength}`));
    }
    const gl = this.gl;
    const buf = gl.createBuffer();
    if (buf === null || buf === void 0) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createBuffer \u8FD4\u56DE null\uFF08\u663E\u5B58\u4E0D\u8DB3\uFF09"));
    }
    const target = desc.usage === BufferUsage.Index ? GL.ELEMENT_ARRAY_BUFFER : GL.ARRAY_BUFFER;
    gl.bindBuffer(target, buf);
    gl.bufferData(target, desc.byteLength, desc.dynamic ? GL.DYNAMIC_DRAW : GL.STATIC_DRAW);
    gl.bindBuffer(target, null);
    return ok(this.track("buffer", buf, {
      byteLength: desc.byteLength,
      dynamic: desc.dynamic,
      target,
      label: desc.label ?? ""
    }));
  }
  updateBuffer(handle, data, byteOffset = 0) {
    const rec = this.get(handle, "buffer");
    if (rec === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7F13\u51B2\u533A\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728\uFF08\u53EF\u80FD\u5DF2\u9500\u6BC1\uFF09`));
    }
    const cap = rec.meta["byteLength"];
    const end = byteOffset + data.byteLength;
    if (byteOffset < 0 || end > cap) {
      return err(
        engineError("GFX.BUFFER_OVERFLOW", `\u5199\u5165\u8D8A\u754C\uFF1Aoffset=${byteOffset} len=${data.byteLength} \u5BB9\u91CF=${cap}`)
      );
    }
    const target = rec.meta["target"];
    this.gl.bindBuffer(target, rec.gl);
    this.gl.bufferSubData(target, byteOffset, data);
    this.gl.bindBuffer(target, null);
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
  }
  destroyBuffer(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    this.gl.deleteBuffer(rec.gl);
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- texture
  createTexture(desc, data) {
    if (!(desc.width > 0) || !(desc.height > 0)) {
      return err(engineError("GFX.BAD_TEXTURE", `\u7EB9\u7406\u5C3A\u5BF8\u975E\u6CD5\uFF1A${desc.width}x${desc.height}`));
    }
    if (desc.width > this.caps.maxTextureSize || desc.height > this.caps.maxTextureSize) {
      return err(
        engineError(
          "GFX.TEXTURE_TOO_LARGE",
          `\u7EB9\u7406 ${desc.width}x${desc.height} \u8D85\u8FC7\u4E0A\u9650 ${this.caps.maxTextureSize}`,
          { label: desc.label ?? "" }
        )
      );
    }
    const format = desc.format ?? PixelFormat.RGBA8;
    const fmt = glFormat(format);
    if (data !== void 0 && data !== null) {
      const need2 = desc.width * desc.height * fmt.bytesPerPixel;
      if (data.byteLength !== need2) {
        return err(
          engineError(
            "GFX.SIZE_MISMATCH",
            `\u7EB9\u7406\u6570\u636E ${data.byteLength} \u5B57\u8282\uFF0C\u4F46 ${desc.width}x${desc.height} \u7684 ${format} \u9700\u8981 ${need2}`,
            { label: desc.label ?? "", format }
          )
        );
      }
    }
    const gl = this.gl;
    const tex = gl.createTexture();
    if (tex === null || tex === void 0) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createTexture \u8FD4\u56DE null\uFF08\u663E\u5B58\u4E0D\u8DB3\uFF09"));
    }
    gl.bindTexture(GL.TEXTURE_2D, tex);
    gl.texImage2D(
      GL.TEXTURE_2D,
      0,
      fmt.internal,
      desc.width,
      desc.height,
      0,
      fmt.format,
      fmt.type,
      data ?? null
    );
    const filter = desc.filter === TextureFilter.Linear ? GL.LINEAR : GL.NEAREST;
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, filter);
    const wrap = desc.wrap === TextureWrap.Repeat ? GL.REPEAT : GL.CLAMP_TO_EDGE;
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, wrap);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, wrap);
    if (desc.mipmaps === true) gl.generateMipmap(GL.TEXTURE_2D);
    gl.bindTexture(GL.TEXTURE_2D, null);
    return ok(
      this.track("texture", tex, {
        width: desc.width,
        height: desc.height,
        isTarget: desc.renderTarget === true,
        // 记下格式：updateTexture 必须按**同一格式**的字节数校验，
        // 否则"往 RGBA16 纹理里写 4 字节/像素"会以小图片段的形式静默成功。
        format,
        label: desc.label ?? ""
      })
    );
  }
  updateTexture(handle, region, data) {
    const rec = this.get(handle, "texture");
    if (rec === void 0) return err(engineError("GFX.INVALID_HANDLE", `\u7EB9\u7406\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728`));
    const w = rec.meta["width"];
    const h = rec.meta["height"];
    if (region.x < 0 || region.y < 0 || region.x + region.width > w || region.y + region.height > h) {
      return err(
        engineError("GFX.REGION_OUT_OF_BOUNDS", `\u4E0A\u4F20\u533A\u57DF\u8D85\u51FA\u7EB9\u7406\uFF1A${JSON.stringify(region)} vs ${w}x${h}`)
      );
    }
    const format = rec.meta["format"];
    const fmt = glFormat(format);
    const need2 = region.width * region.height * fmt.bytesPerPixel;
    if (data.byteLength !== need2) {
      return err(
        engineError(
          "GFX.SIZE_MISMATCH",
          `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${need2} \u4E0D\u7B26\uFF08${format}\uFF0C${region.width}x${region.height}\uFF09`
        )
      );
    }
    const gl = this.gl;
    gl.bindTexture(GL.TEXTURE_2D, rec.gl);
    gl.texSubImage2D(
      GL.TEXTURE_2D,
      0,
      region.x,
      region.y,
      region.width,
      region.height,
      fmt.format,
      fmt.type,
      data
    );
    gl.bindTexture(GL.TEXTURE_2D, null);
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
  }
  destroyTexture(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    this.gl.deleteTexture(rec.gl);
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- shader / pipeline
  createShader(desc) {
    if (desc.vertex.trim() === "" || desc.fragment.trim() === "") {
      return err(engineError("GFX.SHADER_EMPTY", "\u7740\u8272\u5668\u6E90\u7801\u4E3A\u7A7A"));
    }
    const gl = this.gl;
    const vs = gl.createShader(GL.VERTEX_SHADER);
    const fs = gl.createShader(GL.FRAGMENT_SHADER);
    gl.shaderSource(vs, desc.vertex);
    gl.compileShader(vs);
    if (!gl.getShaderParameter(vs, GL.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(vs) ?? "";
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return err(engineError("GFX.SHADER_COMPILE", `\u9876\u70B9\u7740\u8272\u5668\u7F16\u8BD1\u5931\u8D25\uFF1A${log}`, { stage: "vertex", log }));
    }
    gl.shaderSource(fs, desc.fragment);
    gl.compileShader(fs);
    if (!gl.getShaderParameter(fs, GL.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(fs) ?? "";
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return err(engineError("GFX.SHADER_COMPILE", `\u7247\u5143\u7740\u8272\u5668\u7F16\u8BD1\u5931\u8D25\uFF1A${log}`, { stage: "fragment", log }));
    }
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (!gl.getProgramParameter(prog, GL.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(prog) ?? "";
      gl.deleteProgram(prog);
      return err(engineError("GFX.SHADER_LINK", `\u7A0B\u5E8F\u94FE\u63A5\u5931\u8D25\uFF1A${log}`, { log }));
    }
    return ok(this.track("shader", prog, { label: desc.label ?? "" }));
  }
  destroyShader(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    if (this.curProgram === rec.gl) this.curProgram = null;
    this.gl.deleteProgram(rec.gl);
    this.recs.delete(handle);
  }
  createPipeline(desc) {
    const sh = this.get(desc.shader, "shader");
    if (sh === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7BA1\u7EBF\u5F15\u7528\u7684\u7740\u8272\u5668 ${desc.shader} \u4E0D\u5B58\u5728`));
    }
    return ok(
      this.track("pipeline", sh.gl, {
        blend: desc.blend ?? BlendMode.Alpha,
        topology: desc.topology ?? Topology.Triangles,
        label: desc.label ?? ""
      })
    );
  }
  destroyPipeline(handle) {
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- target
  createRenderTarget(desc) {
    const tex = this.get(desc.color, "texture");
    if (tex === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u6E32\u67D3\u76EE\u6807\u7684\u989C\u8272\u7EB9\u7406 ${desc.color} \u4E0D\u5B58\u5728`));
    }
    const fb = this.gl.createFramebuffer();
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, fb);
    this.gl.framebufferTexture2D(GL.FRAMEBUFFER, GL.COLOR_ATTACHMENT0, GL.TEXTURE_2D, tex.gl, 0);
    const status = this.gl.checkFramebufferStatus(GL.FRAMEBUFFER);
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    if (status !== GL.FRAMEBUFFER_COMPLETE) {
      this.gl.deleteFramebuffer(fb);
      return err(engineError("GFX.FRAMEBUFFER_INCOMPLETE", `\u5E27\u7F13\u51B2\u4E0D\u5B8C\u6574\uFF08status=${status}\uFF09`));
    }
    return ok(this.track("target", fb, { label: desc.label ?? "" }));
  }
  destroyRenderTarget(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    this.gl.deleteFramebuffer(rec.gl);
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- frame
  beginFrame(target) {
    if (this.recording !== null) {
      this.recording.forceFinish();
      this.recording = null;
    }
    const gl = this.gl;
    if (target === null) {
      gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    } else {
      const rec = this.get(target, "target");
      gl.bindFramebuffer(GL.FRAMEBUFFER, rec?.gl ?? null);
    }
    this.frameIndex++;
    this._stats = {
      frameIndex: this.frameIndex,
      drawCalls: 0,
      verticesSubmitted: 0,
      textureBindings: 0,
      pipelineSwitches: 0,
      bytesUploaded: 0
    };
    this.curProgram = null;
    this.curTextureSlot = -1;
    this.curTexture = null;
    const cmd = new GL2CommandList(this, gl);
    this.recording = cmd;
    return cmd;
  }
  endFrame() {
    this.recording?.forceFinish();
    this.recording = null;
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, null);
  }
  readPixels(target, rect) {
    if (!this.caps.readback) return err(engineError("GFX.NO_READBACK", "\u8BE5\u8BBE\u5907\u4E0D\u652F\u6301\u8BFB\u56DE\u50CF\u7D20"));
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    const out = new Uint8Array(w * h * 4);
    const gl = this.gl;
    if (target !== null) {
      const rec = this.get(target, "target");
      gl.bindFramebuffer(GL.FRAMEBUFFER, rec?.gl ?? null);
    }
    gl.readPixels(Math.floor(rect.x), Math.floor(rect.y), w, h, GL.RGBA, GL.UNSIGNED_BYTE, out);
    if (target !== null) gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    return ok(out);
  }
  destroy() {
    const gl = this.gl;
    for (const [, rec] of this.recs) {
      switch (rec.kind) {
        case "buffer":
          gl.deleteBuffer(rec.gl);
          break;
        case "texture":
          gl.deleteTexture(rec.gl);
          break;
        case "shader":
          gl.deleteProgram(rec.gl);
          break;
        case "target":
          gl.deleteFramebuffer(rec.gl);
          break;
        default:
          break;
      }
    }
    this.recs.clear();
    this.recording = null;
  }
  // ---------------------------------------------------------------- 内部
  track(kind, glObj, meta) {
    const h = this.next++;
    this.recs.set(h, { kind, gl: glObj, meta });
    return h;
  }
  get(h, kind) {
    const rec = this.recs.get(h);
    return rec !== void 0 && rec.kind === kind ? rec : void 0;
  }
  // ---- 命令列表回调（保持 internal，但需要暴露给同文件的类）
  _useProgram(program) {
    if (this.curProgram === program) return false;
    this.gl.useProgram(program);
    this.curProgram = program;
    this._stats = { ...this._stats, pipelineSwitches: this._stats.pipelineSwitches + 1 };
    return true;
  }
  _bindTexture(slot, tex) {
    if (this.curTextureSlot === slot && this.curTexture === tex) return;
    this.gl.activeTexture(GL.TEXTURE0 + slot);
    this.gl.bindTexture(GL.TEXTURE_2D, tex);
    this.curTextureSlot = slot;
    this.curTexture = tex;
    this._stats = { ...this._stats, textureBindings: this._stats.textureBindings + 1 };
  }
  _countDraw(vertices) {
    this._stats = {
      ...this._stats,
      drawCalls: this._stats.drawCalls + 1,
      verticesSubmitted: this._stats.verticesSubmitted + vertices
    };
  }
  _bufferRec(h) {
    return this.recs.get(h);
  }
  _textureRec(h) {
    const rec = this.recs.get(h);
    return rec !== void 0 && rec.kind === "texture" ? rec : void 0;
  }
  _pipelineRec(h) {
    return this.recs.get(h);
  }
};
var GL2CommandList = class {
  constructor(dev, gl) {
    this.dev = dev;
    this.gl = gl;
    this.gl.viewport(0, 0, this.gl.canvas.width, this.gl.canvas.height);
  }
  pipeline = 0;
  uniforms = /* @__PURE__ */ new Map();
  textureSlots = /* @__PURE__ */ new Map();
  /** 本帧已落到 GL 上的混合方式（`null` = 还没设过）。避免同一帧重复 blendFunc。 */
  blendMode = null;
  finished = false;
  setViewport(rect) {
    this.gl.viewport(rect.x | 0, rect.y | 0, rect.width | 0, rect.height | 0);
  }
  setScissor(rect) {
    if (rect === null) {
      this.gl.disable(GL.SCISSOR_TEST);
      return;
    }
    this.gl.enable(GL.SCISSOR_TEST);
    this.gl.scissor(rect.x | 0, rect.y | 0, rect.width | 0, rect.height | 0);
  }
  clear(color, flags) {
    this.assertOpen("clear");
    this.gl.clearColor(color.r, color.g, color.b, color.a);
    this.gl.clear(flags);
  }
  setPipeline(pipeline) {
    this.assertOpen("setPipeline");
    this.pipeline = pipeline;
    const rec = this.dev._pipelineRec(pipeline);
    if (rec === void 0) return;
    const changed = this.dev._useProgram(rec.gl);
    this.applyBlend(rec.meta.blend);
    if (!changed) return;
    for (const [name, u] of this.uniforms) this.applyUniform(rec.gl, name, u.value, u.kind);
  }
  setUniform(name, value, kind = "float") {
    this.assertOpen("setUniform");
    this.uniforms.set(name, { value, kind });
    const rec = this.dev._pipelineRec(this.pipeline);
    if (rec !== void 0) this.applyUniform(rec.gl, name, value, kind);
  }
  bindTexture(slot, texture) {
    this.assertOpen("bindTexture");
    this.textureSlots.set(slot, texture);
    const rec = this.dev._textureRec(texture);
    if (rec !== void 0) this.dev._bindTexture(slot, rec.gl);
  }
  draw(batch) {
    this.assertOpen("draw");
    const pipe = this.dev._pipelineRec(this.pipeline);
    if (pipe === void 0) {
      throw new Error("draw \u4E4B\u524D\u6CA1\u6709 setPipeline\uFF08\u6216\u7BA1\u7EBF\u53E5\u67C4\u5DF2\u5931\u6548\uFF09");
    }
    const vrec = this.dev._bufferRec(batch.vertices);
    if (vrec === void 0) throw new Error(`draw \u7684\u9876\u70B9\u7F13\u51B2\u53E5\u67C4 ${batch.vertices} \u4E0D\u5B58\u5728`);
    this.gl.bindBuffer(GL.ARRAY_BUFFER, vrec.gl);
    this.gl.enableVertexAttribArray(0);
    this.gl.vertexAttribPointer(0, 2, GL.FLOAT, false, SPRITE_STRIDE, 0);
    this.gl.enableVertexAttribArray(1);
    this.gl.vertexAttribPointer(1, 2, GL.FLOAT, false, SPRITE_STRIDE, 8);
    this.gl.enableVertexAttribArray(2);
    this.gl.vertexAttribPointer(2, 4, GL.FLOAT, false, SPRITE_STRIDE, 16);
    const firstIndex = batch.firstIndex ?? 0;
    const mode = (pipe.meta.topology ?? Topology.Triangles) === Topology.TriangleStrip ? GL.TRIANGLE_STRIP : GL.TRIANGLES;
    if (batch.indices !== null) {
      const irec = this.dev._bufferRec(batch.indices);
      if (irec === void 0) throw new Error(`draw \u7684\u7D22\u5F15\u7F13\u51B2\u53E5\u67C4 ${batch.indices} \u4E0D\u5B58\u5728`);
      this.gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, irec.gl);
      this.gl.drawElements(mode, batch.indexCount, GL.UNSIGNED_SHORT, firstIndex * 2);
    } else {
      this.gl.drawArrays(mode, firstIndex, batch.vertexCount);
    }
    this.dev._countDraw(batch.vertexCount);
  }
  finish() {
    this.finished = true;
  }
  forceFinish() {
    this.finished = true;
  }
  applyUniform(program, name, v, kind = "float") {
    const loc = this.gl.getUniformLocation(program, name);
    if (loc === null || loc === void 0) return;
    if (typeof v === "number") {
      if (kind === "int") this.gl.uniform1i(loc, v | 0);
      else this.gl.uniform1f(loc, v);
    } else if (v instanceof Float32Array) {
      if (v.length === 9) this.gl.uniformMatrix3fv(loc, false, v);
      else this.gl.uniform1i(loc, v[0] ?? 0);
    } else if (v.length === 4) {
      this.gl.uniform4f(loc, v[0], v[1], v[2], v[3]);
    } else if (v.length === 1) {
      this.gl.uniform1f(loc, v[0]);
    }
  }
  assertOpen(what) {
    if (this.finished) {
      throw new Error(`\u547D\u4EE4\u5217\u8868\u5DF2 finish\uFF0C\u4ECD\u5728\u8C03\u7528 ${what}\uFF08\u4F1A\u753B\u8FDB\u4E0B\u4E00\u5E27\uFF09`);
    }
  }
  /**
   * 把管线的 `blend` 落到 GL 上。
   *
   * ★ 为什么必须在这里做：混合方式是**管线**的属性（一条不透明管线和一条半透明
   *   精灵管线可以同帧共存）。设备初始化时写死 `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`
   *   的版本会让 `None / Additive / Premultiplied` 静默退化成 Alpha ——
   *   画面"看着还行"，只是叠加不发光、某些特效莫名半透。与 `firstIndex` 同一类：
   *   字段被存下来，却从没被用。
   */
  applyBlend(mode) {
    const m = mode ?? BlendMode.Alpha;
    if (this.blendMode === m) return;
    this.blendMode = m;
    switch (m) {
      case BlendMode.None:
        this.gl.disable(GL.BLEND);
        break;
      case BlendMode.Additive:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.SRC_ALPHA, GL.ONE);
        break;
      case BlendMode.Premultiplied:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.ONE, GL.ONE_MINUS_SRC_ALPHA);
        break;
      default:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA);
        break;
    }
  }
};
var GL_FORMAT = {
  RGB8: 32849,
  RGBA16: 32859,
  RGBA16F: 34842,
  HALF_FLOAT: 5131
};
function glFormat(f) {
  const bpp = bytesPerPixel(f);
  switch (f) {
    case PixelFormat.RGB8:
      return { internal: GL_FORMAT.RGB8, format: GL.RGB, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    case PixelFormat.R8:
      return { internal: GL.R8, format: GL.R8, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    case PixelFormat.RGBA16:
      return { internal: GL_FORMAT.RGBA16, format: GL.RGBA, type: GL.UNSIGNED_SHORT, bytesPerPixel: bpp };
    case PixelFormat.RGBA16F:
      return { internal: GL_FORMAT.RGBA16F, format: GL.RGBA, type: GL_FORMAT.HALF_FLOAT, bytesPerPixel: bpp };
    case PixelFormat.RGBA8:
      return { internal: GL.RGBA8, format: GL.RGBA, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    default:
      throw new Error(`webgl2 \u540E\u7AEF\u4E0D\u8BA4\u8BC6 PixelFormat\uFF1A${String(f)}`);
  }
}
var webgl2Backend = {
  id: "webgl2",
  priority: 100,
  probe(options) {
    const o = options ?? {};
    const canvas2 = o.canvas;
    if (canvas2 === void 0 || typeof canvas2.getContext !== "function") return false;
    try {
      return isGL2Like(canvas2.getContext("webgl2"));
    } catch {
      return false;
    }
  },
  create(options) {
    const o = options ?? {};
    let ctx = null;
    try {
      ctx = o.canvas?.getContext?.("webgl2") ?? null;
    } catch (e) {
      return err(engineError("GFX.CONTEXT_FAILED", `getContext('webgl2') \u629B\u9519\uFF1A${String(e)}`));
    }
    if (!isGL2Like(ctx)) {
      return err(engineError("GFX.CONTEXT_FAILED", "\u62FF\u4E0D\u5230 WebGL2 \u4E0A\u4E0B\u6587\uFF08\u6D4F\u89C8\u5668\u4E0D\u652F\u6301\u6216\u88AB\u7981\u7528\uFF09"));
    }
    try {
      return ok(new GL2Device(ctx));
    } catch (e) {
      return err(engineError("GFX.DEVICE_INIT", e instanceof Error ? e.message : String(e)));
    }
  }
};

// src/backends/input-dom/device.ts
var PAD_BUTTONS = [
  "A",
  "B",
  "X",
  "Y",
  "LB",
  "RB",
  "LT",
  "RT",
  "Select",
  "Start",
  "L3",
  "R3",
  "DPadUp",
  "DPadDown",
  "DPadLeft",
  "DPadRight"
];
var PREVENT = /* @__PURE__ */ new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);
var DomInputDevice = class {
  caps = {
    backend: "dom",
    pointer: true,
    touch: true,
    // 构造时按环境改（有 `navigator.getGamepads` 才是 true）—— 写死 true 就是假能力声明
    gamepad: false,
    textInput: true
  };
  kb;
  ptr;
  down = /* @__PURE__ */ new Set();
  pressed = /* @__PURE__ */ new Set();
  released = /* @__PURE__ */ new Set();
  px = 0;
  py = 0;
  pDown = false;
  pPressed = false;
  pReleased = false;
  pButton = 0;
  wdx = 0;
  wdy = 0;
  text = "";
  subs = /* @__PURE__ */ new Set();
  gamepads;
  deadzone;
  /** 上一次 poll 时手柄按下的键码（用来算"刚按下 / 刚松开"的边缘）。 */
  padDown = /* @__PURE__ */ new Set();
  bound = [];
  /** 有输入框聚焦时，键盘不驱动游戏（编辑器输入场景名时不能同时让角色走）。 */
  textFocus = false;
  constructor(opts) {
    if (opts.keyboard === void 0 || opts.pointer === void 0) {
      throw new Error("DomInputDevice \u9700\u8981 keyboard \u4E0E pointer \u4E24\u4E2A\u76D1\u542C\u76EE\u6807");
    }
    this.kb = opts.keyboard;
    this.ptr = opts.pointer;
    this.gamepads = opts.gamepads ?? defaultGamepads();
    this.deadzone = opts.stickDeadzone ?? 0.35;
    this.caps = { ...this.caps, gamepad: this.gamepads !== null };
    this.bind();
  }
  bind() {
    const onKeyDown = (ev) => {
      if (this.isTyping(ev)) {
        if (ev.key !== void 0 && ev.key.length === 1) {
          this.text += ev.key;
          this.emit({ kind: "text", value: ev.key });
        }
        return;
      }
      const code = ev.code ?? "";
      if (code === "") return;
      if (!this.down.has(code)) {
        this.down.add(code);
        this.pressed.add(code);
      }
      if (PREVENT.has(code)) ev.preventDefault?.();
      this.emit({ kind: "key", code, down: true });
    };
    const onKeyUp = (ev) => {
      const code = ev.code ?? "";
      if (code === "" || !this.down.delete(code)) return;
      this.released.add(code);
      this.emit({ kind: "key", code, down: false });
    };
    const onBlur = () => {
      this.down.clear();
      this.pressed.clear();
      this.released.clear();
      this.pDown = false;
      this.textFocus = false;
      this.emit({ kind: "blur" });
    };
    const onFocusIn = (ev) => {
      this.textFocus = this.isTyping(ev);
    };
    const onPointerDown = (ev) => {
      this.updatePointer(ev);
      this.pDown = true;
      this.pPressed = true;
      this.pButton = ev.button ?? 0;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: true });
      ev.target?.setPointerCapture?.(0);
    };
    const onPointerUp = (ev) => {
      this.updatePointer(ev);
      if (!this.pDown) return;
      this.pDown = false;
      this.pReleased = true;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: false });
    };
    const onPointerMove = (ev) => {
      this.updatePointer(ev);
    };
    const onWheel = (ev) => {
      this.wdx += ev.deltaX ?? 0;
      this.wdy += ev.deltaY ?? 0;
      this.emit({ kind: "wheel", x: ev.deltaX ?? 0, y: ev.deltaY ?? 0 });
    };
    this.add(this.kb, "keydown", onKeyDown);
    this.add(this.kb, "keyup", onKeyUp);
    this.add(this.kb, "blur", onBlur);
    this.add(this.kb, "focusin", onFocusIn);
    this.add(this.ptr, "pointerdown", onPointerDown);
    this.add(this.ptr, "pointerup", onPointerUp);
    this.add(this.ptr, "pointermove", onPointerMove);
    this.add(this.ptr, "wheel", onWheel);
  }
  add(target, type, fn) {
    target.addEventListener(type, fn, { passive: false });
    this.bound.push([target, type, fn]);
  }
  isTyping(ev) {
    const tag = ev.target?.tagName?.toUpperCase();
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || this.textFocus;
  }
  updatePointer(ev) {
    if (ev.offsetX !== void 0) {
      this.px = ev.offsetX;
      this.py = ev.offsetY ?? 0;
    } else {
      this.px = ev.clientX ?? this.px;
      this.py = ev.clientY ?? this.py;
    }
  }
  poll() {
    const padNow = this.samplePads();
    const padPressed = [];
    const padReleased = [];
    for (const k of padNow) if (!this.padDown.has(k)) padPressed.push(k);
    for (const k of this.padDown) if (!padNow.has(k)) padReleased.push(k);
    this.padDown = padNow;
    const down = new Set(this.down);
    const pressedSet = new Set(this.pressed);
    const releasedSet = new Set(this.released);
    for (const k of padNow) down.add(k);
    for (const k of padPressed) pressedSet.add(k);
    for (const k of padReleased) releasedSet.add(k);
    const snap = {
      keysDown: down,
      keysPressed: pressedSet,
      keysReleased: releasedSet,
      pointer: {
        x: this.px,
        y: this.py,
        down: this.pDown,
        pressed: this.pPressed,
        released: this.pReleased,
        button: this.pButton
      },
      wheel: { dx: this.wdx, dy: this.wdy },
      text: this.text
    };
    this.pressed.clear();
    this.released.clear();
    this.pPressed = false;
    this.pReleased = false;
    this.wdx = 0;
    this.wdy = 0;
    this.text = "";
    return snap;
  }
  subscribe(fn) {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }
  setFocusTarget(target) {
  }
  /**
   * 读一次手柄，返回"当前按下的逻辑键码"。
   *
   * ★ 只读 `standard` 布局的前 16 个键与两个轴。非标准手柄（`mapping !== "standard"`）
   *   的键位因厂商而异 —— 假装能读会让"这个手柄不能用"变成"按 A 触发了 B"。
   *   这里不判断 mapping（结构接口里没有），但**名字按标准布局给**，
   *   文档里写明"非标准手柄需要在宿主侧做映射表"。
   */
  samplePads() {
    const out = /* @__PURE__ */ new Set();
    if (this.gamepads === null) return out;
    const pads = this.gamepads();
    for (const pad of pads) {
      if (pad === null || pad === void 0 || pad.connected === false) continue;
      const prefix = `Gamepad${pad.index ?? 0}.`;
      const btns = pad.buttons ?? [];
      for (let i = 0; i < PAD_BUTTONS.length && i < btns.length; i++) {
        const b = btns[i];
        if (b === void 0) continue;
        if (b.pressed === true || (b.value ?? 0) > 0.5) out.add(prefix + PAD_BUTTONS[i]);
      }
      const ax = pad.axes ?? [];
      const lx = ax[0] ?? 0;
      const ly = ax[1] ?? 0;
      if (lx < -this.deadzone) out.add(prefix + "LStickLeft");
      if (lx > this.deadzone) out.add(prefix + "LStickRight");
      if (ly < -this.deadzone) out.add(prefix + "LStickUp");
      if (ly > this.deadzone) out.add(prefix + "LStickDown");
    }
    return out;
  }
  reset() {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.padDown = /* @__PURE__ */ new Set();
    this.pDown = false;
    this.pPressed = false;
    this.pReleased = false;
  }
  destroy() {
    for (const [t, type, fn] of this.bound) t.removeEventListener(type, fn);
    this.bound.length = 0;
    this.subs.clear();
    this.reset();
  }
  emit(e) {
    for (const f of this.subs) f(e);
  }
};
function defaultGamepads() {
  const nav = globalThis.navigator;
  if (typeof nav?.getGamepads !== "function") return null;
  return () => nav.getGamepads();
}
var domInputBackend = {
  id: "dom",
  priority: 100,
  probe(options) {
    const o = options ?? {};
    return typeof o.keyboard?.addEventListener === "function";
  },
  create(options) {
    const o = options ?? {};
    if (typeof o.keyboard?.addEventListener !== "function") {
      return {
        ok: false,
        error: { code: "INPUT.NO_DOM", message: "\u6CA1\u6709\u53EF\u7528\u7684 DOM \u76D1\u542C\u76EE\u6807\uFF08keyboard/pointer\uFF09" }
      };
    }
    try {
      return ok(new DomInputDevice(o));
    } catch (e) {
      return {
        ok: false,
        error: { code: "INPUT.INIT_FAILED", message: e instanceof Error ? e.message : String(e) }
      };
    }
  }
};

// src/backends/audio-webaudio/device.ts
var WebAudioDevice = class {
  caps = {
    backend: "webaudio",
    maxVoices: 32,
    requiresGesture: true,
    spatial: false
  };
  ctx;
  next = 1;
  clips = /* @__PURE__ */ new Map();
  voices = /* @__PURE__ */ new Map();
  buses = /* @__PURE__ */ new Map([
    ["master", { name: "master", volume: 1, muted: false }]
  ]);
  busGains = /* @__PURE__ */ new Map();
  /** 因声部上限被拒的播放次数（可见，不静默）。 */
  voicesRejected = 0;
  constructor(ctx) {
    this.ctx = ctx;
  }
  async init() {
    try {
      const g = this.ctx.createGain();
      g.gain.value = 1;
      g.connect(this.ctx.destination);
      this.busGains.set("master", g);
      return ok(void 0);
    } catch (e) {
      return err(engineError("AUDIO.INIT_FAILED", e instanceof Error ? e.message : String(e)));
    }
  }
  async resume() {
    try {
      await this.ctx.resume();
    } catch (e) {
      return err(engineError("AUDIO.RESUME_FAILED", e instanceof Error ? e.message : String(e)));
    }
    if (this.ctx.state !== "running") {
      return err(
        engineError("AUDIO.NEEDS_GESTURE", `\u97F3\u9891\u4E0A\u4E0B\u6587\u4ECD\u5904\u4E8E '${this.ctx.state}'\uFF0C\u9700\u8981\u7528\u6237\u624B\u52BF\u540E\u624D\u80FD\u51FA\u58F0`)
      );
    }
    return ok(void 0);
  }
  async loadClip(name, data) {
    if (data.byteLength === 0) {
      return err(engineError("AUDIO.BAD_CLIP", "\u97F3\u9891\u6570\u636E\u4E3A\u7A7A\uFF1A" + name));
    }
    try {
      const buf = await this.ctx.decodeAudioData(data);
      const h = this.next++;
      this.clips.set(h, { name, buffer: buf });
      return ok(h);
    } catch (e) {
      return err(
        engineError("AUDIO.DECODE_FAILED", `\u89E3\u7801\u5931\u8D25\uFF1A${name}\uFF08${e instanceof Error ? e.message : String(e)}\uFF09`, {
          clip: name
        })
      );
    }
  }
  releaseClip(clip) {
    this.clips.delete(clip);
    for (const [h, v] of [...this.voices]) {
      if (v.clip === clip) this.stop(h);
    }
  }
  play(clip, opts = {}) {
    const c = this.clips.get(clip);
    if (c === void 0) return err(engineError("AUDIO.INVALID_CLIP", `clip ${clip} \u4E0D\u5B58\u5728\u6216\u5DF2\u91CA\u653E`));
    if (this.voices.size >= this.caps.maxVoices) {
      this.voicesRejected++;
      return err(
        engineError("AUDIO.NO_FREE_VOICE", `\u5DF2\u8FBE ${this.caps.maxVoices} \u4E2A\u58F0\u90E8\u4E0A\u9650`, { clip: c.name })
      );
    }
    const busName = opts.bus ?? "master";
    const bus = this.bus(busName);
    if (bus.muted) {
      return err(engineError("AUDIO.BUS_MUTED", `\u603B\u7EBF ${busName} \u5DF2\u9759\u97F3`, { clip: c.name }));
    }
    const src = this.ctx.createBufferSource();
    src.buffer = c.buffer;
    src.loop = opts.loop === true;
    src.playbackRate.value = opts.rate ?? 1;
    const gain = this.ctx.createGain();
    gain.gain.value = (opts.volume ?? 1) * bus.volume;
    src.connect(gain);
    gain.connect(this.busGain(busName));
    const h = this.next++;
    const rate = opts.rate ?? 1;
    const rec = {
      src,
      gain,
      clip,
      bus: busName,
      volume: (opts.volume ?? 1) * bus.volume,
      rate,
      loop: opts.loop === true,
      endsAt: this.ctx.currentTime + (opts.loop === true ? Number.POSITIVE_INFINITY : c.buffer.duration / rate),
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    };
    src.onended = () => {
      const v = this.voices.get(h);
      if (v !== void 0 && v.src === src) this.voices.delete(h);
    };
    try {
      src.start();
    } catch (e) {
      this.voices.delete(h);
      return err(
        engineError("AUDIO.START_FAILED", `\u64AD\u653E\u5931\u8D25\uFF08\u97F3\u9891\u4E0A\u4E0B\u6587\u53EF\u80FD\u672A\u89E3\u9501\uFF09\uFF1A${e instanceof Error ? e.message : String(e)}`, {
          clip: c.name
        })
      );
    }
    this.voices.set(h, rec);
    return ok(h);
  }
  stop(voice) {
    const v = this.voices.get(voice);
    if (v === void 0) return;
    this.voices.delete(voice);
    try {
      v.src.onended = null;
      v.src.stop();
      v.src.disconnect();
      v.gain.disconnect();
    } catch {
    }
  }
  setVoice(voice, patch) {
    const v = this.voices.get(voice);
    if (v === void 0) return;
    if (patch.volume !== void 0) {
      v.volume = patch.volume;
      v.gain.gain.value = patch.volume * this.bus(v.bus).volume;
    }
    if (patch.rate !== void 0) {
      v.rate = patch.rate;
      v.src.playbackRate.value = patch.rate;
    }
    if (patch.loop !== void 0) {
      v.loop = patch.loop;
      v.src.loop = patch.loop;
    }
  }
  getVoice(voice) {
    const v = this.voices.get(voice);
    if (v === void 0) return void 0;
    return { handle: voice, playing: true, clip: v.clip, bus: v.bus, volume: v.volume, rate: v.rate, loop: v.loop };
  }
  bus(name) {
    let b = this.buses.get(name);
    if (b === void 0) {
      b = { name, volume: 1, muted: false };
      this.buses.set(name, b);
    }
    return b;
  }
  busGain(name) {
    let g = this.busGains.get(name);
    if (g === void 0) {
      g = this.ctx.createGain();
      g.gain.value = this.bus(name).volume;
      const master = this.busGains.get("master");
      g.connect(master ?? this.ctx.destination);
      this.busGains.set(name, g);
    }
    return g;
  }
  setListener(_pos) {
  }
  get timeMs() {
    return this.ctx.currentTime * 1e3;
  }
  get activeVoices() {
    return this.voices.size;
  }
  destroy() {
    for (const v of [...this.voices.keys()]) this.stop(v);
    this.voices.clear();
    this.clips.clear();
    for (const g of this.busGains.values()) {
      try {
        g.disconnect();
      } catch {
      }
    }
    this.busGains.clear();
  }
};
var webAudioBackend = {
  id: "webaudio",
  priority: 100,
  probe(options) {
    if (typeof globalThis.AudioContext === "function") return true;
    const o = options ?? {};
    return typeof o.context?.createGain === "function";
  },
  create(options) {
    const o = options ?? {};
    let ctx = o.context;
    if (ctx === void 0) {
      const Ctor = globalThis.AudioContext;
      if (Ctor === void 0) {
        return err(engineError("AUDIO.NO_CONTEXT", "\u5F53\u524D\u73AF\u5883\u6CA1\u6709 AudioContext"));
      }
      try {
        ctx = new Ctor();
      } catch (e) {
        return err(engineError("AUDIO.NO_CONTEXT", e instanceof Error ? e.message : String(e)));
      }
    }
    try {
      return ok(new WebAudioDevice(ctx));
    } catch (e) {
      return err(engineError("AUDIO.INIT_FAILED", e instanceof Error ? e.message : String(e)));
    }
  }
};

// src/extensions/render/sprite.ts
var SPRITE_TYPE = "render.sprite";
var Sprite = class extends Component {
  /** 图集资产 id（空 = 用默认图集）。 */
  atlasId = "";
  /** 图集内帧名。 */
  frame = "";
  /** 世界尺寸（宽/高）。 */
  width = 1;
  height = 1;
  /** 顶点色（与纹理相乘）。 */
  r = 1;
  g = 1;
  b = 1;
  a = 1;
  /** 同 z 时的次序（小的先画）。 */
  order = 0;
  /**
   * 绘制层：0 = 背景（地面），1 = 实体（默认）。层在 z **之前**比较。
   *
   * ★ 默认 1 而不是 0：旧内容/旧存档没有这个字段，它们该保持"实体"行为。
   *   缺字段拿到 0 会让所有旧精灵掉到地形背后 —— 一帧都不显示，且没有任何报错。
   *
   * ★ 用整数而不是枚举：层数由宿主定（背景/实体/UI/ overlay…），引擎不替宿主
   *   决定有哪些层，只保证"小的先画"。
   */
  layer = 1;
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;
  /**
   * 水平锚点：0 = 左边界，0.5 = 中心。
   *
   * ★ 为什么需要它（这是"地形一直画不出来"的根因）：
   *   地形节点是**矩形**，位置是矩形左上角的格子坐标。只有 `pivotY` 时，
   *   精灵永远以节点位置为水平中心 —— 一块 8×5 的地形要么整体右移半块，
   *   要么就得把节点位置改成矩形中心（那会破坏「地形节点位置 = 格子坐标」，
   *   连带破坏反查与存档往返）。加一个对称的 `pivotX` 是唯一不动代价的解法。
   *
   * ★ 默认 0.5 = 与"只有 pivotY"时的行为完全一致：旧内容/旧代码的显示不变。
   *   也正因为如此，旧存档里没有这个字段时**必须**拿到 0.5（不是 0）——
   *   见 scene-io 的 `missingFields`：缺字段会走类里的默认值，不会被写成 0。
   */
  pivotX = 0.5;
  /**
   * 沿精灵宽度重复贴图多少次（T288）。
   *
   * ★ 为什么它是"次数"而不是"UV 缩放量"：调用方想的是"这一块 8 格宽的地形，
   *   每格铺一张 64×64 的噪点"—— 8 次，一个整数。乘出来的 UV 是 8×帧宽，
   *   那是实现细节。写成"缩放量"会让每个宿主都得自己算 `宽 / 贴图像素宽`，
   *   而那正是 T288 想消灭的"每处各算一遍"。
   *
   * ★ 只能用在 `wrap: repeat` 的**瓦片页**上（见 `buildTilePages`）。
   *   在 clamp 页上平铺，GPU 会把边缘像素抻出去 —— 画面是一条脏边，
   *   而精灵的所有数字都对。渲染模块对这种组合**告警**（不静默跳过）。
   *
   * ★ 默认 1 = 与旧行为逐字节一致：旧存档没有这个字段时也必须拿到 1
   *   （`scene-io` 的缺字段走类默认值，不会被写成 0 —— 0 会让精灵整块消失）。
   */
  tileX = 1;
  /** 沿精灵高度重复贴图多少次。语义同 `tileX`。 */
  tileY = 1;
  schema = {
    type: SPRITE_TYPE,
    fields: {
      atlasId: FieldType.String,
      frame: FieldType.String,
      width: FieldType.Float,
      height: FieldType.Float,
      r: FieldType.Float,
      g: FieldType.Float,
      b: FieldType.Float,
      a: FieldType.Float,
      order: FieldType.Int,
      layer: FieldType.Int,
      visible: FieldType.Bool,
      pivotY: FieldType.Float,
      pivotX: FieldType.Float,
      tileX: FieldType.Float,
      tileY: FieldType.Float
    }
  };
};

// src/extensions/render/atlas.ts
var Pen = class {
  constructor(px, W, H) {
    this.px = px;
    this.W = W;
    this.H = H;
  }
  /** 当前绘制原点：**每个帧块都必须先 `origin()` 到自己的矩形左上角**。 */
  ox = 0;
  oy = 0;
  /**
   * ★ 这个方法是 T330 顺带抓出来的第二个缺陷的解药：
   *   原来每个帧的绘制用的是**绝对坐标**，而 `layout` 里 rock/player/berry 分别在
   *   x=64/112/144 —— 于是那三帧的图形全被画进了 tree 的矩形（x 0..64），
   *   三帧本身**一个不透明像素都没有**。
   *   症状是"兜底图集里少三类东西"，而所有既有判据（帧在不在、UV 对不对、
   *   尺寸对不对）都是绿的：它们查的是地图，不是地图上有没有东西。
   */
  origin(x, y) {
    this.ox = x;
    this.oy = y;
  }
  put(x, y, r, g, b, a = 255) {
    const ax = this.ox + x;
    const ay = this.oy + y;
    if (ax < 0 || ay < 0 || ax >= this.W || ay >= this.H) return;
    const i = (ay * this.W + ax) * 4;
    const src = a / 255;
    const dstA = this.px[i + 3] / 255;
    const outA = src + dstA * (1 - src);
    if (outA <= 0) return;
    this.px[i] = Math.round((r * src + this.px[i] * dstA * (1 - src)) / outA);
    this.px[i + 1] = Math.round((g * src + this.px[i + 1] * dstA * (1 - src)) / outA);
    this.px[i + 2] = Math.round((b * src + this.px[i + 2] * dstA * (1 - src)) / outA);
    this.px[i + 3] = Math.round(outA * 255);
  }
  rect(x, y, w, h, c) {
    for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) this.put(i, j, c[0], c[1], c[2]);
  }
  /** 圆（用于石头/浆果）。 */
  disc(cx, cy, r, c) {
    for (let j = -r; j <= r; j++) {
      for (let i = -r; i <= r; i++) {
        if (i * i + j * j <= r * r) this.put(cx + i, cy + j, c[0], c[1], c[2]);
      }
    }
  }
  /** 三角（树冠）。 */
  triangle(x0, y0, x1, y1, x2, y2, c) {
    const minY = Math.min(y0, y1, y2);
    const maxY = Math.max(y0, y1, y2);
    for (let y = minY; y <= maxY; y++) {
      const xs = [];
      const edges = [
        [x0, y0, x1, y1],
        [x1, y1, x2, y2],
        [x2, y2, x0, y0]
      ];
      for (const [ax, ay, bx, by] of edges) {
        if (ay <= y && by >= y || by <= y && ay >= y) {
          if (Math.abs(by - ay) < 1e-9) {
            xs.push(ax, bx);
          } else {
            xs.push(ax + (y - ay) / (by - ay) * (bx - ax));
          }
        }
      }
      if (xs.length >= 2) {
        const lo = Math.round(Math.min(...xs));
        const hi = Math.round(Math.max(...xs));
        for (let x = lo; x <= hi; x++) this.put(x, y, c[0], c[1], c[2]);
      }
    }
  }
};
function buildProceduralAtlas() {
  const W = 256;
  const H = 256;
  const px = new Uint8Array(W * H * 4);
  const pen = new Pen(px, W, H);
  const layout = [
    { name: "tree", x: 0, y: 0, w: 64, h: 96 },
    { name: "rock", x: 64, y: 0, w: 48, h: 40 },
    { name: "player", x: 112, y: 0, w: 32, h: 48 },
    { name: "berry", x: 144, y: 0, w: 24, h: 24 },
    { name: "ground", x: 0, y: 96, w: 64, h: 64 },
    { name: "terrain", x: 64, y: 96, w: 64, h: 64 }
  ];
  const at = (n) => {
    const l = layout.find((e) => e.name === n);
    if (l === void 0) throw new Error(`\u5E03\u5C40\u91CC\u6CA1\u6709\u5E27 "${n}"\uFF08\u5185\u90E8\u4E00\u81F4\u6027\u9519\u8BEF\uFF09`);
    return { x: l.x, y: l.y };
  };
  pen.origin(at("tree").x, at("tree").y);
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);
  pen.origin(at("rock").x, at("rock").y);
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);
  pen.origin(at("player").x, at("player").y);
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);
  pen.origin(at("berry").x, at("berry").y);
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);
  let seed = 19088743;
  const rnd = () => {
    seed = seed * 1103515245 + 12345 & 2147483647;
    return seed / 2147483647;
  };
  pen.origin(at("ground").x, at("ground").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
    }
  }
  pen.origin(at("terrain").x, at("terrain").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 188 + Math.floor(rnd() * 31);
      pen.rect(x, y, 1, 1, [v, v, v]);
    }
  }
  const frames = /* @__PURE__ */ new Map();
  for (const l of layout) {
    frames.set(l.name, {
      u0: l.x / W,
      v0: l.y / H,
      u1: (l.x + l.w) / W,
      v1: (l.y + l.h) / H,
      w: l.w,
      h: l.h
    });
  }
  return { width: W, height: H, pixels: px, frames };
}
function buildTilePages(main2, frameNames) {
  const out = [];
  for (const name of frameNames) {
    const f = main2.frames.get(name);
    if (f === void 0) continue;
    const x0 = Math.round(f.u0 * main2.width);
    const y0 = Math.round(f.v0 * main2.height);
    const w = f.w;
    const h = f.h;
    const px = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const from = ((y0 + y) * main2.width + x0) * 4;
      px.set(main2.pixels.subarray(from, from + w * 4), y * w * 4);
    }
    let page = {
      width: w,
      height: h,
      pixels: px,
      wrap: "repeat",
      name: tilePageName(name),
      frames: /* @__PURE__ */ new Map([[name, { u0: 0, v0: 0, u1: 1, v1: 1, w, h }]])
    };
    if (main2.pixels16 !== void 0) {
      const p16 = new Uint16Array(w * h * 4);
      for (let y = 0; y < h; y++) {
        const from = ((y0 + y) * main2.width + x0) * 4;
        p16.set(main2.pixels16.subarray(from, from + w * 4), y * w * 4);
      }
      page = { ...page, format: PixelFormat.RGBA16, pixels16: p16 };
      for (let i = 0; i < px.length; i++) px[i] = Math.round(p16[i] / 257);
    }
    out.push(page);
  }
  return out;
}
function tilePageName(frame) {
  return `${frame}.tile`;
}

// src/extensions/render/shaders-glsl.ts
var SPRITE_VS = `#version 300 es
layout(location = 0) in vec2 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
out vec2 v_uv;
out vec4 v_color;
void main() {
  v_uv = a_uv;
  v_color = a_color;
  gl_Position = vec4(a_position, 0.0, 1.0);
}`;
var SPRITE_FS = `#version 300 es
precision mediump float;
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_texture;
uniform int u_useTexture;
out vec4 o_color;
void main() {
  vec4 c = u_useTexture == 1 ? texture(u_texture, v_uv) : vec4(1.0);
  o_color = c * v_color;
}`;

// src/extensions/render/batch2d.ts
var FLOATS_PER_VERTEX = 8;
var SpriteBatch = class _SpriteBatch {
  maxQuads;
  vertices;
  indices;
  /** 排好序之后的 items（判据可以直接读它验证顺序）。 */
  items = [];
  constructor(maxQuads = 4096) {
    if (!(maxQuads > 0)) throw new RangeError("maxQuads \u5FC5\u987B > 0");
    if (maxQuads * 4 > 65536) {
      throw new RangeError(`maxQuads=${maxQuads} \u8D85\u8FC7 Uint16 \u7D22\u5F15\u4E0A\u9650\uFF08\u6700\u591A 16384\uFF09`);
    }
    this.maxQuads = maxQuads;
    this.vertices = new Float32Array(maxQuads * 4 * FLOATS_PER_VERTEX);
    this.indices = new Uint16Array(maxQuads * 6);
    for (let q = 0; q < maxQuads; q++) {
      const v = q * 4;
      const i = q * 6;
      this.indices[i] = v;
      this.indices[i + 1] = v + 1;
      this.indices[i + 2] = v + 2;
      this.indices[i + 3] = v;
      this.indices[i + 4] = v + 2;
      this.indices[i + 5] = v + 3;
    }
  }
  /**
   * 排序（原地）。规则见文件头。
   * ★ 用**显式比较函数**而不是 `Array.sort` 的默认行为：默认会把数字转字符串，
   *   而 `[10, 9]` 会排成 `[10, 9]`（字符串 "10" < "9"）—— 这类 bug 极难发现。
   * ★ `?? 1`：缺 layer 的 RenderItem 当实体。0 是背景，把旧数据默认成背景
   *   会让所有东西一夜之间消失在地形后面 —— 与 Sprite 的默认值同思路。
   */
  static sort(items) {
    items.sort((a, b) => {
      const la = a.layer ?? 1;
      const lb = b.layer ?? 1;
      if (la !== lb) return la - lb;
      if (a.z !== b.z) return b.z - a.z;
      if (a.order !== b.order) return a.order - b.order;
      if (a.atlas !== b.atlas) return a.atlas - b.atlas;
      return a.nodeId - b.nodeId;
    });
  }
  /**
   * 组装顶点。返回实际写入的 quad 数（可能被 `maxQuads` 截断）。
   * ★ 截断必须**被报告**：调用方据此决定要不要再开一批。
   *   静默截断的症状是"东西画到某个数量就不见了"，而且只在实体多的场景出现。
   */
  build(items, cam) {
    const sorted = [...items];
    _SpriteBatch.sort(sorted);
    this.items = sorted;
    const n = Math.min(sorted.length, this.maxQuads);
    let atlasSwitches = 0;
    let lastAtlas = -1;
    const runsMut = [];
    for (let q = 0; q < n; q++) {
      const it = sorted[q];
      if (it.atlas !== lastAtlas) {
        atlasSwitches++;
        lastAtlas = it.atlas;
        runsMut.push({ atlas: it.atlas, start: q, count: 1 });
      } else {
        const prev = runsMut[runsMut.length - 1];
        if (prev === void 0) throw new Error("batch2d \u5185\u90E8\u9519\u8BEF\uFF1A\u7B2C\u4E00\u6BB5\u6CA1\u5EFA\u8D77\u6765");
        prev.count++;
      }
      const c = cam.project(it.x, it.z);
      const e = cam.extents(it.w, it.h);
      const cy = c.y + (0.5 - it.pivotY) * 2 * e.halfH;
      const cx = c.x + (0.5 - it.pivotX) * 2 * e.halfW;
      const x0 = cx - e.halfW;
      const x1 = cx + e.halfW;
      const y0 = cy - e.halfH;
      const y1 = cy + e.halfH;
      const tileX = Math.max(1, Math.floor(it.tileX ?? 1));
      const tileY = Math.max(1, Math.floor(it.tileY ?? 1));
      const ua = it.u0;
      const ub = it.u0 + (it.u1 - it.u0) * tileX;
      const va = it.v0;
      const vb = it.v0 + (it.v1 - it.v0) * tileY;
      const base = q * 4 * FLOATS_PER_VERTEX;
      writeVert(this.vertices, base, x0, y0, ua, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX, x1, y0, ub, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 2, x1, y1, ub, va, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 3, x0, y1, ua, va, it);
    }
    return {
      quadCount: n,
      vertexCount: n * 4,
      indexCount: n * 6,
      drawCalls: runsMut.length,
      atlasSwitches,
      runs: runsMut
    };
  }
  /** 零拷贝视图：只把前 `quadCount` 个顶点交给 GPU（避免每帧上传满 buffer）。 */
  vertexView(quadCount) {
    return this.vertices.subarray(0, quadCount * 4 * FLOATS_PER_VERTEX);
  }
  indexView(quadCount) {
    return this.indices.subarray(0, quadCount * 6);
  }
};
function writeVert(out, at, x, y, u, v, it) {
  out[at] = x;
  out[at + 1] = y;
  out[at + 2] = u;
  out[at + 3] = v;
  out[at + 4] = it.r;
  out[at + 5] = it.g;
  out[at + 6] = it.b;
  out[at + 7] = it.a;
}

// src/extensions/render/camera.ts
var Camera2D = class {
  vw;
  vh;
  zoom;
  tiltY;
  x;
  z;
  clearColor;
  /** 每世界单位有多少像素（x 方向）。UI 命中测试、像素对齐用。 */
  _pxPerUnit = 1;
  constructor(cfg) {
    if (!(cfg.viewportWidth > 0) || !(cfg.viewportHeight > 0)) {
      throw new RangeError(`\u89C6\u53E3\u5C3A\u5BF8\u5FC5\u987B > 0\uFF1A${cfg.viewportWidth}x${cfg.viewportHeight}`);
    }
    this.vw = cfg.viewportWidth;
    this.vh = cfg.viewportHeight;
    this.zoom = cfg.zoom ?? 32;
    this.tiltY = cfg.tiltY ?? 0.62;
    this.x = cfg.x ?? 0;
    this.z = cfg.z ?? 0;
    this.clearColor = cfg.clearColor ?? new Color(0.07, 0.08, 0.1, 1);
    this.recompute();
  }
  recompute() {
    this._pxPerUnit = this.zoom;
  }
  get pxPerUnit() {
    return this._pxPerUnit;
  }
  setViewport(w, h) {
    if (!(w > 0) || !(h > 0)) return;
    this.vw = w;
    this.vh = h;
  }
  /** 立刻移到（无平滑）。平滑跟随属于"控制器"的职责，不属于相机。 */
  moveTo(x, z) {
    this.x = x;
    this.z = z;
  }
  /** 世界 (x,z) → 裁剪空间 (-1..1)。 */
  project(wx, wz) {
    const sx = (wx - this.x) * this.zoom / (this.vw / 2);
    const sy = (wz - this.z) * this.zoom * this.tiltY / (this.vh / 2);
    return { x: sx, y: sy };
  }
  /** 世界尺寸 → 裁剪空间半宽/半高（精灵用）。 */
  extents(worldW, worldH) {
    return {
      halfW: worldW * this.zoom / this.vw,
      halfH: worldH * this.zoom * this.tiltY / this.vh
    };
  }
  /** 屏幕像素 → 世界 XZ（拾取/点选用）。 */
  unproject(px, py) {
    const nx = px / this.vw * 2 - 1;
    const ny = 1 - py / this.vh * 2;
    return {
      x: this.x + nx * this.vw / 2 / this.zoom,
      z: this.z + ny * this.vh / 2 / (this.zoom * this.tiltY)
    };
  }
  /** 当前可见的世界矩形（裁剪用，也是"哪些实体该画"的粗筛）。 */
  visibleRect() {
    const halfW = this.vw / 2 / this.zoom;
    const halfH = this.vh / 2 / (this.zoom * this.tiltY);
    return {
      xMin: this.x - halfW,
      xMax: this.x + halfW,
      zMin: this.z - halfH,
      zMax: this.z + halfH
    };
  }
};

// src/extensions/render/render-module.ts
function spriteToRenderItem(s, f, nodeId, x, z, atlas) {
  return {
    nodeId,
    x,
    z,
    w: s.width,
    h: s.height,
    u0: f.u0,
    v0: f.v0,
    u1: f.u1,
    v1: f.v1,
    r: s.r,
    g: s.g,
    b: s.b,
    a: s.a,
    order: s.order,
    layer: s.layer,
    pivotY: s.pivotY,
    pivotX: s.pivotX,
    atlas,
    tileX: s.tileX,
    tileY: s.tileY
  };
}
function frameRect(a, f, name) {
  const px = Math.min(a.width - 1, Math.max(0, Math.floor((f.u0 + f.u1) / 2 * a.width)));
  const py = Math.min(a.height - 1, Math.max(0, Math.floor((f.v0 + f.v1) / 2 * a.height)));
  const i = (py * a.width + px) * 4;
  const x0 = Math.floor(f.u0 * a.width);
  const x1 = Math.max(x0, Math.floor(f.u1 * a.width) - 1);
  const y0 = Math.floor(f.v0 * a.height);
  const y1 = Math.max(y0, Math.floor(f.v1 * a.height) - 1);
  const midX = x0 + x1 >> 1;
  let opaqueRows = 0;
  for (let y = y0; y <= y1; y++) {
    if ((a.pixels[(y * a.width + midX) * 4 + 3] ?? 0) > 0) opaqueRows++;
  }
  return {
    u0: f.u0,
    v0: f.v0,
    u1: f.u1,
    v1: f.v1,
    w: f.w,
    h: f.h,
    atlasW: a.width,
    atlasH: a.height,
    opaqueRows,
    sample: {
      r: a.pixels[i] ?? 0,
      g: a.pixels[i + 1] ?? 0,
      b: a.pixels[i + 2] ?? 0,
      a: a.pixels[i + 3] ?? 0
    }
  };
}
function createRenderModule(opts) {
  const camera = new Camera2D({
    viewportWidth: opts.viewportWidth,
    viewportHeight: opts.viewportHeight,
    zoom: opts.zoom ?? 32,
    tiltY: opts.tiltY ?? 0.62
  });
  let dev = null;
  let tex = [];
  let slotOfName = /* @__PURE__ */ new Map();
  let shader = null;
  let pipeline = null;
  let vbo = null;
  let ibo = null;
  let offRender = null;
  let batch = null;
  let pages = [];
  let atlasFmt = PixelFormat.RGBA8;
  let ctxRef = null;
  let warnedAtlasIds = /* @__PURE__ */ new Set();
  let lastFrame = { quads: 0, drawCalls: 0, atlasSwitches: 0, culled: 0 };
  const mod = {
    id: opts.id ?? "render.batch2d",
    deps: [],
    init(ctx) {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;
      const procedural = opts.atlas === void 0;
      const main2 = opts.atlas ?? buildProceduralAtlas();
      pages = [main2, ...buildTilePages(main2, opts.tileFrames ?? ["terrain"]), ...opts.extraPages ?? []];
      const slots = /* @__PURE__ */ new Map();
      for (const [i, p] of pages.entries()) {
        const name = p.name;
        if (name !== void 0 && name !== "") {
          if (slots.has(name)) {
            return err(engineError("RENDER.DUP_PAGE", `\u4E24\u4E2A\u56FE\u96C6\u9875\u91CD\u540D\uFF1A${name}\uFF08atlasId \u4F1A\u6307\u5411\u4E0D\u786E\u5B9A\u7684\u90A3\u4E00\u9875\uFF09`));
          }
          slots.set(name, i);
        }
      }
      slotOfName = slots;
      const uploaded = [];
      for (const [i, page] of pages.entries()) {
        const fmt = page.format ?? PixelFormat.RGBA8;
        const p16 = page.pixels16;
        if (fmt === PixelFormat.RGBA16 && p16 === void 0) {
          for (const h of uploaded) d.destroyTexture(h);
          return err(
            engineError("RENDER.BAD_ATLAS", `\u56FE\u96C6\u9875 ${i}\uFF08${page.name ?? "main"}\uFF09format \u662F rgba16\uFF0C\u4F46\u6CA1\u7ED9 pixels16\uFF08\u89E3\u7801\u5668\u5077\u5077\u964D\u91C7\u6837\u4E86\uFF1F\uFF09`)
          );
        }
        const upload = fmt === PixelFormat.RGBA16 && p16 !== void 0 ? p16 : page.pixels;
        const t = d.createTexture(
          {
            width: page.width,
            height: page.height,
            format: fmt,
            filter: TextureFilter.Nearest,
            // ★ wrap 是**页级**的：瓦片页 repeat（平铺），主图集 clamp（不抻边）。
            //   两页混用同一张 wrap 的两种错法都试过：主图集开 repeat ⇒ 邻居帧被采进来；
            //   瓦片页开 clamp ⇒ 平铺的接缝处一条脏边。两种都不报错，只难看。
            wrap: page.wrap ?? TextureWrap.Clamp,
            // label 不是装饰：null 后端的 `describe()` 与崩溃报告会原样打印它，
            // "这张纹理到底是资产图集还是兜底的程序化图集"必须一眼可辨；
            // 精度同理 —— 一个 "atlas:rgba16" 比翻像素快得多。
            label: (procedural && i === 0 ? "engine.procedural-atlas" : `engine.atlas[${i}]`) + (page.name !== void 0 ? `:${page.name}` : "") + (fmt === PixelFormat.RGBA16 ? ":rgba16" : "") + (page.wrap === TextureWrap.Repeat ? ":repeat" : "")
          },
          upload
        );
        if (!t.ok) {
          for (const h of uploaded) d.destroyTexture(h);
          return t;
        }
        uploaded.push(t.value);
      }
      tex = uploaded;
      atlasFmt = main2.format ?? PixelFormat.RGBA8;
      const sh = d.createShader({
        vertex: SPRITE_VS,
        fragment: SPRITE_FS,
        label: "engine.sprite"
      });
      if (!sh.ok) {
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return sh;
      }
      shader = sh.value;
      const pl = d.createPipeline({
        shader,
        layout: SPRITE_VERTEX_LAYOUT,
        blend: BlendMode.Alpha,
        label: "engine.sprite"
      });
      if (!pl.ok) {
        d.destroyShader(shader);
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return pl;
      }
      pipeline = pl.value;
      batch = new SpriteBatch(opts.maxQuads ?? 4096);
      const vb = d.createBuffer({
        usage: BufferUsage.Vertex,
        byteLength: batch.vertices.byteLength,
        dynamic: true,
        label: "engine.sprite.vbo"
      });
      if (!vb.ok) {
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return vb;
      }
      vbo = vb.value;
      const ib = d.createBuffer({
        usage: BufferUsage.Index,
        byteLength: batch.indices.byteLength,
        dynamic: false,
        label: "engine.sprite.ibo"
      });
      if (!ib.ok) {
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return ib;
      }
      ibo = ib.value;
      const up = d.updateBuffer(ibo, batch.indices);
      if (!up.ok) {
        d.destroyBuffer(ibo);
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return up;
      }
      ctx.log.channel("render").info(
        `\u6E32\u67D3\u6A21\u5757\u5C31\u7EEA\uFF1A${pages.map((p) => `${p.name ?? "main"} ${p.width}x${p.height}`).join(" + ")} \xB7 \u4E3B\u56FE\u96C6 ${main2.frames.size} \u5E27 \xB7 ${atlasFmt} \xB7 \u6279\u91CF\u4E0A\u9650 ${batch.maxQuads} quad`
      );
      return ok(void 0);
    },
    start() {
      const ctx = ctxRef;
      if (ctx === null) return err(engineError("RENDER.NOT_INIT", "start \u4E4B\u524D\u6CA1\u6709 init"));
      const frame = ctx.services.require(Services.Frame);
      offRender = frame.onRender(renderFrame);
      return ok(void 0);
    },
    stop() {
      offRender?.();
      offRender = null;
    },
    dispose() {
      const d = dev;
      if (d !== null) {
        if (ibo !== null) d.destroyBuffer(ibo);
        if (vbo !== null) d.destroyBuffer(vbo);
        if (pipeline !== null) d.destroyPipeline(pipeline);
        if (shader !== null) d.destroyShader(shader);
        for (const h of tex) d.destroyTexture(h);
      }
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      tex = [];
      dev = null;
      batch = null;
      pages = [];
      slotOfName = /* @__PURE__ */ new Map();
      atlasFmt = PixelFormat.RGBA8;
    },
    describe() {
      return `\u6E32\u67D3\uFF1A${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ${lastFrame.atlasSwitches} \u7EB9\u7406\u5207\u6362`;
    },
    get camera() {
      return camera;
    },
    get lastFrame() {
      return lastFrame;
    },
    get atlasFrameCount() {
      return pages[0]?.frames.size ?? 0;
    },
    get atlasFormat() {
      return atlasFmt;
    },
    /** 图集页数（主图集 + 瓦片页 + 附加页）。init 之前是 0。 */
    get atlasPageCount() {
      return pages.length;
    },
    atlasFrame(name) {
      const main2 = pages[0];
      const mf = main2?.frames.get(name);
      if (main2 !== void 0 && mf !== void 0) return frameRect(main2, mf, name);
      for (const a of pages) {
        const f = a.frames.get(name);
        if (f !== void 0) return frameRect(a, f, name);
      }
      return void 0;
    },
    lastVertices(quads) {
      const b = batch;
      if (b === null) return new Float32Array(0);
      return b.vertexView(Math.max(0, quads)).slice();
    }
  };
  function renderFrame(info) {
    const d = dev;
    const b = batch;
    const scene = ctxRef?.services.get(Services.Scene);
    if (d === null || b === null || pages.length === 0 || scene === void 0) return;
    const target = opts.follow?.();
    if (target !== void 0) {
      camera.moveTo(target.x, target.z);
    }
    const sprites = scene.componentsOf("render.sprite");
    const items = [];
    const vis = camera.visibleRect();
    let culled = 0;
    warnedAtlasIds.clear();
    for (const s of sprites) {
      if (!s.visible) continue;
      const node = s.node;
      if (node === null || !node.activeInHierarchy) continue;
      const p = node.worldPosition;
      const pad = Math.max(s.width, s.height);
      if (p.x < vis.xMin - pad || p.x > vis.xMax + pad || p.y < vis.zMin - pad || p.y > vis.zMax + pad) {
        culled++;
        continue;
      }
      let slot = 0;
      if (s.atlasId !== "") {
        const found = slotOfName.get(s.atlasId);
        if (found === void 0) {
          if (!warnedAtlasIds.has(s.atlasId)) {
            warnedAtlasIds.add(s.atlasId);
            ctxRef?.log.channel("render").warn(
              `Sprite \u7684 atlasId \u6CA1\u6709\u5BF9\u5E94\u56FE\u96C6\u9875\uFF1A${JSON.stringify(s.atlasId)}\uFF08\u5DF2\u56DE\u843D\u5230\u4E3B\u56FE\u96C6\uFF09`,
              { node: node.id },
              null
            );
          }
        } else {
          slot = found;
        }
      }
      const f = frameOf(slot, s.frame);
      if (f === void 0) {
        ctxRef?.log.channel("render").warn(`Sprite \u5E27\u540D\u4E0D\u5B58\u5728\uFF1A${JSON.stringify(s.frame)}`, { node: node.id }, null);
        continue;
      }
      items.push(spriteToRenderItem(s, f, node.id, p.x, p.y, slot));
      if ((s.tileX > 1 || s.tileY > 1) && (pages[slot]?.wrap ?? "clamp") !== "repeat") {
        ctxRef?.log.channel("render").warn(
          `Sprite \u5728 clamp \u9875\u4E0A\u5E73\u94FA\uFF08tileX=${s.tileX}, tileY=${s.tileY}, atlasId=${JSON.stringify(s.atlasId)}\uFF09\u2014\u2014 \u63A5\u7F1D\u4F1A\u88AB\u62BB\u6210\u810F\u8FB9\uFF1B\u8BF7\u6539\u7528 buildTilePages \u62BD\u51FA\u7684 repeat \u9875`,
          { node: node.id },
          null
        );
      }
    }
    const built = b.build(items, camera);
    lastFrame = {
      quads: built.quadCount,
      drawCalls: built.drawCalls,
      atlasSwitches: built.atlasSwitches,
      culled
    };
    const vw = d.size.width;
    const vh = d.size.height;
    camera.setViewport(vw, vh);
    const cmd = d.beginFrame(null);
    cmd.setViewport(new Rect(0, 0, vw, vh));
    cmd.clear(camera.clearColor, 1);
    if (built.quadCount > 0 && vbo !== null && ibo !== null && pipeline !== null) {
      const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
      if (!up.ok) {
        ctxRef?.log.channel("render").error(`\u9876\u70B9\u4E0A\u4F20\u5931\u8D25\uFF1A${up.error.message}`, void 0, null);
      } else {
        cmd.setPipeline(pipeline);
        for (const run of built.runs) {
          const page = tex[run.atlas];
          if (page === void 0) {
            ctxRef?.log.channel("render").error(`\u56FE\u96C6\u69FD\u4F4D ${run.atlas} \u6CA1\u6709\u7EB9\u7406\uFF08\u6BB5\u88AB\u8DF3\u8FC7\uFF09`, void 0, null);
            continue;
          }
          cmd.bindTexture(0, page);
          cmd.setUniform("u_useTexture", 1, "int");
          cmd.draw({
            vertices: vbo,
            indices: ibo,
            vertexCount: (run.start + run.count) * 4,
            indexCount: run.count * 6,
            // ★ 段在索引缓冲里的偏移：顶点是连续排的，索引也是按 quad 顺序生成的，
            //   所以第 q 个 quad 的索引起点就是 q*6。少了这个偏移，第二段会把
            //   **第一段的几何**再画一遍（画面重复而不是切换贴图）。
            firstIndex: run.start * 6
          });
        }
      }
    }
    cmd.finish();
    d.endFrame();
  }
  function frameOf(slot, frame) {
    return pages[slot]?.frames.get(frame);
  }
  return mod;
}

// src/extensions/physics/physics.ts
var AUTO_CELL_MIN = 0.5;
var AUTO_CELL_MAX = 16;
var AUTO_CELL_FALLBACK = 1;
var EPS = 1e-9;
var SpatialHashWorld = class {
  cellSize;
  autoCell;
  maxIterations;
  skin;
  bodies = /* @__PURE__ */ new Map();
  /** cell key → body id 列表 */
  cells = /* @__PURE__ */ new Map();
  /**
   * body id → 它现在在哪个格键里。
   *
   * ★ 没有它的时候，`reindex` 只能**遍历所有格**去找这个 id（`indexOf`）——
   *   O(#格) 每次。密集场景里每一步要推几千次，于是 2000 实体 × 250 格 = 几十万次
   *   `indexOf`，实测把 2.8ms 的解算拖到 21ms。性能闸门（physics-perf.test.ts）
   *   第一次跑就把这笔账算出来了。
   */
  cellOfBody = /* @__PURE__ */ new Map();
  /**
   * 全场最大 `rangeOf` 的缓存。
   *
   * ★ 它原来是在 `resolve()` 的内层循环里**每个体每次迭代都重算一遍**（O(n)），
   *   于是整个解算是 O(n²·迭代)。而实体只在 add/remove 时增减 —— 这是个纯缓存问题，
   *   不是算法问题：`maxRadiusNearby()` 现在 O(1)。
   *   失效点只有 add / remove / clear 三处（body 的半径是 add 时定的，之后不可变）。
   */
  maxRange = 0;
  /** 工作量计数（见 `PhysicsStats` 的三个同名注释）：只增不减，`clear()` 归零。 */
  _bodyScans = 0;
  _maxRangeScans = 0;
  _cellScans = 0;
  _settlePasses = 0;
  _settleStaticPushes = 0;
  _cellMoves = 0;
  _pairChecks = 0;
  _candidateScans = 0;
  /**
   * 动态体的 id 集合。
   *
   * ★ `resolve()` 原来遍历**所有** body 再 `if (b.isStatic) continue` ——
   *   于是"加 1900 棵静态树"会让 50 个动态体的解算慢 4.6 倍（实测），
   *   而静态树本不该影响动态体的成本。维护一个集合就把这一侧的开销从 O(全场)
   *   变成 O(动态数)。
   * ★ 不变量：`isStatic` 在 `add` 时确定，之后不可变（要变就先 remove 再 add）。
   */
  dynamicIds = /* @__PURE__ */ new Set();
  pos;
  _queries = 0;
  _pushes = 0;
  _unresolved = 0;
  constructor(pos, cfg = {}) {
    this.pos = pos;
    this.autoCell = cfg.cellSize === void 0;
    this.cellSize = cfg.cellSize ?? AUTO_CELL_FALLBACK;
    this.maxIterations = cfg.maxIterations ?? 3;
    this.skin = cfg.skin ?? 1e-3;
    if (!(this.cellSize > 0)) throw new RangeError("cellSize \u5FC5\u987B > 0");
  }
  /**
   * ★★ 自动格宽（T338）：`cellSize ≈ 2 × 全场最大 range`。
   *
   * 为什么是这个值 —— 一次解算的候选扫描量是
   *   `(覆盖格数) × (每格占用) ≈ (2r_q / cellSize + 1)² × (cellSize / 间距)²·n`
   * 其中 `r_q = 自身 range + 最大 range ≤ 2R`。格宽远大于实体尺寸时，"每格占用"
   * 按平方涨；远小于时，"覆盖格数"按平方涨。实测（2000 体 / 间距 0.5 / R=0.3）：
   * `cellSize=4`（默认值）**13.8ms** → `cellSize=1.6` 7.4ms → `1.0` 6.7ms → `0.7` **6.3ms**。
   * 最优点正好落在 `2R = 0.6` 附近。这是**成本模型**，不是"把场景调快"。
   *
   * 为什么只在**跨档**时才重建（而不是每次 add 都试）：
   *   重建是 O(n)。若按半径从小到大的顺序加载，每次 add 都想缩格 ⇒ 退化成 O(n²)。
   *   所以只有当新尺寸与当前尺寸相差 ≥ 2 倍时才重建 —— 每次重建都至少让尺寸减半/翻倍，
   *   一次加载里最多重建 O(log) 次。
   */
  resizeCellsIfNeeded() {
    if (!this.autoCell) return;
    const want = Math.min(AUTO_CELL_MAX, Math.max(AUTO_CELL_MIN, 2 * this.maxRange));
    if (this.cells.size > 0) {
      const ratio = want / this.cellSize;
      if (ratio < 2 && ratio > 0.5) return;
    }
    this.cellSize = want;
    this.cells.clear();
    this.cellOfBody.clear();
    for (const [id] of this.bodies) {
      const p = this.pos.get(id);
      if (p === void 0) continue;
      const [cx, cz] = this.cellOf(p.x, p.z);
      const k = this.key(cx, cz);
      let list = this.cells.get(k);
      if (list === void 0) {
        list = [];
        this.cells.set(k, list);
      }
      list.push(id);
      this.cellOfBody.set(id, k);
      this._cellMoves++;
    }
  }
  key(cx, cz) {
    return cx + "," + cz;
  }
  cellOf(x, z) {
    return [Math.floor(x / this.cellSize), Math.floor(z / this.cellSize)];
  }
  add(body) {
    if (!(body.radius > 0)) {
      throw new RangeError(`body ${body.nodeId} \u7684\u534A\u5F84\u5FC5\u987B > 0\uFF08\u6536\u5230 ${body.radius}\uFF09`);
    }
    const p = this.pos.get(body.nodeId);
    if (p === void 0) {
      throw new Error(`body ${body.nodeId} \u6CA1\u6709\u4F4D\u7F6E\uFF08PositionAccessor \u8FD4\u56DE undefined\uFF09`);
    }
    this.bodies.set(body.nodeId, body);
    const [cx, cz] = this.cellOf(p.x, p.z);
    const k = this.key(cx, cz);
    let list = this.cells.get(k);
    if (list === void 0) {
      list = [];
      this.cells.set(k, list);
    }
    list.push(body.nodeId);
    this.cellOfBody.set(body.nodeId, k);
    if (!body.isStatic) this.dynamicIds.add(body.nodeId);
    const r = this.rangeOf(body);
    if (r > this.maxRange) {
      this.maxRange = r;
      this.resizeCellsIfNeeded();
    }
  }
  remove(nodeId) {
    const k = this.cellOfBody.get(nodeId);
    const wasMax = this.bodies.get(nodeId) !== void 0 && this.rangeOf(this.bodies.get(nodeId)) >= this.maxRange;
    if (k !== void 0) {
      const list = this.cells.get(k);
      if (list !== void 0) {
        const i = list.indexOf(nodeId);
        if (i >= 0) list.splice(i, 1);
        if (list.length === 0) this.cells.delete(k);
      }
      this.cellOfBody.delete(nodeId);
    }
    this.bodies.delete(nodeId);
    this.dynamicIds.delete(nodeId);
    if (wasMax) {
      this.recomputeMaxRange();
      this.resizeCellsIfNeeded();
    }
  }
  has(nodeId) {
    return this.bodies.has(nodeId);
  }
  /**
   * 重新分格。**移动后必须调用**（由调用方每帧对动态体调一次）。
   * ★ 不做"每帧全量重建"：几千个实体全量重建的分配开销远大于"只更新动过的"。
   *   代价是调用方要记得调 —— 所以 `resolve()` 会顺带校验"位置是否还在原 cell"，
   *   不匹配就自动重分格（**容错但可观测**：`stats().staleCells` 会体现）。
   */
  reindex(nodeId) {
    const b = this.bodies.get(nodeId);
    if (b === void 0) return;
    const p = this.pos.get(nodeId);
    if (p !== void 0) {
      const [ncx, ncz] = this.cellOf(p.x, p.z);
      const nk = this.key(ncx, ncz);
      if (this.cellOfBody.get(nodeId) === nk) return;
    }
    const oldKey = this.findCellOf(nodeId);
    if (oldKey !== void 0) {
      const old = this.cells.get(oldKey);
      if (old !== void 0) {
        const i = old.indexOf(nodeId);
        if (i >= 0) old.splice(i, 1);
        if (old.length === 0) this.cells.delete(oldKey);
      }
      this.cellOfBody.delete(nodeId);
    }
    if (p === void 0) return;
    const [cx, cz] = this.cellOf(p.x, p.z);
    const k = this.key(cx, cz);
    let list = this.cells.get(k);
    if (list === void 0) {
      list = [];
      this.cells.set(k, list);
    }
    list.push(nodeId);
    this.cellOfBody.set(nodeId, k);
    this._cellMoves++;
  }
  /**
   * 这个体现在在哪个格键里。
   *
   * ★ 快路径是 `cellOfBody`（O(1)）。慢路径（遍历所有格）是**兜底**：
   *   表里没有它时（例如有人绕开 `add` 手工往 `cells` 里塞过东西）仍然能找到，
   *   而且会被 `cellScans` 如实计入 —— 否则"索引没建好"会表现成"偶尔慢一下"，
   *   没人会去查。慢路径被**频繁走到**就说明索引出了问题。
   */
  findCellOf(nodeId) {
    const fast = this.cellOfBody.get(nodeId);
    if (fast !== void 0) return fast;
    for (const [key, list] of this.cells) {
      this._cellScans++;
      if (list.includes(nodeId)) return key;
    }
    return void 0;
  }
  rangeOf(b) {
    if (b.halfExtents !== void 0) {
      return Math.max(b.halfExtents.x, b.halfExtents.z);
    }
    return b.radius;
  }
  query(x, z, r) {
    this._queries++;
    if (!(r >= 0)) return [];
    const scanR = r + this.maxRadiusNearby();
    const minCx = Math.floor((x - scanR) / this.cellSize);
    const maxCx = Math.floor((x + scanR) / this.cellSize);
    const minCz = Math.floor((z - scanR) / this.cellSize);
    const maxCz = Math.floor((z + scanR) / this.cellSize);
    const out = [];
    const seen = /* @__PURE__ */ new Set();
    for (let cx = minCx; cx <= maxCx; cx++) {
      for (let cz = minCz; cz <= maxCz; cz++) {
        const list = this.cells.get(this.key(cx, cz));
        if (list === void 0) continue;
        for (const id of list) {
          this._candidateScans++;
          if (seen.has(id)) continue;
          seen.add(id);
          const p = this.pos.get(id);
          if (p === void 0) continue;
          const dx = p.x - x;
          const dz = p.z - z;
          const b = this.bodies.get(id);
          const reach = r + (b === void 0 ? 0 : this.rangeOf(b));
          if (dx * dx + dz * dz <= reach * reach + EPS) out.push(id);
        }
      }
    }
    out.sort((a, b) => a - b);
    return out;
  }
  /**
   * `query` 的饥荒同签名别名 —— **同一份实现**，不是转发到另一套逻辑。
   *
   * 判据钉的是"两个名字返回完全相同的数组"，不是"看起来一样"：
   * 一旦有人为了"内容层兼容"另写一遍查询，那条判据立刻红。
   */
  findEntities(x, z, r) {
    return this.query(x, z, r);
  }
  /**
   * 解算重叠。对每对 (动态, 其它)，若重叠则把动态体推开。
   *
   * ★ 为什么"逐对独立解算 + 迭代"而不是"一次性求平均位移"：
   *   后者在"三四个实体挤一个角"时会出现互相抵消、抖动。
   *   迭代式（最多 3 轮）在这个规模下更稳，而且实现只有一个循环。
   *
   * ★★ T338：每一对**每轮只处理一次**，动态-动态各让一半。
   *   原来两侧都会看到对方、各自按**全部**重叠量推 —— 于是同一对被推了两遍
   *   （总位移 2 倍，下一轮又推回来，正是密集场景抖个不停的一半原因）。
   *   两个后果都实测过：
   *   ① 工作量翻倍：密集布局 9154 次推动/步，其中一半是重复的；
   *   ② **结果带有 id 偏差**：先被遍历到的那个体不推、后来的那个被推全程，
   *      所以"挤在一起时总是同一只怪被弹开"，而判据只看距离，看不出来。
   *   现在：`otherId < id` 的动态对由**先遍历到的那一侧**处理（它已经在上一轮/本轮
   *   推过自己这一半），另外半程由对面承担 —— 总位移与原来相同（`overlap + skin`），
   *   但每对每轮只算一次，且两侧对称。
   */
  resolve() {
    let moved = 0;
    for (let iter = 0; iter < this.maxIterations; iter++) {
      let movedThis = 0;
      for (const id of this.dynamicIds) {
        this._bodyScans++;
        const b = this.bodies.get(id);
        if (b === void 0) continue;
        const p = this.pos.get(id);
        if (p === void 0) continue;
        const near = this.query(p.x, p.z, this.rangeOf(b));
        for (const otherId of near) {
          if (otherId === id) continue;
          this._pairChecks++;
          const ob = this.bodies.get(otherId);
          if (ob === void 0) continue;
          if (ob.isStatic !== true && otherId < id) continue;
          const op = this.pos.get(otherId);
          if (op === void 0) continue;
          const dx = p.x - op.x;
          const dz = p.z - op.z;
          const distSq = dx * dx + dz * dz;
          const minDist = this.effectiveRadius(b, dx, dz) + this.effectiveRadius(ob, -dx, -dz);
          if (distSq >= minDist * minDist - EPS) continue;
          let dist = Math.sqrt(distSq);
          let nx;
          let nz;
          if (dist < EPS) {
            nx = 1;
            nz = 0;
            dist = 0;
          } else {
            nx = dx / dist;
            nz = dz / dist;
          }
          const push = minDist - dist + this.skin;
          this.pos.set(id, p.x + nx * push, p.z + nz * push);
          p.x += nx * push;
          p.z += nz * push;
          this._pushes++;
          movedThis++;
          this.reindex(id);
        }
      }
      moved += movedThis;
      if (movedThis === 0) break;
      if (iter === this.maxIterations - 1 && movedThis > 0) {
        this._unresolved++;
        moved += this.settleOnce();
      }
    }
    return moved;
  }
  /**
   * 兜底分离：**一次性**把仍然重叠的对按重叠量分开，不再迭代。
   *
   * ★ 三条性质必须同时成立，缺一条这个兜底就比抖动更糟：
   *   ① **确定性**：完全重合时沿 +x 分（不给随机方向）—— 否则同种子同操作的两个世界
   *      会跑出不同位置，存档比对与回放全部失效；
   *   ② **静态体不动**：静态体是"墙"，被兜底推动等于物理规则在最后一帧变了；
   *   ③ **每对只处理一次**：用 `id < otherId` 过滤，否则同一对会被推两遍（双倍位移）。
   *
   * 它**不保证**一次分开（三角堆叠仍然需要多帧），但保证"每帧都在往分开的方向走"，
   * 而不是在两个位置之间来回。重叠是否真的消掉仍由调用方看 `unresolved` 与实测决定。
   */
  settleOnce() {
    let moved = 0;
    for (const id of this.dynamicIds) {
      const b = this.bodies.get(id);
      if (b === void 0) continue;
      const p = this.pos.get(id);
      if (p === void 0) continue;
      const near = this.query(p.x, p.z, this.rangeOf(b));
      for (const otherId of near) {
        if (otherId === id) continue;
        const ob = this.bodies.get(otherId);
        if (ob === void 0) continue;
        if (ob.isStatic !== true && otherId < id) continue;
        const op = this.pos.get(otherId);
        if (op === void 0) continue;
        const dx = p.x - op.x;
        const dz = p.z - op.z;
        const distSq = dx * dx + dz * dz;
        const minDist = this.effectiveRadius(b, dx, dz) + this.effectiveRadius(ob, -dx, -dz);
        if (distSq >= minDist * minDist - EPS) continue;
        let dist = Math.sqrt(distSq);
        let nx = 1;
        let nz = 0;
        if (dist >= EPS) {
          nx = dx / dist;
          nz = dz / dist;
        } else {
          dist = 0;
        }
        const overlap = minDist - dist + this.skin;
        const bStatic = b.isStatic === true;
        const oStatic = ob.isStatic === true;
        if (bStatic && oStatic) continue;
        if (oStatic) this._settleStaticPushes++;
        const shareSelf = bStatic ? 0 : oStatic ? 1 : 0.5;
        const shareOther = oStatic ? 0 : bStatic ? 1 : 0.5;
        if (shareSelf > 0) {
          this.pos.set(id, p.x + nx * overlap * shareSelf, p.z + nz * overlap * shareSelf);
          p.x += nx * overlap * shareSelf;
          p.z += nz * overlap * shareSelf;
        }
        if (shareOther > 0) {
          this.pos.set(otherId, op.x - nx * overlap * shareOther, op.z - nz * overlap * shareOther);
          op.x -= nx * overlap * shareOther;
          op.z -= nz * overlap * shareOther;
        }
        this._pushes++;
        moved++;
      }
    }
    if (moved > 0) {
      this._settlePasses++;
      for (const id of this.dynamicIds) this.reindex(id);
    }
    return moved;
  }
  /** AABB 用"沿方向上的投影半径"，圆形直接用半径。 */
  effectiveRadius(b, dx, dz) {
    if (b.halfExtents === void 0) return b.radius;
    const l = Math.sqrt(dx * dx + dz * dz);
    if (l < EPS) return Math.max(b.halfExtents.x, b.halfExtents.z);
    return Math.abs(dx / l * b.halfExtents.x) + Math.abs(dz / l * b.halfExtents.z);
  }
  /**
   * O(1)：直接读缓存。
   *
   * ★★ 这里曾经是 `for (const b of this.bodies.values())` —— 也就是**注释写着 O(1)，
   *   代码是 O(n)**，而且被 `resolve()` 的内层循环每个体每次迭代各调一次（O(n²·迭代)）。
   *   缓存 `maxRange` 当时就已经在维护了（add / remove / clear 三处都更新），
   *   只是**没有任何地方读它**。批47 引入 `maxRangeScans` 计数后立刻显形：
   *   一次 2000 体的解算扫了 6000 个 body 去算一个从没变过的数。
   */
  maxRadiusNearby() {
    return this.maxRange;
  }
  /**
   * **唯一的**全量扫描入口（自带计数）。
   *
   * ★ 为什么要有这个"唯一入口"：`maxRangeScans` 只有在这里加，才可能在
   *   "有人把缓存换回扫描"时报警。如果扫描能绕过它，计数就是摆设 ——
   *   而摆设比没有更坏：它会让人以为"扫没扫"这件事已经被守住了。
   */
  scanMaxRange() {
    let m = 0;
    for (const b of this.bodies.values()) {
      this._maxRangeScans++;
      const r = this.rangeOf(b);
      if (r > m) m = r;
    }
    return m;
  }
  recomputeMaxRange() {
    this.maxRange = this.scanMaxRange();
  }
  stats() {
    return {
      bodies: this.bodies.size,
      cells: this.cells.size,
      queries: this._queries,
      pushes: this._pushes,
      unresolved: this._unresolved,
      bodyScans: this._bodyScans,
      maxRangeScans: this._maxRangeScans,
      cellScans: this._cellScans,
      settlePasses: this._settlePasses,
      settleStaticPushes: this._settleStaticPushes,
      cellMoves: this._cellMoves,
      pairChecks: this._pairChecks,
      candidateScans: this._candidateScans
    };
  }
  clear() {
    this.bodies.clear();
    this.cells.clear();
    this.cellOfBody.clear();
    this.dynamicIds.clear();
    this.maxRange = 0;
    this._queries = 0;
    this._pushes = 0;
    this._unresolved = 0;
    this._bodyScans = 0;
    this._maxRangeScans = 0;
    this._cellScans = 0;
    this._settlePasses = 0;
    this._settleStaticPushes = 0;
    this._cellMoves = 0;
    this._pairChecks = 0;
    this._candidateScans = 0;
  }
};
function makeSceneAccessor(lookup) {
  return {
    get(nodeId) {
      const n = lookup(nodeId);
      if (n === void 0) return void 0;
      const p = n.worldPosition();
      return { x: p.x, z: p.y };
    },
    set(nodeId, x, z) {
      const n = lookup(nodeId);
      if (n === void 0) return;
      n.setLocalPosition(x, z);
    }
  };
}

// src/extensions/physics/world-step-module.ts
function createWorldModule(physics2, hooks = {}) {
  let off = null;
  return {
    id: "game.world",
    init(ctx) {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        physics2.resolve();
        hooks.onStep?.(tick, dt);
        hooks.onTick?.(tick);
      });
    },
    stop() {
      off?.();
      off = null;
    },
    describe() {
      return `\u4E16\u754C\uFF1A${physics2.stats().bodies} \u4E2A\u7269\u7406\u4F53`;
    }
  };
}

// src/foundation/canonical.ts
var CANON_NOT_INTEGER = "CANON.NOT_INTEGER";
var CANON_NOT_FINITE = "CANON.NOT_FINITE";
var CANON_TOO_LARGE = "CANON.TOO_LARGE";
var CANON_NULL = "CANON.NULL";
var CANON_UNSUPPORTED = "CANON.UNSUPPORTED";
function bad(code, path, extra) {
  return err({
    code,
    message: `${path} ${extra} \u2014\u2014 \u5185\u5BB9\u6307\u7EB9\u8981\u6C42"\u540C\u503C\u540C\u4E32"\uFF0C\u8FD9\u7C7B\u503C\u6CA1\u6CD5\u4FDD\u8BC1`,
    detail: { path }
  });
}
function canonicalize(value) {
  return canon(value, "$");
}
function canon(value, path) {
  if (value === null) {
    return bad(CANON_NULL, path, "\u662F null\uFF08\u7F3A\u5B57\u6BB5\u5C31\u522B\u5199\u8FD9\u4E2A\u952E\uFF0C\u4E0D\u8981\u5199 null\uFF09");
  }
  if (value === void 0) {
    return bad(CANON_UNSUPPORTED, path, "\u662F undefined\uFF08JSON \u4F1A\u628A\u5B83\u9759\u9ED8\u4E22\u6389\uFF0C\u6570\u7EC4\u91CC\u8FD8\u4F1A\u53D8 null\uFF09");
  }
  switch (typeof value) {
    case "string":
      return ok(JSON.stringify(value));
    case "boolean":
      return ok(value ? "true" : "false");
    case "number": {
      if (!Number.isFinite(value)) {
        return bad(CANON_NOT_FINITE, path, `\u662F ${String(value)}`);
      }
      if (!Number.isInteger(value)) {
        return bad(CANON_NOT_INTEGER, path, `\u662F\u5C0F\u6570 ${String(value)}\uFF08\u9700\u8981\u5C0F\u6570\u8BF7\u6539\u7528\u5B9A\u70B9\u6574\u6570\uFF09`);
      }
      if (Math.abs(value) > Number.MAX_SAFE_INTEGER) {
        return bad(CANON_TOO_LARGE, path, `\u662F ${String(value)}\uFF0C\u8D85\u51FA\u5B89\u5168\u6574\u6570\u8303\u56F4\uFF08\u6574\u6570\u5DF2\u4E0D\u7CBE\u786E\uFF09`);
      }
      return ok(String(value));
    }
    case "bigint":
    case "function":
    case "symbol":
      return bad(CANON_UNSUPPORTED, path, `\u662F ${typeof value}`);
    default:
      break;
  }
  if (Array.isArray(value)) {
    const parts2 = [];
    for (let i = 0; i < value.length; i++) {
      const r = canon(value[i], `${path}[${String(i)}]`);
      if (!r.ok) return r;
      parts2.push(r.value);
    }
    return ok(`[${parts2.join(",")}]`);
  }
  const proto = Object.getPrototypeOf(value);
  if (proto !== Object.prototype && proto !== null) {
    const name = proto?.constructor?.name;
    return bad(CANON_UNSUPPORTED, path, `\u4E0D\u662F\u7EAF\u5BF9\u8C61\uFF08\u539F\u578B ${String(name)}\uFF09`);
  }
  const rec = value;
  const keys = Object.keys(rec).sort();
  const parts = [];
  for (const k of keys) {
    const r = canon(rec[k], `${path}.${k}`);
    if (!r.ok) return r;
    parts.push(`${JSON.stringify(k)}:${r.value}`);
  }
  return ok(`{${parts.join(",")}}`);
}
function fingerprintOf(value) {
  const c = canonicalize(value);
  if (!c.ok) return c;
  return ok(hashText(c.value));
}

// src/extensions/worldgen/worldgen.ts
var FIXED_UNITS = 256;
var WORLD_PLAN_SCHEMA = 1;
var BIOMES = {
  ocean: { passable: false, sites: [] },
  cliff: { passable: false, sites: [] },
  beach: { passable: true, sites: ["flint", "grass_tuft"] },
  grass: { passable: true, sites: ["tree", "berry", "grass_tuft"] },
  forest: { passable: true, sites: ["tree", "tree", "berry"] },
  savanna: { passable: true, sites: ["grass_tuft", "rock"] },
  marsh: { passable: true, sites: ["reed", "berry"] },
  rocky: { passable: true, sites: ["rock", "flint"] }
};
function isPassable(kind) {
  return BIOMES[kind].passable;
}
function isBiomeKind(value) {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(BIOMES, value);
}
var WORLD_BAD_PARAMS = "WORLD.BAD_PARAMS";
var NOISE_PERIOD = 8;
function mix32(a) {
  let x = a | 0;
  x = Math.imul(x ^ x >>> 16, 2246822507);
  x = Math.imul(x ^ x >>> 13, 3266489909);
  return (x ^ x >>> 16) >>> 0;
}
function latticeValue(seed, lx, lz, channel) {
  const h = mix32(
    (seed | 0) ^ Math.imul(lx, 668265261) ^ Math.imul(lz, 374761393) ^ Math.imul(channel, 2654435761)
  );
  return h % 1024;
}
function noise2(seed, x, z, channel) {
  const g = NOISE_PERIOD;
  const lx = Math.floor(x / g);
  const lz = Math.floor(z / g);
  const dx = x - lx * g;
  const dz = z - lz * g;
  const a = latticeValue(seed, lx, lz, channel);
  const b = latticeValue(seed, lx + 1, lz, channel);
  const c = latticeValue(seed, lx, lz + 1, channel);
  const d = latticeValue(seed, lx + 1, lz + 1, channel);
  const top = a * (g - dx) + b * dx;
  const bot = c * (g - dx) + d * dx;
  return Math.floor((top * (g - dz) + bot * dz) / (g * g));
}
function pickBiome(elevation, moisture) {
  if (elevation < 280) return "ocean";
  if (elevation < 340) return "beach";
  if (elevation >= 900) return "cliff";
  if (elevation >= 780) return "rocky";
  if (moisture < 300) return "savanna";
  if (moisture < 700) return "grass";
  if (moisture < 850) return "forest";
  return "marsh";
}
function cellSeed(seed, cellIndex) {
  return mix32((seed | 0) ^ Math.imul(cellIndex + 1, 2654435761));
}
var NEIGHBORS = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1]
];
function findComponents(width, height, kinds) {
  const total = width * height;
  const regionOf = new Int32Array(total).fill(-1);
  const groups = [];
  const queue = [];
  for (let start = 0; start < total; start++) {
    if (regionOf[start] !== -1) continue;
    if (!isPassable(kinds[start])) continue;
    const id = groups.length;
    const group = [];
    regionOf[start] = id;
    queue.length = 0;
    queue.push(start);
    for (let head = 0; head < queue.length; head++) {
      const cur = queue[head];
      group.push(cur);
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [ox, oz] of NEIGHBORS) {
        const nx = cx + ox;
        const nz = cz + oz;
        if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
        const ni = nz * width + nx;
        if (regionOf[ni] !== -1) continue;
        if (!isPassable(kinds[ni])) continue;
        regionOf[ni] = id;
        queue.push(ni);
      }
    }
    group.sort((p, q) => p - q);
    groups.push(group);
  }
  return { regionOf, groups };
}
function lineCells(width, x0, z0, x1, z1) {
  const out = [];
  const dx = Math.abs(x1 - x0);
  const dz = Math.abs(z1 - z0);
  const sx = x0 < x1 ? 1 : -1;
  const sz = z0 < z1 ? 1 : -1;
  let e = dx - dz;
  let x = x0;
  let z = z0;
  for (; ; ) {
    out.push(z * width + x);
    if (x === x1 && z === z1) break;
    const e2 = 2 * e;
    if (e2 > -dz) {
      e -= dz;
      x += sx;
    }
    if (e2 < dx) {
      e += dx;
      z += sz;
    }
  }
  return out;
}
function repairConnectivity(width, height, kinds, bridges) {
  let carved = 0;
  let rounds = 0;
  for (let round = 0; round < 4; round++) {
    const { groups } = findComponents(width, height, kinds);
    if (groups.length <= 1) break;
    rounds++;
    let mainIdx = 0;
    for (let i = 1; i < groups.length; i++) {
      if (groups[i].length > groups[mainIdx].length) mainIdx = i;
    }
    const main2 = groups[mainIdx];
    let carvedThisRound = 0;
    for (let gi = 0; gi < groups.length; gi++) {
      if (gi === mainIdx) continue;
      const group = groups[gi];
      const source = group[0];
      const sx = source % width;
      const sz = (source - sx) / width;
      let best = -1;
      let bestD = Number.POSITIVE_INFINITY;
      for (const target of main2) {
        const tx2 = target % width;
        const tz2 = (target - tx2) / width;
        const d = Math.abs(tx2 - sx) + Math.abs(tz2 - sz);
        if (d < bestD) {
          bestD = d;
          best = target;
        }
      }
      if (best < 0) continue;
      const tx = best % width;
      const tz = (best - tx) / width;
      let carvedHere = 0;
      for (const cell of lineCells(width, sx, sz, tx, tz)) {
        if (isPassable(kinds[cell])) continue;
        kinds[cell] = "beach";
        carvedHere++;
      }
      if (carvedHere > 0) {
        bridges.push({ fromCell: source, toCell: best });
        carvedThisRound += carvedHere;
      }
    }
    carved += carvedThisRound;
    if (carvedThisRound === 0) break;
  }
  return { carved, rounds };
}
function generateWorld(params) {
  const { seed, width, height } = params;
  if (!Number.isInteger(seed)) {
    return err({ code: WORLD_BAD_PARAMS, message: `seed \u5FC5\u987B\u662F\u6574\u6570\uFF0C\u5F97\u5230 ${String(seed)}` });
  }
  if (!Number.isInteger(width) || width < 8 || width > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `width \u5FC5\u987B\u662F 8..128 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(width)}` });
  }
  if (!Number.isInteger(height) || height < 8 || height > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `height \u5FC5\u987B\u662F 8..128 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(height)}` });
  }
  const maxSites = params.maxSitesPerCell ?? 2;
  if (!Number.isInteger(maxSites) || maxSites < 0 || maxSites > 8) {
    return err({ code: WORLD_BAD_PARAMS, message: `maxSitesPerCell \u5FC5\u987B\u662F 0..8 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(maxSites)}` });
  }
  const total = width * height;
  const kinds = new Array(total);
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      const isBorder = x === 0 || z === 0 || x === width - 1 || z === height - 1;
      if (isBorder) {
        kinds[z * width + x] = "ocean";
        continue;
      }
      const elevation = noise2(seed, x, z, 1);
      const moisture = noise2(seed, x, z, 2);
      kinds[z * width + x] = pickBiome(elevation, moisture);
    }
  }
  const bridges = [];
  if (params.repair !== false) {
    repairConnectivity(width, height, kinds, bridges);
  }
  const sites = [];
  for (let cell = 0; cell < total; cell++) {
    const kind = kinds[cell];
    const def = BIOMES[kind];
    if (!def.passable || def.sites.length === 0 || maxSites === 0) continue;
    const rng = new XorShift128(cellSeed(seed, cell));
    const n = rng.int(1, maxSites + 1);
    const cx = cell % width;
    const cz = (cell - cx) / width;
    for (let k = 0; k < n; k++) {
      const siteKind = rng.pick(def.sites);
      if (siteKind === void 0) continue;
      sites.push({
        id: cell * maxSites + k,
        kind: siteKind,
        x: cx * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        z: cz * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        cell
      });
    }
  }
  const partial = {
    schema: WORLD_PLAN_SCHEMA,
    seed,
    width,
    height,
    kinds,
    sites,
    bridges
  };
  const fp = fingerprintOf(partial);
  if (!fp.ok) return fp;
  return ok({
    seed,
    width,
    height,
    kinds,
    sites,
    bridges,
    fingerprint: fp.value
  });
}
function planDigest(plan) {
  return fingerprintOf({
    schema: WORLD_PLAN_SCHEMA,
    seed: plan.seed,
    width: plan.width,
    height: plan.height,
    kinds: plan.kinds,
    sites: plan.sites,
    bridges: plan.bridges
  });
}
var WORLD_NO_SPAWN = "WORLD.NO_SPAWN";
function pickSpawn(plan) {
  const { width, height, kinds } = plan;
  const total = width * height;
  const { regionOf, groups } = findComponents(width, height, kinds);
  let mainIdx = -1;
  let largest = 0;
  for (let i = 0; i < groups.length; i++) {
    const n = groups[i].length;
    if (n > largest) {
      largest = n;
      mainIdx = i;
    }
  }
  if (mainIdx < 0) {
    return err({ code: WORLD_NO_SPAWN, message: "\u6574\u5F20\u56FE\u6CA1\u6709\u53EF\u901A\u884C\u7684\u9646\u5730\uFF08\u5168\u662F\u6D77/\u60AC\u5D16\uFF09\uFF0C\u65E0\u6CD5\u9009\u51FA\u751F\u70B9" });
  }
  const dist = new Int32Array(total).fill(-1);
  const queue = [];
  for (let i = 0; i < total; i++) {
    if (!isPassable(kinds[i])) {
      dist[i] = 0;
      queue.push(i);
    }
  }
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      if (x !== 0 && z !== 0 && x !== width - 1 && z !== height - 1) continue;
      const i = z * width + x;
      if (dist[i] !== -1) continue;
      dist[i] = 1;
      queue.push(i);
    }
  }
  for (let head = 0; head < queue.length; head++) {
    const cur = queue[head];
    const cx = cur % width;
    const cz = (cur - cx) / width;
    const d = dist[cur];
    for (const [ox, oz] of NEIGHBORS) {
      const nx = cx + ox;
      const nz = cz + oz;
      if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
      const ni = nz * width + nx;
      if (dist[ni] !== -1) continue;
      dist[ni] = d + 1;
      queue.push(ni);
    }
  }
  let best = -1;
  let bestDist = -1;
  for (let i = 0; i < total; i++) {
    if (regionOf[i] !== mainIdx) continue;
    const d = dist[i];
    if (d > bestDist) {
      bestDist = d;
      best = i;
    }
  }
  if (best < 0) {
    return err({ code: WORLD_NO_SPAWN, message: `\u4E3B\u5206\u91CF\uFF08${largest} \u683C\uFF09\u91CC\u6CA1\u6709\u53EF\u901A\u884C\u683C` });
  }
  const bx = best % width;
  const bz = (best - bx) / width;
  return ok({
    cell: best,
    x: bx * FIXED_UNITS + FIXED_UNITS / 2,
    z: bz * FIXED_UNITS + FIXED_UNITS / 2,
    clearance: bestDist
  });
}

// src/extensions/worldgen/assemble.ts
var WORLD_BAD_PLAN = "WORLD.BAD_PLAN";
var WORLD_SCENE_NOT_EMPTY = "WORLD.SCENE_NOT_EMPTY";
var WORLD_COMPONENTS_UNREGISTERED = "WORLD.COMPONENTS_UNREGISTERED";
var TERRAIN_TYPE = "world.terrain";
var SITE_TYPE = "world.site";
var TERRAIN_SCHEMA = {
  type: TERRAIN_TYPE,
  fields: {
    kind: FieldType.String,
    /** 矩形左上角格子坐标与尺寸 —— 存的是**格子**，不是世界单位（不引入浮点）。 */
    cx: FieldType.Int,
    cz: FieldType.Int,
    w: FieldType.Int,
    h: FieldType.Int,
    /** 冗余但必要：`passable` 是"能不能走"的**运行时事实**，不只由 kind 推。 */
    passable: FieldType.Bool
  }
};
var SITE_SCHEMA = {
  type: SITE_TYPE,
  fields: {
    siteId: FieldType.Int,
    kind: FieldType.String,
    cell: FieldType.Int
  }
};
var TerrainArea = class extends Component {
  schema = TERRAIN_SCHEMA;
  kind = "ocean";
  cx = 0;
  cz = 0;
  w = 0;
  h = 0;
  passable = false;
};
var SiteMarker = class extends Component {
  schema = SITE_SCHEMA;
  siteId = 0;
  kind = "tree";
  cell = 0;
};
function registerWorldComponents(registry2) {
  if (!registry2.has(TERRAIN_TYPE)) registry2.register(TERRAIN_SCHEMA, () => new TerrainArea());
  if (!registry2.has(SITE_TYPE)) registry2.register(SITE_SCHEMA, () => new SiteMarker());
}
function mergeTerrain(width, height, kinds) {
  const visited = new Uint8Array(width * height);
  const rects = [];
  for (let cz = 0; cz < height; cz++) {
    for (let cx = 0; cx < width; cx++) {
      const start = cz * width + cx;
      if (visited[start] === 1) continue;
      const kind = kinds[start];
      let w = 1;
      while (cx + w < width) {
        const i = start + w;
        if (visited[i] === 1 || kinds[i] !== kind) break;
        w++;
      }
      let h = 1;
      while (cz + h < height) {
        let sameRow = true;
        for (let dx = 0; dx < w; dx++) {
          const i = (cz + h) * width + cx + dx;
          if (visited[i] === 1 || kinds[i] !== kind) {
            sameRow = false;
            break;
          }
        }
        if (!sameRow) break;
        h++;
      }
      for (let dz = 0; dz < h; dz++) {
        for (let dx = 0; dx < w; dx++) visited[(cz + dz) * width + cx + dx] = 1;
      }
      rects.push({ cx, cz, w, h, kind });
    }
  }
  return rects;
}
function assembleWorld(plan, scene) {
  const { width, height, kinds } = plan;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
    return err({ code: WORLD_BAD_PLAN, message: `\u5C3A\u5BF8\u4E0D\u5408\u6CD5\uFF1A${String(width)}x${String(height)}` });
  }
  if (kinds.length !== width * height) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `kinds \u957F\u5EA6 ${kinds.length} \u4E0E\u5C3A\u5BF8 ${width}x${height}\uFF08${width * height}\uFF09\u4E0D\u7B26`
    });
  }
  for (let i = 0; i < kinds.length; i++) {
    if (!isBiomeKind(kinds[i])) {
      return err({
        code: WORLD_BAD_PLAN,
        message: `\u7B2C ${i} \u683C\u7684\u7FA4\u7CFB\u540D\u672A\u77E5\uFF1A${String(kinds[i])}\uFF08\u53EF\u80FD\u662F\u65E7 schema \u6216\u624B\u6539\u7684\u8BA1\u5212\uFF09`
      });
    }
  }
  const digest = planDigest(plan);
  if (!digest.ok) return digest;
  if (digest.value !== plan.fingerprint) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `\u8BA1\u5212\u6307\u7EB9\u4E0E\u5185\u5BB9\u4E0D\u7B26\uFF08\u8BA1\u5212\u91CC\u5B58 ${plan.fingerprint}\uFF0C\u91CD\u7B97\u5F97 ${digest.value}\uFF09\u2014\u2014 \u5185\u5BB9\u88AB\u6539\u8FC7\u6216\u6765\u81EA\u65E7 schema`
    });
  }
  if (scene.stats().nodes !== 1) {
    return err({
      code: WORLD_SCENE_NOT_EMPTY,
      message: `\u76EE\u6807\u573A\u666F\u5DF2\u6709 ${scene.stats().nodes - 1} \u4E2A\u8282\u70B9\uFF08\u88C5\u914D\u8981\u6C42\u7A7A\u573A\u666F\uFF0C\u5148 scene.clear()\uFF09`
    });
  }
  const missing = [TERRAIN_TYPE, SITE_TYPE].filter((t) => !scene.components.has(t));
  if (missing.length > 0) {
    return err({
      code: WORLD_COMPONENTS_UNREGISTERED,
      message: `\u7EC4\u4EF6\u7C7B\u578B\u672A\u6CE8\u518C\uFF1A${missing.join(", ")} \u2014\u2014 \u5148 registerWorldComponents(scene.components)`
    });
  }
  const rects = mergeTerrain(width, height, kinds);
  const terrainRoot = scene.spawnImmediate("terrain");
  const siteRoot = scene.spawnImmediate("sites");
  for (const r of rects) {
    const node = scene.spawnImmediate(`terrain/${r.kind}`, terrainRoot.id);
    node.setLocalPosition(r.cx, r.cz);
    const made = scene.attach(node.id, () => new TerrainArea());
    if (!made.ok) return made;
    made.value.kind = r.kind;
    made.value.cx = r.cx;
    made.value.cz = r.cz;
    made.value.w = r.w;
    made.value.h = r.h;
    made.value.passable = isPassable(r.kind);
  }
  for (const s of plan.sites) {
    const node = scene.spawnImmediate(`site/${s.kind}`, siteRoot.id);
    node.setLocalPosition(s.x / FIXED_UNITS, s.z / FIXED_UNITS);
    const made = scene.attach(node.id, () => new SiteMarker());
    if (!made.ok) return made;
    made.value.siteId = s.id;
    made.value.kind = s.kind;
    made.value.cell = s.cell;
  }
  scene.flush();
  return ok({
    terrainNodes: rects.length,
    siteNodes: plan.sites.length,
    sceneNodes: scene.stats().nodes,
    cells: width * height,
    rects: rects.length,
    fingerprint: plan.fingerprint
  });
}

// src/extensions/worldgen/spawn.ts
var PLAYER_TYPE = "world.player";
var PLAYER_FRAME = "player";
var SPAWN_NO_SPRITE_COMPONENT = "SPAWN.NO_SPRITE_COMPONENT";
var SPAWN_ALREADY_SPAWNED = "SPAWN.ALREADY_SPAWNED";
var PLAYER_SCHEMA = {
  type: PLAYER_TYPE,
  fields: {
    /** 出生格（升序下标）。玩家走开之后这个字段仍然是"他是从哪开始的"。 */
    cell: FieldType.Int
  }
};
var PlayerSpawn = class extends Component {
  schema = PLAYER_SCHEMA;
  cell = 0;
};
function registerPlayerComponent(registry2) {
  if (!registry2.has(PLAYER_TYPE)) registry2.register(PLAYER_SCHEMA, () => new PlayerSpawn());
}
function spawnPlayer(scene, plan) {
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        SPAWN_NO_SPRITE_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B render.sprite \u672A\u6CE8\u518C \u2014\u2014 \u73A9\u5BB6\u4F1A\u6CA1\u6709\u8EAB\u4F53\uFF08\u6E32\u67D3\u6A21\u5757\u542F\u52A8\u65F6\u4F1A\u6CE8\u518C\uFF09"
      )
    );
  }
  if (!scene.components.has(PLAYER_TYPE)) {
    return err(
      engineError(SPAWN_NO_SPRITE_COMPONENT, "\u7EC4\u4EF6\u7C7B\u578B world.player \u672A\u6CE8\u518C \u2014\u2014 \u5148 registerPlayerComponent(...)")
    );
  }
  const existing = [...scene.componentsOf(PLAYER_TYPE)];
  if (existing.length > 0) {
    return err(
      engineError(SPAWN_ALREADY_SPAWNED, "\u573A\u666F\u91CC\u5DF2\u7ECF\u6709\u73A9\u5BB6\u4E86 \u2014\u2014 \u91CD\u590D\u51FA\u751F\u4F1A\u8BA9\u4E24\u4E2A\u63A7\u5236\u5668\u62A2\u540C\u4E00\u4E2A\u4F4D\u7F6E")
    );
  }
  const pick = pickSpawn(plan);
  if (!pick.ok) return pick;
  const sp = pick.value;
  const made = scene.spawnAt("player", sp.x / FIXED_UNITS, sp.z / FIXED_UNITS);
  if (!made.ok) return made;
  const nodeId = made.value.id;
  scene.attach(nodeId, () => {
    const s = new Sprite();
    s.frame = PLAYER_FRAME;
    s.width = 1;
    s.height = 1;
    s.pivotY = 0;
    return s;
  });
  scene.attach(nodeId, () => {
    const marker = new PlayerSpawn();
    marker.cell = sp.cell;
    return marker;
  });
  scene.flush();
  return ok({ nodeId, cell: sp.cell, x: sp.x, z: sp.z });
}

// src/extensions/worldgen/task-module.ts
var RESOURCE_TYPE = "world.resource";
var RESOURCE_SCHEMA = {
  type: RESOURCE_TYPE,
  fields: {
    cell: FieldType.Int,
    kind: FieldType.String,
    /** 哪一次触发刷出来的（= `TaskFire.tick`）。诊断用，也用来验"重复触发没被合并"。 */
    bornTick: FieldType.Int
  }
};

// src/extensions/render/world-visuals.ts
var VISUAL_MISSING_FRAME = "VISUAL.MISSING_FRAME";
var VISUAL_NO_SPRITE_COMPONENT = "VISUAL.NO_SPRITE_COMPONENT";
var UNMAPPED_LABEL = "\uFF08\u672A\u6620\u5C04\u7684\u79CD\u7C7B\uFF09";
var SITE_FRAMES = {
  tree: "tree",
  rock: "rock",
  berry: "berry",
  flint: "rock",
  grass_tuft: "berry",
  reed: "berry"
};
var TERRAIN_FRAME = "terrain";
var TERRAIN_TILE_PAGE = "terrain.tile";
var BIOME_TINT = {
  ocean: [0.16, 0.32, 0.55],
  beach: [0.85, 0.78, 0.55],
  grass: [0.42, 0.62, 0.3],
  forest: [0.24, 0.46, 0.26],
  rocky: [0.52, 0.5, 0.48],
  cliff: [0.38, 0.36, 0.4],
  savanna: [0.72, 0.66, 0.36],
  marsh: [0.36, 0.44, 0.38]
};
function hasSprite(s, nodeId) {
  const node = s.find(nodeId);
  return node?.get(SPRITE_TYPE) !== void 0;
}
function attachWorldVisuals(scene, availableFrames) {
  const plans = [];
  for (const area of scene.componentsOf(TERRAIN_TYPE)) {
    if (area.node === null) continue;
    const tint = BIOME_TINT[area.kind];
    plans.push({
      nodeId: area.node.id,
      frame: TERRAIN_FRAME,
      atlasId: TERRAIN_TILE_PAGE,
      kind: `terrain:${area.kind}`,
      width: area.w,
      height: area.h,
      // ★ 背景层：地面永远先画、永远被实体盖住。地形的 z 是矩形左上角的格子坐标，
      //   与实体（格子中心）必然交错 —— 不分层会被一块地形盖住站在它上面的角色，
      //   而且 draw 会被 z 序打散成几十段（T288 之后实测 29 段）。
      layer: 0,
      // ★ T288：按格平铺 —— 一块 w×h 的地形铺 w×h 张噪点，颗粒不随块变大。
      //   必须是整数：0.5 次平铺在 GPU 上就是"半张被裁掉的贴图"，
      //   而矩形格数天生是整数（`TerrainArea` 的 w/h 是格子数）。
      tileX: Math.max(1, Math.floor(area.w)),
      tileY: Math.max(1, Math.floor(area.h)),
      // ★ (0,0)：矩形左上角 = 节点位置。用 0.5 会让整块地形右移半块、上移半块 ——
      //   相邻块之间于是出现缝隙，而"缝隙"在 2.5D 斜视角下看起来像地表裂开了。
      pivotX: 0,
      pivotY: 0,
      r: tint[0],
      g: tint[1],
      b: tint[2]
    });
  }
  for (const m of scene.componentsOf(SITE_TYPE)) {
    if (m.node === null) continue;
    plans.push({
      nodeId: m.node.id,
      frame: SITE_FRAMES[m.kind] ?? null,
      atlasId: "",
      kind: `site:${m.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      // 脚踩地面：2.5D 里精灵的底边贴住它所在的格
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1
    });
  }
  for (const res of scene.componentsOf(RESOURCE_TYPE)) {
    if (res.node === null) continue;
    plans.push({
      nodeId: res.node.id,
      frame: SITE_FRAMES[res.kind] ?? null,
      atlasId: "",
      kind: `resource:${res.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1
    });
  }
  const available = new Set(availableFrames);
  const missing = /* @__PURE__ */ new Map();
  for (const p of plans) {
    if (p.frame !== null && available.has(p.frame)) continue;
    const key = p.frame ?? UNMAPPED_LABEL;
    const set = missing.get(key) ?? /* @__PURE__ */ new Set();
    set.add(p.kind);
    missing.set(key, set);
  }
  if (missing.size > 0) {
    const detail = [...missing.entries()].sort((a, b) => a[0] < b[0] ? -1 : 1).map(([frame, kinds]) => `${frame}\uFF08\u88AB ${[...kinds].sort().join(", ")} \u7528\u5230\uFF09`).join("\uFF1B");
    return err(
      engineError(
        VISUAL_MISSING_FRAME,
        `\u56FE\u96C6\u91CC\u6CA1\u6709\u8FD9\u4E9B\u5E27\uFF1A${detail} \u2014\u2014 \u7F3A\u5E27\u7684\u8D44\u6E90\u4F1A**\u9759\u9ED8\u4E0D\u663E\u793A**\uFF08\u6E32\u67D3\u6A21\u5757\u53EA warn \u4E00\u6B21\uFF09\uFF0C\u6240\u4EE5\u5728\u8FD9\u91CC\u62A5\u9519`
      )
    );
  }
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        VISUAL_NO_SPRITE_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B render.sprite \u672A\u6CE8\u518C \u2014\u2014 \u5148 components.register(...)\uFF08\u6E32\u67D3\u6A21\u5757\u542F\u52A8\u65F6\u4F1A\u6CE8\u518C\uFF09"
      )
    );
  }
  let terrain = 0;
  let sites = 0;
  let resources = 0;
  let skipped = 0;
  const used = /* @__PURE__ */ new Set();
  for (const p of plans) {
    if (hasSprite(scene, p.nodeId)) {
      skipped++;
      continue;
    }
    const frame = p.frame;
    if (frame === null) throw new Error(`world-visuals \u5185\u90E8\u9519\u8BEF\uFF1A${p.kind} \u7684\u5E27\u6620\u5C04\u5728\u68C0\u67E5\u4E4B\u540E\u53D8\u6210\u4E86 null`);
    const made = scene.attach(p.nodeId, () => {
      const sp = new Sprite();
      sp.frame = frame;
      sp.atlasId = p.atlasId;
      sp.tileX = p.tileX;
      sp.tileY = p.tileY;
      sp.layer = p.layer;
      sp.width = p.width;
      sp.height = p.height;
      sp.pivotX = p.pivotX;
      sp.pivotY = p.pivotY;
      sp.r = p.r;
      sp.g = p.g;
      sp.b = p.b;
      return sp;
    });
    if (!made.ok) return made;
    used.add(frame);
    if (p.kind.startsWith("terrain:")) terrain++;
    else if (p.kind.startsWith("site:")) sites++;
    else resources++;
  }
  scene.flush();
  return ok({
    terrain,
    sites,
    resources,
    frames: [...used].sort(),
    skipped
  });
}

// src/extensions/inventory/inventory.ts
var ITEM_TYPE = "game.item";
var INVENTORY_TYPE = "game.inventory";
var ItemStack = class extends Component {
  /** 物品种类（与 `SiteKind` 同名，但不强绑：背包不认识"世界"）。 */
  kind = "";
  count = 0;
  schema = {
    type: ITEM_TYPE,
    fields: { kind: FieldType.String, count: FieldType.Int }
  };
};
var Inventory = class extends Component {
  /** 最多几堆（不是"最多几个"）。到上限再加"新种类"就报 `INVENTORY.FULL`。 */
  maxStacks = 8;
  /**
   * 单堆上限（饥荒默认 40）。**不是**"最多几个"：到顶会自动开新堆（有名额时），
   * 没有名额才报 `INVENTORY.FULL`。
   *
   * ★ 为什么需要它：`maxStacks` 管的是**格子数**，单堆无上限时"1 堆 × 9999"与
   *   "250 堆 × 40"都合法 —— 前者让背包面板一行写不下，后者让 `maxStacks` 形同虚设。
   *   两者都管，才是"几格、每格多少"的完整形状。
   */
  maxStack = 40;
  schema = {
    type: INVENTORY_TYPE,
    fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int }
  };
};
function registerInventoryComponents(registry2) {
  if (!registry2.has(ITEM_TYPE)) registry2.register(ITEM_SCHEMA, () => new ItemStack());
  if (!registry2.has(INVENTORY_TYPE)) registry2.register(INVENTORY_SCHEMA, () => new Inventory());
}
var ITEM_SCHEMA = { type: ITEM_TYPE, fields: { kind: FieldType.String, count: FieldType.Int } };
var INVENTORY_SCHEMA = {
  type: INVENTORY_TYPE,
  fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int }
};

// src/extensions/editor/outline.ts
var DEFAULT_MAX_NODES = 2048;
var DEFAULT_MAX_DEPTH = 32;
function buildOutline(scene, opts = {}) {
  const skip = new Set(opts.skipTypes ?? []);
  const maxDepth = opts.maxDepth ?? DEFAULT_MAX_DEPTH;
  const maxNodes = opts.maxNodes ?? DEFAULT_MAX_NODES;
  let count = 0;
  let truncated = false;
  const walk = (n, depth) => {
    if (count >= maxNodes) {
      truncated = true;
      return null;
    }
    if (depth > 0 && skip.size > 0 && n.components.some((c) => skip.has(c.type))) return null;
    count++;
    const kids = [];
    if (depth < maxDepth) {
      const sorted = [...n.children].sort((a, b) => a.id - b.id);
      for (const k of sorted) {
        const kn = walk(k, depth + 1);
        if (kn !== null) kids.push(kn);
      }
    } else if (n.children.length > 0) {
      truncated = true;
    }
    return { id: n.id, name: n.name, types: n.components.map((c) => c.type), children: kids };
  };
  const root = walk(scene.root, 0) ?? {
    id: scene.root.id,
    name: scene.root.name,
    types: [],
    children: []
  };
  return { root, count, truncated };
}
function flattenOutline(o, depth = 0) {
  const rows = [{ node: o, depth }];
  for (const c of o.children) rows.push(...flattenOutline(c, depth + 1));
  return rows;
}

// src/extensions/editor/selection.ts
var Selection = class {
  set = /* @__PURE__ */ new Set();
  primaryId = null;
  /** 单选（替换整个选中集）。 */
  select(id) {
    this.set.clear();
    this.set.add(id);
    this.primaryId = id;
  }
  /** 加入选中集（不动其它）。 */
  add(id) {
    this.set.add(id);
    this.primaryId = id;
  }
  /** 反选：返回**操作后**是否在选中集里。 */
  toggle(id) {
    if (this.set.has(id)) {
      this.set.delete(id);
      if (this.primaryId === id) this.primaryId = this.lowest();
      return false;
    }
    this.set.add(id);
    this.primaryId = id;
    return true;
  }
  clear() {
    this.set.clear();
    this.primaryId = null;
  }
  has(id) {
    return this.set.has(id);
  }
  get size() {
    return this.set.size;
  }
  get primary() {
    return this.primaryId;
  }
  /** 升序快照（新数组：调用方排序/删除不该改到内部状态）。 */
  ids() {
    return [...this.set].sort((a, b) => a - b);
  }
  /**
   * 清掉已经不在场景里的 id，返回**被清掉的**（调用方据此提示「选中项消失了」）。
   * `isAlive` 由宿主提供（`(id) => scene.find(id) !== undefined`），
   * 这一层不依赖 Scene，于是它也能给「还没装配世界」的编辑器空架子用。
   */
  prune(isAlive) {
    const gone = [];
    for (const id of this.ids()) {
      if (!isAlive(id)) {
        this.set.delete(id);
        gone.push(id);
      }
    }
    if (this.primaryId !== null && !this.set.has(this.primaryId)) this.primaryId = this.lowest();
    return gone;
  }
  snapshot() {
    return { ids: this.ids(), primary: this.primaryId };
  }
  lowest() {
    const s = this.ids();
    return s.length === 0 ? null : s[0];
  }
};
function createSelection() {
  return new Selection();
}

// src/extensions/editor/property-model.ts
var EDIT_BAD_FIELD = "EDIT.BAD_FIELD";
var EDIT_BAD_VALUE = "EDIT.BAD_VALUE";
function controlOf(t) {
  switch (t) {
    case FieldType.Int:
    case FieldType.Float:
    case FieldType.Double:
      return "number";
    case FieldType.Bool:
      return "checkbox";
    case FieldType.String:
      return "text";
    case FieldType.Vec2:
      return "vec2";
    case FieldType.Color:
      return "color";
    case FieldType.Asset:
      return "asset";
    case FieldType.NodeRef:
      return "noderef";
    case FieldType.StringArray:
      return "tags";
    default:
      return "text";
  }
}
function fieldsOf(comp) {
  const bag = comp;
  const out = [];
  for (const [key, type] of Object.entries(comp.schema.fields)) {
    const v = bag[key];
    out.push({ key, type, control: controlOf(type), value: v === void 0 ? zeroValue(type) : v });
  }
  return out;
}
function numberOf(v) {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string") {
    const t = v.trim();
    if (t === "") return null;
    const n = Number(t);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}
function bad2(t, raw, want) {
  return err(
    engineError(EDIT_BAD_VALUE, `\u5B57\u6BB5\u7C7B\u578B ${t} \u8981\u7684\u662F${want}\uFF0C\u6536\u5230 ${describe(raw)}`)
  );
}
function describe(v) {
  if (typeof v === "string") return `\u300C${v}\u300D`;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (v === null) return "null";
  if (Array.isArray(v)) return `\u6570\u7EC4(${String(v.length)})`;
  return typeof v;
}
function coerce(type, raw) {
  switch (type) {
    case FieldType.Int: {
      const n = numberOf(raw);
      if (n === null || !Number.isInteger(n)) return bad2(type, raw, "\u6574\u6570\uFF083.5 \u4E0D\u4F1A\u53D8\u6210 3\uFF09");
      return ok(n);
    }
    case FieldType.Float:
    case FieldType.Double: {
      const n = numberOf(raw);
      if (n === null) return bad2(type, raw, "\u6709\u9650\u6570\u5B57\uFF08NaN / Infinity \u4E0D\u6536\uFF09");
      return ok(n);
    }
    case FieldType.Bool: {
      if (typeof raw === "boolean") return ok(raw);
      if (typeof raw === "string") {
        const t = raw.trim();
        if (t === "true") return ok(true);
        if (t === "false") return ok(false);
      }
      return bad2(type, raw, "true / false");
    }
    case FieldType.String: {
      if (typeof raw === "string") return ok(raw);
      return bad2(type, raw, "\u5B57\u7B26\u4E32");
    }
    case FieldType.Vec2: {
      if (typeof raw === "string") {
        const parts = raw.split(",").map((s) => s.trim());
        if (parts.length !== 2) return bad2(type, raw, "\u300Cx, z\u300D\u4E24\u6BB5");
        const x = numberOf(parts[0]);
        const y = numberOf(parts[1]);
        if (x === null || y === null) return bad2(type, raw, "\u4E24\u4E2A\u6709\u9650\u6570\u5B57");
        return ok({ x, y });
      }
      if (typeof raw === "object" && raw !== null) {
        const o = raw;
        const x = numberOf(o.x);
        const y = numberOf(o.y);
        if (x === null || y === null) return bad2(type, raw, "{x, y} \u4E24\u4E2A\u6709\u9650\u6570\u5B57");
        return ok({ x, y });
      }
      return bad2(type, raw, "\u300Cx, z\u300D\u6216 {x, y}");
    }
    case FieldType.Color: {
      if (typeof raw === "string") {
        const m = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(raw.trim());
        if (m !== null) {
          let h = m[1];
          if (h.length === 3) h = [...h].map((c) => c + c).join("");
          const a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
          return ok({
            r: parseInt(h.slice(0, 2), 16) / 255,
            g: parseInt(h.slice(2, 4), 16) / 255,
            b: parseInt(h.slice(4, 6), 16) / 255,
            a
          });
        }
        return bad2(type, raw, "#rgb / #rrggbb / #rrggbbaa");
      }
      if (typeof raw === "object" && raw !== null) {
        const o = raw;
        const r = numberOf(o.r);
        const g = numberOf(o.g);
        const b = numberOf(o.b);
        const a = o.a === void 0 ? 1 : numberOf(o.a);
        if (r === null || g === null || b === null || a === null) return bad2(type, raw, "{r,g,b,a} \u6570\u5B57");
        return ok({ r, g, b, a });
      }
      return bad2(type, raw, "#rrggbb \u6216 {r,g,b,a}");
    }
    case FieldType.Asset: {
      if (typeof raw === "string") return ok(raw);
      return bad2(type, raw, "\u8D44\u4EA7 id \u5B57\u7B26\u4E32\uFF08GUID\uFF0C\u4E0D\u662F\u6570\u5B57\uFF09");
    }
    case FieldType.NodeRef: {
      if (typeof raw === "string") return ok(raw);
      if (typeof raw === "number" && Number.isInteger(raw)) return ok(String(raw));
      return bad2(type, raw, "\u8282\u70B9 id\uFF08\u5B57\u7B26\u4E32\u6216\u6574\u6570\uFF09");
    }
    case FieldType.StringArray: {
      if (Array.isArray(raw)) {
        const out = [];
        for (const v of raw) {
          if (typeof v !== "string") return bad2(type, raw, "\u5B57\u7B26\u4E32\u6570\u7EC4");
          out.push(v);
        }
        return ok(out);
      }
      if (typeof raw === "string") {
        return ok(
          raw.split(",").map((s) => s.trim()).filter((s) => s.length > 0)
        );
      }
      return bad2(type, raw, "\u5B57\u7B26\u4E32\u6570\u7EC4\u6216\u9017\u53F7\u5206\u9694\u7684\u4E32");
    }
    default:
      return bad2(type, raw, "\u5DF2\u77E5\u7684\u5B57\u6BB5\u7C7B\u578B");
  }
}
function setField(scene, nodeId, type, key, raw) {
  const node = scene.find(nodeId);
  if (node === void 0) return err(engineError(EDIT_BAD_FIELD, `\u8282\u70B9 ${String(nodeId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  const comp = node.components.find((c2) => c2.type === type);
  if (comp === void 0) {
    return err(engineError(EDIT_BAD_FIELD, `\u8282\u70B9 ${String(nodeId)}\uFF08${node.name}\uFF09\u4E0A\u6CA1\u6709\u7EC4\u4EF6\u300C${type}\u300D`));
  }
  const declared = comp.schema.fields[key];
  if (declared === void 0) {
    return err(engineError(EDIT_BAD_FIELD, `\u7EC4\u4EF6\u300C${type}\u300D\u6CA1\u6709\u5B57\u6BB5\u300C${key}\u300D`));
  }
  const c = coerce(declared, raw);
  if (!c.ok) return c;
  const bag = comp;
  const before = bag[key];
  bag[key] = c.value;
  return ok({ before, after: c.value });
}

// src/extensions/editor/pie.ts
var EPS2 = 1e-9;
var MAX_PENDING = 600;
var Pie = class {
  hz;
  maxStepTicks;
  playing = false;
  accTicks = 0;
  pendingTicks = 0;
  tickCount = 0;
  clamped = 0;
  constructor(opts = {}) {
    const hz = opts.hz ?? 30;
    this.hz = hz > 0 ? hz : 30;
    const m = opts.maxStepTicks ?? 4;
    this.maxStepTicks = m >= 1 ? Math.floor(m) : 1;
  }
  get isPlaying() {
    return this.playing;
  }
  play() {
    this.playing = true;
  }
  pause() {
    this.playing = false;
    this.accTicks = 0;
  }
  toggle() {
    if (this.playing) this.pause();
    else this.play();
    return this.playing;
  }
  /** 排队单步（默认 1 tick）。**单步 = 暂停着走**，见 ②。 */
  step(n = 1) {
    const k = Math.max(0, Math.floor(n));
    this.pendingTicks = Math.min(this.pendingTicks + k, MAX_PENDING);
    this.playing = false;
    this.accTicks = 0;
  }
  /**
   * 推进一帧，返回**本次应该跑几个 tick**（0..maxStepTicks）。
   * 约定：宿主必须把这个数字**原样**交给 `scene.step`，否则 `stats().tick` 与场景不同步。
   */
  advance(dtSec) {
    let ticks = 0;
    if (this.pendingTicks > 0) {
      ticks = this.pendingTicks;
      this.pendingTicks = 0;
    } else if (this.playing) {
      const dt = dtSec > 0 ? dtSec : 0;
      this.accTicks += dt * this.hz;
      const due = Math.floor(this.accTicks + EPS2);
      this.accTicks -= due;
      ticks = due;
      if (due > this.maxStepTicks) {
        ticks = this.maxStepTicks;
        this.clamped++;
        this.accTicks = 0;
      }
    } else {
      this.accTicks = 0;
    }
    this.tickCount += ticks;
    return ticks;
  }
  stats() {
    return {
      playing: this.playing,
      tick: this.tickCount,
      pending: this.pendingTicks,
      clampedFrames: this.clamped,
      backlog: this.accTicks
    };
  }
};
function createPie(opts = {}) {
  return new Pie(opts);
}

// src/editor-entry.ts
var WORLD_SEED = 20261025;
var WORLD_W = 26;
var WORLD_H = 18;
var HZ = 30;
var FIXED_DT = 1 / HZ;
function need(id) {
  const el = document.getElementById(id);
  if (el === null) throw new Error(`\u9875\u9762\u7ED3\u6784\u4E0D\u5B8C\u6574\uFF1A\u7F3A #${id}`);
  return el;
}
var canvas = need("cv");
var treeEl = need("tree");
var propsEl = need("props");
var statusEl = need("status");
var errEl = need("err");
var tickEl = need("tick");
var pieInfoEl = need("pieinfo");
var btnPlay = need("btn-play");
var btnPause = need("btn-pause");
var btnStep = need("btn-step");
var btnStep10 = need("btn-step10");
var dpr = Math.min(2, window.devicePixelRatio || 1);
canvas.width = Math.floor((canvas.clientWidth || 640) * dpr);
canvas.height = Math.floor((canvas.clientHeight || 420) * dpr);
var selection = createSelection();
var pie = createPie({ hz: HZ, maxStepTicks: 4 });
var appRef = null;
var heroId = -1;
var booted = false;
var registry = new BackendRegistry();
registerNullBackends(registry);
registry.registerGfx(webgl2Backend, 100);
registry.registerInput(domInputBackend, 100);
registry.registerAudio(webAudioBackend, 100);
var physics = new SpatialHashWorld(
  makeSceneAccessor((id) => {
    const n = appRef?.scene.find(id);
    if (n === void 0) return void 0;
    return {
      id: n.id,
      worldPosition: () => n.worldPosition,
      setLocalPosition: (x, y) => n.setLocalPosition(x, y)
    };
  }),
  { maxIterations: 3 }
);
var renderMod = createRenderModule({
  viewportWidth: canvas.width,
  viewportHeight: canvas.height,
  zoom: 24 * dpr,
  tiltY: 0.62,
  follow: () => {
    if (heroId < 0) return void 0;
    const n = appRef?.scene.find(heroId);
    if (n === void 0) return void 0;
    const p = n.worldPosition;
    return { x: p.x, z: p.y };
  }
});
var worldMod = createWorldModule(physics, {});
var atlasFrames = [...buildProceduralAtlas().frames.keys()];
var planRef = null;
var worldgenMod = {
  id: "editor.worldgen",
  init(ctx) {
    const scene = ctx.services.require(Services.Scene);
    const p = planRef;
    if (p === null || !p.ok) {
      return err(engineError("EDITOR.NO_PLAN", "\u4E16\u754C\u8BA1\u5212\u6CA1\u6709\u751F\u6210\u51FA\u6765"));
    }
    registerWorldComponents(scene.components);
    registerPlayerComponent(scene.components);
    registerInventoryComponents(scene.components);
    if (!scene.components.has(SPRITE_TYPE)) {
      scene.components.register(new Sprite().schema, () => new Sprite());
    }
    const a = assembleWorld(p.value, scene);
    if (!a.ok) return a;
    const v = attachWorldVisuals(scene, atlasFrames);
    if (!v.ok) return v;
    const sp = spawnPlayer(scene, p.value);
    if (!sp.ok) return sp;
    heroId = sp.value.nodeId;
    return ok(void 0);
  },
  describe() {
    return "\u7F16\u8F91\u5668\u4E16\u754C";
  }
};
function refreshTree() {
  const app = appRef;
  if (app === null) return;
  const o = buildOutline(app.scene, { skipTypes: [] });
  const rows = flattenOutline(o.root);
  const box = document.createElement("div");
  for (const r of rows) {
    box.appendChild(treeRow(r));
  }
  treeEl.replaceChildren(box);
  statusEl.textContent = `${String(o.count)} \u4E2A\u8282\u70B9${o.truncated ? "\uFF08\u5DF2\u622A\u65AD\uFF09" : ""} \xB7 \u4E16\u754C ${String(WORLD_W)}\xD7${String(WORLD_H)}`;
}
function treeRow(r) {
  const el = document.createElement("div");
  el.className = `row${selection.has(r.node.id) ? " sel" : ""}`;
  el.style.paddingLeft = `${String(6 + r.depth * 10)}px`;
  el.dataset["id"] = String(r.node.id);
  const id = document.createElement("span");
  id.className = "id";
  id.textContent = `#${String(r.node.id)} `;
  el.append(id, document.createTextNode(r.node.name));
  el.addEventListener("click", () => {
    if (selection.toggle(r.node.id)) selection.select(r.node.id);
    refreshTree();
    refreshProps();
  });
  return el;
}
function refreshProps() {
  const app = appRef;
  const primary = selection.primary;
  if (app === null || primary === null) {
    propsEl.replaceChildren(mkEmpty("\u672A\u9009\u4E2D"));
    return;
  }
  const node = app.scene.find(primary);
  if (node === void 0) {
    propsEl.replaceChildren(mkEmpty("\u9009\u4E2D\u7684\u8282\u70B9\u5DF2\u4E0D\u5B58\u5728"));
    return;
  }
  const frag = document.createDocumentFragment();
  const h = document.createElement("h2");
  h.textContent = `${node.name}  #${String(node.id)}`;
  frag.appendChild(h);
  if (node.components.length === 0) {
    const e = document.createElement("div");
    e.className = "empty";
    e.textContent = "\u8FD9\u4E2A\u8282\u70B9\u6CA1\u6709\u7EC4\u4EF6";
    frag.appendChild(e);
  }
  for (const comp of node.components) {
    const t = document.createElement("h3");
    t.textContent = comp.type;
    frag.appendChild(t);
    for (const f of fieldsOf(comp)) {
      frag.appendChild(propRow(primary, comp.type, f.key, f.control, f.value));
    }
  }
  propsEl.replaceChildren(frag);
}
function mkEmpty(text) {
  const d = document.createElement("div");
  d.className = "empty";
  d.textContent = text;
  return d;
}
function displayValue(control, v) {
  if (control === "vec2") {
    const o = v;
    return `${String(o.x ?? 0)}, ${String(o.y ?? 0)}`;
  }
  if (control === "color") {
    const o = v;
    const hex = (n) => Math.round(Math.max(0, Math.min(1, n)) * 255).toString(16).padStart(2, "0");
    return `#${hex(o.r ?? 1)}${hex(o.g ?? 1)}${hex(o.b ?? 1)}${hex(o.a ?? 1)}`;
  }
  if (control === "tags") return Array.isArray(v) ? v.join(", ") : String(v);
  return String(v);
}
function propRow(nodeId, type, key, control, value) {
  const row = document.createElement("div");
  row.className = "f";
  const label = document.createElement("label");
  label.textContent = key;
  label.title = `${type}.${key}`;
  const input = document.createElement("input");
  input.type = control === "checkbox" ? "checkbox" : "text";
  if (control === "checkbox") input.checked = value === true;
  else input.value = displayValue(control, value);
  const ty = document.createElement("span");
  ty.className = "ty";
  ty.textContent = control;
  const commit = () => {
    const raw = control === "checkbox" ? input.checked : input.value;
    const r = setField(appRef.scene, nodeId, type, key, raw);
    if (r.ok) {
      input.classList.remove("bad");
      errEl.textContent = "";
    } else {
      input.classList.add("bad");
      errEl.textContent = `${r.error.code}\uFF1A${r.error.message}`;
    }
  };
  input.addEventListener("change", commit);
  row.append(label, input, ty);
  return row;
}
var last = performance.now();
var uiClock = 0;
function loop(now) {
  const dt = Math.max(0, (now - last) / 1e3);
  last = now;
  const app = appRef;
  if (app !== null) {
    const ticks = pie.advance(dt);
    for (let i = 0; i < ticks; i++) app.frame(FIXED_DT);
    if (now - uiClock > 500) {
      uiClock = now;
      refreshTree();
      const st = pie.stats();
      tickEl.textContent = `tick ${String(app.scheduler.stats().tick)}`;
      pieInfoEl.textContent = st.playing ? "\u64AD\u653E\u4E2D" : st.pending > 0 ? `\u5F85\u8DD1 ${String(st.pending)}` : "\u6682\u505C";
    }
  }
  requestAnimationFrame(loop);
}
function installApi(app) {
  const api = {
    ready: () => booted && appRef !== null,
    stats() {
      const o = buildOutline(app.scene);
      const s = selection.snapshot();
      return {
        nodes: o.count,
        truncated: o.truncated,
        tick: app.scheduler.stats().tick,
        playing: pie.isPlaying,
        selected: [...s.ids],
        primary: s.primary
      };
    },
    outline() {
      return flattenOutline(buildOutline(app.scene).root).map((r) => ({
        id: r.node.id,
        name: r.node.name,
        depth: r.depth,
        types: [...r.node.types]
      }));
    },
    select(id) {
      const n = app.scene.find(id);
      if (n === void 0) return false;
      selection.select(n.id);
      refreshTree();
      refreshProps();
      return true;
    },
    panel() {
      const primary = selection.primary;
      if (primary === null) return null;
      const node = app.scene.find(primary);
      if (node === void 0) return null;
      return {
        node: node.id,
        groups: node.components.map((c) => ({
          type: c.type,
          fields: fieldsOf(c).map((f) => ({ key: f.key, type: f.type, control: f.control, value: f.value }))
        }))
      };
    },
    setField(node, type, key, raw) {
      const r = setField(app.scene, node, type, key, raw);
      if (!r.ok) return { ok: false, code: r.error.code };
      refreshProps();
      return { ok: true, value: r.value.after };
    },
    step(n) {
      const k = Math.max(0, Math.floor(n));
      for (let i = 0; i < k; i++) app.frame(FIXED_DT);
      return app.scheduler.stats().tick;
    },
    play() {
      pie.play();
    },
    pause() {
      pie.pause();
    },
    pie() {
      const s = pie.stats();
      return { tick: s.tick, playing: s.playing, pending: s.pending, clampedFrames: s.clampedFrames };
    }
  };
  window.__editor = api;
}
async function main() {
  planRef = generateWorld({ seed: WORLD_SEED, width: WORLD_W, height: WORLD_H, maxSitesPerCell: 1 });
  const appR = await bootGameApp({
    platformId: "editor",
    interactive: true,
    registry,
    modules: [worldMod, renderMod, worldgenMod],
    seed: WORLD_SEED,
    fixedDt: FIXED_DT,
    backendOptions: {
      gfx: { canvas },
      input: { keyboard: window, pointer: canvas },
      audio: {}
    }
  });
  if (!appR.ok) {
    errEl.textContent = `\u542F\u52A8\u5931\u8D25 ${appR.error.code}\uFF1A${appR.error.message}`;
    return;
  }
  const app = appR.value;
  appRef = app;
  booted = true;
  installApi(app);
  refreshTree();
  refreshProps();
  tickEl.textContent = `tick ${String(app.scheduler.stats().tick)}`;
  btnPlay.addEventListener("click", () => pie.play());
  btnPause.addEventListener("click", () => pie.pause());
  btnStep.addEventListener("click", () => pie.step(1));
  btnStep10.addEventListener("click", () => pie.step(10));
  requestAnimationFrame(loop);
}
void main();
