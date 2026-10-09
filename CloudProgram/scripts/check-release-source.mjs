import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
// User-run release check. Reads sources and performs syntax checks; never loads
// handlers, credentials, devices or cloud clients and never deploys anything.
const cloud=resolve(dirname(fileURLToPath(import.meta.url)),'..'),root=dirname(cloud);
const reportPath=process.argv[2] ? resolve(process.argv[2]) : join(dirname(root),'docs','image-pipeline-rebuild-20261009','execution','user-release-source-report.json');
const results=[];
function check(name,ok,detail=''){results.push({name,ok:Boolean(ok),detail});}
function source(path){return readFileSync(join(root,path),'utf8');}
// AGC's aggregate export includes explicit false flags and numeric defaults as
// strings; objecttype files use omitted flags and JSON numbers. Compare their
// meaning without reformatting or replacing the deployed schema definitions.
function fieldShape(fields){return fields.map(field=>{
  const value={...field};
  for(const key of ['belongPrimaryKey','notNull','isNeedEncrypt','isSensitive'])value[key]=field[key]===true;
  if(value.defaultValue!==undefined&&['Byte','Short','Integer','Long','Float','Double'].includes(value.fieldType))value.defaultValue=String(value.defaultValue);
  return Object.fromEntries(Object.keys(value).sort().map(key=>[key,value[key]]));
}).sort((a,b)=>a.fieldName.localeCompare(b.fieldName));}
function indexShape(indexes){return (indexes||[]).map(index=>({name:index.indexName,fields:index.indexList.map(field=>[field.fieldName,field.sortType||'ASC'])})).sort((a,b)=>a.name.localeCompare(b.name));}
const schema=JSON.parse(source('CloudProgram/AppScope/resources/rawfile/schema.json'));
check('schema version',Number.isSafeInteger(schema.schemaVersion)&&schema.schemaVersion>0,'Source version is recorded; compare the actual deployment export before changing it.');
for(const object of schema.objectTypes){
  const file=join(cloud,'clouddb/objecttype',object.objectTypeName+'.json');
  check('schema file '+object.objectTypeName,existsSync(file));if(!existsSync(file))continue;
  const definition=JSON.parse(readFileSync(file,'utf8'));
  check('fields '+object.objectTypeName,JSON.stringify(fieldShape(object.fields))===JSON.stringify(fieldShape(definition.fields)));
  check('primary keys '+object.objectTypeName,JSON.stringify(object.fields.filter(field=>field.belongPrimaryKey).map(field=>field.fieldName))===JSON.stringify(definition.fields.filter(field=>field.belongPrimaryKey).map(field=>field.fieldName)));
  check('indexes '+object.objectTypeName,JSON.stringify(indexShape(object.indexes))===JSON.stringify(indexShape(definition.indexes)));
  const fields=new Set(object.fields.map(field=>field.fieldName));
  check('index shape '+object.objectTypeName,(object.indexes||[]).length<=16&&(object.indexes||[]).every(index=>index.indexList.length<=5&&index.indexList.every(field=>fields.has(field.fieldName))));
}
// Existing index definitions and sensitivity flags are immutable in deployed
// schemas. Guard the known deployment baseline instead of rewriting them.
for(const [name,indexName,expected] of [
  ['FoodCard','status_score_published_id',[['status','ASC'],['tasteScore','DESC'],['publishedAt','DESC'],['id','ASC']]],
  ['PersonalFoodState','index_1',[['ownerUid','ASC'],['state','ASC'],['updatedAt','DESC'],['cardId','ASC']]]
]){
  const object=schema.objectTypes.find(object=>object.objectTypeName===name);
  const index=object?.indexes?.find(index=>index.indexName===indexName);
  check('preserve deployed index '+name+'.'+indexName,JSON.stringify(index?.indexList?.map(field=>[field.fieldName,field.sortType]))===JSON.stringify(expected));
}
const cardMedia=schema.objectTypes.find(object=>object.objectTypeName==='CardMedia');
for(const name of ['objectKey','sha256'])check('preserve sensitivity CardMedia.'+name,cardMedia?.fields?.find(field=>field.fieldName===name)?.isSensitive===true);
const service='CloudProgram/cloudfunctions/shike-service/';
const modules=['runtime.js','stage1-services.js','stage2-services.js','stage3-services.js','stages47-common.js','stage4-services.js','stage5-services.js','stage6-services.js','stage7-services.js','personal-collections.js','moderation-services.js','lifecycle-services.js','authentication-cleanup.js'];
for(const module of modules){
  const file=join(root,service,module);check('module '+module,existsSync(file));if(!existsSync(file))continue;
  const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8',shell:false});
  check('syntax '+module,!result.error&&result.status===0,(result.stderr||'').trim());
}
const methods={getStage89Capabilities:'get-stage89-capabilities',listModerationQueue:'list-moderation-queue',getModerationDetail:'get-moderation-detail',decideModeration:'decide-moderation',listMyReports:'list-my-reports',reportMerchant:'report-merchant',listOwnReviewRequests:'list-own-review-requests',listDeletedCards:'list-deleted-cards',restoreDeletedCard:'restore-deleted-card',listLifecycleJobs:'list-lifecycle-jobs',getLifecycleJob:'get-lifecycle-job',retryLifecycleJob:'retry-lifecycle-job',confirmAuthCleanup:'confirm-auth-cleanup',getReviewMedia:'get-review-media',runLifecycleJob:'run-lifecycle-job'};
Object.assign(methods,{getCardPreviews:'get-card-previews',listPersonalCollection:'list-personal-collection',getPersonalCollectionMigration:'get-personal-collection-migration',startPersonalCollectionMigration:'start-personal-collection-migration',resumePersonalCollectionMigration:'resume-personal-collection-migration',setCardFavorite:'set-card-favorite',setCardWanted:'set-card-wanted',getStage47Capabilities:'get-stage47-capabilities',getTastePreference:'get-taste-preference',updateTastePreference:'update-taste-preference',clearTastePreference:'clear-taste-preference',listPersonalizedRecommendations:'list-personalized-recommendations',getMealCandidates:'get-meal-candidates',createMealPoll:'create-meal-poll',getMealPoll:'get-meal-poll',addMealPollOption:'add-meal-poll-option',voteMealPoll:'vote-meal-poll',closeMealPoll:'close-meal-poll',cancelMealPoll:'cancel-meal-poll',stopMealPollOptions:'stop-meal-poll-options',getUserPage:'get-user-page',listMerchantRankings:'list-merchant-rankings',setCardReactionV2:'set-card-reaction-v2'});
const entry=source(service+'shikeService.ts'),runtime=source(service+'runtime.js'),gateway=source('Application/entry/src/main/ets/service/CloudGateway.ets');
for(const [method,operation]of Object.entries(methods))check('contract '+operation,entry.includes(method+'(input: CloudEnvelope)')&&entry.includes("executeCloudOperation('"+operation+"'")&&runtime.includes("'"+operation+"':")&&gateway.includes("case '"+operation+"':")&&gateway.includes("invokeStage47('"+method+"'"));
for(const name of ['content-policy.js','media-descriptor.js','read-errors.js','release-info.js','image-models.js','image-reader.js']) {
  const path='CloudProgram/cloudfunctions/shared/'+name;
  check('shared source '+name,existsSync(join(root,path)));
}
for(const folder of ['shike-media','shike-service','shike-location']) for(const name of ['content-policy.js','media-descriptor.js','read-errors.js'])
  check('no duplicate '+folder+'/'+name,!existsSync(join(cloud,'cloudfunctions',folder,name)));
