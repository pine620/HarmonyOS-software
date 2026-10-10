'use strict';
const {dateMillis,currentVisibility}=require('./shared/content-policy');
const {fail,hash,id,int,token,encode,coordinate,distance,flag,timestampPage,afterTuple}=require('./stages47-common');
function createStage7Services(ctx){
 const {collection,one}=ctx;
 const stamp=row=>hash([row.id,row.ownerUid,Number(row.updatedAt),dateMillis(row.modifiedAt),Number(row.lifecycleGeneration),Number(row.tasteScore),dateMillis(row.publishedAt)]);
 async function boundary(saved,env){if(!saved)return null;const row=await one(collection(env,'FoodCard').query().equalTo('id',id(saved.lastId)));if(!row||stamp(row)!==saved.lastStamp)throw fail('分页基准已变化，请刷新。','CURSOR_STALE');return Object.assign(new ctx.models.FoodCard(),row);}
 async function rankingCapability(env,readiness){
  let reason=!flag(env,'SHIKE_RANKINGS_VERIFIED')?'榜单尚未完成上线验证':!readiness.cardCoverageComplete?'卡片历史回填尚未完成':!flag(env,'SHIKE_INDEXED_QUERY_VERIFIED')?'榜单索引尚未验证':String(env.SHIKE_STAGE3_MAP_COORDINATE_SYSTEM||process.env.SHIKE_STAGE3_MAP_COORDINATE_SYSTEM||'')!=='GCJ02'?'附近榜单坐标尚未配置':'';
  if(!reason&&await one(collection(env,'Merchant').query().equalTo('mapVisible',true).equalTo('coordinateSystem','WGS84')))reason='商家坐标系尚未统一';
  return {enabled:!reason,reason};
 }
 async function capabilities(uid,env){
  if(uid)await ctx.contentPolicy(env).assertAccountActive(uid);
  const readiness=await ctx.stage1().migrationReadiness(env), discovery=await ctx.stage3().capabilities(env,readiness), rankings=await rankingCapability(env,readiness);
  const reactionsEnabled=readiness.reactionCoverageComplete&&flag(env,'SHIKE_REACTION_VERIFIED');
  return {protocolVersion:2,reactionsEnabled,reactionsReason:!readiness.reactionCoverageComplete?'赞踩历史整理尚未完成':!reactionsEnabled?'赞踩尚未完成上线验证':'',mealEnabled:discovery.searchEnabled,merchantEnabled:discovery.mapEnabled,collectionEnabled:ctx.collections().enabled(env),rankingsEnabled:rankings.enabled,rankingsReason:rankings.reason};
 }
 async function userPage(uid,p,env){
  const target=id(p.userUid);
  await ctx.contentPolicy(env).assertProfileReadable(uid,target);
  const profile=await one(collection(env,'UserProfile').query().equalTo('uid',target));
  const sig=hash([uid,target,'user-page-v2']);const saved=token(p.cursor,sig);const at=saved?saved.at:Date.now();
  const size=int(p.pageSize===undefined?12:p.pageSize,1,20);
  const cards=[],sources=[];let consumed=0,next=saved;
  do {
   const page=await timestampPage(collection(env,'FoodCard').query().equalTo('ownerUid',target).equalTo('status','APPROVED').orderByDesc('createdAt'),next,at,Math.min(10,size-cards.length,60-consumed),'id','createdAt');
   const rows=page.rows;next=page.next;consumed+=rows.length;
   const context=await ctx.createCardReadContext(rows,uid,env);
   const allowed=await ctx.readableCardRows(rows,uid,env,false,context);
   await ctx.preparePrimaryPhotos(context,allowed,env);
   for(const row of allowed){cards.push(ctx.previewCard(row,context,env));sources.push(row);}
  }while(next&&consumed<60&&cards.length<size);
  const fresh=await ctx.finalizeCardReads(cards,sources,uid,env);
  const latest=await one(collection(env,'UserProfile').query().equalTo('uid',target));
  if(!latest||Number(latest.updatedAt)!==Number(profile.updatedAt))throw fail('主页已变化，请刷新。','CURSOR_STALE');
  const view=ctx.profileResponse(latest,env);
  return {profile:{uid:view.uid,nickname:view.nickname,avatarPath:view.avatarPath,avatarBucket:view.avatarBucket,publishCount:view.publishCount,coverPath:view.coverPath||'',coverBucket:view.coverBucket||''},
   relationshipState:uid===target?'SELF':'VISITOR',
   cards:fresh,
   nextCursor:next?encode(sig,at,next):''};
 }
 async function rankings(uid,p,env){
  if(uid)await ctx.contentPolicy(env).assertAccountActive(uid);
  const caps=await rankingCapability(env,await ctx.stage1().migrationReadiness(env));
  if(!caps.enabled)throw fail(caps.reason+'，请在上线诊断中核对。','FEATURE_NOT_READY');
  const kind=p.kind||'HIGH_SCORE';
  if(!['HIGH_SCORE','FRIENDS'].includes(kind))throw fail('榜单类型无效。');
  if(kind==='FRIENDS'&&!uid)throw fail('好友榜需登录。','AUTH_REQUIRED');
  if(!Number.isFinite(p.lat)||Math.abs(p.lat)>90||!Number.isFinite(p.lon)||Math.abs(p.lon)>180||p.coordinateSystem!=='GCJ02')throw fail('榜单中心无效。','LOCATION_REQUIRED');
  const sig=hash(['rankings-range-v3',uid,kind,p.lat,p.lon]);const saved=token(p.cursor,sig);const at=saved?saved.at:Date.now();
  const last=await boundary(saved,env);let owners=null;
  if(kind==='FRIENDS')owners=new Set((await ctx.friendshipRowsFor(uid,env)).filter(r=>r.status==='ACCEPTED').map(r=>r.memberAUid===uid?r.memberBUid:r.memberAUid));
  let query=collection(env,'FoodCard').query().equalTo('status','APPROVED');
  // Preserve the deployed mixed-direction index; ordinary ranges avoid the SDK
  // startAfter restriction on order direction and pagination predicates.
  if(last)query=afterTuple(query,[['tasteScore','DESC'],['publishedAt','DESC'],['id','ASC']],last);
  query=query.orderByDesc('tasteScore').orderByDesc('publishedAt').orderByAsc('id');
  const rows=await ctx.withReadPhase('candidates',()=>query.limit(400).get());
  ctx.recordReadCounts({scannedCandidateCount:rows.length});
  const cards=[],sources=[];let consumed=0;
  for(let start=0;start<rows.length&&cards.length<20;start+=10){
   await ctx.withReadPhase('assembly',async()=>{
    const batch=rows.slice(start,start+10);
    const candidates=batch.filter(row=>dateMillis(row.publishedAt)!==null&&dateMillis(row.publishedAt)<=at&&(owners?owners.has(row.ownerUid):currentVisibility(row)==='PUBLIC')&&row.merchantId);
    const context=await ctx.createCardReadContext(candidates,uid,env);
    const readable=await ctx.readableCardRows(candidates,uid,env,!owners,context);
    const merchants=await ctx.readMerchantRowsByIds(readable.map(row=>row.merchantId),env,context);
    const qualified=readable.filter(row=>coordinate(merchants.get(row.merchantId))&&distance(p.lat,p.lon,merchants.get(row.merchantId))<=20000);
    await ctx.preparePrimaryPhotos(context,qualified,env);
    const allowed=new Set(qualified.map(row=>row.id));
    for(const row of batch){
     consumed++;
     if(allowed.has(row.id)){
      const meters=distance(p.lat,p.lon,merchants.get(row.merchantId));
      const card=await ctx.readCardIfAllowed(row,env,meters/1000,true,uid,false,1,null,context);
      if(card){cards.push(card);sources.push(row);}
     }
     if(cards.length===20)break;
    }
    ctx.recordReadCounts({consumedCandidateCount:consumed});
   });
  }
  const final=await ctx.withReadPhase('final-check',async()=>{
   const qualified=await ctx.finalizeCardReads(cards,sources,uid,env,kind==='FRIENDS');
   // A separate batch bypasses assembly's merchant cache, just as authority is refreshed.
   const merchants=await ctx.readMerchantRowsByIds(qualified.map(card=>card.merchantId),env);
   return qualified.filter(card=>coordinate(merchants.get(card.merchantId))&&distance(p.lat,p.lon,merchants.get(card.merchantId))<=20000);
  });
  const frontier=consumed?rows[consumed-1]:null;
  return {cards:final,nextCursor:frontier&&(consumed<rows.length||rows.length===400)?encode(sig,at,{lastId:frontier.id,lastStamp:stamp(frontier)}):'',coverage:consumed<rows.length?'PARTIAL_RESULT_LIMIT':rows.length===400?'PARTIAL_SCAN_LIMIT':'COMPLETE',scannedCandidateCount:rows.length,consumedCandidateCount:consumed,centerSource:p.centerSource==='LOCATION'?'LOCATION':'DEFAULT',radiusMeters:20000};
 }
 async function publicShare(p,env){const cardId=id(p.cardId);const row=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!row || currentVisibility(row)!=='PUBLIC' || !await ctx.contentPolicy(env).canReadCard('',row))throw fail('内容已不可访问。','CONTENT_UNAVAILABLE');
  // Explicit browser allowlist. Never serialize the DB row or an owner DTO.
  const card=await ctx.readCardIfAllowed(row,env,0,false,'',false,1);if(!card)throw fail('内容已不可访问。','CONTENT_UNAVAILABLE');
  const merchant=row.merchantId?await one(collection(env,'Merchant').query().equalTo('merchantId',row.merchantId)):null;
  const result={cardId:row.id,productName:String(card.productName||'').slice(0,100),tasteScore:Number(card.tasteScore),merchantName:String(merchant&&merchant.name||row.shop||'').slice(0,100),priceFen:row.queryPriceFen==null?null:Number(row.queryPriceFen),reviewText:String(card.reviewText||'').slice(0,2000),consumptionMode:String(row.consumptionMode||'UNSPECIFIED'),contentVersion:String(row.lifecycleGeneration||0)+':'+String(row.updatedAt),coverAvailable:!!row.mediaId};
  const current=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!current || currentVisibility(current)!=='PUBLIC' || !await ctx.contentPolicy(env).canReadCard('',current) || Number(current.updatedAt)!==Number(row.updatedAt) || dateMillis(current.modifiedAt)!==dateMillis(row.modifiedAt))throw fail('内容已不可访问。','CONTENT_UNAVAILABLE');return result;
 }
 async function publicShareMedia(p,env){const cardId=id(p.cardId);await publicShare({cardId},env);const row=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!row || !row.mediaId)throw fail('图片已不可访问。','CONTENT_UNAVAILABLE');const media=await one(collection(env,'CardMedia').query().equalTo('id',row.mediaId));if(!media || media.cardId!==row.id || media.status!=='APPROVED')throw fail('图片已不可访问。','CONTENT_UNAVAILABLE');const response=await ctx.readPublicShareMedia(row,media,env);await publicShare({cardId},env);const current=await one(collection(env,'FoodCard').query().equalTo('id',cardId));if(!current||current.mediaId!==row.mediaId)throw fail('图片已变化，请刷新。','CONTENT_UNAVAILABLE');return response;}
 async function reaction(uid,p,env){const caps=await capabilities(uid,env);if(!caps.reactionsEnabled)throw fail('赞踩迁移与一致性尚未验证。','FEATURE_NOT_READY');return ctx.stage1().mutateReaction(uid,p,env);}
 return {capabilities,userPage,rankings,publicShare,publicShareMedia,reaction};
}
module.exports={createStage7Services};
