begin;
-- Read commands establish the company's timezone through member(); financial
-- writes additionally refresh it under the company configuration lock.
do $$declare definition text;signature text;begin
 foreach signature in array array['public.bc_report(uuid,text,date,date,date,text)','binderclip.practical_snapshot(uuid,text,jsonb)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  definition:=replace(definition,'timezone(''Asia/Dubai'',','timezone(coalesce(nullif(current_setting(''binderclip.company_timezone'',true),''''),''Asia/Dubai''),');
  execute definition;
 end loop;
end $$;
commit;
