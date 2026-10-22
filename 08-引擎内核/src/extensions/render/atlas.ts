/**
 * L4 · 程序化图集
 *
 * ★ 为什么"程序化生成"而不是读一张 PNG：
 *   浏览器 demo 与 headless 判据要能**零外部资产**跑起来。
 *   一张 PNG 会让"跑起来"依赖文件路径、打包、CORS —— 而那些与本项目
 *   要验证的东西（层级、批处理、深度序）无关。
 *   真实项目会换成 `.meta + GUID + importer`（见 ARCHITECTURE §12 阶段 2），
 *   但那时候**接口不变**：`AtlasData` 仍然是"宽高 + 像素 + 帧表"。
 *
 * ★ 帧表用 `u0,v0,u1,v1`（归一化 UV）而不是像素矩形：
 *   渲染层只关心 UV，转成像素 UV 是采样细节。多图集时 uv 还得按图集尺寸归一化，
 *   提前归一化能避免"渲染层到处除以 width"。
 */

export interface AtlasFrame {
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  /** 像素尺寸（用于"按原始比例摆放"的便利计算）。 */
  readonly w: number;
  readonly h: number;
}

export interface AtlasData {
  readonly width: number;
  readonly height: number;
  /** RGBA8，行主序，原点在左上（与 PNG 一致；上传时 GL 的 flip 由调用方决定）。 */
  readonly pixels: Uint8Array;
  readonly frames: ReadonlyMap<string, AtlasFrame>;
}

/** 极简像素画布（只够画色块、圆、三角）。 */
class Pen {
  constructor(
    private readonly px: Uint8Array,
    private readonly W: number,
    private readonly H: number,
  ) {}

  private put(x: number, y: number, r: number, g: number, b: number, a = 255): void {
    if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
    const i = (y * this.W + x) * 4;
    const src = a / 255;
    const dstA = this.px[i + 3]! / 255;
    const outA = src + dstA * (1 - src);
    if (outA <= 0) return;
    this.px[i] = Math.round((r * src + this.px[i]! * dstA * (1 - src)) / outA);
    this.px[i + 1] = Math.round((g * src + this.px[i + 1]! * dstA * (1 - src)) / outA);
    this.px[i + 2] = Math.round((b * src + this.px[i + 2]! * dstA * (1 - src)) / outA);
    this.px[i + 3] = Math.round(outA * 255);
  }

  rect(x: number, y: number, w: number, h: number, c: [number, number, number]): void {
    for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) this.put(i, j, c[0], c[1], c[2]);
  }

  /** 圆（用于石头/浆果）。 */
  disc(cx: number, cy: number, r: number, c: [number, number, number]): void {
    for (let j = -r; j <= r; j++) {
      for (let i = -r; i <= r; i++) {
        if (i * i + j * j <= r * r) this.put(cx + i, cy + j, c[0], c[1], c[2]);
      }
    }
  }

  /** 三角（树冠）。 */
  triangle(x0: number, y0: number, x1: number, y1: number, x2: number, y2: number, c: [number, number, number]): void {
    const minY = Math.min(y0, y1, y2);
    const maxY = Math.max(y0, y1, y2);
    for (let y = minY; y <= maxY; y++) {
      const xs: number[] = [];
      const edges: Array<[number, number, number, number]> = [
        [x0, y0, x1, y1],
        [x1, y1, x2, y2],
        [x2, y2, x0, y0],
      ];
      for (const [ax, ay, bx, by] of edges) {
        if ((ay <= y && by >= y) || (by <= y && ay >= y)) {
          if (Math.abs(by - ay) < 1e-9) {
            xs.push(ax, bx);
          } else {
            xs.push(ax + ((y - ay) / (by - ay)) * (bx - ax));
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
}

/**
 * 生成默认图集（256×256）。
 * 帧：tree（64×96，绿冠 + 褐干）、rock（48×40，灰圆）、
 *      player（32×48，黄身体）、berry（24×24，红点）、
 *      ground（64×64，草色，可平铺）。
 */
export function buildProceduralAtlas(): AtlasData {
  const W = 256;
  const H = 256;
  const px = new Uint8Array(W * H * 4);
  const pen = new Pen(px, W, H);

  const layout: Array<{ name: string; x: number; y: number; w: number; h: number }> = [
    { name: "tree", x: 0, y: 0, w: 64, h: 96 },
    { name: "rock", x: 64, y: 0, w: 48, h: 40 },
    { name: "player", x: 112, y: 0, w: 32, h: 48 },
    { name: "berry", x: 144, y: 0, w: 24, h: 24 },
    { name: "ground", x: 0, y: 96, w: 64, h: 64 },
  ];

  // tree：褐色树干 + 三层绿冠
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);

  // rock：两层灰圆（顶亮底暗）
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);

  // player：身体 + 头 + 眼睛
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);

  // berry：三颗红果
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);

  // ground：草色噪点（用确定的伪随机，保证两次生成逐字节相同）
  let seed = 0x1234567;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  for (let y = 96; y < 160; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
    }
  }

  const frames = new Map<string, AtlasFrame>();
  for (const l of layout) {
    frames.set(l.name, {
      u0: l.x / W,
      v0: l.y / H,
      u1: (l.x + l.w) / W,
      v1: (l.y + l.h) / H,
      w: l.w,
      h: l.h,
    });
  }

  return { width: W, height: H, pixels: px, frames };
}
