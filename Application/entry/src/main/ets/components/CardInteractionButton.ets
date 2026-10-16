import { PagePaletteName, pageColor } from '../common/PagePaletteUi';

export type CardInteractionIcon = 'like' | 'dislike' | 'favorite';

/** Reactive inputs keep async interaction updates out of by-value Builder parameters. */
@Component
export struct CardInteractionButton {
  @Prop icon: CardInteractionIcon = 'like';
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop ready: boolean = false;
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop reducedMotion: boolean = true;
  onActivate: () => void = (): void => {};

  private tint(): Resource {
    return this.selected ? pageColor(this.palette, 'action') : pageColor(this.palette, 'ink');
  }

  @Builder
  private glyph() {
    // Pack 2: theme-tinted line symbols replace the old emoji (which ignored light/dark and read poorly).
    if (this.icon === 'like') {
      SymbolGlyph(this.selected ? $r('sys.symbol.hand_thumbsup_fill') : $r('sys.symbol.hand_thumbsup'))
        .fontSize(21).fontColor([this.tint()]).accessibilityLevel('no')
    } else if (this.icon === 'dislike') {
      SymbolGlyph(this.selected ? $r('sys.symbol.hand_thumbsdown_fill') : $r('sys.symbol.hand_thumbsdown'))
        .fontSize(21).fontColor([this.tint()]).accessibilityLevel('no')
    } else {
      SymbolGlyph(this.selected ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(21).fontColor([this.tint()]).accessibilityLevel('no')
    }
  }

  build() {
    Button() {
      Column({ space: 3 }) {
        this.glyph()
        Text(this.label).fontSize(11.5).fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.tint()).textAlign(TextAlign.Center).width('100%').maxLines(1)
      }.width('100%').justifyContent(FlexAlign.Center);
    }.type(ButtonType.Normal).height(52).padding(0).borderRadius(14)
      .backgroundColor(this.selected ? pageColor(this.palette, 'soft') : Color.Transparent)
      .opacity(this.ready ? 1 : 0.6)
      .animation({ duration: this.reducedMotion ? 0 : 180, curve: Curve.EaseOut })
      .focusable(true).accessibilitySelected(this.selected)
      .accessibilityText(this.label + (!this.ready ? '，操作处理中' : this.selected ? '，已选中，再点可取消' : ''))
      .onClick((): void => { if (this.ready) this.onActivate(); });
  }
}
