import { ReadScheduler } from '../service/ReadScheduler';
import { DraftStore } from '../service/DraftStore';
import { AbilityConstant, common, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { pushService } from '@kit.PushKit';
import { storePendingSharedCard } from '../service/CardAppLink';
import {
  ContinuationSnapshot, ContinuationState, ENTRY_CARD_ID_PARAMETER, ENTRY_FRIEND_UID_PARAMETER,
  ENTRY_ROUTE_PARAMETER, ENTRY_TAB_PARAMETER
} from '../service/ContinuationState';
import { PushNotificationService } from '../service/PushNotificationService';
import { ImageDescriptors } from '../service/ImageDescriptors';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { ImageRepository } from '../service/ImageRepository';
import { ServiceCardRemoteSyncService } from '../service/ServiceCardRemoteSyncService';

export default class EntryAbility extends UIAbility {
  private readonly tokenUpdateCallback: (token: string) => void = (token: string): void => {
    PushNotificationService.handleTokenUpdate(this.context, token);
    ServiceCardRemoteSyncService.handleTokenUpdate(this.context, token);
  };

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    ImageDescriptors.onRevoked = (mediaId: string): void => { try { ServiceCardStore.revokePublished(this.context, mediaId); } catch (_error) { } };
    if (!AppStorage.has('pendingSharedCardId')) AppStorage.setOrCreate('pendingSharedCardId', '');
    AppStorage.setOrCreate('stage47AppActive', true);
    if (!AppStorage.has('socialForegroundRevision')) AppStorage.setOrCreate('socialForegroundRevision', 0);
    if (!AppStorage.has('friendRelationshipRevision')) AppStorage.setOrCreate('friendRelationshipRevision', 0);
    if (!AppStorage.has('requestedFriendSection')) AppStorage.setOrCreate('requestedFriendSection', 0);
    if (!AppStorage.has('notificationForegroundRevision')) AppStorage.setOrCreate('notificationForegroundRevision', 0);
    ContinuationState.initialize();
    this.captureSystemEntry(want);
    if (PushNotificationService.isSupported()) {
      pushService.on('tokenUpdate', this, this.tokenUpdateCallback);
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.captureSystemEntry(want);
  }

  onBackground(): void { AppStorage.setOrCreate('stage47AppActive', false); ReadScheduler.invalidateQueued(); ImageRepository.revokePermissions(); void DraftStore.flushActive().catch((_error: Object): void => {}); }

  onForeground(): void {
    AppStorage.setOrCreate('stage47AppActive', true);
    const revision: number = AppStorage.get<number>('socialForegroundRevision') || 0;
    AppStorage.setOrCreate('socialForegroundRevision', revision + 1);
    const notificationRevision: number = AppStorage.get<number>('notificationForegroundRevision') || 0;
    AppStorage.setOrCreate('notificationForegroundRevision', notificationRevision + 1);
  }

  onWindowStageRestore(windowStage: window.WindowStage): void {
    // Cross-device continuation invokes this callback instead of onWindowStageCreate.
    // lastRequestWant contains the values written by the source device's onContinue.
    this.captureSystemEntry(this.lastRequestWant);
    this.loadEntryContent(windowStage);
  }

  private captureSystemEntry(want: Want): void {
    const uri = typeof want.uri === 'string' ? want.uri : '';
    if (storePendingSharedCard(uri)) {
      console.info('Received an approved 食刻商品卡 App Linking route.');
      return;
    }
    if (ContinuationState.captureIncomingWant(want)) {
      console.info('Received an approved 食刻 system entry route.');
    }
  }

  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const snapshot: ContinuationSnapshot = ContinuationState.snapshot();
    wantParam[ENTRY_ROUTE_PARAMETER] = snapshot.route;
    wantParam[ENTRY_CARD_ID_PARAMETER] = snapshot.cardId;
    wantParam[ENTRY_FRIEND_UID_PARAMETER] = snapshot.friendUid;
    wantParam[ENTRY_TAB_PARAMETER] = snapshot.tab;
    return AbilityConstant.OnContinueResult.AGREE;
  }

  onDestroy(): void {
    if (PushNotificationService.isSupported()) {
      pushService.off('tokenUpdate', this.tokenUpdateCallback);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.loadEntryContent(windowStage);
  }

  private loadEntryContent(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error: BusinessError) => {
      if (error.code !== 0) {
        console.error(`loadContent failed, code=${error.code}, message=${error.message}`);
      }
    });
  }
}
