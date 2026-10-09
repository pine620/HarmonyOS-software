'use strict';
// User-run regression tests. No cloud SDK, credentials, network, or devices.
const test=require('node:test');
const assert=require('node:assert/strict');
const {timestampPage,afterTuple,hash}=require('../cloudfunctions/shike-service/stages47-common');
const {mediaVariant,sameMediaSource,verifyMediaBytes}=require('../cloudfunctions/shared/media-descriptor');
const {dateMillis}=require('../cloudfunctions/shared/content-policy');
const crypto=require('node:crypto');
const {createStage7Services}=require('../cloudfunctions/shike-service/stage7-services');
const {createPersonalCollections}=require('../cloudfunctions/shike-service/personal-collections');
const {createStage1Services}=require('../cloudfunctions/shike-service/stage1-services');

test('Cloud DB Long timestamps are accepted without coercing invalid values',()=>{
 for(const value of [0,100,1791470500000]){
  assert.equal(dateMillis(value),value);
  assert.equal(dateMillis(String(value)),value);
  assert.equal(dateMillis(new Date(value)),value);
 }
 assert.equal(dateMillis(String(Number.MAX_SAFE_INTEGER)),Number.MAX_SAFE_INTEGER);
 for(const invalid of ['', ' ', '1e3', '12.5', '-1', 'Infinity', '9007199254740992', null, undefined, true, {}, new Date(NaN)])assert.equal(dateMillis(invalid),null);
});

test('collection pagination continues across string Long frontiers after deletion',async()=>{
 let rows=[{id:'a',createdAt:'100'},{id:'b',createdAt:'100'},{id:'c',createdAt:'100'},{id:'d',createdAt:'90'},{id:'future',createdAt:'1100'}];
 const query=()=>{let max=Infinity,size=100;const api={
  lessThanOrEqualTo:(_field,value)=>{assert.equal(typeof value,'number');max=value;return api;},
  limit:value=>{size=value;return api;},
  get:async()=>rows.filter(row=>Number(row.createdAt)<=max).slice(0,size)
 };return api;};
 const first=await timestampPage(query(),null,1000,2,'id','createdAt');
 assert.deepEqual(first.rows.map(row=>row.id),['a','b']);
 assert.equal(first.next.lastStamp,100);
 rows=rows.filter(row=>row.id!=='a');
 const second=await timestampPage(query(),first.next,1000,2,'id','createdAt');
 assert.deepEqual(second.rows.map(row=>row.id),['c','d']);assert.equal(second.next,null);
});

test('historical readiness uses one bounded query and requires verified completion',async()=>{
 let calls=0,selected=[];
 const makeJob=(type,coverage)=>({jobId:crypto.createHash('sha256').update(type+':stage1-v1:1').digest('hex'),jobType:type,status:'DONE',generation:1,
  checkpointJson:JSON.stringify({coverageComplete:coverage,failures:0,verificationMissing:0})});
 const rows=[makeJob('BACKFILL_CARD',true),makeJob('MIGRATE_REACTION',false)];
 const query={in:(field,ids)=>{assert.equal(field,'jobId');selected=ids;return query;},limit:size=>{assert.equal(size,2);return query;},
  get:async()=>{calls++;return rows.filter(row=>selected.includes(row.jobId));}};
 const service=createStage1Services({collection:()=>({query:()=>query})});
 const readiness=await service.migrationReadiness({SHIKE_INDEXED_QUERY_VERIFIED:'true'},true);
 assert.equal(calls,1);assert.equal(readiness.jobs.length,2);
 assert.equal(readiness.cardCoverageComplete,true);assert.equal(readiness.reactionCoverageComplete,false);assert.equal(readiness.indexedQueryReady,false);
 rows[1].checkpointJson=JSON.stringify({coverageComplete:true,failures:0,verificationMissing:0});
 assert.equal((await service.migrationReadiness({SHIKE_INDEXED_QUERY_VERIFIED:'true'})).indexedQueryReady,true);
});

test('media integrity errors identify the failed check without exposing image data',()=>{
 const bytes=Buffer.from([0xff,0xd8,0xff,0xe0,0xff,0xd9]);
  assert.throws(()=>verifyMediaBytes(bytes,{byteSize:7}),{code:'MEDIA_INTEGRITY_FAILED',integrityCheck:'SIZE_MISMATCH'});
  assert.throws(()=>verifyMediaBytes(Buffer.from('abcdef'),{byteSize:6}),{code:'MEDIA_INTEGRITY_FAILED',integrityCheck:'JPEG_MARKERS'});
  assert.throws(()=>verifyMediaBytes(bytes,{byteSize:6,sha256:'0'.repeat(64)}),{code:'MEDIA_INTEGRITY_FAILED',integrityCheck:'SHA256_MISMATCH'});
});

