'use strict';
// User-run contracts. These fixtures never contact AGC or storage.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createCardReportServices } = require('../cloudfunctions/shike-service/card-report-services');
const { cardContentRevision, isAccountActive, readableCardState } = require('../cloudfunctions/shared/content-policy');
const crypto = require('node:crypto');
const requestId = 'd0000000-0000-4000-8000-000000000001';
const secondRequest = 'd0000000-0000-4000-8000-000000000002';
function fixture() {
  const now=Date.now()-10000;
  const data={UserProfile:[{uid:'reporter',accountStatus:'ACTIVE',updatedAt:now},{uid:'author',accountStatus:'ACTIVE',publishCount:2,updatedAt:now},{uid:'reviewer',accountStatus:'ACTIVE',updatedAt:now}],
    FoodCard:[{id:'card',ownerUid:'author',productName:'测试卡片',status:'APPROVED',schemaVersion:2,reviewState:'PENDING_POST_REVIEW',updatedAt:now,createdAt:now,lifecycleGeneration:0}],Report:[],CardMedia:[],Merchant:[]};
  let queued=false; let commits=0;
  class Query {
    constructor(name){this.name=name;this.filters=[];this.size=100;this.sort='';}
    equalTo(key,value){this.filters.push(row=>row[key]===value);return this;}
    in(key,values){this.filters.push(row=>values.includes(row[key]));return this;}
    lessThanOrEqualTo(key,value){this.filters.push(row=>Number(row[key])<=Number(value));return this;}
    orderByDesc(key){this.sort=key;return this;}
    orderByAsc(){return this;}
    limit(size){this.size=size;return this;}
    async get(){const rows=(data[this.name] || []).filter(row=>this.filters.every(filter=>filter(row))).map(row=>({...row}));if(this.sort)rows.sort((a,b)=>Number(b[this.sort])-Number(a[this.sort]));return rows.slice(0,this.size);}
  }
  const models={};for(const name of Object.keys(data)) models[name]=class {getClassName(){return name;}};
  const collection=(_env,name)=>({query:()=>new Query(name),runTransaction:async ({apply})=>{
    const writes=[];queued=false;
    const tx={executeQuery:async query=>{assert.equal(queued,false,'all authority/counter reads must precede writes');return query.get();},executeUpsert:rows=>{queued=true;writes.push(...rows);}};
    const ok=await apply(tx);if(ok){for(const row of writes){const name=row.getClassName(),key=name==='UserProfile'?'uid':name==='Merchant'?'merchantId':'id';const rows=data[name];const at=rows.findIndex(value=>value[key]===row[key]);if(at<0)rows.push({...row});else rows[at]={...row};}commits++;}return ok;
  }});
  const one=async query=>(await query.limit(1).get())[0] || null;
  const stage1={txOne:async(tx,env,name,field,value)=>oneTx(tx,collection(env,name).query().equalTo(field,value)),activeProfile:async(tx,uid,env)=>{const row=await stage1.txOne(tx,env,'UserProfile','uid',uid);if(!isAccountActive(row))throw Object.assign(new Error('inactive'),{code:'ACCOUNT_INACTIVE'});return row;},upsertRows:(tx,rows)=>{for(const row of rows)tx.executeUpsert([row]);}};
  async function oneTx(tx,query){return (await tx.executeQuery(query.limit(1)))[0] || null;}
  const ctx={collection,one,models,stage1:()=>stage1,stage2:()=>counterServices,
    contentPolicy:()=>({assertAccountActive:async uid=>{if(!isAccountActive(data.UserProfile.find(row=>row.uid===uid)))throw Object.assign(new Error('inactive'),{code:'ACCOUNT_INACTIVE'});}}),
    transactionPolicy:()=>({assertCardReadable:async(_uid,card)=>{if(!readableCardState(card))throw Object.assign(new Error('unavailable'),{code:'CONTENT_UNAVAILABLE'});}}),
    logicalWriteTime:(...values)=>Math.max(Date.now(),...values.filter(value=>value!=null).map(value=>Number(value)+1)),profileForWrite:(row,time)=>Object.assign(new models.UserProfile(),row,{updatedAt:time}),refreshPublishCount:async()=>{},
    legacyReportId:(uid,id)=>crypto.createHash('sha256').update(uid+':'+id).digest('hex')};
  const counterServices=require('../cloudfunctions/shike-service/stage2-services').createStage2Services(ctx);
  const env={SHIKE_CARD_REVIEW_ADMIN_UIDS:'["reviewer"]',SHIKE_CURSOR_SIGNING_KEY:'user-test-key-at-least-32-characters'};
  const service=createCardReportServices(ctx);
  const submit=()=>({cardId:'card',expectedRevision:cardContentRevision(data.FoodCard[0]),reasonType:'INACCURATE',description:'价格与图片不符',requestId});
  const resolve=(report,action='TAKE_DOWN')=>({reportId:report.id,expectedReportVersion:Number(report.updatedAt),expectedCardRevision:cardContentRevision(data.FoodCard[0]),action,reason:'核对后确认内容不准确',requestId:secondRequest});
  return {data,service,env,submit,resolve,commits:()=>commits};
}
test('default deny and canonical allowlist; payload cannot grant review permission',async()=>{
  const f=fixture();assert.equal((await f.service.access('reporter',f.env,false)).allowed,false);
  assert.equal((await f.service.access('reviewer',{SHIKE_CARD_REVIEW_ADMIN_UIDS:''},false)).allowed,false);
  await assert.rejects(f.service.list('reporter',{status:'PENDING',admin:true,uid:'reviewer'},f.env,true),{code:'ADMIN_REQUIRED'});
  assert.equal((await f.service.access('reviewer',f.env,false)).allowed,true);
});
test('same card revision deduplicates, a later content revision may be reported again',async()=>{
  const f=fixture();const first=await f.service.submit('reporter',f.submit(),f.env);
  assert.equal((await f.service.submit('reporter',{...f.submit(),requestId:secondRequest},f.env)).reportId,first.reportId);assert.equal(f.data.Report.length,1);
  f.data.FoodCard[0].updatedAt+=100;
  await f.service.submit('reporter',{...f.submit(),requestId:secondRequest},f.env);assert.equal(f.data.Report.length,2);
});
test('a legacy pending card report is reused rather than silently duplicated',async()=>{
  const f=fixture();const id=crypto.createHash('sha256').update('reporter:card').digest('hex');f.data.Report.push({id,reporterUid:'reporter',cardId:'card',reason:'旧举报',status:'PENDING',createdAt:Date.now()-1000});
  assert.equal((await f.service.submit('reporter',f.submit(),f.env)).reportId,id);assert.equal(f.data.Report.length,1);
});
test('only the reporter can read their record; non-card history stays outside the new queue',async()=>{
  const f=fixture();const result=await f.service.submit('reporter',f.submit(),f.env);
  await assert.rejects(f.service.detail('author',{reportId:result.reportId},f.env),{code:'CONTENT_ACCESS_DENIED'});
  f.data.Report.push({id:'merchant-report',reporterUid:'reporter',targetType:'MERCHANT',status:'PENDING',createdAt:Date.now()-1000});
  const page=await f.service.list('reporter',{status:'PENDING'},f.env);assert.equal(page.items.length,1);assert.equal(page.items[0].id,result.reportId);
});
test('take down is atomic, audited and idempotent; no account punishment is written',async()=>{
  const f=fixture();await f.service.submit('reporter',f.submit(),f.env);const payload=f.resolve(f.data.Report[0]);
  const result=await f.service.resolve('reviewer',payload,f.env);assert.equal(result.action,'TAKE_DOWN');
  assert.equal(f.data.FoodCard[0].status,'REMOVED');assert.equal(f.data.FoodCard[0].reviewState,'TAKEN_DOWN');assert.equal(f.data.FoodCard[0].lifecycleGeneration,1);
  assert.equal(f.data.Report[0].status,'RESOLVED');assert.equal(f.data.Report[0].resolvedByUid,'reviewer');assert.ok(Number(f.data.Report[0].resolvedAt)>0);
  assert.equal(f.data.UserProfile.find(row=>row.uid==='author').publishCount,1);assert.ok(f.data.UserProfile.every(row=>row.accountStatus==='ACTIVE'));
  assert.equal((await f.service.resolve('reviewer',payload,f.env)).action,'TAKE_DOWN');
  await assert.rejects(f.service.resolve('reviewer',{...payload,requestId,action:'KEEP'},f.env),{code:'ALREADY_RESOLVED'});
});
test('keep closes just the report; stale content cannot be taken down from an old review',async()=>{
  const f=fixture();await f.service.submit('reporter',f.submit(),f.env);const payload=f.resolve(f.data.Report[0]);f.data.FoodCard[0].updatedAt+=100;
  await assert.rejects(f.service.resolve('reviewer',payload,f.env),{code:'STALE_VERSION'});assert.equal(f.data.Report[0].status,'PENDING');assert.equal(f.data.FoodCard[0].status,'APPROVED');
  await f.service.resolve('reviewer',f.resolve(f.data.Report[0],'KEEP'),f.env);assert.equal(f.data.FoodCard[0].status,'APPROVED');assert.equal(f.data.Report[0].resolutionAction,'KEEP');
});
test('a deleted card keeps a readable report receipt and can be closed without a down action',async()=>{
  const f=fixture();const submitted=await f.service.submit('reporter',f.submit(),f.env);f.data.FoodCard=[];
  const detail=await f.service.detail('reviewer',{reportId:submitted.reportId},f.env,true);assert.equal(detail.card.available,false);
  const request={...f.resolve(f.data.Report[0],'KEEP'),expectedCardRevision:''};
  assert.equal((await f.service.resolve('reviewer',request,f.env)).action,'UNAVAILABLE');
});

