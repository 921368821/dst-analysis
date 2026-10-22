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

// src/foundation/math/scalar.ts
var TAU = Math.PI * 2;
function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}
function quantize(v, decimals = 3) {
  const f = Math.pow(10, decimals);
  return Math.sign(v) * Math.round(Math.abs(v) * f + 1e-9) / f;
}

// src/backends/gfx-null/device.ts
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
    this.textures.set(h, {
      width: desc.width,
      height: desc.height,
      label: desc.label ?? "",
      isTarget: desc.renderTarget === true
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
    const expect = region.width * region.height * 4;
    if (data.byteLength !== expect && rec.isTarget) {
      return err(
        engineError("GFX.SIZE_MISMATCH", `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${expect} \u4E0D\u7B26`)
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
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
    const loop = opts.loop === true;
    const h = this.nextHandle++;
    this.voices.set(h, {
      handle: h,
      clip,
      name: c.name,
      bus: busName,
      volume,
      rate,
      loop,
      endsAtMs: loop ? Number.POSITIVE_INFINITY : this.clock + Math.round(c.durationMs / rate),
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    });
    this.playLog.push({
      clip,
      name: c.name,
      bus: busName,
      volume,
      loop,
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
  RGBA16F: "rgba16f"
};
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
    const gl = this.gl;
    const tex = gl.createTexture();
    if (tex === null || tex === void 0) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createTexture \u8FD4\u56DE null\uFF08\u663E\u5B58\u4E0D\u8DB3\uFF09"));
    }
    const fmt = glFormat(desc.format ?? PixelFormat.RGBA8);
    gl.bindTexture(GL.TEXTURE_2D, tex);
    gl.texImage2D(
      GL.TEXTURE_2D,
      0,
      fmt.internal,
      desc.width,
      desc.height,
      0,
      fmt.format,
      GL.UNSIGNED_BYTE,
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
    const need = region.width * region.height * 4;
    if (data.byteLength !== need) {
      return err(engineError("GFX.SIZE_MISMATCH", `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${need} \u4E0D\u7B26`));
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
      GL.RGBA,
      GL.UNSIGNED_BYTE,
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
    if (batch.indices !== null) {
      const irec = this.dev._bufferRec(batch.indices);
      if (irec === void 0) throw new Error(`draw \u7684\u7D22\u5F15\u7F13\u51B2\u53E5\u67C4 ${batch.indices} \u4E0D\u5B58\u5728`);
      this.gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, irec.gl);
      this.gl.drawElements(GL.TRIANGLES, batch.indexCount, GL.UNSIGNED_SHORT, 0);
    } else {
      this.gl.drawArrays(GL.TRIANGLES, 0, batch.vertexCount);
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
};
function glFormat(f) {
  switch (f) {
    case PixelFormat.RGB8:
      return { internal: GL.RGB, format: GL.RGB };
    case PixelFormat.R8:
      return { internal: GL.R8, format: GL.R8 };
    default:
      return { internal: GL.RGBA8, format: GL.RGBA };
  }
}
var webgl2Backend = {
  id: "webgl2",
  priority: 100,
  probe(options) {
    const o = options ?? {};
    const canvas = o.canvas;
    if (canvas === void 0 || typeof canvas.getContext !== "function") return false;
    try {
      return isGL2Like(canvas.getContext("webgl2"));
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
var PREVENT = /* @__PURE__ */ new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);
var DomInputDevice = class {
  caps = {
    backend: "dom",
    pointer: true,
    touch: true,
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
  bound = [];
  /** 有输入框聚焦时，键盘不驱动游戏（编辑器输入场景名时不能同时让角色走）。 */
  textFocus = false;
  constructor(opts) {
    if (opts.keyboard === void 0 || opts.pointer === void 0) {
      throw new Error("DomInputDevice \u9700\u8981 keyboard \u4E0E pointer \u4E24\u4E2A\u76D1\u542C\u76EE\u6807");
    }
    this.kb = opts.keyboard;
    this.ptr = opts.pointer;
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
    const snap = {
      keysDown: new Set(this.down),
      keysPressed: new Set(this.pressed),
      keysReleased: new Set(this.released),
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
  reset() {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
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

// src/platform/platform.ts
function createPlatform(req) {
  const { registry } = req;
  const clock = req.clock ?? new SystemClock();
  const gfxR = registry.create("gfx", {
    ...req.prefer?.gfx === void 0 ? {} : { prefer: req.prefer.gfx },
    ...req.allow?.gfx === void 0 ? {} : { allow: req.allow.gfx },
    options: req.backendOptions?.gfx
  });
  if (!gfxR.ok) return gfxR;
  const audioR = registry.create("audio", {
    ...req.prefer?.audio === void 0 ? {} : { prefer: req.prefer.audio },
    ...req.allow?.audio === void 0 ? {} : { allow: req.allow.audio },
    options: req.backendOptions?.audio
  });
  if (!audioR.ok) {
    gfxR.value.destroy();
    return audioR;
  }
  const inputR = registry.create("input", {
    ...req.prefer?.input === void 0 ? {} : { prefer: req.prefer.input },
    ...req.allow?.input === void 0 ? {} : { allow: req.allow.input },
    options: req.backendOptions?.input
  });
  if (!inputR.ok) {
    audioR.value.destroy();
    gfxR.value.destroy();
    return inputR;
  }
  const fsR = registry.create("fs", {
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
  if (registry.list("net").length > 0) {
    const netR = registry.create("net", {
      ...req.prefer?.net === void 0 ? {} : { prefer: req.prefer.net },
      ...req.allow?.net === void 0 ? {} : { allow: req.allow.net },
      options: req.backendOptions?.net
    });
    if (netR.ok) {
      net = netR.value;
      netId = req.prefer?.net ?? "auto";
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
      clock,
      backends: {
        gfx: gfxR.value.caps.backend,
        audio: audioR.value.caps.backend,
        input: inputR.value.caps.backend,
        fs: fsR.value.scheme,
        net: netId
      },
      dispose() {
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
   * 通用读取。**缺字段用默认值而不是跳过**，但要报告（见返回值）。
   * 返回缺失的字段名：调用方（AssetDatabase / 存档）据此判断"是不是旧版本"。
   */
  load(data) {
    const missing = [];
    const self = this;
    for (const [k, t] of Object.entries(this.schema.fields)) {
      if (data[k] === void 0) missing.push(k);
      self[k] = data[k] === void 0 ? zeroValue(t) : data[k];
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
    if (this.byId.has(id ?? -1)) {
      return err({ code: "SCENE.DUPLICATE_ID", message: `\u8282\u70B9 id ${id} \u5DF2\u5B58\u5728` });
    }
    const node = new Node(name, id);
    this.pending.push({ kind: "spawn", node, parent });
    return ok(node);
  }
  /** 立即建好（加载/编辑器用）。**游戏逻辑里请用 spawn（走队列）**。 */
  spawnImmediate(name, parent = this.root.id, id) {
    const node = new Node(name, id);
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
  Scheduler: defineService("core.scheduler")
};

// src/runtime/tick-source.ts
var RafTickSource = class {
  constructor(now) {
    this.now = now;
  }
  id = "raf";
  handle = 0;
  fn = null;
  last = 0;
  _running = false;
  start(fn) {
    if (this._running) return;
    this.fn = fn;
    this.last = this.now();
    this._running = true;
    const raf = globalThis.requestAnimationFrame;
    if (raf === void 0) throw new Error("\u5F53\u524D\u73AF\u5883\u6CA1\u6709 requestAnimationFrame \u2014\u2014 \u7528 IntervalTickSource");
    const loop = () => {
      if (!this._running) return;
      const t = this.now();
      const dt = (t - this.last) / 1e3;
      this.last = t;
      this.fn?.(dt);
      this.handle = raf(loop);
    };
    this.handle = raf(loop);
  }
  stop() {
    this._running = false;
    const caf = globalThis.cancelAnimationFrame;
    if (this.handle !== 0 && caf !== void 0) caf(this.handle);
    this.handle = 0;
  }
  get running() {
    return this._running;
  }
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
      `\u5E73\u53F0\u5C31\u7EEA\uFF1A${platform.id} gfx=${platform.backends.gfx} audio=${platform.backends.audio} input=${platform.backends.input} fs=${platform.backends.fs}`,
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
    for (let q2 = 0; q2 < maxQuads; q2++) {
      const v = q2 * 4;
      const i = q2 * 6;
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
   */
  static sort(items) {
    items.sort((a, b) => {
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
    for (let q2 = 0; q2 < n; q2++) {
      const it = sorted[q2];
      if (it.atlas !== lastAtlas) {
        atlasSwitches++;
        lastAtlas = it.atlas;
      }
      const c = cam.project(it.x, it.z);
      const e = cam.extents(it.w, it.h);
      const cy = c.y + (0.5 - it.pivotY) * 2 * e.halfH;
      const x0 = c.x - e.halfW;
      const x1 = c.x + e.halfW;
      const y0 = cy - e.halfH;
      const y1 = cy + e.halfH;
      const va = 1 - it.v0;
      const vb = 1 - it.v1;
      const base = q2 * 4 * FLOATS_PER_VERTEX;
      writeVert(this.vertices, base, x0, y0, it.u0, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX, x1, y0, it.u1, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 2, x1, y1, it.u1, va, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 3, x0, y1, it.u0, va, it);
    }
    return {
      quadCount: n,
      vertexCount: n * 4,
      indexCount: n * 6,
      drawCalls: n === 0 ? 0 : 1,
      atlasSwitches
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

// src/extensions/render/sprite.ts
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
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;
  schema = {
    type: "render.sprite",
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
      visible: FieldType.Bool,
      pivotY: FieldType.Float
    }
  };
};
function makeSprite(frame, width = 1, height = 1) {
  const s = new Sprite();
  s.frame = frame;
  s.width = width;
  s.height = height;
  return s;
}

// src/extensions/render/atlas.ts
var Pen = class {
  constructor(px, W, H) {
    this.px = px;
    this.W = W;
    this.H = H;
  }
  put(x, y, r, g, b, a = 255) {
    if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
    const i = (y * this.W + x) * 4;
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
    { name: "ground", x: 0, y: 96, w: 64, h: 64 }
  ];
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);
  let seed = 19088743;
  const rnd = () => {
    seed = seed * 1103515245 + 12345 & 2147483647;
    return seed / 2147483647;
  };
  for (let y = 96; y < 160; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
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

// src/extensions/render/render-module.ts
function createRenderModule(opts) {
  const camera = new Camera2D({
    viewportWidth: opts.viewportWidth,
    viewportHeight: opts.viewportHeight,
    zoom: opts.zoom ?? 32,
    tiltY: opts.tiltY ?? 0.62
  });
  let dev = null;
  let tex = null;
  let shader = null;
  let pipeline = null;
  let vbo = null;
  let ibo = null;
  let offRender = null;
  let batch = null;
  let atlas = null;
  let ctxRef = null;
  let lastFrame = { quads: 0, drawCalls: 0, atlasSwitches: 0, culled: 0 };
  const mod = {
    id: opts.id ?? "render.batch2d",
    deps: [],
    init(ctx) {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;
      atlas = opts.atlas ?? buildProceduralAtlas();
      const t = d.createTexture(
        {
          width: atlas.width,
          height: atlas.height,
          format: PixelFormat.RGBA8,
          filter: TextureFilter.Nearest,
          wrap: TextureWrap.Clamp,
          label: "engine.procedural-atlas"
        },
        atlas.pixels
      );
      if (!t.ok) return t;
      tex = t.value;
      const sh = d.createShader({
        vertex: SPRITE_VS,
        fragment: SPRITE_FS,
        label: "engine.sprite"
      });
      if (!sh.ok) {
        d.destroyTexture(tex);
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
        d.destroyTexture(tex);
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
        d.destroyTexture(tex);
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
        d.destroyTexture(tex);
        return ib;
      }
      ibo = ib.value;
      const up = d.updateBuffer(ibo, batch.indices);
      if (!up.ok) {
        d.destroyBuffer(ibo);
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return up;
      }
      ctx.log.channel("render").info(
        `\u6E32\u67D3\u6A21\u5757\u5C31\u7EEA\uFF1A${atlas.width}x${atlas.height} \u56FE\u96C6 \xB7 ${atlas.frames.size} \u5E27 \xB7 \u6279\u91CF\u4E0A\u9650 ${batch.maxQuads} quad`
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
        if (tex !== null) d.destroyTexture(tex);
      }
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      tex = null;
      dev = null;
      batch = null;
      atlas = null;
    },
    describe() {
      return `\u6E32\u67D3\uFF1A${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ${lastFrame.atlasSwitches} \u7EB9\u7406\u5207\u6362`;
    },
    get camera() {
      return camera;
    },
    get lastFrame() {
      return lastFrame;
    }
  };
  function renderFrame(info) {
    const d = dev;
    const b = batch;
    const a = atlas;
    const scene = ctxRef?.services.get(Services.Scene);
    if (d === null || b === null || a === null || scene === void 0) return;
    const target = opts.follow?.();
    if (target !== void 0) {
      camera.moveTo(target.x, target.z);
    }
    const sprites = scene.componentsOf("render.sprite");
    const items = [];
    const vis = camera.visibleRect();
    let culled = 0;
    const slotOfAtlas = (atlasId) => atlasId === "" ? 0 : 0;
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
      const f = a.frames.get(s.frame);
      if (f === void 0) {
        ctxRef?.log.channel("render").warn(`Sprite \u5E27\u540D\u4E0D\u5B58\u5728\uFF1A${JSON.stringify(s.frame)}`, { node: node.id }, null);
        continue;
      }
      items.push({
        nodeId: node.id,
        x: p.x,
        z: p.y,
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
        pivotY: s.pivotY,
        atlas: slotOfAtlas(s.atlasId)
      });
    }
    const built = b.build(items, camera);
    lastFrame = {
      quads: built.quadCount,
      drawCalls: 0,
      atlasSwitches: built.atlasSwitches,
      culled
    };
    const vw = d.size.width;
    const vh = d.size.height;
    camera.setViewport(vw, vh);
    const cmd = d.beginFrame(null);
    cmd.setViewport(new Rect(0, 0, vw, vh));
    cmd.clear(camera.clearColor, 1);
    if (built.quadCount > 0 && vbo !== null && ibo !== null && pipeline !== null && tex !== null) {
      const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
      if (!up.ok) {
        ctxRef?.log.channel("render").error(`\u9876\u70B9\u4E0A\u4F20\u5931\u8D25\uFF1A${up.error.message}`, void 0, null);
      } else {
        cmd.setPipeline(pipeline);
        cmd.bindTexture(0, tex);
        cmd.setUniform("u_useTexture", 1, "int");
        cmd.draw({
          vertices: vbo,
          indices: ibo,
          vertexCount: built.vertexCount,
          indexCount: built.indexCount
        });
        lastFrame = { ...lastFrame, drawCalls: 1 };
      }
    }
    cmd.finish();
    d.endFrame();
  }
  return mod;
}

// src/extensions/physics/physics.ts
var EPS = 1e-9;
var SpatialHashWorld = class {
  cellSize;
  maxIterations;
  skin;
  bodies = /* @__PURE__ */ new Map();
  /** cell key → body id 列表 */
  cells = /* @__PURE__ */ new Map();
  pos;
  _queries = 0;
  _pushes = 0;
  _unresolved = 0;
  constructor(pos, cfg = {}) {
    this.pos = pos;
    this.cellSize = cfg.cellSize ?? 4;
    this.maxIterations = cfg.maxIterations ?? 3;
    this.skin = cfg.skin ?? 1e-3;
    if (!(this.cellSize > 0)) throw new RangeError("cellSize \u5FC5\u987B > 0");
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
  }
  remove(nodeId) {
    this.bodies.delete(nodeId);
    this.reindex(nodeId);
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
    for (const [k2, list2] of this.cells) {
      const i = list2.indexOf(nodeId);
      if (i >= 0) {
        list2.splice(i, 1);
        if (list2.length === 0) this.cells.delete(k2);
        break;
      }
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
    const minCx = Math.floor((x - r) / this.cellSize);
    const maxCx = Math.floor((x + r) / this.cellSize);
    const minCz = Math.floor((z - r) / this.cellSize);
    const maxCz = Math.floor((z + r) / this.cellSize);
    const out = [];
    const seen = /* @__PURE__ */ new Set();
    for (let cx = minCx; cx <= maxCx; cx++) {
      for (let cz = minCz; cz <= maxCz; cz++) {
        const list = this.cells.get(this.key(cx, cz));
        if (list === void 0) continue;
        for (const id of list) {
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
   * 解算重叠。对每对 (动态, 其它)，若重叠则把动态体推开。
   *
   * ★ 为什么"逐对独立解算 + 迭代"而不是"一次性求平均位移"：
   *   后者在"三四个实体挤一个角"时会出现互相抵消、抖动。
   *   迭代式（最多 3 轮）在这个规模下更稳，而且实现只有一个循环。
   */
  resolve() {
    let moved = 0;
    for (let iter = 0; iter < this.maxIterations; iter++) {
      let movedThis = 0;
      for (const id of this.bodies.keys()) {
        const b = this.bodies.get(id);
        if (b.isStatic) continue;
        const p = this.pos.get(id);
        if (p === void 0) continue;
        const near = this.query(p.x, p.z, this.rangeOf(b) + this.maxRadiusNearby());
        for (const otherId of near) {
          if (otherId === id) continue;
          const ob = this.bodies.get(otherId);
          if (ob === void 0) continue;
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
      if (iter === this.maxIterations - 1 && movedThis > 0) this._unresolved++;
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
  maxRadiusNearby() {
    let m = 0;
    for (const b of this.bodies.values()) {
      const r = this.rangeOf(b);
      if (r > m) m = r;
    }
    return m;
  }
  stats() {
    return {
      bodies: this.bodies.size,
      cells: this.cells.size,
      queries: this._queries,
      pushes: this._pushes,
      unresolved: this._unresolved
    };
  }
  clear() {
    this.bodies.clear();
    this.cells.clear();
    this._queries = 0;
    this._pushes = 0;
    this._unresolved = 0;
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

// src/core/serialization/schema.ts
var Schema = class {
  version;
  fields;
  migrations;
  decimals;
  constructor(opts) {
    this.version = opts.version;
    this.fields = opts.fields;
    this.migrations = opts.migrations ?? [];
    this.decimals = opts.decimals ?? 3;
    const froms = this.migrations.map((m) => m.from).sort((a, b) => a - b);
    for (let i = 0; i < froms.length; i++) {
      if (froms[i] !== i + 1) {
        throw new Error(
          `\u8FC1\u79FB\u94FE\u5FC5\u987B\u4ECE v1 \u8FDE\u7EED\u8986\u76D6\u5230 v${this.version}\uFF0C\u5B9E\u9645\u7F3A v${i + 1}\uFF08\u5DF2\u6709\uFF1A${froms.join(",") || "\u65E0"}\uFF09`
        );
      }
    }
  }
  /** 把任意旧版本的记录迁到当前版本。 */
  migrate(data) {
    let cur = { ...data };
    let v = typeof cur["__v"] === "number" ? cur["__v"] : 1;
    if (v > this.version) {
      return err({
        code: "SER.VERSION_TOO_NEW",
        message: `\u8BB0\u5F55\u7248\u672C v${v} \u9AD8\u4E8E\u5F15\u64CE\u652F\u6301\u7684 v${this.version}\uFF08\u7528\u65B0\u5F15\u64CE\u5199\u7684\u6863\uFF0C\u65E7\u5F15\u64CE\u4E0D\u80FD\u8BFB\uFF09`
      });
    }
    while (v < this.version) {
      const m = this.migrations.find((x) => x.from === v);
      if (m === void 0) {
        return err({
          code: "SER.NO_MIGRATION",
          message: `\u7F3A\u5C11 v${v} \u2192 v${v + 1} \u7684\u8FC1\u79FB\u51FD\u6570`
        });
      }
      cur = m.migrate(cur);
      v++;
      cur["__v"] = v;
    }
    return ok(cur);
  }
  /**
   * 确定性序列化：`{ "__v": 2, "name": "abc", "hp": 12.346 }`
   * - 字段顺序 = schema 顺序（**不是**对象键顺序）
   * - 数字量化到 decimals
   * - schema 里没有的键**丢弃并报告**（不静默保留：保留会让"字段名拼错"变成永久脏数据）
   */
  encode(data) {
    const dropped = Object.keys(data).filter((k) => k !== "__v" && !this.fields.includes(k));
    const parts = [`"__v":${this.version}`];
    for (const k of this.fields) {
      const v = data[k];
      if (v === void 0) continue;
      parts.push(`${JSON.stringify(k)}:${encodeValue(v, this.decimals)}`);
    }
    return { text: `{${parts.join(",")}}`, dropped };
  }
  decode(text) {
    let raw;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      return err({
        code: "SER.BAD_JSON",
        message: `\u4E0D\u662F\u5408\u6CD5 JSON\uFF1A${e instanceof Error ? e.message : String(e)}`
      });
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      return err({ code: "SER.NOT_OBJECT", message: "\u9876\u5C42\u5FC5\u987B\u662F\u5BF9\u8C61" });
    }
    return this.migrate(raw);
  }
};
function encodeValue(v, decimals) {
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      return JSON.stringify(`__num__:${String(v)}`);
    }
    return String(quantize(v, decimals));
  }
  if (typeof v === "string" || typeof v === "boolean") return JSON.stringify(v);
  if (v === null) return "null";
  if (Array.isArray(v)) return "[" + v.map((x) => encodeValue(x, decimals)).join(",") + "]";
  if (typeof v === "object") {
    const o = v;
    const keys = Object.keys(o).sort();
    const body = [];
    for (const k of keys) {
      if (o[k] === void 0) continue;
      body.push(`${JSON.stringify(k)}:${encodeValue(o[k], decimals)}`);
    }
    return "{" + body.join(",") + "}";
  }
  return JSON.stringify(String(v));
}
function stableHash(text) {
  let h = 2166136261;
  if (typeof text === "string") {
    for (let i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i) & 255;
      h = Math.imul(h, 16777619) >>> 0;
      h ^= text.charCodeAt(i) >>> 8 & 255;
      h = Math.imul(h, 16777619) >>> 0;
    }
  } else {
    for (let i = 0; i < text.length; i++) {
      h ^= text[i];
      h = Math.imul(h, 16777619) >>> 0;
    }
  }
  return h.toString(16).padStart(8, "0");
}

// src/core/scene/scene-io.ts
var SCENE_FORMAT_VERSION = 1;
function collectNodes(scene) {
  const out = [];
  scene.root.walk((n) => {
    if (n.id !== scene.rootId) out.push(n);
  });
  out.sort((a, b) => a.id - b.id);
  return out;
}
function saveScene(scene) {
  const nodes = [];
  for (const n of collectNodes(scene)) {
    const comps = [];
    for (const c of [...n.components].sort((a, b) => a.type < b.type ? -1 : a.type > b.type ? 1 : 0)) {
      const saved = c.save();
      const { type: _t, ...rest } = saved;
      comps.push({ type: c.type, data: rest });
    }
    nodes.push({
      id: n.id,
      name: n.name,
      parent: n.parent === null || n.parent.id === scene.rootId ? null : n.parent.id,
      x: n.localPosition.x,
      y: n.localPosition.y,
      rot: n.localRotation,
      sx: n.localScale.x,
      sy: n.localScale.y,
      zIndex: n.zIndex,
      active: n.active,
      layer: n.layer,
      components: comps
    });
  }
  return { format: SCENE_FORMAT_VERSION, name: scene.name, nodes };
}
function loadScene(scene, snap, registry) {
  if (snap.format > SCENE_FORMAT_VERSION) {
    return err(
      engineError(
        "SCENE.FORMAT_TOO_NEW",
        `\u5B58\u6863\u683C\u5F0F v${snap.format} \u9AD8\u4E8E\u5F15\u64CE\u652F\u6301\u7684 v${SCENE_FORMAT_VERSION}\uFF08\u7528\u65B0\u5F15\u64CE\u5199\u7684\u6863\uFF0C\u65E7\u5F15\u64CE\u4E0D\u80FD\u8BFB\uFF09`
      )
    );
  }
  const skipped = [];
  const missingFields = [];
  scene.clear();
  const built = /* @__PURE__ */ new Map();
  const records = [...snap.nodes].sort((a, b) => a.id - b.id);
  for (const r of records) {
    try {
      const n = scene.spawnImmediate(r.name, r.id === 0 ? null : scene.rootId, r.id);
      n.setLocalPosition(r.x, r.y);
      n.setLocalRotation(r.rot);
      n.setLocalScale(r.sx, r.sy);
      n.zIndex = r.zIndex;
      n.active = r.active;
      n.layer = r.layer;
      n.markTransformDirty();
      built.set(r.id, n);
    } catch (e) {
      skipped.push(`\u8282\u70B9 #${r.id}\uFF08${r.name}\uFF09\uFF1A${e instanceof Error ? e.message : String(e)}`);
    }
  }
  for (const r of records) {
    if (r.parent === null) continue;
    const child = built.get(r.id);
    const parent = built.get(r.parent);
    if (child === void 0) continue;
    if (parent === void 0) {
      skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7236\u8282\u70B9 #${r.parent} \u4E0D\u5B58\u5728\uFF08\u8BE5\u8282\u70B9\u88AB\u6302\u5230\u6839\u4E0B\uFF09`);
      continue;
    }
    parent.addChild(child);
  }
  for (const r of records) {
    const n = built.get(r.id);
    if (n === void 0) continue;
    for (const cr of r.components) {
      if (!registry.has(cr.type)) {
        skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7EC4\u4EF6 ${cr.type} \u672A\u6CE8\u518C\uFF08\u8DF3\u8FC7\uFF09`);
        continue;
      }
      const c = registry.create(cr.type);
      if (c === void 0) {
        skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7EC4\u4EF6 ${cr.type} \u5DE5\u5382\u8FD4\u56DE undefined\uFF08\u8DF3\u8FC7\uFF09`);
        continue;
      }
      const res = c.load(cr.data);
      for (const f of res.missing) missingFields.push(`#${r.id}.${cr.type}.${f}`);
      scene.attach(n.id, () => c);
    }
  }
  scene.flush();
  return ok({ made: built.size, skipped, missingFields });
}
function sceneToJson(snap) {
  const lines = [];
  lines.push(`{"format":${snap.format},"name":${JSON.stringify(snap.name)},"nodes":[`);
  snap.nodes.forEach((n, i) => {
    const comps = n.components.map((c) => `{"type":${JSON.stringify(c.type)},"data":${stringifySorted(c.data)}}`).join(",");
    const rec = `{"id":${n.id},"name":${JSON.stringify(n.name)},"parent":${n.parent === null ? "null" : n.parent},"x":${q(n.x)},"y":${q(n.y)},"rot":${q(n.rot)},"sx":${q(n.sx)},"sy":${q(n.sy)},"zIndex":${n.zIndex},"active":${n.active},"layer":${n.layer},"components":[${comps}]}`;
    lines.push(rec + (i === snap.nodes.length - 1 ? "" : ","));
  });
  lines.push("]}");
  return lines.join("");
}
function sceneFromJson(text) {
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return err(engineError("SCENE.BAD_JSON", `\u4E0D\u662F\u5408\u6CD5 JSON\uFF1A${e instanceof Error ? e.message : String(e)}`));
  }
  if (raw === null || typeof raw !== "object") {
    return err(engineError("SCENE.BAD_JSON", "\u9876\u5C42\u4E0D\u662F\u5BF9\u8C61"));
  }
  const o = raw;
  if (typeof o.format !== "number" || !Array.isArray(o.nodes)) {
    return err(engineError("SCENE.BAD_JSON", "\u7F3A\u5C11 format \u6216 nodes"));
  }
  return ok({
    format: o.format,
    name: typeof o.name === "string" ? o.name : "scene",
    nodes: o.nodes
  });
}
function q(v) {
  return Math.round(v * 1e3) / 1e3;
}
function stringifySorted(o) {
  if (o === null || typeof o !== "object") {
    return typeof o === "number" ? String(q(o)) : JSON.stringify(o);
  }
  if (Array.isArray(o)) return "[" + o.map(stringifySorted).join(",") + "]";
  const rec = o;
  const keys = Object.keys(rec).sort();
  const parts = [];
  for (const k of keys) {
    if (rec[k] === void 0) continue;
    parts.push(`${JSON.stringify(k)}:${stringifySorted(rec[k])}`);
  }
  return "{" + parts.join(",") + "}";
}
var SCENE_SCHEMA = new Schema({
  version: SCENE_FORMAT_VERSION,
  fields: ["format", "name", "nodes"]
});

// src/browser-entry.ts
var PlayerController = class _PlayerController extends Component {
  speed = 4.5;
  lastTick = -1;
  snap = null;
  static pollInput = null;
  schema = {
    type: "game.player",
    fields: { speed: FieldType.Float }
  };
  onUpdate(tick, dt) {
    const poll = _PlayerController.pollInput;
    if (poll === null) return;
    if (tick !== this.lastTick) {
      this.snap = poll();
      this.lastTick = tick;
    }
    const s = this.snap;
    if (s === null) return;
    let dx = 0;
    let dz = 0;
    if (s.keysDown.has("KeyA") || s.keysDown.has("ArrowLeft")) dx -= 1;
    if (s.keysDown.has("KeyD") || s.keysDown.has("ArrowRight")) dx += 1;
    if (s.keysDown.has("KeyW") || s.keysDown.has("ArrowUp")) dz += 1;
    if (s.keysDown.has("KeyS") || s.keysDown.has("ArrowDown")) dz -= 1;
    const len = Math.hypot(dx, dz);
    if (len === 0) return;
    const n = this.node;
    if (n === null) return;
    n.setLocalPosition(
      n.localPosition.x + dx / len * this.speed * dt,
      n.localPosition.y + dz / len * this.speed * dt
    );
  }
};
var Workable = class extends Component {
  workleft = 3;
  schema = {
    type: "game.workable",
    fields: { workleft: FieldType.Int }
  };
};
function createWorldModule(physics, hooks) {
  let off = null;
  return {
    id: "game.world",
    init(ctx) {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        physics.resolve();
        hooks.onTick(tick);
      });
    },
    stop() {
      off?.();
      off = null;
    },
    describe() {
      return `\u4E16\u754C\uFF1A${physics.stats().bodies} \u4E2A\u7269\u7406\u4F53`;
    }
  };
}
async function main() {
  const canvas = document.getElementById("cv");
  const hud = document.getElementById("hud");
  const toastEl = document.getElementById("toast");
  if (canvas === null || hud === null || toastEl === null) {
    throw new Error("\u9875\u9762\u7ED3\u6784\u4E0D\u5B8C\u6574\uFF1A\u9700\u8981 #cv / #hud / #toast");
  }
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.floor((canvas.clientWidth || 960) * dpr);
  canvas.height = Math.floor((canvas.clientHeight || 600) * dpr);
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  registry.registerGfx(webgl2Backend, 100);
  registry.registerInput(domInputBackend, 100);
  registry.registerAudio(webAudioBackend, 100);
  let appRef = null;
  const physics = new SpatialHashWorld(
    makeSceneAccessor((id) => {
      const n = appRef?.scene.find(id);
      if (n === void 0) return void 0;
      return {
        id: n.id,
        worldPosition: () => n.worldPosition,
        setLocalPosition: (x, y) => n.setLocalPosition(x, y)
      };
    }),
    { cellSize: 4, maxIterations: 3 }
  );
  let heroId = -1;
  let hudTick = 0;
  const renderMod = createRenderModule({
    viewportWidth: canvas.width,
    viewportHeight: canvas.height,
    zoom: 26 * dpr,
    tiltY: 0.62,
    follow: () => {
      if (heroId < 0) return void 0;
      const n = appRef?.scene.find(heroId);
      if (n === void 0) return void 0;
      const p = n.worldPosition;
      return { x: p.x, z: p.y };
    }
  });
  const worldMod = createWorldModule(physics, { onTick: (t) => hudTick = t });
  const appR = await bootGameApp({
    platformId: "web",
    interactive: true,
    registry,
    modules: [worldMod, renderMod],
    seed: 20261022,
    fixedDt: 1 / 30,
    tickSource: new RafTickSource(() => performance.now()),
    backendOptions: {
      gfx: { canvas },
      input: { keyboard: window, pointer: canvas },
      audio: {}
    }
  });
  if (!appR.ok) {
    document.body.innerHTML = `<pre style="color:#f66;padding:16px;font:13px ui-monospace">\u542F\u52A8\u5931\u8D25\uFF1A${appR.error.code}
${appR.error.message}

${JSON.stringify(appR.error.detail ?? {}, null, 2)}</pre>`;
    return;
  }
  const app = appR.value;
  appRef = app;
  PlayerController.pollInput = () => app.platform.input.poll();
  const reg = app.components;
  reg.register(new Sprite().schema, () => new Sprite());
  reg.register({ type: "game.player", fields: { speed: FieldType.Float } }, () => new PlayerController());
  reg.register({ type: "game.workable", fields: { workleft: FieldType.Int } }, () => new Workable());
  const scene = app.scene;
  const rnd = app.random;
  for (let gz = -8; gz <= 8; gz++) {
    for (let gx = -14; gx <= 14; gx++) {
      const r = scene.spawnAt(`ground_${gx}_${gz}`, gx * 2, gz * 2);
      if (!r.ok) continue;
      const s = makeSprite("ground", 2.05, 2.05);
      s.pivotY = 0.5;
      s.r = 0.62 + rnd.range(0, 0.06);
      s.g = 0.72 + rnd.range(0, 0.06);
      s.b = 0.66;
      s.order = -100;
      scene.attach(r.value.id, () => s);
    }
  }
  const obstacleIds = [];
  for (let i = 0; i < 70; i++) {
    const isTree = i % 3 !== 0;
    const x = rnd.range(-26, 26);
    const z = rnd.range(-16, 16);
    const r = scene.spawnAt(isTree ? `tree${i}` : `rock${i}`, x, z);
    if (!r.ok) continue;
    const node = r.value;
    const s = makeSprite(isTree ? "tree" : "rock", isTree ? 2 : 1.6, isTree ? 3 : 1.4);
    s.pivotY = 0;
    scene.attach(node.id, () => s);
    if (isTree) scene.attach(node.id, () => new Workable());
    obstacleIds.push(node.id);
    physics.add({ nodeId: node.id, radius: isTree ? 0.55 : 0.7, isStatic: true });
  }
  for (let i = 0; i < 14; i++) {
    const r = scene.spawnAt(`berry${i}`, rnd.range(-24, 24), rnd.range(-14, 14));
    if (!r.ok) continue;
    const s = makeSprite("berry", 0.8, 0.8);
    s.pivotY = 0;
    scene.attach(r.value.id, () => s);
  }
  const hero = scene.spawnAt("hero", 0, 0);
  if (!hero.ok) throw new Error(hero.error.message);
  heroId = hero.value.id;
  const heroSprite = makeSprite("player", 1.1, 1.7);
  heroSprite.pivotY = 0;
  scene.attach(heroId, () => heroSprite);
  scene.attach(heroId, () => new PlayerController());
  physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
  scene.flush();
  const SAVE_KEY = "engine08.save.v1";
  let toastTimer = 0;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.style.opacity = "1";
    if (toastTimer !== 0) clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
      toastEl.style.opacity = "0";
    }, 2e3);
  }
  function doSave() {
    const json = sceneToJson(saveScene(scene));
    localStorage.setItem(SAVE_KEY, json);
    toast(`\u5DF2\u5B58\u6863\uFF1A${json.length} \u5B57\u8282 \xB7 hash ${stableHash(json)}`);
  }
  function doLoad() {
    const json = localStorage.getItem(SAVE_KEY);
    if (json === null) {
      toast("\u8FD8\u6CA1\u6709\u5B58\u6863\uFF08\u5148\u6309 F5\uFF09");
      return;
    }
    const snap = sceneFromJson(json);
    if (!snap.ok) {
      toast("\u5B58\u6863\u635F\u574F\uFF1A" + snap.error.message);
      return;
    }
    const r = loadScene(scene, snap.value, reg);
    if (!r.ok) {
      toast("\u8BFB\u6863\u5931\u8D25\uFF1A" + r.error.message);
      return;
    }
    physics.clear();
    for (const id of obstacleIds) {
      if (scene.find(id) !== void 0) physics.add({ nodeId: id, radius: 0.6, isStatic: true });
    }
    if (scene.find(heroId) !== void 0) physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
    const extra = r.value.skipped.length > 0 ? `\uFF0C\u8DF3\u8FC7 ${r.value.skipped.length} \u9879` : "";
    toast(`\u5DF2\u8BFB\u6863\uFF1A${r.value.made} \u4E2A\u8282\u70B9${extra}`);
  }
  function chopNearest() {
    const heroNode = scene.find(heroId);
    if (heroNode === void 0) return;
    const hp = heroNode.worldPosition;
    for (const id of physics.query(hp.x, hp.y, 2.4)) {
      if (id === heroId) continue;
      const w = scene.find(id)?.get("game.workable");
      if (w === void 0) continue;
      w.workleft -= 1;
      if (w.workleft <= 0) {
        scene.destroy(id);
        physics.remove(id);
        toast("\u780D\u5012\u4E86\u4E00\u68F5\u6811");
      } else {
        toast(`\u780D\u4E86\u4E00\u4E0B\uFF0C\u8FD8\u5269 ${w.workleft}`);
      }
      return;
    }
    toast("\u9644\u8FD1\u6CA1\u6709\u53EF\u780D\u7684\u4E1C\u897F");
  }
  let fps = 0;
  let frames = 0;
  let lastFpsAt = performance.now();
  app.services.require(Services.Frame).onRender((info) => {
    frames++;
    const now = performance.now();
    if (now - lastFpsAt > 500) {
      fps = frames / ((now - lastFpsAt) / 1e3);
      frames = 0;
      lastFpsAt = now;
    }
    const lf = renderMod.lastFrame;
    const st = app.snapshot();
    hud.textContent = `fps ${fps.toFixed(0)} \xB7 tick ${hudTick} \xB7 quad ${lf.quads} \xB7 draw ${lf.drawCalls} \xB7 culled ${lf.culled} \xB7 nodes ${st.scene.nodes} \xB7 bodies ${physics.stats().bodies} \xB7 ${st.backends.gfx}/${st.backends.audio}/${st.backends.input} \xB7 dropped ${st.droppedSteps}`;
  });
  window.addEventListener("keydown", (ev) => {
    if (ev.code === "F5") {
      ev.preventDefault();
      doSave();
    } else if (ev.code === "F9") {
      ev.preventDefault();
      doLoad();
    } else if (ev.code === "KeyR") {
      location.reload();
    } else if (ev.code === "KeyH") {
      chopNearest();
    }
  });
  window.addEventListener(
    "pointerdown",
    () => {
      void app.platform.audio.resume();
    },
    { once: true }
  );
  const runR = app.run();
  if (!runR.ok) {
    app.log.channel("host").error(`\u5E27\u5FAA\u73AF\u542F\u52A8\u5931\u8D25\uFF1A${runR.error.message}`);
    toast("\u5E27\u5FAA\u73AF\u542F\u52A8\u5931\u8D25\uFF1A" + runR.error.message);
  } else {
    toast("WASD \u79FB\u52A8 \xB7 H \u780D\u6811 \xB7 F5 \u5B58\u6863 \xB7 F9 \u8BFB\u6863 \xB7 R \u91CD\u8F7D");
  }
  globalThis.__engine = {
    app,
    renderMod,
    physics,
    scene,
    save: doSave,
    load: doLoad,
    heroId,
    snapshot: () => app.snapshot(),
    lastFrame: () => renderMod.lastFrame
  };
}
void main();
export {
  main
};
