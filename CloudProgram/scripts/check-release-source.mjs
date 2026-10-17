import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
/**
 * 【文件职责】发布前源码检查（npm run check:release-source，由负责人手动运行）：只读取源码并做语法检查，
 * 不加载 handler、不接触凭据 / 设备 / 云端，也不部署任何东西。检查内容：schema.json 与 objecttype 定义一致、必需索引存在、
 * 敏感字段与已部署字段保留、shike-service 模块齐全且语法正确、四处方法表一致、已退役操作没有被加回、维护函数配置等。
 * 报告默认写到仓库外的 docs/ 目录。
 */
const cloud=resolve(dirname(fileURLToPath(import.meta.url)),'..'),root=dirname(cloud);
const reportPath=process.argv[2] ? resolve(process.argv[2]) : join(dirname(root),'docs','image-pipeline-rebuild-20261009','execution','user-release-source-report.json');
const results=[];
// 记录一项检查结果。
function check(name,ok,detail=''){results.push({name,ok:Boolean(ok),detail});}
// 读取仓库中的源文件。
function source(path){return readFileSync(join(root,path),'utf8');}
// AGC 导出的汇总 schema 会显式写出 false 标记，并把数字 / 布尔默认值写成字符串；objecttype 文件则省略这些标记并使用 JSON 数字 / 布尔。这里比较含义，而不重新格式化或替换已部署的定义。
// 把字段定义规范化后用于比较。
function fieldShape(fields){return fields.map(field=>{
  const value={...field};
  for(const key of ['belongPrimaryKey','notNull','isNeedEncrypt','isSensitive'])value[key]=field[key]===true;
  if(value.defaultValue!==undefined&&['Byte','Short','Integer','Long','Float','Double','Boolean'].includes(value.fieldType))value.defaultValue=String(value.defaultValue);
  return Object.fromEntries(Object.keys(value).sort().map(key=>[key,value[key]]));
}).sort((a,b)=>a.fieldName.localeCompare(b.fieldName));}
// 把索引定义规范化后用于比较。
function indexShape(indexes){return (indexes||[]).map(index=>({name:index.indexName,fields:index.indexList.map(field=>[field.fieldName,field.sortType||'ASC'])})).sort((a,b)=>a.name.localeCompare(b.name));}
const schema=JSON.parse(source('CloudProgram/AppScope/resources/rawfile/schema.json'));
check('schema version',Number.isSafeInteger(schema.schemaVersion)&&schema.schemaVersion>0,'Source version is recorded; compare the actual deployment export before changing it.');
// 这个已退役的表保留在部署快照中以保存历史数据；它对应的已删除权限功能不能作为活动模型恢复。
const retiredSchemaObjects=new Set(['FriendContentAccessGrant']);
for(const object of schema.objectTypes){
  const file=join(cloud,'clouddb/objecttype',object.objectTypeName+'.json');
  if(!existsSync(file)&&retiredSchemaObjects.has(object.objectTypeName)){
    check('retired schema compatibility '+object.objectTypeName,
      !source('CloudProgram/cloudfunctions/shike-service/runtime.js').includes(object.objectTypeName)&&
      !source('CloudProgram/cloudfunctions/shared/content-policy.js').includes(object.objectTypeName));
    continue;
  }
  check('schema file '+object.objectTypeName,existsSync(file));if(!existsSync(file))continue;
  const definition=JSON.parse(readFileSync(file,'utf8'));
  check('fields '+object.objectTypeName,JSON.stringify(fieldShape(object.fields))===JSON.stringify(fieldShape(definition.fields)));
  check('primary keys '+object.objectTypeName,JSON.stringify(object.fields.filter(field=>field.belongPrimaryKey).map(field=>field.fieldName))===JSON.stringify(definition.fields.filter(field=>field.belongPrimaryKey).map(field=>field.fieldName)));
  check('indexes '+object.objectTypeName,JSON.stringify(indexShape(object.indexes))===JSON.stringify(indexShape(definition.indexes)));
  const fields=new Set(object.fields.map(field=>field.fieldName));
  const indexNames=(object.indexes||[]).map(index=>index.indexName);
  check('index names '+object.objectTypeName,indexNames.every(name=>typeof name==='string'&&/^[A-Za-z][A-Za-z0-9_]{0,29}$/.test(name))&&new Set(indexNames.map(name=>String(name).toLowerCase())).size===indexNames.length,'Index names must contain 1-30 letters, digits or underscores, start with a letter and be unique ignoring case.');
  check('index shape '+object.objectTypeName,(object.indexes||[]).length<=16&&(object.indexes||[]).every(index=>index.indexList.length<=5&&index.indexList.every(field=>fields.has(field.fieldName))));
}
// 保留已部署的共用索引定义，并要求新的榜单索引存在。
for(const [name,indexName,expected] of [
  ['FoodCard','public_time',[['visibility','ASC'],['status','ASC'],['publishedAt','DESC'],['id','ASC']]],
  ['FoodCard','public_price_asc',[['visibility','ASC'],['status','ASC'],['queryPriceFen','ASC'],['publishedAt','DESC'],['id','ASC']]],
  ['FoodCard','public_price_desc',[['visibility','ASC'],['status','ASC'],['queryPriceFen','DESC'],['publishedAt','DESC'],['id','ASC']]],
  ['FoodCard','public_score',[['visibility','ASC'],['status','ASC'],['tasteScore','DESC'],['publishedAt','DESC'],['id','ASC']]],
  ['FoodCard','merchant_public_time',[['merchantId','ASC'],['visibility','ASC'],['status','ASC'],['publishedAt','DESC'],['id','ASC']]],
  ['FoodCard','merchant_score_time_id',[['merchantId','ASC'],['status','ASC'],['tasteScore','DESC'],['publishedAt','DESC'],['id','ASC']]],
  ['Merchant','coordinate_latitude_id',[['coordinateSystem','ASC'],['latitudeE6','ASC'],['merchantId','ASC']]],
  ['PersonalFoodState','index_1',[['ownerUid','ASC'],['state','ASC'],['updatedAt','DESC'],['cardId','ASC']]]
]){
  const object=schema.objectTypes.find(object=>object.objectTypeName===name);
  const index=object?.indexes?.find(index=>index.indexName===indexName);
  check('required schema index '+name+'.'+indexName,JSON.stringify(index?.indexList?.map(field=>[field.fieldName,field.sortType]))===JSON.stringify(expected));
}
const cardMedia=schema.objectTypes.find(object=>object.objectTypeName==='CardMedia');
for(const name of ['objectKey','sha256'])check('preserve sensitivity CardMedia.'+name,cardMedia?.fields?.find(field=>field.fieldName===name)?.isSensitive===true);
// 删除好友权限功能时不能删除或重新定义 Cloud DB 中已有的列；它们只为存储兼容而保留，不是访问控制。
const foodCard=schema.objectTypes.find(object=>object.objectTypeName==='FoodCard');
for(const [fieldName,fieldType] of [['friendVisibilitySince','Date'],['friendVisibilitySequence','Long']]){
  const field=foodCard?.fields?.find(field=>field.fieldName===fieldName);
  const expected={fieldName,fieldType,belongPrimaryKey:false,notNull:false,isNeedEncrypt:false,isSensitive:false};
  check('preserve deployed field FoodCard.'+fieldName,!!field&&JSON.stringify(fieldShape([field]))===JSON.stringify(fieldShape([expected])));
}
const service='CloudProgram/cloudfunctions/shike-service/';
const modules=['runtime.js','stage1-services.js','stage2-services.js','stage3-services.js','stages47-common.js','stage6-services.js','random-food-services.js','stage7-services.js','food-ranking-services.js','personal-collections.js','card-report-services.js','lifecycle-services.js','authentication-cleanup.js'];
for(const module of modules){
  const file=join(root,service,module);check('module '+module,existsSync(file));if(!existsSync(file))continue;
  const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8',shell:false});
  check('syntax '+module,!result.error&&result.status===0,(result.stderr||'').trim());
}
// 需要在四处方法表中同时存在的操作（方法名 → 操作名）。
const methods={listDeletedCards:'list-deleted-cards',restoreDeletedCard:'restore-deleted-card',getReviewMedia:'get-review-media'};
Object.assign(methods,{getCardReportAccess:'get-card-report-access',getCardReportContext:'get-card-report-context',submitCardReport:'submit-card-report',listMyCardReports:'list-my-card-reports',getMyCardReport:'get-my-card-report',listCardReviewReports:'list-card-review-reports',getCardReviewReport:'get-card-review-report',resolveCardReport:'resolve-card-report'});
Object.assign(methods,{getRandomFoodPool:'get-random-food-pool',getRandomFoodCards:'get-random-food-cards',saveFoodChoice:'save-food-choice',listFoodChoices:'list-food-choices',deleteFoodChoice:'delete-food-choice'});
Object.assign(methods,{getCardPreviews:'get-card-previews',listPersonalCollection:'list-personal-collection',getPersonalCollectionMigration:'get-personal-collection-migration',startPersonalCollectionMigration:'start-personal-collection-migration',resumePersonalCollectionMigration:'resume-personal-collection-migration',setCardFavorite:'set-card-favorite',getMealCandidates:'get-meal-candidates',createMealPoll:'create-meal-poll',getMealPoll:'get-meal-poll',addMealPollOption:'add-meal-poll-option',voteMealPoll:'vote-meal-poll',closeMealPoll:'close-meal-poll',cancelMealPoll:'cancel-meal-poll',stopMealPollOptions:'stop-meal-poll-options',getUserPage:'get-user-page',listFoodRankings:'list-food-rankings',setCardReactionV2:'set-card-reaction-v2'});
const entry=source(service+'shikeService.ts'),runtime=source(service+'runtime.js'),gateway=source('Application/entry/src/main/ets/service/CloudGateway.ets'),routes=source('Application/entry/src/main/ets/service/CloudRoutes.ets');
// 已退役的操作：不能再出现在 runtime 操作表、shikeService.ts、CloudGateway 或 CloudRoutes 中。
const retiredOperations=['get-stage89-capabilities','list-moderation-queue','get-moderation-detail','decide-moderation','list-lifecycle-jobs','get-lifecycle-job','retry-lifecycle-job','confirm-auth-cleanup','run-lifecycle-job','list-moderation-merchants','moderate-merchant','reconcile-merchant-counters','list-moderation-revisions','moderate-card-revision','start-migration-job','process-migration-job','get-migration-status','list-maintenance-jobs','get-maintenance-job','retry-maintenance-job','validate-lifecycle-job','process-friend-cleanup-job','list-moderation-cards','moderate-card','list-notifications','mark-notification-read','mark-all-notifications-read','open-notification','get-taste-preference','update-taste-preference','clear-taste-preference','list-personalized-recommendations',
  'list-food-lists','create-food-list','update-food-list','delete-food-list','list-food-list-items','add-food-list-item','remove-food-list-item',
  'reorder-food-list-items','get-personal-food-state','update-personal-food-state','list-friend-rankings','list-merchant-rankings','list-received-comments',
  'create-card-comment','delete-card-comment','toggle-comment-reaction',
  // 2026-10-16：客户端已无调用者。
  'report-card','report-user','report-merchant','set-card-reaction','get-card-revision','get-stage47-capabilities','toggle-card-action',
  'list-my-favorite-cards','list-my-reports','list-own-review-requests','check-location',
];
for(const operation of retiredOperations)check('retired contract '+operation,
  !runtime.includes("'"+operation+"':")&&!entry.includes("executeCloudOperation('"+operation+"'")&&!gateway.includes("case '"+operation+"':")&&!routes.includes("['"+operation+"',"));
  // 2026-10-17：图片准备 / 上传只由 shike-media 提供（CloudGateway 仍直接分派给 media），所以单独检查：不能出现在 runtime 操作表、shikeService.ts 与 CloudRoutes 中，但 CloudGateway 必须仍能分派。
