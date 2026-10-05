export type NotificationKind = 'FRIEND_REQUEST' | 'FRIEND_ACCEPTED' | 'DIRECT_MESSAGE' |
  'GROUP_MESSAGE' | 'CARD_COMMENT' | 'REPLY';

export interface NotificationItem {
  id: string;
  kind: NotificationKind;
  title: string;
  body: string;
  createdAt: number;
  readAt: number;
}

export interface NotificationPageRequest {
  includeComments?: boolean;
  pageToken: string;
  pageSize: number;
}

export interface NotificationIdRequest {
  includeComments?: boolean;
  notificationId: string;
}

export interface NotificationsResponse {
  items: Array<NotificationItem>;
  unreadCount: number;
  nextPageToken: string;
}

export type NotificationRoute = 'friends' | 'friend-chat' | 'group-chat' | 'card' | 'expired';

export interface OpenNotificationResponse {
  route: NotificationRoute;
  targetId: string;
}
