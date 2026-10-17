/**
 * 【文件职责】事件函数 shike-maintenance（handler：shikeMaintenance.handler，无 HTTP 触发器）：由 AGC 控制台中的定时器调用。
 * 请求必须携带与环境变量 SHIKE_MAINTENANCE_TRIGGER_KEY（≥32 位）完全一致的 workerToken（定长比较）。按 action 分派：
 *   home-snapshot  生成游客首页快照（建议每 5 分钟）    media-covers  回填旧图片的 480px 封面
 *   lifecycle（默认）执行到期的清理任务（删卡、注销、清群）  card-history / reaction-history  历史数据维护
 *   public-content  公开内容整理                       nickname-claims  昵称数据迁移
 * 定时器的推荐配置见同目录 timer-contract.json（该文件只是说明，不会自动创建定时器）。依赖的 service/、media/、shared/ 为生成副本。
 */
'use strict';
const crypto=require('crypto');
const {runMaintenance,migrateNicknameClaims,normalizePublicContent,maintainCardHistory,maintainReactionHistory,executeOperation,safeLogError}=require('./service/runtime');
const {HOME_REQUEST,writeSnapshot}=require('./shared/public-snapshot');
const {runCoverBackfill}=require('./media/runtime');
const {READ_OPT_VERSION,errorCode}=require('./shared/read-errors');
const {buildInfo}=require('./shared/release-info');
// 维护入口：校验定时器凭据 → 按 action 执行 → 返回统一格式的结果。
exports.handler=async(event,context,callback)=>{
  try{
    let input=event;if(typeof input==='string')input=JSON.parse(input);
    if(input&&typeof input.userData==='string')input=JSON.parse(input.userData);
    const expected=String(process.env.SHIKE_MAINTENANCE_TRIGGER_KEY||''),actual=String(input&&input.workerToken||'');
    if(! /^[A-Za-z0-9_-]{32,256}$/.test(expected)||actual.length!==expected.length||! /^[A-Za-z0-9_-]{32,256}$/.test(actual)||!crypto.timingSafeEqual(Buffer.from(expected),Buffer.from(actual)))throw Object.assign(new Error('Timer credential invalid.'),{code:'TRIGGER_ACCESS_DENIED'});
    if(input.action!==undefined&&!['public-content','media-covers','lifecycle','card-history','reaction-history','nickname-claims','home-snapshot'].includes(input.action))throw Object.assign(new Error('Unknown maintenance action.'),{code:'VALIDATION_ERROR'});
    let result;
    // home-snapshot：每次定时触发时把游客首页第一页渲染一次，并发布到 Cloud Storage。
    if(input.action==='home-snapshot')result=await writeSnapshot(await executeOperation('list-nearby-cards',{payload:{...HOME_REQUEST},readRequestId:'home-snapshot-'+crypto.randomUUID()},process.env),process.env);
    else if(input.action==='nickname-claims')result=await migrateNicknameClaims(process.env);
    else if(input.action==='reaction-history')result=await maintainReactionHistory({mode:input.mode},process.env);
    else if(input.action==='card-history')result=await maintainCardHistory({mode:input.mode},process.env);
    else if(input.action==='public-content')result=await normalizePublicContent(process.env,input.cursor===undefined?'':input.cursor);
    else if(input.action==='media-covers')result=await runCoverBackfill(process.env,input.retryFailed===true);
    else result=await runMaintenance(process.env);
    const response={ok:true,data:result,functionVersion:READ_OPT_VERSION,...buildInfo};if(typeof callback==='function')return callback(response);return response;
  }catch(error){const code=errorCode(error);console.error('maintenance.action failed code='+code+' '+safeLogError(error));const response={ok:false,code,message:'维护任务未完成，请核对配置和任务日志。',functionVersion:READ_OPT_VERSION,...buildInfo};if(typeof callback==='function')return callback(response);return response;}
};
