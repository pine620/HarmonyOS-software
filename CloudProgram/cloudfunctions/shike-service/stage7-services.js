/**
 * 【文件职责】用户主页（get-user-page：资料 + 公开卡片分页 + 与查看者的关系）与赞 / 踩 v2（set-card-reaction-v2）。
 */
'use strict';
const {fail,hash,id,int,token,encode,flag,timestampPage}=require('./stages47-common');
// 创建模块：ctx 由 runtime.js 注入公共函数与配置。
function createStage7Services(ctx){
 const {collection,one}=ctx;
 // 读取用户主页。
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
 // 设置赞 / 踩。
 async function reaction(uid,p,env){
  // 写入只需要校验自身的历史数据；搜索 / 地图 / 榜单的就绪状态属于它们各自的入口，不放在反应写入的关键路径上。
  if(!flag(env,'SHIKE_REACTION_VERIFIED'))throw fail('赞踩尚未完成上线验证。','FEATURE_NOT_READY');
  const history=await ctx.stage1().reactionHistoryMaintenance({mode:'status'},env);
  if(!history.ready)throw fail('赞踩历史整理尚未完成。','FEATURE_NOT_READY');
  return ctx.stage1().mutateReaction(uid,p,env,false,true);
 }
 return {userPage,reaction};
}
module.exports={createStage7Services};
