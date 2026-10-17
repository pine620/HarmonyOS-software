import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import util from '@ohos.util';
import { FoodCard } from '../model/CloudContracts';
import { RandomFoodCards, RandomFoodCardsRequest, RandomFoodPool, RandomFoodPoolRequest,
  RandomFoodSource } from '../model/RandomFoodModels';
import { RandomFoodRepository } from '../repository/RandomFoodRepository';
import { AccountRequestGuard } from './AccountRequestGuard';
import { AuthSessionStore } from './AuthSessionStore';
import { RandomFoodRoundStore } from './RandomFoodRoundStore';
import { FormCoverImage, ServiceCardCoverCache } from './ServiceCardCoverCache';
import { ReadRequestOptions } from './ReadScheduler';

/**
 * 【文件职责】「今日吃什么」2×2 桌面卡片的数据层。卡片在本机的小候选池里“翻牌”，卡片生命周期回调从不访问网络；
 * App 在前台负责刷新候选池：每天一次、账号或「今日吃什么」来源变化时，或者候选池为空时最多每 30 分钟一次。
 * 这里不会写入任何“选择记录”（选择记录只在 RandomFoodPage 中由用户确认后保存）。
 * 【链路位置】RandomFoodFormAbility（卡片扩展）读取 / 翻牌；RandomFoodPage、Index 在前台调用 sync() 刷新候选。
 */
const STORE_OPTIONS: preferences.Options = { name: 'shike_random_food_widget' };
const COVER_FOLDER: string = 'shike-random-food-widget-covers';
const POOL_TARGET: number = 12;
const POOL_ID_LIMIT: number = 24;
const EMPTY_RETRY_MS: number = 30 * 60 * 1000;
const FORM_IDS_KEY: string = 'form_ids';
const OWNER_KEY: string = 'owner';
const SOURCE_KEY: string = 'source';
const DAY_KEY: string = 'prepared_day';
const CHECKED_AT_KEY: string = 'checked_at';
const DISHES_KEY: string = 'dishes';
const INDEX_KEY: string = 'index';
const LOOPED_KEY: string = 'looped';
export const RANDOM_FOOD_WIDGET_FLIP_MESSAGE: string = 'flip-random-food-widget';

// 卡片上展示的一道菜（来自候选卡片的摘要与本机封面文件）。
export interface RandomFoodWidgetDish {
  cardId: string;
  name: string;
  place: string;
  score: number;
  coverFile: string;
}

// 卡片内按钮事件参数。
interface RandomFoodWidgetEventParams {
  message: string;
}

// 字段名必须与 randomfoodcard/pages/RandomFoodCard.ets 中 @LocalStorageProp 的名称一致。
export class RandomFoodWidgetBindingData {
  formId: string = '';
  state: string = 'EMPTY';
  cardId: string = '';
  dishName: string = '';
  dishMeta: string = '';
  sourceLabel: string = '';
  looped: boolean = false;
  emptyTitle: string = '还没有候选菜';
  emptyHint: string = '打开食刻准备几道菜';
  coverImageName: string = '';
  formImages: Record<string, number> = {};
}

// 一次图片绑定的租约（持有封面文件描述符直到 Form Kit 收到）。
class RandomFoodWidgetLease {
  data: RandomFoodWidgetBindingData = new RandomFoodWidgetBindingData();
  file: fileIo.File | undefined = undefined;

  // 关闭封面文件描述符。
  close(): void {
    ServiceCardCoverCache.closeFile(this.file);
    this.file = undefined;
  }
}

// 打开卡片数据存储。
function storeFor(context: common.Context): preferences.Preferences {
  // App 与卡片扩展可能运行在不同进程，每次读取前清掉进程内缓存。
  preferences.removePreferencesFromCacheSync(context, STORE_OPTIONS);
  return preferences.getPreferencesSync(context, STORE_OPTIONS);
}

// 读取字符串值（类型不符时返回默认值）。
function stringValue(value: preferences.ValueType, fallback: string): string {
  return typeof value === 'string' ? value : fallback;
}

