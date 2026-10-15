import { FoodCard } from './CloudContracts';

export type PersonalCollectionKind = 'FAVORITE';
export interface SetPersonalCollectionRequest {
  cardId: string;
  active: boolean;
  requestId: string;
  responseMode?: 'ACK';
}
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
export interface CardPreviewsRequest { cardIds: Array<string>; includeDetailPhotos?: boolean; }
export interface CardPreviewItem { cardId: string; accessible: boolean; card: FoodCard | null; }
export interface CardPreviewsResponse { items: Array<CardPreviewItem>; }
export interface PersonalCollectionRequest { kind: PersonalCollectionKind; cursor: string; pageSize: number; }
export interface PersonalCollectionPage { items: Array<CardPreviewItem>; nextCursor: string; migration?: PersonalCollectionMigration; }
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
