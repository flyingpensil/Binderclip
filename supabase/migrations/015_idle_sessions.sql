begin;
create table binderclip.session_activity(session_id uuid primary key references auth.sessions on delete cascade,user_id uuid not null references auth.users,last_seen timestamptz not null);
alter table binderclip.session_activity enable row level security;
revoke all on binderclip.session_activity from public,anon,authenticated;
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.actor()'::regprocedure);
 definition:=replace(definition,'return u;','insert into binderclip.session_activity(session_id,user_id,last_seen) values(sid,u,clock_timestamp()) on conflict do nothing; if exists(select 1 from binderclip.session_activity where session_id=sid and last_seen<=clock_timestamp()-interval ''2 hours'') then raise exception ''Signed out after two hours of inactivity. Sign in again.'' using errcode=''42501'';end if; return u;');execute definition;
end $$;
create function public.bc_activity() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=binderclip.actor();sid uuid:=(auth.jwt()->>'session_id')::uuid;begin
 update binderclip.session_activity set last_seen=clock_timestamp() where session_id=sid and user_id=actor_id;
 return jsonb_build_object('idle_seconds',7200);
end $$;
revoke all on function public.bc_activity() from public,anon,authenticated;
grant execute on function public.bc_activity() to authenticated;
commit;
