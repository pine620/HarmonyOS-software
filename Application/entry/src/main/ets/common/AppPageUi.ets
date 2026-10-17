/**
 * 【文件职责】页面外观的全局协调：当前页面使用的色板、窗口背景/状态栏颜色、是否沉浸式（图片延伸到状态栏下）。
 * 页面切换时调用 AppPageSurface.show()，EntryAbility 通过 onChange 回调同步窗口与状态栏文字颜色；
 * AppDestinationStyle 是所有 NavDestination 子页面共用的样式（标题、背景、顶部安全区、转场）。
 * 【顶部安全区】Index 不再统一预留状态栏高度：首页各页签和每个子页面自己绘制状态栏区域，这样颜色和图片随页面一起滑动、
 * 一起转场，不会滞后。普通子页面由 AppDestinationStyle 用页面顶部色预留；沉浸式页面（卡片详情大图）自己把图片画到状态栏下。
 */
import { PagePaletteName } from './PagePaletteUi';

// 首页页签切换动画时长（ms）：Tabs 的切换动画与顶部状态栏颜色渐变共用，保证两者同时开始、同时结束。
export const TAB_SWITCH_MS: number = 300;

// 首页底部页签栏最多可以下沉到底部手势区域的距离（vp）。Index 少预留这么多底部安全区；子页面再把它加回作为内边距，使内容与底部保持同样的安全距离。
export const HOME_BAR_OVERLAP: number = 12;

// 全局页面外观状态（静态类）。
export class AppPageSurface {
  static bottomOverlap: number = 0;
  static canvas: Resource = $r('app.color.canvas');
  static header: Resource = $r('app.color.canvas');
  static palette: PagePaletteName = 'NOTE';
  static systemBarInk: string = '#3D2A22';
  static onChange: (() => void) | undefined = undefined;
  private static entrySurfaceVisible: boolean = false;
  // 当前页面在状态栏下绘制图片时为 true（“我的”页主页背景、卡片详情大图），状态栏文字改为白色。
  private static immersiveTop: boolean = false;
  private static immersiveOwner: number = 0;
  private static nextImmersiveOwner: number = 0;

  // 申请一个沉浸状态的所有者编号（防止旧页面清除新页面设置的沉浸状态）。
  static newImmersiveOwner(): number {
    AppPageSurface.nextImmersiveOwner++;
    return AppPageSurface.nextImmersiveOwner;
  }

  // 子页面声明自己的大图是否正画在状态栏下。
  static setImmersiveTop(owner: number, immersive: boolean): void {
    if (immersive) {
      if (AppPageSurface.immersiveOwner === owner && AppPageSurface.immersiveTop) return;
      AppPageSurface.immersiveOwner = owner;
    } else if (AppPageSurface.immersiveOwner !== owner || !AppPageSurface.immersiveTop) {
      // 只有设置沉浸状态的页面才能清除它。
      return;
    }
    AppPageSurface.immersiveTop = immersive;
    if (!immersive) AppPageSurface.immersiveOwner = 0;
    AppPageSurface.changed();
  }

  // 外观变化时通知 EntryAbility 刷新窗口颜色。
  private static changed(): void {
    const revision: number = AppStorage.get<number>('pageSurfaceRevision') || 0;
    AppStorage.setOrCreate('pageSurfaceRevision', revision + 1);
    const onChange: (() => void) | undefined = AppPageSurface.onChange;
    if (onChange !== undefined) onChange();
  }

  // 当前窗口顶部（状态栏区域）应使用的颜色。
  static windowHeader(): Resource {
    return AppPageSurface.entrySurfaceVisible ? $r('app.color.canvas') : AppPageSurface.header;
  }

  // 当前窗口画布颜色。
  static windowCanvas(): Resource {
    return AppPageSurface.entrySurfaceVisible ? $r('app.color.canvas') : AppPageSurface.canvas;
  }

  // 顶部是否为沉浸式（状态栏文字需改为白色）。
  static windowImmersiveTop(): boolean {
    return !AppPageSurface.entrySurfaceVisible && AppPageSurface.immersiveTop;
  }

  // 主页面（Index）是否可见；不可见时窗口颜色由子页面决定。
  static setEntrySurfaceVisible(visible: boolean): void {
    if (AppPageSurface.entrySurfaceVisible === visible) return;
    AppPageSurface.entrySurfaceVisible = visible;
    const onChange: (() => void) | undefined = AppPageSurface.onChange;
    if (onChange !== undefined) onChange();
  }

  // 页面显示时调用：登记画布色、顶部色、色板与沉浸状态。
  static show(canvas: Resource, header: Resource, palette: PagePaletteName = 'NOTE',
    immersiveTop: boolean = false): void {
    AppPageSurface.canvas = canvas;
    AppPageSurface.header = header;
    AppPageSurface.palette = palette;
    AppPageSurface.immersiveTop = immersiveTop;
    AppPageSurface.immersiveOwner = 0;
    const revision: number = AppStorage.get<number>('pageSurfaceRevision') || 0;
    AppStorage.setOrCreate('pageSurfaceRevision', revision + 1);
    const onChange: (() => void) | undefined = AppPageSurface.onChange;
    if (onChange !== undefined) onChange();
  }
}

// 子页面共用样式。Index 不为子页面预留状态栏高度：普通页面在这里用顶部色的上边框预留（边框占位并着色，随页面一起转场）；
// immersiveTop=true 的页面不预留，由页面自己把内容画到状态栏下并负责避让。
export class AppDestinationStyle implements AttributeModifier<NavDestinationAttribute> {
  private heading: string;
  private canvas: Resource;
  private header: Resource;
  private palette: PagePaletteName;
  private immersiveTop: boolean;
  // heading：页面标题；canvas：背景色；header：状态栏区域颜色；immersiveTop：页面自己绘制状态栏区域。
  constructor(heading: string = '', canvas: Resource = $r('app.color.canvas'),
    header: Resource = canvas, palette: PagePaletteName = 'NOTE', immersiveTop: boolean = false) {
    this.heading = heading;
    this.canvas = canvas;
    this.header = header;
    this.palette = palette;
    this.immersiveTop = immersiveTop;
  }
  // 应用到 NavDestination：标题、背景、隐藏系统标题栏、转场动画等。
  applyNormalAttribute(destination: NavDestinationAttribute): void {
    const options: NavigationTitleOptions = { backgroundColor: this.header };
    const systemBarStyle: SystemBarStyle = { statusBarContentColor: AppPageSurface.systemBarInk };
    const bottomPadding: Padding = { bottom: AppPageSurface.bottomOverlap };
    // 状态栏高度（px）由 EntryAbility 写入 AppStorage；用 px 长度避免这里没有 UIContext 做单位换算。
    const topInset: string = (this.immersiveTop ? 0 : AppStorage.get<number>('appSystemTopPx') || 0) + 'px';
    const topBorder: BorderOptions = { width: { top: topInset }, color: { top: this.header } };
    destination.padding(bottomPadding).border(topBorder).backgroundColor(this.canvas).background(this.canvas).clip(true).title(this.heading, options)
      .ignoreLayoutSafeArea([], []).expandSafeArea([], [])
      .systemBarStyle(systemBarStyle)
      // 转场时只滑动子页面本身，下面的页面保持不动且不加遮罩，这样侧滑返回时不会出现首页被半透明层部分遮住的情况。
      .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
      .onWillShow((): void => AppPageSurface.show(this.canvas, this.header, this.palette));
  }
}
