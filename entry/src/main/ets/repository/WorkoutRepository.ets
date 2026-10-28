import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Tables } from '../common/Constants';
import { BodyPartCount, ExerciseCount, SetEntry, WorkoutItem } from '../model/Models';

const COLUMNS: string[] = [
  'id', 'check_in_id', 'body_part', 'exercise_name', 'sets', 'reps',
  'weight_kg', 'duration_min', 'distance_km', 'incline', 'speed', 'sort_order',
  'sets_json', 'group_tag'
];

/** 训练明细仓储 */
export class WorkoutRepository {
  private static fromResultSet(rs: relationalStore.ResultSet): WorkoutItem {
    const w: WorkoutItem = {
      id: rs.getLong(rs.getColumnIndex('id')),
      checkInId: rs.getLong(rs.getColumnIndex('check_in_id')),
      bodyPart: rs.getString(rs.getColumnIndex('body_part')),
      exerciseName: rs.getString(rs.getColumnIndex('exercise_name')),
      sets: rs.getLong(rs.getColumnIndex('sets')),
      reps: rs.getLong(rs.getColumnIndex('reps')),
      weightKg: rs.getDouble(rs.getColumnIndex('weight_kg')),
      durationMin: rs.getLong(rs.getColumnIndex('duration_min')),
      distanceKm: rs.getDouble(rs.getColumnIndex('distance_km')),
      incline: rs.getDouble(rs.getColumnIndex('incline')),
      speed: rs.getDouble(rs.getColumnIndex('speed')),
      sortOrder: rs.getLong(rs.getColumnIndex('sort_order')),
      setsJson: rs.getString(rs.getColumnIndex('sets_json')),
      groupTag: rs.getString(rs.getColumnIndex('group_tag'))
    };
    // 旧行自动迁移：sets_json 为空 = 单组（次数=sets、重量=weight_kg）
    if (w.setsJson.length === 0 && w.bodyPart !== '有氧' && (w.sets > 0 || w.weightKg > 0)) {
      const legacy: SetEntry[] = [{ reps: w.sets, weightKg: w.weightKg }];
      w.setsJson = JSON.stringify(legacy);
    }
    return w;
  }

  /** 某次打卡下的全部明细 */
  static async listByCheckIn(checkInId: number): Promise<WorkoutItem[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(Tables.WORKOUT_ITEM);
    predicates.equalTo('check_in_id', checkInId);
    predicates.orderByAsc('sort_order');
    const rs: relationalStore.ResultSet = await store.query(predicates, COLUMNS);
    const list: WorkoutItem[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(WorkoutRepository.fromResultSet(rs));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return list;
  }

  /** 某动作在指定日期之前最近一次的明细（含组列表），用于「上次对照」 */
  static async lastByName(exerciseName: string, beforeDate: string): Promise<WorkoutItem[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const sql: string =
      `SELECT w.* FROM ${Tables.WORKOUT_ITEM} w
        JOIN ${Tables.CHECK_IN} c ON c.id = w.check_in_id
       WHERE w.exercise_name = ? AND c.date < ?
       ORDER BY c.date DESC, w.sort_order ASC LIMIT 12`;
    const rs: relationalStore.ResultSet = await store.querySql(sql, [exerciseName, beforeDate]);
    const list: WorkoutItem[] = [];
    try {
      while (rs.goToNextRow()) {
        list.push(WorkoutRepository.fromResultSet(rs));
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return list;
  }

  /**
   * 覆盖式保存某次打卡的明细：先删后插，保证与界面上的列表一致。
   * @param checkInId 所属打卡 id
   * @param items 明细列表（id 字段会被忽略，由数据库重新分配）
   */
  static async replaceAll(checkInId: number, items: WorkoutItem[]): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    await store.executeSql(`DELETE FROM ${Tables.WORKOUT_ITEM} WHERE check_in_id = ?`, [checkInId]);
    for (let i = 0; i < items.length; i++) {
      const it: WorkoutItem = items[i];
      const values: relationalStore.ValuesBucket = {
        'check_in_id': checkInId,
        'body_part': it.bodyPart,
        'exercise_name': it.exerciseName,
        'sets': it.sets,
        'reps': it.reps,
        'weight_kg': it.weightKg,
        'duration_min': it.durationMin,
        'distance_km': it.distanceKm,
        'incline': it.incline,
        'speed': it.speed,
        'sort_order': i,
        'sets_json': it.setsJson,
        'group_tag': it.groupTag
      };
      await store.insert(Tables.WORKOUT_ITEM, values);
    }
  }

  /** 删除某次打卡的全部明细 */
  static async deleteByCheckIn(checkInId: number): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    await store.executeSql(`DELETE FROM ${Tables.WORKOUT_ITEM} WHERE check_in_id = ?`, [checkInId]);
  }

  /** 删除全部明细（仅导入恢复前使用） */
  static async deleteAll(): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    await store.executeSql(`DELETE FROM ${Tables.WORKOUT_ITEM}`);
  }

  /** 部位训练次数统计（最近 N 天内） */
  static async countByBodyPart(start: string, end: string): Promise<BodyPartCount[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const sql: string =
      `SELECT w.body_part AS body_part, COUNT(*) AS cnt
         FROM ${Tables.WORKOUT_ITEM} w
         JOIN ${Tables.CHECK_IN} c ON c.id = w.check_in_id
        WHERE c.date >= ? AND c.date <= ? AND w.body_part <> ''
        GROUP BY w.body_part
        ORDER BY cnt DESC`;
    const rs: relationalStore.ResultSet = await store.querySql(sql, [start, end]);
    const list: BodyPartCount[] = [];
    try {
      while (rs.goToNextRow()) {
        const item: BodyPartCount = {
          bodyPart: rs.getString(rs.getColumnIndex('body_part')),
          count: rs.getLong(rs.getColumnIndex('cnt'))
        };
        list.push(item);
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return list;
  }

  /**
   * 区间内按「动作」统计：练了多少次、总组数、有氧总时长。
   * 用于统计页展示「这段时间练了哪些动作、有氧多少」。
   */
  static async countByExercise(start: string, end: string): Promise<ExerciseCount[]> {
    const store: relationalStore.RdbStore = await DbHelper.getInstance().getStore();
    const sql: string =
      `SELECT w.exercise_name AS name, w.body_part AS part,
              COUNT(*) AS cnt,
              IFNULL(SUM(w.sets), 0) AS total_sets,
              IFNULL(SUM(w.duration_min), 0) AS dur
         FROM ${Tables.WORKOUT_ITEM} w
         JOIN ${Tables.CHECK_IN} c ON c.id = w.check_in_id
        WHERE c.date >= ? AND c.date <= ? AND w.exercise_name <> ''
        GROUP BY w.exercise_name, w.body_part
        ORDER BY cnt DESC, name ASC`;
    const rs: relationalStore.ResultSet = await store.querySql(sql, [start, end]);
    const list: ExerciseCount[] = [];
    try {
      while (rs.goToNextRow()) {
        const item: ExerciseCount = {
          exerciseName: rs.getString(rs.getColumnIndex('name')),
          bodyPart: rs.getString(rs.getColumnIndex('part')),
          count: rs.getLong(rs.getColumnIndex('cnt')),
          totalSets: rs.getLong(rs.getColumnIndex('total_sets')),
          durationMin: rs.getLong(rs.getColumnIndex('dur'))
        };
        list.push(item);
      }
    } finally {
      DbHelper.closeQuietly(rs);
    }
    return list;
  }
}
