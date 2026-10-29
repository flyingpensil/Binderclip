-- Deferred constraint triggers execute at transaction end, after the public
-- SECURITY DEFINER RPC has returned. Keep private table access inside this
-- narrowly scoped trigger; never grant browser roles private-schema access.
begin;
alter function binderclip.balance() security definer;
alter function binderclip.balance() set search_path='';
revoke all on function binderclip.balance() from public,anon,authenticated;
commit;
