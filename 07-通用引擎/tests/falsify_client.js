// falsify_client.js —— **变异测试**：证明客户端判据「凭什么绿」
//
// ★ 为什么要这个文件（本工程的老母题）：
//   「检查写好了」≠「检查生效过」。一条判据可能因为**指向了错的字符串**、
//   **自满足**、或**根本没人调用**而永远绿 —— 这类假绿本工程已经付出过代价
//   （`audit_fixes.py` 里那条「指向消息文本」的检查一改措辞就断；
//     `selftest()` 曾把真实证据删掉后照样报 ✔）。
//   ⇒ 唯一的机械发现方式是：**把被测的东西故意改坏，看它是否真的变红**。
//
// ★ 做法：把 `rt/client.html` 逐条打上一个「语义篡改」，重跑 `test_client.js`，
//   要求**指定的那条判据**变红。文件在 finally 里一定被还原（哪怕中途崩掉）。
//
// ★★ 关键纪律：如果某个篡改的**锚点串**在源码里找不到了（有人重构过），
//   本脚本必须**报错**而不是跳过 —— 静默跳过就等于「这条判据从此没人守」，
//   而那正是最坏的情形（绿着，但其实什么都没验）。
//
// 用法：node tests/falsify_client.js
// 退出码：0 = 每条篡改都被它该被抓住的判据抓住了
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const CLIENT = path.join(__dirname, '..', 'rt', 'client.html');
const TESTER = path.join(__dirname, 'test_client.js');
const NODE = process.execPath;

// ---------------------------------------------------------------- 篡改清单
// from/to：精确子串替换（各必须**恰好出现一次**）
// expect：**必须**因此变红的判据名子串
const MUTATIONS = [
  {
    name: '摇杆不再复用 setKey，自己发帧',
    expect: ['走同一条路'],
    // ★★ 这条锚点**换过一次**（2026-10-18）。原来写的是**单行**版本：
    //     `setKey('left', kx < 0, 'stick'); setKey('right', kx > 0, 'stick');`
    //   ——那正是「摇杆左右手写一份」的那个**老 bug 的写法**。这一轮把它修好之后
    //   （四个方向一律走 setKey），锚点自然就不存在了 ⇒ 工具如实报
    //   「锚点串在源码里出现 0 次」，而我第一眼差点读成「判据失效」。
    //   ⇒ 现在是**反向**做：把左右两行换回「手写发帧」（不记 seq、不记来源、不反向清除），
    //     看 F20/F21/F22/F26/F27 会不会真的叫。等价于「把当年那个 bug 重新装回去」。
    from: "  setKey('left',  kx < 0, 'stick');\n" +
          "  setKey('right', kx > 0, 'stick');",
    to: "  if (kx < 0 && !keys.left) { keys.left = 1; ws.send(JSON.stringify({ k: 'left', v: 1 })); }\n" +
        "  if (kx > 0 && !keys.right) { keys.right = 1; ws.send(JSON.stringify({ k: 'right', v: 1 })); }",
  },
  {
    name: '摇杆去掉死区',
    expect: ['八向 + 死区'],
    from: 'const kx = Math.abs(ux) < STICK_DEAD ? 0 : (ux < 0 ? -1 : 1);',
    to:   'const kx = Math.abs(ux) < 0 ? 0 : (ux < 0 ? -1 : 1);',
  },
  {
    name: '抬起摇杆时不归零',
    expect: ['松开 / pointercancel'],
    from: "  if (p.role === 'stick' && PAD.stick.id === id) { PAD.stick.id = null; stickKeys(0, 0); }",
    to:   "  if (p.role === 'stick' && PAD.stick.id === id) { PAD.stick.id = null; }",
  },
  {
    name: '动作键只改状态、不发动作',
    expect: ['动作键 = actKeyDown'],
    from: "if (role === 'act') { PAD.act.id = id; actKeyDown(); }",
    to:   "if (role === 'act') { PAD.act.id = id; }",
  },
  {
    name: '面板关闭时仍然劫持左下角（丢掉 PAD.on 判据）',
    expect: ['面板**关**时'],
    from: '  if (PAD.on) {\n    const role = padHit(x, y);',
    to:   '  if (true) {\n    const role = padHit(x, y);',
  },
  {
    name: '双指捏合时不关掉平移',
    expect: ['双指捏合缩放'],
    from: '  if (cams.length >= 2) { pinchZoom(cams[0], cams[1]); return true; }',
    to:   '  if (cams.length >= 2) { pinchZoom(cams[0], cams[1]); }',
  },
  {
    name: 'pointerdown 监听器根本没挂上',
    expect: ['事件**真的挂在**'],
    from: "cv.addEventListener('pointerdown', e => {",
    to:   "if (0) cv.addEventListener('pointerdown', e => {",
  },
  {
    name: '方向键退回 0/1 记账（不再按来源计数）',
    expect: ['按「来源」记账'],
    from: '  const now = s.size > 0;\n  if (now === was) return false;      // 有效状态没变 ⇒ 不发帧（比如 ArrowRight 松开但 KeyD 还按着）',
    to:   '  const now = s.size > 0;',
  },
  {
    // ★ 命名按**量出来的事实**：客户端重发**不是**「打断引擎循环」（那是猜的），
    //   它真正的代价是与服务端 1 s 节拍**叠加** —— 实测砍一棵 15 点的树要
    //   30 次 push / 21 s，而只让服务端一节拍是 15 次 push / 15 s（各 3 遍完全一致）。
    name: '把客户端「按住每 0.7 s 重发 act」加回来（多一个节拍主人，白打一半）',
    expect: ['F18 交互'],
    from: '  // ★ 这里**故意**什么都不做：按住 ≠ 重发（见上方实测：节拍只该有一个主人）。\n'
        + '  //   留着这个函数是因为它还要负责「每 0.5 s 拉一次目标」与「挑最近的那个」。',
    // ★ 篡改里把 nextAt 也一并初始化：这样「锚点」不依赖 `ACT.nextAt` 这个字段还在不在，
    //   判据抓不抓得住完全取决于**有没有重发**这个行为（而不是取决于字段声明）。
    to:   '  ACT.nextAt = ACT.nextAt || 0;\n'
        + '  if (ACT.held && ACT.pick && now >= ACT.nextAt) { sendCmd({ cmd: "act", v: ACT.pick.id }); ACT.nextAt = now + 700; ACT.sent++; }',
  },
  {
    name: '把「选中目标」退回「永远作用于最近的那个」',
    expect: ['F29 选中目标'],
    from: '  if (ACT.pickId !== null) {\n'
        + '    ACT.pick = ACT.targets.find((t) => t.id === ACT.pickId) || null;\n'
        + '    if (!ACT.pick) ACT.pickId = null;                     // 目标没了 ⇒ 明确放弃选择\n'
        + '  }\n'
        + '  if (!ACT.pick) ACT.pick = ACT.targets.length ? ACT.targets[0] : null;',
    to:   '  ACT.pick = ACT.targets.length ? ACT.targets[0] : null;\n'
        + '  ACT.pickId = null;',
  },
  {
    name: '把「找不到自己」的 1.5 s 宽限去掉（单帧抖动就报警）',
    expect: ['F30'],
    from: '  return (now - selfSeenAt) > 1500;',
    to:   '  return true;',
  },
  {
    name: '把所有实体都裁掉（帧率照样很高，但屏幕是空的）',
    expect: ['F31 画面'],
    from: '      if (sx < -40 || sy < -40 || sx > cv.width + 40 || sy > cv.height + 40) continue;',
    to:   '      if (true) continue;',
  },
  // ★ 反向对照：这条篡改**不该**影响任何客户端判据（它只动注释）——
  //   如果它让判据变红，说明判据在**读注释**而不是读行为。
  {
    name: '（对照）只改注释，不该有任何判据变红',
    expect: [],
    from: '// ---------------------------------------------------------------- 触屏 / 指针（P23）',
    to:   '// ---------------------------------------------------------------- 触屏 / 指针（P23）[注释改过了]',
  },
];

