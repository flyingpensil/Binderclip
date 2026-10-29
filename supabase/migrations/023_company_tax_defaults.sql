begin;
create function binderclip.company_tax_defaults(t uuid,v jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c binderclip.companies;result jsonb:=v;begin
 select * into strict c from binderclip.companies where id=t;
 if coalesce(v->>'side','SELL')='SELL' then
  result:=result||jsonb_build_object('tax_rate',coalesce(nullif(v->>'tax_rate','')::numeric,c.default_vat_rate));
  if (result->>'tax_rate')::numeric=0 and c.default_vat_rate=0 then result:=result||jsonb_build_object('exemption',coalesce(nullif(v->>'exemption',''),c.default_tax_reason));end if;
 end if;return result;
end $$;
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_command(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'result:=binderclip.command_snapshot(p_tenant,p_action,data);','if p_action=''cost.add'' then data:=binderclip.company_tax_defaults(p_tenant,data);end if; result:=binderclip.command_snapshot(p_tenant,p_action,data);');execute definition;
 definition:=pg_get_functiondef('public.bc_costsheet(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'result:=binderclip.costsheet_snapshot(p_tenant,p_action,data);','if p_action=''line.save'' then data:=binderclip.company_tax_defaults(p_tenant,data);end if; result:=binderclip.costsheet_snapshot(p_tenant,p_action,data);');execute definition;
 definition:=pg_get_functiondef('public.bc_workflow(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'result:=binderclip.workflow_snapshot(p_tenant,p_action,data);','if p_action=''quote.line'' then data:=binderclip.company_tax_defaults(p_tenant,data);end if; result:=binderclip.workflow_snapshot(p_tenant,p_action,data);');execute definition;
 definition:=pg_get_functiondef('binderclip.practical_snapshot(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'coalesce((p_data->>''sell_vat'')::numeric,5)','coalesce((p_data->>''sell_vat'')::numeric,co.default_vat_rate)');
 definition:=replace(definition,'coalesce(p_data->>''exemption'','''')','coalesce(p_data->>''exemption'',co.default_tax_reason)');execute definition;
end $$;

create function binderclip.company_tax_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare status_value text;begin
 if TG_TABLE_NAME='invoice_items' then select snapshot->'company'->>'tax_status' into status_value from binderclip.invoices where id=new.invoice_id;
 else
  select tax_status into status_value from binderclip.companies where id=new.tenant_id;
  if new.side<>'SELL' then return new;end if;
  if TG_TABLE_NAME='cost_lines' and exists(select 1 from binderclip.invoice_items x join binderclip.invoices i on i.id=x.invoice_id where x.line_id=new.id and coalesce(i.snapshot->'company'->>'tax_status','Unconfirmed')<>'Not VAT registered') then return new;end if;
 end if;
 if status_value='Not VAT registered' and new.tax_rate<>0 then raise exception 'This company is not VAT registered. Use 0 percent sales VAT and an appropriate reason';end if;
 return new;
end $$;
create trigger company_tax_guard before insert or update on binderclip.cost_lines for each row execute function binderclip.company_tax_guard();
create trigger company_tax_guard before insert or update on binderclip.quotation_lines for each row execute function binderclip.company_tax_guard();
create trigger company_tax_guard before insert or update on binderclip.invoice_items for each row execute function binderclip.company_tax_guard();

-- Preserve the tax accounting mode on each source document. Existing rows keep
-- the existing recoverable treatment; no posted journals are rewritten.
alter table binderclip.purchase_invoices add column vat_recoverable boolean not null default true;
alter table binderclip.supplier_bills add column vat_recoverable boolean not null default true;
create function binderclip.supplier_tax_snapshot() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='purchase_invoices' then
  if TG_OP='UPDATE' then new.vat_recoverable:=old.vat_recoverable;
  else select tax_status<>'Not VAT registered' into new.vat_recoverable from binderclip.companies where id=new.tenant_id;end if;
 else
  if TG_OP='UPDATE' and old.tax_amount>0 then new.vat_recoverable:=old.vat_recoverable;
  elsif new.purchase_invoice_id is not null then select vat_recoverable into new.vat_recoverable from binderclip.purchase_invoices where id=new.purchase_invoice_id;
  else select tax_status<>'Not VAT registered' into new.vat_recoverable from binderclip.companies where id=new.tenant_id;end if;
 end if;return new;
end $$;
create trigger a_tax_snapshot before insert or update on binderclip.purchase_invoices for each row execute function binderclip.supplier_tax_snapshot();
create trigger a_tax_snapshot before insert or update on binderclip.supplier_bills for each row execute function binderclip.supplier_tax_snapshot();
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.post_supplier_vat()'::regprocedure);
 definition:=replace(definition,'''Input VAT ''||new.number','''Supplier VAT ''||new.number');
 definition:=replace(definition,'''1200 VAT recoverable''','case when new.vat_recoverable then ''1200 VAT recoverable'' else ''5000 Direct costs'' end');execute definition;
 definition:=pg_get_functiondef('binderclip.figures(uuid,uuid)'::regprocedure);
 definition:=replace(definition,'binderclip.base(b.quantity,b.unit_rate,b.fx_rate)','(binderclip.base(b.quantity,b.unit_rate,b.fx_rate)+case when b.vat_recoverable then 0 else round(b.tax_amount*b.fx_rate,2) end)');execute definition;
end $$;
revoke all on function binderclip.company_tax_defaults(uuid,jsonb),binderclip.company_tax_guard(),binderclip.supplier_tax_snapshot() from public,anon,authenticated;
commit;
