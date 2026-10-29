/**
 * 浏览器宿主入口（L6）
 *
 * 这是"引擎真的能跑"的证据：注册真实后端 → 建世界 → 输入驱动 → 物理碰撞 → 渲染 → 存档。
 *
 * ★ 这个文件允许知道一切（具体后端、具体组件、具体玩法）—— 它是 **宿主**。
 *   内核不知道它的存在。所以这里出现 `webgl2Backend` / `domInputBackend` 是**正确**的；
 *   同样的 import 出现在 `core/**` 里就是架构崩了（arch 规则 4 会红）。
 *
 * 资产：启动时把 `web/assets/*.png` 走**完整导入链**烘焙成真图集 ——
 *   `fs-http（只读）→ 内存 fs → AssetImportPipeline（.meta/增量/依赖）→ PNG 解码 → shelf packing`。
 *   任一步失败（例如用 file:// 直接打开被 CORS 拦住）则降级到程序化图集，
 *   但 HUD 会显示 `atlas:assets*6` 还是 `atlas:procedural` —— **降级不静默**。
 *   静默降级的后果是"以为在测真资产，其实在测假贴图"，这正是本轮要消灭的盲区。
 *
 * ★ 装配顺序很重要（第一版写错过）：
 *   物理 → 渲染模块 → 世界模块 → bootGameApp(modules) → 摆世界 → run()
 *   模块的 init/start **必须交给 ModuleRegistry**，不能在 boot 之后手动调 ——
 *   手动调会绕过拓扑排序与失败回滚，而且很容易漏掉 stop/dispose。
 */

import { ok, err, engineError, type EngineError, type Result } from "./foundation/result.ts";
import { BackendRegistry } from "./platform/registry.ts";
import { registerNullBackends } from "./backends/index.ts";
import { createLuaScriptBackend } from "./backends/script-lua/runtime.ts";
import { webgl2Backend } from "./backends/gfx-webgl2/device.ts";
import { domInputBackend } from "./backends/input-dom/device.ts";
import { webAudioBackend } from "./backends/audio-webaudio/device.ts";
import { bootGameApp, type GameApp } from "./runtime/GameApp.ts";
import { RafTickSource } from "./runtime/tick-source.ts";
import { Services } from "./core/tokens.ts";
import { Component, type ComponentRegistry, FieldType, type ComponentSchema } from "./core/scene/component.ts";
import type { IModule, ModuleContext } from "./core/module/module.ts";
import { createRenderModule } from "./extensions/render/render-module.ts";
import { Sprite, makeSprite, SPRITE_TYPE } from "./extensions/render/sprite.ts";
import { SpatialHashWorld, makeSceneAccessor } from "./extensions/physics/physics.ts";
import { createWorldModule } from "./extensions/physics/world-step-module.ts";
import { createScriptModule } from "./extensions/script/script-module.ts";
import { ScriptComponent } from "./extensions/script/script-component.ts";
import { saveScene, loadScene, sceneToJson, sceneFromJson } from "./core/scene/scene-io.ts";
import { stableHash } from "./core/serialization/schema.ts";
import { Logger, LogLevel } from "./foundation/log/logger.ts";
import { MemoryFileSystem } from "./backends/fs-memory/fs.ts";
import { HttpFileSystem } from "./backends/fs-http/fs.ts";
import { resolveAssetSource } from "./extensions/build/bundle-source.ts";
import type { IReadableFileSystem } from "./platform/fs/fs.ts";
import { StorageFileSystem } from "./backends/fs-storage/fs.ts";
import { AssetDatabase } from "./core/asset/asset.ts";
import { ImporterRegistry } from "./extensions/asset-import/importer.ts";
import { AssetImportPipeline } from "./extensions/asset-import/pipeline.ts";
import { textureImporter } from "./extensions/asset-import/importers/texture.ts";
import { atlasImporter } from "./extensions/asset-import/importers/atlas.ts";
import { textImporter } from "./extensions/asset-import/importers/text.ts";
import { ImportedTexture, ImportedText, createImportLoaders } from "./extensions/asset-import/loaders.ts";
import { decodeImage } from "./extensions/asset-import/decode/image.ts";
import { buildAtlasFromSources, type AtlasSource } from "./extensions/render/atlas-from-assets.ts";
import {
  addItem,
  countItem,
  makeInventory,
  registerInventoryComponents,
  stacksOf,
  swapStacks,
  type Inventory,
} from "./extensions/inventory/inventory.ts";
import { pickupNearby } from "./extensions/inventory/pickup.ts";
// 批123：尸体（死亡原地留下的那一具，自己带 loot 表与腐烂计时）
import { attachLoot, grantLoot, lootOfNode, registerLootComponent } from "./extensions/combat/loot.ts";
import {
  CORPSE_TYPE,
  corpseAt,
  createCorpseModule,
  registerCorpseComponent,
  spawnCorpse,
  takeFromCorpse,
  type Corpse,
  type CorpseModuleHandle,
} from "./extensions/combat/corpse.ts";
import { dropIntoWorld } from "./extensions/inventory/drop-to-world.ts";
import { buildProceduralAtlas, type AtlasData } from "./extensions/render/atlas.ts";
import { parseBmFont, type BitmapFont } from "./extensions/ui/font.ts";
import { UiScaleMode } from "./extensions/ui/viewport.ts";
import { createHudUi, rectOfId, type HudUiHandle, type UiSkinJson } from "./host/hud-ui.ts";
// 批76：UI 过渡 —— `TweenPlayer` 的第一个真实消费者（顿帧消费"时间"，它消费"值"）
import { advancePlayer, ticksToMs, TweenPlayer } from "./extensions/tween/tween-player.ts";
import { applyUiSamples, UI_TWEEN_PROP } from "./extensions/ui/ui-transition.ts";
import { HUD_VALUE_TINT } from "./host/hud-ui.ts";
import { hudLine, hudRowRuns, type HudFacts } from "./host/hud-model.ts";
import { whyNotAttackable } from "./host/attack-target-policy.ts";
import { demoHitstopPolicy } from "./host/hitstop-policy.ts";
import { generateWorld, type WorldPlan } from "./extensions/worldgen/worldgen.ts";
import {
  SITE_TYPE,
  TERRAIN_TYPE,
  assembleWorld,
  registerWorldComponents,
} from "./extensions/worldgen/assemble.ts";
import { RESOURCE_TYPE, createWorldTaskModule, registerResourceComponent } from "./extensions/worldgen/task-module.ts";
import type { WorldTaskModuleHandle } from "./extensions/worldgen/task-module.ts";
import { WORLD_TASK_SCHEMA } from "./extensions/worldgen/tasks.ts";
import { spawnPlayer, registerPlayerComponents, type PlayerHandle } from "./extensions/worldgen/spawn.ts";
import { attachWorldVisuals, type WorldVisualReport } from "./extensions/render/world-visuals.ts";
import { harvestAt } from "./extensions/worldgen/harvest.ts";
import {
  PlayerController,
  createControllerModule,
  registerControllerComponent,
} from "./extensions/input/player-controller.ts";
import { NavGrid } from "./extensions/nav/nav-grid.ts";
import { HEALTH_TYPE, Health, isDead, registerHealthComponent } from "./extensions/combat/health.ts";
import { ATTACKER_TYPE, Attacker, attack, registerAttackerComponent } from "./extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent, teamOf } from "./extensions/combat/faction.ts";
// 批73：顿帧（hitstop）。命中的一瞬间把世界冻住几个逻辑步，画面继续走。
import { createHitstopModule, type HitstopHandle } from "./extensions/combat/hitstop.ts";
import type { HitInfo } from "./extensions/combat/combat-module.ts";
import { createMobWorldModule, type MobSpot, type MobWorldHandle } from "./extensions/mobs/mob-world.ts";
// 批69：命中反馈（受击闪色 / 挥击挤压 / 伤害数字）。引擎侧只负责"让状态可见"，
// 数字的排布属于宿主（贴在屏幕上的东西，引擎不该规定它长什么样）。
import {
  createFeedbackModule,
  flash as flashNode,
  punch as punchNode,
  registerFeedbackComponent,
  FEEDBACK_TYPE,
  type Feedback,
  type FeedbackHandle,
} from "./extensions/render/feedback.ts";
import { registerMoverComponent } from "./extensions/ai/move.ts";
import { registerFacingComponent } from "./extensions/motion/facing.ts";
import {
  DirSprite,
  registerDirSpriteComponent,
  restoreDirClipIds,
  syncDirFrames,
} from "./extensions/render/dir-sprite.ts";
import { createAnimModule } from "./extensions/render/anim-module.ts";
import { makeAnimationClip } from "./extensions/render/animation.ts";
import { SpriteAnimator } from "./extensions/render/sprite-animator.ts";
import { faceFromMotion, FACING_TYPE, Facing } from "./extensions/motion/facing.ts";
import { TextInput } from "./extensions/ui/text-input.ts";
import { HUNGER_TYPE, Hunger, registerHungerComponent } from "./extensions/survival/hunger.ts";
import { eat as eatKind, normalizeFoodTable } from "./extensions/survival/food.ts";
import { createSurvivalModule } from "./extensions/survival/survival-module.ts";
import { craft as craftRecipe, firstCraftable, missingFor, normalizeRecipes } from "./extensions/crafting/recipe.ts";

/** `appRef` 还没就绪时的空输入（控制器模块在 boot 之后才会被驱动，这里只是兜底）。 */
const EMPTY_INPUT = {
  keysDown: new Set<string>(),
  keysPressed: new Set<string>(),
  keysReleased: new Set<string>(),
  pointer: { x: 0, y: 0, dx: 0, dy: 0, buttonsDown: new Set<number>(), buttonsPressed: new Set<number>(), buttonsReleased: new Set<number>() },
  wheel: { dx: 0, dy: 0 },
  text: "",
} as unknown as import("./platform/input/device.ts").InputSnapshot;

// ---------------------------------------------------------------- 组件

/** 可被砍：砍到 0 就倒（演示组件数据随存档往返）。 */
class Workable extends Component {
  workleft = 3;
  readonly schema: ComponentSchema = {
    type: "game.workable",
    fields: { workleft: FieldType.Int },
  };
}


// ---------------------------------------------------------------- 演示脚本

/**
 * 内联的 Lua 演示（Lua 5.4）。
 *
 * ★ 为什么脚本驱动的是"浆果漂浮"这种小事：它一次用到脚本层全部四件能力
 *   —— 查节点（`engine_nodes_named`）、读位置、写位置、写日志 ——
 *   而且**肉眼可见**。脚本层最容易的假完成是"能调通一个 return 1+1"，
 *   却在真实世界里什么都不做；这一条断言的是"脚本真的改变了世界"。
 *
 * ★ 只在首帧收集一次节点 id：`engine_nodes_named` 每个 tick 调一次是 O(N) 遍历，
 *   而节点集合在游戏里并不会每帧变 —— 把"每帧全表扫描"降成"一次扫描"。
 */
const LUA_DEMO = `
local beans = {}
local t = 0

local function collect()
  for i = 0, 13 do
    local ids = engine_nodes_named("berry" .. tostring(i))
    if #ids > 0 then
      beans[#beans + 1] = { id = ids[1] }
    end
  end
end

function onUpdate(selfId, dt, tick)
  t = t + dt
  if #beans == 0 then collect() end
  for i = 1, #beans do
    local b = beans[i]
    if b.z0 == nil then
      local p = engine_get_pos(b.id)
      if p ~= nil then
        b.x0 = p.x
        b.z0 = p.z
      end
    end
    if b.z0 ~= nil then
      engine_set_pos(b.id, b.x0, b.z0 + math.sin(t * 1.6 + i) * 0.18)
    end
  end
  if tick > 0 and tick % 60 == 0 then
    engine_log("demo: " .. tostring(#beans) .. " 个浆果在漂浮 (tick " .. tostring(tick) .. ")")
  end
end
`;

// ---------------------------------------------------------------- 资产烘焙

/**
 * demo 用到的帧。**顺序即图集排布顺序**（shelf packing 内部还会按高度重排，
 * 但这里是"按什么顺序读资产/查 id"，固定下来才能保证两次运行产出同一张图集）。
 *
 * ★ 为什么这里带文件名而不是裸帧名：`photo.jpg` 是**故意**混进来的。
 *   全 PNG 的资产表只能证明 PNG 解码器在跑；要证明"JPEG 也能进引擎"，
 *   就必须让同一份烘焙代码真的走一次有损格式（`decodeImage` 按魔数分发）。
 *   帧名仍叫 `photo`，渲染层不关心它的源格式。
 */
/**
 * 8 向字母表。**顺序必须与 `dir-frames.ts` 的 `LETTERS8` 一致**（`0` = 东，顺时针）。
 *
 * ★ 这里不 import 那个常量是有原因的：`LETTERS8` 是模块私有的实现细节，
 *   而这里的用途是「列文件」—— 两处都写死，靠判据（`dir-sprite.test.ts` 会读每张图的眼睛位置）
 *   来抓顺序错位。若哪天要合并，改的方向是让 `dir-frames.ts` 导出字母表，而不是在这里猜。
 */
const DIRECTION_FRAMES = ["e", "se", "s", "sw", "w", "nw", "n", "ne"] as const;

/** 每个方向的待机帧数（== 导入器写出的张数）。 */
const HERO_FRAMES = [0, 1, 2, 3] as const;

/** 每帧时长（毫秒）。150 是"看得出在呼吸、又不至于像抽搐"的档位，与场景节奏无关。 */
const HERO_IDLE_MS = 150;

/**
 * 玩家待机动画：**每个方向一段 clip**。
 *
 * ★ 为什么是 8 段而不是"一段 clip + 按方向切区间"：`AnimationClip` 只认帧名序列，
 *   切区间要自己算偏移量，偏移量一错就是"朝东播到朝北的帧"—— 而两边的判据都绿
 *   （clip 本身合法、方向下标也合法）。8 段 id 直白，错了在当前帧名上看得见。
 *
 * ★★ 这三个常量**必须声明在 `DEMO_FRAMES` 之前**，不是排版偏好。
 *   `DEMO_FRAMES` 是模块顶层常量，求值发生在 import 的那一刻；它内部引用
 *   `HERO_FRAMES`。把声明放到后面 ⇒ `Cannot access 'HERO_FRAMES' before initialization`
 *   ——整个页面白屏，而 `tsc` 不报（引用藏在箭头函数里，TS 不做跨函数体的
 *   使用前检查），Node 判据也碰不到（`browser-entry.ts` 只在浏览器里跑）。
 *   批112 真踩过：页面级断言是这条错误的唯一守卫。
 */
const HERO_CLIPS = DIRECTION_FRAMES.map((letter) => {
  const made = makeAnimationClip({
    id: `hero_idle_${letter}`,
    frames: HERO_FRAMES.map((f) => `hero_${letter}_${f}`),
    durationsMs: HERO_FRAMES.map(() => HERO_IDLE_MS),
  });
  if (!made.ok) throw new Error(`玩家待机动画 ${letter} 构造失败：${made.error.message}`);
  return made.value;
});

/**
 * 方向 → clip id 表（**装配与读档后共用这一份**）。
 *
 * ★ 抽成一个函数而不是就地写两遍：`clipIds` 不进 `schema`，读档时会被丢掉，
 *   所以「装配」和「读档后补回」必须是同一个来源。写两遍的失效方式是
 *   某天只改了其中一处 —— 表现是「读档之后某个方向的动画换了另一段」。
 */
function heroClipIds(): string[] {
  return DIRECTION_FRAMES.map((letter) => `hero_idle_${letter}`);
}

const DEMO_FRAMES = [
  { name: "ground", file: "ground.png" },
  // ★ terrain 是**中性灰噪点**，不是草绿：地形块用「灰度帧 × 群系色」着色
  //   （一张灰度图 × 8 个群系色 = 8 种地貌）。底色若是草绿，海会变成墨绿。
  { name: "terrain", file: "terrain.png" },
  // 2×2 走向标尺（左上红/右上绿/左下蓝/右下白）：诊断 UV 与裁剪用，平时不挂
  { name: "ruler", file: "ruler.png" },
  { name: "tree", file: "tree.png" },
  { name: "rock", file: "rock.png" },
  { name: "berry", file: "berry.png" },
  { name: "player", file: "player.png" },
  // 批66：世界的活物。★ 名字要与 `MOB_TEMPLATES` 里的 `frame` 一致 ——
  //   两边写错一个字的症状是「生物在走但看不见」，而渲染模块只会 warn。
  { name: "rabbit", file: "rabbit.png" },
  { name: "hound", file: "hound.png" },
  // 批108：八向帧。★ 名字必须与 `dir-frames.ts` 的字母表逐字一致，
  //   写错一个的症状是「某个方向永远显示默认帧」—— 而且只在朝那个方向时才看得见。
  ...DIRECTION_FRAMES.map((letter) => ({
    name: `rabbit_${letter}`,
    file: `rabbit_${letter}.png`,
  })),
  ...DIRECTION_FRAMES.map((letter) => ({
    name: `hound_${letter}`,
    file: `hound_${letter}.png`,
  })),
  // 批112：CC0 八向 + 动画素材（OpenGameArt，作者 Raphael Gonçalves / @rgs_dev）。
  //   ★ 每个方向 4 帧待机；名字 `hero_<方向>_<帧>` 由 `tools/import-8dir-pack.mjs` 定，
  //     判据 `eight-dir-pack.test.ts` 逐张核对磁盘 —— 这里写错一个字母，
  //     症状是"某一个方向永远不动"，而图集只会静默少一帧。
  ...DIRECTION_FRAMES.flatMap((letter) =>
    HERO_FRAMES.map((f) => ({ name: `hero_${letter}_${f}`, file: `hero_${letter}_${f}.png` })),
  ),
  { name: "photo", file: "photo.jpg" },
] as const;

/** 烘焙期的资产根目录。**必须与 `pipeline.run()` / `createImportLoaders()` 用同一个**。 */
const ASSET_ROOT = "/assets";

/**
 * UI 的四个资产。它们与 `DEMO_FRAMES` **分开读**，但走**同一条导入管线**：
 *  · `DEMO_FRAMES` 全部合成**一张**图集（世界的纹理页 0）；
 *  · UI 要的是**两页**：字形一页、皮肤一页（`UiModuleOptions.pageSources` 的下标就是页号）。
 *    把字体塞进世界图集会让 BMFont 里的 UV 全部错位 —— 那些 UV 是相对
 *    **字体图自己**算的，不是相对合成图集的。
 *  · 所以它们必须**显式列出来**（`UI_FILES`），并且用 `ui` 字段单独返回。
 *    靠"扫目录把所有 png 都合成一张"会在加第二个 UI 资产时静默把字挤歪。
 */
const UI_FILES = ["ui-font.fnt", "ui-font.png", "ui-skin.png", "ui-skin.json"] as const;

/**
 * 中文字形资产。**可选**：读不到时 UI 照建，只是背包行回到 `kind` 的 ASCII 形式。
 *
 * ★ 为什么单独一张表而不是塞进 `UI_FILES`：那张表是"缺一个就整体降级"的语义
 *   （`uiFilesOk`），而中文是**增强**。把两者混在一起，后果是"删掉中文资产 →
 *   整个 HUD 退回 DOM"，而那正好是这批之前的状态 —— 降级路径会掩盖掉真正的缺失。
 */
const UI_CJK_FILES = ["ui-font-cjk.fnt", "ui-font-cjk.png"] as const;

/** 字体在图集/注册表里的 id。写死一个常量：节点 props 若不写 `fontId` 也会落到它（唯一字体）。 */
const UI_FONT_ID = "ui5x7";
/** 中文字体的 id。背包行靠它选字体（`props.fontId`），也是 `.fnt` 的 `info face` 名。 */
const UI_CJK_FONT_ID = "unifont-cjk-16-subset";

