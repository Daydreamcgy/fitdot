import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { Constants, Tables } from '../common/Constants';

const SQL_CREATE_CHECK_IN: string =
  `CREATE TABLE IF NOT EXISTS ${Tables.CHECK_IN} (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     date TEXT NOT NULL,
     check_in_at INTEGER NOT NULL DEFAULT 0,
     duration_min INTEGER NOT NULL DEFAULT 0,
     feeling INTEGER NOT NULL DEFAULT 0,
     note TEXT NOT NULL DEFAULT '',
     is_backfill INTEGER NOT NULL DEFAULT 0,
     created_at INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL DEFAULT 0
   )`;

const SQL_CREATE_CHECK_IN_INDEX: string =
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_check_in_date ON ${Tables.CHECK_IN}(date)`;

const SQL_CREATE_WORKOUT: string =
  `CREATE TABLE IF NOT EXISTS ${Tables.WORKOUT_ITEM} (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     check_in_id INTEGER NOT NULL DEFAULT 0,
     body_part TEXT NOT NULL DEFAULT '',
     exercise_name TEXT NOT NULL DEFAULT '',
     sets INTEGER NOT NULL DEFAULT 0,
     reps INTEGER NOT NULL DEFAULT 0,
     weight_kg REAL NOT NULL DEFAULT 0,
     duration_min INTEGER NOT NULL DEFAULT 0,
     distance_km REAL NOT NULL DEFAULT 0,
     sort_order INTEGER NOT NULL DEFAULT 0,
     sets_json TEXT DEFAULT '',
     group_tag TEXT DEFAULT ''
   )`;

const SQL_CREATE_WORKOUT_INDEX: string =
  `CREATE INDEX IF NOT EXISTS idx_workout_check_in ON ${Tables.WORKOUT_ITEM}(check_in_id)`;

/** v1 -> v2：check_in 新增训练部位列 */
const SQL_ADD_BODY_PARTS: string =
  `ALTER TABLE ${Tables.CHECK_IN} ADD COLUMN body_parts TEXT DEFAULT ''`;

/** v2 -> v3：workout_item 新增有氧专用列（坡度、速度） */
const SQL_ADD_INCLINE: string =
  `ALTER TABLE ${Tables.WORKOUT_ITEM} ADD COLUMN incline REAL DEFAULT 0`;
const SQL_ADD_SPEED: string =
  `ALTER TABLE ${Tables.WORKOUT_ITEM} ADD COLUMN speed REAL DEFAULT 0`;

/** v3 -> v4：workout_item 新增组列表 JSON（每组 次数×重量）与超级组标记列。
 *  旧行 sets_json 为空 = 单组（读取时按 sets/weight_kg 自动推导），无需回填。 */
const SQL_ADD_SETS_JSON: string =
  `ALTER TABLE ${Tables.WORKOUT_ITEM} ADD COLUMN sets_json TEXT DEFAULT ''`;
const SQL_ADD_GROUP_TAG: string =
  `ALTER TABLE ${Tables.WORKOUT_ITEM} ADD COLUMN group_tag TEXT DEFAULT ''`;

/** 规范部位全集（顺序固定，存储与展示都按这个顺序） */
const BODY_PART_CANON: string[] = ['肩部', '腿部', '背部', '二头', '胸部', '三头', '腹肌', '有氧'];

/** 「全身」对应的部位集合（有氧单独由 有氧/爬坡/跑步 给出） */
const FULL_BODY_PARTS: string[] = ['肩部', '腿部', '背部', '二头', '胸部', '三头', '腹肌'];

/** 回填用的一次性行补丁 */
interface BodyPartsPatch {
  id: number;
  parts: string;
}

/**
 * 把旧备注文本解析成规范部位串（逗号连接、按 BODY_PART_CANON 顺序去重）。
 * 规则：按 + ＋ 、 ， , 空格 · 切分；每段按关键词映射——
 * 含"肩"→肩部、"腿"→腿部、"背"→背部、"二头"→二头、"三头"→三头、"腹"→腹肌、
 * 含"有氧|爬坡|跑步"→有氧、含"胸"→胸部、含"全身"→肩部,腿部,背部,二头,胸部,三头,腹肌。
 * 例："胸 + 爬坡"→"胸部,有氧"；"背 二头"→"背部,二头"；"肩部+腿"→"肩部,腿部"。
 */
function parseBodyPartsFromNote(note: string): string {
  const found: Set<string> = new Set<string>();
  const segments: string[] = note.split(/[+＋、，, ·]/);
  for (const seg of segments) {
    const s: string = seg.trim();
    if (s.length === 0) {
      continue;
    }
    if (s.includes('全身')) {
      for (const p of FULL_BODY_PARTS) {
        found.add(p);
      }
    }
    if (s.includes('肩')) {
      found.add('肩部');
    }
    if (s.includes('腿')) {
      found.add('腿部');
    }
    if (s.includes('背')) {
      found.add('背部');
    }
    if (s.includes('二头')) {
      found.add('二头');
    }
    if (s.includes('三头')) {
      found.add('三头');
    }
    if (s.includes('腹')) {
      found.add('腹肌');
    }
    if (s.includes('有氧') || s.includes('爬坡') || s.includes('跑步')) {
      found.add('有氧');
    }
    if (s.includes('胸')) {
      found.add('胸部');
    }
  }
  const out: string[] = [];
  for (const p of BODY_PART_CANON) {
    if (found.has(p)) {
      out.push(p);
    }
  }
  return out.join(',');
}

/**
 * 数据库单例。
 *
 * 用法：在 EntryAbility.onCreate 里调用 init(this.context)，
 * 后续任何地方用 DbHelper.getInstance().getStore() 拿 RdbStore。
 */
export class DbHelper {
  private static instance: DbHelper | undefined = undefined;
  private store: relationalStore.RdbStore | undefined = undefined;
  private initPromise: Promise<void> | undefined = undefined;

  static getInstance(): DbHelper {
    if (DbHelper.instance === undefined) {
      DbHelper.instance = new DbHelper();
    }
    return DbHelper.instance;
  }

  /** 幂等初始化，可重复调用 */
  init(context: common.Context): Promise<void> {
    if (this.initPromise === undefined) {
      this.initPromise = this.doInit(context);
    }
    return this.initPromise;
  }

  private async doInit(context: common.Context): Promise<void> {
    // securityLevel 取 S3：官方对 S3 的说明原文是「泄露产生重大影响，例如包含用户
    // 运动、健康、位置等信息的数据库」—— 健身记录正好落在这一档，不要用默认的 S1。
    const config: relationalStore.StoreConfig = {
      name: Constants.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S3,
      // 开启数据库加密（密文落盘）。
      // ⚠️ 注意：该参数在数据库创建后**不允许直接修改**，要改只能走 rekeyEx。
      //   本工程是新建库，所以在这里定死；若日后想去掉加密，需要写迁移逻辑。
      encrypt: true,
      // 显式关掉「出异常就删库重建空表」。健身记录是用户资产，
      // 宁可打开失败报错，也不能悄悄把库里数据清空。
      allowRebuild: false
    };
    try {
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      await DbHelper.migrate(store);
      // 启动时先刷一次：把上一个进程留在 WAL 里、已提交但还没落进主库文件的数据补落盘。
      await DbHelper.flush(store);
      this.store = store;
      Logger.info(Constants.TAG, '数据库初始化完成');
    } catch (e) {
      const err = e as BusinessError;
      Logger.error(Constants.TAG, `数据库初始化失败 code=${err.code} message=${err.message}`);
      // 清掉缓存的 promise，允许下次重试
      this.initPromise = undefined;
      throw new Error(`数据库初始化失败: ${err.message}`);
    }
  }

  /** 建表与版本升级 */
  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    const version: number = store.version;
    if (version === Constants.DB_VERSION) {
      return;
    }
    Logger.info(Constants.TAG, `数据库版本 ${version} -> ${Constants.DB_VERSION}，开始迁移`);
    if (version < 1) {
      await store.executeSql(SQL_CREATE_CHECK_IN);
      await store.executeSql(SQL_CREATE_CHECK_IN_INDEX);
      await store.executeSql(SQL_CREATE_WORKOUT);
      await store.executeSql(SQL_CREATE_WORKOUT_INDEX);
    }
    // v1 -> v2：check_in 增加 body_parts 列，并把旧备注一次性解析回填
    if (version < 2) {
      await store.executeSql(SQL_ADD_BODY_PARTS);
      await DbHelper.backfillBodyParts(store);
    }
    // v2 -> v3：workout_item 增加有氧专用列（坡度、速度）
    if (version < 3) {
      await store.executeSql(SQL_ADD_INCLINE);
      await store.executeSql(SQL_ADD_SPEED);
    }
    // v3 -> v4：workout_item 增加组列表 JSON 与超级组标记
    if (version < 4) {
      await store.executeSql(SQL_ADD_SETS_JSON);
      await store.executeSql(SQL_ADD_GROUP_TAG);
    }
    store.version = Constants.DB_VERSION;
    Logger.info(Constants.TAG, '数据库迁移完成');
  }

  /** 一次性回填：body_parts 为空且 note 非空的行，用备注解析出部位写回 */
  private static async backfillBodyParts(store: relationalStore.RdbStore): Promise<void> {
    const sql: string =
      `SELECT id, note, body_parts FROM ${Tables.CHECK_IN} WHERE note <> ''`;
    const rs: relationalStore.ResultSet = await store.querySql(sql);
    const patches: BodyPartsPatch[] = [];
    try {
      while (rs.goToNextRow()) {
        const existing: string = rs.getString(rs.getColumnIndex('body_parts'));
        if (existing.length > 0) {
          continue;
        }
        const note: string = rs.getString(rs.getColumnIndex('note'));
        const parts: string = parseBodyPartsFromNote(note);
        if (parts.length === 0) {
          continue;
        }
        const patch: BodyPartsPatch = {
          id: rs.getLong(rs.getColumnIndex('id')),
          parts: parts
        };
        patches.push(patch);
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    for (const patch of patches) {
      await store.executeSql(`UPDATE ${Tables.CHECK_IN} SET body_parts = ? WHERE id = ?`,
        [patch.parts, patch.id]);
    }
    if (patches.length > 0) {
      Logger.info(Constants.TAG, `body_parts 回填完成，共 ${patches.length} 行`);
    }
  }

  /**
   * 把 WAL 里已提交的数据强制刷进主库文件，并把 WAL 截断为 0。
   *
   * 背景：真机（Mate 60 Pro / API 26 / encrypt:true）实测发现——
   * 每次写入都正确提交了（WAL 里几十个 commit 帧、salt 一致），
   * 但主库文件始终只有 1 页；进程被杀之后重启，从 WAL 恢复失败，
   * 读到的永远是空库，表现为「打卡数据一重启就丢」。
   *
   * 所以在每次写库后立刻调用本方法：数据当场写进主库文件，
   * 之后无论怎么重启都不再依赖 WAL 恢复。
   * execute()（API 14+）是官方允许执行 PRAGMA 的入口。
   */
  static async flush(store: relationalStore.RdbStore): Promise<void> {
    try {
      await store.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      const err = e as BusinessError;
      Logger.warn(Constants.TAG, `WAL checkpoint 失败 code=${err.code} message=${err.message}`);
    }
  }

  /** 写库后的统一收尾：把数据落进主库文件（checkpoint 最多等 1.5 秒，避免卡住后续写库） */
  static async flushAfterWrite(): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
      const job: Promise<void> = DbHelper.flush(store);
      const timeout: Promise<void> = new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 1500);
      });
      await Promise.race([job, timeout]);
    } catch (e) {
      // getStore 失败时写库本身也已经失败，这里只记日志
      Logger.warn(Constants.TAG, 'flushAfterWrite 获取 RdbStore 失败');
    }
  }

  /** 获取 RdbStore；若尚未初始化则报错（正常流程不会发生） */
  async getStore(): Promise<relationalStore.RdbStore> {
    if (this.store !== undefined) {
      return this.store;
    }
    if (this.initPromise !== undefined) {
      await this.initPromise;
      if (this.store !== undefined) {
        return this.store;
      }
    }
    throw new Error('数据库尚未初始化，请先在 EntryAbility.onCreate 中调用 DbHelper.init()');
  }

  /** 结果集安全关闭 */
  static closeQuietly(rs: relationalStore.ResultSet | undefined): void {
    if (rs === undefined) {
      return;
    }
    try {
      rs.close();
    } catch (e) {
      Logger.warn(Constants.TAG, '关闭 ResultSet 失败');
    }
  }
}
