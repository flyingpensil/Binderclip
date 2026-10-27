-- Install only in a NEW Binderclip Supabase project. All application data is private.
begin;
create schema if not exists binderclip;
revoke all on schema binderclip from public, anon, authenticated;
create table binderclip.companies(
 id uuid primary key default gen_random_uuid(), name text not null, trn text not null default '',
 address text not null default '', currency text not null default 'AED' check(currency ~ '^[A-Z]{3}$'),
 tolerance numeric(5,2) not null default 5 check(tolerance between 0 and 100)
);
create table binderclip.members(
 id uuid primary key default gen_random_uuid(), tenant_id uuid not null references binderclip.companies,
 user_id uuid references auth.users, email text not null check(email=lower(email)), display_name text not null,
 branch text not null default 'Dubai', enabled boolean not null default true,
 unique(tenant_id,email),unique(tenant_id,user_id),unique(id,tenant_id)
);
create table binderclip.roles(
 id uuid primary key default gen_random_uuid(), tenant_id uuid not null references binderclip.companies,
 name text not null, description text not null default '', unique(tenant_id,name),unique(id,tenant_id)
);
create table binderclip.member_roles(
 tenant_id uuid not null, member_id uuid not null,role_id uuid not null,
 primary key(member_id,role_id),foreign key(member_id,tenant_id) references binderclip.members(id,tenant_id),
 foreign key(role_id,tenant_id) references binderclip.roles(id,tenant_id)
);
create table binderclip.permissions(path text not null,action text not null check(action in ('C','R','U','D','X')),primary key(path,action));
create table binderclip.grants(
 role_id uuid not null references binderclip.roles, path text not null, action text not null,
 scope text not null default 'none' check(scope in ('none','self','branch','global')),can_export boolean not null default false,
 primary key(role_id,path,action),foreign key(path,action) references binderclip.permissions
);
insert into binderclip.permissions select path,unnest(string_to_array(actions,null)) from (values
 ('overview.dashboard.view','R'),('customers.list.manage','CRU'),('customers.ledger.view','RX'),
 ('suppliers.list.manage','CRU'),('suppliers.ledger.view','RX'),('jobs.list.manage','CRU'),('jobs.detail.status','U'),
 ('costs.detail.manage','CR'),('costs.detail.book','U'),('costs.detail.match','C'),('costs.detail.variance','U'),
 ('costs.detail.approve','U'),('costs.detail.lock','U'),('costs.detail.unlock','U'),
 ('invoicing.list.manage','R'),('invoicing.detail.generate','C'),('invoicing.detail.approve','U'),
 ('invoicing.detail.issue','U'),('invoicing.detail.receipt','C'),('invoicing.detail.print','X'),
 ('masters.rates.manage','CRU'),('settings.roles.manage','CRU'),('settings.members.manage','CRU'),
 ('reports.journal.view','RX'),('settings.company.manage','RU')
) p(path,actions);
-- Master details are JSON documents; accounting amounts and foreign keys below are typed.
create table binderclip.masters(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,
 kind text not null check(kind in ('customers','suppliers','rates','tariffs')),code text not null,name text not null,
 currency text not null default 'AED' check(currency ~ '^[A-Z]{3}$'),parent_id uuid,
 data jsonb not null default '{}',branch text not null,created_by uuid not null references auth.users,
 created_at timestamptz not null default now(),unique(tenant_id,kind,code),unique(id,tenant_id),
 foreign key(parent_id,tenant_id) references binderclip.masters(id,tenant_id)
);
create table binderclip.jobs(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,
 number text not null,customer_id uuid not null,status text not null default 'Draft' check(status in ('Draft','Booked','In transit','Delivered','Closed','Cancelled')),
 data jsonb not null default '{}',approved boolean not null default false,locked_at timestamptz,locked_by uuid references auth.users,
 branch text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 unique(tenant_id,number),unique(id,tenant_id),foreign key(customer_id,tenant_id) references binderclip.masters(id,tenant_id)
);
create table binderclip.cost_lines(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,job_id uuid not null,
 side text not null check(side in ('BUY','SELL')),service text not null,supplier_id uuid,tariff_id uuid,
 quantity numeric(14,3) not null check(quantity>0),unit_rate numeric(18,2) not null check(unit_rate>=0),
 currency text not null check(currency ~ '^[A-Z]{3}$'),fx_rate numeric(16,8) not null check(fx_rate>0),
 tax_rate numeric(5,2) not null default 5 check(tax_rate between 0 and 100),exemption text not null default '',
 accrued boolean not null default false,branch text not null,created_by uuid not null references auth.users,
 unique(id,tenant_id),foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id),
 foreign key(supplier_id,tenant_id) references binderclip.masters(id,tenant_id),
 foreign key(tariff_id,tenant_id) references binderclip.masters(id,tenant_id),
 check(side<>'BUY' or supplier_id is not null),check(side<>'SELL' or tax_rate<>0 or length(trim(exemption))>0)
);
create table binderclip.supplier_bills(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,job_id uuid not null,line_id uuid not null unique,
 supplier_id uuid not null,number text not null,invoice_date date not null,due_date date not null,
 quantity numeric(14,3) not null check(quantity>0),unit_rate numeric(18,2) not null check(unit_rate>=0),
 currency text not null check(currency ~ '^[A-Z]{3}$'),fx_rate numeric(16,8) not null check(fx_rate>0),
 variance numeric(18,2) not null,status text not null default 'Pending' check(status in ('Pending','Matched')),
 approval_reason text not null default '',approved_by uuid references auth.users,
 branch text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 unique(id,tenant_id),foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id),
 foreign key(line_id,tenant_id) references binderclip.cost_lines(id,tenant_id),
 foreign key(supplier_id,tenant_id) references binderclip.masters(id,tenant_id)
);
create table binderclip.invoices(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,customer_id uuid not null,
 number text not null,currency text not null check(currency ~ '^[A-Z]{3}$'),fx_rate numeric(16,8) not null check(fx_rate>0),
 invoice_date date not null default current_date,due_date date not null,
 status text not null default 'Draft' check(status in ('Draft','Approved','Issued','Partially Paid','Paid')),
 snapshot jsonb not null,subtotal numeric(18,2) not null default 0,tax_total numeric(18,2) not null default 0,
 total numeric(18,2) not null default 0 check(total>=0),paid numeric(18,2) not null default 0 check(paid>=0 and paid<=total),
 branch text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 unique(tenant_id,number),unique(id,tenant_id),foreign key(customer_id,tenant_id) references binderclip.masters(id,tenant_id)
);
create table binderclip.invoice_items(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,invoice_id uuid not null,job_id uuid not null,line_id uuid not null unique,
 description text not null,quantity numeric(14,3) not null,unit_rate numeric(18,2) not null,
 tax_rate numeric(5,2) not null,exemption text not null,net numeric(18,2) not null,tax numeric(18,2) not null,
 foreign key(invoice_id,tenant_id) references binderclip.invoices(id,tenant_id),
 foreign key(job_id,tenant_id) references binderclip.jobs(id,tenant_id),foreign key(line_id,tenant_id) references binderclip.cost_lines(id,tenant_id)
);
create table binderclip.receipts(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,invoice_id uuid not null,
 reference text not null,amount numeric(18,2) not null check(amount>0),received_on date not null default current_date,
 branch text not null,created_by uuid not null references auth.users,unique(tenant_id,reference),
 foreign key(invoice_id,tenant_id) references binderclip.invoices(id,tenant_id)
);
create table binderclip.journals(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,source text not null,
 description text not null,branch text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
 posting_transaction bigint not null default txid_current(),unique(tenant_id,source)
);
create table binderclip.journal_lines(
 id bigint generated always as identity primary key,entry_id uuid not null references binderclip.journals,
 account text not null check(account in ('1000 Bank','1100 Receivables','2000 Accrued costs','2100 Payables','2200 VAT payable','4000 Freight revenue','5000 Direct costs')),
 debit numeric(18,2) not null default 0,credit numeric(18,2) not null default 0,
 check((debit>0 and credit=0) or (credit>0 and debit=0))
);
create table binderclip.audit(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references binderclip.companies,
 actor uuid not null references auth.users,action text not null,object_id uuid,detail text not null default '',created_at timestamptz not null default now()
);
create index on binderclip.jobs(tenant_id,created_at desc);
create index on binderclip.cost_lines(tenant_id,job_id);
create index on binderclip.supplier_bills(tenant_id,job_id);
create index on binderclip.invoices(tenant_id,created_at desc);
create index on binderclip.audit(tenant_id,created_at desc);

