import { Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { HomeView } from '../view/HomeView';
import { CalendarView } from '../view/CalendarView';
import { RecordEditPage, RecordEditView } from '../view/RecordEditView';
import { ConfigManageView } from '../view/ConfigManageView';
import { DataManageView } from '../view/DataManageView';
import { StatsView } from '../view/StatsView';

/**
 * 应用主页面：底部 3 个 Tab（打卡 / 训练 / 日历）+ Navigation 路由栈。
 * 「训练」Tab 即当天训练编辑页；
 * 长按「打卡」Tab → 菜单（统计 / 数据管理 / 配置管理）。
 */
@Entry
@ComponentV2
struct Index {
  @Local currentIndex: number = 0;
  /** 长按「打卡」弹出的菜单是否显示 */
  @Local settingsOpen: boolean = false;
  private controller: TabsController = new TabsController();
  private pathStack: NavPathStack = new NavPathStack();

  /** 路由表：pushPathByName(name) 时渲染对应页面（NavDestination 为根） */
  @Builder
  pageMap(name: string) {
    if (name === 'RecordEdit') {
      RecordEditPage({ pathStack: this.pathStack })
    } else if (name === 'ConfigManage') {
      NavDestination() {
        Column() {
          Row() {
            Text('‹')
              .fontSize(26)
              .fontColor(Theme.TEXT_PRIMARY)
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.pathStack.pop();
              })
            Text('配置管理')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_PRIMARY)
              .layoutWeight(1)
            Row().width(44)
          }
          .width('100%')
          .padding({ top: 12, right: 16 })

          ConfigManageView()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.BG)
      }
      .hideTitleBar(true)
    } else if (name === 'Stats') {
      NavDestination() {
        Column() {
          Row() {
            Text('‹')
              .fontSize(26)
              .fontColor(Theme.TEXT_PRIMARY)
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.pathStack.pop();
              })
            Text('统计')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_PRIMARY)
              .layoutWeight(1)
            Row().width(44)
          }
          .width('100%')
          .padding({ top: 12, right: 16 })

          Column() {
            StatsView()
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.BG)
      }
      .hideTitleBar(true)
    } else if (name === 'DataManage') {
      NavDestination() {
        Column() {
          Row() {
            Text('‹')
              .fontSize(26)
              .fontColor(Theme.TEXT_PRIMARY)
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.pathStack.pop();
              })
            Text('数据管理')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.TEXT_PRIMARY)
              .layoutWeight(1)
            Row().width(44)
          }
          .width('100%')
          .padding({ top: 12, right: 16 })

          Column() {
            DataManageView()
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.BG)
      }
      .hideTitleBar(true)
    }
  }

  @Builder
  tabBar(title: string, index: number) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? Theme.PRIMARY : Theme.TEXT_SECONDARY)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 长按「打卡」Tab 弹出的菜单：统计 / 数据管理 / 配置管理 */
  @Builder
  actionMenu() {
    Column({ space: 4 }) {
      Row() {
        Text('统计')
          .fontSize(15)
          .fontColor(Theme.TEXT_PRIMARY)
        Blank()
        Text('›')
          .fontSize(18)
          .fontColor(Theme.TEXT_SECONDARY)
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .onClick(() => {
        this.settingsOpen = false;
        this.pathStack.pushPathByName('Stats', '');
      })

      Row() {
        Text('数据管理')
          .fontSize(15)
          .fontColor(Theme.TEXT_PRIMARY)
        Blank()
        Text('›')
          .fontSize(18)
          .fontColor(Theme.TEXT_SECONDARY)
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .onClick(() => {
        this.settingsOpen = false;
        this.pathStack.pushPathByName('DataManage', '');
      })

      Row() {
        Text('配置管理')
          .fontSize(15)
          .fontColor(Theme.TEXT_PRIMARY)
        Blank()
        Text('›')
          .fontSize(18)
          .fontColor(Theme.TEXT_SECONDARY)
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .onClick(() => {
        this.settingsOpen = false;
        this.pathStack.pushPathByName('ConfigManage', '');
      })
    }
    .width('100%')
    .padding({ top: 8, bottom: 12 })
    .backgroundColor('#FFFFFF')
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
          TabContent() {
            HomeView({ pathStack: this.pathStack })
          }
          .tabBar(this.tabBar('打卡', 0))

          TabContent() {
            RecordEditView({ pathStack: this.pathStack, showBack: false, forceToday: true })
          }
          .tabBar(this.tabBar('训练', 1))

          TabContent() {
            CalendarView({ pathStack: this.pathStack })
          }
          .tabBar(this.tabBar('日历', 2))
        }
        .barHeight(54)
        .barMode(BarMode.Fixed)
        .scrollable(false)
        .backgroundColor(Theme.BG)
        .onChange((index: number) => {
          this.currentIndex = index;
        })
        .width('100%')
        .height('100%')
        .onTabBarClick((index: number) => {
          // 已在日历页时再点「日历」→ 月/年 切换
          if (index === 2 && this.currentIndex === 2) {
            AppStore.get().toggleCalendarMode();
          }
        })

        // 长按「打卡」Tab（左 1/3 底部区域）→ 菜单（统计 / 数据管理 / 配置管理）；单击穿透给 Tab
        Row() {
          Column()
            .width('33%')
            .height(80)
            .hitTestBehavior(HitTestMode.Transparent)
            .gesture(LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                this.settingsOpen = true;
              }))
          Blank()
        }
        .width('100%')
        .height(80)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.settingsOpen, this.actionMenu(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Color.Transparent
      })
    }
    .navDestination(this.pageMap)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor(Theme.BG)
  }
}
