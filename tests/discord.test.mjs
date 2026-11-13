import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHandler,webhookURL,messagePayload,syncRole,botConfig} from '../supabase/functions/discord-bridge/handler.js';
import {discordLink} from '../discord.js';
const uid='10000000-0000-4000-8000-000000000001',id='20000000-0000-4000-8000-000000000001';
const vars={SUPABASE_URL:'https://project.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'server-key',MUN_SITE_URL:'https://cspatz1014.github.io/Mun-or-Bust/',DISCORD_DISPATCH_SECRET:'a'.repeat(64),DISCORD_GUILD_ID:'100000000000000001',DISCORD_ROLE_CREW:'100000000000000002',DISCORD_ROLE_MENTOR:'100000000000000003',DISCORD_ROLE_LEAD:'100000000000000004',DISCORD_BOT_TOKEN:'bot-secret',DISCORD_CLIENT_ID:'100000000000000005',DISCORD_CLIENT_SECRET:'oauth-secret',DISCORD_WEBHOOK_URL:'https://discord.com/api/webhooks/123456789012345678/token'};
const env={get:k=>vars[k]},reply=x=>Response.json(x),body={type:'INSERT',schema:'public',table:'discord_outbox',record:{id}};
const request=(payload,headers={})=>new Request(vars.SUPABASE_URL+'/functions/v1/discord-bridge',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(payload)});
test('public links reject credentials and webhook URLs',()=>{assert.ok(discordLink('https://discord.com/channels/123/456'));for(const u of ['javascript:alert(1)','https://discord.com/api/webhooks/123/token','https://evil.example/channels/123','https://discord.com@evil.example/channels/123'])assert.equal(discordLink(u),null);assert.ok(webhookURL(vars.DISCORD_WEBHOOK_URL).endsWith('?wait=true'));assert.throws(()=>webhookURL('https://discord.com.evil.example/api/webhooks/123/token'))});
test('announcement contains no pings/private content and uses Discord local timestamps',()=>{const p=messagePayload({category:'meetings',payload:{title:'@everyone **hello**',label:'Meeting',due_at:'2027-01-01T00:00:00Z',route:'project/meetings',secret:'private'}},vars.MUN_SITE_URL);assert.deepEqual(p.allowed_mentions,{parse:[]});assert.match(p.embeds[0].fields[0].value,/^<t:\d+:F>$/);assert.ok(!JSON.stringify(p).includes('private'));assert.ok(p.embeds[0].url.endsWith('#project/meetings'))});
test('unauthorized dispatch does not contact either service',async()=>{let count=0;const h=createHandler({env,fetch:async()=>{count++;throw Error()}});assert.equal((await h(request(body))).status,401);assert.equal(count,0)});
test('duplicate delivery does not post again',async()=>{let calls=0;const h=createHandler({env,fetch:async url=>{calls++;assert.match(url,/claim_discord_delivery$/);return reply([])}});const r=await h(request(body,{'x-mun-dispatch-secret':vars.DISCORD_DISPATCH_SECRET}));assert.equal((await r.json()).status,'already_handled');assert.equal(calls,1)});
test('rate limits record delay; webhook credentials never appear in errors',async()=>{let saved;const h=createHandler({env,fetch:async(url,o)=>{if(url.includes('claim_discord'))return reply([{id,category:'test',payload:{label:'Test',title:'Hello',route:'dashboard'}}]);if(url.includes('discord_settings'))return reply([{enabled:true,events:[]}]);if(url.startsWith('https://discord.com/api/webhooks/'))return new Response('{"retry_after":5}',{status:429});saved=JSON.parse(o.body);return new Response(null,{status:204})}});assert.equal((await h(request(body,{'x-mun-dispatch-secret':vars.DISCORD_DISPATCH_SECRET}))).status,200);assert.equal(saved.error_code,'discord_http_429');assert.ok(Date.parse(saved.retry_after)>Date.now());assert.ok(!JSON.stringify(saved).includes('token'))});
test('OAuth callback only forwards code to app fragment; it never joins unauthenticated',async()=>{let n=0;const h=createHandler({env,fetch:async()=>{n++;throw Error()}}),r=await h(new Request(vars.SUPABASE_URL+'/functions/v1/discord-bridge?code=abc&state=xyz'));assert.equal(r.status,303);const u=new URL(r.headers.get('Location'));assert.equal(u.origin,new URL(vars.MUN_SITE_URL).origin);assert.equal(u.search,'');assert.match(u.hash,/discord\/callback/);assert.equal(n,0)});
test('OAuth finish binds state to verified app user before exchanging tokens',async()=>{let consumed;const h=createHandler({env,fetch:async(url,o)=>{if(url.endsWith('/auth/v1/user'))return reply({id:uid});if(url.includes('profiles?'))return reply([{active:true}]);if(url.includes('consume_discord_state')){consumed=JSON.parse(o.body);return reply([])}throw Error('Must not exchange tokens')}});const r=await h(request({action:'finish',code:'code',state:'state'},{origin:new URL(vars.MUN_SITE_URL).origin,authorization:'Bearer user-session'}));assert.equal(r.status,400);assert.equal(consumed.target,uid)});
test('inactive users cannot start OAuth',async()=>{const h=createHandler({env,fetch:async url=>url.endsWith('/auth/v1/user')?reply({id:uid}):reply([{active:false}])});assert.equal((await h(request({action:'start'},{origin:new URL(vars.MUN_SITE_URL).origin,authorization:'Bearer user-session'}))).status,403)});
for(const role of ['member','mentor','admin','inactive'])test('role synchronization: '+role,async()=>{const cfg=botConfig(env),mutations=[],updates=[];const api=async(path,method,value)=>{if(path.includes('lock_discord'))return true;if(path.startsWith('profiles'))return [{active:role!=='inactive',role:role==='inactive'?'member':role}];if(method==='PATCH'){updates.push(value);return null}return [{discord_id:'200000000000000001'}]};const http=async(url,o)=>{if(url.endsWith('/roles')&&o.method==='GET')return reply(Object.values(cfg.roles).map(id=>({id,permissions:'0',managed:false})));if(o.method==='GET')return reply({});mutations.push({url,method:o.method});return new Response(null,{status:204})};await syncRole({userId:uid,api,env,request:http});assert.equal(mutations.filter(x=>x.method==='PUT').length,role==='inactive'?0:1);if(role!=='inactive')assert.ok(mutations.find(x=>x.method==='PUT').url.endsWith('/'+cfg.roles[role]));assert.equal(updates.at(-1).synced_role,role)});
test('unsafe Administrator role is rejected before any member mutation',async()=>{const cfg=botConfig(env);let mutations=0;await assert.rejects(()=>syncRole({userId:uid,env,api:async(path,method)=>path.includes('lock_discord')?true:method==='PATCH'?null:[{discord_id:'200000000000000001'}],request:async(url,o)=>{if(o.method!=='GET')mutations++;return reply(Object.values(cfg.roles).map(id=>({id,permissions:'8'})))}}),/unsafe_role/);assert.equal(mutations,0)});
test('dashboard-deploy file matches the tested handler',()=>{assert.equal(readFileSync(new URL('../supabase/functions/discord-bridge/index.ts',import.meta.url),'utf8'),readFileSync(new URL('../supabase/functions/discord-bridge/handler.js',import.meta.url),'utf8')+'\nDeno.serve(createHandler({env:Deno.env}));\n')});
test('successful join queues authoritative role sync and revokes the temporary grant',async()=>{
 const writes=[],discordId='200000000000000001';let revoked=false;
 const h=createHandler({env,fetch:async(url,o={})=>{
  if(url.endsWith('/auth/v1/user'))return reply({id:uid});
  if(url.includes('/profiles?'))return reply([{active:true}]);
  if(url.includes('consume_discord_state'))return reply([{user_id:uid}]);
  if(url.endsWith('/oauth2/token'))return reply({access_token:'temporary-token'});
  if(url.endsWith('/users/@me'))return reply({id:discordId});
  if(url.includes('/discord_links?'))return reply([]);
  if(url.endsWith('/discord_links')||url.endsWith('/discord_outbox')){writes.push({url,value:JSON.parse(o.body)});return new Response(null,{status:201})}
  if(url.includes('/guilds/')){assert.equal(o.method,'PUT');assert.deepEqual(JSON.parse(o.body),{access_token:'temporary-token'});return reply({})}
  if(url.endsWith('/token/revoke')){revoked=true;return new Response(null,{status:200})}
  throw Error('Unexpected request '+url);
 }});
 const r=await h(request({action:'finish',code:'code',state:'state',role:'admin',user_id:id},{origin:new URL(vars.MUN_SITE_URL).origin,authorization:'Bearer user-session'}));
 assert.equal(r.status,200);assert.deepEqual(await r.json(),{connected:true});assert.equal(revoked,true);
 assert.deepEqual(writes[0].value,{user_id:uid,discord_id:discordId});assert.equal(writes[1].value.payload.user_id,uid);assert.equal(writes[1].value.category,'access');assert.equal(writes[1].value.payload.role,undefined);
});

for (const insertStatus of [201,204]) test('OAuth start accepts empty successful writes: '+insertStatus,async()=>{
 let saved,deleted=false;
 const h=createHandler({env,fetch:async(url,o={})=>{
  if(url.endsWith('/auth/v1/user'))return reply({id:uid});
  if(url.includes('/profiles?'))return reply([{active:true}]);
  if(url.includes('/discord_oauth_states?')){assert.equal(o.method,'DELETE');deleted=true;return new Response(null,{status:204})}
  if(url.endsWith('/discord_oauth_states')){assert.equal(o.method,'POST');saved=JSON.parse(o.body);return new Response(null,{status:insertStatus})}
  throw Error('Unexpected request');
 }});
 const r=await h(request({action:'start'},{origin:new URL(vars.MUN_SITE_URL).origin,authorization:'Bearer user-session'}));
 assert.equal(r.status,200);const u=new URL((await r.json()).url);assert.equal(u.origin,'https://discord.com');assert.equal(u.searchParams.get('scope'),'identify guilds.join');assert.ok(deleted);assert.equal(saved.user_id,uid);
 const state=u.searchParams.get('state'),hash=Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(state))).toString('hex');assert.equal(saved.state_hash,hash);assert.notEqual(saved.state_hash,state);
});
