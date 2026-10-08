'use strict';
const crypto = require('crypto');
const { accessError, dateMillis, currentVisibility } = require('./content-policy');
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
  if (typeof value !== 'string' || value.length > 65536 || !/^[A-Za-z0-9_-]+$/.test(value)) throw fail('分页失效，请刷新。','CURSOR_STALE');
  let parsed; try { parsed=JSON.parse(Buffer.from(value,'base64url').toString()); } catch (_) { throw fail('分页失效，请刷新。','CURSOR_STALE'); }
  if (!parsed || parsed.signature !== signature || !Number.isSafeInteger(parsed.at) || parsed.at > Date.now() || Date.now()-parsed.at>900000) throw fail('分页失效，请刷新。','CURSOR_STALE');
  return parsed;
}
const encode = (signature, at, state) => Buffer.from(JSON.stringify({signature,at,...state})).toString('base64url');
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
module.exports={CATEGORIES,fail,hash,flag,id,uuid,int,version,token,encode,preference,preferenceView,hasPreference,score,coordinate,distance,friendsAllowed};
