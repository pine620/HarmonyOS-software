'use strict';
const crypto=require('crypto');
const {runMaintenance,normalizePublicContent,safeLogError}=require('./service/runtime');
const {runCoverBackfill}=require('./media/runtime');
const {READ_OPT_VERSION,errorCode}=require('./shared/read-errors');
const {buildInfo}=require('./shared/release-info');
exports.handler=async(event,context,callback)=>{
  try{
    let input=event;if(typeof input==='string')input=JSON.parse(input);
    if(input&&typeof input.userData==='string')input=JSON.parse(input.userData);
    const expected=String(process.env.SHIKE_MAINTENANCE_TRIGGER_KEY||''),actual=String(input&&input.workerToken||'');
    if(! /^[A-Za-z0-9_-]{32,256}$/.test(expected)||actual.length!==expected.length||! /^[A-Za-z0-9_-]{32,256}$/.test(actual)||!crypto.timingSafeEqual(Buffer.from(expected),Buffer.from(actual)))throw Object.assign(new Error('Timer credential invalid.'),{code:'TRIGGER_ACCESS_DENIED'});
    if(input.action!==undefined&&!['public-content','media-covers','lifecycle'].includes(input.action))throw Object.assign(new Error('Unknown maintenance action.'),{code:'VALIDATION_ERROR'});
    const result=input.action==='public-content'?await normalizePublicContent(process.env,input.cursor===undefined?'':input.cursor):input.action==='media-covers'?await runCoverBackfill(process.env,input.retryFailed===true):await runMaintenance(process.env);const response={ok:true,data:result,functionVersion:READ_OPT_VERSION,...buildInfo};if(typeof callback==='function')return callback(response);return response;
  }catch(error){const code=errorCode(error);console.error('maintenance.action failed code='+code+' '+safeLogError(error));const response={ok:false,code,message:'维护任务未完成，请核对配置和任务日志。',functionVersion:READ_OPT_VERSION,...buildInfo};if(typeof callback==='function')return callback(response);return response;}
};
