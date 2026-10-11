'use strict';
const {dateMillis,currentVisibility}=require('./shared/content-policy');
const {fail,hash,id,int,token,encode,flag,timestampPage}=require('./stages47-common');
function createStage7Services(ctx){
 const {collection,one}=ctx;
 async function capabilities(uid,env){
  if(uid)await ctx.contentPolicy(env).assertAccountActive(uid);
  const readiness=await ctx.stage1().migrationReadiness(env), discovery=await ctx.stage3().capabilities(env,readiness), rankings=await ctx.foodRankings().capability(env,readiness);
  const reactionsEnabled=readiness.reactionCoverageComplete&&flag(env,'SHIKE_REACTION_VERIFIED');
  return {protocolVersion:2,reactionsEnabled,reactionsReason:!readiness.reactionCoverageComplete?'赞踩历史整理尚未完成':!reactionsEnabled?'赞踩尚未完成上线验证':'',mealEnabled:discovery.searchEnabled,merchantEnabled:discovery.mapEnabled,collectionEnabled:ctx.collections().enabled(env),foodRankingsEnabled:rankings.enabled,foodRankingsReason:rankings.reason};
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
   relationshipState:uid===target?'SELF':uid&&(await ctx.friendshipBetween(uid,target,env))?.status==='ACCEPTED'?'FRIEND':'VISITOR',
   cards:fresh,
   nextCursor:next?encode(sig,at,next):''};
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
 return {capabilities,userPage,publicShare,publicShareMedia,reaction};
}
module.exports={createStage7Services};
