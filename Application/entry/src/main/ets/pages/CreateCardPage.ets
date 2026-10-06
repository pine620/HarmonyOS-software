import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { CardEditContextResponse, CardPhoto, CardRevisionChanges, CardRevisionView, FoodCard, FoodCategory,
  FoodCategoryV2, FoodConsumptionMode, FoodVisibility, PrepareCardPhotoRequest, PublishCardRequest,
  SetCardVisibilityRequest, SubmitCardRevisionRequest } from '../model/CloudContracts';
import { CreateUserMerchantRequest, DeliveryPlatform, Merchant, MerchantChoice, ResolveMerchantRequest,
  UpdateUserMerchantRequest } from '../model/MerchantModels';
import { CATEGORY_V2_OPTIONS, CategoryV2Option, categoryV2FromLegacy, categoryV2Label, formatFenInput,
  legacyCategoryFor, parseYuanInputToFen } from '../model/PublishingModels';
import { CardRepository } from '../repository/CardRepository';
import { CardEditRepository } from '../repository/CardEditRepository';
import { MerchantRepository } from '../repository/MerchantRepository';
import { ImagePreparationService, PreparedPhoto } from '../service/ImagePreparationService';
import { MerchantLocationPicker } from '../service/MerchantLocationPicker';
import { DeliveryPlatformConfigService } from '../service/DeliveryPlatformConfigService';
import { CloudBusinessError, MediaServiceUnavailableError } from '../service/CloudGateway';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { PublishVisibilityStore } from '../service/PublishVisibilityStore';
import { ModeFieldCache, ModeFields } from '../service/ModeFieldCache';
import { AuthService } from '../service/AuthService';
import { isSafeHttpsSourceLink } from '../service/SafeSourceLink';
import { coverFor } from '../components/FoodCover';
import { tasteScoreLabel, tasteScoreReason } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';

interface LabelOption { value: string; }
interface RetainedPhoto { id: string; url: string; }
const FIRST_SCORE_ROW: Array<number> = [1, 2, 3, 4, 5];
const SECOND_SCORE_ROW: Array<number> = [6, 7, 8, 9, 10];
const MAX_CARD_PHOTOS: number = 6;

function dateInput(value: number | null | undefined): string {
  if (value === undefined || value === null) return '';
  const date: Date = new Date(value);
  return date.getUTCFullYear().toString() + '-' + (date.getUTCMonth() + 1).toString().padStart(2, '0') + '-' +
    date.getUTCDate().toString().padStart(2, '0');
}
function consumedMillis(value: string): number | null {
  const input: string = value.trim();
  if (input.length === 0) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input)) throw new Error('购买日期请填写 YYYY-MM-DD。');
  const parts: Array<string> = input.split('-');
  const stamp: number = Date.UTC(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  if (dateInput(stamp) !== input || stamp < 0 || stamp > Date.now() + 86400000) throw new Error('购买日期无效。');
  return stamp;
}

@Component
export struct CreateCardPage {
  onPublished: () => void = (): void => {};
  onEditingFinished: () => void = (): void => {};
  @Prop editCardId: string = '';
  @Prop @Watch('onAccountChanged') accountUid: string = '';
  @State productName: string = '';
  @State price: string = '';
  @State dineInAvg: string = '';
  @State orderTotal: string = '';
  @State deliveryFee: string = '';
  @State consumedDate: string = '';
  @State sourceLink: string = '';
  @State reviewText: string = '';
  @State tasteScore: number = 9;
  @State category: FoodCategory = 'staple';
  @State categoryV2: FoodCategoryV2 = 'RICE_SET';
  @State mode: FoodConsumptionMode = 'DELIVERY';
  @State cardVisibility: FoodVisibility = 'PUBLIC';
  @State friendsEnabled: boolean = false;
  @State merchant: Merchant | undefined = undefined;
  @State merchantChoice: MerchantChoice | undefined = undefined;
  @State merchantName: string = '';
  @State merchantAddress: string = '';
  @State merchantBusy: boolean = false;
  @State merchantRequestUnconfirmed: boolean = false;
  @State correctingMerchant: boolean = false;
  @State platforms: Array<DeliveryPlatform> = DeliveryPlatformConfigService.defaults();
  @State platformKey: string = '';
  @State platformLabel: string = '';
  @State moreDeliveryInfo: boolean = false;
  @State photoLabel: string = '';
  @State photoPreviewUris: Array<string> = [];
  @State retainedPhotos: Array<RetainedPhoto> = [];
  @State ownsPhoto: boolean = false;
  @State publishing: boolean = false;
  @State initializing: boolean = true;
  @State editContextReady: boolean = false;
  @State requestUnconfirmed: boolean = false;
  @State hasPublishedNotice: boolean = false;
  @State currentRevision: CardRevisionView | undefined = undefined;
  @State status: string = '填写美食信息，留下你的真实口碑。';
  private repository: CardRepository = new CardRepository();
  private editRepository: CardEditRepository = new CardEditRepository();
  private merchantRepository: MerchantRepository = new MerchantRepository();
  private preparedPhotos: Array<PreparedPhoto> = [];
  private uploadedMediaIds: Array<string> = [];
  private formGeneration: number = 0;
  private publicationRequestId: string = '';
  private merchantRequestId: string = '';
  private pendingMerchantRequest: CreateUserMerchantRequest | undefined = undefined;
  private pendingPublication: PublishCardRequest | undefined = undefined;
  private pendingRevision: SubmitCardRevisionRequest | undefined = undefined;
  private baseCard: FoodCard | undefined = undefined;
  private historicalShop: string = '';
  private activeUid: string = '';
  private modeCacheAt: number = Date.now();
  private providerEnabled: boolean = false;
  private successMerchant: Merchant | undefined = undefined;
  private successMode: FoodConsumptionMode = 'DELIVERY';
  private successVisibility: FoodVisibility = 'PUBLIC';

