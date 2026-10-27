-- Record ownership/timestamps are assigned by PostgreSQL, never by browser input.
begin;
create function binderclip.tracking_name(t uuid,u uuid) returns text language sql stable security definer set search_path='' as $$
 select m.display_name from binderclip.members m join auth.users a on lower(a.email)=m.email
 where m.tenant_id=t and a.id=u limit 1
$$;
create function binderclip.stamp_record() returns trigger language plpgsql security definer set search_path='' as $$
declare v jsonb:=to_jsonb(new);previous jsonb; t uuid;u uuid:=auth.uid();person text;
begin
 t:=nullif(v->>'tenant_id','')::uuid;
 if TG_TABLE_NAME='companies' then t:=(v->>'id')::uuid;
 elsif TG_TABLE_NAME='journal_lines' then select tenant_id into t from binderclip.journals where id=(v->>'entry_id')::uuid;
 elsif TG_TABLE_NAME='grants' then select tenant_id into t from binderclip.roles where id=(v->>'role_id')::uuid;end if;
 person:=coalesce(binderclip.tracking_name(t,u),case when u is null then 'System' else 'Company member' end);
 if TG_OP='INSERT' then
  v:=v||jsonb_build_object('created_by',coalesce(u,nullif(v->>'created_by','')::uuid),'created_at',clock_timestamp(),'created_by_name',person,'updated_by',null,'updated_at',null,'updated_by_name',null);
 else
  previous:=to_jsonb(old);
  v:=v||jsonb_build_object('created_by',previous->'created_by','created_at',previous->'created_at','created_by_name',previous->'created_by_name',
    'updated_by',u,'updated_at',clock_timestamp(),'updated_by_name',person);
 end if;
 new:=jsonb_populate_record(new,v);return new;
end $$;
do $$declare tab text;begin
 foreach tab in array array['companies','members','roles','member_roles','grants','masters','jobs','cost_lines','supplier_bills','invoices','invoice_items','receipts','journals','journal_lines','audit','enquiries','quotations','quotation_lines','job_events','job_tasks','job_documents','document_requirements','supplier_payments','costsheet_changes'] loop
  execute format('alter table binderclip.%I add column if not exists created_by uuid references auth.users, add column if not exists created_at timestamptz, add column created_by_name text, add column updated_by uuid references auth.users, add column updated_at timestamptz, add column updated_by_name text',tab);
  execute format('create trigger record_tracking before insert or update on binderclip.%I for each row execute function binderclip.stamp_record()',tab);
 end loop;
end $$;
-- Updating a quotation/cost line also marks the containing document as updated.
create function binderclip.touch_parent() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='quotation_lines' then update binderclip.quotations set updated_at=clock_timestamp() where id=new.quote_id;
 else update binderclip.jobs set updated_at=clock_timestamp() where id=new.job_id;end if;
 return new;
end $$;
create trigger tracking_parent after insert or update on binderclip.quotation_lines for each row execute function binderclip.touch_parent();
create trigger tracking_parent after insert or update on binderclip.cost_lines for each row execute function binderclip.touch_parent();
-- Existing timestamps remain unchanged. Resolve names only for rows already returned
-- by a permission-scoped API. Never invent historical update dates.
create function binderclip.with_tracking(t uuid,v jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;entry record;
begin
 if jsonb_typeof(v)='array' then
  select coalesce(jsonb_agg(binderclip.with_tracking(t,value) order by ord),'[]') into result from jsonb_array_elements(v) with ordinality a(value,ord);return result;
 elsif jsonb_typeof(v)='object' then
  result:=v;
  for entry in select key,value from jsonb_each(v) where key not in('data','snapshot','before_values','after_values') and jsonb_typeof(value) in('array','object') loop
   result:=jsonb_set(result,array[entry.key],binderclip.with_tracking(t,entry.value));
  end loop;
  if v->>'tenant_id'=t::text and v ? 'created_by' then
   result:=result||jsonb_build_object('created_by_name',coalesce(v->>'created_by_name',binderclip.tracking_name(t,nullif(v->>'created_by','')::uuid)),
    'updated_by_name',coalesce(v->>'updated_by_name',binderclip.tracking_name(t,nullif(v->>'updated_by','')::uuid)));
  end if;return result;
 end if;return v;
end $$;
revoke all on function binderclip.tracking_name(uuid,uuid),binderclip.stamp_record(),binderclip.touch_parent(),binderclip.with_tracking(uuid,jsonb) from public,anon,authenticated;
-- Patch the final, installed API definitions without adding alternative public APIs
-- or changing their existing grants and row-scope checks.
do $$declare signature text;definition text;begin
 foreach signature in array array['public.bc_read(uuid,text,uuid,text,text)','public.bc_workspace(uuid,text,uuid,text,text)','public.bc_costsheet(uuid,text,jsonb)','public.bc_billing(uuid,text,jsonb)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  definition:=replace(definition,'return binderclip.decimals(coalesce(result,''[]''))','return binderclip.decimals(binderclip.with_tracking(p_tenant,coalesce(result,''[]'')))');
  definition:=replace(definition,'return binderclip.decimals(result)','return binderclip.decimals(binderclip.with_tracking(p_tenant,result))');
  -- Cost-sheet list uses an explicit projection rather than to_jsonb(j).
  definition:=replace(definition,'''costsheet_number'',j.costsheet_number,','''costsheet_number'',j.costsheet_number,''tenant_id'',j.tenant_id,''created_by'',j.created_by,''created_by_name'',j.created_by_name,''updated_by'',j.updated_by,''updated_at'',j.updated_at,''updated_by_name'',j.updated_by_name,');
  execute definition;
 end loop;
end $$;
-- A quote editor may not alter hidden BUY lines through a guessed line id.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_workflow(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'if p_data->>''side''=''BUY'' and not exists',
  'if p_data->>''side''=''BUY'' or exists(select 1 from binderclip.quotation_lines where id=nullif(p_data->>''line_id'','''')::uuid and quote_id=target and side=''BUY'') then perform binderclip.require(p_tenant,''costs.detail.manage'',''R'',quote_row.created_by,quote_row.branch);end if; if p_data->>''side''=''BUY'' and not exists');
 execute definition;
end $$;
commit;
