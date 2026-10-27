-- First installation only. Never modifies Choco_Requests or inserts sample transactions.
begin;
do $$declare t uuid;m uuid;r uuid;label text;begin
 if exists(select 1 from binderclip.companies) then raise exception 'Company already exists; bootstrap is intentionally first-run only';end if;
 insert into binderclip.companies(name) values('Binderclip') returning id into t;
 insert into binderclip.members(tenant_id,email,display_name) values(t,'inventory.choco@gmail.com','Admin1') returning id into m;
 insert into binderclip.roles(tenant_id,name,description) values(t,'Company administrator','Full company and security administration') returning id into r;
 insert into binderclip.member_roles values(t,m,r);
 insert into binderclip.grants(role_id,path,action,scope,can_export) select r,path,action,'global',true from binderclip.permissions;
 foreach label in array array['Operations','Finance','Read-only'] loop
  insert into binderclip.roles(tenant_id,name,description) values(t,label,label||' access within the assigned branch') returning id into r;
  insert into binderclip.grants(role_id,path,action,scope,can_export)
   select r,path,action,'branch',label='Finance' from binderclip.permissions p
   where p.path not like 'settings.%' and split_part(p.path,'.',3) not in ('unlock','variance')
   and (label<>'Read-only' or p.action='R')
   and (label<>'Operations' or (p.path not like 'invoicing.%' and p.path not like 'reports.%' and split_part(p.path,'.',3) not in ('approve','lock') and p.action<>'X'));
 end loop;
end $$;
commit;
