/**
 * 【文件职责】本机“浏览记录”（Preferences，按账号隔离，最多 100 条，最新在前）。
 * 打开卡片详情时 record() 写入一条摘要（名称、分类、价格文本、封面位置），CardHistoryPage 读取展示；不上传云端。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { FoodCard, FoodCategory } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';

const STORE_NAME: string = 'shike_card_visits';
// 最多保存的浏览记录条数。
const MAX_VISITS: number = 100;

// 一条浏览记录（只保存展示所需的摘要）。
export interface CardVisit {
  cardId: string;
  productName: string;
  category: FoodCategory;
  priceText: string;
  visitedAt: number;
  coverPath?: string;
  coverBucket?: string;
}

// 某账号浏览记录的存储键。
function visitKey(uid: string): string {
  return `visits_${uid}`;
}

// 把一条记录编码成用 | 分隔的字符串（各字段先 URI 编码，避免分隔符冲突）。
function encodeVisit(visit: CardVisit): string {
  return [
    encodeURIComponent(visit.cardId), visit.visitedAt.toString(),
    encodeURIComponent(visit.productName), encodeURIComponent(visit.category),
    encodeURIComponent(visit.priceText), encodeURIComponent(visit.coverPath || ''),
    encodeURIComponent(visit.coverBucket || '')
  ].join('|');
}

// 把存储中的分类字符串转换为分类类型（无法识别时归为 other）。
function visitCategory(value: string): FoodCategory {
  if (value === 'staple' || value === 'bakery' || value === 'drink' ||
    value === 'snack' || value === 'fresh') return value;
  return 'other';
}

// 解码一条记录；格式不对返回 undefined。
function decodeVisit(raw: string): CardVisit | undefined {
  const fields: Array<string> = raw.split('|');
  if (fields.length !== 5 && fields.length !== 7) return undefined;
  const visitedAt: number = Number(fields[1]);
  if (!Number.isFinite(visitedAt) || visitedAt <= 0) return undefined;
  try {
    const cardId: string = decodeURIComponent(fields[0]);
    if (cardId.length === 0) return undefined;
    const storedPrice: string = decodeURIComponent(fields[4]);
    return {
      cardId, visitedAt,
      productName: decodeURIComponent(fields[2]),
      category: visitCategory(decodeURIComponent(fields[3])),
      priceText: storedPrice.startsWith('¥') ? storedPrice : '',
      coverPath: fields.length === 7 ? decodeURIComponent(fields[5]) : '',
      coverBucket: fields.length === 7 ? decodeURIComponent(fields[6]) : ''
    };
  } catch (_error) {
    return undefined;
  }
}

// 浏览记录存储（静态类）。
export class CardVisitStore {
  // 读取某账号的浏览记录（最多 100 条）。
  static list(context: common.Context, uid: string): Array<CardVisit> {
    if (uid.length === 0) return [];
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const value: preferences.ValueType = store.getSync(visitKey(uid), []);
    if (!Array.isArray(value)) return [];
    const rows: Array<string> = value as Array<string>;
    const visits: Array<CardVisit> = [];
    for (const raw of rows) {
      if (typeof raw !== 'string') continue;
      const visit: CardVisit | undefined = decodeVisit(raw);
      if (visit !== undefined) visits.push(visit);
    }
    return visits.slice(0, MAX_VISITS);
  }

  // 记录一次浏览：同一卡片只保留最新一条，放到最前面。
  static record(context: common.Context, uid: string, card: FoodCard): void {
    if (uid.length === 0 || card.id.length === 0) return;
    const visit: CardVisit = {
      cardId: card.id,
      productName: card.productName.slice(0, 64),
      category: card.category,
      priceText: cardPriceText(card, ''),
      visitedAt: Date.now(), coverPath: card.photoPath, coverBucket: card.photoBucket
    };
    const next: Array<CardVisit> = [visit];
    for (const stored of CardVisitStore.list(context, uid)) {
      if (stored.cardId !== visit.cardId && next.length < MAX_VISITS) next.push(stored);
    }
    const rows: Array<string> = next.map((item: CardVisit): string => encodeVisit(item));
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.putSync(visitKey(uid), rows);
    store.flushSync();
  }

  // 补全浏览记录中的封面位置（旧记录没有封面时）。
  static backfillCover(context: common.Context, uid: string, card: FoodCard): void {
    const visits: Array<CardVisit> = CardVisitStore.list(context, uid);
    const found: CardVisit | undefined = visits.find((visit: CardVisit): boolean => visit.cardId === card.id);
    if (found === undefined || found.coverPath === card.photoPath && found.coverBucket === card.photoBucket) return;
    found.coverPath = card.photoPath; found.coverBucket = card.photoBucket;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.putSync(visitKey(uid), visits.map((visit: CardVisit): string => encodeVisit(visit))); store.flushSync();
  }

  // 删除某张卡片的浏览记录（卡片被删除或不可见时）。
  static remove(context: common.Context, uid: string, cardId: string): void {
    const rows: Array<string> = CardVisitStore.list(context, uid)
      .filter((visit: CardVisit): boolean => visit.cardId !== cardId)
      .map((visit: CardVisit): string => encodeVisit(visit));
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.putSync(visitKey(uid), rows);
    store.flushSync();
  }

  // 清空某账号的浏览记录。
  static clear(context: common.Context, uid: string): void {
    if (uid.length === 0) return;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.deleteSync(visitKey(uid));
    store.flushSync();
  }
}
