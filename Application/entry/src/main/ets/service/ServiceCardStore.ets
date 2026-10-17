/**
 * 【文件职责】「食刻推荐」桌面卡片（2×2 / 2×4）的数据层：在 App 前台把一张公开卡片的摘要与封面写入本机
 * Preferences 与文件，卡片扩展（ServiceCardFormAbility，可能在另一个进程）只读取这些本地数据，不访问网络。
 * 【数据流】NearbyPage 前台拿到推荐 → publishRecommendation() 先写文字摘要并刷新所有卡片 → 再准备封面
 * （ServiceCardCoverCache）并以内存图片的形式绑定给 Form Kit。卡片被删除/下架或图片授权撤销时，revokePublished() 清掉封面。
 * 【新人注意】Form Kit 只有在“内存图片名”变化时才会刷新图片，所以每次换图都会生成新的图片名；
 * 传给 Form Kit 的文件描述符要保持打开直到卡片移除或更新完成。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { foodCardCategoryLabel } from '../components/FoodCover';
import { ImageDescriptors } from './ImageDescriptors';
import { ImageDescriptor } from '../model/ImageModels';
import { FormCoverImage, ServiceCardCoverCache } from './ServiceCardCoverCache';

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
const PHOTO_VERSION_KEY: string = 'photo_version';
const COVER_VERSION_KEY: string = 'cover_version';
const COVER_FILE_KEY: string = 'cover_file';
const COVER_CARD_ID_KEY: string = 'cover_card_id';
const COVER_PHOTO_PATH_KEY: string = 'cover_photo_path';
const COVER_PHOTO_BUCKET_KEY: string = 'cover_photo_bucket';
const REMOTE_PROXY_KEYS: Array<string> = [
  'cardId', 'productName', 'scoreText', 'priceText', 'locationText', 'categoryText', 'photoPath', 'photoBucket'
];

// 传给卡片页面（ServiceCard.ets 的 @LocalStorageProp）的数据，字段名必须与卡片页面一致。
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

// 一次图片绑定的“租约”：持有封面文件的描述符，直到 Form Kit 确认收到后再关闭。
class ServiceCardBindingLease {
  data: ServiceCardBindingData = new ServiceCardBindingData();
  file: fileIo.File | undefined = undefined;

  // 关闭封面文件描述符。
  close(): void {
    ServiceCardCoverCache.closeFile(this.file);
    this.file = undefined;
  }
}

// 打开卡片数据存储。
function storeFor(context: common.Context): preferences.Preferences {
  // App 与卡片扩展可能运行在不同进程，每次都清掉进程内缓存后重新读取。
  preferences.removePreferencesFromCacheSync(context, STORE_OPTIONS);
  return preferences.getPreferencesSync(context, STORE_OPTIONS);
}

// 打开卡片尺寸记录存储（记录每个卡片实例是 2×2 还是 2×4）。
function dimensionStore(context: common.Context): preferences.Preferences {
  preferences.removePreferencesFromCacheSync(context, DIMENSION_OPTIONS);
  return preferences.getPreferencesSync(context, DIMENSION_OPTIONS);
}

// 读取字符串值，类型不符时返回默认值。
function stringValue(value: preferences.ValueType, fallback: string): string {
  return typeof value === 'string' ? value : fallback;
}

// 桌面推荐卡片数据（静态类）。
export class ServiceCardStore {
  private static publicationGeneration: number = 0;
  private static initialBindings: Map<string, ServiceCardBindingLease> =
    new Map<string, ServiceCardBindingLease>();

  // 撤销已发布的封面（mediaId 为空表示全部）：图片授权被撤销或卡片不可见时调用。
  static revokePublished(context: common.Context, mediaId: string = ''): void {
    const store: preferences.Preferences = storeFor(context);
    const photoPath: string = stringValue(store.getSync(PHOTO_PATH_KEY, ''), '');
    if (mediaId.length > 0 && !photoPath.endsWith('/' + mediaId + '.jpg')) return;
    ServiceCardStore.publicationGeneration++;
    for (const key of [CARD_ID_KEY, PRODUCT_NAME_KEY, SCORE_TEXT_KEY, PRICE_TEXT_KEY, LOCATION_TEXT_KEY, CATEGORY_TEXT_KEY, PHOTO_PATH_KEY, PHOTO_BUCKET_KEY, COVER_FILE_KEY, COVER_CARD_ID_KEY, COVER_PHOTO_PATH_KEY, COVER_PHOTO_BUCKET_KEY, PHOTO_VERSION_KEY, COVER_VERSION_KEY]) store.putSync(key, '');
    store.flushSync(); ServiceCardStore.releaseInitialBindings(); ServiceCardCoverCache.prune(context, '');
    void ServiceCardStore.updateAllForms(context).catch((): void => {});
  }

  // 读取当前要展示的卡片数据。
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

  // 为某个卡片实例创建一份绑定租约（读取数据并打开封面文件）。
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
      stringValue(store.getSync(PHOTO_VERSION_KEY, ''), '').length === 0 || store.getSync(PHOTO_VERSION_KEY, '') !== store.getSync(COVER_VERSION_KEY, '') ||
      !ServiceCardCoverCache.isUsable(context, path)) return lease;
    const cover: FormCoverImage | undefined = ServiceCardCoverCache.openFormImage(path, 'shike_cover_');
    if (cover !== undefined) {
      lease.file = cover.file;
      data.coverImageName = cover.imageName;
      data.formImages[cover.imageName] = cover.file.fd;
    }
    return lease;
  }

  // 把租约转换为 Form Kit 的绑定数据（文字 + 内存图片）。
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

  // 生成某卡片实例的绑定数据（onAddForm 时使用，初始租约要保留到卡片移除或扩展停止）。
  static bindingData(context: common.Context, formId: string = '',
    initialDimension?: number): formBindingData.FormBindingData {
    const lease: ServiceCardBindingLease = ServiceCardStore.lease(context, formId, initialDimension);
    try {
      const binding: formBindingData.FormBindingData = ServiceCardStore.bind(lease);
      ServiceCardStore.releaseInitialBinding(formId);
      // onAddForm 返回时文件描述符还没有通过 IPC 传过去，要保留到卡片移除或扩展停止。
      ServiceCardStore.initialBindings.set(formId, lease);
      return binding;
    } catch (_error) {
      lease.close();
      throw new Error('桌面卡片摘要绑定失败。');
    }
  }

  // 释放某卡片实例的初始绑定租约。
  static releaseInitialBinding(formId: string): void {
    const lease: ServiceCardBindingLease | undefined = ServiceCardStore.initialBindings.get(formId);
    if (lease !== undefined) lease.close();
    ServiceCardStore.initialBindings.delete(formId);
  }

  // 释放所有初始绑定租约（扩展停止时）。
  static releaseInitialBindings(): void {
    ServiceCardStore.initialBindings.forEach((lease: ServiceCardBindingLease): void => { lease.close(); });
    ServiceCardStore.initialBindings.clear();
  }

  // 用最新数据刷新某个卡片实例。
  static async updateForm(context: common.Context, formId: string): Promise<void> {
    const lease: ServiceCardBindingLease = ServiceCardStore.lease(context, formId);
    try {
      await formProvider.updateForm(formId, ServiceCardStore.bind(lease));
    } finally {
      // updateForm 完成即保证描述符已跨进程传递，可以关闭。
      lease.close();
    }
  }

  // 读取卡片实例的尺寸。
  static formDimension(context: common.Context, formId: string): number {
    const value: preferences.ValueType = dimensionStore(context).getSync(formId || 'preview', 2);
    return value === 3 ? 3 : 2;
  }

  // 记录卡片实例的尺寸（2×2 或 2×4）。
  static setFormDimension(context: common.Context, formId: string, dimension: number): void {
    if (formId.length === 0) return;
    const store: preferences.Preferences = dimensionStore(context);
    store.putSync(formId, dimension === 3 ? 3 : 2);
    store.flushSync();
  }

  // 本机已添加的全部卡片实例 id。
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

  // 记录新添加的卡片实例 id。
  static addFormId(context: common.Context, formId: string): void {
    if (formId.length === 0) return;
    const ids: Array<string> = ServiceCardStore.formIds(context);
    if (!ids.includes(formId)) ids.push(formId);
    const store: preferences.Preferences = storeFor(context);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
  }

  // 移除卡片实例 id（同时释放租约与尺寸记录）。
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

  // 刷新所有卡片实例。
  private static async updateAllForms(context: common.Context): Promise<void> {
    for (const formId of ServiceCardStore.formIds(context)) {
      try {
        await ServiceCardStore.updateForm(context, formId);
      } catch (_error) {
        // 某个卡片已删除或不可用时，不影响其他卡片刷新。
      }
    }
  }

  // 封面版本标识（mediaId + 内容版本），用于判断是否需要换图。
  private static coverVersion(card: FoodCard): string {
    const id: string = card.photos?.[0]?.id || card.photoPath.split('/').pop()?.replace('.jpg', '') || '';
    const permit: ImageDescriptor | undefined = ImageDescriptors.read(id, 'PUBLIC', 'COVER_480');
    return permit === undefined ? '' : permit.variant + ':' + permit.sha256;
  }

  // 写入一张推荐卡片的文字摘要；内容未变化时返回 false。
  private static writeRecommendation(context: common.Context, card: FoodCard): boolean {
    const store: preferences.Preferences = storeFor(context);
    const id: string = card.id.trim(); const version: string = ServiceCardStore.coverVersion(card);
    store.putSync(PHOTO_VERSION_KEY, version);
    store.putSync(CARD_ID_KEY, id);
    store.putSync(PRODUCT_NAME_KEY, card.productName.trim().slice(0, 36) || '附近值得一试');
    store.putSync(SCORE_TEXT_KEY, `${card.tasteScore}/10 好味评分`);
    store.putSync(PRICE_TEXT_KEY, cardPriceText(card));
    store.putSync(LOCATION_TEXT_KEY, (card.merchantAddressSnapshot || card.district).trim().slice(0, 24) || '未关联店铺');
    store.putSync(CATEGORY_TEXT_KEY, foodCardCategoryLabel(card));
    store.putSync(PHOTO_PATH_KEY, card.photoPath.trim());
    store.putSync(PHOTO_BUCKET_KEY, card.photoBucket.trim());
    const oldPath: string = stringValue(store.getSync(COVER_FILE_KEY, ''), '');
    const reusable: boolean = version.length > 0 && store.getSync(COVER_VERSION_KEY, '') === version && stringValue(store.getSync(COVER_CARD_ID_KEY, ''), '') === id &&
      stringValue(store.getSync(COVER_PHOTO_PATH_KEY, ''), '') === card.photoPath.trim() &&
      stringValue(store.getSync(COVER_PHOTO_BUCKET_KEY, ''), '') === card.photoBucket.trim() &&
      ServiceCardCoverCache.isUsable(context, oldPath);
    if (!reusable) {
      store.putSync(COVER_VERSION_KEY, '');
      store.putSync(COVER_FILE_KEY, '');
      store.putSync(COVER_CARD_ID_KEY, '');
      store.putSync(COVER_PHOTO_PATH_KEY, '');
      store.putSync(COVER_PHOTO_BUCKET_KEY, '');
    }
    store.flushSync();
    if (!reusable) ServiceCardCoverCache.prune(context, '');
    return reusable;
  }

  // 发布推荐到桌面卡片：只接受已公开（APPROVED）的卡片；先写文字并刷新，再在后台准备封面。
  static async publishRecommendation(context: common.Context, card: FoodCard): Promise<void> {
    if (card.status !== 'APPROVED' || card.id.trim().length === 0) return;
    const generation: number = ++ServiceCardStore.publicationGeneration;
    // 在任何 await 之前完成所有 Preferences 操作，避免进程内缓存在等待期间失效。
    const reusable: boolean = ServiceCardStore.writeRecommendation(context, card);
    // 先发布文字：图片慢或失败都不能导致推荐内容不显示。
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
      // 图片不可用时保留新的文字，并如实显示占位图。
      console.warn('Service card cover was not prepared.');
    }
  }

  // 记录已准备好的封面文件路径（期间若推荐已换成别的卡片则放弃）。
  private static storeCover(context: common.Context, card: FoodCard, path: string): boolean {
    const current: preferences.Preferences = storeFor(context);
    if (stringValue(current.getSync(CARD_ID_KEY, ''), '') !== card.id.trim() ||
      stringValue(current.getSync(PHOTO_PATH_KEY, ''), '') !== card.photoPath.trim() ||
      stringValue(current.getSync(PHOTO_BUCKET_KEY, ''), '') !== card.photoBucket.trim()) return false;
    const version: string = ServiceCardStore.coverVersion(card);
    const expected: string = stringValue(current.getSync(PHOTO_VERSION_KEY, ''), '');
    if (version.length === 0 || expected.length > 0 && expected !== version) return false;
    current.putSync(PHOTO_VERSION_KEY, version);
    current.putSync(COVER_VERSION_KEY, version);
    current.putSync(COVER_FILE_KEY, path);
    current.putSync(COVER_CARD_ID_KEY, card.id.trim());
    current.putSync(COVER_PHOTO_PATH_KEY, card.photoPath.trim());
    current.putSync(COVER_PHOTO_BUCKET_KEY, card.photoBucket.trim());
    current.flushSync();
    return true;
  }
}
