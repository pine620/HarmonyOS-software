'use strict';
const { dateMillis, cardContentRevision, readableCardState, isAccountActive } = require('./shared/content-policy');
const { isCardReviewer } = require('./shared/card-review-access');
const { fail, hash, id, uuid, token, encode, timestampPage } = require('./stages47-common');
const REASONS = Object.freeze({ INACCURATE: '信息不准确', COPYRIGHT: '图片侵权', INAPPROPRIATE: '不当内容', ADVERTISING: '广告或引流', BROKEN_LINK: '链接失效', OTHER: '其他问题' });
const isCardReport = row => !!row && (row.targetType === 'CARD' || !row.targetType && !!row.cardId);
const target = row => String(row.cardId || row.targetId || '');
const pending = row => row.status === 'PENDING';
const version = row => dateMillis(row.updatedAt) || dateMillis(row.createdAt) || 0;
function createCardReportServices(ctx) {
  const { collection, one, models } = ctx;
  const read = (name, field, value, env) => one(collection(env, name).query().equalTo(field, value));
  const txOne = (...args) => ctx.stage1().txOne(...args);
  const model = (name, values) => Object.assign(new models[name](), values);
  async function access(uid, env, required = true) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const allowed = isCardReviewer(uid, env);
    if (required && !allowed) throw fail('当前账号没有卡片审核权限。', 'ADMIN_REQUIRED');
    return { allowed };
  }
  function view(row, admin = false) {
    return { id: String(row.id), cardId: target(row), cardTitle: String(row.cardTitle || '卡片'), status: pending(row) ? 'PENDING' : 'RESOLVED',
      reasonType: String(row.reasonType || 'OTHER'), reasonLabel: Object.hasOwn(REASONS,row.reasonType) ? REASONS[row.reasonType] : '历史举报', description: Object.hasOwn(REASONS,row.reasonType) ? String(row.description || '') : String(row.reason || '历史举报未保留可读取说明，请核对原记录。'),
      createdAt: dateMillis(row.createdAt) || 0, updatedAt: version(row), reportedRevision: String(row.reportedRevision || ''),
      resolutionAction: String(row.resolutionAction || ''), resolutionReason: String(row.resolutionReason || ''), resolvedAt: dateMillis(row.resolvedAt) || 0, ...(admin ? {reviewerUid: String(row.resolvedByUid || '')} : {}) };
  }
  async function cardView(cardId, uid, env, admin = false) {
    const card = await read('FoodCard', 'id', cardId, env);
    const owner = card ? await read('UserProfile', 'uid', card.ownerUid, env) : null;
    const available = !!card && isAccountActive(owner) && card.deletedAt == null && card.purgeAt == null &&
      (readableCardState(card) || admin && card.reviewState === 'TAKEN_DOWN');
    if (!available) return { available: false, readable: false, id: cardId, title: '内容已不可用', revision: card ? cardContentRevision(card) : '', photos: [] };
    const media = await collection(env, 'CardMedia').query().equalTo('cardId', cardId).orderByAsc('createdAt').limit(20).get();
    const photos = media.filter(row => row.status === 'APPROVED' && row.ownerUid === card.ownerUid).sort((a,b) => Number(b.id === card.mediaId)-Number(a.id === card.mediaId)).map(row => ({mediaId: String(row.id)}));
    const fresh = await read('FoodCard', 'id', cardId, env);
    const freshOwner = await read('UserProfile', 'uid', card.ownerUid, env);
    if (!fresh || cardContentRevision(fresh) !== cardContentRevision(card) || !isAccountActive(freshOwner) || fresh.deletedAt != null || fresh.purgeAt != null || !(readableCardState(fresh) || admin && fresh.reviewState === 'TAKEN_DOWN')) throw fail('卡片已变化，请刷新。', 'STALE_VERSION');
    const arrayText = value => { try { const values = JSON.parse(value || '[]'); return Array.isArray(values) ? values.filter(item => typeof item === 'string').join('；') : ''; } catch (_error) { return ''; } };
    const money = value => value == null ? '' : (Number(value)/100).toFixed(2)+' 元';
    const mode = String(card.consumptionMode || 'LEGACY');
    const price = mode === 'DELIVERY' ? money(card.itemPriceFen) : mode === 'DINE_IN' ? money(card.dineInAvgFen) : card.priceLabel || (Number(card.priceFen)>0 ? money(card.priceFen) : money(card.itemPriceFen));
    return { available: true, readable: readableCardState(card), id: cardId, title: String(card.productName || '卡片'), revision: cardContentRevision(card),
      brand: String(card.brand || ''), price: price || '价格待补充', consumptionMode: mode === 'DELIVERY' ? '外卖' : mode === 'DINE_IN' ? '到店' : '历史卡片',
      itemPrice: money(card.itemPriceFen), dineInAverage: money(card.dineInAvgFen), orderTotal: money(card.orderTotalFen), deliveryFee: money(card.deliveryFeeFen), originalPrice: money(card.originalPriceFen),
      deliveryPlatform: String(card.deliveryPlatformLabelSnapshot || ''), consumedAt: dateMillis(card.consumedAt) || 0, publishedAt: dateMillis(card.publishedAt) || dateMillis(card.createdAt) || 0, modifiedAt: dateMillis(card.modifiedAt) || 0,
      specification: String(card.specification || ''), shop: String(card.merchantNameSnapshot || card.shop || ''), address: String(card.merchantAddressSnapshot || card.district || ''),
      sellingPoints: arrayText(card.sellingPointsJson), offers: arrayText(card.publicOffersJson), reviewText: String(card.reviewText || ''), tasteScore: Number(card.tasteScore || 0),
      sourceLink: String(card.sourceLink || ''), category: String(card.categoryV2 || card.category || ''), photos };
  }
  async function context(uid, payload, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const card = await cardView(id(payload.cardId), uid, env);
    await ctx.contentPolicy(env).assertAccountActive(uid);
    if (!card.available) throw fail('卡片已不可举报。', 'CONTENT_UNAVAILABLE');
    return { card };
  }
  async function submit(uid, payload, env) {
    const cardId = id(payload.cardId || payload.targetId), requestId = uuid(payload.requestId), reasonType = String(payload.reasonType || '');
    const description = String(payload.description || '').trim();
    if (!Object.hasOwn(REASONS,reasonType) || description.length > 200 || reasonType === 'OTHER' && !description) throw fail('请选择举报类型；其他问题需填写说明，最多 200 字。');
    const revision = String(payload.expectedRevision || ''); if (!revision || revision.length > 100) throw fail('请先加载卡片，再提交举报。');
    const key = hash(['card-report-v2', uid, cardId, revision]), payloadHash = hash([cardId, revision, reasonType, description]); let result;
    const committed = await collection(env, 'Report').runTransaction({apply: async tx => {
      const reporter = await ctx.stage1().activeProfile(tx, uid, env);
      const previous = await txOne(tx,env,'Report','id',key);
      if (previous) {
        if (previous.submissionRequestId === requestId && previous.submissionPayloadHash !== payloadHash) throw fail('同一请求不能提交不同内容。','CONFLICT');
        result = { success: true, reportId: key, alreadyReported: true }; return true;
      }
      const legacy = await txOne(tx,env,'Report','id',ctx.legacyReportId(uid,cardId));
      if (isCardReport(legacy) && pending(legacy)) { result = {success:true,reportId:String(legacy.id),alreadyReported:true}; return true; }
      const card = await txOne(tx,env,'FoodCard','id',cardId);
      await ctx.transactionPolicy(tx,env,[reporter]).assertCardReadable(uid,card);
      if (cardContentRevision(card) !== revision) throw fail('卡片已被修改，请刷新后确认举报内容。','STALE_VERSION');
      const now = ctx.logicalWriteTime(reporter.updatedAt);
      ctx.stage1().upsertRows(tx,[model('Report',{id:key,reporterUid:uid,cardId,targetType:'CARD',targetId:cardId,cardTitle:String(card.productName || '卡片'),
        reason: REASONS[reasonType], reasonType, description, reportedRevision:revision,
        submissionRequestId:requestId,submissionPayloadHash:payloadHash,status:'PENDING',createdAt:now,updatedAt:now}),ctx.profileForWrite(reporter,now)]);
      result = {success:true,reportId:key,alreadyReported:false}; return true;
    }});
    if (!committed || !result) throw fail('举报未确认，请重试。','CONFLICT'); return result;
  }
  async function list(uid,payload,env,admin=false) {
    if (admin) await access(uid,env); else await ctx.contentPolicy(env).assertAccountActive(uid);
    const status = payload.status === 'RESOLVED' ? 'RESOLVED' : 'PENDING';
    const signature = hash(['card-report-list-v2',uid,admin,status]), saved = token(payload.cursor,signature), at=saved?saved.at:Date.now();
    let continuation = saved, next = null; const items=[];
    // Bound legacy filtering work. A nonempty cursor remains available even on an empty page.
    for (let scan=0;scan<4 && items.length<12;scan++) {
      const query = admin ? collection(env,'Report').query().equalTo('status',status).orderByDesc('createdAt') : collection(env,'Report').query().equalTo('reporterUid',uid).orderByDesc('createdAt');
      const page = await timestampPage(query,continuation,at,12-items.length,'id','createdAt');
      for (const row of page.rows) if (isCardReport(row) && (pending(row) ? 'PENDING':'RESOLVED') === status) items.push(view(row,admin));
      next=page.next; if (!next) break; continuation=next;
    }
    if (items.length) {
      const ids=[...new Set(items.map(row=>row.cardId))];
      const cards=await collection(env,'FoodCard').query().in('id',ids).limit(ids.length).get();
      const ownerIds=[...new Set(cards.map(card=>card.ownerUid).filter(Boolean))];
      const owners=ownerIds.length?await collection(env,'UserProfile').query().in('uid',ownerIds).limit(ownerIds.length).get():[];
      const allowed=cards.filter(card=>isAccountActive(owners.find(owner=>owner.uid===card.ownerUid)) && card.deletedAt==null && card.purgeAt==null && (readableCardState(card) || admin && card.reviewState==='TAKEN_DOWN'));
      const mediaIds=[...new Set(allowed.map(card=>card.mediaId).filter(Boolean))];
      const media=mediaIds.length?await collection(env,'CardMedia').query().in('id',mediaIds).limit(mediaIds.length).get():[];
      for (const row of items) {
        const card=allowed.find(card=>card.id===row.cardId); if (!card) continue;
        if (row.cardTitle==='卡片') row.cardTitle=String(card.productName || '卡片');
        const cover=media.find(photo=>photo.id===card.mediaId && photo.cardId===card.id && photo.ownerUid===card.ownerUid && photo.status==='APPROVED');
        if (cover) row.previewMediaId=String(cover.id);
      }
    }
    if (admin) await access(uid,env); else await ctx.contentPolicy(env).assertAccountActive(uid);
    return {items,nextCursor:next?encode(signature,at,next):''};
  }
  async function detail(uid,payload,env,admin=false) {
    if (admin) await access(uid,env); else await ctx.contentPolicy(env).assertAccountActive(uid);
    const row = await read('Report','id',id(payload.reportId),env);
    if (!isCardReport(row) || !admin && row.reporterUid !== uid) throw fail('举报记录不可访问。','CONTENT_ACCESS_DENIED');
    const card = await cardView(target(row),uid,env,admin);
    if (admin) await access(uid,env); else await ctx.contentPolicy(env).assertAccountActive(uid);
    return {report:view(row,admin),card,cardChanged:!!row.reportedRevision && row.reportedRevision !== card.revision};
  }
  async function resolve(uid,payload,env) {
    await access(uid,env);
    const reportId=id(payload.reportId),requestId=uuid(payload.requestId), action=String(payload.action || ''),reason=String(payload.reason || '').trim();
    if (!['KEEP','TAKE_DOWN'].includes(action) || !reason || reason.length>200) throw fail('请选择处理方式并填写 1–200 字处理说明。');
    const spec=hash([reportId,action,reason,payload.expectedReportVersion,payload.expectedCardRevision]); let result,ownerUid='';
    const committed=await collection(env,'Report').runTransaction({apply:async tx=>{
      const reviewer=await ctx.stage1().activeProfile(tx,uid,env);
      if (!isCardReviewer(uid,env)) throw fail('当前账号没有审核权限。','ADMIN_REQUIRED');
      const row=await txOne(tx,env,'Report','id',reportId);
      if (!isCardReport(row)) throw fail('举报记录不可访问。','CONTENT_ACCESS_DENIED');
      if (!pending(row)) {
        if (row.resolutionRequestId!==requestId || row.resolvedByUid!==uid || row.resolutionPayloadHash!==spec) throw fail('举报已由管理员处理，请刷新。','ALREADY_RESOLVED');
        result={success:true,reportId,action:row.resolutionAction};return true;
      }
      if (!Number.isSafeInteger(payload.expectedReportVersion) || payload.expectedReportVersion!==version(row)) throw fail('举报已变化，请刷新。','STALE_VERSION');
      const card=await txOne(tx,env,'FoodCard','id',target(row));
      if (String(payload.expectedCardRevision || '')!==(card?cardContentRevision(card):'')) throw fail('卡片已变化，请重新查看后处理。','STALE_VERSION');
      const owner=card && card.ownerUid===uid ? reviewer : card ? await txOne(tx,env,'UserProfile','uid',card.ownerUid) : null;
      const readable=!!card && isAccountActive(owner) && readableCardState(card);
      if (action==='TAKE_DOWN' && !readable) throw fail('卡片已下架或不可用，请刷新后选择结束审核。','CONTENT_UNAVAILABLE');
      const now=ctx.logicalWriteTime(row.updatedAt,reviewer.updatedAt,owner && owner.updatedAt,card && card.updatedAt); const rows=[];
      const actualAction=readable?action:card && card.reviewState==='TAKEN_DOWN'?'ALREADY_DOWN':'UNAVAILABLE';
      if (action==='TAKE_DOWN') {
        const generation=Number(card.lifecycleGeneration || 0); if (!Number.isSafeInteger(generation) || generation<0 || !Number.isSafeInteger(generation+1)) throw fail('卡片版本无效。','INVALID_STATE');
        const after=model('FoodCard',{...card,status:'REMOVED',reviewState:'TAKEN_DOWN',reviewReason:reason,updatedAt:now,lifecycleGeneration:generation+1});
        rows.push(...await ctx.stage2().prepareCounterTransition(tx,card,after,owner,env,now),after);
        ownerUid=card.ownerUid;
      }
      const profiles=new Map([[uid,reviewer]]); if (action==='TAKE_DOWN') profiles.set(owner.uid,owner);
      for (const profile of profiles.values()) { const updated=ctx.profileForWrite(profile,now); if (action==='TAKE_DOWN' && profile.uid===owner.uid) { const count=Number(profile.publishCount || 0); if (!Number.isSafeInteger(count) || count<0 || count>2147483647) throw fail('发布计数无效。','INVALID_STATE'); updated.publishCount=Math.max(0,count-1); } rows.push(updated); }
      rows.push(model('Report',{...row,status:'RESOLVED',updatedAt:now,resolutionAction:actualAction,resolutionReason:reason,resolvedByUid:uid,resolvedAt:now,
        resolutionRequestId:requestId,resolutionPayloadHash:spec,resolvedCardRevision:card?cardContentRevision(card):''}));
      ctx.stage1().upsertRows(tx,rows);result={success:true,reportId,action:actualAction};return true;
    }});
    if (!committed || !result) throw fail('处理未确认，请保持原操作重试。','CONFLICT');
    if (ownerUid) await ctx.refreshPublishCount(ownerUid,env);
    return result;
  }
  return {access,context,submit,list,detail,resolve};
}
module.exports={createCardReportServices};
