import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {createAttachments} from '../attachments.js';

test('each document lists its own attachments and interrupted uploads reuse registration',async()=>{
 const dom=new JSDOM('<form id="editor-form"><input name="upload" type="file"></form>'),oldDocument=globalThis.document,oldForm=globalThis.FormData;globalThis.document=dom.window.document;globalThis.FormData=dom.window.FormData;
 try{
  const calls=[],uploads=[];let submit,failUpload=true;
  const ctx={state:{member:{tenant_id:'company'},session:{user_id:'user'}},can:()=>true,panel:(title,body,actions)=>title+body+actions,table:()=>'',button:(label)=>label,badge:x=>x,
   rpc:async(name,args)=>{calls.push({name,args});return args.p_action==='list'?[]:{id:'registered-doc'};},edit:(_title,_fields,_initial,save)=>{submit=save;},documentService:async form=>{uploads.push(form);if(failUpload)throw Error('Network interrupted');}};
  const ui=createAttachments(ctx);
  for(const type of ['job','quote','purchase','costsheet','invoice']){assert.match(await ui.section(type,type+'-id'),/Upload file/);assert.equal(calls.at(-1).args.p_type,type);assert.equal(calls.at(-1).args.p_id,type+'-id');}
  ui.action({do:'attachment-upload',type:'quote',record:'q1'});Object.defineProperty(document.querySelector('[name=upload]'),'files',{value:[new dom.window.File(['sample'],'quote.txt',{type:'text/plain'})]});
  await assert.rejects(submit({kind:'Other'}),/Retry the same file/);assert.equal(calls.at(-1).args.p_type,'quote');assert.equal(calls.at(-1).args.p_id,'q1');
  const registrations=()=>calls.filter(x=>x.args.p_action==='register').length;assert.equal(registrations(),1);failUpload=false;await submit({kind:'Other'});assert.equal(registrations(),1);assert.equal(uploads[1].get('document_id'),'registered-doc');assert.equal(uploads[1].get('tenant_id'),'company');
 }finally{globalThis.document=oldDocument;globalThis.FormData=oldForm;dom.window.close();}
});
