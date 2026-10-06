import { common } from '@kit.AbilityKit';
import { FoodCard, UserProfile } from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';
import { PrivacyStore } from '../service/PrivacyStore';
import { NearbyPreloadService } from '../service/NearbyPreloadService';
import { FriendRankingPreloadService } from '../service/FriendRankingPreloadService';
import { PhotoUploadService } from '../service/PhotoUploadService';
import { CardRepository } from '../repository/CardRepository';
import { clearPendingSharedCard } from '../service/CardAppLink';
import { FriendRepository } from '../repository/FriendRepository';
import { NotificationRepository } from '../repository/NotificationRepository';
import { OpenNotificationResponse } from '../model/NotificationModels';
import { FriendsResponse, GroupConversationSummary, SocialUser } from '../model/FriendModels';
import { ContinuationState } from '../service/ContinuationState';
import { PushNotificationService } from '../service/PushNotificationService';
import { ServiceCardStore } from '../service/ServiceCardStore';
import { ServiceCardRemoteSyncService } from '../service/ServiceCardRemoteSyncService';
import { NearbyPage } from './NearbyPage';
import { RankingPage } from './RankingPage';
import { CreateCardPage } from './CreateCardPage';
import { ProfilePage } from './ProfilePage';
import { FavoriteCardsPage } from './FavoriteCardsPage';
import { CardHistoryPage } from './CardHistoryPage';
import { NotificationInboxPage } from './NotificationInboxPage';
import { MyPublishedPage, PermissionsPrivacyPage, ProfileEditPage, ProfileSettingsPage } from './ProfileSubPages';
import { CardDetailPage } from './CardDetailPage';
import { FriendsPage } from './FriendsPage';
import { FriendProfilePage } from './FriendProfilePage';
import { FriendSearchPage } from './FriendSearchPage';
import { ChatPage } from './ChatPage';
import { GroupChatPage } from './GroupChatPage';
import { ShareCardPage } from './ShareCardPage';
import { BreakpointSystem, LayoutBreakpoint } from '../common/BreakpointSystem';

interface LoginErrorInfo {
  code?: number | string;
  message?: string;
  name?: string;
}

@Entry
@Component
struct Index {
  @Provide('pathStack') pathStack: NavPathStack = new NavPathStack();
  @Provide('windowBreakpoint') windowBreakpoint: LayoutBreakpoint = 'sm';
  @State ready: boolean = false;
  @State privacyAccepted: boolean = false;
  @State privacyChecked: boolean = false;
  @State showFullPrivacy: boolean = false;
  @State loggedIn: boolean = false;
  @State loginRequested: boolean = false;
  @State loginBusy: boolean = false;
  @State loginMessage: string = '';
  @State emailAddress: string = '';
  @State verifyCode: string = '';
  @State codeBusy: boolean = false;
  @State codeCountdown: number = 0;
  @State registerDialogVisible: boolean = false;
  @State registerBusy: boolean = false;
  @State registerCodeBusy: boolean = false;
  @State registerCodeCountdown: number = 0;
  @State registerEmailAddress: string = '';
  @State registerVerifyCode: string = '';
  @State registerMessage: string = '';
  @State selectedCard: FoodCard | undefined = undefined;
  @State selectedFriend: SocialUser | undefined = undefined;
  @State selectedProfileFriend: SocialUser | undefined = undefined;
  @State selectedGroup: GroupConversationSummary | undefined = undefined;
  @State profile: UserProfile | undefined = undefined;
  @State profileRevision: number = 0;
  @State recommendationRevision: number = 0;
  @StorageLink('contentMutationRevision') @Watch('onContentMutation') contentMutationRevision: number = 0;
  @StorageLink('friendRelationshipRevision') @Watch('onFriendRelationshipChanged') friendRelationshipRevision: number = 0;
  @State selectedTab: number = 0;
  @State sharedLinkMessage: string = '';
  @StorageLink('pendingSharedCardId') @Watch('onPendingSharedCardChanged') pendingSharedCardId: string = '';
  @StorageLink('pendingSystemEntryRoute') @Watch('onPendingSystemEntryChanged') pendingSystemEntryRoute: string = '';
  @StorageLink('pendingSystemEntryCardId') pendingSystemEntryCardId: string = '';
  @StorageLink('pendingSystemEntryFriendUid') pendingSystemEntryFriendUid: string = '';
  @StorageLink('pendingSystemEntryTab') pendingSystemEntryTab: number = 0;
  @StorageLink('pendingSystemEntryNotificationId') pendingSystemEntryNotificationId: string = '';
  private openingSharedCard: boolean = false;
  private sharedCardGeneration: number = 0;
  private openingSystemEntry: boolean = false;
  private emailCodeTimer: number | undefined = undefined;
  private registerCodeTimer: number | undefined = undefined;
  private cardRepository: CardRepository = new CardRepository();
  private friendRepository: FriendRepository = new FriendRepository();
  private notificationRepository: NotificationRepository = new NotificationRepository();
  private tabsController: TabsController = new TabsController();

