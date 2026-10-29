begin;
-- PostgreSQL's JSON operator precedence must not discard the existing offline
-- credential when Google returns only a new short-lived access token.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_document_service(text,jsonb)'::regprocedure);
 if position('v:=v||p_data->''credentials'';' in definition)=0 then raise exception 'Unexpected document broker version';end if;
 definition:=replace(definition,'v:=v||p_data->''credentials'';',
  'if jsonb_typeof(p_data->''credentials'') is distinct from ''object'' then raise exception ''Invalid refreshed credentials'';end if; v:=v||(p_data->''credentials'');');
 execute definition;
end $$;
commit;
