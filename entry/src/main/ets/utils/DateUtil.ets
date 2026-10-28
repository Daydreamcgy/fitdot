/** 日期工具：全程使用本地时区的 'YYYY-MM-DD' 字符串作为「一天」的键 */

export function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** Date -> 'YYYY-MM-DD' */
export function formatDate(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** 今天 */
export function todayStr(): string {
  return formatDate(new Date());
}

/** 'YYYY-MM-DD' -> Date（本地零点） */
export function parseDate(s: string): Date {
  const parts: string[] = s.split('-');
  const y: number = Number.parseInt(parts[0], 10);
  const m: number = Number.parseInt(parts[1], 10);
  const d: number = Number.parseInt(parts[2], 10);
  return new Date(y, m - 1, d);
}

/** 日期加减天数 */
export function addDays(dateStr: string, delta: number): string {
  const d: Date = parseDate(dateStr);
  d.setDate(d.getDate() + delta);
  return formatDate(d);
}

/** to - from 的天数差 */
export function diffDays(from: string, to: string): number {
  const a: number = parseDate(from).getTime();
  const b: number = parseDate(to).getTime();
  return Math.round((b - a) / 86400000);
}

/** 是否同一天 */
export function isSameDay(a: string, b: string): boolean {
  return a === b;
}

/** 星期几（中文单字），'2026-10-10' -> '六' */
export function weekdayLabel(dateStr: string): string {
  const names: string[] = ['日', '一', '二', '三', '四', '五', '六'];
  return names[parseDate(dateStr).getDay()];
}

/** 'YYYY-MM' 月份键 */
export function monthKey(dateStr: string): string {
  return dateStr.substring(0, 7);
}

/** 把分钟格式化成「1小时20分」 */
export function formatDuration(minutes: number): string {
  if (minutes <= 0) {
    return '0 分钟';
  }
  const h: number = Math.floor(minutes / 60);
  const m: number = minutes % 60;
  if (h === 0) {
    return `${m} 分钟`;
  }
  if (m === 0) {
    return `${h} 小时`;
  }
  return `${h} 小时 ${m} 分`;
}

/** 日历单元格 */
export interface CalendarCell {
  /** 'YYYY-MM-DD'，空串表示占位空格 */
  date: string;
  /** 日号，0 表示占位 */
  day: number;
  /** 是否本月 */
  inMonth: boolean;
  /** 是否今天 */
  isToday: boolean;
}

/**
 * 生成月历矩阵（周一为一周起点），长度补齐到 7 的整数倍。
 * @param year 年
 * @param month0 月，0 表示 1 月
 */
export function buildMonthMatrix(year: number, month0: number): CalendarCell[] {
  const cells: CalendarCell[] = [];
  const first: Date = new Date(year, month0, 1);
  // getDay(): 0=周日，这里换算成「周一为 0」
  const offset: number = (first.getDay() + 6) % 7;
  const daysInMonth: number = new Date(year, month0 + 1, 0).getDate();
  const today: string = todayStr();

  for (let i = 0; i < offset; i++) {
    const blank: CalendarCell = { date: '', day: 0, inMonth: false, isToday: false };
    cells.push(blank);
  }
  for (let d = 1; d <= daysInMonth; d++) {
    const ds: string = formatDate(new Date(year, month0, d));
    const cell: CalendarCell = { date: ds, day: d, inMonth: true, isToday: ds === today };
    cells.push(cell);
  }
  while (cells.length % 7 !== 0) {
    const blank: CalendarCell = { date: '', day: 0, inMonth: false, isToday: false };
    cells.push(blank);
  }
  return cells;
}

/** 本月第一天 */
export function firstDayOfMonth(year: number, month0: number): string {
  return formatDate(new Date(year, month0, 1));
}

/** 本月最后一天 */
export function lastDayOfMonth(year: number, month0: number): string {
  return formatDate(new Date(year, month0 + 1, 0));
}

/** 本周一（以周一为一周开始） */
export function mondayOfWeek(dateStr: string): string {
  const d: Date = parseDate(dateStr);
  const offset: number = (d.getDay() + 6) % 7;
  d.setDate(d.getDate() - offset);
  return formatDate(d);
}
