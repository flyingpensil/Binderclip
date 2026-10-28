begin;
-- Supplier documents retain their own header and individual service lines.
create table binderclip.purchase_invoices(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,
 job_id uuid not null,supplier_id uuid not null,number text not null,reference text not null check(length(trim(reference)) between 1 and 240),
 invoice_date date not null,due_date date not null,currency text not null check(currency ~ '^[A-Z]{3}$'),fx_rate numeric(16,8) not null check(fx_rate>0),
 status text not null default 'Draft' check(status in('Draft','Prepared')),branch text not null,
 created_by uuid references auth.users,created_at timestamptz,created_by_name text,updated_by uuid references auth.users,updated_at timestamptz,updated_by_name text,
 unique(id,tenant_id),unique(tenant_id,number),unique(tenant_id,supplier_id,reference),
 foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id),foreign key(supplier_id,tenant_id) references binderclip.masters(id,tenant_id),check(due_date>=invoice_date));
create table binderclip.purchase_items(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,invoice_id uuid not null,position integer not null,
 description text not null check(length(trim(description)) between 1 and 240),comments text not null default '',unit text not null default 'shipment',
 quantity numeric(14,3) not null check(quantity>0),unit_rate numeric(18,2) not null check(unit_rate>=0),tax_rate numeric(5,2) not null default 0 check(tax_rate between 0 and 100),
 buy_line_id uuid,sell_line_id uuid,created_by uuid references auth.users,created_at timestamptz,created_by_name text,updated_by uuid references auth.users,updated_at timestamptz,updated_by_name text,
 foreign key(invoice_id,tenant_id) references binderclip.purchase_invoices(id,tenant_id),foreign key(buy_line_id,tenant_id) references binderclip.cost_lines(id,tenant_id),foreign key(sell_line_id,tenant_id) references binderclip.cost_lines(id,tenant_id),unique(invoice_id,position));
alter table binderclip.purchase_invoices enable row level security;
alter table binderclip.purchase_items enable row level security;
revoke all on binderclip.purchase_invoices,binderclip.purchase_items from public,anon,authenticated;
create index on binderclip.purchase_invoices(tenant_id,job_id);
create unique index on binderclip.purchase_invoices(tenant_id,supplier_id,lower(reference));
create trigger record_tracking before insert or update on binderclip.purchase_invoices for each row execute function binderclip.stamp_record();
create trigger record_tracking before insert or update on binderclip.purchase_items for each row execute function binderclip.stamp_record();
alter table binderclip.supplier_bills add column purchase_invoice_id uuid;
alter table binderclip.supplier_bills add column tax_amount numeric(18,2) not null default 0 check(tax_amount>=0);
alter table binderclip.supplier_bills add foreign key(purchase_invoice_id,tenant_id) references binderclip.purchase_invoices(id,tenant_id);
alter table binderclip.cost_lines add column comments text not null default '',add column unit text not null default 'shipment';
alter table binderclip.invoice_items add column comments text not null default '',add column unit text not null default 'shipment',add column position integer not null default 0,
 add column discount_share numeric(18,2) not null default 0,add column adjustment_share numeric(18,2) not null default 0;
alter table binderclip.invoices add column discount numeric(18,2) not null default 0 check(discount>=0),add column adjustment numeric(18,2) not null default 0,
 add column charges_subtotal numeric(18,2),add column issued_at timestamptz,add column fx_source text not null default '',add column fx_date date,add column supply_date date;
create function binderclip.invoice_defaults() returns trigger language plpgsql set search_path='' as $$
begin new.fx_source:=coalesce(new.snapshot->'customer'->'data'->>'default_fx_source','');new.fx_date:=new.invoice_date;new.supply_date:=new.invoice_date;return new;end $$;
create trigger invoice_defaults before insert on binderclip.invoices for each row execute function binderclip.invoice_defaults();

-- Extend the existing sequence without changing any existing identifiers.
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.number_prefix(text)'::regprocedure);
 execute replace(definition,'when ''customers'' then ''CUS''','when ''purchase_invoices'' then ''PINV'' when ''customers'' then ''CUS''');
end $$;
create function binderclip.purchase_number() returns trigger language plpgsql security definer set search_path='' as $$
begin if TG_OP='INSERT' then new.number:=binderclip.next_number(new.tenant_id,'purchase_invoices');else new.number:=old.number;end if;return new;end $$;
create trigger system_number before insert or update on binderclip.purchase_invoices for each row execute function binderclip.purchase_number();

