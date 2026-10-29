begin;
-- Match the precision of the job-entry controls at the API boundary too.
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.validate_financial_input(jsonb)'::regprocedure);
 definition:=replace(definition,'(''sell_rate'',2)) p(k,s)',
  '(''sell_rate'',2),(''gross_weight'',3),(''chargeable_weight'',3),(''volume'',3),(''packages'',0),(''tolerance'',2)) p(k,s)');
 execute definition;
end $$;
commit;
