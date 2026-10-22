/**
 * 全部测试入口
 *
 * 用显式 import 而不是 glob：Node 的 test runner 对 `.ts` 的 glob 支持不稳定，
 * 而"显式列出"还有一个好处 —— 新增测试文件必须在这里登记，
 * 于是"某个测试文件从没被跑过"这种事不会静默发生。
 */

import "./arch/layers.test.ts";
import "./core/scheduler.test.ts";
import "./core/scene.test.ts";
import "./core/module.test.ts";
import "./core/asset.test.ts";
import "./core/serialization.test.ts";
import "./core/render.test.ts";
import "./core/physics.test.ts";
import "./core/scene-io.test.ts";
import "./contract/gfx.contract.ts";
import "./contract/webgl2.test.ts";
