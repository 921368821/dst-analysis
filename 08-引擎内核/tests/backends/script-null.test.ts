/**
 * null 脚本后端
 *
 * null 的职责是"诚实地说不能执行"，所以这里的断言都围绕**不假装**：
 *   · caps 明确 executes=false / version=null；
 *   · loadModule 只登记、不执行；call 一律 NOT_SUPPORTED；
 *   · 调用计数照实记（诊断"宿主到底试着调了多少次"），不是静默吞掉。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { NullScriptRuntime, nullScriptBackend } from "../../src/backends/script-null/runtime.ts";
import { ScriptErrorCode } from "../../src/platform/script/runtime.ts";
import { runScriptContract } from "../contract/script.contract.ts";

const target = {
  async make(): Promise<NullScriptRuntime> {
    const r = nullScriptBackend.create();
    if (!r.ok) throw new Error("null 后端创建失败：" + r.error.message);
    return r.value as NullScriptRuntime;
  },
};

// 降级契约（executes=false 那条分支）
await runScriptContract("null", target);

test("[null] 能力描述：没有语言版本、不能打断、不能宿主调用", () => {
  const rt = new NullScriptRuntime();
  assert.deepEqual(rt.caps, {
    language: "none",
    version: null,
    interruptible: false,
    hostCalls: false,
    executes: false,
  });
  rt.dispose();
});

test("[null] 加载历史记录字节数（热重载的重复项也留着，可诊断）", async () => {
  const rt = new NullScriptRuntime();
  await rt.loadModule("a", "return 1");
  await rt.loadModule("a", "return 22");
  await rt.loadModule("b", "return 333");
  assert.deepEqual(
    rt.history().map((h) => [h.name, h.bytes]),
    [
      ["a", 8],
      ["a", 9],
      ["b", 10],
    ],
  );
  assert.equal(rt.stats().modules, 2, "同名只算一个当前模块");
  rt.dispose();
});

test("[null] call 每次都记 calls/errors —— 不能静默吞掉宿主的一次尝试", async () => {
  const rt = new NullScriptRuntime();
  const a = await rt.call("f");
  const b = await rt.call("g", [1, 2]);
  for (const r of [a, b]) {
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error.code, ScriptErrorCode.NotSupported);
  }
  assert.deepEqual(rt.stats(), { modules: 0, calls: 2, errors: 2, timeouts: 0 });
  rt.dispose();
});
