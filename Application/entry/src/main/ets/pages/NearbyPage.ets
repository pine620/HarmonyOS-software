import { common } from '@kit.AbilityKit';
import { FoodCard, FoodCategory, UserProfile } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { NearbyPreloadService } from '../service/NearbyPreloadService';
import { NearbyPerformanceTrace, PreloadMetricState } from '../service/NearbyPerformanceTrace';
import { MediaPriority, MediaRequestGuard, PhotoUploadService } from '../service/PhotoUploadService';
import { ReviewCard, ReviewCardViewData } from '../components/review/ReviewDisplay';
import { mapFoodCardToReviewCardViewData } from '../mapper/CloudCardViewMapper';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { ServiceCardRemoteSyncService } from '../service/ServiceCardRemoteSyncService';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { BreakpointSystem, LayoutBreakpoint } from '../common/BreakpointSystem';
import { DiscoveryCapabilities, emptyCapabilities } from '../model/DiscoveryModels';
import { DiscoveryRepository } from '../repository/DiscoveryRepository';
import { DiscoveryCache } from '../service/DiscoveryCache';
import { AuthService } from '../service/AuthService';
import { DiscoveryFeed } from './DiscoveryFeed';

interface CategoryOption {
  value: string;
  label: string;
}

/**
 * Keeps the values that can change after the waterfall is first rendered at
 * the top level of its @State array item. FoodCard remains transport data;
 * cover fields are replaced immutably after each asynchronous URL batch.
 */
interface NearbyCardEntry {
  card: FoodCard;
  coverUrl: string;
  coverResolved: boolean;
  coverFailed: boolean;
}

const CATEGORY_OPTIONS: Array<CategoryOption> = [
  { value: 'all', label: '全部' },
  { value: 'staple', label: '米饭' },
  { value: 'bakery', label: '汤粉' },
  { value: 'snack', label: '炸鸡' },
  { value: 'fresh', label: '烧烤' },
  { value: 'drink', label: '饮品' },
  { value: 'other', label: '其他' }
];
const NEARBY_VISIBLE_PHOTO_COUNT: number = 4;

@Component
export struct NearbyPage {
  @Consume('windowBreakpoint') windowBreakpoint: LayoutBreakpoint;
  @State waterfallWidthVp: number = 0;
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop @Watch('onAccountChanged') loggedIn: boolean = false;
  @Prop showPreferencePrompt: boolean = false;
  onSetupPreference: () => void = (): void => {};
  onSkipPreference: () => void = (): void => {};
  onOpenMeal: () => void = (): void => {};
  @State discoveryCapabilities: DiscoveryCapabilities = emptyCapabilities();
  private discoveryRepository: DiscoveryRepository = new DiscoveryRepository();
  private capabilityGeneration: number = 0;
  private pageActive: boolean = false;
  @State cards: Array<NearbyCardEntry> = [];
  @State status: string = '展示全部公开推荐，无需定位。';
  @State selectedCategory: string = 'all';
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State nextPageToken: string = '';
  @State photoLoading: boolean = false;
  @State mediaServiceUnavailable: boolean = false;
  private repository: CardRepository = new CardRepository();
  private refreshQueued: boolean = false;
  private refreshQueuedForRemoteSync: boolean = false;
  private showingStaleSnapshot: boolean = false;
  private refreshGeneration: number = 0;
  private photoHydrationGeneration: number = 0;
  private activePhotoHydrationCount: number = 0;
  private hydratingCardIds: Set<string> = new Set<string>();
  private serviceCardSyncRunning: boolean = false;
  private pendingServiceCard: FoodCard | undefined = undefined;
  private pendingServiceCardRemoteSync: boolean = false;
  private pendingServiceCardRefreshGeneration: number = 0;
  private firstCoverStarted: number = 0;
  private firstCoverIds: Set<string> = new Set<string>();

