/**
 * 【文件职责】个人收藏与卡片预览的数据结构。
 */
import { FoodCard } from './CloudContracts';

// 个人集合类型（目前只有收藏）。
export type PersonalCollectionKind = 'FAVORITE';
// 设置收藏请求（requestId 用于幂等）。
export interface SetPersonalCollectionRequest {
  cardId: string;
  active: boolean;
  requestId: string;
  responseMode?: 'ACK';
}
// 设置收藏的结果。
export interface PersonalCollectionAction {
  cardId: string;
  kind: PersonalCollectionKind;
  active: boolean;
  requestId: string;
  contentAvailable: boolean;
  likeCount?: number;
  dislikeCount?: number;
  favoriteCount?: number;
  myReaction?: 'LIKE' | 'DISLIKE' | '';
  viewerFavorited?: boolean;
  committed?: boolean;
  collectionReady?: boolean;
}
// 卡片预览请求 / 一项 / 响应。
export interface CardPreviewsRequest { cardIds: Array<string>; includeDetailPhotos?: boolean; }
export interface CardPreviewItem { cardId: string; accessible: boolean; card: FoodCard | null; }
export interface CardPreviewsResponse { items: Array<CardPreviewItem>; }
// 收藏列表请求 / 一页。
export interface PersonalCollectionRequest { kind: PersonalCollectionKind; cursor: string; pageSize: number; }
export interface PersonalCollectionPage { items: Array<CardPreviewItem>; nextCursor: string; migration?: PersonalCollectionMigration; }
// 旧收藏迁移进度。
export interface PersonalCollectionMigration {
  schemaReady: boolean;
  collectionReady: boolean;
  status: 'NOT_STARTED' | 'PENDING' | 'RUNNING' | 'FAILED' | 'DONE';
  phase: 'LISTS' | 'WANTED' | 'DONE';
  processed: number;
  importedFavorites: number;
  importedWanted: number;
  lastErrorCode: string;
}
export interface CollectionMigrationRequest { requestId: string; }
