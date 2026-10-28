/**
 * L4 · 造一只生物（**组合层**：精灵 + 血量 + 阵营 + 移动 + 攻击）
 *
 * 单独一个文件而不是塞进浏览器宿主：宿主写的是"放 6 只兔子"，
 * 而不是"给兔子挂五个组件并按顺序 flush"。后者一旦散落在宿主里，
 * 编辑器 PIE 想放一只兔子就得抄一遍 —— 抄出来的第二份必然漏一个组件。
 *
 * ★★ 三个决定：
 *
 * ① **全部 `attach` 完之后只 `flush` 一次**。
 *    `spawn` 与 `attach` 都是**入队**（见 `attach` 的实现），中途 flush 会让
 *    "生物还没长全"的那一瞬间暴露给别的模块 —— 而物理/渲染/战斗都可能在
 *    那一瞬间读到它。批65 的 `onKill` 已经教训过："顺序错了只在多模块下才暴露"。
 *
 * ② **挂完要读回来确认**，不信 `attach` 的返回值就完事。
 *    `attach` 在"组件没注册"时会立刻报错（这点是好的），但**读回来**还能抓住
 *    "类型名写错但恰好注册过另一个同名组件"这类问题 —— 代价是一行 `get()`。
 *    读不到就**销毁节点**再报错，绝不返回一个"能看见但打不动"的半成品。
 *
 * ③ **`damage: 0` 的生物不挂攻击组件**（和平生物）。
 *    阵营组件则**总是挂上**（哪怕 `team` 是空串）：
 *    "没装阵营"与"装了但中立"在关系判定上等价，但在诊断上是两件事；
 *    而模板既然写了 `team`，就应该有一个组件承载它 —— 否则改了模板的 team
 *    什么也不发生（最难查的一类：配置生效了但没人读）。
 *
 *    这里同时决定了"凶不凶"：`mob-brain` 用 `get(ATTACKER_TYPE) !== undefined`
 *    判断要不要追人。**组件就是策略**，不额外加布尔开关 ——
 *    "配了伤害却永远不出手"的怪是配置错误，不该用一个开关把它合法化。
 *
 * ④ **朝向（`motion.facing`）是生物的标配**，和平生物也挂。
 *    理由：视野锥、「面朝目标」、渲染选帧三件事都要它，而「要不要有朝向」
 *    不是一个可选项 —— 没有朝向的生物等于一个永远朝东的贴纸。
 *    它没注册时 `attach` 会硬失败（同 ②），于是「少挂一个组件」不会静默退化成
 *    「画得出来但不会转身」。
 *
 * ⑤ **方向帧（`render.dirSprite`）也在这里挂**，前缀直接取 `tpl.frame`。
 *    没有它，`motion.facing` 与图集里的 `rabbit_e` 之间就没有任何代码连接 ——
 *    生物会一直显示默认那一张，而所有判据（朝向、帧名契约）各自都是绿的。
 */

import type { Scene } from "../../core/scene/scene.ts";
import type { Component, ComponentSchema } from "../../core/scene/component.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { HEALTH_TYPE, Health } from "../combat/health.ts";
import { ATTACKER_TYPE, Attacker } from "../combat/attack.ts";
import { FACTION_TYPE, FactionMember } from "../combat/faction.ts";
import { LOOT_TYPE, LootHolding, encodeItems } from "../combat/loot.ts";
import { MOVER_TYPE, Mover } from "../ai/move.ts";
import { FACING_TYPE, Facing } from "../motion/facing.ts";
import { DIR_SPRITE_TYPE, DirSprite } from "../render/dir-sprite.ts";
import { SPRITE_TYPE, type Sprite, makeSprite } from "../render/sprite.ts";
import { type MobTemplate, validateTemplate } from "./mob-template.ts";

/** 装配失败（组件没注册 / 节点建不出来）。 */
export const MOB_SPAWN_FAILED = "MOB.SPAWN_FAILED";

export interface MobHandle {
  readonly nodeId: number;
  readonly template: MobTemplate;
  readonly sprite: Sprite;
  readonly health: Health;
  /** `null` = 和平生物（模板 `damage: 0`），见文件头 ③。 */
  readonly attacker: Attacker | null;
  readonly mover: Mover;
  /**
   * 朝向（`motion.facing`）。
   *
   * ★ 必须挂在生物身上、且是**节点上那一个实例**：渲染层按 `dir8` 选帧、
   *   AI 按 `angle` 做扇区感知，两边都从节点上取。给 handle 一个副本的话，
   *   「改了 handle 上的角度、画面不动」就成了新的难查项。
   */
  readonly facing: Facing;
  /**
   * 方向帧绑定（`render.dirSprite`）。
   *
   * ★ `prefix` 抄的是模板的 `frame`：这两处一旦不同，生物会「在走但永远一个姿势」，
   *   而 `syncDirFrames` 的判据也照样绿（它拿到的前缀本身是自洽的）。
   *   装配时强制同源，是把这种错堵在产生的那一刻。
   */
  readonly dirSprite: DirSprite;
}

