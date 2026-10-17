/**
 * 【文件职责】推荐页“发现”功能（地图、搜索、排序、筛选）的数据结构与工具函数。
 */
import { FoodCard, FoodCategoryV2 } from './CloudContracts';

// 消费方式筛选 / 排序方式 / 搜索范围（全部公开或当前地图视野）。
export type DiscoveryMode = 'ALL' | 'DELIVERY' | 'DINE_IN';
export type DiscoverySort = 'LATEST' | 'SCORE_DESC' | 'PRICE_ASC' | 'PRICE_DESC';
export type DiscoveryScope = 'ALL_PUBLIC' | 'VIEWPORT';
// 结果覆盖情况：COMPLETE 完整；PARTIAL_* 因扫描或结果上限只返回了部分。
export type QueryCoverage = 'COMPLETE' | 'PARTIAL_SCAN_LIMIT' | 'PARTIAL_RESULT_LIMIT';
// 发现功能开关与坐标系（由云端开关决定）。
export interface DiscoveryCapabilities {
  searchEnabled: boolean;
  mapEnabled: boolean;
  searchReason: string;
  mapReason: string;
}
// 地图视野边界与相机位置。
export interface DiscoveryViewport { north: number; south: number; east: number; west: number; }
export interface DiscoveryCamera { latitude: number; longitude: number; zoom: number; }
// 地图上的店铺标记。
export interface MapMerchant {
  merchantId: string; name: string; address: string;
  latitude: number; longitude: number; coordinateSystem: string;
}
// 地图店铺查询。
export interface MapMerchantQuery { viewport: DiscoveryViewport; mode: DiscoveryMode; cursor: string; limit: number; }
export interface MapMerchantPage {
  merchants: Array<MapMerchant>; nextCursor: string; coverage: QueryCoverage;
  scannedCandidateCount: number; fetchedCandidateCount: number; returnedCount: number;
}
// 公开卡片搜索 / 筛选条件。
export interface PublicCardQuery {
  keyword: string; mode: DiscoveryMode; categories: Array<FoodCategoryV2>;
  priceMinFen?: number; priceMaxExclusiveFen?: number;
  sort: DiscoverySort; scope: DiscoveryScope; viewport?: DiscoveryViewport;
  cursor: string; pageSize: number;
}
// 搜索结果一页。
export interface DiscoveryCardPage {
  cards: Array<FoodCard>; nextCursor: string; coverage: QueryCoverage;
  scannedCandidateCount: number; fetchedCandidateCount: number; merchantReadCount: number;
  returnedCount: number; scope: DiscoveryScope;
  merchant?: MapMerchant;
}
// 店铺推荐查询。
export interface MerchantRecommendationQuery { merchantId: string; mode: DiscoveryMode; cursor: string; pageSize: number; }
// 规范化搜索词：全角转半角、去首尾空白、合并空格。
export function normalizeSearch(value: string): string { return value.normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase(); }
// 复制视野对象（避免共享引用被修改）。
export function copyViewport(value: DiscoveryViewport): DiscoveryViewport {
  return { north: value.north, south: value.south, east: value.east, west: value.west };
}
// 复制查询条件并替换游标。
export function copyCardQuery(value: PublicCardQuery, cursor: string = ''): PublicCardQuery {
  const result: PublicCardQuery = { keyword: value.keyword, mode: value.mode, categories: value.categories.slice(),
    sort: value.sort, scope: value.scope, pageSize: value.pageSize, cursor };
  if (value.viewport !== undefined) result.viewport = copyViewport(value.viewport);
  if (value.priceMinFen !== undefined) result.priceMinFen = value.priceMinFen;
  if (value.priceMaxExclusiveFen !== undefined) result.priceMaxExclusiveFen = value.priceMaxExclusiveFen;
  return result;
}
// 能力全部关闭的默认值（云端未返回前使用）。
export function emptyCapabilities(): DiscoveryCapabilities {
  return { searchEnabled: false, mapEnabled: false, searchReason: 'VALIDATION_REQUIRED', mapReason: 'VALIDATION_REQUIRED' };
}
