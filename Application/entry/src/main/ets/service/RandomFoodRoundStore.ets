/**
 * 【文件职责】「今日吃什么」当前轮次的本机保存（Preferences: shike_random_food_rounds）。
 * 按“账号 + 来源（我的收藏 / 公开推荐 / 好友推荐）”分别保存翻到的三张卡片、是否已选择等，
 * App 重启或返回页面时可以恢复；读出时会校验格式，异常数据直接丢弃。还保存用户选择的来源与动画开关。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { RandomFoodRound, RandomFoodSource, copyRandomFoodRound } from '../model/RandomFoodModels';

// 今日吃什么轮次存储（静态类）。
export class RandomFoodRoundStore {
  // 打开轮次存储。
  private static store(context: common.Context): preferences.Preferences {
    const options: preferences.Options = { name: 'shike_random_food_rounds' };
    return preferences.getPreferencesSync(context, options);
  }
  // 轮次的存储键。
  private static key(owner: string, source: RandomFoodSource): string { return 'round:' + owner + ':' + source; }
  // 校验 UUID 格式。
  private static uuid(value: string): boolean {
    return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
  }
  // 校验 id 数组（最多 60 个且不重复）。
  private static ids(value: Array<string>): boolean {
    return Array.isArray(value) && value.length <= 60 && new Set<string>(value).size === value.length &&
      value.every((id: string): boolean => typeof id === 'string' && /^[A-Za-z0-9:_-]{1,160}$/.test(id));
  }
  // 读取某账号某来源的当前轮次；格式不合法返回 undefined。
  static read(context: common.Context, owner: string, source: RandomFoodSource): RandomFoodRound | undefined {
    const raw: preferences.ValueType = RandomFoodRoundStore.store(context).getSync(RandomFoodRoundStore.key(owner, source), '');
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 32768) return undefined;
    try {
      const value: RandomFoodRound = JSON.parse(raw) as RandomFoodRound;
      if (value === null || value.version !== 1 || value.owner !== owner || value.source !== source ||
        !RandomFoodRoundStore.uuid(value.roundId) ||
        !RandomFoodRoundStore.ids(value.cardIds) || !RandomFoodRoundStore.ids(value.batchIds) || value.batchIds.length > 3 ||
        !Number.isSafeInteger(value.position) || value.position < 0 || value.position > value.cardIds.length ||
        !Number.isSafeInteger(value.shownCount) || value.shownCount < 0 || value.shownCount > value.position || value.shownCount % 3 !== 0 ||
        !value.batchIds.every((id: string): boolean => value.cardIds.slice(0, value.position).includes(id)) ||
        typeof value.drawId !== 'string' || typeof value.chosenCardId !== 'string' || typeof value.pendingCardId !== 'string' ||
        (value.batchIds.length > 0 && !RandomFoodRoundStore.uuid(value.drawId)) ||
        (value.chosenCardId.length > 0 && value.pendingCardId.length > 0) ||
        typeof value.historyId !== 'string' || typeof value.rangeLabel !== 'string' || value.rangeLabel.length > 240 ||
        !Number.isSafeInteger(value.selectedAt) || value.selectedAt < 0 || !Number.isSafeInteger(value.preparedAt) ||
        value.preparedAt < 0 || typeof value.ended !== 'boolean' || typeof value.recordDeleted !== 'boolean' ||
        (value.chosenCardId.length > 0 && !value.batchIds.includes(value.chosenCardId)) ||
        (value.pendingCardId.length > 0 && !value.batchIds.includes(value.pendingCardId))) return undefined;
      return copyRandomFoodRound(value);
    } catch (_error) { return undefined; }
  }
  // 保存当前轮次。
  static write(context: common.Context, value: RandomFoodRound): void {
    const store: preferences.Preferences = RandomFoodRoundStore.store(context);
    store.putSync(RandomFoodRoundStore.key(value.owner, value.source), JSON.stringify(value));
    store.flushSync();
  }
  // 读取用户选择的候选来源（游客固定为公开推荐）。
  static selectedSource(context: common.Context, owner: string): RandomFoodSource {
    if (owner === 'guest') return 'PUBLIC';
    const value: preferences.ValueType = RandomFoodRoundStore.store(context).getSync('source:' + owner, 'MY');
    return value === 'FRIENDS' ? 'FRIENDS' : value === 'PUBLIC' ? 'PUBLIC' : 'MY';
  }
  // 保存用户选择的候选来源。
  static selectSource(context: common.Context, owner: string, source: RandomFoodSource): void {
    const store: preferences.Preferences = RandomFoodRoundStore.store(context);
    store.putSync('source:' + owner, source); store.flushSync();
  }
  // 翻牌动画是否开启（用户可关闭以减少动效）。
  static motionEnabled(context: common.Context): boolean {
    return RandomFoodRoundStore.store(context).getSync('motion', true) === true;
  }
  // 设置翻牌动画开关。
  static setMotion(context: common.Context, enabled: boolean): void {
    const store: preferences.Preferences = RandomFoodRoundStore.store(context);
    store.putSync('motion', enabled); store.flushSync();
  }
  // 选择记录被删除后，把引用它的轮次标记为“记录已删除”。
  static markRecordDeleted(context: common.Context, owner: string, historyId: string): void {
    const sources: Array<RandomFoodSource> = ['MY', 'PUBLIC', 'FRIENDS'];
    for (const source of sources) {
      const round: RandomFoodRound | undefined = RandomFoodRoundStore.read(context, owner, source);
      if (round !== undefined && round.historyId === historyId) { round.recordDeleted = true; RandomFoodRoundStore.write(context, round); }
    }
  }
  // 清除某账号的全部轮次（注销账号时调用）。
  static clearAccount(context: common.Context, uid: string): void {
    const owner: string = 'user:' + uid;
    const store: preferences.Preferences = RandomFoodRoundStore.store(context);
    const sources: Array<RandomFoodSource> = ['MY', 'PUBLIC', 'FRIENDS'];
    for (const source of sources) store.deleteSync(RandomFoodRoundStore.key(owner, source));
    store.deleteSync('source:' + owner); store.flushSync();
  }
}
