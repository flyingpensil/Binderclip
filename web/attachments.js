import {escapeHTML as h} from './domain.js';
import {tracking} from './tracking.js';
export function createAttachments(ctx){
 const {state,rpc,can,panel,table,button,badge,edit,documentService}=ctx,rows=new Map();
 const request=(type,id,action='list',data={})=>rpc('bc_attachments',{p_tenant:state.member.tenant_id,p_type:type,p_id:id,p_action:action,p_data:data});
 async function section(type,id){
  if(!can('operations.documents.manage'))return '';
  let records;try{records=await request(type,id);}catch(error){return panel('Attachments',`<div class="notice error" role="alert">Attachments unavailable: ${h(error.message)}</div>`,button('Retry','attachment-refresh'));}for(const r of records)rows.set(r.id,{...r,type,recordId:id});
  return panel('Attachments',table(['Document / file','Type','Size','Status','Actions'],records.map(r=>[`${h(r.document_number)}<small>${h(r.filename)}</small>${tracking(r)}`,h(r.kind),`${h(r.bytes)} bytes`,badge(r.status),r.status==='Ready'&&can('operations.documents.manage','X')?button('Download','attachment-download',{id:r.id}):r.status==='Pending'&&r.created_by===state.session.user_id&&can('operations.documents.manage','C')?button('Retry upload','attachment-retry',{id:r.id}):'']))+'<p class="read-limit">Private attachments for this document · PDF, PNG, JPEG, TXT or CSV · maximum 10 MB per file.</p>',can('operations.documents.manage','C')?button('＋ Upload file','attachment-upload',{type,record:id}):'');
 }
 function upload(type,id,pending){let registration=pending?{id:pending.id}:null,fingerprint=pending?`${pending.filename}|${pending.bytes}|${pending.mime}|${pending.kind}`:null;
  edit(pending?'Retry attachment':'Attach related document',[
   {key:'kind',label:'Document type',type:'select',required:true,options:pending?[pending.kind]:['Other','BL','AWB','Bayan','Supplier invoice','Customer invoice','POD']},
   {key:'upload',label:pending?`Original file: ${pending.filename}`:'Choose file (maximum 10 MB)',type:'file',required:true,accept:'.pdf,.png,.jpg,.jpeg,.txt,.csv'}
  ],{kind:pending?.kind||'Other'},async values=>{
   const file=document.querySelector('#editor-form [name=upload]').files[0];if(!file||file.size<1||file.size>10485760)throw Error('Choose a non-empty file no larger than 10 MB.');
   const mime={pdf:'application/pdf',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',txt:'text/plain',csv:'text/csv'}[file.name.split('.').at(-1).toLowerCase()];if(!mime)throw Error('Use PDF, PNG, JPEG, TXT or CSV.');
   const signature=`${file.name}|${file.size}|${mime}|${values.kind}`;if(pending&&signature!==fingerprint)throw Error('Choose the original file with the same name, size and type.');
   if(!registration||signature!==fingerprint){registration=await request(type,id,'register',{kind:values.kind,filename:file.name,mime,bytes:String(file.size)});fingerprint=signature;}
   const form=new FormData();form.set('action','upload');form.set('tenant_id',state.member.tenant_id);form.set('document_id',registration.id);form.set('file',file);
   try{await documentService(form);}catch(error){throw Error(`Upload failed: ${error.message} Retry the same file; its pending entry is retained.`);}
  });
 }
 async function action(d){if(d.do==='attachment-refresh')return ctx.render();if(d.do==='attachment-upload')return upload(d.type,d.record);const row=rows.get(d.id);if(!row)throw Error('Refresh this document and try again.');if(d.do==='attachment-retry')return upload(row.type,row.recordId,row);if(d.do==='attachment-download'){
  const blob=await documentService({action:'download',tenant_id:state.member.tenant_id,document_id:row.id});if(!(blob instanceof Blob))throw Error('The attachment could not be downloaded.');const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=row.filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);
 }}
 return {section,action};
}
