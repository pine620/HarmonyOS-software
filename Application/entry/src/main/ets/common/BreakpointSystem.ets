export type LayoutBreakpoint = 'sm' | 'md' | 'lg';

/** All sizes are vp. Measure the laid-out window, never the physical display. */
export class BreakpointSystem {
  static readonly MEDIUM_MIN: number = 600;
  static readonly LARGE_MIN: number = 840;
  static readonly NAV_RAIL_WIDTH: number = 88;
  static readonly CARD_GAP: number = 12;

  static fromWidth(widthVp: number): LayoutBreakpoint {
    if (widthVp >= BreakpointSystem.LARGE_MIN) return 'lg';
    if (widthVp >= BreakpointSystem.MEDIUM_MIN) return 'md';
    return 'sm';
  }

  static columns(breakpoint: LayoutBreakpoint): number {
    if (breakpoint === 'lg') return 4;
    if (breakpoint === 'md') return 3;
    return 2;
  }

  static columnsTemplate(breakpoint: LayoutBreakpoint): string {
    if (breakpoint === 'lg') return '1fr 1fr 1fr 1fr';
    if (breakpoint === 'md') return '1fr 1fr 1fr';
    return '1fr 1fr';
  }

  static pagePadding(breakpoint: LayoutBreakpoint): number {
    return breakpoint === 'sm' ? 16 : 24;
  }
}
