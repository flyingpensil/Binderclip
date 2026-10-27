import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';

// Isolated DOM/RPC boundary test. Never contacts or signs in to a real Supabase project.
test('authenticated freight workspace renders and submits complete workflows',async t=>{
 const dom=new JSDOM(await readFile(new URL('../index.html',import.meta.url),'utf8'),{url:'https://example.test/Binderclip/'});
 const w=dom.window;
 const globals=['window','document','location','history','sessionStorage','FormData'];
 const saved=new Map(globals.map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]));
 for(const k of globals)Object.defineProperty(globalThis,k,{value:k==='window'?w:w[k],configurable:true,writable:true});
 const oldFetch=globalThis.fetch,oldInterval=globalThis.setInterval;globalThis.setInterval=()=>0;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 const paths=['overview.dashboard.view','jobs.list.manage','costs.detail.manage','customers.list.manage','suppliers.list.manage','sales.enquiries.manage','sales.quotes.manage','sales.quotes.approve','sales.quotes.convert','sales.quotes.print','operations.timeline.manage','operations.tasks.manage','operations.documents.manage','operations.requirements.manage','finance.payments.manage','reports.finance.view','reports.journal.view','settings.roles.manage','settings.members.manage','settings.company.manage','invoicing.list.manage'];
 const member={tenant_id:'tenant',display_name:'Admin1',branch:'Dubai',email:'admin@example.test',company:{name:'Binderclip',currency:'AED'},grants:paths.flatMap(path=>['C','R','U','X'].map(action=>({path,action,scope:'global',can_export:true})))};
 const calls=[],uploads=[];let commandError=null,uploadError=null;
 const enquiry={id:'e1',number:'ENQ-1',customer_id:'c1',subject:'Import machinery',customer_name:'Customer',status:'Pending',data:{pol:'Shanghai',pod:'Jebel Ali',mode:'Ocean'}};
 const lines=[{side:'BUY',service:'Carrier',quantity:'2.000',unit_rate:'500.00',tax_rate:'5.00'},{side:'SELL',service:'Freight',quantity:'2.000',unit_rate:'800.00',tax_rate:'5.00'}];
 const quote={id:'q1',number:'QUO-1',customer_id:'c1',customer_name:'Customer',company_name:'Binderclip',enquiry_id:'e1',status:'Draft',valid_until:'2099-01-01',currency:'AED',fx_rate:'1',terms:'Net 30',data:enquiry.data,lines};
 const bill={id:'b1',number:'BILL-1',supplier_name:'Carrier',job_number:'J1',total:'1000.00',paid:'0.00',currency:'AED',invoice_date:'2026-01-01'};
 const job={id:'j1',number:'J1',customer:{name:'Customer'},data:enquiry.data,status:'Draft',invoices:[],audit:[]};
 async function fakeRpc(name,args){calls.push({name,args});if(name==='bc_session')return {data:{user_id:'user',memberships:[member],permissions:[]}};
  if(['bc_workflow','bc_command'].includes(name))return commandError?{error:{message:commandError}}:{data:{id:args.p_action==='quote.convert'?'j1':'created'}};
  if(name==='bc_document_finish')return {data:{id:args.p_id}};
  if(name==='bc_report')return {data:{currency:'AED',rows:args.p_kind==='trial_balance'?[{account:'1000 Bank',debit:'1000.00',credit:'0.00',balance:'1000.00'},{account:'2100 Payables',debit:'0.00',credit:'1000.00',balance:'-1000.00'}]:[]}};
  if(name==='bc_read'){const data={overview:{active_jobs:'1',customers:'1',receivables:'0',pending_bills:'0',jobs:[]},customers:[{id:'c1',name:'Customer',code:'C1',data:{}}],suppliers:[{id:'s1',name:'Carrier',code:'S1',data:{}}],job,jobs:[],roles:[],members:[],invoices:[],journal:[]};return {data:data[args.p_kind]??[]};}
  if(name==='bc_workspace'){const data={enquiries:[enquiry],quotes:[quote],quote,quote_print:{...quote,lines:lines.filter(l=>l.side==='SELL')},tasks:[],assignees:[{id:'m1',name:'Operations'}],payables:[bill],job_workspace:{events:[],tasks:[],documents:[],requirements:[]},search:{jobs:[job],customers:[],suppliers:[],invoices:[],enquiries:[],quotes:[quote]}};return {data:data[args.p_kind]};}
  throw new Error('Unexpected RPC '+name);
 }
 w.supabase={createClient:()=>({rpc:fakeRpc,auth:{getUser:async()=>({data:{user:{id:'user'}}}),onAuthStateChange:()=>{},signOut:async()=>({})},storage:{from:()=>({upload:async(path,file,options)=>{uploads.push({path,file,options});return {error:uploadError};}})}})};
 globalThis.fetch=async()=>({ok:true,json:async()=>({url:'https://example.supabase.co',publishableKey:'sb_publishable_test',features:{freight:true}})});
 const wait=async predicate=>{const deadline=Date.now()+2000;while(!predicate()){if(Date.now()>deadline)throw new Error('DOM condition timed out: '+w.document.body.textContent.slice(-800));await new Promise(resolve=>setImmediate(resolve));}};
 const click=async selector=>{const el=w.document.querySelector(selector);assert.ok(el,'Missing '+selector);el.click();await new Promise(resolve=>setImmediate(resolve));};
 const route=async(hash,text)=>{w.location.hash=hash;await wait(()=>w.document.getElementById('screen').textContent.includes(text)&&w.document.getElementById('breadcrumb').textContent===hash.split('/')[0]);};
 const submit=async values=>{const form=w.document.getElementById('editor-form');for(const [name,value]of Object.entries(values))form.elements.namedItem(name).value=value;form.noValidate=!!form.querySelector('[name=upload]');form.requestSubmit();await wait(()=>!w.document.getElementById('editor').open||!w.document.getElementById('form-error').hidden);};
 try{
  await import('../app.js?dom-workflow-test');await wait(()=>!w.document.getElementById('workspace').hidden);
  await t.test('new modules render and enquiry data reaches the database command',async()=>{
   await route('sales','Sales pipeline');assert.match(w.document.getElementById('nav').textContent,/Supplier payments/);
   await click('[data-do="freight-enquiry"]');await wait(()=>w.document.getElementById('editor').open);
   await submit({customer_id:'c1',subject:'Machine import','data.pol':'Shanghai','data.pod':'Jebel Ali'});
   assert.ok(calls.some(c=>c.name==='bc_workflow'&&c.args.p_action==='enquiry.save'&&c.args.p_data.data.pol==='Shanghai'));
  });
  await t.test('quotation displays exact sell totals and approval uses a server command',async()=>{
   await route('quote/q1','QUO-1');assert.match(w.document.getElementById('screen').textContent,/1,680.00/);
   await click('[data-process="quote.approve"]');await wait(()=>calls.some(c=>c.args.p_action==='quote.approve'));
  });
  await t.test('server rejection is shown on form and leaves it open',async()=>{
   await route('sales','Sales pipeline');await click('[data-do="freight-enquiry"]');await wait(()=>w.document.getElementById('editor').open);
   commandError='Your role cannot create enquiries';await submit({customer_id:'c1',subject:'Denied','data.pol':'A','data.pod':'B'});
   assert.equal(w.document.getElementById('editor').open,true);assert.match(w.document.getElementById('form-error').textContent,/cannot create/);commandError=null;w.document.getElementById('editor').close();
  });
  await t.test('job exposes tasks, private files and milestone forms',async()=>{
   await route('job/j1','Job documents');await click('[data-do="freight-task"]');await wait(()=>w.document.getElementById('editor').open);
   await submit({title:'Check BL','due_on':'2026-10-27',required_before:'Booked',assignee_id:'m1'});
   assert.ok(calls.some(c=>c.args.p_action==='task.add'&&c.args.p_data.required_before==='Booked'&&c.args.p_data.job_id==='j1'));
  });
  await t.test('upload registers, sends private file, and finalizes only after success',async()=>{
   await click('[data-do="freight-document"]');await wait(()=>w.document.getElementById('editor').open);
   const input=w.document.querySelector('[name=upload]');Object.defineProperty(input,'files',{value:[new w.File(['pdf'],'bl.pdf',{type:'application/pdf'})]});
   await submit({kind:'BL'});assert.equal(uploads[0].path,'tenant/j1/created');assert.equal(uploads[0].options.upsert,false);
   assert.ok(calls.some(c=>c.name==='bc_document_finish'));
  });
  await t.test('failed upload never finalizes a document',async()=>{
   const before=calls.filter(c=>c.name==='bc_document_finish').length;uploadError={message:'Network interrupted'};
   await click('[data-do="freight-document"]');await wait(()=>w.document.getElementById('editor').open);Object.defineProperty(w.document.querySelector('[name=upload]'),'files',{value:[new w.File(['pdf'],'bl.pdf',{type:'application/pdf'})]});
   await submit({kind:'BL'});assert.equal(calls.filter(c=>c.name==='bc_document_finish').length,before);assert.match(w.document.getElementById('form-error').textContent,/Upload failed/);uploadError=null;w.document.getElementById('editor').close();
  });
  await t.test('supplier payment form constrains amount and posts bill reference',async()=>{
   await route('payables','BILL-1');await click('[data-do="freight-payment"]');await wait(()=>w.document.getElementById('editor').open);
   assert.equal(w.document.querySelector('[name=amount]').max,'1000.00');await submit({reference:'PAY-1',amount:'400.00',paid_on:'2026-10-27'});
   assert.ok(calls.some(c=>c.args.p_action==='supplier.pay'&&c.args.p_data.id==='b1'&&c.args.p_data.amount==='400.00'));
  });
  await t.test('reports and universal search display server-scoped results',async()=>{
   await route('reports','Financial reports');const reportForm=w.document.getElementById('freight-report-form');reportForm.elements.report.value='trial_balance';reportForm.requestSubmit();await wait(()=>w.document.getElementById('screen').textContent.includes('Difference: 0.00'));
   const search=w.document.getElementById('global-search');search.elements.q.value='J1';search.requestSubmit();await wait(()=>w.location.hash==='#search'&&w.document.getElementById('screen').textContent.includes('Search results'));
   assert.ok(calls.some(c=>c.name==='bc_workspace'&&c.args.p_kind==='search'&&c.args.p_query==='J1'));
  });
 }finally{dom.window.close();globalThis.fetch=oldFetch;globalThis.setInterval=oldInterval;for(const [key,descriptor]of saved)if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];}
});
