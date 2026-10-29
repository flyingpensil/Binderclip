begin;
-- Validate exact decimal precision before PostgreSQL typmods can round user input.
-- Never silently accept NaN, exponent strings or fractions of a posted cent.
create function binderclip.validate_financial_input(v jsonb) returns void language plpgsql set search_path='' as $$
declare key_name text;places integer;raw text;n numeric;item jsonb;
begin
 if jsonb_typeof(v)<>'object' or octet_length(v::text)>500000 then raise exception 'Invalid entry payload';end if;
 for key_name,places in select * from (values
 ('quantity',3),('unit_rate',2),('amount',2),('tax_rate',2),('discount',2),('adjustment',2),
 ('from_amount',8),('to_amount',8),('fx_rate',8),('sell_vat',2),('credit_limit',2),('credit_days',0),('buy_rate',2),('sell_rate',2)) p(k,s) loop
  raw:=v->>key_name;
  if raw is not null and raw<>'' then
   if raw !~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$' then raise exception 'Enter a valid decimal for %',replace(key_name,'_',' ');end if;
   n:=raw::numeric;
   if n<>round(n,places) then raise exception '% accepts at most % decimal places',replace(key_name,'_',' '),places;end if;
  end if;
 end loop;
 if v ? 'lines' then
  if jsonb_typeof(v->'lines')<>'array' or jsonb_array_length(v->'lines')>500 then raise exception 'Choose between 1 and 500 document lines';end if;
  for item in select value from jsonb_array_elements(v->'lines') loop perform binderclip.validate_financial_input(item);end loop;
 end if;
 if jsonb_typeof(v->'data')='object' then perform binderclip.validate_financial_input(v->'data');end if;
end $$;
-- Apply guards to every public financial command, preserving its original RBAC.
do $$declare definition text;signature text;begin
 foreach signature in array array['public.bc_command(uuid,text,jsonb)','public.bc_workflow(uuid,text,jsonb)','public.bc_costsheet(uuid,text,jsonb)','public.bc_practical(uuid,text,jsonb)','public.bc_rates(uuid,text,jsonb)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n perform binderclip.validate_financial_input(p_data);\n');
  execute definition;
 end loop;
 -- Run the checks after selecting and locking the target document, inside the
 -- private implementations. No mutation or widening of browser privileges.
 definition:=pg_get_functiondef('binderclip.command_snapshot(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'amount:=(p_data->>''amount'')::numeric;if amount<=0',
  'if coalesce(trim(p_data->>''reference''),'''')='''' then raise exception ''Receipt reference is required'';end if; if (p_data->>''received_on'')::date<i.invoice_date then raise exception ''Receipt date cannot precede the invoice date'';end if; amount:=(p_data->>''amount'')::numeric;if amount<=0');
 definition:=replace(definition,'quantity:=(p_data->>''quantity'')::numeric;rate:=',
  'if coalesce(trim(p_data->>''number''),'''')='''' then raise exception ''Supplier invoice reference is required'';end if; if (p_data->>''invoice_date'')::date>current_date or (p_data->>''due_date'')::date<(p_data->>''invoice_date'')::date then raise exception ''Check supplier invoice and due dates'';end if; quantity:=(p_data->>''quantity'')::numeric;rate:=');
 execute definition;
 definition:=pg_get_functiondef('binderclip.workflow_snapshot(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'if bill_row.status<>''Matched'' then',
  'if coalesce(trim(p_data->>''reference''),'''')='''' then raise exception ''Payment reference is required'';end if; if bill_row.status<>''Matched'' then');
 execute definition;
end $$;
revoke all on function binderclip.validate_financial_input(jsonb) from public,anon,authenticated;
commit;
