import { BodyPart, Constants, Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { BodyPartCount, ExerciseCount, PeriodStats, StatsSummary } from '../model/Models';
import { StatsService } from '../service/StatsService';
import { formatDuration } from '../utils/DateUtil';

/**
 * 统计页：
 * 1. 区间视图（本周 / 本月 / 今年）：打卡天数、动作次数、有氧次数与时长、动作排行；
 * 2. 本月部位分布；
 * 3. 累计概览（累计打卡 / 连续天数 / 累计时长）。
 */
@ComponentV2
export struct StatsView {
  @Local store: AppStore = AppStore.get();
  @Local summary: StatsSummary | undefined = undefined;
  @Local period: PeriodStats | undefined = undefined;
  /** 0=本周 1=本月 2=今年 */
  @Local periodKind: number = 0;
  @Local loading: boolean = true;
  @Local periodLoading: boolean = false;
  @Local errMsg: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  @Monitor('store.dataVersion')
  onDataVersionChange(monitor: IMonitor): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.loading = true;
    this.errMsg = '';
    try {
      this.summary = await StatsService.loadSummary();
      this.period = await StatsService.loadPeriod(this.periodKind);
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `统计加载失败: ${err.message}`);
    } finally {
      this.loading = false;
    }
  }

  /** 只重算区间部分，切换本周/本月/今年时用 */
  private async reloadPeriod(kind: number): Promise<void> {
    this.periodKind = kind;
    this.periodLoading = true;
    try {
      this.period = await StatsService.loadPeriod(kind);
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `区间统计失败: ${err.message}`);
    } finally {
      this.periodLoading = false;
    }
  }

  /** 小时数（保留 1 位小数） */
  private hours(minutes: number): string {
    return (minutes / 60).toFixed(1);
  }

  /** 动作排行里最大的次数，用于条形长度 */
  private maxExerciseCount(): number {
    if (this.period === undefined || this.period.exercises.length === 0) {
      return 1;
    }
    return this.period.exercises[0].count;
  }

  /** 部位分布里的最大次数 */
  private maxPartCount(): number {
    if (this.summary === undefined || this.summary.bodyPartCounts.length === 0) {
      return 1;
    }
    return this.summary.bodyPartCounts[0].count;
  }

  // ==================== 通用小组件 ====================

  @Builder
  periodTab(label: string, kind: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.periodKind === kind ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.periodKind === kind ? Color.White : Theme.TEXT_PRIMARY)
      .backgroundColor(this.periodKind === kind ? Theme.PRIMARY : '#FFFFFF')
      .height(34)
      .padding({ left: 18, right: 18 })
      .borderRadius(17)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.reloadPeriod(kind);
      })
  }

  @Builder
  statCell(value: string, unit: string, label: string) {
    Column() {
      Row() {
        Text(value)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_PRIMARY)
        Text(unit)
          .fontSize(11)
          .fontColor(Theme.TEXT_SECONDARY)
          .margin({ left: 2, bottom: 3 })
      }
      .alignItems(VerticalAlign.Bottom)

      Text(label)
        .fontSize(11)
        .fontColor(Theme.TEXT_SECONDARY)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
  }

  // ==================== 区间视图 ====================

  @Builder
  periodSection() {
    Column({ space: 12 }) {
      // 本周 / 本月 / 今年
      Row({ space: 8 }) {
        this.periodTab('本周', 0)
        this.periodTab('本月', 1)
        this.periodTab('今年', 2)
        Blank()
      }
      .width('100%')

      if (this.period !== undefined) {
        Text(this.periodLoading ? '统计中…' : `${this.period.label} · ${this.period.rangeLabel}`)
          .fontSize(11)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')

        // 三个关键数字
        Row() {
          this.statCell(`${this.period.checkInDays}`, '天', '打卡')
          Divider().vertical(true).height(30).color(Theme.DIVIDER)
          this.statCell(`${this.period.actionCount}`, '次', '动作')
          Divider().vertical(true).height(30).color(Theme.DIVIDER)
          this.statCell(`${this.period.cardioCount}`, '次', '有氧')
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .borderRadius(16)
        .backgroundColor(Theme.CARD_BG)

        // 有氧卡
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Row()
              .width(10)
              .height(10)
              .borderRadius(5)
              .backgroundColor(BodyPart.colorOf(BodyPart.CARDIO))
            Text('有氧')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_PRIMARY)
            Blank()
            Text(`${this.period.cardioCount} 次`)
              .fontSize(13)
              .fontColor(Theme.TEXT_SECONDARY)
          }
          .width('100%')

          if (this.period.cardioCount > 0) {
            Row() {
              Text(`累计 ${formatDuration(this.period.cardioDurationMin)}`)
                .fontSize(12)
                .fontColor(Theme.TEXT_SECONDARY)
              Blank()
              Text(`约 ${this.hours(this.period.cardioDurationMin)} 小时`)
                .fontSize(12)
                .fontColor(Theme.TEXT_SECONDARY)
            }
            .width('100%')
          } else {
            Text(`${this.period.label}还没有有氧记录`)
              .fontSize(12)
              .fontColor(Theme.TEXT_SECONDARY)
              .width('100%')
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(Theme.CARD_BG)
        .alignItems(HorizontalAlign.Start)

        this.exerciseCard()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 动作排行：这段时间练了哪些动作、各多少次 */
  @Builder
  exerciseRow(item: ExerciseCount) {
    Column() {
      Row() {
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(BodyPart.colorOf(item.bodyPart))
        Text(item.exerciseName)
          .fontSize(13)
          .fontColor(Theme.TEXT_PRIMARY)
          .margin({ left: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(item.bodyPart)
          .fontSize(10)
          .fontColor(Theme.TEXT_SECONDARY)
          .margin({ right: 8 })
        Text(item.bodyPart === BodyPart.CARDIO
          ? `${item.count} 次 · ${item.durationMin} 分`
          : (item.totalSets > 0 ? `${item.count} 次 · ${item.totalSets} 组` : `${item.count} 次`))
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
      }
      .width('100%')

      Row() {
        Row()
          .height(6)
          .borderRadius(3)
          .backgroundColor(BodyPart.colorOf(item.bodyPart))
          .width(`${this.maxExerciseCount() > 0 ? Math.max(3, Math.round(item.count * 100 / this.maxExerciseCount())) : 3}%`)
      }
      .width('100%')
      .height(6)
      .borderRadius(3)
      .backgroundColor('#EEF0F3')
      .margin({ top: 7 })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  exerciseCard() {
    Column() {
      Row() {
        Text('动作排行')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_PRIMARY)
        Blank()
        if (this.period !== undefined && this.period.exercises.length > 0) {
          Text(`共 ${this.period.exercises.length} 个动作`)
            .fontSize(11)
            .fontColor(Theme.TEXT_SECONDARY)
        }
      }
      .width('100%')

      if (this.period !== undefined && this.period.exercises.length > 0) {
        ForEach(this.period.exercises, (item: ExerciseCount) => {
          this.exerciseRow(item)
        }, (item: ExerciseCount) => `${item.bodyPart}:${item.exerciseName}`)
      } else {
        Text(`${this.period !== undefined ? this.period.label : ''}还没有记录具体动作。打卡时记录「动作」就能看到排行。`)
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 12 })
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 本月部位分布 / 累计概览 ====================

  @Builder
  partRow(item: BodyPartCount, maxCount: number) {
    Column() {
      Row() {
        Row()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(BodyPart.colorOf(item.bodyPart))
        Text(item.bodyPart)
          .fontSize(13)
          .fontColor(Theme.TEXT_PRIMARY)
          .margin({ left: 8 })
        Blank()
        Text(`${item.count} 次`)
          .fontSize(13)
          .fontColor(Theme.TEXT_SECONDARY)
      }
      .width('100%')

      Row() {
        Row()
          .height(8)
          .borderRadius(4)
          .backgroundColor(BodyPart.colorOf(item.bodyPart))
          .width(`${maxCount > 0 ? Math.max(4, Math.round(item.count * 100 / maxCount)) : 4}%`)
      }
      .width('100%')
      .height(8)
      .borderRadius(4)
      .backgroundColor('#EEF0F3')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  bodyPartCard() {
    Column() {
      Text('本月训练部位分布')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_PRIMARY)
        .width('100%')

      if (this.summary !== undefined && this.summary.bodyPartCounts.length > 0) {
        ForEach(this.summary.bodyPartCounts, (item: BodyPartCount) => {
          this.partRow(item, this.maxPartCount())
        }, (item: BodyPartCount) => item.bodyPart)
      } else {
        Text('本月还没有记录具体动作。在打卡时记录「部位」就能看到分布了。')
          .fontSize(13)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 12 })
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  overviewCard() {
    Column() {
      Text('累计概览')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_PRIMARY)
        .width('100%')

      Row() {
        this.statCell(`${this.summary !== undefined ? this.summary.totalCheckIns : 0}`, '天', '累计打卡')
        Divider().vertical(true).height(30).color(Theme.DIVIDER)
        this.statCell(`${this.summary !== undefined ? this.summary.currentStreak : 0}`, '天', '当前连续')
        Divider().vertical(true).height(30).color(Theme.DIVIDER)
        this.statCell(`${this.summary !== undefined ? this.summary.longestStreak : 0}`, '天', '最长连续')
      }
      .width('100%')
      .margin({ top: 12 })

      if (this.summary !== undefined) {
        Text(`累计训练 ${this.hours(this.summary.totalDurationMin)} 小时 · 本月 ${this.hours(this.summary.monthDurationMin)} 小时`)
          .fontSize(11)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 12 })
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    if (this.loading) {
      Column() {
        LoadingProgress().width(44).height(44).color(Theme.PRIMARY)
        Text('正在统计…').fontSize(13).fontColor(Theme.TEXT_SECONDARY).margin({ top: 10 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: 12 }) {
          if (this.errMsg.length > 0) {
            Text(this.errMsg)
              .fontSize(13)
              .fontColor('#D93026')
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .backgroundColor('#FDECEA')
          }

          this.periodSection()

          if (this.summary !== undefined) {
            this.bodyPartCard()
            this.overviewCard()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
    }
  }
}