test('merchant counts and map eligibility change in the same take-down commit',async()=>{
  const f=fixture();Object.assign(f.data.FoodCard[0],{merchantId:'merchant',consumptionMode:'DINE_IN'});
  f.data.Merchant.push({merchantId:'merchant',publicRecommendationCount:1,publicDineInCount:1,publicDeliveryCount:0,verificationStatus:'VERIFIED_PROVIDER',coordinateSystem:'GCJ02',latitudeE6:30000000,longitudeE6:120000000,mapVisible:true});
  await f.service.submit('reporter',f.submit(),f.env);await f.service.resolve('reviewer',f.resolve(f.data.Report[0]),f.env);
  assert.equal(f.data.Merchant[0].publicRecommendationCount,0);assert.equal(f.data.Merchant[0].publicDineInCount,0);assert.equal(f.data.Merchant[0].mapVisible,false);
});
test('counter failure leaves both the report and card unchanged',async()=>{
  const f=fixture();Object.assign(f.data.FoodCard[0],{merchantId:'missing-merchant',consumptionMode:'DINE_IN'});
  await f.service.submit('reporter',f.submit(),f.env);
  await assert.rejects(f.service.resolve('reviewer',f.resolve(f.data.Report[0]),f.env),{code:'INVALID_STATE'});
  assert.equal(f.data.Report[0].status,'PENDING');assert.equal(f.data.FoodCard[0].status,'APPROVED');
});

