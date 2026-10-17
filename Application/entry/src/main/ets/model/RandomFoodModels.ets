/**
 * 【文件职责】「今日吃什么」的数据结构与轮次规则。
 */
import { FoodCard } from './CloudContracts';

// 候选来源：我的收藏 / 公开推荐 / 好友推荐。
export type RandomFoodSource = 'MY' | 'PUBLIC' | 'FRIENDS';
// 候选池请求 / 响应。
export interface RandomFoodPoolRequest { source: RandomFoodSource; roundId: string; }
export interface RandomFoodPool {
  source: RandomFoodSource; roundId: string; cardIds: Array<string>; poolSize: number; poolLimit: number;
  rangeLabel: string; preparedAt: number; scannedCandidateCount: number; coverage: string;
}
// 翻牌内容请求 / 响应。
export interface RandomFoodCardsRequest { source: RandomFoodSource; drawId: string; cardIds: Array<string>; }
export interface RandomFoodCards { cards: Array<FoodCard>; unavailableCardIds: Array<string>; }
// 保存选择请求 / 回执。
export interface FoodChoiceRequest { source: RandomFoodSource; roundId: string; drawId: string; cardId: string; }
export interface FoodChoiceReceipt { historyId: string; selectedAt: number; deleted: boolean; }
// 选择记录一项 / 一页 / 请求 / 删除请求。
export interface FoodChoiceItem { historyId: string; source: RandomFoodSource; selectedAt: number; card: FoodCard | null; }
export interface FoodChoicePage { items: Array<FoodChoiceItem>; nextCursor: string; }
export interface FoodChoicePageRequest { cursor: string; requestId: string; }
export interface FoodChoiceDeleteRequest { historyId: string; }

// 本机保存的轮次只包含引用（卡片 id 等）；可读的内容每次都重新从云端获取。
export interface RandomFoodRound {
  version: number; owner: string; source: RandomFoodSource; roundId: string; cardIds: Array<string>;
  position: number; shownCount: number; batchIds: Array<string>; drawId: string; chosenCardId: string; pendingCardId: string;
  selectedAt: number; historyId: string; recordDeleted: boolean; rangeLabel: string; preparedAt: number; ended: boolean;
}
// 选过之后，下一顿饭可以重新开始的间隔（6 小时）。
export const RANDOM_FOOD_NEXT_MEAL_DELAY_MS: number = 6 * 60 * 60 * 1000;

// 下一顿可以开始的时间（未选择时为 0）。
export function randomFoodNextMealAt(round: RandomFoodRound): number {
  return round.chosenCardId.length === 0 ? 0 : round.selectedAt + RANDOM_FOOD_NEXT_MEAL_DELAY_MS;
}
// 现在是否可以开始下一顿。
export function randomFoodCanStartNextMeal(round: RandomFoodRound, now: number): boolean {
  return round.chosenCardId.length > 0 && round.pendingCardId.length === 0 && now >= randomFoodNextMealAt(round);
}
// 来源的中文名称。
export function randomFoodSourceLabel(source: RandomFoodSource): string {
  return source === 'MY' ? '我的' : source === 'FRIENDS' ? '好友' : '公开';
}
// 复制轮次对象。
export function copyRandomFoodRound(value: RandomFoodRound): RandomFoodRound {
  const result: RandomFoodRound = {
    version: value.version, owner: value.owner, source: value.source, roundId: value.roundId,
    cardIds: value.cardIds.slice(), position: value.position, shownCount: value.shownCount, batchIds: value.batchIds.slice(), drawId: value.drawId,
    chosenCardId: value.chosenCardId, pendingCardId: value.pendingCardId, selectedAt: value.selectedAt,
    historyId: value.historyId, recordDeleted: value.recordDeleted, rangeLabel: value.rangeLabel,
    preparedAt: value.preparedAt, ended: value.ended
  };
  return result;
}
