begin;
-- Preserve report scopes and export checks while aligning all accounting cutoffs
-- with the same Dubai posting date used by customer statements.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_report(uuid,text,date,date,date,text)'::regprocedure);
 definition:=replace(definition,'e.created_at::date','timezone(''Asia/Dubai'',e.created_at)::date');
 definition:=replace(definition,'j.created_at::date','timezone(''Asia/Dubai'',j.created_at)::date');
 definition:=replace(definition,'if p_kind=''receivables'' then return',
  'if p_as_of is null or p_as_of>current_date or p_from>p_to or p_from>p_as_of or p_to>p_as_of then raise exception ''Choose a valid report range ending on or before the as-of date'';end if; if p_kind=''job_profitability'' and p_as_of<>current_date then raise exception ''Job profitability shows current estimates and matched costs. Choose today for the as-of date'';end if; if p_kind=''receivables'' and (p_from is not null or p_to is not null) then raise exception ''Ageing uses an as-of date only. Use the customer statement for a date range'';end if; if p_kind=''receivables'' then return');
 definition:=replace(definition,'elsif p_kind=''payables'' then',
  'elsif p_kind=''payables'' then if p_from is not null or p_to is not null then raise exception ''Ageing uses an as-of date only'';end if;');
 definition:=replace(definition,'and p.paid_on<=p_as_of',
  'and p.paid_on<=p_as_of and coalesce((select timezone(''Asia/Dubai'',pj.created_at)::date from binderclip.journals pj where pj.tenant_id=p.tenant_id and pj.source=''supplier-payment:''||p.id),p.paid_on)<=p_as_of');
 definition:=replace(definition,'and b.invoice_date<=p_as_of',
  'and b.invoice_date<=p_as_of and coalesce((select timezone(''Asia/Dubai'',bj.created_at)::date from binderclip.journals bj where bj.tenant_id=b.tenant_id and bj.source=''bill:''||b.id),b.invoice_date)<=p_as_of');
 execute definition;
end $$;
commit;
