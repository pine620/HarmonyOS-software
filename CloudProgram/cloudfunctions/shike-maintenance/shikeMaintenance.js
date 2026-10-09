'use strict';
const crypto=require('crypto');
const {runMaintenance}=require('./service/runtime');
const {runCoverBackfill}=require('./media/runtime');
const {READ_OPT_VERSION}=require('./shared/read-errors');
const {buildInfo}=require('./shared/release-info');
exports.handler=async(event,context,callback)=>{
  try{
    let input=event;if(typeof input==='string')input=JSON.parse(input);
    if(input&&typeof input.userData==='string')input=JSON.parse(input.userData);
    const expected=String(process.env.SHIKE_MAINTENANCE_TRIGGER_KEY||''),actual=String(input&&input.workerToken||'');
    if(! /^[A-Za-z0-9_-]{32,256}$/.test(expected)||actual.length!==expected.length||! /^[A-Za-z0-9_-]{32,256}$/.test(actual)||!crypto.timingSafeEqual(Buffer.from(expected),Buffer.from(actual)))throw Object.assign(new Error('Timer credential invalid.'),{code:'TRIGGER_ACCESS_DENIED'});
    const result=input.action==='media-covers'?await runCoverBackfill(process.env,input.retryFailed===true):await runMaintenance(process.env);const response={ok:true,data:result,functionVersion:READ_OPT_VERSION,...buildInfo};if(typeof callback==='function')return callback(response);return response;
  }catch(error){const response={ok:false,code:String(error&&error.code||'MAINTENANCE_FAILED').slice(0,64),message:'清理任务未完成，请核对开关、触发器和任务日志。',functionVersion:READ_OPT_VERSION,...buildInfo};if(typeof callback==='function')return callback(response);return response;}
};
