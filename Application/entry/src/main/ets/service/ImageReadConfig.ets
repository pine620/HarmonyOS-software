/** Release switches: select once per account session; no per-image HTTP probing. */
export type ImageTransport = 'BATCH' | 'LEGACY';
export const IMAGE_TRANSPORT: ImageTransport = 'BATCH';
export const IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED: boolean = false;
/** Reuse secondary-page data briefly between tab switches. */
export const SECONDARY_DATA_REUSE_MS: number = 30000;
/** Pack 3.2: read published covers straight from Cloud Storage (falls back to shike-image). */
export const PUBLIC_COVER_DIRECT_READ_ENABLED: boolean = true;
/** Pack 4.1: guests' first public page comes from the 5-minute home snapshot (prefetch, then Cloud Storage). */
export const HOME_SNAPSHOT_ENABLED: boolean = true;
/** Cloud Storage instance holding public/snapshot/home-v1.json (= SHIKE_STORAGE_BUCKET); empty = default instance. */
export const HOME_SNAPSHOT_BUCKET: string = 'shike-otidx';
/**
 * Pack 3.3: native email users upload card photos straight to Cloud Storage (private/pending/{uid}/) and the
 * media function only verifies + promotes them. This one switch also decides whether Cloud Foundation Kit
 * receives the user's AGC token (needed by the storage rules). false = previous function upload for everyone.
 */
export const CLIENT_DIRECT_UPLOAD_ENABLED: boolean = true;
