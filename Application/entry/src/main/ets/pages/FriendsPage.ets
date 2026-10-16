import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteActionStyle, WarmNoteBackdrop, notePanelTransition } from '../common/WarmNoteUi';
import { RandomFoodMotionObserver } from '../common/RandomFoodUi';
import { common } from '@kit.AbilityKit';
import {
  ConversationSummary, FriendRequestItem, GroupConversationSummary, SocialUser
} from '../model/FriendModels';
import { FriendRepository } from '../repository/FriendRepository';
import { SocialAvatar } from '../components/social/SocialDisplay';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { ReadRequestOptions, ReadScheduler } from '../service/ReadScheduler';
import { ImageRepository } from '../service/ImageRepository';
import { SECONDARY_DATA_REUSE_MS } from '../service/ImageReadConfig';
import { DiffDataSource } from '../service/PagedDataSource';

type FriendActionKind = 'REMOVE' | 'BLOCK';
interface NoteConversationEntry {
  id: string; updatedAt: number; conversation?: ConversationSummary; group?: GroupConversationSummary;
}

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
  @Prop palette: PagePaletteName = 'SOCIAL';
  @State reducedMotion: boolean = true;
  private motionObserver: RandomFoodMotionObserver = new RandomFoodMotionObserver((reduced: boolean): void => { this.reducedMotion = reduced; });
  @Prop @Watch('onActiveChanged') pageActive: boolean = true;
  @StorageLink('stage47AppActive') @Watch('onActiveChanged') appActive: boolean = true;
  private mounted: boolean = false;
  private active: boolean = false;
  private readGeneration: number = 0;
  private lastRefreshedAt: number = 0;
  private current(generation: number): boolean { return this.active && this.pageActive && this.appActive && generation === this.readGeneration; }
  private readOptions(generation: number): ReadRequestOptions {
    return { priority: 'secondary', mayContinue: async (): Promise<boolean> => this.current(generation) };
  }
  private onActiveChanged(): void {
    const active: boolean = this.mounted && this.pageActive && this.appActive;
    if (active === this.active) return;
    this.active = active; this.readGeneration++;
    this.friendsLoading = false; this.conversationsLoading = false; this.groupsLoading = false;
    if (active) { this.reducedMotion = this.motionObserver.start(); void this.refreshAll(false); }
    else { this.motionObserver.stop(); this.reducedMotion = true; ReadScheduler.subscriptionsChanged(); ImageRepository.subscriptionsChanged(); }
  }
  onOpenChat: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenProfile: (friend: SocialUser) => void = (_friend: SocialUser): void => {};
  onOpenGroup: (group: GroupConversationSummary) => void = (_group: GroupConversationSummary): void => {};
  onOpenAddFriend: () => void = (): void => {};
  @StorageLink('socialForegroundRevision') @Watch('onSocialForegroundChanged') socialForegroundRevision: number = 0;
  @StorageLink('requestedFriendSection') @Watch('onRequestedFriendSectionChanged') requestedFriendSection: number = 0;
  @State selectedSection: number = 0;
  // Pack 4.3: friends and conversations render through LazyForEach. Render keys include the row data, so a
  // changed unread count / last message / nickname rebuilds just that row.
  @State @Watch('syncFriendSource') friends: Array<SocialUser> = [];
  private friendSource: DiffDataSource<SocialUser> = new DiffDataSource<SocialUser>(
    (user: SocialUser): string => user.uid, (user: SocialUser): string => user.uid + ':' + JSON.stringify(user));
  private conversationSource: DiffDataSource<NoteConversationEntry> = new DiffDataSource<NoteConversationEntry>(
    (entry: NoteConversationEntry): string => entry.id,
    (entry: NoteConversationEntry): string => entry.id + ':' + JSON.stringify(entry));
  private syncFriendSource(): void { this.friendSource.update(this.friends); }
  private syncConversationSource(): void { this.conversationSource.update(this.orderedConversations()); }
  @State blockedUsers: Array<SocialUser> = [];
  @State incomingRequests: Array<FriendRequestItem> = [];
  @State outgoingRequests: Array<FriendRequestItem> = [];
  @State @Watch('syncConversationSource') conversations: Array<ConversationSummary> = [];
  @State @Watch('syncConversationSource') groupConversations: Array<GroupConversationSummary> = [];
  @State unreadCount: number = 0;
  @State groupUnreadCount: number = 0;
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

  aboutToAppear(): void {
    this.mounted = true;
    if (this.requestedFriendSection === 1) {
      this.selectedSection = 1;
      this.requestedFriendSection = 0;
    }
    this.onActiveChanged();
  }
  aboutToDisappear(): void { this.mounted = false; this.onActiveChanged(); }

  private onRequestedFriendSectionChanged(): void {
    if (this.requestedFriendSection === 1) {
      this.selectedSection = 1;
      this.requestedFriendSection = 0;
    }
  }

  private onSocialForegroundChanged(): void {
    if (this.active && this.socialForegroundRevision > 0) void this.refreshAll(false);
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
    if (!this.active || this.friendsLoading || (!reset && this.friendsNextPageToken.length === 0)) return;
    const generation: number = this.readGeneration;
    this.friendsLoading = true;
    this.friendError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listFriends(context, reset ? '' : this.friendsNextPageToken, 50, this.readOptions(generation));
      if (!this.current(generation)) return;
      this.friends = reset ? response.friends : this.appendUsers(this.friends, response.friends);
      this.incomingRequests = reset ? response.incomingRequests
        : this.appendRequests(this.incomingRequests, response.incomingRequests);
      this.outgoingRequests = reset ? response.outgoingRequests
        : this.appendRequests(this.outgoingRequests, response.outgoingRequests);
      this.blockedUsers = reset ? response.blockedUsers : this.appendUsers(this.blockedUsers, response.blockedUsers);
      this.friendsNextPageToken = response.nextPageToken;
    } catch (error) {
      if (this.current(generation)) this.friendError = `好友与申请加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.readGeneration) this.friendsLoading = false;
    }
  }

  private async loadConversations(reset: boolean): Promise<void> {
    if (!this.active || this.conversationsLoading || (!reset && this.conversationsNextPageToken.length === 0)) return;
    const generation: number = this.readGeneration;
    this.conversationsLoading = true;
    this.conversationError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listConversations(context, reset ? '' : this.conversationsNextPageToken, 50, this.readOptions(generation));
      if (!this.current(generation)) return;
      this.conversations = reset ? response.conversations : this.conversations.concat(response.conversations);
      this.unreadCount = response.unreadCount;
      this.conversationsNextPageToken = response.nextPageToken;
    } catch (error) {
      if (this.current(generation)) this.conversationError = `私信加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.readGeneration) this.conversationsLoading = false;
    }
  }

  private async loadGroups(reset: boolean): Promise<void> {
    if (!this.active || this.groupsLoading || (!reset && this.groupsNextPageToken.length === 0)) return;
    const generation: number = this.readGeneration;
    this.groupsLoading = true;
    this.groupError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const response = await this.repository.listGroupConversations(context, reset ? '' : this.groupsNextPageToken, 50, this.readOptions(generation));
      if (!this.current(generation)) return;
      this.groupConversations = reset ? response.groups : this.groupConversations.concat(response.groups);
      this.groupUnreadCount = response.unreadCount;
      this.groupsNextPageToken = response.nextPageToken;
    } catch (error) {
      if (this.current(generation)) this.groupError = `群聊加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      if (generation === this.readGeneration) this.groupsLoading = false;
    }
  }

  private async refreshAll(force: boolean = true): Promise<void> {
    if (!this.active || this.friendsLoading || this.conversationsLoading || this.groupsLoading ||
      !force && Date.now() - this.lastRefreshedAt < SECONDARY_DATA_REUSE_MS) return;
    const generation: number = this.readGeneration;
    await Promise.all([this.loadFriends(true), this.loadConversations(true), this.loadGroups(true)]);
    if (this.current(generation) && this.friendError.length === 0 && this.conversationError.length === 0 && this.groupError.length === 0)
      this.lastRefreshedAt = Date.now();
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

  private async blockPendingFriend(): Promise<void> {
    const user = this.pendingRemoveUser;
    if (user === undefined || this.actionUid.length > 0) return;
    this.actionUid = user.uid;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.blockUser(context, user.uid);
      this.pendingRemoveUser = undefined;
      this.pendingFriendAction = 'REMOVE';
      this.status = `已拉黑 ${user.nickname}，一对一会话已清理。`;
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

  private orderedConversations(): Array<NoteConversationEntry> {
    const entries: Array<NoteConversationEntry> = [];
    for (const conversation of this.conversations) {
      const entry: NoteConversationEntry = { id: 'friend:' + conversation.id, updatedAt: conversation.lastMessageAt, conversation };
      entries.push(entry);
    }
    for (const group of this.groupConversations) {
      const entry: NoteConversationEntry = { id: 'group:' + group.id, updatedAt: group.lastMessageAt, group };
      entries.push(entry);
    }
    return entries.sort((left: NoteConversationEntry, right: NoteConversationEntry): number => right.updatedAt - left.updatedAt || left.id.localeCompare(right.id));
  }
  @Builder
  private sectionButton(label: string, index: number, count: number): void {
    Button() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(label).fontSize(19).fontWeight(this.selectedSection === index ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(this.selectedSection === index ? pageColor(this.palette, 'ink') : pageColor(this.palette, 'muted'));
          if (count > 0) { Text(count > 99 ? '99+' : count.toString()).fontSize(12).fontColor($r('app.color.on_danger_action'))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor($r('app.color.danger_action')).borderRadius(12); }
        }.justifyContent(FlexAlign.Center);
        Column() {}.width(48).height(3).backgroundColor(this.selectedSection === index ? pageColor(this.palette, 'gold') : Color.Transparent).borderRadius(2);
      }.width('100%').padding({ top: 8, bottom: 2 });
    }.type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: 52 }).padding(0).backgroundColor(Color.Transparent)
      .accessibilitySelected(this.selectedSection === index).accessibilityText(label + (count > 0 ? `，${count} 条待处理` : ''))
      .onClick((): void => { this.selectedSection = index; });
  }
  @Builder
  private pageHeader(): void {
    Row({ space: 8 }) {
      Text('好友').fontSize(28).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
      Button() { SymbolGlyph($r('sys.symbol.plus')).fontSize(24).fontColor([pageColor(this.palette, 'ink')]); }
        .width(48).height(48).backgroundColor(Color.Transparent).accessibilityText('添加好友').onClick((): void => this.onOpenAddFriend());
      Button() { Image($r('app.media.ic_discovery_refresh')).width(24).height(24).accessibilityLevel('no'); }
        .width(48).height(48).backgroundColor(Color.Transparent).enabled(!this.friendsLoading && !this.conversationsLoading && !this.groupsLoading)
        .accessibilityText('刷新好友和消息').onClick((): void => { void this.refreshAll(true); });
    }.width('100%');
  }
  @Builder
  private socialShortcuts(): void {
    Button() {
      Row({ space: 10 }) {
        Image($r('app.media.ic_discovery_search')).width(22).height(22).accessibilityLevel('no');
        Text('搜索好友').fontSize(15).fontColor(pageColor(this.palette, 'muted')).layoutWeight(1).textAlign(TextAlign.Start);
      }.width('100%').padding(14);
    }.type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 48 }).padding(0)
      .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(18).accessibilityText('搜索并添加好友')
      .onClick((): void => this.onOpenAddFriend());
    Row({ space: 10 }) {
      Button() {
        Row({ space: 8 }) {
          Image($r('app.media.nav_friends')).width(26).height(26).accessibilityLevel('no');
          Text('新的朋友').fontSize(15).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1).maxLines(2).textAlign(TextAlign.Center);
          if (this.incomingRequests.length > 0) { Text(this.incomingRequests.length > 99 ? '99+' : this.incomingRequests.length.toString())
            .fontSize(11).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'canvas'))
            .constraintSize({ minWidth: 20 }).height(20).textAlign(TextAlign.Center).padding({ left: 6, right: 6 })
            .backgroundColor(pageColor(this.palette, 'action')).borderRadius(10); }
        }.width('100%').justifyContent(FlexAlign.Center).padding(12);
      }.type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: 56 }).padding(0)
        .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(18)
        .border({ width: 1.2, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed }).accessibilityText('查看好友申请')
        .onClick((): void => { this.selectedSection = 1; });
      Button() {
        Row({ space: 8 }) {
          Image($r('app.media.ic_message')).width(26).height(26).accessibilityLevel('no');
          Text('新建群聊').fontSize(15).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1).maxLines(2).textAlign(TextAlign.Center);
        }.width('100%').justifyContent(FlexAlign.Center).padding(12);
      }.type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: 56 }).padding(0)
        .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(18)
        .border({ width: 1.2, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed }).enabled(this.friends.length >= 2)
        .accessibilityText('选择好友新建群聊').onClick((): void => { this.groupCreatorVisible = true; });
    }.width('100%');
  }

  @Builder
  private emptyPanel(title: string, detail: string, action: string, section: number, opensAddFriend: boolean = false): void {
    Column({ space: 12 }) {
      Image($r('app.media.ic_message')).width(52).height(52).objectFit(ImageFit.Contain)
        .accessibilityLevel('no');
      Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
      Text(detail).fontSize(13).lineHeight(20).fontColor(pageColor(this.palette, 'muted'))
        .textAlign(TextAlign.Center).width('82%');
      Button(action).height(48).backgroundColor(pageColor(this.palette, 'gold'))
        .fontColor(pageColor(this.palette, 'on_gold')).onClick((): void => {
          if (opensAddFriend) this.onOpenAddFriend();
          else this.selectedSection = section;
        });
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
    .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(20)
    .border({ width: 1, color: pageColor(this.palette, 'line') });
  }

  @Builder
  private conversationRow(conversation: ConversationSummary): void {
    Row({ space: 12 }) {
      SocialAvatar({ user: conversation.friend, avatarSize: 56 });
      Column({ space: 6 }) {
        Row() {
          Text(conversation.friend.nickname).fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'ink')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(timeLabel(conversation.lastMessageAt)).fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        }.width('100%');
        Row({ space: 8 }) {
          Text(conversation.lastMessagePreview.length > 0 ? conversation.lastMessagePreview : '开始聊聊吃什么')
            .fontSize(13).fontColor(pageColor(this.palette, 'muted')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (conversation.unreadCount > 0) {
            Text(conversation.unreadCount > 99 ? '99+' : conversation.unreadCount.toString())
              .fontSize(11).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'canvas'))
              .height(20).padding({ left: 6, right: 6 })
              .backgroundColor(pageColor(this.palette, 'action')).borderRadius(10)
              .accessibilityText(`${conversation.unreadCount} 条未读消息`);
          }
        }.width('100%').alignItems(VerticalAlign.Center);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Image($r('app.media.ic_chevron_right')).width(24).height(24).objectFit(ImageFit.Contain)
        .accessibilityLevel('no');
    }
    .width('100%').padding({ left: 12, right: 12, top: 16, bottom: 16 }).backgroundColor(Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 1 })
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
      Text('群').fontSize(16).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'on_gold'))
        .width(52).height(52).textAlign(TextAlign.Center).padding({ top: 15 })
        .backgroundColor(pageColor(this.palette, 'gold')).borderRadius(18).accessibilityLevel('no');
      Column({ space: 6 }) {
        Row() {
          Text(group.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(timeLabel(group.lastMessageAt)).fontSize(12).fontColor(pageColor(this.palette, 'muted'));
        }.width('100%');
        Row({ space: 8 }) {
          Text(group.lastMessagePreview.length > 0 ? group.lastMessagePreview : `${group.memberCount} 人群聊`)
            .fontSize(13).fontColor(pageColor(this.palette, 'muted')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (group.unreadCount > 0) {
            Text(group.unreadCount > 99 ? '99+' : group.unreadCount.toString())
              .fontSize(11).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'canvas'))
              .height(20).padding({ left: 6, right: 6 })
              .backgroundColor(pageColor(this.palette, 'action')).borderRadius(10)
              .accessibilityText(`${group.unreadCount} 条未读群消息`);
          }
        }.width('100%').alignItems(VerticalAlign.Center);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Image($r('app.media.ic_chevron_right')).width(24).height(24).objectFit(ImageFit.Contain)
        .accessibilityLevel('no');
    }
    .width('100%').padding({ left: 12, right: 12, top: 16, bottom: 16 }).backgroundColor(Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 1 })
    .accessibilityGroup(true).accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilityText(`${group.name}，${group.memberCount} 人群聊，${group.unreadCount} 条未读消息`)
    .accessibilityDescription('轻点打开群聊')
    .onClick((): void => {
      this.onOpenGroup(group);
    });
  }

  @Builder
  private messageSection(): void {
    if ((this.conversationsLoading || this.groupsLoading) && this.conversations.length === 0 && this.groupConversations.length === 0) {
      this.emptyPanel('正在加载消息', '正在读取好友会话和未读状态。', '查看好友', 1);
    } else if (this.conversations.length === 0 && this.groupConversations.length === 0) {
      this.emptyPanel('还没有消息', '添加好友，分享一张真实的美食卡片。', '添加好友', 1, true);
    } else {
      List({ space: 0 }) {
        LazyForEach(this.conversationSource, (entry: NoteConversationEntry): void => {
          ListItem() {
            Column() {
              if (entry.conversation !== undefined) { this.conversationRow(entry.conversation); }
              else if (entry.group !== undefined) { this.groupConversationRow(entry.group); }
              Column().width('100%').height(1).margin({ left: 76 })
                .border({ width: { top: 1 }, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed }).accessibilityLevel('no');
            }.width('100%');
          }
        }, (_entry: NoteConversationEntry, index: number): string => this.conversationSource.keyAt(index));
        if (this.conversationsNextPageToken.length > 0) { ListItem() {
          Button(this.conversationsLoading ? '正在加载…' : '更多私信').width('100%').enabled(!this.conversationsLoading)
            .attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { void this.loadConversations(false); });
        } }
        if (this.groupsNextPageToken.length > 0) { ListItem() {
          Button(this.groupsLoading ? '正在加载…' : '更多群聊').width('100%').enabled(!this.groupsLoading)
            .attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { void this.loadGroups(false); });
        } }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .maintainVisibleContentPosition(true).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(22)
        .border({ width: 1.2, color: pageColor(this.palette, 'line'), style: BorderStyle.Dashed });
    }
  }

  @Builder
  private incomingRow(request: FriendRequestItem): void {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        SocialAvatar({ user: request.user, avatarSize: 52 });
        Column({ space: 4 }) {
          Text(request.user.nickname).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(1);
          Text(`${request.user.friendCode} · 想加你为好友`).fontSize(12)
            .fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1);
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      }.width('100%');
      Row({ space: 10 }) {
        Button('拒绝').layoutWeight(1).height(48).enabled(this.actionUid.length === 0)
          .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'ink'))
          .border({ width: 1, color: pageColor(this.palette, 'line') })
          .onClick((): void => {
            this.respond(request, false);
          });
        Button(this.actionUid === request.user.uid ? '处理中' : '同意')
          .layoutWeight(1).height(48).enabled(this.actionUid.length === 0)
          .backgroundColor(pageColor(this.palette, 'gold')).fontColor(pageColor(this.palette, 'on_gold'))
          .onClick((): void => {
            this.respond(request, true);
          });
      }.width('100%');
    }
    .width('100%').padding(14).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(18)
    .border({ width: 1, color: pageColor(this.palette, 'line') });
  }

  @Builder
  private friendRow(user: SocialUser): void {
    Row({ space: 12 }) {
      Button() {
        SocialAvatar({ user: user, avatarSize: 52 });
      }
      .width(60).height(60).padding(4).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(30)
      .accessibilityText(`查看 ${user.nickname} 的个人主页`).onClick((): void => {
        this.onOpenProfile(user);
      });
      Column({ space: 4 }) {
        Text(user.nickname).fontSize(16).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${user.friendCode} · 已发布 ${user.publishCount} 张`)
          .fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button('发消息').height(48).fontSize(13).backgroundColor(pageColor(this.palette, 'gold'))
        .fontColor(pageColor(this.palette, 'on_gold')).onClick((): void => {
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
        .fontColor($r('app.color.danger')).borderRadius(14).border({ width: 1, color: pageColor(this.palette, 'line') })
        .accessibilityText(`拉黑好友 ${user.nickname}`).onClick((): void => {
          this.openFriendAction(user, 'BLOCK');
        });
    }
    .height(72).padding({ left: 8, right: 2, top: 10, bottom: 10 }).backgroundColor(pageColor(this.palette, 'canvas'));
  }

  @Builder
  private outgoingRow(request: FriendRequestItem): void {
    Row({ space: 12 }) {
      SocialAvatar({ user: request.user, avatarSize: 46 });
      Column({ space: 3 }) {
        Text(request.user.nickname).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(pageColor(this.palette, 'ink')).width('100%').maxLines(1);
        Text('好友申请已发送，等待对方处理').fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%');
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button(this.actionUid === request.user.uid ? '处理中' : '撤回')
        .height(48).enabled(this.actionUid.length === 0).fontSize(12)
        .backgroundColor(pageColor(this.palette, 'surface')).fontColor($r('app.color.warning'))
        .border({ width: 1, color: pageColor(this.palette, 'line') }).onClick((): void => {
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
            .fontColor(pageColor(this.palette, 'ink')).width('100%');
        }
        ForEach(this.incomingRequests, (request: FriendRequestItem): void => {
          ListItem() { this.incomingRow(request); }
        }, (request: FriendRequestItem): string => request.id);
      }

      ListItem() {
        Row() {
          Text(`我的好友 ${this.friends.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'ink')).layoutWeight(1);
          Button('新建群聊').height(48).fontSize(12).backgroundColor(pageColor(this.palette, 'soft'))
            .fontColor(pageColor(this.palette, 'action')).enabled(this.friends.length >= 2)
            .accessibilityText('选择好友新建群聊').onClick((): void => {
              this.groupCreatorVisible = true;
            });
        }.width('100%').alignItems(VerticalAlign.Center);
      }
      if (!this.friendsLoading && this.friends.length === 0) {
        ListItem() {
          Text('还没有好友。点击右上角“+”添加好友，发送申请后等待确认。')
            .fontSize(13).lineHeight(20).fontColor(pageColor(this.palette, 'muted')).width('100%')
            .padding(16).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(16)
            .border({ width: 1, color: pageColor(this.palette, 'line') });
        }
      } else {
        LazyForEach(this.friendSource, (user: SocialUser): void => {
          ListItem() {
            Column() {
              this.friendRow(user);
              Divider().strokeWidth(1).color(pageColor(this.palette, 'line'));
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
        }, (_user: SocialUser, index: number): string => this.friendSource.keyAt(index));
      }
      if (this.friendsNextPageToken.length > 0) {
        ListItem() {
          Button(this.friendsLoading ? '正在加载…' : '加载更多好友与申请').width('100%').height(48)
            .enabled(!this.friendsLoading).backgroundColor(pageColor(this.palette, 'soft'))
            .fontColor(pageColor(this.palette, 'action')).onClick((): void => {
              this.loadFriends(false);
            });
        }
      }

      if (this.outgoingRequests.length > 0) {
        ListItem() {
          Text(`已发送的申请 ${this.outgoingRequests.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'ink')).width('100%');
        }
        ForEach(this.outgoingRequests, (request: FriendRequestItem): void => {
          ListItem() { this.outgoingRow(request); }
        }, (request: FriendRequestItem): string => request.id);
      }

      if (this.blockedUsers.length > 0) {
        ListItem() {
          Text(`已拉黑 ${this.blockedUsers.length}`).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(pageColor(this.palette, 'ink')).width('100%');
        }
        ForEach(this.blockedUsers, (user: SocialUser): void => {
          ListItem() {
            Row({ space: 12 }) {
              SocialAvatar({ user: user, avatarSize: 44 });
              Column({ space: 3 }) {
                Text(user.nickname).fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'))
                  .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(user.friendCode).fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1);
              }.layoutWeight(1).alignItems(HorizontalAlign.Start);
              Button(this.actionUid === user.uid ? '处理中' : '解除拉黑').height(48).fontSize(12)
                .enabled(this.actionUid.length === 0).backgroundColor(pageColor(this.palette, 'soft'))
                .fontColor(pageColor(this.palette, 'action')).onClick((): void => {
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
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'));
      Text(this.pendingFriendAction === 'BLOCK'
        ? `拉黑 ${this.pendingRemoveUser?.nickname || '这位好友'} 后，好友关系和一对一会话会被清理，对方无法访问你的主页、卡片和图片，也无法向你发起好友申请。`
        : `删除 ${this.pendingRemoveUser?.nickname || '这位好友'} 后，好友关系和一对一会话会被清理，仍可作为访客查看公开内容。`)
        .fontSize(13).lineHeight(20).fontColor(pageColor(this.palette, 'muted')).width('100%');
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
            this.blockPendingFriend();
          });
      }
      Button('取消').width('100%').height(48).enabled(this.actionUid.length === 0)
        .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'ink'))
        .border({ width: 1, color: pageColor(this.palette, 'line') })
        .onClick((): void => {
          this.pendingRemoveUser = undefined;
          this.pendingFriendAction = 'REMOVE';
        });
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
    .transition(notePanelTransition(this.reducedMotion))
    .border({ width: 1, color: pageColor(this.palette, 'line') });
  }

  @Builder
  private groupCreatorSheet(): void {
    Column({ space: 12 }) {
      Text('新建群聊').fontSize(20).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%');
      Text('选择至少两位已互为好友的用户；群内可发送文字和食刻卡片。')
        .fontSize(13).lineHeight(20).fontColor(pageColor(this.palette, 'muted')).width('100%');
      TextInput({ text: this.groupName, placeholder: '群聊名称，最多 32 字' })
        .width('100%').height(48).fontSize(15).backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(14)
        .onChange((value: string): void => {
          this.groupName = value;
        });
      Text(`已选择 ${this.groupMemberUids.length} 位好友`).fontSize(12).fontColor(pageColor(this.palette, 'action')).width('100%');
      List({ space: 6 }) {
        ForEach(this.friends, (friend: SocialUser): void => {
          ListItem() {
            Row({ space: 10 }) {
              SocialAvatar({ user: friend, avatarSize: 38 });
              Column({ space: 2 }) {
                Text(friend.nickname).fontSize(15).fontWeight(FontWeight.Medium).fontColor(pageColor(this.palette, 'ink'))
                  .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(friend.friendCode).fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%').maxLines(1);
              }.layoutWeight(1).alignItems(HorizontalAlign.Start);
              Button(this.isGroupMemberSelected(friend.uid) ? '已选择' : '选择').height(48).fontSize(12)
                .backgroundColor(this.isGroupMemberSelected(friend.uid)
                  ? pageColor(this.palette, 'gold') : pageColor(this.palette, 'soft'))
                .fontColor(this.isGroupMemberSelected(friend.uid)
                  ? pageColor(this.palette, 'on_gold') : pageColor(this.palette, 'action'))
                .enabled(!this.groupCreating).onClick((): void => {
                  this.toggleGroupMember(friend.uid);
                });
            }.width('100%').padding({ top: 4, bottom: 4 }).alignItems(VerticalAlign.Center);
          }
        }, (friend: SocialUser): string => friend.uid);
      }
      .width('100%').height(230).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .padding(10).backgroundColor(pageColor(this.palette, 'canvas')).borderRadius(16);
      Button(this.groupCreating ? '正在创建…' : '创建群聊').width('100%').height(48)
        .enabled(!this.groupCreating && this.groupMemberUids.length >= 2 && this.groupName.trim().length > 0)
        .backgroundColor(pageColor(this.palette, 'gold')).fontColor(pageColor(this.palette, 'on_gold'))
        .onClick((): void => {
          this.createGroupChat();
        });
      Button('取消').width('100%').height(48).enabled(!this.groupCreating)
        .backgroundColor(pageColor(this.palette, 'surface')).fontColor(pageColor(this.palette, 'ink'))
        .border({ width: 1, color: pageColor(this.palette, 'line') }).onClick((): void => {
          this.groupCreatorVisible = false;
          this.groupName = '';
          this.groupMemberUids = [];
        });
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
    .transition(notePanelTransition(this.reducedMotion))
    .border({ width: 1, color: pageColor(this.palette, 'line') }).alignItems(HorizontalAlign.Start);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      WarmNoteBackdrop({ palette: this.palette });
      Column({ space: 14 }) {
        this.pageHeader();
        Row({ space: 8 }) {
          this.sectionButton('消息', 0, this.unreadCount + this.groupUnreadCount);
          this.sectionButton('好友', 1, this.incomingRequests.length);
        }.width('100%');
        this.socialShortcuts();

        if (this.status.length > 0) {
          Text(this.status).fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(12);
        }

        if (this.selectedSection === 0 && (this.conversationError.length > 0 || this.groupError.length > 0)) {
          Text(this.conversationError.length > 0 ? this.conversationError : this.groupError)
            .fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(12);
        }
        if (this.selectedSection === 1 && this.friendError.length > 0) {
          Text(this.friendError).fontSize(12).lineHeight(19).fontColor($r('app.color.warning')).width('100%')
            .padding(10).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(12);
        }

        if (this.selectedSection === 0) {
          this.messageSection();
        } else {
          this.friendSection();
        }
      }
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 18, bottom: 6 })
      .backgroundColor(Color.Transparent).alignItems(HorizontalAlign.Start);

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
    }.width('100%').height('100%').backgroundColor(pageColor(this.palette, 'canvas'));
  }
}
