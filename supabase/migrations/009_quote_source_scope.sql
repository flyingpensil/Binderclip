-- Preserve source financial scope when copying quotation costs into a job.
begin;
create or replace function public.bc_workflow(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);actor_id uuid:=auth.uid();company_row binderclip.companies;
 enquiry_row binderclip.enquiries;quote_row binderclip.quotations;job_row binderclip.jobs;line_row binderclip.quotation_lines;task_row binderclip.job_tasks;bill_row binderclip.supplier_bills;doc_row binderclip.job_documents;
 target uuid:=nullif(p_data->>'id','')::uuid;job_target uuid:=nullif(p_data->>'job_id','')::uuid;customer_target uuid;result uuid;v jsonb;net numeric;actual numeric;paid numeric;delta numeric;
begin
 if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then raise exception 'Invalid workflow payload';end if;
 select * into strict company_row from binderclip.companies where id=p_tenant;
 if p_action='enquiry.save' then
  if target is null then perform binderclip.require(p_tenant,'sales.enquiries.manage','C',actor_id,member_row.branch);
  else select * into strict enquiry_row from binderclip.enquiries where id=target and tenant_id=p_tenant for update;perform binderclip.require(p_tenant,'sales.enquiries.manage','U',enquiry_row.created_by,enquiry_row.branch);if enquiry_row.status<>'Pending' then raise exception 'Only pending enquiries may be edited';end if;end if;
  customer_target:=(p_data->>'customer_id')::uuid;
  if not exists(select 1 from binderclip.masters c where c.id=customer_target and c.tenant_id=p_tenant and c.kind='customers' and binderclip.allowed(p_tenant,'customers.list.manage','R',c.created_by,c.branch)) then raise exception 'Customer unavailable';end if;
  if target is null then insert into binderclip.enquiries(tenant_id,number,customer_id,subject,data,branch,created_by) values(p_tenant,coalesce(nullif(p_data->>'number',''),'ENQ-'||upper(substr(gen_random_uuid()::text,1,8))),customer_target,p_data->>'subject',coalesce(p_data->'data','{}'),member_row.branch,actor_id) returning id into result;
  else update binderclip.enquiries set customer_id=customer_target,subject=p_data->>'subject',data=coalesce(p_data->'data','{}') where id=target;result:=target;end if;
 elsif p_action='enquiry.cancel' then
  select * into strict enquiry_row from binderclip.enquiries where id=target and tenant_id=p_tenant for update;perform binderclip.require(p_tenant,'sales.enquiries.manage','U',enquiry_row.created_by,enquiry_row.branch);
  if enquiry_row.status<>'Pending' then raise exception 'Only pending enquiries can be cancelled';end if;update binderclip.enquiries set status='Cancelled' where id=target;result:=target;
 elsif p_action='quote.save' then
  if target is null then perform binderclip.require(p_tenant,'sales.quotes.manage','C',actor_id,member_row.branch);
  else select * into strict quote_row from binderclip.quotations where id=target and tenant_id=p_tenant for update;perform binderclip.require(p_tenant,'sales.quotes.manage','U',quote_row.created_by,quote_row.branch);if quote_row.status<>'Draft' then raise exception 'Only draft quotes can be edited';end if;end if;
  customer_target:=(p_data->>'customer_id')::uuid;
  if not exists(select 1 from binderclip.masters c where c.id=customer_target and c.tenant_id=p_tenant and c.kind='customers' and binderclip.allowed(p_tenant,'customers.list.manage','R',c.created_by,c.branch)) then raise exception 'Customer unavailable';end if;
  if p_data->>'currency'=company_row.currency and (p_data->>'fx_rate')::numeric<>1 then raise exception 'Base currency exchange rate must be 1';end if;
  if nullif(p_data->>'enquiry_id','') is not null then
   select * into strict enquiry_row from binderclip.enquiries where id=(p_data->>'enquiry_id')::uuid and tenant_id=p_tenant for update;
   perform binderclip.require(p_tenant,'sales.enquiries.manage','U',enquiry_row.created_by,enquiry_row.branch);
   if enquiry_row.customer_id<>customer_target or enquiry_row.status not in('Pending','Quoted') then raise exception 'Enquiry does not match the quotation';end if;
  end if;
  if target is null then insert into binderclip.quotations(tenant_id,enquiry_id,number,customer_id,valid_until,currency,fx_rate,terms,data,branch,created_by)
   values(p_tenant,nullif(p_data->>'enquiry_id','')::uuid,coalesce(nullif(p_data->>'number',''),'QUO-'||upper(substr(gen_random_uuid()::text,1,8))),customer_target,(p_data->>'valid_until')::date,p_data->>'currency',(p_data->>'fx_rate')::numeric,coalesce(p_data->>'terms',''),coalesce(p_data->'data','{}'),member_row.branch,actor_id) returning id into result;
  else
   if quote_row.enquiry_id is distinct from nullif(p_data->>'enquiry_id','')::uuid then raise exception 'The linked enquiry cannot be changed';end if;
   update binderclip.quotations set customer_id=customer_target,valid_until=(p_data->>'valid_until')::date,currency=p_data->>'currency',fx_rate=(p_data->>'fx_rate')::numeric,terms=coalesce(p_data->>'terms',''),data=coalesce(p_data->'data','{}') where id=target;result:=target;
  end if;
  if enquiry_row.id is not null then update binderclip.enquiries set status='Quoted' where id=enquiry_row.id;end if;
 elsif p_action='quote.line' then
  select * into strict quote_row from binderclip.quotations where id=target and tenant_id=p_tenant for update;perform binderclip.require(p_tenant,'sales.quotes.manage','U',quote_row.created_by,quote_row.branch);
  if quote_row.status<>'Draft' then raise exception 'Quote lines are fixed after approval';end if;
  if p_data->>'side'='BUY' and not exists(select 1 from binderclip.masters c where c.id=(p_data->>'supplier_id')::uuid and c.tenant_id=p_tenant and c.kind='suppliers' and binderclip.allowed(p_tenant,'suppliers.list.manage','R',c.created_by,c.branch)) then raise exception 'Supplier unavailable';end if;
  if nullif(p_data->>'line_id','') is not null then
   update binderclip.quotation_lines set side=p_data->>'side',service=p_data->>'service',supplier_id=case when p_data->>'side'='BUY' then nullif(p_data->>'supplier_id','')::uuid else null end,quantity=(p_data->>'quantity')::numeric,unit_rate=(p_data->>'unit_rate')::numeric,tax_rate=coalesce((p_data->>'tax_rate')::numeric,5),exemption=coalesce(p_data->>'exemption','') where id=(p_data->>'line_id')::uuid and quote_id=target and tenant_id=p_tenant returning id into result;
   if not found then raise exception 'Quote line unavailable';end if;
  else
  insert into binderclip.quotation_lines(tenant_id,quote_id,side,service,supplier_id,quantity,unit_rate,tax_rate,exemption) values(p_tenant,target,p_data->>'side',p_data->>'service',case when p_data->>'side'='BUY' then nullif(p_data->>'supplier_id','')::uuid else null end,(p_data->>'quantity')::numeric,(p_data->>'unit_rate')::numeric,coalesce((p_data->>'tax_rate')::numeric,5),coalesce(p_data->>'exemption','')) returning id into result;
  end if;
 elsif p_action in('quote.approve','quote.cancel','quote.convert') then
  select * into strict quote_row from binderclip.quotations where id=target and tenant_id=p_tenant for update;
  if p_action='quote.approve' then
   perform binderclip.require(p_tenant,'sales.quotes.approve','U',quote_row.created_by,quote_row.branch);
   if quote_row.status<>'Draft' or quote_row.valid_until<current_date or coalesce(trim(quote_row.data->>'pol'),'')='' or coalesce(trim(quote_row.data->>'pod'),'')='' or not exists(select 1 from binderclip.quotation_lines where quote_id=target and side='SELL') then raise exception 'A valid draft quote needs routing and sell charges';end if;
   update binderclip.quotations set status='Approved' where id=target;result:=target;
  elsif p_action='quote.cancel' then
   perform binderclip.require(p_tenant,'sales.quotes.manage','U',quote_row.created_by,quote_row.branch);if quote_row.status not in('Draft','Approved') then raise exception 'Converted or cancelled quotes cannot be cancelled';end if;
   update binderclip.quotations set status='Cancelled' where id=target;result:=target;
  else
   perform binderclip.require(p_tenant,'sales.quotes.convert','C',quote_row.created_by,quote_row.branch);
   perform binderclip.require(p_tenant,'costs.detail.manage','R',quote_row.created_by,quote_row.branch);
   if quote_row.status<>'Approved' or quote_row.valid_until<current_date then raise exception 'Only a valid approved quote can become a job';end if;
   v:=public.bc_command(p_tenant,'job.save',jsonb_build_object('number',p_data->>'job_number','customer_id',quote_row.customer_id,'data',quote_row.data));result:=(v->>'id')::uuid;
   for line_row in select * from binderclip.quotation_lines where quote_id=target loop
    perform public.bc_command(p_tenant,'cost.add',to_jsonb(line_row)||jsonb_build_object('job_id',result,'currency',quote_row.currency,'fx_rate',quote_row.fx_rate));
   end loop;
   update binderclip.quotations set status='Converted',job_id=result where id=target;
   if quote_row.enquiry_id is not null then update binderclip.enquiries set status='Confirmed' where id=quote_row.enquiry_id;end if;
  end if;
 elsif p_action in('event.add','task.add','task.complete','document.register','document.require') then
  if p_action='task.complete' then select * into strict task_row from binderclip.job_tasks where id=target and tenant_id=p_tenant;job_target:=task_row.job_id;end if;
  select * into strict job_row from binderclip.jobs where id=job_target and tenant_id=p_tenant for update;
  perform binderclip.require(p_tenant,'jobs.list.manage','R',job_row.created_by,job_row.branch);
  if p_action='event.add' then
   perform binderclip.require(p_tenant,'operations.timeline.manage','C',job_row.created_by,job_row.branch);
   insert into binderclip.job_events(tenant_id,job_id,kind,title,detail,location,occurred_at,branch,created_by) values(p_tenant,job_target,p_data->>'kind',p_data->>'title',coalesce(p_data->>'detail',''),coalesce(p_data->>'location',''),coalesce(nullif(p_data->>'occurred_at','')::timestamptz,now()),job_row.branch,actor_id) returning id into result;
  elsif p_action='task.add' then
   perform binderclip.require(p_tenant,'operations.tasks.manage','C',job_row.created_by,job_row.branch);
   if job_row.status in('Closed','Cancelled') then raise exception 'Cannot add tasks to an archived job';end if;
   if nullif(p_data->>'assignee_id','') is not null and not exists(select 1 from binderclip.members z where z.id=(p_data->>'assignee_id')::uuid and z.tenant_id=p_tenant and z.enabled and (z.branch=job_row.branch or binderclip.allowed(p_tenant,'settings.members.manage','R'))) then raise exception 'Assignee unavailable';end if;
   insert into binderclip.job_tasks(tenant_id,job_id,title,due_on,assignee_id,required_before,branch,created_by) values(p_tenant,job_target,p_data->>'title',(p_data->>'due_on')::date,nullif(p_data->>'assignee_id','')::uuid,nullif(p_data->>'required_before',''),job_row.branch,actor_id) returning id into result;
  elsif p_action='task.complete' then
   perform binderclip.require(p_tenant,'operations.tasks.manage','U',job_row.created_by,job_row.branch);
   if task_row.completed_at is not null then raise exception 'Task already completed';end if;
   update binderclip.job_tasks set completed_at=now(),completed_by=actor_id where id=target;result:=target;
  elsif p_action='document.require' then
   perform binderclip.require(p_tenant,'operations.requirements.manage','C',job_row.created_by,job_row.branch);
   if job_row.status in('Closed','Cancelled') then raise exception 'Cannot add requirements to an archived job';end if;
   insert into binderclip.document_requirements(tenant_id,job_id,kind,required_before,branch,created_by) values(p_tenant,job_target,p_data->>'kind',p_data->>'required_before',job_row.branch,actor_id) returning id into result;
  else
   perform binderclip.require(p_tenant,'operations.documents.manage','C',job_row.created_by,job_row.branch);result:=gen_random_uuid();
   insert into binderclip.job_documents(id,tenant_id,job_id,kind,filename,mime,bytes,object_path,branch,created_by) values(result,p_tenant,job_target,p_data->>'kind',p_data->>'filename',p_data->>'mime',(p_data->>'bytes')::bigint,p_tenant||'/'||job_target||'/'||result,job_row.branch,actor_id);
  end if;
 elsif p_action='supplier.pay' then
  select * into strict bill_row from binderclip.supplier_bills where id=target and tenant_id=p_tenant for update;
  perform binderclip.require(p_tenant,'finance.payments.manage','C',bill_row.created_by,bill_row.branch);
  if bill_row.status<>'Matched' then raise exception 'Match the supplier bill before payment';end if;
  select coalesce(sum(amount),0) into paid from binderclip.supplier_payments where bill_id=target;
  net:=round(bill_row.quantity*bill_row.unit_rate,2);actual:=(p_data->>'amount')::numeric;
  if actual<=0 or actual>net-paid or (p_data->>'paid_on')::date<bill_row.invoice_date or (p_data->>'paid_on')::date>current_date then raise exception 'Payment must be positive, dated within the bill period and within its unpaid balance';end if;
  insert into binderclip.supplier_payments(tenant_id,bill_id,reference,amount,paid_on,branch,created_by) values(p_tenant,target,p_data->>'reference',actual,(p_data->>'paid_on')::date,bill_row.branch,actor_id) returning id into result;
  delta:=round((paid+actual)/net*binderclip.base(bill_row.quantity,bill_row.unit_rate,bill_row.fx_rate),2)-round(paid/net*binderclip.base(bill_row.quantity,bill_row.unit_rate,bill_row.fx_rate),2);
  perform binderclip.post(p_tenant,'supplier-payment:'||result,'Supplier payment '||(p_data->>'reference'),bill_row.branch,jsonb_build_array(jsonb_build_array('2100 Payables',delta,0),jsonb_build_array('1000 Bank',0,delta)));
 else raise exception 'Unknown workflow process';end if;
 perform binderclip.log(p_tenant,p_action,coalesce(job_target,result),coalesce(p_data->>'title',p_data->>'reference',''));
 return jsonb_build_object('id',result);
