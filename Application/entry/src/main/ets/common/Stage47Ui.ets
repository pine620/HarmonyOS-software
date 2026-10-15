import { PagePaletteName, pageColor } from './PagePaletteUi';

type ActionPalette = PagePaletteName | 'DEFAULT';

function actionBase(button: ButtonAttribute): void {
  const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
  button.type(ButtonType.Normal).fontSize(14).fontWeight(FontWeight.Medium)
    .borderRadius(24).padding({ left: 14, right: 14 })
    .constraintSize({ minHeight: 48 }).labelStyle(label).opacity(1).focusable(true);
}

export class SecondaryActionStyle implements AttributeModifier<ButtonAttribute> {
  private palette: ActionPalette;
  constructor(palette: ActionPalette = 'DEFAULT') { this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor((this.palette === 'DEFAULT' ? $r('app.color.surface') : pageColor(this.palette, 'surface'))).fontColor((this.palette === 'DEFAULT' ? $r('app.color.ink') : pageColor(this.palette, 'ink')))
      .border({ width: 1, color: (this.palette === 'DEFAULT' ? $r('app.color.line') : pageColor(this.palette, 'line')) });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class QuietActionStyle implements AttributeModifier<ButtonAttribute> {
  private palette: ActionPalette;
  constructor(palette: ActionPalette = 'DEFAULT') { this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor(Color.Transparent).fontColor((this.palette === 'DEFAULT' ? $r('app.color.action_text') : pageColor(this.palette, 'action')))
      .border({ width: 0 });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class PrimaryActionStyle implements AttributeModifier<ButtonAttribute> {
  private palette: ActionPalette;
  constructor(palette: ActionPalette = 'DEFAULT') { this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor((this.palette === 'DEFAULT' ? $r('app.color.accent_action') : pageColor(this.palette, 'gold'))).fontColor((this.palette === 'DEFAULT' ? $r('app.color.on_accent_action') : pageColor(this.palette, 'on_gold')))
      .border({ width: 0 });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class DangerActionStyle implements AttributeModifier<ButtonAttribute> {
  private palette: ActionPalette;
  constructor(palette: ActionPalette = 'DEFAULT') { this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor((this.palette === 'DEFAULT' ? $r('app.color.surface') : pageColor(this.palette, 'surface'))).fontColor((this.palette === 'DEFAULT' ? $r('app.color.danger') : pageColor(this.palette, 'error')))
      .border({ width: 1, color: (this.palette === 'DEFAULT' ? $r('app.color.line') : pageColor(this.palette, 'line')) });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class ChoiceActionStyle implements AttributeModifier<ButtonAttribute> {
  private selected: boolean;
  private palette: ActionPalette;
  constructor(selected: boolean, palette: ActionPalette = 'DEFAULT') { this.selected = selected; this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    actionBase(button);
    button.backgroundColor(this.selected ? (this.palette === 'DEFAULT' ? $r('app.color.accent_soft') : pageColor(this.palette, 'soft')) : (this.palette === 'DEFAULT' ? $r('app.color.surface') : pageColor(this.palette, 'surface')))
      .fontColor(this.selected ? (this.palette === 'DEFAULT' ? $r('app.color.action_text') : pageColor(this.palette, 'action')) : (this.palette === 'DEFAULT' ? $r('app.color.ink') : pageColor(this.palette, 'ink')))
      .border({ width: 1, color: this.selected ? (this.palette === 'DEFAULT' ? $r('app.color.action_text') : pageColor(this.palette, 'action')) : (this.palette === 'DEFAULT' ? $r('app.color.line') : pageColor(this.palette, 'line')) })
      .accessibilitySelected(this.selected);
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
}

export class FormInputStyle implements AttributeModifier<TextInputAttribute> {
  private palette: ActionPalette;
  constructor(palette: ActionPalette = 'DEFAULT') { this.palette = palette; }
  applyNormalAttribute(input: TextInputAttribute): void {
    input.fontSize(15).fontColor((this.palette === 'DEFAULT' ? $r('app.color.ink') : pageColor(this.palette, 'ink'))).placeholderColor((this.palette === 'DEFAULT' ? $r('app.color.muted') : pageColor(this.palette, 'muted')))
      .caretColor((this.palette === 'DEFAULT' ? $r('app.color.action_text') : pageColor(this.palette, 'action'))).backgroundColor((this.palette === 'DEFAULT' ? $r('app.color.canvas') : pageColor(this.palette, 'canvas')))
      .borderRadius(16).padding({ left: 12, right: 12 });
  }
}

export class FormNoteStyle implements AttributeModifier<TextAreaAttribute> {
  private palette: ActionPalette;
  constructor(palette: ActionPalette = 'DEFAULT') { this.palette = palette; }
  applyNormalAttribute(input: TextAreaAttribute): void {
    input.fontSize(15).fontColor((this.palette === 'DEFAULT' ? $r('app.color.ink') : pageColor(this.palette, 'ink'))).placeholderColor((this.palette === 'DEFAULT' ? $r('app.color.muted') : pageColor(this.palette, 'muted')))
      .caretColor((this.palette === 'DEFAULT' ? $r('app.color.action_text') : pageColor(this.palette, 'action'))).backgroundColor((this.palette === 'DEFAULT' ? $r('app.color.canvas') : pageColor(this.palette, 'canvas')))
      .borderRadius(16).padding(12);
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

export function invalidatesProtectedPage(error: Object): boolean {
  if (error === null || error === undefined) return false;
  const detail: UiErrorDetail = error as UiErrorDetail;
  return ['ADMIN_REQUIRED', 'ALREADY_RESOLVED', 'FORBIDDEN', 'ACCESS_DENIED', 'AUTH_REQUIRED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DELETED',
    'CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'NOT_FOUND', 'FEATURE_NOT_READY', 'CURSOR_STALE', 'CONFLICT', 'STALE_VERSION'].includes(String(detail.code || ''));
}

export function stage47ErrorText(error: Object, fallback: string): string {
  if (error === null || error === undefined) return fallback;
  const detail: UiErrorDetail = error as UiErrorDetail;
  const message: string = error instanceof Error ? error.message :
    typeof detail.message === 'string' ? detail.message : '';
  if (detail.code === 'FEATURE_NOT_READY') return message.length > 0 ? message : '此功能尚未完成上线验证。';
  if (detail.code === 3007009 || detail.code === '3007009' || message.includes('3007009') ||
    message.toLowerCase().includes('too many requests') || message.toLowerCase().includes('system is too busy')) {
    return '服务繁忙，请稍后再试。';
  }
  if (message.includes('Call handler error') || message.includes('Cannot find module')) {
    return '服务暂时不可用，请稍后重试。';
  }
  return message.length > 0 ? message : fallback;
}
