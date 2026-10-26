/**
 * L4 · 编辑器：工程落盘的判据
 *
 * 这一组盯的不是"能不能序列化"（那太容易绿了），而是**坏输入进来了会怎样**：
 * 存档是唯一一份用户数据，解析器写成"尽量恢复"的后果是"我三个场景只剩一个"，
 * 而且没有任何报错。所以每个失败分支都单独点名断言错误码 —— 一个码挂两个出口，
 * 就必有一条变异被遮住（批90 M414 的教训）。
 *
 * 另外盯两条"看起来成立但其实没验"的事：
 *  · **产物必须可复现**：同一个工程序列化两次一字不差（所以不写时间戳）；
 *  · **失败不许清档**：`loadProject` 拿到坏存档时，介质里的字节必须原样还在。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { Project } from "../../src/extensions/editor/project.ts";
import {
  EDIT_PROJECT_CURRENT,
  EDIT_PROJECT_DUP,
  EDIT_PROJECT_FORMAT,
  EDIT_PROJECT_JSON,
  EDIT_PROJECT_SHAPE,
  EDIT_PROJECT_STORE,
  EDIT_PROJECT_VERSION,
  PROJECT_FORMAT,
  PROJECT_STORAGE_KEY,
  PROJECT_VERSION,
  loadProject,
  memoryStore,
  parseProject,
  saveProject,
  serializeProject,
} from "../../src/extensions/editor/project-file.ts";

/** 失败时把错误码拿出来（成功就等于判据红了）。 */
function codeOf<T>(r: Result<T, EngineError>): string {
  assert.equal(r.ok, false, "这一步本该失败，却成功了");
  return r.ok ? "" : r.error.code;
}

function projectOf(entries: Array<[string, string]>, current?: string): Project {
  return {
    scenes: entries.map(([name, text]) => ({ name, text })),
    current: current ?? (entries[0]?.[0] ?? ""),
  };
}

/** 一份"像真的"工程：三个场景，文本里带换行、引号、反斜杠与中文。 */
function sample(): Project {
  return projectOf(
    [
      ["main", '{"nodes":[{"name":"草地\\"甲\\"","pos":[1.5,2]}]}\n'],
      ["场景 1", '{"nodes":[]}'],
      ["boss", '{\n  "nodes": [\n    {"name": "墙"}\n  ]\n}'],
    ],
    "场景 1",
  );
}

// ---------------------------------------------------------------- 往返

