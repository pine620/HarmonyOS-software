'use strict';
// Canonical UserProfile.uid values only; never accept a role or UID from a payload.
function isCardReviewer(uid, env = process.env) {
  const raw = env.SHIKE_CARD_REVIEW_ADMIN_UIDS === undefined ? process.env.SHIKE_CARD_REVIEW_ADMIN_UIDS : env.SHIKE_CARD_REVIEW_ADMIN_UIDS;
  if (!uid || typeof raw !== 'string' || raw.length > 32768) return false;
  try { const values = JSON.parse(raw); return Array.isArray(values) && values.length <= 100 && values.every(value => typeof value === 'string' && value.length > 0 && value.length <= 160) && values.includes(uid); }
  catch (_error) { return false; }
}
module.exports = { isCardReviewer };