for(const operation of ['prepare-card-photo','upload-card-photo'])check('media-only contract '+operation,
  !runtime.includes("'"+operation+"':")&&!entry.includes("executeCloudOperation('"+operation+"'")&&!routes.includes("['"+operation+"',")&&
  gateway.includes("case '"+operation+"':"));
for(const module of ['stage4-services.js','stage5-services.js','content-status-services.js'])check('retired module '+module,!existsSync(join(root,service,module)));
for(const [method,operation]of Object.entries(methods))check('contract '+operation,entry.includes(method+'(input: CloudEnvelope)')&&entry.includes("executeCloudOperation('"+operation+"'")&&runtime.includes("'"+operation+"':")&&routes.includes("['"+operation+"', '"+method+"',"));
for(const name of ['content-policy.js','media-descriptor.js','read-errors.js','release-info.js','image-models.js','image-reader.js','card-review-access.js']) {
  const path='CloudProgram/cloudfunctions/shared/'+name;
  check('shared source '+name,existsSync(join(root,path)));
}
check('retired function shike-location',!existsSync(join(cloud,'cloudfunctions','shike-location')));
for(const folder of ['shike-media','shike-service']) for(const name of ['content-policy.js','media-descriptor.js','read-errors.js'])
  check('no duplicate '+folder+'/'+name,!existsSync(join(cloud,'cloudfunctions',folder,name)));
