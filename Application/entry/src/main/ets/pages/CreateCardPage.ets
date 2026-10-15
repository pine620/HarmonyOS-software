import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { DraftForm, DraftRestore, LocalDraft, DraftRetainedPhoto as RetainedPhoto } from '../model/DraftModels';
import { DraftStore } from '../service/DraftStore';
import { common } from '@kit.AbilityKit';
import { CreateActionStyle, CreateCardBackdrop, CreateChoiceStyle, CreateInputStyle, CreateNoteStyle, CreateSheetKind } from '../common/CreateCardUi';
import { RandomFoodMotionObserver } from '../common/RandomFoodUi';
import util from '@ohos.util';
import { CardEditContextResponse, CardPhoto, CardRevisionChanges, CardRevisionResponse, CardRevisionView, FoodCard, FoodCategory,
  FoodCategoryV2, FoodConsumptionMode, PrepareCardPhotoRequest, PublishCardRequest,
  SubmitCardRevisionRequest } from '../model/CloudContracts';
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
import { ImageRepository } from '../service/ImageRepository';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { ModeFieldCache, ModeFields } from '../service/ModeFieldCache';
import { AuthService } from '../service/AuthService';
import { isSafeHttpsSourceLink } from '../service/SafeSourceLink';
import { tasteScoreLabel, tasteScoreReason } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';

