begin;
-- A draft created before company setup can explicitly refresh legal details.
-- Prices, taxes, customer identity, FX and posted documents are never repriced.
create function binderclip.refresh_draft_company(t uuid,target uuid,reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(t);i binderclip.invoices;c binderclip.companies;j binderclip.jobs;
begin
 perform binderclip.lock_company_settings(t);
 select * into strict i from binderclip.invoices where id=target and tenant_id=t for update;
 perform binderclip.require(t,'invoicing.detail.generate','C',i.created_by,i.branch);
 perform binderclip.require(t,'costs.detail.manage','U',i.created_by,i.branch);
 if i.status<>'Draft' then raise exception 'Only draft invoices can refresh company details. Approved and issued documents retain their snapshot';end if;
 if coalesce(length(trim(reason)),0) not between 1 and 2000 then raise exception 'Record a reason for refreshing the draft company details';end if;
 select * into strict c from binderclip.companies where id=t;
 if c.tax_status='Not VAT registered' and exists(select 1 from binderclip.invoice_items where invoice_id=i.id and tax_rate<>0) then raise exception 'Correct this draft to 0 percent sales VAT before applying the non-registered company details';end if;
 for j in select distinct job.* from binderclip.jobs job join binderclip.invoice_items x on x.job_id=job.id where x.invoice_id=i.id loop
  perform binderclip.require(t,'jobs.list.manage','R',j.created_by,j.branch);
  perform binderclip.require(t,'invoicing.detail.generate','C',j.created_by,j.branch);
  if j.locked_at is not null or j.status in('Closed','Cancelled') then raise exception 'This invoice job is locked or archived';end if;
  insert into binderclip.costsheet_changes(tenant_id,job_id,action,reason,before_values,after_values,actor)
   values(t,j.id,'invoice.company.refresh',trim(reason),i.snapshot->'company',to_jsonb(c),auth.uid());
 end loop;
 update binderclip.invoices set snapshot=jsonb_set(snapshot,'{company}',to_jsonb(c)) where id=i.id;
 perform binderclip.log(t,'invoice.company.refresh',i.id,trim(reason));return jsonb_build_object('id',i.id);
end $$;
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_practical(uuid,text,jsonb)'::regprocedure);
 definition:=regexp_replace(definition,E'\nbegin\n',E'\nbegin\n if p_action=\'invoice.refresh_company\' then return binderclip.refresh_draft_company(p_tenant,(p_data->>\'id\')::uuid,p_data->>\'reason\');end if;\n');
 execute definition;
end $$;
revoke all on function binderclip.refresh_draft_company(uuid,uuid,text) from public,anon,authenticated;
commit;
