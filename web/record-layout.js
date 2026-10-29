import {escapeHTML as h,money} from './domain.js';

const selections=new Map();
const recordPages=new Set(['job','costsheet','invoice','quote','purchase']);
const names={job:'Shipment',costsheet:'Cost sheet',invoice:'Customer invoice',quote:'Quotation',purchase:'Supplier invoice'};
const groups={
 job:[['Details',/Shipment details/],['Operations',/Shipment timeline|Tasks & stage|Required stage/],['Financials',/cost sheet|Customer invoices/i],['Attachments',/documents|Attachments/i],['History',/Job activity/]],
 costsheet:[['Supplier invoices',/Select supplier invoices|Supplier invoice documents/],['Supplier costs',/^Supplier costs/],['Customer charges',/^Customer charges/],['Reconciliation',/Supplier invoice review/],['Customer invoices',/Final customer invoices/],['Attachments',/Attachments/],['History',/correction history/i]],
 invoice:[['Invoice',/^Invoice preview$/],['Payments',/^Payments/],['Attachments',/Attachments/]],
 quote:[['Lines',/^Quotation lines$/],['Internal costs',/Internal buy/],['Related job',/Converted job/],['Attachments',/Attachments/]],
 purchase:[['Lines',/Supplier invoice lines/],['Attachments',/Attachments/]]
};
function facts(page,r){
 if(page==='job'||page==='costsheet')return [['Customer',r.customer?.name],['Client reference / PO',r.data?.client_reference],['Activity',r.data?.activity_code],['Shipper',r.data?.shipper],['Consignee',r.data?.consignee],['Containers',r.data?.container_numbers]];
 if(page==='invoice')return [['Customer',r.snapshot?.customer?.name],['Invoice date',r.invoice_date],['Due date',r.due_date],['Date of supply',r.supply_date||r.invoice_date],['Exchange rate',r.fx_rate],['Payment terms',r.snapshot?.customer?.data?.payment_terms]];
 if(page==='quote')return [['Customer',r.customer_name],['Origin',r.data?.pol],['Destination',r.data?.pod],['Valid until',r.valid_until],['Mode',r.data?.mode],['Client reference',r.data?.client_reference]];
 return [['Supplier',r.supplier_name],['Vendor reference',r.reference],['Job',r.job_number],['Invoice date',r.invoice_date],['Due date',r.due_date],['Exchange rate',r.fx_rate]];
}
function summary(page,r){const items=[['Document',r.costsheet_number||r.number],['Status',r.locked_at?'Locked':r.approved?'Approved':r.status],['Currency',r.base_currency||r.currency]];if(page==='invoice')items.push(['Total',money(r.total)],['Paid',money(r.paid)]);if(page==='purchase')items.push(['Net',money(r.net)],['VAT',money(r.vat)]);return items.filter(([,v])=>v!==undefined&&v!==null&&v!=='').map(([k,v])=>`<span class="record-chip"><span>${h(k)}</span><strong>${h(v)}</strong></span>`).join('');}
function choose(root,key,focus=false){const buttons=[...root.querySelectorAll('[role=tab]')];if(!buttons.some(b=>b.dataset.recordTab===key))key=buttons[0]?.dataset.recordTab;for(const b of buttons){const active=b.dataset.recordTab===key;b.setAttribute('aria-selected',String(active));b.tabIndex=active?0:-1;root.querySelector('#'+b.getAttribute('aria-controls')).hidden=!active;if(active&&focus)b.focus();}if(key)selections.set(root.dataset.recordKey,key);}

// Reparent existing sections: delegated actions, forms and record state stay intact.
export function arrangeRecord(root,{page,id,company,snapshot}){
 root.classList.add('compact-workspace');
 if(!recordPages.has(page))return;
 const r=snapshot?.row||{},heading=root.querySelector('.page-heading');if(!heading)return;
 root.classList.add('record-workspace');const key=`${company}/${page}/${id}`;
 const header=document.createElement('section');header.className='record-header';header.setAttribute('aria-label',names[page]+' header');heading.before(header);header.append(heading);
 const chips=document.createElement('div');chips.className='record-chips';chips.innerHTML=summary(page,r);header.append(chips);
 const grid=document.createElement('dl');grid.className='record-facts';grid.innerHTML=facts(page,r).map(([label,value])=>`<div><dt>${h(label)}</dt><dd>${h(Array.isArray(value)?value.join(', '):value||'—')}</dd></div>`).join('');header.append(grid);
 const route=root.querySelector(':scope > .job-route');if(route)header.append(route);
 const tabRoot=document.createElement('section');tabRoot.className='record-items';tabRoot.dataset.recordKey=key;tabRoot.setAttribute('aria-label',names[page]+' items');
 const list=document.createElement('div');list.className='record-tabs';list.setAttribute('role','tablist');list.setAttribute('aria-label','Document sections');tabRoot.append(list);
 const buckets=new Map(),add=(label,node)=>{if(!buckets.has(label))buckets.set(label,[]);buckets.get(label).push(node);};
 for(const node of [...root.children]){
  if(node===header)continue;
  if(node.matches('.record-tracking')){add('History',node);continue;}
  if(node.matches('.stats-grid,.costsheet-flow,.notice,.action-bar')){header.append(node);continue;}
  if(node.matches('.panel')){
   let title=node.querySelector('h2')?.textContent||'';
   if(node.classList.contains('invoice-paper'))title=page==='invoice'?'Invoice preview':page==='quote'?'Quotation lines':title;
   if(page==='purchase'&&title==='Totals'){node.classList.add('record-header-totals');header.append(node);continue;}
   add(groups[page].find(([,pattern])=>pattern.test(title))?.[0]||'Details',node);
  }else add('Details',node);
 }
 const ordered=[...groups[page].map(([label])=>label),'Details','History'].filter((v,i,a)=>a.indexOf(v)===i&&buckets.has(v));
 for(const [index,label]of ordered.entries()){
  const button=document.createElement('button'),panel=document.createElement('div'),suffix=`record-${page}-${index}`;button.type='button';button.id=suffix+'-tab';button.className='record-tab';button.dataset.recordTab=label;button.setAttribute('role','tab');button.setAttribute('aria-controls',suffix+'-panel');button.textContent=label;
  panel.id=suffix+'-panel';panel.className='record-tab-panel';panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',button.id);panel.tabIndex=0;panel.append(...buckets.get(label));list.append(button);tabRoot.append(panel);
 }
 root.append(tabRoot);choose(tabRoot,selections.get(key));
 list.addEventListener('click',event=>{const b=event.target.closest('[role=tab]');if(b)choose(tabRoot,b.dataset.recordTab);});
 list.addEventListener('keydown',event=>{const buttons=[...list.querySelectorAll('[role=tab]')],i=buttons.indexOf(event.target);if(i<0)return;let next;if(event.key==='ArrowRight')next=(i+1)%buttons.length;else if(event.key==='ArrowLeft')next=(i+buttons.length-1)%buttons.length;else if(event.key==='Home')next=0;else if(event.key==='End')next=buttons.length-1;else return;event.preventDefault();choose(tabRoot,buttons[next].dataset.recordTab,true);});
}
