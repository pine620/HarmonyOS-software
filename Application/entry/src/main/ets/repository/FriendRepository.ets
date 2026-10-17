/**
 * 【文件职责】好友、私信、群聊相关的全部云端调用（19 个操作，全部由 shike-social 提供），
 * 并在返回后补全头像、分享卡片封面等图片的本地地址。
 * 【链路位置】FriendsPage / FriendSearchPage / ChatPage / GroupChatPage / ShareCardPage / UserProfileContent
 * → 本文件 → CloudGateway → shike-social → runtime.js 中的好友、私信、群聊函数。
 * 【新人注意】消息正文在云端以 AES-256-GCM 加密存储，客户端收到的是云端解密后的明文；
 * 响应/拉黑/删除等操作都带“期望版本”（expectedCreatedAt / expectedUpdatedAt），列表过期时云端会拒绝，避免误操作。
 */
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { CardPhoto, FoodCard, OperationResponse } from '../model/CloudContracts';
import {
  CancelFriendRequest, ChatMessage, ConversationSummary, ConversationsResponse, CreateGroupChatRequest,
  CreateGroupChatResponse, FriendProfileRequest, FriendProfileResponse, FriendRequestItem, FriendsResponse,
  GroupChatDetailResponse, GroupConversationsResponse,
  GroupIdRequest, GroupMemberProfile, GroupMessage, GroupMessagesResponse, ListGroupMessagesRequest, ListMessagesRequest,
  MessagesResponse, PageRequest, RemoveFriendRequest, RemoveGroupMemberRequest, RespondFriendRequestRequest,
  SearchUsersRequest, SearchUsersResponse, SendFriendRequestRequest, SendGroupMessageRequest,
  SendGroupMessageResponse, SendMessageRequest, SendMessageResponse, SocialUser, UserIdRequest
} from '../model/FriendModels';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';
import { ImageRepository } from '../service/ImageRepository';
import { ReadRequestOptions } from '../service/ReadScheduler';

// 好友 / 私信 / 群聊仓库。
export class FriendRepository {
  // “解除好友”请求缓存：同一好友 + 同一版本的重试复用同一个 requestId，云端据此保证只执行一次。
  private removalRequests: Map<string, RemoveFriendRequest> = new Map<string, RemoveFriendRequest>();

  // 补全用户头像的本地图片地址（低优先级）；读取失败时显示默认头像。
  private async resolveUserAvatar(context: common.Context, user: SocialUser, options: ReadRequestOptions = {}): Promise<void> {
    if (user.avatarPath.length === 0 || user.avatarBucket.length === 0) {
      user.avatarUrl = '';
      return;
    }
    try {
      user.avatarUrl = await ImageRepository.getDownloadUrl(context, user.avatarBucket, user.avatarPath, 'low', options.mayContinue);
    } catch (_error) {
      user.avatarUrl = '';
    }
  }

  // 补全卡片首图（封面）的本地图片地址，并同步到 photos[0]；失败时显示占位图。
  private async resolveCardPhoto(context: common.Context, card: FoodCard): Promise<void> {
    if (card.photoPath.length === 0 || card.photoBucket.length === 0) {
      card.photoUrl = '';
      return;
    }
    try {
      card.photoUrl = await ImageRepository.getDownloadUrl(context, card.photoBucket, card.photoPath, 'normal', undefined, card.photos?.[0], true);
    } catch (_error) {
      card.photoUrl = '';
    }
    const photos: Array<CardPhoto> = card.photos === undefined ? [] : card.photos;
    if (photos.length > 0) photos[0].url = card.photoUrl;
  }

  // 为好友申请列表中的每个用户补全头像。
  private async resolveRequestUsers(context: common.Context, requests: Array<FriendRequestItem>, options: ReadRequestOptions = {}): Promise<void> {
    await Promise.all(requests.map((request: FriendRequestItem): Promise<void> =>
      this.resolveUserAvatar(context, request.user, options)));
  }

  // 按食刻号或昵称搜索用户。
  async search(context: common.Context, keyword: string): Promise<Array<SocialUser>> {
    await AuthService.ensureSession(context);
    const request: SearchUsersRequest = { keyword };
    const response = await CloudGateway.callAuthenticated<SearchUsersResponse>('search-users', request);
    await Promise.all(response.users.map((user: SocialUser): Promise<void> => this.resolveUserAvatar(context, user)));
    return response.users;
  }