  aboutToAppear(): void {
    this.pageActive = true;
    void this.loadDiscoveryCapabilities();
    PhotoUploadService.retryMediaService();

  }

  aboutToDisappear(): void {
    this.pageActive = false; this.capabilityGeneration++;
    this.finishFirstCover('cancelled');
    this.refreshGeneration += 1;
    this.photoHydrationGeneration = this.refreshGeneration;
    this.loading = false;
    this.loadingMore = false;
    this.refreshQueued = false;
    this.refreshQueuedForRemoteSync = false;
    this.pendingServiceCard = undefined;
    this.pendingServiceCardRemoteSync = false;
  }

  private finishFirstCover(state: PreloadMetricState): void {
    if (this.firstCoverStarted === 0) return;
    NearbyPerformanceTrace.record('nearby_first_cover', state, this.firstCoverStarted);
    this.firstCoverStarted = 0;
    this.firstCoverIds.clear();
  }

  private coverDecoded(id: string, url: string): void {
    if (!this.firstCoverIds.has(id) || !this.cards.some((entry: NearbyCardEntry): boolean =>
      entry.card.id === id && entry.coverUrl === url)) return;
    this.finishFirstCover('decoded');
  }

  private retryPhotosAndRefresh(): void {
    PhotoUploadService.retryMediaService();
    this.mediaServiceUnavailable = false;
    void this.refresh(true);
  }

  private onRevisionChanged(): void {
    DiscoveryCache.clear();
    void this.loadDiscoveryCapabilities();
    if (this.revision > 0) {
      if (!this.discoveryCapabilities.searchEnabled && !this.discoveryCapabilities.mapEnabled) this.refresh();
    }
  }

  private onAccountChanged(): void {
    DiscoveryCache.clear(); this.discoveryCapabilities = emptyCapabilities();
    this.refreshGeneration++; this.loading = false; this.loadingMore = false;
    if (this.pageActive) { void this.loadDiscoveryCapabilities(); void this.refresh(false, true); }
  }
  private async loadDiscoveryCapabilities(): Promise<void> {
    const generation: number = ++this.capabilityGeneration;
    const profile: UserProfile | undefined = AuthService.profile(); const uid: string = profile === undefined ? '' : profile.uid;
    try {
      const capabilities: DiscoveryCapabilities = await this.discoveryRepository.capabilities();
      const currentProfile: UserProfile | undefined = AuthService.profile();
      if (!this.pageActive || generation !== this.capabilityGeneration || uid !== (currentProfile === undefined ? '' : currentProfile.uid)) return;
      const wasEnabled: boolean = this.discoveryCapabilities.searchEnabled || this.discoveryCapabilities.mapEnabled;
      if (this.discoveryCapabilities.searchEnabled !== capabilities.searchEnabled || this.discoveryCapabilities.mapEnabled !== capabilities.mapEnabled ||
        this.discoveryCapabilities.searchReason !== capabilities.searchReason || this.discoveryCapabilities.mapReason !== capabilities.mapReason) this.discoveryCapabilities = capabilities;
      if (!wasEnabled && (capabilities.searchEnabled || capabilities.mapEnabled)) {
        this.refreshGeneration++; this.finishFirstCover('cancelled'); this.loading = false; this.loadingMore = false;
        this.refreshQueued = false; this.refreshQueuedForRemoteSync = false; this.pendingServiceCard = undefined; this.pendingServiceCardRemoteSync = false;
      } else if (wasEnabled && !capabilities.searchEnabled && !capabilities.mapEnabled) {
        this.loading = false; this.loadingMore = false; void this.refresh(false, true);
      }
    } catch (_error) {
      // A missing deployment or unavailable capability endpoint retains the existing list.
      const currentProfile: UserProfile | undefined = AuthService.profile();
      if (this.pageActive && generation === this.capabilityGeneration && uid === (currentProfile === undefined ? '' : currentProfile.uid)) {
        const wasEnabled: boolean = this.discoveryCapabilities.searchEnabled || this.discoveryCapabilities.mapEnabled;
        this.discoveryCapabilities = emptyCapabilities();
        if (wasEnabled) { this.loading = false; this.loadingMore = false; void this.refresh(false, true); }
      }
    }
  }
  private discoveryUnavailable(): void {
    DiscoveryCache.clear(); this.discoveryCapabilities = emptyCapabilities();
    this.loading = false; this.loadingMore = false; void this.refresh(false, true);
  }

