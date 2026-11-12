// Server-only integration. Tokens never enter the public site or delivery log.
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const snowflake=s=>/^\d{15,22}$/.test(s||'');
const digest=async s=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s))),v=>v.toString(16).padStart(2,'0')).join('');
const plain=s=>String(s??'').replace(/[\\`*_~|<>\[\]]/g,'\\$&').slice(0,240);
export function webhookURL(value){const u=new URL(value);if(u.protocol!=='https:'||u.hostname!=='discord.com'||u.port||u.username||u.password||!/^\/api(?:\/v10)?\/webhooks\/\d+\/[A-Za-z0-9_-]+$/.test(u.pathname))throw Error('webhook_configuration');u.search='?wait=true';u.hash='';return u.href}
export function botConfig(env){const keys=['DISCORD_GUILD_ID','DISCORD_ROLE_CREW','DISCORD_ROLE_MENTOR','DISCORD_ROLE_LEAD'],ids=keys.map(k=>env.get(k));if(ids.some(x=>!snowflake(x))||new Set(ids).size!==4||!env.get('DISCORD_BOT_TOKEN'))throw Error('bot_configuration');return {guild:ids[0],roles:{member:ids[1],mentor:ids[2],admin:ids[3]},token:env.get('DISCORD_BOT_TOKEN')}}
export function messagePayload(row,site){const p=row.payload,url=new URL(site);url.hash=/^(tasks|dashboard|project\/[a-z]+)$/.test(p.route)?p.route:'dashboard';url.search='';const fields=[];if(p.status)fields.push({name:'Status',value:plain(p.status),inline:true});if(p.due_date)fields.push({name:'Date',value:plain(p.due_date)+' · all day; cutoff time not specified'});else if(p.due_at&&Number.isFinite(Date.parse(p.due_at)))fields.push({name:row.category==='meetings'?'Meeting time':'Due',value:`<t:${Math.floor(Date.parse(p.due_at)/1000)}:F>`});if(p.revision)fields.push({name:'Revision',value:String(p.revision),inline:true});return {username:'Mun or Bust · Mission Control',allowed_mentions:{parse:[]},embeds:[{title:plain(p.label),description:plain(p.title),url:url.href,color:12572992,fields,footer:{text:'Open the team app for details'}}]}}
export function discordAPI(config,request){return async(path,method='GET',body)=>{const r=await request('https://discord.com/api/v10/'+path,{method,headers:{Authorization:'Bot '+config.token,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('discord_http_'+r.status);return r.status===204?null:r.json()}}
export async function syncRole({userId,api,env,request}){
 if(!UUID.test(userId||''))throw Error('invalid_user');
 if(!await api('rpc/lock_discord_sync','POST',{target:userId}))throw Error('role_sync_busy');
 const path='discord_links?user_id=eq.'+userId;
 try{
  const cfg=botConfig(env),discord=discordAPI(cfg,request),[link]=await api(path+'&select=discord_id');if(!link||!snowflake(link.discord_id))throw Error('link_missing');
  const roles=await discord('guilds/'+cfg.guild+'/roles');
  for(const id of Object.values(cfg.roles)){const r=roles.find(r=>r.id===id);if(!r||r.managed||(BigInt(r.permissions)&(8n|268435456n))!==0n)throw Error('unsafe_role_configuration')}
  for(let attempt=0;attempt<3;attempt++){
   const [p]=await api('profiles?id=eq.'+userId+'&select=role,active'),wanted=p?.active?cfg.roles[p.role]:null;if(p?.active&&!wanted)throw Error('unknown_team_role');
   const memberPath='guilds/'+cfg.guild+'/members/'+link.discord_id;
   let present=true;try{await discord(memberPath)}catch(e){if(e.message==='discord_http_404')present=false;else throw e}
   if(present){for(const role of Object.values(cfg.roles))if(role!==wanted)await discord(memberPath+'/roles/'+role,'DELETE');if(wanted)await discord(memberPath+'/roles/'+wanted,'PUT')}
   else if(wanted)throw Error('not_in_server');
   const [latest]=await api('profiles?id=eq.'+userId+'&select=role,active');
   if(latest?.active===p?.active&&latest?.role===p?.role){await api(path,'PATCH',{synced_role:p?.active?p.role:'inactive',synced_at:new Date().toISOString(),sync_error:null,locked_until:null});return}
  }
  throw Error('membership_changed_retry');
 }catch(e){const code=/^(discord_http_\d+|unsafe_role_configuration|bot_configuration|link_missing|unknown_team_role|not_in_server|membership_changed_retry)$/.test(e.message)?e.message:'role_sync_failed';await api(path,'PATCH',{sync_error:code,locked_until:null});throw Error(code)}
}
export function createHandler({env,fetch:request=fetch}){return async req=>{
 let site;try{site=new URL(env.get('MUN_SITE_URL')||'https://cspatz1014.github.io/Mun-or-Bust/');if(site.protocol!=='https:'||site.username||site.password)throw Error()}catch{return new Response('Invalid site configuration',{status:503})}
 const cors={'Access-Control-Allow-Origin':site.origin,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin'},respond=(status,obj)=>Response.json(obj,{status,headers:cors});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method==='GET'){
  const u=new URL(req.url),code=u.searchParams.get('code'),state=u.searchParams.get('state');site.search='';
  site.hash=u.searchParams.has('error')?'discord/cancelled':code&&code.length<=2000&&state&&state.length<=200?'discord/callback?'+new URLSearchParams({code,state}):'discord/failed';
  return Response.redirect(site.href,303);
 }
 if(req.method!=='POST')return respond(405,{error:'POST required'});
 const base=env.get('SUPABASE_URL'),key=env.get('SUPABASE_SERVICE_ROLE_KEY');if(!base||!key)return respond(503,{error:'Backend not configured'});
 const api=async(path,method='GET',body)=>{const r=await request(base+'/rest/v1/'+path,{method,headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('database_error');return r.status===204?null:r.json()};
 let body;try{const text=await req.text();if(text.length>16000)return respond(413,{error:'Payload too large'});body=JSON.parse(text)}catch{return respond(400,{error:'Invalid JSON'})}
 try{
  if(body.table==='discord_outbox'){
   const secret=env.get('DISCORD_DISPATCH_SECRET'),supplied=req.headers.get('x-mun-dispatch-secret')||'';
   if(!secret||secret.length<32)return respond(503,{error:'Dispatcher not configured'});
   const [a,b]=await Promise.all([digest(secret),digest(supplied)]);let mismatch=0;for(let i=0;i<a.length;i++)mismatch|=a.charCodeAt(i)^b.charCodeAt(i);if(mismatch)return respond(401,{error:'Unauthorized'});
   if(body.type!=='INSERT'||body.schema!=='public'||!UUID.test(body.record?.id||''))return respond(400,{error:'Invalid event'});
   const [row]=await api('rpc/claim_discord_delivery','POST',{delivery_id:body.record.id});if(!row)return respond(200,{status:'already_handled'});
   const finish=v=>api('discord_outbox?id=eq.'+row.id+'&status=eq.sending','PATCH',v);
   if(row.category==='access'){try{await syncRole({userId:row.payload.user_id,api,env,request});await finish({status:'sent',sent_at:new Date().toISOString()})}catch(e){await finish({status:'failed',error_code:e.message==='role_sync_busy'?'role_sync_busy':'role_sync_failed'})}return respond(200,{status:'role_sync_processed'})}
   const [settings]=await api('discord_settings?id=eq.true&select=enabled,events');
   if(!settings?.enabled||(row.category!=='test'&&!settings.events.includes(row.category))){await finish({status:'cancelled',error_code:'disabled'});return respond(200,{status:'cancelled'})}
   let url;try{url=webhookURL(env.get('DISCORD_WEBHOOK_URL'))}catch{await finish({status:'failed',error_code:'webhook_configuration'});return respond(200,{status:'failed'})}
   let r;try{r=await request(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(messagePayload(row,site.href)),redirect:'error',signal:AbortSignal.timeout(10000)})}catch{await finish({status:'failed',error_code:'delivery_unconfirmed'});return respond(200,{status:'unconfirmed'})}
   if(!r.ok){let retry=null;if(r.status===429){let d={};try{d=await r.json()}catch{}const seconds=Number(d.retry_after||r.headers.get('retry-after')||60);retry=new Date(Date.now()+Math.max(1,Math.min(Number.isFinite(seconds)?seconds:60,86400))*1000).toISOString()}await finish({status:'failed',error_code:'discord_http_'+r.status,retry_after:retry});return respond(200,{status:'failed'})}
   const message=await r.json();await finish({status:'sent',sent_at:new Date().toISOString(),discord_message_id:String(message.id),error_code:null});return respond(200,{status:'sent'});
  }
  // Every account-link operation requires a verified current Supabase user.
  if(req.headers.get('origin')!==site.origin)return respond(403,{error:'Open this from the team website.'});
  const authorization=req.headers.get('authorization')||'';if(!authorization.startsWith('Bearer '))return respond(401,{error:'Sign in first.'});
  const who=await request(base+'/auth/v1/user',{headers:{apikey:key,Authorization:authorization},signal:AbortSignal.timeout(8000)});if(!who.ok)return respond(401,{error:'Sign in again.'});const user=await who.json();if(!UUID.test(user.id))return respond(401,{error:'Invalid user'});
  const [profile]=await api('profiles?id=eq.'+user.id+'&select=active');if(!profile?.active)return respond(403,{error:'Active team membership required.'});
  const cfg=botConfig(env),client=env.get('DISCORD_CLIENT_ID'),secret=env.get('DISCORD_CLIENT_SECRET'),redirect=base+'/functions/v1/discord-bridge';if(!snowflake(client)||!secret)throw Error('configuration_error');
  if(body.action==='start'){
   await api('discord_oauth_states?or=(user_id.eq.'+user.id+',expires_at.lt.'+encodeURIComponent(new Date().toISOString())+')','DELETE');
   const state=crypto.randomUUID()+crypto.randomUUID();await api('discord_oauth_states','POST',{state_hash:await digest(state),user_id:user.id});
   const url=new URL('https://discord.com/oauth2/authorize');url.search=new URLSearchParams({client_id:client,response_type:'code',redirect_uri:redirect,scope:'identify guilds.join',state,prompt:'consent'}).toString();return respond(200,{url:url.href});
  }
  if(body.action!=='finish'||typeof body.state!=='string'||body.state.length>200||typeof body.code!=='string'||body.code.length>2000)return respond(400,{error:'Invalid connection request'});
  const [saved]=await api('rpc/consume_discord_state','POST',{hash:await digest(body.state),target:user.id});if(!saved)return respond(400,{error:'Connection expired or belongs to another team account. Start again.'});
  const tokens=await request('https://discord.com/api/v10/oauth2/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:client,client_secret:secret,grant_type:'authorization_code',code:body.code,redirect_uri:redirect}),signal:AbortSignal.timeout(10000)});
  if(!tokens.ok)return respond(400,{error:'Discord authorization expired. Start again.'});const token=await tokens.json();
  try{
   const identityResponse=await request('https://discord.com/api/v10/users/@me',{headers:{Authorization:'Bearer '+token.access_token},signal:AbortSignal.timeout(8000)});if(!identityResponse.ok)throw Error('identity_error');const identity=await identityResponse.json();if(!snowflake(identity.id))throw Error('identity_error');
   const [mine]=await api('discord_links?user_id=eq.'+user.id+'&select=discord_id');if(mine&&mine.discord_id!==identity.id)return respond(409,{error:'Use your previously linked Discord account. Ask the admin if the link needs repair.'});
   const [other]=await api('discord_links?discord_id=eq.'+identity.id+'&select=user_id');if(other&&other.user_id!==user.id)return respond(409,{error:'This Discord account belongs to another team account.'});
   const [current]=await api('profiles?id=eq.'+user.id+'&select=active');if(!current?.active)return respond(403,{error:'Membership inactive.'});
   if(!mine)await api('discord_links','POST',{user_id:user.id,discord_id:identity.id});
   await discordAPI(cfg,request)('guilds/'+cfg.guild+'/members/'+identity.id,'PUT',{access_token:token.access_token});
   await api('discord_outbox','POST',{category:'access',payload:{user_id:user.id,label:'Discord join role sync'}});
   return respond(200,{connected:true});
  }finally{await request('https://discord.com/api/v10/oauth2/token/revoke',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:client,client_secret:secret,token:token.access_token,token_type_hint:'access_token'}),signal:AbortSignal.timeout(5000)}).catch(()=>{})}
 }catch{
  // Never print raw network errors, which may contain a webhook credential.
  return respond(503,{error:'Integration could not finish. Ask an admin to check setup and delivery status, then retry.'});
 }
}}