  // 分页读取好友列表，同时返回收到的申请、发出的申请和黑名单。
  async listFriends(context: common.Context, pageToken: string = '', pageSize: number = 50, options: ReadRequestOptions = {}): Promise<FriendsResponse> {
    await AuthService.ensureSession(context);
    const request: PageRequest = { pageToken, pageSize };
    const response = await CloudGateway.callAuthenticated<FriendsResponse>('list-friends', request, options);
    await Promise.all(response.friends.map((user: SocialUser): Promise<void> => this.resolveUserAvatar(context, user, options)));
    await this.resolveRequestUsers(context, response.incomingRequests, options);
    await this.resolveRequestUsers(context, response.outgoingRequests, options);
    await Promise.all(response.blockedUsers.map((user: SocialUser): Promise<void> => this.resolveUserAvatar(context, user, options)));
    return response;
  }

  // 读取好友主页：资料、主页背景图和对方公开的卡片（分页）。
  async friendProfile(context: common.Context, friendUid: string, pageToken: string = '',
    pageSize: number = 12): Promise<FriendProfileResponse> {
    await AuthService.ensureSession(context);
    const request: FriendProfileRequest = { friendUid, pageToken, pageSize };
    const response = await CloudGateway.callAuthenticated<FriendProfileResponse>('get-friend-profile', request);
    await this.resolveUserAvatar(context, response.profile.user);
    response.profile.coverUrl = '';
    if (response.profile.coverPath.length > 0 && response.profile.coverBucket.length > 0) {
      try {
        response.profile.coverUrl = await ImageRepository.getDownloadUrl(context,
          response.profile.coverBucket, response.profile.coverPath);
      } catch (_error) {
        response.profile.coverUrl = '';
      }
    }
    await Promise.all(response.cards.map((card: FoodCard): Promise<void> => this.resolveCardPhoto(context, card)));
    return response;
  }

  // 向对方发送好友申请。
  async sendRequest(context: common.Context, targetUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: SendFriendRequestRequest = { targetUid };
    await CloudGateway.callAuthenticated<OperationResponse>('send-friend-request', request);
  }

  // 同意或拒绝好友申请；expectedCreatedAt 用于确认处理的是界面上看到的那一条申请。
  async respondRequest(context: common.Context, requestId: string, accept: boolean, expectedCreatedAt: number): Promise<void> {
    await AuthService.ensureSession(context);
    const request: RespondFriendRequestRequest = { requestId, accept, expectedCreatedAt };
    await CloudGateway.callAuthenticated<OperationResponse>('respond-friend-request', request);
  }

  // 撤回自己发出的好友申请。
  async cancelRequest(context: common.Context, requestId: string, expectedCreatedAt: number): Promise<void> {
    await AuthService.ensureSession(context);
    const request: CancelFriendRequest = { requestId, expectedCreatedAt };
    await CloudGateway.callAuthenticated<OperationResponse>('cancel-friend-request', request);
  }

  // 拉黑用户（同时解除好友关系、对方无法再发申请或消息）。
  async blockUser(context: common.Context, targetUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: UserIdRequest = { targetUid };
    await CloudGateway.callAuthenticated<OperationResponse>('block-user', request);
  }

  // 解除拉黑。
  async unblockUser(context: common.Context, targetUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: UserIdRequest = { targetUid };
    await CloudGateway.callAuthenticated<OperationResponse>('unblock-user', request);
  }

  /**
   * 解除好友。
   * 必须带上列表中显示的关系版本（expectedUpdatedAt），版本不对说明列表已过期，需要刷新后再操作；
   * 网络失败后重试会复用同一个 requestId，避免重复执行会话清理等后续工作。
   */
  async removeFriend(context: common.Context, friendUid: string, expectedUpdatedAt: number | undefined): Promise<void> {
    await AuthService.ensureSession(context);
    if (expectedUpdatedAt === undefined || !Number.isSafeInteger(expectedUpdatedAt) || expectedUpdatedAt <= 0) {
      throw new Error('请刷新好友列表后再解除好友。');
    }
    const key: string = `${friendUid}:${expectedUpdatedAt}`;
    let request: RemoveFriendRequest | undefined = this.removalRequests.get(key);
    if (request === undefined) {
      const createdRequest: RemoveFriendRequest = {
        friendUid, requestId: util.generateRandomUUID(), expectedFriendshipUpdatedAt: expectedUpdatedAt
      };
      this.removalRequests.set(key, createdRequest);
      request = createdRequest;
    }
    await CloudGateway.callAuthenticated<OperationResponse>('remove-friend', request);
    this.removalRequests.delete(key);
  }

