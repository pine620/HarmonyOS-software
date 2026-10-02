/**
 * The App Linking prefix belongs to this application in AppGallery Connect.
 * Keep it in one place: the Harmony Share payload, ordinary system-share
 * fallback, URI declaration, and incoming-link validation must agree on it.
 */
export const CARD_APP_LINK_HOST: string = 'shike.drcn.agconnect.link';
export const CARD_APP_LINK_PATH: string = 'card';
export const PENDING_SHARED_CARD_ID_KEY: string = 'pendingSharedCardId';

const CARD_APP_LINK_BASE: string = `https://${CARD_APP_LINK_HOST}/${CARD_APP_LINK_PATH}`;
const CARD_ID_PARAMETER: string = 'cardId';

function isUsableCardId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,160}$/.test(value);
}

/** Builds the public route only for an existing, opaque FoodCard identifier. */
export function cardAppLink(cardId: string): string {
  const normalized = cardId.trim();
  if (!isUsableCardId(normalized)) return '';
  return `${CARD_APP_LINK_BASE}?${CARD_ID_PARAMETER}=${encodeURIComponent(normalized)}`;
}

/**
 * Reads only the one route this bundle declares. This intentionally rejects
 * arbitrary hosts and paths before placing a value in application-wide state.
 */
export function cardIdFromAppLink(uri: string): string {
  const normalized = uri.trim();
  if (!normalized.startsWith(`${CARD_APP_LINK_BASE}?`)) return '';
  const query: string = normalized.slice(CARD_APP_LINK_BASE.length + 1).split('#')[0];
  const parameters: Array<string> = query.split('&');
  let rawValue: string = '';
  let cardIdCount: number = 0;
  for (const parameter of parameters) {
    const separator: number = parameter.indexOf('=');
    const name: string = separator < 0 ? parameter : parameter.slice(0, separator);
    if (name !== CARD_ID_PARAMETER) continue;
    cardIdCount += 1;
    if (cardIdCount > 1 || separator < 0) return '';
    rawValue = parameter.slice(separator + 1);
  }
  if (cardIdCount !== 1 || rawValue.length === 0) return '';
  try {
    const cardId = decodeURIComponent(rawValue);
    return isUsableCardId(cardId) ? cardId : '';
  } catch (_error) {
    return '';
  }
}

/**
 * AppStorage keeps a received link available while privacy consent and Huawei
 * account sign-in finish. It is intentionally in-memory only, not persisted.
 */
export function storePendingSharedCard(uri: string): boolean {
  const cardId = cardIdFromAppLink(uri);
  if (cardId.length === 0) return false;
  AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, cardId);
  return true;
}

export function clearPendingSharedCard(): void {
  AppStorage.setOrCreate(PENDING_SHARED_CARD_ID_KEY, '');
}
