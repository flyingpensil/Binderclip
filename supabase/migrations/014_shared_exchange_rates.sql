begin;
create table binderclip.fx_rates(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,
 from_currency text not null check(from_currency ~ '^[A-Z]{3}$'),from_amount numeric(20,8) not null check(from_amount between 0.00000001 and 999999999999),
 to_currency text not null check(to_currency ~ '^[A-Z]{3}$'),to_amount numeric(20,8) not null check(to_amount between 0.00000001 and 999999999999),
 branch text not null,created_by uuid references auth.users,created_at timestamptz,created_by_name text,updated_by uuid references auth.users,updated_at timestamptz,updated_by_name text,
 check(from_currency<>to_currency));
create unique index on binderclip.fx_rates(tenant_id,least(from_currency,to_currency),greatest(from_currency,to_currency));
alter table binderclip.fx_rates enable row level security;
revoke all on binderclip.fx_rates from public,anon,authenticated;
create trigger record_tracking before insert or update on binderclip.fx_rates for each row execute function binderclip.stamp_record();

create function binderclip.fx_direct(t uuid,a text,b text) returns numeric language sql stable security definer set search_path='' as $$
 select case when e.from_currency=a then e.to_amount/e.from_amount else e.from_amount/e.to_amount end from binderclip.fx_rates e
 where e.tenant_id=t and ((e.from_currency=a and e.to_currency=b) or (e.from_currency=b and e.to_currency=a))
