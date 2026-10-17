/**
 * 【文件职责】系统入口参数的统一处理：跨设备接续（onContinue / onWindowStageRestore）、Push 通知点击、
 * 桌面卡片点击都通过 Want 参数进入 App，这里把它们转换成 AppStorage 中的“待打开目标”（页签 / 卡片 / 好友私信 / 群聊）。
 * Index 页面监听这些键并跳转。接续时只传递最小上下文（路由、id、页签），绝不传递 Token。
 */
import { Want } from '@kit.AbilityKit';

export const ENTRY_ROUTE_PARAMETER: string = 'shikeRoute';
export const ENTRY_CARD_ID_PARAMETER: string = 'shikeCardId';
export const ENTRY_FRIEND_UID_PARAMETER: string = 'shikeFriendUid';
export const ENTRY_GROUP_ID_PARAMETER: string = 'shikeGroupId';
export const ENTRY_TAB_PARAMETER: string = 'shikeTab';

export const PENDING_ENTRY_ROUTE_KEY: string = 'pendingSystemEntryRoute';
export const PENDING_ENTRY_CARD_ID_KEY: string = 'pendingSystemEntryCardId';
export const PENDING_ENTRY_FRIEND_UID_KEY: string = 'pendingSystemEntryFriendUid';
export const PENDING_ENTRY_TAB_KEY: string = 'pendingSystemEntryTab';

export const PENDING_ENTRY_GROUP_ID_KEY: string = 'pendingSystemEntryGroupId';

const CURRENT_ROUTE_KEY: string = 'continuationCurrentRoute';
const CURRENT_CARD_ID_KEY: string = 'continuationCurrentCardId';
const CURRENT_FRIEND_UID_KEY: string = 'continuationCurrentFriendUid';
const CURRENT_TAB_KEY: string = 'continuationCurrentTab';

// 可接续的目标类型：页签 / 卡片详情 / 好友私信。
export type ContinuationRoute = 'tab' | 'card' | 'friend-chat';

// 接续时写入 Want 的快照。
export class ContinuationSnapshot {
  route: ContinuationRoute = 'tab';
  cardId: string = '';
  friendUid: string = '';
  tab: number = 0;
}

// 只接受由字母数字、下划线、短横线组成的不透明 id，防止注入。
function usableOpaqueId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,160}$/.test(value);
}

// 校验路由字符串。
function routeFrom(value: string): ContinuationRoute | undefined {
  if (value === 'tab' || value === 'card' || value === 'friend-chat') return value;
  return undefined;
}

// 从 Want 参数中安全读取字符串。
function parameterString(parameters: Record<string, Object> | undefined, key: string): string {
  if (parameters === undefined) return '';
  const value: Object | undefined = parameters[key];
  return typeof value === 'string' ? value : '';
}

// 从 Want 参数中读取页签序号。
function parameterTab(parameters: Record<string, Object> | undefined): number {
  if (parameters === undefined) return 0;
  const value: Object | undefined = parameters[ENTRY_TAB_PARAMETER];
  if (typeof value === 'number' && Number.isInteger(value)) return value;
  if (typeof value === 'string' && /^[0-4]$/.test(value)) return Number(value);
  return 0;
}

// 读取 AppStorage 中的字符串。
function storedString(key: string): string {
  const value: string | undefined = AppStorage.get<string>(key);
  return value === undefined ? '' : value;
}

// 读取当前页签序号。
function storedTab(): number {
  const value: number | undefined = AppStorage.get<number>(CURRENT_TAB_KEY);
  return value !== undefined && Number.isInteger(value) && value >= 0 && value <= 4 ? value : 0;
}