-- Validate customer FX defaults and every selected supplier on the server.
create function binderclip.validate_practical_fields() returns trigger language plpgsql security definer set search_path='' as $$
declare base_currency text;value text;begin
 select currency into base_currency from binderclip.companies where id=new.tenant_id;
 if TG_TABLE_NAME='masters' then
  if new.data ? 'default_fx_rate' and nullif(new.data->>'default_fx_rate','') is not null then
   if (new.data->>'default_fx_rate')::numeric<=0 or (new.currency=base_currency and (new.data->>'default_fx_rate')::numeric<>1) then raise exception 'Use a positive exchange rate; company currency must use 1';end if;
  end if;
 else
  if new.data ? 'supplier_ids' then
   if jsonb_typeof(new.data->'supplier_ids')<>'array' or jsonb_array_length(new.data->'supplier_ids')>100 then raise exception 'Choose valid job suppliers';end if;
   for value in select jsonb_array_elements_text(new.data->'supplier_ids') loop
    if not exists(select 1 from binderclip.masters s where s.id=value::uuid and s.tenant_id=new.tenant_id and s.kind='suppliers' and binderclip.allowed(new.tenant_id,'suppliers.list.manage','R',s.created_by,s.branch)) then raise exception 'Selected supplier unavailable';end if;
   end loop;
  end if;
 end if;return new;
end $$;
create trigger practical_fields before insert or update on binderclip.masters for each row execute function binderclip.validate_practical_fields();
create trigger practical_fields before insert or update on binderclip.jobs for each row execute function binderclip.validate_practical_fields();
create function binderclip.purchase_stage_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='Booked' and old.status='Draft' and exists(select 1 from binderclip.purchase_invoices where job_id=new.id and status='Draft') then raise exception 'Import every draft supplier invoice into the cost sheet before booking this job';end if;
 return new;
end $$;
create trigger purchase_stage_gate before update of status on binderclip.jobs for each row execute function binderclip.purchase_stage_gate();

-- Posted invoice lines remain immutable. The controlled draft editor is the only
-- application path that can change an unposted line.
create function binderclip.protect_invoice_item() returns trigger language plpgsql security definer set search_path='' as $$
declare inv binderclip.invoices;begin
 select * into strict inv from binderclip.invoices where id=old.invoice_id for update;
 if TG_OP<>'UPDATE' or inv.status<>'Draft' or current_setting('binderclip.draft_invoice',true) is distinct from inv.id::text then raise exception 'Invoice lines are immutable outside authorized draft preparation';end if;
 if (new.id,new.tenant_id,new.invoice_id,new.job_id,new.line_id) is distinct from (old.id,old.tenant_id,old.invoice_id,old.job_id,old.line_id) then raise exception 'Invoice source links cannot be changed';end if;
 return new;
end $$;
drop trigger immutable_invoice_items on binderclip.invoice_items;
create trigger immutable_invoice_items before update or delete on binderclip.invoice_items for each row execute function binderclip.protect_invoice_item();
create function binderclip.invoice_issue_stamp() returns trigger language plpgsql set search_path='' as $$
begin if old.status='Approved' and new.status in('Issued','Paid') then new.issued_at:=clock_timestamp();else new.issued_at:=old.issued_at;end if;return new;end $$;
create trigger issue_stamp before update on binderclip.invoices for each row execute function binderclip.invoice_issue_stamp();
create function binderclip.copy_invoice_source() returns trigger language plpgsql security definer set search_path='' as $$
begin
 select comments,unit into new.comments,new.unit from binderclip.cost_lines where id=new.line_id;
 select coalesce(max(position),0)+1 into new.position from binderclip.invoice_items where invoice_id=new.invoice_id;
 return new;
end $$;
create trigger copy_source before insert on binderclip.invoice_items for each row execute function binderclip.copy_invoice_source();
alter table binderclip.journal_lines drop constraint journal_lines_account_check;
alter table binderclip.journal_lines add constraint journal_lines_account_check check(account in('1000 Bank','1100 Receivables','1200 VAT recoverable','2000 Accrued costs','2100 Payables','2200 VAT payable','4000 Freight revenue','5000 Direct costs'));
create function binderclip.post_supplier_vat() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='Matched' and new.tax_amount>0 and not exists(select 1 from binderclip.journals where tenant_id=new.tenant_id and source='input-tax:'||new.id) then
  perform binderclip.post(new.tenant_id,'input-tax:'||new.id,'Input VAT '||new.number,new.branch,jsonb_build_array(jsonb_build_array('1200 VAT recoverable',round(new.tax_amount*new.fx_rate,2),0),jsonb_build_array('2100 Payables',0,round(new.tax_amount*new.fx_rate,2))));
 end if;return new;
end $$;
create trigger supplier_vat after insert or update of status,tax_amount on binderclip.supplier_bills for each row execute function binderclip.post_supplier_vat();

