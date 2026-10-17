// 窗口宽度断点：sm 手机 / md 折叠屏或小平板 / lg 平板与 2in1。
export type LayoutBreakpoint = 'sm' | 'md' | 'lg';

/**
 * 【文件职责】响应式布局断点。所有尺寸单位为 vp；要测量的是布局后的窗口宽度，而不是物理屏幕尺寸（分屏、自由窗口时二者不同）。
 */
export class BreakpointSystem {
  static readonly MEDIUM_MIN: number = 600;
  static readonly LARGE_MIN: number = 840;
  static readonly NAV_RAIL_WIDTH: number = 88;
  static readonly CARD_GAP: number = 12;

  // 根据窗口宽度（vp）判断断点。
  static fromWidth(widthVp: number): LayoutBreakpoint {
    if (widthVp >= BreakpointSystem.LARGE_MIN) return 'lg';
    if (widthVp >= BreakpointSystem.MEDIUM_MIN) return 'md';
    return 'sm';
  }

  // 该断点下网格的列数。
  static columns(breakpoint: LayoutBreakpoint): number {
    if (breakpoint === 'lg') return 4;
    if (breakpoint === 'md') return 3;
    return 2;
  }

  // Grid 的 columnsTemplate 字符串。
  static columnsTemplate(breakpoint: LayoutBreakpoint): string {
    if (breakpoint === 'lg') return '1fr 1fr 1fr 1fr';
    if (breakpoint === 'md') return '1fr 1fr 1fr';
    return '1fr 1fr';
  }

  // 该断点下页面左右内边距。
  static pagePadding(breakpoint: LayoutBreakpoint): number {
    return breakpoint === 'sm' ? 16 : 24;
  }
}