interface BakedAtlas {
  readonly atlas: AtlasData;
  readonly label: string;
  /** UI 资产（读不到就是 null，调用方决定怎么降级）。 */
  readonly ui: BakedUi | null;
}

interface BakedUi {
  readonly font: BitmapFont;
  /** 中文字体（页 2）。读不到就是 undefined —— 背包行退回 ASCII，UI 照常。 */
  readonly cjkFont?: BitmapFont;
  /** 中文字形图（页 2）。与 `cjkFont` 同生共死：只有字体没有图，UV 全指向空白。 */
  readonly cjkPage?: { name: string; width: number; height: number; pixels: Uint8Array };
  /** 字形图（页 0）。 */
  readonly fontPage: { name: string; width: number; height: number; pixels: Uint8Array };
  /** 皮肤图（页 1）。 */
  readonly skinPage: { name: string; width: number; height: number; pixels: Uint8Array };
  /** 皮肤 json 的原文（换算成 `UiSkin` 在 `host/hud-ui.ts`，那里能被 Node 判据覆盖）。 */
  readonly skinJson: UiSkinJson;
}

/**
 * 资产烘焙：`fetch 位图 → 内存 fs → 导入管线 → 解码 → 合成图集`。
 *
 * ★ 这不是"给 demo 特供的捷径"，而是**编辑器里"导入资产"的同一份代码**
 *   （`AssetImportPipeline` + `SourceImporter` + `decodeImage` + `buildAtlasFromSources`），
 *   只把两端的存储换成了内存与直接渲染。所以它验证的是整条链：
 *   文件真的被扫到 → 真的生成 `.meta` → 真的按 hash 增量 → 真的解码成 RGBA8
 *   → 真的上传给 GPU。
 *
 * ★ 为什么在 `bootGameApp` **之前**跑：
 *   图集是渲染模块 `init` 的输入，而 `init` 发生在 boot 里。所以烘焙必须先完成。
 *   这也符合现实：资产导入是**构建期**工作，不是每帧工作。
 *
 * ★ 失败就降级到程序化图集（`atlas.ts`），但**不静默**：
 *   返回值是 null 时，HUD 会显示 `atlas:procedural`，`__engine.atlasSource` 也会说明。
 *   静默降级的后果是"以为在测真资产，其实在测假贴图"—— 这正是本轮要消灭的盲区。
 */
/**
 * 资产来源：默认直读 web/assets；URL 带 ?pack=<manifest 地址> 时改走构建产物（C17）。
 *
 * ★ 决策本身在 `resolveAssetSource`（纯函数，Node 判据覆盖三条出口）；
 *   这里只做接线：从 location 取参数、把全局 fetch 与直读后端交给它。
 *   写在入口文件里的分支只能靠无头浏览器验，而哪条出口被走到是可以纯函数判的。
 */
async function assetSource(): Promise<IReadableFileSystem> {
  return resolveAssetSource({
    packParam: new URL(location.href).searchParams.get("pack"),
    pageHref: location.href,
    root: ASSET_ROOT,
    fallback: () => new HttpFileSystem({ base: new URL("./assets/", location.href) }),
    fetchLike: (url) => fetch(url),
    warn: (message) => console.warn(message),
  });
}

async function bakeAtlasFromAssets(): Promise<BakedAtlas | null> {
  try {
    const fs = new MemoryFileSystem();
    const logger = new Logger(() => performance.now());
    logger.setLevel(LogLevel.Warn);
    const db = new AssetDatabase(fs, logger.channel("asset"));
    const importers = new ImporterRegistry();
    importers.register(textureImporter);
    importers.register(atlasImporter);
    importers.register(textImporter);
    const pipeline = new AssetImportPipeline(fs, db, importers, logger.channel("import"));
    // ★ 加载器要显式注册，root 必须与下面 run() 的参数一致（产物路径由 root 决定）。
    //   漏注册的症状是"导入报告完美、db.load 全 NO_LOADER" —— 中间层做完两头没接。
    for (const l of createImportLoaders({ root: ASSET_ROOT })) db.registerLoader(l);

    // ★ 资源读取走 `HttpFileSystem`（只读），不再内联 `fetch`：
    //   路径归一、`..` 拒绝、404→`FS.NOT_FOUND`、断网→`FS.IO` 全在**一个地方**，
    //   与 Node 侧 `fs-node` 的失败形状一致。宿主里各写一份 fetch 的后果是
    //   "资产读不到"在浏览器和 Node 下长得不一样，而导入管线只认识后者。
    const remote = await assetSource();
    for (const { file } of DEMO_FRAMES) {
      const r = await remote.readBinary(file);
      if (!r.ok) {
        // 降级要留痕：静默降级会让"以为在测真资产"变成长期的假象
        console.warn(`[asset] 读不到 ${file}：${r.error.code} ${r.error.message}`);
        return null;
      }
      const w = await fs.writeBinary(`${ASSET_ROOT}/${file}`, r.value);
      if (!w.ok) return null;
    }
    // UI 的四个文件走同一条管线：`.fnt` / `.json` 归 textImporter、两张 png 归 textureImporter。
    // ★ 读不到**不整体降级**（世界照样能跑），但要留痕 —— 那条痕迹是 `ui: off` 与一条 warn。
    let uiFilesOk = true;
    for (const file of UI_FILES) {
      const r = await remote.readBinary(file);
      if (!r.ok) {
        console.warn(`[ui] 读不到 ${file}：${r.error.code} ${r.error.message}（HUD 会退回 DOM）`);
        uiFilesOk = false;
        continue;
      }
      const w = await fs.writeBinary(`${ASSET_ROOT}/${file}`, r.value);
      if (!w.ok) uiFilesOk = false;
    }
    // 中文那两件照同样一条管线进库，但**失败不算 UI 失败**（见 `UI_CJK_FILES` 的理由）
    for (const file of UI_CJK_FILES) {
      const r = await remote.readBinary(file);
      if (!r.ok) {
        console.warn(`[ui] 读不到 ${file}：${r.error.code} ${r.error.message}（背包行会用英文 kind）`);
        continue;
      }
      await fs.writeBinary(`${ASSET_ROOT}/${file}`, r.value);
    }

    const report = await pipeline.run(ASSET_ROOT);
    if (!report.ok) return null;

    const sources: AtlasSource[] = [];
    for (const { name, file } of DEMO_FRAMES) {
      const id = db.idAtPath(`${ASSET_ROOT}/${file}`);
      if (id === undefined) continue;
      const h = await db.load(id);
      if (!h.ok) continue;
      const asset = h.value.asset;
      try {
        if (asset instanceof ImportedTexture) {
          // 按**魔数**分发（PNG/JPEG），不看扩展名：导入器已经按 SOF/IHDR 校验过，
          // 这里若自己写 if 分支，新增格式时必然有某个入口忘了改。
          const dec = decodeImage(asset.bytes);
          if (dec.ok) sources.push({ name, png: dec.value });
        }
      } finally {
        h.value.release();
      }
    }
    // 少一张就整体降级：缺帧的图集会让 sprite 指向不存在的帧，画面出现"凭空消失的树"，
    // 比直接用程序化图集更难排查。
    if (sources.length !== DEMO_FRAMES.length) return null;

    const built = buildAtlasFromSources(sources, { padding: 2 });
    if (!built.ok) return null;
    const ui = uiFilesOk ? await loadUiAssets(db, logger) : null;
    return { atlas: built.value, label: `assets*${String(sources.length)}`, ui };
  } catch {
    // file:// 直接打开（fetch 被 CORS 拦）/ 资产缺失 —— 都是预期内的降级路径
    return null;
  }
}

/**
 * 取一份**文本**产物（`.fnt` / `.json` 都归 `textImporter`）。找不到返回 null。
 *
 * ★ `release` 必须在 finally 里：资产是引用计数的，漏一次就永远不会被回收 ——
 *   而"漏了"在浏览器里表现为内存缓慢增长，几小时后才像"页面卡了"。
 */
async function loadText(db: AssetDatabase, file: string): Promise<string | null> {
  const id = db.idAtPath(`${ASSET_ROOT}/${file}`);
  if (id === undefined) return null;
  const h = await db.load(id);
  if (!h.ok) return null;
  try {
    return h.value.asset instanceof ImportedText ? h.value.asset.text : null;
  } finally {
    h.value.release();
  }
}

/** 取一份纹理产物的**原始字节**（解码交给调用方：`decodeImage` 按魔数分发）。 */
async function loadTextureBytes(db: AssetDatabase, file: string): Promise<Uint8Array | null> {
  const id = db.idAtPath(`${ASSET_ROOT}/${file}`);
  if (id === undefined) return null;
  const h = await db.load(id);
  if (!h.ok) return null;
  try {
    return h.value.asset instanceof ImportedTexture ? h.value.asset.bytes : null;
  } finally {
    h.value.release();
  }
}

/**
 * 读 UI 的四个产物并组装成 `BakedUi`。
 *
 * ★ 为什么这里每一步都返回 null 而不是抛：UI 是**可降级的**（退回 DOM HUD）。
 *   但降级必须留痕（调用方拿到 null 会写一条 warn 并让 HUD 显示 `ui:-`），
 *   否则"UI 不见了"会变成一个没人查的现象。
 * ★ 字体 id 显式给：`parseBmFont` 默认 id 是 `font`，而节点/判据都按 `UI_FONT_ID` 找，
 *   默认值会让"字体注册了但找不到"变成谜。
 */
async function loadUiAssets(db: AssetDatabase, logger: Logger): Promise<BakedUi | null> {
  const [fnt, skin, fontPngBytes, skinPngBytes, cjkFnt, cjkPngBytes] = await Promise.all([
    loadText(db, "ui-font.fnt"),
    loadText(db, "ui-skin.json"),
    loadTextureBytes(db, "ui-font.png"),
    loadTextureBytes(db, "ui-skin.png"),
    loadText(db, "ui-font-cjk.fnt"),
    loadTextureBytes(db, "ui-font-cjk.png"),
  ]);
  if (fnt === null || skin === null || fontPngBytes === null || skinPngBytes === null) {
    logger.channel("ui").warn("UI 资产不齐（.fnt/.json/两张 png），HUD 会退回 DOM");
    return null;
  }
  const fontR = parseBmFont(fnt, { id: UI_FONT_ID });
  if (!fontR.ok) {
    logger.channel("ui").warn(`字体解析失败：${fontR.error.code} ${fontR.error.message}（HUD 会退回 DOM）`);
    return null;
  }
  const fontDec = decodeImage(fontPngBytes);
  const skinDec = decodeImage(skinPngBytes);
  if (!fontDec.ok || !skinDec.ok) {
    logger.channel("ui").warn("UI 图解码失败（HUD 会退回 DOM）");
    return null;
  }
  let json: UiSkinJson;
  try {
    json = JSON.parse(skin) as UiSkinJson;
  } catch {
    logger.channel("ui").warn("ui-skin.json 不是合法 JSON（HUD 会退回 DOM）");
    return null;
  }
  const page = (name: string, w: number, h: number, pixels: Uint8Array): BakedUi["fontPage"] => ({
    name,
    width: w,
    height: h,
    pixels,
  });
  // 中文那两件是可选的。**字体与图必须同时成立**：只有 .fnt 没有 png ⇒ UV 全指向空白，
  // 画面上是"有字形位置、没有字形"，比"没有中文"更难看，也更难查。
  let cjkFont: BitmapFont | undefined;
  let cjkPage: BakedUi["cjkPage"];
  if (cjkFnt === null || cjkPngBytes === null) {
    logger.channel("ui").warn("没有中文字形资产（背包行用英文 kind）");
  } else {
    const r = parseBmFont(cjkFnt, { id: UI_CJK_FONT_ID, pageBase: 2 });
    const dec = decodeImage(cjkPngBytes);
    if (!r.ok) logger.channel("ui").warn(`中文字体解析失败：${r.error.code} ${r.error.message}（背包行用英文 kind）`);
    else if (!dec.ok) logger.channel("ui").warn(`中文字形图解码失败：${dec.error.code}（背包行用英文 kind）`);
    else {
      cjkFont = r.value;
      cjkPage = page("ui-font-cjk.png", dec.value.width, dec.value.height, dec.value.pixels);
    }
  }

  return {
    font: fontR.value,
    ...(cjkFont === undefined || cjkPage === undefined ? {} : { cjkFont, cjkPage }),
    fontPage: page("ui-font.png", fontDec.value.width, fontDec.value.height, fontDec.value.pixels),
    skinPage: page("ui-skin.png", skinDec.value.width, skinDec.value.height, skinDec.value.pixels),
    skinJson: json,
  };
}

/** 物品种类 → 显示名。**呈现决定**，所以留在宿主（引擎只认 `kind` 字符串）。
 *
 * ★ 放在**模块级**而不是 `main()` 里面：`createHudUi` 的 `labelOf` 是个闭包，
 *   在 `main()` 里声明 `const` 会让它落在 TDZ 里 —— 今天恰好没被提前调用，
 *   但「恰好」不是保证（背包第一次打开发生在哪一帧不由这里决定）。
 *   中文标签生效的前提是**中文字体读到了**，这个判断在 `createHudUi` 的调用点上。 */
const ITEM_LABEL: Record<string, string> = {
  tree: "木头",
  rock: "石头",
  berry: "浆果",
  flint: "燧石",
  grass_tuft: "草",
  reed: "芦苇",
  // 批65 起战利品会进包；批67 起肉还能吃 —— 没有标签的话 HUD 里显示的是英文 kind
  meat: "肉",
  hide: "皮",
  cooked_meat: "熟肉",
  rope: "绳子",
};

// ---------------------------------------------------------------- main

