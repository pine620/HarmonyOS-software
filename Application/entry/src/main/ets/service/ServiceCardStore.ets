import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import util from '@ohos.util';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { foodCardCategoryLabel } from '../components/FoodCover';
import { ServiceCardCoverCache } from './ServiceCardCoverCache';

const STORE_OPTIONS: preferences.Options = { name: 'shike_service_card' };
const DIMENSION_OPTIONS: preferences.Options = { name: 'shike_service_card_dimensions' };
const FORM_IDS_KEY: string = 'form_ids';
const CARD_ID_KEY: string = 'card_id';
const PRODUCT_NAME_KEY: string = 'product_name';
const SCORE_TEXT_KEY: string = 'score_text';
const PRICE_TEXT_KEY: string = 'price_text';
const LOCATION_TEXT_KEY: string = 'location_text';
const CATEGORY_TEXT_KEY: string = 'category_text';
const PHOTO_PATH_KEY: string = 'photo_path';
const PHOTO_BUCKET_KEY: string = 'photo_bucket';
const COVER_FILE_KEY: string = 'cover_file';
const COVER_CARD_ID_KEY: string = 'cover_card_id';
const COVER_PHOTO_PATH_KEY: string = 'cover_photo_path';
const COVER_PHOTO_BUCKET_KEY: string = 'cover_photo_bucket';
const REMOTE_PROXY_KEYS: Array<string> = [
  'cardId', 'productName', 'scoreText', 'priceText', 'locationText', 'categoryText', 'photoPath', 'photoBucket'
];

export class ServiceCardBindingData {
  formId: string = '';
  formDimension: number = 2;
  cardId: string = '';
  productName: string = '附近值得一试';
  scoreText: string = '';
  priceText: string = '';
  locationText: string = '20 km 内';
  categoryText: string = '附近';
  photoPath: string = '';
  photoBucket: string = '';
  coverCardId: string = '';
  coverPhotoPath: string = '';
  coverPhotoBucket: string = '';
  coverImageName: string = '';
  formImages: Record<string, number> = {};
}

class ServiceCardBindingLease {
  data: ServiceCardBindingData = new ServiceCardBindingData();
  file: fileIo.File | undefined = undefined;

  close(): void {
    if (this.file !== undefined) {
      try { fileIo.closeSync(this.file); } catch (_error) { }
      this.file = undefined;
    }
  }
}

function storeFor(context: common.Context): preferences.Preferences {
  // The app and FormExtensionAbility may run in different processes.
  preferences.removePreferencesFromCacheSync(context, STORE_OPTIONS);
  return preferences.getPreferencesSync(context, STORE_OPTIONS);
}

function dimensionStore(context: common.Context): preferences.Preferences {
  preferences.removePreferencesFromCacheSync(context, DIMENSION_OPTIONS);
  return preferences.getPreferencesSync(context, DIMENSION_OPTIONS);
}

function stringValue(value: preferences.ValueType, fallback: string): string {
  return typeof value === 'string' ? value : fallback;
}

export class ServiceCardStore {
  private static publicationGeneration: number = 0;
  private static initialBindings: Map<string, ServiceCardBindingLease> =
    new Map<string, ServiceCardBindingLease>();

  static read(context: common.Context, snapshot?: preferences.Preferences): ServiceCardBindingData {
    const store: preferences.Preferences = snapshot === undefined ? storeFor(context) : snapshot;
    const data: ServiceCardBindingData = new ServiceCardBindingData();
    data.cardId = stringValue(store.getSync(CARD_ID_KEY, ''), '');
    data.productName = stringValue(store.getSync(PRODUCT_NAME_KEY, data.productName), data.productName);
    data.scoreText = stringValue(store.getSync(SCORE_TEXT_KEY, ''), '');
    const storedPrice: string = stringValue(store.getSync(PRICE_TEXT_KEY, ''), '');
    const currencyAt: number = storedPrice.indexOf('¥');
    data.priceText = currencyAt >= 0 ? storedPrice.slice(currencyAt) : storedPrice;
    data.locationText = stringValue(store.getSync(LOCATION_TEXT_KEY, data.locationText), data.locationText);
    data.categoryText = stringValue(store.getSync(CATEGORY_TEXT_KEY, data.categoryText), data.categoryText);
    data.photoPath = stringValue(store.getSync(PHOTO_PATH_KEY, ''), '');
    data.photoBucket = stringValue(store.getSync(PHOTO_BUCKET_KEY, ''), '');
    data.coverCardId = stringValue(store.getSync(COVER_CARD_ID_KEY, ''), '');
    data.coverPhotoPath = stringValue(store.getSync(COVER_PHOTO_PATH_KEY, ''), '');
    data.coverPhotoBucket = stringValue(store.getSync(COVER_PHOTO_BUCKET_KEY, ''), '');
    return data;
  }

