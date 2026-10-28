/** 数据模型定义 */

/** 一次打卡（一天最多一条） */
export interface CheckIn {
  id: number;
  /** 'YYYY-MM-DD' */
  date: string;
  /** 打卡时刻时间戳(ms) */
  checkInAt: number;
  /** 训练时长（分钟） */
  durationMin: number;
  /** 感受 1-5，0 未填 */
  feeling: number;
  note: string;
  /** 训练部位，逗号分隔的规范部位名（肩部,腿部,背部,二头,胸部,三头,腹肌,有氧 的子集） */
  bodyParts: string;
  /** 是否补录 */
  isBackfill: boolean;
}

/** 一组训练（次数×重量）；力量动作用，有氧不用 */
export interface SetEntry {
  reps: number;
  weightKg: number;
}

/** 打卡下的一条训练明细 */
export interface WorkoutItem {
  id: number;
  checkInId: number;
  bodyPart: string;
  exerciseName: string;
  sets: number;
  reps: number;
  weightKg: number;
  durationMin: number;
  distanceKm: number;
  /** 有氧专用：坡度 */
  incline: number;
  /** 有氧专用：速度 */
  speed: number;
  sortOrder: number;
  /** 组列表 JSON（每组 次数×重量）；空串=旧行，读取时按一组推导 */
  setsJson: string;
  /** 超级组标记：'' | 'A' | 'B' …相邻同标记动作为一组循环 */
  groupTag: string;
}

/** 某个部位的训练次数 */
export interface BodyPartCount {
  bodyPart: string;
  count: number;
}

/** 某动作在区间内的统计（次数 / 总组数 / 有氧时长） */
export interface ExerciseCount {
  exerciseName: string;
  bodyPart: string;
  /** 该动作出现的次数（练习次数） */
  count: number;
  /** 总组数 */
  totalSets: number;
  /** 有氧动作的总时长（分钟） */
  durationMin: number;
}

/** 本周 / 本月 / 今年 的区间统计 */
export interface PeriodStats {
  /** 区间起始日期（含）'YYYY-MM-DD' */
  start: string;
  /** 区间结束日期（含，一般就是今天） */
  end: string;
  /** 区间显示名，如「本周」「本月」「今年」 */
  label: string;
  /** 区间日期范围显示，如「10.27 - 11.02」 */
  rangeLabel: string;
  /** 打卡天数 */
  checkInDays: number;
  /** 动作总次数（明细行数） */
  actionCount: number;
  /** 有氧次数 */
  cardioCount: number;
  /** 有氧总时长（分钟） */
  cardioDurationMin: number;
  /** 各动作统计，按次数降序 */
  exercises: ExerciseCount[];
}

/** 统计概览 */
export interface StatsSummary {
  totalCheckIns: number;
  weekCheckIns: number;
  monthCheckIns: number;
  /** 当前连续打卡天数 */
  currentStreak: number;
  /** 历史最长连续天数 */
  longestStreak: number;
  /** 累计训练时长（分钟） */
  totalDurationMin: number;
  /** 本月训练时长（分钟） */
  monthDurationMin: number;
  bodyPartCounts: BodyPartCount[];
}

/** 新建 CheckIn 用的构造参数 */
export interface CheckInDraft {
  date: string;
  durationMin: number;
  feeling: number;
  note: string;
  isBackfill: boolean;
}

export function emptyCheckIn(date: string): CheckIn {
  const c: CheckIn = {
    id: -1,
    date: date,
    checkInAt: 0,
    durationMin: 0,
    feeling: 0,
    note: '',
    bodyParts: '',
    isBackfill: false
  };
  return c;
}

export function emptyWorkoutItem(checkInId: number): WorkoutItem {
  const w: WorkoutItem = {
    id: -1,
    checkInId: checkInId,
    bodyPart: '',
    exerciseName: '',
    sets: 0,
    reps: 0,
    weightKg: 0,
    durationMin: 0,
    distanceKm: 0,
    incline: 0,
    speed: 0,
    sortOrder: 0,
    setsJson: '',
    groupTag: ''
  };
  return w;
}

/** 路由参数：告诉明细编辑页要编辑哪一天 */
export class EditParam {
  date: string;

  constructor(date: string) {
    this.date = date;
  }
}

