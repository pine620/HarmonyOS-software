'use strict';
const { dateMillis } = require('./shared/content-policy');
const { fail, hash, id, token, encode, timestampPage } = require('./stages47-common');
function createContentStatusServices(ctx) {
  const { collection, one, models } = ctx;
  const model = (name, values) => Object.assign(new models[name](), values);
  const txOne = (...args) => ctx.stage1().txOne(...args);
  const save = (tx, rows) => ctx.stage1().upsertRows(tx, rows);
  const version = row => dateMillis(row.updatedAt) || dateMillis(row.reviewedAt) || dateMillis(row.submittedAt) || Number(row.createdAt || 0);
  function rowView(kind, row) {
    const targetId = kind === 'REPORT' ? String(row.targetId || row.cardId || '') : kind === 'REVISION' ? row.cardId : row.id;
    return { id: String(row.revisionId || row.id), kind, targetId, version: version(row),
      title: kind === 'CARD' ? String(row.productName || '卡片') : kind === 'REVISION' ? '卡片编辑版本' : (row.targetType === 'MERCHANT' ? '商家举报' : '卡片举报'),
      state: String(row.reviewState || row.status || ''),
      reason: String(row.reviewReason || row.resolutionReason || row.reason || ''), createdAt: dateMillis(row.submittedAt) || dateMillis(row.createdAt) || 0 };
  }
  async function reports(uid,payload,env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const signature=hash(['myReports-v1',uid]),saved=token(payload.cursor,signature),at=saved?saved.at:Date.now();
    const query=collection(env,'Report').query().equalTo('reporterUid',uid).orderByDesc('createdAt');
    const page=await timestampPage(query,saved,at,12,'id','createdAt');
    await ctx.contentPolicy(env).assertAccountActive(uid);
    return {items:page.rows.map(row=>rowView('REPORT',row)),nextCursor:page.next?encode(signature,at,page.next):''};
  }
  async function submitReport(uid,payload,env,type='CARD') {
    const targetId=id(payload.targetId||payload.cardId||payload.merchantId);const reason=String(payload.reason||'').trim();if(!reason||reason.length>200)throw fail('请输入 1–200 字举报理由。');
    const key=type==='CARD'?ctx.legacyReportId(uid,targetId):hash(['report',uid,type,targetId]);
    const committed=await collection(env,'Report').runTransaction({apply:async tx=>{
      const owner=await ctx.stage1().activeProfile(tx,uid,env);const old=await txOne(tx,env,'Report','id',key);if(old)return true;
      const target=await txOne(tx,env,type==='CARD'?'FoodCard':'Merchant',type==='CARD'?'id':'merchantId',targetId);
      if(type==='CARD')await ctx.transactionPolicy(tx,env,[owner]).assertCardReadable(uid,target);
      else if(!target||!['VERIFIED_PROVIDER','USER_CONFIRMED_APPROVED'].includes(target.verificationStatus))throw fail('商家不可举报。','CONTENT_UNAVAILABLE');
      const now=ctx.logicalWriteTime(owner.updatedAt);save(tx,[model('Report',{id:key,reporterUid:uid,cardId:type==='CARD'?targetId:'',targetType:type,targetId,reason,status:'PENDING',createdAt:now,updatedAt:now}),ctx.profileForWrite(owner,now)]);return true;
    }});if(!committed)throw fail('举报未保存。','CONFLICT');return {success:true,reportId:key};
  }
  async function ownReviewQueue(uid,payload,env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);const signature=hash(['ownReview',uid]),saved=token(payload.cursor,signature),at=saved?saved.at:Date.now();
    const phase=saved&&saved.phase==='REVISION'?'REVISION':'CARD';
    const query=phase==='CARD'?collection(env,'FoodCard').query().equalTo('ownerUid',uid).equalTo('status','REMOVED').orderByDesc('createdAt'):
      collection(env,'FoodCardRevision').query().equalTo('authorUid',uid).orderByDesc('submittedAt').orderByAsc('revisionId');
    const continuation=saved&&saved.lastStamp!==undefined?saved:null;
    const page=await timestampPage(query,continuation,at,12,phase==='CARD'?'id':'revisionId',phase==='CARD'?'createdAt':'submittedAt',phase==='REVISION');
    const items=[],cards=new Map(),latestByCard=new Map();
    if(phase==='CARD')for(const row of page.rows){if(row.deletedAt==null&&row.reviewState==='REQUEST_CHANGE')items.push(rowView('CARD',row));}
    else for(const row of page.rows){
      if(row.status!=='REJECTED')continue;
      if(!cards.has(row.cardId))cards.set(row.cardId,await one(collection(env,'FoodCard').query().equalTo('id',row.cardId)));
      const card=cards.get(row.cardId);if(!card||card.ownerUid!==uid||!ctx.stage1().editableState(card))continue;
      if(!latestByCard.has(row.cardId))latestByCard.set(row.cardId,await one(collection(env,'FoodCardRevision').query().equalTo('cardId',row.cardId).orderByDesc('submittedAt').orderByAsc('revisionId')));
      const latest=latestByCard.get(row.cardId);if(latest&&latest.revisionId===row.revisionId)items.push(rowView('REVISION',row));
    }
    const next=page.next?{phase,...page.next}:phase==='CARD'?{phase:'REVISION'}:null;
    await ctx.contentPolicy(env).assertAccountActive(uid);return {items,nextCursor:next?encode(signature,at,next):''};
  }


  return {reports,submitReport,ownReviewQueue};
}
module.exports={createContentStatusServices};
