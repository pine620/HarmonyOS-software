import { FoodCard } from './CloudContracts';

export type FoodRankingKind = 'HIGH_SCORE' | 'FRIENDS';
export interface FoodRankingRequest {
  kind: FoodRankingKind;
  cursor: string;
}
export interface FoodRankingItem {
  rank: number;
  card: FoodCard;
  merchantName: string;
}
export interface FoodRankingResponse {
  phase: 'PREPARING' | 'READY';
  kind: FoodRankingKind;
  scope: 'ALL_VISIBLE';
  items: Array<FoodRankingItem>;
  totalCount: number;
  nextCursor: string;
  snapshotAt: number;
  updatedAt: number;
  scannedCardCount: number;
}
export class FoodRankingSnapshot {
  kind: FoodRankingKind;
  items: Array<FoodRankingItem>;
  cursor: string;
  totalCount: number;
  updatedAt: number;
  constructor(kind: FoodRankingKind, response: FoodRankingResponse) {
    this.kind = kind;
    this.items = response.items; this.cursor = response.nextCursor;
    this.totalCount = response.totalCount; this.updatedAt = response.updatedAt;
  }
}
