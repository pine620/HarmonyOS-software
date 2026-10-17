/**
 * 【文件职责】推荐页主体（最复杂的页面之一）：
 *   - 公开推荐流：瀑布流 + 分页（list-nearby-cards，游客首页优先使用首页快照），可见区域按需加载封面，首页后台预取；
 *   - 搜索与筛选：关键词（含本机搜索记录）、分类（最多 3 类）、外卖/到店、价格区间、排序（search-public-cards）；
 *   - 地图浏览：DiscoveryMap 显示视野内店铺（list-map-merchants），点开店铺查看推荐（get-merchant-recommendations），支持“搜索此区域 / 返回上一地区”；
 *   - 返回复用：离开时把列表、滚动位置、筛选等保存到 DiscoveryFeedState，从详情返回时直接恢复。
 * 【并发控制】所有异步加载都带 generation（代次），条件变化（筛选、换号、刷新）后旧结果自动丢弃。
 */
import { RandomFoodMotionObserver } from '../common/RandomFoodUi';
import { ReadCancelledError } from '../service/CloudReadErrors';
import { CardPreviewsRequest, CardPreviewsResponse, CardPreviewItem } from '../model/PersonalCollectionModels';
import { ReadRequestOptions, ReadScheduler } from '../service/ReadScheduler';
import { common } from '@kit.AbilityKit';
import { CardPhoto, FoodCard, FoodCategoryV2, NearbyCardsResponse, PublicCardsRequest, UserProfile } from '../model/CloudContracts';
import { copyCardQuery, copyViewport, DiscoveryCamera, DiscoveryCapabilities, DiscoveryCardPage, DiscoveryMode, DiscoveryScope,
  DiscoverySort, DiscoveryViewport, MapMerchant, MapMerchantPage, MapMerchantQuery,
  MerchantRecommendationQuery, normalizeSearch, PublicCardQuery, QueryCoverage } from '../model/DiscoveryModels';
import { CATEGORY_V2_OPTIONS, CategoryV2Option, categoryV2Label, parseYuanInputToFen } from '../model/PublishingModels';
import { DiscoveryRepository } from '../repository/DiscoveryRepository';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { CloudBusinessError, CloudGateway } from '../service/CloudGateway';
import { DiscoveryFeedState, DiscoverySnapshot, DiscoveryEntry, PreviousRegion } from '../service/DiscoveryFeedState';
import { ImageRepository } from '../service/ImageRepository';
import { PagedDataSource } from '../service/PagedDataSource';
import { MapViewportStore } from '../service/MapViewportStore';
import { SearchHistoryStore } from '../service/SearchHistoryStore';
import { DiscoveryMap } from '../components/DiscoveryMap';
import { DiscoveryCard } from '../components/DiscoveryCard';
import { DISCOVERY_SHORTCUTS, DiscoveryActionStyle, DiscoveryBackdrop,
  DiscoveryCategoryKey, DiscoveryChoiceStyle, DiscoveryLoadingMark, DiscoveryShortcut,
  discoveryCategoryIcon, discoveryPanelTransition } from '../components/DiscoveryVisuals';
import { MerchantRecommendationSheet } from '../components/MerchantRecommendationSheet';
import { BreakpointSystem, LayoutBreakpoint } from '../common/BreakpointSystem';
import { invalidatesProtectedPage, stage47ErrorText } from '../common/Stage47Ui';

// 排序选项。
interface SortOption { value: DiscoverySort; label: string; }
// 筛选条件（分类、价格等）。
interface DiscoveryFilterValues {
  categories: Array<FoodCategoryV2>; sort: DiscoverySort; priceMin: string; priceMax: string; pricePreset: number;
}
// 当前展开的面板：分类 / 筛选 / 搜索记录 / 无。
type DiscoveryPanel = 'CATEGORIES' | 'FILTERS' | 'HISTORY' | 'NONE';
const SORT_OPTIONS: Array<SortOption> = [{ value: 'LATEST', label: '最新发布' }, { value: 'SCORE_DESC', label: '评分优先' },
  { value: 'PRICE_ASC', label: '价格升序' }, { value: 'PRICE_DESC', label: '价格降序' }];

// 推荐页主体。
@Component
export struct DiscoveryFeed {
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  @StorageLink('discoveryVisible') @Watch('onNavigationVisibilityChanged') navigationVisible: boolean = true;
  private visibleLifecycle: boolean = true;
  // 推荐页被子页面覆盖时保留已解码的封面，这样返回动画中露出的仍是同样的图片，而不是转场中途重新加载的空白占位。
  // 导航可见性变化（被子页面覆盖时保留已解码的封面）。
  private onNavigationVisibilityChanged(): void { if (this.navigationVisible && this.appActive && this.visibleLifecycle) this.resume(); else this.pause(false, !this.navigationVisible && this.appActive); }
  // App 前后台切换时暂停 / 恢复。
  private onAppActiveChanged(): void { if (!this.appActive) this.pause(false); else if (this.visibleLifecycle) this.resume(); }

