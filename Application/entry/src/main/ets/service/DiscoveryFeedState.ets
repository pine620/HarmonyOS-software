/**
 * 【文件职责】推荐流的“返回复用”状态（只在内存）：从详情页返回推荐页时恢复列表、滚动位置、筛选条件与地图视野，
 * 不必重新请求。按账号与筛选签名区分，换号时 AuthService 会调用 clear()。
 */
import { FoodCard, FoodCategoryV2 } from '../model/CloudContracts';
import { DiscoveryCamera, DiscoveryMode, DiscoveryScope, DiscoverySort, DiscoveryViewport, MapMerchant, PublicCardQuery } from '../model/DiscoveryModels';
// 推荐流中的一项：卡片、封面地址与加载时间。
export interface DiscoveryEntry { card: FoodCard; coverUrl: string; loadedAt: number; }
// “上一地区”：用于地图上返回之前浏览的区域。
export interface PreviousRegion { viewport: DiscoveryViewport; camera: DiscoveryCamera; }
// 推荐流快照：所属账号、筛选签名、滚动位置、已加载的卡片与分页游标等。
export interface DiscoverySnapshot {
  owner: string; signature: string; scrollY: number;
  cards: Array<DiscoveryEntry>;
  keywordInput: string;
  keyword: string;
  mode: DiscoveryMode;
  categories: Array<FoodCategoryV2>;
  sort: DiscoverySort;
  priceMin: string;
  priceMax: string;
  pricePreset: number;
  status: string;
  nextCursor: string;
  scope: DiscoveryScope;
  submittedQuery: PublicCardQuery | undefined;
  viewport: DiscoveryViewport | undefined;
  searchedViewport: DiscoveryViewport | undefined;
  queryViewport: DiscoveryViewport | undefined;
  queryCamera: DiscoveryCamera | undefined;
  cameraTarget: DiscoveryCamera;
  currentCamera: DiscoveryCamera;
  previousResultRegion: PreviousRegion | undefined;
  previousCards: Array<DiscoveryEntry>;
  showingPrevious: boolean;
  merchants: Array<MapMerchant>;
  mapCursor: string;
  mapStatus: string;
  expanded: boolean;
  listOpen: boolean;
  visibleFirst: number;
  visibleLast: number;
}
// 推荐流状态（静态类，只保留一份快照）。
export class DiscoveryFeedState {
  private static snapshot: DiscoverySnapshot | undefined = undefined;
  // 清除快照（换号、退出时）。
  static clear(): void { DiscoveryFeedState.snapshot = undefined; }
  // 保存快照（离开推荐页时）。
  static save(value: DiscoverySnapshot): void { DiscoveryFeedState.snapshot = value; }
  // 读取快照：账号与筛选签名都一致、且未过期时才返回。
  static read(owner: string, signature: string): DiscoverySnapshot | undefined {
    const value: DiscoverySnapshot | undefined = DiscoveryFeedState.snapshot;
    return value !== undefined && value.owner === owner && value.signature === signature ? value : undefined;
  }
}
