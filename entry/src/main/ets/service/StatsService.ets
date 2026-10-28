import { CheckInRepository } from '../repository/CheckInRepository';
import { WorkoutRepository } from '../repository/WorkoutRepository';
import { addDays, diffDays, firstDayOfMonth, lastDayOfMonth, mondayOfWeek, todayStr } from '../utils/DateUtil';
import { BodyPartCount, CheckIn, ExerciseCount, PeriodStats, StatsSummary } from '../model/Models';

/** 统计计算 */
export class StatsService {
  /** 当前连续打卡天数：今天没打则从昨天往前算（今天还没结束，不算断签） */
  static calcCurrentStreak(sortedDates: string[], today: string): number {
    const set: Set<string> = new Set<string>();
    for (const d of sortedDates) {
      set.add(d);
    }
    let cursor: string = today;
    if (!set.has(cursor)) {
      cursor = addDays(cursor, -1);
      if (!set.has(cursor)) {
        return 0;
      }
    }
    let streak: number = 0;
    while (set.has(cursor)) {
      streak++;
      cursor = addDays(cursor, -1);
    }
    return streak;
  }

  /** 历史最长连续天数 */
  static calcLongestStreak(sortedDates: string[]): number {
    if (sortedDates.length === 0) {
      return 0;
    }
    let longest: number = 1;
    let current: number = 1;
    for (let i = 1; i < sortedDates.length; i++) {
      const gapDays: number = diffDays(sortedDates[i - 1], sortedDates[i]);
      if (gapDays === 1) {
        current++;
      } else {
        current = 1;
      }
      if (current > longest) {
        longest = current;
      }
    }
    return longest;
  }

  /** 汇总统计 */
  static async loadSummary(): Promise<StatsSummary> {
    const today: string = todayStr();
    const dates: string[] = await CheckInRepository.listAllDates(); // 升序

    const monthStart: string = today.substring(0, 7) + '-01';
    const monday: string = mondayOfWeek(today);

    let weekCheckIns: number = 0;
    let monthCheckIns: number = 0;
    for (const d of dates) {
      if (d >= monday && d <= today) {
        weekCheckIns++;
      }
      if (d >= monthStart && d <= today) {
        monthCheckIns++;
      }
    }

    const totalDurationMin: number = await CheckInRepository.sumDuration();
    const monthEnd: string = lastDayOfMonth(
      Number.parseInt(today.substring(0, 4), 10),
      Number.parseInt(today.substring(5, 7), 10) - 1
    );
    const monthDurationMin: number = await CheckInRepository.sumDurationBetween(monthStart, monthEnd);
    const bodyPartCounts: BodyPartCount[] = await WorkoutRepository.countByBodyPart(monthStart, monthEnd);

    const summary: StatsSummary = {
      totalCheckIns: dates.length,
      weekCheckIns: weekCheckIns,
      monthCheckIns: monthCheckIns,
      currentStreak: StatsService.calcCurrentStreak(dates, today),
      longestStreak: StatsService.calcLongestStreak(dates),
      totalDurationMin: totalDurationMin,
      monthDurationMin: monthDurationMin,
      bodyPartCounts: bodyPartCounts
    };
    return summary;
  }

  /**
   * 本周 / 本月 / 今年的训练统计。
   * @param period 0=本周 1=本月 2=今年
   */
  static async loadPeriod(period: number): Promise<PeriodStats> {
    const today: string = todayStr();
    const year: number = Number.parseInt(today.substring(0, 4), 10);
    let start: string = '';
    let label: string = '';
    if (period === 0) {
      start = mondayOfWeek(today);
      label = '本周';
    } else if (period === 1) {
      start = `${today.substring(0, 7)}-01`;
      label = '本月';
    } else {
      start = `${year}-01-01`;
      label = '今年';
    }
    const end: string = today;

    const checkInDays: number = await CheckInRepository.countBetween(start, end);
    const exercises: ExerciseCount[] = await WorkoutRepository.countByExercise(start, end);
    let actionCount: number = 0;
    let cardioCount: number = 0;
    let cardioDurationMin: number = 0;
    for (const e of exercises) {
      actionCount += e.count;
      if (e.bodyPart === '有氧') {
        cardioCount += e.count;
        cardioDurationMin += e.durationMin;
      }
    }

    const stats: PeriodStats = {
      start: start,
      end: end,
      label: label,
      rangeLabel: `${StatsService.shortDate(start)} - ${StatsService.shortDate(end)}`,
      checkInDays: checkInDays,
      actionCount: actionCount,
      cardioCount: cardioCount,
      cardioDurationMin: cardioDurationMin,
      exercises: exercises
    };
    return stats;
  }

  /** 'YYYY-MM-DD' -> 'M.D'，用于区间显示 */
  static shortDate(date: string): string {
    const m: number = Number.parseInt(date.substring(5, 7), 10);
    const d: number = Number.parseInt(date.substring(8, 10), 10);
    return `${m}.${d}`;
  }

  /** 取某月的打卡日期集合，供日历打点 */
  static async loadMonthChecked(year: number, month0: number): Promise<Set<string>> {
    const start: string = firstDayOfMonth(year, month0);
    const end: string = lastDayOfMonth(year, month0);
    const dates: string[] = await CheckInRepository.listDatesBetween(start, end);
    const set: Set<string> = new Set<string>();
    for (const d of dates) {
      set.add(d);
    }
    return set;
  }

  /** 取某整年的打卡日期集合，供年度热力图 */
  static async loadYearChecked(year: number): Promise<Set<string>> {
    const dates: string[] = await CheckInRepository.listDatesBetween(`${year}-01-01`, `${year}-12-31`);
    const set: Set<string> = new Set<string>();
    for (const d of dates) {
      set.add(d);
    }
    return set;
  }

  /**
   * 某年每天练了什么（'YYYY-MM-DD' -> '肩部,腿部'，无部位时退回 note），
   * 供年视图长按查看当天训练内容
   */
  static async loadYearPartsMap(year: number): Promise<Map<string, string>> {
    const list: CheckIn[] = await CheckInRepository.listAll();
    const map: Map<string, string> = new Map<string, string>();
    for (const c of list) {
      if (!c.date.startsWith(`${year}-`)) {
        continue;
      }
      const text: string = c.bodyParts.length > 0 ? c.bodyParts : c.note;
      map.set(c.date, text);
    }
    return map;
  }
}
