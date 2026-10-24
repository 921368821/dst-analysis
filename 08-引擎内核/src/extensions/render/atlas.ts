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

import { PixelFormat, type PixelFormatValue, type TextureWrapValue } from "../../platform/gfx/types.ts";

export interface AtlasFrame {
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  /** 像素尺寸（用于"按原始比例摆放"的便利计算）。 */
  readonly w: number;
  readonly h: number;
}

/**
 * 图集数据。
 *
 * ★ 精度的表达方式是**两个字段 + 一条不变量**，不是一个"支持 16 位"的布尔：
 *   · `format` 缺省视为 `rgba8`：所有既有的调用方（程序化图集、旧测试）不用改；
 *   · `pixels` **永远存在**（8 位视图）：只认 8 位的旧代码、golden 比对、摘要判据
 *     都还能用，且它与 `pixels16` 的关系是钉死的 —— `pixels[i] === round(pixels16[i]/257)`。
 *     没有这条，两份数据会像本仓库那次双 FNV 一样各自漂移，而"图集看起来是对的"。
 *   · 不变量：`format === "rgba16"` ⇒ `pixels16` 必须存在且长度 = `width*height*4`。
 *     没有 pixels16 却说自己是 rgba16，就是"解码器偷偷降采样假装支持"的那种谎。
 *
 * ★ 代价（写清楚，别当它免费）：16 位图集同时持有两份像素 = 12 字节/像素，
 *   是 8 位图集的 3 倍。保留 8 位视图是为了让"只认 pixels"的旧调用方（以及
 *   golden/摘要判据）不必被迫改造；真要省显存，就让合成器出 `precision: 8`。
 */
export interface AtlasData {
  readonly width: number;
  readonly height: number;
  /** RGBA8，行主序，原点在左上（与 PNG 一致；上传时 GL 的 flip 由调用方决定）。 */
  readonly pixels: Uint8Array;
  /** 图集的真实像素格式；缺省 = `rgba8`。 */
  readonly format?: PixelFormatValue;
  /** `format === "rgba16"` 时的全精度像素（RGBA，每通道 0..65535）。 */
  readonly pixels16?: Uint16Array;
  readonly frames: ReadonlyMap<string, AtlasFrame>;
  /**
   * 这一页的采样器环绕方式（缺省 `clamp`）。
   *
   * ★ 为什么它是**页级**属性而不是精灵级：`clamp` 与 `repeat` 是 sampler 参数，
   *   一张纹理一个。精灵想"平铺"（UV 走出 0..1）时，若这一页是 clamp，
   *   GPU 会把边缘像素抻出去 —— 画面表现是"接缝处一条脏边"，
   *   而精灵那一侧的所有数字（UV、尺寸、位置）全是对的。
   *   把它提到页上，渲染模块才能在初始化时/运行时**发现**这种组合
   *   （见 `render-module.ts` 的平铺- clamp 告警），而不是让人靠眼睛找。
   */
  readonly wrap?: TextureWrapValue;
  /**
   * 页名（`Sprite.atlasId` 用它选页）。缺省 = 主图集页。
   *
   * ★ 为什么需要名字而不是下标：组件要能被序列化（存档、编辑器），
   *   而下标会随着"加了一页"而漂移。名字是稳定标识，和 `atlasId` 同一思路。
   */
  readonly name?: string;
}

/** 极简像素画布（只够画色块、圆、三角）。 */
class Pen {
  /** 当前绘制原点：**每个帧块都必须先 `origin()` 到自己的矩形左上角**。 */
  private ox = 0;
  private oy = 0;

  constructor(
    private readonly px: Uint8Array,
    private readonly W: number,
    private readonly H: number,
  ) {}

  /**
   * ★ 这个方法是 T330 顺带抓出来的第二个缺陷的解药：
   *   原来每个帧的绘制用的是**绝对坐标**，而 `layout` 里 rock/player/berry 分别在
   *   x=64/112/144 —— 于是那三帧的图形全被画进了 tree 的矩形（x 0..64），
   *   三帧本身**一个不透明像素都没有**。
   *   症状是"兜底图集里少三类东西"，而所有既有判据（帧在不在、UV 对不对、
   *   尺寸对不对）都是绿的：它们查的是地图，不是地图上有没有东西。
   */
  origin(x: number, y: number): void {
    this.ox = x;
    this.oy = y;
  }

  private put(x: number, y: number, r: number, g: number, b: number, a = 255): void {
    const ax = this.ox + x;
    const ay = this.oy + y;
    if (ax < 0 || ay < 0 || ax >= this.W || ay >= this.H) return;
    const i = (ay * this.W + ax) * 4;
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
    { name: "terrain", x: 64, y: 96, w: 64, h: 64 },
  ];