  // 分页读取私信会话列表（含最后一条消息摘要与未读数），并补全好友头像。
  async listConversations(context: common.Context, pageToken: string = '', pageSize: number = 50, options: ReadRequestOptions = {}): Promise<ConversationsResponse> {
    await AuthService.ensureSession(context);
    const request: PageRequest = { pageToken, pageSize };
    const response = await CloudGateway.callAuthenticated<ConversationsResponse>('list-conversations', request, options);
    await Promise.all(response.conversations.map((conversation: ConversationSummary): Promise<void> =>
      this.resolveUserAvatar(context, conversation.friend, options)));
    return response;
  }

  // 分页读取某个会话的消息；分享卡片类消息需要补全封面。
  async listMessages(context: common.Context, request: ListMessagesRequest): Promise<MessagesResponse> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<MessagesResponse>('list-messages', request);
    await Promise.all(response.messages.map(async (message: ChatMessage): Promise<void> => {
      if (message.sharedCard !== undefined) await this.resolveCardPhoto(context, message.sharedCard);
    }));
    return response;
  }

  // 发送一条私信（文字 / 链接 / 卡片），返回服务端保存后的消息。
  async sendMessage(context: common.Context, request: SendMessageRequest): Promise<ChatMessage> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<SendMessageResponse>('send-message', request);
    if (response.message.sharedCard !== undefined) await this.resolveCardPhoto(context, response.message.sharedCard);
    return response.message;
  }

  // 分页读取群聊列表。
  async listGroupConversations(context: common.Context, pageToken: string = '', pageSize: number = 50, options: ReadRequestOptions = {}): Promise<GroupConversationsResponse> {
    await AuthService.ensureSession(context);
    const request: PageRequest = { pageToken, pageSize };
    return CloudGateway.callAuthenticated<GroupConversationsResponse>('list-group-conversations', request, options);
  }

  // 创建群聊（群名 + 初始成员）。
  async createGroupChat(context: common.Context, name: string, memberUids: Array<string>): Promise<CreateGroupChatResponse> {
    await AuthService.ensureSession(context);
    const request: CreateGroupChatRequest = { name, memberUids };
    return CloudGateway.callAuthenticated<CreateGroupChatResponse>('create-group-chat', request);
  }

  // 读取群聊详情与成员，并补全成员头像。
  async groupDetail(context: common.Context, groupId: string): Promise<GroupChatDetailResponse> {
    await AuthService.ensureSession(context);
    const request: GroupIdRequest = { groupId };
    const response = await CloudGateway.callAuthenticated<GroupChatDetailResponse>('get-group-chat', request);
    await Promise.all(response.members.map((member: GroupMemberProfile): Promise<void> =>
      this.resolveUserAvatar(context, member.user)));
    return response;
  }

  // 分页读取群消息；clientVersion=2 表示客户端支持新版消息格式（含卡片与投票等类型）。
  async listGroupMessages(context: common.Context, request: ListGroupMessagesRequest): Promise<GroupMessagesResponse> {
    await AuthService.ensureSession(context);
    request.clientVersion = 2;
    const response = await CloudGateway.callAuthenticated<GroupMessagesResponse>('list-group-messages', request);
    await Promise.all(response.messages.map(async (message: GroupMessage): Promise<void> => {
      await this.resolveUserAvatar(context, message.sender);
      if (message.sharedCard !== undefined) await this.resolveCardPhoto(context, message.sharedCard);
    }));
    return response;
  }

  // 发送一条群消息，返回服务端保存后的消息。
  async sendGroupMessage(context: common.Context, request: SendGroupMessageRequest): Promise<GroupMessage> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<SendGroupMessageResponse>('send-group-message', request);
    await this.resolveUserAvatar(context, response.message.sender);
    if (response.message.sharedCard !== undefined) await this.resolveCardPhoto(context, response.message.sharedCard);
    return response.message;
  }

  // 退出群聊。
  async leaveGroupChat(context: common.Context, groupId: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: GroupIdRequest = { groupId };
    await CloudGateway.callAuthenticated<OperationResponse>('leave-group-chat', request);
  }

  // 群主移除成员。
  async removeGroupMember(context: common.Context, groupId: string, memberUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: RemoveGroupMemberRequest = { groupId, memberUid };
    await CloudGateway.callAuthenticated<OperationResponse>('remove-group-member', request);
  }
}
