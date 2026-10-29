begin;
-- Existing document IDs, numbers, stored bytes and job relationships are retained.
alter table binderclip.job_documents alter column job_id drop not null;
alter table binderclip.job_documents add column record_type text not null default 'job' check(record_type in('job','quote','purchase','costsheet','invoice'));
alter table binderclip.job_documents add column record_id uuid;
update binderclip.job_documents set record_id=job_id;
alter table binderclip.job_documents alter column record_id set not null;
create index on binderclip.job_documents(tenant_id,record_type,record_id,created_at desc);

create function binderclip.attachment_target(p_tenant uuid,p_type text,p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_type in('job','costsheet') then
  select jsonb_build_object('job_id',id,'number',case when p_type='costsheet' then costsheet_number else number end,'branch',branch,'created_by',created_by,'path',case when p_type='costsheet' then 'costs.detail.manage' else 'jobs.list.manage' end) into result from binderclip.jobs where id=p_id and tenant_id=p_tenant;
 elsif p_type='quote' then
  select jsonb_build_object('job_id',null,'number',number,'branch',branch,'created_by',created_by,'path','sales.quotes.manage') into result from binderclip.quotations where id=p_id and tenant_id=p_tenant;
 elsif p_type='purchase' then
  select jsonb_build_object('job_id',job_id,'number',number,'branch',branch,'created_by',created_by,'path','costs.detail.manage') into result from binderclip.purchase_invoices where id=p_id and tenant_id=p_tenant;
 elsif p_type='invoice' then
  -- A consolidated customer invoice belongs to the invoice, not an arbitrary job.
  select jsonb_build_object('job_id',null,'number',number,'branch',branch,'created_by',created_by,'path','invoicing.list.manage') into result from binderclip.invoices where id=p_id and tenant_id=p_tenant;
 end if;
 if result is null then raise exception 'Document unavailable in this company' using errcode='42501';end if;
 return result;
end $$;
create function binderclip.require_attachment(p_tenant uuid,p_type text,p_id uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);v jsonb:=binderclip.attachment_target(p_tenant,p_type,p_id);j binderclip.jobs;
begin
 perform binderclip.require(p_tenant,v->>'path','R',(v->>'created_by')::uuid,v->>'branch');
 if p_type in('purchase','costsheet') then
  select * into strict j from binderclip.jobs where id=(v->>'job_id')::uuid and tenant_id=p_tenant;
  perform binderclip.require(p_tenant,'jobs.list.manage','R',j.created_by,j.branch);
 end if;
 if p_action not in('C','R','X') then raise exception 'Unknown attachment action';end if;
 perform binderclip.require(p_tenant,'operations.documents.manage',p_action,(v->>'created_by')::uuid,v->>'branch');
 return v;
end $$;
create function binderclip.bind_attachment() returns trigger language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if TG_OP='UPDATE' then
  if (new.tenant_id,new.record_type,new.record_id,new.job_id) is distinct from(old.tenant_id,old.record_type,old.record_id,old.job_id) then raise exception 'Attachment ownership cannot be changed';end if;
  return new;
 end if;
 new.record_id:=coalesce(new.record_id,new.job_id);
 v:=binderclip.attachment_target(new.tenant_id,new.record_type,new.record_id);
 if new.job_id is distinct from (v->>'job_id')::uuid or new.branch is distinct from v->>'branch' then raise exception 'Attachment does not belong to this document';end if;
 return new;
end $$;
create trigger attachment_binding before insert or update on binderclip.job_documents for each row execute function binderclip.bind_attachment();

create table binderclip.record_folders(
 tenant_id uuid not null references binderclip.companies,record_type text not null check(record_type in('job','quote','purchase','costsheet','invoice')),record_id uuid not null,
 external_id text not null unique,parent_id text not null,primary key(tenant_id,record_type,record_id)
);
alter table binderclip.record_folders enable row level security;
revoke all on binderclip.record_folders from public,anon,authenticated;
insert into binderclip.record_folders select tenant_id,'job',job_id,external_id,parent_id from binderclip.drive_folders;

create function public.bc_attachments(p_tenant uuid,p_type text,p_id uuid,p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;result uuid;
begin
 v:=binderclip.require_attachment(p_tenant,p_type,p_id,case when p_action='register' then 'C' else 'R' end);
 if p_action='list' then
  return (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc),'[]') from binderclip.job_documents d where tenant_id=p_tenant and record_type=p_type and record_id=p_id);
 elsif p_action='register' then
  if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>10000 then raise exception 'Invalid attachment metadata';end if;
  result:=gen_random_uuid();
  insert into binderclip.job_documents(id,tenant_id,job_id,record_type,record_id,kind,filename,mime,bytes,object_path,branch,created_by)
   values(result,p_tenant,(v->>'job_id')::uuid,p_type,p_id,p_data->>'kind',p_data->>'filename',p_data->>'mime',(p_data->>'bytes')::bigint,p_tenant||'/'||p_type||'/'||p_id||'/'||result,v->>'branch',auth.uid());
  perform binderclip.log(p_tenant,'document.register',(v->>'job_id')::uuid,p_type||' attachment registered');
  return jsonb_build_object('id',result);
 else raise exception 'Unknown attachment action';end if;
end $$;