for(const path of ['package-cloud-object.mjs','package-share-http.mjs','package-maintenance.mjs'])
  check('shared packager '+path,source('CloudProgram/scripts/'+path).includes('packageFunction'));
check('image SDK endpoint',gateway.includes("name: 'shike-image'")&&gateway.includes('cloudFunction.call(parameters)'));
check('no binary HTTP client',!existsSync(join(root,'Application/entry/src/main/ets/service/BinaryMediaTransport.ets')));
check('no obsolete preload',!existsSync(join(root,'Application/entry/src/main/ets/service/NearbyPreloadService.ets')));
const worker='CloudProgram/cloudfunctions/shike-maintenance/';
const config=JSON.parse(source(worker+'function-config.json')),contract=JSON.parse(source(worker+'timer-contract.json'));
check('worker handler',config.handler==='shikeMaintenance.handler'&&config.functionType===0);
check('timer contract',contract.httpTrigger===false&&contract.maximumJobsPerInvocation===3&&contract.rowsPerCleanupStep===10);
check('no shipped triggers',(config.triggers||[]).length===0,'AGC timer must be configured and verified separately; this file intentionally contains no provider-specific trigger definition.');
for(const path of [worker+'shikeMaintenance.js','CloudProgram/cloudfunctions/shared/image-reader.js','CloudProgram/cloudfunctions/shared/content-policy.js','CloudProgram/cloudfunctions/shike-image/shikeImage.js','CloudProgram/cloudfunctions/shike-media/runtime.js','CloudProgram/cloudfunctions/shike-media/cover-converter.js','CloudProgram/cloudfunctions/shike-media/cover-worker.js','CloudProgram/cloudfunctions/shike-location/runtime.js','CloudProgram/scripts/package-functions.mjs','CloudProgram/scripts/check-artifact.mjs']){
  const result=spawnSync(process.execPath,['--check',join(root,path)],{encoding:'utf8',shell:false});check('syntax '+path,!result.error&&result.status===0,(result.stderr||'').trim());
}
const lifecycle=source(service+'lifecycle-services.js');
check('worker gates',lifecycle.includes("'SHIKE_LIFECYCLE_VERIFIED'")&&lifecycle.includes("'SHIKE_MAINTENANCE_ENABLED'"));
check('production recovery',runtime.includes('SHIKE_ENVIRONMENT')&&runtime.includes('SHIKE_TEST_RECOVERY_SECONDS'),'A source check cannot verify deployed environment values.');
const trace=source('Application/entry/src/main/ets/service/FeaturePerformanceTrace.ets');
for(const name of ['map_first_render','map_marker_query','search_first_result','today_eat_candidates','food_list_first_page','draft_restore','poll_refresh'])check('trace '+name,trace.includes("'"+name+"'"));
const failed=results.filter(result=>!result.ok);
const report={checkedAt:new Date().toISOString(),sourceVersion:'image-read-v1',metricsVersion:'o0-20261008-v1',schemaVersion:schema.schemaVersion,nodeVersion:process.version,checks:results,failedCount:failed.length,scope:'Source/schema/contracts/syntax only. ArkTS build, actual cloud configuration, timer delivery, Auth REST execution, runtime regression and performance are user validation tasks.'};
mkdirSync(dirname(reportPath),{recursive:true});writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
console.log('Source checks: '+results.length+'; failed: '+failed.length+'; report: '+reportPath);
for(const result of failed)console.error(result.name+': '+result.detail);
process.exitCode=failed.length?1:0;
