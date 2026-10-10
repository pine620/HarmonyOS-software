import { FoodCard, FoodCategoryV2 } from '../model/CloudContracts';
import { DiscoveryCamera, DiscoveryMode, DiscoveryScope, DiscoverySort, DiscoveryViewport, MapMerchant, PublicCardQuery } from '../model/DiscoveryModels';
export interface DiscoveryEntry { card: FoodCard; coverUrl: string; loadedAt: number; }
export interface PreviousRegion { viewport: DiscoveryViewport; camera: DiscoveryCamera; }
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
export class DiscoveryFeedState {
  private static snapshot: DiscoverySnapshot | undefined = undefined;
  static clear(): void { DiscoveryFeedState.snapshot = undefined; }
  static save(value: DiscoverySnapshot): void { DiscoveryFeedState.snapshot = value; }
  static read(owner: string, signature: string): DiscoverySnapshot | undefined {
    const value: DiscoverySnapshot | undefined = DiscoveryFeedState.snapshot;
    return value !== undefined && value.owner === owner && value.signature === signature ? value : undefined;
  }
}
