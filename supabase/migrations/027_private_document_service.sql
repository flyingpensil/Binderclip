begin;
-- Provider credentials and file identifiers stay outside user-facing documents.
create table binderclip.drive_connection(
 singleton boolean primary key default true check(singleton),
 status text not null default 'Unconfigured' check(status in('Unconfigured','Preparing','Ready','Reconnect required')),
 owner_email text,owner_sub text,client_id text,root_id text,root_url text,secret_id uuid,updated_at timestamptz not null default now()
);
insert into binderclip.drive_connection(singleton) values(true);
create table binderclip.drive_oauth_states(
 state_hash text primary key check(state_hash ~ '^[a-f0-9]{64}$'),verifier text,
 expires_at timestamptz not null,consumed_at timestamptz
);
create table binderclip.drive_folders(
 tenant_id uuid not null references binderclip.companies,job_id uuid not null,
 external_id text not null unique,parent_id text not null,
 primary key(tenant_id,job_id),foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id)
);
create table binderclip.document_storage(
 document_id uuid primary key references binderclip.job_documents,
 provider text not null check(provider in('supabase','google_drive')),
 external_id text unique,parent_id text,sha256 text check(sha256 ~ '^[a-f0-9]{64}$'),
 verified_at timestamptz,created_at timestamptz not null default now()
);
alter table binderclip.drive_connection enable row level security;
alter table binderclip.drive_oauth_states enable row level security;
alter table binderclip.drive_folders enable row level security;
alter table binderclip.document_storage enable row level security;
revoke all on binderclip.drive_connection,binderclip.drive_oauth_states,binderclip.drive_folders,binderclip.document_storage from public,anon,authenticated;

create function binderclip.register_document_storage() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into binderclip.document_storage(document_id,provider) values(new.id,case when exists(select 1 from binderclip.drive_connection where root_id is not null) then 'google_drive' else 'supabase' end);
 return new;
end $$;
create trigger storage_manifest after insert on binderclip.job_documents for each row execute function binderclip.register_document_storage();

