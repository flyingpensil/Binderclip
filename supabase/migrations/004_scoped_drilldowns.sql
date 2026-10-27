-- Upgrade existing installations; do not rerun first-install bootstrap.
begin;
create or replace function public.bc_read(p_tenant uuid,p_kind text,p_id uuid default null,p_query text default '',p_action text default 'R')
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
  result:=to_jsonb(j)||jsonb_build_object('customer',(select case when binderclip.allowed(p_tenant,'customers.list.manage','R',c.created_by,c.branch) then to_jsonb(c) else jsonb_build_object('id',c.id,'code',c.code,'name',c.name,'parent_id',c.parent_id) end from binderclip.masters c where c.id=j.customer_id));
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
  result:=to_jsonb(i)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('job_number',jr.number)),'[]') from binderclip.invoice_items x join binderclip.jobs jr on jr.id=x.job_id where x.invoice_id=i.id),
   'receipts',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from binderclip.receipts r where r.invoice_id=i.id));
 elsif p_kind in ('customer_ledger','supplier_ledger') then
  path:=case when p_kind='customer_ledger' then 'customers.ledger.view' else 'suppliers.ledger.view' end;
  if not exists(select 1 from binderclip.masters r where r.id=p_id and r.tenant_id=p_tenant and r.kind=case when p_kind='customer_ledger' then 'customers' else 'suppliers' end
   and binderclip.allowed(p_tenant,path,p_action,r.created_by,r.branch)) then raise exception 'Ledger unavailable' using errcode='42501';end if;
  if p_kind='customer_ledger' then
   select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('jobs',(select jsonb_agg(distinct jr.number) from binderclip.invoice_items x join binderclip.jobs jr on jr.id=x.job_id where x.invoice_id=r.id))),'[]') into result
   from binderclip.invoices r where r.tenant_id=p_tenant and r.customer_id=p_id and binderclip.allowed(p_tenant,path,p_action,r.created_by,r.branch)
   and (p_query='' or r.number ilike '%'||p_query||'%' or exists(select 1 from binderclip.invoice_items x join binderclip.jobs jr on jr.id=x.job_id where x.invoice_id=r.id and jr.number ilike '%'||p_query||'%'));
  else
   select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('job_number',jr.number,'amount',round(b.quantity*b.unit_rate,2))),'[]') into result from binderclip.supplier_bills b join binderclip.jobs jr on jr.id=b.job_id
    where b.tenant_id=p_tenant and b.supplier_id=p_id and binderclip.allowed(p_tenant,path,p_action,b.created_by,b.branch)
    and (p_query='' or b.number ilike '%'||p_query||'%' or jr.number ilike '%'||p_query||'%');
  end if;
 elsif p_kind='commitments' then
  perform binderclip.require(p_tenant,'suppliers.ledger.view','R',auth.uid(),m.branch);
  select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('job_number',jr.number,'bill_status',b.status)),'[]') into result
  from binderclip.cost_lines l join binderclip.jobs jr on jr.id=l.job_id left join binderclip.supplier_bills b on b.line_id=l.id
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


commit;
