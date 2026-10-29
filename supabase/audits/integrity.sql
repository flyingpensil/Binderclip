-- Read-only structural/accounting audit. No client names, identifiers or values
-- are returned: each row is a count requiring investigation, not an auto-repair.
begin transaction read only;
with checks(check_name,exceptions) as (
 select 'Unbalanced or empty journals',count(*) from (
  select e.id from binderclip.journals e left join binderclip.journal_lines l on l.entry_id=e.id
  group by e.id having count(l.id)<2 or coalesce(sum(l.debit-l.credit),0)<>0
 ) a
 union all select 'Invoice totals differ from stored lines',count(*) from binderclip.invoices i
 where i.subtotal<>coalesce((select sum(x.net) from binderclip.invoice_items x where x.invoice_id=i.id),0)
 or i.tax_total<>coalesce((select sum(x.tax) from binderclip.invoice_items x where x.invoice_id=i.id),0)
 or i.total<>i.subtotal+i.tax_total
 union all select 'Invoice paid amount differs from receipts',count(*) from binderclip.invoices i
 where i.paid<>coalesce((select sum(r.amount) from binderclip.receipts r where r.invoice_id=i.id),0)
 union all select 'Invoice payment status inconsistent',count(*) from binderclip.invoices i
 where (i.status='Paid' and i.paid<>i.total) or (i.status='Issued' and i.paid<>0)
 or (i.status='Partially Paid' and not(i.paid>0 and i.paid<i.total))
 union all select 'Negative invoice net or VAT lines',count(*) from binderclip.invoice_items where net<0 or tax<0
 union all select 'Invoice item arithmetic differs',count(*) from binderclip.invoice_items x
 where x.net<>round(x.quantity*x.unit_rate,2)-x.discount_share+x.adjustment_share
 or x.tax<>round(x.net*x.tax_rate/100,2)
 union all select 'Invoice discount or adjustment allocation differs',count(*) from binderclip.invoices i
 where i.discount<>coalesce((select sum(x.discount_share) from binderclip.invoice_items x where x.invoice_id=i.id),0)
 or i.adjustment<>coalesce((select sum(x.adjustment_share) from binderclip.invoice_items x where x.invoice_id=i.id),0)
 union all select 'Posted invoice receivable differs from journal',count(*) from binderclip.invoices i
 where i.status in('Issued','Partially Paid','Paid') and
 round(i.subtotal*i.fx_rate,2)+round(i.tax_total*i.fx_rate,2)<>
 coalesce((select sum(l.debit-l.credit) from binderclip.journals e join binderclip.journal_lines l on l.entry_id=e.id where e.tenant_id=i.tenant_id and e.source='invoice:'||i.id and l.account='1100 Receivables'),0)
 union all select 'Invoice receipt total differs from posted credit',count(*) from binderclip.invoices i
 where coalesce((select sum(l.credit-l.debit) from binderclip.receipts r join binderclip.journals e on e.tenant_id=r.tenant_id and e.source='receipt:'||r.id join binderclip.journal_lines l on l.entry_id=e.id where r.invoice_id=i.id and l.account='1100 Receivables'),0)<>
 case when i.total=0 then 0 else round(i.paid/i.total*(round(i.subtotal*i.fx_rate,2)+round(i.tax_total*i.fx_rate,2)),2) end
 union all select 'Draft or approved invoice has posted revenue',count(*) from binderclip.invoices i
 where i.status in('Draft','Approved') and exists(select 1 from binderclip.journals e where e.tenant_id=i.tenant_id and e.source='invoice:'||i.id)
 union all select 'Prepared supplier items missing linked cost lines',count(*) from binderclip.purchase_items x join binderclip.purchase_invoices p on p.id=x.invoice_id where p.status='Prepared' and (x.buy_line_id is null or x.sell_line_id is null)
 union all select 'Invoice original charges differ from stored items',count(*) from binderclip.invoices i where i.charges_subtotal is not null and i.charges_subtotal<>coalesce((select sum(round(x.quantity*x.unit_rate,2)) from binderclip.invoice_items x where x.invoice_id=i.id),0)
 union all select 'Supplier overpayments',count(*) from binderclip.supplier_bills b
 where coalesce((select sum(p.amount) from binderclip.supplier_payments p where p.bill_id=b.id),0)>round(b.quantity*b.unit_rate,2)+b.tax_amount
 union all select 'Matched supplier bill payable differs from journal',count(*) from binderclip.supplier_bills b
 where b.status='Matched' and binderclip.base(b.quantity,b.unit_rate,b.fx_rate)+round(b.tax_amount*b.fx_rate,2)<>
 coalesce((select sum(l.credit-l.debit) from binderclip.journals e join binderclip.journal_lines l on l.entry_id=e.id where e.tenant_id=b.tenant_id and e.source in('bill:'||b.id,'input-tax:'||b.id) and l.account='2100 Payables'),0)
 union all select 'Supplier payments differ from posted payable debit',count(*) from binderclip.supplier_bills b
 where coalesce((select sum(l.debit-l.credit) from binderclip.supplier_payments p join binderclip.journals e on e.tenant_id=p.tenant_id and e.source='supplier-payment:'||p.id join binderclip.journal_lines l on l.entry_id=e.id where p.bill_id=b.id and l.account='2100 Payables'),0)<>
 case when round(b.quantity*b.unit_rate,2)+b.tax_amount=0 then 0 else
 round(coalesce((select sum(p.amount) from binderclip.supplier_payments p where p.bill_id=b.id),0)/(round(b.quantity*b.unit_rate,2)+b.tax_amount)*(binderclip.base(b.quantity,b.unit_rate,b.fx_rate)+round(b.tax_amount*b.fx_rate,2)),2) end
 union all select 'Accrued estimate differs from booking journal',count(*) from binderclip.cost_lines c
 where c.side='BUY' and c.accrued and binderclip.base(c.quantity,c.unit_rate,c.fx_rate)<>
 coalesce((select sum(l.credit-l.debit) from binderclip.journals e join binderclip.journal_lines l on l.entry_id=e.id where e.tenant_id=c.tenant_id and e.source='accrual:'||c.id and l.account='2000 Accrued costs'),0)
 union all select 'Bill source does not match job or supplier',count(*) from binderclip.supplier_bills b join binderclip.cost_lines l on l.id=b.line_id
 where (b.tenant_id,b.job_id,b.supplier_id,b.currency) is distinct from(l.tenant_id,l.job_id,l.supplier_id,l.currency) or l.side<>'BUY'
 union all select 'Invoice item source belongs to another customer/company',count(*) from binderclip.invoice_items x join binderclip.invoices i on i.id=x.invoice_id join binderclip.jobs j on j.id=x.job_id join binderclip.cost_lines c on c.id=x.line_id
 where (x.tenant_id,i.customer_id,x.job_id,c.side) is distinct from(i.tenant_id,j.customer_id,c.job_id,'SELL')
 union all select 'Non-unit base-currency document rates',count(*) from (
  select tenant_id,currency,fx_rate from binderclip.invoices union all select tenant_id,currency,fx_rate from binderclip.cost_lines union all select tenant_id,currency,fx_rate from binderclip.supplier_bills union all select tenant_id,currency,fx_rate from binderclip.purchase_invoices
 ) d join binderclip.companies c on c.id=d.tenant_id where d.currency=c.currency and d.fx_rate<>1
 union all select 'Private tables missing RLS',count(*) from pg_tables where schemaname='binderclip' and not rowsecurity
 union all select 'Direct browser private-table grants',count(*) from information_schema.role_table_grants where table_schema='binderclip' and grantee in('anon','authenticated','PUBLIC')
 union all select 'Ready documents without matching stored files',count(*) from binderclip.job_documents d where d.status='Ready' and not exists(select 1 from storage.objects o where o.bucket_id='binderclip-documents' and o.name=d.object_path and (o.metadata->>'size')::bigint=d.bytes and o.metadata->>'mimetype'=d.mime)
 union all select 'Public document buckets',count(*) from storage.buckets where id='binderclip-documents' and public
)
select check_name,exceptions from checks order by check_name;
commit;
