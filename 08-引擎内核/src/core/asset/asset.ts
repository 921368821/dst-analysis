/**
 * L2 · 资产系统
 *
 * ★★ 这个文件解决的是上一代引擎最贵的一笔债：**资产没有身份**。
 *
 *   上一代的场景文件里写的是 `evergreen\t4.000\t0.000` —— 用 **prefab 名字**
 *   当标识。后果是一整串：
 *     · 改名字 = 删旧建新，所有引用静默失效；
 *     · 不能算依赖（谁用了这张图？），所以不能增量导入、不能分包；
 *     · 不能重命名、不能在两份同名资产间选择；
 *     · "换一张贴图"只能改代码（因为名字是编译进 prefab 表的）。
 *   而它的好处只有一个：读写非常简单。
 *
 *   所以这里引入 `AssetId`（GUID 风格的稳定字符串）作为**唯一身份**：
 *   路径可以改、可以移动、可以有多份镜像，`AssetId` 不变。
 *
 * 三条机制：
 *  ① **引用计数 + 依赖图**：`load` 会递归加载依赖并计数；`release` 减到 0
 *     且无其他资产依赖它时才真正释放。
 *  ② **循环依赖检测**：加载路径上出现环 → 明确报错并点名环上的资产，
 *     而不是栈溢出。资产之间成环在游戏里是真实存在的（A 引用 B 的贴图，
 *     B 引用 A 的动画），必须能诊断。
 *  ③ **卸载顺序 = 依赖的反拓扑**：先卸"用别人的"，再卸"被别人用的"。
 *     顺序错了的症状是"释放纹理时管线还在用它"，随机崩。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";
import type { ChannelLogger } from "../../foundation/log/logger.ts";

/** 稳定身份。约定 8~32 位小写 base36（生成见 `newAssetId`）。 */
export type AssetId = string;

/**
 * 生成新 AssetId。
 * ★ 用**注入的随机**而不是 `crypto.randomUUID()`：导入器需要可复现
 *   （同一份源资产重导入两次应当得到同一个 id，见 `stableIdFromPath`）。
 *   只有在"全新资产、无路径"时才用随机。
 */
export function newAssetId(random: { int(lo: number, hi: number): number }): AssetId {
  let s = "";
  for (let i = 0; i < 12; i++) s += "0123456789abcdefghijklmnopqrstuvwxyz"[random.int(0, 36)];
  return s;
}

/**
 * 从"逻辑路径"派生稳定 id（FNV-1a 32 位，base36）。
 * 用途：**迁移**。老工程用路径当标识，导入器可以据此给每个文件生成稳定 id，
 * 于是"同一个文件重导入两次"不会产生两个 id。
 * 代价：改了逻辑路径就换了 id —— 所以逻辑路径一旦分配就不该改，
 * 需要改就用 `AssetDatabase.remap()` 显式迁移。
 */
