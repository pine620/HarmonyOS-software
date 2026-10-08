'use strict';
const {dateMillis,currentVisibility}=require('./content-policy');
const {fail,hash,id,int,token,encode,coordinate,distance,friendsAllowed,flag}=require('./stages47-common');
function createStage7Services(ctx){
 const {collection,one}=ctx;
 const stamp=row=>hash([row.id,row.ownerUid,Number(row.updatedAt),dateMillis(row.modifiedAt),Number(row.lifecycleGeneration),Number(row.tasteScore),dateMillis(row.publishedAt)]);
 async function boundary(saved,env){if(!saved)return null;const row=await one(collection(env,'FoodCard').query().equalTo('id',id(saved.lastId)));if(!row||stamp(row)!==saved.lastStamp)throw fail('分页基准已变化，请刷新。','CURSOR_STALE');return Object.assign(new ctx.models.FoodCard(),row);}
 async function capabilities(uid,env){if(uid)await ctx.contentPolicy(env).assertAccountActive(uid);const readiness=await ctx.stage1().migrationReadiness(env);const discovery=await ctx.stage3().capabilities(env);return {friendsEnabled:flag(env,'SHIKE_FRIENDS_PUBLISH_VERIFIED'),reactionsEnabled:readiness.reactionCoverageComplete && flag(env,'SHIKE_REACTION_VERIFIED'),mealEnabled:discovery.searchEnabled,merchantEnabled:discovery.mapEnabled,collectionEnabled:ctx.collections().enabled(env)};}
 async function userPage(uid,p,env){
  const target=id(p.userUid);
  await ctx.contentPolicy(env).assertProfileReadable(uid,target);
  const profile=await one(collection(env,'UserProfile').query().equalTo('uid',target));
  const sig=hash([uid,target,'user-page']);const saved=token(p.cursor,sig);const at=saved?saved.at:Date.now();
  const last=await boundary(saved,env);const size=int(p.pageSize===undefined?12:p.pageSize,1,20);
  let query=collection(env,'FoodCard').query().equalTo('ownerUid',target).equalTo('status','APPROVED')
   .lessThanOrEqualTo('createdAt',at).orderByDesc('createdAt').orderByAsc('id');if(last)query=query.startAfter(last);
  const cards=[],sources=[];let consumed=0,frontier=null,hasMore=false;
  while(consumed<60&&cards.length<size){
   const rows=await query.limit(Math.min(10,60-consumed)).get();
   if(!rows.length){hasMore=false;break;}
   const context=await ctx.createCardReadContext(rows,uid,env);
   const allowed=await ctx.readableCardRows(rows.filter(r=>friendsAllowed(env,r)),uid,env,false,context);
   await ctx.preparePrimaryPhotos(context,allowed,env);
   for(const row of rows){
    consumed++;frontier=row;
    if(allowed.some(r=>r.id===row.id)){cards.push(ctx.previewCard(row,context,env));sources.push(row);}
    if(cards.length===size)break;
   }
   hasMore=cards.length===size||rows.length===10;
   if(cards.length===size||rows.length<10)break;
   query=query.startAfter(Object.assign(new ctx.models.FoodCard(),frontier));
  }
  const fresh=await ctx.finalizeCardReads(cards,sources,uid,env);
  // Recheck profile-level block after assembly even for an empty homepage.
  const relation=await ctx.contentPolicy(env).assertProfileReadable(uid,target);
  const isFriend=uid===target||relation&&relation.status==='ACCEPTED';
  const latest=await one(collection(env,'UserProfile').query().equalTo('uid',target));
  if(!latest||Number(latest.updatedAt)!==Number(profile.updatedAt))throw fail('主页已变化，请刷新。','CURSOR_STALE');
  const view=ctx.profileResponse(latest,env);
  return {profile:{uid:view.uid,nickname:view.nickname,avatarPath:view.avatarPath,avatarBucket:view.avatarBucket,publishCount:view.publishCount,coverPath:isFriend?view.coverPath||'':'',coverBucket:isFriend?view.coverBucket||'':''},
   relationshipState:uid===target?'SELF':relation&&relation.status==='ACCEPTED'?'FRIEND':'VISITOR',
   cards:isFriend?fresh:fresh.filter(card=>card.visibility!=='FRIENDS'),
   nextCursor:hasMore&&frontier?encode(sig,at,{lastId:frontier.id,lastStamp:stamp(frontier)}):''};
 }
 async function rankings(uid,p,env){if(uid)await ctx.contentPolicy(env).assertAccountActive(uid);const caps=await ctx.stage3().capabilities(env);if(!caps.mapEnabled)throw fail('排行榜需先验证 Merchant 坐标与索引。','FEATURE_NOT_READY');const kind=p.kind||'HIGH_SCORE';if(!['HIGH_SCORE','FRIENDS'].includes(kind))throw fail('榜单类型无效。');if(kind==='FRIENDS'&&!uid)throw fail('好友榜需登录。','AUTH_REQUIRED');if(!Number.isFinite(p.lat)||Math.abs(p.lat)>90||!Number.isFinite(p.lon)||Math.abs(p.lon)>180||p.coordinateSystem!=='GCJ02')throw fail('榜单中心无效。','LOCATION_REQUIRED');
  const sig=hash([uid,kind,p.lat,p.lon]);const saved=token(p.cursor,sig);const at=saved?saved.at:Date.now();const last=await boundary(saved,env);let owners=null;
  if(kind==='FRIENDS'){owners=new Set((await ctx.friendshipRowsFor(uid,env)).filter(r=>r.status==='ACCEPTED').map(r=>r.memberAUid===uid?r.memberBUid:r.memberAUid));}
  let query=collection(env,'FoodCard').query().equalTo('status','APPROVED').lessThanOrEqualTo('publishedAt',new Date(at)).orderByDesc('tasteScore').orderByDesc('publishedAt').orderByAsc('id');if(last)query=query.startAfter(last);const rows=await query.limit(400).get();const cards=[],sources=[],merchants=new Map();let consumed=0;
  for(const row of rows){consumed++;if(owners && !owners.has(row.ownerUid) || !owners && currentVisibility(row)!=='PUBLIC' || !row.merchantId || !friendsAllowed(env,row))continue;
   if(owners){const relation=await ctx.friendshipBetween(uid,row.ownerUid,env);if(!relation || relation.status!=='ACCEPTED')continue;}
   if(!merchants.has(row.merchantId))merchants.set(row.merchantId,await one(collection(env,'Merchant').query().equalTo('merchantId',row.merchantId)));const merchant=merchants.get(row.merchantId);if(!coordinate(merchant))continue;const meters=distance(p.lat,p.lon,merchant);if(meters>20000)continue;const card=await ctx.readCardIfAllowed(row,env,meters/1000,true,uid,false,1);if(card){cards.push(card);sources.push(row);}if(cards.length===20)break;
  }
  const frontier=consumed?rows[consumed-1]:null;const qualified=await ctx.finalizeCardReads(cards,sources,uid,env,kind==='FRIENDS');const final=[];for(const card of qualified){const merchant=await one(collection(env,'Merchant').query().equalTo('merchantId',card.merchantId));if(coordinate(merchant)&&distance(p.lat,p.lon,merchant)<=20000)final.push(card);}return {cards:final,nextCursor:consumed<rows.length || rows.length===400?encode(sig,at,{lastId:frontier.id,lastStamp:stamp(frontier)}):'',coverage:consumed<rows.length?'PARTIAL_RESULT_LIMIT':rows.length===400?'PARTIAL_SCAN_LIMIT':'COMPLETE',scannedCandidateCount:consumed,centerSource:p.centerSource==='LOCATION'?'LOCATION':'DEFAULT',radiusMeters:20000};}
 async function publicShare(p,env){const cardId=id(p.cardId);const row=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!row || currentVisibility(row)!=='PUBLIC' || !await ctx.contentPolicy(env).canReadCard('',row))throw fail('内容已不可访问。','CONTENT_UNAVAILABLE');
  // Explicit browser allowlist. Never serialize the DB row or an owner DTO.
  const card=await ctx.readCardIfAllowed(row,env,0,false,'',false,1);if(!card)throw fail('内容已不可访问。','CONTENT_UNAVAILABLE');
  const merchant=row.merchantId?await one(collection(env,'Merchant').query().equalTo('merchantId',row.merchantId)):null;
  const result={cardId:row.id,productName:String(card.productName||'').slice(0,100),tasteScore:Number(card.tasteScore),merchantName:String(merchant&&merchant.name||row.shop||'').slice(0,100),priceFen:row.queryPriceFen==null?null:Number(row.queryPriceFen),reviewText:String(card.reviewText||'').slice(0,2000),consumptionMode:String(row.consumptionMode||'UNSPECIFIED'),contentVersion:String(row.lifecycleGeneration||0)+':'+String(row.updatedAt),coverAvailable:!!row.mediaId};
  const current=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!current || currentVisibility(current)!=='PUBLIC' || !await ctx.contentPolicy(env).canReadCard('',current) || Number(current.updatedAt)!==Number(row.updatedAt) || dateMillis(current.modifiedAt)!==dateMillis(row.modifiedAt))throw fail('内容已不可访问。','CONTENT_UNAVAILABLE');return result;
 }
 async function publicShareMedia(p,env){const cardId=id(p.cardId);await publicShare({cardId},env);const row=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!row || !row.mediaId)throw fail('图片已不可访问。','CONTENT_UNAVAILABLE');const media=await one(collection(env,'CardMedia').query().equalTo('id',row.mediaId));if(!media || media.cardId!==row.id || media.status!=='APPROVED')throw fail('图片已不可访问。','CONTENT_UNAVAILABLE');const response=await ctx.readPublicShareMedia(row,media,env);await publicShare({cardId},env);const current=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!current||current.mediaId!==row.mediaId)throw fail('图片已变化，请刷新。','CONTENT_UNAVAILABLE');return response;}
 async function formerGrants(uid,p,env){await ctx.contentPolicy(env).assertAccountActive(uid);return {grants:[],nextCursor:''};}
 async function reaction(uid,p,env){const caps=await capabilities(uid,env);if(!caps.reactionsEnabled)throw fail('赞踩迁移与一致性尚未验证。','FEATURE_NOT_READY');return ctx.stage1().mutateReaction(uid,p,env);}
 return {capabilities,userPage,rankings,publicShare,publicShareMedia,formerGrants,reaction};
}
module.exports={createStage7Services};
