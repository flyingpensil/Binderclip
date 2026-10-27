-- Additive upgrade. No sample records, no new users, no rewrite of posted journals.
begin;
insert into binderclip.permissions select path,unnest(string_to_array(actions,null)) from(values
 ('sales.enquiries.manage','CRU'),('sales.quotes.manage','CRU'),('sales.quotes.approve','U'),('sales.quotes.convert','C'),('sales.quotes.print','X'),
 ('operations.timeline.manage','CR'),('operations.tasks.manage','CRU'),('operations.documents.manage','CRX'),('operations.requirements.manage','CR'),
 ('reports.finance.view','RX'),('finance.payments.manage','CR'))p(path,actions);
-- Existing company administrators inherit the new modules. Other roles remain opt-in.
insert into binderclip.grants(role_id,path,action,scope,can_export)
 select r.id,p.path,p.action,'global',true from binderclip.roles r cross join binderclip.permissions p
 where r.name='Company administrator' on conflict(role_id,path,action) do nothing;

create table binderclip.enquiries(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,
 number text not null,customer_id uuid not null,subject text not null check(length(trim(subject)) between 1 and 240),
 status text not null default 'Pending' check(status in('Pending','Quoted','Confirmed','Cancelled')),
 data jsonb not null default '{}' check(jsonb_typeof(data)='object'),branch text not null,created_by uuid not null references auth.users,
 created_at timestamptz not null default now(),unique(id,tenant_id),unique(tenant_id,number),foreign key(customer_id,tenant_id) references binderclip.masters(id,tenant_id));
create table binderclip.quotations(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,enquiry_id uuid,
 number text not null,customer_id uuid not null,valid_until date not null,status text not null default 'Draft' check(status in('Draft','Approved','Converted','Cancelled')),
 currency text not null check(currency ~ '^[A-Z]{3}$'),fx_rate numeric(16,8) not null check(fx_rate>0),terms text not null default '',
 data jsonb not null default '{}' check(jsonb_typeof(data)='object'),job_id uuid,branch text not null,created_by uuid not null references auth.users,
 created_at timestamptz not null default now(),unique(id,tenant_id),unique(tenant_id,number),
 foreign key(customer_id,tenant_id) references binderclip.masters(id,tenant_id),foreign key(enquiry_id,tenant_id) references binderclip.enquiries(id,tenant_id),
 foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id));
create table binderclip.quotation_lines(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,quote_id uuid not null,
 side text not null check(side in('BUY','SELL')),service text not null check(length(trim(service))>0),supplier_id uuid,
 quantity numeric(14,3) not null check(quantity>0),unit_rate numeric(18,2) not null check(unit_rate>=0),
 tax_rate numeric(5,2) not null default 5 check(tax_rate between 0 and 100),exemption text not null default '',
 foreign key(quote_id,tenant_id) references binderclip.quotations(id,tenant_id),foreign key(supplier_id,tenant_id) references binderclip.masters(id,tenant_id),
 check(side<>'BUY' or supplier_id is not null),check(side<>'SELL' or tax_rate<>0 or length(trim(exemption))>0));
create table binderclip.job_events(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,job_id uuid not null,
 kind text not null check(kind in('Milestone','Note')),title text not null check(length(trim(title)) between 1 and 240),
 detail text not null default '',location text not null default '',occurred_at timestamptz not null default now(),
 branch text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id));
create trigger immutable_events before update or delete on binderclip.job_events for each row execute function binderclip.immutable();
create table binderclip.job_tasks(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,job_id uuid not null,
 title text not null check(length(trim(title)) between 1 and 240),due_on date not null,assignee_id uuid,
 required_before text check(required_before in('Booked','In transit','Delivered','Closed')),
 completed_at timestamptz,completed_by uuid references auth.users,branch text not null,created_by uuid not null references auth.users,
 created_at timestamptz not null default now(),foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id),
 foreign key(assignee_id,tenant_id) references binderclip.members(id,tenant_id));
create table binderclip.job_documents(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,job_id uuid not null,kind text not null check(kind in('BL','AWB','Bayan','Supplier invoice','Customer invoice','POD','Other')),
 filename text not null check(length(filename) between 1 and 240),mime text not null check(mime in('application/pdf','image/png','image/jpeg','text/plain','text/csv')),
 bytes bigint not null check(bytes between 1 and 10485760),object_path text not null unique,status text not null default 'Pending' check(status in('Pending','Ready')),
 branch text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id));
