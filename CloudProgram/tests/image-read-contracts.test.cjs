'use strict';
// User-run tests of the injected core. No cloud SDK, credentials or network.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createImageReader } = require('../cloudfunctions/shared/image-reader');
const { buildInfo } = require('../cloudfunctions/shared/release-info');
const jpeg = Buffer.from([255,216,255,224,255,217]);
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const id = number => '00000000-0000-4000-8000-' + String(number).padStart(12, '0');
const relationshipId = (a,b) => digest('friend:' + [a,b].sort().join(':'));
function fixture(count = 4, cover = true) {
  const db = { IdentityBinding: [], CardMedia: [], FoodCard: [], FoodCardRevision: [],
    UserProfile: [{uid:'viewer',accountStatus:'ACTIVE'},{uid:'author',accountStatus:'ACTIVE'}], Friendship: [] };
  for (let n=1;n<=count;n++) {
    db.CardMedia.push({id:id(n),cardId:'card-'+n,ownerUid:'author',storageUid:'author',status:'APPROVED',createdAt:1,byteSize:jpeg.length,width:100,height:100,preparedSha256:digest(jpeg),
      ...(cover ? {coverRecipeVersion:1,coverSourceSha256:digest(jpeg),coverSha256:digest(jpeg),coverByteSize:jpeg.length,coverWidth:100,coverHeight:100} : {})});
    db.FoodCard.push({id:'card-'+n,ownerUid:'author',status:'APPROVED',schemaVersion:0,updatedAt:1});
  }
  const calls = {db:0,storage:0,auth:0}, hook = {download:async()=>{}, query:async()=>{}};
  const reader = createImageReader({adminUids:['admin'],verifyToken:async token=>{ calls.auth++; if(token==='bad')throw Object.assign(new Error('Bad token'),{code:'AUTH_REQUIRED'}); return 'viewer'; },
    collection:name=>({query:()=>{let filters=[],size=100;const query={in:(field,values)=>{filters.push(row=>values.includes(row[field]));return query;},equalTo:(field,value)=>{filters.push(row=>row[field]===value);return query;},limit:value=>{size=value;return query;},
      get:async()=>{calls.db++;await hook.query(name);return db[name].filter(row=>filters.every(predicate=>predicate(row))).slice(0,size).map(row=>({...row}));}};return query;}}),
    download:async()=>{calls.storage++;await hook.download();return jpeg;}});
  const item = (n, values={}) => ({mediaId:id(n),mode:'PUBLIC',variant:'COVER_480',revisionId:'',wantBytes:true,...values});
  const read = (items, token='token') => reader.readBatch({protocolVersion:'image-read-v1',accessToken:token,items});
  return {db,calls,hook,read,item};
}
test('warm four-cover confirmation uses five DB gets, one auth check, zero bytes',async()=>{
  const f=fixture();const response=await f.read([1,2,3,4].map(n=>f.item(n,{knownSha256:digest(jpeg),knownByteSize:jpeg.length})));
  assert.deepEqual(response.items.map(row=>row.status),['CACHE_OK','CACHE_OK','CACHE_OK','CACHE_OK']);
  assert.deepEqual(f.calls,{db:5,storage:0,auth:1});assert.equal(response.buildId,buildInfo.buildId);
});
test('cold cover batch final-checks all authority with nine DB gets',async()=>{
  const f=fixture();const response=await f.read([1,2,3,4].map(n=>f.item(n)));
  assert.ok(response.items.every(row=>row.status==='BYTES'&&Buffer.from(row.dataBase64,'base64').equals(jpeg)));
  assert.deepEqual(f.calls,{db:9,storage:4,auth:1});
});
test('byte LRU does not bypass permission reads and avoids repeat Storage downloads',async()=>{
  const f=fixture(1);await f.read([f.item(1)]);const before={...f.calls};await f.read([f.item(1)]);
  assert.equal(f.calls.storage,before.storage);assert.equal(f.calls.db-before.db,9);
  f.db.Friendship.push({id:relationshipId('viewer','author'),status:'BLOCKED'});
  const response=await f.read([f.item(1,{knownSha256:digest(jpeg),knownByteSize:jpeg.length})]);assert.equal(response.items[0].status,'DENIED');
});
test('removing a friend revokes FRIENDS images while PUBLIC remains readable',async()=>{
  const f=fixture(2);Object.assign(f.db.FoodCard[0],{schemaVersion:1,visibility:'FRIENDS',reviewState:'APPROVED'});
  f.db.Friendship.push({id:relationshipId('viewer','author'),status:'REMOVED'});
  const response=await f.read([f.item(1),f.item(2)]);assert.deepEqual(response.items.map(row=>row.status),['DENIED','BYTES']);
});
test('block/delete/account suspension during Storage I/O discards fetched bytes',async()=>{
  for(const change of [f=>f.db.Friendship.push({id:relationshipId('viewer','author'),status:'BLOCKED'}),f=>{f.db.FoodCard[0].deletedAt=new Date();},f=>{f.db.UserProfile[1].accountStatus='DELETING';}]) {
    const f=fixture(1);f.hook.download=async()=>change(f);const result=(await f.read([f.item(1)])).items[0];
    assert.equal(result.status,'DENIED');assert.equal(result.dataBase64,undefined);assert.equal(result.descriptor,undefined);
  }
});
test('cover revision changing during I/O is denied rather than delivering stale bytes',async()=>{
  const f=fixture(1);f.hook.download=async()=>{f.db.CardMedia[0].coverSha256='0'.repeat(64);};
  assert.equal((await f.read([f.item(1)])).items[0].status,'DENIED');
});
test('legacy missing SHA computes actual hash and confirms cache without wire bytes',async()=>{
  const f=fixture(1,false);delete f.db.CardMedia[0].preparedSha256;
  const result=(await f.read([f.item(1,{variant:'ORIGINAL',knownSha256:digest(jpeg),knownByteSize:jpeg.length})])).items[0];
  assert.equal(result.status,'CACHE_OK');assert.equal(result.dataBase64,undefined);assert.equal(f.calls.storage,1);
});
test('bad token never silently becomes an anonymous read',async()=>{
  const f=fixture();await assert.rejects(f.read([f.item(1)],'bad'),{code:'AUTH_REQUIRED'});assert.equal(f.calls.storage,0);
});
test('unknown resources reveal no descriptor and do no Storage read',async()=>{
  const f=fixture(1);const result=(await f.read([f.item(999)])).items[0];assert.equal(result.status,'DENIED');assert.equal(result.descriptor,undefined);assert.equal(f.calls.storage,0);
});
test('originals never form a multi-image byte batch; missing cover reports actual variant',async()=>{
  const f=fixture(2,false);const response=await f.read([f.item(1),f.item(2)]);
  assert.ok(response.items.every(row=>row.status==='DEFERRED'&&row.descriptor.variant==='ORIGINAL'));
  assert.equal(f.calls.storage,0);assert.equal((await f.read([f.item(1)])).items[0].status,'BYTES');
});
test('metadata-only result is version change and never downloads a known digest',async()=>{
  const f=fixture(1);const result=(await f.read([f.item(1,{wantBytes:false})])).items[0];assert.equal(result.status,'VERSION_CHANGED');assert.equal(f.calls.storage,0);
});
test('batch/input limits reject before DB access',async()=>{
  const f=fixture();await assert.rejects(f.read(Array.from({length:21},(_,n)=>f.item(n))),{code:'VALIDATION_ERROR'});
  await assert.rejects(f.read([f.item(1),f.item(1)]),{code:'VALIDATION_ERROR'});assert.equal(f.calls.db,0);
});
test('DB busy keeps exact code and failing stage for the shared retry owner',async()=>{
  const f=fixture();f.hook.query=async name=>{if(name==='CardMedia')throw Object.assign(new Error('busy'),{code:3007009});};
  await assert.rejects(f.read([f.item(1)]),error=>error.code===3007009&&error.readStage==='media-permissions');
});
test('normal mode never borrows review/revision authority',async()=>{
  const f=fixture(1);f.db.FoodCard[0].reviewState='REQUEST_CHANGE';f.db.FoodCard[0].schemaVersion=1;f.db.FoodCard[0].visibility='PUBLIC';
  const response=await f.read([f.item(1),f.item(1,{mode:'REVIEW'})]);assert.ok(response.items.every(row=>row.status==='DENIED'));
});
test('revision media binds actor, revision status and manifest membership',async()=>{
  const f=fixture(1);f.db.CardMedia[0].ownerUid='viewer';f.db.FoodCard[0].ownerUid='viewer';
  f.db.FoodCardRevision.push({revisionId:'revision-1',cardId:'card-1',authorUid:'viewer',status:'PENDING',mediaManifestJson:JSON.stringify([id(1)])});
  assert.equal((await f.read([f.item(1,{mode:'REVISION',revisionId:'revision-1'})])).items[0].status,'BYTES');
  f.db.FoodCardRevision[0].mediaManifestJson='[]';assert.equal((await f.read([f.item(1,{mode:'REVISION',revisionId:'revision-1'})])).items[0].status,'DENIED');
});
test('twenty metadata items remain one bounded authority batch',async()=>{
  const f=fixture(20);const response=await f.read(Array.from({length:20},(_,n)=>f.item(n+1,{knownSha256:digest(jpeg),knownByteSize:jpeg.length,wantBytes:false})));
  assert.equal(response.items.length,20);assert.ok(response.items.every(row=>row.status==='CACHE_OK'));assert.equal(f.calls.db,5);assert.equal(f.calls.storage,0);
});
test('fifth cover is deferred without replaying four completed results',async()=>{
  const f=fixture(5);const response=await f.read([1,2,3,4,5].map(n=>f.item(n)));
  assert.deepEqual(response.items.map(row=>row.status),['BYTES','BYTES','BYTES','BYTES','DEFERRED']);assert.equal(f.calls.storage,4);
});
test('one Storage failure preserves other successful items',async()=>{
  const f=fixture(3);f.hook.download=async()=>{if(f.calls.storage===2)throw Object.assign(new Error('unavailable'),{code:'STORAGE_UNAVAILABLE'});};
  assert.deepEqual((await f.read([1,2,3].map(n=>f.item(n)))).items.map(row=>row.status),['BYTES','RETRYABLE_ERROR','BYTES']);
});
test('current avatar binding is rechecked after Storage I/O',async()=>{
  const f=fixture(1);f.db.CardMedia[0].cardId='profile:author';f.db.UserProfile[1].avatarMediaId=id(1);
  f.hook.download=async()=>{f.db.UserProfile[1].avatarMediaId=id(2);};assert.equal((await f.read([f.item(1)])).items[0].status,'DENIED');
});
test('profile cover requires owner or an accepted friendship',async()=>{
  const f=fixture(1);f.db.CardMedia[0].cardId='profile-cover:author';f.db.UserProfile[1].coverMediaId=id(1);
  assert.equal((await f.read([f.item(1)])).items[0].status,'DENIED');
  f.db.Friendship.push({id:relationshipId('viewer','author'),status:'ACCEPTED'});assert.equal((await f.read([f.item(1)])).items[0].status,'BYTES');
});
test('client role claims do not grant moderation authority',async()=>{
  const f=fixture(1);assert.equal((await f.read([f.item(1,{mode:'REVIEW',administrator:true})])).items[0].status,'DENIED');
});
test('non-string present token is rejected instead of becoming a guest',async()=>{
  const f=fixture();await assert.rejects(f.read([f.item(1)],0),{code:'AUTH_REQUIRED'});assert.equal(f.calls.storage,0);
});
test('oversized rendition selects a bounded original without on-read conversion',async()=>{
  const f=fixture(1);f.db.CardMedia[0].coverByteSize=524289;
  const result=(await f.read([f.item(1)])).items[0];assert.equal(result.status,'BYTES');assert.equal(result.descriptor.variant,'ORIGINAL');assert.equal(f.calls.storage,1);
});

test('failed Storage attempts also consume the four-download admission budget',async()=>{
  const f=fixture(8);f.hook.download=async()=>{throw Object.assign(new Error('unavailable'),{code:'STORAGE_UNAVAILABLE'});};
  const response=await f.read(Array.from({length:8},(_,n)=>f.item(n+1)));
  assert.equal(f.calls.storage,4);assert.equal(response.items.filter(row=>row.status==='DEFERRED').length,4);
});
