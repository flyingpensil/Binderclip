import test from 'node:test';
import assert from 'node:assert/strict';
import {createDocumentHandler,sha256,validateFile} from '../../supabase/functions/binderclip-documents/index.js';

const tenant='11111111-1111-4111-8111-111111111111',doc='22222222-2222-4222-8222-222222222222';
const base='https://project.supabase.co/functions/v1/binderclip-documents';
const origin='https://example.test';
const bytes=new TextEncoder().encode('Shipment evidence\n');
const context={id:doc,tenant_id:tenant,job_id:tenant,job_number:'JOB-1',created_by:tenant,filename:'evidence.txt',mime:'text/plain',bytes:String(bytes.length),object_path:tenant+'/'+doc,status:'Pending'};
function fixture(options={}){
 const calls=[],envs={SUPABASE_URL:'https://project.supabase.co',SUPABASE_ANON_KEY:'public-key',SUPABASE_SERVICE_ROLE_KEY:'PRIVATE-SERVER-KEY',BINDERCLIP_APP_URL:origin+'/Binderclip/',GOOGLE_DRIVE_OWNER_EMAIL:'owner@example.test',GOOGLE_DRIVE_CLIENT_ID:'client',GOOGLE_DRIVE_CLIENT_SECRET:'PRIVATE-CLIENT-SECRET'};
 let manifest={provider:options.drive?'google_drive':'supabase'},remote=null,checks=0,sequence=0;
 const objects=new Map([['root-private-123',{id:'root-private-123',mimeType:'application/vnd.google-apps.folder',ownedByMe:true,shared:false,appProperties:{binderclipStorage:'v1'}}]]);
 const fetcher=async(url,init={})=>{
  calls.push({url,init});const respond=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
  if(url.includes('/rest/v1/rpc/')){
   const name=url.split('/').at(-1),args=JSON.parse(init.body);
   if(name==='bc_session')return options.sessionDenied?respond({message:'Sign in first'},401):respond({});
   if(name==='bc_document_context'){checks++;return options.roleDenied||options.revokeAfterRead&&checks>1?respond({message:'Permission denied'},403):respond(context);}
   if(name==='bc_document_finish')return respond({id:doc});
   assert.equal(name,'bc_document_service');assert.equal(init.headers.Authorization,'Bearer PRIVATE-SERVER-KEY');
   if(args.p_action==='document.get')return respond(options.manifest||manifest);
   if(args.p_action==='document.claim'){manifest={...manifest,sha256:args.p_data.sha256,...(options.drive?{external_id:manifest.external_id||args.p_data.external_id,parent_id:'job-folder-123'}:{})};return respond(manifest);}
   if(args.p_action==='document.verified')return respond({});
   if(args.p_action==='connection.get')return respond(options.drive?{status:'Ready',root_id:'root-private-123',credentials:{refresh_token:'PRIVATE-REFRESH',access_token:'PRIVATE-ACCESS',expires_at:'2099-01-01T00:00:00Z'}}:{status:'Unconfigured'});
   if(args.p_action==='folder.claim')return respond({external_id:'job-folder-123',parent_id:'root-private-123'});
   if(args.p_action==='state.create')return respond({});
   throw Error('Unexpected broker '+args.p_action);
  }
  if(url.startsWith('https://www.googleapis.com/')){
   assert.equal(init.headers.Authorization,'Bearer PRIVATE-ACCESS');
   if(url.includes('generateIds'))return respond({ids:['generated-file-'+(++sequence)]});
   if(url.includes('/upload/drive/')){
    const text=await init.body.text(),meta=JSON.parse(text.split('\r\n\r\n')[1].split('\r\n--')[0]);
    objects.set(meta.id,{...meta,size:bytes.length,ownedByMe:true,shared:false,sha256Checksum:await sha256(bytes)});
    // First attempt can finish remotely yet lose its response. Retrying must reuse the same file ID.
    if(options.interrupt&&!options.interrupted){options.interrupted=true;throw Error('Connection dropped');}
    return respond({id:meta.id});
   }
   const parsed=new URL(url),key=parsed.pathname.split('/').at(-1);
   if(key==='files'&&init.method==='POST'){const meta=JSON.parse(init.body);objects.set(meta.id,{...meta,ownedByMe:true,shared:false});return respond(objects.get(meta.id));}
   if(parsed.searchParams.get('alt')==='media')return new Response(bytes);
   return objects.has(key)?respond(objects.get(key)):respond({},404);
  }
  if(url.includes('/storage/v1/object/')){if(init.method==='POST'){remote=init.body;return respond({});}return new Response(options.corrupt?new TextEncoder().encode('tampered'):remote||bytes);}
  throw Error('Unexpected external request');
 };
 const handler=createDocumentHandler({env:key=>envs[key],fetcher});
 const download=()=>handler(new Request(base,{method:'POST',headers:{Origin:origin,Authorization:'Bearer user-jwt','Content-Type':'application/json'},body:JSON.stringify({action:'download',tenant_id:tenant,document_id:doc})}));
 const upload=(content=bytes)=>{const form=new FormData();form.set('action','upload');form.set('tenant_id',tenant);form.set('document_id',doc);form.set('file',new File([content],'evidence.txt',{type:'text/plain'}));return handler(new Request(base,{method:'POST',headers:{Origin:origin,Authorization:'Bearer user-jwt'},body:form}));};
 return {handler,calls,upload,download};
}
test('document file validation rejects disguised, empty and oversized files',()=>{
 validateFile(bytes,'text/plain','evidence.txt');
 assert.throws(()=>validateFile(new TextEncoder().encode('<script>steal()</script>'),'application/pdf','bill.pdf'));
 assert.throws(()=>validateFile(new Uint8Array(),'text/plain','empty.txt'));
 assert.throws(()=>validateFile(new Uint8Array(10485761),'text/plain','large.txt'));
 assert.throws(()=>validateFile(new Uint8Array([0,1,2]),'text/plain','binary.txt'));
});
test('document service denies missing sessions and unrelated origins before file access',async()=>{
 const {handler,calls}=fixture();assert.equal((await handler(new Request(base,{method:'POST'}))).status,401);assert.equal(calls.length,0);
 assert.equal((await handler(new Request(base,{method:'POST',headers:{Origin:'https://evil.test',Authorization:'Bearer x'}}))).status,403);assert.equal(calls.length,0);
 const denied=fixture({sessionDenied:true});assert.equal((await denied.download()).status,401);assert.equal(denied.calls.length,1);
});
test('upload verifies stored bytes before completion and returns no provider identifiers',async()=>{
 const f=fixture(),response=await f.upload();assert.equal(response.status,200);assert.deepEqual(await response.json(),{id:doc,status:'Ready'});
 const actions=f.calls.filter(c=>c.url.endsWith('bc_document_service')).map(c=>JSON.parse(c.init.body).p_action);
 assert.deepEqual(actions,['document.get','document.claim','document.verified']);assert.ok(f.calls.at(-1).url.endsWith('bc_document_finish'));
 const corrupt=fixture({corrupt:true});assert.equal((await corrupt.upload()).status,409);assert.ok(!corrupt.calls.some(c=>c.url.endsWith('bc_document_finish')));
});
test('document permission denial never contacts storage or privileged broker',async()=>{
 const f=fixture({roleDenied:true});assert.equal((await f.download()).status,403);assert.ok(!f.calls.some(c=>/storage|bc_document_service/.test(c.url)));
});
test('downloads check checksum and recheck roles after retrieval',async()=>{
 const digest=await sha256(bytes),f=fixture({manifest:{provider:'supabase',sha256:digest}});
 const response=await f.download();assert.equal(response.status,200);assert.equal(response.headers.get('Content-Type'),'application/octet-stream');assert.match(response.headers.get('Content-Disposition'),/evidence.txt/);assert.equal(response.headers.get('X-Content-Type-Options'),'nosniff');
 assert.deepEqual(new Uint8Array(await response.arrayBuffer()),bytes);
 assert.equal((await fixture({manifest:{provider:'supabase',sha256:digest},corrupt:true}).download()).status,409);
 assert.equal((await fixture({revokeAfterRead:true}).download()).status,403);
});
test('owner setup uses offline app-file scope, PKCE and secure CSRF cookie',async()=>{
 const f=fixture(),r=await f.handler(new Request(base+'/owner/connect'));assert.equal(r.status,303);
 const target=new URL(r.headers.get('Location'));assert.equal(target.origin,'https://accounts.google.com');assert.equal(target.searchParams.get('code_challenge_method'),'S256');assert.equal(target.searchParams.get('access_type'),'offline');assert.equal(target.searchParams.get('scope'),'openid email https://www.googleapis.com/auth/drive.file');
 assert.match(r.headers.get('Set-Cookie'),/Secure; HttpOnly; SameSite=Lax/);assert.ok(!target.href.includes('PRIVATE'));
 const before=f.calls.length;assert.equal((await f.handler(new Request(base+'/owner/callback?code=x&state=wrong'))).status,403);assert.equal(f.calls.length,before);
});
test('Drive retry after a lost upload response reuses the claimed remote file',async()=>{
 const f=fixture({drive:true,interrupt:true});assert.equal((await f.upload()).status,503);
 const retry=await f.upload();assert.equal(retry.status,200);assert.ok(!JSON.stringify(await retry.json()).includes('generated-file'));
 assert.equal(f.calls.filter(c=>c.url.includes('/upload/drive/')).length,1);
 assert.equal(f.calls.filter(c=>c.url.endsWith('bc_document_finish')).length,1);
});
