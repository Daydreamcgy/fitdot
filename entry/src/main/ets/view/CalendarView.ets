import { CheckInService } from '../service/CheckInService';
import { StatsService } from '../service/StatsService';
import { Constants, Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { EditParam } from '../model/Models';
import { CalendarCell, buildMonthMatrix, formatDate, todayStr, weekdayLabel } from '../utils/DateUtil';

const WEEK_NAMES: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const MONTH_NAMES: string[] = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
const ROW_IDX: number[] = [0, 1, 2, 3, 4, 5, 6];
/** 年视图每行两个星期（周一..周日 × 2） */
const YEAR_COLS: number = 14;
/** 年视图列头：一~日 ×2 */
const WEEK14: string[] = [...WEEK_NAMES, ...WEEK_NAMES];

/** 年视图的一个月：标签 + 按 14 列分行的日期矩阵，'' 为占位 */
interface YearBlock {
  label: string;
  rows: string[][];
}

/** 未打卡格子的灰底 */
const EMPTY_CELL: string = '#EDF0F4';
/** 未来日期的更浅灰底（不可打卡） */
const FUTURE_CELL: string = '#F7F8FA';
/** 年度热力图未打卡的灰点 */
const EMPTY_DOT: string = '#E7EBF1';

/**
 * 打卡日历。
 *
 * 月视图：一个月历网格，每天是一枚圆角方块——有记录的亮起主题色，没有的是灰色；
 *   点按任意日期进入当天训练页；长按未打卡的日期补打卡。
 *   网格高度固定 6 行，切换月份时卡片高度不变。
 * 年视图：GitHub 风格热力图，横向 53 周、纵向周一到周日，整年铺在一页；
 *   点按打开当天记录，长按弹出当天练了什么。
 */
@ComponentV2
export struct CalendarView {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local store: AppStore = AppStore.get();
  /** 0=月视图 1=年视图 */
  @Local mode: number = 0;
  @Local year: number = new Date().getFullYear();
  @Local month0: number = new Date().getMonth();
  @Local cells: CalendarCell[] = [];
  @Local monthSet: Set<string> = new Set<string>();
  @Local yearSet: Set<string> = new Set<string>();
  /** 年视图：全年日期连成一条流，每行 14 天（两周），不按月切割 */
  @Local yearRows: string[][] = [];
  @Local today: string = todayStr();
  @Local yearCount: number = 0;
  @Local yearLongest: number = 0;
  /** 年视图长按弹出的日期与内容（固定高度槽位，避免布局跳动） */
  @Local detailDate: string = '';
  @Local detailText: string = '';
  /** 已经加载过年集合的年份，避免切月份时重复查全年 */
  private loadedYear: number = -1;
  private partsMap: Map<string, string> = new Map<string, string>();
  private detailTimerId: number = -1;
  @Local loading: boolean = true;
  @Local errMsg: string = '';
  @Local busy: boolean = false;
  /** 切月/切年的滑动动画状态 */
  @Local slideX: number = 0;
  @Local slideOpacity: number = 1;
  private slideTimerId: number = -1;

  aboutToAppear(): void {
    this.mode = this.store.calendarMode;
    this.load();
    this.ensureMonthSet(this.year, this.month0);
    if (this.month0 > 0) {
      this.ensureMonthSet(this.year, this.month0 - 1);
    }
    if (this.month0 < 11) {
      this.ensureMonthSet(this.year, this.month0 + 1);
    }
  }

  @Monitor('store.calendarMode')
  onCalendarModeChange(monitor: IMonitor): void {
    this.mode = this.store.calendarMode;
    this.clearDetailTimer();
    this.detailDate = '';
    this.detailText = '';
  }

  aboutToDisappear(): void {
    this.clearDetailTimer();
  }

  @Monitor('store.dataVersion')
  onDataVersionChange(monitor: IMonitor): void {
    this.today = todayStr();
    // 数据有变：强制重载年视图缓存（partsMap/年打卡集合），否则气泡显示旧部位
    this.loadedYear = -1;
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errMsg = '';
    try {
      this.cells = buildMonthMatrix(this.year, this.month0);
      const month: Set<string> = await StatsService.loadMonthChecked(this.year, this.month0);
      this.monthSet = month;
      this.monthSetCache.set(this.year * 12 + this.month0, month);
      this.monthSetCache = new Map<number, Set<string>>(this.monthSetCache);
      if (this.loadedYear !== this.year) {
        const year: Set<string> = await StatsService.loadYearChecked(this.year);
        this.yearSet = year;
        this.yearCount = this.setSize(year);
        this.yearLongest = this.calcLongest(year);
        this.yearRows = this.buildYearRows();
        this.partsMap = await StatsService.loadYearPartsMap(this.year);
        this.loadedYear = this.year;
      }
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `日历加载失败: ${err.message}`);
    } finally {
      this.loading = false;
    }
  }

  private setSize(set: Set<string>): number {
    let n: number = 0;
    set.forEach((value: string) => {
      n++;
    });
    return n;
  }

  private calcLongest(set: Set<string>): number {
    const list: string[] = [];
    set.forEach((value: string) => {
      list.push(value);
    });
    list.sort();
    return StatsService.calcLongestStreak(list);
  }

  /** 年视图：全年日期连排，每行 14 天；按 1月1日实际周几留空位，每天落在正确的星期列 */
  private buildYearRows(): string[][] {
    const rows: string[][] = [];
    const start: number = new Date(this.year, 0, 1).getTime();
    const end: number = new Date(this.year + 1, 0, 1).getTime();
    const total: number = Math.round((end - start) / 86400000);
    const offset: number = (new Date(this.year, 0, 1).getDay() + 6) % 7;
    const cells: string[] = [];
    for (let i = 0; i < offset; i++) {
      cells.push('');
    }
    for (let d = 1; d <= total; d++) {
      cells.push(formatDate(new Date(this.year, 0, d)));
    }
    while (cells.length % YEAR_COLS !== 0) {
      cells.push('');
    }
    for (let r = 0; r < cells.length / YEAR_COLS; r++) {
      rows.push(cells.slice(r * YEAR_COLS, (r + 1) * YEAR_COLS));
    }
    return rows;
  }

  private prevMonth(): void {
    if (this.month0 === 0) {
      this.year = this.year - 1;
      this.month0 = 11;
    } else {
      this.month0 = this.month0 - 1;
    }
  }

  private nextMonth(): void {
    if (this.month0 === 11) {
      this.year = this.year + 1;
      this.month0 = 0;
    } else {
      this.month0 = this.month0 + 1;
    }
  }

  private prevYear(): void {
    this.year = this.year - 1;
  }

  private nextYear(): void {
    this.year = this.year + 1;
  }

  /** 双面板无缝滑动：B 板为进入侧的相邻月，动画时与 A 板成一条长带 */
  @Local panelBCells: CalendarCell[] = [];
  @Local panelBSet: Set<string> = new Set<string>();
  @Local panelBVisible: boolean = false;

  private navBusy: boolean = false;
  private lastDir: number = 1;

  private onNavPrev(): void {
    this.onNav(-1);
  }

  /** 双击标题：跳回今天所在月份/年份 */
  private jumpToToday(): void {
    const now: Date = new Date();
    this.today = todayStr();
    this.year = now.getFullYear();
    if (this.mode === 0) {
      const tm: number = now.getMonth();
      this.ensureMonthSet(this.year, tm);
      this.ensureMonthSet(this.year, Math.max(0, tm - 1));
      this.ensureMonthSet(this.year, Math.min(11, tm + 1));
      this.swiperController.changeIndex(tm, true);
    } else {
      this.load();
    }
  }

  private onNavNext(): void {
    this.onNav(1);
  }

  /** 无缝滑动：B 板（相邻月）预加载 → A、B 两板成带一起滑 → B 转正 */
  private async onNav(dir: number): Promise<void> {
    if (this.navBusy) {
      return;
    }
    this.navBusy = true;
    this.lastDir = dir;
    if (this.mode === 1) {
      // 年视图：两段式（年数据量大，暂不做双面板）
      await this.animateSlideTo(-dir * 380, 220);
      this.slideX = dir * 380;
      if (dir > 0) {
        this.nextYear();
      } else {
        this.prevYear();
      }
      await this.load();
      await this.animateSlideTo(0, 260);
      this.navBusy = false;
      return;
    }
    // 月视图：交给 Swiper 原生翻页（跟手、可悬停、吸附）
    let ty: number = this.year;
    let tm: number = this.month0 + dir;
    if (tm < 0) {
      ty = ty - 1;
      tm = 11;
    } else if (tm > 11) {
      ty = ty + 1;
      tm = 0;
    }
    this.year = ty;
    this.swiperController.changeIndex(tm, true);
    this.navBusy = false;
  }

  /** 从当前 slideX 补间到目标值（16ms 一帧，缓入缓出） */
  private animateSlideTo(targetX: number, duration: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      if (this.slideTimerId >= 0) {
        clearInterval(this.slideTimerId);
        this.slideTimerId = -1;
      }
      const fromX: number = this.slideX;
      const start: number = Date.now();
      this.slideTimerId = setInterval(() => {
        const t: number = Math.min(1, (Date.now() - start) / duration);
        const ease: number = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
        this.slideX = fromX + (targetX - fromX) * ease;
        if (t >= 1) {
          clearInterval(this.slideTimerId);
          this.slideTimerId = -1;
          this.slideX = targetX;
          resolve();
        }
      }, 16);
    });
  }

  private switchMode(mode: number): void {
    if (this.mode === mode) {
      return;
    }
    this.mode = mode;
  }

  private title(): string {
    if (this.mode === 0) {
      return `${this.year} 年 ${this.month0 + 1} 月`;
    }
    return `${this.year} 年`;
  }

  private openEditor(date: string): void {
    AppStore.get().editingDate = date;
    this.pathStack.pushPathByName('RecordEdit', new EditParam(date));
  }

  /** 该日期是否在未来（不能打卡） */
  private isFuture(date: string): boolean {
    return date.length === 10 && date > this.today;
  }

  /** 点按某天：进入当天训练页（不再直接点亮打卡） */
  private onDayTap(cell: CalendarCell): void {
    if (cell.day === 0 || !cell.inMonth || this.isFuture(cell.date)) {
      return;
    }
    this.openEditor(cell.date);
  }

  /** 长按某天：未打卡 → 补打卡；已打卡 → 看当天记录 */
  private onDayLongPress(cell: CalendarCell): void {
    if (cell.day === 0 || !cell.inMonth || this.isFuture(cell.date)) {
      return;
    }
    if (this.monthSet.has(cell.date)) {
      this.openEditor(cell.date);
      return;
    }
    this.backfill(cell.date);
  }

  /** 补打卡：非今天时标记为补录 */
  private async backfill(date: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await CheckInService.checkIn(date, date !== this.today);
      // 触发所有页面（含本页）按 dataVersion 刷新
      AppStore.get().markDirty();
      // 再主动刷一次，确保本页立即反映补打卡结果
      await this.load();
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `补打卡失败 ${date}: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  // ==================== 年视图辅助 ====================

  private yearDotColor(date: string): ResourceColor {
    if (date.length === 0) {
      return Color.Transparent;
    }
    if (this.yearSet.has(date)) {
      return Theme.PRIMARY;
    }
    if (date === this.today) {
      return '#C9D6EA';
    }
    return EMPTY_DOT;
  }

  private clearDetailTimer(): void {
    if (this.detailTimerId >= 0) {
      clearTimeout(this.detailTimerId);
      this.detailTimerId = -1;
    }
  }

  /** 年视图长按：弹出当天练了什么，3 秒后自动收起 */
  private showYearDetail(date: string): void {
    if (date.length === 0) {
      return;
    }
    const raw: string | undefined = this.partsMap.get(date);
    let text: string = '未记录训练部位';
    if (raw !== undefined && raw.length > 0) {
      text = raw.split(',').join(' · ');
    }
    this.detailDate = `${date} 周${weekdayLabel(date)}`;
    this.detailText = text;
    this.clearDetailTimer();
    this.detailTimerId = setTimeout(() => {
      this.detailDate = '';
      this.detailText = '';
      this.detailTimerId = -1;
    }, 3000);
  }

  // ==================== UI ====================

  /** 月/年 切换：固定在页面顶部、不随内容滚动，切视图时位置不变 */
  @Builder
  modeSwitch() {
    Row() {
      Row() {
        Text('月')
          .fontSize(13)
          .fontColor(this.mode === 0 ? Color.White : Theme.TEXT_SECONDARY)
      }
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .height(26)
      .borderRadius(13)
      .backgroundColor(this.mode === 0 ? Theme.PRIMARY : Color.Transparent)
      .onClick(() => {
        this.switchMode(0);
      })

      Row() {
        Text('年')
          .fontSize(13)
          .fontColor(this.mode === 1 ? Color.White : Theme.TEXT_SECONDARY)
      }
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .height(26)
      .borderRadius(13)
      .backgroundColor(this.mode === 1 ? Theme.PRIMARY : Color.Transparent)
      .onClick(() => {
        this.switchMode(1);
      })
    }
    .width(104)
    .height(30)
    .padding(2)
    .borderRadius(15)
    .backgroundColor('#E9EDF2')
  }

  /** 月份/年份导航：‹ 标题 › 居中一组，箭头与标题垂直对齐 */
  @Builder
  headerBar() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.mode === 1) {
        Text(`打卡 ${this.yearCount} 天`)
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.End)
          .padding({ right: 10 })
      }
      Row({ space: 2 }) {
        Text('‹')
          .fontSize(22)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(30)
          .height(24)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 4 })
          .onClick(() => {
            this.onNavPrev();
          })

        Text(this.title())
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_PRIMARY)
          .gesture(
            TapGesture({ count: 2 })
              .onAction(() => {
                this.jumpToToday();
              })
          )

        Text('›')
          .fontSize(22)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(30)
          .height(24)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 4 })
          .onClick(() => {
            this.onNavNext();
          })
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ top: 26, bottom: 26 })
  }

  /** B 板：相邻月的整页（星期头 + 网格），动画期间与 A 板成一条长带 */
  @Builder
  panelBPage() {
    Column() {
      this.weekHeader()
      Grid() {
        ForEach(this.panelBCells, (cell: CalendarCell, index: number) => {
          GridItem() {
            Column() {
              Text(cell.day > 0 ? `${cell.day}` : '')
                .fontSize(14)
                .fontWeight(this.panelBSet.has(cell.date) ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.panelBSet.has(cell.date) ? Color.White : Theme.TEXT_PRIMARY)
            }
            .width('100%')
            .height(50)
            .justifyContent(FlexAlign.Center)
            .borderRadius(12)
            .backgroundColor(this.panelBCellBg(cell))
            .opacity(cell.day === 0 ? 0 : 1)
          }
        }, (cell: CalendarCell, index: number) => `b${index}-${cell.date}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
      .columnsGap(3)
      .rowsGap(3)
      .height(315)
      .width('100%')
    }
    .width('100%')
  }

  private panelBCellBg(cell: CalendarCell): ResourceColor {
    if (this.panelBSet.has(cell.date)) {
      return Theme.PRIMARY;
    }
    if (cell.isToday) {
      return '#C9D6EA';
    }
    if (this.isFuture(cell.date)) {
      return FUTURE_CELL;
    }
    return EMPTY_CELL;
  }

  private swiperController: SwiperController = new SwiperController();
  /** 每月打卡集合缓存：key = year*12+month0；更新时整表替换以触发渲染 */
  @Local monthSetCache: Map<number, Set<string>> = new Map<number, Set<string>>();

  /** 某月网格：纯行列布局（不用 Grid，避免其滚动手势抢走 Swiper 的横向拖动） */
  @Builder
  monthPage(m: number) {
    Column({ space: 3 }) {
      this.weekHeader()
      ForEach(this.monthRowsOf(m), (row: CalendarCell[]) => {
        Row({ space: 3 }) {
          ForEach(row, (cell: CalendarCell) => {
            Column() {
              Text(cell.day > 0 ? `${cell.day}` : '')
                .fontSize(14)
                .fontWeight(this.setFor(m).has(cell.date) ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.setFor(m).has(cell.date) ? Color.White : Theme.TEXT_PRIMARY)
            }
            .layoutWeight(1)
            .aspectRatio(1)
            .justifyContent(FlexAlign.Center)
            .borderRadius(12)
            .backgroundColor(this.pageCellBg(m, cell))
            .opacity(cell.day === 0 ? 0 : 1)
            .onClick(() => {
              this.onPageDayTap(m, cell);
            })
            .gesture(
              LongPressGesture({ duration: 500 })
                .onAction(() => {
                  this.onDayLongPress(cell);
                })
            )
          }, (cell: CalendarCell, index: number) => `${m}-${index}-${cell.date}`)
        }
        .width('100%')
      }, (row: CalendarCell[], r: number) => `${m}-r${r}`)
    }
    .width('100%')
  }

  private monthRowsOf(m: number): CalendarCell[][] {
    const cells: CalendarCell[] = this.cellsFor(m);
    const rows: CalendarCell[][] = [];
    for (let r = 0; r < 6; r++) {
      rows.push(cells.slice(r * 7, r * 7 + 7));
    }
    return rows;
  }

  private cellsFor(m: number): CalendarCell[] {
    return buildMonthMatrix(this.year, m);
  }

  private static readonly EMPTY_SET: Set<string> = new Set<string>();

  private setFor(m: number): Set<string> {
    const s: Set<string> | undefined = this.monthSetCache.get(this.year * 12 + m);
    return s !== undefined ? s : CalendarView.EMPTY_SET;
  }

  private async ensureMonthSet(y: number, m: number): Promise<void> {
    const key: number = y * 12 + m;
    if (this.monthSetCache.has(key)) {
      return;
    }
    try {
      const s: Set<string> = await StatsService.loadMonthChecked(y, m);
      this.monthSetCache.set(key, s);
      this.monthSetCache = new Map<number, Set<string>>(this.monthSetCache);
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `月数据加载失败: ${err.message}`);
    }
  }

  /** Swiper 落页：更新当前月并预加载相邻月 */
  private onMonthSwiped(idx: number): void {
    this.month0 = idx;
    this.ensureMonthSet(this.year, idx);
    if (idx > 0) {
      this.ensureMonthSet(this.year, idx - 1);
    }
    if (idx < 11) {
      this.ensureMonthSet(this.year, idx + 1);
    }
  }

  private onPageDayTap(m: number, cell: CalendarCell): void {
    if (cell.day === 0 || this.isFuture(cell.date)) {
      return;
    }
    this.openEditor(cell.date);
  }

  private pageCellBg(m: number, cell: CalendarCell): ResourceColor {
    if (this.setFor(m).has(cell.date)) {
      return Theme.PRIMARY;
    }
    if (cell.isToday) {
      return '#C9D6EA';
    }
    if (this.isFuture(cell.date)) {
      return FUTURE_CELL;
    }
    return EMPTY_CELL;
  }

  /** 左右滑动切月/切年（与竖向滚动手势按方向区分，不冲突） */
  private swipeGesture() {
    return PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
      .onActionEnd((event: GestureEvent) => {
        if (event.offsetX < 0) {
          this.onNavNext();
        } else {
          this.onNavPrev();
        }
      });
  }

  @Builder
  weekHeader() {
    Row() {
      ForEach(WEEK_NAMES, (name: string) => {
        Text(name)
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
      }, (name: string) => name)
    }
    .width('100%')
    .padding({ bottom: 6 })
  }

  /** 月视图：圆角方块日历（高度固定 6 行，切月时卡片高度不变） */
  @Builder
  monthGrid() {
    Grid() {
      ForEach(this.cells, (cell: CalendarCell, index: number) => {
        GridItem() {
          Column() {
            Text(cell.day > 0 ? `${cell.day}` : '')
              .fontSize(14)
              .fontWeight(this.monthSet.has(cell.date) ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.dayFontColor(cell))
          }
          .width('100%')
          .height(50)
          .justifyContent(FlexAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.dayBackground(cell))
          .opacity(cell.day === 0 ? 0 : 1)
          .onClick(() => {
            this.onDayTap(cell);
          })
          .gesture(
            LongPressGesture({ duration: 500 })
              .onAction(() => {
                this.onDayLongPress(cell);
              })
          )
        }
      }, (cell: CalendarCell, index: number) => `${index}-${cell.date}`)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(3)
    .rowsGap(3)
    .height(315)
    .width('100%')
  }

  /** 年视图某一天的格子：点按或长按弹出当天练了什么（滚动区域内长按常被手势竞争吃掉，点按为主） */
  @Builder
  yearCell(date: string) {
    Column()
      .layoutWeight(1)
      .aspectRatio(1)
      .borderRadius(4)
      .backgroundColor(this.yearDotColor(date))
      .onClick(() => {
        this.showYearDetail(date);
      })
      .parallelGesture(
        LongPressGesture({ duration: 500 })
          .onAction(() => {
            this.showYearDetail(date);
          })
      )
  }

  /** 年视图：全年连排大方块直接铺在页面背景上；左侧月份标签等距分布，仅作示意 */
  @Builder
  yearGrid() {
    Row() {
      Column() {
        ForEach(MONTH_NAMES, (name: string) => {
          Text(name)
            .fontSize(10)
            .fontColor(Theme.TEXT_SECONDARY)
        }, (name: string) => name)
      }
      .width(32)
      .alignSelf(ItemAlign.Stretch)
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Start)
      // 顶部让 1月对齐第一行方块，底部让 12月提到倒数第二行，中间等距
      .padding({ top: 18, bottom: 46 })

      Column({ space: 2 }) {
        // 列头：一~日 ×2，与方块列对齐
        Row({ space: 2 }) {
          ForEach(WEEK14, (name: string) => {
            Text(name)
              .fontSize(9)
              .fontColor(Theme.TEXT_SECONDARY)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
          }, (name: string, idx: number) => `${idx}-${name}`)
        }
        .width('100%')

        ForEach(this.yearRows, (row: string[]) => {
          Row({ space: 2 }) {
            ForEach(row, (date: string) => {
              this.yearCell(date)
            }, (date: string, idx: number) => (date.length > 0 ? date : `pad-${idx}`))
          }
          .width('100%')
        }, (row: string[], r: number) => `row${r}-${row[0]}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 年视图长按弹出的当天内容（固定高度，不引起布局跳动） */
  @Builder
  detailSlot() {
    Row() {
      if (this.detailDate.length > 0) {
        Row() {
          Text(`${this.detailDate} · ${this.detailText}`)
            .fontSize(12)
            .fontColor(Theme.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 12, right: 12 })
        .height(28)
        .borderRadius(14)
        .backgroundColor('#EDF0F4')
      }
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          this.headerBar()

          if (this.errMsg.length > 0) {
            Text(this.errMsg)
              .fontSize(13)
              .fontColor('#D93026')
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .backgroundColor('#FDECEA')
              .margin({ bottom: 8 })
          }

          if (this.mode === 0) {
            Column() {
              Swiper(this.swiperController) {
                ForEach(MONTH_NAMES, (name: string, m: number) => {
                  Column() {
                    this.monthPage(m)
                  }
                  .width('100%')
                }, (name: string, m: number) => `m${m}`)
              }
              .index(this.month0)
              .loop(false)
              .indicator(false)
              .duration(300)
              .height(340)
              .onChange((idx: number) => {
                this.onMonthSwiped(idx);
              })
            }
            .width('100%')
          } else {
            // 年视图：不要白底卡片，大方块直接铺在页面背景上；气泡浮层不占位
            Stack({ alignContent: Alignment.Top }) {
              Column() {
                this.yearGrid()
              }
              .width('100%')
              this.detailSlot()
            }
            .width('100%')
            .translate({ x: this.slideX })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  private dayBackground(cell: CalendarCell): ResourceColor {
    if (this.monthSet.has(cell.date)) {
      return Theme.PRIMARY;
    }
    // 当天未打卡：用与年视图一致的灰蓝标注，不再加小圆点
    if (cell.isToday) {
      return '#C9D6EA';
    }
    if (this.isFuture(cell.date)) {
      return FUTURE_CELL;
    }
    return EMPTY_CELL;
  }

  private dayFontColor(cell: CalendarCell): ResourceColor {
    if (this.monthSet.has(cell.date)) {
      return Color.White;
    }
    if (this.isFuture(cell.date)) {
      return '#C3CAD4';
    }
    return Theme.TEXT_PRIMARY;
  }
}