  aboutToAppear(): void {
    ContinuationState.showTab(this.selectedTab);
    this.restoreStartupState();
  }

  aboutToDisappear(): void {
    if (this.emailCodeTimer !== undefined) {
      clearTimeout(this.emailCodeTimer);
      this.emailCodeTimer = undefined;
    }
    if (this.registerCodeTimer !== undefined) {
      clearTimeout(this.registerCodeTimer);
      this.registerCodeTimer = undefined;
    }
  }

  onBackPress(): boolean {
    if (!this.loginRequested) return false;
    if (this.registerDialogVisible) {
      this.closeRegisterDialog();
    } else {
      this.continueBrowsing();
    }
    return true;
  }

  private requestLogin(message: string = '登录后可发布、收藏、评论和使用好友功能。'): void {
    if (this.loggedIn) return;
    this.loginMessage = message;
    this.loginRequested = true;
  }

  private continueBrowsing(): void {
    if (this.loginBusy || this.codeBusy || this.registerBusy || this.registerCodeBusy) return;
    this.registerDialogVisible = false;
    this.loginRequested = false;
    this.loginMessage = '';
  }

  private warmNearby(context: common.UIAbilityContext): void {
    void NearbyPreloadService.warmIfEligible(context);
  }

  private async restoreStartupState(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.privacyAccepted = await PrivacyStore.hasConsent(context);
      this.privacyChecked = this.privacyAccepted;
      if (this.privacyAccepted) {
        this.profile = await AuthService.restore(context, false);
        this.loggedIn = this.profile !== undefined;
        if (this.profile !== undefined) {
          PhotoUploadService.setCacheOwner(this.profile.uid);
          this.warmNearby(context);
          FriendRankingPreloadService.warm(context, this.profile.uid, this.friendRelationshipRevision);
          void this.syncPushIfEnabled(context, this.profile.uid);
        }
      }
    } finally {
      this.ready = true;
      this.openPendingSharedCard();
      this.openPendingSystemEntry();
    }
  }

  private async syncPushIfEnabled(context: common.UIAbilityContext, profileId: string): Promise<void> {
    try {
      await PushNotificationService.syncIfEnabled(context, profileId);
    } catch (_error) {
      // Login and startup must remain usable if Push Kit or the push service is
      // temporarily unavailable. The permissions page exposes the retry path.
    }
    try {
      await ServiceCardRemoteSyncService.syncIfEnabled(context);
    } catch (_error) {
      // Remote card registration never blocks account restoration. Its
      // separate consent card retains a retry action and status explanation.
    }
  }

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

  private async rejectPrivacy(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await context.terminateSelf();
  }

  private async login(): Promise<void> {
    if (this.loginBusy) return;
    this.loginBusy = true;
    this.loginMessage = '正在请求华为账号授权…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const profile: UserProfile = await AuthService.login(context, true);
      await this.finishLogin(context, profile);
    } catch (error) {
      const detail: string = this.errorDetail(error as Object);
      this.loginMessage = `登录未完成：${detail}`;
      // Do not write third-party authentication error details to logs; an SDK
      // error may contain identifiers or credential-related context.
      console.error('Huawei compatibility authentication failed.');
    } finally {
      this.loginBusy = false;
    }
  }

  private async finishLogin(context: common.UIAbilityContext, profile: UserProfile): Promise<void> {
    this.profile = profile;
    this.loggedIn = true;
    this.loginRequested = false;
    PhotoUploadService.setCacheOwner(profile.uid);
    NearbyPreloadService.clear();
    this.recommendationRevision += 1;
    FriendRankingPreloadService.warm(context, profile.uid, this.friendRelationshipRevision);
    // Push and service-card registration are opt-in enhancements. They must
    // never delay the post-authentication transition to the home page.
    void this.syncPushIfEnabled(context, profile.uid);
    this.openPendingSharedCard();
    this.openPendingSystemEntry();
  }

  private errorDetail(error: Object): string {
    // BusinessError is an object; interpolating it directly only displays
    // "[object Object]" and hides the Account Kit/AGC error details.
    const loginError = error as LoginErrorInfo;
    let detail: string = '';
    if (loginError?.code !== undefined) {
      detail = `错误码：${loginError.code}`;
    }
    if (loginError?.message) {
      detail += `${detail ? '，' : ''}${loginError.message}`;
    }
    if (!detail) {
      try {
        detail = JSON.stringify(error);
      } catch (_) {
        detail = String(error);
      }
    }
    return detail || '认证服务暂时不可用。';
  }

  private startEmailCodeCountdown(): void {
    if (this.emailCodeTimer !== undefined) {
      clearTimeout(this.emailCodeTimer);
    }
    this.emailCodeTimer = setTimeout((): void => {
      if (this.codeCountdown <= 1) {
        this.codeCountdown = 0;
        this.emailCodeTimer = undefined;
      } else {
        this.codeCountdown -= 1;
        this.startEmailCodeCountdown();
      }
    }, 1000);
  }

  private async requestEmailCode(): Promise<void> {
    if (this.loginBusy || this.codeBusy || this.codeCountdown > 0) return;
    this.codeBusy = true;
    this.loginMessage = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.requestEmailCode(context, this.emailAddress);
      this.codeCountdown = 60;
      this.startEmailCodeCountdown();
      this.loginMessage = '邮箱验证码已发送，请在有效期内完成认证。';
    } catch (error) {
      this.loginMessage = `验证码发送失败：${this.errorDetail(error as Object)}`;
    } finally {
      this.codeBusy = false;
    }
  }

  private async emailLogin(): Promise<void> {
    if (this.loginBusy) return;
    this.loginBusy = true;
    this.loginMessage = '正在验证邮箱并打开食刻…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const profile: UserProfile = await AuthService.emailLogin(
        context, this.emailAddress, this.verifyCode, false);
      await this.finishLogin(context, profile);
    } catch (error) {
      this.loginMessage = `邮箱登录未完成：${this.errorDetail(error as Object)}`;
    } finally {
      this.loginBusy = false;
    }
  }

  private openRegisterDialog(): void {
    if (this.loginBusy || this.codeBusy) return;
    this.registerEmailAddress = '';
    this.registerVerifyCode = '';
    this.registerMessage = '';
    this.registerDialogVisible = true;
  }

  private closeRegisterDialog(): void {
    if (this.registerBusy || this.registerCodeBusy) return;
    this.registerDialogVisible = false;
  }

  private startRegisterCodeCountdown(): void {
    if (this.registerCodeTimer !== undefined) clearTimeout(this.registerCodeTimer);
    this.registerCodeTimer = setTimeout((): void => {
      if (this.registerCodeCountdown <= 1) {
        this.registerCodeCountdown = 0;
        this.registerCodeTimer = undefined;
      } else {
        this.registerCodeCountdown -= 1;
        this.startRegisterCodeCountdown();
      }
    }, 1000);
  }

  private async requestRegisterCode(): Promise<void> {
    if (this.registerBusy || this.registerCodeBusy || this.registerCodeCountdown > 0) return;
    this.registerCodeBusy = true;
    this.registerMessage = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await AuthService.requestEmailCode(context, this.registerEmailAddress);
      this.registerCodeCountdown = 60;
      this.startRegisterCodeCountdown();
      this.registerMessage = '验证码已发送，请在有效期内完成注册。';
    } catch (error) {
      this.registerMessage = `验证码发送失败：${this.errorDetail(error as Object)}`;
    } finally {
      this.registerCodeBusy = false;
    }
  }

  private async registerEmail(): Promise<void> {
    if (this.registerBusy) return;
    this.registerBusy = true;
    this.registerMessage = '正在创建账号并打开食刻…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const profile: UserProfile = await AuthService.emailLogin(
        context, this.registerEmailAddress, this.registerVerifyCode, true);
      this.registerDialogVisible = false;
      await this.finishLogin(context, profile);
    } catch (error) {
      this.registerMessage = `注册未完成：${this.errorDetail(error as Object)}`;
    } finally {
      this.registerBusy = false;
    }
  }

  private sessionEnded(message: string): void {
    this.sharedCardGeneration += 1;
    clearPendingSharedCard();
    this.sharedLinkMessage = '';
    this.pathStack.clear();
    NearbyPreloadService.clear();
    FriendRankingPreloadService.invalidate();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    PhotoUploadService.clearCachedMedia(context);
    this.loggedIn = false;
    this.loginRequested = false;
    this.profile = undefined;
    this.emailAddress = '';
    this.verifyCode = '';
    this.loginMessage = message;
    this.selectedTab = 0;
    this.recommendationRevision += 1;
    ContinuationState.clearPending();
    ContinuationState.showTab(0);
  }

  private openCard(card: FoodCard): void {
    this.selectedCard = card;
    ContinuationState.showCard(card.id);
    this.updateServiceCard(card);
    this.pathStack.pushPathByName('card-detail', null);
  }

  private async updateServiceCard(card: FoodCard): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ServiceCardStore.publishRecommendation(context, card);
    } catch (_error) {
      // Desktop-card refresh is an enhancement and cannot block navigation.
    }
  }

  private onPendingSharedCardChanged(): void {
    this.openPendingSharedCard();
  }

  private onPendingSystemEntryChanged(): void {
    this.openPendingSystemEntry();
  }

  private async openPendingSystemEntry(): Promise<void> {
    const route: string = this.pendingSystemEntryRoute.trim();
    if (this.openingSystemEntry || route.length === 0 || !this.ready
      || !this.privacyAccepted) return;
    if (!this.loggedIn && route !== 'card' && (route !== 'tab' || this.pendingSystemEntryTab !== 0)) {
      this.requestLogin('登录后可打开这条通知或好友页面。');
      return;
    }
    this.openingSystemEntry = true;
    try {
      if (route === 'notification') {
        const notificationId: string = this.pendingSystemEntryNotificationId.trim();
        ContinuationState.clearPending();
        if (notificationId.length > 0) await this.followNotification(notificationId);
        return;
      }
      if (route === 'tab') {
        const tab: number = this.pendingSystemEntryTab >= 0 && this.pendingSystemEntryTab <= 4
          ? this.pendingSystemEntryTab : 0;
        ContinuationState.clearPending();
        this.selectTab(tab);
        return;
      }
      if (route === 'card') {
        const cardId: string = this.pendingSystemEntryCardId.trim();
        ContinuationState.clearPending();
        if (cardId.length > 0) {
          AppStorage.setOrCreate('pendingSharedCardId', cardId);
          this.openPendingSharedCard();
        }
        return;
      }
      if (route === 'friend-chat') {
        const friendUid: string = this.pendingSystemEntryFriendUid.trim();
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const response: FriendsResponse = await this.friendRepository.listFriends(context);
        const friend: SocialUser | undefined = response.friends.find(
          (item: SocialUser): boolean => item.uid === friendUid);
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
      ContinuationState.clearPending();
      const detail = error as LoginErrorInfo;
      this.sharedLinkMessage = detail.message && detail.message.length > 0
        ? `系统入口打开失败：${detail.message}` : '系统入口暂时无法打开，请稍后重试。';
    } finally {
      this.openingSystemEntry = false;
    }
  }

  private async followNotification(notificationId: string): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const result: OpenNotificationResponse = await this.notificationRepository.open(context, notificationId);
    AppStorage.setOrCreate('notificationForegroundRevision',
      (AppStorage.get<number>('notificationForegroundRevision') || 0) + 1);
    if (result.route === 'friends') {
      AppStorage.setOrCreate('requestedFriendSection', 1);
      this.selectTab(2);
      return;
    }
    if (result.route === 'friend-chat') {
      const response = await this.friendRepository.friendProfile(context, result.targetId, '', 1);
      this.openChat(response.profile.user);
      return;
    }
    if (result.route === 'group-chat') {
      const response = await this.friendRepository.groupDetail(context, result.targetId);
      this.openGroupChat(response.group);
      return;
    }
    if (result.route === 'card') {
      const card: FoodCard = await this.cardRepository.detail(context, result.targetId);
      this.openCard(card);
      return;
    }
    this.sharedLinkMessage = '这条通知对应的内容已失效或不可查看。';
    this.selectTab(2);
  }

  /**
   * App Linking may wake the app before its consent gate and login restoration
   * complete. Hold the opaque card ID in AppStorage, then load the same
   * public detail surface used by every in-app card tap.
   */
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
        clearPendingSharedCard();
        const detail = error as LoginErrorInfo;
        this.sharedLinkMessage = detail.message && detail.message.length > 0
          ? `无法打开分享的商品卡：${detail.message}` : '无法打开分享的商品卡，它可能已删除或不再公开。';
      }
    } finally {
      this.openingSharedCard = false;
      // A newer link can arrive while the previous detail request is pending.
      // Its @Watch callback was blocked by openingSharedCard; resume it now.
      if (this.pendingSharedCardId.length > 0
        && (this.pendingSharedCardId !== cardId || generation !== this.sharedCardGeneration)) {
        void this.openPendingSharedCard();
      }
    }
  }

  private openChat(friend: SocialUser): void {
    this.selectedFriend = friend;
    ContinuationState.showFriend(friend.uid);
    this.pathStack.pushPathByName('friend-chat', null);
  }

  private openFriendProfile(friend: SocialUser): void {
    this.selectedProfileFriend = friend;
    this.pathStack.pushPathByName('friend-profile', null);
  }

  private openAddFriend(): void {
    this.pathStack.pushPathByName('add-friend', null);
  }

  private friendRequestChanged(): void {
    AppStorage.setOrCreate('socialForegroundRevision',
      (AppStorage.get<number>('socialForegroundRevision') || 0) + 1);
  }

  private openGroupChat(group: GroupConversationSummary): void {
    this.selectedGroup = group;
    this.pathStack.pushPathByName('group-chat', null);
  }

  private shareCardToFriend(card: FoodCard): void {
    if (!this.loggedIn) {
      this.requestLogin('登录后可将卡片分享给食刻好友。');
      return;
    }
    this.selectedCard = card;
    ContinuationState.showCard(card.id);
    this.pathStack.pushPathByName('share-card', null);
  }

  private openChatAfterShare(friend: SocialUser): void {
    this.selectedFriend = friend;
    ContinuationState.showFriend(friend.uid);
    this.pathStack.replacePathByName('friend-chat', friend);
  }

  private profileCardsChanged(): void {
    this.profileRevision += 1;
  }

  private profileUpdated(profile: UserProfile): void {
    this.profile = profile;
    this.profileRevision += 1;
  }

  private cardPublished(): void {
    NearbyPreloadService.invalidate();
    FriendRankingPreloadService.invalidate();
    this.recommendationRevision += 1;
    this.profileRevision += 1;
  }

  private onContentMutation(): void {
    NearbyPreloadService.invalidate(); FriendRankingPreloadService.invalidate();
    this.recommendationRevision += 1; this.profileRevision += 1;
  }

  private onFriendRelationshipChanged(): void {
    FriendRankingPreloadService.invalidate();
    if (this.loggedIn && this.profile !== undefined) {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      FriendRankingPreloadService.warm(context, this.profile.uid, this.friendRelationshipRevision);
    }
  }

  private tabPosition(index: number): number {
    return this.loggedIn ? index : index === 4 ? 1 : 0;
  }

  private onTabPositionChanged(position: number): void {
    this.selectTab(this.loggedIn ? position : position === 1 ? 4 : 0);
  }

  private selectTab(index: number): void {
    const safeIndex: number = this.loggedIn
      ? (index >= 0 && index <= 4 ? index : 0) : (index === 4 ? 4 : 0);
    this.selectedTab = safeIndex;
    ContinuationState.showTab(safeIndex);
    if (safeIndex === 2) {
      AppStorage.setOrCreate('socialForegroundRevision',
        (AppStorage.get<number>('socialForegroundRevision') || 0) + 1);
    }
  }

  @Builder
  pathMap(routeName: string) {
    if (routeName === 'card-detail' && this.selectedCard !== undefined) {
      CardDetailPage({
        card: this.selectedCard,
        loggedIn: this.loggedIn,
        onRequireLogin: (message: string): void => this.requestLogin(message),
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
    } else if (routeName === 'friend-profile' && this.selectedProfileFriend !== undefined) {
      FriendProfilePage({
        friendUid: this.selectedProfileFriend.uid,
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
    } else if (routeName === 'profile-history') {
      CardHistoryPage({ onOpenCard: (card: FoodCard): void => this.openCard(card) })
    } else if (routeName === 'notification-inbox') {
      NotificationInboxPage({ onOpenNotification: async (notificationId: string): Promise<void> => {
        await this.followNotification(notificationId);
      } })
    } else if (routeName === 'profile-privacy') {
      PermissionsPrivacyPage()
    } else if (routeName === 'profile-edit') {
      ProfileEditPage({ onProfileChanged: (profile: UserProfile): void => this.profileUpdated(profile) })
    } else if (routeName === 'profile-settings') {
      ProfileSettingsPage({ onSessionEnded: (message: string): void => this.sessionEnded(message) })
    }
  }

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

          this.privacyNoticeRow('账号认证', '无需登录即可浏览公开推荐；发布和互动时支持 AGC Auth 邮箱验证码注册/登录，并保留华为账号兼容入口。邮箱仅用于认证，不写入食刻资料。')
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
            Text('食刻使用 AGC Auth 处理邮箱验证码注册/登录；邮箱只用于认证，不写入 UserProfile、名片、好友或私信，也不会收集或保存邮箱密码。华为账号只作为兼容入口，登录后会换成 AGC 会话。昵称和头像只会在你主动保存资料时处理，头像先在本机重编码并移除 EXIF/GPS。首页推荐不限距离，浏览时不读取定位。你主动发布时，实拍图、公开商品字段、约 100 米精度的位置以及后续主动提交的评论和互动记录会进入 AGC 云端。好友功能会保存食刻号、好友申请、好友关系、一对一和群聊会话的未读数，以及你主动发送的文字和卡片标识；粘贴的链接会作为普通文字消息保存。站内通知会记录好友、消息、评论与回复的事件类型及已读状态，不保存正文；系统 Push 默认关闭，你主动开启后，设备 Push Token 会在食刻云端加密保存，系统通知正文不包含私信或评论内容。桌面服务卡片只在本机缓存一条公开推荐摘要；跨设备接续只传页签、商品卡 ID 或好友 ID，不传聊天正文和账号凭据。移除好友时会话从双方页面移除，并同步清理全部一对一私信。正式上架前必须根据平台要求补充内容审核方案，并在 AGC 配置同内容的 HTTPS 隐私政策地址。')
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

        Text('当前为云端测试版：发布、评论、互动、好友申请和私信仅在你主动操作时写入；通知也只有在“权限与隐私”中主动开启后才会登记。')
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
  }

  @Builder
  private loginPage() {
    Scroll() {
      Column() {
        Blank().height(18)
        Image($r('app.media.app_icon')).width(82).height(82).borderRadius(24)
          .accessibilityLevel('no')
        Text('欢迎来到食刻').fontSize(28).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink')).margin({ top: 20 })
        Text('真实画面，认真推荐').fontSize(15)
          .fontColor($r('app.color.muted')).margin({ top: 8 })

        Text('邮箱登录').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
          .margin({ top: 30 }).width('88%')
        Text('邮箱地址').fontSize(13).fontColor($r('app.color.muted')).width('88%')
          .margin({ top: 18 })
        TextInput({ text: this.emailAddress, placeholder: 'name@example.com' })
          .width('88%').height(48).margin({ top: 6 })
          .accessibilityText('邮箱地址')
          .onChange((value: string): void => {
            this.emailAddress = value;
          })
        Text('邮箱验证码').fontSize(13).fontColor($r('app.color.muted')).width('88%')
          .margin({ top: 14 })
        Row({ space: 10 }) {
          TextInput({ text: this.verifyCode, placeholder: '输入邮箱验证码' })
            .layoutWeight(1).height(48)
            .accessibilityText('邮箱验证码')
            .onChange((value: string): void => {
              this.verifyCode = value;
            })
          Button(this.codeCountdown > 0 ? `${this.codeCountdown} 秒后重发` :
            (this.codeBusy ? '发送中…' : '获取验证码'))
            .enabled(!this.loginBusy && !this.codeBusy && this.codeCountdown === 0)
            .height(48).fontSize(13)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
            .border({ width: 1, color: $r('app.color.line') })
            .accessibilityText('获取邮箱验证码')
            .onClick(() => this.requestEmailCode())
        }.width('88%').margin({ top: 10 })
        Text('验证码由 AGC Auth 发送；食刻不会保存邮箱密码。')
          .fontSize(12).lineHeight(18).fontColor($r('app.color.muted')).width('88%').margin({ top: 8 })

        if (this.loginMessage.length > 0) {
          Row({ space: 8 }) {
            if (this.loginBusy) {
              LoadingProgress().width(18).height(18).color($r('app.color.accent_action'))
            }
            Text(this.loginMessage).fontSize(13).lineHeight(20).layoutWeight(1)
              .fontColor(this.loginMessage.includes('未完成')
                ? $r('app.color.warning') : $r('app.color.muted'))
          }
          .width('88%').padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
          .margin({ top: 12 }).alignItems(VerticalAlign.Top)
        }

        Button(this.loginBusy ? '正在登录…' : '登录')
          .enabled(!this.loginBusy).width('88%').height(52)
          .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
          .margin({ top: 14 }).accessibilityText('使用邮箱验证码登录').onClick(() => this.emailLogin())

        Divider().width('78%').margin({ top: 24, bottom: 18 }).color($r('app.color.line'))
        Button(this.loginBusy ? '正在连接华为账号…' : '使用华为账号登录')
          .enabled(!this.loginBusy).width('88%').height(50)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
          .border({ width: 1, color: $r('app.color.line') })
          .accessibilityText('使用华为账号登录').onClick(() => this.login())
        Text('邮箱与华为账号关联后，可登录同一个食刻账号。')
          .fontSize(12).lineHeight(18).fontColor($r('app.color.muted'))
          .textAlign(TextAlign.Center).width('82%').margin({ top: 10 })

        Row({ space: 4 }) {
          Text('还没有食刻账号？').fontSize(13).fontColor($r('app.color.muted'))
          Button('注册新账号').height(48).fontSize(13)
            .enabled(!this.loginBusy && !this.codeBusy)
            .backgroundColor($r('app.color.canvas')).fontColor($r('app.color.accent_action'))
            .accessibilityText('注册新的食刻账号').onClick(() => this.openRegisterDialog())
        }.margin({ top: 16 }).justifyContent(FlexAlign.Center)

        Button('继续游客浏览').width('88%').height(48).margin({ top: 8 })
          .enabled(!this.loginBusy && !this.codeBusy && !this.registerBusy && !this.registerCodeBusy)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
          .accessibilityText('关闭登录，继续浏览当前页面')
          .onClick((): void => this.continueBrowsing())

        Blank().height(18)
        Text('继续即表示你已同意启动页中的《隐私说明》')
          .fontSize(12).lineHeight(18).fontColor($r('app.color.muted'))
          .textAlign(TextAlign.Center).width('82%').margin({ bottom: 28 })
      }
      .width('100%').padding({ top: 38, bottom: 28 }).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').scrollBar(BarState.Off)
    .backgroundColor($r('app.color.canvas'))
  }

  @Builder
  private registerDialog() {
    Column({ space: 12 }) {
      Text('注册食刻账号').fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
      Text('使用邮箱验证码创建账号，不需要设置密码。').fontSize(13).lineHeight(20)
        .fontColor($r('app.color.muted')).width('100%')
      Text('邮箱地址').fontSize(13).fontColor($r('app.color.muted')).width('100%').margin({ top: 8 })
      TextInput({ text: this.registerEmailAddress, placeholder: 'name@example.com' })
        .width('100%').height(48).accessibilityText('注册邮箱地址')
        .onChange((value: string): void => {
          this.registerEmailAddress = value;
        })
      Text('邮箱验证码').fontSize(13).fontColor($r('app.color.muted')).width('100%').margin({ top: 4 })
      Row({ space: 10 }) {
        TextInput({ text: this.registerVerifyCode, placeholder: '输入邮箱验证码' })
          .layoutWeight(1).height(48).accessibilityText('注册邮箱验证码')
          .onChange((value: string): void => {
            this.registerVerifyCode = value;
          })
        Button(this.registerCodeCountdown > 0 ? `${this.registerCodeCountdown} 秒后重发` :
          (this.registerCodeBusy ? '发送中…' : '获取验证码'))
          .enabled(!this.registerBusy && !this.registerCodeBusy && this.registerCodeCountdown === 0)
          .height(48).fontSize(13).backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.accent_action')).border({ width: 1, color: $r('app.color.line') })
          .accessibilityText('获取注册邮箱验证码').onClick(() => this.requestRegisterCode())
      }.width('100%')
      if (this.registerMessage.length > 0) {
        Row({ space: 8 }) {
          if (this.registerBusy) {
            LoadingProgress().width(18).height(18).color($r('app.color.accent_action'))
          }
          Text(this.registerMessage).fontSize(13).lineHeight(20).layoutWeight(1)
            .fontColor(this.registerMessage.includes('失败') || this.registerMessage.includes('未完成')
              ? $r('app.color.warning') : $r('app.color.muted'))
        }.width('100%').padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14)
          .alignItems(VerticalAlign.Top)
      }
      Button(this.registerBusy ? '正在注册…' : '注册并进入食刻')
        .enabled(!this.registerBusy).width('100%').height(52).margin({ top: 4 })
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .accessibilityText('使用邮箱验证码注册').onClick(() => this.registerEmail())
      Button('取消').enabled(!this.registerBusy && !this.registerCodeBusy).width('100%').height(48)
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.muted'))
        .border({ width: 1, color: $r('app.color.line') }).accessibilityText('关闭账号注册窗口')
        .onClick(() => this.closeRegisterDialog())
    }
    .width('86%').padding(22).backgroundColor($r('app.color.surface')).borderRadius(24)
    .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private navigationRailItem(index: number, label: string, icon: Resource): void {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        Image(icon).width(22).height(22).objectFit(ImageFit.Contain)
          .fillColor(this.selectedTab === index ? $r('app.color.accent_action') : $r('app.color.muted'))
          .accessibilityLevel('no');
        Text(label).fontSize(13)
          .fontWeight(this.selectedTab === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.selectedTab === index ? $r('app.color.accent_action') : $r('app.color.muted'));
      }.width('100%');
    }
    .width('100%').height(64).padding(6).borderRadius(16)
    .backgroundColor(this.selectedTab === index ? $r('app.color.accent_soft') : $r('app.color.surface'))
    .accessibilityText(label).accessibilitySelected(this.selectedTab === index)
    .onClick((): void => {
      if (this.selectedTab !== index) this.tabsController.changeIndex(this.tabPosition(index));
    });
  }

  @Builder
  private navigationRail(): void {
    Scroll() {
      Column({ space: 8 }) {
        Text('食刻').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent_action'))
          .margin({ bottom: 16 }).accessibilityLevel('no');
        this.navigationRailItem(0, '推荐', $r('app.media.nav_recommend'));
        if (this.loggedIn) {
          this.navigationRailItem(1, '榜单', $r('app.media.nav_ranking'));
          this.navigationRailItem(2, '好友', $r('app.media.nav_friends'));
          this.navigationRailItem(3, '制作', $r('app.media.nav_create'));
        }
        this.navigationRailItem(4, '我的', $r('app.media.nav_profile'));
      }.width('100%').padding({ left: 10, right: 10, top: 22, bottom: 22 });
    }
    .width(BreakpointSystem.NAV_RAIL_WIDTH).height('100%').scrollBar(BarState.Off)
    .align(Alignment.Top).backgroundColor($r('app.color.surface'))
    .border({ width: { right: 1 }, color: $r('app.color.line') });
  }

  @Builder
  private guestAccountPage(title: string, description: string) {
    Column({ space: 16 }) {
      Text(title).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
      Text(description).fontSize(14).lineHeight(22).fontColor($r('app.color.muted'))
        .textAlign(TextAlign.Center).width('86%')
      Button('登录 / 注册').height(48).width('80%')
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .onClick((): void => this.requestLogin(description))
      Button('继续看推荐').height(48).width('80%')
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
        .onClick((): void => {
          this.tabsController.changeIndex(0);
          this.selectTab(0);
        })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.canvas'))
  }

  @Builder
  private mainTabs() {
    Column({ space: 0 }) {
      if (this.sharedLinkMessage.length > 0) {
        Row({ space: 10 }) {
          Text(this.sharedLinkMessage).fontSize(12).lineHeight(18).fontColor($r('app.color.warning'))
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
          Button('关闭').height(44).fontSize(12).backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.warning')).border({ width: 1, color: $r('app.color.line') })
            .accessibilityText('关闭提示').onClick((): void => {
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
        // The same Tabs subtree survives breakpoint changes; only its bar is
        // hidden on lg. Drafts, list state and tab lifecycle stay with each page.
        Tabs({ barPosition: BarPosition.End, index: this.tabPosition(this.selectedTab), controller: this.tabsController }) {
          TabContent() {
            NearbyPage({
              onOpenCard: (card: FoodCard): void => this.openCard(card),
              loggedIn: this.loggedIn,
              revision: this.recommendationRevision
            })
          }.tabBar('推荐')
          if (this.loggedIn) {
            TabContent() {
              RankingPage({
                onOpenCard: (card: FoodCard): void => this.openCard(card),
                revision: this.recommendationRevision + this.friendRelationshipRevision
              })
            }.tabBar('榜单')
            TabContent() {
              FriendsPage({
                onOpenChat: (friend: SocialUser): void => this.openChat(friend),
                onOpenProfile: (friend: SocialUser): void => this.openFriendProfile(friend),
                onOpenGroup: (group: GroupConversationSummary): void => this.openGroupChat(group),
                onOpenAddFriend: (): void => this.openAddFriend(),
                onOpenNotifications: (): void => {
                  this.pathStack.pushPathByName('notification-inbox', null);
                }
              })
            }.tabBar('好友')
            TabContent() {
              CreateCardPage({ accountUid: this.profile === undefined ? '' : this.profile.uid, onPublished: (): void => this.cardPublished() })
            }.tabBar('制作')
          }
          TabContent() {
            if (this.loggedIn) {
              ProfilePage({ revision: this.profileRevision })
            } else {
              this.guestAccountPage('我的', '登录后管理资料、收藏和浏览记录。')
            }
          }.tabBar('我的')
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        }
        .onChange((position: number): void => this.onTabPositionChanged(position))
        .layoutWeight(1).height('100%').barHeight(this.windowBreakpoint === 'lg' ? 0 : 58)
        .scrollable(this.windowBreakpoint !== 'lg').backgroundColor($r('app.color.canvas'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
      }.width('100%').layoutWeight(1);
    }
    .width('100%').height('100%').backgroundColor($r('app.color.canvas'));
  }

  build() {
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
          .width('100%').height('100%')
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            const width: number = Number(newArea.width);
            if (Number.isFinite(width) && width > 0) {
              const breakpoint: LayoutBreakpoint = BreakpointSystem.fromWidth(width);
              if (this.windowBreakpoint !== breakpoint) this.windowBreakpoint = breakpoint;
            }
          })
        if (this.loginRequested && !this.loggedIn) {
          this.loginPage()
          if (this.registerDialogVisible) {
            Column() {}
              .width('100%').height('100%').backgroundColor($r('app.color.ink')).opacity(0.38)
            this.registerDialog()
          }
        }
      }.width('100%').height('100%')
    }
  }
}
