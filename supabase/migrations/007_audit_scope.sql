-- General job audits must not disclose separately scoped note/task/document content.
begin;
create or replace function binderclip.log(t uuid,a text,o uuid,detail text default '') returns void language sql security definer set search_path='' as $$
 insert into binderclip.audit(tenant_id,actor,action,object_id,detail)
 values(t,auth.uid(),a,o,case when a in('event.add','task.add','document.ready') then '' else detail end);
$$;
commit;