for(const path of ['package-cloud-object.mjs','package-maintenance.mjs'])
  check('shared packager '+path,source('CloudProgram/scripts/'+path).includes('packageFunction'));
check('image SDK endpoint',gateway.includes("name: 'shike-image'")&&gateway.includes('cloudFunction.call(parameters)'));
check('no binary HTTP client',!existsSync(join(root,'Application/entry/src/main/ets/service/BinaryMediaTransport.ets')));
check('no obsolete preload',!existsSync(join(root,'Application/entry/src/main/ets/service/NearbyPreloadService.ets')));
const worker='CloudProgram/cloudfunctions/shike-maintenance/';
const config=JSON.parse(source(worker+'function-config.json')),contract=JSON.parse(source(worker+'timer-contract.json'));
check('worker handler',config.handler==='shikeMaintenance.handler'&&config.functionType===0);
check('timer contract',contract.httpTrigger===false&&contract.maximumJobsPerInvocation===3&&contract.rowsPerCleanupStep===10);
check('card history maintenance contract',contract.cardHistoryBackfill?.defaultMode==='status'&&
  contract.cardHistoryBackfill?.rowsPerInvocation===20&&contract.cardHistoryBackfill?.lifecycleDeletionRequired===false&&
  contract.cardHistoryBackfill?.writeRequiredFlag==='SHIKE_MAINTENANCE_ENABLED'&&
  JSON.stringify(contract.cardHistoryBackfill?.modes)===JSON.stringify(['status','initialize','run','retry']));
