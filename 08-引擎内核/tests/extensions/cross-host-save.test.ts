/**
 * 跨宿主存档语料的**自检**（Node 这一侧）。
 *
 * ★ 分工要说清楚，否则会误以为"这里已经验过跨宿主了"：
 *   · 本文件：语料本身是不是**确定性的**、能不能解析、往返后字节变不变、下限够不够；
 *   · `tools/cross-host-save.mjs`：把**同一份语料**拿到真浏览器里再跑一遍，逐字节比对
 *     （那一步进 `npm run ci`，没有浏览器时以退出码 2 显式跳过）。
 *
 * ★ 为什么语料也要判据：语料退化的方式很安静 —— 比如某天 `generateWorld` 改了默认值，
 *   语料从 481 个节点变成 3 个节点，"跨宿主比对"依然全绿（两边都小）。
 *   下面的下限断言就是防这个的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { SITE_TYPE, TERRAIN_TYPE, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { RESOURCE_TYPE, registerResourceComponent } from "../../src/extensions/worldgen/task-module.ts";
import { registerPlayerComponent } from "../../src/extensions/worldgen/spawn.ts";
import { registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { buildCrossHostSave, bytesToBase64, crossHostBytes } from "../fixtures/cross-host-save.ts";

test("[跨宿主语料] 同一份语料跑两次：字节完全相同（确定性）", () => {
  const a = buildCrossHostSave();
  const b = buildCrossHostSave();
  const ba = crossHostBytes(a.json);
  const bb = crossHostBytes(b.json);
  assert.equal(ba.length, bb.length, "两次跑出来的存档长度不同 —— 语料里有随机/时钟");
  assert.deepEqual([...ba], [...bb], "两次跑出来的字节不同 —— 语料里有随机/时钟");
});

test("[跨宿主语料] 语料下限：节点 / 资源 / 堆叠都得够（防“两边都空”的假绿）", () => {
  const r = buildCrossHostSave();
  assert.ok(r.nodes >= 400, `节点只有 ${String(r.nodes)} 个 —— 语料退化了`);
  assert.ok(r.resources >= 5, `再生资源只有 ${String(r.resources)} 个 —— 语料退化了`);
  assert.equal(r.stacks, 3, `背包堆数应为 3（芦苇 1 + 树枝 40/5 两堆），得到 ${String(r.stacks)}`);
  assert.equal(r.released, 40, `采集格数应为 40，得到 ${String(r.released)}`);
  assert.ok(r.json.startsWith('{"format":1'), "存档头不是 format:1");
});

test("[跨宿主语料] 存档能解析、能读档、读档后再存**逐字节**相同", () => {
  const r = buildCrossHostSave();
  const snap = sceneFromJson(r.json);
  assert.equal(snap.ok, true, snap.ok ? "" : `解析失败：${snap.error.code}`);
  if (!snap.ok) return;
  assert.equal(snap.value.nodes.length, r.nodes, "解析出来的节点数与语料报告的不一致");

  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponent(reg);
  registerInventoryComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  const scene2 = new Scene("跨宿主存档", reg);
  const loaded = loadScene(scene2, snap.value, scene2.components);
  assert.equal(loaded.ok, true, loaded.ok ? "" : `读档失败：${loaded.error.code}`);
  if (!loaded.ok) return;
  assert.deepEqual([...loaded.value.skipped], [], "读档跳过了东西 —— 语料里有组件没注册");
  assert.deepEqual([...loaded.value.missingFields], [], "读档报了缺字段 —— 组件 schema 与存档不一致");

  // ★ 这条是"确定性序列化"真正的承诺：读回来的世界再存一次，字节不变
  assert.equal(sceneToJson(saveScene(scene2)), r.json, "读档后再存，字节变了");
});

test("[跨宿主语料] 计划投放点与再生资源**两种**来源都在存档里", () => {
  const r = buildCrossHostSave();
  const snap = sceneFromJson(r.json);
  assert.equal(snap.ok, true);
  if (!snap.ok) return;
  const types = new Set(snap.value.nodes.flatMap((n) => n.components.map((c) => c.type)));
  assert.ok(types.has(SITE_TYPE), `存档里没有 ${SITE_TYPE}`);
  assert.ok(types.has(RESOURCE_TYPE), `存档里没有 ${RESOURCE_TYPE}（再生资源没长出来？）`);
  assert.ok(types.has(TERRAIN_TYPE), `存档里没有 ${TERRAIN_TYPE}`);
  assert.ok(types.has("game.inventory"), "存档里没有背包 —— 背包组件没注册");
  assert.ok(types.has("game.item"), "存档里没有物品堆叠");
  assert.ok(types.has(SPRITE_TYPE), "存档里没有精灵");
});

test("[跨宿主语料] 手写 base64 与 Node 的 Buffer 编码一致（含 padding 边界）", () => {
  // 长度 0..8 覆盖三种 padding 情形（余 0 / 余 1 / 余 2）
  for (let n = 0; n <= 8; n++) {
    const bytes = new Uint8Array(n);
    for (let i = 0; i < n; i++) bytes[i] = (i * 37 + 11) & 0xff;
    assert.equal(bytesToBase64(bytes), Buffer.from(bytes).toString("base64"), `长度 ${String(n)} 时编码不同`);
  }
  // 中文（多字节）+ 高位字节
  const text = "跨宿主存档 · ünïcode · \u0000\u00ff";
  const bytes = crossHostBytes(text);
  assert.equal(bytesToBase64(bytes), Buffer.from(bytes).toString("base64"));
  assert.equal(Buffer.from(bytesToBase64(bytes), "base64").toString("utf8"), text, "编码再解码没回到原文");
});
