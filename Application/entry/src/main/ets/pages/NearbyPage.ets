/**
 * 【文件职责】“推荐”页签的外壳：先读取发现能力（get-discovery-capabilities），再渲染 DiscoveryFeed；
 * 同时把推荐流中的第一张公开卡片同步到「食刻推荐」桌面卡片（ServiceCardStore，开启远程同步时还会推送）。
 */
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { DiscoveryCapabilities, emptyCapabilities } from '../model/DiscoveryModels';
import { DiscoveryRepository } from '../repository/DiscoveryRepository';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { ServiceCardRemoteSyncService } from '../service/ServiceCardRemoteSyncService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { DiscoveryFeed } from './DiscoveryFeed';

// 推荐页签外壳。
@Component
export struct NearbyPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @Prop revision: number = 0;
  @Prop @Watch('onAccountChanged') loggedIn: boolean = false;
  @StorageLink('authSessionRevision') @Watch('onAccountChanged') sessionRevision: number = 0;
  onOpenMeal: () => void = (): void => {};
  @State capabilities: DiscoveryCapabilities = emptyCapabilities();
  @State ready: boolean = false;
  @State capabilitiesLoading: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private repository: DiscoveryRepository = new DiscoveryRepository();
  private publishing: boolean = false;
  private pendingCard: FoodCard | undefined = undefined;
  private pendingRemote: boolean = false;
  // 页面出现：首次时读取能力。
  aboutToAppear(): void { this.active = true; if (!this.ready) void this.loadCapabilities(); }
  // 页面消失：作废进行中的读取。
  aboutToDisappear(): void { this.active = false; this.generation++; this.capabilitiesLoading = false; this.pendingCard = undefined; }
  // 账号变化：重新读取能力。
  private onAccountChanged(): void {
    this.ready = false; this.generation++; this.capabilitiesLoading = false; this.capabilities = emptyCapabilities();
    if (this.active) void this.loadCapabilities();
  }
  // 能力读取结果是否仍有效（代次与会话未变化）。
  private capabilityRequestCurrent(generation: number, session: number): boolean {
    return this.active && generation === this.generation && session === AuthSessionStore.generation();
  }
  // 读取发现能力；失败时使用全部关闭的默认值并允许重试。
  private async loadCapabilities(): Promise<void> {
    if (!this.active || this.capabilitiesLoading) return;
    this.capabilitiesLoading = true;
    const generation: number = ++this.generation; const session: number = AuthSessionStore.generation();
    try {
      const value: DiscoveryCapabilities = await this.repository.capabilities();
      if (this.capabilityRequestCurrent(generation, session)) {
        this.capabilities = value;
        console.info('[DiscoveryCapabilities] searchEnabled=' + String(value.searchEnabled) + ' searchReason=' + value.searchReason +
          ' mapEnabled=' + String(value.mapEnabled) + ' mapReason=' + value.mapReason);
      }
    } catch (error) {
      if (this.capabilityRequestCurrent(generation, session)) {
        const unavailable: DiscoveryCapabilities = { searchEnabled: false, mapEnabled: false,
          searchReason: 'CAPABILITIES_LOAD_FAILED', mapReason: 'CAPABILITIES_LOAD_FAILED' };
        this.capabilities = unavailable;
        const code: string = error instanceof CloudBusinessError ? error.code : 'REQUEST_FAILED';
        console.warn('[DiscoveryCapabilities] load_failed code=' + code);
      }
    } finally {
      if (this.capabilityRequestCurrent(generation, session)) { this.ready = true; this.capabilitiesLoading = false; }
    }
  }
  // 把推荐流中的卡片排队，准备发布到桌面卡片。
  private enqueueCard(card: FoodCard, remote: boolean): void {
    if (!this.active) return;
    this.pendingCard = card; this.pendingRemote = this.pendingRemote || remote;
    if (!this.publishing) void this.publishCard();
  }
  // 把排队的卡片写入桌面卡片（本地），并在开启远程同步时请求推送。
  private async publishCard(): Promise<void> {
    this.publishing = true; const session: number = AuthSessionStore.generation();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      while (this.active && session === AuthSessionStore.generation()) {
        const card: FoodCard | undefined = this.pendingCard; if (card === undefined) break;
        const remote: boolean = this.pendingRemote; this.pendingCard = undefined; this.pendingRemote = false;
        await ServiceCardStore.publishRecommendation(context, card);
        if (!this.active || session !== AuthSessionStore.generation() || !remote || !this.loggedIn || ServiceCardStore.read(context).cardId !== card.id) continue;
        if (ServiceCardRemoteSyncService.status(context).optedIn) await ServiceCardRemoteSyncService.pushCurrentRecommendation(context, card.id);
      }
    } catch (_error) { console.warn('[ServiceCard] recommendation sync deferred'); }
    finally { this.publishing = false; }
  }
  // 页面布局。
  build() {
    if (this.ready) {
      DiscoveryFeed({ capabilities: this.capabilities, revision: this.revision, capabilitiesLoading: this.capabilitiesLoading,
        onReloadCapabilities: (): void => { void this.loadCapabilities(); },
        onOpenMeal: this.onOpenMeal,
        onPrimaryCard: (card: FoodCard, remote: boolean): void => this.enqueueCard(card, remote), onOpenCard: this.onOpenCard,
        onUnavailable: (): void => { this.capabilities = emptyCapabilities(); } })
    } else { Column() { LoadingProgress().width(36).height(36) }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
  }
}