  private visibleCards(): Array<NearbyCardEntry> {
    if (this.selectedCategory === 'all') return this.cards;
    return this.cards.filter((entry: NearbyCardEntry): boolean =>
      entry.card.category === (this.selectedCategory as FoodCategory));
  }

  private approvedCards(cards: Array<FoodCard>): Array<FoodCard> {
    return cards.filter((card: FoodCard): boolean =>
      card.status === 'APPROVED');
  }

  private createNearbyCardEntry(card: FoodCard): NearbyCardEntry {
    return {
      card,
      coverUrl: card.photoUrl,
      coverResolved: card.primaryPhotoResolved === true,
      coverFailed: card.photoUrl.length === 0 && card.primaryPhotoLoadFailed === true
    };
  }

  private mergeCards(current: Array<NearbyCardEntry>, incoming: Array<FoodCard>): Array<NearbyCardEntry> {
    const merged: Array<NearbyCardEntry> = [];
    const seenIds: Set<string> = new Set<string>();
    current.forEach((entry: NearbyCardEntry): void => {
      if (!seenIds.has(entry.card.id)) {
        seenIds.add(entry.card.id);
        merged.push(entry);
      }
    });
    incoming.forEach((card: FoodCard): void => {
      if (!seenIds.has(card.id)) {
        seenIds.add(card.id);
        merged.push(this.createNearbyCardEntry(card));
      }
    });
    return merged;
  }

  /**
   * Replaces only the entries whose asynchronous cover request has completed.
   * This gives ArkUI a new top-level @State array item instead of mutating a
   * nested transport object under a persistent ForEach key.
   */
  private syncHydratedCardEntries(hydratedCards: Array<FoodCard>): void {
    if (hydratedCards.length === 0) return;
    const hydratedById: Map<string, FoodCard> = new Map<string, FoodCard>();
    hydratedCards.forEach((card: FoodCard): void => {
      hydratedById.set(card.id, card);
    });
    this.cards = this.cards.map((entry: NearbyCardEntry): NearbyCardEntry => {
      const hydrated: FoodCard | undefined = hydratedById.get(entry.card.id);
      if (hydrated === undefined) return entry;
      const coverUrl: string = hydrated.photoUrl;
      const coverResolved: boolean = hydrated.primaryPhotoResolved === true;
      const coverFailed: boolean = coverUrl.length === 0 && hydrated.primaryPhotoLoadFailed === true;
      if (entry.card === hydrated && entry.coverUrl === coverUrl && entry.coverResolved === coverResolved
        && entry.coverFailed === coverFailed) {
        return entry;
      }
      return { card: hydrated, coverUrl, coverResolved, coverFailed };
    });
  }

  private nearbyStatus(cardCount: number, nextPageToken: string): string {
    if (cardCount === 0) return '当前分类还没有公开推荐。';
    if (nextPageToken.length > 0) {
      return '已找到 ' + cardCount.toString() + ' 条推荐，继续上滑查看更多。';
    }
    return '已加载全部 ' + cardCount.toString() + ' 条推荐。';
  }

  private displayStatus(): string {
    return this.photoLoading ? this.status + ' 实拍图正在后台补充。' : this.status;
  }

