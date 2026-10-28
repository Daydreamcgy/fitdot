import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Constants, Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { StatsSummary } from '../model/Models';
import { StatsService } from '../service/StatsService';
import { formatDuration, pad2 } from '../utils/DateUtil';

const PREF_NAME: string = 'fit_dot_settings';
const KEY_REMINDER_ON: string = 'reminder_on';
const KEY_REMINDER_HOUR: string = 'reminder_hour';
const KEY_REMINDER_MINUTE: string = 'reminder_minute';
const KEY_REMINDER_ID: string = 'reminder_id';

/** 我的：每日提醒设置 + 数据概览 + 关于 */
@ComponentV2
export struct MineView {
  @Local store: AppStore = AppStore.get();
  @Local reminderOn: boolean = false;
  @Local hour: number = 20;
  @Local minute: number = 0;
  @Local reminderId: number = -1;
  @Local summary: StatsSummary | undefined = undefined;
  @Local errMsg: string = '';
  @Local tip: string = '';
  @Local busy: boolean = false;

  aboutToAppear(): void {
    this.loadSettings();
    this.reloadStats();
  }

  @Monitor('store.dataVersion')
  onDataVersionChange(monitor: IMonitor): void {
    this.reloadStats();
  }

  private async reloadStats(): Promise<void> {
    try {
      this.summary = await StatsService.loadSummary();
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `我的页统计失败: ${err.message}`);
    }
  }

  private context(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | undefined = AppStore.get().abilityContext;
    if (ctx === undefined) {
      throw new Error('应用上下文尚未就绪，请重开一次应用');
    }
    return ctx;
  }

  private async loadSettings(): Promise<void> {
    try {
      const options: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context(), options);
      this.reminderOn = await pref.get(KEY_REMINDER_ON, false) as boolean;
      this.hour = await pref.get(KEY_REMINDER_HOUR, 20) as number;
      this.minute = await pref.get(KEY_REMINDER_MINUTE, 0) as number;
      this.reminderId = await pref.get(KEY_REMINDER_ID, -1) as number;
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `读取设置失败: ${err.message}`);
    }
  }

  private async persistSettings(): Promise<void> {
    const options: preferences.Options = { name: PREF_NAME };
    const pref: preferences.Preferences = await preferences.getPreferences(this.context(), options);
    await pref.put(KEY_REMINDER_ON, this.reminderOn);
    await pref.put(KEY_REMINDER_HOUR, this.hour);
    await pref.put(KEY_REMINDER_MINUTE, this.minute);
    await pref.put(KEY_REMINDER_ID, this.reminderId);
    await pref.flush();
  }

  /** 先取消旧的，再按当前时间发布一条每天重复的闹钟型代理提醒 */
  private async applyReminder(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errMsg = '';
    this.tip = '';
    try {
      const ctx: common.UIAbilityContext = this.context();

      // 清掉旧的提醒，避免重复
      if (this.reminderId >= 0) {
        try {
          await reminderAgentManager.cancelReminder(this.reminderId);
        } catch (e) {
          Logger.warn(Constants.TAG, '取消旧提醒失败，忽略');
        }
        this.reminderId = -1;
      }

      if (!this.reminderOn) {
        await this.persistSettings();
        this.tip = '已关闭每日提醒';
        return;
      }

      // 申请通知权限（用户拒绝也不影响后续流程，只是通知可能不弹）
      try {
        await notificationManager.requestEnableNotification(ctx);
      } catch (e) {
        const ne = e as BusinessError;
        Logger.warn(Constants.TAG, `通知权限申请未通过 code=${ne.code}`);
      }

      const request: reminderAgentManager.ReminderRequestAlarm = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
        hour: this.hour,
        minute: this.minute,
        daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
        actionButton: [
          {
            title: '去打卡',
            type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
          }
        ],
        wantAgent: {
          pkgName: 'com.example.fitdot',
          abilityName: 'EntryAbility'
        },
        title: '该健身打卡啦',
        content: '今天还没有打卡，动起来？',
        notificationId: 1001,
        ringDuration: 3,
        snoozeTimes: 0,
        timeInterval: 0
      };

      this.reminderId = await reminderAgentManager.publishReminder(request);
      await this.persistSettings();
      this.tip = `已开启：每天 ${pad2(this.hour)}:${pad2(this.minute)} 提醒`;
      Logger.info(Constants.TAG, `提醒已发布 id=${this.reminderId}`);
    } catch (e) {
      const err = e as BusinessError;
      this.errMsg = `设置提醒失败：${err.message}`;
      Logger.error(Constants.TAG, `设置提醒失败 code=${err.code} message=${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  private changeHour(delta: number): void {
    let h: number = this.hour + delta;
    if (h < 0) {
      h = 23;
    }
    if (h > 23) {
      h = 0;
    }
    this.hour = h;
  }

  private changeMinute(delta: number): void {
    let m: number = this.minute + delta;
    if (m < 0) {
      m = 55;
    }
    if (m > 59) {
      m = 0;
    }
    this.minute = m;
  }

  @Builder
  reminderCard() {
    Column({ space: 14 }) {
      Row() {
        Column() {
          Text('每日提醒').fontSize(15).fontColor(Theme.TEXT_PRIMARY)
          Text('到点提醒你打卡').fontSize(12).fontColor(Theme.TEXT_SECONDARY).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.reminderOn })
          .selectedColor(Theme.PRIMARY)
          .onChange((isOn: boolean) => {
            this.reminderOn = isOn;
            this.applyReminder();
          })
      }
      .width('100%')

      if (this.reminderOn) {
        Row() {
          Text('小时').fontSize(14).fontColor(Theme.TEXT_PRIMARY)
          Blank()
          Text('−')
            .fontSize(20)
            .fontColor(Theme.PRIMARY)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor(Theme.PRIMARY_LIGHT)
            .onClick(() => {
              this.changeHour(-1);
            })
          Text(pad2(this.hour))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_PRIMARY)
            .width(56)
            .textAlign(TextAlign.Center)
          Text('+')
            .fontSize(20)
            .fontColor(Theme.PRIMARY)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor(Theme.PRIMARY_LIGHT)
            .onClick(() => {
              this.changeHour(1);
            })
        }
        .width('100%')

        Row() {
          Text('分钟').fontSize(14).fontColor(Theme.TEXT_PRIMARY)
          Blank()
          Text('−')
            .fontSize(20)
            .fontColor(Theme.PRIMARY)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor(Theme.PRIMARY_LIGHT)
            .onClick(() => {
              this.changeMinute(-5);
            })
          Text(pad2(this.minute))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_PRIMARY)
            .width(56)
            .textAlign(TextAlign.Center)
          Text('+')
            .fontSize(20)
            .fontColor(Theme.PRIMARY)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor(Theme.PRIMARY_LIGHT)
            .onClick(() => {
              this.changeMinute(5);
            })
        }
        .width('100%')

        Text(`当前设置：每天 ${pad2(this.hour)}:${pad2(this.minute)}`)
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')

        Button(this.busy ? '设置中…' : '应用提醒设置')
          .width('100%')
          .height(42)
          .backgroundColor(Theme.PRIMARY)
          .fontColor(Color.White)
          .onClick(() => {
            this.applyReminder();
          })
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
  }

  @Builder
  dataCard() {
    Column() {
      Text('我的数据').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.TEXT_PRIMARY)
        .width('100%')

      if (this.summary !== undefined) {
        Row() {
          Column() {
            Text(`${this.summary.totalCheckIns}`).fontSize(22).fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT_PRIMARY)
            Text('累计打卡').fontSize(12).fontColor(Theme.TEXT_SECONDARY).margin({ top: 2 })
          }
          .layoutWeight(1)

          Divider().vertical(true).height(30).color(Theme.DIVIDER)

          Column() {
            Text(`${this.summary.currentStreak}`).fontSize(22).fontWeight(FontWeight.Bold)
              .fontColor(Theme.TEXT_PRIMARY)
            Text('当前连续').fontSize(12).fontColor(Theme.TEXT_SECONDARY).margin({ top: 2 })
          }
          .layoutWeight(1)

          Divider().vertical(true).height(30).color(Theme.DIVIDER)

          Column() {
            Text(formatDuration(this.summary.totalDurationMin))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_PRIMARY)
            Text('累计时长').fontSize(12).fontColor(Theme.TEXT_SECONDARY).margin({ top: 4 })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 14 })
      }

      Text('所有数据都保存在本机应用沙箱（fit_dot.db），不上传、不需要登录。卸载应用会一并清除。')
        .fontSize(12)
        .fontColor(Theme.TEXT_SECONDARY)
        .width('100%')
        .margin({ top: 14 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  aboutCard() {
    Column({ space: 10 }) {
      Text('关于').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.TEXT_PRIMARY)
        .width('100%')

      Row() {
        Text('应用名称').fontSize(13).fontColor(Theme.TEXT_SECONDARY)
        Blank()
        Text('健身打卡').fontSize(13).fontColor(Theme.TEXT_PRIMARY)
      }
      .width('100%')

      Row() {
        Text('包名').fontSize(13).fontColor(Theme.TEXT_SECONDARY)
        Blank()
        Text('com.example.fitdot').fontSize(13).fontColor(Theme.TEXT_PRIMARY)
      }
      .width('100%')

      Row() {
        Text('版本').fontSize(13).fontColor(Theme.TEXT_SECONDARY)
        Blank()
        Text('1.0.0').fontSize(13).fontColor(Theme.TEXT_PRIMARY)
      }
      .width('100%')

      Row() {
        Text('开发基线').fontSize(13).fontColor(Theme.TEXT_SECONDARY)
        Blank()
        Text('HarmonyOS 7 / API 26').fontSize(13).fontColor(Theme.TEXT_PRIMARY)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('我的')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_PRIMARY)
          .width('100%')
          .padding({ top: 14, bottom: 4 })

        if (this.errMsg.length > 0) {
          Text(this.errMsg)
            .fontSize(13)
            .fontColor('#D93026')
            .width('100%')
            .padding(12)
            .borderRadius(10)
            .backgroundColor('#FDECEA')
        }

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(13)
            .fontColor(Theme.SUCCESS)
            .width('100%')
            .padding(12)
            .borderRadius(10)
            .backgroundColor('#E8F6EC')
        }

        this.reminderCard()
        this.dataCard()
        this.aboutCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}
