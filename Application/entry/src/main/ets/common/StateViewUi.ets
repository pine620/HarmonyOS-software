import { PagePaletteName, pageColor } from './PagePaletteUi';

/**
 * 【文件职责】全 App 统一的空状态 / 加载中 / 出错视图组件，颜色随页面色板变化。
 */
// 状态类型。
export type StateViewKind = 'EMPTY' | 'LOADING' | 'ERROR';
// 状态图标。
export type StateViewIcon = 'food' | 'message' | 'search' | 'offline' | 'card' | 'list';

// 状态视图组件：kind 决定显示内容，可带标题、说明与“重试”按钮。
@Component
export struct StateView {
  @Prop kind: StateViewKind = 'EMPTY';
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop icon: StateViewIcon = 'food';
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop actionLabel: string = '';
  // 加载中时显示的骨架行数（0 = 只显示进度条）。
  @Prop skeletonRows: number = 2;
  onAction: () => void = (): void => {};

  // 绘制状态图标。
  @Builder
  private symbol(size: number) {
    if (this.icon === 'message') {
      SymbolGlyph($r('sys.symbol.message')).fontSize(size).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no')
    } else if (this.icon === 'search') {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(size).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no')
    } else if (this.icon === 'offline') {
      SymbolGlyph($r('sys.symbol.wifi_slash')).fontSize(size).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no')
    } else if (this.icon === 'card') {
      SymbolGlyph($r('sys.symbol.picture')).fontSize(size).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no')
    } else if (this.icon === 'list') {
      SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(size).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no')
    } else {
      SymbolGlyph($r('sys.symbol.fork_knife')).fontSize(size).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no')
    }
  }

  // 骨架行的索引数组（ForEach 使用）。
  private skeletonIndexes(): Array<number> {
    const indexes: Array<number> = [];
    for (let index = 0; index < Math.max(0, Math.min(4, this.skeletonRows)); index++) indexes.push(index);
    return indexes;
  }

  // 一行骨架占位。
  @Builder
  private skeletonCard() {
    Row({ space: 10 }) {
      Column().width(54).height(54).borderRadius(10).backgroundColor(pageColor(this.palette, 'soft'))
      Column({ space: 8 }) {
        Column().width('72%').height(10).borderRadius(5).backgroundColor(pageColor(this.palette, 'soft'))
        Column().width('46%').height(10).borderRadius(5).backgroundColor(pageColor(this.palette, 'soft'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').padding(10).borderRadius(14).backgroundColor(pageColor(this.palette, 'surface'))
    .border({ width: 1, color: pageColor(this.palette, 'line') })
    .accessibilityLevel('no')
  }

  build() {
    if (this.kind === 'LOADING') {
      Column({ space: 10 }) {
        ForEach(this.skeletonIndexes(), (_value: number): void => {
          this.skeletonCard()
        }, (value: number): string => value.toString())
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(pageColor(this.palette, 'action'))
          Text(this.title.length > 0 ? this.title : '正在加载…').fontSize(13).fontColor(pageColor(this.palette, 'muted'))
        }.justifyContent(FlexAlign.Center)
      }
      .width('100%').padding({ left: 4, right: 4 }).justifyContent(FlexAlign.Center)
      .accessibilityGroup(true).accessibilityText(this.title.length > 0 ? this.title : '正在加载')
    } else {
      Column({ space: 10 }) {
        Stack() {
          this.symbol(30)
        }
        .width(64).height(64).borderRadius(32).backgroundColor(pageColor(this.palette, 'soft'))
        .border({ width: 1.6, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed })
        Text(this.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
          .textAlign(TextAlign.Center)
        if (this.hint.length > 0) {
          Text(this.hint).fontSize(13).lineHeight(20).fontColor(pageColor(this.palette, 'muted'))
            .textAlign(TextAlign.Center).constraintSize({ maxWidth: 280 })
        }
        if (this.actionLabel.length > 0) {
          Button({ type: ButtonType.Capsule, stateEffect: true }) {
            Row({ space: 6 }) {
              if (this.kind === 'ERROR') {
                SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(15)
                  .fontColor([pageColor(this.palette, 'canvas')]).accessibilityLevel('no')
              }
              Text(this.actionLabel).fontSize(14).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'canvas'))
            }
          }
          .height(40).padding({ left: 18, right: 18 }).margin({ top: 2 })
          .backgroundColor(pageColor(this.palette, 'action'))
          .accessibilityText(this.actionLabel).onClick((): void => this.onAction())
        }
      }
      .width('100%').padding(16).justifyContent(FlexAlign.Center)
    }
  }
}

