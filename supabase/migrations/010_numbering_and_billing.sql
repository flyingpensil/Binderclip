begin;
create table binderclip.number_sequences(
 tenant_id uuid not null references binderclip.companies,kind text not null,last_value bigint not null check(last_value>0),primary key(tenant_id,kind));
alter table binderclip.number_sequences enable row level security;
revoke all on binderclip.number_sequences from public,anon,authenticated;
alter table binderclip.jobs add column costsheet_number text;
alter table binderclip.supplier_bills add column document_number text;
alter table binderclip.receipts add column document_number text;
alter table binderclip.supplier_payments add column document_number text;
alter table binderclip.job_documents add column document_number text;

create function binderclip.number_prefix(k text) returns text language sql immutable set search_path='' as $$
 select case k when 'customers' then 'CUS' when 'suppliers' then 'SUP' when 'rates' then 'RAT' when 'tariffs' then 'TAR'
 when 'jobs' then 'JOB' when 'costsheets' then 'CS' when 'invoices' then 'INV' when 'enquiries' then 'ENQ' when 'quotations' then 'QUO'
 when 'supplier_bills' then 'BIL' when 'receipts' then 'REC' when 'supplier_payments' then 'PAY' when 'job_documents' then 'DOC' end
$$;
-- Continue beyond existing system-style numbers; preserve every existing identifier.
insert into binderclip.number_sequences(tenant_id,kind,last_value)
 select tenant_id,kind,max(substring(number from '^[A-Z]+-([0-9]{1,15})$')::bigint) from(
 select tenant_id,kind,code number from binderclip.masters union all select tenant_id,'jobs',number from binderclip.jobs
 union all select tenant_id,'invoices',number from binderclip.invoices union all select tenant_id,'enquiries',number from binderclip.enquiries
 union all select tenant_id,'quotations',number from binderclip.quotations)s
 where number ~ ('^'||binderclip.number_prefix(kind)||'-[0-9]{1,15}$') and coalesce(substring(number from '^[A-Z]+-([0-9]{1,15})$'),'0')::numeric>0 group by tenant_id,kind;

create function binderclip.next_number(t uuid,k text) returns text language plpgsql security definer set search_path='' as $$
declare prefix text:=binderclip.number_prefix(k);n bigint;
begin
 if prefix is null then raise exception 'Unknown document sequence';end if;
 insert into binderclip.number_sequences as s(tenant_id,kind,last_value) values(t,k,1)
 on conflict(tenant_id,kind) do update set last_value=s.last_value+1 returning last_value into n;
 return prefix||'-'||lpad(n::text,greatest(6,length(n::text)),'0');
end $$;

create function binderclip.assign_number() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='masters' then
  if TG_OP='INSERT' then new.code:=binderclip.next_number(new.tenant_id,new.kind);else new.code:=old.code;end if;
 elsif TG_TABLE_NAME='jobs' then
  if TG_OP='INSERT' then new.number:=binderclip.next_number(new.tenant_id,'jobs');new.costsheet_number:=binderclip.next_number(new.tenant_id,'costsheets');
  else new.number:=old.number;if old.costsheet_number is not null then new.costsheet_number:=old.costsheet_number;end if;end if;
 elsif TG_TABLE_NAME in('invoices','enquiries','quotations') then
  if TG_OP='INSERT' then new.number:=binderclip.next_number(new.tenant_id,TG_TABLE_NAME);else new.number:=old.number;end if;
 else
  if TG_OP='INSERT' then new.document_number:=binderclip.next_number(new.tenant_id,TG_TABLE_NAME);else new.document_number:=old.document_number;end if;
 end if;return new;
end $$;
create trigger system_number before insert or update on binderclip.masters for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.jobs for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.invoices for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.enquiries for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.quotations for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.supplier_bills for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.receipts for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.supplier_payments for each row execute function binderclip.assign_number();
create trigger system_number before insert or update on binderclip.job_documents for each row execute function binderclip.assign_number();
do $$declare j record;begin
 for j in select id,tenant_id from binderclip.jobs where costsheet_number is null order by tenant_id,created_at,id loop
  update binderclip.jobs set costsheet_number=binderclip.next_number(j.tenant_id,'costsheets') where id=j.id;
 end loop;
