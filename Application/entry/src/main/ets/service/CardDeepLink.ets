import { url } from '@kit.ArkTS';

/**
 * 【文件职责】卡片分享链接 shike://card?cardId=…（用于“碰一碰”分享）。只在 App 内使用，不需要网站或域名关联；
 * 收到链接后先暂存卡片 id，等隐私同意和登录完成后由 Index 打开详情（详情仍会重新向服务端读取并校验权限）。
 */
export const PENDING_SHARED_CARD_ID_KEY: string = 'pendingSharedCardId';
export const PENDING_SHARED_CARD_REVISION_KEY: string = 'pendingSharedCardRevision';

const CARD_ID_PARAMETER: string = 'cardId';

// 卡片 id 只允许字母数字、下划线、短横线，长度 1–160。
function isUsableCardId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,160}$/.test(value);
}

// 生成分享链接。双方设备都必须安装食刻才能打开。
export function cardDeepLink(cardId: string): string {
  const normalized: string = cardId.trim();
  if (!isUsableCardId(normalized)) return '';
  return `shike://card?${CARD_ID_PARAMETER}=${encodeURIComponent(normalized)}`;
}

// 解析分享链接：只接受本应用在 module.json5 中声明的 scheme 与 host，任意其他 host 或路径都会被拒绝，之后才写入全局状态。
export function cardIdFromDeepLink(uri: string): string {
  const normalized: string = uri.trim();
  if (normalized.length === 0 || normalized.length > 2048) return '';
  try {
    const parsed: url.URL = url.URL.parseURL(normalized);
    if (parsed.username.length > 0 || parsed.password.length > 0 || parsed.port.length > 0) return '';
    const appRoute: boolean = parsed.protocol === 'shike:' && parsed.hostname === 'card'
      && (parsed.pathname === '' || parsed.pathname === '/');
    if (!appRoute) return '';
    const values: Array<string> = parsed.params.getAll(CARD_ID_PARAMETER);
    return values.length === 1 && isUsableCardId(values[0]) ? values[0] : '';
  } catch (_error) {
    return '';
  }
}

// AppStorage 在隐私同意与登录完成之前保存收到的链接；只在内存中保存，不持久化。
export function initializeSharedCardEntry(): void {
  if (!AppStorage.has(PENDING_SHARED_CARD_ID_KEY)) AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, '');
  if (!AppStorage.has(PENDING_SHARED_CARD_REVISION_KEY)) AppStorage.setOrCreate(PENDING_SHARED_CARD_REVISION_KEY, 0);
}

// 暂存待打开的卡片 id（格式不合法返回 false）。
export function storePendingSharedCardId(cardId: string): boolean {
  if (!isUsableCardId(cardId)) return false;
  const revision: number = AppStorage.get<number>(PENDING_SHARED_CARD_REVISION_KEY) || 0;
  AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, cardId);
  AppStorage.setOrCreate(PENDING_SHARED_CARD_REVISION_KEY, revision + 1);
  return true;
}

// 解析系统传入的 URI 并暂存（EntryAbility 调用）。
export function storePendingSharedCard(uri: string): boolean {
  return storePendingSharedCardId(cardIdFromDeepLink(uri));
}

// 清除待打开的卡片。
export function clearPendingSharedCard(): void {
  AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, '');
}
