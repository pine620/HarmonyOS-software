import { FoodCard } from './CloudContracts';

export type FriendshipState = 'NONE' | 'OUTGOING' | 'INCOMING' | 'FRIEND';
export type ChatMessageKind = 'TEXT' | 'CARD' | 'LINK';
export type GroupMessageKind = 'TEXT' | 'CARD';
export type GroupMemberRole = 'OWNER' | 'MEMBER';

export interface SocialUser {
  uid: string;
  friendCode: string;
  nickname: string;
  avatarUrl: string;
  avatarPath: string;
  avatarBucket: string;
  publishCount: number;
  friendshipState: FriendshipState;
  requestId: string;
}

export function emptySocialUser(): SocialUser {
  return {
    uid: '', friendCode: '', nickname: '食刻好友', avatarUrl: '', avatarPath: '', avatarBucket: '',
    publishCount: 0, friendshipState: 'NONE', requestId: ''
  };
}

export interface FriendRequestItem {
  id: string;
  user: SocialUser;
  createdAt: number;
}

export interface SearchUsersRequest {
  keyword: string;
}

export interface SearchUsersResponse {
  users: Array<SocialUser>;
}

export interface FriendsResponse {
  friends: Array<SocialUser>;
  incomingRequests: Array<FriendRequestItem>;
  outgoingRequests: Array<FriendRequestItem>;
  blockedUsers: Array<SocialUser>;
  nextPageToken: string;
}

export interface FriendProfileRequest {
  friendUid: string;
  pageToken: string;
  pageSize: number;
}

export interface FriendProfileSummary {
  user: SocialUser;
  coverPath: string;
  coverBucket: string;
  coverUrl?: string;
}

export interface FriendProfileResponse {
  profile: FriendProfileSummary;
  cards: Array<FoodCard>;
  nextPageToken: string;
}

export interface PageRequest {
  pageToken: string;
  pageSize: number;
}

export interface SendFriendRequestRequest {
  targetUid: string;
}

export interface RespondFriendRequestRequest {
  requestId: string;
  accept: boolean;
}

export interface RemoveFriendRequest {
  friendUid: string;
}

export interface CancelFriendRequest {
  requestId: string;
}

export interface UserIdRequest {
  targetUid: string;
}

export interface ReportUserRequest {
  targetUid: string;
  reason: string;
}

export interface ConversationSummary {
  id: string;
  friend: SocialUser;
  lastMessageKind: ChatMessageKind;
  lastMessagePreview: string;
  lastMessageAt: number;
  unreadCount: number;
}

export interface ConversationsResponse {
  conversations: Array<ConversationSummary>;
  unreadCount: number;
  nextPageToken: string;
}

export interface ChatMessage {
  id: string;
  conversationId: string;
  senderUid: string;
  recipientUid: string;
  mine: boolean;
  kind: ChatMessageKind;
  text: string;
  link: string;
  cardId: string;
  sharedCard?: FoodCard;
  createdAt: number;
  readAt: number;
}

export interface ListMessagesRequest {
  friendUid: string;
  beforeToken: string;
  pageSize: number;
}

export interface MessagesResponse {
  messages: Array<ChatMessage>;
  nextBeforeToken: string;
}

export interface SendMessageRequest {
  friendUid: string;
  kind: ChatMessageKind;
  text: string;
  link: string;
  cardId: string;
}

export interface SendMessageResponse {
  message: ChatMessage;
}

export interface GroupConversationSummary {
  id: string;
  name: string;
  ownerUid: string;
  memberCount: number;
  lastMessageKind: GroupMessageKind;
  lastMessagePreview: string;
  lastMessageAt: number;
  unreadCount: number;
}

export function emptyGroupConversation(): GroupConversationSummary {
  return {
    id: '', name: '食刻群聊', ownerUid: '', memberCount: 0, lastMessageKind: 'TEXT',
    lastMessagePreview: '', lastMessageAt: 0, unreadCount: 0
  };
}

export interface GroupConversationsResponse {
  groups: Array<GroupConversationSummary>;
  unreadCount: number;
  nextPageToken: string;
}

export interface CreateGroupChatRequest {
  name: string;
  memberUids: Array<string>;
}

export interface CreateGroupChatResponse {
  group: GroupConversationSummary;
}

export interface GroupMemberProfile {
  user: SocialUser;
  role: GroupMemberRole;
  joinedAt: number;
}

export interface GroupChatDetailResponse {
  group: GroupConversationSummary;
  members: Array<GroupMemberProfile>;
}

export interface GroupIdRequest {
  groupId: string;
}

export interface GroupMessage {
  id: string;
  groupId: string;
  sender: SocialUser;
  mine: boolean;
  kind: GroupMessageKind;
  text: string;
  cardId: string;
  sharedCard?: FoodCard;
  createdAt: number;
}

export interface ListGroupMessagesRequest {
  groupId: string;
  beforeToken: string;
  pageSize: number;
}

export interface GroupMessagesResponse {
  messages: Array<GroupMessage>;
  nextBeforeToken: string;
}

export interface SendGroupMessageRequest {
  groupId: string;
  kind: GroupMessageKind;
  text: string;
  cardId: string;
}

export interface SendGroupMessageResponse {
  message: GroupMessage;
}

export interface RemoveGroupMemberRequest {
  groupId: string;
  memberUid: string;
}
