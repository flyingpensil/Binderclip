begin;
create function binderclip.billed_line_base(t uuid,line_target uuid) returns numeric language sql stable security definer set search_path='' as $$
 with allocations as(
  select x.line_id,round(sum(x.net) over(partition by x.invoice_id order by x.position,x.id rows unbounded preceding)*i.fx_rate,2)
   -round((sum(x.net) over(partition by x.invoice_id order by x.position,x.id rows unbounded preceding)-x.net)*i.fx_rate,2) amount
  from binderclip.invoice_items x join binderclip.invoices i on i.id=x.invoice_id
  where x.tenant_id=t and x.invoice_id=(select invoice_id from binderclip.invoice_items where tenant_id=t and line_id=line_target)
 ) select amount from allocations where line_id=line_target
$$;
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.costsheet_snapshot(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,'binderclip.base(b.quantity,b.unit_rate,b.fx_rate)',
  '(binderclip.base(b.quantity,b.unit_rate,b.fx_rate)+case when b.vat_recoverable then 0 else round(b.tax_amount*b.fx_rate,2) end)');
 definition:=replace(definition,'''actual_base'',case when b.status=''Matched'' then',
  '''actual_base'',case when l.side=''SELL'' then coalesce(binderclip.billed_line_base(p_tenant,l.id),binderclip.base(l.quantity,l.unit_rate,l.fx_rate)) when b.status=''Matched'' then');
 execute definition;
end $$;
revoke all on function binderclip.billed_line_base(uuid,uuid) from public,anon,authenticated;
commit;
