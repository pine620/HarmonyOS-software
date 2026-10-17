/**
 * 【文件职责】应用主 Ability（UIAbility），也是 App 的启动入口（module.json5 中的 mainElement）。
 * 只负责把“系统事件”转换成应用状态，不直接发业务请求：
 *   - onCreate：初始化 AppStorage 键、注册 Push Token 更新与前台 IM 消息监听、处理启动时带来的 Want；
 *   - onNewWant / onWindowStageRestore：处理 Deep Link（碰一碰分享）、通知点击、桌面卡片点击与跨设备接续；
 *   - onWindowStageCreate：先配置窗口（沉浸式、系统栏颜色）再加载 pages/Index；
 *   - onBackground / onForeground：标记前后台（stage47AppActive），后台时冻结读队列并保存草稿；
 *   - onContinue：跨设备接续时只写入路由、卡片 id、好友 uid、页签，不传 Token。
 */
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

// 主 Ability。
export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;
  private appearanceTask: Promise<void> = Promise.resolve();
  // 跟踪系统亮/暗色模式，让窗口与状态栏颜色从对应的资源中解析。
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

  // Ability 创建：初始化全局状态与 Push 监听，处理启动 Want。
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
      // App 在前台时，私信 / 群消息推送（IM 类别）交给 App 处理而不弹横幅：增加 socialForegroundRevision，让打开的聊天和列表立即刷新；前台轮询只作为兜底。
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

  // App 已在运行时又被拉起（例如点击通知或分享链接）。
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.captureSystemEntry(want);
  }

  // 进入后台：标记后台、作废排队中的读请求、清理无人需要的图片任务、保存正在编辑的草稿。
  onBackground(): void { AppStorage.setOrCreate('stage47AppActive', false); ReadScheduler.invalidateQueued(); ImageRepository.subscriptionsChanged(); void DraftStore.flushActive().catch((_error: Object): void => {}); }

  // 回到前台：重新应用窗口颜色，标记前台，并通知社交页面刷新。
  onForeground(): void {
    // 在后台期间系统可能恢复了自己的系统栏颜色，回到前台时强制完整地重新应用一次。
    this.readDarkMode();
    this.lastBarSignature = '';
    void this.applyWindowAppearance();
    AppStorage.setOrCreate('stage47AppActive', true);
    const revision: number = AppStorage.get<number>('socialForegroundRevision') || 0;
    AppStorage.setOrCreate('socialForegroundRevision', revision + 1);
  }

  // 系统配置变化（亮/暗色切换等）时重新应用窗口颜色。
  onConfigurationUpdate(configuration: Configuration): void {
    if (configuration.colorMode !== undefined) {
      this.darkMode = configuration.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    this.lastBarSignature = '';
    void this.applyWindowAppearance();
  }

  // 读取当前是否为暗色模式。
  private readDarkMode(): void {
    try {
      this.darkMode = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (_failure) {
      this.darkMode = false;
    }
  }

  // Ability 的资源管理器在亮/暗色切换后可能滞后，导致暗色页面上画出亮色状态栏；这里通过固定当前模式的覆盖配置来解析颜色。
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

  // 跨设备接续恢复窗口。
  onWindowStageRestore(windowStage: window.WindowStage): void {
    // 跨设备接续时系统调用的是这个回调而不是 onWindowStageCreate；lastRequestWant 中是源设备 onContinue 写入的值。
    this.captureSystemEntry(this.lastRequestWant);
    this.loadEntryContent(windowStage);
  }

  // 处理系统传入的 Want：先识别分享链接，再识别接续 / 通知 / 卡片入口。
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

  // 跨设备接续：把当前页面的最小上下文写入 wantParam。
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const snapshot: ContinuationSnapshot = ContinuationState.snapshot();
    wantParam[ENTRY_ROUTE_PARAMETER] = snapshot.route;
    wantParam[ENTRY_CARD_ID_PARAMETER] = snapshot.cardId;
    wantParam[ENTRY_FRIEND_UID_PARAMETER] = snapshot.friendUid;
    wantParam[ENTRY_TAB_PARAMETER] = snapshot.tab;
    return AbilityConstant.OnContinueResult.AGREE;
  }

  // Ability 销毁：解除窗口与 Push 监听。
  onDestroy(): void {
    this.detachWindowAppearance();
    if (PushNotificationService.isSupported()) {
      pushService.off('tokenUpdate', this.tokenUpdateCallback);
    }
  }

  // 创建窗口后加载主页面。
  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.loadEntryContent(windowStage);
  }

  // 窗口销毁时解除外观监听。
  onWindowStageDestroy(): void {
    this.detachWindowAppearance();
  }

  // 配置窗口后加载 pages/Index。
  private loadEntryContent(windowStage: window.WindowStage): void {
    // 在启动界面或任何子页面绘制之前先配置窗口，避免出现白色系统条。
    void this.prepareWindow(windowStage).finally((): void => {
      windowStage.loadContent('pages/Index', (error: BusinessError): void => {
        if (error.code !== 0) {
          console.error(`loadContent failed, code=${error.code}, message=${error.message}`);
        }
      });
    });
  }

  // 把颜色资源解析为 #AARRGGBB 字符串。
  private colorHex(resource: Resource): string {
    const color: number = this.themedResources().getColorSync(resource);
    return '#' + (color >>> 0).toString(16).padStart(8, '0');
  }

  // 准备主窗口：记录窗口、监听安全区变化、注册外观变化回调。
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

  // 串行地应用窗口外观（避免多次调用乱序）。
  private applyWindowAppearance(): Promise<void> {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined) return Promise.resolve();
    // 把启动、导航、前台、主题切换引起的更新串行化，避免较早的调用后完成而覆盖较新的结果。
    this.appearanceTask = this.appearanceTask.then((): Promise<void> => this.synchronizeWindowAppearance(mainWindow));
    return this.appearanceTask;
  }

  // 同步窗口背景色、全屏布局与状态栏 / 导航栏颜色（颜色未变化时跳过）。
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
    // 页面转场时会反复调用这里。颜色没变就跳过，并且全屏布局只切换一次，这样 push/pop 动画中窗口不会重新布局（内容不会跳动）。
    const immersiveTop: boolean = AppPageSurface.windowImmersiveTop();
    const statusInk: string = immersiveTop ? '#FFFFFFFF' : ink;
    const signature: string = header + '|' + canvas + '|' + ink + '|' + (immersiveTop ? 'immersive' : 'solid');
    if (this.layoutFullScreen && signature === this.lastBarSignature) return;
    try {
      // 系统区域中没有被绘制的部分要露出页面顶部的颜色，而不是浅色的内容画布。
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
      // 子页面总是使用主题正文色；只有首页 Navigation 跟随沉浸状态切换状态栏文字颜色。
      AppPageSurface.systemBarInk = ink;
      AppStorage.setOrCreate('appSystemBarInk', statusInk);
      const properties: window.SystemBarProperties = {
        // 状态栏底色始终透明：状态栏区域的颜色由 Index 的顶部颜色条绘制，能与页面切换同步渐变；
        // 若在这里设为不透明的页面顶部色，会经窗口接口异步生效，并在页签切换时滞后于页面。
        statusBarColor: '#00000000', navigationBarColor: canvas,
        statusBarContentColor: statusInk, navigationBarContentColor: ink,
        enableStatusBarAnimation: false, enableNavigationBarAnimation: false
      };
      await mainWindow.setWindowSystemBarProperties(properties);
      this.lastBarSignature = signature;
    } catch (failure) {
      this.logWindowFailure(failure as Object);
    }
  }

  // 读取系统安全区（状态栏、刘海、导航条、键盘）并写入 AppStorage 供 Index 布局使用。
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

  // 解除窗口外观相关的监听。
  private detachWindowAppearance(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow !== undefined) {
      try { mainWindow.off('avoidAreaChange', this.avoidAreaChanged); }
      catch (failure) { this.logWindowFailure(failure as Object); }
    }
    this.mainWindow = undefined;
    AppPageSurface.onChange = undefined;
  }

  // 记录窗口操作失败（不影响启动）。
  private logWindowFailure(failure: Object): void {
    const error: BusinessError = failure as BusinessError;
    console.warn('[WindowAppearance] code=' + String(error.code || '') + ' message=' + String(error.message || '窗口外观设置失败'));
  }
}