// 接续 / 系统入口状态（静态类）。
export class ContinuationState {
  // 初始化 AppStorage 中的相关键（EntryAbility.onCreate 调用）。
  static initialize(): void {
    if (!AppStorage.has(PENDING_ENTRY_GROUP_ID_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_GROUP_ID_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_ROUTE_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_CARD_ID_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_CARD_ID_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_FRIEND_UID_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_FRIEND_UID_KEY, '');
    if (!AppStorage.has(PENDING_ENTRY_TAB_KEY)) AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, 0);
    if (!AppStorage.has(CURRENT_ROUTE_KEY)) AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'tab');
    if (!AppStorage.has(CURRENT_CARD_ID_KEY)) AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, '');
    if (!AppStorage.has(CURRENT_FRIEND_UID_KEY)) AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, '');
    if (!AppStorage.has(CURRENT_TAB_KEY)) AppStorage.setOrCreate(CURRENT_TAB_KEY, 0);
  }

  // 记录当前显示的页签（用于接续）。
  static showTab(tab: number): void {
    const safeTab: number = Number.isInteger(tab) && tab >= 0 && tab <= 4 ? tab : 0;
    AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, '');
    AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, '');
    AppStorage.setOrCreate(CURRENT_TAB_KEY, safeTab);
    AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'tab');
  }

  // 记录当前打开的卡片（用于接续）。
  static showCard(cardId: string): void {
    const normalized: string = cardId.trim();
    if (!usableOpaqueId(normalized)) return;
    AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, normalized);
    AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, '');
    AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'card');
  }

  // 记录当前打开的好友私信（用于接续）。
  static showFriend(friendUid: string): void {
    const normalized: string = friendUid.trim();
    if (!usableOpaqueId(normalized)) return;
    AppStorage.setOrCreate(CURRENT_CARD_ID_KEY, '');
    AppStorage.setOrCreate(CURRENT_FRIEND_UID_KEY, normalized);
    AppStorage.setOrCreate(CURRENT_ROUTE_KEY, 'friend-chat');
  }

  // 生成接续快照（EntryAbility.onContinue 调用）。
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
   * 桌面卡片、Push 点击动作与跨设备接续都通过 Want 参数进入。
   * 先写 id，最后写被页面监听的路由键，这样页面永远不会看到“写了一半”的路由。返回 true 表示识别到了有效入口。
   */
  static captureIncomingWant(want: Want): boolean {
    const parameters: Record<string, Object> | undefined = want.parameters;
    const incomingRoute: string = parameterString(parameters, ENTRY_ROUTE_PARAMETER);
    if (incomingRoute === 'notification') {
      // 旧版通知收件箱的点击参数不再触发数据库查询。
      ContinuationState.clearPending();
      AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, 2);
      AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, 'tab');
      return true;
    }
    if (incomingRoute === 'group-chat') {
      const groupId: string = parameterString(parameters, ENTRY_GROUP_ID_PARAMETER).trim();
      if (!usableOpaqueId(groupId)) return false;
      ContinuationState.clearPending();
      AppStorage.setOrCreate(PENDING_ENTRY_GROUP_ID_KEY, groupId);
      AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, 'group-chat');
      return true;
    }
    const route: ContinuationRoute | undefined = routeFrom(incomingRoute);
    if (route === undefined) return false;
    const cardId: string = parameterString(parameters, ENTRY_CARD_ID_PARAMETER).trim();
    const friendUid: string = parameterString(parameters, ENTRY_FRIEND_UID_PARAMETER).trim();
    if (route === 'card' && !usableOpaqueId(cardId)) return false;
    if (route === 'friend-chat' && !usableOpaqueId(friendUid)) return false;
    ContinuationState.clearPending();
    AppStorage.setOrCreate(PENDING_ENTRY_CARD_ID_KEY, route === 'card' ? cardId : '');
    AppStorage.setOrCreate(PENDING_ENTRY_FRIEND_UID_KEY, route === 'friend-chat' ? friendUid : '');
    AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, parameterTab(parameters));
    if (route === 'tab' && parameterTab(parameters) === 2 &&
      parameterString(parameters, 'shikeFriendSection') === 'requests') {
      AppStorage.setOrCreate('requestedFriendSection', 1);
    }
    AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, route);
    return true;
  }

  // 清除所有待打开目标（Index 处理完后调用）。
  static clearPending(): void {
    AppStorage.setOrCreate(PENDING_ENTRY_GROUP_ID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_CARD_ID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_FRIEND_UID_KEY, '');
    AppStorage.setOrCreate(PENDING_ENTRY_TAB_KEY, 0);
    AppStorage.setOrCreate(PENDING_ENTRY_ROUTE_KEY, '');
  }
}