create function binderclip.actor() returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); sid uuid;
begin
 if u is null or not exists(select 1 from auth.users a join auth.identities i on i.user_id=a.id and i.provider='google'
   where a.id=u and a.email_confirmed_at is not null and (a.banned_until is null or a.banned_until<now())) then
   raise exception 'An approved, verified Google account is required' using errcode='42501'; end if;
 sid:=nullif(auth.jwt()->>'session_id','')::uuid;
 if sid is null or not exists(select 1 from auth.sessions s where s.id=sid and s.user_id=u and (s.not_after is null or s.not_after>now())) then
   raise exception 'Session revoked or expired' using errcode='42501'; end if;
 return u;
end $$;
create function binderclip.member(t uuid) returns binderclip.members language plpgsql security definer set search_path='' as $$
declare m binderclip.members;u uuid:=binderclip.actor();
begin
 select a.* into m from binderclip.members a join auth.users b on b.id=u
 where a.tenant_id=t and a.enabled and a.email=lower(b.email) and (a.user_id=u or a.user_id is null);
 if not found then raise exception 'Your Google account has no active company access' using errcode='42501'; end if;
 return m;
end $$;
create function binderclip.allowed(t uuid,p text,a text,owner_id uuid default null,row_branch text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare m binderclip.members:=binderclip.member(t);
begin
 return exists(select 1 from binderclip.grants g join binderclip.member_roles r on r.role_id=g.role_id
 where r.member_id=m.id and r.tenant_id=t and g.path=p and g.action=a and g.scope<>'none'
 and (a<>'X' or g.can_export) and (g.scope='global' or (g.scope='branch' and row_branch=m.branch) or (g.scope='self' and owner_id=auth.uid())));
end $$;
create function binderclip.require(t uuid,p text,a text,owner_id uuid default null,row_branch text default null)
returns void language plpgsql security definer set search_path='' as $$
begin if not binderclip.allowed(t,p,a,owner_id,row_branch) then raise exception 'This action is outside your role or company scope' using errcode='42501';end if;end $$;
create function binderclip.log(t uuid,a text,o uuid,detail text default '') returns void language sql security definer set search_path='' as $$
 insert into binderclip.audit(tenant_id,actor,action,object_id,detail) values(t,auth.uid(),a,o,detail);
$$;
create function binderclip.immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Posted history is immutable; use a separately authorized correction workflow';end $$;
create trigger immutable_journals before update or delete on binderclip.journals for each row execute function binderclip.immutable();
create trigger immutable_lines before update or delete on binderclip.journal_lines for each row execute function binderclip.immutable();
create trigger immutable_audit before update or delete on binderclip.audit for each row execute function binderclip.immutable();
create trigger immutable_invoice_items before update or delete on binderclip.invoice_items for each row execute function binderclip.immutable();
create function binderclip.balance() returns trigger language plpgsql set search_path='' as $$
declare target uuid; n bigint;d numeric;c numeric;
begin
 if TG_TABLE_NAME='journals' then target:=new.id;else target:=new.entry_id;end if;
 select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0) into n,d,c from binderclip.journal_lines where entry_id=target;
 if n<2 or d<>c then raise exception 'Journal must have at least two balanced lines';end if;return new;
