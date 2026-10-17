/**
 * 【文件职责】发布页（CreateCardPage）专用的样式：按钮、选项、输入框、点评框（AttributeModifier）与页面背景组件。
 * AttributeModifier 约定：applyNormalAttribute 正常样式；applyDisabledAttribute 禁用时半透明；applyPressedAttribute 按下时变暗。
 */
import { PagePaletteName, pageColor } from './PagePaletteUi';

// 发布页底部弹出面板的种类：评分 / 补充信息 / 店铺 / 图片 / 草稿。
export type CreateSheetKind = 'SCORE' | 'EXTRAS' | 'MERCHANT' | 'PHOTOS' | 'DRAFTS';

// 发布页按钮样式（主要 / 次要 / 弱化 / 危险）。
export class CreateActionStyle implements AttributeModifier<ButtonAttribute> {
  private palette: PagePaletteName;
  private kind: 'PRIMARY' | 'SECONDARY' | 'QUIET' | 'DANGER';
  constructor(kind: 'PRIMARY' | 'SECONDARY' | 'QUIET' | 'DANGER' = 'SECONDARY', palette: PagePaletteName = 'CREATE') { this.palette = palette; this.kind = kind; }
  // 正常状态下的按钮样式（颜色、圆角、内边距、字号等）。
  applyNormalAttribute(button: ButtonAttribute): void {
    const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
    button.type(ButtonType.Normal).constraintSize({ minHeight: 48 }).borderRadius(14)
      .fontSize(14).fontWeight(this.kind === 'PRIMARY' ? FontWeight.Bold : FontWeight.Medium).labelStyle(label).focusable(true).opacity(1)
      .padding({ left: 12, right: 12 })
      // 主要按钮使用深色背景 + 画布色文字，在亮色和暗色主题下都清晰可读。
      .backgroundColor(this.kind === 'PRIMARY' ? pageColor(this.palette, 'action') :
        this.kind === 'QUIET' ? Color.Transparent : pageColor(this.palette, 'surface'))
      .fontColor(this.kind === 'PRIMARY' ? pageColor(this.palette, 'canvas') :
        this.kind === 'DANGER' ? pageColor(this.palette, 'error') : pageColor(this.palette, 'action'))
      .border({ width: this.kind === 'PRIMARY' || this.kind === 'QUIET' ? 0 : 1.2,
        color: this.kind === 'SECONDARY' ? pageColor(this.palette, 'action') : pageColor(this.palette, 'line'),
        style: BorderStyle.Dashed });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.82); }
}

// 发布页单选项样式（选中 / 未选中）。
export class CreateChoiceStyle implements AttributeModifier<ButtonAttribute> {
  private palette: PagePaletteName;
  private selected: boolean;
  constructor(selected: boolean, palette: PagePaletteName = 'CREATE') { this.palette = palette; this.selected = selected; }
  // 正常状态下的按钮样式（颜色、圆角、内边距、字号等）。
  applyNormalAttribute(button: ButtonAttribute): void {
    const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
    button.type(ButtonType.Normal).constraintSize({ minHeight: 48 }).fontSize(15)
      .fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium).labelStyle(label)
      .padding({ left: 8, right: 8 }).borderRadius(12).focusable(true).opacity(1)
      .backgroundColor(this.selected ? pageColor(this.palette, 'gold') : Color.Transparent)
      .fontColor(this.selected ? pageColor(this.palette, 'on_gold') : pageColor(this.palette, 'muted'))
      .border({ width: 0 }).accessibilitySelected(this.selected);
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.82); }
}

// 发布页输入框样式（inline=true 为行内紧凑样式）。
export class CreateInputStyle implements AttributeModifier<TextInputAttribute> {
  private palette: PagePaletteName;
  private inline: boolean;
  constructor(inline: boolean = false, palette: PagePaletteName = 'CREATE') { this.palette = palette; this.inline = inline; }
  // 正常状态下的输入框样式（颜色、圆角、内边距、字号等）。
  applyNormalAttribute(input: TextInputAttribute): void {
    input.fontSize(15).fontColor(pageColor(this.palette, 'ink')).placeholderColor(pageColor(this.palette, 'muted'))
      .caretColor(pageColor(this.palette, 'action')).backgroundColor(this.inline ? Color.Transparent : pageColor(this.palette, 'canvas'))
      .textAlign(this.inline ? TextAlign.End : TextAlign.Start).borderRadius(this.inline ? 0 : 12)
      .padding({ left: this.inline ? 4 : 12, right: this.inline ? 0 : 12 }).border({ width: 0 });
  }
}

// 发布页多行点评框样式。
export class CreateNoteStyle implements AttributeModifier<TextAreaAttribute> {
  private palette: PagePaletteName;
  constructor(palette: PagePaletteName = 'CREATE') { this.palette = palette;}
  // 正常状态下的多行输入框样式（颜色、圆角、内边距、字号等）。
  applyNormalAttribute(input: TextAreaAttribute): void {
    input.fontSize(15).fontColor(pageColor(this.palette, 'ink')).placeholderColor(pageColor(this.palette, 'muted'))
      .caretColor(pageColor(this.palette, 'action')).backgroundColor(pageColor(this.palette, 'surface'))
      .borderRadius(16).padding(12).border({ width: 1, color: pageColor(this.palette, 'line') });
  }
}

// 发布页背景（渐变）。
@Component
export struct CreateCardBackdrop {
  @Prop palette: PagePaletteName = 'CREATE';
  // 背景渐变色（随色板变化）。
  private gradient(): LinearGradient {
    const colors: Array<[ResourceColor, number]> = [
      [pageColor(this.palette, 'header'), 0], [pageColor(this.palette, 'header_fade'), 0.58],
      [pageColor(this.palette, 'canvas'), 1]
    ];
    const gradient: LinearGradient = { direction: GradientDirection.Bottom, colors };
    return gradient;
  }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {}.width('100%').height(270).linearGradient(this.gradient())
        .expandSafeArea([], [])
      Circle().width(220).height(220).fill(pageColor(this.palette, 'glow')).opacity(0.3)
        .translate({ x: 80, y: -90 })
      Circle().width(108).height(108).fill(pageColor(this.palette, 'glow')).opacity(0.18)
        .translate({ x: -240, y: 88 })
      Column() {}.width('100%').height(48)
        .linearGradient({ direction: GradientDirection.Bottom, colors: [[pageColor(this.palette, 'header'), 0], [pageColor(this.palette, 'header_clear'), 1]] });
    }.width('100%').height('100%').clip(true).backgroundColor(pageColor(this.palette, 'canvas'))
      .expandSafeArea([], [])
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
}
