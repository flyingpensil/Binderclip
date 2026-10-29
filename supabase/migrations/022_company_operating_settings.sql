begin;
alter table binderclip.companies
 add column country_code text not null default '' check(country_code='' or country_code ~ '^[A-Z]{2}$'),
 add column timezone text not null default 'Asia/Dubai',
 add column tax_status text not null default 'Unconfirmed' check(tax_status in('Unconfirmed','VAT registered','Not VAT registered')),
 add column default_vat_rate numeric(5,2) not null default 5 check(default_vat_rate between 0 and 100),
 add column default_tax_reason text not null default '' check(length(default_tax_reason)<=240);

create function binderclip.company_has_finance(t uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from binderclip.cost_lines where tenant_id=t)
 or exists(select 1 from binderclip.quotations where tenant_id=t)
 or exists(select 1 from binderclip.purchase_invoices where tenant_id=t)
 or exists(select 1 from binderclip.invoices where tenant_id=t)
 or exists(select 1 from binderclip.journals where tenant_id=t)
$$;
create function binderclip.company_settings(t uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(c)||jsonb_build_object('financial_settings_locked',binderclip.company_has_finance(t)) from binderclip.companies c where id=t
$$;
create function binderclip.validate_company_settings() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from pg_timezone_names where name=new.timezone) then raise exception 'Choose a valid company timezone';end if;
 if TG_OP='UPDATE' and (new.currency,new.timezone) is distinct from(old.currency,old.timezone) and binderclip.company_has_finance(old.id) then raise exception 'Accounting currency and timezone are locked after financial documents exist. Use a controlled accounting migration to change them';end if;
 if new.tax_status<>'Unconfirmed' and new.country_code='' then raise exception 'Choose the company country before confirming tax settings';end if;
 if new.tax_status='VAT registered' then
  if trim(new.trn)='' then raise exception 'Enter the company VAT registration number before confirming VAT registration';end if;
  if new.country_code='AE' and new.trn !~ '^[0-9]{15}$' then raise exception 'A UAE TRN must contain 15 digits. Confirm the number with the client';end if;
  if new.country_code='AE' and new.currency<>'AED' then raise exception 'The current UAE VAT setup requires AED accounting for local-currency tax reporting';end if;
 elsif new.tax_status='Not VAT registered' then new.default_vat_rate:=0;new.default_tax_reason:='Company not VAT registered';end if;
 if new.tax_status='VAT registered' and new.default_vat_rate=0 and trim(new.default_tax_reason)='' then raise exception 'Enter the reason for the default zero tax rate';end if;
 return new;
end $$;
create trigger operating_settings before insert or update on binderclip.companies for each row execute function binderclip.validate_company_settings();

-- Configuration changes serialize against new financial entries. Reads retain
-- their existing lightweight path and permissions.
create function binderclip.lock_company_settings(t uuid,exclusive_lock boolean default false) returns void language plpgsql security definer set search_path='' as $$
begin
 if exclusive_lock then perform 1 from binderclip.companies where id=t for update;else perform 1 from binderclip.companies where id=t for share;end if;
 perform set_config('binderclip.company_timezone',(select timezone from binderclip.companies where id=t),true);
end $$;
create or replace function binderclip.today() returns date language sql stable set search_path='' as $$
 select timezone(coalesce(nullif(current_setting('binderclip.company_timezone',true),''),'Asia/Dubai'),statement_timestamp())::date
$$;
do $$declare definition text;signature text;begin
 definition:=pg_get_functiondef('binderclip.member(uuid)'::regprocedure);
 definition:=replace(definition,'return m;','perform set_config(''binderclip.company_timezone'',(select timezone from binderclip.companies where id=t),true);return m;');execute definition;
 definition:=pg_get_functiondef('public.bc_session()'::regprocedure);
 definition:=replace(definition,'''company'',to_jsonb(c)', '''company'',binderclip.company_settings(c.id)');execute definition;
 definition:=pg_get_functiondef('binderclip.command_snapshot(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'tolerance=(p_data->>''tolerance'')::numeric where id=p_tenant',
 'tolerance=(p_data->>''tolerance'')::numeric,currency=coalesce(nullif(p_data->>''currency'',''''),currency),country_code=coalesce(p_data->>''country_code'',country_code),timezone=coalesce(p_data->>''timezone'',timezone),tax_status=coalesce(p_data->>''tax_status'',tax_status),default_vat_rate=coalesce((p_data->>''default_vat_rate'')::numeric,default_vat_rate),default_tax_reason=coalesce(p_data->>''default_tax_reason'',default_tax_reason) where id=p_tenant');execute definition;
 foreach signature in array array['public.bc_command(uuid,text,jsonb)','public.bc_costsheet(uuid,text,jsonb)','public.bc_workflow(uuid,text,jsonb)','public.bc_practical(uuid,text,jsonb)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  if signature like 'public.bc_command%' then
   definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n perform binderclip.lock_company_settings(p_tenant,p_action=\'company.save\');\n');
  elsif signature like 'public.bc_workflow%' then
   definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n perform binderclip.lock_company_settings(p_tenant);\n');
  else
   definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n if p_action not in(\'list\',\'detail\',\'print\',\'quotes\',\'purchase\',\'purchases\',\'statement\',\'customer_aging\') then perform binderclip.lock_company_settings(p_tenant);end if;\n');
  end if;execute definition;
 end loop;
 definition:=pg_get_functiondef('binderclip.validate_financial_input(jsonb)'::regprocedure);
 definition:=replace(definition,'(''tolerance'',2)) p(k,s)','(''tolerance'',2),(''default_vat_rate'',2)) p(k,s)');execute definition;
end $$;
revoke all on function binderclip.company_has_finance(uuid),binderclip.company_settings(uuid),binderclip.validate_company_settings(),binderclip.lock_company_settings(uuid,boolean) from public,anon,authenticated;
commit;
