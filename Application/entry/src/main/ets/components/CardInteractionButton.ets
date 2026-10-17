/**
 * 【文件职责】卡片详情中的互动按钮（赞 / 踩 / 收藏）：图标、计数、选中与忙碌状态；点击事件由页面交给 CardInteractionController。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';

// 按钮类型。
export type CardInteractionIcon = 'like' | 'dislike' | 'favorite';

// 使用响应式属性（@Prop）接收状态，避免异步更新时 @Builder 按值传参拿不到最新值。
@Component
export struct CardInteractionButton {
  @Prop icon: CardInteractionIcon = 'like';
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop ready: boolean = false;
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop reducedMotion: boolean = true;
  onActivate: () => void = (): void => {};

  // 按钮颜色：选中时使用强调色。
  private tint(): Resource {
    return this.selected ? pageColor(this.palette, 'action') : pageColor(this.palette, 'ink');
  }

  // 绘制线条图标（随主题着色）。
  @Builder
  private glyph() {
    // 随主题着色的线条图标，替换了原来的 emoji（emoji 不随亮/暗色变化且辨识度差）。
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

  // 按钮布局：图标 + 计数，忙碌时禁用。
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
