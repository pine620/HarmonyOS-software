import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { FoodCard } from '../model/CloudContracts';

const STORE_NAME: string = 'shike_service_card';
const FORM_IDS_KEY: string = 'form_ids';
const CARD_ID_KEY: string = 'card_id';
const PRODUCT_NAME_KEY: string = 'product_name';
const SCORE_TEXT_KEY: string = 'score_text';
const PRICE_TEXT_KEY: string = 'price_text';
const LOCATION_TEXT_KEY: string = 'location_text';
const CATEGORY_TEXT_KEY: string = 'category_text';
const REMOTE_PROXY_KEYS: Array<string> = [
  'cardId', 'productName', 'scoreText', 'priceText', 'locationText', 'categoryText'
];

export class ServiceCardBindingData {
  formId: string = '';
  cardId: string = '';
  productName: string = '附近值得一试';
  scoreText: string = '实拍推荐';
  priceText: string = '打开食刻发现好味道';
  locationText: string = '20 km 内';
  categoryText: string = '附近';
}

function stringValue(value: preferences.ValueType, fallback: string): string {
  return typeof value === 'string' ? value : fallback;
}

function categoryLabel(category: string): string {
  if (category === 'staple') return '米饭';
  if (category === 'bakery') return '汤粉';
  if (category === 'snack') return '炸鸡';
  if (category === 'fresh') return '烧烤';
  if (category === 'drink') return '饮品';
  return '其他';
}

function cardPriceText(card: FoodCard): string {
  if (card.priceFen <= 0) return '价格待补充';
  return `¥${(card.priceFen / 100).toFixed(2)}`;
}

export class ServiceCardStore {
  static read(context: common.Context): ServiceCardBindingData {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const data: ServiceCardBindingData = new ServiceCardBindingData();
    data.cardId = stringValue(store.getSync(CARD_ID_KEY, ''), '');
    data.productName = stringValue(store.getSync(PRODUCT_NAME_KEY, data.productName), data.productName);
    data.scoreText = stringValue(store.getSync(SCORE_TEXT_KEY, data.scoreText), data.scoreText);
    const storedPrice: string = stringValue(store.getSync(PRICE_TEXT_KEY, data.priceText), data.priceText);
    const currencyAt: number = storedPrice.indexOf('¥');
    data.priceText = currencyAt >= 0 ? storedPrice.slice(currencyAt) : storedPrice;
    data.locationText = stringValue(store.getSync(LOCATION_TEXT_KEY, data.locationText), data.locationText);
    data.categoryText = stringValue(store.getSync(CATEGORY_TEXT_KEY, data.categoryText), data.categoryText);
    return data;
  }

  static bindingData(context: common.Context, formId: string = ''): formBindingData.FormBindingData {
    const data: ServiceCardBindingData = ServiceCardStore.read(context);
    data.formId = formId;
    const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(data);
    if (formId.length > 0) {
      const proxies: Array<formBindingData.ProxyData> = [];
      for (const key of REMOTE_PROXY_KEYS) {
        proxies.push({ key, subscriberId: formId });
      }
      binding.proxies = proxies;
    }
    return binding;
  }

  static formIds(context: common.Context): Array<string> {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const value: preferences.ValueType = store.getSync(FORM_IDS_KEY, []);
    if (!Array.isArray(value)) return [];
    const rawIds: Array<string> = value as Array<string>;
    const ids: Array<string> = [];
    rawIds.forEach((item: string): void => {
      if (item.length > 0 && !ids.includes(item)) ids.push(item);
    });
    return ids;
  }

  static addFormId(context: common.Context, formId: string): void {
    if (formId.length === 0) return;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const ids: Array<string> = ServiceCardStore.formIds(context);
    if (!ids.includes(formId)) ids.push(formId);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
  }

  static removeFormId(context: common.Context, formId: string): void {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const ids: Array<string> = ServiceCardStore.formIds(context)
      .filter((storedId: string): boolean => storedId !== formId);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
  }

  static async publishRecommendation(context: common.Context, card: FoodCard): Promise<void> {
    if (card.status !== 'APPROVED' || card.id.trim().length === 0) return;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.putSync(CARD_ID_KEY, card.id.trim());
    store.putSync(PRODUCT_NAME_KEY, card.productName.trim().slice(0, 36) || '附近值得一试');
    store.putSync(SCORE_TEXT_KEY, `${card.tasteScore}/10 好味评分`);
    store.putSync(PRICE_TEXT_KEY, cardPriceText(card));
    store.putSync(LOCATION_TEXT_KEY, card.district.trim().slice(0, 24) || '20 km 内');
    store.putSync(CATEGORY_TEXT_KEY, categoryLabel(card.category));
    store.flushSync();
    const ids: Array<string> = ServiceCardStore.formIds(context);
    for (const formId of ids) {
      try {
        await formProvider.updateForm(formId, ServiceCardStore.bindingData(context, formId));
      } catch (_error) {
        // A removed or temporarily unavailable form must not block the app's
        // recommendation refresh. onRemoveForm owns persistent ID cleanup.
      }
    }
  }
}
