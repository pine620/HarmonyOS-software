import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteActionStyle, WarmNoteBackdrop, notePanelTransition } from '../common/WarmNoteUi';
import { RandomFoodMotionObserver } from '../common/RandomFoodUi';
import { ReportRoute } from '../model/ContentStatusModels';
import { AppDestinationStyle } from '../common/AppPageUi';
import { SecondaryActionStyle } from '../common/Stage47Ui';
import { pasteboard } from '@kit.BasicServicesKit';
import { MerchantRepository } from '../repository/MerchantRepository';
import { MerchantResponse } from '../model/MerchantModels';
import { MerchantNavigationService } from '../service/MerchantNavigationService';
import { util } from '@kit.ArkTS';
import { PersonalCollectionMigration } from '../model/PersonalCollectionModels';
import { PersonalCollectionRepository } from '../repository/PersonalCollectionRepository';
import { ReadRequestOptions, ReadScheduler } from '../service/ReadScheduler';
import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import {
  CardReactionType, CardPhoto, FoodCard
} from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { categoryLabel } from '../components/FoodCover';
import { AuthService } from '../service/AuthService';
import { CardVisitStore } from '../service/CardVisitStore';
import { cardPriceText } from '../model/CardPrice';
import { CloudBusinessError, ReadCancelledError } from '../service/CloudReadErrors';
import { CloudGateway, MediaServiceUnavailableError } from '../service/CloudGateway';
import { MediaPriority, ImageRepository } from '../service/ImageRepository';
import { NearbyPerformanceTrace, PreloadMetricState } from '../service/NearbyPerformanceTrace';
import { cardDeepLink } from '../service/CardDeepLink';
import { tasteScoreText as formatTasteScore } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { BreakpointSystem } from '../common/BreakpointSystem';
import { CreateCardPage } from './CreateCardPage';
import { categoryV2Label, formatFenInput } from '../model/PublishingModels';
import { isSafeHttpsSourceLink } from '../service/SafeSourceLink';
import { CardInteractionController } from '../service/CardInteractionController';
import { InteractionView } from '../model/CardInteractionModels';
import { CardInteractionButton } from '../components/CardInteractionButton';

const DETAIL_MEDIA_MAX_HEIGHT: number = 420;

function emptyCard(): FoodCard {
  return {
    id: '', productName: '', brand: '', priceFen: 0, priceLabel: '', originalPriceFen: 0,
    specification: '', shop: '', sellingPoints: [], publicOffers: [], reviewText: '', tasteScore: 0,
    sourceLink: '', category: 'other',
    photoUrl: '', photoPath: '', photoBucket: '', photoWidth: 0, photoHeight: 0,
    authorNickname: '食刻用户', authorAvatarUrl: '', authorAvatarPath: '', authorAvatarBucket: '',
    photos: [], viewerIsOwner: false, likeCount: 0, favoriteCount: 0, viewerLiked: false,
    viewerFavorited: false, district: '', distanceKm: 0,
    status: 'APPROVED', createdAt: 0
  };
}

function fallbackPhoto(card: FoodCard): CardPhoto {
  return {
    id: '', url: '', path: card.photoPath, bucket: card.photoBucket,
    width: card.photoWidth, height: card.photoHeight
  };
}

@Component
export struct CardDetailPage {
  @Prop palette: PagePaletteName = 'NOTE';
  @StorageLink('favoritesMutationRevision') @Watch('onFavoriteMutation') favoritesMutationRevision: number = 0;
  private onFavoriteMutation(): void {
    const controller: CardInteractionController | undefined = this.interactionController;
    if (this.detailVisible && this.appActive && controller !== undefined && controller.needsFavoriteRefresh())
      void controller.refreshState();
  }
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private detailVisible: boolean = false;
  private onAppActiveChanged(): void { if (!this.appActive) { this.detailGeneration++; this.clearDetailView(); } else if (this.detailVisible) void this.loadDetail(); }

  @State detailWidthVp: number = 0;
  @State detailHeightVp: number = 0;
  @State collectionReady: boolean = false;
  @State collectionKnown: boolean = false;
  private detailScroller: Scroller = new Scroller();
  private savedScrollY: number = 0;
  private photoGeneration: number = 0;
  private restoreTimer: number = -1;
  @StorageLink('accountContentRevision') @Watch('onSessionChanged') accountContentRevision: number = 0;
  @State navigationAddress: string = '';
  @State detailReady: boolean = false;
  @State dislikeCount: number = 0;
  @State myReaction: CardReactionType | '' = '';
  @State editingVisible: boolean = false;
  @Prop card: FoodCard = emptyCard();
  @Prop @Watch('onSessionChanged') loggedIn: boolean = false;
  onRequireLogin: (message: string) => void = (_message: string): void => {};
  onOpenAuthor: (uid: string) => void = (_uid: string): void => {};
  onShareToFriend: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State detailPhotos: Array<CardPhoto> = [];
  @State entryCoverUrl: string = '';
  @State coverUrls: Array<string> = [];
  @State decodedPhotoUrls: Array<string> = [];
  @State photoFailures: Array<number> = [];
  @State mediaServiceUnavailable: boolean = false;
  @State photoIndex: number = 0;
  @State photoPreviewVisible: boolean = false;
  @State previewPhotoIndex: number = 0;
  @State detailAuthorNickname: string = '';
  @State detailAuthorAvatarUrl: string = '';
  @State viewerIsOwner: boolean = false;
  @State likeCount: number = 0;
  @State favoriteCount: number = 0;
  @State viewerFavorited: boolean = false;
  @State reactionBusy: boolean = false;
  @State collectionBusy: boolean = false;
  @State actionMenuVisible: boolean = false;
  @State interactionsKnown: boolean = false;
  @State collectionEnabled: boolean = false;
  @State interactionRecovering: boolean = false;
  @State interactionCanRetry: boolean = false;
  @State interactionMessage: string = '';
  @State interactionCountsMessage: string = '';
  @State collectionFeedback: string = '';
  private interactionController: CardInteractionController | undefined = undefined;
  private detachInteractions: () => void = (): void => {};
  private reactionVersion: number = 0;
  private collectionVersion: number = 0;
  @State status: string = '';
  @State preparingCollection: boolean = false;
  @State gateChecking: boolean = false;
  @State reducedMotion: boolean = true;
  private pendingMigrationId: string = '';
  private motionObserver: RandomFoodMotionObserver = new RandomFoodMotionObserver((reduced: boolean): void => { this.reducedMotion = reduced; });
  @State knockShareEnabled: boolean = false;
  @State knockShareBusy: boolean = false;
  private repository: CardRepository = new CardRepository();
  private detailGeneration: number = 0;
  private primaryImageStarted: number = 0;
  private hydratingPhotoIndices: Set<number> = new Set<number>();
  private photoPrefetchIndex: number = -1;
  private knockShareGeneration: number = 0;
  private knockShareListener: (target: harmonyShare.SharableTarget) => void =
    (target: harmonyShare.SharableTarget): void => {
      void this.sendKnockShare(target);
    };

  aboutToAppear(): void {
    this.primaryImageStarted = Date.now();
    this.mediaServiceUnavailable = false;
    this.clearDetailView();
  }

  aboutToDisappear(): void {
    this.motionObserver.stop();
    if (this.restoreTimer !== -1) { clearTimeout(this.restoreTimer); this.restoreTimer = -1; }
    this.clearDetailView();
    this.detailGeneration += 1;
    this.finishPrimaryImage('cancelled');
  }

  private onSessionChanged(): void {
    this.pendingMigrationId = ''; this.editingVisible = false; this.savedScrollY = 0;
    this.clearDetailView();
    if (this.detailVisible && this.appActive) void this.loadDetail();
  }