  private async hydrateNearbyPhotos(cards: Array<FoodCard>, refreshGeneration: number,
    priority: MediaPriority = 'normal'): Promise<void> {
    if (this.refreshGeneration !== refreshGeneration) return;
    const pending: Array<FoodCard> = cards.filter((card: FoodCard): boolean =>
      card.primaryPhotoResolved !== true && !this.hydratingCardIds.has(card.id));
    if (pending.length === 0) return;
    pending.forEach((card: FoodCard): void => { this.hydratingCardIds.add(card.id); });
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.activePhotoHydrationCount += 1;
    if (this.refreshGeneration === refreshGeneration) this.photoLoading = true;
    try {
      const eligible: MediaRequestGuard = NearbyPreloadService.createMediaGuard(context);
      const mayContinue: MediaRequestGuard = async (): Promise<boolean> => {
        return await eligible() && this.refreshGeneration === refreshGeneration;
      };
      for (let start = 0; start < pending.length; start += 2) {
        await this.repository.hydrateNearbyPrimaryPhotoUrls(context, pending, start, 2, priority, mayContinue);
        if (this.refreshGeneration !== refreshGeneration || this.photoHydrationGeneration !== refreshGeneration) {
          return;
        }
        this.syncHydratedCardEntries(pending.slice(start, Math.min(pending.length, start + 2)));
        if (PhotoUploadService.isMediaServiceUnavailable()) this.mediaServiceUnavailable = true;
      }
    } catch (_error) {
      // Individual URL failures already preserve a stable card placeholder.
      if (PhotoUploadService.isMediaServiceUnavailable()) this.mediaServiceUnavailable = true;
    } finally {
      if (this.photoHydrationGeneration === refreshGeneration) {
        pending.forEach((card: FoodCard): void => { this.hydratingCardIds.delete(card.id); });
        this.activePhotoHydrationCount = Math.max(0, this.activePhotoHydrationCount - 1);
        if (this.activePhotoHydrationCount === 0 && this.refreshGeneration === refreshGeneration) {
          this.photoLoading = false;
        }
        if (priority === 'high' && !this.showingStaleSnapshot) {
          NearbyPreloadService.prefetchNextPage(context, this.selectedCategory, this.nextPageToken);
        }
      }
    }
  }

  private hydrateVisibleRange(first: number, last: number): void {
    const visible: Array<NearbyCardEntry> = this.visibleCards();
    const end: number = Math.min(visible.length, Math.max(first, last) + 3);
    const cards: Array<FoodCard> = visible.slice(Math.max(0, first), end)
      .map((entry: NearbyCardEntry): FoodCard => entry.card);
    void this.hydrateNearbyPhotos(cards, this.refreshGeneration, 'normal');
  }

  private isLargeCard(index: number): boolean {
    return index % 2 === 0;
  }

  private coverScale(): number {
    // Preserve phone image heights; wider cards grow without unbounded images.
    if (this.windowBreakpoint === 'sm' || this.waterfallWidthVp <= 0) return 1;
    const columns: number = BreakpointSystem.columns(this.windowBreakpoint);
    const cardWidth: number = (this.waterfallWidthVp - (columns - 1) * BreakpointSystem.CARD_GAP) / columns;
    return Math.max(1, Math.min(1.45, (cardWidth - 24) / 150));
  }

  private async publishServiceCard(context: common.Context, card: FoodCard, requestRemoteSync: boolean): Promise<string> {
    try {
      await ServiceCardStore.publishRecommendation(context, card);
    } catch (_error) {
      // The recommendation surface remains available when a desktop service
      // card is absent or temporarily cannot be updated.
    }
    if (!requestRemoteSync || !this.loggedIn || ServiceCardStore.read(context).cardId !== card.id.trim()) return '';
    const remoteStatus = ServiceCardRemoteSyncService.status(context);
    if (!remoteStatus.supported) return '当前设备不支持桌面卡片远程同步。';
    if (!remoteStatus.optedIn) {
      return '桌面卡片已本地刷新；可在“权限与隐私”主动开启远程同步。';
    }
    try {
      const result = await ServiceCardRemoteSyncService.pushCurrentRecommendation(context, card.id);
      if (result.registeredFormCount === 0) {
        return '远程同步已开启；请先将食刻卡片添加到桌面，再刷新一次。';
      }
      if (!result.deliveryAvailable) return '桌面卡片已登记，远程同步通道暂不可用。';
      if (result.deliveredFormCount > 0) {
        return `已同步 ${result.deliveredFormCount} 张桌面卡片。`;
      }
      if (result.rateLimitedFormCount > 0) return '桌面卡片已达到今日远程同步上限。';
      return '桌面卡片已登记，远程同步暂未完成，请稍后再试。';
    } catch (error) {
      return `桌面卡片同步未完成：${errorText(error as ErrorDetail)}`;
    }
  }

