import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Theme } from '../common/Constants';
import { BackupService } from '../service/BackupService';
import { CheckInRepository } from '../repository/CheckInRepository';

/** 数据管理页：明文 JSON 备份的导出与导入 */
@ComponentV2
export struct DataManageView {
  @Local dayCount: number = 0;
  @Local busy: boolean = false;

  aboutToAppear(): void {
    this.refreshCount();
  }

  private async refreshCount(): Promise<void> {
    const dates: string[] = await CheckInRepository.listAllDates();
    this.dayCount = dates.length;
  }

  private stamp(): string {
    const d: Date = new Date();
    const p = (x: number): string => x < 10 ? `0${x}` : `${x}`;
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
  }

  /** 导出：弹系统保存框，把全部数据写成明文 JSON */
  private async doExport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const json: string = await BackupService.exportAll();
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [`fitdot-backup-${this.stamp()}.json`];
      const uris: string[] = await docPicker.save(opts);
      if (uris.length === 0) {
        return;
      }
      const file = await fileIo.open(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      await fileIo.write(file.fd, json);
      await fileIo.close(file.fd);
      this.toast('导出成功');
    } catch (e) {
      const err = e as Error;
      this.toast(`导出失败: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  /** 导入入口：先确认（覆盖式恢复） */
  private doImport(): void {
    this.getUIContext().showAlertDialog({
      title: '导入备份',
      message: '导入会覆盖当前全部数据，确定继续吗？',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '继续导入',
        fontColor: '#D93026',
        action: () => {
          this.pickAndImport();
        }
      }
    });
  }

  /** 选文件 → 读取 → 覆盖式导入 */
  private async pickAndImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      const uris: string[] = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      await fileIo.read(file.fd, buf);
      await fileIo.close(file.fd);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buf));
      const n: number = await BackupService.importAll(text);
      this.refreshCount();
      this.toast(`导入完成，共 ${n} 天`);
    } catch (e) {
      const err = e as Error;
      this.toast(`导入失败: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  actionRow(title: string, desc: string, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_PRIMARY)
        Text(desc)
          .fontSize(11)
          .fontColor(Theme.TEXT_SECONDARY)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(18)
        .fontColor(Theme.TEXT_SECONDARY)
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor('#F5F6F8')
    .onClick(() => {
      onTap();
    })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text(`已记录 ${this.dayCount} 天训练`)
          .fontSize(12)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Center)

        this.actionRow('导出备份', '保存明文 JSON 到手机，可传到电脑长期保存', (): void => {
          this.doExport();
        })

        this.actionRow('导入备份', '从 JSON 恢复（覆盖当前全部数据）', (): void => {
          this.doImport();
        })

        if (this.busy) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Theme.PRIMARY)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }
}
