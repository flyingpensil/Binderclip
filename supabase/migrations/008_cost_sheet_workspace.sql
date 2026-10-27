-- Cost-sheet workbench. Existing journal, matching, invoice and lock rules remain authoritative.
begin;
insert into binderclip.permissions(path,action) values
 ('costs.detail.manage','U'),('costs.detail.disapprove','U'),('costs.detail.apply','C'),('costs.detail.print','X');
insert into binderclip.grants(role_id,path,action,scope,can_export)
 select r.id,p.path,p.action,'global',true from binderclip.roles r cross join binderclip.permissions p
 where r.name='Company administrator' on conflict(role_id,path,action) do nothing;

create function public.bc_costsheet(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
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
   'line_values',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'estimated_base',binderclip.base(l.quantity,l.unit_rate,l.fx_rate),'actual_base',case when b.status='Matched' then binderclip.base(b.quantity,b.unit_rate,b.fx_rate) else binderclip.base(l.quantity,l.unit_rate,l.fx_rate) end)),'[]') from binderclip.cost_lines l left join binderclip.supplier_bills b on b.line_id=l.id where l.job_id=target));
 elsif p_action='quotes' then
  perform binderclip.require(p_tenant,'costs.detail.apply','C',job_row.created_by,job_row.branch);
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.number||' · '||q.currency||' · valid until '||q.valid_until)),'[]') into result from binderclip.quotations q where q.tenant_id=p_tenant and q.customer_id=job_row.customer_id and q.status='Approved' and q.valid_until>=current_date and binderclip.allowed(p_tenant,'sales.quotes.manage','R',q.created_by,q.branch);
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
  perform binderclip.log(p_tenant,'costsheet.'||p_action,target,coalesce(reason,''));
 else raise exception 'Unknown cost sheet action';end if;
 return binderclip.decimals(result);
end $$;
revoke all on function public.bc_costsheet(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.bc_costsheet(uuid,text,jsonb) to authenticated;
commit;