create table binderclip.document_requirements(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,job_id uuid not null,kind text not null check(kind in('BL','AWB','Bayan','Supplier invoice','Customer invoice','POD','Other')),
 required_before text not null check(required_before in('Booked','In transit','Delivered','Closed')),branch text not null,created_by uuid not null references auth.users,
 foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id),unique(job_id,kind,required_before));
create table binderclip.supplier_payments(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,bill_id uuid not null,reference text not null check(length(trim(reference))>0),
 amount numeric(18,2) not null check(amount>0),paid_on date not null,branch text not null,created_by uuid not null references auth.users,
 created_at timestamptz not null default now(),foreign key(bill_id,tenant_id) references binderclip.supplier_bills(id,tenant_id),unique(tenant_id,reference));
create trigger immutable_payments before update or delete on binderclip.supplier_payments for each row execute function binderclip.immutable();
create index on binderclip.enquiries(tenant_id,created_at desc);
create index on binderclip.quotations(tenant_id,created_at desc);
create index on binderclip.job_events(tenant_id,job_id,occurred_at desc);
create index on binderclip.job_tasks(tenant_id,job_id,due_on);
create index on binderclip.job_documents(tenant_id,job_id);
create index on binderclip.supplier_payments(tenant_id,bill_id,paid_on);
alter table binderclip.enquiries enable row level security;
alter table binderclip.quotations enable row level security;
alter table binderclip.quotation_lines enable row level security;
alter table binderclip.job_events enable row level security;
alter table binderclip.job_tasks enable row level security;
alter table binderclip.job_documents enable row level security;
alter table binderclip.document_requirements enable row level security;
alter table binderclip.supplier_payments enable row level security;
revoke all on all tables in schema binderclip from public,anon,authenticated;

create function binderclip.workflow_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status is distinct from old.status and new.status<>'Cancelled' then
  if exists(select 1 from binderclip.job_tasks t where t.job_id=new.id and t.required_before=new.status and t.completed_at is null) then raise exception 'Complete required tasks before this job stage';end if;
  if exists(select 1 from binderclip.document_requirements r where r.job_id=new.id and r.required_before=new.status and not exists(select 1 from binderclip.job_documents d where d.job_id=new.id and d.kind=r.kind and d.status='Ready')) then raise exception 'Upload required documents before this job stage';end if;
 end if;return new;
end $$;
create trigger workflow_stage_gate before update of status on binderclip.jobs for each row execute function binderclip.workflow_gate();

