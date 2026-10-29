import {escapeHTML as h,money,displayStatus} from './domain.js';

const selections=new Map();
const positions=new Map();
const recordPages=new Set(['job','costsheet','invoice','quote','purchase']);
const names={job:'Shipment',costsheet:'Cost sheet',invoice:'Customer invoice',quote:'Quotation',purchase:'Supplier invoice'};
const groups={
 job:[['Details',/Shipment details/],['Operations',/Shipment timeline|Tasks & stage|Required stage/],['Financials',/cost sheet|Customer invoices/i],['Attachments',/documents|Attachments/i],['History',/Job activity/]],
 costsheet:[['Supplier invoices',/Select supplier invoices|Supplier invoice documents/],['Supplier costs',/^Supplier costs/],['Customer charges',/^Customer charges/],['Reconciliation',/Supplier invoice review/],['Customer invoices',/Final customer invoices/],['Attachments',/Attachments/],['History',/correction history/i]],
 invoice:[['Lines',/^Invoice lines$/],['Payments',/^Payments/],['Attachments',/Attachments/],['Billing details',/^Billing details/]],
 quote:[['Lines',/^Quotation lines$/],['Internal costs',/Internal buy/],['Related job',/Converted job/],['Attachments',/Attachments/],['Terms',/^Quotation terms/],['Billing details',/^Billing details/]],
 purchase:[['Lines',/Supplier invoice lines/],['Attachments',/Attachments/]]
};
function facts(page,r){
 if(page==='costsheet')return [['Customer',r.customer?.name],['Client reference / PO',r.data?.client_reference],['Route',[r.data?.pol,r.data?.pod].filter(Boolean).join(' → ')]];
 if(page==='job')return [['Customer',r.customer?.name],['Client reference / PO',r.data?.client_reference],['Activity',r.data?.activity_code],['Shipper',r.data?.shipper],['Consignee',r.data?.consignee],['Containers',r.data?.container_numbers]];
 if(page==='invoice')return [['Customer',r.snapshot?.customer?.name],['Invoice date',r.invoice_date],['Due date',r.due_date],['Date of supply',r.supply_date||r.invoice_date],['Exchange rate',r.fx_rate],['Payment terms',r.snapshot?.customer?.data?.payment_terms]];
 if(page==='quote')return [['Customer',r.customer_name],['Origin',r.data?.pol],['Destination',r.data?.pod],['Valid until',r.valid_until],['Mode',r.data?.mode],['Client reference',r.data?.client_reference]];
 return [['Supplier',r.supplier_name],['Vendor reference',r.reference],['Job',r.job_number],['Invoice date',r.invoice_date],['Due date',r.due_date],['Exchange rate',r.fx_rate]];
}
function summary(page,r,asOf){let status=r.status;if(page==='costsheet')status=r.locked_at?'Locked':r.approved?'Approved':'Open';if(page==='invoice'&&asOf)status=displayStatus(r,asOf);if(page==='quote'&&asOf&&['Draft','Approved'].includes(status)&&r.valid_until<asOf)status='Expired';const items=[['Document',r.costsheet_number||r.number],['Status',status],['Currency',r.base_currency||r.currency]];if(page==='costsheet')items.push(['Job status',r.status]);if(page==='invoice')items.push(['Total',money(r.total)],['Paid',money(r.paid)]);if(page==='purchase')items.push(['Net',money(r.net)],['VAT',money(r.vat)]);return items.filter(([,v])=>v!==undefined&&v!==null&&v!=='').map(([k,v])=>`<span class="record-chip"><span>${h(k)}</span><strong>${h(v)}</strong></span>`).join('');}
export function rememberRecordView(root){const items=root.matches?.('[data-record-key]')?root:root.querySelector('[data-record-key]');if(!items)return;const panel=items.querySelector('[role=tabpanel]:not([hidden])');if(panel)positions.set(items.dataset.recordKey+'/'+panel.dataset.recordPanel,{top:panel.scrollTop,tables:[...panel.querySelectorAll('.table-wrap')].map(t=>[t.scrollTop,t.scrollLeft])});}
function choose(root,key,focus=false){const buttons=[...root.querySelectorAll('[role=tab]')];if(!buttons.some(b=>b.dataset.recordTab===key))key=buttons[0]?.dataset.recordTab;for(const b of buttons){const active=b.dataset.recordTab===key;b.setAttribute('aria-selected',String(active));b.tabIndex=active?0:-1;const panel=root.querySelector('#'+b.getAttribute('aria-controls'));panel.hidden=!active;if(active){const saved=positions.get(root.dataset.recordKey+'/'+key);if(saved){panel.scrollTop=saved.top;[...panel.querySelectorAll('.table-wrap')].forEach((t,i)=>{t.scrollTop=saved.tables[i]?.[0]||0;t.scrollLeft=saved.tables[i]?.[1]||0;});}if(focus)b.focus();}}if(key)selections.set(root.dataset.recordKey,key);}

