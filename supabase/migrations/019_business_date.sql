begin;
create function binderclip.today() returns date language sql stable set search_path='' as $$
 select timezone('Asia/Dubai',statement_timestamp())::date
$$;
revoke all on function binderclip.today() from public,anon,authenticated;
-- The UI and financial reports use Dubai dates. UTC midnight must not make
-- today's valid invoice or report look future-dated for the last four hours.
do $$declare row_value record;definition text;begin
 for row_value in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='binderclip' or (n.nspname='public' and p.proname like 'bc\_%' escape '\'))
  and p.prosrc like '%current_date%' loop
  definition:=pg_get_functiondef(row_value.oid);
  definition:=replace(definition,'current_date','binderclip.today()');
  execute definition;
 end loop;
 definition:=pg_get_functiondef('public.bc_report(uuid,text,date,date,date,text)'::regprocedure);
 definition:=replace(definition,'p_as_of date DEFAULT CURRENT_DATE','p_as_of date DEFAULT NULL::date');
 definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n p_as_of:=coalesce(p_as_of,binderclip.today());\n');
 execute definition;
end $$;
alter table binderclip.invoices alter column invoice_date set default binderclip.today();
alter table binderclip.receipts alter column received_on set default binderclip.today();
commit;
