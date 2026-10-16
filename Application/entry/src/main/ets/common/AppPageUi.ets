import { PagePaletteName } from './PagePaletteUi';

// How far the home tab bar may sink into the bottom gesture area (vp). Index reserves that much less of the
// bottom inset; destinations add it back as padding so their content keeps the same safe distance.
export const HOME_BAR_OVERLAP: number = 12;

export class AppPageSurface {
  static bottomOverlap: number = 0;
  static canvas: Resource = $r('app.color.canvas');
  static header: Resource = $r('app.color.canvas');
  static palette: PagePaletteName = 'NOTE';
  static systemBarInk: string = '#3D2A22';
  static onChange: (() => void) | undefined = undefined;
  private static entrySurfaceVisible: boolean = false;
  // True while the visible home tab draws its own image under the status bar (profile cover).
  private static immersiveTop: boolean = false;
  // A destination (card detail) may extend its hero image under the status bar: Index paints the top slice
  // of the same image (same width, height = top inset + edgeImageHeight, Cover), the page paints the rest.
  static edgeImageUrl: string = '';
  static edgeImageHeight: number = 0;
  private static edgeImageOwner: number = 0;
  private static nextEdgeOwner: number = 0;

  static newEdgeImageOwner(): number {
    AppPageSurface.nextEdgeOwner++;
    return AppPageSurface.nextEdgeOwner;
  }

  static setEdgeImage(owner: number, url: string, heightVp: number): void {
    const immersive: boolean = url.length > 0;
    if (AppPageSurface.edgeImageOwner === owner && AppPageSurface.edgeImageUrl === url &&
      AppPageSurface.edgeImageHeight === heightVp && AppPageSurface.immersiveTop === immersive) return;
    AppPageSurface.edgeImageOwner = immersive ? owner : 0;
    AppPageSurface.edgeImageUrl = url;
    AppPageSurface.edgeImageHeight = immersive ? heightVp : 0;
    AppPageSurface.immersiveTop = immersive;
    AppPageSurface.changed();
  }

  // Only the page that set the image may clear it; a newer page's image is left alone.
  static clearEdgeImage(owner: number): void {
    if (AppPageSurface.edgeImageOwner !== owner || AppPageSurface.edgeImageUrl.length === 0) return;
    AppPageSurface.setEdgeImage(owner, '', 0);
  }

  private static changed(): void {
    const revision: number = AppStorage.get<number>('pageSurfaceRevision') || 0;
    AppStorage.setOrCreate('pageSurfaceRevision', revision + 1);
    const onChange: (() => void) | undefined = AppPageSurface.onChange;
    if (onChange !== undefined) onChange();
  }

  static windowHeader(): Resource {
    return AppPageSurface.entrySurfaceVisible ? $r('app.color.canvas') : AppPageSurface.header;
  }

  static windowCanvas(): Resource {
    return AppPageSurface.entrySurfaceVisible ? $r('app.color.canvas') : AppPageSurface.canvas;
  }

  static windowImmersiveTop(): boolean {
    return !AppPageSurface.entrySurfaceVisible && AppPageSurface.immersiveTop;
  }

  static setEntrySurfaceVisible(visible: boolean): void {
    if (AppPageSurface.entrySurfaceVisible === visible) return;
    AppPageSurface.entrySurfaceVisible = visible;
    const onChange: (() => void) | undefined = AppPageSurface.onChange;
    if (onChange !== undefined) onChange();
  }

  static show(canvas: Resource, header: Resource, palette: PagePaletteName = 'NOTE',
    immersiveTop: boolean = false): void {
    AppPageSurface.canvas = canvas;
    AppPageSurface.header = header;
    AppPageSurface.palette = palette;
    AppPageSurface.immersiveTop = immersiveTop;
    AppPageSurface.edgeImageUrl = '';
    AppPageSurface.edgeImageHeight = 0;
    AppPageSurface.edgeImageOwner = 0;
    const revision: number = AppStorage.get<number>('pageSurfaceRevision') || 0;
    AppStorage.setOrCreate('pageSurfaceRevision', revision + 1);
    const onChange: (() => void) | undefined = AppPageSurface.onChange;
    if (onChange !== undefined) onChange();
  }
}

// Index reserves system insets once. Destinations must stay inside that content viewport.
export class AppDestinationStyle implements AttributeModifier<NavDestinationAttribute> {
  private heading: string;
  private canvas: Resource;
  private header: Resource;
  private palette: PagePaletteName;
  constructor(heading: string = '', canvas: Resource = $r('app.color.canvas'),
    header: Resource = canvas, palette: PagePaletteName = 'NOTE') {
    this.heading = heading;
    this.canvas = canvas;
    this.header = header;
    this.palette = palette;
  }
  applyNormalAttribute(destination: NavDestinationAttribute): void {
    const options: NavigationTitleOptions = { backgroundColor: this.header };
    const systemBarStyle: SystemBarStyle = { statusBarContentColor: AppPageSurface.systemBarInk };
    const bottomPadding: Padding = { bottom: AppPageSurface.bottomOverlap };
    destination.padding(bottomPadding).backgroundColor(this.canvas).background(this.canvas).clip(true).title(this.heading, options)
      .ignoreLayoutSafeArea([], []).expandSafeArea([], [])
      .systemBarStyle(systemBarStyle)
      // Only the destination itself slides; the page underneath stays still and unmasked, so a back
      // swipe never leaves part of the home page covered by a half-moved layer.
      .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
      .onWillShow((): void => AppPageSurface.show(this.canvas, this.header, this.palette));
  }
}