end $$;
create unique index on binderclip.jobs(tenant_id,costsheet_number);
create unique index on binderclip.supplier_bills(tenant_id,document_number);
create unique index on binderclip.receipts(tenant_id,document_number);
create unique index on binderclip.supplier_payments(tenant_id,document_number);
create unique index on binderclip.job_documents(tenant_id,document_number);
revoke all on function binderclip.number_prefix(text),binderclip.next_number(uuid,text),binderclip.assign_number() from public,anon,authenticated;

create function public.bc_billing(p_tenant uuid,p_kind text default 'invoice_queue') returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);result jsonb;
begin
 if p_kind='invoice_queue' then
  select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at desc),'[]') into result from(
   select j.id,j.number,j.costsheet_number,j.customer_id,c.name customer_name,j.status,j.approved,j.locked_at,j.created_at,
   (select count(*) from binderclip.cost_lines l where l.job_id=j.id and l.side='BUY') buy_count,
   (select count(*) from binderclip.supplier_bills b where b.job_id=j.id and b.status='Matched') matched_count,
   (select count(*) from binderclip.cost_lines l where l.job_id=j.id and l.side='SELL') charge_count,
   (select count(*) from binderclip.cost_lines l where l.job_id=j.id and l.side='SELL' and not exists(select 1 from binderclip.invoice_items x where x.line_id=l.id)) unbilled_count,
   (select count(distinct (l.currency,l.fx_rate)) from binderclip.cost_lines l where l.job_id=j.id and l.side='SELL' and not exists(select 1 from binderclip.invoice_items x where x.line_id=l.id)) billing_groups,
   (select min(l.currency) from binderclip.cost_lines l where l.job_id=j.id and l.side='SELL') currency
   from binderclip.jobs j join binderclip.masters c on c.id=j.customer_id
   where j.tenant_id=p_tenant and j.status not in('Closed','Cancelled') and binderclip.allowed(p_tenant,'jobs.list.manage','R',j.created_by,j.branch)
   and binderclip.allowed(p_tenant,'invoicing.detail.generate','C',j.created_by,j.branch)
   order by j.created_at desc limit 500)s;
 elsif p_kind='supplier_payments' then
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(p)||jsonb_build_object('bill_number',b.number,'currency',b.currency,'supplier_name',c.name) v
   from binderclip.supplier_payments p join binderclip.supplier_bills b on b.id=p.bill_id join binderclip.masters c on c.id=b.supplier_id
   where p.tenant_id=p_tenant and binderclip.allowed(p_tenant,'finance.payments.manage','R',b.created_by,b.branch) order by p.created_at desc limit 500)s;
 else raise exception 'Unknown billing view';end if;
 return binderclip.decimals(result);
end $$;
revoke all on function public.bc_billing(uuid,text) from public,anon,authenticated;
grant execute on function public.bc_billing(uuid,text) to authenticated;
-- Updated command and cost-sheet definitions follow below.

