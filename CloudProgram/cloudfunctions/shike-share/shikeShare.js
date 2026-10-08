'use strict';
const crypto = require('crypto');
// The packaging script rebases this import into the standalone HTTP artifact.
const {readShareCard, readShareMedia} = require('../shike-service/runtime');
const buckets = new Map();
let concurrent = 0;
function header(headers, name) { const key = Object.keys(headers || {}).find(k => k.toLowerCase() === name); return key ? String(headers[key]) : ''; }
function settings(env) {
  const configured = String(env.SHIKE_SHARE_ALLOWED_ORIGINS || '').split(',').map(x => x.trim()).filter(Boolean);
  if (!configured.length || configured.length > 10 || configured.some(x => { try { const u = new URL(x); return u.protocol !== 'https:' || u.origin !== x; } catch (_) { return true; } })) return null;
  if (String(env.SHIKE_SHARE_HTTP_VERIFIED) !== 'true' || String(env.SHIKE_SHARE_GATEWAY_RATE_LIMIT_VERIFIED) !== 'true') return null;
  return new Set(configured);
}
function reply(statusCode, value, origin = '', binary = false) {
  const headers = {'Content-Type': binary ? 'image/jpeg' : 'application/json; charset=utf-8', 'Cache-Control': 'no-store, max-age=0', 'Pragma': 'no-cache', 'Expires': '0', 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'", 'Referrer-Policy': 'no-referrer', 'Vary': 'Origin'};
  if (origin) Object.assign(headers, {'Access-Control-Allow-Origin': origin, 'Access-Control-Allow-Methods': 'GET, OPTIONS', 'Access-Control-Allow-Headers': 'Accept', 'Access-Control-Max-Age': '0'});
  const body = binary ? value : JSON.stringify(value);
  if (!binary && Buffer.byteLength(body) > 32768) return reply(503, {code: 'CONTENT_UNAVAILABLE'}, origin);
  return {statusCode, headers, body, isBase64Encoded: binary};
}
function limited(key, maximum, now) {
  const window = Math.floor(now / 60000);
  if (buckets.size > 10000) for (const [k, row] of buckets) if (row.window !== window) buckets.delete(k);
  const old = buckets.get(key);
  const row = old && old.window === window ? old : {window, count: 0}; row.count++; buckets.set(key, row);
  return row.count > maximum || buckets.size > 10000;
}
async function handle(event, context) {
  const env = {...process.env, ...(context && context.env || {})};
  const origins = settings(env);
  if (!origins) return reply(503, {code: 'SHARE_NOT_READY'});
  if (!event || typeof event !== 'object' || Array.isArray(event)) return reply(400, {code: 'INVALID_REQUEST'});
  try { if (Buffer.byteLength(JSON.stringify(event)) > 4096) return reply(413, {code: 'REQUEST_TOO_LARGE'}); } catch (_) { return reply(400, {code: 'INVALID_REQUEST'}); }
  const headers = event.headers || {};
  const origin = header(headers, 'origin');
  if (origin && !origins.has(origin)) return reply(403, {code: 'ORIGIN_DENIED'});
  const method = String(event.httpMethod || event.requestContext && event.requestContext.http && event.requestContext.http.method || '').toUpperCase();
  if (!['GET', 'OPTIONS'].includes(method)) return reply(405, {code: 'METHOD_NOT_ALLOWED'}, origin);
  if (event.body !== undefined && event.body !== null && event.body !== '') return reply(400, {code: 'INVALID_REQUEST'}, origin);
  const path = String(event.path || event.rawPath || '');
  if (path.length > 512) return reply(400, {code: 'INVALID_REQUEST'}, origin);
  // The gateway maps its public URL onto /api/card/:cardId and /api/media/:cardId.
  const match = /^\/api\/(card|media)\/([A-Za-z0-9_-]{1,160})$/.exec(path);
  if (!match) return reply(404, {code: 'CONTENT_UNAVAILABLE'}, origin);
  const remote = String(event.requestContext && (event.requestContext.identity && event.requestContext.identity.sourceIp || event.requestContext.http && event.requestContext.http.sourceIp) || 'unknown');
  const key = crypto.createHash('sha256').update(remote).digest('hex');
  if (limited('all', 600, Date.now()) || limited(key, 60, Date.now()) || concurrent >= 8) return reply(429, {code: 'RATE_LIMITED'}, origin);
  if (method === 'OPTIONS') { const response = reply(204, {}, origin); response.body = ''; return response; }
  concurrent++;
  try {
    const payload = {cardId: match[2]};
    if (match[1] === 'card') return reply(200, await readShareCard(payload, env), origin);
    const media = await readShareMedia(payload, env);
    if (media.mimeType !== 'image/jpeg' || !Number.isSafeInteger(media.byteSize) || media.byteSize < 1 || media.byteSize > 2097152 || typeof media.dataBase64 !== 'string') return reply(404, {code: 'CONTENT_UNAVAILABLE'}, origin);
    const bytes = Buffer.from(media.dataBase64, 'base64');
    if (bytes.length !== media.byteSize || bytes[0] !== 0xff || bytes[1] !== 0xd8) return reply(404, {code: 'CONTENT_UNAVAILABLE'}, origin);
    return reply(200, bytes.toString('base64'), origin, true);
  } catch (error) {
    // Missing, removed, private and inactive-owner records use the same response.
    const unavailable = ['CONTENT_UNAVAILABLE', 'CONTENT_ACCESS_DENIED', 'ACCOUNT_INACTIVE', 'NOT_FOUND'].includes(error && error.code);
    return reply(unavailable ? 404 : 503, {code: 'CONTENT_UNAVAILABLE'}, origin);
  } finally { concurrent--; }
}
exports.handler = async (event, context, callback) => { const response = await handle(event, context); if (typeof callback === 'function') callback(response); return response; };
