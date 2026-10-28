import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { DbHelper } from '../database/DbHelper';
import { Tables, Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { CheckIn, CheckInDraft, emptyCheckIn } from '../model/Models';

const COLUMNS: string[] = [
  'id', 'date', 'check_in_at', 'duration_min', 'feeling', 'note', 'is_backfill', 'body_parts'
];

/** 打卡记录仓储 */
export class CheckInRepository {
  private static fromResultSet(rs: relationalStore.ResultSet): CheckIn {
    const c: CheckIn = {
      id: rs.getLong(rs.getColumnIndex('id')),
      date: rs.getString(rs.getColumnIndex('date')),
      checkInAt: rs.getLong(rs.getColumnIndex('check_in_at')),
      durationMin: rs.getLong(rs.getColumnIndex('duration_min')),
      feeling: rs.getLong(rs.getColumnIndex('feeling')),
      note: rs.getString(rs.getColumnIndex('note')),
      bodyParts: rs.getString(rs.getColumnIndex('body_parts')),
      isBackfill: rs.getLong(rs.getColumnIndex('is_backfill')) === 1
    };
    return c;
  }

  /** 查某天的打卡，没有返回 undefined */
  static async getByDate(date: string): Promise<CheckIn | undefined> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    predicates.equalTo('date', date);
    const rs: relationalStore.ResultSet = await store.query(predicates, COLUMNS);
    let result: CheckIn | undefined = undefined;
    try {
      if (rs.goToFirstRow()) {
        result = CheckInRepository.fromResultSet(rs);
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return result;
  }

  /** 该天是否已打卡 */
  static async exists(date: string): Promise<boolean> {
    const c: CheckIn | undefined = await CheckInRepository.getByDate(date);
    return c !== undefined;
  }

  /** 全部打卡日期，升序 */
  static async listAllDates(): Promise<string[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const rs: relationalStore.ResultSet =
      await store.querySql(`SELECT date FROM ${Tables.CHECK_IN} ORDER BY date ASC`);
    const dates: string[] = [];
    try {
      while (rs.goToNextRow()) {
        dates.push(rs.getString(rs.getColumnIndex('date')));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return dates;
  }

  /** 区间内的打卡日期（含首尾），升序 */
  static async listDatesBetween(start: string, end: string): Promise<string[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT date FROM ${Tables.CHECK_IN} WHERE date >= ? AND date <= ? ORDER BY date ASC`,
      [start, end]
    );
    const dates: string[] = [];
    try {
      while (rs.goToNextRow()) {
        dates.push(rs.getString(rs.getColumnIndex('date')));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return dates;
  }

  /** 全部打卡记录，按日期倒序 */
  static async listAll(): Promise<CheckIn[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    predicates.orderByDesc('date');
    const rs: relationalStore.ResultSet = await store.query(predicates, COLUMNS);
    const list: CheckIn[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(CheckInRepository.fromResultSet(rs));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return list;
  }

  /**
   * 保存打卡：存在则更新，不存在则插入。
   * @returns 保存后的记录（带真实 id）
   */
  static async save(draft: CheckInDraft): Promise<CheckIn> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const now: number = Date.now();
    const existing: CheckIn | undefined = await CheckInRepository.getByDate(draft.date);

    if (existing === undefined) {
      const values: relationalStore.ValuesBucket = {
        'date': draft.date,
        'check_in_at': now,
        'duration_min': draft.durationMin,
        'feeling': draft.feeling,
        'note': draft.note,
        'body_parts': '',
        'is_backfill': draft.isBackfill ? 1 : 0,
        'created_at': now,
        'updated_at': now
      };
      const rowId: number = await store.insert(Tables.CHECK_IN, values);
      Logger.info(Constants.TAG, `打卡成功 date=${draft.date} rowId=${rowId}`);
      const saved: CheckIn = emptyCheckIn(draft.date);
      saved.id = rowId;
      saved.checkInAt = now;
      saved.durationMin = draft.durationMin;
      saved.feeling = draft.feeling;
      saved.note = draft.note;
      saved.isBackfill = draft.isBackfill;
      return saved;
    }

    const values: relationalStore.ValuesBucket = {
      'duration_min': draft.durationMin,
      'feeling': draft.feeling,
      'note': draft.note,
      'is_backfill': draft.isBackfill ? 1 : 0,
      'updated_at': now
    };
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    predicates.equalTo('date', draft.date);
    await store.update(values, predicates);
    const updated: CheckIn = existing;
    updated.durationMin = draft.durationMin;
    updated.feeling = draft.feeling;
    updated.note = draft.note;
    updated.isBackfill = draft.isBackfill;
    return updated;
  }

  /** 只更新时长/感受/备注，不动打卡时间 */
  static async updateDetail(date: string, durationMin: number, feeling: number, note: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const values: relationalStore.ValuesBucket = {
      'duration_min': durationMin,
      'feeling': feeling,
      'note': note,
      'updated_at': Date.now()
    };
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    predicates.equalTo('date', date);
    await store.update(values, predicates);
  }

  /** 更新某天的训练部位（逗号分隔的规范部位名字符串，如 "胸部,三头"） */
  static async updateBodyParts(date: string, parts: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const values: relationalStore.ValuesBucket = {
      'body_parts': parts,
      'updated_at': Date.now()
    };
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    predicates.equalTo('date', date);
    await store.update(values, predicates);
  }

  /** 删除某天打卡（明细由 WorkoutRepository 一并清掉） */
  static async deleteByDate(date: string): Promise<void> {    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    predicates.equalTo('date', date);
    try {
      await store.delete(predicates);
      Logger.info(Constants.TAG, `已取消打卡 date=${date}`);
    } catch (e) {
      const err = e as BusinessError;
      Logger.error(Constants.TAG, `取消打卡失败 code=${err.code} message=${err.message}`);
      throw new Error(`取消打卡失败: ${err.message}`);
    }
  }

  /** 删除全部打卡（仅导入恢复前使用） */
  static async deleteAll(): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.CHECK_IN);
    await store.delete(predicates);
  }

  /** 累计训练时长（分钟） */
  static async sumDuration(): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT IFNULL(SUM(duration_min), 0) AS total FROM ${Tables.CHECK_IN}`
    );
    let total: number = 0;
    try {
      if (rs.goToFirstRow()) {
        total = rs.getLong(rs.getColumnIndex('total'));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return total;
  }

  /** 区间内累计训练时长（分钟） */
  static async sumDurationBetween(start: string, end: string): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT IFNULL(SUM(duration_min), 0) AS total FROM ${Tables.CHECK_IN} WHERE date >= ? AND date <= ?`,
      [start, end]
    );
    let total: number = 0;
    try {
      if (rs.goToFirstRow()) {
        total = rs.getLong(rs.getColumnIndex('total'));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return total;
  }

  /** 区间内打卡天数 */
  static async countBetween(start: string, end: string): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS cnt FROM ${Tables.CHECK_IN} WHERE date >= ? AND date <= ?`,
      [start, end]
    );
    let cnt: number = 0;
    try {
      if (rs.goToFirstRow()) {
        cnt = rs.getLong(rs.getColumnIndex('cnt'));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return cnt;
  }
}
