import { PagePaletteName, pageColor } from './PagePaletteUi';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { PersonalCollectionPage } from '../model/PersonalCollectionModels';
import { CardRepository } from '../repository/CardRepository';
import { PersonalCollectionRepository } from '../repository/PersonalCollectionRepository';

/**
 * 【文件职责】私信与群聊共用的工具：时间文本、时间分隔条规则、气泡圆角、分隔条组件，以及“发卡片”候选的读取。
 */
const SEPARATOR_GAP_MS: number = 10 * 60 * 1000;

// 补零到两位数。
function twoDigits(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

// 消息时间 “HH:mm”。
export function chatClock(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date: Date = new Date(timestamp);
  return `${date.getHours()}:${twoDigits(date.getMinutes())}`;
}

// 分隔条文字：“今天 HH:mm”、“昨天 HH:mm”或“x月x日 HH:mm”。
export function chatSeparatorLabel(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date: Date = new Date(timestamp);
  const now: Date = new Date();
  const startOfToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  if (timestamp >= startOfToday) return `今天 ${chatClock(timestamp)}`;
  if (timestamp >= startOfToday - 24 * 60 * 60 * 1000) return `昨天 ${chatClock(timestamp)}`;
  return `${date.getMonth() + 1}月${date.getDate()}日 ${chatClock(timestamp)}`;
}

// 第一条消息之前，以及相邻两条消息间隔超过 10 分钟时，显示一个时间分隔条。
export function chatShowsSeparator(previousAt: number | undefined, currentAt: number): boolean {
  return previousAt === undefined || !Number.isFinite(previousAt) || currentAt - previousAt >= SEPARATOR_GAP_MS;
}

// 气泡圆角：自己发的消息右下角小圆角，对方的左下角小圆角。
export function chatBubbleRadius(mine: boolean): BorderRadiuses {
  if (mine) {
    const own: BorderRadiuses = { topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 6 };
    return own;
  }
  const other: BorderRadiuses = { topLeft: 16, topRight: 16, bottomLeft: 6, bottomRight: 16 };
  return other;
}

// 私信 / 群聊“发卡片”候选：我的收藏（分页），首屏再补上本人已发布的公开卡片（按 id 去重）。
export interface ShareableCards {
  cards: Array<FoodCard>;
  nextCursor: string;
  // 收藏尚未完成历史整理（此时只能分享本人发布的卡片）。
  collectionPending: boolean;
}

// 读取一页可分享卡片；more=true 时在 existing 之后追加下一页收藏。每次等待后 stillCurrent() 为 false（页面已切换）则返回 undefined。
export async function loadShareableCards(context: common.Context, cardRepository: CardRepository,
  existing: Array<FoodCard>, cursor: string, more: boolean, stillCurrent: () => boolean): Promise<ShareableCards | undefined> {
  const page: PersonalCollectionPage = await new PersonalCollectionRepository().list('FAVORITE', more ? cursor : '');
  if (!stillCurrent()) return undefined;
  const combined: Array<FoodCard> = more ? existing.slice() : [];
  const contains = (cardId: string): boolean => combined.some((card: FoodCard): boolean => card.id === cardId);
  for (const item of page.items) {
    const card: FoodCard | null = item.card;
    if (card !== null && !contains(card.id)) combined.push(card);
  }
  if (!more) {
    const own: Array<FoodCard> = await cardRepository.myCards(context);
    if (!stillCurrent()) return undefined;
    for (const card of own) {
      if (card.status === 'APPROVED' && !contains(card.id)) combined.push(card);
    }
  }
  const result: ShareableCards = { cards: combined, nextCursor: page.nextCursor,
    collectionPending: page.migration !== undefined && !page.migration.collectionReady };
  return result;
}

// 时间分隔条组件。
@Builder
export function chatSeparator(label: string, palette: PagePaletteName) {
  Row() {
    Text(label).fontSize(11).fontColor(pageColor(palette, 'muted')).height(22).padding({ left: 10, right: 10 })
      .borderRadius(11).border({ width: 1, color: pageColor(palette, 'line'), style: BorderStyle.Dashed })
  }.width('100%').justifyContent(FlexAlign.Center).margin({ bottom: 2 })
}