export interface SpawnMobOptions {
  /** 节点名（默认 `kind#序号`，序号由调用方给 —— 名字要稳定，存档与 Lua 脚本按名字找节点）。 */
  readonly name?: string;
  /** 精灵锚点（默认 0：脚踩地面，饥荒风格）。 */
  readonly pivotY?: number;
}

/**
 * 在 (x, z) 造一只生物。
 *
 * `template` 收 `unknown`：它来自宿主配置，到这里才第一次被校验。
 * 校验失败时**一个节点都不建** —— 于是"模板写错"不会在世界里留下半个生物。
 */
export function spawnMob(
  scene: Scene,
  template: unknown,
  x: number,
  z: number,
  opts: SpawnMobOptions = {},
): Result<MobHandle, EngineError> {
  const tplR = validateTemplate(template);
  if (!tplR.ok) return tplR;
  const tpl = tplR.value;

  const name = opts.name ?? tpl.kind;
  const spawned = scene.spawnAt(name, x, z);
  if (!spawned.ok) return spawned;
  const nodeId = spawned.value.id;

  // 见文件头 ①：五次 attach 全部入队，最后统一 flush
  const sprite = makeSprite(tpl.frame, tpl.width, tpl.height);
  sprite.pivotY = opts.pivotY ?? 0;
  const health = new Health();
  health.hp = tpl.maxHp;
  health.maxHp = tpl.maxHp;
  const attacker = new Attacker();
  attacker.damage = tpl.damage;
  attacker.range = tpl.range;
  attacker.cooldownTicks = tpl.cooldownTicks;
  const mover = new Mover();
  mover.speed = tpl.speed;
  const faction = new FactionMember();
  faction.team = tpl.team;
  const facing = new Facing();
  // 方向帧：前缀 = 模板帧名（见 `MobHandle.dirSprite` 的注释）。
  const dirSprite = new DirSprite();
  dirSprite.prefix = tpl.frame;
  // ★ 批123：战利品表**挂在实体上**（`game.loot`），不是模块里的旁表 ——
  //   旁表按节点 id 索引，而读档会把场景换成存档里的那批节点：跨会话读档之后
  //   "打死的怪什么都不掉"，且没有报错。详见 `loot.ts` 的 `LOOT_TYPE`。
  const loot = new LootHolding();
  loot.items = encodeItems(tpl.loot);

  const attached: Array<[ComponentSchema["type"], Component]> = [
    [SPRITE_TYPE, sprite],
    [HEALTH_TYPE, health],
    [MOVER_TYPE, mover],
    [FACTION_TYPE, faction],
    [FACING_TYPE, facing],
    [DIR_SPRITE_TYPE, dirSprite],
  ];
  // 见文件头 ③：damage 为 0 ⇒ 不挂攻击组件
  if (tpl.damage > 0) attached.push([ATTACKER_TYPE, attacker]);
  // 空表就不挂（`lootOfNode` 对"没有组件"和"空表"都返回 null，语义一致）
  if (tpl.loot.length > 0) attached.push([LOOT_TYPE, loot]);
  for (const [type, c] of attached) {
    const a = scene.attach(nodeId, () => c);
    if (!a.ok) {
      // 组件没注册：节点已经入队，顺序清除，不留半成品
      scene.destroy(nodeId);
      scene.flush();
      return err(
        engineError(MOB_SPAWN_FAILED, `「${tpl.kind}」需要 ${type}，但它没注册：${a.error.message}`, {
          nodeId,
          type,
          cause: a.error.code,
        }),
      );
    }
  }
  scene.flush();

  // 见文件头 ②
  const back = scene.find(nodeId);
  if (back === undefined) {
    return err(engineError(MOB_SPAWN_FAILED, `「${tpl.kind}」的节点 ${String(nodeId)} 建完就找不到了`));
  }
  for (const [type] of attached) {
    if (back.get(type) === undefined) {
      scene.destroy(nodeId);
      scene.flush();
      return err(
        engineError(MOB_SPAWN_FAILED, `「${tpl.kind}」的 ${type} 挂上之后读不到（类型名与注册名不一致？）`, {
          nodeId,
          type,
        }),
      );
    }
  }

  return ok({
    nodeId,
    template: tpl,
    sprite,
    health,
    attacker: tpl.damage > 0 ? attacker : null,
    mover,
    facing,
    dirSprite,
  });
}

/**
 * 批量造一批生物，按格子列表。
 *
 * 返回值里**保留失败项**（不跳过）：`spawnMob` 失败通常是"组件没注册"，
 * 那是全局性问题，静默跳过会让"少了三只兔子"看起来像随机。
 */
export function spawnMobs(
  scene: Scene,
  template: unknown,
  spots: ReadonlyArray<{ readonly x: number; readonly z: number }>,
  opts: { readonly namePrefix?: string } = {},
): Result<readonly MobHandle[], EngineError> {
  const out: MobHandle[] = [];
  for (let i = 0; i < spots.length; i++) {
    const s = spots[i]!;
    const prefix = opts.namePrefix ?? "mob";
    const r = spawnMob(scene, template, s.x, s.z, { name: `${prefix}#${String(i)}` });
    if (!r.ok) return r;
    out.push(r.value);
  }
  return ok(out);
}
