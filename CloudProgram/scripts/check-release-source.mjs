import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
// User-run release check. Reads sources and performs syntax checks; never loads
// handlers, credentials, devices or cloud clients and never deploys anything.
const cloud=resolve(dirname(fileURLToPath(import.meta.url)),'..'),root=dirname(cloud);
const reportPath=process.argv[2] ? resolve(process.argv[2]) : join(dirname(root),'docs','stages8-9','user-release-source-report.json');
const results=[];
function check(name,ok,detail=''){results.push({name,ok:Boolean(ok),detail});}
function source(path){return readFileSync(join(root,path),'utf8');}
const schema=JSON.parse(source('CloudProgram/AppScope/resources/rawfile/schema.json'));
check('schema version',schema.schemaVersion===41,'Expected schema 41, all new fields/indexes must also be deployed by the user.');
for(const object of schema.objectTypes){
  const file=join(cloud,'clouddb/objecttype',object.objectTypeName+'.json');
  check('schema file '+object.objectTypeName,existsSync(file));if(!existsSync(file))continue;
  const definition=JSON.parse(readFileSync(file,'utf8'));
  check('fields '+object.objectTypeName,JSON.stringify(object.fields)===JSON.stringify(definition.fields));
  check('indexes '+object.objectTypeName,JSON.stringify(object.indexes||[])===JSON.stringify(definition.indexes||[]));
  const fields=new Set(object.fields.map(field=>field.fieldName));
  check('index shape '+object.objectTypeName,(object.indexes||[]).length<=16&&(object.indexes||[]).every(index=>index.indexList.length<=5&&index.indexList.every(field=>fields.has(field.fieldName))));
}
const service='CloudProgram/cloudfunctions/shike-service/';
const modules=['runtime.js','content-policy.js','stage1-services.js','stage2-services.js','stage3-services.js','stages47-common.js','stage4-services.js','stage5-services.js','stage6-services.js','stage7-services.js','personal-collections.js','moderation-services.js','lifecycle-services.js','authentication-cleanup.js','read-errors.js'];
for(const module of modules){
  const file=join(root,service,module);check('module '+module,existsSync(file));if(!existsSync(file))continue;
  const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8',shell:false});
  check('syntax '+module,!result.error&&result.status===0,(result.stderr||'').trim());
}
const methods={getStage89Capabilities:'get-stage89-capabilities',listModerationQueue:'list-moderation-queue',getModerationDetail:'get-moderation-detail',decideModeration:'decide-moderation',listMyReports:'list-my-reports',reportMerchant:'report-merchant',listOwnReviewRequests:'list-own-review-requests',listDeletedCards:'list-deleted-cards',restoreDeletedCard:'restore-deleted-card',listLifecycleJobs:'list-lifecycle-jobs',getLifecycleJob:'get-lifecycle-job',retryLifecycleJob:'retry-lifecycle-job',confirmAuthCleanup:'confirm-auth-cleanup',getReviewMedia:'get-review-media',runLifecycleJob:'run-lifecycle-job'};
const entry=source(service+'shikeService.ts'),runtime=source(service+'runtime.js'),gateway=source('Application/entry/src/main/ets/service/CloudGateway.ets');
for(const [method,operation]of Object.entries(methods))check('contract '+operation,entry.includes(method+'(input: CloudEnvelope)')&&entry.includes("executeCloudOperation('"+operation+"'")&&runtime.includes("'"+operation+"':")&&gateway.includes("case '"+operation+"':")&&gateway.includes("invokeStage47('"+method+"'"));
const policy=source(service+'content-policy.js');
for(const name of ['media','location'])check('policy parity '+name,policy===source('CloudProgram/cloudfunctions/shike-'+name+'/content-policy.js'));
for(const path of ['scripts/package-cloud-object.mjs','scripts/package-share-http.mjs','scripts/package-maintenance.mjs']){
  const text=source('CloudProgram/'+path);check('bundle '+path,['moderation-services.js','lifecycle-services.js','authentication-cleanup.js'].every(name=>text.includes(name)));
}
const worker='CloudProgram/cloudfunctions/shike-maintenance/';
const config=JSON.parse(source(worker+'function-config.json')),contract=JSON.parse(source(worker+'timer-contract.json'));
check('worker handler',config.handler==='shikeMaintenance.handler'&&config.functionType===0);
check('timer contract',contract.httpTrigger===false&&contract.maximumJobsPerInvocation===3&&contract.rowsPerCleanupStep===10);
check('no shipped triggers',(config.triggers||[]).length===0,'AGC timer must be configured and verified separately; this file intentionally contains no provider-specific trigger definition.');
for(const path of [worker+'shikeMaintenance.js','CloudProgram/cloudfunctions/shike-media/runtime.js','CloudProgram/cloudfunctions/shike-location/runtime.js','CloudProgram/scripts/package-maintenance.mjs']){
  const result=spawnSync(process.execPath,['--check',join(root,path)],{encoding:'utf8',shell:false});check('syntax '+path,!result.error&&result.status===0,(result.stderr||'').trim());
}
const lifecycle=source(service+'lifecycle-services.js');
check('worker gates',lifecycle.includes("'SHIKE_LIFECYCLE_VERIFIED'")&&lifecycle.includes("'SHIKE_MAINTENANCE_ENABLED'"));
check('production recovery',runtime.includes('SHIKE_ENVIRONMENT')&&runtime.includes('SHIKE_TEST_RECOVERY_SECONDS'),'A source check cannot verify deployed environment values.');
const trace=source('Application/entry/src/main/ets/service/FeaturePerformanceTrace.ets');
for(const name of ['map_first_render','map_marker_query','search_first_result','today_eat_candidates','food_list_first_page','draft_restore','poll_refresh'])check('trace '+name,trace.includes("'"+name+"'"));
const failed=results.filter(result=>!result.ok);
const report={checkedAt:new Date().toISOString(),sourceVersion:'stages89-20261007-v1',nodeVersion:process.version,checks:results,failedCount:failed.length,scope:'Source/schema/contracts/syntax only. ArkTS build, actual cloud configuration, timer delivery, Auth REST execution, runtime regression and performance are user validation tasks.'};
mkdirSync(dirname(reportPath),{recursive:true});writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
console.log('Source checks: '+results.length+'; failed: '+failed.length+'; report: '+reportPath);
for(const result of failed)console.error(result.name+': '+result.detail);
process.exitCode=failed.length?1:0;