  @Consume('windowBreakpoint') windowBreakpoint: LayoutBreakpoint;
  @Require @Prop @Watch('onCapabilitiesChanged') capabilities: DiscoveryCapabilities;
  @Prop capabilitiesLoading: boolean = false;
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  onOpenMeal: () => void = (): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onPrimaryCard: (card: FoodCard, remoteSync: boolean) => void = (_card: FoodCard, _remoteSync: boolean): void => {};
  onUnavailable: () => void = (): void => {};
  onReloadCapabilities: () => void = (): void => {};
  // 瀑布流通过 LazyForEach 渲染；cards 每次变化时都同步到这个数据源。
  @State @Watch('syncCardSource') cards: Array<DiscoveryEntry> = [];
  private cardSource: PagedDataSource<DiscoveryEntry> = new PagedDataSource<DiscoveryEntry>();
  // 把 cards 同步到 LazyForEach 数据源。
  private syncCardSource(): void { this.cardSource.replace(this.cards.slice()); }
  @State keywordInput: string = '';
  @State mode: DiscoveryMode = 'ALL';
  @State categories: Array<FoodCategoryV2> = [];
  @State sort: DiscoverySort = 'LATEST';
  @State priceMin: string = '';
  @State priceMax: string = '';
  @State pricePreset: number = -1;
  @State filtersOpen: boolean = false;
  @State historyOpen: boolean = false;
  @State categoriesOpen: boolean = false;
  @State draftCategories: Array<FoodCategoryV2> = [];
  @State draftSort: DiscoverySort = 'LATEST';
  @State draftPriceMin: string = '';
  @State draftPriceMax: string = '';
  @State draftPricePreset: number = -1;
  @State filterError: string = '';
  @State motionActive: boolean = false;
  @State resultOpacity: number = 1;
  @State resultOffset: number = 0;
  @State history: Array<string> = [];
  @State status: string = '正在准备公开推荐。';
  @State loading: boolean = false;
  @State loadFailed: boolean = false;
  @State featureNotReady: boolean = false;
  @State loadingMore: boolean = false;
  @State loadMoreFailed: boolean = false;
  @State nextCursor: string = '';
  @State scope: DiscoveryScope = 'ALL_PUBLIC';
  @State merchants: Array<MapMerchant> = [];
  @State mapCursor: string = '';
  @State mapStatus: string = '';
  @State mapLoading: boolean = false;
  @State viewportDirty: boolean = false;
  @State expanded: boolean = false;
  @State listOpen: boolean = false;
  @State selectedMerchantId: string = '';
  @State selectedMerchant: MapMerchant | undefined = undefined;
  @State merchantCards: Array<FoodCard> = [];
  @State merchantStatus: string = '';
  @State merchantCursor: string = '';
  @State merchantLoading: boolean = false;
  @State cameraTarget: DiscoveryCamera = { latitude: 39.9, longitude: 116.4, zoom: 15 };
  @State showingPrevious: boolean = false;
  @State availableHeight: number = 700;
  @State waterfallWidthVp: number = 0;
  private keyword: string = '';
  private submittedQuery: PublicCardQuery | undefined = undefined;
  private queryCamera: DiscoveryCamera | undefined = undefined;
  private resultScroller: Scroller = new Scroller();
  private bottomPageTimer: number | undefined = undefined;
  private viewport: DiscoveryViewport | undefined = undefined;
  private searchedViewport: DiscoveryViewport | undefined = undefined;
  private queryViewport: DiscoveryViewport | undefined = undefined;
  private currentCamera: DiscoveryCamera = { latitude: 39.9, longitude: 116.4, zoom: 15 };
  private previousResultRegion: PreviousRegion | undefined = undefined;
  private previousCards: Array<DiscoveryEntry> = [];
  private mapEmpty: boolean = false;
  private active: boolean = false;
  private owner: string = 'guest';
  private listGeneration: number = 0;
  private mapGeneration: number = 0;
  private merchantGeneration: number = 0;
  private debounce: number | undefined = undefined;
  private failedPhotoIds: Set<string> = new Set<string>();
  private loadingPhotoIds: Set<string> = new Set<string>();
  private hydratedIds: Set<string> = new Set<string>();
  private hydrationRunning: boolean = false;
  private prefetchRunning: boolean = false;
  private prefetchTimer: number | undefined = undefined;
  private prefetchGeneration: number = -1;
  private prefetchOwner: string = '';
  private prefetchStartedAt: number = 0;
  private prefetchManifests: Map<string, FoodCard> = new Map<string, FoodCard>();
  private prefetchManifestAttempts: Set<string> = new Set<string>();
  private prefetchPhotoAttempts: Set<string> = new Set<string>();
  private prefetchReadyPhotos: Set<string> = new Set<string>();
  private prefetchCoversSignature: string = '';
  private prefetchCompletedSignature: string = '';
  private feedLoadStartedAt: number = Date.now();
  private visibleFirst: number = 0;
  private visibleLast: number = 3;
  private scrolling: boolean = false;
  private motionObserver: RandomFoodMotionObserver = new RandomFoodMotionObserver((reduced: boolean): void => {
    this.motionActive = this.active && this.appActive && this.navigationVisible && this.visibleLifecycle && !reduced;
    if (!this.motionActive) this.stopResultMotion();
  });
  @StorageLink('accountContentRevision') @Watch('onRevisionChanged') accountContentRevision: number = 0;
  // 页面可见性变化。
  private onVisibilityChanged(visible: boolean): void { if (visible === this.visibleLifecycle) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.resume(); else this.pause(false); }
  // 当前查询是否为普通公开推荐流（没有搜索与筛选）。
  private isPublicFeedQuery(query: PublicCardQuery): boolean { return query.scope === 'ALL_PUBLIC' && query.keyword.length === 0 && query.mode === 'ALL' && query.categories.length === 0 && query.sort === 'LATEST' && query.priceMinFen === undefined && query.priceMaxExclusiveFen === undefined; }
  // 按查询条件读取一页：公开推荐流走 list-nearby-cards，否则走搜索。
  private async queryCards(query: PublicCardQuery, cursor: string): Promise<DiscoveryCardPage> {
    if (this.isPublicFeedQuery(query) || !this.capabilities.searchEnabled) return this.publicPage(cursor);
    return this.repository.search(copyCardQuery(query, cursor));
  }
  private repository: DiscoveryRepository = new DiscoveryRepository();
  private cardRepository: CardRepository = new CardRepository();
  // 取得 UIAbility 上下文。
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  // 当前身份（用于快照与缓存区分账号）。
  private viewer(): string {
    const profile: UserProfile | undefined = AuthService.profile();
    return profile !== undefined && CloudGateway.hasSession() ? profile.uid : 'guest';
  }
  // 异步结果是否仍有效。
  private current(generation: number): boolean { return this.active && this.appActive && this.navigationVisible && generation === this.listGeneration && this.owner === this.viewer(); }
  private loadedSignature: string = '';
  private primaryRemoteSync: boolean = false;
  // 当前列表状态的签名（版本 + 账号 + 条件），用于判断快照能否复用。
  private signature(): string { return this.revision + ':' + this.accountContentRevision; }
  // 出现时恢复。
  aboutToAppear(): void { this.resume(); }
  // 销毁时暂停。
  aboutToDisappear(): void { this.pause(true); }
  // 停止结果入场动画。
  private stopResultMotion(): void {
    const options: AnimateParam = { duration: 0 };
    this.getUIContext().animateTo(options, (): void => { this.resultOpacity = 1; this.resultOffset = 0; });
  }
  // 播放结果入场动画。
  private revealResults(): void {
    if (!this.motionActive || !this.active || this.cards.length === 0) return;
    const reset: AnimateParam = { duration: 0 };
    const reveal: AnimateParam = { duration: 180, curve: Curve.EaseOut };
    this.getUIContext().animateTo(reset, (): void => { this.resultOpacity = 0.72; this.resultOffset = 6; });
    this.getUIContext().animateTo(reveal, (): void => { this.resultOpacity = 1; this.resultOffset = 0; });
  }
  // 保存返回复用快照。
  private saveSnapshot(): void {
    if (this.submittedQuery === undefined || this.owner !== this.viewer() || this.loadedSignature !== this.signature()) return;
    const value: DiscoverySnapshot = {
      owner: this.owner, signature: this.signature(), scrollY: this.resultScroller.currentOffset().yOffset,
      cards: this.cards,
      keywordInput: this.keywordInput,
      keyword: this.keyword,
      mode: this.mode,
      categories: this.categories,
      sort: this.sort,
      priceMin: this.priceMin,
      priceMax: this.priceMax,
      pricePreset: this.pricePreset,
      status: this.status,
      nextCursor: this.nextCursor,
      scope: this.scope,
      submittedQuery: this.submittedQuery,
      viewport: this.viewport,
      searchedViewport: this.searchedViewport,
      queryViewport: this.queryViewport,
      queryCamera: this.queryCamera,
      cameraTarget: this.cameraTarget,
      currentCamera: this.currentCamera,
      previousResultRegion: this.previousResultRegion,
      previousCards: this.previousCards,
      showingPrevious: this.showingPrevious,
      merchants: this.merchants,
      mapCursor: this.mapCursor,
      mapStatus: this.mapStatus,
      expanded: this.expanded,
      listOpen: this.listOpen,
      visibleFirst: this.visibleFirst,
      visibleLast: this.visibleLast
    };
    DiscoveryFeedState.save(value);
  }
  // 快照是否可以复用（账号与签名一致）。
  private snapshotAllowed(snapshot: DiscoverySnapshot): boolean {
    const query: PublicCardQuery | undefined = snapshot.submittedQuery;
    if (!this.capabilities.searchEnabled && (query === undefined || !this.isPublicFeedQuery(query))) return false;
    return this.capabilities.mapEnabled || (!snapshot.expanded && snapshot.scope !== 'VIEWPORT');
  }
  // 恢复：优先使用返回复用快照，否则重新加载。
  private resume(): void {
    if (this.active || !this.appActive || !this.visibleLifecycle || !this.navigationVisible) return;
    this.active = true; this.feedLoadStartedAt = Date.now(); const owner: string = this.viewer();
    this.motionActive = !this.motionObserver.start();
    let snapshot: DiscoverySnapshot | undefined = DiscoveryFeedState.read(owner, this.signature());
    if (snapshot !== undefined && !this.snapshotAllowed(snapshot)) snapshot = undefined;
    this.owner = owner;
    console.info('[DiscoveryFeed] event=resume viewGeneration=' + this.listGeneration + ' snapshot=' + String(snapshot !== undefined) + ' first=' + this.visibleFirst + ' last=' + this.visibleLast);
    try { this.history = SearchHistoryStore.read(this.context(), owner); } catch (_error) { this.history = []; }
    if (snapshot !== undefined) {
      this.cards = snapshot.cards;
      this.keywordInput = snapshot.keywordInput;
      this.keyword = snapshot.keyword;
      this.mode = snapshot.mode;
      this.categories = snapshot.categories;
      this.sort = snapshot.sort;
      this.priceMin = snapshot.priceMin;
      this.priceMax = snapshot.priceMax;
      this.pricePreset = snapshot.pricePreset;
      this.status = snapshot.status;
      this.nextCursor = snapshot.nextCursor;
      this.scope = snapshot.scope;
      this.submittedQuery = snapshot.submittedQuery;
      this.viewport = snapshot.viewport;
      this.searchedViewport = snapshot.searchedViewport;
      this.queryViewport = snapshot.queryViewport;
      this.queryCamera = snapshot.queryCamera;
      this.cameraTarget = snapshot.cameraTarget;
      this.currentCamera = snapshot.currentCamera;
      this.previousResultRegion = snapshot.previousResultRegion;
      this.previousCards = snapshot.previousCards;
      this.showingPrevious = snapshot.showingPrevious;
      this.merchants = snapshot.merchants;
      this.mapCursor = snapshot.mapCursor;
      this.mapStatus = snapshot.mapStatus;
      this.expanded = snapshot.expanded;
      this.listOpen = snapshot.listOpen;
      this.visibleFirst = snapshot.visibleFirst;
      this.visibleLast = snapshot.visibleLast;

      this.hydratedIds.clear(); this.failedPhotoIds.clear(); this.loadingPhotoIds.clear(); this.hydrationRunning = false;
      this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => {
        if (entry.coverUrl.length > 0 && ImageRepository.canReuseCover(entry.card)) {
          this.hydratedIds.add(entry.card.id); return entry;
        }
        return { card: entry.card, coverUrl: '', loadedAt: entry.loadedAt };
      });
      this.loading = false; this.loadingMore = false; this.mapLoading = false;
      this.loadedSignature = this.signature();
      void this.revalidateVisible(snapshot.scrollY);
    } else {
      this.cameraTarget = MapViewportStore.read(this.context(), owner); this.currentCamera = this.cameraTarget;
      void this.reload();
    }
  }
  // 暂停：保存快照并作废进行中的加载（keepCovers=true 时保留封面）。
  private pause(destroying: boolean, keepCovers: boolean = false): void {
    this.cancelBottomPage();
    this.motionObserver.stop(); this.motionActive = false; this.scrolling = false;
    this.stopResultMotion();
    if (!this.active) return;
    console.info('[DiscoveryFeed] event=pause viewGeneration=' + this.listGeneration);
    if (this.prefetchTimer !== undefined) { clearTimeout(this.prefetchTimer); this.prefetchTimer = undefined; }
    this.saveSnapshot(); this.active = false; this.listGeneration++; this.mapGeneration++; this.merchantGeneration++; ImageRepository.subscriptionsChanged(); ReadScheduler.subscriptionsChanged();
    if (!destroying) {
      this.selectedMerchant = undefined; this.merchantCards = [];
      if (!keepCovers) { this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => { return { card: entry.card, coverUrl: '', loadedAt: entry.loadedAt }; }); }
    }
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    this.setPanel('NONE');
  }
  // 恢复快照后，后台重新校验可见卡片是否仍然最新。
  private async revalidateVisible(scrollY: number): Promise<void> {
    // 先恢复布局，再做任何网络请求；内容是否过期的刷新独立进行。
    this.resultScroller.scrollTo({ xOffset: 0, yOffset: scrollY, animation: false });
    const generation: number = this.listGeneration;
    void this.hydrateVisible(this.visibleFirst, this.visibleLast);
    this.scheduleBottomPage(generation);
    const now: number = Date.now();
    const ids: Array<string> = this.cards.slice(this.visibleFirst, this.visibleLast + 1)
      .filter((entry: DiscoveryEntry): boolean => now - entry.loadedAt >= 30000)
      .map((entry: DiscoveryEntry): string => entry.card.id);
    if (ids.length === 0) return;
    await this.refreshChangedCards(ids, generation);
    if (!this.current(generation)) return;
    void this.hydrateVisible(this.visibleFirst, this.visibleLast);
    this.scheduleBottomPage(generation);
  }
  // 发现能力变化（地图、搜索开放）时刷新界面。
  private onCapabilitiesChanged(): void {
    if (!this.capabilities.searchEnabled) {
      this.keyword = ''; this.keywordInput = ''; this.mode = 'ALL'; this.resetFilters();
      this.scope = 'ALL_PUBLIC'; this.queryViewport = undefined;
    }
    if (!this.capabilities.mapEnabled) {
      this.expanded = false; this.listOpen = false; this.scope = 'ALL_PUBLIC'; this.queryViewport = undefined;
      this.searchedViewport = undefined; this.merchants = []; this.mapCursor = ''; this.mapLoading = false; this.mapEmpty = false;
    }
    if (this.active) this.onRevisionChanged();
  }
  // 内容版本变化（发布、修改、删除）时刷新。
  private onRevisionChanged(): void {
    if (!this.active) return;
    this.setPanel('NONE');
    DiscoveryFeedState.clear(); this.listGeneration++; this.mapGeneration++; this.closeMerchant();
    if (this.owner !== this.viewer()) {
      this.owner = this.viewer(); this.cards = []; this.previousCards = []; this.previousResultRegion = undefined;
      this.showingPrevious = false; this.keyword = ''; this.keywordInput = ''; this.scope = 'ALL_PUBLIC';
      this.mode = 'ALL'; this.categories = []; this.pricePreset = -1; this.priceMin = ''; this.priceMax = '';
      this.viewport = undefined; this.searchedViewport = undefined; this.queryViewport = undefined; this.queryCamera = undefined;
      this.merchants = []; this.mapCursor = ''; this.mapLoading = false; this.mapStatus = ''; this.mapEmpty = false; this.viewportDirty = false;
      this.submittedQuery = undefined; this.listOpen = false; this.expanded = false;
      this.cameraTarget = MapViewportStore.read(this.context(), this.owner); this.currentCamera = this.cameraTarget;
      try { this.history = SearchHistoryStore.read(this.context(), this.owner); } catch (_error) { this.history = []; }
    }
    this.loading = false; this.loadingMore = false; this.hydrationRunning = false; this.mapLoading = false;
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    this.showingPrevious = false; void this.reload();
    if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, false);
  }
  // 由当前界面条件构造查询。
  private makeQuery(cursor: string = '', filters: DiscoveryFilterValues | undefined = undefined): PublicCardQuery {
    const keyword: string = normalizeSearch(this.keywordInput);
    if (keyword.length > 50) throw new Error('搜索内容最多 50 字符。');
    const categories: Array<FoodCategoryV2> = filters === undefined ? this.categories : filters.categories;
    const sort: DiscoverySort = filters === undefined ? this.sort : filters.sort;
    const pricePreset: number = filters === undefined ? this.pricePreset : filters.pricePreset;
    const priceMin: string = filters === undefined ? this.priceMin : filters.priceMin;
    const priceMax: string = filters === undefined ? this.priceMax : filters.priceMax;
    const query: PublicCardQuery = { keyword, mode: this.mode, categories: categories.slice(), sort,
      scope: this.scope, cursor, pageSize: 20 };
    if (this.scope === 'VIEWPORT' && this.queryViewport !== undefined) query.viewport = copyViewport(this.queryViewport);
    if (pricePreset >= 0) {
      query.priceMinFen = pricePreset * 1000;
      if (pricePreset < 3) query.priceMaxExclusiveFen = (pricePreset + 1) * 1000;
    } else if (priceMin.length > 0 || priceMax.length > 0) {
      if (priceMin.length === 0 || priceMax.length === 0) throw new Error('自定义价格区间两端都要填写。');
      const min: number | null = parseYuanInputToFen(priceMin);
      const max: number | null = parseYuanInputToFen(priceMax);
      if (min === null || max === null || max <= min) throw new Error('请输入有效区间，上限大于下限，最多两位小数。');
      query.priceMinFen = min; query.priceMaxExclusiveFen = max;
    }
    return query;
  }
  // 把卡片转换为列表项（保留已加载的封面地址）。
  private entries(cards: Array<FoodCard>, retained: Array<DiscoveryEntry> = []): Array<DiscoveryEntry> {
    const loadedAt: number = Date.now();
    return cards.map((card: FoodCard): DiscoveryEntry => {
      const previous: DiscoveryEntry | undefined = retained.find((entry: DiscoveryEntry): boolean => entry.card.id === card.id);
      if ((card.contentRevision || '').length > 0 && previous !== undefined && previous.coverUrl.length > 0 &&
        previous.card.contentRevision === card.contentRevision && ImageRepository.canReuseCover(previous.card)) {
        card.photoUrl = previous.coverUrl; card.primaryPhotoResolved = true; card.primaryPhotoLoadFailed = false;
        this.hydratedIds.add(card.id);
      }
      const entry: DiscoveryEntry = { card, coverUrl: card.photoUrl, loadedAt };
      return entry;
    });
  }
  // 列表项的渲染键。
  private entryRenderKey(entry: DiscoveryEntry): string {
    // 列表项会在异步读取后被替换。如果只用 id 作为 ForEach 的键，封面加载完成后仍会沿用旧项的占位与回调，所以键里包含封面状态。
    const parts: Array<string> = [entry.card.id, entry.card.contentRevision || '', entry.coverUrl,
      String(entry.card.primaryPhotoResolved === true),
      String(entry.card.primaryPhotoLoadFailed === true)];
    return JSON.stringify(parts);
  }
  // 把新一页合并到当前列表（去重）。
  private merge(current: Array<DiscoveryEntry>, incoming: Array<FoodCard>): Array<DiscoveryEntry> {
    const output: Array<DiscoveryEntry> = current.slice(); const seen: Set<string> = new Set<string>();
    for (const value of current) seen.add(value.card.id);
    for (const card of incoming) if (!seen.has(card.id)) { const value: DiscoveryEntry = { card, coverUrl: card.photoUrl, loadedAt: Date.now() }; output.push(value); seen.add(card.id); }
    return output;
  }
  // 结果状态文字（是否完整、是否还有更多）。
  private resultStatus(count: number, coverage: QueryCoverage, cursor: string): string {
    if (count === 0 && cursor.length > 0) return '当前批未找到推荐，扫描尚未结束，可继续搜索。';
    if (count === 0) return '没有符合条件的推荐，可修改关键词或清除筛选。';
    if (coverage === 'PARTIAL_SCAN_LIMIT') return '已找到 ' + count + ' 条，扫描未完成，可继续搜索。';
    return '已找到 ' + count + ' 条推荐' + (cursor.length > 0 ? '，可继续加载。' : '。');
  }
  // 读取公开推荐流的一页。
  private async publicPage(cursor: string): Promise<DiscoveryCardPage> {
    const request: PublicCardsRequest = { scope: 'all', category: 'all', pageToken: cursor, pageSize: 6 };
    const generation: number = this.listGeneration;
    const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.current(generation) };
    const response: NearbyCardsResponse = await this.cardRepository.listRecommendationsMetadata(request, (): boolean => this.current(generation), options);
    return { cards: response.cards, nextCursor: response.nextPageToken, coverage: response.coverage === undefined ? (response.nextPageToken.length > 0 ? 'PARTIAL_RESULT_LIMIT' : 'COMPLETE') : response.coverage,
      scannedCandidateCount: response.scannedCandidateCount || 0, fetchedCandidateCount: response.fetchedCandidateCount || 0, merchantReadCount: 0, returnedCount: response.cards.length, scope: 'ALL_PUBLIC' };
  }
  // 重新加载第一页（recordHistory=true 时成功后记录搜索词）。
  private async reload(recordHistory: boolean = false, remoteSync: boolean = false): Promise<void> {
    this.cancelBottomPage();
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    let query: PublicCardQuery;
    try { query = this.makeQuery(); } catch (failure) { this.status = stage47ErrorText(failure as Object, '筛选条件无效。'); return; }
    const previousQuery: PublicCardQuery | undefined = this.submittedQuery;
    const retain: boolean = remoteSync && this.cards.length > 0 && !this.showingPrevious && this.owner === this.viewer() &&
      this.loadedSignature === this.signature() && previousQuery !== undefined &&
      JSON.stringify(copyCardQuery(query)) === JSON.stringify(copyCardQuery(previousQuery));
    const retained: Array<DiscoveryEntry> = retain ? this.cards.slice() : [];
    const retainedCursor: string = retain ? this.nextCursor : '';
    const generation: number = ++this.listGeneration;
    this.feedLoadStartedAt = Date.now();
    this.loadFailed = false; this.featureNotReady = false;
    this.loading = true; this.loadingMore = false; this.loadMoreFailed = false; this.hydrationRunning = false; this.hydratedIds.clear(); this.failedPhotoIds.clear(); this.loadingPhotoIds.clear(); this.nextCursor = '';
    if (!retain) { this.cards = []; }
    this.stopResultMotion(); this.status = retain ? '正在刷新好味道…' : '正在加载推荐…';
    try {
      const result: DiscoveryCardPage = await this.queryCards(query, '');
      if (!this.current(generation)) return;
      if (query.scope === 'VIEWPORT' && (this.mapEmpty || (result.cards.length === 0 && result.coverage === 'COMPLETE')) && this.previousCards.length > 0) {
        if (!this.current(generation)) return; this.cards = this.previousCards.map((entry: DiscoveryEntry): DiscoveryEntry => { return { card: entry.card, coverUrl: '', loadedAt: entry.loadedAt }; }); this.hydratedIds.clear(); this.showingPrevious = true; this.nextCursor = '';
        this.status = '当前区域无结果，暂时展示上一地区结果。';
      } else {
        this.cards = this.entries(result.cards, retained); this.nextCursor = result.nextCursor; this.showingPrevious = false;
        this.status = this.resultStatus(this.cards.length, result.coverage, result.nextCursor);
      }
      this.submittedQuery = copyCardQuery(query);
      this.primaryRemoteSync = remoteSync; this.loadedSignature = this.signature();
      const primary: DiscoveryEntry | undefined = this.cards.length > 0 ? this.cards[0] : undefined;
      if (retain && !this.showingPrevious && this.isPublicFeedQuery(query) && primary !== undefined &&
        primary.coverUrl.length > 0 && primary.card.primaryPhotoLoadFailed !== true) {
        this.onPrimaryCard(primary.card, remoteSync); this.primaryRemoteSync = false;
      }
      this.historyOpen = false;
      this.visibleFirst = 0; this.visibleLast = Math.min(3, this.cards.length - 1);
      this.scrolling = false; this.resultScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      if (retain) this.revealResults();
      // 只有在对应的成功结果写入界面之后，才把提交的搜索词记入搜索记录。
      if (recordHistory && query.keyword.length > 0 && !this.showingPrevious) {
        try { this.history = SearchHistoryStore.record(this.context(), this.owner, query.keyword); } catch (_error) { }
      }
      void this.hydrateVisible(0, Math.min(3, this.cards.length - 1));
    } catch (failure) {
      if (!this.current(generation)) return;
      this.loadFailed = true;
      this.featureNotReady = failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY';
      if (retain && !invalidatesProtectedPage(failure as Object)) {
        this.nextCursor = retainedCursor;
        this.status = stage47ErrorText(failure as Object, '刷新失败，当前推荐已保留。');
      } else if (invalidatesProtectedPage(failure as Object)) {
        DiscoveryFeedState.clear(); this.cards = []; this.submittedQuery = undefined;
      }
      if (this.featureNotReady) {
        DiscoveryFeedState.clear(); this.cards = [];
        if (this.capabilities.searchEnabled || this.capabilities.mapEnabled) this.onUnavailable();
      }
      if (!retain || invalidatesProtectedPage(failure as Object)) this.status = stage47ErrorText(failure as Object, '推荐加载失败，请稍后重试。');
    } finally { if (this.current(generation)) { this.loading = false; this.scheduleHomepagePrefetch(generation); this.scheduleBottomPage(generation); } }
  }
  // 取消“滚动到底部自动加载”。
  private cancelBottomPage(): void {
    if (this.bottomPageTimer !== undefined) clearTimeout(this.bottomPageTimer);
    this.bottomPageTimer = undefined;
  }
  // 安排一次底部自动加载检查。
  private scheduleBottomPage(generation: number): void {
    this.cancelBottomPage();
    if (!this.current(generation) || this.loading || this.loadingMore || this.loadFailed || this.loadMoreFailed ||
      this.nextCursor.length === 0 || this.showingPrevious || this.submittedQuery === undefined) return;
    // 等待新追加的卡片与底部栏完成布局后，再判断是否真的到底。
    this.bottomPageTimer = setTimeout((): void => {
      this.bottomPageTimer = undefined;
      if (!this.current(generation)) return;
      let atEnd: boolean = this.cards.length === 0;
      if (!atEnd) {
        try { atEnd = this.resultScroller.isAtEnd(); } catch (_error) { return; }
      }
      if (atEnd) void this.loadMore(true);
    }, 80);
  }
  // 加载下一页（automatic=true 为滚动触发）。
  private async loadMore(automatic: boolean = false): Promise<void> {
    if (!this.current(this.listGeneration) || this.loading || this.loadingMore || this.loadFailed ||
      this.nextCursor.length === 0 || this.showingPrevious || automatic && this.loadMoreFailed) return;
    const query: PublicCardQuery | undefined = this.submittedQuery;
    if (query === undefined) return;
    this.cancelBottomPage();
    const cursor: string = this.nextCursor;
    const generation: number = this.listGeneration; this.loadingMore = true; this.feedLoadStartedAt = Date.now();
    try {
      const result: DiscoveryCardPage = await this.queryCards(query, cursor);
      if (!this.current(generation)) return;
      if (result.nextCursor === cursor) throw new Error('分页没有推进，请点击顶部刷新后重试。');
      this.cards = this.merge(this.cards, result.cards); this.nextCursor = result.nextCursor;
      this.loadMoreFailed = false;
      this.status = this.resultStatus(this.cards.length, result.coverage, result.nextCursor);
    } catch (failure) {
      if (!this.current(generation)) return;
      this.loadMoreFailed = true;
      if (failure instanceof CloudBusinessError && failure.code === 'CURSOR_STALE') { this.nextCursor = ''; DiscoveryFeedState.clear(); this.status = '内容已变化，请点击刷新，筛选已保留。'; }
      else if (failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY') {
        DiscoveryFeedState.clear();
        if (this.capabilities.searchEnabled || this.capabilities.mapEnabled) this.onUnavailable();
        this.status = stage47ErrorText(failure as Object, '推荐暂未开放。');
      }
      else this.status = stage47ErrorText(failure as Object, '推荐加载失败。');
    } finally { if (this.current(generation)) { this.loadingMore = false; this.scheduleHomepagePrefetch(generation); this.scheduleBottomPage(generation); } }
  }
  // 为可见范围内的卡片加载封面。
  private async hydrateVisible(first: number, last: number): Promise<void> {
    this.visibleFirst = first; this.visibleLast = last;
    if (this.hydrationRunning || !this.active || !this.navigationVisible || !this.appActive) return;
    const generation: number = this.listGeneration;
    const chosen: Array<FoodCard> = this.cards.slice(Math.max(0, first), Math.min(this.cards.length, last + 1))
      .map((entry: DiscoveryEntry): FoodCard => entry.card).filter((card: FoodCard): boolean => !this.hydratedIds.has(card.id) && !this.failedPhotoIds.has(card.id) && !this.loadingPhotoIds.has(card.id));
    if (chosen.length === 0) { this.scheduleHomepagePrefetch(generation); return; }
    console.info('[DiscoveryFeed] event=hydrate viewGeneration=' + generation + ' count=' + chosen.length + ' first=' + first + ' last=' + last);
    this.hydrationRunning = true; const changed: Array<string> = [];
    for (const card of chosen) this.loadingPhotoIds.add(card.id);
    try {
      if (!this.current(generation)) return;
      const images: Array<FoodCard> = chosen;
      await ImageRepository.hydrateCovers(this.context(), images, async (): Promise<boolean> => this.current(generation),
        (card: FoodCard): void => {
          const currentEntry: DiscoveryEntry | undefined = this.cards.find((entry: DiscoveryEntry): boolean => entry.card === card);
          if (!this.current(generation) || currentEntry === undefined) return;
          this.loadingPhotoIds.delete(card.id);
          if (card.mediaAccessDenied === true) { this.cards = this.cards.filter((entry: DiscoveryEntry): boolean => entry.card.id !== card.id); this.status = '部分内容已不可访问，请刷新推荐。'; return; }
          if (card.primaryPhotoLoadFailed === true) this.failedPhotoIds.add(card.id);
          else this.hydratedIds.add(card.id);
          if (card.mediaContentChanged === true) changed.push(card.id);
          const settled: DiscoveryEntry = { card, coverUrl: card.mediaContentChanged === true ? '' : card.photoUrl, loadedAt: currentEntry.loadedAt };
          console.info('[DiscoveryFeed] event=cover-settled viewGeneration=' + generation + ' cardId=' + card.id +
            ' ready=' + String(settled.coverUrl.length > 0) +
            ' failed=' + String(card.primaryPhotoLoadFailed === true));
          if (card.id === this.cards[0]?.card.id && this.submittedQuery !== undefined && this.isPublicFeedQuery(this.submittedQuery) && card.mediaContentChanged !== true) { this.onPrimaryCard(card, this.primaryRemoteSync); this.primaryRemoteSync = false; }
          this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => entry.card.id === card.id ? settled : entry);
        }, false, 'normal', (card: FoodCard): boolean => { const index: number = this.cards.findIndex((entry: DiscoveryEntry): boolean => entry.card.id === card.id); return index >= this.visibleFirst && index <= this.visibleLast && this.cards[index].card === card; });
    } catch (_failure) { if (this.current(generation)) this.status = '实拍图暂不可用，推荐信息已保留，可刷新重试。'; }
    finally {
      if (this.current(generation)) {
        if (changed.length > 0) await this.refreshChangedCards(changed, generation);
        this.hydrationRunning = false;
        for (const card of chosen) this.loadingPhotoIds.delete(card.id);
        if (changed.length > 0 || this.visibleFirst !== first || this.visibleLast !== last || this.cards.slice(this.visibleFirst, this.visibleLast + 1).some((entry: DiscoveryEntry): boolean => !this.hydratedIds.has(entry.card.id) && !this.failedPhotoIds.has(entry.card.id))) void this.hydrateVisible(this.visibleFirst, this.visibleLast);
        else this.scheduleHomepagePrefetch(generation);
      }
    }
  }
  // 安排首页预取（空闲时进行）。
  private scheduleHomepagePrefetch(generation: number): void {
    if (!this.current(generation) || this.loading || this.loadingMore || this.submittedQuery === undefined || this.cards.length === 0) return;
    if (this.prefetchRunning || this.prefetchTimer !== undefined) return;
    const signature: string = this.cards.map((entry: DiscoveryEntry): string => this.prefetchCardKey(entry.card)).join('|');
    if (this.prefetchGeneration === generation && this.prefetchCompletedSignature === signature) return;
    this.prefetchRunning = true;
    void this.prefetchHomepage(generation).finally((): void => {
      this.prefetchRunning = false;
      // 后台请求结束时代次可能已被刷新替换，需再次检查。
      if (generation !== this.listGeneration) this.scheduleHomepagePrefetch(this.listGeneration);
    });
  }
  // 推迟预取（前台有更重要的请求时）。
  private deferPrefetch(generation: number): void {
    if (!this.current(generation) || this.prefetchTimer !== undefined) return;
    this.prefetchTimer = setTimeout((): void => {
      this.prefetchTimer = undefined;
      this.scheduleHomepagePrefetch(this.listGeneration);
    }, 400);
  }
  // 预取去重键。
  private prefetchCardKey(card: FoodCard): string { return card.id + ':' + (card.contentRevision || ''); }
  // 预取首页卡片的封面（全部封面优先于详情原图）。
  private async prefetchHomepage(generation: number): Promise<void> {
    if (this.prefetchGeneration !== generation) {
      this.prefetchGeneration = generation;
      if (this.prefetchOwner !== this.owner) { this.prefetchManifests.clear(); this.prefetchOwner = this.owner; }
      const keys: Set<string> = new Set<string>(this.cards.map((entry: DiscoveryEntry): string => this.prefetchCardKey(entry.card)));
      for (const key of this.prefetchManifests.keys()) if (!keys.has(key)) this.prefetchManifests.delete(key);
      this.prefetchManifestAttempts.clear(); this.prefetchPhotoAttempts.clear(); this.prefetchReadyPhotos.clear(); this.prefetchCoversSignature = ''; this.prefetchCompletedSignature = '';
      this.prefetchStartedAt = Date.now();
    }
    try {
      while (this.current(generation)) {
        if (this.loading || this.loadingMore || this.hydrationRunning || !ReadScheduler.canPrefetch()) { this.deferPrefetch(generation); return; }
        // 所有返回的封面（包括屏幕外的卡片）都优先于任何详情原图。
        const pendingCover: DiscoveryEntry | undefined = this.cards.find((entry: DiscoveryEntry): boolean =>
          !this.hydratedIds.has(entry.card.id) && !this.failedPhotoIds.has(entry.card.id));
        if (pendingCover !== undefined) {
          const card: FoodCard = pendingCover.card;
          await ImageRepository.hydrateCovers(this.context(), [card], async (): Promise<boolean> => this.current(generation),
            (settledCard: FoodCard): void => {
              if (!this.current(generation) || !this.cards.some((entry: DiscoveryEntry): boolean => entry.card === settledCard)) return;
              if (settledCard.mediaAccessDenied === true) { this.cards = this.cards.filter((entry: DiscoveryEntry): boolean => entry.card.id !== settledCard.id); return; }
              if (settledCard.primaryPhotoLoadFailed === true) this.failedPhotoIds.add(settledCard.id);
              else this.hydratedIds.add(settledCard.id);
              if (settledCard.id === this.cards[0]?.card.id && this.submittedQuery !== undefined && this.isPublicFeedQuery(this.submittedQuery) && settledCard.mediaContentChanged !== true && settledCard.primaryPhotoLoadFailed !== true) { this.onPrimaryCard(settledCard, this.primaryRemoteSync); this.primaryRemoteSync = false; }
              this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => {
                if (entry.card !== settledCard) return entry;
                const updated: DiscoveryEntry = { card: settledCard, coverUrl: settledCard.mediaContentChanged === true ? '' : settledCard.photoUrl, loadedAt: entry.loadedAt };
                return updated;
              });
            }, false, 'prefetch', (value: FoodCard): boolean => this.cards.some((entry: DiscoveryEntry): boolean => entry.card === value));
          if (!this.current(generation)) return;
          if (card.mediaContentChanged === true) await this.refreshChangedCards([card.id], generation);
          if (!this.hydratedIds.has(card.id) && !this.failedPhotoIds.has(card.id) && this.cards.some((entry: DiscoveryEntry): boolean => entry.card === card)) { this.deferPrefetch(generation); return; }
          continue;
        }
        if (this.cards.some((entry: DiscoveryEntry): boolean => this.failedPhotoIds.has(entry.card.id))) return;
        const coversSignature: string = this.cards.map((entry: DiscoveryEntry): string => this.prefetchCardKey(entry.card)).join('|');
        if (coversSignature !== this.prefetchCoversSignature) {
          this.prefetchCoversSignature = coversSignature;
          console.info('[DiscoveryFeed] event=all-covers-ready viewGeneration=' + generation + ' cards=' + this.cards.length + ' ms=' + (Date.now() - this.feedLoadStartedAt));
        }
        const missing: Array<FoodCard> = this.cards.map((entry: DiscoveryEntry): FoodCard => entry.card)
          .filter((card: FoodCard): boolean => card.photoPath.length > 0 && !this.prefetchManifests.has(this.prefetchCardKey(card)) && !this.prefetchManifestAttempts.has(this.prefetchCardKey(card))).slice(0, 10);
        if (missing.length > 0) {
          const request: CardPreviewsRequest = { cardIds: missing.map((card: FoodCard): string => card.id), includeDetailPhotos: true };
          const options: ReadRequestOptions = { priority: 'prefetch', mayContinue: async (): Promise<boolean> => this.current(generation) };
          try {
            const response: CardPreviewsResponse = await CloudGateway.callPublic<CardPreviewsResponse>('get-card-previews', request, options);
            if (!this.current(generation)) return;
            for (const card of missing) {
              const item: CardPreviewItem | undefined = response.items.find((value: CardPreviewItem): boolean => value.cardId === card.id);
              this.prefetchManifestAttempts.add(this.prefetchCardKey(card));
              if (item !== undefined && item.accessible && item.card !== null) {
                if (item.card.contentRevision === card.contentRevision) this.prefetchManifests.set(this.prefetchCardKey(card), item.card);
                else await this.refreshChangedCards([card.id], generation);
                if (!this.current(generation)) return;
              } else this.cards = this.cards.filter((entry: DiscoveryEntry): boolean => entry.card.id !== card.id);
            }
          } catch (error) {
            if (error instanceof ReadCancelledError) { this.deferPrefetch(generation); return; }
            for (const card of missing) this.prefetchManifestAttempts.add(this.prefetchCardKey(card));
            console.warn('[DiscoveryFeed] event=detail-prefetch-manifest-failed viewGeneration=' + generation);
          }
          continue;
        }
        let nextPhoto: CardPhoto | undefined = undefined;
        let photoKey: string = '';
        for (const entry of this.cards) {
          const key: string = this.prefetchCardKey(entry.card);
          const manifest: FoodCard | undefined = this.prefetchManifests.get(key);
          const photo: CardPhoto | undefined = manifest?.photos?.find((value: CardPhoto): boolean =>
            !this.prefetchPhotoAttempts.has(key + ':' + value.id));
          if (photo !== undefined) { nextPhoto = photo; photoKey = key + ':' + photo.id; break; }
        }
        if (nextPhoto === undefined) {
          this.prefetchCompletedSignature = coversSignature;
          console.info('[DiscoveryFeed] event=detail-prefetch-complete viewGeneration=' + generation + ' cards=' + this.cards.length + ' readyOriginals=' + this.prefetchReadyPhotos.size + ' attemptedOriginals=' + this.prefetchPhotoAttempts.size + ' failedManifests=' + this.cards.filter((entry: DiscoveryEntry): boolean => entry.card.photoPath.length > 0 && !this.prefetchManifests.has(this.prefetchCardKey(entry.card))).length + ' ms=' + (Date.now() - this.prefetchStartedAt));
          return;
        }
        try {
          const localUrl: string = await this.cardRepository.hydrateDetailPhoto(this.context(), nextPhoto, 'prefetch', async (): Promise<boolean> => this.current(generation));
          if (localUrl.length === 0) throw new Error('详情图片预加载未返回缓存地址。');
          if (!this.current(generation)) return;
          this.prefetchPhotoAttempts.add(photoKey); this.prefetchReadyPhotos.add(photoKey);
        } catch (error) {
          if (error instanceof ReadCancelledError) { this.deferPrefetch(generation); return; }
          this.prefetchPhotoAttempts.add(photoKey);
          console.warn('[DiscoveryFeed] event=detail-prefetch-photo-failed viewGeneration=' + generation + ' mediaId=' + nextPhoto.id);
        }
      }
    } catch (_error) {
      // 后台失败绝不替换前台列表的状态，也不会自动重试，避免错误风暴。
      console.warn('[DiscoveryFeed] event=detail-prefetch-stopped viewGeneration=' + generation);
    }
  }
  // 重新读取已变化的卡片（版本不一致时）。
  private async refreshChangedCards(ids: Array<string>, generation: number): Promise<void> {
    const options: ReadRequestOptions = { priority: 'secondary', mayContinue: async (): Promise<boolean> => this.current(generation) };
    for (let offset: number = 0; offset < ids.length && this.current(generation); offset += 10) {
      const request: CardPreviewsRequest = { cardIds: ids.slice(offset, offset + 10) };
      try {
        const result: CardPreviewsResponse = await CloudGateway.callPublic<CardPreviewsResponse>('get-card-previews', request, options);
        if (!this.current(generation)) return;
        for (const id of request.cardIds) {
          const item: CardPreviewItem | undefined = result.items.find((value: CardPreviewItem): boolean => value.cardId === id);
          if (item === undefined || !item.accessible || item.card === null) this.cards = this.cards.filter((entry: DiscoveryEntry): boolean => entry.card.id !== id);
          else {
            const card: FoodCard = item.card;
            const previous: DiscoveryEntry | undefined = this.cards.find((entry: DiscoveryEntry): boolean => entry.card.id === id);
            const reusable: boolean = previous !== undefined && previous.card.contentRevision === card.contentRevision && ImageRepository.canReuseCover(previous.card);
            if (reusable && previous !== undefined) { card.photoUrl = previous.coverUrl; card.primaryPhotoResolved = true; card.primaryPhotoLoadFailed = false; }
            const fresh: DiscoveryEntry = { card, coverUrl: reusable && previous !== undefined ? previous.coverUrl : '', loadedAt: Date.now() };
            this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => entry.card.id === id ? fresh : entry);
            if (!reusable) this.hydratedIds.delete(id); this.failedPhotoIds.delete(id);
          }
        }
      } catch (_error) {
        if (!this.current(generation)) return;
        // 已知的版本不一致需要用户手动重试；普通的缓存刷新失败不能阻塞独立的封面加载。
        for (const id of request.cardIds) {
          const entry: DiscoveryEntry | undefined = this.cards.find((value: DiscoveryEntry): boolean => value.card.id === id);
          if (entry !== undefined && entry.card.mediaContentChanged === true) { this.failedPhotoIds.add(id); this.hydratedIds.delete(id); }
        }
        this.status = '推荐更新失败，已保留缓存内容，可刷新重试。';
      }
    }
  }
  // 搜索输入变化。
  private inputChanged(value: string): void {
    this.keywordInput = value; this.listGeneration++; this.loading = false; this.loadingMore = false; this.nextCursor = ''; this.submittedQuery = undefined;
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    this.debounce = setTimeout((): void => { this.debounce = undefined; if (this.active) this.submitSearch(false); }, 300);
  }
  // 提交搜索。
  private submitSearch(recordHistory: boolean = true): void {
    if (!this.capabilities.searchEnabled) return;
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    this.keyword = normalizeSearch(this.keywordInput);
    if (this.keyword.length > 50) { this.status = '搜索内容最多 50 字符。'; return; }
    this.scope = 'ALL_PUBLIC'; this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined;
    void this.reload(recordHistory);
  }
  // 切换外卖 / 到店 / 全部。
  private selectMode(mode: DiscoveryMode): void {
    if (!this.capabilities.searchEnabled) return;
    if (this.mode === mode) return;
    this.mode = mode; this.closeMerchant(); this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined;
    void this.reload();
    if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, false);
  }
  // 地图视野变化。
  private changedViewport(viewport: DiscoveryViewport, camera: DiscoveryCamera): void {
    this.viewport = copyViewport(viewport); this.currentCamera = camera;
    try { MapViewportStore.save(this.context(), this.owner, camera); } catch (_error) { }
    const searched: DiscoveryViewport | undefined = this.searchedViewport;
    this.viewportDirty = searched === undefined || Math.abs(searched.north - viewport.north) > 0.000001 || Math.abs(searched.south - viewport.south) > 0.000001 ||
      Math.abs(searched.east - viewport.east) > 0.000001 || Math.abs(searched.west - viewport.west) > 0.000001;
    if (searched === undefined && this.capabilities.mapEnabled) void this.queryMap(viewport, false);
  }
  // 查询地图视野内的店铺。
  private async queryMap(bounds: DiscoveryViewport, more: boolean): Promise<void> {
    if (!this.capabilities.mapEnabled || (more && this.mapLoading)) return;
    const generation: number = ++this.mapGeneration; const uid: string = this.owner;
    const request: MapMerchantQuery = { viewport: copyViewport(bounds), mode: this.mode, cursor: more ? this.mapCursor : '', limit: 100 };
    this.mapLoading = true;
    if (!more) { this.merchants = []; this.mapCursor = ''; this.searchedViewport = copyViewport(bounds); this.mapEmpty = false; }
    try {
      const result: MapMerchantPage = await this.repository.map(request);
      if (!this.active || generation !== this.mapGeneration || uid !== this.viewer()) return;
      const merged: Array<MapMerchant> = more ? this.merchants.slice() : [];
      for (const value of result.merchants) if (!merged.some((entry: MapMerchant): boolean => entry.merchantId === value.merchantId)) merged.push(value);
      this.merchants = merged; this.mapCursor = result.nextCursor;
      const view: DiscoveryViewport | undefined = this.viewport;
      this.viewportDirty = view !== undefined && (Math.abs(view.north - bounds.north) > 0.000001 || Math.abs(view.south - bounds.south) > 0.000001 || Math.abs(view.east - bounds.east) > 0.000001 || Math.abs(view.west - bounds.west) > 0.000001);
      this.mapEmpty = merged.length === 0 && result.coverage === 'COMPLETE';
      this.mapStatus = result.coverage !== 'COMPLETE' ? '仅显示部分地点，请放大地图或继续搜索。' : this.mapEmpty ? '当前区域没有可展示的店铺。' : '已显示当前区域的可展示店铺。';
      if (this.mapEmpty && this.scope === 'VIEWPORT' && this.previousCards.length > 0) {
        if (!this.active || generation !== this.mapGeneration || uid !== this.viewer()) return; this.cards = this.previousCards.map((entry: DiscoveryEntry): DiscoveryEntry => { return { card: entry.card, coverUrl: '', loadedAt: entry.loadedAt }; }); this.hydratedIds.clear(); this.showingPrevious = true; this.nextCursor = ''; void this.hydrateVisible(0, 3);
      }
    } catch (failure) {
      if (!this.active || generation !== this.mapGeneration || uid !== this.viewer()) return;
      if (failure instanceof CloudBusinessError && failure.code === 'CURSOR_STALE') { this.mapCursor = ''; this.mapStatus = '地图分页已变化，请重新搜索此区域。'; }
      else if (failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY') { this.merchants = []; this.onUnavailable(); }
      else this.mapStatus = stage47ErrorText(failure as Object, '地图加载失败。');
    } finally { if (this.active && generation === this.mapGeneration && uid === this.viewer()) this.mapLoading = false; }
  }
  // “搜索此区域”。
  private searchArea(): void {
    const bounds: DiscoveryViewport | undefined = this.viewport;
    if (bounds === undefined) return;
    if (this.scope === 'VIEWPORT' && this.queryViewport !== undefined && this.queryCamera !== undefined && !this.showingPrevious && this.cards.length > 0) {
      const previous: PreviousRegion = { viewport: copyViewport(this.queryViewport), camera: this.queryCamera };
      this.previousResultRegion = previous; this.previousCards = this.cards.slice();
    }
    this.closeMerchant(); this.mapEmpty = false; this.showingPrevious = false;
    if (this.capabilities.searchEnabled) { this.scope = 'VIEWPORT'; this.queryViewport = copyViewport(bounds); this.queryCamera = this.currentCamera; void this.reload(); }
    void this.queryMap(bounds, false);
  }
  // “返回上一地区”。
  private returnPrevious(): void {
    const previous: PreviousRegion | undefined = this.previousResultRegion;
    if (previous === undefined) return;
    this.cameraTarget = previous.camera; this.queryCamera = previous.camera; this.currentCamera = previous.camera; this.queryViewport = copyViewport(previous.viewport); this.scope = 'VIEWPORT';
    this.showingPrevious = false; this.mapEmpty = false; void this.reload(); void this.queryMap(previous.viewport, false);
  }
  // 关闭店铺面板。
  private closeMerchant(): void {
    this.merchantGeneration++; this.selectedMerchant = undefined; this.selectedMerchantId = '';
    this.merchantCards = []; this.merchantCursor = ''; this.merchantLoading = false;
  }
  // 选中地图上的店铺。
  private selectMerchant(merchant: MapMerchant): void {
    this.closeMerchant(); this.listOpen = false; this.filtersOpen = false; this.historyOpen = false;
    this.selectedMerchant = merchant; this.selectedMerchantId = merchant.merchantId; this.merchantCards = []; this.merchantCursor = '';
    const index: number = this.cards.findIndex((entry: DiscoveryEntry): boolean => entry.card.merchantId === merchant.merchantId);
    if (!this.expanded && index >= 0) this.resultScroller.scrollToIndex(index, false, ScrollAlign.START);
    void this.loadMerchant(false);
  }
  // 加载店铺推荐卡片。
  private async loadMerchant(more: boolean): Promise<void> {
    const merchant: MapMerchant | undefined = this.selectedMerchant;
    if (merchant === undefined || this.merchantLoading) return;
    const generation: number = ++this.merchantGeneration; const uid: string = this.owner;
    const request: MerchantRecommendationQuery = { merchantId: merchant.merchantId, mode: this.mode, cursor: more ? this.merchantCursor : '', pageSize: 10 };
    this.merchantLoading = true; this.merchantStatus = '正在读取商家公开推荐…';
    try {
      const page: DiscoveryCardPage = await this.repository.merchant(request);
      if (!this.active || generation !== this.merchantGeneration || uid !== this.viewer()) return;
      const existing: Array<DiscoveryEntry> = this.entries(more ? this.merchantCards : []);
      this.merchantCards = this.merge(existing, page.cards).map((entry: DiscoveryEntry): FoodCard => entry.card);
      this.merchantCursor = page.nextCursor;
      this.merchantStatus = this.resultStatus(this.merchantCards.length, page.coverage, page.nextCursor);
      if (this.merchantCards.length === 0 && page.coverage === 'COMPLETE') {
        this.merchantStatus = '该店铺当前没有可读取推荐，请刷新地图。';
        this.merchants = this.merchants.filter((value: MapMerchant): boolean => value.merchantId !== merchant.merchantId);
        if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, false);
      }
      await this.cardRepository.hydrateNearbyPrimaryPhotoUrls(this.context(), page.cards, 0, Math.min(page.cards.length, 10), 'normal',
        async (): Promise<boolean> => this.active && generation === this.merchantGeneration && uid === this.viewer());
      if (this.active && generation === this.merchantGeneration && uid === this.viewer()) this.merchantCards = this.merchantCards.slice();
    } catch (failure) {
      if (!this.active || generation !== this.merchantGeneration || uid !== this.viewer()) return;
      if (failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY') { this.closeMerchant(); this.onUnavailable(); return; }
      if (failure instanceof CloudBusinessError && failure.code === 'CURSOR_STALE') this.merchantCursor = '';
      if (failure instanceof CloudBusinessError && failure.code === 'MERCHANT_UNAVAILABLE') {
        this.merchants = this.merchants.filter((value: MapMerchant): boolean => value.merchantId !== merchant.merchantId);
        if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, false);
      }
      this.merchantStatus = stage47ErrorText(failure as Object, '店铺推荐加载失败。');
    } finally { if (this.active && generation === this.merchantGeneration && uid === this.viewer()) this.merchantLoading = false; }
  }
  // 打开卡片详情。
  private openCard(card: FoodCard): void {
    const merchant: MapMerchant | undefined = this.merchants.find((value: MapMerchant): boolean => value.merchantId === card.merchantId);
    if (!this.showingPrevious && merchant !== undefined) { this.selectedMerchantId = merchant.merchantId; this.cameraTarget = { latitude: merchant.latitude, longitude: merchant.longitude, zoom: Math.max(15, this.currentCamera.zoom) }; }
    this.onOpenCard(card);
  }
  // 封面解码失败时清除缓存并重试。
  private coverFailed(card: FoodCard): void {
    const currentEntry: DiscoveryEntry | undefined = this.cards.find((entry: DiscoveryEntry): boolean => entry.card.id === card.id);
    if (!this.active || currentEntry === undefined || (currentEntry.card !== card && currentEntry.card.contentRevision !== card.contentRevision)) return;
    card = currentEntry.card;
    card.photoUrl = ''; card.primaryPhotoLoadFailed = true; this.failedPhotoIds.add(card.id); this.hydratedIds.delete(card.id);
    this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => { const failed: DiscoveryEntry = { card, coverUrl: '', loadedAt: entry.loadedAt }; return entry.card.id === card.id ? failed : entry; });
  }
  // 切换分类筛选（最多 3 类）。
  private toggleCategory(key: FoodCategoryV2): void {
    this.filterError = '';
    if (this.draftCategories.includes(key)) this.draftCategories = this.draftCategories.filter((value: FoodCategoryV2): boolean => value !== key);
    else if (this.draftCategories.length < 3) this.draftCategories = this.draftCategories.concat([key]);
    else this.filterError = '最多选择 3 个分类。';
  }
  // 切换面板。
  private setPanel(panel: DiscoveryPanel): void {
    const options: AnimateParam = { duration: this.motionActive ? 180 : 0, curve: Curve.EaseOut };
    this.getUIContext().animateTo(options, (): void => {
      this.categoriesOpen = panel === 'CATEGORIES'; this.filtersOpen = panel === 'FILTERS'; this.historyOpen = panel === 'HISTORY';
    });
  }
  // 打开筛选面板。
  private openFilters(): void {
    this.draftCategories = this.categories.slice(); this.draftSort = this.sort;
    this.draftPriceMin = this.priceMin; this.draftPriceMax = this.priceMax; this.draftPricePreset = this.pricePreset;
    this.filterError = ''; this.setPanel('FILTERS');
  }
  // 点击分类快捷入口。
  private selectCategory(key: DiscoveryCategoryKey): void {
    if (!this.capabilities.searchEnabled) return;
    if (key === 'MORE') { this.setPanel(this.categoriesOpen ? 'NONE' : 'CATEGORIES'); return; }
    this.setPanel('NONE');
    if (key === 'ALL' && this.categories.length === 0 || this.categories.length === 1 && this.categories[0] === key) return;
    this.categories = key === 'ALL' ? [] : [key];
    this.closeMerchant(); this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined;
    void this.reload();
  }
  // 快捷入口是否选中。
  private shortcutSelected(key: DiscoveryCategoryKey): boolean {
    if (key === 'ALL') return this.categories.length === 0;
    if (key === 'MORE') return this.categories.length > 1 || this.categories.length === 1 &&
      !DISCOVERY_SHORTCUTS.some((item: DiscoveryShortcut): boolean => item.key === this.categories[0]);
    return this.categories.length === 1 && this.categories[0] === key;
  }
  // 快捷入口文字。
  private shortcutLabel(shortcut: DiscoveryShortcut): string {
    if (shortcut.key !== 'MORE' || !this.shortcutSelected('MORE')) return shortcut.label;
    return this.categories.length === 1 ? categoryV2Label(this.categories[0]) : '组合分类';
  }
  // 进入地图浏览。
  private browseMap(): void {
    this.setPanel('NONE'); this.cameraTarget = this.currentCamera; this.expanded = true; this.listOpen = false;
  }
  // 刷新推荐流。
  private refreshFeed(): void {
    this.setPanel('NONE'); DiscoveryFeedState.clear(); void this.reload(false, true);
  }
  // 分类可用性说明。
  private categoryAvailabilityText(): string {
    if (this.capabilitiesLoading) return '正在检查分类是否可用…';
    if (this.capabilities.searchReason === 'CAPABILITIES_LOAD_FAILED') return '分类暂时无法连接，可重新检查。';
    if (this.capabilities.searchReason === 'CARD_HISTORY_REQUIRED') return '分类历史数据尚未整理完成，可先浏览全部推荐。';
    if (this.capabilities.searchReason === 'INDEX_VERIFICATION_REQUIRED') return '分类查询尚未完成验证，可先浏览全部推荐。';
    if (this.capabilities.searchReason === 'HISTORY_OR_INDEX_REQUIRED') return '分类数据或查询尚未就绪，可先浏览全部推荐。';
    if (this.capabilities.searchReason === 'VALIDATION_REQUIRED') return '分类功能正在准备中，可先浏览全部推荐。';
    return '分类暂时不可用，可先浏览全部推荐。';
  }
  // 筛选条件摘要。
  private filterSummary(): string {
    const categories: string = this.categories.length === 0 ? '全部分类' : this.categories.map((key: FoodCategoryV2): string => categoryV2Label(key)).join('、');
    const price: string = this.pricePreset >= 0 ? this.pricePreset === 3 ? '¥30 起' : '¥' + this.pricePreset * 10 + '–' + (this.pricePreset + 1) * 10 : this.priceMin.length > 0 ? '自定义价格' : '不限价格';
    const option: SortOption | undefined = SORT_OPTIONS.find((value: SortOption): boolean => value.value === this.sort);
    return categories + ' · ' + price + ' · ' + (option === undefined ? '最新发布' : option.label);
  }
  // 清除筛选条件。
  private resetFilters(): void { this.categories = []; this.pricePreset = -1; this.priceMin = ''; this.priceMax = ''; this.sort = 'LATEST'; }
  // 重置筛选面板中的草稿条件。
  private resetDraftFilters(): void {
    this.draftCategories = []; this.draftPricePreset = -1; this.draftPriceMin = ''; this.draftPriceMax = '';
    this.draftSort = 'LATEST'; this.filterError = '';
  }
  // 应用筛选面板中的条件。
  private applyFilters(): void {
    const draft: DiscoveryFilterValues = { categories: this.draftCategories.slice(), sort: this.draftSort,
      priceMin: this.draftPriceMin, priceMax: this.draftPriceMax, pricePreset: this.draftPricePreset };
    try { this.makeQuery('', draft); } catch (failure) { this.filterError = stage47ErrorText(failure as Object, '筛选条件无效。'); return; }
    this.categories = draft.categories; this.sort = draft.sort; this.pricePreset = draft.pricePreset;
    this.priceMin = draft.priceMin; this.priceMax = draft.priceMax;
    this.setPanel('NONE'); this.closeMerchant(); this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined; void this.reload();
  }
  // 模式切换按钮。
  @Builder
  private modeButton(mode: DiscoveryMode, label: string): void {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 5 }) {
        Text(label).fontSize(15).fontWeight(this.mode === mode ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.mode === mode ? $r('app.color.discovery_ink') : $r('app.color.discovery_muted'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {}.width(24).height(3).borderRadius(2)
          .backgroundColor(this.mode === mode ? $r('app.color.discovery_gold') : Color.Transparent)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }.height(44).layoutWeight(1).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
      .enabled(this.capabilities.searchEnabled).opacity(this.capabilities.searchEnabled || mode === 'ALL' ? 1 : 0.45)
      .accessibilityText(label + (this.mode === mode ? '，已选中' : '，未选中'))
      .accessibilitySelected(this.mode === mode).onClick((): void => this.selectMode(mode))
  }
  // 快捷入口边框。
  private shortcutBorder(key: DiscoveryCategoryKey): BorderOptions {
    if (this.shortcutSelected(key)) {
      const selected: BorderOptions = { width: 2, color: $r('app.color.discovery_accent'), style: BorderStyle.Solid };
      return selected;
    }
    const idle: BorderOptions = { width: 1.2, color: $r('app.color.discovery_line'), style: BorderStyle.Dashed };
    return idle;
  }
  // 一个分类快捷入口。
  @Builder
  private categoryShortcut(shortcut: DiscoveryShortcut): void {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Stack() {
          // 这些图标是带有亮/暗两套文件的多色图，着色会把线条和填充压成一种颜色，所以放在中性底色上按原样绘制。
          Image(discoveryCategoryIcon(shortcut.key)).width(30).height(30).objectFit(ImageFit.Contain)
            .accessibilityLevel('no')
        }.width(44).height(44).borderRadius(15)
          .backgroundColor(this.shortcutSelected(shortcut.key) ? $r('app.color.discovery_soft') : $r('app.color.discovery_surface'))
          .border(this.shortcutBorder(shortcut.key))
        Text(this.shortcutLabel(shortcut)).fontSize(11).fontWeight(this.shortcutSelected(shortcut.key) ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.shortcutSelected(shortcut.key) ? $r('app.color.discovery_accent') : $r('app.color.discovery_muted'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').textAlign(TextAlign.Center)
      }.width('100%').justifyContent(FlexAlign.Center)
    }.layoutWeight(1).height(64).constraintSize({ minWidth: 44 }).padding(0).borderRadius(14).backgroundColor(Color.Transparent)
      .enabled(this.capabilities.searchEnabled).opacity(this.capabilities.searchEnabled ? 1 : 0.5)
      .accessibilityText(this.shortcutLabel(shortcut) + (this.shortcutSelected(shortcut.key) ? '，已选中' : '') +
        (this.capabilities.searchEnabled ? '' : '，分类暂未开放'))
      .accessibilitySelected(this.shortcutSelected(shortcut.key)).onClick((): void => this.selectCategory(shortcut.key))
  }
  // 图标按钮。
  @Builder
  private iconAction(icon: Resource, label: string, action: () => void, enabled: boolean = true): void {
    Button({ type: ButtonType.Normal }) {
      Image(icon).width(20).height(20).objectFit(ImageFit.Contain).fillColor($r('app.color.discovery_accent')).accessibilityLevel('no')
    }.width(44).height(44).padding(10).backgroundColor(Color.Transparent).borderRadius(14)
      .enabled(enabled).opacity(enabled ? 1 : 0.45).accessibilityText(label).onClick(action)
  }
  // 顶部区域（搜索框、快捷入口）。
  @Builder
  private homeHeader(): void {
    Row({ space: 8 }) {
      Text('食刻').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.discovery_ink'))
      Text(this.owner === 'guest' ? '游客 · 发现好味道' : '发现每一餐的好味道').fontSize(11).fontColor($r('app.color.discovery_muted'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('吃什么 ›').height(44).constraintSize({ minWidth: 72 }).fontSize(13).padding({ left: 12, right: 12 })
        .borderRadius(18).backgroundColor($r('app.color.discovery_soft')).fontColor($r('app.color.discovery_accent'))
        .accessibilityText('今日吃什么，随机翻三张').onClick((): void => this.onOpenMeal())
    }.width('100%').height(44)
    if (this.capabilities.searchEnabled) {
      Row({ space: 2 }) {
        Image($r('app.media.ic_discovery_search')).width(18).height(18).margin({ left: 12 }).accessibilityLevel('no')
        TextInput({ text: this.keywordInput, placeholder: '搜索菜品、店名' }).height(48).layoutWeight(1).maxLength(50)
          .fontSize(14).fontColor($r('app.color.discovery_ink')).placeholderColor($r('app.color.discovery_muted'))
          .backgroundColor(Color.Transparent).padding({ left: 6, right: 4 }).caretColor($r('app.color.discovery_accent'))
          .accessibilityText('搜索菜品或店名').onChange((value: string): void => this.inputChanged(value)).onSubmit((): void => this.submitSearch())
        this.iconAction($r('app.media.ic_discovery_history'), '本机搜索历史', (): void => this.setPanel(this.historyOpen ? 'NONE' : 'HISTORY'))
        Button('搜索').height(44).fontSize(13).padding({ left: 12, right: 12 }).borderRadius(14)
          .backgroundColor($r('app.color.discovery_gold')).fontColor($r('app.color.discovery_on_gold'))
          .onClick((): void => this.submitSearch())
      }.width('100%').padding({ right: 4 }).backgroundColor($r('app.color.discovery_surface')).borderRadius(18)
    }
    Row() {
      ForEach(DISCOVERY_SHORTCUTS, (shortcut: DiscoveryShortcut) => { this.categoryShortcut(shortcut); },
        (shortcut: DiscoveryShortcut): string => shortcut.key)
    }.width('100%')
    Row() {
      Row({ space: 2 }) {
        this.modeButton('ALL', '推荐'); this.modeButton('DELIVERY', '外卖'); this.modeButton('DINE_IN', '到店');
      }.layoutWeight(1)
      if (this.capabilities.searchEnabled) { this.iconAction($r('app.media.ic_discovery_filter'), '高级筛选与排序，' + this.filterSummary(), (): void => this.openFilters()); }
      if (this.capabilities.mapEnabled) { this.iconAction($r('app.media.map_marker'), '浏览地图', (): void => this.browseMap()); }
      this.iconAction($r('app.media.ic_discovery_refresh'), '刷新推荐', (): void => this.refreshFeed(), !this.loading)
    }.width('100%')
    if (this.categories.length > 0 || this.pricePreset >= 0 || this.priceMin.length > 0 || this.sort !== 'LATEST') {
      Text(this.filterSummary()).width('100%').fontSize(12).fontColor($r('app.color.discovery_muted'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ bottom: 4 })
    }
  }
  // 分类面板。
  @Builder
  private categoryPanel(): void {
    Scroll() {
      Column({ space: 8 }) {
        Text('点选一个分类，立即更新推荐').fontSize(13).fontColor($r('app.color.discovery_muted')).width('100%')
        Button('全部分类').width('100%').height(48).onClick((): void => this.selectCategory('ALL'))
          .attributeModifier(new DiscoveryChoiceStyle(this.categories.length === 0))
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(CATEGORY_V2_OPTIONS, (option: CategoryV2Option) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 6 }) {
                Image(discoveryCategoryIcon(option.key)).width(30).height(30).objectFit(ImageFit.Contain).accessibilityLevel('no')
                Text(option.label).fontSize(12).fontColor($r('app.color.discovery_ink')).maxLines(2).textAlign(TextAlign.Center)
              }.width('100%').justifyContent(FlexAlign.Center)
            }.width('31%').height(78).padding(6).margin({ right: '2%', bottom: 8 }).borderRadius(14)
              .backgroundColor(this.categories.length === 1 && this.categories[0] === option.key ? $r('app.color.discovery_soft') : $r('app.color.discovery_surface'))
              .border({ width: 1, color: this.categories.length === 1 && this.categories[0] === option.key ? $r('app.color.discovery_accent') : $r('app.color.discovery_line') })
              .accessibilitySelected(this.categories.length === 1 && this.categories[0] === option.key)
              .accessibilityText(option.label).onClick((): void => this.selectCategory(option.key))
          }, (option: CategoryV2Option): string => option.key)
        }.width('100%')
      }.width('100%')
    }.width('100%').height(Math.min(400, this.availableHeight * 0.62)).scrollBar(BarState.Off)
  }
  // 筛选面板。
  @Builder
  private filterPanel(): void {
    Scroll() {
      Column({ space: 8 }) {
        Text('分类最多选 3 项，按任一分类匹配').fontSize(13).fontColor($r('app.color.discovery_muted')).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(CATEGORY_V2_OPTIONS, (option: CategoryV2Option) => {
            Button(option.label).height(48).fontSize(12).margin({ right: 8, bottom: 8 })
              .accessibilityText(option.label + (this.draftCategories.includes(option.key) ? '，已选中' : '，未选中'))
              .onClick((): void => this.toggleCategory(option.key)).attributeModifier(new DiscoveryChoiceStyle(this.draftCategories.includes(option.key)))
          }, (option: CategoryV2Option): string => option.key)
        }.width('100%')
        Text('按外卖单品／到店人均筛选，未知价格不进入区间。').fontSize(12).fontColor($r('app.color.discovery_muted'))
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([0, 1, 2, 3], (value: number) => {
            Button(value === 3 ? '30 元起' : value * 10 + '–' + (value + 1) * 10 + ' 元').height(48).margin(4)
              .onClick((): void => { this.draftPricePreset = this.draftPricePreset === value ? -1 : value; this.draftPriceMin = ''; this.draftPriceMax = ''; this.filterError = ''; })
              .attributeModifier(new DiscoveryChoiceStyle(this.draftPricePreset === value))
          }, (value: number): string => value.toString())
        }.width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.draftPriceMin, placeholder: '最低价（元）' }).height(48).layoutWeight(1).maxLength(12)
            .fontSize(14).fontColor($r('app.color.discovery_ink')).backgroundColor($r('app.color.discovery_canvas'))
            .accessibilityText('最低价格，单位元').onChange((value: string): void => { this.draftPriceMin = value; this.draftPricePreset = -1; this.filterError = ''; })
          TextInput({ text: this.draftPriceMax, placeholder: '最高价，不含' }).height(48).layoutWeight(1).maxLength(12)
            .fontSize(14).fontColor($r('app.color.discovery_ink')).backgroundColor($r('app.color.discovery_canvas'))
            .accessibilityText('最高价格，不含上限，单位元').onChange((value: string): void => { this.draftPriceMax = value; this.draftPricePreset = -1; this.filterError = ''; })
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SORT_OPTIONS, (option: SortOption) => {
            Button(option.label).height(48).margin({ right: 8, bottom: 8 }).onClick((): void => { this.draftSort = option.value; })
              .attributeModifier(new DiscoveryChoiceStyle(this.draftSort === option.value))
          }, (option: SortOption): string => option.value)
        }.width('100%')
        if (this.filterError.length > 0) { Text(this.filterError).width('100%').fontSize(13).fontColor($r('app.color.danger')); }
        Row({ space: 8 }) {
          Button('清除筛选').height(48).layoutWeight(1).onClick((): void => this.resetDraftFilters()).attributeModifier(new DiscoveryActionStyle())
          Button('应用筛选').height(48).layoutWeight(1).onClick((): void => this.applyFilters()).attributeModifier(new DiscoveryActionStyle(true))
        }.width('100%')
      }.width('100%').padding(4)
    }.width('100%').height(Math.min(420, this.availableHeight * 0.62)).scrollBar(BarState.Off)
  }
  // 封面缩放比例。
  private coverScale(): number {
    if (this.windowBreakpoint === 'sm' || this.waterfallWidthVp <= 0) return 1;
    const columns: number = BreakpointSystem.columns(this.windowBreakpoint);
    const cardWidth: number = (this.waterfallWidthVp - (columns - 1) * BreakpointSystem.CARD_GAP) / columns;
    return Math.max(1, Math.min(1.45, (cardWidth - 20) / 150));
  }
  // 分页底部提示。
  @Builder
  private paginationFooter(): void {
    Column({ space: 6 }) {
      if (this.loadingMore) {
        Row({ space: 8 }) {
          DiscoveryLoadingMark({ markSize: 24, motionEnabled: this.motionActive });
          Text('正在加载更多推荐…').fontSize(13).fontColor($r('app.color.discovery_muted'));
        }.width('100%').constraintSize({ minHeight: 40 }).justifyContent(FlexAlign.Center);
      } else if (this.loadMoreFailed) {
        Text('加载暂时失败，请点击顶部刷新重试。').fontSize(13).lineHeight(19)
          .fontColor($r('app.color.discovery_muted')).width('100%').textAlign(TextAlign.Center);
      } else if (this.nextCursor.length === 0 && !this.loading && !this.showingPrevious) {
        Text('已经到底了').fontSize(12).fontColor($r('app.color.discovery_muted')).width('100%').textAlign(TextAlign.Center);
      }
    }.width('100%').padding({ top: 8, bottom: 12 });
  }
  // 卡片结果区（瀑布流）。
  @Builder
  private cardResults(): void {
    if (this.showingPrevious || this.scope === 'VIEWPORT') {
      Row({ space: 8 }) {
        Text(this.showingPrevious ? '上一地区结果' : '本区域推荐').layoutWeight(1).fontSize(13).fontColor($r('app.color.discovery_ink'))
        Button(this.showingPrevious ? '返回上一地区' : '搜全部公开').height(48).fontSize(12)
          .onClick((): void => { if (this.showingPrevious) this.returnPrevious(); else this.submitSearch(false); }).attributeModifier(new DiscoveryActionStyle())
      }.width('100%')
    }
    if (this.loading && this.cards.length > 0) {
      Row({ space: 8 }) {
        DiscoveryLoadingMark({ markSize: 24, motionEnabled: this.motionActive })
        Text('正在刷新好味道').fontSize(12).fontColor($r('app.color.discovery_accent'))
      }.width('100%').height(36).justifyContent(FlexAlign.Center).backgroundColor($r('app.color.discovery_soft')).borderRadius(12)
    } else if (this.cards.length > 0 && (this.loadFailed || this.loadMoreFailed)) {
      // 正常状态下不显示状态行，让第一张卡片更靠上；出错时仍然显示原因。
      Text(this.status).width('100%').fontSize(12).fontColor(this.loadFailed || this.loadMoreFailed ? $r('app.color.danger') : $r('app.color.discovery_muted'))
        .maxLines(this.loadFailed || this.loadMoreFailed ? 2 : 1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.loadFailed) { Button('重试刷新').height(48).onClick((): void => this.refreshFeed()).attributeModifier(new DiscoveryActionStyle()); }
    }
    if (this.cards.length === 0) {
      Column({ space: 14 }) {
        if (this.loading || this.loadingMore) {
          DiscoveryLoadingMark({ markSize: 58, motionEnabled: this.motionActive })
          Text('正在发现好味道').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.discovery_ink'))
          Text('加载就绪后显示商品与实拍图').fontSize(13).fontColor($r('app.color.discovery_muted'))
        } else if (this.loadFailed || this.loadMoreFailed) {
          Text(this.featureNotReady ? '推荐暂未开放' : '推荐暂时加载失败').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.discovery_ink'))
          Text(this.status).fontSize(14).lineHeight(21).fontColor($r('app.color.discovery_muted')).textAlign(TextAlign.Center).width('100%')
          Button('重新加载').height(48).onClick((): void => { void this.reload(); }).attributeModifier(new DiscoveryActionStyle(true))
        } else {
          Image($r('app.media.ic_discovery_search')).width(36).height(36).accessibilityLevel('no')
          Text(this.nextCursor.length > 0 ? '扫描尚未完成' : '没有符合条件的推荐').fontSize(18).fontColor($r('app.color.discovery_ink'))
          Text(this.status).fontSize(13).fontColor($r('app.color.discovery_muted')).textAlign(TextAlign.Center).width('100%')
          if (this.nextCursor.length === 0 && this.capabilities.searchEnabled) {
            Button('清除筛选并搜索全部').height(48).onClick((): void => { this.resetFilters(); this.keywordInput = ''; this.submitSearch(false); })
              .attributeModifier(new DiscoveryActionStyle(true))
          }
        }
      }.layoutWeight(1).width('100%').padding(20).justifyContent(FlexAlign.Center)
    } else {
      WaterFlow({ scroller: this.resultScroller, footer: (): void => { this.paginationFooter(); } }) {
        LazyForEach(this.cardSource, (entry: DiscoveryEntry, index: number) => {
          FlowItem() {
            DiscoveryCard({ card: entry.card, coverUrl: entry.coverUrl, featured: index % 2 === 0, coverScale: this.coverScale(),
              marketStyle: true, motionEnabled: this.motionActive,
              selected: !this.showingPrevious && this.selectedMerchantId.length > 0 && entry.card.merchantId === this.selectedMerchantId,
              onCoverFailed: (): void => this.coverFailed(entry.card),
              onRetry: (): void => { ImageRepository.retryUnavailableService(); this.failedPhotoIds.delete(entry.card.id); this.hydratedIds.delete(entry.card.id); void this.hydrateVisible(index, index); },
              onOpen: (): void => this.openCard(entry.card) })
          }.width('100%')
        }, (entry: DiscoveryEntry): string => this.entryRenderKey(entry))
      }.width('100%').layoutWeight(1).cachedCount(4).columnsTemplate(BreakpointSystem.columnsTemplate(this.windowBreakpoint))
        .columnsGap(BreakpointSystem.CARD_GAP).rowsGap(BreakpointSystem.CARD_GAP).scrollBar(BarState.Off)
        .opacity(this.resultOpacity).translate({ y: this.resultOffset }).onAppear((): void => this.revealResults())
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const width: number = Number(newArea.width);
          if (Number.isFinite(width) && width > 0 && this.waterfallWidthVp !== width) this.waterfallWidthVp = width;
        })
        .onScrollStart((): void => { this.scrolling = true; })
        .onScrollStop((): void => { this.scrolling = false; this.scheduleBottomPage(this.listGeneration); })
        .onReachEnd((): void => { void this.loadMore(true); })
        .onScrollIndex((first: number, last: number): void => {
          void this.hydrateVisible(first, last);
        })
    }
    if (!this.capabilities.searchEnabled && !this.expanded) {
      Row({ space: 8 }) {
        Text(this.categoryAvailabilityText()).fontSize(12).fontColor($r('app.color.discovery_muted')).layoutWeight(1)
        Button(this.capabilitiesLoading ? '检查中…' : '重新检查').constraintSize({ minWidth: 104, minHeight: 48 })
          .enabled(!this.capabilitiesLoading && !this.loading && !this.loadingMore)
          .accessibilityText(this.capabilitiesLoading ? '正在检查分类是否可用' : '重新检查分类是否可用')
          .onClick((): void => this.onReloadCapabilities()).attributeModifier(new DiscoveryActionStyle())
      }.width('100%')
    }
  }
  // 面板标题。
  @Builder
  private panelHeading(title: string): void {
    Row() {
      Text(title).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.discovery_ink')).layoutWeight(1)
      Button('关闭').height(48).fontSize(13).onClick((): void => this.setPanel('NONE')).attributeModifier(new DiscoveryActionStyle())
    }.width('100%')
  }
  // 页面布局。
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      DiscoveryBackdrop()
      Column({ space: 4 }) {
        if (!this.expanded) {
          this.homeHeader();
          this.cardResults();
        } else {
          Row({ space: 8 }) {
            Text('地图浏览').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.discovery_ink')).layoutWeight(1)
            Button('返回商品流').height(48).fontSize(13).onClick((): void => { this.expanded = false; this.listOpen = false; this.closeMerchant(); })
              .attributeModifier(new DiscoveryActionStyle())
          }.width('100%')
          if (this.availableHeight >= 360) {
            Row({ space: 6 }) { this.modeButton('ALL', '推荐'); this.modeButton('DELIVERY', '外卖'); this.modeButton('DINE_IN', '到店'); }.width('100%')
          }
          if (this.capabilities.mapEnabled) {
            DiscoveryMap({ merchants: this.merchants, selectedMerchantId: this.selectedMerchantId, camera: this.cameraTarget, expanded: true,
              dirty: this.viewportDirty, loading: this.mapLoading,
              onViewport: (viewport: DiscoveryViewport, camera: DiscoveryCamera): void => this.changedViewport(viewport, camera),
              onSelect: (merchant: MapMerchant): void => this.selectMerchant(merchant), onSearch: (): void => this.searchArea(),
              onExpand: (): void => { this.cameraTarget = this.currentCamera; this.expanded = false; this.listOpen = false; this.closeMerchant(); } })
              .width('100%').layoutWeight(1)
            Text(this.mapStatus).fontSize(12).fontColor($r('app.color.discovery_muted')).maxLines(2).width('100%')
            if (this.mapCursor.length > 0) {
              Button(this.mapLoading ? '搜索中…' : '继续搜索区域地点').height(48).enabled(!this.mapLoading)
                .onClick((): void => { if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, true); })
                .attributeModifier(new DiscoveryActionStyle())
            }
          }
          Button('展开推荐列表').width('100%').height(48).onClick((): void => { this.closeMerchant(); this.listOpen = true; })
            .attributeModifier(new DiscoveryActionStyle())
        }
      }.height('100%').width('100%').padding({ left: BreakpointSystem.pagePadding(this.windowBreakpoint), right: BreakpointSystem.pagePadding(this.windowBreakpoint), top: 8, bottom: 8 })
      if (!this.expanded && (this.categoriesOpen || this.filtersOpen || this.historyOpen)) {
        Button({ type: ButtonType.Normal }) {}.width('100%').height('100%').borderRadius(0).padding(0)
          .backgroundColor($r('app.color.scrim')).accessibilityText('关闭当前面板').onClick((): void => this.setPanel('NONE'))
      }
      if (this.expanded && this.listOpen) {
        Column({ space: 6 }) {
          Button('收起推荐列表').width('100%').height(48).onClick((): void => { this.listOpen = false; }).attributeModifier(new DiscoveryActionStyle())
          this.cardResults();
        }.width('94%').height(Math.min(this.availableHeight * 0.7, 560)).padding(12).margin({ bottom: 8 })
          .backgroundColor($r('app.color.discovery_surface')).borderRadius(20).border({ width: 1, color: $r('app.color.discovery_line') })
      }
      if (this.categoriesOpen && !this.expanded) {
        Column({ space: 8 }) { this.panelHeading('选择分类'); this.categoryPanel(); }
          .width('94%').padding(14).margin({ bottom: 8 }).backgroundColor($r('app.color.discovery_surface')).borderRadius(20)
          .transition(discoveryPanelTransition(this.motionActive))
      }
      if (this.filtersOpen && !this.expanded) {
        Column({ space: 8 }) { this.panelHeading('筛选与排序'); this.filterPanel(); }
          .width('94%').padding(14).margin({ bottom: 8 }).backgroundColor($r('app.color.discovery_surface')).borderRadius(20)
          .transition(discoveryPanelTransition(this.motionActive))
      }
      if (this.historyOpen && !this.expanded) {
        Column({ space: 8 }) {
          this.panelHeading('搜索历史');
          Scroll() {
            Column({ space: 8 }) {
              Text(this.history.length === 0 ? '暂无本机搜索历史' : '仅保存在本机，最多 20 条').fontSize(13).fontColor($r('app.color.discovery_muted'))
              ForEach(this.history, (value: string) => {
                Button(value).height(48).width('100%').onClick((): void => { this.keywordInput = value; this.setPanel('NONE'); this.submitSearch(); })
                  .attributeModifier(new DiscoveryActionStyle())
              }, (value: string): string => value)
              if (this.history.length > 0) { Button('清空本机历史').height(48).onClick((): void => { SearchHistoryStore.clear(this.context(), this.owner); this.history = []; }).attributeModifier(new DiscoveryActionStyle()); }
            }.width('100%')
          }.width('100%').height(Math.min(240, this.availableHeight * 0.5)).scrollBar(BarState.Off)
        }.width('94%').padding(14).margin({ bottom: 8 }).backgroundColor($r('app.color.discovery_surface')).borderRadius(20)
          .transition(discoveryPanelTransition(this.motionActive))
      }
      if (this.selectedMerchant !== undefined) {
        MerchantRecommendationSheet({ merchant: this.selectedMerchant, cards: this.merchantCards, status: this.merchantStatus,
          loading: this.merchantLoading, nextCursor: this.merchantCursor, onClose: (): void => this.closeMerchant(),
          onMore: (): void => { void this.loadMerchant(true); }, onRetry: (): void => { void this.loadMerchant(false); }, onOpen: (card: FoodCard): void => { this.onOpenCard(card); } })
          .width('94%').margin({ bottom: 8 })
      }
    }.height('100%').width('100%').backgroundColor($r('app.color.discovery_canvas'))
      .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0))
      .onAreaChange((_oldArea: Area, newArea: Area): void => { const height: number = Number(newArea.height); if (Number.isFinite(height) && height > 0) this.availableHeight = height; })
  }
}