  aboutToAppear(): void { void this.initialize(); }
  aboutToDisappear(): void { this.formGeneration++; this.saveModeFields(); this.publishing = false; this.merchantBusy = false; }
  private onAccountChanged(): void { this.formGeneration++; MerchantLocationPicker.clearSelectionCenter(); this.successMerchant = undefined; this.resetForm(); void this.initialize(); }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private stillCurrent(generation: number): boolean {
    const profile = AuthService.profile();
    return generation === this.formGeneration && profile !== undefined && profile.uid === this.activeUid;
  }
  private isEditing(): boolean { return this.editCardId.length > 0; }
  private formEnabled(): boolean { return (!this.isEditing() || this.editContextReady) && !this.initializing && !this.publishing && !this.merchantBusy && !this.requestUnconfirmed && !this.merchantRequestUnconfirmed; }
  private scoreLabel(score: number = this.tasteScore): string { return tasteScoreLabel(score); }
  private scoreReason(score: number = this.tasteScore): string { return tasteScoreReason(score); }
  private isScoreSelected(score: number): boolean { return this.tasteScore === score; }
  private resetPublicationState(): void { this.hasPublishedNotice = false; }
  private resetForm(): void {
    this.formGeneration++; this.publicationRequestId = ''; this.pendingPublication = undefined; this.pendingRevision = undefined;
    this.publishing = false; this.merchantBusy = false; this.merchantRequestUnconfirmed = false;
    this.requestUnconfirmed = false; this.preparedPhotos = []; this.uploadedMediaIds = []; this.retainedPhotos = [];
    this.productName = ''; this.price = ''; this.dineInAvg = ''; this.orderTotal = ''; this.deliveryFee = ''; this.consumedDate = '';
    this.sourceLink = ''; this.reviewText = ''; this.tasteScore = 9; this.category = 'staple'; this.categoryV2 = 'RICE_SET';
    this.merchant = undefined; this.merchantChoice = undefined; this.pendingMerchantRequest = undefined;
    this.merchantRequestId = ''; this.merchantName = ''; this.merchantAddress = ''; this.correctingMerchant = false;
    this.platformKey = ''; this.platformLabel = ''; this.photoPreviewUris = []; this.photoLabel = ''; this.ownsPhoto = false;
    this.currentRevision = undefined; this.baseCard = undefined; this.editContextReady = false; this.historicalShop = ''; this.hasPublishedNotice = false;
    this.status = '填写美食信息，留下你的真实口碑。'; this.modeCacheAt = Date.now();
  }
  private async initialize(): Promise<void> {
    this.initializing = true;
    const generation: number = ++this.formGeneration;
    const profile = AuthService.profile();
    this.activeUid = profile === undefined ? '' : profile.uid;
    try {
      const caps = await this.merchantRepository.capabilities(this.context());
      if (!this.stillCurrent(generation)) return;
      this.friendsEnabled = caps.friendsPublishEnabled; this.providerEnabled = caps.providerVerificationEnabled;
      if (this.isEditing()) await this.loadEditContext(generation);
      else {
        this.cardVisibility = PublishVisibilityStore.read(this.context(), this.activeUid);
        if (!this.friendsEnabled) this.cardVisibility = 'PUBLIC';
      }
      const platforms: Array<DeliveryPlatform> = await DeliveryPlatformConfigService.load();
      if (!this.stillCurrent(generation)) return;
      this.platforms = platforms;
    } catch (error) {
      if (this.stillCurrent(generation)) this.status = '加载失败：' + errorText(error as ErrorDetail);
    } finally { if (this.stillCurrent(generation)) this.initializing = false; }
  }
  private async loadEditContext(generation: number): Promise<void> {
    this.editContextReady = false;
    const response: CardEditContextResponse = await this.editRepository.context(this.context(), this.editCardId);
    if (!this.stillCurrent(generation)) return;
    const card: FoodCard = response.card; this.baseCard = card;
    const revision: CardRevisionView | null = response.revision;
    const reusable: boolean = revision !== null && (revision.status === 'PENDING' || revision.status === 'REJECTED') &&
      revision.baseModifiedAt === card.modifiedAt && revision.baseLifecycleGeneration === card.lifecycleGeneration;
    this.currentRevision = revision === null ? undefined : revision;
    this.productName = card.productName; this.price = formatFenInput(card.itemPriceFen === undefined && card.priceFen > 0 ? card.priceFen : card.itemPriceFen);
    this.dineInAvg = formatFenInput(card.dineInAvgFen); this.orderTotal = formatFenInput(card.orderTotalFen);
    this.deliveryFee = formatFenInput(card.deliveryFeeFen); this.consumedDate = dateInput(card.consumedAt);
    this.sourceLink = card.sourceLink; this.reviewText = card.reviewText; this.tasteScore = card.tasteScore;
    this.mode = card.consumptionMode === undefined ? 'UNSPECIFIED' : card.consumptionMode;
    this.cardVisibility = card.visibility === undefined ? 'PUBLIC' : card.visibility;
    this.categoryV2 = categoryV2FromLegacy(card.category);
    for (const option of CATEGORY_V2_OPTIONS) if (option.key === card.categoryV2) this.categoryV2 = option.key;
    this.platformKey = card.deliveryPlatformKey === undefined ? '' : card.deliveryPlatformKey;
    this.platformLabel = card.deliveryPlatformLabelSnapshot === undefined ? '' : card.deliveryPlatformLabelSnapshot;
    let merchantId: string = card.merchantId === undefined ? '' : card.merchantId;
    this.historicalShop = merchantId.length > 0 ? '' : card.shop;
    const kept: Array<RetainedPhoto> = [];
    if (reusable && revision !== null) {
      const changes: CardRevisionChanges = revision.changes;
      if (changes.productName !== undefined) this.productName = changes.productName;
      if (changes.reviewText !== undefined) this.reviewText = changes.reviewText;
      if (changes.tasteScore !== undefined) this.tasteScore = changes.tasteScore;
      if (changes.categoryV2 !== undefined) this.categoryV2 = changes.categoryV2;
      else if (changes.category !== undefined) this.categoryV2 = categoryV2FromLegacy(changes.category);
      if (changes.consumptionMode !== undefined) this.mode = changes.consumptionMode;
      if (changes.visibility !== undefined) this.cardVisibility = changes.visibility;
      if (changes.merchantId !== undefined) merchantId = changes.merchantId;
      this.price = formatFenInput(changes.itemPriceFen === undefined ?
        changes.priceFen !== undefined && changes.priceFen > 0 ? changes.priceFen : null : changes.itemPriceFen);
      this.dineInAvg = formatFenInput(changes.dineInAvgFen);
      this.orderTotal = formatFenInput(changes.orderTotalFen); this.deliveryFee = formatFenInput(changes.deliveryFeeFen);
      this.consumedDate = dateInput(changes.consumedAt);
      if (changes.sourceLink !== undefined) this.sourceLink = changes.sourceLink;
      this.platformKey = changes.deliveryPlatformKey === undefined ? '' : changes.deliveryPlatformKey;
      this.platformLabel = changes.deliveryPlatformLabelSnapshot === undefined ? '' : changes.deliveryPlatformLabelSnapshot;
      for (const id of revision.mediaIds) {
        let uri: string = '';
        try { uri = await PhotoUploadService.getRevisionDownloadUrl(this.context(), revision.revisionId, id); } catch (_error) { }
        if (!this.stillCurrent(generation)) return;
        const photo: RetainedPhoto = { id, url: uri }; kept.push(photo);
      }
      this.status = revision.status === 'PENDING' ? '已载入待审版本；提交会替换旧待审版本，公开展示仍是旧版。' :
        '编辑被退回：' + revision.reviewReason + '。修改后可重新提交。';
    } else {
      const photos: Array<CardPhoto> = card.photos === undefined ? [] : card.photos;
      for (const photo of photos) {
        let uri: string = '';
        try { uri = await this.repository.hydrateDetailPhoto(this.context(), photo); } catch (_error) { }
        if (!this.stillCurrent(generation)) return;
        const retained: RetainedPhoto = { id: photo.id, url: uri }; if (photo.id.length > 0) kept.push(retained);
      }
      this.status = revision !== null ? '旧编辑已结束或基准变化，已载入当前版本；请重新检查后提交。' : '编辑提交后待审，当前展示保持旧版本。';
    }
    this.category = legacyCategoryFor(this.categoryV2); this.retainedPhotos = kept; this.ownsPhoto = kept.length > 0;
    if (merchantId.length > 0) {
      const result = await this.merchantRepository.get(this.context(), merchantId);
      if (this.stillCurrent(generation)) this.merchant = result.merchant;
    } else this.merchant = undefined;
    if (this.stillCurrent(generation)) this.editContextReady = true;
  }
  private saveModeFields(): void {
    if (this.activeUid.length === 0 || this.initializing || (this.isEditing() && !this.editContextReady)) return;
    const fields: ModeFields = { savedAt: Date.now(), dineInAvg: this.dineInAvg, orderTotal: this.orderTotal,
      deliveryFee: this.deliveryFee, platformKey: this.platformKey, platformLabel: this.platformLabel, consumedDate: this.consumedDate };
    try { ModeFieldCache.save(this.context(), this.activeUid, this.editCardId, fields, this.mode); this.modeCacheAt = fields.savedAt; } catch (_error) { }
  }
  private selectMode(mode: FoodConsumptionMode): void {
    if (!this.formEnabled() || this.mode === mode) return;
    this.saveModeFields();
    let stored: ModeFields | undefined = undefined;
    try { stored = ModeFieldCache.read(this.context(), this.activeUid, this.editCardId); } catch (_error) { }
    if (mode === 'DINE_IN') this.dineInAvg = stored === undefined ? '' : stored.dineInAvg;
    if (mode === 'DELIVERY') {
      if (stored !== undefined) {
        this.orderTotal = stored.orderTotal; this.deliveryFee = stored.deliveryFee; this.platformKey = stored.platformKey;
        this.platformLabel = stored.platformLabel; this.consumedDate = stored.consumedDate;
      } else { this.orderTotal = ''; this.deliveryFee = ''; this.platformKey = ''; this.platformLabel = ''; this.consumedDate = ''; }
    }
    this.mode = mode; this.resetPublicationState();
  }
  private async chooseMerchant(): Promise<void> {
    if (!this.formEnabled()) return;
    const correcting: boolean = this.correctingMerchant;
    this.merchantBusy = true; const generation: number = this.formGeneration;
    try {
      const choice: MerchantChoice | undefined = await MerchantLocationPicker.choose(this.context(), this.merchant);
      if (!this.stillCurrent(generation)) return;
      if (choice === undefined) { this.status = '已取消选点，保留原店铺。'; return; }
      this.merchantChoice = choice; this.merchantName = choice.name; this.merchantAddress = choice.address;
      this.pendingMerchantRequest = undefined; this.merchantRequestId = ''; this.correctingMerchant = correcting;
      this.status = choice.providerPoiId.length > 0 ? '确认关联此官方地点，或填写名称创建用户确认地点。' : '普通地图点没有官方 POI 标识，请填写店名后创建待审地点。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.merchantBusy = false; }
  }
  private correctMerchant(): void {
    const merchant: Merchant | undefined = this.merchant;
    if (merchant === undefined) return;
    const choice: MerchantChoice = { providerPoiId: '', name: merchant.name, address: merchant.address,
      latitudeE6: merchant.latitudeE6, longitudeE6: merchant.longitudeE6 };
    this.merchantChoice = choice; this.merchantName = merchant.name; this.merchantAddress = merchant.address;
    this.correctingMerchant = true; this.merchantRequestId = util.generateRandomUUID(); this.pendingMerchantRequest = undefined;
  }
  private async confirmMerchant(provider: boolean): Promise<void> {
    const choice: MerchantChoice | undefined = this.merchantChoice;
    if (choice === undefined || this.merchantBusy) return;
    this.merchantBusy = true; const generation: number = this.formGeneration;
    try {
      let selected: Merchant;
      if (provider) {
        const request: ResolveMerchantRequest = { provider: 'HUAWEI_MAP', providerPoiId: choice.providerPoiId };
        selected = (await this.merchantRepository.resolve(this.context(), request)).merchant;
      } else {
        if (this.merchantName.trim().length === 0) throw new Error('请补充店名。');
        if (this.merchantRequestId.length === 0) this.merchantRequestId = util.generateRandomUUID();
        const pending = this.pendingMerchantRequest;
        const request: CreateUserMerchantRequest = pending === undefined ? { requestId: this.merchantRequestId,
          name: this.merchantName.trim(), address: this.merchantAddress.trim(), latitudeE6: choice.latitudeE6, longitudeE6: choice.longitudeE6 } : pending;
        this.pendingMerchantRequest = request; this.merchantRequestUnconfirmed = true;
        const merchant: Merchant | undefined = this.merchant;
        if (this.correctingMerchant && merchant !== undefined) {
          const update: UpdateUserMerchantRequest = { requestId: request.requestId, name: request.name, address: request.address,
            latitudeE6: request.latitudeE6, longitudeE6: request.longitudeE6, merchantId: merchant.merchantId, expectedUpdatedAt: merchant.updatedAt };
          selected = (await this.merchantRepository.update(this.context(), update)).merchant;
        } else selected = (await this.merchantRepository.create(this.context(), request)).merchant;
      }
      if (!this.stillCurrent(generation)) return;
      this.merchant = selected; this.merchantChoice = undefined; this.historicalShop = ''; this.pendingMerchantRequest = undefined; this.merchantRequestUnconfirmed = false;
      this.status = selected.verificationStatus === 'USER_CONFIRMED_PENDING' ? '待审地点已关联；你可以发布，审核前不进入地图和距离功能。' :
        selected.coordinateSystem === 'UNKNOWN' ? '已关联官方地点；坐标系验证完成前不进入地图和距离功能。' : '店铺已关联。';
    } catch (error) {
      if (this.stillCurrent(generation)) {
        if (error instanceof CloudBusinessError && ['CONFLICT', 'VALIDATION_ERROR', 'FORBIDDEN', 'ACCOUNT_INACTIVE'].includes(error.code)) {
          this.merchantRequestUnconfirmed = false; this.pendingMerchantRequest = undefined; this.merchantRequestId = '';
        }
        this.status = errorText(error as ErrorDetail) + (this.merchantRequestUnconfirmed ? '；请重试原地点请求。' : '');
      }
    } finally { if (this.stillCurrent(generation)) this.merchantBusy = false; }
  }
  private async chooseOwnedPhoto(): Promise<void> {
    if (!this.formEnabled()) return;
    const generation: number = this.formGeneration;
    this.publishing = true;
    try {
      const uris: Array<string> = await ImagePreparationService.selectMany(MAX_CARD_PHOTOS - this.retainedPhotos.length);
      if (!this.stillCurrent(generation) || uris.length === 0) return;
      this.publishing = true; this.status = '正在本地处理实拍图…';
      const photos: Array<PreparedPhoto> = [];
      for (const uri of uris) {
        const photo: PreparedPhoto = await ImagePreparationService.prepareOwnedPhoto(uri);
        if (!this.stillCurrent(generation)) return; photos.push(photo);
      }
      this.preparedPhotos = photos; this.uploadedMediaIds = []; this.photoPreviewUris = uris; this.ownsPhoto = false;
      this.photoLabel = '已处理 ' + photos.length + ' 张 JPEG；勾选权利声明后上传。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.publishing = false; }
  }
  private formChanges(): CardRevisionChanges {
    const item: number | null = parseYuanInputToFen(this.price);
    const changes: CardRevisionChanges = { productName: this.productName.trim(), priceFen: item === null ? 0 : item,
      reviewText: this.reviewText.trim(), tasteScore: this.tasteScore, sourceLink: this.sourceLink.trim(),
      category: legacyCategoryFor(this.categoryV2), categoryV2: this.categoryV2, consumptionMode: this.mode, visibility: this.cardVisibility,
      merchantId: this.merchant === undefined ? '' : this.merchant.merchantId, itemPriceFen: item,
      dineInAvgFen: this.mode === 'DINE_IN' ? parseYuanInputToFen(this.dineInAvg) : null,
      orderTotalFen: this.mode === 'DELIVERY' ? parseYuanInputToFen(this.orderTotal) : null,
      deliveryFeeFen: this.mode === 'DELIVERY' ? parseYuanInputToFen(this.deliveryFee) : null,
      deliveryPlatformKey: this.mode === 'DELIVERY' ? this.platformKey : '',
      deliveryPlatformLabelSnapshot: this.mode === 'DELIVERY' ? this.platformLabel : '',
      consumedAt: this.mode === 'DELIVERY' ? consumedMillis(this.consumedDate) : null, shop: this.historicalShop };
    return changes;
  }
  private publishBlocker(): string {
    if (this.productName.trim().length < 2 || this.productName.trim().length > 100) return '美食名称需为 2–100 字。';
    if (!this.isEditing() && this.mode === 'UNSPECIFIED') return '请选择外卖或到店。';
    if (this.reviewText.trim().length > 600) return '点评最多 600 字。';
    if (this.tasteScore < 1 || this.tasteScore > 10) return '请选择 1–10 分。';
    if (this.cardVisibility === 'FRIENDS' && !this.friendsEnabled && (!this.baseCard || this.baseCard.visibility !== 'FRIENDS')) return '好友发布尚未开放。';
    if (this.sourceLink.trim().length > 0 && !isSafeHttpsSourceLink(this.sourceLink)) return '来源链接需为有效的 HTTPS 地址，不含内嵌账号信息。';
    if (this.retainedPhotos.length + this.preparedPhotos.length < 1) return '请至少添加一张实拍图。';
    if (this.retainedPhotos.length + this.preparedPhotos.length > MAX_CARD_PHOTOS) return '最多六张实拍图。';
    if (!this.ownsPhoto) return '请确认照片拍摄或使用权。';
    if (this.merchantChoice !== undefined) return '请先确认店铺，或取消本次选点。';
    if (this.merchant !== undefined && this.merchant.verificationStatus === 'REJECTED') return '店铺已被拒绝，请更换或修正待审地点。';
    try { this.formChanges(); } catch (error) { return errorText(error as ErrorDetail); }
    return '';
  }
  private async uploadPhotos(generation: number): Promise<Array<string>> {
    const ids: Array<string> = this.retainedPhotos.map((photo: RetainedPhoto): string => photo.id);
    for (let index: number = 0; index < this.preparedPhotos.length; index++) {
      if (!this.stillCurrent(generation)) throw new Error('账号或表单已变化。');
      if (this.uploadedMediaIds[index] !== undefined) { ids.push(this.uploadedMediaIds[index]); continue; }
      const photo: PreparedPhoto = this.preparedPhotos[index];
      const request: PrepareCardPhotoRequest = { mimeType: photo.mimeType, byteSize: photo.byteSize,
        sha256: photo.sha256, width: photo.width, height: photo.height };
      this.status = '正在上传实拍图 ' + (index + 1) + '/' + this.preparedPhotos.length + '…';
      const prepared = await this.repository.preparePhoto(this.context(), request);
      if (!this.stillCurrent(generation)) throw new Error('账号已变化。');
      await PhotoUploadService.upload(this.context(), prepared.bucketName, prepared.cloudPath, photo.data, photo.sha256);
      if (!this.stillCurrent(generation)) throw new Error('账号已变化。');
      this.uploadedMediaIds.push(prepared.mediaId); ids.push(prepared.mediaId);
    }
    return ids;
  }
  private async publish(): Promise<void> {
    if (this.publishing || this.initializing || this.merchantBusy || this.merchantRequestUnconfirmed ||
      (this.isEditing() && !this.editContextReady && !this.requestUnconfirmed)) return;
    if (!this.requestUnconfirmed) { const blocker: string = this.publishBlocker(); if (blocker.length > 0) { this.status = blocker; return; } }
    const generation: number = this.formGeneration; this.publishing = true;
    try {
      if (this.publicationRequestId.length === 0) this.publicationRequestId = util.generateRandomUUID();
      if (this.isEditing()) {
        let request: SubmitCardRevisionRequest | undefined = this.pendingRevision;
        const card: FoodCard | undefined = this.baseCard;
        if (card === undefined) throw new Error('编辑基准未加载，请刷新。');
        if (request === undefined) {
          const mediaIds: Array<string> = await this.uploadPhotos(generation);
          request = { cardId: card.id, requestId: this.publicationRequestId,
            baseModifiedAt: card.modifiedAt === undefined ? card.createdAt : card.modifiedAt,
            baseLifecycleGeneration: card.lifecycleGeneration === undefined ? 0 : card.lifecycleGeneration,
            changes: this.formChanges(), mediaIds };
          this.pendingRevision = request;
        }
        this.requestUnconfirmed = true;
        const result = await this.editRepository.submit(this.context(), request);
        if (!this.stillCurrent(generation)) return;
        this.pendingRevision = undefined; this.publicationRequestId = ''; this.requestUnconfirmed = false;
        this.currentRevision = result.revision; this.preparedPhotos = []; this.uploadedMediaIds = []; this.photoPreviewUris = [];
        this.initializing = true; await this.loadEditContext(generation); this.initializing = false;
        this.status = result.revision.status === 'PENDING' ? '编辑已提交待审；公开展示仍保持旧版。可继续编辑或撤回。' :
          result.revision.status === 'APPROVED' ? '原编辑已审核通过；已载入当前版本。' :
          result.revision.status === 'REJECTED' ? '原编辑已被退回：' + result.revision.reviewReason :
          '原编辑已撤回或被替换；已读取当前编辑状态。';
      } else {
        let request: PublishCardRequest | undefined = this.pendingPublication;
        if (request === undefined) {
          const mediaIds: Array<string> = await this.uploadPhotos(generation);
          const item: number | null = parseYuanInputToFen(this.price);
          request = { requestId: this.publicationRequestId, productName: this.productName.trim(), brand: '',
            priceFen: item === null ? 0 : item, priceLabel: '', originalPriceFen: 0, specification: '', shop: this.historicalShop,
            sellingPoints: [], publicOffers: [], reviewText: this.reviewText.trim(), tasteScore: this.tasteScore,
            sourceLink: this.sourceLink.trim(), category: this.category, categoryV2: this.categoryV2, consumptionMode: this.mode,
            visibility: this.cardVisibility, merchantId: this.merchant === undefined ? '' : this.merchant.merchantId,
            itemPriceFen: item, dineInAvgFen: this.mode === 'DINE_IN' ? parseYuanInputToFen(this.dineInAvg) : null,
            orderTotalFen: this.mode === 'DELIVERY' ? parseYuanInputToFen(this.orderTotal) : null,
            deliveryFeeFen: this.mode === 'DELIVERY' ? parseYuanInputToFen(this.deliveryFee) : null,
            deliveryPlatformKey: this.mode === 'DELIVERY' ? this.platformKey : '',
            deliveryPlatformLabelSnapshot: this.mode === 'DELIVERY' ? this.platformLabel : '',
            consumedAt: this.mode === 'DELIVERY' ? consumedMillis(this.consumedDate) : null, mediaId: mediaIds[0], mediaIds };
          this.pendingPublication = request;
        }
        this.requestUnconfirmed = true;
        const result = await this.repository.publish(this.context(), request);
        if (!this.stillCurrent(generation)) return;
        if (result.status !== 'APPROVED') throw new Error('发布结果需进一步确认。');
        this.successMerchant = this.merchant; this.successMode = this.mode; this.successVisibility = this.cardVisibility;
        try { PublishVisibilityStore.save(this.context(), this.activeUid, this.cardVisibility); } catch (_error) { }
        try { ModeFieldCache.clear(this.context(), this.activeUid, this.editCardId); } catch (_error) { }
        this.resetForm(); this.hasPublishedNotice = true;
        this.status = '发布成功，已提交后审。可以继续发布同店菜品。'; this.onPublished();
      }
    } catch (error) {
      if (!this.stillCurrent(generation)) return;
      if (error instanceof CloudBusinessError) {
        // A business rejection is a confirmed response. Transport/handler errors
        // remain ambiguous and keep the immutable request for retry.
        const confirmed: Array<string> = ['CONFLICT', 'VALIDATION_ERROR', 'FRIENDS_VALIDATION_REQUIRED', 'NARROWING_REQUIRED',
          'MERCHANT_NOT_VERIFIED', 'ACCOUNT_INACTIVE', 'CONTENT_ACCESS_DENIED', 'COUNTER_RECONCILIATION_REQUIRED'];
        if (confirmed.includes(error.code)) { this.requestUnconfirmed = false; this.pendingRevision = undefined; this.pendingPublication = undefined; this.publicationRequestId = ''; }
        if (error.code === 'CONFLICT' && this.isEditing()) this.editContextReady = false;
      }
      this.status = error instanceof MediaServiceUnavailableError ? '实拍图服务暂时不可用；表单和请求会保留。' :
        errorText(error as ErrorDetail) + (this.requestUnconfirmed ? '；结果未确认，请重试原请求。' : '；表单已保留。');
    } finally {
      if (this.stillCurrent(generation)) { this.publishing = false; this.initializing = false; }
      else if (this.hasPublishedNotice) this.publishing = false;
    }
  }
  private async withdraw(): Promise<void> {
    const revision: CardRevisionView | undefined = this.currentRevision;
    if (revision === undefined || revision.status !== 'PENDING' || !this.formEnabled()) return;
    this.publishing = true; const generation: number = this.formGeneration;
    try {
      await this.editRepository.withdraw(this.context(), revision.revisionId);
      if (!this.stillCurrent(generation)) return;
      await this.loadEditContext(generation); this.status = '已撤回编辑；当前展示保持原版。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.publishing = false; }
  }
  private async narrow(): Promise<void> {
    const card: FoodCard | undefined = this.baseCard;
    if (card === undefined || !this.formEnabled() || !this.friendsEnabled) return;
    this.publishing = true; const generation: number = this.formGeneration;
    try {
      const request: SetCardVisibilityRequest = { cardId: card.id, visibility: 'FRIENDS', expectedModifiedAt: card.modifiedAt };
      await this.editRepository.narrow(this.context(), request);
      if (!this.stillCurrent(generation)) return;
      AppStorage.setOrCreate('contentMutationRevision', (AppStorage.get<number>('contentMutationRevision') || 0) + 1);
      await this.loadEditContext(generation); this.status = '已立即设为仅好友可见；旧编辑不能恢复公开，请在新基准上提交。';
    } catch (error) {
      if (this.stillCurrent(generation)) {
        this.editContextReady = false;
        this.status = errorText(error as ErrorDetail) + '；请读取最新基准以确认可见范围，表单已保留。';
      }
    }
    finally { if (this.stillCurrent(generation)) this.publishing = false; }
  }
  private async reloadEditBasis(): Promise<void> {
    if (this.baseCard === undefined) { await this.initialize(); return; }
    const generation: number = this.formGeneration;
    this.initializing = true;
    try {
      const response: CardEditContextResponse = await this.editRepository.context(this.context(), this.editCardId);
      if (!this.stillCurrent(generation)) return;
      this.baseCard = response.card; this.currentRevision = response.revision === null ? undefined : response.revision;
      this.cardVisibility = response.card.visibility === undefined ? 'PUBLIC' : response.card.visibility;
      this.editContextReady = true;
      this.status = '已读取最新基准并确认当前可见范围；保留了输入和照片，请检查后重新提交。旧图片失效时请重新选择。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.initializing = false; }
  }
  private continueSameMerchant(): void {
    const merchant: Merchant | undefined = this.successMerchant; const mode: FoodConsumptionMode = this.successMode;
    const visibility: FoodVisibility = this.successVisibility;
    this.resetForm(); this.merchant = merchant; this.mode = mode; this.cardVisibility = visibility;
    this.status = '已继承店铺、消费方式和可见范围；请填写新菜品、价格、照片和评分。';
  }
  @Builder
  private fieldLabel(title: string, required: boolean = false): void {
    Row({ space: 6 }) {
      Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'));
      if (required) {
        Text('必填').fontSize(10).fontColor($r('app.color.accent_action'))
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor($r('app.color.accent_soft')).borderRadius(6);
      }
    }.width('100%');
  }

  @Builder
  private scoreButton(score: number): void {
    Button() {
      Column({ space: 2 }) {
        Text(score.toString()).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.isScoreSelected(score) ? $r('app.color.accent_action') : $r('app.color.ink'));
        Text(this.scoreLabel(score)).fontSize(12)
          .fontColor(this.isScoreSelected(score) ? $r('app.color.accent_action') : $r('app.color.muted'));
      }.alignItems(HorizontalAlign.Center);
    }
      .height(56).layoutWeight(1)
      .backgroundColor(this.isScoreSelected(score) ? $r('app.color.accent_soft') : $r('app.color.canvas'))
      .border({ width: this.isScoreSelected(score) ? 1.5 : 1,
        color: this.isScoreSelected(score) ? $r('app.color.accent_action') : $r('app.color.line') })
      .borderRadius(12)
      .accessibilityText(`${score} 分，${this.scoreLabel(score)}${this.isScoreSelected(score) ? '，已选中' : ''}`)
      .onClick((): void => {
        this.tasteScore = score;
        this.resetPublicationState();
      });
  }

  @Builder
  private scoreStage(): void {
    Row({ space: 12 }) {
      Row({ space: 3 }) {
        Text(this.tasteScore.toString()).fontSize(38).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent_action')).lineHeight(42);
        Text('/10').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.muted'))
          .padding({ top: 22 });
      }.alignItems(VerticalAlign.Top);
      Column({ space: 4 }) {
        Text(this.scoreLabel()).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent_action')).width('100%');
        Text(this.scoreReason()).fontSize(12).lineHeight(17)
          .fontColor($r('app.color.ink')).width('100%').maxLines(2);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.accent_soft')).borderRadius(15)
    .accessibilityText(`${this.tasteScore} 分，${this.scoreLabel()}。${this.scoreReason()}`);
  }


  private categoryOptions(): Array<LabelOption> {
    return CATEGORY_V2_OPTIONS.map((option: CategoryV2Option): LabelOption => { return { value: option.label }; });
  }
  private categoryIndex(): number { return CATEGORY_V2_OPTIONS.findIndex((option: CategoryV2Option): boolean => option.key === this.categoryV2); }
  private platformOptions(): Array<DeliveryPlatform> {
    const rows: Array<DeliveryPlatform> = this.platforms.filter((value: DeliveryPlatform): boolean => value.enabled);
    if (this.platformKey.length > 0 && !rows.some((value: DeliveryPlatform): boolean => value.key === this.platformKey)) {
      const retained: DeliveryPlatform = { key: this.platformKey, label: this.platformLabel + '（历史已停用）', enabled: false, sortOrder: 0 };
      rows.unshift(retained);
    }
    const empty: DeliveryPlatform = { key: '', label: '不填写平台', enabled: true, sortOrder: -1 }; rows.unshift(empty); return rows;
  }
  private platformLabels(): Array<LabelOption> {
    return this.platformOptions().map((option: DeliveryPlatform): LabelOption => { return { value: option.label }; });
  }
  @Builder
  private productInfoSection(): void {
    Column({ space: 12 }) {
      Text('商品信息').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      this.fieldLabel('消费方式', true);
      Row({ space: 10 }) {
        Button(this.mode === 'DELIVERY' ? '外卖 · 已选' : '外卖').layoutWeight(1).height(48)
          .backgroundColor(this.mode === 'DELIVERY' ? $r('app.color.accent_soft') : $r('app.color.canvas'))
          .fontColor($r('app.color.ink')).onClick((): void => this.selectMode('DELIVERY'));
        Button(this.mode === 'DINE_IN' ? '到店 · 已选' : '到店').layoutWeight(1).height(48)
          .backgroundColor(this.mode === 'DINE_IN' ? $r('app.color.accent_soft') : $r('app.color.canvas'))
          .fontColor($r('app.color.ink')).onClick((): void => this.selectMode('DINE_IN'));
      }.width('100%');
      if (this.mode === 'UNSPECIFIED') { Text('历史内容尚未区分外卖 / 到店，可在编辑中补充。').fontSize(13).fontColor($r('app.color.muted')); }
      this.fieldLabel('美食名称', true);
      TextInput({ text: this.productName, placeholder: '例如：黑椒鸡排饭' }).height(48).maxLength(100).fontSize(15)
        .backgroundColor($r('app.color.canvas')).borderRadius(12).onChange((value: string): void => { this.productName = value; });
      this.fieldLabel('主分类', true);
      Select(this.categoryOptions()).selected(this.categoryIndex()).height(48).width('100%')
        .backgroundColor($r('app.color.canvas')).onSelect((index: number): void => {
          const option: CategoryV2Option | undefined = CATEGORY_V2_OPTIONS[index];
          if (option !== undefined) { this.categoryV2 = option.key; this.category = legacyCategoryFor(option.key); }
        });
      this.fieldLabel('单品价格（可选）');
      TextInput({ text: this.price, placeholder: '留空表示未知，例如 12.30' }).height(48).fontSize(15).maxLength(12)
        .backgroundColor($r('app.color.canvas')).borderRadius(12).onChange((value: string): void => { this.price = value; });
      if (this.mode === 'DINE_IN') {
        this.fieldLabel('到店人均（可选）');
        TextInput({ text: this.dineInAvg, placeholder: '筛选与排序使用此人均价格' }).height(48).fontSize(15).maxLength(12)
          .backgroundColor($r('app.color.canvas')).borderRadius(12).onChange((value: string): void => { this.dineInAvg = value; });
      }
      Text(this.mode === 'DINE_IN' ? '未填人均时不使用单品价替代。明确填写 0 表示零元。' : '建议填写单品价；留空表示未知，0 表示明确零元。')
        .fontSize(13).lineHeight(19).fontColor($r('app.color.muted')).width('100%');
    }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') }).enabled(this.formEnabled());
  }
  @Builder
  private merchantSection(): void {
    Column({ space: 10 }) {
      Text('店铺（可选）').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      if (this.merchant !== undefined) {
        Text(this.merchant.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%');
        Text(this.merchant.address).fontSize(13).fontColor($r('app.color.muted')).width('100%');
        Text(this.merchant.verificationStatus === 'USER_CONFIRMED_PENDING' ? '用户确认地点 · 待审，不进入地图' :
          this.merchant.verificationStatus === 'REJECTED' ? '店铺已拒绝，请更换或修正' :
          this.merchant.coordinateSystem === 'UNKNOWN' ? '坐标系待验证，不进入地图' : '店铺已核实')
          .fontSize(13).fontColor($r('app.color.muted')).width('100%');
        if (this.merchant.reviewReason.length > 0) { Text('审核意见：' + this.merchant.reviewReason).fontSize(13).fontColor($r('app.color.warning')); }
        if (this.merchant.sourceType === 'USER_CONFIRMED' && this.merchant.verificationStatus !== 'USER_CONFIRMED_APPROVED') {
          Button('修正用户地点并重新送审').height(48).width('100%').enabled(!this.merchantRequestUnconfirmed).onClick((): void => this.correctMerchant());
        }
        Button('取消店铺关联').height(48).width('100%').enabled(!this.merchantRequestUnconfirmed).backgroundColor($r('app.color.canvas')).fontColor($r('app.color.ink'))
          .onClick((): void => { this.merchant = undefined; this.historicalShop = ''; });
      } else {
        Text(this.historicalShop.length > 0 ? '历史店名文本：' + this.historicalShop : '无店铺也可以发布。')
          .fontSize(13).fontColor($r('app.color.muted')).width('100%');
        Text('未关联可靠店铺时，此内容不进入地图和距离功能。').fontSize(13).lineHeight(19).fontColor($r('app.color.muted'));
      }
      Button(this.merchantBusy ? '正在选取 / 核验…' : '在地图中选择店铺').height(48).width('100%').enabled(!this.merchantRequestUnconfirmed)
        .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action')).onClick((): void => { void this.chooseMerchant(); });
      if (this.merchantChoice !== undefined) {
        this.fieldLabel('确认店名');
        TextInput({ text: this.merchantName, placeholder: '普通地图点请补充店名' }).height(48).maxLength(100).enabled(!this.merchantRequestUnconfirmed)
          .backgroundColor($r('app.color.canvas')).onChange((value: string): void => { this.merchantName = value; });
        this.fieldLabel('店铺地址');
        TextInput({ text: this.merchantAddress, placeholder: '地点地址' }).height(48).maxLength(600).enabled(!this.merchantRequestUnconfirmed)
          .backgroundColor($r('app.color.canvas')).onChange((value: string): void => { this.merchantAddress = value; });
        if (this.merchantChoice.providerPoiId.length > 0 && this.providerEnabled) {
          Button('关联官方 POI').height(48).width('100%').enabled(!this.merchantRequestUnconfirmed).onClick((): void => { void this.confirmMerchant(true); });
        }
        Button(this.merchantRequestUnconfirmed ? '重试原地点请求' : this.correctingMerchant ? '保存修正并重新送审' : '创建用户确认地点（待审）').height(48).width('100%')
          .onClick((): void => { void this.confirmMerchant(false); });
        Button('取消本次选点').height(48).width('100%').enabled(!this.merchantRequestUnconfirmed).backgroundColor($r('app.color.canvas')).fontColor($r('app.color.ink'))
          .onClick((): void => { this.merchantChoice = undefined; this.pendingMerchantRequest = undefined; });
      }
    }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') }).enabled((!this.isEditing() || this.editContextReady) && !this.initializing && !this.publishing && !this.merchantBusy && !this.requestUnconfirmed);
  }
  @Builder
  private deliverySection(): void {
    Column({ space: 10 }) {
      Text('外卖信息（可选）').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      this.fieldLabel('外卖平台');
      Select(this.platformLabels()).selected(this.platformOptions().findIndex((value: DeliveryPlatform): boolean => value.key === this.platformKey))
        .height(48).width('100%').backgroundColor($r('app.color.canvas')).onSelect((index: number): void => {
          const platform: DeliveryPlatform | undefined = this.platformOptions()[index];
          if (platform !== undefined && platform.enabled) { this.platformKey = platform.key; this.platformLabel = platform.key.length > 0 ? platform.label : ''; }
        });
      Button(this.moreDeliveryInfo ? '收起更多信息' : '更多信息：订单总额 / 配送费 / 购买日期').height(48).width('100%')
        .backgroundColor($r('app.color.canvas')).fontColor($r('app.color.ink')).onClick((): void => { this.moreDeliveryInfo = !this.moreDeliveryInfo; });
      if (this.moreDeliveryInfo) {
        this.fieldLabel('订单总额（可选，元）');
        TextInput({ text: this.orderTotal, placeholder: '例如 20.00' }).height(48).maxLength(12)
          .onChange((value: string): void => { this.orderTotal = value; });
        this.fieldLabel('配送费（可选，元）');
        TextInput({ text: this.deliveryFee, placeholder: '例如 3.00' }).height(48).maxLength(12)
          .onChange((value: string): void => { this.deliveryFee = value; });
        this.fieldLabel('购买日期（可选）');
        TextInput({ text: this.consumedDate, placeholder: 'YYYY-MM-DD' }).height(48).maxLength(10)
          .onChange((value: string): void => { this.consumedDate = value; });
        Text('只记录体验信息，请勿填写订单号、收货地址、电话或支付凭证。').fontSize(13).lineHeight(19).fontColor($r('app.color.muted'));
      }
    }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') }).enabled(this.formEnabled());
  }
  @Builder
  private reviewSection(): void {
    Column({ space: 10 }) {
      Text('评分与点评').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      this.fieldLabel('口味评分', true); this.scoreStage();
      Row({ space: 8 }) { ForEach(FIRST_SCORE_ROW, (score: number): void => { this.scoreButton(score); }, (score: number): string => score.toString()); }.width('100%');
      Row({ space: 8 }) { ForEach(SECOND_SCORE_ROW, (score: number): void => { this.scoreButton(score); }, (score: number): string => score.toString()); }.width('100%');
      this.fieldLabel('真实点评（可选）');
      TextArea({ text: this.reviewText, placeholder: '味道、口感或推荐理由，最多 600 字' }).height(100).fontSize(15).maxLength(600)
        .backgroundColor($r('app.color.canvas')).borderRadius(12).onChange((value: string): void => { this.reviewText = value; });
      this.fieldLabel('来源链接（可选）');
      TextInput({ text: this.sourceLink, placeholder: 'https://…' }).height(48).fontSize(15).maxLength(2048)
        .backgroundColor($r('app.color.canvas')).borderRadius(12).onChange((value: string): void => { this.sourceLink = value; });
      Text('外部链接不代表实时优惠、库存或配送承诺。').fontSize(13).fontColor($r('app.color.muted'));
    }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') }).enabled(this.formEnabled());
  }
  @Builder
  private photoSection(): void {
    Column({ space: 10 }) {
      this.fieldLabel('实拍照片（最多六张）', true);
      ForEach(this.retainedPhotos, (photo: RetainedPhoto): void => {
        Row({ space: 10 }) {
          Image(photo.url.length > 0 ? photo.url : coverFor(this.category)).width(60).height(60).objectFit(ImageFit.Cover).borderRadius(12)
            .accessibilityText('保留的照片');
          Text(photo.url.length > 0 ? '保留现有照片' : '预览暂不可用，可保留或重选').fontSize(13).fontColor($r('app.color.muted')).layoutWeight(1);
          Button('移除').height(48).fontSize(13).onClick((): void => {
            this.retainedPhotos = this.retainedPhotos.filter((value: RetainedPhoto): boolean => value.id !== photo.id);
          });
        }.width('100%');
      }, (photo: RetainedPhoto): string => photo.id);
      if (this.photoPreviewUris.length > 0) {
        Image(this.photoPreviewUris[0]).width(100).height(100).objectFit(ImageFit.Cover).borderRadius(12).accessibilityText('新添加实拍图');
        Text('新照片 ' + this.photoPreviewUris.length + ' 张。' + this.photoLabel).fontSize(13).fontColor($r('app.color.muted'));
      }
      Button(this.preparedPhotos.length > 0 ? '更换新照片' : '添加新照片').height(48).width('100%')
        .enabled(this.retainedPhotos.length < MAX_CARD_PHOTOS).onClick((): void => { void this.chooseOwnedPhoto(); });
      Row({ space: 8 }) {
        Checkbox({ name: 'photo-rights', group: 'manual-publish' }).select(this.ownsPhoto).onChange((value: boolean): void => { this.ownsPhoto = value; });
        Text('确认照片由本人拍摄或已获授权').fontSize(13).fontColor($r('app.color.ink')).layoutWeight(1);
      }.height(48).width('100%');
    }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') }).enabled(this.formEnabled());
  }
  @Builder
  private visibilitySection(): void {
    Column({ space: 10 }) {
      this.fieldLabel('可见范围');
      Row({ space: 10 }) {
        Button(this.cardVisibility === 'PUBLIC' ? '公开 · 已选' : '公开').height(48).layoutWeight(1)
          .onClick((): void => { this.cardVisibility = 'PUBLIC'; });
        Button(this.cardVisibility === 'FRIENDS' ? '仅好友 · 已选' : '仅好友').height(48).layoutWeight(1)
          .enabled(this.friendsEnabled && (!this.isEditing() || this.baseCard === undefined || this.baseCard.visibility === 'FRIENDS'))
          .onClick((): void => { this.cardVisibility = 'FRIENDS'; });
      }.width('100%').enabled(this.formEnabled());
      if (!this.friendsEnabled) { Text('仅好友发布等待权限验收后开放。').fontSize(13).fontColor($r('app.color.muted')); }
      if (this.isEditing() && this.baseCard !== undefined && this.baseCard.visibility !== 'FRIENDS') {
        Button('立即设为仅好友可见').height(48).width('100%').enabled(this.friendsEnabled && this.formEnabled())
          .onClick((): void => { void this.narrow(); });
        Text('立即生效，旧待审编辑失效；其他内容需在新基准上重新编辑。').fontSize(13).lineHeight(19).fontColor($r('app.color.muted'));
      } else if (this.isEditing() && this.cardVisibility === 'PUBLIC') {
        Text('扩大为公开需审核，通过前维持当前好友范围。').fontSize(13).fontColor($r('app.color.muted'));
      }
    }.width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: $r('app.color.line') });
  }
  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 12 }) {
          Text(this.isEditing() ? '编辑推荐' : '制作推荐').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).layoutWeight(1);
          if (this.isEditing()) {
            Button('返回详情').height(48).onClick((): void => this.onEditingFinished());
          } else {
            Button('重置').height(48).enabled(this.formEnabled()).onClick((): void => {
              try { ModeFieldCache.clear(this.context(), this.activeUid, this.editCardId); } catch (_error) { }
              this.resetForm();
            });
          }
        }.width('100%');
        if (this.initializing) {
          LoadingProgress().height(40).width(40).color($r('app.color.accent_action'));
          Text('正在读取当前权限与编辑状态…').fontSize(13).fontColor($r('app.color.muted'));
        }
        if (this.hasPublishedNotice) {
          Button('继续发布同店菜品').height(52).width('100%').onClick((): void => this.continueSameMerchant());
        }
        this.productInfoSection(); this.merchantSection();
        if (this.mode === 'DELIVERY') { this.deliverySection(); }
        this.reviewSection(); this.photoSection(); this.visibilitySection();
        Text(this.status).fontSize(13).lineHeight(20).fontColor(this.hasPublishedNotice ? $r('app.color.leaf') : $r('app.color.muted'))
          .width('100%').padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        if (this.isEditing() && !this.editContextReady && !this.initializing && !this.requestUnconfirmed) {
          Button('读取最新基准并保留表单').height(48).width('100%').enabled(!this.publishing)
            .onClick((): void => { void this.reloadEditBasis(); });
        }
        Button(this.publishing ? '正在保存…' : this.requestUnconfirmed ? '重试原请求' : this.isEditing() ? '提交待审编辑' : '发布这张卡')
          .enabled((!this.isEditing() || this.editContextReady || this.requestUnconfirmed) && !this.publishing && !this.initializing && !this.merchantBusy && !this.merchantRequestUnconfirmed).width('100%').height(52).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_accent_action')).backgroundColor($r('app.color.accent_action')).borderRadius(15)
          .onClick((): void => { void this.publish(); });
        if (this.isEditing() && this.currentRevision !== undefined && this.currentRevision.status === 'PENDING') {
          Button('撤回待审编辑').height(48).width('100%').enabled(this.formEnabled()).onClick((): void => { void this.withdraw(); });
        }
        if (!this.formEnabled() && !this.initializing && this.requestUnconfirmed) {
          Text('结果未确认，表单已锁定。重试使用原 UUID 与图片，避免重复发布。').fontSize(13).lineHeight(19).fontColor($r('app.color.warning'));
        }
      }.width('100%').padding({ left: 14, right: 14, top: 14, bottom: 28 }).alignItems(HorizontalAlign.Start);
    }.width('100%').height('100%').backgroundColor($r('app.color.canvas'));
  }
}
