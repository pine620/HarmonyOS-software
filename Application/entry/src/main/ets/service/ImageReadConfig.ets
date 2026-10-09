/** Release switches: select once per account session; no per-image HTTP probing. */
export type ImageTransport = 'BATCH' | 'LEGACY';
export const IMAGE_TRANSPORT: ImageTransport = 'BATCH';
export const IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED: boolean = false;