create or replace function public.bc_document_context(p_tenant uuid,p_id uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);d binderclip.job_documents;v jsonb;
begin
 select * into strict d from binderclip.job_documents where id=p_id and tenant_id=p_tenant;
 v:=binderclip.require_attachment(p_tenant,d.record_type,d.record_id,p_action);
 if p_action='C' then
  if d.status<>'Pending' or d.created_by<>auth.uid() or d.created_at<=clock_timestamp()-interval '1 day' then raise exception 'Only the uploader can retry a pending attachment within 24 hours';end if;
 elsif p_action='X' then
  if d.status<>'Ready' then raise exception 'This attachment is not ready';end if;
 else raise exception 'Unknown document action';end if;
 return jsonb_build_object('id',d.id,'tenant_id',d.tenant_id,'job_id',d.job_id,'job_number',v->>'number','record_type',d.record_type,'record_id',d.record_id,'record_number',v->>'number','filename',d.filename,'mime',d.mime,'bytes',d.bytes::text,'status',d.status,'object_path',d.object_path,'created_by',d.created_by);
end $$;
create or replace function public.bc_document_access(p_name text,p_action text) returns boolean language plpgsql security definer set search_path='' as $$
declare d binderclip.job_documents;
begin
 select * into d from binderclip.job_documents where object_path=p_name;
 if not found or p_action not in('C','X') then return false;end if;
 if exists(select 1 from binderclip.document_storage where document_id=d.id and provider<>'supabase') then return false;end if;
 perform public.bc_document_context(d.tenant_id,d.id,p_action);return true;
exception when others then return false;
end $$;
create or replace function public.bc_document_finish(p_tenant uuid,p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d binderclip.job_documents;
begin
 select * into strict d from binderclip.job_documents where id=p_id and tenant_id=p_tenant for update;
 perform public.bc_document_context(p_tenant,p_id,'C');
 if exists(select 1 from binderclip.document_storage where document_id=d.id and verified_at is null) then raise exception 'Server file verification is required';end if;
 if not exists(select 1 from binderclip.document_storage where document_id=d.id and provider='google_drive' and verified_at is not null)
  and not exists(select 1 from storage.objects o where o.bucket_id='binderclip-documents' and o.name=d.object_path and (o.metadata->>'size')::bigint=d.bytes and o.metadata->>'mimetype'=d.mime) then raise exception 'Uploaded file does not match the attachment';end if;
 update binderclip.job_documents set status='Ready' where id=p_id;
 perform binderclip.log(p_tenant,'document.ready',d.job_id,d.record_type||' attachment ready');return jsonb_build_object('id',p_id);
end $$;

do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_document_service(text,jsonb)'::regprocedure);
 definition:=replace(definition,'if not exists(select 1 from binderclip.jobs where id=(p_data->>''job_id'')::uuid and tenant_id=(p_data->>''tenant_id'')::uuid) then raise exception ''Job unavailable'';end if;',
  'perform binderclip.attachment_target((p_data->>''tenant_id'')::uuid,coalesce(p_data->>''record_type'',''job''),coalesce(p_data->>''record_id'',p_data->>''job_id'')::uuid);');
 definition:=replace(definition,'insert into binderclip.drive_folders(tenant_id,job_id,external_id,parent_id) values((p_data->>''tenant_id'')::uuid,(p_data->>''job_id'')::uuid,p_data->>''external_id'',c.root_id) on conflict do nothing;',
  'insert into binderclip.record_folders(tenant_id,record_type,record_id,external_id,parent_id) values((p_data->>''tenant_id'')::uuid,coalesce(p_data->>''record_type'',''job''),coalesce(p_data->>''record_id'',p_data->>''job_id'')::uuid,p_data->>''external_id'',c.root_id) on conflict do nothing;');
 definition:=replace(definition,'select to_jsonb(f) into result from binderclip.drive_folders f where tenant_id=(p_data->>''tenant_id'')::uuid and job_id=(p_data->>''job_id'')::uuid;',
  'select to_jsonb(f) into result from binderclip.record_folders f where tenant_id=(p_data->>''tenant_id'')::uuid and record_type=coalesce(p_data->>''record_type'',''job'') and record_id=coalesce(p_data->>''record_id'',p_data->>''job_id'')::uuid;');
 definition:=replace(definition,'select external_id into strict folder_id from binderclip.drive_folders where tenant_id=d.tenant_id and job_id=d.job_id;',
  'select external_id into strict folder_id from binderclip.record_folders where tenant_id=d.tenant_id and record_type=d.record_type and record_id=d.record_id;');execute definition;
 -- Other document attachments must not satisfy a job's mandatory BL/POD gate or leak into its file list.
 definition:=pg_get_functiondef('public.bc_workspace(uuid,text,uuid,text,text)'::regprocedure);
 definition:=replace(definition,'d.job_id=p_id and binderclip.allowed','d.job_id=p_id and d.record_type=''job'' and binderclip.allowed');execute definition;
end $$;
-- Locate the stage-check trigger without depending on a historical function name.
do $$declare f record;definition text;begin
 for f in select distinct p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='binderclip' and p.prosrc like '%where d.job_id=new.id and d.kind=r.kind%' loop
  definition:=pg_get_functiondef(f.oid);definition:=replace(definition,'where d.job_id=new.id and d.kind=r.kind','where d.job_id=new.id and d.record_type=''job'' and d.kind=r.kind');execute definition;
 end loop;
end $$;
revoke all on function binderclip.attachment_target(uuid,text,uuid),binderclip.require_attachment(uuid,text,uuid,text),binderclip.bind_attachment(),public.bc_attachments(uuid,text,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.bc_attachments(uuid,text,uuid,text,jsonb) to authenticated;
commit;
