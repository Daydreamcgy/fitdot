import { CheckInRepository } from '../repository/CheckInRepository';
import { WorkoutRepository } from '../repository/WorkoutRepository';
import { CheckIn, CheckInDraft, WorkoutItem } from '../model/Models';
import { AppStore } from '../common/AppStore';

/** 备份文件里的一天 */
export interface BackupDay {
  date: string;
  checkInAt: number;
  durationMin: number;
  feeling: number;
  note: string;
  isBackfill: boolean;
  bodyParts: string;
  items: WorkoutItem[];
}

/** 备份文件根结构 */
export interface BackupFile {
  version: number;
  exportedAt: number;
  days: BackupDay[];
}

/** 明文 JSON 备份：导出/导入（导入为覆盖式恢复） */
export class BackupService {
  /** 导出全部数据为 JSON 字符串 */
  static async exportAll(): Promise<string> {
    const list: CheckIn[] = await CheckInRepository.listAll();
    const days: BackupDay[] = [];
    for (const c of list) {
      const items: WorkoutItem[] = await WorkoutRepository.listByCheckIn(c.id);
      days.push({
        date: c.date,
        checkInAt: c.checkInAt,
        durationMin: c.durationMin,
        feeling: c.feeling,
        note: c.note,
        isBackfill: c.isBackfill,
        bodyParts: c.bodyParts,
        items: items
      });
    }
    const file: BackupFile = {
      version: 1,
      exportedAt: Date.now(),
      days: days
    };
    return JSON.stringify(file, null, 1);
  }

  /** 覆盖式导入：清空现有数据后按备份重建。返回导入天数 */
  static async importAll(json: string): Promise<number> {
    const file: BackupFile = JSON.parse(json) as BackupFile;
    if (file.version !== 1 || !Array.isArray(file.days)) {
      throw new Error('备份文件格式不正确');
    }
    await WorkoutRepository.deleteAll();
    await CheckInRepository.deleteAll();
    for (const d of file.days) {
      const draft: CheckInDraft = {
        date: d.date,
        durationMin: d.durationMin,
        feeling: d.feeling,
        note: d.note,
        isBackfill: d.isBackfill
      };
      const saved: CheckIn = await CheckInRepository.save(draft);
      if (d.bodyParts.length > 0) {
        await CheckInRepository.updateBodyParts(d.date, d.bodyParts);
      }
      if (d.items.length > 0) {
        const items: WorkoutItem[] = [];
        for (let i = 0; i < d.items.length; i++) {
          const raw: WorkoutItem = d.items[i];
          const w: WorkoutItem = {
            id: -1,
            checkInId: saved.id,
            bodyPart: raw.bodyPart,
            exerciseName: raw.exerciseName,
            sets: raw.sets,
            reps: raw.reps,
            weightKg: raw.weightKg,
            durationMin: raw.durationMin,
            distanceKm: raw.distanceKm,
            incline: raw.incline,
            speed: raw.speed,
            sortOrder: i,
            setsJson: raw.setsJson,
            groupTag: raw.groupTag
          };
          items.push(w);
        }
        await WorkoutRepository.replaceAll(saved.id, items);
      }
    }
    await AppStore.get().markDirty();
    return file.days.length;
  }
}