export async function main(): Promise<void> {
  const canvas = document.getElementById("cv") as HTMLCanvasElement | null;
  const hud = document.getElementById("hud");
  const toastEl = document.getElementById("toast");
  if (canvas === null || hud === null || toastEl === null) {
    throw new Error("页面结构不完整：需要 #cv / #hud / #toast");
  }

  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.floor((canvas.clientWidth || 960) * dpr);
  canvas.height = Math.floor((canvas.clientHeight || 600) * dpr);

  const registry = new BackendRegistry();
  registerNullBackends(registry); // 兜底：真实后端 probe 失败时自动降级
  registry.registerGfx(webgl2Backend, 100);
  registry.registerInput(domInputBackend, 100);
  registry.registerAudio(webAudioBackend, 100);
  // 脚本后端：wasm 从**本目录**取（`web/glue.wasm`），不依赖 unpkg ——
  // 否则"离线能不能跑"就变成了对 CDN 的依赖。
  registry.registerScript(createLuaScriptBackend({ wasmPath: new URL("glue.wasm", location.href).href }), 100);

  // ---- 先建物理（位置访问器是惰性的：step 时才读 app）
  let appRef: GameApp | null = null;
  const physics = new SpatialHashWorld(
    makeSceneAccessor((id) => {
      const n = appRef?.scene.find(id);
      if (n === undefined) return undefined;
      return {
        id: n.id,
        worldPosition: () => n.worldPosition,
        setLocalPosition: (x: number, y: number) => n.setLocalPosition(x, y),
      };
    }),
    // ★ 不写死 cellSize：格宽由引擎按实体尺寸定（`2 × 全场最大 range`，这里的世界是 1.4）。
    //   写死 4 的时候，0.45~0.7 半径的实体被塞进"每格能装几十个"的粗桶里，
    //   每次查询白扫上百个候选 —— 2000 体规模下实测差 2.3 倍（见 T338）。
    { maxIterations: 3 },
  );

  let heroId = -1;
  /**
   * 上一 tick 的玩家位置，用来算朝向（批112）。
   * ★ `null` = 还没有上一 tick（首帧）：此时**不**设朝向，用装配时的初始角度。
   *   把首帧的"从 (0,0) 到出生点"当成一段位移，会让玩家一进游戏就朝着
   *   地图原点 —— 看起来像随机朝向。
   */
  let lastHeroPos: { x: number; z: number } | null = null;
  let hudTick = 0;

  // ---- 资产烘焙（必须在渲染模块之前：图集是渲染 init 的输入）
  const baked = await bakeAtlasFromAssets();
  const atlasLabel = baked === null ? "procedural" : baked.label;

  // ---- 渲染模块（follow 闭包读 heroId，世界建好后才有效）
  const renderMod = createRenderModule({
    viewportWidth: canvas.width,
    viewportHeight: canvas.height,
    zoom: 26 * dpr,
    tiltY: 0.62,
    atlas: baked?.atlas,
    follow: () => {
      if (heroId < 0) return undefined;
      const n = appRef?.scene.find(heroId);
      if (n === undefined) return undefined;
      // 2.5D：世界的 z 就是 Node 的 y（Node 只有二维局部坐标）
      const p = n.worldPosition;
      return { x: p.x, z: p.y };
    },
  });

  // 脚本模块：单次调用 16ms 预算（≈半个 tick）。不设预算的死循环会挂住整个页面。
  const scriptMod = createScriptModule({ callTimeoutMs: 16 });

  // 玩家移动控制：**下沉成扩展**（原来这段在宿主里，第二宿主就得抄一遍）。
  // ★ 模块不会被框架自动 update —— 由下面的 onStep 手动驱动（脚本模块也是这么做的）。
  const controllerMod = createControllerModule({
    poll: () => (appRef === null ? EMPTY_INPUT : appRef.platform.input.poll()),
  });

  // 批112：动画模块（每实体时钟 + 只读 clip 注册表）。
  // ★ 它**不自动跑**，由 onStep 手动驱动 —— 与其它模块一致；
  //   位置排在 `syncDirFrames` 之后，才能"这一 tick 换了方向、这一 tick 就出新帧"。
  const animMod = createAnimModule({ clips: HERO_CLIPS });

  // ---- HUD / 背包（批71）：从手写 DOM 迁到引擎的 UI 模块
  //
  // ★ 顺序约束：`createUiModule` 必须在 `bootGameApp` **之前**（它是个 module，
  //   init/start 要交给 ModuleRegistry 排序），而那时 `platform.gfx` 还不存在 ——
  //   所以纹理走 `pageSources`（数据，不是句柄），由模块在自己的 init 里建。
  //   这与渲染模块接受 `atlas` 数据是同一条路：宿主不必为了"先建两张贴图"把 boot 拆成两段。
  //
  // ★ 降级：UI 资产读不到时 `baked.ui === null`，此时**不建 UI 模块**，
  //   HUD 退回 DOM 一行（`hud.textContent = hudLine(...)`）。降级路径只保留一行文本 ——
  //   保留一整套 DOM 面板等于两份实现同时维护，而"两份实现"迟早会给出两个答案。
  const bakedUi = baked?.ui ?? null;
  let hudUi: HudUiHandle | null = null;
  if (bakedUi !== null) {
    const r = createHudUi({
      font: bakedUi.font,
      // 中文在才传：`labelOf` 与字体是**同一件事的两半** —— 传了中文标签却没有字形，
      // 行文本会变成一串空白（`missingAdvance` 还占着宽度），而日志里一个字都不会响。
      ...(bakedUi.cjkFont === undefined || bakedUi.cjkPage === undefined
        ? {}
        : {
            cjkFont: bakedUi.cjkFont,
            cjkPage: bakedUi.cjkPage,
            labelOf: (kind: string): string => ITEM_LABEL[kind] ?? kind,
          }),
      skinJson: bakedUi.skinJson,
      fontPage: bakedUi.fontPage,
      skinPage: bakedUi.skinPage,
      // 设计分辨率与画布默认尺寸一致（960×600）；`expand` 让 HUD 贴屏幕边而不是贴设计框，
      // 于是超宽屏上左上角的那块不会跑到黑边里。
      viewport: { designWidth: 960, designHeight: 600, scaleMode: UiScaleMode.Expand },
      dpr,
      hints: { drop: keyLabel("drop"), bag: keyLabel("bag"), pick: keyLabel("harvest") },
      // 点中背包行 = 选中（走的是**真实指针路径**：命中测试 → click 事件 → 这里）
      onSelectRow: (i) => {
        selectBagRow(i);
      },
      // 拖拽换位：UI 只报「从第几行拖到第几行」，改库存是宿主的事。
      // ★ 换的是格子**内容**不是节点（见 `swapStacks` 的注释）。
      // ★ 失败只 warn 不弹 toast：越界是「拖到缝里」这种操作噪音，
      //   弹提示会盖住 HUD，而不弹的话下一帧的 `setBag` 自己就把画面拉正了。
      onSwapRows: (from, to) => {
        if (heroId < 0) return;
        const swapped = swapStacks(scene, heroId, from, to);
        if (!swapped.ok) {
          console.warn(`[bag] 换位失败：${swapped.error.code} ${swapped.error.message}`);
        }
        syncBagUi();
      },
    });
    if (r.ok) hudUi = r.value;
    else console.warn(`[ui] UI 模块没建起来：${r.error.code} ${r.error.message}（HUD 退回 DOM）`);
  }
  // UI 画出来之后，DOM 的 #hud 就只剩诊断用途 —— 它必须是 hidden，
  // 否则屏幕上会有两份 HUD（一份引擎画的、一份 DOM 的），而两边数字可能不同步。
  hud.hidden = hudUi !== null;

  /**
   * 背包面板的过渡（批76）：两条属性轨道 —— 不透明度 0→1、位移 −8→0。
   *
   * ★★ 为什么这是一个"真实消费者"而不是示例代码：`tween.ts` 只回答
   *   "时间 → 值"，没有任何东西持有进度、也没人把值写回 UI。这里补上后半段：
   *   `advancePlayer`（推进）→ `applyUiSamples`（写进节点）→ `invalidate`（重排重画）。
   *   少了最后一步，值算得再对屏幕也不动 —— 而这正是"接口齐全但没接线"的典型。
   *
   * ★ 时长按**逻辑步**（`BAG_FADE_TICKS`）指定，再用调度器的 `fixedDt` 换成毫秒：
   *   写死 200ms 的话，30Hz 与 144Hz 上看到的帧数差近 5 倍（见 `ticksToMs` 注释）。
   *
   * ★ 关闭不做淡出（v1 限制）：`setBag(null)` 会把面板 `visible=false`，
   *   而不可见节点**不进布局**（`layoutTree` 的约定），先淡出再藏需要宿主维护
   *   "正在淡出"的第三态。记在缺口里，不在这一批硬塞。
   */
  const BAG_FADE_TICKS = 6;
  /** 滑入的起始位移（设计像素，向上 8px）。终点恒为 0 —— 过渡不该留下偏移。 */
  const BAG_SLIDE_FROM = -8;
  let bagTween: TweenPlayer | null = null;
  /** 过渡目标查询：按 id 在 UI 树里找节点。 */
  const uiNodeById = (id: string) => hudUi?.module.root.find(id);

  /** 开/关背包（两个入口 —— 键盘与自检页 —— 都走这里，否则两边的过渡会不一样）。 */
  function setBagOpen(next: boolean): void {
    bagOpen = next;
    if (next) bagSel = 0;
    syncBagUi();
    const t = bagTween;
    if (t === null) return;
    if (next) {
      // 回到起点（两条轨道都从 from 开始），立刻把起点值写进去：
      // 不先写的话，第一帧会看到"上一轮结束时的 opacity=1"，闪一下。
      // ★★ `player.playing` 也必须恢复：关背包时把它置了 false（整组停），
      //   `reset()` 只重置**轨道**的进度与 autoplay，不动整组开关 ——
      //   只 reset 不恢复的话，第一次关过之后再打开就再也不会推进
      //   （症状：面板一直是全透明，而 `anim()` 读出来的起点 0 完全正确）。
      //   这条是浏览器判据抓出来的：Node 判据直接调 `advancePlayer`，
      //   不会经过"关闭 → 重开"这条宿主状态路径。
      t.playing = true;
      t.reset();
      applyUiSamples(advancePlayer(t, 0), uiNodeById);
      hudUi?.module.invalidate();
    } else {
      t.playing = false;
    }
  }

  /**
   * 给"世界里新出现的东西"补挂精灵（批123）。
   *
   * ★★ 为什么需要它：`attachWorldVisuals` 只在**装配那一刻**调过一次，而再生资源与
   *   尸体是运行期才出现的 —— 它们没有 `render.sprite`，**画面上就是不存在**。
   *   这不是"画得不好看"，是"砍完的树重生了、玩家看不见也想不到去找"。
   * ★ 为什么用阀门而不是每帧调：函数本身是幂等的（有精灵就跳过），但每次都要扫
   *   全部地形/投放点/资源/尸体。按"数量没变就不扫"走，跑起来只有事件那几帧有开销。
   * ★ 计数必须**单调**：`spawned` 只涨；尸体用 `corpses + decayed`（涨 + 烂掉的总数），
   *   两个都只涨。用 `corpses` 本身的话，"这 tick 烂了一具、又死了一具"数量不变 ⇒
   *   新那具的精灵永远补不上，而尸体会腐烂、所以这个错不会累积成"看不见"，
   *   只会在少数几帧里闪一下没图 —— 正是最难查的那一类。
   */
  let lastVisualKey = -1;
  let lastVisualError = "";
  function syncNewVisuals(): void {
    const s = appRef?.scene;
    if (s === undefined) return;
    const t = worldState.tasks;
    const c = corpsesHandle;
    const key = (t === null ? 0 : t.stats().spawned) + (c === null ? 0 : c.stats.corpses + c.stats.decayed);
    if (key === lastVisualKey) return;
    lastVisualKey = key;
    const v = attachWorldVisuals(s, atlasFrames);
    // ★ 失败要说出来：补挂失败的症状是"新长出来的资源没有图"，而那一刻
    //   世界逻辑一切正常 —— 不说的话没人会去查。
    // ★★ 但**同一个错误只报一次**：这条路径跟着"世界里多了东西"跑，
    //   每长一具尸体就弹一次错的话，提示条会被反复顶出来（永远收不下去），
    //   而真正的坏消息埋在那一片重复里。实测症状：自检页里
    //   「提示条不再走 DOM…2 秒后自己收起」变红 —— 提示条不是坏了，是被刷爆了。
    if (!v.ok && v.error.code !== lastVisualError) {
      lastVisualError = v.error.code;
      toast(`补挂精灵失败：${v.error.code} ${v.error.message}`);
    }
  }

  const worldMod = createWorldModule(physics, {
    onTick: (t) => (hudTick = t),
    onStep: (tick, dt) => {
      // 批76：UI 过渡推进（时间 → 值 → 节点 → 重排）。
      // ★ 放在逻辑步里而不是渲染帧里：时长按 tick 配置，只有这里才知道"一步有多长"；
      //   放在渲染帧里的话，同一段过渡在 60fps 与 144fps 上会走不同的进度。
      // ★ 只有 `changed > 0` 才标脏：静止的过渡每帧标脏会让整棵 UI 每帧重排，
      //   文本缓存跟着全废，症状是"UI 一直卡但看不出在动什么"。
      if (bagTween !== null) {
        const applied = applyUiSamples(advancePlayer(bagTween, dt * 1000), uiNodeById);
        if (applied.changed > 0) hudUi?.module.invalidate();
      }
      // 控制器 / 再生任务 / 脚本：都由宿主在**同一个** onStep 里驱动（模块不会被自动 update）
      // ★ 控制器必须在物理之前：位置先变，再解算重叠
      controllerMod.update(tick, dt);
      // ---- 批112：玩家朝向 = 本 tick 的**实际位移**方向
      //   ★ 不读控制器内部状态：控制器算的是"想往哪走"（含被挡住的部分），
      //     而画面要跟的是"真的往哪挪了"。贴着墙时两者不同，读前者会让角色
      //     一直面朝墙外 —— 看起来像穿模的前兆。
      //   ★ 停下时 `angleOf` 返回 null ⇒ **保持**上一朝向，别掰向东（见 facing.ts 文件头）。
      if (heroId >= 0) {
        // ★ 用 `worldPosition`（世界坐标）而不是本地坐标：玩家是根节点，两者今天相同 ——
        //   但"今天相同"不是理由，等它挂到容器下时本地坐标会立刻错，而错法是"朝向反了"。
        //   注意字段名：XZ 平面里的第二轴在节点上是 `y`（屏幕向下为正），不是 `z`。
        const wp = appRef?.scene.find(heroId)?.worldPosition;
        if (wp !== undefined) {
          if (lastHeroPos !== null) {
            const face = appRef?.scene.find(heroId)?.get<Facing>(FACING_TYPE);
            if (face !== undefined) faceFromMotion(face, lastHeroPos.x, lastHeroPos.z, wp.x, wp.y);
          }
          lastHeroPos = { x: wp.x, z: wp.y };
        }
      }
      // ---- 动作分发：**只认动作名**，不认物理键码（键位在 InputMap 里，见 input-map.ts）
      // ★ 读的是 controllerMod.snapshot（这一 tick 已经 poll 过的那一份）：
      //   再 poll 一次会把"刚按下"的边缘吞掉 —— M168 那个 bug 的另一种写法。
      // ★ 为什么放在固定步里而不是 keydown 里：一帧跑多个 tick 时，keydown 会
      //   在"帧"的粒度上触发，固定步在"tick"的粒度上消费 —— 后者才是可回放的。
      dispatchActions();
      worldState.tasks?.update(tick, dt);
      // 生物：在玩家控制器之后、物理之前（它读的是本 tick 的位置，改的也是位置）
      mobsHandle?.update(tick, dt);
      // 批123：尸体在生物之后（刚死的那一具在同一 tick 里还没到期，清不掉）
      corpsesHandle?.update(tick, dt);
      syncNewVisuals();
      // 批108：朝向 → 帧名。**必须排在生物之后**：它读的是本 tick 已经转过的角度，
      // 排在前面就会稳定慢一 tick（快跑时看得出来：转弯的那一帧还是旧朝向）。
      if (appRef !== null) syncDirFrames(appRef.scene, hasFrame);
      // 批112：动画采样 → 写 `Sprite.frame`。
      // ★ 必须紧跟在 `syncDirFrames` 之后：前者只改 `clipId`，后者才出帧。
      //   反过来（先采样再选 clip）会让每次转向都慢一 tick —— 60fps 下 16ms，
      //   肉眼不容易发现，但"转向时那个方向的第一帧永远是旧的"是可测的。
      animMod.update(tick, dt);
      // 生存：在场所有带 `game.hunger` 的实体（目前只有玩家）各推进一 tick。
      // ★ 放在生物之后：饿死是"这一 tick 的最后一件事"，免得同一 tick 里
      //   "先被判定饿死、再被打"这种顺序歧义。
      survivalMod.update(tick, dt);
      // 表现层：倒计时推进与到点还原。**必须在渲染之前**（onStep 天然早于 onRender），
      // 放在渲染之后会让"最后一帧闪色"多显示一帧（看起来闪得比配置久）。
      feedbackMod.update(tick);
      // 不 await：宿主在同步的 onStep 里。ScriptModule 内部有串行队列，
      // 保证 tick N+1 不会插到 tick N 的 Lua 调用中间。
      void scriptMod.update(tick, dt);
    },
  });

  // ---- 世界生成（批46）：把"生成 → 装配 → 可见化 → 出生 → 再生 → 采集"接进浏览器
  //
  // ★ 顺序是硬约束，不是风格：
  //   ① 生成是**纯数据**，可以在 boot 之前跑（它不需要 Scene）；
  //   ② 装配要求**空场景**（`WORLD.SCENE_NOT_EMPTY`）—— 所以必须发生在任何宿主摆件之前；
  //   ③ 组件注册要在装配之前（装配要按类型挂组件、读档要按类型重建）。
  //   宿主自己的摆件（树/石头/立牌）放在最后，它们只是"世界里的装饰"。
  const WORLD_SEED = 20261023;
  const WORLD_W = 32;
  const WORLD_H = 24;
  const planR = generateWorld({ seed: WORLD_SEED, width: WORLD_W, height: WORLD_H, maxSitesPerCell: 0 });
  const plan: WorldPlan | null = planR.ok ? planR.value : null;
  if (!planR.ok) console.error(`[worldgen] 生成失败：${planR.error.code} ${planR.error.message}`);

  /** 世界链的产物（宿主与自检页都要读它；`__engine.world` 就是它的投影）。 */
  const worldState = {
    plan,
    player: null as PlayerHandle | null,
    visual: null as WorldVisualReport | null,
    tasks: null as WorldTaskModuleHandle | null,
    /** 导航网格（批60）：从生成计划建一次，之后不再变（地图要变就整张重建）。 */
    nav: null as NavGrid | null,
    /** 生物群（批66）：世界里会走、会打、会掉东西的活物。 */
    mobs: null as MobWorldHandle | null,
    assembled: false,
  };

  /** 可用帧：图集来自资产就用资产的帧名，降级则用程序化图集的帧名 —— 两者必须一致。 */
  const atlasFrames: readonly string[] =
    baked === null ? [...buildProceduralAtlas().frames.keys()] : [...baked.atlas.frames.keys()];

  /**
   * 方向帧解析用的 `has`。**只在这里建一次**：图集在 boot 之后只读，
   * 每 tick 重建一个 Set 是纯浪费（生物数 × 每帧）。
   */
  const frameSet = new Set(atlasFrames);
  const hasFrame = (frame: string): boolean => frameSet.has(frame);

  const worldgenMod: IModule = {
    id: "world.worldgen",
    init(ctx: ModuleContext): Result<void, EngineError> {
      const scene = ctx.services.require(Services.Scene);
      const p = worldState.plan;
      if (p === null) {
        return err(engineError("WORLD.GEN_FAILED", "世界计划没有生成出来，装配无法进行"));
      }
      // 组件注册（幂等）：装配与读档都按类型重建组件，漏一个就是"读档少一半东西"
      registerWorldComponents(scene.components);
      registerResourceComponent(scene.components);
      registerPlayerComponents(scene.components);
      // 批123：尸体组件。不注册的话生物死亡时的 `spawnCorpse` 会报
      // `CORPSE.NO_COMPONENT`，而战利品退回进包 —— 画面上只是"地上没有尸体"，
      // 看起来像"这次没掉东西"。
      registerCorpseComponent(scene.components);
      // ★ 批123：生物身上的战利品表（`game.loot`）。不注册的话 `spawnMob`
      //   在 attach 时会失败 —— 但那是在生物模块 init 里，报错会被当成"世界没装配好"；
      //   更糟的是"注册了但忘了 save" ⇒ 读档后生物不掉东西（见 `loot.ts` 的 `LOOT_TYPE`）。
      registerLootComponent(scene.components);
      // ★ 背包也要注册：`game.item` / `game.inventory` 不注册的话，
      //   存档里这两类组件的字段会在读档时**静默丢失**（"读档后背包空了"）。
      registerInventoryComponents(scene.components);
      // 批66：玩家与生物都要血量/攻击/阵营（玩家的那三个在下面 hero 装配处挂上）
      registerHealthComponent(scene.components);
      registerAttackerComponent(scene.components);
      registerFactionComponent(scene.components);
      registerMoverComponent(scene.components);
      registerFacingComponent(scene.components);
      registerDirSpriteComponent(scene.components);
      // 批67：饱食度。**不注册的后果是 READ 档里这一项静默丢失**（读回来 100，
      // 玩家以为自己没饿过）—— 与背包那一条同一个坑。
      registerHungerComponent(scene.components);
      // 批69：受击反馈。**基色存在组件里**（还原要用），所以不注册就等于
      // "读档回来正在闪的怪永远停在闪色上"（基色丢了）。
      registerFeedbackComponent(scene.components);
      if (!scene.components.has(SPRITE_TYPE)) {
        scene.components.register(new Sprite().schema, () => new Sprite());
      }
      const a = assembleWorld(p, scene);
      if (!a.ok) return a;
      worldState.assembled = true;
      // ★ 缺帧在这里是**错误**（渲染模块自己只会 warn + 跳过，于是一类东西静默消失）
      const v = attachWorldVisuals(scene, atlasFrames);
      if (!v.ok) return v;
      worldState.visual = v.value;
      const sp = spawnPlayer(scene, p);
      if (!sp.ok) return sp;
      worldState.player = sp.value;
      // 导航网格：源的唯一性是**生成计划**（不是场景字段），于是它与渲染出来的地形必然同源。
      // 场景字段与计划的一致性由 Node 判据交叉验证（`NavGrid.fromScene` vs `fromPlan`，
      // 见 nav-grid.test.ts）—— 这里只建一次，失败就当成世界没装配好。
      const nav = NavGrid.fromPlan(p);
      if (!nav.ok) return nav;
      worldState.nav = nav.value;
      return ok(undefined);
    },
    describe(): string {
      const v = worldState.visual;
      return v === null ? "世界：未装配" : `世界：${v.terrain} 块地形 / ${v.sites} 个投放点`;
    },
  };

  /**
   * 每个资源节点出生时带几个物品（`ResourceMarker.count` 的初值）。
   *
   * ★ 这是**产品决定，留在宿主**：引擎只认"这一格有几个"，不认识芦苇。
   * ★ 批122 之前这张表是传给 `pickupNearby` 的"产量"，现在是传给世界的"存量" ——
   *   两者在**自然节点**上完全等价（采一次拿光），但只有后者能表达"丢 40 个 berry
   *   在地上、一次捡回 40 个"：产量表会让它一次只捡 1 个。
   * ★ 这张表同时是"背包堆叠上限"的存在意义：单次产出 > 1 时，`maxStack`（每堆 40）
   *   才会真的被撞到（采 25 次芦苇 = 50 个 ⇒ 自动开第二堆）。
   */
  const RESOURCE_YIELD: Record<string, number> = {
    berry: 1,
    reed: 2,
    tree: 1,
    rock: 1,
    flint: 1,
    grass_tuft: 1,
  };

  // 再生任务：每 30 tick（约 1 秒 @30Hz）在可通行群系里抽 2 格长出新资源
  const tasksHandle: WorldTaskModuleHandle | null =
    plan === null
      ? null
      : createWorldTaskModule({
          tasks: {
            schema: WORLD_TASK_SCHEMA,
            tasks: [{ id: "regen", periodTicks: 30, phase: 0, picksPerRun: 2, biomes: ["grass", "forest"] }],
          },
          plan,
          maxResources: 96,
          // 产量在**出生那一刻**冻进 `count`：之后改这张表不影响地上已有的资源
          yieldOf: (kind) => RESOURCE_YIELD[kind] ?? 1,
        });

  /**
   * 任务模块的**包装**：只为了一件事 —— 让它 `deps` 上 `world.worldgen`。
   *
   * ★ 为什么不能直接把 `createWorldTaskModule()` 的句柄塞进 modules：
   *   它的 `init` 会检查场景里有没有注册 `world.resource`，而组件是 worldgen 模块注册的。
   *   两个模块都声明"无依赖"时，谁先 init 就成了注册顺序的隐式约定 ——
   *   那种约定在重构时会静默失效（这里表现为启动直接失败，还算好的）。
   */
  const tasksMod: IModule = {
    id: "world.tasks",
    deps: [worldgenMod.id],
    init(ctx: ModuleContext): Result<void, EngineError> {
      if (tasksHandle === null) return ok(undefined);
      // 世界任务模块的 init 是**同步**的（只查场景有没有注册 world.resource）——
      // 这里显式断言这一点，而不是把 Promise 分支混进来：异步 init 会让"模块起没起来"
      // 变成一个时序问题，而这一步没有异步的必要。
      const r = tasksHandle.init(ctx) as Result<void, EngineError> | undefined;
      if (r === undefined) return ok(undefined);
      if (!r.ok) return r;
      worldState.tasks = tasksHandle;
      return ok(undefined);
    },
    start(): void {
      tasksHandle?.start?.();
    },
    stop(): void {
      tasksHandle?.stop?.();
    },
    describe(): string {
      const s = worldState.tasks?.stats();
      return s === undefined ? "世界任务：未启动" : `世界任务：活 ${s.alive} / 累计 ${s.spawned}`;
    },
  };

  // ---- 生物群（批66）：世界里**终于有活物了**
  //
  // ★ 模板只写数字，不写"兔子应该跑多快"这种判断 —— 那是配表，不是引擎。
  // ★ `damage: 0` 的兔子不挂攻击组件（见 spawn-mob.ts）：它只跑不打，
  //   而"凶不凶"由**组件有没有**决定，不额外加一个布尔开关。
  /**
   * 尸体留多久（批123）。30Hz 下 900 tick = 30 秒。
   * ★ 一个常量而不是两处字面量：AI 击杀（`mobsMod` 的 `corpse.decayTicks`）与
   *   玩家击杀（`attackNearest`）必须是**同一个**时长 —— 两处各写一遍的话，
   *   调平衡时只改一处，玩家会发现"自己打死的尸体留得比怪打死的长"。
   */
  const CORPSE_DECAY_TICKS = 900;

  /**
   * 玩家击杀留尸体的**诊断账**（批123）。
   *
   * ★ 为什么需要它：这条分支有四个前置条件（节点还在 / 有战利品表 / 有导航网格 /
   *   放得下），任何一个不成立都表现为**同一个现象**——"地上没多一具尸体"。
   *   没有这一对计数器，那四种原因长得一模一样，只能靠猜。
   * ★ `lastCorpseSkip` 是"这次为什么没留"的原话（空串 = 留了）。
   *   它与 `playerCorpses` **一起**读才有意义：只看计数会分不清"没走到这条分支"
   *   与"走了但每次都失败"。
   */
  let playerCorpses = 0;
  let lastCorpseSkip = "";
  /**
   * 玩家这一下打死的**是谁**（`id` / 生物种类 / 节点名）。
   *
   * ★ 为什么必须记：`NO_LOOT_TABLE` 只说明"它不是生物"，不说明"它是谁"。
   *   没有这一项时，"玩家打不到兔子、却打死了旁边的靶子"与"战利品表没建起来"
   *   报的是同一个码 —— 一个在选择侧，一个在配表侧，修法完全不同。
   * ★ `mobKind` 为 `null` = 场景里没有这个节点的生物登记（靶子、树、其他有血量的东西）。
   */
  let lastVictim: { id: number; mobKind: string | null; name: string } | null = null;

  const MOB_TEMPLATES = [
    {
      kind: "rabbit",
      frame: "rabbit",
      width: 0.9,
      height: 0.9,
      radius: 0.28,
      maxHp: 4,
      damage: 0,
      range: 1.4,
      cooldownTicks: 20,
      speed: 1.1,
      team: "prey",
      loot: [{ kind: "meat", count: 2 }],
    },
    {
      kind: "hound",
      frame: "hound",
      width: 1.1,
      height: 1.1,
      radius: 0.34,
      maxHp: 8,
      damage: 2,
      range: 1.7,
      cooldownTicks: 15,
      speed: 2.3,
      team: "hunter",
      loot: [{ kind: "hide", count: 1 }],
    },
  ] as const;

  // ★ 关系表是**宿主**的配置（引擎不认识"猎人"）：玩家与猎狗同队，兔子是猎物。
  //   于是猎狗会追兔子、玩家能打兔子，而玩家与猎狗之间是友军（互不攻击）。
  const MOB_FACTIONS = createFactions();
  MOB_FACTIONS.setStance("hunter", "prey", "foe");

  /**
   * 挑出生点：**等距抽样** + 避开采摘点。
   *
   * ★ 不用随机：同一个种子要跑出同一批位置（回放与截图比对都依赖这条）。
   * ★ 避开玩家出生点 2 格内：出生就贴脸会让"第一次看见怪物"变成"被怪物淹没"。
   */
  function pickMobSpots(grid: NavGrid, hounds: number, rabbits: number, avoidCell: number): MobSpot[] {
    const walk: number[] = [];
    const ax = grid.cellX(avoidCell);
    const az = grid.cellZ(avoidCell);
    for (let i = 0; i < grid.total; i++) {
      if (!grid.isWalkableIndex(i)) continue;
      const cx = grid.cellX(i);
      const cz = grid.cellZ(i);
      if (Math.abs(cx - ax) <= 2 && Math.abs(cz - az) <= 2) continue;
      walk.push(i);
    }
    const total = hounds + rabbits;
    const out: MobSpot[] = [];
    if (walk.length === 0) return out;
    const stride = Math.max(1, Math.floor(walk.length / total));
    for (let k = 0; k < total; k++) {
      const cell = walk[Math.min(walk.length - 1, k * stride)];
      if (cell === undefined) continue;
      out.push({ template: k < hounds ? 1 : 0, cell });
    }
    return out;
  }

  let mobsHandle: MobWorldHandle | null = null;
  /** 尸体模块句柄（批123；与 `mobsHandle` 同一个形状：init 里拿到、onStep 里驱动）。 */
  let corpsesHandle: CorpseModuleHandle | null = null;

  // ---------------------------------------------------------------- 表现层（批69）
  //
  // ★ 分工：**闪色与挤压是引擎的**（`feedback.ts` 直接改 `Sprite`，判据能读），
  //   **伤害数字是宿主的**（它是贴在屏幕上的 DOM，引擎不该规定字体与排布）。
  //   把数字也塞进引擎的后果：引擎要么带一个字体资源，要么得规定字形——
  //   而"数字在屏幕上往上飘 0.9 秒"是**表现决定**，不是世界规则。
  const feedbackMod: FeedbackHandle = createFeedbackModule({ id: "render.feedback.demo" });

  // ---------------------------------------------------------------- 顿帧（批73）
  //
  // ★ 策略抽到 `host/hitstop-policy.ts`（批74）：它是玩法判断，而玩法判断要被
  //   单测钉住。第一版内联在这里，分支顺序写反了（"任何死亡都冻 12 步" ⇒
  //   猎狗咬死兔子也冻），只有浏览器里看得出来 —— 两条顿帧判据时红时绿跑了
  //   很久，最后以 CI 上 M292「还原不干净」的形式爆出来。
  //   演示页的取舍：玩家打中冻 3 步（≈0.1s，够看见"这一下是实的"）、
  //   击杀冻 12 步（≈0.4s，和闪色同长，让"打死了一个东西"有分量）、
  //   **怪打玩家不冻** —— 群战里每个怪都冻会让画面一帧一停，
  //   而冻结本身不报错，只是手感变怪，所以这条必须显式写出来。
  const hitstopMod: HitstopHandle = createHitstopModule({
    id: "combat.hitstop.demo",
    policy: (info) => demoHitstopPolicy(info, heroId),
  });

  /** 受击闪多久（tick，30Hz ⇒ 12 ≈ 0.4s：够看见，又不会糊住下一次攻击）。 */
  const HIT_FLASH_TICKS = 12;
  /** 挥击挤压多久（比闪烁短：它是"动作"，不是"状态"）。 */
  const HIT_PUNCH_TICKS = 6;
  /** 伤害数字活多久（毫秒：它是**画面**，跟着渲染时钟走，与 tick 无关）。 */
  const DMG_LIFE_MS = 900;
  /** 表现层自己吞掉的错误（不打断游戏，但要能在诊断面看到）。 */
  const feedbackErrors: string[] = [];

  interface DamageNumber {
    readonly el: HTMLDivElement;
    readonly x: number;
    readonly z: number;
    readonly bornMs: number;
    readonly lifeMs: number;
    readonly text: string;
    readonly dead: boolean;
    /** 谁打的（批74：判据要能只数自己的数字 —— 生物打斗也在冒数字）。 */
    readonly by: number;
  }
  const damageNumbers: DamageNumber[] = [];

  /**
   * 数字挂在这一层上（`position: fixed` + `pointer-events: none`）：
   * ★ 必须是 fixed 而不是 absolute：`getBoundingClientRect()` 给的是**视口**坐标，
   *   页面一旦滚动（或 HUD 在布局里挪位置），absolute 的数字会整体偏掉。
   */
  const fxLayer = document.createElement("div");
  fxLayer.id = "fx";
  fxLayer.style.cssText =
    "position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;overflow:hidden;z-index:20;";
  document.body.appendChild(fxLayer);

  /** 冒一个伤害数字（世界坐标 → 屏幕，跟着相机走）。 */
  function spawnDamageNumber(x: number, z: number, text: string, dead: boolean, by: number): void {
    const el = document.createElement("div");
    el.className = "dmg";
    // ★ 带 `data-dmg`：自检页要能**读到**屏幕上显示的是几，而不是只数元素个数
    //   （"冒了一个数字"与"冒的是 3 还是 10"是两件事，后者才是玩家看到的）。
    el.dataset.dmg = text;
    // ★ 带 `data-dmg-by`（批74）：判据要能只数**自己的**数字。演示世界里
    //   猎狗常年追杀兔子，生物打斗也在冒数字 —— 不区分来源的话，
    //   "数字会消失"这条判据在打斗窗口里永远等不到一个空数组。
    el.dataset.dmgBy = String(by);
    el.textContent = text;
    el.style.cssText =
      "position:absolute;left:0;top:0;font:700 14px/1 ui-monospace,monospace;" +
      `color:${dead ? "#ffd54a" : "#ff6b5a"};text-shadow:0 1px 2px rgba(0,0,0,.55);` +
      "pointer-events:none;will-change:transform,opacity;";
    fxLayer.appendChild(el);
    damageNumbers.push({ el, x, z, bornMs: performance.now(), lifeMs: DMG_LIFE_MS, text, dead, by });
  }

  /**
   * 每帧把数字挪到对应世界位置（并上浮/淡出/到期删除）。
   *
   * ★ 到期必须**真的从 DOM 里删掉**：只把 opacity 设成 0 的话，
   *   打一场之后页面上会堆着几百个不可见 div，而自检页"数元素"永远数得到 ——
   *   于是"数字会消失"这条判据永远不会失败。
   */
  function updateDamageNumbers(now: number): void {
    if (damageNumbers.length === 0) return;
    if (canvas === null) return;
    const rect = canvas.getBoundingClientRect();
    const cam = renderMod.camera;
    for (let i = damageNumbers.length - 1; i >= 0; i--) {
      const d = damageNumbers[i];
      if (d === undefined) continue;
      const t = (now - d.bornMs) / d.lifeMs;
      if (t >= 1) {
        d.el.remove();
        damageNumbers.splice(i, 1);
        continue;
      }
      const c = cam.project(d.x, d.z);
      const px = rect.left + ((c.x + 1) / 2) * rect.width;
      const py = rect.top + ((1 - c.y) / 2) * rect.height - t * 28;
      const op = t < 0.7 ? 1 : 1 - (t - 0.7) / 0.3;
      d.el.style.transform = `translate(${px.toFixed(1)}px, ${py.toFixed(1)}px)`;
      d.el.style.opacity = op.toFixed(2);
    }
  }

  /**
   * 一次命中的全部表现：数字 + 受击闪 + 挥击挤压。
   *
   * ★ 位置在**这里**取（而不是在回调里取）：`onKill` 之后目标可能已经被销毁，
   *   而回调顺序保证 `onHit` 在前 —— 但这个函数也会被 `attackNearest()` 直接调用，
   *   两条路径走同一段代码才不会"玩家打的看得见、怪打玩家的看不见"。
   */
  /**
   * 一次命中的全部表现：数字 + 受击闪 + 挥击挤压 + 顿帧。
   *
   * ★ 位置在**这里**取（而不是在回调里取）：`onKill` 之后目标可能已经被销毁，
   *   而回调顺序保证 `onHit` 在前 —— 但这个函数也会被 `attackNearest()` 直接调用，
   *   两条路径走同一段代码才不会"玩家打的看得见、怪打玩家的看不见"。
   * ★ 收**完整的** `HitInfo`（含 before/after/overkill），不收裁剪版：
   *   顿帧策略要按 overkill 判断"这一下有多重"时，裁剪版只能让它拿到 0 ——
   *   而 0 是个看起来完全正常的假值（批65：回调少给一个参数，调用方就得猜）。
   */
  function showHit(info: HitInfo): void {
    // ★ 记仇放在这里，而不是放在 `attackNearest()` 里：这是**所有**命中都要经过的
    //   唯一一段代码（玩家手动打 / 生物按 decide 打）。放在任一边都会漏掉另一边，
    //   而漏掉的那一边恰好是玩家最常走的那条。
    worldState.mobs?.noteHit({
      attackerId: info.attackerId,
      targetId: info.targetId,
      applied: info.applied,
      tick: hudTick,
    });
    // ★ 顿帧与记仇同理：放在任一边都会让另一边没有顿帧。策略决定冻不冻
    //   （怪打玩家不冻，见上面的 `createHitstopModule`）。
    const hs = hitstopMod.trigger(info);
    if (!hs.ok) feedbackErrors.push(hs.error.code);
    const target = scene.find(info.targetId);
    if (target !== undefined) {
      const p = target.worldPosition;
      spawnDamageNumber(p.x, p.y, `-${String(info.applied)}`, info.dead, info.attackerId);
      const f = flashNode(scene, info.targetId, HIT_FLASH_TICKS);
      if (!f.ok) feedbackErrors.push(f.error.code);
    }
    const pn = punchNode(scene, info.attackerId, HIT_PUNCH_TICKS);
    if (!pn.ok) feedbackErrors.push(pn.error.code);
  }

  /**
   * 生物模块：`deps` 上 `world.worldgen`（它要用导航网格，而网格在那边建）。
   *
   * ★ 与 `tasksMod` 同一个形状：句柄在 init 里拿到，`update` 由宿主在 `onStep` 里调。
   *   不能让模块自己订阅调度器 —— 那样"生物先动还是玩家先动"就成了注册顺序的隐式约定。
   */
  const mobsMod: IModule = {
    id: "world.mobs",
    deps: [worldgenMod.id],
    init(ctx: ModuleContext): Result<void, EngineError> {
      const g = worldState.nav;
      const player = worldState.player;
      if (g === null || player === null) {
        return err(engineError("MOBS.NO_WORLD", "导航网格或玩家还没建好，生物无处落脚"));
      }
      const spots = pickMobSpots(g, 3, 10, player.cell);
      if (spots.length === 0) {
        return err(engineError("MOBS.NO_SPOT", "世界里找不到可走的出生点（地形全是水/崖？）"));
      }
      const h = createMobWorldModule({
        grid: g,
        factions: MOB_FACTIONS,
        templates: MOB_TEMPLATES,
        spots,
        range: 14,
        seed: WORLD_SEED,
        wanderEvery: 18,
        // 记仇：5 秒记忆、追 16 格（跑出 16 格才能甩掉）。这两个值是**玩法参数**，
        // 所以显式写在这里，而不是靠库里的默认值 —— 调平衡的人该在这里调。
        threatDecayTicks: 150,
        aggroCells: 16,
        // 生物打人：与玩家打怪走**同一个** showHit（否则会出现"我打的看得见、
        // 我挨打看不见"，而两边的代码都对）
        onHit: (info) => showHit(info),
        // 批123：死了原地留一具（战利品在尸体里，得自己走过去翻）。
        // ★ 时长与玩家击杀共用同一个常量（见 `CORPSE_DECAY_TICKS`）
        corpse: { ground: g, decayTicks: CORPSE_DECAY_TICKS },
        // 批124：生物长**动态体**（被树挡住、被玩家挡住、彼此挡住）。
        // ★ 不传的话它们仍然互相穿过 —— 而"穿过"与"挡住"在统计上一模一样，
        //   只有画面能分辨，所以这条接线必须有判据（浏览器自检的 bodies 那一条）。
        physics,
      });
      const r = h.init(ctx) as Result<void, EngineError> | undefined;
      if (r !== undefined && !r.ok) return r;
      mobsHandle = h;
      worldState.mobs = h;
      return ok(undefined);
    },
    describe(): string {
      const m = worldState.mobs;
      if (m === null) return "生物：未启动";
      const st = m.stats;
      return `生物：${String(st.mobs)} 只（追 ${String(st.hunting)} / 游 ${String(st.wandering)}），击杀 ${String(st.kills)}`;
    },
  };

  /**
   * 尸体模块（批123）：每 tick 把到点的尸体清掉。
   *
   * ★ 与 `mobsMod` 同一个形状（句柄在 init 里拿到、`update` 由宿主在 `onStep` 里调）：
   *   让模块自己订阅调度器的话，"尸体在生物之前还是之后清"就变成了注册顺序的隐式约定。
   * ★ 排在生物**之后**：这一 tick 刚死的那一具不会被同一 tick 清掉
   *   （`decayTicks` 相对死亡 tick 算，顺序反了就会出现"刚死就没了"的边界）。
   */
  const corpsesMod: IModule = {
    id: "world.corpses",
    deps: [worldgenMod.id],
    init(ctx: ModuleContext): Result<void, EngineError> {
      const h = createCorpseModule({ id: "world.corpses" });
      const r = h.init(ctx);
      if (!r.ok) return r;
      h.start();
      corpsesHandle = h;
      return ok(undefined);
    },
    describe(): string {
      const c = corpsesHandle;
      if (c === null) return "尸体：未启动";
      const st = c.stats;
      return `尸体：${String(st.corpses)} 具（已烂 ${String(st.decayed)}）`;
    },
  };

  const survivalMod = createSurvivalModule({
    id: "game.survival.demo",
    // 60 tick（2 秒）掉 1 点 ⇒ 满值 100 点能撑 200 秒。演示里"看得见它在掉"，
    // 但不至于让人一直在吃东西。
    decayEveryTicks: 60,
    // 饿着之后每 30 tick（1 秒）掉 1 血：20 血能撑 20 秒才死 —— 够人反应。
    starveEveryTicks: 30,
    starveDamage: 1,
  });

  /**
   * 演示用的食物表（批67）。
   *
   * ★ 浆果能吃：**采集链第一次接上了用途**（原来采了只能占格子）。
   * ★ 肉更好，且顺带回 5 血 —— 于是"打猎"比"采浆果"划算，"追→打→拾→吃"闭环成立。
   * ★ 皮/木头/石头/燧石/草丛/芦苇都**不在表里**：不能吃的东西不该有一条"营养值 0"的
   *   记录（那会让 `eat` 成功、然后什么也没发生）。
   * ★ 归一化失败在加载期就抛：配表写错不该等到"玩家按 E 没反应"才发现。
   */
  const FOOD_TABLE_R = normalizeFoodTable({
    berry: { nutrition: 15 },
    meat: { nutrition: 25, health: 5 },
    // 批68：熟肉是"制作"的产物 —— 比生肉更顶饱、回血更多。
    // ★ 这条让「采草 + 打猎 → 做 → 吃」成为一个**有比价关系**的循环：
    //   生肉直接吃是 25/5，花一份草做成熟肉是 40/10。
    cooked_meat: { nutrition: 40, health: 10 },
  });
  if (!FOOD_TABLE_R.ok) throw new Error(`食物表不合法：${FOOD_TABLE_R.error.message}`);
  const FOOD_TABLE = FOOD_TABLE_R.value;

  /**
   * 演示用的配方表（批68）。
   *
   * ★ **表序即优先级**：`C` 键做"第一条现在就能做的"。所以把贵的放前面，
   *   这样材料够的时候优先做更值钱的东西，不够才往下退。
   * ★ `rope` 目前没有用途（还没有"用绳子做别的"的配方），它的存在是为了让
   *   判据与变异有一个**非食物**的产物 —— 否则"制作"会被误认为"烹饪"。
   */
  const RECIPES_R = normalizeRecipes([
    { id: "cooked_meat", name: "熟肉", inputs: [{ kind: "meat", count: 1 }, { kind: "grass_tuft", count: 1 }], output: { kind: "cooked_meat", count: 1 } },
    { id: "rope", name: "绳子", inputs: [{ kind: "reed", count: 2 }], output: { kind: "rope", count: 1 } },
  ]);
  if (!RECIPES_R.ok) throw new Error(`配方表不合法：${RECIPES_R.error.message}`);
  const RECIPES = RECIPES_R.value;

  // 模块顺序由 ModuleRegistry 按 deps 拓扑排序（UI 依赖 `render.batch2d`），
  // 这里只决定"谁在列表里"—— 漏加的症状是"HUD 不画"，而 UI 模块自己没有任何报错。
  const modules: IModule[] = [
    worldMod,
    renderMod,
    scriptMod,
    worldgenMod,
    tasksMod,
    mobsMod,
    // ★ 排在 `mobsMod` 之后（见 `corpsesMod` 的注释）：刚死的那一具不该被同 tick 清掉
    corpsesMod,
    survivalMod,
    feedbackMod,
    hitstopMod,
    controllerMod,
    animMod,
  ];
  if (hudUi !== null) modules.push(hudUi.module);

  const appR = await bootGameApp({
    platformId: "web",
    interactive: true,
    registry,
    modules,
    seed: 20261022,
    fixedDt: 1 / 30,
    tickSource: new RafTickSource(() => performance.now()),
    backendOptions: {
      gfx: { canvas },
      input: { keyboard: window, pointer: canvas },
      audio: {},
    },
  });

  if (!appR.ok) {
    document.body.innerHTML =
      `<pre style="color:#f66;padding:16px;font:13px ui-monospace">启动失败：${appR.error.code}\n` +
      `${appR.error.message}\n\n${JSON.stringify(appR.error.detail ?? {}, null, 2)}</pre>`;
    return;
  }
  const app = appR.value;
  appRef = app;

  // ---- UI 过渡的轨道（批76）：到这一步才有 `fixedDt`，所以在这里建
  //   ★ 时长换算的唯一入口是 `ticksToMs`：轨道按**逻辑步**配置，调度器按 fixedDt
  //     收真实时间。写死毫秒会让 30Hz 与 144Hz 上的观感差出几倍。
  if (hudUi !== null) {
    const fadeMs = ticksToMs(BAG_FADE_TICKS, app.scheduler.fixedDt * 1000);
    const player = new TweenPlayer();
    // ★★ `loopCount: 1` **必须显式写**：`TweenSpec.loopCount` 的缺省值是 `0`，
    //   而 `0` 的语义是**无限循环**（见 `makeTween` 的 `BAD_LOOP` 报错文案）。
    //   漏掉它的症状不是"播完停在终点"，而是**面板一直 0→1 反复淡入**：
    //   每 6 个逻辑步重置一次，`sampleTween` 的 `done` 永远不为 true，
    //   于是 `advancePlayer` 的 `wasDone` 夹不住 `timeMs`，时间无界增长。
    //   这件事是被浏览器判据抓到的，而且抓了两次（批76 报 0.5555、批78 报 0.75）——
    //   两次都是"某个瞬间的相位"，因为判据只断言"到过 1"。判据的薄弱之处见
    //   `web/selftest.html` 里那条「到达终点后必须停住」。
    const fade = player.addTrack({
      id: "bag.fadeIn",
      targetId: "bag.panel",
      prop: UI_TWEEN_PROP.Opacity,
      spec: { id: "bag.fadeIn", from: 0, to: 1, durationMs: fadeMs, easing: "quadOut", loopCount: 1 },
    });
    const slide = player.addTrack({
      id: "bag.slideIn",
      targetId: "bag.panel",
      prop: UI_TWEEN_PROP.OffsetY,
      spec: { id: "bag.slideIn", from: BAG_SLIDE_FROM, to: 0, durationMs: fadeMs, easing: "quadOut", loopCount: 1 },
    });
    if (fade.ok && slide.ok) bagTween = player;
    else app.log.channel("host").warn("背包过渡轨道没建起来：属性名或 spec 写错了");
  }

  // ---- 脚本：加载演示模块
  // ★ 只 loadModule 是**不会执行**的：ScriptModule 遍历的是 `game.script` 组件，
  //   所以下面还要给 hero 挂一个（见 "挂脚本组件"）。这是"脚本加载了但没跑"
  //   最常见的原因，因此在两处都写清楚。
  const scriptRuntime = scriptMod.runtime;
  if (scriptRuntime === null) {
    app.log.channel("host").warn("平台没有脚本运行时：演示脚本不会执行");
  } else {
    const lr = await scriptRuntime.loadModule("demo", LUA_DEMO);
    if (!lr.ok) app.log.channel("host").error(`演示脚本加载失败：${lr.error.code} ${lr.error.message}`);
  }

  // ---- 组件注册（新增组件 = 一次 register，不改内核）
  // ★ world.terrain / world.site / world.resource / world.player / render.sprite
  //   已经由 `world.worldgen` 模块注册过了（它必须早于装配）；这里只补演示用的两个。
  const reg: ComponentRegistry = app.components;
  registerControllerComponent(reg);
  reg.register({ type: "game.workable", fields: { workleft: FieldType.Int } }, () => new Workable());

  // ---- 在世界之上摆装饰
  const scene = app.scene;
  const rnd = app.random;
  const worldPlan = worldState.plan;
  const W = worldPlan?.width ?? WORLD_W;
  const H = worldPlan?.height ?? WORLD_H;

  /** 抽一个可通行格的中心点（抽不到就退回地图中心，别把整段摆件卡死）。 */
  function walkableSpot(margin = 1, avoid?: ReadonlySet<number>): { x: number; z: number } {
    for (let tries = 0; tries < 64 && worldPlan !== null; tries++) {
      const cx = Math.floor(rnd.range(margin, W - margin));
      const cz = Math.floor(rnd.range(margin, H - margin));
      const kind = worldPlan.kinds[cz * W + cx];
      if (kind === undefined) continue;
      if (kind === "ocean" || kind === "cliff") continue;
      // 见下面装饰段的 ★：生物与玩家已经在场，树不能摆在他们脚下
      if (avoid !== undefined && avoid.has(cz * W + cx)) continue;
      return { x: cx + 0.5, z: cz + 0.5 };
    }
    return { x: W / 2, z: H / 2 };
  }

  // ---- 装饰摆件：它们**同时**是物理障碍与导航障碍（批124）
  //
  // ★★ 为什么两样都要：物理体让它挡得住已经贴上来的东西，导航封格让它**不往那儿走**。
  //   只做物理体是不够的 —— 树摆在格中心（`walkableSpot` 给的是 `cx+0.5`），
  //   而路点也是格中心（`NavGrid.centerOf`），两者落在同一个点阵上、误差为零。
  //   于是生物会**正对着树心**走过去：推力与走的方向正好相反、净位移 0，
  //   症状是"一只怪顶着树抖一整天"，而生物数、击杀数、战利品数全部自洽。
  //
  // ★ 生物与玩家此刻**已经在前场**（生物群模块先于本段 init），所以先收一张
  //   "别摆"的格子表 —— 否则开局第一帧就是"一只怪从树干里被挤出来"。
  const occupiedCells = new Set<number>();
  {
    const nav0 = worldState.nav;
    const mobs0 = worldState.mobs;
    if (nav0 !== null && mobs0 !== null) {
      for (const id of mobs0.nodeIds) {
        const n = scene.find(id);
        if (n !== undefined) occupiedCells.add(nav0.cellAt(n.worldPosition.x, n.worldPosition.y));
      }
    }
    if (worldState.player !== null) occupiedCells.add(worldState.player.cell);
  }

  const obstacleIds: number[] = [];
  /** 摆件占住的格子：摆完一起交给 `blockCells`（见上面的 ★★）。 */
  const obstacleCells: number[] = [];
  for (let i = 0; i < 70; i++) {
    const isTree = i % 3 !== 0;
    const spot = walkableSpot(1, occupiedCells);
    const r = scene.spawnAt(isTree ? `tree${i}` : `rock${i}`, spot.x, spot.z);
    if (!r.ok) continue;
    const node = r.value;
    const s = makeSprite(isTree ? "tree" : "rock", isTree ? 2 : 1.6, isTree ? 3 : 1.4);
    s.pivotY = 0; // 底边贴地（脚踩地面）
    scene.attach(node.id, () => s);
    if (isTree) scene.attach(node.id, () => new Workable());
    obstacleIds.push(node.id);
    obstacleCells.push(Math.floor(spot.z) * W + Math.floor(spot.x));
    // ★ 物理体要跟着节点**同批**建：`spawn` 只是入队，节点在 `flush()` 之前不在 `byId` 里，
    //   而 `SpatialHashWorld.add` 会立刻读位置（读不到就抛"没有位置"）。
    //   用 `scene.enqueue` 把它排在同一批里，顺序由投递序保证 —— 这时节点已经挂上了。
    scene.enqueue(() => physics.add({ nodeId: node.id, radius: isTree ? 0.55 : 0.7, isStatic: true }), "physics-add");
  }

  // 14 个浆果：Lua 演示脚本按名字找它们（`berry0..berry13`），所以名字必须稳定
  for (let i = 0; i < 14; i++) {
    const spot = walkableSpot();
    const r = scene.spawnAt(`berry${i}`, spot.x, spot.z);
    if (!r.ok) continue;
    const s = makeSprite("berry", 0.8, 0.8);
    s.pivotY = 0;
    scene.attach(r.value.id, () => s);
  }

  // 几张立牌，用的就是那张 **JPEG** 帧。
  // ★ 存在的意义是让"JPEG 支持"在画面上可见：如果解码器只对 PNG 有效，
  //   这四块牌子会是空的/花屏 —— 而只跑判据是看不到这一点的。
  for (let i = 0; i < 4; i++) {
    const cellX = 6 + i * 5;
    const cx = Math.min(W - 2, cellX);
    const r = scene.spawnAt(`poster${i}`, cx + 0.5, 3.5);
    if (!r.ok) continue;
    const s = makeSprite("photo", 1.6, 1.6);
    s.pivotY = 0;
    s.order = -50;
    scene.attach(r.value.id, () => s);
    obstacleIds.push(r.value.id);
    obstacleCells.push(Math.floor(3.5) * W + Math.floor(cx + 0.5));
    scene.enqueue(() => physics.add({ nodeId: r.value.id, radius: 0.6, isStatic: true }), "physics-add");
  }

  // ★ 见装饰段开头 ★★：障碍必须在导航里"看得见"，否则生物会正对着障碍心走。
  //   放在这里（而不是更早）是因为格子要等摆件落位才知道；放在这里也不会漏，
  //   因为**第一批寻路发生在本段之后**（生物群模块 init 用的是摆件之前的格子，
  //   而那些格子已经被 `occupiedCells` 排除了）。
  const navObstacles = worldState.nav;
  if (navObstacles !== null && obstacleCells.length > 0) {
    navObstacles.blockCells(obstacleCells);
  }

  // ---- 玩家：就是世界生成里落地的那个（不再是另造一个 hero）
  const sp = worldState.player;
  if (sp === null) throw new Error("世界没有给出出生点（worldgen 模块没跑成）");
  heroId = sp.nodeId;
  const heroNode = scene.find(heroId);
  if (heroNode === undefined) throw new Error(`出生节点 ${heroId} 不在场景里`);
  // 控制、脚本、物理都挂在**同一个**节点上 —— 换一个人就等于换一个坐标基准
  scene.attach(heroId, () => new PlayerController());
  // 批112：玩家的八向动画三件套（朝向 + 方向选 clip + 每实体时钟）。
  //
  // ★ 为什么这三件必须一起挂：少任何一个的表现都**是"不动"**，而不是报错 ——
  //   缺 Facing ⇒ 方向同步直接 return（`visited` 都不加）；缺 DirSprite ⇒ 没人写
  //   clipId；缺 SpriteAnimator ⇒ clip 选出来了但没有时钟，`Sprite.frame` 一直是
  //   装配时的那个名字。三种都长得像"素材没接上"。
  //
  // ★ `prefix` 必须填：`DirSprite` 用 `prefix === ""` 判定"本组件不生效"。
  //   clip 模式下它不参与选帧，但仍然要非空才进同步循环。
  scene.attach(heroId, () => {
    const f = new Facing();
    // 初始朝南（对着镜头）：出生瞬间还没有位移，不给角度就会朝东 ——
    // 而"刚进游戏就背对镜头"看起来像贴图反了。
    f.setAngle(Math.PI / 2);
    return f;
  });
  scene.attach(heroId, () => new SpriteAnimator());
  scene.attach(heroId, () => {
    const ds = new DirSprite();
    ds.prefix = "hero";
    ds.dirs = 8;
    ds.clipIds = heroClipIds();
    return ds;
  });
  // 批66：玩家也要能打、能被打。阵营写 "hunter" —— 与猎狗同队（互不攻击），
  // 兔子是 "prey"（敌对）⇒ 空格键打得到兔子，打不到猎狗。
  scene.attach(heroId, () => {
    const h = new Health();
    h.hp = 20;
    h.maxHp = 20;
    return h;
  });
  scene.attach(heroId, () => {
    const a = new Attacker();
    a.damage = 3;
    a.range = 1.8;
    a.cooldownTicks = 12;
    return a;
  });
  scene.attach(heroId, () => {
    const f = new FactionMember();
    f.team = "hunter";
    return f;
  });
  // 批67：饱食度。**满值起步**（默认值站在安全的一侧）：一进游戏就在饿死倒计时里
  // 只会让人以为"这游戏有 bug"。
  scene.attach(heroId, () => {
    const g = new Hunger();
    g.max = 100;
    g.value = 100;
    return g;
  });
  scene.attach(heroId, () => {
    const c = new ScriptComponent();
    c.module = "demo";
    c.entry = "onUpdate";
    return c;
  });
  scene.enqueue(() => physics.add({ nodeId: heroId, radius: 0.45, isStatic: false }), "physics-add");
  scene.flush();
  // 背包：8 堆（`game.inventory` 挂在玩家身上，物品是**独立节点** —— 见 inventory.ts 的理由）
  const bag = makeInventory(scene, heroId, 8);
  if (!bag.ok) toast(`背包建不起来：${bag.error.code}`);

  // ---- 存档
  // ★ 不再直接 `localStorage.setItem(key, json)`：走 `StorageFileSystem`，
  //   于是"存档写不进去/读不出来"有了错误码（`FS.NO_SPACE` / `FS.NOT_FOUND` / `FS.IO`），
  //   和 Node 侧同一套。旁路 localStorage 的后果是：浏览器遇到配额满只会弹一个
  //   冒泡的 `QuotaExceededError`，而宿主的 toast 只显示"已存档"。
  //   `saves` 用 `engine08.fs.` 前缀，避免与旧版本那个裸 key 混在一起。
  const saves = new StorageFileSystem({ storage: window.localStorage, prefix: "engine08.fs." });
  const SAVE_PATH = "/saves/slot1.json";
  let toastTimer = 0;
  /**
   * 一行提示。
   *
   * ★ 有引擎 UI 就走 UI 树（`hudUi.setToast`），**没有才**回落到 DOM 的 `#toast`。
   *   那个 DOM 元素现在只剩一个职责：资产建不起来时的降级通路 —— 那时整套 UI 树都不存在
   *   （`hud.hidden` 也是同一条路上的），提示若只走 UI 就等于"什么都看不到"。
   *   ★ 两条路都要留：降级态的可用性不是"顺便"，而是"启动失败时唯一的说话方式"。
   * ★ 计时留在这里：UI 层没有时钟（它只把状态映射成节点），
   *   "两秒后收起"是宿主对**用户注意力**的安排，不是界面的属性。
   */
  function toast(msg: string): void {
    if (hudUi !== null) hudUi.setToast(msg);
    else {
      toastEl!.textContent = msg;
      toastEl!.style.opacity = "1";
    }
    if (toastTimer !== 0) clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
      if (hudUi !== null) hudUi.setToast(null);
      else toastEl!.style.opacity = "0";
    }, 2000);
  }

  /**
   * 存档。**返回 Promise**：存储是异步接口，判据必须能等到写完。
   * ★ 这一点以前是错的：`doSave()` 同步返回，自检页 `e.save(); e.load();` 之后立刻
   *   数节点 —— 现在改成异步以后，那个断言会"必然通过"（什么都没发生）。
   *   所以诊断面把 Promise 交出去，断言也改成 `await`。
   */
  /**
   * 把"这一 tick 刚按下的动作"变成游戏行为。
   *
   * ★ 全部走 `InputMap.justPressed`：动作名在映射表里，改键不需要动这里一行。
   * ★ 动作与键位解耦之后，"手柄的 A 键能不能采集"就不再是一个需要单独写的分支。
   */
  /**
   * 打最近的一个**敌对**目标（空格键）。返回给 toast 的一句话。
   *
   * ★ 用 `componentsOf(HEALTH_TYPE)` 找候选而不是"找最近的一切"：
   *   能被打的东西一定有血量，而树/石头没有 —— 于是"站在树边上按空格"不会报
   *   `NO_HEALTH`，而是老老实实说"附近没有可打的"。
   * ★ **尸体不是候选**（批74 修）：`damage()` 不销毁节点，归零的靶子会一直留在
   *   场景里。不跳的话，贴着尸体站 ⇔ 最近的候选是尸体 ⇔ `attack()` 报
   *   `COMBAT.TARGET_DEAD` 原样上抛 —— 空格键对着一个还能打的活人**就是没反应**。
   *   而 `health.ts` 的文案自己说了"打尸体通常是目标选择出错"：选择侧的问题
   *   要在选择侧修，不能等攻击时报错。（浏览器自检的顿帧判据原来就绕在这上面：
   *   它那一枪打中上一条判据留下的尸体，却读到上一条残留的冻结而假绿。）
   * ★ 友军过滤走 `MOB_FACTIONS`（与生物同一个关系表）：只在攻击入口处判一次，
   *   而不是靠"距离太远所以打不到"去蒙。
   */
  function attackNearest(): string {
    if (heroId < 0) return "还没有玩家";
    const hero = scene.find(heroId);
    if (hero === undefined) return "玩家不在场景里";
    if (hero.get(ATTACKER_TYPE) === undefined) return `玩家没有 ${ATTACKER_TYPE}`;
    const me = hero.worldPosition;
    const myTeam = teamOf(scene, heroId).team;
    let bestId = -1;
    let bestD2 = Number.POSITIVE_INFINITY;
    for (const h of scene.componentsOf<Health>(HEALTH_TYPE)) {
      const n = h.node;
      if (n === null) continue;
      // ★★ 批123：候选资格抽成**纯函数**（`src/host/attack-target-policy.ts`）。
      //   原来这里是四行 `continue`（自己 / 未激活 / 死 / 盟友）与在一起 ——
      //   四个条件任何一个不成立都是同一个现象（"打不到"），诊断只能猜；
      //   更要紧的是"死节点不当候选"这条**在演示里没了语料**：批123 让玩家击杀
      //   当场撤节点，场上不再有站着的尸体，浏览器判据再也咬不住它（M314 报假绿）。
      //   抽出去之后四条理由各有 Node 判据，不再赌世界里恰好有什么。
      const why = whyNotAttackable({
        selfId: heroId,
        id: n.id,
        active: n.activeInHierarchy,
        dead: isDead(h),
        isAlly: MOB_FACTIONS.stanceOf(myTeam, teamOf(scene, n.id).team) === "ally",
      });
      if (why !== null) continue;
      const p = n.worldPosition;
      const dx = p.x - me.x;
      const dz = p.y - me.y;
      const d2 = dx * dx + dz * dz;
      if (d2 < bestD2) {
        bestD2 = d2;
        bestId = n.id;
      }
    }
    if (bestId < 0) return "附近没有可打的";
    const r = attack(scene, heroId, bestId, { tick: hudTick, factions: MOB_FACTIONS });
    if (!r.ok) return `${r.error.code}：${r.error.message}`;
    const rep = r.value.report;
    // ★ 玩家这条路径**不经过** `combat-module`（它是"按一下打一下"，
    //   没有每 tick 的 decide），所以表现要在这里补一次 —— 且必须是**同一个** showHit：
    //   分头写两份的那天，就是"怪打我冒数字、我打怪不冒"的那天。
    // ★ 这里拼**完整的** HitInfo（rep 里什么都有），而不是裁剪版：
    //   顿帧策略要按 overkill 判断"这一下有多重"，裁剪版会给它一个 0。
    showHit({
      attackerId: heroId,
      targetId: bestId,
      before: rep.before,
      after: rep.after,
      applied: rep.applied,
      overkill: rep.overkill,
      dead: rep.dead,
      tick: hudTick,
    });
    // ★★ 批123：玩家打死的东西也要**留一具尸体**。
    //   这条路走的是 `attack()`（按一下打一下），不经过生物模块的 `combat-module`，
    //   所以那边的 `onKill` 永远不会为玩家触发 —— 不在这里补，演示里就是
    //   "AI 互相打死的留下尸体、玩家亲手打死的什么也没有"，同一种死两种结果。
    //   ★ 尸体放不下时退回"直接进包"：掉不许凭空消失（与 `mob-world` 同一条纪律）。
    if (rep.dead) {
      const dead = scene.find(bestId);
      lastVictim = {
        id: bestId,
        mobKind: worldState.mobs?.templateOf(bestId) ?? null,
        name: dead?.name ?? "",
      };
      if (dead === undefined) {
        // 已经不在场景里（同一 tick 被 AI 那条路先撤掉了）：没有位置可落尸体
        lastCorpseSkip = "NODE_GONE";
      } else {
        const nav = worldState.nav;
        const p = dead.worldPosition;
        // ★ 战利品表从**实体身上**读（`game.loot`），不问生物模块：
        //   玩家的攻击不经过 `combat-module`，而模块里的旁表按节点 id 索引 ——
        //   读档换了场景之后就查不到，于是"打死了却什么都不掉"（见 `loot.ts`）。
        const lootR = lootOfNode(scene, bestId);
        const table = lootR.ok ? lootR.value : null;
        if (!lootR.ok) {
          lastCorpseSkip = `BAD_LOOT:${lootR.error.code}`;
          toast(`尸体没生成（战利品表读不出来：${lootR.error.code}）`);
        } else if (table === null) {
          // 没有战利品表 ⇒ 它不是生物（是某个恰好有血量的东西）。
          // ★ 仍然要撤掉节点：不撤就是"一只站着的死兔子"，而 AI 那条路是
          //   `combat-module` 撤的 —— 这条路没人替它撤。
          lastCorpseSkip = "NO_LOOT_TABLE";
        } else if (nav === null) {
          // 没有导航网格就算不出"哪一格能放"：退回直接进包，且**说出来**
          lastCorpseSkip = "NO_NAV";
          const g = grantLoot(scene, heroId, table);
          toast(`尸体没生成（没有导航网格），${g.ok ? "战利品直接进包" : "而且进包也失败了"}`);
        } else {
          const placed = spawnCorpse(scene, table, {
            ground: nav,
            x: p.x,
            z: p.y,
            nowTick: hudTick,
            decayTicks: CORPSE_DECAY_TICKS,
          });
          if (placed.ok) {
            playerCorpses++;
            lastCorpseSkip = "";
          } else {
            // 退回老路：战利品直接进包（并且说出来 —— 静默退回等于"偶尔不掉东西"）
            lastCorpseSkip = `PLACE_FAILED:${placed.error.code}`;
            const g = grantLoot(scene, heroId, table);
            toast(`尸体没生成（${placed.error.code}），${g.ok ? "战利品直接进包" : "而且进包也失败了"}`);
          }
        }
        // 死掉的生物节点要撤掉：AI 那条路是 `combat-module` 撤的，这条路没人撤 ——
        // 不撤就变成"一只站着的死兔子 + 旁边一具尸体"。
        // ★ 放在**所有**分支之后（不只是放成功那条）：撤节点与留尸体是两件事，
        //   尸体放不下不代表该死的东西还能站着。
        scene.destroy(bestId);
        scene.flush();
      }
    }
    return rep.dead ? `击杀！` : `命中 ${String(rep.applied)}，剩 ${String(rep.after)}`;
  }

  /**
   * 吃一口（批67）：从背包里挑**最有营养**的那一种吃。
   *
   * ★ 为什么自动挑而不是让玩家选：能吃的东西通常只有一两样，"先选再吃"会把
   *   一次按键变成三步操作。挑的规则是确定的（营养降序 → kind 升序），
   *   所以同一个背包每次按 E 吃到的东西是一样的。
   * ★ 背包里一样能吃的都没有 ⇒ 返回一句能看懂的话，而不是静默什么都不做。
   */
  function eatSomething(): string {
    if (heroId < 0) return "还没有玩家";
    const held = stacksOf(scene, heroId)
      .filter((s) => FOOD_TABLE[s.kind] !== undefined && s.count > 0)
      .sort((a, b) => {
        const na = FOOD_TABLE[a.kind]?.nutrition ?? 0;
        const nb = FOOD_TABLE[b.kind]?.nutrition ?? 0;
        if (na !== nb) return nb - na; // 营养高的先吃
        return a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : 0; // 同营养时按 kind 定序（可回放）
      });
    const best = held[0];
    if (best === undefined) {
      return `背包里没有能吃的东西（能吃的：${Object.keys(FOOD_TABLE).sort().join(" / ")}）`;
    }
    const r = eatKind(scene, heroId, best.kind, FOOD_TABLE);
    if (!r.ok) return `${r.error.code}：${r.error.message}`;
    const rep = r.value;
    return `吃了「${rep.kind}」：饱食 ${String(rep.hungerBefore)}→${String(rep.hungerAfter)}` +
      (rep.healed > 0 ? `，回血 ${String(rep.healed)}` : "");
  }

  /**
   * 制作一件（批68）：做**表里第一条现在就能做的**。
   *
   * ★ 为什么不给"选配方"的面板：现在只有两条配方，而"能否做"完全由背包决定。
   *   一条按键 + 一句提示足够了；等配方多到需要分类时再做面板（那时才有人知道该分几类）。
   * ★ 一条都做不了的时候，报**最接近的那一条**缺什么 —— 只说"材料不足"等于让人
   *   挨个去数背包，而"缺什么、缺几个"是已知的。
   */
  function craftSomething(): string {
    if (heroId < 0) return "还没有玩家";
    const pick = firstCraftable(scene, heroId, RECIPES);
    if (pick !== undefined) {
      const r = craftRecipe(scene, heroId, pick);
      if (!r.ok) return `${r.error.code}：${r.error.message}`;
      return `做好了「${pick.name}」：${pick.inputs.map((c) => `${ITEM_LABEL[c.kind] ?? c.kind}×${String(c.count)}`).join(" + ")}` +
        ` → ${ITEM_LABEL[r.value.output.kind] ?? r.value.output.kind}×${String(r.value.added)}`;
    }
    // 一条都做不了：报"最接近"的那一条（缺料项最少）
    let best: { id: string; name: string; missing: ReturnType<typeof missingFor> } | null = null;
    for (const r of RECIPES) {
      const missing = missingFor(scene, heroId, r);
      if (missing.length === 0) continue;
      if (best === null || missing.length < best.missing.length) best = { id: r.id, name: r.name, missing };
    }
    if (best === null) return "没有可做的配方";
    const desc = best.missing.map((m) => `${ITEM_LABEL[m.kind] ?? m.kind} ${String(m.have)}/${String(m.count)}`).join("、");
    return `${best.id} 缺：${desc}`;
  }

  function dispatchActions(): void {
    const snap = controllerMod.snapshot;
    const map = controllerMod.map;
    if (map.justPressed(snap, "save")) void doSave();
    else if (map.justPressed(snap, "load")) void doLoad();
    else if (map.justPressed(snap, "restart")) location.reload();
    else if (map.justPressed(snap, "bag")) {
      setBagOpen(!bagOpen);
      toast(bagOpen ? "背包已打开" : "背包已关上");
    } else if (map.justPressed(snap, "drop")) {
      const d = dropSelected(shiftDown);
      toast(d.ok ? d.value : `${d.error.code}：${d.error.message}`);
    } else if (map.justPressed(snap, "attack")) toast(attackNearest());
    else if (map.justPressed(snap, "eat")) toast(eatSomething());
    else if (map.justPressed(snap, "craft")) toast(craftSomething());
    else if (map.justPressed(snap, "chop")) chopNearest();
    else if (map.justPressed(snap, "harvest")) {
      const h = pickupNearest();
      toast(h.ok ? h.value : `${h.error.code}：${h.error.message}`);
    }
  }

  async function doSave(): Promise<Result<void, EngineError>> {
    const json = sceneToJson(saveScene(scene));
    const w = await saves.writeText(SAVE_PATH, json);
    // ★ 失败必须说出来：以前无论写没写成都会提示"已存档"
    toast(w.ok ? `已存档：${json.length} 字节 · hash ${stableHash(json)}` : `存档失败：${w.error.code} ${w.error.message}`);
    return w;
  }

  async function doLoad(): Promise<Result<number, EngineError>> {
    const res = await saves.readText(SAVE_PATH);
    if (!res.ok) {
      toast(res.error.code === "FS.NOT_FOUND" ? "还没有存档（先按 F5）" : `读档失败：${res.error.code}`);
      return res;
    }
    return applyLoad(res.value);
  }

  function applyLoad(json: string): Result<number, EngineError> {
    const snap = sceneFromJson(json);
    if (!snap.ok) {
      toast("存档损坏：" + snap.error.message);
      return snap;
    }
    const r = loadScene(scene, snap.value, reg);
    if (!r.ok) {
      toast("读档失败：" + r.error.message);
      return r;
    }
    // 物理登记表重建（节点 id 不变，但 body 已被 clear）
    physics.clear();
    for (const id of obstacleIds) {
      if (scene.find(id) !== undefined) physics.add({ nodeId: id, radius: 0.6, isStatic: true });
    }
    if (scene.find(heroId) !== undefined) {
      physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
      // ★ 批112：`clipIds` 不进 `schema` ⇒ `loadScene` 按 schema 重建组件时会把它丢掉，
      //   玩家从此退回单帧模式（这套素材没有单帧名）⇒ 读档后变成一张静止贴图。
      //   这是**装配**（哪套资产），不是实体状态，所以只能由宿主在读档后重新施加。
      //   同一类事：上面那张物理登记表。
      // ★ 返回值要判：`DirSprite` 本身在 schema 里（`prefix`/`dirs` 会被存下来），
      //   所以玩家节点在就必须补得上 —— 补不上说明装配坏了，说出来比静默停帧强。
      if (!restoreDirClipIds(scene, heroId, heroClipIds())) {
        toast("读档：玩家的方向帧组件没找回来（动画会停在前一帧）");
      }
    }
    const extra = r.value.skipped.length > 0 ? `，跳过 ${r.value.skipped.length} 项` : "";
    toast(`已读档：${r.value.made} 个节点${extra}`);
    return ok(r.value.made);
  }

  /**
   * 脚下最近的一具尸体（格中心距离，`null` = 范围内没有）。
   *
   * ★ 按**格中心**算距离，不按节点坐标：尸体就落在格中心，两者今天等价 ——
   *   而"按格"是拾取的单位（`takeFromCorpse` 收 cell），两处用同一个口径才不会
   *   出现"看得见却够不着"（判据在 `corpse.test.ts` 里钉的是格，不是坐标）。
   */
  function nearestCorpse(x: number, z: number, range: number): number | null {
    const plan = worldState.plan;
    if (plan === null) return null;
    let best = -1;
    let bestD = Number.POSITIVE_INFINITY;
    for (const c of scene.componentsOf<Corpse>(CORPSE_TYPE)) {
      if (c.node === null) continue;
      const gx = c.cell % plan.width;
      const gz = (c.cell - gx) / plan.width;
      const d = Math.hypot(gx + 0.5 - x, gz + 0.5 - z);
      if (d > range) continue;
      // 同距离取小 cell：回放与"点了同一具"都依赖确定性
      if (d < bestD || (d === bestD && (best < 0 || c.cell < best))) {
        best = c.cell;
        bestD = d;
      }
    }
    return best < 0 ? null : best;
  }

  /**
   * **半径拾取**：把脚下 `range` 内的世界资源按"最近优先"收进背包。
   *
   * ★ 以前这里只摘**一格**、而且**不进背包**（直接调 `harvestAt`）——
   *   于是"采了 6 次"与"背包里有什么"是两个互不相干的数字。现在走 `pickupNearby`：
   *   顺序是"先进包、后摘"（`harvestInto` 保证），背包满了就停，并且**说出来**。
   * ★ 老演示区的树走的是 `Workable` 那条路（砍三下倒，`chopNearest`），两条路并存是
   *   故意的：一条演示"世界自己的资源"，一条演示"宿主自定义的可交互物"。
   * ★ 批123：**尸体优先于资源**。尸体是玩家自己打出来的，意图明确（"我是来翻这具的"）；
   *   而资源满地都是、随时能采。反过来（资源优先）的症状是"站在尸体上按 G，
   *   结果把旁边的树采了"—— 玩家会以为尸体不能翻。
   */
  function pickupNearest(range = 3.2): Result<string, EngineError> {
    const heroNode2 = scene.find(heroId);
    if (heroNode2 === undefined) return err(engineError("HARVEST.NO_PLAYER", "玩家不在场景里"));
    const tasks = worldState.tasks;
    if (tasks === null) return err(engineError("HARVEST.NO_TASKS", "世界任务模块没起来"));
    const hp = heroNode2.worldPosition;
    // ★ 批123：先翻尸体（见上面那段注释）。取空了就一次拿完 —— 尸体只有一次机会，
    //   玩家不会想为了剩下的两块肉再按一次 G。
    const bodyCell = nearestCorpse(hp.x, hp.y, range);
    if (bodyCell !== null) {
      const took = takeFromCorpse(scene, bodyCell, heroId);
      if (!took.ok) {
        // 背包满是最常见的；指名道姓，否则玩家只看到"按 G 没反应"
        return err(engineError(took.error.code, `翻尸体失败：${took.error.message}`));
      }
      const list = took.value.taken.map((e) => `${ITEM_LABEL[e.kind] ?? e.kind}×${e.count}`);
      const tail = took.value.emptied ? "（取空了，尸体已经消失）" : `（还剩 ${String(took.value.leftCount)} 个）`;
      return ok(`翻尸体：${list.join(" ")}${tail}`);
    }
  const r = pickupNearby(scene, hp.x, hp.y, range, heroId, {
    max: 4,
    // ★ 批122 起不传 `amount`：产量已经是**世界侧**的事（`ResourceMarker.count`，
    //   出生时由 `yieldOf` 冻结）。这里再传一张产量表，就会把"丢在地上 40 个 berry"
    //   压成一次捡 1 个 —— 而那正是地面堆叠要解决的问题。
    onRelease: (c) => tasks.releaseCell(c),
  });
    if (!r.ok) return r;
    const out = r.value;
    if (out.inRange === 0) {
      return err(engineError("HARVEST.FAR", "附近没有世界资源（资源会自己长出来，等几秒）"));
    }
    if (out.picked.length === 0) {
      // 找到了东西却一个都没拿到 ⇒ 一定是失败那次（背包满最常见）。必须点名，否则玩家只看到"没反应"
      const f = out.failed;
      return err(
        engineError(
          f?.code ?? "PICKUP.NONE",
          `拿到了 0 个（半径内 ${out.inRange} 个）：${f === null ? "原因不明" : f.message}`,
        ),
      );
    }
    const got = out.picked.map((p) => `${ITEM_LABEL[p.kind] ?? p.kind}×${countItem(scene, heroId, p.kind)}`);
    const tail = out.failed === null ? "" : `；背包满了，还剩 ${out.remaining} 个没拿`;
    return ok(`拾取：${got.join(" ")}${tail}`);
  }

  function chopNearest(): void {
    const heroNode = scene.find(heroId);
    if (heroNode === undefined) return;
    const hp = heroNode.worldPosition;
    for (const id of physics.query(hp.x, hp.y, 2.4)) {
      if (id === heroId) continue;
      const w = scene.find(id)?.get<Workable>("game.workable");
      if (w === undefined) continue;
      w.workleft -= 1;
      if (w.workleft <= 0) {
        scene.destroy(id);
        physics.remove(id);
        toast("砍倒了一棵树");
      } else {
        toast(`砍了一下，还剩 ${w.workleft}`);
      }
      return;
    }
    toast("附近没有可砍的东西");
  }

  /**
   * 操作提示**从映射表生成**（不是手写一段话）。
   * ★ 手写的提示与键位是两份数据，改键之后必然分叉 —— 而"提示里写着 G、实际要按 L"
   *   这种错，玩家会认为是游戏坏了。这里取每个动作的**第一个键**（键盘优先）。
   */
  function helpText(): string {
    const m = controllerMod.map;
    const k = (a: string): string => (m.keysOf(a)[0] ?? "?").replace(/^Key/, "");
    // ★ 每一个**玩家会按**的动作都必须在这句里（它是从映射表生成的，所以改键会自动跟着变；
    //   但**新增一个动作**不会自动出现 —— 漏了就等于这个功能对玩家不存在）。
    //   批66 加了 attack、批67 加了 eat、批68 加了 craft，三处都补在这里。
    return (
      `${k("move_forward")}${k("move_left")}${k("move_back")}${k("move_right")} 移动 · ` +
      `${k("harvest")} 拾取 · ${k("chop")} 砍树 · ${k("attack")} 打 · ${k("eat")} 吃 · ${k("craft")} 制作 · ` +
      `${k("bag")} 背包 · ${k("drop")} 丢弃 · ` +
      `${k("save")} 存档 · ${k("load")} 读档 · ${k("restart")} 重载`
    );
  }


  /**
   * 背包一行文本。**空背包要显示"空"，不是空白** ——
   * 空字符串会让人分不清"背包是空的"与"背包功能没接上"。
   */
  function bagText(): string {
    if (heroId < 0) return "无主";
    const stacks = stacksOf(scene, heroId);
    if (stacks.length === 0) return "空";
    return stacks
      .map((s) => `${ITEM_LABEL[s.kind] ?? s.kind}×${s.count}`)
      .join(" ");
  }

  /**
   * HUD 里的饱食度（批67）。
   *
   * ★ 饿着的时候要**看起来不一样**（`饿！`）：一个"0/100"和"100/100"在同一条
   *   长文本里长得一样，而前者意味着每秒在掉血。
   */
  function hungerText(): string {
    if (heroId < 0) return "无主";
    const h = scene.find(heroId)?.get<Hunger>(HUNGER_TYPE);
    if (h === undefined) return "无";
    return `${String(h.value)}/${String(h.max)}${h.value <= 0 ? " 饿！" : ""}`;
  }


  // ---- 背包面板（T355 遗留：从"一行文本"到"能选中、能丢"）
  //
  // ★ 批71 起它**不再是 DOM**：面板是 UI 树里常驻的 8 行（`host/hud-ui.ts`），
  //   这里的 `bagOpen` / `bagSel` 只表示**状态**，每帧由 `syncBagUi()` 写进节点 props。
  //   DOM 版每帧重建面板，靠"签名比对"躲开"重建打到点击"的时序问题；
  //   UI 版没有重建这一步，那类问题因此不存在 —— 但状态仍然只有一份（就是这两个变量）。
  let bagOpen = false;
  /** 选中的堆叠下标（关闭时归 0；越界时按最后一堆算，见 dropSelected）。 */
  let bagSel = 0;
  /** Shift 状态：DOM 是唯一事实源（InputSnapshot 不带修饰键），"丢整堆"要用。 */
  let shiftDown = false;

  function keyLabel(a: string): string {
    return (controllerMod.map.keysOf(a)[0] ?? "?").replace(/^Key/, "");
  }

  /**
   * 把"背包状态"写进 UI 树（没开 UI 时什么也不做）。
   * ★ 每帧都调是**安全**的：`setBag` 内部比签名，没变就直接返回，不会重排。
   * ★ 收一个可选的 `stacks`：`onRender` 里已经为了 `bagStacks` 遍历过一次，
   *   再序遍历一次是白花的（而且两处遍历同一个可变场景，句柄还会不一致）。
   */
  /**
   * 背包面板里的命令行（批110 的输入框消费者）。
   *
   * ★ 为什么给它一个**真的消费者**而不是"留个接口等以后用"：
   *   没有消费者的控件，判据只能验它自己（模型算得对），验不到"接上之后还对不对"。
   *   命令行是最小的真消费者：它要光标、要退格、要 Esc 取消、要中文（`give 木头 3`），
   *   四件事正好把输入框的四条路径全走一遍。
   *
   * ★ 命令是**调试性质**的（give / clear），不进玩法存档。
   */
  const cmd = new TextInput();
  let cmdOpen = false;

  function setCmdOpen(next: boolean): void {
    cmdOpen = next;
    cmd.value = "";
    cmd.caret = 0;
    cmd.anchor = 0;
    cmd.cancelComposition();
    syncBagUi();
    // ★ 收起时要把焦点**交还给页面**（批112）：命令行用一个屏幕外的隐藏 `<input>`
    //   接输入法，它开着时一直握着焦点。不 blur 的话，DOM 输入后端会认为「还在打字」，
    //   于是收起的输入行后面每一个按键都被吞掉 —— 症状是「打完一条命令之后 WASD 不动了」。
    //   两端都要修：这一处让焦点真的离开，后端那边的 `focusout` 才收得到。
    if (!next && imeHost !== null && document.activeElement === imeHost) imeHost.blur();
  }

  /** 执行一条命令。返回给提示条的那句话（成功/失败都说）。 */
  function runCommand(text: string): string {
    const parts = text.trim().split(/\s+/).filter((s) => s !== "");
    if (parts.length === 0) return "";
    const [head, a, b] = parts;
    if (head === "clear") {
      if (heroId < 0) return "没有玩家";
      for (const s of stacksOf(scene, heroId)) {
        const n = s.node;
        if (n !== null && n !== undefined) scene.destroy(n.id);
      }
      scene.flush();
      syncBagUi();
      return "背包已清空";
    }
    if (head === "give" && a !== undefined) {
      if (heroId < 0) return "没有玩家";
      const n = b === undefined ? 1 : Number(b);
      if (!Number.isFinite(n) || n <= 0) return `数量不对：${b ?? ""}`;
      const g = addItem(scene, heroId, a, Math.floor(n));
      if (!g.ok) return `给不了 ${a}：${g.error.code}`;
      syncBagUi();
      return `给了 ${a} x${String(Math.floor(n))}`;
    }
    return `未知命令：${head}（可用 give <种类> <数量> / clear）`;
  }

  function syncBagUi(stacks?: readonly { readonly kind: string; readonly count: number }[]): void {
    if (hudUi === null) return;
    // 输入行的显示状态**跟背包一起推**：它住在背包面板里，面板一关它就该跟着收。
    // 分开推的话，"关面板"与"收输入行"会各有一个入口，必然有一次忘了其中一个。
    hudUi.setInput(
      cmdOpen
        ? { text: cmd.display, caret: cmd.displayCaret, selStart: cmd.selection.start, selEnd: cmd.selection.end }
        : null,
    );
    if (!bagOpen || heroId < 0) {
      hudUi.setBag(null, bagSel);
      return;
    }
    hudUi.setBag(stacks ?? stacksOf(scene, heroId), bagSel);
  }

  /** 选中第 i 堆（键盘数字键 / 点击面板行 / 自检页都走这里）。 */
  function selectBagRow(i: number): number {
    const n = heroId < 0 ? 0 : stacksOf(scene, heroId).length;
    bagSel = n === 0 ? 0 : Math.min(Math.max(0, Math.floor(i)), n - 1);
    syncBagUi();
    return bagSel;
  }

  /**
   * 丢弃选中堆（`whole` = 整堆，否则 1 个）到脚下的世界里。
   *
   * ★ 顺序由 `dropIntoWorld` 保证：先找格放下、再从包里出 —— 失败时物品还在包里。
   * ★ "面板没开"与"背包是空的"是**两种**提示：前者是操作顺序，后者是世界状态，
   *   合成一条"什么都没发生"会让玩家以为按键坏了。
   */
  function dropSelected(whole: boolean): Result<string, EngineError> {
    if (heroId < 0) return err(engineError("BAG.NO_OWNER", "没有玩家"));
    if (!bagOpen) return err(engineError("BAG.CLOSED", `先按 ${keyLabel("bag")} 打开背包`));
    const stacks = stacksOf(scene, heroId);
    if (stacks.length === 0) return err(engineError("BAG.EMPTY", "背包是空的，没什么可丢"));
    const plan = worldState.plan;
    const tasks = worldState.tasks;
    if (plan === null || tasks === null) return err(engineError("BAG.NO_WORLD", "世界没起来，没地方丢"));
    const heroNode3 = scene.find(heroId);
    if (heroNode3 === undefined) return err(engineError("HARVEST.NO_PLAYER", "玩家不在场景里"));
    const sel = Math.min(Math.max(0, bagSel), stacks.length - 1);
    const s = stacks[sel]!;
    const n = whole ? s.count : 1;
    const hp = heroNode3.worldPosition;
    const r = dropIntoWorld(scene, heroId, s.kind, n, {
      x: hp.x,
      z: hp.y,
      plan,
      tasks,
      bornTick: app.snapshot().tick,
    });
    if (!r.ok) return r;
    syncBagUi();
    const label = ITEM_LABEL[s.kind] ?? s.kind;
    // ★ 报告"这一堆现在有几个"，不是"占了几格"：批122 起丢 n 个只有一格，
    //   再说"散落在 1 格"会让 40 个和 1 个的提示一模一样。
    const where = r.value.merged ? "叠到地上的堆" : "放在脚下";
    return ok(`丢下 ${label}×${String(n)}（${where}，那一堆共 ${String(r.value.count)} 个，按 G 还能捡回来）`);
  }

  // ---- HUD（每帧一次；字段都是"可解释的事实"，不是装饰）
  //
  // ★ 两条路径**同一份事实**（`HudFacts`），不是两套格式化：
  //   · UI 路径：`hudRows(facts)` → 三个 Label 节点（就地改 props，不重建树）
  //   · 降级路径：`hudLine(facts)` → 一行 DOM 文本
  //   两句话同源（`hudLine === hudRows.join`，判据盯着），所以"UI 里少了一个字段"
  //   和"DOM 里少了一个字段"不可能是同一批代码的两种表现。
  let fps = 0;
  let frames = 0;
  let lastFpsAt = performance.now();
  /** 累计渲染帧数（**不随 fps 窗口清零**）。自检页用它和 `gfx.stats.frameIndex` 对账。 */
  let renderFrames = 0;
  /** 最近一帧的 HUD 文本（诊断用；UI 路径下 DOM 不再更新，但这句话还在）。 */
  let lastHudText = "";
  app.services.require(Services.Frame).onRender((info) => {
    frames++;
    renderFrames++;
    const now = performance.now();
    if (now - lastFpsAt > 500) {
      fps = frames / ((now - lastFpsAt) / 1000);
      frames = 0;
      lastFpsAt = now;
    }
    // 表现层：伤害数字跟着相机走（每帧一次 —— 它没有逻辑，只有位置）
    updateDamageNumbers(now);
    const lf = renderMod.lastFrame;
    const st = app.snapshot();
    const sc = scriptMod.runtime?.stats();
    const ws = worldState.tasks?.stats();
    const wv = worldState.visual;
    const stacks = heroId < 0 ? [] : stacksOf(scene, heroId);
    const hungerC = heroId < 0 ? undefined : scene.find(heroId)?.get<Hunger>(HUNGER_TYPE);
    const facts: HudFacts = {
      fps,
      tick: hudTick,
      quads: lf.quads,
      drawCalls: lf.drawCalls,
      culled: lf.culled,
      nodes: st.scene.nodes,
      bodies: physics.stats().bodies,
      atlas: atlasLabel,
      world: wv === null ? null : { terrain: wv.terrain, sites: wv.sites },
      resources: { alive: ws?.alive ?? 0, spawned: ws?.spawned ?? 0, released: ws?.released ?? 0 },
      bagStacks: stacks.length,
      hunger: hungerC === undefined ? null : { value: hungerC.value, max: hungerC.max },
      backends: { gfx: st.backends.gfx, audio: st.backends.audio, input: st.backends.input, script: st.backends.script },
      script: sc === undefined ? null : { calls: sc.calls, errors: sc.errors, timeouts: sc.timeouts },
      droppedSteps: st.droppedSteps,
    };
    lastHudText = hudLine(facts);
    if (hudUi !== null) {
      // ★ HUD 行是富文本（批115）：标签与分隔符继承行基色（dim），值一段用亮色。
      //   色号从 hud-ui 导入 —— HUD 的整套配色只在一处，判据按同一常量断言。
      hudUi.setHud(
        hudRowRuns(facts, { value: HUD_VALUE_TINT }),
        hungerC === undefined || hungerC.max <= 0 ? null : hungerC.value / hungerC.max,
      );
      // 复用上面为 `bagStacks` 已经取过的那一份，不再遍历第二次
      syncBagUi(stacks);
    } else {
      hud!.textContent = lastHudText;
    }
    void info;
  });

  // ---- 指针 → UI（**只认原始事件流**，不调 poll）
  //
  // ★ 为什么不能用 `platform.input.poll()`：边缘是"自上次 poll 以来"，
  //   而 controller 模块已经在 onStep 里 poll 过一次 —— 第二次 poll 会把
  //   `pressed` 边缘吃掉（宿主里"点一下没反应"，而 keydown 明明到了）。
  //   原始事件流就是给 UI/编辑器用的（见 `IInputDevice.subscribe` 的注释）。
  // ★ 坐标是**画布相对 CSS 像素**：`screenToDesign` 要的就是这个，
  //   传设备像素会让点击位置差一个 dpr（高分屏上"点不中"）。
  if (hudUi !== null) {
    const ui = hudUi;
    // 滚轮事件**不带坐标**（`x`/`y` 字段里是 deltaX/deltaY），所以要记住最后一次
    // 指针位置再投进去。用 `input.poll()` 的 snapshot 不行：那是"自上次 poll 以来"的
    // 边缘状态，而 controller 每 tick 已经 poll 过一次了（见上面的注释）。
    let lastX = 0;
    let lastY = 0;
    let lastDown = false;
    app.platform.input.subscribe((e) => {
      if (e.kind === "pointer") {
        if (e.x === undefined || e.y === undefined) return;
        lastX = e.x;
        lastY = e.y;
        lastDown = e.down === true;
        ui.pointer(lastX, lastY, lastDown);
        return;
      }
      if (e.kind !== "wheel") return;
      // 单位是 CSS 像素，换算在 `HudUiHandle.pointer` 里做（与坐标同一处）
      ui.pointer(lastX, lastY, lastDown, e.y ?? 0, e.x ?? 0);
    });
  }

  // ---- 输入
  // ★ 这里**只处理浏览器的默认行为**，不做动作分发（那件事在 tick 里，见 dispatchActions）。
  //   不拦的话 F5 会刷新页面、方向键会滚动、Tab 会把焦点移出画布 ——
  //   "按背包键顺手把页面焦点跳了"这种 bug 只会在真按下去的那一刻出现，
  //   而且看起来像"背包打不开"。
  const RESERVED = new Set(["F5", "F9", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);

  /**
   * IME 宿主：一个**看不见的 `<input>`**。
   *
   * ★★ 为什么非要有一个 DOM 元素：`compositionstart/update/end` 只会发给
   *   可编辑元素。纯 canvas 的输入框**根本收不到**这三个事件 ——
   *   于是"组合中不提交"在浏览器里永远走不到，而 Node 判据全绿。
   *   这是"模型对了但没接上"最典型的一种：引擎侧一条链是通的，浏览器侧没有入口。
   * ★ 它的 `value` 不参与逻辑：真正的值在 `cmd` 里。这里只是让输入法有地方落脚，
   *   所以每次 `compositionend` 之后要把它的 value 清空，否则注入的字符会越攒越多。
   */
  let imeHost: HTMLInputElement | null = null;
  function ensureImeHost(): HTMLInputElement {
    if (imeHost !== null) return imeHost;
    const el = document.createElement("input");
    el.type = "text";
    el.autocomplete = "off";
    el.spellcheck = false;
    // 放到屏幕外但不 `display:none`（后者会让它拿不到焦点，输入法就不工作）
    el.style.cssText = "position:fixed;left:-1000px;top:0;width:1px;height:1px;opacity:0;border:0;padding:0;";
    document.body.appendChild(el);
    el.addEventListener("compositionstart", () => {
      if (!cmdOpen) return;
      cmd.beginComposition();
      syncBagUi();
    });
    el.addEventListener("compositionupdate", (e) => {
      if (!cmdOpen) return;
      cmd.updateComposition(e.data ?? "");
      syncBagUi();
    });
    el.addEventListener("compositionend", (e) => {
      if (!cmdOpen) return;
      // ★ 空串 = 取消（Esc 时浏览器就这么发）。模型里已经把这条钉住了，
      //   这里原样传下去，**不要**在这里自作聪明过滤。
      cmd.commitComposition(e.data ?? "");
      el.value = "";
      syncBagUi();
    });
    imeHost = el;
    return el;
  }

  /** 处理输入行里的按键。返回 true = 已消费。 */
  function handleCmdKey(ev: KeyboardEvent): boolean {
    if (!cmdOpen) return false;
    // 组合中的按键交给输入法：此时 `key` 是 "Process" 或单个字母，
    // 自己处理会把拼音字母插进文本里
    if (ev.isComposing) return true;
    if (ev.key === "Enter") {
      const msg = runCommand(cmd.value);
      setCmdOpen(false);
      if (msg !== "") toast(msg);
      return true;
    }
    if (ev.key === "Escape") {
      setCmdOpen(false);
      return true;
    }
    if (ev.key === "Backspace") {
      cmd.deleteBackward();
      syncBagUi();
      return true;
    }
    if (ev.key === "Delete") {
      cmd.deleteForward();
      syncBagUi();
      return true;
    }
    if (ev.key === "ArrowLeft" || ev.key === "ArrowRight") {
      cmd.moveCaret(cmd.caret + (ev.key === "ArrowLeft" ? -1 : 1), ev.shiftKey);
      syncBagUi();
      return true;
    }
    if (ev.key === "Home" || ev.key === "End") {
      cmd.moveCaret(ev.key === "Home" ? 0 : Number.MAX_SAFE_INTEGER, ev.shiftKey);
      syncBagUi();
      return true;
    }
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === "a") {
      cmd.selectAll();
      syncBagUi();
      return true;
    }
    // 可打印字符：`key.length === 1` 排掉 F1/F2/Tab 这些名字很长的键
    if (ev.key.length === 1 && !ev.ctrlKey && !ev.metaKey) {
      cmd.insert(ev.key);
      syncBagUi();
      return true;
    }
    return false;
  }

  window.addEventListener("keydown", (ev) => {
    if (handleCmdKey(ev)) {
      ev.preventDefault();
      return;
    }
    // `/` 打开命令行（只在背包开着时有意义：它就画在背包面板里）
    if (ev.code === "Slash" && bagOpen && !cmdOpen) {
      setCmdOpen(true);
      ensureImeHost().focus();
      ev.preventDefault();
      return;
    }
    if (RESERVED.has(ev.code)) ev.preventDefault();
    // Shift 状态：DOM 是唯一事实源（InputSnapshot 不带修饰键）—— "丢整堆"要用
    if (ev.code === "ShiftLeft" || ev.code === "ShiftRight") shiftDown = true;
    // 数字键直接选中对应堆叠（面板开着时）。不走 InputMap：那是"动作→键"的表，
    // 而"选第 n 堆"是带参数的，塞进映射表会炸出 8 个动作。
    if (bagOpen && /^Digit[1-8]$/.test(ev.code)) selectBagRow(Number(ev.code.slice(5)) - 1);
  });
  window.addEventListener("keyup", (ev) => {
    if (ev.code === "ShiftLeft" || ev.code === "ShiftRight") shiftDown = false;
  });
  // 焦点离开页面时 Shift 可能卡在"按下"状态（keyup 没送到）—— 失焦一律清零
  window.addEventListener("blur", () => {
    shiftDown = false;
  });

  // 首次真实手势时解锁音频（浏览器要求）
  window.addEventListener(
    "pointerdown",
    () => {
      void app.platform.audio.resume();
    },
    { once: true },
  );

  const runR = app.run();
  if (!runR.ok) {
    app.log.channel("host").error(`帧循环启动失败：${runR.error.message}`);
    toast("帧循环启动失败：" + runR.error.message);
  } else {
    // 提示写进页面底栏（**同一份** helpText：改键之后底栏自己会跟着变）
    const helpEl = document.getElementById("help");
    if (helpEl !== null) helpEl.textContent = helpText();
    toast(helpText());
  }

  // 供浏览器端到端判据读取（自动化时用；不影响正常游玩）
  (globalThis as { __engine?: unknown }).__engine = {
    app,
    renderMod,
    physics,
    scene,
    scriptMod,
    save: doSave,
    load: doLoad,
    heroId,
    /** 打一下最近的敌人（自检页用：它要走**玩家这条真实路径**，见 `attackNearest`）。 */
    attack: () => attackNearest(),
    /**
     * 顿帧状态（批73）。自检页用它证两件只有浏览器里才可能坏的事：
     * ① 命中真的让世界停下来（`frozen` / `freezeTicks` / `triggers`）；
     * ② 停的时候画面还在走 —— 这条要配 `renderFrames()` 与 `snapshot().tick` 读。
     */
    hitstop: () => ({ ...hitstopMod.stats }),
    /** 图集真实来源：`assets*7`（6 PNG + 1 JPEG）表示走完了导入链；`procedural` 表示降级了。 */
    atlasSource: atlasLabel,
    /** 世界链的产物：生成计划 / 装配结果 / 可见化报告 / 再生任务句柄。 */
    world: {
      plan: worldState.plan,
      player: worldState.player,
      visual: worldState.visual,
      tasks: worldState.tasks,
      assembled: worldState.assembled,
      /** 半径拾取（自检页用；**会进背包**）。 */
      pickupNearest,
      /**
       * 按格子采一次（自检页用）。目标是确定的格子 —— 判据不该依赖"玩家恰好站在哪"。
       * ★ 注意它**不进背包**（走 `harvestAt`）：它验的是"世界这一侧"，背包那一侧用
       *   `pickup` / `bag` 验。两条判据分开，才不会一条红了两边都要查。
       */
      harvest: (cell: number) => {
        const t = worldState.tasks;
        if (t === null) return err(engineError("HARVEST.NO_TASKS", "世界任务模块没起来"));
        return harvestAt(scene, cell, { onRelease: (c) => t.releaseCell(c) });
      },
      /** 世界里还剩多少可见的东西（地形 / 投放点 / 资源）。 */
      counts: () => ({
        terrain: scene.countOf(TERRAIN_TYPE),
        sites: scene.countOf(SITE_TYPE),
        resources: scene.countOf(RESOURCE_TYPE),
        sprites: scene.countOf(SPRITE_TYPE),
        // 批123：尸体会自己烂掉，所以它不能靠"打死一只就验一次"来观察
        corpses: scene.countOf(CORPSE_TYPE),
      }),
      /** 某一格尸体里有什么（自检页用；`null` = 那一格没有尸体）。 */
      corpseItems: (cell: number) => corpseAt(scene, cell)?.items.slice() ?? null,
      /**
       * 玩家击杀留尸体的诊断（批123）。
       * ★ `playerCorpses` 与 `lastCorpseSkip` 必须一起读：前者 0 而后者空 = 这条
       *   分支根本没走到；前者 0 而后者有值 = 走到了但没成（原因就在那个码里）。
       */
      corpseDiag: () => ({ playerCorpses, lastCorpseSkip, lastVictim }),
    },
    /**
     * 生物群（批66）。自检页要用它证三件**只有浏览器里才可能坏**的事：
     * ① 世界里真有生物（不是只有配表）；② 它们会动；③ 玩家打得到并拿到战利品。
     * 位置直接给出来（而不是只给统计）："会动"必须能被逐次采样比对。
     */
    mobs: () => {
      const m = worldState.mobs;
      if (m === null) return null;
      return {
        ...m.stats,
        list: m.nodeIds.map((id) => {
          const n = scene.find(id);
          return {
            id,
            kind: m.templateOf(id),
            x: n === undefined ? -1 : n.worldPosition.x,
            z: n === undefined ? -1 : n.worldPosition.y,
          };
        }),
      };
    },
    snapshot: () => app.snapshot(),
    lastFrame: () => renderMod.lastFrame,
    /**
     * 饱食度（批67）。自检页要用它证两件**只有浏览器里才可能坏**的事：
     * ① 玩家的 `game.hunger` 真的挂上了（组件没注册/没 attach ⇒ 读回来 undefined）；
     * ② 它会掉（模块被 `onStep` 驱动了 ⇒ 停在那里不动就是没接上）。
     * ★ 顺带把"能吃的东西"和"当前能不能吃"给出去：判据不必自己抄一份食物表。
     */
    hunger: () => {
      const h = heroId < 0 ? undefined : scene.find(heroId)?.get<Hunger>(HUNGER_TYPE);
      return {
        value: h?.value ?? -1,
        max: h?.max ?? -1,
        text: hungerText(),
        food: Object.keys(FOOD_TABLE).sort(),
        edible: heroId < 0
          ? []
          : stacksOf(scene, heroId)
              .filter((s) => FOOD_TABLE[s.kind] !== undefined && s.count > 0)
              .map((s) => ({ kind: s.kind, count: s.count })),
        stats: survivalMod.stats,
      };
    },
    /** 吃一口（自检页驱动；等价于按 E）。返回提示文本，与 toast 同一句。 */
    eat: () => eatSomething(),
    /**
     * 制作（批68）。自检页要证三件**只有浏览器里才可能坏**的事：
     * ① 配方表在建 app 之前就归一化通过了（表写错会在加载期抛）；
     * ② 缺料时制作**不动背包**；
     * ③ 材料齐了能做出东西，且**产物真的进了背包**。
     * 返回提示文本（与 toast 同一句）+ 当前配方清单。
     */
    craft: () => craftSomething(),
    recipes: () => RECIPES.map((r) => ({ id: r.id, name: r.name, inputs: r.inputs, output: r.output })),
    /**
     * **调试/自检专用**：把玩家的饱食度设成某个值。
     * ★ 为什么允许这个后门（与 `give` 同一个理由）：验"饿了能吃、满了不能吃"
     *   要么等 200 秒让它自然掉到 30，要么直接设。后门只改一个数字，不碰世界，
     *   所以它证的仍然是"进食这一侧"。
     */
    setHunger: (v: number) => {
      const h = heroId < 0 ? undefined : scene.find(heroId)?.get<Hunger>(HUNGER_TYPE);
      if (h === undefined) return -1;
      h.value = Math.max(0, Math.min(h.max, Math.floor(v)));
      return h.value;
    },
    /** 背包内容（自检页与截图工具读它：`[{kind,count}]`，空数组 = 真空）。 */
    bag: () => (heroId < 0 ? [] : stacksOf(scene, heroId).map((s) => ({ kind: s.kind, count: s.count }))),
    /** 背包文本（HUD 里那一行，判据直接比对它就不用抄一份格式化逻辑）。 */
    bagText: () => bagText(),
    /** 背包的两层上限（自检页验"上限真的接上了"，不是只写在文档里）。 */
    bagLimits: () => {
      const inv = heroId < 0 ? undefined : scene.find(heroId)?.get<Inventory>("game.inventory");
      return { maxStacks: inv?.maxStacks ?? 0, maxStack: inv?.maxStack ?? 0 };
    },
    /**
     * **调试/自检专用**：直接往包里放 n 个（绕过世界采集）。
     * ★ 为什么允许这个后门：堆叠上限的判据需要"采 45 次芦苇"才能撞到 40，
     *   而一次采集要等资源再生（30 tick）—— 判据会慢到没法每轮跑。
     *   后门只加物品、不碰世界，所以它证的仍是"背包这一侧"。
     */
    give: (kind: string, n: number) => (heroId < 0 ? err(engineError("BAG.NO_OWNER", "没有玩家")) : addItem(scene, heroId, kind, n)),
    /**
     * **调试/自检专用**：清空背包，**但不往世界里丢**。
     *
     * ★ 为什么不能直接用"整堆丢弃"来清空：`dropIntoWorld` 会把东西丢在玩家脚下，
     *   而后面还有"拾取进包"的判据 —— 清空产生的 5 堆垃圾会被它们捡走，
     *   于是"背包 53→52→54"（多捡了一份）。判据之间的**共享可变世界**就是靠
     *   "别留下副作用"来隔离的；需要副作用的地方，就该给一个没有副作用的入口。
     * ★ 只删物品节点，不碰世界、不碰玩家。
     */
    clearBag: () => {
      if (heroId < 0) return 0;
      const stacks = stacksOf(scene, heroId);
      let n = 0;
      for (const s of stacks) {
        const node = s.node;
        if (node === null || node === undefined) continue;
        scene.destroy(node.id);
        n++;
      }
      scene.flush();
      return n;
    },
    /**
     * 表现层（批69，自检页用）。
     *
     * ★ 这里返回的是**屏幕上的事实**（DOM 里几个数字、精灵现在什么颜色），
     *   不是"我调过 flash 所以应该闪了"。前者能抓住"调了但没接到渲染"，
     *   后者只能证明函数被调用过（批66 的 `firstIndex` 就是这么假绿的）。
     */
    feedback: {
      /** 屏幕上还活着的伤害数字（`[{text, dead, opacity, by}]`，空数组 = 都消失了）。 */
      numbers: () => damageNumbers.map((d) => ({ text: d.text, dead: d.dead, opacity: d.el.style.opacity, by: d.by })),
      /**
       * DOM 里真的有这么多 `.dmg` 元素（与上面的数组**分开**：一个对、一个错就是漏删）。
       * ★ `by` 可选（批74）：只数某个攻击者冒的数字。生物打斗也在冒数字，
       *   不区分来源的话"数字会消失"在打斗窗口里永远等不到 0。
       */
      domCount: (by?: number) =>
        by === undefined
          ? fxLayer.querySelectorAll(".dmg").length
          : fxLayer.querySelectorAll(`.dmg[data-dmg-by="${String(by)}"]`).length,
      /** 某个节点现在是不是在闪（读组件字段，不是读"我记得调过"）。 */
      flashing: (id: number) => {
        const fb = scene.find(id)?.get<Feedback>(FEEDBACK_TYPE);
        return fb === undefined ? -1 : fb.flashTicks;
      },
      /** 累计：表现层自己吞掉的错误码（正常时为空数组）。 */
      errors: () => [...feedbackErrors],
      /** 闪一下（自检页需要在**不打架**的情况下验"闪完会还原"）。 */
      flash: (id: number, ticks: number) => {
        const r = flashNode(scene, id, ticks);
        return r.ok ? r.value.remaining : `${r.error.code}：${r.error.message}`;
      },
      /** 精灵现在乘的是什么色（验"闪的是红、还原回原色"）。 */
      tint: (id: number) => {
        const sp = scene.find(id)?.get<Sprite>(SPRITE_TYPE);
        return sp === undefined ? null : { r: sp.r, g: sp.g, b: sp.b, a: sp.a };
      },
      /** 模块统计（闪几个/挤几个/还原几次/覆盖几次）。 */
      stats: () => feedbackMod.stats,
      /**
       * **调试/自检专用**：在玩家旁边放一个 2 血的靶子（有血量、有精灵、无 AI）。
       *
       * ★ 为什么需要它：验"屏幕上的数字是不是**实际扣血**"必须让
       *   `applied ≠ attacker.damage`（玩家伤害 3、靶子 2 血 ⇒ 应该显示 -2）。
       *   而世界里的生物血量都是满的，那两条数永远相等 —— 那种语料下
       *   "用 damage 还是 applied"是分不出来的。
       * ★ 它不改玩家状态、不碰背包，所以它证的仍然是"命中这一侧"。
       * ★★ 批123：第二个参数给"打死它掉什么"。**没有它，尸体的判据就没有语料** ——
       *   演示世界的兔子会在开播 3~4 秒内被猎狗吃光（3 只猎狗 × 2 伤害 / 0.5 秒
       *   对 10 只 4 血兔子），而"尸体"这条判据必须有**一只当场能打死的、带战利品表
       *   的非盟友**。依赖世界的自发活动（"碰巧还剩一只兔子"）是在赌，
       *   而判据不许赌。
       */
      dummy: (hp = 2, loot: readonly { kind: string; count: number }[] = []) => {
        if (heroId < 0) return -1;
        const hero = scene.find(heroId);
        if (hero === undefined) return -1;
        const p = hero.worldPosition;
        const n = scene.spawnAt(`靶子×${String(hp)}血`, p.x + 1, p.y);
        if (!n.ok) return -1;
        const id = n.value.id;
        const h = new Health();
        h.maxHp = hp;
        h.hp = hp;
        scene.attach(id, () => h);
        scene.attach(id, () => makeSprite("rabbit", 1, 1));
        scene.flush();
        if (loot.length > 0) {
          // 挂不上就**别把它当靶子交出去**：没有战利品表的靶子打死了不留尸体，
          // 而那种失败在判据里看起来一模一样（"尸体没生成"）。
          const l = attachLoot(scene, id, loot);
          if (!l.ok) {
            scene.destroy(id);
            scene.flush();
            return -1;
          }
        }
        return id;
      },
    },
    /**
     * 导航网格（批60，自检页用）。
     * ★ 自检只验两件**浏览器里才可能坏**的事：网格真的建起来了、两次寻路逐格相同。
     *   寻路算法本身对不对由 Node 判据 + 变异管，这里不重复。
     */
    nav: {
      stats: () => {
        const g = worldState.nav;
        if (g === null) return null;
        const st = g.stats();
        return {
          width: st.width,
          height: st.height,
          walkable: st.walkable,
          blocked: st.blocked,
          components: g.componentCount,
        };
      },
      isWalkable: (cell: number) => worldState.nav?.isWalkableIndex(cell) ?? false,
      /** 不抛：返回 `{ok:true,cells,cost}` 或 `{ok:false,code}`。 */
      path: (from: number, to: number) => {
        const g = worldState.nav;
        if (g === null) return { ok: false as const, code: "NAV.NO_GRID" };
        const r = g.findPath(from, to);
        if (!r.ok) return { ok: false as const, code: r.error.code };
        return { ok: true as const, cells: r.value.cells.slice(), cost: r.value.cost };
      },
    },
    /** 背包面板状态（自检页读 UI 之前先读它：开着没有、选中第几堆）。 */
    bagPanel: () => ({ open: bagOpen, selected: bagSel, stacks: stacksOf(scene, heroId).length }),
    /** 开关面板（自检页驱动；等价于按 Tab）。 */
    toggleBag: () => {
      setBagOpen(!bagOpen);
      return bagOpen;
    },
    /** 选中第 i 堆（自检页驱动；等价于按数字键）。 */
    selectStack: (i: number) => selectBagRow(i),
    /**
     * 弹一条提示（自检页驱动）。
     *
     * ★ 为什么要有这个入口：提示的**触发点**散在十几个动作里（存档、丢弃、制作失败…），
     *   而"提示走 UI 而不是 DOM"这件事与"哪个动作触发"无关。造一个直接入口，
     *   自检页才能在不依赖某个玩法的前提下验它 —— 否则这条断言会跟着玩法改，
     *   改一次断一次，最后没人维护。
     */
    toast: (msg: string) => toast(msg),
    /** 丢弃选中堆（自检页驱动；等价于按 Q，`whole` = 按住 Shift）。 */
    dropSelected: (whole = false) => {
      const r = dropSelected(whole);
      return r.ok ? { ok: true as const, value: r.value } : { ok: false as const, code: r.error.code, message: r.error.message };
    },
    /** 当前操作提示（**从映射表生成**，改键后它自己会变）。 */
    helpText: () => helpText(),
    /** 动作名 → 键位（改键界面的数据源，也是"提示与键位同源"的证据）。 */
    bindings: () => ({ ...controllerMod.map.toData().actions }),
    /** 最近一帧的 HUD 一行文本（**UI 路径下 DOM 不再更新**，诊断与降级都读这里）。 */
    hudText: () => lastHudText,
    /**
     * 图形后端的帧计数（`frameIndex` **每次 `endFrame` 加一**）。
     *
     * ★★ 自检页用它证"UI 与世界在**同一个 pass**"：一帧里若 UI 自己开了第二个
     *   `beginFrame/endFrame`，`frameIndex` 会跳 2。这是这条集成约定**唯一**
     *   能从外部观测到的证据 —— 顶点和 draw call 都看不出"在不在同一个 pass 里"。
     */
    gfxStats: () => app.platform.gfx.stats,
    /** 累计渲染帧数（引擎侧计数）。与 `gfxStats().frameIndex` 对账 ⇒ 一帧几个 pass。 */
    renderFrames: () => renderFrames,
    /**
     * 像素级断言的窗口（批115）：回调在 `endFrame` 之后、**同一个任务里**被调（一次）。
     * ★ 自检页在这里把 WebGL 画布 `drawImage` 到 2D 画布再读像素 ——
     *   `preserveDrawingBuffer: false` 之下，出了这个任务帧缓冲就空了
     *   （自检页头部那条注释说过：帧后 `readPixels` 读不到内容）。
     *   返回退订函数（等不到帧时用来收尾）。
     */
    onFrameEnd: (cb: () => void) => renderMod.onFrameEnd(cb),
    /**
     * UI（批71）。`null` = UI 资产不可用，HUD 已退回 DOM。
     *
     * ★ 这里给的必须是**屏幕上的事实**：这一帧真画了多少 quad/字形、
     *   有没有画不出来的字、面板的行文本是什么、点一下会发生什么。
     *   "我建了 UI 模块"不能当证据 —— 它和"UI 真的画出来了"是两件事。
     */
    ui:
      hudUi === null
        ? null
        : {
            lastFrame: () => hudUi.module.lastFrame,
            /** 设计坐标里的节点矩形（`null` = 不可见/没这个 id）。 */
            rect: (id: string) => rectOfId(hudUi, id) ?? null,
            /**
             * 节点的动画属性（批76 判据用）：过渡到底有没有真的改到节点上。
             * ★ 只暴露"节点自己存的值"，不在这里乘父链 —— 判据读到的东西
             *   必须与 `applyUiTween` 写进去的是同一个量，否则断言的是另一个数。
             */
            anim: (id: string) => {
              const n = hudUi.module.root.find(id);
              return n === undefined
                ? null
                : { opacity: n.opacity, scale: n.scale, x: n.offset.x, y: n.offset.y };
            },
            /** 面板里**画出来的**行文本（不是重新算一遍的那份）。 */
            bagRows: () => hudUi.bagRowTexts.slice(),
            /**
             * 最近一帧 UI 实际提交的顶点（诊断；与渲染模块的 `lastVertices` 同款）。
             * ★ Node 判据验的是「要画什么」，这里验的是「真的提交了什么」——
             *   「四边形说有、像素说没有」时只有这一层能分辨 UV 与位置（批115）。
             */
            verts: (n: number) => hudUi.module.lastVertices(n),
            /** 当前提示文案（"" = 没有）。自检页用它证"提示走 UI 树而不是 DOM"。 */
            toastText: () => hudUi.toastText,
            /** 命令行输入框的状态（自检页读**屏幕上那份**：display / 光标）。 */
            cmdText: () => cmd.display,
            cmdVisible: () => hudUi.inputVisible,
            cmdCaret: () => cmd.displayCaret,
            cmdSelection: () => cmd.selection,
            bagOpen: () => hudUi.bagOpen,
            hudRowIds: hudUi.hudRowIds,
            /** 设计坐标（自检页验"点击命中真实矩形"时用）。 */
            designSize: () => ({ w: hudUi.module.viewport.designWidth, h: hudUi.module.viewport.designHeight }),
            /**
             * 设计坐标 → CSS 像素（含视口缩放与 letterbox 偏移）。
             * ★ 像素断言用它定位采样区：行矩形是设计像素，帧缓冲是画布像素，
             *   中间隔着这一步换算 —— 跳过它采样就会采到别的行（视口 1×1 时碰巧对，
             *   缩放一变就错，而且错得没有计数能看出来）。
             */
            toScreen: (x: number, y: number) => hudUi.module.viewport.designToScreen(x, y),
            /**
             * 点一下某个节点：走**真实指针路径**（设计坐标 → CSS 像素 → 命中测试 → click）。
             * 直接改 `bagSel` 只能证明"赋值有效"，证明不了"面板上的行点得到"。
             */
            clickNode: (id: string) => {
              hudUi.module.relayout();
              const r = rectOfId(hudUi, id);
              if (r === undefined) return { ok: false as const, reason: "NO_RECT", clicks: [] as string[] };
              const s = hudUi.module.viewport.designToScreen(r.x + r.width / 2, r.y + r.height / 2);
              hudUi.pointer(s.x, s.y, true);
              const evs = hudUi.pointer(s.x, s.y, false);
              return {
                ok: true as const,
                reason: "",
                clicks: evs.filter((e) => e.type === "click").map((e) => e.target.id),
              };
            },
            /**
             * 从一个节点拖到另一个节点：走**真实指针路径**（按下 → 中间移动 → 抬起）。
             *
             * ★ 为什么不直接调 `onSwapRows`：拖拽的三条语义（按下捕获、位移阈值、
             *   逐帧命中）全在路由层。直接调回调只能证明"宿主把回调接上了"，
             *   证明不了"这东西拖得动" —— 而拖不动才是玩家会遇到的那一半。
             * ★ 中间那一步不能省：没有 `pointermove`，落点永远停在起点，
             *   松手就等于"原地放下"，而它在断言里看起来和"换位成功"一样（都是两行没变）。
             */
            dragNode: (fromId: string, toId: string) => {
              hudUi.module.relayout();
              const a = rectOfId(hudUi, fromId);
              const b = rectOfId(hudUi, toId);
              if (a === undefined || b === undefined) return { ok: false as const, reason: "NO_RECT" };
              const sa = hudUi.module.viewport.designToScreen(a.x + a.width / 2, a.y + a.height / 2);
              const sb = hudUi.module.viewport.designToScreen(b.x + b.width / 2, b.y + b.height / 2);
              hudUi.pointer(sa.x, sa.y, true);
              hudUi.pointer((sa.x + sb.x) / 2, (sa.y + sb.y) / 2, true);
              hudUi.pointer(sb.x, sb.y, true);
              hudUi.pointer(sb.x, sb.y, false);
              return { ok: true as const, reason: "" };
            },
          },
  };
}

void main();
