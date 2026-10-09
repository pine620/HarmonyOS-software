'use strict';
const crypto=require('crypto');
const {dateMillis}=require('./shared/content-policy');
const {fail,hash,int,version,token,encode,preference,preferenceView,hasPreference,score,friendsAllowed}=require('./stages47-common');
function createStage4Services(ctx) {
 const {collection,one,models}=ctx; const model=(name,row)=>Object.assign(new models[name](),row);
 async function get(uid,env) { await ctx.contentPolicy(env).assertAccountActive(uid);return preferenceView(await one(collection(env,'TastePreference').query().equalTo('uid',uid))); }
 async function update(uid,payload,env,clear=false) {
  let result;
  const committed=await collection(env,'TastePreference').runTransaction({apply:async tx=>{
   const owner=await ctx.stage1().activeProfile(tx,uid,env);const old=await ctx.stage1().txOne(tx,env,'TastePreference','uid',uid);version(payload.version,old);
   let data=clear?preferenceView(old):preference(payload);
   if(clear){const field=payload.field || 'ALL';if(!['ALL','LIKED','LESS','MODE','BUDGET'].includes(field))throw fail('清除项无效。');data={...data};if(field==='ALL')data=preference({});if(field==='LIKED')data.likedCategories=[];if(field==='LESS')data.lessCategories=[];if(field==='MODE')data.preferredMode='ANY';if(field==='BUDGET'){data.budgetMinFen=null;data.budgetMaxFen=null;}}
   const now=ctx.logicalWriteTime(owner.updatedAt,dateMillis(old&&old.updatedAt));
   const row=model('TastePreference',{uid,likedCategoriesJson:JSON.stringify(data.likedCategories),lessCategoriesJson:JSON.stringify(data.lessCategories),preferredMode:data.preferredMode,budgetMinFen:data.budgetMinFen,budgetMaxFen:data.budgetMaxFen,version:Number(old&&old.version||0)+1,updatedAt:new Date(now)});
   ctx.stage1().upsertRows(tx,[row,ctx.profileForWrite(owner,now)]);result=preferenceView(row);return true;
  }});if(!committed)throw fail('偏好未保存，请重试。','CONFLICT');return result;
 }
 async function recommendations(uid,payload,env) {
  const p=uid?await ctx.withReadPhase('preferences',()=>get(uid,env)):{...preference(payload.preference||{}),version:0};
  const size=int(payload.pageSize===undefined?6:payload.pageSize,1,30);const signature=hash({uid,p,kind:'recommendations'});
  let saved=token(payload.cursor,signature); const at=saved?saved.at:Date.now();const seed=saved?saved.seed:crypto.randomBytes(12).toString('hex');
  if(saved && (!Array.isArray(saved.order)||saved.order.length>400||!saved.order.every(x=>x && typeof x.id==='string' && typeof x.explore==='boolean')||new Set(saved.order.map(x=>x.id)).size!==saved.order.length||!Number.isSafeInteger(saved.position)||saved.position<0||saved.position>saved.order.length||typeof seed!=='string'||seed.length>64))throw fail('推荐分页失效。','CURSOR_STALE');
  if(!saved){
   // Use the deployed status_createdAt_desc index for the bounded snapshot.
   // Reserve the other new index for stable owner pagination; never alter an existing index.
   // Published-time ordering stays inside this pool. No action/state/history data is read for scores.
   const caps=await ctx.stage3().capabilities(env);
   const raw=await ctx.withReadPhase('candidates',()=>collection(env,'FoodCard').query().equalTo('status','APPROVED').lessThanOrEqualTo('createdAt',at).orderByDesc('createdAt').orderByAsc('id').limit(400).get());
   ctx.recordReadCounts({scannedCandidateCount:raw.length});
   const candidates=raw.filter(r=>{const published=dateMillis(r.publishedAt);return friendsAllowed(env,r) && (!caps.searchEnabled || published!==null && published<=at);});
   if(caps.searchEnabled)candidates.sort((a,b)=>dateMillis(b.publishedAt)-dateMillis(a.publishedAt) || a.id.localeCompare(b.id));
   const readable=await ctx.withReadPhase('candidate-permissions',()=>ctx.readableCardRows(candidates,uid,env,!uid));
   ctx.recordReadCounts({eligibleCandidateCount:readable.length});
   let order=readable.map(r=>({id:r.id,explore:false}));
   if(hasPreference(p)){
    const ranked=readable.slice().sort((a,b)=>score(b,p,at).value-score(a,p,at).value || Number(b.createdAt)-Number(a.createdAt) || a.id.localeCompare(b.id));
    const exploratory=readable.slice().sort((a,b)=>Number(p.lessCategories.includes(a.categoryV2))-Number(p.lessCategories.includes(b.categoryV2)) || hash([seed,a.id]).localeCompare(hash([seed,b.id])));
    const used=new Set();order=[];let normal=0,explore=0;
    for(let i=0;i<ranked.length;i++) {const exploration=i%6===5;const pool=exploration?exploratory:ranked;let selected;
     if(exploration){while(explore<pool.length && used.has(pool[explore].id))explore++;selected=pool[explore++];}
     else{while(normal<pool.length && used.has(pool[normal].id))normal++;selected=pool[normal++];}
     if(selected){used.add(selected.id);order.push({id:selected.id,explore:exploration});}
    }
   }
   saved={order,position:0,seed,scanned:raw.length,coverage:raw.length===400?'PARTIAL_SCAN_LIMIT':'COMPLETE'};
  }
  let cards=[];const reasons=new Map(),sources=new Map(),fetchedIds=new Set();let position=saved.position,consumed=0;
  ctx.recordReadCounts({scannedCandidateCount:saved.scanned});
  // Prefetch up to ten IDs, but consume only visited positions; unused rows stay on the next page.
  // Deleted/denied/changed rows consume their position. Refill is bounded per response.
  while(position<saved.order.length && cards.length<size && consumed<60){
   await ctx.withReadPhase('assembly',async()=>{
    while(position<saved.order.length && cards.length<size && consumed<60){
     const count=Math.min(10,60-consumed);
     const entries=saved.order.slice(position,position+count);
     for(const entry of entries)fetchedIds.add(entry.id);
     ctx.recordReadCounts({fetchedCandidateCount:fetchedIds.size,consumedCandidateCount:consumed});
     const byId=await ctx.readCardRowsByIds(entries.map(entry=>entry.id),env);
     const rows=entries.map(entry=>byId.get(entry.id)).filter(row=>row&&friendsAllowed(env,row));
     const context=await ctx.createCardReadContext(rows,uid,env);
     const readable=await ctx.readableCardRows(rows,uid,env,!uid,context);
     await ctx.preparePrimaryPhotos(context,readable,env);
     for(const entry of entries){
      if(cards.length===size)break;
      position++;consumed++;const row=byId.get(entry.id);
      if(!row||!friendsAllowed(env,row))continue;
      const card=await ctx.readCardIfAllowed(row,env,0,true,uid,false,1,null,context);
      if(!card)continue;
      cards.push(card);sources.set(card.id,row);
      reasons.set(card.id,{cardId:row.id,reasons:entry.explore?['探索推荐']:score(row,p,at).reasons,exploration:entry.explore});
     }
     ctx.recordReadCounts({consumedCandidateCount:consumed});
    }
   });
   // A new authority context on EVERY final pass, including after a refill.
   cards=await ctx.withReadPhase('final-check',()=>ctx.finalizeCardReads(cards,[...sources.values()],uid,env));
  }
  return {cards,reasons:cards.map(card=>reasons.get(card.id)),seed,nextCursor:position<saved.order.length?encode(signature,at,{...saved,position}):'',coverage:saved.coverage,scannedCandidateCount:saved.scanned,consumedCandidateCount:consumed,fetchedCandidateCount:fetchedIds.size,sessionExhausted:position===saved.order.length};
 }
 return {get,update,recommendations};
}
module.exports={createStage4Services};
