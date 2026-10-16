import { PagePaletteName, pageColor } from './PagePaletteUi';

// Pack 2 (2026-10-15): one empty / loading / error component for the whole app, tinted by page palette.
export type StateViewKind = 'EMPTY' | 'LOADING' | 'ERROR';
export type StateViewIcon = 'food' | 'message' | 'search' | 'offline' | 'card' | 'list';

@Component
export struct StateView {
  @Prop kind: StateViewKind = 'EMPTY';
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop icon: StateViewIcon = 'food';
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop actionLabel: string = '';
  // Skeleton rows shown while loading (0 = only the progress line).
  @Prop skeletonRows: number = 2;
  onAction: () => void = (): void => {};

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

  private skeletonIndexes(): Array<number> {
    const indexes: Array<number> = [];
    for (let index = 0; index < Math.max(0, Math.min(4, this.skeletonRows)); index++) indexes.push(index);
    return indexes;
  }

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

// Shown above existing content when a refresh failed but older content is still on screen.
@Component
export struct WeakNetworkBanner {
  @Prop text: string = '网络较慢，内容可能不是最新';
  onRetry: () => void = (): void => {};

  build() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.wifi_slash')).fontSize(15).fontColor([$r('app.color.danger')]).accessibilityLevel('no')
      Text(this.text).fontSize(12).lineHeight(18).fontColor($r('app.color.danger')).layoutWeight(1).maxLines(2)
      Text('重试').fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.danger'))
        .padding({ left: 8, right: 4, top: 4, bottom: 4 }).onClick((): void => this.onRetry())
    }
    .width('100%').padding({ left: 12, right: 8, top: 8, bottom: 8 }).borderRadius(14)
    .backgroundColor($r('app.color.danger_soft'))
    .accessibilityGroup(true).accessibilityText(this.text + '，点按重试')
    .onClick((): void => this.onRetry())
  }
}