// ---------------------------------------------------------------- 跑一次测试
function runTests() {
  let out = '';
  try {
    out = execFileSync(NODE, [TESTER], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    out = (e.stdout || '') + (e.stderr || '');
  }
  const red = [], green = [];
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^ {2}([✔✘]) (.+?)(?: {2}|$)/);
    if (!m) continue;
    (m[1] === '✘' ? red : green).push(m[2]);
  }
  return { red, green, out };
}

// ---------------------------------------------------------------- 主流程
const original = fs.readFileSync(CLIENT, 'utf8');
console.log('═'.repeat(74));
console.log('  客户端判据的**变异测试**（把实现改坏，看判据是否真的变红）');
console.log('═'.repeat(74));

let bad = 0;
try {
  const base = runTests();
  console.log(`  基线：${base.green.length} 通过 / ${base.red.length} 失败` + (base.red.length ? '  ⚠ 基线就不干净，下面的结论不可信' : ''));
  if (base.red.length) { bad++; console.log('  ✘ 基线有红项：' + base.red.join(' | ')); }

  for (const mu of MUTATIONS) {
    const n = original.split(mu.from).length - 1;
    if (n !== 1) {
      bad++;
      console.log(`  ✘ [${mu.name}] 锚点串在源码里出现 ${n} 次（要求恰好 1 次）—— 代码被重构过，`
                + '这条篡改已失效，必须更新锚点（**不许静默跳过**）');
      continue;
    }
    fs.writeFileSync(CLIENT, original.replace(mu.from, mu.to));
    let res;
    try { res = runTests(); } finally { fs.writeFileSync(CLIENT, original); }
    const hit = mu.expect.filter((e) => res.red.some((r) => r.includes(e)));
    const miss = mu.expect.filter((e) => !res.red.some((r) => r.includes(e)));
    if (mu.expect.length === 0) {
      // 对照：期望零红
      if (res.red.length) {
        bad++;
        console.log(`  ✘ [${mu.name}] 本该零红，却红了 ${res.red.length} 条：` + res.red.join(' | '));
      } else console.log(`  ✔ [${mu.name}] 红 0 条（正确地不受影响）`);
    } else if (miss.length) {
      bad++;
      console.log(`  ✘ [${mu.name}] 篡改后**没被抓住**：期望红「${miss.join('、')}」`
                + `，实际只红了 ${res.red.length ? res.red.join(' | ') : '（无）'}`);
    } else {
      console.log(`  ✔ [${mu.name}] 被抓住 → ${hit.join('、')}`
                + `（连带红 ${res.red.length - hit.length} 条）`);
    }
  }
} finally {
  fs.writeFileSync(CLIENT, original);       // ★ 无论如何都还原
}

console.log('\n  结果：' + (bad === 0 ? '✔ 每条篡改都被对应的判据抓住'
                                       : '✘ ' + bad + ' 处判据失效或锚点过期'));
process.exit(bad === 0 ? 0 : 1);