test('inherited property names cannot be used as a report category',async()=>{
  const f=fixture();await assert.rejects(f.service.submit('reporter',{...f.submit(),reasonType:'constructor'},f.env),{code:'VALIDATION_ERROR'});assert.equal(f.data.Report.length,0);
});
test('a bounded page of legacy non-card rows retains a usable continuation cursor',async()=>{
  const f=fixture();const {withCursorContext}=require('../cloudfunctions/shike-service/stages47-common');const now=Date.now()-1000;
  for(let i=0;i<49;i++)f.data.Report.push({id:'old-merchant-'+i,reporterUid:'reporter',targetType:'MERCHANT',status:'PENDING',createdAt:now-i});
  f.data.Report.push({id:'legacy-card-record',reporterUid:'reporter',cardId:'card',status:'PENDING',createdAt:now-100});
  const first=await withCursorContext(f.env,()=>f.service.list('reporter',{status:'PENDING'},f.env));assert.equal(first.items.length,0);assert.ok(first.nextCursor);
  const next=await withCursorContext(f.env,()=>f.service.list('reporter',{status:'PENDING',cursor:first.nextCursor},f.env));assert.equal(next.items.length,1);assert.equal(next.items[0].id,'legacy-card-record');
  await assert.rejects(withCursorContext(f.env,()=>f.service.list('author',{status:'PENDING',cursor:first.nextCursor},f.env)),{code:'CURSOR_STALE'});
});
