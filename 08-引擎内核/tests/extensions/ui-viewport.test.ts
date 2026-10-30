/**
 * L4 · UI 视口判据（坐标与缩放适配）
 *
 * 这一层的缺陷几乎都是"在某个分辨率上才错"，所以判据必须**同时**断言
 * scale、可参考矩形、以及"设计坐标 → 裁剪空间"的落点。
 * 只断言 scale 不够：`anchorRect` 用错（fill 与 expand 的唯一差别）时 scale 完全一样。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { UiScaleMode, UiViewport } from "../../src/extensions/ui/viewport.ts";

const near = (a: number, b: number, msg?: string): void => {
  assert.ok(Math.abs(a - b) < 1e-9, msg ?? `${a} 应等于 ${b}`);
};

function vp(mode: (typeof UiScaleMode)[keyof typeof UiScaleMode], w = 960, h = 540): UiViewport {
  const v = new UiViewport({ designWidth: w, designHeight: h, scaleMode: mode });
  return v;
}

test("fit：取 min，整块设计区可见，屏幕范围比设计框大（多出黑边）", () => {
  const v = vp(UiScaleMode.Fit);
  v.setScreen(1000, 540); // 宽出来 40 像素
  near(v.scale, 1);
  const r = v.screenRect;
  near(r.x, -20, "多出的 40 像素左右各分 20 ⇒ 屏幕从 -20 开始");
  near(r.width, 1000);
  near(r.height, 540);
});

test("fill：取 max，屏幕范围比设计框小（裁边），锚点参考仍是设计框", () => {
  const v = vp(UiScaleMode.Fill);
  v.setScreen(1000, 540);
  near(v.scale, 1000 / 960);
  const r = v.screenRect;
  near(r.height, 540 / (1000 / 960), "竖直方向被裁掉一点");
  assert.ok(r.height < 540);
  // ★ 这是 fill 与 expand 的唯一差别：锚点参考区
  near(v.anchorRect.width, 960, "fill 的锚点贴在**设计框**边界上");
  near(v.anchorRect.x, 0);
});

test("★ expand：与 fit 同缩放，但锚点参考扩到整屏（超宽屏上 HUD 贴屏幕边而非设计框）", () => {
  const fit = vp(UiScaleMode.Fit);
  fit.setScreen(1400, 540);
  const expand = vp(UiScaleMode.Expand);
  expand.setScreen(1400, 540);
  const fill = vp(UiScaleMode.Fill);
  fill.setScreen(1400, 540);

  near(expand.scale, fit.scale, "两者都用 min 缩放：整框可见");
  assert.ok(expand.scale < fill.scale, "fill 用 max，铺满");

  // 超宽屏下屏幕范围比设计框宽 —— 这正是「扩展」的含义
  assert.ok(expand.anchorRect.width > 960, "expand 的参考矩形必须比设计框大，否则扩展不存在");
  near(expand.anchorRect.width, 1400 / expand.scale);
  near(fit.anchorRect.width, 960, "fit 锁在设计框内");
  near(fill.anchorRect.width, 960);
  // ★ 反证：如果 expand 与 fit 返回同一个参考矩形，这条判据必须红
  assert.notEqual(expand.anchorRect.width, fit.anchorRect.width);
});

test("screenToDesign / designToScreen 互为逆运算（含 dpr）", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(800, 450, 2); // CSS 800×450、物理 1600×900
  near(v.pixelWidth, 1600);
  near(v.pixelHeight, 900);
  for (const p of [
    { x: 0, y: 0 },
    { x: 800, y: 450 },
    { x: 123.5, y: 67.25 },
  ]) {
    const d = v.screenToDesign(p.x, p.y);
    const back = v.designToScreen(d.x, d.y);
    near(back.x, p.x);
    near(back.y, p.y);
  }
});

test("屏幕中心对应设计框中心（三种模式都必须成立）", () => {
  for (const mode of [UiScaleMode.Fit, UiScaleMode.Fill, UiScaleMode.Expand]) {
    const v = vp(mode);
    v.setScreen(1234, 567);
    const d = v.screenToDesign(617, 283.5);
    near(d.x, 480, `${mode}：屏幕中心的 x 应是设计宽的一半`);
    near(d.y, 270);
  }
});

test("★ UI 相机是纯 2D：tiltY 恒为 1，把字压扁的实现在这里红", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(1000, 540);
  assert.equal(v.camera.tiltY, 1, "tiltY≠1 会把所有文字压成扁的");
  near(v.camera.zoom, v.scale, "相机的 zoom 就是设计→屏幕的缩放");
});

test("相机投影：设计框左上角落到 NDC 左上，右下落到右下（fit 下左右留边）", () => {
  const v = vp(UiScaleMode.Fit);
  v.setScreen(1000, 540);
  const tl = v.camera.project(0, 0);
  const br = v.camera.project(960, 540);
  // 竖直方向恰好铺满 ⇒ ±1；水平方向多出 40 像素 ⇒ 不到 ±1
  //
  // ★ 这条判据的符号曾经写反过，而且**一直是绿的**（批115 修镜像时发现）：
  //   旧版断言 `tl.y = -1 / br.y = +1`，理由是"NDC 的 -1 在上"。
  //   但在裁剪空间里 **+y 朝上**（`SPRITE_VS` 直接把位置写进 gl_Position），
  //   所以 -1 是**屏幕底部**。旧断言等于要求"设计左上角落到屏幕左下角"，
  //   正好把 UI 整棵树上下镜像那个缺陷钉成了契约 —— 于是布局层所有判据
  //   都绿，只有像素级判据能把这件事抓出来（批115 就是被它抓到的）。
  near(tl.y, 1, "设计 (0,0) 是左上角 ⇒ 裁剪空间 +1（上）");
  near(br.y, -1, "设计 (960,540) 是右下角 ⇒ 裁剪空间 −1（下）");
  near(tl.x, -0.96, "(0−480)×1/(1000/2)");
  near(br.x, 0.96);
  assert.ok(tl.x > -1 && br.x < 1, "fit 下设计框不应顶到屏幕左右边");
});

test("安全区：扣在锚点参考矩形内侧，且不超过它的一半", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(960, 540);
  v.setSafeArea({ top: 40, bottom: 20, left: 10, right: 10 });
  const s = v.safeRect;
  assert.equal(s.y, 40);
  assert.equal(s.height, 540 - 60);
  assert.equal(s.x, 10);
  assert.equal(s.width, 940);

  // 荒谬的安全区（比屏幕还大）不能算出负尺寸
  v.setSafeArea({ top: 9999, bottom: 9999, left: 9999, right: 9999 });
  const s2 = v.safeRect;
  assert.ok(s2.width >= 0 && s2.height >= 0, "夹取后不能出现负尺寸");
});

test("非法输入：设计分辨率 ≤ 0 抛；setScreen(0,0) 保持上一次的值", () => {
  assert.throws(() => new UiViewport({ designWidth: 0, designHeight: 540 }), /设计分辨率/);
  assert.throws(() => new UiViewport({ designWidth: 960, designHeight: -1 }), /设计分辨率/);

  const v = vp(UiScaleMode.Fit);
  v.setScreen(1000, 540);
  const before = v.scale;
  v.setScreen(0, 0);
  assert.equal(v.scale, before, "窗口最小化时报 0 尺寸，不能把 scale 变成 0 或 NaN");
  assert.ok(Number.isFinite(v.scale));
});

test("切换缩放模式不需要重新 setScreen（宿主改设置后立刻生效）", () => {
  const v = vp(UiScaleMode.Fit);
  v.setScreen(1400, 540);
  const fitScale = v.scale;
  v.setScaleMode(UiScaleMode.Fill);
  assert.notEqual(v.scale, fitScale, "fit 用 min、fill 用 max，超宽屏上两者必然不同");
  near(v.scale, 1400 / 960);
});

test("★★ 坐标换算的单位：CSS 边缘 ↔ 设计边缘（dpr=2 时旧实现差一倍，且逆运算判据看不出来）", () => {
  // ★ 这条钉的是**单位**，不是数值关系。旧实现 `screenToDesign` 除的是 `scale`
  //   （绘制像素/设计像素），而入参是宿主给的 CSS 像素 ⇒ dpr=2 的屏上，
  //   屏幕右边（CSS 800）算出来是设计 720 而不是 960：点中间准、点边上偏。
  //   它在旧判据里一直绿 —— 因为 `screenToDesign` 与 `designToScreen` 错同一个倍数，
  //   "互为逆运算"永远成立。判据要有分辨力，就必须断言**端点落在端点上**。
  const v = vp(UiScaleMode.Expand);
  v.setScreen(800, 450, 2); // CSS 800×450、物理 1600×900、设计 960×540
  near(v.scale, 1600 / 960, "渲染侧仍是「绘制像素/设计像素」：相机的 viewport 是物理像素");

  const right = v.screenToDesign(800, 450);
  near(right.x, 960, "CSS 右边缘必须落在设计右边缘");
  near(right.y, 540, "CSS 下边缘必须落在设计下边缘");
  const mid = v.screenToDesign(400, 225);
  near(mid.x, 480);
  near(mid.y, 270);

  const back = v.designToScreen(960, 540);
  near(back.x, 800, "反方向同理：设计右边缘落到 CSS 右边缘");
  near(back.y, 450);
});

test("★★ 安全区入参是 CSS 像素：按 CSS 比例换到设计像素（不是按绘制比例）", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(480, 270, 2); // CSS 宽度是设计宽的一半 ⇒ 1 设计像素 = 0.5 CSS 像素
  v.setSafeArea({ top: 20, right: 10, bottom: 20, left: 10 });
  const r = v.anchorRect;
  const s = v.safeRect;
  near(s.y - r.y, 40, "20 CSS 像素 ⇒ 40 设计像素");
  near(s.x - r.x, 20);
  near(r.width - s.width, 40, "左右各 20 设计像素");
  near(r.height - s.height, 80);
  // ★ 反证：若按绘制比例（scale=1）换算，边距会是 20 而不是 40 —— 少一半。
  assert.notEqual(s.y - r.y, 20);
});

test("★★ 换屏幕尺寸后同一组 CSS inset 必须重算（转屏后停在旧值 = 边距突然变宽/变窄）", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(480, 270, 2);
  v.setSafeArea({ top: 20, right: 0, bottom: 0, left: 0 });
  near(v.safeRect.y - v.anchorRect.y, 40);

  // 同一个设备横过来：CSS 宽度变成 960（= 设计宽）⇒ 1 设计像素 = 1 CSS 像素
  v.setScreen(960, 270, 2);
  near(v.safeRect.y - v.anchorRect.y, 20, "没有重新 setSafeArea，也必须跟着新比例走");
});

test("★★ setSafeArea 立刻生效，且构造参数也生效（不需要等下一次 setScreen）", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(960, 540); // CSS = 设计
  v.setSafeArea({ top: 12, right: 0, bottom: 0, left: 0 });
  near(v.safeRect.y - v.anchorRect.y, 12, "填了数字却没生效，在下次 setScreen 之前完全看不出来");

  const w = new UiViewport({
    designWidth: 960,
    designHeight: 540,
    scaleMode: UiScaleMode.Expand,
    safeArea: { top: 30, right: 0, bottom: 0, left: 0 },
  });
  w.setScreen(960, 540);
  near(w.safeRect.y - w.anchorRect.y, 30, "构造时就给的安全区不能只在字段里躺着");
});

test("安全区的畸形输入：负数与 NaN 一律当 0（负 inset 会把可用区推出屏幕）", () => {
  const v = vp(UiScaleMode.Expand);
  v.setScreen(960, 540);
  v.setSafeArea({ top: -50, right: Number.NaN, bottom: 0, left: 0 });
  const r = v.anchorRect;
  const s = v.safeRect;
  near(s.y, r.y, "负的 top 不能变成「往上扩」");
  near(s.height, r.height);
  near(s.width, r.width);
});