  private enqueueServiceCardSync(
    context: common.Context,
    card: FoodCard,
    requestRemoteSync: boolean,
    refreshGeneration: number
  ): void {
    this.pendingServiceCard = card;
    this.pendingServiceCardRemoteSync = this.pendingServiceCardRemoteSync || requestRemoteSync;
    this.pendingServiceCardRefreshGeneration = refreshGeneration;
    if (this.serviceCardSyncRunning) return;
    void this.processServiceCardSync(context);
  }

  private async processServiceCardSync(context: common.Context): Promise<void> {
    this.serviceCardSyncRunning = true;
    try {
      while (true) {
        const card: FoodCard | undefined = this.pendingServiceCard;
        if (card === undefined) break;
        const requestRemoteSync: boolean = this.pendingServiceCardRemoteSync;
        const refreshGeneration: number = this.pendingServiceCardRefreshGeneration;
        this.pendingServiceCard = undefined;
        this.pendingServiceCardRemoteSync = false;
        let message: string = '';
        try {
          message = await this.publishServiceCard(context, card, requestRemoteSync);
        } catch (error) {
          message = `桌面卡片同步未完成：${errorText(error as ErrorDetail)}`;
        }
        if (message.length > 0 && this.refreshGeneration === refreshGeneration && !this.loadingMore) {
          this.status = `${this.status} ${message}`;
        }
      }
    } finally {
      this.serviceCardSyncRunning = false;
    }
  }

