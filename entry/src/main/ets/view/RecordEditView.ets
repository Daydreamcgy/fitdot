import { Constants, Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { SetEntry, WorkoutItem } from '../model/Models';
import { CheckInService, DayDetail } from '../service/CheckInService';
import { WorkoutRepository } from '../repository/WorkoutRepository';
import { AppConfig, ConfigService, DEFAULT_BODYWEIGHT_MOVES } from '../service/ConfigService';
import { todayStr, weekdayLabel } from '../utils/DateUtil';
import { vibrator } from '@kit.SensorServiceKit';

/** 长按打卡需要持续按住的时长（毫秒），与打卡首页一致 */
const HOLD_DURATION_MS: number = 1000;
/** 长按进度的刷新间隔（毫秒） */
const HOLD_TICK_MS: number = 8;
/** 按住过程中每隔多少进度给一次轻震 */
const HOLD_VIBRATE_STEP: number = 0.2;
/** 提前松手时进度回弹的时长（毫秒） */
const RELEASE_MS: number = 150;
/** 未打卡时按钮的灰蓝色 / 字色，与打卡首页一致 */
const RESTING_COLOR: string = '#9FB0C7';
const RESTING_TEXT_COLOR: string = '#F4F7FA';

/**
 * 离开页面守卫：dirty 状态在 RecordEditView 内，返回手势拦在 NavDestination 上，
 * 用这个共享对象搭桥——子组件注册询问逻辑，父级返回手势调用它。
 */
@ObservedV2
class LeaveGuard {
  /** 由 RecordEditView 注入：处理「返回」询问，返回 true 表示已消费该次返回事件 */
  ask: () => boolean = () => false;
}

/** 规范部位全集（顺序固定：肩、腿、背、二头、胸、三头、腹、有氧），与 body_parts 存储顺序一致 */
const ALL_PARTS: string[] = ['肩部', '腿部', '背部', '二头', '胸部', '三头', '腹肌', '有氧'];

/** 部位 → 预设动作 */
interface PresetGroup {
  part: string;
  moves: string[];
}

/**
 * 自重动作判定：动作名在「自重清单」里就只填次数、不填重量。
 * 清单来自配置管理（ConfigService），不在代码里写死——以后加负重了改配置即可。
 */
function isBodyweightMove(list: string[], name: string): boolean {
  return list.indexOf(name) >= 0;
}

/** 把库里存的 "胸部,三头" 解析成 groups 顺序的部位数组（防御未知值与乱序） */
function parseStoredParts(stored: string, allParts: string[]): string[] {
  const storedList: string[] = stored.split(',');
  const out: string[] = [];
  for (const p of allParts) {
    if (storedList.indexOf(p) >= 0) {
      out.push(p);
    }
  }
  return out;
}

/** 编辑态的一组训练（次数×重量） */
@ObservedV2
export class EditSet {
  @Trace reps: number = 0;
  @Trace weightKg: number = 0;

  constructor(reps: number, weightKg: number) {
    this.reps = reps;
    this.weightKg = weightKg;
  }
}

/** 编辑态的训练动作（@ObservedV2 + @Trace 让输入框里的修改能实时反映到界面） */
@ObservedV2
export class EditItem {
  @Trace bodyPart: string = '';
  @Trace exerciseName: string = '';
  /** 力量动作的组列表（每组 次数×重量）；有氧不用 */
  @Trace setList: EditSet[] = [];
  /** 超级组标记：'' 表示普通动作，'S' 表示属于某个超级组 */
  @Trace groupTag: string = '';
  /** 兼容字段：旧数据推导来源 / 汇总展示用 */
  @Trace sets: number = 0;
  @Trace weightKg: number = 0;
  /** 有氧专用：时间(分)、坡度(%)、速度(km/h)；存储时复用 reps(坡度) → distanceKm(速度) */
  @Trace durationMin: number = 0;
  @Trace incline: number = 0;
  @Trace speed: number = 0;

  static fromModel(w: WorkoutItem): EditItem {
    const e: EditItem = new EditItem();
    e.bodyPart = w.bodyPart;
    e.exerciseName = w.exerciseName;
    e.sets = w.sets;
    e.weightKg = w.weightKg;
    e.groupTag = w.groupTag;
    // 有氧回显：durationMin=时间(分)、reps=坡度(%)、distanceKm=速度(km/h) 反向映射
    e.durationMin = w.durationMin;
    if (w.bodyPart === '有氧') {
      e.incline = w.reps;
      e.speed = w.distanceKm;
    } else if (w.setsJson.length > 0) {
      try {
        const arr: SetEntry[] = JSON.parse(w.setsJson) as SetEntry[];
        for (const s of arr) {
          e.setList.push(new EditSet(s.reps, s.weightKg));
        }
      } catch (err) {
        e.setList.push(new EditSet(w.sets, w.weightKg));
      }
      // 旧记录常见「建了 3 组只填 2 组」的残留空组，读出来时去掉，别显示 0 次 0 kg
      EditItem.trimEmptyTail(e.setList);
    } else if (w.sets > 0 || w.weightKg > 0) {
      // 旧数据自动迁移：视为一组
      e.setList.push(new EditSet(w.sets, w.weightKg));
    }
    return e;
  }

  /** 去掉结尾的空组（0 次 0 kg）：旧记录里「建了 3 组只填 2 组」的残留 */
  static trimEmptyTail(list: EditSet[]): void {
    while (list.length > 1) {
      const last: EditSet = list[list.length - 1];
      if (last.reps > 0 || last.weightKg > 0) {
        break;
      }
      list.pop();
    }
  }

  /** 从预设动作新建一行：力量默认 1 个空组（超级组在 addPreset 里补到 2 组），有氧全 0 */
  static preset(part: string, move: string): EditItem {
    const e: EditItem = new EditItem();
    e.bodyPart = part;
    e.exerciseName = move;
    if (part !== '有氧') {
      e.setList.push(new EditSet(0, 0));
    }
    return e;
  }

  toModel(order: number): WorkoutItem {
    const isCardio: boolean = this.bodyPart === '有氧';
    // 有氧字段复用现有列存储，不改表结构：
    // durationMin=时间(分钟)、reps=坡度(整数%)、distanceKm=速度(km/h)
    // 力量行把组列表序列化进 sets_json，sets/weightKg 同步为兼容汇总值
    let setsJson: string = '';
    let sets: number = this.sets;
    let weightKg: number = this.weightKg;
    if (!isCardio) {
      const entries: SetEntry[] = [];
      for (const s of this.setList) {
        entries.push({ reps: s.reps, weightKg: s.weightKg });
      }
      setsJson = JSON.stringify(entries);
      sets = entries.length;
      weightKg = entries.length > 0 ? entries[entries.length - 1].weightKg : 0;
    }
    const w: WorkoutItem = {
      id: -1,
      checkInId: -1,
      bodyPart: this.bodyPart,
      exerciseName: this.exerciseName,
      sets: sets,
      reps: isCardio ? Math.round(this.incline) : 0,
      weightKg: weightKg,
      durationMin: isCardio ? this.durationMin : 0,
      distanceKm: isCardio ? this.speed : 0,
      incline: 0,
      speed: 0,
      sortOrder: order,
      setsJson: setsJson,
      groupTag: this.groupTag
    };
    return w;
  }
}

/** 当天健身记录页（极简版）：训练部位 + 动作明细，保存即打卡 */
@ComponentV2
export struct RecordEditView {
  @Param pathStack: NavPathStack = new NavPathStack();
  /** Tab 内嵌时隐藏返回箭头 */
  @Param showBack: boolean = true;
  @Local date: string = '';
  @Local checked: boolean = false;
  @Local isBackfill: boolean = false;
  /** 亮起的训练部位（保持规范顺序），保存时 join(',') 写入 body_parts */
  @Local selectedParts: string[] = [];
  @Local items: EditItem[] = [];
  /** 只读态：已展开「每组明细」的动作行下标 */
  @Local expandedRows: number[] = [];
  /** 「＋ 添加动作」选择区是否展开 */
  @Local showPicker: boolean = false;
  @Local loading: boolean = true;
  @Local saving: boolean = false;
  @Local errMsg: string = '';
  /** 有未保存的修改时才显示右上角保存按钮 */
  @Local dirty: boolean = false;
  /** 顶部滑入轻提示 */
  @Local flashText: string = '';
  @Local flashShown: boolean = false;
  private flashTimer: number = -1;
  /** 顶部按钮按压动效状态 */
  @Local editPressed: boolean = false;
  @Local savePressed: boolean = false;
  /** 长按打卡状态（与打卡首页同款） */
  @Local pressing: boolean = false;
  @Local progress: number = 0;
  private holdTimerId: number = -1;
  private holdStartAt: number = 0;
  private vibrateStep: number = 0;
  private releasing: boolean = false;
  private releaseStartAt: number = 0;
  private releaseFrom: number = 0;
  /** 数字输入框的原始文本镜像：键=输入框标识，值=用户键入的原始串（含未完成的小数点等） */
  @Local inputTexts: Map<string, string> = new Map<string, string>();

  private inputProp(key: string, fallback: string): string {
    const v: string | undefined = this.inputTexts.get(key);
    return v !== undefined ? v : fallback;
  }

  private setInputText(key: string, raw: string): void {
    const m: Map<string, string> = new Map<string, string>();
    this.inputTexts.forEach((v: string, k: string) => {
      m.set(k, v);
    });
    m.set(key, raw);
    this.inputTexts = m;
  }
  /** 编辑状态：当天默认可编辑；过去的日子只读，点「编辑」进入 */
  @Local editMode: boolean = false;
  /** 编辑态当前展开输入框的动作行下标（-1=没有）；输入框按需挂载，避免几十个同帧创建卡主线程 */
  @Local activeRow: number = -1;
  /** 当前展开行内已挂载的组数（保留字段，备用） */
  @Local activeSets: number = 0;
  /** 进入编辑后已挂载输入框的行数：整页输入框分帧创建，避免一次性卡住主线程 */
  @Local editRows: number = 0;
  private mountTimer: number = -1;

  /** 进编辑态：所有行都自动变成可输入，但逐帧挂载（首帧先来 2 行，其余每帧 2 行） */
  private startAutoMount(): void {
    if (this.mountTimer >= 0) {
      clearInterval(this.mountTimer);
      this.mountTimer = -1;
    }
    const total: number = this.items.length;
    this.editRows = Math.min(2, total);
    if (this.editRows >= total) {
      return;
    }
    this.mountTimer = setInterval(() => {
      if (this.editRows >= this.items.length) {
        clearInterval(this.mountTimer);
        this.mountTimer = -1;
        return;
      }
      this.editRows = Math.min(this.editRows + 2, this.items.length);
    }, 16);
  }

  /** 该行输入框是否已挂载：普通行分帧挂载；有氧/超级组卡片结构不同，一律立即挂载 */
  private isRowMounted(index: number): boolean {
    if (index < 0 || index >= this.items.length) {
      return false;
    }
    if (index < this.editRows || index === this.activeRow) {
      return true;
    }
    const item: EditItem = this.items[index];
    return item.bodyPart === '有氧' || item.groupTag !== '';
  }

  /** 点某行/某格：挂载该行输入框并聚焦到点的那一格（与直接点输入框聚焦是同一个动作） */
  private activateRow(index: number, field: string, focus: boolean = true): void {
    if (!this.editMode || index < 0 || index >= this.items.length) {
      return;
    }
    this.activeRow = index;
    if (!focus) {
      return;
    }
    const key: string = this.fieldKey(index, field);
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus(key);
      } catch (e) {
        const err = e as Error;
        Logger.warn(Constants.TAG, `聚焦失败: ${err.message}`);
      }
    }, 80);
  }

  /** 行内输入框 id：与 inputTexts 的键一致，用于聚焦 */
  private fieldKey(index: number, field: string): string {
    const item: EditItem = this.items[index];
    if (item.bodyPart === '有氧') {
      return field === 'weight' ? `${index}-spd` : `${index}-dur`;
    }
    if (item.groupTag !== '') {
      return field === 'weight' ? `${index}-0-w` : `${index}-0-reps`;
    }
    return field === 'weight' ? `${index}-n-w` : `${index}-n-reps`;
  }

  private closeActiveRow(): void {
    this.activeRow = -1;
  }
  /** 添加抽屉里的超级组模式：开启后连续添加的动作打上同一「超级组」标记 */
  @Local supersetMode: boolean = false;
  /** 动作名 → 上次训练摘要（如「上次 12×10 / 10×8」） */
  @Local lastRefs: Map<string, string> = new Map<string, string>();
  /** 可配置的部位/动作清单（来自配置管理，进入页面时读取） */
  @Local groups: PresetGroup[] = [];
  /** 自重动作清单（来自配置管理）：命中则记录时不填重量 */
  @Local bodyweightMoves: string[] = DEFAULT_BODYWEIGHT_MOVES.slice();
  /** 底部导航的训练 Tab 实例：永远显示今天，不受日历残留 editingDate 影响 */
  @Param forceToday: boolean = false;
  /** 离开页面守卫（由 RecordEditPage 注入，用于拦截返回手势） */
  @Param guard: LeaveGuard = new LeaveGuard();
  /** 订阅全局数据版本：别处打卡/取消后本页自动重载 */
  @Local store: AppStore = AppStore.get();

  @Monitor('store.dataVersion')
  onDataVersionChange(monitor: IMonitor): void {
    if (this.forceToday) {
      this.date = todayStr();
      this.isBackfill = false;
      this.editMode = true;
      this.closeActiveRow();
    }
    this.reload();
  }

  /** 配置管理里改了部位/动作/自重标记：立即重读，不用重启应用 */
  @Monitor('store.configVersion')
  onConfigVersionChange(monitor: IMonitor): void {
    ConfigService.loadConfig(getContext(this)).then((cfg: AppConfig) => {
      this.groups = cfg.groups;
      this.bodyweightMoves = cfg.bodyweight;
    });
  }

  aboutToAppear(): void {
    // 返回手势（NavDestination.onBackPressed）交给本组件处理
    this.guard.ask = () => {
      this.confirmLeave();
      return true;
    };
    const d: string = AppStore.get().editingDate;
    this.date = !this.forceToday && d.length > 0 ? d : todayStr();
    this.isBackfill = this.date !== todayStr();
    this.editMode = this.date === todayStr();
    ConfigService.loadConfig(getContext(this)).then((cfg: AppConfig) => {
      this.groups = cfg.groups;
      this.bodyweightMoves = cfg.bodyweight;
    });
    this.reload();
  }

  /** 首次加载才显示 loading；后续静默刷新，避免内容卸载导致滚动位置丢失 */
  private loadedOnce: boolean = false;

  private async reload(): Promise<void> {
    if (!this.loadedOnce) {
      this.loading = true;
    }
    this.errMsg = '';
    try {
      const detail: DayDetail = await CheckInService.loadDay(this.date);
      this.checked = detail.checked;
      this.selectedParts = parseStoredParts(detail.checkIn.bodyParts, this.partsList());
      const list: EditItem[] = [];
      for (const w of detail.items) {
        list.push(EditItem.fromModel(w));
      }
      this.items = list;
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `记录页加载失败: ${err.message}`);
    } finally {
      this.loadedOnce = true;
      this.loading = false;
      this.inputTexts = new Map<string, string>();
      this.loadLastRefs();
      // 当天页首次加载即为编辑态：所有行分帧变为可输入
      if (this.editMode && this.editRows < this.items.length) {
        this.startAutoMount();
      }
    }
  }

  /** 规范顺序的部位全集（来自配置） */
  private partsList(): string[] {
    const out: string[] = [];
    for (const g of this.groups) {
      out.push(g.part);
    }
    return out;
  }

  /** 点胶囊切换部位选中态；selectedParts 始终保持规范顺序（只读态不可点） */
  private togglePart(part: string): void {
    if (!this.editMode) {
      return;
    }
    this.dirty = true;
    const idx: number = this.selectedParts.indexOf(part);
    if (idx >= 0) {
      const list: string[] = this.selectedParts.slice();
      list.splice(idx, 1);
      this.selectedParts = list;
      return;
    }
    const list: string[] = [];
    for (const p of this.partsList()) {
      if (p === part || this.selectedParts.indexOf(p) >= 0) {
        list.push(p);
      }
    }
    this.selectedParts = list;
  }

  /** 当前亮起部位对应的预设动作组（按规范顺序；同名动作只出现一次） */
  private litGroups(): PresetGroup[] {
    const out: PresetGroup[] = [];
    const seen: Set<string> = new Set<string>();
    for (const part of this.selectedParts) {
      for (const g of this.groups) {
        if (g.part !== part) {
          continue;
        }
        const moves: string[] = [];
        for (const m of g.moves) {
          if (!seen.has(m)) {
            seen.add(m);
            moves.push(m);
          }
        }
        if (moves.length > 0) {
          const group: PresetGroup = { part: g.part, moves: moves };
          out.push(group);
        }
        break;
      }
    }
    return out;
  }

  /** 开关超级组模式：开启后连续添加的动作打上同一「超级组」标记 */
  private toggleSupersetMode(): void {
    this.supersetMode = !this.supersetMode;
  }

  /** 把预设动作加入列表，选择区保持展开方便连加；同一动作重复添加时继承上次填写的数据 */
  private addPreset(part: string, move: string): void {
    this.dirty = true;
    const list: EditItem[] = this.items.slice();
    const e: EditItem = EditItem.preset(part, move);
    if (this.supersetMode) {
      e.groupTag = 'S';
      // 超级组默认 2 组（preset 已建 1 组，这里再补 1 组）
      e.setList.push(new EditSet(0, 0));
    }
    for (let i = this.items.length - 1; i >= 0; i--) {
      const prev: EditItem = this.items[i];
      if (prev.exerciseName === move) {
        // 组列表整组继承（连加同一动作时不用重填）
        e.setList = [];
        for (const s of prev.setList) {
          e.setList.push(new EditSet(s.reps, s.weightKg));
        }
        e.sets = prev.sets;
        e.weightKg = prev.weightKg;
        e.durationMin = prev.durationMin;
        e.incline = prev.incline;
        e.speed = prev.speed;
        break;
      }
    }
    list.push(e);
    this.items = list;
    // 新增的动作立即展开输入框，接着就能填数据
    this.activateRow(this.items.length - 1, 'reps');
  }

  /** 重量字段标签：哑铃动作为左右各（单只重量），其余为公斤 */
  private weightLabel(name: string): string {
    if (name.indexOf('哑铃') >= 0) {
      return '左右各';
    }
    return '公斤';
  }

  /** 该动作是否按自重记录（清单来自「配置管理」，可随时改） */
  private isBodyweight(name: string): boolean {
    return isBodyweightMove(this.bodyweightMoves, name);
  }

  // ==================== 只读态：展开每组明细 ====================

  /** 多组的力量动作才需要展开（单组本来就一行看完） */
  private rowExpandable(item: EditItem): boolean {
    return item.bodyPart !== '有氧' && item.setList.length > 1;
  }

  private isRowExpanded(index: number): boolean {
    return this.expandedRows.indexOf(index) >= 0;
  }

  private toggleRowExpanded(index: number): void {
    const list: number[] = this.expandedRows.slice();
    const i: number = list.indexOf(index);
    if (i >= 0) {
      list.splice(i, 1);
    } else {
      list.push(index);
    }
    this.expandedRows = list;
  }

  /** 某一组的重量文案：自重动作显示「自重」或「自重+Xkg」 */
  private setWeightText(item: EditItem, s: EditSet): string {
    if (this.isBodyweight(item.exerciseName)) {
      return s.weightKg > 0 ? `自重+${s.weightKg}kg` : '自重';
    }
    return `${s.weightKg}kg`;
  }

  private removeItem(index: number): void {
    this.dirty = true;
    const list: EditItem[] = this.items.slice();
    list.splice(index, 1);
    this.items = list;
    this.closeActiveRow();
    this.editRows = Math.min(this.editRows, this.items.length);
  }

  // ==================== 组操作（力量动作卡片） ====================

  /** 组变化后把兼容汇总值同步回 item（sets=组数、weightKg=末组重量） */
  private syncLegacy(item: EditItem): void {
    item.sets = item.setList.length;
    item.weightKg = item.setList.length > 0 ? item.setList[item.setList.length - 1].weightKg : 0;
  }

  private addSet(item: EditItem): void {
    item.setList.push(new EditSet(0, 0));
    this.dirty = true;
    this.syncLegacy(item);
  }

  /** 递减组：复制末组，重量 −2.5kg（不低于 0） */
  private addDropSet(item: EditItem): void {
    const n: number = item.setList.length;
    if (n === 0) {
      item.setList.push(new EditSet(0, 0));
      this.dirty = true;
      this.syncLegacy(item);
      return;
    }
    const last: EditSet = item.setList[n - 1];
    const w: number = last.weightKg - 2.5 > 0 ? last.weightKg - 2.5 : 0;
    item.setList.push(new EditSet(last.reps, w));
    this.dirty = true;
    this.syncLegacy(item);
  }

  private removeSet(item: EditItem, si: number): void {
    item.setList.splice(si, 1);
    this.dirty = true;
    this.syncLegacy(item);
  }

  /** 超级组标记：统一为 'S'，相邻同标记的动作为一组超级组 */
  private cycleGroupTag(index: number): void {
    const item: EditItem = this.items[index];
    const used: string[] = [];
    for (const it of this.items) {
      if (it.groupTag !== '' && used.indexOf(it.groupTag) < 0) {
        used.push(it.groupTag);
      }
    }
    if (item.groupTag !== '') {
      item.groupTag = '';
    } else {
      const letters: string[] = ['A', 'B', 'C', 'D', 'E', 'F'];
      let next: string = 'A';
      for (const l of letters) {
        if (used.indexOf(l) < 0) {
          next = l;
          break;
        }
      }
      item.groupTag = next;
    }
    this.dirty = true;
  }

  /** 组内输入：聚焦记录字段（仅用于记账，不再自动保存） */
  private focusSet(s: EditSet, field: string, key: string): void {
    this.editField = `set:${field}`;
  }

  /** 失焦：只把原始文本规范回数值格式，不写库（保存由右上角按钮手动触发） */
  private blurSet(s: EditSet, field: string, key: string): void {
    this.setInputText(key, field === 'reps'
      ? (s.reps > 0 ? `${s.reps}` : '')
      : (s.weightKg > 0 ? `${s.weightKg}` : ''));
  }

  // ==================== 汇总 ====================

  /** 右上角轻提示：滑入后自动或右滑滑出 */
  private hideFlash(): void {
    if (!this.flashShown) {
      return;
    }
    if (this.flashTimer >= 0) {
      clearTimeout(this.flashTimer);
      this.flashTimer = -1;
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseIn }, () => {
      this.flashShown = false;
    });
  }

  /** 右上角轻提示：从右滑入，停留片刻或右滑消失 */
  private flashToast(message: string): void {
    this.flashText = message;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.flashShown = true;
    });
    if (this.flashTimer >= 0) {
      clearTimeout(this.flashTimer);
    }
    this.flashTimer = setTimeout(() => {
      this.hideFlash();
    }, 1200);
  }

  /** 拉取各动作「上次训练」摘要（只取历史日期） */
  private async loadLastRefs(): Promise<void> {
    const names: string[] = [];
    for (const it of this.items) {
      if (it.bodyPart !== '有氧' && names.indexOf(it.exerciseName) < 0) {
        names.push(it.exerciseName);
      }
    }
    const map: Map<string, string> = new Map<string, string>();
    for (const n of names) {
      const rows: WorkoutItem[] = await WorkoutRepository.lastByName(n, this.date);
      if (rows.length === 0) {
        continue;
      }
      const parts: string[] = [];
      for (const r of rows) {
        // 自重动作不显示重量（历史上有负重值时按「自重+kg」展示，不丢信息）
        if (this.isBodyweight(n)) {
          parts.push(r.weightKg > 0 ? `${r.reps}×自重+${r.weightKg}kg` : `${r.reps}×自重`);
        } else {
          parts.push(`${r.reps}×${r.weightKg}kg`);
        }
      }
      map.set(n, `上次 ${parts.join(' / ')}`);
    }
    this.lastRefs = map;
  }

  private toInt(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    const v: number = Number.parseInt(text, 10);
    return Number.isNaN(v) ? 0 : v;
  }

  private toFloat(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    const v: number = Number.parseFloat(text);
    return Number.isNaN(v) ? 0 : v;
  }

  // ==================== 输入体验：聚焦清空 / 失焦自动保存 ====================

  private editBackup: number = 0;
  private editField: string = '';
  private editTouched: boolean = false;

  private getNum(item: EditItem, field: string): number {
    if (field === 'sets') {
      return item.sets;
    }
    if (field === 'weightKg') {
      return item.weightKg;
    }
    if (field === 'durationMin') {
      return item.durationMin;
    }
    if (field === 'incline') {
      return item.incline;
    }
    return item.speed;
  }

  private setNum(item: EditItem, field: string, v: number): void {
    if (field === 'sets') {
      item.sets = v;
    } else if (field === 'weightKg') {
      item.weightKg = v;
    } else if (field === 'durationMin') {
      item.durationMin = v;
    } else if (field === 'incline') {
      item.incline = v;
    } else {
      item.speed = v;
    }
  }

  /** 聚焦记录当前编辑字段（不清值，避免输入框重置丢键盘） */
  private focusNum(item: EditItem, field: string, key: string): void {
    this.editField = field;
  }

  /** 失焦：只把原始文本规范回数值格式，不写库（保存由右上角按钮手动触发） */
  private blurNum(item: EditItem, field: string, key: string): void {
    let canonical: string = '';
    if (field === 'durationMin') {
      canonical = item.durationMin > 0 ? `${item.durationMin}` : '';
    } else if (field === 'incline') {
      canonical = item.incline > 0 ? `${item.incline}` : '';
    } else if (field === 'speed') {
      canonical = item.speed > 0 ? `${item.speed}` : '';
    }
    this.setInputText(key, canonical);
  }

  /** 保存（右上角按钮）：保存后留在当前页 */
  /** 保存排队：写库进行中又收到保存请求（如点击按钮时失焦自动保存正在跑），写完补一次 */
  private saveQueued: boolean = false;

  private async save(): Promise<void> {
    if (this.saving) {
      this.saveQueued = true;
      return;
    }
    this.saving = true;
    this.errMsg = '';
    try {
      const models: WorkoutItem[] = [];
      for (let i = 0; i < this.items.length; i++) {
        const it: EditItem = this.items[i];
        // 没有动作名的行直接丢弃，避免存进空记录
        if (it.exerciseName.length === 0) {
          continue;
        }
        models.push(it.toModel(models.length));
      }
      await CheckInService.saveDay(this.date, this.selectedParts.join(','), models);
      this.dirty = false;
      // 历史补录：保存后回到只读摘要（仅切换可见性，不重建）；当天保持编辑态
      if (this.isBackfill) {
        this.editMode = false;
        this.closeActiveRow();
        this.editRows = 0;
      }
      this.flashToast('已保存');
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `保存失败: ${err.message}`);
    } finally {
      this.saving = false;
      if (this.saveQueued) {
        this.saveQueued = false;
        this.save();
      }
    }
  }

  /** 离开页面：有未保存修改就先问一句 */
  private confirmLeave(): void {
    if (!this.dirty || this.saving) {
      this.doLeave();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '还没保存',
      message: '这一天的训练有修改还没保存，要保存吗？',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '保存并离开',
        action: () => {
          this.saveAndLeave();
        }
      },
      secondaryButton: {
        value: '不保存离开',
        fontColor: '#D93026',
        action: () => {
          this.doLeave();
        }
      }
    });
  }

  /** 保存成功后再离开；保存失败则留在页面（错误提示已显示） */
  private async saveAndLeave(): Promise<void> {
    await this.save();
    if (!this.dirty) {
      this.doLeave();
    }
  }

  private doLeave(): void {
    this.pathStack.pop();
  }

  private async cancelCheckIn(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      await CheckInService.cancel(this.date);
      AppStore.get().markDirty();
      // 取消即完成：清掉未保存标记与排队保存（防止后续保存把打卡重新建回），直接回日历
      this.dirty = false;
      this.saveQueued = false;
      this.closeActiveRow();
      this.editRows = 0;
      this.editMode = false;
      this.pathStack.pop();
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `取消打卡失败: ${err.message}`);
    } finally {
      this.saving = false;
    }
  }

  /** 长按大按钮打卡：非今天标记为补录，成功后进入信息页 */
  private async checkInNow(): Promise<void> {
    if (this.saving || this.checked) {
      return;
    }
    this.saving = true;
    try {
      await CheckInService.checkIn(this.date, this.date !== todayStr());
      AppStore.get().markDirty();
      await this.reload();
      this.flashToast('已打卡');
    } catch (e) {
      const err = e as Error;
      this.errMsg = err.message;
      Logger.error(Constants.TAG, `打卡失败 ${this.date}: ${err.message}`);
    } finally {
      this.saving = false;
    }
  }

  /** 未打卡：大按钮（与打卡首页同款），长按打卡后才进入信息页 */
  @Builder
  bigCheckIn() {
    Column({ space: 18 }) {
      Stack() {
        // 常驻灰环
        Progress({ value: 100, total: 100, type: ProgressType.Ring })
          .width(244)
          .height(244)
          .color('#DDE3EC')
          .style({ strokeWidth: 10 })

        // 长按进度环
        Progress({ value: Math.round(this.progress * 100), total: 100, type: ProgressType.Ring })
          .width(244)
          .height(244)
          .color(Theme.PRIMARY)
          .style({ strokeWidth: 10 })
          .opacity(this.progress > 0 ? 1 : 0)

        Column() {
          Text(this.pressing ? '松开取消' : '补打卡')
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .fontColor(RESTING_TEXT_COLOR)
            .letterSpacing(4)
        }
        .justifyContent(FlexAlign.Center)
        .width(216)
        .height(216)
        .borderRadius(108)
        .backgroundColor(RESTING_COLOR)
        .shadow({
          radius: this.pressing ? 26 : 20,
          color: '#264176e6',
          offsetY: 10
        })
        .scale({
          x: 1 - 0.05 * Math.min(1, this.progress * 5),
          y: 1 - 0.05 * Math.min(1, this.progress * 5)
        })
        .onTouch((event: TouchEvent) => {
          this.onButtonTouch(event);
        })
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  // ==================== 长按打卡（与打卡首页同款交互） ====================

  /** 指尖按下：开始计时并给出第一下触感 */
  private startHold(): void {
    if (this.saving || this.loading || this.checked) {
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
      this.vibrateSuccess();
      this.checkInNow();
    }
  }

  /** 手指提前松开：平滑回弹 */
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
    }, { usage: 'touch' }).catch((err: Error) => {
      this.vibrateTime(60);
    });
  }

  // ==================== UI ====================

  /** 顶栏：返回箭头 + 居中日期 + 有修改时才出现的保存按钮 */
  @Builder
  topBar() {
    Stack() {
      Row() {
        Text(`${this.date} 周${weekdayLabel(this.date)}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_PRIMARY)
      }
      .alignItems(VerticalAlign.Center)

      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor(Theme.TEXT_PRIMARY)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .visibility(this.showBack ? Visibility.Visible : Visibility.None)
          .onClick(() => {
            this.confirmLeave();
          })
        Blank()
        if (this.checked && !this.editMode) {
          Text('编辑')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.PRIMARY)
            .height(48)
            .padding({ left: 24, right: 16 })
            .scale({ x: this.editPressed ? 0.9 : 1, y: this.editPressed ? 0.9 : 1 })
            .opacity(this.editPressed ? 0.55 : 1)
            .onTouch((event: TouchEvent) => {
              this.editPressed = event.type === TouchType.Down;
            })
            .onClick(() => {
              this.editMode = true;
              // 进入编辑即进入待保存状态，右上角立即出现「保存」
              this.dirty = true;
              // 所有行自动变为可输入（分帧挂载，不卡）
              this.startAutoMount();
            })
        } else if (this.dirty) {
          Text(this.saving ? '保存中…' : '保存')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.saving ? Theme.TEXT_SECONDARY : Theme.PRIMARY)
            .height(48)
            .padding({ left: 24, right: 16 })
            .scale({ x: this.savePressed ? 0.9 : 1, y: this.savePressed ? 0.9 : 1 })
            .opacity(this.savePressed ? 0.55 : 1)
            .onTouch((event: TouchEvent) => {
              this.savePressed = event.type === TouchType.Down;
            })
            .onClick(() => {
              this.save();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 12 })
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_SECONDARY)
      .width('100%')
  }

  /** 训练部位：8 个胶囊按钮，可多选 */
  @Builder
  partsSection() {
    Column({ space: 12 }) {
      this.sectionTitle('训练部位')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.partsList(), (part: string) => {
          Text(part)
            .fontSize(13)
            .fontColor(this.selectedParts.indexOf(part) >= 0 ? Color.White : Theme.TEXT_PRIMARY)
            .backgroundColor(this.selectedParts.indexOf(part) >= 0 ? Theme.PRIMARY : '#EDF0F4')
            .height(32)
            .padding({ left: 14, right: 14 })
            .borderRadius(16)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.togglePart(part);
            })
        }, (part: string) => part)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  /** 只读次数列：单组=12次；多组=3组；有氧=20分 */
  private repsCell(item: EditItem): string {
    if (item.bodyPart === '有氧') {
      return item.durationMin > 0 ? `${item.durationMin}分` : '';
    }
    if (item.setList.length === 1) {
      return `${item.setList[0].reps}次`;
    }
    return item.setList.length > 0 ? `${item.setList.length}组` : '';
  }

  /** 只读重量列：自重 / 自重+20kg / 30kg / 多组 60/55kg；有氧=速度或坡度 */
  private weightCell(item: EditItem): string {
    if (item.bodyPart === '有氧') {
      if (item.speed > 0) {
        return `${item.speed}km/h`;
      }
      if (item.incline > 0) {
        return `坡度${item.incline}`;
      }
      return '';
    }
    if (this.isBodyweight(item.exerciseName)) {
      // 自重动作：如果历史上填过负重（改配置之前记的，或负重做），显示成「自重+kg」不丢信息
      let maxAdded: number = 0;
      for (const s of item.setList) {
        if (s.weightKg > maxAdded) {
          maxAdded = s.weightKg;
        }
      }
      return maxAdded > 0 ? `自重+${maxAdded}kg` : '自重';
    }
    if (item.setList.length === 1) {
      return `${item.setList[0].weightKg}kg`;
    }
    const parts: string[] = [];
    for (let i = 0; i < item.setList.length; i++) {
      parts.push(`${item.setList[i].weightKg}`);
    }
    return item.setList.length > 0 ? `${parts.join('/')}kg` : '';
  }

  /** 动作卡片：名称 + 超级组标记 + 组行列表（每组 次数×重量）+ 加组/递减；有氧仍为单行三输入 */
  @Builder
  moveRow(index: number, item: EditItem) {
    if (item.bodyPart === '有氧' || item.groupTag !== '') {
      Column({ space: 10 }) {
      Row({ space: 8 }) {
        if (item.groupTag !== '') {
          Text('超级组')
            .fontSize(10)
            .fontColor(Color.White)
            .backgroundColor('#7B61FF')
            .height(18)
            .padding({ left: 6, right: 6 })
            .borderRadius(9)
        }
        Text(item.exerciseName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('×')
          .fontSize(18)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.removeItem(index);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if ((this.lastRefs.get(item.exerciseName) ?? '').length > 0) {
        Text(this.lastRefs.get(item.exerciseName) ?? '')
          .fontSize(10)
          .fontColor(Theme.TEXT_SECONDARY)
      }

      if (item.bodyPart === '有氧') {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text('时间(分)').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
            TextInput({ text: this.inputProp(`${index}-dur`, item.durationMin > 0 ? `${item.durationMin}` : ''), placeholder: '0' })
              .id(`${index}-dur`)
              .type(InputType.Number)
              .selectAll(true)
              .width(56)
              .height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .onChange((value: string) => {
                this.setInputText(`${index}-dur`, value);
                item.durationMin = this.toInt(value);
                this.editTouched = true;
                this.dirty = true;
              })
              .onFocus(() => {
                this.focusNum(item, 'durationMin', `${index}-dur`);
              })
              .onBlur(() => {
                this.blurNum(item, 'durationMin', `${index}-dur`);
              })
          }

          Column({ space: 3 }) {
            Text('坡度(%)').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
            TextInput({ text: this.inputProp(`${index}-inc`, item.incline > 0 ? `${item.incline}` : ''), placeholder: '0' })
              .id(`${index}-inc`)
              .type(InputType.NUMBER_DECIMAL)
              .selectAll(true)
              .width(56)
              .height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .onChange((value: string) => {
                this.setInputText(`${index}-inc`, value);
                item.incline = this.toFloat(value);
                this.editTouched = true;
                this.dirty = true;
              })
              .onFocus(() => {
                this.focusNum(item, 'incline', `${index}-inc`);
              })
              .onBlur(() => {
                this.blurNum(item, 'incline', `${index}-inc`);
              })
          }

          Column({ space: 3 }) {
            Text('速度(km/h)').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
            TextInput({ text: this.inputProp(`${index}-spd`, item.speed > 0 ? `${item.speed}` : ''), placeholder: '0' })
              .id(`${index}-spd`)
              .type(InputType.NUMBER_DECIMAL)
              .selectAll(true)
              .width(56)
              .height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .onChange((value: string) => {
                this.setInputText(`${index}-spd`, value);
                item.speed = this.toFloat(value);
                this.editTouched = true;
                this.dirty = true;
              })
              .onFocus(() => {
                this.focusNum(item, 'speed', `${index}-spd`);
              })
              .onBlur(() => {
                this.blurNum(item, 'speed', `${index}-spd`);
              })
          }
        }
        .width('100%')
      } else {
        ForEach(item.setList, (s: EditSet, si: number) => {
          Row({ space: 8 }) {
            Text(`${si + 1}`)
              .fontSize(11)
              .fontColor(Theme.TEXT_SECONDARY)
              .width(16)
              .textAlign(TextAlign.Center)
            Column({ space: 2 }) {
              Text('次数').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
              TextInput({ text: this.inputProp(`${index}-${si}-reps`, s.reps > 0 ? `${s.reps}` : ''), placeholder: '0' })
                .id(`${index}-${si}-reps`)
                .type(InputType.Number)
                .selectAll(true)
                .width(72)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor('#FFFFFF')
                .borderRadius(8)
                .onChange((value: string) => {
                  this.setInputText(`${index}-${si}-reps`, value);
                  s.reps = this.toInt(value);
                  this.editTouched = true;
                  this.dirty = true;
                  this.syncLegacy(item);
                })
                .onFocus(() => {
                  this.focusSet(s, 'reps', `${index}-${si}-reps`);
                })
                .onBlur(() => {
                  this.blurSet(s, 'reps', `${index}-${si}-reps`);
                })
            }
            if (this.isBodyweight(item.exerciseName)) {
              Column({ space: 2 }) {
                Text('重量').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
                Text('自重')
                  .fontSize(13)
                  .fontColor(Theme.TEXT_PRIMARY)
                  .width(72)
                  .height(32)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(8)
              }
            } else {
              Column({ space: 2 }) {
                Text(this.weightLabel(item.exerciseName)).fontSize(10).fontColor(Theme.TEXT_SECONDARY)
                TextInput({ text: this.inputProp(`${index}-${si}-w`, s.weightKg > 0 ? `${s.weightKg}` : ''), placeholder: '0' })
                  .id(`${index}-${si}-w`)
                  .type(InputType.NUMBER_DECIMAL)
                  .selectAll(true)
                  .width(72)
                  .height(32)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(8)
                  .onChange((value: string) => {
                    this.setInputText(`${index}-${si}-w`, value);
                    s.weightKg = this.toFloat(value);
                    this.editTouched = true;
                    this.dirty = true;
                    this.syncLegacy(item);
                  })
                  .onFocus(() => {
                    this.focusSet(s, 'weightKg', `${index}-${si}-w`);
                  })
                  .onBlur(() => {
                    this.blurSet(s, 'weightKg', `${index}-${si}-w`);
                  })
              }
            }
            Blank()
            Text('×')
              .fontSize(15)
              .fontColor(Theme.TEXT_SECONDARY)
              .width(24)
              .height(24)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.removeSet(item, si);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (s: EditSet, si: number) => `${index}-${si}`)

        Row({ space: 8 }) {
          Text('＋ 加一组')
            .fontSize(12)
            .fontColor(Theme.PRIMARY)
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .backgroundColor('#FFFFFF')
            .onClick(() => {
              this.addSet(item);
            })
          Text('递减 −2.5kg')
            .fontSize(12)
            .fontColor(Theme.PRIMARY)
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .backgroundColor('#FFFFFF')
            .onClick(() => {
              this.addDropSet(item);
            })
        }
      }
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 10, bottom: 12 })
    .borderRadius(12)
    .backgroundColor('#F5F6F8')
    .alignItems(HorizontalAlign.Start)
    } else {
      // 普通力量动作：单行 名称 + 次数 + 重量
      Row({ space: 8 }) {
        Text(item.exerciseName)
          .fontSize(14)
          .fontColor(Theme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Column({ space: 2 }) {
          Text('次数').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
          TextInput({ text: this.inputProp(`${index}-n-reps`, item.setList[0].reps > 0 ? `${item.setList[0].reps}` : ''), placeholder: '0' })
            .id(`${index}-n-reps`)
            .type(InputType.Number)
            .selectAll(true)
            .width(72)
            .height(32)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
            .onChange((value: string) => {
              this.setInputText(`${index}-n-reps`, value);
              item.setList[0].reps = this.toInt(value);
              this.editTouched = true;
              this.dirty = true;
              this.syncLegacy(item);
            })
            .onFocus(() => {
              this.focusSet(item.setList[0], 'reps', `${index}-n-reps`);
            })
            .onBlur(() => {
              this.blurSet(item.setList[0], 'reps', `${index}-n-reps`);
            })
        }
        if (this.isBodyweight(item.exerciseName)) {
          Column({ space: 2 }) {
            Text('重量').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
            Text('自重')
              .fontSize(13)
              .fontColor(Theme.TEXT_PRIMARY)
              .width(72)
              .height(32)
              .textAlign(TextAlign.Center)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
          }
        } else {
          Column({ space: 2 }) {
            Text(this.weightLabel(item.exerciseName)).fontSize(10).fontColor(Theme.TEXT_SECONDARY)
            TextInput({ text: this.inputProp(`${index}-n-w`, item.setList[0].weightKg > 0 ? `${item.setList[0].weightKg}` : ''), placeholder: '0' })
              .id(`${index}-n-w`)
              .type(InputType.NUMBER_DECIMAL)
              .selectAll(true)
              .width(72)
              .height(32)
              .textAlign(TextAlign.Center)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .onChange((value: string) => {
                this.setInputText(`${index}-n-w`, value);
                item.setList[0].weightKg = this.toFloat(value);
                this.editTouched = true;
                this.dirty = true;
                this.syncLegacy(item);
              })
              .onFocus(() => {
                this.focusSet(item.setList[0], 'weightKg', `${index}-n-w`);
              })
              .onBlur(() => {
                this.blurSet(item.setList[0], 'weightKg', `${index}-n-w`);
              })
          }
        }
        Text('×')
          .fontSize(16)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.removeItem(index);
          })
      }
      .width('100%')
      .padding({ left: 14, right: 8, top: 8, bottom: 8 })
      .borderRadius(12)
      .backgroundColor('#F5F6F8')
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 编辑态未展开的值行：浅蓝底 + ›，点一下即展开该行输入框并聚焦 */
  @Builder
  valueRow(item: EditItem, index: number) {
    Row({ space: 8 }) {
      if (item.groupTag !== '') {
        Text('超级组')
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor('#7B61FF')
          .height(18)
          .padding({ left: 6, right: 6 })
          .borderRadius(9)
      }
      Text(item.exerciseName)
        .fontSize(14)
        .fontColor(Theme.TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Column({ space: 2 }) {
        Text('次数').fontSize(10).fontColor(Theme.TEXT_SECONDARY)
        Text(item.setList.length > 0 && item.setList[0].reps > 0 ? `${item.setList[0].reps}` : '')
          .fontSize(14)
          .fontColor(Theme.TEXT_PRIMARY)
          .width(72)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
      }
      Column({ space: 2 }) {
        Text(this.isBodyweight(item.exerciseName) ? '重量' : this.weightLabel(item.exerciseName))
          .fontSize(10)
          .fontColor(Theme.TEXT_SECONDARY)
        Text(this.isBodyweight(item.exerciseName)
          ? '自重'
          : (item.setList.length > 0 && item.setList[0].weightKg > 0 ? `${item.setList[0].weightKg}` : ''))
          .fontSize(14)
          .fontColor(Theme.TEXT_PRIMARY)
          .width(72)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
      }
      Text('×')
        .fontSize(16)
        .fontColor(Theme.TEXT_SECONDARY)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.removeItem(index);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor('#F5F6F8')
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.activateRow(index, 'reps');
    })
  }

  /** 只读动作行：名称 次数 重量。多组时点一下展开每组明细（超级组标记只在展开后显示） */
  @Builder
  readOnlyRow(index: number, item: EditItem) {
    Column() {
      Row({ space: 8 }) {
        Text(item.exerciseName)
          .fontSize(14)
          .fontColor(Theme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.repsCell(item))
          .fontSize(13)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(52)
          .textAlign(TextAlign.End)
        Text(this.weightCell(item))
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(96)
          .textAlign(TextAlign.End)
        Text(this.rowExpandable(item) ? (this.isRowExpanded(index) ? '▴' : '▾') : '')
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(14)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.rowExpandable(item)) {
          this.toggleRowExpanded(index);
        }
      })

      // 展开后：每组做了什么（列宽与表头一致：次数 = 52 宽 / 重量 = 96 宽 / 尾部留 14 对应箭头列）
      if (this.isRowExpanded(index)) {
        Divider()
          .strokeWidth(0.5)
          .color('#E2E5EA')
          .margin({ left: 14, right: 14 })

        Column({ space: 8 }) {
          if (item.groupTag !== '') {
            Row() {
              Text('超级组')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor('#7B61FF')
                .height(16)
                .padding({ left: 6, right: 6 })
                .borderRadius(8)
              Blank()
            }
            .width('100%')
          }

          ForEach(item.setList, (s: EditSet, si: number) => {
            Row({ space: 8 }) {
              Text(`第 ${si + 1} 组`)
                .fontSize(11)
                .fontColor(Theme.TEXT_SECONDARY)
                .width(52)
              Text(`${s.reps} 次`)
                .fontSize(12)
                .fontColor(Theme.TEXT_PRIMARY)
                .layoutWeight(1)
                .textAlign(TextAlign.End)
              Text(this.setWeightText(item, s))
                .fontSize(12)
                .fontColor(Theme.TEXT_PRIMARY)
                .width(96)
                .textAlign(TextAlign.End)
              Row().width(14)
            }
            .width('100%')
          }, (s: EditSet, si: number) => `${index}-set-${si}`)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor('#F5F6F8')
    .alignItems(HorizontalAlign.Start)
  }

  /** 预设动作选择：部位标题 + 三列圆角方块按钮，点击即添加并收起抽屉 */
  @Builder
  movePicker() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Text('超级组')
          .fontSize(12)
          .fontColor(this.supersetMode ? Color.White : Theme.TEXT_PRIMARY)
          .height(28)
          .padding({ left: 12, right: 12 })
          .borderRadius(14)
          .backgroundColor(this.supersetMode ? '#7B61FF' : '#F5F6F8')
          .onClick(() => {
            this.toggleSupersetMode();
          })
        if (this.supersetMode) {
          Text('连续添加的动作将合并为一个超级组')
            .fontSize(10)
            .fontColor(Theme.TEXT_SECONDARY)
        }
      }
      .width('100%')

      if (this.litGroups().length === 0) {
        Text('先选择训练部位')
          .fontSize(13)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
      }
      ForEach(this.litGroups(), (group: PresetGroup) => {
        Column({ space: 8 }) {
          Text(group.part)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_PRIMARY)
          Grid() {
            ForEach(group.moves, (move: string) => {
              GridItem() {
                Text(move)
                  .fontSize(12)
                  .fontColor(Theme.TEXT_PRIMARY)
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .height(40)
                  .borderRadius(6)
                  .backgroundColor('#F5F6F8')
                  .onClick(() => {
                    this.addPreset(group.part, move);
                    this.showPicker = false;
                  })
              }
            }, (move: string) => `${group.part}-${move}`)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .width('100%')
          .height(group.moves.length <= 3 ? 40 : (group.moves.length <= 6 ? 88 : 136))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (group: PresetGroup) => group.part)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 动作：列表 + 添加按钮 + 选择区 */
  @Builder
  movesSection() {
    Column({ space: 12 }) {
      this.sectionTitle('动作')

      ForEach(this.items, (item: EditItem, index: number) => {
        if (this.editMode && this.isRowMounted(index)) {
          // 编辑态（已就绪）：完整输入行
          Column() {
            this.moveRow(index, item)
          }
          .width('100%')
        } else if (this.editMode) {
          // 编辑态（输入框正在后台挂载）：外观与输入行完全一致，看不出加载过程
          Column() {
            this.valueRow(item, index)
          }
          .width('100%')
        } else {
          Column() {
            this.readOnlyRow(index, item)
          }
          .width('100%')
        }
      }, (item: EditItem, index: number) =>
        `${index}-${item.exerciseName}-${this.editMode ? 'e' : 'r'}-${this.isRowExpanded(index) ? 1 : 0}`)

      if (this.editMode) {
        Row() {
          Text('＋ 添加动作')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.TEXT_PRIMARY)
        }
        .width('100%')
        .height(42)
        .justifyContent(FlexAlign.Center)
        .borderRadius(21)
        .backgroundColor('#EDF0F4')
        .visibility(this.editMode ? Visibility.Visible : Visibility.None)
        .onClick(() => {
          this.showPicker = true;
        })
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
    .bindSheet($$this.showPicker, this.presetSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: Color.Transparent
    })
  }

  /** 底部抽屉内容：自绘白底，无圆角 */
  @Builder
  presetSheet() {
    Column() {
      this.movePicker()
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
  }

  /** 页面底部：已打卡且编辑态才显示「取消这一天的打卡」 */
  @Builder
  bottomActions() {
    Column({ space: 10 }) {
      if (this.checked && this.editMode) {
        Text(this.saving ? '处理中…' : '取消打卡')
          .fontSize(14)
          .fontColor('#D93026')
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(40)
          .borderRadius(20)
          .backgroundColor('#F7F8FA')
          .onClick(() => {
            // 已有填写数据时二次确认，避免误删
            if (this.items.length > 0) {
              this.getUIContext().showAlertDialog({
                title: '取消打卡',
                message: '这一天已填写训练数据，取消后数据会一并删除。确定取消吗？',
                autoCancel: true,
                alignment: DialogAlignment.Center,
                primaryButton: {
                  value: '再想想',
                  action: () => {
                  }
                },
                secondaryButton: {
                  value: '确定取消',
                  fontColor: '#D93026',
                  action: () => {
                    this.cancelCheckIn();
                  }
                }
              });
              return;
            }
            this.cancelCheckIn();
          })
      }
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        this.topBar()

        if (!this.checked && this.isBackfill) {
          // 只有历史补录日才用大按钮打卡；今天未打卡时直接进编辑页
          this.bigCheckIn()
        } else if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40).color(Theme.PRIMARY)
          }
          .layoutWeight(1)
          .width('100%')
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

              this.partsSection()

              this.movesSection()

              this.bottomActions()
            }
            .width('100%')
            // 内容不足一屏时也保持顶部对齐（Scroll 默认会把不足一屏的内容居中）
            .constraintSize({ minHeight: '100%' })
            .padding({ left: 16, right: 16, top: 4, bottom: 24 })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)

      // 右上角轻提示：白色胶囊从右滑入，停留片刻或右滑消失
      // hitTestBehavior None：这层永不拦截触摸，否则会挡住顶栏的编辑/保存按钮
      Row() {
        Blank()
        Text(this.flashText)
          .fontSize(12)
          .fontColor('#1A1A1A')
          .backgroundColor(Color.White)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .border({ width: 1, color: '#14000000' })
          .opacity(this.flashShown ? 1 : 0)
          .translate({ x: this.flashShown ? 0 : 64 })
          .shadow({ radius: 14, color: '#26000000', offsetY: 4 })
          .gesture(PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart(() => {
              this.hideFlash();
            }))
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .margin({ top: 8 })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 路由目标包装：
 *
 * 注意：Navigation 的 navDestination 目标根容器必须是 NavDestination，
 * 否则路由跳转会失败。所以这里单独包一层，把表单本身 RecordEditView 放进去。
 */
@ComponentV2
export struct RecordEditPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  /** 离开守卫：子组件注入询问逻辑，返回手势在这里拦截 */
  private guard: LeaveGuard = new LeaveGuard();

  build() {
    NavDestination() {
      RecordEditView({ pathStack: this.pathStack, guard: this.guard })
    }
    .hideTitleBar(true)
    .backgroundColor(Theme.BG)
    .onBackPressed(() => this.guard.ask())
  }
}
