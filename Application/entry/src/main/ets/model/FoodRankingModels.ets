/**
 * 【文件职责】榜单（高分榜 / 好友榜）请求与响应结构。
 */
import { FoodCard } from './CloudContracts';

// 榜单类型。
export type FoodRankingKind = 'HIGH_SCORE' | 'FRIENDS';
// 榜单请求（分页）。
export interface FoodRankingRequest {
  kind: FoodRankingKind;
  cursor: string;
}
// 榜单中的一项（名次 + 卡片）。
export interface FoodRankingItem {
  rank: number;
  card: FoodCard;
  merchantName: string;
}
// 榜单一页；快照生成中时返回准备中状态。
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
// 本机缓存的榜单页（用于切换页签时复用）。
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
