import { PagePaletteName, pageColor } from './PagePaletteUi';

// Pack 2 (2026-10-15): shared look for private and group chat.
const SEPARATOR_GAP_MS: number = 10 * 60 * 1000;

function twoDigits(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export function chatClock(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date: Date = new Date(timestamp);
  return `${date.getHours()}:${twoDigits(date.getMinutes())}`;
}

export function chatSeparatorLabel(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date: Date = new Date(timestamp);
  const now: Date = new Date();
  const startOfToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  if (timestamp >= startOfToday) return `今天 ${chatClock(timestamp)}`;
  if (timestamp >= startOfToday - 24 * 60 * 60 * 1000) return `昨天 ${chatClock(timestamp)}`;
  return `${date.getMonth() + 1}月${date.getDate()}日 ${chatClock(timestamp)}`;
}

// A time chip before the first message and whenever ten minutes pass between two messages.
export function chatShowsSeparator(previousAt: number | undefined, currentAt: number): boolean {
  return previousAt === undefined || !Number.isFinite(previousAt) || currentAt - previousAt >= SEPARATOR_GAP_MS;
}

export function chatBubbleRadius(mine: boolean): BorderRadiuses {
  if (mine) {
    const own: BorderRadiuses = { topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 6 };
    return own;
  }
  const other: BorderRadiuses = { topLeft: 16, topRight: 16, bottomLeft: 6, bottomRight: 16 };
  return other;
}

@Builder
export function chatSeparator(label: string, palette: PagePaletteName) {
  Row() {
    Text(label).fontSize(11).fontColor(pageColor(palette, 'muted')).height(22).padding({ left: 10, right: 10 })
      .borderRadius(11).border({ width: 1, color: pageColor(palette, 'line'), style: BorderStyle.Dashed })
  }.width('100%').justifyContent(FlexAlign.Center).margin({ bottom: 2 })
}