create function public.bc_workflow(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
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
  insert into binderclip.quotation_lines(tenant_id,quote_id,side,service,supplier_id,quantity,unit_rate,tax_rate,exemption) values(p_tenant,target,p_data->>'side',p_data->>'service',case when p_data->>'side'='BUY' then nullif(p_data->>'supplier_id','')::uuid else null end,(p_data->>'quantity')::numeric,(p_data->>'unit_rate')::numeric,coalesce((p_data->>'tax_rate')::numeric,5),coalesce(p_data->>'exemption','')) returning id into result;
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

create function public.bc_workspace(p_tenant uuid,p_kind text,p_id uuid default null,p_query text default '',p_action text default 'R') returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);result jsonb;job_row binderclip.jobs;quote_row binderclip.quotations;
begin
 if p_action not in('R','X') then raise exception 'Invalid read action';end if;
 if p_kind='enquiries' then
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(e)||jsonb_build_object('customer_name',c.name) v from binderclip.enquiries e join binderclip.masters c on c.id=e.customer_id where e.tenant_id=p_tenant and (p_id is null or e.id=p_id) and binderclip.allowed(p_tenant,'sales.enquiries.manage','R',e.created_by,e.branch) and concat_ws(' ',e.number,e.subject,c.name,e.data::text) ilike '%'||p_query||'%' order by e.created_at desc limit 500)s;
 elsif p_kind in('quotes','quote','quote_print') then
  if p_kind in('quote','quote_print') then
   select * into strict quote_row from binderclip.quotations where id=p_id and tenant_id=p_tenant;
   perform binderclip.require(p_tenant,case when p_kind='quote_print' then 'sales.quotes.print' else 'sales.quotes.manage' end,case when p_kind='quote_print' then 'X' else 'R' end,quote_row.created_by,quote_row.branch);
   result:=to_jsonb(quote_row)||jsonb_build_object('customer_name',(select name from binderclip.masters where id=quote_row.customer_id),'company_name',(select name from binderclip.companies where id=p_tenant),
    'lines',(select coalesce(jsonb_agg(to_jsonb(l)),'[]') from binderclip.quotation_lines l where l.quote_id=p_id and (l.side='SELL' or (p_kind<>'quote_print' and binderclip.allowed(p_tenant,'costs.detail.manage','R',quote_row.created_by,quote_row.branch)))));
  else select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(q)||jsonb_build_object('customer_name',c.name,'display_status',case when q.status in('Draft','Approved') and q.valid_until<current_date then 'Expired' else q.status end) v from binderclip.quotations q join binderclip.masters c on c.id=q.customer_id where q.tenant_id=p_tenant and binderclip.allowed(p_tenant,'sales.quotes.manage','R',q.created_by,q.branch) and concat_ws(' ',q.number,c.name,q.data::text) ilike '%'||p_query||'%' order by q.created_at desc limit 500)s;end if;
 elsif p_kind='job_workspace' then
  select * into strict job_row from binderclip.jobs where id=p_id and tenant_id=p_tenant;perform binderclip.require(p_tenant,'jobs.list.manage','R',job_row.created_by,job_row.branch);
  result:=jsonb_build_object('events',(select coalesce(jsonb_agg(to_jsonb(e) order by e.occurred_at desc),'[]') from binderclip.job_events e where e.job_id=p_id and binderclip.allowed(p_tenant,'operations.timeline.manage','R',job_row.created_by,job_row.branch)),
   'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by t.due_on),'[]') from binderclip.job_tasks t where t.job_id=p_id and binderclip.allowed(p_tenant,'operations.tasks.manage','R',job_row.created_by,job_row.branch)),
   'documents',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc),'[]') from binderclip.job_documents d where d.job_id=p_id and binderclip.allowed(p_tenant,'operations.documents.manage','R',job_row.created_by,job_row.branch)),
   'requirements',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from binderclip.document_requirements r where r.job_id=p_id and binderclip.allowed(p_tenant,'operations.requirements.manage','R',job_row.created_by,job_row.branch)));
 elsif p_kind='tasks' then
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(t)||jsonb_build_object('job_number',j.number,'assignee',(select display_name from binderclip.members where id=t.assignee_id)) v from binderclip.job_tasks t join binderclip.jobs j on j.id=t.job_id where t.tenant_id=p_tenant and binderclip.allowed(p_tenant,'operations.tasks.manage','R',j.created_by,j.branch) and binderclip.allowed(p_tenant,'jobs.list.manage','R',j.created_by,j.branch) and concat_ws(' ',t.title,j.number) ilike '%'||p_query||'%' order by t.completed_at nulls first,t.due_on limit 500)s;
 elsif p_kind='assignees' then
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.display_name)),'[]') into result from binderclip.members m where m.tenant_id=p_tenant and m.enabled and (m.branch=member_row.branch or binderclip.allowed(p_tenant,'settings.members.manage','R'));
 elsif p_kind='payables' then
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(b)||jsonb_build_object('supplier_name',c.name,'job_number',j.number,'total',round(b.quantity*b.unit_rate,2),'paid',(select coalesce(sum(p.amount),0) from binderclip.supplier_payments p where p.bill_id=b.id)) v from binderclip.supplier_bills b join binderclip.masters c on c.id=b.supplier_id join binderclip.jobs j on j.id=b.job_id where b.tenant_id=p_tenant and b.status='Matched' and binderclip.allowed(p_tenant,'finance.payments.manage','R',b.created_by,b.branch) and concat_ws(' ',b.number,c.name,j.number) ilike '%'||p_query||'%' order by b.due_date limit 500)s;
 elsif p_kind='search' then
  if length(trim(p_query))<2 then raise exception 'Enter at least two search characters';end if;
  result:=jsonb_build_object('jobs',public.bc_read(p_tenant,'jobs',null,p_query),'customers',public.bc_read(p_tenant,'customers',null,p_query),'suppliers',public.bc_read(p_tenant,'suppliers',null,p_query),'invoices',public.bc_read(p_tenant,'invoices',null,p_query),'enquiries',public.bc_workspace(p_tenant,'enquiries',null,p_query),'quotes',public.bc_workspace(p_tenant,'quotes',null,p_query));
 else raise exception 'Unknown workspace screen';end if;
 return binderclip.decimals(result);
end $$;

