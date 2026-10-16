import { AppPageSurface } from '../common/AppPageUi';
import { ReadScheduler } from '../service/ReadScheduler';
import { DraftStore } from '../service/DraftStore';
import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { pushCommon, pushService } from '@kit.PushKit';
import { initializeSharedCardEntry, storePendingSharedCard } from '../service/CardDeepLink';
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
  private mainWindow: window.Window | undefined = undefined;
  private appearanceTask: Promise<void> = Promise.resolve();
  // Tracks the system colour mode so window/status-bar colours resolve from the matching resources.
  private darkMode: boolean = false;
  private layoutFullScreen: boolean = false;
  private lastBarSignature: string = '';
  private readonly avoidAreaChanged: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (options.type === window.AvoidAreaType.TYPE_SYSTEM || options.type === window.AvoidAreaType.TYPE_CUTOUT ||
        options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR || options.type === window.AvoidAreaType.TYPE_KEYBOARD) this.updateSystemEdges();
    };
  private readonly tokenUpdateCallback: (token: string) => void = (token: string): void => {
    PushNotificationService.handleTokenUpdate(this.context, token);
    ServiceCardRemoteSyncService.handleTokenUpdate(this.context, token);
  };

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    ImageDescriptors.onRevoked = (mediaId: string): void => { try { ServiceCardStore.revokePublished(this.context, mediaId); } catch (_error) { } };
    initializeSharedCardEntry();
    AppStorage.setOrCreate('stage47AppActive', true);
    if (!AppStorage.has('socialForegroundRevision')) AppStorage.setOrCreate('socialForegroundRevision', 0);
    if (!AppStorage.has('friendRelationshipRevision')) AppStorage.setOrCreate('friendRelationshipRevision', 0);
    if (!AppStorage.has('requestedFriendSection')) AppStorage.setOrCreate('requestedFriendSection', 0);
    ContinuationState.initialize();
    this.captureSystemEntry(want);
    if (PushNotificationService.isSupported()) {
      pushService.on('tokenUpdate', this, this.tokenUpdateCallback);
      // Pack 4 (2026-10-15): while the app is in front, a private / group message push (category IM) is handed
      // to the app instead of a banner. Bumping the social revision makes open chats and lists refresh at once;
      // foreground polling remains only as a fallback.
      try {
        pushService.receiveMessage('IM', this, (_payload: pushCommon.PushPayload): void => {
          const revision: number = AppStorage.get<number>('socialForegroundRevision') || 0;
          AppStorage.setOrCreate('socialForegroundRevision', revision + 1);
        });
      } catch (_error) {
        console.warn('[Push] foreground message listener unavailable');
      }
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.captureSystemEntry(want);
  }

  onBackground(): void { AppStorage.setOrCreate('stage47AppActive', false); ReadScheduler.invalidateQueued(); ImageRepository.subscriptionsChanged(); void DraftStore.flushActive().catch((_error: Object): void => {}); }

  onForeground(): void {
    // The system may restore its own bar colours while backgrounded; force one full re-apply.
    this.readDarkMode();
    this.lastBarSignature = '';
    void this.applyWindowAppearance();
    AppStorage.setOrCreate('stage47AppActive', true);
    const revision: number = AppStorage.get<number>('socialForegroundRevision') || 0;
    AppStorage.setOrCreate('socialForegroundRevision', revision + 1);
  }

  onConfigurationUpdate(configuration: Configuration): void {
    if (configuration.colorMode !== undefined) {
      this.darkMode = configuration.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    this.lastBarSignature = '';
    void this.applyWindowAppearance();
  }

  private readDarkMode(): void {
    try {
      this.darkMode = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (_failure) {
      this.darkMode = false;
    }
  }

  // The ability's resource manager can lag behind a light/dark switch, which painted the status bar
  // with light colours over a dark page. Resolve through an override that pins the current mode.
  private themedResources(): resourceManager.ResourceManager {
    const base: resourceManager.ResourceManager = this.context.resourceManager;
    try {
      const override: resourceManager.Configuration = base.getOverrideConfiguration();
      override.colorMode = this.darkMode ? resourceManager.ColorMode.DARK : resourceManager.ColorMode.LIGHT;
      return base.getOverrideResourceManager(override);
    } catch (_failure) {
      return base;
    }
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
      console.info('Received an approved 食刻商品卡 Deep Linking route.');
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
    this.detachWindowAppearance();
    if (PushNotificationService.isSupported()) {
      pushService.off('tokenUpdate', this.tokenUpdateCallback);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.loadEntryContent(windowStage);
  }

  onWindowStageDestroy(): void {
    this.detachWindowAppearance();
  }

  private loadEntryContent(windowStage: window.WindowStage): void {
    // Configure the window before startup UI or any destination can draw a white system strip.
    void this.prepareWindow(windowStage).finally((): void => {
      windowStage.loadContent('pages/Index', (error: BusinessError): void => {
        if (error.code !== 0) {
          console.error(`loadContent failed, code=${error.code}, message=${error.message}`);
        }
      });
    });
  }

  private colorHex(resource: Resource): string {
    const color: number = this.themedResources().getColorSync(resource);
    return '#' + (color >>> 0).toString(16).padStart(8, '0');
  }

  private async prepareWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      this.detachWindowAppearance();
      this.readDarkMode();
      this.layoutFullScreen = false;
      this.lastBarSignature = '';
      this.mainWindow = mainWindow;
      AppPageSurface.setEntrySurfaceVisible(true);
      AppPageSurface.onChange = (): void => { void this.applyWindowAppearance(); };
      mainWindow.on('avoidAreaChange', this.avoidAreaChanged);
      this.updateSystemEdges();
    } catch (failure) {
      this.logWindowFailure(failure as Object);
    }
    await this.applyWindowAppearance();
  }

  private applyWindowAppearance(): Promise<void> {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined) return Promise.resolve();
    // Serialize startup, navigation, foreground and theme updates so older calls cannot win a race.
    this.appearanceTask = this.appearanceTask.then((): Promise<void> => this.synchronizeWindowAppearance(mainWindow));
    return this.appearanceTask;
  }

  private async synchronizeWindowAppearance(mainWindow: window.Window): Promise<void> {
    if (this.mainWindow !== mainWindow) return;
    let ink: string = '';
    let header: string = '';
    let canvas: string = '';
    try {
      ink = this.colorHex($r('app.color.ink'));
      header = this.colorHex(AppPageSurface.windowHeader());
      canvas = this.colorHex(AppPageSurface.windowCanvas());
    } catch (failure) {
      this.logWindowFailure(failure as Object);
      return;
    }
    // Page transitions call this repeatedly. Skipping unchanged colours and toggling full-screen layout
    // only once keeps the window from relayouting (and the content from jumping) mid push/pop animation.
    const immersiveTop: boolean = AppPageSurface.windowImmersiveTop();
    const statusInk: string = immersiveTop ? '#FFFFFFFF' : ink;
    const signature: string = header + '|' + canvas + '|' + ink + '|' + (immersiveTop ? 'immersive' : 'solid');
    if (this.layoutFullScreen && signature === this.lastBarSignature) return;
    try {
      // Unpainted system regions must reveal the scene's header color, not its pale content canvas.
      mainWindow.setWindowBackgroundColor(header);
      if (!this.layoutFullScreen) {
        await mainWindow.setWindowLayoutFullScreen(true);
        this.layoutFullScreen = true;
        this.updateSystemEdges();
      }
    } catch (failure) {
      this.logWindowFailure(failure as Object);
    }
    if (this.mainWindow !== mainWindow) return;
    try {
      // Destinations always use the theme ink; only the home Navigation follows the immersive ink.
      AppPageSurface.systemBarInk = ink;
      AppStorage.setOrCreate('appSystemBarInk', statusInk);
      const properties: window.SystemBarProperties = {
        // A transparent status bar lets the profile cover painted by Index show through.
        statusBarColor: immersiveTop ? '#00000000' : header, navigationBarColor: canvas,
        statusBarContentColor: statusInk, navigationBarContentColor: ink,
        enableStatusBarAnimation: false, enableNavigationBarAnimation: false
      };
      await mainWindow.setWindowSystemBarProperties(properties);
      this.lastBarSignature = signature;
    } catch (failure) {
      this.logWindowFailure(failure as Object);
    }
  }

  private updateSystemEdges(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined) return;
    try {
      const system: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const indicator: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const keyboard: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
      AppStorage.setOrCreate('appSystemTopPx', Math.max(0, system.topRect.height, cutout.topRect.height));
      AppStorage.setOrCreate('appSystemBottomPx', Math.max(0, system.bottomRect.height, cutout.bottomRect.height, indicator.bottomRect.height));
      AppStorage.setOrCreate('appSystemLeftPx', Math.max(0, system.leftRect.width, cutout.leftRect.width, indicator.leftRect.width));
      AppStorage.setOrCreate('appSystemRightPx', Math.max(0, system.rightRect.width, cutout.rightRect.width, indicator.rightRect.width));
      AppStorage.setOrCreate('appKeyboardVisible', keyboard.bottomRect.height > 0);
    } catch (failure) {
      this.logWindowFailure(failure as Object);
    }
  }

  private detachWindowAppearance(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow !== undefined) {
      try { mainWindow.off('avoidAreaChange', this.avoidAreaChanged); }
      catch (failure) { this.logWindowFailure(failure as Object); }
    }
    this.mainWindow = undefined;
    AppPageSurface.onChange = undefined;
  }

  private logWindowFailure(failure: Object): void {
    const error: BusinessError = failure as BusinessError;
    console.warn('[WindowAppearance] code=' + String(error.code || '') + ' message=' + String(error.message || '窗口外观设置失败'));
  }
}