  private requireAccount(): boolean {
    if (this.loggedIn && AuthService.profile() !== undefined && CloudGateway.hasSession()) return true;
    this.closeActionMenu();
    this.onRequireLogin('登录后可赞踩、收藏和与好友分享。');
    return false;
  }

  private finishPrimaryImage(state: PreloadMetricState): void {
    if (this.primaryImageStarted === 0) return;
    NearbyPerformanceTrace.record('detail_primary_image', state, this.primaryImageStarted);
    this.primaryImageStarted = 0;
  }

  private clearDetailView(): void {
    this.preparingCollection = false; this.gateChecking = false;
    this.detachInteractions(); this.detachInteractions = (): void => {}; this.interactionController = undefined;
    this.reactionBusy = false; this.collectionBusy = false; this.interactionsKnown = false; this.collectionEnabled = false;
    this.interactionRecovering = false; this.interactionCanRetry = false; this.interactionMessage = '';
    this.interactionCountsMessage = ''; this.collectionFeedback = ''; this.myReaction = ''; this.viewerFavorited = false;
    this.photoGeneration++; this.detailReady = false; this.viewerIsOwner = false; this.entryCoverUrl = '';
    this.coverUrls = []; this.decodedPhotoUrls = []; this.photoPrefetchIndex = -1;
    this.navigationAddress = ''; this.detailPhotos = []; this.detailAuthorAvatarUrl = ''; this.detailAuthorNickname = '';
    this.photoPreviewVisible = false; this.closeActionMenu();
    this.collectionKnown = false; this.collectionReady = false; this.stopKnockShare('');
  }

  private async showEntryCover(generation: number): Promise<void> {
    const photo: CardPhoto = this.card.photos?.[0] || fallbackPhoto(this.card);
    const url: string = await ImageRepository.cachedPhotoUrl(this.getUIContext().getHostContext() as common.UIAbilityContext,
      photo, true, this.card.contentRevision || '');
    if (generation === this.detailGeneration && this.detailVisible && this.appActive && !this.detailReady) {
      this.entryCoverUrl = url;
      if (url.length > 0) console.info('[DetailImage] event=entry-cover-ready source=cache');
    }
  }

  private async showCachedCover(index: number, generation: number): Promise<void> {
    const photo: CardPhoto | undefined = this.detailPhotos[index];
    if (photo === undefined) return;
    const contentRevision: string = this.card.contentRevision || '';
    const url: string = await ImageRepository.cachedPhotoUrl(this.getUIContext().getHostContext() as common.UIAbilityContext,
      photo, true, contentRevision);
    if (generation !== this.detailGeneration || !this.detailVisible || !this.appActive || !this.detailReady || contentRevision !== (this.card.contentRevision || '') || this.detailPhotos[index]?.id !== photo.id) return;
    this.coverUrls = this.coverUrls.map((value: string, position: number): string => position === index ? url : value);
  }

  private prefetchNextPhoto(index: number): void {
    if (index !== this.photoIndex || !this.detailVisible || !this.appActive || !this.detailReady || !ReadScheduler.canPrefetch()) return;
    if (index + 1 >= this.detailPhotos.length || this.hydratingPhotoIndices.has(index + 1) || this.detailPhotos[index + 1].url.length > 0) return;
    this.photoPrefetchIndex = index + 1;
    void this.hydratePhotoAt(index + 1, 'prefetch');
  }

