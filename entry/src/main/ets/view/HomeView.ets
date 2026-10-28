import { vibrator } from '@kit.SensorServiceKit';
import { Constants, Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { EditParam } from '../model/Models';
import { CheckInService, DayDetail } from '../service/CheckInService';
import { DataImporter } from '../service/DataImporter';
import { todayStr } from '../utils/DateUtil';

/** 长按打卡需要持续按住的时长（毫秒） */
const HOLD_DURATION_MS: number = 1000;
/** 长按进度的刷新间隔（毫秒），约 30fps */
const HOLD_TICK_MS: number = 8;
/** 按住过程中每隔多少进度给一次轻震（0.2 = 每 200ms 一下） */
const HOLD_VIBRATE_STEP: number = 0.2;
/** 提前松手时进度回弹的时长（毫秒） */
const RELEASE_MS: number = 150;
/** 打卡成功后庆祝动画时长（毫秒） */
const CELEBRATE_MS: number = 900;

/** 未打卡时按钮的灰蓝色 */
const RESTING_COLOR: string = '#9FB0C7';
/** 未打卡时按钮上的字色（近白） */
const RESTING_TEXT_COLOR: string = '#F4F7FA';

/** 打卡成功时爆出来的 emoji，按顺序循环取用 */
const CELEBRATION_EMOJIS: string[] = [
  '🎉', '🥳', '🎊', '✨', '⭐️', '🌟', '👏',
  '💯', '🥇', '😄', '❤️', '🙌', '🏆', '🔥', '🎉'
];

function hexToRgb(color: string): number[] {
  const s: string = color.replace('#', '');
  return [
    parseInt(s.substring(0, 2), 16),
    parseInt(s.substring(2, 4), 16),
    parseInt(s.substring(4, 6), 16)
  ];
}

function toHex(value: number): string {
  const h: string = Math.max(0, Math.min(255, Math.round(value))).toString(16);
  return h.length === 1 ? `0${h}` : h;
}

/** 在两个 #RRGGBB 颜色之间线性插值 */
function mixColor(from: string, to: string, t: number): string {
  const a: number[] = hexToRgb(from);
  const b: number[] = hexToRgb(to);
  return `#${toHex(a[0] + (b[0] - a[0]) * t)}${toHex(a[1] + (b[1] - a[1]) * t)}${toHex(a[2] + (b[2] - a[2]) * t)}`;
}

/** 一枚从天而降的庆祝 emoji：重力下落，碰到圆钮会弹开（拟物碰撞），随后消逝 */
class BurstEmoji {
  id: number = 0;
  emoji: string = '';
  /** 位置（相对按钮中心，vp） */
  px: number = 0;
  py: number = 0;
  /** 速度（vp/s） */
  vx: number = 0;
  vy: number = 0;
  /** 出场延迟（秒，错落下落） */
  delay: number = 0;
  size: number = 26;
  spin: number = 0;
  /** 是否已碰过圆钮 */
  bounced: boolean = false;
  /** 开始消逝的时刻（秒，-1 表示未开始） */
  fadeStart: number = -1;

  constructor(id: number, emoji: string, px: number, py: number, vx: number, vy: number, delay: number, size: number, spin: number) {
    this.id = id;
    this.emoji = emoji;
    this.px = px;
    this.py = py;
    this.vx = vx;
    this.vy = vy;
    this.delay = delay;
    this.size = size;
    this.spin = spin;
  }
}

/**
 * 首页：极简打卡。
 *
 * 整页只有一枚 DOTS 圆钮：
 * - 未打卡：灰蓝色圆，长按 1 秒完成打卡，外圈进度环随按住时长走满；
 * - 打卡成功：圆与圆环一起变成主题色 #4176e6，并爆出 emoji 庆祝；
 * - 双击圆钮：进入当日训练记录（记录页里可取消今日打卡）。
 */
@ComponentV2
export struct HomeView {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local store: AppStore = AppStore.get();
  @Local today: string = todayStr();
  @Local checked: boolean = false;
  @Local loading: boolean = true;
  @Local errMsg: string = '';
  @Local busy: boolean = false;

  /** 手指是否按在按钮上 */
  @Local pressing: boolean = false;
  /** 长按进度 0~1（松手回弹时递减） */
  @Local progress: number = 0;
  /** 成功后的颜色过渡：0=灰蓝，1=主题色 */
  @Local successBlend: number = 0;
  /** 正在爆开的 emoji 列表 */
  @Local burstItems: BurstEmoji[] = [];
  /** 爆开动画进度 0~1 */
  @Local burstProgress: number = 0;
  /** 粒子模拟时钟（秒）：每帧递增以驱动重渲染 */
  @Local burstTick: number = 0;
  /** 庆祝轮次：让 ForEach key 每轮不同，避免节点复用旧透明度 */
  private burstRound: number = 0;
  /** 上一次圆钮抬起的时刻（自管双击检测） */
  private lastTapUpAt: number = 0;

  private holdTimerId: number = -1;
  private holdStartAt: number = 0;
  private vibrateStep: number = 0;
  private releasing: boolean = false;
  private releaseStartAt: number = 0;
  private releaseFrom: number = 0;
  private burstTimerId: number = -1;
  private burstStartAt: number = 0;

  aboutToAppear(): void {
    // 一次性历史数据导入（内部有标记，只会真正执行一次）
    DataImporter.maybeImport();
    this.reload();
  }

  aboutToDisappear(): void {
    this.clearHoldTimer();
    this.clearBurstTimer();
  }

  /** 任何页面写库后 AppStore.dataVersion 会变，这里自动刷新 */
  @Monitor('store.dataVersion')
  onDataVersionChange(monitor: IMonitor): void {
    this.today = todayStr();
    this.reload();
  }

  private async reload(): Promise<void> {
    this.loading = true;
    this.errMsg = '';
    try {
      const detail: DayDetail = await CheckInService.loadDay(this.today);
      this.checked = detail.checked;
      this.successBlend = detail.checked ? 1 : 0;
      if (!detail.checked) {
        // 未打卡时长按进度必须归零，否则圆环会残留上一轮的满环
        this.progress = 0;
      }
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `首页加载失败: ${err.message}`);
    } finally {
      this.loading = false;
    }
  }

  private async doCheckIn(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await CheckInService.checkInToday();
      await this.reload();
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      // 写库失败则把颜色和圆环都退回去
      this.progress = 0;
      this.successBlend = 0;
      Logger.error(Constants.TAG, `打卡失败: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  private openEditor(date: string): void {
    AppStore.get().editingDate = date;
    this.pathStack.pushPathByName('RecordEdit', new EditParam(date));
  }

  // ==================== 长按打卡 ====================

  /** 指尖按下：开始计时并给出第一下触感（已打卡时也可长按，纯解压） */
  private startHold(): void {
    if (this.busy || this.loading) {
      return;
    }
    this.holdStartAt = Date.now();
    this.vibrateStep = 0;
    this.releasing = false;
    this.pressing = true;
    if (this.progress > 0.05) {
      this.progress = 0;
    }
    this.clearHoldTimer();
    this.holdTimerId = setInterval(() => this.onHoldTick(), HOLD_TICK_MS);
    this.vibrateTime(28);
  }

  private onHoldTick(): void {
    if (this.releasing) {
      // 松手回弹：进度平滑退回 0
      const rp: number = Math.min(1, (Date.now() - this.releaseStartAt) / RELEASE_MS);
      this.progress = this.releaseFrom * (1 - rp);
      if (rp >= 1) {
        this.progress = 0;
        this.pressing = false;
        this.clearHoldTimer();
      }
      return;
    }

    const elapsed: number = Date.now() - this.holdStartAt;
    const p: number = Math.min(1, elapsed / HOLD_DURATION_MS);
    this.progress = p;
    if (p >= (this.vibrateStep + 1) * HOLD_VIBRATE_STEP) {
      this.vibrateStep += 1;
      this.vibrateTime(16);
    }
    if (p >= 1) {
      this.pressing = false;
      this.clearHoldTimer();
      this.completeCheckIn();
    }
  }

  /** 手指提前松开 / 被系统手势打断：平滑回弹 */
  private cancelHold(): void {
    if (this.holdTimerId < 0 || this.progress >= 1) {
      return;
    }
    this.releasing = true;
    this.releaseStartAt = Date.now();
    this.releaseFrom = this.progress;
  }

  private clearHoldTimer(): void {
    if (this.holdTimerId >= 0) {
      clearInterval(this.holdTimerId);
      this.holdTimerId = -1;
    }
  }

  private onButtonTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.startHold();
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.cancelHold();
    }
  }

  /** 长按满 1 秒：成功触感 + emoji 爆开；未打卡才真正写库，已打卡纯解压 */
  private completeCheckIn(): void {
    if (this.busy) {
      return;
    }
    this.progress = 1;
    this.vibrateSuccess();
    this.startSuccessFx();
    if (!this.checked) {
      this.doCheckIn();
    }
  }

  // ==================== 震动 ====================

  private vibrateTime(durationMs: number): void {
    vibrator.startVibration({ type: 'time', duration: durationMs }, { usage: 'touch' })
      .catch((err: Error) => {
        Logger.warn(Constants.TAG, `震动失败: ${err.message}`);
      });
  }

  /** 打卡成功的预置触感，设备不支持时退回普通震动 */
  private vibrateSuccess(): void {
    vibrator.startVibration({
      type: 'preset',
      effectId: vibrator.HapticFeedback.EFFECT_NOTICE_SUCCESS,
      count: 1
    }, { usage: 'touch' })
      .catch(() => {
        this.vibrateTime(180);
      });
  }

  // ==================== 庆祝动画（逐帧驱动，不依赖全局动画） ====================

  /** 打卡成功的视觉反馈：驱动变色与圆环弹动（不再爆 emoji） */
  private startSuccessFx(): void {
    this.burstProgress = 0;
    this.burstTick = 0;
    this.clearBurstTimer();
    this.burstStartAt = Date.now();
    this.burstTimerId = setInterval(() => {
      const p: number = Math.min(1, (Date.now() - this.burstStartAt) / CELEBRATE_MS);
      this.burstProgress = p;
      this.successBlend = Math.min(1, p * 3);
      this.burstTick = p * (CELEBRATE_MS / 1000);
      if (p >= 1) {
        this.clearBurstTimer();
      }
    }, HOLD_TICK_MS);
  }

  private onBurstTick(): void {
    const elapsed: number = (Date.now() - this.burstStartAt) / 1000;
    const p: number = Math.min(1, elapsed * 1000 / CELEBRATE_MS);
    this.burstProgress = p;
    // 颜色在爆开的前 ~0.7s 内从灰蓝过渡到主题色
    this.successBlend = Math.min(1, p * 6);
    this.burstTick = elapsed;
    const dt: number = HOLD_TICK_MS / 1000;
    let anyAlive: boolean = false;
    for (const e of this.burstItems) {
      if (elapsed < e.delay) {
        anyAlive = true;
        continue;
      }
      if (e.fadeStart >= 0 && elapsed - e.fadeStart > 3.1) {
        continue;
      }
      // 轻重力 + 限速：下落段近似匀速，弹起后被轻柔拉回，不会飞上天
      e.vy = Math.min(e.vy + 380 * dt, 620);
      e.px = e.px + e.vx * dt;
      e.py = e.py + e.vy * dt;
      // 拟物碰撞：emoji 边缘碰到圆环即按法线弹开并损耗能量
      const cr: number = 127 + e.size / 2;
      const dist: number = Math.sqrt(e.px * e.px + e.py * e.py);
      if (dist < cr && dist > 0.001) {
        const nx: number = e.px / dist;
        const ny: number = e.py / dist;
        const dot: number = e.vx * nx + e.vy * ny;
        e.vx = (e.vx - 2 * dot * nx) * 0.4 + (Math.random() * 60 - 30);
        e.vy = (e.vy - 2 * dot * ny) * 0.4;
        e.px = nx * (cr + 2);
        e.py = ny * (cr + 2);
        e.bounced = true;
      }
      // 卡在环上的兜底：庆祝时限一过强制开始消逝，保证动画必然收场
      if (p >= 1 && e.fadeStart < 0) {
        e.fadeStart = elapsed;
      }
      const settled: boolean = e.bounced && Math.abs(e.vy) < 90 && e.py > -70;
      const gone: boolean = e.py > 330;
      if ((settled || gone) && e.fadeStart < 0) {
        e.fadeStart = elapsed;
      }
      anyAlive = true;
    }
    if (!anyAlive) {
      this.clearBurstTimer();
      this.burstItems = [];
      this.burstTick = 0;
    }
  }

  private clearBurstTimer(): void {
    if (this.burstTimerId >= 0) {
      clearInterval(this.burstTimerId);
      this.burstTimerId = -1;
    }
  }

  // ==================== 视觉参数 ====================

  /** 下落位置：轻微左右摆动增加飘感 */
  private burstX(e: BurstEmoji): number {
    return e.px + Math.sin(this.burstTick * 5 + e.id) * 6;
  }

  private burstY(e: BurstEmoji): number {
    return e.py;
  }

  private burstScale(e: BurstEmoji): number {
    return 0.85 + 0.3 * Math.min(1, this.burstTick / 0.5);
  }

  private burstSpin(e: BurstEmoji): number {
    return e.spin * Math.min(1, this.burstTick / 0.9);
  }

  /** 弹开/落定后缓慢消逝（约 2s） */
  private burstFade(e: BurstEmoji): number {
    if (e.fadeStart < 0) {
      return 1;
    }
    return Math.max(0, 1 - (this.burstTick - e.fadeStart) / 3);
  }

  private congratsOpacity(): number {
    return 0;
  }

  private congratsScale(): number {
    return 1;
  }

  /** 圆环弹动：阻尼全振荡，起步快、轻微回缩、落定（约 220ms） */
  private ringPop(): number {
    const t: number = Math.min(1, this.burstTick / 0.22);
    return 1 + 0.06 * Math.sin(t * Math.PI * 2) * (1 - t * 0.6);
  }

  /** 圆钮颜色：灰蓝 → 主题色 */
  private circleColor(): string {
    return mixColor(RESTING_COLOR, Theme.PRIMARY, this.successBlend);
  }

  /** 按下的轻微缩放 */
  private buttonScale(): number {
    return 1 - 0.05 * Math.min(1, this.progress * 5);
  }

  /** 圆环只在长按过程中和打卡完成后出现 */
  private ringValue(): number {
    if (this.checked || this.successBlend > 0) {
      return 100;
    }
    return Math.round(this.progress * 100);
  }

  private ringOpacity(): number {
    if (this.checked || this.successBlend > 0) {
      return 1;
    }
    return this.progress > 0 ? 1 : 0;
  }

  /** 圆心文字：未打卡提示长按，长按中提示松开取消，打卡成功显示打卡成功 */
  private centerLabel(): string {
    if (this.checked) {
      return '打卡成功';
    }
    if (this.pressing) {
      return '松开取消';
    }
    return '长按打卡';
  }

  private hintText(): string {
    if (this.checked) {
      return '';
    }
    if (this.pressing) {
      return '松开取消';
    }
    return '长按打卡';
  }

  // ==================== UI ====================

  @Builder
  mainButton() {
    Stack() {
      // 常驻灰环：未打卡时也显示，长按时被蓝色进度环覆盖
      Progress({ value: 100, total: 100, type: ProgressType.Ring })
        .width(244)
        .height(244)
        .color('#DDE3EC')
        .style({ strokeWidth: 10 })
        .scale({ x: this.ringPop(), y: this.ringPop() })

      // 外圈进度环：打卡完成后与圆一起变成主题色
      Progress({ value: this.ringValue(), total: 100, type: ProgressType.Ring })
        .width(244)
        .height(244)
        .color(Theme.PRIMARY)
        .style({ strokeWidth: 10 })
        .opacity(this.ringOpacity())
        .scale({ x: this.ringPop(), y: this.ringPop() })

      Column() {
        Text(this.centerLabel())
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.checked ? Color.White : RESTING_TEXT_COLOR)
          .letterSpacing(4)
      }
      .justifyContent(FlexAlign.Center)
      .width(216)
      .height(216)
      .borderRadius(108)
      .backgroundColor(this.circleColor())
      .shadow({
        radius: this.pressing ? 26 : 20,
        color: '#264176e6',
        offsetY: 10
      })
      .scale({ x: this.buttonScale(), y: this.buttonScale() })
      .onTouch((event: TouchEvent) => {
        this.onButtonTouch(event);
      })
    }
  }

  @Builder
  hintBar() {
    Column() {
      if (this.errMsg.length > 0) {
        Text(this.errMsg)
          .fontSize(12)
          .fontColor('#D93026')
      } else {
        Text(this.hintText())
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .opacity(0.9)
      }
    }
    .width('100%')
    .offset({ x: 0, y: 152 })
  }

  /** emoji 爆开层：不参与命中测试，纯展示 */
  @Builder
  burstLayer() {
    Stack() {
      ForEach(this.burstItems, (e: BurstEmoji) => {
        Text(e.emoji)
          .fontSize(e.size)
          .translate({ x: this.burstX(e), y: this.burstY(e) })
          .rotate({ angle: this.burstSpin(e) })
          .scale({ x: this.burstScale(e), y: this.burstScale(e) })
          .opacity(this.burstFade(e))
      }, (e: BurstEmoji) => `${this.burstRound}-${e.id}`)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack() {
      this.mainButton()
    }
    .width('100%')
    .height('100%')
  }
}
