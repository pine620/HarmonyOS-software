import { FoodCard } from './CloudContracts';

export type RandomFoodSource = 'MY' | 'PUBLIC' | 'FRIENDS';
export interface RandomFoodPoolRequest { source: RandomFoodSource; roundId: string; }
export interface RandomFoodPool {
  source: RandomFoodSource; roundId: string; cardIds: Array<string>; poolSize: number; poolLimit: number;
  rangeLabel: string; preparedAt: number; scannedCandidateCount: number; coverage: string;
}
export interface RandomFoodCardsRequest { source: RandomFoodSource; drawId: string; cardIds: Array<string>; }
export interface RandomFoodCards { cards: Array<FoodCard>; unavailableCardIds: Array<string>; }
export interface FoodChoiceRequest { source: RandomFoodSource; roundId: string; drawId: string; cardId: string; }
export interface FoodChoiceReceipt { historyId: string; selectedAt: number; deleted: boolean; }
export interface FoodChoiceItem { historyId: string; source: RandomFoodSource; selectedAt: number; card: FoodCard | null; }
export interface FoodChoicePage { items: Array<FoodChoiceItem>; nextCursor: string; }
export interface FoodChoicePageRequest { cursor: string; requestId: string; }
export interface FoodChoiceDeleteRequest { historyId: string; }

/** Local progress contains references only; readable content is always refreshed. */
export interface RandomFoodRound {
  version: number; owner: string; source: RandomFoodSource; roundId: string; cardIds: Array<string>;
  position: number; shownCount: number; batchIds: Array<string>; drawId: string; chosenCardId: string; pendingCardId: string;
  selectedAt: number; historyId: string; recordDeleted: boolean; rangeLabel: string; preparedAt: number; ended: boolean;
}
export function randomFoodSourceLabel(source: RandomFoodSource): string {
  return source === 'MY' ? '我的' : source === 'FRIENDS' ? '好友' : '公开';
}
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