  private async loadDetail(): Promise<void> {
    const generation: number = this.detailGeneration + 1;
    this.detailGeneration = generation;
    const reactionVersion: number = this.reactionVersion;
    const collectionVersion: number = this.collectionVersion;
    const entryPhotoId: string = this.card.photos?.[0]?.id || this.card.photoPath;
    const entryRevision: string = this.card.contentRevision || '';
    this.clearDetailView();
    this.bindInteractions(generation);
    this.photoFailures = []; this.hydratingPhotoIndices.clear();
    if (this.card.status === 'APPROVED' && this.card.productName.length > 0) {
      this.detailReady = true;
      this.detailPhotos = this.card.photos !== undefined && this.card.photos.length > 0
        ? this.card.photos.map((photo: CardPhoto): CardPhoto => {
          // List photo URLs are covers; only an ORIGINAL cache/read may fill this URL.
          const preview: CardPhoto = { id: photo.id, url: '', path: photo.path, bucket: photo.bucket,
            width: photo.width, height: photo.height, sha256: photo.sha256, byteSize: photo.byteSize,
            coverSha256: photo.coverSha256, coverByteSize: photo.coverByteSize, coverWidth: photo.coverWidth,
            coverHeight: photo.coverHeight, readAcceptedAt: photo.readAcceptedAt, accessDenied: false };
          return preview;
        }) : (this.card.photoPath.length > 0 ? [fallbackPhoto(this.card)] : []);
      this.photoIndex = 0;
      this.coverUrls = this.detailPhotos.map((_photo: CardPhoto, index: number): string =>
        index === 0 && ImageRepository.canReuseCover(this.card) ? this.card.photoUrl : '');
      this.detailAuthorNickname = this.card.authorNickname || '';
      this.detailAuthorAvatarUrl = this.card.authorAvatarUrl || '';
      this.likeCount = this.card.likeCount || 0; this.favoriteCount = this.card.favoriteCount || 0;
      void this.showCachedCover(0, generation).catch((): void => {});
      void this.hydratePhotoAt(0, 'high', generation);
    } else void this.showEntryCover(generation).catch((): void => {});
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => generation === this.detailGeneration && this.detailVisible && this.appActive };
      const detail: FoodCard = await this.repository.detail(context, this.card.id, options);
      if (generation !== this.detailGeneration) return;
      const photos: Array<CardPhoto> = detail.photos === undefined ? [] : detail.photos;
      const previousPhotos: Array<CardPhoto> = this.detailPhotos;
      const previousCovers: Array<string> = this.coverUrls;
      const sameRevision: boolean = entryRevision === (detail.contentRevision || '');
      this.card = detail; this.detailReady = true;
      if (collectionVersion === this.collectionVersion) {
        this.collectionKnown = typeof detail.viewerFavorited === 'boolean' && typeof detail.collectionReady === 'boolean';
        this.collectionReady = this.collectionKnown && detail.collectionReady === true;
      }
      if (this.restoreTimer !== -1) clearTimeout(this.restoreTimer);
      this.restoreTimer = setTimeout((): void => {
        this.restoreTimer = -1;
        if (generation === this.detailGeneration && this.detailVisible && this.detailReady)
          this.detailScroller.scrollTo({ xOffset: 0, yOffset: this.savedScrollY, animation: false });
      }, 50);
      if (reactionVersion === this.reactionVersion) {
        this.myReaction = detail.myReaction === undefined ? '' : detail.myReaction;
        this.dislikeCount = detail.dislikeCount === undefined ? 0 : detail.dislikeCount;
      }
      try {
        const viewer = AuthService.profile();
        if (viewer !== undefined) CardVisitStore.record(context, viewer.uid, detail);
      } catch (_error) {
        // Local browsing history must never turn a successful detail load into an error.
      }
      this.detailPhotos = photos.length > 0
        ? photos : (detail.photoPath.length > 0 ? [fallbackPhoto(detail)] : []);
      const sameCover: boolean = entryPhotoId === (this.detailPhotos[0]?.id || this.detailPhotos[0]?.path || '') &&
        entryRevision === (detail.contentRevision || '');
      if (sameRevision) {
        this.detailPhotos = this.detailPhotos.map((photo: CardPhoto): CardPhoto => {
          const previous: CardPhoto | undefined = previousPhotos.find((item: CardPhoto): boolean => item.id === photo.id && item.path === photo.path && item.sha256 === photo.sha256);
          if (previous !== undefined) photo.url = previous.url;
          return photo;
        });
      } else { this.photoGeneration++; this.hydratingPhotoIndices.clear(); }
      this.coverUrls = this.detailPhotos.map((photo: CardPhoto, index: number): string => {
        const previousIndex: number = previousPhotos.findIndex((item: CardPhoto): boolean => item.id === photo.id && item.path === photo.path);
        if (sameRevision && previousIndex >= 0) return previousCovers[previousIndex] || '';
        return index === 0 && sameCover ? this.entryCoverUrl : '';
      });
      this.entryCoverUrl = '';
      void this.showCachedCover(0, generation).catch((): void => {});
      if (this.detailPhotos.length === 0) this.finishPrimaryImage('empty');
      this.photoIndex = 0;
      this.photoFailures = [];
      this.detailAuthorNickname = detail.authorNickname === undefined ? '' : detail.authorNickname;
      this.detailAuthorAvatarUrl = detail.authorAvatarUrl === undefined ? '' : detail.authorAvatarUrl;
      this.viewerIsOwner = detail.viewerIsOwner === true;
      const ownProfile = AuthService.profile();
      if (this.viewerIsOwner && ownProfile !== undefined) {
        if (this.detailAuthorNickname.length === 0 || this.detailAuthorNickname === '食刻用户') {
          this.detailAuthorNickname = ownProfile.nickname;
        }
        if (this.detailAuthorAvatarUrl.length === 0 && ownProfile.avatarUrl.length > 0) {
          this.detailAuthorAvatarUrl = ownProfile.avatarUrl;
        }
      }
      if (reactionVersion === this.reactionVersion) {
        this.likeCount = detail.likeCount === undefined ? 0 : detail.likeCount;
      }
      if (collectionVersion === this.collectionVersion) {
        this.favoriteCount = detail.favoriteCount === undefined ? 0 : detail.favoriteCount;
        this.viewerFavorited = detail.viewerFavorited === true;
      }
      this.status = '';
      void this.hydratePhotoAt(0, 'high', generation);
      void this.hydrateAuthorAvatar(generation);
    } catch (error) {
      if (generation !== this.detailGeneration) return;
      if (error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'NOT_FOUND'].includes(error.code)) this.clearDetailView();
      this.finishPrimaryImage('error');
      this.status = `详情刷新失败：${errorText(error as ErrorDetail)}`;
    }
  }

  private async hydratePhotoAt(index: number, priority: MediaPriority,
    generation: number = this.detailGeneration): Promise<void> {
    if (index < 0 || index >= this.detailPhotos.length ||
      this.hydratingPhotoIndices.has(index) && !(priority === 'high' && index === this.photoPrefetchIndex)) return;
    const photo: CardPhoto = this.detailPhotos[index];
    if (photo.url.length > 0 || photo.path.length === 0) return;
    const startedAt: number = Date.now();
    const photoGeneration: number = this.photoGeneration;
    this.hydratingPhotoIndices.add(index);
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await this.repository.hydrateDetailPhoto(context, photo, priority, async (): Promise<boolean> =>
        generation === this.detailGeneration && photoGeneration === this.photoGeneration && this.detailVisible && this.appActive && this.detailReady &&
        (index === this.photoIndex || this.photoPreviewVisible && index === this.previewPhotoIndex || priority === 'prefetch' && index === this.photoIndex + 1));
      if (generation !== this.detailGeneration || photoGeneration !== this.photoGeneration) return;
      console.info('[DetailImage] event=original-ready index=' + index + ' priority=' + priority +
        ' ready=' + String(url.length > 0) + ' elapsedMs=' + (Date.now() - startedAt));
      this.detailPhotos = this.detailPhotos.map((item: CardPhoto, position: number): CardPhoto =>
        position === index ? { id: item.id, url, path: item.path, bucket: item.bucket,
          width: item.width, height: item.height, sha256: item.sha256, byteSize: item.byteSize, coverSha256: item.coverSha256, coverByteSize: item.coverByteSize, coverWidth: item.coverWidth, coverHeight: item.coverHeight, readAcceptedAt: item.readAcceptedAt, accessDenied: item.accessDenied } : item);
      if (index === 0) {
        this.card.photoUrl = url;
        this.card.photos = this.detailPhotos;
      }
      if (url.length === 0) {
        if (index === 0) this.finishPrimaryImage('error');
        this.photoFailures = this.photoFailures.concat([index]);
      }
    } catch (error) {
      if (error instanceof ReadCancelledError) return;
      if (generation === this.detailGeneration && photoGeneration === this.photoGeneration) {
        if (index === 0) this.finishPrimaryImage('error');
        if (error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'ACCOUNT_INACTIVE'].includes(error.code)) { this.clearDetailView(); this.status = '内容已不可访问，请重新读取。'; return; }
        if (error instanceof MediaServiceUnavailableError) this.mediaServiceUnavailable = true;
        if (!this.photoFailures.includes(index)) this.photoFailures = this.photoFailures.concat([index]);
      }
    } finally {
      if (generation === this.detailGeneration && photoGeneration === this.photoGeneration) {
        this.hydratingPhotoIndices.delete(index);
        if (this.photoPrefetchIndex === index) this.photoPrefetchIndex = -1;
      }
    }
  }

  private photoDecodeFailed(index: number): void {
    const photo: CardPhoto | undefined = this.detailPhotos[index]; if (photo === undefined) return;
    this.decodedPhotoUrls = this.decodedPhotoUrls.filter((url: string): boolean => url !== photo.url);
    if (index === 0) this.finishPrimaryImage('error');
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    void ImageRepository.reportDecodeFailure(context, photo.id || photo.path.split('/').pop()?.replace('.jpg', '') || '').catch((): void => {});
    photo.url = ''; this.detailPhotos = this.detailPhotos.slice();
    if (!this.photoFailures.includes(index)) this.photoFailures = this.photoFailures.concat([index]);
  }

  private retryPhoto(index: number): void {
    ImageRepository.retryUnavailableService();
    this.mediaServiceUnavailable = false;
    this.photoFailures = this.photoFailures.filter((failed: number): boolean => failed !== index);
    void this.hydratePhotoAt(index, 'high');
  }

  private async hydrateAuthorAvatar(generation: number): Promise<void> {
    if (this.detailAuthorAvatarUrl.length > 0 || !this.card.authorAvatarPath || !this.card.authorAvatarBucket) return;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await ImageRepository.getDownloadUrl(context, this.card.authorAvatarBucket,
        this.card.authorAvatarPath, 'low', async (): Promise<boolean> => generation === this.detailGeneration && this.detailVisible && this.appActive);
      if (generation === this.detailGeneration) this.detailAuthorAvatarUrl = url;
    } catch (error) { if (generation === this.detailGeneration && error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'ACCOUNT_INACTIVE'].includes(error.code)) { this.clearDetailView(); this.status = '该作者当前不可访问。'; } }
  }

  private authorName(): string {
    if (this.detailAuthorNickname.length > 0) return this.detailAuthorNickname;
    const value = this.card.authorNickname;
    return value !== undefined && value.length > 0 ? value : '食刻用户';
  }

  private authorAvatarUrl(): string {
    if (this.detailAuthorAvatarUrl.length > 0) return this.detailAuthorAvatarUrl;
    const value = this.card.authorAvatarUrl;
    return value === undefined ? '' : value;
  }

  private imageHeight(): number {
    const width: number = this.isWideDetail() ? this.detailPaneWidth() : Math.max(240, this.detailWidthVp - this.detailPadding() * 2);
    const photo: CardPhoto | undefined = this.detailPhotos[this.photoIndex];
    const natural: number = photo !== undefined && photo.width > 0 && photo.height > 0 ? width * photo.height / photo.width : width;
    const available: number = this.detailHeightVp > 0 ? this.detailHeightVp * 0.58 : DETAIL_MEDIA_MAX_HEIGHT;
    return Math.round(Math.max(180, Math.min(DETAIL_MEDIA_MAX_HEIGHT, available, natural)));
  }

  private isWideDetail(): boolean {
    return this.detailWidthVp >= BreakpointSystem.LARGE_MIN;
  }

  private detailPadding(): number {
    return BreakpointSystem.pagePadding(BreakpointSystem.fromWidth(this.detailWidthVp));
  }

  private detailPaneWidth(): number {
    return Math.max(0, (this.detailWidthVp - this.detailPadding() * 2 - 24) / 2);
  }

  private detailColumnWidth(): number | string {
    return this.isWideDetail() ? this.detailPaneWidth() : '100%';
  }

  private openPhotoPreview(index: number): void {
    if (index < 0 || index >= this.detailPhotos.length || this.detailPhotos[index].url.length === 0) return;
    this.previewPhotoIndex = index;
    this.photoPreviewVisible = true;
  }

  private closePhotoPreview(): void {
    this.photoPreviewVisible = false;
  }

  private createdLabel(timestamp: number): string {
    if (timestamp <= 0) return '刚刚发布';
    const date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  private reviewText(): string {
    const reviewText = typeof this.card.reviewText === 'string' ? this.card.reviewText.trim() : '';
    if (reviewText.length > 0) return reviewText;
    return this.card.sellingPoints.length > 0
      ? this.card.sellingPoints.join('；') : '发布者暂未填写点评。';
  }

  private tasteScoreText(): string {
    const score = typeof this.card.tasteScore === 'number' ? this.card.tasteScore : 0;
    return formatTasteScore(score);
  }

  private cardLink(): string {
    return this.detailReady && this.card.status === 'APPROVED' ? cardDeepLink(this.card.id) : '';
  }

  private interactionCurrent(generation: number): boolean {
    return generation === this.detailGeneration && this.detailReady && this.detailVisible && this.appActive;
  }
  private bindInteractions(generation: number): void {
    if (!this.loggedIn || AuthService.profile() === undefined || !CloudGateway.hasSession()) return;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const controller: CardInteractionController = CardInteractionController.forCard(context, this.card.id);
      this.interactionController = controller;
      this.detachInteractions = controller.subscribe((view: InteractionView): void => {
        if (generation !== this.detailGeneration || !this.detailVisible || !this.appActive) return;
        const changed: boolean = this.interactionsKnown !== view.known || this.myReaction !== view.reaction ||
          this.viewerFavorited !== view.favorited;
        this.interactionsKnown = view.known;
        this.myReaction = view.reaction; this.viewerFavorited = view.favorited;
        if (view.known) { this.reactionVersion++; this.collectionVersion++; }
        this.collectionEnabled = view.collectionEnabled; this.collectionReady = view.collectionReady; this.collectionKnown = view.known;
        this.reactionBusy = view.reactionBusy; this.collectionBusy = view.favoriteBusy;
        this.interactionRecovering = view.recovering; this.interactionCanRetry = view.canRetry;
        this.interactionMessage = view.message; this.interactionCountsMessage = view.countsMessage;
        if (view.countsKnown) { this.likeCount = view.likeCount; this.dislikeCount = view.dislikeCount; this.favoriteCount = view.favoriteCount; }
        if (changed) console.info('[CardInteraction] stage=view_applied known=' + this.interactionsKnown +
          ' reaction=' + this.myReaction + ' favorited=' + this.viewerFavorited + ' generation=' + generation);
      });
      void controller.refreshState();
    } catch (error) { this.interactionMessage = errorText(error as ErrorDetail); }
  }
  private async prepareFavorite(): Promise<void> {
    if (!this.requireAccount() || !this.detailReady || !this.detailVisible || !this.appActive || this.preparingCollection) return;
    const generation: number = this.detailGeneration;
    const controller: CardInteractionController | undefined = this.interactionController;
    if (controller === undefined) return;
    this.preparingCollection = true; this.collectionFeedback = '正在整理旧收藏…';
    try {
      const repo: PersonalCollectionRepository = new PersonalCollectionRepository();
      let migration: PersonalCollectionMigration = await repo.migration();
      if (!this.interactionCurrent(generation)) return;
      if (migration.status === 'NOT_STARTED') migration = await repo.start();
      if (!this.interactionCurrent(generation)) return;
      for (let batch: number = 0; batch < 3 && !migration.collectionReady; batch++) {
        if (this.pendingMigrationId.length === 0) this.pendingMigrationId = util.generateRandomUUID(true);
        migration = await repo.resume(this.pendingMigrationId);
        if (!this.interactionCurrent(generation)) return;
        this.pendingMigrationId = '';
        this.collectionFeedback = '正在整理，已处理 ' + migration.processed + ' 条…';
      }
      if (!migration.collectionReady) { this.collectionFeedback = '已处理 ' + migration.processed + ' 条，可继续整理。'; return; }
      await controller.refreshState();
      if (this.interactionCurrent(generation)) this.collectionFeedback = '旧收藏已整理，可以使用 ❤️ 收藏。';
    } catch (error) {
      if (this.interactionCurrent(generation)) this.collectionFeedback = '整理未完成：' + errorText(error as ErrorDetail);
    } finally { if (generation === this.detailGeneration) this.preparingCollection = false; }
  }

  private async refreshForKnockShare(): Promise<boolean> {
    const generation: number = this.detailGeneration;
    const cardId: string = this.card.id;
    const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> =>
      generation === this.detailGeneration && this.detailVisible && this.appActive && this.detailReady };
    const detail: FoodCard = await this.repository.detail(
      this.getUIContext().getHostContext() as common.UIAbilityContext, cardId, options);
    if (generation !== this.detailGeneration || !this.detailReady || !this.detailVisible
      || !this.appActive || this.card.id !== cardId) return false;
    this.card = detail;
    if (detail.status !== 'APPROVED') {
      this.clearDetailView();
      this.status = '内容已下架，无法分享。';
      return false;
    }
    return true;
  }
  private react(reaction: CardReactionType): void {
    if (!this.requireAccount() || !this.detailReady || !this.detailVisible || !this.appActive) return;
    this.interactionController?.chooseReaction(reaction);
  }
  private favorite(): void {
    if (!this.requireAccount() || !this.detailReady || !this.detailVisible || !this.appActive) return;
    this.interactionController?.chooseFavorite();
  }
  private interactionStatusText(): string {
    const messages: Array<string> = [];
    if (this.interactionMessage.length > 0) messages.push(this.interactionMessage);
    if (this.collectionFeedback.length > 0) messages.push(this.collectionFeedback);
    if (this.interactionCountsMessage.length > 0) messages.push(this.interactionCountsMessage);
    if (this.status.length > 0) messages.push(this.status);
    return messages.join('；');
  }
  private async refreshInteractions(): Promise<void> {
    if (!this.requireAccount() || this.gateChecking) return;
    this.gateChecking = true;
    if (this.interactionController === undefined) this.bindInteractions(this.detailGeneration);
    try { await this.interactionController?.refreshState(); }
    finally { this.gateChecking = false; }
  }

  private cardLinkShareData(): systemShare.SharedData {
    // SharedData is also required by harmonyShare; it does not open a share panel.
    const record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.HYPERLINK,
      content: this.cardLink(),
      title: '食刻推荐：' + (this.card.productName || '美食卡片'),
      description: '请在已安装的食刻中查看这张美食卡片'
    };
    return new systemShare.SharedData(record);
  }

  private toggleKnockShare(): void {
    if (this.knockShareEnabled) {
      this.stopKnockShare('已结束碰一碰分享。');
      this.closeActionMenu();
      return;
    }
    if (!this.detailReady || !this.detailVisible || !this.appActive) return;
    if (this.cardLink().length === 0) {
      this.status = '当前卡片还没有可分享的安全链接，请刷新详情后重试。';
      this.closeActionMenu();
      return;
    }
    if (!canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      this.status = '当前设备不支持碰一碰分享，可发送给食刻好友。';
      this.closeActionMenu();
      return;
    }
    try {
      this.knockShareGeneration += 1;
      harmonyShare.on('knockShare', this.knockShareListener);
      this.knockShareEnabled = true;
      this.status = '已准备碰一碰：双方先安装食刻，解锁亮屏并开启华为分享，再让设备顶部轻碰。';
    } catch (error) {
      this.status = '当前设备无法开启碰一碰：' + errorText(error as ErrorDetail)
        + '；可发送给食刻好友。';
    }
    this.closeActionMenu();
  }

  private stopKnockShare(status: string): void {
    const wasEnabled: boolean = this.knockShareEnabled;
    this.knockShareGeneration += 1;
    this.knockShareEnabled = false;
    this.knockShareBusy = false;
    if (wasEnabled) {
      try {
        harmonyShare.off('knockShare', this.knockShareListener);
      } catch (_error) {
        // The system may already have removed the foreground callback.
      }
    }
    if (status.length > 0) this.status = status;
  }

  private async rejectKnockShare(target: harmonyShare.SharableTarget,
    reason: harmonyShare.SharableErrorCode): Promise<void> {
    try { await target.reject(reason); } catch (_error) {
      // The system may already have closed this knock session.
    }
  }

  private async sendKnockShare(target: harmonyShare.SharableTarget): Promise<void> {
    if (!this.knockShareEnabled || this.knockShareBusy || !this.detailVisible
      || !this.appActive || this.cardLink().length === 0) {
      await this.rejectKnockShare(target, harmonyShare.SharableErrorCode.NO_CONTENT_ERROR);
      return;
    }
    const generation: number = this.knockShareGeneration;
    this.knockShareBusy = true;
    try {
      if (!await this.refreshForKnockShare() || generation !== this.knockShareGeneration) {
        await this.rejectKnockShare(target, harmonyShare.SharableErrorCode.NO_CONTENT_ERROR);
        return;
      }
      await target.share(this.cardLinkShareData());
      if (generation !== this.knockShareGeneration || !this.detailVisible) return;
      this.status = '已提交碰一碰，请在接收端确认是否打开对应卡片。';
    } catch (error) {
      const unavailable: boolean = error instanceof CloudBusinessError
        && ['CONTENT_UNAVAILABLE', 'CONTENT_ACCESS_DENIED', 'NOT_FOUND', 'ACCOUNT_INACTIVE'].includes(error.code);
      await this.rejectKnockShare(target, unavailable || error instanceof ReadCancelledError
        ? harmonyShare.SharableErrorCode.NO_CONTENT_ERROR : harmonyShare.SharableErrorCode.DOWNLOAD_ERROR);
      if (generation !== this.knockShareGeneration || !this.detailVisible) return;
      if (unavailable) this.clearDetailView();
      this.status = '碰一碰未完成：' + errorText(error as ErrorDetail) + '；可重试或发送给食刻好友。';
    } finally {
      if (generation === this.knockShareGeneration) this.knockShareBusy = false;
    }
  }

  private priceText(): string {
    return cardPriceText(this.card);
  }

  private async openSource(): Promise<void> {
    const generation: number = this.detailGeneration; this.closeActionMenu();
    try { const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fresh: FoodCard = await this.repository.detail(context, this.card.id); if (generation !== this.detailGeneration || !this.detailReady) return;
      if (!isSafeHttpsSourceLink(fresh.sourceLink)) throw new Error('当前卡片没有可打开的来源页面。');
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: fresh.sourceLink });
    } catch (error) { if (generation === this.detailGeneration) { this.clearDetailView(); this.status = errorText(error as ErrorDetail); } }
  }

  private async navigateMerchant(): Promise<void> { const generation: number = this.detailGeneration; try { const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext; const fresh: FoodCard = await this.repository.detail(context, this.card.id); if (generation !== this.detailGeneration || !this.detailReady) return; if (fresh.consumptionMode !== 'DINE_IN' || !fresh.merchantId) throw new Error('当前卡片没有可导航的到店商家。'); const result: MerchantResponse = await new MerchantRepository().get(context, fresh.merchantId); if (generation !== this.detailGeneration || !this.detailReady) return; this.navigationAddress = result.merchant.address || result.merchant.name; await MerchantNavigationService.open(context, result.merchant); } catch (error) { if (generation === this.detailGeneration) this.status = errorText(error as ErrorDetail); } }

  private async copyNavigationAddress(): Promise<void> { if (!this.detailReady || this.navigationAddress.length === 0) return; try { const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.navigationAddress); await pasteboard.getSystemPasteboard().setData(data); this.status = '已复制商家地址。'; } catch (error) { this.status = errorText(error as ErrorDetail); } }

  private closeActionMenu(): void {
    this.actionMenuVisible = false;
  }

  private shareToFriend(): void {
    if (!this.requireAccount()) return;
    this.closeActionMenu();
    this.onShareToFriend(this.card);
  }

  private dismissOverlay(): void {
    this.closeActionMenu();
    this.closePhotoPreview();
  }

  private openReport(): void {
    if (!this.requireAccount() || !this.detailReady) return;
    const request: ReportRoute = { targetType: 'CARD', targetId: this.card.id };
    this.closeActionMenu(); this.pathStack.pushPathByName('report-content', request);
  }

  @Builder
  private authorHeader() {
    Row({ space: 12 }) {
      Button() {
        if (this.authorAvatarUrl().length > 0) {
          Image(this.authorAvatarUrl()).width(42).height(42).borderRadius(21).objectFit(ImageFit.Cover).accessibilityLevel('no');
        } else { Image($r('app.media.app_icon')).width(42).height(42).borderRadius(21).accessibilityLevel('no'); }
      }.type(ButtonType.Normal).width(48).height(48).padding(3).backgroundColor(Color.Transparent).borderRadius(24)
        .enabled(this.card.authorUid !== undefined && this.card.authorUid.length > 0)
        .accessibilityText(`查看${this.authorName()}的主页`)
        .onClick((): void => { if (this.card.authorUid !== undefined) this.onOpenAuthor(this.card.authorUid); });
      Column({ space: 4 }) {
        Text(this.authorName()).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Row({ space: 6 }) {
          Text('实拍分享者').fontSize(11).fontColor($r('app.color.leaf'))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor(pageColor(this.palette, 'soft')).borderRadius(8);
          Text(`${this.card.merchantNameSnapshot || (this.card.consumptionMode === 'DELIVERY' || this.card.consumptionMode === 'DINE_IN' ? '店铺未关联' : this.card.district || '历史发布位置')} · ${this.createdLabel(this.card.publishedAt === undefined ? this.card.createdAt : this.card.publishedAt)}`).fontSize(12)
            .fontColor(pageColor(this.palette, 'muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button() {
        Image($r('app.media.ic_more')).width(24).height(24).objectFit(ImageFit.Contain)
          .accessibilityLevel('no');
      }
      .width(48).height(48).padding(12).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
      .accessibilityText('更多帖子操作')
      .onClick(() => {
        this.actionMenuVisible = !this.actionMenuVisible;
      });
    }.width('100%').padding({ left: 2, right: 2, top: 4, bottom: 4 });
  }

  @Builder
  private actionMenu() {
    Column({ space: 10 }) {
      Row() {
        Text('更多操作').fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
        Blank();
        Button('关闭').height(44).fontSize(13).backgroundColor(pageColor(this.palette, 'surface'))
          .fontColor(pageColor(this.palette, 'muted')).border({ width: 1, color: pageColor(this.palette, 'line') })
          .onClick(() => this.closeActionMenu());
      }.width('100%');
      Button('发送给食刻好友').width('100%').height(48).backgroundColor(pageColor(this.palette, 'soft'))
        .fontColor(pageColor(this.palette, 'action')).onClick((): void => {
          this.shareToFriend();
        });
      Button(this.knockShareEnabled ? '结束碰一碰分享' : '碰一碰分享').width('100%').height(48)
        .backgroundColor(pageColor(this.palette, 'gold')).fontColor(pageColor(this.palette, 'on_gold'))
        .enabled(!this.knockShareBusy).accessibilityText(this.knockShareEnabled ? '结束碰一碰分享' : '开启碰一碰分享')
        .onClick((): void => {
          this.toggleKnockShare();
        });
      if (this.viewerIsOwner && this.loggedIn) { Button('编辑推荐').width('100%').onClick((): void => { this.closeActionMenu(); this.editingVisible = true; }).attributeModifier(new NoteActionStyle(false, this.palette)); }
      if (this.card.consumptionMode === 'DINE_IN' && this.card.merchantId !== undefined && this.card.merchantId.length > 0) { Button('去这里 · 商家导航').height(48).width('100%').onClick((): void => { void this.navigateMerchant(); this.closeActionMenu(); }).attributeModifier(new SecondaryActionStyle(this.palette)); }
      if (isSafeHttpsSourceLink(this.card.sourceLink)) {
        Button('打开来源页面').width('100%').height(48).backgroundColor(pageColor(this.palette, 'canvas'))
          .fontColor(pageColor(this.palette, 'ink')).onClick(() => this.openSource());
      }
      Button('举报卡片').width('100%').height(48)
        .backgroundColor($r('app.color.danger_soft')).fontColor($r('app.color.danger'))
        .onClick((): void => this.openReport());
      Button('取消').width('100%').height(48).backgroundColor(pageColor(this.palette, 'surface'))
        .fontColor(pageColor(this.palette, 'ink')).border({ width: 1, color: pageColor(this.palette, 'line') })
        .onClick(() => this.closeActionMenu());
    }
    .width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .transition(notePanelTransition(this.reducedMotion))
    .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
    .border({ width: 1, color: pageColor(this.palette, 'line') });
  }

  @Builder
  private knockShareNotice(): void {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Column() {}
          .width(4).height(40).backgroundColor(pageColor(this.palette, 'action')).borderRadius(2)
          .accessibilityLevel('no');
        Column({ space: 3 }) {
          Text(this.knockShareBusy ? '正在发送商品卡' : '碰一碰已就绪')
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%');
          Text(this.knockShareBusy ? '请保持两台设备靠近，等待系统完成传送。' : '保持本页打开，让两台设备顶部轻碰。')
            .fontSize(12).lineHeight(18).fontColor(pageColor(this.palette, 'muted')).width('100%');
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Button('结束').height(44).fontSize(13).backgroundColor(pageColor(this.palette, 'surface'))
          .fontColor(pageColor(this.palette, 'action')).border({ width: 1, color: pageColor(this.palette, 'line') })
          .accessibilityText('结束碰一碰分享').onClick((): void => {
            this.stopKnockShare('已结束碰一碰分享。');
          });
      }.width('100%').alignItems(VerticalAlign.Center);
      Text('双方需先安装食刻并开启华为分享；无法使用时，可发送给食刻好友。')
        .fontSize(11).lineHeight(17).fontColor(pageColor(this.palette, 'muted')).width('100%');
    }
    .width('100%').padding(14).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(16)
    .border({ width: 1, color: pageColor(this.palette, 'line') }).alignItems(HorizontalAlign.Start)
    .accessibilityText('碰一碰分享已就绪；可随时点击结束。');
  }

  @Builder
  private photoCarousel() {
    if (this.detailPhotos.length > 0) {
      Swiper() {
        ForEach(this.detailPhotos, (photo: CardPhoto, index: number) => {
          if (photo.url.length > 0 || (this.coverUrls[index] || '').length > 0) {
            Stack({ alignContent: Alignment.Bottom }) {
              if ((this.coverUrls[index] || '').length > 0 && !this.decodedPhotoUrls.includes(photo.url)) {
                Image(this.coverUrls[index]).width('100%').height(this.imageHeight()).objectFit(ImageFit.Contain)
                  .onError((): void => {
                    this.coverUrls = this.coverUrls.map((url: string, position: number): string => position === index ? '' : url);
                  })
                  .accessibilityText(`${this.card.productName}的实拍封面，正在加载清晰图片`);
              }
              if (photo.url.length > 0) {
            Image(photo.url).width('100%').height(this.imageHeight()).objectFit(ImageFit.Contain)
              .onComplete((event): void => {
                if (event !== undefined && event.loadingStatus === 1 && this.detailVisible && this.detailPhotos[index]?.url === photo.url) {
                  if (!this.decodedPhotoUrls.includes(photo.url)) this.decodedPhotoUrls = this.decodedPhotoUrls.concat([photo.url]);
                  console.info('[DetailImage] event=original-decoded index=' + index);
                  if (index === 0) this.finishPrimaryImage('decoded');
                  this.prefetchNextPhoto(index);
                }
              })
              .onError((): void => {
                if (this.detailPhotos[index]?.url === photo.url) this.photoDecodeFailed(index);
              })
              .borderRadius(20)
              .accessibilityText(`${this.card.productName}的发布者实拍图，轻点查看完整图片`)
              .accessibilityDescription('轻点查看完整图片；左右滑动可切换实拍图')
              .onClick(() => this.openPhotoPreview(index));
              }
              if (this.photoFailures.includes(index)) {
                Button('重试清晰图片').height(44).backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'action'))
                  .onClick((): void => this.retryPhoto(index));
              }
            }.width('100%').height(this.imageHeight()).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(20)
          } else {
            Column({ space: 6 }) {
              Text(this.mediaServiceUnavailable && this.photoFailures.includes(index)
                ? '实拍图服务暂时不可用' : this.photoFailures.includes(index)
                  ? '这张实拍图暂不可用' : '正在加载这张实拍图')
                .fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor(pageColor(this.palette, 'muted'));
              Text(this.photoFailures.includes(index) ? '点评仍可阅读，点下方重试。' :
                '点评已可阅读。').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
              if (this.photoFailures.includes(index)) {
                Button('重试实拍图').height(44).fontSize(13)
                  .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'action'))
                  .onClick((): void => this.retryPhoto(index));
              }
            }
            .width('100%').height(this.imageHeight()).justifyContent(FlexAlign.Center)
            .backgroundColor(pageColor(this.palette, 'soft')).borderRadius(20);
          }
        }, (photo: CardPhoto): string => `${photo.id.length > 0 ? photo.id : photo.path}:${photo.url}`)
      }
      .width('100%').height(this.imageHeight()).index(this.photoIndex).indicator(this.detailPhotos.length > 1)
      .loop(false).onChange((index: number): void => {
        this.photoIndex = index;
        ImageRepository.subscriptionsChanged();
        void this.showCachedCover(index, this.detailGeneration).catch((): void => {});
        void this.hydratePhotoAt(index, 'high');
        if (this.decodedPhotoUrls.includes(this.detailPhotos[index]?.url || '')) this.prefetchNextPhoto(index);
      });
      Text(`发布者实拍 ${this.photoIndex + 1} / ${this.detailPhotos.length} · 轻点图片查看完整图片`).fontSize(11)
        .fontColor(pageColor(this.palette, 'muted')).width('100%');
    } else {
      Column({ space: 6 }) {
        Text('暂无发布者实拍图').fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'muted'));
        Text('卡片仍可查看点评、商品信息与来源。').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
      }.width('100%').height(180).justifyContent(FlexAlign.Center)
        .backgroundColor(pageColor(this.palette, 'soft')).borderRadius(20);
    }
  }

  @Builder
  private photoPreview() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}
        .width('100%').height('100%').backgroundColor($r('app.color.scrim'))
        .onClick(() => this.closePhotoPreview());
      Column({ space: 12 }) {
        Row() {
          Text('实拍图预览').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_danger_action'));
          Blank();
          Button('关闭').width(72).height(48).fontSize(13).backgroundColor(pageColor(this.palette, 'surface'))
            .fontColor(pageColor(this.palette, 'ink')).borderRadius(24)
            .accessibilityText('关闭实拍图预览')
            .onClick(() => this.closePhotoPreview());
        }.width('100%');
        Swiper() {
          ForEach(this.detailPhotos, (photo: CardPhoto, index: number) => {
            if (photo.url.length > 0) {
              Image(photo.url).width('100%').height('100%').objectFit(ImageFit.Contain)
                .backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(16)
                .accessibilityText(`${this.card.productName}的完整实拍图`);
            } else {
              Column({ space: 6 }) {
                Text(this.mediaServiceUnavailable && this.photoFailures.includes(index)
                  ? '实拍图服务暂时不可用' : this.photoFailures.includes(index)
                    ? '这张实拍图暂不可用' : '正在加载这张实拍图')
                  .fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.on_danger_action'));
                Text('可左右切换查看其他图片，或重试当前图片。')
                  .fontSize(12).fontColor($r('app.color.on_danger_action'));
                if (this.photoFailures.includes(index)) {
                  Button('重试实拍图').height(44).fontSize(13)
                    .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'action'))
                    .onClick((): void => this.retryPhoto(index));
                }
              }
              .width('100%').height('100%').justifyContent(FlexAlign.Center)
              .backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(16);
            }
          }, (photo: CardPhoto): string => `${photo.id.length > 0 ? photo.id : photo.path}:${photo.url}`)
        }
        .width('100%').layoutWeight(1).index(this.previewPhotoIndex).indicator(this.detailPhotos.length > 1)
        .loop(false).onChange((index: number): void => {
          this.previewPhotoIndex = index;
          void this.hydratePhotoAt(index, 'high');
        });
        Text(`完整实拍 ${this.previewPhotoIndex + 1} / ${this.detailPhotos.length}`).fontSize(12)
          .fontColor($r('app.color.on_danger_action')).width('100%').textAlign(TextAlign.Center);
      }
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 24, bottom: 28 });
    }
    .width('100%').height('100%')
    .accessibilityText(`实拍图预览，共 ${this.detailPhotos.length} 张`);
  }

  @Builder
  private actionButton(icon: Resource, label: string, selected: boolean, ready: boolean, action: () => void): void {
    Button() {
      Column({ space: 6 }) {
        Image(icon).width(25).height(25).objectFit(ImageFit.Contain).accessibilityLevel('no');
        Text(label).fontSize(13).fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(selected ? pageColor(this.palette, 'action') : pageColor(this.palette, 'ink')).maxLines(2)
          .textAlign(TextAlign.Center).width('100%');
      }.width('100%').padding({ top: 10, bottom: 10, left: 2, right: 2 });
    }.type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: 68 }).padding(0).borderRadius(16)
      .backgroundColor(selected ? pageColor(this.palette, 'soft') : Color.Transparent)
      .animation({ duration: this.reducedMotion ? 0 : 180, curve: Curve.EaseOut })
      .enabled(ready).focusable(true).accessibilitySelected(selected)
      .accessibilityText(label + (selected ? '，已选中，再点可取消' : '')).onClick(action);
  }
  @Builder
  private cardActions(): void {
    Column({ space: 6 }) {
      if (this.interactionStatusText().length > 0) {
        Row({ space: 8 }) {
          if (this.interactionRecovering || this.preparingCollection || this.gateChecking) {
            LoadingProgress().width(18).height(18).color(pageColor(this.palette, 'action'));
          }
          Text(this.interactionStatusText()).fontSize(12).lineHeight(18)
            .fontColor(pageColor(this.palette, 'muted')).layoutWeight(1).maxLines(3);
        }.width('100%').padding({ left: 8, right: 8 });
      }
      if (this.interactionCanRetry) {
        Button('核对并重试').fontSize(12).backgroundColor(Color.Transparent).fontColor(pageColor(this.palette, 'action'))
          .onClick((): void => { void this.interactionController?.recover(true); });
      }
      if (this.loggedIn && (!this.interactionsKnown || this.interactionMessage.length > 0 || this.interactionCountsMessage.length > 0)) {
        Button('刷新互动状态').fontSize(12).backgroundColor(Color.Transparent).fontColor(pageColor(this.palette, 'action'))
          .enabled(!this.gateChecking).onClick((): void => { void this.refreshInteractions(); });
      }
      if (this.interactionsKnown && this.collectionEnabled && !this.collectionReady) {
        Button(this.preparingCollection ? '整理中…' : '整理旧收藏').fontSize(12).backgroundColor(Color.Transparent)
          .fontColor(pageColor(this.palette, 'action')).enabled(!this.preparingCollection && !this.collectionBusy)
          .onClick((): void => { void this.prepareFavorite(); });
      }
      Row({ space: 4 }) {
        CardInteractionButton({ icon: '👍', label: '赞 ' + this.likeCount, selected: this.myReaction === 'LIKE',
          ready: !this.reactionBusy && !this.gateChecking && (!this.loggedIn || this.interactionsKnown),
          palette: this.palette, reducedMotion: this.reducedMotion,
          onActivate: (): void => { this.react('LIKE'); } }).layoutWeight(1);
        CardInteractionButton({ icon: '🖕', label: '踩 ' + this.dislikeCount, selected: this.myReaction === 'DISLIKE',
          ready: !this.reactionBusy && !this.gateChecking && (!this.loggedIn || this.interactionsKnown),
          palette: this.palette, reducedMotion: this.reducedMotion,
          onActivate: (): void => { this.react('DISLIKE'); } }).layoutWeight(1);
        CardInteractionButton({ icon: '❤️', label: '收藏 ' + this.favoriteCount, selected: this.viewerFavorited,
          ready: !this.collectionBusy && !this.preparingCollection && (!this.loggedIn || this.interactionsKnown),
          palette: this.palette, reducedMotion: this.reducedMotion,
          onActivate: (): void => { this.favorite(); } }).layoutWeight(1);
        this.actionButton($r('app.media.ic_note_share'), '发给好友', false, this.detailReady,
          (): void => { this.shareToFriend(); });
      }.width('100%');
    }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 6 })
      .backgroundColor(pageColor(this.palette, 'surface'))
      .border({ width: { top: 1 }, color: pageColor(this.palette, 'line') })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
  }
  @Builder
  private detailHeading(): void {
    Row({ space: 12 }) {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(24).fontColor([pageColor(this.palette, 'ink')]); }
        .width(48).height(48).padding(0).backgroundColor(Color.Transparent).accessibilityText('返回上一页')
        .onClick((): void => { this.pathStack.pop(); });
      Text('美食笔记').fontSize(18).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
    }.width('100%').padding({ left: 8, right: 16, top: 4, bottom: 4 });
  }
  @Builder
  private reviewSection() {
    Column({ space: 8 }) {
      Row() {
        Text('发布者点评').fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
        Blank();
        if (this.tasteScoreText().length > 0) {
          Text('口味 ' + this.tasteScoreText()).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(pageColor(this.palette, 'action')).padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor(pageColor(this.palette, 'soft')).borderRadius(10);
        }
      }.width('100%');
      Text(this.reviewText()).fontSize(16).lineHeight(26).fontColor(pageColor(this.palette, 'ink')).width('100%');
    }
    .width('100%').padding(16).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(18)
    .border({ width: 1, color: pageColor(this.palette, 'line') });
  }

  @Builder
  private infoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(13).fontColor(pageColor(this.palette, 'muted')).width(64);
      Text(value.length > 0 ? value : '待补充').fontSize(14).fontColor(pageColor(this.palette, 'ink'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
    }.width('100%').alignItems(VerticalAlign.Top);
  }

  @Builder
  private productInfo(): void {
    Column({ space: 14 }) {
      Text(this.card.productName).fontSize(26).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(3);
      Text(this.priceText()).fontSize(25).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action')).width('100%');
      Row({ space: 8 }) {
        Text(this.card.categoryV2 === undefined ? categoryLabel(this.card.category) : categoryV2Label(this.card.categoryV2))
          .fontSize(13).fontColor(pageColor(this.palette, 'action')).padding(8).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(10);
        Text(this.card.consumptionMode === 'DELIVERY' ? '外卖' : this.card.consumptionMode === 'DINE_IN' ? '到店' : '美食推荐')
          .fontSize(13).fontColor(pageColor(this.palette, 'muted')).padding(8).backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(10);
      }.width('100%');
      if ((this.card.merchantNameSnapshot || this.card.shop).trim().length > 0) { this.infoRow('店铺', this.card.merchantNameSnapshot || this.card.shop); }
      if ((this.card.merchantAddressSnapshot || this.card.district).trim().length > 0) { this.infoRow('地点', this.card.merchantAddressSnapshot || this.card.district); }
      if (this.card.consumptionMode === 'DINE_IN' && this.card.merchantId !== undefined && this.card.merchantId.length > 0) {
        Button('去这里 · 商家导航').width('100%').onClick((): void => { void this.navigateMerchant(); }).attributeModifier(new NoteActionStyle(false, this.palette));
      }
      if (this.navigationAddress.length > 0) { Button('复制商家地址').width('100%').onClick((): void => { void this.copyNavigationAddress(); }).attributeModifier(new NoteActionStyle(false, this.palette)); }
      if (this.card.consumptionMode === 'DINE_IN' && this.card.itemPriceFen !== undefined) { this.infoRow('单品价格', '¥' + formatFenInput(this.card.itemPriceFen)); }
      if (this.card.deliveryPlatformLabelSnapshot !== undefined && this.card.deliveryPlatformLabelSnapshot.length > 0) { this.infoRow('外卖平台', this.card.deliveryPlatformLabelSnapshot); }
      if (this.card.specification.trim().length > 0) { this.infoRow('规格', this.card.specification); }
      if (this.card.publicOffers.length > 0) { this.infoRow('优惠', this.card.publicOffers.join('；')); }
      if (this.card.edited === true) { this.infoRow('内容状态', '已编辑'); }
      if (isSafeHttpsSourceLink(this.card.sourceLink)) { Button('打开来源页面').width('100%').onClick((): void => { void this.openSource(); }).attributeModifier(new NoteActionStyle(false, this.palette)); }
    }.width('100%').padding(18).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(22);
  }

  private editorUid(): string { const profile = AuthService.profile(); return profile === undefined ? '' : profile.uid; }

  build() {
    NavDestination() {
      if (this.editingVisible && this.loggedIn && this.detailReady) {
        CreateCardPage({ palette: this.palette, editCardId: this.card.id, accountUid: this.editorUid(), onEditingFinished: (): void => {
          this.editingVisible = false; void this.loadDetail();
        } })
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
          WarmNoteBackdrop({ palette: this.palette });
          Column() {
            this.detailHeading();
            if (!this.detailReady) {
              Column({ space: 16 }) {
                if (this.entryCoverUrl.length > 0) { Image(this.entryCoverUrl).width('100%').height(this.imageHeight()).objectFit(ImageFit.Contain).borderRadius(22).accessibilityText('商品实拍封面'); }
                if (this.status.length === 0) { LoadingProgress().width(32).height(32).color(pageColor(this.palette, 'action')); }
                Text(this.status.length > 0 ? this.status : '正在打开美食笔记…').fontSize(15).fontColor(pageColor(this.palette, 'muted'));
                Button('重新读取').onClick((): void => { void this.loadDetail(); }).attributeModifier(new NoteActionStyle(false, this.palette));
              }.width('100%').layoutWeight(1).padding(20).justifyContent(FlexAlign.Center);
            } else {
              Scroll(this.detailScroller) {
                Column({ space: 16 }) {
                  this.authorHeader();
                  Flex({ direction: this.isWideDetail() ? FlexDirection.Row : FlexDirection.Column, alignItems: ItemAlign.Start }) {
                    Column({ space: 10 }) {
                      this.photoCarousel();
                      if (this.knockShareEnabled) { this.knockShareNotice(); }
                    }.width(this.detailColumnWidth()).flexShrink(0)
                      .margin({ right: this.isWideDetail() ? 24 : 0, bottom: this.isWideDetail() ? 0 : 16 });
                    Column({ space: 16 }) { this.productInfo(); this.reviewSection(); }
                      .width(this.detailColumnWidth()).flexShrink(0).alignItems(HorizontalAlign.Start);
                  }.width('100%');
                }.width('100%').padding({ left: this.detailPadding(), right: this.detailPadding(), top: 4, bottom: 20 });
              }.width('100%').layoutWeight(1).scrollBar(BarState.Off);
              this.cardActions();
            }
          }.width('100%').height('100%');
          if (this.photoPreviewVisible) { this.photoPreview(); }
          else if (this.actionMenuVisible) {
            Column() {}.width('100%').height('100%').backgroundColor($r('app.color.scrim')).onClick((): void => this.dismissOverlay());
            this.actionMenu();
          }
        }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas'))
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            const height: number = Number(newArea.height); const width: number = Number(newArea.width);
            if (Number.isFinite(height) && height > 0) this.detailHeightVp = height;
            if (Number.isFinite(width) && width > 0 && this.detailWidthVp !== width) this.detailWidthVp = width;
          });
      }
    }.hideTitleBar(!this.editingVisible).attributeModifier(new AppDestinationStyle(this.editingVisible ? '编辑推荐' : '', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette))
      .onShown((): void => {
        this.reducedMotion = this.motionObserver.start();
        if (!this.detailVisible) { this.detailVisible = true; if (this.appActive) void this.loadDetail(); }
      })
      .onHidden((): void => {
        this.motionObserver.stop(); this.reducedMotion = true;
        this.savedScrollY = this.detailScroller.currentOffset().yOffset;
        if (this.restoreTimer !== -1) { clearTimeout(this.restoreTimer); this.restoreTimer = -1; }
        this.detailVisible = false; ImageRepository.subscriptionsChanged(); ReadScheduler.subscriptionsChanged();
        this.detailGeneration++; this.clearDetailView();
      });
  }
}
