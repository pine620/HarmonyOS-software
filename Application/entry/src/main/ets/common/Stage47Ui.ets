function actionBase(button: ButtonAttribute): void {
  const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
  button.type(ButtonType.Normal).fontSize(14).fontWeight(FontWeight.Medium)
    .borderRadius(12).padding({ left: 14, right: 14 })
    .constraintSize({ minHeight: 48 }).labelStyle(label).opacity(1);
}

export class SecondaryActionStyle implements AttributeModifier<ButtonAttribute> {
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
      .border({ width: 1, color: $r('app.color.line') });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class QuietActionStyle implements AttributeModifier<ButtonAttribute> {
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor(Color.Transparent).fontColor($r('app.color.action_text'))
      .border({ width: 0 });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class PrimaryActionStyle implements AttributeModifier<ButtonAttribute> {
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
      .border({ width: 0 });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class DangerActionStyle implements AttributeModifier<ButtonAttribute> {
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor($r('app.color.surface')).fontColor($r('app.color.danger'))
      .border({ width: 1, color: $r('app.color.line') });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class ChoiceActionStyle implements AttributeModifier<ButtonAttribute> {
  private selected: boolean;
  constructor(selected: boolean) { this.selected = selected; }
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor(this.selected ? $r('app.color.accent_soft') : $r('app.color.surface'))
      .fontColor(this.selected ? $r('app.color.action_text') : $r('app.color.ink'))
      .border({ width: 1, color: this.selected ? $r('app.color.action_text') : $r('app.color.line') })
      .accessibilitySelected(this.selected);
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class FormInputStyle implements AttributeModifier<TextInputAttribute> {
  applyNormalAttribute(input: TextInputAttribute): void {
    input.fontSize(15).fontColor($r('app.color.ink')).placeholderColor($r('app.color.muted'))
      .caretColor($r('app.color.action_text')).backgroundColor($r('app.color.canvas'))
      .borderRadius(12).padding({ left: 12, right: 12 });
  }
}

export class FormNoteStyle implements AttributeModifier<TextAreaAttribute> {
  applyNormalAttribute(input: TextAreaAttribute): void {
    input.fontSize(15).fontColor($r('app.color.ink')).placeholderColor($r('app.color.muted'))
      .caretColor($r('app.color.action_text')).backgroundColor($r('app.color.canvas'))
      .borderRadius(12).padding(12);
  }
}

interface UiErrorDetail {
  code?: string | number;
  message?: string;
}

export function featureUnavailable(error: Object): boolean {
  if (error === null || error === undefined) return false;
  const detail: UiErrorDetail = error as UiErrorDetail;
  return detail.code === 'FEATURE_NOT_READY';
}

export function stage47ErrorText(error: Object, fallback: string): string {
  if (error === null || error === undefined) return fallback;
  const detail: UiErrorDetail = error as UiErrorDetail;
  const message: string = error instanceof Error ? error.message :
    typeof detail.message === 'string' ? detail.message : '';
  if (detail.code === 'FEATURE_NOT_READY') return '此功能暂未开放，请稍后再试。';
  if (detail.code === 3007009 || detail.code === '3007009' || message.includes('3007009') ||
    message.toLowerCase().includes('too many requests') || message.toLowerCase().includes('system is too busy')) {
    return '服务繁忙，请稍后再试。';
  }
  if (message.includes('Call handler error') || message.includes('Cannot find module')) {
    return '服务暂时不可用，请稍后重试。';
  }
  return message.length > 0 ? message : fallback;
}
