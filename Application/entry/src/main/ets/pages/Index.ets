/**
 * 【文件职责】App 唯一的 @Entry 页面，也是全局“路由器”和主容器。
 * 【启动流程】aboutToAppear → restoreStartupState：读取隐私同意 → 未同意只显示隐私页（同意前不初始化任何 SDK）
 * → 同意后 AuthService.restore 恢复会话 → 按登录状态显示页签：游客“推荐 · 榜单 · 我的”，登录“推荐 · 榜单 · 好友 · 我的”。
 * 窄屏使用底部页签栏，宽屏（lg 断点）改为侧边导航栏；“推荐”页右下角悬浮按钮打开发布页。
 * 【子页面导航】使用 Navigation + NavPathStack：pathStack.pushPathByName('路由名', 参数) 打开子页面，
 * pathMap() 根据路由名渲染对应的 NavDestination。新增页面时：新建组件 → 在 pathMap 中加分支 → 用 pushPathByName 打开。
 * 【系统入口】监听 CardDeepLink（碰一碰分享）与 ContinuationState（接续 / 通知 / 桌面卡片点击）写入的 AppStorage 键，
 * 在隐私与登录就绪后打开对应卡片、私信或页签。
 * 【窗口外观】统一预留左右与底部安全区并绘制底部手势区颜色；状态栏区域由首页各页签（homeTopStrip）与子页面自己绘制，
 *   随页面一起滑动 / 转场。只有启动加载、隐私确认与登录界面由这里预留并着色。
 */
import { PagePaletteName, PagePaletteRoute, pageColor } from '../common/PagePaletteUi';
import { EmailLoginPage } from '../components/EmailLoginPage';
import { DeletedCardsPage } from './DeletedCardsPage';
import { CardReportListPage } from './CardReportListPage';
import { CardReportDetailPage } from './CardReportDetailPage';
import { CardReportRoute } from '../model/CardReportModels';
import { ReportContentPage } from './ReportContentPage';
import { ReportRoute } from '../model/ContentStatusModels';
import { RandomFoodPage } from './RandomFoodPage';
import { FoodChoiceHistoryPage } from './FoodChoiceHistoryPage';
import { DraftsPage } from './SocialDiscoveryPages';
import { LocalDraft } from '../model/DraftModels';
import { common } from '@kit.AbilityKit';
import { FoodCard, UserProfile } from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';
import { RandomFoodWidgetStore } from '../service/RandomFoodWidgetStore';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { PrivacyStore } from '../service/PrivacyStore';
import { DiscoveryFeedState } from '../service/DiscoveryFeedState';
import { ImageRepository } from '../service/ImageRepository';
import { CardRepository } from '../repository/CardRepository';
import { clearPendingSharedCard, storePendingSharedCardId } from '../service/CardDeepLink';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { FriendRepository } from '../repository/FriendRepository';
import { FriendProfileResponse, GroupChatDetailResponse, GroupConversationSummary, SocialUser } from '../model/FriendModels';
import { ContinuationState } from '../service/ContinuationState';
import { PushNotificationService } from '../service/PushNotificationService';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { ServiceCardRemoteSyncService } from '../service/ServiceCardRemoteSyncService';
import { NearbyPage } from './NearbyPage';
import { FoodRankingPage } from './FoodRankingPage';
import { CreateCardPage } from './CreateCardPage';
import { ProfilePage } from './ProfilePage';
import { FavoriteCardsPage } from './FavoriteCardsPage';
import { CardHistoryPage } from './CardHistoryPage';
import { MyPublishedPage } from './MyPublishedPage';
import { PermissionsPrivacyPage } from './PermissionsPrivacyPage';
import { ProfileEditPage } from './ProfileEditPage';
import { ProfileSettingsPage } from './ProfileSettingsPage';
import { CardDetailPage } from './CardDetailPage';
import { FriendsPage } from './FriendsPage';
import { FriendProfilePage } from './FriendProfilePage';
import { FriendSearchPage } from './FriendSearchPage';
import { ChatPage } from './ChatPage';
import { GroupChatPage } from './GroupChatPage';
import { ShareCardPage } from './ShareCardPage';
import { BreakpointSystem, LayoutBreakpoint } from '../common/BreakpointSystem';
import { AppDestinationStyle, AppPageSurface, HOME_BAR_OVERLAP, TAB_SWITCH_MS } from '../common/AppPageUi';

// 打开用户主页的路由参数。
interface AuthorPageRoute { userUid: string; palette: PagePaletteName; }
// 打开卡片详情的路由参数。
interface CardDetailRoute { card: FoodCard; palette: PagePaletteName; }

// 启动或系统入口出错时的提示信息。
interface EntryErrorInfo {
  message?: string;
}

// 主容器页面。
@Entry
@Component
struct Index {
  @Provide('pathStack') pathStack: NavPathStack = new NavPathStack();
  @Provide('windowBreakpoint') windowBreakpoint: LayoutBreakpoint = 'sm';
  @State randomFoodVisible: boolean = false;
  @State foodChoiceVisible: boolean = false;
  @State createCardVisible: boolean = false;
  @State draftTarget: string = '';
  @State selectedDraftId: string = '';
  @State @Watch('onEntryAppearanceChanged') ready: boolean = false;
  @State @Watch('onEntryAppearanceChanged') privacyAccepted: boolean = false;
  @State privacyChecked: boolean = false;
  @State showFullPrivacy: boolean = false;
  @State @Watch('onEntryAppearanceChanged') loggedIn: boolean = false;
  @State @Watch('onEntryAppearanceChanged') loginRequested: boolean = false;
  @State loginBusy: boolean = false;
  @State loginMessage: string = '';
  @State loginBackRequest: number = 0;
  @State selectedCard: FoodCard | undefined = undefined;
  @State selectedFriend: SocialUser | undefined = undefined;
  @State selectedGroup: GroupConversationSummary | undefined = undefined;
  @State profile: UserProfile | undefined = undefined;
  @State profileRevision: number = 0;
  @State recommendationRevision: number = 0;
  @StorageLink('contentMutationRevision') @Watch('onContentMutation') contentMutationRevision: number = 0;
  @StorageLink('friendRelationshipRevision') @Watch('onFriendRelationshipChanged') friendRelationshipRevision: number = 0;
  @State @Watch('onEntryAppearanceChanged') selectedTab: number = 0;
  // 视觉页签：决定页签栏颜色与状态栏文字颜色。切换动画一开始就更新（selectedTab 要等动画结束才变），让它们与页面同时过渡。
  // 状态栏区域本身由各页签自己绘制（homeTopStrip），随页面一起滑动。
  @State visualTab: number = 0;
  @StorageLink('pageSurfaceRevision') pageSurfaceRevision: number = 0;
  @StorageLink('appSystemBarInk') systemBarInk: string = '#3D2A22';
  @StorageLink('appSystemTopPx') systemTopPx: number = 0;
  @StorageLink('profileCoverUrl') @Watch('onEntryAppearanceChanged') profileCoverUrl: string = '';
  @StorageLink('socialForegroundRevision') @Watch('syncRandomFoodWidget') widgetForegroundRevision: number = 0;
  private widgetScope: string = '';
  @StorageLink('appSystemBottomPx') systemBottomPx: number = 0;
  @StorageLink('appSystemLeftPx') systemLeftPx: number = 0;
  @StorageLink('appSystemRightPx') systemRightPx: number = 0;
  @StorageLink('appKeyboardVisible') keyboardVisible: boolean = false;
  @State navigationHomeVisible: boolean = true;
  @State sharedLinkMessage: string = '';
  @StorageLink('pendingSharedCardId') pendingSharedCardId: string = '';
  @StorageLink('pendingSharedCardRevision') @Watch('onPendingSharedCardChanged') pendingSharedCardRevision: number = 0;
  @StorageLink('pendingSystemEntryRoute') @Watch('onPendingSystemEntryChanged') pendingSystemEntryRoute: string = '';
  @StorageLink('pendingSystemEntryCardId') pendingSystemEntryCardId: string = '';
  @StorageLink('pendingSystemEntryFriendUid') pendingSystemEntryFriendUid: string = '';
  @StorageLink('pendingSystemEntryGroupId') pendingSystemEntryGroupId: string = '';
  @StorageLink('pendingSystemEntryTab') pendingSystemEntryTab: number = 0;
  @State openingSharedCard: boolean = false;
  private sharedCardGeneration: number = 0;
  private openingSystemEntry: boolean = false;
  private cardRepository: CardRepository = new CardRepository();
  private friendRepository: FriendRepository = new FriendRepository();
  private tabsController: TabsController = new TabsController();

