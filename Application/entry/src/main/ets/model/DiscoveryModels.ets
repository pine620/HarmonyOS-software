import { FoodCard, FoodCategoryV2 } from './CloudContracts';

export type DiscoveryMode = 'ALL' | 'DELIVERY' | 'DINE_IN';
export type DiscoverySort = 'LATEST' | 'SCORE_DESC' | 'PRICE_ASC' | 'PRICE_DESC';
export type DiscoveryScope = 'ALL_PUBLIC' | 'VIEWPORT';
export type QueryCoverage = 'COMPLETE' | 'PARTIAL_SCAN_LIMIT' | 'PARTIAL_RESULT_LIMIT';
export interface DiscoveryCapabilities {
  searchEnabled: boolean;
  mapEnabled: boolean;
  searchReason: string;
  mapReason: string;
}
export interface DiscoveryViewport { north: number; south: number; east: number; west: number; }
export interface DiscoveryCamera { latitude: number; longitude: number; zoom: number; }
export interface MapMerchant {
  merchantId: string; name: string; address: string;
  latitude: number; longitude: number; coordinateSystem: string;
}
export interface MapMerchantQuery { viewport: DiscoveryViewport; mode: DiscoveryMode; cursor: string; limit: number; }
export interface MapMerchantPage {
  merchants: Array<MapMerchant>; nextCursor: string; coverage: QueryCoverage;
  scannedCandidateCount: number; fetchedCandidateCount: number; returnedCount: number;
}
export interface PublicCardQuery {
  keyword: string; mode: DiscoveryMode; categories: Array<FoodCategoryV2>;
  priceMinFen?: number; priceMaxExclusiveFen?: number;
  sort: DiscoverySort; scope: DiscoveryScope; viewport?: DiscoveryViewport;
  cursor: string; pageSize: number;
}
export interface DiscoveryCardPage {
  cards: Array<FoodCard>; nextCursor: string; coverage: QueryCoverage;
  scannedCandidateCount: number; fetchedCandidateCount: number; merchantReadCount: number;
  returnedCount: number; scope: DiscoveryScope;
  merchant?: MapMerchant;
}
export interface MerchantRecommendationQuery { merchantId: string; mode: DiscoveryMode; cursor: string; pageSize: number; }
export function normalizeSearch(value: string): string { return value.normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase(); }
export function copyViewport(value: DiscoveryViewport): DiscoveryViewport {
  return { north: value.north, south: value.south, east: value.east, west: value.west };
}
export function copyCardQuery(value: PublicCardQuery, cursor: string = ''): PublicCardQuery {
  const result: PublicCardQuery = { keyword: value.keyword, mode: value.mode, categories: value.categories.slice(),
    sort: value.sort, scope: value.scope, pageSize: value.pageSize, cursor };
  if (value.viewport !== undefined) result.viewport = copyViewport(value.viewport);
  if (value.priceMinFen !== undefined) result.priceMinFen = value.priceMinFen;
  if (value.priceMaxExclusiveFen !== undefined) result.priceMaxExclusiveFen = value.priceMaxExclusiveFen;
  return result;
}
export function emptyCapabilities(): DiscoveryCapabilities {
  return { searchEnabled: false, mapEnabled: false, searchReason: 'VALIDATION_REQUIRED', mapReason: 'VALIDATION_REQUIRED' };
}
