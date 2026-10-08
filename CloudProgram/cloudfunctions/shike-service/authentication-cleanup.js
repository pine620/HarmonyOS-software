'use strict';
const {fail}=require('./stages47-common');
// Auth 1.0.5 has no arbitrary-UID delete API. This adapter uses the documented
// client-authorized REST deregistration endpoint, never a guessed admin URL.
function createAuthenticationCleanup(ctx){
  async function jsonRequest(path,headers,body){const abort=new AbortController(),timer=setTimeout(()=>abort.abort(),15000);
    try{const response=await fetch('https://connect-drcn.dbankcloud.cn'+path,{method:'POST',headers,body:body===undefined?undefined:JSON.stringify(body),signal:abort.signal});
      if(!response.ok)throw fail('认证清理上游暂不可用。','AUTH_UPSTREAM_FAILED');const result=await response.json();if(!result||typeof result!=='object')throw fail('认证清理响应无效。','AUTH_UPSTREAM_FAILED');return result;
    }catch(error){if(error&&error.code)throw error;throw fail('认证清理连接失败，请稍后重试。','AUTH_UPSTREAM_FAILED');}finally{clearTimeout(timer);}}
  function setting(env,name){const value=String(env[name]||process.env[name]||'');if(!value)throw fail('认证清理服务配置尚未就绪。','AUTH_ACTION_REQUIRED');return value;}
  async function remove(job,binding,env){const accessToken=ctx.decryptPrivateText(job.authCredentialCiphertext,'delete-account:'+job.entityId,env);
    try{if(await ctx.verifiedAgcUid(accessToken)!==binding.providerUid)throw fail('认证身份不匹配。','AUTH_ACTION_REQUIRED');}catch(_){throw fail('注销授权已失效，需要核实认证身份清理。','AUTH_ACTION_REQUIRED');}
    const clientId=setting(env,'SHIKE_AGC_CLIENT_ID'),projectId=setting(env,'SHIKE_AGC_PROJECT_ID');
    const token=await jsonRequest('/agc/apigw/oauth2/v1/token',{'Content-Type':'application/json'},{grant_type:'client_credentials',client_id:clientId,client_secret:setting(env,'SHIKE_AGC_CLIENT_SECRET'),useJwt:1});
    if(typeof token.access_token!=='string')throw fail('认证清理鉴权失败。','AUTH_UPSTREAM_FAILED');
    const result=await jsonRequest('/agc/apigw/oauth2/third/v1/user-delete?productId='+encodeURIComponent(projectId),{'Accept':'application/json','Content-Type':'application/json;charset=utf-8',client_id:clientId,Authorization:'Bearer '+token.access_token,access_token:accessToken});
    let ret=result.ret;if(typeof ret==='string'){try{ret=JSON.parse(ret);}catch(_){ret=null;}}
    if(!ret||Number(ret.code)!==0)throw fail('认证注销需要核实或重新授权。','AUTH_ACTION_REQUIRED');
  }
  return {remove};
}
module.exports={createAuthenticationCleanup};
