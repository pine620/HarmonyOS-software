'use strict';
const { dateMillis, readableCardState, isAccountActive } = require('./shared/content-policy');
const { fail, hash, id, uuid, int, token, encode, flag, coordinate, timestampPage } = require('./stages47-common');
const KINDS = ['CARD','REVISION','MERCHANT','REPORT'];
const REVIEW_FIELDS=[['productName','名称'],['brand','品牌'],['specification','规格'],['shop','店铺'],['sellingPoints','卖点'],['publicOffers','公开优惠'],['reviewText','体验'],['sourceLink','来源'],['category','原分类'],['categoryV2','分类'],['consumptionMode','消费方式'],['merchantId','商家编号'],['merchantNameSnapshot','商家名称'],['merchantAddressSnapshot','商家地址'],['priceFen','原单价（分）'],['originalPriceFen','原价（分）'],['itemPriceFen','单品价格（分）'],['dineInAvgFen','人均（分）'],['orderTotalFen','订单总额（分）'],['deliveryFeeFen','配送费（分）'],['deliveryPlatformKey','配送平台'],['deliveryPlatformLabelSnapshot','平台名称'],['consumedAt','消费时间'],['tasteScore','口味评分']];
function fieldText(row,key){let value=row&&row[key];if(value==null&&row&&['sellingPoints','publicOffers'].includes(key)){try{value=JSON.parse(row[key+'Json']||'[]');}catch(_){value=[];}}if(value==null)return '';if(key==='consumedAt'){const at=dateMillis(value);return at?new Date(at).toISOString():'';}return typeof value==='object'?JSON.stringify(value):String(value);}
function cardReviewFields(row){return REVIEW_FIELDS.map(([key,label])=>({label,before:'',after:fieldText(row,key)})).filter(field=>field.after.length>0);}
function createModerationServices(ctx) {
  const { collection, one, models } = ctx;
  const model = (name, values) => Object.assign(new models[name](), values);
  const txOne = (...args) => ctx.stage1().txOne(...args);
  const save = (tx, rows) => ctx.stage1().upsertRows(tx, rows);
  const version = row => dateMillis(row.updatedAt) || dateMillis(row.reviewedAt) || dateMillis(row.submittedAt) || Number(row.createdAt || 0);
  function rowView(kind, row) {
    const targetId = kind === 'REPORT' ? String(row.targetId || row.cardId || '') : kind === 'REVISION' ? row.cardId : kind === 'MERCHANT' ? row.merchantId : row.id;
    return { id: String(row.revisionId || row.merchantId || row.id), kind, targetId, version: version(row),
      title: kind === 'CARD' ? String(row.productName || '卡片') : kind === 'MERCHANT' ? String(row.name || '商家') : kind === 'REVISION' ? '卡片编辑版本' : (row.targetType === 'MERCHANT' ? '商家举报' : '卡片举报'),
      state: String(row.reviewState || row.verificationStatus || row.status || ''),
      reason: String(row.reviewReason || row.resolutionReason || row.reason || ''), createdAt: dateMillis(row.submittedAt) || dateMillis(row.createdAt) || 0 };
  }
  async function capabilities(uid, env, payload={}) {
    if (uid) await ctx.contentPolicy(env).assertAccountActive(uid);
    const result={protocolVersion:2,administrator:!!uid&&ctx.isAdministrator(uid,env),lifecycleEnabled:flag(env,'SHIKE_LIFECYCLE_VERIFIED'),workerEnabled:flag(env,'SHIKE_MAINTENANCE_ENABLED')};
    if(result.administrator&&payload.includeDiagnostics===true){
      const lines=['服务协议：2；分页兼容修复：repair-20261008-v4'];
      for(const [key,label] of [['SHIKE_INDEXED_QUERY_VERIFIED','索引验证'],['SHIKE_REACTION_VERIFIED','赞踩验证'],['SHIKE_COLLECTIONS_VERIFIED','收藏合并验证'],['SHIKE_RANKINGS_VERIFIED','榜单验证'],['SHIKE_MEDIA_COVERS_VERIFIED','小图转换验证'],['SHIKE_IMAGE_READ_ENABLED','图片批量读取']])lines.push(label+'：'+(flag(env,key)?'已启用':'待验证'));
      try{const readiness=await ctx.stage1().migrationReadiness(env);lines.push('历史卡片：'+(readiness.cardCoverageComplete?'已完成':'待回填'),'历史赞踩：'+(readiness.reactionCoverageComplete?'已完成':'待整理'));}catch(_){lines.push('迁移状态读取失败，请核对 schema 与服务版本');}
      result.diagnostics=lines;
    }
    return result;
  }
  async function queue(uid,payload,env,own=false) {
    if (own) await ctx.contentPolicy(env).assertAccountActive(uid); else await ctx.assertAdmin(uid,env);
    const kind = own ? 'REPORT' : String(payload.kind || 'CARD'); if(!KINDS.includes(kind)) throw fail('审核队列无效。');
    const signature = hash(['moderation-v2',uid,kind,own]); const saved = token(payload.cursor,signature);
    const at=saved?saved.at:Date.now(), size=12;
    const name={CARD:'FoodCard',REVISION:'FoodCardRevision',MERCHANT:'Merchant',REPORT:'Report'}[kind];
    const primary={CARD:'id',REVISION:'revisionId',MERCHANT:'merchantId',REPORT:'id'}[kind];
    const stamp=kind==='REVISION'?'submittedAt':'createdAt', ascending=['REVISION','MERCHANT'].includes(kind);
    function query(){
      let q=collection(env,name).query();
      if(kind==='CARD')q=q.equalTo('status','APPROVED');
      if(kind==='REVISION')q=q.equalTo('status','PENDING');
      if(kind==='MERCHANT')q=q.equalTo('verificationStatus','USER_CONFIRMED_PENDING');
      if(kind==='REPORT')q=q.equalTo(own?'reporterUid':'status',own?uid:'PENDING');
      return ascending?q.orderByAsc(stamp):q.orderByDesc(stamp);
    }
    const items=[];let scanned=0,next=saved;
    do {
      const page=await timestampPage(query(),next,at,Math.min(size-items.length,120-scanned),primary,stamp,ascending,ascending);
      for(const row of page.rows){scanned++;if(kind!=='CARD'||(row.reviewState==='PENDING_POST_REVIEW'&&row.deletedAt==null&&row.purgeAt==null))items.push(rowView(kind,row));}
      next=page.next;
    }while(next&&scanned<120&&items.length<size);
    if(own)await ctx.contentPolicy(env).assertAccountActive(uid);else await ctx.assertAdmin(uid,env);
    return {items,nextCursor:next?encode(signature,at,next):'',scanned};
  }

  async function detail(uid,payload,env) {
    await ctx.assertAdmin(uid,env);const kind=String(payload.kind),key=id(payload.id);if(!KINDS.includes(kind))throw fail('审核类型无效。');
    const name={CARD:'FoodCard',REVISION:'FoodCardRevision',MERCHANT:'Merchant',REPORT:'Report'}[kind],primary={CARD:'id',REVISION:'revisionId',MERCHANT:'merchantId',REPORT:'id'}[kind];
    const row=await one(collection(env,name).query().equalTo(primary,key));if(!row)throw fail('审核内容不存在。','NOT_FOUND');
    let body='',sourceLink='',photos=[],changes=[],actions=[],targetVersion=0;
    if(kind==='CARD'){body=String(row.reviewText||'');sourceLink=String(row.sourceLink||'');photos=await ctx.publicPhotos(row,env,true);changes=cardReviewFields(row);actions=['APPROVE','REQUEST_CHANGE','TAKE_DOWN'];}
    if(kind==='MERCHANT'){body=String(row.address||'');changes=[{label:'坐标系',before:'',after:String(row.coordinateSystem||'UNKNOWN')},{label:'来源',before:'',after:String(row.sourceType||'')},{label:'纬度',before:'',after:String(Number(row.latitudeE6)/1e6)},{label:'经度',before:'',after:String(Number(row.longitudeE6)/1e6)},{label:'提供商',before:'',after:String(row.provider||'')}];actions=['APPROVE','REQUEST_CHANGE','TAKE_DOWN'];}
    if(kind==='REPORT'){body=String(row.reason||'');const targetType=row.targetType==='MERCHANT'?'MERCHANT':'CARD';const target=await one(collection(env,targetType==='CARD'?'FoodCard':'Merchant').query().equalTo(targetType==='CARD'?'id':'merchantId',row.targetId||row.cardId));
      if(target){targetVersion=version(target);changes=[{label:'举报对象',before:'',after:String(target.productName||target.name||'')}];if(targetType==='CARD'){changes.push(...cardReviewFields(target));sourceLink=String(target.sourceLink||'');photos=await ctx.publicPhotos(target,env,true);}else changes.push({label:'商家地址',before:'',after:String(target.address||'')});}actions=['NO_ISSUE','REQUEST_CHANGE','TAKE_DOWN'];}
    if(kind==='REVISION'){const fields=JSON.parse(row.payloadJson||'{}');const before=await one(collection(env,'FoodCard').query().equalTo('id',row.cardId));
      for(const [key,label] of REVIEW_FIELDS)if(fieldText(fields,key)!==fieldText(before,key))changes.push({label,before:fieldText(before,key),after:fieldText(fields,key)});
      body=String(fields.reviewText||'');sourceLink=String(fields.sourceLink||'');for(const mediaId of JSON.parse(row.mediaManifestJson||'[]')){const media=await one(collection(env,'CardMedia').query().equalTo('id',mediaId));if(media&&media.ownerUid===row.authorUid)photos.push(ctx.photoReference(media,env));}actions=['APPROVE','REQUEST_CHANGE'];}
    const fresh=await one(collection(env,name).query().equalTo(primary,key));await ctx.assertAdmin(uid,env);if(!fresh||version(fresh)!==version(row))throw fail('审核内容已变化，请刷新。','CONFLICT');
    return {item:rowView(kind,row),body,sourceLink,photos,changes,actions,targetVersion,coordinateSystem:String(row.coordinateSystem||'UNKNOWN')};
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
  async function decide(uid,payload,env) {
    await ctx.assertAdmin(uid,env);const kind=String(payload.kind),key=id(payload.id),action=String(payload.action),reason=String(payload.reason||'').trim(),requestId=uuid(payload.requestId);
    if(!KINDS.includes(kind)||!['APPROVE','REQUEST_CHANGE','TAKE_DOWN','NO_ISSUE'].includes(action))throw fail('审核操作无效。');
    if(reason.length>200||(action!=='APPROVE'&&!reason))throw fail('请填写不超过 200 字处理理由。');
    if((kind==='REVISION'&&!['APPROVE','REQUEST_CHANGE'].includes(action))||(kind==='REPORT'&&action==='APPROVE')||(kind!=='REPORT'&&action==='NO_ISSUE'))throw fail('此队列不支持该动作。');
    const expected=int(payload.expectedVersion,0,Number.MAX_SAFE_INTEGER),receiptId=hash(['moderation',uid,requestId]),payloadHash=hash([kind,key,action,reason,expected,payload.coordinateSystem||'',payload.targetVersion||0]);let result;
    const committed=await collection(env,'Report').runTransaction({apply:async tx=>{
      result=null;await ctx.assertAdmin(uid,env);const admin=await ctx.stage1().activeProfile(tx,uid,env);const receipt=await txOne(tx,env,'PublishRequestRecord','requestId',receiptId);
      if(receipt){if(receipt.uid!==uid||receipt.payloadHash!==payloadHash||receipt.operationType!=='MODERATION')throw fail('请求标识已用于其他处理。','CONFLICT');result={success:true,alreadyProcessed:true};return true;}
      const name={CARD:'FoodCard',REVISION:'FoodCardRevision',MERCHANT:'Merchant',REPORT:'Report'}[kind],primary={CARD:'id',REVISION:'revisionId',MERCHANT:'merchantId',REPORT:'id'}[kind];
      const row=await txOne(tx,env,name,primary,key);if(!row||version(row)!==expected)throw fail('内容已变化，请刷新后处理。','CONFLICT');
      let now=ctx.logicalWriteTime(version(row),admin.updatedAt);const writes=[];
      async function changeCard(card,decision){if(!card||card.deletedAt!=null||card.purgeAt!=null)throw fail('卡片已删除。','CONTENT_UNAVAILABLE');const owner=await txOne(tx,env,'UserProfile','uid',card.ownerUid);
        if(decision==='APPROVE'&&(!isAccountActive(owner)||card.status!=='APPROVED'||card.reviewState!=='PENDING_POST_REVIEW'))throw fail('当前卡片不能批准。','INVALID_STATE');
        if(decision==='REQUEST_CHANGE'&&card.reviewState==='TAKEN_DOWN')throw fail('已下架内容不可转为作者修改恢复。','INVALID_STATE');
        now=ctx.logicalWriteTime(now,card.updatedAt,dateMillis(card.modifiedAt),owner&&owner.updatedAt);
        const next=model('FoodCard',{...card,visibility:'PUBLIC',reviewState:decision==='APPROVE'?'APPROVED':decision==='REQUEST_CHANGE'?'REQUEST_CHANGE':'TAKEN_DOWN',reviewReason:reason,status:decision==='APPROVE'?'APPROVED':'REMOVED',modifiedAt:new Date(now),publishedAt:new Date(now),updatedAt:now,lifecycleGeneration:Number(card.lifecycleGeneration||0)+1});
        writes.push(next,...await ctx.stage2().prepareCounterTransition(tx,card,next,owner,env,now));if(owner)writes.push(ctx.profileForWrite(owner,ctx.logicalWriteTime(owner.updatedAt,now)));}
      async function changeMerchant(merchant,decision){if(!merchant)throw fail('商家不存在。','NOT_FOUND');const system=decision==='APPROVE'?String(payload.coordinateSystem||merchant.coordinateSystem):merchant.coordinateSystem;
        if(decision==='APPROVE'&&(!['GCJ02','WGS84'].includes(system)||merchant.verificationStatus!=='USER_CONFIRMED_PENDING'))throw fail('请核实待审商家的坐标系。','COORDINATE_VERIFICATION_REQUIRED');
        now=ctx.logicalWriteTime(now,dateMillis(merchant.updatedAt));const next=model('Merchant',{...merchant,coordinateSystem:system,verificationStatus:decision==='APPROVE'?'USER_CONFIRMED_APPROVED':decision==='REQUEST_CHANGE'?'USER_CONFIRMED_PENDING':'REJECTED',reviewAction:decision,reviewReason:reason,reviewedAt:new Date(now),updatedAt:new Date(now)});next.mapVisible=ctx.stage2().mapEligible(next);writes.push(next);}
      if(kind==='CARD')await changeCard(row,action);
      if(kind==='MERCHANT')await changeMerchant(row,action);
      if(kind==='REPORT'){if(row.status!=='PENDING')throw fail('举报已处理。','CONFLICT');if(action!=='NO_ISSUE'){const merchant=row.targetType==='MERCHANT';const target=await txOne(tx,env,merchant?'Merchant':'FoodCard',merchant?'merchantId':'id',row.targetId||row.cardId);if(!target||version(target)!==int(payload.targetVersion,0,Number.MAX_SAFE_INTEGER))throw fail('举报对象已变化，请刷新后处理。','CONFLICT');if(merchant)await changeMerchant(target,action);else await changeCard(target,action);}
        writes.push(model('Report',{...row,status:'RESOLVED',resolutionAction:action,resolutionReason:reason,resolvedByUid:uid,resolvedAt:now,updatedAt:now}));}
      if(kind==='REVISION'){if(row.status!=='PENDING')throw fail('编辑版本已处理。','CONFLICT');const card=await txOne(tx,env,'FoodCard','id',row.cardId),owner=await txOne(tx,env,'UserProfile','uid',row.authorUid);
        if(action==='APPROVE'){if(!card||card.ownerUid!==row.authorUid||!ctx.stage1().editableState(card)||!isAccountActive(owner)||ctx.stage1().cardTime(card)!==dateMillis(row.baseModifiedAt)||Number(card.lifecycleGeneration||0)!==Number(row.baseLifecycleGeneration))throw fail('编辑基准已变化，请要求作者重新提交。','CONFLICT');
          const fields=JSON.parse(row.payloadJson),ids=JSON.parse(row.mediaManifestJson);ctx.uniqueMediaIds({mediaIds:ids});const typed=await ctx.stage2().cardFields(fields,row.authorUid,env,(n,f,v)=>txOne(tx,env,n,f,v),true);
          if(typed.merchantNameSnapshot!==String(fields.merchantNameSnapshot||'')||typed.merchantAddressSnapshot!==String(fields.merchantAddressSnapshot||''))throw fail('商家已变化，请重新提交。','CONFLICT');
          const medias=[];for(const mediaId of ids){const media=await txOne(tx,env,'CardMedia','id',mediaId);if(!media||media.ownerUid!==row.authorUid||media.status!=='APPROVED'||![row.cardId,'revision:'+row.revisionId].includes(media.cardId))throw fail('编辑图片已失效。','CONFLICT');medias.push(model('CardMedia',{...media,cardId:card.id}));}
          const oldMedia=await tx.executeQuery(collection(env,'CardMedia').query().equalTo('cardId',card.id).limit(20));if(oldMedia.length===20)throw fail('图片数量异常。','INVALID_STATE');
          const next=model('FoodCard',{...card,...fields,...ctx.stage2().storageFields(typed),reviewState:'APPROVED',reviewReason:'',status:'APPROVED',edited:true,modifiedAt:new Date(now),publishedAt:new Date(now),updatedAt:now,lifecycleGeneration:Number(card.lifecycleGeneration||0)+1,mediaId:ids[0]||''});
          writes.push(next,...medias,...oldMedia.filter(m=>!ids.includes(m.id)).map(m=>model('CardMedia',{...m,cardId:'revision:'+row.revisionId,status:'RETIRED'})),...await ctx.stage2().prepareCounterTransition(tx,card,next,owner,env,now),ctx.profileForWrite(owner,now));}
        writes.push(model('FoodCardRevision',{...row,status:action==='APPROVE'?'APPROVED':'REJECTED',reviewReason:reason,reviewedAt:new Date(now)}));}
      const audit=ctx.stage1().jobRow('MODERATION_AUDIT',key,uid,now,now,now,{kind,action,reason,requestId});audit.status='DONE';
      writes.push(audit,model('PublishRequestRecord',{requestId:receiptId,uid,operationType:'MODERATION',payloadHash,resultEntityId:key,status:'COMMITTED',createdAt:new Date(now),expiresAt:new Date(now+30*86400000)}),ctx.profileForWrite(admin,now));save(tx,writes);result={success:true,alreadyProcessed:false};return true;
    }});if(!committed||!result)throw fail('审核未保存，请使用同一请求重试。','CONFLICT');return result;
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


  return {capabilities,queue,detail,submitReport,decide,ownReviewQueue,rowView,version};
}
module.exports={createModerationServices};