// Reparent existing sections: delegated actions, forms and record state stay intact.
export function arrangeRecord(root,{page,id,company,snapshot,asOf}){
 root.classList.add('compact-workspace');
 root.classList.remove('record-workspace');
 if(!recordPages.has(page))return;
 const r=snapshot?.row||{},heading=root.querySelector('.page-heading');if(!heading)return;
 root.classList.add('record-workspace');const key=`${company}/${page}/${id}`;
 const header=document.createElement('section');header.className='record-header';header.setAttribute('aria-label',names[page]+' header');heading.before(header);header.append(heading);
 const chips=document.createElement('div');chips.className='record-chips';chips.innerHTML=summary(page,r,asOf);header.append(chips);
 const grid=document.createElement('dl');grid.className='record-facts';grid.innerHTML=facts(page,r).map(([label,value])=>`<div><dt>${h(label)}</dt><dd>${h(Array.isArray(value)?value.join(', '):value||'—')}</dd></div>`).join('');header.append(grid);
 const route=root.querySelector(':scope > .job-route');if(route)header.append(route);
 const tabRoot=document.createElement('section');tabRoot.className='record-items';tabRoot.dataset.recordKey=key;tabRoot.setAttribute('aria-label',names[page]+' items');
 // Screen layout separates line items from the printable identity/addresses.
 // Authorized printing still builds the original full document independently.
 if(['invoice','quote'].includes(page)){
  const paper=root.querySelector(':scope > .invoice-paper'),identity=paper?[...paper.children].filter(n=>n.matches('.invoice-top,.bill-to')):[];
  if(identity.length){const details=document.createElement('section');details.className='panel';details.innerHTML='<div class="panel-heading"><h2>Billing details</h2></div>';details.append(...identity);root.append(details);}
  if(page==='quote'&&paper){const terms=[...paper.children].find(n=>n.matches('.activity-list')&&n.querySelector('h3'));if(terms){const section=document.createElement('section');section.className='panel';section.innerHTML='<div class="panel-heading"><h2>Quotation terms</h2></div>';section.append(terms);root.append(section);}}
 }
 const list=document.createElement('div');list.className='record-tabs';list.setAttribute('role','tablist');list.setAttribute('aria-label','Document sections');tabRoot.append(list);
 const buckets=new Map(),add=(label,node)=>{if(!buckets.has(label))buckets.set(label,[]);buckets.get(label).push(node);};
 for(const node of [...root.children]){
  if(node===header)continue;
  if(node.matches('.record-tracking')){add('History',node);continue;}
  if(node.matches('.action-bar')&&!node.querySelector('form')){let actions=heading.querySelector('.button-group');if(!actions){actions=document.createElement('div');actions.className='button-group';heading.append(actions);}actions.append(...node.childNodes);node.remove();continue;}
  if(node.matches('.notice')&&page==='costsheet'){const help=document.createElement('details');help.className='record-guidance';const title=document.createElement('summary');title.textContent='Workflow guidance';help.append(title,node);header.append(help);continue;}
  if(node.matches('.stats-grid,.costsheet-flow,.notice,.action-bar')){header.append(node);continue;}
  if(node.matches('.panel')){
   let title=node.querySelector('h2')?.textContent||'';
   if(node.classList.contains('invoice-paper'))title=page==='invoice'?'Invoice lines':page==='quote'?'Quotation lines':title;
   if(page==='purchase'&&title==='Totals'){node.classList.add('record-header-totals');header.append(node);continue;}
   add(groups[page].find(([,pattern])=>pattern.test(title))?.[0]||'Details',node);
  }else add('Details',node);
 }
 const ordered=[...groups[page].map(([label])=>label),'Details','History'].filter((v,i,a)=>a.indexOf(v)===i&&buckets.has(v));
 for(const [index,label]of ordered.entries()){
  const button=document.createElement('button'),panel=document.createElement('div'),suffix=`record-${page}-${index}`;button.type='button';button.id=suffix+'-tab';button.className='record-tab';button.dataset.recordTab=label;button.setAttribute('role','tab');button.setAttribute('aria-controls',suffix+'-panel');button.textContent=label;
  panel.id=suffix+'-panel';panel.className='record-tab-panel';panel.dataset.recordPanel=label;panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',button.id);panel.tabIndex=0;panel.append(...buckets.get(label));list.append(button);tabRoot.append(panel);
 }
 root.append(tabRoot);choose(tabRoot,selections.get(key));
 list.addEventListener('click',event=>{const b=event.target.closest('[role=tab]');if(b){rememberRecordView(tabRoot);choose(tabRoot,b.dataset.recordTab);}});
 list.addEventListener('keydown',event=>{const buttons=[...list.querySelectorAll('[role=tab]')],i=buttons.indexOf(event.target);if(i<0)return;let next;if(event.key==='ArrowRight')next=(i+1)%buttons.length;else if(event.key==='ArrowLeft')next=(i+buttons.length-1)%buttons.length;else if(event.key==='Home')next=0;else if(event.key==='End')next=buttons.length-1;else return;event.preventDefault();rememberRecordView(tabRoot);choose(tabRoot,buttons[next].dataset.recordTab,true);});
}
