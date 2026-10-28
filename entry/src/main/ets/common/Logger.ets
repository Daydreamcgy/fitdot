import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;

/**
 * 统一日志封装：便于按 TAG 过滤，也避免每处都写 hilog 参数格式。
 * 真机上看日志：DevEco Studio 的 Log 窗口过滤 FitDot，或用 hdc hilog。
 */
export class Logger {
  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', message);
  }
}
