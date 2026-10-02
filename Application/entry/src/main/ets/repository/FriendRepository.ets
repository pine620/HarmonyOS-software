import { common } from '@kit.AbilityKit';
import { CardPhoto, FoodCard, OperationResponse } from '../model/CloudContracts';
import {
  CancelFriendRequest, ChatMessage, ConversationSummary, ConversationsResponse, CreateGroupChatRequest,
  CreateGroupChatResponse, FriendProfileRequest, FriendProfileResponse, FriendRequestItem, FriendsResponse,
  GroupChatDetailResponse, GroupConversationsResponse,
  GroupIdRequest, GroupMemberProfile, GroupMessage, GroupMessagesResponse, ListGroupMessagesRequest, ListMessagesRequest,
  MessagesResponse, PageRequest, RemoveFriendRequest, RemoveGroupMemberRequest, RespondFriendRequestRequest,
  SearchUsersRequest, SearchUsersResponse, SendFriendRequestRequest, SendGroupMessageRequest,
  ReportUserRequest, SendGroupMessageResponse, SendMessageRequest, SendMessageResponse, SocialUser, UserIdRequest
} from '../model/FriendModels';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';
import { PhotoUploadService } from '../service/PhotoUploadService';

export class FriendRepository {
  private async resolveUserAvatar(context: common.Context, user: SocialUser): Promise<void> {
    if (user.avatarPath.length === 0 || user.avatarBucket.length === 0) {
      user.avatarUrl = '';
      return;
    }
    try {
      user.avatarUrl = await PhotoUploadService.getDownloadUrl(context, user.avatarBucket, user.avatarPath);
    } catch (_error) {
      user.avatarUrl = '';
    }
  }

  private async resolveCardPhoto(context: common.Context, card: FoodCard): Promise<void> {
    if (card.photoPath.length === 0 || card.photoBucket.length === 0) {
      card.photoUrl = '';
      return;
    }
    try {
      card.photoUrl = await PhotoUploadService.getDownloadUrl(context, card.photoBucket, card.photoPath);
    } catch (_error) {
      card.photoUrl = '';
    }
    const photos: Array<CardPhoto> = card.photos === undefined ? [] : card.photos;
    if (photos.length > 0) photos[0].url = card.photoUrl;
  }

  private async resolveRequestUsers(context: common.Context, requests: Array<FriendRequestItem>): Promise<void> {
    await Promise.all(requests.map((request: FriendRequestItem): Promise<void> =>
      this.resolveUserAvatar(context, request.user)));
  }

  async search(context: common.Context, keyword: string): Promise<Array<SocialUser>> {
    await AuthService.ensureSession(context);
    const request: SearchUsersRequest = { keyword };
    const response = await CloudGateway.callAuthenticated<SearchUsersResponse>('search-users', request);
    await Promise.all(response.users.map((user: SocialUser): Promise<void> => this.resolveUserAvatar(context, user)));
    return response.users;
  }

  async listFriends(context: common.Context, pageToken: string = '', pageSize: number = 50): Promise<FriendsResponse> {
    await AuthService.ensureSession(context);
    const request: PageRequest = { pageToken, pageSize };
    const response = await CloudGateway.callAuthenticated<FriendsResponse>('list-friends', request);
    await Promise.all(response.friends.map((user: SocialUser): Promise<void> => this.resolveUserAvatar(context, user)));
    await this.resolveRequestUsers(context, response.incomingRequests);
    await this.resolveRequestUsers(context, response.outgoingRequests);
    await Promise.all(response.blockedUsers.map((user: SocialUser): Promise<void> => this.resolveUserAvatar(context, user)));
    return response;
  }

  async friendProfile(context: common.Context, friendUid: string, pageToken: string = '',
    pageSize: number = 12): Promise<FriendProfileResponse> {
    await AuthService.ensureSession(context);
    const request: FriendProfileRequest = { friendUid, pageToken, pageSize };
    const response = await CloudGateway.callAuthenticated<FriendProfileResponse>('get-friend-profile', request);
    await this.resolveUserAvatar(context, response.profile.user);
    response.profile.coverUrl = '';
    if (response.profile.coverPath.length > 0 && response.profile.coverBucket.length > 0) {
      try {
        response.profile.coverUrl = await PhotoUploadService.getDownloadUrl(context,
          response.profile.coverBucket, response.profile.coverPath);
      } catch (_error) {
        response.profile.coverUrl = '';
      }
    }
    await Promise.all(response.cards.map((card: FoodCard): Promise<void> => this.resolveCardPhoto(context, card)));
    return response;
  }

  async sendRequest(context: common.Context, targetUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: SendFriendRequestRequest = { targetUid };
    await CloudGateway.callAuthenticated<OperationResponse>('send-friend-request', request);
  }

