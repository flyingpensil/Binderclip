// This module is shared by Deno Edge Functions and isolated Node regression tests.
// No provider tokens, folder IDs or owner settings are returned to app users.
const MAX_FILE=10485760,DRIVE='https://www.googleapis.com/drive/v3',UPLOAD='https://www.googleapis.com/upload/drive/v3';
const SCOPES='openid email https://www.googleapis.com/auth/drive.file';
class Fault extends Error{constructor(status,message){super(message);this.status=status;}}
const base64url=bytes=>btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
const json=(value,status=200,headers={})=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...headers}});
export async function sha256(bytes){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');}
export function validateFile(bytes,mime,name){
 if(bytes.length<1||bytes.length>MAX_FILE)throw new Fault(413,'Choose a non-empty file no larger than 10 MB.');
 const extension=String(name).split('.').at(-1).toLowerCase(),text=new TextDecoder().decode(bytes.slice(0,16));
 const ends=(...values)=>values.every((value,i)=>bytes[bytes.length-values.length+i]===value);
 if(mime==='application/pdf'&&extension==='pdf'&&text.startsWith('%PDF-')&&new TextDecoder().decode(bytes.slice(-2048)).includes('%%EOF'))return;
 if(mime==='image/png'&&extension==='png'&&bytes.length>=24&&[137,80,78,71,13,10,26,10].every((v,i)=>bytes[i]===v)&&ends(73,69,78,68,174,66,96,130))return;
 if(mime==='image/jpeg'&&['jpg','jpeg'].includes(extension)&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255&&ends(255,217))return;
 if((mime==='text/plain'&&extension==='txt')||(mime==='text/csv'&&extension==='csv')){
  try{const value=new TextDecoder('utf-8',{fatal:true}).decode(bytes);if(!/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value))return;}catch{}
 }
 throw new Fault(400,'The file content does not match its supported format. Use PDF, PNG, JPEG, UTF-8 TXT or CSV.');
}
async function boundedBody(request,limit){const reader=request.body?.getReader();if(!reader)return new Uint8Array();const chunks=[];let size=0;try{for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>limit){await reader.cancel();throw new Fault(413,'The request is too large. Maximum file size is 10 MB.');}chunks.push(value);}}finally{reader.releaseLock();}const result=new Uint8Array(size);let offset=0;for(const part of chunks){result.set(part,offset);offset+=part.length;}return result;}
function id(value){if(!/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(value||''))throw new Fault(400,'Choose a valid attachment.');return value;}
function fileId(value){if(!/^[A-Za-z0-9_-]{10,200}$/.test(value||''))throw new Fault(503,'The attachment service needs administrator attention.');return value;}