$$;
create function binderclip.fx_quote(t uuid,a text,b text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rate numeric;base text;source text;begin
 if a=b then return jsonb_build_object('rate',1,'source','Same currency','date',current_date);end if;
 rate:=binderclip.fx_direct(t,a,b);source:=a||' → '||b;
 if rate is null then
  select currency into strict base from binderclip.companies where id=t;
  rate:=binderclip.fx_direct(t,a,base)*binderclip.fx_direct(t,base,b);source:=a||' → '||base||' → '||b;
 end if;
 if rate is null then raise exception 'No shared exchange rate for % to %. Add it under Accounts & rates → Currency exchange.',a,b;end if;
 rate:=round(rate,8);if rate<=0 or rate>=100000000 then raise exception 'Exchange rate is outside the supported range';end if;
 return jsonb_build_object('rate',rate,'source','Shared currency exchange: '||source,'date',current_date);
end $$;
create function public.bc_rates(p_tenant uuid,p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);row_value binderclip.fx_rates;target uuid:=nullif(p_data->>'id','')::uuid;result jsonb;
begin
 if p_action='quote' then result:=binderclip.fx_quote(p_tenant,p_data->>'from_currency',p_data->>'to_currency');
 elsif p_action='list' then
  select coalesce(jsonb_agg(to_jsonb(e) order by e.from_currency,e.to_currency),'[]') into result from binderclip.fx_rates e where e.tenant_id=p_tenant and binderclip.allowed(p_tenant,'masters.rates.manage','R',e.created_by,e.branch);
 elsif p_action='save' then
  if p_data->>'from_currency' is null or p_data->>'to_currency' is null or nullif(p_data->>'from_amount','') is null or nullif(p_data->>'to_amount','') is null then raise exception 'Both currencies and both amounts are required';end if;
  if target is null then
   perform binderclip.require(p_tenant,'masters.rates.manage','C',auth.uid(),member_row.branch);
   insert into binderclip.fx_rates(tenant_id,from_currency,from_amount,to_currency,to_amount,branch) values(p_tenant,p_data->>'from_currency',(p_data->>'from_amount')::numeric,p_data->>'to_currency',(p_data->>'to_amount')::numeric,member_row.branch) returning id into target;
  else
   select * into strict row_value from binderclip.fx_rates where id=target and tenant_id=p_tenant for update;
   perform binderclip.require(p_tenant,'masters.rates.manage','U',row_value.created_by,row_value.branch);
   update binderclip.fx_rates set from_currency=p_data->>'from_currency',from_amount=(p_data->>'from_amount')::numeric,to_currency=p_data->>'to_currency',to_amount=(p_data->>'to_amount')::numeric where id=target;
  end if;
  perform binderclip.log(p_tenant,'currency.rate.save',target,'Shared currency pair updated');result:=jsonb_build_object('id',target);
 else raise exception 'Unknown currency action';end if;
 return binderclip.decimals(binderclip.with_tracking(p_tenant,result));
end $$;

alter table binderclip.cost_lines add column fx_source text not null default 'Saved document rate',add column fx_date date;
alter table binderclip.purchase_invoices add column fx_source text not null default 'Saved document rate',add column fx_date date;
alter table binderclip.quotations add column fx_source text not null default 'Saved document rate',add column fx_date date;
-- Private snapshot commands retain source-document rates during document transfer.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_command(uuid,text,jsonb)'::regprocedure);
 execute replace(definition,'FUNCTION public.bc_command(','FUNCTION binderclip.command_snapshot(');
 definition:=pg_get_functiondef('public.bc_costsheet(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'perform public.bc_command(p_tenant,''cost.add''','perform binderclip.command_snapshot(p_tenant,''cost.add''');
 execute replace(definition,'FUNCTION public.bc_costsheet(','FUNCTION binderclip.costsheet_snapshot(');
 definition:=pg_get_functiondef('public.bc_workflow(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'perform public.bc_command(p_tenant,''cost.add''','perform binderclip.command_snapshot(p_tenant,''cost.add''');
 execute replace(definition,'FUNCTION public.bc_workflow(','FUNCTION binderclip.workflow_snapshot(');
 definition:=pg_get_functiondef('public.bc_practical(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'reason text;','reason text;shared_quote jsonb;');
 definition:=replace(definition,'sell_currency:=c.currency;sell_fx:=case when c.currency=co.currency then 1 else nullif(c.data->>''default_fx_rate'','''')::numeric end;',
  'sell_currency:=c.currency;shared_quote:=binderclip.fx_quote(p_tenant,sell_currency,co.currency);sell_fx:=(shared_quote->>''rate'')::numeric;');
 definition:=replace(definition,'v:=public.bc_command(p_tenant,''cost.add''','v:=binderclip.command_snapshot(p_tenant,''cost.add''');
 definition:=replace(definition,'v:=public.bc_command(p_tenant,''bill.match''','v:=binderclip.command_snapshot(p_tenant,''bill.match''');
 definition:=replace(definition,'set comments=item.comments,unit=item.unit where id in(buy_id,sell_id)',
  'set comments=item.comments,unit=item.unit,fx_source=case when id=buy_id then purchase.fx_source else shared_quote->>''source'' end,fx_date=case when id=buy_id then purchase.fx_date else current_date end where id in(buy_id,sell_id)');
 execute replace(definition,'FUNCTION public.bc_practical(','FUNCTION binderclip.practical_snapshot(');
end $$;

create or replace function public.bc_command(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);data jsonb:=p_data;q jsonb;result jsonb;base text;
begin
 select currency into strict base from binderclip.companies where id=p_tenant;
 if p_action='master.save' and p_data->>'kind'='customers' then data:=jsonb_set(data,'{data}',coalesce(data->'data','{}')-'default_fx_rate'-'default_fx_source');end if;
 if p_action in('cost.add','bill.match') then q:=binderclip.fx_quote(p_tenant,coalesce(data->>'currency',base),base);data:=data||jsonb_build_object('fx_rate',q->'rate');end if;
 result:=binderclip.command_snapshot(p_tenant,p_action,data);
 if p_action='cost.add' then update binderclip.cost_lines set fx_source=q->>'source',fx_date=current_date where id=(result->>'id')::uuid;end if;
 if p_action='invoice.generate' then
  update binderclip.invoices set fx_source=coalesce((select string_agg(distinct l.fx_source,'; ') from binderclip.invoice_items x join binderclip.cost_lines l on l.id=x.line_id where x.invoice_id=(result->>'id')::uuid),'Saved document rate'),fx_date=current_date where id=(result->>'id')::uuid;
 end if;
 return result;
end $$;
create or replace function public.bc_costsheet(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);data jsonb:=p_data;q jsonb;result jsonb;base text;l binderclip.cost_lines;
begin
 if p_action='line.save' then
  select currency into strict base from binderclip.companies where id=p_tenant;
  select * into l from binderclip.cost_lines where id=nullif(data->>'line_id','')::uuid and tenant_id=p_tenant;
  if l.id is not null and l.currency=data->>'currency' then q:=jsonb_build_object('rate',l.fx_rate,'source',l.fx_source);else q:=binderclip.fx_quote(p_tenant,data->>'currency',base);end if;
  data:=data||jsonb_build_object('fx_rate',q->'rate');
 end if;
 result:=binderclip.costsheet_snapshot(p_tenant,p_action,data);
 if p_action='line.save' then update binderclip.cost_lines set fx_source=q->>'source',fx_date=coalesce(fx_date,current_date) where id=(result->>'id')::uuid;end if;
 return result;
end $$;
create or replace function public.bc_workflow(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);data jsonb:=p_data;q jsonb;result jsonb;base text;old_row binderclip.quotations;
begin
 if p_action='quote.save' then
  select currency into strict base from binderclip.companies where id=p_tenant;
  select * into old_row from binderclip.quotations where id=nullif(data->>'id','')::uuid and tenant_id=p_tenant;
  if old_row.id is not null and old_row.currency=data->>'currency' then q:=jsonb_build_object('rate',old_row.fx_rate,'source',old_row.fx_source);else q:=binderclip.fx_quote(p_tenant,data->>'currency',base);end if;
  data:=data||jsonb_build_object('fx_rate',q->'rate');
 end if;
 result:=binderclip.workflow_snapshot(p_tenant,p_action,data);
 if p_action='quote.save' then update binderclip.quotations set fx_source=q->>'source',fx_date=coalesce(fx_date,current_date) where id=(result->>'id')::uuid;end if;
 return result;
end $$;
create or replace function public.bc_practical(p_tenant uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);data jsonb:=p_data;q jsonb;result jsonb;base text;old_row binderclip.purchase_invoices;inv binderclip.invoices;
begin
 if p_action='purchase.save' then
  select currency into strict base from binderclip.companies where id=p_tenant;
  select * into old_row from binderclip.purchase_invoices where id=nullif(data->>'id','')::uuid and tenant_id=p_tenant;
  if old_row.id is not null and old_row.currency=data->>'currency' then q:=jsonb_build_object('rate',old_row.fx_rate,'source',old_row.fx_source);else q:=binderclip.fx_quote(p_tenant,data->>'currency',base);end if;
  data:=data||jsonb_build_object('fx_rate',q->'rate');
 elsif p_action='invoice.save' then
  select * into inv from binderclip.invoices where id=nullif(data->>'id','')::uuid and tenant_id=p_tenant;
  data:=data||jsonb_build_object('fx_source',inv.fx_source,'fx_date',inv.fx_date);
 end if;
 result:=binderclip.practical_snapshot(p_tenant,p_action,data);
 if p_action='purchase.save' then update binderclip.purchase_invoices set fx_source=q->>'source',fx_date=coalesce(fx_date,current_date) where id=(result->>'id')::uuid;end if;
 return result;
end $$;
-- Shared conversion must not depend on removed customer-level FX preferences.
create or replace function binderclip.validate_practical_fields() returns trigger language plpgsql security definer set search_path='' as $$
declare value text;begin
 if TG_TABLE_NAME='jobs' and new.data ? 'supplier_ids' then
  if jsonb_typeof(new.data->'supplier_ids')<>'array' or jsonb_array_length(new.data->'supplier_ids')>100 then raise exception 'Choose valid job suppliers';end if;
  for value in select jsonb_array_elements_text(new.data->'supplier_ids') loop
   if not exists(select 1 from binderclip.masters s where s.id=value::uuid and s.tenant_id=new.tenant_id and s.kind='suppliers' and binderclip.allowed(new.tenant_id,'suppliers.list.manage','R',s.created_by,s.branch)) then raise exception 'Selected supplier unavailable';end if;
  end loop;
 end if;return new;
end $$;
revoke all on function binderclip.fx_direct(uuid,text,text),binderclip.fx_quote(uuid,text,text),binderclip.command_snapshot(uuid,text,jsonb),binderclip.costsheet_snapshot(uuid,text,jsonb),binderclip.workflow_snapshot(uuid,text,jsonb),binderclip.practical_snapshot(uuid,text,jsonb),public.bc_rates(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.bc_rates(uuid,text,jsonb) to authenticated;
commit;