test("[工程落盘] 往返：三个场景的名字与顺序、当前项、每份文本都逐字节一致", () => {
  const p = sample();
  const r = parseProject(serializeProject(p));
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code}: ${r.error.message}`);
  if (!r.ok) return;
  assert.deepEqual(
    r.value.scenes.map((s) => s.name),
    ["main", "场景 1", "boss"],
  );
  assert.equal(r.value.current, "场景 1");
  // ★ 逐字节，不是"包含"：JSON 转义（引号 / 反斜杠 / 换行）只要吃掉一个字符，
  //   文档就坏了，而"能解析出来"照样成立。
  for (let i = 0; i < p.scenes.length; i++) {
    assert.equal(r.value.scenes[i]?.text, p.scenes[i]?.text, `第 ${String(i + 1)} 份文本变了`);
  }
});

test("★★ 可复现：同一个工程序列化两次一字不差（所以产物里不许写时间戳）", () => {
  const p = sample();
  assert.equal(serializeProject(p), serializeProject(p));
});

test("★ 序列化不改动工程本身（否则存一次盘就把内存里的东西改了）", () => {
  const p = sample();
  const before = JSON.stringify(p);
  serializeProject(p);
  assert.equal(JSON.stringify(p), before);
});

test("★ 产物里带着 format 与 version（否则下次读的人认不出来）", () => {
  const o = JSON.parse(serializeProject(sample())) as Record<string, unknown>;
  assert.equal(o.format, PROJECT_FORMAT);
  assert.equal(o.version, PROJECT_VERSION);
  assert.equal(o.current, "场景 1");
  assert.equal(Array.isArray(o.scenes), true);
  assert.equal((o.scenes as unknown[]).length, 3);
});

test("★ 产物里只有名字与文本，不带节点实例 / 历史 / 选中集", () => {
  const o = JSON.parse(serializeProject(sample())) as { scenes: Array<Record<string, unknown>> };
  assert.deepEqual(Object.keys(o.scenes[0] ?? {}).sort(), ["name", "text"]);
});

// ---------------------------------------------------------------- 坏输入

test("坏输入：不是 JSON ⇒ EDIT.PROJECT_JSON", () => {
  assert.equal(codeOf(parseProject("{")), EDIT_PROJECT_JSON);
  assert.equal(codeOf(parseProject("")), EDIT_PROJECT_JSON);
});

test("坏输入：顶层是数组 ⇒ EDIT.PROJECT_FORMAT（数组也能 JSON.parse，但不是工程）", () => {
  assert.equal(codeOf(parseProject("[]")), EDIT_PROJECT_FORMAT);
  assert.equal(codeOf(parseProject("42")), EDIT_PROJECT_FORMAT);
});

test("坏输入：format 不符 ⇒ EDIT.PROJECT_FORMAT（别把别人的 JSON 当工程装进去）", () => {
  const other = JSON.stringify({ format: "something.else", version: 1, current: "a", scenes: [] });
  assert.equal(codeOf(parseProject(other)), EDIT_PROJECT_FORMAT);
});

test("坏输入：版本不认识 ⇒ EDIT.PROJECT_VERSION（不许假装兼容）", () => {
  const p = JSON.parse(serializeProject(sample())) as Record<string, unknown>;
  p.version = PROJECT_VERSION + 1;
  assert.equal(codeOf(parseProject(JSON.stringify(p))), EDIT_PROJECT_VERSION);
});

test("坏输入：scenes 不是数组 ⇒ EDIT.PROJECT_SHAPE", () => {
  const p = JSON.parse(serializeProject(sample())) as Record<string, unknown>;
  p.scenes = { main: "x" };
  assert.equal(codeOf(parseProject(JSON.stringify(p))), EDIT_PROJECT_SHAPE);
});

test("★★ 坏输入：一个场景都没有 ⇒ EDIT.PROJECT_SHAPE（空工程等于「没有文档可编辑」）", () => {
  const p = JSON.parse(serializeProject(sample())) as Record<string, unknown>;
  p.scenes = [];
  assert.equal(
    codeOf(parseProject(JSON.stringify(p))),
    EDIT_PROJECT_SHAPE,
    "空 scenes 如果没有被单独拦住，会走到「当前项不在列表里」—— 报错位置就骗人了",
  );
});

test("坏输入：某个场景缺 text ⇒ EDIT.PROJECT_SHAPE（不是「当成空文档」）", () => {
  const p = JSON.parse(serializeProject(sample())) as { scenes: Array<Record<string, unknown>> };
  delete p.scenes[1]?.text;
  assert.equal(codeOf(parseProject(JSON.stringify(p))), EDIT_PROJECT_SHAPE);
});

test("坏输入：某个场景没有名字 ⇒ EDIT.PROJECT_SHAPE", () => {
  const p = JSON.parse(serializeProject(sample())) as { scenes: Array<Record<string, unknown>> };
  p.scenes[0]!.name = "";
  assert.equal(codeOf(parseProject(JSON.stringify(p))), EDIT_PROJECT_SHAPE);
});

test("★★ 坏输入：current 不在列表里 ⇒ EDIT.PROJECT_CURRENT（别自动改成第一个）", () => {
  const p = JSON.parse(serializeProject(sample())) as Record<string, unknown>;
  p.current = "已经删掉的场景";
  assert.equal(
    codeOf(parseProject(JSON.stringify(p))),
    EDIT_PROJECT_CURRENT,
    "自动改成第一个的后果：打开之后人在「main」上编辑，而以为是「已经删掉的场景」",
  );
});

test("★★ 坏输入：两个同名场景 ⇒ EDIT.PROJECT_DUP（重名之后切换只命中第一份）", () => {
  const p = projectOf([
    ["main", "{}"],
    ["main", "{\"a\":1}"],
  ]);
  p.current = "main";
  assert.equal(codeOf(parseProject(serializeProject(p))), EDIT_PROJECT_DUP);
});

test("★ 失败时不返回「半个工程」（要么整个成功，要么什么都没有）", () => {
  const r = parseProject('{"format":"dst.editor.project","version":1,"current":"x","scenes":[]}');
  assert.equal(r.ok, false);
  assert.equal("value" in r, false, "失败分支里带回了 value —— 用的人一定会去读它");
});

// ---------------------------------------------------------------- 介质

test("介质：存过再读，工程一模一样；没存过是 null（不是错误）", () => {
  const store = memoryStore();
  const p = sample();
  const w = saveProject(store, p);
  assert.equal(w.ok, true, w.ok ? "" : `${w.error.code}: ${w.error.message}`);
  if (w.ok) assert.equal(w.value.scenes, 3);

  const r = loadProject(store);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  assert.notEqual(r.value, null);
  assert.equal(r.value?.project.current, "场景 1");
  assert.equal(r.value?.bytes, new TextEncoder().encode(store.peek() ?? "").length);

  const empty = loadProject(memoryStore());
  assert.equal(empty.ok, true);
  assert.equal(empty.ok ? empty.value : "×", null, "没存过必须是 null —— 空串会让读取去跑解析然后报「不是 JSON」");
});

test("★ 介质：写入抛异常 ⇒ EDIT.PROJECT_STORE（不许当成存好了）", () => {
  const store = {
    read: () => null,
    write: () => {
      throw new Error("QuotaExceededError（夹具）");
    },
  };
  assert.equal(codeOf(saveProject(store, sample())), EDIT_PROJECT_STORE);
});

test("★ 介质：读取抛异常 ⇒ EDIT.PROJECT_STORE", () => {
  const store = {
    read: (): string | null => {
      throw new Error("SecurityError（夹具）");
    },
    write: () => undefined,
  };
  assert.equal(codeOf(loadProject(store)), EDIT_PROJECT_STORE);
});

test("★★ 介质：存档坏了要报错，但**不许把它清掉**（人还要靠它修）", () => {
  const corrupt = '{"format":"dst.editor.project","version":1,"current":"nope","scenes":[{"name":"main","text":"{}"}]}';
  const store = memoryStore(corrupt);
  assert.equal(codeOf(loadProject(store)), EDIT_PROJECT_CURRENT);
  assert.equal(store.peek(), corrupt, "读失败时把存档写掉了 —— 用户的工程就这么没了");
});

test("介质键名带版本后缀（升版本时不能与旧键共用）", () => {
  assert.equal(PROJECT_STORAGE_KEY, `dst.editor.project.v${String(PROJECT_VERSION)}`);
});