create function public.bc_practical(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare member_row binderclip.members:=binderclip.member(p_tenant);co binderclip.companies;j binderclip.jobs;s binderclip.masters;c binderclip.masters;
 purchase binderclip.purchase_invoices;item binderclip.purchase_items;inv binderclip.invoices;x binderclip.invoice_items;l binderclip.cost_lines;
 target uuid:=nullif(p_data->>'id','')::uuid;job_id uuid:=nullif(p_data->>'job_id','')::uuid;ids uuid[];v jsonb;result jsonb;line_id uuid;buy_id uuid;sell_id uuid;
 idx integer:=0;n integer:=0;gross numeric:=0;net numeric:=0;tax numeric:=0;discount_value numeric:=0;adjustment_value numeric:=0;running numeric:=0;prior_discount numeric:=0;prior_adjustment numeric:=0;allocated_discount numeric;allocated_adjustment numeric;
 bill_id uuid;sell_currency text;sell_fx numeric;as_of date:=coalesce(nullif(p_data->>'as_of','')::date,current_date);from_on date:=nullif(p_data->>'from','')::date;to_on date;
 customer_id uuid:=nullif(p_data->>'customer_id','')::uuid;requested_currency text:=nullif(p_data->>'currency','');requested_action text:=coalesce(p_data->>'action','R');reason text;
begin
 if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>500000 then raise exception 'Invalid request';end if;
 select * into strict co from binderclip.companies where id=p_tenant;
 if p_action in('purchases','purchase') then
  if job_id is not null then select * into strict j from binderclip.jobs where id=job_id and tenant_id=p_tenant;perform binderclip.require(p_tenant,'jobs.list.manage','R',j.created_by,j.branch);end if;
  select coalesce(jsonb_agg(q.payload order by q.payload->>'created_at' desc),'[]') into result from(
   select to_jsonb(h)||jsonb_build_object('supplier_name',vendor.name,'job_number',shipment.number,
    'lines',(select coalesce(jsonb_agg(to_jsonb(a) order by position),'[]') from binderclip.purchase_items a where a.invoice_id=h.id),
    'net',(select coalesce(sum(round(a.quantity*a.unit_rate,2)),0) from binderclip.purchase_items a where a.invoice_id=h.id),
    'vat',(select coalesce(sum(round(round(a.quantity*a.unit_rate,2)*a.tax_rate/100,2)),0) from binderclip.purchase_items a where a.invoice_id=h.id),
    'match_status',case when h.status='Draft' then 'Draft' when not exists(select 1 from binderclip.purchase_items a left join binderclip.supplier_bills b on b.line_id=a.buy_line_id where a.invoice_id=h.id and (b.id is null or b.status<>'Matched')) then 'Matched' when exists(select 1 from binderclip.supplier_bills b where b.purchase_invoice_id=h.id and b.status='Pending') then 'Variance review' else 'Prepared' end) payload
   from binderclip.purchase_invoices h join binderclip.masters vendor on vendor.id=h.supplier_id join binderclip.jobs shipment on shipment.id=h.job_id
   where h.tenant_id=p_tenant and (target is null or h.id=target) and (job_id is null or h.job_id=job_id)
   and binderclip.allowed(p_tenant,'costs.detail.manage','R',shipment.created_by,shipment.branch) and binderclip.allowed(p_tenant,'jobs.list.manage','R',shipment.created_by,shipment.branch)
   order by h.created_at desc limit 500)q;
 elsif p_action='purchase.save' then
  j:=binderclip.job_guard(p_tenant,job_id,'costs.detail.manage','C');
  perform binderclip.require(p_tenant,'jobs.list.manage','R',j.created_by,j.branch);
  if j.status<>'Draft' or j.approved then raise exception 'Enter supplier invoices before booking this job';end if;
  select * into strict s from binderclip.masters where id=(p_data->>'supplier_id')::uuid and tenant_id=p_tenant and kind='suppliers';
  perform binderclip.require(p_tenant,'suppliers.list.manage','R',s.created_by,s.branch);
  if jsonb_typeof(p_data->'lines')<>'array' or jsonb_array_length(p_data->'lines') not between 1 and 100 then raise exception 'Enter 1 to 100 supplier invoice lines';end if;
  if (p_data->>'invoice_date')::date>current_date or (p_data->>'currency'=co.currency and (p_data->>'fx_rate')::numeric<>1) then raise exception 'Check supplier invoice date and exchange rate';end if;
  if target is null then
   insert into binderclip.purchase_invoices(tenant_id,job_id,supplier_id,number,reference,invoice_date,due_date,currency,fx_rate,branch)
   values(p_tenant,j.id,s.id,'',trim(p_data->>'reference'),(p_data->>'invoice_date')::date,(p_data->>'due_date')::date,p_data->>'currency',(p_data->>'fx_rate')::numeric,j.branch) returning id into target;
  else
   select * into strict purchase from binderclip.purchase_invoices where id=target and tenant_id=p_tenant and purchase_invoices.job_id=j.id for update;
   perform binderclip.require(p_tenant,'costs.detail.manage','U',j.created_by,j.branch);
   if purchase.status<>'Draft' then raise exception 'Imported supplier documents are fixed; use variance approval for corrections';end if;
   update binderclip.purchase_invoices set supplier_id=s.id,reference=trim(p_data->>'reference'),invoice_date=(p_data->>'invoice_date')::date,due_date=(p_data->>'due_date')::date,currency=p_data->>'currency',fx_rate=(p_data->>'fx_rate')::numeric where id=target;
   delete from binderclip.purchase_items where invoice_id=target;
  end if;
  for v in select value from jsonb_array_elements(p_data->'lines') loop
   idx:=idx+1;insert into binderclip.purchase_items(tenant_id,invoice_id,position,description,comments,unit,quantity,unit_rate,tax_rate)
   values(p_tenant,target,idx,trim(v->>'description'),coalesce(v->>'comments',''),coalesce(nullif(v->>'unit',''),'shipment'),(v->>'quantity')::numeric,(v->>'unit_rate')::numeric,coalesce((v->>'tax_rate')::numeric,0));
  end loop;
  perform binderclip.log(p_tenant,'purchase.save',target,p_data->>'reference');result:=jsonb_build_object('id',target);
 elsif p_action='purchase.unprepare' then
  select * into strict purchase from binderclip.purchase_invoices where id=target and tenant_id=p_tenant for update;
  j:=binderclip.job_guard(p_tenant,purchase.job_id,'costs.detail.manage','U');
  if j.status<>'Draft' or j.approved or purchase.status<>'Prepared' or coalesce(trim(p_data->>'reason'),'')='' then raise exception 'A reason and an unbooked, unapproved job are required';end if;
  select array_agg(a) into ids from(select buy_line_id a from binderclip.purchase_items where invoice_id=target union all select sell_line_id from binderclip.purchase_items where invoice_id=target)q;
  if exists(select 1 from binderclip.cost_lines where id=any(ids) and accrued) or exists(select 1 from binderclip.invoice_items where line_id=any(ids)) then raise exception 'Posted or invoiced source lines cannot be removed';end if;
  insert into binderclip.costsheet_changes(tenant_id,job_id,action,reason,before_values,after_values,actor) values(p_tenant,j.id,'purchase.unprepare',trim(p_data->>'reason'),(select jsonb_agg(to_jsonb(a)) from binderclip.cost_lines a where a.id=any(ids)),jsonb_build_object('purchase_id',purchase.id),auth.uid());
  update binderclip.purchase_items set buy_line_id=null,sell_line_id=null where invoice_id=target;
  delete from binderclip.cost_lines where id=any(ids);
  update binderclip.purchase_invoices set status='Draft' where id=target;update binderclip.jobs set approved=false where id=j.id;
  result:=jsonb_build_object('id',target);
 elsif p_action='costsheet.import' then
  j:=binderclip.job_guard(p_tenant,job_id,'costs.detail.manage','C');
  if j.status<>'Draft' or j.approved then raise exception 'Import supplier documents into an open draft job';end if;
  select array_agg(value::uuid order by value) into ids from jsonb_array_elements_text(p_data->'invoice_ids');
  if coalesce(cardinality(ids),0)=0 or cardinality(ids)<>(select count(distinct a) from unnest(ids)a) then raise exception 'Select unique supplier invoices';end if;
  select * into strict c from binderclip.masters where id=j.customer_id;
  sell_currency:=c.currency;sell_fx:=case when c.currency=co.currency then 1 else nullif(c.data->>'default_fx_rate','')::numeric end;
  if sell_fx is null or sell_fx<=0 then raise exception 'Set the customer exchange rate before preparing foreign-currency charges';end if;
  for purchase in select * from binderclip.purchase_invoices h where h.id=any(ids) and h.tenant_id=p_tenant and h.job_id=j.id order by h.id for update loop
   n:=n+1;if purchase.status<>'Draft' then raise exception 'This supplier invoice was already imported';end if;
   perform binderclip.require(p_tenant,'suppliers.list.manage','R',(select created_by from binderclip.masters where id=purchase.supplier_id),(select branch from binderclip.masters where id=purchase.supplier_id));
   for item in select * from binderclip.purchase_items where invoice_id=purchase.id order by position loop
    v:=public.bc_command(p_tenant,'cost.add',jsonb_build_object('job_id',j.id,'side','BUY','service',item.description,'supplier_id',purchase.supplier_id,'quantity',item.quantity,'unit_rate',item.unit_rate,'currency',purchase.currency,'fx_rate',purchase.fx_rate,'tax_rate',0));buy_id:=(v->>'id')::uuid;
    v:=public.bc_command(p_tenant,'cost.add',jsonb_build_object('job_id',j.id,'side','SELL','service',item.description,'quantity',item.quantity,'unit_rate',round(item.unit_rate*purchase.fx_rate/sell_fx,2),'currency',sell_currency,'fx_rate',sell_fx,'tax_rate',coalesce((p_data->>'sell_vat')::numeric,5),'exemption',coalesce(p_data->>'exemption','')));sell_id:=(v->>'id')::uuid;
    update binderclip.cost_lines set comments=item.comments,unit=item.unit where id in(buy_id,sell_id);
    update binderclip.purchase_items set buy_line_id=buy_id,sell_line_id=sell_id where id=item.id;
   end loop;
   update binderclip.purchase_invoices set status='Prepared' where id=purchase.id;
  end loop;
  if n<>cardinality(ids) then raise exception 'Selected supplier invoice is unavailable for this job';end if;
  perform binderclip.log(p_tenant,'costsheet.import',j.id,'Supplier documents imported without duplicate lines');result:=jsonb_build_object('id',j.id);
 elsif p_action='costsheet.book_match' then
  select * into strict j from binderclip.jobs where id=job_id and tenant_id=p_tenant for update;
  if j.locked_at is not null or j.status in('Closed','Cancelled') then raise exception 'This job is locked or archived';end if;
  if j.status='Draft' then perform public.bc_command(p_tenant,'job.book',jsonb_build_object('id',j.id));end if;
  perform binderclip.require(p_tenant,'costs.detail.match','C',j.created_by,j.branch);
  for purchase in select * from binderclip.purchase_invoices h where h.tenant_id=p_tenant and h.job_id=j.id and h.status='Prepared' order by id for update loop
   for item in select * from binderclip.purchase_items a where a.invoice_id=purchase.id and not exists(select 1 from binderclip.supplier_bills b where b.line_id=a.buy_line_id) order by a.position loop
    v:=public.bc_command(p_tenant,'bill.match',jsonb_build_object('job_id',j.id,'line_id',item.buy_line_id,'supplier_id',purchase.supplier_id,'number',purchase.reference,'invoice_date',purchase.invoice_date,'due_date',purchase.due_date,'quantity',item.quantity,'unit_rate',item.unit_rate,'currency',purchase.currency,'fx_rate',purchase.fx_rate));
    update binderclip.supplier_bills set purchase_invoice_id=purchase.id,tax_amount=round(round(item.quantity*item.unit_rate,2)*item.tax_rate/100,2) where id=(v->>'id')::uuid;
   end loop;
  end loop;
  result:=jsonb_build_object('id',j.id);
 elsif p_action='invoice.save' then
  select * into strict inv from binderclip.invoices where id=target and tenant_id=p_tenant for update;
  perform binderclip.require(p_tenant,'invoicing.list.manage','R',inv.created_by,inv.branch);
  if inv.status<>'Draft' then raise exception 'Only an unapproved draft invoice can be edited';end if;
  if jsonb_typeof(p_data->'lines')<>'array' or jsonb_array_length(p_data->'lines') not between 1 and 100 then raise exception 'Enter 1 to 100 invoice lines';end if;
  reason:=trim(p_data->>'reason');if coalesce(reason,'')='' then raise exception 'Record a reason for draft invoice preparation';end if;
  if coalesce(nullif(p_data->>'invoice_date','')::date,inv.invoice_date)>current_date or coalesce(nullif(p_data->>'due_date','')::date,inv.due_date)<coalesce(nullif(p_data->>'invoice_date','')::date,inv.invoice_date) then raise exception 'Check invoice and due dates';end if;
  for j in select distinct r.* from binderclip.jobs r join binderclip.invoice_items a on a.job_id=r.id where a.invoice_id=inv.id order by r.id loop
   perform binderclip.require(p_tenant,'invoicing.detail.generate','C',j.created_by,j.branch);perform binderclip.require(p_tenant,'costs.detail.manage','U',j.created_by,j.branch);
   if j.locked_at is not null or j.status in('Closed','Cancelled') then raise exception 'This job is locked or archived';end if;
   perform 1 from binderclip.jobs where id=j.id for update;
  end loop;
  select count(*) into n from binderclip.invoice_items where invoice_id=inv.id;
  if (select count(distinct a->>'id') from jsonb_array_elements(p_data->'lines') a where nullif(a->>'id','') is not null)<>n or (select count(*) from jsonb_array_elements(p_data->'lines') a where nullif(a->>'id','') is not null)<>n then raise exception 'Keep every existing invoice line exactly once';end if;
  perform set_config('binderclip.draft_invoice',inv.id::text,true);
  for v in select value from jsonb_array_elements(p_data->'lines') loop
   idx:=idx+1;line_id:=nullif(v->>'id','')::uuid;
   if line_id is not null then
    select * into strict x from binderclip.invoice_items where id=line_id and invoice_id=inv.id and tenant_id=p_tenant;job_id:=x.job_id;
   else
    job_id:=(v->>'job_id')::uuid;
    if not exists(select 1 from binderclip.invoice_items a where a.invoice_id=inv.id and a.job_id=job_id) then raise exception 'New lines must belong to a job already on this invoice';end if;
    select * into strict j from binderclip.jobs where id=job_id;
    perform binderclip.require(p_tenant,'costs.detail.manage','C',j.created_by,j.branch);
    insert into binderclip.cost_lines(tenant_id,job_id,side,service,quantity,unit_rate,currency,fx_rate,tax_rate,exemption,branch,created_by)
    values(p_tenant,job_id,'SELL',v->>'description',(v->>'quantity')::numeric,(v->>'unit_rate')::numeric,inv.currency,inv.fx_rate,(v->>'tax_rate')::numeric,coalesce(v->>'exemption',''),j.branch,auth.uid()) returning id into sell_id;
    insert into binderclip.invoice_items(tenant_id,invoice_id,job_id,line_id,description,quantity,unit_rate,tax_rate,exemption,net,tax) values(p_tenant,inv.id,job_id,sell_id,v->>'description',(v->>'quantity')::numeric,(v->>'unit_rate')::numeric,(v->>'tax_rate')::numeric,coalesce(v->>'exemption',''),0,0) returning * into x;line_id:=x.id;
   end if;
   if coalesce(length(trim(v->>'description')),0) not between 1 and 240 or (v->>'quantity')::numeric<=0 or (v->>'unit_rate')::numeric<0 or (v->>'tax_rate')::numeric not between 0 and 100 then raise exception 'Check invoice description, quantity, price and VAT';end if;
   update binderclip.cost_lines set service=v->>'description',quantity=(v->>'quantity')::numeric,unit_rate=(v->>'unit_rate')::numeric,tax_rate=(v->>'tax_rate')::numeric,exemption=coalesce(v->>'exemption',''),comments=coalesce(v->>'comments',''),unit=coalesce(nullif(v->>'unit',''),'shipment') where id=x.line_id;
   update binderclip.invoice_items set description=v->>'description',quantity=(v->>'quantity')::numeric,unit_rate=(v->>'unit_rate')::numeric,tax_rate=(v->>'tax_rate')::numeric,exemption=coalesce(v->>'exemption',''),comments=coalesce(v->>'comments',''),unit=coalesce(nullif(v->>'unit',''),'shipment'),position=idx where id=line_id;
   gross:=gross+round((v->>'quantity')::numeric*(v->>'unit_rate')::numeric,2);
  end loop;
  discount_value:=round(coalesce((p_data->>'discount')::numeric,0),2);adjustment_value:=round(coalesce((p_data->>'adjustment')::numeric,0),2);
  if discount_value<0 or discount_value>gross or gross-discount_value+adjustment_value<0 or (gross=0 and adjustment_value<>0) then raise exception 'Discount/adjustment cannot produce a negative invoice or adjust zero charges';end if;
  for x in select * from binderclip.invoice_items where invoice_id=inv.id order by position,id loop
   running:=running+round(x.quantity*x.unit_rate,2);
   allocated_discount:=case when gross=0 then 0 else round(discount_value*running/gross,2)-prior_discount end;
   allocated_adjustment:=case when gross=0 then 0 else round(adjustment_value*running/gross,2)-prior_adjustment end;
   prior_discount:=prior_discount+allocated_discount;prior_adjustment:=prior_adjustment+allocated_adjustment;
   v:=jsonb_build_object('net',round(x.quantity*x.unit_rate,2)-allocated_discount+allocated_adjustment);
   update binderclip.invoice_items set net=(v->>'net')::numeric,tax=round((v->>'net')::numeric*x.tax_rate/100,2),discount_share=allocated_discount,adjustment_share=allocated_adjustment where id=x.id;
  end loop;
  select sum(a.net),sum(a.tax) into net,tax from binderclip.invoice_items a where a.invoice_id=inv.id;
  update binderclip.invoices set charges_subtotal=gross,discount=discount_value,adjustment=adjustment_value,subtotal=net,tax_total=tax,total=net+tax,invoice_date=coalesce(nullif(p_data->>'invoice_date','')::date,invoice_date),due_date=coalesce(nullif(p_data->>'due_date','')::date,due_date),supply_date=coalesce(nullif(p_data->>'supply_date','')::date,supply_date,invoice_date),fx_date=coalesce(nullif(p_data->>'fx_date','')::date,fx_date,invoice_date),fx_source=coalesce(p_data->>'fx_source',fx_source) where id=inv.id;
  for job_id in select distinct a.job_id from binderclip.invoice_items a where a.invoice_id=inv.id loop
   insert into binderclip.costsheet_changes(tenant_id,job_id,action,reason,before_values,after_values,actor) values(p_tenant,job_id,'invoice.draft.save',reason,
    jsonb_build_object('subtotal',inv.subtotal,'tax_total',inv.tax_total,'total',inv.total,'discount',inv.discount,'adjustment',inv.adjustment),
    (select jsonb_build_object('subtotal',a.subtotal,'tax_total',a.tax_total,'total',a.total,'discount',a.discount,'adjustment',a.adjustment) from binderclip.invoices a where a.id=inv.id),auth.uid());
  end loop;
  perform set_config('binderclip.draft_invoice','',true);result:=jsonb_build_object('id',inv.id);
 elsif p_action in('statement','customer_aging') then
  if requested_action not in('R','X') or as_of>current_date then raise exception 'Choose a valid report date/action';end if;
  to_on:=least(coalesce(nullif(p_data->>'to','')::date,as_of),as_of);
  if from_on>to_on then raise exception 'From date cannot follow the report end date';end if;
  perform binderclip.require(p_tenant,'reports.finance.view',requested_action,auth.uid(),member_row.branch);
  if p_action='statement' and customer_id is null then raise exception 'Choose a customer for the statement of account';end if;
  if customer_id is not null then select * into strict c from binderclip.masters where id=customer_id and tenant_id=p_tenant and kind='customers';perform binderclip.require(p_tenant,'customers.ledger.view',requested_action,c.created_by,c.branch);end if;
  with visible as(
   select i.*,customer_alias.name customer_name from binderclip.invoices i join binderclip.masters customer_alias on customer_alias.id=i.customer_id
   where i.tenant_id=p_tenant and i.status in('Issued','Partially Paid','Paid') and (customer_id is null or i.customer_id=customer_id) and (requested_currency is null or i.currency=requested_currency)
   and coalesce(timezone('Asia/Dubai',i.issued_at)::date,(select timezone('Asia/Dubai',entry.created_at)::date from binderclip.journals entry where entry.tenant_id=p_tenant and entry.source='invoice:'||i.id),i.invoice_date)<=to_on
   and binderclip.allowed(p_tenant,'customers.ledger.view',requested_action,customer_alias.created_by,customer_alias.branch) and binderclip.allowed(p_tenant,'customers.ledger.view',requested_action,i.created_by,i.branch)
  ), events as(
   select i.id,i.customer_id,i.customer_name,i.currency,i.number reference,'Invoice' kind,i.invoice_date document_date,coalesce(timezone('Asia/Dubai',i.issued_at)::date,(select timezone('Asia/Dubai',entry.created_at)::date from binderclip.journals entry where entry.tenant_id=p_tenant and entry.source='invoice:'||i.id),i.invoice_date) posted_on,i.total debit,0::numeric credit,i.due_date from visible i
   union all
   select r.id,i.customer_id,i.customer_name,i.currency,r.reference,'Receipt',r.received_on,timezone('Asia/Dubai',entry.created_at)::date,0,r.amount,i.due_date from visible i join binderclip.receipts r on r.invoice_id=i.id join binderclip.journals entry on entry.tenant_id=p_tenant and entry.source='receipt:'||r.id where timezone('Asia/Dubai',entry.created_at)::date<=to_on and r.received_on<=to_on
  ), statement_rows as(
   select *,sum(debit-credit) over(partition by currency order by posted_on,kind,id rows unbounded preceding) balance from events
  ), aging as(
   select i.id,i.customer_id,i.customer_name,i.customer_name party,i.number,i.currency,i.invoice_date,i.due_date,greatest(0,to_on-i.due_date) days_overdue,
    i.total-coalesce((select sum(r.amount) from binderclip.receipts r join binderclip.journals entry on entry.tenant_id=p_tenant and entry.source='receipt:'||r.id where r.invoice_id=i.id and timezone('Asia/Dubai',entry.created_at)::date<=to_on and r.received_on<=to_on),0) outstanding from visible i
  )
  select jsonb_build_object('currency',co.currency,'customer',case when c.id is null then null else jsonb_build_object('id',c.id,'name',c.name,'code',c.code) end,'as_of',to_on,'from',from_on,'rows',
   case when p_action='statement' then (select coalesce(jsonb_agg(to_jsonb(a) order by posted_on,kind,id),'[]') from statement_rows a where from_on is null or a.posted_on>=from_on)
   else(select coalesce(jsonb_agg(to_jsonb(a) order by customer_name,currency,due_date,id),'[]') from aging a where outstanding>0) end,
   'totals',(select coalesce(jsonb_agg(to_jsonb(a) order by currency),'[]') from(select currency,coalesce(sum(debit-credit) filter(where from_on is not null and posted_on<from_on),0) opening,sum(debit-credit) closing,coalesce(sum(debit) filter(where from_on is null or posted_on>=from_on),0) debit,coalesce(sum(credit) filter(where from_on is null or posted_on>=from_on),0) credit from events group by currency)a)) into result;
 else raise exception 'Unknown practical workflow action';end if;
 return binderclip.decimals(binderclip.with_tracking(p_tenant,result));
end $$;
revoke all on function binderclip.purchase_number(),binderclip.validate_practical_fields(),binderclip.purchase_stage_gate(),binderclip.protect_invoice_item(),binderclip.invoice_issue_stamp(),binderclip.invoice_defaults(),binderclip.copy_invoice_source(),binderclip.post_supplier_vat(),public.bc_practical(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.bc_practical(uuid,text,jsonb) to authenticated;
-- Use invoice net charges for billed revenue so discounts and adjustments appear in job margin.
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.figures(uuid,uuid)'::regprocedure);
 definition:=replace(definition,'binderclip.base(l.quantity,l.unit_rate,l.fx_rate)','case when l.side=''SELL'' and exists(select 1 from binderclip.invoice_items x where x.line_id=l.id) then (select round(x.net*i.fx_rate,2) from binderclip.invoice_items x join binderclip.invoices i on i.id=x.invoice_id where x.line_id=l.id) else binderclip.base(l.quantity,l.unit_rate,l.fx_rate) end');
 execute definition;
end $$;
-- Payables and settlement include vendor VAT; job expense/margins exclude recoverable VAT.
do $$declare definition text;signature text;begin
 foreach signature in array array['public.bc_workspace(uuid,text,uuid,text,text)','public.bc_report(uuid,text,date,date,date,text)','public.bc_read(uuid,text,uuid,text,text)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  definition:=replace(definition,'round(b.quantity*b.unit_rate,2)','(round(b.quantity*b.unit_rate,2)+b.tax_amount)');execute definition;
 end loop;
 definition:=pg_get_functiondef('public.bc_workflow(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'net:=round(bill_row.quantity*bill_row.unit_rate,2);','net:=round(bill_row.quantity*bill_row.unit_rate,2)+bill_row.tax_amount;');
 definition:=replace(definition,'binderclip.base(bill_row.quantity,bill_row.unit_rate,bill_row.fx_rate)','(binderclip.base(bill_row.quantity,bill_row.unit_rate,bill_row.fx_rate)+round(bill_row.tax_amount*bill_row.fx_rate,2))');execute definition;
end $$;
-- Allocate base revenue cumulatively: line sums match the invoice's rounded net
-- posting even when an invoice contains several jobs or fractional FX values.
create or replace function binderclip.figures(t uuid,j uuid) returns jsonb language sql stable security definer set search_path='' as $$
 with billed as(
  select x.line_id,round(sum(x.net) over(partition by x.invoice_id order by x.position,x.id rows unbounded preceding)*i.fx_rate,2)-round((sum(x.net) over(partition by x.invoice_id order by x.position,x.id rows unbounded preceding)-x.net)*i.fx_rate,2) base_net
  from binderclip.invoice_items x join binderclip.invoices i on i.id=x.invoice_id where x.tenant_id=t
 ),totals as(
  select coalesce(sum(binderclip.base(l.quantity,l.unit_rate,l.fx_rate)) filter(where side='BUY'),0) expected_buy,
   coalesce(sum(case when b.status='Matched' then binderclip.base(b.quantity,b.unit_rate,b.fx_rate) else binderclip.base(l.quantity,l.unit_rate,l.fx_rate) end) filter(where side='BUY'),0) actual_buy,
   coalesce(sum(coalesce(x.base_net,binderclip.base(l.quantity,l.unit_rate,l.fx_rate))) filter(where side='SELL'),0) sell,
   coalesce(sum(binderclip.base(l.quantity,l.unit_rate,l.fx_rate)) filter(where side='SELL'),0) expected_sell
  from binderclip.cost_lines l left join binderclip.supplier_bills b on b.line_id=l.id left join billed x on x.line_id=l.id where l.tenant_id=t and l.job_id=j)
 select to_jsonb(totals)||jsonb_build_object('margin',sell-actual_buy,'expected_margin',expected_sell-expected_buy,'margin_percent',case when sell=0 then 0 else round((sell-actual_buy)/sell*100,2) end) from totals;
$$;
-- The original Receivables report now uses the same posted-date ageing engine.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_report(uuid,text,date,date,date,text)'::regprocedure);
 definition:=replace(definition,'if p_action not in(''R'',''X'')','if p_kind=''receivables'' then return public.bc_practical(p_tenant,''customer_aging'',jsonb_build_object(''as_of'',p_as_of,''action'',p_action));end if; if p_action not in(''R'',''X'')');execute definition;
end $$;
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_command(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'amount:=(p_data->>''amount'')::numeric;if amount<=0','if (p_data->>''received_on'')::date>current_date then raise exception ''Receipt date cannot be in the future'';end if; amount:=(p_data->>''amount'')::numeric;if amount<=0');execute definition;
end $$;
commit;