  private static lease(context: common.Context, formId: string,
    initialDimension?: number): ServiceCardBindingLease {
    const lease: ServiceCardBindingLease = new ServiceCardBindingLease();
    const store: preferences.Preferences = storeFor(context);
    lease.data = ServiceCardStore.read(context, store);
    lease.data.formId = formId;
    lease.data.formDimension = initialDimension === undefined
      ? ServiceCardStore.formDimension(context, formId) : (initialDimension === 3 ? 3 : 2);
    const data: ServiceCardBindingData = lease.data;
    const path: string = stringValue(store.getSync(COVER_FILE_KEY, ''), '');
    if (data.formDimension !== 3 || data.cardId.length === 0 || data.coverCardId !== data.cardId ||
      data.coverPhotoPath !== data.photoPath || data.coverPhotoBucket !== data.photoBucket ||
      !ServiceCardCoverCache.isUsable(context, path)) return lease;
    try {
      lease.file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      // Form Kit refreshes the Image only when the memory image name changes.
      data.coverImageName = `shike_cover_${util.generateRandomUUID().replace(/-/g, '_')}`;
      data.formImages[data.coverImageName] = lease.file.fd;
    } catch (_error) {
      lease.close();
      data.coverImageName = '';
      data.formImages = {};
    }
    return lease;
  }

  private static bind(lease: ServiceCardBindingLease): formBindingData.FormBindingData {
    const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(lease.data);
    if (lease.data.formId.length > 0) {
      const proxies: Array<formBindingData.ProxyData> = [];
      for (const key of REMOTE_PROXY_KEYS) {
        const proxy: formBindingData.ProxyData = { key, subscriberId: lease.data.formId };
        proxies.push(proxy);
      }
      binding.proxies = proxies;
    }
    return binding;
  }

  static bindingData(context: common.Context, formId: string = '',
    initialDimension?: number): formBindingData.FormBindingData {
    const lease: ServiceCardBindingLease = ServiceCardStore.lease(context, formId, initialDimension);
    try {
      const binding: formBindingData.FormBindingData = ServiceCardStore.bind(lease);
      ServiceCardStore.releaseInitialBinding(formId);
      // onAddForm returns before IPC transfers the fd. Retain it until removal/stop.
      ServiceCardStore.initialBindings.set(formId, lease);
      return binding;
    } catch (_error) {
      lease.close();
      throw new Error('桌面卡片摘要绑定失败。');
    }
  }

  static releaseInitialBinding(formId: string): void {
    const lease: ServiceCardBindingLease | undefined = ServiceCardStore.initialBindings.get(formId);
    if (lease !== undefined) lease.close();
    ServiceCardStore.initialBindings.delete(formId);
  }

  static releaseInitialBindings(): void {
    ServiceCardStore.initialBindings.forEach((lease: ServiceCardBindingLease): void => { lease.close(); });
    ServiceCardStore.initialBindings.clear();
  }

  static async updateForm(context: common.Context, formId: string): Promise<void> {
    const lease: ServiceCardBindingLease = ServiceCardStore.lease(context, formId);
    try {
      await formProvider.updateForm(formId, ServiceCardStore.bind(lease));
    } finally {
      // updateForm completion guarantees the descriptor has crossed the process boundary.
      lease.close();
    }
  }

  static formDimension(context: common.Context, formId: string): number {
    const value: preferences.ValueType = dimensionStore(context).getSync(formId || 'preview', 2);
    return value === 3 ? 3 : 2;
  }

  static setFormDimension(context: common.Context, formId: string, dimension: number): void {
    if (formId.length === 0) return;
    const store: preferences.Preferences = dimensionStore(context);
    store.putSync(formId, dimension === 3 ? 3 : 2);
    store.flushSync();
  }

  static formIds(context: common.Context): Array<string> {
    const value: preferences.ValueType = storeFor(context).getSync(FORM_IDS_KEY, []);
    if (!Array.isArray(value)) return [];
    const rawIds: Array<string | number | boolean> = value as Array<string | number | boolean>;
    const ids: Array<string> = [];
    rawIds.forEach((item: string | number | boolean): void => {
      if (typeof item === 'string' && item.length > 0 && !ids.includes(item)) ids.push(item);
    });
    return ids;
  }

  static addFormId(context: common.Context, formId: string): void {
    if (formId.length === 0) return;
    const ids: Array<string> = ServiceCardStore.formIds(context);
    if (!ids.includes(formId)) ids.push(formId);
    const store: preferences.Preferences = storeFor(context);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
  }