test('ascending Date queues continue across equal timestamps and exclude future rows',async()=>{
 let rows=[{id:'a',submittedAt:new Date(100)},{id:'b',submittedAt:new Date(100)},{id:'c',submittedAt:new Date(100)},{id:'d',submittedAt:new Date(200)},{id:'e',submittedAt:new Date(300)},{id:'future',submittedAt:new Date(1100)}];
 const query=()=>{let min=0,max=Infinity,size=100;const api={
  greaterThanOrEqualTo:(_key,value)=>{assert.ok(value instanceof Date);min=value.getTime();return api;},
  lessThanOrEqualTo:(_key,value)=>{assert.ok(value instanceof Date);max=value.getTime();return api;},
  limit:value=>{size=value;return api;},
  get:async()=>rows.filter(row=>row.submittedAt.getTime()>=min&&row.submittedAt.getTime()<=max).slice(0,size)
 };return api;};
 const first=await timestampPage(query(),null,1000,2,'id','submittedAt',true,true);
 assert.deepEqual(first.rows.map(row=>row.id),['a','b']);
 rows=rows.filter(row=>row.id!=='a');
 const second=await timestampPage(query(),first.next,1000,2,'id','submittedAt',true,true);
 assert.deepEqual(second.rows.map(row=>row.id),['c','d']);
 const third=await timestampPage(query(),second.next,1000,2,'id','submittedAt',true,true);
 assert.deepEqual(third.rows.map(row=>row.id),['e']);assert.equal(third.next,null);
});

test('rankings can open while map and reaction product gates remain closed',async()=>{
 const query={equalTo:()=>query,limit:()=>query,get:async()=>[]};
 const service=createStage7Services({collection:()=>({query:()=>query}),one:async q=>(await q.get())[0]||null,
  stage1:()=>({migrationReadiness:async()=>({cardCoverageComplete:true,reactionCoverageComplete:false})}),
  stage3:()=>({capabilities:async()=>({searchEnabled:false,mapEnabled:false})}),collections:()=>({enabled:()=>true})});
 const caps=await service.capabilities('',{SHIKE_RANKINGS_VERIFIED:'true',SHIKE_INDEXED_QUERY_VERIFIED:'true',SHIKE_STAGE3_MAP_COORDINATE_SYSTEM:'GCJ02',SHIKE_REACTION_VERIFIED:'false'});
 assert.equal(caps.rankingsEnabled,true);assert.equal(caps.merchantEnabled,false);assert.equal(caps.reactionsEnabled,false);
});

function collectionFixture(hasLegacyWanted){
 class MaintenanceJob{};class UserProfile{};
 const data={MaintenanceJob:[],FoodList:[],PersonalFoodState:hasLegacyWanted?[{ownerUid:'viewer',state:'WANT_TO_EAT'}]:[]};
 const owner={uid:'viewer',updatedAt:100};
 const collection=(_env,name)=>({query:()=>{let size=100;const filters=[];const q={equalTo:(field,value)=>{filters.push([field,value]);return q;},limit:value=>{size=value;return q;},get:async()=>data[name].filter(row=>filters.every(([field,value])=>row[field]===value)).slice(0,size)};return q;},
  runTransaction:async({apply})=>apply({executeQuery:q=>q.get(),executeUpsert:rows=>{for(const row of rows)if(row instanceof MaintenanceJob){const index=data.MaintenanceJob.findIndex(old=>old.jobId===row.jobId);if(index<0)data.MaintenanceJob.push(row);else data.MaintenanceJob[index]=row;}}})});
 const ctx={collection,one:async q=>(await q.limit(1).get())[0]||null,models:{MaintenanceJob,UserProfile},
  stage1:()=>({activeProfile:async()=>owner,txOne:async(tx,env,name,field,value)=>(await tx.executeQuery(collection(env,name).query().equalTo(field,value).limit(1)))[0]||null,upsertRows:(tx,rows)=>tx.executeUpsert(rows)}),
  logicalWriteTime:at=>at+1,profileForWrite:row=>row,contentPolicy:()=>({assertAccountActive:async()=>{}})};
 return createPersonalCollections(ctx);
}
test('an empty legacy source initializes collections immediately',async()=>{
 const service=collectionFixture(false),env={SHIKE_COLLECTIONS_VERIFIED:'true'};
 const result=await service.start('viewer',env);assert.equal(result.status,'DONE');assert.equal(result.collectionReady,true);
 const again=await service.start('viewer',env);assert.equal(again.status,'DONE');assert.equal(again.importedFavorites,0);
});
test('legacy wanted rows require migration rather than being marked complete',async()=>{
 const result=await collectionFixture(true).start('viewer',{SHIKE_COLLECTIONS_VERIFIED:'true'});
 assert.equal(result.status,'PENDING');assert.equal(result.collectionReady,false);
});