check('worker-only card history entry',source(worker+'shikeMaintenance.js').includes("input.action==='card-history'")&&
  runtime.includes('stage1.cardHistoryMaintenance(payload, source)')&&
  !entry.includes('maintainCardHistory(')&&!gateway.includes("case 'card-history-maintenance':"));
check('no shipped triggers',(config.triggers||[]).length===0,'AGC timer must be configured and verified separately; this file intentionally contains no provider-specific trigger definition.');
for(const path of [worker+'shikeMaintenance.js','CloudProgram/cloudfunctions/shared/image-reader.js','CloudProgram/cloudfunctions/shared/content-policy.js','CloudProgram/cloudfunctions/shike-image/shikeImage.js','CloudProgram/cloudfunctions/shike-media/runtime.js','CloudProgram/cloudfunctions/shike-media/cover-converter.js','CloudProgram/cloudfunctions/shike-media/cover-worker.js','CloudProgram/scripts/package-functions.mjs','CloudProgram/scripts/check-artifact.mjs']){
  const result=spawnSync(process.execPath,['--check',join(root,path)],{encoding:'utf8',shell:false});check('syntax '+path,!result.error&&result.status===0,(result.stderr||'').trim());
}
const lifecycle=source(service+'lifecycle-services.js');
check('worker gates',lifecycle.includes("'SHIKE_LIFECYCLE_VERIFIED'")&&lifecycle.includes("'SHIKE_MAINTENANCE_ENABLED'"));
check('production recovery',runtime.includes('SHIKE_ENVIRONMENT')&&runtime.includes('SHIKE_TEST_RECOVERY_SECONDS'),'A source check cannot verify deployed environment values.');
const trace=source('Application/entry/src/main/ets/service/FeaturePerformanceTrace.ets');
for(const name of ['map_first_render','map_marker_query','search_first_result','random_food_pool','random_food_cards','food_choice_history','meal_poll_candidates','food_list_first_page','draft_restore','poll_refresh'])check('trace '+name,trace.includes("'"+name+"'"));
const failed=results.filter(result=>!result.ok);
const report={checkedAt:new Date().toISOString(),sourceVersion:'image-read-v1',metricsVersion:'o0-20261008-v1',schemaVersion:schema.schemaVersion,nodeVersion:process.version,checks:results,failedCount:failed.length,scope:'Source/schema/contracts/syntax only. ArkTS build, actual cloud configuration, timer delivery, Auth REST execution, runtime regression and performance are user validation tasks.'};
mkdirSync(dirname(reportPath),{recursive:true});writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
console.log('Source checks: '+results.length+'; failed: '+failed.length+'; report: '+reportPath);
for(const result of failed)console.error(result.name+': '+result.detail);
process.exitCode=failed.length?1:0;
