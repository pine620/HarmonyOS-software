'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {createImageReader}=require('../cloudfunctions/shared/image-reader');
const mediaId='d0000000-0000-4000-8000-000000000010',reportId='a'.repeat(64);
function fixture(){
  const rows={IdentityBinding:[],Report:[{id:reportId,cardId:'card',targetType:'CARD',status:'PENDING'}],FoodCard:[{id:'card',ownerUid:'author',schemaVersion:2,status:'REMOVED',reviewState:'TAKEN_DOWN',updatedAt:1}],
    CardMedia:[{id:mediaId,cardId:'card',ownerUid:'author',status:'APPROVED',sha256:'b'.repeat(64),byteSize:100,width:10,height:10}],UserProfile:[{uid:'author',accountStatus:'ACTIVE'},{uid:'reviewer',accountStatus:'ACTIVE'},{uid:'reader',accountStatus:'ACTIVE'}],FoodCardRevision:[]};
  let allowed=true;
  const collection=name=>({query:()=>{const predicates=[];let size=100;const q={in:(key,values)=>{predicates.push(row=>values.includes(row[key]));return q;},equalTo:(key,value)=>{predicates.push(row=>row[key]===value);return q;},limit:value=>{size=value;return q;},get:async()=>(rows[name] || []).filter(row=>predicates.every(p=>p(row))).slice(0,size)};return q;}});
  const reader=createImageReader({collection,verifyToken:async uid=>uid,isCardReviewer:uid=>allowed && uid==='reviewer',download:async()=>{throw new Error('metadata authorization must not download bytes');},shouldLogMetrics:()=>false});
  const request=(uid,mode='REPORT')=>({protocolVersion:'image-read-v1',accessToken:uid,items:[{mediaId,mode,revisionId:mode==='REPORT'?reportId:'',variant:'ORIGINAL',wantBytes:false}]});
  return {rows,reader,request,revoke:()=>{allowed=false;}};
}
test('down-card photos need an active configured reviewer and a matching report',async()=>{
  const f=fixture();assert.equal((await f.reader.readBatch(f.request('reviewer'))).items[0].status,'VERSION_CHANGED');
  assert.equal((await f.reader.readBatch(f.request('reader'))).items[0].status,'DENIED');
  assert.equal((await f.reader.readBatch(f.request('reader','PUBLIC'))).items[0].status,'DENIED');
  f.rows.Report[0].cardId='another-card';assert.equal((await f.reader.readBatch(f.request('reviewer'))).items[0].status,'DENIED');
});
test('revocation, deletion and retired correction access do not reuse report privileges',async()=>{
  const f=fixture();assert.equal((await f.reader.readBatch(f.request('reviewer','REVIEW'))).items[0].status,'DENIED');
  f.rows.FoodCard[0].deletedAt=new Date();assert.equal((await f.reader.readBatch(f.request('reviewer'))).items[0].status,'DENIED');
  delete f.rows.FoodCard[0].deletedAt;f.revoke();assert.equal((await f.reader.readBatch(f.request('reviewer'))).items[0].status,'DENIED');
});
