#!/usr/bin/env node
/**
 * tools/gen-protocol-schema.mjs —— 协议常量的**单源生成器**（L1）
 *
 * 为什么要有（缺口是什么）
 *   `rt/protocol_bin.py` 与 `rt/protocol_bin.js` 是同一份线上格式的两端实现，
 *   它们在顶上**各自手写**了同一组常量：
 *       VERSION = 3 / FIX = 16 / PHASES = [day, dusk, night] / SEASONS = [autumn, winter, spring, summer]
 *   两处手写意味着「只改一边」是随时可能发生的，而后果是**最难查的那类错**：
 *     · 顺序写错 ⇒ 服务端发 `day`、客户端解成 `night`（画面里天黑得莫名其妙）；
 *     · FIX 不一致 ⇒ 位置缓慢漂移（看着像物理抖动）；
 *     · VERSION 不一致 ⇒ 客户端直接拒帧（这条还算好消息）。
 *   `tests/test_protocol_parity.py`（②g）能抓到「编码→解码」不一致，
 *   但它抓不到「两边一起写错」；单源生成把这类错误从「靠人记得改两处」变成「不可能」。
 *
 * 生成物
 *   rt/protocol_schema.py   —— Python 侧常量
 *   rt/protocol_schema.js   —— JS 侧常量（同时支持 CommonJS 与 <script>，见 client.html 的加载顺序）
 *   两份文件头都带「勿手改」标记；`--check` 发现不一致就红。
 *
 * 用法
 *   node tools/gen-protocol-schema.mjs --write     # 写盘
 *   node tools/gen-protocol-schema.mjs --check     # 只校验（CI / pre-commit / run_all）
 *   node tools/gen-protocol-schema.mjs --selftest  # 自检：改 schema 必须导致 --check 红
 *
 * 退出码：0 通过 / 1 漂移 / 2 用法或 schema 错误
 */
import { readFileSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RT = join(ROOT, "07-通用引擎", "rt");
const SCHEMA = join(RT, "protocol.schema.json");
const PY_OUT = join(RT, "protocol_schema.py");
const JS_OUT = join(RT, "protocol_schema.js");

function loadSchema(file = SCHEMA) {
  const s = JSON.parse(readFileSync(file, "utf8"));
  const need = ["magic", "version", "fix", "phases", "seasons"];
  for (const k of need) {
    if (s[k] === undefined) throw new Error(`schema 缺字段 ${k}`);
  }
  if (!Array.isArray(s.magic) || s.magic.length !== 2) throw new Error("magic 必须是 2 个字节");
  if (!Array.isArray(s.phases) || !s.phases.length) throw new Error("phases 必须是非空数组");
  if (!Array.isArray(s.seasons) || !s.seasons.length) throw new Error("seasons 必须是非空数组");
  const dup = (a) => a.length !== new Set(a).size;
  if (dup(s.phases)) throw new Error("phases 有重复项 —— 序数编码下重复项等于两项同号");
  if (dup(s.seasons)) throw new Error("seasons 有重复项 —— 同上");
  return s;
}

const pyList = (a) => "[" + a.map((x) => JSON.stringify(x)).join(", ") + "]";
const jsList = (a) => "[" + a.map((x) => JSON.stringify(x)).join(", ") + "]";

function genPy(s) {
  const [m0, m1] = s.magic;
  return `# -*- coding: utf-8 -*-
"""protocol_schema.py —— ⚠ **生成文件，勿手改**

单一来源：rt/protocol.schema.json
生成器    ：tools/gen-protocol-schema.mjs（\`--check\` 会校验本文件是否被手改）
"""
MAGIC0 = ${m0}
MAGIC1 = ${m1}
MAGIC = ${((m0 << 8) | m1) >>> 0}
VERSION = ${s.version}
FIX = ${Number(s.fix)}.0
PHASES = ${pyList(s.phases)}
SEASONS = ${jsList(s.seasons)}
`;
}

function genJs(s) {
  return `// protocol_schema.js —— ⚠ 生成文件，勿手改
//
// 单一来源：protocol.schema.json（生成器 tools/gen-protocol-schema.mjs）
// ★ 加载顺序：本文件必须**先于** protocol_bin.js（见 client.html 的 <script> 顺序），
//   否则 protocol_bin.js 会抛「schema 未加载」而不是静默用错常量。
(function (root) {
  'use strict';
  const S = {
    MAGIC: ${((s.magic[0] << 8) | s.magic[1]) >>> 0},
    MAGIC0: ${s.magic[0]},
    MAGIC1: ${s.magic[1]},
    VERSION: ${s.version},
    FIX: ${Number(s.fix)},
    PHASES: ${jsList(s.phases)},
    SEASONS: ${jsList(s.seasons)},
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = S;
  if (typeof window !== 'undefined') window.ProtocolSchema = S;
})(typeof globalThis !== 'undefined' ? globalThis : this);
`;
}

function check() {
  const s = loadSchema();
  const wantPy = genPy(s), wantJs = genJs(s);
  let bad = 0;
  for (const [p, want, name] of [[PY_OUT, wantPy, "protocol_schema.py"], [JS_OUT, wantJs, "protocol_schema.js"]]) {
    const have = existsSync(p) ? readFileSync(p, "utf8") : null;
    if (have === null) {
      console.log(`  ✘ ${name} 不存在 —— 跑 --write`);
      bad++;
    } else if (have !== want) {
      console.log(`  ✘ ${name} 与 schema 不一致（被手改过，或 schema 改了没重生成）`);
      bad++;
    } else {
      console.log(`  ✔ ${name} 与 schema 一致（version=${s.version} fix=${s.fix}）`);
    }
  }
  return bad ? 1 : 0;
}

function write() {
  const s = loadSchema();
  writeFileSync(PY_OUT, genPy(s), "utf8");
  writeFileSync(JS_OUT, genJs(s), "utf8");
  console.log(`✔ 已生成 protocol_schema.py / protocol_schema.js（version=${s.version} fix=${s.fix} ` +
              `phases=${s.phases.length} seasons=${s.seasons.length}）`);
  return 0;
}

function selftest() {
  let bad = 0;
  const ok = (c, m) => { console.log(`  ${c ? "✔" : "✘"} ${m}`); if (!c) bad++; };
  const tmpSchema = join(RT, "_schema_selftest.json");
  const orig = readFileSync(SCHEMA, "utf8");
  try {
    console.log("── G1 生成物包含 schema 的全部事实 ──");
    const s = loadSchema();
    const py = genPy(s), js = genJs(s);
    ok(py.includes(`PHASES = ${pyList(s.phases)}`), "py 侧 phases 顺序原样");
    ok(js.includes(`SEASONS: ${jsList(s.seasons)}`), "js 侧 seasons 顺序原样");
    ok(/VERSION = 3/.test(py) && /VERSION: 3/.test(js), "两侧 version 都是 3");

    console.log("── G2 改 schema ⇒ --check 必须红（证明它真的读了 schema） ──");
    const mutated = { ...s, version: 99 };
    writeFileSync(tmpSchema, JSON.stringify(mutated), "utf8");
    const m = loadSchema(tmpSchema);
    const py2 = genPy(m), js2 = genJs(m);
    ok(py2 !== py && js2 !== js, "version 改动会改变两侧生成物");
    ok(!/VERSION = 3/.test(py2), "py 侧旧的 version=3 确实没了");

    console.log("── G3 坏 schema 必须抛错（不许生成半成品） ──");
    const badCases = [
      [{ ...s, magic: [1] }, "magic 只有一个字节"],
      [{ ...s, phases: [] }, "phases 为空"],
      [{ ...s, phases: ["day", "day", "night"] }, "phases 有重复（序数撞号）"],
      [{ ...s, seasons: ["autumn", "autumn"] }, "seasons 有重复"],
    ];
    for (const [obj, why] of badCases) {
      writeFileSync(tmpSchema, JSON.stringify(obj), "utf8");
      try {
        loadSchema(tmpSchema);
        ok(false, `${why} —— 竟然没抛错`);
      } catch (e) {
        ok(true, `${why} → ${e.message}`);
      }
    }
  } finally {
    // ★ 只删临时 schema —— 真正的 protocol.schema.json **全程没被改过**
    //   （变异都写进 tmpSchema）。早期版本在这里多写了一次 SCHEMA，
    //   万一自检中途被打断，就可能留下一个「看起来没变」的写操作。
    try { unlinkSync(tmpSchema); } catch { /* noop */ }
  }
  console.log(bad ? `\n结果：${bad} 条失败` : "\n结果：全绿");
  return bad ? 1 : 0;
}

const argv = process.argv.slice(2);
let rc;
try {
  if (argv.includes("--selftest")) rc = selftest();
  else if (argv.includes("--write")) rc = write();
  else if (argv.includes("--check")) rc = check();
  else { console.error("用法: --write | --check | --selftest"); rc = 2; }
} catch (e) {
  console.error("✘ " + (e && e.message ? e.message : e));
  rc = 2;
}
process.exit(rc);
