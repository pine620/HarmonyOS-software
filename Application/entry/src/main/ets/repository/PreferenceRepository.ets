import { AuthSessionStore } from '../service/AuthSessionStore';
import { AuthService } from '../service/AuthService';
import { ReadRequestOptions } from '../service/ReadScheduler';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { EmptyRequest, FoodCategoryV2 } from '../model/CloudContracts';
import { PreferenceClearRequest, RecommendationPage, RecommendationQuery, Stage47Capabilities, TastePreference, copyPreference, emptyPreference } from '../model/PreferenceModels';
import { CATEGORY_V2_OPTIONS, CategoryV2Option } from '../model/PublishingModels';
import { CloudGateway } from '../service/CloudGateway';
export class PreferenceRepository {
  private static capabilitiesKey: string = '';
  private static capabilitiesUntil: number = 0;
  private static capabilitiesValue: Stage47Capabilities | undefined = undefined;
  private static capabilitiesPending: Promise<Stage47Capabilities> | undefined = undefined;

  private guest(context: common.Context): preferences.Preferences { return preferences.getPreferencesSync(context, { name: 'shike_guest_preference' }); }
  async get(context: common.Context): Promise<TastePreference> {
    if (CloudGateway.hasSession()) { const request: EmptyRequest = {}; return AccountRequestGuard.authenticated<TastePreference>('get-taste-preference', request); }
    const raw: preferences.ValueType = this.guest(context).getSync('active', '');
    if (typeof raw !== 'string' || raw.length > 8192 || raw.length === 0) return emptyPreference();
    try { const value: TastePreference = JSON.parse(raw) as TastePreference; this.validate(value); return copyPreference(value); } catch (_error) { return emptyPreference(); }
  }
  private validate(p: TastePreference): void {
    if (!Array.isArray(p.likedCategories) || !Array.isArray(p.lessCategories) || p.likedCategories.length > 11 || p.lessCategories.length > 11) throw new Error('分类偏好无效。');
    for (const category of p.likedCategories.concat(p.lessCategories)) if (!CATEGORY_V2_OPTIONS.some((item: CategoryV2Option): boolean => item.key === category)) throw new Error('分类无效。');
    if (p.likedCategories.some((key: FoodCategoryV2): boolean => p.lessCategories.includes(key)) || !['ANY', 'DELIVERY', 'DINE_IN'].includes(p.preferredMode)) throw new Error('偏好无效。');
    for (const value of [p.budgetMinFen, p.budgetMaxFen]) if (value !== null && (!Number.isSafeInteger(value) || value < 0 || value > 100000000)) throw new Error('预算无效。');
    if (p.budgetMinFen !== null && p.budgetMaxFen !== null && p.budgetMaxFen < p.budgetMinFen) throw new Error('预算上限不得小于下限。');
  }
  async save(context: common.Context, value: TastePreference): Promise<TastePreference> {
    this.validate(value); let result: TastePreference;
    if (CloudGateway.hasSession()) result = await AccountRequestGuard.authenticated<TastePreference>('update-taste-preference', value);
    else { result = copyPreference(value); result.version++; result.updatedAt = Date.now(); const store: preferences.Preferences = this.guest(context); store.putSync('active', JSON.stringify(result)); store.flushSync(); }
    AppStorage.setOrCreate('preferenceRevision', (AppStorage.get<number>('preferenceRevision') || 0) + 1); return result;
  }
  async clear(context: common.Context, request: PreferenceClearRequest): Promise<TastePreference> {
    if (CloudGateway.hasSession()) { const result: TastePreference = await AccountRequestGuard.authenticated<TastePreference>('clear-taste-preference', request); AppStorage.setOrCreate('preferenceRevision', (AppStorage.get<number>('preferenceRevision') || 0) + 1); return result; }
    const p: TastePreference = request.field === 'ALL' ? emptyPreference() : await this.get(context);
    if (CloudGateway.hasSession()) throw new Error('账号已变化，请重新读取偏好。');
    if (request.field === 'LIKED') p.likedCategories = []; if (request.field === 'LESS') p.lessCategories = []; if (request.field === 'MODE') p.preferredMode = 'ANY'; if (request.field === 'BUDGET') { p.budgetMinFen = null; p.budgetMaxFen = null; }
    return this.save(context, p);
  }
  async recommendations(context: common.Context, cursor: string = '', options: ReadRequestOptions = {}): Promise<RecommendationPage> {
    const request: RecommendationQuery = { cursor, pageSize: 6 };
    if (CloudGateway.hasSession()) return AccountRequestGuard.authenticated<RecommendationPage>('list-personalized-recommendations', request, options);
    request.preference = await this.get(context); return AccountRequestGuard.public<RecommendationPage>('list-personalized-recommendations', request, options);
  }
  async capabilities(): Promise<Stage47Capabilities> {
    const owner: string = AuthService.profile()?.uid || '';
    const session: number = AuthSessionStore.generation();
    const revision: number = AppStorage.get<number>('accountContentRevision') || 0;
    const key: string = `${owner}:${session}:${revision}`;
    if (key !== PreferenceRepository.capabilitiesKey) {
      PreferenceRepository.capabilitiesKey = key; PreferenceRepository.capabilitiesValue = undefined;
      PreferenceRepository.capabilitiesPending = undefined; PreferenceRepository.capabilitiesUntil = 0;
    }
    const cached: Stage47Capabilities | undefined = PreferenceRepository.capabilitiesValue;
    if (cached !== undefined && Date.now() < PreferenceRepository.capabilitiesUntil) return cached;
    const pending: Promise<Stage47Capabilities> | undefined = PreferenceRepository.capabilitiesPending;
    if (pending !== undefined) return pending;
    const request: EmptyRequest = {};
    const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> =>
      owner === (AuthService.profile()?.uid || '') && session === AuthSessionStore.generation() &&
      revision === (AppStorage.get<number>('accountContentRevision') || 0) };
    const promise: Promise<Stage47Capabilities> = (CloudGateway.hasSession() ?
      AccountRequestGuard.authenticated<Stage47Capabilities>('get-stage47-capabilities', request, options) :
      AccountRequestGuard.public<Stage47Capabilities>('get-stage47-capabilities', request, options))
      .then((value: Stage47Capabilities): Stage47Capabilities => {
        if (PreferenceRepository.capabilitiesKey === key) {
          PreferenceRepository.capabilitiesValue = value; PreferenceRepository.capabilitiesUntil = Date.now() + 60000;
        }
        return value;
      }).finally((): void => { if (PreferenceRepository.capabilitiesKey === key) PreferenceRepository.capabilitiesPending = undefined; });
    PreferenceRepository.capabilitiesPending = promise; return promise;
  }
  seen(context: common.Context, uid: string): boolean { return this.guest(context).getSync('seen_' + uid, false) === true; }
  markSeen(context: common.Context, uid: string): void { const store: preferences.Preferences = this.guest(context); store.putSync('seen_' + uid, true); store.flushSync(); }
}