  private async refresh(requestRemoteSync: boolean = false, forceRefresh: boolean = false): Promise<void> {
    if (this.loading || this.loadingMore) {
      // Preserve a repeated refresh request while the previous one is still
      // in flight, then perform one follow-up pull with fresh card data.
      this.refreshQueued = true;
      this.refreshQueuedForRemoteSync = this.refreshQueuedForRemoteSync || requestRemoteSync;
      return;
    }
    const refreshGeneration: number = this.refreshGeneration + 1;
    this.finishFirstCover('cancelled');
    const started: number = Date.now();
    this.firstCoverStarted = started;
    this.refreshGeneration = refreshGeneration;
    this.photoHydrationGeneration = refreshGeneration;
    this.activePhotoHydrationCount = 0;
    this.hydratingCardIds.clear();
    this.photoLoading = false;
    this.mediaServiceUnavailable = PhotoUploadService.isMediaServiceUnavailable();
    this.loading = true;
    this.status = '正在加载全部公开推荐…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const snapshot = await NearbyPreloadService.load(context, requestRemoteSync || forceRefresh, this.selectedCategory);
      if (this.refreshGeneration !== refreshGeneration) return;
      const response = snapshot.response;
      this.showingStaleSnapshot = snapshot.stale === true;
      const approved: Array<FoodCard> = this.approvedCards(response.cards);
      if (!PhotoUploadService.isMediaServiceUnavailable()) {
        approved.forEach((card: FoodCard): void => {
          if (card.primaryPhotoLoadFailed === true) {
            card.primaryPhotoResolved = false;
            card.primaryPhotoLoadFailed = false;
          }
        });
      }
      this.cards = approved.map((card: FoodCard): NearbyCardEntry => this.createNearbyCardEntry(card));
      this.firstCoverIds = new Set<string>(this.visibleCards().slice(0, NEARBY_VISIBLE_PHOTO_COUNT)
        .map((entry: NearbyCardEntry): string => entry.card.id));
      NearbyPerformanceTrace.record('nearby_metadata', snapshot.stale === true ? 'stale' :
        requestRemoteSync ? 'refresh' : 'open', started, approved.length);
      if (this.firstCoverIds.size === 0) this.finishFirstCover('empty');
      this.nextPageToken = response.nextPageToken;
      this.status = this.nearbyStatus(approved.length, this.nextPageToken);
      if (snapshot.stale === true) {
        this.status = '网络暂不可用，正在显示 5 分钟内的公开推荐缓存；详情将重新向云端确认。';
      }
      if (approved.length > 0) {
        void this.hydrateNearbyPhotos(approved.slice(0, NEARBY_VISIBLE_PHOTO_COUNT), refreshGeneration, 'high');
        if (approved.slice(0, NEARBY_VISIBLE_PHOTO_COUNT).every((card: FoodCard): boolean =>
          card.primaryPhotoResolved === true) && snapshot.stale !== true) {
          NearbyPreloadService.prefetchNextPage(context, this.selectedCategory, this.nextPageToken);
        }
      }
      const firstCard: FoodCard | undefined = approved[0];
      if (firstCard !== undefined && snapshot.stale !== true) {
        if (requestRemoteSync) this.status = this.status + ' 桌面卡片正在后台更新。';
        this.enqueueServiceCardSync(context, firstCard, requestRemoteSync, refreshGeneration);
      }
    } catch (error) {
      if (this.refreshGeneration !== refreshGeneration) return;
      NearbyPerformanceTrace.record('nearby_metadata', 'error', started);
      this.finishFirstCover('error');
      this.cards = [];
      this.nextPageToken = '';
      this.photoLoading = false;
      this.status = '推荐加载失败：' + errorText(error as ErrorDetail);
    } finally {
      if (this.refreshGeneration !== refreshGeneration) return;
      this.loading = false;
      if (this.refreshQueued) {
        const queuedRemoteSync: boolean = this.refreshQueuedForRemoteSync;
        this.refreshQueued = false;
        this.refreshQueuedForRemoteSync = false;
        void this.refresh(queuedRemoteSync);
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.nextPageToken.length === 0) {
      return;
    }
    const pageToken: string = this.nextPageToken;
    const refreshGeneration: number = this.refreshGeneration;
    this.loadingMore = true;
    this.status = '正在加载更多公开推荐…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await NearbyPreloadService.loadNextPage(context, this.selectedCategory, pageToken);
      if (this.refreshGeneration !== refreshGeneration) return;
      const incoming: Array<FoodCard> = this.approvedCards(response.cards);
      const merged: Array<NearbyCardEntry> = this.mergeCards(this.cards, incoming);
      this.cards = merged;
      this.nextPageToken = response.nextPageToken;
      this.status = this.nearbyStatus(merged.length, this.nextPageToken);
      if (incoming.length > 0) {
        void this.hydrateNearbyPhotos(incoming.slice(0, 2), refreshGeneration, 'normal');
      }
      NearbyPreloadService.prefetchNextPage(context, this.selectedCategory, this.nextPageToken);
    } catch (error) {
      if (this.refreshGeneration !== refreshGeneration) return;
      this.status = '更多推荐加载失败：' + errorText(error as ErrorDetail) + '；上滑可重试。';
    } finally {
      if (this.refreshGeneration !== refreshGeneration) return;
      this.loadingMore = false;
      if (this.refreshQueued) {
        const queuedRemoteSync: boolean = this.refreshQueuedForRemoteSync;
        this.refreshQueued = false;
        this.refreshQueuedForRemoteSync = false;
        void this.refresh(queuedRemoteSync);
      }
    }
  }

  @Builder
  private categoryChip(option: CategoryOption) {
    Button(option.label)
      .height(48).padding({ left: 16, right: 16 })
      .backgroundColor(this.selectedCategory === option.value ? $r('app.color.accent_action') : $r('app.color.surface'))
      .fontColor(this.selectedCategory === option.value ? $r('app.color.on_accent_action') : $r('app.color.ink'))
      .fontSize(14).fontWeight(FontWeight.Medium)
      .border({ width: this.selectedCategory === option.value ? 0 : 1, color: $r('app.color.line') })
      .borderRadius(24)
      .onClick((): void => {
        if (this.selectedCategory === option.value) return;
        this.finishFirstCover('cancelled');
        this.refreshGeneration += 1;
        this.loading = false;
        this.loadingMore = false;
        this.refreshQueued = false;
        this.refreshQueuedForRemoteSync = false;
        this.pendingServiceCard = undefined;
        this.pendingServiceCardRemoteSync = false;
        this.cards = [];
        this.nextPageToken = '';
        this.selectedCategory = option.value;
        NearbyPreloadService.invalidate();
        void this.refresh(false, true);
      })
  }

  private reviewCardData(entry: NearbyCardEntry): ReviewCardViewData {
    const data: ReviewCardViewData = mapFoodCardToReviewCardViewData(entry.card);
    data.coverUrl = entry.coverUrl;
    data.coverLoading = entry.card.photoPath.length > 0 && !entry.coverResolved && !entry.coverFailed;
    data.coverFailed = entry.coverFailed;
    return data;
  }

  /**
   * WaterFlow/ForEach keeps an item with the same card ID alive. A nearby
   * image arrives after that item first renders, so include only the
   * asynchronous cover state in the render key to let ArkUI replace that one
   * child when its local cache URI becomes available.
   */
  private nearbyCardRenderKey(entry: NearbyCardEntry): string {
    const coverState: string = entry.coverResolved ? 'ready' : entry.coverFailed ? 'failed' : 'loading';
    return entry.card.id + ':' + coverState + ':' + entry.coverUrl;
  }

  @Builder
  private cardView(entry: NearbyCardEntry, index: number): void {
    ReviewCard({
      data: this.reviewCardData(entry),
      featured: this.isLargeCard(index),
      coverScale: this.coverScale(),
      onCoverDecoded: (id: string, url: string): void => this.coverDecoded(id, url),
      onOpen: (_cardId: string): void => {
        this.onOpenCard(entry.card);
      }
    });
  }

  @Builder
  private emptyState() {
    Column({ space: 12 }) {
      Text(this.loading ? '正在准备推荐' : '还没有符合条件的推荐')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
      Text(this.loading ? '正在加载公开推荐，无需定位或登录。' : '当前分类暂无公开卡片，可切换“全部”或刷新重试。')
        .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).textAlign(TextAlign.Center).width('82%')
      Button(this.loading ? '正在更新' : '刷新推荐').height(48).enabled(!this.loading)
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .onClick((): void => this.retryPhotosAndRefresh())
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
    .backgroundColor($r('app.color.surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') })
  }

  build() {
    DiscoveryFeed({ capabilities: this.discoveryCapabilities, revision: this.revision,
      showPreferencePrompt: this.showPreferencePrompt, onSetupPreference: this.onSetupPreference,
      onSkipPreference: this.onSkipPreference, onOpenMeal: this.onOpenMeal,
      onPrimaryCard: (card: FoodCard, remoteSync: boolean): void => {
        if (this.pageActive && card.visibility !== 'FRIENDS') this.enqueueServiceCardSync(this.getUIContext().getHostContext() as common.UIAbilityContext, card, remoteSync, this.refreshGeneration);
      }, onOpenCard: (card: FoodCard): void => this.onOpenCard(card), onUnavailable: (): void => this.discoveryUnavailable() })
  }
}