end $$;

create or replace function public.bc_costsheet(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);job_row binderclip.jobs;cost_row binderclip.cost_lines;quote_row binderclip.quotations;quote_line binderclip.quotation_lines;
 company_row binderclip.companies;result jsonb;target uuid:=nullif(p_data->>'job_id','')::uuid;line_target uuid:=nullif(p_data->>'line_id','')::uuid;supplier_target uuid;reason text;side_value text;invoice_id uuid;
begin
 if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then raise exception 'Invalid cost sheet payload';end if;
 if p_action='list' then
  select coalesce(jsonb_agg(v),'[]') into result from(select jsonb_build_object('id',j.id,'number',j.number,'customer_name',c.name,'status',j.status,'sheet_status',case when j.locked_at is not null then 'Locked' when j.approved then 'Approved' else 'Open' end,'created_at',j.created_at,'data',j.data,'figures',binderclip.figures(p_tenant,j.id)) v
   from binderclip.jobs j join binderclip.masters c on c.id=j.customer_id
   where j.tenant_id=p_tenant and binderclip.allowed(p_tenant,'jobs.list.manage','R',j.created_by,j.branch) and binderclip.allowed(p_tenant,'costs.detail.manage','R',j.created_by,j.branch)
   and concat_ws(' ',j.number,c.name,j.data::text) ilike '%'||coalesce(p_data->>'q','')||'%' order by j.created_at desc limit 500)s;
  return binderclip.decimals(result);
 end if;
 select * into strict job_row from binderclip.jobs where id=target and tenant_id=p_tenant for update;
 perform binderclip.require(p_tenant,'jobs.list.manage','R',job_row.created_by,job_row.branch);
 perform binderclip.require(p_tenant,'costs.detail.manage','R',job_row.created_by,job_row.branch);
 select * into strict company_row from binderclip.companies where id=p_tenant;
 if p_action in('detail','print') then
  if p_action='print' then perform binderclip.require(p_tenant,'costs.detail.print','X',job_row.created_by,job_row.branch);end if;
  result:=public.bc_read(p_tenant,'job',target)||jsonb_build_object('company_name',company_row.name,'base_currency',company_row.currency,
   'has_invoices',exists(select 1 from binderclip.invoice_items x where x.job_id=target),
   'unbilled_charges',(select count(*) from binderclip.cost_lines l where l.job_id=target and l.side='SELL' and not exists(select 1 from binderclip.invoice_items x where x.line_id=l.id)),
   'matched_bills',(select count(*) from binderclip.supplier_bills b where b.job_id=target and b.status='Matched'),
   'buy_lines',(select count(*) from binderclip.cost_lines where job_id=target and side='BUY'),
   'changes',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('by_user',(select m.display_name from binderclip.members m where m.tenant_id=p_tenant and m.user_id=c.actor)) order by c.created_at desc),'[]') from binderclip.costsheet_changes c where c.job_id=target),
   'line_values',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'estimated_base',binderclip.base(l.quantity,l.unit_rate,l.fx_rate),'actual_base',case when b.status='Matched' then binderclip.base(b.quantity,b.unit_rate,b.fx_rate) else binderclip.base(l.quantity,l.unit_rate,l.fx_rate) end)),'[]') from binderclip.cost_lines l left join binderclip.supplier_bills b on b.line_id=l.id where l.job_id=target));
 elsif p_action='quotes' then
  perform binderclip.require(p_tenant,'costs.detail.apply','C',job_row.created_by,job_row.branch);
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.number||' · '||q.currency||' · valid until '||q.valid_until)),'[]') into result from binderclip.quotations q where q.tenant_id=p_tenant and q.customer_id=job_row.customer_id and q.status='Approved' and q.valid_until>=current_date and binderclip.allowed(p_tenant,'sales.quotes.manage','R',q.created_by,q.branch) and binderclip.allowed(p_tenant,'costs.detail.manage','R',q.created_by,q.branch);
 elsif p_action in('line.save','disapprove','apply','invoice') then
  if job_row.locked_at is not null or job_row.status in('Closed','Cancelled') then raise exception 'Locked or archived cost sheets cannot be changed';end if;
  if p_action='invoice' then
   if coalesce((p_data->>'invoice_date')::date,current_date)>current_date or (p_data->>'due_date')::date<coalesce((p_data->>'invoice_date')::date,current_date) then raise exception 'Invoice date cannot be future-dated and due date cannot precede it';end if;
   result:=public.bc_command(p_tenant,'invoice.generate',jsonb_build_object('job_ids',jsonb_build_array(target)));invoice_id:=(result->>'id')::uuid;
   update binderclip.invoices set invoice_date=coalesce((p_data->>'invoice_date')::date,current_date),due_date=coalesce((p_data->>'due_date')::date,due_date) where id=invoice_id;
  else
   if exists(select 1 from binderclip.invoice_items x where x.job_id=target) then raise exception 'Cost sheets with generated customer invoices cannot be changed in this release';end if;
   if p_action='disapprove' then
    perform binderclip.require(p_tenant,'costs.detail.disapprove','U',job_row.created_by,job_row.branch);
    reason:=trim(p_data->>'reason');if not job_row.approved or coalesce(reason,'')='' then raise exception 'An approved cost sheet and a reason are required';end if;
    update binderclip.jobs set approved=false where id=target;result:=jsonb_build_object('id',target);
   elsif p_action='apply' then
    perform binderclip.require(p_tenant,'costs.detail.apply','C',job_row.created_by,job_row.branch);
    if job_row.status<>'Draft' or job_row.approved or exists(select 1 from binderclip.cost_lines where job_id=target) then raise exception 'Apply a quotation only to an empty draft cost sheet to prevent duplicate charges';end if;
    select * into strict quote_row from binderclip.quotations where id=(p_data->>'quote_id')::uuid and tenant_id=p_tenant for share;
    perform binderclip.require(p_tenant,'sales.quotes.manage','R',quote_row.created_by,quote_row.branch);
    perform binderclip.require(p_tenant,'costs.detail.manage','R',quote_row.created_by,quote_row.branch);
    if quote_row.customer_id<>job_row.customer_id or quote_row.status<>'Approved' or quote_row.valid_until<current_date then raise exception 'Choose a valid approved quotation for this customer';end if;
    if not exists(select 1 from binderclip.quotation_lines where quote_id=quote_row.id) then raise exception 'Quotation has no charges';end if;
    for quote_line in select * from binderclip.quotation_lines where quote_id=quote_row.id loop
     perform public.bc_command(p_tenant,'cost.add',to_jsonb(quote_line)||jsonb_build_object('job_id',target,'currency',quote_row.currency,'fx_rate',quote_row.fx_rate));
    end loop;
    reason:='Applied quotation '||quote_row.number;result:=jsonb_build_object('id',target);
   else
    if job_row.approved then raise exception 'Disapprove the cost sheet before changing charges';end if;
    if coalesce(length(trim(p_data->>'service')),0) not between 1 and 240 then raise exception 'A service name is required';end if;
    if line_target is null then
     perform binderclip.require(p_tenant,'costs.detail.manage','C',job_row.created_by,job_row.branch);side_value:=p_data->>'side';
    else
     select * into strict cost_row from binderclip.cost_lines where id=line_target and job_id=target and tenant_id=p_tenant for update;
     perform binderclip.require(p_tenant,'costs.detail.manage','U',job_row.created_by,job_row.branch);side_value:=cost_row.side;
     if cost_row.accrued or exists(select 1 from binderclip.supplier_bills where line_id=line_target) then raise exception 'Booked buy estimates and matched bills cannot be rewritten';end if;
     reason:=trim(p_data->>'reason');if coalesce(reason,'')='' then raise exception 'A reason is required when correcting a charge';end if;
    end if;
    if job_row.status<>'Draft' and side_value<>'SELL' then raise exception 'Only unbilled customer charges can be added or corrected after booking';end if;
    supplier_target:=case when side_value='BUY' then nullif(p_data->>'supplier_id','')::uuid else null end;
    if side_value='BUY' and not exists(select 1 from binderclip.masters s where s.id=supplier_target and s.tenant_id=p_tenant and s.kind='suppliers' and binderclip.allowed(p_tenant,'suppliers.list.manage','R',s.created_by,s.branch)) then raise exception 'Supplier unavailable';end if;
    if p_data->>'currency'=company_row.currency and (p_data->>'fx_rate')::numeric<>1 then raise exception 'Base currency exchange rate must be 1';end if;
    if line_target is null then
     insert into binderclip.cost_lines(tenant_id,job_id,side,service,supplier_id,quantity,unit_rate,currency,fx_rate,tax_rate,exemption,branch,created_by) values(p_tenant,target,side_value,p_data->>'service',supplier_target,(p_data->>'quantity')::numeric,(p_data->>'unit_rate')::numeric,p_data->>'currency',(p_data->>'fx_rate')::numeric,(p_data->>'tax_rate')::numeric,coalesce(p_data->>'exemption',''),job_row.branch,auth.uid()) returning id into line_target;
    else
     update binderclip.cost_lines set service=p_data->>'service',supplier_id=supplier_target,quantity=(p_data->>'quantity')::numeric,unit_rate=(p_data->>'unit_rate')::numeric,currency=p_data->>'currency',fx_rate=(p_data->>'fx_rate')::numeric,tax_rate=(p_data->>'tax_rate')::numeric,exemption=coalesce(p_data->>'exemption','') where id=line_target;
    end if;result:=jsonb_build_object('id',line_target);
   end if;
  end if;
  insert into binderclip.costsheet_changes(tenant_id,job_id,action,reason,before_values,after_values,actor)
   values(p_tenant,target,p_action,coalesce(reason,''),case when cost_row.id is not null then to_jsonb(cost_row) else jsonb_build_object('approved',job_row.approved) end,
   case when line_target is not null then (select to_jsonb(c) from binderclip.cost_lines c where c.id=line_target) else jsonb_build_object('invoice_id',invoice_id,'quote_id',p_data->>'quote_id') end,auth.uid());
  -- General job readers see the action, while correction reasons stay in scoped financial history.
  perform binderclip.log(p_tenant,'costsheet.'||p_action,target,'');
 else raise exception 'Unknown cost sheet action';end if;
 return binderclip.decimals(result);
end $$;

commit;
