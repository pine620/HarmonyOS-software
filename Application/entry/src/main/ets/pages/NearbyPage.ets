import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { DiscoveryCapabilities, emptyCapabilities } from '../model/DiscoveryModels';
import { DiscoveryRepository } from '../repository/DiscoveryRepository';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { ServiceCardRemoteSyncService } from '../service/ServiceCardRemoteSyncService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { DiscoveryFeed } from './DiscoveryFeed';

@Component
export struct NearbyPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @Prop revision: number = 0;
  @Prop @Watch('onAccountChanged') loggedIn: boolean = false;
  @Prop showPreferencePrompt: boolean = false;
  onSetupPreference: () => void = (): void => {};
  onSkipPreference: () => void = (): void => {};
  onOpenMeal: () => void = (): void => {};
  @State capabilities: DiscoveryCapabilities = emptyCapabilities();
  @State ready: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private repository: DiscoveryRepository = new DiscoveryRepository();
  private publishing: boolean = false;
  private pendingCard: FoodCard | undefined = undefined;
  private pendingRemote: boolean = false;
  aboutToAppear(): void { this.active = true; if (!this.ready) void this.loadCapabilities(); }
  aboutToDisappear(): void { this.active = false; this.generation++; this.pendingCard = undefined; }
  private onAccountChanged(): void { this.ready = false; this.generation++; if (this.active) void this.loadCapabilities(); }
  private async loadCapabilities(): Promise<void> {
    const generation: number = ++this.generation; const session: number = AuthSessionStore.generation();
    try {
      const value: DiscoveryCapabilities = await this.repository.capabilities();
      if (this.active && generation === this.generation && session === AuthSessionStore.generation()) this.capabilities = value;
    } catch (_error) { if (this.active && generation === this.generation) this.capabilities = emptyCapabilities(); }
    finally { if (this.active && generation === this.generation && session === AuthSessionStore.generation()) this.ready = true; }
  }
  private enqueueCard(card: FoodCard, remote: boolean): void {
    if (!this.active) return;
    this.pendingCard = card; this.pendingRemote = this.pendingRemote || remote;
    if (!this.publishing) void this.publishCard();
  }
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
  build() {
    if (this.ready) {
      DiscoveryFeed({ capabilities: this.capabilities, revision: this.revision, showPreferencePrompt: this.showPreferencePrompt,
        onSetupPreference: this.onSetupPreference, onSkipPreference: this.onSkipPreference, onOpenMeal: this.onOpenMeal,
        onPrimaryCard: (card: FoodCard, remote: boolean): void => this.enqueueCard(card, remote), onOpenCard: this.onOpenCard,
        onUnavailable: (): void => { this.capabilities = emptyCapabilities(); } })
    } else { Column() { LoadingProgress().width(36).height(36) }.width('100%').height('100%').justifyContent(FlexAlign.Center) }
  }
}