  // 每一块都先 origin 到自己的矩形：坐标一律写**帧内局部坐标**
  // （否则 rock/player/berry 会画到 tree 的矩形里，见 Pen.origin 的说明）
  const at = (n: string): { x: number; y: number } => {
    const l = layout.find((e) => e.name === n);
    if (l === undefined) throw new Error(`布局里没有帧 "${n}"（内部一致性错误）`);
    return { x: l.x, y: l.y };
  };

  // tree：褐色树干 + 三层绿冠
  pen.origin(at("tree").x, at("tree").y);
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);

  // rock：两层灰圆（顶亮底暗）
  pen.origin(at("rock").x, at("rock").y);
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);

  // player：身体 + 头 + 眼睛
  pen.origin(at("player").x, at("player").y);
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);

  // berry：三颗红果
  pen.origin(at("berry").x, at("berry").y);
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);

  // ground：草色噪点（用确定的伪随机，保证两次生成逐字节相同）
  let seed = 0x1234567;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  pen.origin(at("ground").x, at("ground").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
    }
  }

  /**
   * terrain：**中性灰**噪点，专门给群系着色用。
   *
   * ★ 为什么不是"再来一张草色图"：地形是按群系上色的（草地/沙滩/海/岩石…），
   *   底色如果是绿的，海就会变成"绿 × 蓝 = 墨绿"—— 而这时调色板看起来还挺"自然"，
   *   没人会想到是基色错了。中性灰乘任何颜色都还在那个颜色的色相上，
   *   这是"灰度基色 + 顶点色"这条路子成立的全部前提。
   *
   * ★ 亮度取 ~0.8 而不是 0.5：它是**乘子**。基色 0.5 时，草色 0.42 会被压成 0.21
   *   （看起来像夜里）；0.8 时 `0.8 × 群系色 ≈ 群系色`，调色板写什么就看起来是什么。
   */
  pen.origin(at("terrain").x, at("terrain").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 188 + Math.floor(rnd() * 31);
      pen.rect(x, y, 1, 1, [v, v, v]);
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

// ------------------------------------------------------------------ 瓦片页

/**
 * 从主图集里**抽出**若干帧，各自变成一页独立的 `repeat` 纹理（T288）。
 *
 * ★ 为什么"抽出来"而不是让精灵在大图集上平铺：
 *   大图集里每一帧都有邻居。UV 一旦走出 0..1（平铺），`repeat` 会把**邻居帧**
 *   采进来 —— 画面表现是"地形上每隔几格出现一块树/石头"，而 UV 数字完全正确。
 *   所以能平铺的帧必须**独占一张纹理**：邻居不存在，repeat 才只重复自己。
 *
 * ★ 为什么是拷贝而不是"给主图集也开 repeat"：主图集绝大多数帧（树/石头/玩家）
 *   **永远不该**被平铺，给整张图集开 repeat 等于给那些帧埋一条"抻边"的暗雷。
 *   两页两种 wrap，各管各的。
 *
 * ★ 16 位图集同样抽出 `pixels16`（不是从 8 位视图上转）：`pixels[i] === round(pixels16[i]/257)`
 *   这条不变量必须在每一页上都成立，否则"图集是 16 位"这句话在瓦片页上就成了谎。
 */
export function buildTilePages(main: AtlasData, frameNames: readonly string[]): AtlasData[] {
  const out: AtlasData[] = [];
  for (const name of frameNames) {
    const f = main.frames.get(name);
    if (f === undefined) continue; // 帧不存在就不建页（可视化桥会为缺帧报错）
    const x0 = Math.round(f.u0 * main.width);
    const y0 = Math.round(f.v0 * main.height);
    const w = f.w;
    const h = f.h;
    const px = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const from = ((y0 + y) * main.width + x0) * 4;
      px.set(main.pixels.subarray(from, from + w * 4), y * w * 4);
    }
    let page: AtlasData = {
      width: w,
      height: h,
      pixels: px,
      wrap: "repeat",
      name: tilePageName(name),
      frames: new Map<string, AtlasFrame>([[name, { u0: 0, v0: 0, u1: 1, v1: 1, w, h }]]),
    };
    if (main.pixels16 !== undefined) {
      const p16 = new Uint16Array(w * h * 4);
      for (let y = 0; y < h; y++) {
        const from = ((y0 + y) * main.width + x0) * 4;
        p16.set(main.pixels16.subarray(from, from + w * 4), y * w * 4);
      }
      page = { ...page, format: PixelFormat.RGBA16, pixels16: p16 };
      // 8 位视图由 16 位**派生**（与合成器同一口径），不是两份各自拼
      for (let i = 0; i < px.length; i++) px[i] = Math.round(p16[i]! / 257);
    }
    out.push(page);
  }
  return out;
}

/** 瓦片页的页名（`Sprite.atlasId` 用它选页）。集中一处，宿主与判据都不写死字符串。 */
export function tilePageName(frame: string): string {
  return `${frame}.tile`;
}
