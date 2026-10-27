begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('binderclip-documents','binderclip-documents',false,10485760,array['application/pdf','image/png','image/jpeg','text/plain','text/csv']);

-- Storage checks an exact server-issued object path; clients cannot choose another job or tenant.
create function public.bc_document_access(p_name text,p_action text) returns boolean language plpgsql security definer set search_path='' as $$
declare document_row binderclip.job_documents;job_row binderclip.jobs;
begin
 select * into document_row from binderclip.job_documents where object_path=p_name;
 if not found or p_action not in('C','X') then return false;end if;
 select * into strict job_row from binderclip.jobs where id=document_row.job_id;
 if not binderclip.allowed(document_row.tenant_id,'jobs.list.manage','R',job_row.created_by,job_row.branch) then return false;end if;
 if p_action='C' then return document_row.status='Pending' and document_row.created_by=auth.uid() and document_row.created_at>now()-interval '1 day' and binderclip.allowed(document_row.tenant_id,'operations.documents.manage','C',job_row.created_by,job_row.branch);end if;
 return document_row.status='Ready' and binderclip.allowed(document_row.tenant_id,'operations.documents.manage','X',job_row.created_by,job_row.branch);
exception when insufficient_privilege then return false;
end $$;
revoke all on function public.bc_document_access(text,text) from public,anon,authenticated;
grant execute on function public.bc_document_access(text,text) to authenticated;
create policy binderclip_document_upload on storage.objects for insert to authenticated with check(bucket_id='binderclip-documents' and public.bc_document_access(name,'C'));
create policy binderclip_document_download on storage.objects for select to authenticated using(bucket_id='binderclip-documents' and public.bc_document_access(name,'X'));

create function public.bc_document_finish(p_tenant uuid,p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare member_row binderclip.members:=binderclip.member(p_tenant);document_row binderclip.job_documents;job_row binderclip.jobs;
begin
 select * into strict document_row from binderclip.job_documents where id=p_id and tenant_id=p_tenant for update;
 select * into strict job_row from binderclip.jobs where id=document_row.job_id;
 perform binderclip.require(p_tenant,'operations.documents.manage','C',job_row.created_by,job_row.branch);
 if document_row.created_by<>auth.uid() or document_row.status<>'Pending' then raise exception 'Only the uploader can finalize a pending document';end if;
 if not exists(select 1 from storage.objects o where o.bucket_id='binderclip-documents' and o.name=document_row.object_path and (o.metadata->>'size')::bigint=document_row.bytes and o.metadata->>'mimetype'=document_row.mime) then raise exception 'Uploaded file size or content type does not match the registered document';end if;
 update binderclip.job_documents set status='Ready' where id=p_id;
 perform binderclip.log(p_tenant,'document.ready',document_row.job_id,document_row.filename);
 return jsonb_build_object('id',p_id);
end $$;
revoke all on function public.bc_document_finish(uuid,uuid) from public,anon,authenticated;
grant execute on function public.bc_document_finish(uuid,uuid) to authenticated;
commit;
