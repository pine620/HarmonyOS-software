// Per-call deadlines (the Cloud Foundation default stays 70 s).
// Card interaction RPCs: a write timeout is an unknown result; the controller recovers it with the same request
// UUID, so the server never applies one tap twice.
export const INTERACTION_WRITE_TIMEOUT_MS: number = 12 * 1000;
export const INTERACTION_READ_TIMEOUT_MS: number = 10 * 1000;
export const NICKNAME_AUTH_TIMEOUT_MS: number = 45 * 1000;