end $$;
create constraint trigger balanced_entry after insert on binderclip.journals deferrable initially deferred for each row execute function binderclip.balance();
create constraint trigger balanced_lines after insert on binderclip.journal_lines deferrable initially deferred for each row execute function binderclip.balance();
create function binderclip.new_line_only() returns trigger language plpgsql set search_path='' as $$
begin if not exists(select 1 from binderclip.journals where id=new.entry_id and posting_transaction=txid_current()) then raise exception 'Cannot append to committed journal';end if;return new;end $$;
create trigger committed_entry_guard before insert on binderclip.journal_lines for each row execute function binderclip.new_line_only();
create function binderclip.post(t uuid,k text,descr text,b text,lines jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare e uuid;v jsonb;d numeric;c numeric;ds numeric:=0;cs numeric:=0;
begin
 for v in select value from jsonb_array_elements(lines) loop
  d:=round((v->>1)::numeric,2);c:=round((v->>2)::numeric,2);
  if d<0 or c<0 or (d>0 and c>0) then raise exception 'Invalid journal line';end if;
  ds:=ds+d;cs:=cs+c;
 end loop;
 if ds<>cs then raise exception 'Unbalanced posting';end if;if ds=0 then return null;end if;
 insert into binderclip.journals(tenant_id,source,description,branch,created_by) values(t,k,descr,b,auth.uid()) returning id into e;
 for v in select value from jsonb_array_elements(lines) loop
  d:=round((v->>1)::numeric,2);c:=round((v->>2)::numeric,2);
  if d>0 or c>0 then insert into binderclip.journal_lines(entry_id,account,debit,credit) values(e,v->>0,d,c);end if;
 end loop;return e;
end $$;
create function binderclip.base(q numeric,r numeric,fx numeric) returns numeric language sql immutable set search_path='' as $$select round(round(q*r,2)*fx,2)$$;
-- Send decimals as strings so browser JSON parsing cannot round money or FX values.
create function binderclip.decimals(v jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb;
begin
 case jsonb_typeof(v)
 when 'number' then return to_jsonb(v#>>'{}');
 when 'array' then select coalesce(jsonb_agg(binderclip.decimals(value)),'[]') into result from jsonb_array_elements(v);return result;
 when 'object' then select coalesce(jsonb_object_agg(key,binderclip.decimals(value)),'{}') into result from jsonb_each(v);return result;
 else return v;end case;
end $$;
create function binderclip.figures(t uuid,j uuid) returns jsonb language sql stable set search_path='' as $$
 with totals as(select
 coalesce(sum(binderclip.base(l.quantity,l.unit_rate,l.fx_rate)) filter(where side='BUY'),0) expected_buy,
 coalesce(sum(case when b.status='Matched' then binderclip.base(b.quantity,b.unit_rate,b.fx_rate) else binderclip.base(l.quantity,l.unit_rate,l.fx_rate) end) filter(where side='BUY'),0) actual_buy,
 coalesce(sum(binderclip.base(l.quantity,l.unit_rate,l.fx_rate)) filter(where side='SELL'),0) sell
 from binderclip.cost_lines l left join binderclip.supplier_bills b on b.line_id=l.id where l.tenant_id=t and l.job_id=j)
 select to_jsonb(totals)||jsonb_build_object('margin',sell-actual_buy,'expected_margin',sell-expected_buy,'margin_percent',case when sell=0 then 0 else round((sell-actual_buy)/sell*100,2) end) from totals;
$$;
create function binderclip.job_guard(t uuid,j uuid,p text,a text default 'U') returns binderclip.jobs language plpgsql security definer set search_path='' as $$
declare r binderclip.jobs;
begin
 select * into r from binderclip.jobs where id=j and tenant_id=t for update;
 if not found then raise exception 'Job unavailable';end if;
 perform binderclip.require(t,p,a,r.created_by,r.branch);
 if r.locked_at is not null or r.status in ('Closed','Cancelled') then raise exception 'The job is locked, closed or cancelled';end if;
 return r;
end $$;
-- There are no table grants or RLS policies permitting direct browser access.
do $$declare r record;begin
 for r in select tablename from pg_tables where schemaname='binderclip' loop
  execute format('alter table binderclip.%I enable row level security',r.tablename);
 end loop;
end $$;
revoke all on all tables in schema binderclip from public,anon,authenticated;
revoke all on all sequences in schema binderclip from public,anon,authenticated;
revoke all on all functions in schema binderclip from public,anon,authenticated;
alter default privileges in schema binderclip revoke execute on functions from public;
commit;
