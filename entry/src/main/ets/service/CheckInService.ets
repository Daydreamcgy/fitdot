import { CheckInRepository } from '../repository/CheckInRepository';
import { WorkoutRepository } from '../repository/WorkoutRepository';
import { DbHelper } from '../database/DbHelper';
import { AppStore } from '../common/AppStore';
import { CheckIn, CheckInDraft, WorkoutItem, emptyCheckIn } from '../model/Models';
import { todayStr } from '../utils/DateUtil';

/** 某一天的完整数据 */
export interface DayDetail {
  date: string;
  checked: boolean;
  checkIn: CheckIn;
  items: WorkoutItem[];
}

/** 打卡业务门面：界面只跟它打交道，不直接碰仓储 */
export class CheckInService {
  /** 读取某天的打卡与明细 */
  static async loadDay(date: string): Promise<DayDetail> {
    const checkIn: CheckIn | undefined = await CheckInRepository.getByDate(date);
    if (checkIn === undefined) {
      const detail: DayDetail = {
        date: date,
        checked: false,
        checkIn: emptyCheckIn(date),
        items: []
      };
      return detail;
    }
    const items: WorkoutItem[] = await WorkoutRepository.listByCheckIn(checkIn.id);
    const detail: DayDetail = {
      date: date,
      checked: true,
      checkIn: checkIn,
      items: items
    };
    return detail;
  }

  /** 一键打卡：今天。已打过则原样返回，不覆盖已有明细 */
  static async checkInToday(): Promise<CheckIn> {
    return CheckInService.checkIn(todayStr(), false);
  }

  /**
   * 打卡某一天
   * @param date 'YYYY-MM-DD'
   * @param isBackfill 是否补录
   */
  static async checkIn(date: string, isBackfill: boolean): Promise<CheckIn> {
    const existing: CheckIn | undefined = await CheckInRepository.getByDate(date);
    if (existing !== undefined) {
      return existing;
    }
    const draft: CheckInDraft = {
      date: date,
      durationMin: 0,
      feeling: 0,
      note: '',
      isBackfill: isBackfill
    };
    const saved: CheckIn = await CheckInRepository.save(draft);
    // 写库后立刻把 WAL 刷进主库文件，避免进程被杀后数据只剩在 WAL 里
    await DbHelper.flushAfterWrite();
    // 通知所有页面（日历等）刷新
    AppStore.get().markDirty();
    return saved;
  }

  /** 取消打卡，连同明细一起删掉 */
  static async cancel(date: string): Promise<void> {
    const existing: CheckIn | undefined = await CheckInRepository.getByDate(date);
    if (existing === undefined) {
      return;
    }
    await WorkoutRepository.deleteByCheckIn(existing.id);
    await CheckInRepository.deleteByDate(date);
    await DbHelper.flushAfterWrite();
    // 通知所有页面（日历等）刷新
    AppStore.get().markDirty();
  }

  /**
   * 保存某天的训练部位与动作明细。
   * 若尚未打卡，会先补一条打卡记录（时长/感受/备注写 0/0/''，历史日期自动算补录）。
   * @param date 'YYYY-MM-DD'
   * @param bodyParts 逗号分隔的规范部位名字符串，如 "胸部,三头"
   * @param items 动作明细列表
   * @param flush 是否刷盘；失焦自动保存传 false 省时，显式保存保持 true
   */
  static async saveDay(date: string, bodyParts: string, items: WorkoutItem[], flush: boolean = true): Promise<void> {
    let checkIn: CheckIn | undefined = await CheckInRepository.getByDate(date);
    if (checkIn === undefined) {
      const draft: CheckInDraft = {
        date: date,
        durationMin: 0,
        feeling: 0,
        note: '',
        isBackfill: date !== todayStr()
      };
      checkIn = await CheckInRepository.save(draft);
    }
    await CheckInRepository.updateBodyParts(date, bodyParts);
    await WorkoutRepository.replaceAll(checkIn.id, items);
    // 写库后立刻把 WAL 刷进主库文件，避免进程被杀后数据只剩在 WAL 里
    if (flush) {
      await DbHelper.flushAfterWrite();
    }
    // 通知所有页面（日历等）刷新
    AppStore.get().markDirty();
  }

  /** 是否已打卡 */
  static async isChecked(date: string): Promise<boolean> {
    return CheckInRepository.exists(date);
  }
}
