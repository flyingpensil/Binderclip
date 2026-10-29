begin;
-- Normalize familiar wildcard syntax inside the existing scoped read functions.
do $$declare definition text;signature text;begin
 foreach signature in array array['public.bc_read(uuid,text,uuid,text,text)','public.bc_workspace(uuid,text,uuid,text,text)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n p_query:=replace(replace(coalesce(p_query,\'\'),\'*\',\'%\'),\'?\',\'_\');\n if length(p_query)>240 then raise exception \'Search is limited to 240 characters\';end if;\n');
  definition:=replace(definition,'if length(trim(p_query))<2 then','if length(trim(p_query))<2 and p_query not in(''%'',''_'') then');
  execute definition;
 end loop;
 definition:=pg_get_functiondef('public.bc_costsheet(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'result:=binderclip.costsheet_snapshot(p_tenant,p_action,data);','if p_action=''list'' then data:=jsonb_set(data,''{q}'',to_jsonb(replace(replace(coalesce(data->>''q'',''''),''*'',''%''),''?'',''_'')));end if; result:=binderclip.costsheet_snapshot(p_tenant,p_action,data);');
 execute definition;
end $$;
commit;