  static removeFormId(context: common.Context, formId: string): void {
    ServiceCardStore.releaseInitialBinding(formId);
    const ids: Array<string> = ServiceCardStore.formIds(context)
      .filter((storedId: string): boolean => storedId !== formId);
    const store: preferences.Preferences = storeFor(context);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
    const dimensions: preferences.Preferences = dimensionStore(context);
    dimensions.deleteSync(formId);
    dimensions.flushSync();
  }

  private static async updateAllForms(context: common.Context): Promise<void> {
    for (const formId of ServiceCardStore.formIds(context)) {
      try {
        await ServiceCardStore.updateForm(context, formId);
      } catch (_error) {
        // A removed/unavailable form does not block the recommendation surface.
      }
    }
  }

  private static writeRecommendation(context: common.Context, card: FoodCard): boolean {
    const store: preferences.Preferences = storeFor(context);
    const id: string = card.id.trim();
    store.putSync(CARD_ID_KEY, id);
    store.putSync(PRODUCT_NAME_KEY, card.productName.trim().slice(0, 36) || '附近值得一试');
    store.putSync(SCORE_TEXT_KEY, `${card.tasteScore}/10 好味评分`);
    store.putSync(PRICE_TEXT_KEY, cardPriceText(card));
    store.putSync(LOCATION_TEXT_KEY, (card.merchantAddressSnapshot || card.district).trim().slice(0, 24) || '未关联店铺');
    store.putSync(CATEGORY_TEXT_KEY, foodCardCategoryLabel(card));
    store.putSync(PHOTO_PATH_KEY, card.photoPath.trim());
    store.putSync(PHOTO_BUCKET_KEY, card.photoBucket.trim());
    const oldPath: string = stringValue(store.getSync(COVER_FILE_KEY, ''), '');
    const reusable: boolean = stringValue(store.getSync(COVER_CARD_ID_KEY, ''), '') === id &&
      stringValue(store.getSync(COVER_PHOTO_PATH_KEY, ''), '') === card.photoPath.trim() &&
      stringValue(store.getSync(COVER_PHOTO_BUCKET_KEY, ''), '') === card.photoBucket.trim() &&
      ServiceCardCoverCache.isUsable(context, oldPath);
    if (!reusable) {
      store.putSync(COVER_FILE_KEY, '');
      store.putSync(COVER_CARD_ID_KEY, '');
      store.putSync(COVER_PHOTO_PATH_KEY, '');
      store.putSync(COVER_PHOTO_BUCKET_KEY, '');
    }
    store.flushSync();
    if (!reusable) ServiceCardCoverCache.prune(context, '');
    return reusable;
  }

  static async publishRecommendation(context: common.Context, card: FoodCard): Promise<void> {
    if (card.status !== 'APPROVED' || card.id.trim().length === 0) return;
    const generation: number = ++ServiceCardStore.publicationGeneration;
    // Finish all preference operations before an await can invalidate this process's cache.
    const reusable: boolean = ServiceCardStore.writeRecommendation(context, card);
    // Publish text first; slow/failed image work must not hide the recommendation.
    await ServiceCardStore.updateAllForms(context);
    if (reusable || generation !== ServiceCardStore.publicationGeneration) return;
    let path: string = '';
    try {
      const mayContinue: () => boolean = (): boolean => generation === ServiceCardStore.publicationGeneration;
      path = await ServiceCardCoverCache.prepare(context, card, mayContinue);
      if (path.length === 0) return;
      if (!mayContinue()) {
        ServiceCardCoverCache.remove(context, path);
        return;
      }
      if (!ServiceCardStore.storeCover(context, card, path)) {
        ServiceCardCoverCache.remove(context, path);
        return;
      }
      await ServiceCardStore.updateAllForms(context);
      if (mayContinue()) ServiceCardCoverCache.prune(context, path);
    } catch (_error) {
      // Keep the new text and its honest placeholder when media is unavailable.
      console.warn('Service card cover was not prepared.');
    }
  }

  private static storeCover(context: common.Context, card: FoodCard, path: string): boolean {
    const current: preferences.Preferences = storeFor(context);
    if (stringValue(current.getSync(CARD_ID_KEY, ''), '') !== card.id.trim() ||
      stringValue(current.getSync(PHOTO_PATH_KEY, ''), '') !== card.photoPath.trim() ||
      stringValue(current.getSync(PHOTO_BUCKET_KEY, ''), '') !== card.photoBucket.trim()) return false;
    current.putSync(COVER_FILE_KEY, path);
    current.putSync(COVER_CARD_ID_KEY, card.id.trim());
    current.putSync(COVER_PHOTO_PATH_KEY, card.photoPath.trim());
    current.putSync(COVER_PHOTO_BUCKET_KEY, card.photoBucket.trim());
    current.flushSync();
    return true;
  }
}