  async respondRequest(context: common.Context, requestId: string, accept: boolean): Promise<void> {
    await AuthService.ensureSession(context);
    const request: RespondFriendRequestRequest = { requestId, accept };
    await CloudGateway.callAuthenticated<OperationResponse>('respond-friend-request', request);
  }

  async cancelRequest(context: common.Context, requestId: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: CancelFriendRequest = { requestId };
    await CloudGateway.callAuthenticated<OperationResponse>('cancel-friend-request', request);
  }

  async blockUser(context: common.Context, targetUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: UserIdRequest = { targetUid };
    await CloudGateway.callAuthenticated<OperationResponse>('block-user', request);
  }

  async unblockUser(context: common.Context, targetUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: UserIdRequest = { targetUid };
    await CloudGateway.callAuthenticated<OperationResponse>('unblock-user', request);
  }

  async reportUser(context: common.Context, targetUid: string, reason: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: ReportUserRequest = { targetUid, reason };
    await CloudGateway.callAuthenticated<OperationResponse>('report-user', request);
  }

  async removeFriend(context: common.Context, friendUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: RemoveFriendRequest = { friendUid };
    await CloudGateway.callAuthenticated<OperationResponse>('remove-friend', request);
  }

  async listConversations(context: common.Context, pageToken: string = '', pageSize: number = 50): Promise<ConversationsResponse> {
    await AuthService.ensureSession(context);
    const request: PageRequest = { pageToken, pageSize };
    const response = await CloudGateway.callAuthenticated<ConversationsResponse>('list-conversations', request);
    await Promise.all(response.conversations.map((conversation: ConversationSummary): Promise<void> =>
      this.resolveUserAvatar(context, conversation.friend)));
    return response;
  }

  async listMessages(context: common.Context, request: ListMessagesRequest): Promise<MessagesResponse> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<MessagesResponse>('list-messages', request);
    await Promise.all(response.messages.map(async (message: ChatMessage): Promise<void> => {
      if (message.sharedCard !== undefined) await this.resolveCardPhoto(context, message.sharedCard);
    }));
    return response;
  }

  async sendMessage(context: common.Context, request: SendMessageRequest): Promise<ChatMessage> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<SendMessageResponse>('send-message', request);
    if (response.message.sharedCard !== undefined) await this.resolveCardPhoto(context, response.message.sharedCard);
    return response.message;
  }

  async listGroupConversations(context: common.Context, pageToken: string = '', pageSize: number = 50): Promise<GroupConversationsResponse> {
    await AuthService.ensureSession(context);
    const request: PageRequest = { pageToken, pageSize };
    return CloudGateway.callAuthenticated<GroupConversationsResponse>('list-group-conversations', request);
  }

  async createGroupChat(context: common.Context, name: string, memberUids: Array<string>): Promise<CreateGroupChatResponse> {
    await AuthService.ensureSession(context);
    const request: CreateGroupChatRequest = { name, memberUids };
    return CloudGateway.callAuthenticated<CreateGroupChatResponse>('create-group-chat', request);
  }

  async groupDetail(context: common.Context, groupId: string): Promise<GroupChatDetailResponse> {
    await AuthService.ensureSession(context);
    const request: GroupIdRequest = { groupId };
    const response = await CloudGateway.callAuthenticated<GroupChatDetailResponse>('get-group-chat', request);
    await Promise.all(response.members.map((member: GroupMemberProfile): Promise<void> =>
      this.resolveUserAvatar(context, member.user)));
    return response;
  }

  async listGroupMessages(context: common.Context, request: ListGroupMessagesRequest): Promise<GroupMessagesResponse> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<GroupMessagesResponse>('list-group-messages', request);
    await Promise.all(response.messages.map(async (message: GroupMessage): Promise<void> => {
      await this.resolveUserAvatar(context, message.sender);
      if (message.sharedCard !== undefined) await this.resolveCardPhoto(context, message.sharedCard);
    }));
    return response;
  }

  async sendGroupMessage(context: common.Context, request: SendGroupMessageRequest): Promise<GroupMessage> {
    await AuthService.ensureSession(context);
    const response = await CloudGateway.callAuthenticated<SendGroupMessageResponse>('send-group-message', request);
    await this.resolveUserAvatar(context, response.message.sender);
    if (response.message.sharedCard !== undefined) await this.resolveCardPhoto(context, response.message.sharedCard);
    return response.message;
  }

  async leaveGroupChat(context: common.Context, groupId: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: GroupIdRequest = { groupId };
    await CloudGateway.callAuthenticated<OperationResponse>('leave-group-chat', request);
  }

  async removeGroupMember(context: common.Context, groupId: string, memberUid: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: RemoveGroupMemberRequest = { groupId, memberUid };
    await CloudGateway.callAuthenticated<OperationResponse>('remove-group-member', request);
  }
}
