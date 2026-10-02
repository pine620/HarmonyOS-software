import { Want } from '@kit.AbilityKit';

export const ENTRY_ROUTE_PARAMETER: string = 'shikeRoute';
export const ENTRY_CARD_ID_PARAMETER: string = 'shikeCardId';
export const ENTRY_FRIEND_UID_PARAMETER: string = 'shikeFriendUid';
export const ENTRY_TAB_PARAMETER: string = 'shikeTab';
export const ENTRY_NOTIFICATION_ID_PARAMETER: string = 'shikeNotificationId';

export const PENDING_ENTRY_ROUTE_KEY: string = 'pendingSystemEntryRoute';
export const PENDING_ENTRY_CARD_ID_KEY: string = 'pendingSystemEntryCardId';
export const PENDING_ENTRY_FRIEND_UID_KEY: string = 'pendingSystemEntryFriendUid';
export const PENDING_ENTRY_TAB_KEY: string = 'pendingSystemEntryTab';
export const PENDING_ENTRY_NOTIFICATION_ID_KEY: string = 'pendingSystemEntryNotificationId';

const CURRENT_ROUTE_KEY: string = 'continuationCurrentRoute';
const CURRENT_CARD_ID_KEY: string = 'continuationCurrentCardId';
const CURRENT_FRIEND_UID_KEY: string = 'continuationCurrentFriendUid';
const CURRENT_TAB_KEY: string = 'continuationCurrentTab';

export type ContinuationRoute = 'tab' | 'card' | 'friend-chat';

export class ContinuationSnapshot {
  route: ContinuationRoute = 'tab';
  cardId: string = '';
  friendUid: string = '';
  tab: number = 0;
}

function usableOpaqueId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,160}$/.test(value);
}

function routeFrom(value: string): ContinuationRoute | undefined {
  if (value === 'tab' || value === 'card' || value === 'friend-chat') return value;
  return undefined;
}

function parameterString(parameters: Record<string, Object> | undefined, key: string): string {
  if (parameters === undefined) return '';
  const value: Object | undefined = parameters[key];
  return typeof value === 'string' ? value : '';
}

function parameterTab(parameters: Record<string, Object> | undefined): number {
  if (parameters === undefined) return 0;
  const value: Object | undefined = parameters[ENTRY_TAB_PARAMETER];
  if (typeof value === 'number' && Number.isInteger(value)) return value;
  if (typeof value === 'string' && /^[0-4]$/.test(value)) return Number(value);
  return 0;
}

function storedString(key: string): string {
  const value: string | undefined = AppStorage.get<string>(key);
  return value === undefined ? '' : value;
}

function storedTab(): number {
  const value: number | undefined = AppStorage.get<number>(CURRENT_TAB_KEY);
  return value !== undefined && Number.isInteger(value) && value >= 0 && value <= 4 ? value : 0;
}

export class ContinuationState {
  static initialize(): void {
    if (!AppStorage.has(PENDING_ENTRY_ROUTE_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_CARD_ID_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_CARD_ID_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_FRIEND_UID_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_FRIEND_UID_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_TAB_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, 0);
    if (!AppStorage.has(PENDING_ENTRY_NOTIFICATION_ID_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_NOTIFICATION_ID_KEY, '');
    if (!AppStorage.has(CURRENT_ROUTE_KEY)) AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'tab');
    if (!AppStorage.has(CURRENT_CARD_ID_KEY)) AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, '');
    if (!AppStorage.has(CURRENT_FRIEND_UID_KEY)) AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, '');
    if (!AppStorage.has(CURRENT_TAB_KEY)) AppStorage.setOrCreate(CURRENT_TAB_KEY, 0);
  }

  static showTab(tab: number): void {
    const safeTab: number = Number.isInteger(tab) && tab >= 0 && tab <= 4 ? tab : 0;
    AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, '');
    AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, '');
    AppStorage.setOrCreate(CURRENT_TAB_KEY, safeTab);
    AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'tab');
  }

  static showCard(cardId: string): void {
    const normalized: string = cardId.trim();
    if (!usableOpaqueId(normalized)) return;
    AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, normalized);
    AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, '');
    AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'card');
  }

  static showFriend(friendUid: string): void {
    const normalized: string = friendUid.trim();
    if (!usableOpaqueId(normalized)) return;
    AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, '');
    AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, normalized);
    AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'friend-chat');
  }

  static snapshot(): ContinuationSnapshot {
    const snapshot = new ContinuationSnapshot();
    const route: ContinuationRoute | undefined = routeFrom(storedString(CURRENT_ROUTE_KEY));
    snapshot.route = route === undefined ? 'tab' : route;
    snapshot.cardId = storedString(CURRENT_CARD_ID_KEY);
    snapshot.friendUid = storedString(CURRENT_FRIEND_UID_KEY);
    snapshot.tab = storedTab();
    if (snapshot.route === 'card' && !usableOpaqueId(snapshot.cardId)) snapshot.route = 'tab';
    if (snapshot.route === 'friend-chat' && !usableOpaqueId(snapshot.friendUid)) snapshot.route = 'tab';
    return snapshot;
  }

  /**
   * Service cards, Push Kit click actions and continuation all enter through
   * Want parameters. Write identifiers first and the watched route last so
   * the page never observes a half-written route.
   */
  static captureIncomingWant(want: Want): boolean {
    const parameters: Record<string, Object> | undefined = want.parameters;
    const incomingRoute: string = parameterString(parameters, ENTRY_ROUTE_PARAMETER);
    if (incomingRoute === 'notification') {
      const notificationId: string = parameterString(parameters, ENTRY_NOTIFICATION_ID_PARAMETER).trim();
      if (!/^[0-9a-f]{64}$/.test(notificationId)) return false;
      AppStorage.setOrCreate(PENDING_ENTRY_NOTIFICATION_ID_KEY, notificationId);
      AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, incomingRoute);
      return true;
    }
    const route: ContinuationRoute | undefined = routeFrom(incomingRoute);
    if (route === undefined) return false;
    const cardId: string = parameterString(parameters, ENTRY_CARD_ID_PARAMETER).trim();
    const friendUid: string = parameterString(parameters, ENTRY_FRIEND_UID_PARAMETER).trim();
    if (route === 'card' && !usableOpaqueId(cardId)) return false;
    if (route === 'friend-chat' && !usableOpaqueId(friendUid)) return false;
    AppStorage.setOrCreate(PENDING_ENTRY_CARD_ID_KEY, route === 'card' ? cardId : '');
    AppStorage.setOrCreate(PENDING_ENTRY_FRIEND_UID_KEY, route === 'friend-chat' ? friendUid : '');
    AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, parameterTab(parameters));
    AppStorage.setOrCreate(PENDING_ENTRY_NOTIFICATION_ID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, route);
    return true;
  }

  static clearPending(): void {
    AppStorage.setOrCreate(PENDING_ENTRY_CARD_ID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_FRIEND_UID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, 0);
    AppStorage.setOrCreate(PENDING_ENTRY_NOTIFICATION_ID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, '');
  }
}
