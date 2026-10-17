/**
 * 【文件职责】“笔记”风格页面（详情、举报、好友等）共用的面板转场、按钮与输入框样式和背景组件。
 */
import { PagePaletteName, pageColor } from './PagePaletteUi';

// 面板出现/消失的转场；reduced=true（减弱动态效果）时只做淡入淡出。
export function notePanelTransition(reduced: boolean): TransitionEffect {
  if (reduced) return TransitionEffect.IDENTITY;
  const enter: AnimateParam = { duration: 240, curve: Curve.EaseOut };
  const exit: AnimateParam = { duration: 160, curve: Curve.EaseOut };
  const shift: TranslateOptions = { y: 24 };
  return TransitionEffect.asymmetric(TransitionEffect.opacity(0).animation(enter)
    .combine(TransitionEffect.translate(shift)), TransitionEffect.opacity(0).animation(exit));
}

// 笔记风格按钮（primary 为主要按钮）。
export class NoteActionStyle implements AttributeModifier<ButtonAttribute> {
  private palette: PagePaletteName;
  private primary: boolean;
  constructor(primary: boolean = false, palette: PagePaletteName = 'NOTE') { this.palette = palette; this.primary = primary; }
  // 正常状态下的按钮样式（颜色、圆角、内边距、字号等）。
  applyNormalAttribute(button: ButtonAttribute): void {
    const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
    button.type(ButtonType.Normal).constraintSize({ minHeight: 48 }).borderRadius(16).fontSize(15)
      .fontWeight(FontWeight.Medium).labelStyle(label).focusable(true).opacity(1)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.primary ? pageColor(this.palette, 'gold') : pageColor(this.palette, 'surface'))
      .fontColor(this.primary ? pageColor(this.palette, 'on_gold') : pageColor(this.palette, 'action'))
      .border({ width: this.primary ? 0 : 1, color: pageColor(this.palette, 'line') });
  }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.82); }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

// 笔记风格输入框。
export class NoteInputStyle implements AttributeModifier<TextInputAttribute> {
  private palette: PagePaletteName;
  constructor(palette: PagePaletteName = 'NOTE') { this.palette = palette;}
  // 正常状态下的输入框样式（颜色、圆角、内边距、字号等）。
  applyNormalAttribute(input: TextInputAttribute): void {
    input.fontSize(16).fontColor(pageColor(this.palette, 'ink')).placeholderColor(pageColor(this.palette, 'muted'))
      .caretColor(pageColor(this.palette, 'action')).backgroundColor(pageColor(this.palette, 'canvas'))
      .borderRadius(18).padding({ left: 14, right: 14 }).border({ width: 1, color: pageColor(this.palette, 'line') });
  }
}

// 笔记风格页面背景（渐变）。
@Component
export struct WarmNoteBackdrop {
  @Prop palette: PagePaletteName = 'NOTE';
  // 背景渐变色（随色板变化）。
  private gradient(): LinearGradient {
    const colors: Array<[ResourceColor, number]> = [
      [pageColor(this.palette, 'header'), 0], [pageColor(this.palette, 'header_fade'), 0.5], [pageColor(this.palette, 'canvas'), 1]
    ];
    const gradient: LinearGradient = { direction: GradientDirection.Bottom, colors };
    return gradient;
  }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {}.width('100%').height(280).linearGradient(this.gradient())
        .expandSafeArea([], []);
      Circle().width(200).height(200).fill(pageColor(this.palette, 'glow')).opacity(0.13).translate({ x: 80, y: -100 });
      Column() {}.width('100%').height(48)
        .linearGradient({ direction: GradientDirection.Bottom, colors: [[pageColor(this.palette, 'header'), 0], [pageColor(this.palette, 'header_clear'), 1]] });
    }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas')).clip(true)
      .expandSafeArea([], [])
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
  }
}
