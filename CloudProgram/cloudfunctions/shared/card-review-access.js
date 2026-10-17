'use strict';
/**
 * 【文件职责】卡片举报审核员判断：读取环境变量 SHIKE_CARD_REVIEW_ADMIN_UIDS（JSON 字符串数组，最多 100 个业务 UID）。
 * 只接受服务端算出的 canonical UserProfile.uid，绝不接受请求里传来的角色或 UID。
 */
// uid 是否在审核员白名单中。
function isCardReviewer(uid, env = process.env) {
  const raw = env.SHIKE_CARD_REVIEW_ADMIN_UIDS === undefined ? process.env.SHIKE_CARD_REVIEW_ADMIN_UIDS : env.SHIKE_CARD_REVIEW_ADMIN_UIDS;
  if (!uid || typeof raw !== 'string' || raw.length > 32768) return false;
  try { const values = JSON.parse(raw); return Array.isArray(values) && values.length <= 100 && values.every(value => typeof value === 'string' && value.length > 0 && value.length <= 160) && values.includes(uid); }
  catch (_error) { return false; }
}
module.exports = { isCardReviewer };
