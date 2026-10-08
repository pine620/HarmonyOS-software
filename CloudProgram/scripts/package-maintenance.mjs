import {copyFileSync,mkdirSync,readFileSync,readdirSync,writeFileSync} from 'node:fs';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..'),service=join(root,'cloudfunctions/shike-service'),source=join(root,'cloudfunctions/shike-maintenance');
const target=join(root,'build','shike-maintenance-'+Date.now());mkdirSync(join(target,'service'),{recursive:true});
const modules=['runtime.js','content-policy.js','stage1-services.js','stage2-services.js','stage3-services.js','stages47-common.js','stage4-services.js','stage5-services.js','stage6-services.js','stage7-services.js','personal-collections.js','moderation-services.js','lifecycle-services.js','authentication-cleanup.js','read-errors.js'];
for(const name of modules)copyFileSync(join(service,name),join(target,'service',name));
writeFileSync(join(target,'shikeMaintenance.js'),readFileSync(join(source,'shikeMaintenance.js'),'utf8').replace("require('../shike-service/runtime')","require('./service/runtime')"));
for(const name of ['function-config.json','timer-contract.json'])copyFileSync(join(source,name),join(target,name));
for(const name of ['package.json','package-lock.json'])copyFileSync(join(service,name),join(target,name));
const env={...process.env,PATH:dirname(process.execPath)+':'+(process.env.PATH||'')};
function run(command,args){const result=spawnSync(command,args,{cwd:target,env,shell:false,stdio:'inherit'});if(result.error||result.status!==0)throw new Error('Maintenance package failed; do not use a partial artifact.');}
run('npm',['ci','--omit=dev']);
run('zip',['-q','-r',target+'.zip',...readdirSync(target).sort()]);
console.log('Maintenance artifact: '+target+'.zip');console.log('Configure the timer using timer-contract.json; no HTTP trigger. No deployment or handler execution performed.');
