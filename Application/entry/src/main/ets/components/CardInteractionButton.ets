import { PagePaletteName, pageColor } from '../common/PagePaletteUi';

/** Reactive inputs keep async interaction updates out of by-value Builder parameters. */
@Component
export struct CardInteractionButton {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop ready: boolean = false;
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop reducedMotion: boolean = true;
  onActivate: () => void = (): void => {};

  build() {
    Button() {
      Column({ space: 6 }) {
        Text(this.icon).fontSize(26).opacity(this.selected ? 1 : 0.38).accessibilityLevel('no');
        Text(this.label).fontSize(13).fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.selected ? pageColor(this.palette, 'action') : pageColor(this.palette, 'ink'))
          .textAlign(TextAlign.Center).width('100%');
      }.width('100%').padding({ top: 10, bottom: 10, left: 2, right: 2 });
    }.type(ButtonType.Normal).constraintSize({ minHeight: 68 }).padding(0).borderRadius(16)
      .backgroundColor(this.selected ? pageColor(this.palette, 'soft') : Color.Transparent)
      .animation({ duration: this.reducedMotion ? 0 : 180, curve: Curve.EaseOut })
      .focusable(true).accessibilitySelected(this.selected)
      .accessibilityText(this.label + (!this.ready ? '，操作处理中' : this.selected ? '，已选中，再点可取消' : ''))
      .onClick((): void => { if (this.ready) this.onActivate(); });
  }
}