create function public.bc_report(p_tenant uuid,p_kind text,p_as_of date default current_date,p_from date default null,p_to date default null,p_action text default 'R') returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);result jsonb;
begin
 if p_action not in('R','X') or p_as_of>current_date or (p_from is not null and p_to is not null and p_from>p_to) then raise exception 'Invalid report filters';end if;
 perform binderclip.require(p_tenant,'reports.finance.view',p_action,auth.uid(),member_row.branch);
 if p_kind='receivables' then
  select coalesce(jsonb_agg(v),'[]') into result from(select jsonb_build_object('number',i.number,'id',i.id,'party',i.snapshot->'customer'->>'name','currency',i.currency,'due_date',i.due_date,'outstanding',i.total-coalesce((select sum(r.amount) from binderclip.receipts r where r.invoice_id=i.id and r.received_on<=p_as_of),0),'days_overdue',greatest(p_as_of-i.due_date,0)) v from binderclip.invoices i where i.tenant_id=p_tenant and i.status in('Issued','Partially Paid','Paid') and i.invoice_date<=p_as_of and binderclip.allowed(p_tenant,'reports.finance.view',p_action,i.created_by,i.branch) and binderclip.allowed(p_tenant,'customers.ledger.view',p_action,i.created_by,i.branch))s where (v->>'outstanding')::numeric>0;
 elsif p_kind='payables' then
  select coalesce(jsonb_agg(v),'[]') into result from(select jsonb_build_object('number',b.number,'id',b.id,'party',c.name,'currency',b.currency,'due_date',b.due_date,'outstanding',round(b.quantity*b.unit_rate,2)-coalesce((select sum(p.amount) from binderclip.supplier_payments p where p.bill_id=b.id and p.paid_on<=p_as_of),0),'days_overdue',greatest(p_as_of-b.due_date,0)) v from binderclip.supplier_bills b join binderclip.masters c on c.id=b.supplier_id where b.tenant_id=p_tenant and b.status='Matched' and b.invoice_date<=p_as_of and binderclip.allowed(p_tenant,'reports.finance.view',p_action,b.created_by,b.branch) and binderclip.allowed(p_tenant,'suppliers.ledger.view',p_action,b.created_by,b.branch))s where (v->>'outstanding')::numeric>0;
 elsif p_kind in('trial_balance','income_statement') then
  select coalesce(jsonb_agg(v),'[]') into result from(select jsonb_build_object('account',l.account,'debit',sum(l.debit),'credit',sum(l.credit),'balance',sum(l.debit-l.credit)) v from binderclip.journal_lines l join binderclip.journals e on e.id=l.entry_id where e.tenant_id=p_tenant and e.created_at::date<=p_as_of and (p_from is null or e.created_at::date>=p_from) and (p_to is null or e.created_at::date<=p_to) and binderclip.allowed(p_tenant,'reports.finance.view',p_action,e.created_by,e.branch) and binderclip.allowed(p_tenant,'reports.journal.view',p_action,e.created_by,e.branch) and (p_kind='trial_balance' or left(l.account,1) in('4','5')) group by l.account order by l.account)s;
 elsif p_kind='job_profitability' then
  select coalesce(jsonb_agg(v),'[]') into result from(select jsonb_build_object('number',j.number,'id',j.id,'customer',c.name,'status',j.status)||binderclip.figures(p_tenant,j.id) v from binderclip.jobs j join binderclip.masters c on c.id=j.customer_id where j.tenant_id=p_tenant and j.created_at::date<=p_as_of and (p_from is null or j.created_at::date>=p_from) and (p_to is null or j.created_at::date<=p_to) and binderclip.allowed(p_tenant,'reports.finance.view',p_action,j.created_by,j.branch) and binderclip.allowed(p_tenant,'costs.detail.manage','R',j.created_by,j.branch) and binderclip.allowed(p_tenant,'jobs.list.manage','R',j.created_by,j.branch) order by j.created_at desc)s;
 else raise exception 'Unknown financial report';end if;
 return binderclip.decimals(jsonb_build_object('as_of',p_as_of,'currency',(select currency from binderclip.companies where id=p_tenant),'rows',result));
end $$;

revoke all on function binderclip.workflow_gate() from public,anon,authenticated;
revoke all on function public.bc_workflow(uuid,text,jsonb),public.bc_workspace(uuid,text,uuid,text,text),public.bc_report(uuid,text,date,date,date,text) from public,anon,authenticated;
grant execute on function public.bc_workflow(uuid,text,jsonb),public.bc_workspace(uuid,text,uuid,text,text),public.bc_report(uuid,text,date,date,date,text) to authenticated;
commit;
