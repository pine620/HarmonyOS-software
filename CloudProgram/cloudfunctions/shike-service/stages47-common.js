'use strict';
const crypto = require('crypto');
const { AsyncLocalStorage } = require('async_hooks');
const cursorScope = new AsyncLocalStorage();
const withCursorContext = (env, action) => cursorScope.run(env || process.env, action);
function cursorKey() {
  const env = cursorScope.getStore() || process.env;
  const configured = key => env[key] === undefined ? process.env[key] || '' : env[key];
  const secret = String(configured('SHIKE_CURSOR_SIGNING_KEY') || configured('SHIKE_MEDIA_INTERNAL_KEY') || '').trim();
  if (Buffer.byteLength(secret) < 32) throw fail('分页签名配置尚未就绪。', 'CONFIGURATION_REQUIRED');
  // Domain-separated derivation permits rollout with the existing internal key.
  return crypto.createHmac('sha256', secret).update('shike-pagination-v1').digest();
}
const { accessError, dateMillis, currentVisibility } = require('./shared/content-policy');
const CATEGORIES = ['RICE_SET','NOODLES','HOT_POT','GRILL_FRIED','SNACK','FAST_WESTERN','BREAKFAST_BAKERY','DESSERT','DRINK','PACKAGED','OTHER'];
const fail = (message, code = 'VALIDATION_ERROR') => accessError(message, code);
const hash = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const flag = (env, key) => String(env[key] === undefined ? process.env[key] || '' : env[key]) === 'true';
function id(value) { if (typeof value !== 'string' || !/^[A-Za-z0-9:_-]{1,160}$/.test(value)) throw fail('标识无效。'); return value; }
function uuid(value) { if(typeof value!=='string'||! /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw fail('请求标识必须为 UUID。');return value.toLowerCase(); }
function int(value, min, max) { if (!Number.isSafeInteger(value) || value < min || value > max) throw fail('数值无效。'); return value; }
function version(value, row) { if (int(value,0,Number.MAX_SAFE_INTEGER) !== Number(row && row.version || 0)) throw fail('记录已变化，请刷新后重试。','STALE_VERSION'); }
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
function encode(signature, at, state) {
  const body = Buffer.from(JSON.stringify({...state,signature,at})).toString('base64url');
  if (body.length > 65536) throw fail('分页快照过大，请刷新。', 'CURSOR_STALE');
  return body + '.' + crypto.createHmac('sha256', cursorKey()).update(body).digest('hex');
}
// Descending timestamp indexes without a primary-key tie-breaker remain usable.
// Re-read only the frontier timestamp, excluding its already consumed IDs; never
// use a shifting offset when records ahead of the frontier disappear.
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
function preference(value) {
  if (!value || typeof value!=='object' || Array.isArray(value)) throw fail('偏好无效。');
  const liked = value.likedCategories || []; const less = value.lessCategories || [];
  for (const array of [liked,less]) if (!Array.isArray(array) || array.length>11 || new Set(array).size!==array.length || array.some(x=>!CATEGORIES.includes(x))) throw fail('分类偏好无效。');
  if (liked.some(x=>less.includes(x))) throw fail('喜欢与少推荐分类不能重叠。');
  const mode=value.preferredMode || 'ANY'; if (!['ANY','DELIVERY','DINE_IN'].includes(mode)) throw fail('偏好消费方式无效。');
  const min=value.budgetMinFen == null ? null : int(value.budgetMinFen,0,100000000);
  const max=value.budgetMaxFen == null ? null : int(value.budgetMaxFen,0,100000000);
  if (min!==null && max!==null && max<min) throw fail('预算上限不得小于下限。');
  return {likedCategories:liked.slice(),lessCategories:less.slice(),preferredMode:mode,budgetMinFen:min,budgetMaxFen:max};
}
function preferenceView(row) {
  if (!row) return {...preference({}),version:0,updatedAt:0};
  return {...preference({likedCategories:JSON.parse(row.likedCategoriesJson || '[]'),lessCategories:JSON.parse(row.lessCategoriesJson || '[]'),preferredMode:row.preferredMode,budgetMinFen:row.budgetMinFen,budgetMaxFen:row.budgetMaxFen}),version:Number(row.version),updatedAt:dateMillis(row.updatedAt)};
}
const hasPreference = p=>p.likedCategories.length+p.lessCategories.length>0 || p.preferredMode!=='ANY' || p.budgetMinFen!==null || p.budgetMaxFen!==null;
function score(row,p,at) {
  let value=Math.max(0,20-Math.floor((at-(dateMillis(row.publishedAt)||Number(row.createdAt)))/86400000)); const reasons=[];
  if(p.likedCategories.includes(row.categoryV2)){value+=30;reasons.push('你喜欢的分类');}
  if(p.lessCategories.includes(row.categoryV2))value-=35;
  if(p.preferredMode!=='ANY' && row.consumptionMode===p.preferredMode){value+=20;reasons.push(p.preferredMode==='DELIVERY'?'偏好的外卖方式':'偏好的到店方式');}
  if((p.budgetMinFen!==null || p.budgetMaxFen!==null) && row.queryPriceFen!=null && (p.budgetMinFen===null || row.queryPriceFen>=p.budgetMinFen) && (p.budgetMaxFen===null || row.queryPriceFen<=p.budgetMaxFen)){value+=15;reasons.push('符合你的常用预算');}
  return {value,reasons};
}
function coordinate(row) { return row && ['VERIFIED_PROVIDER','USER_CONFIRMED_APPROVED'].includes(row.verificationStatus) && row.coordinateSystem==='GCJ02' && Number.isSafeInteger(row.latitudeE6) && Math.abs(row.latitudeE6)<=90000000 && Number.isSafeInteger(row.longitudeE6) && Math.abs(row.longitudeE6)<=180000000; }
function distance(lat,lon,row) { const rad=Math.PI/180,a=(row.latitudeE6/1e6-lat)*rad,b=(row.longitudeE6/1e6-lon)*rad;const h=Math.sin(a/2)**2+Math.cos(lat*rad)*Math.cos(row.latitudeE6/1e6*rad)*Math.sin(b/2)**2;return 6371000*2*Math.asin(Math.min(1,Math.sqrt(h))); }
function friendsAllowed(env,row) { return currentVisibility(row)==='PUBLIC' || flag(env,'SHIKE_FRIENDS_PUBLISH_VERIFIED'); }
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

module.exports={afterTuple,CATEGORIES,fail,hash,flag,id,uuid,int,version,token,encode,withCursorContext,timestampPage,preference,preferenceView,hasPreference,score,coordinate,distance,friendsAllowed};
