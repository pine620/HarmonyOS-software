/**
 * 【文件职责】好友、私信、群聊相关的数据结构（FriendRepository 与社交页面使用，云端由 shike-social 提供）。
 */
import { FoodCard } from './CloudContracts';

// 与对方的关系：无 / 我发出申请 / 对方发来申请 / 已是好友。
export type FriendshipState = 'NONE' | 'OUTGOING' | 'INCOMING' | 'FRIEND';
// 私信消息类型：文字 / 卡片 / 链接。
export type ChatMessageKind = 'TEXT' | 'CARD' | 'LINK';
// 群消息类型：文字 / 卡片 / 选餐投票。
export type GroupMessageKind = 'TEXT' | 'CARD' | 'MEAL_POLL';
// 群成员角色：群主 / 成员。
export type GroupMemberRole = 'OWNER' | 'MEMBER';

// 社交场景中的用户（含关系状态与头像存储位置）。
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
  friendshipUpdatedAt?: number;
}

// 空用户占位（列表初始化用）。
export function emptySocialUser(): SocialUser {
  return {
    uid: '', friendCode: '', nickname: '食刻好友', avatarUrl: '', avatarPath: '', avatarBucket: '',
    publishCount: 0, friendshipState: 'NONE', requestId: ''
  };
}

// 一条好友申请。
export interface FriendRequestItem {
  id: string;
  user: SocialUser;
  createdAt: number;
}

// 用户搜索请求 / 响应。
export interface SearchUsersRequest {
  keyword: string;
}

export interface SearchUsersResponse {
  users: Array<SocialUser>;
}

// 好友列表响应：好友、收到/发出的申请、黑名单。
export interface FriendsResponse {
  friends: Array<SocialUser>;
  incomingRequests: Array<FriendRequestItem>;
  outgoingRequests: Array<FriendRequestItem>;
  blockedUsers: Array<SocialUser>;
  nextPageToken: string;
}

// 好友主页请求（分页读取对方卡片）。
export interface FriendProfileRequest {
  friendUid: string;
  pageToken: string;
  pageSize: number;
}

// 好友主页资料摘要。
export interface FriendProfileSummary {
  user: SocialUser;
  coverPath: string;
  coverBucket: string;
  coverUrl?: string;
}

// 好友主页响应。
export interface FriendProfileResponse {
  profile: FriendProfileSummary;
  cards: Array<FoodCard>;
  nextPageToken: string;
}

// 通用分页请求。
export interface PageRequest {
  pageToken: string;
  pageSize: number;
}

// 发送好友申请。
export interface SendFriendRequestRequest {
  targetUid: string;
}

// 处理好友申请（expectedCreatedAt 确认处理的是界面上那一条）。
export interface RespondFriendRequestRequest {
  requestId: string;
  accept: boolean;
  expectedCreatedAt?: number;
}

// 解除好友请求（requestId 幂等 + 期望关系版本）。
export interface RemoveFriendRequest {
  friendUid: string;
  requestId?: string;
  expectedFriendshipUpdatedAt?: number;
}

// 撤回好友申请。
export interface CancelFriendRequest {
  requestId: string;
  expectedCreatedAt?: number;
}

// 只含目标用户 id 的请求。
export interface UserIdRequest {
  targetUid: string;
}

// 私信会话摘要（最后一条消息、未读数）。
export interface ConversationSummary {
  id: string;
  friend: SocialUser;
  lastMessageKind: ChatMessageKind;
  lastMessagePreview: string;
  lastMessageAt: number;
  unreadCount: number;
}

// 会话列表响应。
export interface ConversationsResponse {
  conversations: Array<ConversationSummary>;
  unreadCount: number;
  nextPageToken: string;
}

// 一条私信。
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

// 私信分页请求。
export interface ListMessagesRequest {
  friendUid: string;
  beforeToken: string;
  pageSize: number;
}

// 私信分页响应。
export interface MessagesResponse {
  messages: Array<ChatMessage>;
  nextBeforeToken: string;
}

// 发送私信请求。
export interface SendMessageRequest {
  friendUid: string;
  kind: ChatMessageKind;
  text: string;
  link: string;
  cardId: string;
}

// 发送私信响应。
export interface SendMessageResponse {
  message: ChatMessage;
}

// 群聊摘要。
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

// 空群聊占位。
export function emptyGroupConversation(): GroupConversationSummary {
  return {
    id: '', name: '食刻群聊', ownerUid: '', memberCount: 0, lastMessageKind: 'TEXT',
    lastMessagePreview: '', lastMessageAt: 0, unreadCount: 0
  };
}

// 群聊列表响应。
export interface GroupConversationsResponse {
  groups: Array<GroupConversationSummary>;
  unreadCount: number;
  nextPageToken: string;
}

// 创建群聊请求 / 响应。
export interface CreateGroupChatRequest {
  name: string;
  memberUids: Array<string>;
}

export interface CreateGroupChatResponse {
  group: GroupConversationSummary;
}

// 群成员资料。
export interface GroupMemberProfile {
  user: SocialUser;
  role: GroupMemberRole;
  joinedAt: number;
}

// 群聊详情响应。
export interface GroupChatDetailResponse {
  group: GroupConversationSummary;
  members: Array<GroupMemberProfile>;
}

// 只含群 id 的请求。
export interface GroupIdRequest {
  groupId: string;
}

// 一条群消息。
export interface GroupMessage {
  referenceId?: string;
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

// 群消息分页请求。
export interface ListGroupMessagesRequest {
  clientVersion?: number;
  groupId: string;
  beforeToken: string;
  pageSize: number;
}

// 群消息分页响应。
export interface GroupMessagesResponse {
  messages: Array<GroupMessage>;
  nextBeforeToken: string;
}

// 发送群消息请求 / 响应。
export interface SendGroupMessageRequest {
  groupId: string;
  kind: GroupMessageKind;
  text: string;
  cardId: string;
}

export interface SendGroupMessageResponse {
  message: GroupMessage;
}

// 移除群成员请求。
export interface RemoveGroupMemberRequest {
  groupId: string;
  memberUid: string;
}
