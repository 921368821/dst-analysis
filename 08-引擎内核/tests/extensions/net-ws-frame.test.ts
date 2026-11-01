/**
 * RFC 6455 帧编解码的判据（批169）
 *
 * ★ 为什么这一层值得单独一组判据：网关唯一的输入就是字节流，而
 *   "读帧"这件事的失败方式是**安静**的 —— 少算一个长度字节会让后面每一帧都错位，
 *   而错位之后的表现是"JSON 读不出来"，离真正的原因差着三层。
 *
 * ★ 每条"错误路径"都配一条语料（RSV、分片、超长、坏 UTF-8）：这些分支在真实
 *   浏览器上**永远不会走到**（Chromium 的帧总是规规矩矩），所以它们只可能被
 *   手搓的字节覆盖 —— 而对手搓字节的处理，正是网关与"一个随便什么 TCP 连接"的界线。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { FrameReader, MAX_PAYLOAD, Opcode, decodeText, encodeFrame, encodeText } from "../../src/extensions/net/ws-frame.ts";

/** 喂一整块，取所有能取出的帧。 */
function drain(bytes: Uint8Array): { frames: { opcode: number; payload: Uint8Array }[]; error: string | null } {
  const r = new FrameReader();
  r.push(bytes);
  return drainReader(r);
}

function drainReader(r: FrameReader): { frames: { opcode: number; payload: Uint8Array }[]; error: string | null } {
  const frames: { opcode: number; payload: Uint8Array }[] = [];
  for (;;) {
    const f = r.next();
    if (f === null) break;
    frames.push(f);
  }
  return { frames, error: r.error() };
}

const str = (b: Uint8Array): string => new TextDecoder().decode(b);

// ---------------------------------------------------------------- ① 往返

test("★ 三档长度都往返：<126 / 126..65535 / ≥65536（长度字段的写法各不相同）", () => {
  // 125、126、65535、65536 正好落在两个分支的边界上：漏掉任意一边，
  // 症状都是"小消息正常、大快照一来就断"，而小消息永远测不出来。
  for (const n of [0, 1, 125, 126, 127, 65535, 65536, 70000]) {
    const payload = new Uint8Array(n);
    for (let i = 0; i < n; i++) payload[i] = i & 0xff;
    const { frames, error } = drain(encodeFrame(Opcode.Binary, payload));
    assert.equal(error, null, `长度 ${String(n)} 编码出错`);
    assert.equal(frames.length, 1, `长度 ${String(n)} 应该只有一个帧`);
    assert.equal(frames[0]?.opcode, Opcode.Binary);
    assert.equal(frames[0]?.payload.length, n);
    // 逐字节比对：长度字段写错时"长度对、内容错"也是可能的（比如少读一个掩码字节）
    for (let i = 0; i < n; i++) {
      if (frames[0]?.payload[i] !== (i & 0xff)) {
        assert.fail(`长度 ${String(n)} 的第 ${String(i)} 字节不对`);
      }
    }
  }
});

test("★ 掩码往返：客户端口径（mask=true）解出来必须与原字节逐字节一致", () => {
  const payload = new TextEncoder().encode("你好，世界 hello");
  const { frames, error } = drain(encodeFrame(Opcode.Text, payload, true));
  assert.equal(error, null);
  assert.equal(frames.length, 1);
  assert.equal(str(frames[0]?.payload ?? new Uint8Array(0)), "你好，世界 hello");
});

test("★★ 分段喂：一次一个字节也必须拼出同一帧（TCP 不保证一次 data 就是一帧）", () => {
  // 这条是整份文件里最重要的：本地环回上第一次就能过，跨机器时大快照必然被拆成
  // 多个 TCP 段。只处理"完整缓冲"的实现在这里会一帧都取不出来。
  const text = "x".repeat(300);
  const bytes = encodeText(text);
  const r = new FrameReader();
  const got: string[] = [];
  for (const b of bytes) {
    r.push(new Uint8Array([b]));
    for (;;) {
      const f = r.next();
      if (f === null) break;
      got.push(str(f.payload));
    }
  }
  assert.equal(got.length, 1, "逐字节喂应该也只是一帧");
  assert.equal(got[0], text);
  assert.equal(r.error(), null);
});

test("★ 两帧粘在一起（同一个 TCP 段里）：一次 push 要能取出两帧", () => {
  const a = encodeText("one");
  const b = encodeText("two");
  const both = new Uint8Array(a.length + b.length);
  both.set(a, 0);
  both.set(b, a.length);
  const { frames } = drain(both);
  assert.deepEqual(frames.map((f) => str(f.payload)), ["one", "two"]);
});

// ---------------------------------------------------------------- ② 分片

