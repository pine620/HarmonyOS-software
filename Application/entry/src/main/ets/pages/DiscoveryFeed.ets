import { PreferenceRepository } from '../repository/PreferenceRepository';
import { RecommendationPage, RecommendationReason } from '../model/PreferenceModels';
import { ReadRequestOptions } from '../service/ReadScheduler';
import { common } from '@kit.AbilityKit';
import { FoodCard, FoodCategoryV2, NearbyCardsResponse, PublicCardsRequest, UserProfile } from '../model/CloudContracts';
import { copyCardQuery, copyViewport, DiscoveryCamera, DiscoveryCapabilities, DiscoveryCardPage, DiscoveryMode, DiscoveryScope,
  DiscoverySort, DiscoveryViewport, MapMerchant, MapMerchantPage, MapMerchantQuery,
  MerchantRecommendationQuery, normalizeSearch, PublicCardQuery, QueryCoverage } from '../model/DiscoveryModels';
import { CATEGORY_V2_OPTIONS, CategoryV2Option, categoryV2Label, parseYuanInputToFen } from '../model/PublishingModels';
import { DiscoveryRepository } from '../repository/DiscoveryRepository';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { CloudBusinessError, CloudGateway } from '../service/CloudGateway';
import { DiscoveryCache } from '../service/DiscoveryCache';
import { MapViewportStore } from '../service/MapViewportStore';
import { SearchHistoryStore } from '../service/SearchHistoryStore';
import { DiscoveryMap } from '../components/DiscoveryMap';
import { DiscoveryCard } from '../components/DiscoveryCard';
import { MerchantRecommendationSheet } from '../components/MerchantRecommendationSheet';
import { BreakpointSystem, LayoutBreakpoint } from '../common/BreakpointSystem';
import { ChoiceActionStyle, PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';

interface DiscoveryEntry { card: FoodCard; coverUrl: string; }
interface PreviousRegion { viewport: DiscoveryViewport; camera: DiscoveryCamera; }
interface SortOption { value: DiscoverySort; label: string; }
const SORT_OPTIONS: Array<SortOption> = [{ value: 'LATEST', label: '最新发布' }, { value: 'SCORE_DESC', label: '评分优先' },
  { value: 'PRICE_ASC', label: '价格升序' }, { value: 'PRICE_DESC', label: '价格降序' }];

@Component
export struct DiscoveryFeed {
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private visibleLifecycle: boolean = true;
  private onAppActiveChanged(): void { if (!this.appActive) this.aboutToDisappear(); else if (this.visibleLifecycle) this.aboutToAppear(); }

  @Consume('windowBreakpoint') windowBreakpoint: LayoutBreakpoint;
  @Require @Prop @Watch('onCapabilitiesChanged') capabilities: DiscoveryCapabilities;
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop showPreferencePrompt: boolean = false;
  onSetupPreference: () => void = (): void => {};
  onSkipPreference: () => void = (): void => {};
  onOpenMeal: () => void = (): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onPrimaryCard: (card: FoodCard, remoteSync: boolean) => void = (_card: FoodCard, _remoteSync: boolean): void => {};
  onUnavailable: () => void = (): void => {};
  @State cards: Array<DiscoveryEntry> = [];
  @State keywordInput: string = '';
  @State mode: DiscoveryMode = 'ALL';
  @State categories: Array<FoodCategoryV2> = [];
  @State sort: DiscoverySort = 'LATEST';
  @State priceMin: string = '';
  @State priceMax: string = '';
  @State pricePreset: number = -1;
  @State filtersOpen: boolean = false;
  @State historyOpen: boolean = false;
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
  private cardSelectionGeneration: number = 0;
  private debounce: number | undefined = undefined;
  private hydratedIds: Set<string> = new Set<string>();
  private hydrationRunning: boolean = false;
  private visibleFirst: number = 0;
  private visibleLast: number = 3;
  @StorageLink('accountContentRevision') @Watch('onRevisionChanged') accountContentRevision: number = 0;
  private onVisibilityChanged(visible: boolean): void { if (visible === this.visibleLifecycle) return; this.visibleLifecycle = visible; if (visible && this.appActive) this.aboutToAppear(); else this.aboutToDisappear(); }
  @StorageLink('preferenceRevision') @Watch('onRevisionChanged') preferenceRevision: number = 0;
  private preferenceRepository: PreferenceRepository = new PreferenceRepository();
  private isRecommendation(query: PublicCardQuery): boolean { return query.scope === 'ALL_PUBLIC' && query.keyword.length === 0 && query.mode === 'ALL' && query.categories.length === 0 && query.sort === 'LATEST' && query.priceMinFen === undefined && query.priceMaxExclusiveFen === undefined; }
  private async queryCards(query: PublicCardQuery, cursor: string): Promise<DiscoveryCardPage> {
    if (!this.isRecommendation(query)) return this.capabilities.searchEnabled ? this.repository.search(copyCardQuery(query, cursor)) : this.legacyPage(cursor);
    const generation: number = this.listGeneration;
    const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.current(generation) };
    const page: RecommendationPage = await this.preferenceRepository.recommendations(this.context(), cursor, options);
    for (const card of page.cards) { const reason: RecommendationReason | undefined = page.reasons.find((r: RecommendationReason): boolean => r.cardId === card.id); if (reason !== undefined) card.recommendationReasons = reason.reasons; }
    return { cards: page.cards, nextCursor: page.nextCursor, coverage: page.coverage === 'COMPLETE' ? 'COMPLETE' : 'PARTIAL_SCAN_LIMIT', scannedCandidateCount: page.scannedCandidateCount, fetchedCandidateCount: page.fetchedCandidateCount === undefined ? page.scannedCandidateCount : page.fetchedCandidateCount, merchantReadCount: 0, returnedCount: page.cards.length, scope: 'ALL_PUBLIC' };
  }
  private repository: DiscoveryRepository = new DiscoveryRepository();
  private cardRepository: CardRepository = new CardRepository();
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private viewer(): string {
    const profile: UserProfile | undefined = AuthService.profile();
    return profile !== undefined && CloudGateway.hasSession() ? profile.uid : 'guest';
  }
  private current(generation: number): boolean { return this.active && this.appActive && generation === this.listGeneration && this.owner === this.viewer(); }
  aboutToAppear(): void {
    this.active = true; this.owner = this.viewer();
    this.cameraTarget = MapViewportStore.read(this.context(), this.owner); this.currentCamera = this.cameraTarget;
    try { this.history = SearchHistoryStore.read(this.context(), this.owner); } catch (_error) { this.history = []; }
    void this.reload();
  }
  aboutToDisappear(): void {
    this.active = false; this.cards = []; this.previousCards = []; this.merchants = []; this.merchantCards = []; this.listGeneration++; this.mapGeneration++; this.merchantGeneration++;
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
  }
  private onCapabilitiesChanged(): void {
    if (!this.capabilities.mapEnabled) {
      this.expanded = false; this.listOpen = false; this.scope = 'ALL_PUBLIC'; this.queryViewport = undefined;
      this.searchedViewport = undefined; this.merchants = []; this.mapCursor = ''; this.mapLoading = false; this.mapEmpty = false;
    }
    if (this.active) this.onRevisionChanged();
  }
  private onRevisionChanged(): void {
    if (!this.active) return;
    DiscoveryCache.clear(); this.listGeneration++; this.mapGeneration++; this.closeMerchant();
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
  private makeQuery(cursor: string = ''): PublicCardQuery {
    const keyword: string = normalizeSearch(this.keywordInput);
    if (keyword.length > 50) throw new Error('搜索内容最多 50 字符。');
    const query: PublicCardQuery = { keyword, mode: this.mode, categories: this.categories.slice(), sort: this.sort,
      scope: this.scope, cursor, pageSize: 20 };
    if (this.scope === 'VIEWPORT' && this.queryViewport !== undefined) query.viewport = copyViewport(this.queryViewport);
    if (this.pricePreset >= 0) {
      query.priceMinFen = this.pricePreset * 1000;
      if (this.pricePreset < 3) query.priceMaxExclusiveFen = (this.pricePreset + 1) * 1000;
    } else if (this.priceMin.length > 0 || this.priceMax.length > 0) {
      if (this.priceMin.length === 0 || this.priceMax.length === 0) throw new Error('自定义价格区间两端都要填写。');
      const min: number | null = parseYuanInputToFen(this.priceMin);
      const max: number | null = parseYuanInputToFen(this.priceMax);
      if (min === null || max === null || max <= min) throw new Error('请输入有效区间，上限大于下限，最多两位小数。');
      query.priceMinFen = min; query.priceMaxExclusiveFen = max;
    }
    return query;
  }
  private entries(cards: Array<FoodCard>): Array<DiscoveryEntry> {
    return cards.map((card: FoodCard): DiscoveryEntry => { return { card, coverUrl: card.photoUrl }; });
  }
  private merge(current: Array<DiscoveryEntry>, incoming: Array<FoodCard>): Array<DiscoveryEntry> {
    const output: Array<DiscoveryEntry> = current.slice(); const seen: Set<string> = new Set<string>();
    for (const value of current) seen.add(value.card.id);
    for (const card of incoming) if (!seen.has(card.id)) { const value: DiscoveryEntry = { card, coverUrl: card.photoUrl }; output.push(value); seen.add(card.id); }
    return output;
  }
  private resultStatus(count: number, coverage: QueryCoverage, cursor: string): string {
    if (count === 0 && cursor.length > 0) return '当前批未找到推荐，扫描尚未结束，可继续搜索。';
    if (count === 0) return '没有符合条件的推荐，可修改关键词或清除筛选。';
    if (coverage === 'PARTIAL_SCAN_LIMIT') return '已找到 ' + count + ' 条，扫描未完成，可继续搜索。';
    return '已找到 ' + count + ' 条推荐' + (cursor.length > 0 ? '，可继续加载。' : '。');
  }
  private async legacyPage(cursor: string): Promise<DiscoveryCardPage> {
    const request: PublicCardsRequest = { scope: 'all', category: 'all', pageToken: cursor, pageSize: 20 };
    const response: NearbyCardsResponse = await this.cardRepository.listRecommendationsMetadata(request);
    return { cards: response.cards, nextCursor: response.nextPageToken, coverage: response.nextPageToken.length > 0 ? 'PARTIAL_RESULT_LIMIT' : 'COMPLETE',
      scannedCandidateCount: 0, fetchedCandidateCount: 0, merchantReadCount: 0, returnedCount: response.cards.length, scope: 'ALL_PUBLIC' };
  }
  private async reload(recordHistory: boolean = false, remoteSync: boolean = false): Promise<void> {
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    const generation: number = ++this.listGeneration;
    this.loadFailed = false; this.featureNotReady = false;
    this.loading = true; this.loadingMore = false; this.loadMoreFailed = false; this.hydrationRunning = false; this.hydratedIds.clear(); this.nextCursor = '';
    let query: PublicCardQuery;
    try { query = this.makeQuery(); } catch (failure) { this.status = stage47ErrorText(failure as Object, '筛选条件无效。'); this.loading = false; return; }
    this.cards = []; this.status = '正在重新验证推荐…';
    try {
      const result: DiscoveryCardPage = await this.queryCards(query, '');
      if (!this.current(generation)) return;
      if (query.scope === 'VIEWPORT' && (this.mapEmpty || (result.cards.length === 0 && result.coverage === 'COMPLETE')) && this.previousCards.length > 0) {
        const fresh: Array<FoodCard> = []; for (const previous of this.previousCards.slice(0, 30)) { try { const card: FoodCard = await this.cardRepository.detail(this.context(), previous.card.id); if (card.visibility !== 'FRIENDS') fresh.push(card); } catch (_error) {} }
        if (!this.current(generation)) return; this.cards = this.entries(fresh); this.showingPrevious = true; this.nextCursor = '';
        this.status = '当前区域无结果，暂时展示上一地区结果。';
      } else {
        this.cards = this.entries(result.cards); this.nextCursor = result.nextCursor; this.showingPrevious = false;
        this.status = this.resultStatus(this.cards.length, result.coverage, result.nextCursor);
        if (this.capabilities.searchEnabled && !this.isRecommendation(query)) DiscoveryCache.save(this.owner, query, result);
      }
      this.submittedQuery = copyCardQuery(query);
      if (!this.showingPrevious && query.scope === 'ALL_PUBLIC' && query.keyword.length === 0 && query.mode === 'ALL' &&
        query.categories.length === 0 && query.priceMinFen === undefined && query.priceMaxExclusiveFen === undefined &&
        query.sort === 'LATEST' && result.cards.length > 0 && result.cards[0].visibility !== 'FRIENDS') this.onPrimaryCard(result.cards[0], remoteSync);
      this.historyOpen = false;
      // A submitted search is recorded only after the matching successful result state is assigned.
      if (recordHistory && query.keyword.length > 0 && !this.showingPrevious) {
        try { this.history = SearchHistoryStore.record(this.context(), this.owner, query.keyword); } catch (_error) { }
      }
      void this.hydrateVisible(0, Math.min(3, this.cards.length - 1));
    } catch (failure) {
      if (!this.current(generation)) return;
      this.loadFailed = true;
      this.featureNotReady = failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY';
      if (this.featureNotReady) {
        DiscoveryCache.clear(); this.cards = [];
        if (this.capabilities.searchEnabled || this.capabilities.mapEnabled) this.onUnavailable();
      }
      this.status = stage47ErrorText(failure as Object, '推荐加载失败，请稍后重试。');
    } finally { if (this.current(generation)) this.loading = false; }
  }
  private async loadMore(automatic: boolean = false): Promise<void> {
    if (this.loading || this.loadingMore || this.nextCursor.length === 0 || this.showingPrevious || automatic && this.loadMoreFailed) return;
    const query: PublicCardQuery | undefined = this.submittedQuery;
    if (query === undefined) return;
    const generation: number = this.listGeneration; this.loadingMore = true;
    try {
      const result: DiscoveryCardPage = await this.queryCards(query, this.nextCursor);
      if (!this.current(generation)) return;
      this.cards = this.merge(this.cards, result.cards); this.nextCursor = result.nextCursor;
      this.loadMoreFailed = false;
      this.status = this.resultStatus(this.cards.length, result.coverage, result.nextCursor);
    } catch (failure) {
      if (!this.current(generation)) return;
      this.loadMoreFailed = true;
      if (failure instanceof CloudBusinessError && failure.code === 'CURSOR_STALE') { this.nextCursor = ''; DiscoveryCache.clear(); this.status = '内容已变化，请点击刷新，筛选已保留。'; }
      else if (failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY') {
        DiscoveryCache.clear();
        if (this.capabilities.searchEnabled || this.capabilities.mapEnabled) this.onUnavailable();
        this.status = stage47ErrorText(failure as Object, '推荐暂未开放。');
      }
      else this.status = stage47ErrorText(failure as Object, '推荐加载失败。');
    } finally { if (this.current(generation)) this.loadingMore = false; }
  }
  private async hydrateVisible(first: number, last: number): Promise<void> {
    this.visibleFirst = first; this.visibleLast = last;
    if (this.hydrationRunning || !this.active) return;
    const generation: number = this.listGeneration;
    const chosen: Array<FoodCard> = this.cards.slice(Math.max(0, first), Math.min(this.cards.length, last + 3))
      .map((entry: DiscoveryEntry): FoodCard => entry.card).filter((card: FoodCard): boolean => !this.hydratedIds.has(card.id));
    if (chosen.length === 0) return;
    this.hydrationRunning = true;
    for (const card of chosen) this.hydratedIds.add(card.id);
    try {
      await this.cardRepository.hydrateNearbyPrimaryPhotoUrls(this.context(), chosen, 0, chosen.length, 'normal', async (): Promise<boolean> => this.current(generation));
      if (!this.current(generation)) return;
      this.cards = this.cards.map((entry: DiscoveryEntry): DiscoveryEntry => { return { card: entry.card, coverUrl: entry.card.photoUrl }; });
    } catch (_failure) { if (this.current(generation)) this.status = '实拍图暂不可用，推荐信息已保留，可刷新重试。'; }
    finally {
      if (this.current(generation)) {
        this.hydrationRunning = false;
        if (this.visibleFirst !== first || this.visibleLast !== last) void this.hydrateVisible(this.visibleFirst, this.visibleLast);
      }
    }
  }
  private inputChanged(value: string): void {
    this.keywordInput = value; this.listGeneration++; this.loading = false; this.loadingMore = false; this.nextCursor = ''; this.submittedQuery = undefined;
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    this.debounce = setTimeout((): void => { this.debounce = undefined; if (this.active) this.submitSearch(false); }, 300);
  }
  private submitSearch(recordHistory: boolean = true): void {
    if (!this.capabilities.searchEnabled) return;
    if (this.debounce !== undefined) { clearTimeout(this.debounce); this.debounce = undefined; }
    this.keyword = normalizeSearch(this.keywordInput);
    if (this.keyword.length > 50) { this.status = '搜索内容最多 50 字符。'; return; }
    this.scope = 'ALL_PUBLIC'; this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined;
    void this.reload(recordHistory);
  }
  private selectMode(mode: DiscoveryMode): void {
    if (this.mode === mode) return;
    this.mode = mode; this.closeMerchant(); this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined;
    void this.reload();
    if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, false);
  }
  private changedViewport(viewport: DiscoveryViewport, camera: DiscoveryCamera): void {
    this.viewport = copyViewport(viewport); this.currentCamera = camera;
    try { MapViewportStore.save(this.context(), this.owner, camera); } catch (_error) { }
    const searched: DiscoveryViewport | undefined = this.searchedViewport;
    this.viewportDirty = searched === undefined || Math.abs(searched.north - viewport.north) > 0.000001 || Math.abs(searched.south - viewport.south) > 0.000001 ||
      Math.abs(searched.east - viewport.east) > 0.000001 || Math.abs(searched.west - viewport.west) > 0.000001;
    if (searched === undefined && this.capabilities.mapEnabled) void this.queryMap(viewport, false);
  }
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
        const fresh: Array<FoodCard> = []; for (const previous of this.previousCards.slice(0, 30)) { try { const card: FoodCard = await this.cardRepository.detail(this.context(), previous.card.id); if (card.visibility !== 'FRIENDS') fresh.push(card); } catch (_error) {} }
        if (!this.current(generation)) return; this.cards = this.entries(fresh); this.showingPrevious = true; this.nextCursor = '';
      }
    } catch (failure) {
      if (!this.active || generation !== this.mapGeneration || uid !== this.viewer()) return;
      if (failure instanceof CloudBusinessError && failure.code === 'CURSOR_STALE') { this.mapCursor = ''; this.mapStatus = '地图分页已变化，请重新搜索此区域。'; }
      else if (failure instanceof CloudBusinessError && failure.code === 'FEATURE_NOT_READY') { this.merchants = []; this.onUnavailable(); }
      else this.mapStatus = stage47ErrorText(failure as Object, '地图加载失败。');
    } finally { if (this.active && generation === this.mapGeneration && uid === this.viewer()) this.mapLoading = false; }
  }
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
  private returnPrevious(): void {
    const previous: PreviousRegion | undefined = this.previousResultRegion;
    if (previous === undefined) return;
    this.cameraTarget = previous.camera; this.queryCamera = previous.camera; this.currentCamera = previous.camera; this.queryViewport = copyViewport(previous.viewport); this.scope = 'VIEWPORT';
    this.showingPrevious = false; this.mapEmpty = false; void this.reload(); void this.queryMap(previous.viewport, false);
  }
  private closeMerchant(): void {
    this.cardSelectionGeneration++; this.merchantGeneration++; this.selectedMerchant = undefined; this.selectedMerchantId = '';
    this.merchantCards = []; this.merchantCursor = ''; this.merchantLoading = false;
  }
  private selectMerchant(merchant: MapMerchant): void {
    this.closeMerchant(); this.listOpen = false; this.filtersOpen = false; this.historyOpen = false;
    this.selectedMerchant = merchant; this.selectedMerchantId = merchant.merchantId; this.merchantCards = []; this.merchantCursor = '';
    const index: number = this.cards.findIndex((entry: DiscoveryEntry): boolean => entry.card.merchantId === merchant.merchantId);
    if (!this.expanded && index >= 0) this.resultScroller.scrollToIndex(index, false, ScrollAlign.START);
    void this.loadMerchant(false);
  }
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
  private async openCard(card: FoodCard): Promise<void> {
    const selection: number = ++this.cardSelectionGeneration;
    if (!this.showingPrevious && this.capabilities.mapEnabled && card.merchantId !== undefined && card.merchantId.length > 0) {
      const generation: number = this.listGeneration;
      let merchant: MapMerchant | undefined = this.merchants.find((value: MapMerchant): boolean => value.merchantId === card.merchantId);
      try {
        if (merchant === undefined) {
          const request: MerchantRecommendationQuery = { merchantId: card.merchantId, mode: this.mode, cursor: '', pageSize: 1 };
          const page: DiscoveryCardPage = await this.repository.merchant(request); merchant = page.merchant;
        }
        if (!this.current(generation) || selection !== this.cardSelectionGeneration) return;
        if (merchant !== undefined) {
          const resolved: MapMerchant = merchant;
          this.selectedMerchantId = resolved.merchantId;
          if (!this.merchants.some((value: MapMerchant): boolean => value.merchantId === resolved.merchantId)) this.merchants = this.merchants.concat([resolved]);
          const camera: DiscoveryCamera = { latitude: resolved.latitude, longitude: resolved.longitude, zoom: Math.max(15, this.currentCamera.zoom) };
          this.cameraTarget = camera;
        }
      } catch (_failure) { if (!this.current(generation) || selection !== this.cardSelectionGeneration) return; }
    }
    this.onOpenCard(card);
  }
  private toggleCategory(key: FoodCategoryV2): void {
    if (this.categories.includes(key)) this.categories = this.categories.filter((value: FoodCategoryV2): boolean => value !== key);
    else if (this.categories.length < 3) this.categories = this.categories.concat([key]);
    else this.status = '最多选择 3 个分类。';
  }
  private filterSummary(): string {
    const categories: string = this.categories.length === 0 ? '全部分类' : this.categories.map((key: FoodCategoryV2): string => categoryV2Label(key)).join('、');
    const price: string = this.pricePreset >= 0 ? this.pricePreset === 3 ? '¥30 起' : '¥' + this.pricePreset * 10 + '–' + (this.pricePreset + 1) * 10 : this.priceMin.length > 0 ? '自定义价格' : '不限价格';
    const option: SortOption | undefined = SORT_OPTIONS.find((value: SortOption): boolean => value.value === this.sort);
    return categories + ' · ' + price + ' · ' + (option === undefined ? '最新发布' : option.label);
  }
  private resetFilters(): void { this.categories = []; this.pricePreset = -1; this.priceMin = ''; this.priceMax = ''; this.sort = 'LATEST'; }
  private applyFilters(): void {
    try { this.makeQuery(); } catch (failure) { this.status = stage47ErrorText(failure as Object, '筛选条件无效。'); return; }
    this.filtersOpen = false; this.showingPrevious = false; this.previousCards = []; this.previousResultRegion = undefined; void this.reload();
  }
  private compactMapHeight(): number { return Math.max(120, Math.min(136, this.availableHeight - 580)); }
  private showsFullMap(): boolean { return this.expanded || this.availableHeight >= 680; }
  @Builder
  private modeButton(mode: DiscoveryMode, label: string): void {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        Text(label).fontSize(16).fontWeight(this.mode === mode ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.mode === mode ? $r('app.color.action_text') : $r('app.color.muted'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {}.width(24).height(3).borderRadius(2)
          .backgroundColor(this.mode === mode ? $r('app.color.accent_action') : Color.Transparent)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }.height(48).layoutWeight(1).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
      .accessibilityText(label + (this.mode === mode ? '，已选中' : '，未选中'))
      .accessibilitySelected(this.mode === mode).onClick((): void => this.selectMode(mode))
  }
  @Builder
  private filterPanel(): void {
    Scroll() {
      Column({ space: 8 }) {
        Text('分类最多选 3 项，按任一分类匹配').fontSize(13).fontColor($r('app.color.muted')).width('100%');
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(CATEGORY_V2_OPTIONS, (option: CategoryV2Option) => {
            Button(option.label).height(48).fontSize(12).margin({ right: 8, bottom: 8 })
              .accessibilityText(option.label + (this.categories.includes(option.key) ? '，已选中' : '，未选中')).onClick((): void => this.toggleCategory(option.key)).attributeModifier(new ChoiceActionStyle(this.categories.includes(option.key)))
          }, (option: CategoryV2Option): string => option.key)
        }.width('100%')
        Text('按各内容对应价格：外卖单品／到店人均；未知价不进入价格筛选。').fontSize(12).fontColor($r('app.color.muted'));
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([0, 1, 2, 3], (value: number) => {
            Button(value === 3 ? '30 元起' : value * 10 + '–' + (value + 1) * 10 + ' 元').height(48).margin(4)
              .onClick((): void => { this.pricePreset = this.pricePreset === value ? -1 : value; this.priceMin = ''; this.priceMax = ''; }).attributeModifier(new ChoiceActionStyle(this.pricePreset === value))
          }, (value: number): string => value.toString())
        }.width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.priceMin, placeholder: '最低价（元）' }).height(48).layoutWeight(1).maxLength(12)
            .accessibilityText('自定义最低价格，单位元').onChange((value: string): void => { this.priceMin = value; this.pricePreset = -1; });
          TextInput({ text: this.priceMax, placeholder: '最高价，不含（元）' }).height(48).layoutWeight(1).maxLength(12)
            .accessibilityText('自定义最高价格，不含上限，单位元').onChange((value: string): void => { this.priceMax = value; this.pricePreset = -1; });
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SORT_OPTIONS, (option: SortOption) => {
            Button(option.label).height(48).fontSize(13).margin({ right: 8, bottom: 8 })
              .onClick((): void => { this.sort = option.value; }).attributeModifier(new ChoiceActionStyle(this.sort === option.value))
          }, (option: SortOption): string => option.value)
        }
        Row({ space: 8 }) {
          Button('清除筛选').height(48).layoutWeight(1).onClick((): void => this.resetFilters()).attributeModifier(new QuietActionStyle());
          Button('应用筛选').height(48).layoutWeight(1).onClick((): void => this.applyFilters()).attributeModifier(new PrimaryActionStyle());
        }.width('100%')
      }.width('100%').padding(8)
    }.width('100%').height(Math.min(260, this.availableHeight * 0.5)).scrollBar(BarState.Off)
  }
  private coverScale(): number {
    if (this.windowBreakpoint === 'sm' || this.waterfallWidthVp <= 0) return 1;
    const columns: number = BreakpointSystem.columns(this.windowBreakpoint);
    const cardWidth: number = (this.waterfallWidthVp - (columns - 1) * BreakpointSystem.CARD_GAP) / columns;
    return Math.max(1, Math.min(1.45, (cardWidth - 24) / 150));
  }

  @Builder
  private preferenceButton(): void {
    Button('设置偏好').attributeModifier(new QuietActionStyle()).height(48).fontSize(13)
      .padding({ left: 8, right: 8 }).accessibilityText('设置推荐偏好')
      .onClick((): void => this.onSetupPreference())
  }

  @Builder
  private cardResults(): void {
    Row({ space: 8 }) {
      Text(this.showingPrevious ? '上一地区结果' : this.scope === 'VIEWPORT' ? '本区域推荐' : '全部公开推荐').fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
      this.preferenceButton();
      Button('刷新').attributeModifier(new QuietActionStyle()).height(48).enabled(!this.loading)
        .onClick((): void => { DiscoveryCache.clear(); void this.reload(false, true); })
    }.width('100%')
    if (this.showingPrevious) { Button('返回上一地区').height(48).fontSize(12).onClick((): void => this.returnPrevious()).attributeModifier(new QuietActionStyle()); }
    else if (this.scope === 'VIEWPORT') { Button('搜全部公开').height(48).fontSize(12).onClick((): void => this.submitSearch(false)).attributeModifier(new SecondaryActionStyle()); }
    if (!this.loadFailed) {
      Text(this.status).fontSize(12).fontColor($r('app.color.muted')).maxLines(3).width('100%')
    }
    if (this.cards.length === 0) {
      Column({ space: 8 }) {
        if (this.loading) {
          LoadingProgress().width(36).height(36).color($r('app.color.accent_action'))
          Text('正在加载推荐').fontSize(16).fontColor($r('app.color.ink'))
        } else if (this.loadFailed) {
          Column({ space: 12 }) {
            Text(this.featureNotReady ? '推荐暂未开放' : '推荐暂时加载失败')
              .fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
            Text(this.status).fontSize(14).lineHeight(20).fontColor($r('app.color.muted'))
              .textAlign(TextAlign.Center).width('100%')
            Button('重新加载').attributeModifier(new SecondaryActionStyle()).height(48)
              .onClick((): void => { void this.reload(); })
          }.width('100%').padding(24).backgroundColor($r('app.color.surface')).borderRadius(18)
            .border({ width: 1, color: $r('app.color.line') })
        } else {
          Text(this.nextCursor.length > 0 ? '扫描尚未完成' : '没有符合条件的推荐')
            .fontSize(16).fontColor($r('app.color.ink'))
          if (this.nextCursor.length === 0 && this.capabilities.searchEnabled) {
            Button('清除筛选并搜索全部公开').height(48).onClick((): void => { this.resetFilters(); this.keywordInput = ''; this.submitSearch(false); }).attributeModifier(new QuietActionStyle())
          }
        }
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else {
      WaterFlow({ scroller: this.resultScroller }) {
        ForEach(this.cards, (entry: DiscoveryEntry, index: number) => {
          FlowItem() { DiscoveryCard({ card: entry.card, coverUrl: entry.coverUrl, featured: index % 2 === 0, coverScale: this.coverScale(), selected: !this.showingPrevious && this.selectedMerchantId.length > 0 && entry.card.merchantId === this.selectedMerchantId,
            onOpen: (): void => { void this.openCard(entry.card); } }) }.width('100%')
        }, (entry: DiscoveryEntry): string => entry.card.id + ':' + entry.coverUrl)
      }.width('100%').layoutWeight(1).columnsTemplate(BreakpointSystem.columnsTemplate(this.windowBreakpoint))
        .columnsGap(BreakpointSystem.CARD_GAP).rowsGap(BreakpointSystem.CARD_GAP).scrollBar(BarState.Off)
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const width: number = Number(newArea.width);
          if (Number.isFinite(width) && width > 0 && this.waterfallWidthVp !== width) this.waterfallWidthVp = width;
        })
        .onScrollIndex((first: number, last: number): void => {
          if (first > 0) this.filtersOpen = false;
          void this.hydrateVisible(first, last);
          if (first > 0 && last >= this.cards.length - 2) void this.loadMore(true);
        })
    }
    if (this.nextCursor.length > 0 && !this.showingPrevious) {
      Button(this.loadingMore ? '加载中…' : '继续搜索推荐').height(48).width('100%').enabled(!this.loading && !this.loadingMore)
        .onClick((): void => { void this.loadMore(); }).attributeModifier(new SecondaryActionStyle());
    }
    if (!this.capabilities.searchEnabled && !this.expanded) {
      Text('当前展示全部公开推荐，筛选功能暂未开放。')
        .fontSize(12).fontColor($r('app.color.muted')).width('100%').margin({ top: 4 })
    }
  }
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 4 }) {
        if (!this.expanded || this.availableHeight >= 360) {
        Row() {
          Text(this.expanded ? '地图浏览' : '推荐').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
          Blank()
          if (this.expanded) {
            if (!this.listOpen) { this.preferenceButton(); }
            Button('刷新').attributeModifier(new QuietActionStyle()).height(48).enabled(!this.loading)
              .onClick((): void => { DiscoveryCache.clear(); void this.reload(false, true); })
          } else {
            Button('今天吃什么 ›').attributeModifier(new QuietActionStyle()).height(48)
              .accessibilityText('今天吃什么').onClick((): void => this.onOpenMeal())
          }
        }.width('100%')
        }
        if (!this.expanded && this.capabilities.searchEnabled) {
          Row({ space: 8 }) {
            TextInput({ text: this.keywordInput, placeholder: '搜产品或店名' }).height(48).layoutWeight(1).maxLength(50)
              .accessibilityText('搜索产品或店名').onChange((value: string): void => this.inputChanged(value)).onSubmit((): void => this.submitSearch());
            Button('搜索').height(48).onClick((): void => this.submitSearch()).attributeModifier(new PrimaryActionStyle());
            Button('历史').height(48).fontSize(12).onClick((): void => { this.historyOpen = !this.historyOpen; this.filtersOpen = false; }).attributeModifier(new QuietActionStyle());
          }.width('100%')
        }
        if (!this.expanded || this.availableHeight >= 360) {
          Row({ space: 8 }) { this.modeButton('ALL', '全部'); this.modeButton('DELIVERY', '外卖'); this.modeButton('DINE_IN', '到店'); }.width('100%')
        }
        if (!this.expanded && this.capabilities.searchEnabled) {
          Button(this.filterSummary()).width('100%').height(48).fontSize(12)
            .accessibilityText('筛选与排序，' + this.filterSummary()).onClick((): void => { this.filtersOpen = !this.filtersOpen; this.historyOpen = false; }).attributeModifier(new SecondaryActionStyle());
        }
        if (this.capabilities.mapEnabled) {
          if (this.showsFullMap()) {
          DiscoveryMap({ merchants: this.merchants, selectedMerchantId: this.selectedMerchantId, camera: this.cameraTarget, expanded: this.expanded,
            dirty: this.viewportDirty, loading: this.mapLoading, onViewport: (viewport: DiscoveryViewport, camera: DiscoveryCamera): void => this.changedViewport(viewport, camera),
            onSelect: (merchant: MapMerchant): void => this.selectMerchant(merchant), onSearch: (): void => this.searchArea(),
            onExpand: (): void => { this.cameraTarget = this.currentCamera; this.expanded = !this.expanded; this.listOpen = false; this.filtersOpen = false; this.historyOpen = false; } })
            .width('100%').height(this.expanded ? Math.max(120, this.availableHeight - (this.availableHeight < 360 ? 116 : 236) - (this.mapCursor.length > 0 ? 52 : 0)) : this.compactMapHeight())
          Text(this.mapStatus).fontSize(12).fontColor($r('app.color.muted')).maxLines(2).width('100%');
          if (this.mapCursor.length > 0) {
            Button(this.mapLoading ? '搜索中…' : '继续搜索区域地点').height(48).enabled(!this.mapLoading)
              .onClick((): void => { if (this.searchedViewport !== undefined) void this.queryMap(this.searchedViewport, true); }).attributeModifier(new SecondaryActionStyle());
          }
          } else {
            Button('浏览地图').width('100%').height(48).accessibilityText('展开地图，未主动定位')
              .onClick((): void => { this.cameraTarget = this.currentCamera; this.expanded = true; this.filtersOpen = false; this.historyOpen = false; }).attributeModifier(new SecondaryActionStyle());
          }
        }
        if (!this.expanded) { this.cardResults(); }
        else {
          Button('展开推荐列表').width('100%').height(48).onClick((): void => { this.closeMerchant(); this.listOpen = true; }).attributeModifier(new SecondaryActionStyle());
        }
      }.height('100%').width('100%').padding({ left: BreakpointSystem.pagePadding(this.windowBreakpoint), right: BreakpointSystem.pagePadding(this.windowBreakpoint), top: 8, bottom: 8 })
      if (this.expanded && this.listOpen) {
        Column({ space: 6 }) {
          Button('收起推荐列表').width('100%').height(48).onClick((): void => { this.listOpen = false; }).attributeModifier(new QuietActionStyle());
          this.cardResults();
        }.width('94%').height(Math.min(this.availableHeight * 0.7, 560)).padding(12).margin({ bottom: 8 })
          .backgroundColor($r('app.color.surface')).borderRadius(18).border({ width: 1, color: $r('app.color.line') })
      }
      if (this.filtersOpen && !this.expanded) {
        Column({ space: 8 }) {
          Button('关闭筛选面板').width('100%').height(48).onClick((): void => { this.filtersOpen = false; }).attributeModifier(new QuietActionStyle());
          this.filterPanel();
        }.width('94%').padding(12).margin({ bottom: 8 }).backgroundColor($r('app.color.surface')).borderRadius(18)
      }
      if (this.historyOpen && !this.expanded) {
        Column({ space: 8 }) {
          Button('关闭搜索历史').width('100%').height(48).onClick((): void => { this.historyOpen = false; }).attributeModifier(new QuietActionStyle());
          Scroll() {
            Column({ space: 6 }) {
              Text('本机搜索历史，最多 20 条').fontSize(12).fontColor($r('app.color.muted'));
              ForEach(this.history, (value: string) => {
                Button(value).height(48).width('100%').onClick((): void => { this.keywordInput = value; this.submitSearch(); }).attributeModifier(new SecondaryActionStyle());
              }, (value: string): string => value)
              Button('清空本机历史').height(48).onClick((): void => { SearchHistoryStore.clear(this.context(), this.owner); this.history = []; }).attributeModifier(new QuietActionStyle());
            }.width('100%')
          }.width('100%').height(180).scrollBar(BarState.Off)
        }.width('94%').padding(12).margin({ bottom: 8 }).backgroundColor($r('app.color.surface')).borderRadius(18)
      }
      if (this.selectedMerchant !== undefined) {
        MerchantRecommendationSheet({ merchant: this.selectedMerchant, cards: this.merchantCards, status: this.merchantStatus,
          loading: this.merchantLoading, nextCursor: this.merchantCursor, onClose: (): void => this.closeMerchant(),
          onMore: (): void => { void this.loadMerchant(true); }, onRetry: (): void => { void this.loadMerchant(false); }, onOpen: (card: FoodCard): void => { this.cardSelectionGeneration++; this.onOpenCard(card); } })
          .width('94%').margin({ bottom: 8 })
      }
    }.height('100%').width('100%').backgroundColor($r('app.color.canvas')).onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0))
      .onAreaChange((_oldArea: Area, newArea: Area): void => { const height: number = Number(newArea.height); if (Number.isFinite(height) && height > 0) this.availableHeight = height; })
  }
}