interface LabelOption { value: string; }
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
  @Prop palette: PagePaletteName = 'CREATE';
  onPublished: () => void = (): void => {};
  onEditingFinished: () => void = (): void => {};
  @Prop editCardId: string = '';
  @Prop @Watch('onPageVisibilityChanged') pageActive: boolean = true;
  @StorageLink('stage47AppActive') appActive: boolean = true;
  @State reducedMotion: boolean = true;
  @State sheetVisible: boolean = false;
  @State sheetKind: CreateSheetKind = 'SCORE';
  @State savingDraft: boolean = false;
  @State loadingDraftChoices: boolean = false;
  @State attemptedSubmit: boolean = false;
  @State extraPrice: string = '';
  @State extraOrderTotal: string = '';
  @State extraDeliveryFee: string = '';
  @State extraDate: string = '';
  @State extraLink: string = '';
  @State extraPlatformKey: string = '';
  @State extraPlatformLabel: string = '';
  @State extraError: string = '';
  private motionObserver: RandomFoodMotionObserver = new RandomFoodMotionObserver((reduced: boolean): void => {
    this.reducedMotion = reduced;
  });
  @Prop @Watch('onAccountChanged') accountUid: string = '';
  @State @Watch('onDraftChanged') productName: string = '';
  @State @Watch('onDraftChanged') price: string = '';
  @State @Watch('onDraftChanged') dineInAvg: string = '';
  @State @Watch('onDraftChanged') orderTotal: string = '';
  @State @Watch('onDraftChanged') deliveryFee: string = '';
  @State @Watch('onDraftChanged') consumedDate: string = '';
  @State @Watch('onDraftChanged') sourceLink: string = '';
  @State @Watch('onDraftChanged') reviewText: string = '';
  @State @Watch('onDraftChanged') tasteScore: number = 9;
  @State @Watch('onDraftChanged') category: FoodCategory = 'staple';
  @State @Watch('onDraftChanged') categoryV2: FoodCategoryV2 = 'RICE_SET';
  @State @Watch('onDraftChanged') mode: FoodConsumptionMode = 'DELIVERY';
  @State @Watch('onDraftChanged') merchant: Merchant | undefined = undefined;
  @State @Watch('onDraftChanged') merchantChoice: MerchantChoice | undefined = undefined;
  @State @Watch('onDraftChanged') merchantName: string = '';
  @State @Watch('onDraftChanged') merchantAddress: string = '';
  @State merchantBusy: boolean = false;
  @State @Watch('onDraftChanged') merchantRequestUnconfirmed: boolean = false;
  @State @Watch('onDraftChanged') correctingMerchant: boolean = false;
  @State platforms: Array<DeliveryPlatform> = DeliveryPlatformConfigService.defaults();
  @State @Watch('onDraftChanged') platformKey: string = '';
  @State @Watch('onDraftChanged') platformLabel: string = '';
  @State @Watch('onDraftChanged') moreDeliveryInfo: boolean = false;
  @State photoLabel: string = '';
  @State @Watch('onDraftMediaChanged') photoPreviewUris: Array<string> = [];
  @State @Watch('onDraftMediaChanged') retainedPhotos: Array<RetainedPhoto> = [];
  @State @Watch('onDraftChanged') ownsPhoto: boolean = false;
  @State publishing: boolean = false;
  @State initializing: boolean = true;
  @State editContextReady: boolean = false;
  @State requestUnconfirmed: boolean = false;
  @State savedEditNeedsReload: boolean = false;
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
  private providerEnabled: boolean = false;
  private successMerchant: Merchant | undefined = undefined;
  private successMode: FoodConsumptionMode = 'DELIVERY';

  @Prop restoreDraftId: string = '';
  @State draftChoices: Array<LocalDraft> = [];
  @State draftNotice: string = '';
  private draftId: string = util.generateRandomUUID();
  private draftReady: boolean = false;
  private draftTimer: number | undefined = undefined;
  private draftFlush: () => Promise<void> = (): Promise<void> => this.flushDraft();
  private draftDirty: boolean = false;
  private draftEditSequence: number = 0;
  private onDraftMediaChanged(): void { this.onDraftChanged(); }
  private onDraftChanged(): void {
    if (!this.draftReady || this.initializing || this.hasPublishedNotice) return;
    this.draftDirty = true; this.draftEditSequence++;
    if (this.draftTimer !== undefined) clearTimeout(this.draftTimer);
    this.draftTimer = setTimeout((): void => { this.draftTimer = undefined; void this.flushDraft(); }, 700);
  }
  private draftForm(): DraftForm {
    const form: DraftForm = { ownsPhoto: this.ownsPhoto, productName: this.productName, price: this.price, dineInAvg: this.dineInAvg,
      orderTotal: this.orderTotal, deliveryFee: this.deliveryFee, consumedDate: this.consumedDate, sourceLink: this.sourceLink,
      reviewText: this.reviewText, tasteScore: this.tasteScore, category: this.category, categoryV2: this.categoryV2,
      mode: this.mode, merchant: this.merchant, merchantChoice: this.merchantChoice,
      merchantName: this.merchantName, merchantAddress: this.merchantAddress, platformKey: this.platformKey, platformLabel: this.platformLabel,
      moreDeliveryInfo: this.moreDeliveryInfo, historicalShop: this.historicalShop, retainedPhotos: this.retainedPhotos.map((photo: RetainedPhoto): RetainedPhoto => { return { id: photo.id, url: '' }; }),
      uploadedMediaIds: this.uploadedMediaIds.slice(), publicationRequestId: this.publicationRequestId, requestUnconfirmed: this.requestUnconfirmed,
      pendingPublication: this.pendingPublication, pendingRevision: this.pendingRevision, baseCard: this.baseCard,
      currentRevision: this.currentRevision, merchantRequestId: this.merchantRequestId, pendingMerchantRequest: this.pendingMerchantRequest,
      merchantRequestUnconfirmed: this.merchantRequestUnconfirmed, correctingMerchant: this.correctingMerchant };
    return form;
  }
  private async flushDraft(required: boolean = false): Promise<void> {
    if (!this.draftReady || this.activeUid.length === 0 || this.hasPublishedNotice) { if (required) throw new Error('草稿尚未就绪，请重新进入发布页。'); return; }
    if (this.draftTimer !== undefined) { clearTimeout(this.draftTimer); this.draftTimer = undefined; }
    if (!this.draftDirty && !required) return;
    const generation: number = this.formGeneration;
    const sequence: number = this.draftEditSequence;
    try { await DraftStore.save(this.context(), this.activeUid, this.draftId, this.editCardId, this.draftForm(), this.preparedPhotos.slice()); if (this.stillCurrent(generation)) { if (sequence === this.draftEditSequence) this.draftDirty = false; this.draftNotice = '草稿已保存到本机'; } }
    catch (error) { if (this.stillCurrent(generation)) this.draftNotice = error instanceof Error ? error.message : '草稿保存失败，输入仍保留。'; if (required) throw error instanceof Error ? error : new Error('草稿落盘失败，尚未发送发布请求。'); }
  }
  private async loadDraftChoices(): Promise<void> {
    if (this.activeUid.length === 0) return;
    const generation: number = this.formGeneration; const uid: string = this.activeUid;
    const choices: Array<LocalDraft> = await DraftStore.list(this.context(), uid);
    if (!this.stillCurrent(generation)) return;
    this.draftChoices = choices;
    const reminders: number = await DraftStore.reminders(this.context(), uid);
    if (!this.stillCurrent(generation)) return;
    if (reminders > 0) this.draftNotice = reminders.toString() + ' 个草稿将在 3 天内过期，请及时处理。';
  }
  private async restoreDraft(draft: LocalDraft): Promise<void> {
    const generation: number = this.formGeneration; this.initializing = true; this.draftReady = false;
    try {
      const restored: DraftRestore = await DraftStore.restore(this.context(), this.activeUid, draft.draftId);
      if (!this.stillCurrent(generation)) return;
      const form: DraftForm = restored.draft.form;
      this.productName = form.productName; this.price = form.price; this.dineInAvg = form.dineInAvg; this.orderTotal = form.orderTotal;
      this.deliveryFee = form.deliveryFee; this.consumedDate = form.consumedDate; this.sourceLink = form.sourceLink; this.reviewText = form.reviewText;
      this.tasteScore = form.tasteScore; this.category = form.category; this.categoryV2 = form.categoryV2; this.mode = form.mode;
      this.merchant = form.merchant; this.merchantChoice = form.merchantChoice; this.merchantName = form.merchantName; this.merchantAddress = form.merchantAddress;
      this.platformKey = form.platformKey; this.platformLabel = form.platformLabel; this.moreDeliveryInfo = form.moreDeliveryInfo; this.historicalShop = form.historicalShop;
      this.retainedPhotos = form.retainedPhotos.map((photo: RetainedPhoto): RetainedPhoto => { return { id: photo.id, url: '' }; }); this.uploadedMediaIds = form.uploadedMediaIds.slice(); this.publicationRequestId = form.publicationRequestId;
      this.requestUnconfirmed = form.requestUnconfirmed; this.pendingPublication = form.pendingPublication; this.pendingRevision = form.pendingRevision;
      this.baseCard = form.baseCard; this.currentRevision = form.currentRevision; this.merchantRequestId = form.merchantRequestId;
      this.pendingMerchantRequest = form.pendingMerchantRequest; this.merchantRequestUnconfirmed = form.merchantRequestUnconfirmed; this.correctingMerchant = form.correctingMerchant;
      this.preparedPhotos = []; this.photoPreviewUris = []; let missing: number = restored.missingMediaCount;
      for (const media of restored.media) { try { this.preparedPhotos.push(DraftStore.photo(media)); this.photoPreviewUris.push('file://' + media.path); } catch (_error) { missing++; } }
      this.ownsPhoto = form.ownsPhoto === true;
      this.draftId = draft.draftId; this.draftDirty = true; this.editContextReady = !this.isEditing() || this.baseCard !== undefined;
      if (this.isEditing()) {
        this.editContextReady = false;
        const latest: CardEditContextResponse = await this.editRepository.context(this.context(), this.editCardId);
        if (!this.stillCurrent(generation)) return;
        if (form.baseCard !== undefined && latest.card.modifiedAt === form.baseCard.modifiedAt && latest.card.lifecycleGeneration === form.baseCard.lifecycleGeneration) this.editContextReady = true;
        for (let index: number = 0; index < this.retainedPhotos.length; index++) { const photo: RetainedPhoto = this.retainedPhotos[index]; const current = (latest.card.photos || []).find((value: CardPhoto): boolean => value.id === photo.id); if (current !== undefined) { try { photo.url = await ImageRepository.getDownloadUrl(this.context(), current.bucket, current.path); } catch (_error) {} } }
        if (!this.stillCurrent(generation)) return;
        this.retainedPhotos = this.retainedPhotos.slice();
      }
      this.draftNotice = missing > 0 ? '已恢复文字；' + missing.toString() + ' 张本地图片缺失，请重选。' : '已恢复草稿和原请求标识；编辑基准变化时请刷新确认。';
    } catch (error) { this.draftNotice = error instanceof Error ? error.message : '草稿恢复失败。'; }
    finally { if (this.stillCurrent(generation)) { this.initializing = false; this.draftReady = true; } }
  }
  private async deleteDraft(draft: LocalDraft): Promise<void> { try { await DraftStore.remove(this.context(), this.activeUid, draft.draftId); await this.loadDraftChoices(); } catch (error) { this.draftNotice = error instanceof Error ? error.message : '删除失败。'; } }
  aboutToAppear(): void { this.reducedMotion = this.motionObserver.start(); DraftStore.flushHandler = this.draftFlush; void this.initialize(); }
  aboutToDisappear(): void { this.motionObserver.stop(); this.sheetVisible = false; void this.flushDraft(); if (DraftStore.flushHandler === this.draftFlush) DraftStore.flushHandler = undefined; this.formGeneration++; this.saveModeFields(); this.publishing = false; this.merchantBusy = false; }
  private onPageVisibilityChanged(): void { if (!this.pageActive) this.sheetVisible = false; }
  private onAccountChanged(): void { this.draftReady = false; if (this.draftTimer !== undefined) clearTimeout(this.draftTimer); this.draftTimer = undefined; this.draftChoices = []; this.draftId = util.generateRandomUUID(); this.draftDirty = false; this.formGeneration++; MerchantLocationPicker.clearSelectionCenter(); this.successMerchant = undefined; this.resetForm(); void this.initialize(); }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private stillCurrent(generation: number): boolean {
    const profile = AuthService.profile();
    return generation === this.formGeneration && profile !== undefined && profile.uid === this.activeUid;
  }
  private isEditing(): boolean { return this.editCardId.length > 0; }
  private formEnabled(): boolean { return (!this.isEditing() || this.editContextReady) && !this.initializing && !this.publishing && !this.savingDraft && !this.hasPublishedNotice && !this.merchantBusy && !this.requestUnconfirmed && !this.merchantRequestUnconfirmed; }
  private scoreLabel(score: number = this.tasteScore): string { return tasteScoreLabel(score); }
  private scoreReason(score: number = this.tasteScore): string { return tasteScoreReason(score); }
  private isScoreSelected(score: number): boolean { return this.tasteScore === score; }
  private resetPublicationState(): void { this.hasPublishedNotice = false; }
  private resetForm(): void {
    this.sheetVisible = false; this.attemptedSubmit = false; this.extraError = ''; this.savingDraft = false; this.loadingDraftChoices = false;
    this.formGeneration++; this.publicationRequestId = ''; this.pendingPublication = undefined; this.pendingRevision = undefined;
    this.publishing = false; this.merchantBusy = false; this.merchantRequestUnconfirmed = false;
    this.requestUnconfirmed = false; this.preparedPhotos = []; this.uploadedMediaIds = []; this.retainedPhotos = [];
    this.productName = ''; this.price = ''; this.dineInAvg = ''; this.orderTotal = ''; this.deliveryFee = ''; this.consumedDate = '';
    this.sourceLink = ''; this.reviewText = ''; this.tasteScore = 9; this.category = 'staple'; this.categoryV2 = 'RICE_SET';
    this.merchant = undefined; this.merchantChoice = undefined; this.pendingMerchantRequest = undefined;
    this.merchantRequestId = ''; this.merchantName = ''; this.merchantAddress = ''; this.correctingMerchant = false;
    this.platformKey = ''; this.platformLabel = ''; this.photoPreviewUris = []; this.photoLabel = ''; this.ownsPhoto = false;
    this.currentRevision = undefined; this.baseCard = undefined; this.editContextReady = false; this.savedEditNeedsReload = false; this.historicalShop = ''; this.hasPublishedNotice = false;
    this.status = '填写美食信息，留下你的真实口碑。';
  }
  private async initialize(): Promise<void> {
    this.initializing = true;
    const generation: number = ++this.formGeneration;
    const profile = AuthService.profile();
    this.activeUid = profile === undefined ? '' : profile.uid;
    try {
      const caps = await this.merchantRepository.capabilities(this.context());
      if (!this.stillCurrent(generation)) return;
      this.providerEnabled = caps.providerVerificationEnabled;
      if (this.isEditing()) await this.loadEditContext(generation);
      const platforms: Array<DeliveryPlatform> = await DeliveryPlatformConfigService.load();
      if (!this.stillCurrent(generation)) return;
      this.platforms = platforms;
      await this.loadDraftChoices();
      if (!this.stillCurrent(generation)) return;
      this.draftReady = true;
      if (this.restoreDraftId.length > 0) { const selected: LocalDraft | undefined = this.draftChoices.find((draft: LocalDraft): boolean => draft.draftId === this.restoreDraftId); if (selected !== undefined) await this.restoreDraft(selected); }
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
        try { uri = await ImageRepository.getRevisionDownloadUrl(this.context(), revision.revisionId, id); } catch (_error) { }
        if (!this.stillCurrent(generation)) return;
        const photo: RetainedPhoto = { id, url: uri }; kept.push(photo);
      }
      this.status = revision.status === 'PENDING' ? '已载入旧待审编辑；检查内容后保存，修改将直接生效。' :
        '旧编辑被退回：' + revision.reviewReason + '。检查并修改后保存，修改将直接生效。';
    } else {
      const photos: Array<CardPhoto> = card.photos === undefined ? [] : card.photos;
      for (const photo of photos) {
        let uri: string = '';
        try { uri = card.reviewState === 'REQUEST_CHANGE' ? await ImageRepository.getRevisionDownloadUrl(this.context(), '', photo.id) : await this.repository.hydrateDetailPhoto(this.context(), photo); } catch (_error) { }
        if (!this.stillCurrent(generation)) return;
        const retained: RetainedPhoto = { id: photo.id, url: uri }; if (photo.id.length > 0) kept.push(retained);
      }
      this.status = card.reviewState === 'REQUEST_CHANGE' ? '历史修改要求：' + (card.reviewReason || '请检查内容') + '。修改并保存后将直接生效。' : revision !== null ? '旧编辑已结束或基准变化，已载入当前版本；请检查后保存。' : '保存后修改将直接生效。';
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
    try { ModeFieldCache.save(this.context(), this.activeUid, this.editCardId, fields, this.mode); } catch (_error) { }
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
        await this.flushDraft(true);
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
  private async chooseOwnedPhoto(replace: boolean = false): Promise<void> {
    if (!this.formEnabled()) return;
    const remaining: number = MAX_CARD_PHOTOS - this.retainedPhotos.length - (replace ? 0 : this.preparedPhotos.length);
    if (remaining <= 0) return;
    const generation: number = this.formGeneration;
    this.publishing = true;
    try {
      const uris: Array<string> = await ImagePreparationService.selectMany(remaining);
      if (!this.stillCurrent(generation) || uris.length === 0) return;
      this.publishing = true; this.status = '正在本地处理实拍图…';
      const photos: Array<PreparedPhoto> = [];
      for (const uri of uris) {
        const photo: PreparedPhoto = await ImagePreparationService.prepareOwnedPhoto(uri);
        if (!this.stillCurrent(generation)) return; photos.push(photo);
      }
      const previews: Array<string> = photos.map((photo: PreparedPhoto): string => photo.cover === undefined ? '' : 'data:image/jpeg;base64,' + new util.Base64Helper().encodeToStringSync(new Uint8Array(photo.cover.data)));
      this.preparedPhotos = replace ? photos : this.preparedPhotos.concat(photos);
      if (replace) this.uploadedMediaIds = [];
      this.photoPreviewUris = replace ? previews : this.photoPreviewUris.concat(previews); this.ownsPhoto = false;
      this.photoLabel = '新照片 ' + this.preparedPhotos.length + ' 张，已完成本地处理。';
      this.status = '实拍已准备好，请确认照片拍摄或使用权。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.publishing = false; }
  }
  private formChanges(): CardRevisionChanges {
    const item: number | null = parseYuanInputToFen(this.price);
    const changes: CardRevisionChanges = { productName: this.productName.trim(), priceFen: item === null ? 0 : item,
      reviewText: this.reviewText.trim(), tasteScore: this.tasteScore, sourceLink: this.sourceLink.trim(),
      category: legacyCategoryFor(this.categoryV2), categoryV2: this.categoryV2, consumptionMode: this.mode, visibility: 'PUBLIC',
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
      await this.flushDraft(true);
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
      await this.flushDraft(true);
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
        await this.flushDraft(true);
        const result: CardRevisionResponse = await this.editRepository.submit(this.context(), request);
        if (!this.stillCurrent(generation)) return;
        this.initializing = true;
        this.savedEditNeedsReload = result.revision.status === 'APPROVED';
        this.pendingRevision = undefined; this.publicationRequestId = ''; this.requestUnconfirmed = false;
        try { await DraftStore.remove(this.context(), this.activeUid, this.draftId); }
        catch (_error) { if (this.stillCurrent(generation)) this.draftNotice = '提交结果已确认，本机草稿清理待重试。'; }
        if (!this.stillCurrent(generation)) return;
        if (this.draftTimer !== undefined) clearTimeout(this.draftTimer);
        this.draftTimer = undefined; this.draftDirty = false; this.draftId = util.generateRandomUUID();
        this.currentRevision = result.revision; this.preparedPhotos = []; this.uploadedMediaIds = []; this.photoPreviewUris = [];
        try {
          await this.loadEditContext(generation);
          if (!this.stillCurrent(generation)) return;
          this.savedEditNeedsReload = false;
          this.status = result.revision.status === 'APPROVED' ? '修改已保存并生效，已载入最新内容。' :
            result.revision.status === 'PENDING' ? '云端仍返回旧待审结果，修改尚未生效。请更新云服务后保存。' :
            result.revision.status === 'REJECTED' ? '原请求已被退回，未应用本次修改：' + result.revision.reviewReason :
            '原请求已撤回或被替换，未应用本次修改；已载入当前内容。';
        } catch (error) {
          if (!this.stillCurrent(generation)) return;
          this.editContextReady = false;
          this.status = result.revision.status === 'APPROVED' ?
            '修改已保存并生效，但最新内容读取失败；请重新读取已保存内容。' :
            '提交结果已确认，状态为 ' + result.revision.status + '；最新内容读取失败，请重新读取。';
          this.status += ' ' + errorText(error as ErrorDetail);
        }
      } else {
        let request: PublishCardRequest | undefined = this.pendingPublication;
        if (request === undefined) {
          const mediaIds: Array<string> = await this.uploadPhotos(generation);
          const item: number | null = parseYuanInputToFen(this.price);
          request = { requestId: this.publicationRequestId, productName: this.productName.trim(), brand: '',
            priceFen: item === null ? 0 : item, priceLabel: '', originalPriceFen: 0, specification: '', shop: this.historicalShop,
            sellingPoints: [], publicOffers: [], reviewText: this.reviewText.trim(), tasteScore: this.tasteScore,
            sourceLink: this.sourceLink.trim(), category: this.category, categoryV2: this.categoryV2, consumptionMode: this.mode,
            visibility: 'PUBLIC', merchantId: this.merchant === undefined ? '' : this.merchant.merchantId,
            itemPriceFen: item, dineInAvgFen: this.mode === 'DINE_IN' ? parseYuanInputToFen(this.dineInAvg) : null,
            orderTotalFen: this.mode === 'DELIVERY' ? parseYuanInputToFen(this.orderTotal) : null,
            deliveryFeeFen: this.mode === 'DELIVERY' ? parseYuanInputToFen(this.deliveryFee) : null,
            deliveryPlatformKey: this.mode === 'DELIVERY' ? this.platformKey : '',
            deliveryPlatformLabelSnapshot: this.mode === 'DELIVERY' ? this.platformLabel : '',
            consumedAt: this.mode === 'DELIVERY' ? consumedMillis(this.consumedDate) : null, mediaId: mediaIds[0], mediaIds };
          this.pendingPublication = request;
        }
        this.requestUnconfirmed = true;
        await this.flushDraft(true);
        const result = await this.repository.publish(this.context(), request);
        if (!this.stillCurrent(generation)) return;
        if (result.status !== 'APPROVED') throw new Error('发布结果需进一步确认。');
        this.successMerchant = this.merchant; this.successMode = this.mode;
        try { ModeFieldCache.clear(this.context(), this.activeUid, this.editCardId); } catch (_error) { }
        try { await DraftStore.remove(this.context(), this.activeUid, this.draftId); } catch (_error) { this.draftNotice = '发布已确认，本机草稿清理待重试。'; } this.draftReady = false; this.draftDirty = false; this.resetForm(); this.draftId = util.generateRandomUUID(); this.hasPublishedNotice = true;
        this.status = '发布成功。可以继续发布同店菜品。'; this.onPublished();
      }
    } catch (error) {
      if (!this.stillCurrent(generation)) return;
      if (error instanceof CloudBusinessError) {
        // A business rejection is a confirmed response. Transport/handler errors
        // remain ambiguous and keep the immutable request for retry.
        const confirmed: Array<string> = ['CONFLICT', 'VALIDATION_ERROR',
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
      await this.loadEditContext(generation); this.status = '已撤回旧待审编辑；当前内容未改变。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.publishing = false; }
  }
  private async reloadEditBasis(): Promise<void> {
    if (this.baseCard === undefined) { await this.initialize(); return; }
    const generation: number = this.formGeneration;
    this.initializing = true;
    try {
      if (this.savedEditNeedsReload) {
        await this.loadEditContext(generation);
        if (!this.stillCurrent(generation)) return;
        this.savedEditNeedsReload = false;
        this.status = '修改已保存并生效，已重新载入最新内容。';
        return;
      }
      const response: CardEditContextResponse = await this.editRepository.context(this.context(), this.editCardId);
      if (!this.stillCurrent(generation)) return;
      this.baseCard = response.card; this.currentRevision = response.revision === null ? undefined : response.revision;
      this.editContextReady = true;
      this.status = '已读取最新编辑基准；保留了输入和照片，请检查后重新保存。旧图片失效时请重新选择。';
    } catch (error) { if (this.stillCurrent(generation)) this.status = errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.initializing = false; }
  }
  private continueSameMerchant(): void {
    const merchant: Merchant | undefined = this.successMerchant; const mode: FoodConsumptionMode = this.successMode;
    this.resetForm(); this.merchant = merchant; this.mode = mode;
    this.draftReady = true; this.status = '已继承店铺和消费方式；请填写新菜品、价格、照片和评分。';
  }
  private choiceAnimation(duration: number = 160): AnimateParam {
    const options: AnimateParam = { duration: this.reducedMotion || !this.pageActive || !this.appActive ? 0 : duration, curve: Curve.EaseOut };
    return options;
  }
  private merchantControlsEnabled(): boolean {
    return (!this.isEditing() || this.editContextReady) && !this.initializing && !this.publishing && !this.savingDraft && !this.hasPublishedNotice && !this.merchantBusy && !this.requestUnconfirmed;
  }
  private photoCount(): number { return this.retainedPhotos.length + this.photoPreviewUris.length; }
  private newPhotoKey(index: number): string {
    const photo: PreparedPhoto | undefined = this.preparedPhotos[index];
    return (photo === undefined ? 'missing' : photo.sha256) + ':' + index.toString();
  }
  private merchantSummary(): string {
    if (this.merchantRequestUnconfirmed) return '地点结果未确认 · 点击重试';
    if (this.merchantChoice !== undefined) return '待确认 · ' + this.merchantName;
    if (this.merchant !== undefined) return this.merchant.name;
    return this.historicalShop.length > 0 ? this.historicalShop : '可选 · 选择店铺';
  }
  private extrasSummary(): string {
    const count: number = this.mode === 'DELIVERY'
      ? [this.platformKey, this.orderTotal, this.deliveryFee, this.consumedDate, this.sourceLink].filter((value: string): boolean => value.trim().length > 0).length
      : [this.mode === 'DINE_IN' ? this.price : '', this.sourceLink].filter((value: string): boolean => value.trim().length > 0).length;
    return count > 0 ? '已填写 ' + count.toString() + ' 项' : this.mode === 'DELIVERY' ? '平台、费用、日期、链接' :
      this.mode === 'DINE_IN' ? '单品价格、来源链接' : '来源链接';
  }
  private nameError(): string {
    return this.attemptedSubmit && (this.productName.trim().length < 2 || this.productName.trim().length > 100) ? '美食名称需为 2–100 字。' : '';
  }
  private mainPriceError(): string {
    if (!this.attemptedSubmit) return '';
    try { parseYuanInputToFen(this.mode === 'DINE_IN' ? this.dineInAvg : this.price); return ''; }
    catch (error) { return errorText(error as ErrorDetail); }
  }
  private extrasError(): string {
    if (!this.attemptedSubmit) return '';
    if (this.sourceLink.trim().length > 0 && !isSafeHttpsSourceLink(this.sourceLink)) return '来源链接无效，请在补充信息中修改。';
    try {
      if (this.mode === 'DINE_IN') parseYuanInputToFen(this.price);
      if (this.mode === 'DELIVERY') { parseYuanInputToFen(this.orderTotal); parseYuanInputToFen(this.deliveryFee); consumedMillis(this.consumedDate); }
      return '';
    } catch (error) { return '请检查补充信息：' + errorText(error as ErrorDetail); }
  }
  private photoError(): string {
    if (!this.attemptedSubmit) return '';
    if (this.photoCount() < 1) return '请至少添加一张实拍图。';
    return !this.ownsPhoto ? '请确认照片拍摄或使用权。' : '';
  }
  private openSheet(kind: CreateSheetKind): void {
    if (this.initializing || this.publishing || this.savingDraft || this.merchantBusy) return;
    if ((kind === 'EXTRAS' || kind === 'SCORE') && !this.formEnabled()) return;
    if (kind === 'EXTRAS') {
      this.extraPrice = this.price; this.extraOrderTotal = this.orderTotal; this.extraDeliveryFee = this.deliveryFee;
      this.extraDate = this.consumedDate; this.extraLink = this.sourceLink;
      this.extraPlatformKey = this.platformKey; this.extraPlatformLabel = this.platformLabel; this.extraError = '';
    }
    this.sheetKind = kind; this.sheetVisible = true;
    if (kind === 'DRAFTS') void this.refreshDraftChoices();
  }
  private sheetTitle(): string {
    if (this.sheetKind === 'SCORE') return '选择口味评分';
    if (this.sheetKind === 'EXTRAS') return '补充信息 · 可选';
    if (this.sheetKind === 'MERCHANT') return '关联店铺';
    if (this.sheetKind === 'PHOTOS') return '我的实拍 · ' + this.photoCount().toString() + '/6';
    return '本机草稿';
  }
  private sheetOptions(): SheetOptions {
    const options: SheetOptions = { height: this.sheetKind === 'SCORE' ? '62%' : '85%',
      backgroundColor: pageColor(this.palette, 'surface'), maskColor: pageColor(this.palette, 'scrim'),
      showClose: false, dragBar: false, preferType: SheetType.BOTTOM, mode: SheetMode.OVERLAY,
      keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
      radius: { topLeft: 24, topRight: 24 },
      onWillDismiss: (action: DismissSheetAction): void => {
        if (this.publishing || this.savingDraft || this.merchantBusy) return;
        this.sheetVisible = false; action.dismiss();
      } };
    return options;
  }
  private applyExtras(): void {
    if (!this.formEnabled()) return;
    try {
      if (this.mode === 'DINE_IN') parseYuanInputToFen(this.extraPrice);
      if (this.mode === 'DELIVERY') {
        parseYuanInputToFen(this.extraOrderTotal); parseYuanInputToFen(this.extraDeliveryFee); consumedMillis(this.extraDate);
      }
      if (this.extraLink.trim().length > 0 && !isSafeHttpsSourceLink(this.extraLink)) throw new Error('来源链接需为有效 HTTPS 地址，不含内嵌账号信息。');
    } catch (error) { this.extraError = errorText(error as ErrorDetail); return; }
    if (this.mode === 'DINE_IN') this.price = this.extraPrice;
    if (this.mode === 'DELIVERY') {
      this.orderTotal = this.extraOrderTotal; this.deliveryFee = this.extraDeliveryFee; this.consumedDate = this.extraDate;
      this.platformKey = this.extraPlatformKey; this.platformLabel = this.extraPlatformLabel;
      this.moreDeliveryInfo = this.extraOrderTotal.length > 0 || this.extraDeliveryFee.length > 0 || this.extraDate.length > 0;
    }
    this.sourceLink = this.extraLink; this.resetPublicationState(); this.sheetVisible = false;
  }
  private removeNewPhoto(index: number): void {
    if (!this.formEnabled() || index < 0 || index >= this.preparedPhotos.length) return;
    this.preparedPhotos = this.preparedPhotos.filter((_photo: PreparedPhoto, position: number): boolean => position !== index);
    this.uploadedMediaIds = this.uploadedMediaIds.filter((_id: string, position: number): boolean => position !== index);
    this.photoPreviewUris = this.photoPreviewUris.filter((_uri: string, position: number): boolean => position !== index);
    this.photoLabel = this.preparedPhotos.length > 0 ? '新照片 ' + this.preparedPhotos.length.toString() + ' 张，已完成本地处理。' : '';
  }
  private async saveDraftFromUi(): Promise<void> {
    if (this.initializing || this.publishing || this.savingDraft || this.loadingDraftChoices || this.merchantBusy || !this.draftReady) return;
    const generation: number = this.formGeneration; this.savingDraft = true;
    try { await this.flushDraft(true); if (this.stillCurrent(generation) && this.sheetVisible && this.sheetKind === 'DRAFTS') await this.refreshDraftChoices(); }
    catch (error) { if (this.stillCurrent(generation)) this.draftNotice = '保存失败：' + errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.savingDraft = false; }
  }
  private async refreshDraftChoices(): Promise<void> {
    if (this.loadingDraftChoices) return;
    const generation: number = this.formGeneration; this.loadingDraftChoices = true;
    try { await this.loadDraftChoices(); }
    catch (error) { if (this.stillCurrent(generation)) this.draftNotice = '草稿列表读取失败：' + errorText(error as ErrorDetail); }
    finally { if (this.stillCurrent(generation)) this.loadingDraftChoices = false; }
  }
  private restoreFromUi(draft: LocalDraft): void {
    if (this.initializing || this.publishing || this.savingDraft || this.loadingDraftChoices || this.merchantBusy || this.requestUnconfirmed || this.merchantRequestUnconfirmed) return;
    this.sheetVisible = false; this.attemptedSubmit = false; this.hasPublishedNotice = false; void this.restoreDraft(draft);
  }
  private submitFromUi(): void {
    if (this.savingDraft) return;
    if (this.hasPublishedNotice) { this.continueSameMerchant(); return; }
    this.attemptedSubmit = true; void this.publish();
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
  private fieldLabel(title: string, required: boolean = false): void {
    Row({ space: 4 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'));
      if (required) { Text('*').fontSize(14).fontColor(pageColor(this.palette, 'error')).accessibilityText('必填'); }
    }.constraintSize({ minHeight: 24 }).alignItems(VerticalAlign.Center);
  }
  @Builder
  private fieldError(message: string): void {
    if (message.length > 0) {
      Text(message).fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'error')).width('100%')
        .padding({ top: 4, bottom: 4 }).accessibilityText('提示：' + message);
    }
  }
  @Builder
  private divider(): void { Divider().color(pageColor(this.palette, 'line')).strokeWidth(1).accessibilityLevel('no'); }
  @Builder
  private chevron(): void { Image($r('app.media.ic_create_chevron')).width(18).height(18).accessibilityLevel('no'); }
  @Builder
  private pageHeader(): void {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(this.isEditing() ? '编辑推荐' : '制作推荐').fontSize(26).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
        Text('少一点操作，记得更轻松').fontSize(12).lineHeight(18).fontColor(pageColor(this.palette, 'action'));
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button('草稿箱').attributeModifier(new CreateActionStyle('QUIET', this.palette))
        .border({ width: 1.2, color: pageColor(this.palette, 'action'), style: BorderStyle.Dashed }).borderRadius(24)
        .enabled(!this.initializing && !this.publishing && !this.savingDraft && !this.merchantBusy)
        .onClick((): void => this.openSheet('DRAFTS'));
    }.width('100%').padding({ left: 16, right: 12, top: 8, bottom: 12 });
  }
  @Builder
  private modeControl(): void {
    Row({ space: 4 }) {
      Button('外卖').layoutWeight(1).attributeModifier(new CreateChoiceStyle(this.mode === 'DELIVERY', this.palette))
        .animation(this.choiceAnimation()).onClick((): void => this.selectMode('DELIVERY'));
      Button('到店').layoutWeight(1).attributeModifier(new CreateChoiceStyle(this.mode === 'DINE_IN', this.palette))
        .animation(this.choiceAnimation()).onClick((): void => this.selectMode('DINE_IN'));
    }.padding(4).width('100%').backgroundColor(pageColor(this.palette, 'soft')).borderRadius(16).enabled(this.formEnabled());
    if (this.mode === 'UNSPECIFIED') {
      Text('历史内容未区分外卖 / 到店，可保留或在这里补充。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted')).width('100%');
    }
  }
  @Builder
  private commonFields(): void {
    Column() {
      Row({ space: 8 }) {
        Column() { this.fieldLabel('美食名称', true); }.width(96).alignItems(HorizontalAlign.Start);
        TextInput({ text: this.productName, placeholder: '请输入美食名称' }).layoutWeight(1).height(52).maxLength(100)
          .attributeModifier(new CreateInputStyle(true, this.palette)).accessibilityText('美食名称，必填，2 到 100 字')
          .onChange((value: string): void => { this.productName = value; });
      }.width('100%').constraintSize({ minHeight: 52 }).enabled(this.formEnabled());
      this.fieldError(this.nameError()); this.divider();
      Row({ space: 8 }) {
        Text('主分类').fontSize(14).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink')).width(96);
        Select(this.categoryOptions()).selected(this.categoryIndex()).value(categoryV2Label(this.categoryV2))
          .layoutWeight(1).height(52).font({ size: 14, weight: FontWeight.Medium })
          .fontColor(pageColor(this.palette, 'ink')).backgroundColor(Color.Transparent).borderRadius(0)
          .optionFontColor(pageColor(this.palette, 'ink')).optionBgColor(pageColor(this.palette, 'surface'))
          .selectedOptionBgColor(pageColor(this.palette, 'soft')).selectedOptionFontColor(pageColor(this.palette, 'action'))
          .menuAlign(MenuAlignType.END).accessibilityText('主分类，' + categoryV2Label(this.categoryV2))
          .onSelect((index: number): void => {
            const option: CategoryV2Option | undefined = CATEGORY_V2_OPTIONS[index];
            if (option !== undefined) { this.categoryV2 = option.key; this.category = legacyCategoryFor(option.key); }
          });
      }.width('100%').constraintSize({ minHeight: 52 }).enabled(this.formEnabled());
      this.divider();
      Row({ space: 6 }) {
        Column({ space: 1 }) {
          Text(this.mode === 'DINE_IN' ? '到店人均' : '单品价格').fontSize(14).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'));
          Text('可选 · 元').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        }.width(96).alignItems(HorizontalAlign.Start);
        Text('¥').fontSize(16).fontColor(pageColor(this.palette, 'action'));
        TextInput({ text: this.mode === 'DINE_IN' ? this.dineInAvg : this.price, placeholder: '留空表示未知' })
          .height(52).layoutWeight(1).maxLength(12).type(InputType.NUMBER_DECIMAL)
          .attributeModifier(new CreateInputStyle(true, this.palette)).accessibilityText(this.mode === 'DINE_IN' ? '到店人均，可选，单位元' : '单品价格，可选，单位元')
          .onChange((value: string): void => { if (this.mode === 'DINE_IN') this.dineInAvg = value; else this.price = value; });
      }.width('100%').constraintSize({ minHeight: 52 }).enabled(this.formEnabled());
      this.fieldError(this.mainPriceError()); this.divider();
      Button() {
        Row({ space: 8 }) {
          Text('关联店铺').fontSize(14).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink')).width(96);
          Text(this.merchantSummary()).fontSize(14).fontColor(this.merchantChoice !== undefined || this.merchantRequestUnconfirmed ? pageColor(this.palette, 'action') : pageColor(this.palette, 'muted'))
            .layoutWeight(1).textAlign(TextAlign.End).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
          this.chevron();
        }.width('100%');
      }.width('100%').attributeModifier(new CreateActionStyle('QUIET', this.palette)).padding({ top: 6, bottom: 6, left: 0, right: 0 })
        .constraintSize({ minHeight: 52 }).borderRadius(0).enabled(this.merchantControlsEnabled())
        .accessibilityText('关联店铺，' + this.merchantSummary()).onClick((): void => this.openSheet('MERCHANT'));
      this.divider();
      Button() {
        Row({ space: 8 }) {
          Text('口味评分').fontSize(14).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink')).width(96);
          Text(this.tasteScore.toString() + '/10 · ' + this.scoreLabel()).fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'action')).layoutWeight(1).textAlign(TextAlign.End);
          this.chevron();
        }.width('100%');
      }.width('100%').attributeModifier(new CreateActionStyle('QUIET', this.palette)).padding({ top: 6, bottom: 6, left: 0, right: 0 })
        .constraintSize({ minHeight: 52 }).borderRadius(0).enabled(this.formEnabled())
        .accessibilityText('口味评分，' + this.tasteScore.toString() + ' 分，' + this.scoreLabel() + '，点击修改')
        .onClick((): void => this.openSheet('SCORE'));
    }.width('100%').padding({ left: 12, right: 12 }).backgroundColor(pageColor(this.palette, 'surface'))
      .borderRadius(18).border({ width: 1, color: pageColor(this.palette, 'line') });
  }
  @Builder
  private reviewSection(): void {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        this.fieldLabel('真实点评'); Text('可选').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        Blank(); Text(this.reviewText.length.toString() + '/600').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
      }.width('100%');
      TextArea({ text: this.reviewText, placeholder: '说说味道、口感或推荐理由' }).height(76).maxLength(600)
        .attributeModifier(new CreateNoteStyle(this.palette)).accessibilityText('真实点评，可选，最多 600 字')
        .onChange((value: string): void => { this.reviewText = value; });
    }.width('100%').enabled(this.formEnabled());
  }
  @Builder
  private photoThumbnail(uri: string, position: number): void {
    Button() {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (uri.length > 0) {
          Image(uri).width('100%').height('100%').objectFit(ImageFit.Cover).autoResize(true).syncLoad(false).accessibilityLevel('no');
        } else {
          Image($r('app.media.ic_create_photo')).width(28).height(28).align(Alignment.Center).accessibilityLevel('no');
        }
        Text(position === 0 ? '封面' : '实拍 ' + (position + 1).toString()).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(pageColor(this.palette, 'ink')).backgroundColor(pageColor(this.palette, 'surface'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius({ topRight: 8 });
      }.width('100%').height('100%').clip(true).borderRadius(12);
    }.width(72).height(72).attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).padding(0).borderRadius(12)
      .accessibilityText((position === 0 ? '封面' : '第 ' + (position + 1).toString() + ' 张实拍') + '，点击管理照片')
      .onClick((): void => this.openSheet('PHOTOS'));
  }
  @Builder
  private photoSection(): void {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.retainedPhotos, (photo: RetainedPhoto, index: number): void => {
              this.photoThumbnail(photo.url, index);
            }, (photo: RetainedPhoto, index: number): string => photo.id + ':' + index.toString() + ':' + photo.url);
            ForEach(this.photoPreviewUris, (uri: string, index: number): void => {
              this.photoThumbnail(uri, this.retainedPhotos.length + index);
            }, (_uri: string, index: number): string => this.newPhotoKey(index));
            if (this.photoCount() < MAX_CARD_PHOTOS) {
              Button() {
                Column({ space: 4 }) {
                  Image($r('app.media.ic_create_photo')).width(24).height(24).fillColor(pageColor(this.palette, 'action')).accessibilityLevel('no');
                  Text('添加实拍').fontSize(12).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action'));
                }.justifyContent(FlexAlign.Center).width('100%').height('100%');
              }.width(72).height(72).attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).padding(0).borderRadius(12)
                .enabled(this.formEnabled()).onClick((): void => { void this.chooseOwnedPhoto(); });
            }
          }.height(76);
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1).height(76);
        Column({ space: 2 }) {
          Text(this.photoCount().toString() + '/6').fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
          Text('我的实拍').fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        }.width(56).alignItems(HorizontalAlign.End);
      }.width('100%');
      this.fieldError(this.attemptedSubmit && this.photoCount() === 0 ? '请至少添加一张实拍图。' : '');
    }.width('100%');
  }
  @Builder
  private extrasEntry(): void {
    Button() {
      Row({ space: 8 }) {
        Text('补充信息').fontSize(14).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'));
        Text(this.extrasSummary()).fontSize(13).fontColor(pageColor(this.palette, 'muted')).layoutWeight(1).textAlign(TextAlign.End);
        this.chevron();
      }.width('100%');
    }.width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).constraintSize({ minHeight: 52 })
      .enabled(this.formEnabled()).onClick((): void => this.openSheet('EXTRAS'));
    this.fieldError(this.extrasError());
  }
  @Builder
  private photoRights(): void {
    Row({ space: 4 }) {
      Checkbox({ name: 'photo-rights', group: 'manual-publish' }).select(this.ownsPhoto).width(24).height(24).margin(12)
        .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
        .selectedColor(pageColor(this.palette, 'action')).unselectedColor(pageColor(this.palette, 'muted'))
        .accessibilityText('确认照片由本人拍摄或已获授权').enabled(this.formEnabled())
        .onChange((value: boolean): void => { this.ownsPhoto = value; });
      Text('照片由本人拍摄或已获授权').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
    }.width('100%').constraintSize({ minHeight: 48 });
    this.fieldError(this.attemptedSubmit && this.photoCount() > 0 ? this.photoError() : '');
  }
  @Builder
  private scoreButton(score: number): void {
    Button() {
      Column({ space: 3 }) {
        Text(score.toString()).fontSize(20).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
        Text(this.scoreLabel(score)).fontSize(12).fontColor(pageColor(this.palette, 'action'));
      }.width('100%').alignItems(HorizontalAlign.Center);
    }.layoutWeight(1).constraintSize({ minHeight: 68 }).attributeModifier(new CreateActionStyle('SECONDARY', this.palette))
      .padding({ top: 8, bottom: 8, left: 4, right: 4 })
      .backgroundColor(this.isScoreSelected(score) ? pageColor(this.palette, 'soft') : pageColor(this.palette, 'canvas'))
      .border({ width: this.isScoreSelected(score) ? 2 : 1, color: this.isScoreSelected(score) ? pageColor(this.palette, 'action') : pageColor(this.palette, 'line') })
      .animation(this.choiceAnimation(140)).accessibilitySelected(this.isScoreSelected(score))
      .accessibilityText(score.toString() + ' 分，' + this.scoreLabel(score) + (this.isScoreSelected(score) ? '，已选中' : ''))
      .enabled(this.formEnabled()).onClick((): void => { this.tasteScore = score; this.resetPublicationState(); this.sheetVisible = false; });
  }
  @Builder
  private scoreSheet(): void {
    Column({ space: 12 }) {
      Text(this.tasteScore.toString() + '/10 · ' + this.scoreLabel()).fontSize(22).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'action'));
      Text(this.scoreReason()).fontSize(14).lineHeight(21).fontColor(pageColor(this.palette, 'muted')).width('100%');
      Row({ space: 8 }) { ForEach(FIRST_SCORE_ROW, (score: number): void => { this.scoreButton(score); }, (score: number): string => score.toString()); }.width('100%');
      Row({ space: 8 }) { ForEach(SECOND_SCORE_ROW, (score: number): void => { this.scoreButton(score); }, (score: number): string => score.toString()); }.width('100%');
      Text('1–10 分，按自己的真实口味选择。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted'));
    }.width('100%').alignItems(HorizontalAlign.Start);
  }
  @Builder
  private extrasSheet(): void {
    Column({ space: 8 }) {
      if (this.mode === 'DELIVERY') {
        this.fieldLabel('外卖平台');
        Select(this.platformLabels()).selected(this.platformOptions().findIndex((value: DeliveryPlatform): boolean => value.key === this.extraPlatformKey))
          .value(this.extraPlatformLabel.length > 0 ? this.extraPlatformLabel : '不填写平台').height(48).width('100%')
          .font({ size: 15 }).fontColor(pageColor(this.palette, 'ink')).backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(12)
          .optionFontColor(pageColor(this.palette, 'ink')).optionBgColor(pageColor(this.palette, 'surface'))
          .selectedOptionBgColor(pageColor(this.palette, 'soft')).selectedOptionFontColor(pageColor(this.palette, 'action'))
          .accessibilityText('外卖平台，可选').onSelect((index: number): void => {
            const platform: DeliveryPlatform | undefined = this.platformOptions()[index];
            if (platform !== undefined && platform.enabled) { this.extraPlatformKey = platform.key; this.extraPlatformLabel = platform.key.length > 0 ? platform.label : ''; }
          });
        this.fieldLabel('订单总额（元）');
        TextInput({ text: this.extraOrderTotal, placeholder: '留空表示未知' }).height(48).maxLength(12).type(InputType.NUMBER_DECIMAL)
          .attributeModifier(new CreateInputStyle(false, this.palette)).accessibilityText('订单总额，可选，单位元').onChange((value: string): void => { this.extraOrderTotal = value; });
        this.fieldLabel('配送费（元）');
        TextInput({ text: this.extraDeliveryFee, placeholder: '留空表示未知' }).height(48).maxLength(12).type(InputType.NUMBER_DECIMAL)
          .attributeModifier(new CreateInputStyle(false, this.palette)).accessibilityText('配送费，可选，单位元').onChange((value: string): void => { this.extraDeliveryFee = value; });
        this.fieldLabel('购买日期');
        TextInput({ text: this.extraDate, placeholder: 'YYYY-MM-DD' }).height(48).maxLength(10).attributeModifier(new CreateInputStyle(false, this.palette))
          .accessibilityText('购买日期，可选，格式 YYYY-MM-DD').onChange((value: string): void => { this.extraDate = value; });
        Text('请勿填写订单号、收货地址、电话或支付凭证。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted'));
      } else if (this.mode === 'DINE_IN') {
        this.fieldLabel('单品价格（元）');
        TextInput({ text: this.extraPrice, placeholder: '留空表示未知' }).height(48).maxLength(12).type(InputType.NUMBER_DECIMAL)
          .attributeModifier(new CreateInputStyle(false, this.palette)).accessibilityText('单品价格，可选，单位元').onChange((value: string): void => { this.extraPrice = value; });
      }
      this.fieldLabel('来源链接');
      TextInput({ text: this.extraLink, placeholder: 'https://…' }).height(48).maxLength(2048).attributeModifier(new CreateInputStyle(false, this.palette))
        .accessibilityText('来源链接，可选，HTTPS 地址').onChange((value: string): void => { this.extraLink = value; });
      Text(this.mode === 'DINE_IN' ? '人均与单品价分别保存；留空表示未知，0 表示明确零元。' : '金额留空表示未知，0 表示明确零元。')
        .fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted'));
      Text('外部链接不代表实时优惠、库存或配送承诺。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted'));
      this.fieldError(this.extraError);
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).onClick((): void => { this.sheetVisible = false; });
        Button('应用信息').layoutWeight(1).attributeModifier(new CreateActionStyle('PRIMARY', this.palette)).onClick((): void => this.applyExtras());
      }.width('100%').padding({ top: 8 });
    }.width('100%').alignItems(HorizontalAlign.Start).enabled(this.formEnabled());
  }
  @Builder
  private merchantSheet(): void {
    Column({ space: 10 }) {
      if (this.merchant !== undefined) {
        Text(this.merchant.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%');
        Text(this.merchant.address).fontSize(14).lineHeight(21).fontColor(pageColor(this.palette, 'muted')).width('100%');
        Text(this.merchant.verificationStatus === 'USER_CONFIRMED_PENDING' ? '用户确认地点 · 待审，不进入地图' :
          this.merchant.verificationStatus === 'REJECTED' ? '店铺已拒绝，请更换或修正' :
          this.merchant.coordinateSystem === 'UNKNOWN' ? '坐标系待验证，不进入地图' : '店铺已核实')
          .fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted')).width('100%');
        if (this.merchant.reviewReason.length > 0) { this.fieldError('审核意见：' + this.merchant.reviewReason); }
        if (this.merchant.sourceType === 'USER_CONFIRMED' && this.merchant.verificationStatus !== 'USER_CONFIRMED_APPROVED') {
          Button('修正用户地点并重新送审').width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette))
            .enabled(!this.merchantRequestUnconfirmed).onClick((): void => this.correctMerchant());
        }
        Button('取消店铺关联').width('100%').attributeModifier(new CreateActionStyle('QUIET', this.palette)).enabled(!this.merchantRequestUnconfirmed)
          .onClick((): void => { this.merchant = undefined; this.historicalShop = ''; });
      } else {
        Text(this.historicalShop.length > 0 ? '历史店名：' + this.historicalShop : '无店铺也可以发布。').fontSize(14).lineHeight(21).fontColor(pageColor(this.palette, 'muted')).width('100%');
        Text('未关联可靠店铺时，此内容不进入地图和距离功能。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted'));
      }
      Button('在地图中选择店铺').width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).enabled(!this.merchantRequestUnconfirmed)
        .onClick((): void => { void this.chooseMerchant(); });
      if (this.merchantChoice !== undefined) {
        this.fieldLabel('确认店名');
        TextInput({ text: this.merchantName, placeholder: '普通地图点请补充店名' }).height(48).maxLength(100).enabled(!this.merchantRequestUnconfirmed)
          .attributeModifier(new CreateInputStyle(false, this.palette)).accessibilityText('确认店名').onChange((value: string): void => { this.merchantName = value; });
        this.fieldLabel('店铺地址');
        TextInput({ text: this.merchantAddress, placeholder: '地点地址' }).height(48).maxLength(600).enabled(!this.merchantRequestUnconfirmed)
          .attributeModifier(new CreateInputStyle(false, this.palette)).accessibilityText('店铺地址').onChange((value: string): void => { this.merchantAddress = value; });
        if (this.merchantChoice.providerPoiId.length > 0 && this.providerEnabled) {
          Button('关联官方 POI').width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).enabled(!this.merchantRequestUnconfirmed)
            .onClick((): void => { void this.confirmMerchant(true); });
        }
        Button(this.merchantRequestUnconfirmed ? '重试原地点请求' : this.correctingMerchant ? '保存修正并重新送审' : '创建用户确认地点（待审）')
          .width('100%').attributeModifier(new CreateActionStyle('PRIMARY', this.palette)).onClick((): void => { void this.confirmMerchant(false); });
        Button('取消本次选点').width('100%').attributeModifier(new CreateActionStyle('QUIET', this.palette)).enabled(!this.merchantRequestUnconfirmed)
          .onClick((): void => { this.merchantChoice = undefined; this.pendingMerchantRequest = undefined; });
      }
    }.width('100%').alignItems(HorizontalAlign.Start).enabled(this.merchantControlsEnabled());
  }
  @Builder
  private photosSheet(): void {
    Column({ space: 10 }) {
      Text('最多六张，首张作为列表封面。').fontSize(14).lineHeight(21).fontColor(pageColor(this.palette, 'muted'));
      ForEach(this.retainedPhotos, (photo: RetainedPhoto, index: number): void => {
        Row({ space: 10 }) {
          if (photo.url.length > 0) { Image(photo.url).width(64).height(64).objectFit(ImageFit.Contain).autoResize(true).syncLoad(false).borderRadius(12).accessibilityText('保留的实拍图'); }
          else { Image($r('app.media.ic_create_photo')).width(64).height(64).accessibilityText('图片预览暂不可用'); }
          Text(index === 0 ? '封面 · 已有实拍' : '已有实拍 ' + (index + 1).toString()).fontSize(14).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
          Button('移除').attributeModifier(new CreateActionStyle('DANGER', this.palette)).enabled(this.formEnabled())
            .accessibilityText('移除第 ' + (index + 1).toString() + ' 张已有实拍').onClick((): void => {
              if (this.formEnabled()) this.retainedPhotos = this.retainedPhotos.filter((value: RetainedPhoto): boolean => value.id !== photo.id);
            });
        }.width('100%');
      }, (photo: RetainedPhoto, index: number): string => photo.id + ':' + index.toString() + ':' + photo.url);
      ForEach(this.photoPreviewUris, (uri: string, index: number): void => {
        Row({ space: 10 }) {
          if (uri.length > 0) { Image(uri).width(64).height(64).objectFit(ImageFit.Contain).autoResize(true).syncLoad(false).borderRadius(12).accessibilityText('新增的实拍图'); }
          else { Image($r('app.media.ic_create_photo')).width(64).height(64).accessibilityText('图片预览暂不可用'); }
          Text(this.retainedPhotos.length + index === 0 ? '封面 · 新增实拍' : '新增实拍 ' + (index + 1).toString()).fontSize(14).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
          Button('移除').attributeModifier(new CreateActionStyle('DANGER', this.palette)).enabled(this.formEnabled())
            .accessibilityText('移除第 ' + (index + 1).toString() + ' 张新增实拍').onClick((): void => this.removeNewPhoto(index));
        }.width('100%');
      }, (_uri: string, index: number): string => this.newPhotoKey(index));
      if (this.photoLabel.length > 0) { Text(this.photoLabel).fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted')); }
      Button(this.photoCount() >= MAX_CARD_PHOTOS ? '已达六张上限' : '继续添加实拍').width('100%').attributeModifier(new CreateActionStyle('PRIMARY', this.palette))
        .enabled(this.formEnabled() && this.photoCount() < MAX_CARD_PHOTOS).onClick((): void => { void this.chooseOwnedPhoto(); });
      if (this.photoPreviewUris.length > 0) {
        Button('重新选择全部新照片').width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette)).enabled(this.formEnabled())
          .onClick((): void => { void this.chooseOwnedPhoto(true); });
        Text('重新选择仅替换新增照片；取消选择会保留当前照片。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted'));
      }
      this.photoRights();
    }.width('100%').alignItems(HorizontalAlign.Start);
  }
  @Builder
  private draftsSheet(): void {
    Column({ space: 10 }) {
      Text('草稿保存在本机 · 最多 10 份 · 30 天未编辑自动清理').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted')).width('100%');
      if (this.draftNotice.length > 0) { Text(this.draftNotice).fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'action')).width('100%'); }
      if (this.loadingDraftChoices) { Text('正在读取本机草稿…').fontSize(14).fontColor(pageColor(this.palette, 'muted')); }
      else if (this.draftChoices.length === 0) { Text('暂无本机草稿').fontSize(15).fontColor(pageColor(this.palette, 'muted')).padding({ top: 16, bottom: 16 }); }
      ForEach(this.draftChoices, (draft: LocalDraft): void => {
        Column({ space: 6 }) {
          Text(draft.form.productName || '未命名推荐').fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink')).width('100%');
          Text(draft.draftType === 'EDIT' ? '编辑草稿 · 仅在对应推荐中恢复' : '新发布草稿').fontSize(12).lineHeight(18).fontColor(pageColor(this.palette, 'muted')).width('100%');
          Row({ space: 8 }) {
            Button('继续填写').layoutWeight(1).attributeModifier(new CreateActionStyle('SECONDARY', this.palette))
              .enabled(draft.targetCardId === this.editCardId && !this.initializing && !this.publishing && !this.savingDraft && !this.loadingDraftChoices && !this.merchantBusy && !this.requestUnconfirmed && !this.merchantRequestUnconfirmed)
              .onClick((): void => this.restoreFromUi(draft));
            Button('删除').attributeModifier(new CreateActionStyle('DANGER', this.palette))
              .enabled(!this.initializing && !this.publishing && !this.savingDraft && !this.loadingDraftChoices && !this.merchantBusy && !this.requestUnconfirmed && !this.merchantRequestUnconfirmed)
              .onClick((): void => { void this.deleteDraft(draft); });
          }.width('100%');
        }.width('100%').padding(12).backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(14).alignItems(HorizontalAlign.Start);
      }, (draft: LocalDraft): string => draft.draftId + ':' + draft.updatedAt.toString());
      Button('保存当前草稿').width('100%').attributeModifier(new CreateActionStyle('PRIMARY', this.palette))
        .enabled(this.draftReady && !this.initializing && !this.publishing && !this.savingDraft && !this.loadingDraftChoices && !this.merchantBusy).onClick((): void => { void this.saveDraftFromUi(); });
      Button('清空当前表单').width('100%').attributeModifier(new CreateActionStyle('QUIET', this.palette)).enabled(this.formEnabled() && !this.isEditing())
        .onClick((): void => {
          try { ModeFieldCache.clear(this.context(), this.activeUid, this.editCardId); } catch (_error) { }
          this.resetForm();
        });
    }.width('100%').alignItems(HorizontalAlign.Start);
  }
  @Builder
  private busyFeedback(): void {
    if (this.initializing || this.publishing || this.merchantBusy || this.savingDraft) {
      Row({ space: 8 }) {
        if (!this.reducedMotion && this.pageActive && this.appActive) { LoadingProgress().width(24).height(24).color(pageColor(this.palette, 'action')); }
        Text(this.initializing ? '正在读取表单…' : this.merchantBusy ? '正在选取 / 核验店铺…' : this.savingDraft ? '正在保存本机草稿…' : '正在处理照片或提交…')
          .fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'action')).layoutWeight(1);
      }.width('100%').padding(10).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(12);
    }
  }
  @Builder
  private sheetContent(): void {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Text(this.sheetTitle()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
        Button(this.sheetKind === 'EXTRAS' ? '取消' : '关闭').attributeModifier(new CreateActionStyle('QUIET', this.palette))
          .enabled(!this.publishing && !this.savingDraft && !this.merchantBusy).onClick((): void => { this.sheetVisible = false; });
      }.width('100%').padding({ left: 20, right: 12, top: 8, bottom: 4 });
      Scroll() {
        Column({ space: 12 }) {
          if (this.sheetKind === 'SCORE') { this.scoreSheet(); }
          else if (this.sheetKind === 'EXTRAS') { this.extrasSheet(); }
          else if (this.sheetKind === 'MERCHANT') { this.merchantSheet(); }
          else if (this.sheetKind === 'PHOTOS') { this.photosSheet(); }
          else { this.draftsSheet(); }
          this.busyFeedback();
          if (this.sheetKind === 'MERCHANT' || this.sheetKind === 'PHOTOS') {
            Text(this.status).fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'muted')).width('100%');
          }
        }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 28 }).alignItems(HorizontalAlign.Start);
      }.layoutWeight(1).width('100%').align(Alignment.TopStart);
    }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'surface'));
  }
  @Builder
  private formFeedback(): void {
    this.busyFeedback();
    Text(this.status === '填写美食信息，留下你的真实口碑。' && this.draftNotice.length > 0 ? this.draftNotice : this.status)
      .fontSize(13).lineHeight(19).fontColor(this.hasPublishedNotice ? pageColor(this.palette, 'good') : pageColor(this.palette, 'muted')).width('100%');
    if (this.mode === 'DINE_IN') { Text('到店人均与单品价分别记录，未填人均不以单品价替代。').fontSize(12).lineHeight(18).fontColor(pageColor(this.palette, 'muted')).width('100%'); }
    if (this.requestUnconfirmed) { Text('提交结果尚未确认，输入已保留。重试会继续上次提交。').fontSize(13).lineHeight(19).fontColor(pageColor(this.palette, 'error')).width('100%'); }
    if (this.merchantRequestUnconfirmed || this.merchantChoice !== undefined) {
      Button(this.merchantRequestUnconfirmed ? '查看并重试原地点请求' : '继续确认店铺').width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette))
        .enabled(this.merchantControlsEnabled()).onClick((): void => this.openSheet('MERCHANT'));
    }
    if (this.isEditing() && !this.editContextReady && !this.initializing && !this.requestUnconfirmed) {
      Button(this.savedEditNeedsReload ? '重新读取已保存内容' : '读取最新基准并保留表单').width('100%').attributeModifier(new CreateActionStyle('SECONDARY', this.palette))
        .enabled(!this.publishing && !this.savingDraft).onClick((): void => { void this.reloadEditBasis(); });
    }
    if (this.isEditing() && this.currentRevision !== undefined && this.currentRevision.status === 'PENDING') {
      Button('撤回旧待审编辑').width('100%').attributeModifier(new CreateActionStyle('DANGER', this.palette)).enabled(this.formEnabled())
        .onClick((): void => { void this.withdraw(); });
    }
  }
  @Builder
  private submitBar(): void {
    Row({ space: 12 }) {
      Button(this.savingDraft ? '保存中…' : '保存草稿').layoutWeight(1).attributeModifier(new CreateActionStyle('SECONDARY', this.palette))
        .enabled(this.draftReady && !this.initializing && !this.publishing && !this.savingDraft && !this.loadingDraftChoices && !this.merchantBusy)
        .onClick((): void => { void this.saveDraftFromUi(); });
      Button(this.publishing ? '正在处理…' : this.requestUnconfirmed ? '重试原请求' : this.hasPublishedNotice ? '继续制作同店菜品' : this.isEditing() ? '保存修改' : '发布推荐')
        .layoutWeight(1.5).attributeModifier(new CreateActionStyle('PRIMARY', this.palette)).fontSize(16).fontWeight(FontWeight.Bold)
        .enabled((!this.isEditing() || this.editContextReady || this.requestUnconfirmed) && !this.publishing && !this.initializing && !this.savingDraft && !this.merchantBusy && !this.merchantRequestUnconfirmed)
        .onClick((): void => this.submitFromUi());
    }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).backgroundColor(pageColor(this.palette, 'canvas'))
      .border({ width: { top: 1 }, color: pageColor(this.palette, 'line') });
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      CreateCardBackdrop({ palette: this.palette });
      Column({ space: 0 }) {
        this.pageHeader();
        Scroll() {
          Column({ space: 8 }) {
            this.modeControl(); this.commonFields(); this.reviewSection(); this.photoSection(); this.extrasEntry(); this.photoRights(); this.formFeedback();
          }.width('100%').padding({ left: 16, right: 16, bottom: 16 }).alignItems(HorizontalAlign.Start);
        }.width('100%').layoutWeight(1).align(Alignment.TopStart);
        this.submitBar();
      }.width('100%').height('100%');
    }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas'))
      .bindSheet($$this.sheetVisible, this.sheetContent(), this.sheetOptions());
  }
}