test("★ 分片重组：FIN=0 的起始帧 + 续帧，拼成一条完整消息", () => {
  const r = new FrameReader();
  // 手搓：起始帧（FIN=0, opcode=Text）
  const first = encodeText("hello ");
  first[0] = (first[0] ?? 0) & 0x7f; // 清掉 FIN
  const second = encodeText("world");
  second[0] = ((second[0] ?? 0) & 0x80) | Opcode.Continuation; // FIN=1 + continuation
  r.push(first);
  const afterFirst = drainReader(r);
  assert.equal(afterFirst.frames.length, 0, "还没收到 FIN，不该吐帧");
  // ★ 注意 `drainReader` 已经把 first 消费掉了（返回空数组），续帧要接着 push。
  r.push(second);
  const afterSecond = drainReader(r);
  assert.equal(afterSecond.frames.length, 1);
  assert.equal(str(afterSecond.frames[0]?.payload ?? new Uint8Array(0)), "hello world");
});

test("★ 控制帧可以插在分片消息中间（RFC 允许），且不能污染重组缓冲", () => {
  const r = new FrameReader();
  const first = encodeText("AB");
  first[0] = (first[0] ?? 0) & 0x7f;
  const last = encodeText("CD");
  last[0] = ((last[0] ?? 0) & 0x80) | Opcode.Continuation;
  r.push(first);
  assert.equal(drainReader(r).frames.length, 0);
  r.push(encodeFrame(Opcode.Ping, new Uint8Array(0)));
  const mid = drainReader(r);
  // ★ 关键：ping 必须**单独**吐出来，而不是被当成 "ABCD" 的一部分。
  assert.equal(mid.frames.length, 1);
  assert.equal(mid.frames[0]?.opcode, Opcode.Ping);
  r.push(last);
  const done = drainReader(r);
  assert.equal(done.frames.length, 1);
  assert.equal(
    str(done.frames[0]?.payload ?? new Uint8Array(0)),
    "ABCD",
    "ping 被当成分片的一部分了 ⇒ 载荷字节序错乱，最后只会报「JSON 读不出来」",
  );
});

test("★ 不属于任何消息的续帧 = 协议错误（不是「忽略掉继续」）", () => {
  const stray = encodeText("x");
  stray[0] = ((stray[0] ?? 0) & 0x80) | Opcode.Continuation;
  const { error } = drain(stray);
  assert.notEqual(error, null, "孤立的续帧必须报错：容忍它等于让下一条消息从半截开始");
});

// ---------------------------------------------------------------- ③ 错误路径

test("★★ 控制帧不许分片、载荷不许超过 125（对端实现有问题，不是我们该容忍的）", () => {
  // 分片的 ping
  const ping = encodeFrame(Opcode.Ping, new Uint8Array(0));
  ping[0] = (ping[0] ?? 0) & 0x7f;
  assert.notEqual(drain(ping).error, null, "分片的控制帧必须报错");

  // 126 字节的 ping
  const big = encodeFrame(Opcode.Ping, new Uint8Array(126));
  assert.notEqual(drain(big).error, null, "控制帧载荷 126 字节必须报错");
});

test("★ RSV 位非零 = 协议错误（我们没协商任何扩展）", () => {
  const f = encodeText("x");
  f[0] = (f[0] ?? 0) | 0x40; // RSV1
  assert.notEqual(drain(f).error, null);
});

test("★★ 声称超长的帧头要**在读载荷之前**就被拒（10 个字节不该能吃掉 2GB 内存）", () => {
  // 手搓一个 127 长度形态的帧头，长度字段写 MAX_PAYLOAD + 1，载荷一个字节都不给。
  const head = new Uint8Array(10);
  head[0] = 0x80 | Opcode.Text;
  head[1] = 127;
  const len = MAX_PAYLOAD + 1;
  head[6] = (Math.floor(len / 2 ** 24) & 0xff) >>> 0;
  head[7] = (Math.floor(len / 65536) & 0xff) >>> 0;
  head[8] = (Math.floor(len / 256) & 0xff) >>> 0;
  head[9] = len & 0xff;
  const { error } = drain(head);
  assert.notEqual(error, null, "只靠帧头就该拒 —— 等载荷到齐再判断等于让对端决定我们吃多少内存");
});

test("★ 坏 UTF-8 读成 null（而不是替换成 U+FFFD 让坏字节混进 JSON）", () => {
  // 0xFF 在 UTF-8 里永远是非法起始字节
  assert.equal(decodeText(new Uint8Array([0xff, 0xfe])), null);
  assert.equal(decodeText(new TextEncoder().encode("好的")), "好的");
});

test("★ 出错之后这个读取器就废了（不会「下一帧又好了」）", () => {
  const r = new FrameReader();
  const bad = encodeText("x");
  bad[0] = (bad[0] ?? 0) | 0x40; // RSV1
  r.push(bad);
  assert.equal(r.next(), null);
  assert.notEqual(r.error(), null);
  // 再喂一条好的，也不该吐出来 —— 出了协议错误的连接没有"之后"
  r.push(encodeText("ok"));
  assert.equal(r.next(), null);
});
