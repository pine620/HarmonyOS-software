import { url } from '@kit.ArkTS';

// App-only route for knock sharing; no website or domain association is required.
export const PENDING_SHARED_CARD_ID_KEY: string = 'pendingSharedCardId';
export const PENDING_SHARED_CARD_REVISION_KEY: string = 'pendingSharedCardRevision';

const CARD_ID_PARAMETER: string = 'cardId';

function isUsableCardId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,160}$/.test(value);
}

/** Both devices must have 食刻 installed to open this route. */
export function cardDeepLink(cardId: string): string {
  const normalized: string = cardId.trim();
  if (!isUsableCardId(normalized)) return '';
  return `shike://card?${CARD_ID_PARAMETER}=${encodeURIComponent(normalized)}`;
}

/**
 * Reads only the one route this bundle declares. This intentionally rejects
 * arbitrary hosts and paths before placing a value in application-wide state.
 */
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

/**
 * AppStorage keeps a received link available while privacy consent and Huawei
 * account sign-in finish. It is intentionally in-memory only, not persisted.
 */
export function initializeSharedCardEntry(): void {
  if (!AppStorage.has(PENDING_SHARED_CARD_ID_KEY)) AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, '');
  if (!AppStorage.has(PENDING_SHARED_CARD_REVISION_KEY)) AppStorage.setOrCreate(PENDING_SHARED_CARD_REVISION_KEY, 0);
}

export function storePendingSharedCardId(cardId: string): boolean {
  if (!isUsableCardId(cardId)) return false;
  const revision: number = AppStorage.get<number>(PENDING_SHARED_CARD_REVISION_KEY) || 0;
  AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, cardId);
  AppStorage.setOrCreate(PENDING_SHARED_CARD_REVISION_KEY, revision + 1);
  return true;
}

export function storePendingSharedCard(uri: string): boolean {
  return storePendingSharedCardId(cardIdFromDeepLink(uri));
}

export function clearPendingSharedCard(): void {
  AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, '');
}
