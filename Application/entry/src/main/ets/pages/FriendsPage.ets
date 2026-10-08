import { common } from '@kit.AbilityKit';
import {
  ConversationSummary, FriendRequestItem, GroupConversationSummary, SocialUser
} from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { NotificationRepository } from '../repository/NotificationRepository';
import { NotificationsResponse } from '../model/NotificationModels';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { ErrorDetail, errorText } from '../common/ErrorKit';

type FriendActionKind = 'REMOVE' | 'BLOCK';

function timeLabel(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '';
  const date = new Date(timestamp);
  const today = new Date();
  if (date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth()
    && date.getDate() === today.getDate()) {
    const minute = date.getMinutes();
    return `${date.getHours()}:${minute < 10 ? `0${minute}` : minute}`;
  }
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

@Component
export struct FriendsPage {
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenProfile: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenGroup: (group: GroupConversationSummary) => void = (_group: GroupConversationSummary): void => {};
  onOpenAddFriend: () => void = (): void => {};
  onOpenNotifications: () => void = (): void => {};
  @StorageLink('socialForegroundRevision') @Watch('onSocialForegroundChanged') socialForegroundRevision: number = 0;
  @StorageLink('requestedFriendSection') @Watch('onRequestedFriendSectionChanged') requestedFriendSection: number = 0;
  @StorageLink('notificationForegroundRevision') @Watch('onNotificationForegroundChanged') notificationForegroundRevision: number = 0;
  @State selectedSection: number = 0;
  @State friends: Array<SocialUser> = [];
  @State blockedUsers: Array<SocialUser> = [];
  @State incomingRequests: Array<FriendRequestItem> = [];
  @State outgoingRequests: Array<FriendRequestItem> = [];
  @State conversations: Array<ConversationSummary> = [];
  @State groupConversations: Array<GroupConversationSummary> = [];
  @State unreadCount: number = 0;
  @State groupUnreadCount: number = 0;
  @State notificationUnreadCount: number = 0;
  @State friendsNextPageToken: string = '';
  @State conversationsNextPageToken: string = '';
  @State groupsNextPageToken: string = '';
  @State friendsLoading: boolean = false;
  @State conversationsLoading: boolean = false;
  @State groupsLoading: boolean = false;
  @State actionUid: string = '';
  @State friendError: string = '';
  @State conversationError: string = '';
  @State groupError: string = '';
  @State status: string = '';
  @State pendingRemoveUser: SocialUser | undefined = undefined;
  @State pendingFriendAction: FriendActionKind = 'REMOVE';
  @State groupCreatorVisible: boolean = false;
  @State groupName: string = '';
  @State groupMemberUids: Array<string> = [];
  @State groupCreating: boolean = false;
  private repository: FriendRepository = new FriendRepository();
  private notificationRepository: NotificationRepository = new NotificationRepository();

  aboutToAppear(): void {
    if (this.requestedFriendSection === 1) {
      this.selectedSection = 1;
      this.requestedFriendSection = 0;
    }
    this.refreshAll();
  }

  private onRequestedFriendSectionChanged(): void {
    if (this.requestedFriendSection === 1) {
      this.selectedSection = 1;
      this.requestedFriendSection = 0;
    }
  }

  private onNotificationForegroundChanged(): void {
    if (this.notificationForegroundRevision > 0) void this.loadNotificationCount();
  }

  private onSocialForegroundChanged(): void {
    if (this.socialForegroundRevision > 0) this.refreshAll();
  }

  private appendUsers(existing: Array<SocialUser>, next: Array<SocialUser>): Array<SocialUser> {
    const output: Array<SocialUser> = existing.slice();
    for (const user of next) {
      if (!output.some((item: SocialUser): boolean => item.uid === user.uid)) output.push(user);
    }
    return output;
  }

  private appendRequests(existing: Array<FriendRequestItem>, next: Array<FriendRequestItem>): Array<FriendRequestItem> {
    const output: Array<FriendRequestItem> = existing.slice();
    for (const request of next) {
      if (!output.some((item: FriendRequestItem): boolean => item.id === request.id)) output.push(request);
    }
    return output;
  }

  private async loadFriends(reset: boolean): Promise<void> {
    if (this.friendsLoading || (!reset && this.friendsNextPageToken.length === 0)) return;
    this.friendsLoading = true;
    this.friendError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listFriends(context, reset ? '' : this.friendsNextPageToken);
      this.friends = reset ? response.friends : this.appendUsers(this.friends, response.friends);
      this.incomingRequests = reset ? response.incomingRequests
        : this.appendRequests(this.incomingRequests, response.incomingRequests);
      this.outgoingRequests = reset ? response.outgoingRequests
        : this.appendRequests(this.outgoingRequests, response.outgoingRequests);
      this.blockedUsers = reset ? response.blockedUsers : this.appendUsers(this.blockedUsers, response.blockedUsers);
      this.friendsNextPageToken = response.nextPageToken;
    } catch (error) {
      this.friendError = `好友与申请加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.friendsLoading = false;
    }
  }

  private async loadConversations(reset: boolean): Promise<void> {
    if (this.conversationsLoading || (!reset && this.conversationsNextPageToken.length === 0)) return;
    this.conversationsLoading = true;
    this.conversationError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listConversations(context, reset ? '' : this.conversationsNextPageToken);
      this.conversations = reset ? response.conversations : this.conversations.concat(response.conversations);
      this.unreadCount = response.unreadCount;
      this.conversationsNextPageToken = response.nextPageToken;
    } catch (error) {
      this.conversationError = `私信加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.conversationsLoading = false;
    }
  }

  private async loadGroups(reset: boolean): Promise<void> {
    if (this.groupsLoading || (!reset && this.groupsNextPageToken.length === 0)) return;
    this.groupsLoading = true;
    this.groupError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listGroupConversations(context, reset ? '' : this.groupsNextPageToken);
      this.groupConversations = reset ? response.groups : this.groupConversations.concat(response.groups);
      this.groupUnreadCount = response.unreadCount;
      this.groupsNextPageToken = response.nextPageToken;
    } catch (error) {
      this.groupError = `群聊加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.groupsLoading = false;
    }
  }

  private async loadNotificationCount(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response: NotificationsResponse = await this.notificationRepository.list(context, '', 1);
      this.notificationUnreadCount = response.unreadCount;
    } catch (_error) {
      // The inbox remains usable from the button even while the badge cannot refresh.
    }
  }

  private async refreshAll(): Promise<void> {
    await Promise.all([this.loadFriends(true), this.loadConversations(true), this.loadGroups(true),
      this.loadNotificationCount()]);
  }

  private notifyRelationshipChanged(): void {
    const revision: number = AppStorage.get<number>('friendRelationshipRevision') || 0;
    AppStorage.setOrCreate('friendRelationshipRevision', revision + 1);
  }

  private async respond(request: FriendRequestItem, accept: boolean): Promise<void> {
    if (this.actionUid.length > 0) return;
    this.actionUid = request.user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.respondRequest(context, request.id, accept, request.createdAt);
      this.status = accept ? `你和 ${request.user.nickname} 已成为好友。` : '已拒绝这条好友申请。';
      this.notifyRelationshipChanged();
      void this.loadFriends(true);
      void this.loadConversations(true);
    } catch (error) {
      this.status = `申请处理失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.actionUid = '';
    }
  }

  private async removePendingFriend(): Promise<void> {
    const user = this.pendingRemoveUser;
    if (user === undefined || this.actionUid.length > 0) return;
    this.actionUid = user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.removeFriend(context, user.uid, user.friendshipUpdatedAt);
      this.pendingRemoveUser = undefined;
      this.pendingFriendAction = 'REMOVE';
      this.status = `已移除 ${user.nickname}，会话已从应用中移除。`;
      this.notifyRelationshipChanged();
      void this.loadFriends(true);
      void this.loadConversations(true);
    } catch (error) {
      this.status = `移除失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.actionUid = '';
    }
  }

  private async blockPendingFriend(reportUser: boolean): Promise<void> {
    const user = this.pendingRemoveUser;
    if (user === undefined || this.actionUid.length > 0) return;
    this.actionUid = user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.blockUser(context, user.uid);
      this.pendingRemoveUser = undefined;
      this.pendingFriendAction = 'REMOVE';
      this.status = `已拉黑 ${user.nickname}，一对一会话已清理。`;
      if (reportUser) {
        try {
          await this.repository.reportUser(context, user.uid, '用户主动举报');
          this.status = `已举报并拉黑 ${user.nickname}，一对一会话已清理。`;
        } catch (reportError) {
          this.status = `已拉黑 ${user.nickname}，但举报未提交：${errorText(reportError as ErrorDetail)}`;
        }
      }
      this.notifyRelationshipChanged();
      void this.loadFriends(true);
      void this.loadConversations(true);
    } catch (error) {
      this.status = `拉黑失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.actionUid = '';
    }
  }

  private async unblockUser(user: SocialUser): Promise<void> {
    if (this.actionUid.length > 0) return;
    this.actionUid = user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.unblockUser(context, user.uid);
      this.status = `已解除对 ${user.nickname} 的拉黑。`;
      this.notifyRelationshipChanged();
      void this.loadFriends(true);
    } catch (error) {
      this.status = `解除拉黑失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.actionUid = '';
    }
  }

  private async cancelOutgoingRequest(request: FriendRequestItem): Promise<void> {
    if (this.actionUid.length > 0) return;
    this.actionUid = request.user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.cancelRequest(context, request.id, request.createdAt);
      this.status = `已撤回给 ${request.user.nickname} 的好友申请。`;
      this.notifyRelationshipChanged();
      void this.loadFriends(true);
    } catch (error) {
      this.status = `撤回失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.actionUid = '';
    }
  }

  private openFriendAction(user: SocialUser, action: FriendActionKind): void {
    if (this.actionUid.length > 0) return;
    this.pendingRemoveUser = user;
    this.pendingFriendAction = action;
  }

  private isGroupMemberSelected(uid: string): boolean {
    return this.groupMemberUids.some((value: string): boolean => value === uid);
  }

  private toggleGroupMember(uid: string): void {
    if (this.isGroupMemberSelected(uid)) {
      this.groupMemberUids = this.groupMemberUids.filter((value: string): boolean => value !== uid);
    } else if (this.groupMemberUids.length < 19) {
      this.groupMemberUids = this.groupMemberUids.concat([uid]);
    }
  }

  private async createGroupChat(): Promise<void> {
    const name = this.groupName.trim();
    if (name.length === 0) {
      this.status = '请填写群聊名称。';
      return;
    }
    if (this.groupMemberUids.length < 2) {
      this.status = '请至少选择两位好友。';
      return;
    }
    if (this.groupCreating) return;
    this.groupCreating = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.createGroupChat(context, name, this.groupMemberUids);
      this.groupCreatorVisible = false;
      this.groupName = '';
      this.groupMemberUids = [];
      this.status = `已创建群聊「${response.group.name}」。`;
      void this.loadGroups(true);
      this.onOpenGroup(response.group);
    } catch (error) {
      this.status = `创建群聊失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.groupCreating = false;
    }
  }

  @Builder
  private sectionButton(label: string, index: number, count: number): void {
    Button(count > 0 ? `${label} ${count}` : label)
      .layoutWeight(1).height(48).fontSize(15).fontWeight(FontWeight.Medium)
      .backgroundColor(this.selectedSection === index ? $r('app.color.accent_action') : $r('app.color.surface'))
      .fontColor(this.selectedSection === index ? $r('app.color.on_accent_action') : $r('app.color.ink'))
      .border({ width: this.selectedSection === index ? 0 : 1, color: $r('app.color.line') })
      .borderRadius(16)
      .accessibilityText(`${label}${count > 0 ? `，${count} 条待处理` : ''}${this.selectedSection === index ? '，已选中' : ''}`)
      .onClick((): void => {
        this.selectedSection = index;
      });
  }

  @Builder
  private pageHeader(): void {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text('好友与消息').fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
        Text('把真实好味道，发给认识的人').fontSize(13).fontColor($r('app.color.leaf'));
      }.alignItems(HorizontalAlign.Start);
      Blank();
      Button(this.notificationUnreadCount > 0
        ? '通知 ' + (this.notificationUnreadCount > 99 ? '99+' : this.notificationUnreadCount.toString()) : '通知')
        .height(48).fontSize(13).backgroundColor($r('app.color.accent_soft'))
        .fontColor($r('app.color.ink')).borderRadius(16)
        .accessibilityText(this.notificationUnreadCount > 0
          ? '通知，' + this.notificationUnreadCount.toString() + ' 条未读' : '打开通知')
        .onClick((): void => this.onOpenNotifications());
      Button() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(23).fontColor([$r('app.color.ink')]);
      }
      .width(48).height(48).backgroundColor($r('app.color.surface')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.line') }).accessibilityText('添加好友')
      .accessibilityDescription('打开添加好友页面').onClick((): void => {
        this.onOpenAddFriend();
      });
    }.width('100%');
  }

  @Builder
  private emptyPanel(title: string, detail: string, action: string, section: number, opensAddFriend: boolean = false): void {
    Column({ space: 12 }) {
      Image($r('app.media.ic_message')).width(52).height(52).objectFit(ImageFit.Contain)
        .accessibilityLevel('no');
      Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      Text(detail).fontSize(13).lineHeight(20).fontColor($r('app.color.muted'))
        .textAlign(TextAlign.Center).width('82%');
      Button(action).height(48).backgroundColor($r('app.color.accent_action'))
        .fontColor($r('app.color.on_accent_action')).onClick((): void => {
          if (opensAddFriend) this.onOpenAddFriend();
          else this.selectedSection = section;
        });
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
    .backgroundColor($r('app.color.surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private conversationRow(conversation: ConversationSummary): void {
    Row({ space: 12 }) {
      SocialAvatar({ user: conversation.friend, avatarSize: 56 });
      Column({ space: 6 }) {
        Row() {
          Text(conversation.friend.nickname).fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(timeLabel(conversation.lastMessageAt)).fontSize(11).fontColor($r('app.color.muted'));
        }.width('100%');
        Row({ space: 8 }) {
          Text(conversation.lastMessagePreview.length > 0 ? conversation.lastMessagePreview : '开始聊聊吃什么')
            .fontSize(13).fontColor($r('app.color.muted')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (conversation.unreadCount > 0) {
            Text(conversation.unreadCount > 99 ? '99+' : conversation.unreadCount.toString())
              .fontSize(11).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent_action'))
              .height(24).padding({ left: 8, right: 8 })
              .backgroundColor($r('app.color.accent_action')).borderRadius(12)
              .accessibilityText(`${conversation.unreadCount} 条未读消息`);
          }
        }.width('100%').alignItems(VerticalAlign.Center);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Image($r('app.media.ic_chevron_right')).width(24).height(24).objectFit(ImageFit.Contain)
        .accessibilityLevel('no');
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') })
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.98 })
    .accessibilityGroup(true).accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilityText(`${conversation.friend.nickname}，${conversation.lastMessagePreview}，${conversation.unreadCount} 条未读消息`)
    .accessibilityDescription('轻点打开私信')
    .onClick((): void => {
      this.onOpenChat(conversation.friend);
    });
  }

  @Builder
  private groupConversationRow(group: GroupConversationSummary): void {
    Row({ space: 12 }) {
      Text('群').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent_action'))
        .width(52).height(52).textAlign(TextAlign.Center).padding({ top: 15 })
        .backgroundColor($r('app.color.leaf')).borderRadius(18).accessibilityLevel('no');
      Column({ space: 6 }) {
        Row() {
          Text(group.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(timeLabel(group.lastMessageAt)).fontSize(11).fontColor($r('app.color.muted'));
        }.width('100%');
        Row({ space: 8 }) {
          Text(group.lastMessagePreview.length > 0 ? group.lastMessagePreview : `${group.memberCount} 人群聊`)
            .fontSize(13).fontColor($r('app.color.muted')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (group.unreadCount > 0) {
            Text(group.unreadCount > 99 ? '99+' : group.unreadCount.toString())
              .fontSize(11).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent_action'))
              .height(24).padding({ left: 8, right: 8 })
              .backgroundColor($r('app.color.accent_action')).borderRadius(12)
              .accessibilityText(`${group.unreadCount} 条未读群消息`);
          }
        }.width('100%').alignItems(VerticalAlign.Center);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Image($r('app.media.ic_chevron_right')).width(24).height(24).objectFit(ImageFit.Contain)
        .accessibilityLevel('no');
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') })
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.98 })
    .accessibilityGroup(true).accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilityText(`${group.name}，${group.memberCount} 人群聊，${group.unreadCount} 条未读消息`)
    .accessibilityDescription('轻点打开群聊')
    .onClick((): void => {
      this.onOpenGroup(group);
    });
  }

  @Builder
  private messageSection(): void {
    if ((this.conversationsLoading || this.groupsLoading)
      && this.conversations.length === 0 && this.groupConversations.length === 0) {
      this.emptyPanel('正在加载消息', '正在读取好友会话和未读状态。', '查看好友', 1);
    } else if (this.conversations.length === 0 && this.groupConversations.length === 0) {
      this.emptyPanel('还没有消息', '先添加好友，或邀请多位好友创建群聊，一起分享美食卡片。', '添加好友', 1, true);
    } else {
      List({ space: 10 }) {
        if (this.conversations.length > 0) {
          ListItem() {
            Text('私信').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%');
          }
        }
        ForEach(this.conversations, (conversation: ConversationSummary): void => {
          ListItem() { this.conversationRow(conversation); }
        }, (conversation: ConversationSummary): string => conversation.id);
        if (this.conversationsNextPageToken.length > 0) {
          ListItem() {
            Button(this.conversationsLoading ? '正在加载…' : '加载更多私信').width('100%').height(44)
              .enabled(!this.conversationsLoading).backgroundColor($r('app.color.accent_soft'))
              .fontColor($r('app.color.accent_action')).onClick((): void => {
                this.loadConversations(false);
              });
          }
        }
        if (this.groupConversations.length > 0) {
          ListItem() {
            Text('群聊').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
              .margin({ top: 6 });
          }
        }
        ForEach(this.groupConversations, (group: GroupConversationSummary): void => {
          ListItem() { this.groupConversationRow(group); }
        }, (group: GroupConversationSummary): string => group.id);
        if (this.groupsNextPageToken.length > 0) {
          ListItem() {
            Button(this.groupsLoading ? '正在加载…' : '加载更多群聊').width('100%').height(44)
              .enabled(!this.groupsLoading).backgroundColor($r('app.color.accent_soft'))
              .fontColor($r('app.color.accent_action')).onClick((): void => {
                this.loadGroups(false);
              });
          }
        }
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring);
    }
  }

  @Builder
  private incomingRow(request: FriendRequestItem): void {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        SocialAvatar({ user: request.user, avatarSize: 52 });
        Column({ space: 4 }) {
          Text(request.user.nickname).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%').maxLines(1);
          Text(`${request.user.friendCode} · 想加你为好友`).fontSize(12)
            .fontColor($r('app.color.muted')).width('100%').maxLines(1);
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      }.width('100%');
      Row({ space: 10 }) {
        Button('拒绝').layoutWeight(1).height(48).enabled(this.actionUid.length === 0)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
          .border({ width: 1, color: $r('app.color.line') })
          .onClick((): void => {
            this.respond(request, false);
          });
        Button(this.actionUid === request.user.uid ? '处理中' : '同意')
          .layoutWeight(1).height(48).enabled(this.actionUid.length === 0)
          .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
          .onClick((): void => {
            this.respond(request, true);
          });
      }.width('100%');
    }
    .width('100%').padding(14).backgroundColor($r('app.color.accent_soft')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private friendRow(user: SocialUser): void {
    Row({ space: 12 }) {
      Button() {
        SocialAvatar({ user: user, avatarSize: 52 });
      }
      .width(60).height(60).padding(4).backgroundColor($r('app.color.surface')).borderRadius(30)
      .accessibilityText(`查看 ${user.nickname} 的个人主页`).onClick((): void => {
        this.onOpenProfile(user);
      });
      Column({ space: 4 }) {
        Text(user.nickname).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${user.friendCode} · 已发布 ${user.publishCount} 张`)
          .fontSize(12).fontColor($r('app.color.muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button('发消息').height(48).fontSize(13).backgroundColor($r('app.color.accent_action'))
        .fontColor($r('app.color.on_accent_action')).onClick((): void => {
          this.onOpenChat(user);
        });
    }.width('100%').padding({ top: 10, bottom: 10 });
  }

  @Builder
  private friendSwipeActions(user: SocialUser): void {
    Row({ space: 8 }) {
      Button('删除').width(58).height(52).fontSize(12).backgroundColor($r('app.color.danger_action'))
        .fontColor($r('app.color.on_danger_action')).borderRadius(14).accessibilityText(`删除好友 ${user.nickname}`)
        .onClick((): void => {
          this.openFriendAction(user, 'REMOVE');
        });
      Button('拉黑').width(58).height(52).fontSize(12).backgroundColor($r('app.color.danger_soft'))
        .fontColor($r('app.color.danger')).borderRadius(14).border({ width: 1, color: $r('app.color.line') })
        .accessibilityText(`拉黑好友 ${user.nickname}`).onClick((): void => {
          this.openFriendAction(user, 'BLOCK');
        });
    }
    .height(72).padding({ left: 8, right: 2, top: 10, bottom: 10 }).backgroundColor($r('app.color.canvas'));
  }

  @Builder
  private outgoingRow(request: FriendRequestItem): void {
    Row({ space: 12 }) {
      SocialAvatar({ user: request.user, avatarSize: 46 });
      Column({ space: 3 }) {
        Text(request.user.nickname).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink')).width('100%').maxLines(1);
        Text('好友申请已发送，等待对方处理').fontSize(12).fontColor($r('app.color.muted')).width('100%');
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button(this.actionUid === request.user.uid ? '处理中' : '撤回')
        .height(44).enabled(this.actionUid.length === 0).fontSize(12)
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.warning'))
        .border({ width: 1, color: $r('app.color.line') }).onClick((): void => {
          this.cancelOutgoingRequest(request);
        });
    }.width('100%').padding({ top: 8, bottom: 8 });
  }

  @Builder
  private friendSection(): void {
    List({ space: 14 }) {
      if (this.incomingRequests.length > 0) {
        ListItem() {
          Text(`收到的申请 ${this.incomingRequests.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%');
        }
        ForEach(this.incomingRequests, (request: FriendRequestItem): void => {
          ListItem() { this.incomingRow(request); }
        }, (request: FriendRequestItem): string => request.id);
      }

      ListItem() {
        Row() {
          Text(`我的好友 ${this.friends.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).layoutWeight(1);
          Button('新建群聊').height(44).fontSize(12).backgroundColor($r('app.color.accent_soft'))
            .fontColor($r('app.color.accent_action')).enabled(this.friends.length >= 2)
            .accessibilityText('选择好友新建群聊').onClick((): void => {
              this.groupCreatorVisible = true;
            });
        }.width('100%').alignItems(VerticalAlign.Center);
      }
      if (!this.friendsLoading && this.friends.length === 0) {
        ListItem() {
          Text('还没有好友。点击右上角“+”添加好友，发送申请后等待确认。')
            .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
            .padding(16).backgroundColor($r('app.color.surface')).borderRadius(16)
            .border({ width: 1, color: $r('app.color.line') });
        }
      } else {
        ForEach(this.friends, (user: SocialUser): void => {
          ListItem() {
            Column() {
              this.friendRow(user);
              Divider().strokeWidth(1).color($r('app.color.line'));
            }.width('100%');
          }
          .swipeAction({
            start: {
              builder: (): void => {
                this.friendSwipeActions(user);
              }
            },
            end: {
              builder: (): void => {
                this.friendSwipeActions(user);
              }
            }
          })
        }, (user: SocialUser): string => user.uid);
      }
      if (this.friendsNextPageToken.length > 0) {
        ListItem() {
          Button(this.friendsLoading ? '正在加载…' : '加载更多好友与申请').width('100%').height(44)
            .enabled(!this.friendsLoading).backgroundColor($r('app.color.accent_soft'))
            .fontColor($r('app.color.accent_action')).onClick((): void => {
              this.loadFriends(false);
            });
        }
      }

      if (this.outgoingRequests.length > 0) {
        ListItem() {
          Text(`已发送的申请 ${this.outgoingRequests.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%');
        }
        ForEach(this.outgoingRequests, (request: FriendRequestItem): void => {
          ListItem() { this.outgoingRow(request); }
        }, (request: FriendRequestItem): string => request.id);
      }

      if (this.blockedUsers.length > 0) {
        ListItem() {
          Text(`已拉黑 ${this.blockedUsers.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).width('100%');
        }
        ForEach(this.blockedUsers, (user: SocialUser): void => {
          ListItem() {
            Row({ space: 12 }) {
              SocialAvatar({ user: user, avatarSize: 44 });
              Column({ space: 3 }) {
                Text(user.nickname).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
                  .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(user.friendCode).fontSize(11).fontColor($r('app.color.muted')).width('100%').maxLines(1);
              }.layoutWeight(1).alignItems(HorizontalAlign.Start);
              Button(this.actionUid === user.uid ? '处理中' : '解除拉黑').height(44).fontSize(12)
                .enabled(this.actionUid.length === 0).backgroundColor($r('app.color.accent_soft'))
                .fontColor($r('app.color.accent_action')).onClick((): void => {
                  this.unblockUser(user);
                });
            }.width('100%').padding({ top: 8, bottom: 8 }).alignItems(VerticalAlign.Center);
          }
        }, (user: SocialUser): string => user.uid);
      }
    }
    .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  private removeSheet(): void {
    Column({ space: 12 }) {
      Text(this.pendingFriendAction === 'BLOCK' ? '拉黑这位好友？' : '删除这位好友？')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      Text(this.pendingFriendAction === 'BLOCK'
        ? `拉黑 ${this.pendingRemoveUser?.nickname || '这位好友'} 后，好友关系和一对一会话会被清理，对方无法访问你的主页、卡片和图片，也无法向你发起好友申请。`
        : `删除 ${this.pendingRemoveUser?.nickname || '这位好友'} 后，好友关系和一对一会话会被清理，仍可作为访客查看公开内容。`)
        .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%');
      if (this.pendingFriendAction === 'REMOVE') {
        Button(this.actionUid.length > 0 ? '正在删除…' : '确认删除')
          .width('100%').height(48).enabled(this.actionUid.length === 0)
          .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
          .onClick((): void => {
            this.removePendingFriend();
          });
      } else {
        Button(this.actionUid.length > 0 ? '正在拉黑…' : '确认拉黑')
          .width('100%').height(48).enabled(this.actionUid.length === 0)
          .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
          .onClick((): void => {
            this.blockPendingFriend(false);
          });
        Button(this.actionUid.length > 0 ? '正在举报…' : '举报并拉黑')
          .width('100%').height(48).enabled(this.actionUid.length === 0)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.danger'))
          .border({ width: 1, color: $r('app.color.line') }).onClick((): void => {
            this.blockPendingFriend(true);
          });
      }
      Button('取消').width('100%').height(48).enabled(this.actionUid.length === 0)
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
        .border({ width: 1, color: $r('app.color.line') })
        .onClick((): void => {
          this.pendingRemoveUser = undefined;
          this.pendingFriendAction = 'REMOVE';
        });
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .backgroundColor($r('app.color.surface')).borderRadius(24)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private groupCreatorSheet(): void {
    Column({ space: 12 }) {
      Text('新建群聊').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%');
      Text('选择至少两位已互为好友的用户；群内可发送文字和食刻卡片。')
        .fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%');
      TextInput({ text: this.groupName, placeholder: '群聊名称，最多 32 字' })
        .width('100%').height(48).fontSize(15).backgroundColor($r('app.color.canvas')).borderRadius(14)
        .onChange((value: string): void => {
          this.groupName = value;
        });
      Text(`已选择 ${this.groupMemberUids.length} 位好友`).fontSize(12).fontColor($r('app.color.leaf')).width('100%');
      List({ space: 6 }) {
        ForEach(this.friends, (friend: SocialUser): void => {
          ListItem() {
            Row({ space: 10 }) {
              SocialAvatar({ user: friend, avatarSize: 38 });
              Column({ space: 2 }) {
                Text(friend.nickname).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
                  .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(friend.friendCode).fontSize(11).fontColor($r('app.color.muted')).width('100%').maxLines(1);
              }.layoutWeight(1).alignItems(HorizontalAlign.Start);
              Button(this.isGroupMemberSelected(friend.uid) ? '已选择' : '选择').height(40).fontSize(12)
                .backgroundColor(this.isGroupMemberSelected(friend.uid)
                  ? $r('app.color.accent_action') : $r('app.color.accent_soft'))
                .fontColor(this.isGroupMemberSelected(friend.uid)
                  ? $r('app.color.on_accent_action') : $r('app.color.accent_action'))
                .enabled(!this.groupCreating).onClick((): void => {
                  this.toggleGroupMember(friend.uid);
                });
            }.width('100%').padding({ top: 4, bottom: 4 }).alignItems(VerticalAlign.Center);
          }
        }, (friend: SocialUser): string => friend.uid);
      }
      .width('100%').height(230).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .padding(10).backgroundColor($r('app.color.canvas')).borderRadius(16);
      Button(this.groupCreating ? '正在创建…' : '创建群聊').width('100%').height(48)
        .enabled(!this.groupCreating && this.groupMemberUids.length >= 2 && this.groupName.trim().length > 0)
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .onClick((): void => {
          this.createGroupChat();
        });
      Button('取消').width('100%').height(48).enabled(!this.groupCreating)
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.ink'))
        .border({ width: 1, color: $r('app.color.line') }).onClick((): void => {
          this.groupCreatorVisible = false;
          this.groupName = '';
          this.groupMemberUids = [];
        });
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .backgroundColor($r('app.color.surface')).borderRadius(24)
    .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 14 }) {
        this.pageHeader();
        Row({ space: 8 }) {
          this.sectionButton('消息', 0, this.unreadCount + this.groupUnreadCount);
          this.sectionButton('好友', 1, this.incomingRequests.length);
        }.width('100%');

        if (this.status.length > 0) {
          Text(this.status).fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        }

        if (this.selectedSection === 0 && (this.conversationError.length > 0 || this.groupError.length > 0)) {
          Text(this.conversationError.length > 0 ? this.conversationError : this.groupError)
            .fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        }
        if (this.selectedSection === 1 && this.friendError.length > 0) {
          Text(this.friendError).fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        }

        if (this.selectedSection === 0) {
          this.messageSection();
        } else {
          this.friendSection();
        }
      }
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 18, bottom: 6 })
      .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);

      if (this.pendingRemoveUser !== undefined) {
        Column() {}.width('100%').height('100%').backgroundColor($r('app.color.scrim'))
          .onClick((): void => {
            if (this.actionUid.length === 0) {
              this.pendingRemoveUser = undefined;
              this.pendingFriendAction = 'REMOVE';
            }
          });
        this.removeSheet();
      }
      if (this.groupCreatorVisible) {
        Column() {}.width('100%').height('100%').backgroundColor($r('app.color.scrim'))
          .onClick((): void => {
            if (!this.groupCreating) this.groupCreatorVisible = false;
          });
        this.groupCreatorSheet();
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.canvas'));
  }
}
