import {escapeHTML as h,scaled} from './domain.js';

export function createBillingUI(ctx){
 const {state,rpc,can,heading,panel,table,link,button,badge,edit,message,today}=ctx;
 const billing=(kind,data={})=>rpc('bc_billing',{p_tenant:state.member.tenant_id,p_kind:kind,p_data:data});
 function nextStep(j){
  if(Number(j.charge_count)>0&&Number(j.unbilled_count)===0)return 'Already invoiced';
  if(!Number(j.buy_count))return 'Add supplier costs';
  if(!Number(j.charge_count))return 'Add customer charges';
  if(j.status==='Draft')return 'Book the job';
  if(Number(j.matched_count)<Number(j.buy_count))return 'Match / approve supplier bills';
  if(!j.approved)return 'Approve the cost sheet';
  if(Number(j.billing_groups)!==1)return 'Use one sell currency and FX rate';
  if(j.locked_at)return 'Cost sheet is locked';
  return 'Ready to invoice';
 }
 async function queue(){const rows=await billing('invoice_queue');state.invoiceQueue=rows;const ready=rows.filter(j=>nextStep(j)==='Ready to invoice'),pending=rows.filter(j=>!['Ready to invoice','Already invoiced'].includes(nextStep(j)));
  return {action:button('＋ Create invoice','billing-start',{},true),html:panel('Create a customer invoice',`<div class="invoice-create-help"><p>Invoices come from approved job cost sheets. Use <strong>Create invoice</strong> for one job, or select ready jobs below to consolidate them. Draft invoices must then be approved and issued.</p>${!ready.length?'<p>No jobs are ready yet. Follow the next-step list below; a ready job will appear here after cost-sheet approval.</p>':''}</div>`+
   (ready.length?`<form id="billing-consolidate-form"><div class="selection-list">${ready.map(j=>`<label><input type="checkbox" name="job_ids" value="${h(j.id)}"><strong>${h(j.number)}</strong><span>${h(j.customer_name)} · ${h(j.currency)}</span><a href="#costsheet/${h(j.id)}">Cost sheet ↗</a></label>`).join('')}</div><div class="action-bar"><button class="button primary" type="submit" disabled>Generate consolidated invoice</button><small>Select at least one ready job. Consolidation requires the same customer, currency and FX rate.</small></div></form>`:''))+
   (pending.length?panel('Jobs that need another step',table(['Job','Customer','Next step','Open'],pending.map(j=>[h(j.number),h(j.customer_name),h(nextStep(j)),can('costs.detail.manage')?link('Open cost sheet →',`costsheet/${j.id}`):link('Open job →',`job/${j.id}`)]))):'')};
 }
 async function create(ids=null){const rows=state.invoiceQueue||[],ready=rows.filter(j=>nextStep(j)==='Ready to invoice');
  if(!ready.length){message('No jobs are ready to invoice yet. See “Jobs that need another step” below, or open Cost sheets to finish the job.');return;}
  if(ids&&(!ids.length||new Set(ids).size!==ids.length))throw new Error('Select at least one ready job.');
  const selected=ids?ids.map(id=>ready.find(j=>j.id===id)):null;
  if(selected?.some(j=>!j))throw new Error('A selected job is no longer ready. Refresh the invoice list.');
  if(selected&&(new Set(selected.map(j=>j.customer_id)).size!==1||new Set(selected.map(j=>`${j.currency}:${scaled(j.fx_rate,8)}`)).size!==1))throw new Error('Choose jobs for one customer, currency and exchange rate.');
  const first=selected?.[0]||ready[0],due=new Date(today()+'T00:00:00Z');due.setUTCDate(due.getUTCDate()+Number(first.credit_days??30));
  const fields=[...(!ids?[{key:'job_id',label:'Ready job / cost sheet',type:'select',required:true,options:ready.map(j=>({id:j.id,name:`${j.number} · ${j.customer_name} · ${j.currency}`}))}]:[]),{key:'invoice_date',label:'Invoice date',type:'date',required:true,max:today()},{key:'due_date',label:'Payment due date',type:'date',required:true}];
  const updateDue=form=>{const row=ready.find(j=>j.id===form.elements.job_id?.value);if(row&&form.elements.invoice_date.value){const date=new Date(form.elements.invoice_date.value+'T00:00:00Z');date.setUTCDate(date.getUTCDate()+Number(row.credit_days??30));form.elements.due_date.value=date.toISOString().slice(0,10);}};
  edit(ids?'Create consolidated customer invoice':'Create customer invoice',fields,{job_id:first.id,invoice_date:today(),due_date:due.toISOString().slice(0,10)},async values=>{
   const result=await billing('invoice.create',{job_ids:ids||[values.job_id],invoice_date:values.invoice_date,due_date:values.due_date});location.hash=`invoice/${result.id}`;
  },updateDue);
 }
 document.addEventListener('change',event=>{if(event.target.closest('#billing-consolidate-form')){const form=event.target.closest('form');form.querySelector('button[type=submit]').disabled=!form.querySelector('input[name=job_ids]:checked');}});
 document.addEventListener('submit',async event=>{if(event.target.id!=='billing-consolidate-form')return;event.preventDefault();if(state.busy)return;try{await create(new FormData(event.target).getAll('job_ids'));}catch(error){message(error.message,true);}});
 return {queue,create};
}
