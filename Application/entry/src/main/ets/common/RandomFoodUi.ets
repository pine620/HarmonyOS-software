import { PagePaletteName, pageColor } from './PagePaletteUi';
import { accessibility } from '@kit.AccessibilityKit';
import { CloudBusinessError } from '../service/CloudReadErrors';

export type RandomFoodMotionKind = 'REVEAL' | 'CONFIRM' | 'RECORD';

// Motion never owns a request, a saved choice, or an interaction lock.
export function randomFoodTransition(enabled: boolean, kind: RandomFoodMotionKind): TransitionEffect {
  if (!enabled) return TransitionEffect.IDENTITY;
  const duration: number = kind === 'REVEAL' ? 220 : kind === 'CONFIRM' ? 180 : 160;
  const animation: AnimateParam = { duration, curve: Curve.EaseOut };
  const translation: TranslateOptions = { x: kind === 'REVEAL' ? 12 : 0, y: kind === 'RECORD' ? 6 : 0 };
  let effect: TransitionEffect = TransitionEffect.opacity(0.35).animation(animation)
    .combine(TransitionEffect.translate(translation));
  if (kind === 'REVEAL') {
    const rotation: RotateOptions = { y: 1, angle: -12, centerX: '0%', centerY: '50%' };
    effect = effect.combine(TransitionEffect.rotate(rotation));
  } else if (kind === 'CONFIRM') {
    const scale: ScaleOptions = { x: 1.025, y: 1.025 };
    effect = effect.combine(TransitionEffect.scale(scale));
  }
  return TransitionEffect.asymmetric(effect, TransitionEffect.IDENTITY);
}

export class RandomFoodMotionObserver {
  private listening: boolean = false;
  private changed: (reduced: boolean) => void;
  constructor(changed: (reduced: boolean) => void) { this.changed = changed; }
  start(): boolean {
    this.stop();
    let reduced: boolean = true;
    try {
      reduced = accessibility.isAnimationReduceEnabledSync();
      accessibility.onAnimationReduceStateChange(this.changed);
      this.listening = true;
    } catch (_error) { /* Keep the page usable without optional motion APIs. */ }
    return reduced;
  }
  stop(): void {
    if (!this.listening) return;
    this.listening = false;
    try { accessibility.offAnimationReduceStateChange(this.changed); } catch (_error) {}
  }
}

export function randomFoodAccountUnavailable(error: Object): boolean {
  return error instanceof CloudBusinessError &&
    ['AUTH_REQUIRED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DELETED', 'FORBIDDEN', 'ACCESS_DENIED'].includes(error.code);
}

function randomAction(button: ButtonAttribute): void {
  const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
  button.type(ButtonType.Normal).constraintSize({ minHeight: 48 }).borderRadius(12)
    .fontSize(16).fontWeight(FontWeight.Bold).labelStyle(label).focusable(true).opacity(1);
}
export class RandomPrimaryStyle implements AttributeModifier<ButtonAttribute> {
  private palette: PagePaletteName;
  constructor(palette: PagePaletteName = 'NOTE') { this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    randomAction(button);
    button.backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'gold') : $r('app.color.random_accent'))).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'on_gold') : $r('app.color.random_on_accent'))).border({ width: 0 });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.86); }
}
export class RandomSecondaryStyle implements AttributeModifier<ButtonAttribute> {
  private palette: PagePaletteName;
  constructor(palette: PagePaletteName = 'NOTE') { this.palette = palette; }
  applyNormalAttribute(button: ButtonAttribute): void {
    randomAction(button);
    button.backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'surface') : $r('app.color.random_surface'))).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
      .border({ width: 1, color: (this.palette === 'PERSONAL' ? pageColor(this.palette, 'line') : $r('app.color.random_line')) });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.86); }
}
