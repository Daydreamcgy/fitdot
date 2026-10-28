import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { DbHelper } from '../database/DbHelper';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(Constants.TAG, 'Ability onCreate');
    // 把上下文交给 AppStore，页面里需要 Context 的地方（Preferences、通知等）从这里取
    AppStore.get().abilityContext = this.context;
    // 提前把数据库建好，页面首次加载时就不用手动等待
    DbHelper.getInstance().init(this.context).catch((e: Error) => {
      Logger.error(Constants.TAG, `数据库初始化失败: ${e.message}`);
    });
  }

  onDestroy(): void {
    Logger.info(Constants.TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(Constants.TAG, 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(Constants.TAG, `加载首页失败: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info(Constants.TAG, '首页加载成功');
    });
  }

  onWindowStageDestroy(): void {
    Logger.info(Constants.TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info(Constants.TAG, 'Ability onForeground');
  }

  onBackground(): void {
    Logger.info(Constants.TAG, 'Ability onBackground');
  }
}
