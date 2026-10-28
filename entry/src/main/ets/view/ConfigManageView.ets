import { Theme } from '../common/Constants';
import { AppStore } from '../common/AppStore';
import { ConfigService, MoveGroup } from '../service/ConfigService';

/**
 * 配置管理：分层展示训练部位与动作。
 * 第一层：部位卡片（可展开/收起，头部带「动作数 / 自重数」摘要）；
 * 第二层：部位下的动作行（动作名 + 自重/负重标记 + 删除）。
 * 自重动作：记录时不填重量，只填次数；以后加负重了把标签点成「负重」即可。
 * 改动即时写入 Preferences，并通过 configVersion 通知记录页，无需重启。
 */
@ComponentV2
export struct ConfigManageView {
  @Local groups: MoveGroup[] = [];
  /** 自重动作清单（动作名集合） */
  @Local bodyweight: string[] = [];
  /** 当前展开的部位名列表 */
  @Local expanded: string[] = [];
  /** 正在输入的新动作名（按部位独立） */
  @Local moveInputs: Map<string, string> = new Map<string, string>();
  @Local newPart: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.groups = await ConfigService.load(getContext(this));
    this.bodyweight = await ConfigService.loadBodyweight(getContext(this));
  }

  private async persist(): Promise<void> {
    await ConfigService.save(getContext(this), this.groups);
    await ConfigService.saveBodyweight(getContext(this), this.bodyweight);
    // 通知训练页等重新读配置，改动即时生效
    AppStore.get().markConfigDirty();
  }

  private cloneGroups(): MoveGroup[] {
    const out: MoveGroup[] = [];
    for (const g of this.groups) {
      out.push({ part: g.part, moves: g.moves.slice() });
    }
    return out;
  }

  /** 该动作当前是否按自重记录 */
  private isBodyweight(move: string): boolean {
    return this.bodyweight.indexOf(move) >= 0;
  }

  /** 部位内自重动作数 */
  private bwCount(g: MoveGroup): number {
    let n: number = 0;
    for (const m of g.moves) {
      if (this.isBodyweight(m)) {
        n++;
      }
    }
    return n;
  }

  private totalMoves(): number {
    let n: number = 0;
    for (const g of this.groups) {
      n += g.moves.length;
    }
    return n;
  }

  private totalBw(): number {
    let n: number = 0;
    for (const g of this.groups) {
      n += this.bwCount(g);
    }
    return n;
  }

  private isExpanded(part: string): boolean {
    return this.expanded.indexOf(part) >= 0;
  }

  private isAllExpanded(): boolean {
    return this.groups.length > 0 && this.expanded.length >= this.groups.length;
  }

  private toggleExpand(part: string): void {
    const list: string[] = this.expanded.slice();
    const idx: number = list.indexOf(part);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(part);
    }
    this.expanded = list;
  }

  /** 全部展开 / 全部收起 */
  private toggleAll(): void {
    if (this.isAllExpanded()) {
      this.expanded = [];
      return;
    }
    const list: string[] = [];
    for (const g of this.groups) {
      list.push(g.part);
    }
    this.expanded = list;
  }

  /** 切换动作的自重/负重标记 */
  private toggleBodyweight(move: string): void {
    const list: string[] = this.bodyweight.slice();
    const idx: number = list.indexOf(move);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(move);
    }
    this.bodyweight = list;
    this.persist();
  }

  private removeMove(part: string, move: string): void {
    const list: MoveGroup[] = this.cloneGroups();
    for (const g of list) {
      if (g.part !== part) {
        continue;
      }
      const idx: number = g.moves.indexOf(move);
      if (idx >= 0) {
        g.moves.splice(idx, 1);
      }
    }
    this.groups = list;
    this.persist();
  }

  private addMove(part: string): void {
    const name: string = (this.moveInputs.get(part) ?? '').trim();
    if (name.length === 0) {
      return;
    }
    const list: MoveGroup[] = this.cloneGroups();
    for (const g of list) {
      if (g.part === part && g.moves.indexOf(name) < 0) {
        g.moves.push(name);
      }
    }
    this.groups = list;
    const inputs: Map<string, string> = new Map<string, string>(this.moveInputs);
    inputs.set(part, '');
    this.moveInputs = inputs;
    this.persist();
  }

  private addPart(): void {
    const name: string = this.newPart.trim();
    if (name.length === 0) {
      return;
    }
    for (const g of this.groups) {
      if (g.part === name) {
        this.newPart = '';
        return;
      }
    }
    const list: MoveGroup[] = this.cloneGroups();
    list.push({ part: name, moves: [] });
    this.groups = list;
    this.newPart = '';
    // 新部位自动展开，方便接着加动作
    this.expanded = this.expanded.concat(name);
    this.persist();
  }

  /** 部位卡片：头部摘要 + 展开后的动作列表与添加框 */
  @Builder
  partCard(g: MoveGroup) {
    Column() {
      // ---- 头部：点一下展开/收起 ----
      Row({ space: 8 }) {
        Text(g.part)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_PRIMARY)
        Blank()
        Text(`${g.moves.length} 个动作`)
          .fontSize(11)
          .fontColor(Theme.TEXT_SECONDARY)
        Text(this.isExpanded(g.part) ? '▾' : '▸')
          .fontSize(14)
          .fontColor(Theme.TEXT_SECONDARY)
          .width(22)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(48)
      .padding({ left: 14, right: 10 })
      .onClick(() => {
        this.toggleExpand(g.part);
      })

      if (this.isExpanded(g.part)) {
        Divider()
          .strokeWidth(0.5)
          .color(Theme.DIVIDER)

        if (g.moves.length === 0) {
          Text('还没有动作，在下面添加一个')
            .fontSize(12)
            .fontColor(Theme.TEXT_SECONDARY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 16, bottom: 4 })
        }

        // ---- 第二层：动作行 ----
        ForEach(g.moves, (m: string) => {
          Row({ space: 8 }) {
            Text(m)
              .fontSize(13)
              .fontColor(Theme.TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.isBodyweight(m) ? '自重' : '负重')
              .fontSize(10)
              .fontColor(this.isBodyweight(m) ? Color.White : Theme.TEXT_SECONDARY)
              .backgroundColor(this.isBodyweight(m) ? Theme.PRIMARY : '#E8EBEF')
              .height(20)
              .padding({ left: 8, right: 8 })
              .borderRadius(10)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.toggleBodyweight(m);
              })
            Text('×')
              .fontSize(15)
              .fontColor(Theme.TEXT_SECONDARY)
              .width(28)
              .height(28)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.removeMove(g.part, m);
              })
          }
          .width('100%')
          .height(40)
          .padding({ left: 14, right: 8 })
        }, (m: string) => `${m}:${this.isBodyweight(m)}`)

        // ---- 添加动作 ----
        Row({ space: 8 }) {
          TextInput({ placeholder: `给「${g.part}」添加动作`, text: this.moveInputs.get(g.part) ?? '' })
            .fontSize(12)
            .layoutWeight(1)
            .height(34)
            .backgroundColor('#F5F6F8')
            .borderRadius(8)
            .onChange((value: string) => {
              const inputs: Map<string, string> = new Map<string, string>(this.moveInputs);
              inputs.set(g.part, value);
              this.moveInputs = inputs;
            })
            .onSubmit(() => {
              this.addMove(g.part);
            })
          Text('添加')
            .fontSize(12)
            .fontColor(Theme.PRIMARY)
            .height(34)
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14 })
            .borderRadius(8)
            .backgroundColor('#EDF0F4')
            .onClick(() => {
              this.addMove(g.part);
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 12 })
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(Theme.CARD_BG)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // ---- 汇总 + 全部展开/收起 ----
        Row({ space: 8 }) {
          Text(`共 ${this.totalMoves()} 个动作 · 自重 ${this.totalBw()} 个`)
            .fontSize(12)
            .fontColor(Theme.TEXT_SECONDARY)
            .layoutWeight(1)
          Text(this.isAllExpanded() ? '收起全部' : '展开全部')
            .fontSize(12)
            .fontColor(Theme.PRIMARY)
            .padding({ left: 4, right: 4 })
            .onClick(() => {
              this.toggleAll();
            })
        }
        .width('100%')

        Text('点部位卡片展开；点动作后的「自重 / 负重」切换记录方式')
          .fontSize(11)
          .fontColor(Theme.TEXT_SECONDARY)
          .width('100%')
          .padding({ left: 4, right: 4 })

        ForEach(this.groups, (g: MoveGroup) => {
          this.partCard(g)
        }, (g: MoveGroup) => `${g.part}:${g.moves.join('|')}:${this.bwCount(g)}:${this.isExpanded(g.part) ? 1 : 0}`)

        // ---- 添加部位 ----
        Row({ space: 8 }) {
          TextInput({ placeholder: '添加训练部位', text: this.newPart })
            .fontSize(13)
            .layoutWeight(1)
            .height(42)
            .backgroundColor(Theme.CARD_BG)
            .borderRadius(12)
            .onChange((value: string) => {
              this.newPart = value;
            })
            .onSubmit(() => {
              this.addPart();
            })
          Text('＋ 添加')
            .fontSize(13)
            .fontColor(Theme.PRIMARY)
            .height(42)
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14 })
            .borderRadius(12)
            .backgroundColor(Theme.CARD_BG)
            .onClick(() => {
              this.addPart();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }
}