// 读取数字值（类型不符时返回默认值）。
function numberValue(value: preferences.ValueType, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

// 今天的日期字符串（用于“每天刷新一次”的判断）。
function today(): string {
  const now: Date = new Date();
  return `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
}

// 候选来源的中文名称。
function sourceLabel(source: string): string {
  return source === 'MY' ? '我的收藏' : source === 'FRIENDS' ? '好友推荐' : '公开推荐';
}

// 候选为空时卡片上显示的标题。
function emptyTitle(source: string, prepared: boolean): string {
  if (!prepared) return '还没有候选菜';
  return source === 'MY' ? '收藏里还没有菜' : source === 'FRIENDS' ? '好友还没有可翻的菜' : '暂时没有可翻的菜';
}

// 校验从存储中读出的一道菜数据是否完整。
function validDish(value: RandomFoodWidgetDish): boolean {
  return value !== null && typeof value === 'object' && typeof value.cardId === 'string' &&
    /^[A-Za-z0-9:_-]{1,160}$/.test(value.cardId) && typeof value.name === 'string' &&
    typeof value.place === 'string' && typeof value.score === 'number' && typeof value.coverFile === 'string';
}

// 「今日吃什么」桌面卡片数据（静态类）。
export class RandomFoodWidgetStore {
  private static refreshing: Promise<void> | undefined = undefined;
  private static initialBindings: Map<string, RandomFoodWidgetLease> = new Map<string, RandomFoodWidgetLease>();

  // 判断卡片事件是否为“翻牌”消息。
  static isFlipMessage(message: string): boolean {
    if (message === RANDOM_FOOD_WIDGET_FLIP_MESSAGE) return true;
    try {
      const params: RandomFoodWidgetEventParams = JSON.parse(message) as RandomFoodWidgetEventParams;
      return params !== null && typeof params === 'object' && params.message === RANDOM_FOOD_WIDGET_FLIP_MESSAGE;
    } catch (_error) {
      return false;
    }
  }

  // 候选池所属身份：未登录为 guest，登录为 user:{uid}。
  private static owner(): string {
    const uid: string = AccountRequestGuard.owner();
    return uid.length === 0 ? 'guest' : 'user:' + uid;
  }

  // 读取本地候选池。
  private static dishes(store: preferences.Preferences): Array<RandomFoodWidgetDish> {
    try {
      const parsed: Object = JSON.parse(stringValue(store.getSync(DISHES_KEY, '[]'), '[]')) as Object;
      if (!Array.isArray(parsed)) return [];
      return (parsed as Array<RandomFoodWidgetDish>).filter((dish: RandomFoodWidgetDish): boolean => validDish(dish));
    } catch (_error) {
      return [];
    }
  }

  // ---- 卡片生命周期部分（不访问网络）----

  // 本机已添加的卡片实例 id 列表。
  static formIds(context: common.Context): Array<string> {
    const value: preferences.ValueType = storeFor(context).getSync(FORM_IDS_KEY, []);
    if (!Array.isArray(value)) return [];
    const ids: Array<string> = [];
    (value as Array<string | number | boolean>).forEach((item: string | number | boolean): void => {
      if (typeof item === 'string' && item.length > 0 && !ids.includes(item)) ids.push(item);
    });
    return ids;
  }

  // 记录新添加的卡片实例。
  static addFormId(context: common.Context, formId: string): void {
    if (formId.length === 0) return;
    const ids: Array<string> = RandomFoodWidgetStore.formIds(context);
    if (ids.includes(formId)) return;
    ids.push(formId);
    const store: preferences.Preferences = storeFor(context);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
  }

  // 移除卡片实例（同时释放租约）。
  static removeFormId(context: common.Context, formId: string): void {
    RandomFoodWidgetStore.releaseInitialBinding(formId);
    const ids: Array<string> = RandomFoodWidgetStore.formIds(context).filter((id: string): boolean => id !== formId);
    const store: preferences.Preferences = storeFor(context);
    store.putSync(FORM_IDS_KEY, ids);
    store.flushSync();
  }

  // 为卡片实例创建绑定租约（读取当前菜品与封面）。
  private static lease(context: common.Context, formId: string): RandomFoodWidgetLease {
    const lease: RandomFoodWidgetLease = new RandomFoodWidgetLease();
    const store: preferences.Preferences = storeFor(context);
    const data: RandomFoodWidgetBindingData = lease.data;
    data.formId = formId;
    const source: string = stringValue(store.getSync(SOURCE_KEY, ''), '');
    const dishes: Array<RandomFoodWidgetDish> = RandomFoodWidgetStore.dishes(store);
    data.sourceLabel = sourceLabel(source);
    data.emptyTitle = emptyTitle(source, stringValue(store.getSync(DAY_KEY, ''), '').length > 0);
    if (dishes.length === 0) return lease;
    const index: number = Math.min(Math.max(0, Math.floor(numberValue(store.getSync(INDEX_KEY, 0), 0))), dishes.length - 1);
    const dish: RandomFoodWidgetDish = dishes[index];
    data.state = 'DISH';
    data.cardId = dish.cardId;
    data.dishName = dish.name;
    const parts: Array<string> = [];
    if (dish.place.length > 0) parts.push(dish.place);
    if (Number.isInteger(dish.score) && dish.score >= 1 && dish.score <= 10) parts.push(`口味 ${dish.score}/10`);
    data.dishMeta = parts.join(' · ');
    data.looped = store.getSync(LOOPED_KEY, false) === true;
    if (!ServiceCardCoverCache.isUsable(context, dish.coverFile, COVER_FOLDER)) return lease;
    const cover: FormCoverImage | undefined = ServiceCardCoverCache.openFormImage(dish.coverFile, 'shike_food_');
    if (cover !== undefined) {
      lease.file = cover.file;
      data.coverImageName = cover.imageName;
      data.formImages[cover.imageName] = cover.file.fd;
    }
    return lease;
  }

  // 生成卡片实例的绑定数据（onAddForm 时使用）。
  static bindingData(context: common.Context, formId: string): formBindingData.FormBindingData {
    const lease: RandomFoodWidgetLease = RandomFoodWidgetStore.lease(context, formId);
    try {
      const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(lease.data);
      RandomFoodWidgetStore.releaseInitialBinding(formId);
      // onAddForm 返回时描述符还没跨进程传过去，要保留到卡片移除或扩展停止。
      RandomFoodWidgetStore.initialBindings.set(formId, lease);
      return binding;
    } catch (_error) {
      lease.close();
      throw new Error('今日吃什么卡片绑定失败。');
    }
  }

  // 释放某卡片实例的初始租约。
  static releaseInitialBinding(formId: string): void {
    const lease: RandomFoodWidgetLease | undefined = RandomFoodWidgetStore.initialBindings.get(formId);
    if (lease !== undefined) lease.close();
    RandomFoodWidgetStore.initialBindings.delete(formId);
  }

  // 释放所有初始租约。
  static releaseInitialBindings(): void {
    RandomFoodWidgetStore.initialBindings.forEach((lease: RandomFoodWidgetLease): void => { lease.close(); });
    RandomFoodWidgetStore.initialBindings.clear();
  }

  // 刷新某个卡片实例。
  static async updateForm(context: common.Context, formId: string): Promise<void> {
    const lease: RandomFoodWidgetLease = RandomFoodWidgetStore.lease(context, formId);
    try {
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(lease.data));
    } finally {
      lease.close();
    }
  }

  // 刷新所有卡片实例。
  static async updateAllForms(context: common.Context): Promise<void> {
    for (const formId of RandomFoodWidgetStore.formIds(context)) {
      try {
        await RandomFoodWidgetStore.updateForm(context, formId);
      } catch (_error) {
        // 某个卡片已删除或不可用时不影响其他卡片。
      }
    }
  }

  // 翻到本地候选池中的下一道菜；翻完后从头循环，并在卡片上提示“换一批”。
  static async flip(context: common.Context): Promise<void> {
    const store: preferences.Preferences = storeFor(context);
    const dishes: Array<RandomFoodWidgetDish> = RandomFoodWidgetStore.dishes(store);
    if (dishes.length > 0) {
      const index: number = Math.floor(numberValue(store.getSync(INDEX_KEY, 0), 0));
      const next: number = index + 1 >= dishes.length ? 0 : index + 1;
      store.putSync(INDEX_KEY, next);
      if (next === 0) store.putSync(LOOPED_KEY, true);
      store.flushSync();
    }
    await RandomFoodWidgetStore.updateAllForms(context);
  }

  // ---- App 前台部分（允许访问网络）----

  // 立即清空所有候选（退出登录、换号、注销时调用）。
  static async clear(context: common.Context): Promise<void> {
    const store: preferences.Preferences = storeFor(context);
    for (const key of [OWNER_KEY, SOURCE_KEY, DAY_KEY, DISHES_KEY]) store.putSync(key, '');
    store.putSync(CHECKED_AT_KEY, 0);
    store.putSync(INDEX_KEY, 0);
    store.putSync(LOOPED_KEY, false);
    store.flushSync();
    ServiceCardCoverCache.pruneExcept(context, [], COVER_FOLDER);
    await RandomFoodWidgetStore.updateAllForms(context);
  }

  // 前台同步：按需刷新候选池（账号/来源变化、跨天、空池超过 30 分钟）。
  static async sync(context: common.Context): Promise<void> {
    const owner: string = RandomFoodWidgetStore.owner();
    const source: RandomFoodSource = owner === 'guest' ? 'PUBLIC' : RandomFoodRoundStore.selectedSource(context, owner);
    const store: preferences.Preferences = storeFor(context);
    const storedOwner: string = stringValue(store.getSync(OWNER_KEY, ''), '');
    // 绝不显示其他账号（或已退出账号）的私人候选，哪怕一瞬间也不行。
    if (storedOwner.length > 0 && storedOwner !== owner) await RandomFoodWidgetStore.clear(context);
    if (RandomFoodWidgetStore.formIds(context).length === 0) return;
    const fresh: preferences.Preferences = storeFor(context);
    const dishes: Array<RandomFoodWidgetDish> = RandomFoodWidgetStore.dishes(fresh);
    const sameScope: boolean = stringValue(fresh.getSync(OWNER_KEY, ''), '') === owner &&
      stringValue(fresh.getSync(SOURCE_KEY, ''), '') === source;
    const sameDay: boolean = stringValue(fresh.getSync(DAY_KEY, ''), '') === today();
    const checkedAt: number = numberValue(fresh.getSync(CHECKED_AT_KEY, 0), 0);
    if (sameScope && sameDay && (dishes.length > 0 || Date.now() - checkedAt < EMPTY_RETRY_MS)) return;
    const running: Promise<void> | undefined = RandomFoodWidgetStore.refreshing;
    if (running !== undefined) { await running; return; }
    const task: Promise<void> = RandomFoodWidgetStore.refresh(context, owner, source)
      .catch((_error: Object): void => { console.warn('[RandomFoodWidget] pool refresh deferred'); })
      .finally((): void => { RandomFoodWidgetStore.refreshing = undefined; });
    RandomFoodWidgetStore.refreshing = task;
    await task;
  }

  // 从云端读取候选池与卡片内容，准备封面后写入本地并刷新所有卡片；期间账号或会话变化则放弃。
  private static async refresh(context: common.Context, owner: string, source: RandomFoodSource): Promise<void> {
    const session: number = AuthSessionStore.generation();
    const current: () => boolean = (): boolean =>
      RandomFoodWidgetStore.owner() === owner && AuthSessionStore.generation() === session;
    const options: ReadRequestOptions = { priority: 'secondary', mayContinue: async (): Promise<boolean> => current() };
    const repo: RandomFoodRepository = new RandomFoodRepository();
    const poolRequest: RandomFoodPoolRequest = { source, roundId: util.generateRandomUUID() };
    const pool: RandomFoodPool = await repo.pool(poolRequest, options);
    if (!current()) return;
    if (pool.source !== source || !Array.isArray(pool.cardIds) || pool.cardIds.length > 60 ||
      !pool.cardIds.every((id: string): boolean => typeof id === 'string' && /^[A-Za-z0-9:_-]{1,160}$/.test(id))) {
      throw new Error('候选池响应无效。');
    }
    const ids: Array<string> = pool.cardIds.slice(0, POOL_ID_LIMIT);
    const drawId: string = util.generateRandomUUID();
    const cards: Array<FoodCard> = [];
    for (let start = 0; start < ids.length && cards.length < POOL_TARGET; start += 3) {
      const request: RandomFoodCardsRequest = { source, drawId, cardIds: ids.slice(start, start + 3) };
      const page: RandomFoodCards = await repo.cards(request, options);
      if (!current()) return;
      for (const card of page.cards) {
        if (cards.length < POOL_TARGET && card.status === 'APPROVED') cards.push(card);
      }
    }
    const dishes: Array<RandomFoodWidgetDish> = [];
    for (const card of cards) {
      let coverFile: string = '';
      try {
        coverFile = await ServiceCardCoverCache.prepare(context, card, current, COVER_FOLDER);
      } catch (_error) {
        coverFile = '';
      }
      if (!current()) {
        if (coverFile.length > 0) ServiceCardCoverCache.remove(context, coverFile, COVER_FOLDER);
        return;
      }
      const placeSource: string = card.merchantNameSnapshot || card.shop || card.district || '';
      const place: string = placeSource.trim().slice(0, 20);
      const dish: RandomFoodWidgetDish = {
        cardId: card.id.trim(), name: card.productName.trim().slice(0, 24) || '一道好味', place,
        score: card.tasteScore, coverFile
      };
      dishes.push(dish);
    }
    const store: preferences.Preferences = storeFor(context);
    store.putSync(OWNER_KEY, owner);
    store.putSync(SOURCE_KEY, source);
    store.putSync(DAY_KEY, today());
    store.putSync(CHECKED_AT_KEY, Date.now());
    store.putSync(DISHES_KEY, JSON.stringify(dishes));
    store.putSync(INDEX_KEY, 0);
    store.putSync(LOOPED_KEY, false);
    store.flushSync();
    ServiceCardCoverCache.pruneExcept(context,
      dishes.map((dish: RandomFoodWidgetDish): string => dish.coverFile).filter((path: string): boolean => path.length > 0),
      COVER_FOLDER);
    await RandomFoodWidgetStore.updateAllForms(context);
  }
}