  // 页面创建时恢复启动状态。
  aboutToAppear(): void {
    ContinuationState.showTab(this.selectedTab);
    this.restoreStartupState();
  }

  // 系统返回键：登录界面打开时交给登录界面处理（返回 true 拦截），否则交给系统 / Navigation。
  onBackPress(): boolean {
    if (!this.loginRequested) return false;
    this.loginBackRequest += 1;
    return true;
  }

  // 需要登录时显示登录界面，并给出提示文字（已登录时忽略）。
  private requestLogin(message: string = '登录后可发布、收藏和使用好友功能。'): void {
    if (this.loggedIn) return;
    this.loginMessage = message;
    this.loginRequested = true;
  }

  // 关闭登录界面，继续以游客身份浏览。
  private continueBrowsing(): void {
    if (this.loginBusy) return;
    this.loginRequested = false;
    this.loginMessage = '';
  }

  private restoreBusy: boolean = false;
  @StorageLink('sessionRestoreMessage') sessionRestoreMessage: string = '';
  // 启动恢复：读取隐私同意 → 恢复会话 → 同步 Push 与桌面卡片 → 处理待打开的入口。
  private async restoreStartupState(): Promise<void> {
    if (this.restoreBusy) return;
    this.restoreBusy = true;
    const intent: number = AuthService.sessionIntent();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.privacyAccepted = await PrivacyStore.hasConsent(context);
      this.privacyChecked = this.privacyAccepted;
      if (this.privacyAccepted) {
        const restored: UserProfile | undefined = await AuthService.restore(context, true);
        if (intent !== AuthService.sessionIntent()) return;
        this.profile = restored;
        this.loggedIn = this.profile !== undefined;
        if (this.profile !== undefined) {
          ImageRepository.setCacheOwner(this.profile.uid);
          void this.syncPushIfEnabled(context, this.profile.uid);
        }
      }
    } finally {
      this.restoreBusy = false;
      this.ready = true;
      this.openPendingSharedCard();
      this.openPendingSystemEntry();
    }
  }

  // 已开启通知时，同步一次 Push 登记（失败不影响启动）。
  private async syncPushIfEnabled(context: common.UIAbilityContext, profileId: string): Promise<void> {
    try {
      await PushNotificationService.syncIfEnabled(context, profileId);
    } catch (_error) {
      // 即使 Push Kit 或推送服务暂时不可用，登录和启动也必须能正常使用；“权限与隐私”页提供重试入口。
    }
    try {
      await ServiceCardRemoteSyncService.syncIfEnabled(context);
    } catch (_error) {
      // 桌面卡片远程登记绝不阻塞账号恢复；它有单独的同意卡片，保留重试操作与状态说明。
    }
  }

  // 用户同意隐私：保存同意并继续启动。
  private async acceptPrivacy(): Promise<void> {
    if (!this.privacyChecked) {
      this.loginMessage = '请先阅读并勾选隐私摘要。';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await PrivacyStore.setConsent(context, true);
    this.privacyAccepted = true;
    this.loginMessage = '';
    this.openPendingSharedCard();
    this.openPendingSystemEntry();
  }

  // 用户拒绝隐私：只保留隐私说明页。
  private async rejectPrivacy(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await context.terminateSelf();
  }

  // 登录完成：刷新资料、同步 Push 与桌面卡片、处理待打开的入口。
  private finishLogin(context: common.UIAbilityContext, profile: UserProfile): void {
    this.profile = profile;
    this.loggedIn = true;
    this.loginRequested = false;
    ImageRepository.setCacheOwner(profile.uid);
    DiscoveryFeedState.clear();
    this.recommendationRevision += 1;
    // Push 与桌面卡片登记都是可选增强，绝不能延迟登录后进入首页。
    void this.syncPushIfEnabled(context, profile.uid);
    this.openPendingSharedCard();
    this.openPendingSystemEntry();
  }

  // 会话结束（退出、注销、会话失效）：清理状态并回到游客页签。
  private sessionEnded(message: string): void {
    this.sharedCardGeneration += 1;
    clearPendingSharedCard();
    this.sharedLinkMessage = '';
    this.pathStack.clear();
    DiscoveryFeedState.clear();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    void ImageRepository.clearCachedMedia(context).catch((): void => {});
    this.loggedIn = false;
    this.loginRequested = false;
    this.profile = undefined;
    this.profileCoverUrl = '';
    this.loginMessage = message;
    this.selectedTab = 0;
    this.visualTab = 0;
    this.recommendationRevision += 1;
    ContinuationState.clearPending();
    ContinuationState.showTab(0);
  }

  // 打开卡片详情。
  private openCard(card: FoodCard): void {
    this.selectedCard = card;
    ContinuationState.showCard(card.id);
    const route: CardDetailRoute = { card, palette: this.navigationHomeVisible ? this.homePalette() : AppPageSurface.palette };
    this.pathStack.pushPathByName('card-detail', route);
  }


  // 收到新的分享链接时尝试打开。
  private onPendingSharedCardChanged(): void {
    this.sharedCardGeneration += 1;
    this.sharedLinkMessage = '';
    void this.openPendingSharedCard();
  }

  // 收到新的系统入口时尝试打开。
  private onPendingSystemEntryChanged(): void {
    this.openPendingSystemEntry();
  }

  // 打开待处理的系统入口（页签 / 卡片 / 私信 / 群聊）。
  private async openPendingSystemEntry(): Promise<void> {
    const route: string = this.pendingSystemEntryRoute.trim();
    if (this.openingSystemEntry || route.length === 0 || !this.ready
      || !this.privacyAccepted) return;
    if (!this.loggedIn && route !== 'card' && (route !== 'tab' || this.pendingSystemEntryTab !== 0)) {
      this.requestLogin('登录后可打开好友消息。');
      return;
    }
    this.openingSystemEntry = true;
    const entrySession: number = AuthSessionStore.generation();
    try {
      if (route === 'tab') {
        const tab: number = this.pendingSystemEntryTab >= 0 && this.pendingSystemEntryTab <= 4
          ? this.pendingSystemEntryTab : 0;
        ContinuationState.clearPending();
        if (tab === 3) {
          // “制作”已不再是页签；旧的接续或卡片入口会把它作为子页面打开。
          this.selectTab(0);
          this.openCreateCard();
          return;
        }
        this.selectTab(tab);
        return;
      }
      if (route === 'card') {
        const cardId: string = this.pendingSystemEntryCardId.trim();
        ContinuationState.clearPending();
        if (cardId.length > 0) {
          storePendingSharedCardId(cardId);
        }
        return;
      }
      if (route === 'group-chat') {
        const groupId: string = this.pendingSystemEntryGroupId.trim();
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const response: GroupChatDetailResponse = await this.friendRepository.groupDetail(context, groupId);
        if (entrySession !== AuthSessionStore.generation() || this.pendingSystemEntryRoute !== route ||
          this.pendingSystemEntryGroupId !== groupId) return;
        ContinuationState.clearPending();
        this.openGroupChat(response.group);
        return;
      }
      if (route === 'friend-chat') {
        const friendUid: string = this.pendingSystemEntryFriendUid.trim();
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const response: FriendProfileResponse = await this.friendRepository.friendProfile(context, friendUid, '', 1);
        if (entrySession !== AuthSessionStore.generation() || this.pendingSystemEntryRoute !== route ||
          this.pendingSystemEntryFriendUid !== friendUid) return;
        const friend: SocialUser | undefined = response.profile.user.friendshipState === 'FRIEND'
          ? response.profile.user : undefined;
        ContinuationState.clearPending();
        if (friend !== undefined) {
          this.openChat(friend);
        } else {
          this.sharedLinkMessage = '无法打开这段好友会话，好友关系可能已发生变化。';
          this.selectTab(2);
        }
        return;
      }
      ContinuationState.clearPending();
    } catch (error) {
      if (entrySession !== AuthSessionStore.generation()) return;
      ContinuationState.clearPending();
      const detail = error as EntryErrorInfo;
      this.sharedLinkMessage = detail.message && detail.message.length > 0
        ? `系统入口打开失败：${detail.message}` : '系统入口暂时无法打开，请稍后重试。';
    } finally {
      this.openingSystemEntry = false;
    }
  }

  /**
   * 碰一碰分享链接可能在隐私同意与登录恢复完成之前就唤起 App：先把不透明的卡片 id 暂存在 AppStorage，就绪后再加载与普通点击相同的公开详情页。
   */
  // 打开待处理的分享卡片。
  private async openPendingSharedCard(): Promise<void> {
    const cardId = this.pendingSharedCardId.trim();
    if (this.openingSharedCard || cardId.length === 0 || !this.ready
      || !this.privacyAccepted) return;
    const generation: number = this.sharedCardGeneration;
    this.openingSharedCard = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const card: FoodCard = await this.cardRepository.detail(context, cardId);
      if (generation === this.sharedCardGeneration && this.privacyAccepted
        && this.pendingSharedCardId === cardId) {
        clearPendingSharedCard();
        if (card.status !== 'APPROVED') {
          this.sharedLinkMessage = '无法打开分享的商品卡，它可能已删除或不再公开。';
          return;
        }
        this.sharedLinkMessage = '';
        this.openCard(card);
      }
    } catch (error) {
      if (generation === this.sharedCardGeneration && this.privacyAccepted
        && this.pendingSharedCardId === cardId) {
        const unavailable: boolean = error instanceof CloudBusinessError &&
          ['CONTENT_UNAVAILABLE', 'CONTENT_ACCESS_DENIED', 'NOT_FOUND', 'ACCOUNT_INACTIVE'].includes(error.code);
        if (unavailable) clearPendingSharedCard();
        const detail = error as EntryErrorInfo;
        this.sharedLinkMessage = detail.message && detail.message.length > 0
          ? `无法打开分享的商品卡：${detail.message}`
          : unavailable ? '分享的商品卡已不可访问。' : '分享卡片暂时无法读取，请重试。';
      }
    } finally {
      this.openingSharedCard = false;
      // 等待上一次详情请求时可能又收到了新链接：它的 @Watch 回调被 openingSharedCard 挡住了，这里继续处理。
      if (this.pendingSharedCardId.length > 0
        && (this.pendingSharedCardId !== cardId || generation !== this.sharedCardGeneration)) {
        void this.openPendingSharedCard();
      }
    }
  }

  // 打开私信。
  private openChat(friend: SocialUser): void {
    this.selectedFriend = friend;
    ContinuationState.showFriend(friend.uid);
    this.pathStack.pushPathByName('friend-chat', null);
  }

  // 打开好友主页。
  private openFriendProfile(friend: SocialUser): void {
    this.pathStack.pushPathByName('friend-profile', friend);
  }

  // 打开添加好友页。
  private openAddFriend(): void {
    this.pathStack.pushPathByName('add-friend', null);
  }

  // 好友申请状态变化：通知好友页刷新。
  private friendRequestChanged(): void {
    AppStorage.setOrCreate('socialForegroundRevision',
      (AppStorage.get<number>('socialForegroundRevision') || 0) + 1);
  }

  // 打开群聊。
  private openGroupChat(group: GroupConversationSummary): void {
    this.selectedGroup = group;
    this.pathStack.pushPathByName('group-chat', null);
  }

  // 打开“发给好友”页。
  private shareCardToFriend(card: FoodCard): void {
    if (!this.loggedIn) {
      this.requestLogin('登录后可将卡片分享给食刻好友。');
      return;
    }
    this.selectedCard = card;
    ContinuationState.showCard(card.id);
    this.pathStack.pushPathByName('share-card', null);
  }

  // 分享后直接进入与该好友的私信。
  private openChatAfterShare(friend: SocialUser): void {
    this.selectedFriend = friend;
    ContinuationState.showFriend(friend.uid);
    this.pathStack.replacePathByName('friend-chat', friend);
  }

  // 我的卡片发生变化（删除等）。
  private profileCardsChanged(): void {
    this.profileRevision += 1;
  }

  // 资料更新后刷新本页缓存的资料。
  private profileUpdated(profile: UserProfile): void {
    this.profile = profile;
    this.profileRevision += 1;
  }

  // 发布成功：关闭发布页并刷新推荐与我的卡片。
  private cardPublished(): void {
    DiscoveryFeedState.clear();
    this.recommendationRevision += 1;
    this.profileRevision += 1;
  }

  // 内容变化（修改生效等）时刷新推荐流状态。
  private onContentMutation(): void {
    DiscoveryFeedState.clear();
    this.recommendationRevision += 1; this.profileRevision += 1;
  }

  // 好友关系变化时清除推荐流缓存（好友推荐可能变化）。
  private onFriendRelationshipChanged(): void { DiscoveryFeedState.clear(); }

  // 逻辑页签 id 固定为 0 推荐 / 1 榜单 / 2 好友 / 4 我的；3（制作）现在是子页面。
  // 逻辑页签 id → Tabs 中的实际位置（游客没有“好友”页签）。
  private tabPosition(index: number): number {
    return this.loggedIn ? (index === 4 ? 3 : index) : index === 4 ? 2 : index === 1 ? 1 : 0;
  }

  // Tabs 中的实际位置 → 逻辑页签 id（tabPosition 的逆映射）。
  private logicalTab(position: number): number {
    return this.loggedIn ? (position === 3 ? 4 : position) : position === 2 ? 4 : position === 1 ? 1 : 0;
  }

  // 用户滑动或点击切换页签。
  private onTabPositionChanged(position: number): void {
    this.selectTab(this.logicalTab(position));
  }

  // 切换动画开始（点击页签或松手后）：立即切换视觉页签，页签栏颜色在与 Tabs 相同的时长内渐变到目标页签。
  private beginTabSwitch(targetPosition: number): void {
    const target: number = this.logicalTab(targetPosition);
    this.getUIContext().animateTo({ duration: TAB_SWITCH_MS, curve: Curve.Friction }, (): void => { this.visualTab = target; });
  }

  // 切换动画结束（包括拖动后弹回原页签）：视觉页签与实际页签对齐。
  private endTabSwitch(position: number): void {
    this.visualTab = this.logicalTab(position);
  }


  // 打开发布页（未登录时提示登录）。
  private openCreateCard(): void {
    if (!this.loggedIn) {
      this.requestLogin('登录后可发布推荐。');
      return;
    }
    this.pathStack.pushPathByName('create-card', null);
  }

  // 切换到某个页签。
  private selectTab(index: number): void {
    const safeIndex: number = this.loggedIn
      ? (index >= 0 && index <= 4 && index !== 3 ? index : 0) : (index === 4 ? 4 : index === 1 ? 1 : 0);
    this.selectedTab = safeIndex;
    // 程序切换（深链、通知、退出登录等）没有拖动过程，直接对齐视觉页签。
    if (this.visualTab !== safeIndex) this.visualTab = safeIndex;
    AppStorage.setOrCreate('discoveryVisible', this.navigationHomeVisible && safeIndex === 0);
    ContinuationState.showTab(safeIndex);
    if (safeIndex === 2) {
      AppStorage.setOrCreate('socialForegroundRevision',
        (AppStorage.get<number>('socialForegroundRevision') || 0) + 1);
    }
  }

  // 根据路由名渲染子页面（NavDestination）；所有子页面在这里集中注册。
  @Builder
  pathMap(routeName: string, routeParam: object) {
    if (routeName === 'card-detail' && routeParam !== null && routeParam !== undefined) {
      CardDetailPage({
        card: (routeParam as CardDetailRoute).card,
        palette: (routeParam as CardDetailRoute).palette,
        loggedIn: this.loggedIn,
        onRequireLogin: (message: string): void => this.requestLogin(message),
        onOpenAuthor: (uid: string): void => {
          const request: AuthorPageRoute = { userUid: uid, palette: AppPageSurface.palette }; this.pathStack.pushPathByName('user-page', request);
        },
        onShareToFriend: (card: FoodCard): void => {
          this.shareCardToFriend(card);
        }
      })
    } else if (routeName === 'friend-chat' && this.selectedFriend !== undefined) {
      ChatPage({
        friend: this.selectedFriend,
        onOpenCard: (card: FoodCard): void => {
          this.openCard(card);
        }
      })
    } else if (routeName === 'user-page' && routeParam !== null && routeParam !== undefined) {
      FriendProfilePage({ friendUid: (routeParam as AuthorPageRoute).userUid, palette: (routeParam as AuthorPageRoute).palette,
        onOpenChat: (friend: SocialUser): void => this.openChat(friend),
        onOpenCard: (card: FoodCard): void => this.openCard(card) })
    } else if (routeName === 'friend-profile' && routeParam !== null && routeParam !== undefined) {
      FriendProfilePage({
        friendUid: (routeParam as SocialUser).uid,
        friendCode: (routeParam as SocialUser).friendCode,
        onOpenChat: (friend: SocialUser): void => {
          this.openChat(friend);
        },
        onOpenCard: (card: FoodCard): void => {
          this.openCard(card);
        }
      })
    } else if (routeName === 'add-friend') {
      FriendSearchPage({
        onOpenChat: (friend: SocialUser): void => {
          this.selectedFriend = friend;
          ContinuationState.showFriend(friend.uid);
          this.pathStack.replacePathByName('friend-chat', friend);
        },
        onFriendRequestChanged: (): void => {
          this.friendRequestChanged();
        }
      })
    } else if (routeName === 'group-chat' && this.selectedGroup !== undefined) {
      GroupChatPage({
        group: this.selectedGroup,
        onOpenCard: (card: FoodCard): void => {
          this.openCard(card);
        },
        onGroupChanged: (): void => {
          AppStorage.setOrCreate('socialForegroundRevision',
            (AppStorage.get<number>('socialForegroundRevision') || 0) + 1);
        }
      })
    } else if (routeName === 'share-card' && this.selectedCard !== undefined) {
      ShareCardPage({
        card: this.selectedCard,
        onOpenChat: (friend: SocialUser): void => {
          this.openChatAfterShare(friend);
        },
        onOpenGroup: (group: GroupConversationSummary): void => {
          this.selectedGroup = group;
          this.pathStack.replacePathByName('group-chat', group);
        }
      })
    } else if (routeName === 'profile-published') {
      MyPublishedPage({
        onOpenCard: (card: FoodCard): void => this.openCard(card),
        onCardsChanged: (): void => this.profileCardsChanged()
      })
    } else if (routeName === 'profile-favorites') {
      FavoriteCardsPage({ onOpenCard: (card: FoodCard): void => this.openCard(card) })
    } else if (routeName === 'my-reports') {
      CardReportListPage()
    } else if (routeName === 'card-review-reports') {
      CardReportListPage({ admin: true })
    } else if ((routeName === 'report-detail' || routeName === 'card-review-detail') && routeParam !== null && routeParam !== undefined) {
      CardReportDetailPage({ reportId: (routeParam as CardReportRoute).reportId, admin: routeName === 'card-review-detail' })
    } else if (routeName === 'deleted-cards') {
      DeletedCardsPage()
    } else if (routeName === 'report-content' && routeParam !== null && routeParam !== undefined) {
      ReportContentPage({ targetType: (routeParam as ReportRoute).targetType, targetId: (routeParam as ReportRoute).targetId })
    } else if (routeName === 'random-food') {
      NavDestination() {
        RandomFoodPage({ palette: this.choicePalette(routeParam), navigationVisible: this.randomFoodVisible,
          onBack: (): void => { this.pathStack.pop(); }, onOpenCard: (card: FoodCard): void => this.openCard(card),
          onOpenHistory: (): void => { const request: PagePaletteRoute = { palette: this.choicePalette(routeParam) }; this.pathStack.pushPathByName('food-choice-history', request); },
          onLogin: (): void => this.requestLogin('登录后使用我的、好友来源和云端选择记录。') })
      }.hideTitleBar(true).attributeModifier(new AppDestinationStyle('', this.choiceCanvas(routeParam), this.choiceCanvas(routeParam), this.choicePalette(routeParam)))
        .onShown((): void => { this.randomFoodVisible = true; }).onHidden((): void => { this.randomFoodVisible = false; })
    } else if (routeName === 'food-choice-history') {
      NavDestination() {
        FoodChoiceHistoryPage({ palette: this.choicePalette(routeParam), navigationVisible: this.foodChoiceVisible, onBack: (): void => { this.pathStack.pop(); },
          onOpenCard: (card: FoodCard): void => this.openCard(card), onLogin: (): void => this.requestLogin('登录后查看云端选择记录。') })
      }.hideTitleBar(true).attributeModifier(new AppDestinationStyle('', this.choiceCanvas(routeParam), this.choiceCanvas(routeParam), this.choicePalette(routeParam)))
        .onShown((): void => { this.foodChoiceVisible = true; }).onHidden((): void => { this.foodChoiceVisible = false; })

    } else if (routeName === 'create-card') {
      NavDestination() {
        CreateCardPage({ pageActive: this.createCardVisible, accountUid: this.profile === undefined ? '' : this.profile.uid,
          onPublished: (): void => this.cardPublished() })
      }.attributeModifier(new AppDestinationStyle('', $r('app.color.create_canvas'), $r('app.color.create_header'), 'CREATE'))
        .onShown((): void => { this.createCardVisible = true; }).onHidden((): void => { this.createCardVisible = false; })
    } else if (routeName === 'drafts') {
      NavDestination() { DraftsPage({ onRestore: (draft: LocalDraft): void => { this.draftTarget = draft.targetCardId; this.selectedDraftId = draft.draftId; this.pathStack.pushPathByName('restore-draft', null); } }) }.attributeModifier(new AppDestinationStyle('草稿箱', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL'))
    } else if (routeName === 'restore-draft') {
      NavDestination() { CreateCardPage({ palette: 'PERSONAL', editCardId: this.draftTarget, restoreDraftId: this.selectedDraftId, accountUid: this.profile === undefined ? '' : this.profile.uid }) }.attributeModifier(new AppDestinationStyle('恢复草稿', $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL'))
    } else if (routeName === 'profile-history') {
      CardHistoryPage({ onOpenCard: (card: FoodCard): void => this.openCard(card) })
    } else if (routeName === 'profile-privacy') {
      PermissionsPrivacyPage()
    } else if (routeName === 'profile-edit') {
      ProfileEditPage({ onProfileChanged: (profile: UserProfile): void => this.profileUpdated(profile) })
    } else if (routeName === 'profile-settings') {
      ProfileSettingsPage({ onSessionEnded: (message: string): void => this.sessionEnded(message),
        onProfileChanged: (profile: UserProfile): void => this.profileUpdated(profile) })
    }
  }

  // 隐私说明中的一行。
  @Builder
  private privacyNoticeRow(title: string, description: string) {
    Row({ space: 12 }) {
      Column() {}
        .width(4).height(28).backgroundColor($r('app.color.accent_action')).borderRadius(2)
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink')).width('100%')
        Text(description).fontSize(13).lineHeight(20)
          .fontColor($r('app.color.muted')).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  // 隐私同意页面。
  @Builder
  private privacyPage() {
    Scroll() {
      Column({ space: 20 }) {
        Row({ space: 14 }) {
          Image($r('app.media.app_icon')).width(64).height(64).borderRadius(20)
            .accessibilityLevel('no')
          Column({ space: 4 }) {
            Text('食刻').fontSize(28).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink')).width('100%')
            Text('真实画面，认真推荐').fontSize(14)
              .fontColor($r('app.color.leaf')).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')

        Column({ space: 16 }) {
          Text('开始前，请了解').fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%')
          Text('我们只会在功能需要时使用必要数据。')
            .fontSize(13).fontColor($r('app.color.muted')).width('100%')

          this.privacyNoticeRow('账号认证', '无需登录即可浏览公开推荐；注册需验证邮箱或华为账号，之后可使用唯一昵称和密码登录。服务端仅保存加盐密码哈希。')
          Divider().strokeWidth(1).color($r('app.color.line'))
          this.privacyNoticeRow('位置', '浏览推荐无需定位；仅发布时按需使用精确位置，离开设备前舍入到约 100 米。')
          Divider().strokeWidth(1).color($r('app.color.line'))
          this.privacyNoticeRow('图片', '使用系统图片选择器；你主动发布时，实拍图会先在本机移除 EXIF/GPS，再上传到 AGC 云存储。')
          Divider().strokeWidth(1).color($r('app.color.line'))
          this.privacyNoticeRow('好友与私信', '食刻号、好友关系和你主动发送的文字、卡片或 HTTPS 链接会写入云端，仅用于好友功能。')
          Divider().strokeWidth(1).color($r('app.color.line'))
          this.privacyNoticeRow('通知与多设备', '只有你主动开启后才登记加密的设备推送令牌；桌面卡片只缓存公开推荐摘要，跨设备只接续页面和不透明标识。')
          Divider().strokeWidth(1).color($r('app.color.line'))
          this.privacyNoticeRow('第三方页面', '由对应平台提供，价格与活动以来源页面为准。')

          Button(this.showFullPrivacy ? '收起完整说明' : '查看完整隐私说明')
            .width('100%').height(48).backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.ink')).border({ width: 1, color: $r('app.color.line') })
            .onClick(() => this.showFullPrivacy = !this.showFullPrivacy)
          if (this.showFullPrivacy) {
            Text('食刻使用 AGC Auth 验证邮箱或华为账号，并通过自有账号认证提供唯一昵称与密码登录。食刻服务端保存昵称与账号的关联、加盐密码哈希和登录限流计数，不保存明文密码。修改昵称会同步改变登录名，找回密码需再次验证绑定身份。昵称在注册或主动保存资料时处理，头像先在本机重编码并移除 EXIF/GPS。首页推荐不限距离，浏览时不读取定位。你主动发布时，实拍图、公开商品字段、约 100 米精度的位置以及后续主动提交的互动记录会进入 AGC 云端。好友功能会保存食刻号、好友申请、好友关系、一对一和群聊会话的未读数，以及你主动发送的文字和卡片标识；粘贴的链接会作为普通文字消息保存。系统 Push 默认关闭，你主动开启后，设备 Push Token 会在食刻云端加密保存，系统通知正文不包含私信内容。桌面服务卡片只在本机缓存一条公开推荐摘要；跨设备接续只传页签、商品卡 ID 或好友 ID，不传聊天正文和账号凭据。移除好友时会话从双方页面移除，并同步清理全部一对一私信。正式上架前必须根据平台要求补充内容审核方案，并在 AGC 配置同内容的 HTTPS 隐私政策地址。')
              .fontSize(13).lineHeight(21).fontColor($r('app.color.muted')).width('100%')
              .padding(14).backgroundColor($r('app.color.canvas')).borderRadius(14)
          }

          Row({ space: 10 }) {
            Checkbox({ name: 'privacy', group: 'startup' }).select(this.privacyChecked)
              .selectedColor($r('app.color.accent_action'))
              .onChange((value: boolean) => this.privacyChecked = value)
            Text('我已阅读并同意隐私说明').fontSize(14)
              .fontColor($r('app.color.ink')).layoutWeight(1)
          }.width('100%').height(48)

          Button('同意并继续').enabled(this.privacyChecked).width('100%').height(50)
            .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
            .onClick(() => this.acceptPrivacy())
          Button('暂不同意并退出').width('100%').height(48)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.muted'))
            .border({ width: 1, color: $r('app.color.line') }).onClick(() => this.rejectPrivacy())
        }
        .width('100%').padding(18).backgroundColor($r('app.color.surface')).borderRadius(22)
        .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)

        Text('当前为云端测试版：发布、互动、好友申请和私信仅在你主动操作时写入；通知也只有在“权限与隐私”中主动开启后才会登记。')
          .fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
          .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)

        if (this.loginMessage.length > 0) {
          Text(this.loginMessage).fontSize(13).lineHeight(20)
            .fontColor($r('app.color.warning')).width('100%')
            .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
        }
      }
      .width('100%').padding({ left: 20, right: 20, top: 34, bottom: 30 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%').scrollBar(BarState.Off)
    .backgroundColor($r('app.color.canvas'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // 登录界面。
  @Builder
  private loginPage(): void {
    EmailLoginPage({
      backRequest: this.loginBackRequest,
      onBusyChanged: (busy: boolean): void => { this.loginBusy = busy; },
      onClose: (): void => this.continueBrowsing(),
      onAuthenticated: (profile: UserProfile): void => {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.finishLogin(context, profile);
      }
    })
  }

  // 侧边导航栏中的一项（宽屏）。
  @Builder
  private navigationRailItem(index: number, label: string, icon: Resource): void {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        Image(icon).width(22).height(22).objectFit(ImageFit.Contain)
          .fillColor(this.visualTab === index ? this.tabAction() : $r('app.color.muted'))
          .accessibilityLevel('no');
        Text(label).fontSize(13)
          .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.visualTab === index ? this.tabAction() : $r('app.color.muted'));
      }.width('100%');
    }
    .width('100%').height(64).padding(6).borderRadius(16)
    .backgroundColor(this.visualTab === index ? this.tabHighlight() : $r('app.color.surface'))
    .accessibilityText(label).accessibilitySelected(this.selectedTab === index)
    .onClick((): void => {
      if (this.selectedTab !== index) this.tabsController.changeIndex(this.tabPosition(index));
    });
  }

  // 侧边导航栏（宽屏）。
  @Builder
  private navigationRail(): void {
    Scroll() {
      Column({ space: 8 }) {
        Text('食刻').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent_action'))
          .margin({ bottom: 16 }).accessibilityLevel('no');
        this.navigationRailItem(0, '推荐', $r('app.media.nav_recommend'));
        this.navigationRailItem(1, '榜单', $r('app.media.nav_ranking'));
        if (this.loggedIn) {
          this.navigationRailItem(2, '好友', $r('app.media.nav_friends'));
        }
        this.navigationRailItem(4, '我的', $r('app.media.nav_profile'));
      }.width('100%').padding({ left: 10, right: 10, top: 22 + (this.homeNoticeVisible() ? 0 : this.systemTopVp()), bottom: 22 });
    }
    .width(BreakpointSystem.NAV_RAIL_WIDTH).height('100%').scrollBar(BarState.Off)
    .align(Alignment.Top).backgroundColor($r('app.color.surface'))
    .border({ width: { right: 1 }, color: $r('app.color.line') });
  }

  // 游客访问需要登录的页签时显示的提示页。
  @Builder
  private guestAccountPage(title: string, description: string) {
    Column({ space: 16 }) {
      Text(title).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.personal_ink'))
      Text(description).fontSize(14).lineHeight(22).fontColor($r('app.color.personal_muted'))
        .textAlign(TextAlign.Center).width('86%')
      Button('登录 / 注册').height(48).width('80%')
        .backgroundColor($r('app.color.personal_action')).fontColor($r('app.color.personal_surface'))
        .onClick((): void => this.requestLogin(description))
      Button('设置').height(48).width('80%')
        .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_action'))
        .accessibilityText('打开设置').onClick((): void => this.pathStack.pushPathByName('profile-settings', null))
      Button('继续看推荐').height(48).width('80%')
        .backgroundColor($r('app.color.personal_surface')).fontColor($r('app.color.personal_action'))
        .onClick((): void => {
          this.tabsController.changeIndex(0);
          this.selectTab(0);
        })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.personal_canvas'))
  }

  // 底部页签按钮。
  @Builder
  private bottomTab(label: string, index: number, icon: Resource) {
    Column({ space: 2 }) {
      Image(icon).width(22).height(22).objectFit(ImageFit.Contain)
        .fillColor(this.visualTab === index ? this.tabAction() : $r('app.color.muted'))
        .accessibilityLevel('no')
      Text(label).fontSize(11)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.visualTab === index ? this.tabAction() : $r('app.color.muted'))
      Column().width(5).height(5).borderRadius(3)
        .backgroundColor(this.visualTab === index ? this.tabHighlightDot() : Color.Transparent)
    }
    .width('100%').height(58).justifyContent(FlexAlign.Center)
    .accessibilityText(label).accessibilitySelected(this.selectedTab === index)
  }

  // 发布悬浮按钮。
  @Builder
  private publishFab() {
    // 使用系统符号而不是线条 SVG：SVG 线条不受 fillColor 影响，会导致加号看不见。
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.plus')).fontSize(28).fontWeight(FontWeight.Bold)
        .fontColor([$r('app.color.discovery_canvas')]).accessibilityLevel('no')
    }
    .width(58).height(58).opacity(1).backgroundColor($r('app.color.discovery_accent'))
    .border({ width: 3, color: $r('app.color.discovery_canvas') })
    .shadow({ radius: 16, color: '#40000000', offsetY: 6 })
    .margin({ right: 18, bottom: 18 })
    .accessibilityText('发布推荐')
    .onClick((): void => this.openCreateCard())
  }

  // 页签容器（窄屏底部页签 / 宽屏侧边栏共用同一个 Tabs）。
  // 首页顶部是否显示了提示条（会话恢复失败 / 分享链接提示）：显示时提示条承担状态栏区域，页签内不再重复预留。
  private homeNoticeVisible(): boolean {
    return (!this.loggedIn && this.sessionRestoreMessage.length > 0) || this.sharedLinkMessage.length > 0;
  }

  // 某个页签自己的状态栏区域：放在页签内容里，随页签一起滑动，颜色与页面同步。
  // “我的”页有主页背景时，ProfilePage 把背景图向上画进这一区域并盖住这里的颜色。
  @Builder
  private homeTopStrip(tab: number): void {
    Column().width('100%').height(this.homeNoticeVisible() ? 0 : this.systemTopVp())
      .backgroundColor(this.homeHeaderFor(tab)).hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
  }

  @Builder
  private mainTabs() {
    Column({ space: 0 }) {
      if (this.homeNoticeVisible()) {
        Column().width('100%').height(this.systemTopVp()).backgroundColor($r('app.color.accent_soft'))
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
      }
      if (!this.loggedIn && this.sessionRestoreMessage.length > 0) {
        Row({ space: 8 }) {
          Text(this.sessionRestoreMessage).fontSize(12).fontColor($r('app.color.muted')).layoutWeight(1)
          Button('重试恢复').height(48).borderRadius(24).fontColor($r('app.color.action_text')).backgroundColor($r('app.color.surface')).onClick((): void => { void this.restoreStartupState(); })
        }.width('100%').padding({ left: 16, right: 12 }).backgroundColor($r('app.color.accent_soft'))
      }
      if (this.sharedLinkMessage.length > 0) {
        Row({ space: 10 }) {
          Text(this.sharedLinkMessage).fontSize(12).lineHeight(18).fontColor($r('app.color.warning'))
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
          if (this.pendingSharedCardId.length > 0) {
            Button('重试').height(44).fontSize(12).enabled(!this.openingSharedCard)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.warning'))
              .onClick((): void => { void this.openPendingSharedCard(); });
          }
          Button('关闭').height(44).fontSize(12).backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.warning')).border({ width: 1, color: $r('app.color.line') })
            .accessibilityText('关闭提示').onClick((): void => {
              this.sharedCardGeneration += 1;
              clearPendingSharedCard();
              this.sharedLinkMessage = '';
            });
        }
        .width('100%').padding({ left: 16, right: 12, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.accent_soft')).border({ width: 1, color: $r('app.color.line') });
      }
      Row() {
        if (this.windowBreakpoint === 'lg') {
          this.navigationRail();
        }
        // 断点变化时保留同一个 Tabs 子树，宽屏只是隐藏页签栏；草稿、列表状态和页签生命周期都留在各自页面中。
        Tabs({ barPosition: BarPosition.End, index: this.tabPosition(this.selectedTab), controller: this.tabsController }) {
          TabContent() {
            Column() {
            this.homeTopStrip(0);
            Stack({ alignContent: Alignment.BottomEnd }) {
              Column() {
              NearbyPage({
                onOpenCard: (card: FoodCard): void => this.openCard(card),
                loggedIn: this.loggedIn,
                revision: this.recommendationRevision,
                onOpenMeal: (): void => {
                  this.pathStack.pushPathByName('random-food', null);
                }
              }).layoutWeight(1)
              }.width('100%').height('100%')
              this.publishFab()
            }.width('100%').layoutWeight(1)
            }.width('100%').height('100%')
          }.tabBar(this.bottomTab('推荐', 0, $r('app.media.nav_recommend')))
          TabContent() {
            Column() {
              this.homeTopStrip(1);
              FoodRankingPage({
                pageActive: this.navigationHomeVisible && this.selectedTab === 1,
                onOpenCard: (card: FoodCard): void => this.openCard(card),
                revision: this.recommendationRevision + this.friendRelationshipRevision,
                onRequireLogin: (): void => this.requestLogin('登录后查看好友推荐榜。')
              }).layoutWeight(1)
            }.width('100%').height('100%')
          }.tabBar(this.bottomTab('榜单', 1, $r('app.media.nav_ranking')))
          if (this.loggedIn) {
            TabContent() {
              Column() {
                this.homeTopStrip(2);
                FriendsPage({
                  pageActive: this.navigationHomeVisible && this.selectedTab === 2,
                  onOpenChat: (friend: SocialUser): void => this.openChat(friend),
                  onOpenProfile: (friend: SocialUser): void => this.openFriendProfile(friend),
                  onOpenGroup: (group: GroupConversationSummary): void => this.openGroupChat(group),
                  onOpenAddFriend: (): void => this.openAddFriend()
                }).layoutWeight(1)
              }.width('100%').height('100%')
            }.tabBar(this.bottomTab('好友', 2, $r('app.media.nav_friends')))
          }
          TabContent() {
            Column() {
              this.homeTopStrip(4);
              if (this.loggedIn) {
                ProfilePage({ revision: this.profileRevision }).layoutWeight(1)
              } else {
                Column() { this.guestAccountPage('我的', '登录后管理资料、收藏和浏览记录。') }.width('100%').layoutWeight(1)
              }
            }.width('100%').height('100%')
          }.tabBar(this.bottomTab('我的', 4, $r('app.media.nav_profile')))
        }
        .onChange((position: number): void => this.onTabPositionChanged(position))
        .animationDuration(TAB_SWITCH_MS)
        .onAnimationStart((_position: number, targetPosition: number, _event: TabsAnimationEvent): void => this.beginTabSwitch(targetPosition))
        .onAnimationEnd((position: number, _event: TabsAnimationEvent): void => this.endTabSwitch(position))
        .barMode(BarMode.Fixed)
        .layoutWeight(1).height('100%').barHeight(this.windowBreakpoint === 'lg' ? 0 : 58)
        .scrollable(this.windowBreakpoint !== 'lg')
        .backgroundColor(this.tabCanvas()).barBackgroundColor(this.tabCanvas()).clip(true)
        .expandSafeArea([], []);
      }.width('100%').layoutWeight(1);
    }
    .width('100%').height('100%')
    .backgroundColor(this.tabCanvas())
    .expandSafeArea([], []);
  }

  // 子页面使用的色板（由路由参数指定）。
  private choicePalette(routeParam: object): PagePaletteName {
    if (routeParam === null || routeParam === undefined) return 'NOTE';
    return (routeParam as PagePaletteRoute).palette === 'PERSONAL' ? 'PERSONAL' : 'NOTE';
  }

  // 子页面画布颜色。
  private choiceCanvas(routeParam: object): Resource {
    return this.choicePalette(routeParam) === 'PERSONAL' ? $r('app.color.personal_canvas') : $r('app.color.random_canvas');
  }

  // 当前首页页签的色板（跟随视觉页签）。
  private homePalette(): PagePaletteName {
    return this.homePaletteFor(this.visualTab);
  }

  // 某个页签的色板。
  private homePaletteFor(tab: number): PagePaletteName {
    if (tab === 1) return 'RANKING';
    if (tab === 2 && this.loggedIn) return 'SOCIAL';
    if (tab === 4) return 'PERSONAL';
    return 'NOTE';
  }

  // 页签栏背景色。
  private tabCanvas(): Resource {
    if (this.visualTab === 0) return $r('app.color.discovery_canvas');
    if (this.visualTab === 1) return $r('app.color.food_ranking_canvas');
    return pageColor(this.homePalette(), 'canvas');
  }

  // 页签栏选中色。
  private tabAction(): Resource {
    if (this.visualTab === 0) return $r('app.color.discovery_accent');
    if (this.visualTab === 1) return $r('app.color.food_ranking_accent');
    return pageColor(this.homePalette(), 'action');
  }

  // 选中指示点颜色。
  private tabHighlightDot(): Resource {
    if (this.visualTab === 0) return $r('app.color.discovery_gold');
    if (this.visualTab === 1) return $r('app.color.food_ranking_action');
    return pageColor(this.homePalette(), 'gold');
  }

  // 选中高亮色。
  private tabHighlight(): Resource {
    if (this.visualTab === 0) return $r('app.color.discovery_soft');
    if (this.visualTab === 1) return $r('app.color.food_ranking_tab_track');
    return pageColor(this.homePalette(), 'soft');
  }

  // 首页顶部颜色（跟随视觉页签）。
  private homeHeader(): Resource {
    return this.homeHeaderFor(this.visualTab);
  }

  // 某个页签的顶部颜色。
  private homeHeaderFor(tab: number): Resource {
    if (tab === 0) return $r('app.color.discovery_header');
    if (tab === 1) return $r('app.color.food_ranking_header');
    if (tab === 4 && !this.loggedIn) return $r('app.color.personal_canvas');
    return pageColor(this.homePaletteFor(tab), 'header');
  }

  // 「今日吃什么」桌面卡片：在前台刷新本地候选（没有卡片或候选仍有效时立即返回；换号时立即清空）。
  // 前台刷新「今日吃什么」桌面卡片的候选。
  private syncRandomFoodWidget(): void {
    if (!this.ready || !this.privacyAccepted) return;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    void RandomFoodWidgetStore.sync(context).catch((): void => {});
  }

  // 页面外观变化时同步窗口颜色。
  private onEntryAppearanceChanged(): void {
    const widgetScope: string = `${this.ready}|${this.privacyAccepted}|${this.loggedIn}`;
    if (widgetScope !== this.widgetScope) { this.widgetScope = widgetScope; this.syncRandomFoodWidget(); }
    AppPageSurface.setEntrySurfaceVisible(!this.ready || !this.privacyAccepted || this.loginRequested);
    if (!this.navigationHomeVisible) return;
    if (!this.ready || !this.privacyAccepted || this.loginRequested) {
      AppPageSurface.show($r('app.color.canvas'), $r('app.color.canvas'));
      return;
    }
    AppPageSurface.show(this.tabCanvas(), this.homeHeader(), this.homePalette(), this.profileCoverOnTop());
  }

  // “我的”页签把背景图延伸到状态栏下，其他页面保持纯色条。
  // “我的”页背景是否需要延伸到状态栏下。
  private profileCoverOnTop(): boolean {
    return this.ready && this.privacyAccepted && !this.loginRequested && this.loggedIn &&
      this.navigationHomeVisible && this.visualTab === 4 && this.profileCoverUrl.length > 0;
  }

  // 隐私确认、启动加载与登录界面不属于 Navigation 页面，由 Index 预留状态栏高度并在这里着色；首页和子页面自己绘制状态栏区域。
  private entrySurfaceActive(): boolean {
    return !this.ready || !this.privacyAccepted || this.loginRequested;
  }

  // 状态栏高度（vp）。
  private systemTopVp(): number {
    return this.getUIContext().px2vp(this.systemTopPx);
  }

  // 入口界面的状态栏颜色条。
  @Builder
  private topEdge(): void {
    if (this.entrySurfaceActive()) {
      Column().width('100%').height(this.systemTopVp()).backgroundColor($r('app.color.canvas'))
        .position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
    }
  }


  // 窗口底色（只在页面未覆盖的位置可见）。
  private edgeCanvas(): Resource {
    const revision: number = this.pageSurfaceRevision;
    if (!this.ready || !this.privacyAccepted || this.loginRequested) return $r('app.color.canvas');
    if (!this.navigationHomeVisible && revision >= 0) return AppPageSurface.header;
    return this.homeHeader();
  }

  // 整体画布颜色。
  private frameCanvas(): Resource {
    const revision: number = this.pageSurfaceRevision;
    if (!this.ready || !this.privacyAccepted || this.loginRequested) return $r('app.color.canvas');
    return !this.navigationHomeVisible && revision >= 0 ? AppPageSurface.canvas : this.tabCanvas();
  }

  // 需要避让的底部边缘。
  private bottomEdge(): Edges {
    const edges: Edges = { left: 0, bottom: 0 };
    return edges;
  }

  // 系统栏样式。首页的状态栏文字颜色跟随视觉页签立即切换（“我的”主页背景延伸到状态栏下时用白色），不等窗口接口在动画结束后生效。
  private nativeSystemBarStyle(): SystemBarStyle {
    const homeInk: string = this.profileCoverOnTop() ? '#FFFFFFFF' : AppPageSurface.systemBarInk;
    const style: SystemBarStyle = { statusBarContentColor: this.navigationHomeVisible ? homeInk : this.systemBarInk };
    return style;
  }

  // Index 仍需预留的底部安全区：手势区高度减去首页页签栏允许下沉的部分。
  // Index 实际预留的底部安全区高度。
  private reservedBottom(): number {
    const bottom: number = this.getUIContext().px2vp(this.systemBottomPx);
    AppPageSurface.bottomOverlap = Math.min(HOME_BAR_OVERLAP, bottom);
    return this.keyboardVisible ? 0 : bottom - AppPageSurface.bottomOverlap;
  }

  // 内容区内边距（系统安全区）。
  private contentInsets(): Padding {
    const insets: Padding = {
      // 进入 Navigation 后由首页页签与子页面各自绘制状态栏区域，这里不再预留。
      top: this.ready && this.privacyAccepted ? 0 : this.systemTopVp(),
      bottom: this.reservedBottom(),
      left: this.getUIContext().px2vp(this.systemLeftPx),
      right: this.getUIContext().px2vp(this.systemRightPx)
    };
    return insets;
  }

  // 主内容：隐私页 / 登录 / 页签 / 子页面栈。
  @Builder
  private entryContent(): void {
    if (!this.ready) {
      Column({ space: 12 }) {
        LoadingProgress().width(42).height(42).color($r('app.color.accent_action'))
        Text('正在准备食刻…').fontSize(13).fontColor($r('app.color.muted'))
      }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.canvas'))
    } else if (!this.privacyAccepted) {
      this.privacyPage()
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Navigation(this.pathStack) { this.mainTabs() }
          .hideTitleBar(true).navDestination(this.pathMap).mode(NavigationMode.Stack)
          .backgroundColor(Color.Transparent).background(this.edgeCanvas()).clip(true)
          .ignoreLayoutSafeArea([], []).expandSafeArea([], [])
          .systemBarStyle(this.nativeSystemBarStyle())
          .onNavBarStateChange((visible: boolean): void => { this.navigationHomeVisible = visible; if (visible) this.onEntryAppearanceChanged(); AppStorage.setOrCreate('discoveryVisible', visible && this.selectedTab === 0); })
          .width('100%').height('100%')
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            const width: number = Number(newArea.width);
            if (Number.isFinite(width) && width > 0) {
              const breakpoint: LayoutBreakpoint = BreakpointSystem.fromWidth(width);
              if (this.windowBreakpoint !== breakpoint) this.windowBreakpoint = breakpoint;
            }
          })
        if (this.loginRequested && !this.loggedIn) {
          Column() { this.loginPage() }.width('100%').height('100%').padding({ top: this.systemTopVp() })
        }
      }.width('100%').height('100%')
    }
  }

  // 页面布局。
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 统一预留左右与底部安全区（入口界面另预留顶部）；只有背景铺满整个窗口。
      Column() {
        this.entryContent();
      }.width('100%').height('100%').padding(this.contentInsets())
        .expandSafeArea([], []).clip(true);
      // 入口界面的状态栏颜色条。
      this.topEdge();
      // 底部手势区颜色条（align() 只对容器自己的子组件生效，所以用 position 固定到底部边缘）。
      Column() {}.width('100%').height(this.reservedBottom())
        .backgroundColor(this.frameCanvas()).position(this.bottomEdge())
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
    }.width('100%').height('100%').backgroundColor(this.edgeCanvas()).background(this.edgeCanvas())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
