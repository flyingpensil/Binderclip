begin;
create function public.bc_session() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=binderclip.actor(); result jsonb;
begin
 update binderclip.members m set user_id=u where m.user_id is null and m.enabled
 and m.email=(select lower(email) from auth.users where id=u);
 select jsonb_agg(jsonb_build_object('id',m.id,'tenant_id',m.tenant_id,'display_name',m.display_name,'email',m.email,
 'branch',m.branch,'company',to_jsonb(c),'grants',(select coalesce(jsonb_agg(to_jsonb(g)-'role_id'),'[]') from binderclip.grants g
 join binderclip.member_roles mr on mr.role_id=g.role_id where mr.member_id=m.id and mr.tenant_id=m.tenant_id))) into result
 from binderclip.members m join binderclip.companies c on c.id=m.tenant_id
 where m.user_id=u and m.enabled and m.email=(select lower(email) from auth.users where id=u);
 if result is null then raise exception 'This Google account has not been invited to Binderclip' using errcode='42501';end if;
 return jsonb_build_object('memberships',result,'permissions',(select jsonb_agg(to_jsonb(p) order by path,action) from binderclip.permissions p),'user_id',u);
end $$;

create function public.bc_read(p_tenant uuid,p_kind text,p_id uuid default null,p_query text default '',p_action text default 'R')
returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);result jsonb;path text;j binderclip.jobs;i binderclip.invoices;
begin
 if p_action not in ('R','X') then raise exception 'Invalid read action';end if;
 if p_kind='overview' then
  perform binderclip.require(p_tenant,'overview.dashboard.view','R',auth.uid(),m.branch);
  result:=jsonb_build_object('active_jobs',(select count(*) from binderclip.jobs r where r.tenant_id=p_tenant and r.status not in ('Closed','Cancelled') and binderclip.allowed(p_tenant,'overview.dashboard.view','R',r.created_by,r.branch) and binderclip.allowed(p_tenant,'jobs.list.manage','R',r.created_by,r.branch)),
   'customers',(select count(*) from binderclip.masters r where r.tenant_id=p_tenant and r.kind='customers' and binderclip.allowed(p_tenant,'overview.dashboard.view','R',r.created_by,r.branch) and binderclip.allowed(p_tenant,'customers.list.manage','R',r.created_by,r.branch)),
   'receivables',(select coalesce(sum(r.total-r.paid),0) from binderclip.invoices r join binderclip.companies c on c.id=r.tenant_id where r.tenant_id=p_tenant and r.currency=c.currency and r.status in ('Issued','Partially Paid') and binderclip.allowed(p_tenant,'overview.dashboard.view','R',r.created_by,r.branch) and binderclip.allowed(p_tenant,'invoicing.list.manage','R',r.created_by,r.branch)),
   'pending_bills',(select count(*) from binderclip.supplier_bills r where r.tenant_id=p_tenant and r.status='Pending' and binderclip.allowed(p_tenant,'overview.dashboard.view','R',r.created_by,r.branch) and binderclip.allowed(p_tenant,'costs.detail.manage','R',r.created_by,r.branch)),
   'jobs',(select coalesce(jsonb_agg(v),'[]') from(select to_jsonb(r)||jsonb_build_object('customer_name',c.name) v from binderclip.jobs r join binderclip.masters c on c.id=r.customer_id where r.tenant_id=p_tenant and binderclip.allowed(p_tenant,'overview.dashboard.view','R',r.created_by,r.branch) and binderclip.allowed(p_tenant,'jobs.list.manage','R',r.created_by,r.branch) order by r.created_at desc limit 6)s));
 elsif p_kind in ('customers','suppliers','rates','tariffs') then
  path:=case when p_kind in ('rates','tariffs') then 'masters.rates.manage' else p_kind||'.list.manage' end;
  -- Exports use the ledger permission and retain its own data scope.
  if p_action='X' then raise exception 'Use the ledger export endpoint';end if;
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(r) v from binderclip.masters r where r.tenant_id=p_tenant and r.kind=p_kind
   and (p_id is null or r.id=p_id) and binderclip.allowed(p_tenant,path,'R',r.created_by,r.branch)
   and (p_query='' or concat_ws(' ',r.code,r.name,r.data::text) ilike '%'||p_query||'%') order by r.created_at desc limit 500) s;
 elsif p_kind='jobs' then
  if p_action<>'R' then raise exception 'Job export is not configured';end if;
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(r)||jsonb_build_object('customer_name',c.name) v
   from binderclip.jobs r join binderclip.masters c on c.id=r.customer_id and c.tenant_id=r.tenant_id
   where r.tenant_id=p_tenant and (p_id is null or r.id=p_id) and binderclip.allowed(p_tenant,'jobs.list.manage','R',r.created_by,r.branch)
   and (p_query='' or concat_ws(' ',r.number,c.name,r.status,r.data::text) ilike '%'||p_query||'%') order by r.created_at desc limit 500)s;
 elsif p_kind='job' then
  select * into j from binderclip.jobs where id=p_id and tenant_id=p_tenant;
  if not found then raise exception 'Job unavailable';end if;
  perform binderclip.require(p_tenant,'jobs.list.manage','R',j.created_by,j.branch);
  result:=to_jsonb(j)||jsonb_build_object('customer',(select to_jsonb(c) from binderclip.masters c where c.id=j.customer_id));
  if binderclip.allowed(p_tenant,'costs.detail.manage','R',j.created_by,j.branch) then
   result:=result||jsonb_build_object('figures',binderclip.figures(p_tenant,j.id),'lines',(select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('supplier_name',s.name)),'[]') from binderclip.cost_lines l left join binderclip.masters s on s.id=l.supplier_id where l.job_id=j.id and l.tenant_id=p_tenant),
    'bills',(select coalesce(jsonb_agg(to_jsonb(b)),'[]') from binderclip.supplier_bills b where b.job_id=j.id and b.tenant_id=p_tenant));
  end if;
  result:=result||jsonb_build_object('invoices',(select coalesce(jsonb_agg(distinct to_jsonb(v)),'[]') from binderclip.invoices v join binderclip.invoice_items x on x.invoice_id=v.id
   where x.job_id=j.id and v.tenant_id=p_tenant and binderclip.allowed(p_tenant,'invoicing.list.manage','R',v.created_by,v.branch)),
   'audit',(select coalesce(jsonb_agg(v),'[]') from(select to_jsonb(a) v from binderclip.audit a where a.tenant_id=p_tenant and a.object_id=j.id order by a.created_at desc limit 50)s));
 elsif p_kind='invoices' then
  if p_action<>'R' then raise exception 'Use ledger export for invoice rows';end if;
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(r)||jsonb_build_object('display_status',case when r.status in ('Issued','Partially Paid') and r.due_date<current_date then 'Overdue' else r.status end) v
   from binderclip.invoices r where r.tenant_id=p_tenant and (p_id is null or r.id=p_id)
   and binderclip.allowed(p_tenant,'invoicing.list.manage','R',r.created_by,r.branch)
   and (p_query='' or concat_ws(' ',r.number,r.snapshot::text,r.status) ilike '%'||p_query||'%' or exists(select 1 from binderclip.invoice_items x join binderclip.jobs y on y.id=x.job_id where x.invoice_id=r.id and y.number ilike '%'||p_query||'%')) order by r.created_at desc limit 500)s;
 elsif p_kind in ('invoice','invoice_print') then
  select * into i from binderclip.invoices where id=p_id and tenant_id=p_tenant;
  if not found then raise exception 'Invoice unavailable';end if;
  perform binderclip.require(p_tenant,case when p_kind='invoice_print' then 'invoicing.detail.print' else 'invoicing.list.manage' end,
   case when p_kind='invoice_print' then 'X' else 'R' end,i.created_by,i.branch);
  result:=to_jsonb(i)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('job_number',j.number)),'[]') from binderclip.invoice_items x join binderclip.jobs j on j.id=x.job_id where x.invoice_id=i.id),
   'receipts',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from binderclip.receipts r where r.invoice_id=i.id));
 elsif p_kind in ('customer_ledger','supplier_ledger') then
  path:=case when p_kind='customer_ledger' then 'customers.ledger.view' else 'suppliers.ledger.view' end;
  if not exists(select 1 from binderclip.masters r where r.id=p_id and r.tenant_id=p_tenant and r.kind=case when p_kind='customer_ledger' then 'customers' else 'suppliers' end
   and binderclip.allowed(p_tenant,path,p_action,r.created_by,r.branch)) then raise exception 'Ledger unavailable' using errcode='42501';end if;
  if p_kind='customer_ledger' then
   select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('jobs',(select jsonb_agg(distinct j.number) from binderclip.invoice_items x join binderclip.jobs j on j.id=x.job_id where x.invoice_id=r.id))),'[]') into result
   from binderclip.invoices r where r.tenant_id=p_tenant and r.customer_id=p_id and binderclip.allowed(p_tenant,path,p_action,r.created_by,r.branch)
   and (p_query='' or r.number ilike '%'||p_query||'%' or exists(select 1 from binderclip.invoice_items x join binderclip.jobs j on j.id=x.job_id where x.invoice_id=r.id and j.number ilike '%'||p_query||'%'));
  else
   select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('job_number',j.number,'amount',round(b.quantity*b.unit_rate,2))),'[]') into result from binderclip.supplier_bills b join binderclip.jobs j on j.id=b.job_id
    where b.tenant_id=p_tenant and b.supplier_id=p_id and binderclip.allowed(p_tenant,path,p_action,b.created_by,b.branch)
    and (p_query='' or b.number ilike '%'||p_query||'%' or j.number ilike '%'||p_query||'%');
  end if;
 elsif p_kind='commitments' then
  perform binderclip.require(p_tenant,'suppliers.ledger.view','R',null,m.branch);
  select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('job_number',j.number,'bill_status',b.status)),'[]') into result
  from binderclip.cost_lines l join binderclip.jobs j on j.id=l.job_id left join binderclip.supplier_bills b on b.line_id=l.id
  where l.tenant_id=p_tenant and l.supplier_id=p_id and l.side='BUY' and binderclip.allowed(p_tenant,'suppliers.ledger.view','R',l.created_by,l.branch);
 elsif p_kind='journal' then
  select coalesce(jsonb_agg(v),'[]') into result from(select to_jsonb(e)||jsonb_build_object('lines',(select jsonb_agg(to_jsonb(l)) from binderclip.journal_lines l where l.entry_id=e.id)) v
  from binderclip.journals e where e.tenant_id=p_tenant and binderclip.allowed(p_tenant,'reports.journal.view',p_action,e.created_by,e.branch)
  and (p_query='' or concat_ws(' ',e.source,e.description) ilike '%'||p_query||'%') order by e.created_at desc limit 500)s;
 elsif p_kind='roles' then
  perform binderclip.require(p_tenant,'settings.roles.manage','R');
  select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('grants',(select coalesce(jsonb_agg(to_jsonb(g)),'[]') from binderclip.grants g where g.role_id=r.id))),'[]') into result from binderclip.roles r where r.tenant_id=p_tenant;
 elsif p_kind='members' then
  perform binderclip.require(p_tenant,'settings.members.manage','R');
  select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('roles',(select coalesce(jsonb_agg(r.role_id),'[]') from binderclip.member_roles r where r.member_id=a.id))),'[]') into result from binderclip.members a where a.tenant_id=p_tenant;
 else raise exception 'Unknown screen';end if;
 return binderclip.decimals(coalesce(result,'[]'));