test('ordinary prepared digest remains readable when sensitive fields are blank',()=>{
 const sha='a'.repeat(64),media={preparedSha256:sha,sha256:'',objectKey:'',byteSize:100,width:800,height:600};
 assert.equal(mediaVariant(media).sha256,sha);
 const cover={...media,coverRecipeVersion:1,coverSourceSha256:sha,coverSha256:'b'.repeat(64),coverByteSize:50,coverWidth:480,coverHeight:360};
 assert.equal(mediaVariant(cover,'COVER_480').sha256,'b'.repeat(64));
 assert.throws(()=>mediaVariant({...cover,coverSourceSha256:'c'.repeat(64)},'COVER_480'),{code:'MEDIA_VARIANT_UNAVAILABLE'});
});

test('legacy unknown digest is omitted and actual bytes determine the version',()=>{
 const media={sha256:'',byteSize:6,width:1,height:1},descriptor=mediaVariant(media);
 assert.equal(Object.hasOwn(JSON.parse(JSON.stringify(descriptor)),'sha256'),false);
 const bytes=Buffer.from([0xff,0xd8,0xff,0xe0,0xff,0xd9]);
 const actual=crypto.createHash('sha256').update(bytes).digest('hex');
 assert.equal(verifyMediaBytes(bytes,descriptor),actual);
 assert.throws(()=>verifyMediaBytes(bytes,descriptor,'0'.repeat(64)),{code:'MEDIA_VERSION_STALE'});
 assert.throws(()=>verifyMediaBytes(bytes,{...descriptor,sha256:'0'.repeat(64)}),{code:'MEDIA_INTEGRITY_FAILED'});
 assert.throws(()=>verifyMediaBytes(bytes,{...descriptor,byteSize:7}),{code:'MEDIA_INTEGRITY_FAILED'});
 assert.throws(()=>verifyMediaBytes(Buffer.from('abcdef'),descriptor),{code:'MEDIA_INTEGRITY_FAILED'});
 const backfilled={...media,coverRecipeVersion:1,coverSourceSha256:actual,coverSha256:'b'.repeat(64),coverByteSize:6,coverWidth:1,coverHeight:1};
 assert.equal(mediaVariant(backfilled).sha256,actual);
 assert.equal(mediaVariant(backfilled,'COVER_480').sha256,'b'.repeat(64));
});

test('media final check rejects changed ownership, storage, size or ordinary digest',()=>{
 const source={id:'m',cardId:'c',ownerUid:'u',storageUid:'s',status:'APPROVED',createdAt:1,byteSize:6,width:1,height:1,preparedSha256:'a'.repeat(64),sha256:''};
 assert.equal(sameMediaSource({...source,sha256:undefined},source),true);
 for(const update of [{cardId:'c2'},{ownerUid:'u2'},{storageUid:'s2'},{status:'DELETED'},{byteSize:8},{preparedSha256:'b'.repeat(64)}]){
  assert.equal(sameMediaSource({...source,...update},source),false);
 }
});

// In-memory query double evaluates ordinary groups/ranges and deliberately has
// no SDK pagination method. This validates equal-key boundaries without AGC.
function rangeQuery(rows){
 const stack=[{parts:[],op:'and'}],orders=[];let size=Infinity;
 function add(predicate){const group=stack[stack.length-1];group.parts.push({predicate,op:group.op});group.op='and';}
 const compare=(field,value,operator)=>{add(row=>operator(row[field]?.valueOf(),value?.valueOf()));return q;};
 const q={and:()=>{stack[stack.length-1].op='and';return q;},or:()=>{stack[stack.length-1].op='or';return q;},
  beginGroup:()=>{stack.push({parts:[],op:'and'});return q;},endGroup:()=>{const group=stack.pop();add(row=>group.parts.reduce((result,part,index)=>index===0?part.predicate(row):part.op==='or'?result||part.predicate(row):result&&part.predicate(row),true));return q;},
  equalTo:(field,value)=>compare(field,value,(a,b)=>a===b),greaterThan:(field,value)=>compare(field,value,(a,b)=>a>b),lessThan:(field,value)=>compare(field,value,(a,b)=>a<b),
  orderByAsc:field=>{orders.push([field,1]);return q;},orderByDesc:field=>{orders.push([field,-1]);return q;},limit:value=>{size=value;return q;},
  get:async()=>rows.filter(row=>stack[0].parts.every(part=>part.predicate(row))).sort((a,b)=>{for(const [field,sign]of orders){if(a[field]<b[field])return -sign;if(a[field]>b[field])return sign;}return 0;}).slice(0,size)};
 return q;
}

