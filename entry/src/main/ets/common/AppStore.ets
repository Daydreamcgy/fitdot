/**
 * 应用级共享状态（状态管理 V2 写法）。
 *
 * 用途：跨页面通知「数据变了，请重新加载」。
 * 例：在明细编辑页保存后调用 markDirty()，首页监听到 dataVersion 变化即刷新。
 */
import { common } from '@kit.AbilityKit';

@ObservedV2
export class AppStore {
  private static inst: AppStore | undefined = undefined;

  static get(): AppStore {
    if (AppStore.inst === undefined) {
      AppStore.inst = new AppStore();
    }
    return AppStore.inst;
  }

  /** 数据版本号：每次写库 +1 */
  @Trace dataVersion: number = 0;
  /** 配置版本号：部位/动作/自重标记每次保存 +1，各页面监听后重读配置 */
  @Trace configVersion: number = 0;
  /** 日历页模式：0=月视图 1=年视图；由底部「日历」Tab 重复点按切换 */
  @Trace calendarMode: number = 0;

  toggleCalendarMode(): void {
    this.calendarMode = (this.calendarMode + 1) % 2;
  }

  /** 待编辑的日期，跳转编辑页前设置（不需要响应式） */
  editingDate: string = '';

  /** Ability 上下文，由 EntryAbility.onCreate 注入；数据库与 Preferences 都要用 */
  abilityContext: common.UIAbilityContext | undefined = undefined;

  /** 通知所有监听者重新加载数据 */
  markDirty(): void {
    this.dataVersion++;
  }

  /** 通知所有页面：配置变了，重新读配置 */
  markConfigDirty(): void {
    this.configVersion++;
  }
}