create function public.bc_document_context(p_tenant uuid,p_id uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(p_tenant);d binderclip.job_documents;j binderclip.jobs;
begin
 select * into strict d from binderclip.job_documents where id=p_id and tenant_id=p_tenant;
 select * into strict j from binderclip.jobs where id=d.job_id;
 perform binderclip.require(p_tenant,'jobs.list.manage','R',j.created_by,j.branch);
 if p_action='C' then
  perform binderclip.require(p_tenant,'operations.documents.manage','C',j.created_by,j.branch);
  if d.status<>'Pending' or d.created_by<>auth.uid() or d.created_at<=clock_timestamp()-interval '1 day' then raise exception 'Only the uploader can retry a pending attachment within 24 hours';end if;
 elsif p_action='X' then
  perform binderclip.require(p_tenant,'operations.documents.manage','X',j.created_by,j.branch);
  if d.status<>'Ready' then raise exception 'This attachment is not ready';end if;
 else raise exception 'Unknown document action';end if;
 return jsonb_build_object('id',d.id,'tenant_id',d.tenant_id,'job_id',d.job_id,'job_number',j.number,'filename',d.filename,'mime',d.mime,'bytes',d.bytes::text,'status',d.status,'object_path',d.object_path,'created_by',d.created_by);
end $$;

-- Only the server's service-role key can call this broker. It is never exposed
-- to app users. User authorization is independently rechecked by context/finish.
create function public.bc_document_service(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare c binderclip.drive_connection;d binderclip.job_documents;s binderclip.document_storage;v jsonb;result jsonb;secret_value uuid;folder_id text;state_value binderclip.drive_oauth_states;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Server authorization required' using errcode='42501';end if;
 if jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>50000 then raise exception 'Invalid service payload';end if;
 select * into strict c from binderclip.drive_connection where singleton for update;
 if p_action='connection.get' then
  result:=to_jsonb(c)-'secret_id';
  if c.secret_id is not null then select decrypted_secret::jsonb into v from vault.decrypted_secrets where id=c.secret_id;result:=result||jsonb_build_object('credentials',v);end if;
 elsif p_action='state.create' then
  if length(coalesce(p_data->>'verifier','')) not between 43 and 128 then raise exception 'Invalid verifier';end if;
  if (select count(*) from binderclip.drive_oauth_states where consumed_at is null and expires_at>clock_timestamp())>=20 then raise exception 'Too many connection attempts. Retry in ten minutes';end if;
  insert into binderclip.drive_oauth_states(state_hash,verifier,expires_at) values(p_data->>'state_hash',p_data->>'verifier',clock_timestamp()+interval '10 minutes');result:='{}';
 elsif p_action='state.consume' then
  select * into state_value from binderclip.drive_oauth_states where state_hash=p_data->>'state_hash' and consumed_at is null and expires_at>clock_timestamp() for update;
  if not found then raise exception 'Connection request expired or was already used';end if;
  update binderclip.drive_oauth_states set verifier=null,consumed_at=clock_timestamp() where state_hash=state_value.state_hash;
  result:=jsonb_build_object('verifier',state_value.verifier);
 elsif p_action='connection.save' then
  if length(coalesce(p_data->'credentials'->>'refresh_token',''))<10 or length(coalesce(p_data->'credentials'->>'access_token',''))<10 then raise exception 'Offline authorization is required';end if;
  if c.owner_sub is not null and (c.owner_sub<>p_data->>'owner_sub' or c.client_id<>p_data->>'client_id') then raise exception 'The existing storage owner and OAuth client must be preserved';end if;
  if c.secret_id is null then select vault.create_secret((p_data->'credentials')::text,'binderclip-drive-owner','Private attachment service OAuth credentials') into secret_value;
  else perform vault.update_secret(c.secret_id,(p_data->'credentials')::text);secret_value:=c.secret_id;end if;
  update binderclip.drive_connection set status='Preparing',owner_email=p_data->>'owner_email',owner_sub=p_data->>'owner_sub',client_id=p_data->>'client_id',root_id=coalesce(root_id,p_data->>'root_id'),secret_id=secret_value,updated_at=clock_timestamp() where singleton;
  select to_jsonb(x)-'secret_id' into result from binderclip.drive_connection x where singleton;
 elsif p_action='connection.token' then
  if c.secret_id is null then raise exception 'Storage is not connected';end if;
  select decrypted_secret::jsonb into strict v from vault.decrypted_secrets where id=c.secret_id;
  v:=v||p_data->'credentials';perform vault.update_secret(c.secret_id,v::text);result:='{}';
 elsif p_action='connection.ready' then
  if c.root_id is null or c.secret_id is null then raise exception 'Connection is incomplete';end if;
  update binderclip.drive_connection set status='Ready',root_url=p_data->>'root_url',updated_at=clock_timestamp() where singleton;result:='{}';
 elsif p_action='connection.error' then
  update binderclip.drive_connection set status='Reconnect required',updated_at=clock_timestamp() where singleton;result:='{}';
 elsif p_action='folder.claim' then
  if c.status<>'Ready' then raise exception 'The document service needs owner attention';end if;
  if not exists(select 1 from binderclip.jobs where id=(p_data->>'job_id')::uuid and tenant_id=(p_data->>'tenant_id')::uuid) then raise exception 'Job unavailable';end if;
  insert into binderclip.drive_folders(tenant_id,job_id,external_id,parent_id) values((p_data->>'tenant_id')::uuid,(p_data->>'job_id')::uuid,p_data->>'external_id',c.root_id) on conflict do nothing;
  select to_jsonb(f) into result from binderclip.drive_folders f where tenant_id=(p_data->>'tenant_id')::uuid and job_id=(p_data->>'job_id')::uuid;
 elsif p_action in('document.get','document.claim','document.verified') then
  select * into strict d from binderclip.job_documents where id=(p_data->>'id')::uuid for update;
  insert into binderclip.document_storage(document_id,provider) values(d.id,'supabase') on conflict do nothing;
  select * into strict s from binderclip.document_storage where document_id=d.id for update;
  if p_action<>'document.get' then
   if d.status<>'Pending' or d.created_by::text<>p_data->>'created_by' then raise exception 'Attachment state changed';end if;
   if s.sha256 is not null and s.sha256<>p_data->>'sha256' then raise exception 'Select the original file for this pending attachment';end if;
   if p_action='document.claim' then
    if s.provider='google_drive' then
     select external_id into strict folder_id from binderclip.drive_folders where tenant_id=d.tenant_id and job_id=d.job_id;
     update binderclip.document_storage set external_id=coalesce(external_id,p_data->>'external_id'),parent_id=folder_id,sha256=p_data->>'sha256' where document_id=d.id;
    else update binderclip.document_storage set sha256=p_data->>'sha256' where document_id=d.id;end if;
   else
    if s.provider='google_drive' and s.external_id is null then raise exception 'Attachment is incomplete';end if;
    update binderclip.document_storage set sha256=p_data->>'sha256',verified_at=clock_timestamp() where document_id=d.id;
   end if;
   select * into strict s from binderclip.document_storage where document_id=d.id;
  end if;result:=to_jsonb(s);
 else raise exception 'Unknown document service action';end if;
 return coalesce(result,'{}');
end $$;

-- New uploads cannot bypass server verification, or use Supabase Storage when
-- the server selected another provider. Historical ready files remain usable.
do $$declare definition text;begin
 definition:=pg_get_functiondef('public.bc_document_access(text,text)'::regprocedure);
 definition:=replace(definition,'if not found or p_action not in', 'if found and exists(select 1 from binderclip.document_storage where document_id=document_row.id and provider<>''supabase'') then return false;end if; if not found or p_action not in');execute definition;
 definition:=pg_get_functiondef('public.bc_document_finish(uuid,uuid)'::regprocedure);
 definition:=replace(definition,'if not exists(select 1 from storage.objects',
  'if exists(select 1 from binderclip.document_storage where document_id=document_row.id and verified_at is null) then raise exception ''Server file verification is required. Refresh Binderclip and retry this attachment'';end if; if not exists(select 1 from binderclip.document_storage where document_id=document_row.id and provider=''google_drive'' and verified_at is not null) and not exists(select 1 from storage.objects');execute definition;
end $$;
revoke all on function binderclip.register_document_storage(),public.bc_document_context(uuid,uuid,text),public.bc_document_service(text,jsonb) from public,anon,authenticated;
grant execute on function public.bc_document_context(uuid,uuid,text) to authenticated;
grant execute on function public.bc_document_service(text,jsonb) to service_role;
commit;
