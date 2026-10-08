'use strict';
const crypto=require('crypto');
const {dateMillis,currentVisibility,isAccountActive}=require('./content-policy');
const {fail,hash,id,uuid,int,version,token,encode,score,coordinate,distance,friendsAllowed}=require('./stages47-common');
function createStage6Services(ctx){
 const {collection,one,models}=ctx;const model=(n,r)=>Object.assign(new models[n](),r);
 async function personalCandidates(uid,p,env){
  await ctx.contentPolicy(env).assertAccountActive(uid);
  const excluded=p.excludedCardIds||[];
  if(!Array.isArray(excluded)||excluded.length>1000||excluded.some(x=>typeof x!=='string'||x.length>128))throw fail('会话排除集合无效。');
  const limit=1000;
  const migration=await ctx.collections().status(uid,env);
  const [wanted,favorites,items,ownedLists]=migration.collectionReady?await Promise.all([
   collection(env,'CardAction').query().equalTo('actorUid',uid).equalTo('kind','WANT_TO_EAT').orderByDesc('createdAt').orderByAsc('id').limit(limit).get(),
   collection(env,'CardAction').query().equalTo('actorUid',uid).equalTo('kind','FAVORITE').orderByDesc('createdAt').orderByAsc('id').limit(limit).get(),
   Promise.resolve([]),Promise.resolve([])
  ]):await Promise.all([
   collection(env,'PersonalFoodState').query().equalTo('ownerUid',uid).equalTo('state','WANT_TO_EAT').orderByDesc('updatedAt').orderByAsc('cardId').limit(limit).get(),
   collection(env,'CardAction').query().equalTo('actorUid',uid).equalTo('kind','FAVORITE').orderByDesc('createdAt').orderByAsc('id').limit(limit).get(),
   collection(env,'FoodListItem').query().equalTo('ownerUid',uid).orderByAsc('cardId').orderByAsc('listId').limit(limit).get(),
   collection(env,'FoodList').query().equalTo('ownerUid',uid).orderByAsc('sortOrder').orderByAsc('listId').limit(limit).get()
  ]);
  const activeLists=new Set(ownedLists.filter(list=>list.deletedAt==null).map(list=>list.listId));
  const seen=new Set(excluded),pool=new Map(),sourceIds=new Set();
  function entry(cardId){
   if(typeof cardId!=='string'||!cardId)return null;
   sourceIds.add(cardId);
   if(seen.has(cardId))return null;
   if(!pool.has(cardId))pool.set(cardId,{cardId,wanted:false,favorite:false,listIds:[]});
   return pool.get(cardId);
  }
  for(const row of wanted){const item=entry(row.cardId);if(item)item.wanted=true;}
  for(const row of favorites){const item=entry(row.cardId);if(item)item.favorite=true;}
  for(const row of items){if(!activeLists.has(row.listId))continue;const item=entry(row.cardId);if(item&&!item.listIds.includes(row.listId))item.listIds.push(row.listId);}
  const shuffled=[...pool.values()];
  for(let i=shuffled.length-1;i>0;i--){const j=crypto.randomInt(i+1);[shuffled[i],shuffled[j]]=[shuffled[j],shuffled[i]];}
  let output=[];const sources=new Map(),fetchedIds=new Set();let scanned=0;
  // Personal references need no public-search qualification or preference ranking.
  // Bound stale-reference reads while drawing uniformly from the collected IDs.
  while(scanned<shuffled.length&&scanned<60&&output.length<3){
   await ctx.withReadPhase('assembly',async()=>{
    while(scanned<shuffled.length&&scanned<60&&output.length<3){
     const batch=shuffled.slice(scanned,scanned+Math.min(10,60-scanned));
     for(const item of batch)fetchedIds.add(item.cardId);
     const byId=await ctx.readCardRowsByIds(batch.map(item=>item.cardId),env);
     const rows=batch.map(item=>byId.get(item.cardId)).filter(row=>row&&friendsAllowed(env,row));
     const context=await ctx.createCardReadContext(rows,uid,env);
     const readable=await ctx.readableCardRows(rows,uid,env,false,context);
     await ctx.preparePrimaryPhotos(context,readable,env);
     for(const item of batch){
      if(output.length===3)break;
      scanned++;const row=byId.get(item.cardId);if(!row||!friendsAllowed(env,row))continue;
      const card=await ctx.readCardIfAllowed(row,env,0,true,uid,false,1,null,context);if(!card)continue;
      const reasons=[];if(item.wanted)reasons.push('来自我的想吃');if(item.favorite)reasons.push('来自我的收藏');if(item.listIds.length)reasons.push('来自待整理收藏');
      output.push({card,reasons,distanceMeters:null});sources.set(card.id,row);
     }
    }
   });
   const fresh=await ctx.withReadPhase('final-check',()=>ctx.finalizeCardReads(output.map(item=>item.card),[...sources.values()],uid,env));
   const readable=new Map(fresh.map(card=>[card.id,card]));
   output=output.filter(item=>readable.has(item.card.id)).map(item=>({...item,card:readable.get(item.card.id)}));
  }
  const candidates=output;
  await ctx.contentPolicy(env).assertAccountActive(uid);
  const complete=wanted.length<limit&&favorites.length<limit&&items.length<limit&&ownedLists.length<limit&&scanned===shuffled.length;
  const sourcesBounded=wanted.length===limit||favorites.length===limit||items.length===limit||ownedLists.length===limit;
  const emptyReason=candidates.length?'':sourceIds.size===0?'NO_SOURCES':pool.size===0?'EXCLUDED_EXHAUSTED':sourcesBounded||scanned<shuffled.length?'SCAN_LIMIT':'EXHAUSTED';
  return {personalRandom:true,candidates,coverage:complete?'COMPLETE':'BOUNDED',scannedCandidateCount:scanned,fetchedCandidateCount:fetchedIds.size,insufficient:candidates.length<3,sessionExhausted:complete&&candidates.length===0,emptyReason};
 }
 async function candidates(uid,p,env){
  if(p.personalRandom===true)return personalCandidates(uid,p,env);
  await ctx.contentPolicy(env).assertAccountActive(uid);const caps=await ctx.stage3().capabilities(env);if(!caps.searchEnabled)throw fail('选餐硬条件需先完成查询资格验证。','FEATURE_NOT_READY');
  const spec=ctx.stage3().querySpec({...p,scope:'ALL_PUBLIC',sort:'LATEST'},env);const source=p.source||'ALL';if(!['ALL','MY_LISTS','FRIENDS_ONLY','PUBLIC_ONLY'].includes(source))throw fail('来源无效。');
  const excluded=p.excludedCardIds||[];if(!Array.isArray(excluded)||excluded.length>1000||excluded.some(x=>typeof x!=='string'||x.length>128))throw fail('会话排除集合无效。');
  let point=null;if(p.nearby===true){if(!caps.mapEnabled)throw fail('附近选餐需先验证 Merchant 坐标。','FEATURE_NOT_READY');if(!Number.isFinite(p.lat)||Math.abs(p.lat)>90||!Number.isFinite(p.lon)||Math.abs(p.lon)>180||p.coordinateSystem!=='GCJ02')throw fail('附近需要本次可靠位置。','LOCATION_REQUIRED');point={lat:p.lat,lon:p.lon,radius:int(p.radiusMeters,100,20000)};}
  const pref=await ctx.stage4().get(uid,env);const at=Date.now();const layers=[];let scanned=0;
  if(source==='ALL'||source==='MY_LISTS'){
   const migration=await ctx.collections().status(uid,env);
   const statesQuery=migration.collectionReady?collection(env,'CardAction').query().equalTo('actorUid',uid).equalTo('kind','WANT_TO_EAT').orderByDesc('createdAt').orderByAsc('id'):collection(env,'PersonalFoodState').query().equalTo('ownerUid',uid).equalTo('state','WANT_TO_EAT').orderByDesc('updatedAt').orderByAsc('cardId');
   const [states,favorites]=await Promise.all([statesQuery.limit(100).get(),collection(env,'CardAction').query().equalTo('actorUid',uid).equalTo('kind','FAVORITE').orderByDesc('createdAt').orderByAsc('id').limit(100).get()]);scanned+=states.length+favorites.length;let refs=[...states,...favorites];
   if(p.listId && p.listId!=='FAVORITES'){if(migration.collectionReady)throw fail('私人清单已合并到收藏，请更新客户端。','CLIENT_UPDATE_REQUIRED');await ctx.stage5().ownList(uid,p.listId,env);refs=await collection(env,'FoodListItem').query().equalTo('listId',p.listId).orderByAsc('sortKey').orderByAsc('cardId').limit(200).get();scanned+=refs.length;}
   const rows=[];for(const ref of refs)rows.push(await one(collection(env,'FoodCard').query().equalTo('id',ref.cardId)));layers.push({rows:rows.filter(Boolean),reason:'来自我的想吃或收藏'});
  }
  if(source==='ALL'||source==='FRIENDS_ONLY'){
   const relations=await ctx.friendshipRowsFor(uid,env);const friends=[...new Set(relations.filter(r=>r.status==='ACCEPTED').map(r=>r.memberAUid===uid?r.memberBUid:r.memberAUid))].sort().slice(0,30);const rows=[];
   for(const friend of friends){const result=await collection(env,'FoodCard').query().equalTo('ownerUid',friend).equalTo('status','APPROVED').orderByDesc('createdAt').limit(10).get();scanned+=result.length;rows.push(...result);}layers.push({rows,reason:'来自当前好友推荐'});
  }
  if(source==='ALL'||source==='PUBLIC_ONLY'){const rows=await collection(env,'FoodCard').query().equalTo('status','APPROVED').orderByDesc('createdAt').orderByAsc('id').limit(300).get();scanned+=rows.length;layers.push({rows:rows.filter(r=>currentVisibility(r)==='PUBLIC'),reason:'来自公开推荐'});}
  const seen=new Set(excluded),output=[];const merchants=new Map();
  for(const layer of layers){const filtered=[];
   for(const row of layer.rows){if(seen.has(row.id)||!friendsAllowed(env,row)||!ctx.stage3().matchesHardFilters(row,spec,at)||!await ctx.contentPolicy(env).canReadCard(uid,row))continue;
    let meters=null;if(point){if(!merchants.has(row.merchantId))merchants.set(row.merchantId,await one(collection(env,'Merchant').query().equalTo('merchantId',row.merchantId||'')));const merchant=merchants.get(row.merchantId);if(!coordinate(merchant))continue;meters=distance(point.lat,point.lon,merchant);if(meters>point.radius)continue;}
    filtered.push({row,meters});}
   filtered.sort((a,b)=>score(b.row,pref,at).value-score(a.row,pref,at).value || a.row.id.localeCompare(b.row.id));
   // Each layer has a quota, so a single private candidate does not end ALL.
   const quota=source==='ALL'?Math.max(1,3-output.length):3;
   for(const item of filtered){if(seen.has(item.row.id))continue;if(layer.reason==='来自当前好友推荐'){const relation=await ctx.friendshipBetween(uid,item.row.ownerUid,env);if(!relation||relation.status!=='ACCEPTED')continue;}const card=await ctx.readCardIfAllowed(item.row,env,item.meters===null?0:item.meters/1000,true,uid,false,1);if(!card)continue;seen.add(card.id);output.push({card,reasons:[layer.reason,...score(item.row,pref,at).reasons],distanceMeters:item.meters});if(output.length>=3 || output.filter(x=>x.reasons[0]===layer.reason).length>=quota)break;}
   if(output.length>=3)break;
  }
  const final=[],sources=[];for(const item of output){const row=await one(collection(env,'FoodCard').query().equalTo('id',item.card.id));if(!row||!friendsAllowed(env,row)||!ctx.stage3().matchesHardFilters(row,spec,at))continue;if(item.reasons[0]==='来自当前好友推荐'){const relation=await ctx.friendshipBetween(uid,row.ownerUid,env);if(!relation||relation.status!=='ACCEPTED')continue;}let meters=null;if(point){const merchant=await one(collection(env,'Merchant').query().equalTo('merchantId',row.merchantId||''));if(!coordinate(merchant))continue;meters=distance(point.lat,point.lon,merchant);if(meters>point.radius)continue;}const card=await ctx.readCardIfAllowed(row,env,meters===null?0:meters/1000,true,uid,false,1);if(card){final.push({card,reasons:[item.reasons[0],...score(row,pref,at).reasons],distanceMeters:meters});sources.push(row);}}
  const readable=await ctx.finalizeCardReads(final.map(x=>x.card),sources,uid,env);const candidates=final.filter(x=>readable.some(c=>c.id===x.card.id));
  return {candidates,coverage:'BOUNDED',scannedCandidateCount:scanned,insufficient:candidates.length<3,sessionExhausted:candidates.length===0};
 }
 async function record(uid,p,env){const historyId=hash([uid,'choice',uuid(p.requestId)]);const cardId=id(p.cardId);let result;
  const committed=await collection(env,'MealChoiceHistory').runTransaction({apply:async tx=>{const owner=await ctx.stage1().activeProfile(tx,uid,env);const old=await ctx.stage1().txOne(tx,env,'MealChoiceHistory','historyId',historyId);if(old){if(old.cardId!==cardId)throw fail('请求已用于其它选餐。','CONFLICT');result={historyId,cardId,selectedAt:dateMillis(old.selectedAt)};return true;}const card=await ctx.stage1().txOne(tx,env,'FoodCard','id',cardId);await ctx.transactionPolicy(tx,env,[owner]).assertCardReadable(uid,card);const now=ctx.logicalWriteTime(owner.updatedAt);ctx.stage1().upsertRows(tx,[model('MealChoiceHistory',{historyId,uid,cardId,merchantId:card.merchantId||'',consumptionMode:card.consumptionMode||'UNSPECIFIED',selectedAt:new Date(now)}),ctx.profileForWrite(owner,now)]);result={historyId,cardId,selectedAt:now};return true;}});if(!committed)throw fail('选餐未记录。','CONFLICT');return result;}
 async function history(uid,p,env){await ctx.contentPolicy(env).assertAccountActive(uid);const sig=hash([uid,'history']);const saved=token(p.cursor,sig);const offset=saved?int(saved.offset,0,10000000):0;const rows=await collection(env,'MealChoiceHistory').query().equalTo('uid',uid).lessThanOrEqualTo('selectedAt',new Date(saved?saved.at:Date.now())).orderByDesc('selectedAt').orderByAsc('historyId').limit(30,offset).get();const items=[],sources=[];for(const row of rows){const source=await one(collection(env,'FoodCard').query().equalTo('id',row.cardId));const card=source&&friendsAllowed(env,source)?await ctx.readCardIfAllowed(source,env,0,true,uid,false,1):null;if(card)sources.push(source);items.push({historyId:row.historyId,cardId:row.cardId,merchantId:row.merchantId,consumptionMode:row.consumptionMode,selectedAt:dateMillis(row.selectedAt),card});}const fresh=await ctx.finalizeCardReads(items.filter(x=>x.card).map(x=>x.card),sources,uid,env);for(const item of items)item.card=fresh.find(c=>c.id===item.cardId)||null;return {items,nextCursor:rows.length===30?encode(sig,saved?saved.at:Date.now(),{offset:offset+rows.length}):''};}
 async function groupSnapshot(tx,uid,groupId,env){const group=await ctx.stage1().txOne(tx,env,'GroupConversation','id',id(groupId));const members=await tx.executeQuery(collection(env,'GroupMember').query().equalTo('groupId',groupId).limit(21));if(!group || members.length>20 || !members.some(m=>m.memberUid===uid))throw fail('你已不在此群。','FORBIDDEN');const profiles=[];for(const m of members){const profile=await ctx.stage1().txOne(tx,env,'UserProfile','uid',m.memberUid);if(isAccountActive(profile))profiles.push(profile);}if(!profiles.some(r=>r.uid===uid))throw fail('账号不可用。','ACCOUNT_INACTIVE');const activeMembers=members.filter(m=>profiles.some(r=>r.uid===m.memberUid));if(!profiles.some(r=>r.uid===group.ownerUid))throw fail('群主不可用。','FORBIDDEN');return {group,members:activeMembers,profiles};}
 async function validatedOptions(tx,poll,snapshot,env){const options=await tx.executeQuery(collection(env,'MealPollOption').query().equalTo('pollId',poll.pollId).orderByAsc('optionId').limit(13));const votes=await tx.executeQuery(collection(env,'MealPollVote').query().equalTo('pollId',poll.pollId).limit(21));if(options.length>12||votes.length>20)throw fail('投票超过事务预算。','TRANSACTION_LIMIT');const policy=ctx.transactionPolicy(tx,env,snapshot.profiles);const details=new Map();const invalid=[];
  for(const option of options){let accessible=option.status==='ACTIVE';let row=null;
   if(accessible && poll.mode==='CARD'){row=await ctx.stage1().txOne(tx,env,'FoodCard','id',option.cardId);accessible=!!row && friendsAllowed(env,row) && (poll.consumptionMode==='ANY'||row.consumptionMode===poll.consumptionMode);if(accessible)for(const member of snapshot.members){if(!await policy.canReadCard(member.memberUid,row)){accessible=false;break;}}}
   if(accessible && poll.mode==='MERCHANT'){row=await ctx.stage1().txOne(tx,env,'Merchant','merchantId',option.merchantId);accessible=!!coordinate(row);}
   if(!accessible && option.status==='ACTIVE' && poll.status==='OPEN')invalid.push(model('MealPollOption',{...option,status:'INVALID'}));details.set(option.optionId,{accessible,row});
  }
  const validVotes=votes.filter(v=>{const m=snapshot.members.find(x=>x.memberUid===v.voterUid);return m && dateMillis(v.updatedAt)>=Number(m.joinedAt||0) && details.get(v.optionId)&&details.get(v.optionId).accessible;});
  return {options,votes,validVotes,details,invalid};
 }
 function closeFields(poll,valid,now){const counts={};for(const o of valid.options)if(valid.details.get(o.optionId).accessible)counts[o.optionId]=0;for(const v of valid.validVotes)counts[v.optionId]++;const entries=Object.entries(counts);const max=Math.max(0,...entries.map(x=>x[1]));const tied=entries.filter(x=>x[1]===max && max>0);return {status:'CLOSED',acceptingOptions:false,closeOutcome:tied.length?'WINNER':'NO_RESULT',closeReason:tied.length?'':entries.length?'NO_VALID_VOTES':'NO_VALID_OPTIONS',winnerOptionId:tied.length?tied[crypto.randomInt(tied.length)][0]:'',winnerResolvedAt:new Date(now),resultCountsJson:JSON.stringify(counts)};}
 async function createPoll(uid,p,env){const pollId=hash([uid,'poll',uuid(p.requestId)]);const groupId=id(p.groupId);const title=String(p.title||'一起选餐').trim();if(!title || title.length>50 || !['CARD','MERCHANT'].includes(p.mode)||!['NAMED','ANONYMOUS'].includes(p.visibilityMode)||!['ANY','DELIVERY','DINE_IN'].includes(p.consumptionMode))throw fail('投票设置无效。');const deadline=p.deadlineAt==null?null:int(p.deadlineAt,0,Number.MAX_SAFE_INTEGER);const requestHash=hash([groupId,title,p.mode,p.visibilityMode,p.consumptionMode,p.deadlineAt||null]);
  const committed=await collection(env,'MealPoll').runTransaction({apply:async tx=>{const snapshot=await groupSnapshot(tx,uid,groupId,env);const old=await ctx.stage1().txOne(tx,env,'MealPoll','pollId',pollId);if(old){if(old.requestPayloadHash!==requestHash)throw fail('请求已用于不同投票。','CONFLICT');return true;}const now=Date.now();if(deadline!==null&&(deadline<now+1000||deadline>now+7*86400000))throw fail('截止必须在服务端当前时间之后且不超过 7 天。');const r=model('MealPoll',{pollId,groupId,creatorUid:uid,title,mode:p.mode,visibilityMode:p.visibilityMode,consumptionMode:p.consumptionMode,status:'OPEN',deadlineAt:deadline===null?null:new Date(deadline),acceptingOptions:true,closeOutcome:'',closeReason:'',winnerOptionId:'',winnerResolvedAt:null,resultCountsJson:'{}',createdAt:new Date(now),updatedAt:new Date(now),version:1,requestPayloadHash:requestHash});const messageId=hash(['poll-message',pollId]);const preview=ctx.encryptPrivateText('选餐投票，请升级或打开查看','group-conversation:'+groupId+':preview',env);
   ctx.stage1().upsertRows(tx,[r,model('GroupMessage',{id:messageId,groupId,senderUid:uid,kind:'MEAL_POLL',referenceId:pollId,cardId:'',text:'',createdAt:now}),model('GroupConversation',{...snapshot.group,lastMessageId:messageId,lastMessageKind:'MEAL_POLL',lastMessagePreview:preview,lastMessageAt:now,updatedAt:now}),...snapshot.members.map(m=>model('GroupMember',{...m,unreadCount:m.memberUid===uid?Number(m.unreadCount||0):Math.min(999,Number(m.unreadCount||0)+1),updatedAt:now}))]);return true;}});if(!committed)throw fail('投票未创建。','CONFLICT');return getPoll(uid,{pollId},env);}
 async function mutatePoll(uid,p,env,action='GET'){
  let output;let deadlineReached=false;
  const committed=await collection(env,'MealPoll').runTransaction({apply:async tx=>{deadlineReached=false;const poll=await ctx.stage1().txOne(tx,env,'MealPoll','pollId',id(p.pollId));if(!poll)throw fail('投票不存在。','NOT_FOUND');const snapshot=await groupSnapshot(tx,uid,poll.groupId,env);const valid=await validatedOptions(tx,poll,snapshot,env);const now=Date.now();let next={...poll};const writes=[];const deletes=[];
   if(poll.status==='OPEN' && dateMillis(poll.deadlineAt)!==null && now>=dateMillis(poll.deadlineAt)){Object.assign(next,closeFields(poll,valid,now));deadlineReached=action!=='GET';}
   else if(action!=='GET'){
    if(poll.status!=='OPEN'){if(action==='CLOSE'||action==='CANCEL'){output={poll,next,valid,snapshot};return true;}throw fail('投票已结束。','POLL_CLOSED');}if(action==='ADD'){const reference=poll.mode==='CARD'?id(p.cardId):id(p.merchantId);const repeated=hash([poll.pollId,poll.mode,reference]);if(valid.options.some(o=>o.optionId===repeated)){output={poll,valid,snapshot};return true;}}version(p.version,poll);
    if(['CLOSE','CANCEL','STOP'].includes(action) && poll.creatorUid!==uid)throw fail('只有发起人能操作。','FORBIDDEN');
    if(action==='CLOSE')Object.assign(next,closeFields(poll,valid,now));
    if(action==='CANCEL')Object.assign(next,{status:'CANCELLED',acceptingOptions:false});
    if(action==='STOP')next.acceptingOptions=false;
    if(action==='ADD'){
     if(!poll.acceptingOptions)throw fail('已停止添加候选。','POLL_CLOSED');if(valid.options.length>=12)throw fail('候选最多 12 个。','INSUFFICIENT_CANDIDATES');const reference=poll.mode==='CARD'?id(p.cardId):id(p.merchantId);const optionId=hash([poll.pollId,poll.mode,reference]);if(valid.options.some(o=>o.optionId===optionId))throw fail('候选已存在。','CONFLICT');let row;
     if(poll.mode==='CARD'){row=await ctx.stage1().txOne(tx,env,'FoodCard','id',reference);if(!row||!friendsAllowed(env,row))throw fail('候选尚无读取资格。','CONTENT_UNAVAILABLE');if(poll.consumptionMode!=='ANY' && row.consumptionMode!==poll.consumptionMode)throw fail('候选不符合消费方式。');const policy=ctx.transactionPolicy(tx,env,snapshot.profiles);for(const member of snapshot.members)if(!await policy.canReadCard(member.memberUid,row))throw fail('当前全群无法读取此候选。','FORBIDDEN');}
     else{const caps=await ctx.stage3().capabilities(env);if(!caps.mapEnabled)throw fail('商家候选需先验证坐标。','FEATURE_NOT_READY');row=await ctx.stage1().txOne(tx,env,'Merchant','merchantId',reference);if(!coordinate(row))throw fail('商家暂不可选。','MERCHANT_NOT_VERIFIED');}
     const added=model('MealPollOption',{pollId:poll.pollId,optionId,addedByUid:uid,cardId:poll.mode==='CARD'?reference:'',merchantId:poll.mode==='MERCHANT'?reference:'',status:'ACTIVE',createdAt:new Date(now)});writes.push(added);valid.options.push(added);valid.details.set(optionId,{accessible:true,row});
    }
    if(action==='VOTE'){const optionId=id(p.optionId);if(!valid.details.get(optionId)||!valid.details.get(optionId).accessible)throw fail('候选已不可访问。','CONTENT_UNAVAILABLE');const vote=model('MealPollVote',{pollId:poll.pollId,voterUid:uid,optionId,updatedAt:new Date(now)});writes.push(vote);valid.validVotes=valid.validVotes.filter(v=>v.voterUid!==uid);valid.validVotes.push(vote);}
   }
   if(poll.status==='OPEN'){writes.push(...valid.invalid);for(const v of valid.votes)if(!valid.validVotes.some(x=>x.voterUid===v.voterUid))deletes.push(model('MealPollVote',v));}
   if(action!=='GET' || valid.invalid.length || deletes.length || next.status!==poll.status){next.version=Number(poll.version)+1;next.updatedAt=new Date(now);writes.push(model('MealPoll',next));writes.push(model('GroupConversation',{...snapshot.group,updatedAt:ctx.logicalWriteTime(snapshot.group.updatedAt)}));}
   // All policy/authority queries above precede all SDK writes.
   if(deletes.length)tx.executeDelete(deletes);if(writes.length)ctx.stage1().upsertRows(tx,writes);output={poll:next,valid,snapshot};return true;
  }});if(!committed)throw fail('投票冲突，请刷新重试。','CONFLICT');if(deadlineReached)throw fail('截止已到，结果已固化。','POLL_DEADLINE_REACHED');return pollView(uid,output,env);
 }
 async function pollView(uid,data,env){const {poll,valid,snapshot}=data;await ctx.contentPolicy(env).assertAccountActive(uid);const currentMembers=await collection(env,'GroupMember').query().equalTo('groupId',poll.groupId).limit(21).get();if(!currentMembers.some(m=>m.memberUid===uid))throw fail('你已不在此群。','FORBIDDEN');const activeMembers=[];for(const member of currentMembers){const profile=await one(collection(env,'UserProfile').query().equalTo('uid',member.memberUid));if(isAccountActive(profile))activeMembers.push(member);}const counts=poll.status==='CLOSED'?JSON.parse(poll.resultCountsJson||'{}'):{};const liveVotes=valid.validVotes.filter(v=>activeMembers.some(m=>m.memberUid===v.voterUid&&dateMillis(v.updatedAt)>=Number(m.joinedAt||0)));if(poll.status==='OPEN')for(const v of liveVotes)counts[v.optionId]=(counts[v.optionId]||0)+1;const options=[];
  for(const o of valid.options){const d=valid.details.get(o.optionId);let card=null,merchant=null;if(d.accessible){if(poll.mode==='CARD'){let allReadable=true;const fresh=await one(collection(env,'FoodCard').query().equalTo('id',d.row.id));for(const member of activeMembers)if(!fresh||!await ctx.contentPolicy(env).canReadCard(member.memberUid,fresh)){allReadable=false;break;}if(allReadable&&friendsAllowed(env,fresh)){card=await ctx.readCardIfAllowed(fresh,env,0,true,uid,false,1);if(card){const finalized=await ctx.finalizeCardReads([card],[fresh],uid,env);card=finalized[0]||null;for(const member of activeMembers)if(!await ctx.contentPolicy(env).canReadCard(member.memberUid,fresh)){card=null;break;}}}}else{const fresh=await one(collection(env,'Merchant').query().equalTo('merchantId',d.row.merchantId));if(coordinate(fresh))merchant={merchantId:fresh.merchantId,name:fresh.name,address:fresh.address,latitude:fresh.latitudeE6/1e6,longitude:fresh.longitudeE6/1e6};}}const accessible=!!card||!!merchant;const out={optionId:o.optionId,status:accessible?'ACTIVE':'INVALID',accessible,card,merchant,voteCount:poll.status==='OPEN'&&!accessible?0:Number(counts[o.optionId]||0)};
   if(poll.visibilityMode==='NAMED'){out.voters=valid.validVotes.filter(v=>v.optionId===o.optionId&&activeMembers.some(m=>m.memberUid===v.voterUid&&dateMillis(v.updatedAt)>=Number(m.joinedAt||0))).map(v=>({uid:v.voterUid,nickname:String((snapshot.profiles.find(r=>r.uid===v.voterUid)||{}).nicknameValue||'群成员')}));}options.push(out);}
  const myVote=(poll.status==='OPEN'?liveVotes:valid.votes).find(v=>v.voterUid===uid);return {poll:{pollId:poll.pollId,groupId:poll.groupId,creatorUid:poll.creatorUid,title:poll.title,mode:poll.mode,visibilityMode:poll.visibilityMode,consumptionMode:poll.consumptionMode,status:poll.status,deadlineAt:dateMillis(poll.deadlineAt),acceptingOptions:poll.acceptingOptions,closeOutcome:poll.closeOutcome||'',closeReason:poll.closeReason||'',winnerOptionId:poll.winnerOptionId||'',winnerResolvedAt:dateMillis(poll.winnerResolvedAt),version:Number(poll.version),serverTime:Date.now()},options,myVote:myVote?myVote.optionId:''};
 }
 const getPoll=(uid,p,env)=>mutatePoll(uid,p,env,'GET');
 return {candidates,record,history,createPoll,getPoll,mutatePoll};
}
module.exports={createStage6Services};
