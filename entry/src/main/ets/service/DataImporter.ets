import { preferences, relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Constants, Tables } from '../common/Constants';
import { Logger } from '../common/Logger';
import { AppStore } from '../common/AppStore';
import { HISTORY_DATES, HISTORY_NOTES } from './HistoryData';

const PREF_FILE: string = 'fitdot_import';
const PREF_KEY: string = 'history_imported_v1';

/**
 * 一次性把旧打卡 App 的「健身」历史记录导入本应用（带标记，只会执行一次）。
 *
 * 规则：
 * 1. 先清空 check_in / workout_item，保证与源数据完全一致（顺带清掉调试期产生的记录）；
 * 2. 逐天写入打卡，备注为当天的训练部位；
 * 3. check_in_at 记为当天 20:00（历史补录的合理时刻）。
 */
export class DataImporter {
  private static running: boolean = false;

  /** 首页 aboutToAppear 调用；已有标记或缺上下文时直接跳过 */
  static async maybeImport(): Promise<void> {
    if (DataImporter.running) {
      return;
    }
    const ctx = AppStore.get().abilityContext;
    if (ctx === undefined) {
      return;
    }
    DataImporter.running = true;
    try {
      const sp = await preferences.getPreferences(ctx, { name: PREF_FILE });
      const done: boolean = (await sp.get(PREF_KEY, false)) as boolean;
      if (done) {
        return;
      }
      await DataImporter.doImport();
      await sp.put(PREF_KEY, true);
      await sp.flush();
      // 通知所有页面按导入后的数据刷新
      AppStore.get().markDirty();
      Logger.info(Constants.TAG, `历史数据导入完成：${HISTORY_DATES.length} 天`);
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `历史数据导入失败: ${err.message}`);
    } finally {
      DataImporter.running = false;
    }
  }

  private static async doImport(): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    // 单事务：要么全部导入成功，要么回滚，不会出现半截数据
    store.beginTransaction();
    try {
      await store.executeSql(`DELETE FROM ${Tables.WORKOUT_ITEM}`);
      await store.executeSql(`DELETE FROM ${Tables.CHECK_IN}`);
      for (let i = 0; i < HISTORY_DATES.length; i++) {
        const date: string = HISTORY_DATES[i];
        const note: string = i < HISTORY_NOTES.length ? HISTORY_NOTES[i] : '';
        const at: number = DataImporter.eveningOf(date);
        const values: relationalStore.ValuesBucket = {
          'date': date,
          'check_in_at': at,
          'duration_min': 0,
          'feeling': 0,
          'note': note,
          'is_backfill': 1,
          'created_at': at,
          'updated_at': at
        };
        await store.insert(Tables.CHECK_IN, values);
      }
      store.commit();
    } catch (e) {
      store.rollBack();
      throw e as Error;
    }
    // 全部落进主库文件，避免重启丢数据
    await DbHelper.flush(store);
  }

  /** 'YYYY-MM-DD' -> 当天 20:00 的时间戳 */
  private static eveningOf(date: string): number {
    const parts: string[] = date.split('-');
    const y: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    const d: number = Number.parseInt(parts[2], 10);
    return new Date(y, m - 1, d, 20, 0, 0).getTime();
  }
}
