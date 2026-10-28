import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';

/** 可配置的训练部位与动作清单（配置管理的数据模型） */
export interface MoveGroup {
  part: string;
  moves: string[];
}

/** 一次读取的完整配置：部位/动作清单 + 自重动作清单 */
export interface AppConfig {
  groups: MoveGroup[];
  bodyweight: string[];
}

const PREF_NAME: string = 'fitdot_config';
const KEY_GROUPS: string = 'move_groups';
const KEY_BODYWEIGHT: string = 'bodyweight_moves';

/**
 * 默认按「自重」记录的动作：记录时不填重量，只填次数。
 * 以后加负重了，去「配置管理」把它的「自重」标签点成「负重」即可，无需改代码。
 */
export const DEFAULT_BODYWEIGHT_MOVES: string[] = ['引体向上', '双杠臂屈伸', '悬垂举腿', '卧姿抬腿卷腹'];

/** 出厂默认配置（与初版预设一致） */
export function defaultGroups(): MoveGroup[] {
  return [
    { part: '肩部', moves: ['哑铃飞鸟', '哑铃推肩', 'Y字侧平举', '杠铃实力推', '蝴蝶机练肩后束'] },
    { part: '腿部', moves: ['保加利亚深蹲', '哈克机深蹲', '髋内收', '髋外展', '腿弯举', '腿屈伸'] },
    { part: '背部', moves: ['引体向上', '高位下拉', '坐姿划船'] },
    { part: '二头', moves: ['哑铃二头弯举'] },
    { part: '胸部', moves: ['杠铃卧推', '史密斯杠铃上斜卧推', '哑铃上斜卧推', '双杠臂屈伸'] },
    { part: '三头', moves: ['双杠臂屈伸', '碎颅者', '绳索臂屈伸'] },
    { part: '腹肌', moves: ['悬垂举腿', '卧姿抬腿卷腹'] },
    { part: '有氧', moves: ['爬坡'] }
  ];
}

/** 配置读写服务：部位/动作清单、自重动作清单都持久化在 Preferences（JSON 字符串） */
export class ConfigService {
  private static store: preferences.Preferences | undefined = undefined;
  private static cache: MoveGroup[] = [];
  private static bodyweightCache: string[] | undefined = undefined;

  private static async open(context: Context): Promise<preferences.Preferences> {
    if (ConfigService.store === undefined) {
      ConfigService.store = await preferences.getPreferences(context, PREF_NAME);
    }
    return ConfigService.store;
  }

  /** 读取配置；首次使用返回出厂默认 */
  static async load(context: Context): Promise<MoveGroup[]> {
    if (ConfigService.cache.length > 0) {
      return ConfigService.cache;
    }
    try {
      const store: preferences.Preferences = await ConfigService.open(context);
      const raw: string = (await store.get(KEY_GROUPS, '')) as string;
      if (raw.length > 0) {
        ConfigService.cache = JSON.parse(raw) as MoveGroup[];
      } else {
        ConfigService.cache = defaultGroups();
      }
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `配置读取失败: ${err.message}`);
      ConfigService.cache = defaultGroups();
    }
    return ConfigService.cache;
  }

  /** 保存配置 */
  static async save(context: Context, groups: MoveGroup[]): Promise<void> {
    ConfigService.cache = groups;
    try {
      const store: preferences.Preferences = await ConfigService.open(context);
      await store.put(KEY_GROUPS, JSON.stringify(groups));
      await store.flush();
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `配置保存失败: ${err.message}`);
    }
  }

  /**
   * 读取「自重动作」清单。
   * 没有存过（首次使用 / 老版本升级上来）时返回出厂默认，
   * 所以老用户升级后这四个动作会直接按自重记录，不用手动配置。
   */
  static async loadBodyweight(context: Context): Promise<string[]> {
    if (ConfigService.bodyweightCache !== undefined) {
      return ConfigService.bodyweightCache;
    }
    try {
      const store: preferences.Preferences = await ConfigService.open(context);
      const raw: string = (await store.get(KEY_BODYWEIGHT, '')) as string;
      if (raw.length > 0) {
        ConfigService.bodyweightCache = JSON.parse(raw) as string[];
      } else {
        ConfigService.bodyweightCache = DEFAULT_BODYWEIGHT_MOVES.slice();
      }
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `自重动作配置读取失败: ${err.message}`);
      ConfigService.bodyweightCache = DEFAULT_BODYWEIGHT_MOVES.slice();
    }
    return ConfigService.bodyweightCache;
  }

  /** 保存「自重动作」清单 */
  static async saveBodyweight(context: Context, list: string[]): Promise<void> {
    ConfigService.bodyweightCache = list;
    try {
      const store: preferences.Preferences = await ConfigService.open(context);
      await store.put(KEY_BODYWEIGHT, JSON.stringify(list));
      await store.flush();
    } catch (e) {
      const err = e as Error;
      Logger.error(Constants.TAG, `自重动作配置保存失败: ${err.message}`);
    }
  }

  /** 一次读全：动作清单 + 自重动作清单 */
  static async loadConfig(context: Context): Promise<AppConfig> {
    const groups: MoveGroup[] = await ConfigService.load(context);
    const bodyweight: string[] = await ConfigService.loadBodyweight(context);
    return { groups: groups, bodyweight: bodyweight };
  }

  /** 重置缓存（下次 load 重新读盘） */
  static resetCache(): void {
    ConfigService.cache = [];
    ConfigService.bodyweightCache = undefined;
  }
}
