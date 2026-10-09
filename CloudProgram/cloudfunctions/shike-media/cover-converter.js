'use strict';
const {Worker}=require('node:worker_threads');
const path=require('node:path');
let busy=false;
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
