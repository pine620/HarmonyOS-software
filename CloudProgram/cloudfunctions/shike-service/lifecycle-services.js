'use strict';
const crypto=require('crypto');
const {errorCode}=require('./shared/read-errors');
const maintenanceCode=error=>{const code=errorCode(error);return code==='REQUEST_FAILED'?'MAINTENANCE_FAILED':code;};
const {dateMillis,isAccountActive,readableCardState}=require('./shared/content-policy');
const {fail,hash,id,uuid,int,token,encode,flag,timestampPage}=require('./stages47-common');
const BATCH=10,LEASE_MS=300000,DAY=86400000;
const TYPES=['PURGE_CARD','DELETE_ACCOUNT','PURGE_GROUP'];
const LEGACY_TYPES=['PURGE_CONVERSATION','BACKFILL_CARD','MIGRATE_REACTION'];
function createLifecycleServices(ctx){
  const {collection,one,models}=ctx;const model=(name,row)=>Object.assign(new models[name](),row);
  const txOne=(...args)=>ctx.stage1().txOne(...args),save=(tx,rows)=>ctx.stage1().upsertRows(tx,rows);
  function enabled(env){if(!flag(env,'SHIKE_LIFECYCLE_VERIFIED'))throw fail('生命周期服务尚未就绪。','FEATURE_NOT_READY');}
  function errorCategory(job){
    const code=String(job.lastErrorCode||'');
    if(!code)return 'NONE';
    if(['INVALID_STATE','STALE_GENERATION'].includes(code))return 'PERMANENT';
    if(['AUTH_ACTION_REQUIRED','CHILD_CLEANUP_REQUIRED','CONFIGURATION_REQUIRED'].includes(code)||job.status==='FAILED')return 'MANUAL';
    return 'RETRYABLE';
  }
  function view(job){
    let cp;try{cp=progress(job);}catch(_){cp={phase:'INVALID_CHECKPOINT'};}
    const created=dateMillis(job.createdAt)||0,deadline=job.jobType==='DELETE_ACCOUNT'&&created>0?created+7*DAY:0;
    const terminal=['DONE','CANCELLED'].includes(job.status);
    const lastProgress=Number(cp.lastProgressAt||created),authRequired=job.lastErrorCode==='AUTH_ACTION_REQUIRED';
    const authDue=authRequired&&deadline?Math.min(deadline,Number(cp.authActionRequiredAt||created)+2*DAY):0;
    const migration=['BACKFILL_CARD','MIGRATE_REACTION'].includes(job.jobType)&&cp.phase!=='INVALID_CHECKPOINT';
    return {...ctx.stage1().jobView(job),processed:Number(migration?cp.scanned||0:cp.processed||0),phase:String(cp.phase||'START'),authActionRequired:authRequired,
      ...(migration?{migration:cp}:{}),
      processingDeadlineAt:deadline,manualActionDueAt:authDue,overdue:!terminal&&!!deadline&&Date.now()>deadline,
      lastProgressAt:lastProgress,noProgressRuns:Number(cp.noProgressRuns||0),
      stalled:!terminal&&(dateMillis(job.runAfterAt)||0)<=Date.now()&&lastProgress>0&&Date.now()-lastProgress>1800000,
      errorCategory:cp.phase==='INVALID_CHECKPOINT'?'PERMANENT':errorCategory(job)};
  }
  function progress(job){let value;try{value=JSON.parse(job.checkpointJson||'{}');}catch(_){throw fail('任务检查点无效。','INVALID_STATE');}if(!value||typeof value!=='object'||Array.isArray(value))throw fail('任务检查点无效。','INVALID_STATE');return value;}
  async function deleted(uid,payload,env){
    await ctx.contentPolicy(env).assertAccountActive(uid);const signature=hash(['deleted',uid]),saved=token(payload.cursor,signature),at=saved?saved.at:Date.now();
    const page=await timestampPage(collection(env,'FoodCard').query().equalTo('ownerUid',uid).orderByDesc('createdAt'),saved,at,12,'id','createdAt');
    const candidates=page.rows.filter(row=>row.deletedAt!=null),fresh=await ctx.readCardRowsByIds(candidates.map(row=>row.id),env),items=[];
    for(const original of candidates){const row=fresh.get(original.id);if(!row||row.ownerUid!==uid||row.deletedAt==null||Number(row.updatedAt)!==Number(original.updatedAt))continue;
      const job=await one(collection(env,'MaintenanceJob').query().equalTo('jobId',ctx.stage1().hash('PURGE_CARD:'+row.id+':'+Number(row.lifecycleGeneration||0))));
      items.push({cardId:row.id,title:String(row.productName||'已删除卡片'),deletedAt:dateMillis(row.deletedAt)||0,purgeAt:dateMillis(row.purgeAt)||0,version:Number(row.updatedAt||0),
        canRestore:flag(env,'SHIKE_LIFECYCLE_VERIFIED')&&dateMillis(row.purgeAt)>Date.now()&&readableCardState({...row,deletedAt:null,purgeAt:null})&&!!job&&['PENDING','RETRY_WAIT'].includes(job.status)&&progress(job).physicalDeletionStarted!==true});
    }
    await ctx.contentPolicy(env).assertAccountActive(uid);
    return {items,nextCursor:page.next?encode(signature,at,page.next):'',lifecycleEnabled:flag(env,'SHIKE_LIFECYCLE_VERIFIED')};
  }

  async function restore(uid,payload,env){enabled(env);const cardId=id(payload.cardId),requestId=uuid(payload.requestId),expected=int(payload.expectedVersion,0,Number.MAX_SAFE_INTEGER),receiptId=hash(['restore',uid,requestId]),payloadHash=hash([cardId,expected]);let result;
    const committed=await collection(env,'FoodCard').runTransaction({apply:async tx=>{const owner=await ctx.stage1().activeProfile(tx,uid,env),receipt=await txOne(tx,env,'PublishRequestRecord','requestId',receiptId);
      if(receipt){if(receipt.uid!==uid||receipt.operationType!=='RESTORE_CARD'||receipt.payloadHash!==payloadHash)throw fail('请求标识已使用。','CONFLICT');result={success:true,alreadyProcessed:true};return true;}
      const card=await txOne(tx,env,'FoodCard','id',cardId);if(!card||card.ownerUid!==uid||card.deletedAt==null||Number(card.updatedAt)!==expected)throw fail('删除状态已变化。','CONFLICT');
      if(card.reviewState==='TAKEN_DOWN'||!readableCardState({...card,deletedAt:null,purgeAt:null})||dateMillis(card.purgeAt)<=Date.now())throw fail('此卡片已过恢复期限或被下架。','RESTORE_UNAVAILABLE');
      const jobId=ctx.stage1().hash('PURGE_CARD:'+cardId+':'+Number(card.lifecycleGeneration||0)),job=await txOne(tx,env,'MaintenanceJob','jobId',jobId);
      if(!job||!['PENDING','RETRY_WAIT'].includes(job.status)||progress(job).physicalDeletionStarted===true)throw fail('清理已开始，不能恢复。','RESTORE_UNAVAILABLE');
      const now=ctx.logicalWriteTime(owner.updatedAt,card.updatedAt),next=model('FoodCard',{...card,deletedAt:null,purgeAt:null,lifecycleGeneration:Number(card.lifecycleGeneration||0)+1,modifiedAt:new Date(now),updatedAt:now});
      const counters=await ctx.stage2().prepareCounterTransition(tx,card,next,owner,env,now);save(tx,[next,...counters,ctx.profileForWrite(owner,now),model('MaintenanceJob',{...job,status:'CANCELLED',leaseOwner:'',leaseUntilAt:null,updatedAt:new Date(now),lastErrorCode:'RESTORED'}),
        model('PublishRequestRecord',{requestId:receiptId,uid,operationType:'RESTORE_CARD',payloadHash,resultEntityId:cardId,status:'COMMITTED',createdAt:new Date(now),expiresAt:new Date(now+30*DAY)})]);result={success:true,alreadyProcessed:false};return true;
    }});if(!committed||!result)throw fail('恢复未保存，请用同一请求重试。','CONFLICT');await ctx.refreshPublishCount(uid,env);return result;}
  async function claim(jobId,env){const lease=crypto.randomUUID();let claimed=null;
    const ok=await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{const job=await txOne(tx,env,'MaintenanceJob','jobId',jobId);if(!job||!TYPES.includes(job.jobType)||!['PENDING','RETRY_WAIT','RUNNING'].includes(job.status))return true;
      if(job.status==='RUNNING'&&dateMillis(job.leaseUntilAt)>Date.now())return true;if(dateMillis(job.runAfterAt)>Date.now())return true;
      const cp=progress(job),now=ctx.logicalWriteTime(dateMillis(job.updatedAt));if(!cp.lastProgressAt)cp.lastProgressAt=dateMillis(job.createdAt)||now;
      if(job.jobType==='PURGE_CARD'){const card=await txOne(tx,env,'FoodCard','id',job.entityId);if(card&&(card.deletedAt==null||Number(card.lifecycleGeneration||0)!==Number(job.generation))){save(tx,[model('MaintenanceJob',{...job,status:'CANCELLED',updatedAt:new Date(now),lastErrorCode:'STALE_GENERATION'})]);return true;}
        if(card&&dateMillis(card.purgeAt)>now)return true;cp.physicalDeletionStarted=true;cp.phase=cp.phase||'MEDIA';}
      if(job.jobType==='DELETE_ACCOUNT'){const profile=await txOne(tx,env,'UserProfile','uid',job.entityId);if(profile&&isAccountActive(profile))throw fail('账号仍活跃，拒绝清理。','INVALID_STATE');if(profile&&profile.deletionJobId&&profile.deletionJobId!==jobId)throw fail('注销版本已变化。','CONFLICT');cp.phase=cp.phase==='BUSINESS_CLEANUP'?'CARDS':cp.phase||'CARDS';cp.physicalDeletionStarted=true;}
      if(job.jobType==='PURGE_GROUP')cp.phase=cp.phase||'MESSAGES';
      claimed=model('MaintenanceJob',{...job,status:'RUNNING',leaseOwner:lease,leaseUntilAt:new Date(now+LEASE_MS),attemptCount:Number(job.attemptCount||0)+1,checkpointJson:JSON.stringify(cp),updatedAt:new Date(now),lastErrorCode:''});save(tx,[claimed]);return true;
    }});return ok?claimed:null;}
  async function locked(tx,job,env){const fresh=await txOne(tx,env,'MaintenanceJob','jobId',job.jobId);if(!fresh||fresh.status!=='RUNNING'||fresh.leaseOwner!==job.leaseOwner||dateMillis(fresh.leaseUntilAt)<=Date.now())throw fail('任务租约已变化。','LEASE_LOST');
    if(fresh.jobType==='PURGE_CARD'){const card=await txOne(tx,env,'FoodCard','id',fresh.entityId);if(card&&(card.deletedAt==null||dateMillis(card.purgeAt)>Date.now()||Number(card.lifecycleGeneration||0)!==Number(fresh.generation)))throw fail('卡片清理资格已变化。','STALE_GENERATION');}
    if(fresh.jobType==='DELETE_ACCOUNT'){const owner=await txOne(tx,env,'UserProfile','uid',fresh.entityId);if(owner&&isAccountActive(owner))throw fail('账号仍活跃。','INVALID_STATE');if(owner&&owner.deletionJobId&&owner.deletionJobId!==fresh.jobId)throw fail('注销版本已变化。','CONFLICT');}
    if(fresh.jobType==='PURGE_GROUP'&&await txOne(tx,env,'GroupConversation','id',fresh.entityId))throw fail('群仍存在，拒绝清理。','INVALID_STATE');
    return fresh;}
  function changed(job,cp,status='RUNNING'){return model('MaintenanceJob',{...job,status,checkpointJson:JSON.stringify(cp),updatedAt:new Date(ctx.logicalWriteTime(dateMillis(job.updatedAt))),leaseUntilAt:new Date(Date.now()+LEASE_MS)});}
  async function transition(job,env,mutate){
    let next=null;const ok=await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{
      const fresh=await locked(tx,job,env),cp=progress(fresh);
      const before=JSON.stringify([cp.phase,cp.step,cp.processed,cp.complete]);
      await mutate(tx,cp,fresh);
      if(before!==JSON.stringify([cp.phase,cp.step,cp.processed,cp.complete])){cp.lastProgressAt=Date.now();cp.progressVersion=Number(cp.progressVersion||0)+1;cp.noProgressRuns=0;}
      next=changed(fresh,cp,cp.complete?'DONE':'RUNNING');save(tx,[next]);return true;
    }});if(!ok||!next)throw fail('任务进度未保存。','CONFLICT');return next;
  }
  async function deleteRows(job,env,name,field,value,nextPhase,extra=null){return transition(job,env,async(tx,cp)=>{let query=collection(env,name).query().equalTo(field,value);if(extra)query=query.equalTo(extra[0],extra[1]);const rows=await tx.executeQuery(query.limit(BATCH));if(rows.length)tx.executeDelete(rows);cp.processed=Number(cp.processed||0)+rows.length;if(rows.length<BATCH)cp.phase=nextPhase;});}
  async function mediaBatch(job,env,field,value,nextPhase,deadline){const fresh=await one(collection(env,'MaintenanceJob').query().equalTo('jobId',job.jobId));if(!fresh||fresh.leaseOwner!==job.leaseOwner)throw fail('租约已变化。','LEASE_LOST');
    const rows=await collection(env,'CardMedia').query().equalTo(field,value).limit(BATCH).get();
    for(const row of rows){if(Date.now()+20000>=deadline)return job;if(row.ownerUid!==job.ownerUid)throw fail('媒体归属无效。','INVALID_STATE');await transition(job,env,async()=>{});
      // Storage is not transactional: delete bytes first, retaining the DB row until a fenced commit.
      await ctx.removeMediaFiles(row,env);job=await transition(job,env,async(tx,cp)=>{const current=await txOne(tx,env,'CardMedia','id',row.id);if(current){if(current.ownerUid!==row.ownerUid||current.cardId!==row.cardId)throw fail('媒体归属已变化。','CONFLICT');tx.executeDelete([current]);cp.processed=Number(cp.processed||0)+1;}});}
    if(rows.length<BATCH)job=await transition(job,env,async(_tx,cp)=>{cp.phase=nextPhase;});return job;}
  async function purgeCard(job,env,deadline){const cp=progress(job),cardId=job.entityId;
    if(cp.phase==='MEDIA')return mediaBatch(job,env,'cardId',cardId,'REVISIONS',deadline);
    if(cp.phase==='REVISIONS'){const rows=await collection(env,'FoodCardRevision').query().equalTo('cardId',cardId).limit(1).get();if(!rows.length)return transition(job,env,async(_tx,c)=>{c.phase='REACTIONS';});
      const media=await collection(env,'CardMedia').query().equalTo('cardId','revision:'+rows[0].revisionId).limit(BATCH).get();for(const row of media){if(Date.now()+20000>=deadline)return job;await transition(job,env,async()=>{});if(row.ownerUid!==job.ownerUid)throw fail('媒体归属无效。','INVALID_STATE');await ctx.removeMediaFiles(row,env);job=await transition(job,env,async(tx,c)=>{const current=await txOne(tx,env,'CardMedia','id',row.id);if(current&&current.ownerUid!==job.ownerUid)throw fail('媒体归属已变化。','CONFLICT');if(current&&current.cardId==='revision:'+rows[0].revisionId){tx.executeDelete([current]);c.processed=Number(c.processed||0)+1;}});}
      if(!media.length)return transition(job,env,async(tx,c)=>{const revision=await txOne(tx,env,'FoodCardRevision','revisionId',rows[0].revisionId);if(revision&&revision.cardId===cardId)tx.executeDelete([revision]);c.processed=Number(c.processed||0)+1;});return job;}
    const steps={REACTIONS:['CardReaction','cardId',cardId,'LIKES'],LIKES:['CardAction','cardId',cardId,'COMMENTS',['kind','LIKE']],COMMENTS:['CardComment','cardId',cardId,'REPORTS'],REPORTS:['Report','cardId',cardId,'FINISH']};
    if(steps[cp.phase])return deleteRows(job,env,...steps[cp.phase]);
    if(cp.phase==='FINISH')return transition(job,env,async(tx,c)=>{const card=await txOne(tx,env,'FoodCard','id',cardId);if(card)tx.executeDelete([card]);c.complete=true;c.phase='DONE';});throw fail('卡片任务阶段无效。','INVALID_STATE');}
  const accountSteps=[['FoodCardRevision','authorUid'],['PublishRequestRecord','uid'],['CardAction','actorUid'],['CardReaction','uid'],['FoodListItem','ownerUid'],['FoodList','ownerUid'],['PersonalFoodState','ownerUid'],['TastePreference','uid'],['CardComment','authorUid'],['Report','reporterUid'],['FriendReport','reporterUid'],['FriendReport','targetUid'],['Friendship','memberAUid'],['Friendship','memberBUid'],['ChatMessage','senderUid'],['ChatMessage','recipientUid'],['Conversation','memberAUid'],['Conversation','memberBUid'],['NotificationEvent','recipientUid'],['NotificationEvent','actorUid'],['PushRegistration','ownerUid'],['WidgetRegistration','ownerUid'],['FriendContentAccessGrant','authorUid'],['FriendContentAccessGrant','viewerUid'],['AuthMigrationTicket','canonicalUid'],['MealPollVote','voterUid'],['MealPollOption','addedByUid'],['GroupMessage','senderUid']];
  async function account(job,env,deadline){const cp=progress(job),uid=job.entityId;
    if(cp.phase==='CARDS'){const rows=await collection(env,'FoodCard').query().equalTo('ownerUid',uid).limit(1).get();if(!rows.length)return transition(job,env,async(_tx,c)=>{c.phase='MEDIA';});
      const card=rows[0];return transition(job,env,async(tx,c,fresh)=>{const current=await txOne(tx,env,'FoodCard','id',card.id),owner=await txOne(tx,env,'UserProfile','uid',uid);if(!current)return;
        if(current.deletedAt==null){const now=ctx.logicalWriteTime(current.updatedAt,owner&&owner.updatedAt),generation=Number(current.lifecycleGeneration||0)+1,next=model('FoodCard',{...current,deletedAt:new Date(now),purgeAt:new Date(now),updatedAt:now,modifiedAt:new Date(now),lifecycleGeneration:generation});
          const counters=c.counterRemovalDeferred?await ctx.stage2().prepareCounterTransition(tx,current,next,{...owner,accountStatus:'ACTIVE'},env,now):[];
          const child=ctx.stage1().jobRow('PURGE_CARD',current.id,uid,generation,now,now,{physicalDeletionStarted:false,accountDeletion:true});save(tx,[next,...counters,child]);}
        else{const childId=ctx.stage1().hash('PURGE_CARD:'+current.id+':'+Number(current.lifecycleGeneration||0)),child=await txOne(tx,env,'MaintenanceJob','jobId',childId);if(child&&child.status==='FAILED')throw fail('卡片子任务失败，请先重试该任务。','CHILD_CLEANUP_REQUIRED');
          if(child&&['PENDING','RETRY_WAIT'].includes(child.status))save(tx,[model('MaintenanceJob',{...child,runAfterAt:new Date(),updatedAt:new Date()})]);if(!child)save(tx,[ctx.stage1().jobRow('PURGE_CARD',current.id,uid,Number(current.lifecycleGeneration||0),Date.now(),Date.now(),{physicalDeletionStarted:false,accountDeletion:true})]);
          if(dateMillis(current.purgeAt)>Date.now())save(tx,[model('FoodCard',{...current,purgeAt:new Date(),updatedAt:ctx.logicalWriteTime(current.updatedAt)})]);}c.waitForChild=true;});}
    if(cp.phase==='MEDIA')return mediaBatch(job,env,'ownerUid',uid,'GROUPS',deadline);
    if(cp.phase==='GROUPS'){const rows=await collection(env,'GroupMember').query().equalTo('memberUid',uid).limit(1).get();if(!rows.length)return transition(job,env,async(_tx,c)=>{c.phase='DATA';c.step=0;});
      return transition(job,env,async(tx,c)=>{const member=await txOne(tx,env,'GroupMember','id',rows[0].id);if(!member||member.memberUid!==uid)return;const group=await txOne(tx,env,'GroupConversation','id',member.groupId);const members=await tx.executeQuery(collection(env,'GroupMember').query().equalTo('groupId',member.groupId).limit(21));if(members.length===21)throw fail('群成员超过已验证预算。','INVALID_STATE');
        const others=members.filter(m=>m.memberUid!==uid).sort((a,b)=>String(a.memberUid).localeCompare(String(b.memberUid))),now=Date.now();if(group&&others.length){const lastMessage=group.lastMessageId ? await txOne(tx,env,'GroupMessage','id',group.lastMessageId) : null;if(lastMessage&&lastMessage.senderUid===uid){group.lastMessageId='';group.lastMessagePreview='';group.lastMessageKind='';group.lastMessageAt=0;}const nextOwner=group.ownerUid===uid?others[0].memberUid:group.ownerUid;save(tx,[model('GroupConversation',{...group,ownerUid:nextOwner,memberCount:others.length,updatedAt:now})]);if(group.ownerUid===uid)save(tx,[model('GroupMember',{...others[0],role:'OWNER',updatedAt:now})]);}
        if(group&&!others.length){save(tx,[ctx.stage1().jobRow('PURGE_GROUP',group.id,uid,now,now,now,{phase:'MESSAGES'})]);tx.executeDelete([group]);}tx.executeDelete([member]);c.processed=Number(c.processed||0)+1;});}
    if(cp.phase==='DATA'){const index=Number(cp.step||0),step=accountSteps[index];if(!step)return transition(job,env,async(_tx,c)=>{c.phase='MERCHANTS';});
      return transition(job,env,async(tx,c)=>{const rows=await tx.executeQuery(collection(env,step[0]).query().equalTo(step[1],uid).limit(BATCH));if(['MealPollVote','MealPollOption'].includes(step[0])){for(const pollId of [...new Set(rows.map(r=>r.pollId))]){const poll=await txOne(tx,env,'MealPoll','pollId',pollId);if(poll)save(tx,[model('MealPoll',{...poll,updatedAt:Date.now(),version:Number(poll.version||0)+1})]);}}if(rows.length)tx.executeDelete(rows);c.processed=Number(c.processed||0)+rows.length;if(rows.length<BATCH)c.step=index+1;});}
    if(cp.phase==='MERCHANTS')return transition(job,env,async(tx,c)=>{const rows=await tx.executeQuery(collection(env,'Merchant').query().equalTo('createdByUid',uid).limit(BATCH));if(rows.length)save(tx,rows.map(r=>model('Merchant',{...r,createdByUid:'',updatedAt:new Date()})));c.processed=Number(c.processed||0)+rows.length;if(rows.length<BATCH)c.phase='POLLS';});
    if(cp.phase==='POLLS'){const rows=await collection(env,'MealPoll').query().equalTo('creatorUid',uid).limit(BATCH).get();if(!rows.length)return transition(job,env,async(_tx,c)=>{c.phase='AUTH';});
      return transition(job,env,async(tx,c)=>{for(const row of rows){const poll=await txOne(tx,env,'MealPoll','pollId',row.pollId);if(poll&&poll.creatorUid===uid)save(tx,[model('MealPoll',{...poll,creatorUid:'',status:poll.status==='OPEN'?'CANCELLED':poll.status,acceptingOptions:false,closeReason:poll.status==='OPEN'?'ACCOUNT_DELETED':poll.closeReason,updatedAt:Date.now(),version:Number(poll.version||0)+1})]);}c.processed=Number(c.processed||0)+rows.length;});}
    if(cp.phase==='AUTH'){const bindings=await collection(env,'IdentityBinding').query().equalTo('canonicalUid',uid).limit(BATCH).get();if(!bindings.length)return transition(job,env,async(_tx,c)=>{c.phase='PROFILE';});
      for(const binding of bindings){if(Date.now()+35000>=deadline)return job;if(binding.provider==='AGC'&&cp.authConfirmed!==true){if(binding.providerUid!==job.authProviderUid||!job.authCredentialCiphertext)throw fail('需要在 AGC 核实并完成认证身份清理。','AUTH_ACTION_REQUIRED');await ctx.deleteAuthentication(job,binding,env);}
        job=await transition(job,env,async(tx,c,fresh)=>{const current=await txOne(tx,env,'IdentityBinding','id',binding.id);if(current&&current.canonicalUid===uid){tx.executeDelete([current]);c.processed=Number(c.processed||0)+1;}if(binding.provider==='AGC')fresh.authCredentialCiphertext='';});}return job;}
    if(cp.phase==='PROFILE')return transition(job,env,async(tx,c,fresh)=>{const owner=await txOne(tx,env,'UserProfile','uid',uid);if(owner){if(isAccountActive(owner))throw fail('账号重新活跃，拒绝清理。','INVALID_STATE');save(tx,[model('UserProfile',{uid,accountStatus:'DELETED',deletionJobId:fresh.jobId,nickname:'已注销用户',nicknameValue:'已注销用户',avatarUrl:'',avatarMediaId:'',avatarStorageUid:'',coverMediaId:'',coverStorageUid:'',friendCode:'',publishCount:0,createdAt:0,updatedAt:Date.now(),contentSequence:Number(owner.contentSequence||0)+1})]);}c.phase='DONE';c.complete=true;fresh.authCredentialCiphertext='';});throw fail('账号任务阶段无效。','INVALID_STATE');}
  async function group(job,env){const cp=progress(job),groupId=job.entityId;
    if(cp.phase==='MESSAGES')return deleteRows(job,env,'GroupMessage','groupId',groupId,'POLLS');
    if(cp.phase==='POLLS'){const polls=await collection(env,'MealPoll').query().equalTo('groupId',groupId).limit(1).get();if(!polls.length)return transition(job,env,async(_tx,c)=>{c.phase='DONE';c.complete=true;});
      const poll=polls[0],votes=await collection(env,'MealPollVote').query().equalTo('pollId',poll.pollId).limit(BATCH).get();if(votes.length)return transition(job,env,async(tx,c)=>{tx.executeDelete(votes);c.processed=Number(c.processed||0)+votes.length;});const options=await collection(env,'MealPollOption').query().equalTo('pollId',poll.pollId).limit(BATCH).get();if(options.length)return transition(job,env,async(tx,c)=>{tx.executeDelete(options);c.processed=Number(c.processed||0)+options.length;});return transition(job,env,async(tx,c)=>{const current=await txOne(tx,env,'MealPoll','pollId',poll.pollId);if(current&&current.groupId===groupId){tx.executeDelete([current]);c.processed=Number(c.processed||0)+1;}});}throw fail('群任务阶段无效。','INVALID_STATE');}
  async function process(jobId,env,deadline=Date.now()+45000){enabled(env);if(!flag(env,'SHIKE_MAINTENANCE_ENABLED'))throw fail('清理执行开关尚未开启。','FEATURE_NOT_READY');const initial=await one(collection(env,'MaintenanceJob').query().equalTo('jobId',id(jobId)));
    if(initial && LEGACY_TYPES.includes(initial.jobType)){try{await ctx.processLegacyJob(initial,env);return {processed:true};}catch(error){await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{const fresh=await txOne(tx,env,'MaintenanceJob','jobId',initial.jobId);if(!fresh||!['PENDING','RETRY_WAIT'].includes(fresh.status)||dateMillis(fresh.updatedAt)!==dateMillis(initial.updatedAt))return true;const attempts=Number(fresh.attemptCount||0)+1;save(tx,[model('MaintenanceJob',{...fresh,status:attempts>=8?'FAILED':'RETRY_WAIT',attemptCount:attempts,lastErrorCode:maintenanceCode(error),runAfterAt:new Date(Date.now()+Math.min(3600000,30000*2**Math.min(6,attempts))),updatedAt:new Date(ctx.logicalWriteTime(dateMillis(fresh.updatedAt)))})]);return true;}});throw error;}}
    let job;
    try{job=await claim(id(jobId),env);}catch(error){await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{const fresh=await txOne(tx,env,'MaintenanceJob','jobId',jobId);if(!fresh||!initial||dateMillis(fresh.updatedAt)!==dateMillis(initial.updatedAt)||!TYPES.includes(fresh.jobType)||!['PENDING','RETRY_WAIT','RUNNING'].includes(fresh.status)||fresh.status==='RUNNING'&&dateMillis(fresh.leaseUntilAt)>Date.now())return true;const code=maintenanceCode(error),attempts=Number(fresh.attemptCount||0)+1;save(tx,[model('MaintenanceJob',{...fresh,status:code==='INVALID_STATE'||attempts>=8?'FAILED':'RETRY_WAIT',attemptCount:attempts,lastErrorCode:code,leaseOwner:'',leaseUntilAt:null,updatedAt:new Date(ctx.logicalWriteTime(dateMillis(fresh.updatedAt))),runAfterAt:new Date(Date.now()+60000)})]);return true;}});throw error;}
    if(!job)return {processed:false};
    const initialProgress=Number(progress(job).progressVersion||0);
    try{for(let count=0;count<3&&job.status==='RUNNING'&&Date.now()+5000<deadline;count++){job=await(job.jobType==='PURGE_CARD'?purgeCard(job,env,deadline):job.jobType==='DELETE_ACCOUNT'?account(job,env,deadline):group(job,env));if(progress(job).waitForChild)break;}
      if(job.status!=='DONE')job=await transition(job,env,async(_tx,cp)=>{delete cp.waitForChild;if(Number(cp.progressVersion||0)===initialProgress)cp.noProgressRuns=Number(cp.noProgressRuns||0)+1;});await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{const fresh=await txOne(tx,env,'MaintenanceJob','jobId',job.jobId);if(fresh&&fresh.leaseOwner===job.leaseOwner)save(tx,[model('MaintenanceJob',{...fresh,status:fresh.status==='DONE'?'DONE':'PENDING',attemptCount:0,runAfterAt:new Date(Date.now()+1000),leaseOwner:'',leaseUntilAt:null,updatedAt:new Date(ctx.logicalWriteTime(dateMillis(fresh.updatedAt)))})]);return true;}});return {processed:true};
    }catch(error){await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{const fresh=await txOne(tx,env,'MaintenanceJob','jobId',job.jobId);if(!fresh||fresh.leaseOwner!==job.leaseOwner||['DONE','CANCELLED'].includes(fresh.status))return true;const code=maintenanceCode(error),cp=progress(fresh);if(code==='AUTH_ACTION_REQUIRED'&&!cp.authActionRequiredAt)cp.authActionRequiredAt=Date.now();cp.noProgressRuns=Number(cp.noProgressRuns||0)+1;const failed=Number(fresh.attemptCount||0)>=8||code==='AUTH_ACTION_REQUIRED'||code==='INVALID_STATE'||code==='CHILD_CLEANUP_REQUIRED'||code==='CONFIGURATION_REQUIRED';
      save(tx,[model('MaintenanceJob',{...fresh,status:failed?'FAILED':'RETRY_WAIT',lastErrorCode:code,checkpointJson:JSON.stringify(cp),leaseOwner:'',leaseUntilAt:null,runAfterAt:new Date(Date.now()+Math.min(3600000,30000*2**Math.min(6,Number(fresh.attemptCount||0)))),updatedAt:new Date(ctx.logicalWriteTime(dateMillis(fresh.updatedAt)))})]);return true;}});throw error;}}
  async function tick(env){
    enabled(env);if(!flag(env,'SHIKE_MAINTENANCE_ENABLED'))return {enabled:false,processed:0};
    let processed=0,failed=0,observed=0,oldestWaitMs=0,stalled=0,overdue=0,failedObserved=0,oldestFailedAgeMs=0,authAwaitingObserved=0;const started=Date.now(),deadline=started+45000;
    const types=[...TYPES,...LEGACY_TYPES],rotation=Math.floor(Date.now()/300000)%types.length,ordered=types.slice(rotation).concat(types.slice(0,rotation));
    try{
      const failedRows=await collection(env,'MaintenanceJob').query().equalTo('status','FAILED').orderByAsc('runAfterAt').orderByAsc('jobId').limit(3).get();
      for(const row of failedRows){const summary=view(row);failedObserved++;if(summary.authActionRequired)authAwaitingObserved++;
        oldestFailedAgeMs=Math.max(oldestFailedAgeMs,Math.max(0,Date.now()-(dateMillis(row.createdAt)||Date.now())));
        if(summary.overdue)overdue++;if(summary.stalled||summary.noProgressRuns>=3)stalled++;}
      for(const type of ordered)for(const state of ['PENDING','RETRY_WAIT','RUNNING']){
        if(processed>=3||Date.now()+5000>=deadline)return {enabled:true,processed};
        if(type==='PURGE_CONVERSATION'&&state==='RUNNING')continue;
        const timeField=state==='RUNNING'?'leaseUntilAt':'runAfterAt';
        const rows=await collection(env,'MaintenanceJob').query().equalTo('status',state).equalTo('jobType',type)
          .lessThanOrEqualTo(timeField,new Date()).orderByAsc(timeField).orderByAsc('jobId').limit(3-processed).get();
        for(const row of rows){
          if(processed>=3||Date.now()+5000>=deadline)break;
          const summary=view(row);observed++;oldestWaitMs=Math.max(oldestWaitMs,Math.max(0,Date.now()-(dateMillis(row.runAfterAt)||Date.now())));
          if(summary.stalled||summary.noProgressRuns>=3)stalled++;if(summary.overdue)overdue++;
          try{const result=await process(row.jobId,env,deadline);if(result.processed)processed++;}
          catch(error){processed++;failed++;console.warn('maintenance.tick code='+maintenanceCode(error));}
        }
      }
      return {enabled:true,processed};
    }finally{
      // Bounded due-task sample, not a global queue count or cross-instance rate limit.
      console.info('maintenance.metrics '+JSON.stringify({metricsVersion:'o6-20261008-v1',processed,failed,observed,
        oldestDueWaitMs:oldestWaitMs,stalledObserved:stalled,overdueObserved:overdue,failedObserved,oldestFailedAgeMs,authAwaitingObserved,elapsedMs:Date.now()-started,sampleScope:'due-and-failed-samples-no-global-count'}));
    }
  }

  async function jobs(uid,payload,env){
    await ctx.assertAdmin(uid,env);const state=String(payload.status||'FAILED');
    if(!['PENDING','RUNNING','RETRY_WAIT','FAILED','DONE','CANCELLED'].includes(state))throw fail('任务状态无效。');
    const signature=hash(['jobs8',uid,state]),saved=token(payload.cursor,signature);
    let query=collection(env,'MaintenanceJob').query().equalTo('status',state).orderByAsc('runAfterAt').orderByAsc('jobId');
    if(saved){const last=await one(collection(env,'MaintenanceJob').query().equalTo('jobId',id(saved.lastId)));
      if(!last||last.status!==state||dateMillis(last.updatedAt)!==saved.lastVersion||dateMillis(last.runAfterAt)!==saved.lastStamp)throw fail('任务队列已变化，请刷新。','CURSOR_STALE');
      query=query.startAfter(model('MaintenanceJob',last));}
    const rows=await query.limit(12).get();await ctx.assertAdmin(uid,env);const last=rows[rows.length-1];
    return {items:rows.map(view),nextCursor:rows.length===12?encode(signature,saved?saved.at:Date.now(),
      {lastId:last.jobId,lastStamp:dateMillis(last.runAfterAt),lastVersion:dateMillis(last.updatedAt)}):''};
  }

  async function jobDetail(uid,payload,env){await ctx.assertAdmin(uid,env);const job=await one(collection(env,'MaintenanceJob').query().equalTo('jobId',id(payload.jobId)));if(!job)throw fail('任务不存在。','NOT_FOUND');const signature=hash(['identities',uid,job.jobId,dateMillis(job.updatedAt)]),saved=token(payload.identityCursor,signature),offset=saved?int(saved.offset,0,10000000):0;const identities=job.jobType==='DELETE_ACCOUNT'&&job.lastErrorCode==='AUTH_ACTION_REQUIRED'?await collection(env,'IdentityBinding').query().equalTo('canonicalUid',job.entityId).orderByAsc('id').limit(10,offset).get():[];
    const fresh=await one(collection(env,'MaintenanceJob').query().equalTo('jobId',job.jobId));await ctx.assertAdmin(uid,env);if(!fresh||dateMillis(fresh.updatedAt)!==dateMillis(job.updatedAt))throw fail('任务已变化，请刷新。','CONFLICT');const cp=progress(job),audit=job.jobType==='MODERATION_AUDIT'?{kind:String(cp.kind||''),action:String(cp.action||''),reason:String(cp.reason||''),requestId:String(cp.requestId||''),operatorUid:String(job.ownerUid||'')}:null;return {job:view(job),audit,authIdentities:identities.filter(x=>x.provider==='AGC').map(x=>({provider:'AGC',providerUid:x.providerUid})),hasMoreIdentities:identities.length===10,nextIdentityCursor:identities.length===10?encode(signature,saved?saved.at:Date.now(),{offset:offset+10}):''};}
  async function retry(uid,payload,env,confirmAuth=false){await ctx.assertAdmin(uid,env);enabled(env);const jobId=id(payload.jobId),requestId=uuid(payload.requestId),expected=int(payload.expectedVersion,0,Number.MAX_SAFE_INTEGER),receiptId=hash(['job8',uid,requestId]),payloadHash=hash([jobId,expected,confirmAuth]);
    const committed=await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{await ctx.assertAdmin(uid,env);const admin=await ctx.stage1().activeProfile(tx,uid,env),receipt=await txOne(tx,env,'PublishRequestRecord','requestId',receiptId);if(receipt){if(receipt.uid!==uid||receipt.payloadHash!==payloadHash||receipt.operationType!=='RETRY_LIFECYCLE')throw fail('请求标识冲突。','CONFLICT');return true;}
      const job=await txOne(tx,env,'MaintenanceJob','jobId',jobId);if(!job||![...TYPES,...LEGACY_TYPES].includes(job.jobType)||!['FAILED','RETRY_WAIT'].includes(job.status)||dateMillis(job.updatedAt)!==expected)throw fail('任务已变化或不能重试。','CONFLICT');const cp=progress(job);
      if(['BACKFILL_CARD','MIGRATE_REACTION'].includes(job.jobType)){cp.failures=0;cp.failedEntityId='';if(job.lastErrorCode==='COVERAGE_INCOMPLETE'){cp.phase='MIGRATE';cp.verificationCursor='';cp.verificationScanned=0;cp.verificationMissing=0;cp.coverageComplete=false;job.cursor='';}}
      if(confirmAuth){if(job.jobType!=='DELETE_ACCOUNT'||job.lastErrorCode!=='AUTH_ACTION_REQUIRED'||payload.confirmDeleted!==true)throw fail('请先在 AGC 控制台核实认证身份均已删除。');cp.authConfirmed=true;}
      const now=ctx.logicalWriteTime(admin.updatedAt,dateMillis(job.updatedAt));save(tx,[model('MaintenanceJob',{...job,status:'PENDING',attemptCount:0,lastErrorCode:'',leaseOwner:'',leaseUntilAt:null,runAfterAt:new Date(now),updatedAt:new Date(now),checkpointJson:JSON.stringify(cp)}),ctx.profileForWrite(admin,now),
        model('PublishRequestRecord',{requestId:receiptId,uid,operationType:'RETRY_LIFECYCLE',payloadHash,resultEntityId:jobId,status:'COMMITTED',createdAt:new Date(now),expiresAt:new Date(now+30*DAY)})]);if(confirmAuth){const audit=ctx.stage1().jobRow('MODERATION_AUDIT',jobId,uid,now,now,now,{kind:'AUTH_CLEANUP',action:'CONFIRM_DELETED',reason:'管理员已核实 AGC 认证身份均已删除',requestId});audit.status='DONE';save(tx,[audit]);}return true;
    }});if(!committed)throw fail('重试未保存。','CONFLICT');return {success:true};}
  return {deleted,restore,process,tick,jobs,jobDetail,retry,view};
}
module.exports={createLifecycleServices};
