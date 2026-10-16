import { FoodCategoryV2 } from '../model/CloudContracts';

export type DiscoveryCategoryKey = FoodCategoryV2 | 'ALL' | 'MORE';
export interface DiscoveryShortcut { key: DiscoveryCategoryKey; label: string; }
export const DISCOVERY_SHORTCUTS: Array<DiscoveryShortcut> = [
  { key: 'ALL', label: '全部' }, { key: 'NOODLES', label: '粉面' },
  { key: 'RICE_SET', label: '米饭' }, { key: 'SNACK', label: '小吃' },
  { key: 'DRINK', label: '饮品' }, { key: 'MORE', label: '更多' }
];

export function discoveryCategoryIcon(key: DiscoveryCategoryKey): Resource {
  if (key === 'ALL') return $r('app.media.ic_discovery_all');
  if (key === 'MORE') return $r('app.media.ic_discovery_more');
  if (key === 'NOODLES') return $r('app.media.ic_discovery_noodles');
  if (key === 'RICE_SET') return $r('app.media.ic_discovery_rice');
  if (key === 'SNACK') return $r('app.media.ic_discovery_snack');
  if (key === 'DRINK') return $r('app.media.ic_discovery_drink');
  if (key === 'GRILL_FRIED') return $r('app.media.ic_discovery_grill');
  if (key === 'HOT_POT') return $r('app.media.ic_discovery_hotpot');
  if (key === 'FAST_WESTERN') return $r('app.media.ic_discovery_western');
  if (key === 'BREAKFAST_BAKERY') return $r('app.media.ic_discovery_bakery');
  if (key === 'DESSERT') return $r('app.media.ic_discovery_dessert');
  if (key === 'PACKAGED') return $r('app.media.ic_discovery_packaged');
  return $r('app.media.ic_discovery_other');
}

export function discoveryPanelTransition(enabled: boolean): TransitionEffect {
  if (!enabled) return TransitionEffect.IDENTITY;
  const animation: AnimateParam = { duration: 180, curve: Curve.EaseOut };
  const translation: TranslateOptions = { y: 8 };
  return TransitionEffect.asymmetric(TransitionEffect.opacity(0).combine(TransitionEffect.translate(translation))
    .animation(animation), TransitionEffect.opacity(0).animation(animation));
}

export class DiscoveryActionStyle implements AttributeModifier<ButtonAttribute> {
  private primary: boolean;
  constructor(primary: boolean = false) { this.primary = primary; }
  applyNormalAttribute(button: ButtonAttribute): void {
    const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
    button.type(ButtonType.Normal).constraintSize({ minHeight: 48 }).fontSize(14).fontWeight(FontWeight.Medium)
      .labelStyle(label).borderRadius(16).padding({ left: 14, right: 14 }).focusable(true).opacity(1)
      .backgroundColor(this.primary ? $r('app.color.discovery_gold') : $r('app.color.discovery_surface'))
      .fontColor(this.primary ? $r('app.color.discovery_on_gold') : $r('app.color.discovery_ink'))
      .border({ width: this.primary ? 0 : 1, color: $r('app.color.discovery_line') });
  }
  applyDisabledAttribute(button: ButtonAttribute): void { button.opacity(0.45); }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.85); }
}

export class DiscoveryChoiceStyle implements AttributeModifier<ButtonAttribute> {
  private selected: boolean;
  constructor(selected: boolean) { this.selected = selected; }
  applyNormalAttribute(button: ButtonAttribute): void {
    const label: LabelStyle = { maxLines: 2, overflow: TextOverflow.Ellipsis };
    button.type(ButtonType.Normal).constraintSize({ minHeight: 48 }).fontSize(13).labelStyle(label)
      .padding({ left: 12, right: 12 }).borderRadius(14).focusable(true).opacity(1)
      .backgroundColor(this.selected ? $r('app.color.discovery_soft') : $r('app.color.discovery_surface'))
      .fontColor(this.selected ? $r('app.color.discovery_accent') : $r('app.color.discovery_ink'))
      .border({ width: 1, color: this.selected ? $r('app.color.discovery_accent') : $r('app.color.discovery_line') })
      .accessibilitySelected(this.selected);
  }
  applyPressedAttribute(button: ButtonAttribute): void { button.opacity(0.85); }
}

@Component
export struct DiscoveryBackdrop {
  private gradient(): LinearGradient {
    const colors: Array<[ResourceColor, number]> = [
      [$r('app.color.discovery_header'), 0], [$r('app.color.discovery_header_fade'), 0.72],
      [$r('app.color.discovery_clear'), 1]
    ];
    const gradient: LinearGradient = { direction: GradientDirection.Bottom, colors };
    return gradient;
  }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {}.width('100%').height(330).linearGradient(this.gradient())
        .expandSafeArea([], [])
      // The glow circle and arc were clipped at the content top, leaving a visible seam under the
      // flat-coloured status bar (most obvious in dark mode). The header keeps only its gradient and dots.
      Column({ space: 10 }) {
        ForEach([0, 1, 2, 3, 4], (row: number) => {
          Row({ space: 10 }) {
            ForEach([0, 1, 2, 3, 4], (column: number) => {
              Circle().width(1.5).height(1.5).fill($r('app.color.discovery_accent')).opacity(0.16)
            }, (column: number): string => column.toString())
          }
        }, (row: number): string => row.toString())
      }.translate({ x: -20, y: 62 })
      Column() {}.width('100%').height(48)
        .linearGradient({ direction: GradientDirection.Bottom, colors: [[$r('app.color.discovery_header'), 0], [$r('app.color.discovery_header_clear'), 1]] });
    }.width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .expandSafeArea([], [])
  }
}

@Component
export struct DiscoveryLoadingMark {
  @Prop @Watch('syncMotion') motionEnabled: boolean = false;
  @Prop markSize: number = 32;
  @State angle: number = 0;
  private mounted: boolean = false;
  private syncMotion(): void {
    if (!this.mounted) return;
    const options: AnimateParam = this.motionEnabled
      ? { duration: 900, curve: Curve.Linear, iterations: -1 }
      : { duration: 0, iterations: 1 };
    this.getUIContext().animateTo(options, (): void => { this.angle = this.motionEnabled ? 360 : 0; });
  }
  build() {
    Stack() {
      Circle().width(this.markSize).height(this.markSize).fill($r('app.color.discovery_soft'))
      Image($r('app.media.ic_discovery_refresh')).width(this.markSize * 0.68).height(this.markSize * 0.68)
        .objectFit(ImageFit.Contain).fillColor($r('app.color.discovery_accent')).rotate({ angle: this.angle })
    }.width(this.markSize).height(this.markSize).accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
      .onAppear((): void => { this.mounted = true; this.syncMotion(); })
      .onDisAppear((): void => {
        const options: AnimateParam = { duration: 0 };
        this.getUIContext().animateTo(options, (): void => { this.angle = 0; });
        this.mounted = false;
      })
  }
}