export function createDocumentHandler({env=name=>globalThis.Deno?.env.get(name),fetcher=fetch,now=()=>Date.now()}={}){
 const required=name=>{const value=env(name);if(!value)throw new Fault(503,'The attachment service is not configured. Contact the administrator.');return value;};
 const supabase=()=>new URL(required('SUPABASE_URL')).origin;
 const appURL=()=>{const url=new URL(required('BINDERCLIP_APP_URL'));if(url.protocol!=='https:'||url.username||url.password||url.search||url.hash)throw new Fault(503,'Invalid application configuration.');return url;};
 const callbackURL=()=>supabase()+'/functions/v1/binderclip-documents/owner/callback';
 async function request(url,options={}){return fetcher(url,{...options,redirect:'error',signal:AbortSignal.timeout(20000)});}
 async function rpc(name,args,authorization,server=false){
  const key=required(server?'SUPABASE_SERVICE_ROLE_KEY':'SUPABASE_ANON_KEY');
  const response=await request(supabase()+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:server?'Bearer '+key:authorization,'Content-Type':'application/json'},body:JSON.stringify(args)});
  if(!response.ok){if(server)throw new Fault(503,'The attachment service needs administrator attention.');let value={};try{value=await response.json();}catch{}throw new Fault(response.status===401?401:403,value.message||'This attachment is outside your permissions.');}
  return response.json();
 }
 const service=(action,data={})=>rpc('bc_document_service',{p_action:action,p_data:data},null,true);
 async function google(url,token,options={}){const response=await request(url,{...options,headers:{...(options.headers||{}),Authorization:'Bearer '+token}});if(!response.ok&&response.status!==404&&response.status!==409)throw new Fault(response.status===429?429:503,'The attachment service is temporarily unavailable. Retry shortly or contact the administrator.');return response;}
 async function generatedId(token){const r=await google(DRIVE+'/files/generateIds?count=1&space=drive&type=files',token);const v=await r.json();return fileId(v.ids?.[0]);}
 async function metadata(token,key){const r=await google(DRIVE+'/files/'+fileId(key)+'?fields=id,name,mimeType,size,sha256Checksum,parents,appProperties,trashed,shared,ownedByMe,webViewLink',token);return r.status===404?null:r.json();}
 async function ensureFolder(token,key,name,parent,properties){
  let value=await metadata(token,key);
  if(!value){const r=await google(DRIVE+'/files?fields=id,name,mimeType,parents,appProperties,trashed,shared,ownedByMe,webViewLink',token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:key,name,mimeType:'application/vnd.google-apps.folder',...(parent?{parents:[parent]}:{}),appProperties:properties})});value=r.status===409?await metadata(token,key):await r.json();}
  if(!value||value.trashed||value.shared||!value.ownedByMe||value.mimeType!=='application/vnd.google-apps.folder'||(parent&&!value.parents?.includes(parent))||Object.entries(properties).some(([k,v])=>value.appProperties?.[k]!==v))throw new Fault(503,'The private attachment folder needs owner attention.');
  return value;
 }
 async function tokenFor(connection){
  const creds=connection?.credentials;if(!creds?.refresh_token)throw new Fault(503,'The attachment service needs the owner to reconnect.');
  if(Date.parse(creds.expires_at)>now()+60000)return creds.access_token;
  const r=await request('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:creds.refresh_token,client_id:required('GOOGLE_DRIVE_CLIENT_ID'),client_secret:required('GOOGLE_DRIVE_CLIENT_SECRET')})});
  if(!r.ok){let reason='';try{reason=(await r.json()).error;}catch{}if(['invalid_client','invalid_grant','unauthorized_client'].includes(reason)){await service('connection.error');throw new Fault(503,'The attachment service needs the owner to reconnect.');}throw new Fault(r.status===429?429:503,'The attachment service is temporarily unavailable. Retry shortly.');}
  const data=await r.json();if(!data.access_token||!Number.isFinite(Number(data.expires_in)))throw new Fault(503,'The attachment service needs owner attention.');
  await service('connection.token',{credentials:{access_token:data.access_token,expires_at:new Date(now()+Number(data.expires_in)*1000).toISOString(),...(data.refresh_token?{refresh_token:data.refresh_token}:{})}});return data.access_token;
 }
 async function fileBytes(token,key){const r=await google(DRIVE+'/files/'+fileId(key)+'?alt=media',token);if(r.status===404)throw new Fault(404,'The attachment is unavailable. Contact the administrator.');return boundedBody(r,MAX_FILE);}
 async function checkRemote(token,key,context,digest,parent){
  const value=await metadata(token,key);if(!value)return null;
  if(value.trashed||value.shared||!value.ownedByMe||Number(value.size)!==Number(context.bytes)||value.mimeType!==context.mime||!value.parents?.includes(parent)||value.appProperties?.binderclipDocument!==context.id||value.appProperties?.sha256!==digest)throw new Fault(409,'This attachment was changed or moved outside Binderclip. Contact the administrator.');
  if(value.sha256Checksum?value.sha256Checksum!==digest:(await sha256(await fileBytes(token,key)))!==digest)throw new Fault(409,'Attachment integrity verification failed. Contact the administrator.');return value;
 }
 async function uploadDrive(context,manifest,bytes,digest){
  const connection=await service('connection.get');if(connection.status!=='Ready')throw new Fault(503,'The attachment service needs owner attention.');const token=await tokenFor(connection);
  await ensureFolder(token,connection.root_id,'Binderclip files',null,{binderclipStorage:'v1'});
  const recordType=context.record_type||'job',recordId=context.record_id||context.job_id;
  const folder=await service('folder.claim',{tenant_id:context.tenant_id,job_id:context.job_id,record_type:recordType,record_id:recordId,external_id:await generatedId(token)});
  await ensureFolder(token,folder.external_id,(context.record_number||context.job_number)+' · '+context.tenant_id,folder.parent_id,recordType==='job'?{binderclipTenant:context.tenant_id,binderclipJob:recordId}:{binderclipTenant:context.tenant_id,binderclipRecord:recordId,binderclipType:recordType});
  manifest=await service('document.claim',{id:context.id,created_by:context.created_by,sha256:digest,external_id:manifest.external_id||await generatedId(token)});
  if(!await checkRemote(token,manifest.external_id,context,digest,manifest.parent_id)){
   const boundary='binderclip-'+crypto.randomUUID(),meta={id:manifest.external_id,name:context.filename,mimeType:context.mime,parents:[manifest.parent_id],appProperties:{binderclipDocument:context.id,sha256:digest}};
   const body=new Blob([`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(meta)}\r\n--${boundary}\r\nContent-Type: ${context.mime}\r\n\r\n`,bytes,`\r\n--${boundary}--\r\n`]);
   await google(UPLOAD+'/files?uploadType=multipart&fields=id',token,{method:'POST',headers:{'Content-Type':'multipart/related; boundary='+boundary},body});
   if(!await checkRemote(token,manifest.external_id,context,digest,manifest.parent_id))throw new Fault(503,'Upload verification is pending. Retry the same attachment.');
  }
 }
 async function owner(requestValue,url){
  const ownerEmail=required('GOOGLE_DRIVE_OWNER_EMAIL').toLowerCase();required('GOOGLE_DRIVE_CLIENT_SECRET');const clientId=required('GOOGLE_DRIVE_CLIENT_ID');
  const cookiePath='/functions/v1/binderclip-documents/owner',cookie=(state,age=600)=>`bc_drive_setup=${state}; Path=${cookiePath}; Secure; HttpOnly; SameSite=Lax; Max-Age=${age}`;
  if(url.pathname.endsWith('/owner/connect')){
   const current=await service('connection.get');if(current.root_id&&current.status==='Ready'&&current.credentials?.refresh_token&&env('GOOGLE_DRIVE_SETUP_ENABLED')!=='true')throw new Fault(403,'Owner setup is closed. Re-enable it in the backend for an authorized reconnection.');
   const state=base64url(crypto.getRandomValues(new Uint8Array(32))),verifier=base64url(crypto.getRandomValues(new Uint8Array(32)));
   await service('state.create',{state_hash:await sha256(new TextEncoder().encode(state)),verifier});
   const target=new URL('https://accounts.google.com/o/oauth2/v2/auth');target.search=new URLSearchParams({client_id:clientId,redirect_uri:callbackURL(),response_type:'code',scope:SCOPES,access_type:'offline',prompt:'consent',state,code_challenge:base64url(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier)))),code_challenge_method:'S256'});
   return new Response(null,{status:303,headers:{Location:target.href,'Set-Cookie':cookie(state),'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});
  }
  const state=url.searchParams.get('state'),stored=requestValue.headers.get('cookie')?.split(';').map(x=>x.trim()).find(x=>x.startsWith('bc_drive_setup='))?.slice(15);
  if(!state||state!==stored||url.searchParams.has('error')||!url.searchParams.get('code'))throw new Fault(403,'Owner authorization was not completed. Start the connection again.');
  const pending=await service('state.consume',{state_hash:await sha256(new TextEncoder().encode(state))});
  const response=await request('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:clientId,client_secret:required('GOOGLE_DRIVE_CLIENT_SECRET'),code:url.searchParams.get('code'),code_verifier:pending.verifier,redirect_uri:callbackURL(),grant_type:'authorization_code'})});
  if(!response.ok){
   // Return only known categories, never Google's raw response, codes or credentials.
   let reason='';try{reason=(await response.json()).error;}catch{}
   const messages={invalid_client:'Google rejected the OAuth client credentials. Re-enter the Client Secret for the Binderclip private attachments client in the backend, then start a new connection.',invalid_grant:'Google authorization expired or was already used. Start a new connection and complete it once without refreshing the callback.',redirect_uri_mismatch:'The Google OAuth callback address does not match the backend configuration.',unauthorized_client:'Google has not authorized this OAuth web client for the requested connection.'};
   throw new Fault(403,messages[reason]||'Google authorization could not be completed. Check the backend OAuth settings and reconnect.');
  }const credentials=await response.json();
  if(!credentials.refresh_token||!credentials.scope?.split(' ').includes('https://www.googleapis.com/auth/drive.file'))throw new Fault(403,'Offline access to app-created files is required. Reconnect and approve the requested access.');
  const userResponse=await request('https://openidconnect.googleapis.com/v1/userinfo',{headers:{Authorization:'Bearer '+credentials.access_token}});if(!userResponse.ok)throw new Fault(403,'Owner identity could not be verified.');const user=await userResponse.json();
  if(user.email_verified!==true||user.email?.toLowerCase()!==ownerEmail||!user.sub)throw new Fault(403,'Storage must be authorized by the designated owner account.');
  const current=await service('connection.get');const connection=await service('connection.save',{owner_email:user.email.toLowerCase(),owner_sub:user.sub,client_id:clientId,root_id:current.root_id||await generatedId(credentials.access_token),credentials:{refresh_token:credentials.refresh_token,access_token:credentials.access_token,expires_at:new Date(now()+Number(credentials.expires_in)*1000).toISOString()}});
  const folder=await ensureFolder(credentials.access_token,connection.root_id,'Binderclip files',null,{binderclipStorage:'v1'});
  await service('connection.ready',{root_url:folder.webViewLink});
  let quota='';try{const r=await google(DRIVE+'/about?fields=storageQuota',credentials.access_token);if(r.ok){const v=await r.json();quota=`\nAccount storage limit: ${v.storageQuota?.limit||'not supplied'} bytes. Used: ${v.storageQuota?.usage||'not supplied'} bytes.`;}}catch{}
  // The default Edge hostname rewrites HTML responses to plain text.
  return new Response(`Attachment storage connected.\n\nThis is an owner-only connection result. No storage settings appear in Binderclip.\nPrivate app-created folder: ${folder.webViewLink}\nThe owner may move this folder under Binderclip / Attachments; keep it private.${quota}\n\nReturn to Binderclip: ${appURL().href}`,{headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','Set-Cookie':cookie('',0)}});
 }
 return async requestValue=>{
  let cors={};try{
   const url=new URL(requestValue.url),origin=requestValue.headers.get('Origin'),allowed=appURL().origin;
   if(origin&&origin!==allowed)throw new Fault(403,'Origin is not allowed.');cors={'Access-Control-Allow-Origin':allowed,'Vary':'Origin','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info, x-supabase-api-version','Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Expose-Headers':'Content-Disposition'};
   if(requestValue.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
   if(requestValue.method==='GET'&&/\/owner\/(connect|callback)$/.test(url.pathname))return await owner(requestValue,url);
   if(requestValue.method!=='POST')throw new Fault(405,'Use the document upload/download actions in Binderclip.');
   const authorization=requestValue.headers.get('Authorization');if(!authorization?.startsWith('Bearer '))throw new Fault(401,'Sign in to Binderclip first.');
   await rpc('bc_session',{},authorization);
   const raw=await boundedBody(requestValue,MAX_FILE+65536);let values,file;
   if(requestValue.headers.get('Content-Type')?.startsWith('multipart/form-data')){const form=await new Response(raw,{headers:{'Content-Type':requestValue.headers.get('Content-Type')}}).formData();values=Object.fromEntries(form);file=form.get('file');}
   else{try{values=JSON.parse(new TextDecoder().decode(raw));}catch{throw new Fault(400,'Invalid document request.');}}
   const action=values.action;if(!['upload','download'].includes(action))throw new Fault(400,'Unknown document action.');
   const args={p_tenant:id(values.tenant_id),p_id:id(values.document_id),p_action:action==='upload'?'C':'X'};
   const context=await rpc('bc_document_context',args,authorization);let manifest=await service('document.get',{id:context.id});
   if(action==='upload'){
    if(!file||typeof file.arrayBuffer!=='function'||file.name!==context.filename||file.size!==Number(context.bytes))throw new Fault(400,'Select the original file matching this attachment name and size.');
    const bytes=new Uint8Array(await file.arrayBuffer());validateFile(bytes,context.mime,context.filename);const digest=await sha256(bytes);
    if(manifest.sha256&&manifest.sha256!==digest)throw new Fault(409,'Select the original file for this pending attachment.');
    if(manifest.provider==='google_drive')await uploadDrive(context,manifest,bytes,digest);
    else{
     await service('document.claim',{id:context.id,created_by:context.created_by,sha256:digest});
     const path=context.object_path.split('/').map(encodeURIComponent).join('/'),headers={apikey:required('SUPABASE_ANON_KEY'),Authorization:authorization};
     // Pending objects are intentionally not downloadable through browser RLS.
     // A retry may hit an already-uploaded object; verify it using the server key.
     const uploaded=await request(supabase()+'/storage/v1/object/binderclip-documents/'+path,{method:'POST',headers:{...headers,'Content-Type':context.mime,'x-upsert':'false'},body:bytes});
     if(!uploaded.ok&&![400,409].includes(uploaded.status))throw new Fault(503,'Upload interrupted. Retry the same attachment.');
     const serverKey=required('SUPABASE_SERVICE_ROLE_KEY');const check=await request(supabase()+'/storage/v1/object/authenticated/binderclip-documents/'+path,{headers:{apikey:serverKey,Authorization:'Bearer '+serverKey}});
     if(!check.ok||await sha256(await boundedBody(check,MAX_FILE))!==digest)throw new Fault(409,'Uploaded file verification failed. Retry the original attachment.');
    }
    await service('document.verified',{id:context.id,created_by:context.created_by,sha256:digest});
    await rpc('bc_document_finish',{p_tenant:args.p_tenant,p_id:args.p_id},authorization);return json({id:context.id,status:'Ready'},200,cors);
   }
   let bytes;
   if(manifest.provider==='google_drive'){
    const connection=await service('connection.get'),token=await tokenFor(connection);
    if(!manifest.sha256||!manifest.external_id||!await checkRemote(token,manifest.external_id,context,manifest.sha256,manifest.parent_id))throw new Fault(404,'The attachment is unavailable.');bytes=await fileBytes(token,manifest.external_id);
   }else{const path=context.object_path.split('/').map(encodeURIComponent).join('/');const r=await request(supabase()+'/storage/v1/object/authenticated/binderclip-documents/'+path,{headers:{apikey:required('SUPABASE_ANON_KEY'),Authorization:authorization}});if(!r.ok)throw new Fault(404,'The attachment is unavailable. Contact the administrator.');bytes=await boundedBody(r,MAX_FILE);}
   if(bytes.length!==Number(context.bytes)||(manifest.sha256&&await sha256(bytes)!==manifest.sha256))throw new Fault(409,'Attachment integrity verification failed. Contact the administrator.');validateFile(bytes,context.mime,context.filename);
   await rpc('bc_document_context',args,authorization);
   const filename=encodeURIComponent(context.filename).replace(/['()*]/g,c=>'%'+c.charCodeAt(0).toString(16));return new Response(bytes,{headers:{...cors,'Content-Type':'application/octet-stream','Content-Disposition':"attachment; filename*=UTF-8''"+filename,'X-Content-Type-Options':'nosniff','Content-Security-Policy':"sandbox; default-src 'none'",'Cache-Control':'private, no-store'}});
  }catch(error){return json({error:error instanceof Fault?error.message:'The attachment service could not complete this request. Retry or contact the administrator.'},error instanceof Fault?error.status:503,cors);}
 };
}
if(import.meta.main&&globalThis.Deno)globalThis.Deno.serve(createDocumentHandler());