export function stableIdFromPath(path: string): AssetId {
  let h = 0x811c9dc5;
  for (let i = 0; i < path.length; i++) {
    h ^= path.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return "p" + h.toString(36).padStart(7, "0");
}

export const AssetType = {
  Texture: "texture",
  Atlas: "atlas",
  Audio: "audio",
  Prefab: "prefab",
  Scene: "scene",
  Script: "script",
  Json: "json",
  Text: "text",
  Binary: "binary",
} as const;
export type AssetTypeValue = (typeof AssetType)[keyof typeof AssetType];

export interface AssetMeta {
  readonly id: AssetId;
  readonly type: string;
  /** 逻辑路径（`mem:/a/b.png`）。可变，**不参与身份**。 */
  readonly path: string;
  /** 导入器版本 + 源文件 hash。变了就要重导入。 */
  readonly importerVersion: number;
  readonly sourceHash: string;
  /** 依赖的资产 id（有序：导入/加载按这个顺序，保证确定性）。 */
  readonly dependencies: readonly AssetId[];
  readonly byteLength: number;
}

export interface IAsset {
  readonly id: AssetId;
  readonly type: string;
  dispose(): void;
}

/** 加载上下文：加载器需要读文件、记日志、递归加载依赖。 */
export interface AssetLoadContext {
  readonly fs: IFileSystem;
  readonly log: ChannelLogger;
  /** 递归加载依赖（由数据库提供，处理计数与环检测）。 */
  load(id: AssetId): Promise<Result<IAsset, EngineError>>;
}

export interface IAssetLoader {
  /** 这个加载器负责哪些 AssetType。 */
  readonly types: readonly string[];
  load(meta: AssetMeta, ctx: AssetLoadContext): Promise<Result<IAsset, EngineError>>;
}

/** 引用计数句柄。**必须 release**（用 `using` 或 try/finally）。 */
export class AssetHandle<T extends IAsset = IAsset> {
  private released = false;

  constructor(
    readonly asset: T,
    private readonly onRelease: (a: T) => void,
  ) {}

  get id(): AssetId {
    return this.asset.id;
  }

  release(): void {
    if (this.released) {
      // 重复释放是调用方 bug，但不该崩 —— 记录并由数据库侧统计
      this.onRelease(this.asset);
      return;
    }
    this.released = true;
    this.onRelease(this.asset);
  }

  get isReleased(): boolean {
    return this.released;
  }
}

interface Slot {
  readonly meta: AssetMeta;
  asset: IAsset | null;
  /** 外部句柄计数。 */
  refs: number;
  /** 被多少个资产依赖（加载期算）。 */
  inDegree: number;
  loading: Promise<Result<IAsset, EngineError>> | null;
}

export interface AssetDatabaseStats {
  readonly registered: number;
  readonly loaded: number;
  readonly refs: number;
  readonly cacheHit: number;
  readonly cacheMiss: number;
}

export class AssetDatabase {
  private readonly slots = new Map<AssetId, Slot>();
  private readonly byPath = new Map<string, AssetId>();
  private readonly loaders: IAssetLoader[] = [];
  private hit = 0;
  private miss = 0;

  constructor(
    private readonly fs: IFileSystem,
    private readonly log: ChannelLogger,
  ) {}

  registerLoader(l: IAssetLoader): void {
    this.loaders.push(l);
  }

  /** 注册/更新元数据。同一个 id 重复注册允许（= 重新导入），但会作废已加载实例。 */
  register(meta: AssetMeta): Result<void, EngineError> {
    const prev = this.slots.get(meta.id);
    if (prev !== undefined) {
      if (prev.refs > 0) {
        return err({
          code: "ASSET.REIMPORT_WHILE_IN_USE",
          message: `资产 ${meta.id} 正被 ${prev.refs} 处使用，不能重新导入（先全部 release）`,
        });
      }
      if (prev.asset !== null) prev.asset.dispose();
      this.byPath.delete(prev.meta.path);
    }
    this.slots.set(meta.id, { meta, asset: null, refs: 0, inDegree: 0, loading: null });
    this.byPath.set(meta.path, meta.id);
    return ok(undefined);
  }

  meta(id: AssetId): AssetMeta | undefined {
    return this.slots.get(id)?.meta;
  }

  /**
   * 反注册（源资产被删除）。
   *
   * ★ 为什么必须有（阶段 2 补）：导入器要处理"源文件被删了"——这是**正常事件**，
   *   不是异常。没有反注册时，删除只让文件消失、注册表里留下一条幽灵：
   *   `describe()` 还看得到它、`dependents()` 还把它算进依赖、`idAtPath` 还能查到，
   *   于是"这个资产到底还在不在"从可判定退化成了靠猜。
   *   上一代引擎里同类的债是"prefab 表只增不减"，改一版涨一版。
   *
   * 两条拒绝条件都不是保守，而是正确性：
   *   · `refs > 0`：有句柄在用，删了它句柄就指向已释放实例（随机崩）；
   *   · 有反向依赖：删了被引用的资产，依赖方下次加载会失败，而失败点离根因很远。
   * 都不满足才算"真的没人要它了"。
   */
  unregister(id: AssetId): Result<void, EngineError> {
    const slot = this.slots.get(id);
    if (slot === undefined) return ok(undefined); // 幂等：删两次不该报错
    if (slot.refs > 0) {
      return err({
        code: "ASSET.IN_USE",
        message: `资产 ${id} 还有 ${slot.refs} 个句柄未释放，不能反注册`,
      });
    }
    const users = this.dependents(id);
    if (users.length > 0) {
      return err({
        code: "ASSET.STILL_REFERENCED",
        message: `资产 ${id} 仍被 ${users.join(", ")} 依赖，不能反注册（先删依赖方的引用）`,
        detail: { id, dependents: users },
      });
    }
    this.byPath.delete(slot.meta.path);
    this.slots.delete(id);
    slot.asset?.dispose();
    return ok(undefined);
  }

  idAtPath(path: string): AssetId | undefined {
    return this.byPath.get(path);
  }

  /** 直接依赖 / 反向依赖（编辑器"谁用了它"）。 */
  dependencies(id: AssetId): readonly AssetId[] {
    return this.slots.get(id)?.meta.dependencies ?? [];
  }

  dependents(id: AssetId): readonly AssetId[] {
    const out: AssetId[] = [];
    for (const [k, s] of this.slots) {
      if (s.meta.dependencies.includes(id)) out.push(k);
    }
    return out.sort();
  }

  /**
   * 加载。相同的 id 并发调用会**共享同一个 Promise**（不会加载两次）。
   * 依赖按 meta 里声明的顺序加载；任一失败则整体失败并回滚已加载的依赖计数。
   */
  async load<T extends IAsset = IAsset>(id: AssetId, _stack: AssetId[] = []): Promise<Result<AssetHandle<T>, EngineError>> {
    const slot = this.slots.get(id);
    if (slot === undefined) {
      return err({
        code: "ASSET.NOT_REGISTERED",
        message: `资产 ${id} 未注册（先由导入器写入 meta）`,
      });
    }

    // 环检测
    if (_stack.includes(id)) {
      return err({
        code: "ASSET.DEPENDENCY_CYCLE",
        message: `资产依赖成环：${[..._stack, id].join(" → ")}`,
        detail: { cycle: [..._stack, id] },
      });
    }

    if (slot.asset !== null) {
      this.hit++;
      slot.refs++;
      return ok(this.makeHandle(slot));
    }

    if (slot.loading !== null) {
      this.hit++;
      const r = await slot.loading;
      if (!r.ok) return err(r.error);
      slot.refs++;
      return ok(this.makeHandle(slot));
    }

    this.miss++;
    const p = this.doLoad(slot, [..._stack, id]);
    slot.loading = p;
    const r = await p;
    slot.loading = null;
    if (!r.ok) return err(r.error);
    slot.refs++;
    return ok(this.makeHandle(slot));
  }

  private async doLoad(
    slot: Slot,
    stack: AssetId[],
  ): Promise<Result<IAsset, EngineError>> {
    const { meta } = slot;

    // 先加载依赖（失败要回滚已成功的计数）
    const loadedDeps: AssetId[] = [];
    for (const depId of meta.dependencies) {
      const r = await this.load(depId, stack);
      if (!r.ok) {
        for (const d of loadedDeps) this.decRef(d);
        // ★ 环是**根因**，必须透传而不是包一层。
        //   契约测试抓到的：原来一律包成 `DEPENDENCY_FAILED`，
        //   于是调用方看到"依赖 a 加载失败"，永远不知道真正的原因是成环 ——
        //   而这两者的处置完全不同（缺依赖 = 补资源；成环 = 改依赖图）。
        //   同理，深层已经报过的失败也不再重复包装（保留最内层的 code）。
        if (r.error.code === "ASSET.DEPENDENCY_CYCLE" || r.error.code === "ASSET.DEPENDENCY_FAILED") {
          return err(r.error);
        }
        return err({
          code: "ASSET.DEPENDENCY_FAILED",
          message: `资产 ${meta.id} 的依赖 ${depId} 加载失败：${r.error.message}`,
          detail: { asset: meta.id, dep: depId, cause: r.error },
        });
      }
      loadedDeps.push(depId);
    }

    const loader = this.loaders.find((l) => l.types.includes(meta.type));
    if (loader === undefined) {
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.NO_LOADER",
        message: `没有能处理类型 ${meta.type} 的加载器（已注册的：${this.loaders
          .flatMap((l) => l.types)
          .sort()
          .join(", ") || "(空)"}）`,
      });
    }

    const ctx: AssetLoadContext = {
      fs: this.fs,
      log: this.log,
      load: async (depId) => {
        const r = await this.load(depId, stack);
        return r.ok ? ok(r.value.asset) : err(r.error);
      },
    };

    let asset: IAsset;
    try {
      const r = await loader.load(meta, ctx);
      if (!r.ok) {
        for (const d of loadedDeps) this.decRef(d);
        return err(r.error);
      }
      asset = r.value;
    } catch (e) {
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.LOADER_THREW",
        message: `加载器 ${meta.type} 抛异常：${e instanceof Error ? e.message : String(e)}`,
      });
    }

    if (asset.id !== meta.id) {
      // 加载器返回了别人的资产 = 严重 bug，早失败早发现
      asset.dispose();
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.ID_MISMATCH",
        message: `加载器返回的资产 id ${asset.id} 与请求的 ${meta.id} 不一致`,
      });
    }
    slot.asset = asset;
    return ok(asset);
  }

  /** 减引用。`slots.get(x)?.refs--` 在 TS 里不合法（可选属性不能自减），必须走这个。 */
  private decRef(id: AssetId): void {
    const s = this.slots.get(id);
    if (s !== undefined) s.refs = Math.max(0, s.refs - 1);
  }

  private makeHandle<T extends IAsset>(slot: Slot): AssetHandle<T> {
    return new AssetHandle<T>(slot.asset as T, (a) => {
      void a;
      slot.refs = Math.max(0, slot.refs - 1);
      if (slot.refs === 0 && this.dependents(slot.meta.id).length === 0) {
        slot.asset?.dispose();
        slot.asset = null;
      }
    });
  }

  /**
   * 卸载计划：**依赖的反拓扑序**（先卸使用者，再卸被使用者）。
   * 编辑器"重新导入前先卸载"与关场景时用。
   */
  unloadPlan(): readonly AssetId[] {
    const loaded = Array.from(this.slots.entries())
      .filter(([, s]) => s.asset !== null)
      .map(([id]) => id);

    const order: AssetId[] = [];
    const state = new Map<AssetId, 0 | 1 | 2>(); // 0 未访问 1 访问中 2 完成
    const visit = (id: AssetId): void => {
      const st = state.get(id) ?? 0;
      if (st !== 0) return;
      state.set(id, 1);
      for (const dep of this.dependencies(id)) visit(dep);
      state.set(id, 2);
      order.push(id); // 后序：依赖先入栈
    };
    for (const id of loaded.sort()) visit(id);
    // 后序的结果是"依赖在前"，卸载要反过来
    return order.reverse();
  }

  /** 强制卸载全部（关场景）。返回真正释放的个数。 */
  unloadAll(): number {
    const plan = this.unloadPlan();
    for (const id of plan) {
      const s = this.slots.get(id);
      if (s?.asset != null) {
        s.asset.dispose();
        s.asset = null;
      }
      if (s !== undefined) s.refs = 0;
    }
    return plan.length;
  }

  stats(): AssetDatabaseStats {
    let loaded = 0;
    let refs = 0;
    for (const s of this.slots.values()) {
      if (s.asset !== null) loaded++;
      refs += s.refs;
    }
    return {
      registered: this.slots.size,
      loaded,
      refs,
      cacheHit: this.hit,
      cacheMiss: this.miss,
    };
  }

  /** 诊断：列出所有资产的 id / 类型 / 是否加载。 */
  describe(): ReadonlyArray<{ id: AssetId; type: string; path: string; loaded: boolean; refs: number }> {
    return Array.from(this.slots.entries())
      .map(([id, s]) => ({
        id,
        type: s.meta.type,
        path: s.meta.path,
        loaded: s.asset !== null,
        refs: s.refs,
      }))
      .sort((a, b) => a.id.localeCompare(b.id));
  }
}
