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
 let invoiceReady=false,noCustomers=false;
 let printed='';w.print=()=>{printed=w.document.getElementById('screen').textContent;};
 member.grants.push(...['costs.detail.apply','costs.detail.disapprove','costs.detail.print','costs.detail.approve','costs.detail.book','costs.detail.match','invoicing.detail.generate'].flatMap(path=>['C','R','U','X'].map(action=>({path,action,scope:'global',can_export:true}))));
 const enquiry={id:'e1',number:'ENQ-1',customer_id:'c1',subject:'Import machinery',customer_name:'Customer',status:'Pending',data:{pol:'Shanghai',pod:'Jebel Ali',mode:'Ocean'}};
 const lines=[{id:'buy1',side:'BUY',service:'Carrier',quantity:'2.000',unit_rate:'500.00',tax_rate:'5.00'},{id:'sell1',side:'SELL',service:'Freight',quantity:'2.000',unit_rate:'800.00',tax_rate:'5.00'}];
 const quote={id:'q1',number:'QUO-1',customer_id:'c1',customer_name:'Customer',company_name:'Binderclip',enquiry_id:'e1',status:'Draft',valid_until:'2099-01-01',currency:'AED',fx_rate:'1',terms:'Net 30',data:enquiry.data,lines};
 const bill={id:'b1',number:'BILL-1',supplier_name:'Carrier',job_number:'J1',total:'1000.00',paid:'0.00',currency:'AED',invoice_date:'2026-01-01'};
 const job={id:'j1',number:'J1',customer:{name:'Customer'},data:enquiry.data,status:'Draft',invoices:[],audit:[]};
 const costSheet={...job,status:'Booked',approved:false,locked_at:null,base_currency:'AED',company_name:'Binderclip',has_invoices:false,unbilled_charges:'1',buy_lines:'1',matched_bills:'1',figures:{expected_buy:'1000.00',actual_buy:'1100.00',sell:'1600.00',expected_margin:'600.00',margin:'500.00',margin_percent:'31.25'},lines:lines.map(l=>({...l,currency:'AED',fx_rate:'1',supplier_name:l.side==='BUY'?'Carrier':null,supplier_id:l.side==='BUY'?'s1':null})),line_values:[{id:'buy1',estimated_base:'1000.00',actual_base:'1100.00'},{id:'sell1',estimated_base:'1600.00',actual_base:'1600.00'}],bills:[{id:'b1',line_id:'buy1',number:'BILL-1',quantity:'2',unit_rate:'550',currency:'AED',variance:'100.00',status:'Matched'}]};
 async function fakeRpc(name,args){calls.push({name,args});if(name==='bc_session')return {data:{user_id:'user',memberships:[member],permissions:[]}};
  if(name==='bc_practical'){const purchase={id:'p1',number:'PINV-000001',reference:'VENDOR-1',job_id:'j1',job_number:'J1',supplier_id:'s1',supplier_name:'Carrier',status:'Draft',match_status:'Draft',currency:'AED',fx_rate:'1',invoice_date:'2026-10-27',due_date:'2026-11-27',net:'1000.00',vat:'50.00',lines:[{id:'pi1',description:'Ocean freight',comments:'Carrier service',unit:'container',quantity:'2',unit_rate:'500',tax_rate:'5'}]};return {data:['purchases','purchase'].includes(args.p_action)?[purchase]:['statement','customer_aging'].includes(args.p_action)?{customer:{name:'Customer'},as_of:'2026-10-28',rows:[],totals:[{currency:'AED',opening:'0.00',debit:'1000.00',credit:'400.00',closing:'600.00'}]}:{id:args.p_action==='invoice.save'?'invoice-created':'p1'}};}
  if(name==='bc_billing')return {data:args.p_kind==='supplier_payments'?[]:args.p_kind==='invoice.create'?{id:'invoice-created'}:[{id:'j1',number:'J1',customer_id:'c1',customer_name:'Customer',status:invoiceReady?'Booked':'Draft',approved:invoiceReady,locked_at:null,buy_count:'1',charge_count:'1',unbilled_count:'1',matched_count:invoiceReady?'1':'0',billing_groups:'1',currency:'AED',fx_rate:'1',credit_days:'30'}]};
  if(name==='bc_costsheet')return {data:args.p_action==='detail'||args.p_action==='print'?costSheet:args.p_action==='list'?[{...costSheet,customer_name:'Customer',sheet_status:'Open'}]:args.p_action==='quotes'?[{id:'q1',name:'QUO-1'}]:{id:'created'}};
  if(['bc_workflow','bc_command'].includes(name))return commandError?{error:{message:commandError}}:{data:{id:args.p_action==='quote.convert'?'j1':'created'}};
  if(name==='bc_document_finish')return {data:{id:args.p_id}};
  if(name==='bc_report')return {data:{currency:'AED',rows:args.p_kind==='trial_balance'?[{account:'1000 Bank',debit:'1000.00',credit:'0.00',balance:'1000.00'},{account:'2100 Payables',debit:'0.00',credit:'1000.00',balance:'-1000.00'}]:[]}};
  if(name==='bc_read'){const data={overview:{active_jobs:'1',customers:'1',receivables:'0',pending_bills:'0',jobs:[]},customers:noCustomers?[]:[{id:'c1',name:'Customer',code:'C1',currency:'AED',data:{},created_by_name:'Admin1',created_at:'2026-10-27T09:30:00Z',updated_by_name:'Operations editor',updated_at:'2026-10-27T10:45:00Z'}],suppliers:[{id:'s1',name:'Carrier',code:'S1',data:{}}],job,jobs:[],roles:[],members:[],invoices:[],invoice:{id:'invoice-created',number:'INV-000001',status:'Draft',currency:'AED',fx_rate:'1',invoice_date:'2026-10-27',due_date:'2026-11-27',subtotal:'1600.00',tax_total:'80.00',total:'1680.00',paid:'0.00',items:[{id:'ii1',job_id:'j1',job_number:'J1',description:'Freight',quantity:'2',unit_rate:'800',tax_rate:'5',net:'1600',tax:'80',unit:'container',comments:''}],receipts:[],snapshot:{company:{name:'Binderclip',address:'',trn:''},customer:{name:'Customer',data:{}}}},journal:[]};return {data:data[args.p_kind]??[]};}
  if(name==='bc_workspace'){const data={enquiries:[enquiry],quotes:[quote],quote,quote_print:{...quote,lines:lines.filter(l=>l.side==='SELL')},tasks:[],assignees:[{id:'m1',name:'Operations'}],payables:[bill],job_workspace:{events:[],tasks:[],documents:[],requirements:[]},search:{jobs:[job],customers:[],suppliers:[],invoices:[],enquiries:[],quotes:[quote]}};return {data:data[args.p_kind]};}
  throw new Error('Unexpected RPC '+name);
 }
 w.supabase={createClient:()=>({rpc:fakeRpc,auth:{getUser:async()=>({data:{user:{id:'user'}}}),onAuthStateChange:()=>{},signOut:async()=>({})},storage:{from:()=>({upload:async(path,file,options)=>{uploads.push({path,file,options});return {error:uploadError};}})}})};
 globalThis.fetch=async()=>({ok:true,json:async()=>({url:'https://example.supabase.co',publishableKey:'sb_publishable_test',features:{freight:true,costSheets:true}})});
 const wait=async predicate=>{const deadline=Date.now()+2000;while(!predicate()){if(Date.now()>deadline)throw new Error('DOM condition timed out: '+w.document.body.textContent.slice(-800));await new Promise(resolve=>setImmediate(resolve));}};
 const click=async selector=>{const el=w.document.querySelector(selector);assert.ok(el,'Missing '+selector);el.click();await new Promise(resolve=>setImmediate(resolve));};
 const route=async(hash,text)=>{w.location.hash=hash;const page=hash.split('/')[0],label={invoices:'Customer invoices',customers:'Customers',jobs:'Jobs'}[page]||page;await wait(()=>w.document.getElementById('screen').textContent.includes(text)&&w.document.getElementById('breadcrumb').textContent===label);};
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
   await click('[data-line="sell1"]');await wait(()=>w.document.getElementById('editor').open);
   await submit({unit_rate:'850.00'});
   assert.ok(calls.some(c=>c.args.p_action==='quote.line'&&c.args.p_data.line_id==='sell1'&&c.args.p_data.unit_rate==='850.00'));
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
  await t.test('cost sheet separates actual supplier costs, revenue and profit',async()=>{
   await route('costsheets','Job financials');await route('costsheet/j1','Supplier costs — what we pay');
   const text=w.document.getElementById('screen').textContent;assert.match(text,/1,100.00/);assert.match(text,/1,600.00/);assert.match(text,/500.00/);assert.match(text,/31.25%/);
   assert.match(text,/BILL-1/);assert.match(text,/Customer charges — what we bill/);
   await click('[data-line="sell1"]');await wait(()=>w.document.getElementById('editor').open);
   await submit({unit_rate:'850.00',reason:'Agreed rate correction'});
   assert.ok(calls.some(c=>c.name==='bc_costsheet'&&c.args.p_action==='line.save'&&c.args.p_data.line_id==='sell1'&&c.args.p_data.reason==='Agreed rate correction'));
   await click('[data-do="costsheet-print"]');await wait(()=>printed.includes('INTERNAL COST SHEET'));
   assert.match(printed,/550.00/);assert.match(printed,/500.00/);
  });
  await t.test('approved cost sheet offers invoice creation rather than price editing',async()=>{
   costSheet.approved=true;await route('sales','Sales pipeline');await route('costsheet/j1','Approved and ready');
   assert.equal(w.document.querySelector('[data-line="sell1"]'),null);
   await click('[data-do="costsheet-invoice"]');await wait(()=>w.document.getElementById('editor').open);
   assert.ok(w.document.querySelector('[name=invoice_date]'));assert.ok(w.document.querySelector('[name=due_date]'));w.document.getElementById('editor').close();
  });
  await t.test('client forms use automatic identifiers, full currency choices and cargo addresses',async()=>{
   await route('customers','Customer');await click('[data-do="new-master"][data-kind="customers"]');await wait(()=>w.document.getElementById('editor').open);
   assert.equal(w.document.querySelector('[name=code]').readOnly,true);
   assert.ok(w.document.querySelectorAll('[name=currency] option').length>150);
   await submit({name:'Japanese customer',currency:'JPY'});
   assert.ok(calls.some(c=>c.args.p_action==='master.save'&&c.args.p_data.currency==='JPY'&&c.args.p_data.code===''));
   await route('jobs','Every shipment');await click('[data-do="new-job"]');await wait(()=>w.document.getElementById('editor').open);
   assert.equal(w.document.querySelector('[name=number]').readOnly,true);assert.equal(w.document.querySelector('[name="data.supplier_job_number"]'),null);
   await submit({customer_id:'c1','data.pol':'Tokyo','data.pod':'Dubai','data.shipper_address':'Tokyo warehouse','data.consignee_address':'Dubai warehouse'});
   assert.ok(calls.some(c=>c.args.p_action==='job.save'&&c.args.p_data.data.shipper_address==='Tokyo warehouse'&&c.args.p_data.data.consignee_address==='Dubai warehouse'));
  });
  await t.test('invoice page explains unfinished jobs and never submits an empty consolidation',async()=>{
   await route('invoices','Jobs that need another step');const before=calls.filter(c=>c.args.p_kind==='invoice.create').length;
   await click('[data-do="billing-start"]');assert.match(w.document.getElementById('notice').textContent,/No jobs are ready/);
   assert.equal(w.document.getElementById('consolidate-form'),null);
   assert.equal(calls.filter(c=>c.args.p_kind==='invoice.create').length,before);
  });
  await t.test('ready job has a clear single-invoice action and guarded consolidation',async()=>{
   invoiceReady=true;await route('sales','Sales pipeline');await route('invoices','Generate consolidated invoice');
   const form=w.document.getElementById('billing-consolidate-form');assert.equal(form.querySelector('button').disabled,true);
   const checkbox=form.querySelector('[name=job_ids]');checkbox.checked=true;checkbox.dispatchEvent(new w.Event('change',{bubbles:true}));assert.equal(form.querySelector('button').disabled,false);
   await click('[data-do="billing-start"]');await wait(()=>w.document.getElementById('editor').open);
   await submit({job_id:'j1',invoice_date:'2026-10-27',due_date:'2026-11-27'});
   await wait(()=>w.location.hash==='#invoice/invoice-created');assert.ok(calls.some(c=>c.args.p_kind==='invoice.create'&&c.args.p_data.job_ids[0]==='j1'));
  });
  await t.test('entry history is visible, old environment label is removed and detail navigation stays selected',async()=>{
   await route('customers','Customers');
   const history=w.document.querySelector('#screen .record-tracking');assert.ok(history);assert.match(history.textContent,/Admin1/);assert.match(history.textContent,/Operations editor/);assert.match(history.textContent,/13:30 GST/);
   assert.equal(w.document.querySelector('.environment'),null);assert.ok(w.document.getElementById('nav-search'));
   await route('job/j1','Job documents');assert.equal(w.document.querySelector('[href="#jobs"]').getAttribute('aria-current'),'page');
  });
  await t.test('job creation explains missing customer prerequisite without opening a broken form',async()=>{
   noCustomers=true;await route('jobs','Jobs');await click('[data-do="new-job"]');
   assert.equal(w.document.getElementById('editor').open,false);assert.match(w.document.getElementById('notice').textContent,/Create a customer/);noCustomers=false;
  });
  await t.test('supplier invoice grid supports multiple lines and posts the complete vendor document',async()=>{
   await route('purchase-new/j1','Enter supplier invoice');
   const form=w.document.getElementById('practical-entry-form');form.elements.reference.value='VENDOR-NEW';
   form.elements.description_0.value='Freight';form.elements.quantity_0.value='2';form.elements.unit_rate_0.value='500';form.elements.tax_rate_0.value='5';
   await click('[data-do="practical-add-line"]');form.elements.description_1.value='Handling';form.elements.quantity_1.value='1';form.elements.unit_rate_1.value='100';form.elements.tax_rate_1.value='5';
   form.requestSubmit();await wait(()=>calls.some(c=>c.name==='bc_practical'&&c.args.p_action==='purchase.save'));
   const saved=calls.findLast(c=>c.args.p_action==='purchase.save');assert.equal(saved.args.p_data.lines.length,2);assert.equal(saved.args.p_data.reference,'VENDOR-NEW');
   await wait(()=>w.location.hash==='#purchase/p1');await route('purchases/j1','PINV-000001');
  });
  await t.test('invoice preparation offers requested columns, live totals and server save',async()=>{
   await route('invoice-edit/invoice-created','Prepare invoice');
   const form=w.document.getElementById('practical-entry-form');form.elements.discount.value='100';form.elements.adjustment.value='20';
   form.elements.discount.dispatchEvent(new w.Event('input',{bubbles:true}));assert.match(form.querySelector('.entry-totals').textContent,/1,596.00/);
   assert.ok(form.elements.comments_0);assert.ok(form.elements.unit_0);assert.ok(form.elements.tax_rate_0);
   form.requestSubmit();await wait(()=>calls.some(c=>c.args.p_action==='invoice.save'));
   const saved=calls.findLast(c=>c.args.p_action==='invoice.save');assert.equal(saved.args.p_data.discount,'100');assert.equal(saved.args.p_data.adjustment,'20');
   await wait(()=>w.location.hash==='#invoice/invoice-created'&&w.document.getElementById('breadcrumb').textContent==='invoice');
  });
  await t.test('customer report selection requests a scoped statement and shows currency totals',async()=>{
   await route('customer-reports/statement','Choose a customer');
   const form=w.document.getElementById('customer-report-form');form.elements.customer_id.value='c1';form.requestSubmit();
   await wait(()=>w.document.querySelector('.report-paper'));assert.match(w.document.querySelector('.report-paper').textContent,/600.00/);
   assert.ok(calls.some(c=>c.args.p_action==='statement'&&c.args.p_data.customer_id==='c1'));
  });
  await t.test('sidebar follows setup, operations, billing and finance order',()=>{
   const routes=[...w.document.querySelectorAll('#nav a')].map(a=>a.hash);
   for(const [before,after]of [['#customers','#sales'],['#sales','#jobs'],['#jobs','#costsheets'],['#costsheets','#invoices'],['#invoices','#payables'],['#payables','#reports']])assert.ok(routes.indexOf(before)<routes.indexOf(after));
  });
 }finally{dom.window.close();globalThis.fetch=oldFetch;globalThis.setInterval=oldInterval;for(const [key,descriptor]of saved)if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];}
});
