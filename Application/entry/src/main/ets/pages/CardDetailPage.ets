/**
 * 【文件职责】卡片详情页（最大的页面）：沉浸式大图轮播与全屏预览、作者信息、点评与口味评分、价格与店铺信息、来源链接、
 * 互动（赞 / 踩 / 收藏，由 CardInteractionController 协调）、发给好友、碰一碰分享（Share Kit）、举报、作者编辑 / 删除、店铺导航。
 * 【加载链路】先用列表传入的卡片与封面立即显示（showEntryCover）→ get-card-detail 读取完整详情（CardRepository.detail）
 * → 按需加载每张原图（hydratePhotoAt，并预取下一张）→ 写入本机浏览记录（CardVisitStore）。
 * 卡片不可见（下架、删除、无权限）时清空页面并提示；所有异步结果用 detailGeneration 判断是否过期。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { WarmNoteBackdrop, notePanelTransition } from '../common/WarmNoteUi';
import { RandomFoodMotionObserver } from '../common/RandomFoodUi';
import { ReportRoute } from '../model/ContentStatusModels';
import { AppDestinationStyle, AppPageSurface } from '../common/AppPageUi';
import { StateView } from '../common/StateViewUi';
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
import { tasteScoreLabel, tasteScoreText as formatTasteScore } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { BreakpointSystem } from '../common/BreakpointSystem';
import { CreateCardPage } from './CreateCardPage';
import { categoryV2Label, formatFenInput } from '../model/PublishingModels';
import { isSafeHttpsSourceLink } from '../service/SafeSourceLink';
import { CardInteractionController } from '../service/CardInteractionController';
import { InteractionView } from '../model/CardInteractionModels';
import { CardInteractionButton } from '../components/CardInteractionButton';

const DETAIL_MEDIA_MAX_HEIGHT: number = 420;

// 商品信息区的一项（类型、标签、值）。
interface DetailInfoItem { kind: string; label: string; value: string; }

// 空卡片占位。
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

// 旧数据没有 photos 数组时，用单图字段构造首图。
function fallbackPhoto(card: FoodCard): CardPhoto {
  return {
    id: '', url: '', path: card.photoPath, bucket: card.photoBucket,
    width: card.photoWidth, height: card.photoHeight
  };
}

// 卡片详情页面。
@Component
export struct CardDetailPage {
  @Prop palette: PagePaletteName = 'NOTE';
  @StorageLink('favoritesMutationRevision') @Watch('onFavoriteMutation') favoritesMutationRevision: number = 0;
  // 别处修改了收藏时刷新互动状态。
  private onFavoriteMutation(): void {
    const controller: CardInteractionController | undefined = this.interactionController;
    if (this.detailVisible && this.appActive && controller !== undefined && controller.needsFavoriteRefresh())
      void controller.refreshState();
  }
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  private detailVisible: boolean = false;
  // App 进入后台时作废进行中的请求并停止碰一碰分享；回到前台时重新加载。
  private onAppActiveChanged(): void { if (!this.appActive) { this.detailGeneration++; this.clearDetailView(); } else if (this.detailVisible) void this.loadDetail(); }

  @State @Watch('syncEdgeImage') detailWidthVp: number = 0;
  @State @Watch('syncEdgeImage') heroAtTop: boolean = true;
  @StorageProp('appSystemTopPx') systemTopPx: number = 0;
  private edgeOwner: number = AppPageSurface.newImmersiveOwner();
  @State detailHeightVp: number = 0;
  @State collectionReady: boolean = false;
  @State collectionKnown: boolean = false;
  private detailScroller: Scroller = new Scroller();
  private savedScrollY: number = 0;
  private photoGeneration: number = 0;
  private restoreTimer: number = -1;
  @StorageLink('accountContentRevision') @Watch('onSessionChanged') accountContentRevision: number = 0;
  @State navigationAddress: string = '';
  @State @Watch('syncEdgeImage') detailReady: boolean = false;
  @State dislikeCount: number = 0;
  @State myReaction: CardReactionType | '' = '';
  @State @Watch('syncEdgeImage') editingVisible: boolean = false;
  @Prop card: FoodCard = emptyCard();
  @Prop @Watch('onSessionChanged') loggedIn: boolean = false;
  onRequireLogin: (message: string) => void = (_message: string): void => {};
  onOpenAuthor: (uid: string) => void = (_uid: string): void => {};
  onShareToFriend: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State @Watch('syncEdgeImage') detailPhotos: Array<CardPhoto> = [];
  @State entryCoverUrl: string = '';
  @State @Watch('syncEdgeImage') coverUrls: Array<string> = [];
  @State @Watch('syncEdgeImage') decodedPhotoUrls: Array<string> = [];
  @State photoFailures: Array<number> = [];
  @State mediaServiceUnavailable: boolean = false;
  @State @Watch('syncEdgeImage') photoIndex: number = 0;
  @State @Watch('syncEdgeImage') photoPreviewVisible: boolean = false;
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

  // 出现时加载详情并绑定互动。
  aboutToAppear(): void {
    this.primaryImageStarted = Date.now();
    this.mediaServiceUnavailable = false;
    this.clearDetailView();
  }

  // 消失时停止分享、解绑互动并清空大图。
  aboutToDisappear(): void {
    AppPageSurface.setImmersiveTop(this.edgeOwner, false);
    this.motionObserver.stop();
    if (this.restoreTimer !== -1) { clearTimeout(this.restoreTimer); this.restoreTimer = -1; }
    this.clearDetailView();
    this.detailGeneration += 1;
    this.finishPrimaryImage('cancelled');
  }

  // 会话变化（换号）时重新加载。
  private onSessionChanged(): void {
    this.pendingMigrationId = ''; this.editingVisible = false; this.savedScrollY = 0;
    this.clearDetailView();
    if (this.detailVisible && this.appActive) void this.loadDetail();
  }

  // 需要登录的操作前检查登录（未登录时提示）。
  private requireAccount(): boolean {
    if (this.loggedIn && AuthService.profile() !== undefined && CloudGateway.hasSession()) return true;
    this.closeActionMenu();
    this.onRequireLogin('登录后可点赞、收藏和与好友分享。');
    return false;
  }

  // 结束首图加载的性能指标。
  private finishPrimaryImage(state: PreloadMetricState): void {
    if (this.primaryImageStarted === 0) return;
    NearbyPerformanceTrace.record('detail_primary_image', state, this.primaryImageStarted);
    this.primaryImageStarted = 0;
  }

  // 清空详情视图（卡片不可见或换号时）。
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

  // 先显示列表中带过来的封面，减少等待。
  private async showEntryCover(generation: number): Promise<void> {
    const photo: CardPhoto = this.card.photos?.[0] || fallbackPhoto(this.card);
    const url: string = await ImageRepository.cachedPhotoUrl(this.getUIContext().getHostContext() as common.UIAbilityContext,
      photo, true, this.card.contentRevision || '');
    if (generation === this.detailGeneration && this.detailVisible && this.appActive && !this.detailReady) {
      this.entryCoverUrl = url;
      if (url.length > 0) console.info('[DetailImage] event=entry-cover-ready source=cache');
    }
  }

  // 显示某张图片的本机缓存（如有）。
  private async showCachedCover(index: number, generation: number): Promise<void> {
    const photo: CardPhoto | undefined = this.detailPhotos[index];
    if (photo === undefined) return;
    const contentRevision: string = this.card.contentRevision || '';
    const url: string = await ImageRepository.cachedPhotoUrl(this.getUIContext().getHostContext() as common.UIAbilityContext,
      photo, true, contentRevision);
    if (generation !== this.detailGeneration || !this.detailVisible || !this.appActive || !this.detailReady || contentRevision !== (this.card.contentRevision || '') || this.detailPhotos[index]?.id !== photo.id) return;
    this.coverUrls = this.coverUrls.map((value: string, position: number): string => position === index ? url : value);
  }

  // 预取下一张原图。
  private prefetchNextPhoto(index: number): void {
    if (index !== this.photoIndex || !this.detailVisible || !this.appActive || !this.detailReady || !ReadScheduler.canPrefetch()) return;
    if (index + 1 >= this.detailPhotos.length || this.hydratingPhotoIndices.has(index + 1) || this.detailPhotos[index + 1].url.length > 0) return;
    this.photoPrefetchIndex = index + 1;
    void this.hydratePhotoAt(index + 1, 'prefetch');
  }

  // 读取完整详情（流程见文件头）。
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
          // 列表中的图片地址都是封面；只有读取到的原图（缓存或云端）才能填入这里。
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
        // 本机浏览记录写入失败绝不能把一次成功的详情加载变成错误。
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

  // 加载第 index 张原图。
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

  // 图片解码失败：清除缓存并允许重试。
  private photoDecodeFailed(index: number): void {
    const photo: CardPhoto | undefined = this.detailPhotos[index]; if (photo === undefined) return;
    this.decodedPhotoUrls = this.decodedPhotoUrls.filter((url: string): boolean => url !== photo.url);
    if (index === 0) this.finishPrimaryImage('error');
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    void ImageRepository.reportDecodeFailure(context, photo.id || photo.path.split('/').pop()?.replace('.jpg', '') || '').catch((): void => {});
    photo.url = ''; this.detailPhotos = this.detailPhotos.slice();
    if (!this.photoFailures.includes(index)) this.photoFailures = this.photoFailures.concat([index]);
  }

  // 重试加载某张图片。
  private retryPhoto(index: number): void {
    ImageRepository.retryUnavailableService();
    this.mediaServiceUnavailable = false;
    this.photoFailures = this.photoFailures.filter((failed: number): boolean => failed !== index);
    void this.hydratePhotoAt(index, 'high');
  }

  // 加载作者头像。
  private async hydrateAuthorAvatar(generation: number): Promise<void> {
    if (this.detailAuthorAvatarUrl.length > 0 || !this.card.authorAvatarPath || !this.card.authorAvatarBucket) return;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await ImageRepository.getDownloadUrl(context, this.card.authorAvatarBucket,
        this.card.authorAvatarPath, 'low', async (): Promise<boolean> => generation === this.detailGeneration && this.detailVisible && this.appActive);
      if (generation === this.detailGeneration) this.detailAuthorAvatarUrl = url;
    } catch (error) { if (generation === this.detailGeneration && error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'ACCOUNT_INACTIVE'].includes(error.code)) { this.clearDetailView(); this.status = '该作者当前不可访问。'; } }
  }

  // 作者名称。
  private authorName(): string {
    if (this.detailAuthorNickname.length > 0) return this.detailAuthorNickname;
    const value = this.card.authorNickname;
    return value !== undefined && value.length > 0 ? value : '食刻用户';
  }

  // 作者头像地址。
  private authorAvatarUrl(): string {
    if (this.detailAuthorAvatarUrl.length > 0) return this.detailAuthorAvatarUrl;
    const value = this.card.authorAvatarUrl;
    return value === undefined ? '' : value;
  }

  // 大图高度（随屏幕宽度与图片比例）。
  private imageHeight(): number {
    const width: number = this.isWideDetail() ? this.detailPaneWidth() : Math.max(240, this.detailWidthVp - this.detailPadding() * 2);
    const photo: CardPhoto | undefined = this.detailPhotos[this.photoIndex];
    const natural: number = photo !== undefined && photo.width > 0 && photo.height > 0 ? width * photo.height / photo.width : width;
    const available: number = this.detailHeightVp > 0 ? this.detailHeightVp * 0.58 : DETAIL_MEDIA_MAX_HEIGHT;
    return Math.round(Math.max(180, Math.min(DETAIL_MEDIA_MAX_HEIGHT, available, natural)));
  }

  // 是否为宽屏双栏布局。
  private isWideDetail(): boolean {
    return this.detailWidthVp >= BreakpointSystem.LARGE_MIN;
  }

  // 页面内边距。
  private detailPadding(): number {
    return BreakpointSystem.pagePadding(BreakpointSystem.fromWidth(this.detailWidthVp));
  }

  // 宽屏下详情栏宽度。
  private detailPaneWidth(): number {
    return Math.max(0, (this.detailWidthVp - this.detailPadding() * 2 - 24) / 2);
  }

  // 内容栏宽度。
  private detailColumnWidth(): number | string {
    return this.isWideDetail() ? this.detailPaneWidth() : '100%';
  }

  // 打开全屏图片预览。
  private openPhotoPreview(index: number): void {
    if (index < 0 || index >= this.detailPhotos.length || this.detailPhotos[index].url.length === 0) return;
    this.previewPhotoIndex = index;
    this.photoPreviewVisible = true;
  }

  // 关闭全屏图片预览。
  private closePhotoPreview(): void {
    this.photoPreviewVisible = false;
  }

  // 发布时间文字。
  private createdLabel(timestamp: number): string {
    if (timestamp <= 0) return '刚刚发布';
    const date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  // 点评文字。
  private reviewText(): string {
    const reviewText = typeof this.card.reviewText === 'string' ? this.card.reviewText.trim() : '';
    if (reviewText.length > 0) return reviewText;
    return this.card.sellingPoints.length > 0
      ? this.card.sellingPoints.join('；') : '发布者暂未填写点评。';
  }

  // 评分文字。
  private tasteScoreText(): string {
    const score = typeof this.card.tasteScore === 'number' ? this.card.tasteScore : 0;
    return formatTasteScore(score);
  }

  // 卡片分享链接（shike://card?cardId=…）。
  private cardLink(): string {
    return this.detailReady && this.card.status === 'APPROVED' ? cardDeepLink(this.card.id) : '';
  }

  // 互动订阅是否仍属于当前详情。
  private interactionCurrent(generation: number): boolean {
    return generation === this.detailGeneration && this.detailReady && this.detailVisible && this.appActive;
  }
  // 绑定 CardInteractionController（订阅互动状态变化）。
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
  // 收藏前的准备（旧收藏未迁移时提示整理）。
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

  // 碰一碰分享前重新读取卡片，确认仍可分享。
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
  // 点击赞 / 踩。
  private react(reaction: CardReactionType): void {
    if (!this.requireAccount() || !this.detailReady || !this.detailVisible || !this.appActive) return;
    this.interactionController?.chooseReaction(reaction);
  }
  // 点击收藏。
  private favorite(): void {
    if (!this.requireAccount() || !this.detailReady || !this.detailVisible || !this.appActive) return;
    this.interactionController?.chooseFavorite();
  }
  // 互动区的提示文字。
  private interactionStatusText(): string {
    const messages: Array<string> = [];
    if (this.interactionMessage.length > 0) messages.push(this.interactionMessage);
    if (this.collectionFeedback.length > 0) messages.push(this.collectionFeedback);
    if (this.interactionCountsMessage.length > 0) messages.push(this.interactionCountsMessage);
    if (this.status.length > 0) messages.push(this.status);
    return messages.join('；');
  }
  // 刷新互动状态。
  private async refreshInteractions(): Promise<void> {
    if (!this.requireAccount() || this.gateChecking) return;
    this.gateChecking = true;
    if (this.interactionController === undefined) this.bindInteractions(this.detailGeneration);
    try { await this.interactionController?.refreshState(); }
    finally { this.gateChecking = false; }
  }

  // 构造分享数据（卡片链接）。
  private cardLinkShareData(): systemShare.SharedData {
    // harmonyShare 也需要 SharedData；这里只构造数据，不会打开分享面板。
    const record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.HYPERLINK,
      content: this.cardLink(),
      title: '食刻推荐：' + (this.card.productName || '美食卡片'),
      description: '请在已安装的食刻中查看这张美食卡片'
    };
    return new systemShare.SharedData(record);
  }

  // 开启 / 关闭碰一碰分享。
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

  // 停止碰一碰分享并显示状态。
  private stopKnockShare(status: string): void {
    const wasEnabled: boolean = this.knockShareEnabled;
    this.knockShareGeneration += 1;
    this.knockShareEnabled = false;
    this.knockShareBusy = false;
    if (wasEnabled) {
      try {
        harmonyShare.off('knockShare', this.knockShareListener);
      } catch (_error) {
        // 系统可能已经移除了前台回调。
      }
    }
    if (status.length > 0) this.status = status;
  }

  // 拒绝一次碰一碰分享请求。
  private async rejectKnockShare(target: harmonyShare.SharableTarget,
    reason: harmonyShare.SharableErrorCode): Promise<void> {
    try { await target.reject(reason); } catch (_error) {
      // 系统可能已经关闭了这次碰一碰会话。
    }
  }

  // 向碰一碰的目标设备发送分享数据。
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

  // 价格文字。
  private priceText(): string {
    return cardPriceText(this.card);
  }

  // 用系统浏览器打开来源链接（只允许 HTTPS）。
  private async openSource(): Promise<void> {
    const generation: number = this.detailGeneration; this.closeActionMenu();
    try { const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fresh: FoodCard = await this.repository.detail(context, this.card.id); if (generation !== this.detailGeneration || !this.detailReady) return;
      if (!isSafeHttpsSourceLink(fresh.sourceLink)) throw new Error('当前卡片没有可打开的来源页面。');
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: fresh.sourceLink });
    } catch (error) { if (generation === this.detailGeneration) { this.clearDetailView(); this.status = errorText(error as ErrorDetail); } }
  }

  // 导航到店铺。
  private async navigateMerchant(): Promise<void> { const generation: number = this.detailGeneration; try { const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext; const fresh: FoodCard = await this.repository.detail(context, this.card.id); if (generation !== this.detailGeneration || !this.detailReady) return; if (fresh.consumptionMode !== 'DINE_IN' || !fresh.merchantId) throw new Error('当前卡片没有可导航的到店商家。'); const result: MerchantResponse = await new MerchantRepository().get(context, fresh.merchantId); if (generation !== this.detailGeneration || !this.detailReady) return; this.navigationAddress = result.merchant.address || result.merchant.name; await MerchantNavigationService.open(context, result.merchant); } catch (error) { if (generation === this.detailGeneration) this.status = errorText(error as ErrorDetail); } }

  // 复制店铺地址。
  private async copyNavigationAddress(): Promise<void> { if (!this.detailReady || this.navigationAddress.length === 0) return; try { const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.navigationAddress); await pasteboard.getSystemPasteboard().setData(data); this.status = '已复制商家地址。'; } catch (error) { this.status = errorText(error as ErrorDetail); } }

  // 关闭操作菜单。
  private closeActionMenu(): void {
    this.actionMenuVisible = false;
  }

  // 打开“发给好友”。
  private shareToFriend(): void {
    if (!this.requireAccount()) return;
    this.closeActionMenu();
    this.onShareToFriend(this.card);
  }

  // 关闭所有弹层。
  private dismissOverlay(): void {
    this.closeActionMenu();
    this.closePhotoPreview();
  }

  // 打开举报页。
  private openReport(): void {
    if (!this.requireAccount() || !this.detailReady) return;
    const request: ReportRoute = { targetType: 'CARD', targetId: this.card.id };
    this.closeActionMenu(); this.pathStack.pushPathByName('report-content', request);
  }

  // 作者信息区。
  @Builder
  private authorHeader() {
    Row({ space: 10 }) {
      Button() {
        if (this.authorAvatarUrl().length > 0) {
          Image(this.authorAvatarUrl()).width(36).height(36).borderRadius(18).objectFit(ImageFit.Cover).accessibilityLevel('no');
        } else { Image($r('app.media.app_icon')).width(36).height(36).borderRadius(18).accessibilityLevel('no'); }
      }.type(ButtonType.Normal).width(44).height(44).padding(4).backgroundColor(Color.Transparent).borderRadius(22)
        .enabled(this.card.authorUid !== undefined && this.card.authorUid.length > 0)
        .accessibilityText(`查看${this.authorName()}的主页`)
        .onClick((): void => { if (this.card.authorUid !== undefined) this.onOpenAuthor(this.card.authorUid); });
      Column({ space: 2 }) {
        Text(this.authorName()).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${this.authorPlace()} · ${this.createdLabel(this.card.publishedAt === undefined ? this.card.createdAt : this.card.publishedAt)}`)
          .fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Text('实拍分享').fontSize(11).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action'))
        .padding({ left: 9, right: 9, top: 4, bottom: 4 }).borderRadius(12)
        .border({ width: 1.2, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed });
      if (this.isWideDetail()) {
        Button() {
          Image($r('app.media.ic_more')).width(24).height(24).objectFit(ImageFit.Contain)
            .fillColor(pageColor(this.palette, 'ink')).accessibilityLevel('no');
        }
        .width(48).height(48).padding(12).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
        .accessibilityText('更多帖子操作')
        .onClick(() => {
          this.actionMenuVisible = !this.actionMenuVisible;
        });
      }
    }.width('100%');
  }

  // 作者所在地文字。
  private authorPlace(): string {
    return this.card.merchantNameSnapshot || (this.card.consumptionMode === 'DELIVERY' || this.card.consumptionMode === 'DINE_IN'
      ? '店铺未关联' : this.card.district || '历史发布位置');
  }

  // 操作菜单中的一行。
  @Builder
  private menuRow(label: string, icon: Resource, danger: boolean, onTap: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph(icon).fontSize(18)
            .fontColor([danger ? $r('app.color.danger') : pageColor(this.palette, 'action')]).accessibilityLevel('no');
        }
        .width(32).height(32).borderRadius(10)
        .backgroundColor(danger ? $r('app.color.danger_soft') : pageColor(this.palette, 'soft'));
        Text(label).fontSize(15).fontColor(danger ? $r('app.color.danger') : pageColor(this.palette, 'ink')).layoutWeight(1);
      }.width('100%');
    }
    .width('100%').height(52).padding({ left: 4, right: 4 }).backgroundColor(Color.Transparent).borderRadius(12)
    .accessibilityText(label).onClick(onTap);
  }

  // 操作菜单（编辑、删除、举报、分享等）。
  @Builder
  private actionMenu() {
    Column({ space: 2 }) {
      Column().width(36).height(4).borderRadius(2).backgroundColor(pageColor(this.palette, 'line')).margin({ bottom: 8 });
      Text('更多操作').fontSize(16).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
        .width('100%').margin({ bottom: 4 });
      this.menuRow('发送给食刻好友', $r('sys.symbol.paperplane'), false, (): void => { this.shareToFriend(); });
      this.menuRow(this.knockShareEnabled ? '结束碰一碰分享' : '碰一碰分享', $r('sys.symbol.phone'), false,
        (): void => { if (!this.knockShareBusy) this.toggleKnockShare(); });
      if (this.viewerIsOwner && this.loggedIn) {
        this.menuRow('编辑推荐', $r('sys.symbol.square_and_pencil'), false,
          (): void => { this.closeActionMenu(); this.editingVisible = true; });
      }
      if (this.card.consumptionMode === 'DINE_IN' && this.card.merchantId !== undefined && this.card.merchantId.length > 0) {
        this.menuRow('去这里 · 商家导航', $r('sys.symbol.location_north_up_right'), false,
          (): void => { void this.navigateMerchant(); this.closeActionMenu(); });
      }
      if (isSafeHttpsSourceLink(this.card.sourceLink)) {
        this.menuRow('打开来源页面', $r('sys.symbol.link'), false, (): void => { void this.openSource(); });
      }
      Column().width('100%').height(1).margin({ top: 4, bottom: 4 })
        .border({ width: { top: 1.2 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
      this.menuRow('举报卡片', $r('sys.symbol.flag'), true, (): void => this.openReport());
      Button('取消').width('100%').height(46).margin({ top: 8 }).fontSize(15)
        .backgroundColor(pageColor(this.palette, 'canvas')).fontColor(pageColor(this.palette, 'ink'))
        .onClick(() => this.closeActionMenu());
    }
    .width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 16, right: 16, top: 10, bottom: 20 })
    .transition(notePanelTransition(this.reducedMotion))
    .backgroundColor(pageColor(this.palette, 'surface')).borderRadius({ topLeft: 24, topRight: 24 });
  }

  // 碰一碰分享提示条。
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

  // 图片轮播。
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

  // 全屏图片预览。
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
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 24 + (this.heroLayout() ? this.topInset() : 0), bottom: 28 });
    }
    .width('100%').height('100%')
    .accessibilityText(`实拍图预览，共 ${this.detailPhotos.length} 张`);
  }

  // ---- 沉浸式大图（手机宽度）----

  // 顶部安全区高度。
  private topInset(): number {
    return this.getUIContext().px2vp(this.systemTopPx);
  }

  // 大图区域高度。
  private heroHeight(): number {
    const width: number = this.detailWidthVp > 0 ? this.detailWidthVp : 360;
    const limit: number = this.detailHeightVp > 0 ? this.detailHeightVp * 0.5 : 360;
    return Math.round(Math.max(220, Math.min(width * 0.82, limit)));
  }

  // 第 index 张大图的地址。
  private heroUrl(index: number): string {
    const photo: CardPhoto | undefined = this.detailPhotos[index];
    if (photo === undefined) return '';
    if (photo.url.length > 0 && this.decodedPhotoUrls.includes(photo.url)) return photo.url;
    return this.coverUrls[index] || '';
  }

  // 手机宽度的大图布局：大图由本页直接画到状态栏下（页面不预留顶部安全区），随页面一起转场。
  private heroLayout(): boolean {
    return this.detailReady && !this.isWideDetail() && !this.editingVisible;
  }

  // 状态栏区域显示页面顶部色（而不是大图）：大图已滚走，或全屏预览打开时。
  private statusStripVisible(): boolean {
    return this.heroLayout() && (!this.heroAtTop || this.photoPreviewVisible);
  }

  // 大图正露在状态栏下时声明沉浸状态，让状态栏文字改为白色。
  private syncEdgeImage(): void {
    const immersive: boolean = this.detailVisible && this.heroLayout() && this.heroAtTop &&
      !this.photoPreviewVisible && this.heroUrl(this.photoIndex).length > 0;
    AppPageSurface.setImmersiveTop(this.edgeOwner, immersive);
  }

  // 大图滚动时更新“大图是否在顶部”（决定状态栏区域显示大图还是页面顶部色）。
  private onHeroScroll(): void {
    const atTop: boolean = this.detailScroller.currentOffset().yOffset <= 1;
    if (atTop !== this.heroAtTop) this.heroAtTop = atTop;
  }

  // 沉浸式大图区域。
  @Builder
  private hero() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.detailPhotos.length > 0) {
        Swiper() {
          ForEach(this.detailPhotos, (photo: CardPhoto, index: number) => {
            Stack({ alignContent: Alignment.Top }) {
              Column().width('100%').height('100%').backgroundColor(pageColor(this.palette, 'soft'));
              if ((this.coverUrls[index] || '').length > 0 && !this.decodedPhotoUrls.includes(photo.url)) {
                // 大图从页面顶边开始画，上面一段位于状态栏下。
                Image(this.coverUrls[index]).width('100%').height(this.topInset() + this.heroHeight()).objectFit(ImageFit.Cover)
                  .onError((): void => {
                    this.coverUrls = this.coverUrls.map((url: string, position: number): string => position === index ? '' : url);
                  })
                  .accessibilityText(`${this.card.productName}的实拍封面，正在加载清晰图片`);
              }
              if (photo.url.length > 0) {
                Image(photo.url).width('100%').height(this.topInset() + this.heroHeight()).objectFit(ImageFit.Cover)
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
                  .accessibilityText(`${this.card.productName}的发布者实拍图，轻点查看完整图片`)
                  .accessibilityDescription('轻点查看完整图片；左右滑动可切换实拍图')
                  .onClick(() => this.openPhotoPreview(index));
              }
              if (photo.url.length === 0 && (this.coverUrls[index] || '').length === 0) {
                Column({ space: 6 }) {
                  Text(this.mediaServiceUnavailable && this.photoFailures.includes(index)
                    ? '实拍图服务暂时不可用' : this.photoFailures.includes(index)
                      ? '这张实拍图暂不可用' : '正在加载这张实拍图')
                    .fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'muted'));
                  Text(this.photoFailures.includes(index) ? '点评仍可阅读，点下方重试。' : '点评已可阅读。')
                    .fontSize(12).fontColor(pageColor(this.palette, 'muted'));
                  if (this.photoFailures.includes(index)) {
                    Button('重试实拍图').height(44).fontSize(13)
                      .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'action'))
                      .onClick((): void => this.retryPhoto(index));
                  }
                }.width('100%').height('100%').justifyContent(FlexAlign.Center);
              } else if (this.photoFailures.includes(index)) {
                Column() {
                  Button('重试清晰图片').height(44).backgroundColor(pageColor(this.palette, 'surface'))
                    .fontColor(pageColor(this.palette, 'action')).onClick((): void => this.retryPhoto(index));
                }.width('100%').height('100%').justifyContent(FlexAlign.Center);
              }
            }.width('100%').height(this.topInset() + this.heroHeight());
          }, (photo: CardPhoto): string => `${photo.id.length > 0 ? photo.id : photo.path}:${photo.url}`)
        }
        .width('100%').height(this.topInset() + this.heroHeight()).index(this.photoIndex).indicator(false)
        .loop(false).onChange((index: number): void => {
          this.photoIndex = index;
          ImageRepository.subscriptionsChanged();
          void this.showCachedCover(index, this.detailGeneration).catch((): void => {});
          void this.hydratePhotoAt(index, 'high');
          if (this.decodedPhotoUrls.includes(this.detailPhotos[index]?.url || '')) this.prefetchNextPhoto(index);
        });
        // 状态栏区域保持 35% 遮罩（白色状态栏文字可读），其下 90vp 逐渐淡出。
        Column().width('100%').height(this.topInset() + 90).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          .linearGradient({ direction: GradientDirection.Bottom, colors: [['#59000000', 0],
            ['#59000000', this.topInset() / (this.topInset() + 90)], ['#00000000', 1]] });
        if (this.detailPhotos.length > 1) {
          Row() {
            Blank();
            Text(`${this.photoIndex + 1} / ${this.detailPhotos.length}`).fontSize(11).fontColor('#FFF8EC')
              .height(22).padding({ left: 9, right: 9 }).borderRadius(11).backgroundColor('#8C14100A')
              .accessibilityText(`第 ${this.photoIndex + 1} 张，共 ${this.detailPhotos.length} 张实拍图`);
          }.width('100%').padding({ right: 14 }).position({ x: 0, y: this.topInset() + this.heroHeight() - 58 })
            .hitTestBehavior(HitTestMode.None);
        }
      } else {
        Column({ space: 6 }) {
          Text('暂无发布者实拍图').fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'muted'));
          Text('卡片仍可查看点评、商品信息与来源。').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        }.width('100%').height(this.topInset() + this.heroHeight() * 0.6).padding({ top: this.topInset() })
          .justifyContent(FlexAlign.Center)
          .backgroundColor(pageColor(this.palette, 'soft'));
      }
    }.width('100%');
  }

  // 浮动顶部栏（返回、更多）。
  @Builder
  private floatingTopBar() {
    Row() {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([Color.White]).accessibilityLevel('no');
      }
      .width(40).height(40).backgroundColor('#6B14100A').accessibilityText('返回上一页')
      .onClick((): void => { this.pathStack.pop(); });
      Blank();
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image($r('app.media.ic_more')).width(22).height(22).fillColor(Color.White).accessibilityLevel('no');
      }
      .width(40).height(40).backgroundColor('#6B14100A').accessibilityText('更多帖子操作')
      .onClick((): void => { this.actionMenuVisible = !this.actionMenuVisible; });
    }
    .width('100%').padding({ left: 12, right: 12, top: 8 + this.topInset() }).position({ x: 0, y: 0 })
    .hitTestBehavior(HitTestMode.Transparent);
  }

  // 详情内容卡片。
  @Builder
  private detailSheet() {
    Column({ space: 14 }) {
      this.authorHeader();
      this.productInfo();
      if (this.knockShareEnabled) { this.knockShareNotice(); }
      this.reviewSection();
    }
    .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 44 })
    .offset({ y: -24 }).backgroundColor(pageColor(this.palette, 'canvas'))
    .borderRadius({ topLeft: 24, topRight: 24 });
  }

  // 互动按钮行。
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
        CardInteractionButton({ icon: 'like', label: '赞 ' + this.likeCount, selected: this.myReaction === 'LIKE',
          ready: !this.reactionBusy && !this.gateChecking && (!this.loggedIn || this.interactionsKnown),
          palette: this.palette, reducedMotion: this.reducedMotion,
          onActivate: (): void => { this.react('LIKE'); } }).layoutWeight(1);
        CardInteractionButton({ icon: 'dislike', label: '不推荐 ' + this.dislikeCount, selected: this.myReaction === 'DISLIKE',
          ready: !this.reactionBusy && !this.gateChecking && (!this.loggedIn || this.interactionsKnown),
          palette: this.palette, reducedMotion: this.reducedMotion,
          onActivate: (): void => { this.react('DISLIKE'); } }).layoutWeight(1);
        CardInteractionButton({ icon: 'favorite', label: '收藏 ' + this.favoriteCount, selected: this.viewerFavorited,
          ready: !this.collectionBusy && !this.preparingCollection && (!this.loggedIn || this.interactionsKnown),
          palette: this.palette, reducedMotion: this.reducedMotion,
          onActivate: (): void => { this.favorite(); } }).layoutWeight(1);
        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.paperplane')).fontSize(16)
              .fontColor([pageColor(this.palette, 'canvas')]).accessibilityLevel('no');
            Text('发给好友').fontSize(14).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'canvas'));
          }
        }
        .layoutWeight(1.4).height(44).backgroundColor(pageColor(this.palette, 'action'))
        .enabled(this.detailReady).opacity(this.detailReady ? 1 : 0.6)
        .accessibilityText('发给好友').onClick((): void => { this.shareToFriend(); });
      }.width('100%').alignItems(VerticalAlign.Center);
    }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(pageColor(this.palette, 'surface'))
      .border({ width: { top: 1.2 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
  }
  // 标题区。
  @Builder
  private detailHeading(): void {
    Row({ space: 12 }) {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(24).fontColor([pageColor(this.palette, 'ink')]); }
        .width(48).height(48).padding(0).backgroundColor(Color.Transparent).accessibilityText('返回上一页')
        .onClick((): void => { this.pathStack.pop(); });
      Text('美食笔记').fontSize(18).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
    }.width('100%').padding({ left: 8, right: 16, top: 4, bottom: 4 });
  }
  // 点评区。
  @Builder
  private reviewSection() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 6 }) {
        Text('发布者点评').fontSize(12).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'muted')).width('100%');
        Text(this.reviewText()).fontSize(15).lineHeight(24).fontColor(pageColor(this.palette, 'ink')).width('100%');
      }
      .width('100%').padding({ left: 14, right: this.scoreStampVisible() ? 60 : 14, top: 14, bottom: 14 })
      .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(18)
      .border({ width: 1.2, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
      if (this.scoreStampVisible()) {
        Column() {
          Text(String(this.card.tasteScore)).fontSize(16).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action'));
          Text(tasteScoreLabel(this.card.tasteScore)).fontSize(9).fontColor(pageColor(this.palette, 'action'));
        }
        .width(46).height(46).borderRadius(23).justifyContent(FlexAlign.Center)
        .backgroundColor(pageColor(this.palette, 'canvas'))
        .border({ width: 1.6, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed })
        .rotate({ angle: -8 }).offset({ x: -12, y: -14 })
        .accessibilityText('口味 ' + this.tasteScoreText());
      }
    }.width('100%').margin({ top: 8 });
  }

  // 是否显示评分印章。
  private scoreStampVisible(): boolean {
    const score: number = typeof this.card.tasteScore === 'number' ? this.card.tasteScore : 0;
    return Number.isInteger(score) && score >= 1 && score <= 10;
  }

  // 商品信息列表项。
  private infoItems(): Array<DetailInfoItem> {
    const items: Array<DetailInfoItem> = [];
    const shop: string = this.card.merchantNameSnapshot || this.card.shop;
    if (shop.trim().length > 0) items.push({ kind: 'store', label: '店铺', value: shop });
    const place: string = this.card.merchantAddressSnapshot || this.card.district;
    if (place.trim().length > 0) items.push({ kind: 'place', label: '地点', value: place });
    if (this.card.consumptionMode === 'DINE_IN' && this.card.itemPriceFen !== undefined) {
      items.push({ kind: 'price', label: '单品价格', value: '¥' + formatFenInput(this.card.itemPriceFen) });
    }
    if (this.card.deliveryPlatformLabelSnapshot !== undefined && this.card.deliveryPlatformLabelSnapshot.length > 0) {
      items.push({ kind: 'platform', label: '外卖平台', value: this.card.deliveryPlatformLabelSnapshot });
    }
    if (this.card.specification.trim().length > 0) items.push({ kind: 'spec', label: '规格', value: this.card.specification });
    if (this.card.publicOffers.length > 0) items.push({ kind: 'offer', label: '优惠', value: this.card.publicOffers.join('；') });
    if (this.card.edited === true) items.push({ kind: 'edited', label: '内容状态', value: '已编辑' });
    return items;
  }

  // 信息行边框。
  private infoBorder(last: boolean): BorderOptions {
    if (last) {
      const none: BorderOptions = { width: 0 };
      return none;
    }
    const dashed: BorderOptions = { width: { bottom: 1.2 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed };
    return dashed;
  }

  // 信息行图标。
  @Builder
  private infoIcon(kind: string) {
    if (kind === 'store') {
      SymbolGlyph($r('sys.symbol.house')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    } else if (kind === 'place') {
      SymbolGlyph($r('sys.symbol.map')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    } else if (kind === 'price') {
      SymbolGlyph($r('sys.symbol.bag')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    } else if (kind === 'platform') {
      SymbolGlyph($r('sys.symbol.phone')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    } else if (kind === 'spec') {
      SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    } else if (kind === 'offer') {
      SymbolGlyph($r('sys.symbol.info_circle')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    } else {
      SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
    }
  }

  // 一行商品信息。
  @Builder
  private infoRow(item: DetailInfoItem, last: boolean) {
    Row({ space: 10 }) {
      Stack() { this.infoIcon(item.kind); }
        .width(28).height(28).borderRadius(9).backgroundColor(pageColor(this.palette, 'soft'));
      Text(item.label).fontSize(13).fontColor(pageColor(this.palette, 'muted')).width(56);
      Text(item.value.length > 0 ? item.value : '待补充').fontSize(14).fontColor(pageColor(this.palette, 'ink'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
    }.width('100%').padding({ top: 10, bottom: 10 }).alignItems(VerticalAlign.Center).border(this.infoBorder(last));
  }

  // 胶囊按钮。
  @Builder
  private pillAction(label: string, icon: Resource, onTap: () => void) {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Row({ space: 4 }) {
        SymbolGlyph(icon).fontSize(14).fontColor([pageColor(this.palette, 'action')]).accessibilityLevel('no');
        Text(label).fontSize(12.5).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action'));
      }
    }
    .height(36).padding({ left: 12, right: 12 }).margin({ right: 8, bottom: 8 }).backgroundColor(Color.Transparent)
    .border({ width: 1.2, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed })
    .accessibilityText(label).onClick(onTap);
  }

  // 商品信息区。
  @Builder
  private productInfo(): void {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text(this.card.productName).fontSize(23).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
          .layoutWeight(1).maxLines(3);
        Text(this.priceText()).fontSize(21).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action'));
      }.width('100%').alignItems(VerticalAlign.Bottom);
      Row({ space: 6 }) {
        Text(this.card.categoryV2 === undefined ? categoryLabel(this.card.category) : categoryV2Label(this.card.categoryV2))
          .fontSize(12).fontColor(pageColor(this.palette, 'action')).height(26).padding({ left: 10, right: 10 })
          .backgroundColor(pageColor(this.palette, 'soft')).borderRadius(13);
        Text(this.card.consumptionMode === 'DELIVERY' ? '外卖' : this.card.consumptionMode === 'DINE_IN' ? '到店' : '美食推荐')
          .fontSize(12).fontColor(pageColor(this.palette, 'muted')).height(26).padding({ left: 10, right: 10 })
          .borderRadius(13).border({ width: 1, color: pageColor(this.palette, 'line') });
      }.width('100%');
      if (this.infoItems().length > 0) {
        Column() {
          ForEach(this.infoItems(), (item: DetailInfoItem, index: number): void => {
            this.infoRow(item, index === this.infoItems().length - 1);
          }, (item: DetailInfoItem): string => item.kind + ':' + item.value);
        }
        .width('100%').padding({ left: 14, right: 14, top: 2, bottom: 2 }).borderRadius(18)
        .backgroundColor(pageColor(this.palette, 'surface')).border({ width: 1, color: pageColor(this.palette, 'line') });
      }
      if ((this.card.consumptionMode === 'DINE_IN' && this.card.merchantId !== undefined && this.card.merchantId.length > 0) ||
        this.navigationAddress.length > 0 || isSafeHttpsSourceLink(this.card.sourceLink)) {
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.card.consumptionMode === 'DINE_IN' && this.card.merchantId !== undefined && this.card.merchantId.length > 0) {
            this.pillAction('去这里 · 导航', $r('sys.symbol.location_north_up_right'), (): void => { void this.navigateMerchant(); });
          }
          if (this.navigationAddress.length > 0) {
            this.pillAction('复制地址', $r('sys.symbol.list_bullet'), (): void => { void this.copyNavigationAddress(); });
          }
          if (isSafeHttpsSourceLink(this.card.sourceLink)) {
            this.pillAction('来源页面', $r('sys.symbol.link'), (): void => { void this.openSource(); });
          }
        }.width('100%');
      }
    }.width('100%');
  }

  // 当前登录用户 uid（判断是否为作者）。
  private editorUid(): string { const profile = AuthService.profile(); return profile === undefined ? '' : profile.uid; }

  // 页面布局。
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
            if (!this.detailReady) {
              this.detailHeading();
              Column({ space: 16 }) {
                if (this.entryCoverUrl.length > 0) { Image(this.entryCoverUrl).width('100%').height(this.imageHeight()).objectFit(ImageFit.Contain).borderRadius(22).accessibilityText('商品实拍封面'); }
                if (this.status.length === 0) {
                  StateView({ kind: 'LOADING', palette: this.palette, title: '正在打开美食笔记…',
                    skeletonRows: this.entryCoverUrl.length > 0 ? 0 : 2 });
                  Button('重新读取').fontSize(13).backgroundColor(Color.Transparent).fontColor(pageColor(this.palette, 'action'))
                    .onClick((): void => { void this.loadDetail(); });
                } else {
                  StateView({ kind: 'ERROR', palette: this.palette, icon: 'offline', title: '暂时打不开这篇笔记',
                    hint: this.status, actionLabel: '重新读取', onAction: (): void => { void this.loadDetail(); } });
                }
              }.width('100%').layoutWeight(1).padding(20).justifyContent(FlexAlign.Center);
            } else if (this.isWideDetail()) {
              this.detailHeading();
              Scroll(this.detailScroller) {
                Column({ space: 16 }) {
                  this.authorHeader();
                  Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Start }) {
                    Column({ space: 10 }) {
                      this.photoCarousel();
                      if (this.knockShareEnabled) { this.knockShareNotice(); }
                    }.width(this.detailColumnWidth()).flexShrink(0).margin({ right: 24 });
                    Column({ space: 16 }) { this.productInfo(); this.reviewSection(); }
                      .width(this.detailColumnWidth()).flexShrink(0).alignItems(HorizontalAlign.Start);
                  }.width('100%');
                }.width('100%').padding({ left: this.detailPadding(), right: this.detailPadding(), top: 4, bottom: 20 });
              }.width('100%').layoutWeight(1).scrollBar(BarState.Off);
              this.cardActions();
            } else {
              Scroll(this.detailScroller) {
                Column() {
                  this.hero();
                  this.detailSheet();
                }.width('100%');
              }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
                .onDidScroll((): void => this.onHeroScroll());
              this.cardActions();
            }
          }.width('100%').height('100%');
          if (this.detailReady && !this.isWideDetail()) { this.floatingTopBar(); }
          if (this.photoPreviewVisible) { this.photoPreview(); }
          else if (this.actionMenuVisible) {
            Column() {}.width('100%').height('100%').backgroundColor($r('app.color.scrim')).onClick((): void => this.dismissOverlay());
            this.actionMenu();
          }
          if (this.statusStripVisible()) {
            // 大图滚走或预览打开时，状态栏区域显示页面顶部色。
            Column().width('100%').height(this.topInset()).backgroundColor(pageColor(this.palette, 'header'))
              .position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
          }
        }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas'))
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            const height: number = Number(newArea.height); const width: number = Number(newArea.width);
            if (Number.isFinite(height) && height > 0) this.detailHeightVp = height;
            if (Number.isFinite(width) && width > 0 && this.detailWidthVp !== width) this.detailWidthVp = width;
          });
      }
    }.hideTitleBar(!this.editingVisible).attributeModifier(new AppDestinationStyle(this.editingVisible ? '编辑推荐' : '', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette, this.heroLayout()))
      .onShown((): void => {
        this.reducedMotion = this.motionObserver.start();
        if (!this.detailVisible) { this.detailVisible = true; if (this.appActive) void this.loadDetail(); }
        this.syncEdgeImage();
      })
      .onHidden((): void => {
        AppPageSurface.setImmersiveTop(this.edgeOwner, false);
        this.motionObserver.stop(); this.reducedMotion = true;
        this.savedScrollY = this.detailScroller.currentOffset().yOffset;
        if (this.restoreTimer !== -1) { clearTimeout(this.restoreTimer); this.restoreTimer = -1; }
        this.detailVisible = false; ImageRepository.subscriptionsChanged(); ReadScheduler.subscriptionsChanged();
        this.detailGeneration++; this.clearDetailView();
      });
  }
}