create or replace function public.bc_command(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
<<cmd>>
declare m binderclip.members:=binderclip.member(p_tenant);u uuid:=auth.uid();co binderclip.companies;
 r binderclip.masters; j binderclip.jobs;l binderclip.cost_lines;b binderclip.supplier_bills;i binderclip.invoices;
 member_row binderclip.members;role_row binderclip.roles;
 target uuid:=nullif(p_data->>'id','')::uuid;kind text;path text;v jsonb;d jsonb;ids uuid[];jobid uuid;
 n integer;quantity numeric;rate numeric;fx numeric;net numeric;tax numeric;amount numeric;expected numeric;actual numeric;delta numeric;
 subtotal numeric:=0;tax_total numeric:=0;cur text;customer uuid;reason text;result uuid;
begin
 if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then raise exception 'Invalid command payload';end if;
 select * into strict co from binderclip.companies where id=p_tenant;
 if p_action='master.save' then
  kind:=p_data->>'kind';if kind not in ('customers','suppliers','rates','tariffs') then raise exception 'Invalid master type';end if;
  path:=case when kind in ('rates','tariffs') then 'masters.rates.manage' else kind||'.list.manage' end;
  if target is not null then
   select * into r from binderclip.masters where id=target and tenant_id=p_tenant and masters.kind=cmd.kind for update;
   if not found then raise exception 'Record unavailable';end if;
   perform binderclip.require(p_tenant,path,'U',r.created_by,r.branch);
  else perform binderclip.require(p_tenant,path,'C',u,m.branch);end if;
  if coalesce(length(trim(p_data->>'name')),0)<1 then raise exception 'Name is required';end if;
  cur:=coalesce(nullif(p_data->>'currency',''),co.currency);
  jobid:=nullif(p_data->>'parent_id','')::uuid;
  if jobid is not null and not exists(select 1 from binderclip.masters z where z.id=jobid and z.tenant_id=p_tenant and z.kind='rates' and binderclip.allowed(p_tenant,'masters.rates.manage','R',z.created_by,z.branch)) then raise exception 'Rate card unavailable';end if;
  d:=coalesce(p_data->'data','{}');
  if jsonb_typeof(d)<>'object' then raise exception 'Master details must be an object';end if;
  if coalesce((d->>'credit_days')::integer,0)<0 or coalesce((d->>'credit_limit')::numeric,0)<0 or coalesce((d->>'buy_rate')::numeric,0)<0 or coalesce((d->>'sell_rate')::numeric,0)<0 then raise exception 'Credit and tariff values cannot be negative';end if;
  if kind='rates' and nullif(d->>'valid_until','')::date<nullif(d->>'valid_from','')::date then raise exception 'Invalid rate-card validity';end if;
  if target is null then
   insert into binderclip.masters(tenant_id,kind,code,name,currency,parent_id,data,branch,created_by) values(p_tenant,kind,trim(p_data->>'code'),trim(p_data->>'name'),cur,jobid,d,m.branch,u) returning id into result;
  else update binderclip.masters set code=trim(p_data->>'code'),name=trim(p_data->>'name'),currency=cur,parent_id=jobid,data=d where id=target;result:=target;end if;
 elsif p_action='job.save' then
  if target is not null then
   j:=binderclip.job_guard(p_tenant,target,'jobs.list.manage');if j.status<>'Draft' then raise exception 'Job details can only be edited in Draft';end if;
  else perform binderclip.require(p_tenant,'jobs.list.manage','C',u,m.branch);end if;
  customer:=(p_data->>'customer_id')::uuid;
  select * into r from binderclip.masters where id=customer and tenant_id=p_tenant and masters.kind='customers';
  if not found or not binderclip.allowed(p_tenant,'customers.list.manage','R',r.created_by,r.branch) then raise exception 'Customer unavailable';end if;
  d:=coalesce(p_data->'data','{}');
  if coalesce(trim(d->>'pol'),'')='' or coalesce(trim(d->>'pod'),'')='' then raise exception 'Routing is required';end if;
  if coalesce(d->>'mode','Ocean') not in ('Ocean','Air','Road','Multimodal') then raise exception 'Invalid mode';end if;
  foreach path in array array['gross_weight','chargeable_weight','volume','packages'] loop
   if coalesce(nullif(d->>path,'')::numeric,0)<0 then raise exception 'Cargo measures cannot be negative';end if;
  end loop;
  if target is null then insert into binderclip.jobs(tenant_id,number,customer_id,data,branch,created_by) values(p_tenant,trim(p_data->>'number'),customer,d,m.branch,u) returning id into result;
  else update binderclip.jobs set number=trim(p_data->>'number'),customer_id=customer,data=d where id=target;result:=target;end if;
 elsif p_action='cost.add' then
  j:=binderclip.job_guard(p_tenant,(p_data->>'job_id')::uuid,'costs.detail.manage','C');
  if j.status<>'Draft' then raise exception 'Estimates are fixed after booking';end if;
  jobid:=nullif(p_data->>'supplier_id','')::uuid;
  if jobid is not null and not exists(select 1 from binderclip.masters z where z.id=jobid and z.tenant_id=p_tenant and z.kind='suppliers' and binderclip.allowed(p_tenant,'suppliers.list.manage','R',z.created_by,z.branch)) then raise exception 'Supplier unavailable';end if;
  target:=nullif(p_data->>'tariff_id','')::uuid;
  if target is not null and not exists(select 1 from binderclip.masters z where z.id=target and z.tenant_id=p_tenant and z.kind='tariffs' and binderclip.allowed(p_tenant,'masters.rates.manage','R',z.created_by,z.branch)) then raise exception 'Tariff unavailable';end if;
  cur:=coalesce(p_data->>'currency',co.currency);fx:=coalesce((p_data->>'fx_rate')::numeric,1);
  if cur=co.currency and fx<>1 then raise exception 'Base currency exchange rate must be 1';end if;
  insert into binderclip.cost_lines(tenant_id,job_id,side,service,supplier_id,tariff_id,quantity,unit_rate,currency,fx_rate,tax_rate,exemption,branch,created_by)
  values(p_tenant,j.id,p_data->>'side',p_data->>'service',jobid,target,(p_data->>'quantity')::numeric,(p_data->>'unit_rate')::numeric,cur,fx,coalesce((p_data->>'tax_rate')::numeric,5),coalesce(p_data->>'exemption',''),j.branch,u) returning id into result;
  update binderclip.jobs set approved=false where id=j.id;
 elsif p_action='job.book' then
  j:=binderclip.job_guard(p_tenant,target,'costs.detail.book');
  if j.status<>'Draft' then raise exception 'Only Draft jobs can be booked';end if;
  if not exists(select 1 from binderclip.cost_lines where job_id=j.id and side='BUY') or not exists(select 1 from binderclip.cost_lines where job_id=j.id and side='SELL') then raise exception 'Add buy and sell estimates first';end if;
  for l in select * from binderclip.cost_lines where job_id=j.id and tenant_id=p_tenant and side='BUY' loop
   amount:=binderclip.base(l.quantity,l.unit_rate,l.fx_rate);
   perform binderclip.post(p_tenant,'accrual:'||l.id,'Booking accrual '||l.service,j.branch,jsonb_build_array(jsonb_build_array('5000 Direct costs',amount,0),jsonb_build_array('2000 Accrued costs',0,amount)));
   update binderclip.cost_lines set accrued=true where id=l.id;
  end loop;
  update binderclip.jobs set status='Booked' where id=j.id;result:=j.id;
 elsif p_action='bill.match' then
  j:=binderclip.job_guard(p_tenant,(p_data->>'job_id')::uuid,'costs.detail.match','C');
  select * into l from binderclip.cost_lines where id=(p_data->>'line_id')::uuid and tenant_id=p_tenant and job_id=j.id and side='BUY' and accrued for update;
  if not found then raise exception 'Select a booked buy estimate from this job';end if;
  quantity:=(p_data->>'quantity')::numeric;rate:=(p_data->>'unit_rate')::numeric;fx:=(p_data->>'fx_rate')::numeric;
  if coalesce(p_data->>'currency',l.currency)<>l.currency or (p_data->>'supplier_id')::uuid<>l.supplier_id then raise exception 'Supplier and currency must match the estimate';end if;
  if l.currency=co.currency and fx<>1 then raise exception 'Base currency exchange rate must be 1';end if;
  expected:=binderclip.base(l.quantity,l.unit_rate,l.fx_rate);actual:=binderclip.base(quantity,rate,fx);delta:=actual-expected;
  insert into binderclip.supplier_bills(tenant_id,job_id,line_id,supplier_id,number,invoice_date,due_date,quantity,unit_rate,currency,fx_rate,variance,branch,created_by)
  values(p_tenant,j.id,l.id,l.supplier_id,p_data->>'number',(p_data->>'invoice_date')::date,(p_data->>'due_date')::date,quantity,rate,l.currency,fx,delta,j.branch,u) returning id into result;
  if greatest(abs(quantity-l.quantity)/l.quantity,case when l.unit_rate=0 then case when rate=0 then 0 else 1 end else abs(rate-l.unit_rate)/l.unit_rate end,
    case when expected=0 then case when actual=0 then 0 else 1 end else abs(delta)/expected end)<=co.tolerance/100 then perform binderclip.match_post(p_tenant,result);end if;
  update binderclip.jobs set approved=false where id=j.id;
 elsif p_action='bill.approve' then
  select * into b from binderclip.supplier_bills where id=target and tenant_id=p_tenant;
  if not found then raise exception 'Supplier bill unavailable';end if;
  j:=binderclip.job_guard(p_tenant,b.job_id,'costs.detail.variance');
  select * into b from binderclip.supplier_bills where id=target for update;
  if b.status<>'Pending' then raise exception 'Bill already matched';end if;
  reason:=trim(p_data->>'reason');if coalesce(reason,'')='' then raise exception 'Approval reason required';end if;
  update binderclip.supplier_bills set approval_reason=reason,approved_by=u where id=target;
  perform binderclip.match_post(p_tenant,target);result:=target;
 elsif p_action='cost.approve' then
  j:=binderclip.job_guard(p_tenant,target,'costs.detail.approve');
  if j.status='Draft' or not exists(select 1 from binderclip.cost_lines where job_id=j.id and side='SELL') or exists(select 1 from binderclip.cost_lines cl left join binderclip.supplier_bills sb on sb.line_id=cl.id where cl.job_id=j.id and cl.side='BUY' and (sb.id is null or sb.status<>'Matched')) then raise exception 'Book the job and match every buy estimate before approval';end if;
  update binderclip.jobs set approved=true where id=j.id;result:=j.id;
 elsif p_action='invoice.generate' then
  select array_agg(value::uuid order by value) into ids from jsonb_array_elements_text(p_data->'job_ids');
  if coalesce(cardinality(ids),0)=0 or cardinality(ids)<>(select count(distinct x) from unnest(ids)x) then raise exception 'Select unique jobs to invoice';end if;
  n:=0;
  for j in select * from binderclip.jobs where id=any(ids) and tenant_id=p_tenant order by id for update loop
   n:=n+1;perform binderclip.require(p_tenant,'invoicing.detail.generate','C',j.created_by,j.branch);
   if not j.approved or j.status in ('Draft','Cancelled') then raise exception 'Approve every selected cost sheet';end if;
   if customer is null then customer:=j.customer_id;elsif customer<>j.customer_id then raise exception 'Consolidation requires one customer';end if;
  end loop;
  if n<>cardinality(ids) then raise exception 'Job selection unavailable';end if;
  n:=0;
  for l in select * from binderclip.cost_lines c where c.tenant_id=p_tenant and c.job_id=any(ids) and c.side='SELL' and not exists(select 1 from binderclip.invoice_items x where x.line_id=c.id) order by c.id loop
   n:=n+1;if cur is null then cur:=l.currency;fx:=l.fx_rate;elsif cur<>l.currency or fx<>l.fx_rate then raise exception 'Consolidation requires one currency and FX rate';end if;
  end loop;
  if n=0 then raise exception 'Charges already invoiced';end if;
  select * into strict r from binderclip.masters where id=customer and tenant_id=p_tenant;
  insert into binderclip.invoices(tenant_id,customer_id,number,currency,fx_rate,due_date,snapshot,branch,created_by)
  values(p_tenant,customer,'INV-'||to_char(current_date,'YYYYMM')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),cur,fx,current_date+coalesce((r.data->>'credit_days')::integer,30),
   jsonb_build_object('company',to_jsonb(co),'customer',to_jsonb(r)),m.branch,u) returning id into result;
  for l in select * from binderclip.cost_lines c where c.tenant_id=p_tenant and c.job_id=any(ids) and c.side='SELL' and not exists(select 1 from binderclip.invoice_items x where x.line_id=c.id) loop
   net:=round(l.quantity*l.unit_rate,2);tax:=round(net*l.tax_rate/100,2);subtotal:=subtotal+net;tax_total:=tax_total+tax;
   insert into binderclip.invoice_items(tenant_id,invoice_id,job_id,line_id,description,quantity,unit_rate,tax_rate,exemption,net,tax) values(p_tenant,result,l.job_id,l.id,l.service,l.quantity,l.unit_rate,l.tax_rate,l.exemption,net,tax);
  end loop;
  update binderclip.invoices set subtotal=cmd.subtotal,tax_total=cmd.tax_total,total=cmd.subtotal+cmd.tax_total where id=result;
 elsif p_action in ('invoice.approve','invoice.issue','invoice.receipt') then
  select * into i from binderclip.invoices where id=target and tenant_id=p_tenant for update;
  if not found then raise exception 'Invoice unavailable';end if;
  path:=case p_action when 'invoice.approve' then 'approve' when 'invoice.issue' then 'issue' else 'receipt' end;
  perform binderclip.require(p_tenant,'invoicing.detail.'||path,case when path='receipt' then 'C' else 'U' end,i.created_by,i.branch);
  if path='approve' and i.status='Draft' then update binderclip.invoices set status='Approved' where id=i.id;
  elsif path='issue' and i.status='Approved' then
   net:=round(i.subtotal*i.fx_rate,2);tax:=round(i.tax_total*i.fx_rate,2);
   perform binderclip.post(p_tenant,'invoice:'||i.id,'Customer invoice '||i.number,i.branch,jsonb_build_array(jsonb_build_array('1100 Receivables',net+tax,0),jsonb_build_array('4000 Freight revenue',0,net),jsonb_build_array('2200 VAT payable',0,tax)));
   update binderclip.invoices set status=case when total=0 then 'Paid' else 'Issued' end where id=i.id;
  elsif path='receipt' and i.status in ('Issued','Partially Paid') then
   amount:=(p_data->>'amount')::numeric;if amount<=0 or amount>i.total-i.paid then raise exception 'Payment must be positive and within outstanding balance';end if;
   insert into binderclip.receipts(tenant_id,invoice_id,reference,amount,received_on,branch,created_by) values(p_tenant,i.id,p_data->>'reference',amount,(p_data->>'received_on')::date,i.branch,u) returning id into result;
   actual:=round(i.subtotal*i.fx_rate,2)+round(i.tax_total*i.fx_rate,2);
   delta:=round((i.paid+amount)/i.total*actual,2)-round(i.paid/i.total*actual,2);
   perform binderclip.post(p_tenant,'receipt:'||result,'Receipt '||(p_data->>'reference'),i.branch,jsonb_build_array(jsonb_build_array('1000 Bank',delta,0),jsonb_build_array('1100 Receivables',0,delta)));
   update binderclip.invoices set paid=paid+amount,status=case when paid+amount=total then 'Paid' else 'Partially Paid' end where id=i.id;
  else raise exception 'Invalid invoice state transition';end if;result:=i.id;
 elsif p_action='cost.lock' then
  j:=binderclip.job_guard(p_tenant,target,'costs.detail.lock');
  if not j.approved or not exists(select 1 from binderclip.cost_lines where job_id=j.id and side='SELL') or exists(select 1 from binderclip.cost_lines cl left join binderclip.supplier_bills sb on sb.line_id=cl.id where cl.job_id=j.id and cl.side='BUY' and (sb.id is null or sb.status<>'Matched'))
   or exists(select 1 from binderclip.cost_lines cl left join binderclip.invoice_items x on x.line_id=cl.id left join binderclip.invoices iv on iv.id=x.invoice_id where cl.job_id=j.id and cl.side='SELL' and (iv.id is null or iv.status in ('Draft','Approved'))) then raise exception 'Approve costs, match bills and issue all sell charges before locking';end if;
  update binderclip.jobs set locked_at=now(),locked_by=u where id=j.id;result:=j.id;
 elsif p_action='cost.unlock' then
  select * into j from binderclip.jobs where id=target and tenant_id=p_tenant for update;
  if not found then raise exception 'Job unavailable';end if;
  perform binderclip.require(p_tenant,'costs.detail.unlock','U',j.created_by,j.branch);
  if j.locked_at is null or j.status in ('Closed','Cancelled') or coalesce(trim(p_data->>'reason'),'')='' then raise exception 'Unlock requires an active locked job and a reason';end if;
  update binderclip.jobs set locked_at=null,locked_by=null where id=j.id;result:=j.id;
 elsif p_action='job.status' then
  select * into j from binderclip.jobs where id=target and tenant_id=p_tenant for update;
  if not found then raise exception 'Job unavailable';end if;
  perform binderclip.require(p_tenant,'jobs.detail.status','U',j.created_by,j.branch);path:=p_data->>'status';
  if not ((j.status='Draft' and path='Cancelled') or (j.status='Booked' and path='In transit') or (j.status='In transit' and path='Delivered') or (j.status='Delivered' and path='Closed' and j.locked_at is not null)) then raise exception 'Invalid job transition; closing requires a locked sheet';end if;
  update binderclip.jobs set status=path where id=j.id;result:=j.id;
 elsif p_action='member.save' then
  perform binderclip.require(p_tenant,'settings.members.manage',case when target is null then 'C' else 'U' end);
  if (p_data->>'email') !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or coalesce(trim(p_data->>'display_name'),'')='' then raise exception 'Valid Google email and display name required';end if;
  select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_data->'role_ids');
  if coalesce(cardinality(ids),0)=0 or cardinality(ids)<>(select count(*) from binderclip.roles where id=any(ids) and tenant_id=p_tenant) then raise exception 'Assign valid company roles';end if;
  if target is null then
   insert into binderclip.members(tenant_id,email,display_name,branch) values(p_tenant,lower(trim(p_data->>'email')),trim(p_data->>'display_name'),coalesce(nullif(p_data->>'branch',''),m.branch)) returning id into result;
  else
   select * into member_row from binderclip.members where id=target and tenant_id=p_tenant for update;
   if not found then raise exception 'Member unavailable';end if;
   if member_row.id=m.id then raise exception 'Use another administrator to change your own membership';end if;
   if member_row.user_id is not null and member_row.email<>lower(trim(p_data->>'email')) then raise exception 'Disable the existing member and invite the new Google email separately';end if;
   update binderclip.members set email=lower(trim(p_data->>'email')),display_name=trim(p_data->>'display_name'),branch=coalesce(nullif(p_data->>'branch',''),m.branch),enabled=coalesce((p_data->>'enabled')::boolean,true) where id=target;result:=target;
   delete from binderclip.member_roles where member_id=target;
  end if;
  insert into binderclip.member_roles(tenant_id,member_id,role_id) select p_tenant,result,unnest(ids);
 elsif p_action='role.save' then
  perform binderclip.require(p_tenant,'settings.roles.manage',case when target is null then 'C' else 'U' end);
  if coalesce(trim(p_data->>'name'),'')='' then raise exception 'Role name required';end if;
  if target is null then insert into binderclip.roles(tenant_id,name,description) values(p_tenant,trim(p_data->>'name'),coalesce(p_data->>'description','')) returning id into result;
  else
   select * into role_row from binderclip.roles where id=target and tenant_id=p_tenant for update;if not found then raise exception 'Role unavailable';end if;
   if exists(select 1 from binderclip.member_roles where member_id=m.id and role_id=target) then raise exception 'Use another administrator to change a role assigned to yourself';end if;
   update binderclip.roles set name=trim(p_data->>'name'),description=coalesce(p_data->>'description','') where id=target;delete from binderclip.grants where role_id=target;result:=target;
  end if;
  for v in select value from jsonb_array_elements(p_data->'grants') loop
   insert into binderclip.grants(role_id,path,action,scope,can_export) values(result,v->>'path',v->>'action',v->>'scope',coalesce((v->>'can_export')::boolean,false));
  end loop;
 elsif p_action='company.save' then
  perform binderclip.require(p_tenant,'settings.company.manage','U');
  if coalesce(trim(p_data->>'name'),'')='' then raise exception 'Company name required';end if;
  update binderclip.companies set name=trim(p_data->>'name'),trn=coalesce(p_data->>'trn',''),address=coalesce(p_data->>'address',''),tolerance=(p_data->>'tolerance')::numeric where id=p_tenant;result:=p_tenant;
 else raise exception 'Unknown process';end if;
 perform binderclip.log(p_tenant,p_action,coalesce(jobid,result),coalesce(p_data->>'reason',''));
 return jsonb_build_object('id',result);
end $$;


create or replace function public.bc_costsheet(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);job_row binderclip.jobs;cost_row binderclip.cost_lines;quote_row binderclip.quotations;quote_line binderclip.quotation_lines;
 company_row binderclip.companies;result jsonb;target uuid:=nullif(p_data->>'job_id','')::uuid;line_target uuid:=nullif(p_data->>'line_id','')::uuid;supplier_target uuid;reason text;side_value text;invoice_id uuid;
begin
 if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>100000 then raise exception 'Invalid cost sheet payload';end if;
 if p_action='list' then
  select coalesce(jsonb_agg(v),'[]') into result from(select jsonb_build_object('id',j.id,'number',j.number,'costsheet_number',j.costsheet_number,'customer_name',c.name,'status',j.status,'sheet_status',case when j.locked_at is not null then 'Locked' when j.approved then 'Approved' else 'Open' end,'created_at',j.created_at,'data',j.data,'figures',binderclip.figures(p_tenant,j.id)) v
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