end $$;

create function binderclip.match_post(t uuid,bid uuid) returns void language plpgsql security definer set search_path='' as $$
declare b binderclip.supplier_bills;l binderclip.cost_lines;expected numeric;actual numeric;delta numeric;
begin
 select * into strict b from binderclip.supplier_bills where id=bid and tenant_id=t;
 select * into strict l from binderclip.cost_lines where id=b.line_id and tenant_id=t;
 expected:=binderclip.base(l.quantity,l.unit_rate,l.fx_rate);actual:=binderclip.base(b.quantity,b.unit_rate,b.fx_rate);delta:=actual-expected;
 perform binderclip.post(t,'bill:'||b.id,'Supplier invoice '||b.number,b.branch,jsonb_build_array(
  jsonb_build_array('2000 Accrued costs',expected,0),jsonb_build_array('5000 Direct costs',greatest(delta,0),greatest(-delta,0)),jsonb_build_array('2100 Payables',0,actual)));
 update binderclip.supplier_bills set status='Matched' where id=b.id;
end $$;

create function public.bc_command(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
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
   select * into r from binderclip.masters where id=target and tenant_id=p_tenant and masters.kind=bc_command.kind for update;
   if not found then raise exception 'Record unavailable';end if;
   perform binderclip.require(p_tenant,path,'U',r.created_by,r.branch);
  else perform binderclip.require(p_tenant,path,'C',u,m.branch);end if;
  if length(trim(p_data->>'name'))<1 or length(trim(p_data->>'code'))<1 then raise exception 'Code and name are required';end if;
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
  if coalesce(trim(p_data->>'number'),'')='' or coalesce(trim(d->>'pol'),'')='' or coalesce(trim(d->>'pod'),'')='' then raise exception 'Job number and routing are required';end if;
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
  if j.status='Draft' or not exists(select 1 from binderclip.cost_lines where job_id=j.id and side='SELL') or exists(select 1 from binderclip.cost_lines l left join binderclip.supplier_bills b on b.line_id=l.id where l.job_id=j.id and l.side='BUY' and (b.id is null or b.status<>'Matched')) then raise exception 'Book the job and match every buy estimate before approval';end if;
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
  update binderclip.invoices set subtotal=bc_command.subtotal,tax_total=bc_command.tax_total,total=bc_command.subtotal+bc_command.tax_total where id=result;
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
  if not j.approved or not exists(select 1 from binderclip.cost_lines where job_id=j.id and side='SELL') or exists(select 1 from binderclip.cost_lines l left join binderclip.supplier_bills b on b.line_id=l.id where l.job_id=j.id and l.side='BUY' and (b.id is null or b.status<>'Matched'))
   or exists(select 1 from binderclip.cost_lines l left join binderclip.invoice_items x on x.line_id=l.id left join binderclip.invoices v on v.id=x.invoice_id where l.job_id=j.id and l.side='SELL' and (v.id is null or v.status in ('Draft','Approved'))) then raise exception 'Approve costs, match bills and issue all sell charges before locking';end if;
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

revoke all on function public.bc_session(),public.bc_read(uuid,text,uuid,text,text),public.bc_command(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.bc_session(),public.bc_read(uuid,text,uuid,text,text),public.bc_command(uuid,text,jsonb) to authenticated;
revoke all on all functions in schema binderclip from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