test('mixed-direction ranking ranges include every following tied record',async()=>{
 const rows=[{id:'a',tasteScore:9,publishedAt:new Date(200)},{id:'b',tasteScore:9,publishedAt:new Date(200)},{id:'c',tasteScore:9,publishedAt:new Date(200)},{id:'d',tasteScore:9,publishedAt:new Date(100)},{id:'e',tasteScore:8,publishedAt:new Date(300)},{id:'f',tasteScore:10,publishedAt:new Date(100)}];
 let query=rangeQuery(rows);query=afterTuple(query,[['tasteScore','DESC'],['publishedAt','DESC'],['id','ASC']],rows[1]);
 const result=await query.orderByDesc('tasteScore').orderByDesc('publishedAt').orderByAsc('id').get();
 assert.deepEqual(result.map(row=>row.id),['c','d','e']);
});

test('wanted migration restarts an old checkpoint once and deduplicates imports',async()=>{
 class MaintenanceJob{};class CardAction{};class PublishRequestRecord{};
 const uid='viewer',a='00000000-0000-4000-8000-000000000001',b='00000000-0000-4000-8000-000000000002';
 const parentId=hash(['MIGRATE_PERSONAL_COLLECTION',uid,1]);
 const actionId=(kind,actor,card)=>hash([kind,actor,card]);
 const data={MaintenanceJob:[Object.assign(new MaintenanceJob(),{jobId:parentId,jobType:'MIGRATE_PERSONAL_COLLECTION',generation:1,ownerUid:uid,status:'PENDING',leaseOwner:'',leaseUntilAt:null,checkpointJson:JSON.stringify({phase:'WANTED',stateBoundary:{ownerUid:uid,cardId:b,updatedAt:100},scanned:1,createdFavorites:0,createdWanted:1,batches:1})})],
  PersonalFoodState:[{ownerUid:uid,cardId:a,state:'WANT_TO_EAT',updatedAt:new Date(100)},{ownerUid:uid,cardId:b,state:'WANT_TO_EAT',updatedAt:new Date(100)}],
  PublishRequestRecord:[],CardAction:[Object.assign(new CardAction(),{id:actionId('card:WANT_TO_EAT',uid,b),actorUid:uid,cardId:b,kind:'WANT_TO_EAT',createdAt:100})]};
 const owner={uid,updatedAt:Date.now()};
 const put=rows=>{for(const row of rows){const name=row.constructor.name,key=name==='MaintenanceJob'?'jobId':name==='PublishRequestRecord'?'requestId':'id';if(!data[name])continue;const index=data[name].findIndex(old=>old[key]===row[key]);if(index<0)data[name].push(row);else data[name][index]=row;}};
 const collection=(_env,name)=>({query:()=>rangeQuery(data[name]||[]),runTransaction:async({apply})=>apply({executeQuery:q=>q.get(),executeUpsert:put})});
 const ctx={collection,one:async q=>(await q.limit(1).get())[0]||null,models:{MaintenanceJob,CardAction,PublishRequestRecord},actionId,
  stage1:()=>({activeProfile:async()=>owner,txOne:async(tx,env,name,field,value)=>(await tx.executeQuery(collection(env,name).query().equalTo(field,value).limit(1)))[0]||null,upsertRows:(tx,rows)=>tx.executeUpsert(rows)}),
  logicalWriteTime:at=>at+1,profileForWrite:row=>row,contentPolicy:()=>({assertAccountActive:async()=>{}})};
 const service=createPersonalCollections(ctx),env={SHIKE_COLLECTIONS_VERIFIED:'true'},requestId='00000000-0000-4000-8000-000000000003';
 const result=await service.resume(uid,{requestId},env);
 assert.equal(result.status,'DONE');assert.equal(result.importedWanted,2);
 assert.deepEqual(data.CardAction.map(row=>row.cardId).sort(),[a,b]);
 assert.equal(JSON.parse(data.MaintenanceJob.find(row=>row.jobId===parentId).checkpointJson).wantedOrderVersion,2);
 const again=await service.resume(uid,{requestId},env);assert.equal(again.importedWanted,2);assert.equal(data.CardAction.length,2);
});
