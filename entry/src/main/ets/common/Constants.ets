/** 全局常量与枚举型常量（ArkTS 里用静态只读字段比 enum 更省心） */
export class Constants {
  static readonly TAG: string = 'FitDot';
  static readonly DB_NAME: string = 'fit_dot.db';
  static readonly DB_VERSION: number = 4;
}

/** 表名 */
export class Tables {
  static readonly CHECK_IN: string = 'check_in';
  static readonly WORKOUT_ITEM: string = 'workout_item';
}

/** 训练部位 */
export class BodyPart {
  static readonly CHEST: string = '胸';
  static readonly BACK: string = '背';
  static readonly LEG: string = '腿';
  static readonly SHOULDER: string = '肩';
  static readonly ARM: string = '手臂';
  static readonly CORE: string = '核心';
  static readonly CARDIO: string = '有氧';
  static readonly OTHER: string = '其他';

  static readonly ALL: string[] = [
    BodyPart.CHEST, BodyPart.BACK, BodyPart.LEG, BodyPart.SHOULDER,
    BodyPart.ARM, BodyPart.CORE, BodyPart.CARDIO, BodyPart.OTHER
  ];

  /** 每个部位一个配色，用于日历打点与统计条 */
  static colorOf(part: string): string {
    switch (part) {
      case BodyPart.CHEST: return '#FF6B6B';
      case BodyPart.BACK: return '#4D96FF';
      case BodyPart.LEG: return '#6BCB77';
      case BodyPart.SHOULDER: return '#FFD93D';
      case BodyPart.ARM: return '#B983FF';
      case BodyPart.CORE: return '#FF9F45';
      case BodyPart.CARDIO: return '#00B8D9';
      default: return '#9AA0A6';
    }
  }
}

/** 训练感受（1-5），0 表示未填写 */
export const FEELING_LABELS: string[] = ['未记录', '很累', '偏累', '一般', '不错', '状态很好'];

export function feelingLabel(v: number): string {
  if (v < 0 || v >= FEELING_LABELS.length) {
    return FEELING_LABELS[0];
  }
  return FEELING_LABELS[v];
}

/** 应用主题色（主打色 #4176e6） */
export class Theme {
  static readonly PRIMARY: string = '#4176e6';
  static readonly PRIMARY_LIGHT: string = '#E6EEFC';
  static readonly SUCCESS: string = '#1FA84E';
  static readonly TEXT_PRIMARY: string = '#182431';
  static readonly TEXT_SECONDARY: string = '#8A8F99';
  static readonly DIVIDER: string = '#E5E5E5';
  static readonly BG: string = '#F1F3F5';
  static readonly CARD_BG: string = '#FFFFFF';
}
