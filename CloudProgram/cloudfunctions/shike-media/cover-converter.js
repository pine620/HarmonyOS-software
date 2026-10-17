/**
 * 【文件职责】生成 480px 封面：在独立的 worker 线程中执行 cover-worker.js（限制内存 96MB、超时 12 秒），同一实例同时只转换一张。
 */
'use strict';
const {Worker}=require('node:worker_threads');
const path=require('node:path');
let busy=false;
// 把原图 JPEG 字节转换为封面；忙碌时抛出 COVER_BUSY，超时抛出 COVER_TIMEOUT。
exports.convert=async bytes=>{
 if(busy)throw Object.assign(new Error('Cover worker busy'),{code:'COVER_BUSY'});
 if(!Buffer.isBuffer(bytes)||bytes.length<4||bytes.length>2097152)throw new Error('Invalid source');
 busy=true;
 let worker,timer;
 try{return await new Promise((resolve,reject)=>{
   worker=new Worker(path.join(__dirname,'cover-worker.js'),{workerData:bytes,resourceLimits:{maxOldGenerationSizeMb:96,maxYoungGenerationSizeMb:16}});
   timer=setTimeout(()=>reject(Object.assign(new Error('Cover conversion timeout'),{code:'COVER_TIMEOUT'})),12000);
   worker.once('message',value=>value&&value.error?reject(new Error(value.error)):resolve(value));
   worker.once('error',reject);worker.once('exit',code=>reject(new Error('Cover worker exited '+code)));
 });}finally{clearTimeout(timer);if(worker)await worker.terminate();busy=false;}
};
