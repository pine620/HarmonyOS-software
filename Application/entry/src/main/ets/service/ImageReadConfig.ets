/** Release switches: select once per account session; no per-image HTTP probing. */
export type ImageTransport = 'BATCH' | 'LEGACY';
export const IMAGE_TRANSPORT: ImageTransport = 'BATCH';
export const IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED: boolean = false;
/** Reuse secondary-page data briefly between tab switches. */
export const SECONDARY_DATA_REUSE_MS: number = 30000;
