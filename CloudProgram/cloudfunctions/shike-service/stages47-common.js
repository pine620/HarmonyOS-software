/**
 * 【文件职责】阶段 4–7 业务模块（收藏、互动、榜单、今日吃什么、群投票、用户主页等）共用的工具：
 * 错误构造、哈希、开关读取、参数校验（id / uuid / 整数 / 版本）、分页游标的 HMAC 签名与校验、按时间戳的稳定分页、坐标与距离。
 * 【游标签名】游标里带有查询条件的签名与时间戳，被篡改或过期（与查询不匹配）时拒绝，密钥来自 SHIKE_CURSOR_SIGNING_KEY。
 */
'use strict';
const crypto = require('crypto');
const { AsyncLocalStorage } = require('async_hooks');
// 每个请求的环境变量上下文（游标签名需要读取密钥）。
const cursorScope = new AsyncLocalStorage();
const withCursorContext = (env, action) => cursorScope.run(env || process.env, action);
// 游标签名密钥（由 SHIKE_CURSOR_SIGNING_KEY 派生）。
function cursorKey() {
  const env = cursorScope.getStore() || process.env;
  const configured = key => env[key] === undefined ? process.env[key] || '' : env[key];
  const secret = String(configured('SHIKE_CURSOR_SIGNING_KEY') || configured('SHIKE_MEDIA_INTERNAL_KEY') || '').trim();
  if (Buffer.byteLength(secret) < 32) throw fail('分页签名配置尚未就绪。', 'CONFIGURATION_REQUIRED');
  // 按用途做域分离派生，因此可以直接复用现有的内部密钥上线。
  return crypto.createHmac('sha256', secret).update('shike-pagination-v1').digest();
}
// 错误 / 哈希 / 开关读取的简写。
const { accessError, dateMillis, currentVisibility } = require('./shared/content-policy');
const fail = (message, code = 'VALIDATION_ERROR') => accessError(message, code);
const hash = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const flag = (env, key) => String(env[key] === undefined ? process.env[key] || '' : env[key]) === 'true';
// 校验不透明 id。
function id(value) { if (typeof value !== 'string' || !/^[A-Za-z0-9:_-]{1,160}$/.test(value)) throw fail('标识无效。'); return value; }
// 校验 UUID。
function uuid(value) { if(typeof value!=='string'||! /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw fail('请求标识必须为 UUID。');return value.toLowerCase(); }
// 校验整数范围。
function int(value, min, max) { if (!Number.isSafeInteger(value) || value < min || value > max) throw fail('数值无效。'); return value; }
// 校验期望版本与当前行一致。
function version(value, row) { if (int(value,0,Number.MAX_SAFE_INTEGER) !== Number(row && row.version || 0)) throw fail('记录已变化，请刷新后重试。','STALE_VERSION'); }
// 解析并校验分页游标（签名、查询条件签名、有效期）。
function token(value, signature) {
  if (!value) return null;
  if (typeof value !== 'string' || value.length > 65601 || !/^[A-Za-z0-9_-]+\.[0-9a-f]{64}$/.test(value)) throw fail('分页失效，请刷新。','CURSOR_STALE');
  const [body, mac] = value.split('.');
  const expected = crypto.createHmac('sha256', cursorKey()).update(body).digest();
  if (!crypto.timingSafeEqual(expected, Buffer.from(mac, 'hex'))) throw fail('分页失效，请刷新。','CURSOR_STALE');
  let parsed; try { parsed=JSON.parse(Buffer.from(body,'base64url').toString()); } catch (_) { throw fail('分页失效，请刷新。','CURSOR_STALE'); }
  if (!parsed || parsed.signature !== signature || !Number.isSafeInteger(parsed.at) || parsed.at > Date.now() || Date.now()-parsed.at>900000) throw fail('分页失效，请刷新。','CURSOR_STALE');
  return parsed;
}
// 生成分页游标。
function encode(signature, at, state) {
  const body = Buffer.from(JSON.stringify({...state,signature,at})).toString('base64url');
  if (body.length > 65536) throw fail('分页快照过大，请刷新。', 'CURSOR_STALE');
  return body + '.' + crypto.createHmac('sha256', cursorKey()).update(body).digest('hex');
}
// 对没有主键作为并列排序字段的“时间戳倒序”索引也能分页：只重新读取边界时间戳那一批，并排除其中已经返回过的 id；绝不使用会因前面记录消失而错位的 offset。
async function timestampPage(query, saved, at, size, primary, stamp, asDate = false, ascending = false) {
  const seen = saved ? saved.seen : [];
  const frontier = saved ? saved.lastStamp : ascending ? 0 : at;
  if (!Number.isSafeInteger(frontier) || frontier < 0 || frontier > at || !Array.isArray(seen) || seen.length > 400 ||
    new Set(seen).size !== seen.length || seen.some(value=>typeof value!=='string'||value.length>160)) throw fail('分页失效，请刷新。','CURSOR_STALE');
  const previous = new Set(seen), limit = size + seen.length;
  const edge = asDate ? new Date(frontier) : frontier;
  const bounded = ascending ? query.greaterThanOrEqualTo(stamp, edge).lessThanOrEqualTo(stamp, asDate ? new Date(at) : at) : query.lessThanOrEqualTo(stamp, edge);
  const rows = await bounded.limit(limit).get();
  const remaining = rows.filter(row=>dateMillis(row[stamp])!==frontier||!previous.has(String(row[primary])));
  const items = remaining.slice(0,size), last = items[items.length-1];
  if (!last) return {rows:[],next:null};
  const lastStamp = dateMillis(last[stamp]);
  if (lastStamp===null) throw fail('分页时间无效，请刷新。','INVALID_STATE');
  const ids = items.filter(row=>dateMillis(row[stamp])===lastStamp).map(row=>String(row[primary]));
  const nextSeen = [...new Set([...(lastStamp===frontier?seen:[]),...ids])];
  if (nextSeen.length>400) throw fail('同一时间的记录过多，请联系管理员核对数据。','CURSOR_STALE');
  return {rows:items,next:remaining.length>size||rows.length===limit?{lastStamp,seen:nextSeen}:null};
}
// 店铺是否有可信坐标（已核验的店铺才参与地图与距离）。
function coordinate(row) { return row && ['VERIFIED_PROVIDER','USER_CONFIRMED_APPROVED'].includes(row.verificationStatus) && row.coordinateSystem==='GCJ02' && Number.isSafeInteger(row.latitudeE6) && Math.abs(row.latitudeE6)<=90000000 && Number.isSafeInteger(row.longitudeE6) && Math.abs(row.longitudeE6)<=180000000; }
// 两点间距离（米，球面近似）。
function distance(lat,lon,row) { const rad=Math.PI/180,a=(row.latitudeE6/1e6-lat)*rad,b=(row.longitudeE6/1e6-lon)*rad;const h=Math.sin(a/2)**2+Math.cos(lat*rad)*Math.cos(row.latitudeE6/1e6*rad)*Math.sin(b/2)**2;return 6371000*2*Math.asin(Math.min(1,Math.sqrt(h))); }
// 在复合排序的查询上加入“排在某行之后”的条件（游标分页）。
function afterTuple(query,fields,row){
 query.and().beginGroup();
 for(let branch=0;branch<fields.length;branch++){
   if(branch)query.or();query.beginGroup();
   for(let prefix=0;prefix<branch;prefix++)query.equalTo(fields[prefix][0],row[fields[prefix][0]]);
   const [field,direction]=fields[branch];
   if(direction==='ASC')query.greaterThan(field,row[field]);else query.lessThan(field,row[field]);
   query.endGroup();
 }
 return query.endGroup();
}

module.exports={afterTuple,fail,hash,flag,id,uuid,int,version,token,encode,withCursorContext,timestampPage,coordinate,distance};
